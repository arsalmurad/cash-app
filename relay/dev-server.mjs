// Runs the relay locally in workerd (via miniflare) for development and for
// scripts/verify_relay.sh. Usage: node dev-server.mjs [port]
import { Miniflare } from "miniflare";
import { fileURLToPath } from "node:url";

const port = Number(process.argv[2] ?? process.env.PORT ?? 8787);
const mf = new Miniflare({
  modules: true,
  scriptPath: fileURLToPath(new URL("./src/worker.js", import.meta.url)),
  durableObjects: { GROUP: "GroupLog", MAILBOX: "Mailbox" },
  bindings: { LOCAL_DEVELOPMENT: "true" },
  compatibilityDate: "2026-07-01",
  host: "127.0.0.1",
  port,
});
await mf.ready;
console.log(`relay listening on http://127.0.0.1:${port}`);
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, async () => {
    await mf.dispose();
    process.exit(0);
  });
}
