#!/usr/bin/env bash
# Levanta (si no existe) el Schema Registry efímero que usa el CI, en http://localhost:18080, y espera a que responda.
set -euo pipefail
IMAGE=${1:-apicurio/apicurio-registry:3.3.4}
if ! docker ps --format '{{.Names}}' | grep -qx ci-registry; then
  docker run -d --rm --name ci-registry -p 18080:8080 "$IMAGE" >/dev/null
fi
for _ in $(seq 1 60); do
  if curl -sf http://localhost:18080/apis/ccompat/v7/subjects >/dev/null; then echo "registry efímero listo (:18080)"; exit 0; fi
  sleep 2
done
echo "el registry efímero no respondió" >&2
exit 1
