// Control de un Chrome VISIBLE (perfil aparte) en el monitor de grabación, por el protocolo DevTools.
// Corre con el Node de Windows. Uso:
//   node cdp.mjs launch <x> <y> <w> <h>       abre Chrome (perfil propio, escala 1,5) en esa posición
//   node cdp.mjs nav <url>                    navega y espera la carga
//   node cdp.mjs eval "<js>"                  evalúa JS en la página y muestra el resultado
//   node cdp.mjs scroll <y> [ms]              desplazamiento suave hasta y (px CSS) en ms
//   node cdp.mjs type "<texto>"               escribe en el elemento con foco
//   node cdp.mjs key Enter                    pulsa una tecla
//   node cdp.mjs close                        cierra ese Chrome
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const PORT = 9555;
const CHROME = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const PROFILE = path.join(os.tmpdir(), "pg-rec-chrome");
const sleep = ms => new Promise(r => setTimeout(r, ms));
const [, , cmd, ...args] = process.argv;

if (cmd === "launch") {
  const [x, y, w, h] = args;
  fs.mkdirSync(PROFILE, { recursive: true });
  const p = spawn(CHROME, [`--user-data-dir=${PROFILE}`, `--remote-debugging-port=${PORT}`, `--window-position=${x},${y}`, `--window-size=${w},${h}`,
    "--force-device-scale-factor=1.5", "--no-first-run", "--no-default-browser-check", "--disable-features=Translate,AutofillServerCommunication",
    "--disable-session-crashed-bubble", "--hide-crash-restore-bubble", "--lang=es", "about:blank"], { detached: true, stdio: "ignore" });
  p.unref();
  for (let i = 0; i < 100; i++) { try { await fetch(`http://127.0.0.1:${PORT}/json/version`); console.log("chrome listo"); process.exit(0); } catch { await sleep(200); } }
  console.error("chrome no respondió"); process.exit(1);
}

const targets = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
const page = targets.find(t => t.type === "page" && !t.url.startsWith("devtools://"));
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 0; const pending = new Map(); const events = [];
ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } else if (m.method) events.push(m); };
const send = (method, params = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
const evalJS = async e => (await send("Runtime.evaluate", { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;

try {
  if (cmd === "nav") {
    await send("Page.enable"); await send("Page.navigate", { url: args[0] });
    for (let i = 0; i < 150; i++) { if ((await evalJS("document.readyState")) === "complete") break; await sleep(200); }
  } else if (cmd === "eval") {
    console.log(JSON.stringify(await evalJS(args[0])));
  } else if (cmd === "scroll") {
    const [y, ms = 1500] = args.map(Number);
    await evalJS(`new Promise(r => { const y0 = scrollY, t0 = performance.now(), d = ${ms};
      const f = t => { const p = Math.min(1, (t - t0) / d), e = p < .5 ? 2*p*p : 1 - Math.pow(-2*p + 2, 2) / 2; scrollTo(0, y0 + (${y} - y0) * e); p < 1 ? requestAnimationFrame(f) : r(); };
      requestAnimationFrame(f); })`);
  } else if (cmd === "type") {
    for (const ch of args[0]) { await send("Input.insertText", { text: ch }); await sleep(45); }
  } else if (cmd === "key") {
    const key = args[0]; const code = { Enter: 13, Tab: 9 }[key];
    await send("Input.dispatchKeyEvent", { type: "keyDown", key, windowsVirtualKeyCode: code, text: key === "Enter" ? "\r" : undefined });
    await send("Input.dispatchKeyEvent", { type: "keyUp", key, windowsVirtualKeyCode: code });
  } else if (cmd === "close") {
    await send("Browser.close").catch(() => {});
  } else throw new Error("comando desconocido: " + cmd);
  ws.close(); process.exit(0);
} catch (e) { console.error(e.message || e); process.exit(1); }
