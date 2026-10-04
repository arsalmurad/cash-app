// Explicit, short-lived all-current-key permission. Not a saved-state receipt,
// account signup, private archive, or substitute for protected client saves.
import {validDevicePolicy} from './request-scope.js';
const utf8=new TextEncoder(), decode=new TextDecoder('utf-8',{fatal:true});
const domain=utf8.encode('cash-app prefix retention consent v1\0');
const history=utf8.encode('cash-app authenticated history v1\0');
const verifiedBundles=new WeakMap();
const hex=value=>Array.from(value,byte=>byte.toString(16).padStart(2,'0')).join('');
const join=values=>{const result=new Uint8Array(values.reduce((sum,value)=>sum+value.length,0));let offset=0;
  for(const value of values) {result.set(value,offset);offset+=value.length;}return result;};
const field=value=>{const length=new Uint8Array(8);new DataView(length.buffer).setBigUint64(0,BigInt(value.length),false);return join([length,value]);};
const integer=value=>Number.isSafeInteger(value)&&value>=0;
function parse(value,now) {
  if(typeof value!=='string'||value.length>2048||value.length%2||!/^[0-9a-f]+$/.test(value)) throw new Error('invalid consent');
  const bytes=Uint8Array.from(value.match(/../g),part=>Number.parseInt(part,16));let offset=0;
  const take=count=>{if(count<0||offset+count>bytes.length) throw new Error('short consent');
    const result=bytes.slice(offset,offset+count);offset+=count;return result;};
  const number=()=>{const part=take(8);const value=new DataView(part.buffer).getBigUint64(0,false);
    if(value>BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('unsafe consent integer');return Number(value);};
  const bounded=max=>{const size=number();if(size===0||size>max) throw new Error('oversized consent field');return take(size);};
  if(hex(take(domain.length))!==hex(domain)) throw new Error('wrong consent domain');
  const origin=decode.decode(bounded(256)),id=decode.decode(take(32)),group=bounded(256);
  const epoch=number(),through=number(),checkpoint=hex(take(32)),holder=hex(take(32)),expires=number(),key=hex(take(32));
  const payload=bytes.slice(0,offset),signature=take(64);
  const base=new URL(origin);
  if(offset!==bytes.length||base.origin!==origin||!(base.protocol==='https:'||
      (base.protocol==='http:'&&['127.0.0.1','localhost','[::1]'].includes(base.hostname)))||
      !/^[0-9a-f]{32}$/.test(id)||through===0||through>999_999_999_999||expires<=now||expires-now>60000) throw new Error('invalid consent context');
  return {origin,id,group:hex(group),epoch,through,checkpoint,holder,expires,key,
    common:hex(payload.slice(0,-32)),signature,payload:join([history,field(group),field(payload)])};
}

export async function verifyPrefixConsentBundle(supplied,now) {
  if(!integer(now)||!Array.isArray(supplied)||supplied.length===0||supplied.length>64) return null;
  // Freeze primitive copies before crypto awaits; caller mutation cannot replace
  // approved keys, expiry, checkpoint, recovery holder or deletion target.
  const encoded=[...supplied];
  try {
    const claims=encoded.map(value=>parse(value,now)),first=claims[0];
    const keys=claims.map(claim=>claim.key).sort();
    if(keys.some((key,index)=>index&&key===keys[index-1])||
        claims.some(claim=>claim.common!==first.common)||!keys.includes(first.holder)) return null;
    const valid=await Promise.all(claims.map(async claim=>{
      const key=await crypto.subtle.importKey('raw',Uint8Array.from(claim.key.match(/../g),part=>Number.parseInt(part,16)),
        'Ed25519',false,['verify']);
      return crypto.subtle.verify('Ed25519',key,claim.signature,claim.payload);
    }));
    if(valid.some(value=>value!==true)) return null;
    const token=Object.freeze({});
    verifiedBundles.set(token,Object.freeze({origin:first.origin,id:first.id,epoch:first.epoch,
      through:first.through,holder:first.holder,expires:first.expires,keys:Object.freeze(keys)}));
    return token;
  } catch {return null;}
}

export const prefixConsentHolder=token=>verifiedBundles.get(token)?.holder??null;

// Invoke inside EACH deletion transaction, after verification and before any
// conflict metadata or deletion. A fabricated JSON token cannot authorize it.
export async function authorizePrefixConsents(txn,token,context,now) {
  const consent=verifiedBundles.get(token);
  if(!consent||!integer(now)||consent.through!==context.through) return false;
  const clock=await txn.get('request_clock');
  if(clock!==undefined&&!integer(clock)) return false;
  const effective=Math.max(now,clock??now);
  if(consent.expires<=effective||consent.expires-effective>60000) return false;
  const policy=await txn.get('authorized_devices');
  if(!validDevicePolicy(policy)||policy.scope.kind!=='g'||policy.scope.origin!==consent.origin||
      policy.scope.id!==consent.id||policy.epoch!==consent.epoch||policy.devices.length!==consent.keys.length||
      policy.devices.some((device,index)=>device.key!==consent.keys[index]||!device.operations.includes('read'))) return false;
  const holder=policy.devices.find(device=>device.key===consent.holder);
  return holder?.operations.includes('membership')===true;
}
