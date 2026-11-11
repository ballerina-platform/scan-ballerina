#!/usr/bin/env bash
# Step 9, for pull request runs whose token cannot read code scanning alerts (forks and Dependabot):
# warns at each @scan:Suppress annotation the pull request removes. Code scanning matches the
# findings it suppressed to their alerts dismissed on the default branch, so it shows nothing new
# for them, and dismiss-alerts.sh cannot list the alerts to tell. Read from the diff between the
# pull request's base commit and the checked out merge commit, so it needs no token beyond reading
# the base repository. Every failure is a log line, so that it never fails the scan.
#
# Inputs (environment): SCAN_WORK_DIR, GITHUB_EVENT_PATH, GITHUB_WORKSPACE, SUPPRESSIONS, CATEGORY.
# Writes: $SCAN_WORK_DIR/alerts.json, with removed (the number of annotations removed) and branch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
echo '{}' > "$WORK/alerts.json"
# With suppressions off no finding is suppressed, so removing an annotation changes nothing.
[ "$(bool_setting "${SUPPRESSIONS:-}")" = true ] || exit 0
BASE="$(jq -r '.pull_request.base.sha // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
BRANCH="$(jq -r '.repository.default_branch // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
[ -n "$BASE" ] && [ -n "$BRANCH" ] || exit 0
cd "${GITHUB_WORKSPACE:-.}" || exit 0
git rev-parse --git-dir > /dev/null 2>&1 || { echo "No Git checkout, so removed suppressions are not checked." && exit 0; }

# A shallow checkout of the merge commit lacks its base.
if ! git cat-file -e "$BASE^{commit}" 2> /dev/null \
  && ! git fetch --quiet --no-tags --depth=1 origin "$BASE"; then
  echo "Could not fetch the base commit $BASE, so removed suppressions are not checked."
  exit 0
fi
if ! DIFF="$(git diff --no-color --no-ext-diff --unified=0 "$BASE" HEAD -- '*.bal')"; then
  echo "Could not compare with the base commit $BASE, so removed suppressions are not checked."
  exit 0
fi

# One line per removed annotation that is not added back in the same file: file, the line of the
# pull request's version where it was, and the annotation.
# A hunk that only removes lines gives the line before it, so the next one is where they were. A
# deleted file takes its findings with it.
REMOVED="$(awk '
  /^\+\+\+ / { file = ($0 == "+++ /dev/null") ? "" : substr($0, 7); next }
  /^--- / { next }
  /^@@ / { split($3, n, ","); line = substr(n[1], 2) + (n[2] == "0" ? 1 : 0); next }
  file == "" { next }
  /^-/ && /@scan:Suppress/ { text = substr($0, 2); gsub(/^[ \t]+|[ \t]+$/, "", text); removed[file SUBSEP text] = line; next }
  /^\+/ && /@scan:Suppress/ { text = substr($0, 2); gsub(/^[ \t]+|[ \t]+$/, "", text); added[file SUBSEP text] = 1 }
  END {
    for (k in removed) if (!(k in added)) {
      split(k, p, SUBSEP)
      printf "%s\t%d\t%s\n", p[1], (removed[k] > 0 ? removed[k] : 1), p[2]
    }
  }' <<< "$DIFF" | sort)"

TITLE="bal scan ($(trim "${CATEGORY:-bal-scan}"))"
COUNT=0
while IFS=$'\t' read -r file line text; do
  [ -n "$file" ] || continue
  COUNT=$((COUNT + 1))
  # GitHub shows at most 10 warnings per step.
  [ "$COUNT" -le 10 ] || continue
  echo "::warning file=$(escape_property "$file"),line=$line,title=$(escape_property "$TITLE")::$(escape_data "This pull request removes $text. Code scanning matches the findings it suppressed to their alerts dismissed on $BRANCH, so they are not shown as new here, and this run cannot read the alerts to check them. The action reopens the alerts when this change is merged.")"
done <<< "$REMOVED"
echo "@scan:Suppress annotations removed: $COUNT."
jq -n --argjson n "$COUNT" --arg branch "$BRANCH" '{removed: $n, branch: $branch}' > "$WORK/alerts.json"
