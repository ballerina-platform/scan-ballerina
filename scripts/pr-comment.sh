#!/usr/bin/env bash
# Step 10, for pull_request and pull_request_target runs: keeps one comment on the pull request that
# lists the suppressed findings of this category with their reasons, so reviewers see each accepted
# finding. The comment is found by a hidden marker and edited in place on each run. Once no finding
# is suppressed, an existing comment says so, and none is created. Every failure is a warning, so
# that it never fails the scan.
#
# Inputs (environment): SCAN_WORK_DIR, GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_API_URL,
# GITHUB_SERVER_URL, GITHUB_SHA, GITHUB_WORKSPACE, GITHUB_EVENT_PATH, CATEGORY.
# Reads: $SCAN_WORK_DIR/results.json, written by merge-sarif.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
# The rows a comment shows, which keeps it under the 65536 characters GitHub accepts.
MAX_ROWS=100

# shellcheck disable=SC2329
on_exit() {
  [ $? -eq 0 ] || log_warning "Could not update the pull request comment that lists the suppressed findings. The token needs the pull-requests: write permission. See the log of this step."
  exit 0
}
trap on_exit EXIT

NUMBER="$(jq -r '.pull_request.number // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
[ -n "$NUMBER" ] || { echo "Not a pull request run, so no comment is written." && exit 0; }

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
COMMENTS_API="${GITHUB_API_URL:-https://api.github.com}/repos/$REPO/issues"
CATEGORY_NAME="$(trim "${CATEGORY:-bal-scan}")"
MARKER="<!-- scan-ballerina:suppressions:$CATEGORY_NAME -->"
# The checked out commit, whose lines the findings are at: the merge commit of a pull_request run.
SHA="$(git -C "$(workspace_root)" rev-parse HEAD 2> /dev/null || true)"
SHA="${SHA:-${GITHUB_SHA:-}}"

gh_api() {
  curl "${CURL_OPTS[@]}" --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN:?GITHUB_TOKEN is not set}" \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

COUNT="$(jq '[.[] | select(.suppressed and .severity != "none")] | length' "$WORK/results.json")"

# Prints the id of the first comment with the marker, nothing when there is none.
find_comment() {
  local page=1 body
  while :; do
    body="$(gh_api -G "$COMMENTS_API/$NUMBER/comments" -d per_page=100 -d "page=$page")" || return 1
    # A response that is not a list would otherwise read as no comment, and duplicate it.
    jq -e 'type == "array"' <<< "$body" > /dev/null || return 1
    jq -r --arg m "$MARKER" 'first(.[] | select((.body // "") | contains($m)) | .id) // empty' <<< "$body" | grep . && return 0
    [ "$(jq 'length' <<< "$body")" -eq 100 ] || return 0
    page=$((page + 1))
  done
}

if ! EXISTING="$(find_comment)"; then
  log_warning "Could not read the comments of pull request #$NUMBER, so the suppressed findings were not commented."
  exit 0
fi
if [ "$COUNT" -eq 0 ] && [ -z "$EXISTING" ]; then
  echo "No suppressed findings, so no comment is written."
  exit 0
fi

BODY="$(jq -r -L "$SCRIPT_DIR" --arg marker "$MARKER" --arg category "$CATEGORY_NAME" --arg sha "$SHA" \
  --arg base "${GITHUB_SERVER_URL:-https://github.com}/$REPO" --argjson max "$MAX_ROWS" '
  include "common";
  # Text safe in a table cell: one line, no column breaks and no HTML.
  def cell: gsub("\r?\n"; " ") | gsub("\\|"; "\\|") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
  def clip($n): if length > $n then .[0:$n] + "…" else . end;
  def order: {high: 0, medium: 1, low: 2}[.] // 3;
  [.[] | select(.suppressed and .severity != "none")] | sort_by((.severity | order), .file, .line) as $rows
  | ($sha[0:7]) as $short
  | [$marker,
     "### bal scan (\($category | cell)): \($rows | length) suppressed finding(s)",
     "",
     if ($rows | length) == 0 then
       "The scan of \($short) reports no suppressed finding."
     else
       "The scan of \($short) reports these findings as suppressed in source with `@scan:Suppress`. They are left out of the counts and the gate.",
       "",
       "| Severity | Rule | Location | Reason |",
       "| --- | --- | --- | --- |",
       ($rows[0:$max][] | "| \(.severity) | `\(.rule)` | [\(.file | cell | gsub("\\["; "\\[") | gsub("]"; "\\]")):\(.line)](\($base)/blob/\($sha)/\(.file | uri_path)#L\(.line)) | \(if .justification == "" then "_No reason given_" else (.justification | clip(500) | cell) end) |"),
       if ($rows | length) > $max then "", "And \(($rows | length) - $max) more, listed in the SARIF file." else empty end
     end] | join("\n")
' "$WORK/results.json")"

PAYLOAD="$(jq -nc --arg body "$BODY" '{body: $body}')"
if [ -n "$EXISTING" ]; then
  gh_api -X PATCH "$COMMENTS_API/comments/$EXISTING" --data-binary @- <<< "$PAYLOAD" > /dev/null
  echo "Updated comment $EXISTING on pull request #$NUMBER: $COUNT suppressed finding(s)."
else
  gh_api -X POST "$COMMENTS_API/$NUMBER/comments" --data-binary @- <<< "$PAYLOAD" > /dev/null
  echo "Commented on pull request #$NUMBER: $COUNT suppressed finding(s)."
fi
