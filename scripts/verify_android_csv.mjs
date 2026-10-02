// Owns only the explicitly named disposable emulator and synthetic CSV files.
// Flutter drives the app; this driver handles Android's actual document UI.
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { createWriteStream, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const adb = process.env.ADB_BINARY ?? 'D:/Android/Sdk/platform-tools/adb.exe';
const serial = process.env.ANDROID_DEVICE_SERIAL ?? 'emulator-5582';
assert.match(serial, /^emulator-\d+$/, 'Never run this fixture-reset test on a physical device');
const fixture = join(root, 'app/test_support/fixtures/native-transactions.csv');
const remoteInput = '/sdcard/Download/cash-app-native-input.csv';
const remoteOutput = '/sdcard/Download/private-ledger-transactions.csv';
const expected = readFileSync(fixture, 'utf8').replace(/^\uFEFF/, '');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const device = async (...args) => (await run(adb, ['-s', serial, ...args], {
  windowsHide: true, timeout: 20_000, maxBuffer: 2 * 1024 * 1024,
})).stdout;

assert.equal((await device('emu', 'avd', 'name')).split(/\r?\n/)[0].trim(), 'CashAppCsvApi36');
assert.equal(process.env.ANDROID_RESET_CSV_TEST_APP, '1', 'Explicit disposable-app reset opt-in is required');
const appPackage = 'app.privateledger.private_ledger';
const installed = await device('shell', 'pm', 'list', 'packages', appPackage);
if (installed.split(/\r?\n/).includes(`package:${appPackage}`)) {
  assert.match(await device('shell', 'pm', 'clear', appPackage), /Success/,
    'An installed disposable test app must be reset successfully');
}
// Only remove the previous synthetic export after verifying its exact contents.
const previous = join(root, 'app/.dart_tool/csv-android-export-previous.csv');
const old = await device('pull', remoteOutput, previous).catch(() => null);
if (old !== null) {
  assert.equal(readFileSync(previous, 'utf8'), expected,
    'Preserve unexpected output; it is not this test fixture');
  await device('shell', 'rm', remoteOutput);
}
await device('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP');
await device('shell', 'wm', 'dismiss-keyguard');
await device('shell', 'mkdir', '-p', '/sdcard/Download');
await device('push', fixture, remoteInput);
await device('shell', 'am', 'broadcast', '-a', 'android.intent.action.MEDIA_SCANNER_SCAN_FILE', '-d', `file://${remoteInput}`);

async function nodes() {
  await device('shell', 'uiautomator', 'dump', '--compressed', '/sdcard/cash-app-csv-ui.xml');
  const xml = await device('shell', 'cat', '/sdcard/cash-app-csv-ui.xml');
  return [...xml.matchAll(/<node\s+([^>]+)>/g)].map(match =>
    Object.fromEntries([...match[1].matchAll(/([\w-]+)="([^"]*)"/g)].map(field => [field[1], field[2]])));
}
async function tap(node) {
  assert.equal(node.package, 'com.android.documentsui');
  assert.equal(node.enabled, 'true');
  const bounds = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(node.bounds);
  assert(bounds, 'A current observed control must provide bounds');
  const [, x1, y1, x2, y2] = bounds.map(Number);
  await device('shell', 'input', 'tap', String(Math.floor((x1 + x2) / 2)), String(Math.floor((y1 + y2) / 2)));
}

const flutter = join(root, '.toolchains/flutter/bin/flutter.bat');
const log = createWriteStream(join(root, 'app/.dart_tool/android-csv-file-journey.log'));
const command = `""${flutter}" --no-version-check test --no-pub integration_test/csv_native_test.dart -d ${serial} --dart-define=RUN_DOCUMENT_PICKER_JOURNEY=true --reporter expanded"`;
const child = spawn(process.env.COMSPEC ?? 'cmd.exe', ['/d', '/s', '/c', command], {
  cwd: join(root, 'app'), env: process.env, windowsHide: true, windowsVerbatimArguments: true,
  stdio: ['ignore', 'pipe', 'pipe'],
});
let text = '';
for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => {
  const output = chunk.toString();
  text += output;
  log.write(output);
  process.stdout.write(output);
});
let result;
const completion = new Promise((resolve, reject) => {
  child.on('error', reject);
  child.on('close', code => { result = code; resolve(code); });
});
let selected = false, saved = false;
const deadline = Date.now() + 10 * 60_000;
try {
  while (result === undefined && Date.now() < deadline) {
    // Do not probe/repaint the device while the native build is still active.
    if (!text.includes('real Android file selection is reviewed')) {
      await delay(1000);
      continue;
    }
    const current = await nodes();
    assert(!current.some(node => /isn.t responding/.test(node.text)), 'Owned emulator System UI is unhealthy; do not hide its failure');
    const filename = current.find(node => node.package === 'com.android.documentsui' &&
      node.text === 'cash-app-native-input.csv' && node.enabled === 'true');
    if (!selected && filename) {
      await tap(filename);
      selected = true;
      console.log('Selected the real synthetic CSV through Android document UI.');
    } else if (selected && !saved && current.some(node => node.class === 'android.widget.EditText' &&
      node.text === 'private-ledger-transactions.csv')) {
      assert(current.some(node => node.text === 'Downloads'), 'Save only inside the owned Downloads fixture directory');
      const save = current.find(node => node.package === 'com.android.documentsui' &&
        node['resource-id'] === 'android:id/button1' && node.text === 'SAVE' && node.enabled === 'true');
      if (save) {
        await tap(save);
        saved = true;
        console.log('Confirmed the real Android document-provider Save action.');
      }
    }
    await delay(500);
  }
  assert.notEqual(result, undefined, 'Bounded native CSV journey timed out');
  assert.equal(await completion, 0, 'Native Flutter assertions must pass, not just picker clicks');
  assert(selected && saved, 'Both actual native picker actions must occur');
  const output = join(root, 'app/.dart_tool/csv-android-export.csv');
  await device('pull', remoteOutput, output);
  assert.equal(readFileSync(output, 'utf8'), expected);
  console.log(`PASS: actual Android provider exported ${Buffer.byteLength(expected)} exact UTF-8 CSV bytes; native clipboard, review-before-import and SQLite restart assertions passed.`);
} finally {
  if (child.exitCode === null) {
    // Kill only the command tree spawned by this driver, never shared Java,
    // emulator, browser or other user processes.
    await run('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true }).catch(() => {});
  }
  log.end();
}
