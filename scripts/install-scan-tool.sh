#!/usr/bin/env bash
# Steps 4 and 5: checks the Ballerina version and installs the scan tool.
#
# An empty tool-version installs the latest scan tool compatible with the installed Ballerina,
# which Ballerina Central picks. A given tool-version is pulled only when it is missing or a
# different version is active, so the action can run more than once in a job.
#
# Inputs (environment): TOOL_VERSION (empty uses the latest compatible version), CATEGORY.
# Outputs: ballerina-version, tool-version.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

has_bal || die "The bal command was not found on the path after setting up Ballerina."

BAL_VERSION="$(bal_version)"
[ -n "$BAL_VERSION" ] || die "Could not read the Ballerina version from 'bal version'."
version_ge "$BAL_VERSION" "$MIN_BALLERINA_VERSION" \
  || die "bal scan $MIN_TOOL_VERSION and later need Ballerina $MIN_BALLERINA_VERSION or later, but Ballerina $BAL_VERSION is installed. Set ballerina-version to $MIN_BALLERINA_VERSION or later, or update the Ballerina setup step before this action."

active_version() {
  bal_cmd tool list 2> /dev/null | tr -d '\r' \
    | awk -F'|' '$2 ~ /^[[:space:]]*scan[[:space:]]*$/ { if (match($3, /[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*/)) print substr($3, RSTART, RLENGTH) }' \
    | head -n1
}

WANTED="$(trim "${TOOL_VERSION:-}")"
ACTIVE="$(active_version)"
if [ -z "$WANTED" ]; then
  echo "::group::Install the latest bal scan compatible with Ballerina $BAL_VERSION"
  OUTPUT="$(bal_cmd tool pull scan 2>&1)" || true
  printf '%s\n' "$OUTPUT"
  # A higher version that is already active, such as one an earlier run in the job installed for a
  # newer Ballerina, stays active after the pull, so the version Central picked is made active.
  PULLED="$(tr -d '\r' <<< "$OUTPUT" | sed -n "s/.*tool 'scan:\([0-9][^']*\)'.*/\1/p" | head -n1)"
  if [ -n "$PULLED" ] && [ "$PULLED" != "$(active_version)" ]; then
    bal_cmd tool use "scan:$PULLED" || true
  fi
  echo "::endgroup::"
  ACTIVE="$(active_version)"
  [ -n "$ACTIVE" ] || die "Could not install bal scan from Ballerina Central for Ballerina $BAL_VERSION."
  version_ge "$ACTIVE" "$MIN_TOOL_VERSION" \
    || die "The latest bal scan compatible with Ballerina $BAL_VERSION is $ACTIVE, but the oldest supported version is $MIN_TOOL_VERSION. Set ballerina-version to $MIN_BALLERINA_VERSION or later."
elif [ "$ACTIVE" != "$WANTED" ]; then
  echo "::group::Install bal scan $WANTED"
  # 'bal tool use' switches to a version that is already pulled. 'bal tool pull' fails for one
  # that is already active, so it runs only when the switch did not work. Neither exit code is
  # reliable on every runner, so the active version decides.
  bal_cmd tool use "scan:$WANTED" || true
  ACTIVE="$(active_version)"
  if [ "$ACTIVE" != "$WANTED" ]; then
    bal_cmd tool pull "scan:$WANTED" || true
    ACTIVE="$(active_version)"
  fi
  echo "::endgroup::"
  [ "$ACTIVE" = "$WANTED" ] || die "Could not install bal scan $WANTED for Ballerina $BAL_VERSION (active version: ${ACTIVE:-none}). Check that tool-version names a published version that supports Ballerina $BAL_VERSION: a scan tool runs on the Ballerina update it was built with and later ones. Leave tool-version out to use the latest compatible version."
fi

echo "Using bal scan $ACTIVE on Ballerina $BAL_VERSION"
set_output ballerina-version "$BAL_VERSION"
set_output tool-version "$ACTIVE"
