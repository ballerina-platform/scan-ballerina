#!/usr/bin/env bash
# Steps 11 and 12: writes annotations and the job summary, then applies the gate. Runs even when an
# earlier step failed, so that the result output and the summary are always set.
#
# Inputs (environment): SCAN_WORK_DIR, CATEGORY, ANNOTATIONS, JOB_SUMMARY, FAIL_ON_SEVERITY,
# MAX_FINDINGS, FAILED_STEP (the first step that failed, empty when none did), UNIT_COUNT,
# PACKAGES_SCANNED, HIGH, MEDIUM, LOW, TOTAL, SARIF_ID, ARTIFACT_NAME, ARTIFACT_ID, ARTIFACT_URL,
# GCS_SKIPPED, SONARQUBE_SKIPPED.
# Reads: $SCAN_WORK_DIR/sonarqube-failures.txt, written by scan.sh. A package whose SonarQube scan
# failed makes the result error and fails the step here, after the SARIF file was uploaded.
# Outputs: result, uploads, high-count, medium-count, low-count, total-count, packages-scanned.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# GitHub shows at most this many annotations of each level (error, warning, notice) per step, and
# drops the rest without a notice.
ANNOTATION_LIMIT=10

WORK="${SCAN_WORK_DIR:-}"
CATEGORY="$(trim "${CATEGORY:-bal-scan}")"
FAIL_ON="$(tr '[:upper:]' '[:lower:]' <<< "$(trim "${FAIL_ON_SEVERITY:-none}")")"
MAX="$(trim "${MAX_FINDINGS:-0}")"
[[ "$MAX" =~ ^[0-9]+$ ]] || MAX=0
# The merge step sets the counts whenever it succeeds, so missing counts mean it never finished,
# such as when the run was cancelled or timed out, which FAILED_STEP does not catch.
COUNTED=false
[ -n "${HIGH:-}" ] && [ -n "${MEDIUM:-}" ] && [ -n "${LOW:-}" ] && COUNTED=true
COUNT_OUTPUTS=("${HIGH:-}" "${MEDIUM:-}" "${LOW:-}" "${TOTAL:-}" "${PACKAGES_SCANNED:-}")
HIGH="${HIGH:-0}" MEDIUM="${MEDIUM:-0}" LOW="${LOW:-0}"

# Uploads: one entry per platform the findings were sent to.
UPLOADS='{}'
if [ -n "${SARIF_ID:-}" ]; then
  UPLOADS="$(jq -c --arg id "$SARIF_ID" '. + {"github-code-scanning": {"sarif-id": $id}}' <<< "$UPLOADS")"
fi
if [ -n "$WORK" ] && [ -f "$WORK/sonarqube-uploads.jsonl" ]; then
  SONAR_UPLOADS="$(jq -sc '.' "$WORK/sonarqube-uploads.jsonl")"
  if [ "$(jq 'length' <<< "$SONAR_UPLOADS")" -gt 0 ]; then
    UPLOADS="$(jq -c --argjson s "$SONAR_UPLOADS" '. + {sonarqube: $s}' <<< "$UPLOADS")"
  fi
fi
if [ -n "${ARTIFACT_ID:-}" ]; then
  UPLOADS="$(jq -c --arg name "${ARTIFACT_NAME:-}" --arg id "$ARTIFACT_ID" --arg url "${ARTIFACT_URL:-}" \
    '. + {artifact: {name: $name, id: $id, url: $url}}' <<< "$UPLOADS")"
fi
set_output uploads "$UPLOADS"

# Packages whose SonarQube scan failed. The SARIF file was still produced and sent to the other
# platforms, so the step fails here, at the end.
SONAR_FAILURES=()
if [ -n "$WORK" ] && [ -s "$WORK/sonarqube-failures.txt" ]; then
  while IFS= read -r line; do [ -n "$line" ] && SONAR_FAILURES+=("$line"); done < "$WORK/sonarqube-failures.txt"
  SONAR_FAILURES=("Reporting to SonarQube failed for ${#SONAR_FAILURES[@]} package(s). The SARIF file was still produced." \
    "${SONAR_FAILURES[@]}")
fi

REASONS=()
if [ -n "${FAILED_STEP:-}" ]; then
  RESULT=error
  REASONS+=("The step failed while it was trying to ${FAILED_STEP}. See the step log for the errors." \
    "${SONAR_FAILURES[@]+"${SONAR_FAILURES[@]}"}")
elif [ "${UNIT_COUNT:-0}" = "0" ]; then
  RESULT=skipped
  REASONS+=("No Ballerina package was found.")
elif [ "$COUNTED" != "true" ]; then
  RESULT=error
  REASONS+=("The findings were not counted, so the scan did not finish. The run may have been cancelled or timed out.")
else
  case "$FAIL_ON" in
    high) SELECTED=$HIGH ;;
    medium) SELECTED=$((HIGH + MEDIUM)) ;;
    low) SELECTED=$((HIGH + MEDIUM + LOW)) ;;
    *) SELECTED=0 ;;
  esac
  RESULT=passed
  if [ "$FAIL_ON" != "none" ] && [ "$SELECTED" -gt "$MAX" ]; then
    RESULT=failed
    if [ "$MAX" -eq 0 ]; then
      REASONS+=("Found $SELECTED finding(s) at or above $FAIL_ON severity; none are allowed.")
    else
      REASONS+=("Found $SELECTED finding(s) at or above $FAIL_ON severity; at most $MAX are allowed.")
    fi
  fi
  if [ "${#SONAR_FAILURES[@]}" -gt 0 ]; then
    RESULT=error
    REASONS=("${SONAR_FAILURES[@]}" "${REASONS[@]+"${REASONS[@]}"}")
  fi
fi
set_output result "$RESULT"

# Nothing was found to scan, so every count is 0. Otherwise the counts are passed on as the earlier
# steps set them, which is empty when they did not finish.
if [ "$RESULT" = skipped ]; then
  COUNT_OUTPUTS=(0 0 0 0 0)
fi
set_output high-count "${COUNT_OUTPUTS[0]}"
set_output medium-count "${COUNT_OUTPUTS[1]}"
set_output low-count "${COUNT_OUTPUTS[2]}"
set_output total-count "${COUNT_OUTPUTS[3]}"
set_output packages-scanned "${COUNT_OUTPUTS[4]}"

# Annotations on each counted finding, up to GitHub's limit for each level. The gate's errors and
# the warning about the limit are annotations too, so they take their slots first.
ANNOTATION_NOTE=""
if [ "$(trim "${ANNOTATIONS:-false}")" = "true" ] && [ -n "$WORK" ] && [ -f "$WORK/findings.json" ] && [ -z "${FAILED_STEP:-}" ]; then
  HIGH_SLOTS=$ANNOTATION_LIMIT
  MEDIUM_SLOTS=$ANNOTATION_LIMIT
  LOW_SLOTS=$ANNOTATION_LIMIT
  { [ "$RESULT" = failed ] || [ "$RESULT" = error ]; } && HIGH_SLOTS=$((HIGH_SLOTS - ${#REASONS[@]}))
  [ "$HIGH_SLOTS" -ge 0 ] || HIGH_SLOTS=0
  if [ "$HIGH" -gt "$HIGH_SLOTS" ] || [ "$MEDIUM" -gt "$MEDIUM_SLOTS" ] || [ "$LOW" -gt "$LOW_SLOTS" ]; then
    MEDIUM_SLOTS=$((MEDIUM_SLOTS - 1))
    min() { echo $(($1 < $2 ? $1 : $2)); }
    SHOWN=$(($(min "$HIGH" "$HIGH_SLOTS") + $(min "$MEDIUM" "$MEDIUM_SLOTS") + $(min "$LOW" "$LOW_SLOTS")))
    ANNOTATION_NOTE="Annotated $SHOWN of the $((HIGH + MEDIUM + LOW)) findings, since GitHub shows at most $ANNOTATION_LIMIT annotations of each level per step and 50 per job. The SARIF file and the platforms it was sent to have every finding."
    log_warning "$ANNOTATION_NOTE"
  fi
  jq -r --argjson slots "{\"high\": $HIGH_SLOTS, \"medium\": $MEDIUM_SLOTS, \"low\": $LOW_SLOTS}" '
      . as $all
      | ("high", "medium", "low") as $s
      | [$all[] | select(.severity == $s)][:$slots[$s]][]
      | [
          ({"high": "error", "medium": "warning", "low": "notice"}[.severity]),
          .file, (.line | tostring), ((."end-line" // .line) | tostring), .rule, .message
        ]
      # Empty fields are written as "-", since read joins consecutive tabs.
      | map(if . == "" then "-" else . end)
      | @tsv' "$WORK/findings.json" \
    | while IFS=$'\t' read -r level file line end_line rule message; do
        [ "$file" != - ] || file=""
        [ "$rule" != - ] || rule=""
        [ "$message" != - ] || message=""
        props="title=$(escape_property "$rule")"
        [ -z "$file" ] || props="file=$(escape_property "$file"),line=$line,endLine=$end_line,$props"
        echo "::$level $props::$(escape_data "$message")"
      done
fi

if [ "$(trim "${JOB_SUMMARY:-true}")" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  case "$RESULT" in
    passed) ICON="✅" ;;
    failed) ICON="❌" ;;
    error) ICON="⚠️" ;;
    *) ICON="⏭️" ;;
  esac
  {
    echo "### $ICON bal scan: $CATEGORY"
    echo
    echo "**Result:** $RESULT"
    for r in "${REASONS[@]+"${REASONS[@]}"}"; do echo "- $r"; done
    if [ "$RESULT" = "passed" ] || [ "$RESULT" = "failed" ] || [ "${#SONAR_FAILURES[@]}" -gt 0 ]; then
      echo
      echo "| Severity | Findings |"
      echo "| --- | ---: |"
      echo "| High | $HIGH |"
      echo "| Medium | $MEDIUM |"
      echo "| Low | $LOW |"
      echo
      GATE="off"
      [ "$FAIL_ON" != "none" ] && GATE="fail on more than $MAX finding(s) at or above $FAIL_ON severity"
      echo "Packages scanned: ${PACKAGES_SCANNED:-0}."
      echo
      echo "Gate: $GATE."
      if [ -n "$ANNOTATION_NOTE" ]; then
        echo
        echo "$ANNOTATION_NOTE"
      fi
    fi
    if [ "$(jq 'length' <<< "$UPLOADS")" -gt 0 ]; then
      echo
      jq -r '
        (if has("github-code-scanning") then "- Uploaded to GitHub code scanning." else empty end),
        (.sonarqube[]? | "- Reported \(.package) to SonarQube project `\(."project-key")`"
          + (if ."dashboard-url" != "" then ": [dashboard](\(."dashboard-url"))" else "" end) + "."),
        (.artifact // empty | "- Saved the SARIF file as the artifact "
          + (if .url != "" then "[`\(.name)`](\(.url))" else "`\(.name)`" end) + ".")
      ' <<< "$UPLOADS"
    fi
    if [ "${GCS_SKIPPED:-false}" = "true" ] || [ "${SONARQUBE_SKIPPED:-false}" = "true" ]; then
      echo
    fi
    if [ "${GCS_SKIPPED:-false}" = "true" ]; then
      echo "- The upload to GitHub code scanning was skipped: pull requests from forks and Dependabot runs get a read-only \`GITHUB_TOKEN\`. The SARIF file is kept as the \`sarif-file\` output, and \`artifacts: true\` saves it as an artifact."
    fi
    if [ "${SONARQUBE_SKIPPED:-false}" = "true" ]; then
      echo "- SonarQube was skipped: secrets are not available to pull requests from forks or to Dependabot runs."
    fi
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi

case "$RESULT" in
  failed)
    for r in "${REASONS[@]}"; do log_error "$r"; done
    exit 1
    ;;
  error)
    # Other errors failed an earlier step, which reported them.
    if [ "${#SONAR_FAILURES[@]}" -gt 0 ]; then
      if [ -n "${FAILED_STEP:-}" ]; then
        for r in "${SONAR_FAILURES[@]}"; do log_error "$r"; done
      else
        for r in "${REASONS[@]}"; do log_error "$r"; done
      fi
      exit 1
    fi
    ;;
  passed) echo "bal scan '$CATEGORY' passed." ;;
  skipped) echo "bal scan '$CATEGORY' was skipped: no Ballerina package was found." ;;
esac
