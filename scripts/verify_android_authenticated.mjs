// Owns only a named disposable emulator, one random reverse tunnel, an isolated
// SQLite worker and the Flutter command tree this driver launches. No cloud.
import assert from 'node:assert/strict';
import {execFile, spawn} from 'node:child_process';
import {createWriteStream} from 'node:fs';
import {createServer} from 'node:net';
import {dirname, join} from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {promisify} from 'node:util';
import {validMembershipPolicy} from '../relay/src/request-membership.js';

const {Miniflare}=createRequire(new URL('../relay/package.json',import.meta.url))('miniflare');
const run=promisify(execFile);
const root=dirname(dirname(fileURLToPath(import.meta.url)));
const adb=process.env.ADB_BINARY??'D:/Android/Sdk/platform-tools/adb.exe';
const serial=process.env.ANDROID_DEVICE_SERIAL??'emulator-5580';
assert.match(serial,/^emulator-\d+$/,'Never run on a physical device');
const device=async(...args)=>(await run(adb,['-s',serial,...args],{windowsHide:true,timeout:20_000})).stdout;
assert.equal((await device('emu','avd','name')).split(/\r?\n/)[0].trim(),'Phase0Api36');
assert.equal((await device('shell','getprop','sys.boot_completed')).trim(),'1');
const reservation=createServer();
await new Promise((resolve,reject)=>{reservation.once('error',reject);reservation.listen(0,'127.0.0.1',resolve);});
const port=reservation.address().port;
await new Promise(resolve=>reservation.close(resolve));
const origin=`http://127.0.0.1:${port}`;
await device('reverse',`tcp:${port}`,`tcp:${port}`);
const log=createWriteStream(join(root,'app/.dart_tool/android-authenticated-http.log'));
let worker,child,closed=false,complete,resolveBootstrap,rejectBootstrap;
const bootstrap=new Promise((resolve,reject)=>{resolveBootstrap=resolve;rejectBootstrap=reject;});
let timer;
const deadline=new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Owned Android authenticated journey timed out')),15*60_000);});
try {
  const flutter=join(root,'.toolchains/flutter/bin/flutter.bat');
  const command=`""${flutter}" --no-version-check test --no-pub integration_test/authenticated_household_test.dart -d ${serial} --dart-define=AUTH_RELAY_ORIGIN=${origin} --reporter expanded"`;
  child=spawn(process.env.COMSPEC??'cmd.exe',['/d','/s','/c',command],{
    cwd:join(root,'app'),env:process.env,windowsHide:true,windowsVerbatimArguments:true,
    stdio:['ignore','pipe','pipe'],
  });
  complete=new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',code=>{closed=true;resolve(code);});});
  let pending='',seen=false;
  const output=chunk=>{
    const value=chunk.toString();log.write(value);pending+=value;
    const lines=pending.split(/\r?\n/);pending=lines.pop();
    for(const line of lines) {
      const match=line.match(/ANDROID_AUTH_BOOTSTRAP:(\{.*\})\s*$/);
      if(!match||seen) continue;
      seen=true;
      try {
        assert(match[1].length<=4096);
        const policy=JSON.parse(match[1]);
        assert(validMembershipPolicy(policy));
        assert.equal(policy.scope.origin,origin);
        assert.equal(policy.epoch,0);assert.equal(policy.devices.length,1);
        resolveBootstrap(policy);
      } catch(error) {rejectBootstrap(error);}
    }
  };
  child.stdout.on('data',output);child.stderr.on('data',output);
  const policy=await Promise.race([bootstrap,deadline,complete.then(code=>{throw new Error(`Flutter ended before public setup export (${code}); see owned log`);})]);
  console.log('Accepted public Android founding setup; starting owned SQLite relay.');
  worker=new Miniflare({
    modules:true,modulesRules:[{type:'ESModule',include:['**/*.js']}],
    scriptPath:join(root,'relay/src/roster-worker.js'),
    durableObjects:{GROUP:{className:'RosterGroupLog',useSQLite:true}},
    bindings:{LOCAL_DEVELOPMENT:'true',LOCAL_AUTH_MEMBERSHIP:'true',LOCAL_AUTH_POLICY:JSON.stringify(policy)},
    compatibilityDate:'2026-07-01',host:'127.0.0.1',port,
  });
  await Promise.race([worker.ready,deadline]);
  assert.equal((await fetch(`${origin}/g/${policy.scope.id}`)).status,401,'No anonymous household history');
  assert.equal(await Promise.race([complete,deadline]),0,'Android Flutter assertions must all pass; see owned log');
  console.log('PASS: Android native authenticated HTTP, three protected peers, restart, consumed invitations, encrypted expenses and retired-member catch-up.');
} finally {
  clearTimeout(timer);
  if(child&&!closed) {
    // Only the exact command tree spawned here; never Java/shared emulators.
    await run('taskkill.exe',['/PID',String(child.pid),'/T','/F'],{windowsHide:true}).catch(()=>{});
  }
  if(worker) await worker.dispose();
  await device('reverse','--remove',`tcp:${port}`);
  await new Promise(resolve=>log.end(resolve));
}
