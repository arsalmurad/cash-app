// Admission primitive only, not imported by production routing.
// Run inside the SAME storage transaction as the authorized mutation. Verify
// the signature against that exact request/DO scope before calling this helper.
import { isVerifiedRequestProof, verifiedRequestContext } from "./request-proof.js";
import { validDevicePolicy, requestOperation } from "./request-scope.js";
import { retiredReader } from './retired-readers.js';

const HEX32 = /^[0-9a-f]{64}$/;
const MAX_NONCES = 256;
const refuse = reason => ({ ok: false, reason });
const time = value => Number.isSafeInteger(value) && value >= 0;

export async function admitVerifiedDeviceRequest(txn, verified, now) {
  if (!isVerifiedRequestProof(verified) || !time(now)) return refuse("invalid");
  const roster = await txn.get("authorized_devices");
  if (!validDevicePolicy(roster)) return refuse("policy");
  const device = roster.devices.find(device => device.key === verified.publicKey);
  if (!device) return refuse("unauthorized");
  const operation = requestOperation(verifiedRequestContext(verified), roster.scope);
  if (!operation) return refuse("scope");
  if (!device.operations.includes(operation)) return refuse("permission");

  return admitNonce(txn,verified,now,roster.epoch);
}

// A separate authority check, never a caller-supplied bypass flag. Only exact
// group-history GETs by an absent current device with live stored cutoff qualify.
export async function admitRetiredReadRequest(txn,verified,now) {
  if(!isVerifiedRequestProof(verified)||!time(now)) return refuse('invalid');
  const roster=await txn.get('authorized_devices');
  if(!validDevicePolicy(roster)) return refuse('policy');
  const context=verifiedRequestContext(verified);
  if(roster.devices.some(device=>device.key===verified.publicKey)) return refuse('unauthorized');
  if(requestOperation(context,roster.scope)!=='read'||context.path!==`/g/${roster.scope.id}`) return refuse('scope');
  const retired=await retiredReader(txn,verified.publicKey,now);
  if(!retired) return refuse('unauthorized');
  const tail=await txn.get('tail');
  if(!time(tail)||retired.through>tail) return refuse('state');
  const admission=await admitNonce(txn,verified,now,roster.epoch);
  return admission.ok ? {...admission,through:retired.through} : admission;
}

async function admitNonce(txn,verified,now,epoch) {

  const clock = await txn.get("request_clock");
  if (clock !== undefined && !time(clock)) return refuse("state");
  const effectiveNow = Math.max(now, clock ?? now);
  if (verified.expires <= effectiveNow || verified.expires - effectiveNow > 60_000) return refuse("expired");

  const key = `request_nonces:${verified.publicKey}`;
  const saved = await txn.get(key);
  if (saved !== undefined && (!saved || saved.version !== 1 ||
      !Array.isArray(saved.records) || saved.records.length > MAX_NONCES ||
      (saved.records.length > 0 && clock === undefined))) return refuse("state");
  const records = saved?.records ?? [];
  if (records.some((record, index) => !record || typeof record.nonce !== "string" ||
      !HEX32.test(record.nonce) || !time(record.expires) ||
      (index > 0 && record.nonce <= records[index - 1].nonce))) return refuse("state");
  const live = records.filter(record => record.expires > effectiveNow);
  if (live.some(record => record.nonce === verified.nonce)) return refuse("replay");
  if (live.length >= MAX_NONCES) return refuse("capacity");
  live.push({ nonce: verified.nonce, expires: verified.expires });
  live.sort((a, b) => a.nonce < b.nonce ? -1 : a.nonce > b.nonce ? 1 : 0);
  await txn.put(key, { version: 1, records: live });
  await txn.put("request_clock", effectiveNow);
  return { ok: true, epoch };
}
