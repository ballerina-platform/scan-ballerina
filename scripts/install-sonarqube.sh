#!/usr/bin/env bash
# Step 5 (sonarqube only): downloads the platform plugin each package resolved to, and the SonarScanner
# CLI. Both are kept in a cache shared by every run of the action in the job, so they are downloaded
# only once.
#
# The SonarScanner distribution for the runner's operating system bundles its own Java runtime, so
# the job needs no Java or scanner setup step. Its checksum is verified against the one this
# release pins, and so is the checksum of a platform plugin version this release knows.
#
# The default plugin, and any plugin-version, is checked against the installed scan tool.
#
# Inputs (environment): SCAN_WORK_DIR, SCAN_TOOL_VERSION (the installed scan tool), GITHUB_TOKEN
# (reads the plugin from GitHub Packages), CATEGORY.
# Writes: "plugin-file", and the resolved default plugin, into each item of
# $SCAN_WORK_DIR/sonarqube.json.
# Outputs: scanner-bin, the directory to put on the path of the scan process.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
TOOL="${SCAN_TOOL_VERSION:?SCAN_TOOL_VERSION is not set}"
ROOT="$(workspace_root)"
CACHE="$(tool_cache_dir)"

# Downloads from GitHub Packages, which needs a token with read:packages even for public packages.
download_package() {
  download "$1" "$2" -H "Authorization: Bearer ${GITHUB_TOKEN:-}"
}

PACKAGES_HINT="The plugin is published to GitHub Packages, which needs a token with read:packages: give the job 'packages: read' permission, or pass github-token. You can also set plugin-path to a JAR in the repository or an https URL."

# Prints the newest known plugin version that works with the installed scan tool, or the newest
# known one with a warning. Runs in a subshell, so messages go to stderr.
default_plugin_version() {
  local version
  version="$(sonar_plugin_for_tool "$TOOL")"
  if [ -z "$version" ]; then
    version="$(newest_sonar_plugin)"
    [ "$(sonar_plugin_support "$version" "$TOOL")" = untested ] \
      || die "This release of the action knows no SonarQube platform plugin that works with bal scan $TOOL. Set plugin-version or plugin-path." >&2
    log_warning "This release of the action knows no SonarQube platform plugin for bal scan $TOOL, so version $version, made for an older scan tool, is used. Set plugin-version or plugin-path to use another plugin, or tool-version to pin the scan tool." >&2
  fi
  echo "SonarQube platform plugin for bal scan $TOOL: $version" >&2
  printf '%s' "$version"
}

# Fails or warns when a known plugin version does not work with the installed scan tool.
check_plugin_version() {
  local version="$1" newest
  newest="$(sonar_plugin_for_tool "$TOOL")"
  case "$(sonar_plugin_support "$version" "$TOOL")" in
    too-old)
      die "Version $version of the SonarQube platform plugin needs a later scan tool than bal scan $TOOL. Leave plugin-version out to use the newest plugin that works with bal scan $TOOL, or set tool-version to a later scan tool." >&2
      ;;
    untested)
      if [ -n "$newest" ]; then
        die "Version $version of the SonarQube platform plugin does not work with bal scan $TOOL, which needs version $newest. Set plugin-version to $newest, or leave it out to use it." >&2
      fi
      log_warning "Version $version of the SonarQube platform plugin is not known to work with bal scan $TOOL, which is newer than this release of the action knows. Set tool-version to pin the scan tool if the scan fails." >&2
      ;;
  esac
}

# Prints the cached JAR of a plugin version, downloading it when needed. $2 is true when it was
# already checked against the scan tool. Runs in a subshell, so errors go to stderr.
plugin_version_file() {
  local version="$1" checked="${2:-false}"
  if [ "$version" = latest ]; then
    local base="${SONAR_PLUGIN_URL%%/\{version\}*}" metadata="$CACHE/sonar-platform-plugin-metadata.xml"
    download_package "$base/maven-metadata.xml" "$metadata" \
      || die "Could not read the latest SonarQube platform plugin version. $PACKAGES_HINT" >&2
    version="$(sed -n 's:.*<release>\(.*\)</release>.*:\1:p' "$metadata" | head -n1)"
    [ -n "$version" ] || version="$(sed -n 's:.*<latest>\(.*\)</latest>.*:\1:p' "$metadata" | head -n1)"
    [ -n "$version" ] || die "Could not read the latest SonarQube platform plugin version from GitHub Packages." >&2
    echo "Latest SonarQube platform plugin: $version" >&2
  fi
  local file="$CACHE/sonar-platform-plugin-$version.jar" expected actual
  if [ ! -f "$file" ]; then
    download_package "${SONAR_PLUGIN_URL//\{version\}/$version}" "$file" \
      || die "Could not download version $version of the SonarQube platform plugin. $PACKAGES_HINT" >&2
  fi
  # The plugin runs with the SonarQube token, so a version this release knows must match its
  # pinned checksum, also when it comes from the cache.
  if expected="$(sonar_plugin_sha256 "$version")"; then
    actual="$(sha256_of "$file")"
    if [ "$actual" != "$expected" ]; then
      rm -f "$file"
      die "Version $version of the SonarQube platform plugin has the SHA-256 $actual, but $expected was expected." >&2
    fi
    [ "$checked" = true ] || check_plugin_version "$version"
  else
    log_warning "This release of the action does not know version $version of the SonarQube platform plugin, so neither the download nor whether it works with bal scan $TOOL is verified. Leave plugin-version out to use a verified version that works with the scan tool." >&2
  fi
  printf '%s' "$file"
}

# Prints the cached JAR of a plugin URL, downloading it when it is not cached yet.
plugin_url_file() {
  local url="$1" file
  file="$CACHE/sonar-platform-plugin-$(printf '%s' "$url" | sha256_of /dev/stdin | cut -c1-16).jar"
  if [ ! -f "$file" ]; then
    download "$url" "$file" || die "Could not download the SonarQube platform plugin from '$url'." >&2
  fi
  log_warning "The SonarQube platform plugin from '$url' runs with the SonarQube token, but has no checksum to verify it against. Use plugin-version, or a plugin-path to a JAR in the repository, to run a verified plugin." >&2
  printf '%s' "$file"
}

echo "::group::Install the SonarQube platform plugin"
UPDATED='[]'
while IFS= read -r settings; do
  kind="$(jq -r '.plugin.kind' <<< "$settings")"
  value="$(jq -r '.plugin.value' <<< "$settings")"
  case "$kind" in
    default)
      value="$(default_plugin_version)"
      settings="$(jq -c --arg v "$value" '.plugin = {kind: "version", value: $v}' <<< "$settings")"
      file="$(plugin_version_file "$value" true)"
      ;;
    version) file="$(plugin_version_file "$value")" ;;
    url) file="$(plugin_url_file "$value")" ;;
    file) file="$ROOT/$value" ;;
    *) die "Package '$(jq -r '.package' <<< "$settings")' resolved to an unknown kind of platform plugin, '$kind'." ;;
  esac
  echo "$(jq -r '.package' <<< "$settings"): $file"
  UPDATED="$(jq -c --argjson s "$settings" --arg f "$file" '. + [$s + {"plugin-file": $f}]' <<< "$UPDATED")"
done < <(jq -c '.[]' "$WORK/sonarqube.json")
printf '%s\n' "$UPDATED" > "$WORK/sonarqube.json"
echo "::endgroup::"

# SonarScanner
case "${RUNNER_OS:-$(uname -s)}" in
  Linux) OS=linux ;;
  macOS | Darwin) OS=macosx ;;
  Windows | MINGW* | MSYS* | CYGWIN*) OS=windows ;;
  *) die "SonarQube reporting does not support the runner's operating system, ${RUNNER_OS:-$(uname -s)}." ;;
esac
case "${RUNNER_ARCH:-$(uname -m)}" in
  ARM64 | arm64 | aarch64) ARCH=aarch64 ;;
  *) ARCH=x64 ;;
esac
# SonarSource publishes Windows for x64 only, which ARM64 Windows runs emulated.
[ "$OS" = windows ] && ARCH=x64
DIST="$OS-$ARCH"
VERSION="$PINNED_SONAR_SCANNER_VERSION"
EXPECTED="$(sonar_scanner_sha256 "$DIST")" || die "No SonarScanner distribution is pinned for $DIST."
DIR="$CACHE/sonar-scanner-$VERSION-$DIST"

if [ ! -d "$DIR" ]; then
  echo "::group::Install SonarScanner $VERSION ($DIST)"
  ZIP="$CACHE/sonar-scanner-cli-$VERSION-$DIST.zip"
  download "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-$VERSION-$DIST.zip" "$ZIP" \
    || die "Could not download SonarScanner $VERSION for $DIST."
  ACTUAL="$(sha256_of "$ZIP")"
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    rm -f "$ZIP"
    die "The SonarScanner $VERSION download for $DIST has the SHA-256 $ACTUAL, but $EXPECTED was expected."
  fi
  EXTRACT="$(mktemp -d "$CACHE/sonar-scanner-extract.XXXXXX")"
  unzip -q "$ZIP" -d "$EXTRACT"
  rm -f "$ZIP"
  # The archive holds a single top-level directory.
  TOP="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  { [ -n "$TOP" ] && [ -d "$TOP/bin" ]; } || die "The SonarScanner $VERSION archive for $DIST has no bin directory."
  mv "$TOP" "$DIR"
  rm -rf "$EXTRACT"
  chmod +x "$DIR"/bin/* "$DIR"/jre/bin/* 2> /dev/null || true
  echo "::endgroup::"
fi

echo "Using SonarScanner $VERSION ($DIST)"
set_output scanner-bin "$DIR/bin"
