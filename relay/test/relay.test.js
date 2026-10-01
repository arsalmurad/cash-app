import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import { Miniflare } from "miniflare";
import { fileURLToPath } from "node:url";

const group = "0123456789abcdef0123456789abcdef";
const b64 = (text) => Buffer.from(text).toString("base64");

let mf;

before(async () => {
  mf = new Miniflare({
    modules: true,
    scriptPath: fileURLToPath(new URL("../src/worker.js", import.meta.url)),
    durableObjects: { GROUP: "GroupLog", MAILBOX: "Mailbox" },
    compatibilityDate: "2026-07-01",
  });
  await mf.ready;
});

after(async () => {
  await mf.dispose();
});

const call = (path, init) => mf.dispatchFetch(`http://relay.test${path}`, init);
const post = (path, body) =>
  call(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
const freshGroup = () =>
  Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join("");

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
