#!/usr/bin/env bash
# Step 9, for pull request runs whose token cannot read code scanning alerts (forks and Dependabot):
# warns at each @scan:Suppress annotation the pull request removes. Code scanning matches the
# findings it suppressed to their alerts dismissed on the default branch, so it shows nothing new
# for them, and dismiss-alerts.sh cannot list the alerts to tell. Read from the diff of the pull
# request's own changes, so it needs no token beyond reading the base repository. Every failure is a
# log line, so that it never fails the scan.
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
cd "$(workspace_root)" || exit 0
git rev-parse --git-dir > /dev/null 2>&1 || { echo "No Git checkout, so removed suppressions are not checked." && exit 0; }

# A shallow checkout lacks the commits it is compared with.
fetch_commit() {
  git cat-file -e "$1^{commit}" 2> /dev/null || git fetch --quiet --no-tags --depth=1 origin "$1"
}

# Only the pull request's own changes count, not those on the base branch since BASE. Against the
# first parent of the merge commit GitHub checks out by default, and otherwise against the fork
# point of the checked out commit. A commit object lists its parents even in a shallow checkout.
read -r -a PARENTS <<< "$(git cat-file -p HEAD 2> /dev/null | sed -n 's/^parent //p' | paste -sd ' ' -)"
if [ "${#PARENTS[@]}" -eq 2 ]; then
  FROM="${PARENTS[0]}"
  if ! fetch_commit "$FROM"; then
    echo "Could not fetch the base commit $FROM, so removed suppressions are not checked."
    exit 0
  fi
else
  if ! fetch_commit "$BASE"; then
    echo "Could not fetch the base commit $BASE, so removed suppressions are not checked."
    exit 0
  fi
  if ! FROM="$(git merge-base "$BASE" HEAD 2> /dev/null)"; then
    [ "$(git rev-parse --is-shallow-repository)" = true ] \
      && git fetch --quiet --no-tags --unshallow origin "$BASE" \
      && FROM="$(git merge-base "$BASE" HEAD 2> /dev/null)" \
      || { echo "Could not find where the pull request branched off $BASE, so removed suppressions are not checked." && exit 0; }
  fi
fi
if ! DIFF="$(git diff --no-color --no-ext-diff --unified=0 "$FROM" HEAD -- '*.bal')"; then
  echo "Could not compare with the base commit $FROM, so removed suppressions are not checked."
  exit 0
fi

# One line per removed annotation that is not added back in the same file: file, the line of the
# pull request's version where it was, and the annotation's first line. Annotations are matched by
# their rules, so one that is moved or has only its reason changed is not removed, and each removal
# of identical annotations counts. One spanning several lines is read up to its closing brace.
# A hunk that only removes lines gives the line before it, so the next one is where they were. A
# deleted file takes its findings with it.
REMOVED="$(awk '
  function norm(s) { gsub(/[ \t]+/, "", s); return s }
  function rules(s) { return match(s, /rules[ \t]*:[ \t]*\[[^]]*\]/) ? norm(substr(s, RSTART, RLENGTH)) : norm(s) }
  function depth(s,   o) { o = gsub(/\{/, "{", s); return o - gsub(/\}/, "}", s) }
  function finish(   k) {
    if (sign == "") return
    k = file SUBSEP rules(buf)
    if (sign == "-") { n++; key[n] = k; at[n] = start; first[n] = head } else added[k]++
    sign = ""
  }
  /^\+\+\+ / { finish(); file = ($0 == "+++ /dev/null") ? "" : substr($0, 7); next }
  /^--- / { finish(); next }
  /^@@ / { finish(); split($3, h, ","); line = substr(h[1], 2) + (h[2] == "0" ? 1 : 0); next }
  file == "" { next }
  sign != "" && substr($0, 1, 1) == sign { buf = buf " " substr($0, 2); open += depth(substr($0, 2)); if (open <= 0) finish(); next }
  { finish() }
  /^[-+]/ && /@scan:Suppress/ {
    sign = substr($0, 1, 1); head = substr($0, 2); gsub(/^[ \t]+|[ \t]+$/, "", head)
    buf = head; start = line; open = depth(head)
    if (open <= 0) finish()
    next
  }
  # The rules line of an annotation spanning several lines, whose other lines did not change.
  /^[-+]/ && match($0, /rules[ \t]*:[ \t]*\[[ \t]*"[^"]*:[^]]*\]/) {
    sign = substr($0, 1, 1); buf = substr($0, RSTART, RLENGTH); head = "@scan:Suppress {" buf "}"; start = line
    finish()
  }
  END {
    finish()
    for (i = 1; i <= n; i++) {
      if (added[key[i]] > 0) { added[key[i]]--; continue }
      split(key[i], p, SUBSEP)
      printf "%s\t%d\t%s\n", p[1], (at[i] > 0 ? at[i] : 1), first[i]
    }
  }' <<< "$DIFF" | sort)"

COUNT=0
while IFS=$'\t' read -r file line text; do
  [ -n "$file" ] || continue
  COUNT=$((COUNT + 1))
  log_file_warning "$file" "$line" "This pull request removes $text. Code scanning matches the findings it suppressed to their alerts dismissed on $BRANCH, so they are not shown as new here, and this run cannot read the alerts to check them. The action reopens the alerts when this change is merged."
done <<< "$REMOVED"
echo "@scan:Suppress annotations removed: $COUNT."
jq -n --argjson n "$COUNT" --arg branch "$BRANCH" '{removed: $n, branch: $branch}' > "$WORK/alerts.json"
