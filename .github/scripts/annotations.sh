#!/usr/bin/env bash
# Prints the annotations of a job in the current workflow run as a JSON array.
#
# Annotations reach the check run only after the job has finished, so run this from a job that
# needs it.
#
# Usage: annotations.sh <job name>
# Environment: GH_TOKEN, with actions: read and checks: read.

set -euo pipefail

JOB_NAME="$1"

# Prints the job with the name in attempt $1 as compact JSON, or nothing when there is none.
job_in_attempt() {
  gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$1/jobs" \
    | jq -c --arg name "$JOB_NAME" '.jobs[] | select(.name == $name)' | head -n1
}

JOB="$(job_in_attempt "$GITHUB_RUN_ATTEMPT")"
if [ -z "$JOB" ]; then
  echo "::error::Could not find the check run of the '$JOB_NAME' job." >&2
  exit 1
fi

# A re-run copies the jobs that passed into the new attempt without their annotations, keeping
# started_at, so the annotations are on the first attempt with the same start time.
STARTED_AT="$(jq -r '.started_at' <<< "$JOB")"
for ((attempt = 1; attempt < GITHUB_RUN_ATTEMPT; attempt++)); do
  EARLIER="$(job_in_attempt "$attempt")"
  if [ -n "$EARLIER" ] && [ "$(jq -r '.started_at' <<< "$EARLIER")" = "$STARTED_AT" ]; then
    JOB="$EARLIER"
    break
  fi
done

CHECK_RUN_URL="$(jq -r '.check_run_url' <<< "$JOB")"
gh api --paginate "${CHECK_RUN_URL#https://api.github.com/}/annotations" | jq -sc 'add // []'
