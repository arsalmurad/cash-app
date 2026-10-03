// Transaction-local admission budget, not an account-wide billing guarantee.
// Call only after current-policy/nonce admission, in the operation transaction.
import { isVerifiedRequestProof } from "./request-proof.js";

const DAY = 86_400_000;
const DEVICE_LIMIT = 10_000;
const GROUP_LIMIT = 20_000;
const HEX32 = /^[0-9a-f]{64}$/;
const integer = value => Number.isSafeInteger(value) && value >= 0;
const exact = (value, fields) => value && typeof value === "object" && !Array.isArray(value) &&
  JSON.stringify(Object.keys(value).sort()) === JSON.stringify(fields);

export class RequestBudgetRefused extends Error {
  constructor(status, retryAfter = null) {
    super("request budget refused");
    this.status = status;
    this.retryAfter = retryAfter;
  }
}

export function emptyRequestBudget(now) {
  if (!integer(now)) throw new RequestBudgetRefused(503);
  return { version: 1, day: Math.floor(now / DAY), used: 0, devices: [] };
}

export async function spendRequestBudget(txn, verified, effectiveNow) {
  if (!isVerifiedRequestProof(verified) || !integer(effectiveNow)) throw new RequestBudgetRefused(503);
  const saved = await txn.get("request_budget");
  if (!exact(saved, ["day", "devices", "used", "version"]) || saved.version !== 1 ||
      !integer(saved.day) || !integer(saved.used) || saved.used > GROUP_LIMIT ||
      !Array.isArray(saved.devices) || saved.devices.length > 64 ||
      saved.devices.some((device, index) => !exact(device, ["key", "used"]) ||
        typeof device.key !== "string" || !HEX32.test(device.key) ||
        !integer(device.used) || device.used === 0 || device.used > DEVICE_LIMIT ||
        (index > 0 && device.key <= saved.devices[index - 1].key)) ||
      saved.devices.reduce((sum, device) => sum + device.used, 0) !== saved.used) {
    throw new RequestBudgetRefused(503);
  }
  const day = Math.floor(effectiveNow / DAY);
  if (day < saved.day) throw new RequestBudgetRefused(503);
  const current = day === saved.day ? saved : emptyRequestBudget(effectiveNow);
  const devices = current.devices.map(device => ({ ...device }));
  let device = devices.find(device => device.key === verified.publicKey);
  const retryAfter = Math.ceil((DAY - effectiveNow % DAY) / 1000);
  if (current.used >= GROUP_LIMIT || (device?.used ?? 0) >= DEVICE_LIMIT ||
      (!device && devices.length >= 64)) throw new RequestBudgetRefused(429, retryAfter);
  if (!device) { device = {key: verified.publicKey, used: 0}; devices.push(device); }
  device.used++;
  devices.sort((a,b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
  await txn.put("request_budget", {version: 1, day, used: current.used + 1, devices});
}
