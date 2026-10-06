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
