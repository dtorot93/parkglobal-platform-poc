#!/usr/bin/env bash
# Borra SOLO el clúster de la PoC. Nunca toca evidence/ ni el repositorio.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
if kind get clusters | grep -qx "$CLUSTER_NAME"; then kind delete cluster --name "$CLUSTER_NAME"; fi
