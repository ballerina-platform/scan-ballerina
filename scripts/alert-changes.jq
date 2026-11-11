# Picks the code scanning alerts dismiss-alerts.sh changes or reports, from the alerts (slurped) of a ref.
#
# Arguments:
#   $results   results.json of merge-sarif.sh (slurped), every result with whether it is suppressed.
#   $category  The category of the upload. Alerts of other categories are left alone.
#   $marker    Starts the comment of every alert this step dismisses.
#   $reason    The dismissed_reason it gives them.
#   $limit     The longest comment code scanning accepts.
#   $mode      change: prints {number, change} for each open alert of a suppressed result, to
#              dismiss, and for each alert this step dismissed whose result is no longer suppressed,
#              to reopen. reintroduced: prints {rule, file, line, url} for each alert this step
#              dismissed whose result is no longer suppressed, from the alerts of the default branch.
# An alert matches a result by rule, file, line and column.

def key: "\(.rule)|\(.file)|\(.line)|\(.column // 1)";
def alert_key: .most_recent_instance.location as $l | "\(.rule.id)|\($l.path)|\($l.start_line)|\($l.start_column // 1)";
def dismissed_here: .state == "dismissed" and .dismissed_reason == $reason
  and (.dismissed_comment // "" | startswith($marker));

# The suppressed result of each key, false when its results are not suppressed, and null when some
# are and some are not, which is left alone.
($results[0] | group_by(key) | map({
    key: (.[0] | key),
    value: (if all(.suppressed) then .[0] elif any(.suppressed) then null else false end)
  }) | from_entries) as $by_key
| .[]
| select((.most_recent_instance.category // "" | rtrimstr("/")) == ($category | rtrimstr("/")))
| $by_key[alert_key] as $r
| if $mode == "reintroduced" then
    if dismissed_here and $r == false then
      .most_recent_instance.location as $l | {rule: .rule.id, file: $l.path, line: $l.start_line, url: .html_url}
    else empty end
  elif .state == "open" and ($r | type) == "object" then
    {number, change: {state: "dismissed", dismissed_reason: $reason,
      dismissed_comment: ($marker + (if $r.justification != "" then ": \($r.justification)" else "." end))[:$limit]}}
  elif dismissed_here and $r == false then
    {number, change: {state: "open"}}
  else empty end
