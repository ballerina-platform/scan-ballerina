# Normalizes the SARIF report of one package or workspace.
#
# Arguments:
#   $prefix         The unit's directory relative to the repository root, "." for the root.
#   $excludes       exclude-paths globs, relative to the repository root.
#
# Gives each location that has only an artifactLocation.index the URI of its artifact, makes each
# artifactLocation.uri, in the results and in run.artifacts, relative to the repository root, then
# drops the findings in excluded files. bal scan writes each URI as a plain path with
# forward slashes, relative to the package, or to the workspace root for a workspace. The paths
# stay plain here, so that they can be matched against exclude-paths, and merge-sarif.sh
# percent-encodes them at the end. bal scan leaves the test sources out itself, with
# --exclude-tests.

include "common";

def absolute: test("^(/|[A-Za-z][A-Za-z0-9+.-]*:)");

def repo_uri:
  if absolute then . else gsub("\\\\"; "/") | sub("^\\./"; "") as $uri | join_path($prefix; $uri) end;

def uris: [.locations[]?.physicalLocation.artifactLocation.uri | select(type == "string")];

# Gives a location that names its file only by artifactLocation.index the URI of that artifact, so
# that exclude-paths, the findings and the alerts see its file.
def fill_uri($artifacts):
  .physicalLocation.artifactLocation.index as $i
  | if (.physicalLocation.artifactLocation.uri | type) != "string" and ($i | type) == "number" and $i >= 0
      and ($artifacts[$i].location.uri? | type) == "string"
    then .physicalLocation.artifactLocation.uri = $artifacts[$i].location.uri else . end;

.runs |= map(
  (.artifacts // []) as $artifacts
  | .results |= map(
    (if .locations then .locations |= map(fill_uri($artifacts)) else . end)
    | (if .relatedLocations then .relatedLocations |= map(fill_uri($artifacts)) else . end))
  | (if .artifacts then .artifacts |= map(if (.location.uri | type) == "string" then .location.uri |= repo_uri else . end) else . end)
  | .results |= map(
    (if .locations then .locations |= map(map_uri(repo_uri)) else . end)
    | (if .relatedLocations then .relatedLocations |= map(map_uri(repo_uri)) else . end)
    | select(uris | any(excluded($excludes)) | not)
  )
)
