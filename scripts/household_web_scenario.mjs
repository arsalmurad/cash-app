// Drives the unmodified production Flutter/WASM app through its rendered UI.
// All browser contexts, storage, keys and relay records are synthetic and owned
// by this test. No application debug hook or direct Rust/state injection.
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { runHouseholdQuotaScenario } from './browser_quota_scenario.mjs';

export async function runHouseholdWebScenario(alice, api) {
  const { appUrl, debugPort, repoRoot, connectCdp, waitForPage, openApp,
    evaluate, waitFor, waitForLabel, clickLabel, focusLabel, delay } = api;
  const { Miniflare } = createRequire(import.meta.url)('../relay/node_modules/miniflare');
  const authenticated = process.env.WEB_HOUSEHOLD_AUTH === '1';
  const relayOptions = {
    modules: true,
    modulesRules: [{ type: 'ESModule', include: ['**/*.js'] }],
    scriptPath: join(repoRoot, authenticated ? 'relay/src/roster-worker.js' : 'relay/src/worker.js'),
    durableObjects: authenticated ? { GROUP: { className: 'RosterGroupLog', useSQLite: true } } :
      { GROUP: 'GroupLog', MAILBOX: 'Mailbox' },
    bindings: { LOCAL_DEVELOPMENT: 'true', ...(authenticated ? {
      LOCAL_AUTH_MEMBERSHIP: 'true', LOCAL_AUTH_RETENTION: 'true',
    } : {}) },
    compatibilityDate: '2026-07-01', host: '127.0.0.1', port: 0,
  };
  const relay = new Miniflare(relayOptions);
  const relayUrl = String(await relay.ready).replace(/\/$/, '');
  const version = await (await fetch(`http://127.0.0.1:${debugPort}/json/version`)).json();
  let rejectWorkerFailure;
  let scenarioStage = 'initializing';
  const workerFailure = new Promise((_, reject) => { rejectWorkerFailure = reject; });
  workerFailure.catch(() => {}); // Observed again by the guarded UI waits below.
  const attach = { autoAttach: true, waitForDebuggerOnStart: false, flatten: true };
  const browser = await connectCdp(version.webSocketDebuggerUrl, (event) => {
    const details = event.params?.exceptionDetails;
    const panic = event.method === 'Runtime.consoleAPICalled' && event.params.type === 'error'
      ? event.params.args.map(a => a.value ?? a.description ?? '').find(v => String(v).includes('panicked at'))
      : null;
    if (event.method === 'Runtime.exceptionThrown' || panic) {
      const opaqueFrame = event.params.stackTrace?.callFrames?.find(frame => frame.functionName.includes('decrement_strong_count'))?.functionName;
      rejectWorkerFailure(new Error(`Owned browser worker failed during ${scenarioStage}: ${String(panic ?? details?.exception?.description ?? details?.text).slice(0, 1200)}${opaqueFrame ? `\n${opaqueFrame}` : ''}`));
    }
    if (event.method !== 'Target.attachedToTarget') return;
    const session = event.params.sessionId;
    browser.send('Runtime.enable', {}, session).catch(() => {});
    browser.send('Target.setAutoAttach', attach, session).catch(() => {});
  });
  await browser.send('Target.setAutoAttach', attach);
  const peers = [];
  const contexts = [];

  async function newPeer() {
    const { browserContextId } = await browser.send('Target.createBrowserContext');
    contexts.push(browserContextId);
    const { targetId } = await browser.send('Target.createTarget', { url: appUrl, browserContextId });
    const page = await waitForPage(debugPort, appUrl, targetId);
    const peer = await connectCdp(page.webSocketDebuggerUrl);
    peers.push(peer);
    await peer.send('Runtime.enable');
    await peer.send('Page.enable');
    await peer.send('Network.enable');
    await openApp(peer);
    await waitForLabel(peer, 'Private Ledger');
    return peer;
  }

  async function textMatching(peer, pattern) {
    const expression = `(() => {
      const values = [...document.querySelectorAll('flt-semantics-host *, input, textarea')].flatMap(e =>
        [e.value, e.getAttribute('aria-label'), e.getAttribute('aria-valuetext'), e.textContent,
         e.getAttribute('data-value')]);
      return values.filter(v => typeof v === 'string').map(v => v.trim()).find(v => new RegExp(${JSON.stringify(pattern)}).test(v));
    })()`;
    try {
      await waitFor(peer, expression);
    } catch (error) {
      const screenshot = await peer.send('Page.captureScreenshot', { format: 'png' });
      writeFileSync(join(repoRoot, 'app/.dart_tool/household-web-failure.png'), Buffer.from(screenshot.data, 'base64'));
      throw error;
    }
    return evaluate(peer, expression);
  }

  async function fill(peer, label, value, replace = false) {
    await focusLabel(peer, label);
    await waitFor(peer, `['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName)`);
    if (replace) {
      await evaluate(peer, `(() => {
        const input = document.activeElement;
        if (!input || typeof input.setSelectionRange !== 'function') throw new Error('No active editable field');
        input.setSelectionRange(0, input.value.length);
      })()`);
    }
    await peer.send('Input.insertText', { text: value });
    await waitFor(peer, `document.activeElement?.value === ${JSON.stringify(value)}`);
    // Complete editing through the same keyboard path as the personal flow.
    // DOM text alone does not prove Flutter has committed the field update.
    await peer.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
    await peer.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  }

  async function openHousehold(peer) {
    await clickLabel(peer, 'Import or export', 'button');
    await clickLabel(peer, 'Household');
  }

  async function protect(peer) {
    await openHousehold(peer);
    await waitForLabel(peer, 'Protect this browser');
    await clickLabel(peer, 'Create unlock phrase', 'button');
    const phrase = await textMatching(peer, '^(?:[a-z]+ ){23}[a-z]+$');
    await clickLabel(peer, 'I saved this phrase privately');
    await clickLabel(peer, 'Encrypt and continue', 'button');
    await waitForLabel(peer, 'Share expenses');
    return phrase;
  }

  async function joinRequest(peer) {
    await clickLabel(peer, 'Join a household', 'button');
    return textMatching(peer, '^cashkp1:[A-Za-z0-9_+/=-]+$');
  }

  async function invite(request) {
    await clickLabel(alice, 'Invite', 'button');
    await fill(alice, 'Their join request', request);
    await clickLabel(alice, 'Add to household', 'button');
    const code = await textMatching(alice, '^cashinv1:[A-Za-z0-9_+/=-]+$');
    await clickLabel(alice, 'Done', 'button');
    return code;
  }

  async function accept(peer, code) {
    await fill(peer, 'Invite', code);
    await clickLabel(peer, 'Join', 'button');
    await waitForLabel(peer, 'Shared balance');
  }

  async function expense(peer, title, amount, accountLabel, rate) {
    await clickLabel(peer, 'Add shared expense', 'button');
    await fill(peer, 'Title', title);
    await fill(peer, 'Amount', amount);
    if (accountLabel) {
      await clickDropdown(peer, 'Shared account');
      await clickLabel(peer, accountLabel);
    }
    await clickLabel(peer, 'Add', 'button');
    if (rate) {
      await fill(peer, 'Exchange rate', rate);
      await clickLabel(peer, 'Use rate', 'button');
    }
    await waitForLabel(peer, title);
  }

  async function createSharedAccount(name, currency) {
    await clickLabel(alice, 'Household options', 'button');
    await clickLabel(alice, 'Create shared account');
    await fill(alice, 'Shared account name', name);
    await clickDropdown(alice, 'Currency');
    await clickLabel(alice, currency);
    await clickLabel(alice, 'Create shared account', 'button');
    // Populated household lists lazily expose below-fold account semantics.
    // Verify the rendered card by scrolling, not by reading controller state.
    const accountLabel = `${name} (${currency})`;
    const viewport = await evaluate(alice, `({ width: innerWidth, height: innerHeight })`);
    for (let attempt = 0; attempt < 8; attempt++) {
      const present = await evaluate(alice, `[...document.querySelectorAll('flt-semantics-host *')]
        .some(e => (e.getAttribute('aria-label') ?? e.textContent?.trim())?.includes(${JSON.stringify(accountLabel)}))`);
      if (present) break;
      await alice.send('Input.dispatchMouseEvent', { type: 'mouseWheel',
        x: viewport.width / 2, y: viewport.height * 0.75, deltaX: 0, deltaY: 300 });
      await delay(200);
    }
    await waitForLabel(alice, accountLabel);
    await alice.send('Input.dispatchMouseEvent', { type: 'mouseWheel',
      x: viewport.width / 2, y: viewport.height * 0.75, deltaX: 0, deltaY: -2400 });
    await delay(200);
  }

  async function clickDropdown(peer, label) {
    const controls = await evaluate(peer, `(() => [...document.querySelectorAll('flt-semantics-host [role="button"], flt-semantics-host [role="combobox"]')]
      .map(e => ({ label: e.getAttribute('aria-label') ?? e.textContent?.trim(), role: e.getAttribute('role') })))()`);
    const control = controls.find(e => e.label?.includes(label));
    assert(control, `No rendered dropdown for ${label}: ${JSON.stringify(controls)}`);
    await clickLabel(peer, control.label, control.role);
  }

  async function edit(peer, amount) {
    // Summary cards can place the transaction below the initial viewport.
    // Scroll the rendered list as a user would; do not inject a menu or state.
    for (let attempt = 0; attempt < 6; attempt++) {
      const visible = await evaluate(peer, `[...document.querySelectorAll('flt-semantics-host [role="button"]')]
        .some(e => (e.getAttribute('aria-label') ?? e.textContent?.trim()) === 'Expense actions')`);
      if (visible) break;
      const viewport = await evaluate(peer, `({ width: innerWidth, height: innerHeight })`);
      await peer.send('Input.dispatchMouseEvent', { type: 'mouseWheel',
        x: viewport.width / 2, y: viewport.height * 0.75, deltaX: 0, deltaY: 300 });
      await delay(200);
    }
    await clickLabel(peer, 'Expense actions', 'button');
    await clickLabel(peer, 'Change amount');
    await fill(peer, 'Amount', amount, true);
    await clickLabel(peer, 'Save', 'button');
    const viewport = await evaluate(peer, `({ width: innerWidth, height: innerHeight })`);
    await peer.send('Input.dispatchMouseEvent', { type: 'mouseWheel',
      x: viewport.width / 2, y: viewport.height * 0.75, deltaX: 0, deltaY: -1800 });
    await delay(200);
  }

  async function sync(peer, { allowAlreadyRemoved = false } = {}) {
    const removed = () => evaluate(peer,
      `document.body.textContent.includes('You are no longer in this household.')`);
    if (allowAlreadyRemoved && await removed()) return;
    try {
      await clickLabel(peer, 'Sync', 'button');
    } catch (error) {
      // Only the explicit removed-device step may already have completed via
      // the production background timer. Its removal assertion still follows.
      if (allowAlreadyRemoved && await removed()) return;
      throw error;
    }
    await Promise.race([workerFailure, delay(350)]);
    await waitFor(peer, `document.body.textContent.includes('You are no longer in this household.') ||
      [...document.querySelectorAll('flt-semantics-host [role="button"]')]
        .some(e => (e.getAttribute('aria-label') ?? e.textContent?.trim()) === 'Sync' &&
          e.getAttribute('aria-disabled') !== 'true')`);
  }

  try {
    await alice.send('Network.enable');
    const alicePhrase = await protect(alice);
    await fill(alice, 'Relay address', relayUrl);
    if (authenticated) {
      await clickLabel(alice, 'Authenticated relay (development)\nRequires operator setup. Only approved devices can sync. Saving this setting does not register your household.', 'switch');
    }
    await clickLabel(alice, 'Save relay address', 'button');
    await clickLabel(alice, 'Create a household', 'button');
    await waitForLabel(alice, 'Shared balance');
    if (authenticated) {
      scenarioStage = 'exporting public operator bootstrap';
      await clickLabel(alice, 'Household options', 'button');
      await clickLabel(alice, 'Export local relay setup');
      await waitForLabel(alice, 'Relay operator setup');
      const policy = JSON.parse(await textMatching(alice, '^\\{"version":2,"epoch":0,"scope":'));
      assert.deepEqual(Object.keys(policy).sort(), ['devices', 'epoch', 'scope', 'version']);
      assert.equal(policy.devices.length, 1);
      assert.deepEqual(policy.devices[0].operations, ['append', 'membership', 'read']);
      assert.match(policy.devices[0].key, /^[0-9a-f]{64}$/);
      assert.equal(policy.scope.origin, relayUrl);
      assert.equal(policy.scope.kind, 'g');
      assert.match(policy.scope.id, /^[0-9a-f]{32}$/);
      await relay.setOptions({ ...relayOptions, port: Number(new URL(relayUrl).port),
        bindings: { ...relayOptions.bindings, LOCAL_AUTH_POLICY: JSON.stringify(policy) } });
      await clickLabel(alice, 'Close', 'button');
      await sync(alice);
      await clickLabel(alice, 'Household options', 'button');
      assert.equal(await evaluate(alice, `document.body.textContent.includes('Export local relay setup')`), false);
      // Dismiss through the real modal barrier; Escape depends on which
      // renderer/semantics element currently owns keyboard focus.
      await waitForLabel(alice, 'Popup menu');
      // Semantics can appear before Flutter finishes pushing the popup route.
      // Let its entrance animation settle before sending barrier pointer input.
      await delay(250);
      await alice.send('Input.dispatchMouseEvent', { type: 'mousePressed', x:16, y:160, button:'left', clickCount:1 });
      await alice.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x:16, y:160, button:'left', clickCount:1 });
      await waitForLabel(alice, 'Invite');
      console.log('Verified authenticated bootstrap: production app public roster export starts owned SQLite relay; no pre-seeded history.');
    }
    const bob = await newPeer();
    await clickLabel(bob, 'Add', 'button');
    await fill(bob, 'Title', 'Private summary-only lunch');
    await fill(bob, 'Amount', '12.34');
    await clickLabel(bob, 'Add transaction', 'button');
    await waitForLabel(bob, 'USD -12.34');
    const bobPhrase = await protect(bob);
    await accept(bob, await invite(await joinRequest(bob)));
    console.log('Verified household: two independent browser identities joined through real HTTP/CORS.');
    const relayEntries = () => peers.flatMap(peer => peer.events).filter(event =>
      event.method === 'Network.requestWillBeSent' &&
      event.params.request.url.startsWith(relayUrl) &&
      event.params.request.method === 'POST').length;
    await clickLabel(bob, 'Choose private totals to share', 'button');
    await waitForLabel(bob, 'Preview totals');
    const disabled = await evaluate(bob, `[...document.querySelectorAll('flt-semantics-host [role="button"]')]
      .some(e => (e.getAttribute('aria-label') ?? e.textContent?.trim()) === 'Preview totals' &&
        e.getAttribute('aria-disabled') === 'true')`);
    assert.equal(disabled, true, 'No private total may be selected by default');
    await clickLabel(bob, 'Expense total');
    await clickLabel(bob, 'Preview totals', 'button');
    await waitForLabel(bob, 'Review shared snapshot');
    await waitForLabel(bob, 'USD 12.34');
    const canceledBefore = relayEntries();
    await clickLabel(bob, 'Change selection', 'button');
    await clickLabel(bob, 'Preview totals', 'button');
    await waitForLabel(bob, 'USD 12.34');
    assert.equal(relayEntries(), canceledBefore, 'Replacing a preview must not append to the relay');
    await clickLabel(bob, 'Keep private', 'button');
    await waitForLabel(bob, 'No totals have been shared.');
    assert.equal(relayEntries(), canceledBefore, 'Canceled preview must not append to the relay');
    await clickLabel(bob, 'Choose private totals to share', 'button');
    await clickLabel(bob, 'Expense total');
    await clickLabel(bob, 'Preview totals', 'button');
    await waitForLabel(bob, 'USD 12.34');
    await clickLabel(bob, 'Everyone in this household has updated to the summary-capable app.');
    await clickLabel(bob, 'Share these totals', 'button');
    await waitForLabel(bob, 'Expense total: USD 12.34');
    await sync(bob);
    assert.equal(relayEntries(), canceledBefore + 2,
      'A shared summary sends one financial frame and one confirmed-save receipt');
    await sync(alice);
    await waitForLabel(alice, 'Expense total: USD 12.34');
    await waitForLabel(alice, 'USD 0.00');
    assert.equal(await evaluate(alice, `document.body.textContent.includes('Private summary-only lunch')`), false);
    assert.equal(await evaluate(alice, `document.body.textContent.includes('Income total:')`), false);
    const stableReceipts = [alice, ...peers].flatMap(peer => peer.events).filter(event =>
      event.method === 'Network.requestWillBeSent' && event.params.request.method === 'POST' &&
      event.params.request.url.startsWith(relayUrl) && event.params.request.url.endsWith('/append')).length;
    for (let attempt = 0; attempt < 2; attempt++) {
      await sync(bob);
      await sync(alice);
    }
    const afterControlSync = [alice, ...peers].flatMap(peer => peer.events).filter(event =>
      event.method === 'Network.requestWillBeSent' && event.params.request.method === 'POST' &&
      event.params.request.url.startsWith(relayUrl) && event.params.request.url.endsWith('/append')).length;
    assert.equal(afterControlSync, stableReceipts, 'Control-only sync must not create an ACK loop');
    console.log('Verified saved receipts: one per published checkpoint and no control-only ACK loop.');
    console.log('Verified household summaries: default-off selection, exact preview, keep-private cancellation, explicit sharing and no private title or balance change.');
    scenarioStage = 'locking Bob';
    await clickLabel(bob, 'Lock household in this browser', 'button');
    await Promise.race([workerFailure, waitForLabel(bob, 'Unlock this browser')]);
    assert.equal(await evaluate(bob, `document.body.textContent.includes('Expense total: USD 12.34')`), false,
      'Locked household must not render the previous summary');
    scenarioStage = 'unlocking Bob';
    await fill(bob, '24-word unlock phrase', bobPhrase);
    await clickLabel(bob, 'Unlock household', 'button');
    await waitForLabel(bob, 'Expense total: USD 12.34');
    console.log('Verified household summary: explicit browser lock hides the snapshot and phrase unlock restores it.');
    scenarioStage = 'standalone household encryption-key refresh';
    await sync(alice);
    const refreshEndpoint = authenticated ? '/membership' : '/append';
    const refreshWrites = () => alice.events.filter(event =>
      event.method === 'Network.requestWillBeSent' &&
      event.params.request.method === 'POST' &&
      event.params.request.url.startsWith(relayUrl) &&
      event.params.request.url.endsWith(refreshEndpoint));
    const beforeRefresh = refreshWrites().length;
    await clickLabel(alice, 'Household options', 'button');
    await clickLabel(alice, 'Refresh encryption keys');
    await waitForLabel(alice, 'Refresh encryption keys?');
    await clickLabel(alice, 'Cancel', 'button');
    assert.equal(refreshWrites().length, beforeRefresh, 'Canceled key refresh must not append');
    await clickLabel(alice, 'Household options', 'button');
    await clickLabel(alice, 'Refresh encryption keys');
    await clickLabel(alice, 'Refresh keys', 'button');
    await waitForLabel(alice, 'Encryption keys refreshed');
    const confirmedRefresh = refreshWrites().slice(beforeRefresh);
    assert(confirmedRefresh.length > 0, 'Confirmed key refresh must publish its encrypted commit');
    if (authenticated) assert.equal(confirmedRefresh.length, 1,
      'Authenticated refresh must send exactly one membership commit');
    assert(confirmedRefresh.some(request => alice.events.some(event =>
      event.method === 'Network.responseReceived' &&
      event.params.requestId === request.params.requestId &&
      event.params.response.status === 200)), 'Refresh commit must receive an actual successful relay response');
    await sync(bob);
    await waitForLabel(bob, 'Expense total: USD 12.34');
    await waitForLabel(bob, 'USD 0.00');
    console.log('Verified standalone encryption-key refresh: cancellation writes nothing, confirmation sends a commit, existing shared history survives peer catch-up.');
    if (process.env.WEB_HOUSEHOLD_QUOTA === '1') {
      scenarioStage = 'Alice quota failure and restart';
      await Promise.race([workerFailure, runHouseholdQuotaScenario(alice, alicePhrase, relayUrl, api)]);
    }

    scenarioStage = 'Alice publishes after Bob unlock';
    await expense(alice, 'Browser shared dinner', '40.00');
    scenarioStage = 'Bob syncs after unlock';
    await sync(bob);
    await waitForLabel(bob, 'USD -40.00');
    await waitForLabel(bob, 'Expense total: USD 12.34');
    const beforeBobReload = await evaluate(bob, `localStorage.getItem('private_ledger.sqlite.v1')`);
    assert(beforeBobReload && atob(beforeBobReload).includes('cash-app sealed vault v1\0'),
      'Household must have a sealed document before reload');
    scenarioStage = 'reloading Bob';
    await bob.send('Page.reload');
    await openApp(bob);
    await waitForLabel(bob, 'Private Ledger');
    const afterBobReload = await evaluate(bob, `localStorage.getItem('private_ledger.sqlite.v1')`);
    assert.equal(afterBobReload, beforeBobReload, 'Reload must preserve the confirmed SQLite image');
    await openHousehold(bob);
    await waitForLabel(bob, 'Unlock this browser');
    scenarioStage = 'unlocking Bob after reload';
    await fill(bob, '24-word unlock phrase', bobPhrase);
    await clickLabel(bob, 'Unlock household', 'button');
    await Promise.race([workerFailure, waitForLabel(bob, 'USD -40.00')]);
    await waitForLabel(bob, 'Expense total: USD 12.34');
    const saved = await evaluate(bob, `(() => {
      const bytes = atob(localStorage.getItem('private_ledger.sqlite.v1'));
      return { sqlite: bytes.startsWith('SQLite format 3\\0'),
        sealed: bytes.includes('cash-app sealed vault v1\\0'),
        containsTitle: bytes.includes('Browser shared dinner'),
        containsPhrase: Object.values(localStorage).some(v => v.includes(${JSON.stringify(bobPhrase)})) };
    })()`);
    assert.deepEqual(saved, { sqlite: true, sealed: true, containsTitle: false, containsPhrase: false });
    console.log('Verified household: reload requires the RAM-only phrase and restores sealed history.');

    await bob.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await edit(bob, '42.00');
    await waitForLabel(bob, 'USD -42.00');
    await waitForLabel(bob, 'waiting to send');
    await edit(alice, '45.00');
    await bob.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await sync(bob);
    await sync(alice);
    await waitForLabel(bob, 'Edited by two people at once');
    await waitForLabel(alice, 'Edited by two people at once');
    await waitForLabel(bob, 'USD -45.00');
    await waitForLabel(alice, 'USD -45.00');
    console.log('Verified household: offline concurrent edits converge with a visible conflict.');

    await clickLabel(bob, 'Household options', 'button');
    await clickLabel(bob, 'Back up');
    const backupPhrase = await textMatching(bob, '^(?:[a-z]+ ){23}[a-z]+$');
    const backup = await textMatching(bob, '^cashbk1:[A-Za-z0-9_+/=-]+$');
    await clickLabel(bob, 'I have saved both', 'button');
    await expense(bob, 'Sent after browser backup', '5.00');
    await sync(alice);
    if (authenticated) {
      scenarioStage = 'explicit browser relay-copy consent';
      await sync(bob);
      await sync(alice);
      const pruneWrites = () => alice.events.filter(event =>
        event.method === 'Network.requestWillBeSent' && event.params.request.method === 'POST' &&
        event.params.request.url.startsWith(relayUrl) && event.params.request.url.endsWith('/prune'));
      const beforePrune = pruneWrites().length;
      for (const peer of [alice, bob]) {
        await clickLabel(peer, 'Household options', 'button');
        await clickLabel(peer, 'Manage relay copies');
      }
      assert.equal(pruneWrites().length, beforePrune, 'Opening consent controls cannot delete');
      await clickLabel(alice, 'Prepare request', 'button');
      const retentionRequest = await textMatching(alice, '^cashretreq1:[A-Za-z0-9_-]+$');
      await fill(bob, 'Request code', retentionRequest);
      await clickLabel(bob, 'Review approval', 'button');
      await clickLabel(bob, 'Keep relay copies', 'button');
      assert.equal(pruneWrites().length, beforePrune, 'Canceled approval cannot delete');
      await clickLabel(bob, 'Review approval', 'button');
      await clickLabel(bob, 'Approve deletion', 'button');
      const retentionApproval = await textMatching(bob, '^cashretok1:[A-Za-z0-9_-]+$');
      await clickLabel(alice, 'Review deletion', 'button');
      await clickLabel(alice, 'Delete relay copies', 'button');
      await waitForLabel(alice, 'Could not finish. FormatException: Deletion was not confirmed and some copies may already be deleted. Keep this device available. Retry with these codes while valid, or prepare a new request and collect new approvals.');
      assert.equal(pruneWrites().length, beforePrune, 'Missing approval must fail before any prune request');
      await fill(alice, 'Approval codes', retentionApproval);
      await clickLabel(alice, 'Review deletion', 'button');
      await clickLabel(alice, 'Keep relay copies', 'button');
      assert.equal(pruneWrites().length, beforePrune, 'Canceled deletion cannot contact pruning');
      await clickLabel(alice, 'Review deletion', 'button');
      await clickLabel(alice, 'Delete relay copies', 'button');
      await waitForLabel(alice, 'Approved old relay copies deleted. Saved history stays on devices.');
      const requests = pruneWrites().slice(beforePrune);
      assert(requests.length > 0, 'Confirmed deletion must use the actual prune endpoint');
      for (const request of requests) {
        assert(Object.keys(request.params.request.headers).some(key => key.toLowerCase() === 'x-cash-device-proof'));
        assert(alice.events.some(event => event.method === 'Network.responseReceived' &&
          event.params.requestId === request.params.requestId && event.params.response.status === 200),
          'Every actual deletion chunk must receive an authenticated successful response');
      }
      await clickLabel(bob, 'Close', 'button');
      await waitForLabel(alice, 'USD -50.00');
      await waitForLabel(bob, 'USD -50.00');
      const retained = await evaluate(alice, `localStorage.getItem('private_ledger.sqlite.v1')`);
      await alice.send('Page.reload');
      await openApp(alice);
      await waitForLabel(alice, 'Private Ledger');
      assert.equal(await evaluate(alice, `localStorage.getItem('private_ledger.sqlite.v1')`), retained,
        'Reload after pruning must retain the exact confirmed sealed SQLite image');
      await openHousehold(alice);
      await waitForLabel(alice, 'Unlock this browser');
      await fill(alice, '24-word unlock phrase', alicePhrase);
      await clickLabel(alice, 'Unlock household', 'button');
      await waitForLabel(alice, 'USD -50.00');
      await waitForLabel(alice, 'Expense total: USD 12.34');
      console.log('Verified production browser consent: no deletion on open/cancel/missing approval, authenticated unanimous chunks, sealed restart and preserved history.');
      scenarioStage = 'same-origin household identity lease';
      // Unlike newPeer(), this tab deliberately shares Alice's origin storage
      // and browser context. It must not obtain a second sender-state lease.
      const { targetId: siblingId } = await browser.send('Target.createTarget', { url: appUrl });
      let sibling;
      try {
        const page = await waitForPage(debugPort, appUrl, siblingId);
        sibling = await connectCdp(page.webSocketDebuggerUrl);
        peers.push(sibling);
        await sibling.send('Runtime.enable');
        await sibling.send('Page.enable');
        await sibling.send('Network.enable');
        await sibling.send('Page.bringToFront');
        await openApp(sibling);
        await waitForLabel(sibling, 'Private Ledger');
        await openHousehold(sibling);
        await waitForLabel(sibling, 'Unlock this browser');
        const beforeUnlock = await evaluate(alice, `localStorage.getItem('private_ledger.sqlite.v1')`);
        await fill(sibling, '24-word unlock phrase', alicePhrase);
        await clickLabel(sibling, 'Unlock household', 'button');
        await waitForLabel(sibling, 'The household is open in another tab. Lock or close that tab, then try again.');
        assert.equal(await evaluate(alice, `localStorage.getItem('private_ledger.sqlite.v1')`), beforeUnlock,
          'Rejected second-tab unlock must preserve the confirmed database');
        assert(!sibling.events.some(event => event.method === 'Network.requestWillBeSent' &&
          event.params.request.method === 'POST' && event.params.request.url.startsWith(relayUrl)),
          'A locked duplicate identity must never send relay writes');
        await waitForLabel(alice, 'USD -50.00');
        await alice.send('Page.bringToFront');
        await clickLabel(alice, 'Lock household in this browser', 'button');
        await waitForLabel(alice, 'Unlock this browser');
        await sibling.send('Page.bringToFront');
        await clickLabel(sibling, 'Unlock household', 'button');
        await waitForLabel(sibling, 'USD -50.00');
        await waitForLabel(sibling, 'Expense total: USD 12.34');
      } finally {
        await browser.send('Target.closeTarget', { targetId: siblingId });
        if (sibling) {
          peers.splice(peers.indexOf(sibling), 1);
          sibling.close();
        }
      }
      await alice.send('Page.bringToFront');
      await fill(alice, '24-word unlock phrase', alicePhrase);
      await clickLabel(alice, 'Unlock household', 'button');
      await waitForLabel(alice, 'USD -50.00');
      await waitForLabel(alice, 'Expense total: USD 12.34');
      console.log('Verified actual browser identity lease: duplicate tab cannot unlock/write, explicit lock transfers access, closing releases the lease.');
    }
    const replacement = await newPeer();
    await protect(replacement);
    await clickLabel(replacement, 'Restore from a backup', 'button');
    await fill(replacement, 'Your 24 words', backupPhrase);
    await fill(replacement, 'Backup code', backup);
    await clickLabel(replacement, 'Restore', 'button');
    await waitForLabel(replacement, 'Backup history saved');

    // Alice has just one other member here, so this removes the old Bob key.
    await clickLabel(alice, 'Remove from household', 'button');
    await clickLabel(alice, 'Remove', 'button');
    await accept(replacement, await invite(await joinRequest(replacement)));
    await waitForLabel(replacement, 'USD -50.00');
    await sync(bob, { allowAlreadyRemoved: true });
    await waitForLabel(bob, 'You are no longer in this household');
    await expense(alice, 'After old device retirement', '1.00');
    await sync(replacement);
    await waitForLabel(replacement, 'USD -51.00');
    console.log('Verified household: a stale backup rejoins with fresh keys; the old device is removed.');

    await createSharedAccount('Browser travel', 'EUR');
    await expense(alice, 'Browser EUR first', '10', 'Browser travel (EUR)', '1.1');
    await expense(alice, 'Browser EUR second', '10', 'Browser travel (EUR)', '1.2');
    await sync(replacement);
    await waitForLabel(replacement, 'USD -74.00');
    await createSharedAccount('Browser Japan', 'JPY');
    await expense(alice, 'Browser JPY train', '100', 'Browser Japan (JPY)', '0.0067');
    await sync(replacement);
    await waitForLabel(alice, 'USD -74.67');
    await waitForLabel(replacement, 'USD -74.67');
    await waitForLabel(replacement, 'Browser EUR first');
    await waitForLabel(replacement, 'Browser EUR second');
    console.log('Verified household: explicit EUR/JPY accounts and frozen entry rates converge through the production WASM UI.');

    await clickLabel(replacement, 'Back', 'button');
    await waitForLabel(replacement, 'Private Ledger');
    await waitForLabel(replacement, 'USD 0.00');
    const privateLeak = await evaluate(replacement, `document.body.textContent.includes('Groceries') || document.body.textContent.includes('Rent')`);
    assert.equal(privateLeak, false);
    await openHousehold(replacement);
    await waitForLabel(replacement, 'After old device retirement');
    await waitForLabel(replacement, 'Expense total: USD 12.34');
    const requests = [alice, bob, replacement].flatMap(peer => peer.events)
      .filter(event => event.method === 'Network.requestWillBeSent' && event.params.request.url.startsWith(relayUrl));
    assert(requests.some(event => event.params.request.method === 'POST'));
    assert(requests.some(event => event.params.request.method === 'GET'));
    if (authenticated) {
      assert(requests.some(event => event.params.request.method === 'PUT' && event.params.request.url.includes('/invite/')));
      assert(!requests.some(event => new URL(event.params.request.url).pathname.startsWith('/m/')),
        'Authenticated production peers must never use legacy mailbox routes');
    }
    for (const event of requests) {
      const body = event.params.request.postData ?? '';
      for (const title of ['Groceries', 'Rent', 'Private summary-only lunch', 'Quota blocked entry', 'After quota clears', 'Browser CSV, چائے 🍵', 'Browser shared dinner', 'Sent after browser backup',
        'Browser travel', 'Browser Japan', 'Browser EUR first', 'Browser EUR second', 'Browser JPY train']) {
        assert(!body.includes(title), 'Relay request leaked a readable financial title');
      }
    }
    const screenshot = await replacement.send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(repoRoot, 'app/.dart_tool/household-web-pass.png'), Buffer.from(screenshot.data, 'base64'));
    await Promise.race([workerFailure, Promise.resolve()]);
    console.log('Verified household: private ledgers stay separate; HTTP bodies contain no readable fixture titles.');
  } catch (error) {
    const responses=[alice,...peers].flatMap(peer=>peer.events)
      .filter(event=>event.method==='Network.responseReceived'&&event.params.response.url.startsWith(relayUrl)&&event.params.response.status>=400)
      .slice(-12).map(event=>({path:new URL(event.params.response.url).pathname,status:event.params.response.status}));
    console.error('Owned relay refusal diagnostics (paths/status only):',JSON.stringify(responses));
    for (const [index, peer] of [alice, ...peers].entries()) {
      const screenshot = await peer.send('Page.captureScreenshot', { format: 'png' }).catch(() => null);
      if (screenshot) writeFileSync(join(repoRoot, `app/.dart_tool/household-web-failure-${index}.png`), Buffer.from(screenshot.data, 'base64'));
    }
    throw error;
  } finally {
    for (const peer of peers) peer.close();
    for (const browserContextId of contexts) await browser.send('Target.disposeBrowserContext', { browserContextId }).catch(() => {});
    browser.close();
    await relay.dispose();
  }
}
