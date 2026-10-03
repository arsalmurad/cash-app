// Transaction-local public delivery authority, not enrolment or an endpoint.
// Derive only from an accepted policy transition in the ciphertext transaction.
const TTL = 7 * 24 * 60 * 60 * 1000;
const exact = (value, fields) => value && typeof value === 'object' && !Array.isArray(value) &&
  JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...fields].sort());
const key = value => typeof value === 'string' && value.length === 64 && /^[0-9a-f]{64}$/.test(value);
const id = value => typeof value === 'string' && value.length === 32 && /^[0-9a-f]{32}$/.test(value);
const integer = value => Number.isSafeInteger(value) && value >= 0;
export class InviteAuthorityRefused extends Error {
  constructor() {super('invalid invitation authority');this.status=503;}
}

export async function readInviteAuthorities(txn) {
  const saved = await txn.get('invite_authorities');
  if (saved === undefined) return {version:1,records:[]};
  if (!exact(saved,['version','records']) || saved.version !== 1 ||
      !Array.isArray(saved.records) || saved.records.length > 64 ||
      saved.records.some((record,index) => !exact(record,['key','sponsor','sequence','expires','mailbox']) ||
        !key(record.key) || !key(record.sponsor) || record.key === record.sponsor ||
        !integer(record.sequence) || record.sequence === 0 || !integer(record.expires) ||
        !(record.mailbox === null || id(record.mailbox)) ||
        (index > 0 && record.key <= saved.records[index-1].key))) {
    throw new InviteAuthorityRefused();
  }
  return {version:1,records:saved.records.map(record => ({...record}))};
}

export async function updateInviteAuthorities(txn,current,next,sponsor,sequence,effectiveNow) {
  if (!key(sponsor) || !integer(sequence) || sequence === 0 ||
      !integer(effectiveNow) || effectiveNow > Number.MAX_SAFE_INTEGER - TTL) {
    throw new InviteAuthorityRefused();
  }
  const saved = await readInviteAuthorities(txn);
  const before = new Set(current.devices.map(device => device.key));
  const after = new Set(next.devices.map(device => device.key));
  const records = saved.records.filter(record => after.has(record.key) && record.expires > effectiveNow);
  for (const device of next.devices) {
    if (!before.has(device.key)) {
      if (device.key === sponsor) throw new InviteAuthorityRefused();
      records.push({key:device.key,sponsor,sequence,expires:effectiveNow+TTL,mailbox:null});
    }
  }
  if (records.length > 64) throw new InviteAuthorityRefused();
  records.sort((a,b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
  await txn.put('invite_authorities',{version:1,records});
}
