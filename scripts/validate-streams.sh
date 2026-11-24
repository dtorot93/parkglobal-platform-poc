#!/usr/bin/env bash
# Valida con Kyverno todos los streams/**/eventstreamclaim.yaml (mismo script en CI y en local).
# Falla cerrado: si Kyverno evalúa menos recursos de los esperados o si el canario no es rechazado.
set -euo pipefail
cd "$(dirname "$0")/.."
POLICIES=platform/kyverno/policies
VALUES=platform/kyverno/tests/values.yaml

# Canario: un stream que publica en un dominio ajeno DEBE ser rechazado; si no, el control está roto.
if kyverno apply "$POLICIES" -r tests/fixtures/invalid-stream-domain.yaml --values-file "$VALUES" >/dev/null 2>&1; then
  echo "::error::Canario fallido: kyverno apply aceptó tests/fixtures/invalid-stream-domain.yaml"; exit 1
fi

files=()
while IFS= read -r f; do files+=("$f"); done < <(find streams -name eventstreamclaim.yaml | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "No hay streams que validar (el canario confirmó que las políticas funcionan)."; exit 0
fi
args=()
for f in "${files[@]}"; do args+=(-r "$f"); done
echo "Evaluando ${#files[@]} stream(s): ${files[*]}"

out=$(kyverno apply "$POLICIES" "${args[@]}" --values-file "$VALUES" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -v "is deprecated"
if [ "$rc" -ne 0 ]; then
  echo "$out" | awk 'match($0, /EventStreamClaim\/[^ ]+ failed:/) { claim=substr($0, RSTART+17, RLENGTH-25) }
    /^[0-9]+ - / && claim { sub(/^[0-9]+ - [^ ]+ /, ""); print "::error title=Kyverno::" claim ": " $0 }'
fi
evaluated=$(echo "$out" | sed -n 's/.*to \([0-9]*\) resource(s).*/\1/p' | head -1)
if [ "${evaluated:-0}" -ne "${#files[@]}" ]; then
  echo "::error::Kyverno evaluó ${evaluated:-0} recursos de ${#files[@]} streams"; exit 1
fi
exit "$rc"
