#!/usr/bin/env bash
# Step 5 (sonarqube only): downloads the platform plugin each package resolved to, and the SonarScanner
# CLI. Both are kept in a cache shared by every run of the action in the job, so they are downloaded
# only once.
#
# The SonarScanner distribution for the runner's operating system bundles its own Java runtime, so
# the job needs no Java or scanner setup step. Its checksum is verified against the one this
# release pins, and so is the checksum of a platform plugin version this release knows.
#
# Inputs (environment): SCAN_WORK_DIR, GITHUB_TOKEN (reads the plugin from GitHub Packages),
# CATEGORY.
# Writes: "plugin-file" into each item of $SCAN_WORK_DIR/sonarqube.json.
# Outputs: scanner-bin, the directory to put on the path of the scan process.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
ROOT="$(workspace_root)"
CACHE="$(tool_cache_dir)"

# Downloads from GitHub Packages, which needs a token with read:packages even for public packages.
download_package() {
  download "$1" "$2" -H "Authorization: Bearer ${GITHUB_TOKEN:-}"
}

PACKAGES_HINT="The plugin is published to GitHub Packages, which needs a token with read:packages: give the job 'packages: read' permission, or pass github-token. You can also set plugin-path to a JAR in the repository or an https URL."

# Prints the cached JAR of a plugin version, downloading it when it is not cached yet. It runs in a
# subshell, so errors go to stderr.
plugin_version_file() {
  local version="$1"
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
  else
    log_warning "This release of the action has no checksum for version $version of the SonarQube platform plugin, so the download is not verified. Leave plugin-version out to use the pinned version $PINNED_SONAR_PLUGIN_VERSION, which is verified." >&2
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
