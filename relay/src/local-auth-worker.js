// Experimental, explicit loopback-only entry point. Not used by Wrangler or
// the default dev server. One operator-configured namespace, no self-signup.
import { GroupLog } from "./worker.js";
import { verifyRequestProof, verifiedRequestContext } from "./request-proof.js";
import { admitVerifiedDeviceRequest } from "./request-admission.js";
import { validDevicePolicy, requestOperation } from "./request-scope.js";
import { emptyRequestBudget, spendRequestBudget, RequestBudgetRefused } from "./request-budget.js";

const fail = (status, message) => new Response(JSON.stringify({ error: message }), {
  status, headers: { "content-type": "application/json" } });
const loopback = url => ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
export function configuredPolicy(env, membership = false) {
  if (typeof env.LOCAL_AUTH_POLICY !== "string" || env.LOCAL_AUTH_POLICY.length > 32 * 1024) return null;
  try {
    const input = JSON.parse(env.LOCAL_AUTH_POLICY);
    if (!validDevicePolicy(input) || input.scope.kind !== "g" ||
        !loopback(new URL(input.scope.origin)) ||
        input.devices.some(device => device.operations.some(operation =>
          !(membership ? ["append", "membership", "read"] : ["append", "read"]).includes(operation)))) return null;
    // Persist only the documented, nonfinancial fields, never extra config.
    return { version: 2, epoch: input.epoch,
      scope: { origin: input.scope.origin, kind: "g", id: input.scope.id },
      devices: input.devices.map(device => ({ key: device.key, operations: [...device.operations] })) };
  } catch { return null; }
}
export async function boundedBody(request) {
  if (Number(request.headers.get("content-length")) > 512 * 1024) {
    await request.body?.cancel();
    return null;
  }
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 512 * 1024) { await reader.cancel(); return null; }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return bytes;
  } finally { reader.releaseLock(); }
}

export class AuthenticatedGroupLog extends GroupLog {
  constructor(state, env) { super(state); this.env = env; }
  async fetch(request) {
    try { return await this.authenticatedFetch(request); }
    catch (error) {
      if (!(error instanceof RequestBudgetRefused)) throw error;
      const response = fail(error.status, "local request budget refused; history preserved");
      if (error.retryAfter !== null) response.headers.set("retry-after", String(error.retryAfter));
      return response;
    }
  }
  async authenticatedFetch(request) {
    const url = new URL(request.url);
    if (this.env.LOCAL_DEVELOPMENT !== "true" || !loopback(url)) return fail(503, "public relay disabled");
    const policy = configuredPolicy(this.env);
    if (!policy) return fail(503, "trusted local policy required");
    const operation = requestOperation({ origin: url.origin, method: request.method,
      path: url.pathname, query: url.search }, policy.scope);
    if (!["append", "read"].includes(operation)) return fail(403, "route not authorized");
    const header = request.headers.get("x-cash-device-proof");
    let proof;
    try {
      if (!header || header.length > 1024) return fail(401, "device proof required");
      proof = JSON.parse(header);
    } catch { return fail(401, "invalid device proof"); }
    const device = policy.devices.find(device => device.key === proof?.publicKey);
    if (!device) return fail(401, "device proof refused");
    const body = await boundedBody(request);
    if (body === null) return fail(413, "request body exceeds size limit");
    const verified = await verifyRequestProof(request, body, proof, device.key, Date.now());
    if (!verified) return fail(401, "device proof refused");
    if (!device.operations.includes(requestOperation(verifiedRequestContext(verified), policy.scope))) {
      return fail(403, "operation not authorized");
    }
    const authorize = async txn => {
      const saved = await txn.get("authorized_devices");
      if (saved === undefined) {
        // Never turn an old unauthenticated log into a newly owned log.
        if ((await txn.list({ limit: 1 })).size !== 0) return 503;
        await txn.put("authorized_devices", policy);
        await txn.put("request_budget", emptyRequestBudget(Date.now()));
      } else if (JSON.stringify(saved) !== JSON.stringify(policy)) {
        // No silent policy replacement, downgrade or replay-clock reset.
        return 503;
      }
      const result = await admitVerifiedDeviceRequest(txn, verified, Date.now());
      if (result.ok) {
        // A refusal throws so policy, nonce, clock and mutation roll back too.
        // Use the admitted monotonic time, not a client's chosen proof TTL.
        await spendRequestBudget(txn, verified, await txn.get("request_clock"));
        return 0;
      }
      return result.reason === "replay" ? 409 : result.reason === "expired" ? 401 :
        result.reason === "capacity" ? 429 : 503;
    };
    if (operation === "read") return this.read(url, authorize);
    // Reconstruct from the exact verified bytes, never reserialize signed JSON.
    return this.append(new Request(request.url, { method: request.method,
      headers: request.headers, body }), authorize);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (env.LOCAL_DEVELOPMENT !== "true" || !loopback(url)) return fail(503, "public relay disabled");
    const policy = configuredPolicy(env);
    if (!policy) return fail(503, "trusted local policy required");
    const prefix = `/g/${policy.scope.id}`;
    if (url.origin !== policy.scope.origin ||
        !((request.method === "GET" && url.pathname === prefix) ||
          (request.method === "POST" && url.pathname === `${prefix}/append`) ||
          (request.method === "OPTIONS" && [prefix, `${prefix}/append`].includes(url.pathname)))) {
      return fail(403, "namespace or route not authorized");
    }
    const cors = { "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET, POST, OPTIONS",
      "access-control-allow-headers": "content-type, x-cash-device-proof" };
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    const response = await env.GROUP.get(env.GROUP.idFromName(policy.scope.id)).fetch(request);
    const result = new Response(response.body, response);
    for (const [name, value] of Object.entries(cors)) result.headers.set(name, value);
    return result;
  }
};
