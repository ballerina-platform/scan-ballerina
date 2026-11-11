#!/usr/bin/env bash
# Step 9: after the upload to code scanning, keeps the code scanning alerts in line with the
# suppressions, since code scanning ignores SARIF suppressions. Alerts are matched to findings by
# rule, file, line and column. Every failure is a warning, so that it never fails the scan.
#   - On the default branch (DEFAULT_BRANCH=true), dismisses the alert of each suppressed finding as
#     "won't fix" with the suppression's justification, so the accepted finding can still be
#     audited. It takes over an alert dismissed by hand once its finding is suppressed, keeping its
#     reason, and records a changed justification. It reopens an alert it dismissed once its finding
#     is reported again without a suppression, and once its finding is gone, so that code scanning
#     sets it to fixed instead of leaving it dismissed.
#   - On other branches, warns about each unsuppressed finding that code scanning matches to a
#     dismissed alert, and so shows nothing new for: one this step dismissed whose suppression was
#     removed, and one dismissed by anyone whose finding the default branch no longer has, such as
#     code reintroduced after it was fixed.
# Both read the alerts of the uploaded ref, GITHUB_REF, whose locations are those of the findings
# just uploaded. It first waits until code scanning has processed the upload, so that they are current.
#
# Inputs (environment): SCAN_WORK_DIR, GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_REF, GITHUB_API_URL,
# GITHUB_EVENT_PATH, DEFAULT_BRANCH, SARIF_ID, CATEGORY.
# Reads: $SCAN_WORK_DIR/results.json and $SCAN_WORK_DIR/merged.sarif, written by merge-sarif.sh.
# Writes: $SCAN_WORK_DIR/alerts.json, with the number of alerts dismissed, recorded (taken over or
# given a changed justification), reopened, fixed and failed to change, left-open (the suppressed
# findings whose alerts stay open because the alerts could not be listed), unsuppressed (findings
# whose suppression was removed off the default branch), reintroduced (findings new to the default
# branch whose alerts are dismissed), pending (true when the upload was not processed in time) and
# error (true when the step stopped early).

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

# Waits until code scanning has processed upload $1. Returns 1 when it is not processed in time,
# and 2 when it never will be or its status cannot be read, which retrying does not change.
wait_for_processing() {
  local deadline=$((SECONDS + PROCESSING_TIMEOUT)) response code status
  [ -n "$1" ] || return 0
  while :; do
    # -w prints the HTTP status after the body, also when curl fails on an HTTP error.
    response="$(gh_api -w '\n%{http_code}' "$REPO_API/sarifs/$1")" || true
    code="${response##*$'\n'}"
    case "$code" in
      401 | 403 | 404)
        log_warning "Could not read the processing status of the upload $1 (HTTP $code), so no alert was changed. The token needs the security-events: read permission."
        return 2
        ;;
    esac
    status="$(jq -r '.processing_status // ""' <<< "${response%$'\n'*}" 2> /dev/null)" || status=""
    case "$status" in
      complete) return 0 ;;
      failed) log_warning "Code scanning could not process the upload $1, so no alert was changed." && return 2 ;;
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

PROCESSING=0
wait_for_processing "${SARIF_ID:-}" || PROCESSING=$?
if [ "$PROCESSING" -eq 2 ]; then
  jq -n '{error: true}' > "$WORK/alerts.json"
  exit 0
elif [ "$PROCESSING" -ne 0 ]; then
  log_warning "Code scanning had not finished processing the upload after ${PROCESSING_TIMEOUT}s, so the alerts of suppressed findings were not updated. The next run updates them."
  jq -n '{pending: true}' > "$WORK/alerts.json"
  exit 0
fi

ALERTS="$WORK/alerts-list.jsonl"
: > "$ALERTS"

REF="${GITHUB_REF:?GITHUB_REF is not set}"

if [ "${DEFAULT_BRANCH:-false}" != true ]; then
  # Off the default branch: the dismissed alerts of the uploaded ref whose findings are reported
  # without a suppression. The default branch's locations predate the change, which usually moves
  # the finding by deleting the annotation line, so the alerts are listed on the uploaded ref.
  BRANCH="$(jq -r '.repository.default_branch // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
  [ -n "$BRANCH" ] || exit 0
  if ! list_alerts "$REF" dismissed >> "$ALERTS"; then
    echo "Could not list the code scanning alerts of $REF, so removed suppressions are not checked."
    exit 0
  fi
  TITLE="bal scan ($(trim "${CATEGORY:-bal-scan}"))"
  UNSUPPRESSED=0
  REINTRODUCED=0
  WARNINGS=0
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    # A unit separator keeps empty fields, which a tab, as whitespace, would merge.
    IFS=$'\x1f' read -r number file line rule url own reason \
      < <(jq -r '[.number, .file, .line, .rule, .url, .own, .reason] | map(. // "" | tostring) | join("\u001f")' <<< "$item")
    # Whether the default branch's latest analysis reports the finding. An alert has no instance
    # on a branch that never had it.
    if ! on_branch="$(gh_api -G "$API/$number/instances" --data-urlencode "ref=refs/heads/$BRANCH" \
      | jq -r 'any(.[]; .state == "open")')"; then
      echo "Could not read the instances of alert $number on $BRANCH, so it is not checked."
      continue
    fi
    if [ "$on_branch" = true ]; then
      # Dismissed by hand while the default branch reports it: a decision about this finding.
      [ "$own" = true ] || continue
      UNSUPPRESSED=$((UNSUPPRESSED + 1))
      message="This $rule finding is no longer suppressed, but its alert #$number stays dismissed on $BRANCH until this change is merged, when the action reopens it: $url"
    else
      REINTRODUCED=$((REINTRODUCED + 1))
      if [ "$own" = true ]; then
        message="This $rule finding is not on $BRANCH, but code scanning matches it to alert #$number, dismissed there while it was suppressed, so it is not shown as new. The action reopens the alert when this change is merged: $url"
      else
        message="This $rule finding is not on $BRANCH, but code scanning matches it to alert #$number, dismissed by hand as $reason, so it is not shown as new, and the alert stays dismissed after the merge. Reopen it if the dismissal no longer applies: $url"
      fi
    fi
    WARNINGS=$((WARNINGS + 1))
    # GitHub shows at most 10 warnings per step.
    [ "$WARNINGS" -le 10 ] || continue
    echo "::warning file=$(escape_property "$file"),line=$line,title=$(escape_property "$TITLE")::$(escape_data "$message")"
  done < <(alert_changes unsuppressed "$ALERTS")
  echo "Findings whose suppression was removed: $UNSUPPRESSED. Findings new to $BRANCH whose alerts are dismissed: $REINTRODUCED."
  jq -n --argjson u "$UNSUPPRESSED" --argjson r "$REINTRODUCED" --arg branch "$BRANCH" \
    '{unsuppressed: $u, reintroduced: $r, branch: $branch}' > "$WORK/alerts.json"
  exit 0
fi

# Counted as the job summary counts suppressed findings, without those of severity none.
SUPPRESSED="$(jq '[.[] | select(.suppressed and .severity != "none")] | length' "$WORK/results.json")"
STATES=(dismissed)
# Open alerts are only dismissed, so they are listed only when a finding is suppressed.
jq -e 'any(.[]; .suppressed)' "$WORK/results.json" > /dev/null && STATES=(open dismissed)
for state in "${STATES[@]}"; do
  if ! list_alerts "$REF" "$state" >> "$ALERTS"; then
    if [ "$SUPPRESSED" -gt 0 ]; then
      log_warning "Could not list the code scanning alerts, so the alerts of $SUPPRESSED suppressed finding(s) stay open and no alert was reopened. See the log of this step."
    else
      echo "Could not list the code scanning alerts, so no alert of a finding whose suppression was removed was reopened."
    fi
    jq -n --argjson n "$SUPPRESSED" '{dismissed: 0, recorded: 0, reopened: 0, fixed: 0, failed: 0, "left-open": $n}' > "$WORK/alerts.json"
    exit 0
  fi
done

# One line per alert: number, kind and the patches as JSON, which has no raw tab or newline.
CHANGES="$(alert_changes change "$ALERTS" | jq -r '"\(.number)\t\(.kind)\t\(.patches | tojson)"')"

declare -A DONE=([dismiss]=0 [record]=0 [reopen]=0 [fix]=0)
FAILED=0
while IFS=$'\t' read -r number kind patches; do
  [ -n "$number" ] || continue
  ok=true
  while IFS= read -r patch; do
    gh_api -X PATCH "$API/$number" -d "$patch" > /dev/null || { ok=false && break; }
  done < <(jq -c '.[]' <<< "$patches")
  if [ "$ok" = true ]; then DONE[$kind]=$((DONE[$kind] + 1)); else FAILED=$((FAILED + 1)); fi
done <<< "$CHANGES"

[ "$FAILED" -eq 0 ] \
  || log_warning "Could not change $FAILED code scanning alert(s) of suppressed findings. The token needs the security-events: write permission."
echo "Code scanning alerts of suppressed findings: dismissed ${DONE[dismiss]}, recorded ${DONE[record]}, reopened ${DONE[reopen]}, set to fixed ${DONE[fix]}."
jq -n --argjson d "${DONE[dismiss]}" --argjson c "${DONE[record]}" --argjson r "${DONE[reopen]}" \
  --argjson x "${DONE[fix]}" --argjson f "$FAILED" \
  '{dismissed: $d, recorded: $c, reopened: $r, fixed: $x, failed: $f, "left-open": 0}' > "$WORK/alerts.json"
