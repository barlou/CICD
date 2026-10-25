# Changelog

All notable changes to this project are documented in this file.

---
## [cicd-v1.8.0] - 2026-10-25

## cicd v1.8.0

> **Bump type:** Minor - new feature
> **Previous version:** cicd-v1.7.0

### Features
- feat: allow possibility to use special deployment for api & frontend application ([`69a70b5`](../../commit/69a70b5)) - Louis Barillon

### Fixes
- fix: correct unbound variable ([`6444ca4`](../../commit/6444ca4)) - Louis Barillon


---
---
## [cicd-v1.7.1] - 2026-10-19

## cicd v1.7.1

> **Bump type:** Patch - bug fix
> **Previous version:** cicd-v1.7.0

### Fixes
- fix: correct unbound variable ([`6444ca4`](../../commit/6444ca4)) - Louis Barillon


---
---
## [cicd-v1.7.0] - 2026-10-19

## cicd v1.7.0

> **Bump type:** Minor - new feature
> **Previous version:** cicd-v1.6.1

### Features
- feat: add spark packages to used pyspark on deployed server ([`7f3ec12`](../../commit/7f3ec12)) - Louis Barillon

### Fixes
- fix: correct MODULE_DIR to MODULE for pyproject.toml file build conception ([`99a2308`](../../commit/99a2308)) - Louis Barillon
- fix: correct MODULE_DIR to MODULE for pyproject.toml file build conception ([`3b0290f`](../../commit/3b0290f)) - Louis Barillon


---
---
## [cicd-v1.6.2] - 2026-10-14

## cicd v1.6.2

> **Bump type:** Patch - bug fix
> **Previous version:** cicd-v1.6.1

### Fixes
- fix: correct MODULE_DIR to MODULE for pyproject.toml file build conception ([`99a2308`](../../commit/99a2308)) - Louis Barillon
- fix: correct MODULE_DIR to MODULE for pyproject.toml file build conception ([`3b0290f`](../../commit/3b0290f)) - Louis Barillon


---
---
## [cicd-v1.6.1] - 2026-10-14

## cicd v1.6.1

> **Bump type:** Patch - bug fix
> **Previous version:** cicd-v1.6.0

### Fixes
- fix: correct MODULE_DIR to MODULE for pyproject.toml file build conception ([`1fbc28c`](../../commit/1fbc28c)) - Louis Barillon

### Other
- correct if condition for pyproject.toml ([`42fe069`](../../commit/42fe069)) - Louis Barillon


---
---
## [cicd-v1.6.0] - 2026-10-13

## cicd v1.6.0

> **Bump type:** Minor - new feature
> **Previous version:** cicd-v1.5.3

### Features
- feat: add pyproject.toml to be build on the artifact before being deployed on servers ([`92270d1`](../../commit/92270d1)) - Louis Barillon


---
---
## [cicd-v1.5.3] - 2026-10-09

## cicd v1.5.3

> **Bump type:** Patch - bug fix
> **Previous version:** cicd-v1.5.2

### Fixes
- fix: correct security-report/ folder to avoid untracked and blocked merging code from release to main ([`d68f19d`](../../commit/d68f19d)) - Louis Barillon


---
---
## [cicd-v1.5.2] - 2026-10-09

## cicd v1.5.2

> **Bump type:** Patch - bug fix
> **Previous version:** cicd-v1.5.1

### Fixes
- fix: correct the merge commit to avoid skipping jobs ([`6bd0b05`](../../commit/6bd0b05)) - Louis Barillon
- fix: correct pip audit job name ([`a08a8c9`](../../commit/a08a8c9)) - Louis Barillon
- fix: change default value of pip-audit from failure to success to avoid blocking issue when no requirements.txt file present ([`733ec9f`](../../commit/733ec9f)) - Louis Barillon
- fix: change default value of pip-audit from failure to success to avoid blocking issue when no requirements.txt file present ([`2ecb8f4`](../../commit/2ecb8f4)) - Louis Barillon
- fix: correct the way to handle no requirements.txt present in a folder ([`aa582fb`](../../commit/aa582fb)) - Louis Barillon
- fix: issue while handling conflict from release to main and properly versionning project ([`147086f`](../../commit/147086f)) - Louis Barillon
- fix: add allow failure true for pip_audit because too much package in issues for my project ([`760ebb7`](../../commit/760ebb7)) - Louis Barillon
- fix: correct pip audit args issue ([`b2dafba`](../../commit/b2dafba)) - Louis Barillon
- fix: correct pip audit args issue ([`d81bf2d`](../../commit/d81bf2d)) - Louis Barillon
- fix: correct pip audit args issue ([`9a88d07`](../../commit/9a88d07)) - Louis Barillon
- fix: issue in duplicate job on the CICD ([`d2787a5`](../../commit/d2787a5)) - Louis Barillon

### Other
- Use of develop branch to use new changes instead of main -> to be change later on ([`8c23fb1`](../../commit/8c23fb1)) - Louis Barillon
- Use of develop branch to use new changes instead of main -> to be change later on ([`2fbc42b`](../../commit/2fbc42b)) - Louis Barillon


---
---
## [cicd-v1.5.1] - 2026-05-02

## cicd v1.5.1

> **Bump type:** Patch - bug fix
> **Previous version:** cicd-v1.5.0

### Fixes
- fix: deploy issue ([`fb4b99f`](../../commit/fb4b99f)) - Louis Barillon
- fix: build method ([`c77f94a`](../../commit/c77f94a)) - Louis Barillon


---
---
## [cicd-v1.5.0] - 2026-05-01

## cicd v1.5.0

> **Bump type:** Minor - new feature
> **Previous version:** cicd-v1.4.3

### Features
- feat: add github secret configuraiton for airflow ([`d772b76`](../../commit/d772b76)) - Louis Barillon


---
---
## [cicd-v1.4.3] - 2026-04-29

## cicd v1.4.3

> **Bump type:** Patch - bug fix
> **Previous version:** cicd-v1.4.2

### Fixes
- fix: changelog issues ([`c2d8184`](../../commit/c2d8184)) - Louis Barillon


---
---
## [cicd-v1.4.2] - 2026-04-29

## cicd v1.4.2

> **Bump type:** Patch - bug fix
> **Previous version:** cicd-v1.4.1


---
