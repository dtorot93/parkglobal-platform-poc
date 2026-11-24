# ADR-007 · Un tópico de estado por entidad, con un solo dueño; jerarquía por referencia

**Estado:** aceptada (2026-11-21) · **Sección:** Proyecto 2, I y IV

## Contexto

La propuesta inicial era un contrato único para **Ciudad**, con sus Zonas y Tarifas anidadas, y "propagar hacia la Ciudad" cada cambio en una Zona o una Tarifa. En ParkGlobal la tarifa pertenece a Tarifas y la zona a Zonas/Core (diapositivas 3-4).

## Decisión

1. **Un tópico compactado por entidad**, `<dominio>.state.<entidad>.v<major>`, con **un único equipo escritor** por dominio. Kyverno lo exige al **declarar** el stream, con la política `eventstream-domain-ownership` y el ConfigMap `event-domains`. En la PoC el bus no tiene autenticación ni ACL: Kyverno controla quién **declara** un stream, no quién escribe en el tópico. En ParkGlobal la escritura se restringe con las ACLs como código que ya existen (diapositiva 2), derivadas del dueño del claim.
   - `pricing.state.zone-tariff.v1`: dueño Tarifas.
   - `topology.state.zone.v1`: dueño Zonas, con `cityId` y `cityName`.
2. **La jerarquía Ciudad → Zona → Tarifa se expresa por referencia** (`zoneKey`, `cityId`), no por anidamiento. Cada consumidor la compone en su vista local; el Consumidor C lo demuestra (`GET /cities`).
3. **La clave del mensaje es la identidad de la entidad** (`<countryCode>:<zoneNo>`): da orden por zona, compactación (una foto por zona) y relectura desde el offset 0.

## Por qué no el agregado Ciudad

| Criterio | Tópico por entidad | Ciudad anidada |
|---|---|---|
| Un solo escritor por clave | Sí | No: o escritores parciales (gana el último y se pierde estado) o un agregador que recrea el intermediario (Core) |
| Tamaño del mensaje | Una zona | Toda la ciudad; riesgo con `message.max.bytes` (~1 MB) |
| Amplificación de escritura | 1 tarifa → 1 evento | 1 tarifa → republicar la ciudad entera |
| Orden y particiones | Por zona; carga repartida | Por ciudad; partición caliente en ciudades grandes |
| Concurrencia | Sin bloqueo | Leer, modificar y reescribir con bloqueo por ciudad |
| Evolución | Independiente por dominio | Un cambio de tarifa versiona el contrato de ciudades |
| Patrón | ECST (estado) | Riesgo de deltas o de cadena de eventos (Nivel 2 de la rúbrica) |

Una vista de ciudad desnormalizada es legítima como **read model derivado** para un consumidor concreto, construido con stream processing. Esa capacidad está en el Nivel 2 de madurez y fuera de la TVP.

## Consecuencias

- Consistencia eventual por clave, garantizada por: orden por partición, `version` monotónica más upsert idempotente, tombstone para las bajas y `delete.retention.ms` = 7 días (un consumidor caído más tiempo debe releer desde cero).
- Entre entidades se tolera el desorden: una tarifa que llega antes que su zona se guarda y se une cuando llega la zona (`tariffsWaitingForZone`).
- El número de particiones es fijo tras la creación (perfil semántico). Cambiarlo rompería el mapeo clave → partición y, con él, el orden.
