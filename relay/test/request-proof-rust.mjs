// Synthetic interoperability only: no user keys, public deployment or account.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
const relay = fileURLToPath(new URL("../", import.meta.url));
async function run(command, args, cwd, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env, windowsHide: true });
    let stdout = "", stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => resolve({ code, stdout, stderr }));
  });
}

async function fixtureProof(extra = []) {
  const fixture = await run(process.env.CARGO ?? "cargo", [
    "run", "--manifest-path", "rust/Cargo.toml", "--locked", "--offline", "--quiet",
    "-p", "cash_crypto", "--features", "relay-auth", "--example", "relay_request_proof",
    ...extra,
  ], root, process.env);
  assert.equal(fixture.code, 0, `Rust proof fixture failed: ${fixture.stderr.slice(-2400)}`);
  assert(fixture.stdout.length < 4096, "Synthetic proof output must be bounded");
  const proof = JSON.parse(fixture.stdout);
  assert.deepEqual(Object.keys(proof).sort(), ["expires", "nonce", "publicKey", "signature"]);
  return proof;
}
const proof = await fixtureProof();
const localProof = await fixtureProof(["--", "local-group"]);
const verified = await run(process.execPath, ["--test", "test/request-proof.test.js", "test/local-auth.test.js"], relay,
  { ...process.env, RUST_RELAY_PROOF_FIXTURE: JSON.stringify(proof), RUST_LOCAL_GROUP_PROOF_FIXTURE: JSON.stringify(localProof) });
assert.equal(verified.code, 0, `workerd proof interoperability failed: ${verified.stderr.slice(-2400)}\n${verified.stdout.slice(-2400)}`);
process.stdout.write(verified.stdout);
