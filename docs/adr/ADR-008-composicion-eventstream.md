# ADR-008 · Composición del EventStreamClaim: provider-kubernetes + Job registrador

**Estado:** aceptada (2026-11-21) · **Sección:** Proyecto 2, IV

## Contexto

El `EventStreamClaim` vive en el namespace del equipo (`team-tarifas`), igual que el `DatabaseClaim` (ADR-004). Pero en Crossplane v2 **un XR namespaced solo compone recursos en su propio namespace**, y:

- El Topic Operator de Strimzi observa un único namespace (`kafka`), donde debe vivir el `KafkaTopic`.
- La configuración de cliente debe llegar al namespace de **cada consumidor**.
- El contrato se registra por API REST en el Schema Registry, que no es un recurso de Kubernetes.

## Decisión

| Necesidad | Mecanismo |
|---|---|
| `KafkaTopic` en `kafka` | `Object` de **provider-kubernetes v1.4.1** (namespaced, `kubernetes.m.crossplane.io`) con `managementPolicies` sin `Delete`. |
| ConfigMap de cliente en cada `team-<consumidor>` | `Object` de provider-kubernetes, uno por consumidor declarado. |
| Registro del contrato | **Job** compuesto en el namespace del equipo. Monta el ConfigMap `<stream>-contract` (generado por kustomize desde `schemas/*.avsc`) y registra v1..vN en orden con FULL_TRANSITIVE. El nombre lleva la versión y un hash de sus entradas: un cambio crea un Job nuevo. |
| Estado del claim | `status.topic`, `subject`, `contractVersion`, `topicReady`, `contractRegistered`; Ready solo si el tópico existe **y** el contrato quedó registrado. |

El ServiceAccount del provider tiene **mínimo privilegio**: solo `kafkatopics` y `configmaps`, nunca `cluster-admin` como en los ejemplos del provider.

## Alternativas descartadas

- **XRD cluster-scoped**: rompe el aislamiento por namespace del P1 y la política `namespace-matches-owner`.
- **provider-http** para el registry: otro provider que operar, y el `Job` es más fácil de auditar (sus logs muestran el 409).
- **provider-kafka** contra el broker: es la opción para producción con MSK (composición `eventstream-msk-apicurio`). En la PoC, Strimzi ya ofrece el `KafkaTopic` declarativo.

## Consecuencias

- Borrar un claim **no borra el tópico**: el estado del negocio no desaparece por accidente. Retirar un stream es una deprecación explícita.
- Si alguien salta el CI con un contrato incompatible, el Job falla con el 409 del registry y el claim no queda Ready. Es la segunda barrera, simétrica a Kyverno en la admisión.
