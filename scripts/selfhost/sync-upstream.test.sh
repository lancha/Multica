#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/selfhost/sync-upstream.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git_quiet() { git "$@" >/dev/null; }

make_public() {
  local repo=$1
  git_quiet init "$repo"
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.com
  echo one >"$repo/public.txt"
  git_quiet -C "$repo" add .
  git_quiet -C "$repo" commit -m v1
  git_quiet -C "$repo" tag v1.0.0
  echo two >"$repo/public.txt"
  echo added >"$repo/added.txt"
  git_quiet -C "$repo" add .
  git_quiet -C "$repo" commit -m v2
  git_quiet -C "$repo" tag v1.1.0
}

make_private() {
  local public=$1 repo=$2
  git_quiet clone "$public" "$repo"
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.com
  git_quiet -C "$repo" checkout v1.0.0
  git_quiet -C "$repo" tag -d v1.0.0 v1.1.0
  git_quiet -C "$repo" switch -C main
  mkdir -p "$repo/apps/web/features/landing/utils" "$repo/scripts/selfhost"
  cat >"$repo/apps/web/features/landing/utils/github-release.ts" <<'EOF'
DESKTOP_RELEASES_SOURCE FORGEJO_BASE_URL FORGEJO_TOKEN
EOF
  cat >"$repo/scripts/selfhost/build-desktop-macos.sh" <<'EOF'
pattern='v*-mikeux.*'
[[ "$candidate" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-mikeux\.[0-9]+)?$ ]] || continue
EOF
  cp "$SCRIPT" "$repo/scripts/selfhost/sync-upstream.sh"
  mkdir -p "$repo/server/pkg/agent"
  cp "$ROOT_DIR/scripts/selfhost/dsh-agent.json" "$repo/scripts/selfhost/"
  cp "$ROOT_DIR/server/pkg/agent/dsh.go" "$ROOT_DIR/server/pkg/agent/dsh_test.go" "$repo/server/pkg/agent/"
  git_quiet -C "$repo" add .
  git_quiet -C "$repo" commit -m local
  git_quiet -C "$repo" checkout --orphan vendor/upstream
  git_quiet -C "$repo" rm -rf .
  git -C "$public" show v1.0.0:public.txt >"$repo/public.txt"
  git_quiet -C "$repo" add .
  git_quiet -C "$repo" commit -m snapshot
  git_quiet -C "$repo" tag -a vendor/v1.0.0 -m snapshot
  git_quiet -C "$repo" switch main
  vendor_snapshot="$(git -C "$repo" rev-parse vendor/v1.0.0^{commit})"
  git_quiet -C "$repo" commit --amend -m local -m "Vendor snapshot: $vendor_snapshot"
  git_quiet -C "$repo" branch mikeux
  git -C "$repo" remote remove origin
  git -C "$repo" remote add origin "$TMP/private-bare.git"
}

PUBLIC="$TMP/public"
PRIVATE="$TMP/private"
make_public "$PUBLIC"
git_quiet init --bare "$TMP/private-bare.git"
make_private "$PUBLIC" "$PRIVATE"

# A broken integration trailer must not silently select the newest snapshot.
for broken_kind in missing-object missing-tag invalid-trailer empty-trailer; do
  broken_repo="$TMP/$broken_kind"
  make_private "$PUBLIC" "$broken_repo"
  case "$broken_kind" in
    missing-object)
      git_quiet -C "$broken_repo" commit --amend -m local -m "Vendor snapshot: 1111111111111111111111111111111111111111" ;;
    missing-tag)
      git_quiet -C "$broken_repo" tag -d vendor/v1.0.0
      git_quiet -C "$broken_repo" tag vendor/v0.9.0 main ;;
    invalid-trailer)
      git_quiet -C "$broken_repo" commit --amend -m local -m "Vendor snapshot: not-a-sha" ;;
    empty-trailer)
      git_quiet -C "$broken_repo" commit --amend -m local -m "Vendor snapshot:" ;;
  esac
  before_main="$(git -C "$broken_repo" rev-parse main)"
  set +e
  output="$({ cd "$broken_repo" && MULTICA_SYNC_CHECK_CMD=true bash scripts/selfhost/sync-upstream.sh --public-url "$PUBLIC" --merge-main; } 2>&1)"
  status=$?
  set -e
  test "$status" -eq 9
  grep -Fq 'refusing to guess a merge base' <<<"$output"
  test "$(git -C "$broken_repo" rev-parse main)" = "$before_main"
  test -z "$(git -C "$broken_repo" tag -l 'deploy/*')"
done
git -C "$PRIVATE" config --unset user.name
git -C "$PRIVATE" config --unset user.email

output="$({ cd "$PRIVATE" && MULTICA_SYNC_CHECK_CMD=true \
  bash scripts/selfhost/sync-upstream.sh --public-url "$PUBLIC" --merge-main; })"
grep -Fq '"status":"integrated"' <<<"$output"
test "$(git -C "$PRIVATE" show main:public.txt)" = two
test "$(git -C "$PRIVATE" show main:added.txt)" = added
git -C "$PRIVATE" show main:apps/web/features/landing/utils/github-release.ts | \
  grep -Fq FORGEJO_TOKEN
git -C "$PRIVATE" show-ref --verify --quiet refs/tags/vendor/v1.1.0
git -C "$PRIVATE" show-ref --verify --quiet refs/tags/deploy/v1.1.0
if git -C "$PRIVATE" tag --list 'v1.1.0*' | grep -q .; then
  echo "desktop release tag must not exist before Ubuntu deployment" >&2
  exit 1
fi
test "$(git -C "$PRIVATE" rev-parse main)" = "$(git -C "$PRIVATE" rev-parse mikeux)"

output="$({ cd "$PRIVATE" && MULTICA_SYNC_CHECK_CMD=true \
  bash scripts/selfhost/sync-upstream.sh --public-url "$PUBLIC"; })"
grep -Fq '"status":"up-to-date"' <<<"$output"

# A competing local edit must stop on a sync branch without advancing main.
CONFLICT_PRIVATE="$TMP/conflict-private"
make_private "$PUBLIC" "$CONFLICT_PRIVATE"
echo localized >"$CONFLICT_PRIVATE/public.txt"
git_quiet -C "$CONFLICT_PRIVATE" add public.txt
git_quiet -C "$CONFLICT_PRIVATE" commit -m localized-conflict
git -C "$CONFLICT_PRIVATE" config --unset user.name
git -C "$CONFLICT_PRIVATE" config --unset user.email
conflict_main="$(git -C "$CONFLICT_PRIVATE" rev-parse main)"
set +e
output="$({ cd "$CONFLICT_PRIVATE" && MULTICA_SYNC_CHECK_CMD=true \
  bash scripts/selfhost/sync-upstream.sh --public-url "$PUBLIC" --merge-main; } 2>&1)"
status=$?
set -e
test "$status" -eq 7
grep -Fq '"status":"conflict"' <<<"$output"
test "$(git -C "$CONFLICT_PRIVATE" branch --show-current)" = sync/upstream-v1.1.0
test "$(git -C "$CONFLICT_PRIVATE" rev-parse main)" = "$conflict_main"
test -n "$(git -C "$CONFLICT_PRIVATE" ls-files -u)"
grep -Fq '<<<<<<<' "$CONFLICT_PRIVATE/public.txt"

echo resolved >"$CONFLICT_PRIVATE/public.txt"
git_quiet -C "$CONFLICT_PRIVATE" add public.txt
output="$({ cd "$CONFLICT_PRIVATE" && MULTICA_SYNC_CHECK_CMD=true \
  bash scripts/selfhost/sync-upstream.sh --resume --merge-main; })"
grep -Fq '"status":"integrated"' <<<"$output"
test "$(git -C "$CONFLICT_PRIVATE" show main:public.txt)" = resolved

# A merge with many conflicting files must still be reported as a conflict.
# `git ls-files -u` can exceed one pipe buffer, so a `git ls-files -u | grep -q`
# guard misses it, runs validation on an unresolved tree, and can even commit
# the conflict markers. Long paths keep the fixture small.
MANY_PUBLIC="$TMP/many-public"
git_quiet init "$MANY_PUBLIC"
git -C "$MANY_PUBLIC" config user.name test
git -C "$MANY_PUBLIC" config user.email test@example.com
mkdir -p "$MANY_PUBLIC/many"
long_stem="$(printf 'f%.0s' $(seq 1 170))"
many_names=()
for i in $(seq 1 420); do
  many_names+=("many/${long_stem}${i}.txt")
  echo base >"$MANY_PUBLIC/many/${long_stem}${i}.txt"
done
echo one >"$MANY_PUBLIC/public.txt"
git_quiet -C "$MANY_PUBLIC" add .
git_quiet -C "$MANY_PUBLIC" commit -m v1
git_quiet -C "$MANY_PUBLIC" tag v1.0.0
for name in "${many_names[@]}"; do echo upstream >"$MANY_PUBLIC/$name"; done
echo two >"$MANY_PUBLIC/public.txt"
echo added >"$MANY_PUBLIC/added.txt"
git_quiet -C "$MANY_PUBLIC" add .
git_quiet -C "$MANY_PUBLIC" commit -m v2
git_quiet -C "$MANY_PUBLIC" tag v1.1.0

MANY_PRIVATE="$TMP/many-private"
make_private "$MANY_PUBLIC" "$MANY_PRIVATE"
for name in "${many_names[@]}"; do echo local >"$MANY_PRIVATE/$name"; done
git_quiet -C "$MANY_PRIVATE" add .
git_quiet -C "$MANY_PRIVATE" commit -m local-conflicts
git -C "$MANY_PRIVATE" config --unset user.name
git -C "$MANY_PRIVATE" config --unset user.email
MARKER="$TMP/check-ran"
rm -f "$MARKER"
many_main="$(git -C "$MANY_PRIVATE" rev-parse main)"
set +e
output="$({ cd "$MANY_PRIVATE" && MULTICA_SYNC_CHECK_CMD="touch $MARKER" \
  bash scripts/selfhost/sync-upstream.sh --public-url "$MANY_PUBLIC" --merge-main; } 2>&1)"
status=$?
set -e
test "$status" -eq 7
grep -Fq '"status":"conflict"' <<<"$output"
test "$(git -C "$MANY_PRIVATE" rev-parse main)" = "$many_main"
test -n "$(git -C "$MANY_PRIVATE" ls-files -u)"
if [ -e "$MARKER" ]; then
  echo "validation must not run while conflicts remain" >&2
  exit 1
fi

for name in "${many_names[@]}"; do echo resolved >"$MANY_PRIVATE/$name"; done
git_quiet -C "$MANY_PRIVATE" add -A
output="$({ cd "$MANY_PRIVATE" && MULTICA_SYNC_CHECK_CMD=true \
  bash scripts/selfhost/sync-upstream.sh --resume --merge-main; })"
grep -Fq '"status":"integrated"' <<<"$output"
test "$(git -C "$MANY_PRIVATE" show main:${many_names[0]})" = resolved

# A pristine snapshot can exist even when the localized branch has not
# integrated it. The next release must use the last integrated snapshot as its
# merge base rather than skipping over the pending snapshot.
PENDING_PRIVATE="$TMP/pending-private"
make_private "$PUBLIC" "$PENDING_PRIVATE"
git_quiet -C "$PENDING_PRIVATE" fetch --no-tags "$PUBLIC" \
  refs/tags/v1.1.0:refs/upstream-test/v1.1.0
git_quiet -C "$PENDING_PRIVATE" switch vendor/upstream
git_quiet -C "$PENDING_PRIVATE" read-tree --reset -u refs/upstream-test/v1.1.0
git_quiet -C "$PENDING_PRIVATE" commit -m pending-snapshot
git_quiet -C "$PENDING_PRIVATE" tag vendor/v1.1.0
git_quiet -C "$PENDING_PRIVATE" switch main
git -C "$PENDING_PRIVATE" config --unset user.name
git -C "$PENDING_PRIVATE" config --unset user.email
output="$({ cd "$PENDING_PRIVATE" && MULTICA_SYNC_CHECK_CMD=true \
  bash scripts/selfhost/sync-upstream.sh --tag v1.1.0 --public-url "$PUBLIC" --merge-main; })"
grep -Fq '"status":"integrated"' <<<"$output"
test "$(git -C "$PENDING_PRIVATE" show main:public.txt)" = two

# A localized release stays on the upstream version line: when the plain
# upstream number is already taken by local work, the import gets an X.Y.Z.N
# increment instead of consuming the next upstream patch number.
COLLISION_PRIVATE="$TMP/collision-private"
make_private "$PUBLIC" "$COLLISION_PRIVATE"
git_quiet -C "$COLLISION_PRIVATE" tag v1.1.0
git_quiet -C "$COLLISION_PRIVATE" tag deploy/v1.1.0
old_release="$(git -C "$COLLISION_PRIVATE" rev-parse v1.1.0)"
output="$({ cd "$COLLISION_PRIVATE" && MULTICA_SYNC_CHECK_CMD=true \
  bash scripts/selfhost/sync-upstream.sh --tag v1.1.0 --public-url "$PUBLIC" --merge-main; })"
grep -Fq '"status":"integrated"' <<<"$output"
test "$(git -C "$COLLISION_PRIVATE" rev-parse v1.1.0)" = "$old_release"
git -C "$COLLISION_PRIVATE" show-ref --verify --quiet refs/tags/deploy/v1.1.0.1
if git -C "$COLLISION_PRIVATE" show-ref --verify --quiet refs/tags/deploy/v1.1.1; then
  echo "a localized import must not consume the next upstream patch number" >&2
  exit 1
fi

# The next free increment is used when X.Y.Z.1 is taken as well.
INCREMENT_PRIVATE="$TMP/increment-private"
make_private "$PUBLIC" "$INCREMENT_PRIVATE"
git_quiet -C "$INCREMENT_PRIVATE" tag v1.1.0
git_quiet -C "$INCREMENT_PRIVATE" tag deploy/v1.1.0.1
output="$({ cd "$INCREMENT_PRIVATE" && MULTICA_SYNC_CHECK_CMD=true \
  bash scripts/selfhost/sync-upstream.sh --tag v1.1.0 --public-url "$PUBLIC" --merge-main; })"
grep -Fq '"status":"integrated"' <<<"$output"
git -C "$INCREMENT_PRIVATE" show-ref --verify --quiet refs/tags/deploy/v1.1.0.2

# Remote compatibility state is authoritative even when the local branch is old.
PUSH_PRIVATE="$TMP/push-private"
make_private "$PUBLIC" "$PUSH_PRIVATE"
git -C "$PUSH_PRIVATE" push origin main mikeux vendor/upstream refs/tags/vendor/v1.0.0
git -C "$PUSH_PRIVATE" branch -f mikeux main~1
output="$({ cd "$PUSH_PRIVATE" && MULTICA_SYNC_CHECK_CMD=true \
  bash scripts/selfhost/sync-upstream.sh --tag v1.1.0 --public-url "$PUBLIC" --merge-main --push; })"
test "$(git -C "$TMP/private-bare.git" rev-parse main)" = "$(git -C "$TMP/private-bare.git" rev-parse mikeux)"
echo "sync-upstream tests passed"
