import assert from "node:assert/strict";
import { test } from "node:test";
import { webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";
import { admitVerifiedDeviceRequest } from "../src/request-admission.js";
import { encodeRequestProofPayload, verifyRequestProof } from "../src/request-proof.js";

const now = 1_790_000_000_000;
const keys = await webcrypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
const key = Buffer.from(await webcrypto.subtle.exportKey("raw", keys.publicKey)).toString("hex");
const other = "ac".repeat(32);
async function signed(nonce = "01".repeat(32), expires = now + 30_000, path = "/g/0123456789abcdef0123456789abcdef/append") {
  const body = new Uint8Array();
  const digest = Buffer.from(await webcrypto.subtle.digest("SHA-256", body)).toString("hex");
  const payload = encodeRequestProofPayload({ origin: "https://relay.example", method: "POST",
    path, digest, publicKey: key, nonce, expires });
  const signature = Buffer.from(await webcrypto.subtle.sign("Ed25519", keys.privateKey, payload)).toString("hex");
  return { publicKey: key, nonce, expires, signature };
}
async function proof(nonce, expires) {
  const raw = await signed(nonce, expires);
  return verifyRequestProof(new Request("https://relay.example/g/0123456789abcdef0123456789abcdef/append", { method: "POST" }),
    new Uint8Array(), raw, key, raw.expires - 30_000);
}
const operations = ["append", "membership", "prune", "read", "ws"];
const roster = { version: 2, epoch: 3,
  scope: { origin: "https://relay.example", kind: "g", id: "0123456789abcdef0123456789abcdef" },
  devices: [{ key, operations }] };

function transaction(rows = {}) {
  const values = new Map(Object.entries(rows));
  return { values, get: async key => structuredClone(values.get(key)),
    put: async (key, value) => { values.set(key, structuredClone(value)); } };
}

test("only immutable verifier output can be admitted, not copied JSON metadata", async () => {
  const verified = await proof();
  assert(Object.isFrozen(verified));
  assert.throws(() => { verified.nonce = "ff".repeat(32); });
  const txn = transaction({ authorized_devices: roster });
  assert.deepEqual(await admitVerifiedDeviceRequest(txn, JSON.parse(JSON.stringify(verified)), now),
    { ok: false, reason: "invalid" });
  assert.equal((await admitVerifiedDeviceRequest(txn, verified, now)).ok, true);
});

test("transaction policy refuses a verified request in the wrong namespace or without its operation grant", async () => {
  const verified = await proof();
  for (const scoped of [
    {...roster.scope, origin: "https://other.example"},
    {...roster.scope, id: "02".repeat(16)},
  ]) {
    const txn = transaction({authorized_devices: {...roster, scope: scoped}});
    const before = structuredClone([...txn.values]);
    assert.deepEqual(await admitVerifiedDeviceRequest(txn, verified, now), {ok: false, reason: "scope"});
    assert.deepEqual([...txn.values], before);
  }
  const txn = transaction({authorized_devices: {...roster, devices: [{key, operations: ["read"]}]}});
  assert.deepEqual(await admitVerifiedDeviceRequest(txn, verified, now), {ok: false, reason: "permission"});
  assert.equal(txn.values.has(`request_nonces:${key}`), false);
});

test("admission requires the current transaction roster and rejects replay", async () => {
  const txn = transaction({ authorized_devices: roster });
  assert.deepEqual(await admitVerifiedDeviceRequest(txn, await proof(), now), { ok: true, epoch: 3 });
  const saved = structuredClone([...txn.values]);
  assert.deepEqual(await admitVerifiedDeviceRequest(txn, await proof(), now), { ok: false, reason: "replay" });
  assert.deepEqual([...txn.values], saved);
  txn.values.set("authorized_devices", { ...roster, epoch: 4, devices: [{key: other, operations}] });
  assert.deepEqual(await admitVerifiedDeviceRequest(txn, await proof("02".repeat(32)), now), { ok: false, reason: "unauthorized" });
});

test("expired replay rows may be replaced, never unexpired rows at capacity", async () => {
  const records = Array.from({ length: 256 }, (_, index) => ({
    nonce: index.toString(16).padStart(64, "0"), expires: now + 10_000,
  }));
  const txn = transaction({ authorized_devices: roster, request_clock: now,
    [`request_nonces:${key}`]: { version: 1, records } });
  const before = structuredClone([...txn.values]);
  assert.deepEqual(await admitVerifiedDeviceRequest(txn, await proof(), now), { ok: false, reason: "capacity" });
  assert.deepEqual([...txn.values], before);
  assert.deepEqual(await admitVerifiedDeviceRequest(txn, await proof("02".repeat(32), now + 40_000), now + 11_000), { ok: true, epoch: 3 });
  assert.equal(txn.values.get(`request_nonces:${key}`).records.length, 1);
});

test("persisted monotonic server time prevents old proof revival after clock rollback", async () => {
  const txn = transaction({ authorized_devices: roster });
  assert.equal((await admitVerifiedDeviceRequest(txn, await proof(), now)).ok, true);
  assert.equal((await admitVerifiedDeviceRequest(txn, await proof("02".repeat(32), now + 80_000), now + 40_000)).ok, true);
  assert.deepEqual(await admitVerifiedDeviceRequest(txn, await proof(), now), { ok: false, reason: "expired" });
});

test("missing/malformed policy, proof, clock or nonce state fails closed", async () => {
  for (const invalid of [undefined, null, { ...roster, version: 1 },
    { ...roster, devices: [] }, { ...roster, devices: [roster.devices[0], roster.devices[0]] },
    { ...roster, devices: [other, key].sort().reverse().map(key => ({key, operations})) },
    { ...roster, epoch: -1 }, { ...roster, scope: { ...roster.scope, id: "bad" } },
    { ...roster, devices: [{key, operations: ["read", "append"]}] }]) {
    const txn = transaction(invalid === undefined ? {} : { authorized_devices: invalid });
    const before = structuredClone([...txn.values]);
    assert.equal((await admitVerifiedDeviceRequest(txn, await proof(), now)).ok, false);
    assert.deepEqual([...txn.values], before);
  }
  for (const invalid of [null, { version: 2, records: [] },
    { version: 1, records: [{ nonce: "bad", expires: now + 1 }] },
    { version: 1, records: Array.from({ length: 257 }, () => ({ nonce: "01".repeat(32), expires: now + 1 })) }]) {
    const txn = transaction({ authorized_devices: roster, [`request_nonces:${key}`]: invalid });
    const before = structuredClone([...txn.values]);
    assert.equal((await admitVerifiedDeviceRequest(txn, await proof(), now)).ok, false);
    assert.deepEqual([...txn.values], before);
  }
  const txn = transaction({ authorized_devices: roster, request_clock: -1 });
  assert.equal((await admitVerifiedDeviceRequest(txn, await proof(), now)).ok, false);
  assert.deepEqual(await admitVerifiedDeviceRequest(transaction({ authorized_devices: roster }),
    { publicKey: key, nonce: "01".repeat(32), expires: now + 1 }, now), { ok: false, reason: "invalid" });
});

test("actual SQLite workerd transaction admits one racer, rolls back nonce with mutation, and rechecks revocation", async () => {
  const root = fileURLToPath(new URL("./", import.meta.url));
  // Seed/read/fault/revoke controls exist only inside this test module.
  const wrapper = `
    import { verifyRequestProof } from './request-proof.js';
    import { admitVerifiedDeviceRequest } from './request-admission.js';
    export class AdmissionFixture {
      constructor(state) { this.state = state; }
      async fetch(request) {
        const path = new URL(request.url).pathname;
        if (path.startsWith('/__seed/')) {
          await this.state.storage.put(await request.json());
          return Response.json({ok: true});
        }
        if (path.startsWith('/__rows/')) return Response.json([...await this.state.storage.list()]);
        const raw = JSON.parse(request.headers.get('x-test-proof'));
        const initial = await this.state.storage.get('authorized_devices');
        const trusted = initial?.devices.some(device => device.key === raw.publicKey) ? raw.publicKey : undefined;
        const verified = await verifyRequestProof(request, new Uint8Array(await request.arrayBuffer()), raw, trusted, ${now});
        if (!verified) return Response.json({ok: false}, {status: 401});
        if (request.headers.get('x-test-revoke') === '1') {
          await this.state.storage.put('authorized_devices', {...initial, epoch: 4, devices: [{key: '${other}', operations: ['append']}]});
        }
        try {
          const result = await this.state.storage.transaction(async txn => {
            const admitted = await admitVerifiedDeviceRequest(txn, verified, ${now});
            if (!admitted.ok) return admitted;
            await txn.put('accepted', (await txn.get('accepted') ?? 0) + 1);
            if (request.headers.get('x-test-fault') === '1') throw new Error('controlled rollback');
            return admitted;
          });
          return Response.json(result, {status: result.ok ? 200 : result.reason === 'replay' ? 409 : 403});
        } catch { return Response.json({ok: false}, {status: 503}); }
      }
    }
    export default { fetch(request, env) {
      const id = new URL(request.url).pathname.split('/')[2];
      return env.AUTH.get(env.AUTH.idFromName(id)).fetch(request);
    }};`;
  const mf = new Miniflare({ modulesRoot: root,
    modules: [
      { type: "ESModule", path: `${root}/admission-fixture.js`, contents: wrapper },
      ...await Promise.all(["request-proof", "request-admission", "request-scope"].map(async name => ({
        type: "ESModule", path: `${root}/${name}.js`,
        contents: await readFile(new URL(`../src/${name}.js`, import.meta.url), "utf8"),
      }))),
    ], durableObjects: { AUTH: { className: "AdmissionFixture", useSQLite: true } },
    compatibilityDate: "2026-07-01",
  });
  const call = (path, init) => mf.dispatchFetch(`https://relay.example${path}`, init);
  const seed = id => call(`/__seed/${id}`, { method: "POST", body: JSON.stringify({authorized_devices: {...roster, scope: {...roster.scope, id}}}) });
  const rows = async id => Object.fromEntries(await (await call(`/__rows/${id}`)).json());
  const invoke = (id, raw, extra = {}) => call(`/g/${id}/append`, { method: "POST", body: "",
    headers: { "x-test-proof": JSON.stringify(raw), ...extra } });
  try {
    await mf.ready;
    const id = "0123456789abcdef0123456789abcdef";
    await seed(id);
    const raw = await signed();
    const racers = await Promise.all([invoke(id, raw), invoke(id, raw)]);
    assert.deepEqual(racers.map(response => response.status).sort(), [200, 409]);
    assert.equal((await rows(id)).accepted, 1);
    const nonceRows = (await rows(id))[`request_nonces:${key}`];
    assert.equal(nonceRows.records.length, 1);
    for (const changed of [
      {...roster, scope: {...roster.scope, origin: "https://other.example"}},
      {...roster, devices: [{key, operations: ["read"]}]},
    ]) {
      await call(`/__seed/${id}`, {method: "POST", body: JSON.stringify({authorized_devices: changed})});
      assert.equal((await invoke(id, await signed("04".repeat(32)))).status, 403);
      assert.equal((await rows(id)).accepted, 1);
      assert.deepEqual((await rows(id))[`request_nonces:${key}`], nonceRows);
    }
    await seed(id); // Preserve nonce/clock; only restores the test policy.
    const revoked = await signed("02".repeat(32));
    assert.equal((await invoke(id, revoked, {"x-test-revoke": "1"})).status, 403);
    assert.equal((await rows(id)).accepted, 1);
    assert.deepEqual((await rows(id))[`request_nonces:${key}`], nonceRows);

    const second = "00000000000000000000000000000002";
    await seed(second);
    const retry = await signed("03".repeat(32), now + 30_000, `/g/${second}/append`);
    assert.equal((await invoke(second, retry, {"x-test-fault": "1"})).status, 503);
    assert.deepEqual(await rows(second), { authorized_devices: {...roster, scope: {...roster.scope, id: second}} }, "Mutation rollback must also roll back nonce/clock");
    assert.equal((await invoke(second, retry)).status, 200);
    assert.equal((await rows(second)).accepted, 1);
  } finally { await mf.dispose(); }
});
