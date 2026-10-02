import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import { Miniflare } from "miniflare";
import { fileURLToPath } from "node:url";
import { GroupLog } from "../src/worker.js";

const group = "0123456789abcdef0123456789abcdef";
const b64 = (text) => Buffer.from(text).toString("base64");

let mf;

before(async () => {
  mf = new Miniflare({
    modules: true,
    scriptPath: fileURLToPath(new URL("../src/worker.js", import.meta.url)),
    durableObjects: { GROUP: "GroupLog", MAILBOX: "Mailbox" },
    bindings: { LOCAL_DEVELOPMENT: "true" },
    compatibilityDate: "2026-07-01",
  });
  await mf.ready;
});

after(async () => {
  await mf.dispose();
});

const call = (path, init) => mf.dispatchFetch(`http://127.0.0.1${path}`, init);
const post = (path, body) =>
  call(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
const freshGroup = () =>
  Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join("");

test("oversized request bodies cannot write a log entry or mailbox", async () => {
  const id = freshGroup();
  const padding = " ".repeat(512 * 1024);
  const append = await call(`/g/${id}/append`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ expected_tail: 0, blob: b64("opaque") }) + padding,
  });
  assert.equal(append.status, 413);
  assert.equal((await (await call(`/g/${id}?after=0`)).json()).tail, 0);
  const mailbox = await call(`/m/${id}`, {
    method: "PUT", headers: { "content-type": "application/json" },
    body: JSON.stringify({ group: id, joined_after: 0, welcome: b64("opaque") }) + padding,
  });
  assert.equal(mailbox.status, 413);
  assert.equal((await call(`/m/${id}`)).status, 404);
});

test("decoded welcome size is bounded like an application blob", async () => {
  const id = freshGroup();
  const response = await call(`/m/${id}`, {
    method: "PUT", headers: { "content-type": "application/json" },
    body: JSON.stringify({ group: id, joined_after: 0,
      welcome: Buffer.alloc(256 * 1024 + 1).toString("base64") }),
  });
  assert.equal(response.status, 400);
  assert.equal((await call(`/m/${id}`)).status, 404);
});

test("streamed request bounds do not trust a smaller content length", async () => {
  let cancelled = false;
  let storageCalls = 0;
  const stream = new ReadableStream({
    pull(controller) { controller.enqueue(new Uint8Array(64 * 1024).fill(32)); },
    cancel() { cancelled = true; },
  });
  const log = new GroupLog({ storage: {
    transaction() { storageCalls++; throw new Error("Oversized body reached storage"); },
  } });
  const response = await log.append(new Request(`http://127.0.0.1/g/${group}/append`, {
    method: "POST", headers: { "content-length": "1" }, body: stream, duplex: "half",
  }));
  assert.equal(response.status, 413);
  assert.equal(cancelled, true);
  assert.equal(storageCalls, 0);
});

test("maximum allowed decoded blobs still pass both real worker routes", async () => {
  const id = freshGroup();
  const blob = Buffer.alloc(256 * 1024).toString("base64");
  assert.equal((await post(`/g/${id}/append`, { expected_tail: 0, blob })).status, 200);
  const response = await call(`/m/${id}`, {
    method: "PUT", headers: { "content-type": "application/json" },
    body: JSON.stringify({ group: id, joined_after: 1, welcome: blob }),
  });
  assert.equal(response.status, 200);
  assert.equal((await (await call(`/m/${id}`)).json()).welcome, blob);
});

test("actual default workerd deployment rejects data routes without development opt-in", async () => {
  const closed = new Miniflare({
    modules: true,
    scriptPath: fileURLToPath(new URL("../src/worker.js", import.meta.url)),
    durableObjects: { GROUP: "GroupLog", MAILBOX: "Mailbox" },
    compatibilityDate: "2026-07-01",
  });
  try {
    await closed.ready;
    for (const path of [`/g/${group}`, `/g/${group}/append`, `/g/${group}/ws`, `/m/${group}`, `/m/${group}/ack`]) {
      const response = await closed.dispatchFetch(`http://127.0.0.1${path}`);
      assert.equal(response.status, 503);
      assert.equal(response.headers.get("access-control-allow-origin"), null);
    }
  } finally {
    await closed.dispose();
  }
});

describe("group log", () => {
  test("appends are totally ordered and compare-and-swap", async () => {
    const id = freshGroup();
    let response = await post(`/g/${id}/append`, { expected_tail: 0, blob: b64("a") });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { seq: 1 });
    response = await post(`/g/${id}/append`, { expected_tail: 1, blob: b64("b") });
    assert.deepEqual(await response.json(), { seq: 2 });

    response = await post(`/g/${id}/append`, { expected_tail: 1, blob: b64("stale") });
    assert.equal(response.status, 409);
    assert.deepEqual(await response.json(), { tail: 2 });

    response = await call(`/g/${id}?after=0`);
    const read = await response.json();
    assert.deepEqual(read.entries, [
      { seq: 1, blob: b64("a") },
      { seq: 2, blob: b64("b") },
    ]);
    assert.equal(read.tail, 2);
    assert.equal(read.more, false);

    response = await call(`/g/${id}?after=1`);
    assert.deepEqual((await response.json()).entries, [{ seq: 2, blob: b64("b") }]);
    response = await call(`/g/${id}?after=2`);
    assert.deepEqual((await response.json()).entries, []);
  });

  test("groups are independent", async () => {
    const one = freshGroup();
    const two = freshGroup();
    await post(`/g/${one}/append`, { expected_tail: 0, blob: b64("x") });
    const response = await post(`/g/${two}/append`, { expected_tail: 0, blob: b64("y") });
    assert.deepEqual(await response.json(), { seq: 1 });
  });

  test("racing appends on one tail: exactly one wins", async () => {
    const id = freshGroup();
    const results = await Promise.all(
      Array.from({ length: 20 }, (_, index) =>
        post(`/g/${id}/append`, { expected_tail: 0, blob: b64(`racer-${index}`) }).then(
          (response) => response.status,
        ),
      ),
    );
    assert.equal(results.filter((status) => status === 200).length, 1);
    assert.equal(results.filter((status) => status === 409).length, 19);
    const read = await (await call(`/g/${id}?after=0`)).json();
    assert.equal(read.entries.length, 1);
  });

  test("a long log is paged, in order, with nothing skipped", async () => {
    const id = freshGroup();
    for (let seq = 0; seq < 620; seq += 1) {
      const response = await post(`/g/${id}/append`, {
        expected_tail: seq,
        blob: b64(`entry-${seq}`),
      });
      assert.equal(response.status, 200);
    }
    const seen = [];
    let after = 0;
    for (;;) {
      const page = await (await call(`/g/${id}?after=${after}`)).json();
      for (const entry of page.entries) {
        seen.push(entry.seq);
      }
      if (!page.more) {
        break;
      }
      after = page.entries[page.entries.length - 1].seq;
    }
    assert.deepEqual(seen, Array.from({ length: 620 }, (_, index) => index + 1));
  });

  test("maximum-sized blobs have bounded pages with lossless continuation", async () => {
    const id = freshGroup();
    const blob = Buffer.alloc(256 * 1024, 0xa5).toString("base64");
    for (let seq = 0; seq < 17; seq += 1) {
      assert.equal((await post(`/g/${id}/append`, {
        expected_tail: seq, blob,
      })).status, 200);
    }
    const seen = [];
    let after = 0;
    for (;;) {
      const response = await call(`/g/${id}?after=${after}`);
      assert.equal(response.status, 200);
      const text = await response.text();
      assert(Buffer.byteLength(text) < 6 * 1024 * 1024,
        "A page must not buffer hundreds of maximum-sized blobs");
      const page = JSON.parse(text);
      assert(page.entries.length > 0 && page.entries.length <= 16);
      assert.equal(page.tail, 17);
      for (const entry of page.entries) {
        assert.equal(entry.blob, blob);
        seen.push(entry.seq);
      }
      after = page.entries.at(-1).seq;
      assert.equal(page.more, after < 17);
      if (!page.more) break;
    }
    assert.deepEqual(seen, Array.from({ length: 17 }, (_, index) => index + 1));
    const finished = await (await call(`/g/${id}?after=${after}`)).json();
    assert.deepEqual(finished, { entries: [], tail: 17, more: false });
  });

  test("malformed appends are rejected without touching the log", async () => {
    const id = freshGroup();
    const bad = [
      { expected_tail: -1, blob: b64("x") },
      { expected_tail: 0.5, blob: b64("x") },
      { expected_tail: "0", blob: b64("x") },
      { expected_tail: 0, blob: "not base64!" },
      { expected_tail: 0, blob: "" },
      { expected_tail: 0 },
      { expected_tail: 0, blob: Buffer.alloc(300 * 1024).toString("base64") },
    ];
    for (const body of bad) {
      const response = await post(`/g/${id}/append`, body);
      assert.equal(response.status, 400, JSON.stringify(body).slice(0, 60));
    }
    const read = await (await call(`/g/${id}?after=0`)).json();
    assert.equal(read.tail, 0);
    const notJson = await call(`/g/${id}/append`, { method: "POST", body: "{" });
    assert.equal(notJson.status, 400);
    assert.equal((await call(`/g/${id}?after=-1`)).status, 400);
  });

  test("unknown routes and malformed ids are 404", async () => {
    assert.equal((await call("/")).status, 404);
    assert.equal((await call("/g/short")).status, 404);
    assert.equal((await call(`/x/${group}`)).status, 404);
  });

  test("a WebSocket listener is told the new tail after each append", async () => {
    const id = freshGroup();
    const upgrade = await call(`/g/${id}/ws`, { headers: { upgrade: "websocket" } });
    assert.equal(upgrade.status, 101);
    const socket = upgrade.webSocket;
    socket.accept();
    const messages = [];
    socket.addEventListener("message", (event) => messages.push(event.data));

    await post(`/g/${id}/append`, { expected_tail: 0, blob: b64("one") });
    await post(`/g/${id}/append`, { expected_tail: 1, blob: b64("two") });
    for (let wait = 0; wait < 50 && messages.length < 2; wait += 1) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.deepEqual(messages.map((message) => JSON.parse(message)), [
      { tail: 1 },
      { tail: 2 },
    ]);
    socket.close();
  });
});

describe("mailbox", () => {
  const welcome = b64("welcome bytes");

  test("a welcome can be taken exactly once", async () => {
    const id = freshGroup();
    let response = await call(`/m/${id}`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ group, joined_after: 3, welcome }),
    });
    assert.equal(response.status, 200);

    response = await post(`/m/${id}/take`, {});
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { group, joined_after: 3, welcome });
    assert.equal((await post(`/m/${id}/take`, {})).status, 404);
  });

  test("a mailbox holding an item cannot be overwritten", async () => {
    const id = freshGroup();
    const put = (joined_after = 1) =>
      call(`/m/${id}`, {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ group, joined_after, welcome }),
      });
    assert.equal((await put()).status, 200);
    assert.equal((await put()).status, 200, 'an exact retry is idempotent');
    assert.equal((await put(2)).status, 409, 'different data cannot overwrite');
    assert.equal((await post(`/m/${id}/take`, {})).status, 200);
    assert.equal((await put()).status, 200, 'a lost delivery reply may be retried');
    assert.equal((await post(`/m/${id}/take`, {})).status, 404, 'retry does not resurrect a consumed welcome');
  });

  test("invalid items are rejected", async () => {
    const id = freshGroup();
    const bad = [
      { group: "nope", joined_after: 1, welcome },
      { group, joined_after: -1, welcome },
      { group, joined_after: 1, welcome: "%%%" },
      { group, joined_after: 1, welcome: "" },
      { group, joined_after: 1 },
    ];
    for (const body of bad) {
      const response = await call(`/m/${id}`, {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      assert.equal(response.status, 400);
    }
  });

  test("welcome retrieval retries until an idempotent acknowledgement", async () => {
    const id = freshGroup();
    const item = { group, joined_after: 1, welcome };
    const put = () => call(`/m/${id}`, {
      method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(item),
    });
    assert.equal((await put()).status, 200);
    for (let retry = 0; retry < 3; retry++) {
      const read = await call(`/m/${id}`);
      assert.equal(read.status, 200);
      assert.deepEqual(await read.json(), item);
    }
    assert.equal((await post(`/m/${id}/ack`, {})).status, 200);
    assert.equal((await post(`/m/${id}/ack`, {})).status, 200);
    assert.equal((await call(`/m/${id}`)).status, 404);
    assert.equal((await put()).status, 200);
    assert.equal((await call(`/m/${id}`)).status, 404, 'delivery retry cannot undo acknowledgement');
  });
});

describe("cors (the web app calls the relay from a browser)", () => {
  test("preflight requests are answered without touching a group", async () => {
    const response = await call(`/g/${freshGroup()}/append`, {
      method: "OPTIONS",
      headers: {
        origin: "https://app.example",
        "access-control-request-method": "POST",
        "access-control-request-headers": "content-type",
      },
    });
    assert.equal(response.status, 204);
    assert.equal(response.headers.get("access-control-allow-origin"), "*");
    assert.match(response.headers.get("access-control-allow-methods"), /POST/);
    assert.match(response.headers.get("access-control-allow-headers"), /content-type/i);
  });

  test("every kind of response carries the allow-origin header", async () => {
    const id = freshGroup();
    const ok = await post(`/g/${id}/append`, { expected_tail: 0, blob: b64("a") });
    const conflict = await post(`/g/${id}/append`, { expected_tail: 0, blob: b64("b") });
    const bad = await post(`/g/${id}/append`, { expected_tail: -1, blob: b64("c") });
    const read = await call(`/g/${id}?after=0`);
    const missing = await call("/nope");
    const mailbox = await post(`/m/${freshGroup()}/take`, {});
    for (const response of [ok, conflict, bad, read, missing, mailbox]) {
      assert.equal(response.headers.get("access-control-allow-origin"), "*");
    }
    assert.deepEqual(
      [ok.status, conflict.status, bad.status, read.status, missing.status, mailbox.status],
      [200, 409, 400, 200, 404, 404],
    );
  });
});
