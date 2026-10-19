#!/usr/bin/env bash
# Step 3 (sonarqube only): resolves each package's SonarQube settings, before anything is
# downloaded.
#
# Each setting is resolved field by field: the package's item under platform-config packages,
# then the platform level of platform-config, then the package's Scan.toml and properties file.
# Paths in platform-config are relative to the repository root, and paths in Scan.toml are
# relative to the package.
#
# Inputs (environment): SCAN_WORK_DIR, PLATFORM_CONFIG, CATEGORY.
# Writes: $SCAN_WORK_DIR/sonarqube.json, a list of {package, scan-toml, scan-toml-kind, plugin,
# properties-file, host-url, project-key, project-name}. scan-toml-kind is file, remote (scan-toml
# is then the downloaded copy), or none when the package has no Scan.toml. plugin is {kind, value},
# where kind is version, file or url. Tokens are not written; scan.sh reads them from
# PLATFORM_CONFIG.

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
  scan_toml="$(scan_toml_path "$pkg")"
  scan_url="$(scan_config_url "$pkg")"
  scan_toml_name="${scan_url:-$scan_toml}"
  scan_toml_kind="none"
  entry='{}'
  if [ -n "$scan_toml" ]; then
    scan_toml_kind="file"
    [ -z "$scan_url" ] || scan_toml_kind="remote"
    if ! platforms="$(scan_toml_platforms "$scan_toml")"; then
      error "Package '$pkg': could not read '$scan_toml_name' as TOML."
      continue
    fi
    entry="$(jq -c 'map(select(.name == "sonarqube")) | first // {}' <<< "$platforms")"
    # The SonarQube scan replaces this entry with one for the resolved plugin.
    left="$(drop_platforms sonarqube < "$scan_toml" \
      | yq -p toml -o json -I0 '[.platform // [] | .[] | select(.name == "sonarqube")] | length' 2> /dev/null | tr -d '\r')" || left=""
    if [ "$left" != 0 ]; then
      error "Package '$pkg': the sonarqube [[platform]] entry in '$scan_toml_name' is in a form the action cannot replace. Write it as a [[platform]] table with name = \"sonarqube\" on its own line."
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
      plugin="$(jq -nc --arg v "$PINNED_SONAR_PLUGIN_VERSION" '{kind: "version", value: $v}')"
    elif [[ "$entry_path" =~ ^https:// ]]; then
      plugin="$(jq -nc --arg v "$entry_path" '{kind: "url", value: $v}')"
    elif [[ "$entry_path" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
      error "Package '$pkg': the sonarqube [[platform]] entry in '$scan_toml_name' has the path '$entry_path'. Use an https URL or a path relative to the package."
    elif is_absolute_path "$entry_path"; then
      error "Package '$pkg': the sonarqube [[platform]] entry in '$scan_toml_name' has the absolute path '$entry_path', which points to one machine. Use a path relative to the package, an https URL, or set plugin-version under platform-config.sonarqube."
    elif [ ! -f "$pkg/$(to_unix_path "$entry_path")" ]; then
      error "Package '$pkg': the sonarqube [[platform]] entry in '$scan_toml_name' has the path '$entry_path', which is not an existing file relative to the package."
    else
      plugin="$(jq -nc --arg v "$pkg/$(to_unix_path "$entry_path")" '{kind: "file", value: $v}')"
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
    properties_file="$pkg/$(to_unix_path "$entry_properties")"
    is_absolute_path "$entry_properties" && properties_file="$(to_unix_path "$entry_properties")"
    if [ ! -f "$properties_file" ]; then
      error "Package '$pkg': sonarProjectPropertiesPath in '$scan_toml_name' is '$entry_properties', which does not exist."
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

printf '%s\n' "$RESOLVED" > "$WORK/sonarqube.json"
jq -r '.[] | "SonarQube project for \(.package): \(."project-key") on \(."host-url")"' <<< "$RESOLVED"
