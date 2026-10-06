# PoC · Primer Golden Path de ParkGlobal: autoservicio de PostgreSQL

Un desarrollador pide una base de datos PostgreSQL con un formulario de Backstage. La plataforma abre un PR, lo valida con Kyverno, lo integra sin revisión humana, lo sincroniza con Argo CD y lo compone con Crossplane v2 sobre CloudNativePG. El resultado es una base Ready, un secreto por referencia, acceso derivado del grupo del equipo, etiquetas FinOps y una entidad en el catálogo. Resuelve la fricción **F1** (RICE 8,1).

> ParkGlobal es un nombre anonimizado. Diagrama del flujo: [docs/d9-flujo-to-be.md](docs/d9-flujo-to-be.md). Decisiones: [docs/adr/](docs/adr/). Versiones: [docs/versions.md](docs/versions.md). Evidencia: [docs/evidencia.md](docs/evidencia.md).

## Arquitectura

| Capa | Pieza | Dónde |
|---|---|---|
| Desarrollador | Backstage + plantilla `database-claim-postgresql` | `backstage/templates/database-claim/` |
| Integración y entrega | Repo GitOps + GitHub Actions (validación + auto-merge) | `claims/`, `.github/workflows/` |
| Integración y entrega | Argo CD: app-of-apps + ApplicationSet de claims | `platform/argocd/` |
| Platform API | XRD `DatabaseClaim` + Composition `databaseclaim-cnpg` | `platform/crossplane/` |
| Seguridad / FinOps | 5 políticas Kyverno (CI y admisión) | `platform/kyverno/` |
| Recursos | CloudNativePG (local) ≙ Aurora (AWS) | ADR-002 |

Orden de despliegue GitOps (sync-waves): `-3` Crossplane, Kyverno y CNPG → `-2` namespaces de equipos y ConfigMap de centros de costo → `-1` funciones, RBAC, XRD, Composition y políticas → `0` ApplicationSet de claims.

### Contrato

```yaml
apiVersion: platform.parkglobal.io/v1alpha1
kind: DatabaseClaim
metadata: { name: parking-sessions-db, namespace: team-parking-core }
spec:
  owner: { team: parking-core, costCenter: CC-PARK-01 }
  engine: postgresql
  size: small          # small: 1 instancia, 1Gi · medium: 2 instancias, 5Gi (solo staging)
  environment: dev
  access: { readers: [grp-parking-core] }
# status: endpoint (<name>-rw.<ns>.svc), secretRef (<name>-app), ready
```

### Políticas (mismas en CI y en admisión)

| Política | Regla |
|---|---|
| `require-registered-cost-center` | owner obligatorio; centro de costo registrado en `kyverno/cost-centers` |
| `namespace-matches-owner` | el claim vive en `team-<owner.team>` |
| `restrict-size-by-environment` | `medium` solo en `staging` (cost gate estático) |
| `limit-claims-per-namespace` | máximo 3 claims por namespace |
| `add-finops-labels` | agrega `parkglobal.io/team` y `parkglobal.io/cost-center` |

## Prerrequisitos

- macOS (probado en arm64) con Docker Desktop corriendo y ≥ 6 GB de RAM asignados.
- `brew install kind kubectl helm gh kyverno yq` (opcionales: `argocd gitleaks`). Node 20 o 22 LTS.
- `gh auth login -h github.com -s repo,workflow`. El token de `gh auth token` (o `GITHUB_TOKEN`) se usa para que Argo CD lea el repo y Backstage abra PRs; **nunca se escribe en archivos**.
- Un fork o copia de este repo en tu cuenta. Si cambias de owner, reemplaza el owner en `platform/argocd/`, `backstage/app-config.yaml` y `backstage/templates/database-claim/template.yaml`.

## Reproducir desde cero

```bash
make bootstrap    # kind + Argo CD + Secret del repo (desde el token) + app-of-apps
make platform     # espera a que todo quede Synced/Healthy (≈5–8 min la primera vez)
make test         # kyverno test: pruebas unitarias de las políticas
make validate     # dry-run en servidor: los fixtures inválidos se rechazan en admisión
make backstage    # Backstage en http://localhost:3000 (log: evidence/raw/backstage.log)
```

`make backstage` exporta `GITHUB_TOKEN` desde `gh auth token`. Usa yarn 4.13.0 vía `corepack yarn` con `COREPACK_HOME=.corepack` (caché propia del proyecto); la yarn 1 global no funciona con esta app.

## Demo (guion de 5 minutos)

1. **Formulario:** Backstage → *Create* → «Solicitar base de datos PostgreSQL». Completa nombre `e2e-db`, equipo `team-parking-core`, `CC-PARK-01`, `small`, `dev`.
   Alternativa por CLI (mismo resultado de GitOps): `./scripts/request-db.sh parking-core e2e-db small dev CC-PARK-01`.
2. **PR:** se abre `claim/e2e-db`; el job `validate` (Kyverno) pasa y `auto-merge` lo integra.
3. **Argo CD:** `make argocd-ui` → app `claim-parking-core-e2e-db` Synced/Healthy.
4. **Recurso:** `kubectl --context kind-parkglobal-poc -n team-parking-core get databaseclaim e2e-db` → READY=True y ENDPOINT.
5. **Lead time:** `./scripts/measure-lead-time.sh team-parking-core e2e-db`.
6. **Catálogo:** la entidad Resource `e2e-db` aparece con owner `team-parking-core` en ≤ 2 min.
7. **Guardrail:** `./scripts/request-db.sh parking-core bad-db medium dev CC-PARK-01` → check rojo con el mensaje «El tamaño medium solo se permite en staging…»; el PR no se integra.
8. **Evidencia:** `make evidence`.

## Configuración del repositorio para el auto-merge

El job `auto-merge` usa el `GITHUB_TOKEN` de Actions con `contents: write` y `pull-requests: write` declarados en el workflow, así que no requiere cambiar settings en un repo personal. Si la organización restringe los permisos de los workflows, habilita *Settings → Actions → General → Workflow permissions → Read and write*. En producción se agrega protección de rama con el check `validate` obligatorio (ADR-003).

## Troubleshooting

| Síntoma | Causa / solución |
|---|---|
| Apps `platform-*` en `Unknown` / ComparisonError | Argo CD no puede leer el repo: vuelve a ejecutar `make bootstrap` con `gh auth status` válido. |
| `platform-policies` reintenta con «kind not found» | La XRD aún no está *Established*; los reintentos lo resuelven solos en 1–2 min. |
| Claim `Synced=False` | `kubectl describe databaseclaim <n>`; revisa `kubectl get functions` (HEALTHY=True) y el ClusterRole agregado. |
| `yarn` no hace nada en `backstage/` | La yarn 1 global o una caché de corepack corrupta (`yarn.js` de 0 bytes). Usa `make backstage`, que fija `COREPACK_HOME=.corepack`. |
| La entidad no aparece en el catálogo | Debe estar en `main`; el proveedor de GitHub corre cada minuto. Revisa `evidence/raw/backstage.log`. |
| `kind create` cambió el contexto por defecto | `scripts/bootstrap.sh` lo restaura; todos los comandos usan `--context kind-parkglobal-poc`. |

## Equivalencia PoC / ParkGlobal

| Pieza | PoC local | ParkGlobal |
|---|---|---|
| Clúster | kind | EKS |
| Motor | CloudNativePG | Aurora PostgreSQL (provider-aws) |
| Secreto | Secret de Kubernetes | AWS Secrets Manager + External Secrets |
| Identidad | Grupos RBAC | Okta → OIDC |
| Portal | Backstage local (guest) | Backstage existente |

## Fuera de alcance (TODO, fase 2)

S3 en el catálogo cerrado · producción · Cost Gate dinámico (OpenCost/Infracost) · kube-green · lease/TTL · MCP sobre la Platform API · reutilizar el patrón en `APIClaim` (III.2) · migrar las políticas a `ValidatingPolicy` (CEL).

## Limpieza

`make teardown` borra solo el clúster `parkglobal-poc`; no toca `evidence/` ni el repo.
