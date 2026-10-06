#!/usr/bin/env bash
# Lead time = creación del PR del claim -> lastTransitionTime de Ready=True del DatabaseClaim.
# Uso: measure-lead-time.sh <namespace> <name>
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ns=$1 name=$2
pr=$(gh pr list --repo "$(repo_slug)" --state merged --search "head:claim/${name}" --json number,createdAt,mergedAt --limit 1)
created=$(jq -r '.[0].createdAt // empty' <<<"$pr")
merged=$(jq -r '.[0].mergedAt // empty' <<<"$pr")
[ -n "$created" ] || { echo "No se encontró un PR mergeado para claim/${name}" >&2; exit 1; }
ready=$(k -n "$ns" get databaseclaim "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')
status=$(k -n "$ns" get databaseclaim "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
[ "$status" = "True" ] || { echo "El claim ${ns}/${name} aún no está Ready" >&2; exit 1; }
read -r total to_merge <<<"$(python3 - "$created" "$merged" "$ready" <<'PY'
import sys
from datetime import datetime
p=lambda s: datetime.fromisoformat(s.replace("Z","+00:00"))
c,m,r=map(p,sys.argv[1:4])
print(int((r-c).total_seconds()), int((m-c).total_seconds()))
PY
)"
echo "PR creado: $created | merge: $merged | Ready: $ready"
echo "Lead time: ${total} s (PR->merge: ${to_merge} s)"
mkdir -p "$ROOT_DIR/evidence"
csv="$ROOT_DIR/evidence/lead-time.csv"
[ -f "$csv" ] || echo "namespace,name,pr_created,pr_merged,ready_at,seconds_pr_to_merge,seconds_total" > "$csv"
echo "${ns},${name},${created},${merged},${ready},${to_merge},${total}" >> "$csv"
