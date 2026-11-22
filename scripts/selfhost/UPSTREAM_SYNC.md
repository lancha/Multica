# Upstream synchronization

This repository keeps public Multica snapshots separate from the localized
product line:

- `vendor/upstream` is an orphan branch containing pristine public release
  snapshots only.
- `vendor/vX.Y.Z` identifies the pristine snapshot for a public release.
- `main` contains the localized product, including the Forgejo release source
  and the macOS desktop build publisher.
- `vX.Y.Z` identifies a verified localized product release, not a public snapshot.
- `deploy/vX.Y.Z` identifies an immutable Ubuntu deployment candidate;
  this prefix is deliberately ignored by the Mac builder.
- `vX.Y.Z` is created only after Ubuntu deployment passes its health gate.
  The Mac builder also reads historical `-mikeux.N` tags; old tags never move.
- `vX.Y.Z.N` and `deploy/vX.Y.Z.N` identify a localized release whose upstream
  base is `X.Y.Z`. They are server-only: a `vX.Y.Z.N` release is never packaged
  for macOS.
- `archive/pre-vendor-model-*` preserves the branch tips from before this
  workflow was introduced.

Never commit `.env` files, Forgejo tokens, signing identities, or deployment
credentials. The builder reads its token from `~/.config/multica/forgejo-token`
or `FORGEJO_TOKEN`.

## Import a public release

The examples below use `v0.5.2`; replace it with the release being imported.
Run them from a clean checkout and review every diff before pushing.

1. Fetch the public tag into a private local ref so the public tag name remains
   available for the localized release:

   ```bash
   git fetch --no-tags https://github.com/multica-ai/multica.git \
     refs/tags/v0.5.2:refs/upstream-snapshots/v0.5.2
   ```

2. Update the pristine snapshot branch and tag it:

   ```bash
   git switch vendor/upstream
   git read-tree --reset -u 'refs/upstream-snapshots/v0.5.2^{}'
   git commit -m 'chore(sync): import upstream v0.5.2'
   git tag -a vendor/v0.5.2 -m 'Pristine Multica upstream snapshot v0.5.2'
   ```

   Verify that the snapshot tree exactly matches the public release:

   ```bash
   git diff --exit-code \
     'vendor/v0.5.2^{tree}' \
     'refs/upstream-snapshots/v0.5.2^{tree}'
   ```

3. Create an integration branch from local `main` and apply only the public
   delta between the two vendor snapshots:

   ```bash
   git switch main
   git pull --ff-only
   git switch -c sync/upstream-v0.5.2
   git read-tree -m -u vendor/v0.5.1 main vendor/v0.5.2
   ```

4. Resolve conflicts deliberately. Public behavior wins by default for shared
   code, while these local surfaces must remain functional:

   - `apps/web/features/landing/utils/github-release.ts`
   - `scripts/selfhost/`
   - server-side `FORGEJO_*` and `DESKTOP_RELEASES_SOURCE` configuration

   Compare the result with the pristine snapshot; the remaining difference
   should be explainable local customization:

   ```bash
   git diff --name-status vendor/v0.5.2 --
   ```

5. Run the checks required by `AGENTS.md`, then commit the resolved tree as one
   normal commit. Include the vendor snapshot commit in the message:

   ```bash
   git commit -m 'chore(sync): import upstream v0.5.2 into main'
   git tag -a deploy/v0.5.2 -m 'Ubuntu deployment candidate for v0.5.2'
   ```

6. Push `vendor/upstream`, the reviewed integration branch or `main`, the
   vendor snapshot tag, and the `deploy/` candidate. Do not create a
   desktop release tag yet.

7. Let Ubuntu deploy and verify the candidate. A successful
   `deploy-ubuntu.sh` run invokes `promote-desktop-release.sh`, creating the
   `vX.Y.Z` tag that starts the Ubuntu GitHub release pipeline.

## Automated upgrade agent

`sync-upstream.sh` automates release detection, pristine snapshot creation,
three-way integration, local-boundary checks, validation, tagging, and pushing.
Its safe default creates a reviewable local candidate and leaves `main`
unchanged:

```bash
scripts/selfhost/sync-upstream.sh
```

After the workflow has been reviewed, unattended operation can atomically
advance `main` and its compatible `mikeux` branch:

```bash
scripts/selfhost/sync-upstream.sh --merge-main --push
```

The script creates the `deploy/...` candidate but not the unprefixed desktop
tag. This prevents the Mac builder from publishing a client before the matching
server is online. If a candidate fails, fix `main` and create the next candidate
patch version; never move an existing candidate tag. A local product tag is
never evidence that its corresponding upstream was integrated.

Localized releases stay on the upstream version line. An import uses the plain
upstream version while it is still free and otherwise the next unused `X.Y.Z.N`
local increment, so importing upstream `v0.6.1` while local `v0.6.1` and `v0.6.2`
already exist produces `deploy/v0.6.1.1`. The next upstream patch number is never
consumed: the real `v0.6.3` has to stay publishable, because an installed client
only accepts a strictly newer version — a release that already used `v0.6.3` for
different code would permanently block that update. The actual upstream identity
stays in the `Vendor snapshot:` commit trailer.

`X.Y.Z.N` releases are server-only. `promote-desktop-release.sh` still creates the
verified `vX.Y.Z.N` tag after the Ubuntu health gate, but GitHub Actions packages
only plain `vX.Y.Z` releases (plus the historical `vX.Y.Z-mikeux.N` tags): a
four-component version is not valid semver, and `electron-updater` refuses to start
when the running app reports one. Desktop installers therefore resume at the next
plain upstream release, which every installed client can still take.

The script derives the merge base from the latest `Vendor snapshot:` trailer
on the localized branch. A newer pristine snapshot by itself does not count as
an integrated product version and will not cause an intermediate release to be
skipped.

The script never guesses through a conflict. It leaves the worktree on
`sync/upstream-vX.Y.Z`, records machine-readable status in
`.git/multica-upstream-sync-summary.json`, and preserves `main`. An agent can
resolve the files according to [UPSTREAM_SYNC_AGENT.md](UPSTREAM_SYNC_AGENT.md)
and then continue with:

```bash
scripts/selfhost/sync-upstream.sh --resume --merge-main --push
```

Set `MULTICA_SYNC_CHECK_CMD` to replace the default targeted web regression and
type checks plus the DSH Agent regressions with a broader command such as
`make check`. Keep `scripts/selfhost/dsh-agent.json` and the DSH backend/tests
when resolving integration conflicts. The DSH checks cover selected profiles
and process shutdown after a terminal result; they use synthetic executables
and do not access user models. Real Agent acceptance is a separate deployment
gate, described in [README.md](README.md#deploy-ubuntush).
`--check-only` detects
a new stable release without changing refs. Pre-release tags are ignored. The
automated commits and annotated tags use a dedicated sync-bot identity, which
can be overridden with `MULTICA_SYNC_COMMITTER_NAME` and
`MULTICA_SYNC_COMMITTER_EMAIL`; no global Git identity is required.

## Rollback

The pre-migration tips remain available as
`archive/pre-vendor-model-main` and `archive/pre-vendor-model-mikeux`. Each
public source tree can be restored from `vendor/vX.Y.Z`, while each localized
integration can be restored from `vX.Y.Z`.
