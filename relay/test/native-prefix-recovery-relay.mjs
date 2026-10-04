// Owned stdin-only inspection. Deletion uses real authenticated HTTP consent;
// this fixture provides no guard bypass, seed or internal deletion command.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {createInterface} from 'node:readline';
import {Miniflare} from 'miniflare';

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
export default worker;`;
const names = ['roster-worker','worker','local-auth-worker','request-proof',
  'request-admission','prefix-consent','retired-readers','request-scope','request-budget',
  'roster-welcome','request-membership','invite-authority'];
const mf = new Miniflare({modulesRoot:root,modules:[
  {type:'ESModule',path:`${root}/prefix-recovery-fixture.js`,contents:wrapper},
  ...await Promise.all(names.map(async name=>({type:'ESModule',path:`${root}/${name}.js`,
    contents:await readFile(new URL(`../src/${name}.js`,import.meta.url),'utf8')}))),
],durableObjects:{GROUP:{className:'Fixture',useSQLite:true}},
bindings:{LOCAL_DEVELOPMENT:'true',LOCAL_AUTH_MEMBERSHIP:'true',LOCAL_AUTH_POLICY:JSON.stringify(policy),
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
      assert.deepEqual(command,{kind:'inspect'});
      const values = await (await stub.fetch('http://fixture-internal/inspect')).json();
      const stored = Object.fromEntries(values);
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
