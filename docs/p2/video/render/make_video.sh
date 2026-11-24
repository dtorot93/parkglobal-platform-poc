#!/usr/bin/env bash
# Arma el video del Proyecto 2: animación + terminal grabada (Chrome sin interfaz) + narración (ElevenLabs).
#   ./make_video.sh            video completo -> ../video-p2.mp4
#   ./make_video.sh stills T1,T2,...   capturas PNG en build/stills para revisar
# Usa Node, Chrome y ffmpeg de Windows (desde WSL). No instala nada.
set -euo pipefail
cd "$(dirname "$0")"
FFDIR=$(ls -d /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg*/*/bin 2>/dev/null | tail -1)
[ -n "$FFDIR" ] || { echo "No se encontró ffmpeg de Windows (winget Gyan.FFmpeg)"; exit 1; }
NODE="/mnt/c/Program Files/nodejs/node.exe"
win() { wslpath -w "$1"; }
export FFMPEG="$(win "$FFDIR/ffmpeg.exe")"; export WSLENV=FFMPEG/w:${WSLENV:-}
FFMPEG_EXE="$FFDIR/ffmpeg.exe"

python3 build.py
URL="file:$(win "$PWD/build/index.html" | tr '\\' /)"

if [ "${1:-}" = stills ]; then
  rm -rf build/stills; "$NODE" "$(win capture.mjs)" "$URL" "$(win "$PWD/build/stills")" stills "$2"; exit
fi

WT=$(wslpath "$(cmd.exe /c "echo %TEMP%" 2>/dev/null | tr -d '\r')")/pg-video; mkdir -p "$WT"
"$NODE" "$(win capture.mjs)" "$URL" "$(win "$WT/video.mp4")" 30

# Audio: cada segmento en su instante exacto de la línea de tiempo, volumen normalizado para web (-16 LUFS).
args=(); filt=""; i=0; total=$(python3 -c "import json;print(json.load(open('build/timeline.json'))['total'])")
while read -r file start; do
  args+=(-i "$(win "$PWD/../voz/$file")")
  filt+="[$i:a]aresample=48000,adelay=$(python3 -c "print(int($start*1000))"):all=1[a$i];"; i=$((i+1))
done < <(python3 -c "import json;[print(s['file'],s['start']) for s in json.load(open('build/timeline.json'))['segs']]")
for j in $(seq 0 $((i-1))); do filt+="[a$j]"; done
filt+="amix=inputs=$i:normalize=0,apad,atrim=0:$total,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000[aout]"
"$FFMPEG_EXE" -y -hide_banner -loglevel error "${args[@]}" -filter_complex "$filt" -map "[aout]" -c:a aac -b:a 192k "$(win "$WT/audio.m4a")"
"$FFMPEG_EXE" -y -hide_banner -loglevel error -i "$(win "$WT/video.mp4")" -i "$(win "$WT/audio.m4a")" -map 0:v -map 1:a -c copy -movflags +faststart -t "$total" "$(win "$PWD/../video-p2.mp4")"
rm -rf "$WT"
echo "listo: $(cd .. && pwd)/video-p2.mp4"
