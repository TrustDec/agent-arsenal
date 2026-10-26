---
description: Agentic continuous learning, Reflexion loops, trajectory distillation, post-mortem error analysis, living workspace memory extraction, candidate rule staging, anti-sycophantic rule firewalls, and self-evolving repository rules across Claude Code, Cursor, Windsurf, Roo Code, Pi, and OpenCode
globs: **/*{reflexion,learning,reflection,trajectory,distill,rule,memory,feedback,postmortem,retro}*.*,**/rules/**,**/.cursorrules,**/CLAUDE.md,**/AGENTS.md,**/.agents/**
alwaysApply: false
---

# Agentic Continuous Learning, Reflexion Loops & Dynamic Rule Distillation

> Add these rules to your project when designing, configuring, or operating autonomous coding agents, multi-turn pair programmers, or IDE assistants (Claude Code, Cursor Composer, Windsurf Cascade, Roo Code, Pi, OpenCode, Aider). Terminate the Amnesiac Agent tax and prevent sycophantic workaround poisoning by transforming multi-turn trajectory failures and human corrections into machine-verifiable, living repository rules.

---

## 1. Architectural Taxonomy: The Amnesiac Agent Trap vs Reflexion Loops

In modern autonomous software engineering, the single largest multiplier of token waste, latency degradation, and recurring bugs is the **Amnesiac Agent Trap**:

- **The Amnesiac Agent Trap ($O(E)$ Repeated Blunder Tax)**:
  - Autonomous agents operate without memory across separate conversational sessions. When an agent spends 12 turns debugging an obscure compiler issue (e.g. Svelte 5 rune boundaries, Go 1.24 weak pointer semantics, PostgreSQL lock timeout nuances, or custom monorepo alias paths), the discovered solution evaporates when the session terminates.
  - In the subsequent session, the agent makes the **exact same mistake**, repeats the same failing tool calls, wastes another 100,000 tokens, and forces the developer to re-explain the project's internal invariants.
- **The Sycophantic Workaround Curse (Rule Poisoning)**:
  - When naive self-updating rule systems are introduced without strict firewalls, agents exhibit **sycophantic degradation**: they solve immediate compile errors by taking the path of least resistance (e.g. appending `@ts-ignore`, casting to `any`, disabling linter rules with `eslint-disable`, skipping broken tests with `test.skip()`, or adding `--no-verify` to git commit hooks).
  - If allowed to distill rules without validation, the agent codifies these hacks as permanent team guidance (e.g., *"Always add @ts-ignore when imports fail"*), progressively corrupting repository health and developer trust.
- **The Reflexion Invariant (Dual-Loop Autonomous Evolution)**:
  - Autonomous learning must decouple the **Inner Execution Loop** (ReAct tool execution, compiler feedback, test cycles) from the **Outer Invariant Distillation Loop** (Reflexion post-mortem, counterfactual causal attribution, anti-poisoning filtering, and tiered rule promotion).
  - Failures are transformed into concrete, reproducible, machine-verifiable invariants backed by reproduction tests and linter constraints.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Trajectory Event: Complex Refactoring with 4 Failed Test Iterations                              │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: Amnesiac Agent / Sycophantic Hack]                               ▼ [PRODUCTION: Reflexion & Distillation Loop]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ Turn 1-4: Agent encounters TypeScript error.    │               │ Turn 1-4: Agent encounters TypeScript error.    │
│ Fails 3 times on complex generic schema.        │               │ Diagnoses structural mismatch in runtime guard. │
├─────────────────────────────────────────────────┤               ├─────────────────────────────────────────────────┤
│ Turn 5: Agent slaps `// @ts-ignore` to pass CI. │               │ Turn 5: Fixes root cause by tightening schema.  │
│ User asks: "Record what you learned to rules".  │               │ All tests pass. Outer Reflexion loop activates. │
├─────────────────────────────────────────────────┤               ├─────────────────────────────────────────────────┤
│ Corrupt Distillation:                           │               │ Post-Mortem Reflexion Engine:                   │
│ Writes to .cursorrules / CLAUDE.md:             │               │ 1. Isolate Causal Gap: False assumption on Zod. │
│ "When generic typing fails, use @ts-ignore".    │               │ 2. Anti-Poisoning Firewall: Reject workarounds. │
├─────────────────────────────────────────────────┤               │ 3. Formulate Invariant with Code Diff & Glob.   │
│ Consequence: Future agent sessions disable type │               ├─────────────────────────────────────────────────┤
│ safety globally; repository quality collapses.  │               │ Staged to .agents/candidates/zod-generics.md    │
│ Next session repeats identical runtime failure! │               │ Promoted to Canonical Rule after verification!  │
└─────────────────────────────────────────────────┘               └─────────────────────────────────────────────────┘
```

---

## 2. The 4-Stage Reflexion & Rule Distillation Pipeline

Every autonomous agent trajectory that encounters friction (compilation errors, test failures, tool exceptions, or human corrections) must pass through a 4-stage pipeline before any rule may be synthesized:

```
┌────────────────────────┐     ┌────────────────────────┐     ┌────────────────────────┐     ┌────────────────────────┐
│ Stage 1: Epistemic Gap │ ──> │ Stage 2: Counterfactual│ ──> │ Stage 3: Invariant     │ ──> │ Stage 4: Anti-Poisoning│
│  & Anomaly Detection   │     │   Causal Attribution   │     │  Synthesis & Schema    │     │  & Promotion Firewall  │
└────────────────────────┘     └────────────────────────┘     └────────────────────────┘     └────────────────────────┘
```

### Stage 1: Epistemic Gap & Anomaly Detection
Trigger the Reflexion evaluator when any of the following threshold conditions are met during a session:
1. **Iteration Count Threshold**: A single subtask requires $\ge 3$ consecutive failed attempts (compiler error, test failure, runtime crash).
2. **Backtracking / Reversion**: The agent reverts a file via `git checkout` or rewrites code completely after encountering unexpected behavior.
3. **Explicit Human Steering**: The human developer intervenes with phrases such as *"No, don't do that"*, *"We use X instead of Y"*, or *"Our convention requires Z"*.
4. **Tool Exception Cascade**: A tool execution returns non-zero exit codes, permission denials, or malformed input exceptions $\ge 2$ times.

### Stage 2: Counterfactual Causal Attribution
Perform root cause analysis to answer: *What false assumption did the agent make, and what objective invariant resolves it?*
- ❌ **Superficial Symptom Attribution**: *"The test failed because the timeout was too short."*
- ✅ **Counterfactual Causal Attribution**: *"The agent assumed asynchronous state updates in Svelte 5 resolve in the next microtask; however, DOM side-effects require `$tick()` or an explicit `$effect` lifecycle. Increasing the test timeout merely hid the race condition."*

### Stage 3: Invariant Synthesis & Canonical Rule Schema
Synthesize the learning into an actionable, non-conversational rule adhering strictly to the **Agent Arsenal Rule Schema**:

````markdown
---
description: [One-line trigger description with technology, problem, and solution]
globs: [Targeted file glob patterns; NEVER use catch-all wildcard for language-specific rules]
alwaysApply: false
---

# [Precise Domain Name]

- **[Descriptive Invariant Title]**:
  - ❌ **Anti-Pattern**: [Concrete description of the failing approach and why it fails]
  - ✅ **Production Invariant**: [Concrete specification of the required pattern with code snippet]
    ```[lang]
    // Minimal, self-contained, correct implementation
    ```
````

### Stage 4: Anti-Poisoning & Generalization Firewall
Run the synthesized candidate through the automated safety checks defined in Section 4. If any check fails, **the rule candidate is permanently rejected or demoted to an ephemeral session note**.

---

## 3. The 3-Tier Promotion Ladder: Living Workspace Memory

To protect the repository from rule bloat and noisy temporary advice, rules must advance through a tiered hierarchy:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ TIER 3: CANONICAL REPOSITORY LAW (CLAUDE.md, .cursorrules, .cursor/rules/*.mdc)        │
│ Criteria: >= 3 Independent Session Hits OR Explicit Human PR Approval                 │
└──────────────────────────────────────────▲─────────────────────────────────────────────┘
                                           │ Verified in CI & No Clashes
┌──────────────────────────────────────────┴─────────────────────────────────────────────┐
│ TIER 2: CANDIDATE RULE STAGING (.agents/candidates/<slug>.md)                          │
│ Criteria: Synthesized by Reflexion Pipeline with Machine-Proof Passing Tests           │
└──────────────────────────────────────────▲─────────────────────────────────────────────┘
                                           │ Anomaly Threshold Triggered
┌──────────────────────────────────────────┴─────────────────────────────────────────────┐
│ TIER 1: EPHEMERAL SESSION SCRATCHPAD (activeContext.md, decisionLog.md)                │
│ Criteria: In-flight execution notes; discarded or compacted upon task completion       │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

1. **Tier 1: Ephemeral Session Scratchpad (`activeContext.md` / `decisionLog.md`)**:
   - Stores current hypotheses, immediate test command outputs, and task progress.
   - Cleared, compacted, or reset when the git branch is merged. Never pollutes global context.
2. **Tier 2: Candidate Rule Staging (`.agents/candidates/<slug>.md`)**:
   - Contains candidate rules generated by the Reflexion loop.
   - Includes metadata frontmatter: `hitCount: 1`, `firstEncountered: <commit>`, `verificationProof: <test-command>`.
   - Invisible to regular agent prompt context unless specifically evaluated or targeted by matching globs.
3. **Tier 3: Canonical Repository Law (`rules/*.md`, `CLAUDE.md`, `.cursorrules`, `.cursor/rules/*.mdc`)**:
   - Promoted when a candidate rule reaches `hitCount >= 3` across distinct git sessions without regression, OR when explicitly reviewed and approved by a human maintainer in a pull request.
   - Fully committed and shared with the entire engineering team.

---

## 4. The 6 Absolute Anti-Poisoning Firewalls

Every rule candidate synthesized by an autonomous agent MUST pass all 6 firewalls before entering Tier 2 or Tier 3:

### Firewall 1: Strict Prohibition on Codifying Workarounds
- 🛑 **Immediate Disqualification**: Any candidate rule proposing the following is rejected instantly:
  - Disabling compiler checks: `@ts-ignore`, `@ts-nocheck`, `// eslint-disable`, `# noqa`, `any` casting.
  - Skipping test assertions: `test.skip`, `xit`, `it.todo`, commenting out assertions, weakening thresholds.
  - Bypassing commit/push gates: `--no-verify`, `git commit -n`, `--force`.
  - Wall-clock sleeps to patch race conditions: `sleep(5000)`, `setTimeout(..., 3000)`.

### Firewall 2: Environmental Transience Eviction
- 🛑 **Reject Flaky / Ephemeral Noise**:
  - Network timeouts, DNS blips, 502/503/504 HTTP status codes from external package registries.
  - Local host conflicts: `EADDRINUSE: port 3000 already in use`, `out of disk space`.
  - Ephemeral file locks, OS PID collisions, or dirty `.git/index.lock` files.
  - Rules must capture **structural code invariants**, never transient operational hiccups.

### Firewall 3: Rule Deduplication & Semantic Clash Verification
- 🛑 **No Duplicate or Contradictory Rules**:
  - The engine must compute the lexical and semantic similarity between the candidate and existing rules in `rules/`, `CLAUDE.md`, and `.cursorrules`.
  - If semantic similarity $> 0.82$, update the hit counter of the existing rule rather than generating a duplicate.
  - If the candidate contradicts an existing canonical rule, block automatic staging and trigger a human review notification.

### Firewall 4: Concrete AST, Glob & Regex Trigger Precision
- 🛑 **Ban Vague, Catch-All Rules**:
  - ❌ Vague: `"Be careful with asynchronous code in components."` (Globs: `**/*.*`)
  - ✅ Specific: `"When defining Svelte 5 `$derived` state that branches across multiple conditions, use `$derived.by(() => ...)` instead of IIFEs inside `$derived()`."` (Globs: `**/*.svelte,**/*.svelte.ts`)

### Firewall 5: Machine-Proof Verification Requirement
- 🛑 **Every Rule Must Provide Machine Evidence**:
  - The rule distillation payload must include:
    1. The exact command that failed (e.g. `pnpm test:unit src/auth/jwt.test.ts`).
    2. The exact error output before the fix.
    3. The command that succeeded after the architectural invariant was applied.
  - If the invariant cannot be verified by a compiler, linter, or automated test, it cannot be promoted.

### Firewall 6: Minimal Actionable Token Budget
- 🛑 **Zero Conversational Fluff**:
  - Distilled rules must not contain introductory pleasantries, self-congratulations (*"In this session, I successfully solved..."*), or lengthy theoretical background.
  - Hard token ceiling: Maximum **400 words** per individual rule invariant. High density, immediate readability.

---

## 5. Production-Ready Reflexion Guard & Trajectory Distiller

The following production-grade TypeScript engine inspects multi-turn agent execution logs, detects epistemic gaps, enforces the 6 anti-poisoning firewalls, and stages candidate rules deterministically:

```typescript
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as crypto from 'node:crypto';

export interface TrajectoryTurn {
  turnNumber: number;
  tool: string;
  input: Record<string, unknown>;
  output: string;
  exitCode?: number;
  userFeedback?: string;
}

export interface RuleCandidate {
  slug: string;
  title: string;
  globs: string;
  antiPattern: string;
  productionInvariant: string;
  codeSnippet: string;
  verificationCommand: string;
  sourceSessionId: string;
}

export class TrajectoryReflexionDistiller {
  private static readonly BANNED_PATTERNS = [
    /@ts-ignore/i,
    /@ts-nocheck/i,
    /eslint-disable/i,
    /--no-verify/i,
    /test\.skip/i,
    /xit\(/i,
    /sleep\(\d{3,}\)/i,
    /EADDRINUSE/i,
    /ECONNRESET/i,
    /502 Bad Gateway/i
  ];

  constructor(private readonly repoRoot: string) {}

  /**
   * Evaluates an agent session trajectory to determine if Reflexion distillation is warranted.
   */
  public shouldTriggerReflexion(turns: TrajectoryTurn[]): boolean {
    const failedTurns = turns.filter(t => (t.exitCode !== undefined && t.exitCode !== 0) || (t.output && /error|fatal|exception|failed/i.test(t.output)));
    const hasHumanCorrection = turns.some(t => t.userFeedback && /no|don't|incorrect|wrong|revert|stop/i.test(t.userFeedback));
    
    // Trigger if >= 3 failures or direct human correction with follow-up fix
    return failedTurns.length >= 3 || hasHumanCorrection;
  }

  /**
   * Applies the 6 Anti-Poisoning Firewalls to a proposed rule candidate.
   */
  public validateCandidate(candidate: RuleCandidate): { valid: boolean; reason?: string } {
    const combinedText = `${candidate.title} ${candidate.antiPattern} ${candidate.productionInvariant} ${candidate.codeSnippet}`;

    // Firewall 1 & 2: Banned workarounds and ephemeral noise
    for (const pattern of TrajectoryReflexionDistiller.BANNED_PATTERNS) {
      if (pattern.test(combinedText)) {
        return { valid: false, reason: `Firewall violation: Contains prohibited workaround or transient pattern [${pattern.source}]` };
      }
    }

    // Firewall 4: Glob specificity (disallow global catch-all on language-specific rules)
    if (candidate.globs.trim() === '**/*.*' || candidate.globs.trim() === '*') {
      return { valid: false, reason: 'Firewall violation: Catch-all globs are prohibited. Specify target extensions.' };
    }

    // Firewall 5: Verification command required
    if (!candidate.verificationCommand || candidate.verificationCommand.trim().length === 0) {
      return { valid: false, reason: 'Firewall violation: Rule candidate must provide a machine-verifiable test/build command.' };
    }

    // Firewall 6: Word count ceiling (max 400 words)
    const wordCount = combinedText.split(/\s+/).filter(Boolean).length;
    if (wordCount > 400) {
      return { valid: false, reason: `Firewall violation: Candidate exceeds 400-word budget (${wordCount} words).` };
    }

    return { valid: true };
  }

  /**
   * Stages a validated candidate into .agents/candidates/<slug>.md with deduplication.
   */
  public stageCandidate(candidate: RuleCandidate): { staged: boolean; filePath: string; hitCount: number } {
    const validation = this.validateCandidate(candidate);
    if (!validation.valid) {
      throw new Error(`Candidate rejected: ${validation.reason}`);
    }

    const stagingDir = path.join(this.repoRoot, '.agents', 'candidates');
    fs.mkdirSync(stagingDir, { recursive: true });

    const safeSlug = candidate.slug.toLowerCase().replace(/[^a-z0-9_-]/g, '-');
    const filePath = path.join(stagingDir, `${safeSlug}.md`);

    let hitCount = 1;
    if (fs.existsSync(filePath)) {
      const existingContent = fs.readFileSync(filePath, 'utf-8');
      const match = existingContent.match(/hitCount:\s*(\d+)/);
      if (match) {
        hitCount = parseInt(match[1], 10) + 1;
      }
    }

    const markdown = [
      '---',
      `title: ${JSON.stringify(candidate.title)}`,
      `globs: ${JSON.stringify(candidate.globs)}`,
      `hitCount: ${hitCount}`,
      `lastUpdated: ${JSON.stringify(new Date().toISOString())}`,
      `sourceSessionId: ${JSON.stringify(candidate.sourceSessionId)}`,
      `verificationCommand: ${JSON.stringify(candidate.verificationCommand)}`,
      'alwaysApply: false',
      '---',
      '',
      `# ${candidate.title}`,
      '',
      `- **${candidate.title}**:`,
      `  - ❌ **Anti-Pattern**: ${candidate.antiPattern}`,
      `  - ✅ **Production Invariant**: ${candidate.productionInvariant}`,
      '    ```typescript',
      candidate.codeSnippet.trim(),
      '    ```',
      ''
    ].join('\n');

    fs.writeFileSync(filePath, markdown, 'utf-8');
    return { staged: true, filePath, hitCount };
  }
}
```

---

## 6. The Trajectory Reflexion & Self-Correction FSM

```
                  ┌────────────────────────┐
                  │    TASK_EXECUTION      │
                  └───────────┬────────────┘
                              │ Tool Calls & Commits
                              ▼
                  ┌────────────────────────┐
                  │   EVALUATION_VERIFY    │
                  └─────┬────────────┬─────┘
           Passed First │            │ Repeated Failures (>= 3)
           Attempt      │            │ OR Human Steering
                        ▼            ▼
             ┌────────────────┐  ┌────────────────────────┐
             │ TASK_SUCCEEDED │  │ EPISTEMIC_ANOMALY_HIT  │
             └────────────────┘  └───────────┬────────────┘
                                             │
                                             ▼
                                 ┌────────────────────────┐
                                 │ CAUSAL_POST_MORTEM     │
                                 │ Isolate root false     │
                                 │ mental model / trap    │
                                 └───────────┬────────────┘
                                             │
                                             ▼
                                 ┌────────────────────────┐
                                 │ INVARIANT_SYNTHESIS    │
                                 │ Formulate Anti-Pattern │
                                 │ vs Production Invariant│
                                 └───────────┬────────────┘
                                             │
                                             ▼
                                 ┌────────────────────────┐
                 Rejected        │ ANTI_POISON_FIREWALL   │
           ┌─────────────────────┤ Check workarounds, AST │
           │                     │ globs, test proof      │
           ▼                     └───────────┬────────────┘
┌─────────────────────┐                      │ Passed Firewalls
│ DISCARD_OR_SCRATCH  │                      ▼
│ Local note only     │          ┌────────────────────────┐
└─────────────────────┘          │ TIER_2_STAGING         │
                                 │ .agents/candidates/    │
                                 └───────────┬────────────┘
                                             │ Hit Count >= 3 OR
                                             │ Human PR Sign-off
                                             ▼
                                 ┌────────────────────────┐
                                 │ TIER_3_CANONICAL_LAW   │
                                 │ rules/*.md, CLAUDE.md  │
                                 └────────────────────────┘
```

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Check | Automated Enforcement Target | Failure Threshold Action |
| :--- | :--- | :--- | :--- |
| **Gate 1: Anomaly Qualification** | Subtask failure count $\ge 3$ or explicit human steering recorded | Trajectory turn logs parsed | Abort distillation; treat as normal clean execution |
| **Gate 2: Causal Isolation** | Root cause isolated to architectural / domain invariant | Post-mortem diff analysis | Reject superficial attribution (e.g. timeout bumps) |
| **Gate 3: Anti-Poisoning Scan** | Zero occurrences of `@ts-ignore`, `skip`, `--no-verify`, sleeps | Regex & AST token scan | Disqualify candidate immediately; log warning |
| **Gate 4: Trigger Specificity** | Specific file glob pattern provided (no `*` or `**/*.*`) | Glob syntax verification | Block staging until narrow extension/path provided |
| **Gate 5: Machine-Proof Test** | Passing test, compiler, or linter command attached | Subprocess execution | Demote to Tier 1 session note if unverified |
| **Gate 6: Promotion Governance** | Tier 2 candidate reaches hit count $\ge 3$ or human approval | Candidate metadata audit | Retain in staging; do not pollute canonical rules |

---

## 8. Absolute Prohibitions (Anti-Patterns)

| Anti-Pattern | Immediate Risk | Production Invariant |
| :--- | :--- | :--- |
| **Bypassing Types via `@ts-ignore` to "Fix" Build** | Disables compiler safety; creates silent runtime crashes in production | Fix underlying type definition or extract explicit type guard |
| **Codifying Flaky Network Errors into Rules** | Pollutes repository rules with irrelevant noise (e.g. npm 503s) | Filter transient I/O and process errors; record only structural code laws |
| **Catch-All Wildcard Globs (`**/*.*`)** | Injects domain-specific rules into unrelated file contexts, wasting tokens | Use surgical globs (e.g. `src/features/**/*.store.ts`) |
| **Unbounded Rule Proliferation** | Bloats context window; triggers prompt attention saturation | Enforce 3-tier promotion ladder and semantic deduplication |
| **Conversational / Chatty Rule Format** | Consumes context tokens with narrative storytelling | Strictly adhere to Title $\to$ Anti-Pattern $\to$ Invariant $\to$ Code schema |
| **Promoting Unverified Workarounds** | Normalizes substandard engineering practices across the team | Require automated reproduction and verification proof in CI |
