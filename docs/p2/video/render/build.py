#!/usr/bin/env python3
"""Prepara el video: línea de tiempo (a partir de la duración real de cada audio) y grabación de la terminal.

Entradas:
  ../voz/NN.mp3                 narración (ElevenLabs), un archivo por segmento (01..18)
  demo-rec/raw, demo-rec/timing  sesión REAL de demo.sh grabada con `script -T timing -O raw`
  animacion.html                 plantilla con el marcador __DATA__
Salidas:
  build/index.html               página autocontenida que se renderiza cuadro a cuadro
  build/timeline.json            inicio de cada audio (lo usa la mezcla de audio)

Uso: python3 build.py   (mide los audios con el ffprobe.exe de Windows o con ffprobe si existe)
"""
import codecs
import json
import pathlib
import re
import shutil
import subprocess

HERE = pathlib.Path(__file__).resolve().parent
VOZ = HERE.parent / "voz"
OUT = HERE / "build"

INTRO, GAP, CARD, OUTRO, LEAD = 0.6, 0.55, 1.8, 3.0, 0.35
PARTS = {1: "Qué se hizo", 2: "Cómo se hizo", 3: "En qué beneficia · demo en vivo", 4: "En resumen"}
PART_OF = {**{i: 1 for i in range(1, 5)}, **{i: 2 for i in range(5, 10)}, **{i: 3 for i in range(10, 17)}, 17: 4, 18: 4}


def ffprobe() -> list[str]:
    if shutil.which("ffprobe"):
        return ["ffprobe"]
    win = sorted(pathlib.Path("/mnt/c/Users").glob("*/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg*/*/bin/ffprobe.exe"))
    if not win:
        raise SystemExit("No se encontró ffprobe (ni en WSL ni en Windows)")
    return [str(win[-1])]


def duration(path: pathlib.Path) -> float:
    exe = ffprobe()
    arg = str(path)
    if exe[0].endswith(".exe"):
        arg = subprocess.run(["wslpath", "-w", arg], capture_output=True, text=True, check=True).stdout.strip()
    out = subprocess.run(exe + ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", arg],
                         capture_output=True, text=True, check=True).stdout
    return float(out.strip())


def timeline() -> dict:
    t, part, segs, cards = INTRO, 0, [], []
    for n in range(1, 19):
        f = VOZ / f"{n:02d}.mp3"
        if not f.exists():
            raise SystemExit(f"Falta {f}")
        if PART_OF[n] != part:
            part = PART_OF[n]
            cards.append({"part": part, "title": PARTS[part], "start": round(t, 3), "dur": CARD})
            t += CARD
        d = duration(f)
        segs.append({"id": f"{n:02d}", "part": part, "start": round(t, 3), "dur": round(d, 3), "file": f.name})
        t += d + GAP
    return {"segs": segs, "cards": cards, "total": round(t - GAP + OUTRO, 3), "lead": LEAD}


def terminal() -> list[dict]:
    """Pantallas de la demo: [(segundos desde el inicio de la pantalla, texto)], sin el aviso [Enter]."""
    raw = (HERE / "demo-rec/raw").read_bytes()
    raw = raw[raw.index(b"\n") + 1:]                       # la cabecera "Script started..." no está en timing
    dec, chars, pos, t = codecs.getincrementaldecoder("utf-8")(), [], 0, 0.0
    for line in (HERE / "demo-rec/timing").read_text().split("\n"):
        if not line.strip():
            continue
        delay, n = line.split()
        t += float(delay)
        for ch in dec.decode(raw[pos:pos + int(n)]):
            chars.append((t, ch))
        pos += int(n)
    text = "".join(c for _, c in chars)
    times = [tt for tt, _ in chars]
    clear = "\x1b[H\x1b[2J\x1b[3J"
    starts = [m.start() for m in re.finditer(re.escape(clear), text)]
    end_all = text.find("Restaurando")
    screens = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else end_all
        body_start = s + len(clear)
        seg = text[body_start:e]
        prompt = seg.rfind("\x1b[2m[Enter]")            # fin del contenido de la pantalla
        if prompt >= 0:
            seg = seg[:prompt]
        t0 = times[s]
        evs, cur, cur_t = [], "", None
        for k, ch in enumerate(seg):
            tt = round(times[body_start + k] - t0, 3)
            if cur_t is None or tt == cur_t:
                cur += ch; cur_t = tt
            else:
                evs.append([cur_t, cur]); cur, cur_t = ch, tt
        if cur:
            evs.append([cur_t, cur])
        screens.append({"events": evs, "D": evs[-1][0] if evs else 0})
    if len(screens) != 7:
        raise SystemExit(f"Se esperaban 7 pantallas (portada + 6 pasos) y hay {len(screens)}")
    return screens


def main():
    tl = timeline()
    tl["term"] = terminal()
    OUT.mkdir(exist_ok=True)
    html = (HERE / "animacion.html").read_text()
    (OUT / "index.html").write_text(html.replace("__DATA__", json.dumps(tl, ensure_ascii=False).replace("</", "<\\/")))
    (OUT / "timeline.json").write_text(json.dumps({k: tl[k] for k in ("segs", "cards", "total")}, indent=1))
    print(f"total {tl['total']:.1f} s · {len(tl['segs'])} audios · pantallas de demo: "
          + ", ".join(f"{s['D']:.1f}s" for s in tl["term"]))


if __name__ == "__main__":
    main()
