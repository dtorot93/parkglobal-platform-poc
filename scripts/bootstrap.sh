#!/usr/bin/env bash
# Crea el clúster kind, instala Argo CD (único helm install imperativo), registra el repo y aplica el app-of-apps.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"
ARGOCD_CHART_VERSION=10.9.6

if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  prev_ctx=$(kubectl config current-context 2>/dev/null || true)
  log "Creando clúster kind $CLUSTER_NAME"
  kind create cluster --config bootstrap/kind-config.yaml --name "$CLUSTER_NAME"
  # kind cambia el contexto por defecto; se restaura el que tenía el usuario.
  if [ -n "$prev_ctx" ] && [ "$prev_ctx" != "$KCTX" ]; then kubectl config use-context "$prev_ctx" >/dev/null; fi
fi
k wait node --all --for=condition=Ready --timeout=180s

log "Instalando Argo CD (chart $ARGOCD_CHART_VERSION)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --kube-context "$KCTX" -n argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" -f bootstrap/argocd-values.yaml --wait --timeout 10m

log "Registrando el repositorio GitOps en Argo CD (token solo en el clúster)"
slug=$(repo_slug)
k -n argocd create secret generic repo-gitops \
  --from-literal=type=git --from-literal=url="https://github.com/${slug}.git" \
  --from-literal=username=x-access-token --from-literal=password="$(github_token)" \
  --dry-run=client -o yaml | k label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | k apply -f - >/dev/null

log "Aplicando app-of-apps"
k apply -f platform/argocd/root-app.yaml
