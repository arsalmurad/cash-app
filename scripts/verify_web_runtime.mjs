import { spawn } from 'node:child_process';
import {
  createReadStream,
  existsSync,
  mkdtempSync,
  readdirSync,
  rmSync,
} from 'node:fs';
import { createServer } from 'node:http';
import { dirname, extname, join, normalize, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const webRoot = join(repoRoot, 'app', 'build', 'web');
const viewportMatch = /^(\d{3,4})x(\d{3,4})$/.exec(process.env.WEB_VIEWPORT ?? '1280x900');
if (!viewportMatch) throw new Error('WEB_VIEWPORT must be WIDTHxHEIGHT');
const [viewportWidth, viewportHeight] = viewportMatch.slice(1).map(Number);
if (viewportWidth < 240 || viewportWidth > 3840 || viewportHeight < 240 || viewportHeight > 2160) {
  throw new Error('WEB_VIEWPORT is outside the supported verification dimensions');
}
const chromeBinary =
  process.env.CHROME_BINARY ??
  (process.platform === 'win32'
    ? 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe'
    : 'google-chrome');

if (!existsSync(join(webRoot, 'index.html'))) {
  throw new Error('Build app/build/web before running the browser verification.');
}
if (process.platform === 'win32' && !existsSync(chromeBinary)) {
  throw new Error(`Chrome not found at ${chromeBinary}`);
}

const server = createServer((request, response) => {
  const requestPath = decodeURIComponent(new URL(request.url, 'http://local').pathname);
  const relative = requestPath === '/' ? 'index.html' : requestPath.slice(1);
  const filePath = normalize(join(webRoot, relative));
  if (!filePath.startsWith(normalize(webRoot) + sep) || !existsSync(filePath)) {
    response.writeHead(404).end('Not found');
    return;
  }
  response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('Content-Type', contentType(extname(filePath)));
  createReadStream(filePath).pipe(response);
});

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const appPort = server.address().port;
const debugPort = await reservePort();
const profileRoot = join(repoRoot, 'app', '.dart_tool');
for (const entry of readdirSync(profileRoot)) {
  if (!entry.startsWith('private-ledger-chrome-')) continue;
  const ownedProfile = normalize(join(profileRoot, entry));
  if (!ownedProfile.startsWith(normalize(profileRoot) + sep)) throw new Error('Unsafe profile path');
  try {
    rmSync(ownedProfile, { recursive: true, force: true });
  } catch (_) {
    // A just-exited Chrome process can briefly retain a Windows file lock.
  }
}
const profile = mkdtempSync(join(profileRoot, 'private-ledger-chrome-'));
const chrome = spawn(
  chromeBinary,
  [
    '--headless=new',
    '--disable-gpu',
    '--disable-extensions',
    '--disable-background-networking',
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1280,900',
    // Containers and CI runners run as root, where Chrome refuses to start
    // with its sandbox on.
    ...(process.env.CHROME_NO_SANDBOX ? ['--no-sandbox'] : []),
    `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=${profile}`,
    `http://127.0.0.1:${appPort}`,
  ],
  { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true },
);
let chromeErrors = '';
chrome.stderr.on('data', (chunk) => (chromeErrors += chunk.toString()));
let cdp;

try {
  const appUrl = `http://127.0.0.1:${appPort}`;
  const page = await waitForPage(debugPort, appUrl);
  cdp = await connectCdp(page.webSocketDebuggerUrl);
  await cdp.send('Runtime.enable');
  await cdp.send('Page.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width: viewportWidth, height: viewportHeight, deviceScaleFactor: 1, mobile: false,
  });
  await waitFor(cdp, `innerWidth === ${viewportWidth} && innerHeight === ${viewportHeight}`);
  console.log(`Verification viewport: ${viewportWidth}x${viewportHeight}`);
  if (process.env.WEB_OFFLINE_FONTS === '1') {
    await cdp.send('Network.enable');
    await cdp.send('Network.setBlockedURLs', { urls: ['*://fonts.gstatic.com/*', '*://fonts.googleapis.com/*'] });
  }
  await openApp(cdp);
  await waitForLabel(cdp, 'Private Ledger');
  await waitForLabel(cdp, 'USD 0.00');

  await clickLabel(cdp, 'Add first transaction', 'button');
  await waitForLabel(cdp, 'Add transaction');
  await focusLabel(cdp, 'Title');
  await cdp.send('Input.insertText', { text: 'Groceries' });
  await focusLabel(cdp, 'Amount');
  await cdp.send('Input.insertText', { text: '12.34' });
  await clickLabel(cdp, 'Add transaction', 'button');

  await waitForLabel(cdp, 'USD -12.34');
  await waitForLabel(cdp, 'Groceries');
  console.log('Verified: Private Ledger | Groceries | USD -12.34');

  // A full page reload is this platform's "app restart": the event log lives
  // in window.localStorage, so the ledger must be rebuilt from it alone.
  await cdp.send('Page.reload');
  await openApp(cdp);
  await waitForLabel(cdp, 'Private Ledger');
  await waitForLabel(cdp, 'USD -12.34');
  await waitForLabel(cdp, 'Groceries');
  console.log('Verified after reload: Groceries | USD -12.34 (persisted)');

  await clickLabel(cdp, 'Add', 'button');
  await waitForLabel(cdp, 'Add transaction');
  await focusLabel(cdp, 'Title');
  await cdp.send('Input.insertText', { text: 'Rent' });
  await focusLabel(cdp, 'Amount');
  await cdp.send('Input.insertText', { text: '500.00' });
  await clickLabel(cdp, 'Add transaction', 'button');
  await waitForLabel(cdp, 'USD -512.34');
  await waitForLabel(cdp, 'Rent');

  await cdp.send('Page.reload');
  await openApp(cdp);
  await waitForLabel(cdp, 'USD -512.34');
  await waitForLabel(cdp, 'Rent');
  await waitForLabel(cdp, 'Groceries');
  console.log('Verified after second reload: Rent + Groceries | USD -512.34');
  if (process.env.WEB_CSV === '1') {
    const { runCsvWebScenario } = await import('./csv_web_scenario.mjs');
    await runCsvWebScenario(cdp, {
      debugPort, repoRoot, connectCdp, openApp, evaluate,
      waitFor, waitForLabel, clickLabel, focusLabel, delay,
    });
  }
  if (process.env.WEB_PERSONAL_LIFECYCLE === '1') {
    const { runPersonalLifecycleWebScenario } = await import('./personal_lifecycle_web_scenario.mjs');
    await runPersonalLifecycleWebScenario(cdp, {
      openApp, evaluate, waitFor, waitForLabel, clickLabel, focusLabel,
    });
  }
  if (process.env.WEB_HOUSEHOLD === '1') {
    const { runHouseholdWebScenario } = await import('./household_web_scenario.mjs');
    await runHouseholdWebScenario(cdp, {
      appUrl, debugPort, repoRoot, connectCdp, waitForPage, openApp,
      evaluate, waitFor, waitForLabel, clickLabel, focusLabel, delay,
    });
  }
  console.log('Web runtime verification passed.');
} catch (error) {
  if (cdp) {
    const diagnostics = await evaluate(
      cdp,
      `({
        url: location.href,
        isolated: crossOriginIsolated,
        title: document.title,
        editors: [...document.querySelectorAll('input, textarea, [role="textbox"]')].map(e => ({
          tag: e.tagName, role: e.getAttribute('role'),
          label: e.getAttribute('aria-label'), description: e.getAttribute('aria-description'),
          labelledBy: e.getAttribute('aria-labelledby'), placeholder: e.getAttribute('placeholder'),
          focused: e === document.activeElement,
          rectangle: { x: e.getBoundingClientRect().x, y: e.getBoundingClientRect().y,
            width: e.getBoundingClientRect().width, height: e.getBoundingClientRect().height },
        })),
      })`,
    ).catch((diagnosticError) => ({ diagnosticError: diagnosticError.message }));
    console.error('Page diagnostics:', diagnostics);
    const relevantEvents = cdp.events
      .filter((event) =>
        ['Runtime.exceptionThrown', 'Runtime.consoleAPICalled', 'Log.entryAdded'].includes(
          event.method,
        ),
      )
      .slice(-20);
    console.error('Browser events:', JSON.stringify(relevantEvents, null, 2));
  }
  if (chromeErrors) {
    console.error(chromeErrors);
  }
  throw error;
} finally {
  if (cdp) {
    await Promise.race([cdp.send('Browser.close').catch(() => {}), delay(1_000)]);
    cdp.close();
  }
  await stopChrome(chrome.pid);
  await new Promise((resolve) => server.close(resolve));
  await delay(500);
  try {
    rmSync(profile, {
      recursive: true,
      force: true,
      maxRetries: 10,
      retryDelay: 100,
    });
  } catch (error) {
    // The next run removes a profile if Windows retained a short-lived lock.
  }
}

// Waits for Flutter to boot and turns on its accessibility tree, which is
// what this script reads and clicks (Flutter draws to a canvas otherwise).
async function openApp(cdp) {
  await waitFor(
    cdp,
    `document.querySelector('flt-semantics-placeholder, flt-semantics-host') !== null`,
  );
  await evaluate(
    cdp,
    `document.querySelector('flt-semantics-placeholder')?.click(); true`,
  );
}

function contentType(extension) {
  return (
    {
      '.css': 'text/css',
      '.html': 'text/html; charset=utf-8',
      '.ico': 'image/x-icon',
      '.js': 'text/javascript',
      '.mjs': 'text/javascript',
      '.json': 'application/json',
      '.png': 'image/png',
      '.wasm': 'application/wasm',
    }[extension] ?? 'application/octet-stream'
  );
}

async function reservePort() {
  const probe = createServer();
  await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
  const port = probe.address().port;
  await new Promise((resolve) => probe.close(resolve));
  return port;
}

async function waitForPage(port, expectedUrl, targetId) {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/list`);
      const pages = await response.json();
      const page = pages.find(
        (entry) => entry.type === 'page' && entry.url.startsWith(expectedUrl) && (!targetId || entry.id === targetId),
      );
      if (page) return page;
    } catch (_) {
      // Chrome is still starting.
    }
    await delay(200);
  }
  throw new Error('Chrome DevTools endpoint did not become ready.');
}

async function stopChrome(processId) {
  if (!processId) return;
  if (process.platform !== 'win32') {
    try {
      process.kill(processId, 'SIGKILL');
    } catch (_) {
      // Already exited.
    }
    return;
  }
  await new Promise((resolve) => {
    const taskkill = spawn(
      'C:\\Windows\\System32\\taskkill.exe',
      ['/PID', String(processId), '/T', '/F'],
      { stdio: 'ignore', windowsHide: true },
    );
    taskkill.once('exit', resolve);
    taskkill.once('error', resolve);
  });
}

async function connectCdp(url, onEvent = () => {}) {
  const socket = new WebSocket(url);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  let nextId = 0;
  const pending = new Map();
  const events = [];
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (!message.id) {
      events.push(message);
      onEvent(message);
      return;
    }
    if (!pending.has(message.id)) return;
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result);
  });
  socket.addEventListener('close', () => {
    for (const { reject } of pending.values()) reject(new Error('Chrome connection closed'));
    pending.clear();
  });
  return {
    events,
    send(method, params = {}, sessionId) {
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`Chrome command timed out: ${method}`));
        }, 30_000);
        pending.set(id, {
          resolve: (value) => { clearTimeout(timeout); resolve(value); },
          reject: (error) => { clearTimeout(timeout); reject(error); },
        });
        socket.send(JSON.stringify({ id, method, params, sessionId }));
      });
    },
    close() {
      socket.close();
    },
  };
}

async function evaluate(cdp, expression, options = {}) {
  const response = await cdp.send('Runtime.evaluate', {
    ...options,
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  if (response.exceptionDetails) {
    throw new Error(response.exceptionDetails.text);
  }
  return response.result.value;
}

async function semanticLabels(cdp) {
  const labels = await evaluate(
    cdp,
    `[...document.querySelectorAll('flt-semantics-host *')]
      .map((element) => element.getAttribute('aria-label') ?? element.textContent?.trim())
      .filter(Boolean)`,
  );
  return labels.map((label) =>
    /cash(?:kp|inv|bk)1:/.test(label) || /^(?:[a-z]+ ){23}[a-z]+$/.test(label)
      ? '[synthetic copy code or phrase]' : label);
}

async function waitForLabel(cdp, label) {
  await waitFor(
    cdp,
    `[...document.querySelectorAll('flt-semantics-host *')]
      .some((element) =>
        (element.getAttribute('aria-label') ?? element.textContent?.trim())?.includes(${JSON.stringify(label)})
      )`,
  );
}

async function clickLabel(cdp, label, role) {
  await waitForLabel(cdp, label);
  if (role === 'button') {
    await waitFor(cdp, `[...document.querySelectorAll('flt-semantics-host [role="button"]')].some(e =>
      (e.getAttribute('aria-label') ?? e.textContent?.trim()) === ${JSON.stringify(label)} &&
      e.getAttribute('aria-disabled') !== 'true')`);
  }
  const clicked = await evaluate(
    cdp,
    `(() => {
      const element = [...document.querySelectorAll('flt-semantics-host *')].find(
        (candidate) =>
          (candidate.getAttribute('aria-label') ?? candidate.textContent?.trim()) === ${JSON.stringify(label)} &&
          (!${JSON.stringify(role)} || candidate.getAttribute('role') === ${JSON.stringify(role)})
      );
      if (!element) return false;
      element.click();
      return true;
    })()`,
  );
  if (!clicked) throw new Error(`Could not click ${label}`);
}

async function focusLabel(cdp, label) {
  await waitForLabel(cdp, label);
  const target = await evaluate(
    cdp,
    `(() => {
      const element = [...document.querySelectorAll('flt-semantics-host *')].find(
        (candidate) =>
          candidate.matches('input, textarea, [role="textbox"]') &&
          candidate.getAttribute('aria-label')?.split(String.fromCharCode(10)).some(line => line.trim() === ${JSON.stringify(label)})
      );
      if (!element) return false;
      const rect = element.getBoundingClientRect();
      if (element.disabled || rect.width <= 0 || rect.height <= 0) return null;
      return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
    })()`,
  );
  if (!target) throw new Error(`Could not focus ${label}`);
  // Use browser pointer input, not DOM-only focus, so Flutter receives the
  // ordinary field activation path even if its editor is already DOM-focused.
  await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed',
    button: 'left', clickCount: 1, ...target });
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased',
    button: 'left', clickCount: 1, ...target });
  // Flutter's semantics editor can be DOM-focused before its engine activates
  // the input listener. Do not mistake an editable DOM value for an app edit.
  // Inspect readiness through DevTools; never install or call an app hook.
  await waitFor(cdp, `['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName) &&
    document.activeElement.getAttribute('aria-label')?.split(String.fromCharCode(10)).some(line => line.trim() === ${JSON.stringify(label)}) &&
    getEventListeners(document.activeElement).input?.length > 0`,
    { includeCommandLineAPI: true });
  await delay(150);
}

async function waitFor(cdp, expression, options = {}) {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    try {
      if (await evaluate(cdp, expression, options)) return;
    } catch (error) {
      // The page can replace its execution context during Flutter bootstrap.
      // Command timeouts and other failures are not a not-yet-ready predicate.
      if (!/Cannot find context|Execution context was destroyed|No execution context/i.test(error.message)) {
        throw error;
      }
    }
    await delay(200);
  }
  const labels = await semanticLabels(cdp);
  throw new Error(`Timed out waiting for ${expression}. Labels: ${labels.join(' | ')}`);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
