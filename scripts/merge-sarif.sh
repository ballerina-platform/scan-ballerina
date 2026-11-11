#!/usr/bin/env bash
# Step 7: normalizes the package reports, merges them into one SARIF file and counts the findings.
#
# Inputs (environment): SCAN_WORK_DIR, EXCLUDE_PATHS, SUPPRESSIONS, GITHUB_CODE_SCANNING (true
# when the findings are uploaded to code scanning), DISMISS_ALERTS (true when dismiss-alerts.sh
# dismisses alerts after the upload), CATEGORY.
# Writes: the merged SARIF file, $SCAN_WORK_DIR/results.json, every result, and
# $SCAN_WORK_DIR/findings.json, the counted findings: those that are not suppressed.
# Outputs: sarif-file, upload-file (the SARIF file to upload to code scanning), high-count,
# medium-count, low-count, total-count, suppressed-count.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
EXCLUDES="$(split_list "${EXCLUDE_PATHS:-}" | jq -R . | jq -sc .)"
APPLY="$(bool_setting "${SUPPRESSIONS:-}")"

mkdir -p "$WORK/normalized"
INDEX=0
while IFS= read -r unit; do
  report="$WORK/reports/$INDEX.sarif"
  [ -f "$report" ] || die "The report of '$(jq -r '.path' <<< "$unit")' is missing from the work directory."
  jq -L "$SCRIPT_DIR" -f "$SCRIPT_DIR/normalize-sarif.jq" \
    --arg prefix "$(jq -r '.path' <<< "$unit")" \
    --argjson excludes "$EXCLUDES" \
    "$report" > "$WORK/normalized/$INDEX.sarif"
  INDEX=$((INDEX + 1))
done < <(jq -c '.[]' "$WORK/units.json")

SARIF="$WORK/$(safe_category).sarif"
FILES=()
for ((i = 0; i < INDEX; i++)); do FILES+=("$WORK/normalized/$i.sarif"); done
# The merged run keeps plain paths, which the findings and annotations use. The SARIF file gets
# them percent-encoded, as SARIF URIs.
MERGED="$WORK/merged.sarif"
jq -s -f "$SCRIPT_DIR/merge-sarif.jq" "${FILES[@]}" > "$MERGED"
jq -L "$SCRIPT_DIR" '
  include "common";
  .runs |= map(
    (if .artifacts then .artifacts |= map(if (.location.uri | type) == "string" then .location.uri |= uri_path else . end) else . end)
    | .results |= map(
      (if .locations then .locations |= map(map_uri(uri_path)) else . end)
      | (if .relatedLocations then .relatedLocations |= map(map_uri(uri_path)) else . end)))
' "$MERGED" > "$SARIF"

# Every result, with whether it is suppressed, for the counts here and for dismiss-alerts.sh.
# suppressions: false makes bal scan report no suppression, so then no result is.
jq -L "$SCRIPT_DIR" --argjson apply "$APPLY" '
  include "common";
  .runs[0].tool.driver.rules as $rules
  | [.runs[0].results[] | {
      severity: severity($rules),
      rule: .ruleId,
      message: (.message.text // ""),
      file: (.locations[0].physicalLocation.artifactLocation.uri // ""),
      line: (.locations[0].physicalLocation.region.startLine // 1),
      "end-line": (.locations[0].physicalLocation.region.endLine // null),
      column: (.locations[0].physicalLocation.region.startColumn // null),
      "end-column": (.locations[0].physicalLocation.region.endColumn // null),
      suppressed: ($apply and suppressed),
      justification: justification
    }]
' "$MERGED" > "$WORK/results.json"
jq '[.[] | select(.severity != "none" and (.suppressed | not)) | del(.suppressed, .justification)]' \
  "$WORK/results.json" > "$WORK/findings.json"

count() { jq --arg s "$1" '[.[] | select(.severity == $s)] | length' "$WORK/findings.json"; }
HIGH="$(count high)"
MEDIUM="$(count medium)"
LOW="$(count low)"
TOTAL=$((HIGH + MEDIUM + LOW))
SUPPRESSED="$(jq '[.[] | select(.suppressed and .severity != "none")] | length' "$WORK/results.json")"

# Code scanning ignores SARIF suppressions. On the default branch dismiss-alerts.sh dismisses the
# alerts of suppressed results after the upload; elsewhere they are left out of the upload.
UPLOAD="$SARIF"
if [ "${GITHUB_CODE_SCANNING:-false}" = true ] && [ "${DISMISS_ALERTS:-false}" != true ] \
  && jq -e 'any(.[]; .suppressed)' "$WORK/results.json" > /dev/null; then
  mkdir -p "$WORK/upload"
  UPLOAD="$WORK/upload/$(safe_category).sarif"
  jq -L "$SCRIPT_DIR" 'include "common"; .runs |= map(.results |= map(select(suppressed | not)))' "$SARIF" > "$UPLOAD"
fi

# Paths in outputs use the runner's native form, so later steps on Windows can read them.
SARIF_OUT="$SARIF"
UPLOAD_OUT="$UPLOAD"
if command -v cygpath > /dev/null 2>&1; then
  SARIF_OUT="$(cygpath -w "$SARIF")"
  UPLOAD_OUT="$(cygpath -w "$UPLOAD")"
fi

echo "bal scan '${CATEGORY:-bal-scan}': $HIGH high, $MEDIUM medium, $LOW low severity finding(s), $SUPPRESSED suppressed"
echo "SARIF file: $SARIF_OUT"
set_output sarif-file "$SARIF_OUT"
set_output upload-file "$UPLOAD_OUT"
set_output high-count "$HIGH"
set_output medium-count "$MEDIUM"
set_output low-count "$LOW"
set_output total-count "$TOTAL"
set_output suppressed-count "$SUPPRESSED"
