// Real production dialogs only; storage is read as evidence, never injected.
import assert from 'node:assert/strict';

export async function runCategoryPickerWebScenario(page, api) {
  const { evaluate, waitFor, waitForLabel, clickLabel } = api;
  const expected = [
    'Shopping cart icon', 'Dining icon', 'Car icon', 'Home icon', 'Money icon',
    'Shopping bag icon', 'Travel icon', 'Fitness icon', 'Pets icon',
    'Education icon', 'Entertainment icon', 'Health icon',
  ];
  const saved = () => evaluate(page, "localStorage.getItem('private_ledger.sqlite.v1')");
  const before = await saved();
  assert(before, 'Real confirmed SQLite image required');
  const choices = () => evaluate(page, `[...document.querySelectorAll('flt-semantics-host *')]
    .map(e => ({label: e.getAttribute('aria-label') ?? e.textContent?.trim(),
      role: e.getAttribute('role'), checked: e.getAttribute('aria-checked')}))
    .filter(e => ${JSON.stringify(expected)}.includes(e.label))`);
  async function inspect() {
    await waitForLabel(page, 'Shopping cart icon');
    const current = await choices();
    assert.deepEqual(current.map(e => e.label).sort(), [...expected].sort(), 'Every icon needs a distinct real browser name');
    for (const choice of current) {
      assert.equal(choice.role, 'checkbox', `${choice.label}: expected real selectable semantics`);
      assert(['true', 'false'].includes(choice.checked), `${choice.label}: selected state must be exposed`);
    }
  }
  await clickLabel(page, 'Import or export', 'button');
  await clickLabel(page, 'Manage categories');
  await waitForLabel(page, 'Categories');
  await clickLabel(page, 'New category', 'button');
  await inspect();
  await clickLabel(page, 'Travel icon', 'checkbox');
  await waitFor(page, `[...document.querySelectorAll('flt-semantics-host [role="checkbox"]')]
    .some(e => e.getAttribute('aria-label') === 'Travel icon' && e.getAttribute('aria-checked') === 'true')`);
  assert.equal((await choices()).filter(e => e.checked === 'true').length, 1, 'Exactly one chosen icon');
  await clickLabel(page, 'Cancel', 'button');
  await waitForLabel(page, 'Categories');
  assert.equal(await saved(), before, 'Cancelling a new category/icon choice must not write SQLite');
  await clickLabel(page, 'Edit category', 'button');
  await inspect();
  await clickLabel(page, 'Cancel', 'button');
  await waitForLabel(page, 'Categories');
  assert.equal(await saved(), before, 'Cancelling an existing category edit must not write SQLite');
  await clickLabel(page, 'Back', 'button');
  await waitForLabel(page, 'Private Ledger');
  assert.equal(await saved(), before, 'Picker review must preserve the entire confirmed ledger image');
  console.log('Verified production category picker: twelve real accessible names/checked states, icon selection and byte-unchanged creation/edit cancellation.');
}
