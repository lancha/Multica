# Multica upstream upgrade agent

Use this runbook for an automated Multica task that keeps the localized
`mike/Multica` repository current with stable public releases.

## Agent task

1. Start from a clean checkout of `main` and read the repository `AGENTS.md`.
2. Run:

   ```bash
   scripts/selfhost/sync-upstream.sh --merge-main --push
   ```

3. Read `.git/multica-upstream-sync-summary.json`.
   - `up-to-date`: finish without changing the repository.
   - `integrated`: report the public version, validation result, and new commit.
   - `conflict`: stay on the generated `sync/upstream-vX.Y.Z` branch. Inspect
     every unresolved file and compare it with both `vendor/vX.Y.Z` and
     `main`. Keep upstream behavior for shared code, but preserve the local
     boundaries below. Do not merge or push `main` manually.
   - `blocked`: another change moved `main`; rebase/review rather than forcing.
4. After resolving every conflict, stage the resolutions and run:

   ```bash
   scripts/selfhost/sync-upstream.sh --resume --merge-main --push
   ```

5. Never use `git push --force`, never invent a conflict resolution, and never
   commit credentials. If validation fails, leave the sync branch for review
   and report the exact failing check.

## Local boundaries that must survive

- `apps/web/features/landing/utils/github-release.ts` must retain the private
  Forgejo release source selected by `DESKTOP_RELEASES_SOURCE`, including
  `FORGEJO_BASE_URL`, `FORGEJO_REPO`, and server-only `FORGEJO_TOKEN` support.
- `scripts/selfhost/` must retain the manual recovery macOS builder, its launchd configuration,
  and this synchronization workflow.
- The GitHub macOS pipeline consumes promoted `vX.Y.Z` tags with identical `deploy/`
  candidates; historical `-mikeux.N` tags remain supported. Never create the
  unprefixed tag before the Ubuntu health gate. Preserve the public download
  proxy, server-only credentials, and runtime rewrite exemptions.
- A localized import that cannot use the plain upstream version is named
  `X.Y.Z.N`, never the next upstream patch: keep `vX.Y.Z.N` / `deploy/vX.Y.Z.N`
  server-only and leave desktop packaging to plain `vX.Y.Z` releases, so an
  installed client can always reach the next upstream version.
- Tokens, signing identities, `.env` files, and machine paths remain external.

The script snapshots the public tree first, applies only the delta between the
old and new vendor snapshots, runs validation, checks that these boundaries
still exist, and advances `main` only when its starting commit has not moved.
