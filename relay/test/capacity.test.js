import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";

// Storage seeding exists only in this in-memory test module, never deployment.
const fixture = `
import production, { GroupLog, Mailbox } from './production-worker.js';
export { Mailbox };
export class SeededGroupLog extends GroupLog {
  async fetch(request) {
    if (new URL(request.url).pathname === '/__seed') {
      await this.state.storage.put(await request.json());
      return Response.json({ok: true});
    }
    if (new URL(request.url).pathname === '/__rows') {
      return Response.json([...await this.state.storage.list()]);
    }
    return super.fetch(request);
  }
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith('/__test/')) {
      const [, , id, operation] = url.pathname.split('/');
      return env.GROUP.get(env.GROUP.idFromName(id)).fetch(
        new Request('http://fixture/__' + operation, request));
    }
    return production.fetch(request, env);
  }
};`;

let mf;
let nextId = 0;
const fresh = () => (++nextId).toString(16).padStart(32, "0");
const call = (path, body) => mf.dispatchFetch(`http://127.0.0.1${path}`,
  body === undefined ? undefined : {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
const append = (id, expected_tail, blob = "YQ==") =>
  call(`/g/${id}/append`, { expected_tail, blob });
const rows = async (id) => (await call(`/__test/${id}/rows`)).json();
const seed = (id, values) => call(`/__test/${id}/seed`, values);
const limit = 64 * 1024 * 1024;

before(async () => {
  const root = fileURLToPath(new URL("./", import.meta.url));
  mf = new Miniflare({
    modulesRoot: root,
    modules: [
      { type: "ESModule", path: `${root}/capacity-fixture.js`, contents: fixture },
      { type: "ESModule", path: `${root}/production-worker.js`,
        contents: await readFile(new URL("../src/worker.js", import.meta.url), "utf8") },
    ],
    durableObjects: { GROUP: "SeededGroupLog", MAILBOX: "Mailbox" },
    bindings: { LOCAL_DEVELOPMENT: "true" }, compatibilityDate: "2026-07-01",
  });
  await mf.ready;
});
after(async () => { await mf.dispose(); });

test("fresh log atomically accounts stored base64 bytes, not decoded bytes", async () => {
  const id = fresh();
  assert.equal((await append(id, 0)).status, 200);
  assert.equal((await append(id, 1, "YWJjZA==")).status, 200);
  assert.deepEqual(Object.fromEntries(await rows(id)), {
    "e:000000000001": "YQ==", "e:000000000002": "YWJjZA==",
    tail: 2, capacity: { version: 1, bytes: 12, entries: 2 },
  });
});

test("last allowed byte wins one racing append; full logs remain readable", async () => {
  const id = fresh();
  await seed(id, { tail: 1, "e:000000000001": "Yg==",
    capacity: { version: 1, bytes: limit - 4, entries: 1 } });
  const statuses = await Promise.all([append(id, 1), append(id, 1)])
    .then(results => results.map(response => response.status).sort());
  assert.deepEqual(statuses, [200, 409]);
  const before = await rows(id);
  assert.equal((await append(id, 2)).status, 507);
  assert.deepEqual(await rows(id), before, "capacity failure must not write or prune");
  const page = await (await call(`/g/${id}?after=0`)).json();
  assert.deepEqual(page.entries.map(entry => entry.blob), ["Yg==", "YQ=="]);
  assert.equal(page.tail, 2);
});

test("record cap bounds tiny ciphertext too, independently of byte cap", async () => {
  const id = fresh();
  await seed(id, { tail: 9999,
    capacity: { version: 1, bytes: 39996, entries: 9999 } });
  assert.equal((await append(id, 9999)).status, 200);
  const before = await rows(id);
  assert.equal((await append(id, 10000)).status, 507);
  assert.deepEqual(await rows(id), before);
  assert.equal((await append(id, 9999)).status, 409, "CAS conflicts retain precedence");
});

test("unaccounted legacy and malformed counters block writes, never erase history", async () => {
  for (const capacity of [undefined, null,
    { version: 2, bytes: 4, entries: 1 },
    { version: 1, bytes: -1, entries: 1 },
    { version: 1, bytes: 4.5, entries: 1 },
    { version: 1, bytes: limit + 1, entries: 1 },
    { version: 1, bytes: 4, entries: 0 }]) {
    const id = fresh();
    await seed(id, { tail: 1, "e:000000000001": "YQ==",
      ...(capacity === undefined ? {} : { capacity }) });
    const before = await rows(id);
    assert.equal((await append(id, 1)).status, 503);
    assert.deepEqual(await rows(id), before);
    const page = await (await call(`/g/${id}?after=0`)).json();
    assert.deepEqual(page.entries, [{ seq: 1, blob: "YQ==" }]);
  }
});

test("actual maximum-size records fill the byte ceiling and backfill losslessly", async () => {
  const id = fresh();
  const largest = Buffer.alloc(256 * 1024, 0xa5).toString("base64");
  let bytes = 0, tail = 0;
  while (bytes < limit) {
    // Both sizes are multiples of four, so truncation stays valid base64.
    const blob = largest.slice(0, Math.min(largest.length, limit - bytes));
    assert.equal((await append(id, tail, blob)).status, 200);
    tail++;
    bytes += blob.length;
  }
  assert.equal((await append(id, tail)).status, 507);
  let after = 0, readBytes = 0;
  while (after < tail) {
    const page = await (await call(`/g/${id}?after=${after}`)).json();
    assert.equal(page.tail, tail);
    assert(page.entries.length > 0 && page.entries.length <= 16);
    for (const entry of page.entries) {
      assert.equal(entry.seq, ++after);
      assert.equal(entry.blob, largest.slice(0, Math.min(largest.length, limit - readBytes)));
      readBytes += entry.blob.length;
    }
    assert.equal(page.more, after < tail);
  }
  assert.equal(readBytes, limit);
});
