# Scheduled security scans

None of these checks runs on a pull request, so none can fail one. Each files a labelled GitHub issue
and closes it when the finding clears.

## Daily dependency sweep (`osv-scan.yml`)

- Scans `package-lock.json` and `tools/requirements-ci.txt` with a pinned `osv-scanner` on `develop`,
  `main`, the newest `develop-v*` branch and the latest release tag. The scanner queries the public
  OSV API, so there is no database to cache.
- `scripts/osv-file-issue.sh` files one issue per ref, titled `Security: dependency vulnerabilities on <ref>`,
  with labels `security`, `security-baseline` and `branch:<ref>`. It looks up the open issue by exact title,
  updates it in place and closes it when the ref has nothing at or above CVSS 7.0. Findings below that
  floor are listed in the same issue, never filed alone.
- A finding with a fixed version carries `expires:` 30 days out; one without carries `review:` and never
  blocks anything. The date survives later runs.
- Advisory text never reaches the issue; only package, version and advisory ids do.
- Manual run: `gh workflow run osv-scan.yml`; the `floor` input lowers the threshold to prove filing.

## XMRig release watch (`xmrig-bump.yml`)

Runs daily. When upstream has a newer release whose notes match `CVE-`, `security` or `vulnerab`, it
files one `Security: XMRig <tag> release notes mention a security fix` issue and labels the bump PR
`security`. The `notes_tag` dispatch input checks one tag's notes without touching the pin.

## Workflow audit (`security.yml`)

The Monday zizmor run files or updates `Security: workflow audit failing on <ref>` when it fails and
closes it when it passes. The `file_issue` dispatch input does the same from a manual run.

`scripts/file-security-issue.sh` is the shared open-or-close step for these two.
