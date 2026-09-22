#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/assertions.sh
source "$repo_root/tests/lib/assertions.sh"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dismiss-stale-approvals-range-tests.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/unchanged.txt" <<'EOF'
1:  aaaaaaa = 1:  bbbbbbb Keep behavior
2:  ccccccc = 2:  ddddddd Preserve behavior
EOF
assert_equals \
  "unchanged" \
  "$("$repo_root/classify_range_diff.sh" "$work_dir/unchanged.txt")" \
  "equal commits should be unchanged"
assert_equals \
  "unchanged" \
  "$("$repo_root/classify_pr_change.sh" "$work_dir/unchanged.txt" false false)" \
  "equal non-merge ranges should be unchanged"
assert_equals \
  "changed" \
  "$("$repo_root/classify_pr_change.sh" "$work_dir/unchanged.txt" false true)" \
  "ranges containing merge commits should fail closed"

cat > "$work_dir/changed.txt" <<'EOF'
1:  aaaaaaa ! 1:  bbbbbbb Change behavior
    @@ src/example.ts:1 @@
    -old value
    +new value
EOF
assert_equals \
  "changed" \
  "$("$repo_root/classify_range_diff.sh" "$work_dir/changed.txt")" \
  "modified commits should be changed"
assert_equals \
  "changed" \
  "$("$repo_root/classify_pr_change.sh" "$work_dir/changed.txt" false false)" \
  "a changed range-diff should remain changed without merges"

cat > "$work_dir/added.txt" <<'EOF'
-:  ------- > 1:  bbbbbbb Add behavior
EOF
assert_equals \
  "changed" \
  "$("$repo_root/classify_range_diff.sh" "$work_dir/added.txt")" \
  "added commits should be changed"

: > "$work_dir/empty.txt"
assert_equals \
  "unchanged" \
  "$("$repo_root/classify_range_diff.sh" "$work_dir/empty.txt")" \
  "two empty ranges should be unchanged"

printf 'not range-diff output\n' > "$work_dir/malformed.txt"
if "$repo_root/classify_range_diff.sh" "$work_dir/malformed.txt" >/dev/null 2>&1; then
  fail "malformed range-diff output should fail closed"
fi

awk 'BEGIN { for (i = 0; i < 1000000; i++) print "1: aaaaaaa ! 1: bbbbbbb Large change" }' \
  > "$work_dir/large.txt"
assert_equals \
  "changed" \
  "$("$repo_root/classify_range_diff.sh" "$work_dir/large.txt")" \
  "large changed diffs must not be misclassified after a broken pipe"

echo "Range-diff tests passed."
