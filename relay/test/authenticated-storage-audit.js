// Test-only scanner: inspect the actual Durable Object KV view backed by SQLite.
import assert from 'node:assert/strict';

const exact = (value, fields) => assert.deepEqual(Object.keys(value).sort(), fields.sort());
const integer = value => assert(Number.isSafeInteger(value) && value >= 0);
const hex = value => assert(typeof value === 'string' && /^[0-9a-f]{64}$/.test(value));

export function auditAuthenticatedStorage(rows, policy, needles) {
  assert(Array.isArray(rows) && rows.length > 0, 'audit must inspect nonempty storage');
  const stored = new Map(rows);
  assert.equal(stored.size, rows.length, 'duplicate storage keys');
  assert.deepEqual(stored.get('authorized_devices'), policy);
  const keys = policy.devices.map(device => device.key);
  for (const required of ['tail', 'capacity', 'request_clock', 'request_budget',
    ...keys.map(key => `request_nonces:${key}`)]) assert(stored.has(required));
  let entries = 0, bytes = 0;
  for (const [key, value] of rows) {
    if (/^e:\d{12}$/.test(key)) {
      assert.equal(typeof value, 'string');
      const decoded = Buffer.from(value, 'base64');
      assert.equal(decoded.toString('base64'), value);
      for (const needle of needles) assert(!decoded.includes(Buffer.from(needle)), 'readable synthetic financial data');
      entries++;
      bytes += value.length;
    } else if (key === 'authorized_devices') {
      // Exact operator policy comparison rejects extra nested financial fields.
      assert.deepEqual(value, policy);
    } else if (key === 'tail' || key === 'request_clock') {
      integer(value);
    } else if (key === 'capacity') {
      exact(value, ['version', 'entries', 'bytes']);
      assert.equal(value.version, 1); integer(value.entries); integer(value.bytes);
    } else if (key === 'request_budget') {
      exact(value, ['version', 'day', 'used', 'devices']);
      assert.equal(value.version, 1); integer(value.day); integer(value.used);
      assert(value.used <= 20_000 && Array.isArray(value.devices));
      assert(value.devices.length <= keys.length);
      let used = 0, previous = '';
      for (const device of value.devices) {
        exact(device, ['key', 'used']);
        assert(keys.includes(device.key) && device.key > previous);
        integer(device.used); assert(device.used > 0 && device.used <= 10_000);
        used += device.used; previous = device.key;
      }
      assert.equal(used, value.used);
    } else if (keys.some(publicKey => key === `request_nonces:${publicKey}`)) {
      exact(value, ['version', 'records']); assert.equal(value.version, 1);
      assert(Array.isArray(value.records) && value.records.length <= 256);
      let previous = '';
      for (const record of value.records) {
        exact(record, ['nonce', 'expires']); hex(record.nonce); integer(record.expires);
        assert(record.nonce > previous); previous = record.nonce;
      }
    } else {
      assert.fail('unexpected persisted authenticated group field');
    }
  }
  assert(entries > 20, 'audit must inspect the nontrivial native app log');
  assert.equal(stored.get('tail'), entries);
  for (let seq = 1; seq <= entries; seq++) assert(stored.has(`e:${String(seq).padStart(12, '0')}`));
  assert.deepEqual(stored.get('capacity'), { version: 1, entries, bytes });
  // Scan encoded metadata too, not just the decoded ciphertext records.
  const serialized = Buffer.from(JSON.stringify(rows));
  for (const needle of needles) assert(!serialized.includes(Buffer.from(needle)), 'readable synthetic financial metadata');
  return entries;
}
