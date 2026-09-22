#!/usr/bin/env bash

set -euo pipefail

range_diff_file=${1:?range-diff file is required}
previous_has_merges=${2:?previous merge status is required}
current_has_merges=${3:?current merge status is required}

for value in "$previous_has_merges" "$current_has_merges"; do
  if [[ "$value" != "true" && "$value" != "false" ]]; then
    echo "Merge status must be true or false" >&2
    exit 2
  fi
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
range_classification=$("$script_dir/classify_range_diff.sh" "$range_diff_file")

if [[ "$previous_has_merges" == "true" || "$current_has_merges" == "true" ]]; then
  echo "changed"
elif [[ "$range_classification" == "changed" ]]; then
  echo "changed"
elif [[ "$range_classification" != "unchanged" ]]; then
  echo "Unexpected range-diff classification: $range_classification" >&2
  exit 2
else
  echo "unchanged"
fi
