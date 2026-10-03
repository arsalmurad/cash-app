import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readInviteAuthorities, updateInviteAuthorities } from '../src/invite-authority.js';

const a='01'.repeat(32), b='02'.repeat(32), c='03'.repeat(32), now=1790000000000;
const policy = keys => ({devices:keys.map(key=>({key}))});
const store = () => {
  const values=new Map();
  return {values,async get(key){return structuredClone(values.get(key));},
    async put(key,value){values.set(key,structuredClone(value));}};
};

test('accepted additions bind original sponsor, slot and immutable expiry; removal/re-add never revives old authority',async()=>{
  const txn=store();
  await updateInviteAuthorities(txn,policy([a]),policy([a,b]),a,1,now);
  const first=await readInviteAuthorities(txn);
  assert.deepEqual(first,{version:1,records:[{key:b,sponsor:a,sequence:1,expires:now+7*86400000,mailbox:null}]});
  first.records[0].mailbox='04'.repeat(16);
  await txn.put('invite_authorities',first);
  await updateInviteAuthorities(txn,policy([a,b]),policy([a,b,c]),a,2,now+1000);
  let current=await readInviteAuthorities(txn);
  assert.deepEqual(current.records[0],first.records[0],'later epochs must not reset expiry or one-mailbox binding');
  assert.equal(current.records[1].sequence,2);
  await updateInviteAuthorities(txn,policy([a,b,c]),policy([a,c]),a,3,now+2000);
  assert.deepEqual((await readInviteAuthorities(txn)).records.map(record=>record.key),[c]);
  await updateInviteAuthorities(txn,policy([a,c]),policy([a,b,c]),a,4,now+3000);
  current=await readInviteAuthorities(txn);
  assert.equal(current.records[0].sequence,4);
  assert.equal(current.records[0].mailbox,null);
  assert.equal(current.records[0].expires,now+3000+7*86400000);
  current.records.length=0;
  assert.equal((await readInviteAuthorities(txn)).records.length,2,'returned metadata cannot mutate stored authority');
});

test('expiry uses supplied admitted clock and does not mint permissions for unchanged/root devices',async()=>{
  const txn=store();
  await updateInviteAuthorities(txn,policy([a]),policy([a,b]),a,1,now);
  await updateInviteAuthorities(txn,policy([a,b]),policy([a,b]),a,2,now+7*86400000);
  assert.deepEqual(await readInviteAuthorities(txn),{version:1,records:[]});
});

test('damaged or oversized authority fails closed instead of discarding records',async()=>{
  const txn=store();
  const valid={key:b,sponsor:a,sequence:1,expires:now,mailbox:null};
  for (const value of [null,{}, {version:1,records:[{...valid,amount:2050}]},
    {version:1,records:[{...valid,sponsor:b}]}, {version:1,records:[{...valid,sequence:0}]},
    {version:1,records:[{...valid,expires:-1}]}, {version:1,records:[{...valid,mailbox:'bad'}]},
    {version:1,records:[valid,valid]}, {version:1,records:Array(65).fill(valid)},
  ]) {
    await txn.put('invite_authorities',value);
    await assert.rejects(updateInviteAuthorities(txn,policy([a]),policy([a,b]),a,1,now),error=>error.status===503);
    assert.deepEqual(await txn.get('invite_authorities'),value);
  }
});
