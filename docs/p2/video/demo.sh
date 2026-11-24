#!/usr/bin/env bash
# Demo guiada para el video de la segunda parte (guion: docs/p2/video/guion.md).
#   demo.sh preparar   revisa el entorno y deja listo el registry del CI (antes de grabar)
#   demo.sh            6 pasos; Enter avanza. Un paso solo muestra ✔ si lo comprobó.
#   AUTO=3 demo.sh     ensayo sin teclado (3 s por pantalla)
# No escribe en evidence/. Crea un stream con nombre único y, al salir (también con Ctrl+C), borra solo ese.
set -euo pipefail
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib.sh"
cd "$ROOT_DIR"
# Ninguna llamada puede dejar la grabación colgada (--foreground: Ctrl+C sigue funcionando).
k() { timeout --foreground -k 5 "${KTIMEOUT:-130}" kubectl --context "$KCTX" "$@"; }
LOG=${DEMO_LOG:-${TMPDIR:-/tmp}/parkglobal-demo-video.$UID.log}

B=$'\e[1m'; C=$'\e[1;36m'; G=$'\e[1;32m'; R=$'\e[1;31m'; Y=$'\e[1;33m'; D=$'\e[2m'; N=$'\e[0m'
CI=http://localhost:18080/apis/ccompat/v7
V1=streams/tarifas/zone-tariff-state/schemas/v1.avsc
V2=tests/contracts/zone-tariff-state-v2-compatible.avsc
BAD=tests/contracts/zone-tariff-state-v2-breaking.avsc

fail() { printf '%s✘ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
ok()   { printf '%s✔ %s%s\n' "$G" "$*" "$N"; }
cmd()  { printf '%s$ %s%s\n' "$Y" "$*" "$N"; }
now()  { date +%s%3N; }
secs() { awk -v m="$1" 'BEGIN{s=sprintf("%.1f", m/1000); sub(/\./,",",s); print s}'; }
wrap() { fold -s -w 104 | sed 's/^/  /'; }
next() { printf '\n%s[Enter]%s' "$D" "$N"; if [ -n "${AUTO:-}" ]; then sleep "$AUTO"; else read -rs; fi; }
step() { printf '\e[H\e[2J\e[3J'; printf '%s%s/6  %s%s\n%s%s%s\n\n' "$C" "$1" "$2" "$N" "$D" "$3" "$N"; }

# http <namespace> <deploy> <método> <url|ruta> [json] -> cuerpo de la respuesta (también si es un error HTTP)
http() {
  k -n "$1" exec "deploy/$2" -- python -c '
import sys, urllib.request as u, urllib.error as e
m, url = sys.argv[1:3]; body = sys.argv[3].encode() if sys.argv[3] else None
url = "http://localhost:8000" + url if url.startswith("/") else url
req = u.Request(url, body, {"Content-Type": "application/json"}, method=m)
try: print(u.urlopen(req, timeout=15).read().decode())
except e.HTTPError as x: print(x.read().decode())' "$3" "$4" "${5:-}"
}
# El registry se consulta desde Zonas: en el paso 4 Tarifas está apagado.
registry() { http team-zonas zonas "$1" "http://schema-registry.team-platform-events.svc:8080/apis/ccompat/v7$2" "${3:-}"; }

preparar() {
  docker info >/dev/null 2>&1 || fail "Docker no responde: abre Docker Desktop y espera un minuto"
  k --request-timeout=15s get nodes >/dev/null 2>&1 || fail "el clúster $CLUSTER_NAME no responde"
  local x
  for x in "kafka deploy/events-entity-operator" "team-platform-events deploy/schema-registry" "team-tarifas deploy/tarifas" \
           "team-zonas deploy/zonas" "team-consumidor-c deploy/consumidor-c" "kyverno deploy/kyverno-admission-controller"; do
    set -- $x
    k -n "$1" rollout status "$2" --timeout=120s >/dev/null || fail "$2 no está listo"
    ok "$2"
  done
  [ "$(k -n team-tarifas get deploy tarifas -o jsonpath='{.status.readyReplicas}')" = 1 ] ||
    fail "Tarifas está en 0 réplicas: kubectl --context $KCTX -n team-tarifas scale deploy/tarifas --replicas=1"
  ./scripts/contracts/ci-registry.sh >/dev/null
  ok "registry efímero del CI"
  ok "Listo para grabar"
}

if [ "${1:-}" = preparar ]; then preparar; exit 0; fi
[ $# -eq 0 ] || fail "uso: demo.sh [preparar]"
echo "Comprobando el entorno..."
preparar >/dev/null

TMP=$(mktemp -d)
ENTITY=parking-rule-$(date +%H%M%S)
NAME=$ENTITY-state
TOPIC=pricing.state.$ENTITY.v1
SUBJECT=$TOPIC-value
CREATED=; STOPPED=

cleanup() {
  local rc=$?
  set +e; trap '' INT
  printf '\n%sRestaurando el entorno (no hace falta grabar esto)...%s\n' "$D" "$N"
  [ -n "$STOPPED" ] && k -n team-tarifas scale deploy/tarifas --replicas=1 >/dev/null
  if [ -n "$CREATED" ]; then
    k -n team-tarifas delete eventstreamclaim "$NAME" --timeout=90s >/dev/null 2>&1
    k -n team-tarifas delete configmap "$NAME-contract" >/dev/null 2>&1
    k -n kafka delete kafkatopic "$TOPIC" >/dev/null 2>&1
    registry DELETE "/subjects/$SUBJECT" >/dev/null 2>&1
    registry DELETE "/subjects/$SUBJECT?permanent=true" >/dev/null 2>&1
  fi
  k -n team-tarifas rollout status deploy/tarifas --timeout=120s >/dev/null 2>&1
  rm -rf "$TMP"
  printf '%sEntorno restaurado.%s\n' "$D" "$N"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

write_claim() { # $1 = versión del contrato
  cat > "$TMP/claim.yaml" <<Y
apiVersion: platform.parkglobal.io/v1alpha1
kind: EventStreamClaim
metadata: {name: $NAME, namespace: team-tarifas}
spec:
  owner: {team: tarifas, costCenter: CC-PRC-01}
  domain: pricing
  entity: $ENTITY
  environment: dev
  key: {format: "<countryCode>:<zoneNo>", pattern: "^[A-Z]{2}:[0-9]+\$"}
  contract: {version: $1}
  governance: {pii: false}
  consumers: [{team: zonas}, {team: consumidor-c}]
Y
  { echo "resources: [claim.yaml]"
    echo "generatorOptions: {disableNameSuffixHash: true}"
    echo "configMapGenerator:"
    echo "- name: $NAME-contract"
    echo "  files:"
    for i in $(seq 1 "$1"); do echo "  - v$i.avsc"; done
  } > "$TMP/kustomization.yaml"
}

printf '\e[H\e[2J\e[3J\n\n  %sParkGlobal · Proyecto 2%s\n  %sGolden Path de eventos: demostración en vivo%s\n' "$C" "$N" "$B" "$N"
next

# ---------------------------------------------------------------------------------------------------------------------
step 1 "Autoservicio: el equipo declara, la plataforma construye" "Stream nuevo, creado en este momento"
cp "$V1" "$TMP/v1.avsc"; write_claim 1
sed -n '/^spec:/,$p' "$TMP/claim.yaml"
echo
cmd "kubectl apply -k <claim + contrato Avro>"
CREATED=1; t=$(now)
k apply --server-side -n team-tarifas -k "$TMP" >/dev/null
# Cada hito se imprime cuando ocurre. El Ready del claim llega entre 5 y 40 s: el provider sondea el estado del tópico.
topic= contract= config= ready=
for _ in $(seq 1 300); do
  if [ -z "$topic" ] && [ "$(k -n kafka get kafkatopic "$TOPIC" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)" = True ]; then
    policy=$(k -n kafka get kafkatopic "$TOPIC" -o jsonpath='{.spec.config.cleanup\.policy}')
    [ "$policy" = compact ] || fail "el tópico no quedó compactado"
    topic=1; ok "Tópico compactado     $TOPIC  ($(secs $(( $(now) - t ))) s)"
  fi
  if [ -z "$config" ]; then
    config=1
    for ns in team-tarifas team-zonas team-consumidor-c; do k -n "$ns" get cm "$TOPIC-client" >/dev/null 2>&1 || config=; done
    [ -z "$config" ] || ok "Configuración         entregada a Tarifas, Zonas y Consumidor C  ($(secs $(( $(now) - t ))) s)"
  fi
  claim=$(k -n team-tarifas get eventstreamclaim "$NAME" -o json)
  if [ -z "$contract" ] && [ "$(jq -r .status.contractRegistered <<<"$claim")" = true ]; then
    compat=$(registry GET "/config/$SUBJECT" | jq -r .compatibilityLevel)
    [ "$compat" = FULL_TRANSITIVE ] || fail "compatibilidad inesperada: $compat"
    contract=1; ok "Contrato registrado   v1 · $compat  ($(secs $(( $(now) - t ))) s)"
  fi
  if [ -n "$topic$contract$config" ] && jq -e '.status.conditions[]? | select(.type=="Ready" and .status=="True")' <<<"$claim" >/dev/null; then
    [ -n "$topic" ] && [ -n "$contract" ] && [ -n "$config" ] && { ready=1; break; }
  fi
  sleep .3
done
[ -n "$ready" ] || fail "el claim no quedó Ready"
ok "Claim Ready           verificado por la plataforma  ($(secs $(( $(now) - t ))) s)"
next

# ---------------------------------------------------------------------------------------------------------------------
step 2 "Guardrails: Kyverno rechaza lo que no cumple" "Se envían dos solicitudes inválidas al clúster"
reject() { # $1 = fixture, $2 = regla esperada
  cmd "kubectl apply --dry-run=server -f $1"
  local out
  if out=$(k apply --dry-run=server -f "$1" 2>&1); then fail "$1 fue aceptado"; fi
  grep -q "$2" <<<"$out" || fail "$1 falló por otra causa: $out"
  printf '%sRECHAZADO%s\n' "$R" "$N"
  grep "$2:" <<<"$out" | sed "s/^ *$2: *//; s/^'//; s/'\$//" | wrap
  echo
}
reject tests/fixtures/invalid-stream-domain.yaml domain-belongs-to-owner
reject tests/fixtures/invalid-stream-pii.yaml deny-pii
ok "Un equipo no declara streams de otro dominio ni con datos personales"
next

# ---------------------------------------------------------------------------------------------------------------------
step 3 "ECST: el evento trae el estado completo" "Tarifas cambia el precio de la zona SE:4021"
calls() { http team-tarifas tarifas GET /metrics | jq .api_calls_received; }
before=$(calls)
http team-zonas zonas DELETE /metrics/latency >/dev/null
http team-consumidor-c consumidor-c DELETE /metrics/latency >/dev/null
price=$(( 11000 + RANDOM % 8000 ))
cmd "PUT tarifas/tariffs/SE:4021 {\"maxDailyPriceMinor\": $price}"
http team-tarifas tarifas PUT /tariffs/SE:4021 "{\"maxDailyPriceMinor\":$price}" >/dev/null
seen=
for _ in $(seq 1 40); do
  z=$(http team-zonas zonas GET /zones/SE:4021 | jq .tariff.maxDailyPriceMinor)
  city=$(http team-consumidor-c consumidor-c GET /cities/SE-STO)
  c=$(jq '.zones[] | select(.zoneKey=="SE:4021") | .tariff.maxDailyPriceMinor' <<<"$city")
  if [ "$z" = "$price" ] && [ "$c" = "$price" ]; then seen=1; break; fi
  sleep .2
done
[ -n "$seen" ] || fail "el cambio no llegó a los dos consumidores"
echo
echo "Consumidor C arma Ciudad > Zonas > Tarifa con su copia local:"
jq -r '"  \(.cityName)", (.zones[] | "    \(.zoneKey)  \(.name)  precio=\(.tariff.maxDailyPriceMinor)  decisión=\(.decision.chargeType)")' <<<"$city"
echo
lz=$(http team-zonas zonas GET /metrics | jq .e2e_latency_ms.p50)
lc=$(http team-consumidor-c consumidor-c GET /metrics | jq .e2e_latency_ms.p50)
delta=$(( $(calls) - before ))
[ "$delta" = 0 ] || fail "hubo $delta llamadas a la API de Tarifas"
ok "Zonas          recibió el precio $price en $lz ms"
ok "Consumidor C   recibió el precio $price en $lc ms"
ok "Llamadas de vuelta a la API de Tarifas: 0   (diagnóstico actual: 4 o más)"
next

# ---------------------------------------------------------------------------------------------------------------------
step 4 "Disponibilidad: apagamos Tarifas" "Los consumidores responden con su copia local"
cmd "kubectl -n team-tarifas scale deploy/tarifas --replicas=0"
STOPPED=1
k -n team-tarifas scale deploy/tarifas --replicas=0 >/dev/null
# No se espera al apagado completo del pod: basta con que deje de atender (sin endpoints).
for _ in $(seq 1 100); do
  up=$(k -n team-tarifas get endpointslices -l kubernetes.io/service-name=tarifas -o json | jq '[.items[].endpoints[]? | select(.conditions.ready==true)] | length')
  [ "$up" = 0 ] && break; sleep .2
done
[ "$up" = 0 ] || fail "Tarifas sigue atendiendo"
printf '%sTarifas: 0 réplicas atendiendo%s\n\n' "$R" "$N"
z=$(http team-zonas zonas GET /zones/SE:4021)
c=$(http team-consumidor-c consumidor-c GET /cities/SE-STO | jq -c '.zones[] | select(.zoneKey=="SE:4021")')
[ "$(jq .tariff.maxDailyPriceMinor <<<"$z")" = "$price" ] || fail "Zonas perdió la tarifa"
[ "$(jq .tariff.maxDailyPriceMinor <<<"$c")" = "$price" ] || fail "el Consumidor C perdió la tarifa"
cmd "GET zonas/zones/SE:4021"
jq -r '"  precio=\(.tariff.maxDailyPriceMinor) \(.tariff.currency)  versión=\(.tariff.version)"' <<<"$z"
cmd "GET consumidor-c/cities/SE-STO"
jq -r '"  precio=\(.tariff.maxDailyPriceMinor) \(.tariff.currency)  decisión=\(.decision.chargeType)"' <<<"$c"
echo
ok "Los dos consumidores siguen operando sin el productor"
next
k -n team-tarifas scale deploy/tarifas --replicas=1 >/dev/null

# ---------------------------------------------------------------------------------------------------------------------
step 5 "Contrato: un cambio que rompe no pasa" "Un desarrollador borra el campo currency"
printf '%sBarrera 1 · el chequeo del CI, ejecutado en local%s\n' "$B" "$N"
cmd "check_contracts.py --candidate v2-sin-currency.avsc"
if out=$(python3 scripts/contracts/check_contracts.py --registry "$CI" --stream streams/tarifas/zone-tariff-state --candidate "$BAD" 2>&1); then
  fail "el chequeo aceptó el cambio incompatible"
fi
field=$(grep -o '\[currency at [^]]*\]' <<<"$out" | head -1) || fail "el chequeo falló por otra causa: $out"
printf '%sFALLA: incompatible con FULL_TRANSITIVE %s%s\n\n' "$R" "$field" "$N"
printf '%sBarrera 2 · alguien se salta el CI y va directo al registry%s\n' "$B" "$N"
cmd "POST /subjects/$SUBJECT/versions"
resp=$(registry POST "/subjects/$SUBJECT/versions" "$(jq -n --rawfile s "$BAD" '{schema:$s,schemaType:"AVRO"}')")
[ "$(jq -r .error_code <<<"$resp")" = 409 ] || fail "el registry no respondió 409: $resp"
printf '%sHTTP 409: %s%s\n' "$R" "$(jq -r .message <<<"$resp" | grep -o '\[currency at [^]]*\]')" "$N"
versions=$(registry GET "/subjects/$SUBJECT/versions" | jq -c .)
[ "$versions" = "[1]" ] || fail "versiones inesperadas: $versions"
echo
ok "Versiones registradas: $versions (la versión rota no entró)"
next

# ---------------------------------------------------------------------------------------------------------------------
step 6 "Evolución: un cambio compatible sí pasa" "Se agrega maxSessionMinutes, opcional y con valor por defecto"
cp "$V2" "$TMP/v2.avsc"; write_claim 2
cmd "kubectl apply -k <claim con contract.version: 2>"
t=$(now)
k apply --server-side -n team-tarifas -k "$TMP" >/dev/null
state=
for _ in $(seq 1 200); do
  state=$(k -n team-tarifas get eventstreamclaim "$NAME" -o jsonpath='{.status.contractVersion}{.status.contractRegistered}')
  [ "$state" = v2true ] && break; sleep .3
done
[ "$state" = v2true ] || fail "la v2 no se registró"
t=$(( $(now) - t ))
versions=$(registry GET "/subjects/$SUBJECT/versions" | jq -c .)
[ "$versions" = "[1,2]" ] || fail "versiones inesperadas: $versions"
ok "v2 registrada en $(secs "$t") s · versiones $versions"
echo
cmd "productor escribe con v2 → consumidores leen el mismo mensaje"
evolution() {
KTIMEOUT=35 k -n team-zonas exec deploy/zonas -- python -c '
import faulthandler, os, sys, uuid
faulthandler.dump_traceback_later(25, exit=True)
from confluent_kafka import Consumer, Producer
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroDeserializer, AvroSerializer
from confluent_kafka.serialization import MessageField, SerializationContext
topic, v1, v2 = sys.argv[1:]
reg = SchemaRegistryClient({"url": os.environ["ZONES_SCHEMA_REGISTRY_URL"], "timeout": 5})  # sin esto espera para siempre
bus = {"bootstrap.servers": os.environ["ZONES_KAFKA_BOOTSTRAP_SERVERS"]}
ctx = SerializationContext(topic, MessageField.VALUE)
doc = dict(zoneKey="SE:4021", countryCode="SE", zoneNo=4021, version=1, status="ACTIVE", timezone="UTC", currency="SEK",
           validFrom=1, validTo=None, parkingTypesByChannel={}, parkingFree=False, maxDailyPriceMinor=15000, updatedAt=1,
           maxSessionMinutes=240)
p = Producer(bus)
p.produce(topic, key="SE:4021", value=AvroSerializer(reg, v2, conf={"auto.register.schemas": False})(doc, ctx))
if p.flush(5): sys.exit("no se pudo publicar")
c = Consumer({**bus, "group.id": uuid.uuid4().hex, "auto.offset.reset": "earliest"})
c.subscribe([topic])
for _ in range(24):
    m = c.poll(.5)
    if m and not m.error(): break
else: sys.exit("no llegó el mensaje")
old, new = [AvroDeserializer(reg, s)(m.value(), ctx) for s in (v1, v2)]
c.close()
if "maxSessionMinutes" in old or new["maxSessionMinutes"] != 240: sys.exit("lectura inesperada")
for name, d, extra in (("v1", old, "(no conoce el campo)"), ("v2", new, "maxSessionMinutes=%s" % new["maxSessionMinutes"])):
    print("  consumidor %s  →  %s  %s  precio=%s  %s" % (name, d["zoneKey"], d["currency"], d["maxDailyPriceMinor"], extra))
' "$TOPIC" "$(cat "$V1")" "$(cat "$V2")"
}
read_ok=
for attempt in 1 2 3; do
  if out=$(evolution 2>>"$LOG"); then read_ok=1; break; fi
  echo "$(date -Is) paso 6, intento $attempt fallido ($TOPIC)" >>"$LOG"
done
[ -n "$read_ok" ] || fail "la lectura entre versiones falló (detalle en $LOG)"
echo "$out"
echo
ok "El consumidor con v1 sigue leyendo: nadie tuvo que coordinar un despliegue"
next
