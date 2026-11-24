# Alineación con la rúbrica (Proyecto No. 2) y con las responsabilidades de Daniel

**Responsabilidad asignada** (`responsables.xlsx`, Sección IV, «Daniel / Felipe»; en la práctica la ejecutó Daniel): *«Implementación de una capacidad de la Plataforma de Gestión de Eventos: seleccionen una capacidad (ej. Schema Registry, Metadata Tagging, Pluggable Message Brokers), investiguen herramientas Open Source para implementarla y construyan una PoC que demuestre mediante captura de pantalla, video o código cómo reduce la carga cognitiva extrínseca de los desarrolladores.»*

| Requisito del entregable | Cómo se cumple | Evidencia |
|---|---|---|
| Seleccionar una capacidad | **Schema Registry obligatorio + Metadata Tagging** (dueño, PII, SLO y consumidores en el registry y en el catálogo), entregados como Golden Path de autoservicio (`EventStreamClaim`) | `platform/crossplane/xrd-eventstreamclaim.yaml`, `evidence/p2/01` |
| Investigar herramientas OSS | Comparación de Apicurio, Karapace, Confluent SR y Glue (ADR-006); spike empírico JSON Schema vs Avro en dos registries (ADR-005); Strimzi como broker (CNCF) | `docs/adr/ADR-005`, `ADR-006`, `evidence/p2/00` |
| PoC funcional | Clúster kind con Strimzi 1.3.0 (Kafka 4.3.1), Apicurio 3.3.4, Crossplane v2, Kyverno, 3 servicios reales | `evidence/p2/01`–`11` |
| Demostrar la reducción de carga extrínseca | El equipo declara 7 campos obligatorios y su contrato (el formulario tiene 11; 4 con valor por defecto). Ya no decide particiones, compactación, subject, compatibilidad ni serializadores. El código de los equipos hace un `envFrom` por stream (3 líneas). El CI responde con el campo exacto que rompe | `docs/p2/arquitectura-eventos.md` §3.5, `apps/ecst-demo/k8s/*.yaml`, `evidence/p2/07`, `12` |

## Criterio «PoC: Implementación y Evidencia (Gestión de Eventos)» · /20

| Exigencia del Nivel 4 (20 pts) | Cumplimiento |
|---|---|
| «La PoC es altamente funcional» | 11 escenarios reproducibles con `make events-demo` (4 min 21 s). Cada uno comprueba sus afirmaciones: **48 comprobaciones correctas y 0 fallidas** (`evidence/p2/resumen.txt`). Cubren propagación, disponibilidad, relectura, tombstone, jerarquía, 409, evolución v2, sin autorregistro, Kyverno, lead time. El montaje completo se reproduce con `make local-up` |
| «Implementa herramientas Open Source para gestionar eventos (ej. abstracción de mensajería)» | Strimzi, Apicurio, Crossplane, provider-kubernetes y Kyverno (todas OSS). **Abstracción**: el `EventStreamClaim` oculta tópico, compactación, particiones, subject, compatibilidad y serializadores; la plataforma entrega la configuración de cliente a dueño y consumidores |
| «Demuestra de forma irrefutable (video/código) cómo se reduce la carga operativa» | Mediciones: el tópico existe en ~1,3 s y el contrato queda registrado en ~5–7 s; el claim pasa a Ready en **5,0–35,6 s** (5 muestras, mediana 35,5 s; bimodal por el sondeo de provider-kubernetes) (hoy no existe camino gobernado; los tópicos se crean a mano y no hay esquemas). Evolución de contrato en **3,8 s**, demostrada con un productor v2 y un lector v1 sobre el mismo mensaje. Cambio incompatible detectado por el chequeo del CI (ejecutado en local) **antes** de llegar al registry. Configuración de un servicio: un `envFrom` de **3 líneas** por stream |

**GitOps verificado** (`evidence/p2/13-gitops-desde-main.txt`): un clúster nuevo con `make bootstrap` sincroniza desde `main` las 16 Applications (Strimzi, Apicurio, los dos streams generados por el ApplicationSet) en ~9 min; sobre ese clúster los 11 escenarios dan 48/48 comprobaciones (`evidence/p2/gitops/`) y Argo CD revierte un cambio manual de un claim en 1,4 s. **Golden Path completo verificado** con el PR #6 (`stream/parking-rule-state`): CI en verde en 18 s, auto-merge a los 31 s y claim Ready a los **2 min 34 s** de abrir el PR; casi todo ese tiempo es el sondeo de 3 min del ApplicationSet. Riesgo restante: la plantilla de Backstage no se probó en un Backstage en marcha (el PR se abrió a mano con los mismos archivos que genera), y el bus de la PoC no tiene autenticación ni ACL. El video (`docs/p2/video/`) muestra el núcleo en vivo y declara estos límites.

## Criterios de Juan potenciados por esta PoC

| Criterio | Aporte de la Sección IV |
|---|---|
| **Migración a ECST** /15 | Prueba ejecutable de lo que argumenta la diapositiva 5. **0 llamadas** a la API de Tarifas por cambio (antes ≥ 4); SLO medido sobre 200 cambios: p50 **111 ms**, p99 **227 ms**, máximo 275 ms (sin `sleep` de 5 s); con Tarifas caído, Zonas y el Consumidor C siguen respondiendo; un consumidor nuevo reconstruye su vista desde el offset 0 en **5,3 s** (incluye 1,5 s de rollout del pod); la jerarquía Ciudad → Zona → Tarifa se compone en local (`evidence/p2/02`–`06`) |
| **Contratos y gobernanza (Schema Registry)** /15 | Contrato formal (Avro) con política precisa (FULL_TRANSITIVE) y **ejemplo ejecutado** de protección de consumidores: v2 sin `currency` → CI rojo con `[currency at /fields/6]` y **409** en el registry; v2 con campo opcional → aceptada, y un lector con el contrato v1 lee un mensaje escrito con v2 (`evidence/p2/07`, `08`). Corrige con evidencia un problema técnico del borrador: con JSON Schema y FULL_TRANSITIVE no se puede agregar un campo opcional en los modelos cerrado y abierto; solo un modelo parcial lo admite, y de forma distinta en cada registry (ADR-005) |

**Acción para Juan:** actualizar la diapositiva 6 (JSON Schema → Avro, citando el spike) y la 5 (`maxDailyPrice` → `maxDailyPriceMinor`, enums con default). Sin estos cambios, la Sección I y la IV se contradicen.

## Aporte a otros criterios

| Criterio (responsable) | Insumo que deja esta PoC |
|---|---|
| Dinámicas de interacción /10 (Andrés) | Transición concreta: hoy, cada stream nuevo se coordina en Colaboración con el Platform Team. Con el Golden Path pasa a **X-as-a-Service** (PR auto-integrado). Los casos atípicos (PII, streams delta) vuelven a Colaboración temporal |
| PaaP, 80/20 e InnerSourcing /15 (Felipe, Luis) | Curación explícita: solo `type: state`, sin PII, Avro, FULL_TRANSITIVE (Kyverno lo impone). La plantilla de Backstage y las políticas son contribuibles por PR (InnerSourcing) con CI como guardián |
| Tablero de valor /15 (Luis) | Métricas leading: lead time de stream gobernado (`evidence/p2/lead-time-streams.csv`), % de streams con contrato registrado, cambios incompatibles bloqueados en el PR, p99 de entrega por stream. Métrica lagging (DORA): tasa de fallos de cambio por roturas de consumidores. ROI: ≥ 4 llamadas síncronas evitadas por cambio de tarifa (4N en importaciones masivas) |
