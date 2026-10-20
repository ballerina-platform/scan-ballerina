# shellcheck shell=bash disable=SC2034
# Shared helpers for the scan-ballerina scripts. Sourced, not executed.
#
# The scripts read their inputs from environment variables and keep their state in the work
# directory, so they can be run locally as well as from action.yml:
#   SCAN_WORK_DIR       Work directory of this run (created by validate.sh).
#   GITHUB_WORKSPACE    Repository root. Defaults to the current directory.
#   GITHUB_OUTPUT       File the step outputs are written to. Defaults to stdout.

set -euo pipefail

# The oldest supported scan tool, and the oldest Ballerina that runs it.
MIN_TOOL_VERSION="0.12.0"
MIN_BALLERINA_VERSION="2201.13.0"

# The Central API 'bal tool pull scan' uses to pick the latest scan tool for a Ballerina version.
CENTRAL_TOOLS_URL="https://api.central.ballerina.io/2.0/registry/tools"
CENTRAL_PLATFORM="java21"

# The SonarQube platform plugin, published to GitHub Packages, which needs a token with
# read:packages. Older versions do not work with the supported scan tools.
MIN_SONAR_PLUGIN_VERSION="0.3.0"
SONAR_PLUGIN_URL="https://maven.pkg.github.com/ballerina-platform/sonar-ballerina/io/ballerina/sonar/sonar-platform-plugin/{version}/sonar-platform-plugin-{version}.jar"

# Known plugin versions, newest first: version, oldest scan tool it works with, first scan tool it
# is not known to work with, and the SHA-256 a download must match.
SONAR_PLUGINS="\
0.3.0 0.12.0 0.13.0 b1e962ecc2e5337d92f7a8043089f40e1f284f2133328835d6c4987322ea98a5
"

# Prints the SHA-256 of platform plugin version $1, failing when this release does not know it.
sonar_plugin_sha256() {
  awk -v v="$1" '$1 == v { print $4; found = 1 } END { exit !found }' <<< "$SONAR_PLUGINS"
}

# Prints whether plugin version $1 works with scan tool version $2: supported, too-old (the tool is
# older than the plugin needs), untested (newer than it is known to work with) or unknown.
sonar_plugin_support() {
  local plugin tool below
  while read -r plugin tool below _; do
    [ "$plugin" = "$1" ] || continue
    if ! version_ge "$2" "$tool"; then
      echo too-old
    elif version_ge "$2" "$below"; then
      echo untested
    else
      echo supported
    fi
    return
  done <<< "$SONAR_PLUGINS"
  echo unknown
}

# Prints the newest known plugin version that works with scan tool version $1, if any.
sonar_plugin_for_tool() {
  local plugin
  while read -r plugin _; do
    [ -n "$plugin" ] || continue
    if [ "$(sonar_plugin_support "$plugin" "$1")" = supported ]; then
      printf '%s' "$plugin"
      return
    fi
  done <<< "$SONAR_PLUGINS"
}

# Prints the newest platform plugin version this release knows.
newest_sonar_plugin() {
  awk 'NF { print $1; exit }' <<< "$SONAR_PLUGINS"
}

# The SonarScanner CLI an action release pins, with the SHA-256 of each distribution. Each one
# bundles its own Java runtime.
PINNED_SONAR_SCANNER_VERSION="8.1.0.6389"
sonar_scanner_sha256() {
  case "$1" in
    linux-x64) echo bb8f709f9cb73352f8d1260a3b3c506c0f41146754bc630762c126d795499d0b ;;
    linux-aarch64) echo 5e1c9328f4e261838de778c9e586ee608cca45ff7f0538108642219214628ba5 ;;
    windows-x64) echo 73f0e71928673d5b2f39bb86213342a30e51a14c8eec345164016bb29c8df8ee ;;
    macosx-x64) echo 8afc8bbff9008434e53b31cb681333ff643b999f84ca537db573d0fae8883cdc ;;
    macosx-aarch64) echo 20d12be4081896b337cd873d98ebd3d554be666086a45e31dd84a12ef51c3688 ;;
    *) return 1 ;;
  esac
}

# The mikefarah/yq an action release installs when the runner has no yq v4, as on GitHub-hosted
# Windows runners, with the SHA-256 of each binary.
PINNED_YQ_VERSION="4.54.1"
yq_sha256() {
  case "$1" in
    linux_amd64) echo 8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f ;;
    linux_arm64) echo 189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b ;;
    darwin_amd64) echo 3a812fce205a4d67014fb71b7fa297092210e580df3d8f52dddc2cf3a599c22b ;;
    darwin_arm64) echo fee511a181bd8b3e6b7da98842b41973bfac8cd3bcd341ed29a584620b5b2844 ;;
    windows_amd64) echo b645f47ebb3a0d2fbab52998550bbd0a1706f23b5ca5f5b48e638c580bb70928 ;;
    windows_arm64) echo c46a295a98c31173e72220da7c35f86fbcc1c2cd2da5188105f326b32585e984 ;;
    *) return 1 ;;
  esac
}

KNOWN_PLATFORMS=(github-code-scanning sonarqube)

# jq on Windows ends lines with CRLF, which 'read' keeps. JSON escapes CRs inside strings, so
# dropping every CR is safe; pipefail keeps jq's exit code.
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  jq() { command jq "$@" | tr -d '\r'; }
fi

# GitHub workflow commands. Values are escaped so that they cannot inject other commands. common.jq
# has the same escaping for the annotations that report.sh writes from jq.
escape_data() {
  local s="$1"
  s="${s//'%'/'%25'}"
  s="${s//$'\r'/'%0D'}"
  s="${s//$'\n'/'%0A'}"
  printf '%s' "$s"
}

escape_property() {
  local s
  s="$(escape_data "$1")"
  s="${s//':'/'%3A'}"
  s="${s//','/'%2C'}"
  printf '%s' "$s"
}

log_error() { echo "::error title=bal scan ($(escape_property "${CATEGORY:-bal-scan}"))::$(escape_data "$1")"; }
log_warning() { echo "::warning title=bal scan ($(escape_property "${CATEGORY:-bal-scan}"))::$(escape_data "$1")"; }
log_notice() { echo "::notice title=bal scan ($(escape_property "${CATEGORY:-bal-scan}"))::$(escape_data "$1")"; }

die() {
  log_error "$1"
  exit 1
}

# Writes a step output. Multi-line values use the heredoc form.
set_output() {
  local name="$1" value="$2" out="${GITHUB_OUTPUT:-/dev/stdout}"
  if [[ "$value" == *$'\n'* ]]; then
    local delim="EOF_$RANDOM$RANDOM"
    printf '%s<<%s\n%s\n%s\n' "$name" "$delim" "$value" "$delim" >> "$out"
  else
    printf '%s=%s\n' "$name" "$value" >> "$out"
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# The category in a form safe for file names, such as the work directory and the SARIF file.
safe_category() {
  tr -c 'A-Za-z0-9._-' '_' <<< "$(trim "${CATEGORY:-bal-scan}")" | sed 's/_$//'
}

# Splits a newline or comma separated list into one trimmed, non-empty item per line.
split_list() {
  local item
  tr ',' '\n' <<< "$1" | tr -d '\r' | while IFS= read -r item || [ -n "$item" ]; do
    item="$(trim "$item")"
    [ -n "$item" ] && printf '%s\n' "$item"
  done
  return 0
}

require_command() {
  command -v "$1" > /dev/null 2>&1 || die "'$1' is required on the runner but was not found on the path. $2"
}

# Converts a Windows path to the form bash uses, so paths can be compared on every runner.
to_unix_path() {
  if [ -n "$1" ] && command -v cygpath > /dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s' "$1"
  fi
}

workspace_root() {
  local root
  root="$(to_unix_path "${GITHUB_WORKSPACE:-$PWD}")"
  (cd "$root" && pwd -P)
}

# Prints the path of an existing directory relative to the repository root, "." for the root
# itself. Fails when the directory is outside the repository.
repo_relative_dir() {
  local root abs
  root="$(workspace_root)"
  abs="$(cd "$root" && cd "$1" && pwd -P)" || return 1
  if [ "$abs" = "$root" ]; then
    printf '.'
  elif [[ "$abs" == "$root"/* ]]; then
    printf '%s' "${abs#"$root"/}"
  else
    return 1
  fi
}

# Runs the bal command. On Windows runners it is bal.bat, which bash does not find as "bal".
bal_cmd() {
  if command -v bal > /dev/null 2>&1; then
    bal "$@"
  else
    bal.bat "$@"
  fi
}

has_bal() {
  command -v bal > /dev/null 2>&1 || command -v bal.bat > /dev/null 2>&1
}

# Prints the version of the bal on the path, such as 2201.13.5, or nothing when it cannot be read.
bal_version() {
  bal_cmd version 2> /dev/null | tr -d '\r' | sed -n 's/^Ballerina \([0-9][^ ]*\).*/\1/p' | head -n1
}

# Succeeds when the bal on the path can be used for ballerina-version $1: latest, a version, or a
# prefix of one, such as 2201.13.
bal_matches() {
  local current
  has_bal || return 1
  current="$(bal_version)"
  [ -n "$current" ] || return 1
  if [ "$1" = latest ]; then
    version_ge "$current" "$MIN_BALLERINA_VERSION"
  else
    [ "$current" = "$1" ] || [[ "$current" == "$1".* ]]
  fi
}

# Removes the Ballerina distributions installed from .deb packages. Each version is its own package
# but installs into /usr/lib/ballerina, so dpkg refuses to install another version over it.
# Remove once setup-ballerina does this: https://github.com/ballerina-platform/setup-ballerina/issues/23
remove_ballerina_debs() {
  local pkgs sudo=sudo
  command -v dpkg-query > /dev/null 2>&1 || return 0
  # shellcheck disable=SC2016
  pkgs="$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 'ballerina-*' 2> /dev/null \
    | awk '$2 == "installed" { print $1 }')" || true
  [ -n "$pkgs" ] || return 0
  [ "$(id -u)" -eq 0 ] && sudo=""
  echo "Removing the installed Ballerina packages: ${pkgs//$'\n'/ }"
  # shellcheck disable=SC2086
  $sudo dpkg --remove $pkgs
}

has_command() {
  command -v "$1" > /dev/null 2>&1 || command -v "$1.bat" > /dev/null 2>&1 || command -v "$1.cmd" > /dev/null 2>&1
}

# Succeeds when version $1 is greater than or equal to version $2. A suffix such as -alpha marks a
# pre-release, which is lower than its release.
version_ge() {
  local na nb sa sb a b i
  na="$(sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/' <<< "$1")"
  nb="$(sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/' <<< "$2")"
  sa="${1#"$na"}"
  sb="${2#"$nb"}"
  IFS=. read -ra a <<< "$na"
  IFS=. read -ra b <<< "$nb"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  [ -z "$sa" ] && return 0
  [ -z "$sb" ] && return 1
  [[ ! "$sa" < "$sb" ]]
}

# Parses the platform-config input (YAML or JSON) and prints it as compact JSON, "{}" when empty.
# Fails without printing anything when it is not valid YAML, since the parser's error can quote
# credentials.
platform_config_json() {
  if [ -z "$(trim "${PLATFORM_CONFIG:-}")" ]; then
    echo '{}'
    return
  fi
  local json
  json="$(yq -p yaml -o json -I0 '.' <<< "$PLATFORM_CONFIG" 2> /dev/null)" || return 1
  [ -z "$json" ] || [ "$json" = "null" ] && json='{}'
  printf '%s' "$json"
}

INVALID_PLATFORM_CONFIG="platform-config is not valid YAML. Give a mapping keyed by platform, such as 'sonarqube:'."

# Prints the [scan] table of a package's Ballerina.toml as JSON, "null" when it has none or the
# file cannot be read, in which case bal scan reports the problem. $1 is the package directory.
scan_table() {
  local json
  json="$(yq -p toml -o json -I0 '.scan' "$1/Ballerina.toml" 2> /dev/null)" || json=null
  printf '%s' "${json:-null}"
}

# Resolves a [scan] configPath of package $1: absolute, or relative to the package.
resolve_config_path() {
  if is_absolute_path "$2"; then
    printf '%s' "$(to_unix_path "$2")"
  else
    printf '%s' "$1/$(to_unix_path "$2")"
  fi
}

# bal scan reads Scan.toml from the package root, or from [scan] configPath in Ballerina.toml when
# the table is there. It treats a configPath that is not an existing file as a URL to download,
# and a [scan] table without configPath as an error. find-packages.sh checks each package's
# setting and downloads a remote Scan.toml into the work directory, so the scripts after it read
# and change that copy. It resolves the setting once per package, with scan_config_info, and
# keeps it in units.json for the scripts after it.

# Prints [scan] configPath of a [scan] table given as JSON, empty when it is not set.
config_path_of() {
  jq -r 'if type == "object" and (.configPath | type) == "string" then .configPath else "" end' <<< "$1"
}

# Prints [scan] configPath of package $1, empty when it is not set. Parses Ballerina.toml again, so
# it sees changes made since units.json was written.
scan_config_value() {
  config_path_of "$(scan_table "$1")"
}

# Prints the work-directory copy of a remote Scan.toml, one per URL.
remote_scan_toml_file() {
  printf '%s/remote-scan-toml/%s.toml' "${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}" \
    "$(printf '%s' "$1" | sha256_of /dev/stdin | cut -c1-16)"
}

# Prints the Scan.toml setting of package $1 as JSON, parsing its Ballerina.toml once:
#   table      whether Ballerina.toml has a [scan] table
#   config     its configPath, empty when it is not set
#   url        the URL the package reads its Scan.toml from, empty when the file is local or there
#              is none
#   scan-toml  the Scan.toml file the scan reads, empty when there is none: the work-directory
#              copy for a remote file
scan_config_info() {
  local pkg="$1" table config url="" file=""
  table="$(scan_table "$pkg")"
  config="$(config_path_of "$table")"
  if [[ "$config" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] && [ ! -f "$(resolve_config_path "$pkg" "$config")" ]; then
    url="$config"
    file="$(remote_scan_toml_file "$url")"
  elif [ -n "$config" ]; then
    file="$(resolve_config_path "$pkg" "$config")"
  elif [ -f "$pkg/Scan.toml" ]; then
    file="$pkg/Scan.toml"
  fi
  jq -nc --arg path "$pkg" --argjson table "$([ "$table" != null ] && echo true || echo false)" \
    --arg config "$config" --arg url "$url" --arg file "$file" \
    '{path: $path, table: $table, config: $config, url: $url, "scan-toml": $file}'
}

# Sets SCAN_PKG, SCAN_CONFIG, SCAN_URL and SCAN_TOML from the scan_config_info JSON in $1.
read_scan_config() {
  { IFS= read -r SCAN_PKG; IFS= read -r SCAN_CONFIG; IFS= read -r SCAN_URL; IFS= read -r SCAN_TOML; } \
    < <(jq -r '.path // "", .config // "", .url // "", ."scan-toml" // ""' <<< "$1")
}

# Prints the scan_config_info of package $2 kept in unit $1 of units.json, {} when there is none.
unit_scan_config() {
  jq -c --arg p "$2" '[."scan-config" // [] | .[] | select(.path == $p)] | first // {}' <<< "$1"
}

# Prints a Ballerina.toml ($1) with the configPath of its [scan] table set to $2. Only a
# 'configPath = ...' line directly under [scan] is changed, so callers check the result.
with_config_path() {
  awk -v path="$2" '
    /^[[:space:]]*\[/ { inscan = ($0 ~ /^[[:space:]]*\[[[:space:]]*scan[[:space:]]*\][[:space:]]*(#.*)?\r?$/) }
    inscan && /^[[:space:]]*configPath[[:space:]]*=/ { print "configPath = \"" path "\""; next }
    { print }
  ' "$1"
}

# Prints the [[platform]] entries of a Scan.toml file as a JSON array.
scan_toml_platforms() {
  local json
  json="$(yq -p toml -o json -I0 '.platform // []' "$1" 2> /dev/null)" || return 1
  printf '%s' "$json"
}

# Reads a key from a Java properties file. Handles '=' and ':' separators and surrounding spaces.
read_property() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    { sub(/\r$/, "") }
    /^[ \t]*[#!]/ { next }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (match(line, /[ \t]*[=:][ \t]*/)) {
        k = substr(line, 1, RSTART - 1)
        v = substr(line, RSTART + RLENGTH)
        if (k == key) { value = v }
      }
    }
    END { if (value != "") print value }
  ' "$file"
}

# Converts a path to the form the runner's native programs, such as bal and Java, read. On Windows
# runners that is C:/..., which TOML and JSON strings take without escaping.
to_native_path() {
  if [ -n "$1" ] && command -v cygpath > /dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

# Succeeds when a path is absolute, on any runner.
is_absolute_path() {
  [[ "$1" = /* || "$1" =~ ^[A-Za-z]:[/\\] ]]
}

# Prints the SHA-256 of a file.
sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Downloads an https URL to a file, which is left untouched when the download fails. Further
# arguments go to curl.
download() {
  local url="$1" out="$2" tmp
  shift 2
  tmp="$(mktemp "$out.XXXXXX")"
  if curl -fsSL --proto '=https' --retry 3 "$@" -o "$tmp" "$url"; then
    mv "$tmp" "$out"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Cache shared by every run of the action in a job, so tools are downloaded only once.
tool_cache_dir() {
  local dir
  dir="$(to_unix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")/scan-ballerina-tools"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# Prints a Scan.toml without its [[platform]] entries ("all", or only "sonarqube") and their sub-tables,
# keeping the rest byte for byte. Other forms are missed, so callers check with scan_toml_platforms.
drop_platforms() {
  awk -v mode="$1" '
    function flush() { if (!drop) printf "%s", buf; buf = ""; drop = 0; inplat = 0 }
    /^[[:space:]]*\[/ {
      if ($0 ~ /^[[:space:]]*\[\[[[:space:]]*platform[[:space:]]*\]\]/) {
        if (inplat) flush()
        inplat = 1; insub = 0; drop = (mode == "all")
      } else if ($0 ~ /^[[:space:]]*\[\[?[[:space:]]*platform[[:space:]]*\./) {
        if (!inplat) { inplat = 1; drop = (mode == "all") }
        insub = 1
      } else if (inplat) {
        flush()
      }
    }
    inplat {
      buf = buf $0 "\n"
      if (!insub && mode == "sonarqube" && $0 ~ /^[[:space:]]*name[[:space:]]*=[[:space:]]*["\047]sonarqube["\047]/) drop = 1
      next
    }
    { print }
    END { if (inplat) flush() }
  '
}

# Prints why the [[platform]] entries of a Scan.toml file ($1) cannot be hidden, or nothing when
# they can or the file is not valid TOML, which bal scan reports itself. $2 is the name to use in
# the message, such as the URL of a remote file.
platform_form_problem() {
  local file="$1" name="$2" left
  scan_toml_platforms "$file" > /dev/null || return 0
  if ! left="$(drop_platforms all < "$file" | yq -p toml -o json -I0 '.platform // [] | length' 2> /dev/null)"; then
    echo "'$name' cannot have its [[platform]] entries hidden without breaking the file, for example because a multi-line string holds a line that starts with '['. Move such values out of the file."
  elif [ "$(tr -d '\r' <<< "$left")" != 0 ]; then
    echo "'$name' has [[platform]] entries in a form the action cannot hide, such as an array of inline tables. Write each entry as a [[platform]] table."
  fi
  return 0
}

# Kept in the git directory so a later run can restore files a stopped run left changed, while git
# status and git clean ignore it. Falls back to the work directory outside a git repository.
journal_dir() {
  local dir
  # --absolute-git-dir is the git directory of the worktree, and works with git 2.13 or later.
  if dir="$(git -C "$(workspace_root)" rev-parse --absolute-git-dir 2> /dev/null)" && [ -n "$dir" ]; then
    dir="${dir%$'\r'}/scan-ballerina"
  else
    dir="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}/journal"
  fi
  to_unix_path "$dir"
}

JOURNAL=""
journal_init() {
  JOURNAL="$(journal_dir)"
  mkdir -p "$JOURNAL"
  touch "$JOURNAL/manifest.tsv"
}

# Keeps path $1 as it is now until restore_files runs: an existing file is copied to the journal
# and copied back byte for byte, and a path that does not exist yet is deleted. An existing
# directory is left as it is. $2 is the SHA-256 of what the action is about to write to the path,
# empty when another program writes it, such as SonarScanner.
protect() {
  local path="$1" written="${2:-}" backup=""
  [ -d "$path" ] && return 0
  if [ -e "$path" ]; then
    backup="$(mktemp "$JOURNAL/backup.XXXXXX")"
    cp "$path" "$backup"
  fi
  # Empty fields are written as "-", since read joins consecutive tabs.
  printf '%s\t%s\t%s\n' "$path" "${backup:--}" "${written:--}" >> "$JOURNAL/manifest.tsv"
}

# Reads one journal line into original, backup and written, with "-" read back as empty.
read_journal_line() {
  IFS=$'\t' read -r original backup written || return 1
  [ "$backup" != - ] || backup=""
  [ "$written" != - ] || written=""
}

# Restores every path in the journal of this run.
restore_files() {
  local original backup written
  [ -n "$JOURNAL" ] && [ -f "$JOURNAL/manifest.tsv" ] || return 0
  while read_journal_line; do
    [ -n "$original" ] || continue
    if [ -n "$backup" ]; then
      cp "$backup" "$original" && rm -f "$backup"
    else
      rm -rf "$original"
    fi
  done < "$JOURNAL/manifest.tsv"
  : > "$JOURNAL/manifest.tsv"
}

# Restores the files an earlier run left changed because it stopped before restoring them. A file
# the action wrote is restored only while it still holds what the action wrote, so a change made
# since, such as by a checkout, is kept. Paths are relative to the repository root.
recover_files() {
  local journal original backup written current
  journal="$(journal_dir)"
  [ -s "$journal/manifest.tsv" ] || return 0
  log_warning "An earlier run of the action stopped before it restored the files it changed during a scan, for example because it was cancelled. Restoring them now."
  while read_journal_line; do
    [ -n "$original" ] || continue
    current=""
    [ -f "$original" ] && current="$(sha256_of "$original")"
    if [ -n "$written" ] && [ "$current" != "$written" ]; then
      # Either the change never happened, or the file changed again since.
      if [ -n "$current" ] && [ -n "$backup" ] && [ -f "$backup" ] && [ "$current" = "$(sha256_of "$backup")" ]; then
        continue
      fi
      [ -z "$current" ] && [ -z "$backup" ] && continue
      log_warning "Left '$original' as it is, since it changed after the earlier run changed it."
    elif [ -n "$backup" ] && [ -f "$backup" ]; then
      cp "$backup" "$original"
      echo "Restored $original"
    elif [ -z "$backup" ] && [ -e "$original" ]; then
      rm -rf "$original"
      echo "Deleted $original, which the earlier run created"
    fi
  done < "$journal/manifest.tsv"
  rm -rf "$journal"
}
