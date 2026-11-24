#!/usr/bin/env python3
"""Servicios de demostración del caso Tarifas -> Zonas -> Consumidor C con ECST (Proyecto 2).

Un solo programa, tres roles (variable APP):
  tarifas       Dueño de pricing.state.zone-tariff.v1. Guarda la tarifa y la fila de outbox en UNA transacción;
                un relay publica tras el commit (sin sleep de 5 s). Expone la "API de Tarifas" solo para medir
                que nadie la llama por un cambio.
  zonas         Dueño de topology.state.zone.v1 (zona con referencia cityId) y consumidor de tarifas:
                mantiene una vista local y responde sin llamar a Tarifas ni a Core.
  consumidor-c  Consume ambos streams y arma en local la jerarquía Ciudad -> Zonas -> Tarifa (opción A+);
                decide su tipo de carga y su nivel de comisión sin llamadas síncronas.

Lo que el desarrollador NO configura: bootstrap, URL del registry, nombre del tópico, subject, serializadores ni
política de compatibilidad. Todo llega en el ConfigMap <tópico>-client que crea la plataforma (envFrom con prefijo).
El código solo conoce su contrato (contracts/*.avsc, copia de la versión registrada) y su lógica de negocio.
"""
import datetime as dt
import json
import logging
import os
import re
import signal
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from confluent_kafka import OFFSET_BEGINNING, Consumer, KafkaError, Producer
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroDeserializer, AvroSerializer
from confluent_kafka.serialization import MessageField, SerializationContext

APP = os.environ.get("APP", "tarifas")
DATA = os.environ.get("DATA_DIR", "/data")
CONTRACTS = os.environ.get("CONTRACTS_DIR", os.path.join(os.path.dirname(__file__), "contracts"))
logging.basicConfig(level=logging.INFO, format=f"%(asctime)s {APP} %(levelname)s %(message)s", stream=sys.stdout)
log = logging.getLogger(APP)
logging.getLogger("httpx").setLevel(logging.WARNING)

METRICS = {"api_calls_received": 0, "events_published": 0, "events_consumed": 0, "stale_or_duplicate_skipped": 0,
           "tombstones_applied": 0, "publish_errors": 0, "poison_messages_skipped": 0}
LATENCIES_MS: list[int] = []
LOCK = threading.Lock()
STOP = threading.Event()
WORKERS: list[threading.Thread] = []


def now_ms() -> int:
    return int(time.time() * 1000)


def stream_conf(prefix: str) -> dict:
    """Configuración que entrega la plataforma (ConfigMap <tópico>-client, inyectado con envFrom + prefix)."""
    keys = ["KAFKA_BOOTSTRAP_SERVERS", "SCHEMA_REGISTRY_URL", "TOPIC", "SUBJECT", "KEY_PATTERN",
            "SERDE_AUTO_REGISTER_SCHEMAS", "SERDE_USE_LATEST_VERSION", "CONSUMER_GROUP_PREFIX", "CONSUMER_AUTO_OFFSET_RESET"]
    return {k: os.environ.get(prefix + k, "") for k in keys}


def registry_client(cfg: dict) -> SchemaRegistryClient:
    # Sin timeout, el cliente espera para siempre una respuesta perdida y bloquea el relay o el consumidor.
    return SchemaRegistryClient({"url": cfg["SCHEMA_REGISTRY_URL"], "timeout": 10})


def to_json(o):
    if isinstance(o, (dt.datetime, dt.date)):
        return o.isoformat()
    raise TypeError(type(o))


def ts_ms(v) -> int:
    return int(v.timestamp() * 1000) if isinstance(v, dt.datetime) else int(v)


def db() -> sqlite3.Connection:
    os.makedirs(DATA, exist_ok=True)
    c = sqlite3.connect(os.path.join(DATA, f"{APP}.db"), check_same_thread=False, isolation_level=None)
    c.execute("PRAGMA journal_mode=WAL")
    return c


DB = db()
DB_LOCK = threading.RLock()


def q(sql: str, args: tuple = ()) -> list:
    """Lectura con el lock: la conexión SQLite se comparte entre el servidor HTTP, el relay y los consumidores."""
    with DB_LOCK:
        return DB.execute(sql, args).fetchall()


# ----------------------------------------------------------------------------------------------- productor + outbox
class OutboxPublisher:
    """Outbox transaccional: el estado y el evento se guardan en la misma transacción; el relay publica tras el commit."""

    def __init__(self, prefix: str, entity_table: str, schema_file: str):
        self.cfg = stream_conf(prefix)
        self.table = entity_table
        self.key_re = re.compile(self.cfg["KEY_PATTERN"] or ".*")
        sr = registry_client(self.cfg)
        schema = open(os.path.join(CONTRACTS, schema_file)).read()
        # Sin autorregistro: si el contrato de este binario no está registrado, no se publica (y no se pierde: queda en outbox).
        self.serializer = AvroSerializer(sr, schema, conf={
            "auto.register.schemas": self.cfg["SERDE_AUTO_REGISTER_SCHEMAS"] == "true",
            "use.latest.version": self.cfg["SERDE_USE_LATEST_VERSION"] == "true"})
        self.producer = Producer({"bootstrap.servers": self.cfg["KAFKA_BOOTSTRAP_SERVERS"], "acks": "all",
                                  "enable.idempotence": True, "linger.ms": 5})
        with DB_LOCK:
            DB.execute(f"CREATE TABLE IF NOT EXISTS {self.table} (k TEXT PRIMARY KEY, version INTEGER, doc TEXT)")
            DB.execute(f"CREATE TABLE IF NOT EXISTS outbox_{self.table} (id INTEGER PRIMARY KEY AUTOINCREMENT, k TEXT, "
                       "doc TEXT, created_ms INTEGER, published_ms INTEGER)")
        threading.Thread(target=self.relay, daemon=True).start()

    def upsert(self, key: str, changes: dict, defaults: dict) -> dict:
        if not self.key_re.fullmatch(key):
            raise ValueError(f"clave {key!r} no cumple {self.cfg['KEY_PATTERN']}")
        with DB_LOCK:
            DB.execute("BEGIN IMMEDIATE")
            try:
                row = DB.execute(f"SELECT version, doc FROM {self.table} WHERE k=?", (key,)).fetchone()
                # Tras una baja (doc NULL) se conserva la versión: sigue siendo monotónica aunque un consumidor
                # se haya perdido el tombstone (caído más que delete.retention.ms).
                state = json.loads(row[1]) if row and row[1] else dict(defaults)
                state.update({k: v for k, v in changes.items() if k in defaults})
                state["version"] = (row[0] if row else 0) + 1
                state["updatedAt"] = now_ms()
                doc = json.dumps(state)
                DB.execute(f"INSERT INTO {self.table}(k, version, doc) VALUES(?,?,?) "
                           "ON CONFLICT(k) DO UPDATE SET version=excluded.version, doc=excluded.doc", (key, state["version"], doc))
                DB.execute(f"INSERT INTO outbox_{self.table}(k, doc, created_ms) VALUES(?,?,?)", (key, doc, now_ms()))
                DB.execute("COMMIT")
            except Exception:
                DB.execute("ROLLBACK")
                raise
        return state

    def delete(self, key: str) -> bool:
        with DB_LOCK:
            DB.execute("BEGIN IMMEDIATE")
            n = DB.execute(f"UPDATE {self.table} SET doc=NULL WHERE k=? AND doc IS NOT NULL", (key,)).rowcount
            if n:
                DB.execute(f"INSERT INTO outbox_{self.table}(k, doc, created_ms) VALUES(?,?,?)", (key, None, now_ms()))
            DB.execute("COMMIT")
        return bool(n)

    def get(self, key: str):
        rows = q(f"SELECT doc FROM {self.table} WHERE k=?", (key,))
        return json.loads(rows[0][0]) if rows and rows[0][0] else None

    def pending(self) -> int:
        return q(f"SELECT count(*) FROM outbox_{self.table} WHERE published_ms IS NULL")[0][0]

    def relay(self):
        topic = self.cfg["TOPIC"]
        while True:
            rows = q(f"SELECT id, k, doc FROM outbox_{self.table} WHERE published_ms IS NULL ORDER BY id LIMIT 200")
            if not rows:
                time.sleep(0.2)
                continue
            delivered = []
            try:
                for oid, key, doc in rows:
                    value = None if doc is None else self.serializer(json.loads(doc), SerializationContext(topic, MessageField.VALUE))
                    self.producer.produce(topic, key=key.encode(), value=value,
                                          on_delivery=lambda err, msg, oid=oid: (delivered.append(oid) if err is None else log.error("entrega fallida: %s", err)))
                self.producer.flush(10)
            except Exception as e:  # noqa: BLE001 - p. ej. contrato no registrado: el evento queda en el outbox, no se pierde
                with LOCK:
                    METRICS["publish_errors"] += 1
                log.error("no se pudo publicar (el evento sigue en el outbox): %s", e)
                time.sleep(3)
            if delivered:
                with DB_LOCK:
                    DB.executemany(f"UPDATE outbox_{self.table} SET published_ms=? WHERE id=?", [(now_ms(), i) for i in delivered])
                with LOCK:
                    METRICS["events_published"] += len(delivered)
                log.info("publicados %d evento(s) en %s", len(delivered), topic)


# ------------------------------------------------------------------------------------------------ consumidor ECST
class StateView:
    """Vista local alimentada por un stream de estado: upsert idempotente por versión; tombstone = borrar."""

    def __init__(self, prefix: str, table: str):
        self.cfg = stream_conf(prefix)
        self.table = table
        with DB_LOCK:
            DB.execute(f"CREATE TABLE IF NOT EXISTS {table} (k TEXT PRIMARY KEY, version INTEGER, doc TEXT)")
        sr = registry_client(self.cfg)
        self.deser = AvroDeserializer(sr)  # usa el esquema del escritor (id en el mensaje): lee cualquier versión compatible
        group = f"{self.cfg['CONSUMER_GROUP_PREFIX']}.{os.environ.get('GROUP_SUFFIX', 'view')}"
        self.consumer = Consumer({"bootstrap.servers": self.cfg["KAFKA_BOOTSTRAP_SERVERS"], "group.id": group,
                                  "auto.offset.reset": self.cfg["CONSUMER_AUTO_OFFSET_RESET"] or "earliest",
                                  "enable.auto.commit": False})
        # Vista desechable: si arranca vacía (pod nuevo, almacenamiento efímero), los offsets confirmados del grupo NO sirven:
        # hay que releer el tópico compactado desde el offset 0. Sin esto, la vista queda incompleta para siempre.
        # La asignación puede llegar en varias llamadas (rebalanceo incremental): la relectura se decide POR PARTICIÓN.
        self.rebuild = not q(f"SELECT count(*) FROM {table}")[0][0]
        self.rewound: set[int] = set()

        def on_assign(consumer, partitions):
            fresh = [p for p in partitions if self.rebuild and p.partition not in self.rewound]
            for p in fresh:
                p.offset = OFFSET_BEGINNING
                self.rewound.add(p.partition)
            if fresh:
                log.info("vista local vacía: relectura de %s particiones %s desde el offset 0",
                         self.cfg["TOPIC"], [p.partition for p in fresh])
            consumer.assign(partitions)

        self.consumer.subscribe([self.cfg["TOPIC"]], on_assign=on_assign)
        log.info("consumiendo %s con el grupo %s", self.cfg["TOPIC"], group)
        t = threading.Thread(target=self.loop, daemon=True)
        WORKERS.append(t)
        t.start()

    def loop(self):
        while not STOP.is_set():
            msg = self.consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() != KafkaError._PARTITION_EOF:
                    log.warning("kafka: %s", msg.error())
                continue
            try:
                key = msg.key().decode()
                value = self.deser(msg.value(), SerializationContext(msg.topic(), MessageField.VALUE)) if msg.value() else None
            except Exception as e:  # noqa: BLE001 - mensaje ilegible (sin clave, bytes que no son Avro, esquema desconocido)
                # Sin esto, un solo mensaje malo mata el hilo y la vista deja de actualizarse sin que nadie lo note.
                # Se registra y se salta: la siguiente foto de esa clave repara la vista (ECST). Fase 2: DLQ.
                log.error("mensaje ilegible en %s[%d]@%d, se omite: %s", msg.topic(), msg.partition(), msg.offset(), e)
                with LOCK:
                    METRICS["poison_messages_skipped"] += 1
                self.consumer.commit(msg, asynchronous=False)
                continue
            with DB_LOCK:
                if value is None:
                    DB.execute(f"DELETE FROM {self.table} WHERE k=?", (key,))
                    with LOCK:
                        METRICS["tombstones_applied"] += 1
                else:
                    row = DB.execute(f"SELECT version FROM {self.table} WHERE k=?", (key,)).fetchone()
                    if row and row[0] >= value["version"]:
                        with LOCK:
                            METRICS["stale_or_duplicate_skipped"] += 1
                    else:
                        DB.execute(f"INSERT INTO {self.table}(k, version, doc) VALUES(?,?,?) ON CONFLICT(k) DO UPDATE "
                                   "SET version=excluded.version, doc=excluded.doc", (key, value["version"], json.dumps(value, default=to_json)))
                        # SLO extremo a extremo (commit en el productor -> vista local), solo para eventos en vivo:
                        # en una relectura desde el offset 0 el updatedAt es histórico y no mide la entrega.
                        if now_ms() - msg.timestamp()[1] < 10_000:
                            with LOCK:
                                LATENCIES_MS.append(now_ms() - ts_ms(value["updatedAt"]))
                                del LATENCIES_MS[:-500]
            self.consumer.commit(msg, asynchronous=False)
            with LOCK:
                METRICS["events_consumed"] += 1
        self.consumer.close()
        log.info("consumidor de %s cerrado (salida ordenada del grupo)", self.cfg["TOPIC"])

    def all(self) -> dict:
        return {k: json.loads(d) for k, d in q(f"SELECT k, doc FROM {self.table}")}

    def get(self, key):
        rows = q(f"SELECT doc FROM {self.table} WHERE k=?", (key,))
        return json.loads(rows[0][0]) if rows else None


# ------------------------------------------------------------------------------------------------ roles
TARIFF_DEFAULTS = {"zoneKey": "", "countryCode": "", "zoneNo": 0, "version": 0, "status": "ACTIVE", "timezone": "UTC",
                   "currency": "EUR", "validFrom": 0, "validTo": None, "parkingTypesByChannel": {"APP": ["STREET"]},
                   "parkingFree": False, "maxDailyPriceMinor": None, "updatedAt": 0}
ZONE_DEFAULTS = {"zoneKey": "", "countryCode": "", "zoneNo": 0, "version": 0, "name": "", "cityId": "", "cityName": "",
                 "status": "ACTIVE", "timezone": "UTC", "updatedAt": 0}
SEED_ZONES = [  # (zona, ciudad, nombre de ciudad, nombre de zona, zona horaria, moneda, gratis, precio máx. diario)
    ("SE:4021", "SE-STO", "Stockholm", "Södermalm Norte", "Europe/Stockholm", "SEK", False, 12000),
    ("SE:4022", "SE-STO", "Stockholm", "Södermalm Sur", "Europe/Stockholm", "SEK", True, None),
    ("SE:5101", "SE-GOT", "Göteborg", "Centrum", "Europe/Stockholm", "SEK", False, 9000),
    ("CO:1101", "CO-BOG", "Bogotá", "Chapinero", "America/Bogota", "COP", False, 2500000),
    ("CO:1102", "CO-BOG", "Bogotá", "Usaquén", "America/Bogota", "COP", False, 1800000),
]


def key_parts(key: str) -> dict:
    cc, no = key.split(":")
    return {"zoneKey": key, "countryCode": cc, "zoneNo": int(no)}


def build_roles():
    roles = {}
    if APP == "tarifas":
        pub = OutboxPublisher("TARIFFS_", "tariffs", "zone-tariff-state.avsc")
        if not q("SELECT count(*) FROM tariffs")[0][0]:
            for key, _, _, _, tz, cur, free, maxp in SEED_ZONES:
                pub.upsert(key, {**key_parts(key), "timezone": tz, "currency": cur, "parkingFree": free, "maxDailyPriceMinor": maxp,
                                 "validFrom": now_ms(), "parkingTypesByChannel": {"APP": ["STREET"], "ANPR": ["GATED"]}}, TARIFF_DEFAULTS)
        roles["tariffs"] = pub
    if APP == "zonas":
        pub = OutboxPublisher("ZONES_", "zones", "zone-state.avsc")
        if not q("SELECT count(*) FROM zones")[0][0]:
            for key, city, cname, zname, tz, *_ in SEED_ZONES:
                pub.upsert(key, {**key_parts(key), "name": zname, "cityId": city, "cityName": cname, "timezone": tz}, ZONE_DEFAULTS)
        roles["zones"] = pub
        roles["tariff_view"] = StateView("TARIFFS_", "tariff_view")
    if APP == "consumidor-c":
        roles["tariff_view"] = StateView("TARIFFS_", "tariff_view")
        roles["zone_view"] = StateView("ZONES_", "zone_view")
    return roles


def decide(tariff: dict | None) -> dict:
    """Lógica del Consumidor C (diap. 3): tipo de carga y nivel de comisión, solo con datos locales."""
    if not tariff:
        return {"chargeType": "SIN_TARIFA", "commissionTier": None}
    charge = "SOLO_CARGA" if tariff["parkingFree"] else "APARCAMIENTO_MAS_CARGA"
    tier = "ALTA" if (tariff.get("maxDailyPriceMinor") or 0) >= 10000 and tariff["currency"] == "SEK" else "ESTANDAR"
    return {"chargeType": charge, "commissionTier": tier}


def city_view(roles, city_id=None):
    zones, tariffs = roles["zone_view"].all(), roles["tariff_view"].all()
    cities: dict = {}
    for key, z in sorted(zones.items()):
        c = cities.setdefault(z["cityId"], {"cityId": z["cityId"], "cityName": z["cityName"], "zones": []})
        t = tariffs.get(key)
        c["zones"].append({"zoneKey": key, "name": z["name"], "status": z["status"], "zoneVersion": z["version"],
                           "tariff": None if not t else {k: t[k] for k in ("version", "currency", "parkingFree", "maxDailyPriceMinor", "status")},
                           "decision": decide(t)})
    orphan = sorted(set(tariffs) - set(zones))  # tarifa llegó antes que su zona: se guarda y se une cuando llegue
    if city_id:
        return cities.get(city_id)
    return {"cities": list(cities.values()), "tariffsWaitingForZone": orphan}


def metrics(roles):
    with LOCK:
        m = dict(METRICS)
        lat = sorted(LATENCIES_MS)
    if lat:
        pct = lambda q: lat[min(len(lat) - 1, int(len(lat) * q))]
        m["e2e_latency_ms"] = {"samples": len(lat), "p50": pct(.5), "p95": pct(.95), "p99": pct(.99), "max": lat[-1]}
    for name, r in roles.items():
        if isinstance(r, OutboxPublisher):
            m[f"{name}_outbox_pending"] = r.pending()
        if isinstance(r, StateView):
            m[f"{name}_size"] = len(r.all())
    m["app"] = APP
    return m


def serve(roles):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, body):
            data = json.dumps(body, default=to_json, ensure_ascii=False, indent=2).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def body(self):
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n) or b"{}")

        def route(self, method):
            p = self.path.rstrip("/")
            try:
                if p == "/metrics":
                    return self.send(200, metrics(roles))
                if p == "/metrics/latency" and method == "DELETE":
                    with LOCK:
                        LATENCIES_MS.clear()  # abre una ventana de medición limpia del SLO
                    return self.send(200, {"latency_window": "reset"})
                if p == "/healthz":
                    return self.send(200, {"ok": True})
                if APP == "tarifas" and p.startswith("/tariffs/"):
                    key, pub = p.split("/")[2], roles["tariffs"]
                    if method == "GET":
                        with LOCK:
                            METRICS["api_calls_received"] += 1  # la "API de Tarifas" de la diap. 3
                        t = pub.get(key)
                        return self.send(200 if t else 404, t or {"error": "no existe"})
                    if method == "PUT":
                        return self.send(200, pub.upsert(key, {**self.body(), **key_parts(key)}, TARIFF_DEFAULTS))
                    if method == "DELETE":
                        return self.send(200 if pub.delete(key) else 404, {"tombstone": key})
                if APP == "zonas" and p.startswith("/zones/"):
                    key = p.split("/")[2]
                    if method == "GET":
                        z = roles["zones"].get(key)
                        # Respuesta compuesta SOLO con datos locales: cero llamadas a Tarifas, Core o la caché.
                        return self.send(200 if z else 404, {"zone": z, "tariff": roles["tariff_view"].get(key)})
                    if method == "PUT":
                        return self.send(200, roles["zones"].upsert(key, {**self.body(), **key_parts(key)}, ZONE_DEFAULTS))
                    if method == "DELETE":
                        return self.send(200 if roles["zones"].delete(key) else 404, {"tombstone": key})
                if APP == "consumidor-c" and p.startswith("/cities"):
                    parts = p.split("/")
                    v = city_view(roles, parts[2] if len(parts) > 2 else None)
                    return self.send(200 if v else 404, v or {"error": "ciudad sin zonas"})
                return self.send(404, {"error": "ruta no encontrada", "app": APP})
            except ValueError as e:
                return self.send(400, {"error": str(e)})

        def do_GET(self):
            self.route("GET")

        def do_PUT(self):
            self.route("PUT")

        def do_DELETE(self):
            self.route("DELETE")

    port = int(os.environ.get("PORT", "8000"))
    log.info("HTTP en :%d", port)
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()


def shutdown(signum, _frame):
    """SIGTERM de Kubernetes: cerrar consumidores para que el grupo rebalancee de inmediato."""
    log.info("señal %s: cerrando", signum)
    STOP.set()
    for t in WORKERS:
        t.join(timeout=10)
    os._exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, shutdown)
    serve(build_roles())
