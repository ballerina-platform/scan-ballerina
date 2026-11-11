# Picks the code scanning alerts dismiss-alerts.sh changes or reports, from the alerts (slurped) of a ref.
#
# Arguments:
#   $results   results.json of merge-sarif.sh (slurped), every result with whether it is suppressed.
#   $category  The category of the upload. Alerts of other categories are left alone.
#   $marker    Starts the comment of every alert this step dismissed. Such an alert is its own,
#              whatever its reason, and every other dismissed alert was dismissed by hand.
#   $reason    The dismissed_reason it gives the open alerts it dismisses.
#   $limit     The longest comment code scanning accepts.
#   $sha       In change mode, the commit of the upload, or "". An alert whose latest instance is of
#              another commit was not reported by this analysis, even when its last location is that
#              of a result, such as when the code after the finding changed and gave it a new alert.
#   $mode      change: prints {number, kind, patches} for each alert of the default branch to change,
#              where patches are applied in order:
#                dismiss   an open alert whose results are all suppressed.
#                record    a dismissed alert whose results are all suppressed but whose comment is not
#                          this suppression's: one dismissed by hand, which this step takes over, or
#                          one whose justification changed. Code scanning rejects dismissing a
#                          dismissed alert, so it is reopened first, and keeps its reason.
#                reopen    an alert this step dismissed whose results are no longer suppressed.
#                fix       an alert this step dismissed that this analysis did not report, such as
#                          when the code was fixed or deleted. Code scanning sets a reopened alert
#                          that the latest analysis does not report to fixed.
#              unsuppressed: prints {number, rule, file, line, url, own, reason} for each dismissed
#              alert of the scanned ref that matches results which are not suppressed, own being
#              whether this step dismissed it.
# An alert matches a result by rule, file, line and column.

def key: "\(.rule)|\(.file)|\(.line)|\(.column // 1)";
def alert_key: .most_recent_instance.location as $l | "\(.rule.id)|\($l.path)|\($l.start_line)|\($l.start_column // 1)";
def own: .state == "dismissed" and (.dismissed_comment // "" | startswith($marker));
def comment($r): ($marker + (if $r.justification != "" then ": \($r.justification)" else "." end))[:$limit];

# For each key: its suppressed result when all of them are suppressed, false when none is, and
# "mixed" when some are, which is left alone. A key with no result is missing.
($results[0] | group_by(key) | map({
    key: (.[0] | key),
    value: (if all(.suppressed) then .[0] elif any(.suppressed) then "mixed" else false end)
  }) | from_entries) as $by_key
| .[]
| select((.most_recent_instance.category // "" | rtrimstr("/")) == ($category | rtrimstr("/")))
| alert_key as $k
| ($by_key | has($k)) as $reported
| $by_key[$k] as $r
| if $mode == "unsuppressed" then
    if .state == "dismissed" and $reported and $r == false then
      .most_recent_instance.location as $l
      | {number, rule: .rule.id, file: $l.path, line: $l.start_line, url: .html_url, own: own, reason: .dismissed_reason}
    else empty end
  elif ($reported | not) or ($sha != "" and (.most_recent_instance.commit_sha // $sha) != $sha) then
    if own then {number, kind: "fix", patches: [{state: "open"}]} else empty end
  elif ($r | type) == "object" then
    if .state == "open" then
      {number, kind: "dismiss", patches: [{state: "dismissed", dismissed_reason: $reason, dismissed_comment: comment($r)}]}
    elif .state == "dismissed" and .dismissed_comment != comment($r) then
      {number, kind: "record", patches: [{state: "open"},
        {state: "dismissed", dismissed_reason: (.dismissed_reason // $reason), dismissed_comment: comment($r)}]}
    else empty end
  elif own and $r == false then
    {number, kind: "reopen", patches: [{state: "open"}]}
  else empty end
