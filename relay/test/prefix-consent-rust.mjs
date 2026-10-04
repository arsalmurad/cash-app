// Offline synthetic interoperability. Output contains public proofs only.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../../',import.meta.url));
const relay=fileURLToPath(new URL('../',import.meta.url));
const run=(command,args,cwd,env)=>new Promise((resolve,reject)=>{
  const child=spawn(command,args,{cwd,env,windowsHide:true});let stdout='',stderr='';
  child.stdout.on('data',chunk=>{stdout+=chunk;});child.stderr.on('data',chunk=>{stderr+=chunk;});
  child.on('error',reject);child.on('close',code=>resolve({code,stdout,stderr}));
});
const fixture=await run(process.env.CARGO??'cargo',['run','--manifest-path','rust/Cargo.toml','--locked','--offline','--quiet',
  '-p','cash_sync','--features','relay-auth','--example','prefix_consent'],root,process.env);
assert.equal(fixture.code,0,fixture.stderr.slice(-2000));
assert(fixture.stdout.length<128*1024,'Bound public synthetic fixture output');
const result=await run(process.execPath,['--test','test/prefix-consent-interop.test.js'],relay,
  {...process.env,PREFIX_CONSENT_RUST_FIXTURE:fixture.stdout.trim()});
assert.equal(result.code,0,result.stderr.slice(-2000)+'\n'+result.stdout.slice(-2500));
process.stdout.write(result.stdout);
