#!/usr/bin/env bash
# Consulta el catálogo de Backstage local. Desde 1.x la API exige credenciales: usa un token de invitado.
# Uso: catalog-query.sh <kind>   (p. ej. template, resource, group)
set -euo pipefail
kind=${1:?Uso: $0 <kind>}
base=${BACKSTAGE_URL:-http://localhost:7007}
token=$(curl -sf "$base/api/auth/guest/refresh" | jq -r '.backstageIdentity.token')
curl -sf -H "Authorization: Bearer $token" "$base/api/catalog/entities?filter=kind=$kind" | jq -r '.[].metadata.name'
