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
      async welcomeRequest(txn,verified,bytes) {
        const value=await super.welcomeRequest(txn,verified,bytes);
        if(this.welcomeFault) throw new Error('controlled Welcome transaction rollback');
        return value;
      }
      async fetch(request) {
        if (request.headers.get('x-test') === 'inspect') return Response.json([...await this.state.storage.list()]);
        if (request.headers.get('x-test') === 'alarm-time') return Response.json(await this.state.storage.getAlarm());
        if (request.headers.get('x-test') === 'seed') {await this.state.storage.put(await request.json());return Response.json({ok:true});}
        if (request.headers.get('x-test') === 'alarm') {await this.alarm();return Response.json({ok:true});}
        const previous = this.env.LOCAL_AUTH_POLICY;
        const previousFault=this.welcomeFault;
        this.welcomeFault=request.headers.get('x-test')==='welcome-fault';
        if (request.headers.has('x-test-root')) this.env.LOCAL_AUTH_POLICY=request.headers.get('x-test-root');
        try {return await super.fetch(request);} finally {this.env.LOCAL_AUTH_POLICY=previous;this.welcomeFault=previousFault;}
      }
    }
    export default worker;`;
  const mf = new Miniflare({modulesRoot:moduleRoot,
    modules:[{type:'ESModule',path:`${moduleRoot}/fixture.js`,contents:wrapper},
      ...await Promise.all(['roster-worker','roster-welcome','local-auth-worker','worker','request-proof','request-membership','invite-authority','request-scope','request-admission','request-budget'].map(async name => ({
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
    const mailbox=prefix+'/invite/'+'04'.repeat(16);
    const welcome={recipient:devices[1].key,joined_after:1,welcome:Buffer.alloc(256*1024).toString('base64')};
    assert.equal((await call(mailbox)).status,401);
    assert.equal((await call(mailbox,await signed(mailbox,'GET',undefined,devices[1]))).status,404);
    assert.equal((await call(mailbox,await signed(mailbox,'PUT',welcome,devices[1]))).status,403,'membership grant is not original sponsorship');
    assert.equal((await call(mailbox,await signed(mailbox,'PUT',{...welcome,joined_after:2}))).status,403);
    assert.equal((await call(mailbox,await signed(mailbox,'PUT',{...welcome,amount:2050}))).status,400);
    for(const invalid of ['', 'AA', Buffer.alloc(256*1024+1).toString('base64')]) {
      assert.equal((await call(mailbox,await signed(mailbox,'PUT',{...welcome,welcome:invalid}))).status,400);
    }
    const seedIndex=async records=>call(prefix+'/append',{method:'POST',headers:{'x-test':'seed'},body:JSON.stringify({welcome_index:{version:1,records}})});
    for(const count of [64,65]) {
      const records=Array.from({length:count},(_,i)=>({id:(i+16).toString(16).padStart(32,'0'),recipient:devices[0].key,sequence:1,expires:Date.now()+7*86400000}));
      assert.equal((await seedIndex(records)).status,200);
      const before=await inspect();
      assert.equal((await call(mailbox,await signed(mailbox,'PUT',welcome))).status,count===64?507:503);
      assert.deepEqual(await inspect(),before,'inventory/capacity refusal rolls back admission and authority');
    }
    assert.equal((await seedIndex([])).status,200);
    const beforeWrite=await inspect();
    const alarmTime=async()=> (await call(prefix,{headers:{'x-test':'alarm-time'}})).json();
    const beforeAlarm=await alarmTime();
    const upload=await signed(mailbox,'PUT',welcome);
    assert.equal((await call(mailbox,{...upload,headers:{...upload.headers,'x-test':'welcome-fault'}})).status,503);
    assert.deepEqual(await inspect(),beforeWrite,'fault after payload/index/authority/alarm writes must roll back every record');
    assert.equal(await alarmTime(),beforeAlarm,'alarm scheduling must roll back too');
    assert.equal((await call(mailbox,upload)).status,200,'rolled-back nonce remains reusable');
    assert.equal((await call(mailbox,await signed(mailbox,'PUT',welcome))).status,200);
    const delivered=Object.fromEntries(await inspect());
    const expiry=delivered.welcome_index.records[0].expires;
    assert.equal(await alarmTime(),expiry);
    assert.equal(delivered.invite_authorities.records[0].mailbox,'04'.repeat(16));
    assert.deepEqual(await (await call(mailbox,await signed(mailbox,'GET',undefined,devices[1]))).json(),
      {group:scope.id,joined_after:1,welcome:welcome.welcome});
    assert.equal((await call(mailbox,await signed(mailbox))).status,403,'random ID and sponsorship do not grant recipient read access');
    const get=await signed(mailbox,'GET',undefined,devices[1]);
    assert.equal((await call(mailbox,get)).status,200);
    const seen=await inspect();
    assert.equal((await call(mailbox,get)).status,409);
    assert.deepEqual(await inspect(),seen,'replayed read cannot spend budget');
    assert.equal((await call(mailbox,await signed(mailbox,'PUT',{...welcome,welcome:'AQ=='}))).status,409);
    assert.deepEqual(await inspect(),seen,'failed replacement cannot reset bytes or expiry');
    const ack=mailbox+'/ack';
    assert.equal((await call(ack,await signed(ack,'POST',undefined,devices[1]))).status,200);
    assert.equal((await call(ack,await signed(ack,'POST',undefined,devices[1]))).status,200);
    assert.equal((await call(mailbox,await signed(mailbox,'PUT',welcome))).status,200,'exact retry must preserve consumed state');
    assert.equal((await call(mailbox,await signed(mailbox,'GET',undefined,devices[1]))).status,404);
    const other=prefix+'/invite/'+'05'.repeat(16);
    assert.equal((await call(other,await signed(other,'PUT',welcome))).status,409,'one accepted addition cannot recreate its Welcome in another mailbox');
    assert.equal(Object.fromEntries(await inspect()).welcome_index.records[0].expires,expiry);
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
    const beforeExpiry=await inspect();
    assert.equal((await call(prefix+'/append',{method:'POST',headers:{'x-test':'seed'},body:JSON.stringify({request_clock:expiry})})).status,200);
    assert.equal((await call(prefix,{headers:{'x-test':'alarm'}})).status,200);
    const expired=Object.fromEntries(await inspect());
    assert.deepEqual(expired.welcome_index,{version:1,records:[]});
    assert.equal(await alarmTime(),null);
    assert(!Object.keys(expired).some(key=>key.startsWith('welcome:')));
    assert.deepEqual(expired.authorized_devices,rows.authorized_devices);
    for(const [key,value] of beforeExpiry.filter(([key])=>key.startsWith('e:'))) assert.deepEqual(expired[key],value,'expiry must never delete ledger ciphertext');
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
  for(const path of [`/g/${scope.id}?after=0`,`/g/${scope.id}/invite/${'04'.repeat(16)}`]) {
    const response=await rosterWorker.fetch(new Request(scope.origin+path,{method:'OPTIONS'}),env);
    assert.equal(response.status,204);
    assert(response.headers.get('access-control-allow-methods').includes('PUT'));
  }
  assert.equal((await rosterWorker.fetch(new Request(scope.origin+`/g/${scope.id}?after=-1`,{method:'OPTIONS'}),env)).status,403);
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
