import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readRetiredReaders, updateRetiredReaders, retiredReader} from '../src/retired-readers.js';
import {webcrypto} from 'node:crypto';
import {encodeRequestProofPayload,verifyRequestProof} from '../src/request-proof.js';
import {admitRetiredReadRequest} from '../src/request-admission.js';

const a='01'.repeat(32), b='02'.repeat(32), now=1790000000000, ttl=7*86400000;
const policy=keys=>({devices:keys.map(key=>({key,operations:['read']}))});
const store=()=>{const values=new Map();return {async get(key){return structuredClone(values.get(key));},async put(key,value){values.set(key,structuredClone(value));}};};

test('retired read authority has immutable cutoff/expiry, re-add drops old authority, and no-read keys gain nothing',async()=>{
  const txn=store();
  await updateRetiredReaders(txn,policy([a,b]),policy([a]),3,now);
  assert.deepEqual(await readRetiredReaders(txn),{version:1,records:[{key:b,through:3,expires:now+ttl}]});
  await updateRetiredReaders(txn,policy([a]),policy([a]),4,now+1000);
  assert.deepEqual(await retiredReader(txn,b,now),{key:b,through:3,expires:now+ttl});
  await txn.put('request_clock',now+ttl);
  assert.equal(await retiredReader(txn,b,now),null,'a rolled-back wall clock cannot revive expired authority');
  await updateRetiredReaders(txn,policy([a]),policy([a,b]),5,now+ttl);
  assert.deepEqual(await readRetiredReaders(txn),{version:1,records:[]});
  await updateRetiredReaders(txn,{devices:[{key:b,operations:['append']}]},policy([a]),6,now+ttl);
  assert.deepEqual(await readRetiredReaders(txn),{version:1,records:[]});
  await updateRetiredReaders(txn,policy([a,b]),policy([a]),7,now+ttl);
  assert.equal((await readRetiredReaders(txn)).records[0].through,7);
});

test('retired authority rejects damaged/oversized records and refuses growth without evicting live recipients',async()=>{
  const txn=store(), valid={key:b,through:3,expires:now+ttl};
  for(const value of [null,{}, {version:1,records:[{...valid,name:'private'}]},
    {version:1,records:[{...valid,through:0}]},{version:1,records:[{...valid,expires:-1}]},
    {version:1,records:[valid,valid]},{version:1,records:Array(65).fill(valid)}]) {
    await txn.put('retired_readers',value);
    await assert.rejects(readRetiredReaders(txn),error=>error.status===503);
    assert.deepEqual(await txn.get('retired_readers'),value);
  }
  const records=Array.from({length:64},(_,i)=>({key:`ff${i.toString(16).padStart(62,'0')}`,through:1,expires:now+ttl}));
  await txn.put('retired_readers',{version:1,records});
  await assert.rejects(updateRetiredReaders(txn,policy([a,b]),policy([a]),3,now),error=>error.status===507);
  assert.deepEqual((await readRetiredReaders(txn)).records,records);
});

test('retired admission requires verifier ownership, exact historical route, absent current membership and stored cutoff',async()=>{
  const identity=await webcrypto.subtle.generateKey('Ed25519',true,['sign','verify']);
  const key=Buffer.from(await webcrypto.subtle.exportKey('raw',identity.publicKey)).toString('hex');
  const scope={origin:'http://127.0.0.1',kind:'g',id:'01'.repeat(16)}, prefix=`/g/${scope.id}`;
  let nonce=0;
  async function proof(path) {
    const request=new Request(scope.origin+path);
    const value={publicKey:key,nonce:(++nonce).toString(16).padStart(64,'0'),expires:now+50000};
    const payload=encodeRequestProofPayload({origin:scope.origin,method:'GET',path,digest:Buffer.from(await webcrypto.subtle.digest('SHA-256',new Uint8Array())).toString('hex'),...value});
    value.signature=Buffer.from(await webcrypto.subtle.sign('Ed25519',identity.privateKey,payload)).toString('hex');
    return verifyRequestProof(request,new Uint8Array(),value,key,now);
  }
  const txn=store();
  await txn.put('authorized_devices',{version:2,epoch:2,scope,devices:[{key:a,operations:['read']}]});
  await txn.put('tail',3);
  const verified=await proof(prefix+'?after=0');
  assert.deepEqual(await admitRetiredReadRequest(txn,verified,now),{ok:false,reason:'unauthorized'});
  await txn.put('retired_readers',{version:1,records:[{key,through:3,expires:now+ttl}]});
  assert.deepEqual(await admitRetiredReadRequest(txn,{...verified},now),{ok:false,reason:'invalid'});
  assert.deepEqual(await admitRetiredReadRequest(txn,await proof(prefix+'/policy'),now),{ok:false,reason:'scope'});
  assert.deepEqual(await admitRetiredReadRequest(txn,verified,now),{ok:true,epoch:2,through:3});
  assert.deepEqual(await admitRetiredReadRequest(txn,verified,now),{ok:false,reason:'replay'});
  await txn.put('tail',2);
  assert.deepEqual(await admitRetiredReadRequest(txn,await proof(prefix),now),{ok:false,reason:'state'});
  await txn.put('tail',3);
  await txn.put('authorized_devices',{version:2,epoch:3,scope,devices:[{key,operations:['read']}]});
  assert.deepEqual(await admitRetiredReadRequest(txn,await proof(prefix),now),{ok:false,reason:'unauthorized'});
});
