#!/usr/bin/env bash
# Graba el monitor 2 mientras la PoC funciona de verdad: PR real -> CI -> auto-merge -> Argo CD -> stream listo -> demo.
# Escenas y tiempos en markers.txt (para la edición). La única acción humana: el push y "Create pull request".
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
OUT=${OUT:-$HERE/out}; mkdir -p "$OUT"
MARK=$OUT/markers-b.txt; : > "$MARK"
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
typecmd() { local s=$1 i; for ((i = 0; i < ${#s}; i++)); do c=${s:i:1}; [ "$c" = ";" ] && c="\\;"; tmux send-keys -t rec -l -- "$c"; sleep 0.035; done; sleep 0.4; tmux send-keys -t rec Enter; }
waitprompt() { for _ in $(seq 1 ${1:-120}); do tmux capture-pane -p -t rec | grep -v '^$' | tail -1 | grep -q '\$ *$' && return 0; sleep 0.5; done; }
gh_api() { curl -s "https://api.github.com/repos/$GH/$1"; }

# ---------------------------------------------------------------------------------------------- grabación
rm -f "$OUT/fifo"; mkfifo "$OUT/fifo"
"$FF" -hide_banner -loglevel error -f lavfi -i "ddagrab=output_idx=1:framerate=30" -c:v h264_nvenc -preset p5 -cq 19 -y \
  "$(wslpath -w "$OUT")\\raw-b.mkv" < "$OUT/fifo" &
FFPID=$!; exec 3>"$OUT/fifo"; T0=$(now); sleep 1
stop() { echo q >&3; exec 3>&-; wait $FFPID 2>/dev/null; mark "fin de la grabación"; }
trap stop EXIT

# ---------------------------------------------------------------------------------------------- B1 · streams del clúster
front terminal; tmux send-keys -t rec "clear" Enter; sleep 1.5
mark "terminal: streams gobernados (incluye city-state del PR #7)"
typecmd "kubectl get eventstreamclaims -A -o custom-columns='EQUIPO:.metadata.namespace,STREAM:.metadata.name,TOPICO:.status.topic,CONTRATO:.status.contractVersion,READY:.status.conditions[?(@.type==\"Ready\")].status'"; sleep 7
typecmd "kubectl -n argocd get applications -l parkglobal.io/golden-path=event-stream"; sleep 7

# ---------------------------------------------------------------------------------------------- B2 · demo en vivo
typecmd "clear; docs/p2/video/demo.sh"; mark "demo: inicio"
for step in portada 1 2 3 4 5 6; do
  for _ in $(seq 1 240); do tmux capture-pane -p -t rec | grep -q '\[Enter\]' && break; sleep 0.5; done
  mark "demo: pantalla $step completa"; sleep ${PAUSE:-8}
  tmux send-keys -t rec Enter; sleep 1.5
done
waitprompt 120; mark "demo: entorno restaurado"; sleep 2
