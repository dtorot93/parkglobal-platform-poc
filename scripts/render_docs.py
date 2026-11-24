#!/usr/bin/env python3
"""Genera docs/p2/documentacion-interactiva.html (autocontenido) desde la plantilla docs/p2/src/template.html,
incrustando los contratos, el spike, los ADR y la evidencia real de evidence/p2/. Uso: python3 scripts/render_docs.py

Las cifras salen de evidence/p2/kpis.env y evidence/p2/resumen.txt, que escribe scripts/events-demo.sh.
Si falta una cifra, falla: el documento nunca muestra un número que no se midió."""
import datetime as dt
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
EV = ROOT / "evidence" / "p2"
rd = lambda p: (ROOT / p).read_text()


def secs(ms: str) -> str:
    return f"{int(ms) / 1000:.1f}".replace(".", ",")


ev = {f.name: f.read_text() for f in sorted(EV.glob("*.txt"))}
raw = dict(line.split("=", 1) for line in (EV / "kpis.env").read_text().split() if "=" in line)  # la última gana
need = ["prop_ms", "lat_samples", "lat_p50", "lat_p99", "replay_ms", "v2_ms", "lead_min_ms", "lead_med_ms", "lead_max_ms", "lead_samples"]
missing = [k for k in need if not raw.get(k)]
if missing:
    raise SystemExit(f"Faltan cifras en evidence/p2/kpis.env: {missing}. Ejecute make events-demo.")
summary = ev["resumen.txt"]
passed, failed = (int(x) for x in re.search(r"# (\d+) comprobaciones correctas, (\d+) fallidas", summary).groups())
kpis = {"prop": raw["prop_ms"], "p50": raw["lat_p50"], "p99": raw["lat_p99"], "n": raw["lat_samples"],
        "replay": secs(raw["replay_ms"]), "v2": secs(raw["v2_ms"]),
        "lead": f"{secs(raw['lead_min_ms'])}–{secs(raw['lead_max_ms'])}", "leadmed": secs(raw["lead_med_ms"]),
        "leadn": raw["lead_samples"], "checks": f"{passed} comprobaciones correctas y {failed} fallidas",
        "evdate": re.search(r"· (\d{4}-\d\d-\d\d)T", summary).group(1)}

spike = []
for line in ev.get("00-spike-compatibilidad.txt", "").splitlines():
    m = re.match(r"(\S+)\s+\| (.+?)\s+\| cfg=\d+ v1=\d+ -> (ACEPTA|RECHAZA)", line)
    if m:
        spike.append((m.group(1), m.group(2), m.group(3)))
half = len(spike) // 2
spike_rows = [{"m": a[0], "c": a[1], "a": a[2], "k": b[2]} for a, b in zip(spike[:half], spike[half:])]

adrs = []
for f in sorted((ROOT / "docs" / "adr").glob("ADR-00[5-9]*.md")):
    text = f.read_text()
    adrs.append({"title": text.splitlines()[0].lstrip("# "), "body": "\n".join(text.splitlines()[1:]).strip()})

names = {"00": "00 spike", "01": "01 estado", "02": "02 propagación", "03": "03 disponibilidad", "04": "04 relectura",
         "05": "05 tombstone", "06": "06 jerarquía", "07": "07 registry 409", "08": "08 evolución v2",
         "09": "09 sin autorregistro", "10": "10 Kyverno", "11": "11 lead time", "12": "12 CI barrera 1", "re": "resumen"}
evidence = [{"name": names.get(k[:2], k), "text": v[:14000]} for k, v in ev.items()]

rubric = [
    {"crit": "PoC: Implementación y Evidencia (Gestión de Eventos) · /20", "mine": True, "items": [
        ["Herramientas OSS para gestionar eventos", "Strimzi, Apicurio, Crossplane, provider-kubernetes, Kyverno: evidence/p2/01"],
        ["Abstracción de mensajería", "EventStreamClaim + ConfigMap <tópico>-client; el servicio solo hace envFrom (apps/ecst-demo/k8s)"],
        ["PoC altamente funcional", f"11 escenarios con make events-demo: {kpis['checks']} (evidence/p2/resumen.txt)"],
        ["Demostración de la reducción de carga", f"claim Ready en {kpis['lead']} s (mediana {kpis['leadmed']} s); 7 campos obligatorios + contrato; CI con diagnóstico por campo"],
        ["Video para la sustentación", "Kit en docs/p2/video: guion, láminas y demo guiada que comprueba cada paso"]]},
    {"crit": "Contratos de Datos y Gobernanza (Schema Registry) · /15", "mine": False, "items": [
        ["Contrato formal Avro", "streams/*/*/schemas/v1.avsc (docs/p2/contratos.md)"],
        ["Política de compatibilidad precisa", "FULL_TRANSITIVE, justificada por el orden de despliegue y la relectura del tópico compactado"],
        ["Ejemplo claro de protección", "Sin currency → CI rojo y 409; campo opcional → aceptado, escrito con v2 y leído por un lector v1 (evidence/p2/07, 08)"],
        ["Actualizar la diapositiva 6 (Juan)", "JSON Schema → Avro con el spike como evidencia (ADR-005)"]]},
    {"crit": "Migración a ECST · /15", "mine": False, "items": [
        ["Reducción de carga en las APIs síncronas", "0 llamadas a la API de Tarifas por cambio (evidence/p2/02)"],
        ["Desacoplamiento temporal", "Tarifas caído → los consumidores siguen respondiendo (evidence/p2/03)"],
        ["Estado reconstruible", f"relectura desde el offset 0 en {kpis['replay']} s (evidence/p2/04)"]]},
    {"crit": "Insumos para Interacción, PaaP y Tablero", "mine": False, "items": [
        ["Collaboration → X-as-a-Service", "PR auto-integrado; los casos atípicos (PII, deltas) vuelven a Collaboration"],
        ["Curación 80/20", "Solo type: state, sin PII, Avro (impuesto por Kyverno y la XRD)"],
        ["Métricas leading", "lead time por stream con desglose por hito (lead-time-streams.csv), p99 de entrega, incompatibles bloqueados"]]},
]

claim = rd("streams/tarifas/zone-tariff-state/eventstreamclaim.yaml")
data = {"zt": json.loads(rd("streams/tarifas/zone-tariff-state/schemas/v1.avsc")),
        "zs": json.loads(rd("streams/zonas/zone-state/schemas/v1.avsc")),
        "v2c": json.loads(rd("tests/contracts/zone-tariff-state-v2-compatible.avsc")),
        "v2b": json.loads(rd("tests/contracts/zone-tariff-state-v2-breaking.avsc")),
        "spike": spike_rows, "adrs": adrs, "kpis": kpis, "evidence": evidence, "rubric": rubric}
html = rd("docs/p2/src/template.html")
html = html.replace("__DATA__", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
for key, ph in [("p99", "__P99__"), ("p50", "__P50__"), ("n", "__N__"), ("leadmed", "__LEADMED__"), ("leadn", "__LEADN__"),
                ("lead", "__LEAD__"), ("checks", "__CHECKS__"), ("replay", "__REPLAY__"), ("evdate", "__EVDATE__")]:
    html = html.replace(ph, kpis[key])
html = (html
        .replace("__CLAIM__", claim.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
        .replace("__DATE__", dt.date.today().isoformat()))
out = ROOT / "docs" / "p2" / "documentacion-interactiva.html"
out.write_text(html)
print(f"{out.relative_to(ROOT)} ({len(html) // 1024} KiB) · KPIs {kpis} · spike {len(spike_rows)} filas · {len(evidence)} evidencias")
