// Only the selected synthetic fixture and an owned browser download directory
// are used. This exercises FileReader/downloads, not an injected ledger state.
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, normalize, sep } from 'node:path';

export async function runCsvWebScenario(page, api) {
  const { debugPort, repoRoot, connectCdp, openApp, evaluate,
    waitFor, waitForLabel, clickLabel, focusLabel, delay } = api;
  const root = join(repoRoot, 'app', '.dart_tool');
  const directory = mkdtempSync(join(root, 'csv-browser-test-'));
  const fixture = join(directory, 'selected.csv');
  const title = 'Browser CSV, چائے 🍵';
  writeFileSync(fixture, '\uFEFFtitle,amount,kind,account,category\r\n' +
    `"${title}",1.23,expense,Everyday,\r\n`, 'utf8');
  const version = await (await fetch(`http://127.0.0.1:${debugPort}/json/version`)).json();
  const browser = await connectCdp(version.webSocketDebuggerUrl);

  async function eventAfter(connection, index, name, predicate = () => true) {
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const event = connection.events.slice(index).find(e => e.method === name && predicate(e.params));
      if (event) return event.params;
      await delay(100);
    }
    throw new Error(`No browser event: ${name}`);
  }
  async function trustedClick(label) {
    await waitForLabel(page, label);
    const response = await page.send('Runtime.evaluate', {
      expression: `(() => {
        const element = [...document.querySelectorAll('flt-semantics-host *')].find(e =>
          (e.getAttribute('aria-label') ?? e.textContent?.trim()) === ${JSON.stringify(label)});
        if (!element) throw new Error('Missing file action');
        element.click(); return true;
      })()`, userGesture: true, returnByValue: true,
    });
    if (response.exceptionDetails) throw new Error('Could not invoke file action');
  }
  try {
    await page.send('Page.setInterceptFileChooserDialog', { enabled: true });
    await browser.send('Browser.setDownloadBehavior', {
      behavior: 'allow', downloadPath: directory, eventsEnabled: true,
    });
    const beforeStorage = await evaluate(page, "localStorage.getItem('private_ledger.sqlite.v1')");
    await clickLabel(page, 'Import or export', 'button');
    await clickLabel(page, 'Import CSV');
    await waitForLabel(page, 'Choose CSV');
    const beforePicker = page.events.length;
    await trustedClick('Choose CSV');
    const picker = await eventAfter(page, beforePicker, 'Page.fileChooserOpened');
    await page.send('DOM.setFileInputFiles', {
      backendNodeId: picker.backendNodeId, files: [fixture],
    });
    await waitFor(page, `[...document.querySelectorAll('flt-semantics-host [role="button"]')]
      .some(e => (e.getAttribute('aria-label') ?? e.textContent?.trim()) === 'Import' && e.getAttribute('aria-disabled') !== 'true')`);
    // Flutter creates the editable DOM value when the review field is focused.
    await focusLabel(page, 'CSV to review');
    await waitFor(page, `[...document.querySelectorAll('flt-semantics-host *, input, textarea')]
      .some(e => [e.value,e.getAttribute('aria-valuetext'),e.textContent]
        .some(v => typeof v === 'string' && v.includes(${JSON.stringify(title)})))`);
    // Reading a file alone cannot mutate the private ledger.
    assert.equal(await evaluate(page, "localStorage.getItem('private_ledger.sqlite.v1')"), beforeStorage);
    await clickLabel(page, 'Import', 'button');
    await waitForLabel(page, 'USD -513.57');
    await page.send('Page.reload');
    await openApp(page);
    await waitForLabel(page, 'USD -513.57');
    await clickLabel(page, 'Import or export', 'button');
    await clickLabel(page, 'Export CSV');
    await waitForLabel(page, 'Save CSV');
    const beforeDownload = browser.events.length;
    await trustedClick('Save CSV');
    const download = await eventAfter(browser, beforeDownload, 'Browser.downloadWillBegin');
    assert.equal(download.suggestedFilename, 'private-ledger-transactions.csv');
    await eventAfter(browser, beforeDownload, 'Browser.downloadProgress',
      e => e.guid === download.guid && e.state === 'completed');
    const exported = readFileSync(join(directory, download.suggestedFilename), 'utf8');
    assert.ok(exported.startsWith('title,amount,kind,account,category\n'));
    assert.ok(exported.includes(`"${title}",1.23,expense,Everyday,`));
    assert.ok(exported.includes('Groceries,12.34,expense,Everyday,'));
    assert.ok(exported.includes('Rent,500.00,expense,Everyday,'));
    await waitForLabel(page, 'Download requested. Check your browser’s downloads.');
    await clickLabel(page, 'Close', 'button');
    console.log('Verified CSV: selected UTF-8 file, review before import, persisted Unicode transaction and actual downloaded bytes.');
  } finally {
    await page.send('Page.setInterceptFileChooserDialog', { enabled: false }).catch(() => {});
    browser.close();
    if (!normalize(directory).startsWith(normalize(root) + sep)) throw new Error('Unsafe CSV test directory');
    rmSync(directory, { recursive: true, force: true });
  }
}
