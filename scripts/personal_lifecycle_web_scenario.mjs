// Production UI only; read storage as evidence, never inject ledger state.
import assert from 'node:assert/strict';

export async function runPersonalLifecycleWebScenario(page, api) {
  const { openApp, evaluate, waitForLabel, clickLabel, focusLabel } = api;
  async function fill(label, value) {
    await focusLabel(page, label);
    await page.send('Input.insertText', { text: value });
  }
  const saved = () => evaluate(page, "localStorage.getItem('private_ledger.sqlite.v1')");
  async function navigate(tab) {
    await waitForLabel(page, tab);
    const controls = await evaluate(page,
      `[...document.querySelectorAll('flt-semantics-host [role="button"], flt-semantics-host [role="tab"]')]
        .map(e => e.getAttribute('aria-label') ?? e.textContent?.trim()).filter(Boolean)`);
    const matches = controls.filter(value => value.split(String.fromCharCode(10))[0] === tab);
    assert.equal(matches.length, 1, `Expected one rendered navigation control for ${tab}: ${JSON.stringify(controls)}`);
    await clickLabel(page, matches[0]);
  }
  await navigate('Budgets');
  await clickLabel(page, 'Add budget', 'button');
  await fill('Name', 'Lifecycle budget');
  await fill('Limit amount', '10');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Lifecycle budget');

  await navigate('Goals');
  await clickLabel(page, 'Add goal', 'button');
  await fill('Name', 'Lifecycle goal');
  await fill('Target amount', '100');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Lifecycle goal');

  await navigate('Recurring');
  await clickLabel(page, 'Add recurring', 'button');
  await fill('Title', 'Lifecycle bill');
  await fill('Amount', '1.23');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Lifecycle bill');
  await clickLabel(page, 'Record', 'button');
  await navigate('Overview');
  await waitForLabel(page, 'Net balance');
  await waitForLabel(page, 'Lifecycle bill');
  const beforeBalance = await evaluate(page,
    `[...document.querySelectorAll('flt-semantics-host *')]
      .map(e => e.getAttribute('aria-label') ?? e.textContent?.trim())
      .flatMap(label => typeof label === 'string' ? label.split(String.fromCharCode(10)) : [])
      .find(label => /^USD -\\d+\\.\\d{2}$/.test(label ?? ''))`);
  if (!beforeBalance) {
    const labels = await evaluate(page,
      `[...document.querySelectorAll('flt-semantics-host *')]
        .map(e => e.getAttribute('aria-label') ?? e.textContent?.trim())
        .filter(label => typeof label === 'string' && label.includes('USD'))`);
    throw new Error(`No displayed reporting balance: ${JSON.stringify(labels)}`);
  }

  for (const [tab, kind, title, empty] of [
    ['Budgets', 'budget', 'Lifecycle budget', 'No budgets yet'],
    ['Goals', 'goal', 'Lifecycle goal', 'No goals yet'],
    ['Recurring', 'recurring rule', 'Lifecycle bill', 'No upcoming bills'],
  ]) {
    await navigate(tab);
    const action = kind === 'recurring rule' ? 'Stop recurring rule' : `Remove ${kind}`;
    const before = await saved();
    async function open() {
      await clickLabel(page, `${kind} actions`, 'button');
      await clickLabel(page, action);
      await waitForLabel(page, `${action}?`);
    }
    await open();
    await clickLabel(page, `Keep ${kind}`, 'button');
    await waitForLabel(page, title);
    assert.equal(await saved(), before, 'Cancellation cannot write data');
    await open();
    await clickLabel(page, action, 'button');
    await waitForLabel(page, empty);
    assert.notEqual(await saved(), before, 'Removal must be durable');
  }
  await page.send('Page.reload');
  await openApp(page);
  await waitForLabel(page, beforeBalance);
  await waitForLabel(page, 'Lifecycle bill');
  for (const [tab, empty] of [
    ['Budgets', 'No budgets yet'], ['Goals', 'No goals yet'],
    ['Recurring', 'No upcoming bills'],
  ]) {
    await navigate(tab);
    await waitForLabel(page, empty);
  }
  await navigate('Overview');
  await waitForLabel(page, beforeBalance);
  console.log('Verified personal lifecycle: explicit cancel/confirm, SQLite reload, preserved recorded expense and unchanged balance.');
}
