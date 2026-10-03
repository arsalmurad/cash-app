import assert from "node:assert/strict";
import { test } from "node:test";
import { validDevicePolicy, requestOperation } from "../src/request-scope.js";

const scope = { origin: "https://relay.example", kind: "g", id: "01".repeat(16) };
const context = { origin: scope.origin, method: "POST", path: `/g/${scope.id}/append`, query: "" };
const key = "ab".repeat(32);

test("only exact namespace, origin, method and known route resolve an operation", () => {
  assert.equal(requestOperation(context, scope), "append");
  for (const wrong of [
    {...context, origin: "https://other.example"},
    {...context, method: "PUT"},
    {...context, path: `/g/${"02".repeat(16)}/append`},
    {...context, path: `/m/${scope.id}/append`},
    {...context, path: context.path + "/extra"},
    {...context, path: context.path + "/"},
    {...context, query: "?ignored=true"},
  ]) assert.equal(requestOperation(wrong, scope), null);
});

test("group read permits only unambiguous bounded after cursors", () => {
  const read = {...context, method: "GET", path: `/g/${scope.id}`};
  for (const query of ["", "?after=0", "?after=10000"]) {
    assert.equal(requestOperation({...read, query}, scope), "read");
  }
  for (const query of ["?after=", "?after=-1", "?after=01", "?after=1&after=2",
    "?after=9007199254740992", "?after=1&other=2", "?after=1.5"]) {
    assert.equal(requestOperation({...read, query}, scope), null);
  }
});

test('group invitations bind exact delivery methods and forbid premature take or query aliases',()=>{
  const path=`/g/${scope.id}/invite/${'02'.repeat(16)}`;
  for(const [method,suffix,operation] of [['PUT','','membership'],['GET','','read'],['POST','/ack','read']]) {
    assert.equal(requestOperation({...context,method,path:path+suffix},scope),operation);
  }
  for(const [method,suffix] of [['POST',''],['GET','/ack'],['POST','/take'],['PUT','/'],['GET','/extra']]) {
    assert.equal(requestOperation({...context,method,path:path+suffix},scope),null);
  }
  assert.equal(requestOperation({...context,method:'GET',path,query:'?after=0'},scope),null);
  assert.equal(requestOperation({...context,method:'GET',path:path.replace('/invite/','/invite/%')},scope),null);
});

test("mailbox actions are distinct from group actions and from each other", () => {
  const mailbox = {...scope, kind: "m"};
  for (const [method, suffix, expected] of [
    ["PUT", "", "write"], ["GET", "", "read"], ["POST", "/take", "take"], ["POST", "/ack", "ack"],
  ]) assert.equal(requestOperation({...context, method, path: `/m/${scope.id}${suffix}`}, mailbox), expected);
  assert.equal(requestOperation({...context, method: "PUT", path: `/m/${scope.id}/ack`}, mailbox), null);
});

test("versioned per-device policy requires canonical bounded operation grants", () => {
  const policy = { version: 2, epoch: 3, scope, devices: [{key, operations: ["append", "read"]}] };
  assert(validDevicePolicy(policy));
  for (const devices of [[], [{key, operations: []}], [{key, operations: ["read", "append"]}],
    [{key, operations: ["read", "read"]}], [{key, operations: ["write"]}],
    [policy.devices[0], policy.devices[0]], Array.from({length: 65}, () => policy.devices[0])]) {
    assert.equal(validDevicePolicy({...policy, devices}), false);
  }
  assert.equal(validDevicePolicy({...policy, version: 1}), false);
  for (const origin of ["", "https://relay.example/", "https://user@relay.example", "http://relay.example"]) {
    assert.equal(validDevicePolicy({...policy, scope: {...scope, origin}}), false);
  }
});
