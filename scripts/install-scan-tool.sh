#!/usr/bin/env bash
# Step 5: checks the installed Ballerina and installs the scan tool.
#
# An empty tool-version resolves to the latest scan tool Ballerina Central picks for the installed
# Ballerina, which is then installed like a given tool-version.
#
# Inputs (environment): SCAN_WORK_DIR, TOOL_VERSION (the version resolve-versions.sh resolved, empty for the latest
# compatible version), TOOL_PICKED and TOOL_CHECKED (its outputs of those names), CATEGORY.
# Outputs: ballerina-version, tool-version.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

has_bal || die "The bal command was not found on the path after setting up Ballerina."

BAL_VERSION="$(bal_version)"
[ -n "$BAL_VERSION" ] || die "Could not read the Ballerina version from 'bal version'."
version_ge "$BAL_VERSION" "$MIN_BALLERINA_VERSION" \
  || die "bal scan $MIN_TOOL_VERSION and later need Ballerina $MIN_BALLERINA_VERSION or later, but Ballerina $BAL_VERSION is installed. Set ballerina-version to $MIN_BALLERINA_VERSION or later, or update the Ballerina setup step before this action."

WANTED="$(trim "${TOOL_VERSION:-}")"
ACTIVE="$(active_tool_version)"
HINT="Check that tool-version names a published version that supports Ballerina $BAL_VERSION: a scan tool runs on the Ballerina update it was built with and later ones. Leave tool-version empty to use the latest compatible version."
PICKED_HINT="Ballerina Central picked it as the latest version compatible with Ballerina $BAL_VERSION. Set tool-version to install a given version."
[ "${TOOL_PICKED:-false}" != true ] || HINT="$PICKED_HINT"
# resolve-versions.sh already asked Central which Ballerina a resolved scan tool needs.
CHECKED="${TOOL_CHECKED:-true}"
[ -n "$WANTED" ] || CHECKED=true
if [ -z "$WANTED" ]; then
  if pick_compatible_tool "$BAL_VERSION"; then
    WANTED="$PICKED_TOOL"
  elif [ -n "$ACTIVE" ] && tool_supported "$ACTIVE"; then
    log_warning "Could not ask Ballerina Central for the latest bal scan compatible with Ballerina $BAL_VERSION, so the active version $ACTIVE is used. Set tool-version to choose the version."
    WANTED="$ACTIVE"
  else
    die "Could not ask Ballerina Central for the latest bal scan compatible with Ballerina $BAL_VERSION. Set tool-version to install a given version."
  fi
  HINT="$PICKED_HINT"
fi

# For a Ballerina unknown until installed, such as 2201.13. Cached, and not asked again when Central
# failed in resolve-versions.sh: then 'bal tool pull' and the active version below catch a mismatch.
if [ "$CHECKED" = true ] && NEEDED="$(tool_min_ballerina "$WANTED")"; then
  version_ge "$BAL_VERSION" "$NEEDED" \
    || die "bal scan $WANTED needs Ballerina $NEEDED or later, but Ballerina $BAL_VERSION is installed. Set ballerina-version to $NEEDED or later, or set tool-version to an older scan tool that supports Ballerina $BAL_VERSION."
fi

if [ "$ACTIVE" != "$WANTED" ]; then
  echo "::group::Install bal scan $WANTED"
  # 'bal tool use' switches to a version that is already pulled. 'bal tool pull' fails for one
  # that is already active, so it runs only when the switch did not work. Neither exit code is
  # reliable on every runner, so the active version decides.
  bal_cmd tool use "scan:$WANTED" || true
  ACTIVE="$(active_tool_version)"
  if [ "$ACTIVE" != "$WANTED" ]; then
    bal_cmd tool pull "scan:$WANTED" || true
    ACTIVE="$(active_tool_version)"
  fi
  echo "::endgroup::"
  [ "$ACTIVE" = "$WANTED" ] || die "Could not install bal scan $WANTED for Ballerina $BAL_VERSION (active version: ${ACTIVE:-none}). $HINT"
fi

echo "Using bal scan $ACTIVE on Ballerina $BAL_VERSION"
set_output ballerina-version "$BAL_VERSION"
set_output tool-version "$ACTIVE"
