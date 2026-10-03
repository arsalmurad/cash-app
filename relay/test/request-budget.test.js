import assert from "node:assert/strict";
import { test } from "node:test";
import { webcrypto } from "node:crypto";
import { encodeRequestProofPayload, verifyRequestProof } from "../src/request-proof.js";
import { spendRequestBudget } from "../src/request-budget.js";

const DAY = 86_400_000;
const now = 2000 * DAY + 1000;
const identity = await webcrypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
const key = Buffer.from(await webcrypto.subtle.exportKey("raw", identity.publicKey)).toString("hex");
const other = "ab".repeat(32);
async function proof(at = now) {
  const fields = { origin: "https://relay.example", method: "GET", path: `/g/${"ab".repeat(16)}`,
    digest: Buffer.from(await webcrypto.subtle.digest("SHA-256", new Uint8Array())).toString("hex"),
    publicKey: key, nonce: "01".repeat(32), expires: at + 30_000 };
  const signature = Buffer.from(await webcrypto.subtle.sign("Ed25519", identity.privateKey,
    encodeRequestProofPayload(fields))).toString("hex");
  return verifyRequestProof(new Request(fields.origin + fields.path), new Uint8Array(),
    { publicKey: key, nonce: fields.nonce, expires: fields.expires, signature }, key, at);
}
function txn(budget) {
  return { saved: structuredClone(budget), writes: 0,
    async get(name) { assert.equal(name, "request_budget"); return this.saved; },
    async put(name, value) { assert.equal(name, "request_budget"); this.writes++; this.saved = structuredClone(value); } };
}
const budget = (used = 0, devices = []) => ({ version: 1, day: 2000, used, devices });

test("request budgets are bounded integer counters, independent of proof lifetime", async () => {
  const store = txn(budget(9999, [{key, used: 9999}]));
  const verified = await proof();
  await spendRequestBudget(store, verified, now);
  assert.equal(store.saved.used, 10_000);
  assert.equal(store.saved.devices[0].used, 10_000);
  const before = structuredClone(store.saved);
  await assert.rejects(spendRequestBudget(store, verified, now), error => error.status === 429 && error.retryAfter > 0);
  assert.deepEqual(store.saved, before);
  assert.equal(store.writes, 1);
});

test("group budget and bounded device slots cannot be bypassed by another key", async () => {
  const devices = [{key, used: 10_000}, {key: other, used: 10_000}].sort((a,b) => a.key < b.key ? -1 : 1);
  const store = txn(budget(20_000, devices));
  await assert.rejects(spendRequestBudget(store, await proof(), now), error => error.status === 429);
  assert.equal(store.writes, 0);
  const full = txn(budget(64, Array.from({length: 64}, (_, index) => ({ key: index.toString(16).padStart(64, "0"), used: 1 }))));
  await assert.rejects(spendRequestBudget(full, await proof(), now), error => error.status === 429);
  assert.equal(full.writes, 0);
});

test("new UTC day resets request counts, but rollback/fabrication/corruption cannot grant budget", async () => {
  const verified = await proof();
  const store = txn(budget(10_000, [{key, used: 10_000}]));
  await spendRequestBudget(store, await proof(now + DAY), now + DAY);
  assert.deepEqual(store.saved, {version: 1, day: 2001, used: 1, devices: [{key, used: 1}]});
  await assert.rejects(spendRequestBudget(store, verified, now), error => error.status === 503);
  for (const invalid of [undefined, null, {...budget(), version: 2}, {...budget(), used: -1},
    budget(1), budget(0, [{key, used: 1}]), budget(2, [{key, used: 1}, {key, used: 1}]),
    {...budget(), plaintext: "never preserve arbitrary metadata"}]) {
    const damaged = txn(invalid);
    await assert.rejects(spendRequestBudget(damaged, verified, now), error => error.status === 503);
    assert.equal(damaged.writes, 0);
  }
  await assert.rejects(spendRequestBudget(txn(budget()), {...verified}, now), error => error.status === 503);
});
