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
      ...await Promise.all(['worker', 'request-proof', 'request-membership', 'invite-authority', 'retired-readers', 'request-scope', 'request-admission', 'prefix-consent', 'request-budget'].map(async name => ({
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
    assert.deepEqual(rows.invite_authorities,{version:1,records:[{
      key:identities[1].key,sponsor:identities[0].key,sequence:1,expires:now+7*86400000,mailbox:null,
    }]},'only newly added public keys acquire delivery authority from the accepted slot');
    const committed = await inspect();
    const authority=rows.invite_authorities;
    for (const damaged of [{version:1,records:[{...authority.records[0],name:'private'}]},
        {version:1,records:Array(65).fill(authority.records[0])}]) {
      await seed({invite_authorities:damaged});
      const before=await inspect();
      const proposal={expected_tail:1,blob:'Ag==',policy:{...next,epoch:2}};
      assert.equal((await mf.dispatchFetch(url,await signed(proposal))).status,503);
      assert.deepEqual(await inspect(),before,'invalid invitation authority rolls back ciphertext, nonce and budget too');
    }
    await seed({invite_authorities:authority});
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
    const removalRequest=await signed({expected_tail:1,blob:'Ag==',policy:removed});
    const beforeRetirement=await inspect();
    assert.equal((await mf.dispatchFetch(url,{...removalRequest,headers:{...removalRequest.headers,'x-control':'fault'}})).status,503);
    assert.deepEqual(await inspect(),beforeRetirement,'post-retirement fault rolls back cutoff together with removal, nonce, budget and policy');
    assert.equal((await mf.dispatchFetch(url,removalRequest)).status,200);
    const afterRemoval = await inspect();
    assert.equal((await mf.dispatchFetch(url,await signed({expected_tail:2,blob:'Aw==',policy:{...next,epoch:3}}))).status,403);
    assert.deepEqual(await inspect(),afterRemoval);
    rows = Object.fromEntries(afterRemoval);
    assert.equal(rows.request_budget.used,2);
    assert.equal(rows[`request_nonces:${identities[0].key}`].records.length,2,'revocation must not erase replay records');
    // 128 retained keys is a hard inventory bound, not permission to evict a
    // recently removed device's replay records when adding another key.
    const retired = Array.from({length:126}, (_, index) => `ff${index.toString(16).padStart(62,'0')}`);
    await seed(Object.fromEntries(retired.map(key => [`request_nonces:${key}`, {
      version:1,records:[{nonce:'01'.repeat(32),expires:now+10000}],
    }])));
    // Account for the current device even if it has not issued a request yet.
    await seed({[`request_nonces:${identities[1].key}`]:{version:1,records:[]}});
    const full = await inspect();
    const added = {...removed,epoch:3,devices:[
      ...removed.devices,{key:'fe'.repeat(32),operations},
    ].sort((a,b) => a.key.localeCompare(b.key))};
    const churnRequest = await signed({expected_tail:2,blob:'Aw==',policy:added},identities[1]);
    assert.equal((await mf.dispatchFetch(url,churnRequest)).status,429);
    assert.deepEqual(await inspect(),full,'live-key capacity refusal must roll back all writes');
    // Server's admitted monotonic floor, not a rolled-back wall clock, decides
    // expiry. The retired rows still expire in the future relative to `now`.
    await seed({request_clock:now+10001});
    const beforeCleanup = await inspect();
    assert.equal((await mf.dispatchFetch(url,{...churnRequest,headers:{...churnRequest.headers,'x-control':'fault'}})).status,503);
    assert.deepEqual(await inspect(),beforeCleanup,'failed commit must also roll back expired-key deletion');
    assert.equal((await mf.dispatchFetch(url,churnRequest)).status,200,'refused nonce remains retryable once retired records expire');
    rows = Object.fromEntries(await inspect());
    assert(retired.every(key => !(`request_nonces:${key}` in rows)));
    assert.equal(rows[`request_nonces:${identities[0].key}`].records.length,2,'unexpired revoked replay records must remain');
    assert.equal(rows.request_budget.used,3,'membership churn must not reset spending');
    const fourth = await signed({expected_tail:3,blob:'BA==',policy:{...added,epoch:4}},identities[1]);
    const corruptKey = `request_nonces:${'fc'.repeat(32)}`;
    await seed({[corruptKey]:{version:1,records:[{nonce:'01'.repeat(32),expires:-1}]}});
    const corrupt = await inspect();
    assert.equal((await mf.dispatchFetch(url,fourth)).status,503);
    assert.deepEqual(await inspect(),corrupt,'corrupt retired state must not be silently discarded');
    await seed({[corruptKey]:{version:1,records:[]}});
    await seed(Object.fromEntries(Array.from({length:128}, (_, index) => [
      `request_nonces:fd${index.toString(16).padStart(62,'0')}`,{version:1,records:[]},
    ])));
    const oversized = await inspect();
    assert.equal((await mf.dispatchFetch(url,fourth)).status,503);
    assert.deepEqual(await inspect(),oversized,'oversized legacy inventory needs explicit migration, not an unbounded scan');
  } finally {await mf.dispose();}
});
