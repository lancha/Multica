#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/selfhost/promote-desktop-release.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git init --bare -q "$TMP/remote.git"
git init -q "$TMP/work"
git -C "$TMP/work" config user.name test
git -C "$TMP/work" config user.email test@example.com
git -C "$TMP/work" remote add origin "$TMP/remote.git"
echo one >"$TMP/work/file"
git -C "$TMP/work" add file
git -C "$TMP/work" commit -qm initial
git -C "$TMP/work" tag -a deploy/v1.2.3-mikeux.1 -m candidate
cp "$SCRIPT" "$TMP/work/promote.sh"
mkdir "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
export PATH="$TMP/bin:$PATH"

(cd "$TMP/work" && bash promote.sh deploy/v1.2.3-mikeux.1)
git -C "$TMP/remote.git" show-ref --verify --quiet refs/tags/v1.2.3-mikeux.1

# Idempotent for the same deployed commit.
(cd "$TMP/work" && bash promote.sh deploy/v1.2.3-mikeux.1) | grep -Fq 'already promoted'
test "$(git -C "$TMP/work" tag --list 'v1.2.3-mikeux.*' | wc -l | tr -d ' ')" = 1

echo "promote-desktop-release tests passed"

git -C "$TMP/work" tag -a deploy/v1.2.4 -m candidate
(cd "$TMP/work" && bash promote.sh deploy/v1.2.4)
git -C "$TMP/remote.git" show-ref --verify --quiet refs/tags/v1.2.4

# A localized X.Y.Z.N release is promoted for the server line only: it must not
# wake the macOS builder, because installers resume at the next plain vX.Y.Z.
git -C "$TMP/work" tag -a deploy/v1.2.4.1 -m candidate
output="$(cd "$TMP/work" && bash promote.sh deploy/v1.2.4.1)"
git -C "$TMP/remote.git" show-ref --verify --quiet refs/tags/v1.2.4.1
grep -Fq 'server-only release' <<<"$output"
if grep -Fq 'macOS builder triggered' <<<"$output"; then
  echo "a localized X.Y.Z.N release must not trigger a desktop build" >&2
  exit 1
fi
