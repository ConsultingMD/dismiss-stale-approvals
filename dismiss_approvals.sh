#!/usr/bin/env bash

set -euo pipefail

repository=${1:?repository is required}
pr_number=${2:?pull request number is required}
dry_run=${3:?dry-run value is required}
reason=${4:?dismissal reason is required}
current_head_sha=${5:?current head SHA is required}

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid repository name" >&2
  exit 2
fi
if [[ ! "$pr_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid pull request number" >&2
  exit 2
fi
if [[ "$dry_run" != "true" && "$dry_run" != "false" ]]; then
  echo "dry-run must be either true or false" >&2
  exit 2
fi
if [[ ! "$current_head_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "current head SHA is invalid" >&2
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
    --connect-timeout 10 \
    --max-time 60 \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN") \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "$@"
}

get_live_head_sha() {
  local pull_request
  local live_head_sha
  pull_request=$(github_api "https://api.github.com/repos/${repository}/pulls/${pr_number}")
  live_head_sha=$(jq -er '.head.sha | select(type == "string")' <<< "$pull_request")
  if [[ ! "$live_head_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "GitHub returned an invalid live pull request head SHA" >&2
    return 1
  fi
  printf '%s\n' "$live_head_sha"
}

live_head_sha=$(get_live_head_sha)
if [[ "$live_head_sha" != "$current_head_sha" ]]; then
  echo "::notice::The pull request head changed after this workflow started; skipping stale approval dismissal."
  exit 0
fi

approval_ids=()
page=1
while :; do
  reviews=$(github_api \
    --get \
    --data-urlencode 'per_page=100' \
    --data-urlencode "page=${page}" \
    "https://api.github.com/repos/${repository}/pulls/${pr_number}/reviews")

  jq -e 'type == "array"' >/dev/null <<< "$reviews"
  if ! jq -e '
    all(.[];
      .state != "APPROVED" or
      (
        (.id | type == "number") and
        (.id | floor == . and . > 0) and
        (.commit_id | type == "string") and
        (.commit_id | test("^[0-9a-fA-F]{40}$"))
      )
    )
  ' >/dev/null <<< "$reviews"; then
    echo "GitHub returned an invalid approved-review payload" >&2
    exit 1
  fi

  while IFS= read -r approval_id; do
    if [[ -n "$approval_id" ]]; then
      approval_ids+=("$approval_id")
    fi
  done < <(
    jq -r \
      --arg current_head_sha "$current_head_sha" \
      '.[] |
        select(
          .state == "APPROVED" and
          (.commit_id | ascii_downcase) != ($current_head_sha | ascii_downcase)
        ) |
        .id' <<< "$reviews"
  )

  review_count=$(jq 'length' <<< "$reviews")
  if (( review_count < 100 )); then
    break
  fi
  ((page += 1))
done

if (( ${#approval_ids[@]} == 0 )); then
  echo "::notice::No approvals need to be dismissed."
  exit 0
fi

live_head_sha=$(get_live_head_sha)
if [[ "$live_head_sha" != "$current_head_sha" ]]; then
  echo "::notice::The pull request head changed while reviews were being read; skipping stale approval dismissal."
  exit 0
fi

if [[ "$dry_run" == "true" ]]; then
  body="dismiss-stale-approvals dry run: Would have dismissed ${#approval_ids[@]} approval(s) with reason:

${reason}"
  jq -n --arg body "$body" '{body: $body}' |
    github_api \
      --request POST \
      --data-binary @- \
      "https://api.github.com/repos/${repository}/issues/${pr_number}/comments" >/dev/null
  echo "::notice::Dry run: would dismiss ${#approval_ids[@]} approval(s)."
  exit 0
fi

payload=$(jq -n --arg message "$reason" '{message: $message}')
for approval_id in "${approval_ids[@]}"; do
  if [[ ! "$approval_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "GitHub returned an invalid review ID" >&2
    exit 1
  fi
  github_api \
    --request PUT \
    --data-binary @- \
    "https://api.github.com/repos/${repository}/pulls/${pr_number}/reviews/${approval_id}/dismissals" \
    <<< "$payload" >/dev/null
done

echo "::notice::Dismissed ${#approval_ids[@]} approval(s)."
