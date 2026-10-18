// Production WASM app only: real window lifecycle, browser network emulation,
// and actual localStorage quota. No patched APIs or injected app/ledger state.
import assert from 'node:assert/strict';
import { withBrowserQuota } from './browser_quota_scenario.mjs';

export async function runNotificationLifecycleWebScenario(bob, alice, phrase, relayUrl, api) {
  const { browser, targetId, evaluate, waitFor, waitForLabel, delay, openApp,
    clickLabel, edit, expense, voidFixtureExpense, fill, openHousehold, toggleLiveUpdates, notificationEvent,
    notificationIdle, workerFailure, stage } = api;
  const { windowId } = await browser.send('Browser.getWindowForTarget', { targetId });
  const saved = () => evaluate(bob, "localStorage.getItem('private_ledger.sqlite.v1')");
  const writes = start => bob.events.slice(start).filter(event =>
    event.method === 'Network.requestWillBeSent' && event.params.request.method === 'POST' &&
    new URL(event.params.request.url).origin === relayUrl);
  async function hidden() {
    const start = bob.events.length;
    await browser.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'minimized' } });
    await waitFor(bob, `document.visibilityState === 'hidden'`);
    await notificationEvent(bob, start, event => event.method === 'Network.webSocketClosed');
    return bob.events.length;
  }
  async function foreground() {
    await browser.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'normal' } });
    await bob.send('Page.bringToFront');
    await waitFor(bob, `document.visibilityState === 'visible' && document.hasFocus()`);
  }
  async function balance(label) {
    await Promise.race([workerFailure, waitForLabel(bob, label), delay(10000).then(() => {
      throw new Error('Notification backfill missed the ten-second rendered-balance deadline');
    })]);
  }
  async function openedAndRead(start) {
    const opened = await notificationEvent(bob, start, event =>
      event.method === 'Network.webSocketHandshakeResponseReceived' && event.params.response.status === 101);
    const read = await notificationEvent(bob, start, event =>
      event.method === 'Network.requestWillBeSent' && event.params.request.method === 'GET' &&
      event.params.request.url.startsWith(`${relayUrl}/g/`) && event.params.request.url.includes('?after=') &&
      event.params.timestamp >= opened.params.timestamp);
    await notificationEvent(bob, start, event => event.method === 'Network.responseReceived' &&
      event.params.requestId === read.params.requestId && event.params.response.status === 200);
  }

  stage('real browser background notification suspension');
  await notificationIdle(bob);
  const backgroundStart = await hidden();
  await edit(alice, '41.00');
  await delay(2500);
  assert(!bob.events.slice(backgroundStart).some(event => event.method === 'Network.webSocketCreated'),
    'A genuinely hidden page must not reconnect notifications');
  const foregroundStart = bob.events.length;
  await foreground();
  await openedAndRead(foregroundStart);
  await balance('USD -41.00');
  console.log('Verified production background: actual hidden window closes notifications, stays disconnected, foreground opens and backfills missed history.');

  stage('browser offline notification retry and reconnect');
  await notificationIdle(bob);
  await bob.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
  try {
    await hidden();
    const offlineStart = bob.events.length;
    await foreground();
    await notificationEvent(bob, offlineStart, event =>
      event.method === 'Network.webSocketFrameError' || event.method === 'Network.loadingFailed');
    await edit(alice, '42.00');
    await delay(5000);
    const attempts = bob.events.slice(offlineStart).filter(event => event.method === 'Network.webSocketCreated').length;
    assert(attempts > 0 && attempts <= 3, 'Offline retries must remain bounded by exponential backoff');
    await waitForLabel(bob, 'USD -41.00');
  } finally {
    await bob.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
  }
  const onlineStart = bob.events.length;
  await openedAndRead(onlineStart);
  await balance('USD -42.00');
  await edit(alice, '40.00');
  await balance('USD -40.00');
  console.log('Verified production offline notifications: actual browser network failures, bounded attempts, unchanged missed balance, fresh signed reconnect/HTTP and automatic convergence.');

  stage('received notification cannot save under actual browser quota');
  await notificationIdle(bob);
  let confirmed = await saved();
  let faultStart;
  // A tiny amount edit may fit existing SQLite pages even at full quota.
  // Publish enough actual journal data to require growth, through normal UI.
  const quotaTitle = `Notification quota payload ${'q'.repeat(4096)}`;
  await withBrowserQuota(bob, evaluate, async () => {
    faultStart = bob.events.length;
    await expense(alice, quotaTitle, '1.00');
    await waitForLabel(bob, 'Restart the app before making changes.');
    await notificationEvent(bob, faultStart, event => event.method === 'Network.webSocketClosed');
    // Catch-up may durably save smaller control-only prefixes before the
    // larger frame fails. Preserve that last confirmed image; do not demand
    // rollback of earlier successful writes in the same HTTP page.
    confirmed = await saved();
    assert(confirmed && atob(confirmed).startsWith('SQLite format 3\0') &&
      atob(confirmed).includes('cash-app sealed vault v1\0'),
      'An unconfirmed receive must retain a previously saved sealed SQLite image');
    assert.equal(writes(faultStart).length, 0, 'An unsaved received update must not publish a receipt or other write');
  });
  await delay(2500);
  assert(!bob.events.slice(faultStart).some(event => event.method === 'Network.webSocketCreated'),
    'Clearing quota must not restart a controller whose save was unconfirmed');
  assert.equal(writes(faultStart).length, 0, 'Clearing quota must not allow writes before restart');
  assert((await saved()) === confirmed, 'Clearing quota must preserve the last confirmed database');
  await waitFor(bob, `![...document.querySelectorAll('flt-semantics-host [role="button"]')]
    .some(e => (e.getAttribute('aria-label') ?? e.textContent?.trim()) === 'Add shared expense')`);
  await bob.send('Page.reload');
  await openApp(bob);
  assert((await saved()) === confirmed, 'Restart must begin with the exact confirmed database');
  await openHousehold(bob);
  await waitForLabel(bob, 'Unlock this browser');
  await fill(bob, '24-word unlock phrase', phrase);
  await clickLabel(bob, 'Unlock household', 'button');
  await waitForLabel(bob, 'Shared balance');
  // Reload deliberately resets live updates to off. Re-enable the public
  // option before requiring its unconditional open backfill, not a timer sync.
  const restartStart = bob.events.length;
  await toggleLiveUpdates(bob);
  await openedAndRead(restartStart);
  await balance('USD -41.00');
  await voidFixtureExpense(alice, quotaTitle);
  await balance('USD -40.00');
  console.log('Verified production received-save quota: unchanged confirmed image, no receipt before save, closed/no-retry session, restart/unlock/backfill and later signed live updates.');
}
