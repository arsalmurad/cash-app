import assert from 'node:assert/strict';

export async function withBrowserQuota(peer, evaluate, action) {
  const fillerKey = 'cash-app.test.quota-filler';
  const proofKey = 'cash-app.test.quota-proof';
  try {
    const pressure = await evaluate(peer, `(() => {
      const key = ${JSON.stringify(fillerKey)};
      const proof = ${JSON.stringify(proofKey)};
      if (localStorage.getItem(key) !== null || localStorage.getItem(proof) !== null)
        throw new Error('Quota fixture key unexpectedly exists');
      let low = 0, high = 16 * 1024 * 1024;
      while (low < high) {
        const middle = Math.ceil((low + high) / 2);
        try { localStorage.setItem(key, 'q'.repeat(middle)); low = middle; }
        catch (error) {
          if (error.name !== 'QuotaExceededError') throw error;
          high = middle - 1;
        }
      }
      localStorage.setItem(key, 'q'.repeat(low));
      let refused = false;
      try { localStorage.setItem(proof, 'q'); }
      catch (error) {
        if (error.name !== 'QuotaExceededError') throw error;
        refused = true;
      }
      localStorage.removeItem(proof);
      return { chars: low, refused };
    })()`);
    assert(pressure.chars > 0 && pressure.refused, 'Actual browser quota was not exhausted');
    await action();
  } finally {
    await evaluate(peer, `(() => {
      localStorage.removeItem(${JSON.stringify(fillerKey)});
      localStorage.removeItem(${JSON.stringify(proofKey)});
    })()`);
  }
}

// Exhaust real origin-local storage using an unrelated, owned fixture key.
// Never replace the app's database, patch its APIs, or inject financial state.
export async function runHouseholdQuotaScenario(peer, phrase, relayUrl, api) {
  const { evaluate, waitFor, waitForLabel, clickLabel, focusLabel, openApp, readRelayTail } = api;
  const databaseKey = 'private_ledger.sqlite.v1';
  const saved = () => evaluate(peer, `localStorage.getItem(${JSON.stringify(databaseKey)})`);
  let before = await saved();
  assert(before, 'A confirmed household database must exist before quota pressure');
  const group = peer.events.filter(event => event.method === 'Network.requestWillBeSent')
    .map(event => event.params.request.url).filter(url => url.startsWith(relayUrl))
    .map(url => new URL(url).pathname.match(/^\/g\/([0-9a-f]{32})(?:\/|$)/)?.[1])
    .find(Boolean);
  assert(group, 'No actual group request was observed');
  async function tail() {
    // Protected history must be read through an independently unlocked peer's
    // normal signed UI sync, never an anonymous inspection/bypass endpoint.
    if (readRelayTail) return readRelayTail(group);
    const response = await fetch(`${relayUrl}/g/${group}?after=0`);
    assert.equal(response.status, 200);
    return (await response.json()).tail;
  }
  const beforeTail = await tail();
  // The independent signed read can publish its saved-state receipt. Drain
  // that work before recording the database whose bytes pressure must preserve.
  await api.notificationIdle?.(peer);
  before = await saved();
  const image = Uint8Array.from(atob(before), char => char.charCodeAt(0));
  const header = new DataView(image.buffer);
  const encodedPageSize = header.getUint16(16);
  const pageSize = encodedPageSize === 1 ? 65536 : encodedPageSize;
  const freeBytes = header.getUint32(36) * pageSize;
  // Remain below the existing 64 KiB signed-event limit, while exceeding
  // the actual image's unused-page capacity by a substantial margin.
  const growthTitleChars = 60000;
  assert(freeBytes < 48000, 'Use a fresh fixture without a large unused SQLite prefix for the quota scenario');
  const beforeEvents = peer.events.length;
  const assertNoWrites = () => assert(!peer.events.slice(beforeEvents).some(event =>
    event.method === 'Network.requestWillBeSent' && event.params.request.method === 'POST' &&
    event.params.request.url.startsWith(relayUrl)), 'Unconfirmed saves must never send relay writes');
  async function rejectedExpense(title) {
    await clickLabel(peer, 'Add shared expense', 'button');
    await focusLabel(peer, 'Title');
    await peer.send('Input.insertText', { text: title });
    await focusLabel(peer, 'Amount');
    await peer.send('Input.insertText', { text: '1.00' });
    await clickLabel(peer, 'Add', 'button');
    await waitForLabel(peer, 'Restart');
  }
  await withBrowserQuota(peer, evaluate, async () => {
    // Exceed its measured free pages without exceeding the signed-event
    // bound. The first save requires growth. A periodic control
    // sync can still have completed an earlier valid save while the form was
    // open; retain that last checkpoint rather than promising batch rollback.
    await rejectedExpense(`Quota blocked entry ${'q'.repeat(growthTitleChars)}`);
    before = await saved();
    assert(before && atob(before).startsWith('SQLite format 3\0') &&
      atob(before).includes('cash-app sealed vault v1\0'), 'Quota failure lost the last sealed database');
    assert.equal(await tail(), beforeTail, 'Unconfirmed save published relay ciphertext');
    assertNoWrites();
  });
  // A failed save now replaces the stale household pane with a persistent
  // restart state. Clearing pressure must not restore write controls.
  await waitForLabel(peer, 'Restart the app before making changes.');
  await waitFor(peer, `![...document.querySelectorAll('flt-semantics-host [role="button"]')]
    .some(e => (e.getAttribute('aria-label') ?? e.textContent?.trim()) === 'Add shared expense')`);
  assert((await saved()) === before, 'A failed household allowed later writes before restart');
  assert.equal(await tail(), beforeTail);
  assertNoWrites();

  await peer.send('Page.reload');
  await openApp(peer);
  assert.equal(await saved(), before, 'Quota restart must preserve the confirmed SQLite image');
  await clickLabel(peer, 'Import or export', 'button');
  await clickLabel(peer, 'Household');
  await waitForLabel(peer, 'Unlock this browser');
  await focusLabel(peer, '24-word unlock phrase');
  await peer.send('Input.insertText', { text: phrase });
  await clickLabel(peer, 'Unlock household', 'button');
  await waitForLabel(peer, 'Shared balance');
  await waitForLabel(peer, 'USD 0.00');
  const leaked = await evaluate(peer,
    `document.body.textContent.includes('Quota blocked entry') || document.body.textContent.includes('After quota clears')`);
  assert.equal(leaked, false, 'Restart resurrected an unconfirmed quota-failed entry');
  assert.equal(await tail(), beforeTail);
  console.log('Verified actual browser quota: last confirmed sealed image retained, no relay append, restart-only UI, unlock restores state without the rejected expense.');
}
