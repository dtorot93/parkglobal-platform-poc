#!/usr/bin/env bash
# Recolecta evidencia del Golden Path en evidence/. Nunca imprime valores de secretos ni URIs.
# Uso: collect-evidence.sh [namespace] [name] [bad-claim-name]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ns=${1:-team-parking-core} name=${2:-e2e-db} bad=${3:-bad-db}
E="$ROOT_DIR/evidence"; mkdir -p "$E"
cd "$ROOT_DIR"
run() { local f=$1; shift; { echo "\$ $*"; "$@" 2>&1 || true; } > "$E/$f"; log "evidence/$f"; }

run 01-databaseclaims.txt kubectl --context "$KCTX" get databaseclaims -A -o wide
run 02-databaseclaim-describe.txt kubectl --context "$KCTX" -n "$ns" describe databaseclaim "$name"
run 03-cnpg-clusters.txt kubectl --context "$KCTX" get cluster.postgresql.cnpg.io -A
{ echo "\$ kubectl -n $ns get secret ${name}-app -o jsonpath='{.data}' | jq 'keys'   # solo claves"
  k -n "$ns" get secret "${name}-app" -o jsonpath='{.data}' | jq 'keys'; } > "$E/04-secret-keys.txt"; log "evidence/04-secret-keys.txt"
run 05-rbac.txt kubectl --context "$KCTX" -n "$ns" get role,rolebinding -l parkglobal.io/team -o wide
run 06-argocd-applications.txt kubectl --context "$KCTX" -n argocd get applications
run 07-claim-labels.txt kubectl --context "$KCTX" -n "$ns" get databaseclaim "$name" -o jsonpath='{.metadata.labels}'

pr=$(gh pr list --repo "$(repo_slug)" --state all --head "claim/${name}" --json number -q '.[0].number' || true)
[ -n "$pr" ] && run 08-pr-golden-path.txt gh pr view "$pr" --repo "$(repo_slug)" --json number,title,state,createdAt,mergedAt,url,statusCheckRollup

# Guardrail en admisión: dry-run en servidor de los fixtures inválidos
{ for f in tests/fixtures/invalid-*.yaml; do
    echo "\$ kubectl apply --dry-run=server -f $f"
    if k apply --dry-run=server -f "$f" 2>&1; then echo "ERROR: $f fue aceptado"; else echo "OK rechazado: $f"; fi
    echo
  done; } > "$E/09-kyverno-admission-rejections.txt"; log "evidence/09-kyverno-admission-rejections.txt"

# Guardrail en CI: log del job validate del PR inválido
badpr=$(gh pr list --repo "$(repo_slug)" --state all --head "claim/${bad}" --json number -q '.[0].number' || true)
if [ -n "$badpr" ]; then
  run 10-pr-rechazado.txt gh pr view "$badpr" --repo "$(repo_slug)" --json number,title,state,url,statusCheckRollup
  runid=$(gh run list --repo "$(repo_slug)" --branch "claim/${bad}" --workflow validate-and-merge-claims.yaml --json databaseId -q '.[0].databaseId' || true)
  [ -n "$runid" ] && run 11-ci-rechazo-kyverno.txt gh run view "$runid" --repo "$(repo_slug)" --log-failed
fi

# Conectividad: el URI se lee del secreto dentro del pod; nunca pasa por la terminal ni por archivos.
{ echo "\$ kubectl run psql-check (URI tomado de secretKeyRef ${name}-app/uri) -- psql \"\$URI\" -c 'select 1'"
  k -n "$ns" run psql-check --rm -i --restart=Never --image=postgres:16.10-alpine \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"psql-check\",\"image\":\"postgres:16.10-alpine\",\"command\":[\"sh\",\"-c\",\"psql \\\"\$URI\\\" -c 'select 1 as ok'\"],\"env\":[{\"name\":\"URI\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"${name}-app\",\"key\":\"uri\"}}}]}]}}" 2>&1 \
    | grep -v -iE 'postgres(ql)?:[/]{2}' || true; } > "$E/12-psql-select1.txt"; log "evidence/12-psql-select1.txt"

[ -f "$E/lead-time.csv" ] && cp "$E/lead-time.csv" "$E/13-lead-time.csv"
