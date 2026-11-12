#!/usr/bin/env bash
# Step 3 (sonarqube only): resolves each package's SonarQube settings, before anything is
# downloaded.
#
# Each setting is resolved field by field: the package's item under platform-config packages,
# then the platform level of platform-config, then the package's Scan.toml and properties file.
# Paths in platform-config are relative to the repository root. Paths in Scan.toml are relative to
# the folder of Scan.toml, or to the package for a remote one, as bal scan resolves them.
#
# Inputs (environment): SCAN_WORK_DIR, PLATFORM_CONFIG, CATEGORY.
# Writes: $SCAN_WORK_DIR/sonarqube.json, a list of {package, scan-toml, scan-toml-kind, plugin,
# properties-file, host-url, project-key, project-name}. scan-toml-kind is file, remote (scan-toml
# is then the downloaded copy), or none when the package has no Scan.toml. plugin is {kind, value},
# where kind is version, file, url, or default (resolved by install-sonarqube.sh). Tokens are not
# written; scan.sh reads them from PLATFORM_CONFIG.
# Also writes $SCAN_WORK_DIR/sonar-caches.json, a list of {slot, url, home, prefix}: each server's
# SONAR_USER_HOME and the prefix of its cache keys, and sonar-user-home into each item of
# sonarqube.json.
# Outputs: the Actions cache of SonarScanner, which action.yml restores and saves:
#   scanner-zip, scanner-key, scanner-present  The SonarScanner CLI zip, the prefix of its cache
#                                              keys, and true when an earlier use of the action in
#                                              the job has it.
#   sonar-cache-dir-N, sonar-cache-prefix-N, sonar-cache-present-N  For the server in slot N, from
#                                              1 to SONAR_CACHE_SLOTS: its cache folder of
#                                              analyzers, the prefix of its cache keys, and true when
#                                              an earlier use of the action in the job has it. Not
#                                              set for an unused slot.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
cd "$(workspace_root)"

ERRORS=()
error() { ERRORS+=("$1"); }

CONFIG="$(platform_config_json)" || die "$INVALID_PLATFORM_CONFIG"
SONAR="$(jq -c '.sonarqube // {}' <<< "$CONFIG")"
ITEMS="$(jq -c -L "$SCRIPT_DIR" 'include "common"; [.packages // [] | .[] | . + {path: (.path | package_path)}]' <<< "$SONAR")"
UNITS="$(cat "$WORK/units.json")"

while IFS= read -r path; do
  jq -e --arg p "$path" 'any(.[]; .path == $p)' <<< "$UNITS" > /dev/null \
    || error "platform-config.sonarqube.packages has the path '$path', which matches no scanned package. Give the package directory relative to the repository root."
done < <(jq -r '.[].path' <<< "$ITEMS")

# The platform-level project-key and project-name are for a scan of one package. With more
# packages they would name one project for all of them, so each package sets its own under
# packages. With one package, a field set both there and in the package's item is an error. Items
# that match no scanned package are reported above, so they are left out here.
UNIT_COUNT="$(jq 'length' <<< "$UNITS")"
for field in project-key project-name; do
  jq -e --arg f "$field" 'has($f)' <<< "$SONAR" > /dev/null || continue
  if [ "$UNIT_COUNT" -gt 1 ]; then
    error "platform-config.sonarqube.$field is for a single package, but $UNIT_COUNT packages are scanned. Set $field for each package under packages, and leave it out of the platform level."
  else
    while IFS= read -r path; do
      error "platform-config.sonarqube.$field is set at the platform level and in the packages item '$path'. Set it in one place."
    done < <(jq -r --arg f "$field" --argjson units "$UNITS" \
      '.[] | select(has($f)) | .path as $p | select(any($units[]; .path == $p)) | $p' <<< "$ITEMS")
  fi
done

# Resolves a plugin-path or plugin-version from platform-config. Prints {kind, value}, or a line
# starting with "!" and the problem, since it runs in a subshell.
config_plugin() {
  local where="$1" path="$2" version="$3"
  if [ -n "$version" ]; then
    jq -nc --arg v "$version" '{kind: "version", value: $v}'
  elif [[ "$path" =~ ^https:// ]]; then
    jq -nc --arg v "$path" '{kind: "url", value: $v}'
  elif is_absolute_path "$path"; then
    echo "!$where.plugin-path is the absolute path '$path', which points to one machine. Give a path relative to the repository root, or an https URL."
  elif [ ! -f "$(to_unix_path "$path")" ]; then
    echo "!$where.plugin-path is '$path', which is not an existing file. Give a path relative to the repository root, or an https URL."
  else
    jq -nc --arg v "$(to_unix_path "$path")" '{kind: "file", value: $v}'
  fi
}

RESOLVED='[]'
while IFS= read -r unit; do
  pkg="$(jq -r '.path' <<< "$unit")"
  if [ "$(jq -r '.kind' <<< "$unit")" = "workspace" ]; then
    error "Package '$pkg' is a workspace. bal scan reports each workspace member to the same SonarQube project, so SonarQube is not supported for workspaces yet. Give the member package directories in paths instead of the workspace or a directory above it, or leave sonarqube out of platforms."
    continue
  fi

  item="$(jq -c -L "$SCRIPT_DIR" --arg p "$pkg" 'include "common"; sonar_item($p)' <<< "$SONAR")"
  where="platform-config.sonarqube"
  [ "$item" != "{}" ] && where="platform-config.sonarqube.packages item '$pkg'"
  # A field from the package's item, then from the platform level.
  pick() {
    jq -r -L "$SCRIPT_DIR" --arg p "$pkg" --arg f "$1" 'include "common"; sonar_setting($p; $f)' <<< "$SONAR"
  }

  # The package's Scan.toml and its sonarqube [[platform]] entry. For a remote Scan.toml, that is
  # the copy find-packages.sh downloaded, and messages name its URL.
  info="$(unit_scan_config "$unit" "$pkg")"
  read_scan_config "$info"
  scan_toml="$SCAN_TOML"
  scan_url="$SCAN_URL"
  scan_toml_name="${scan_url:-$scan_toml}"
  scan_toml_kind="none"
  entry='{}'
  base="$(scan_toml_base_dir "$pkg" "$scan_toml" "$scan_url")"
  if [ -n "$scan_toml" ]; then
    scan_toml_kind="file"
    [ -z "$scan_url" ] || scan_toml_kind="remote"
    if ! platforms="$(scan_toml_platforms "$scan_toml")"; then
      error "Package '$pkg': could not read '$scan_toml_name' as TOML."
      continue
    fi
    entry="$(jq -c 'map(select(.name == "sonarqube")) | first // {}' <<< "$platforms")"
    # The SonarQube scan replaces this entry with one for the resolved plugin.
    if ! sonarqube_entry_replaceable "$scan_toml"; then
      error "Package '$pkg': the [[platform]] entries in '$scan_toml_name' are in a form the action cannot change. Write each entry as a [[platform]] table, not an array of inline tables, with name = \"...\" on its own line and without a multi-line string that holds a line starting with '['."
      continue
    fi
  else
    # The SonarQube scan of a workspace member without a Scan.toml starts from the workspace's.
    ws_toml="$(jq -r '."workspace-scan-toml" // ""' <<< "$info")"
    if [ -n "$ws_toml" ] && ! sonarqube_entry_replaceable "$ws_toml"; then
      error "Package '$pkg': the SonarQube scan of this member adds a [[platform]] entry to a copy of the workspace Scan.toml '$ws_toml', which is in a form the action cannot extend. Remove its platform entries, which bal scan ignores in a workspace Scan.toml, and any multi-line string that holds a line starting with '['."
      continue
    fi
  fi

  # 1. Platform plugin. A plugin-path or plugin-version in the item replaces both platform-level
  # fields.
  plugin=""
  if jq -e 'has("plugin-path") or has("plugin-version")' <<< "$item" > /dev/null; then
    plugin="$(config_plugin "$where" "$(jq -r '."plugin-path" // "" | tostring' <<< "$item")" \
      "$(jq -r '."plugin-version" // "" | tostring' <<< "$item")")"
  elif jq -e 'has("plugin-path") or has("plugin-version")' <<< "$SONAR" > /dev/null; then
    plugin="$(config_plugin "$where" "$(jq -r '."plugin-path" // "" | tostring' <<< "$SONAR")" \
      "$(jq -r '."plugin-version" // "" | tostring' <<< "$SONAR")")"
  else
    entry_path="$(jq -r '.path // "" | tostring' <<< "$entry")"
    if [ -z "$entry_path" ]; then
      plugin='{"kind":"default"}'
    elif [[ "$entry_path" =~ ^https:// ]]; then
      plugin="$(jq -nc --arg v "$entry_path" '{kind: "url", value: $v}')"
    elif [[ "$entry_path" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
      error "Package '$pkg': the sonarqube [[platform]] entry in '$scan_toml_name' has the path '$entry_path'. Use an https URL or a relative path."
    elif is_absolute_path "$entry_path"; then
      error "Package '$pkg': the sonarqube [[platform]] entry in '$scan_toml_name' has the absolute path '$entry_path', which points to one machine. Use a relative path, an https URL, or set plugin-version under platform-config.sonarqube."
    elif [ ! -f "$base/$(to_unix_path "$entry_path")" ]; then
      error "Package '$pkg': the sonarqube [[platform]] entry in '$scan_toml_name' has the path '$entry_path', which is not an existing file relative to '$base'."
    else
      plugin="$(jq -nc --arg v "$base/$(to_unix_path "$entry_path")" '{kind: "file", value: $v}')"
    fi
  fi

  # 2. Properties file.
  properties_file=""
  config_properties="$(pick properties-file)"
  entry_properties="$(jq -r '.sonarProjectPropertiesPath // "" | tostring' <<< "$entry")"
  if [ -n "$config_properties" ]; then
    properties_file="$(to_unix_path "$config_properties")"
    if [ ! -f "$properties_file" ]; then
      error "$where.properties-file is '$config_properties', which does not exist. Give a path relative to the repository root."
      continue
    fi
  elif [ -n "$entry_properties" ]; then
    # bal scan resolves it against the folder of Scan.toml when the file is there, and otherwise
    # passes it unchanged to the platform plugin, which runs in the package.
    if is_absolute_path "$entry_properties"; then
      properties_file="$(to_unix_path "$entry_properties")"
    else
      properties_file="$base/$(to_unix_path "$entry_properties")"
      [ -f "$properties_file" ] || properties_file="$pkg/$(to_unix_path "$entry_properties")"
    fi
    if [ ! -f "$properties_file" ]; then
      error "Package '$pkg': sonarProjectPropertiesPath in '$scan_toml_name' is '$entry_properties', which is not an existing file relative to '$base' or to the package."
      continue
    fi
  elif [ -f "$pkg/sonar-project.properties" ]; then
    properties_file="$pkg/sonar-project.properties"
  fi
  [ -z "$properties_file" ] || properties_file="$(cd "$(dirname "$properties_file")" && pwd -P)/$(basename "$properties_file")"

  # 3. Settings.
  host_url="$(pick host-url)"
  host_from="$where.host-url"
  if [ -z "$host_url" ] && [ -n "$properties_file" ]; then
    host_url="$(read_property "$properties_file" sonar.host.url)"
    host_from="sonar.host.url in $properties_file"
  fi
  project_key="$(pick project-key)"
  [ -n "$project_key" ] || [ -z "$properties_file" ] || project_key="$(read_property "$properties_file" sonar.projectKey)"
  project_name="$(pick project-name)"
  [ -n "$project_name" ] || [ -z "$properties_file" ] || project_name="$(read_property "$properties_file" sonar.projectName)"
  token="$(pick token)"

  # 4. Validation.
  if [ -z "$host_url" ]; then
    error "Package '$pkg' has no SonarQube server URL. Set host-url under platform-config.sonarqube or for the package under packages, or sonar.host.url in its sonar-project.properties."
  elif ! [[ "$host_url" =~ ^https://[^[:space:]/]+ ]]; then
    error "Package '$pkg' has the SonarQube server URL '$host_url' from $host_from, which is not an https URL. The token is sent to it, so only https is accepted."
  elif [ "$host_from" != "$where.host-url" ] && [ -n "$token" ] && ! jq -e 'has("token")' <<< "$item" > /dev/null; then
    # Like host-url under packages, a server named outside platform-config needs a token of its own.
    error "Package '$pkg' takes its SonarQube server URL from $host_from, but its token from the platform level of platform-config.sonarqube. The platform-level token is not sent to another server. Set host-url under platform-config.sonarqube, or set token for the package under packages."
  fi
  if [ -z "$project_key" ]; then
    error "Package '$pkg' has no SonarQube project key. Set project-key for it under platform-config.sonarqube.packages, or sonar.projectKey in its sonar-project.properties."
  fi
  if [ -z "$token" ]; then
    error "Package '$pkg' has no SonarQube token. Set token under platform-config.sonarqube or for the package under packages, from a secret such as \${{ secrets.SONAR_TOKEN }}."
  fi
  if [[ "$plugin" == '!'* ]]; then
    error "${plugin#!}"
    plugin=""
  fi
  [ -n "$plugin" ] || continue

  RESOLVED="$(jq -c --arg pkg "$pkg" --arg toml "$scan_toml" --arg kind "$scan_toml_kind" --argjson plugin "$plugin" \
    --arg props "$properties_file" --arg url "$host_url" --arg key "$project_key" --arg name "$project_name" \
    '. + [{package: $pkg, "scan-toml": $toml, "scan-toml-kind": $kind, plugin: $plugin, "properties-file": $props,
           "host-url": $url, "project-key": $key, "project-name": $name}]' <<< "$RESOLVED")"
done < <(jq -c '.[]' <<< "$UNITS")

# Each analysis would replace the previous one of the same project on the same server.
while IFS= read -r dup; do
  [ -n "$dup" ] && error "$dup"
done < <(jq -r 'map(select(."project-key" != "")) | group_by([."host-url", ."project-key"])[] | select(length > 1)
  | "Packages \(map(.package | @json) | join(", ")) resolve to the same SonarQube project key \(.[0]."project-key" | @json) on \(.[0]."host-url"), so each analysis would replace the previous one. Give each package its own project key."' <<< "$RESOLVED")

if [ "${#ERRORS[@]}" -gt 0 ]; then
  for e in "${ERRORS[@]}"; do log_error "$e"; done
  exit 1
fi

# The Actions cache, restored before the tools are installed. Each server gets its own
# SONAR_USER_HOME and cache, since SonarScanner downloads the analyzers the server has installed,
# so jobs that share a server share its cache whatever other servers they use.
DIST="$(sonar_scanner_dist)" || die "SonarQube reporting does not support the runner's operating system, ${RUNNER_OS:-$(uname -s)}."
SCANNER_DIR="$(sonar_scanner_dir "$DIST")"
SCANNER_ZIP="$(sonar_scanner_zip "$DIST")"
present() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2> /dev/null)" ] && echo true || echo false; }
USER_SONAR_HOME="$(to_unix_path "${SONAR_USER_HOME:-$HOME/.sonar}")"

CACHES='[]'
while IFS= read -r url; do
  server="$(printf '%s' "$url" | sha256_of /dev/stdin | cut -c1-16)"
  home="$(sonar_user_home "$server")"
  # SonarScanner reads the truststore and keystore of a private CA from SONAR_USER_HOME/ssl, so the
  # user's own ssl folder is carried over to the action's SONAR_USER_HOME. It is outside the cache.
  if [ -d "$USER_SONAR_HOME/ssl" ] && [ "$USER_SONAR_HOME" != "$home" ]; then
    mkdir -p "$home"
    rm -rf "$home/ssl"
    cp -R "$USER_SONAR_HOME/ssl" "$home/ssl"
  fi
  CACHES="$(jq -c --arg url "$url" --arg home "$home" --arg prefix "scan-ballerina-sonar-cache-$DIST-$server-" \
    '. + [{slot: (length + 1), url: $url, home: $home, prefix: $prefix}]' <<< "$CACHES")"
done < <(jq -r '[.[]."host-url" | rtrimstr("/")] | unique | .[]' <<< "$RESOLVED")
[ ! -d "$USER_SONAR_HOME/ssl" ] || echo "SonarScanner uses the ssl folder of $USER_SONAR_HOME."
printf '%s\n' "$CACHES" > "$WORK/sonar-caches.json"

RESOLVED="$(jq -c --argjson caches "$CACHES" \
  'map(."host-url" as $u | . + {"sonar-user-home": ($caches[] | select(.url == ($u | rtrimstr("/"))) | .home)})' <<< "$RESOLVED")"
printf '%s\n' "$RESOLVED" > "$WORK/sonarqube.json"
jq -r '.[] | "SonarQube project for \(.package): \(."project-key") on \(."host-url")"' <<< "$RESOLVED"

set_output scanner-zip "$(to_native_path "$SCANNER_ZIP")"
# A prefix: saved keys add the run, so a zip saved again after failing its checksum is restored next.
set_output scanner-key "scan-ballerina-sonar-scanner-zip-$PINNED_SONAR_SCANNER_VERSION-$DIST-$(sonar_scanner_sha256 "$DIST" | cut -c1-16)"
set_output scanner-present "$({ [ -f "$SCANNER_ZIP" ] || [ "$(present "$SCANNER_DIR")" = true ]; } && echo true || echo false)"
# action.yml has a fixed set of cache steps, one per slot. A server past the last slot is scanned
# with its own SONAR_USER_HOME, which is not kept in the Actions cache.
COUNT="$(jq 'length' <<< "$CACHES")"
[ "$COUNT" -le "$SONAR_CACHE_SLOTS" ] \
  || echo "The run uses $COUNT SonarQube servers; the analyzers of the first $SONAR_CACHE_SLOTS are kept in the Actions cache."
for ((slot = 1; slot <= SONAR_CACHE_SLOTS; slot++)); do
  home="$(jq -r --argjson s "$slot" '.[] | select(.slot == $s) | .home' <<< "$CACHES")"
  if [ -n "$home" ]; then
    set_output "sonar-cache-dir-$slot" "$(to_native_path "$home/cache")"
    set_output "sonar-cache-prefix-$slot" "$(jq -r --argjson s "$slot" '.[] | select(.slot == $s) | .prefix' <<< "$CACHES")"
    set_output "sonar-cache-present-$slot" "$(present "$home/cache")"
  fi
done
