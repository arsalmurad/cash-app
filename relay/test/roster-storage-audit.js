// Test-only exact-schema audit of real SQLite-backed roster relay KV records.
import assert from 'node:assert/strict';
import {validMembershipPolicy} from '../src/request-membership.js';

const exact=(value,fields)=>assert(value&&typeof value==='object'&&!Array.isArray(value)&&JSON.stringify(Object.keys(value).sort())===JSON.stringify([...fields].sort()));
const integer=value=>assert(Number.isSafeInteger(value)&&value>=0);
const id=value=>assert(typeof value==='string'&&/^[0-9a-f]{32}$/.test(value)&&value.length===32);
const list=(value,fields,sort)=>{
  exact(value,['version','records']); assert.equal(value.version,1);
  assert(Array.isArray(value.records)&&value.records.length<=64);
  let previous='';
  for(const record of value.records){exact(record,fields);assert(record[sort]>previous);previous=record[sort];}
  return value.records;
};
const ciphertext=(value,needles)=>{
  assert(typeof value==='string'&&value.length>0);
  const bytes=Buffer.from(value,'base64');
  assert.equal(bytes.toString('base64'),value);
  assert(bytes.length>0&&bytes.length<=256*1024);
  for(const needle of needles) assert(!bytes.includes(Buffer.from(needle)),'readable synthetic financial data');
};

export function auditRosterStorage(rows,root,manifest,needles) {
  assert(Array.isArray(rows)&&rows.length>0);
  const stored=new Map(rows); assert.equal(stored.size,rows.length);
  for(const key of ['authorization_root','authorized_devices','tail','request_clock','capacity','request_budget','welcome_index','invite_authorities','retired_readers']) {
    assert(stored.has(key),`missing required public metadata: ${key}`);
  }
  const policy=manifest.currentPolicy;
  assert(validMembershipPolicy(root)&&validMembershipPolicy(policy));
  assert.deepEqual(policy.scope,root.scope); assert(policy.epoch>root.epoch);
  assert.deepEqual(stored.get('authorization_root'),root);
  assert.deepEqual(stored.get('authorized_devices'),policy);
  const keys=manifest.publicKeys;
  assert(Array.isArray(keys)&&keys.length<=128&&new Set(keys).size===keys.length);
  for(const key of keys) assert(typeof key==='string'&&key.length===64&&/^[0-9a-f]{64}$/.test(key));
  const known=key=>assert(keys.includes(key));
  for(const device of [...root.devices,...policy.devices]) known(device.key);
  const tail=stored.get('tail'); integer(tail); assert(tail>20);
  const index=list(stored.get('welcome_index'),['id','recipient','sequence','expires'],'id');
  assert.equal(index.length,2,'audit must include actual old/new encrypted Welcomes');
  for(const record of index) {
    id(record.id); known(record.recipient); integer(record.sequence); assert(record.sequence>0&&record.sequence<=tail); integer(record.expires);
  }
  assert.deepEqual(index.map(record=>({id:record.id,recipient:record.recipient})),[...manifest.mailboxes].sort((a,b)=>a.id.localeCompare(b.id)));
  const retired=list(stored.get('retired_readers'),['key','through','expires'],'key');
  assert.equal(retired.length,1);
  for(const record of retired){known(record.key);integer(record.through);assert(record.through>0&&record.through<=tail);integer(record.expires);assert(!policy.devices.some(device=>device.key===record.key));}
  assert.deepEqual(retired.map(record=>({key:record.key,through:record.through})),manifest.retired);
  const authorities=list(stored.get('invite_authorities'),['key','sponsor','sequence','expires','mailbox'],'key');
  assert.equal(authorities.length,1);
  for(const record of authorities){
    known(record.key); known(record.sponsor); assert.notEqual(record.key,record.sponsor);
    assert(policy.devices.some(device=>device.key===record.key));
    integer(record.sequence); assert(record.sequence>0&&record.sequence<=tail); integer(record.expires); id(record.mailbox);
    const welcome=index.find(entry=>entry.id===record.mailbox);
    assert(welcome&&welcome.recipient===record.key&&welcome.sequence===record.sequence&&welcome.expires===record.expires);
  }
  let entries=0,bytes=0,welcomes=0,nonceKeys=0;
  for(const [key,value] of rows) {
    if(/^e:\d{12}$/.test(key)) {ciphertext(value,needles);entries++;bytes+=value.length;}
    else if(key.startsWith('welcome:')) {
      const record=index.find(entry=>`welcome:${entry.id}`===key); assert(record);
      exact(value,['version','recipient','sequence','expires','welcome','consumed']);assert.equal(value.version,1);
      assert.equal(value.recipient,record.recipient);assert.equal(value.sequence,record.sequence);assert.equal(value.expires,record.expires);
      assert.equal(value.consumed,true);ciphertext(value.welcome,needles);welcomes++;
    } else if(key==='authorization_root') assert.deepEqual(value,root);
    else if(key==='authorized_devices') assert.deepEqual(value,policy);
    else if(key==='tail'||key==='request_clock') integer(value);
    else if(key==='capacity') {exact(value,['version','entries','bytes']);assert.equal(value.version,1);integer(value.entries);integer(value.bytes);}
    else if(key==='request_budget') {
      exact(value,['version','day','used','devices']);assert.equal(value.version,1);integer(value.day);integer(value.used);assert(value.used<=20000);
      assert(Array.isArray(value.devices)&&value.devices.length<=64);let used=0,previous='';
      for(const device of value.devices){exact(device,['key','used']);known(device.key);assert(device.key>previous);previous=device.key;integer(device.used);assert(device.used>0&&device.used<=10000);used+=device.used;}
      assert.equal(used,value.used);
    } else if(key.startsWith('request_nonces:')) {
      known(key.slice('request_nonces:'.length));nonceKeys++;
      exact(value,['version','records']);assert.equal(value.version,1);assert(Array.isArray(value.records)&&value.records.length<=256);let previous='';
      for(const record of value.records){exact(record,['nonce','expires']);assert(typeof record.nonce==='string'&&record.nonce.length===64&&/^[0-9a-f]{64}$/.test(record.nonce));assert(record.nonce>previous);previous=record.nonce;integer(record.expires);}
    } else assert(['welcome_index','invite_authorities','retired_readers'].includes(key),'unexpected persisted roster field');
  }
  assert(nonceKeys>0&&nonceKeys<=128);assert.equal(welcomes,index.length);assert.equal(entries,tail);
  for(let sequence=1;sequence<=tail;sequence++) assert(stored.has(`e:${String(sequence).padStart(12,'0')}`));
  assert.deepEqual(stored.get('capacity'),{version:1,entries,bytes});
  const serialized=Buffer.from(JSON.stringify(rows));
  for(const needle of needles) assert(!serialized.includes(Buffer.from(needle)),'readable synthetic financial metadata');
  return {entries,welcomes,retired:retired.length,authorities:authorities.length};
}
