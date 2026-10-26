---
description: Agentic task planning, dynamic Plan-and-Solve workflows, Directed Acyclic Graph (DAG) task decomposition, topological execution, dynamic replanning FSM, anti-thrashing circuit breakers, state durability checkpointing, and clean-room worker context isolation
globs: **/*{planner,planning,workflow,orchestrator,dag,task_graph,pipeline,scheduler}*.*,**/workflows/*.{ts,js,py,go},**/agents/*.{ts,js,py,go},**/{CLAUDE,AGENTS}.md,**/.cursor/rules/**,**/.agents/**
alwaysApply: false
---

# Agentic Task Decomposition, Dynamic Plan-and-Solve & DAG Workflow Orchestration

> Add these rules to your project when building or operating multi-step autonomous agents, complex SWE-bench software engineering harnesses, long-horizon coding workflows, or enterprise agent pipelines (Claude Code, Cursor Composer, Windsurf Cascade, Roo Code, LangGraph, Temporal, CrewAI Flows, OpenAI Agents SDK).

---

## 1. Architectural Taxonomy: ReAct Horizon Collapse vs Hierarchical DAG Orchestration

The fundamental failure mode of frontier autonomous agents in multi-step missions is **The ReAct Horizon Collapse**:
When operating in a purely reactive loop (`while true: Thought ➔ Action ➔ Observation`), the agent:
1. **Suffers from Plan Drift**: After 5–10 iterative tool turns, earlier strategic goals dissolve from the context midsection ("Lost in the Middle"). The agent begins pursuing irrelevant micro-optimizations.
2. **Falls into Action Thrashing**: Without a deterministic dependency graph, the agent toggles back and forth between two opposing actions (e.g. modifying File A, encountering an error in File B, modifying File B, breaking File A again).
3. **Prematurely Declares Victory**: After fixing a single compilation error or running one test, the agent hallucinates that the overarching user goal is 100% complete, skipping downstream migrations, lint checks, or integration verifications.
4. **Lacks Execution Isolation**: All tool calls share a single monolithic conversation history, polluting the context with thousands of lines of intermediate compiler output and causing quadratic token cost spikes.

Production-grade autonomous systems decouple **Strategic Planning (The Directed Acyclic Graph)** from **Tactical Execution (Isolated Worker Tasks)**:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   USER HIGH-LEVEL MISSION OBJECTIVE                              │
│         ("Refactor Payment Service from REST to gRPC, Add Idempotency & Pass Integration Tests") │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 1: Strategic Task Decomposition & DAG Synthesis (Plan-and-Solve Planner)                   │
│    • Deconstruct mission into discrete, typed, idempotent subtasks.                              │
│    • Declare strict topological dependencies (Parents ➔ Children).                               │
│    • Validate graph acyclicity (Kahn's Algorithm / Cycle Elimination).                            │
│    • Annotate each node with strict input/output schemas & tool allowlists.                     │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Validated Acyclic Graph
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 2: Topological Task Scheduler & Dynamic State Machine (FSM)                                │
│    • State Tracking: [PENDING] ➔ [READY] ➔ [RUNNING] ➔ [SUCCEEDED] / [FAILED] / [BLOCKED]        │
│    • Concurrency Governor: Bound parallel execution (max 3–5 concurrent worker tasks).           │
│    • Clean-Room Isolation: Workers receive ONLY their task schema + upstream dependency outputs. │
└─────────────────────────┬────────────────────────────────────────────┬───────────────────────────┘
                          │                                            │
                          ▼                                            ▼
           ┌─────────────────────────────┐              ┌─────────────────────────────┐
           │ Node 1: Proto Definition    │              │ Node 2: DB Schema Migration │
           │ Status: [SUCCEEDED]         │              │ Status: [SUCCEEDED]         │
           └──────────────┬──────────────┘              └──────────────┬──────────────┘
                          │                                            │
                          └──────────────────────┬─────────────────────┘
                                                 │ Both Upstream Succeeded
                                                 ▼
                                  ┌─────────────────────────────┐
                                  │ Node 3: Server Implementation│
                                  │ Status: [RUNNING] (Worker)  │
                                  └──────────────┬──────────────┘
                                                 │
                   ┌─────────────────────────────┴─────────────────────────────┐
                   │ Node Execution Fails!                                     │
                   ▼                                                           ▼
┌──────────────────────────────────────────────┐              ┌────────────────────────────────────┐
│ Phase 3: Dynamic Replanning FSM              │              │ Phase 4: Anti-Thrashing Guardrail  │
│    • Localize blast radius to child nodes.   │              │    • Sliding window state hash.    │
│    • Freeze downstream [BLOCKED] nodes.       │              │    • Detect 3-attempt oscillation. │
│    • Synthesize compensating recovery node.   │              │    • Hard Circuit Breaker trip.    │
│    • Re-validate graph & resume execution.   │              │    • Escalate to HITL / abort.     │
└──────────────────────────────────────────────┘              └────────────────────────────────────┘
```

---

## 2. The Directed Acyclic Graph (DAG) Task Representation Schema

Every mission MUST be compiled into an explicit, serializable task graph before any mutating code modifications or file writes are permitted.

### The Strict Task Node Schema
```typescript
export type TaskNodeStatus =
  | 'PENDING'    // Waiting for upstream dependencies to finish
  | 'READY'      // All dependencies satisfied; eligible for dispatch
  | 'RUNNING'    // Currently executing inside an isolated worker runtime
  | 'SUCCEEDED'  // Executed and output validated against Zod schema
  | 'FAILED'     // Execution threw error or violated verification invariant
  | 'BLOCKED'    // An upstream dependency failed; execution halted
  | 'SKIPPED';   // Compensating logic determined step is redundant

export interface TaskNode<TInput = unknown, TOutput = unknown> {
  readonly id: string;                        // Unique deterministic slug (e.g. "task_01_proto_gen")
  readonly title: string;                     // Short human-readable summary
  readonly description: string;               // Exhaustive task brief with explicit acceptance criteria
  readonly dependencies: readonly string[];   // Array of upstream node IDs that MUST succeed first
  readonly status: TaskNodeStatus;
  readonly toolAllowlist: readonly string[];  // Least-privilege tool filter for this step
  readonly requiresHitlApproval: boolean;     // True if node performs destructive / egress side-effects
  readonly input?: TInput;                    // Typed input parameters (synthesized from upstream outputs)
  readonly output?: TOutput;                  // Strictly validated result data
  readonly error?: {
    readonly code: string;
    readonly message: string;
    readonly retryCount: number;
    readonly stack?: string;
  };
  readonly executionMetrics?: {
    readonly startedAt: number;
    readonly finishedAt?: number;
    readonly tokenUsage: number;
  };
}
```

### Invariants for Task Graph Construction
1. **Strict Acyclicity Invariant**:
   - The graph MUST be validated with Kahn's Algorithm or Tarjan's Strongly Connected Components before execution starts.
   - Any cycle ($A \to B \to A$) is an invalid architectural plan and MUST be rejected immediately prior to running any worker agent.
2. **Explicit Dependency Lineage**:
   - ❌ **NEVER allow implicit dependencies**. If Node C uses code generated in Node A, Node A MUST be declared in Node C's `dependencies` array.
   - Parallel tasks MUST have disjoint write sets (e.g., they must never modify the same source file concurrently).
3. **Typed Output Contract Boundary**:
   - The output of an upstream node MUST NOT be dumped as free-form conversation prose. It MUST conform to a typed schema (e.g. `{ generatedFiles: string[], exports: string[] }`) so downstream nodes can consume it deterministically.

---

## 3. Dynamic Replanning Finite-State Machine (FSM)

Static plans generated at the beginning of a mission will fail when confronted with real-world edge cases (e.g. a missing native C library, an unexpected database constraint, or a failing edge-case test). 

When a task node fails, the orchestrator MUST NOT blindly retry the entire mission or hallucinate random file edits. It MUST trigger the **Dynamic Replanning Protocol**:

```
                       ┌─────────────────────────┐
                       │   Worker Node Fails     │
                       └────────────┬────────────┘
                                    │
                                    ▼
                       ┌─────────────────────────┐
                       │ Classify Error Taxonomy │
                       └────────────┬────────────┘
                                    │
         ┌──────────────────────────┼──────────────────────────┐
         │ Transient                │ Structural               │ Unrecoverable
         ▼                          ▼                          ▼
┌─────────────────┐        ┌─────────────────┐        ┌─────────────────┐
│ Immediate Retry │        │ Dynamic Replan  │        │ Emergency Halt  │
│ (Max 2 with     │        │ Splicing Sub-DAG│        │ & HITL Escalation│
│  Exp. Backoff)  │        └────────┬────────┘        └─────────────────┘
└─────────────────┘                 │
                                    ▼
                       ┌─────────────────────────┐
                       │ Invalidate Downstream   │
                       │ Dependent Sub-Tree      │
                       └────────────┬────────────┘
                                    │
                                    ▼
                       ┌─────────────────────────┐
                       │ Synthesize Recovery     │
                       │ & Spliced Fix Nodes     │
                       └────────────┬────────────┘
                                    │
                                    ▼
                       ┌─────────────────────────┐
                       │ Verify DAG Acyclicity   │
                       └────────────┬────────────┘
                                    │
                                    ▼
                       ┌─────────────────────────┐
                       │ Resume Graph Execution  │
                       └─────────────────────────┘
```

### The 4 Rules of Dynamic Graph Mutation
1. **Downstream Sub-Tree Invalidation**:
   - When Node $K$ fails, the scheduler traverses all nodes that transitively depend on $K$ ($K \to D_1 \to D_2$) and marks them as `BLOCKED`. Unrelated parallel subtrees remain unaffected.
2. **Surgical Graph Splicing**:
   - The Planner LLM is invoked with an isolated payload containing:
     - The original node objective and acceptance criteria.
     - The exact error output / stack trace (truncated to the relevant diagnostic slice).
     - The failed hypothesis.
   - The Planner synthesizes a compensating sub-DAG (e.g., Node $K_{\text{fix1}}$: "Install libssl-dev", Node $K_{\text{fix2}}$: "Re-run build") and splices them into the graph ahead of the failed node.
3. **Max Replanning Budget (Depth $\le 2$)**:
   - An individual node or subtree may undergo dynamic replanning at most **2 times**. If the compensating nodes also fail, the task is marked `UNRECOVERABLE`, execution halts, and the agent requests human intervention.
4. **Clean Git State Preservation on Replan**:
   - Before applying a compensating subtask, the agent inspects `git status`. Any unverified, half-baked edits from the failed attempt MUST be cleanly reverted (`git checkout -- <files>`) to prevent state pollution.

---

## 4. Anti-Thrashing, Loop Detection & Circuit Breaker Guardrails

Autonomous agents are prone to **Action Thrashing**: oscillating back and forth between two invalid states without converging on a solution.

### The State Transition N-Gram Detector
Track an execution action history vector for every agent turn:
$$\text{Action Signature} = \text{SHA256}(\text{ToolName} \mathbin{\Vert} \text{TargetFile} \mathbin{\Vert} \text{NormalizedArgs})$$

```typescript
export class AntiThrashingMonitor {
  private readonly windowSize = 6;
  private readonly history: string[] = [];
  private readonly transitionCounts = new Map<string, number>();

  public recordAction(tool: string, target: string, args: Record<string, unknown>): void {
    const signature = `${tool}:${target}:${JSON.stringify(args, Object.keys(args).sort())}`;
    this.history.push(signature);

    if (this.history.length > this.windowSize) {
      this.history.shift();
    }

    this.checkOscillation();
  }

  private checkOscillation(): void {
    if (this.history.length < 4) return;

    // Detect A -> B -> A -> B flip-flop
    const [a1, b1, a2, b2] = this.history.slice(-4);
    if (a1 === a2 && b1 === b2 && a1 !== b1) {
      throw new CircuitBreakerError(
        `Action Thrashing Detected: Agent is oscillating between two opposing actions.\nAction A: ${a1}\nAction B: ${b1}`
      );
    }

    // Detect 3 consecutive identical actions on same file failing
    const lastThree = this.history.slice(-3);
    if (lastThree.every((sig) => sig === lastThree[0])) {
      throw new CircuitBreakerError(
        `Repetitive Loop Detected: Agent executed identical action 3 consecutive times: ${lastThree[0]}`
      );
    }
  }
}
```

### The 3 Circuit Breakers
| Breaker Type | Trigger Condition | Automated Action |
| :--- | :--- | :--- |
| **Oscillation Breaker** | A-B-A-B action alternation within a 6-turn sliding window | Freeze execution, revert uncommitted changes, force planner to formulate alternative hypothesis |
| **Max Turn Exhaustion** | Worker node exceeds 10 tool calls without completing acceptance criteria | Abort worker, mark node as `FAILED`, capture execution log for replanner |
| **Context Threshold Breaker** | Worker prompt exceeds 75% of max context window (e.g. >150k tokens) | Force context pruning / compaction checkpoint or split task into smaller sub-units |

---

## 5. Concurrency, Barrier Synchronization & Clean-Room Context Isolation

Executing all tasks serially is wasteful. However, naive unconstrained parallelism causes file-system race conditions, port collisions, and git merge conflicts.

```
                  ┌────────────────────────────────────────┐
                  │          DAG Execution Barrier         │
                  └──────────────────┬─────────────────────┘
                                     │
           ┌─────────────────────────┼─────────────────────────┐
           ▼                         ▼                         ▼
┌─────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
│ Subtask A (Worker 1)│   │ Subtask B (Worker 2)│   │ Subtask C (Worker 3)│
│ Context: Clean-Room │   │ Context: Clean-Room │   │ Context: Clean-Room │
│ Token Cost: 4k      │   │ Token Cost: 4k      │   │ Token Cost: 4k      │
└──────────┬──────────┘   └──────────┬──────────┘   └──────────┬──────────┘
           │                         │                         │
           └─────────────────────────┼─────────────────────────┘
                                     │ Barrier Join (All Must Pass)
                                     ▼
                  ┌────────────────────────────────────────┐
                  │ Subtask D: Integration & Verification  │
                  │ Context: Synthesized Outputs of A, B, C│
                  └────────────────────────────────────────┘
```

### Clean-Room Worker Context Isolation Invariant
- ❌ **NEVER inherit the parent agent's entire multi-turn conversation into child workers**. Doing so defeats context caching and re-introduces attention dissipation.
- ✅ **The Clean-Room Context Envelope**:
  A child worker task receives strictly:
  1. System prompt with core engineering discipline invariants (from `CLAUDE.md`).
  2. The specific task title, acceptance criteria, and tool allowlist.
  3. Structured outputs from direct parent nodes.
  4. Local repo map / file interfaces relevant to the assigned task.
- **Barrier Join Synchronization**:
  When multiple parallel tasks (e.g., writing client SDK and writing server mocks) feed into an integration test task, the downstream node MUST wait for all parent nodes to achieve `SUCCEEDED` status. If any upstream parallel task fails, the downstream task is immediately marked `BLOCKED`.

---

## 6. State Durability, Session Checkpointing & Resilient Pause/Resume

In production agent platforms, processes will be killed by container restarts, spot instance terminations, or human approval delays. A mission must be fully resumable from persistent state.

```json
{
  "missionId": "mission_20261027_payment_migration",
  "rootObjective": "Migrate payment client to gRPC with idempotency",
  "createdAt": "2026-10-27T08:00:00.000Z",
  "updatedAt": "2026-10-27T08:14:22.000Z",
  "status": "IN_PROGRESS",
  "activeNodeId": "task_03_server_grpc",
  "nodes": {
    "task_01_proto": {
      "status": "SUCCEEDED",
      "dependencies": [],
      "output": {
        "protoFiles": ["proto/payment/v1/service.proto"],
        "generatedTypes": ["PaymentServiceClient", "ProcessPaymentRequest"]
      }
    },
    "task_02_db_migration": {
      "status": "SUCCEEDED",
      "dependencies": [],
      "output": {
        "migrationVersion": "20261027001",
        "appliedTables": ["idempotency_keys"]
      }
    },
    "task_03_server_grpc": {
      "status": "RUNNING",
      "dependencies": ["task_01_proto", "task_02_db_migration"],
      "retryCount": 0
    }
  }
}
```

### State Checkpointing Invariants
1. **Atomic State Flushes**:
   - After every node state transition (`READY` ➔ `RUNNING` ➔ `SUCCEEDED`), serialize the updated DAG state atomically to disk (`.agents/checkpoints/<mission_id>.json` or SQLite database).
2. **Deterministic Resume Protocol**:
   - On process restart, the scheduler loads the checkpoint, identifies all nodes with `SUCCEEDED` status, skips re-executing them, and immediately resumes at the `READY` or interrupted `RUNNING` nodes.
3. **HITL Interruption Point**:
   - Any node with `requiresHitlApproval: true` transitions the graph into `PAUSED_FOR_HUMAN`. The checkpoint is saved, and the process safely exits or suspends until the user emits an explicit `dws/approve` or CLI confirmation.

---

## 7. Production Anti-Patterns & Catastrophic Failure Modes

### Anti-Pattern 1: Monolithic Free-Text Plans
- ❌ **The "Vague Thoughts" Trap**: The agent writes a markdown list in conversation memory ("1. Inspect files, 2. Update code, 3. Run tests") and immediately starts coding without structured state tracking. By turn 6, the list is forgotten.
- ✅ **Production Invariant**: Plans MUST exist as typed data structures with programmatic state machines, tracked independently of conversational memory.

### Anti-Pattern 2: Premature Task Completion
- ❌ **The "First Green" Fallacy**: The agent runs a quick command that succeeds and concludes: "Everything is implemented successfully!" meanwhile 4 downstream acceptance criteria were never executed.
- ✅ **Production Invariant**: The orchestrator only marks a mission complete when **every single node in the DAG** has verified `SUCCEEDED` status and the final verification node passes in a hermetic clean environment.

### Anti-Pattern 3: Massive Unbounded Subtask Trees
- ❌ **Runaway Subtask Explosion**: The agent attempts to solve a problem by spawning 20 micro-subtasks, each spawning 5 more, leading to 100+ tasks that exhaust API rate limits and blow through token budgets.
- ✅ **Production Invariant**: Enforce a strict DAG size limit:
  - Max Nodes per Mission: $\le 12$
  - Max Decomposition Depth: $\le 2$
  - Max Concurrent Workers: $\le 4$

### Anti-Pattern 4: Silent Failure Swallowing in Downstream Dependencies
- ❌ **The "Null Output Cascade"**: Node A fails to generate an output schema but returns empty `{}`; Node B receives empty `{}` and silently creates empty files or no-ops, masking the bug until final validation.
- ✅ **Production Invariant**: Enforce strict schema validation on node outputs via Zod / Pydantic. If output validation fails, Node A transitions to `FAILED` immediately and never propagates empty state to Node B.

---

## 8. Reference Implementation: Production-Grade DAG Task Engine

```typescript
import { z } from 'zod';

export interface TaskDefinition<TInput = unknown, TOutput = unknown> {
  id: string;
  title: string;
  dependencies: string[];
  inputSchema: z.ZodSchema<TInput>;
  outputSchema: z.ZodSchema<TOutput>;
  execute: (input: TInput, context: { signal: AbortSignal }) => Promise<TOutput>;
}

export class DagExecutionEngine {
  private readonly tasks = new Map<string, TaskDefinition>();
  private readonly statuses = new Map<string, TaskNodeStatus>();
  private readonly outputs = new Map<string, unknown>();

  public registerTask<I, O>(task: TaskDefinition<I, O>): void {
    if (this.tasks.has(task.id)) {
      throw new Error(`Duplicate task registered: ${task.id}`);
    }
    this.tasks.set(task.id, task as TaskDefinition);
    this.statuses.set(task.id, 'PENDING');
  }

  public validateAcyclicity(): string[] {
    const inDegree = new Map<string, number>();
    const adjacency = new Map<string, string[]>();

    for (const [id, task] of this.tasks) {
      inDegree.set(id, task.dependencies.length);
      for (const dep of task.dependencies) {
        if (!this.tasks.has(dep)) {
          throw new Error(`Task ${id} references unknown dependency: ${dep}`);
        }
        const list = adjacency.get(dep) ?? [];
        list.push(id);
        adjacency.set(dep, list);
      }
    }

    const queue: string[] = [];
    for (const [id, degree] of inDegree) {
      if (degree === 0) queue.push(id);
    }

    const executionOrder: string[] = [];
    while (queue.length > 0) {
      const current = queue.shift()!;
      executionOrder.push(current);

      for (const neighbor of adjacency.get(current) ?? []) {
        const newDegree = (inDegree.get(neighbor) ?? 1) - 1;
        inDegree.set(neighbor, newDegree);
        if (newDegree === 0) {
          queue.push(neighbor);
        }
      }
    }

    if (executionOrder.length !== this.tasks.size) {
      throw new Error('Cyclic dependency detected in task graph! Acyclicity invariant violated.');
    }

    return executionOrder;
  }

  public async executeDag(concurrency = 3): Promise<Map<string, unknown>> {
    this.validateAcyclicity();
    const abortController = new AbortController();

    const isTaskReady = (id: string): boolean => {
      if (this.statuses.get(id) !== 'PENDING') return false;
      const task = this.tasks.get(id)!;
      return task.dependencies.every((dep) => this.statuses.get(dep) === 'SUCCEEDED');
    };

    while (Array.from(this.statuses.values()).some((s) => s === 'PENDING' || s === 'RUNNING')) {
      const readyTasks = Array.from(this.tasks.keys()).filter(isTaskReady);

      if (readyTasks.length === 0 && Array.from(this.statuses.values()).every((s) => s !== 'RUNNING')) {
        const blockedTasks = Array.from(this.tasks.keys()).filter((id) => this.statuses.get(id) === 'PENDING');
        for (const blocked of blockedTasks) {
          this.statuses.set(blocked, 'BLOCKED');
        }
        break;
      }

      const batch = readyTasks.slice(0, concurrency);
      await Promise.all(
        batch.map(async (taskId) => {
          this.statuses.set(taskId, 'RUNNING');
          const task = this.tasks.get(taskId)!;

          try {
            // Aggregate inputs from upstream dependencies
            const dependencyOutputs = Object.fromEntries(
              task.dependencies.map((dep) => [dep, this.outputs.get(dep)])
            );
            const validatedInput = task.inputSchema.parse(dependencyOutputs);

            const result = await task.execute(validatedInput, { signal: abortController.signal });
            const validatedOutput = task.outputSchema.parse(result);

            this.outputs.set(taskId, validatedOutput);
            this.statuses.set(taskId, 'SUCCEEDED');
          } catch (err) {
            this.statuses.set(taskId, 'FAILED');
            abortController.abort();
            throw new Error(`DAG node execution failed: ${taskId} - ${(err as Error).message}`);
          }
        })
      );
    }

    return this.outputs;
  }
}
```

---

## 9. Production Verification Checklist

Before releasing or running autonomous agent workflows with DAG orchestration, audit against this checklist:

- [ ] **Topological Validation**: Is Kahn's algorithm or cycle checking executed before any mutating tool call is dispatched?
- [ ] **Clean-Room Isolation**: Do child workers run with isolated contexts rather than inheriting the full monolithic history?
- [ ] **Typed Schema Contracts**: Are inputs and outputs between graph nodes validated with strict runtime schemas (Zod/Pydantic)?
- [ ] **Downstream Invalidation**: When a node fails, are its transitive children automatically marked `BLOCKED` rather than executing with stale or missing data?
- [ ] **Anti-Thrashing Circuit Breakers**: Is an action signature N-gram monitor active to immediately halt A-B-A-B oscillatory loops?
- [ ] **Max Decomposition Limits**: Are task graph depth ($\le 2$) and node count ($\le 12$) strictly bounded to prevent recursive explosions?
- [ ] **Durable State Persistence**: Are node transitions and intermediate outputs written atomically to disk for resilient pause/resume?
- [ ] **Human-in-the-Loop Gating**: Do destructive operations (database drops, branch force-pushes, production egress) require interactive human approval before transition from `READY` to `RUNNING`?
- [ ] **Git Revert on Failure**: When dynamic replanning is triggered, are unverified dirty file edits cleanly reverted before dispatching the recovery sub-DAG?
