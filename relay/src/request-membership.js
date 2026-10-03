// Transaction-local primitive, NOT a routed signup/membership endpoint.
// Invoke from GroupLog's afterAppend hook inside the SAME SQLite transaction.
import { verifiedRequestContext, verifiedRequestDigest } from './request-proof.js';
import { validDevicePolicy, requestOperation } from './request-scope.js';
import { admitVerifiedDeviceRequest } from './request-admission.js';
import { spendRequestBudget } from './request-budget.js';
import { updateInviteAuthorities } from './invite-authority.js';

export class MembershipRefused extends Error {
  constructor(status) { super('membership transition refused'); this.status = status; }
}
const exact = (value, fields) => value && typeof value === 'object' && !Array.isArray(value) &&
  JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...fields].sort());
export function validMembershipPolicy(policy) {
  return validDevicePolicy(policy) && exact(policy, ['version', 'epoch', 'scope', 'devices']) &&
    exact(policy.scope, ['origin', 'kind', 'id']) && policy.scope.kind === 'g' &&
    policy.devices.every(device => exact(device, ['key', 'operations']) &&
      device.operations.every(operation => ['append', 'membership', 'read'].includes(operation))) &&
    policy.devices.some(device => device.operations.includes('membership'));
}

async function boundReplayKeys(txn, nextPolicy, effectiveNow) {
  const maximum = 128;
  // Bound the storage read itself. Do not scan/adopt an oversized legacy set.
  const stored = await txn.list({ prefix: 'request_nonces:', limit: maximum + 1 });
  if (stored.size > maximum) throw new MembershipRefused(503);
  const active = new Set(nextPolicy.devices.map(device => device.key));
  const retained = new Set(active);
  const expiredRetired = [];
  for (const [name, value] of stored) {
    const key = name.slice('request_nonces:'.length);
    if (!/^[0-9a-f]{64}$/.test(key) || !exact(value, ['version', 'records']) ||
        value.version !== 1 || !Array.isArray(value.records) || value.records.length > 256 ||
        value.records.some((record, index) => !exact(record, ['nonce', 'expires']) ||
          typeof record.nonce !== 'string' || !/^[0-9a-f]{64}$/.test(record.nonce) ||
          !Number.isSafeInteger(record.expires) || record.expires < 0 ||
          (index > 0 && record.nonce <= value.records[index - 1].nonce))) {
      throw new MembershipRefused(503);
    }
    if (!active.has(key) && value.records.every(record => record.expires <= effectiveNow)) {
      expiredRetired.push(name);
    } else {
      retained.add(key);
    }
  }
  if (retained.size > maximum) throw new MembershipRefused(429);
  for (const name of expiredRetired) await txn.delete(name);
}

export async function applyMembershipTransition(txn, verified, suppliedBody, now) {
  const refuse = status => { throw new MembershipRefused(status); };
  const context = verifiedRequestContext(verified);
  if (!context || !(suppliedBody instanceof Uint8Array) || suppliedBody.length > 512 * 1024) refuse(401);
  // Freeze the exact bytes before awaiting; a caller cannot swap the proposal.
  const body = Uint8Array.from(suppliedBody);
  const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', body)),
    byte => byte.toString(16).padStart(2, '0')).join('');
  if (digest !== verifiedRequestDigest(verified)) refuse(401);
  let proposal;
  try { proposal = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(body)); }
  catch { refuse(400); }
  if (!exact(proposal, ['expected_tail', 'blob', 'policy']) ||
      !Number.isSafeInteger(proposal.expected_tail) || proposal.expected_tail < 0 ||
      proposal.expected_tail >= Number.MAX_SAFE_INTEGER || !validMembershipPolicy(proposal.policy)) refuse(400);
  const current = await txn.get('authorized_devices');
  if (!validMembershipPolicy(current)) refuse(503);
  if (requestOperation(context, current.scope) !== 'membership') refuse(403);
  if (['origin', 'kind', 'id'].some(field => proposal.policy.scope[field] !== current.scope[field]) ||
      current.epoch >= Number.MAX_SAFE_INTEGER || proposal.policy.epoch !== current.epoch + 1) refuse(409);
  const sequence = proposal.expected_tail + 1;
  if (await txn.get('tail') !== sequence ||
      await txn.get(`e:${String(sequence).padStart(12, '0')}`) !== proposal.blob) refuse(409);
  const admission = await admitVerifiedDeviceRequest(txn, verified, now);
  if (!admission.ok) refuse(admission.reason === 'replay' ? 409 :
    admission.reason === 'expired' ? 401 : admission.reason === 'capacity' ? 429 : 403);
  const effectiveNow = await txn.get('request_clock');
  await spendRequestBudget(txn, verified, effectiveNow);
  await boundReplayKeys(txn, proposal.policy, effectiveNow);
  await updateInviteAuthorities(txn, current, proposal.policy, verified.publicKey, sequence, effectiveNow);
  // Retain live revoked replay records and all spent budgets. Only expired
  // retired nonce keys are removed, never ciphertext or current-device state.
  await txn.put('authorized_devices', proposal.policy);
  return sequence;
}
