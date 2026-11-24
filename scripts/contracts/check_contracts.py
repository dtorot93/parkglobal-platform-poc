#!/usr/bin/env python3
"""Primera barrera de gobierno de contratos (shift-left). Mismo script en CI y en local.

Para cada stream en streams/<team>/<stream>/ verifica:
  1. Estructura: claim, kustomization y schemas/v1..vN contiguos, con N == spec.contract.version
     y el ConfigMapGenerator listando exactamente esas versiones.
  2. Inmutabilidad: una versión ya publicada en la rama base no se modifica ni se borra (--base-ref).
  3. Catálogo: catalog-info.yaml y asyncapi.yaml describen el tópico, el subject y el último contrato.
  4. Compatibilidad: registra v1..vN, en orden, en un registry EFÍMERO (contenedor de servicio en CI)
     con la política FULL_TRANSITIVE. Un 409 = cambio incompatible: el PR queda en rojo.

Uso:
  check_contracts.py [--registry URL] [--base-ref origin/main] [--stream DIR ...]
  check_contracts.py --registry URL --stream DIR --candidate archivo.avsc   # prueba una vN+1 hipotética

Sale con 1 si algo falla. Imprime anotaciones ::error para GitHub Actions.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import render_catalog  # noqa: E402

COMPATIBILITY = "FULL_TRANSITIVE"
CT = {"Content-Type": "application/vnd.schemaregistry.v1+json"}
errors: list[str] = []


def error(file: pathlib.Path | str, msg: str) -> None:
    rel = pathlib.Path(file).resolve().relative_to(ROOT) if pathlib.Path(file).exists() else file
    print(f"::error file={rel},title=Contrato::{msg}")
    errors.append(msg)


def call(base: str, method: str, path: str, body=None):
    req = urllib.request.Request(base.rstrip("/") + path, method=method, headers=CT,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def versions_in(stream: pathlib.Path) -> list[tuple[int, pathlib.Path]]:
    found = []
    for p in (stream / "schemas").glob("*.avsc"):
        m = re.fullmatch(r"v(\d+)\.avsc", p.name)
        if not m:
            error(p, f"Nombre inválido {p.name}: use v<N>.avsc")
            continue
        found.append((int(m.group(1)), p))
    return sorted(found)


def check_structure(stream: pathlib.Path) -> tuple[dict, list[tuple[int, pathlib.Path]]] | None:
    claim_f, kust_f = stream / "eventstreamclaim.yaml", stream / "kustomization.yaml"
    for f in (claim_f, kust_f):
        if not f.exists():
            error(stream, f"Falta {f.name} en {stream.relative_to(ROOT)}")
            return None
    claim = yaml.safe_load(claim_f.read_text())
    name = claim["metadata"]["name"]
    declared = claim["spec"]["contract"]["version"]
    vers = versions_in(stream)
    nums = [n for n, _ in vers]
    if nums != list(range(1, len(nums) + 1)):
        error(stream / "schemas", f"Las versiones deben ser contiguas desde v1; hay {['v%d' % n for n in nums]}")
    if not nums or nums[-1] != declared:
        error(claim_f, f"spec.contract.version={declared} pero la última versión en schemas/ es v{nums[-1] if nums else 0}")
    for n, p in vers:
        try:
            sch = json.loads(p.read_text())
            if sch.get("type") != "record":
                error(p, "El contrato de un stream de estado debe ser un record Avro")
            # Convención ECST de la plataforma: versión monotónica (idempotencia) y updatedAt (SLO extremo a extremo).
            fields = {f["name"]: f["type"] for f in sch.get("fields", [])}
            if fields.get("version") != "long":
                error(p, f"{p.name}: falta el campo version (long): el consumidor lo usa para descartar duplicados y desorden")
            ua = fields.get("updatedAt")
            if not (isinstance(ua, dict) and ua.get("logicalType") == "timestamp-millis"):
                error(p, f"{p.name}: falta updatedAt (long timestamp-millis): sin él no se mide el SLO de entrega")
        except json.JSONDecodeError as e:
            error(p, f"JSON inválido: {e}")
    kust = yaml.safe_load(kust_f.read_text())
    gens = {g["name"]: g for g in kust.get("configMapGenerator", [])}
    gen = gens.get(f"{name}-contract")
    if not gen:
        error(kust_f, f"Falta configMapGenerator {name}-contract")
    else:
        expected = [f"v{n}.avsc=schemas/v{n}.avsc" for n in nums]
        if gen.get("files") != expected:
            error(kust_f, f"configMapGenerator.files debe ser exactamente {expected}")
    if not kust.get("generatorOptions", {}).get("disableNameSuffixHash"):
        error(kust_f, "generatorOptions.disableNameSuffixHash debe ser true (la composición monta <claim>-contract)")
    return claim, vers


def check_immutability(stream: pathlib.Path, base_ref: str) -> None:
    rel = stream.relative_to(ROOT) / "schemas"
    out = subprocess.run(["git", "-C", str(ROOT), "ls-tree", "--name-only", f"{base_ref}:{rel}"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return  # stream nuevo: no existe en la base
    for name in out.stdout.split():
        current = ROOT / rel / name
        base = subprocess.run(["git", "-C", str(ROOT), "show", f"{base_ref}:{rel}/{name}"],
                              capture_output=True, text=True).stdout
        if not current.exists():
            error(rel / name, f"{name} ya está publicado en {base_ref} y no se puede borrar (versiones inmutables)")
        elif current.read_text() != base:
            error(current, f"{name} ya está publicado en {base_ref} y no se puede modificar: agregue una versión nueva")


def check_catalog(stream: pathlib.Path, claim: dict, vers: list[tuple[int, pathlib.Path]]) -> None:
    """La ficha del catálogo debe describir exactamente el stream y su último contrato (chequeo semántico)."""
    s = claim["spec"]
    names = render_catalog.derive(claim)
    cat_f, api_f = stream / "catalog-info.yaml", stream / "asyncapi.yaml"
    hint = f"regenere con scripts/contracts/render_catalog.py {stream.relative_to(ROOT)}"
    if not cat_f.exists() or not api_f.exists():
        error(stream, f"Faltan catalog-info.yaml o asyncapi.yaml: {hint}")
        return
    cat = yaml.safe_load(cat_f.read_text())
    ann = cat.get("metadata", {}).get("annotations", {})
    expected = {"parkglobal.io/topic": names["topic"], "parkglobal.io/schema-subject": names["subject"],
                "parkglobal.io/contract-version": str(s["contract"]["version"])}
    for k, v in expected.items():
        if str(ann.get(k)) != v:
            error(cat_f, f"{k}={ann.get(k)!r} no coincide con el claim ({v!r}): {hint}")
    if cat.get("kind") != "API" or cat.get("spec", {}).get("type") != "asyncapi":
        error(cat_f, "La ficha debe ser una entidad API de tipo asyncapi")
    if cat.get("spec", {}).get("owner") != f"group:team-{s['owner']['team']}":
        error(cat_f, f"spec.owner debe ser group:team-{s['owner']['team']} (dueño del stream)")
    api = yaml.safe_load(api_f.read_text())
    channel = api.get("channels", {}).get(names["topic"])
    latest = json.loads(vers[-1][1].read_text()) if vers else None
    payloads = [m.get("payload", {}).get("schema") for m in (channel or {}).get("messages", {}).values()]
    if not channel or latest not in payloads:
        error(api_f, f"asyncapi.yaml no publica el canal {names['topic']} con el contrato v{s['contract']['version']}: {hint}")


def check_compatibility(registry: str, subject: str, files: list[pathlib.Path]) -> bool:
    """Registra las versiones en orden en un subject aislado del registry efímero."""
    isolated = f"ci-{uuid.uuid4().hex[:8]}-{subject}"
    code, body = call(registry, "PUT", f"/config/{isolated}", {"compatibility": COMPATIBILITY})
    if code != 200:
        error(files[0], f"No se pudo fijar {COMPATIBILITY} en el registry de CI ({code}): {body[:200]}")
        return False
    for i, f in enumerate(files, 1):
        code, body = call(registry, "POST", f"/subjects/{isolated}/versions",
                          {"schema": f.read_text(), "schemaType": "AVRO"})
        if code == 409:
            msg = json.loads(body).get("message", body) if body.startswith("{") else body
            error(f, f"{f.name} es INCOMPATIBLE con las versiones anteriores bajo {COMPATIBILITY}. "
                     f"Si el cambio es intencional, publique un tópico .v<major+1> con doble publicación. Registry: {msg[:300]}")
            return False
        if code not in (200, 201):
            error(f, f"{f.name} rechazado por el registry ({code}): {body[:300]}")
            return False
        print(f"  ok  v{i} compatible ({COMPATIBILITY}) -> id {json.loads(body).get('id')}")
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", help="URL de la API compatible con Confluent (p. ej. http://localhost:8080/apis/ccompat/v7)")
    ap.add_argument("--base-ref", help="rama base para verificar inmutabilidad (p. ej. origin/main)")
    ap.add_argument("--stream", action="append", help="directorio del stream (por defecto todos los de streams/*/*)")
    ap.add_argument("--candidate", help="archivo .avsc a probar como la versión N+1 del --stream indicado")
    args = ap.parse_args()

    streams = [pathlib.Path(s).resolve() for s in args.stream] if args.stream else sorted(
        p for p in (ROOT / "streams").glob("*/*") if p.is_dir())
    if not streams:
        print("No hay streams que validar.")
        return 0
    for stream in streams:
        print(f"== {stream.relative_to(ROOT)}")
        res = check_structure(stream)
        if res is None:
            continue
        claim, vers = res
        if args.base_ref:
            check_immutability(stream, args.base_ref)
        if not args.candidate:
            check_catalog(stream, claim, vers)
        if args.registry:
            s = claim["spec"]
            subject = f"{s['domain']}.{s.get('type', 'state')}.{s['entity']}.v{s.get('majorVersion', 1)}-value"
            files = [p for _, p in vers] + ([pathlib.Path(args.candidate).resolve()] if args.candidate else [])
            check_compatibility(args.registry, subject, files)
    if errors:
        print(f"\nFALLÓ: {len(errors)} problema(s) de contrato.")
        return 1
    print("\nOK: contratos válidos, inmutables y compatibles.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
