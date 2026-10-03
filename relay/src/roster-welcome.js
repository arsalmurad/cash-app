// Protected, bounded ciphertext delivery inside the group transaction. Public
// authority comes from an accepted membership slot, never a mailbox request.
import { readInviteAuthorities } from './invite-authority.js';
import { verifiedRequestContext, verifiedRequestDigest } from './request-proof.js';
import { inviteRequest } from './request-scope.js';
const exact=(value,fields)=>value && typeof value==='object' && !Array.isArray(value) &&
  JSON.stringify(Object.keys(value).sort())===JSON.stringify([...fields].sort());
const integer=value=>Number.isSafeInteger(value) && value>=0;
const hex=(value,length)=>typeof value==='string' && value.length===length && /^[0-9a-f]+$/.test(value);
const name=id=>`welcome:${id}`;
export class WelcomeRefused extends Error {
  constructor(status){super('invitation delivery refused');this.status=status;}
}
const refuse=status=>{throw new WelcomeRefused(status);};
const ciphertext=value=>{
  if(typeof value!=='string' || value.length>349528) return false;
  try {const bytes=atob(value);return bytes.length>0 && bytes.length<=256*1024 && btoa(bytes)===value;}
  catch{return false;}
};
async function index(txn) {
  const saved=await txn.get('welcome_index');
  if(saved===undefined) return {version:1,records:[]};
  if(!exact(saved,['version','records']) || saved.version!==1 || !Array.isArray(saved.records) || saved.records.length>64 ||
    saved.records.some((record,i)=>!exact(record,['id','recipient','sequence','expires']) ||
      !hex(record.id,32) || !hex(record.recipient,64) || !integer(record.sequence) || record.sequence===0 ||
      !integer(record.expires) || (i>0 && record.id<=saved.records[i-1].id))) refuse(503);
  return {version:1,records:saved.records.map(record=>({...record}))};
}
async function item(txn,record) {
  const value=await txn.get(name(record.id));
  if(!exact(value,['version','recipient','sequence','expires','welcome','consumed']) || value.version!==1 ||
    value.recipient!==record.recipient || value.sequence!==record.sequence || value.expires!==record.expires ||
    typeof value.consumed!=='boolean' || !ciphertext(value.welcome)) refuse(503);
  return {...value};
}
async function effectiveTime(txn,now) {
  const clock=await txn.get('request_clock');
  if(!integer(now) || (clock!==undefined && !integer(clock))) refuse(503);
  return Math.max(now,clock??now);
}
async function expire(txn,inventory,now) {
  const live=[];
  for(const record of inventory.records) {
    if(record.expires<=now) {
      await item(txn,record); // Corruption is not permission to silently discard.
      await txn.delete(name(record.id));
    } else live.push(record);
  }
  return {version:1,records:live};
}
async function saveIndex(txn,inventory) {
  inventory.records.sort((a,b)=>a.id<b.id?-1:a.id>b.id?1:0);
  await txn.put('welcome_index',inventory);
  if(inventory.records.length) await txn.setAlarm(Math.min(...inventory.records.map(record=>record.expires)));
  else await txn.deleteAlarm();
}
export async function expireWelcomes(txn,now) {
  const time=await effectiveTime(txn,now);
  await saveIndex(txn,await expire(txn,await index(txn),time));
  await txn.put('request_clock',time); // Never forget a trusted alarm-time observation.
}

export async function applyWelcomeRequest(txn,verified,suppliedBody,now) {
  const policy=await txn.get('authorized_devices');
  const route=inviteRequest(verifiedRequestContext(verified),policy.scope);
  if(!route || !(suppliedBody instanceof Uint8Array) || suppliedBody.length>512*1024) refuse(403);
  const body=Uint8Array.from(suppliedBody);
  const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',body)),byte=>byte.toString(16).padStart(2,'0')).join('');
  if(digest!==verifiedRequestDigest(verified)) refuse(401);
  const time=await effectiveTime(txn,now);
  let inventory=await index(txn);
  const authorities=await readInviteAuthorities(txn);
  if(route.action==='put') {
    let proposal;
    try{proposal=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(body));}catch{refuse(400);}
    if(!exact(proposal,['recipient','joined_after','welcome']) || !hex(proposal.recipient,64) ||
      !integer(proposal.joined_after) || proposal.joined_after===0 || !ciphertext(proposal.welcome)) refuse(400);
    const authority=authorities.records.find(record=>record.key===proposal.recipient);
    if(!authority || authority.sponsor!==verified.publicKey || authority.sequence!==proposal.joined_after ||
      authority.expires<=time || !policy.devices.some(device=>device.key===authority.key)) refuse(403);
    if(authority.mailbox!==null && authority.mailbox!==route.id) refuse(409);
    inventory=await expire(txn,inventory,time);
    const existing=inventory.records.find(record=>record.id===route.id);
    if(existing) {
      const stored=await item(txn,existing);
      if(stored.recipient!==proposal.recipient || stored.sequence!==proposal.joined_after ||
        stored.expires!==authority.expires || stored.welcome!==proposal.welcome) refuse(409);
      if(authority.mailbox!==route.id) refuse(503);
    } else {
      if(authority.mailbox!==null) refuse(503);
      if(inventory.records.length>=64) refuse(507);
      inventory.records.push({id:route.id,recipient:authority.key,sequence:authority.sequence,expires:authority.expires});
      await txn.put(name(route.id),{version:1,recipient:authority.key,sequence:authority.sequence,
        expires:authority.expires,welcome:proposal.welcome,consumed:false});
      authority.mailbox=route.id;
      await txn.put('invite_authorities',authorities);
    }
    await saveIndex(txn,inventory);
    return {ok:true};
  }
  if(body.length!==0) refuse(400);
  const record=inventory.records.find(record=>record.id===route.id);
  if(!record || record.expires<=time) refuse(404);
  if(record.recipient!==verified.publicKey) refuse(403);
  const authority=authorities.records.find(entry=>entry.key===record.recipient);
  if(!authority || authority.sequence!==record.sequence || authority.mailbox!==record.id ||
      authority.expires!==record.expires) refuse(403);
  const stored=await item(txn,record);
  if(route.action==='ack') {
    stored.consumed=true;
    await txn.put(name(route.id),stored);
    return {ok:true};
  }
  if(stored.consumed) refuse(404);
  return {group:policy.scope.id,joined_after:stored.sequence,welcome:stored.welcome};
}
