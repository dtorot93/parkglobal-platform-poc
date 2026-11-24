# ADR-005 · Avro en lugar de JSON Schema para los contratos de streams de estado

**Estado:** aceptada (2026-11-21) · **Sección:** Proyecto 2, I (contrato) y IV (PoC) · **Reemplaza:** la elección de JSON Schema de la diapositiva 6 del borrador.

## Contexto

El borrador de la Sección I eligió **JSON Schema + FULL_TRANSITIVE** para `ZoneTariffState`, con el argumento de que el bus ya es 100 % JSON. Sus propias notas reconocían el punto débil: en JSON Schema la compatibilidad depende del modelo de contenido (`additionalProperties`). Con modelo cerrado, agregar una propiedad opcional es compatible hacia atrás pero no hacia delante; con modelo abierto, al revés. FULL exige ambas direcciones.

Antes de construir la PoC se ejecutó un spike reproducible (`scripts/contracts/spike_compat.py`, salida en `evidence/p2/00-spike-compatibilidad.txt`) contra **Apicurio Registry 3.3.4** y **Karapace 6.2.4**, con la política FULL_TRANSITIVE.

| Modelo / cambio | Apicurio | Karapace |
|---|---|---|
| JSON cerrado · agregar propiedad opcional | **RECHAZA** | **RECHAZA** |
| JSON abierto · agregar propiedad opcional | **RECHAZA** | **RECHAZA** |
| JSON parcialmente abierto (`patternProperties ^ext_`) · agregar `ext_promoCode` | **RECHAZA** | ACEPTA |
| JSON parcialmente abierto (`additionalProperties: {string\|null}`) · agregar string\|null | ACEPTA | ACEPTA |
| JSON (cualquier modelo) · eliminar `currency` requerido | RECHAZA | RECHAZA |
| **Avro · agregar campo opcional con default** | **ACEPTA** | **ACEPTA** |
| Avro · agregar campo sin default | RECHAZA | RECHAZA |
| Avro · eliminar `currency` (sin default) | RECHAZA | RECHAZA |

## Decisión

Los contratos de streams de estado se escriben en **Avro**, con política **FULL_TRANSITIVE** fija por la plataforma.

## Por qué

1. **Con JSON Schema el contrato quedaba congelado.** Bajo FULL_TRANSITIVE, ni el modelo cerrado ni el abierto permiten agregar un campo: todo cambio, incluso inocuo, obligaría a un tópico `.v2` con doble publicación. La plataforma se volvería un cuello de botella, justo lo contrario de su objetivo.
2. **Las salidas en JSON Schema son frágiles.** El modelo parcialmente abierto solo funciona si cada campo nuevo tiene exactamente el tipo de `additionalProperties` (un contrato débilmente tipado), y la variante con `patternProperties` da resultados distintos según el registry. La compatibilidad de JSON Schema no está estandarizada: cada registry trae su propio verificador.
3. **Avro tiene reglas simples, estandarizadas y coincidentes entre registries.** "Campo nuevo con default: compatible; campo sin default o eliminado: incompatible". Es una regla que un desarrollador aprende en un minuto (carga cognitiva pertinente, no extraña).
4. **El costo de adopción es bajo.** El tópico es nuevo (no hay consumidores JSON que romper), el serializador estándar funciona contra Apicurio sin cambios, y Backstage muestra el contrato legible en la ficha AsyncAPI.

## Consecuencias

- La diapositiva 6 debe actualizarse: JSON Schema → Avro, citando este spike como evidencia.
- Los enums declaran un `default` (Avro ≥ 1.9) para poder agregar símbolos sin romper lectores antiguos.
- El dinero se modela en unidades menores (`long`) en vez de `double`, para evitar errores de redondeo.
- La clave del mensaje sigue siendo un **string sin esquema** (`<countryCode>:<zoneNo>`). Si la clave se serializara con prefijo de id de esquema, una evolución del esquema de la clave cambiaría sus bytes y rompería la compactación y el particionamiento por clave.
