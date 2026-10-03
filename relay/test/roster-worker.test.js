import assert from 'node:assert/strict';
import { test } from 'node:test';
import { webcrypto } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { Miniflare } from 'miniflare';
import { encodeRequestProofPayload } from '../src/request-proof.js';
import rosterWorker from '../src/roster-worker.js';

const scope = {origin:'http://127.0.0.1',kind:'g',id:'02'.repeat(16)};
const operations = ['append','membership','read'];
const devices = await Promise.all([0,1].map(async () => {
  const keys = await webcrypto.subtle.generateKey('Ed25519',true,['sign','verify']);
  return {keys,key:Buffer.from(await webcrypto.subtle.exportKey('raw',keys.publicKey)).toString('hex')};
}));
const root = {version:2,epoch:0,scope,devices:[{key:devices[0].key,operations}]};
let nonce = 0;
async function signed(path,method='GET',value,device=devices[0],origin=scope.origin) {
  const body = value === undefined ? '' : JSON.stringify(value);
  const proof = {publicKey:device.key,nonce:(++nonce).toString(16).padStart(64,'0'),expires:Date.now()+50000};
  const payload = encodeRequestProofPayload({origin,method,path,
    digest:Buffer.from(await webcrypto.subtle.digest('SHA-256',new TextEncoder().encode(body))).toString('hex'),...proof});
  proof.signature = Buffer.from(await webcrypto.subtle.sign('Ed25519',device.keys.privateKey,payload)).toString('hex');
  return {method,headers:{'x-cash-device-proof':JSON.stringify(proof)},...(body ? {body}: {})};
}

test('explicit roster worker bootstraps trusted empty storage and enforces live grants atomically',async () => {
  const moduleRoot = fileURLToPath(new URL('./',import.meta.url));
  const wrapper = `
    import worker, { RosterGroupLog } from './roster-worker.js';
    export class Fixture extends RosterGroupLog {
      async fetch(request) {
        if (request.headers.get('x-test') === 'inspect') return Response.json([...await this.state.storage.list()]);
        if (request.headers.get('x-test') === 'seed') {await this.state.storage.put(await request.json());return Response.json({ok:true});}
        const previous = this.env.LOCAL_AUTH_POLICY;
        if (request.headers.has('x-test-root')) this.env.LOCAL_AUTH_POLICY=request.headers.get('x-test-root');
        try {return await super.fetch(request);} finally {this.env.LOCAL_AUTH_POLICY=previous;}
      }
    }
    export default worker;`;
  const mf = new Miniflare({modulesRoot:moduleRoot,
    modules:[{type:'ESModule',path:`${moduleRoot}/fixture.js`,contents:wrapper},
      ...await Promise.all(['roster-worker','local-auth-worker','worker','request-proof','request-membership','request-scope','request-admission','request-budget'].map(async name => ({
        type:'ESModule',path:`${moduleRoot}/${name}.js`,contents:await readFile(new URL(`../src/${name}.js`,import.meta.url),'utf8'),
      })))],durableObjects:{GROUP:{className:'Fixture',useSQLite:true}},
    bindings:{LOCAL_DEVELOPMENT:'true',LOCAL_AUTH_MEMBERSHIP:'true',LOCAL_AUTH_POLICY:JSON.stringify(root)},compatibilityDate:'2026-07-01'});
  const prefix = `/g/${scope.id}`;
  const call = (path,init) => mf.dispatchFetch(scope.origin+path,init);
  const inspect = async () => (await call(prefix,{headers:{'x-test':'inspect'}})).json();
  try {
    assert.equal((await call(prefix)).status,401);
    assert.deepEqual(await inspect(),[],'unsigned calls must not acquire bootstrap ownership');
    assert.equal((await mf.dispatchFetch('https://relay.example'+prefix,await signed(prefix))).status,503);
    assert.equal((await call('/m/'+scope.id,await signed('/m/'+scope.id))).status,403);
    assert.equal((await call(prefix+'/ws',await signed(prefix+'/ws'))).status,403);
    assert.equal((await call(prefix+'/policy',await signed(prefix+'/policy'))).status,200);
    const first = Object.fromEntries(await inspect());
    assert.deepEqual(first.authorization_root,root);
    assert.deepEqual(first.authorized_devices,root);
    const next = {...root,epoch:1,devices:devices.map(device => ({key:device.key,operations})).sort((a,b)=>a.key.localeCompare(b.key))};
    const change = {expected_tail:0,blob:'AQ==',policy:next};
    const race = await Promise.all([0,1].map(async () => call(prefix+'/membership',await signed(prefix+'/membership','POST',change))));
    assert.deepEqual(race.map(response=>response.status).sort(),[200,409]);
    const policyReply = await call(prefix+'/policy',await signed(prefix+'/policy','GET',undefined,devices[1]));
    assert.deepEqual(await policyReply.json(),{policy:next});
    assert.equal((await call(prefix+'/append',await signed(prefix+'/append','POST',{expected_tail:1,blob:'Ag=='},devices[1]))).status,200);
    const revokedProof = await signed(prefix+'?after=0','GET',undefined,devices[1]);
    const removed = {...root,epoch:2};
    assert.equal((await call(prefix+'/membership',await signed(prefix+'/membership','POST',{expected_tail:2,blob:'Aw==',policy:removed}))).status,200);
    const revoked = await inspect();
    assert.equal((await call(prefix+'?after=0',revokedProof)).status,401);
    assert.deepEqual(await inspect(),revoked,'revoked requests cannot spend budget or change history');
    const overridden = await signed(prefix+'?after=0');
    overridden.headers['x-test-root']=JSON.stringify({...root,epoch:1});
    assert.equal((await call(prefix+'?after=0',overridden)).status,503);
    assert.deepEqual(await inspect(),revoked,'deployment config cannot replace persisted bootstrap authority');
    const current = await call(prefix+'?after=0',await signed(prefix+'?after=0'));
    assert.equal(current.status,200);
    assert.deepEqual((await current.json()).entries.map(entry=>entry.seq),[1,2,3]);
    const rows = Object.fromEntries(await inspect());
    assert.deepEqual(rows.authorization_root,root);
    assert.deepEqual(rows.authorized_devices,removed);
    assert.equal(rows.tail,3);
    // Fixed/legacy storage cannot acquire new bootstrap authority merely by
    // enabling the mode. Direct binding inspection exists only in this fixture.
    const namespace=await mf.getDurableObjectNamespace('GROUP');
    const legacy=namespace.get(namespace.idFromName('legacy-fixture'));
    await legacy.fetch(scope.origin+prefix,{method:'POST',headers:{'x-test':'seed'},body:JSON.stringify({authorized_devices:root,tail:1})});
    const legacyBefore=await (await legacy.fetch(scope.origin+prefix,{headers:{'x-test':'inspect'}})).json();
    assert.equal((await legacy.fetch(scope.origin+prefix,await signed(prefix))).status,503);
    assert.deepEqual(await (await legacy.fetch(scope.origin+prefix,{headers:{'x-test':'inspect'}})).json(),legacyBefore);
  } finally {await mf.dispose();}
});

test('roster mode requires explicit loopback authority and rejects unsafe routing before storage allocation',async()=>{
  let allocated=0;
  const GROUP={idFromName(){allocated++;throw new Error('unexpected allocation');}};
  const env={LOCAL_DEVELOPMENT:'true',LOCAL_AUTH_MEMBERSHIP:'true',LOCAL_AUTH_POLICY:JSON.stringify(root),GROUP};
  for (const overrides of [{LOCAL_AUTH_MEMBERSHIP:undefined},{LOCAL_DEVELOPMENT:undefined},{LOCAL_AUTH_POLICY:'{}'},
    {LOCAL_AUTH_POLICY:JSON.stringify({...root,amount:100})}]) {
    assert.equal((await rosterWorker.fetch(new Request(scope.origin+`/g/${scope.id}`),{...env,...overrides})).status,503);
  }
  for (const path of [`/g/${scope.id}?after=-1`,`/g/${scope.id}/policy?after=0`,`/g/${'03'.repeat(16)}`,`/m/${scope.id}`,`/g/${scope.id}/prune`]) {
    assert.equal((await rosterWorker.fetch(new Request(scope.origin+path),env)).status,403);
  }
  assert.equal((await rosterWorker.fetch(new Request('https://relay.example'+`/g/${scope.id}`),env)).status,503);
  assert.equal(allocated,0);
});

test('owned development launcher explicitly selects the live roster worker',{timeout:30000},async()=>{
  const reserve=createServer(); reserve.listen(0,'127.0.0.1'); await once(reserve,'listening');
  const port=reserve.address().port; await new Promise(resolve=>reserve.close(resolve));
  const origin=`http://127.0.0.1:${port}`, liveRoot={...root,scope:{...scope,origin}};
  const child=spawn(process.execPath,['dev-server.mjs',String(port)],{
    cwd:fileURLToPath(new URL('../',import.meta.url)),windowsHide:true,
    env:{...process.env,LOCAL_AUTH_MEMBERSHIP:'true',LOCAL_AUTH_POLICY:JSON.stringify(liveRoot)},
  });
  child.stderr.on('data',()=>{});
  try {
    await new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>reject(new Error('Owned roster launcher did not become ready')),10000);
      child.once('error',error=>{clearTimeout(timer);reject(error);});
      child.once('exit',()=>{clearTimeout(timer);reject(new Error('Owned launcher exited before ready'));});
      let output=''; child.stdout.on('data',chunk=>{
        output=(output+chunk).slice(-2048);
        if (output.includes('local roster group relay listening')) {clearTimeout(timer);resolve();}
      });
    });
    const prefix=`/g/${scope.id}`;
    assert.equal((await fetch(origin+prefix)).status,401);
    const initial=await fetch(origin+prefix+'/policy',await signed(prefix+'/policy','GET',undefined,devices[0],origin));
    assert.deepEqual(await initial.json(),{policy:liveRoot});
    const next={...liveRoot,epoch:1,devices:devices.map(device=>({key:device.key,operations})).sort((a,b)=>a.key.localeCompare(b.key))};
    assert.equal((await fetch(origin+prefix+'/membership',await signed(prefix+'/membership','POST',
      {expected_tail:0,blob:'AQ==',policy:next},devices[0],origin))).status,200);
    const joined=await fetch(origin+prefix+'/policy',await signed(prefix+'/policy','GET',undefined,devices[1],origin));
    assert.deepEqual(await joined.json(),{policy:next});
  } finally {
    if (child.exitCode===null && child.signalCode===null) {
      if (process.platform==='win32') {
        const stop=spawn('C:\\Windows\\System32\\taskkill.exe',['/PID',String(child.pid),'/T','/F'],{windowsHide:true,stdio:'ignore'});
        await once(stop,'exit');
      } else {child.kill('SIGTERM');await once(child,'exit');}
    }
  }
});
