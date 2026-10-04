import assert from 'node:assert/strict';
import { test } from 'node:test';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Miniflare } from 'miniflare';
import { encodeRequestProofPayload } from '../src/request-proof.js';

const origin = 'http://127.0.0.1';
const group = '15'.repeat(16), prefix = `/g/${group}`, wsPath = `${prefix}/ws`;
const identities = await Promise.all([0, 1, 2].map(async () => {
  const keys = await webcrypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
  return { keys, key: Buffer.from(await webcrypto.subtle.exportKey('raw', keys.publicKey)).toString('hex') };
}));
const [alice, bob, stranger] = identities;
const root = { version: 2, epoch: 0, scope: { origin, kind: 'g', id: group },
  devices: [{ key: alice.key, operations: ['append', 'membership', 'read'] },
    { key: bob.key, operations: ['read'] }].sort((a, b) => a.key.localeCompare(b.key)) };
let nonce = 0;
async function signed(path = wsPath, method = 'GET', body, actor = alice, expires = Date.now() + 50000, targetOrigin = origin) {
  const text = body === undefined ? '' : JSON.stringify(body);
  const proof = { publicKey: actor.key, nonce: (++nonce).toString(16).padStart(64, '0'), expires };
  const payload = encodeRequestProofPayload({ origin: targetOrigin, method, path,
    digest: Buffer.from(await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(text))).toString('hex'), ...proof });
  proof.signature = Buffer.from(await webcrypto.subtle.sign('Ed25519', actor.keys.privateKey, payload)).toString('hex');
  return { method, headers: { 'x-cash-device-proof': JSON.stringify(proof) }, ...(text ? { body: text } : {}) };
}
const upgrade = init => ({ ...init, headers: { ...init.headers, upgrade: 'websocket' } });
const protocol = init => 'cash-request.' + Buffer.from(init.headers['x-cash-device-proof']).toString('base64url');
async function eventually(predicate, diagnostic = () => undefined, attempts = 100) {
  for (let i = 0; i < attempts; i++) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.fail('Expected bounded socket observation did not arrive: ' + JSON.stringify(await diagnostic()));
}

async function fixture(enabled = true) {
  const reserve = createServer();
  reserve.listen(0, '127.0.0.1');
  await once(reserve, 'listening');
  const port = reserve.address().port;
  await new Promise(resolve => reserve.close(resolve));
  const liveOrigin = `http://127.0.0.1:${port}`;
  const liveRoot = {...root, scope: {...root.scope, origin: liveOrigin}};
  const moduleRoot = fileURLToPath(new URL('./', import.meta.url));
  const wrapper = `import worker, {RosterGroupLog} from './roster-worker.js';
    export class Fixture extends RosterGroupLog {
      async fetch(request) {
        if(request.headers.get('x-test')==='seed') {await this.state.storage.put(await request.json());return Response.json({ok:true});}
        if(request.headers.get('x-test')==='inspect') return Response.json({
          rows:[...await this.state.storage.list()],
          connections:this.state.getWebSockets().length,
          attachments:this.state.getWebSockets().filter(socket=>socket.readyState===1).map(socket=>socket.deserializeAttachment())});
        if(request.headers.get('x-test')==='recreate') return new RosterGroupLog(this.state,this.env).fetch(request);
        return super.fetch(request);
      }
    }
    export default worker;`;
  const names = ['roster-worker','roster-welcome','local-auth-worker','worker','request-proof',
    'request-membership','invite-authority','retired-readers','request-scope','request-admission','prefix-consent','request-budget'];
  const options = { modulesRoot: moduleRoot,
    modules: [{ type: 'ESModule', path: `${moduleRoot}/socket-fixture.js`, contents: wrapper },
      ...await Promise.all(names.map(async name => ({ type: 'ESModule', path: `${moduleRoot}/${name}.js`,
        contents: await readFile(new URL(`../src/${name}.js`, import.meta.url), 'utf8') })))],
    durableObjects: { GROUP: { className: 'Fixture', useSQLite: true } },
    bindings: { LOCAL_DEVELOPMENT: 'true', LOCAL_AUTH_MEMBERSHIP: 'true',
      LOCAL_AUTH_POLICY: JSON.stringify(liveRoot), ...(enabled ? { LOCAL_AUTH_SOCKETS: 'true' } : {}) },
    host: '127.0.0.1', port, compatibilityDate: '2026-07-01' };
  const mf = new Miniflare(options);
  await mf.ready;
  return { mf, origin: liveOrigin, root: liveRoot,
    trust: async devices => {
      // Test operator configuration, never a production signup/proof grant.
      await mf.setOptions({...options,bindings:{...options.bindings,
        LOCAL_AUTH_POLICY:JSON.stringify({...liveRoot,devices})}});
      await mf.ready;
    },
    signed: (path = wsPath, method = 'GET', body, actor = alice, expires = Date.now() + 50000) =>
      signed(path, method, body, actor, expires, liveOrigin),
    call: (path, init) => mf.dispatchFetch(liveOrigin + path, init),
    inspect: async () => (await mf.dispatchFetch(liveOrigin + prefix, { headers: { 'x-test': 'inspect' } })).json() };
}

test('authenticated notifications are explicit, proof-bound and survive instance reconstruction', async () => {
  const f = await fixture();
  const clients = [];
  const observe = socket => {
    const observed = { socket, messages: [], closed: null };
    socket.addEventListener('message', event => observed.messages.push(JSON.parse(event.data)));
    socket.addEventListener('close', event => { observed.closed = event.code; });
    clients.push(observed);
    return observed;
  };
  const accept = response => {
    assert.equal(response.status, 101);
    response.webSocket.accept();
    return observe(response.webSocket);
  };
  async function openRealSocket(proof) {
    const subprotocol = protocol(proof);
    const observed = observe(new WebSocket(f.origin.replace('http:', 'ws:') + wsPath, subprotocol));
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Owned TCP socket did not open')), 5000);
      observed.socket.addEventListener('open', () => {clearTimeout(timer);resolve();}, {once:true});
      observed.socket.addEventListener('error', () => {clearTimeout(timer);reject(new Error('Owned TCP socket failed'));}, {once:true});
    });
    assert.equal(observed.socket.protocol, subprotocol, 'Actual client must receive the selected proof subprotocol');
    return observed;
  }
  try {
    const before = await f.inspect();
    assert.equal((await f.mf.dispatchFetch('https://relay.example'+wsPath,upgrade(await f.signed()))).status,503,
      'Socket opt-in must never authorize public routing');
    assert.equal((await f.call(wsPath, { headers: { upgrade: 'websocket' } })).status, 401);
    assert.equal((await f.call(wsPath,upgrade(await f.signed(wsPath,'GET',undefined,alice,Date.now()-1)))).status,401);
    assert.equal((await f.call(wsPath, upgrade(await f.signed(wsPath, 'GET', undefined, stranger)))).status, 401);
    assert.equal((await f.call(wsPath + '?after=0', upgrade(await f.signed(wsPath + '?after=0')))).status, 403);
    assert.deepEqual(await f.inspect(), before, 'Unauthenticated requests must not acquire bootstrap or consume quotas');
    const nativeProof = await f.signed();
    assert.equal((await f.call(wsPath, nativeProof)).status, 426);
    assert.deepEqual(await f.inspect(), before, 'Missing upgrade must not spend the proof');
    const native = accept(await f.call(wsPath, upgrade(nativeProof)));
    assert.equal((await f.call(wsPath, upgrade(nativeProof))).status, 409, 'Signed upgrade is one-use');
    const browserProof = await f.signed();
    const browserProtocol = protocol(browserProof);
    const browserReply = await f.call(wsPath, { headers: { upgrade: 'websocket', 'sec-websocket-protocol': browserProtocol } });
    assert.equal(browserReply.headers.get('sec-websocket-protocol'), browserProtocol);
    const browser = accept(browserReply);
    const full = await f.inspect();
    assert.equal(Object.fromEntries(full.rows).request_budget.used, 2);
    assert.deepEqual(full.attachments, [0, 1].map(() => ({ version: 1, publicKey: alice.key, origin:f.origin, group })));
    const cappedProof = await f.signed();
    assert.equal((await f.call(wsPath, upgrade(cappedProof))).status, 429, 'Two connections per trusted device');
    assert.deepEqual(await f.inspect(), full, 'Connection-cap refusal must not spend nonce or budget');
    const conflicting = upgrade(await f.signed());
    conflicting.headers['sec-websocket-protocol'] = browserProtocol;
    assert.equal((await f.call(wsPath, conflicting)).status, 401);
    for (const invalid of [browserProtocol + '=', browserProtocol + ',other', 'other', 'cash-request.' + 'a'.repeat(1024)]) {
      // Send invalid carriers as ordinary HTTP: the Node WS client itself
      // rejects invalid protocol tokens before a request can reach workerd.
      assert.equal((await f.call(wsPath, { headers: { 'sec-websocket-protocol': invalid } })).status, 401);
    }
    const wrongScope = await f.signed(prefix);
    assert.equal((await f.call(wsPath, upgrade(wrongScope))).status, 401, 'Signature cannot move from history to a socket');
    assert.deepEqual(await f.inspect(), full);
    const append = await f.signed(prefix + '/append', 'POST', { expected_tail: 0, blob: 'AQ==' });
    append.headers['x-test'] = 'recreate';
    assert.equal((await f.call(prefix + '/append', append)).status, 200);
    await eventually(() => native.messages.length === 1 && browser.messages.length === 1);
    assert.deepEqual(native.messages, [{ tail: 1 }]);
    assert.deepEqual(browser.messages, [{ tail: 1 }]);
    browser.socket.close();
    await eventually(async () => (await f.inspect()).attachments.length === 1);
    const replacement = await openRealSocket(cappedProof); // Refused nonce is reusable.
    const peer = await openRealSocket(await f.signed(wsPath, 'GET', undefined, bob));
    const next = { ...f.root, epoch: 1, devices: [f.root.devices.find(device => device.key === alice.key)] };
    const removal = await f.signed(prefix + '/membership', 'POST', { expected_tail: 1, blob: 'Ag==', policy: next });
    assert.equal((await f.call(prefix + '/membership', removal)).status, 200);
    await eventually(() => peer.closed !== null && native.messages.length === 2,
      async () => ({peer:{closed:peer.closed,state:peer.socket.readyState,messages:peer.messages},
        native:{closed:native.closed,state:native.socket.readyState,messages:native.messages},
        openAttachments:(await f.inspect()).attachments.length}), 2000);
    assert.equal(peer.closed, 1008);
    assert.deepEqual(peer.messages, [], 'Removed device must not receive its removal tail or later notifications');
    assert.deepEqual(native.messages, [{ tail: 1 }, { tail: 2 }]);
    assert.equal((await f.call(wsPath, upgrade(await f.signed(wsPath, 'GET', undefined, bob)))).status, 401,
      'Retired history permission must not grant a new live subscription');
    const confirmed = (await f.inspect()).rows;
    replacement.socket.send(JSON.stringify({ amount: 987654, title: 'plaintext negative control' }));
    await eventually(() => replacement.closed !== null, () => ({state:replacement.socket.readyState}), 2000);
    assert.equal(replacement.closed, 1008);
    assert.deepEqual((await f.inspect()).rows, confirmed, 'Incoming payload must never be stored or treated as a financial command');
    assert(!JSON.stringify(confirmed).includes('plaintext negative control'));
  } finally {
    for (const client of clients) {
      if (client.socket.readyState === 1) try {client.socket.close();} catch {}
    }
    await f.mf.dispose();
  }
});

test('sockets remain closed without explicit opt-in', async () => {
  const f = await fixture(false);
  try {
    assert.equal((await f.call(wsPath, upgrade(await f.signed()))).status, 403);
    assert.deepEqual(await f.inspect(), { rows: [], connections:0, attachments: [] });
  } finally { await f.mf.dispose(); }
});

test('socket budget and read-grant refusals roll back and preserve existing listeners', async () => {
  const f = await fixture();
  let socket;
  try {
    const response = await f.call(wsPath,upgrade(await f.signed()));
    assert.equal(response.status,101);
    socket = response.webSocket;
    socket.accept();
    const messages=[];
    socket.addEventListener('message',event=>messages.push(JSON.parse(event.data)));
    const baseline=await f.inspect();
    const budget=Object.fromEntries(baseline.rows).request_budget;
    const full={...budget,used:20000,devices:[alice,bob].map(actor=>({key:actor.key,used:10000})).sort((a,b)=>a.key.localeCompare(b.key))};
    const seed=values=>f.call(prefix+'/append',{method:'POST',headers:{'x-test':'seed'},body:JSON.stringify(values)});
    assert.equal((await seed({request_budget:full})).status,200);
    const before=await f.inspect();
    const retry=await f.signed(wsPath,'GET',undefined,bob);
    const refusal=await f.call(wsPath,upgrade(retry));
    assert.equal(refusal.status,429);
    assert(Number(refusal.headers.get('retry-after'))>0);
    assert.deepEqual(await f.inspect(),before,'Quota refusal must not consume nonce, alter clock or accept a socket');
    assert.equal((await seed({request_budget:budget})).status,200);
    const append=await f.signed(prefix+'/append','POST',{expected_tail:0,blob:'AQ=='});
    assert.equal((await f.call(prefix+'/append',append)).status,200);
    await eventually(()=>messages.length===1);
    assert.deepEqual(messages,[{tail:1}],'Expected refusal inside the input gate must not terminate existing listeners');
    const next={...f.root,epoch:1,devices:f.root.devices.map(device=>device.key===alice.key?
      {...device,operations:['append','membership']}:device)};
    const revokeRead=await f.signed(prefix+'/membership','POST',{expected_tail:1,blob:'Ag==',policy:next});
    assert.equal((await f.call(prefix+'/membership',revokeRead)).status,200);
    const revoked=await f.inspect();
    assert.equal(revoked.attachments.length,0,'Read-grant revocation must close the old active subscription even when identity remains');
    assert.equal((await f.call(wsPath,upgrade(await f.signed()))).status,403);
    assert.deepEqual(await f.inspect(),revoked,'Read-grant refusal must roll back nonce and budget');
    assert.deepEqual(messages,[{tail:1}],'Revoked reader must not receive the policy-change tail');
  } finally {
    if(socket?.readyState===1) try {socket.close();} catch {}
    await f.mf.dispose();
  }
});

test('actual maximum roster fills the global socket ceiling without spending refused proofs', async () => {
  const f=await fixture();
  const sockets=[];
  try {
    const actors=[alice,bob];
    for(let i=0;i<62;i++) {
      const keys=await webcrypto.subtle.generateKey('Ed25519',true,['sign','verify']);
      actors.push({keys,key:Buffer.from(await webcrypto.subtle.exportKey('raw',keys.publicKey)).toString('hex')});
    }
    await f.trust(actors.map(actor=>({key:actor.key,operations:['append','membership','read']}))
      .sort((a,b)=>a.key.localeCompare(b.key)));
    for(const actor of actors) for(let i=0;i<2;i++) {
      const reply=await f.call(wsPath,upgrade(await f.signed(wsPath,'GET',undefined,actor)));
      assert.equal(reply.status,101);
      reply.webSocket.accept();sockets.push(reply.webSocket);
    }
    const full=await f.inspect();
    assert.equal(full.connections,128);
    assert.equal(full.attachments.length,128);
    assert.equal(Object.fromEntries(full.rows).request_budget.used,128);
    assert.equal((await f.call(wsPath,upgrade(await f.signed()))).status,429);
    assert.deepEqual(await f.inspect(),full,'Global-cap refusal must not consume an admitted nonce or budget');
  } finally {
    for(const socket of sockets) if(socket.readyState===1) try {socket.close();} catch {}
    await f.mf.dispose();
  }
});

test('Rust opaque identities authenticate native and real network notification handshakes',
  {skip:process.env.RUST_NOTIFICATION_INTEROP!=='1'}, async () => {
    const f=await fixture();
    const clients=[];
    try {
      const run=promisify(execFile);
      const repo=fileURLToPath(new URL('../../',import.meta.url));
      const proofs=[];
      for(let i=0;i<2;i++) {
        // The interoperability runner builds examples before this test starts,
        // so no cold compilation can consume the short proof lifetime.
        const result=await run(process.env.CARGO??'cargo',[
          'run','--manifest-path','rust/Cargo.toml','--locked','--offline','--quiet',
          '-p','cash_crypto','--features','relay-auth','--example','relay_request_proof',
          '--','local-notification',f.origin],{cwd:repo,windowsHide:true,timeout:20000,maxBuffer:4096});
        const proof=JSON.parse(result.stdout);
        assert.deepEqual(Object.keys(proof).sort(),['expires','nonce','publicKey','signature']);
        assert(!result.stdout.includes('Synthetic private label'));
        proofs.push(proof);
      }
      await f.trust(proofs.map(proof=>({key:proof.publicKey,operations:['append','membership','read']}))
        .sort((a,b)=>a.key.localeCompare(b.key)));
      const native={headers:{'x-cash-device-proof':JSON.stringify(proofs[0])}};
      const response=await f.call(wsPath,upgrade(native));
      assert.equal(response.status,101);
      response.webSocket.accept();clients.push(response.webSocket);
      assert.equal((await f.call(wsPath,upgrade(native))).status,409);
      const selected=protocol({headers:{'x-cash-device-proof':JSON.stringify(proofs[1])}});
      const browser=new WebSocket(f.origin.replace('http:','ws:')+wsPath,selected);
      clients.push(browser);
      await new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>reject(new Error('Rust-signed network socket did not open')),5000);
        browser.addEventListener('open',()=>{clearTimeout(timer);resolve();},{once:true});
        browser.addEventListener('error',()=>{clearTimeout(timer);reject(new Error('Rust-signed network socket failed'));},{once:true});
      });
      assert.equal(browser.protocol,selected);
      const confirmed=await f.inspect();
      assert.equal(Object.fromEntries(confirmed.rows).request_budget.used,2);
      assert.deepEqual(confirmed.attachments.map(value=>value.publicKey).sort(),proofs.map(value=>value.publicKey).sort());
      assert.equal(Object.keys(Object.fromEntries(confirmed.rows)).filter(key=>key.startsWith('e:')).length,0,
        'Notification handshakes must not append financial/ciphertext events');
    } finally {
      for(const socket of clients) if(socket.readyState===1) try {socket.close();} catch {}
      await f.mf.dispose();
    }
  });
