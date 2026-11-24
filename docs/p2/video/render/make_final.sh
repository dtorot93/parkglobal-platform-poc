#!/usr/bin/env bash
# Video v2 (grabación real, 4 min): ./make_final.sh     -> ../video-p2-4min.mp4
#                            ./make_final.sh clip 24    -> solo el tramo grabado 24 en build2/clips/ (para revisar)
#                            ./make_final.sh stills T1,T2  -> capturas de la animación/marcos en build2/stills
set -euo pipefail
cd "$(dirname "$0")"
FFDIR=$(ls -d /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg*/*/bin 2>/dev/null | tail -1)
FF="$FFDIR/ffmpeg.exe"; NODE="/mnt/c/Program Files/nodejs/node.exe"
win() { wslpath -w "$1"; }
export FFMPEG="$(win "$FF")"; export WSLENV=FFMPEG/w:${WSLENV:-}
RAW_A=$(win "$PWD/../rec/out/raw.mkv"); RAW_B=$(win "$PWD/../rec/out/raw-b.mkv")
python3 build2.py
URL="file:$(win "$PWD/build2/index.html" | tr '\\' /)"
WT=$(wslpath "$(cmd.exe /c "echo %TEMP%" 2>/dev/null | tr -d '\r')")/pg-video2; mkdir -p "$WT" build2/clips

if [ "${1:-}" = stills ]; then rm -rf build2/stills; "$NODE" "$(win ../render/capture.mjs)" "$URL" "$(win "$PWD/build2/stills")" stills "$2"; exit; fi

# Un tramo grabado -> clip 1680x914 a 30 fps, con la duración exacta de su ventana.
clip() { # $1 = id
  python3 - "$1" "$RAW_A" "$RAW_B" > "$WT/clip-$1.args" <<'PY'
import json, sys
sid, A, B = sys.argv[1:]
edl = json.load(open("build2/edl.json")); idx = [e["id"] for e in edl].index(sid); e = edl[idx]
prev_adj = idx > 0 and abs(edl[idx-1]["at"] + edl[idx-1]["dur"] - e["at"]) < 1e-3
next_adj = idx + 1 < len(edl) and abs(e["at"] + e["dur"] - edl[idx+1]["at"]) < 1e-3
args, filt = [], []
for i, c in enumerate(e["cuts"]):
    args += ["-ss", str(c["t0"]), "-t", str(c["t1"] - c["t0"]), "-i", A if c["src"] == "A" else B]
    ch = f"[{i}:v]setpts=(PTS-STARTPTS)/{c['speed']}"
    if c["blur"]:
        n = len(c["blur"]); ch += f",split={n+1}[b{i}0]" + "".join(f"[b{i}{k+1}]" for k in range(n)) + ";"
        cur = f"[b{i}0]"
        for k, (x, y, w, h) in enumerate(c["blur"]):
            ch += f"[b{i}{k+1}]crop={w}:{h}:{x}:{y},boxblur=luma_radius=10:luma_power=3:chroma_radius=5:chroma_power=3[bb{i}{k}];{cur}[bb{i}{k}]overlay={x}:{y}[o{i}{k}];"
            cur = f"[o{i}{k}]"
        ch += cur
    else:
        ch += ","
    x, y, w, h = c["crop"]
    ch += ("" if not c["blur"] else "") + f"{'null,' if c['blur'] else ''}crop={w}:{h}:{x}:{y},scale=1680:914:force_original_aspect_ratio=decrease:flags=lanczos," \
          f"pad=1680:914:0:0:color=0x0c0c0c,fps=30,format=yuv420p,setsar=1[c{i}]"
    filt.append(ch)
n = len(e["cuts"]); d = e["dur"]
tail = "".join(f"[c{i}]" for i in range(n)) + f"concat=n={n}:v=1:a=0,tpad=stop_mode=clone:stop_duration=120,trim=duration={d},setpts=PTS-STARTPTS"
if not prev_adj: tail += ",fade=t=in:st=0:d=0.4:color=0x0c0c0c"
if not next_adj: tail += f",fade=t=out:st={max(0, d - 0.35):.3f}:d=0.35:color=0x0c0c0c"
tail += "[v]"
print("\n".join(args + ["-filter_complex", ";".join(filt) + ";" + tail, "-map", "[v]", "-frames:v", str(round(d * 30))]))
PY
  mapfile -t ARGS < "$WT/clip-$1.args"
  "$FF" -y -hide_banner -loglevel error "${ARGS[@]}" -c:v libx264 -preset medium -crf 16 -pix_fmt yuv420p "$(win "$PWD/build2/clips/$1.mp4")"
}

if [ "${1:-}" = clip ]; then clip "$2"; echo "build2/clips/$2.mp4"; exit; fi

# 1) Tramos grabados
for id in $(python3 -c "import json;print(' '.join(e['id'] for e in json.load(open('build2/edl.json'))))"); do clip "$id"; echo "clip $id"; done
# 2) Animación y marcos (cuadro a cuadro)
"$NODE" "$(win ../render/capture.mjs)" "$URL" "$(win "$WT/base.mp4")" 30
# 3) Composición: cada clip dentro del recuadro (x=120, y=150) en su instante
python3 - "$(win "$WT/base.mp4")" "$(win "$PWD/build2/clips")" > "$WT/compose.args" <<'PY'
import json, sys
base, clips = sys.argv[1:]
edl = json.load(open("build2/edl.json"))
args = ["-i", base]; f = []; cur = "[0:v]"
for k, e in enumerate(edl, 1):
    args += ["-i", f"{clips}\\{e['id']}.mp4"]
    f.append(f"[{k}:v]setpts=PTS-STARTPTS+{e['at']}/TB[f{k}]")
    f.append(f"{cur}[f{k}]overlay=120:150:eof_action=pass:enable='between(t,{e['at']},{e['at'] + e['dur']})'[v{k}]"); cur = f"[v{k}]"
print("\n".join(args + ["-filter_complex", ";".join(f), "-map", cur]))
PY
mapfile -t ARGS < "$WT/compose.args"
"$FF" -y -hide_banner -loglevel error "${ARGS[@]}" -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -r 30 "$(win "$WT/video.mp4")"
# 4) Audio en su instante exacto, normalizado a -16 LUFS
args=(); filt=""; i=0; total=$(python3 -c "import json;print(json.load(open('build2/timeline.json'))['total'])")
while read -r file start trim tempo; do
  args+=(-i "$(win "$PWD/../voz/$file")")
  filt+="[$i:a]atrim=start=$trim,asetpts=PTS-STARTPTS,atempo=$tempo,aresample=48000,adelay=$(python3 -c "print(int($start*1000))"):all=1[a$i];"; i=$((i+1))
done < <(python3 -c "import json;[print(s['file'],s['start'],s.get('trim',0),s.get('tempo',1)) for s in json.load(open('build2/timeline.json'))['segs']]")
for j in $(seq 0 $((i-1))); do filt+="[a$j]"; done
filt+="amix=inputs=$i:normalize=0,apad,atrim=0:$total,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000[aout]"
"$FF" -y -hide_banner -loglevel error "${args[@]}" -filter_complex "$filt" -map "[aout]" -c:a aac -b:a 192k "$(win "$WT/audio.m4a")"
"$FF" -y -hide_banner -loglevel error -i "$(win "$WT/video.mp4")" -i "$(win "$WT/audio.m4a")" -map 0:v -map 1:a -c copy -movflags +faststart -t "$total" "$(win "$PWD/../video-p2-4min.mp4")"
rm -rf "$WT"
echo "listo: $(cd .. && pwd)/video-p2-4min.mp4"
