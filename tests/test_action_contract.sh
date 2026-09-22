#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/assertions.sh
source "$repo_root/tests/lib/assertions.sh"

action_file="$repo_root/action.yml"
artifact_reader="$repo_root/latest_artifact.sh"

assert_file_contains \
  "printf.*> \"\$CURRENT_SHAS_DIR/shas.txt\"" \
  "$action_file" \
  "the action should write the baseline with the filename expected by restore"
assert_file_contains \
  'path:.*dismiss-stale-approvals-.*}/shas.txt' \
  "$action_file" \
  "the artifact upload should preserve shas.txt as its filename"
assert_file_contains \
  "unzip -p \"\$archive\" shas.txt" \
  "$artifact_reader" \
  "artifact restore should extract the same shas.txt filename"

echo "Action contract tests passed."
