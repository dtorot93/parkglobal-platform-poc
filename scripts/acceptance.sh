#!/usr/bin/env bash
# Criterios de aceptación (sección 5 del spec), solo lectura. Los pasos que escriben en GitHub
# (request-db.sh) se ejecutan aparte; aquí se verifican sus resultados.
# Uso: acceptance.sh [claim-ok] [claim-rechazado]
set -uo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"
ok=${1:-e2e-db} bad=${2:-bad-medium-db} slug=$(repo_slug)
sec() { printf '\n======== %s ========\n' "$*"; }
run() { echo "\$ $*"; "$@" 2>&1 | grep -v "is deprecated"; echo; }

sec "1. Plataforma sana"
run kubectl --context "$KCTX" get nodes
run kubectl --context "$KCTX" -n argocd get applications
echo '$ kubectl get pods -A | grep -vE "Running|Completed"   # solo cabecera'
k get pods -A | grep -vE "Running|Completed"; echo

sec "2. Platform API"
run kubectl --context "$KCTX" get xrd databaseclaims.platform.parkglobal.io
run kubectl --context "$KCTX" get compositions
run kubectl --context "$KCTX" get functions

sec "3. Políticas (unitarias + servidor)"
echo '$ kyverno test platform/kyverno/tests'; kyverno test platform/kyverno/tests 2>&1 | grep -E "Test Summary|Fail"; echo
for f in tests/fixtures/invalid-*.yaml; do
  k apply --dry-run=server -f "$f" >/dev/null 2>&1 && echo "ERROR: $f fue aceptado" || echo "OK rechazado: $f"
done
run kubectl --context "$KCTX" apply --dry-run=server -f tests/fixtures/valid-claim.yaml
echo '$ ./scripts/validate-claims.sh   # mismo control que el CI'; ./scripts/validate-claims.sh >/dev/null 2>&1 && echo "OK claims de main válidos" || echo "ERROR en claims de main"

sec "4. End-to-end por PR ($ok)"
run gh pr list --repo "$slug" --state all --head "claim/$ok" --json number,state,createdAt,mergedAt
pr=$(gh pr list --repo "$slug" --state all --head "claim/$ok" --json number -q '.[0].number')
run gh pr checks "$pr" --repo "$slug"
run kubectl --context "$KCTX" -n team-parking-core wait "databaseclaim/$ok" --for=condition=Ready --timeout=30s
echo "\$ kubectl get secret $ok-app -o jsonpath='{.data}' | jq 'keys'"; k -n team-parking-core get secret "$ok-app" -o jsonpath='{.data}' | jq -c 'keys'; echo
echo "\$ kubectl get databaseclaim $ok -o jsonpath='{.metadata.labels}'"; k -n team-parking-core get databaseclaim "$ok" -o jsonpath='{.metadata.labels}'; echo; echo
echo '$ evidence/lead-time.csv'; cat evidence/lead-time.csv; echo
echo '$ psql select 1 (ver evidence/12-psql-select1.txt)'; grep -A3 -m1 " ok" evidence/12-psql-select1.txt; echo

sec "5. Guardrail en CI ($bad)"
badpr=$(gh pr list --repo "$slug" --state all --head "claim/$bad" --json number -q '.[0].number')
run gh pr view "$badpr" --repo "$slug" --json number,state,mergedAt -q '{number,state,mergedAt}'
echo "\$ gh pr checks $badpr"; gh pr checks "$badpr" --repo "$slug" 2>&1; echo

sec "6. Backstage"
echo '$ ./scripts/catalog-query.sh template'; ./scripts/catalog-query.sh template; echo
echo '$ ./scripts/catalog-query.sh resource'; ./scripts/catalog-query.sh resource; echo
echo '$ (cd backstage && yarn tsc)'; (cd backstage && COREPACK_HOME="$ROOT_DIR/.corepack" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack yarn tsc >/dev/null 2>&1) && echo "OK tsc sin errores" || echo "ERROR tsc"; echo

sec "7. Higiene"
# El patrón se arma por partes para que este archivo no coincida consigo mismo.
pat="gh""p_|github""_pat_|pass""word:|postgres:/""/"
echo '$ git grep -nE <patrones de secretos del spec>'; git grep -nE "$pat" || echo "OK sin secretos"; echo
echo '$ git status --porcelain'; git status --porcelain; echo
run gh repo view "$slug" --json url -q .url
