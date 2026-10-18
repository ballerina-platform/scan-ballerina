#!/usr/bin/env bash
# Step 2: finds the packages and workspaces to scan.
#
# Each entry in SCAN_PATHS is a package or a directory searched for Ballerina.toml, skipping
# target, build and .git. A workspace is scanned as one unit from its root, so its member
# packages are not scanned again on their own. Units matching EXCLUDE_PATHS are dropped. Each
# package's remote Scan.toml is downloaded to the work directory, and a package whose Scan.toml
# settings cannot be used, or whose [[platform]] entries the action cannot hide, fails the step.
# Files that an earlier run left changed, because it stopped before restoring them, are restored
# first.
#
# Inputs (environment): SCAN_WORK_DIR, SCAN_PATHS, EXCLUDE_PATHS, CATEGORY.
# Writes: $SCAN_WORK_DIR/units.json, a list of {path, kind, members}, with paths relative to
# the repository root.
# Outputs: count (units to scan).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
ROOT="$(workspace_root)"
cd "$ROOT"

# Before any Ballerina.toml or Scan.toml is read, so that none still holds a change of an earlier
# run that was stopped before it restored it.
recover_files

FOUND=()
while IFS= read -r p; do
  while IFS= read -r toml; do
    FOUND+=("$(repo_relative_dir "$(dirname "$toml")")")
  # A target or build directory is pruned only when it is not itself a package.
  done < <(find "$p" -mindepth 1 \( -name .git -o \( -name target -o -name build \) -type d \
    ! -exec sh -c 'test -f "$1/Ballerina.toml"' sh {} \; \) -prune -o -name Ballerina.toml -type f -print)
done < <(split_list "${SCAN_PATHS:-.}")

UNITS='[]'
if [ "${#FOUND[@]}" -gt 0 ]; then
  while IFS= read -r dir; do
    if grep -Eq '^[[:space:]]*\[workspace\][[:space:]]*(#.*)?$' "$dir/Ballerina.toml"; then
      MEMBERS="$(yq -p toml -o json -I0 '.workspace.packages // []' "$dir/Ballerina.toml" 2> /dev/null || echo '[]')"
      UNIT="$(jq -nc --arg path "$dir" --argjson members "$MEMBERS" \
        '{path: $path, kind: "workspace", members: [$members[] | tostring | sub("^\\./"; "") | sub("/+$"; "")]}')"
    else
      UNIT="$(jq -nc --arg path "$dir" '{path: $path, kind: "package", members: []}')"
    fi
    UNITS="$(jq -c --argjson unit "$UNIT" '. + [$unit]' <<< "$UNITS")"
  done < <(printf '%s\n' "${FOUND[@]}" | sort -u)
fi

EXCLUDES="$(split_list "${EXCLUDE_PATHS:-}" | jq -R . | jq -sc .)"
UNITS="$(jq -c -L "$SCRIPT_DIR" --argjson excludes "$EXCLUDES" '
  include "common";
  ([.[] | select(.kind == "workspace") | .path as $ws | .members[] | join_path($ws; .)]) as $covered
  | map(select(
      (.kind == "workspace" or (.path | IN($covered[]) | not))
      and (.path | excluded($excludes) | not)))
' <<< "$UNITS")"

printf '%s\n' "$UNITS" > "$WORK/units.json"
COUNT="$(jq 'length' <<< "$UNITS")"

if [ "$COUNT" -eq 0 ]; then
  log_warning "No Ballerina package was found in paths '$(split_list "${SCAN_PATHS:-.}" | paste -sd, -)'. Nothing was scanned."
else
  echo "Found $COUNT package(s) to scan:"
  jq -r '.[] | "  \(.path)\(if .kind == "workspace" then " (workspace)" else "" end)"' <<< "$UNITS"
fi

# Prints why the Scan.toml settings of package $1 cannot be used, or nothing when they can. A
# remote Scan.toml is downloaded into the work directory, since the action changes the file
# during a scan: scan.sh points configPath to a changed copy for each scan.
scan_config_problem() {
  local pkg="$1" config url file probe
  [ "$(scan_table "$pkg")" != null ] || return 0
  config="$(scan_config_value "$pkg")"
  url="$(scan_config_url "$pkg")"
  if [ -z "$config" ]; then
    echo "Package '$pkg' has a [scan] table in Ballerina.toml without configPath, which bal scan rejects. Set configPath to its Scan.toml file, or remove the table to use the package's Scan.toml."
  elif [ -z "$url" ]; then
    [ -f "$(resolve_config_path "$pkg" "$config")" ] \
      || echo "Package '$pkg' sets [scan] configPath in Ballerina.toml to '$config', which is not an existing file. Give a path relative to the package, or an https URL."
  elif ! [[ "$url" =~ ^https:// ]]; then
    # The scan tool loads the JAR of each [[platform]] entry, so the file must not be changed in transit.
    echo "Package '$pkg' reads its Scan.toml from '$url'. Use an https URL, since the scan tool loads the platform plugins the file names."
  else
    # The scan uses this configPath line, so check now that it can be changed.
    probe="$(with_config_path "$pkg/Ballerina.toml" /scan-ballerina/Scan.toml | yq -p toml -o json -I0 '.scan.configPath // ""' 2> /dev/null | tr -d '\r' || true)"
    if [ "$probe" != '"/scan-ballerina/Scan.toml"' ]; then
      echo "Package '$pkg' sets [scan] configPath in Ballerina.toml in a form the action cannot change. Write it as a configPath = \"...\" line under a [scan] table."
      return 0
    fi
    file="$(remote_scan_toml_file "$url")"
    if [ ! -f "$file" ]; then
      mkdir -p "$(dirname "$file")"
      if ! curl -fsSL --proto '=https' --retry 3 -o "$file" "$url"; then
        rm -f "$file"
        echo "Package '$pkg': could not download its Scan.toml from '$url' ([scan] configPath in Ballerina.toml)."
        return 0
      fi
      echo "Downloaded the Scan.toml of '$pkg' from $url" >&2
    fi
    yq -p toml -o json '.' "$file" > /dev/null 2>&1 \
      || echo "Package '$pkg': the Scan.toml at '$url' is not valid TOML."
  fi
}

# Each package, including each workspace member, needs Scan.toml settings the action can use,
# whatever platforms are selected, since a scan fails without them. Checked before the tools are
# downloaded.
PROBLEMS=()
while IFS= read -r pkg; do
  [ -d "$pkg" ] || continue
  problem="$(scan_config_problem "$pkg")"
  if [ -z "$problem" ]; then
    # The SARIF scan hides the [[platform]] entries, which needs them in a form the action edits.
    file="$(scan_toml_path "$pkg")"
    if [ -n "$file" ] && [ -f "$file" ]; then
      name="$(scan_config_url "$pkg")"
      [ -n "$name" ] || name="$file"
      form="$(platform_form_problem "$file" "$name")"
      [ -z "$form" ] || problem="Package '$pkg': $form"
    fi
  fi
  [ -z "$problem" ] || PROBLEMS+=("$problem")
done < <(jq -r -L "$SCRIPT_DIR" 'include "common";
  .[] | if .kind == "workspace" then .path as $ws | .members[] | join_path($ws; .) else .path end' <<< "$UNITS")
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  for p in "${PROBLEMS[@]}"; do log_error "$p"; done
  exit 1
fi

set_output count "$COUNT"
