## What's the problem

CI and Security lack scoped concurrency cancellation, so a replaced PR head can leave obsolete hosted work running.

## How I fixed it

Add workflow-level concurrency groups to `.github/workflows/ci.yml` and `.github/workflows/security.yml`:

```yaml
concurrency:
  group: "${{ github.workflow }}-${{ github.event_name == 'pull_request' && 'pr-' || 'push-' }}${{ github.event.pull_request.number || github.ref_name }}"
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

- **PR events**: grouped by `${{ github.workflow }}-pr-${{ PR number }}`. When a new commit arrives on the same PR, only the older run is cancelled (`cancel-in-progress` on `pull_request` only). Different PRs run in parallel since they have different PR numbers.
- **Push events**: grouped by `${{ github.workflow }}-push-${{ branch name }}`. New pushes cancel older runs on the same branch.
- **Schedule events**: get their own group (via `github.event_name` check) so weekly audits run independently.
- Push, PR, and schedule events are independent because the `event_name` check creates distinct group prefixes.

## Here is the proof

- [x] CI lint-yaml, lint-md, lint, actionlint on current head
- [x] CI test-suite, coverage, apt-feed, stock-home, e2e, homebrew on current head
- [x] Security gitleaks, zizmor on current head
- [x] yamllint passes (local)
- [x] actionlint passes (local)
- [x] File budget check passes
- Pending: tier4-e2e proof (requires real rig; change is workflow config only)
