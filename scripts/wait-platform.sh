#!/usr/bin/env bash
# Espera a que todas las Applications de plataforma queden Synced/Healthy.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
apps="root crossplane kyverno cloudnative-pg platform-tenants platform-crossplane platform-policies claims-appset"
deadline=$(( $(date +%s) + ${TIMEOUT:-900} ))
while :; do
  pending=""
  for a in $apps; do
    st=$(k -n argocd get application "$a" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo "missing")
    [ "$st" = "Synced/Healthy" ] || pending="$pending $a($st)"
  done
  [ -z "$pending" ] && { log "Plataforma Synced/Healthy"; k -n argocd get applications; exit 0; }
  [ "$(date +%s)" -gt "$deadline" ] && { echo "Timeout esperando:$pending" >&2; exit 1; }
  echo "Esperando:$pending"; sleep 15
done
