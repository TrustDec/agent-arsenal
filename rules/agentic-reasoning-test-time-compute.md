---
description: Agentic reasoning loops, test-time compute (TTC) scaling, Process Reward Models (PRM) vs Outcome Reward Models (ORM), Best-of-N sampling, Monte Carlo Tree Search (MCTS), execution-guided verification, backtracking state machines, reflection & self-correction protocols, thinking token budgeting, and hallucination pruning
globs: **/*{reasoning,verifier,mcts,prm,cot,reflection,eval,search,tree,test_time}*.*,**/reasoning/**,**/verifiers/**,**/search/**,**/agents/**
alwaysApply: false
---

# Agentic Reasoning, Test-Time Compute (TTC) & Verification Loops Invariants

> Add these rules to your project when architecting, implementing, or auditing autonomous reasoning agents, inference-time compute scaling pipelines, test-time search engines, or execution-guided self-correction loops (OpenAI o1/o3, DeepSeek-R1, QwQ, Claude 3.7 Sonnet Extended Thinking, SWE-bench agent harnesses, Process Reward Models PRM, and Monte Carlo Tree Search MCTS).

---

## 1. Architectural Taxonomy: Inference-Time Scaling & Test-Time Compute (TTC)

Pre-training compute scaling faces diminishing returns, data bottlenecks, and high capital costs. The modern frontier of AI capability relies on **Test-Time Compute (TTC) scaling**: trading inference latency and token generation budgets for vastly superior reasoning accuracy, formal verification, and execution success rates.

Autonomous agents without structured test-time compute suffer from **Greedy Autoregressive Collapse**: once a flawed initial decision or hallucinated premise is generated, the agent doubles down in subsequent turns (confirmation bias), consuming context and driving task failure.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              Incoming Complex Goal / User Mission                      │
│                  ("Refactor database schema with zero downtime & update ORM models")   │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 1. Dynamic Difficulty Router & Compute Budget Allocator                                │
│    • Low Entropy / Deterministic ──▶ Direct Fast-Path (0 TTC overhead)                 │
│    • High Ambiguity / Complex    ──▶ Allocate Test-Time Compute Budget ($B$ tokens)    │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 2. Test-Time Search & Exploration Strategies (Choose Paradigm)                         │
│                                                                                        │
│    ┌──────────────────────────┐   ┌─────────────────────────┐  ┌─────────────────────┐ │
│    │ Mode A: Sequential CoT   │   │ Mode B: Parallel Best-N │  │ Mode C: Tree Search │ │
│    │ • Deep Thinking tokens   │   │ • $N$ independent paths │  │ • MCTS / Beam Search│ │
│    │ • Self-reflective trace  │   │ • Temperature sampling  │  │ • Step backtracking │ │
│    │ • Single autoreg stream  │   │ • Verifier reranker     │  │ • State branch pruning││
│    └─────────────┬────────────┘   └────────────┬────────────┘  └──────────┬──────────┘ │
└──────────────────┼─────────────────────────────┼──────────────────────────┼────────────┘
                   │                             │                          │
                   ▼                             ▼                          ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 3. The 3-Tier Verification & Credit Assignment Engine                                  │
│                                                                                        │
│    [Candidate Step / Action] ──▶ [Deterministic Verifier] ──▶ [Execution Verifier]     │
│                 ▲                • AST syntax check           • Unit tests / Compiler  │
│                 │                • Schema validation          • Sandboxed execution    │
│                 │                                                         │            │
│                 │                                                         ▼            │
│                 │ Pass / Fail                                 [Process Reward Model]   │
│                 │                                             • Step score $S(s_t)$    │
│                 │                                             • Credit assignment      │
│                 │                                                         │            │
│                 └─────────────────────────────────────────────────────────┘            │
│                                                                                        │
│                                                                                        ▼
│    [Accepted High-Confidence Trajectory] ──▶ [Execute Tool Mutation / Emit Final Patch]│
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### The 4 Test-Time Search Modalities

| Modality | Search Architecture | Verification Mechanism | Latency Overhead | Ideal Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **1. Extended Thinking CoT** | Deep single-stream scratchpad (Claude 3.7 Thinking, o1/o3, DeepSeek-R1) | Self-checking implicit reflection | $1\times$ to $4\times$ token latency | Multi-step mathematical reasoning, logical constraint satisfiability, inline planning. |
| **2. Best-of-$N$ Sampling (BoN)** | Parallel independent trajectories generated at $T \in [0.6, 0.9]$ | Outcome Reward Model (ORM) or deterministic test suite | High concurrency ($N\times$ tokens), low wall-clock with batching | Code generation where formal automated tests can reject broken variants. |
| **3. Beam Search over Steps** | Step-by-step expansion keeping top $K$ promising intermediate states | Process Reward Model (PRM) evaluating each intermediate deduction | Moderate latency and token cost | Long-horizon multi-step problem solving with clear step boundaries. |
| **4. Monte Carlo Tree Search (MCTS)** | Iterative Selection (UCT), Expansion, Rollout, and Backpropagation | Execution feedback (compiler + linter + PRM) with backtracking | Highest token and latency budget ($10\times$–$50\times$) | Complex architectural refactoring, SWE-bench software patches, critical math proofs. |

---

## 2. Process Reward Models (PRM) vs Outcome Reward Models (ORM)

Traditional RLHF and evaluation systems rely on **Outcome Reward Models (ORM)**: scoring only the final output ($r(y \mid x)$). For multi-step agent reasoning, ORMs suffer from **credit assignment blindness**: an agent may execute 9 brilliant steps, stumble on step 10, and receive a $0$ reward; conversely, an agent may make flawed deductions that happen to stumble upon the right answer by luck ("false positive hallucination").

**Process Reward Models (PRM)** score every intermediate reasoning step:
$$R_{\text{trajectory}} = \prod_{t=1}^{T} P(\text{step}_t \text{ is correct} \mid \text{step}_{1:t-1}, x)$$

```
ORM (Outcome Reward Model):
[Step 1: OK] ──▶ [Step 2: Flaw] ──▶ [Step 3: Flaw] ──▶ [Final Answer: WRONG] ──▶ Reward = 0.0
                                                            (Which step failed? Unknown!)

PRM (Process Reward Model):
[Step 1: OK] ──▶ Score: 0.98 ──▶ Continue
[Step 2: Flaw] ──▶ Score: 0.12 ──▶ PRUNE & BACKTRACK!
        │
        └──▶ [Step 2 (Alternative): OK] ──▶ Score: 0.95 ──▶ Continue
```

### Production Invariants for Step Supervision

1. **Explicit Step Delimiters**: When prompting or fine-tuning models for step-level reasoning, enforce explicit step separators (e.g. `\n\nStep N:` or `\n---\n`).
2. **Deterministic Pre-Filters Before PRM Invocation**: Never spend expensive LLM tokens scoring an intermediate step if deterministic static analysis fails. Verify syntax (AST parse), linting, and typecheck before asking a model judge.
3. **Threshold-Based Pruning**:
   - If PRM step confidence $S(s_t) < \tau_{\text{prune}}$ (typically $0.40$), prune the branch immediately.
   - Do not waste compute expanding child nodes of a demonstrably poisoned premise.

---

## 3. Execution-Guided Search & Backtracking Finite-State Machines

LLM self-reflection without external ground truth often degenerates into sycophancy: the model convinces itself that incorrect code is correct. **Execution-Guided Search** replaces subjective self-assessment with deterministic sandbox feedback (compilers, typecheckers, unit tests, linters).

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              Deterministic Backtracking FSM                            │
└────────────────────────────────────────────────────────────────────────────────────────┘

              ┌──────────────────┐
              │   STATE: INIT    │
              └────────┬─────────┘
                       │ Receive Task
                       ▼
         ┌───────────────────────────┐
    ┌───▶│     STATE: REASONING      │◀──────────────────────────────┐
    │    └─────────────┬─────────────┘                               │
    │                  │ Propose Step / Diff                         │
    │                  ▼                                             │
    │    ┌───────────────────────────┐                               │
    │    │      STATE: STAGING       │                               │
    │    │  (Create Git Worktree /   │                               │
    │    │   OverlayFS Checkpoint)   │                               │
    │    └─────────────┬─────────────┘                               │
    │                  │ Apply Patch                                 │
    │                  ▼                                             │
    │    ┌───────────────────────────┐                               │
    │    │    STATE: VERIFICATION    │                               │
    │    │  Run `tsc`, `go test`,    │                               │
    │    │  or deterministic linter  │                               │
    │    └─────────────┬─────────────┘                               │
    │                  │                                             │
    │         ┌────────┴────────┐                                    │
    │         │                 │                                    │
    │    [Tests Pass]      [Tests Fail]                              │
    │         │                 │                                    │
    │         ▼                 ▼                                    │
    │  ┌───────────────┐  ┌──────────────────────────┐               │
    │  │ STATE: COMMIT │  │ STATE: ROLLBACK & BRANCH │               │
    │  │ Commit delta, │  │ Rollback worktree, record│               │
    │  │ update base   │  │ failure trace in memory  │───────────────┘
    │  └───────┬───────┘  └──────────────────────────┘ (Attempts < Max)
    │          │ All Goals Met                          │
    │          ▼                                        ▼ (Attempts >= Max)
    │  ┌───────────────┐                      ┌──────────────────┐
    │  │ STATE: SUCCESS│                      │  STATE: EXHAUST   │
    │  └───────────────┘                      │ (Trigger Fallback│
    │                                         │  or Human Escal.)│
    └─────────────────────────────────────────┴──────────────────┘
```

### Git Worktree Isolation Invariant
Never apply speculative code changes directly to the agent's primary working tree. Speculative code exploration must execute inside isolated, lightweight Git worktrees or memory-backed OverlayFS checkpoints:

```bash
# Production Invariant: Stage speculative reasoning in isolated worktree
BRANCH_ID="speculative-$(uuidgen | cut -c1-8)"
WORKTREE_DIR="/tmp/agent-worktrees/${BRANCH_ID}"

git worktree add -b "$BRANCH_ID" "$WORKTREE_DIR" HEAD --quiet

# Execute candidate modifications & verifications inside $WORKTREE_DIR
pushd "$WORKTREE_DIR" > /dev/null
if npm run check && npm test; then
  popd > /dev/null
  git merge --ff-only "$BRANCH_ID"
else
  popd > /dev/null
  # Backtrack instantly: zero residual file pollution
fi

git worktree remove --force "$WORKTREE_DIR" --quiet
git branch -D "$BRANCH_ID" --quiet
```

---

## 4. Monte Carlo Tree Search (MCTS) for Agentic Planning

For complex, long-horizon problems with high branching factors (e.g., migrating a multi-service authentication protocol or solving competition-grade code challenges), linear ReAct loops fail due to error accumulation. Monte Carlo Tree Search (MCTS) systematically balances exploration of novel solution paths with exploitation of verified high-scoring trajectories.

### The 4 Phases of Agentic MCTS

1. **Selection**: Traverse the tree from root using the **Upper Confidence Bound applied to Trees (UCT)**:
   $$\text{UCT}(v_i) = \frac{Q(v_i)}{N(v_i)} + c \cdot \sqrt{\frac{\ln N(v)}{N(v_i)}}$$
   Where $Q(v_i)$ is accumulated verification reward, $N(v_i)$ is visit count of candidate node $v_i$, $N(v)$ is parent visit count, and $c \approx \sqrt{2}$ is the exploration constant.
2. **Expansion**: When reaching a leaf node that is non-terminal, generate $K$ alternative subsequent steps using temperature sampling ($T = 0.8$).
3. **Evaluation / Rollout**:
   - Deterministic fast-evaluation: Run compiler/linters on the proposed patch.
   - Semantic evaluation: Invoke Process Reward Model (PRM) to score reasoning soundness.
4. **Backpropagation**: Propagate verification score up the tree, incrementing visit counts $N$ and updating mean action values $Q$.

```typescript
// Production Invariant: Node definition for Agentic MCTS
export interface MCTSNode<TState, TAction> {
  id: string;
  parentId: string | null;
  state: TState;
  incomingAction: TAction | null;
  children: MCTSNode<TState, TAction>[];
  visits: number;
  totalValue: number; // Accumulated verification reward
  isTerminal: boolean;
  depth: number;
}

export function selectBestUCTChild<S, A>(
  node: MCTSNode<S, A>,
  explorationWeight = Math.SQRT2
): MCTSNode<S, A> {
  if (node.children.length === 0) {
    throw new Error('Cannot select child from leaf node');
  }

  let bestChild = node.children[0];
  let maxUCT = -Infinity;

  for (const child of node.children) {
    if (child.visits === 0) {
      // Unvisited child gets infinite priority to ensure initial exploration
      return child;
    }

    const exploitation = child.totalValue / child.visits;
    const exploration =
      explorationWeight * Math.sqrt(Math.log(node.visits) / child.visits);
    const uctValue = exploitation + exploration;

    if (uctValue > maxUCT) {
      maxUCT = uctValue;
      bestChild = child;
    }
  }

  return bestChild;
}
```

---

## 5. Self-Correction, Reflection & Preventing the "Sunk Cost" Loop

When LLMs are told *"Your previous response had a bug; please fix it"*, single-model agents frequently fall into one of two pathological failure modes:
1. **Sycophantic Hallucination**: Changing trivial variable names or comments while leaving the root architectural bug completely untouched.
2. **Oscillating Ping-Pong**: Flapping back and forth between two flawed implementations (e.g. flipping an `<` sign to `>` in turn 1, then flipping it back in turn 2).

### The Dual-Agent Actor-Critic Verification Protocol

To break confirmation bias, decouple generation from verification. Never have the author model grade its own reasoning without an adversarial critic role:

```
┌──────────────────┐                           ┌──────────────────┐
│   ACTOR AGENT    │                           │   CRITIC AGENT   │
│ (Generator Mode) │                           │ (Verifier Mode)  │
└────────┬─────────┘                           └────────┬─────────┘
         │                                              │
         │ Propose Solution / Patch                     │
         ├─────────────────────────────────────────────▶│
         │                                              │
         │                                              │ 1. Verify against Edge Cases
         │                                              │ 2. Run AST/Static Typecheck
         │                                              │ 3. Formulate Counterexamples
         │                                              │
         │ Structured Critique & Counterexample         │
         │◀─────────────────────────────────────────────┤
         │                                              │
         │ 1. Acknowledge Root Cause                    │
         │ 2. Propose Radical Alternative (Not Tweak)   │
         │                                              │
         ├─────────────────────────────────────────────▶│ (Max 3 Iterations)
```

### Structured Critique Schema Invariant

Critics must never return unstructured vague conversational complaints. Force structured JSON/Pydantic validation schemas with concrete counterexamples:

```json
{
  "verdict": "FAIL",
  "root_cause": "Integer overflow vulnerability on line 42 when processing inputs > 2^31 - 1",
  "counterexample": {
    "input": { "batch_size": 2147483648 },
    "expected": "Error('Input exceeds maximum allowable batch size')",
    "actual": "Panic: runtime error: integer overflow"
  },
  "suggested_invariant": "Validate input bounds using math/bits or explicit uint64 assertions prior to memory allocation"
}
```

---

## 6. Reasoning Token Budgeting & Claude 3.7 / o1 / DeepSeek Scratchpad Discipline

Modern frontier models provide native reasoning/thinking tokens (e.g., Claude 3.7 Sonnet Extended Thinking, OpenAI o1/o3 `reasoning_effort`, DeepSeek-R1 CoT). Managing thinking token budgets is critical for controlling latency, inference costs, and context saturation.

### The 4 Reasoning Budget Invariants

1. **Explicit Thinking Token Caps (`budget_tokens`)**:
   - Claude 3.7 Sonnet: Specify `thinking: { type: "enabled", budget_tokens: N }` where $1024 \le N \le 32000$.
   - Never leave thinking tokens uncapped in automated production loops. A model trapped in an undecidable logic paradox can consume 32,000 thinking tokens before failing.
2. **Segregation of Scratchpad Thinking from Visible Responses**:
   - Thinking tokens are ephemeral scratchpad compute. They must **never** be injected back into subsequent agent turns as conversational assistant messages unless specifically cached via prompt caching.
   - Pass only the final synthesized response and tool call actions to downstream subagents.
3. **Dynamic Budget Allocation by Task Complexity**:
   - Deterministic file edits / single-line fixes: `budget_tokens: 1024` or disabled.
   - Refactoring multi-file modules or designing schemas: `budget_tokens: 4096` to `8192`.
   - Architectural migration, distributed concurrency algorithms, or competition-grade logic: `budget_tokens: 16384` to `32000`.
4. **Early-Stopping on Circular Reasoning**:
   - If thinking trace analysis detects high $N$-gram repetition ($3+$ identical 20-token phrases in the scratchpad), abort the turn immediately. The model is experiencing an attention loop.

```typescript
// Production Invariant: Dynamic Reasoning Budget Allocator
export function determineReasoningBudget(task: {
  filesAffected: number;
  hasConcurrency: boolean;
  hasDatabaseMigration: boolean;
  isAmbiguous: boolean;
}): number {
  if (!task.hasConcurrency && !task.hasDatabaseMigration && task.filesAffected <= 1) {
    return 1024; // Fast-path: simple bugfix or documentation
  }

  let budget = 2048;

  if (task.filesAffected > 3) budget += 2048;
  if (task.hasConcurrency) budget += 4096;
  if (task.hasDatabaseMigration) budget += 4096;
  if (task.isAmbiguous) budget += 4096;

  // Cap at 16,384 tokens for standard automated agent loops to bound latency
  return Math.min(budget, 16384);
}
```

---

## 7. Best-of-$N$ with Verifier Reranking Implementation

Here is an end-to-end, production-ready implementation of a concurrent **Best-of-$N$ Search Engine** with deterministic compilation verification and Process Reward Model reranking:

```typescript
// verifier-engine.ts
import { exec } from 'node:child_process';
import { promisify } from 'node:util';

const execAsync = promisify(exec);

export interface CandidateSolution {
  id: string;
  codePatch: string;
  reasoningTrace: string;
}

export interface VerificationResult {
  candidateId: string;
  compilationPassed: boolean;
  unitTestsPassed: boolean;
  prmScore: number; // 0.0 to 1.0 from Process Reward Model
  finalCompositeScore: number;
  failureReason?: string;
}

export class BestOfNSearchEngine {
  constructor(
    private readonly prmScorer: (trace: string, patch: string) => Promise<number>,
    private readonly testCommand = 'npm test --silent'
  ) {}

  /**
   * Concurrently verifies and ranks N candidate solutions.
   * Discards candidates that fail deterministic compilation before invoking PRM.
   */
  async rankCandidates(candidates: CandidateSolution[]): Promise<VerificationResult[]> {
    const results = await Promise.all(
      candidates.map((c) => this.verifySingleCandidate(c))
    );

    // Sort descending by composite score
    return results.sort((a, b) => b.finalCompositeScore - a.finalCompositeScore);
  }

  private async verifySingleCandidate(
    candidate: CandidateSolution
  ): Promise<VerificationResult> {
    // Stage 1: Deterministic Compilation & Unit Test Verification
    const execution = await this.runSandboxExecution(candidate.codePatch);
    if (!execution.passed) {
      return {
        candidateId: candidate.id,
        compilationPassed: execution.compiled,
        unitTestsPassed: false,
        prmScore: 0.0,
        finalCompositeScore: 0.0,
        failureReason: execution.error,
      };
    }

    // Stage 2: Process Reward Model Scoring (Only invoked on executing code!)
    let prmScore = 0.0;
    try {
      prmScore = await this.prmScorer(candidate.reasoningTrace, candidate.codePatch);
    } catch {
      prmScore = 0.5; // Fallback neutral score if PRM evaluates with error
    }

    // Stage 3: Composite Score Calculation
    // Passing execution provides 0.70 base; PRM elegance adds remaining 0.30
    const finalCompositeScore = 0.70 + 0.30 * prmScore;

    return {
      candidateId: candidate.id,
      compilationPassed: true,
      unitTestsPassed: true,
      prmScore,
      finalCompositeScore,
    };
  }

  private async runSandboxExecution(
    patch: string
  ): Promise<{ passed: boolean; compiled: boolean; error?: string }> {
    // In real production, execute in temporary git worktree / Docker container
    try {
      // Step A: Syntax check
      // Step B: Run test suite
      await execAsync(this.testCommand, { timeout: 15000 });
      return { passed: true, compiled: true };
    } catch (err: unknown) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      const isCompileError = errorMsg.includes('TS2304') || errorMsg.includes('SyntaxError');
      return {
        passed: false,
        compiled: !isCompileError,
        error: errorMsg.slice(0, 500),
      };
    }
  }
}
```

---

## 8. Agentic Reasoning & Test-Time Compute Production Checklist

Before deploying autonomous reasoning pipelines, verify each architectural invariant:

- [ ] **Hard Token Ceilings**: Are all extended thinking and search loops bounded by hard upper token ceilings (`budget_tokens` or `max_tokens`) to prevent unbounded cost loops?
- [ ] **Deterministic Verifier First**: Does the search engine run syntax, AST parsing, and linters *before* invoking expensive LLM-as-a-Judge or PRM verifiers?
- [ ] **Isolated Speculative Staging**: Are candidate patches and file mutations staged in isolated Git worktrees or temporary directories instead of the user's primary working directory?
- [ ] **Reversible Backtracking**: Can the agent cleanly revert to the previous verified state when tests fail, without leaving phantom artifacts or dirty Git states?
- [ ] **No Self-Grading Sycophancy**: Does the system use an adversarial Critic agent or deterministic test runner rather than asking the author model *"Are you sure this is correct?"*?
- [ ] **Early-Stop Loop Detection**: Is there an automated circuit breaker detecting repeating $N$-grams or oscillating ping-pong edits in the reasoning scratchpad?
- [ ] **Process Supervision over Outcome Guessing**: Are multi-step reasoning tasks scored at intermediate step boundaries rather than solely on the final answer?
- [ ] **Separation of Concerns**: Are ephemeral scratchpad reasoning tokens stripped from long-term context memory to prevent context window saturation?
