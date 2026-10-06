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
    printf '%s\n' "$WORKFLOW_RUNS_JSON"
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

sha_a=1111111111111111111111111111111111111111
sha_b=2222222222222222222222222222222222222222
sha_other=3333333333333333333333333333333333333333
sha_current_head=4444444444444444444444444444444444444444
sha_current_base=5555555555555555555555555555555555555555

# GitHub rewrites pull_requests[].head.sha and .base.sha on a finished run to
# the pull request's current head and base. head_sha stays on the commit that
# run executed against. The default fixture models a run for head $sha_a whose
# pull request has since moved to different head and base commits.
workflow_runs_json() {
  local run_head=$1 pr_head=$2 pr_base=$3
  printf '{"workflow_runs":[{"id":88,"run_number":2,%s"pull_requests":[{"number":42,"head":{"sha":"%s"},"base":{"sha":"%s"}}]}]}' \
    "${run_head:+\"head_sha\":\"$run_head\",}" "$pr_head" "$pr_base"
}
WORKFLOW_RUNS_JSON=$(workflow_runs_json "$sha_a" "$sha_current_head" "$sha_current_base")
export WORKFLOW_RUNS_JSON

artifact_source="$work_dir/artifact-source"
mkdir "$artifact_source"
export ARTIFACT_ZIP="$work_dir/artifact.zip"

write_artifact() {
  printf '%s\n%s\n' "$1" "$2" > "$artifact_source/shas.txt"
  rm -f "$ARTIFACT_ZIP"
  (cd "$artifact_source" && zip -q "$ARTIFACT_ZIP" shas.txt)
}

run_latest_artifact() {
  GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" RUNNER_TEMP="$work_dir" \
    "$repo_root/latest_artifact.sh" \
    owner/repository \
    42 \
    feature/security \
    123 \
    dismiss-stale-approvals-shas \
    "$1"
}

# The artifact head equals the run's head_sha. The pull_requests SHAs differ
# because the pull request moved after the run, so they must be ignored.
write_artifact "$sha_a" "$sha_b"
downloaded_shas="$work_dir/downloaded-shas.txt"
run_latest_artifact "$downloaded_shas" >/dev/null 2>&1
assert_equals \
  "$sha_a"$'\n'"$sha_b" \
  "$(cat "$downloaded_shas")" \
  "an artifact matching the run head_sha should be accepted after the pull request moved"

write_artifact 'not-a-commit-sha' "$sha_b"
if run_latest_artifact "$work_dir/invalid-output.txt" >/dev/null 2>&1; then
  fail "invalid artifact SHAs should fail closed"
fi

write_artifact "$sha_a" 'not-a-commit-sha'
if run_latest_artifact "$work_dir/invalid-base-output.txt" >/dev/null 2>&1; then
  fail "an invalid artifact base SHA should fail closed"
fi

write_artifact "$sha_other" "$sha_b"
if run_latest_artifact "$work_dir/mismatched-output.txt" >/dev/null 2>&1; then
  fail "an artifact head that differs from the run head_sha should fail closed"
fi

# Matching the live pull_requests head must not be enough to be accepted.
write_artifact "$sha_current_head" "$sha_current_base"
if run_latest_artifact "$work_dir/live-pr-output.txt" >/dev/null 2>&1; then
  fail "an artifact matching only the live pull request head should fail closed"
fi

write_artifact "$sha_a" "$sha_b"
WORKFLOW_RUNS_JSON=$(workflow_runs_json "" "$sha_current_head" "$sha_current_base")
if run_latest_artifact "$work_dir/missing-run-head-output.txt" >/dev/null 2>&1; then
  fail "a selected run without head_sha should fail closed"
fi

WORKFLOW_RUNS_JSON=$(workflow_runs_json 'not-a-commit-sha' "$sha_current_head" "$sha_current_base")
if run_latest_artifact "$work_dir/invalid-run-head-output.txt" >/dev/null 2>&1; then
  fail "a selected run with a malformed head_sha should fail closed"
fi

echo "Latest-artifact tests passed."
