import assert from 'node:assert/strict';
import {test} from 'node:test';
import {Miniflare} from 'miniflare';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';

test('actual workerd verifies Rust saved-checkpoint consents and device proof before deletion',async()=>{
  const fixture=JSON.parse(process.env.PREFIX_CONSENT_RUST_FIXTURE);
  const origin='http://127.0.0.1',prefix=`/g/${fixture.group}`;
  const policy={version:2,epoch:1,scope:{origin,kind:'g',id:fixture.group},
    devices:fixture.keys.map(key=>({key,operations:['append','membership','read']}))};
  const root=fileURLToPath(new URL('./',import.meta.url));
  const wrapper=`import worker,{RosterGroupLog} from './roster-worker.js';
    export class Fixture extends RosterGroupLog {async fetch(request) {
      if(request.url==='http://fixture-internal/seed') {await this.state.storage.put(await request.json());return Response.json({ok:true});}
      if(request.url==='http://fixture-internal/rows') return Response.json([...await this.state.storage.list()]);
      return super.fetch(request);
    }} export default worker;`;
  const names=['roster-worker','roster-welcome','local-auth-worker','worker','request-proof',
    'request-membership','invite-authority','retired-readers','request-scope','request-admission','request-budget','prefix-consent'];
  const mf=new Miniflare({modulesRoot:root,modules:[{type:'ESModule',path:`${root}/rust-consent-fixture.js`,contents:wrapper},
    ...await Promise.all(names.map(async name=>({type:'ESModule',path:`${root}/${name}.js`,contents:await readFile(new URL(`../src/${name}.js`,import.meta.url),'utf8')})))],
    durableObjects:{GROUP:{className:'Fixture',useSQLite:true}},bindings:{LOCAL_DEVELOPMENT:'true',LOCAL_AUTH_MEMBERSHIP:'true',
      LOCAL_AUTH_RETENTION:'true',LOCAL_AUTH_POLICY:JSON.stringify(policy)},compatibilityDate:'2026-07-01'});
  try {
    await mf.ready;
    assert.equal((await mf.dispatchFetch(origin+prefix+'/policy',{headers:{'x-cash-device-proof':JSON.stringify(fixture.readProof)}})).status,200);
    const namespace=await mf.getDurableObjectNamespace('GROUP'),stub=namespace.get(namespace.idFromName(fixture.group));
    const entries=fixture.entries.map(entry=>({seq:entry.seq,blob:Buffer.from(entry.hex,'hex').toString('base64')}));
    assert(entries.length>fixture.body.through,'Retain control messages beyond the acknowledged financial prefix');
    const capacity={version:1,bytes:entries.reduce((sum,entry)=>sum+entry.blob.length,0),entries:entries.length};
    await stub.fetch('http://fixture-internal/seed',{method:'POST',body:JSON.stringify({tail:entries.length,capacity,
      ...Object.fromEntries(entries.map(entry=>[`e:${String(entry.seq).padStart(12,'0')}`,entry.blob]))})});
    const before=Object.fromEntries(await (await stub.fetch('http://fixture-internal/rows')).json());
    const response=await mf.dispatchFetch(origin+prefix+'/prune',{method:'POST',headers:{'x-cash-device-proof':JSON.stringify(fixture.proof)},body:JSON.stringify(fixture.body)});
    assert.equal(response.status,200,JSON.stringify(await response.clone().json()));
    assert.deepEqual(await response.json(),{floor:fixture.body.through,tail:entries.length,more:false});
    const after=Object.fromEntries(await (await stub.fetch('http://fixture-internal/rows')).json());
    const deleted=entries.filter(entry=>entry.seq<=fixture.body.through);
    for(const entry of deleted) assert.equal(after[`e:${String(entry.seq).padStart(12,'0')}`],undefined);
    assert.equal(after.capacity.bytes,before.capacity.bytes-deleted.reduce((sum,entry)=>sum+entry.blob.length,0));
    assert.equal(after.capacity.entries,entries.length-fixture.body.through);
  } finally {await mf.dispose();}
});
