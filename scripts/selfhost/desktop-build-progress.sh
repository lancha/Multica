#!/usr/bin/env bash
set -euo pipefail

# Ubuntu bridge from the GitHub publisher progress protocol to a Multica issue.
CONFIG="${MULTICA_CONFIG:-$HOME/.multica/config.json}"
PROJECT_ID="${MULTICA_BUILD_PROJECT_ID:?set the destination build project explicitly}"
GITHUB_PIPELINE="${MULTICA_GITHUB_PIPELINE:-$HOME/.local/lib/multica-github/pipeline.py}"
STATE_DIR="${MULTICA_DEPLOY_STATE_DIR:-$HOME/.local/state/multica-deploy}/desktop-progress"

[ -r "$CONFIG" ] || exit 0
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
base="${MULTICA_SERVER_URL:-$(jq -r .server_url "$CONFIG")}"
token="$(jq -r .token "$CONFIG")"
workspace="${MULTICA_WORKSPACE_ID:-$(jq -r .workspace_id "$CONFIG")}"
[ -n "$base" ] && [ -n "$token" ] && [ -n "$workspace" ] || exit 0

lines=""
relay_log="${MULTICA_MAC_PROGRESS_LOG:-${MULTICA_DEPLOY_STATE_DIR:-$HOME/.local/state/multica-deploy}/mac-progress.log}"
if [ -r "$relay_log" ]; then
  # Preserve milestone order within the same second and remove duplicate records.
  lines="$( { printf '%s\n' "$lines"; tail -200 "$relay_log"; } | grep ' PROGRESS v' | awk '!seen[$0]++' | LC_ALL=C sort -s -k1,1)"
fi
[ -n "$lines" ] || exit 0
tag="$(printf '%s\n' "$lines" | tail -1 | awk '{print $3}')"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-mikeux\.[0-9]+)?$ ]] || exit 0

api() { curl -fsS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' "$@"; }
title="Mac App 自动构建 · $tag"
project="$(api "$base/api/projects/$PROJECT_ID?workspace_id=$workspace")"
[ "$(printf '%s' "$project" | jq -r .workspace_id)" = "$workspace" ] || {
  echo 'error: build project is outside the configured workspace' >&2
  exit 2
}
issues="$(api "$base/api/issues?workspace_id=$workspace&project_id=$PROJECT_ID&limit=100")"
issue="$(printf '%s' "$issues" | jq -c --arg title "$title" '.issues[] | select(.title==$title)' | head -1)"
if [ -z "$issue" ]; then
  payload="$(jq -nc --arg title "$title" --arg project "$PROJECT_ID" --arg tag "$tag" '{title:$title,project_id:$project,status:"in_progress",priority:"none",description:("自动化发布链构建任务；标签 "+$tag+"；目标 macOS arm64 DMG/ZIP。进度由 Ubuntu 自动回写。")}' )"
  issue="$(api -X POST --data "$payload" "$base/api/issues?workspace_id=$workspace")"
fi

issue_id="$(printf '%s' "$issue" | jq -r .id)"
identifier="$(printf '%s' "$issue" | jq -r .identifier)"
state="$STATE_DIR/$tag"
previous="$(cat "$state" 2>/dev/null || true)"
progress_state="$STATE_DIR/$tag.progress"
status_state="$STATE_DIR/$tag.status"
if [[ "$previous" =~ ^[0-9]+$ ]] && [ ! -f "$progress_state" ]; then printf '%s\n' "$previous" >"$progress_state"; fi
if [ "$previous" = FAILED ] && [ ! -f "$status_state" ]; then printf 'FAILED\n' >"$status_state"; fi
previous_progress="$(cat "$progress_state" 2>/dev/null || true)"
previous_status="$(cat "$status_state" 2>/dev/null || true)"

set_issue_status() {
  status="$1"
  issue="$(api "$base/api/issues/$issue_id?workspace_id=$workspace")"
  revision="$(printf '%s' "$issue" | jq -r .revision)"
  update="$(jq -nc --arg status "$status" --argjson revision "$revision" '{status:$status,expected_revision:$revision}')"
  api -X PUT --data "$update" "$base/api/issues/$issue_id?workspace_id=$workspace" >/dev/null
}

post_comment() {
  comment="$(jq -nc --arg content "$1" '{content:$content}')"
  api -X POST --data "$comment" "$base/api/issues/$issue_id/comments?workspace_id=$workspace" >/dev/null
}

# A workspace member can restart a failed build by posting an exact standalone
# comment: 重新运行. Each comment id is consumed at most once.
comments="$(api "$base/api/issues/$issue_id/comments?workspace_id=$workspace")"
rerun="$(printf '%s' "$comments" | jq -c '(if type == "object" then .comments else . end) | map(select((.content | gsub("^[[:space:]]+|[[:space:]]+$"; "")) == "重新运行")) | last // empty')"
if [ -n "$rerun" ]; then
  rerun_id="$(printf '%s' "$rerun" | jq -r .id)"
  rerun_state="$STATE_DIR/$tag.rerun"
  consumed="$(cat "$rerun_state" 2>/dev/null || true)"
  issue_status="$(printf '%s' "$issue" | jq -r .status)"
  if [ "$rerun_id" != "$consumed" ] && { [ "$issue_status" = blocked ] || [ "$previous_status" = FAILED ]; }; then
    if python3 "$GITHUB_PIPELINE" --retry "$tag"; then
      post_comment "已收到重新运行指令。GitHub 构建已进入重试队列，进度将继续自动更新。"
      set_issue_status in_progress
      printf '%s\n' "$rerun_id" >"$rerun_state"
      printf 'RUNNING\n' >"$status_state"
      previous_status=RUNNING
      printf '%s: %s rerun requested\n' "$identifier" "$tag"
    else
      post_comment "重新运行失败：请检查 Ubuntu 的 GitHub 发布服务。"
      printf '%s\n' "$rerun_id" >"$rerun_state"
    fi
  fi
fi

publish() {
  value="$1"
  message="$2"
  if [ "$value" = FAILED ]; then
    [ "$previous_status" != FAILED ] || return 0
    printf -v content '构建失败：%s\n\n自动化会保留错误并等待修复后重试。' "$message"
    status=blocked
  else
    [[ "$value" =~ ^(10|20|30|40|50|60|70|80|90|100)$ ]] || return 0
    if [[ "$previous_progress" =~ ^[0-9]+$ ]] && (( value <= previous_progress )); then return 0; fi
    printf -v content '构建进度：%s%%\n\n当前阶段：%s' "$value" "$message"
    if [ "$value" = 100 ]; then status=done; else status=in_progress; fi
  fi
  post_comment "$content"
  set_issue_status "$status"
  if [ "$value" = FAILED ]; then
    printf 'FAILED\n' >"$status_state"
    previous_status=FAILED
  else
    printf '%s\n' "$value" >"$progress_state"
    printf 'RUNNING\n' >"$status_state"
    previous_progress="$value"
    previous_status=RUNNING
  fi
  printf '%s: %s -> %s\n' "$identifier" "$tag" "$value"
}

while IFS= read -r line; do
  [ "$(printf '%s\n' "$line" | awk '{print $3}')" = "$tag" ] || continue
  value="$(printf '%s\n' "$line" | awk '{print $4}')"
  message="$(printf '%s\n' "$line" | cut -d' ' -f5-)"
  publish "$value" "$message"
done <<<"$lines"
