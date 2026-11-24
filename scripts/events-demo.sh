#!/usr/bin/env bash
# Demostración reproducible del Golden Path de eventos (Proyecto 2, Sección IV) y recolección de evidencia.
# Cada escenario escribe evidence/p2/NN-*.txt y COMPRUEBA su resultado: una línea ✔/✘ por afirmación.
# Al final escribe evidence/p2/resumen.txt y evidence/p2/kpis.env (cifras que usa scripts/render_docs.py)
# y sale con código 1 si alguna comprobación falló.
# Requiere: scripts/local-up.sh (o Argo CD) + make events-demo-deploy + el registry efímero (make events-test).
#
# Uso: scripts/events-demo.sh [escenario...]     (sin argumentos: todos, en orden)
#   01 estado   02 propagacion   03 disponibilidad   04 replay   05 tombstone   06 jerarquia
#   07 registry-409   08 evolucion-v2   09 sin-autorregistro   10 kyverno   11 lead-time
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"
# Ninguna llamada puede colgar la demo (--foreground: Ctrl+C sigue funcionando).
k() { timeout --foreground -k 5 "${KTIMEOUT:-180}" kubectl --context "$KCTX" "$@"; }
EV=${EVIDENCE_DIR:-evidence/p2}   # EVIDENCE_DIR permite una corrida aparte sin pisar la evidencia publicada
mkdir -p "$EV"
TMP=$(mktemp -d)
RESULTS=$TMP/results
DISPOSABLE=$TMP/disposable   # streams desechables creados por esta ejecución (se borran al salir)
: > "$RESULTS"; : > "$DISPOSABLE"
REG=http://schema-registry.team-platform-events.svc:8080
LEAD_SAMPLES=${LEAD_SAMPLES:-5}
BURST=${BURST:-200}

# ------------------------------------------------------------------------------------------------- utilidades
# api <ns> <deploy> <METHOD> <path|url> [json]: llama desde el propio pod (sin port-forward). Imprime el cuerpo.
api() {
  KTIMEOUT=40 k -n "$1" exec "deploy/$2" -- python -c '
import sys, urllib.request as u, urllib.error as e
m, url = sys.argv[1], sys.argv[2]; body = sys.argv[3].encode() if len(sys.argv) > 3 and sys.argv[3] else None
url = "http://localhost:8000" + url if url.startswith("/") else url
req = u.Request(url, body, {"Content-Type": "application/json"}, method=m)
try: print(u.urlopen(req, timeout=15).read().decode())
except e.HTTPError as x: print(x.read().decode())' "$3" "$4" "${5:-}"
}
# reg <METHOD> <path> [json]: Schema Registry del clúster, desde Zonas (Tarifas se apaga en 03 y se altera en 09).
# Imprime "<código> <cuerpo>".
reg() {
  KTIMEOUT=40 k -n team-zonas exec deploy/zonas -- python -c '
import sys, urllib.request as u, urllib.error as e
m, url = sys.argv[1], sys.argv[2]; body = sys.argv[3].encode() if len(sys.argv) > 3 and sys.argv[3] else None
req = u.Request(url, body, {"Content-Type": "application/vnd.schemaregistry.v1+json"}, method=m)
try: r = u.urlopen(req, timeout=15); print(r.status, r.read().decode())
except e.HTTPError as x: print(x.code, x.read().decode())' "$1" "$REG$2" "${3:-}"
}
body() { cut -d' ' -f2-; }
hdr() { printf '# %s · %s\n# %s\n\n' "$1" "$(date -u +%FT%TZ)" "$2"; }
now() { date +%s%3N; }
kpi() { echo "$1=$2" >> "$EV/kpis.env"; }
# check "<afirmación>" <comando...>: ejecuta el comando y registra ✔ o ✘ (no aborta: el resumen cuenta los fallos).
check() {
  local msg=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  ✔ $msg"; echo "PASS|$SCEN|$msg" >> "$RESULTS"
  else echo "  ✘ $msg"; echo "FAIL|$SCEN|$msg" >> "$RESULTS"; fi
}
# poll <timeout s> <comando...>: repite hasta éxito; imprime los ms transcurridos o falla.
poll() {
  local t=$1; shift; local s; s=$(now)
  until "$@" >/dev/null 2>&1; do
    [ $(( $(now) - s )) -ge $(( t * 1000 )) ] && return 1
    sleep 0.2
  done
  echo $(( $(now) - s ))
}
eq() { [ "$1" = "$2" ]; }
le() { [ "$1" -le "$2" ]; }
ge() { [ "$1" -ge "$2" ]; }
has() { grep -qF -- "$2" <<<"$1"; }
secs() { awk -v m="$1" 'BEGIN{s=sprintf("%.1f", m/1000); sub(/\./,",",s); print s}'; }

# Streams desechables (08 y 11): misma forma que streams/tarifas/zone-tariff-state, con nombre único.
make_stream() { # <dir> <entidad> <versión> <v1.avsc> [v2.avsc]
  local d=$1 entity=$2 v=$3; mkdir -p "$d"
  cp "$4" "$d/v1.avsc"; [ -z "${5:-}" ] || cp "$5" "$d/v2.avsc"
  cat > "$d/claim.yaml" <<Y
apiVersion: platform.parkglobal.io/v1alpha1
kind: EventStreamClaim
metadata: {name: $entity-state, namespace: team-tarifas}
spec:
  owner: {team: tarifas, costCenter: CC-PRC-01}
  domain: pricing
  entity: $entity
  environment: dev
  key: {format: "<countryCode>:<zoneNo>", pattern: "^[A-Z]{2}:[0-9]+\$"}
  contract: {version: $v}
  governance: {pii: false, description: Stream desechable de events-demo.sh}
  consumers: [{team: zonas}]
Y
  { echo "resources: [claim.yaml]"; echo "generatorOptions: {disableNameSuffixHash: true}"
    echo "configMapGenerator:"; echo "- name: $entity-state-contract"; echo "  files:"
    for i in $(seq 1 "$v"); do echo "  - v$i.avsc"; done; } > "$d/kustomization.yaml"
  grep -qx "$entity" "$DISPOSABLE" || echo "$entity" >> "$DISPOSABLE"
}
drop_stream() { # <entidad>: borra solo lo que creó esta ejecución
  local e=$1 topic=pricing.state.$1.v1
  k -n team-tarifas delete eventstreamclaim "$e-state" --ignore-not-found --timeout=90s >/dev/null 2>&1 || true
  k -n team-tarifas delete configmap "$e-state-contract" --ignore-not-found >/dev/null 2>&1 || true
  k -n kafka delete kafkatopic "$topic" --ignore-not-found >/dev/null 2>&1 || true   # el claim lo conserva por diseño
  reg DELETE "/apis/ccompat/v7/subjects/$topic-value" >/dev/null 2>&1 || true
  reg DELETE "/apis/ccompat/v7/subjects/$topic-value?permanent=true" >/dev/null 2>&1 || true
}
cleanup() {
  local rc=$?; set +e
  while read -r e; do [ -n "$e" ] && drop_stream "$e"; done < "$DISPOSABLE"
  [ "$(k -n team-tarifas get deploy tarifas -o jsonpath='{.spec.replicas}' 2>/dev/null)" = 0 ] &&
    k -n team-tarifas scale deploy/tarifas --replicas=1 >/dev/null
  k -n team-tarifas delete configmap rogue-contract --ignore-not-found >/dev/null 2>&1
  rm -rf "$TMP"; exit "$rc"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------------------------- escenarios
s01() { # Estado de la plataforma: claims, tópicos compactados, subjects y configuración entregada
  { hdr "01 · Estado de la capacidad" "kubectl get eventstreamclaims, kafkatopics, jobs registradores, ConfigMaps de cliente y subjects"
    k get eventstreamclaims -A -o wide; echo
    k -n kafka get kafkatopics -l strimzi.io/cluster=events -o custom-columns='TOPIC:.metadata.name,PARTITIONS:.spec.partitions,CLEANUP:.spec.config.cleanup\.policy,READY:.status.conditions[0].status'; echo
    k get jobs -A -l parkglobal.io/stream; echo
    k get configmaps -A | grep -E -- '-client ' ; echo
    echo "## Subjects y política en el registry"; reg GET /apis/ccompat/v7/subjects
    local s
    for s in pricing.state.zone-tariff.v1-value topology.state.zone.v1-value; do
      reg GET "/apis/ccompat/v7/config/$s"; reg GET "/apis/ccompat/v7/subjects/$s/versions"; done
    echo; echo "## Metadatos de catálogo en el registry (dueño, PII, SLO, consumidores)"
    reg GET /apis/registry/v3/groups/default/artifacts/pricing.state.zone-tariff.v1-value
    echo; echo "## Lo que recibe el Consumidor C (sin pedirlo a nadie)"
    k -n team-consumidor-c get cm pricing.state.zone-tariff.v1-client -o yaml | sed -n '/^data:/,/^kind:/p'
    echo; echo "## Comprobaciones"
    local claims topics
    claims=$(k get eventstreamclaims -A -o json | jq '[.items[] | select(.metadata.name=="zone-tariff-state" or .metadata.name=="zone-state")
      | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length')
    check "Los 2 claims del piloto están Ready" eq "$claims" 2
    topics=$(k -n kafka get kafkatopics -o json | jq '[.items[] | select(.metadata.name|test("^(pricing.state.zone-tariff|topology.state.zone).v1$")) | select(.spec.config["cleanup.policy"]=="compact")] | length')
    check "Los 2 tópicos son compactados" eq "$topics" 2
    for s in pricing.state.zone-tariff.v1-value topology.state.zone.v1-value; do
      check "$s: FULL_TRANSITIVE" has "$(reg GET "/apis/ccompat/v7/config/$s")" FULL_TRANSITIVE
      check "$s: versiones registradas = las del repositorio ([1])" eq "$(reg GET "/apis/ccompat/v7/subjects/$s/versions" | body)" "[1]"
    done
    check "El Consumidor C recibió la configuración de los 2 streams" \
      eq "$(k -n team-consumidor-c get cm -o name | grep -c -- '-client$')" 2
  } | tee "$EV/01-estado-capacidad.txt"
}

s02() { # Propagación ECST: cambio de tarifa -> vistas locales, sin llamadas a la API de Tarifas
  local before after price ms
  before=$(api team-tarifas tarifas GET /metrics | jq .api_calls_received)
  price=$(( 20000 + RANDOM % 9000 ))   # valor único: el sondeo no puede confundirlo con otro cambio
  api team-tarifas tarifas PUT /tariffs/SE:4021 "{\"maxDailyPriceMinor\": $price}" > "$TMP/put.json"
  seen() { [ "$(api team-zonas zonas GET /zones/SE:4021 | jq .tariff.maxDailyPriceMinor)" = "$price" ] &&
           [ "$(api team-consumidor-c consumidor-c GET /cities/SE-STO | jq --arg k SE:4021 '.zones[]|select(.zoneKey==$k)|.tariff.maxDailyPriceMinor')" = "$price" ]; }
  ms=$(poll 30 seen) || ms=-1
  after=$(api team-tarifas tarifas GET /metrics | jq .api_calls_received)
  { hdr "02 · Propagación del estado (ECST)" "PUT de una tarifa en Tarifas -> Zonas y Consumidor C actualizan su vista local"
    echo "Tarifa SE:4021 -> maxDailyPriceMinor=$price, versión $(jq .version "$TMP/put.json") (outbox + relay tras el commit, sin espera fija)"
    echo "Visible en las vistas de Zonas y del Consumidor C en: ${ms} ms"
    echo "  (cota superior: incluye dos kubectl exec por cada sondeo; la latencia real del bus está en la ráfaga de abajo)"
    echo "Llamadas recibidas por la API de Tarifas durante el cambio: $((after - before))  (diagnóstico actual: >= 4 llamadas síncronas por cambio)"
    echo
    echo "## SLO de entrega (updatedAt en Tarifas -> escritura en la vista local): ráfaga de $BURST cambios, ventana limpia"
    api team-zonas zonas DELETE /metrics/latency >/dev/null; api team-consumidor-c consumidor-c DELETE /metrics/latency >/dev/null
    KTIMEOUT=300 k -n team-tarifas exec deploy/tarifas -- python -c '
import json, sys, time, urllib.request
keys = ["SE:4021", "SE:4022", "SE:5101", "CO:1101", "CO:1102"]
for i in range(int(sys.argv[1])):
    body = json.dumps({"maxDailyPriceMinor": 10000 + i}).encode()
    urllib.request.urlopen(urllib.request.Request("http://localhost:8000/tariffs/" + keys[i % 5], data=body, method="PUT",
                           headers={"Content-Type": "application/json"}), timeout=10).read()
    time.sleep(0.05)' "$BURST"
    sleep 3
    local a lat
    for a in "team-zonas zonas" "team-consumidor-c consumidor-c"; do
      set -- $a; lat=$(api "$1" "$2" GET /metrics | jq -c .e2e_latency_ms); printf '%-14s %s\n' "$2" "$lat"
      echo "$lat" > "$TMP/lat-$2.json"
    done
    echo "(SLO del contrato: p99 < 5000 ms. Reloj único: productores y consumidores corren en el mismo nodo kind)"
    echo; echo "## Zonas responde con su vista local (GET /zones/SE:4021)"; api team-zonas zonas GET /zones/SE:4021
    echo; echo "## Métricas de los consumidores"; api team-zonas zonas GET /metrics; api team-consumidor-c consumidor-c GET /metrics
    echo; echo "## Comprobaciones"
    check "El cambio llegó a las dos vistas locales" ge "$ms" 0
    check "0 llamadas a la API de Tarifas por el cambio" eq "$((after - before))" 0
    for a in zonas consumidor-c; do
      check "$a midió los $BURST cambios de la ráfaga" eq "$(jq .samples "$TMP/lat-$a.json")" "$BURST"
      check "$a cumple el SLO (p99 < 5000 ms)" le "$(jq .p99 "$TMP/lat-$a.json")" 4999
    done
  } | tee "$EV/02-propagacion.txt"
  kpi prop_ms "$ms"
  local l; l=$(cat "$EV/02-propagacion.txt" | sed -n 's/^consumidor-c *//p')
  kpi lat_samples "$(jq .samples <<<"$l")"; kpi lat_p50 "$(jq .p50 <<<"$l")"; kpi lat_p95 "$(jq .p95 <<<"$l")"
  kpi lat_p99 "$(jq .p99 <<<"$l")"; kpi lat_max "$(jq .max <<<"$l")"
}

s03() { # Disponibilidad recuperada: Tarifas caído, los consumidores siguen respondiendo
  local expected z c ready
  expected=$(api team-zonas zonas GET /zones/SE:4022 | jq .tariff.maxDailyPriceMinor)
  k -n team-tarifas scale deploy/tarifas --replicas=0 >/dev/null
  k -n team-tarifas wait --for=delete pod -l app=tarifas --timeout=90s >/dev/null 2>&1 || true
  z=$(api team-zonas zonas GET /zones/SE:4022)
  c=$(api team-consumidor-c consumidor-c GET /cities/SE-STO)
  ready=$(k -n team-tarifas get deploy tarifas -o jsonpath='{.status.readyReplicas}')
  { hdr "03 · Disponibilidad con el productor caído" "kubectl scale deploy/tarifas --replicas=0 y consultas a los consumidores"
    k -n team-tarifas get deploy tarifas; k -n team-tarifas get pods -l app=tarifas 2>&1; echo
    echo "## Zonas (sin Tarifas, sin Core, sin caché)"; echo "$z"
    echo; echo "## Consumidor C decide tipo de carga y comisión"; echo "$c"
    echo; echo "## Comprobaciones"
    check "Tarifas no tiene réplicas listas" eq "${ready:-0}" 0
    check "Zonas responde la tarifa vigente de SE:4022 ($expected)" eq "$(jq .tariff.maxDailyPriceMinor <<<"$z")" "$expected"
    check "El Consumidor C decide para las 2 zonas de Stockholm" \
      eq "$(jq '[.zones[] | select(.tariff != null and .decision.chargeType != "SIN_TARIFA")] | length' <<<"$c")" 2
  } | tee "$EV/03-disponibilidad.txt"
  k -n team-tarifas scale deploy/tarifas --replicas=1 >/dev/null
  k -n team-tarifas rollout status deploy/tarifas --timeout=180s >/dev/null
}

s04() { # Consumidor nuevo: reconstruye toda su vista desde el offset 0 del tópico compactado
  local m0 tv zv old new start podms ms m
  m0=$(api team-consumidor-c consumidor-c GET /metrics)
  tv=$(jq .tariff_view_size <<<"$m0"); zv=$(jq .zone_view_size <<<"$m0")
  old=$(k -n team-consumidor-c get pod -l app=consumidor-c -o jsonpath='{.items[0].metadata.name}')
  start=$(now)
  k -n team-consumidor-c set env deploy/consumidor-c "GROUP_SUFFIX=rebuild-$(date +%s)" >/dev/null
  k -n team-consumidor-c rollout status deploy/consumidor-c --timeout=180s >/dev/null
  podms=$(( $(now) - start ))
  # El pod NUEVO (exec deploy/ podría elegir el que está terminando, con la vista vieja completa).
  new=$(k -n team-consumidor-c get pod -l app=consumidor-c -o json |
        jq -r '[.items[] | select(.metadata.deletionTimestamp == null)][0].metadata.name')
  full() { KTIMEOUT=30 k -n team-consumidor-c exec "$new" -- python -c 'import urllib.request as u; print(u.urlopen("http://localhost:8000/metrics").read().decode())' |
           jq -e --argjson t "$tv" --argjson z "$zv" '.tariff_view_size == $t and .zone_view_size == $z' ; }
  poll 120 full >/dev/null || true
  ms=$(( $(now) - start ))
  m=$(KTIMEOUT=30 k -n team-consumidor-c exec "$new" -- python -c 'import urllib.request as u; print(u.urlopen("http://localhost:8000/metrics").read().decode())')
  { hdr "04 · Consumidor nuevo: relectura desde el offset 0" "Grupo de consumo nuevo + almacenamiento vacío: la vista se reconstruye sin llamar a ninguna API"
    echo "Pod anterior: $old · pod nuevo: $new"
    echo "Rollout terminado (pod nuevo listo): ${podms} ms"
    echo "Vista completa en el pod nuevo ($tv tarifas, $zv zonas): ${ms} ms desde el cambio de configuración"
    echo; echo "$m"
    echo; echo "## Log del pod nuevo"; k -n team-consumidor-c logs "$new" | grep -E 'relectura|consumiendo' | head -4
    echo; echo "## Comprobaciones"
    check "Es un pod nuevo" test "$new" != "$old"
    check "Reconstruyó $tv tarifas y $zv zonas" eq "$(jq '"\(.tariff_view_size)/\(.zone_view_size)"' -r <<<"$m")" "$tv/$zv"
    check "Leyó desde el tópico (events_consumed > 0) y no recibió llamadas" \
      eq "$(jq '.events_consumed > 0 and .api_calls_received == 0' <<<"$m")" true
  } | tee "$EV/04-replay.txt"
  kpi replay_ms "$ms"; kpi replay_pod_ms "$podms"
}

s05() { # Tombstone: la zona deja de tener tarifa; al volver, la versión sigue creciendo
  local v0 t0 gone back v1 c
  v0=$(api team-zonas zonas GET /zones/CO:1102 | jq '.tariff.version // 0')
  t0=$(api team-consumidor-c consumidor-c GET /metrics | jq .tombstones_applied)
  api team-tarifas tarifas DELETE /tariffs/CO:1102 >/dev/null || true
  isnull() { [ "$(api team-consumidor-c consumidor-c GET /cities/CO-BOG | jq --arg k CO:1102 '.zones[]|select(.zoneKey==$k)|.tariff')" = null ]; }
  gone=$(poll 30 isnull) || gone=-1
  c=$(api team-consumidor-c consumidor-c GET /cities/CO-BOG)
  local t1; t1=$(api team-consumidor-c consumidor-c GET /metrics | jq .tombstones_applied)
  api team-tarifas tarifas PUT /tariffs/CO:1102 '{"currency": "COP", "timezone": "America/Bogota", "maxDailyPriceMinor": 1800000}' >/dev/null
  # Si la versión se reiniciara tras la baja (bug corregido), nunca superaría v0 y esto agotaría el tiempo.
  isback() { [ "$(api team-zonas zonas GET /zones/CO:1102 | jq '.tariff.version // 0')" -gt "$v0" ]; }
  back=$(poll 30 isback) || back=-1
  v1=$(api team-zonas zonas GET /zones/CO:1102 | jq '.tariff.version // 0')
  { hdr "05 · Tombstone" "DELETE /tariffs/CO:1102 -> mensaje con valor nulo; los consumidores borran la clave (la compactación la retirará)"
    echo "## Consumidor C tras el tombstone ($gone ms)"; echo "$c"
    echo; echo "## Alta de nuevo ($back ms): versión antes de la baja = $v0, versión nueva = $v1"
    echo; echo "## Comprobaciones"
    check "El Consumidor C quitó la tarifa de CO:1102" ge "$gone" 0
    check "Aplicó un tombstone más" eq "$((t1 - t0))" 1
    check "La zona sin tarifa queda como SIN_TARIFA" has "$c" SIN_TARIFA
    check "Al volver, la versión sigue creciendo ($v0 -> $v1): nadie la descarta por vieja" test "$v1" -gt "$v0"
  } | tee "$EV/05-tombstone.txt"
}

s06() { # Jerarquía por referencia: Ciudad -> Zonas -> Tarifa compuesta por el consumidor
  local name c
  name="Centrum (Göteborg) $(date +%H%M%S)"
  api team-zonas zonas PUT /zones/SE:5101 "{\"name\": \"$name\", \"status\": \"ACTIVE\"}" >/dev/null
  renamed() { api team-consumidor-c consumidor-c GET /cities/SE-GOT | grep -qF "$name"; }
  poll 30 renamed >/dev/null || true
  c=$(api team-consumidor-c consumidor-c GET /cities)
  { hdr "06 · Jerarquía Ciudad -> Zonas -> Tarifa (opción A+)" "Dos streams de estado con un solo dueño cada uno; el Consumidor C los une por zoneKey y agrupa por cityId"
    echo "$c"
    echo; echo "## Comprobaciones"
    check "3 ciudades y 5 zonas" eq "$(jq '"\(.cities|length)/\([.cities[].zones[]]|length)"' -r <<<"$c")" "3/5"
    check "Las 5 zonas tienen tarifa" eq "$(jq '[.cities[].zones[] | select(.tariff != null)] | length' <<<"$c")" 5
    check "El cambio de Zonas (nombre) llegó sin tocar Tarifas" has "$c" "$name"
    check "Ninguna tarifa espera a su zona" eq "$(jq '.tariffsWaitingForZone | length' <<<"$c")" 0
  } | tee "$EV/06-jerarquia-ciudad.txt"
}

s07() { # Segunda barrera: alguien salta el CI y registra un cambio incompatible
  local b r v0 v1 ci rc
  b=$(jq -n --rawfile s tests/contracts/zone-tariff-state-v2-breaking.avsc '{schema: $s, schemaType: "AVRO"}')
  v0=$(reg GET /apis/ccompat/v7/subjects/pricing.state.zone-tariff.v1-value/versions | body)
  r=$(reg POST /apis/ccompat/v7/subjects/pricing.state.zone-tariff.v1-value/versions "$b")
  v1=$(reg GET /apis/ccompat/v7/subjects/pricing.state.zone-tariff.v1-value/versions | body)
  rc=0; ci=$(python3 scripts/contracts/check_contracts.py --registry "${CI_REGISTRY:-http://localhost:18080/apis/ccompat/v7}" \
      --stream streams/tarifas/zone-tariff-state --candidate tests/contracts/zone-tariff-state-v2-breaking.avsc 2>&1) || rc=$?
  { hdr "07 · Registry: cambio incompatible rechazado (409)" "POST directo al registry del clúster con el contrato sin currency (saltándose el CI)"
    echo "$r"
    echo; echo "## Versiones del subject: antes $v0 · después $v1"
    echo; echo "## Primera barrera (CI) con el mismo archivo (código de salida $rc)"; echo "$ci"
    echo; echo "## Comprobaciones"
    check "El registry responde 409" eq "${r%% *}" 409
    check "El diagnóstico señala el campo: [currency at /fields/6]" has "$r" "currency at /fields/6"
    check "La versión rota no se registró ($v0 = $v1)" eq "$v0" "$v1"
    check "El chequeo del CI falla" test "$rc" -ne 0
    check "El CI señala el mismo campo" has "$ci" "currency at /fields/6"
  } 2>&1 | tee "$EV/07-registry-409.txt"
}

s08() { # Evolución compatible v1 -> v2 en un stream desechable: registro real, escritor v2 y lector v1
  # Desechable: el stream del piloto no debe quedar con una v2 en el registry que el repositorio no declara.
  local e d t ms vers out rc
  e=evo-$(date +%H%M%S); d=$TMP/$e
  make_stream "$d" "$e" 1 streams/tarifas/zone-tariff-state/schemas/v1.avsc
  k apply --server-side -n team-tarifas -k "$d" >/dev/null
  k -n team-tarifas wait "eventstreamclaim/$e-state" --for=condition=Ready --timeout=180s >/dev/null || true
  make_stream "$d" "$e" 2 streams/tarifas/zone-tariff-state/schemas/v1.avsc tests/contracts/zone-tariff-state-v2-compatible.avsc
  t=$(now)
  k apply --server-side -n team-tarifas -k "$d" >/dev/null
  v2ok() { [ "$(k -n team-tarifas get eventstreamclaim "$e-state" -o jsonpath='{.status.contractVersion}{.status.contractRegistered}')" = v2true ]; }
  poll 180 v2ok >/dev/null || true
  ms=$(( $(now) - t ))
  vers=$(reg GET "/apis/ccompat/v7/subjects/pricing.state.$e.v1-value/versions" | body)
  rc=0; out=$(KTIMEOUT=60 k -n team-zonas exec deploy/zonas -- python -c '
import faulthandler, os, sys, uuid
faulthandler.dump_traceback_later(45, exit=True)
from confluent_kafka import Consumer, Producer
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroDeserializer, AvroSerializer
from confluent_kafka.serialization import MessageField, SerializationContext
topic, v1, v2 = sys.argv[1:]
reg = SchemaRegistryClient({"url": os.environ["ZONES_SCHEMA_REGISTRY_URL"], "timeout": 10})
bus = {"bootstrap.servers": os.environ["ZONES_KAFKA_BOOTSTRAP_SERVERS"]}
ctx = SerializationContext(topic, MessageField.VALUE)
doc = dict(zoneKey="SE:4021", countryCode="SE", zoneNo=4021, version=1, status="ACTIVE", timezone="UTC", currency="SEK",
           validFrom=1, validTo=None, parkingTypesByChannel={}, parkingFree=False, maxDailyPriceMinor=15000, updatedAt=1,
           maxSessionMinutes=240)
p = Producer(bus)
p.produce(topic, key="SE:4021", value=AvroSerializer(reg, v2, conf={"auto.register.schemas": False})(doc, ctx))
if p.flush(10): sys.exit("no se pudo publicar")
c = Consumer({**bus, "group.id": uuid.uuid4().hex, "auto.offset.reset": "earliest"})
c.subscribe([topic])
for _ in range(40):
    m = c.poll(.5)
    if m and not m.error(): break
else: sys.exit("no llegó el mensaje")
print("schema id del mensaje:", int.from_bytes(m.value()[1:5], "big"))
for name, s in (("lector con el contrato v1", v1), ("lector con el contrato v2", v2)):
    print(name, "->", AvroDeserializer(reg, s)(m.value(), ctx))
c.close()' "pricing.state.$e.v1" "$(cat streams/tarifas/zone-tariff-state/schemas/v1.avsc)" "$(cat tests/contracts/zone-tariff-state-v2-compatible.avsc)" 2>&1) || rc=$?
  { hdr "08 · Evolución compatible v1 -> v2 (FULL_TRANSITIVE)" "Stream desechable pricing.state.$e.v1: claim v1, luego contract.version: 2 (maxSessionMinutes opcional con default)"
    echo "Claim con contrato v2 registrado en: ${ms} ms"
    k -n team-tarifas get eventstreamclaim "$e-state" -o wide; k -n team-tarifas get jobs -l "parkglobal.io/stream=$e-state"
    echo; echo "Versiones del subject: $vers"
    echo; echo "## Un productor escribe con v2; dos lectores leen el mismo mensaje"; echo "$out"
    echo; echo "## Comprobaciones"
    check "El registry aceptó la v2 ([1,2])" eq "$vers" "[1,2]"
    check "El claim reporta contractVersion=v2 y contractRegistered=true" v2ok
    check "El productor publicó con v2 sin autorregistro" eq "$rc" 0
    check "El lector v1 lee el mensaje v2 sin el campo nuevo" bash -c "grep 'contrato v1' <<<\"\$1\" | grep -q \"'currency': 'SEK'\" && ! grep 'contrato v1' <<<\"\$1\" | grep -q maxSessionMinutes" _ "$out"
    check "El lector v2 ve maxSessionMinutes=240" bash -c "grep 'contrato v2' <<<\"\$1\" | grep -q \"'maxSessionMinutes': 240\"" _ "$out"
  } | tee "$EV/08-evolucion-v2.txt"
  kpi v2_ms "$ms"
  drop_stream "$e"
}

s09() { # Sin autorregistro: un productor con un contrato no registrado no puede publicar (y no pierde eventos)
  local price m1 m2 logs drained
  price=$(( 30000 + RANDOM % 9000 ))
  k -n team-tarifas create configmap rogue-contract \
    --from-file=zone-tariff-state.avsc=tests/contracts/zone-tariff-state-v2-breaking.avsc --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n team-tarifas patch deploy tarifas --type=json -p '[
    {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"rogue","configMap":{"name":"rogue-contract"}}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"rogue","mountPath":"/rogue"}},
    {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"CONTRACTS_DIR","value":"/rogue"}}]' >/dev/null
  k -n team-tarifas rollout status deploy/tarifas --timeout=180s >/dev/null
  api team-tarifas tarifas PUT /tariffs/SE:4021 "{\"maxDailyPriceMinor\": $price}" >/dev/null
  failing() { api team-tarifas tarifas GET /metrics | jq -e '.publish_errors > 0 and .tariffs_outbox_pending > 0'; }
  poll 30 failing >/dev/null || true
  m1=$(api team-tarifas tarifas GET /metrics)
  logs=$(k -n team-tarifas logs deploy/tarifas --tail=20 | grep -E "no se pudo publicar" | tail -2)
  k -n team-tarifas rollout undo deploy/tarifas >/dev/null
  k -n team-tarifas rollout status deploy/tarifas --timeout=180s >/dev/null
  k -n team-tarifas delete configmap rogue-contract >/dev/null
  arrived() { [ "$(api team-consumidor-c consumidor-c GET /cities/SE-STO | jq --arg k SE:4021 '.zones[]|select(.zoneKey==$k)|.tariff.maxDailyPriceMinor')" = "$price" ]; }
  drained=$(poll 90 arrived) || drained=-1
  m2=$(api team-tarifas tarifas GET /metrics)
  { hdr "09 · Sin autorregistro (auto.register.schemas=false)" "Tarifas desplegado con un contrato que el registry no conoce; PUT SE:4021 maxDailyPriceMinor=$price"
    echo "$logs"
    echo; echo "## El evento NO se pierde: queda en el outbox"; echo "$m1"
    echo; echo "## Tras volver al contrato registrado: el relay publica lo pendiente (estado durable del productor, PVC)"
    echo "$m2" | grep -E 'published|pending'
    echo "El precio $price llegó al Consumidor C ${drained} ms después de restaurar"
    echo; echo "## Comprobaciones"
    check "El serializador rechaza el contrato no registrado (40403)" has "$logs" 40403
    check "El evento queda pendiente en el outbox" ge "$(jq .tariffs_outbox_pending <<<"$m1")" 1
    check "Tras restaurar, el outbox queda vacío" eq "$(jq .tariffs_outbox_pending <<<"$m2")" 0
    check "El cambio retenido llega al Consumidor C" ge "$drained" 0
  } | tee "$EV/09-sin-autorregistro.txt"
}

s10() { # Guardrails de admisión (segunda barrera de Kyverno)
  local f rule out
  { hdr "10 · Kyverno en la admisión" "kubectl apply --dry-run=server de claims inválidos y de uno válido"
    for f in cost-center:cost-center-registered domain:domain-belongs-to-owner namespace:namespace-is-team-namespace pii:deny-pii; do
      rule=${f#*:}; f=tests/fixtures/invalid-stream-${f%%:*}.yaml
      out=$(k apply --dry-run=server -f "$f" 2>&1) && echo "  ACEPTADO (error)" || true
      echo "## $f"; grep -v '^\s*$' <<<"$out" | sed 's/^/  /'; echo
      echo "$out" > "$TMP/$rule"
    done
    echo "## tests/fixtures/valid-stream.yaml"; out=$(k apply --dry-run=server -f tests/fixtures/valid-stream.yaml 2>&1) || true; echo "  $out"
    echo; echo "## Comprobaciones"
    for rule in cost-center-registered domain-belongs-to-owner namespace-is-team-namespace deny-pii; do
      check "Rechazado por la regla $rule" grep -q "$rule:" "$TMP/$rule"
    done
    check "Un claim válido se admite" has "$out" "created (server dry run)"
  } | tee "$EV/10-kyverno-admision.txt"
}

s11() { # Lead time: de claim a stream gobernado listo, con varias muestras y desglose por hito
  local i e d t topic contract ready j all=()
  echo "timestamp,stream,topico_ms,contrato_ms,ready_ms" > "$EV/lead-time-streams.csv"
  { hdr "11 · Lead time del Golden Path de eventos" "$LEAD_SAMPLES streams nuevos: desde aplicar el claim hasta cada hito (sin contar el CI del PR)"
    printf '%-22s %10s %12s %10s\n' stream topico_ms contrato_ms ready_ms
    for i in $(seq 1 "$LEAD_SAMPLES"); do
      e=lead-$(date +%H%M%S)-$i; d=$TMP/$e; topic=pricing.state.$e.v1
      make_stream "$d" "$e" 1 streams/tarifas/zone-tariff-state/schemas/v1.avsc
      t=$(now); local tp= ct= rd=
      k apply --server-side -n team-tarifas -k "$d" >/dev/null
      for _ in $(seq 1 600); do
        [ -z "$tp" ] && [ "$(k -n kafka get kafkatopic "$topic" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && tp=$(( $(now) - t ))
        j=$(k -n team-tarifas get eventstreamclaim "$e-state" -o json)
        [ -z "$ct" ] && [ "$(jq -r .status.contractRegistered <<<"$j")" = true ] && ct=$(( $(now) - t ))
        jq -e 'any(.status.conditions[]?; .type=="Ready" and .status=="True")' <<<"$j" >/dev/null && { rd=$(( $(now) - t )); break; }
        sleep 0.3
      done
      printf '%-22s %10s %12s %10s\n' "$e" "${tp:--}" "${ct:--}" "${rd:--}"
      echo "$(date -u +%FT%TZ),$e,${tp:-},${ct:-},${rd:-}" >> "$EV/lead-time-streams.csv"
      [ -n "$rd" ] && all+=("$rd")
      if [ "$i" = 1 ]; then
        echo; k -n team-tarifas get eventstreamclaim "$e-state" -o wide; k -n kafka get kafkatopic "$topic"; k -n team-zonas get cm "$topic-client"; echo
      fi
      drop_stream "$e"
    done
    local sorted; sorted=$(printf '%s\n' "${all[@]}" | sort -n)
    echo
    echo "Claim Ready: mínimo $(head -1 <<<"$sorted") ms · mediana $(sed -n "$(( (${#all[@]} + 1) / 2 ))p" <<<"$sorted") ms · máximo $(tail -1 <<<"$sorted") ms"
    echo "El tópico y el contrato quedan listos en segundos. El Ready del claim es bimodal (unos 5 s o unos 35 s) porque"
    echo "provider-kubernetes observa el estado del KafkaTopic por sondeo: a veces lo ve al instante y a veces en el siguiente ciclo."
    echo; echo "## Comprobaciones"
    check "Las $LEAD_SAMPLES muestras quedaron Ready" eq "${#all[@]}" "$LEAD_SAMPLES"
    check "Todas en menos de 60 s" le "$(tail -1 <<<"$sorted")" 59999
    echo "$sorted" > "$TMP/lead"
  } | tee "$EV/11-lead-time.txt"
  local s; s=$(sed -n 's/^Claim Ready: mínimo \([0-9]*\) ms · mediana \([0-9]*\) ms · máximo \([0-9]*\) ms$/\1 \2 \3/p' "$EV/11-lead-time.txt")
  set -- $s; kpi lead_min_ms "${1:-}"; kpi lead_med_ms "${2:-}"; kpi lead_max_ms "${3:-}"; kpi lead_samples "$LEAD_SAMPLES"
}

all=(01 02 03 04 05 06 07 08 09 10 11)
sel=("${@:-${all[@]}}")
[ $# -gt 0 ] || : > "$EV/kpis.env"   # ejecución completa: cifras nuevas
for SCEN in "${sel[@]}"; do
  log "Escenario $SCEN"
  "s$SCEN"
done
pass=$(grep -c '^PASS' "$RESULTS" || true); fail=$(grep -c '^FAIL' "$RESULTS" || true)
{ echo "# Resumen de events-demo.sh · $(date -u +%FT%TZ) · escenarios: ${sel[*]}"
  echo "# $pass comprobaciones correctas, $fail fallidas"; echo
  awk -F'|' '{printf "%s  %s  %s\n", ($1=="PASS"?"✔":"✘"), $2, $3}' "$RESULTS"
} | tee "$EV/resumen.txt"
log "Evidencia en $EV/ · $pass ✔ · $fail ✘"
[ "$fail" -eq 0 ]
