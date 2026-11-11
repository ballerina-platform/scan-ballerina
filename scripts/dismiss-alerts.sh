#!/usr/bin/env bash
# Step 9: after the upload to code scanning, keeps the code scanning alerts in line with the
# suppressions, since code scanning ignores SARIF suppressions. Alerts are matched to findings by
# rule, file, line and column. Every failure is a warning, so that it never fails the scan.
#   - On the default branch (DEFAULT_BRANCH=true), dismisses the alert of each suppressed finding as
#     "won't fix" with the suppression's justification, so the accepted finding can still be
#     audited, and reopens an alert this step dismissed once its finding is reported again without
#     a suppression.
#   - On other branches, warns about each finding whose alert this step dismissed on the default
#     branch but which is no longer suppressed, since code scanning matches it to that dismissed
#     alert and shows nothing new until the change is merged.
# It first waits until code scanning has processed the upload, so that the alerts are current.
#
# Inputs (environment): SCAN_WORK_DIR, GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_REF, GITHUB_API_URL,
# GITHUB_EVENT_PATH, DEFAULT_BRANCH, SARIF_ID, CATEGORY.
# Reads: $SCAN_WORK_DIR/results.json and $SCAN_WORK_DIR/merged.sarif, written by merge-sarif.sh.
# Writes: $SCAN_WORK_DIR/alerts.json, with the number of alerts dismissed, reopened and failed to
# change, left-open (the suppressed findings whose alerts stay open because the alerts could not be
# listed), reintroduced (findings whose suppression was removed off the default branch), pending
# (true when the upload was not processed in time) and error (true when the step stopped early).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
REPO_API="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}/code-scanning"
API="$REPO_API/alerts"
# Marks the alerts this step dismissed, so that it reopens no alert dismissed by hand.
MARKER="Suppressed in source with @scan:Suppress"
REASON="won't fix"
# The longest dismissed_comment code scanning accepts.
COMMENT_LIMIT=280
# How long to wait for code scanning to process the upload, on top of the wait of upload-sarif.
PROCESSING_TIMEOUT=180

# Any unexpected failure, such as a response that is not JSON, ends the step with a warning.
# shellcheck disable=SC2329
on_exit() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    log_warning "Could not finish updating the code scanning alerts of suppressed findings. See the log of this step."
    jq -n '{error: true}' > "$WORK/alerts.json"
  fi
  exit 0
}
trap on_exit EXIT

echo '{}' > "$WORK/alerts.json"
TOOL="$(jq -r '.runs[0].tool.driver.name // "Ballerina Scan Tool"' "$WORK/merged.sarif")"

gh_api() {
  curl "${CURL_OPTS[@]}" --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN:?GITHUB_TOKEN is not set}" \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

# Waits until code scanning has processed upload $1. Fails when it is not processed in time.
wait_for_processing() {
  local deadline=$((SECONDS + PROCESSING_TIMEOUT)) status
  [ -n "$1" ] || return 0
  while :; do
    status="$(gh_api "$REPO_API/sarifs/$1" | jq -r '.processing_status // ""')" || status=""
    case "$status" in
      complete) return 0 ;;
      failed) log_warning "Code scanning could not process the upload $1, so no alert was changed." && return 1 ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# Prints every alert of the tool on ref $1 in state $2, one JSON object per line. Stops at the
# first page with fewer than the most items a page holds.
list_alerts() {
  local page=1 body count
  while :; do
    body="$(gh_api -G "$API" --data-urlencode "ref=$1" --data-urlencode "tool_name=$TOOL" \
      -d "state=$2" -d per_page=100 -d "page=$page")" || return 1
    count="$(jq 'length' <<< "$body")"
    jq -c '.[]' <<< "$body"
    [ "$count" -eq 100 ] || return 0
    page=$((page + 1))
  done
}

alert_changes() {
  jq -sc -f "$SCRIPT_DIR/alert-changes.jq" --slurpfile results "$WORK/results.json" \
    --arg category "$(trim "${CATEGORY:-bal-scan}")" --arg marker "$MARKER" --arg reason "$REASON" \
    --argjson limit "$COMMENT_LIMIT" --arg mode "$1" "$2"
}

if ! wait_for_processing "${SARIF_ID:-}"; then
  log_warning "Code scanning had not finished processing the upload after ${PROCESSING_TIMEOUT}s, so the alerts of suppressed findings were not updated. The next run updates them."
  jq -n '{pending: true}' > "$WORK/alerts.json"
  exit 0
fi

ALERTS="$WORK/alerts-list.jsonl"
: > "$ALERTS"

if [ "${DEFAULT_BRANCH:-false}" != true ]; then
  # Off the default branch: the alerts this step dismissed there whose findings are now reported
  # without a suppression.
  BRANCH="$(jq -r '.repository.default_branch // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
  [ -n "$BRANCH" ] || exit 0
  if ! list_alerts "refs/heads/$BRANCH" dismissed >> "$ALERTS"; then
    echo "Could not list the code scanning alerts of $BRANCH, so removed suppressions are not checked."
    exit 0
  fi
  REINTRODUCED="$(alert_changes reintroduced "$ALERTS")"
  COUNT=0
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    COUNT=$((COUNT + 1))
    # GitHub shows at most 10 warnings per step.
    [ "$COUNT" -le 10 ] || continue
    IFS=$'\t' read -r file line rule url < <(jq -r '[.file, .line, .rule, .url] | @tsv' <<< "$item")
    echo "::warning file=$(escape_property "$file"),line=$line,title=$(escape_property "bal scan ($(trim "${CATEGORY:-bal-scan}"))")::$(escape_data "The suppression of this $rule finding was removed. Its alert stays dismissed on $BRANCH until this change is merged, when the action reopens it: $url")"
  done <<< "$REINTRODUCED"
  echo "Findings whose suppression was removed: $COUNT."
  jq -n --argjson n "$COUNT" --arg branch "$BRANCH" '{reintroduced: $n, branch: $branch}' > "$WORK/alerts.json"
  exit 0
fi

REF="${GITHUB_REF:?GITHUB_REF is not set}"
for state in open dismissed; do
  if ! list_alerts "$REF" "$state" >> "$ALERTS"; then
    OPEN="$(jq '[.[] | select(.suppressed)] | length' "$WORK/results.json")"
    log_warning "Could not list the code scanning alerts, so the alerts of $OPEN suppressed finding(s) stay open and no alert was reopened. The token needs the security-events: write permission."
    jq -n --argjson n "$OPEN" '{dismissed: 0, reopened: 0, failed: 0, "left-open": $n}' > "$WORK/alerts.json"
    exit 0
  fi
done

CHANGES="$(alert_changes change "$ALERTS")"

DISMISSED=0
REOPENED=0
FAILED=0
while IFS= read -r item; do
  [ -n "$item" ] || continue
  number="$(jq -r '.number' <<< "$item")"
  change="$(jq -c '.change' <<< "$item")"
  if gh_api -X PATCH "$API/$number" -d "$change" > /dev/null; then
    if [ "$(jq -r '.state' <<< "$change")" = dismissed ]; then DISMISSED=$((DISMISSED + 1)); else REOPENED=$((REOPENED + 1)); fi
  else
    FAILED=$((FAILED + 1))
  fi
done <<< "$CHANGES"

[ "$FAILED" -eq 0 ] \
  || log_warning "Could not change $FAILED code scanning alert(s) of suppressed findings. The token needs the security-events: write permission."
echo "Dismissed $DISMISSED code scanning alert(s) of suppressed findings, and reopened $REOPENED."
jq -n --argjson d "$DISMISSED" --argjson r "$REOPENED" --argjson f "$FAILED" \
  '{dismissed: $d, reopened: $r, failed: $f, "left-open": 0}' > "$WORK/alerts.json"
