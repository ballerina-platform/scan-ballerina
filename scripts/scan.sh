#!/usr/bin/env bash
# Step 6: runs bal scan on each package or workspace found by find-packages.sh.
#
# Each unit gets a SARIF pass, and with SONARQUBE=true a SonarQube pass:
#   - SARIF pass: bal scan --format=sarif. The scan tool writes no report file while any
#     [[platform]] entry is active, and every entry in Scan.toml is always active. So when the
#     package's Scan.toml has [[platform]] entries, they are hidden for this pass only: the file is
#     copied to the journal and restored as soon as the pass ends, also when it fails.
#   - SonarQube pass: bal scan --platforms=sonarqube, with the package's resolved settings passed
#     to SonarScanner as environment variables of that process only, and the installed
#     SonarScanner on its path. The scan tool reads the platform plugin only from Scan.toml, so
#     its sonarqube [[platform]] entry points to the resolved plugin for this pass only: the file
#     is restored, or deleted when the action created it, as soon as the pass ends. So are the
#     results file the platform plugin writes and the .scannerwork directory of SonarScanner.
#   - A remote Scan.toml cannot be changed, so for each pass [scan] configPath in Ballerina.toml
#     points to a changed copy of the file find-packages.sh downloaded, and Ballerina.toml is
#     restored as soon as the pass ends.
# A failing unit does not stop the others, so every failure is reported. A failed SARIF pass
# fails the step. A failed SonarQube pass only fails SonarQube: the SARIF file is still produced,
# and report.sh fails the step at the end.
#
# Inputs (environment): SCAN_WORK_DIR, SONARQUBE, PLATFORM_CONFIG, SCANNER_BIN, INCLUDE_RULES,
# EXCLUDE_RULES, CATEGORY.
# Writes: $SCAN_WORK_DIR/reports/<index>.sarif per unit, in the order of units.json,
# $SCAN_WORK_DIR/sonarqube-uploads.json and $SCAN_WORK_DIR/sonarqube-failures.txt, one line per
# package whose SonarQube pass failed.
# Outputs: packages, the number of packages scanned, when every unit was scanned.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
ROOT="$(workspace_root)"
cd "$ROOT"

RULE_ARGS=()
INCLUDE="$(split_list "${INCLUDE_RULES:-}" | paste -sd, -)"
EXCLUDE="$(split_list "${EXCLUDE_RULES:-}" | paste -sd, -)"
[ -n "$INCLUDE" ] && RULE_ARGS+=("--include-rules=$INCLUDE")
[ -n "$EXCLUDE" ] && RULE_ARGS+=("--exclude-rules=$EXCLUDE")

SONAR=""
if [ "${SONARQUBE:-false}" = "true" ]; then
  SONAR="$(platform_config_json)" || die "$INVALID_PLATFORM_CONFIG"
  SONAR="$(jq -c '.sonarqube // {}' <<< "$SONAR")"
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
  jar="$(to_native_path "$(jq -r '."plugin-file"' <<< "$settings")")"
  tmp="$(mktemp "$WORK/Scan.toml.XXXXXX")"
  if [ -n "$file" ]; then
    drop_platforms sonarqube < "$file" > "$tmp"
    echo >> "$tmp"
  fi
  printf '[[platform]]\nname = "sonarqube"\npath = "%s"\n' "$jar" >> "$tmp"
  use_scan_toml "$info" "$tmp"
}

# Hides the [[platform]] entries of a package's Scan.toml until restore_files runs. $1 is the
# package's scan_config_info from units.json. A remote Scan.toml is always replaced with a local
# copy, so that the scan reads the file that find-packages.sh downloaded and checked.
hide_platforms() {
  local info="$1" tmp
  read_scan_config "$info"
  [ -n "$SCAN_TOML" ] || return 0
  if [ -z "$SCAN_URL" ]; then
    [ -f "$SCAN_TOML" ] && grep -Eq '^[[:space:]]*\[\[[[:space:]]*platform[[:space:]]*\]\]' "$SCAN_TOML" || return 0
  fi
  tmp="$(mktemp "$WORK/Scan.toml.XXXXXX")"
  drop_platforms all < "$SCAN_TOML" > "$tmp"
  use_scan_toml "$info" "$tmp"
}

# Makes a package read the Scan.toml in file $2 until restore_files runs. $1 is the package's
# scan_config_info. A local Scan.toml, or the package's Scan.toml when it has none, is overwritten
# with it. A remote one cannot be, so [scan] configPath in Ballerina.toml points to the file
# instead.
use_scan_toml() {
  local new="$2" pkg target native
  read_scan_config "$1"
  pkg="$SCAN_PKG"
  if [ -n "$SCAN_URL" ]; then
    native="$(to_native_path "$(cd "$(dirname "$new")" && pwd -P)/$(basename "$new")")"
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
    hide_platforms "$info"
  done < <(jq -c '."scan-config" // [] | .[]' <<< "$unit")

  status=0
  run_bal_scan "$path" "$WORK/logs/scan-$idx.log" --format=sarif "${RULE_ARGS[@]+"${RULE_ARGS[@]}"}" || status=$?
  restore_files

  # bal scan reports some errors, such as an invalid Scan.toml, without a failing exit code.
  if [ "$status" -ne 0 ]; then
    FAILED+=("$path: bal scan exited with code $status")
  elif [ ! -f "$report" ] || ! jq -e '.runs[0]' "$report" > /dev/null 2>&1; then
    FAILED+=("$path: bal scan did not write a SARIF report. See its output above")
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
    PATH="${SCANNER_BIN:+$SCANNER_BIN:}$PATH" \
      SONAR_HOST_URL="$(jq -r '."host-url"' <<< "$settings")" \
      SONAR_TOKEN="$(sonar_token "$path")" \
      SONAR_SCANNER_JSON_PARAMS="$params" \
      run_bal_scan "$path" "$log" --platforms=sonarqube "${RULE_ARGS[@]+"${RULE_ARGS[@]}"}" || status=$?
    # The platform plugin does not fail bal scan when SonarScanner fails. SonarScanner writes
    # report-task.txt, with the ID of the server's background task, only once the server has
    # accepted the analysis, so that file decides. It is read before .scannerwork is removed.
    task_id="$(read_property "$task_file" ceTaskId)"
    dashboard="$(read_property "$task_file" dashboardUrl | sed 's/\\:/:/g')"
    restore_files
    if [ "$status" -ne 0 ]; then
      SONAR_FAILED+=("$path: reporting to SonarQube failed, bal scan exited with code $status")
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
