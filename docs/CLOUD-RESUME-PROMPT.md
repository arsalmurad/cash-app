# Paste into the Codex Cloud task

Continue `arsalmurad/cash-app` from branch `codex/notification-lifecycle-20261018`
and the latest checkpoint in `docs/CLOUD-HANDOFF.md`. This is a continuation, not a
new app or redesign. First confirm the checked-out branch/HEAD and read
`AGENTS.md`, `docs/CLOUD-HANDOFF.md`, `docs/PHASE0-RESULT.md`,
`docs/COMPLETION.md`, and only the relevant build-brief phase/evidence.

Our goal is a polished local-first budgeting app for iPhone, Android and web,
then privacy-preserving selected household sharing: private individual ledgers,
no shared login, no readable financial data at the relay. Preserve all money,
event ordering, canonical convergence, MLS, protected-key and save-before-ACK
invariants. Preserve the known-working pinned toolchains/lockfiles.

Set up/reuse the Linux environment as documented. The receive-only notification
transport and bounded controller lifecycle are integrated with scoped native
and browser transport evidence; read `docs/NOTIFICATION-LIFECYCLE.md` and the
current handoff before repeating work. Continue production-browser and remaining
platform acceptance, especially locking/disposal/background/identity changes,
stale callbacks, uncertain saves, offline recovery and current-member revocation.
Never treat a tail hint as ledger state, delivery ACK or retention consent.

Continue meaningful safe implementation toward the remaining completion gates
without asking me to approve each ordinary step. Inspect caches/disk/tools
first, use focused tests before broad acceptance runs, and keep concise evidence
and focused commits on a `codex/` work branch. Distinguish actual runtime passes
from builds, mocks, skips and older revision evidence. Keep the handoff and
completion tracker current so later sessions can resume without rereading the
whole history. Do not declare the project 100% complete with unchecked gates.

Use only this repository and synthetic test data. Do not change repository
visibility, expose an anonymous/public relay, add telemetry/bank integration,
upload private financial data or request real recovery keys. Do not buy services,
deploy, dispatch Actions, or open a PR that auto-runs Actions until the owner
has verified the required $0 spending cap. That prior safety refusal is not
permission to retry through another route. Full/unrestricted permissions do not
override these boundaries. Save progress in a branch while that gate is pending.
No app-store publication or paid provider is authorized. If a genuine external
permission is missing, state the exact blocker and continue independent safe
work; do not invent a workaround or repeatedly ask about unchanged state.

Begin implementing and verifying, rather than returning only a plan. If a task
limit ends a run, checkpoint the commit, exact tests, remaining gaps and next
command in the handoff. Do not promise uninterrupted work or completion beyond
the available runtime. Do not merge unverified draft work into `main`.
