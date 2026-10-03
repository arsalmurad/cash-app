// Exact namespace/action binding for verified requests. No routing or grants.
const ID = /^[0-9a-f]{32}$/;
const HEX32 = /^[0-9a-f]{64}$/;
const operations = { g: ["append", "membership", "prune", "read", "ws"],
  m: ["ack", "read", "take", "write"] };

export function validDevicePolicy(policy) {
  if (!policy || policy.version !== 2 || !Number.isSafeInteger(policy.epoch) || policy.epoch < 0 ||
      !policy.scope || typeof policy.scope.origin !== "string" || policy.scope.origin.length > 256 ||
      !["g", "m"].includes(policy.scope.kind) || typeof policy.scope.id !== "string" || !ID.test(policy.scope.id) ||
      !Array.isArray(policy.devices) || policy.devices.length === 0 || policy.devices.length > 64) return false;
  try {
    const origin = new URL(policy.scope.origin);
    if (origin.origin !== policy.scope.origin || !(origin.protocol === "https:" ||
        (origin.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(origin.hostname)))) return false;
  } catch { return false; }
  const allowed = operations[policy.scope.kind];
  return policy.devices.every((device, index) => device && typeof device.key === "string" && HEX32.test(device.key) &&
    (index === 0 || device.key > policy.devices[index - 1].key) &&
    Array.isArray(device.operations) && device.operations.length > 0 && device.operations.length <= allowed.length &&
    device.operations.every((operation, position) => typeof operation === "string" && allowed.includes(operation) &&
      (position === 0 || operation > device.operations[position - 1])));
}

export function requestOperation(context, scope) {
  if (!context || context.origin !== scope.origin) return null;
  const prefix = `/${scope.kind}/${scope.id}`;
  if (scope.kind === "g" && context.method === "GET" &&
      context.path === `${prefix}/policy` && !context.query) return "read";
  if (scope.kind === "g" && context.method === "GET" && context.path === prefix) {
    if (context.query) {
      const params = new URLSearchParams(context.query);
      const after = params.get("after");
      if ([...params].length !== 1 || typeof after !== "string" ||
          !/^(0|[1-9][0-9]*)$/.test(after) || !Number.isSafeInteger(Number(after))) return null;
    }
    return "read";
  }
  if (context.query) return null;
  if (scope.kind === "g") {
    const invitation = inviteRequest(context, scope);
    if (invitation) return invitation.action === 'put' ? 'membership' : 'read';
    if (context.method === "GET" && context.path === `${prefix}/ws`) return "ws";
    if (context.method === "POST") {
      for (const operation of ["append", "membership", "prune"]) {
        if (context.path === `${prefix}/${operation}`) return operation;
      }
    }
  } else {
    if (context.path === prefix && context.method === "GET") return "read";
    if (context.path === prefix && context.method === "PUT") return "write";
    if (context.method === "POST") {
      for (const operation of ["ack", "take"]) {
        if (context.path === `${prefix}/${operation}`) return operation;
      }
    }
  }
  return null;
}

// Group-scoped, proof-bound routes; there is no consume-before-save operation.
export function inviteRequest(context, scope) {
  if (!context || scope.kind !== 'g' || context.origin !== scope.origin || context.query) return null;
  const prefix = `/g/${scope.id}/invite/`;
  if (!context.path.startsWith(prefix)) return null;
  const remainder = context.path.slice(prefix.length);
  const [id, suffix, ...extra] = remainder.split('/');
  if (typeof id !== 'string' || id.length !== 32 || !ID.test(id) || extra.length) return null;
  if (suffix === undefined && context.method === 'PUT') return {id,action:'put'};
  if (suffix === undefined && context.method === 'GET') return {id,action:'get'};
  if (suffix === 'ack' && context.method === 'POST') return {id,action:'ack'};
  return null;
}
