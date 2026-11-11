#!/usr/bin/env bash
# After the scan (sonarqube only): keys the SonarScanner cache of the servers' analyzers by a hash
# of its file list, since saved cache keys cannot be overwritten.
#
# Inputs (environment): SONAR_USER_HOME_DIR, CATEGORY, and either SONAR_CACHE_PREFIX, RESTORED_KEY
# (the key action.yml restored, empty when none), SCAN_WORK_DIR and SCAN_SUCCEEDED, or SAVED_KEY
# after a successful save.
# Writes: $SONAR_USER_HOME_DIR/cache-key, the key the Actions cache holds, read by later uses in the job.
# Outputs: key, and save (true when the cache has files and differs from the one restored or saved).

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOME_DIR="$(to_unix_path "${SONAR_USER_HOME_DIR:?SONAR_USER_HOME_DIR is not set}")"
CACHE_DIR="$HOME_DIR/cache"
MARKER="$HOME_DIR/cache-key"

if [ -n "${SAVED_KEY:-}" ]; then
  printf '%s' "$SAVED_KEY" > "$MARKER"
  exit 0
fi

HELD="$(trim "${RESTORED_KEY:-}")"
[ -n "$HELD" ] || [ ! -f "$MARKER" ] || HELD="$(cat "$MARKER")"

# SonarScanner never deletes an analyzer the server no longer has, such as the old version after a
# server upgrade, so the plugin folders the scan did not read are dropped before saving. Only after
# every SonarQube scan succeeded, and only when access times are tracked: at least one restored
# file must have been read, since a file downloaded during the scan says nothing about them.
prune_unused() {
  local start="${SCAN_WORK_DIR:-}/sonar-cache-start" dir name jar read_restored=false unused=()
  [ -n "${SCAN_WORK_DIR:-}" ] && [ -f "$start" ] && [ "${SCAN_SUCCEEDED:-false}" = true ] || return 0
  [ ! -s "$SCAN_WORK_DIR/sonarqube-failures.txt" ] || return 0
  for dir in "$CACHE_DIR"/*/; do
    dir="${dir%/}"
    name="$(basename "$dir")"
    [ "${name#_}" = "$name" ] || continue
    if [ -n "$(find "$dir" -maxdepth 1 -type f -anewer "$start" ! -newer "$start" | head -n 1)" ]; then
      read_restored=true
    elif [ -z "$(find "$dir" -maxdepth 1 -type f -anewer "$start" | head -n 1)" ] \
      && [ -z "$(find "$dir" -maxdepth 1 -type f ! -name '*.jar' | head -n 1)" ]; then
      # Plugin JARs only: the JRE archive is read only when its unzipped copy is missing.
      unused+=("$dir")
    fi
  done
  [ "$read_restored" = true ] || return 0
  for dir in "${unused[@]+"${unused[@]}"}"; do
    for jar in "$dir"/*.jar; do
      [ -e "$jar" ] && rm -rf "$CACHE_DIR/_unzip/$(basename "$jar")_unzip"
    done
    rm -rf "$dir"
    echo "Dropped $(basename "$dir") from the SonarScanner cache, since the scan did not use it."
  done
}
prune_unused

# Only cache/<hash>/<file>: the folders starting with "_" hold unzipped and temporary copies.
FILES="$( (cd "$CACHE_DIR" 2> /dev/null && find . -mindepth 2 -maxdepth 2 -type f ! -path './_*' | LC_ALL=C sort) || true)"
if [ -z "$FILES" ]; then
  echo "SonarScanner cached no files, so there is nothing to save."
  set_output save false
  exit 0
fi

KEY="${SONAR_CACHE_PREFIX:?SONAR_CACHE_PREFIX is not set}$(printf '%s\n' "$FILES" | sha256_of /dev/stdin | cut -c1-16)"
set_output key "$KEY"
if [ "$KEY" = "$HELD" ]; then
  echo "The SonarScanner cache is unchanged: $KEY"
  printf '%s' "$KEY" > "$MARKER"
  set_output save false
else
  echo "The SonarScanner cache changed, so it is saved as $KEY"
  # The unzipped and temporary copies are not in the key, and SonarScanner extracts them again.
  rm -rf "$CACHE_DIR"/_*
  set_output save true
fi
