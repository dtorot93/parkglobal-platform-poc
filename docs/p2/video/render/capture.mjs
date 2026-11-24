// Renderiza build/index.html cuadro a cuadro con Chrome sin interfaz (protocolo DevTools) y entrega los cuadros a ffmpeg.
// Corre con el Node de Windows (WebSocket nativo de Node 22), junto al Chrome y al ffmpeg de Windows.
//   node capture.mjs <url> <salida.mp4> <fps>                    video completo
//   node capture.mjs <url> <carpeta> stills <t1,t2,...>          capturas PNG para revisar
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const [, , url, out, a3, a4] = process.argv;
const CHROME = process.env.CHROME || "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const FFMPEG = process.env.FFMPEG || "ffmpeg";
const sleep = ms => new Promise(r => setTimeout(r, ms));
const port = 9400 + Math.floor(Math.random() * 400);
const prof = fs.mkdtempSync(path.join(os.tmpdir(), "pgv-"));
const chrome = spawn(CHROME, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`, "--hide-scrollbars",
  "--force-device-scale-factor=1", "--window-size=1920,1080", "--mute-audio", "--allow-file-access-from-files", "about:blank"], { stdio: "ignore" });
const done = code => { try { chrome.kill(); } catch {} setTimeout(() => { try { fs.rmSync(prof, { recursive: true, force: true }); } catch {} process.exit(code); }, 800); };

async function json(u) {
  for (let i = 0; i < 150; i++) { try { return await (await fetch(u)).json(); } catch { await sleep(200); } }
  throw new Error("Chrome no respondió en el puerto " + port);
}
try {
  const page = (await json(`http://127.0.0.1:${port}/json/list`)).find(t => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let id = 0; const pending = new Map();
  ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
  const send = (method, params = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
  const evalJS = async expr => { const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true }); if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails)); return r.result?.result?.value; };

  await send("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
  await send("Page.enable");
  await send("Page.navigate", { url });
  for (let i = 0; ; i++) { if (await evalJS("window.READY === true")) break; if (i > 200) throw new Error("la página no quedó lista: " + JSON.stringify(await evalJS("window.__errors"))); await sleep(150); }
  const errors = await evalJS("window.__errors || []");
  if (errors.length) throw new Error("errores en la página: " + errors.join(" | "));
  const total = await evalJS("window.DURATION");
  const shot = async t => { await evalJS(`seek(${t})`); const r = await send("Page.captureScreenshot", { format: a3 === "stills" ? "png" : "jpeg", quality: 93 }); return Buffer.from(r.result.data, "base64"); };

  if (a3 === "stills") {
    fs.mkdirSync(out, { recursive: true });
    for (const t of a4.split(",").map(Number)) fs.writeFileSync(path.join(out, `t${t.toFixed(1).padStart(6, "0")}.png`), await shot(t));
    console.log(`capturas en ${out}`);
    done(0);
  } else {
    const fps = +a3 || 30, n = Math.ceil(total * fps);
    const ff = spawn(FFMPEG, ["-y", "-hide_banner", "-loglevel", "error", "-f", "image2pipe", "-framerate", String(fps), "-c:v", "mjpeg", "-i", "-",
      "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-r", String(fps), out], { stdio: ["pipe", "inherit", "inherit"] });
    const t0 = Date.now();
    for (let f = 0; f < n; f++) {
      const buf = await shot(f / fps);
      if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once("drain", r));
      if (f % 300 === 0) console.log(`cuadro ${f}/${n} · ${((Date.now() - t0) / 1000).toFixed(0)} s`);
    }
    ff.stdin.end();
    ff.on("close", code => { console.log(`video ${out} (${n} cuadros, ${((Date.now() - t0) / 1000).toFixed(0)} s)`); done(code); });
  }
} catch (e) { console.error(e.message || e); done(1); }
