import assert from 'node:assert/strict';
import {test} from 'node:test';
import {webcrypto} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {Miniflare} from 'miniflare';
import {encodeRequestProofPayload} from '../src/request-proof.js';

const origin = 'http://127.0.0.1', id = '06'.repeat(16), prefix = `/g/${id}`;
const hex = value => Buffer.from(value).toString('hex');
const integer = value => {const bytes=Buffer.alloc(8);bytes.writeBigUInt64BE(BigInt(value));return bytes;};
const field = value => Buffer.concat([integer(value.length),value]);
const bytes = value => Buffer.from(value,'hex');
const logKey = seq => `e:${String(seq).padStart(12,'0')}`;
async function setup(enabled=true) {
  const identities = await Promise.all([0,1].map(async()=>{
    const keys=await webcrypto.subtle.generateKey('Ed25519',true,['sign','verify']);
    return {keys,key:hex(await webcrypto.subtle.exportKey('raw',keys.publicKey))};
  }));
  identities.sort((a,b)=>a.key.localeCompare(b.key));
  const policy={version:2,epoch:0,scope:{origin,kind:'g',id},
    devices:identities.map(identity=>({key:identity.key,operations:['append','membership','read']}))};
  const root=fileURLToPath(new URL('./',import.meta.url));
  const fixture=`import worker, {RosterGroupLog} from './roster-worker.js';
    export class Fixture extends RosterGroupLog {
      async fetch(request) {
        if(request.url==='http://fixture-internal/seed') {await this.state.storage.put(await request.json());return Response.json({ok:true});}
        if(request.url==='http://fixture-internal/rows') return Response.json([...await this.state.storage.list()]);
        return super.fetch(request);
      }
    } export default worker;`;
  const names=['roster-worker','roster-welcome','local-auth-worker','worker','request-proof',
    'request-membership','invite-authority','retired-readers','request-scope','request-admission',
    'request-budget','prefix-consent'];
  const mf=new Miniflare({modulesRoot:root,modules:[
    {type:'ESModule',path:`${root}/prefix-consent-fixture.js`,contents:fixture},
    ...await Promise.all(names.map(async name=>({type:'ESModule',path:`${root}/${name}.js`,
      contents:await readFile(new URL(`../src/${name}.js`,import.meta.url),'utf8')}))),
  ],durableObjects:{GROUP:{className:'Fixture',useSQLite:true}},
  bindings:{LOCAL_DEVELOPMENT:'true',LOCAL_AUTH_MEMBERSHIP:'true',
    LOCAL_AUTH_POLICY:JSON.stringify(policy),...(enabled?{LOCAL_AUTH_RETENTION:'true'}:{})},compatibilityDate:'2026-07-01'});
  await mf.ready;
  const namespace=await mf.getDurableObjectNamespace('GROUP'),stub=namespace.get(namespace.idFromName(id));
  const rows=async()=> (await stub.fetch('http://fixture-internal/rows')).json();
  const seed=value=>stub.fetch('http://fixture-internal/seed',{method:'POST',body:JSON.stringify(value)});
  let nonce=0;
  async function signed(path,body,identity=identities[0]) {
    const text=body===undefined?'':JSON.stringify(body),method=body===undefined?'GET':'POST';
    const proof={publicKey:identity.key,nonce:(++nonce).toString(16).padStart(64,'0'),expires:Date.now()+50000};
    proof.signature=hex(await webcrypto.subtle.sign('Ed25519',identity.keys.privateKey,
      encodeRequestProofPayload({origin,method,path,...proof,digest:hex(await webcrypto.subtle.digest('SHA-256',Buffer.from(text)))})));
    return {method,headers:{'x-cash-device-proof':JSON.stringify(proof)},...(text?{body:text}:{})};
  }
  const call=async(path,body,identity)=>mf.dispatchFetch(origin+path,await signed(path,body,identity));
  async function consent(identity,change={}) {
    const values={origin,id,epoch:0,through:33,checkpoint:'08'.repeat(32),group:'09'.repeat(16),
      holder:identities[0].key,expires:Date.now()+50000,...change};
    const group=bytes(values.group);
    const payload=Buffer.concat([Buffer.from('cash-app prefix retention consent v1\0'),field(Buffer.from(values.origin)),
      Buffer.from(values.id),field(group),integer(values.epoch),integer(values.through),bytes(values.checkpoint),
      bytes(values.holder),integer(values.expires),bytes(identity.key)]);
    const signature=await webcrypto.subtle.sign('Ed25519',identity.keys.privateKey,
      Buffer.concat([Buffer.from('cash-app authenticated history v1\0'),field(group),field(payload)]));
    return hex(Buffer.concat([payload,Buffer.from(signature)]));
  }
  async function bundle(change={}) {
    const expires=Date.now()+50000;
    return Promise.all(identities.map(identity=>consent(identity,{expires,...change})));
  }
  async function initial() {
    assert.equal((await call(prefix+'/policy')).status,200);
    await seed({tail:33,capacity:{version:1,bytes:132,entries:33},
      ...Object.fromEntries(Array.from({length:33},(_,i)=>[logKey(i+1),'YQ==']))});
  }
  return {mf,identities,policy,rows,seed,signed,call,consent,bundle,initial};
}

test('actual routed prefix deletion needs exact consent from every current key and live holder proof',async()=>{
  const f=await setup();try {
    await f.initial();const before=await f.rows();const consents=await f.bundle();
    const request={expectedFloor:0,through:33,consents};
    assert.equal((await f.mf.dispatchFetch(origin+prefix+'/prune',{method:'POST',body:JSON.stringify(request)})).status,401);
    for(const invalid of [[],[consents[0]],[consents[0],consents[0]], [...consents,consents[0]],
      [consents[0],consents[1].slice(0,-2)+(Number.parseInt(consents[1].slice(-2),16)^1).toString(16).padStart(2,'0')]]) {
      assert.equal((await f.call(prefix+'/prune',{...request,consents:invalid})).status,403);
      assert.deepEqual(await f.rows(),before,'Denied consent must not consume replay/budget or delete history');
    }
    assert.equal((await f.call(prefix+'/prune',request,f.identities[1])).status,403);
    assert.deepEqual(await f.rows(),before);
    const proof=await f.signed(prefix+'/prune',request);
    assert.deepEqual(await (await f.mf.dispatchFetch(origin+prefix+'/prune',proof)).json(),{floor:16,tail:33,more:true});
    const committed=await f.rows();
    assert.equal((await f.mf.dispatchFetch(origin+prefix+'/prune',proof)).status,409,'Replay cannot delete the next chunk');
    assert.deepEqual(await f.rows(),committed);
    assert.equal((await f.call(prefix+'/prune',request)).status,409,'Fresh stale-floor retry cannot delete twice');
    assert.equal((await f.call(prefix+'?after=0')).status,410);
    assert.equal((await f.call(prefix+'/prune',{...request,expectedFloor:16})).status,200);
    assert.equal((await f.call(prefix+'/prune',{...request,expectedFloor:32})).status,200);
    const stored=Object.fromEntries(await f.rows());
    assert.equal(stored.floor,33);assert.equal(stored.tail,33);
    assert.deepEqual(stored.capacity,{version:1,bytes:0,entries:0});
    assert.equal((await f.call(prefix+'/append',{expected_tail:33,blob:'YQ=='})).status,200);
    assert.equal(Object.fromEntries(await f.rows()).tail,34);
  } finally {await f.mf.dispose();}
});

test('cross-scope, checkpoint, cutoff, holder and expired consents fail without metadata leakage',async()=>{
  const f=await setup();try {
    await f.initial();const before=await f.rows();
    for (const change of [{origin:'https://other.example'},{id:'07'.repeat(16)}, {epoch:1},
      {through:32},{holder:'01'.repeat(32)},{expires:Date.now()-1},{expires:Date.now()+61000}]) {
      const response=await f.call(prefix+'/prune',{expectedFloor:1,through:33,consents:await f.bundle(change)});
      assert.equal(response.status,403,JSON.stringify(change));
      assert.deepEqual(Object.keys(await response.json()),['error']);
      assert.deepEqual(await f.rows(),before);
    }
    for (const change of [{checkpoint:'0a'.repeat(32)},{group:'0b'.repeat(16)}]) {
      const expires=Date.now()+50000;
      const consents=await Promise.all(f.identities.map((identity,i)=>f.consent(identity,{expires,...(i?change:{})})));
      assert.equal((await f.call(prefix+'/prune',{expectedFloor:0,through:33,consents})).status,403);
      assert.deepEqual(await f.rows(),before);
    }
  } finally {await f.mf.dispose();}
});

test('each chunk rechecks the actual current policy and storage monotonic clock',async()=>{
  const f=await setup();try {
    await f.initial();const consents=await f.bundle();
    assert.equal((await f.call(prefix+'/prune',{expectedFloor:0,through:33,consents})).status,200);
    // Actual authenticated policy transition, not a fixture policy mutation.
    assert.equal((await f.call(prefix+'/membership',{expected_tail:33,blob:'AQ==',policy:{...f.policy,epoch:1}})).status,200);
    const before=await f.rows();
    assert.equal((await f.call(prefix+'/prune',{expectedFloor:16,through:33,consents})).status,403);
    assert.deepEqual(await f.rows(),before);
  } finally {await f.mf.dispose();}
});

test('retention is explicit opt-in and never opens public routing',async()=>{
  const f=await setup(false);try {
    assert.equal((await f.call(prefix+'/prune',{expectedFloor:0,through:1,consents:[]})).status,403);
    assert.deepEqual(await f.rows(),[]);
    assert.equal((await f.mf.dispatchFetch('https://relay.example'+prefix+'/prune',{method:'POST'})).status,503);
  } finally {await f.mf.dispose();}
});

test('unanimous signatures do not bypass exact roster, recovery-holder permission, quota or monotonic expiry',async()=>{
  const f=await setup();try {
    await f.initial();
    const keys=await webcrypto.subtle.generateKey('Ed25519',true,['sign','verify']);
    const foreign={keys,key:hex(await webcrypto.subtle.exportKey('raw',keys.publicKey))};
    const expires=Date.now()+50000;
    const consents=await Promise.all([f.consent(f.identities[0],{expires}),f.consent(foreign,{expires})]);
    let before=await f.rows();
    assert.equal((await f.call(prefix+'/prune',{expectedFloor:0,through:33,consents})).status,403);
    assert.deepEqual(await f.rows(),before);
    const limited={...f.policy,epoch:1,devices:f.policy.devices.map((device,index)=>
      index?device:{...device,operations:['read']})};
    assert.equal((await f.call(prefix+'/membership',{expected_tail:33,blob:'AQ==',policy:limited})).status,200);
    before=await f.rows();
    assert.equal((await f.call(prefix+'/prune',{expectedFloor:0,through:33,consents:await f.bundle({epoch:1})})).status,403);
    assert.deepEqual(await f.rows(),before);
  } finally {await f.mf.dispose();}
  const quota=await setup();try {
    await quota.initial();
    await quota.seed({request_budget:{version:1,day:Math.floor(Date.now()/86400000),used:20000,
      devices:quota.identities.map(identity=>({key:identity.key,used:10000}))}});
    const before=await quota.rows();
    const response=await quota.call(prefix+'/prune',{expectedFloor:0,through:33,consents:await quota.bundle()});
    assert.equal(response.status,429);assert(Number(response.headers.get('retry-after'))>0);
    assert.deepEqual(await quota.rows(),before,'Spent quota cannot commit nonce or deletion');
  } finally {await quota.mf.dispose();}
  const clock=await setup();try {
    await clock.initial();const consents=await clock.bundle();
    await clock.seed({request_clock:Date.now()+60000});
    const before=await clock.rows();
    assert.equal((await clock.call(prefix+'/prune',{expectedFloor:0,through:33,consents})).status,403);
    assert.deepEqual(await clock.rows(),before,'Stored admitted time, not a rolled-back wall clock, expires consent');
  } finally {await clock.mf.dispose();}
});
