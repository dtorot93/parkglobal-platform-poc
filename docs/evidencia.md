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
| Tiempo hasta recurso | [dato real de ParkGlobal: días] | **PENDIENTE** s (`evidence/lead-time.csv`) |
| Imputación de costo | Opcional | 100 % (owner y costCenter obligatorios, etiquetas automáticas) |

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

## Capturas para IV.2

| # | Captura | Estado |
|---|---|---|
| ① | Formulario de Backstage «Solicitar base de datos PostgreSQL» | PENDIENTE |
| ② | PR generado con el check `validate` en verde y merge automático | PENDIENTE |
| ③ | App de Argo CD `claim-parking-core-e2e-db` Synced/Healthy | PENDIENTE |
| ④ | `kubectl get databaseclaim` con READY=True | PENDIENTE |
| ⑤ | Secreto disponible (solo claves) | PENDIENTE |
| ⑥ | Entidad Resource en el catálogo con su owner | PENDIENTE |
| ★ | Guardrail: PR `bad-db` con check rojo y mensaje de Kyverno | PENDIENTE |

Video (3–5 min): formulario → PR con check verde → auto-merge → sync de Argo → claim Ready → `psql select 1` → catálogo → caso de rechazo.
