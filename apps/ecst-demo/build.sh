#!/usr/bin/env bash
# Construye la imagen de demostración y la carga en el clúster kind (sin registry de imágenes en la PoC local).
# Los contratos se copian desde streams/: el código usa exactamente la versión que la plataforma registró.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
IMAGE=${IMAGE:-parkglobal/ecst-demo:0.1.7}
TARIFF_V=${TARIFF_CONTRACT_VERSION:-1}
ZONE_V=${ZONE_CONTRACT_VERSION:-1}
rm -rf contracts && mkdir contracts
cp "$ROOT/streams/tarifas/zone-tariff-state/schemas/v${TARIFF_V}.avsc" contracts/zone-tariff-state.avsc
cp "$ROOT/streams/zonas/zone-state/schemas/v${ZONE_V}.avsc" contracts/zone-state.avsc
# Para la demo del autorregistro bloqueado: CONTRACT_OVERRIDE=<archivo.avsc> reemplaza el contrato de Tarifas.
if [ -n "${CONTRACT_OVERRIDE:-}" ]; then cp "$CONTRACT_OVERRIDE" contracts/zone-tariff-state.avsc; fi
docker build -q -t "$IMAGE" .
NODE=${CLUSTER_NAME:-parkglobal-poc}-control-plane
# kind < v0.31 falla con "failed to detect containerd snapshotter" en nodos v1.35: se importa directo en containerd.
if ! kind load docker-image "$IMAGE" --name "${CLUSTER_NAME:-parkglobal-poc}" 2>/dev/null; then
  docker save "$IMAGE" | docker exec -i "$NODE" ctr -n k8s.io images import --all-platforms - >/dev/null
fi
echo "imagen $IMAGE cargada en kind"
