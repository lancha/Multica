#!/usr/bin/env bash
set -euo pipefail

# Promote deploy/vX.Y.Z (or a localized deploy/vX.Y.Z.N) to the matching
# vX.Y.Z / vX.Y.Z.N tag. This must run only after that exact candidate commit
# has been deployed and health-checked on Ubuntu. A plain release also wakes the
# macOS builder; a localized X.Y.Z.N release is server-only by design (see
# UPSTREAM_SYNC.md), so it is promoted without a desktop build.

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT_DIR" ] || { echo "error: run from a Multica checkout" >&2; exit 2; }
cd "$ROOT_DIR"

CANDIDATE_TAG="${1:-}"
REMOTE="${MULTICA_PRIVATE_REMOTE:-origin}"
TOKEN_FILE="${FORGEJO_TOKEN_FILE:-$HOME/.config/multica/forgejo-token}"
FORGEJO_USER="${FORGEJO_USER:-mike}"
TAGGER_NAME="${MULTICA_RELEASE_TAGGER_NAME:-Multica Release Bot}"
TAGGER_EMAIL="${MULTICA_RELEASE_TAGGER_EMAIL:-multica-release@localhost}"
MAC_BUILDER_HOST="${MULTICA_MAC_BUILDER_HOST:-192.168.0.182}"
MAC_BUILDER_USER="${MULTICA_MAC_BUILDER_USER:-mike}"
MAC_BUILDER_LABEL="${MULTICA_MAC_BUILDER_LABEL:-com.mikeux.multica-desktop-builder}"
MAC_BUILDER_SSH_OPTIONS="${MULTICA_MAC_BUILDER_SSH_OPTIONS:--o BatchMode=yes -o ConnectTimeout=10}"

[[ "$CANDIDATE_TAG" =~ ^deploy/v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(-mikeux\.[0-9]+)?$ ]] || {
  echo "usage: $0 deploy/vX.Y.Z[.N]" >&2
  exit 2
}

RELEASE_TAG="${CANDIDATE_TAG#deploy/}"
SOURCE_COMMIT="$(git rev-parse "$CANDIDATE_TAG^{}")"
VERIFIED_COMMIT="${MULTICA_DEPLOYED_SHA:-$(git rev-parse HEAD)}"
[ "$VERIFIED_COMMIT" = "$SOURCE_COMMIT" ] || {
  echo "error: verified deployment is not $CANDIDATE_TAG; refusing desktop promotion" >&2
  exit 3
}

if git show-ref --verify --quiet "refs/tags/$RELEASE_TAG"; then
  [ "$(git rev-parse "$RELEASE_TAG^{}")" = "$SOURCE_COMMIT" ] || {
    echo "error: $RELEASE_TAG already points to another commit" >&2
    exit 4
  }
  echo "desktop release already promoted: $RELEASE_TAG"
  exit 0
fi

git -c user.name="$TAGGER_NAME" -c user.email="$TAGGER_EMAIL" \
  tag -a "$RELEASE_TAG" "$SOURCE_COMMIT" \
  -m "desktop release after verified Ubuntu deployment of $CANDIDATE_TAG"

askpass=""
cleanup() {
  [ -z "$askpass" ] || rm -f "$askpass"
}
trap cleanup EXIT

if [ -s "$TOKEN_FILE" ]; then
  askpass="$(mktemp)"
  chmod 700 "$askpass"
  cat >"$askpass" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' "${FORGEJO_USER:-mike}" ;;
  *) cat "$FORGEJO_TOKEN_FILE" ;;
esac
EOF
  export FORGEJO_USER TOKEN_FILE
  # The helper expects this stable variable name and keeps the token out of
  # argv, logs, Git config, and the repository.
  export FORGEJO_TOKEN_FILE="$TOKEN_FILE"
  GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
    git push "$REMOTE" "refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"
else
  git push "$REMOTE" "refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"
fi

echo "desktop release promoted: $RELEASE_TAG"

# A localized X.Y.Z.N release only keeps this deployment aligned with the
# upstream version line; desktop installers resume at the next plain vX.Y.Z.
# The builder filters that tag out, so waking the Mac would be a no-op.
if [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "server-only release: no desktop installer is built for $RELEASE_TAG"
  exit 0
fi

# Trigger the dedicated Mac builder immediately. The builder remains idempotent
# and checks the promoted Forgejo release before doing any work. Promotion is
# already valid if the Mac is temporarily offline, so this is intentionally a
# warning rather than a rollback condition; the Mac LaunchAgent's 30-minute
# timer remains the retry path.
if command -v ssh >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  if ssh $MAC_BUILDER_SSH_OPTIONS "$MAC_BUILDER_USER@$MAC_BUILDER_HOST" \
      "launchctl kickstart -k gui/\$(id -u)/$MAC_BUILDER_LABEL"; then
    echo "macOS builder triggered: $MAC_BUILDER_USER@$MAC_BUILDER_HOST ($MAC_BUILDER_LABEL)"
  else
    echo "warning: could not trigger macOS builder at $MAC_BUILDER_USER@$MAC_BUILDER_HOST; timer retry remains enabled" >&2
  fi
fi
