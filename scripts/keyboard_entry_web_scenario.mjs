// Owned production Chrome test. No application hooks or storage injection.
import assert from 'node:assert/strict';

export async function runKeyboardEntryWebScenario(page, api) {
  const { evaluate, waitFor, waitForLabel, clickLabel, focusLabel } = api;
  const saved = () => evaluate(page, `localStorage.getItem('private_ledger.sqlite.v1')`);
  async function key(key, code, windowsVirtualKeyCode, modifiers = 0) {
    await page.send('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode, modifiers });
    await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode, modifiers });
  }
  const focused = label => waitFor(page, `['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName) &&
    document.activeElement.getAttribute('aria-label')?.split(String.fromCharCode(10)).some(line => line.trim() === ${JSON.stringify(label)}) &&
    getEventListeners(document.activeElement).input?.length > 0`, { includeCommandLineAPI: true });
  const before = await saved();
  assert(before, 'The baseline ledger must exist before testing cancellation');
  await clickLabel(page, 'Add', 'button');
  await waitForLabel(page, 'Add transaction');
  // Only opening/initial field activation use pointer input. Subsequent field
  // traversal and dismissal use actual browser keyboard events.
  await focusLabel(page, 'Title');
  await page.send('Input.insertText', { text: 'Cancelled keyboard entry' });
  await key('Tab', 'Tab', 9);
  await focused('Amount');
  await page.send('Input.insertText', { text: '6.00' });
  // Flutter tracks the pressed physical keys; a Tab modifier bit alone is
  // not a held Shift key. Match the ordinary keyboard down/up sequence.
  await page.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Shift', code: 'ShiftLeft', windowsVirtualKeyCode: 16, modifiers: 8 });
  await key('Tab', 'Tab', 9, 8); // Shift+Tab
  await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Shift', code: 'ShiftLeft', windowsVirtualKeyCode: 16 });
  await focused('Title');
  await key('Escape', 'Escape', 27);
  await waitFor(page, `![...document.querySelectorAll('flt-semantics-host [role="button"]')]
    .some(e => (e.getAttribute('aria-label') ?? e.textContent?.trim()) === 'Add transaction')`);
  await waitForLabel(page, 'USD -512.34');
  assert.equal(await saved(), before, 'Keyboard cancellation cannot mutate persisted SQLite bytes');
  console.log('Verified production keyboard Tab/Shift+Tab, Escape cancellation and unchanged SQLite bytes.');
}
