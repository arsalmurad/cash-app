// Owned stdin-only inspection. Deletion uses real authenticated HTTP consent;
// this fixture provides no guard bypass, seed or internal deletion command.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {createInterface} from 'node:readline';
import {Miniflare} from 'miniflare';
import {auditPrunedRosterStorage,auditRosterStorage} from './roster-storage-audit.js';

const root = fileURLToPath(new URL('./',import.meta.url));
const policy = JSON.parse(process.env.LOCAL_AUTH_POLICY);
const wrapper = `
import worker, {RosterGroupLog} from './roster-worker.js';
export class Fixture extends RosterGroupLog {
  async fetch(request) {
    if (request.url === 'http://fixture-internal/inspect') {
      return Response.json([...await this.state.storage.list()]);
    }
    return super.fetch(request);
  }
}
let dropped = false;
export default {
  async fetch(request, env) {
    const response = await worker.fetch(request, env);
    if (!dropped && env.DROP_FIRST_PRUNE_REPLY === 'true' &&
        new URL(request.url).pathname.endsWith('/prune') && response.status === 200) {
      // Only discard the actual successful response after the production
      // transaction. No fabricated deletion, authority or metadata progress.
      dropped = true;
      return new Response('Controlled lost prune confirmation', {status:503});
    }
    return response;
  }
};`;
const names = ['roster-worker','worker','local-auth-worker','request-proof',
  'request-admission','prefix-consent','retired-readers','request-scope','request-budget',
  'roster-welcome','request-membership','invite-authority'];
const mf = new Miniflare({modulesRoot:root,modules:[
  {type:'ESModule',path:`${root}/prefix-recovery-fixture.js`,contents:wrapper},
  ...await Promise.all(names.map(async name=>({type:'ESModule',path:`${root}/${name}.js`,
    contents:await readFile(new URL(`../src/${name}.js`,import.meta.url),'utf8')}))),
],durableObjects:{GROUP:{className:'Fixture',useSQLite:true}},
bindings:{LOCAL_DEVELOPMENT:'true',LOCAL_AUTH_MEMBERSHIP:'true',LOCAL_AUTH_POLICY:JSON.stringify(policy),
  ...(process.env.DROP_FIRST_PRUNE_REPLY==='true'?{DROP_FIRST_PRUNE_REPLY:'true'}:{}),
  ...(process.env.LOCAL_AUTH_RETENTION==='true'?{LOCAL_AUTH_RETENTION:'true'}:{})},
compatibilityDate:'2026-07-01',host:'127.0.0.1',port:Number(process.argv[2])});
await mf.ready;
console.log('PREFIX-READY');
const namespace = await mf.getDurableObjectNamespace('GROUP');
const stub = namespace.get(namespace.idFromName(policy.scope.id));
const input = createInterface({input:process.stdin});
// Serialize commands; never use externally accessible HTTP control routes.
let commands = Promise.resolve();
input.on('line',line=>{
  commands = commands.then(async()=>{
    try {
      const command = JSON.parse(line);
      const values = await (await stub.fetch('http://fixture-internal/inspect')).json();
      const stored = Object.fromEntries(values);
      if(command.kind==='audit') {
        assert.deepEqual(Object.keys(command).sort(),['kind','manifest']);
        const manifest=command.manifest;
        assert(Array.isArray(manifest.needles)&&manifest.needles.length>0&&manifest.needles.length<=64);
        assert(manifest.needles.every(value=>typeof value==='string'&&value.length>=8&&value.length<=256));
        const needles=[...manifest.needles,Buffer.from('cash-app durable receipt v2\0')];
        for(const amount of [100n,-100n,250n,-250n,725n,-725n,975n,-975n,1075n,-1075n]) {
          const be=Buffer.alloc(8),le=Buffer.alloc(8);
          be.writeBigInt64BE(amount);le.writeBigInt64LE(amount);needles.push(be,le);
        }
        const audit=rows=>auditPrunedRosterStorage(rows,policy,manifest,needles);
        const result=audit(values);
        assert.throws(()=>auditRosterStorage(values,policy,manifest,needles));
        const entry=values.find(([key])=>key.startsWith('e:'))[0];
        for(const poison of [Buffer.from(needles[0]),needles.at(-1)]) {
          const copy=structuredClone(values);copy.find(([key])=>key===entry)[1]=poison.toString('base64');
          assert.throws(()=>audit(copy),/readable synthetic financial data/);
        }
        for(const field of ['authorized_devices','request_budget','retired_readers','welcome_index','invite_authorities']) {
          const copy=structuredClone(values);copy.find(([key])=>key===field)[1].privateName=manifest.needles[0];
          assert.throws(()=>audit(copy));
          assert.throws(()=>audit(values.filter(([key])=>key!==field)));
        }
        const welcome=structuredClone(values);welcome.find(([key])=>key.startsWith('welcome:'))[1].welcome=Buffer.from(needles[0]).toString('base64');
        assert.throws(()=>audit(welcome),/readable synthetic financial data/);
        assert.throws(()=>audit(values.filter(([key])=>key!==entry)));
        const extra=structuredClone(values);extra.push(['retention_consents',manifest.needles[0]]);assert.throws(()=>audit(extra));
        const corrupt=structuredClone(values);corrupt.find(([key])=>key==='floor')[1]++;assert.throws(()=>audit(corrupt));
        console.log('PREFIX-RESULT:'+JSON.stringify({...result,negativeControls:true}));
        return;
      }
      assert.deepEqual(command,{kind:'inspect'});
      console.log('PREFIX-RESULT:'+JSON.stringify({floor:stored.floor??0,tail:stored.tail,
        entries:values.filter(([key])=>key.startsWith('e:')).length,capacity:stored.capacity}));
    } catch {
      console.log('PREFIX-FAIL');
    }
  });
});
for (const signal of ['SIGINT','SIGTERM']) process.on(signal,async()=>{
  input.close();await mf.dispose();process.exit(0);
});
