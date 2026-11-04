// Browser check for docs/design/mockups.html.
// Run: node docs/design/check-mockups.mjs
// It starts a headless Chromium (CHROME env var, or the newest Playwright
// headless shell), talks to it over the DevTools protocol, and checks:
// 5 canvases drawn under 300 ms, the page layout at desktop and phone width,
// no outside requests, no console errors, and hover and click in every look.
import { spawn } from 'node:child_process';
import { existsSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const pageUrl = pathToFileURL(resolve(here, 'mockups.html')).href;

function findChrome() {
  if (process.env.CHROME) return process.env.CHROME;
  const base = join(homedir(), 'Library/Caches/ms-playwright');
  if (existsSync(base)) {
    const dirs = readdirSync(base).filter(d => d.startsWith('chromium_headless_shell-')).sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]));
    for (const d of dirs) {
      for (const sub of ['chrome-headless-shell-mac-arm64', 'chrome-headless-shell-mac-x64', 'chrome-headless-shell-linux64']) {
        const p = join(base, d, sub, 'chrome-headless-shell');
        if (existsSync(p)) return p;
      }
    }
  }
  throw new Error('No headless Chromium found. Set CHROME to a Chromium binary.');
}

const failures = [];
const passes = [];
function check(ok, label, detail = '') {
  (ok ? passes : failures).push(`${label}${detail ? ' (' + detail + ')' : ''}`);
}

const profile = mkdtempSync(join(tmpdir(), 'cushion-check-'));
const chrome = spawn(findChrome(), ['--no-sandbox', '--disable-gpu', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const wsUrl = await new Promise((res, rej) => {
  let buf = '';
  const t = setTimeout(() => rej(new Error('Chromium did not start in 15 s')), 15000);
  chrome.stderr.on('data', d => {
    buf += d;
    const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
    if (m) { clearTimeout(t); res(m[1]); }
  });
  chrome.on('exit', code => rej(new Error(`Chromium exited early with code ${code}`)));
});
const port = new URL(wsUrl).port;
const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const pageTarget = targets.find(t => t.type === 'page');
if (!pageTarget) throw new Error('No page target in Chromium');

const ws = new WebSocket(pageTarget.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let nextId = 1;
const pending = new Map();
const consoleErrors = [];
const outsideRequests = [];
ws.onmessage = ev => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const { res, rej } = pending.get(msg.id); pending.delete(msg.id);
    msg.error ? rej(new Error(JSON.stringify(msg.error))) : res(msg.result);
  } else if (msg.method === 'Runtime.exceptionThrown') {
    consoleErrors.push(msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text);
  } else if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') {
    consoleErrors.push(msg.params.args.map(a => a.value ?? a.description).join(' '));
  } else if (msg.method === 'Network.requestWillBeSent') {
    const u = msg.params.request.url;
    if (!u.startsWith('file:') && !u.startsWith('data:') && !u.startsWith('about:')) outsideRequests.push(u);
  }
};
const send = (method, params = {}) => new Promise((res, rej) => {
  const id = nextId++; pending.set(id, { res, rej }); ws.send(JSON.stringify({ id, method, params }));
});
async function evaluate(expr) {
  const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(`Page error in check: ${r.exceptionDetails.exception?.description || r.exceptionDetails.text}`);
  return r.result.value;
}
const wait = ms => new Promise(r => setTimeout(r, ms));
async function waitFor(expr, label, ms = 10000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await evaluate(expr)) return true; await wait(50); }
  throw new Error(`Timed out waiting for: ${label}`);
}
async function load(width, height, dpr) {
  await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: dpr, mobile: width < 600 });
  await send('Page.navigate', { url: pageUrl });
  await waitFor(`document.querySelectorAll('canvas[data-ms]').length === 5`, '5 canvases drawn');
}
async function mouse(type, x, y) {
  await send('Input.dispatchMouseEvent', { type, x, y, button: type === 'mouseMoved' ? 'none' : 'left', clickCount: type === 'mouseMoved' ? 0 : 1 });
}
async function click(x, y) { await mouse('mouseMoved', x, y); await mouse('mousePressed', x, y); await mouse('mouseReleased', x, y); }

try {
  await send('Runtime.enable'); await send('Network.enable'); await send('Page.enable');

  // ---- Desktop width, retina ----
  await load(1600, 1200, 2);
  const info = await evaluate(`({
    title: document.title,
    ask: document.getElementById('ask')?.textContent.trim(),
    canvases: document.querySelectorAll('canvas').length,
    ms: [...document.querySelectorAll('canvas')].map(c => Number(c.dataset.ms)),
    sizes: [...document.querySelectorAll('canvas')].map(c => c.width + 'x' + c.height),
    cols: getComputedStyle(document.getElementById('grid')).gridTemplateColumns.split(' ').length,
    sideScroll: document.documentElement.scrollWidth > innerWidth,
    sample: document.body.textContent.includes('Sample data'),
    status: [...document.querySelectorAll('.status span')].map(s => s.textContent),
    captions: [...document.querySelectorAll('.card h2')].map(h => h.textContent),
    files: Number((document.querySelector('.meta').textContent.match(/([\\d,]+) files/) || [])[1]?.replace(/,/g, '')),
  })`);
  check(info.title === 'Cushion looks', 'title is "Cushion looks"', info.title);
  check(info.ask === 'Pick one of these 5 looks.', '#ask text', info.ask);
  check(info.canvases === 5, '5 canvases', String(info.canvases));
  check(info.ms.every(m => m > 0 && m < 300), 'each map draws in under 300 ms', info.ms.join(', ') + ' ms');
  check(info.sizes.every(s => Number(s.split('x')[0]) >= 2200), 'canvases drawn at device pixel ratio 2', info.sizes.join(', '));
  check(info.cols === 2, '2 columns at 1600 px', String(info.cols));
  check(!info.sideScroll, 'no sideways scroll at 1600 px');
  check(info.sample, 'page says "Sample data"');
  check(info.status.every(s => s === '386 GB used · 64 GB free · 12 GB not counted · 3 folders unreadable'), 'status line text');
  check(info.captions.length === 5, '5 captions', info.captions.join(' | '));
  check(info.files >= 2800 && info.files <= 3300, 'about 3,000 files', String(info.files));
  const rootSize = await evaluate(`document.querySelector('.tree .row .num').textContent`);
  check(rootSize === '386 GB', 'tree root is 386 GB', rootSize);

  // ---- Interaction in every look ----
  for (let i = 0; i < 5; i++) {
    const name = info.captions[i];
    await evaluate(`document.querySelectorAll('.card')[${i}].scrollIntoView({block: 'start'})`);
    await wait(50);
    const r = await evaluate(`(() => { const b = document.querySelectorAll('.card')[${i}].querySelector('canvas').getBoundingClientRect(); return {x: b.left, y: b.top, w: b.width, h: b.height}; })()`);
    const px = r.x + r.w * 0.37, py = r.y + r.h * 0.41;
    await mouse('mouseMoved', px, py);
    const hover = await evaluate(`document.querySelectorAll('.card')[${i}].querySelector('.status span').textContent`);
    check(/^\/.+ · [\d.]+ (GB|MB|KB|B)$/.test(hover), `${name}: hover shows path and size`, hover);

    await click(px, py);
    const sel = await evaluate(`(() => {
      const card = document.querySelectorAll('.card')[${i}];
      const body = card.querySelector('.tree .body'), row = body.querySelector('.row.sel'), fr = card.querySelector('.frame');
      if (!row) return null;
      const rb = row.getBoundingClientRect(), bb = body.getBoundingClientRect();
      return { visible: rb.top >= bb.top - 1 && rb.bottom <= bb.bottom + 1, frame: fr.style.display, name: row.querySelector('.tx').textContent };
    })()`);
    check(!!sel && sel.frame === 'block', `${name}: map click frames the box`, sel ? sel.name : 'no selected row');
    check(!!sel && sel.visible, `${name}: map click scrolls its tree row into view`);
    check(!!sel && hover.split(' · ')[0].endsWith('/' + sel.name), `${name}: selected row is the hovered file`, sel ? sel.name : '');

    // Click the "Users" row (row 2) and expect a frame around that folder.
    const usersRow = await evaluate(`(() => { const card = document.querySelectorAll('.card')[${i}]; const b = card.querySelector('.tree .body'); b.scrollTop = 0; const row = [...b.querySelectorAll('.row')].find(x => x.querySelector('.tx').textContent === 'Users'); const rr = row.getBoundingClientRect(); return {x: rr.left + rr.width * 0.5, y: rr.top + rr.height / 2}; })()`);
    await click(usersRow.x, usersRow.y);
    const fr = await evaluate(`(() => { const card = document.querySelectorAll('.card')[${i}]; const f = card.querySelector('.frame'); const m = card.querySelector('.map'); return { sel: card.querySelector('.tree .row.sel .tx')?.textContent, w: f.offsetWidth / m.offsetWidth, h: f.offsetHeight / m.offsetHeight }; })()`);
    check(fr.sel === 'Users' && fr.w * fr.h > 0.6 && fr.w * fr.h < 0.95, `${name}: tree row click frames its folder`, `Users frame covers ${(fr.w * fr.h * 100).toFixed(0)}% of the map; Users is 79% of the disk`);

    // Click the first file type and expect the map pixels to change, then change back.
    const sum = `(() => { const c = document.querySelectorAll('.card')[${i}].querySelector('canvas'); const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let s = 0; for (let k = 0; k < d.length; k += 97) s += d[k]; return s; })()`;
    const before = await evaluate(sum);
    const typeRow = await evaluate(`(() => { const rr = document.querySelectorAll('.card')[${i}].querySelector('.types .row').getBoundingClientRect(); return {x: rr.left + rr.width / 2, y: rr.top + rr.height / 2}; })()`);
    await click(typeRow.x, typeRow.y);
    const during = await evaluate(sum);
    const typeSel = await evaluate(`!!document.querySelectorAll('.card')[${i}].querySelector('.types .row.sel')`);
    check(typeSel && during !== before, `${name}: file type click highlights its boxes`);
    await click(typeRow.x, typeRow.y);
    const after = await evaluate(sum);
    check(after === before, `${name}: second file type click clears the highlight`);
  }
  const words = await evaluate(`document.body.innerText.toLowerCase()`);
  check(!/\btrash\b|\bdelete\b/.test(words), 'no Delete or Trash text on the page');

  // ---- Phone width ----
  await load(390, 844, 3);
  const phone = await evaluate(`({ cols: getComputedStyle(document.getElementById('grid')).gridTemplateColumns.split(' ').length, sideScroll: document.documentElement.scrollWidth > innerWidth, ms: [...document.querySelectorAll('canvas')].map(c => Number(c.dataset.ms)), w: document.querySelector('canvas').width })`);
  check(phone.cols === 1, '1 column at 390 px', String(phone.cols));
  check(!phone.sideScroll, 'no sideways scroll at 390 px');
  check(phone.w === 2360, 'device pixel ratio is capped at 2', `canvas width ${phone.w} at ratio 3`);
  check(phone.ms.every(m => m > 0 && m < 300), 'each map draws in under 300 ms at phone width', phone.ms.join(', ') + ' ms');

  check(outsideRequests.length === 0, 'no outside requests', outsideRequests.join(', '));
  check(consoleErrors.length === 0, 'no console errors', consoleErrors.join(' | '));
} catch (e) {
  failures.push(`check stopped: ${e.message}`);
} finally {
  ws.close();
  const exited = new Promise(res => chrome.once('exit', res));
  chrome.kill();
  await Promise.race([exited, wait(5000)]);
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}

for (const p of passes) console.log('PASS ' + p);
for (const f of failures) console.log('FAIL ' + f);
console.log(`${passes.length} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);
