#!/usr/bin/env bash
set -euo pipefail

# Deploy the newest immutable deploy/vX.Y.Z[.N] candidate to Ubuntu, verify it,
# then promote the matching desktop release tag. Local .env and host overlays
# are deliberately left untracked and untouched.

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT_DIR" ] || { echo "error: run from a Multica checkout" >&2; exit 2; }
cd "$ROOT_DIR"

REMOTE="${MULTICA_PRIVATE_REMOTE:-origin}"
STATE_DIR="${MULTICA_DEPLOY_STATE_DIR:-$HOME/.local/state/multica-deploy}"
HEALTH_URL="${MULTICA_HEALTH_URL:-https://app.example.invalid/health}"
LOGIN_URL="${MULTICA_LOGIN_URL:-https://app.example.invalid/login}"
WAIT_SECONDS="${MULTICA_DEPLOY_WAIT_SECONDS:-300}"
PROMOTE="${MULTICA_PROMOTE_AFTER_DEPLOY:-1}"
REQUESTED_TAG=""
PRINT_TARGET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print-target-tag) PRINT_TARGET=1 ;;
    -h|--help) echo "usage: $0 [--print-target-tag] [deploy/vX.Y.Z[.N]]" ; exit 0 ;;
    *) [ -z "$REQUESTED_TAG" ] || { echo "usage: $0 [--print-target-tag] [deploy/vX.Y.Z[.N]]" >&2; exit 2; }
       REQUESTED_TAG="$1" ;;
  esac
  shift
done

if [ "$PRINT_TARGET" = 0 ]; then
  command -v flock >/dev/null || { echo "error: flock is required for deployment" >&2; exit 2; }
  mkdir -p "$STATE_DIR/backups"
  chmod 700 "$STATE_DIR" "$STATE_DIR/backups"
  exec 9>"$STATE_DIR/deploy.lock"
  flock -n 9 || { echo "another Multica deployment is running"; exit 0; }
fi

is_release_tag() { [[ "$1" =~ ^deploy/v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(-mikeux\.[0-9]+)?$ ]]; }
health_commit() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("commit", ""))'
}

accept_dsh_agent() {
  [ -f "$release_dir/scripts/selfhost/dsh-agent.json" ] || return 0
  MULTICA_RELEASE_DIR="$release_dir" MULTICA_RELEASE_SHA="$target_sha" \
    bash -lc "$MULTICA_DSH_ACCEPTANCE_CMD"
}

git fetch --force --tags "$REMOTE" main
if [ -n "$REQUESTED_TAG" ]; then
  is_release_tag "$REQUESTED_TAG" || { echo "usage: $0 [deploy/vX.Y.Z[.N]]" >&2; exit 2; }
  target_tag="$REQUESTED_TAG"
else
  # Candidate order comes from main's history, never from tag-name ordering: a
  # localized vX.Y.Z.N candidate deliberately sorts below an already released
  # vX.Y.(Z+1) tag, so `--sort=-v:refname` would silently redeploy that older
  # release. The newest candidate is the one closest to main's tip.
  target_tag="$(git tag --list 'deploy/v*' | while IFS= read -r candidate; do
    is_release_tag "$candidate" || continue
    candidate_sha="$(git rev-parse "$candidate^{commit}" 2>/dev/null)" || continue
    git merge-base --is-ancestor "$candidate_sha" FETCH_HEAD 2>/dev/null || continue
    printf '%08d %s\n' "$(git rev-list --count "$candidate_sha..FETCH_HEAD")" "$candidate"
  done | LC_ALL=C sort -k1,1n -k2,2 | sed -n '1p' | cut -d' ' -f2)"
fi
[ -n "$target_tag" ] || { echo "error: no Ubuntu deployment candidate found" >&2; exit 3; }
if [ "$PRINT_TARGET" = 1 ]; then
  printf '%s\n' "$target_tag"
  exit 0
fi
target_sha="$(git rev-parse "$target_tag^{}")"
release_tag="${target_tag#deploy/}"

# Build in a dedicated immutable worktree. The controller checkout stays on
# main so a deployed old tag can never remove the deployer that will discover
# the next release.
release_dir="$STATE_DIR/releases/$release_tag"
mkdir -p "$STATE_DIR/releases"
if [ -e "$release_dir/.git" ]; then
  [ "$(git -C "$release_dir" rev-parse HEAD)" = "$target_sha" ] || {
    echo "error: existing release worktree does not match $target_tag" >&2
    exit 3
  }
else
  [ ! -e "$release_dir" ] || { echo "error: non-worktree path exists: $release_dir" >&2; exit 3; }
  git worktree add --detach "$release_dir" "$target_tag"
fi
if [ -f "$release_dir/scripts/selfhost/dsh-agent.json" ] && [ -z "${MULTICA_DSH_ACCEPTANCE_CMD:-}" ]; then
  echo "error: this candidate requires MULTICA_DSH_ACCEPTANCE_CMD before deployment and promotion" >&2
  exit 3
fi
install -m 600 .env "$release_dir/.env"
if [ -f docker-compose.lan.yml ]; then
  install -m 600 docker-compose.lan.yml "$release_dir/docker-compose.lan.yml"
fi

compose=(--project-directory "$release_dir" --env-file "$release_dir/.env")
compose+=(-f "$release_dir/docker-compose.selfhost.yml")
if [ -f "$release_dir/docker-compose.lan.yml" ]; then
  compose+=(-f "$release_dir/docker-compose.lan.yml")
fi
compose+=(-f "$release_dir/docker-compose.selfhost.build.yml")
dc() { docker compose "${compose[@]}" "$@"; }

deployed_sha="$(cat "$STATE_DIR/deployed-sha" 2>/dev/null || true)"
reported_commit="$(curl -fsS --max-time 20 "$HEALTH_URL" 2>/dev/null | health_commit 2>/dev/null || true)"
if [ "$deployed_sha" = "$target_sha" ] && [ "$reported_commit" = "$target_sha" ]; then
  # The same verified commit can be reachable under a re-allocated candidate
  # name (a version rename is not a new deployment). Record the current name so
  # the promotion below and later runs agree on it.
  echo "$target_tag is already deployed and healthy"
  accept_dsh_agent
  printf '%s\n' "$target_tag" >"$STATE_DIR/deployed-tag"
  if [ "$PROMOTE" = 1 ]; then
    MULTICA_DEPLOYED_SHA="$target_sha" \
      scripts/selfhost/promote-desktop-release.sh "$target_tag"
  fi
  exit 0
fi

old_sha="$(cat "$STATE_DIR/deployed-sha" 2>/dev/null || git rev-parse HEAD)"
old_backend_image="$(dc images -q backend 2>/dev/null | head -1 || true)"
old_frontend_image="$(dc images -q frontend 2>/dev/null | head -1 || true)"
rollback_backend="multica-backend:rollback-${old_sha:0:12}"
rollback_frontend="multica-web:rollback-${old_sha:0:12}"
[ -z "$old_backend_image" ] || docker image tag "$old_backend_image" "$rollback_backend"
[ -z "$old_frontend_image" ] || docker image tag "$old_frontend_image" "$rollback_frontend"

backup="$STATE_DIR/backups/pre-${release_tag}-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
umask 077
echo "backing up PostgreSQL before $target_tag"
dc exec -T postgres sh -c 'exec pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip -c >"$backup"
gzip -t "$backup"

rollback() {
  status=$?
  trap - ERR
  echo "deployment failed; restoring previous application images" >&2
  [ -z "$old_backend_image" ] || docker image tag "$rollback_backend" multica-backend:dev
  [ -z "$old_frontend_image" ] || docker image tag "$rollback_frontend" multica-web:dev
  dc up -d --no-build --force-recreate backend frontend || true
  exit "$status"
}
trap rollback ERR

build_ok=0
for attempt in 1 2 3; do
  echo "building application images with refreshed bases (attempt $attempt/3)"
  if VERSION="${release_tag#v}" COMMIT="$target_sha" DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      dc build --pull backend frontend; then
    build_ok=1
    break
  fi
  sleep $((attempt * 10))
done
if [ "$build_ok" -ne 1 ]; then
  echo "warning: registry refresh failed after three attempts; using cached base images" >&2
  VERSION="${release_tag#v}" COMMIT="$target_sha" DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    dc build backend frontend
fi
dc up -d --no-deps --force-recreate backend frontend

deadline=$((SECONDS + WAIT_SECONDS))
until curl -fsS --max-time 20 "$HEALTH_URL" >/dev/null && \
      curl -fsS --max-time 20 "$LOGIN_URL" >/dev/null; do
  if (( SECONDS >= deadline )); then
    echo "health gate timed out for $target_tag" >&2
    false
  fi
  sleep 5
done

running="$(dc ps --status running --services)"
grep -Fxq backend <<<"$running"
grep -Fxq frontend <<<"$running"
grep -Fxq postgres <<<"$running"
reported_commit="$(curl -fsS --max-time 20 "$HEALTH_URL" | health_commit)"
[ "$reported_commit" = "$target_sha" ] || {
  echo "health gate reported commit $reported_commit, expected $target_sha" >&2
  false
}
accept_dsh_agent

trap - ERR
printf '%s\n' "$target_tag" >"$STATE_DIR/deployed-tag"
printf '%s\n' "$target_sha" >"$STATE_DIR/deployed-sha"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STATE_DIR/deployed-at"
echo "Ubuntu deployment verified: $target_tag ($target_sha)"

if [ "$PROMOTE" = 1 ]; then
  MULTICA_DEPLOYED_SHA="$target_sha" \
    scripts/selfhost/promote-desktop-release.sh "$target_tag"
fi

# Keep the five newest local database recovery points.
ls -1t "$STATE_DIR"/backups/pre-*.sql.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
