#!/usr/bin/env bash
# Valida con Kyverno todos los claims/**/databaseclaim.yaml (mismo script en CI y en local).
# Falla cerrado: si Kyverno evalúa menos recursos de los esperados o si el canario no es rechazado.
set -euo pipefail
cd "$(dirname "$0")/.."
POLICIES=platform/kyverno/policies
VALUES=platform/kyverno/tests/values.yaml

# Canario: un claim inválido conocido DEBE ser rechazado; si no, el control está roto.
if kyverno apply "$POLICIES" -r tests/fixtures/invalid-medium-in-dev.yaml --values-file "$VALUES" >/dev/null 2>&1; then
  echo "::error::Canario fallido: kyverno apply aceptó tests/fixtures/invalid-medium-in-dev.yaml"; exit 1
fi

# kyverno apply -r <dir> no recorre subdirectorios: se pasa cada claim explícitamente.
files=()
while IFS= read -r f; do files+=("$f"); done < <(find claims -name databaseclaim.yaml | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "No hay claims que validar (el canario confirmó que las políticas funcionan)."; exit 0
fi
args=()
for f in "${files[@]}"; do args+=(-r "$f"); done
echo "Evaluando ${#files[@]} claim(s): ${files[*]}"

out=$(kyverno apply "$POLICIES" "${args[@]}" --values-file "$VALUES" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -v "is deprecated"
evaluated=$(echo "$out" | sed -n 's/.*to \([0-9]*\) resource(s).*/\1/p' | head -1)
if [ "${evaluated:-0}" -ne "${#files[@]}" ]; then
  echo "::error::Kyverno evaluó ${evaluated:-0} recursos de ${#files[@]} claims"; exit 1
fi
exit "$rc"
