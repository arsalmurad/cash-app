// Verification primitive only. Not imported by the production worker yet.
// A valid signature is not roster authorization, replay admission or a quota.
const HEX32 = /^[0-9a-f]{64}$/;
const HEX64 = /^[0-9a-f]{128}$/;
const utf8 = new TextEncoder();
const domain = utf8.encode("cash-app authenticated relay request v1\0");
const schema = ["expires", "nonce", "publicKey", "signature"];
const verifiedProofs = new WeakMap();

// Identity-local, frozen verifier output cannot be fabricated from JSON.
export const isVerifiedRequestProof = proof => verifiedProofs.has(proof);
export const verifiedRequestContext = proof => verifiedProofs.get(proof) ?? null;

function bytes(hex) {
  return Uint8Array.from(hex.match(/../g), value => Number.parseInt(value, 16));
}

function hex(bytes) {
  return Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, "0")).join("");
}

export function encodeRequestProofPayload({ origin, method, path, digest, publicKey, nonce, expires }) {
  if (typeof origin !== "string" || origin.length > 256 ||
      typeof path !== "string" || path.length > 1024 || !path.startsWith("/") ||
      !["GET", "POST", "PUT"].includes(method) ||
      typeof digest !== "string" || typeof publicKey !== "string" || typeof nonce !== "string" ||
      !HEX32.test(digest) || !HEX32.test(publicKey) || !HEX32.test(nonce) ||
      !Number.isSafeInteger(expires) || expires < 0) {
    throw new TypeError("invalid request proof fields");
  }
  const base = new URL(origin);
  const url = new URL(path, origin);
  if (base.origin !== origin || url.origin !== origin ||
      url.pathname + url.search !== path || url.hash ||
      !(base.protocol === "https:" || (base.protocol === "http:" &&
        ["127.0.0.1", "localhost", "[::1]"].includes(base.hostname)))) {
    throw new TypeError("noncanonical request proof URL");
  }
  const fields = [utf8.encode(origin), utf8.encode(method), utf8.encode(path),
    bytes(digest), bytes(publicKey), bytes(nonce)];
  const payload = new Uint8Array(domain.length + 8 + fields.reduce((sum, field) => sum + 8 + field.length, 0));
  payload.set(domain);
  const view = new DataView(payload.buffer);
  let offset = domain.length;
  for (const field of fields) {
    view.setBigUint64(offset, BigInt(field.length), false);
    offset += 8;
    payload.set(field, offset);
    offset += field.length;
  }
  view.setBigUint64(offset, BigInt(expires), false);
  return payload;
}

/** expectedKey must come from an independently authorized current device roster.
 * The caller must atomically check/admit nonce, scope and quotas before mutation.
 * Return null on all untrusted failures; never echo keys, bodies or exceptions.
 */
export async function verifyRequestProof(request, body, proof, expectedKey, now) {
  if (!(body instanceof Uint8Array) || body.length > 512 * 1024 ||
      !proof || typeof proof !== "object" || Array.isArray(proof) ||
      JSON.stringify(Object.keys(proof).sort()) !== JSON.stringify(schema) ||
      typeof expectedKey !== "string" || !HEX32.test(expectedKey) ||
      proof.publicKey !== expectedKey || typeof proof.nonce !== "string" || !HEX32.test(proof.nonce) ||
      typeof proof.signature !== "string" || !HEX64.test(proof.signature) || !Number.isSafeInteger(now) || now < 0 ||
      !Number.isSafeInteger(proof.expires) || proof.expires <= now ||
      proof.expires - now > 60_000) return null;
  try {
    const url = new URL(request.url);
    const digest = hex(await crypto.subtle.digest("SHA-256", body));
    const payload = encodeRequestProofPayload({ origin: url.origin,
      method: request.method, path: url.pathname + url.search,
      digest, publicKey: expectedKey, nonce: proof.nonce, expires: proof.expires });
    const key = await crypto.subtle.importKey("raw", bytes(expectedKey), "Ed25519", false, ["verify"]);
    if (!await crypto.subtle.verify("Ed25519", key, bytes(proof.signature), payload)) return null;
    const verified = Object.freeze({ publicKey: expectedKey, nonce: proof.nonce, expires: proof.expires });
    verifiedProofs.set(verified, Object.freeze({ origin: url.origin,
      method: request.method, path: url.pathname, query: url.search }));
    return verified;
  } catch {
    return null;
  }
}
