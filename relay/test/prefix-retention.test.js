import assert from 'node:assert/strict';
import {after, before, test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {Miniflare} from 'miniflare';

// Only this in-memory module exposes seed/inspect/authorized/fault commands.
// It verifies storage mechanics, NOT all-peer pruning permission or recovery.
const fixture = `
import production, {GroupLog, Mailbox} from './production-worker.js';
export {Mailbox};
export class Fixture extends GroupLog {
  constructor(state) {super(state); this.instance = crypto.randomUUID();}
  async fetch(request) {
    const command = new URL(request.url).pathname;
    if (command === '/__seed') {
      await this.state.storage.put(await request.json());
      return Response.json({ok:true});
    }
    if (command === '/__rows') return Response.json([...await this.state.storage.list()]);
    if (command === '/__instance') return Response.json({instance:this.instance});
    if (command === '/__prune') {
      const mode = request.headers.get('x-fixture-mode') ?? 'allow';
      const original = this.state.storage;
      const storage = {transaction: closure => original.transaction(txn => closure(new Proxy(txn, {
        get(target, property) {
          if (property === 'list') return async options => {
            if (options.limit !== 16 || !options.start || !options.end) throw new Error('unbounded prefix read');
            return target.list(options);
          };
          if (property === 'delete') return async keys => {
            const result = await target.delete(keys);
            if (mode === 'after-delete') throw new Error('controlled interruption after delete');
            return result;
          };
          if (property === 'put') return async (key, value) => {
            const result = await target.put(key, value);
            if (mode === 'after-' + key) throw new Error('controlled interruption after ' + key);
            return result;
          };
          const value = target[property];
          return typeof value === 'function' ? value.bind(target) : value;
        }
      }))) };
      const log = new GroupLog({storage});
      const spec = await request.json();
      const authorize = mode === 'missing' ? null : async (txn, context) => {
        if (context.floor > context.through || context.through > context.tail) throw new Error('wrong guard context');
        await txn.put('admitted', 'fixture-only');
        if (mode === 'mutate-request') spec.through = context.tail;
        return mode !== 'deny';
      };
      const response = await log.prunePrefix(spec, authorize);
      // A lost reply happens after commit, unlike transaction interruption.
      if (mode === 'lost' && response.status === 200) return new Response(null,{status:503});
      return response;
    }
    return super.fetch(request);
  }
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith('/__fixture/')) {
      const [, , id, command] = url.pathname.split('/');
      return env.GROUP.get(env.GROUP.idFromName(id)).fetch(new Request('http://fixture/__' + command,request));
    }
    return production.fetch(request,env);
  }
};`;

let mf, options, nextId = 0;
const fresh = () => (++nextId).toString(16).padStart(32,'0');
const key = seq => `e:${String(seq).padStart(12,'0')}`;
const call = (path, body, mode) => mf.dispatchFetch(`http://127.0.0.1${path}`,
  body === undefined ? undefined : {method:'POST',headers:{'content-type':'application/json',
    ...(mode ? {'x-fixture-mode':mode} : {})},body:JSON.stringify(body)});
const seed = (id, values) => call(`/__fixture/${id}/seed`,values);
const rows = async id => (await call(`/__fixture/${id}/rows`)).json();
const prune = (id, expectedFloor, through, mode) => call(`/__fixture/${id}/prune`,{expectedFloor,through},mode);
const append = (id, expected_tail) => call(`/g/${id}/append`,{expected_tail,blob:'YQ=='});
const log = count => ({tail:count,capacity:{version:1,bytes:4*count,entries:count},
  ...Object.fromEntries(Array.from({length:count},(_,i)=>[key(i+1),'YQ==']))});

before(async () => {
  const root = fileURLToPath(new URL('./',import.meta.url));
  options = {modulesRoot:root,modules:[
    {type:'ESModule',path:`${root}/prefix-fixture.js`,contents:fixture},
    {type:'ESModule',path:`${root}/production-worker.js`,contents:await readFile(new URL('../src/worker.js',import.meta.url),'utf8')},
  ],durableObjects:{GROUP:{className:'Fixture',useSQLite:true},MAILBOX:'Mailbox'},
  bindings:{LOCAL_DEVELOPMENT:'true'},compatibilityDate:'2026-07-01'};
  mf = new Miniflare(options);
  await mf.ready;
});
after(async () => {await mf.dispose();});

test('prefix deletion refuses absent/denied guards and rolls back guard writes',async () => {
  const id = fresh(); await seed(id,log(3)); const before = await rows(id);
  for (const mode of ['missing','deny']) {
    assert.equal((await prune(id,0,3,mode)).status,403);
    assert.deepEqual(await rows(id),before);
  }
});

test('bounded prefix chunks preserve absolute sequences and reclaim exact capacity',async () => {
  const id = fresh(); await seed(id,log(33));
  assert.deepEqual(await (await prune(id,0,33)).json(),{floor:16,tail:33,more:true});
  let stored = Object.fromEntries(await rows(id));
  assert.equal(stored.tail,33); assert.equal(stored.floor,16);
  assert.deepEqual(stored.capacity,{version:1,bytes:68,entries:17});
  assert.equal(Object.keys(stored).filter(name=>name.startsWith('e:')).length,17);
  assert.equal((await call(`/g/${id}?after=0`)).status,410,'Never silently skip a missing prefix');
  const page = await (await call(`/g/${id}?after=16`)).json();
  assert.deepEqual(page.entries.map(entry=>entry.seq),Array.from({length:16},(_,i)=>17+i));
  assert.equal(page.more,true); assert.equal(page.tail,33);
  assert.equal((await prune(id,0,33)).status,409,'A stale request must not delete a second chunk');
  assert.deepEqual(await (await prune(id,16,33)).json(),{floor:32,tail:33,more:true});
  assert.deepEqual(await (await prune(id,32,33)).json(),{floor:33,tail:33,more:false});
  stored = Object.fromEntries(await rows(id));
  assert.deepEqual(stored.capacity,{version:1,bytes:0,entries:0});
  assert.deepEqual(await (await append(id,33)).json(),{seq:34});
  stored = Object.fromEntries(await rows(id));
  assert.equal(stored.floor,33); assert.equal(stored.tail,34);
  assert.deepEqual(stored.capacity,{version:1,bytes:4,entries:1});
  assert.deepEqual((await (await call(`/g/${id}?after=33`)).json()).entries,[{seq:34,blob:'YQ=='}]);
});

test('actual SQLite rolls back deletion, floor, counters and admission on interruption',async () => {
  for (const mode of ['after-delete','after-floor','after-capacity']) {
    const id = fresh(); await seed(id,log(17)); const before = await rows(id);
    assert.equal((await prune(id,0,16,mode)).status,503);
    assert.deepEqual(await rows(id),before,mode);
    assert.equal((await prune(id,0,16)).status,200);
  }
});

test('lost replies cannot delete a chunk twice and competing prefix requests serialize',async () => {
  const id = fresh(); await seed(id,log(33));
  assert.equal((await prune(id,0,33,'lost')).status,503);
  const committed = await rows(id);
  assert.equal((await prune(id,0,33)).status,409);
  assert.deepEqual(await rows(id),committed);
  const race = await Promise.all([prune(id,16,33),prune(id,16,33)]);
  assert.deepEqual(race.map(response=>response.status).sort(),[200,409]);
  assert.equal(Object.fromEntries(await rows(id)).floor,32);
});

test('append racing prefix reclamation retains the new absolute tail',async () => {
  const id = fresh(); await seed(id,log(33));
  const race = await Promise.all([prune(id,0,16),append(id,33)]);
  assert.deepEqual(race.map(response=>response.status),[200,200]);
  const stored = Object.fromEntries(await rows(id));
  assert.equal(stored.floor,16); assert.equal(stored.tail,34);
  assert.deepEqual(stored.capacity,{version:1,bytes:72,entries:18});
  assert.equal(stored[key(34)],'YQ==');
});

test('malformed or incomplete prefix accounting fails closed without mutation',async () => {
  const damaged = [
    {floor:-1},{floor:0.5},{floor:4},{tail:4.5},
    {capacity:{version:1,bytes:12,entries:2}},
    {capacity:{version:1,bytes:3,entries:3}},
    {capacity:{version:1,bytes:13,entries:3}},
    {[key(2)]:null},{[key(2)]:'not ciphertext !'},
  ];
  for (const change of damaged) {
    const id = fresh(); await seed(id,{...log(3),...change}); const before = await rows(id);
    assert.equal((await prune(id,0,3)).status,503,JSON.stringify(change));
    assert.deepEqual(await rows(id),before);
  }
  const id = fresh(); await seed(id,log(3)); const before = await rows(id);
  for (const input of [[-1,3],[0,0],[0,3.5],[0,Number.MAX_SAFE_INTEGER+1]]) {
    assert.equal((await prune(id,...input)).status,400);
    assert.deepEqual(await rows(id),before);
  }
  assert.equal((await prune(id,0,4)).status,409);
  assert.deepEqual(await rows(id),before);
});

test('reads reject unmarked holes rather than return a cursor-skipping page',async () => {
  const id = fresh(); await seed(id,{tail:2,[key(2)]:'YQ=='});
  assert.equal((await call(`/g/${id}?after=0`)).status,503);
  const tailMissing = fresh(); await seed(tailMissing,{tail:2,[key(1)]:'YQ=='});
  assert.equal((await call(`/g/${tailMissing}?after=0`)).status,503);
  assert.equal((await call(`/g/${tailMissing}?after=1`)).status,503);
});

test('an awaited authorizer cannot swap the already-validated deletion target',async () => {
  const id = fresh(); await seed(id,log(33));
  assert.deepEqual(await (await prune(id,0,3,'mutate-request')).json(),{floor:3,tail:33,more:false});
  const stored = Object.fromEntries(await rows(id));
  assert.equal(stored.floor,3);
  assert.deepEqual(stored.capacity,{version:1,bytes:120,entries:30});
});

test('the fixed-width absolute sequence ceiling remains ordered and never wraps',async () => {
  const maximum = 999999999999, id = fresh();
  await seed(id,{floor:maximum-2,tail:maximum-1,[key(maximum-1)]:'YQ==',
    capacity:{version:1,bytes:4,entries:1}});
  assert.equal((await append(id,maximum-1)).status,200);
  assert.deepEqual((await (await call(`/g/${id}?after=${maximum-1}`)).json()).entries,
    [{seq:maximum,blob:'YQ=='}]);
  const before = await rows(id);
  assert.equal((await append(id,maximum)).status,507);
  assert.deepEqual(await rows(id),before);
});

test('floor and reclaimed accounting survive actual workerd replacement',async () => {
  const id = fresh(); await seed(id,log(17)); await prune(id,0,16);
  const before = await rows(id);
  const instance = await (await call(`/__fixture/${id}/instance`)).json();
  await mf.setOptions({...options,bindings:{...options.bindings,RELOAD:'replacement'}});
  await mf.ready;
  const replacement = await (await call(`/__fixture/${id}/instance`)).json();
  assert.notEqual(replacement.instance,instance.instance,'Must actually replace the in-memory object');
  assert.deepEqual(await rows(id),before);
  assert.equal((await call(`/g/${id}?after=0`)).status,410);
  assert.equal((await append(id,17)).status,200);
});

test('production routing never exposes the fixture or a prefix-prune endpoint',async () => {
  const id = fresh();
  for (const path of [`/g/${id}/prune`,`/g/${id}/prefix`,`/__prune`,`/__seed`]) {
    const response = await call(path,{expectedFloor:0,through:3});
    assert.notEqual(response.status,200,path);
  }
});
