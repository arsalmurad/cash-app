// Production APK only: ordinary Android accessibility/pointer/keyboard input.
// Never resets app data, reads private files, or installs on a physical device.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { randomUUID, createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const adb = process.env.ADB_BINARY ?? 'D:/Android/Sdk/platform-tools/adb.exe';
const aapt = process.env.AAPT_BINARY ?? 'D:/Android/Sdk/build-tools/36.0.0/aapt2.exe';
const jar = process.env.JAR_BINARY ?? 'D:/cash-app-toolchains/jdk17/bin/jar.exe';
const serial = process.env.ANDROID_DEVICE_SERIAL ?? 'emulator-5580';
const appPackage = 'app.privateledger.private_ledger';
const apk = join(root, 'app/build/app/outputs/flutter-apk/app-x86_64-release.apk');
const fixture = `Release-${randomUUID()}`;
const remoteXml = `/sdcard/cash-app-release-ui-${randomUUID()}.xml`;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
assert.match(serial, /^emulator-\d+$/, 'Never install on a physical device');
const device = async (...args) => (await run(adb, ['-s', serial, ...args], {
  windowsHide: true, timeout: 30_000, maxBuffer: 4 * 1024 * 1024,
})).stdout;
assert.equal((await device('emu', 'avd', 'name')).split(/\r?\n/)[0].trim(), 'Phase0Api36');
assert.equal((await device('shell', 'getprop', 'sys.boot_completed')).trim(), '1');
const badging = (await run(aapt, ['dump', 'badging', apk], {
  windowsHide: true, timeout: 20_000,
})).stdout;
assert(badging.includes(`package: name='${appPackage}'`));
assert.match(badging, /native-code: 'x86_64'\s*$/m);
assert(!badging.includes('application-debuggable'), 'Production release must not be debuggable');
const entries = (await run(jar, ['tf', apk], {
  windowsHide: true, timeout: 20_000, maxBuffer: 4 * 1024 * 1024,
})).stdout.split(/\r?\n/);
assert(entries.includes('lib/x86_64/libapp.so'), 'Release must package actual AOT Dart code');
assert(entries.includes('lib/x86_64/librust_lib_cash_app.so'), 'Release must package the real native bridge');
console.log(`Production release APK SHA-256: ${createHash('sha256').update(readFileSync(apk)).digest('hex')}`);

const unescapeXml = value => value.replace(/&quot;/g, '"').replace(/&apos;/g, "'")
  .replace(/&#10;/g, '\n').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const labels = node => [node.text, node['content-desc'], node.hint].filter(Boolean)
  .flatMap(value => value.split(/\r?\n/).map(line => line.trim()));
async function nodes() {
  await device('shell', 'uiautomator', 'dump', '--compressed', remoteXml);
  const xml = await device('shell', 'cat', remoteXml);
  assert(!/isn.t responding/.test(xml), 'Do not hide an unhealthy emulator');
  return [...xml.matchAll(/<node\s+([^>]+)>/g)].map(match => Object.fromEntries(
    [...match[1].matchAll(/([\w-]+)="([^"]*)"/g)].map(field => [field[1], unescapeXml(field[2])]),
  ));
}
async function waitFor(predicate, description) {
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    const current = await nodes();
    const result = predicate(current);
    if (result) return result;
    await delay(300);
  }
  throw new Error(`Production APK UI timeout: ${description}`);
}
async function tapLabel(label, { editable = false } = {}) {
  const node = await waitFor(current => current.find(node => node.package === appPackage &&
    node.enabled === 'true' && node.clickable === 'true' && labels(node).includes(label) &&
    (!editable || node.class === 'android.widget.EditText')), label);
  const bounds = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(node.bounds);
  assert(bounds, 'Only tap currently observed control bounds');
  const [, x1, y1, x2, y2] = bounds.map(Number);
  assert(x2 > x1 && y2 > y1);
  await device('shell', 'input', 'tap', String(Math.floor((x1 + x2) / 2)), String(Math.floor((y1 + y2) / 2)));
}
async function uncoverAction(label) {
  const rect = node => {
    const values = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(node.bounds);
    assert(values, 'Observed scroll/action bounds are required');
    return values.slice(1).map(Number);
  };
  for (let attempt = 0; attempt < 4; attempt++) {
    const current = await waitFor(current => current.some(node =>
      node.package === appPackage && node.scrollable === 'true') && current,
    'current ledger scroll/action tree');
    const action = current.find(node => node.package === appPackage &&
      node.clickable === 'true' && labels(node).includes(label));
    const floating = current.find(node => node.package === appPackage &&
      node.clickable === 'true' && labels(node).includes('Add'));
    if (action && floating) {
      const [x1, y1, x2, y2] = rect(action);
      const [fx1, fy1, fx2, fy2] = rect(floating);
      const x = (x1 + x2) / 2, y = (y1 + y2) / 2;
      if (x < fx1 || x > fx2 || y < fy1 || y > fy2) return;
    }
    const viewport = current.find(node => node.package === appPackage && node.scrollable === 'true');
    assert(viewport, 'Use the actual ledger scroll container, not guessed screen coordinates');
    const [x1, y1, x2, y2] = rect(viewport);
    await device('shell', 'input', 'swipe', String(Math.floor((x1 + x2) / 2)),
      String(Math.floor(y1 + (y2 - y1) * 0.75)), String(Math.floor((x1 + x2) / 2)),
      String(Math.floor(y1 + (y2 - y1) * 0.35)), '350');
  }
  throw new Error('Synthetic transaction action never became clear of the floating button');
}
const hasLabel = (current, label) => current.some(node => node.package === appPackage && labels(node).includes(label));
function balance(current) {
  const label = current.filter(node => node.package === appPackage).flatMap(labels)
    .find(value => /^USD [-−]?\d[\d,]*\.\d{2}$/.test(value));
  if (!label) return null;
  const match = /^USD ([-−]?)([\d,]+)\.(\d{2})$/.exec(label);
  const minor = BigInt(match[2].replaceAll(',', '')) * 100n + BigInt(match[3]);
  return match[1] ? -minor : minor;
}
async function launch() {
  await device('shell', 'am', 'force-stop', appPackage);
  await device('shell', 'am', 'start', '-W', '-n', `${appPackage}/.MainActivity`);
  return waitFor(current => hasLabel(current, 'Private Ledger') && balance(current) !== null && current,
    'initialized production ledger');
}

async function verifyCategoryPicker(initialBalance) {
  const expected = [
    'Shopping cart icon', 'Dining icon', 'Car icon', 'Home icon', 'Money icon',
    'Shopping bag icon', 'Travel icon', 'Fitness icon', 'Pets icon',
    'Education icon', 'Entertainment icon', 'Health icon',
  ];
  async function inspect(selectedLabel) {
    const current = await waitFor(current => expected.every(label => hasLabel(current, label)) && current,
      'all twelve named native category choices');
    const choices = expected.map(label => {
      const matches = current.filter(node => node.package === appPackage && labels(node).includes(label));
      assert.equal(matches.length, 1, `${label}: one accessible native choice`);
      const node = matches[0];
      assert.equal(node.clickable, 'true', `${label}: ordinary native selection must be reachable`);
      return { label, selected: node.selected === 'true' || node.checked === 'true' };
    });
    assert.equal(choices.filter(choice => choice.selected).length, 1, 'Exactly one native selected icon');
    if (selectedLabel) assert(choices.find(choice => choice.label === selectedLabel)?.selected,
      'Selected native icon must expose its actual state');
  }
  await tapLabel('Import or export');
  await tapLabel('Manage categories');
  await waitFor(current => hasLabel(current, 'Categories'), 'native categories page');
  await tapLabel('New category');
  await inspect('Shopping cart icon');
  await tapLabel('Travel icon');
  await inspect('Travel icon');
  await tapLabel('Name', { editable: true });
  await device('shell', 'input', 'text', 'CancelledReleaseCategory');
  await device('shell', 'input', 'keyevent', 'KEYCODE_BACK');
  await tapLabel('Cancel');
  await waitFor(current => hasLabel(current, 'Categories'), 'cancelled native category creation');
  await tapLabel('Edit category');
  await waitFor(current => hasLabel(current, 'Save'), 'native existing category editor');
  await inspect();
  await tapLabel('Cancel');
  await waitFor(current => hasLabel(current, 'Categories'), 'cancelled native category edit');
  await tapLabel('Back');
  assert.equal(balance(await launch()), initialBalance, 'Picker cancellation/restart must preserve the exact ledger balance');
  assert(!hasLabel(await nodes(), 'CancelledReleaseCategory'), 'Cancelled category must not appear after restart');
  console.log('PASS: production Android category picker exposes twelve real names and selected states; pointer icon choice, creation/edit cancellation and process restart preserve the balance. No screen-reader or SQLite-byte claim.');
}

try {
  assert.match(await device('install', '-r', apk), /Success/);
  await device('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP');
  await device('shell', 'wm', 'dismiss-keyguard');
  const initial = balance(await launch());
  await tapLabel('Add');
  await tapLabel('Title', { editable: true });
  await device('shell', 'input', 'text', fixture);
  await tapLabel('Amount', { editable: true });
  await device('shell', 'input', 'text', '12.34');
  await device('shell', 'input', 'keyevent', 'KEYCODE_BACK');
  await tapLabel('Add transaction');
  await waitFor(current => hasLabel(current, fixture) && balance(current) === initial - 1234n,
    'one exact production expense');
  const restarted = await launch();
  assert(hasLabel(restarted, fixture), 'Process restart must retain the exact fixture');
  assert.equal(balance(restarted), initial - 1234n);
  await uncoverAction(`Transaction actions: ${fixture}`);
  await tapLabel(`Transaction actions: ${fixture}`);
  await tapLabel('Remove transaction');
  await waitFor(current => hasLabel(current, 'Remove transaction?'), 'explicit removal review');
  await tapLabel('Remove transaction');
  await waitFor(current => balance(current) === initial, 'only this fixture is excluded from balances');
  assert.equal(balance(await launch()), initial, 'Confirmed removal must survive process restart');
  console.log('PASS: production Android x86_64 release, real UI expense, exact minor-unit balance, process restart and confirmed fixture removal. Existing app data preserved; immutable fixture history remains.');
  if (process.env.ANDROID_CATEGORIES === '1') await verifyCategoryPicker(initial);
} catch (error) {
  console.error(`Owned synthetic fixture for diagnosis: ${fixture}`);
  const screenshot = await run(adb, ['-s', serial, 'exec-out', 'screencap', '-p'], {
    windowsHide: true, timeout: 20_000, encoding: 'buffer', maxBuffer: 8 * 1024 * 1024,
  }).catch(() => null);
  if (screenshot) writeFileSync(join(root, 'app/.dart_tool/android-release-ui-failure.png'), screenshot.stdout);
  throw error;
} finally {
  // The exact randomly named dump created by this invocation, never app data.
  await device('shell', 'rm', remoteXml).catch(() => {});
}
