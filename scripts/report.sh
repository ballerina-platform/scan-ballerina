#!/usr/bin/env bash
# Steps 11 and 12: writes annotations and the job summary, then applies the gate. Runs even when an
# earlier step failed, so that the result output and the summary are always set.
#
# Inputs (environment): SCAN_WORK_DIR, CATEGORY, ANNOTATIONS, JOB_SUMMARY, FAIL_ON_SEVERITY,
# FAIL_ON_COUNT, FAILED_STEP (the first step that failed, empty when none did), UNIT_COUNT,
# PACKAGES_SCANNED, HIGH, MEDIUM, LOW, TOTAL, SUPPRESSED, SARIF_ID, ARTIFACT_NAME, ARTIFACT_ID,
# ARTIFACT_URL, GCS_SKIPPED, SONARQUBE_SKIPPED.
# Reads: $SCAN_WORK_DIR/sonarqube-failures.txt, written by scan.sh. A package whose SonarQube scan
# failed makes the result error and fails the step here, after the SARIF file was uploaded. Also
# reads $SCAN_WORK_DIR/alerts.json, written by dismiss-alerts.sh.
# Outputs: result, uploads, high-count, medium-count, low-count, total-count, packages-scanned,
# suppressed-count.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# GitHub shows at most this many annotations of each level (error, warning, notice) per step, and
# drops the rest without a notice.
ANNOTATION_LIMIT=10

WORK="${SCAN_WORK_DIR:-}"
CATEGORY="$(trim "${CATEGORY:-bal-scan}")"
FAIL_ON="$(tr '[:upper:]' '[:lower:]' <<< "$(trim "${FAIL_ON_SEVERITY:-none}")")"
# As bal scan --fail-on-count: the gate fails when this many findings, or more, are at or above
# fail-on-severity.
COUNT_LIMIT="$(trim "${FAIL_ON_COUNT:-1}")"
[[ "$COUNT_LIMIT" =~ ^[1-9][0-9]*$ ]] || COUNT_LIMIT=1
# The merge step sets the counts whenever it succeeds, so missing counts mean it never finished,
# such as when the run was cancelled or timed out, which FAILED_STEP does not catch.
COUNTED=false
[ -n "${HIGH:-}" ] && [ -n "${MEDIUM:-}" ] && [ -n "${LOW:-}" ] && COUNTED=true
COUNT_OUTPUTS=("${HIGH:-}" "${MEDIUM:-}" "${LOW:-}" "${TOTAL:-}" "${PACKAGES_SCANNED:-}" "${SUPPRESSED:-}")
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

GCS_SKIP_REASON="code scanning rejects a token that cannot write security events outside pull_request runs. See the upload step log for the error."
if [ "${GCS_SKIPPED:-false}" = "true" ]; then
  log_warning "The upload to GitHub code scanning failed and was skipped: $GCS_SKIP_REASON The SARIF file is kept as the sarif-file output; save it with artifacts: true and upload it from a trusted workflow_run workflow."
fi

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
  if [ "$FAIL_ON" != "none" ] && [ "$SELECTED" -ge "$COUNT_LIMIT" ]; then
    RESULT=failed
    if [ "$COUNT_LIMIT" -eq 1 ]; then
      REASONS+=("Found $SELECTED finding(s) at or above $FAIL_ON severity; none are allowed.")
    else
      REASONS+=("Found $SELECTED finding(s) at or above $FAIL_ON severity; the gate fails at $COUNT_LIMIT.")
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
  COUNT_OUTPUTS=(0 0 0 0 0 0)
fi
set_output high-count "${COUNT_OUTPUTS[0]}"
set_output medium-count "${COUNT_OUTPUTS[1]}"
set_output low-count "${COUNT_OUTPUTS[2]}"
set_output total-count "${COUNT_OUTPUTS[3]}"
set_output packages-scanned "${COUNT_OUTPUTS[4]}"
set_output suppressed-count "${COUNT_OUTPUTS[5]}"

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
  # jq writes the workflow commands itself, so that empty fields and messages with tabs or newlines
  # need no splitting in bash.
  jq -r -L "$SCRIPT_DIR" --argjson slots "{\"high\": $HIGH_SLOTS, \"medium\": $MEDIUM_SLOTS, \"low\": $LOW_SLOTS}" '
      include "common";
      . as $all
      | ("high", "medium", "low") as $s
      | [$all[] | select(.severity == $s)][:$slots[$s]][]
      | (.file // "") as $file
      | ((if $file == "" then ""
          else "file=\($file | escape_property),line=\(.line),endLine=\(."end-line" // .line),"
          end) + "title=\(.rule // "" | escape_property)") as $props
      | "::\({"high": "error", "medium": "warning", "low": "notice"}[.severity]) \($props)::\(.message // "" | escape_data)"
    ' "$WORK/findings.json"
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
      [ "$FAIL_ON" != "none" ] && GATE="fail on $COUNT_LIMIT or more finding(s) at or above $FAIL_ON severity"
      echo "Packages scanned: ${PACKAGES_SCANNED:-0}."
      echo
      if [ "${SUPPRESSED:-0}" -gt 0 ]; then
        echo "Suppressed findings, left out of the counts and the gate: $SUPPRESSED."
        echo
      fi
      echo "Gate: $GATE."
      if [ -n "$ANNOTATION_NOTE" ]; then
        echo
        echo "$ANNOTATION_NOTE"
      fi
    fi
    if [ "$(jq 'length' <<< "$UPLOADS")" -gt 0 ]; then
      echo
      ALERTS='{}'
      [ -z "$WORK" ] || [ ! -s "$WORK/alerts.json" ] || ALERTS="$(jq -c . "$WORK/alerts.json")"
      jq -r --argjson alerts "$ALERTS" '
        (if has("github-code-scanning") then "- Uploaded to GitHub code scanning."
          + (if ($alerts.dismissed // 0) + ($alerts.reopened // 0) > 0
             then " Dismissed \($alerts.dismissed) alert(s) of suppressed findings, and reopened \($alerts.reopened) whose suppression was removed."
             else "" end)
          + (if ($alerts."left-open" // 0) > 0
             then " **Could not list the code scanning alerts, so the alerts of \($alerts."left-open") suppressed finding(s) stay open.** The token needs the `security-events: write` permission."
             else "" end)
          + (if ($alerts.failed // 0) > 0
             then " **Could not change \($alerts.failed) code scanning alert(s) of suppressed findings.** The token needs the `security-events: write` permission."
             else "" end) else empty end),
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
      echo "- The upload to GitHub code scanning failed and was skipped: $GCS_SKIP_REASON The SARIF file is kept as the \`sarif-file\` output, and \`artifacts: true\` saves it as an artifact."
    fi
    if [ "${SONARQUBE_SKIPPED:-false}" = "true" ]; then
      echo "- SonarQube was skipped: pull requests from forks get no secrets and Dependabot runs get only Dependabot secrets."
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
