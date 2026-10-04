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
  if (process.env.WEB_CATEGORY_LIST === '1') {
    await runLongCategoryList(page, api);
  }
}

async function runLongCategoryList(page, api) {
  const { openApp, evaluate, waitFor, waitForLabel, clickLabel, focusLabel, delay } = api;
  const saved = () => evaluate(page, "localStorage.getItem('private_ledger.sqlite.v1')");
  async function manage() {
    await clickLabel(page, 'Import or export', 'button');
    await clickLabel(page, 'Manage categories');
    await waitForLabel(page, 'Categories');
  }
  async function name(value) {
    await focusLabel(page, 'Name');
    await page.send('Input.dispatchKeyEvent', {
      type: 'keyDown', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, modifiers: 2,
    });
    await page.send('Input.dispatchKeyEvent', {
      type: 'keyUp', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, modifiers: 2,
    });
    await page.send('Input.insertText', { text: value });
    await waitFor(page, `document.activeElement?.value === ${JSON.stringify(value)}`);
    await page.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
    await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  }
  async function bottomControl(requireScroll = false) {
    const visibleNames = () => evaluate(page, `[...document.querySelectorAll('flt-semantics-host *')]
      .filter(e => { const r=e.getBoundingClientRect(); return r.width>0 && r.height>0 && r.top>=0 && r.bottom<=innerHeight; })
      .map(e => e.getAttribute('aria-label') ?? e.textContent?.trim())
      .filter(label => /^Browser category \\d{2}$/.test(label ?? ''))`);
    const beforeNames = await visibleNames();
    // Physical wheel input, not DOM scroll/state injection. Thirty normal rows
    // fit well within this bounded total distance even on a narrow viewport.
    for (let i = 0; i < 12; i++) {
      await page.send('Input.dispatchMouseEvent', {
        type: 'mouseWheel', x: 150, y: 300, deltaX: 0, deltaY: 1800,
      });
      await delay(100);
    }
    const afterNames = await visibleNames();
    assert(afterNames.length > 0, 'Saved browser category rows must be visibly rendered');
    if (requireScroll) assert.notDeepEqual(afterNames, beforeNames, 'Physical wheel must actually move the category list');
    await page.send('Input.dispatchMouseEvent', {
      type: 'mouseWheel', x: 150, y: 300, deltaX: 0, deltaY: 1800,
    });
    await delay(200);
    assert.deepEqual(await visibleNames(), afterNames, 'An additional wheel must leave the final visible rows stable at the bottom');
    const geometry = await evaluate(page, `(() => {
      const controls = [...document.querySelectorAll('flt-semantics-host [role="button"]')];
      const label = e => e.getAttribute('aria-label') ?? e.textContent?.trim();
      const rect = e => { const r = e.getBoundingClientRect();
        return {left:r.left, right:r.right, top:r.top, bottom:r.bottom,
          x:r.x+r.width/2, y:r.y+r.height/2, width:r.width, height:r.height}; };
      const edits = controls.filter(e => label(e) === 'Edit category').map(rect)
        .filter(r => r.width > 0 && r.height > 0 && r.top >= 0 && r.bottom <= innerHeight)
        .sort((a,b) => a.top-b.top);
      const fab = controls.find(e => label(e) === 'New category');
      return {edit:edits.at(-1), fab:fab ? rect(fab) : null, height:innerHeight};
    })()`);
    assert(geometry.edit && geometry.fab, `Missing visible bottom controls: ${JSON.stringify(geometry)}`);
    const { edit, fab } = geometry;
    assert(!(edit.left < fab.right && edit.right > fab.left &&
      edit.top < fab.bottom && edit.bottom > fab.top), 'Bottom Edit must not overlap floating New category');
    return edit;
  }
  async function pointerEdit(requireScroll = false) {
    const { x, y } = await bottomControl(requireScroll);
    await page.send('Input.dispatchMouseEvent', { type:'mousePressed', button:'left', clickCount:1, x, y });
    await page.send('Input.dispatchMouseEvent', { type:'mouseReleased', button:'left', clickCount:1, x, y });
    await waitForLabel(page, 'Save');
    await focusLabel(page, 'Name');
    return evaluate(page, 'document.activeElement.value');
  }
  await manage();
  // Fresh owned browser profile has five seeded categories. Add 25 through the
  // actual production create/save path; every addition must change saved bytes.
  for (let i = 0; i < 25; i++) {
    const beforeCreate = await saved();
    await clickLabel(page, 'New category', 'button');
    await name(`Browser category ${String(i).padStart(2, '0')}`);
    await clickLabel(page, 'Travel icon', 'checkbox');
    await clickLabel(page, 'Create', 'button');
    await waitForLabel(page, 'Categories');
    await waitFor(page, `localStorage.getItem('private_ledger.sqlite.v1') !== ${JSON.stringify(beforeCreate)}`);
    if ((i + 1) % 5 === 0) console.log(`Saved ${i + 1}/25 additional categories through production UI.`);
  }
  const beforeCancel = await saved();
  const lastName = await pointerEdit(true);
  assert(lastName, 'Bottom pointer must open a populated category editor');
  await clickLabel(page, 'Cancel', 'button');
  await waitForLabel(page, 'Categories');
  assert.equal(await saved(), beforeCancel, 'Bottom-row cancellation must leave SQLite byte-identical');
  assert.equal(await pointerEdit(), lastName, 'The same bottom row must reopen');
  await name('Browser bottom category edited');
  await clickLabel(page, 'Travel icon', 'checkbox');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Categories');
  await waitFor(page, `localStorage.getItem('private_ledger.sqlite.v1') !== ${JSON.stringify(beforeCancel)}`);
  const confirmed = await saved();
  await page.send('Page.reload');
  await openApp(page);
  await waitForLabel(page, 'USD -512.34');
  await manage();
  assert.equal(await pointerEdit(), 'Browser bottom category edited', 'Bottom edit must persist after full reload');
  await waitFor(page, `[...document.querySelectorAll('flt-semantics-host [role="checkbox"]')]
    .some(e => e.getAttribute('aria-label') === 'Travel icon' && e.getAttribute('aria-checked') === 'true')`);
  await clickLabel(page, 'Cancel', 'button');
  await waitForLabel(page, 'Categories');
  assert.equal(await saved(), confirmed, 'Reload and review must preserve confirmed category edits');
  await clickLabel(page, 'Back', 'button');
  await waitForLabel(page, 'USD -512.34');
  console.log('Verified production thirty-category list: physical bottom scrolling/edit without FAB overlap, byte-unchanged cancellation, durable name/icon and unchanged balance.');
}
