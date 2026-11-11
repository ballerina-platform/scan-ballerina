#!/usr/bin/env bash
# After the scan (sonarqube only): keys the SonarScanner cache of each server's analyzers by a hash
# of its file list, since saved cache keys cannot be overwritten. Each server has its own
# SONAR_USER_HOME, listed in $SCAN_WORK_DIR/sonar-caches.json by check-sonarqube.sh, and action.yml
# saves the one in slot N with the key-N output.
#
# Inputs (environment): SCAN_WORK_DIR, CATEGORY, and either SCAN_SUCCEEDED and RESTORED_KEY_N (the
# key action.yml restored for slot N, empty when none), or RECORD=true and SAVED_KEY_N (the key
# saved for slot N, empty when it was not saved) after the saves.
# Writes: <home>/cache-key, the key the Actions cache holds for the server, read by later uses in
# the job.
# Outputs: key-N, and save-N (true when the server's cache has files and differs from the one
# restored or saved), for each slot in use.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
[ -f "$WORK/sonar-caches.json" ] || exit 0

# SonarScanner never deletes an analyzer the server no longer has, such as the old version after a
# server upgrade, so the plugin folders the scan did not read are dropped before saving. Only after
# every SonarQube scan succeeded, and only when access times are tracked: at least one restored
# file must have been read, since a file downloaded during the scan says nothing about them.
# $1 is the cache folder and $2 the marker scan.sh created before the scan.
prune_unused() {
  local cache="$1" start="$2" dir name jar read_restored=false unused=()
  [ -f "$start" ] && [ "${SCAN_SUCCEEDED:-false}" = true ] || return 0
  [ ! -s "$WORK/sonarqube-failures.txt" ] || return 0
  for dir in "$cache"/*/; do
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
      [ -e "$jar" ] && rm -rf "$cache/_unzip/$(basename "$jar")_unzip"
    done
    rm -rf "$dir"
    echo "Dropped $(basename "$dir") from the SonarScanner cache, since the scan did not use it."
  done
}

# Keys the cache of the server in slot $1, whose SONAR_USER_HOME is $2, key prefix $3 and URL $4.
key_cache() {
  local slot="$1" home="$2" prefix="$3" url="$4" cache="$2/cache" held files key restored_var="RESTORED_KEY_$1"
  held="$(trim "${!restored_var:-}")"
  [ -n "$held" ] || [ ! -f "$home/cache-key" ] || held="$(cat "$home/cache-key")"
  prune_unused "$cache" "$home/cache-start"

  # Only cache/<hash>/<file>: the folders starting with "_" hold unzipped and temporary copies.
  files="$( (cd "$cache" 2> /dev/null && find . -mindepth 2 -maxdepth 2 -type f ! -path './_*' | LC_ALL=C sort) || true)"
  if [ -z "$files" ]; then
    echo "SonarScanner cached no files for $url, so there is nothing to save."
    set_output "save-$slot" false
    return 0
  fi
  key="$prefix$(printf '%s\n' "$files" | sha256_of /dev/stdin | cut -c1-16)"
  set_output "key-$slot" "$key"
  if [ "$key" = "$held" ]; then
    echo "The SonarScanner cache of $url is unchanged: $key"
    printf '%s' "$key" > "$home/cache-key"
    set_output "save-$slot" false
  else
    echo "The SonarScanner cache of $url changed, so it is saved as $key"
    # The unzipped and temporary copies are not in the key, and SonarScanner extracts them again.
    rm -rf "$cache"/_*
    set_output "save-$slot" true
  fi
}

while IFS=$'\t' read -r slot url home prefix; do
  [ "$slot" -le "$SONAR_CACHE_SLOTS" ] || continue
  if [ "${RECORD:-false}" = true ]; then
    saved_var="SAVED_KEY_$slot"
    [ -z "${!saved_var:-}" ] || printf '%s' "${!saved_var}" > "$home/cache-key"
  else
    key_cache "$slot" "$home" "$prefix" "$url"
  fi
done < <(jq -r '.[] | [.slot, .url, .home, .prefix] | @tsv' "$WORK/sonar-caches.json")
