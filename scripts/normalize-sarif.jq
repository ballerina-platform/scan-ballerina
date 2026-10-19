# Normalizes the SARIF report of one package or workspace.
#
# Arguments:
#   $prefix         The unit's directory relative to the repository root, "." for the root.
#   $packages       Package roots relative to the unit, "" for the unit itself, used to find tests.
#   $exclude_tests  Drop findings in tests/ and modules/*/tests/ of each package.
#   $excludes       exclude-paths globs, relative to the repository root.
#
# Makes each artifactLocation.uri, in the results and in run.artifacts, relative to the repository
# root, then drops the findings in test sources and excluded files. bal scan writes each URI as a
# plain path with forward slashes, relative to the package, or to the workspace root for a
# workspace. The paths stay plain here, so that they can be matched against exclude-paths, and
# merge-sarif.sh percent-encodes them at the end.

include "common";

def absolute: test("^(/|[A-Za-z][A-Za-z0-9+.-]*:)");

def repo_uri:
  if absolute then . else gsub("\\\\"; "/") | sub("^\\./"; "") as $uri | join_path($prefix; $uri) end;

def test_source:
  gsub("\\\\"; "/") as $uri
  | any($packages[]; . as $pkg
      | $uri | test("^\(if $pkg == "" then "" else ($pkg | regex_escape) + "/" end)(modules/[^/]+/)?tests/"));

def uris: [.locations[]?.physicalLocation.artifactLocation.uri | select(type == "string")];

.runs |= map(
  (if .artifacts then .artifacts |= map(if (.location.uri | type) == "string" then .location.uri |= repo_uri else . end) else . end)
  | .results |= map(
    select(($exclude_tests | not) or (uris | any(test_source) | not))
    | (if .locations then .locations |= map(map_uri(repo_uri)) else . end)
    | (if .relatedLocations then .relatedLocations |= map(map_uri(repo_uri)) else . end)
    | select(uris | any(excluded($excludes)) | not)
  )
)
