# Evidencia de autoservicio (IV.2)

Los archivos de `evidence/` se generan con `make evidence` (`scripts/collect-evidence.sh`); ninguno contiene valores de secretos ni URIs de conexión.

## Antes y después (F1)

| Dimensión | Antes (flujo actual) | Después (Golden Path) |
|---|---|---|
| Interfaz | PR a repo central + Terraform + YAML | Formulario de 6 campos en Backstage |
| Herramientas que debe conocer | 6+ (Terraform, Terragrunt, Helm, IAM, Okta, Datadog) | 1 (Backstage) |
| Handoffs | 1–2 con el Platform Team | 0 |
| Gobierno | Revisión humana del PR | Kyverno en CI y en admisión + reconciliación de Argo CD |
| Acceso | Grupos definidos a mano | Derivado del grupo del equipo (`spec.access.readers`) |
| Tiempo hasta recurso | [dato real de ParkGlobal: días] | **132 s (≈2,2 min)**: 21 s del PR al merge + 111 s de Argo CD, Crossplane y CNPG (`evidence/lead-time.csv`; meta TVP < 15 min) |
| Imputación de costo | Opcional | 100 % (owner y costCenter obligatorios, etiquetas automáticas) |

## Resultados medidos (2026-10-05, Mac arm64, kind)

| Prueba | Resultado |
|---|---|
| PR #1 `e2e-db` (small, dev) | `validate` verde → auto-merge en 21 s → `Ready=True` a los 132 s |
| Conectividad | `psql select 1` → 1 fila (URI leído del Secret dentro del pod) |
| Guardrail en CI | PR #4 `bad-medium-db` (medium, dev): `validate` falla con «El tamaño medium solo se permite en staging…»; `auto-merge` omitido; el PR sigue abierto |
| Guardrail en admisión | Los 4 fixtures inválidos se rechazan en dry-run server, cada uno con su mensaje |
| Catálogo | Resource `e2e-db` descubierto desde `main` con owner `group:team-parking-core` |

### Hallazgo: guardrail de CI que fallaba abierto (PR #2)
La primera versión del CI evaluó 0 recursos (`kyverno apply -r` no es recursivo) y el PR `bad-db` se integró. **Kyverno en admisión lo rechazó y nunca llegó al clúster** (defensa en profundidad). Se corrigió con `scripts/validate-claims.sh` (claims explícitos, conteo de recursos evaluados y canario) y se retiró el claim con el PR #3, revisado por una persona. Detalle en ADR-003. Vale la pena contarlo en la sustentación: muestra por qué hacen falta dos barreras.

## Archivos de evidencia

| Archivo | Qué demuestra |
|---|---|
| `validacion.txt` | Salida de los 8 bloques de criterios de aceptación |
| `lead-time.csv` | Lead time PR → Ready medido por `measure-lead-time.sh` |
| `01-databaseclaims.txt`, `02-databaseclaim-describe.txt` | Claim Ready con `status.endpoint` y `status.secretRef` |
| `03-cnpg-clusters.txt` | Clúster PostgreSQL compuesto por Crossplane |
| `04-secret-keys.txt` | Secreto disponible (solo claves) |
| `05-rbac.txt` | Role y RoleBinding derivados del grupo del equipo |
| `06-argocd-applications.txt` | Apps Synced/Healthy |
| `07-claim-labels.txt` | Etiquetas FinOps agregadas por Kyverno |
| `08-pr-golden-path.txt` | PR del claim, check verde y merge automático |
| `09-kyverno-admission-rejections.txt` | Guardrail en admisión (dry-run server de fixtures inválidos) |
| `10-pr-rechazado.txt`, `11-ci-rechazo-kyverno.txt` | Guardrail en CI: `medium` en `dev` rechazado y no integrado |
| `12-psql-select1.txt` | Conectividad real (`select 1`) sin exponer el URI |
| `14-incidente-guardrail-ci.txt` | Incidente del PR #2: CI evaluó 0 recursos; la admisión lo frenó; remediación en el PR #3 |
| `raw/reproducibilidad.txt` | `make teardown && make bootstrap && make platform` desde cero |

## Capturas para IV.2

| # | Captura | Estado |
|---|---|---|
| ① | Formulario de Backstage «Solicitar base de datos PostgreSQL» | ✅ `evidence/screenshots/01-formulario-backstage.png` (y `00-catalogo-plantillas.png`) |
| ② | PR generado con el check `validate` en verde y merge automático | ✅ `02-pr-check-verde-automerge.png` (vista pública; con sesión iniciada se ven los checks en detalle) |
| ③ | App de Argo CD `claim-parking-core-e2e-db` Synced/Healthy | PENDIENTE: `make argocd-ui` (requiere la contraseña admin; no se automatizó para no exponerla). Texto en `06-argocd-applications.txt` |
| ④ | `kubectl get databaseclaim` con READY=True | PENDIENTE (captura de terminal). Texto en `01-databaseclaims.txt` |
| ⑤ | Secreto disponible (solo claves) | PENDIENTE (captura de terminal). Texto en `04-secret-keys.txt` |
| ⑥ | Entidad Resource en el catálogo con su owner | ✅ `06-entidad-catalogo.png` |
| ★ | Guardrail: PR `bad-medium-db` (#4) con check rojo y mensaje de Kyverno | ✅ `07-guardrail-pr-rechazado.png` y `07b-guardrail-ci-job.png`; mensaje en `11-ci-rechazo-kyverno.txt` |

Video (3–5 min): formulario → PR con check verde → auto-merge → sync de Argo → claim Ready → `psql select 1` → catálogo → caso de rechazo.
