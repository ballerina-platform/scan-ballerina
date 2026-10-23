#!/usr/bin/env bash
# Prints the active bal scan version, or nothing when no scan tool is installed.
#
# Before Ballerina 2201.13, 'bal tool list' lists every pulled version and marks the active one with
# "*", as in "|scan |* 0.11.0 |central |". Later ones list only the active version, unmarked.
#
# Usage: active-scan-tool.sh

set -euo pipefail

bal tool list | tr -d '\r' \
  | awk -F'|' '$2 ~ /^[[:space:]]*scan[[:space:]]*$/ && match($3, /[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*/) {
      v = substr($3, RSTART, RLENGTH)
      if ($3 ~ /\*/) active = v
      else if (first == "") first = v
    }
    END { print (active != "" ? active : first) }'
