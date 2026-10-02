import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker from '../src/worker.js';

const group = '0123456789abcdef0123456789abcdef';
const paths = [`/g/${group}`, `/g/${group}/append`, `/g/${group}/ws`,
  `/m/${group}`, `/m/${group}/take`, `/m/${group}/ack`];

function blockedBindings(localDevelopment) {
  let calls = 0;
  const namespace = {
    idFromName() { calls++; throw new Error('Blocked request reached storage'); },
  };
  return {
    env: { GROUP: namespace, MAILBOX: namespace, LOCAL_DEVELOPMENT: localDevelopment },
    count: () => calls,
  };
}

test('unconfigured relay refuses all data routes before accessing a Durable Object', async () => {
  for (const value of [undefined, false, 'false', '1', true]) {
    const bindings = blockedBindings(value);
    for (const path of paths) {
      for (const method of ['GET', 'POST', 'PUT', 'OPTIONS']) {
        const response = await worker.fetch(new Request(`http://127.0.0.1${path}`, { method }), bindings.env);
        assert.equal(response.status, 503);
        assert.equal(response.headers.get('access-control-allow-origin'), null);
      }
    }
    assert.equal(bindings.count(), 0);
  }
});

test('even explicitly enabled local development refuses non-loopback URLs', async () => {
  const bindings = blockedBindings('true');
  for (const host of ['relay.example', '127.0.0.1.example', 'localhost.example', '192.168.1.10', '[::ffff:7f00:1]']) {
    for (const path of paths) {
      const response = await worker.fetch(new Request(`http://${host}${path}`, {
        headers: { Host: '127.0.0.1', Origin: 'http://localhost' },
      }), bindings.env);
      assert.equal(response.status, 503);
    }
  }
  assert.equal(bindings.count(), 0);
});

test('explicit loopback development retains preflight without touching storage', async () => {
  const bindings = blockedBindings('true');
  for (const host of ['127.0.0.1', 'localhost', '[::1]']) {
    const response = await worker.fetch(new Request(`http://${host}/g/${group}/append`, { method: 'OPTIONS' }), bindings.env);
    assert.equal(response.status, 204);
    assert.equal(response.headers.get('access-control-allow-origin'), '*');
  }
  assert.equal(bindings.count(), 0);
});
