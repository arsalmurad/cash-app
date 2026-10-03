// Admission primitive only, not imported by production routing.
// Run inside the SAME storage transaction as the authorized mutation. Verify
// the signature against that exact request/DO scope before calling this helper.
import { isVerifiedRequestProof } from "./request-proof.js";

const HEX32 = /^[0-9a-f]{64}$/;
const MAX_DEVICES = 64;
const MAX_NONCES = 256;
const refuse = reason => ({ ok: false, reason });
const time = value => Number.isSafeInteger(value) && value >= 0;

export async function admitVerifiedDeviceRequest(txn, verified, now) {
  if (!isVerifiedRequestProof(verified) || !time(now)) return refuse("invalid");
  const roster = await txn.get("authorized_devices");
  if (!roster || roster.version !== 1 || !time(roster.epoch) ||
      !Array.isArray(roster.keys) || roster.keys.length === 0 || roster.keys.length > MAX_DEVICES ||
      roster.keys.some((key, index) => typeof key !== "string" || !HEX32.test(key) ||
        (index > 0 && key <= roster.keys[index - 1]))) return refuse("policy");
  if (!roster.keys.includes(verified.publicKey)) return refuse("unauthorized");

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
  return { ok: true, epoch: roster.epoch };
}
