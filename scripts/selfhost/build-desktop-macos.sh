#!/usr/bin/env bash
#
# Build the macOS desktop app from the self-hosted Multica checkout and publish
# the installer to the Forgejo release that matches the built tag, so the web
# app's /download page can serve it.
#
# Designed to run unattended (launchd agent, see desktop-builder.plist.example):
# every run is idempotent — it picks the newest tag matching TAG_PATTERN, skips
# work when that release already carries a macOS installer, and otherwise
# builds and uploads.
#
# Configuration (environment overrides, else defaults):
#   FORGEJO_BASE_URL   https://forgejo.example.invalid
#   FORGEJO_REPO       owner/Multica
#   FORGEJO_TOKEN      falls back to ~/.config/multica/forgejo-token (chmod 600)
#   WORK_DIR           ~/src/multica
#   WORK_BRANCH        main
#   TAG_PATTERN        'v*' (only tags with matching deploy/ candidates are built)
#   TARGET_ARCH        arm64 | x64  (default: host arch)
#   DESKTOP_API_URL    endpoint baked into the local package
#   DESKTOP_WS_URL     WebSocket endpoint baked into the local package
#   DESKTOP_APP_URL    browser URL baked into the local package
#   DESKTOP_UPDATE_URL public update feed baked into the local package
#   DRY_RUN            1 = report what would happen, build nothing
#   CLEANUP_AFTER_UPLOAD 1 = verify remote copies and remove local build outputs
#
# Exit codes: 0 = success or nothing to do; non-zero = failure (logged).
set -euo pipefail

FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-https://forgejo.example.invalid}"
FORGEJO_REPO="${FORGEJO_REPO:-owner/Multica}"
WORK_DIR="${WORK_DIR:-$HOME/src/multica}"
WORK_BRANCH="${WORK_BRANCH:-main}"
TAG_PATTERN="${TAG_PATTERN:-v*}"
DRY_RUN="${DRY_RUN:-0}"
CLEANUP_AFTER_UPLOAD="${CLEANUP_AFTER_UPLOAD:-1}"
DESKTOP_API_URL="${DESKTOP_API_URL:-https://app.example.invalid}"
DESKTOP_WS_URL="${DESKTOP_WS_URL:-wss://app.example.invalid/ws}"
DESKTOP_APP_URL="${DESKTOP_APP_URL:-https://app.example.invalid}"
DESKTOP_UPDATE_URL="${DESKTOP_UPDATE_URL:-https://app.example.invalid/api/desktop-updates}"

if [ -z "${TARGET_ARCH:-}" ]; then
  case "$(uname -m)" in
    arm64) TARGET_ARCH=arm64 ;;
    x86_64) TARGET_ARCH=x64 ;;
    *) TARGET_ARCH=arm64 ;;
  esac
fi

LOG_DIR="$HOME/Library/Logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/multica-desktop-builder.log"
LOCK_DIR="${TMPDIR:-/tmp}/multica-desktop-builder.lock"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }
progress() {
  local message="PROGRESS ${TAG:-unknown} $1 $2"
  log "$message"
  # Optional outbound telemetry works when Ubuntu cannot SSH into a roaming Mac.
  # Only progress records cross this link, never tokens or full command output.
  if [ -n "${MULTICA_PROGRESS_SSH_HOST:-}" ]; then
    # shellcheck disable=SC2086
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" |
      ssh -o BatchMode=yes -o ConnectTimeout=5 ${MULTICA_PROGRESS_SSH_OPTIONS:-} "$MULTICA_PROGRESS_SSH_HOST" \
        'umask 077; mkdir -p "$HOME/.local/state/multica-deploy"; tee -a "$HOME/.local/state/multica-deploy/mac-progress.log" >/dev/null' ||
      log "warning: progress relay unavailable; local progress retained"
  fi
}

# One builder at a time; a stale lock older than 6h is reclaimed.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +360 2>/dev/null)" ]; then
    log "reclaiming stale lock $LOCK_DIR"
    rm -rf "$LOCK_DIR" && mkdir "$LOCK_DIR"
  else
    log "another build is running ($LOCK_DIR); exiting"
    exit 0
  fi
fi
cleanup() {
  # Keep the dedicated builder checkout on its controller branch so the next
  # launch always runs the newest orchestration script rather than the script
  # embedded in the last release tag.
  if [ -d "$WORK_DIR/.git" ]; then
    git -C "$WORK_DIR" checkout -q "$WORK_BRANCH" 2>/dev/null || true
  fi
  rm -rf "$LOCK_DIR"
}
trap cleanup EXIT

[ -n "${FORGEJO_TOKEN:-}" ] || FORGEJO_TOKEN="$(cat "$HOME/.config/multica/forgejo-token" 2>/dev/null || true)"
API="$FORGEJO_BASE_URL/api/v1/repos/$FORGEJO_REPO"
AUTH_HEADER=()
[ -n "$FORGEJO_TOKEN" ] && AUTH_HEADER=(-H "Authorization: token $FORGEJO_TOKEN")
curl_auth() {
  if [ "${#AUTH_HEADER[@]}" -gt 0 ]; then
    curl "$@" "${AUTH_HEADER[@]}"
  else
    curl "$@"
  fi
}

command -v git >/dev/null || die "git not found"
command -v python3 >/dev/null || die "python3 not found"
[[ "$CLEANUP_AFTER_UPLOAD" =~ ^[01]$ ]] || die "CLEANUP_AFTER_UPLOAD must be 0 or 1"
# A roaming Mac can retain a home-LAN proxy that is unreachable on another Wi-Fi.
# Only this build process falls back, and only after direct registry access works.
if [ -n "${HTTPS_PROXY:-}" ] &&
   ! curl -fsSI --connect-timeout 3 --max-time 5 --proxy "$HTTPS_PROXY" https://registry.npmjs.org/ >/dev/null 2>&1 &&
   curl -fsSI --connect-timeout 3 --max-time 5 --noproxy '*' https://registry.npmjs.org/ >/dev/null 2>&1; then
  log "configured proxy unavailable; using verified direct access for this build"
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
fi
# --- 1. Newest tag to build -------------------------------------------------
if [ ! -d "$WORK_DIR/.git" ]; then
  log "cloning $FORGEJO_BASE_URL/$FORGEJO_REPO.git → $WORK_DIR"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would clone the checkout and inspect tags matching $TAG_PATTERN"
    log "DRY_RUN: would build missing macOS assets for the newest matching tag"
    exit 0
  fi
  git clone -q "$FORGEJO_BASE_URL/$FORGEJO_REPO.git" "$WORK_DIR"
fi
[ "$DRY_RUN" = "1" ] || git -C "$WORK_DIR" fetch -q --tags --prune origin
[ "$DRY_RUN" = "1" ] || {
  [ -z "$(git -C "$WORK_DIR" status --porcelain --untracked-files=no)" ] || die "builder checkout has tracked changes"
  git -C "$WORK_DIR" checkout -q "$WORK_BRANCH"
  git -C "$WORK_DIR" merge --ff-only -q "origin/$WORK_BRANCH"
}

# A promoted tag can predate the cleanup helper. Snapshot the current controller
# before checking out the immutable release source.
if [ "$CLEANUP_AFTER_UPLOAD" = "1" ]; then
  cp "$WORK_DIR/scripts/selfhost/cleanup-desktop-artifacts.py" "$LOCK_DIR/cleanup-desktop-artifacts.py"
fi
cleanup_published_outputs() {
  [ "$CLEANUP_AFTER_UPLOAD" = "1" ] || { log "local output cleanup disabled"; return 0; }
  local release_json
  local dry_run_arg=""
  [ "$DRY_RUN" != "1" ] || dry_run_arg=--dry-run
  release_json="$(curl_auth -fsS -m 30 "$API/releases/tags/$TAG")" || return 1
  printf '%s' "$release_json" | FORGEJO_TOKEN="$FORGEJO_TOKEN" \
    python3 "$LOCK_DIR/cleanup-desktop-artifacts.py" \
      --work-dir "$WORK_DIR" --tag "$TAG" --arch "$TARGET_ARCH" \
      --base "$FORGEJO_BASE_URL" --repo "$FORGEJO_REPO" ${dry_run_arg:+"$dry_run_arg"} 2>&1 | tee -a "$LOG"
}

TAG="$(git -C "$WORK_DIR" tag --list "$TAG_PATTERN" --sort=-v:refname | while read -r candidate; do
  # Only plain vX.Y.Z product releases (plus the historical vX.Y.Z-mikeux.N
  # tags) are packaged. A localized vX.Y.Z.N release is server-only: its
  # four-component version is not valid semver, so electron-updater would
  # refuse to start in the built app and an installed client could never take
  # the next plain upstream release.
  [[ "$candidate" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-mikeux\.[0-9]+)?$ ]] || continue
  if git -C "$WORK_DIR" show-ref --verify --quiet "refs/tags/deploy/$candidate" &&
      [ "$(git -C "$WORK_DIR" rev-parse "$candidate^{}")" = "$(git -C "$WORK_DIR" rev-parse "deploy/$candidate^{}")" ]; then
    printf '%s\n' "$candidate"
  fi
done | sed -n '1p')"
[ -n "$TAG" ] || die "no tag matching '$TAG_PATTERN' in $WORK_DIR (does the mirror have your tags?)"
VERSION="${TAG#v}"
log "target tag: $TAG (version $VERSION, arch $TARGET_ARCH)"
progress 10 "release tag discovered"

DMG="multica-desktop-$VERSION-mac-$TARGET_ARCH.dmg"
ZIP="multica-desktop-$VERSION-mac-$TARGET_ARCH.zip"

# --- 2. Release + existing assets ------------------------------------------
RELEASES_JSON="$(curl_auth -fsS -m 30 "$API/releases?limit=20" || die "cannot read releases from $API")"
RELEASE_ID="$(printf '%s' "$RELEASES_JSON" | python3 -c '
import json,sys
tag=sys.argv[1]
for r in json.load(sys.stdin):
    if r.get("tag_name")==tag:
        print(r.get("id")); break
' "$TAG")"

if [ -z "$RELEASE_ID" ]; then
  log "creating release for $TAG"
  if [ "$DRY_RUN" != "1" ]; then
    RELEASE_ID="$(curl_auth -fsS -m 30 -X POST -H 'Content-Type: application/json' \
      -d "{\"tag_name\":\"$TAG\",\"name\":\"Multica Desktop $VERSION\",\"draft\":false,\"prerelease\":false}" \
      "$API/releases" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
  fi
  [ -n "$RELEASE_ID" ] || { [ "$DRY_RUN" = "1" ] || die "release creation failed"; }
fi
log "release id: ${RELEASE_ID:-<dry-run>}"
progress 20 "Forgejo release ready"

has_asset() {
  printf '%s' "$RELEASES_JSON" | python3 -c '
import json,sys
tag,name=sys.argv[1],sys.argv[2]
for r in json.load(sys.stdin):
    if r.get("tag_name")==tag:
        print("yes" if any(a.get("name")==name for a in (r.get("assets") or [])) else "no"); break
else:
    print("no")
' "$TAG" "$1"
}

HAVE_DMG="$(has_asset "$DMG")"
HAVE_ZIP="$(has_asset "$ZIP")"
HAVE_METADATA="$(has_asset latest-mac.yml)"

if [ "$HAVE_DMG" = "yes" ] && [ "$HAVE_ZIP" = "yes" ] && [ "$HAVE_METADATA" = "yes" ] &&
   [ "$(has_asset "$DMG.blockmap")" = yes ] && [ "$(has_asset "$ZIP.blockmap")" = yes ]; then
  log "$DMG and $ZIP already published for $TAG; checking local outputs"
  # Housekeeping errors must not reopen an already completed Multica issue.
  cleanup_published_outputs || die "published output cleanup failed; no rebuild was attempted"
  [ "$DRY_RUN" = "1" ] || progress 100 "publication complete; local output housekeeping finished"
  exit 0
fi

# --- 3. Build ---------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN: would checkout $TAG, install dependencies, package @multica/desktop for mac/$TARGET_ARCH, upload $DMG/$ZIP"
  exit 0
fi

command -v pnpm >/dev/null || die "pnpm not found (corepack enable)"
command -v go >/dev/null || die "go 1.26+ not found (required to bundle the CLI into the app)"
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools not installed (xcode-select --install)"

cd "$WORK_DIR"
git checkout -q "$TAG"
BUILT_VERSION="$(git describe --tags --match 'v[0-9]*' --always)"
log "checked out $TAG (describe: $BUILT_VERSION)"
progress 30 "source checked out"
UPDATE_URL="$DESKTOP_UPDATE_URL"

build_failed() {
  status=$?
  progress FAILED "build command exited with status $status"
  exit "$status"
}
trap build_failed ERR

DIST_DIR="$WORK_DIR/apps/desktop/dist"
if [ -f "$DIST_DIR/$DMG" ] && [ -f "$DIST_DIR/$ZIP" ]; then
  log "reusing existing artifacts for $TAG"
else
  # A checkout from a new tag must refresh dependencies even when node_modules exists.
  PNPM_VERSION="$(node -p 'require("./package.json").packageManager.replace(/^pnpm@/, "").split("+")[0]')"
  [[ "$PNPM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid pinned pnpm version"
  PNPM_DIR="$HOME/Library/Caches/multica/pnpm/$PNPM_VERSION"
  [ -f "$PNPM_DIR/node_modules/pnpm/bin/pnpm.cjs" ] || npm install --prefix "$PNPM_DIR" --ignore-scripts --no-audit --no-fund "pnpm@$PNPM_VERSION"
  export PATH="$PNPM_DIR/node_modules/.bin:$PATH"
  pnpm() { node "$PNPM_DIR/node_modules/pnpm/bin/pnpm.cjs" "$@"; }
  log "installing locked dependencies with pnpm $PNPM_VERSION"
  CI=true pnpm install --frozen-lockfile
  progress 40 "dependencies ready"

  log "building desktop (unsigned / ad-hoc) for $DESKTOP_API_URL"
  progress 50 "building bundled CLI"
  progress 60 "packaging Electron application"
  VITE_API_URL="$DESKTOP_API_URL" \
  VITE_WS_URL="$DESKTOP_WS_URL" \
  VITE_APP_URL="$DESKTOP_APP_URL" \
  CSC_IDENTITY_AUTO_DISCOVERY=false \
    pnpm --filter @multica/desktop package -- --mac "--$TARGET_ARCH" \
      --config electron-builder.selfhost.yml "-c.publish.url=$UPDATE_URL" "-c.publish.channel=latest" --publish never
fi

log "artifacts in $DIST_DIR: $(ls "$DIST_DIR" 2>/dev/null | tr '\n' ' ')"
progress 70 "DMG and ZIP packaging finished"
for required in "$DMG" "$ZIP" "$DMG.blockmap" "$ZIP.blockmap" latest-mac.yml; do
  [ -s "$DIST_DIR/$required" ] || die "required release artifact missing: $required"
done

# --- 4. Upload --------------------------------------------------------------
upload() {
  local file="$1"
  [ -f "$file" ] || { log "skip (missing): $file"; return 0; }
  if [ "$(has_asset "$(basename "$file")")" = yes ]; then
    log "skip (already uploaded): $(basename "$file")"
    return 0
  fi
  log "uploading $(basename "$file")"
  curl_auth --http1.1 --retry 3 --retry-all-errors --retry-delay 5 \
    -fsS -m 1800 -X POST \
    -F "attachment=@$file" "$API/releases/$RELEASE_ID/assets?name=$(basename "$file")" >/dev/null \
    || { log "upload failed: $file"; return 1; }
}

upload_failed=0
progress 80 "uploading release assets"
for f in "$DIST_DIR/$DMG" "$DIST_DIR/$ZIP" "$DIST_DIR/$DMG.blockmap" "$DIST_DIR/$ZIP.blockmap" "$DIST_DIR/latest-mac.yml"; do
  upload "$f" || upload_failed=1
done
[ "$upload_failed" -eq 0 ] || die "one or more release assets failed to upload"
progress 90 "release assets uploaded"
if ! cleanup_published_outputs; then
  progress FAILED "remote verification or local output cleanup failed; retry after inspection"
  die "publication housekeeping failed"
fi

log "done: $TAG published ($DMG, $ZIP)"
progress 100 "build and publication complete"
