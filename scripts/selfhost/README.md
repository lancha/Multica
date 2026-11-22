# Self-host build automation

Scripts that keep this deployment's own builds in step with the self-hosted Git
server. They are site-specific: upstream Multica ships neither a Forgejo release
publisher nor a desktop auto-builder, so these live here rather than upstream.

## Frontend release-source configuration

The standard `docker-compose.selfhost.yml` passes `DESKTOP_RELEASES_SOURCE`,
`FORGEJO_BASE_URL`, `FORGEJO_REPO`, and `FORGEJO_TOKEN` into the frontend at
runtime. Set the source to `forgejo` and the URL/repository in the private
deployment environment; a private repository also needs a read-only token.
The default remains `github` for upstream-compatible deployments. These values
must never use `NEXT_PUBLIC_*` names or be embedded in desktop installers.
No untracked Compose overlay is required for this release-source wiring.

`pnpm clean` delegates to `make clean`: generated outputs and build caches are
removed, while installed dependencies are retained. Do not run it during builds.

## build-desktop-macos.sh

macOS packaging assigns distinct build UUIDs to the app and its Helper executables
in `apps/desktop/scripts/mac-executable-uuids.mjs`, before electron-builder signs
them. Stock Electron executables can otherwise share an identity with an unrelated
app in macOS local-network privacy checks. Framework UUIDs remain unchanged.
The hook is inherited by the self-host configuration and runs for each new package;
already-published assets are not rewritten. If distributing executable dSYM files
in the future, their UUIDs must match these final executables.

The Ubuntu source-build Compose overlay passes the deployer's existing
`HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` (or lowercase equivalents) as Docker's
predefined build arguments for both application images. Docker daemon proxy
configuration covers image pulls but does not proxy dependency downloads inside
build steps. Keep host-specific proxy values in the private deployment environment;
do not add Dockerfile `ENV` entries that persist them in the runtime image.

Runs on the Mac. Picks the newest promoted `vX.Y.Z` tag (with an identical
`deploy/` candidate; historical `-mikeux.N` tags remain readable), and if that
tag's Forgejo release has no macOS installer yet, checks the tag out, builds the
desktop app (unsigned / ad-hoc), and uploads the artifacts to the release.
Idempotent: a second run with nothing to do exits without building.

A localized `vX.Y.Z.N` release is deliberately skipped: it exists only to keep
the server on the upstream version line, and its four-component version is not
valid semver, which `electron-updater` rejects at startup. Packaging resumes at
the next plain `vX.Y.Z` release, so an installed client always receives it.

Needs on the Mac: git, Python 3, Node 22/24 + pnpm (`corepack enable`), Go 1.26+ (the
app bundles a CLI built from `server/cmd/multica`), Xcode Command Line Tools.
The supplied LaunchAgent also defines the site's Clash HTTP proxy because
launchd does not inherit the macOS interactive system proxy configuration.
For self-hosted builds, the builder overrides electron-updater's publish
provider to Generic and points it at the public, read-only update proxy on the
self-hosted web app. The proxy authenticates to the private Forgejo repository
server-side, so desktop clients never need a Forgejo token.

The supplied LaunchAgent also relays progress-only records back to Ubuntu using
the Mac's existing `ubuntu26` SSH identity and known host. This lets the normal
Ubuntu progress timer update Multica even when the Mac is on another network.
It does not make an offline Mac remotely startable: comment-triggered retries
still require Ubuntu-to-Mac SSH reachability. A dead configured home proxy is
bypassed for this build only, after direct package-registry access is verified.

Configuration (environment variables, all optional):

| Variable | Default |
| --- | --- |
| `FORGEJO_BASE_URL` | `https://git.mikeux.com:188` |
| `FORGEJO_REPO` | `mike/Multica` |
| `FORGEJO_TOKEN` | `~/.config/multica/forgejo-token` |
| `WORK_DIR` | `~/src/multica` |
| `WORK_BRANCH` | `main` — controller scripts follow the stable branch, not the compatibility alias |
| `TAG_PATTERN` | `v*` (requires a matching deployment candidate) |
| `TARGET_ARCH` | host arch (`arm64` / `x64`) |
| `DESKTOP_API_URL` | `https://ca.mikeux.com:188` |
| `DESKTOP_WS_URL` | `wss://ca.mikeux.com:188/ws` |
| `DESKTOP_APP_URL` | `https://ca.mikeux.com:188` |
| `DESKTOP_UPDATE_URL` | `https://ca.mikeux.com:188/api/desktop-updates` |
| `DRY_RUN` | `0` — set to `1` to only report what it would do |
| `CLEANUP_AFTER_UPLOAD` | `1` — verify published bytes, then remove local generated output; set `0` to retain it |

### Local output retention

After all five release assets are uploaded, the builder rereads the release and
streams each file from the trusted Forgejo download URL to verify its size and
SHA-256 against the local copy. This does not save another download on disk.
Redirects, mismatched content, incomplete releases, or failed requests prevent
cleanup. The 100% completion stage follows verification and cleanup.

Only these Git-ignored generated paths inside `WORK_DIR` are removed:

- `apps/desktop/dist` (installers, update metadata, and unpacked app)
- `apps/desktop/out`
- `apps/desktop/resources/bin/multica`
- `server/bin/darwin-arm64/multica` (`darwin-amd64` for x64)

Source, Git history, installed applications, credentials, logs, `node_modules`,
pnpm, Electron and Go caches are retained. Tracked files, linked/mounted targets,
and `dist` containing another release or architecture are refused. Failed builds
retain outputs for diagnosis. If a filesystem error interrupts deletion, inspect
remaining outputs before retrying; cleanup is not a filesystem transaction.

An already-published release also runs this housekeeping step, so a later timer
run retries interrupted verification without rebuilding or uploading again.
When no generated output remains, subsequent runs skip artifact downloads.
Housekeeping-only failures do not reopen a completed Multica task. `DRY_RUN=1`
lists targets without downloading or deleting; `CLEANUP_AFTER_UPLOAD=0` disables
cleanup for debugging. Decisions and removals are recorded in
`~/Library/Logs/multica-desktop-builder.log`.

Deleted installers remain available in the Forgejo release and via `/download`;
intermediate files can be rebuilt from the immutable release tag. The helper is
snapshotted from the controller branch before checkout, so this policy also works
for release tags created before cleanup was added.

Install:

```bash
git clone https://git.mikeux.com:188/mike/Multica.git ~/src/multica
mkdir -p ~/.config/multica && printf '%s' '<forgejo-token>' > ~/.config/multica/forgejo-token
chmod 600 ~/.config/multica/forgejo-token

# verify once by hand
DRY_RUN=1 bash ~/src/multica/scripts/selfhost/build-desktop-macos.sh

cp ~/src/multica/scripts/selfhost/com.mikeux.multica-desktop-builder.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.mikeux.multica-desktop-builder.plist
launchctl start com.mikeux.multica-desktop-builder   # run now; afterwards every 30 min
tail -f ~/Library/Logs/multica-desktop-builder.log
```

The token needs Forgejo's `write:repository` scope (create releases, upload
assets). Builds are unsigned, so the installer must be opened via right-click →
Open the first time, and it cannot auto-update — reinstall the new dmg instead.

The three desktop endpoint values are baked into this site's package. A user
can still override them with `~/.multica/desktop.json`; upstream packages built
without these variables retain the public Multica defaults.

## deploy-ubuntu.sh

Candidates carrying `scripts/selfhost/dsh-agent.json` require an operator-provided
`MULTICA_DSH_ACCEPTANCE_CMD`. The deployer supplies `MULTICA_RELEASE_DIR` and
`MULTICA_RELEASE_SHA`, and runs the command after the exact-commit HTTP gate and
before recording success or promoting Desktop. A missing command stops before
application changes. A failed command triggers the existing application-image
rollback; the command must restore any daemon configuration it changed.

The Homelab implementation lives in its independent deployment repository at
`projects/multica-dsh-pilot/production_rollout.py`. It extracts the CLI from the
running backend, selects independently installed DSH/Node/bridge dependencies,
and verifies real tool execution, task-scoped CLI access, session resume and
cancellation. Node, DSH and bridge versions are declared together in
`dsh-agent.json`; installing or updating DSH Web does not update this private
Agent installation. Runtime configuration, credentials and acceptance receipts
remain outside this source repository.

Runs on Ubuntu26. It finds the newest immutable `deploy/vX.Y.Z[.N]` candidate by
its position in `main`'s history — not by tag name, because a localized
`vX.Y.Z.N` deliberately sorts below an already released `vX.Y.(Z+1)` tag —
creates a private PostgreSQL recovery dump,
builds the backend and web images from that exact commit, recreates only the
application containers, and waits for both `/health` and `/login`. It records
the deployed candidate/SHA under
`~/.local/state/multica-deploy/` and preserves the previous application images
for automatic container rollback if the health gate fails.

Base-image refreshes are retried three times. If Docker Hub remains temporarily
unavailable, deployment falls back to already-cached base images instead of
aborting an otherwise reproducible candidate build.

Each source tag is built in a detached worktree below the state directory. The
main controller checkout is never switched to an older release, so the timer
always retains the newest deployer and host-local `.env`/Compose overlay.

Only after the health gate and reported commit check succeed does
`promote-desktop-release.sh` remove the `deploy/` prefix and create the matching
`vX.Y.Z` (or `vX.Y.Z.N`). A plain `vX.Y.Z` tag is the handoff to the Mac builder;
a server-only `vX.Y.Z.N` release is promoted without waking it. Database dumps
are not automatically restored on failure because a destructive database
restore requires explicit operator review.

Install the polling service on Ubuntu26:

```bash
mkdir -p ~/.config/systemd/user ~/.config/multica
cp scripts/selfhost/multica-ubuntu-deployer.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now multica-ubuntu-deployer.timer
```

Machine-private options belong in `~/.config/multica/deploy.env`, for example
`FORGEJO_TOKEN_FILE=/home/mike/.config/multica/forgejo-token`. Never commit the
token or that environment file.

## Why /download reads Forgejo

`apps/web/features/landing/utils/github-release.ts` normally reads
`api.github.com/repos/multica-ai/multica`. This deployment sets
`DESKTOP_RELEASES_SOURCE=forgejo` (plus `FORGEJO_BASE_URL`, `FORGEJO_REPO`
and `FORGEJO_TOKEN`) on the frontend container so the page lists the installers
built here. Unset, it behaves exactly like upstream.

For Forgejo, the page and update feed select the newest complete arm64 release
(DMG, ZIP, both blockmaps, and metadata). Installer links use the same public
proxy, never a private Forgejo login URL. Upload metadata last. The previous
complete release stays visible during packaging; other platforms stay disabled.

New product releases use standard `vX.Y.Z` names and candidates use
`deploy/vX.Y.Z`. Upstream snapshots remain `vendor/vX.Y.Z`. When the plain
upstream number is already taken by local work, the import gets the next unused
`X.Y.Z.N` increment (`v0.6.1.1` while local `v0.6.1` and `v0.6.2` exist) rather
than the next upstream patch: the real `v0.6.3` must stay free, because a
release that consumed it for different code would permanently block that update
on installed clients. `X.Y.Z.N` releases deploy to Ubuntu and stop there — no
macOS installer is built for them. Upstream integration records its source
snapshot separately, so a local patch cannot make a future upstream import look
complete.
The builder installs the pinned pnpm version and checks the frozen lockfile on
every build, not just when node_modules is missing. Old clients with a GitHub
feed need a one-time manual reinstall to migrate to this site's feed. The feed
supports discovery/download; unsigned macOS builds still require manual install.

## Automatic Mac builder trigger

After Ubuntu health-gates a `deploy/vX.Y.Z` candidate, promotion can
trigger the dedicated Mac builder immediately instead of waiting for its
30-minute LaunchAgent timer. Configure these private environment variables on
Ubuntu26 (never commit them):

```text
MULTICA_MAC_BUILDER_HOST=192.168.0.182
MULTICA_MAC_BUILDER_USER=mike
MULTICA_MAC_BUILDER_LABEL=com.mikeux.multica-desktop-builder
```

Ubuntu26 must have a passwordless SSH key accepted by the Mac user and a
known-host entry. If the Mac is offline, promotion remains successful and the
LaunchAgent timer retries later. The website status endpoint reports the
release as `building` while the Mac assets are missing and `published` after
the arm64 DMG and ZIP are uploaded.

## Multica task progress

The Mac builder emits stable `PROGRESS <tag> <percent> <stage>` records.
Ubuntu runs `desktop-build-progress.sh` once a minute, creates or reuses the
matching issue in the configured Multica project, and posts a comment only
when a new 10% stage is reached. A failure moves the issue to `blocked`; 100%
moves it to `done`. The API token stays in `~/.multica/config.json` on Ubuntu.

```bash
cp scripts/selfhost/multica-desktop-progress.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now multica-desktop-progress.timer
```

Set `MULTICA_BUILD_PROJECT_ID` explicitly in `~/.config/multica/deploy.env`.
Set `MULTICA_WORKSPACE_ID` alongside it to pin the automation workspace
independently of the interactive CLI's current workspace. An optional
`MULTICA_SERVER_URL` overrides the API origin without copying its token.
The bridge validates that the project belongs to the pinned workspace before
creating or updating any issue. There is no built-in project UUID fallback.

When a build is `blocked`, a workspace member can post the exact standalone
comment `重新运行` on that issue. The Ubuntu progress bridge consumes each
comment once, restarts the Mac LaunchAgent, acknowledges the command in the
issue, and moves it back to `in_progress`.
