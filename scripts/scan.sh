#!/usr/bin/env bash
# Step 6: runs bal scan on each package or workspace found by find-packages.sh.
#
# Each unit gets a SARIF pass, and with SONARQUBE=true a SonarQube pass:
#   - SARIF pass: bal scan --format=sarif. bal scan uses a [[platform]] entry only when
#     --platforms names it, so Scan.toml is read as it is.
#   - SonarQube pass: bal scan --platforms=sonarqube, with the package's resolved settings passed
#     to SonarScanner as environment variables of that process only, and the installed
#     SonarScanner on its path. The scan tool reads the platform plugin only from Scan.toml, so
#     its sonarqube [[platform]] entry points to the resolved plugin for this pass only: the file
#     is restored, or deleted when the action created it, as soon as the pass ends. So are the
#     results file the platform plugin writes and the .scannerwork directory of SonarScanner.
#   - A remote Scan.toml cannot be changed, so each pass points [scan] configPath at the local copy
#     from find-packages.sh, and Ballerina.toml is restored as soon as the pass ends.
# Both passes set --exclude-tests from the input, and --fail-on-severity=NONE since report.sh gates.
# A failing unit does not stop the others, so every failure is reported. A failed SARIF pass
# fails the step. A failed SonarQube pass only fails SonarQube: the SARIF file is still produced,
# and report.sh fails the step at the end.
#
# Inputs (environment): SCAN_WORK_DIR, SONARQUBE, SCAN_BALLERINA_VERSION and SCAN_TOOL_VERSION
# (the installed Ballerina and scan tool), PLATFORM_CONFIG, SCANNER_BIN,
# INCLUDE_RULES, EXCLUDE_RULES, EXCLUDE_TESTS, SUPPRESSIONS, CATEGORY.
# Writes: $SCAN_WORK_DIR/reports/<index>.sarif per unit, in the order of units.json,
# $SCAN_WORK_DIR/sonarqube-uploads.json and $SCAN_WORK_DIR/sonarqube-failures.txt, one line per
# package whose SonarQube pass failed, and $SCAN_WORK_DIR/scan-failures.txt, one line per unit
# whose SARIF pass failed, with the errors bal scan printed.
# Outputs: packages, the number of packages scanned, when every unit was scanned.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
ROOT="$(workspace_root)"
cd "$ROOT"

# Catches workspaces resolve-versions.sh could not check, such as with an unresolved latest.
check_workspace_support "${SCAN_BALLERINA_VERSION:-}" "${SCAN_TOOL_VERSION:-}" "$WORK/units.json"

SCAN_ARGS=("--exclude-tests=$(bool_setting "${EXCLUDE_TESTS:-}")" --fail-on-severity=NONE)
INCLUDE="$(split_list "${INCLUDE_RULES:-}" | paste -sd, -)"
EXCLUDE="$(split_list "${EXCLUDE_RULES:-}" | paste -sd, -)"
[ -n "$INCLUDE" ] && SCAN_ARGS+=("--include-rules=$INCLUDE")
[ -n "$EXCLUDE" ] && SCAN_ARGS+=("--exclude-rules=$EXCLUDE")
[ "$(bool_setting "${SUPPRESSIONS:-}")" = true ] || SCAN_ARGS+=(--ignore-suppressions)

SONAR=""
if [ "${SONARQUBE:-false}" = "true" ]; then
  SONAR="$(platform_config_json)" || die "$INVALID_PLATFORM_CONFIG"
  SONAR="$(jq -c '.sonarqube // {}' <<< "$SONAR")"
  # Each server's SONAR_USER_HOME, so that sonar-cache.sh can tell the analyzers the scan read.
  if [ -f "$WORK/sonar-caches.json" ]; then
    while IFS= read -r home; do
      rm -f "$home/cache-start"
      mark_sonar_cache "$home/cache" "$home/cache-start"
    done < <(jq -r '.[].home' "$WORK/sonar-caches.json")
  fi
fi

# The token of a package, resolved as check-sonarqube.sh resolved it. Each token goes to its own
# package's scan only.
sonar_token() {
  jq -r -L "$SCRIPT_DIR" --arg p "$1" 'include "common"; sonar_setting($p; "token")' <<< "$SONAR"
}

# Each pass restores the files it changed as soon as it ends. The traps also restore them when the
# step is cancelled or the script fails, and the journal lets the next run restore them when the
# runner stops this one before a trap can run. See journal_dir in lib.sh.
journal_init
trap restore_files EXIT
trap 'restore_files; exit 130' INT
trap 'restore_files; exit 143' TERM

# Points the sonarqube [[platform]] entry of a package's Scan.toml to the resolved plugin JAR until
# restore_files runs. The other entries and settings are kept. The properties file is passed to
# SonarScanner through the environment instead, so the entry has no sonarProjectPropertiesPath.
# $1 is the package's item in sonarqube.json, and $2 its scan_config_info.
use_plugin() {
  local settings="$1" info="$2" file tmp jar
  file="$(jq -r '."scan-toml"' <<< "$settings")"
  # A Scan.toml written for a workspace member hides the workspace's, so it starts from a copy of it.
  [ -n "$file" ] || file="$(jq -r '."workspace-scan-toml" // ""' <<< "$info")"
  jar="$(to_native_path "$(jq -r '."plugin-file"' <<< "$settings")")"
  tmp="$(mktemp "$WORK/Scan.toml.XXXXXX")"
  if [ -n "$file" ]; then
    drop_sonarqube_platform < "$file" > "$tmp"
    echo >> "$tmp"
  fi
  printf '[[platform]]\nname = "sonarqube"\npath = "%s"\n' "$jar" >> "$tmp"
  use_scan_toml "$info" "$tmp"
}

# Makes a package with a remote Scan.toml read the copy find-packages.sh downloaded and checked,
# until restore_files runs, so that the file is not downloaded again. $1 is its scan_config_info.
use_downloaded_scan_toml() {
  read_scan_config "$1"
  [ -z "$SCAN_URL" ] || use_scan_toml "$1" "$SCAN_TOML"
}

# Makes a package read the Scan.toml in file $2 until restore_files runs. $1 is the package's
# scan_config_info. A local Scan.toml, or the package's Scan.toml when it has none, is overwritten
# with it. A remote one cannot be, so [scan] configPath in Ballerina.toml points to a copy of the
# file in the package instead: bal scan resolves the relative paths of a remote Scan.toml against
# the package, but those of a local one against its folder.
use_scan_toml() {
  local new="$2" pkg target native copy
  read_scan_config "$1"
  pkg="$SCAN_PKG"
  if [ -n "$SCAN_URL" ]; then
    copy="$pkg/.scan-ballerina.Scan.toml"
    protect "$copy" "$(sha256_of "$new")"
    cp "$new" "$copy"
    native="$(to_native_path "$(cd "$pkg" && pwd -P)/$(basename "$copy")")"
    target="$(mktemp "$WORK/Ballerina.toml.XXXXXX")"
    with_config_path "$pkg/Ballerina.toml" "$native" > "$target"
    protect "$pkg/Ballerina.toml" "$(sha256_of "$target")"
    cp "$target" "$pkg/Ballerina.toml"
    rm -f "$target"
    # find-packages.sh checked that the line can be changed. This catches a file changed since.
    [ "$(scan_config_value "$pkg")" = "$native" ] \
      || die "Could not point [scan] configPath in '$pkg/Ballerina.toml' to the changed copy of its remote Scan.toml."
  else
    target="${SCAN_TOML:-$pkg/Scan.toml}"
    protect "$target" "$(sha256_of "$new")"
    cp "$new" "$target"
    rm -f "$new"
  fi
}

# Prints the errors bal scan wrote to log file $1, such as "cannot scan package 'org/name': its
# dependencies are not locked in Dependencies.toml", on one line, or nothing when there are none.
scan_errors() {
  { grep -E '^(bal scan: )?error: ' "$1" 2> /dev/null || true; } | tr -d '\r' \
    | sed -E 's/^(bal scan: )?error: //' | head -n 3 | paste -sd ' ' -
}

# Runs bal scan in a directory and keeps its output in a log file. Returns its exit code.
run_bal_scan() {
  local dir="$1" log="$2"
  shift 2
  set +e
  # stdin is closed, so that bal scan and the processes it starts cannot read the list of units.
  (cd "$dir" && bal_cmd scan "$@" < /dev/null) 2>&1 | tee "$log"
  local status="${PIPESTATUS[0]}"
  set -e
  return "$status"
}

: > "$WORK/sonarqube-uploads.jsonl"
: > "$WORK/sonarqube-failures.txt"
FAILED=()
SONAR_FAILED=()
INDEX=0
while IFS= read -r unit; do
  path="$(jq -r '.path' <<< "$unit")"
  report="$path/target/report/scan_results.sarif"
  idx=$INDEX
  INDEX=$((INDEX + 1))
  out="$WORK/reports/$idx.sarif"

  echo "::group::bal scan $path"
  rm -f "$report" "$out"
  # The package, or each member of the workspace.
  while IFS= read -r info; do
    use_downloaded_scan_toml "$info"
  done < <(jq -c '."scan-config" // [] | .[]' <<< "$unit")

  status=0
  run_bal_scan "$path" "$WORK/logs/scan-$idx.log" --format=sarif "${SCAN_ARGS[@]}" || status=$?
  restore_files

  # bal.bat does not always pass on the exit code of bal scan, so the report decides too.
  errors="$(scan_errors "$WORK/logs/scan-$idx.log")"
  if [ "$status" -ne 0 ]; then
    FAILED+=("$path: bal scan exited with code $status${errors:+: $errors}")
  elif [ ! -f "$report" ] || ! jq -e '.runs[0]' "$report" > /dev/null 2>&1; then
    FAILED+=("$path: bal scan did not write a SARIF report${errors:+: $errors}. See its output above")
  else
    cp "$report" "$out"
  fi
  echo "::endgroup::"

  if [ "${SONARQUBE:-false}" = "true" ]; then
    settings="$(jq -c --arg p "$path" 'map(select(.package == $p)) | first' "$WORK/sonarqube.json")"
    echo "::group::bal scan $path (report to SonarQube project $(jq -r '."project-key"' <<< "$settings"))"
    properties_file="$(jq -r '."properties-file"' <<< "$settings")"
    # SonarScanner runs from the package directory and keeps its files in .scannerwork under the
    # project base directory, which the properties file can move.
    base_dir="$path"
    base_prop="$(read_property "$properties_file" sonar.projectBaseDir)"
    if [ -n "$base_prop" ]; then
      base_dir="$path/$(to_unix_path "$base_prop")"
      is_absolute_path "$base_prop" && base_dir="$(to_unix_path "$base_prop")"
    fi
    task_file="$base_dir/.scannerwork/report-task.txt"
    protect "$base_dir/.scannerwork"
    protect "$path/ballerina-static-code-analysis-results.json"
    rm -f "$task_file"
    log="$WORK/logs/sonarqube-$idx.log"
    # These override the properties file. analyzedResultsPath is set here since the plugin's own
    # command-line value does not reach SonarScanner on every OS, and bal scan would then run twice.
    user_params="$(jq -c 'objects' <<< "${SONAR_SCANNER_JSON_PARAMS:-}" 2> /dev/null || true)"
    [ -n "$user_params" ] || user_params='{}'
    params="$(jq -c \
      --arg settings "$(to_native_path "$properties_file")" \
      --arg results "$(to_native_path "$ROOT/$path/ballerina-static-code-analysis-results.json")" \
      --argjson user "$user_params" \
      '$user + {"sonar.projectKey": ."project-key", analyzedResultsPath: $results}
        + (if ."project-name" != "" then {"sonar.projectName": ."project-name"} else {} end)
        + (if $settings != "" then {"project.settings": $settings} else {} end)' <<< "$settings")"
    use_plugin "$settings" "$(unit_scan_config "$unit" "$path")"
    status=0
    # Set on this process only, and credentials never appear on the command line.
    # SONAR_USER_HOME is the server's folder that action.yml keeps in the Actions cache, with the
    # user's ssl folder copied in by check-sonarqube.sh.
    PATH="${SCANNER_BIN:+$SCANNER_BIN:}$PATH" \
      SONAR_HOST_URL="$(jq -r '."host-url"' <<< "$settings")" \
      SONAR_TOKEN="$(sonar_token "$path")" \
      SONAR_SCANNER_JSON_PARAMS="$params" \
      SONAR_USER_HOME="$(to_native_path "$(jq -r '."sonar-user-home"' <<< "$settings")")" \
      run_bal_scan "$path" "$log" --platforms=sonarqube "${SCAN_ARGS[@]}" || status=$?
    # The platform plugin does not fail bal scan when SonarScanner fails. SonarScanner writes
    # report-task.txt, with the ID of the server's background task, only once the server has
    # accepted the analysis, so that file decides. It is read before .scannerwork is removed.
    task_id="$(read_property "$task_file" ceTaskId)"
    dashboard="$(read_property "$task_file" dashboardUrl | sed 's/\\:/:/g')"
    restore_files
    if [ "$status" -ne 0 ]; then
      errors="$(scan_errors "$log")"
      SONAR_FAILED+=("$path: reporting to SonarQube failed, bal scan exited with code $status${errors:+: $errors}")
    elif [ -z "$task_id" ]; then
      SONAR_FAILED+=("$path: reporting to SonarQube failed, since SonarScanner did not submit the analysis. See the SonarScanner output above")
    else
      jq -nc --argjson s "$settings" --arg url "$dashboard" --arg task "$task_id" \
        '{package: $s.package, "project-key": $s."project-key", "dashboard-url": $url, "task-id": $task}' \
        >> "$WORK/sonarqube-uploads.jsonl"
    fi
    echo "::endgroup::"
  fi
done < <(jq -c '.[]' "$WORK/units.json")

jq -sc '.' "$WORK/sonarqube-uploads.jsonl" > "$WORK/sonarqube-uploads.json"

if [ "${#FAILED[@]}" -gt 0 ]; then
  # report.sh puts them in the job summary.
  printf '%s.\n' "${FAILED[@]}" > "$WORK/scan-failures.txt"
  for f in "${FAILED[@]}" "${SONAR_FAILED[@]+"${SONAR_FAILED[@]}"}"; do log_error "$f."; done
  die "bal scan failed for ${#FAILED[@]} of $INDEX package(s), so no SARIF file was produced."
fi

# SonarQube is one destination. Its failures do not stop the SARIF file from being produced and
# sent to the other platforms: report.sh fails the step at the end.
if [ "${#SONAR_FAILED[@]}" -gt 0 ]; then
  printf '%s.\n' "${SONAR_FAILED[@]}" > "$WORK/sonarqube-failures.txt"
  echo "Reporting to SonarQube failed for ${#SONAR_FAILED[@]} package(s). The SARIF file is still produced, and the step fails at the end:"
  printf '  %s.\n' "${SONAR_FAILED[@]}"
fi

# A workspace counts as the packages it holds.
set_output packages "$(jq '[.[] | if .kind == "workspace" then (.members | length) else 1 end] | add // 0' "$WORK/units.json")"
