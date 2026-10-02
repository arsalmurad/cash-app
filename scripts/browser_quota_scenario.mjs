import assert from 'node:assert/strict';

// Exhaust real origin-local storage using an unrelated, owned fixture key.
// Never replace the app's database, patch its APIs, or inject financial state.
export async function runHouseholdQuotaScenario(peer, phrase, relayUrl, api) {
  const { evaluate, waitFor, waitForLabel, clickLabel, focusLabel, openApp } = api;
  const databaseKey = 'private_ledger.sqlite.v1';
  const fillerKey = 'cash-app.test.quota-filler';
  const proofKey = 'cash-app.test.quota-proof';
  const saved = () => evaluate(peer, `localStorage.getItem(${JSON.stringify(databaseKey)})`);
  const before = await saved();
  assert(before, 'A confirmed household database must exist before quota pressure');
  const group = peer.events.filter(event => event.method === 'Network.requestWillBeSent')
    .map(event => event.params.request.url).filter(url => url.startsWith(relayUrl))
    .map(url => new URL(url).pathname.match(/^\/g\/([0-9a-f]{32})(?:\/|$)/)?.[1])
    .find(Boolean);
  assert(group, 'No actual group request was observed');
  async function tail() {
    const response = await fetch(`${relayUrl}/g/${group}?after=0`);
    assert.equal(response.status, 200);
    return (await response.json()).tail;
  }
  const beforeTail = await tail();
  const labelsHaveRestart = `[...document.querySelectorAll('flt-semantics-host *')]
    .some(e => (e.getAttribute('aria-label') ?? e.textContent?.trim())?.includes('Restart'))`;
  async function rejectedExpense(title) {
    await clickLabel(peer, 'Add shared expense', 'button');
    await focusLabel(peer, 'Title');
    await peer.send('Input.insertText', { text: title });
    await focusLabel(peer, 'Amount');
    await peer.send('Input.insertText', { text: '1.00' });
    await clickLabel(peer, 'Add', 'button');
    await waitForLabel(peer, 'Restart');
  }
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
    // Enough new journal data to require more SQLite pages, even if its old
    // image has reusable pages. This title is only a synthetic fixture.
    await rejectedExpense(`Quota blocked entry ${'q'.repeat(16000)}`);
    assert((await saved()) === before, 'Quota failure changed confirmed database bytes');
    assert.equal(await tail(), beforeTail, 'Unconfirmed save published relay ciphertext');
  } finally {
    await evaluate(peer, `(() => {
      localStorage.removeItem(${JSON.stringify(fillerKey)});
      localStorage.removeItem(${JSON.stringify(proofKey)});
    })()`);
  }
  // Wait out the first real Snackbar so a new error proves the later request
  // was also refused after pressure cleared, not just an old visible message.
  await waitFor(peer, `!(${labelsHaveRestart})`);
  await rejectedExpense('After quota clears');
  assert((await saved()) === before, 'A failed household allowed later writes before restart');
  assert.equal(await tail(), beforeTail);

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
  console.log('Verified actual browser quota: confirmed SQLite bytes unchanged, no relay append, later writes refused, restart unlock restores confirmed state.');
}
