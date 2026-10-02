// Production UI only; read storage as evidence, never inject ledger state.
import assert from 'node:assert/strict';

export async function runPersonalLifecycleWebScenario(page, api) {
  const { openApp, evaluate, waitFor, waitForLabel, clickLabel, focusLabel } = api;
  async function fill(label, value) {
    await focusLabel(page, label);
    await page.send('Input.insertText', { text: value });
  }
  const saved = () => evaluate(page, "localStorage.getItem('private_ledger.sqlite.v1')");
  async function dropdown(label, option) {
    await waitFor(page, `[...document.querySelectorAll('flt-semantics-host [role="button"], flt-semantics-host [role="combobox"]')]
      .some(e => (e.getAttribute('aria-label') ?? e.textContent?.trim() ?? '').includes(${JSON.stringify(label)}))`);
    const controls = await evaluate(page,
      `[...document.querySelectorAll('flt-semantics-host [role="button"], flt-semantics-host [role="combobox"]')]
        .map(e => ({ label: e.getAttribute('aria-label') ?? e.textContent?.trim(), role: e.getAttribute('role') }))`);
    const control = controls.find(value => value.label?.includes(label));
    assert(control, `No rendered dropdown for ${label}: ${JSON.stringify(controls)}`);
    await clickLabel(page, control.label, control.role);
    await clickLabel(page, option);
  }
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
  await waitForLabel(page, 'Target currency: USD');
  await dropdown('Kind', 'Spend under a cap');
  await dropdown('Category', 'Food');
  await clickLabel(page, 'Add deadline (optional)', 'button');
  await clickLabel(page, 'OK', 'button');
  await fill('Target amount', '100');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Lifecycle goal');
  await page.send('Page.reload');
  await openApp(page);
  await navigate('Goals');
  await waitForLabel(page, 'Lifecycle goal');
  const goalBeforeEdit = await saved();
  await clickLabel(page, 'goal actions', 'button');
  await clickLabel(page, 'Edit goal');
  await waitForLabel(page, 'Food');
  await waitForLabel(page, 'Deadline:');
  await clickLabel(page, 'Cancel', 'button');
  assert.equal(await saved(), goalBeforeEdit, 'Cancelled goal edits cannot write data');

  await navigate('Recurring');
  await clickLabel(page, 'Add recurring', 'button');
  await fill('Title', 'Lifecycle bill');
  await fill('Amount', '1.23');
  await dropdown('Category', 'Food');
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
  await navigate('Goals');
  await waitForLabel(page, 'USD 1.23 of USD 100.00');

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
  // All entry is through rendered UI. This valid i64 amount exceeds the old
  // progress * 100 intermediate range; money labels must remain exact.
  const largeAmount = '10000000000000000.00';
  await navigate('Goals');
  await clickLabel(page, 'Add goal', 'button');
  await fill('Name', 'Large saving');
  await fill('Target amount', '0.01');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Large saving');
  await navigate('Budgets');
  await clickLabel(page, 'Add budget', 'button');
  await fill('Name', 'Large budget');
  await fill('Limit amount', '0.01');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Large budget');
  await navigate('Overview');
  await clickLabel(page, 'Add', 'button');
  await clickLabel(page, 'Income');
  await fill('Title', 'Large income');
  await fill('Amount', largeAmount);
  await clickLabel(page, 'Add transaction', 'button');
  await waitForLabel(page, 'Large income');
  await waitForLabel(page, `USD ${largeAmount}`);
  await page.send('Page.reload');
  await openApp(page);
  await navigate('Goals');
  await waitForLabel(page, '>1,000,000%');
  await navigate('Overview');
  await clickLabel(page, 'Add', 'button');
  await fill('Title', 'Large expense');
  await fill('Amount', largeAmount);
  await clickLabel(page, 'Add transaction', 'button');
  await waitForLabel(page, 'Large expense');
  await waitForLabel(page, beforeBalance);
  await page.send('Page.reload');
  await openApp(page);
  await waitForLabel(page, beforeBalance);
  await navigate('Budgets');
  await waitForLabel(page, '>1,000,000%');
  await waitForLabel(page, 'Large budget');
  await navigate('Overview');
  await waitForLabel(page, beforeBalance);
  console.log('Verified personal controls: goal currency/category/deadline reload, cancelled edit, categorized recurring posting, USD 1.23 goal progress, explicit removal and preserved balance.');
  console.log('Verified large money: exact income/expense entry, bounded goal/budget percentage display, durable reload and unchanged net balance.');

  await clickLabel(page, 'Add', 'button');
  await fill('Title', 'Correction fixture');
  await fill('Amount', '10.00');
  await clickLabel(page, 'Add transaction', 'button');
  await waitForLabel(page, 'Correction fixture');
  const beforeCorrection = await saved();
  await clickLabel(page, 'Transaction actions: Correction fixture', 'button');
  await clickLabel(page, 'Remove transaction');
  await clickLabel(page, 'Keep transaction', 'button');
  assert.equal(await saved(), beforeCorrection, 'Cancelled transaction removal cannot write data');
  await clickLabel(page, 'Transaction actions: Correction fixture', 'button');
  await clickLabel(page, 'Correct amount');
  await focusLabel(page, 'Amount');
  await page.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, modifiers: 2 });
  await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, modifiers: 2 });
  await page.send('Input.insertText', { text: '12.00' });
  await clickLabel(page, 'Save correction', 'button');
  await waitForLabel(page, '−USD 12.00');
  await clickLabel(page, 'Transaction actions: Correction fixture', 'button');
  await clickLabel(page, 'Change category');
  await waitForLabel(page, 'Category');
  await dropdown('Category', 'Food');
  await clickLabel(page, 'Save correction', 'button');
  await clickLabel(page, 'Transaction actions: Correction fixture', 'button');
  await clickLabel(page, 'Remove transaction');
  await clickLabel(page, 'Remove transaction', 'button');
  await waitForLabel(page, 'Removed from balances');
  await waitForLabel(page, beforeBalance);
  await page.send('Page.reload');
  await openApp(page);
  await waitForLabel(page, beforeBalance);
  await waitForLabel(page, 'Removed from balances');
  await clickLabel(page, 'Transaction actions: Correction fixture', 'button');
  await clickLabel(page, 'View history');
  for (const label of ['Recorded', 'Amount corrected', 'Category changed', 'Removed from balances', 'USD 10.00', 'USD 12.00']) {
    await waitForLabel(page, label);
  }
  await clickLabel(page, 'Close', 'button');
  console.log('Verified transaction corrections: cancelled removal, amount/category changes, durable removal, preserved balance and immutable history after full reload.');
}
