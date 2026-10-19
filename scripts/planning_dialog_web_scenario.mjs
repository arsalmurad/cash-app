// Owned production UI only. Read confirmed storage as evidence; never inject it.
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

export async function runPlanningDialogWebScenario(page, api) {
  const { evaluate, waitFor, waitForLabel, clickLabel, focusLabel, openApp, delay, repoRoot } = api;
  const category = 'Groceries and household supplies for the entire family';
  const account = 'Long term holiday savings and emergency fund in Japanese yen';
  const saved = () => evaluate(page, "localStorage.getItem('private_ledger.sqlite.v1')");
  const labels = () => evaluate(page, `[...document.querySelectorAll('flt-semantics-host *')]
    .map(e => e.getAttribute('aria-label') ?? e.textContent?.trim()).filter(Boolean)`);
  async function key(key, code, windowsVirtualKeyCode, modifiers = 0) {
    await page.send('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode, modifiers });
    await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode, modifiers });
  }
  async function fill(label, value) {
    await focusLabel(page, label);
    await key('a', 'KeyA', 65, 2);
    await page.send('Input.insertText', { text: value });
    await waitFor(page, `document.activeElement?.value === ${JSON.stringify(value)}`);
    await key('Tab', 'Tab', 9);
  }
  async function field(label, expected) {
    await focusLabel(page, label);
    assert.equal(await evaluate(page, 'document.activeElement.value'), expected, `${label} must survive reload exactly`);
    await key('Tab', 'Tab', 9);
  }
  async function navigate(tab) {
    await waitForLabel(page, tab);
    const control = (await labels()).find(label => label.split('\n')[0] === tab);
    assert(control, `Missing ${tab} destination`);
    await clickLabel(page, control);
  }
  async function pointer(label, field = false) {
    for (let attempt = 0; attempt < 12; attempt++) {
      const target = await evaluate(page, `(() => {
        const e=[...document.querySelectorAll('flt-semantics-host *')].find(e => {
          const value=e.getAttribute('aria-label') ?? e.textContent?.trim() ?? '';
          return ${field ? `(e.getAttribute('role')==='button' || e.getAttribute('role')==='combobox') &&
            value.split(String.fromCharCode(10)).some(line => line.trim()===${JSON.stringify(label)})` : `value===${JSON.stringify(label)}`};
        });
        if (!e) return null;
        const r=e.getBoundingClientRect();
        let top=0, bottom=innerHeight;
        for (let p=e.parentElement;p;p=p.parentElement) {
          if (!/(hidden|clip|scroll|auto)/.test(getComputedStyle(p).overflowY)) continue;
          const clip=p.getBoundingClientRect();
          if (clip.height>0) { top=Math.max(top,clip.top); bottom=Math.min(bottom,clip.bottom); }
        }
        const y=r.y+r.height/2;
        return {x:r.x+r.width/2,y,top,bottom,visible:r.width>0 && r.height>0 && y>=top+4 && y<=bottom-4};
      })()`);
      if (target?.visible) {
        await page.send('Input.dispatchMouseEvent', {type:'mousePressed',button:'left',clickCount:1,x:target.x,y:target.y});
        await page.send('Input.dispatchMouseEvent', {type:'mouseReleased',button:'left',clickCount:1,x:target.x,y:target.y});
        await delay(300);
        return;
      }
      const viewport = await evaluate(page, '({width:innerWidth,height:innerHeight})');
      await page.send('Input.dispatchMouseEvent', {type:'mouseWheel',x:viewport.width/2,y:viewport.height*0.55,
        deltaX:0,deltaY:target && target.y<target.top ? -200 : 200});
      await delay(100);
    }
    throw new Error(`Cannot reach planning ${field ? 'field' : 'option'}: ${label}`);
  }
  async function dropdown(label, option) {
    await pointer(label, true);
    await waitForLabel(page, option);
    await pointer(option);
    await selected(label, option);
  }
  async function selected(label, expected) {
    await waitFor(page, `[...document.querySelectorAll('flt-semantics-host [role="button"], flt-semantics-host [role="combobox"]')]
      .some(e => { const value=e.getAttribute('aria-label') ?? e.textContent?.trim() ?? '';
        return value.includes(${JSON.stringify(label)}) && value.includes(${JSON.stringify(expected)}); })`);
  }
  async function edit(kind) {
    await clickLabel(page, `${kind} actions`, 'button');
    await clickLabel(page, `Edit ${kind}`);
    await waitForLabel(page, `Edit ${kind}`);
  }
  async function reload(tab) {
    await page.send('Page.reload');
    await openApp(page);
    await navigate(tab);
  }
  async function review(name) {
    await delay(350);
    const screenshot = await page.send('Page.captureScreenshot', {format:'png'});
    const path = join(repoRoot, 'app', '.dart_tool', `planning-${process.pid}-${name}.png`);
    writeFileSync(path, Buffer.from(screenshot.data, 'base64'));
    console.log(`Saved rendered planning review: ${path}`);
  }

  // Establish long real definitions through their normal creation controls.
  await clickLabel(page, 'Import or export', 'button');
  await clickLabel(page, 'Manage categories');
  await waitForLabel(page, 'Categories');
  await delay(350);
  await clickLabel(page, 'New category', 'button');
  await fill('Name', category);
  await clickLabel(page, 'Create', 'button');
  await waitForLabel(page, category);
  await clickLabel(page, 'Back', 'button');
  await clickLabel(page, 'Add account', 'button');
  await fill('Name', account);
  await dropdown('Currency', 'JPY');
  await clickLabel(page, 'Create', 'button');
  await waitForLabel(page, account);
  await waitForLabel(page, 'USD -512.34');

  await navigate('Budgets');
  await clickLabel(page, 'Add budget', 'button');
  await fill('Name', 'Planning budget');
  await dropdown('Category', category);
  await dropdown('Period', 'Custom (rolling days)');
  await fill('Limit amount', '92233720368547758.07');
  await fill('Days', '365');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Planning budget');
  await reload('Budgets');
  const budgetBefore = await saved();
  await edit('budget');
  await selected('Category', category);
  await review('budget-category');
  await selected('Period', 'Custom (rolling days)');
  await field('Limit amount', '92233720368547758.07');
  await field('Days', '365');
  await fill('Name', 'Cancelled planning budget');
  await key('Escape', 'Escape', 27);
  await waitForLabel(page, 'Planning budget');
  assert.equal(await saved(), budgetBefore, 'Escape must preserve the confirmed budget bytes');
  console.log('Verified durable custom-period budget and byte-unchanged Escape cancellation.');

  await navigate('Goals');
  await clickLabel(page, 'Add goal', 'button');
  await fill('Name', 'Planning saving');
  await dropdown('Account', account);
  await waitForLabel(page, 'Target currency: JPY');
  await fill('Target amount', '9223372036854775807');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Planning saving');
  await reload('Goals');
  const savingBefore = await saved();
  await edit('goal');
  await selected('Account', account);
  await waitForLabel(page, 'Target currency: JPY');
  await field('Target amount', '9223372036854775807');
  await review('saving-account');
  await fill('Name', 'Cancelled planning saving');
  await key('Escape', 'Escape', 27);
  await waitForLabel(page, 'Planning saving');
  assert.equal(await saved(), savingBefore, 'Escape must preserve the confirmed JPY goal bytes');
  await clickLabel(page, 'goal actions', 'button');
  await clickLabel(page, 'Remove goal');
  await waitForLabel(page, 'Remove goal?');
  await clickLabel(page, 'Remove goal', 'button');
  await waitForLabel(page, 'No goals yet');

  await clickLabel(page, 'Add goal', 'button');
  await fill('Name', 'Planning spending');
  await dropdown('Kind', 'Spend under a cap');
  await dropdown('Category', category);
  await fill('Target amount', '100');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Planning spending');
  await reload('Goals');
  const spendingBefore = await saved();
  await edit('goal');
  await selected('Category', category);
  await waitForLabel(page, 'Target currency: USD');
  await field('Target amount', '100.00');
  await review('spending-category');
  await clickLabel(page, 'Cancel', 'button');
  await waitForLabel(page, 'Planning spending');
  assert.equal(await saved(), spendingBefore, 'Cancel must preserve the confirmed spending goal bytes');
  console.log('Verified durable exact JPY/USD goals and byte-unchanged cancellation.');

  await navigate('Recurring');
  await clickLabel(page, 'Add recurring', 'button');
  await fill('Title', 'Planning recurring');
  await dropdown('Account', account);
  await dropdown('Category', category);
  await dropdown('Frequency', 'Yearly');
  await fill('Amount', '9223372036854775807');
  await clickLabel(page, 'Save', 'button');
  await waitForLabel(page, 'Planning recurring');
  await reload('Recurring');
  const recurringBefore = await saved();
  await edit('recurring rule');
  await selected('Account', account);
  await selected('Category', category);
  await selected('Frequency', 'Yearly');
  await field('Amount', '9223372036854775807');
  await review('recurring-account');
  await fill('Title', 'Cancelled planning recurring');
  await key('Escape', 'Escape', 27);
  await waitForLabel(page, 'Planning recurring');
  assert.equal(await saved(), recurringBefore, 'Escape must preserve the confirmed recurring rule bytes');
  await navigate('Overview');
  await waitForLabel(page, 'USD -512.34');
  console.log('Verified production planning dialogs: long category/account selections, custom365-day/i64 budget, exact i64JPY saving/recurring and USD spending targets, new-document reload, Escape/cancel with unchanged SQLite bytes and unchanged net balance.');
}
