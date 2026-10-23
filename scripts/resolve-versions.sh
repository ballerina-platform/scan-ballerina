#!/usr/bin/env bash
# Step 4: resolves the Ballerina to install and the scan tool version, before either is installed.
#
# A version, or latest, is used as given. latest is the newest release, whatever the other version
# is, and a Ballerina older than the scan tool needs fails. An empty version is resolved to one that
# works with the other:
# - An empty tool-version is the latest scan tool compatible with the installed Ballerina, which
#   install-scan-tool.sh asks Ballerina Central for.
# - An empty ballerina-version is the bal on the path when it can run the scan tool, and otherwise
#   the latest Ballerina.
#
# Inputs (environment): BALLERINA_VERSION, TOOL_VERSION, CATEGORY.
# Outputs: install (true when Ballerina must be installed), ballerina-version (the version to
# install, or the one on the path), tool-version (the scan tool to install, or empty for the latest
# one compatible with the installed Ballerina).

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WANTED_BAL="$(trim "${BALLERINA_VERSION:-}")"
WANTED_TOOL="$(trim "${TOOL_VERSION:-}")"

# 1. The scan tool.
TOOL="$WANTED_TOOL"
if [ "$TOOL" = latest ]; then
  TOOL="$(latest_tool_version)" \
    || die "Could not ask Ballerina Central for the latest bal scan. Set tool-version to a version, or leave it empty to use the latest version compatible with the Ballerina version."
  echo "The latest bal scan is $TOOL."
fi
NEEDED="$(tool_min_ballerina "$TOOL")"
TOOL_NAME="the scan tool"
[ -z "$TOOL" ] || TOOL_NAME="bal scan $TOOL"
[ "$WANTED_TOOL" != latest ] || TOOL_NAME="the latest bal scan, $TOOL,"

# 2. Ballerina. An empty ballerina-version keeps a bal on the path that can run the scan tool.
CURRENT=""
has_bal && CURRENT="$(bal_version)"
BAL="$WANTED_BAL"
if [ -z "$BAL" ]; then
  if [ -n "$CURRENT" ] && version_ge "$CURRENT" "$NEEDED"; then
    BAL="$CURRENT"
  else
    BAL=latest
  fi
fi
if [ "$BAL" = latest ]; then
  if BAL="$(latest_ballerina_version)"; then
    echo "The latest Ballerina is $BAL."
  else
    # setup-ballerina looks it up again, and install-scan-tool.sh checks the installed pair.
    log_warning "Could not ask Ballerina Central for the latest Ballerina, so its version is checked against the scan tool once it is installed."
    BAL=latest
  fi
fi

# 3. The pair. Versions given together were already checked by validate.sh, so this catches latest.
if [ -n "$TOOL" ] && [[ "$BAL" =~ ^[0-9] ]] && ! version_ge "$BAL" "$NEEDED"; then
  case "$WANTED_BAL" in
    '' | latest)
      die "The latest Ballerina is $BAL, but $TOOL_NAME needs Ballerina $NEEDED or later. Set tool-version to an older scan tool, or leave it empty to use the latest one compatible with Ballerina $BAL."
      ;;
    *)
      die "ballerina-version is $BAL, but $TOOL_NAME needs Ballerina $NEEDED or later. Set a later ballerina-version, or leave tool-version empty to use the latest scan tool compatible with Ballerina $BAL."
      ;;
  esac
fi

# 4. Install Ballerina unless the bal on the path is the one resolved.
if [ "$BAL" != latest ] && bal_matches "$BAL"; then
  echo "Using Ballerina $CURRENT, which is on the path."
  set_output install false
else
  if has_bal && [ -z "$CURRENT" ]; then
    echo "A bal command is on the path, but its version could not be read from 'bal version', so Ballerina $BAL is installed."
  elif has_bal && [ -z "$WANTED_BAL" ]; then
    echo "Ballerina $CURRENT is on the path, but $TOOL_NAME needs $NEEDED or later, so the latest Ballerina is installed."
  elif has_bal; then
    echo "Ballerina $CURRENT is on the path, but ballerina-version is $WANTED_BAL, so Ballerina $BAL is installed."
  fi
  remove_ballerina_debs
  set_output install true
fi
set_output ballerina-version "$BAL"
set_output tool-version "$TOOL"
