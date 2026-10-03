// Runs the relay locally in workerd (via miniflare) for development and for
// scripts/verify_relay.sh. Usage: node dev-server.mjs [port]
import { Miniflare } from "miniflare";
import { fileURLToPath } from "node:url";

const port = Number(process.argv[2] ?? process.env.PORT ?? 8787);
const membership = process.env.LOCAL_AUTH_MEMBERSHIP === "true";
const authenticated = process.env.LOCAL_AUTH_POLICY !== undefined || membership;
const mf = new Miniflare({
  modules: true,
  modulesRules: [{ type: "ESModule", include: ["**/*.js"] }],
  scriptPath: fileURLToPath(new URL(membership ? "./src/roster-worker.js" : authenticated ? "./src/local-auth-worker.js" : "./src/worker.js", import.meta.url)),
  durableObjects: authenticated ? { GROUP: { className: membership ? "RosterGroupLog" : "AuthenticatedGroupLog", useSQLite: true } } :
    { GROUP: "GroupLog", MAILBOX: "Mailbox" },
  bindings: { LOCAL_DEVELOPMENT: "true", ...(process.env.LOCAL_AUTH_POLICY !== undefined ? { LOCAL_AUTH_POLICY: process.env.LOCAL_AUTH_POLICY } : {}),
    ...(membership ? { LOCAL_AUTH_MEMBERSHIP: "true" } : {}) },
  compatibilityDate: "2026-07-01",
  host: "127.0.0.1",
  port,
});
await mf.ready;
console.log(`${membership ? 'local roster group relay' : authenticated ? 'local authenticated group relay' : 'relay'} listening on http://127.0.0.1:${port}`);
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, async () => {
    await mf.dispose();
    process.exit(0);
  });
}
