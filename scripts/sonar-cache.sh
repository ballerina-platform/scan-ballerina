#!/usr/bin/env bash
# After the scan (sonarqube only): keys the SonarScanner cache of the servers' analyzers, which
# action.yml saves to the Actions cache. SonarScanner names each file it caches by its hash, so the
# key is a hash of the file list, and changes only when a server's analyzers do. Cache keys cannot
# be overwritten, so a fixed key would never pick up a server upgrade.
#
# Inputs (environment): SONAR_USER_HOME_DIR and SONAR_CACHE_PREFIX (outputs of check-sonarqube.sh),
# RESTORED_KEY (the key action.yml restored, empty when it restored none), CATEGORY.
# Writes: $SONAR_USER_HOME_DIR/cache-key, the key the cache holds, so that a later use of the
# action in the job, which skips the restore, does not save it again.
# Outputs: key, and save (true when the cache has files and differs from the one restored or saved).

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOME_DIR="$(to_unix_path "${SONAR_USER_HOME_DIR:?SONAR_USER_HOME_DIR is not set}")"
CACHE_DIR="$HOME_DIR/cache"
MARKER="$HOME_DIR/cache-key"

HELD="$(trim "${RESTORED_KEY:-}")"
[ -n "$HELD" ] || [ ! -f "$MARKER" ] || HELD="$(cat "$MARKER")"

# Only cache/<hash>/<file>: the folders starting with "_" hold unzipped and temporary copies.
FILES="$( (cd "$CACHE_DIR" 2> /dev/null && find . -mindepth 2 -maxdepth 2 -type f ! -path './_*' | LC_ALL=C sort) || true)"
if [ -z "$FILES" ]; then
  echo "SonarScanner cached no files, so there is nothing to save."
  set_output save false
  exit 0
fi

KEY="${SONAR_CACHE_PREFIX:?SONAR_CACHE_PREFIX is not set}$(printf '%s\n' "$FILES" | sha256_of /dev/stdin | cut -c1-16)"
printf '%s' "$KEY" > "$MARKER"
set_output key "$KEY"
if [ "$KEY" = "$HELD" ]; then
  echo "The SonarScanner cache is unchanged: $KEY"
  set_output save false
else
  echo "The SonarScanner cache changed, so it is saved as $KEY"
  set_output save true
fi
