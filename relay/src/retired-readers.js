// Public historical-read grants minted only by an accepted membership change.
// No current grants, payload copies, device names or financial history deletion.
const TTL=7*86400000;
const integer=value=>Number.isSafeInteger(value)&&value>=0;
const exact=(value,fields)=>value&&typeof value==='object'&&!Array.isArray(value)&&
  JSON.stringify(Object.keys(value).sort())===JSON.stringify([...fields].sort());
export class RetiredReaderRefused extends Error {
  constructor(status=503){super('retired historical read refused');this.status=status;}
}
export async function readRetiredReaders(txn) {
  const saved=await txn.get('retired_readers');
  if(saved===undefined) return {version:1,records:[]};
  if(!exact(saved,['version','records'])||saved.version!==1||!Array.isArray(saved.records)||saved.records.length>64||
    saved.records.some((record,index)=>!exact(record,['key','through','expires'])||
      typeof record.key!=='string'||record.key.length!==64||!/^[0-9a-f]{64}$/.test(record.key)||
      !integer(record.through)||record.through===0||!integer(record.expires)||
      (index>0&&record.key<=saved.records[index-1].key))) throw new RetiredReaderRefused();
  return {version:1,records:saved.records.map(record=>({...record}))};
}
export async function retiredReader(txn,key,now) {
  const floor=await txn.get('request_clock')??0;
  if(!integer(now)||!integer(floor)) throw new RetiredReaderRefused();
  return (await readRetiredReaders(txn)).records.find(record=>record.key===key&&record.expires>Math.max(now,floor))??null;
}
export async function updateRetiredReaders(txn,current,next,through,effectiveNow) {
  if(!integer(through)||through===0||!integer(effectiveNow)||effectiveNow>Number.MAX_SAFE_INTEGER-TTL) throw new RetiredReaderRefused();
  const saved=await readRetiredReaders(txn), after=new Set(next.devices.map(device=>device.key));
  const records=saved.records.filter(record=>record.expires>effectiveNow&&!after.has(record.key));
  for(const device of current.devices) {
    if(!after.has(device.key)&&device.operations.includes('read')) {
      if(records.some(record=>record.key===device.key)) throw new RetiredReaderRefused();
      records.push({key:device.key,through,expires:effectiveNow+TTL});
    }
  }
  if(records.length>64) throw new RetiredReaderRefused(507);
  records.sort((a,b)=>a.key<b.key?-1:a.key>b.key?1:0);
  await txn.put('retired_readers',{version:1,records});
  return records;
}
