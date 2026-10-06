# ADR-001 · Kyverno en lugar de OPA Gatekeeper para el gobierno del Golden Path

**Estado:** aceptado · **Fricciones:** F1 (revisión humana del PR), F5 (rutas de acceso)

## Contexto
El Golden Path elimina la revisión humana del PR de infraestructura. El control debe aplicarse dos veces con la misma definición: en el PR (shift-left) y en la admisión del clúster. ParkGlobal ya tiene Kyverno instalado, pero desconectado del flujo.

## Opciones
1. **OPA Gatekeeper**: políticas en Rego, ConstraintTemplates y Constraints. Para CI se usa `gator` o `conftest` con otra sintaxis de pruebas.
2. **Kyverno**: políticas YAML declarativas. El CLI (`kyverno apply` y `kyverno test`) ejecuta exactamente las mismas políticas en CI que en admisión y permite simular contexto (ConfigMap, apiCall) con un archivo de valores.

## Decisión
Kyverno. Es la opción de la diapositiva 18 (trazabilidad) y no requiere una herramienta nueva.

## Consecuencias
- (+) Una sola fuente de verdad: `platform/kyverno/policies/` se aplica en GitHub Actions y en el webhook de admisión.
- (+) La curva de aprendizaje del Platform Team es baja (YAML y JMESPath frente a Rego).
- (+) Las mutaciones (etiquetas FinOps) usan la misma herramienta.
- (−) Kyverno 1.19 marca `kyverno.io/v1 ClusterPolicy` como deprecado en favor de `ValidatingPolicy`/`MutatingPolicy` (CEL). La PoC usa ClusterPolicy por requisito del diseño; la migración a CEL queda en el backlog antes de producción.
- (−) Las reglas con contexto de clúster (ConfigMap y conteo por apiCall) se simulan en CI con `values.yaml`; el ConfigMap de CI y el del clúster deben mantenerse sincronizados.
