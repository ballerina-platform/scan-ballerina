#!/usr/bin/env bash
# Step 9: on the default branch, after the upload to code scanning, dismisses the alerts of
# suppressed findings, since code scanning ignores SARIF suppressions. An alert is dismissed as
# "won't fix" with the suppression's justification, so the accepted finding can still be audited. An
# alert this step dismissed is reopened once its finding is reported again without a suppression.
# Alerts are matched to findings by rule, file, line and column. A failed API call is a warning,
# so that it does not fail the scan.
#
# Inputs (environment): SCAN_WORK_DIR, GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_REF, GITHUB_API_URL,
# CATEGORY.
# Reads: $SCAN_WORK_DIR/results.json and $SCAN_WORK_DIR/merged.sarif, written by merge-sarif.sh.
# Writes: $SCAN_WORK_DIR/alerts.json, the number of alerts dismissed and reopened.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
API="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}/code-scanning/alerts"
REF="${GITHUB_REF:?GITHUB_REF is not set}"
TOOL="$(jq -r '.runs[0].tool.driver.name // "Ballerina Scan Tool"' "$WORK/merged.sarif")"
# Marks the alerts this step dismissed, so that it reopens no alert dismissed by hand.
MARKER="Suppressed in source with @scan:Suppress"
# The longest dismissed_comment code scanning accepts.
COMMENT_LIMIT=280

echo '{"dismissed": 0, "reopened": 0}' > "$WORK/alerts.json"

gh_api() {
  curl "${CURL_OPTS[@]}" --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN:?GITHUB_TOKEN is not set}" \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

ALERTS="$WORK/alerts-list.jsonl"
: > "$ALERTS"
for state in open dismissed; do
  page=1
  while :; do
    if ! body="$(gh_api -G "$API" --data-urlencode "ref=$REF" --data-urlencode "tool_name=$TOOL" \
      -d "state=$state" -d per_page=100 -d "page=$page")"; then
      log_warning "Could not list the code scanning alerts, so the alerts of suppressed findings were not dismissed or reopened. The token needs the security-events: write permission."
      exit 0
    fi
    [ "$(jq 'length' <<< "$body")" -gt 0 ] || break
    jq -c '.[]' <<< "$body" >> "$ALERTS"
    page=$((page + 1))
  done
done

CHANGES="$(jq -sc -f "$SCRIPT_DIR/alert-changes.jq" --slurpfile results "$WORK/results.json" \
  --arg category "$(trim "${CATEGORY:-bal-scan}")" --arg marker "$MARKER" --arg reason "won't fix" \
  --argjson limit "$COMMENT_LIMIT" "$ALERTS")"

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
jq -n --argjson d "$DISMISSED" --argjson r "$REOPENED" '{dismissed: $d, reopened: $r}' > "$WORK/alerts.json"
