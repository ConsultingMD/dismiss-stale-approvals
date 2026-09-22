#!/usr/bin/env bash

set -euo pipefail

repository=${1:?repository is required}
pr_number=${2:?pull request number is required}
branch_name=${3:?branch name is required}
current_run_id=${4:?current workflow run ID is required}
artifact_name=${5:?artifact name is required}
output_file=${6:?output file is required}

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid repository name" >&2
  exit 2
fi
if [[ ! "$pr_number" =~ ^[1-9][0-9]*$ ]] || [[ ! "$current_run_id" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid pull request number or workflow run ID" >&2
  exit 2
fi
if [[ ! "$artifact_name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid artifact name" >&2
  exit 2
fi

curl_bin=${CURL_BIN:-curl}

github_api() {
  "$curl_bin" \
    --fail-with-body \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 60 \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN") \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "$@"
}

current_run=$(github_api "https://api.github.com/repos/${repository}/actions/runs/${current_run_id}")
workflow_id=$(jq -er '.workflow_id | select(type == "number")' <<< "$current_run")
echo "Current workflow ID: $workflow_id" >&2

selected_workflow_run=
page=1
while :; do
  workflow_runs=$(github_api \
    --get \
    --data-urlencode 'status=success' \
    --data-urlencode "branch=${branch_name}" \
    --data-urlencode 'per_page=100' \
    --data-urlencode "page=${page}" \
    "https://api.github.com/repos/${repository}/actions/workflows/${workflow_id}/runs")

  jq -e '.workflow_runs | type == "array"' >/dev/null <<< "$workflow_runs"
  selected_workflow_run=$(jq -c \
    --argjson pr_number "$pr_number" \
    '[.workflow_runs[]
      | select(any(.pull_requests[]?; .number == $pr_number))]
      | max_by(.run_number)
      // empty' <<< "$workflow_runs")

  if [[ -n "$selected_workflow_run" ]]; then
    break
  fi

  run_count=$(jq '.workflow_runs | length' <<< "$workflow_runs")
  if (( run_count < 100 )); then
    echo "No successful previous workflow run found for PR $pr_number" >&2
    exit 1
  fi
  ((page += 1))
done
latest_workflow_run_id=$(jq -er '.id | select(type == "number")' <<< "$selected_workflow_run")
expected_head_sha=$(jq -er \
  --argjson pr_number "$pr_number" \
  '.pull_requests[]
    | select(.number == $pr_number)
    | .head.sha
    | select(type == "string")' <<< "$selected_workflow_run")
expected_base_sha=$(jq -er \
  --argjson pr_number "$pr_number" \
  '.pull_requests[]
    | select(.number == $pr_number)
    | .base.sha
    | select(type == "string")' <<< "$selected_workflow_run")
for sha in "$expected_head_sha" "$expected_base_sha"; do
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "Previous workflow run contains an invalid pull request SHA" >&2
    exit 1
  fi
done
echo "Previous workflow run ID: $latest_workflow_run_id" >&2

latest_artifact_id=
page=1
while :; do
  artifacts=$(github_api \
    --get \
    --data-urlencode 'per_page=100' \
    --data-urlencode "page=${page}" \
    "https://api.github.com/repos/${repository}/actions/runs/${latest_workflow_run_id}/artifacts")

  jq -e '.artifacts | type == "array"' >/dev/null <<< "$artifacts"
  latest_artifact_id=$(jq -r \
    --arg artifact_name "$artifact_name" \
    '[.artifacts[]
      | select(.name == $artifact_name and .expired == false)]
      | max_by(.id)
      | .id // empty' <<< "$artifacts")

  if [[ -n "$latest_artifact_id" ]]; then
    break
  fi

  artifact_count=$(jq '.artifacts | length' <<< "$artifacts")
  if (( artifact_count < 100 )); then
    echo "No unexpired '$artifact_name' artifact found for workflow run $latest_workflow_run_id" >&2
    exit 1
  fi
  ((page += 1))
done
echo "Previous artifact ID: $latest_artifact_id" >&2

work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/dismiss-stale-approvals-artifact.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
archive="$work_dir/artifact.zip"
payload="$work_dir/shas.txt"

github_api \
  --output "$archive" \
  "https://api.github.com/repos/${repository}/actions/artifacts/${latest_artifact_id}/zip"
unzip -p "$archive" shas.txt > "$payload"

shas=()
while IFS= read -r sha || [[ -n "$sha" ]]; do
  shas+=("$sha")
done < "$payload"
if (( ${#shas[@]} != 2 )); then
  echo "Artifact must contain exactly two SHA lines" >&2
  exit 1
fi
for sha in "${shas[@]}"; do
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "Artifact contains an invalid commit SHA" >&2
    exit 1
  fi
done
if [[ "${shas[0]}" != "$expected_head_sha" ]] ||
  [[ "${shas[1]}" != "$expected_base_sha" ]]; then
  echo "Artifact SHAs do not match the selected workflow run" >&2
  exit 1
fi

umask 077
printf '%s\n%s\n' "${shas[0]}" "${shas[1]}" > "$output_file"

