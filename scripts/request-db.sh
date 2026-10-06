#!/usr/bin/env bash
# Alternativa CLI al formulario de Backstage: genera los mismos archivos y abre el PR claim/<name>.
# Uso: request-db.sh <team> <name> <size> <env> <costCenter> [readers]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
[ $# -ge 5 ] || { echo "Uso: $0 <team> <name> <small|medium> <dev|staging> <costCenter> [readers]" >&2; exit 2; }
team=$1 name=$2 size=$3 env=$4 cc=$5 readers=${6:-grp-$1}
branch="claim/${name}"
dir="claims/${team}/${name}"
cd "$ROOT_DIR"

wt=$(mktemp -d)
trap 'git worktree remove --force "$wt" >/dev/null 2>&1 || true' EXIT
git fetch -q origin main
git worktree add -q -b "$branch" "$wt" origin/main
mkdir -p "$wt/$dir"
cat > "$wt/$dir/databaseclaim.yaml" <<YAML
apiVersion: platform.parkglobal.io/v1alpha1
kind: DatabaseClaim
metadata:
  name: ${name}
  namespace: team-${team}
spec:
  owner:
    team: ${team}
    costCenter: ${cc}
  engine: postgresql
  size: ${size}
  environment: ${env}
  access:
    readers: [${readers}]
YAML
cat > "$wt/$dir/catalog-info.yaml" <<YAML
apiVersion: backstage.io/v1alpha1
kind: Resource
metadata:
  name: ${name}
  description: Base de datos PostgreSQL ${size} (${env}) solicitada por Golden Path
  annotations:
    parkglobal.io/cost-center: ${cc}
    parkglobal.io/secret-ref: ${name}-app
    backstage.io/kubernetes-namespace: team-${team}
  tags: [postgresql, golden-path, ${env}]
spec:
  type: database
  owner: group:team-${team}
  system: parking
YAML
git -C "$wt" add "$dir"
git -C "$wt" commit -q -m "feat(claims): solicitar DatabaseClaim ${name} (${size}, ${env})"
git -C "$wt" push -q -u origin "$branch"
gh pr create --repo "$(repo_slug)" --base main --head "$branch" \
  --title "[golden-path] DatabaseClaim ${name}" \
  --body "Solicitud de base de datos PostgreSQL por Golden Path.

| Campo | Valor |
|---|---|
| Equipo | ${team} |
| Nombre | ${name} |
| Tamaño | ${size} |
| Entorno | ${env} |
| Centro de costo | ${cc} |
| Lectores | ${readers} |

Validado por Kyverno en CI; se integra automáticamente si cumple las políticas."
