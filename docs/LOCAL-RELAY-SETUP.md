# Authenticated local development relay

This is an owned loopback prototype, not public registration or deployment.
The public/default relay remains closed. No account, purchase or cloud runner
is needed for these steps. Use the pinned tools and cached dependencies already
recorded in `PHASE0-RESULT.md`; do not upgrade them for this setup.

1. In Household setup, enter `http://127.0.0.1:8787`, enable **Authenticated
   relay (development)**, then use the address checkmark to save both settings.
2. Create a household. Until the operator starts the relay, sync will fail but
   the newly created household is saved locally. Do not create another copy.
3. From Household options choose **Export local relay setup**, then Copy.
   Save the exact public JSON as `relay-policy.json` in the repository's `relay`
   directory. It contains only origin/group/public device grants; never put a
   recovery phrase, backup, private key or financial data in this file.
4. In an operator-owned PowerShell terminal in `relay`, start the local worker:

   ```powershell
   $env:LOCAL_AUTH_POLICY = Get-Content -LiteralPath ./relay-policy.json -Raw
   $env:LOCAL_AUTH_MEMBERSHIP = 'true'
   node dev-server.mjs 8787
   ```

5. Close the export dialog and Sync. The founding device uploads its saved
   encrypted events. The export action disappears after confirmed sync.
6. A second app creates a join request; the founding app invites that request.
   The returned invite selects authenticated delivery automatically. Check the
   safety number out of band before trusting the member. Neither person's
   private personal ledger is published by these steps.

The port/origin must match the copied policy exactly. Do not replace the root
for an existing relay store. The launcher uses ephemeral local test storage;
stopping it loses relay history, although saved device ledgers remain local.
This is not durable production hosting or an offline-peer recovery guarantee.
Removed devices have seven days to fetch already-authorized encrypted history
through their removal commit, so their local MLS state can become inactive.
This does not permit later ciphertext, current policy, invites or writes. A
device offline beyond that window may retain stale local membership; preserve
its archive and use a fresh-key invitation rather than reopening the old grant.
Loopback addresses refer to the device running the app: two isolated mobile
devices cannot share this URL without a separately authorized deployment path.

Native Windows acceptance: the normal controllers found a household before
relay startup, exported public grants without changing saved state, started the
owned workerd SQLite worker with that policy, joined/restarted a second device
and received an encrypted expense. UI copying was separately checked at 200%
phone text. See `RELAY-AUTH.md` for exact runs and unverified platform limits.
