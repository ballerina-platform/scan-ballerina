#!/usr/bin/env bash
# Step 4: resolves the Ballerina to install and the scan tool version, before either is installed.
#
# A version, or latest, is used as given. latest is the newest release, whatever the other version
# is, and a Ballerina older than the scan tool needs, from the Ballerina update Ballerina Central
# records for that scan tool version, fails. An empty version is resolved to one that
# works with the other:
# - An empty ballerina-version is the bal on the path when it can run the given scan tool, or with
#   an empty tool-version when it can run the latest scan tools, and otherwise the latest Ballerina.
# - An empty tool-version is the latest scan tool Ballerina Central picks for that Ballerina. When
#   the Ballerina is known only once installed, such as 2201.13 or nightly, install-scan-tool.sh
#   asks Central instead.
# A workspace with a Ballerina or scan tool that cannot scan it also fails here.
#
# Inputs (environment): SCAN_WORK_DIR, BALLERINA_VERSION, TOOL_VERSION, CATEGORY.
# Outputs: install (true when Ballerina must be installed), ballerina-version (the version to
# install, or the one on the path), tool-version (the scan tool to install, or empty for the latest
# one compatible with the installed Ballerina), tool-picked (true when Central picked it),
# tool-checked (false when Central could not say which Ballerina it needs).

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
WANTED_BAL="$(trim "${BALLERINA_VERSION:-}")"
WANTED_TOOL="$(trim "${TOOL_VERSION:-}")"

# Sets NEEDED to the Ballerina bal scan $TOOL needs, from Ballerina Central. When Central cannot
# say, TOOL_CHECKED is false and NEEDED is the oldest Ballerina for that scan tool line.
tool_needs() {
  TOOL_CHECKED=true
  NEEDED="$(tool_min_ballerina "$TOOL")" && return
  TOOL_CHECKED=false
  NEEDED="$(known_tool_min_ballerina "$TOOL")"
  if [ "$WANTED_TOOL" = "$TOOL" ]; then
    log_warning "Could not ask Ballerina Central which Ballerina bal scan $TOOL needs, so Ballerina $NEEDED or later is assumed. Check that tool-version names a published version."
  else
    log_warning "Could not ask Ballerina Central which Ballerina $TOOL_NAME needs, so Ballerina $NEEDED or later is assumed."
  fi
}

# 1. The scan tool, when given or latest.
TOOL="$WANTED_TOOL"
if [ "$TOOL" = latest ]; then
  TOOL="$(latest_tool_version)" \
    || die "Could not ask Ballerina Central for the latest bal scan. Set tool-version to a version, or leave it empty to use the latest version compatible with the Ballerina version."
  echo "The latest bal scan is $TOOL."
fi
TOOL_NAME="bal scan $TOOL"
[ "$WANTED_TOOL" != latest ] || TOOL_NAME="the latest bal scan, $TOOL,"
TOOL_CHECKED=true
TOOL_PICKED=false

# 2. Ballerina. An empty ballerina-version keeps a bal on the path that can run the given scan
# tool, or with an empty tool-version the newest supported line, so it is not limited to 0.11.x.
if [ -n "$TOOL" ]; then
  tool_needs
  KEEP="$NEEDED"
  KEEP_REASON="$TOOL_NAME needs $NEEDED"
else
  KEEP="$NEWEST_LINE_BALLERINA_VERSION"
  KEEP_REASON="bal scan $NEWEST_LINE_TOOL_VERSION and later need $KEEP"
fi
CURRENT=""
if has_bal; then
  CURRENT="$(bal_version)"
fi
BAL="$WANTED_BAL"
if [ -z "$BAL" ]; then
  if [ -n "$CURRENT" ] && version_ge "$CURRENT" "$KEEP"; then
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
    log_warning "Could not ask Ballerina Central for the latest Ballerina, so the latest one setup-ballerina finds is installed, and checked against the scan tool once it is installed."
    BAL=latest
  fi
fi
BAL_NAME="Ballerina $BAL"
[ "$BAL" != latest ] || BAL_NAME="the latest Ballerina"

# 3. An empty tool-version, for a Ballerina known before it is installed.
if [ -z "$TOOL" ] && [[ "$BAL" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  if pick_compatible_tool "$BAL"; then
    TOOL="$PICKED_TOOL"
    TOOL_NAME="bal scan $TOOL, which Ballerina Central picked,"
    TOOL_PICKED=true
    tool_needs
  else
    # install-scan-tool.sh falls back to the active scan tool, without asking Central again.
    log_warning "Could not ask Ballerina Central for the latest bal scan compatible with Ballerina $BAL."
  fi
fi

# 4. The pair. When Central could not say which Ballerina the scan tool needs, the oldest
# Ballerina for its scan tool line is checked.
if [ -n "$TOOL" ] && [[ "$BAL" =~ ^[0-9] ]] && ! version_ge "$BAL" "$NEEDED"; then
  # Central disagrees with itself here, and BAL may be the bal on the path.
  [ "$TOOL_PICKED" != true ] \
    || die "Ballerina Central picked bal scan $TOOL as the latest version compatible with Ballerina $BAL, but records that it needs Ballerina $NEEDED or later. Set tool-version to a version that supports Ballerina $BAL."
  case "$WANTED_BAL" in
    '' | latest)
      die "The latest Ballerina is $BAL, but $TOOL_NAME needs Ballerina $NEEDED or later. Set tool-version to an older scan tool, or leave it empty to use the latest one compatible with Ballerina $BAL."
      ;;
    *)
      die "ballerina-version is $BAL, but $TOOL_NAME needs Ballerina $NEEDED or later. Set a later ballerina-version, or leave tool-version empty to use the latest scan tool compatible with Ballerina $BAL."
      ;;
  esac
fi

# 5. Workspaces, which fail here before anything is installed when the versions are known.
check_workspace_support "$BAL" "$TOOL" "$WORK/units.json"

# 6. Install Ballerina unless the bal on the path is the one resolved: that version, or a prefix
# of it, such as 2201.13.
if [ "$BAL" != latest ] && [ -n "$CURRENT" ] && { [ "$CURRENT" = "$BAL" ] || [[ "$CURRENT" == "$BAL".* ]]; }; then
  echo "Using Ballerina $CURRENT, which is on the path."
  set_output install false
else
  if has_bal && [ -z "$CURRENT" ]; then
    echo "A bal command is on the path, but its version could not be read from 'bal version', so $BAL_NAME is installed."
  elif [ "$WANTED_BAL" = latest ] && [ -n "$CURRENT" ] && version_ge "$CURRENT" "$KEEP"; then
    log_warning "Ballerina $CURRENT is on the path and can run the scan tool, but ballerina-version is latest, so $BAL_NAME is installed and used for the rest of the job. Leave ballerina-version empty to keep Ballerina $CURRENT."
  elif has_bal && [ -z "$WANTED_BAL" ]; then
    echo "Ballerina $CURRENT is on the path, but $KEEP_REASON or later, so $BAL_NAME is installed."
  elif has_bal; then
    echo "Ballerina $CURRENT is on the path, but ballerina-version is $WANTED_BAL, so $BAL_NAME is installed."
  fi
  remove_ballerina_debs
  set_output install true
fi
set_output ballerina-version "$BAL"
set_output tool-version "$TOOL"
set_output tool-picked "$TOOL_PICKED"
set_output tool-checked "$TOOL_CHECKED"
