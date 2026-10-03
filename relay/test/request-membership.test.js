import assert from 'node:assert/strict';
import { test } from 'node:test';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Miniflare } from 'miniflare';
import { encodeRequestProofPayload } from '../src/request-proof.js';

const now = 1790000000000;
const scope = { origin: 'http://127.0.0.1', kind: 'g', id: '01'.repeat(16) };
const identities = await Promise.all([0, 1].map(async () => {
  const keys = await webcrypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
  return { keys, key: Buffer.from(await webcrypto.subtle.exportKey('raw', keys.publicKey)).toString('hex') };
}));
const operations = ['append', 'membership', 'read'];
const policy = { version: 2, epoch: 0, scope, devices: [{ key: identities[0].key, operations }] };
let nonce = 0;
async function signed(proposal, identity = identities[0]) {
  const body = JSON.stringify(proposal);
  const proof = { publicKey: identity.key, nonce: (++nonce).toString(16).padStart(64, '0'), expires: now + 50000 };
  const payload = encodeRequestProofPayload({ origin: scope.origin, method: 'POST',
    path: `/g/${scope.id}/membership`, digest: Buffer.from(await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(body))).toString('hex'), ...proof });
  proof.signature = Buffer.from(await webcrypto.subtle.sign('Ed25519', identity.keys.privateKey, payload)).toString('hex');
  return { method: 'POST', headers: { 'x-proof': JSON.stringify(proof) }, body };
}

test('SQLite membership transition binds ciphertext, current grant, epoch and replay state atomically', async () => {
  const root = fileURLToPath(new URL('./', import.meta.url));
  // Only the in-memory fixture exposes inspect/seed/fault commands.
  const wrapper = `
    import { GroupLog } from './worker.js';
    import { verifyRequestProof } from './request-proof.js';
    import { applyMembershipTransition } from './request-membership.js';
    export class Fixture extends GroupLog {
      async fetch(request) {
        const command = request.headers.get('x-control');
        if (command === 'seed') { await this.state.storage.put(await request.json()); return Response.json({ok:true}); }
        if (command === 'inspect') return Response.json([...await this.state.storage.list()]);
        const bytes = new Uint8Array(await request.arrayBuffer());
        const proof = JSON.parse(request.headers.get('x-proof'));
        const current = await this.state.storage.get('authorized_devices');
        const device = current.devices.find(device => device.key === proof.publicKey);
        if (!device) return new Response(null, {status:403});
        const verified = await verifyRequestProof(request, bytes, proof, device.key, ${now});
        if (!verified) return new Response(null, {status:401});
        try {
          return await this.append(new Request(request.url, {method:'POST',body:bytes}), null, async txn => {
            const supplied = Uint8Array.from(bytes);
            if (command === 'swap') supplied[supplied.length - 1] ^= 1;
            await applyMembershipTransition(txn, verified, supplied, ${now});
            if (command === 'fault') throw new Error('controlled rollback');
          });
        } catch (error) { return new Response(null, {status:error.status ?? 503}); }
      }
    }
    export default {fetch(request, env) {return env.GROUP.get(env.GROUP.idFromName('fixture')).fetch(request);}};`;
  const mf = new Miniflare({ modulesRoot: root,
    modules: [{type:'ESModule', path:`${root}/fixture.js`, contents:wrapper},
      ...await Promise.all(['worker', 'request-proof', 'request-membership', 'request-scope', 'request-admission', 'request-budget'].map(async name => ({
        type:'ESModule', path:`${root}/${name}.js`, contents:await readFile(new URL(`../src/${name}.js`, import.meta.url), 'utf8'),
      })))], durableObjects: {GROUP:{className:'Fixture',useSQLite:true}}, compatibilityDate:'2026-07-01' });
  const url = `${scope.origin}/g/${scope.id}/membership`;
  const inspect = async () => (await mf.dispatchFetch(url, {headers:{'x-control':'inspect'}})).json();
  const seed = async rows => mf.dispatchFetch(url, {method:'POST',headers:{'x-control':'seed'},body:JSON.stringify(rows)});
  const next = { ...policy, epoch:1, devices:identities.map(identity => ({key:identity.key,operations})).sort((a,b) => a.key.localeCompare(b.key)) };
  const proposal = {expected_tail:0,blob:'AQ==',policy:next};
  try {
    await seed({authorized_devices:policy,request_budget:{version:1,day:Math.floor(now/86400000),used:0,devices:[]}});
    const before = await inspect();
    const request = await signed(proposal);
    assert.equal((await mf.dispatchFetch(url, {...request,headers:{...request.headers,'x-control':'swap'}})).status,401);
    assert.deepEqual(await inspect(),before,'even a verified caller cannot substitute unsigned proposal bytes');
    assert.equal((await mf.dispatchFetch(url, {...request,headers:{...request.headers,'x-control':'fault'}})).status,503);
    assert.deepEqual(await inspect(),before,'failure must roll back frame, policy, nonce, clock, budget and capacity');
    assert.equal((await mf.dispatchFetch(url,request)).status,200);
    let rows = Object.fromEntries(await inspect());
    assert.deepEqual(rows.authorized_devices,next); assert.equal(rows.tail,1);
    assert.equal(rows['e:000000000001'],'AQ=='); assert.equal(rows.request_budget.used,1);
    assert.equal(rows[`request_nonces:${identities[0].key}`].records.length,1);
    const committed = await inspect();
    assert.equal((await mf.dispatchFetch(url,request)).status,409);
    assert.deepEqual(await inspect(),committed);
    for (const bad of [
      {...next,epoch:0}, {...next,epoch:3}, {...next,scope:{...scope,id:'02'.repeat(16)}},
      {...next,epoch:2,amount:2050}, {...next,epoch:2,devices:[{key:identities[0].key,operations:['read']}]},
    ]) {
      const response = await mf.dispatchFetch(url,await signed({expected_tail:1,blob:'Ag==',policy:bad}));
      assert([400,409].includes(response.status)); assert.deepEqual(await inspect(),committed);
    }
    // An admitted member with no membership grant cannot change the policy.
    await seed({authorized_devices:{...next,devices:next.devices.map(device => ({...device,operations:device.key === identities[1].key ? ['read'] : operations}))}});
    const restricted = await inspect();
    assert.equal((await mf.dispatchFetch(url,await signed({expected_tail:1,blob:'Ag==',policy:{...next,epoch:2}},identities[1]))).status,403);
    assert.deepEqual(await inspect(),restricted);
    await seed({authorized_devices:next});
    const removed = {...next,epoch:2,devices:[{key:identities[1].key,operations}]};
    assert.equal((await mf.dispatchFetch(url,await signed({expected_tail:1,blob:'Ag==',policy:removed}))).status,200);
    const afterRemoval = await inspect();
    assert.equal((await mf.dispatchFetch(url,await signed({expected_tail:2,blob:'Aw==',policy:{...next,epoch:3}}))).status,403);
    assert.deepEqual(await inspect(),afterRemoval);
    rows = Object.fromEntries(afterRemoval);
    assert.equal(rows.request_budget.used,2);
    assert.equal(rows[`request_nonces:${identities[0].key}`].records.length,2,'revocation must not erase replay records');
  } finally {await mf.dispose();}
});
