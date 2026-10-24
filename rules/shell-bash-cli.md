---
description: Shell and Bash scripting production discipline, strict mode invariants, defensive quoting, signal trapping, and CLI automation
globs: **/*.{sh,bash,zsh},**/Makefile,**/Dockerfile
alwaysApply: false
---

# Shell Scripting & Bash Automation Production Discipline

> Add these rules to your project if developing or maintaining Bash/POSIX shell scripts, deployment automations, Docker entrypoints, CI/CD pipeline steps, or CLI developer tooling.

## 1. Strict Execution Flags & Fail-Fast Discipline
- **Mandatory Modern Strict Mode**:
  - Every Bash script MUST start with strict error handling flags immediately following the shebang:
    ```bash
    #!/usr/bin/env bash
    set -euo pipefail
    IFS=$'\n\t'
    ```
  - **The Anatomy of Strict Mode**:
    - `set -e`: Exit immediately if any command exits with a non-zero status. Prevents continuing execution past catastrophic failures.
    - `set -u`: Treat unset/unbound variables and parameters as fatal errors. Catches typos and prevents accidental operations on empty strings.
    - `set -o pipefail`: Ensure pipeline exit status is the exit code of the last command to exit with a non-zero status (e.g. `curl -fsSL https://... | grep "foo"` fails if `curl` fails, rather than masking it with `grep`'s exit code).
    - `IFS=$'\n\t'`: Limit internal field splitting to newlines and tabs, eliminating accidental word splitting on standard whitespace spaces.
- **Portable Shebang**:
  - Always use `#!/usr/bin/env bash` instead of hardcoded `#!/bin/bash` (which fails on macOS Homebrew Bash, FreeBSD, NixOS, or non-standard environments).
  - For strictly POSIX-compliant scripts targeting minimal Alpine/busybox containers without Bash:
    ```sh
    #!/bin/sh
    set -eu
    ```

## 2. Defensive Variable Quoting & Word Splitting Immunity
- ❌ **TOTAL BAN ON UNQUOTED VARIABLES**:
  - Never reference a variable without double quotes in command arguments, filenames, or path references:
    ```bash
    # ❌ AI Vulnerability: Breaks on filenames with spaces, triggers glob expansion
    rm -rf $DIR/$FILE
    cp $SOURCE $DEST

    # ✅ Production Invariant: Quoted variable expansions
    rm -rf "${DIR}/${FILE}"
    cp "${SOURCE}" "${DEST}"
    ```
- **Modern Test Brackets (`[[ ... ]]` vs `[ ... ]`)**:
  - In Bash scripts, prefer modern conditional expressions `[[ ... ]]` over legacy POSIX `[ ... ]`:
    - `[[ ... ]]` eliminates word splitting and pathname expansion inside test expressions.
    - Supports regex matching: `[[ "${version}" =~ ^v[0-9]+\.[0-9]+ ]]`.
    - Supports standard boolean operators: `[[ -f "${file}" && -r "${file}" ]]`.
- **Parameter Expansion & Default Guards**:
  - Always guard required variables with `${VAR:?Error message}` to fail immediately with an explicit diagnostic:
    ```bash
    TARGET_DIR="${1:?Error: Target directory argument is required}"
    ENVIRONMENT="${ENV:-development}" # Fallback default
    ```
- **Array Expansion Discipline**:
  - Always quote array expansions: `"${args[@]}"`.
  - ❌ **NEVER use `$args` or `${args[*]}`** when passing argument lists; they flatten elements into a single space-separated string or split across whitespace boundaries.

## 3. The `local` Variable Assignment Exit Code Masking Trap
- ❌ **NEVER COMBINE `local` DECLARATION WITH COMMAND SUBSTITUTION**:
  - In Bash, `local` is a built-in command that returns exit code `0`. Combining declaration and assignment masks the exit status of the subshell command even under `set -e`:
    ```bash
    # ❌ CATASTROPHIC BUG: If git rev-parse fails, exit code 0 of 'local' overrides it!
    # The script continues running with an empty commit_hash variable.
    local commit_hash="$(git rev-parse HEAD)"

    # ✅ Production Invariant: Declare first, assign second
    local commit_hash
    commit_hash="$(git rev-parse HEAD)"
    ```

## 4. Deterministic Script Directory Resolution & Path Anchoring
- **Self-Resolving Script Location**:
  - Never assume a script is invoked from its containing directory. Scripts executed via absolute paths, relative paths, symlinks, or cron jobs must resolve their own location deterministically:
    ```bash
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
    ```
- **Safe Directory Navigation**:
  - Always guard `cd` commands to prevent executing subsequent commands in the wrong directory if `cd` fails:
    ```bash
    cd "${TARGET_DIR}" || { echo "Failed to enter ${TARGET_DIR}" >&2; exit 1; }
    ```

## 5. Temporary Files, Signal Trapping & Atomic Cleanup
- **Secure Temporary Directories with `mktemp`**:
  - ❌ **NEVER hardcode temporary files** (`/tmp/temp.txt`). They are vulnerable to symlink hijacking and collision attacks.
  - Always allocate dynamic temporary workspaces using `mktemp`:
    ```bash
    TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'app_worker')"
    ```
- **Deterministic Cleanup Traps**:
  - Register a trap handler to guarantee temp files and dangling child processes are pruned on exit, interrupt, or termination signals:
    ```bash
    cleanup() {
      local exit_code=$?
      if [[ -d "${TMP_DIR:-}" ]]; then
        rm -rf "${TMP_DIR}"
      fi
      exit "${exit_code}"
    }
    trap cleanup EXIT INT TERM
    ```
- **Atomic File Writes**:
  - Never write directly into a destination file consumed by concurrent processes. Write to a temporary file on the same filesystem, then execute an atomic rename:
    ```bash
    generate_config > "${DEST_FILE}.tmp.$$"
    mv -f "${DEST_FILE}.tmp.$$" "${DEST_FILE}"
    ```

## 6. Stream Processing & Safe Line-by-Line Iteration
- ❌ **NEVER ITERATE OVER FILES WITH `for line in $(cat file)`**:
  - `$(cat file)` splits on all whitespace (spaces, tabs, newlines) and chokes on lines with spaces or empty lines.
- **Canonical `while read` Loop**:
  - Read text files line-by-line safely using `IFS= read -r`:
    ```bash
    while IFS= read -r line || [[ -n "${line}" ]]; do
      # -r prevents backslash escaping
      # [[ -n "${line}" ]] ensures the final line without a trailing newline is processed
      [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue # Skip empty/comment lines
      process_entry "${line}"
    done < "${input_file}"
    ```
- **Safe Command Output Iteration with Process Substitution**:
  - When iterating over command output, avoid pipes that spawn subshells (which isolate mutated variables):
    ```bash
    # Process substitution preserves outer shell variable state:
    while IFS= read -r file; do
      total_files=$((total_files + 1))
    done < <(find . -type f -name "*.log")
    ```

## 7. Destructive Operations & Guarded Deletions
- ❌ **ANTI-CATASTROPHIC DELETION GUARD**:
  - A blank or undefined variable in `rm -rf "${VAR}/*"` results in executing `rm -rf /*`, wiping the entire root filesystem!
  - Always enforce parameter presence validation before any recursive delete:
    ```bash
    # ❌ Dangerous if CACHE_DIR is empty or undefined:
    rm -rf "${CACHE_DIR}/*"

    # ✅ Production Guard: Unset or empty parameter triggers instant fatal exit
    rm -rf "${CACHE_DIR:?Error: CACHE_DIR must be non-empty and set}"/*
    ```
  - Explicitly verify that the target directory exists and is not root (`/`):
    ```bash
    if [[ -n "${BUILD_DIR:-}" && "${BUILD_DIR}" != "/" && -d "${BUILD_DIR}" ]]; then
      rm -rf "${BUILD_DIR:?}"
    fi
    ```

## 8. Standard I/O Separation & Logging Ergonomics
- **Machine Data vs Human Diagnostics**:
  - **STDOUT (`1`)**: Reserved exclusively for machine-readable payloads (JSON, file paths, IDs) intended for downstream pipe consumption.
  - **STDERR (`2`)**: Reserved for human diagnostic logs, progress status, and error messages.
    ```bash
    log_info() {
      echo -e "\033[0;34m[INFO]\033[0m $*" >&2
    }
    log_err() {
      echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
    }
    ```
- **TTY Detection for Color Output**:
  - Only emit ANSI color escape sequences when STDERR is connected to an interactive terminal:
    ```bash
    if [[ -t 2 ]]; then
      RED='\033[0;31m'; NC='\033[0m'
    else
      RED=''; NC=''
    fi
    echo -e "${RED}Deployment failed${NC}" >&2
    ```

## 9. Dependency Checking & CLI Invariants
- **Portable Binary Availability Verification**:
  - ❌ **NEVER use `which <cmd>`**: It is an external binary, behaves inconsistently across OS distributions, and returns 0 even for aliases or builtins on some platforms.
  - Always use Bash built-in `command -v`:
    ```bash
    require_cmd() {
      local cmd="$1"
      if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Error: Required binary '${cmd}' is not installed or not in PATH." >&2
        exit 127
      fi
    }
    require_cmd "jq"
    require_cmd "curl"
    ```
- **Non-Interactive Execution Invariant**:
  - Scripts running in CI/CD, agent harnesses, or Docker builds must pass non-interactive flags to prevent hanging forever on user prompts:
    ```bash
    export DEBIAN_FRONTEND=noninteractive
    export CI=true
    apt-get update -y -qq
    npm ci --no-audit --prefer-offline
    ```

## 10. Robust CLI Option Parsing with `getopts`
- For scripts accepting CLI flags, use the standard `getopts` built-in rather than fragile manual argument slicing:
  ```bash
  usage() {
    echo "Usage: $0 [-e <env>] [-v] <target_path>" >&2
    exit 1
  }

  ENV="production"
  VERBOSE=0

  while getopts "e:vh" opt; do
    case "${opt}" in
      e) ENV="${OPTARG}" ;;
      v) VERBOSE=1 ;;
      h) usage ;;
      *) usage ;;
    esac
  done
  shift $((OPTIND - 1))

  TARGET_PATH="${1:-}"
  if [[ -z "${TARGET_PATH}" ]]; then
    usage
  fi
  ```
