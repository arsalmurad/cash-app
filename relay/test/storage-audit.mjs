import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Miniflare } from 'miniflare';

const root = fileURLToPath(new URL('../../', import.meta.url));
const moduleRoot = fileURLToPath(new URL('./', import.meta.url));
const mf = new Miniflare({
  modulesRoot: moduleRoot,
  modules: [
    { type: 'ESModule', path: `${moduleRoot}/storage-audit-worker.js`, contents: await readFile(new URL('./storage-audit-worker.js', import.meta.url), 'utf8') },
    { type: 'ESModule', path: `${moduleRoot}/production-worker.js`, contents: await readFile(new URL('../src/worker.js', import.meta.url), 'utf8') },
  ],
  durableObjects: { GROUP: 'AuditGroupLog', MAILBOX: 'AuditMailbox' },
  compatibilityDate: '2026-07-01', host: '127.0.0.1', port: 0,
});

function scan(records, manifest) {
  assert(records.some(record => record.kind === 'group' && record.id === manifest.group));
  assert(records.some(record => record.kind === 'mailbox'), 'inspect welcomes as well as logs');
  const needles = [...new Set(manifest.needles)].map(hex => Buffer.from(hex, 'hex'));
  let entries = 0;
  const check = value => {
    for (const needle of needles) assert(!value.includes(needle), 'readable synthetic financial data found in actual storage');
  };
  for (const record of records) {
    check(Buffer.from(JSON.stringify(record)));
    for (const [key, value] of record.rows) {
      if (record.kind === 'group') {
        if (key === 'tail') { assert(Number.isSafeInteger(value)); continue; }
        assert(/^e:\d{12}$/.test(key), 'unexpected persisted group field');
        assert.equal(typeof value, 'string');
        check(Buffer.from(value, 'base64'));
        entries++;
      } else {
        assert(['item', 'consumed'].includes(key), 'unexpected persisted mailbox field');
        if (key === 'item') {
          assert.deepEqual(Object.keys(value).sort(), ['group', 'joined_after', 'welcome']);
          check(Buffer.from(value.welcome, 'base64'));
        } else assert.equal(value, true);
      }
    }
  }
  assert(entries > 20, 'storage inspection must not pass on an empty/trivial log');
  return entries;
}

try {
  const url = await mf.ready;
  const cargo = process.env.CARGO ?? 'cargo';
  const result = await new Promise((resolve, reject) => {
    const child = spawn(cargo, ['test', '--manifest-path', 'rust/Cargo.toml', '-p', 'cash_sync', '--features', 'http', '--test', 'http_relay', '--locked',
      'three_peers_converge_through_the_real_worker', '--', '--ignored', '--nocapture', '--test-threads=1'], {
      cwd: root, env: { ...process.env, RELAY_URL: url.toString(), CASH_RELAY_STORAGE_AUDIT: '1' },
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', code => resolve({ code, stdout, stderr }));
  });
  assert.equal(result.code, 0, `Rust peer scenario failed:\n${result.stderr}\n${result.stdout}`);
  const match = result.stdout.match(/STORAGE_AUDIT_MANIFEST:(\{[^\r\n]+\})/);
  assert(match, 'Rust scenario must provide synthetic needle evidence');
  const manifest = JSON.parse(match[1]);
  const records = await (await mf.dispatchFetch('http://audit/__audit')).json();
  const entries = scan(records, manifest);
  // Prove the scanner fails on plaintext leakage; otherwise an empty/no-op scan
  // could be mistaken for privacy evidence.
  const poisoned = structuredClone(records);
  poisoned.find(record => record.kind === 'group').rows.push(['e:999999999999', Buffer.from(manifest.needles[0], 'hex').toString('base64')]);
  assert.throws(() => scan(poisoned, manifest), /readable synthetic financial data/);
  console.log(`PASS: inspected actual workerd storage: ${entries} ciphertext log records plus encrypted mailboxes; plaintext injection rejected.`);
} finally {
  await mf.dispose();
}
