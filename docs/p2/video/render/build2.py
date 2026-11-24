#!/usr/bin/env python3
"""Video v2: introducción animada + GRABACIÓN REAL (PR #7 en vivo, Argo CD, Apicurio, demo) + cierre animado.

Secuencia y cortes de la grabación en SEQ. Cada segmento dura lo que su audio (voz/NN.mp3); los tramos grabados se
recortan, se aceleran (solo esperas, con aviso en pantalla) o se congelan en su último cuadro para calzar con la voz.
Salidas en build2/: index.html (animación + marcos), timeline.json (audios) y edl.json (cortes para ffmpeg).
Fuentes de grabación: ../rec/out/raw.mkv (A, director.sh) y ../rec/out/raw-b.mkv (B, director-b.sh), monitor 2560x1440.
"""
import json
import pathlib

from build import CARD, GAP, INTRO, LEAD, OUTRO, VOZ, duration

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "build2"
FULL = [0, 0, 2560, 1392]                       # monitor sin la barra de tareas
EMAIL = [[690, 402, 276, 48], [1392, 402, 440, 48]]   # correo del autor del commit en la cabecera de Argo CD (se difumina)
TERM = "Terminal · clúster local (kind)"

CARDS = {1: "Qué se hizo", 2: "Así funciona · grabación real", 3: "En operación · demo en vivo", 4: "En resumen"}
# (audio, parte, tipo, etiqueta, cortes) · corte = (fuente, desde, hasta, velocidad, recorte, difuminar)
SEQ = [
    ("01", 1, "anim", None, None), ("02", 1, "anim", None, None), ("03", 1, "anim", None, None), ("04", 1, "anim", None, None),
    ("20", 2, "footage", "Terminal · el equipo Zonas declara su stream (streams/zonas/city-state)",
     [("A", 6.6, 13.4, 1, FULL, None)]),
    ("21", 2, "footage", "Terminal y GitHub · el equipo hace push y abre el pull request #7",
     [("A", 339.5, 342.0, 1, [0, 355, 2560, 1037], None), ("A", 359.0, 372.0, 1, FULL, None)]),
    ("22", 2, "footage", "GitHub Actions · la validación del PR #7 corre sola",
     [("A", 384.0, 392.0, 1, FULL, None), ("A", 400.0, 413.0, 1, FULL, None)]),
    ("23", 2, "footage", "GitHub · el PR #7 lo integra github-actions[bot]", [("A", 419.0, 431.0, 1, FULL, None)]),
    ("24", 2, "footage", "Argo CD · la espera real (~2 min) se muestra acelerada ×10; después, el árbol del stream",
     [("A", 431.0, 531.0, 10, FULL, None), ("A", 531.0, 535.4, 1, FULL, None), ("A", 535.4, 548.0, 1, FULL, EMAIL)]),
    ("25", 2, "footage", "Terminal · lo que quedó en el clúster",
     [("B", 8.0, 24.0, 1, FULL, None), ("A", 586.5, 592.0, 1, [0, 880, 2560, 512], None)]),
    ("26", 2, "footage", "Apicurio Registry · el contrato topology.state.city.v1", [("A", 594.0, 612.0, 1, FULL, None)]),
    ("08", 2, "anim", None, None),
    ("10", 3, "footage", TERM + " · demo.sh en vivo", [("B", 36.5, 44.0, 1, FULL, None)]),
    ("12", 3, "footage", TERM + " · demo.sh en vivo", [("B", 61.8, 71.3, 1, FULL, None)]),
    ("13", 3, "footage", TERM + " · demo.sh en vivo", [("B", 71.3, 84.8, 1, FULL, None)]),
    ("14", 3, "footage", TERM + " · demo.sh en vivo", [("B", 84.8, 94.3, 1, FULL, None)]),
    ("15", 3, "footage", TERM + " · demo.sh en vivo", [("B", 94.3, 104.3, 1, FULL, None)]),
    ("16", 3, "footage", TERM + " · demo.sh en vivo", [("B", 104.3, 123.4, 1, FULL, None)]),
    ("17", 4, "anim", None, None), ("18", 4, "anim", None, None),
]


def main():
    t, part, segs, cards = INTRO, 0, [], []
    for sid, p, kind, label, cuts in SEQ:
        if p != part:
            part = p
            cards.append({"part": p, "title": CARDS[p], "start": round(t, 3), "dur": CARD})
            t += CARD
        d = duration(VOZ / f"{sid}.mp3")
        segs.append({"id": sid, "part": p, "kind": kind, "label": label, "start": round(t, 3), "dur": round(d, 3), "file": f"{sid}.mp3"})
        t += d + GAP
    total = round(t - GAP + OUTRO, 3)
    # Ventana visible de cada tramo grabado: desde (inicio - LEAD) hasta el siguiente bloque.
    starts = sorted([c["start"] for c in cards] + [s["start"] - LEAD for s in segs]) + [total]
    edl = []
    for s, (_, _, kind, _, cuts) in zip(segs, SEQ):
        if kind != "footage":
            continue
        a = s["start"] - LEAD
        b = next(x for x in starts if x > a + 1e-6)
        edl.append({"id": s["id"], "at": round(a, 3), "dur": round(b - a, 3),
                    "cuts": [{"src": c[0], "t0": c[1], "t1": c[2], "speed": c[3], "crop": c[4], "blur": c[5]} for c in cuts]})
    OUT.mkdir(exist_ok=True)
    data = {"segs": segs, "cards": cards, "total": total, "lead": LEAD, "term": [{"events": [], "D": 0}] * 7}
    html = (HERE / "animacion.html").read_text().replace("__DATA__", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
    (OUT / "index.html").write_text(html)
    (OUT / "timeline.json").write_text(json.dumps({"segs": segs, "cards": cards, "total": total}, indent=1, ensure_ascii=False))
    (OUT / "edl.json").write_text(json.dumps(edl, indent=1))
    print(f"total {total:.1f} s ({total / 60:.2f} min) · {len(segs)} audios · {len(edl)} tramos grabados")
    for e in edl:
        real = sum((c["t1"] - c["t0"]) / c["speed"] for c in e["cuts"])
        print(f"  {e['id']}: ventana {e['dur']:5.1f} s · material {real:5.1f} s · {'congela el final' if real < e['dur'] else 'recorta el final'}")


if __name__ == "__main__":
    main()
