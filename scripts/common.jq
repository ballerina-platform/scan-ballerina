# jq definitions shared by the scan-ballerina scripts. Load with: jq -L <scripts dir> 'include "common"; ...'

# Converts an exclude-paths glob into an anchored regex. "*" and "?" stay within one directory,
# "**" crosses directories, and a match also covers everything below it.
def glob_regex:
  sub("^\\./"; "") | sub("/+$"; "")
  | gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)")
  | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002")
  | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]")
  | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*")
  | "^\(.)(/.*)?$";

# True when the repository-relative path matches any of the globs.
def excluded($globs):
  . as $path | any($globs[]; . as $glob | $path | test($glob | glob_regex));

# Joins a directory relative to the repository root, where "." is the root, with a relative path.
def join_path($dir; $path):
  if $dir == "." or $dir == "" then $path else "\($dir)/\($path)" end;

# Escaping for GitHub workflow commands, so that values cannot inject other commands. The same as
# escape_data and escape_property in lib.sh.
def escape_data: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
def escape_property: escape_data | gsub(":"; "%3A") | gsub(","; "%2C");

# Normalizes a package path relative to the repository root: no leading "./" or trailing "/", and
# "." for the root.
def package_path:
  tostring | sub("^\\./"; "") | sub("/+$"; "") | if . == "" then "." else . end;

# On platform-config.sonarqube: the packages item of package $p, or {} when it has none.
def sonar_item($p):
  [.packages // [] | .[] | select(type == "object" and (.path | package_path) == $p)] | first // {};

# On platform-config.sonarqube: setting $f of package $p, from its packages item, then from the
# platform level, or "" when neither sets it. check-sonarqube.sh and scan.sh both resolve settings
# with it, so that the token sent to SonarScanner is the one that was checked.
def sonar_setting($p; $f):
  sonar_item($p)[$f] // .[$f] // "" | tostring;

# Applies f to the artifactLocation.uri of a SARIF location, when it has one.
def map_uri(f):
  if (.physicalLocation.artifactLocation.uri | type) == "string" then .physicalLocation.artifactLocation.uri |= f else . end;

# Percent-encodes a relative path for a SARIF URI, one segment at a time, so that spaces and
# other reserved characters are valid and "/" still separates the segments. Absolute URIs are left
# as they are.
def uri_path:
  if test("^(/|[A-Za-z][A-Za-z0-9+.-]*:)") then . else split("/") | map(@uri) | join("/") end;

# True when a SARIF result is suppressed: it has suppressions, and none is under review or rejected.
def suppressed:
  (.suppressions // []) as $s | ($s | length) > 0 and all($s[]; (.status // "accepted") == "accepted");

# The justification of a suppressed result, "" when it gives none.
def justification:
  [.suppressions[]? | .justification // empty | select(. != "")] | join("; ");

# The action severity of a SARIF result: high, medium, low, or none when it is not counted.
# A result without a level takes its rule's default level, and warning when there is none.
def severity($rules):
  (.ruleId as $id | ($rules | map(select(.id == $id)) | first // {}) | .defaultConfiguration.level) as $default
  | {"error": "high", "warning": "medium", "note": "low"}[.level // $default // "warning"] // "none";

# On the text of an @scan:Suppress annotation: its rules segment, such as rules: ["a:1"], or "" when
# it has none.
def suppress_rules_segment:
  capture("(?<s>rules\s*:\s*\[[^\]]*\])").s // "";

# On the text of an @scan:Suppress annotation: the rules it lists.
def suppress_rules:
  suppress_rules_segment | [scan("\"([^\"]*)\"")[0]];

# On the text of an @scan:Suppress annotation: its reason, or null when it gives none.
def suppress_reason:
  capture("reason\s*:\s*\"(?<r>(\\.|[^\"\\])*)\"").r // null;

# On a unified diff patch: {plus, minus}, the text of each added line by its line in the new file
# and of each removed line by its line in the old file, both keyed by the line number as a string.
def diff_lines:
  reduce (split("\n")[] | rtrimstr("\r")) as $l ({o: 0, n: 0, plus: {}, minus: {}};
    if $l | startswith("@@") then ($l | capture("-(?<o>[0-9]+)(,[0-9]+)? \+(?<n>[0-9]+)")) as $h
      | .o = ($h.o | tonumber) | .n = ($h.n | tonumber)
    elif $l | startswith("+") then .plus[.n | tostring] = $l[1:] | .n += 1
    elif $l | startswith("-") then .minus[.o | tostring] = $l[1:] | .o += 1
    elif $l | startswith("\\") then .
    else .o += 1 | .n += 1 end)
  | {plus, minus};
