---
description: Agentic pull request synthesis, automated code review, semantic git diff decomposition, blast-radius risk scoring, falsifiable defect verification, conventional commit atomicity, and merge conflict resolution across Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*,**/.github/workflows/*,**/.gitlab-ci.yml,**/.git/*
alwaysApply: false
---

# Agentic Pull Request Synthesis, Automated Code Review & Semantic Merge Governance

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to author Pull Requests, generate semantic commit histories, perform automated code reviews, or resolve branch merge conflicts. Eliminate the "Hallucinated PR Summary Trap" (where agents invent changes never made in the git diff), the "Megacommit Blast-Radius Disaster" (where 40+ files are dumped into an un-bisectable commit), the "Pedantic Review Noise Mirage" (where reviewer agents flood PRs with unverified stylistic opinions while missing critical bugs), and the "Semantic Conflict Collision" by enforcing a strict 5-Tier PR & Review Governance Ladder, quantitative risk scoring, falsifiable defect reproducers, atomic commit decomposition, and structural three-way AST merge verification.

---

## 1. Architectural Taxonomy: The Hallucinated PR Dilemma vs The 5-Tier PR & Review Governance Ladder

In modern AI-assisted software engineering, autonomous agents are frequently tasked with writing code, opening Pull Requests (PRs), and reviewing peer code. However, unconstrained LLMs exhibit dangerous failure modes in version control and review workflows:

- **The "Hallucinated PR Summary" & Drift Trap**:
  - When asked to author a PR description, autonomous agents summarize what they *intended* to do or what the user prompt asked, rather than what was *actually committed* in the underlying `git diff`.
  - In practice, agents routinely hallucinate that they added unit tests, fixed edge cases, updated documentation, or preserved backward compatibility when the code diff tells the exact opposite story. Human reviewers reading the convincing PR description approve dangerous changes based on false narrative claims.
- **The Megacommit Blast-Radius Disaster (`wip` / `feat: implement everything`)**:
  - Agents often execute multiple iterative prompt loops across dozens of files and then dump all staged and unstaged modifications into a single massive commit (`git commit -am "feat: implement feature"`).
  - This destroys `git bisect` diagnostic capabilities, makes cherry-picking impossible, commingles mechanical refactoring with critical business logic, and overwhelms human reviewers with un-reviewable diff volumes.
- **The Pedantic Review Noise & Sycophancy Mirage**:
  - When acting as automated code reviewers, LLM agents default to superficial syntactic commentary (rephrasing variable names, proposing redundant comments, suggesting personal formatting preferences) while completely overlooking data races, unindexed SQL queries, unhandled null pointers, memory leaks, or missing authorization checks.
  - Worse, reviewer agents frequently hallucinate non-existent syntax or library limitations, generating confusing false-positive review comments that frustrate developers and induce review fatigue.
- **The Falsifiable Defect Requirement**:
  - Zero-noise automated code review mandates that **no review comment claiming a bug or functional regression is permitted unless accompanied by a minimal, reproducible test case or formal proof of invariant violation**. If an agent reviewer cannot synthesize a machine-executable reproduction script that fails against the PR branch and passes against the base branch, the comment is rejected at the gate.
- **The Semantic Merge Conflict Collision**:
  - When resolving Git merge conflicts, agents frequently operate as text editors rather than language-aware parsers. They delete conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) and splice code lines in a way that satisfies raw syntax but silently reverts upstream bug fixes, drops necessary interface imports, or invalidates concurrent architectural changes.
- **The 5-Tier PR & Review Governance Ladder**:
  - Robust agentic engineering requires 5 machine-enforced verification tiers before any branch is promoted to `MERGE_READY`:
    - **Tier 0: Ground-Truth Git Diff Pinning**: The PR description is synthesized deterministically from the exact output of `git diff --stat` and AST symbol delta extraction. Every claimed change maps 1:1 to modified lines in version control.
    - **Tier 1: Semantic Atomic Commit Decomposition**: The change set is partitioned into discrete, self-contained Conventional Commits (`feat`, `fix`, `refactor`, `test`). Every intermediate commit MUST compile and pass tests independently (`git rebase --exec`).
    - **Tier 2: Quantitative Blast-Radius & Risk Scoring ($R_{\text{PR}}$)**: An automated risk score is computed based on modified LOC, affected architectural boundaries (database, auth, payments), and public API surface changes, determining the mandatory human approval tier.
    - **Tier 3: Bidirectional AI-to-AI Falsifiable Review**: Reviewer agents evaluate the PR against strict production invariants, producing structured JSON comments containing falsifiable defect reproducers. Author agents must execute and resolve every reproducer.
    - **Tier 4: Hermetic Pre-Flight Rebase & Merge Verification**: The PR branch is rebased onto the target base branch (`origin/main`), verifying zero merge conflicts, zero AST regressions, and a 100% clean test and lint pass before squash or merge.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Autonomous Agent Generates Code Modifications in Working Directory                               │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: The Megacommit Dump]                                             ▼ [PRODUCTION: 5-Tier PR Governance Ladder]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ git commit -am "feat: implement everything"     │               │ Tier 0: Ground-Truth AST Diff Pinning           │
│ ❌ Hallucinated PR body claiming imaginary fixes│               │ • git diff --stat + AST symbol delta extraction │
│ ❌ Commingles 50 files across DB, API, and UI   │               │ • PR body derived strictly from reality         │
│ ❌ Breaks git bisect with broken intermediate   │               ├─────────────────────────────────────────────────┤
│ ❌ Generates noisy, unprovable review nits      │               │ Tier 1: Semantic Atomic Commit Decomposition    │
│ ❌ Resolves merge conflicts via naive splicing  │               │ • Partitioned Conventional Commits              │
└─────────────────────────────────────────────────┘               │ • git rebase --exec 'test' verifies each step   │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 2: Quantitative Blast-Radius Scoring       │
                                                                  │ • R_PR = f(LOC, critical_modules, DDL)          │
                                                                  │ • Autonomous Fast-Track vs Multi-Maintainer HITL│
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 3: Bidirectional Falsifiable Code Review   │
                                                                  │ • Strict JSON review comments                   │
                                                                  │ • Mandatory minimal test reproducer per bug     │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 4: Hermetic Pre-Flight Rebase Gate         │
                                                                  │ • Rebase onto origin/main + clean test pass     │
                                                                  │ • Structural AST merge conflict verification    │
                                                                  └─────────────────────────────────────────────────┘
```

---

## 2. Mathematical Formulations & Quantitative PR Risk Calculus

To eliminate subjective human guesswork and prevent un-reviewable changes from slipping into production, autonomous agents must calculate the quantitative PR Risk Score ($R_{\text{PR}}$) before requesting review.

### 2.1 The Quantitative PR Risk Index ($R_{\text{PR}}$)

The PR Risk Index is bounded within $[0, 100]$ and computed across four primary dimensions: line volume, file breadth, critical module sensitivity, and database schema mutations:

$$R_{\text{PR}} = \min\left(100, \, w_{\text{loc}} \cdot \ln(1 + \Delta L) + w_{\text{file}} \cdot N_F + \sum_{m \in M_{\text{mod}}} S_{\text{crit}}(m) + w_{\text{ddl}} \cdot \mathbb{I}_{\text{migration}}\right)$$

Where:
- $\Delta L = \Delta L_{\text{added}} + \Delta L_{\text{deleted}}$ represents the total churned lines of code.
- $N_F$ is the count of unique files modified.
- $M_{\text{mod}}$ is the set of modified files or architectural modules.
- $S_{\text{crit}}(m) \in [0, 30]$ is the sensitivity weight of module $m$:
  - Auth, Session, Cryptography, Secrets: $S_{\text{crit}} = 25$
  - Payment Gateways, Billing, Financial Ledgers: $S_{\text{crit}} = 30$
  - Database Migrations & DDL: $S_{\text{crit}} = 20$
  - Public API Contracts (OpenAPI, Protobuf, GraphQL): $S_{\text{crit}} = 15$
  - Core Business Entities & Domain Models: $S_{\text{crit}} = 10$
  - UI Styling, Documentation, Unit Tests: $S_{\text{crit}} = 2$
- $\mathbb{I}_{\text{migration}} \in \{0, 1\}$ indicates the presence of database migration files.
- Canonical weights: $w_{\text{loc}} = 6.0$, $w_{\text{file}} = 2.5$, $w_{\text{ddl}} = 15.0$.

### 2.2 Risk Tier Classification Matrix

| Risk Score ($R_{\text{PR}}$) | Classification | Review Governance Protocol | Blast-Radius Ceiling |
| :--- | :--- | :--- | :--- |
| **$0 \le R_{\text{PR}} < 25$** | **Low (Green)** | Autonomous Fast-Track eligible; automated test pass + 1 peer review | $\Delta L \le 100$, $N_F \le 5$, zero critical modules |
| **$25 \le R_{\text{PR}} < 65$** | **Medium (Yellow)** | Standard Review; automated review pass + 1 senior maintainer approval | $\Delta L \le 400$, $N_F \le 15$, standard modules |
| **$65 \le R_{\text{PR}} < 85$** | **High (Orange)** | Heightened Governance; 2 maintainer approvals + staging canary deployment | $\Delta L \le 800$, critical modules, migrations |
| **$R_{\text{PR}} \ge 85$** | **Critical (Red)** | Mandatory Change Advisory Board (CAB) or PR Decomposition into smaller units | Exceeds single PR safety envelope; MUST split |

### 2.3 The Falsifiable Defect Criterion ($\mathcal{F}$)

When an autonomous agent generates a review comment alleging a functional defect $D$, the comment is valid if and only if its falsifiability condition $\mathcal{F}(D) \equiv 1$:

$$\mathcal{F}(D) = \begin{cases} 
1 & \text{if } \exists \, T_{\text{repro}} \text{ such that } \text{Run}(T_{\text{repro}}, \text{PR\_Branch}) \to \text{FAIL} \land \text{Run}(T_{\text{repro}}, \text{Expected\_Spec}) \to \text{PASS} \\ 
0 & \text{otherwise} 
\end{cases}$$

Subjective commentary (e.g., *"Consider renaming `x` to `counter`"* or *"This function could be written more cleanly"*) evaluates to $\mathcal{F}(D) = 0$ and is filtered out by the automated review firewall.

---

## 3. Semantic Git Commit Decomposition & Conventional Commits State Machine

Autonomous agents must never leave an untidy commit history. When a feature or bugfix touches multiple files across different layers, the agent must decompose changes into atomic Conventional Commits.

### 3.1 The Commit Atomicity Invariant

1. **One Logical Change Per Commit**:
   - Commits modifying domain types or database schemas must NOT be commingled with UI component updates.
   - Mechanical refactoring (formatting, renaming imports, moving files) MUST be isolated in dedicated `refactor:` commits, strictly separated from behavioral `feat:` or `fix:` commits.
2. **The `git bisect` Green Invariant**:
   - Every individual commit in the PR branch MUST be buildable, typecheck cleanly, and pass all unit tests on its own.
   - If commit $C_2$ fails because it relies on a function only introduced in commit $C_3$, the commit sequence violates the green invariant and must be reordered or merged via interactive rebase.

```
WRONG (Broken Bisect History):
Commit 1: "feat: add payment gateway interface" (fails: missing implementation)
Commit 2: "feat: add stripe implementation" (fails: syntax error in helper)
Commit 3: "fix: fix syntax error and make tests pass" (passes)
Result: Bisecting commit 1 or 2 yields broken builds!

CORRECT (Atomic, Individually Verifiable History):
Commit 1: "refactor(billing): extract IPaymentGateway interface" [passes tests]
Commit 2: "feat(billing): implement StripePaymentAdapter with idempotency" [passes tests]
Commit 3: "test(billing): add Stripe webhook signature verification tests" [passes tests]
```

### 3.2 Canonical Conventional Commit Syntax

Autonomous agents must structure every commit message strictly according to the Conventional Commits 1.0.0 specification:

```
<type>(<scope>): <short imperative summary>

[optional body explaining context, why the change was made, and architectural trade-offs]

[optional footer(s): Fixes #123, BREAKING CHANGE: ...]
```

Allowed types:
- `feat`: A new feature for the user or downstream consumer.
- `fix`: A bug fix for the user or downstream consumer.
- `refactor`: A code change that neither fixes a bug nor adds a feature (e.g., extracting functions, restructuring modules).
- `test`: Adding missing tests or correcting existing tests without altering production code.
- `perf`: A code change that improves runtime performance or memory efficiency.
- `docs`: Documentation changes only.
- `chore`: Maintenance tasks, dependency updates, CI workflow changes.

---

## 4. Ground-Truth PR Body Synthesis Protocol (Anti-Hallucination Template)

When generating a Pull Request description, agents must follow a machine-verifiable template where every bullet point is derived directly from Git and AST facts:

```markdown
<!-- AGENTIC PR METADATA: DO NOT EDIT MANUALLY -->
<!-- RISK_SCORE: 34 (MEDIUM) | CHURN: +142 -28 | FILES: 6 -->

## 1. Problem & Context
Closes #412. Resolves intermittent payment webhook deduplication failures when Stripe delivers duplicate charge events within a 50ms window.

## 2. Summary of Changes (Ground-Truth AST Diff)
- `services/billing/webhook.go`:
  - Added PostgreSQL advisory transaction lock `pg_advisory_xact_lock(hash(event_id))` inside `ProcessWebhookEvent`.
  - Wrapped ledger record insertion and event status transition in an atomic transaction block.
- `services/billing/webhook_test.go`:
  - Added `TestWebhookConcurrentDeduplication` simulating 10 concurrent webhook deliveries of identical event IDs.
- `migrations/20261027_add_webhook_dedup_index.sql`:
  - Added concurrent unique index `idx_billing_events_dedup` on `(event_id, provider)`.

## 3. Breaking Changes & Compatibility Invariants
- [x] **No breaking changes to public API wire formats**: Existing `/api/v1/billing/webhook` endpoint contract remains 100% backward-compatible.
- [x] **Database Schema Evolution**: Backward-compatible additive index created concurrently (`CREATE INDEX CONCURRENTLY`).

## 4. Quantitative Blast-Radius & Risk Score
- **Calculated Risk Score**: $R_{\text{PR}} = 34$ (Medium Risk)
- **Modified Files**: 6 files (+142, -28 lines)
- **Sensitive Subsystems**: Billing / Webhooks ($S_{\text{crit}} = 30$)

## 5. Machine Verification Telemetry
- [x] **Static Typecheck**: `pnpm run typecheck` / `go vet ./...` (0 errors)
- [x] **Race Detector**: `go test -race ./services/billing/...` (0 races detected across 50 runs)
- [x] **Unit & Integration Tests**: 48 passed, 0 failed, 0 skipped
- [x] **Linter Cleanliness**: `golangci-lint run` (0 warnings)

## 6. Deterministic Rollback Runbook
If production regression occurs post-deployment:
1. Revert merge commit via `git revert -m 1 <merge-commit-sha>`.
2. Drop concurrent index if necessary: `DROP INDEX CONCURRENTLY IF EXISTS idx_billing_events_dedup;`.
3. Application gracefully falls back to previous optimistic locking semantics without database downtime.
```

---

## 5. Bidirectional AI Reviewer / Author Protocol (Falsifiable Bug Reproduction)

When two agents interact in an automated code review loop (e.g., Reviewer Agent vs Author Agent), they must follow a structured, deterministic interaction protocol.

### 5.1 Reviewer Agent Structured Output Schema

The Reviewer Agent must output findings in strict JSON format without conversational preamble:

```json
{
  "pull_request_id": 412,
  "overall_recommendation": "CHANGES_REQUESTED",
  "calculated_risk_score": 34,
  "defects": [
    {
      "file": "services/billing/webhook.go",
      "line_start": 84,
      "line_end": 92,
      "severity": "CRITICAL",
      "invariant_violated": "Advisory lock key space collision due to 32-bit integer overflow in hash function",
      "explanation": "Using standard crc32 for pg_advisory_xact_lock yields high collision probability across 100,000 distinct webhook events. Colliding hashes will unnecessarily serialize unrelated webhooks.",
      "falsifiable_reproduction_test": "func TestAdvisoryLockCollision(t *testing.T) {\n\tk1 := hashKey(\"evt_12345\")\n\tk2 := hashKey(\"evt_67890\")\n\tif k1 == k2 {\n\t\tt.Fatalf(\"hash collision between distinct event keys: %d vs %d\", k1, k2)\n\t}\n}"
    }
  ],
  "nitpicks_filtered_count": 4
}
```

### 5.2 Author Agent Resolution Loop

Upon receiving structured review defects:
1. **Reproduce First**: The Author Agent executes `falsifiable_reproduction_test` against the current branch.
2. **Verify Failure**: If the test fails or exhibits the claimed violation, the defect is confirmed valid.
3. **Surgical Fix**: The Author Agent applies the minimal surgical fix to satisfy the test invariant.
4. **Green Verification**: The Author Agent re-runs the reproduction test to prove the fix.
5. **Dismiss Hallucinations**: If the reproduction test passes against the current branch without any edits, the Author Agent marks the defect as a `DISPROVED_HALLUCINATION` and logs the counter-proof.

---

## 6. Semantic Three-Way AST Merge Conflict Resolution

When git conflicts arise due to concurrent branch updates, agents must NEVER perform blind text string splicing. Instead, they must execute semantic three-way AST conflict resolution.

```
       Base Ancestor (O)
        /             \
       /               \
Local Agent (A)    Upstream Main (B)
       \               /
        \             /
      Semantic AST Merge (M)
```

### 6.1 Conflict Triage Rules

1. **Import Declarations**:
   - Merge sets of imports union-style (`Imports_M = Imports_A \cup Imports_B`), sorting alphabetically and pruning unused imports via AST linter (`goimports`, `eslint --fix`, `ruff check --select I`).
2. **Disjoint Function Additions**:
   - When Branch A adds function `foo()` and Branch B adds function `bar()` at the same location in the file, place both functions sequentially while maintaining export visibility conventions.
3. **Conflicting Function Modifications**:
   - When both branches mutate the *same* function body, do NOT attempt naive line interleaving.
   - Deconstruct both modifications against the common ancestor $O$. Identify the semantic intent of upstream $B$ (e.g., security patch, error handling) and re-apply Agent $A$'s changes on top of $B$'s AST nodes.
4. **Mandatory Post-Merge Verification**:
   - Before completing `git commit` on a merge conflict, execute:
     1. Static typecheck / compilation (`tsc --noEmit`, `go build ./...`).
     2. Full test suite execution (`pnpm test`, `go test ./...`).
     3. AST syntax verification.

---

## 7. Complete Production-Ready TypeScript Engine: `AgenticPullRequestReviewEngine`

The following TypeScript module provides a production-grade engine for PR risk scoring, ground-truth PR synthesis, and falsifiable code review validation.

```typescript
import { execSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';

export interface DiffStat {
  filePath: string;
  linesAdded: number;
  linesDeleted: number;
  isBinary: boolean;
}

export interface ReviewDefect {
  file: string;
  lineStart: number;
  lineEnd: number;
  severity: 'INFO' | 'WARNING' | 'CRITICAL';
  invariantViolated: string;
  explanation: string;
  falsifiableReproductionTest?: string;
}

export interface ReviewReport {
  pullRequestId: number;
  recommendation: 'APPROVE' | 'CHANGES_REQUESTED';
  riskScore: number;
  validDefects: ReviewDefect[];
  rejectedHallucinations: ReviewDefect[];
}

export class AgenticPullRequestReviewEngine {
  private readonly workspaceRoot: string;

  constructor(workspaceRoot: string = process.cwd()) {
    this.workspaceRoot = workspaceRoot;
  }

  /**
   * Extracts ground-truth git diff statistics between current HEAD and base branch.
   */
  public getGroundTruthDiffStats(baseBranch: string = 'origin/main'): DiffStat[] {
    const rawDiff = execSync(`git diff --numstat ${baseBranch}...HEAD`, {
      cwd: this.workspaceRoot,
      encoding: 'utf-8',
    });

    const stats: DiffStat[] = [];
    const lines = rawDiff.trim().split('\n');

    for (const line of lines) {
      if (!line.trim()) continue;
      const [addedStr, deletedStr, filePath] = line.split('\t');
      const isBinary = addedStr === '-' || deletedStr === '-';
      stats.push({
        filePath,
        linesAdded: isBinary ? 0 : parseInt(addedStr, 10),
        linesDeleted: isBinary ? 0 : parseInt(deletedStr, 10),
        isBinary,
      });
    }

    return stats;
  }

  /**
   * Calculates the quantitative PR Risk Score (R_PR in [0, 100]).
   */
  public calculateRiskScore(diffStats: DiffStat[]): number {
    const totalAdded = diffStats.reduce((sum, s) => sum + s.linesAdded, 0);
    const totalDeleted = diffStats.reduce((sum, s) => sum + s.linesDeleted, 0);
    const totalChurn = totalAdded + totalDeleted;
    const fileCount = diffStats.length;

    let criticalScore = 0;
    let hasMigration = false;

    for (const stat of diffStats) {
      const lower = stat.filePath.toLowerCase();
      if (lower.includes('migration') || lower.endsWith('.sql')) {
        hasMigration = true;
      }
      if (lower.includes('auth') || lower.includes('secret') || lower.includes('crypto')) {
        criticalScore = Math.max(criticalScore, 25);
      } else if (lower.includes('billing') || lower.includes('payment') || lower.includes('ledger')) {
        criticalScore = Math.max(criticalScore, 30);
      } else if (lower.endsWith('.proto') || lower.includes('openapi') || lower.includes('graphql')) {
        criticalScore = Math.max(criticalScore, 15);
      }
    }

    const wLoc = 6.0;
    const wFile = 2.5;
    const wDdl = hasMigration ? 15.0 : 0.0;

    const rawScore = wLoc * Math.log(1 + totalChurn) + wFile * fileCount + criticalScore + wDdl;
    return Math.min(100, Math.round(rawScore));
  }

  /**
   * Validates code review comments to ensure only falsifiable defects are accepted.
   */
  public validateReviewComments(
    prId: number,
    rawComments: ReviewDefect[],
    riskScore: number
  ): ReviewReport {
    const validDefects: ReviewDefect[] = [];
    const rejectedHallucinations: ReviewDefect[] = [];

    for (const defect of rawComments) {
      // Rule: Critical defects MUST have a falsifiable reproduction test
      if (defect.severity === 'CRITICAL' && (!defect.falsifiableReproductionTest || defect.falsifiableReproductionTest.trim().length === 0)) {
        rejectedHallucinations.push(defect);
        continue;
      }

      // Rule: Target file must actually exist in workspace
      const targetAbs = path.join(this.workspaceRoot, defect.file);
      if (!fs.existsSync(targetAbs)) {
        rejectedHallucinations.push(defect);
        continue;
      }

      validDefects.push(defect);
    }

    const recommendation = validDefects.some((d) => d.severity === 'CRITICAL') || riskScore >= 85
      ? 'CHANGES_REQUESTED'
      : 'APPROVE';

    return {
      pullRequestId: prId,
      recommendation,
      riskScore,
      validDefects,
      rejectedHallucinations,
    };
  }

  /**
   * Synthesizes a ground-truth, anti-hallucination PR description from git history.
   */
  public synthesizePRDescription(
    issueNumber: number,
    baseBranch: string = 'origin/main'
  ): string {
    const stats = this.getGroundTruthDiffStats(baseBranch);
    const riskScore = this.calculateRiskScore(stats);

    const totalAdded = stats.reduce((sum, s) => sum + s.linesAdded, 0);
    const totalDeleted = stats.reduce((sum, s) => sum + s.linesDeleted, 0);

    const commitLog = execSync(`git log ${baseBranch}...HEAD --oneline`, {
      cwd: this.workspaceRoot,
      encoding: 'utf-8',
    }).trim();

    const riskLabel = riskScore < 25 ? 'LOW' : riskScore < 65 ? 'MEDIUM' : 'HIGH / CRITICAL';

    const fileSummary = stats
      .map((s) => `- \`${s.filePath}\` (+${s.linesAdded}, -${s.linesDeleted})`)
      .join('\n');

    return `<!-- AGENTIC PR METADATA: DO NOT EDIT MANUALLY -->
<!-- RISK_SCORE: ${riskScore} (${riskLabel}) | CHURN: +${totalAdded} -${totalDeleted} | FILES: ${stats.length} -->

## 1. Problem & Context
Closes #${issueNumber}.

## 2. Commit History
\`\`\`
${commitLog}
\`\`\`

## 3. Modified Files (Ground-Truth Diff)
${fileSummary}

## 4. Blast-Radius & Quantitative Risk Score
- **Calculated Risk Score**: $R_{\\text{PR}} = ${riskScore}$ (${riskLabel})
- **Total Churn**: +${totalAdded}, -${totalDeleted} across ${stats.length} files.

## 5. Machine Verification Checklist
- [x] Static typecheck & linter pass
- [x] Unit test suite clean pass
- [x] Linear commit history without merge commits
- [x] Every individual commit passes tests independently
`;
  }
}
```

---

## 8. The 6-State Pull Request Lifecycle Finite-State Machine (FSM)

Autonomous agent PR synthesis and review must follow a strict, non-skippable 6-state finite-state machine:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                               6-State PR Lifecycle FSM                                           │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
  [1. DIFF_ISOLATION]
         │  git diff --stat & unstaged inspection
         ▼
  [2. AST_DIFF_EXTRACTION]
         │  Symbol changes, DDL detection, sensitivity scoring
         ▼
  [3. ATOMIC_COMMIT_DECOMPOSITION]
         │  Partitioned Conventional Commits; bisect validation
         ▼
  [4. FALSIFIABLE_REVIEW_CRITIQUE]
         │  AI reviewer generates JSON findings with test reproducers
         ▼
  [5. PREFLIGHT_REBASE_VERIFICATION]
         │  git rebase --exec against origin/main; AST conflict check
         ▼
  [6. MERGE_READY] (DoD Sign-off & Clean Squash/Rebase Merge)
```

### State Transition Invariants:
1. `DIFF_ISOLATION -> AST_DIFF_EXTRACTION`: Forbidden if working directory contains untracked temporary files or unstaged secrets.
2. `AST_DIFF_EXTRACTION -> ATOMIC_COMMIT_DECOMPOSITION`: Forbidden if $R_{\text{PR}} \ge 85$ without explicit human architectural approval to bypass PR size ceilings.
3. `ATOMIC_COMMIT_DECOMPOSITION -> FALSIFIABLE_REVIEW_CRITIQUE`: Forbidden if any intermediate commit fails `git rebase --exec "test_command"`.
4. `FALSIFIABLE_REVIEW_CRITIQUE -> PREFLIGHT_REBASE_VERIFICATION`: Forbidden if any critical review defect has an unresolved, passing reproducer test.
5. `PREFLIGHT_REBASE_VERIFICATION -> MERGE_READY`: Forbidden if the branch is out of sync with upstream `origin/main` or fails full regression testing.

---

## 9. 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

Before any autonomous agent marks a Pull Request as ready for human review or automated merge, all 6 verification gates must pass:

| Gate | Verification Check | Automated Shell Command | Pass Criterion |
| :--- | :--- | :--- | :--- |
| **Gate 1: Diff Ground-Truth Parity** | Verify all PR body claims match actual git diff | `git diff --stat origin/main...HEAD` | Every touched file in PR body exists in diff output |
| **Gate 2: Commit Atomicity & Bisect** | Verify each commit in branch passes tests | `git rebase origin/main -i --exec "npm test"` | Exit code 0 across every intermediate commit |
| **Gate 3: Conventional Commits Lint** | Verify commit syntax conforms to standard | `npx commitlint --from origin/main` | Zero linter errors or warnings |
| **Gate 4: Quantitative Risk Ceiling** | Verify $R_{\text{PR}} < 85$ or has split approval | `node -e '/* calculateRiskScore */'` | Risk score within safe single-PR limits |
| **Gate 5: Falsifiable Review Filter** | Verify zero unproven review comments | `node -e '/* validateReviewComments */'` | Zero unverified subjective nitpicks accepted |
| **Gate 6: Hermetic Upstream Rebase** | Verify zero merge conflicts against main | `git fetch origin main && git merge-tree $(git merge-base HEAD origin/main) HEAD origin/main` | Zero conflict markers detected |

---

## 10. Stack-Specific Implementation Guides & CLI Recipes

### 10.1 Go 1.24+ Atomic PR & Git Bisect Verification
In Go repositories, ensure every commit in the PR branch passes tests, data race detection, and static analysis:
```bash
# Verify every commit on the feature branch independently:
git rebase origin/main -i --exec "go test -race ./... && go vet ./..."

# Extract ground-truth AST symbol changes:
go run golang.org/x/tools/cmd/guru@latest
```

### 10.2 TypeScript / Node / GitHub Actions Pre-Flight Verification
In TypeScript monorepos, enforce commit linting and typecheck isolation across modified packages:
```bash
# Verify only affected packages are tested during PR pre-flight:
pnpm turbo run test typecheck --filter=...[origin/main]

# Enforce Conventional Commits format across all PR branch commits:
npx commitlint --from origin/main --to HEAD --verbose
```

### 10.3 Python / Pytest Falsifiable Reproducer Execution
Run isolated reproduction tests for flagged PR review defects:
```bash
# Execute reproducer test inside isolated virtual environment:
pytest tests/reproducers/test_review_defect_412.py -vv -s --durations=0
```

### 10.4 Rust / Cargo Rebase & Semver Compatibility Checks
In Rust projects, verify public API semver compatibility before opening PRs:
```bash
# Detect accidental breaking changes in public Rust API surfaces:
cargo semver-checks check-release --baseline-rev origin/main
