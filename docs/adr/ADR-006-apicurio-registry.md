# ADR-006 · Apicurio Registry como Schema Registry de la plataforma

**Estado:** aceptada (2026-11-21) · **Sección:** Proyecto 2, IV

## Contexto

ParkGlobal tiene un Schema Registry desplegado en una sola región, en una versión de 2018 que solo admite Avro, y ningún productor lo usa (diapositivas 1-2). La rúbrica exige herramientas **open source** para la PoC de gestión de eventos.

## Alternativas

| Opción | Licencia | A favor | En contra |
|---|---|---|---|
| **Apicurio Registry 3.3.4** | Apache-2.0 | API compatible con Confluent (`/apis/ccompat/v7`): los serializadores estándar funcionan sin cambios. API nativa v3 con **etiquetas y metadatos** por artefacto (dueño, PII, SLO, consumidores). Storage SQL: PostgreSQL pedido con el `DatabaseClaim` del P1. Consola web para evidencia. Soporta Avro, JSON Schema, Protobuf, AsyncAPI y OpenAPI. | No replica al 100 % la semántica de Confluent en JSON Schema (irrelevante tras ADR-005). |
| Karapace 6.2.4 | Apache-2.0 | Réplica muy fiel de la API de Confluent. | Persiste en un tópico de Kafka (acopla registry y broker). No tiene metadatos de catálogo ni consola. |
| Confluent Schema Registry | Confluent Community License | Estándar de facto. | **No es open source según la OSI**: incumple el criterio de la rúbrica. |
| AWS Glue Schema Registry | Servicio gestionado | Integración nativa con MSK. | Lock-in, serializadores propios, no es OSS y no sirve en la PoC local. |

## Decisión

**Apicurio Registry 3.3.4** (imagen `apicurio/apicurio-registry:3.3.4`), con storage PostgreSQL. En CI se usa la **misma imagen** como contenedor efímero (en memoria).

## Consecuencias

- Una sola herramienta da contrato, política de compatibilidad y metadatos de gobierno. Cubre los puntos 1 (registry obligatorio) y 2 (catálogo de streams: dueño, SLA, PII) del backlog de madurez (diapositiva 2).
- *Dogfooding*: el Platform Team pide la base del registry con su propio Golden Path (`platform/registry/schema-registry-db.yaml`), con las mismas políticas FinOps.
- Producción: Apicurio en el clúster de gestión, autenticación OIDC (Okta) con roles. Solo la identidad de la plataforma (el Job registrador) puede escribir versiones; las aplicaciones solo leen (`auto.register.schemas=false`).
