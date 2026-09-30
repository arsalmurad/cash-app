// Cash App relay: a ciphertext-only, totally ordered log per household group.
//
// It is deliberately dumb. It stores opaque blobs and assigns them sequence
// numbers; it never parses a blob and has no field for a sender, a message
// kind, an amount, or a name. Group and mailbox identifiers are random hex
// chosen by clients. Behaviour mirrors `rust/sync/src/relay.rs`
// (`MemoryRelay`), which is the specification.
//
//   POST /g/{group}/append   {"expected_tail": n, "blob": "<base64>"}
//        -> 200 {"seq": n+1}  |  409 {"tail": current}
//   GET  /g/{group}?after=n  -> {"entries": [{"seq", "blob"}], "tail", "more"}
//   GET  /g/{group}/ws       -> WebSocket; receives {"tail": n} after each append
//   PUT  /m/{mailbox}        {"group", "joined_after", "welcome": "<base64>"}
//   POST /m/{mailbox}/take   -> the item once, then 404

const ID = /^[0-9a-f]{32}$/;
const MAX_BLOB_BYTES = 256 * 1024;
const PAGE = 500;
const MAILBOX_TTL_MS = 7 * 24 * 60 * 60 * 1000;

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

const fail = (status, message) => json({ error: message }, status);

function base64Bytes(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(text)) {
    return null;
  }
  try {
    const binary = atob(text);
    return binary.length;
  } catch {
    return null;
  }
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

const key = (seq) => `e:${String(seq).padStart(12, "0")}`;

export class GroupLog {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname.endsWith("/ws")) {
      return this.connect(request);
    }
    if (request.method === "POST" && url.pathname.endsWith("/append")) {
      return this.append(request);
    }
    if (request.method === "GET") {
      return this.read(url);
    }
    return fail(405, "method not allowed");
  }

  async append(request) {
    const body = await readJson(request);
    if (
      !body ||
      !Number.isSafeInteger(body.expected_tail) ||
      body.expected_tail < 0
    ) {
      return fail(400, "expected_tail must be a non-negative integer");
    }
    const size = base64Bytes(body.blob);
    if (size === null || size === 0 || size > MAX_BLOB_BYTES) {
      return fail(400, "blob must be non-empty base64 under the size limit");
    }
    const result = await this.state.storage.transaction(async (txn) => {
      const tail = (await txn.get("tail")) ?? 0;
      if (tail !== body.expected_tail) {
        return { conflict: tail };
      }
      const seq = tail + 1;
      await txn.put(key(seq), body.blob);
      await txn.put("tail", seq);
      return { seq };
    });
    if (result.conflict !== undefined) {
      return json({ tail: result.conflict }, 409);
    }
    const note = JSON.stringify({ tail: result.seq });
    for (const socket of this.state.getWebSockets()) {
      try {
        socket.send(note);
      } catch {
        // A dead socket is cleaned up by webSocketClose.
      }
    }
    return json({ seq: result.seq });
  }

  async read(url) {
    const after = Number(url.searchParams.get("after") ?? "0");
    if (!Number.isSafeInteger(after) || after < 0) {
      return fail(400, "after must be a non-negative integer");
    }
    const tail = (await this.state.storage.get("tail")) ?? 0;
    if (after >= tail) {
      return json({ entries: [], tail, more: false });
    }
    const stored = await this.state.storage.list({
      start: key(after + 1),
      end: key(tail + 1),
      limit: PAGE,
    });
    const entries = [];
    for (const [entryKey, blob] of stored) {
      entries.push({ seq: Number(entryKey.slice(2)), blob });
    }
    const last = entries.length ? entries[entries.length - 1].seq : after;
    return json({ entries, tail, more: last < tail });
  }

  connect(request) {
    if (request.headers.get("upgrade") !== "websocket") {
      return fail(426, "expected a WebSocket upgrade");
    }
    const pair = new WebSocketPair();
    // Hibernation API: the object can be evicted while sockets stay open.
    this.state.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  // Clients only listen; anything they send is ignored.
  async webSocketMessage() {}

  async webSocketClose(socket, code) {
    try {
      socket.close(code || 1000);
    } catch {
      // Already closed.
    }
  }
}

export class Mailbox {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "PUT") {
      const body = await readJson(request);
      if (
        !body ||
        typeof body.group !== "string" ||
        !ID.test(body.group) ||
        !Number.isSafeInteger(body.joined_after) ||
        body.joined_after < 0 ||
        base64Bytes(body.welcome) === null ||
        body.welcome.length === 0 ||
        body.welcome.length > MAX_BLOB_BYTES * 2
      ) {
        return fail(400, "invalid mailbox item");
      }
      if ((await this.state.storage.get("item")) !== undefined) {
        return fail(409, "mailbox already holds an item");
      }
      await this.state.storage.put("item", {
        group: body.group,
        joined_after: body.joined_after,
        welcome: body.welcome,
      });
      await this.state.storage.setAlarm(Date.now() + MAILBOX_TTL_MS);
      return json({ ok: true });
    }
    if (request.method === "POST" && url.pathname.endsWith("/take")) {
      const item = await this.state.storage.transaction(async (txn) => {
        const stored = await txn.get("item");
        if (stored !== undefined) {
          await txn.delete("item");
        }
        return stored;
      });
      return item === undefined ? fail(404, "empty mailbox") : json(item);
    }
    return fail(405, "method not allowed");
  }

  // An uncollected welcome expires rather than lingering forever.
  async alarm() {
    await this.state.storage.deleteAll();
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    const [kind, id] = parts;
    if (!id || !ID.test(id)) {
      return fail(404, "not found");
    }
    if (kind === "g") {
      return env.GROUP.get(env.GROUP.idFromName(id)).fetch(request);
    }
    if (kind === "m") {
      return env.MAILBOX.get(env.MAILBOX.idFromName(id)).fetch(request);
    }
    return fail(404, "not found");
  },
};
