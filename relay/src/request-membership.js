// Transaction-local primitive, NOT a routed signup/membership endpoint.
// Invoke from GroupLog's afterAppend hook inside the SAME SQLite transaction.
import { verifiedRequestContext, verifiedRequestDigest } from './request-proof.js';
import { validDevicePolicy, requestOperation } from './request-scope.js';
import { admitVerifiedDeviceRequest } from './request-admission.js';
import { spendRequestBudget } from './request-budget.js';

export class MembershipRefused extends Error {
  constructor(status) { super('membership transition refused'); this.status = status; }
}
const exact = (value, fields) => value && typeof value === 'object' && !Array.isArray(value) &&
  JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...fields].sort());
function policyShape(policy) {
  return validDevicePolicy(policy) && exact(policy, ['version', 'epoch', 'scope', 'devices']) &&
    exact(policy.scope, ['origin', 'kind', 'id']) && policy.scope.kind === 'g' &&
    policy.devices.every(device => exact(device, ['key', 'operations']) &&
      device.operations.every(operation => ['append', 'membership', 'read'].includes(operation))) &&
    policy.devices.some(device => device.operations.includes('membership'));
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
      proposal.expected_tail >= Number.MAX_SAFE_INTEGER || !policyShape(proposal.policy)) refuse(400);
  const current = await txn.get('authorized_devices');
  if (!policyShape(current)) refuse(503);
  if (requestOperation(context, current.scope) !== 'membership') refuse(403);
  if (['origin', 'kind', 'id'].some(field => proposal.policy.scope[field] !== current.scope[field]) ||
      current.epoch >= Number.MAX_SAFE_INTEGER || proposal.policy.epoch !== current.epoch + 1) refuse(409);
  const sequence = proposal.expected_tail + 1;
  if (await txn.get('tail') !== sequence ||
      await txn.get(`e:${String(sequence).padStart(12, '0')}`) !== proposal.blob) refuse(409);
  const admission = await admitVerifiedDeviceRequest(txn, verified, now);
  if (!admission.ok) refuse(admission.reason === 'replay' ? 409 :
    admission.reason === 'expired' ? 401 : admission.reason === 'capacity' ? 429 : 403);
  await spendRequestBudget(txn, verified, await txn.get('request_clock'));
  // Keep old replay records and spent budgets: remove/re-add must not reset them.
  await txn.put('authorized_devices', proposal.policy);
  return sequence;
}
