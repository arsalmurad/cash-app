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
//   GET  /m/{mailbox}        -> retryable encrypted welcome until acknowledged
//   POST /m/{mailbox}/ack    -> consume after the receiver saves; idempotent

const ID = /^[0-9a-f]{32}$/;
const MAX_BLOB_BYTES = 256 * 1024;
const MAX_JSON_BYTES = 512 * 1024;
const BODY_TOO_LARGE = Symbol("request body too large");
// Bound the storage read itself, not just the JSON after all values are loaded.
// Sixteen maximum-size base64 blobs plus metadata stay below 6 MiB per page.
// The cursor/more protocol already supports any positive page length.
const PAGE = 16;
// Conservative per-log ceilings, not an account-wide free-plan guarantee.
// Count ASCII base64 as actually stored; never silently evict offline history.
const MAX_LOG_BYTES = 64 * 1024 * 1024;
const MAX_LOG_ENTRIES = 10_000;
// Existing keys have twelve decimal digits. Never cross the width boundary,
// where lexicographic order would no longer match absolute sequence order.
const MAX_SEQUENCE = 999_999_999_999;
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
  const declaredSize = Number(request.headers.get("content-length"));
  if (Number.isFinite(declaredSize) && declaredSize > MAX_JSON_BYTES) {
    await request.body?.cancel();
    return BODY_TOO_LARGE;
  }
  if (!request.body) return null;
  const reader = request.body.getReader();
  try {
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let bytesRead = 0;
    let text = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytesRead += value.byteLength;
      if (bytesRead > MAX_JSON_BYTES) {
        await reader.cancel();
        return BODY_TOO_LARGE;
      }
      text += decoder.decode(value, { stream: true });
    }
    return JSON.parse(text + decoder.decode());
  } catch {
    return null;
  } finally {
    reader.releaseLock();
  }
}

const key = (seq) => `e:${String(seq).padStart(12, "0")}`;
const rangeEnd = seq => seq === MAX_SEQUENCE ? "e;" : key(seq + 1);

async function logPosition(storage) {
  const storedTail = await storage.get("tail");
  const storedFloor = await storage.get("floor");
  const tail = storedTail === undefined ? 0 : storedTail;
  const floor = storedFloor === undefined ? 0 : storedFloor;
  if (!Number.isSafeInteger(tail) || tail < 0 || tail > MAX_SEQUENCE ||
      !Number.isSafeInteger(floor) || floor < 0 || floor > tail) return null;
  return {tail, floor};
}

function validCapacity(capacity, {tail, floor}) {
  return capacity && capacity.version === 1 &&
    Number.isSafeInteger(capacity.bytes) && capacity.bytes >= 0 &&
    capacity.bytes <= MAX_LOG_BYTES &&
    Number.isSafeInteger(capacity.entries) && capacity.entries >= 0 &&
    capacity.entries <= MAX_LOG_ENTRIES && capacity.entries === tail - floor;
}

export class PrefixRefused extends Error {
  constructor(status) {super("prefix transaction refused"); this.status = status;}
}
class PrefixConflict extends Error {
  constructor(floor,tail) {super("prefix transaction conflict");this.result={conflict:true,floor,tail};}
}

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

  async append(request, authorize = null, afterAppend = null) {
    const body = await readJson(request);
    if (body === BODY_TOO_LARGE) return fail(413, "request body exceeds size limit");
    if (
      !body ||
      !Number.isSafeInteger(body.expected_tail) ||
      body.expected_tail < 0 || body.expected_tail > MAX_SEQUENCE
    ) {
      return fail(400, "expected_tail must be a non-negative integer");
    }
    const size = base64Bytes(body.blob);
    if (size === null || size === 0 || size > MAX_BLOB_BYTES) {
      return fail(400, "blob must be non-empty base64 under the size limit");
    }
    const result = await this.state.storage.transaction(async (txn) => {
      if (authorize) {
        const denied = await authorize(txn);
        if (denied) return { denied };
      }
      const position = await logPosition(txn);
      if (!position) return {unavailable:true};
      const {tail} = position;
      if (tail !== body.expected_tail) {
        return { conflict: tail };
      }
      let capacity = await txn.get("capacity");
      if (capacity === undefined && tail === 0) {
        capacity = { version: 1, bytes: 0, entries: 0 };
      }
      if (!validCapacity(capacity, position)) {
        // Do not scan an old unbounded log into memory or guess its usage.
        // Reads remain available; an explicit bounded migration is required.
        return { unavailable: true };
      }
      if (tail === MAX_SEQUENCE || capacity.entries >= MAX_LOG_ENTRIES ||
          body.blob.length > MAX_LOG_BYTES - capacity.bytes) {
        return { full: true };
      }
      const seq = tail + 1;
      await txn.put(key(seq), body.blob);
      await txn.put("tail", seq);
      await txn.put("capacity", { version: 1,
        bytes: capacity.bytes + body.blob.length, entries: capacity.entries + 1 });
      // Optional transaction-local coordination. Throwing rolls back the frame,
      // capacity and any authentication state together; never run after commit.
      if (afterAppend) await afterAppend(txn, seq);
      return { seq };
    });
    if (result.denied) return fail(result.denied, "request admission refused");
    if (result.conflict !== undefined) {
      return json({ tail: result.conflict }, 409);
    }
    if (result.unavailable) return fail(503, "log capacity accounting requires migration or repair");
    if (result.full) return fail(507, "log capacity reached; history preserved, append refused");
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

  async read(url, authorize = null, historicalLimit = null) {
    const after = Number(url.searchParams.get("after") ?? "0");
    if (!Number.isSafeInteger(after) || after < 0) {
      return fail(400, "after must be a non-negative integer");
    }
    const read = async storage => {
      const position = await logPosition(storage);
      if (!position) return fail(503, "invalid log prefix accounting; history preserved");
      const {tail:storedTail, floor} = position;
      // Trusted authorizer sets this limit in the SAME transaction, never the
      // caller/query. Bound the storage read, not merely its returned values.
      const cutoff = historicalLimit?.() ?? storedTail;
      if (!Number.isSafeInteger(cutoff) || cutoff < 0 || cutoff > storedTail) {
        return fail(503, "invalid historical read limit");
      }
      const tail = cutoff;
      if (after < floor) {
        // Do not disclose a later floor/tail to a retired bounded reader.
        // The client must recover through a current peer, never jump cursors.
        return fail(410, "old history prefix unavailable; recover from a household peer");
      }
      if (after >= tail) {
        return json({ entries: [], tail, more: false });
      }
      const stored = await storage.list({
        start: key(after + 1),
        end: rangeEnd(tail),
        limit: PAGE,
      });
      if (stored.size !== Math.min(PAGE, tail - after)) {
        return fail(503, "log history is incomplete; recovery required");
      }
      const entries = [];
      for (const [entryKey, blob] of stored) {
        const seq = Number(entryKey.slice(2));
        const size = base64Bytes(blob);
        if (!/^e:[0-9]{12}$/.test(entryKey) || seq !== after + entries.length + 1 ||
            seq > tail || size === null || size === 0 || size > MAX_BLOB_BYTES) {
          return fail(503, "log history is incomplete or invalid; recovery required");
        }
        entries.push({ seq, blob });
      }
      if (!entries.length) return fail(503, "log history is incomplete; recovery required");
      const last = entries.length ? entries[entries.length - 1].seq : after;
      return json({ entries, tail, more: last < tail });
    };
    if (!authorize) return read(this.state.storage);
    return this.state.storage.transaction(async txn => {
      const denied = await authorize(txn);
      return denied ? fail(denied, "request admission refused") : read(txn);
    });
  }

  // Storage primitive, not permission by itself. The opt-in roster caller
  // verifies explicit all-current-device consent in authorize(txn, context)
  // on every chunk; protected-client recoverable availability remains a gate.
  // Explicit false/absent guards cannot become an unprotected deletion path.
  async prunePrefix(spec, authorize) {
    if (!spec || typeof spec !== "object" || Array.isArray(spec) ||
        JSON.stringify(Object.keys(spec).sort()) !== '["expectedFloor","through"]') {
      return fail(400, "invalid bounded prefix request");
    }
    // Capture primitives before the first await: an internal caller/guard must
    // not swap a signed target while authorization is in progress.
    const {expectedFloor, through} = spec;
    if (!Number.isSafeInteger(expectedFloor) || expectedFloor < 0 ||
        !Number.isSafeInteger(through) || through <= 0 ||
        through > MAX_SEQUENCE || expectedFloor > through) {
      return fail(400, "invalid bounded prefix request");
    }
    if (typeof authorize !== "function") return fail(403, "prefix authorization required");
    try {
      const result = await this.state.storage.transaction(async txn => {
        const position = await logPosition(txn);
        if (!position) throw new PrefixRefused(503);
        const {floor, tail} = position;
        const capacity = await txn.get("capacity");
        if (!validCapacity(capacity, position)) throw new PrefixRefused(503);
        if (await authorize(txn, Object.freeze({...position, through})) !== true) {
          // Throw, rather than return, so a denied guard's own writes roll back.
          throw new PrefixRefused(403);
        }
        // Authenticate before exposing conflict metadata. Public callers must
        // not learn a later floor/tail after revocation or invalid consent.
        if (expectedFloor !== floor || through > tail || through < floor) {
          // Authorization can write nonce/budget state. A conflicting request
          // must roll back that guard as well as preserve the financial log.
          throw new PrefixConflict(floor,tail);
        }
        if (floor === through) return {floor, tail, more:false};
        const nextFloor = Math.min(floor + PAGE, through);
        const stored = await txn.list({start:key(floor + 1), end:rangeEnd(nextFloor), limit:PAGE});
        if (stored.size !== nextFloor - floor) throw new PrefixRefused(503);
        let bytes = 0, sequence = floor;
        for (const [entryKey, blob] of stored) {
          const size = base64Bytes(blob);
          if (entryKey !== key(++sequence) ||
              size === null || size === 0 || size > MAX_BLOB_BYTES) throw new PrefixRefused(503);
          bytes += blob.length;
        }
        if (bytes > capacity.bytes || (nextFloor === tail && bytes !== capacity.bytes)) {
          throw new PrefixRefused(503);
        }
        const removed = await txn.delete([...stored.keys()]);
        if (removed !== stored.size) throw new PrefixRefused(503);
        await txn.put("floor", nextFloor);
        await txn.put("capacity", {version:1, bytes:capacity.bytes - bytes,
          entries:tail - nextFloor});
        return {floor:nextFloor, tail, more:nextFloor < through};
      });
      return json(result, result.conflict ? 409 : 200);
    } catch (error) {
      if(error instanceof PrefixConflict) return json(error.result,409);
      return fail(error instanceof PrefixRefused ? error.status : 503,
        "prefix transaction refused; history preserved");
    }
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
      if (body === BODY_TOO_LARGE) return fail(413, "request body exceeds size limit");
      const welcomeSize = base64Bytes(body?.welcome);
      if (
        !body ||
        typeof body.group !== "string" ||
        !ID.test(body.group) ||
        !Number.isSafeInteger(body.joined_after) ||
        body.joined_after < 0 ||
        welcomeSize === null ||
        welcomeSize === 0 ||
        welcomeSize > MAX_BLOB_BYTES
      ) {
        return fail(400, "invalid mailbox item");
      }
      const item = {
        group: body.group,
        joined_after: body.joined_after,
        welcome: body.welcome,
      };
      const result = await this.state.storage.transaction(async (txn) => {
        const stored = await txn.get("item");
        if (stored !== undefined) {
          return stored.group === item.group &&
            stored.joined_after === item.joined_after &&
            stored.welcome === item.welcome ? "retry" : "conflict";
        }
        await txn.put("item", item);
        await txn.setAlarm(Date.now() + MAILBOX_TTL_MS);
        return "created";
      });
      if (result === "conflict") return fail(409, "mailbox already holds an item");
      return json({ ok: true });
    }
    if (request.method === "GET") {
      const item = await this.state.storage.transaction(async (txn) => {
        if (await txn.get("consumed")) return undefined;
        return txn.get("item");
      });
      return item === undefined ? fail(404, "empty mailbox") : json(item);
    }
    if (request.method === "POST" && url.pathname.endsWith("/ack")) {
      await this.state.storage.transaction(async (txn) => {
        if ((await txn.get("item")) !== undefined) await txn.put("consumed", true);
      });
      return json({ ok: true });
    }
    if (request.method === "POST" && url.pathname.endsWith("/take")) {
      const item = await this.state.storage.transaction(async (txn) => {
        const stored = await txn.get("item");
        if (stored === undefined || await txn.get("consumed")) return undefined;
        // Keep opaque contents until the original expiry so an exact PUT
        // retry can succeed without recreating an already consumed welcome.
        await txn.put("consumed", true);
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

// The app on the web calls the relay from a browser, which enforces CORS.
// This policy is for explicit loopback development only. Random identifiers
// and ciphertext do not authorize public storage/bandwidth use. Production
// authentication and abuse controls must be implemented before public access.
const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, PUT, OPTIONS",
  "access-control-allow-headers": "content-type",
  "access-control-max-age": "86400",
};

async function route(request, env) {
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
}

export default {
  async fetch(request, env) {
    const hostname = new URL(request.url).hostname;
    if (env.LOCAL_DEVELOPMENT !== "true" ||
        !["127.0.0.1", "localhost", "[::1]"].includes(hostname)) {
      // Default deployment is closed, including preflight and WebSocket paths.
      // This is a development safety gate, not authentication. Do not infer
      // peer identity or authorization from Host/Origin headers.
      return fail(503, "public relay disabled: authentication and abuse controls required");
    }
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }
    const response = await route(request, env);
    if (response.webSocket) {
      // An upgrade response must reach the client untouched.
      return response;
    }
    const withCors = new Response(response.body, response);
    for (const [name, value] of Object.entries(CORS)) {
      withCors.headers.set(name, value);
    }
    return withCors;
  },
};
