#!/usr/bin/env bash
# Step 10, for pull_request and pull_request_target runs: comments each suppressed finding on a line
# the pull request adds, at that line, with the finding's message and the suppression's reason.
# Code scanning shows these findings as alerts, which are not dismissed off the default branch, so
# the comment sits next to the alert's own and tells reviewers why the finding was accepted.
# A comment already on the line is edited rather than repeated, and one whose line no longer has a
# suppressed finding says so. Every failure is a warning, so that it never fails the scan.
#
# Inputs (environment): SCAN_WORK_DIR, GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_API_URL,
# GITHUB_WORKSPACE, GITHUB_EVENT_PATH, CATEGORY.
# Reads: $SCAN_WORK_DIR/results.json, written by merge-sarif.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"

# shellcheck disable=SC2329
on_exit() {
  [ $? -eq 0 ] || log_warning "Could not comment the suppressed findings on the pull request. The token needs the pull-requests: write permission. See the log of this step."
  exit 0
}
trap on_exit EXIT

NUMBER="$(jq -r '.pull_request.number // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
HEAD_SHA="$(jq -r '.pull_request.head.sha // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
[ -n "$NUMBER" ] && [ -n "$HEAD_SHA" ] || { echo "Not a pull request run, so nothing is commented." && exit 0; }

PULLS="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}/pulls"
CATEGORY_NAME="$(trim "${CATEGORY:-bal-scan}")"
MARKER="<!-- scan-ballerina:suppression:$CATEGORY_NAME -->"
ROOT="$(workspace_root)"

gh_api() {
  curl "${CURL_OPTS[@]}" --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN:?GITHUB_TOKEN is not set}" \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

# Prints every item of a paginated list as one JSON array. A response that is not a list fails.
get_all() {
  local page=1 body
  while :; do
    body="$(gh_api -G "$1" -d per_page=100 -d "page=$page")" || return 1
    jq -e 'type == "array"' <<< "$body" > /dev/null || return 1
    printf '%s\n' "$body"
    [ "$(jq 'length' <<< "$body")" -eq 100 ] || return 0
    page=$((page + 1))
  done
}

# Each suppressed finding with the text of its line in the checked out commit, which the diff of
# the pull request's head is compared with, since the scan may have run on the merge commit.
TARGETS="$WORK/pr-targets.json"
while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  IFS=$'\t' read -r file line < <(jq -r '[.file, .line] | @tsv' <<< "$finding")
  text="$(sed -n "${line}p" "$ROOT/$file" 2> /dev/null | tr -d '\r' || true)"
  jq -c --arg text "$text" '. + {text: $text}' <<< "$finding"
done < <(jq -c '.[] | select(.suppressed and .severity != "none")' "$WORK/results.json") | jq -s . > "$TARGETS"

if ! CURRENT="$(gh_api "$PULLS/$NUMBER" | jq -r '.head.sha // ""')" || [ -z "$CURRENT" ]; then
  log_warning "Could not read pull request #$NUMBER, so the suppressed findings were not commented."
  exit 0
fi
# Comments are placed on the head's diff, which a newer push changes. Its own run comments then.
if [ "$CURRENT" != "$HEAD_SHA" ]; then
  echo "Pull request #$NUMBER has moved on to $CURRENT, so the run for that commit comments the suppressed findings."
  exit 0
fi
if ! get_all "$PULLS/$NUMBER/files" | jq -s 'add // []' > "$WORK/pr-files.json" \
  || ! get_all "$PULLS/$NUMBER/comments" | jq -s 'add // []' > "$WORK/pr-comments.json"; then
  log_warning "Could not read the changes and comments of pull request #$NUMBER, so the suppressed findings were not commented."
  exit 0
fi

# One action per line: create, or update a comment of this category already there.
ACTIONS="$(jq -c -n --slurpfile targets "$TARGETS" --slurpfile files "$WORK/pr-files.json" \
  --slurpfile comments "$WORK/pr-comments.json" --arg marker "$MARKER" --arg category "$CATEGORY_NAME" \
  --arg short "${HEAD_SHA:0:7}" '
  # Untrusted text, such as a reason from a fork, made one line, without HTML or mentions.
  def safe: gsub("\r?\n"; " ") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("@"; "@​");
  def clip($n): if length > $n then .[0:$n] + "…" else . end;
  # The lines a patch adds, by their number in the new file.
  def added: reduce (split("\n")[] | rtrimstr("\r")) as $l ({n: 0, out: {}};
    if $l | startswith("@@") then .n = ($l | capture("\\+(?<s>[0-9]+)").s | tonumber)
    elif $l | startswith("+") then .out[.n | tostring] = $l[1:] | .n += 1
    elif ($l | startswith("-")) or ($l | startswith("\\")) then .
    else .n += 1 end) | .out;
  ($files[0] | map({key: .filename, value: (.patch // "" | added)}) | from_entries) as $added
  | ($comments[0] | map(select((.body // "") | contains($marker)))) as $ours
  | [$targets[0][] | select($added[.file][.line | tostring] as $t | $t != null and $t == .text)]
  | group_by([.file, .line])
  | map({path: .[0].file, line: .[0].line, body: ([
      $marker,
      "**Suppressed in source with `@scan:Suppress`** (bal scan, \($category | safe))",
      ""]
      + map("> **\(.severity)** `\(.rule)`: \(.message | clip(1000) | safe)\n>\n> **Reason:** \(if .justification == "" then "_No reason given_" else .justification | clip(1000) | safe end)\n")
      + ["Code scanning still reports this finding, and its alert is not dismissed automatically. A repository owner can dismiss it after review."]
      | join("\n"))}) as $wanted
  | ($wanted[] | . as $w | ($ours | map(select(.path == $w.path and .line == $w.line)) | first) as $c
      | if $c == null then {action: "create"} + $w
        elif $c.body == $w.body then empty
        else {action: "update", id: $c.id} + $w end),
    ($ours[] | select(.line != null) | . as $c
      | select(any($wanted[]; .path == $c.path and .line == $c.line) | not)
      | select(.body | contains("is no longer suppressed") | not)
      | {action: "update", id: .id, path: .path, line: .line,
         body: "\($marker)\nThe finding at this line is no longer suppressed, as of \($short)."})
')"

CREATED=0 UPDATED=0 FAILED=0
while IFS= read -r item; do
  [ -n "$item" ] || continue
  if [ "$(jq -r '.action' <<< "$item")" = create ]; then
    jq -c --arg sha "$HEAD_SHA" '{body, commit_id: $sha, path, line, side: "RIGHT"}' <<< "$item" \
      | gh_api -X POST "$PULLS/$NUMBER/comments" --data-binary @- > /dev/null \
      && CREATED=$((CREATED + 1)) || FAILED=$((FAILED + 1))
  else
    jq -c '{body}' <<< "$item" \
      | gh_api -X PATCH "$PULLS/comments/$(jq -r '.id' <<< "$item")" --data-binary @- > /dev/null \
      && UPDATED=$((UPDATED + 1)) || FAILED=$((FAILED + 1))
  fi
done <<< "$ACTIONS"

[ "$FAILED" -eq 0 ] \
  || log_warning "Could not write $FAILED comment(s) on pull request #$NUMBER. The token needs the pull-requests: write permission."
echo "Pull request #$NUMBER: $(jq 'length' "$TARGETS") suppressed finding(s); comments created $CREATED, updated $UPDATED."
