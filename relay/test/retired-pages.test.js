import assert from 'node:assert/strict';
import {test} from 'node:test';
import {webcrypto} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {Miniflare} from 'miniflare';
import {encodeRequestProofPayload} from '../src/request-proof.js';

test('SQLite retired-device pages end at removal across page boundaries, while the active peer sees the later tail',async()=>{
  const origin='http://127.0.0.1', id='03'.repeat(16), prefix=`/g/${id}`;
  const identities=await Promise.all([0,1].map(async()=>{
    const keys=await webcrypto.subtle.generateKey('Ed25519',true,['sign','verify']);
    return {keys,key:Buffer.from(await webcrypto.subtle.exportKey('raw',keys.publicKey)).toString('hex')};
  }));
  const operations=['append','membership','read'];
  const root={version:2,epoch:0,scope:{origin,kind:'g',id},devices:[{key:identities[0].key,operations}]};
  const mf=new Miniflare({modules:true,modulesRules:[{type:'ESModule',include:['**/*.js']}],
    scriptPath:fileURLToPath(new URL('../src/roster-worker.js',import.meta.url)),
    durableObjects:{GROUP:{className:'RosterGroupLog',useSQLite:true}},
    bindings:{LOCAL_DEVELOPMENT:'true',LOCAL_AUTH_MEMBERSHIP:'true',LOCAL_AUTH_POLICY:JSON.stringify(root)},compatibilityDate:'2026-07-01'});
  let nonce=0;
  async function call(path,method='GET',value,identity=identities[0]) {
    const body=value===undefined?'':JSON.stringify(value);
    const proof={publicKey:identity.key,nonce:(++nonce).toString(16).padStart(64,'0'),expires:Date.now()+50000};
    const payload=encodeRequestProofPayload({origin,method,path,digest:Buffer.from(await webcrypto.subtle.digest('SHA-256',new TextEncoder().encode(body))).toString('hex'),...proof});
    proof.signature=Buffer.from(await webcrypto.subtle.sign('Ed25519',identity.keys.privateKey,payload)).toString('hex');
    return mf.dispatchFetch(origin+path,{method,headers:{'x-cash-device-proof':JSON.stringify(proof)},...(body?{body}:{})});
  }
  try {
    const joined={...root,epoch:1,devices:identities.map(identity=>({key:identity.key,operations})).sort((a,b)=>a.key.localeCompare(b.key))};
    assert.equal((await call(prefix+'/membership','POST',{expected_tail:0,blob:'AQ==',policy:joined})).status,200);
    for(let slot=2;slot<=31;slot++) assert.equal((await call(prefix+'/append','POST',{expected_tail:slot-1,blob:Buffer.from([slot]).toString('base64')})).status,200);
    assert.equal((await call(prefix+'/membership','POST',{expected_tail:31,blob:'IA==',policy:{...root,epoch:2}})).status,200);
    assert.equal((await call(prefix+'/append','POST',{expected_tail:32,blob:'IQ=='})).status,200);
    const first=await (await call(prefix+'?after=0','GET',undefined,identities[1])).json();
    assert.deepEqual(first.entries.map(entry=>entry.seq),Array.from({length:16},(_,i)=>i+1));
    assert.equal(first.tail,32); assert.equal(first.more,true);
    const second=await (await call(prefix+'?after=16','GET',undefined,identities[1])).json();
    assert.deepEqual(second.entries.map(entry=>entry.seq),Array.from({length:16},(_,i)=>i+17));
    assert.equal(second.entries.at(-1).blob,'IA==');
    assert.equal(second.tail,32); assert.equal(second.more,false);
    assert.deepEqual(await (await call(prefix+'?after=32','GET',undefined,identities[1])).json(),{entries:[],tail:32,more:false});
    assert.deepEqual(await (await call(prefix+'?after=32')).json(),{entries:[{seq:33,blob:'IQ=='}],tail:33,more:false});
  } finally {await mf.dispose();}
});
