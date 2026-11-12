#!/usr/bin/env bash
# Step 10, for pull_request and pull_request_target runs: comments the suppression's reason of each
# suppressed finding on a line the pull request adds. Code scanning shows these findings as alerts,
# which are not dismissed off the default branch, and comments each new one at its line. The reason
# is posted as a reply in that comment's thread, once code scanning has commented, and as a comment
# of its own at the line when code scanning does not comment in time, or at all, such as for a
# finding matching an alert dismissed before. A comment already there is edited rather than
# repeated, and one whose finding is no longer suppressed says so. It also keeps one comment in the
# pull request's conversation listing the @scan:Suppress annotations it adds and removes. Every
# failure is a warning, so that it never fails the scan.
#
# Inputs (environment): SCAN_WORK_DIR, GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_API_URL,
# GITHUB_SERVER_URL, GITHUB_WORKSPACE, GITHUB_EVENT_PATH, CATEGORY, CODE_SCANNING (true when the
# findings were uploaded to code scanning, so that its comments are waited for).
# Reads: $SCAN_WORK_DIR/results.json and $SCAN_WORK_DIR/merged.sarif, written by merge-sarif.sh, and
# $SCAN_WORK_DIR/suppression-changes.json, written by suppression-changes.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
BOT_LOGIN="github-advanced-security[bot]"
# How long to wait for code scanning to comment the alerts, and how often to look.
BOT_TIMEOUT="${BOT_TIMEOUT:-120}"
BOT_POLL="${BOT_POLL:-10}"

# shellcheck disable=SC2329
on_exit() {
  [ $? -eq 0 ] || log_warning "Could not comment the suppressed findings on the pull request. The token needs the pull-requests: write permission. See the log of this step."
  exit 0
}
trap on_exit EXIT

NUMBER="$(jq -r '.pull_request.number // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
HEAD_SHA="$(jq -r '.pull_request.head.sha // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
[ -n "$NUMBER" ] && [ -n "$HEAD_SHA" ] || { echo "Not a pull request run, so nothing is commented." && exit 0; }

REPO_API="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
PULLS="$REPO_API/pulls"
CATEGORY_NAME="$(trim "${CATEGORY:-bal-scan}")"
TOOL="$(jq -r '.runs[0].tool.driver.name // "Ballerina Scan Tool"' "$WORK/merged.sarif" 2> /dev/null || echo "Ballerina Scan Tool")"
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
while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  IFS=$'\t' read -r file line < <(jq -r '[.file, .line] | @tsv' <<< "$finding")
  text="$(sed -n "${line}p" "$ROOT/$file" 2> /dev/null | tr -d '\r' || true)"
  jq -c --arg text "$text" '. + {text: $text}' <<< "$finding"
done < <(jq -c '.[] | select(.suppressed and .severity != "none")' "$WORK/results.json") | jq -s . > "$WORK/pr-suppressed.json"

if ! CURRENT="$(gh_api "$PULLS/$NUMBER" | jq -r '.head.sha // ""')" || [ -z "$CURRENT" ]; then
  log_warning "Could not read pull request #$NUMBER, so the suppressed findings were not commented."
  exit 0
fi
# Comments are placed on the head's diff, which a newer push changes. Its own run comments then.
if [ "$CURRENT" != "$HEAD_SHA" ]; then
  echo "Pull request #$NUMBER has moved on to $CURRENT, so the run for that commit comments the suppressed findings."
  exit 0
fi

# One comment in the conversation of the pull request lists the @scan:Suppress annotations it adds
# and removes, as suppression-changes.sh found them. Later runs edit it, and none is written until
# there is a change to list.
post_summary() {
  local changes="$WORK/suppression-changes.json" comments="$REPO_API/issues/$NUMBER/comments" body found
  jq -e 'has("added")' "$changes" > /dev/null 2>&1 || return 0
  if ! get_all "$comments" | jq -s 'add // []' > "$WORK/pr-issue-comments.json"; then
    log_warning "Could not read the comments of pull request #$NUMBER, so the suppression changes were not listed."
    return 0
  fi
  body="$(jq -r -L "$SCRIPT_DIR" --arg category "$CATEGORY_NAME" --arg short "${HEAD_SHA:0:7}" \
    --arg server "${GITHUB_SERVER_URL:-https://github.com}" --arg repo "$GITHUB_REPOSITORY" \
    --argjson code_scanning "$([ "${CODE_SCANNING:-false}" = true ] && echo true || echo false)" '
    include "common";
    # Untrusted text in a code span, which shows HTML, mentions and Markdown as they are.
    def code: gsub("\r?\n"; " ") | gsub("`"; "'"'"'") | if length > 300 then .[0:300] + "…" else . end | "`\(.)`";
    def item($sha; $line): "- [\("\(.file):\($line)" | code)](\($server)/\($repo)/blob/\($sha)/\(.file | uri_path)#L\($line)): \(.text | code)";
    def list($items; f): ($items[:50] | map(f)) + (if ($items | length) > 50 then ["- …and \(($items | length) - 50) more"] else [] end);
    . as $c
    | ["<!-- scan-ballerina:suppression-changes:\($category) -->", "### `bal scan` suppression changes (\($category | code))", ""]
    + if (.added | length) + (.removed | length) == 0 then
        ["This pull request no longer adds or removes any `@scan:Suppress` annotation."]
      else
        (if (.added | length) > 0 then
          ["**Added (\(.added | length))**: the findings of these rules are left out of the counts and the gate"
            + (if $code_scanning then ", and code scanning shows no new alert for those already on \($c.branch)" else "" end)
            + ", so each one needs a reviewer'"'"'s explicit acceptance.", ""]
          + list(.added; item($c.head; .line))
        else [] end)
        + (if (.added | length) > 0 and (.removed | length) > 0 then [""] else [] end)
        + (if (.removed | length) > 0 then
          ["**Removed (\(.removed | length))**: the findings these suppressed are reported again"
            + (if $code_scanning then ". Code scanning matches them to their alerts dismissed on \($c.branch), so it does not show them as new, and the action reopens the alerts when this change is merged" else "" end)
            + ".", ""]
          + list(.removed; item($c.base; ."base-line"))
        else [] end)
      end
    + ["", "_As of \($short)._"]
    | join("\n")' "$changes")"
  found="$(jq -c --arg m "<!-- scan-ballerina:suppression-changes:$CATEGORY_NAME -->" \
    'map(select((.body // "") | startswith($m))) | first // {}' "$WORK/pr-issue-comments.json")"
  if [ "$(jq -r '.id // ""' <<< "$found")" = "" ]; then
    jq -e '(.added | length) + (.removed | length) > 0' "$changes" > /dev/null || return 0
    jq -n --arg body "$body" '{body: $body}' | gh_api -X POST "$comments" --data-binary @- > /dev/null \
      || log_warning "Could not list the suppression changes on pull request #$NUMBER. The token needs the pull-requests: write permission."
  elif [ "$(jq -r '.body' <<< "$found")" != "$body" ]; then
    jq -n --arg body "$body" '{body: $body}' \
      | gh_api -X PATCH "$REPO_API/issues/comments/$(jq -r '.id' <<< "$found")" --data-binary @- > /dev/null \
      || log_warning "Could not update the list of suppression changes on pull request #$NUMBER. The token needs the pull-requests: write permission."
  fi
}
post_summary

load_comments() {
  get_all "$PULLS/$NUMBER/comments" | jq -s 'add // []' > "$WORK/pr-comments.json"
}
if ! get_all "$PULLS/$NUMBER/files" | jq -s 'add // []' > "$WORK/pr-files.json" || ! load_comments; then
  log_warning "Could not read the changes and comments of pull request #$NUMBER, so the suppressed findings were not commented."
  exit 0
fi

# The suppressed findings on lines the pull request adds, whose text is the same in the head.
jq '
  def added: reduce (split("\n")[] | rtrimstr("\r")) as $l ({n: 0, out: {}};
    if $l | startswith("@@") then .n = ($l | capture("\\+(?<s>[0-9]+)").s | tonumber)
    elif $l | startswith("+") then .out[.n | tostring] = $l[1:] | .n += 1
    elif ($l | startswith("-")) or ($l | startswith("\\")) then .
    else .n += 1 end) | .out;
  (map({key: .filename, value: (.patch // "" | added)}) | from_entries) as $added
  | $suppressed[0] | map(select($added[.file][.line | tostring] as $t | $t != null and $t == .text))
' --slurpfile suppressed "$WORK/pr-suppressed.json" "$WORK/pr-files.json" > "$WORK/pr-targets.json"

# The rule and tool of each alert code scanning commented at a target line, by alert number.
echo '{}' > "$WORK/pr-alerts.json"
read_alerts() {
  local n alert
  for n in $(jq -r --arg bot "$BOT_LOGIN" --slurpfile targets "$WORK/pr-targets.json" --slurpfile known "$WORK/pr-alerts.json" '
    .[] | select(.user.login == $bot and .in_reply_to_id == null) | . as $c
    | select(any($targets[0][]; .file == $c.path and .line == $c.line))
    | (.body // "") | capture("/security/code-scanning/(?<n>[0-9]+)").n
    | select($known[0][.] == null)' "$WORK/pr-comments.json" | sort -u); do
    alert="$(gh_api "$REPO_API/code-scanning/alerts/$n" | jq -c '{rule: .rule.id, tool: .tool.name}')" || continue
    jq --arg n "$n" --argjson a "$alert" '.[$n] = $a' "$WORK/pr-alerts.json" > "$WORK/pr-alerts.tmp"
    mv "$WORK/pr-alerts.tmp" "$WORK/pr-alerts.json"
  done
}

# Writes the actions to take: create (a reply when code scanning commented the alert) or update.
PLAN='
  def marker($t): "<!-- scan-ballerina:suppression:\($category):\($t.rule) -->";
  # Untrusted text, such as a reason from a fork, made one line, without HTML or mentions.
  def safe: gsub("\r?\n"; " ") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("@"; "@​");
  def clip($n): if length > $n then .[0:$n] + "…" else . end;
  def reason: if .justification == "" then "_No reason given_" else .justification | clip(1000) | safe end;
  def header: "**Suppression detected**";
  def note: "_A `bal scan` suppression (`@scan:Suppress`) is not dismissed automatically in pull requests, so it needs a reviewer'"'"'s explicit acceptance. Its alert is dismissed only by the scan of the default branch after the merge._";
  def reply_body: [marker(.), header, "", "**Reason:** \(reason)", "", note] | join("\n");
  def own_body: [marker(.), header, "", "> **\(.severity)** `\(.rule)`: \(.message | clip(1000) | safe)", ">", "> **Reason:** \(reason)", "", note] | join("\n");
  ($comments[0] | map(select((.body // "") | startswith("<!-- scan-ballerina:suppression:\($category):")))) as $ours
  | ($comments[0] | map(select(.user.login == $bot and .in_reply_to_id == null)
      | . + {alert: ((.body // "") | [capture("/security/code-scanning/(?<n>[0-9]+)").n] | first | $alerts[0][. // ""])})
      | map(select(.alert.tool == $tool))) as $threads
  | ($targets[0][] as $t
    | ($ours | map(select(.path == $t.file and .line == $t.line and (.body | startswith(marker($t))))) | first) as $c
    | ($threads | map(select(.path == $t.file and .line == $t.line and .alert.rule == $t.rule)) | first) as $thread
    | if $c != null then
        (if $c.in_reply_to_id != null then $t | reply_body else $t | own_body end) as $body
        | if $c.body == $body then empty else {action: "update", id: $c.id, body: $body} end
      elif $thread != null then {action: "create", reply_to: $thread.id, body: ($t | reply_body)}
      elif $final then {action: "create", path: $t.file, line: $t.line, body: ($t | own_body)}
      else {action: "wait"} end),
  ($ours[] | select(.line != null) | . as $c
    | select(any($targets[0][]; . as $t | $t.file == $c.path and $t.line == $c.line and ($c.body | startswith(marker($t)))) | not)
    | select(.body | contains("is no longer suppressed") | not)
    | {action: "update", id: .id, body: "\(.body | split("\n") | first)\nThis finding is no longer suppressed, as of \($short)."})
'
plan() {
  jq -c -n --slurpfile targets "$WORK/pr-targets.json" --slurpfile comments "$WORK/pr-comments.json" \
    --slurpfile alerts "$WORK/pr-alerts.json" --arg category "$CATEGORY_NAME" --arg bot "$BOT_LOGIN" \
    --arg tool "$TOOL" --arg short "${HEAD_SHA:0:7}" --argjson final "$1" "$PLAN"
}

# Waits until code scanning has commented the alert of each target without a comment of ours.
if [ "${CODE_SCANNING:-false}" = true ] && [ "$(jq 'length' "$WORK/pr-targets.json")" -gt 0 ]; then
  DEADLINE=$((SECONDS + BOT_TIMEOUT))
  while :; do
    read_alerts
    plan false | grep -q '"action":"wait"' || break
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
      echo "Code scanning did not comment every alert within ${BOT_TIMEOUT}s, so the rest get comments of their own."
      break
    fi
    sleep "$BOT_POLL"
    load_comments || { log_warning "Could not read the comments of pull request #$NUMBER, so the suppressed findings were not commented." && exit 0; }
  done
fi

CREATED=0 REPLIED=0 UPDATED=0 FAILED=0
while IFS= read -r item; do
  [ -n "$item" ] || continue
  case "$(jq -r '.action + (if .reply_to then ":reply" else "" end)' <<< "$item")" in
    create:reply)
      jq -c '{body}' <<< "$item" \
        | gh_api -X POST "$PULLS/$NUMBER/comments/$(jq -r '.reply_to' <<< "$item")/replies" --data-binary @- > /dev/null \
        && REPLIED=$((REPLIED + 1)) || FAILED=$((FAILED + 1))
      ;;
    create)
      jq -c --arg sha "$HEAD_SHA" '{body, commit_id: $sha, path, line, side: "RIGHT"}' <<< "$item" \
        | gh_api -X POST "$PULLS/$NUMBER/comments" --data-binary @- > /dev/null \
        && CREATED=$((CREATED + 1)) || FAILED=$((FAILED + 1))
      ;;
    update)
      jq -c '{body}' <<< "$item" \
        | gh_api -X PATCH "$PULLS/comments/$(jq -r '.id' <<< "$item")" --data-binary @- > /dev/null \
        && UPDATED=$((UPDATED + 1)) || FAILED=$((FAILED + 1))
      ;;
  esac
done < <(plan true)

[ "$FAILED" -eq 0 ] \
  || log_warning "Could not write $FAILED comment(s) on pull request #$NUMBER. The token needs the pull-requests: write permission."
echo "Pull request #$NUMBER: $(jq 'length' "$WORK/pr-targets.json") suppressed finding(s) on added lines; replies $REPLIED, comments $CREATED, updated $UPDATED."
