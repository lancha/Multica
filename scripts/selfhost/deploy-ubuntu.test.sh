#!/usr/bin/env bash
set -euo pipefail

# Candidate discovery is the one deployer decision that can silently roll the
# server back, so it is covered without touching Docker or the live host: the
# script supports --print-target-tag, which stops right after selecting.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/selfhost/deploy-ubuntu.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git_quiet() { git "$@" >/dev/null; }

git_quiet init --bare -q -b main "$TMP/remote.git"
git_quiet init -b main "$TMP/work"
git -C "$TMP/work" config user.name test
git -C "$TMP/work" config user.email test@example.com
git -C "$TMP/work" remote add origin "$TMP/remote.git"

commit() {
  echo "$1" >"$TMP/work/file"
  git_quiet -C "$TMP/work" add file
  git_quiet -C "$TMP/work" commit -m "$1"
}

# The already released desktop line: v0.6.2 sorts above a localized v0.6.1.1.
commit release-062
git_quiet -C "$TMP/work" tag -a deploy/v0.6.2 -m 'released v0.6.2'
git_quiet -C "$TMP/work" push -q origin main --tags

# The newer localized import of upstream v0.6.1.
commit localized-0611
git_quiet -C "$TMP/work" tag -a deploy/v0.6.1.1 -m 'localized v0.6.1.1'
git_quiet -C "$TMP/work" push -q origin main --tags

pick_target() {
  MULTICA_PRIVATE_REMOTE=origin MULTICA_DEPLOY_STATE_DIR="$TMP/state" \
    bash "$SCRIPT" --print-target-tag "$@"
}

# A localized X.Y.Z.N candidate deliberately sorts below the older v0.6.2
# candidate, so tag-name ordering would redeploy the previous release.
test "$(cd "$TMP/work" && pick_target)" = deploy/v0.6.1.1
test "$(cd "$TMP/work" && pick_target)" != "$(git -C "$TMP/work" tag --list 'deploy/v*' --sort=-v:refname | sed -n '1p')"

# The newest candidate by commit order wins even when its name sorts last.
commit upstream-063
git_quiet -C "$TMP/work" tag -a deploy/v0.6.3 -m 'upstream v0.6.3'
git_quiet -C "$TMP/work" push -q origin main --tags
test "$(cd "$TMP/work" && pick_target)" = deploy/v0.6.3

# A two-component form and a foreign tag name stay unrecognized.
git_quiet -C "$TMP/work" tag -a deploy/v0.7 -m malformed
git_quiet -C "$TMP/work" tag -a deploy/v0.6.4-mikeux -m malformed
git_quiet -C "$TMP/work" push -q origin main --tags
test "$(cd "$TMP/work" && pick_target)" = deploy/v0.6.3

# An explicit request still works, including the historical tag shape.
test "$(cd "$TMP/work" && pick_target deploy/v0.6.2)" = deploy/v0.6.2
set +e
(cd "$TMP/work" && pick_target deploy/v0.7) >/dev/null 2>&1
status=$?
set -e
test "$status" -eq 2

# No candidate at all is a clean stop, not a fallback to an older release.
EMPTY="$TMP/empty"
git_quiet init --bare -q -b main "$TMP/empty-remote.git"
git_quiet init -b main "$EMPTY"
git -C "$EMPTY" config user.name test
git -C "$EMPTY" config user.email test@example.com
git_quiet -C "$EMPTY" remote add origin "$TMP/empty-remote.git"
git_quiet -C "$EMPTY" commit --allow-empty -m empty
git_quiet -C "$EMPTY" push -q origin main
set +e
(cd "$EMPTY" && pick_target) >/dev/null 2>&1
status=$?
set -e
test "$status" -eq 3

echo "deploy-ubuntu tests passed"
