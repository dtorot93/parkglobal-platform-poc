# Utilidades comunes. Todos los comandos usan el contexto de la PoC, nunca el default del usuario.
CLUSTER_NAME=parkglobal-poc
KCTX=kind-${CLUSTER_NAME}
k() { kubectl --context "$KCTX" "$@"; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_slug() { gh repo view --json nameWithOwner -q .nameWithOwner; }
github_token() { if [ -n "${GITHUB_TOKEN:-}" ]; then echo "$GITHUB_TOKEN"; else gh auth token; fi; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
