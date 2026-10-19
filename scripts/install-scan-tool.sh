#!/usr/bin/env bash
# Steps 4 and 5: checks the Ballerina version and installs the scan tool.
#
# The tool is pulled only when it is missing or a different version is active, so the action can
# run more than once in a job.
#
# Inputs (environment): TOOL_VERSION (empty uses the version this release pins), CATEGORY.
# Outputs: ballerina-version, tool-version.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

has_bal || die "The bal command was not found on the path after setting up Ballerina."

BAL_VERSION="$(bal_version)"
[ -n "$BAL_VERSION" ] || die "Could not read the Ballerina version from 'bal version'."

WANTED="$(trim "${TOOL_VERSION:-}")"
if [ -z "$WANTED" ]; then
  WANTED="$PINNED_TOOL_VERSION"
  if ! version_ge "$BAL_VERSION" "$MIN_BALLERINA_VERSION"; then
    die "bal scan $WANTED needs Ballerina $MIN_BALLERINA_VERSION or later, but Ballerina $BAL_VERSION is installed. Set ballerina-version to $MIN_BALLERINA_VERSION or later, or update the Ballerina setup step before this action."
  fi
fi

active_version() {
  bal_cmd tool list 2> /dev/null | tr -d '\r' \
    | awk -F'|' '$2 ~ /^[[:space:]]*scan[[:space:]]*$/ { if (match($3, /[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*/)) print substr($3, RSTART, RLENGTH) }' \
    | head -n1
}

ACTIVE="$(active_version)"
if [ "$ACTIVE" != "$WANTED" ]; then
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
  [ "$ACTIVE" = "$WANTED" ] || die "Could not install bal scan $WANTED from Ballerina Central (active version: ${ACTIVE:-none}). Check that tool-version names a published version compatible with Ballerina $BAL_VERSION."
fi

echo "Using bal scan $ACTIVE on Ballerina $BAL_VERSION"
set_output ballerina-version "$BAL_VERSION"
set_output tool-version "$ACTIVE"
