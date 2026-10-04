// Explicit operator-bootstrapped loopback experiment, not public signup.
import { GroupLog, PrefixRefused } from './worker.js';
import { configuredPolicy, boundedBody } from './local-auth-worker.js';
import { verifyRequestProof, verifiedRequestContext } from './request-proof.js';
import { requestOperation, inviteRequest } from './request-scope.js';
import { applyWelcomeRequest, expireWelcomes, WelcomeRefused } from './roster-welcome.js';
import { admitVerifiedDeviceRequest, admitRetiredReadRequest, admitVerifiedPrefixRequest, admitVerifiedNotificationRequest } from './request-admission.js';
import {verifyPrefixConsentBundle} from './prefix-consent.js';
import { emptyRequestBudget, spendRequestBudget, RequestBudgetRefused } from './request-budget.js';
import { validMembershipPolicy, applyMembershipTransition, MembershipRefused } from './request-membership.js';
import { retiredReader, RetiredReaderRefused } from './retired-readers.js';

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

function refused(error) {
  const response = fail(error instanceof MembershipRefused || error instanceof RequestBudgetRefused ||
    error instanceof WelcomeRefused || error instanceof RetiredReaderRefused ? error.status : 503);
  if (error instanceof RequestBudgetRefused && error.retryAfter !== null) response.headers.set('retry-after',String(error.retryAfter));
  return response;
}
function socketProof(request) {
  const header = request.headers.get('x-cash-device-proof');
  const protocol = request.headers.get('sec-websocket-protocol');
  if (protocol === null) {
    if (!header || header.length > 1024) throw new Error('missing bounded proof');
    return { proof: JSON.parse(header), protocol: null };
  }
  if (header !== null || protocol.length > 1024) throw new Error('ambiguous proof');
  const match = /^cash-request\.([A-Za-z0-9_-]+)$/.exec(protocol);
  if (!match) throw new Error('invalid protocol');
  const encoded = match[1], text = atob(encoded.replaceAll('-','+').replaceAll('_','/'));
  if (btoa(text).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'') !== encoded) throw new Error('noncanonical protocol');
  return { proof: JSON.parse(text), protocol };
}
function socketKey(socket, root) {
  try {
    const saved = socket.deserializeAttachment();
    if (!saved || JSON.stringify(Object.keys(saved).sort()) !== '["group","origin","publicKey","version"]' ||
      saved.version !== 1 || saved.origin !== root.scope.origin || saved.group !== root.scope.id ||
      typeof saved.publicKey !== 'string' || !/^[0-9a-f]{64}$/.test(saved.publicKey)) return null;
    return saved.publicKey;
  } catch { return null; }
}
function closeSocket(socket, code = 1008) {try {socket.close(code);} catch {}}

export class RosterGroupLog extends GroupLog {
  constructor(state,env) {super(state);this.env=env;}
  async fetch(request) {
    try {return await this.authenticatedFetch(request);}
    catch (error) {
      return refused(error);
    }
  }
  async authenticatedFetch(request) {
    const url = new URL(request.url);
    const root = trustedRoot(this.env);
    if (!root || !loopback(url)) return fail(503);
    const operation = requestOperation({origin:url.origin,method:request.method,path:url.pathname,query:url.search},root.scope);
    const retention=operation==='prune'&&this.env.LOCAL_AUTH_RETENTION==='true';
    const notification=operation==='ws'&&this.env.LOCAL_AUTH_SOCKETS==='true';
    if (!['read','append','membership'].includes(operation)&&!retention&&!notification) return fail(403);
    let proof, protocol = null;
    try {
      if (notification) ({proof, protocol}=socketProof(request));
      else {
        const header=request.headers.get('x-cash-device-proof');
        if (!header || header.length > 1024) return fail(401);
        proof=JSON.parse(header);
      }
    } catch {return fail(401);}
    // Candidate verification uses a trusted saved roster snapshot, never the
    // request's desired policy. The transaction rechecks grants after awaits.
    const snapshot = await this.state.storage.get('authorized_devices') ?? root;
    if (!acceptable(snapshot,root)) return fail(503);
    const historical=operation==='read'&&url.pathname===`/g/${root.scope.id}`;
    const device=snapshot.devices.find(device=>device.key===proof?.publicKey)??
      (historical ? await retiredReader(this.state.storage,proof?.publicKey,Date.now()) : null);
    if (!device) return fail(401);
    const bytes=await boundedBody(request);
    if (bytes===null) return fail(413);
    const verified=await verifyRequestProof(request,bytes,proof,device.key,Date.now());
    if (!verified) return fail(401);
    if(retention) return this.retentionRequest(bytes,verified,root);
    let historicalLimit=null;
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
      if (actor) {
        if(!actor.operations.includes(notification ? 'read' : requestOperation(verifiedRequestContext(verified),current.scope))) deny(403);
      } else {
        const retired=historical ? await retiredReader(txn,verified.publicKey,Date.now()) : null;
        if(!retired) deny(403);
        const tail=await txn.get('tail');
        if(!Number.isSafeInteger(tail)||retired.through>tail) deny(503);
        historicalLimit=retired.through;
      }
      if (operation==='membership' && !inviteRequest(verifiedRequestContext(verified),current.scope)) return 0; // Commit admission occurs in afterAppend.
      const admission=notification ? await admitVerifiedNotificationRequest(txn,verified,Date.now()) :
        historicalLimit===null ? await admitVerifiedDeviceRequest(txn,verified,Date.now()) :
        await admitRetiredReadRequest(txn,verified,Date.now());
      if (!admission.ok) deny(admission.reason==='replay' ? 409 : admission.reason==='expired' ? 401 : admission.reason==='capacity' ? 429 : 503);
      if(historicalLimit!==null) historicalLimit=admission.through;
      await spendRequestBudget(txn,verified,await txn.get('request_clock'));
      return 0;
    };
    if (notification) return this.connectAuthenticated(request,authorize,verified,root,protocol);
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
      return this.read(url,authorize,()=>historicalLimit);
    }
    return this.append(new Request(request.url,{method:request.method,headers:request.headers,body:bytes}),authorize,
      operation==='membership' ? txn=>applyMembershipTransition(txn,verified,bytes,Date.now()) : null);
  }
  async welcomeRequest(txn,verified,bytes) {return applyWelcomeRequest(txn,verified,bytes,Date.now());}
  async connectAuthenticated(request,authorize,verified,root,protocol) {
    if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') return fail(426);
    // Only local storage and synchronous socket setup under this input gate.
    // Expected transaction refusals are caught INSIDE the gate: throwing out
    // of blockConcurrencyWhile terminates the object and its other clients.
    return this.state.blockConcurrencyWhile(async () => {
      try {
        const sockets = this.state.getWebSockets();
        // Count closing transports in the global cap too; rapid reconnects
        // cannot grow an unlimited set waiting for close handshakes.
        if (sockets.length >= 128 || sockets.filter(socket=>socket.readyState===1&&socketKey(socket,root)===verified.publicKey).length >= 2) return fail(429);
        await this.state.storage.transaction(authorize);
        const pair = new WebSocketPair();
        pair[1].serializeAttachment({version:1,publicKey:verified.publicKey,origin:root.scope.origin,group:root.scope.id});
        this.state.acceptWebSocket(pair[1]);
        return new Response(null,{status:101,webSocket:pair[0],
          ...(protocol ? {headers:{'sec-websocket-protocol':protocol}} : {})});
      } catch(error) {return refused(error);}
    });
  }
  async notifyTail(sequence) {
    if (this.state.getWebSockets().length === 0) return;
    await this.state.blockConcurrencyWhile(async () => {
      const sockets = this.state.getWebSockets();
      try {
        const root = trustedRoot(this.env);
        const policy = await this.state.storage.get('authorized_devices');
        const tail = await this.state.storage.get('tail');
        if (this.env.LOCAL_AUTH_SOCKETS !== 'true' || !root || !acceptable(policy,root) ||
          JSON.stringify(await this.state.storage.get('authorization_root'))!==JSON.stringify(root) ||
          !Number.isSafeInteger(tail) || tail < sequence) throw new Error('notification authority unavailable');
        const allowed = new Set(policy.devices.filter(device=>device.operations.includes('read')).map(device=>device.key));
        const note = JSON.stringify({tail});
        for (const socket of sockets) {
          // This committed, current roster is checked after every append,
          // including membership removal, before any tail leaves the object.
          if (!allowed.has(socketKey(socket,root))) {closeSocket(socket);continue;}
          try {socket.send(note);} catch {closeSocket(socket,1011);}
        }
      } catch {for (const socket of sockets) closeSocket(socket,1011);}
    });
  }
  async webSocketMessage(socket) {closeSocket(socket);}
  async webSocketError(socket) {closeSocket(socket,1011);}
  async retentionRequest(bytes,verified,root) {
    let body;
    try {body=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));} catch {return fail(400);}
    if(!body||typeof body!=='object'||Array.isArray(body)||
        JSON.stringify(Object.keys(body).sort())!=='["consents","expectedFloor","through"]') return fail(400);
    const spec={expectedFloor:body.expectedFloor,through:body.through};
    const token=await verifyPrefixConsentBundle(body.consents,Date.now());
    if(!token) return fail(403);
    let retryAfter=null;
    const response=await this.prunePrefix(spec,async(txn,context)=>{
      if(JSON.stringify(await txn.get('authorization_root'))!==JSON.stringify(root)||
          !acceptable(await txn.get('authorized_devices'),root)) throw new PrefixRefused(503);
      const admission=await admitVerifiedPrefixRequest(txn,verified,token,context,Date.now());
      if(!admission.ok) throw new PrefixRefused(admission.reason==='replay'?409:admission.reason==='expired'?401:admission.reason==='capacity'?429:403);
      try {await spendRequestBudget(txn,verified,await txn.get('request_clock'));}
      catch(error) {
        if(!(error instanceof RequestBudgetRefused)) throw error;
        retryAfter=error.retryAfter;throw new PrefixRefused(error.status);
      }
      return true;
    });
    if(retryAfter!==null) response.headers.set('retry-after',String(retryAfter));
    return response;
  }
  async alarm() {await this.state.storage.transaction(txn=>expireWelcomes(txn,Date.now()));}
}

export default {
  async fetch(request,env) {
    const url=new URL(request.url), root=trustedRoot(env);
    if (!root || !loopback(url)) return fail(503);
    const prefix=`/g/${root.scope.id}`;
    const read=[prefix,`${prefix}/policy`], write=[`${prefix}/append`,`${prefix}/membership`];
    const socket=env.LOCAL_AUTH_SOCKETS==='true'&&url.pathname===`${prefix}/ws`&&!url.search&&request.method==='GET';
    if(env.LOCAL_AUTH_RETENTION==='true') write.push(`${prefix}/prune`);
    const context={origin:url.origin,method:request.method,path:url.pathname,query:url.search};
    const invitation=inviteRequest(context,root.scope);
    const preflight=url.pathname.match(new RegExp(`^${prefix}/invite/[0-9a-f]{32}(?:/ack)?$`));
    const validPreflight=(preflight && !url.search) ||
      (read.includes(url.pathname) && requestOperation({...context,method:'GET'},root.scope)==='read') ||
      (write.includes(url.pathname) && !url.search);
    if (url.origin!==root.scope.origin || !((request.method==='GET' && read.includes(url.pathname)) ||
        (request.method==='POST' && write.includes(url.pathname)) ||
        invitation || socket || (request.method==='OPTIONS' && validPreflight))) return fail(403);
    if (request.method!=='OPTIONS' && !requestOperation({origin:url.origin,method:request.method,
      path:url.pathname,query:url.search},root.scope)) return fail(403);
    const cors={'access-control-allow-origin':'*','access-control-allow-methods':'GET, POST, PUT, OPTIONS',
      'access-control-allow-headers':'content-type, x-cash-device-proof'};
    if (request.method==='OPTIONS') return new Response(null,{status:204,headers:cors});
    const response=await env.GROUP.get(env.GROUP.idFromName(root.scope.id)).fetch(request);
    if(response.status===101) return response; // Preserve the real upgrade/socket.
    const result=new Response(response.body,response);
    for (const [key,value] of Object.entries(cors)) result.headers.set(key,value);
    return result;
  }
};
