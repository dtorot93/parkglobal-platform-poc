# ADR-003 · Auto-merge por política en lugar de revisión humana

**Estado:** aceptado · **Fricción:** F1 (RICE 8,1)

## Contexto
Hoy cada base de datos espera días por la revisión del Platform Team (relación 1:7 con producto). La revisión verifica casi siempre lo mismo: owner, centro de costo, tamaño razonable y namespace correcto.

## Opciones
1. Mantener la revisión humana con una plantilla de PR (no reduce la espera).
2. Aplicar directamente desde Backstage al clúster (rápido, pero sin auditoría y con credenciales en el portal).
3. **PR auditable + validación automática + merge automático** cuando las políticas pasan.

## Decisión
Opción 3. El workflow `validate-and-merge-claims` ejecuta `kyverno test` y `kyverno apply` sobre `claims/`; si pasa y la rama es `claim/*`, `gh pr merge --squash` integra el PR. Argo CD (modelo pull) lo sincroniza; Kyverno vuelve a validar en admisión (defensa en profundidad).

Salvaguardas:
- Un PR `claim/*` que toque archivos fuera de `claims/` falla la validación: el auto-merge no puede colar cambios de plataforma.
- El workflow corre con permisos mínimos (`contents: read`; `contents/pull-requests: write` solo en el job de merge).
- Las políticas viven en el mismo repo y sus cambios sí pasan por revisión humana del Platform Team (CODEOWNERS en producción).

## Consecuencias
- (+) Lead time de minutos en lugar de días y 0 handoffs.
- (+) Cada solicitud queda auditada en Git (quién, qué, cuándo, qué política la validó).
- (−) La calidad del control depende de las políticas: un hueco en ellas se integra sin ojos humanos. Se mitiga con pruebas (`kyverno test`) y con la segunda barrera en admisión.
- (−) En producción se requiere protección de rama con el check `validate` obligatorio. En la PoC el repo es público y no se cambiaron sus settings.

## Hallazgo durante la PoC (2026-10-05): un control que falla abierto
La primera versión del job `validate` ejecutaba `kyverno apply ... -r claims/`. Ese comando **no recorre subdirectorios**: evaluó 0 recursos, terminó con código 0 y el PR `bad-db` (`medium` en `dev`) se integró automáticamente. La segunda barrera (Kyverno en admisión) lo rechazó y nada llegó al clúster, pero el guardrail de CI falló en silencio.

Corrección (`scripts/validate-claims.sh`, mismo script en CI y en local):
- Pasa cada `claims/**/databaseclaim.yaml` de forma explícita y falla si Kyverno evalúa menos recursos de los esperados.
- **Canario:** antes de validar, comprueba que el fixture `invalid-medium-in-dev.yaml` sea rechazado; si no lo es, el job falla.
- El claim inválido se retiró de `main` con un PR de remediación revisado por una persona (rama fuera de `claim/*`, sin auto-merge).

Lección: con auto-merge, un check verde no basta; el pipeline debe demostrar que **evaluó** lo que debía y que es capaz de rechazar. La defensa en profundidad (CI + admisión) evitó el impacto.
