# ADR-002 · Composición intercambiable: CloudNativePG local, Aurora en AWS

**Estado:** aceptado · **Pilar S5:** 05 Composable by design

## Contexto
La PoC corre en kind, sin cuenta AWS. ParkGlobal opera Aurora PostgreSQL en EKS. El contrato que ven los equipos (DatabaseClaim) no debe depender de dónde corre la base.

## Opciones
1. Usar Aurora real desde la PoC (requiere cuenta sandbox, costo y credenciales en el laptop).
2. Helm de PostgreSQL vía provider-helm (imágenes Bitnami, ya no recomendadas; sin noción de "Ready" del clúster de base de datos).
3. **Operador CloudNativePG** compuesto directamente por Crossplane v2, que entrega readiness, servicio `-rw` y secreto `-app` nativos.

## Decisión
Composición `databaseclaim-cnpg` (opción 3) para la PoC. En AWS se sustituye por `databaseclaim-aurora` (provider-aws: `rds.aws.upbound.io` Cluster/ClusterInstance + Secrets Manager + External Secrets) seleccionada con `compositionSelector` o `defaultCompositionRef` por clúster. **El contrato no cambia.**

| Pieza | PoC | ParkGlobal |
|---|---|---|
| Motor | CNPG `Cluster` | Aurora PostgreSQL |
| small / medium | 1×1Gi / 2×5Gi (HA) | p. ej. db.t4g.medium / db.r7g.large (Graviton) |
| Secreto | Secret `<name>-app` | Secrets Manager → ExternalSecret `<name>-app` |
| Acceso | Role + RoleBinding a grupos | Igual, con grupos de Okta vía OIDC |

## Consecuencias
- (+) Los equipos no aprenden Aurora, RDS ni Terraform: piden `small` o `medium`.
- (+) El *replatform* silencioso (p. ej. a Graviton) es un cambio de composición, sin tocar claims.
- (−) Hay que mantener dos composiciones con paridad de `status` (`endpoint`, `secretRef`, `ready`). Se mitiga con pruebas de contrato sobre el XR.
