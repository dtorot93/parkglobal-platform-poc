#!/usr/bin/env bash
# Graba el monitor 2 mientras la PoC funciona de verdad: PR real -> CI -> auto-merge -> Argo CD -> stream listo -> demo.
# Escenas y tiempos en markers.txt (para la edición). La única acción humana: el push y "Create pull request".
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
OUT=${OUT:-$HERE/out}; mkdir -p "$OUT"
MARK=$OUT/markers.txt; : > "$MARK"
GH=dtorot93/parkglobal-platform-poc
BRANCH=stream/city-state
NODE="/mnt/c/Program Files/nodejs/node.exe"
FF=$(ls -d /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg*/*/bin | tail -1)/ffmpeg.exe
C="kubectl --context kind-parkglobal-poc"
cdp() { "$NODE" "$(wslpath -w "$HERE/cdp.mjs")" "$@" >/dev/null 2>&1; }
front() { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$HERE/win.ps1")" front "$1" >/dev/null 2>&1; sleep 0.6; }
now() { date +%s.%N; }
mark() { printf '%.1f %s\n' "$(echo "$(now) - $T0" | bc)" "$*" | tee -a "$MARK"; }
# Escribe un comando en la terminal a ritmo humano y lo ejecuta.
typecmd() { local s=$1 i; for ((i = 0; i < ${#s}; i++)); do tmux send-keys -t rec -l "${s:i:1}"; sleep 0.035; done; sleep 0.4; tmux send-keys -t rec Enter; }
waitprompt() { for _ in $(seq 1 ${1:-120}); do tmux capture-pane -p -t rec | grep -v '^$' | tail -1 | grep -q '\$ *$' && return 0; sleep 0.5; done; }
gh_api() { curl -s "https://api.github.com/repos/$GH/$1"; }

# ---------------------------------------------------------------------------------------------- grabación
rm -f "$OUT/fifo"; mkfifo "$OUT/fifo"
"$FF" -hide_banner -loglevel error -f lavfi -i "ddagrab=output_idx=1:framerate=30" -c:v h264_nvenc -preset p5 -cq 19 -y \
  "$(wslpath -w "$OUT")\\raw.mkv" < "$OUT/fifo" &
FFPID=$!; exec 3>"$OUT/fifo"; T0=$(now); sleep 1
stop() { echo q >&3; exec 3>&-; wait $FFPID 2>/dev/null; mark "fin de la grabación"; }
trap stop EXIT

# ---------------------------------------------------------------------------------------------- 1 · el claim
front terminal; tmux send-keys -t rec "clear" Enter; sleep 1.5
mark "terminal: el equipo Zonas declara su stream"
typecmd "cat streams/zonas/city-state/eventstreamclaim.yaml | grep -v '^#'"; sleep 7
typecmd "clear; kubectl get eventstreamclaims -A -o custom-columns='EQUIPO:.metadata.namespace,STREAM:.metadata.name,TOPICO:.status.topic,READY:.status.conditions[?(@.type==\"Ready\")].status'"; sleep 5

# ---------------------------------------------------------------------------------------------- 2 · push (humano)
typecmd "# El equipo publica su stream con un pull request:"
mark "ESPERA: push del equipo"
for _ in $(seq 1 240); do git ls-remote "https://github.com/$GH" "refs/heads/$BRANCH" | grep -q . && break; sleep 2.5; done
mark "push recibido en GitHub"; sleep 3

# ---------------------------------------------------------------------------------------------- 3 · PR (humano: Create pull request)
front chrome; cdp nav "https://github.com/$GH/compare/main...$BRANCH?expand=1"
mark "ESPERA: Create pull request"
PR=
for _ in $(seq 1 40); do
  PR=$(gh_api "pulls?state=all&head=dtorot93:$BRANCH" | jq -r '.[0].number // empty'); [ -n "$PR" ] && break; sleep 8
done
mark "PR #$PR abierto"; sleep 4
cdp nav "https://github.com/$GH/pull/$PR"; sleep 4; cdp scroll 700 2500; sleep 4

# ---------------------------------------------------------------------------------------------- 4 · CI en vivo
RUN=; for _ in $(seq 1 20); do RUN=$(gh_api "actions/runs?branch=$BRANCH&per_page=1" | jq -r '.workflow_runs[0].id // empty'); [ -n "$RUN" ] && break; sleep 4; done
JOB=$(gh_api "actions/runs/$RUN/jobs" | jq -r '.jobs[] | select(.name=="validate") | .id')
cdp nav "https://github.com/$GH/actions/runs/$RUN/job/$JOB"; mark "CI: validate corriendo (run $RUN)"
for _ in $(seq 1 40); do [ "$(gh_api "actions/jobs/$JOB" | jq -r .status)" = completed ] && break; sleep 6; done
mark "CI: validate terminado ($(gh_api "actions/jobs/$JOB" | jq -r .conclusion))"; sleep 6
cdp nav "https://github.com/$GH/actions/runs/$RUN"; sleep 3
for _ in $(seq 1 30); do [ "$(gh_api "pulls/$PR" | jq -r '.merged_at // empty')" ] && break; sleep 6; done
cdp nav "https://github.com/$GH/actions/runs/$RUN"; sleep 4
mark "auto-merge hecho"
cdp nav "https://github.com/$GH/pull/$PR"; sleep 3; cdp scroll 5000 3000; sleep 5

# ---------------------------------------------------------------------------------------------- 5 · Argo CD en vivo
cdp nav "http://localhost:8090/applications?search=stream"; mark "Argo CD: esperando el stream nuevo"
for _ in $(seq 1 300); do $C -n argocd get application stream-zonas-city-state >/dev/null 2>&1 && break; sleep 2; done
mark "Argo CD: Application stream-zonas-city-state creada"; sleep 4
cdp nav "http://localhost:8090/applications/argocd/stream-zonas-city-state?view=tree"
for _ in $(seq 1 120); do $C -n team-zonas get eventstreamclaim city-state -o json 2>/dev/null | jq -e 'any(.status.conditions[]?; .type=="Ready" and .status=="True")' >/dev/null && break; sleep 1; done
mark "claim city-state Ready"; sleep 10

# ---------------------------------------------------------------------------------------------- 6 · lo que creó la plataforma
front terminal
typecmd "clear; kubectl -n team-zonas get eventstreamclaim city-state -o custom-columns='STREAM:.metadata.name,TOPICO:.status.topic,CONTRATO:.status.contractVersion,COMPAT:.status.compatibility,READY:.status.conditions[?(@.type==\"Ready\")].status'"
mark "terminal: claim Ready"; sleep 5
typecmd "kubectl -n kafka get kafkatopic topology.state.city.v1 -o custom-columns=TOPICO:.metadata.name,PARTICIONES:.spec.partitions,LIMPIEZA:.spec.config.cleanup\\\\.policy"; sleep 5
typecmd "kubectl -n team-consumidor-c get configmap topology.state.city.v1-client -o yaml | grep -E 'TOPIC|SUBJECT|SCHEMA_REGISTRY|AUTO_REGISTER|GROUP'"
mark "terminal: configuración entregada al Consumidor C"; sleep 7

# ---------------------------------------------------------------------------------------------- 7 · el contrato en el registry
front chrome; cdp nav "http://localhost:8888/explore/default/topology.state.city.v1-value"; mark "Apicurio: contrato registrado"; sleep 6
cdp scroll 600 2500; sleep 6

# ---------------------------------------------------------------------------------------------- 8 · demo en vivo
front terminal; typecmd "clear; docs/p2/video/demo.sh"; mark "demo: inicio"
for step in portada 1 2 3 4 5 6; do
  for _ in $(seq 1 240); do tmux capture-pane -p -t rec | grep -q '\[Enter\]' && break; sleep 0.5; done
  mark "demo: pantalla $step completa"; sleep ${PAUSE:-8}
  tmux send-keys -t rec Enter; sleep 1
done
waitprompt 120; mark "demo: entorno restaurado"; sleep 2
