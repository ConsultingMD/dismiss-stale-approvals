#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/assertions.sh
source "$repo_root/tests/lib/assertions.sh"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dismiss-stale-approvals-review-tests.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

fake_curl="$work_dir/fake-curl"
cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "$CURL_LOG"
printf '\n' >> "$CURL_LOG"

url=
page=1
while (( $# > 0 )); do
  case "$1" in
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
assert_file_contains \
  '/pulls/42/reviews/101/dismissals' \
  "$CURL_LOG" \
  "an approval for an older commit should be dismissed"
assert_file_not_contains \
  '/pulls/42/reviews/102/dismissals' \
  "$CURL_LOG" \
  "an approval for the current head must be preserved"
assert_file_not_contains \
  'test-token' \
  "$CURL_LOG" \
  "the token must not be exposed in curl arguments"

: > "$CURL_LOG"
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  true \
  "Security policy" \
  "2222222222222222222222222222222222222222"
assert_file_contains \
  '/issues/42/comments' \
  "$CURL_LOG" \
  "a dry run should create a pull request comment"
assert_file_not_contains \
  '/dismissals' \
  "$CURL_LOG" \
  "a dry run must not dismiss an approval"

: > "$CURL_LOG"
LIVE_HEAD_SHA='3333333333333333333333333333333333333333'
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222"
assert_file_not_contains \
  '/dismissals' \
  "$CURL_LOG" \
  "an outdated workflow must not dismiss approvals on a newer head"
LIVE_HEAD_SHA='2222222222222222222222222222222222222222'

REVIEWS_RESPONSE='[{"id":103,"state":"APPROVED","commit_id":null}]'
if GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222" >/dev/null 2>&1; then
  fail "malformed approved-review data should fail closed"
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
assert_file_contains \
  '/pulls/42/reviews/201/dismissals' \
  "$CURL_LOG" \
  "an approval on the second reviews page should be dismissed"

echo "Approval-dismissal tests passed."
