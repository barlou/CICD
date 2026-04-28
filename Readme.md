# CICD Framework — barlou/CICD

![CI](https://github.com/barlou/scheduler/actions/
workflows/ci.yml/badge.svg?branch=main)
![Release](https://img.shields.io/github/v/release/barlou/scheduler)
![Python](https://img.shields.io/badge/python-3.11+-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Security](https://img.shields.io/badge/security-gitleaks-red)

> **A complete, modular, and reusable CI/CD system built on GitHub Actions — designed to industrialise the deployment of data, ML, and application projects without configuration duplication.**

---

## Overview

This repository is the **core of the CI/CD system**. It contains reusable GitHub Actions workflows (called *templates*) that can be included in any private project via a simple reference. Every consumer project automatically benefits from the full pipeline without rewriting any logic.

```
barlou/CICD (public)          Private projects (N projects)
├── _build.yml       ←────── ci-template.yml
├── _deploy.yml      ←────── (one line per workflow)
├── _verify.yml      ←────── secrets: inherit
├── _release.yml     ←────── with: module, environment...
├── _security.yml    ←──────
└── _notify.yml      ←──────
```

---

## Global Architecture

### Branch strategy

```
feat/${ticket}  ──┐
fix/${ticket}   ──┤  manual merge → develop
                  │
develop           ├── manual trigger → INT deployment
                  ├── manual trigger → UAT deployment
                  │
                  │  manual merge → release
                  ↓
release        → security scan (blocking)
                  if passed → automatic merge → main
                  ↓
main           → build → deploy production → verify → release tag
```

### Full pipeline flow

```
┌─────────────────────────────────────────────────────────────────┐
│                         RELEASE BRANCH                          │
│                                                                 │
│  push to release                                                │
│       ↓                                                         │
│  _security.yml  ──── gitleaks  (secrets detection)             │
│                 ──── semgrep   (SAST)                           │
│                 ──── pip-audit (dependency vulnerabilities)     │
│                       ↓ (if all pass)                           │
│              automatic merge release → main                     │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                          MAIN BRANCH                            │
│                                                                 │
│  push to main                                                   │
│       ↓                                                         │
│  _build.yml   ── preflight checks                               │
│               ── server version check (jars, tools, airflow)    │
│               ── jar download (wget)                            │
│               ── fetch tools repo (pinned tag)                  │
│               ── fetch airflow repo (pinned tag)                │
│               ── packaging tar.gz                               │
│       ↓                                                         │
│  _deploy.yml  ── transfer archive to server                     │
│               ── execute deploy.sh                              │
│               ── fetch secrets from SSM                         │
│               ── render config.json from template               │
│               ── install components                             │
│               ── backup before deployment                       │
│       ↓                                                         │
│  _verify.yml  ── server-side verification                       │
│               ── check success log marker                       │
│               ── check config.json rendered                     │
│               ── check component versions                       │
│               ── check disk space                               │
│               ── automatic rollback on failure                  │
│       ↓                                                         │
│  _release.yml ── compute next version (semver)                  │
│               ── grouped changelog generation                   │
│               ── create annotated tag                           │
│               ── create GitHub Release                          │
│       ↓                                                         │
│  _notify.yml  ── pipeline result notification                   │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                     INT / UAT (manual)                          │
│                                                                 │
│  workflow_dispatch → environment: INT | UAT                     │
│       ↓                                                         │
│  _build.yml → _deploy.yml → _verify.yml → _notify.yml          │
└─────────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
barlou/CICD/
├── .github/
│   └── workflows/
│       ├── _build.yml           # project packaging
│       ├── _deploy.yml          # server deployment
│       ├── _verify.yml          # post-deployment verification
│       ├── _release.yml         # semantic versioning + GitHub Release
│       ├── _security.yml        # security scan (gitleaks, semgrep, pip-audit)
│       └── _notify.yml          # pipeline result notification
├── tools/
│   ├── deploy.sh                # deployment script executed on server
│   └── rollback.sh              # rollback script executed on server
└── docs/
    └── usage.md                 # integration guide for projects
```

---

## Detailed Workflows

### `_build.yml` — Build deployment package

**Trigger:** `workflow_call` from `ci-template.yml`

**What it does:**

1. **Module resolution** — derives module name from repository name if not provided
2. **Read `cicd.config.yml`** — parses project configuration (components, versions, secrets map, template path)
3. **Preflight checks** — validates repository structure before any packaging:
   - Presence of `src/` directory
   - Presence of `requirements.txt`
   - Presence of `airflow/airflow_job.yml` if required
   - Validity of `config.template.json` (JSON structure + placeholders covered)
   - Consistency of component declarations
4. **Server version check** — single SSH call to check installed versions of jars, tools, and airflow before any download
5. **Jar download** via `wget` (only if version differs or `force_jars=true`)
6. **Fetch tools repository** at pinned tag (only if version differs)
7. **Fetch airflow repository** at pinned tag (only if version differs)
8. **Packaging** — creates `tar.gz` archive containing:
   - Module `src/`
   - Module `tests/`
   - Module `requirements.txt`
   - `config/config.template.json` (no credentials)
   - `airflow/airflow_job.yml` if required
   - `method/business/` always fresh
   - `jars.tar.gz` if needed
   - `utils/` if needed
   - `airflow/` framework if needed
9. **Upload** archive and manifest as GitHub artifacts

**Outputs:**

```yaml
archive_name      # name of the created archive
module_name       # resolved module name
need_jars         # true/false from cicd.config.yml
need_tools        # true/false
need_airflow      # true/false
need_method       # true/false
need_airflow_job  # true/false
skip_tools        # true if server version = required version
skip_airflow      # true if server version = required version
jars_version      # jars version
tools_version     # tools version
airflow_version   # scheduler version
airflow_id        # target airflow instance
ssm_prefix        # SSM prefix for secret fetch
secrets_map       # placeholder → SSM key mapping (JSON)
```

---

### `_deploy.yml` — Server deployment

**Trigger:** `workflow_call`, requires outputs from `_build.yml`

**What it does:**

1. **Module resolution** — same logic as `_build.yml`
2. **Download archive** from GitHub artifacts
3. **Archive verification** — presence and contents
4. **Context preparation** — generates `deploy_env.sh` (no secrets):
   ```bash
   export MODULE_NAME="data_ingestion"
   export ENVIRONMENT="production"
   export DEPLOYMENT_ID="deploy_12345_20250115_010000"
   export SSM_PREFIX="/production/data_ingestion"
   export NEED_JARS="true"
   export SKIP_TOOLS="false"
   # ...
   ```
5. **SSH setup** via `ssh-keyscan` + key from GitHub Secrets
6. **Transfer** — `scp` of archive, `deploy_env.sh`, and `deploy.sh` to server
7. **Remote execution** — `deploy.sh` on the server:
   - Fetch secrets from AWS SSM
   - Backup current state before any modification
   - Install components (jars, utils, airflow, method/business, module)
   - Render `config.json` from template with SSM values
8. **Cleanup** — remove temporary files from server home (`if: always()`)
9. **Summary** — recap table in GitHub Actions interface

**Output:** `deployment_id` — unique identifier used by `_verify.yml` and `_notify.yml`

---

### `deploy.sh` — Server-side deployment script

Executed directly on the server after transfer. Sourced from `deploy_env.sh`.

**Execution structure:**

```bash
fetch_all_secrets()    # dynamic fetch from SSM via secrets_map
create_backup()        # snapshot before any modification
install_jars()         # extract jars.tar.gz if present in archive
install_tools()        # copy utils/ if present
install_airflow()      # copy airflow/ + run setup.sh
install_method()       # copy method/business/ (always fresh)
install_module()       # copy src/, config/, tests/ + render config.json
```

**Server directory structure managed:**

```
~/deployments/
├── {module}/
│   ├── config/
│   │   ├── config.template.json   ← delivered by build
│   │   └── config.json            ← rendered by deploy.sh from SSM
│   ├── src/
│   ├── tests/
│   ├── requirements.txt
│   └── airflow/
│       └── airflow_job.yml
├── jars/
│   └── VERSION
├── utils/
│   └── VERSION
├── airflow/
│   ├── VERSION
│   └── framework/
├── method/
│   └── business/
└── .backups/
    └── {deployment_id}/           ← snapshot for rollback
```

**Secret management — zero credentials in artifact:**

```
GitHub Secrets
    ↓ (AWS credentials only)
AWS SSM (SecureString)
    ↓ (fetched at runtime on server)
config.json (chmod 600, never transferred)
```

---

### `_verify.yml` — Post-deployment verification

**Trigger:** `workflow_call`, after `_deploy.yml`

**What it checks on the server:**

1. **Success log** — presence of `DEPLOYMENT COMPLETED SUCCESSFULLY` marker
2. **Module directory** — existence of `~/deployments/{module}/`
3. **`config.json`** — presence and JSON validity (SSM render succeeded)
4. **`src/`** — not empty
5. **Jars** — installed version = required version
6. **Utils** — installed version = required version (warn if `skip_tools=true`)
7. **Airflow** — installed version = required version (warn if `skip_airflow=true`)
8. **Method/business** — presence and `config.json` rendered in subdirectories
9. **Disk space** — alert if > 90%

**Automatic rollback on failure:**

```
verify fails
    ↓
transfer rollback.sh to server
    ↓
rollback.sh restores from .backups/{deployment_id}/
    ├── module/          → ~/deployments/{module}/
    ├── method_business/ → ~/deployments/method/business/
    ├── jars_VERSION     → ~/deployments/jars/VERSION
    ├── utils_VERSION    → ~/deployments/utils/VERSION
    └── airflow/         → ~/deployments/airflow/ + re-run setup.sh
    ↓
pipeline marked as failed
```

**Output:** `verify_status` — `success` or `failure`

---

### `_release.yml` — Semantic versioning

**Trigger:** push to `main` (after merge from `release`)

**Commit convention:**

| Prefix | Bump | Example |
|---|---|---|
| `fix:` | PATCH → `1.0.1` | `fix: handle null in parser` |
| `feat:` | MINOR → `1.1.0` | `feat: add parquet writer` |
| `breaking:` | MAJOR → `2.0.0` | `breaking: remove legacy API` |

**Tag format:** `{module}-v{X}.{Y}.{Z}`
```
data_ingestion-v1.0.0
data_ingestion-v1.0.1   ← fix
data_ingestion-v1.1.0   ← feat
data_ingestion-v2.0.0   ← breaking
```

**Bump rules:**
- **Highest priority wins** — one `feat:` and two `fix:` since last tag → MINOR bump
- **Semver reset** — MAJOR bump resets MINOR and PATCH to 0
- **Delta scan only** — only commits on `main` since the last tag

**Generated GitHub Release:**

```markdown
## data_ingestion v1.1.0

> **Bump type:** Minor — new feature
> **Previous version:** data_ingestion-v1.0.2

### Features
- feat: add parquet writer (`abc1234`) — Louis

### Fixes
- fix: handle null in parser (`def5678`) — Louis
- fix: correct schema validation (`ghi9012`) — Louis

### Other changes
- chore: update dependencies (`jkl3456`) — Louis
```

---

### `_security.yml` — Security scan

**Trigger:** push to `release` (blocking before merge to main)

**3 parallel jobs:**

#### Gitleaks — secret detection
- **Delta scan only** — commits on `release` not yet on `main`
- Detects: API keys, tokens, passwords, hardcoded credentials
- JSON report uploaded as artifact (7 days retention)

#### Semgrep — static analysis (SAST)
- Scans **only files modified in the delta**
- OSS rules (no token, no account required): `p/python`, `p/owasp-top-ten`, `p/secrets`, `p/ci`
- Skipped if no Python/Scala/Java/YAML files modified

#### pip-audit — dependency vulnerabilities
- Verifies **all packages have a version constraint** before scanning
- Blocks if package has no version: `pandas` → error, `pandas>=2.0.0,<3.0.0` → OK
- Scans known CVEs with fix version suggestions

**Security gate — configurable per tool:**

```yaml
# ci-template.yml
with:
  gitleaks_allow_failure:  false   # blocking by default
  semgrep_allow_failure:   false   # blocking by default
  pip_audit_allow_failure: false   # blocking by default
```

**If all scans pass → automatic merge `release → main`**

---

### `_notify.yml` — Notification

**Trigger:** `if: always()` — runs whether pipeline succeeds or fails

**On success:**
- Confirmation message with module + environment + deployment_id

**On failure:**
- Fetch logs from server via SSH
- Upload logs to S3 (`s3://{bucket}/logs/failures/{module}/{deployment_id}/`)
- Slack notification (if `SLACK_WEBHOOK_URL` configured)
- Exit with error to mark pipeline red

---

## Project Configuration — `cicd.config.yml`

Each consumer project declares a `cicd.config.yml` file at its root:

```yaml
# my-project/cicd.config.yml
module: ""   # empty = derived from repository name

components:
  jars:
    enabled: true
    version: "2.1.0"
    files:
      spark-core: "https://github.com/barlou/jars/releases/download/v2.1.0/spark-core.jar"
      delta-lib:  "https://github.com/barlou/jars/releases/download/v2.1.0/delta-lib.jar"

  airflow:
    enabled: true
    instance_id: "airflow-prod-1"
    version: "scheduler-v1.0.0"
    repo: "barlou/scheduler"

  tools:
    enabled: true
    version: "v1.2.1"
    repo: "barlou/tools"

  method:
    enabled: true

  airflow_job:
    enabled: true   # airflow/airflow_job.yml present in this project

update:
  force_jars:    false   # force re-download even if version matches
  force_tools:   false
  force_airflow: false

config_template:
  path: "config/config.template.json"   # this project owns this file

# Mapping placeholder → SSM key
secrets_map:
  DB_HOST:          "db/host"
  DB_PASSWORD:      "db/password"
  ACCESS_KEY:       "access_key"
  SECRET_KEY:       "secret_key"
  BUCKET_NAME:      "storage/bucket"
  TOOLS_ACCESS_KEY: "storage/access_key"
  TOOLS_SECRET_KEY: "storage/secret_key"

ssm_prefix: "/production/data_ingestion"
```

---

## Config Template — Zero credentials in the artifact

Each project owns its `config/config.template.json` with placeholders:

```json
{
  "module": "{{ MODULE }}",
  "deployment_date": "{{ DEPLOYMENT_DATE }}",
  "database": {
    "host":     "{{ DB_HOST }}",
    "password": "{{ DB_PASSWORD }}"
  },
  "exchange": {
    "access_key": "{{ ACCESS_KEY }}",
    "secret_key": "{{ SECRET_KEY }}"
  }
}
```

The template is delivered as-is in the artifact. Real values are fetched from AWS SSM at deploy time on the server and the final `config.json` is written with `chmod 600`.

---

## Project Integration — `ci-template.yml`

Copy this file to `.github/workflows/ci-template.yml` in the project:

```yaml
name: CI/CD Pipeline

on:
  push:
    branches:
      - main
      - release
  workflow_dispatch:
    inputs:
      environment:
        description: "Target environment"
        required: true
        type: choice
        options: [INT, UAT, production]
      module:
        required: false
        type: string
        default: ""
      force_jars:
        required: false
        type: boolean
        default: false
      force_tools:
        required: false
        type: boolean
        default: false
      force_airflow:
        required: false
        type: boolean
        default: false
      gitleaks_allow_failure:
        required: false
        type: boolean
        default: false
      semgrep_allow_failure:
        required: false
        type: boolean
        default: false
      pip_audit_allow_failure:
        required: false
        type: boolean
        default: false

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

jobs:

  security:
    name: Security gate
    if: github.ref == 'refs/heads/release'
    uses: barlou/CICD/.github/workflows/_security.yml@main
    with:
      gitleaks_allow_failure:  ${{ inputs.gitleaks_allow_failure || false }}
      semgrep_allow_failure:   ${{ inputs.semgrep_allow_failure  || false }}
      pip_audit_allow_failure: ${{ inputs.pip_audit_allow_failure || false }}
    secrets: inherit

  build:
    name: Build
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    uses: barlou/CICD/.github/workflows/_build.yml@main
    with:
      module:        ${{ inputs.module || '' }}
      force_jars:    ${{ inputs.force_jars    || false }}
      force_tools:   ${{ inputs.force_tools   || false }}
      force_airflow: ${{ inputs.force_airflow || false }}
    secrets: inherit

  # ... deploy, verify, release, notify
  # see full ci-template.yml in this repository
```

---

## Commit Convention

All projects using this CI/CD must follow this convention:

```
<type>: <short description>

Valid types:
  fix:       bug fix                        → PATCH bump
  feat:      new feature                    → MINOR bump
  breaking:  incompatible change            → MAJOR bump
  docs:      documentation only             → no bump
  chore:     maintenance, dependencies      → no bump
  refactor:  refactoring without bug/feat   → no bump
  perf:      performance improvement        → no bump
  test:      add/modify tests               → no bump
  ci:        CI/CD modification             → no bump

Examples:
  fix: handle null balance in edge case
  feat: add Parquet output format support
  breaking: rename config_path parameter to config
  chore: upgrade boto3 to 1.34.0
```

The `_release.yml` pipeline reads commits since the last tag and automatically computes the next version number.

---

## Required Secrets per Repository

### Minimum required secrets

```
GH_TOKEN                      # GitHub PAT — push tags, create releases, fetch private repos
SERVER_HOST                   # server IP or hostname
SERVER_USERNAME               # SSH username
SERVER_SSH_KEY                # SSH private key (PEM format)
CONFIG_ACCESS_KEY_ID          # CLOUD credentials
CONFIG_SECRET_ACCESS_KEY      # CLOUD credentials
```

### Optional secrets

```
SLACK_WEBHOOK_URL             # Slack notifications
CONFIG_BUCKET_NAME            # S3 bucket for error log upload
CONFIG_REGION                 # Region (default: eu-west-1)
```

### What does NOT need to be in GitHub Secrets

Everything in `secrets_map` of `cicd.config.yml` — these values live in AWS SSM and are fetched directly on the server at deploy time. This includes: database passwords, third-party API keys, cloud storage credentials, etc.

---

## Version Pinning

Workflows are referenced with a tag to guarantee stability:

```yaml
uses: barlou/CICD/.github/workflows/_build.yml@main
```

In stabilised production, switch to an explicit tag:

```yaml
uses: barlou/CICD/.github/workflows/_build.yml@v1.2.0
```

To upgrade, do a find/replace of the tag in `ci-template.yml`. No other file needs modifying.

---

## Shared Component Version Check

The pipeline avoids re-deploying components already at the correct version. A single SSH check is performed before the build:

```
Current server              Required in cicd.config.yml    Action
jars:    VERSION=2.0.0      jars.version=2.1.0            → download + deploy
utils:   VERSION=1.2.1      tools.version=1.2.1           → skip (already up to date)
airflow: VERSION=1.0.0      airflow.version=1.1.0         → fetch + deploy
```

Force re-deployment even if version matches:

```yaml
# In ci-template.yml workflow_dispatch
force_jars:    true
force_tools:   true
force_airflow: true
```

---

## Consumer Project Structure

```
my-project/
├── .github/
│   └── workflows/
│       └── ci-template.yml          # copied from barlou/CICD
├── cicd.config.yml                  # pipeline configuration
├── config/
│   └── config.template.json         # credentials template (no values)
├── airflow/
│   └── airflow_job.yml              # scheduler configuration (if applicable)
├── {module}/
│   ├── src/
│   │   └── main.py
│   ├── tests/
│   └── requirements.txt
└── method/
    ├── Logs/
    ├── Result/
    └── Archive/
```

---

## Ecosystem Repositories

| Repository | Visibility | Role |
|---|---|---|
| `barlou/CICD` | Public | Reusable CI/CD workflow templates (this repository) |
| `barlou/scheduler` | Private | Airflow orchestration framework |
| `barlou/tools` | Private | Shared Python library (CloudClient, Logger, etc.) |
| `barlou/{project}` | Private | Consumer business projects |

---

## New Project Integration Checklist

```
□ Create cicd.config.yml at root
□ Create config/config.template.json with placeholders
□ Create airflow/airflow_job.yml (if scheduler required)
□ Ensure requirements.txt exists in the module directory
□ Copy ci-template.yml to .github/workflows/
□ Configure GitHub Secrets:
    □ GH_TOKEN
    □ SERVER_HOST
    □ SERVER_USERNAME
    □ SERVER_SSH_KEY
    □ CONFIG_ACCESS_KEY_ID
    □ CONFIG_SECRET_ACCESS_KEY
□ Configure SSM parameters matching secrets_map
□ First deployment to INT to validate
□ UAT deployment for business validation
□ Merge develop → release → triggers security scan
□ If all passes → automatic merge release → main → production deployment
```

---

## Troubleshooting

### Preflight fails

```
[ERROR] Missing src directory: data_ingestion/src
```
→ Verify that the `src/` directory exists inside the module folder.

---

### Version check fails

```
[ERROR] jars VERSION mismatch — expected 2.1.0, got 2.0.0
```
→ The deployment failed before writing the `VERSION` file. Check the `deploy.sh` logs at `/tmp/deploy_{module}_{id}.log` on the server.

---

### Rollback cannot find backup

```
[ERROR] No backup found at ~/deployments/.backups/{id}
```
→ `deploy.sh` failed before `create_backup()`. This is either the first deployment or the script could not execute. Manual intervention required.

---

### `config.json` not rendered

```
[ERROR] config.json not found — SSM render may have failed
```
→ Check AWS credentials on the server (`aws sts get-caller-identity`) and verify SSM parameters exist at the correct path (`/production/{module}/...`).

---

### Gitleaks blocks the pipeline

```
[ERROR] Gitleaks detected secrets in the delta commits
```
→ A secret was committed. Find it in the JSON report in GitHub artifacts, remove it from history (`git filter-branch` or BFG Repo Cleaner), then rotate the compromised secret value.

---

### pip-audit blocks on missing version constraint

```
[ERROR] The following packages have no version constraint:
  - pandas
```
→ Add a version constraint to `requirements.txt`:
```
# Wrong
pandas

# Correct
pandas>=2.0.0,<3.0.0
```

---

### Security scan passes but merge to main does not trigger

→ Verify the `GH_TOKEN` has `contents: write` and `pull_requests: write` permissions. The automatic merge requires the token to push to `main` which is a protected branch.

---

## References

- [GitHub Actions — Reusable Workflows](https://docs.github.com/en/actions/sharing-automations/reusing-workflows)
- [GitHub Actions — Contexts](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/accessing-contextual-information-about-workflow-runs)
- [GitHub Actions — Encrypted Secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets)
- [Gitleaks](https://github.com/gitleaks/gitleaks)
- [Semgrep OSS](https://semgrep.dev/docs/getting-started/oss-overview)
- [pip-audit](https://pypi.org/project/pip-audit/)
- [AWS SSM Parameter Store](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html)
- [Conventional Commits](https://www.conventionalcommits.org/)
- [Semantic Versioning](https://semver.org/)