#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dismiss-stale-approvals-tests.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

assert_equals() {
  local expected=$1
  local actual=$2
  local message=$3
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual: %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

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
  echo "FAIL: malformed range-diff output should fail closed" >&2
  exit 1
fi

awk 'BEGIN { for (i = 0; i < 1000000; i++) print "1: aaaaaaa ! 1: bbbbbbb Large change" }' \
  > "$work_dir/large.txt"
assert_equals \
  "changed" \
  "$("$repo_root/classify_range_diff.sh" "$work_dir/large.txt")" \
  "large changed diffs must not be misclassified after a broken pipe"

fake_curl="$work_dir/fake-curl"
cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "$CURL_LOG"
printf '\n' >> "$CURL_LOG"

url=
output=
page=1
while (( $# > 0 )); do
  case "$1" in
    --output)
      output=$2
      shift 2
      ;;
    --data-urlencode)
      if [[ "$2" == page=* ]]; then
        page=${2#page=}
      fi
      shift 2
      ;;
    http://* | https://*)
      url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  */pulls/42)
    printf '{"head":{"sha":"%s"}}\n' "$LIVE_HEAD_SHA"
    ;;
  */pulls/42/reviews)
    if [[ "${REVIEWS_PAGINATED:-false}" == "true" && "$page" == "1" ]]; then
      jq -n '[range(0; 100) | {id: (1000 + .), state: "COMMENTED"}]'
    elif [[ "${REVIEWS_PAGINATED:-false}" == "true" && "$page" == "2" ]]; then
      printf '%s\n' \
        '[{"id":201,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111"}]'
    else
      printf '%s\n' "$REVIEWS_RESPONSE"
    fi
    ;;
  */pulls/42/reviews/101/dismissals | */pulls/42/reviews/201/dismissals | */issues/42/comments)
    printf '%s\n' '{}'
    ;;
  */actions/runs/123)
    printf '%s\n' '{"workflow_id":77}'
    ;;
  */actions/workflows/77/runs)
    printf '%s\n' \
      '{"workflow_runs":[{"id":88,"run_number":2,"pull_requests":[{"number":42,"head":{"sha":"1111111111111111111111111111111111111111"},"base":{"sha":"2222222222222222222222222222222222222222"}}]}]}'
    ;;
  */actions/runs/88/artifacts)
    printf '%s\n' '{"artifacts":[{"id":99,"name":"dismiss-stale-approvals-shas","expired":false}]}'
    ;;
  */actions/artifacts/99/zip)
    cp "$ARTIFACT_ZIP" "$output"
    ;;
  *)
    printf 'Unexpected URL: %s\n' "$url" >&2
    exit 1
    ;;
esac
EOF
chmod 700 "$fake_curl"

export CURL_LOG="$work_dir/curl.log"
export LIVE_HEAD_SHA='2222222222222222222222222222222222222222'
export REVIEWS_RESPONSE='[
  {"id":101,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111"},
  {"id":102,"state":"APPROVED","commit_id":"2222222222222222222222222222222222222222"}
]'
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222"
if ! grep -q '/pulls/42/reviews/101/dismissals' "$CURL_LOG"; then
  echo "FAIL: approved review was not dismissed" >&2
  exit 1
fi
if grep -q '/pulls/42/reviews/102/dismissals' "$CURL_LOG"; then
  echo "FAIL: approval for the current head was dismissed" >&2
  exit 1
fi
if grep -q 'test-token' "$CURL_LOG"; then
  echo "FAIL: token was exposed in curl arguments" >&2
  exit 1
fi

: > "$CURL_LOG"
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  true \
  "Security policy" \
  "2222222222222222222222222222222222222222"
if ! grep -q '/issues/42/comments' "$CURL_LOG"; then
  echo "FAIL: dry run did not create a pull request comment" >&2
  exit 1
fi
if grep -q '/dismissals' "$CURL_LOG"; then
  echo "FAIL: dry run dismissed an approval" >&2
  exit 1
fi

: > "$CURL_LOG"
LIVE_HEAD_SHA='3333333333333333333333333333333333333333'
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222"
if grep -q '/dismissals' "$CURL_LOG"; then
  echo "FAIL: an outdated workflow dismissed approvals on a newer pull request head" >&2
  exit 1
fi
LIVE_HEAD_SHA='2222222222222222222222222222222222222222'

REVIEWS_RESPONSE='[{"id":103,"state":"APPROVED","commit_id":null}]'
if GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222" >/dev/null 2>&1; then
  echo "FAIL: malformed approved-review data should fail closed" >&2
  exit 1
fi

: > "$CURL_LOG"
REVIEWS_PAGINATED=true
export REVIEWS_PAGINATED
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222"
if ! grep -q '/pulls/42/reviews/201/dismissals' "$CURL_LOG"; then
  echo "FAIL: an approval on the second reviews page was not dismissed" >&2
  exit 1
fi
unset REVIEWS_PAGINATED

artifact_source="$work_dir/artifact-source"
mkdir "$artifact_source"
printf '%s\n%s\n' \
  '1111111111111111111111111111111111111111' \
  '2222222222222222222222222222222222222222' \
  > "$artifact_source/shas.txt"
ARTIFACT_ZIP="$work_dir/valid-artifact.zip"
export ARTIFACT_ZIP
(cd "$artifact_source" && zip -q "$ARTIFACT_ZIP" shas.txt)

downloaded_shas="$work_dir/downloaded-shas.txt"
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" RUNNER_TEMP="$work_dir" \
  "$repo_root/latest_artifact.sh" \
  owner/repository \
  42 \
  feature/security \
  123 \
  dismiss-stale-approvals-shas \
  "$downloaded_shas"
assert_equals \
  $'1111111111111111111111111111111111111111\n2222222222222222222222222222222222222222' \
  "$(cat "$downloaded_shas")" \
  "a valid previous SHA artifact should be accepted"

printf '%s\n%s\n' \
  'not-a-commit-sha' \
  '2222222222222222222222222222222222222222' \
  > "$artifact_source/shas.txt"
ARTIFACT_ZIP="$work_dir/invalid-artifact.zip"
(cd "$artifact_source" && zip -q "$ARTIFACT_ZIP" shas.txt)
if GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" RUNNER_TEMP="$work_dir" \
  "$repo_root/latest_artifact.sh" \
  owner/repository \
  42 \
  feature/security \
  123 \
  dismiss-stale-approvals-shas \
  "$work_dir/invalid-output.txt" >/dev/null 2>&1; then
  echo "FAIL: invalid artifact SHAs should fail closed" >&2
  exit 1
fi

printf '%s\n%s\n' \
  '3333333333333333333333333333333333333333' \
  '2222222222222222222222222222222222222222' \
  > "$artifact_source/shas.txt"
ARTIFACT_ZIP="$work_dir/mismatched-artifact.zip"
(cd "$artifact_source" && zip -q "$ARTIFACT_ZIP" shas.txt)
if GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" RUNNER_TEMP="$work_dir" \
  "$repo_root/latest_artifact.sh" \
  owner/repository \
  42 \
  feature/security \
  123 \
  dismiss-stale-approvals-shas \
  "$work_dir/mismatched-output.txt" >/dev/null 2>&1; then
  echo "FAIL: artifact SHAs not belonging to the selected run should fail closed" >&2
  exit 1
fi

echo "All tests passed."
