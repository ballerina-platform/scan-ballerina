# Merges normalized bal scan SARIF reports (slurped) into one run, and fills in what GitHub code
# scanning renders. GitHub accepts one run per category, so all packages share a run: rules are
# deduplicated by ID, each result's rule is set as ruleId, and its ruleIndex and rule.index are
# recomputed. The run.artifacts of the reports are concatenated, so each artifactLocation.index is
# moved by the number of artifacts of the runs before its own.

def owasp_2025: {
  "A01": "Broken Access Control",
  "A02": "Security Misconfiguration",
  "A03": "Software Supply Chain Failures",
  "A04": "Cryptographic Failures",
  "A05": "Injection",
  "A06": "Insecure Design",
  "A07": "Authentication Failures",
  "A08": "Software or Data Integrity Failures",
  "A09": "Security Logging and Alerting Failures",
  "A10": "Mishandling of Exceptional Conditions"
};

def rule_kinds: {"VULNERABILITY": "Vulnerability", "CODE_SMELL": "Code smell", "BUG": "Bug"};

def cwe_links:
  [.properties.tags[]? | capture("^external/cwe/cwe-0*(?<id>[0-9]+)$")
    | "[CWE-\(.id)](https://cwe.mitre.org/data/definitions/\(.id).html)"];

def owasp_links:
  [.properties.tags[]? | capture("^external/owasp/owasp-(?<cat>a[0-9]{2})-(?<year>[0-9]{4})$")
    | (.cat | ascii_upcase) as $cat
    | if .year == "2025" and owasp_2025[$cat] then
        "[\($cat):2025 – \(owasp_2025[$cat])](https://top10.owasp.org/2025/\($cat)_2025-\(owasp_2025[$cat] | gsub(" "; "_"))/)"
      else "\($cat):\(.year)" end];

def plain_tags:
  [.properties.tags[]? | select(startswith("external/") or . == "security" or . == "maintainability" | not) | "`\(.)`"];

def help_markdown($desc):
  [
    $desc,
    "",
    "- **Rule:** `\(.id)`",
    (rule_kinds[.properties.ruleKind // ""] // empty | "- **Type:** \(.)"),
    (cwe_links | select(length > 0) | "- **CWE:** \(join(", "))"),
    (owasp_links | select(length > 0) | "- **OWASP Top 10:** \(join(", "))"),
    (plain_tags | select(length > 0) | "- **Tags:** \(join(" "))"),
    (.helpUri // empty | "", "[Rule documentation](\(.))")
  ] | join("\n");

# The [major, minor] version of the bal scan that wrote a tool.driver, [] when it is not known.
def tool_version:
  [.semanticVersion // "" | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)") | (.major | tonumber), (.minor | tonumber)];

# bal scan up to 0.12.x reports the rule's title as every result's message, not one about the finding.
def generic_messages:
  tool_version as $v | $v != [] and $v <= [0, 12];

# bal scan before 0.12.0 sets no ruleKind, but takes each rule's level from its kind.
def kinds_from_levels:
  tool_version as $v | $v != [] and $v < [0, 12];

def with_kind:
  if .properties.ruleKind then .
  else
    {"error": "BUG", "warning": "VULNERABILITY", "note": "CODE_SMELL"}[.defaultConfiguration.level // ""] as $kind
    | if $kind then .properties.ruleKind = $kind else . end
  end;

def enrich:
  (.fullDescription.text // .shortDescription.text // .id) as $desc
  | .help //= {text: $desc, markdown: help_markdown($desc)}
  | .fullDescription //= {text: $desc}
  | if .properties.ruleKind == "VULNERABILITY" then .properties.tags = (((.properties.tags // []) + ["security"]) | unique)
    elif .properties.ruleKind == "CODE_SMELL" then .properties.tags = (((.properties.tags // []) + ["maintainability"]) | unique)
    else . end;

def shift_index($offset):
  if (.physicalLocation.artifactLocation.index | type) == "number"
  then .physicalLocation.artifactLocation.index += $offset else . end;

def shift_indexes($offset):
  (if .locations then .locations |= map(shift_index($offset)) else . end)
  | (if .relatedLocations then .relatedLocations |= map(shift_index($offset)) else . end);

. as $all
| ($all | map(.runs[]?)) as $runs
| ($runs | map(.artifacts // [] | length)) as $artifact_counts
| ($runs | map(.artifacts[]?)) as $artifacts
| ($runs[0].tool.driver | generic_messages) as $generic
| ($runs[0].tool.driver | kinds_from_levels) as $legacy
| ($runs | map(.tool.driver.rules[]?) | unique_by(.id)) as $tool_rules
| ($tool_rules | map(select(.fullDescription.text) | {key: .id, value: .fullDescription.text}) | from_entries) as $descriptions
| ($tool_rules | map(if $legacy then with_kind else . end | enrich)) as $rules
| ($rules | to_entries | map({key: .value.id, value: .key}) | from_entries) as $index
| {
    "$schema": ($all[0]["$schema"] // "https://json.schemastore.org/sarif-2.1.0.json"),
    version: "2.1.0",
    runs: [{
      tool: (($runs[0].tool // {driver: {name: "Ballerina Scan Tool"}}) | .driver.rules = $rules)
    }
    + (if ($artifacts | length) > 0 then {artifacts: $artifacts} else {} end)
    + {
      results: ([range(0; $runs | length) as $i
          | ($artifact_counts[:$i] | add // 0) as $offset
          | ($runs[$i].tool.driver.rules // []) as $run_rules
          | $runs[$i].results[]? | shift_indexes($offset)
          # SARIF names a result's rule by ruleId, rule.id, or an index into its own run's rules,
          # so the ID is found before the runs are merged, and set as ruleId.
          | (.ruleId
              // .rule.id?
              // (.rule.index? | numbers | select(. >= 0) | $run_rules[.].id?)
              // (.ruleIndex | numbers | select(. >= 0) | $run_rules[.].id?)
              // null) as $id
          | if $id then .ruleId = $id else . end] | map(
        .ruleId as $id
        # The indexes are recomputed for the merged rules, and dropped when the rule is unknown.
        | (if $id then $index[$id] else null end) as $new
        | if $new == null then del(.ruleIndex) else .ruleIndex = $new end
        | if (.rule | type) == "object" then
            (if $new == null then del(.rule.index) else .rule.index = $new end)
          else . end
        | if $id and $generic and $descriptions[$id] then .message.text = $descriptions[$id] else . end
      ))
    }]
  }
