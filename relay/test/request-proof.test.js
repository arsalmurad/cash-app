import assert from "node:assert/strict";
import { test } from "node:test";
import { webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";
import { encodeRequestProofPayload, verifyRequestProof } from "../src/request-proof.js";

const now = 1_790_000_000_000;
const origin = "https://relay.example";
const path = "/g/0123456789abcdef0123456789abcdef/append";
const body = new TextEncoder().encode('{"expected_tail":1,"blob":"YQ=="}');
const hex = bytes => Buffer.from(bytes).toString("hex");

async function fixture() {
  const keys = await webcrypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const publicKey = hex(await webcrypto.subtle.exportKey("raw", keys.publicKey));
  const digest = hex(await webcrypto.subtle.digest("SHA-256", body));
  const fields = { origin, method: "POST", path, digest, publicKey,
    nonce: "ab".repeat(32), expires: now + 30_000 };
  const payload = encodeRequestProofPayload(fields);
  const signature = hex(await webcrypto.subtle.sign("Ed25519", keys.privateKey, payload));
  return { keys, fields, proof: { publicKey, nonce: fields.nonce, expires: fields.expires, signature } };
}

test("request proof binds exact origin, method, path/query, body and trusted device key", async () => {
  const { proof } = await fixture();
  const request = new Request(origin + path, { method: "POST" });
  assert.deepEqual(await verifyRequestProof(request, body, proof, proof.publicKey, now),
    { publicKey: proof.publicKey, nonce: proof.nonce, expires: proof.expires });
  for (const changed of [
    new Request("https://other.example" + path, { method: "POST" }),
    new Request(origin + path, { method: "PUT" }),
    new Request(origin + path + "?after=2", { method: "POST" }),
    new Request(origin + path.replace("append", "ws"), { method: "POST" }),
  ]) assert.equal(await verifyRequestProof(changed, body, proof, proof.publicKey, now), null);
  assert.equal(await verifyRequestProof(request, new Uint8Array([...body, 32]), proof, proof.publicKey, now), null);
  const other = await fixture();
  assert.equal(await verifyRequestProof(request, body, proof, other.proof.publicKey, now), null);
  assert.equal(await verifyRequestProof(request, body, proof, undefined, now), null);
});

test("request proof rejects expired, excessive-lived, malformed and tampered attestations", async () => {
  const { proof } = await fixture();
  const request = new Request(origin + path, { method: "POST" });
  for (const invalid of [
    null, {}, { ...proof, expires: now }, { ...proof, expires: now + 60_001 },
    { ...proof, expires: now + 0.5 }, { ...proof, expires: proof.expires + 1 },
    { ...proof, nonce: "ac".repeat(32) }, { ...proof, nonce: "ab" },
    { ...proof, nonce: proof.nonce.toUpperCase() },
    { ...proof, publicKey: "00".repeat(32) },
    { ...proof, signature: "00".repeat(64) },
    { ...proof, signature: "ff".repeat(65) },
    { ...proof, extra: "not part of the signed schema" },
    { ...proof, nonce: { toString: null } },
    { ...proof, signature: { toString: null } },
  ]) assert.equal(await verifyRequestProof(request, body, invalid, proof.publicKey, now), null);
  assert.equal(await verifyRequestProof(request, new Uint8Array(512 * 1024 + 1), proof, proof.publicKey, now), null);
});

test("proof verification alone intentionally does not authorize or deduplicate a request", async () => {
  const { proof } = await fixture();
  const request = new Request(origin + path, { method: "POST" });
  // The future caller owes trusted-roster lookup and atomic replay admission.
  assert.notEqual(await verifyRequestProof(request, body, proof, proof.publicKey, now), null);
  assert.notEqual(await verifyRequestProof(request, body, proof, proof.publicKey, now), null);
});

test("canonical request payload refuses ambiguous or noncanonical fields", async () => {
  const { fields } = await fixture();
  for (const invalid of [
    { ...fields, origin: origin + "/" },
    { ...fields, origin: "https://user@relay.example" },
    { ...fields, origin: "http://relay.example" },
    { ...fields, path: "//other.example/g/x" },
    { ...fields, path: path + "#fragment" },
    { ...fields, method: "post" },
    { ...fields, path: path + "\n" },
    { ...fields, digest: "00" },
  ]) assert.throws(() => encodeRequestProofPayload(invalid));
});

test("request payload uses the documented big-endian length-framed byte layout", async () => {
  const { fields } = await fixture();
  const parts = [Buffer.from(fields.origin), Buffer.from(fields.method), Buffer.from(fields.path),
    Buffer.from(fields.digest, "hex"), Buffer.from(fields.publicKey, "hex"), Buffer.from(fields.nonce, "hex")];
  const expected = Buffer.from("cash-app authenticated relay request v1\0").toString("hex") +
    parts.map(part => part.length.toString(16).padStart(16, "0") + part.toString("hex")).join("") +
    BigInt(fields.expires).toString(16).padStart(16, "0");
  assert.equal(hex(encodeRequestProofPayload(fields)), expected);
});

async function verifyInWorkerd(proof) {
  const root = fileURLToPath(new URL("./", import.meta.url));
  const mf = new Miniflare({
    modulesRoot: root,
    modules: [
      { type: "ESModule", path: `${root}/proof-fixture.js`, contents: `
        import { verifyRequestProof } from './request-proof.js';
        export default { async fetch(request, env) {
          const proof = JSON.parse(request.headers.get('x-test-proof'));
          const body = new Uint8Array(await request.arrayBuffer());
          const verified = await verifyRequestProof(request, body, proof, env.EXPECTED_KEY, ${now});
          return Response.json({verified}, {status: verified ? 200 : 401});
        }};` },
      { type: "ESModule", path: `${root}/request-proof.js`,
        contents: await readFile(new URL("../src/request-proof.js", import.meta.url), "utf8") },
    ],
    compatibilityDate: "2026-07-01", bindings: { EXPECTED_KEY: proof.publicKey },
  });
  try {
    await mf.ready;
    const init = { method: "POST", headers: { "x-test-proof": JSON.stringify(proof) }, body };
    assert.equal((await mf.dispatchFetch(origin + path, init)).status, 200);
    assert.equal((await mf.dispatchFetch(origin + path, { ...init, body: new Uint8Array([...body, 32]) })).status, 401);
  } finally { await mf.dispose(); }
}

test("actual workerd verifies the Node-signed request and rejects body substitution", async () => {
  await verifyInWorkerd((await fixture()).proof);
});

test("actual workerd verifies the Rust device identity signer", {
  skip: !process.env.RUST_RELAY_PROOF_FIXTURE,
}, async () => {
  const proof = JSON.parse(process.env.RUST_RELAY_PROOF_FIXTURE);
  await verifyInWorkerd(proof);
});
