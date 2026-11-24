import json, sys, copy, urllib.request, uuid
REG = {"apicurio": "http://localhost:18080/apis/ccompat/v7", "karapace": "http://localhost:18081"}
def call(base, method, path, body=None):
    req = urllib.request.Request(base+path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/vnd.schemaregistry.v1+json"})
    try:
        with urllib.request.urlopen(req) as r: return r.status, r.read().decode()[:160]
    except urllib.error.HTTPError as e: return e.code, e.read().decode()[:160]

BASE = {"$schema": "http://json-schema.org/draft-07/schema#", "title": "ZoneTariffState", "type": "object",
  "properties": {"zoneKey": {"type": "string"}, "version": {"type": "integer"}, "currency": {"type": "string"},
                 "parkingFree": {"type": "boolean"}, "maxDailyPrice": {"type": ["number", "null"]}},
  "required": ["zoneKey", "version", "currency", "parkingFree"]}
def model(kind):
    s = copy.deepcopy(BASE)
    if kind == "closed": s["additionalProperties"] = False
    if kind == "partial-pattern": s["additionalProperties"] = False; s["patternProperties"] = {"^ext_": {"type": ["string", "null"]}}
    if kind == "partial-addl": s["additionalProperties"] = {"type": ["string", "null"]}
    return s
def add(s, name, sch): s = copy.deepcopy(s); s["properties"][name] = sch; return s
def remove_currency(s): s = copy.deepcopy(s); del s["properties"]["currency"]; s["required"].remove("currency"); return s
JSON_CASES = []
for m in ["closed", "open", "partial-pattern", "partial-addl"]:
    v1 = model(m)
    JSON_CASES.append((m, "add optional promoCode (string|null)", v1, add(v1, "promoCode", {"type": ["string", "null"]})))
    if m == "partial-pattern":
        JSON_CASES.append((m, "add optional ext_promoCode (string|null)", v1, add(v1, "ext_promoCode", {"type": ["string", "null"]})))
    JSON_CASES.append((m, "remove required currency", v1, remove_currency(v1)))
AV1 = {"type": "record", "name": "ZoneTariffState", "namespace": "io.parkglobal.pricing", "fields": [
  {"name": "zoneKey", "type": "string"}, {"name": "version", "type": "long"}, {"name": "currency", "type": "string"},
  {"name": "parkingFree", "type": "boolean"}]}
av_add = copy.deepcopy(AV1); av_add["fields"].append({"name": "promoCode", "type": ["null", "string"], "default": None})
av_rm = copy.deepcopy(AV1); av_rm["fields"] = [f for f in av_rm["fields"] if f["name"] != "currency"]
av_add_nodef = copy.deepcopy(AV1); av_add_nodef["fields"].append({"name": "promoCode", "type": "string"})
AVRO_CASES = [("avro", "add optional promoCode with default", AV1, av_add), ("avro", "add promoCode WITHOUT default", AV1, av_add_nodef), ("avro", "remove required currency (no default)", AV1, av_rm)]

for regname, base in REG.items():
    print(f"\n### {regname}")
    for (m, desc, v1, v2) in JSON_CASES + AVRO_CASES:
        st = "AVRO" if m == "avro" else "JSON"
        subj = f"spike-{uuid.uuid4().hex[:8]}-value"
        c0, _ = call(base, "PUT", f"/config/{subj}", {"compatibility": "FULL_TRANSITIVE"})
        b1 = {"schema": json.dumps(v1)}; b2 = {"schema": json.dumps(v2)}
        if st == "JSON": b1["schemaType"] = b2["schemaType"] = "JSON"
        c1, r1 = call(base, "POST", f"/subjects/{subj}/versions", b1)
        c2, r2 = call(base, "POST", f"/subjects/{subj}/versions", b2)
        verdict = "ACEPTA" if c2 == 200 else f"RECHAZA({c2})"
        print(f"{m:16} | {desc:42} | cfg={c0} v1={c1} -> {verdict:13} {'' if c2==200 else r2[:90]}")
