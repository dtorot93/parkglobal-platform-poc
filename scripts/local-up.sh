#!/usr/bin/env bash
# Modo local SIN GitOps: aplica, en el mismo orden que las olas de Argo CD y con las mismas versiones, todo lo que
# vive en platform/ y streams/. Sirve para iterar y verificar cambios de plataforma antes de hacer push a main.
# El camino oficial sigue siendo `make bootstrap` (Argo CD sincroniza desde GitHub).
#
# Uso: scripts/local-up.sh            (crea el clúster kind si no existe)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"

ver() { python3 -c "import yaml; print(yaml.safe_load(open('platform/argocd/apps/$1.yaml'))['spec']['source']['targetRevision'])"; }
wait_for() { # $1 descripción, $2.. comando que debe tener éxito
  local desc=$1; shift
  for _ in $(seq 1 120); do if "$@" >/dev/null 2>&1; then log "listo: $desc"; return 0; fi; sleep 5; done
  echo "timeout esperando: $desc" >&2; return 1
}

if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  prev_ctx=$(kubectl config current-context 2>/dev/null || true)
  log "Creando clúster kind $CLUSTER_NAME"
  kind create cluster --config bootstrap/kind-config.yaml --name "$CLUSTER_NAME"
  if [ -n "$prev_ctx" ] && [ "$prev_ctx" != "$KCTX" ]; then kubectl config use-context "$prev_ctx" >/dev/null; fi
fi
k wait node --all --for=condition=Ready --timeout=180s

log "Ola -3: Crossplane, Kyverno, CloudNativePG y Strimzi (charts de platform/argocd/apps)"
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo add strimzi https://strimzi.io/charts/ >/dev/null 2>&1 || true
helm repo update >/dev/null
H="helm upgrade --install --kube-context $KCTX --create-namespace --wait --timeout 10m"
$H crossplane crossplane-stable/crossplane -n crossplane-system --version "$(ver crossplane)"
$H kyverno kyverno/kyverno -n kyverno --version "$(ver kyverno)" \
  --set admissionController.replicas=1 --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 --set reportsController.replicas=1
$H cnpg cnpg/cloudnative-pg -n cnpg-system --version "$(ver cloudnative-pg)"
$H strimzi strimzi/strimzi-kafka-operator -n kafka --version "$(ver strimzi)" --set watchAnyNamespace=false \
  --set resources.requests.cpu=100m --set resources.requests.memory=256Mi --set resources.limits.memory=512Mi

log "Ola -2: tenants (namespaces, centros de costo, dueños de dominio) y clúster Kafka"
k apply --server-side -f platform/tenants/
k apply --server-side -f platform/events/

log "Ola -1: Platform API (funciones, provider-kubernetes, XRDs, composiciones, RBAC) y políticas"
k apply --server-side -f platform/crossplane/functions.yaml -f platform/crossplane/provider-kubernetes.yaml 2>/dev/null || true
wait_for "provider-kubernetes Healthy" k wait provider.pkg.crossplane.io/provider-kubernetes --for=condition=Healthy --timeout=5s
wait_for "funciones Healthy" k wait function.pkg.crossplane.io --all --for=condition=Healthy --timeout=5s
k apply --server-side -f platform/crossplane/
wait_for "XRDs Established" k wait xrd --all --for=condition=Established --timeout=5s
k apply --server-side -f platform/kyverno/policies/
wait_for "políticas Kyverno Ready" k wait clusterpolicy --all --for=condition=Ready --timeout=5s

log "Ola 0: Schema Registry (DatabaseClaim del P1 + Apicurio)"
k apply --server-side -f platform/registry/
wait_for "Kafka events Ready" k -n kafka wait kafka/events --for=condition=Ready --timeout=5s
wait_for "base del registry Ready" k -n team-platform-events wait databaseclaim/schema-registry-db --for=condition=Ready --timeout=5s
k -n team-platform-events rollout status deploy/schema-registry --timeout=600s

log "Ola 0: streams (equivalente al ApplicationSet: kustomize de cada streams/<team>/<stream>)"
for d in streams/*/*/; do
  team=$(basename "$(dirname "$d")")
  k apply --server-side -n "team-$team" -k "$d"
done
log "Plataforma de eventos aplicada. Siguiente: make events-status"
