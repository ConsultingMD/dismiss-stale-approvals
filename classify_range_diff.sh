#!/usr/bin/env bash

set -euo pipefail

range_diff_file=${1:?range-diff file is required}

awk '
  NF >= 3 && $3 ~ /^[!<>]$/ {
    changed = 1
    saw_summary = 1
  }
  NF >= 3 && $3 == "=" {
    saw_summary = 1
  }
  END {
    if (changed) {
      print "changed"
    } else if (saw_summary || NR == 0) {
      print "unchanged"
    } else {
      print "range-diff output did not contain a recognized summary" > "/dev/stderr"
      exit 2
    }
  }
' "$range_diff_file"
