# RootingLabs scan-action

Run an autonomous Web/API pentest on [RootingLabs](https://rootinglabs.com) from
your CI pipeline and surface findings as **SARIF** in GitHub code scanning.

> "Ne restez pas aveugle entre deux audits" — a scan on every change, findings
> on the pull request.

## Usage (GitHub)

1. Create an API token in your RootingLabs dashboard and store it as the repo
   secret `ROOTINGLABS_TOKEN`.
2. Add `.github/workflows/rootinglabs.yml`:

```yaml
permissions:
  contents: read
  security-events: write   # required for upload-sarif

jobs:
  pentest:
    runs-on: ubuntu-latest
    steps:
      - id: scan
        uses: RootingLabs/scan-action@v1
        with:
          token: ${{ secrets.ROOTINGLABS_TOKEN }}
          target: https://staging.example.com
          scan-mode: standard     # quick | standard | deep
          fail-on: high           # critical | high | medium | low | none
      - if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: ${{ steps.scan.outputs.sarif-file }}
          category: rootinglabs
```

A ready-to-copy workflow is in [`examples/github-workflow.yml`](examples/github-workflow.yml).

## Inputs

| Input | Default | Notes |
|---|---|---|
| `token` | — | required; RootingLabs API token |
| `target` | — | required; the host is frozen as the scope at launch |
| `api-url` | `https://rootinglabs.com` | |
| `scan-mode` | `standard` | `quick` \| `standard` \| `deep` |
| `fail-on` | `high` | `critical`\|`high`\|`medium`\|`low`\|`none` |
| `sarif-file` | `rootinglabs.sarif` | |
| `wait` | `true` | `false` queues and returns immediately |
| `timeout-minutes` | `60` | |

## Outputs

| Output | Description |
|---|---|
| `scan-id` | id of the scan that was created |
| `status` | final scan status |
| `sarif-file` | path to the written SARIF file |

## GitLab

A GitLab CI job is in [`gitlab/rootinglabs.gitlab-ci.yml`](gitlab/rootinglabs.gitlab-ci.yml).
Note: GitLab's `reports:sast` expects its own schema, not SARIF — the SARIF is
published as an artifact and the job gates on severity.

## Notes

- **Auth is a JWT token today**; it expires. A non-expiring, scope-limited PAT
  for unattended CI is on the roadmap. Rotate the secret when it expires.
- **Cost**: each run spends a scan credit. Gate with `on:` filters (e.g. only
  `main` or `workflow_dispatch`) rather than every push.
