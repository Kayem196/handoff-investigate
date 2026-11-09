// Optional local Chromium checks. Node's built-in WebSocket is the only CDP client.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { watch } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [browser, completeFile, incompleteFile, hostileFile, destination] = process.argv.slice(2);
assert(browser && completeFile && incompleteFile && hostileFile && destination,
  'Usage: node verify-report.mjs <chromium.exe> <complete.html> <incomplete.html> <hostile.html> <new-output-directory>');
const output = resolve(destination);
await mkdir(output); // Never overwrite an earlier QA run.
const profile = join(output, 'browser-profile');
await mkdir(profile);
const result = { status: 'ERROR', checks: [], screenshots: [], browserStopped: false };
let socket;
let send;
const child = spawn(browser, [
  '--headless=new', '--no-first-run', '--no-default-browser-check',
  '--disable-background-networking', '--disable-component-update', '--disable-sync',
  '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0',
  `--user-data-dir=${profile}`, 'about:blank',
], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
let diagnostic = '';
child.stderr.on('data', chunk => { diagnostic = (diagnostic + chunk).slice(-8000); });
const exited = new Promise((resolveExit, reject) => { child.once('exit', resolveExit); child.once('error', reject); });

function check(condition, name) {
  assert(condition, name);
  result.checks.push(name);
}

async function waitForEndpoint() {
  const file = join(profile, 'DevToolsActivePort');
  return new Promise((resolveFile, reject) => {
    const timer = setTimeout(() => finish(new Error('Chromium did not expose its local CDP endpoint.')), 15000);
    const watcher = watch(profile, () => { void inspect(); });
    let complete = false;
    function finish(error, text) {
      if (complete) return;
      complete = true;
      clearTimeout(timer);
      watcher.close();
      if (error) reject(error); else resolveFile(text);
    }
    async function inspect() {
      try {
        const text = await readFile(file, 'utf8');
        if (/^\d+\r?\n\/devtools\/browser\//.test(text)) finish(null, text);
      } catch (error) { if (error.code !== 'ENOENT') finish(error); }
    }
    void inspect();
    void exited.then(() => finish(new Error('Chromium exited before CDP was ready.')), finish);
  });
}

try {
  const [port, endpoint] = (await waitForEndpoint()).trim().split(/\r?\n/);
  assert(Number(port) > 0 && Number(port) <= 65535 && endpoint.startsWith('/devtools/browser/'));
  socket = new WebSocket(`ws://127.0.0.1:${port}${endpoint}`);
  await new Promise((ready, reject) => { socket.addEventListener('open', ready, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  let next = 0;
  const pending = new Map();
  const events = [];
  const listeners = new Set();
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const call = pending.get(message.id);
      if (!call) return;
      clearTimeout(call.timer);
      pending.delete(message.id);
      if (message.error) call.reject(new Error(JSON.stringify(message.error))); else call.resolve(message.result);
    } else { events.push(message); for (const listener of listeners) listener(message); }
  });
  socket.addEventListener('close', () => {
    for (const call of pending.values()) { clearTimeout(call.timer); call.reject(new Error('CDP connection closed.')); }
    pending.clear();
  });
  send = (method, params = {}, sessionId) => new Promise((resolveCall, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 15000);
    pending.set(id, { resolve: resolveCall, reject, timer });
    socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  result.browser = await send('Browser.getVersion');
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const call = (method, params) => send(method, params, sessionId);
  const evaluate = async expression => {
    const response = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    assert(!response.exceptionDetails, JSON.stringify(response.exceptionDetails));
    return response.result.value;
  };
  await call('Page.enable');
  await call('Runtime.enable');
  await call('Network.enable');
  const loaded = start => {
    const match = event => event.sessionId === sessionId && event.method === 'Page.loadEventFired';
    if (events.slice(start).some(match)) return Promise.resolve();
    return new Promise((resolveLoad, reject) => {
      const listener = event => { if (match(event)) { clearTimeout(timer); listeners.delete(listener); resolveLoad(); } };
      const timer = setTimeout(() => { listeners.delete(listener); reject(new Error('Document did not finish loading.')); }, 15000);
      listeners.add(listener);
    });
  };
  for (const [name, file] of [['complete', completeFile], ['incomplete', incompleteFile], ['hostile', hostileFile]]) {
    await call('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
    const start = events.length;
    const navigation = await call('Page.navigate', { url: pathToFileURL(resolve(file)).href });
    assert(!navigation.errorText, navigation.errorText);
    await loaded(start);
    const page = await evaluate(`({
      headings: document.querySelectorAll('h1').length,
      title: document.title,
      text: document.body.innerText,
      activeTags: document.querySelectorAll('script,img,iframe,object,embed,link,base,form').length,
      brand: getComputedStyle(document.querySelector('.wordmark')).color,
      main: !!document.querySelector('main'),
      brokenLinks: [...document.querySelectorAll('a[href^="#"]')].filter(a => !document.getElementById(a.getAttribute('href').slice(1))).length,
      references: document.querySelectorAll('.reference').length
    })`);
    check(page.headings === 1 && page.main && page.title.length > 0, `${name}: semantic document structure`);
    check(page.activeTags === 0, `${name}: no executable or external-resource elements`);
    check(page.brand === 'rgb(106, 72, 245)', `${name}: inline stylesheet passes the hash-based CSP`);
    check(page.brokenLinks === 0, `${name}: internal evidence links resolve`);
    check(page.references === 2, `${name}: expected reference count`);
    if (name === 'incomplete') check(page.text.includes('Incomplete evidence') && page.text.includes('coverage is incomplete'), 'incomplete: coverage warning remains visible');
    if (name === 'hostile') check(page.text.includes('<script>') && !await evaluate('!!window.__handoffInjected'), 'hostile: supplied markup stays literal text');
    const capture = async suffix => {
      const image = await call('Page.captureScreenshot', { format: 'png' });
      const file = join(output, `${name}-${suffix}.png`);
      await writeFile(file, Buffer.from(image.data, 'base64'), { flag: 'wx' });
      result.screenshots.push(file);
    };
    await capture('desktop');
    for (const width of [390, 320]) {
      await call('Emulation.setDeviceMetricsOverride', { width, height: 844, deviceScaleFactor: 1, mobile: true });
      const layout = await evaluate('({viewport:innerWidth, width:document.documentElement.scrollWidth, body:document.body.scrollWidth})');
      check(layout.width <= width + 1 && layout.body <= width + 1, `${name}: no page overflow at ${width}px`);
      if (width === 390) await capture('mobile');
    }
    await call('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
    await evaluate(`document.querySelector('#evidence summary').focus(); true`);
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key: ' ', code: 'Space', windowsVirtualKeyCode: 32 });
    await call('Input.dispatchKeyEvent', { type: 'keyUp', key: ' ', code: 'Space', windowsVirtualKeyCode: 32 });
    check(await evaluate(`!document.querySelector('#evidence details').open`), `${name}: native disclosure operates from the keyboard`);
    await call('Emulation.setEmulatedMedia', { media: 'print' });
    const print = await evaluate(`({nav:getComputedStyle(document.querySelector('nav')).display, evidence:getComputedStyle(document.querySelector('#evidence details'),'::details-content').contentVisibility})`);
    check(print.nav === 'none' && print.evidence === 'visible', `${name}: print styles hide navigation and expose collapsed evidence`);
    await call('Emulation.setEmulatedMedia', { media: '' });
  }
  const requests = events.filter(event => event.method === 'Network.requestWillBeSent');
  check(requests.every(event => !/^https?:/i.test(event.params.request.url)), 'All three local documents make no HTTP(S) page requests');
  check(!events.some(event => event.method === 'Page.javascriptDialogOpening'), 'No injected JavaScript dialog opened');
  result.status = 'PASS';
} catch (error) {
  result.failure = error.stack;
  result.browserDiagnostic = diagnostic;
  process.exitCode = 1;
} finally {
  if (send && socket?.readyState === WebSocket.OPEN) {
    try { await send('Browser.close'); } catch { /* The browser can close its socket first. */ }
  }
  socket?.close();
  let timer;
  await Promise.race([exited.catch(() => {}), new Promise(resolveWait => { timer = setTimeout(resolveWait, 5000); })]);
  clearTimeout(timer);
  if (child.exitCode === null && child.signalCode === null) {
    child.kill();
    await Promise.race([exited.catch(() => {}), new Promise(resolveWait => { timer = setTimeout(resolveWait, 5000); })]);
    clearTimeout(timer);
  }
  result.browserStopped = child.exitCode !== null || child.signalCode !== null;
  if (!result.browserStopped) { result.status = 'ERROR'; result.failure ??= 'The test-owned browser did not stop.'; process.exitCode = 1; }
  await writeFile(join(output, 'browser-checks.json'), JSON.stringify(result, null, 2), { flag: 'wx' });
}
console.log(JSON.stringify({ status: result.status, checks: result.checks.length, output, browserStopped: result.browserStopped }));
if (result.failure) console.error(result.failure);
