import assert from "node:assert/strict";
import { test } from "node:test";
import { webcrypto } from "node:crypto";
import { fileURLToPath } from "node:url";
import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { once } from "node:events";
import { Miniflare } from "miniflare";
import { encodeRequestProofPayload } from "../src/request-proof.js";
import localWorker from "../src/local-auth-worker.js";

const group = "0123456789abcdef0123456789abcdef";
const origin = "http://127.0.0.1";
const identity = await webcrypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
const publicKey = Buffer.from(await webcrypto.subtle.exportKey("raw", identity.publicKey)).toString("hex");
const policy = { version: 2, epoch: 0, scope: { origin, kind: "g", id: group },
  devices: [{ key: publicKey, operations: ["append", "read"] }] };
let nextNonce = 0;
async function signed(path, method = "GET", body = "", proofOrigin = origin) {
  const nonce = (++nextNonce).toString(16).padStart(64, "0");
  const expires = Date.now() + 50_000;
  const digest = Buffer.from(await webcrypto.subtle.digest("SHA-256", new TextEncoder().encode(body))).toString("hex");
  const payload = encodeRequestProofPayload({ origin: proofOrigin, method, path, digest, publicKey, nonce, expires });
  const signature = Buffer.from(await webcrypto.subtle.sign("Ed25519", identity.privateKey, payload)).toString("hex");
  return { method, headers: { "x-cash-device-proof": JSON.stringify({ publicKey, nonce, expires, signature }) },
    ...(body ? { body } : {}) };
}

test("local authenticated routing uses real group transactions, rejects replay and stays public-closed", async () => {
  const mf = new Miniflare({ modules: true,
    modulesRules: [{ type: "ESModule", include: ["**/*.js"] }],
    scriptPath: fileURLToPath(new URL("../src/local-auth-worker.js", import.meta.url)),
    durableObjects: { GROUP: { className: "AuthenticatedGroupLog", useSQLite: true } },
    bindings: { LOCAL_DEVELOPMENT: "true", LOCAL_AUTH_POLICY: JSON.stringify(policy) },
    compatibilityDate: "2026-07-01" });
  try {
    const path = `/g/${group}/append`;
    const body = JSON.stringify({ expected_tail: 0, blob: "AQ==" });
    assert.equal((await mf.dispatchFetch(`${origin}${path}`, { method: "POST", body })).status, 401);
    assert.equal((await mf.dispatchFetch(`https://relay.example${path}`, await signed(path, "POST", body))).status, 503);
    const proof = await signed(path, "POST", body);
    const race = await Promise.all([mf.dispatchFetch(`${origin}${path}`, proof), mf.dispatchFetch(`${origin}${path}`, proof)]);
    assert.deepEqual(race.map(response => response.status).sort(), [200, 409]);
    const readPath = `/g/${group}?after=0`;
    const readProof = await signed(readPath);
    const response = await mf.dispatchFetch(`${origin}${readPath}`, readProof);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { entries: [{ seq: 1, blob: "AQ==" }], tail: 1, more: false });
    assert.equal((await mf.dispatchFetch(`${origin}${readPath}`)).status, 401);
    assert.equal((await mf.dispatchFetch(`${origin}${readPath}`, readProof)).status, 409);
    const wrongPath = `/g/${"ab".repeat(16)}/append`;
    assert.equal((await mf.dispatchFetch(`${origin}${wrongPath}`, await signed(wrongPath, "POST", body))).status, 403);
    assert.equal((await mf.dispatchFetch(`${origin}${path}`, { ...await signed(path, "POST", body),
      body: JSON.stringify({ expected_tail: 1, blob: "Ag==" }) })).status, 401);
    assert.equal((await mf.dispatchFetch(`${origin}${path}`, await signed(path, "POST", "x".repeat(512 * 1024 + 1)))).status, 413);
    const unchanged = await mf.dispatchFetch(`${origin}${readPath}`, await signed(readPath));
    assert.deepEqual(await unchanged.json(), { entries: [{ seq: 1, blob: "AQ==" }], tail: 1, more: false });
  } finally { await mf.dispose(); }
});

test("local fixed-namespace policy fails closed before allocating unknown storage", async () => {
  let calls = 0;
  const GROUP = { idFromName() { calls++; throw new Error("Unauthorized storage allocation"); } };
  for (const invalid of [undefined, "", "{}", JSON.stringify({ ...policy, scope: { ...policy.scope, origin: "https://relay.example" } }),
    JSON.stringify({ ...policy, scope: { ...policy.scope, kind: "m" } }),
    JSON.stringify({ ...policy, devices: [{ key: publicKey, operations: ["prune"] }] }), "x".repeat(32 * 1024 + 1)]) {
    const response = await localWorker.fetch(new Request(`${origin}/g/${group}`),
      { LOCAL_DEVELOPMENT: "true", LOCAL_AUTH_POLICY: invalid, GROUP });
    assert.equal(response.status, 503);
  }
  const env = { LOCAL_DEVELOPMENT: "true", LOCAL_AUTH_POLICY: JSON.stringify(policy), GROUP };
  for (const path of [`/g/${"ab".repeat(16)}`, `/g/${group}/`, `/g/${group}/ws`, `/g/${group}/membership`,
    `/g/${group}/prune`, `/m/${group}`, `/g/${group}/extra`]) {
    assert.equal((await localWorker.fetch(new Request(`${origin}${path}`), env)).status, 403);
  }
  assert.equal((await localWorker.fetch(new Request(`https://relay.example/g/${group}`), env)).status, 503);
  assert.equal((await localWorker.fetch(new Request(`${origin}/g/${group}`), { ...env, LOCAL_DEVELOPMENT: undefined })).status, 503);
  const preflight = await localWorker.fetch(new Request(`${origin}/g/${group}/append`, { method: "OPTIONS" }), env);
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-headers"), "content-type, x-cash-device-proof");
  assert.equal(calls, 0);
});

async function instrumented(fault = false) {
  const root = fileURLToPath(new URL("./", import.meta.url));
  // Only this in-memory fixture has seed/inspection/failure controls.
  const wrapper = `
    import worker, { AuthenticatedGroupLog } from './local-auth-worker.js';
    export class AuthFixture extends AuthenticatedGroupLog {
      constructor(state, env) {
        let failOnce = env.FAULT_ONCE === 'true';
        super({ getWebSockets: () => state.getWebSockets(), storage: {
          transaction: action => state.storage.transaction(txn => action(new Proxy(txn, {
            get(target, name) {
              if (name === 'put') return async (key, value) => {
                if (failOnce && key.startsWith('e:')) { failOnce = false; throw new Error('controlled append rollback'); }
                return target.put(key, value);
              };
              const value = target[name];
              return typeof value === 'function' ? value.bind(target) : value;
            }
          })))
        }}, env);
        this.raw = state;
      }
      async fetch(request) {
        if (request.headers.get('x-test-control') === 'seed') {
          await this.raw.storage.put(await request.json()); return Response.json({ok: true});
        }
        if (request.headers.get('x-test-control') === 'inspect') return Response.json([...await this.raw.storage.list()]);
        try { return await super.fetch(request); }
        catch { return Response.json({ok: false}, {status: 503}); }
      }
    }
    export default worker;`;
  return new Miniflare({ modulesRoot: root,
    modules: [{ type: "ESModule", path: `${root}/fixture.js`, contents: wrapper },
      ...await Promise.all(["local-auth-worker", "worker", "request-proof", "request-admission", "retired-readers", "request-scope", "request-budget"].map(async name => ({
        type: "ESModule", path: `${root}/${name}.js`,
        contents: await readFile(new URL(`../src/${name}.js`, import.meta.url), "utf8"),
      })))], durableObjects: { GROUP: { className: "AuthFixture", useSQLite: true } },
    bindings: { LOCAL_DEVELOPMENT: "true", LOCAL_AUTH_POLICY: JSON.stringify(policy), FAULT_ONCE: String(fault) },
    compatibilityDate: "2026-07-01" });
}

test("real authenticated append rollback rolls back policy, nonce, clock and ciphertext together", async () => {
  const mf = await instrumented(true);
  const path = `/g/${group}/append`;
  const inspect = async () => (await mf.dispatchFetch(`${origin}/g/${group}`, { headers: { "x-test-control": "inspect" } })).json();
  try {
    const init = await signed(path, "POST", JSON.stringify({ expected_tail: 0, blob: "AQ==" }));
    assert.equal((await mf.dispatchFetch(`${origin}${path}`, init)).status, 503);
    assert.deepEqual(await inspect(), [], "The failed first append must leave no policy or replay state behind");
    assert.equal((await mf.dispatchFetch(`${origin}${path}`, init)).status, 200);
    const rows = Object.fromEntries(await inspect());
    assert.equal(rows.tail, 1);
    assert.deepEqual(rows.capacity, { version: 1, bytes: 4, entries: 1 });
    assert.equal(rows[`request_nonces:${publicKey}`].records.length, 1);
    assert.equal(rows["e:000000000001"], "AQ==");
    assert.equal(rows.request_budget.used, 1);
  } finally { await mf.dispose(); }
});

test("actual request-budget refusal rolls back nonce and clock without changing history", async () => {
  const mf = await instrumented();
  const path = `/g/${group}`;
  const inspect = async () => (await mf.dispatchFetch(`${origin}${path}`, { headers: { "x-test-control": "inspect" } })).json();
  const seed = value => mf.dispatchFetch(`${origin}/g/${group}/append`, { method: "POST",
    headers: { "x-test-control": "seed" }, body: JSON.stringify(value) });
  try {
    assert.equal((await mf.dispatchFetch(`${origin}${path}`, await signed(path))).status, 200);
    await seed({ request_budget: {version: 1, day: Math.floor(Date.now() / 86_400_000), used: 10_000,
      devices: [{key: publicKey, used: 10_000}]} });
    const before = await inspect();
    const response = await mf.dispatchFetch(`${origin}${path}`, await signed(path));
    assert.equal(response.status, 429);
    assert(Number(response.headers.get("retry-after")) >= 1);
    assert(Number(response.headers.get("retry-after")) <= 86_400);
    assert.deepEqual(await inspect(), before, "A budget refusal cannot consume the nonce or move the clock");
    await seed({ request_budget: {version: 1, day: Math.floor(Date.now() / 86_400_000) - 1,
      used: 10_000, devices: [{key: publicKey, used: 10_000}]} });
    assert.equal((await mf.dispatchFetch(`${origin}${path}`, await signed(path))).status, 200);
    const reset = Object.fromEntries(await inspect()).request_budget;
    assert.equal(reset.used, 1);
    assert.deepEqual(reset.devices, [{key: publicKey, used: 1}]);
  } finally { await mf.dispose(); }
});

test("authenticated paged reads resume after nonce capacity without evicting history or live proofs", async () => {
  const mf = await instrumented();
  const path = `/g/${group}`;
  const inspect = async () => (await mf.dispatchFetch(`${origin}${path}`, {
    headers: { "x-test-control": "inspect" },
  })).json();
  try {
    assert.equal((await mf.dispatchFetch(`${origin}${path}`, await signed(path))).status, 200);
    // Test-only storage controls populate opaque sample entries and a nearly
    // full replay table. Production routing has no seed/inspection endpoint.
    const expires = Date.now() + 2000;
    const entries = Object.fromEntries(Array.from({ length: 320 }, (_, index) =>
      [`e:${String(index + 1).padStart(12, "0")}`, "AQ=="]));
    const records = Array.from({ length: 255 }, (_, index) => ({
      nonce: `ff${index.toString(16).padStart(62, "0")}`, expires,
    }));
    assert.equal((await mf.dispatchFetch(`${origin}${path}/append`, {
      method: "POST", headers: { "x-test-control": "seed" },
      body: JSON.stringify({ ...entries, tail: 320,
        capacity: { version: 1, bytes: 1280, entries: 320 },
        [`request_nonces:${publicKey}`]: { version: 1, records } }),
    })).status, 200);
    const firstPath = `${path}?after=0`;
    const firstProof = await signed(firstPath);
    const first = await mf.dispatchFetch(`${origin}${firstPath}`, firstProof);
    assert.equal(first.status, 200);
    const page = await first.json();
    assert.equal(page.entries.length, 16);
    assert.equal(page.more, true);
    let cursor = page.entries.at(-1).seq;
    const confirmed = page.entries.map(entry => entry.seq);
    const before = await inspect();
    const blockedPath = `${path}?after=${cursor}`;
    assert.equal((await mf.dispatchFetch(`${origin}${blockedPath}`, await signed(blockedPath))).status, 429);
    assert.deepEqual(await inspect(), before, "Nonce refusal preserves history, budget and clock");
    // Wait only for the seeded short-lived records. The first page's real
    // request proof remains live and must still be rejected as a replay.
    await new Promise(resolve => setTimeout(resolve, Math.max(0, expires - Date.now() + 30)));
    assert.equal((await mf.dispatchFetch(`${origin}${firstPath}`, firstProof)).status, 409);
    while (cursor < 320) {
      const nextPath = `${path}?after=${cursor}`;
      const response = await mf.dispatchFetch(`${origin}${nextPath}`, await signed(nextPath));
      assert.equal(response.status, 200);
      const next = await response.json();
      assert.equal(next.tail, 320);
      assert(next.entries.length > 0 && next.entries.length <= 16);
      confirmed.push(...next.entries.map(entry => entry.seq));
      cursor = next.entries.at(-1).seq;
      assert.equal(next.more, cursor < 320);
    }
    assert.deepEqual(confirmed, Array.from({ length: 320 }, (_, index) => index + 1));
    const rows = Object.fromEntries(await inspect());
    for (const [key, value] of Object.entries(entries)) assert.equal(rows[key], value);
    assert.equal(rows.tail, 320);
    assert.deepEqual(rows.capacity, { version: 1, bytes: 1280, entries: 320 });
    assert.equal(rows.request_budget.used, 21, "Only bootstrap and successful pages spend request budget");
    assert.equal(rows[`request_nonces:${publicKey}`].records.length, 20);
  } finally { await mf.dispose(); }
});

test("local auth cannot adopt legacy history or replace changed stored policy", async () => {
  const mf = await instrumented();
  const path = `/g/${group}/append`;
  const seed = value => mf.dispatchFetch(`${origin}${path}`, { method: "POST",
    headers: { "x-test-control": "seed" }, body: JSON.stringify(value) });
  const rows = async () => (await mf.dispatchFetch(`${origin}/g/${group}`, { headers: { "x-test-control": "inspect" } })).json();
  try {
    await seed({ tail: 1, "e:000000000001": "AQ==" });
    const before = await rows();
    assert.equal((await mf.dispatchFetch(`${origin}${path}`, await signed(path, "POST",
      JSON.stringify({ expected_tail: 1, blob: "Ag==" })))).status, 503);
    assert.deepEqual(await rows(), before);
    await seed({ authorized_devices: { ...policy, epoch: 1, devices: [{key: "ab".repeat(32), operations: ["read"]}] } });
    const changed = await rows();
    assert.equal((await mf.dispatchFetch(`${origin}/g/${group}`, await signed(`/g/${group}`))).status, 503);
    assert.deepEqual(await rows(), changed, "Configuration cannot silently restore a revoked device or reset replay state");
  } finally { await mf.dispose(); }
});

async function proveRustGroupAppend(proofJson) {
  const proof = JSON.parse(proofJson);
  const trusted = { ...policy, devices: [
    { key: proof.publicKey, operations: ["append"] },
    { key: publicKey, operations: ["read"] },
  ].sort((a, b) => a.key < b.key ? -1 : 1) };
  const mf = new Miniflare({ modules: true,
    modulesRules: [{ type: "ESModule", include: ["**/*.js"] }],
    scriptPath: fileURLToPath(new URL("../src/local-auth-worker.js", import.meta.url)),
    durableObjects: { GROUP: { className: "AuthenticatedGroupLog", useSQLite: true } },
    bindings: { LOCAL_DEVELOPMENT: "true", LOCAL_AUTH_POLICY: JSON.stringify(trusted) },
    compatibilityDate: "2026-07-01" });
  try {
    const init = { method: "POST", headers: { "x-cash-device-proof": JSON.stringify(proof) },
      body: '{"expected_tail":0,"blob":"AQ=="}' };
    const url = `${origin}/g/${group}/append`;
    assert.equal((await mf.dispatchFetch(url, init)).status, 200);
    assert.equal((await mf.dispatchFetch(url, init)).status, 409);
    const path = `/g/${group}`;
    assert.deepEqual(await (await mf.dispatchFetch(`${origin}${path}`, await signed(path))).json(),
      { entries: [{seq: 1, blob: "AQ=="}], tail: 1, more: false });
  } finally { await mf.dispose(); }
}

test("Rust opaque identity proof appends through the actual authenticated group route", {
  skip: !process.env.RUST_LOCAL_GROUP_PROOF_FIXTURE,
}, () => proveRustGroupAppend(process.env.RUST_LOCAL_GROUP_PROOF_FIXTURE));

test("Rust restored peer signs a fresh request accepted by the actual authenticated group", {
  skip: !process.env.RUST_PEER_GROUP_PROOF_FIXTURE,
}, () => proveRustGroupAppend(process.env.RUST_PEER_GROUP_PROOF_FIXTURE));

test("development launcher actually selects authenticated SQLite group routing", { timeout: 30_000 }, async () => {
  const reserve = createServer();
  reserve.listen(0, "127.0.0.1");
  await once(reserve, "listening");
  const port = reserve.address().port;
  await new Promise(resolve => reserve.close(resolve));
  const liveOrigin = `http://127.0.0.1:${port}`;
  const child = spawn(process.execPath, ["dev-server.mjs", String(port)], {
    cwd: fileURLToPath(new URL("../", import.meta.url)), windowsHide: true,
    env: { ...process.env, LOCAL_AUTH_POLICY: JSON.stringify({ ...policy, scope: { ...policy.scope, origin: liveOrigin } }) },
  });
  let output = "";
  child.stderr.on("data", () => {});
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Local authenticated launcher did not become ready")), 10_000);
      child.once("error", error => { clearTimeout(timer); reject(error); });
      child.once("exit", () => { clearTimeout(timer); reject(new Error("Local launcher exited before ready")); });
      child.stdout.on("data", chunk => {
        output = (output + chunk).slice(-2048);
        if (output.includes("local authenticated group relay listening")) { clearTimeout(timer); resolve(); }
      });
    });
    const path = `/g/${group}/append`;
    const body = JSON.stringify({ expected_tail: 0, blob: "AQ==" });
    assert.equal((await fetch(`${liveOrigin}${path}`, { method: "POST", body })).status, 401);
    assert.equal((await fetch(`${liveOrigin}${path}`, await signed(path, "POST", body, liveOrigin))).status, 200);
  } finally {
    // Only the process tree started by this test; never a user's browser/server.
    if (process.platform === "win32") {
      const stop = spawn("C:\\Windows\\System32\\taskkill.exe", ["/PID", String(child.pid), "/T", "/F"],
        { windowsHide: true, stdio: "ignore" });
      await once(stop, "exit");
    } else { child.kill("SIGTERM"); }
  }
});
