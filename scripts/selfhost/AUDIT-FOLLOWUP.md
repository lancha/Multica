# Fork audit repair status

Verified against Forgejo `main` at `2849c4425` on 2026-10-11. Repairs are on
`codex/fork-audit-fixes`; deployment acceptance is recorded separately in the
Homelab handoff. Existing release tags must never be moved.

## Implemented

- Reject malformed task/workspace UUIDs before accessing handler dependencies.
- Pass private release-source variables through the standard frontend Compose
  environment and document them without storing credentials. Unknown sources
  fail closed rather than silently selecting GitHub.
- Delegate `pnpm clean` to the existing Makefile. Dependencies are retained.
- Reject missing, untagged, malformed, and empty vendor trailers. Annotated
  vendor tags are supported; legacy repositories without trailers retain their
  existing baseline behavior.
- Default Mac controller scripts to `main`. Product packaging still uses the
  exact promoted release tag; server-only four-component versions stay excluded.
- Move the shared search store to core; declare ESLint directly in five
  workspaces and runtime views peers in both consuming apps.
- Align mobile React types with its existing React 19.2 runtime and remove global
  React-type overrides. Regenerate the lockfile using pinned pnpm 10.28.2.
- Export the plain TypeScript markdown modules and correct the web test alias.
- Separate avatar identity rendering from profile hover cards. Separate preview
  context from its provider and defer rich preview/save-dialog imports to remove
  synchronous initialization cycles without changing public component exports.
- Add blocking configuration, dependency-resolution, full Knip and static cycle
  checks to frontend quality.
- Resolve package self-imports and JavaScript-to-TypeScript specifiers in the
  static cycle check. Four graph fixtures guard barrels, re-exports, side
  effects, mixed imports and the intended type-only/deferred exclusions.
- Register the live shimmer-text Playwright bundle/fixture with Knip. Its
  `new URL(...)` entry and esbuild dependency are used, not dead code.
- Guard ordinary and task-supplement inserts with locked, workspace/issue-scoped
  parent reads. Lock issue, parent, then task; revalidate running state and the
  selected trigger after waiting. Invalid parents create no comment, supplement
  or issue-activity change. Tombstones remain valid thread parents.
- Remove eight reference-checked unused files and the docs-only Mermaid
  dependency. Shared editor Mermaid remains available; full Knip exits 0.
- Gate future migration index builds on CONCURRENTLY and one statement per file.
  Historical SQL remains immutable. Production has zero invalid indexes at the
  2026-10-11 read-only check; no healthy index was rebuilt.

## Remaining / not claimed fixed

- Retain production's historical parent-comment FK in this deployment. The
  existing rollback restores older application images, which lack the new guard.
  A later corrective migration may remove the constraint only after the safe
  rollback baseline also contains this guard and all deletion paths are checked.
  No migration 018 rewrite or production constraint removal is included here.
- Root workspace version, desktop product version and Git describe serve
  different purposes. Do not bump product versions just to equalize them.
  Signed updating and migration from historical locally numbered releases still
  require release-level validation, not only typechecks. On 2026-10-11 the local
  arm64 0.6.1 application was ad-hoc signed and `security find-identity` reported
  zero valid signing identities. Its updater points to the private generic feed,
  but signed install/restart acceptance is blocked pending a Developer ID
  certificate. Free Personal Team enrollment does not provide that certificate.
  Continue using manual installation for unsigned builds; do not claim that
  compilation or a reachable update manifest proves automatic installation.
- Backfill commands are manual maintenance entry points, not proven dead code.
  They must not be automatically invoked by a normal server build or deployment.
- Vite/electron-vite/Fumadocs peer compatibility warnings predate this batch and
  remain; no unrequested framework upgrade was performed.

## Verification

Six DB-free UUID boundary cases were run using production handler source files
and the new test, excluding the package's DB-dependent TestMain. The ordinary
package command can skip all tests when no database is reachable, so its exit
status alone is not counted as execution.

Targeted Vitest suites cover search state/commands, shortcuts, avatar navigation,
attachment/sequence preview, issue details, property/status filters, save view,
and release sources. Core/Views/Web/Desktop/Mobile typechecks pass (Web requires
its normal MDX generation first); changed-file ESLint and UI export checks pass.
Isolated sync, deploy-selection, promotion and Mac builder fixtures cover the
release pipeline without building or deploying a real release.

Follow-up on 2026-10-11: the actual desktop `bundle-cli` and `electron-vite build`
completed successfully. This verifies compilation, not packaging, signing,
updating, uploading or deployment. The existing ineffective dynamic-import
warnings remain; deferred imports here remove initialization cycles and do not
promise separate output chunks.

An explicitly disposable PostgreSQL 17/pgvector container on Ubuntu26, bound
only to loopback and reached through SSH, ran the normal migration runner through
563. No production database or volume was used. Thirty top-level handler tests
passed without skips (including the six UUID subcases, issue/comment/workspace
deletion, other-workspace preservation and concurrent task/child writes). Two
additional issue-teardown lock-order tests passed. The temporary parent-constraint
diagnostic demonstrated the remaining dependency described above and was removed
afterward; it is not a regression test asserting the unsafe behavior as desired.
The disposable container and its tmpfs database were removed after verification.

The four graph regression tests, actual views graph and six self-host contracts
pass. Installed Knip's full check now exits 0 after unused-code removal. A separate `pnpm exec` invocation
could not verify its pinned package manager over the network; the check was rerun
via the already-installed Knip entry, without disabling signature checks.

Parent-integrity follow-up: normal migration through 563 on an isolated tmpfs
PostgreSQL 17 database, with only `comment_parent_id_fkey` removed, passed 69
top-level handler tests without skips. Cases include parent issue/workspace
mismatch, tombstones, root comments, concurrent parent deletion, terminal races,
and issue teardown lock order. The task-trigger FK remains present: deletion
before a statement starts deliberately clears that trigger; deletion after
selection must reject the waiting reply. An additional regression checks a
trigger changed while waiting for the task lock. SQL was regenerated with
`make sqlc` (pinned sqlc 1.31.1). Docs MDX/typecheck and views typecheck pass.
Three migration tests include an actual invalid concurrent-index retry/repair.
