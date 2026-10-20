#!/usr/bin/env bash
# Steps 4 and 5: checks the Ballerina version and installs the scan tool.
#
# An empty tool-version resolves to the latest scan tool Ballerina Central picks for the installed
# Ballerina, which is then installed like a given tool-version.
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

# Prints the latest scan tool version compatible with Ballerina $1, cached once per job.
latest_compatible_version() {
  local cache version
  cache="$(tool_cache_dir)/scan-tool-for-ballerina-$1"
  if [ -s "$cache" ]; then
    cat "$cache"
    return
  fi
  version="$(curl -fsSL --proto '=https' --retry 3 -H "User-Agent: $1" -H "Ballerina-Platform: $CENTRAL_PLATFORM" \
    "$CENTRAL_TOOLS_URL/scan" | jq -r '.version // empty')" || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  printf '%s' "$version" > "$cache"
  printf '%s' "$version"
}

WANTED="$(trim "${TOOL_VERSION:-}")"
ACTIVE="$(active_version)"
HINT="Check that tool-version names a published version that supports Ballerina $BAL_VERSION: a scan tool runs on the Ballerina update it was built with and later ones. Leave tool-version out to use the latest compatible version."
if [ -z "$WANTED" ]; then
  if WANTED="$(latest_compatible_version "$BAL_VERSION")"; then
    echo "The latest bal scan compatible with Ballerina $BAL_VERSION is $WANTED."
  elif [ -n "$ACTIVE" ] && version_ge "$ACTIVE" "$MIN_TOOL_VERSION"; then
    log_warning "Could not ask Ballerina Central for the latest bal scan compatible with Ballerina $BAL_VERSION, so the active version $ACTIVE is used. Set tool-version to choose the version."
    WANTED="$ACTIVE"
  else
    die "Could not ask Ballerina Central for the latest bal scan compatible with Ballerina $BAL_VERSION. Set tool-version to install a given version."
  fi
  version_ge "$WANTED" "$MIN_TOOL_VERSION" \
    || die "The latest bal scan compatible with Ballerina $BAL_VERSION is $WANTED, but the oldest supported version is $MIN_TOOL_VERSION. Set tool-version to $MIN_TOOL_VERSION or a later version that supports Ballerina $BAL_VERSION."
  HINT="Ballerina Central picked it as the latest version compatible with Ballerina $BAL_VERSION. Set tool-version to install a given version."
fi

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
  [ "$ACTIVE" = "$WANTED" ] || die "Could not install bal scan $WANTED for Ballerina $BAL_VERSION (active version: ${ACTIVE:-none}). $HINT"
fi

echo "Using bal scan $ACTIVE on Ballerina $BAL_VERSION"
set_output ballerina-version "$BAL_VERSION"
set_output tool-version "$ACTIVE"
