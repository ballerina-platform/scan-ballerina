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

# Normalizes a package path relative to the repository root: no leading "./" or trailing "/", and
# "." for the root.
def package_path:
  tostring | sub("^\\./"; "") | sub("/+$"; "") | if . == "" then "." else . end;

# Applies f to the artifactLocation.uri of a SARIF location, when it has one.
def map_uri(f):
  if (.physicalLocation.artifactLocation.uri | type) == "string" then .physicalLocation.artifactLocation.uri |= f else . end;

# Percent-encodes a relative path for a SARIF URI, one segment at a time, so that spaces and
# other reserved characters are valid and "/" still separates the segments. Absolute URIs are left
# as they are.
def uri_path:
  if test("^(/|[A-Za-z][A-Za-z0-9+.-]*:)") then . else split("/") | map(@uri) | join("/") end;

# Escapes a string for use inside a regex.
def regex_escape:
  gsub("(?<c>[.+*?^$(){}|\\[\\]\\\\])"; "\\\(.c)");

# The action severity of a SARIF result: high, medium, low, or none when it is not counted.
# A result without a level takes its rule's default level, and warning when there is none.
def severity($rules):
  (.ruleId as $id | ($rules | map(select(.id == $id)) | first // {}) | .defaultConfiguration.level) as $default
  | {"error": "high", "warning": "medium", "note": "low"}[.level // $default // "warning"] // "none";
