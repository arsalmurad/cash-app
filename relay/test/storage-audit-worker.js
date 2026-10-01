// Test-only wrapper. Never included in production worker/deployment config.
import production, { GroupLog, Mailbox } from './production-worker.js';

const groups = new Set();
const mailboxes = new Set();
const auditPath = '/__test_only_storage';

export class AuditGroupLog extends GroupLog {
  async fetch(request) {
    if (new URL(request.url).pathname === auditPath) {
      return Response.json([...await this.state.storage.list()]);
    }
    return super.fetch(request);
  }
}

export class AuditMailbox extends Mailbox {
  async fetch(request) {
    if (new URL(request.url).pathname === auditPath) {
      return Response.json([...await this.state.storage.list()]);
    }
    return super.fetch(request);
  }
}

export default {
  async fetch(request, env) {
    const parts = new URL(request.url).pathname.split('/').filter(Boolean);
    if (parts[0] === '__audit') {
      const records = [];
      for (const [kind, ids, namespace] of [
        ['group', groups, env.GROUP], ['mailbox', mailboxes, env.MAILBOX],
      ]) {
        for (const id of ids) {
          const response = await namespace.get(namespace.idFromName(id)).fetch(`http://audit${auditPath}`);
          records.push({ kind, id, rows: await response.json() });
        }
      }
      return Response.json(records);
    }
    if (/^[0-9a-f]{32}$/.test(parts[1])) {
      if (parts[0] === 'g') groups.add(parts[1]);
      if (parts[0] === 'm') mailboxes.add(parts[1]);
    }
    // All writes, encryption transport and expiry use unchanged production code.
    return production.fetch(request, env);
  },
};
