// Explicit operator-bootstrapped loopback experiment, not public signup.
import { GroupLog } from './worker.js';
import { configuredPolicy, boundedBody } from './local-auth-worker.js';
import { verifyRequestProof, verifiedRequestContext } from './request-proof.js';
import { requestOperation, inviteRequest } from './request-scope.js';
import { applyWelcomeRequest, expireWelcomes, WelcomeRefused } from './roster-welcome.js';
import { admitVerifiedDeviceRequest } from './request-admission.js';
import { emptyRequestBudget, spendRequestBudget, RequestBudgetRefused } from './request-budget.js';
import { validMembershipPolicy, applyMembershipTransition, MembershipRefused } from './request-membership.js';

const json = (body, status = 200) => Response.json(body, {status});
const fail = status => json({error:'local roster request refused; history preserved'},status);
const loopback = url => ['127.0.0.1','localhost','[::1]'].includes(url.hostname);
const sameScope = (a,b) => ['origin','kind','id'].every(field => a[field] === b[field]);
function trustedRoot(env) {
  if (env.LOCAL_DEVELOPMENT !== 'true' || env.LOCAL_AUTH_MEMBERSHIP !== 'true') return null;
  const root = configuredPolicy(env,true);
  try {
    return root && validMembershipPolicy(JSON.parse(env.LOCAL_AUTH_POLICY)) ? root : null;
  } catch {return null;}
}
const acceptable = (policy, root) => validMembershipPolicy(policy) &&
  sameScope(policy.scope,root.scope) && policy.epoch >= root.epoch;

export class RosterGroupLog extends GroupLog {
  constructor(state,env) {super(state);this.env=env;}
  async fetch(request) {
    try {return await this.authenticatedFetch(request);}
    catch (error) {
      const response = fail(error instanceof MembershipRefused || error instanceof RequestBudgetRefused || error instanceof WelcomeRefused ? error.status : 503);
      if (error instanceof RequestBudgetRefused && error.retryAfter !== null) response.headers.set('retry-after',String(error.retryAfter));
      return response;
    }
  }
  async authenticatedFetch(request) {
    const url = new URL(request.url);
    const root = trustedRoot(this.env);
    if (!root || !loopback(url)) return fail(503);
    const operation = requestOperation({origin:url.origin,method:request.method,path:url.pathname,query:url.search},root.scope);
    if (!['read','append','membership'].includes(operation)) return fail(403);
    let proof;
    try {
      const header=request.headers.get('x-cash-device-proof');
      if (!header || header.length > 1024) return fail(401);
      proof=JSON.parse(header);
    } catch {return fail(401);}
    // Candidate verification uses a trusted saved roster snapshot, never the
    // request's desired policy. The transaction rechecks grants after awaits.
    const snapshot = await this.state.storage.get('authorized_devices') ?? root;
    if (!acceptable(snapshot,root)) return fail(503);
    const device=snapshot.devices.find(device=>device.key===proof?.publicKey);
    if (!device) return fail(401);
    const bytes=await boundedBody(request);
    if (bytes===null) return fail(413);
    const verified=await verifyRequestProof(request,bytes,proof,device.key,Date.now());
    if (!verified) return fail(401);
    const authorize=async txn => {
      const deny=status=>{throw new MembershipRefused(status);};
      let current=await txn.get('authorized_devices');
      if (current===undefined) {
        if ((await txn.list({limit:1})).size!==0) deny(503);
        current=root;
        await txn.put('authorization_root',root);
        await txn.put('authorized_devices',root);
        await txn.put('request_budget',emptyRequestBudget(Date.now()));
      } else if (JSON.stringify(await txn.get('authorization_root'))!==JSON.stringify(root)) {
        // No fixed-policy adoption, authority replacement or clock reset.
        deny(503);
      }
      if (!acceptable(current,root)) deny(503);
      const actor=current.devices.find(device=>device.key===verified.publicKey);
      if (!actor || !actor.operations.includes(requestOperation(verifiedRequestContext(verified),current.scope))) deny(403);
      if (operation==='membership' && !inviteRequest(verifiedRequestContext(verified),current.scope)) return 0; // Commit admission occurs in afterAppend.
      const admission=await admitVerifiedDeviceRequest(txn,verified,Date.now());
      if (!admission.ok) deny(admission.reason==='replay' ? 409 : admission.reason==='expired' ? 401 : admission.reason==='capacity' ? 429 : 503);
      await spendRequestBudget(txn,verified,await txn.get('request_clock'));
      return 0;
    };
    if (inviteRequest(verifiedRequestContext(verified),root.scope)) {
      return this.state.storage.transaction(async txn=>{
        await authorize(txn);
        return json(await this.welcomeRequest(txn,verified,bytes));
      });
    }
    if (operation==='read') {
      if (url.pathname.endsWith('/policy')) {
        return this.state.storage.transaction(async txn => {
          const denied=await authorize(txn);
          return denied ? fail(denied) : json({policy:await txn.get('authorized_devices')});
        });
      }
      return this.read(url,authorize);
    }
    return this.append(new Request(request.url,{method:request.method,headers:request.headers,body:bytes}),authorize,
      operation==='membership' ? txn=>applyMembershipTransition(txn,verified,bytes,Date.now()) : null);
  }
  async welcomeRequest(txn,verified,bytes) {return applyWelcomeRequest(txn,verified,bytes,Date.now());}
  async alarm() {await this.state.storage.transaction(txn=>expireWelcomes(txn,Date.now()));}
}

export default {
  async fetch(request,env) {
    const url=new URL(request.url), root=trustedRoot(env);
    if (!root || !loopback(url)) return fail(503);
    const prefix=`/g/${root.scope.id}`;
    const read=[prefix,`${prefix}/policy`], write=[`${prefix}/append`,`${prefix}/membership`];
    const context={origin:url.origin,method:request.method,path:url.pathname,query:url.search};
    const invitation=inviteRequest(context,root.scope);
    const preflight=url.pathname.match(new RegExp(`^${prefix}/invite/[0-9a-f]{32}(?:/ack)?$`));
    const validPreflight=(preflight && !url.search) ||
      (read.includes(url.pathname) && requestOperation({...context,method:'GET'},root.scope)==='read') ||
      (write.includes(url.pathname) && !url.search);
    if (url.origin!==root.scope.origin || !((request.method==='GET' && read.includes(url.pathname)) ||
        (request.method==='POST' && write.includes(url.pathname)) ||
        invitation || (request.method==='OPTIONS' && validPreflight))) return fail(403);
    if (request.method!=='OPTIONS' && !requestOperation({origin:url.origin,method:request.method,
      path:url.pathname,query:url.search},root.scope)) return fail(403);
    const cors={'access-control-allow-origin':'*','access-control-allow-methods':'GET, POST, PUT, OPTIONS',
      'access-control-allow-headers':'content-type, x-cash-device-proof'};
    if (request.method==='OPTIONS') return new Response(null,{status:204,headers:cors});
    const response=await env.GROUP.get(env.GROUP.idFromName(root.scope.id)).fetch(request);
    const result=new Response(response.body,response);
    for (const [key,value] of Object.entries(cors)) result.headers.set(key,value);
    return result;
  }
};
