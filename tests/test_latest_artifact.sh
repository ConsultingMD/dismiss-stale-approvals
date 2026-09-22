#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/assertions.sh
source "$repo_root/tests/lib/assertions.sh"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dismiss-stale-approvals-artifact-tests.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

fake_curl="$work_dir/fake-curl"
cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=
output=
while (( $# > 0 )); do
  case "$1" in
    --output)
      output=$2
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
  fail "invalid artifact SHAs should fail closed"
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
  fail "artifact SHAs not belonging to the selected run should fail closed"
fi

echo "Latest-artifact tests passed."
