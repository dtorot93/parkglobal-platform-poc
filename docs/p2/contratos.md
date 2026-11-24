# Contratos de datos de los streams piloto (listos para registrar)

Los archivos **son** los contratos: `streams/<team>/<stream>/schemas/vN.avsc`. La plataforma los registra en Apicurio por la API compatible con Confluent, en el subject `<tópico>-value`, con FULL_TRANSITIVE. Para registrarlos a mano (por ejemplo, en otro registry):

```bash
curl -X PUT  -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
  $REGISTRY/apis/ccompat/v7/config/pricing.state.zone-tariff.v1-value -d '{"compatibility":"FULL_TRANSITIVE"}'
jq -n --rawfile s streams/tarifas/zone-tariff-state/schemas/v1.avsc '{schema:$s, schemaType:"AVRO"}' | \
curl -X POST -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
  $REGISTRY/apis/ccompat/v7/subjects/pricing.state.zone-tariff.v1-value/versions -d @-
```

## 1. `ZoneTariffState` · `pricing.state.zone-tariff.v1`

| Nivel | Contenido |
|---|---|
| **Técnico** | Avro, record `io.parkglobal.pricing.state.ZoneTariffState` · [v1.avsc](../../streams/tarifas/zone-tariff-state/schemas/v1.avsc) |
| Clave | `<countryCode>:<zoneNo>` (string, regex `^[A-Z]{2}:[0-9]+$`) |
| Semántica | Foto **completa** del estado público de la tarifa de una zona. Valor nulo = tombstone (la zona dejó de tener tarifa) |
| **Sociotécnico** | Dueño: `team-tarifas` (único escritor del dominio `pricing`) · Consumidores declarados: `team-zonas`, `team-consumidor-c` · SLO: p99 < 5 s extremo a extremo · Sin PII · Retención: compactada, tombstones visibles 7 días · Centro de costo: CC-PRC-01 |
| Proceso de cambio | PR al stream con `schemas/vN+1.avsc`; el CI prueba FULL_TRANSITIVE. Un cambio incompatible va a `.v2` con doble publicación y plazo de retirada; el catálogo dice a quién avisar |

| Campo | Tipo Avro | ¿Opcional? | Nota |
|---|---|---|---|
| zoneKey | string | no | = clave del mensaje |
| countryCode | string | no | ISO 3166-1 alfa-2 |
| zoneNo | int | no | |
| version | long | no | Monotónica por zona: idempotencia |
| status | enum TariffStatus {ACTIVE, SUSPENDED, UNKNOWN}, default UNKNOWN | no | El default del enum permite agregar símbolos |
| timezone | string | no | IANA |
| currency | string | no | ISO 4217 · **el campo del ejemplo de la diapositiva 6** |
| validFrom | long (timestamp-millis) | no | |
| validTo | null \| timestamp-millis, default null | sí | |
| parkingTypesByChannel | map<array<enum ParkingType>> | no | Lo que hoy Zonas obtiene pasando por Core y la caché |
| parkingFree | boolean | no | Lo usa el Consumidor C para decidir el tipo de carga |
| maxDailyPriceMinor | null \| long, default null | sí | Unidades menores (öre o céntimos), no `double` |
| updatedAt | long (timestamp-millis) | no | Commit en Tarifas; permite medir el SLO |

Diferencias con el borrador de la diapositiva 5, todas justificadas: formato Avro (ADR-005); `maxDailyPrice: 120.0` pasa a `maxDailyPriceMinor: 12000` (sin coma flotante en dinero); se agregan `countryCode` y `zoneNo` explícitos (el Consumidor C los pedía a la API de Zonas); los enums tienen default.

## 2. `ZoneState` · `topology.state.zone.v1` (opción A+)

| Nivel | Contenido |
|---|---|
| Técnico | Avro, record `io.parkglobal.topology.state.ZoneState` · [v1.avsc](../../streams/zonas/zone-state/schemas/v1.avsc) |
| Clave | `<countryCode>:<zoneNo>`: la misma identidad que la tarifa, de modo que el consumidor une por clave |
| Jerarquía | `cityId` (referencia) + `cityName` (desnormalizado para no llamar a otra API) |
| Sociotécnico | Dueño: `team-zonas` (dominio `topology`) · Consumidor: `team-consumidor-c` · SLO p99 < 5 s · Sin PII · CC-TOP-01 |

## 3. Política de compatibilidad y cómo protege a los consumidores

**FULL_TRANSITIVE**: cada versión nueva debe poder leer **y** ser leída por **todas** las anteriores.

| Cambio propuesto | Resultado | Qué ve el equipo |
|---|---|---|
| Agregar `maxSessionMinutes: ["null","int"]`, default null (`tests/contracts/zone-tariff-state-v2-compatible.avsc`) | ✅ aceptado | El CI pasa y el Job registra la v2. Demostrado en la evidencia 08: un productor escribe con v2 y un lector con el contrato v1 lee el mismo mensaje sin el campo nuevo (resolución de esquemas de Avro: escritor v2, lector v1) |
| Eliminar `currency` (`tests/contracts/zone-tariff-state-v2-breaking.avsc`) | ❌ rechazado | CI: `INCOMPATIBLE … [currency at /fields/6]`. Si se salta el CI: el registry responde **409**, el claim no queda Ready y un productor que use la configuración de la plataforma no puede serializar con ese esquema (`auto.register.schemas=false`, error 40403; evidencia 09). Kafka no valida los mensajes: un cliente que escriba bytes a mano se salta esta barrera, y por eso el consumidor omite y registra los mensajes ilegibles |
| Agregar un campo sin default | ❌ rechazado | Un lector nuevo no sabría qué valor dar a los mensajes históricos del tópico compactado |
| Agregar un símbolo a un enum con default | ✅ aceptado | Los lectores antiguos lo leen como `UNKNOWN` |

¿Por qué no BACKWARD o FORWARD?

- **BACKWARD** solo protege si los consumidores se despliegan antes que el productor.
- **FORWARD** solo protege si el productor se despliega primero.
- Con varios equipos y cuatro regiones ninguno de esos órdenes se puede garantizar, y con compactación el lector debe entender todo el historial. Por eso FULL y además TRANSITIVE.
