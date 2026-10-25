---
description: Agent sandboxing, secure code execution runtimes, MicroVMs, gVisor, Docker isolation, rootless execution, seccomp-bpf syscall filtering, cgroups v2 resource limits, network egress filtering, SSRF prevention, ephemeral snapshot provisioning, process group reaping, and tool execution safety
globs: **/*{sandbox,exec,runner,runtime,container,isolated,workspace,docker,microvm,jail}*.*,**/sandbox/**,**/executors/**,**/runners/**,**/runtimes/**
alwaysApply: false
---

# Agent Sandboxing, Secure Code Execution Runtimes & Tool Isolation Invariants

> Add these rules to your project when architecting, building, or operating execution environments where AI agents (Claude Code, Cursor Agent, OpenCode, Devin, Windsurf Cascade, Pi, LangGraph, CrewAI) execute arbitrary shell commands, code snippets (Python, TypeScript, Go, Bash), automated tests, or containerized tool calls.

---

## 1. Architectural Taxonomy & Threat Modeling

Autonomous agents executing generated code introduce the highest-severity attack surface in modern software systems: **Remote Code Execution (RCE) by design**. Untrusted LLM output can execute destructive shell commands (`rm -rf /`), download cryptocurrency miners, mount denial-of-service floods, pivot to internal networks via Server-Side Request Forgery (SSRF), steal cloud instance credentials (IMDS), or tamper with the host source repository.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              Untrusted Code Execution                                  │
│             (Generated Python, Node.js, Shell, Cargo, Pytest, Git Commands)            │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 1. Isolation Layer Selection (Defense-in-Depth)                                        │
│    • Tier 1 (Multi-Tenant / Production): MicroVMs (Firecracker / Cloud Hypervisor)     │
│    • Tier 2 (Kubernetes / Cloud Native): User-Space Kernels (gVisor runsc / Kata)     │
│    • Tier 3 (Developer Desktop / Local CLI): Rootless OCI + seccomp-bpf + cgroups v2   │
│    • Tier 4 (Deterministic Compute): WebAssembly / WASI Capability Sandboxes (Wasmtime)│
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 2. Security Boundaries & Invariants Enforced at Every Execution Turn                  │
│                                                                                        │
│   [Network Egress]      [Resource Limits]      [Filesystem]         [Process Tree]     │
│   • Air-gapped or       • cgroups v2 pids.max  • Read-Only Base     • Process Groups   │
│     strict allowlist    • Memory hard cap      • CoW OverlayFS      • Tini PID 1 reaper│
│   • Block IMDS 169.254  • CPU CFS quota        • tmpfs for /tmp     • SIGTERM ->       │
│   • Block RFC 1918      • Timeout watchdog     • Noexec, nosuid       SIGKILL cascade  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### The 4 Isolation Tiers

| Tier | Isolation Mechanism | Startup Overhead | Hardware Reqs | Security Boundary | Recommended Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Tier 1: MicroVMs** | **AWS Firecracker**, Cloud Hypervisor | 5ms – 50ms | Hardware Virtualization (`/dev/kvm`) | Hardware-assisted VM boundary (KVM); separate Linux guest kernel | Multi-tenant SaaS code execution (E2B, Modal, Daydream, Cloud Agent backends) |
| **Tier 2: User-Space Kernels** | **gVisor (`runsc`)**, Kata Containers | 100ms – 300ms | Standard Linux Kernel (no KVM strictly required for ptrace/KVM) | Emulated system call interception in user-space Go; zero host kernel exposure | Enterprise Kubernetes clusters, self-hosted agent runners, CI/CD code runners |
| **Tier 3: Hardened Containers** | **Rootless Docker / Podman**, `bwrap`, `nsjail` | 200ms – 500ms | Linux namespaces + cgroups v2 | Linux namespaces + seccomp-bpf filters + capability stripping | Local desktop coding agents (Claude Code, Cursor, OpenCode, Pi harness) |
| **Tier 4: Bytecode Sandboxes** | **Wasmtime / Wasmer (WASI)**, V8 Isolates | 1ms – 5ms | Any CPU Architecture | Capability-based memory safety; zero OS syscall access without host imports | CPU-bound algorithms, JSON/data parsing, regex compilation, custom transforms |

---

## 2. Kernel & System Call Hardening (seccomp-bpf & Capabilities)

Standard Docker containers share the host Linux kernel directly. Without explicit system call filtering and privilege stripping, a kernel vulnerability (e.g., Dirty COW, Dirty Pipe, use-after-free bugs) allows sandbox escape and host takeover.

### The Strict Default-Deny seccomp-bpf Profile
- ❌ **TOTAL BAN ON DEFAULT PERMISSIVE CONTAINERS**:
  - Never run agent containers with `--privileged`, `--cap-add=ALL`, or default Docker seccomp profiles for untrusted LLM code.
- ✅ **Production Invariant**:
  - Apply a custom, strict default-deny seccomp-bpf profile that allows only baseline POSIX execution calls (`read`, `write`, `openat`, `close`, `fstat`, `mprotect`, `brk`, `rt_sigaction`, `futex`, `exit_group`).
  - **Explicitly block and log dangerous system calls**:
    - `ptrace`: Prevents inspecting, hijacking, or injecting code into sibling or parent processes.
    - `bpf`: Prevents loading arbitrary eBPF programs into the host kernel.
    - `clone3` / `unshare`: Blocks unprivileged namespace manipulation and container breakout vectors.
    - `mount` / `umount2` / `pivot_root`: Prevents filesystem hierarchy tampering.
    - `reboot` / `kexec_load`: Blocks host power state manipulation.
    - `init_module` / `delete_module`: Prevents dynamic kernel module insertion.
    - `keyctl` / `add_key`: Blocks Linux kernel keyring exploitation.

### Mandatory Capability Stripping & Flags
```bash
# Production Container Hardening Flags for Agent Code Execution:
docker run --rm -i \
  --cap-drop=ALL \
  --security-opt=no-new-privs:true \
  --security-opt=seccomp=/etc/agent/seccomp-strict.json \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=512m \
  --tmpfs /run:rw,noexec,nosuid,nodev,size=64m \
  --user=10001:10001 \
  --pids-limit=256 \
  --memory=1g \
  --memory-swap=1g \
  --cpus=1.0 \
  --network=none \
  agent-runner:latest
```
- **`--cap-drop=ALL`**: Drops all Linux capabilities (including `CAP_CHOWN`, `CAP_FOWNER`, `CAP_KILL`, `CAP_NET_RAW`, `CAP_SYS_ADMIN`).
- **`--security-opt=no-new-privs:true`**: Prevents child processes from gaining elevated privileges via `setuid` or `setgid` binaries (e.g., `sudo`, `pkexec`, `su`).
- **`--read-only`**: Enforces an immutable root filesystem. Malicious scripts cannot overwrite system binaries (`/bin/sh`, `/usr/lib`) or drop persistence mechanisms.
- **`--user=10001:10001`**: Always execute as an unprivileged UID/GID without `/etc/passwd` root mapping.

---

## 3. Linux cgroups v2 & Resource Quota Hardening

LLM agents will generate code with infinite loops, memory leaks, fork-bombs, or multi-gigabyte disk writes. Without strict Linux cgroups v2 constraints, a single agent run can freeze the host system and exhaust kernel resources.

### 1. Fork-Bomb Defense (`pids.max`)
- ❌ **The Fork-Bomb Host Lockout**:
  - An agent running `:(){ :|:& };:` or a buggy Python script spawning infinite multiprocessing workers exhausts the Linux PID table (default `32768` or `4194304`), crashing the host and preventing SSH recovery.
- ✅ **Production Invariant**:
  - Enforce `pids.max = 128` (or up to `256` for large Node.js / Rust builds). When the limit is reached, `fork()` and `clone()` return `EAGAIN`, halting the fork-bomb instantly without impacting host processes.

### 2. Memory Quotas & OOM Control (`memory.max`)
- **Hard Limit**: Set `memory.max` (e.g., `1GB` or `2GB`).
- **Disable Swap**: Set `memory.swap.max = 0`. Allowing swap causes unconstrained disk thrashing when an agent script consumes excess memory, stalling the entire host hypervisor.
- **Out-of-Memory Score Adjustment**:
  - In container runners, set `/proc/self/oom_score_adj` to `1000` for child execution sandboxes, ensuring the Linux OOM killer reaps the sandbox process first if host system pressure occurs.

### 3. CPU Throttling (`cpu.max`)
- Enforce CFS quotas: e.g., `cpu.max = 100000 100000` (1 core) or `200000 100000` (2 cores). Prevents runaway agent loops from starving the orchestrator or adjacent microVMs.

### 4. Disk & Inode Quotas
- Mount workspace and temporary scratchpads on `tmpfs` with explicit byte limits (`size=512m`) and inode ceilings (`nr_inodes=100000`), preventing disk exhaustion via `dd if=/dev/zero` or million-file creation loops.

---

## 4. Network Isolation & Anti-SSRF Egress Defense

The most critical operational risk of agent code execution is **unauthorized network egress**. If an agent can make arbitrary outbound network requests, it can exfiltrate source code, forge requests to internal corporate intranets, or steal cloud credentials.

### The IMDS Cloud Credential Theft Vector
```
Agent Container ──▶ HTTP GET http://169.254.169.254/latest/meta-data/iam/security-credentials/
                 ◀── Returns AWS Temporary STS AccessKeyId & SecretAccessKey! (Host Pwned)
```

### Production Egress Invariants
- ❌ **TOTAL BAN ON DEFAULT OPEN INTERNET IN UNTRUSTED SANDBOXES**:
  - Sandboxes MUST run air-gapped (`--network=none` or isolated veth pair with default-deny iptables/nftables) unless external package download or web crawling is explicitly required by the user turn.
- **Mandatory Egress Firewall Rules (eBPF / iptables / nftables)**:
  - If outbound internet access is enabled (e.g., to run `npm install` or `pip install`), the host network namespace MUST drop all packets to:
    - **Cloud Instance Metadata Services (IMDS)**:
      - AWS/GCP/Azure IMDS IPv4: `169.254.169.254/32`
      - AWS IMDS IPv6: `fd00:ec2::254/128`
      - Alibaba Cloud IMDS: `100.100.100.200/32`
      - Oracle Cloud IMDS: `169.254.169.254/32`
    - **RFC 1918 Private Subnets** (prevents intranet port scanning & microservice SSRF):
      - `10.0.0.0/8`
      - `172.16.0.0/12`
      - `192.168.0.0/16`
      - `127.0.0.0/8` (Host Loopback)
      - `::1/128`
      - Carrier-Grade NAT: `100.64.0.0/10`
      - Link-Local: `169.254.0.0/16`
- **Domain-Allowlisted HTTP Forward Proxy**:
  - For package installations, route all outbound traffic through an authenticated forward proxy (e.g., Envoy or Squid) enforcing a strict domain allowlist:
    ```text
    # Allowed Egress Destinations:
    registry.npmjs.org:443
    pypi.org:443
    files.pythonhosted.org:443
    crates.io:443
    proxy.golang.org:443
    github.com:443
    ```
  - Intercept and block raw TCP/UDP sockets to non-whitelisted ports (blocking reverse shells, IRC botnet C2, and DNS tunneling).

---

## 5. Ephemeral Lifecycle & Copy-on-Write (CoW) Workspace Provisioning

Agent tasks must be isolated from the host repository and from previous agent turns. Reusing mutable container state leads to non-reproducible bugs, poisoned test artifacts, and privilege escalation traps.

### The OverlayFS Copy-on-Write Architecture
```
┌─────────────────────────────────────────────────────────────┐
│                 Merged View (Sandbox /app)                  │
│               Agent sees clean workspace + writes           │
└──────────────────────────────┬──────────────────────────────┘
                               │
            ┌──────────────────┴──────────────────┐
            ▼                                     ▼
┌───────────────────────────────┐   ┌───────────────────────────────┐
│ UpperDir (tmpfs / Ephemeral)  │   │ LowerDir (Read-Only Host Dir) │
│ • All file creations          │   │ • Original project source     │
│ • File modifications          │   │ • Locked with read-only bind  │
│ • Whiteout deletions          │   │ • Protected from corruption   │
└───────────────────────────────┘   └───────────────────────────────┘
```

### Production Provisioning Invariants
- **Never Mount Host Source as Read-Write Directly**:
  - Mounting the user's host repository directly with `-v /path/to/host:/app:rw` allows the LLM to run destructive commands (`git reset --hard`, `rm -rf .git`, deleting uncommitted work).
  - Use OverlayFS:
    ```bash
    # Mount host repo as read-only lowerdir, write layer on tmpfs:
    mount -t overlay overlay -o lowerdir=/host/repo:ro,upperdir=/tmp/sandbox/upper,workdir=/tmp/sandbox/work /sandbox/merged
    ```
- **Targeted Diff Extraction**:
  - When the agent finishes executing, inspect the `upperdir` to extract clean `git diff` patches. Present the diff to the user or orchestrator for verification before applying changes to the real host repository.
- **Fast Pre-warmed Pool**:
  - For microVMs (Firecracker) or containers, maintain an idle pool of pre-warmed, booted sandboxes (e.g., 3–5 instances). On incoming agent task, allocate an instance in $<50\text{ms}$ rather than waiting for cold container pull and boot.
- **Stateless Post-Execution Destruction**:
  - Upon task completion, timeout, or failure, immediately terminate the sandbox and unmount/wipe the ephemeral `tmpfs` directories. Never persist runtime artifacts across unrelated tasks.

---

## 6. Subprocess Execution, Process Groups & Zombie Reaping

Executing shell commands on behalf of an agent requires strict process tree control. A simple `child_process.exec()` or `subprocess.run()` without process groups leaves detached background processes (daemons, miners, orphaned test servers) alive forever.

### The Orphaned Process & Zombie Trap
```
Host Orchestrator
   │
   ▼
child_process.spawn("sh -c 'python -m server & pytest'")
   │
   ├─► Parent PID: sh (Killed by Orchestrator on timeout)
   │
   └─► Orphaned Child: python -m server (Adopts PID 1, keeps port 8080 open forever!)
```

### Production Execution Pattern (Go & TypeScript)

#### 1. Go Production Sandbox Runner
```go
package sandbox

import (
    "bytes"
    "context"
    "errors"
    "fmt"
    "io"
    "os/exec"
    "regexp"
    "syscall"
    "time"
)

var ansiRegex = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]`)

type ExecResult struct {
    Stdout   string
    Stderr   string
    ExitCode int
    TimedOut bool
}

// RunInProcessGroup executes a command in an isolated process group with strict timeouts and output bounding.
func RunInProcessGroup(ctx context.Context, timeout time.Duration, maxBytes int64, cmdName string, args ...string) (*ExecResult, error) {
    execCtx, cancel := context.WithTimeout(ctx, timeout)
    defer cancel()

    cmd := exec.CommandContext(execCtx, cmdName, args...)
    // Setpgid creates a new process group: pgid == child pid
    cmd.SysProcAttr = &syscall.SysProcAttr{
        Setpgid:   true,
        Pdeathsig: syscall.SIGKILL, // Reaps child immediately if host parent dies
    }

    var stdoutBuf, stderrBuf bytes.Buffer
    cmd.Stdout = io.LimitReader(&stdoutBuf, maxBytes)
    cmd.Stderr = io.LimitReader(&stderrBuf, maxBytes)

    err := cmd.Start()
    if err != nil {
        return nil, fmt.Errorf("failed to start sandbox process: %w", err)
    }

    pgid, err := syscall.Getpgid(cmd.Process.Pid)
    if err != nil {
        pgid = cmd.Process.Pid
    }

    done := make(chan error, 1)
    go func() { done <- cmd.Wait() }()

    select {
    case <-execCtx.Done():
        // Timeout expired: Graceful SIGTERM to process group, followed by uncatchable SIGKILL
        _ = syscall.Kill(-pgid, syscall.SIGTERM)
        time.Sleep(500 * time.Millisecond)
        _ = syscall.Kill(-pgid, syscall.SIGKILL) // Mandatory negative PID targets entire process group!
        <-done

        return &ExecResult{
            Stdout:   sanitizeOutput(stdoutBuf.String()),
            Stderr:   sanitizeOutput(stderrBuf.String()),
            ExitCode: 124, // Standard Linux timeout exit code
            TimedOut: true,
        }, nil

    case err := <-done:
        exitCode := 0
        if err != nil {
            var exitErr *exec.ExitError
            if errors.As(err, &exitErr) {
                exitCode = exitErr.ExitCode()
            } else {
                exitCode = 1
            }
        }
        return &ExecResult{
            Stdout:   sanitizeOutput(stdoutBuf.String()),
            Stderr:   sanitizeOutput(stderrBuf.String()),
            ExitCode: exitCode,
            TimedOut: false,
        }, nil
    }
}

func sanitizeOutput(raw string) string {
    // Strip terminal ANSI color and cursor codes to prevent context window pollution
    return ansiRegex.ReplaceAllString(raw, "")
}
```

#### 2. TypeScript / Node.js Production Sandbox Runner
```ts
import { spawn } from 'node:child_process';
import { Buffer } from 'node:buffer';

interface CommandResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  timedOut: boolean;
}

const ANSI_REGEX = /\x1b\[[0-9;]*[a-zA-Z]/g;

export function runSandboxedCommand(
  command: string,
  args: string[],
  cwd: string,
  timeoutMs = 30_000,
  maxOutputBytes = 64 * 1024
): Promise<CommandResult> {
  return new Promise((resolve) => {
    let stdoutBuffer = '';
    let stderrBuffer = '';
    let timedOut = false;
    let finished = false;

    // detached: true makes child the leader of a new process group
    const child = spawn(command, args, {
      cwd,
      detached: true,
      env: {
        PATH: '/usr/local/bin:/usr/bin:/bin',
        LANG: 'en_US.UTF-8',
        PYTHONUNBUFFERED: '1',
        NODE_ENV: 'test',
      },
    });

    const timer = setTimeout(() => {
      timedOut = true;
      if (child.pid && !finished) {
        try {
          // Negative PID kills the entire process group, reaping all spawned child sub-processes
          process.kill(-child.pid, 'SIGTERM');
          setTimeout(() => {
            if (!finished && child.pid) {
              try { process.kill(-child.pid, 'SIGKILL'); } catch {}
            }
          }, 1000);
        } catch {
          // Process already exited
        }
      }
    }, timeoutMs);

    child.stdout.on('data', (chunk: Buffer) => {
      if (stdoutBuffer.length < maxOutputBytes) {
        stdoutBuffer += chunk.toString('utf-8');
      }
    });

    child.stderr.on('data', (chunk: Buffer) => {
      if (stderrBuffer.length < maxOutputBytes) {
        stderrBuffer += chunk.toString('utf-8');
      }
    });

    child.on('close', (code) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);

      resolve({
        stdout: stdoutBuffer.replace(ANSI_REGEX, '').slice(0, maxOutputBytes),
        stderr: stderrBuffer.replace(ANSI_REGEX, '').slice(0, maxOutputBytes),
        exitCode: timedOut ? 124 : (code ?? 1),
        timedOut,
      });
    });

    child.on('error', (err) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);

      resolve({
        stdout: '',
        stderr: `Failed to execute: ${err.message}`,
        exitCode: 1,
        timedOut: false,
      });
    });
  });
}
```

### The Tini PID 1 Reaper Requirement
- When running in Docker/container sandboxes, processes running as PID 1 do not inherit standard OS signal handlers and fail to reap zombie (`[defunct]`) processes.
- Always use **Tini** (`--init` flag in Docker or `ENTRYPOINT ["/sbin/tini", "--"]`) to correctly route `SIGTERM`/`SIGINT` signals and automatically harvest terminated child processes.

---

## 7. Secret Isolation & Environment Variable Sanitization

Passing the host environment to an execution sandbox leaks critical credentials into the agent's reach.

### Secret Sanitization Invariants
- ❌ **TOTAL BAN ON INHERITING `process.env` / `os.Environ()`**:
  - Never execute sandbox commands with host environment variables. Untrusted code can simply execute `env`, `printenv`, or `cat /proc/self/environ` to exfiltrate OpenAI API keys, AWS credentials, GitHub tokens, or database connection strings.
- **Strict Clean Environment Allowlist**:
  - Construct an explicit, minimal environment map:
    ```go
    cleanEnv := []string{
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin",
        "LANG=C.UTF-8",
        "LC_ALL=C.UTF-8",
        "HOME=/tmp",
        "TMPDIR=/tmp",
        "NODE_ENV=test",
        "PYTHONUNBUFFERED=1",
        "HISTFILE=/dev/null", // Disables bash shell history disk logging
    }
    ```
- **Zero-Storage for Sensitive Dotfiles**:
  - Ensure `/root` and user home directories inside the sandbox contain no lingering `.netrc`, `.npmrc`, `.gitconfig`, or `.aws/credentials` files.

---

## 8. Symlink Traversal & Path Escapes (Zip Slip / Directory Traversal)

Agents frequently manipulate archives, tarballs, or create symbolic links (`ln -s`). If unverified, this enables filesystem jailbreaks out of the sandbox directory.

### The Symlink Directory Escape
```
Workspace: /sandbox/workspace/
Malicious Link: /sandbox/workspace/escaped_etc -> /etc
Agent Read Tool: reads /sandbox/workspace/escaped_etc/shadow
```

### Production Path Verification Invariant
```go
package sandbox

import (
    "fmt"
    "path/filepath"
    "strings"
)

// ValidateSafeWorkspacePath verifies that requestedPath strictly resolves within rootDir.
func ValidateSafeWorkspacePath(rootDir, requestedPath string) (string, error) {
    // 1. Resolve absolute path of workspace root
    absRoot, err := filepath.Abs(rootDir)
    if err != nil {
        return "", fmt.Errorf("invalid root directory: %w", err)
    }

    // 2. Resolve symlinks on the root itself
    canonicalRoot, err := filepath.EvalSymlinks(absRoot)
    if err != nil {
        return "", fmt.Errorf("failed to canonicalize root directory: %w", err)
    }

    // 3. Resolve target path
    target := requestedPath
    if !filepath.IsAbs(target) {
        target = filepath.Join(canonicalRoot, requestedPath)
    }

    // 4. Fully evaluate all symlinks in target path
    canonicalTarget, err := filepath.EvalSymlinks(target)
    if err != nil {
        // If file doesn't exist yet (e.g. for write operations), check canonical parent directory
        parentDir := filepath.Dir(target)
        canonicalParent, parentErr := filepath.EvalSymlinks(parentDir)
        if parentErr != nil {
            return "", fmt.Errorf("path does not exist or invalid parent: %w", parentErr)
        }
        canonicalTarget = filepath.Join(canonicalParent, filepath.Base(target))
    }

    // 5. Enforce boundary prefix check with trailing slash
    prefix := canonicalRoot
    if !strings.HasSuffix(prefix, string(filepath.Separator)) {
        prefix += string(filepath.Separator)
    }

    if canonicalTarget != canonicalRoot && !strings.HasPrefix(canonicalTarget, prefix) {
        return "", fmt.Errorf("security violation: path '%s' escapes sandbox root '%s'", requestedPath, rootDir)
    }

    return canonicalTarget, nil
}
```

---

## 9. Agent Sandbox Production Verification Checklist

Before deploying any autonomous coding agent or code execution runner to production, verify every item in this checklist:

- [ ] **Runtime Isolation**: Are multi-tenant workloads isolated via MicroVMs (Firecracker) or user-space kernels (gVisor `runsc`) rather than bare host Docker?
- [ ] **Privilege Stripping**: Are containers run with `--cap-drop=ALL` and `no-new-privs: true`?
- [ ] **Filesystem Protection**: Is the root filesystem read-only (`--read-only`), with writeable scratchpads restricted to `tmpfs`?
- [ ] **Fork-Bomb Protection**: Is `pids.max` explicitly configured (e.g., $\le 256$) to prevent PID exhaustion?
- [ ] **Memory & CPU Bounds**: Are `memory.max`, `memory.swap.max = 0`, and CFS CPU quotas enforced?
- [ ] **IMDS Blocked**: Are network packets to `169.254.169.254`, `fd00:ec2::254`, and private RFC 1918 subnets dropped at the firewall level?
- [ ] **Process Group Reaping**: Does the process executor use process groups (`setpgid`) and `kill(-pgid, SIGKILL)` on timeout, avoiding orphaned processes?
- [ ] **PID 1 Zombie Reaper**: Is `tini` or `dumb-init` configured as PID 1 inside container runtimes?
- [ ] **Environment Scrubbing**: Are all host credentials (`process.env`) stripped from sandbox child execution contexts?
- [ ] **Symlink Jailbreak Defense**: Are file reads and writes checked via `filepath.EvalSymlinks()` against the canonical workspace boundary?
- [ ] **Output Bounding**: Are stdout and stderr streams truncated at a hard ceiling ($\le 64\text{ KB}$ or $\le 200\text{ lines}$) with ANSI escape codes stripped?
- [ ] **Ephemeral Teardown**: Are overlayfs workdirs and temporary containers destroyed immediately upon task completion?
