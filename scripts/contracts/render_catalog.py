#!/usr/bin/env python3
"""Genera asyncapi.yaml y catalog-info.yaml de un stream a partir de su claim y de su última versión de contrato.

Uso: scripts/contracts/render_catalog.py streams/<team>/<stream>

Así la ficha del catálogo (Backstage, entidad API tipo asyncapi) nunca se desalinea del contrato registrado:
el CI (check_contracts.py) verifica que tópico, subject, versión y payload coincidan con el claim y el último contrato.
Requiere PyYAML.
"""
import json
import pathlib
import sys

import yaml


def load_claim(path: pathlib.Path) -> dict:
    return yaml.safe_load(path.read_text())


def derive(claim: dict) -> dict:
    s = claim["spec"]
    topic = f"{s['domain']}.{s.get('type', 'state')}.{s['entity']}.v{s.get('majorVersion', 1)}"
    return {"topic": topic, "subject": f"{topic}-value"}


def main(stream_dir: str) -> None:
    d = pathlib.Path(stream_dir)
    claim = load_claim(d / "eventstreamclaim.yaml")
    s, meta = claim["spec"], claim["metadata"]
    names = derive(claim)
    version = s["contract"]["version"]
    schema = json.loads((d / "schemas" / f"v{version}.avsc").read_text())
    gov = s.get("governance", {})
    team = s["owner"]["team"]
    asyncapi = {
        "asyncapi": "3.0.0",
        "info": {
            "title": schema["name"],
            "version": f"{s.get('majorVersion', 1)}.{version}.0",
            "description": gov.get("description", ""),
            "x-parkglobal": {
                "owner": f"team-{team}",
                "pattern": "ECST (event-carried state transfer)",
                "subject": names["subject"],
                "compatibility": "FULL_TRANSITIVE",
                "pii": gov.get("pii", False),
                "sloP99Seconds": gov.get("sloP99Seconds", 5),
                "retention": "compactada por clave; tombstone = baja",
            },
        },
        "servers": {"local": {"host": "events-kafka-bootstrap.kafka.svc:9092", "protocol": "kafka"}},
        "channels": {
            names["topic"]: {
                "address": names["topic"],
                "messages": {
                    schema["name"]: {
                        "name": schema["name"],
                        "contentType": "application/vnd.apache.avro+binary",
                        "bindings": {"kafka": {"key": {"type": "string", "description": s["key"]["format"]}}},
                        "payload": {"schemaFormat": "application/vnd.apache.avro;version=1.9.0", "schema": schema},
                    }
                },
            }
        },
        "operations": {
            f"publish{schema['name']}": {
                "action": "send",
                "channel": {"$ref": f"#/channels/{names['topic']}"},
                "summary": f"team-{team} publica la foto completa del estado (único escritor).",
            }
        },
    }
    # JSON es YAML válido: se escribe como JSON indentado para no depender de PyYAML.
    (d / "asyncapi.yaml").write_text(
        "# GENERADO por scripts/contracts/render_catalog.py a partir del claim y de schemas/v%s.avsc. No editar a mano.\n" % version
        + json.dumps(asyncapi, indent=2, ensure_ascii=False) + "\n"
    )
    consumers = [f"team-{c['team']}" for c in s.get("consumers", [])]
    catalog = f"""# GENERADO por scripts/contracts/render_catalog.py. Entidad API (AsyncAPI) del catálogo de streams.
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: {names['topic'].replace('.', '-')}
  title: {schema['name']} ({names['topic']})
  description: {gov.get('description', '')}
  annotations:
    parkglobal.io/topic: {names['topic']}
    parkglobal.io/schema-subject: {names['subject']}
    parkglobal.io/compatibility: FULL_TRANSITIVE
    parkglobal.io/contract-version: "{version}"
    parkglobal.io/pii: "{str(gov.get('pii', False)).lower()}"
    parkglobal.io/slo-p99-seconds: "{gov.get('sloP99Seconds', 5)}"
    parkglobal.io/cost-center: {s['owner']['costCenter']}
    parkglobal.io/consumers: "{','.join(consumers)}"
    backstage.io/kubernetes-namespace: team-{team}
  tags: [ecst, kafka, avro, {s['domain']}, golden-path]
spec:
  type: asyncapi
  lifecycle: experimental
  owner: group:team-{team}
  system: {s['domain']}
  definition:
    $text: ./asyncapi.yaml
"""
    (d / "catalog-info.yaml").write_text(catalog)
    print(f"{d}: asyncapi.yaml y catalog-info.yaml generados ({names['topic']}, contrato v{version})")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
