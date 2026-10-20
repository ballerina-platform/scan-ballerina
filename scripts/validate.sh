#!/usr/bin/env bash
# Step 1: validates the inputs and creates the work directory. Needs only the inputs themselves,
# so it runs before packages are searched or anything but yq is downloaded.
#
# Inputs (environment): PLATFORMS, SCAN_PATHS, EXCLUDE_PATHS, EXCLUDE_TESTS, CATEGORY,
# INCLUDE_RULES, EXCLUDE_RULES, FAIL_ON_SEVERITY, MAX_FINDINGS, ANNOTATIONS, JOB_SUMMARY,
# ARTIFACTS, PLATFORM_CONFIG, BALLERINA_VERSION, TOOL_VERSION, MATRIX (the matrix as JSON).
# Outputs: work-dir, github-code-scanning, github-code-scanning-skipped, sonarqube,
# sonarqube-skipped, artifacts (true or false), artifact-name.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_command jq "It is preinstalled on GitHub-hosted runners."
require_command yq "Install mikefarah/yq v4, or run install-yq.sh first."

# Credentials first, so that nothing printed later can reveal them.
CONFIG="$(platform_config_json)" || die "$INVALID_PLATFORM_CONFIG"
jq -r '[.. | objects | .token? | select(type == "string" and . != "")] | .[]' <<< "$CONFIG" 2> /dev/null \
  | while IFS= read -r secret; do echo "::add-mask::$secret"; done

ERRORS=()
error() { ERRORS+=("$1"); }

one_of() {
  local value="$1"
  shift
  local v
  for v in "$@"; do [ "$value" = "$v" ] && return 0; done
  return 1
}

check_boolean() {
  one_of "$2" true false || error "$1 must be 'true' or 'false', got '$2'."
}

[ -n "$(trim "${CATEGORY-bal-scan}")" ] || error "category must not be empty."

# Platforms
SELECTED=()
while IFS= read -r p; do
  if one_of "$p" "${KNOWN_PLATFORMS[@]}"; then
    one_of "$p" "${SELECTED[@]+"${SELECTED[@]}"}" || SELECTED+=("$p")
  else
    error "platforms has an unknown platform '$p'. Accepted values: ${KNOWN_PLATFORMS[*]}."
  fi
done < <(split_list "${PLATFORMS:-}")
selected() { one_of "$1" "${SELECTED[@]+"${SELECTED[@]}"}"; }

# Paths
ROOT="$(workspace_root)"
PATH_COUNT=0
while IFS= read -r p; do
  PATH_COUNT=$((PATH_COUNT + 1))
  if ! (cd "$ROOT" && [ -e "$p" ]); then
    error "paths has '$p', which does not exist."
  elif ! (cd "$ROOT" && [ -d "$p" ]); then
    error "paths has '$p', which is not a directory. Give a package or a directory to search for packages."
  elif ! repo_relative_dir "$p" > /dev/null; then
    error "paths has '$p', which is outside the repository."
  fi
done < <(split_list "${SCAN_PATHS:-.}")
[ "$PATH_COUNT" -gt 0 ] || error "paths must name at least one path."

while IFS= read -r p; do
  is_absolute_path "$p" && error "exclude-paths has '$p'. Give globs relative to the repository root."
done < <(split_list "${EXCLUDE_PATHS:-}")

# Rules. bal scan rejects include and exclude rules together without writing a report.
INCLUDE="$(split_list "${INCLUDE_RULES:-}")"
EXCLUDE="$(split_list "${EXCLUDE_RULES:-}")"
if [ -n "$INCLUDE" ] && [ -n "$EXCLUDE" ]; then
  error "include-rules and exclude-rules cannot be used together. Set one of them."
fi
while IFS= read -r r; do
  [[ "$r" =~ ^[A-Za-z0-9_./-]+:[0-9]+$ ]] || error "'$r' is not a rule ID. Give IDs such as ballerina:1 or ballerina/crypto:1."
done < <(printf '%s\n%s\n' "$INCLUDE" "$EXCLUDE" | sed '/^$/d')

# Gate and reporting
FAIL_ON="$(tr '[:upper:]' '[:lower:]' <<< "$(trim "${FAIL_ON_SEVERITY:-none}")")"
one_of "$FAIL_ON" none low medium high \
  || error "fail-on-severity must be one of none, low, medium or high, got '${FAIL_ON_SEVERITY:-}'."
[[ "$(trim "${MAX_FINDINGS:-0}")" =~ ^[0-9]+$ ]] \
  || error "max-findings must be a whole number of 0 or more, got '${MAX_FINDINGS:-}'."
check_boolean exclude-tests "$(trim "${EXCLUDE_TESTS:-true}")"
check_boolean annotations "$(trim "${ANNOTATIONS:-false}")"
check_boolean job-summary "$(trim "${JOB_SUMMARY:-true}")"
ARTIFACTS="$(trim "${ARTIFACTS:-false}")"
check_boolean artifacts "$ARTIFACTS"

# Versions below the minimums fail before anything is installed. Whether a pair is compatible is
# checked when the scan tool is installed.
BALLERINA_VERSION="$(trim "${BALLERINA_VERSION:-latest}")"
if [[ ! "$BALLERINA_VERSION" =~ ^(latest|nightly.*|[0-9]+(\.[0-9]+)*([.-][A-Za-z0-9.-]+)?)$ ]]; then
  error "ballerina-version must be 'latest' or a version such as 2201.13.3, got '$BALLERINA_VERSION'."
elif [[ "$BALLERINA_VERSION" =~ ^[0-9] ]] && ! version_ge "$BALLERINA_VERSION" "$MIN_BALLERINA_VERSION"; then
  error "ballerina-version is $BALLERINA_VERSION, but bal scan $MIN_TOOL_VERSION and later need Ballerina $MIN_BALLERINA_VERSION or later. Set $MIN_BALLERINA_VERSION or later, or leave it out to use the latest Ballerina."
fi
TOOL_VERSION="$(trim "${TOOL_VERSION:-}")"
if [ -n "$TOOL_VERSION" ]; then
  if [[ ! "$TOOL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
    error "tool-version must be a version such as $MIN_TOOL_VERSION, got '$TOOL_VERSION'."
  elif ! version_ge "$TOOL_VERSION" "$MIN_TOOL_VERSION"; then
    error "tool-version is $TOOL_VERSION, but the oldest supported version is $MIN_TOOL_VERSION. Set $MIN_TOOL_VERSION or later, or leave it out to use the latest version compatible with the Ballerina version."
  fi
fi

# Platform configuration
if [ "$(jq -r 'type' <<< "$CONFIG")" != "object" ]; then
  error "platform-config must be a mapping keyed by platform, such as 'sonarqube:'."
  CONFIG='{}'
fi

while IFS= read -r p; do
  if ! one_of "$p" "${KNOWN_PLATFORMS[@]}"; then
    error "platform-config has an unknown platform '$p'. Accepted platforms: ${KNOWN_PLATFORMS[*]}."
  elif ! selected "$p"; then
    log_warning "platform-config has settings for '$p', which is not in platforms. They are ignored."
  fi
done < <(jq -r 'keys[]' <<< "$CONFIG")

# Prints one problem per line for the settings of the sonarqube platform.
sonarqube_schema_errors() {
  jq -r -L "$SCRIPT_DIR" '
    include "common";
    def scalar: type == "string" or type == "number";
    def check_fields($where; $allowed):
      (keys - $allowed)[] as $k
      | "\($where) has an unknown field \($k | @json). Accepted fields: \($allowed | join(", ")).";
    def check_scalars($where; $fields):
      $fields[] as $f
      | select(has($f) and .[$f] != null and (.[$f] | scalar | not))
      | "\($where).\($f) must be a string.";
    def str($f): .[$f] // "" | tostring;
    # Checks shared by the platform level and each packages item.
    def check_settings($where; $fields):
      check_fields($where; $fields),
      check_scalars($where; $fields - ["packages"]),
      (select(has("plugin-path") and has("plugin-version"))
        | "\($where) sets both plugin-path and plugin-version. Set one of them."),
      (select(str("host-url") != "" and (str("host-url") | test("^https://[^\\s/]+") | not))
        | "\($where).host-url must be an https URL, since the token is sent to it, got \(str("host-url") | @json)."),
      (select(str("plugin-version") != "" and (str("plugin-version") | test("^(latest|[0-9]+\\.[0-9]+\\.[0-9]+([.-][A-Za-z0-9.-]+)?)$") | not))
        | "\($where).plugin-version must be latest or a version such as 1.0.0, got \(str("plugin-version") | @json)."),
      (select(str("plugin-path") | test("^[a-zA-Z][a-zA-Z0-9+.-]*://") and (test("^https://") | not))
        | "\($where).plugin-path must be a path relative to the repository root or an https URL, got \(str("plugin-path") | @json).");
    ["plugin-path", "plugin-version", "properties-file", "host-url", "token", "project-key", "project-name"] as $fields
    | (.sonarqube // {}) as $s
    | if ($s | type) != "object" then "platform-config.sonarqube must be a mapping."
      else
        ($s | check_settings("platform-config.sonarqube"; $fields + ["packages"])),
        (if ($s.packages // []) | type != "array" then "platform-config.sonarqube.packages must be a list."
         else
           ($s.packages // [] | to_entries[]
             | "platform-config.sonarqube.packages[\(.key)]" as $w
             | .value
             | if type != "object" then "\($w) must be a mapping with a path."
               else
                 check_settings($w; ["path"] + $fields),
                 (select(str("path") == "") | "\($w).path is required."),
                 # A token is never sent to a server other than the one it was configured with.
                 (select(has("host-url") and (has("token") | not))
                   | "\($w) sets host-url, so it must also set token. The platform-level token is not sent to another server.")
               end),
           # Paths are compared as check-sonarqube.sh matches them, so "." and "./" are the same.
           # A missing path is reported as required above, not as a duplicate.
           ($s.packages // [] | map(select(type == "object") | str("path") | select(. != "") | package_path)
             | group_by(.)[] | select(length > 1)
             | "platform-config.sonarqube.packages has the path \(.[0] | @json) more than once.")
         end)
      end
  ' <<< "$CONFIG"
}

if jq -e 'has("github-code-scanning") and (.["github-code-scanning"] // {} | length > 0)' <<< "$CONFIG" > /dev/null; then
  error "platform-config.github-code-scanning takes no settings. It uses the github-token and category inputs."
fi

# Runs triggered by Dependabot, on any event, and pull requests from forks get no secrets and a
# read-only GITHUB_TOKEN. pull_request_target and workflow_run run in the base repository.
RESTRICTED=false
case "${GITHUB_EVENT_NAME:-}" in
  pull_request_target | workflow_run) ;;
  *)
    if [ "${GITHUB_ACTOR:-}" = "dependabot[bot]" ]; then
      RESTRICTED=true
    elif [ "${GITHUB_EVENT_NAME:-}" = pull_request ] && [ -f "${GITHUB_EVENT_PATH:-}" ] && jq -e \
      '.pull_request.head.repo.full_name != null and .pull_request.head.repo.full_name != .repository.full_name' \
      "$GITHUB_EVENT_PATH" > /dev/null 2>&1; then
      RESTRICTED=true
    fi
    ;;
esac

GCS=false
GCS_SKIPPED=false
if selected github-code-scanning; then
  GCS=true
  if [ "$RESTRICTED" = true ]; then
    log_warning "Skipping the upload to GitHub code scanning: pull requests from forks and Dependabot runs get a read-only GITHUB_TOKEN. The SARIF file is kept as the sarif-file output; save it with artifacts: true and upload it from a trusted workflow_run workflow."
    GCS=false
    GCS_SKIPPED=true
  fi
fi

SONARQUBE=false
if selected sonarqube; then
  while IFS= read -r e; do [ -n "$e" ] && error "$e"; done < <(sonarqube_schema_errors)
  # Each plugin-version, at the platform level and under packages. latest and malformed versions
  # are left to the checks above.
  while IFS=$'\t' read -r where v; do
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || continue
    version_ge "$v" "$MIN_SONAR_PLUGIN_VERSION" \
      || error "$where.plugin-version is $v, but the oldest supported version is $MIN_SONAR_PLUGIN_VERSION. Set $MIN_SONAR_PLUGIN_VERSION or later, or leave it out to use the newest plugin that works with the scan tool."
  done < <(jq -r '.sonarqube // {} | select(type == "object")
    | (["platform-config.sonarqube", ."plugin-version"]),
      (.packages // [] | select(type == "array") | to_entries[] | select(.value | type == "object")
        | ["platform-config.sonarqube.packages[\(.key)]", .value."plugin-version"])
    | select(.[1] != null) | map(tostring) | @tsv' <<< "$CONFIG")
  SONARQUBE=true
  # Every token field that is present, at the platform level and under packages. A secret that is
  # not available resolves to an empty value.
  EMPTY_TOKENS="$(jq -r '.sonarqube // {} | select(type == "object")
    | [(., (.packages // [] | select(type == "array") | .[] | select(type == "object")))
       | select(has("token") and ((.token // "") | tostring) == "")] | length' <<< "$CONFIG")"
  ANY_TOKEN="$(jq -r '[.sonarqube // {} | select(type == "object")
    | (., (.packages // [] | select(type == "array") | .[] | select(type == "object")))
    | .token // "" | tostring | select(. != "")] | length > 0' <<< "$CONFIG")"

  if [ "$RESTRICTED" = true ] && { [ "${EMPTY_TOKENS:-0}" -gt 0 ] || [ "$ANY_TOKEN" != true ]; }; then
    log_warning "Skipping sonarqube: secrets are not available to pull requests from forks or to Dependabot runs, so a SonarQube token is empty. The SARIF file is still produced."
    SONARQUBE=false
  elif [ "${EMPTY_TOKENS:-0}" -gt 0 ]; then
    error "platform-config.sonarqube has an empty token. Pass each token from a secret, such as token: \${{ secrets.SONAR_TOKEN }}, and check that the secret is set."
  fi
  if [ "$SONARQUBE" = true ]; then
    while IFS= read -r v; do
      [ -n "$v" ] && log_warning "platform-config.sonarqube sets plugin-version to latest, which may not match the scan tool. Pin a plugin version for reproducible runs."
    done < <(jq -r '.sonarqube | select(type == "object")
      | [(., (.packages // [] | select(type == "array") | .[] | select(type == "object")))
         | select(."plugin-version" == "latest")] | if length > 0 then "latest" else empty end' <<< "$CONFIG")
  fi
fi

if [ "${#ERRORS[@]}" -gt 0 ]; then
  for e in "${ERRORS[@]}"; do log_error "$e"; done
  exit 1
fi

# A work directory per run, so the action can run more than once in a job.
TEMP_ROOT="$(to_unix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")"
WORK="$(mktemp -d "$TEMP_ROOT/scan-ballerina-$(safe_category)-XXXXXX")"
# Artifact names keep the category as given, apart from the characters upload-artifact rejects, so
# that categories such as "a b" and "a_b" get different artifacts.
ARTIFACT_NAME="$(trim "${CATEGORY-bal-scan}")"
for c in '"' ':' '<' '>' '|' '*' '?' '\' '/' $'\r' $'\n'; do ARTIFACT_NAME="${ARTIFACT_NAME//"$c"/_}"; done
# Artifact names must be unique in the whole run, so the job, and a hash of the matrix values when
# there are any, tell apart jobs, and matrix jobs, that use the same category.
[ -z "${GITHUB_JOB:-}" ] || ARTIFACT_NAME="$ARTIFACT_NAME-$GITHUB_JOB"
case "${MATRIX:-}" in
  '' | null) ;;
  *) ARTIFACT_NAME="$ARTIFACT_NAME-$(printf '%s' "$MATRIX" | sha256_of /dev/stdin | cut -c1-8)" ;;
esac
mkdir -p "$WORK/reports" "$WORK/logs"

set_output work-dir "$WORK"
set_output github-code-scanning "$GCS"
set_output github-code-scanning-skipped "$GCS_SKIPPED"
set_output sonarqube "$SONARQUBE"
set_output sonarqube-skipped "$(selected sonarqube && [ "$SONARQUBE" = false ] && echo true || echo false)"
set_output artifacts "$ARTIFACTS"
set_output artifact-name "$ARTIFACT_NAME"
echo "Platforms: ${SELECTED[*]:-none (SARIF file only)}"
[ "$ARTIFACTS" = false ] || echo "Artifact: '$ARTIFACT_NAME', with the merged SARIF file"
