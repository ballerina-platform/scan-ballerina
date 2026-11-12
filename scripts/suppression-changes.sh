#!/usr/bin/env bash
# Step 9, for pull_request and pull_request_target runs: finds the @scan:Suppress annotations the
# pull request adds and removes, from the diff of its own changes, and annotates each one. Code
# scanning shows neither when the finding is already on the base branch: a finding newly suppressed
# keeps its open alert, and one whose suppression is removed matches its alert dismissed on the
# default branch. Each one is a warning, the only one for that change: an added annotation takes
# findings out of the gate as soon as it is pushed, and a removed one counts them again.
# dismiss-alerts.sh, which runs after it, does not warn again at the findings of a removed one.
# pr-comment.sh comments both on the pull request. Annotations are matched by their
# rules, so one that is moved or has only its reason changed is neither added nor removed. Needs no
# token beyond reading the base repository. Every failure is a log line, so that it never fails the
# scan.
#
# Inputs (environment): SCAN_WORK_DIR, GITHUB_EVENT_PATH, GITHUB_WORKSPACE, SUPPRESSIONS,
# CODE_SCANNING (true when the findings go to code scanning), CATEGORY.
# Writes: $SCAN_WORK_DIR/suppression-changes.json, {} when nothing was checked, and otherwise
# {branch, head, base, added, removed}: head and base are the commits compared, and each change is
# {file, line, text}, with line in head. A removed one also has base-line, its line in base.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
OUT="$WORK/suppression-changes.json"
echo '{}' > "$OUT"
# With suppressions off no finding is suppressed, so an annotation changes nothing.
[ "$(bool_setting "${SUPPRESSIONS:-}")" = true ] || exit 0
BASE="$(jq -r '.pull_request.base.sha // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
BRANCH="$(jq -r '.repository.default_branch // ""' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
[ -n "$BASE" ] && [ -n "$BRANCH" ] || exit 0
cd "$(workspace_root)" || exit 0
git rev-parse --git-dir > /dev/null 2>&1 || { echo "No Git checkout, so suppression changes are not checked." && exit 0; }
HEAD_SHA="$(git rev-parse HEAD)"

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
    echo "Could not fetch the base commit $FROM, so suppression changes are not checked."
    exit 0
  fi
else
  if ! fetch_commit "$BASE"; then
    echo "Could not fetch the base commit $BASE, so suppression changes are not checked."
    exit 0
  fi
  if ! FROM="$(git merge-base "$BASE" HEAD 2> /dev/null)"; then
    [ "$(git rev-parse --is-shallow-repository)" = true ] \
      && git fetch --quiet --no-tags --unshallow origin "$BASE" \
      && FROM="$(git merge-base "$BASE" HEAD 2> /dev/null)" \
      || { echo "Could not find where the pull request branched off $BASE, so suppression changes are not checked." && exit 0; }
  fi
fi
if ! DIFF="$(git diff --no-color --no-ext-diff --unified=0 "$FROM" HEAD -- '*.bal')"; then
  echo "Could not compare with the base commit $FROM, so suppression changes are not checked."
  exit 0
fi

# One line per annotation added or removed, and not removed or added back in the same file: + or -,
# file, its line in HEAD, its line in FROM (0 for an added one), and its text on one line. A removed
# one is at the line of HEAD where it was. Each change of identical annotations counts. One spanning
# several lines is read up to its closing brace. A deleted file takes its findings with it.
CHANGES="$(awk '
  function norm(s) { gsub(/[ \t]+/, "", s); return s }
  function rules(s) { return match(s, /rules[ \t]*:[ \t]*\[[^]]*\]/) ? norm(substr(s, RSTART, RLENGTH)) : norm(s) }
  function depth(s,   o) { o = gsub(/\{/, "{", s); return o - gsub(/\}/, "}", s) }
  function begin(text) { sign = c; buf = text; start = (c == "+" ? cur : line); base = (c == "-" ? ocur : 0) }
  function finish() {
    if (sign == "") return
    n++; sg[n] = sign; key[n] = file SUBSEP rules(buf); at[n] = start; was[n] = base
    gsub(/[ \t]+/, " ", buf); txt[n] = buf; count[sign, key[n]]++
    sign = ""
  }
  /^\+\+\+ / { finish(); file = ($0 == "+++ /dev/null") ? "" : substr($0, 7); next }
  /^--- / { finish(); next }
  # A hunk that only removes lines gives the line before it, so the next one is where they were.
  /^@@ / { finish(); split($2, o, ","); split($3, h, ","); oline = substr(o[1], 2); line = substr(h[1], 2) + (h[2] == "0" ? 1 : 0); next }
  file == "" { next }
  { c = substr($0, 1, 1); if (c == "+") cur = line++; else if (c == "-") ocur = oline++ }
  sign != "" && c == sign { buf = buf " " substr($0, 2); open += depth(substr($0, 2)); if (open <= 0) finish(); next }
  { finish() }
  (c == "-" || c == "+") && /@scan:Suppress/ {
    head = substr($0, 2); gsub(/^[ \t]+|[ \t]+$/, "", head)
    begin(head); open = depth(head)
    if (open <= 0) finish()
    next
  }
  # The rules line of an annotation spanning several lines, whose other lines did not change.
  (c == "-" || c == "+") && match($0, /rules[ \t]*:[ \t]*\[[ \t]*"[^"]*:[^]]*\]/) {
    begin("@scan:Suppress {" substr($0, RSTART, RLENGTH) "}")
    finish()
  }
  END {
    finish()
    for (i = 1; i <= n; i++) {
      other = (sg[i] == "+" ? "-" : "+")
      if (count[other, key[i]] > 0 && cancelled[sg[i], key[i]] < count[other, key[i]]) { cancelled[sg[i], key[i]]++; continue }
      split(key[i], p, SUBSEP)
      printf "%s\t%s\t%d\t%d\t%s\n", sg[i], p[1], (at[i] > 0 ? at[i] : 1), was[i], txt[i]
    }
  }' <<< "$DIFF" | sort -t$'\t' -k2,2 -k3,3n)"

ADDED=0 REMOVED=0
while IFS=$'\t' read -r sign file line base_line text; do
  [ -n "$file" ] || continue
  if [ "$sign" = + ]; then
    ADDED=$((ADDED + 1))
    message="$(jq -rn --arg t "$text" '
      ($t | capture("rules\\s*:\\s*\\[(?<r>[^\\]]*)\\]").r // "" | [scan("\"([^\"]*)\"")[0]]) as $rules
      | ($t | capture("reason\\s*:\\s*\"(?<r>(\\\\.|[^\"\\\\])*)\"").r // "") as $reason
      | "Suppressed rule\(if ($rules | length) > 1 then "s" else "" end): \(if $rules == [] then "not specified" else $rules | join(", ") end)",
        "Suppressed reason: \(if $reason == "" then "not given" else $reason end)",
        "Its findings are left out of the counts and the gate as soon as it is pushed, whether or not a reviewer accepts it."')"
    log_file_warning "$file" "$line" "$message"
  else
    REMOVED=$((REMOVED + 1))
    message="This pull request removes $text, so the findings it suppressed are reported again."
    [ "${CODE_SCANNING:-false}" != true ] \
      || message+=" Code scanning matches them to their alerts dismissed on $BRANCH, so it does not show them as new. The action reopens the alerts when this change is merged."
    log_file_warning "$file" "$line" "$message"
  fi
done <<< "$CHANGES"
echo "@scan:Suppress annotations added: $ADDED, removed: $REMOVED."

jq -R -s --arg branch "$BRANCH" --arg head "$HEAD_SHA" --arg base "$FROM" '
  [split("\n")[] | select(. != "") | split("\t") | {sign: .[0], file: .[1], line: (.[2] | tonumber), "base-line": (.[3] | tonumber), text: (.[4:] | join("\t"))}]
  | {branch: $branch, head: $head, base: $base,
     added: map(select(.sign == "+") | del(.sign, ."base-line")),
     removed: map(select(.sign == "-") | del(.sign))}
' <<< "$CHANGES" > "$OUT"
