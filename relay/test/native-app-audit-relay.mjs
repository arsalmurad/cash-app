// Owned loopback test fixture only. No seed/control route is exposed by HTTP.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { Miniflare } from 'miniflare';
import { auditAuthenticatedStorage } from './authenticated-storage-audit.js';

const root = fileURLToPath(new URL('./', import.meta.url));
const policy = JSON.parse(process.env.LOCAL_AUTH_POLICY);
const wrapper = `
  import worker, { AuthenticatedGroupLog } from './local-auth-worker.js';
  export class AuditGroup extends AuthenticatedGroupLog {
    constructor(state, env) { super(state, env); this.raw = state; }
    async fetch(request) {
      if (request.url === 'http://fixture-internal/inspect') {
        return Response.json([...await this.raw.storage.list()]);
      }
      return super.fetch(request);
    }
  }
  export default worker;`;
const mf = new Miniflare({ modulesRoot: root,
  modules: [{ type: 'ESModule', path: `${root}/native-fixture.js`, contents: wrapper },
    ...await Promise.all(['local-auth-worker', 'worker', 'request-proof', 'request-admission', 'request-scope', 'request-budget'].map(async name => ({
      type: 'ESModule', path: `${root}/${name}.js`,
      contents: await readFile(new URL(`../src/${name}.js`, import.meta.url), 'utf8'),
    })))],
  durableObjects: { GROUP: { className: 'AuditGroup', useSQLite: true } },
  bindings: { LOCAL_DEVELOPMENT: 'true', LOCAL_AUTH_POLICY: JSON.stringify(policy) },
  compatibilityDate: '2026-07-01', host: '127.0.0.1', port: Number(process.argv[2]),
});
await mf.ready;
console.log('local authenticated group relay listening (test-only storage fixture)');
const input = createInterface({ input: process.stdin });
let auditing = false;
input.on('line', async line => {
  if (!line.startsWith('audit:') || auditing) return;
  auditing = true;
  try {
    const manifest = JSON.parse(line.slice(6));
    assert(Array.isArray(manifest.needles) && manifest.needles.length > 0 && manifest.needles.length <= 64);
    assert(manifest.needles.every(needle => typeof needle === 'string' && needle.length >= 8 && needle.length <= 256));
    const namespace = await mf.getDurableObjectNamespace('GROUP');
    const rows = await (await namespace.get(namespace.idFromName(policy.scope.id))
      .fetch('http://fixture-internal/inspect')).json();
    const needles = [...manifest.needles, Buffer.from('cash-app durable receipt v2\0')];
    // Financial amounts must not appear as readable i64 fields either.
    // Do not scan tiny decimal substrings that also occur in public counters.
    for (const amount of [100n, -100n, 250n, -250n, 2050n, -2050n]) {
      const be = Buffer.alloc(8), le = Buffer.alloc(8);
      be.writeBigInt64BE(amount); le.writeBigInt64LE(amount);
      needles.push(be, le);
    }
    const entries = auditAuthenticatedStorage(rows, policy, needles);
    const poison = structuredClone(rows);
    poison.find(([key]) => key === 'e:000000000001')[1] = Buffer.from(needles[0]).toString('base64');
    assert.throws(() => auditAuthenticatedStorage(poison, policy, needles), /readable synthetic financial data/);
    const metadata = structuredClone(rows);
    metadata.find(([key]) => key === 'request_budget')[1].amount = 2050;
    assert.throws(() => auditAuthenticatedStorage(metadata, policy, needles));
    const roster = structuredClone(rows);
    roster.find(([key]) => key === 'authorized_devices')[1].devices[0].name = 'Private member';
    assert.throws(() => auditAuthenticatedStorage(roster, policy, needles));
    console.log(`AUDIT:${JSON.stringify({ entries, plaintextPoisonRejected: true, metadataPoisonRejected: true, rosterPoisonRejected: true })}`);
  } catch {
    console.log('AUDIT-FAIL: actual authenticated storage inspection failed');
  }
});
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => {
  input.close(); await mf.dispose(); process.exit(0);
});
