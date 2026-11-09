# dismiss-stale-approvals

A GitHub action to automatically dismiss stale approvals on pull requests.
Unlike the built in GitHub protection, this action will compare the `git range-diff` of the new version against the previous version, and only dismiss approvals if the diff has changed.

## How it works

The action restores the previous pull request head and base SHAs, compares them
with the current commit range, and dismisses only approvals attached to older
commits when the changes cannot be proven equivalent.

See [How dismiss-stale-approvals works](docs/how-it-works.md) for the data
boundaries, end-to-end flow, security behavior, and failure outcomes.

## Usage

1. Add the below workflow to your repository's `.github/workflows` directory.
2. Ensure that this GitHub Action is required for pull requests, which will ensure that PRs cannot be merged until the action has run successfully.
![Screenshot of selecting the `dismiss-stale-approvals` action as a required check](./images/required-status-check.png)

You can make the check required with either:
- Branch protection rules ([see here](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/managing-a-branch-protection-rule))
- Rulesets ([see here](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository))

Run this action in a dedicated job that does not check out or execute pull
request code. Pin the action to a reviewed full-length commit SHA; GitHub
considers that the only immutable action reference.

```yaml
name: Dismiss stale pull request approvals

on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  dismiss_stale_approvals:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      actions: read
      contents: read
      pull-requests: write
    concurrency:
      group: dismiss-stale-approvals-${{ github.event.pull_request.number }}
      cancel-in-progress: true
    steps:
      - name: Dismiss stale pull request approvals
        # Replace this placeholder with a reviewed 40-character commit SHA.
        uses: ConsultingMD/dismiss-stale-approvals@FULL_COMMIT_SHA
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Security and rollout

- Do not use a personal access token. The repository-scoped `GITHUB_TOKEN`
  with the permissions above is sufficient.
- Start with `dry-run: true` and review the resulting comments before making
  the job a required check.
- Workflows triggered by pull requests from forks normally receive a read-only
  token and cannot dismiss reviews. Do not enable write tokens for untrusted
  fork workflows. Prefer GitHub's native stale-review protection for those
  repositories, or design a separately reviewed `pull_request_target` workflow
  that never checks out or executes pull request code.
- Keep this job separate from build and test jobs. A prior step that executes
  untrusted code could otherwise observe credentials used by later processes.
- Pin all actions to full commit SHAs and use dependency automation to review
  updates.

The action fails closed: missing artifacts, invalid data, shallow history, API
errors, and comparison failures all cause existing approvals to be dismissed.
Because `git range-diff` does not evaluate merge commits, a compared range that
contains a merge commit is also conservatively treated as changed.
If dismissal itself fails, the job fails and should remain merge-blocking.

## Testing

Run the complete local suite with:

```bash
./tests/run.sh
```

The runner automatically discovers focused `tests/test_*.sh` files. Add new
regressions to the test file matching the affected behavior, or create another
focused file when introducing a new behavior area. Shared assertions live in
`tests/lib/assertions.sh`.

## Issues and contributions

We (the Graphite team) have limited staffing in this area (mainly due to the need for DSA being a relatively small number of customers), which is why the action is OSS in the first place. It was an issue an enterprise customer asked us for input on while trialing so we created it as the simplest possible solution for the problem as a proof-of-concept. We don't expect it to solve the problem for every single Graphite customer exactly as implemented, which is why some of our other larger customers have forked the repo for their desired use.

Feel free to fork to fit your exact use case, and we'd love back-contributions if you feel they'd be useful for others. Keep in mind that a change may work best as an optional configuration for the action, depending on exactly what the change is, of course.

If we don't respond on GitHub immediately to an issue or PR, feel free to bring it to our attention in our [Community Slack server](community.graphite.com).

## Lack of license

This repository is public source, but protected by copyright per GitHub defaults ([see here](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository#choosing-the-right-license)). Graphite customers have express permission to use this action or a fork in their repositories by default. 
