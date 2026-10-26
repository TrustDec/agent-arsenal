---
description: Agentic shadow workspaces, Git worktree isolation, ephemeral execution enclaves, dirty tree collision prevention, headless multi-agent concurrency, and atomic rebase/patch integration across Claude Code, Cursor, Windsurf, Roo Code, Pi, and OpenCode
globs: **/*{worktree,workspace,enclave,sandbox,git,branch,patch,diff,concurrency,rebase,merge}*.*,**/rules/**,**/.cursorrules,**/CLAUDE.md,**/AGENTS.md,**/.agents/**
alwaysApply: false
---

# Agentic Shadow Workspaces, Git Worktree Isolation & Ephemeral Sandboxes

> Add these rules to your project when configuring autonomous coding agents, multi-turn pair programmers, or SWE-bench execution harnesses (Claude Code, Cursor Composer, Windsurf Cascade, Roo Code, Pi, OpenCode, Aider). Prevent dirty working tree collisions, dev server watcher thrashing, and stash corruption by executing agent reasoning, code modifications, and test runs inside isolated, detached Git worktree enclaves.

---

## 1. Architectural Taxonomy: The Dirty Tree Collision vs Shadow Worktrees

In real-world autonomous software engineering, running agents directly inside the developer's interactive working directory introduces critical failure modes:

- **The Dirty Tree Collision ($O(1)$ Blast Radius Disaster)**:
  - Developers run autonomous agents while actively coding in an IDE. When an agent executes in the current working tree, it modifies files the developer is editing, conflicts with unstaged changes, and corrupts the developer's mental model.
  - If the agent fails or hallucinates mid-task, the developer is left with half-modified files mixed with their own uncommitted edits, requiring tedious manual triage or risking catastrophic loss via accidental `git checkout -- .` or `git reset --hard`.
- **The Amnesiac Stash Trap**:
  - Naive agent scripts attempt to work around dirty trees by running `git stash`, executing agent changes, and running `git stash pop`.
  - If the developer has untracked files, `git stash` silently ignores them or fails. If the agent changes overlap with stashed edits, `git stash pop` triggers merge conflicts inside the stash index, corrupting the stash queue and stranding user code in a detached commit.
- **Dev Server Watcher Thrashing & HMR Meltdown**:
  - In modern full-stack web and backend applications (Vite, Next.js, Webpack, `cargo watch`, `air`), file watchers trigger instant Hot Module Replacement (HMR) and background test runs.
  - Every time an agent edits, formats, or reverts files across dozens of turns, the developer's local dev server locks CPU cores, flashes browser windows, and crashes active debugging sessions.
- **Multi-Agent File Lock & Index Contention**:
  - When multi-agent swarms execute concurrently (e.g. Planner + Coder + Reviewer or parallel sub-task agents), concurrent file writes and git commands crash with `fatal: Unable to create '.git/index.lock': File exists`.
- **The Shadow Worktree Invariant**:
  - Autonomous agents must operate inside an isolated **Shadow Worktree Enclave**: a detached Git worktree created outside the primary repository checkout (e.g. in `/tmp/agent-worktrees/<task-id>`), sharing the underlying `.git` object store without copying gigabytes of history.
  - The developer's primary interactive tree remains $100\%$ untouched. The agent generates, tests, and verifies changes hermetically, synthesizing an atomic unified patch or pull request that can be cleanly previewed, validated, and merged.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Developer Workspace (Main Tree: branch `feat/billing`, uncommitted user WIP in progress)        │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: In-Place Execution]                                             ▼ [PRODUCTION: Shadow Worktree Enclave]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ Agent runs directly in main directory:          │               │ Main Tree untouched! (Zero HMR thrash, no risk) │
│ - Overwrites user uncommitted edits.            │               │ git worktree add --detach /tmp/enclave-42 HEAD    │
│ - Triggers Vite HMR & Cargo watcher reloads.    │               ├─────────────────────────────────────────────────┤
│ - Crashes on .git/index.lock if multi-agent.    │               │ Shadow Worktree (/tmp/enclave-42/):             │
├─────────────────────────────────────────────────┤               │ - Symlinked node_modules/target/vendor caches   │
│ Fails test: runs `git checkout .`               │               │ - Agent edits, compiles & runs full test suites │
├─────────────────────────────────────────────────┤               │ - Verifies clean green build in hermetic isolation│
│ Disaster: User's 3 hours of WIP deleted forever!│               ├─────────────────────────────────────────────────┤
│ Dev server crashed; working tree left broken.   │               │ Atomic Patch Extraction:                        │
│ Trust in autonomous tooling destroyed.          │               │ git diff HEAD > /tmp/task-42.patch              │
│                                                 │               │ Preflight verify: git apply --check             │
└─────────────────────────────────────────────────┘               └─────────────────────────────────────────────────┘
```

---

## 2. Mathematical Formalism: Workspace Isolation & Blast Radius Bounds

We quantify workspace isolation safety $S_{\text{isolation}}$ and provisioning latency $T_{\text{provision}}$ across execution strategies:

### 2.1 Workspace Isolation Safety Coefficient
Let $F_{\text{primary\_modified}}$ be the set of files modified by the agent, and $F_{\text{uncommitted\_user}}$ be the developer's uncommitted working files. The safety coefficient $S_{\text{isolation}} \in [0, 1]$ is:

$$S_{\text{isolation}} = 1 - \frac{|F_{\text{primary\_modified}} \cap F_{\text{uncommitted\_user}}|}{\max(1, |F_{\text{uncommitted\_user}}|)}$$

- In naive in-place execution: if the agent modifies any user WIP file, $S_{\text{isolation}} < 1$. In worst-case reverts, $S_{\text{isolation}} = 0$.
- Under Shadow Worktree isolation: $F_{\text{primary\_modified}} \equiv \emptyset$ during agent execution, guaranteeing:
  $$S_{\text{isolation}} \equiv 1.0 \quad (\text{Absolute Invariant})$$

### 2.2 Amortized Provisioning Latency
A naive full `git clone` requires $O(|V| + |E|)$ transfer of all packfiles and network roundtrips, followed by $O(D_{\text{deps}})$ package manager reinstallation:

$$T_{\text{clone}} = T_{\text{git\_clone}} + T_{\text{npm\_install}} \approx 30\text{s} - 180\text{s}$$

A Shadow Git Worktree shares the existing `.git/objects` directory via hard references and symlinks runtime dependency caches (`node_modules`, `target`, `.venv`), requiring only tree object expansion:

$$T_{\text{worktree}} = O(|Tree_{\text{HEAD}}|) + O(|Symlinks|) \approx 50\text{ms} - 200\text{ms}$$

Delivering a $> 200\times$ acceleration while preserving $100\%$ hermetic isolation.

---

## 3. The 5-Stage Worktree Enclave Lifecycle State Machine

Every autonomous agent task must follow the deterministic 5-stage enclave lifecycle:

```
┌────────────────────────┐     ┌────────────────────────┐     ┌────────────────────────┐
│ Stage 1: Provision     │ ──> │ Stage 2: Hydration     │ ──> │ Stage 3: Execution     │
│ git worktree add       │     │ Symlink cache layers   │     │ Agent ReAct / CodeAct  │
│ --detach /tmp/enclave  │     │ (node_modules, target) │     │ Compile, test & verify │
└────────────────────────┘     └────────────────────────┘     └───────────┬────────────┘
                                                                          │
┌────────────────────────┐     ┌────────────────────────┐                 │
│ Stage 5: Teardown      │ <── │ Stage 4: Synthesis     │ <───────────────┘
│ git worktree remove    │     │ Generate unified patch │
│ Prune orphan locks     │     │ git apply --check main │
└────────────────────────┘     └────────────────────────┘
```

```
                        [IDLE]
                          │
                          │ Task Initiated (taskId, baseRef)
                          ▼
                    [PROVISIONING] ──(Worktree lock / path clash)──> [PROVISION_FAILED]
                          │                                                 │
                          │ Worktree created (--detach)                     ▼
                          ▼                                              [ABORT]
                     [HYDRATING]
                          │ Symlinks verified (node_modules, target)
                          ▼
                     [EXECUTING] <───┐ (Iterative agent edits & test runs)
                          │          │
                          ├──(Test fail)──┘
                          ├──(Task abort / timeout)──> [EMERGENCY_TEARDOWN]
                          │                                  │
                          │ All tests PASS                   ▼
                          ▼                               [ABORT]
                    [SYNTHESIZING]
                          │ git diff HEAD -> patch.diff
                          │ git apply --check (on primary tree)
                          ├──(Merge clash detected)──> [CONFLICT_DIAGNOSED]
                          │                                  │
                          │ Clean patch verified             ▼
                          ▼                            [HUMAN_REVIEW]
                    [COMMITTING / APPLIED]
                          │
                          ▼
                    [TEARING_DOWN]
                          │ git worktree remove --force
                          │ git worktree prune
                          ▼
                       [CLEAN]
```

---

## 4. Production TypeScript Shadow Worktree Orchestrator

Below is the production-grade, hardened `ShadowWorktreeManager` implementing atomic enclave provisioning, dependency symlinking, unified patch synthesis, preflight patch verification, signal-trapped cleanup, and lock pruning:

```typescript
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import * as os from 'node:os';
import * as crypto from 'node:crypto';

const execFileAsync = promisify(execFile);

export interface EnclaveOptions {
  repoRoot: string;
  baseRef?: string;
  taskId?: string;
  cacheDirs?: string[]; // e.g. ['node_modules', 'target', '.venv', 'vendor']
}

export interface UnifiedPatch {
  taskId: string;
  patchContent: string;
  filesChanged: string[];
  insertions: number;
  deletions: number;
}

export interface EnclaveContext {
  id: string;
  worktreePath: string;
  baseRef: string;
  createdAt: number;
}

export class ShadowWorktreeManager {
  private readonly activeEnclaves = new Map<string, EnclaveContext>();
  private isShuttingDown = false;

  constructor() {
    this.registerSignalHandlers();
  }

  /**
   * Provision an isolated detached shadow worktree for agent execution.
   */
  public async createEnclave(options: EnclaveOptions): Promise<EnclaveContext> {
    if (this.isShuttingDown) {
      throw new Error('Manager is shutting down, cannot provision new enclaves');
    }

    const taskId = options.taskId || crypto.randomUUID().slice(0, 8);
    const enclaveId = `agent-enclave-${taskId}-${Date.now()}`;
    const baseRef = options.baseRef || 'HEAD';
    const worktreePath = path.join(os.tmpdir(), 'agent-arsenal-worktrees', enclaveId);

    await fs.mkdir(path.dirname(worktreePath), { recursive: true });

    // Step 1: Provision detached worktree directly from Git object store
    try {
      await execFileAsync('git', ['worktree', 'add', '--detach', worktreePath, baseRef], {
        cwd: options.repoRoot
      });
    } catch (err: any) {
      throw new Error(`Failed to create git worktree at ${worktreePath}: ${err.message}`);
    }

    // Step 2: Hydrate shared dependency caches via symlinks (Zero-copy hydration)
    const cacheDirs = options.cacheDirs || ['node_modules', 'target', '.venv', 'vendor'];
    for (const dirName of cacheDirs) {
      const sourceDir = path.join(options.repoRoot, dirName);
      const targetDir = path.join(worktreePath, dirName);

      try {
        const stat = await fs.stat(sourceDir);
        if (stat.isDirectory()) {
          await fs.symlink(sourceDir, targetDir, 'junction');
        }
      } catch {
        // Directory does not exist in root, skip cleanly
      }
    }

    const context: EnclaveContext = {
      id: enclaveId,
      worktreePath,
      baseRef,
      createdAt: Date.now()
    };

    this.activeEnclaves.set(enclaveId, context);
    return context;
  }

  /**
   * Synthesize a clean, atomic unified patch from the worktree.
   */
  public async synthesizePatch(enclaveId: string): Promise<UnifiedPatch> {
    const context = this.activeEnclaves.get(enclaveId);
    if (!context) {
      throw new Error(`Enclave ${enclaveId} not found`);
    }

    // Capture unstaged and staged changes relative to initial base ref
    const { stdout: patchContent } = await execFileAsync(
      'git',
      ['diff', context.baseRef, '--binary', '--no-color'],
      { cwd: context.worktreePath }
    );

    const { stdout: numstat } = await execFileAsync(
      'git',
      ['diff', context.baseRef, '--numstat'],
      { cwd: context.worktreePath }
    );

    const filesChanged: string[] = [];
    let insertions = 0;
    let deletions = 0;

    for (const line of numstat.trim().split('\n')) {
      if (!line) continue;
      const [ins, del, file] = line.split('\t');
      filesChanged.push(file);
      insertions += ins === '-' ? 0 : parseInt(ins, 10) || 0;
      deletions += del === '-' ? 0 : parseInt(del, 10) || 0;
    }

    return {
      taskId: enclaveId,
      patchContent,
      filesChanged,
      insertions,
      deletions
    };
  }

  /**
   * Perform dry-run preflight verification of patch against primary repository.
   */
  public async verifyPatchOnPrimary(repoRoot: string, patch: UnifiedPatch): Promise<boolean> {
    if (!patch.patchContent.trim()) {
      return true; // No-op patch is always valid
    }

    try {
      const child = execFile('git', ['apply', '--check', '--binary', '-'], {
        cwd: repoRoot
      });

      child.stdin?.write(patch.patchContent);
      child.stdin?.end();

      await new Promise<void>((resolve, reject) => {
        child.on('close', code => {
          if (code === 0) resolve();
          else reject(new Error(`git apply --check exited with code ${code}`));
        });
        child.on('error', reject);
      });

      return true;
    } catch {
      return false; // Patch encounters conflicts on current primary tree
    }
  }

  /**
   * Teardown worktree hermetically, unlinking caches and pruning git worktree state.
   */
  public async teardownEnclave(enclaveId: string, repoRoot: string): Promise<void> {
    const context = this.activeEnclaves.get(enclaveId);
    if (!context) return;

    try {
      // 1. Force remove worktree from git tracking
      await execFileAsync('git', ['worktree', 'remove', '--force', context.worktreePath], {
        cwd: repoRoot
      }).catch(() => {});

      // 2. Remove lingering directory if git worktree remove left symlinks/files
      await fs.rm(context.worktreePath, { recursive: true, force: true }).catch(() => {});

      // 3. Prune dead worktree metadata from .git/worktrees
      await execFileAsync('git', ['worktree', 'prune'], { cwd: repoRoot }).catch(() => {});
    } finally {
      this.activeEnclaves.delete(enclaveId);
    }
  }

  /**
   * Emergency teardown on process exit/SIGINT to prevent orphaned directories and locks.
   */
  private registerSignalHandlers(): void {
    const handleShutdown = async (signal: string) => {
      if (this.isShuttingDown) return;
      this.isShuttingDown = true;
      console.error(`Received ${signal}. Cleaning up ${this.activeEnclaves.size} shadow worktrees...`);

      for (const [id, ctx] of this.activeEnclaves.entries()) {
        try {
          await fs.rm(ctx.worktreePath, { recursive: true, force: true }).catch(() => {});
        } catch {}
      }
      process.exit(1);
    };

    process.once('SIGINT', () => handleShutdown('SIGINT'));
    process.once('SIGTERM', () => handleShutdown('SIGTERM'));
  }
}
```

---

## 5. Anti-Patterns vs Production Invariants

### 5.1 In-Place `git stash` vs Detached Shadow Worktrees
- ❌ **Anti-Pattern: Running `git stash` in Dirty Working Trees**:
  - Agent starts by running `git stash` to clean the tree, applies modifications, tests, and runs `git stash pop`.
  - If untracked files were present, they are either left behind and clash with agent files, or `git stash pop` triggers a 3-way merge conflict inside the developer's uncommitted work, resulting in broken working state and lost productivity.
- ✅ **Production Invariant**:
  - Never run `git stash` inside autonomous agent workflows.
  - Leave the developer's working tree completely untouched. Create a shadow worktree with `git worktree add --detach <tmp-path> HEAD`. Agent modifications are isolated from user WIP.

### 5.2 Heavy `git clone` vs Shared-Object Worktrees
- ❌ **Anti-Pattern: Full Repository Clones & Fresh Installs**:
  - Agent clones the remote or local repository to a temporary folder (`git clone . /tmp/clone`) and runs `npm install` or `cargo build`.
  - This wastes $500\text{MB} - 5\text{GB}$ of disk space, burns several minutes downloading dependencies, and exhausts CI/local bandwidth.
- ✅ **Production Invariant**:
  - Always use Git worktrees. Git worktrees share the primary `.git/objects` directory with zero byte duplication.
  - Symlink heavy cached folders (`node_modules`, `target`, `.venv`, Go `pkg/mod`) into the worktree enclave. Provisioning completes in $< 200\text{ms}$.

### 5.3 Orphaned Worktree Metadata & `.git/index.lock` Collisions
- ❌ **Anti-Pattern: Deleting Worktrees with Naked `rm -rf`**:
  - The agent or runner cleans up by running `rm -rf /tmp/agent-worktree`.
  - While files are deleted, `.git/worktrees/<name>/` metadata remains orphaned in the main repository. Future worktree creations fail with `fatal: '<name>' already exists`, and background git commands lock up.
- ✅ **Production Invariant**:
  - Always tear down worktrees via canonical Git commands:
    ```bash
    git worktree remove --force "$WORKTREE_PATH"
    git worktree prune
    ```
  - Register process signal handlers (`SIGINT`, `SIGTERM`, unhandled exceptions) to guarantee cleanup before the process exits.

### 5.4 Live Dev Server Watcher Thrashing
- ❌ **Anti-Pattern: Editing Files Monitored by Active HMR / File Watchers**:
  - The developer is previewing the UI in a browser (`npm run dev`). The autonomous agent edits 15 files across 6 iterations, causing Vite/Webpack to compile 15 times, resetting frontend client state, and spiking CPU to $100\%$.
- ✅ **Production Invariant**:
  - Because shadow worktrees reside in an ephemeral path (e.g. `/tmp/agent-arsenal-worktrees/...`), IDE file watchers and dev servers monitoring the primary repository never receive inotify/FSEvents triggers.
  - The developer's interactive session experiences zero frame drops, zero HMR reloads, and zero watcher restarts.

### 5.5 Port and Test Database Collisions in Concurrent Multi-Agent Swarms
- ❌ **Anti-Pattern: Hardcoded Ports (`3000`, `8080`) & Shared Local Databases in Enclaves**:
  - Parallel sub-agents running inside worktrees try to spin up local servers on `localhost:3000` or run database migrations against `postgres://localhost:5432/test_db`.
  - The second agent crashes with `EADDRINUSE` or clobbers database records created by the first agent.
- ✅ **Production Invariant**:
  - Allocate dynamic ephemeral ports (`PORT=0` or dynamically assigned ports) for each worktree execution.
  - Use isolated SQLite databases (`file::memory:?cache=shared` or `/tmp/<enclave-id>.db`) or unique schema namespaces in PostgreSQL (`search_path = enclave_<id>`).

---

## 6. Definition of Done (DoD) Verification Matrix

Every autonomous agent shadow worktree integration must satisfy all six machine-verifiable verification gates before being approved for production use:

| Gate | Verification Check | Deterministic Command / Proof | Failure Remediation |
| :--- | :--- | :--- | :--- |
| **G1: Primary Tree Immutability** | Main repository status before and after execution must be identical | `git status --porcelain` on primary repository returns identical byte hash before and after agent run | Halt execution; agent leaked writes into parent repository directory |
| **G2: Worktree Creation Latency** | Shadow enclave provisioning must complete within bounded time | `time git worktree add --detach <path> HEAD` $\le 500\text{ ms}$ | Check disk I/O; replace deep directory copying with symlink cache hydration |
| **G3: Zero-Copy Dependency Hydration** | Heavy dependency folders (`node_modules`, `target`) must be symlinked, not re-downloaded | `test -L <worktree>/node_modules && readlink <worktree>/node_modules` | Symlink missing; package manager ran cold install instead of linking cache |
| **G4: Preflight Patch Verifiability** | Generated unified patch must be dry-run tested against current base | `git apply --check --binary < synthesized.patch` exits with `0` | Rebase enclave onto latest primary HEAD or prompt user for interactive 3-way conflict resolution |
| **G5: Clean Teardown & Lock Pruning** | Zero orphaned worktrees or stale index locks in `.git` directory | `git worktree list` contains only primary tree; `.git/worktrees/` contains no stale entries | Execute `git worktree remove --force` followed by `git worktree prune` |
| **G6: Process Signal Resilience** | Abrupt `SIGINT` / `SIGTERM` must cleanly clean up ephemeral directory | Send `SIGINT` to test harness; verify `/tmp/agent-arsenal-worktrees/<id>` does not leak on disk | Check process signal handler registration and `process.once` cleanup traps |

---

## 7. Claude Code & Cursor Quick Integration Cheat Sheet

```bash
# 1. Quick Detached Worktree Creation for Agent Exploration:
ENCLAVE_DIR="/tmp/agent-worktrees/task-$(date +%s)"
git worktree add --detach "$ENCLAVE_DIR" HEAD

# 2. Symlink Dependencies (Zero re-install overhead):
ln -s "$(pwd)/node_modules" "$ENCLAVE_DIR/node_modules" 2>/dev/null || true

# 3. Direct your agent to work inside the enclave:
cd "$ENCLAVE_DIR"
# ... Agent makes changes, runs tests, fixes bugs ...
npm test

# 4. Generate clean patch:
git diff HEAD > /tmp/task-result.patch

# 5. Return to primary workspace, verify & apply:
cd -
git apply --check /tmp/task-result.patch
git apply /tmp/task-result.patch

# 6. Teardown enclave cleanly:
git worktree remove --force "$ENCLAVE_DIR"
git worktree prune
```
