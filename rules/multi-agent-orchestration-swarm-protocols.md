---
description: Multi-agent systems, swarm topologies, hierarchical supervisor-worker architectures, dynamic handoff protocols, state reducers, fan-in fan-out map-reduce, token budget containment, infinite loop circuit breakers, and human-in-the-loop consensus
globs: **/*{swarm,orchestrat,multi_agent,supervisor,worker,handoff,graph,reducer,topology,subagent}*.*,**/agents/**,**/workflows/**,**/orchestration/**,**/swarms/**
alwaysApply: false
---

# Agentic Multi-Agent Orchestration, Swarm Topologies & Dynamic Handoff Protocols

> Add these rules to your project when architecting, deploying, or auditing multi-agent systems, collaborative AI swarms, hierarchical supervisor-worker graphs, or subagent tool-calling pipelines (Claude Code subagents, OpenAI Swarm / Agent SDK, LangGraph StateGraph, AutoGen 0.4, CrewAI, PydanticAI).

---

## 1. Architectural Taxonomy: Choosing the Optimal Multi-Agent Topology

Multi-agent architectures fail in production when engineers deploy unbounded peer-to-peer swarms for simple tasks or attempt to solve complex multi-domain refactorings with a single monolithic ReAct loop. Match the architectural topology to the task's complexity, token budget, and determinism requirements.

```
1. Hierarchical Supervisor-Worker         2. Peer-to-Peer Dynamic Swarm
┌───────────────────────────────┐        ┌───────────────────────────────┐
│     Supervisor / Router       │        │  Triage / Coordinator Agent   │
│  (Decomposes, Plans, Routes)  │        └───────┬───────────────▲───────┘
└───┬───────────────┬───────┬───┘                │ transfer_to   │ transfer_back
    │               │       │                    ▼               │
    ▼               ▼       ▼            ┌───────────────┐ ┌─────┴─────────┐
┌───────┐       ┌───────┐ ┌───────┐      │ Billing Agent │ │ Support Agent │
│WorkerA│       │WorkerB│ │WorkerC│      └───────────────┘ └───────────────┘
└───┬───┘       └───┬───┘ └───┬───┘       (Stateless handoffs via typed tools)
    │               │       │
    └───────┬───────┴───────┘
            ▼
┌───────────────────────────────┐
│     Aggregator / Reducer      │
│  (Synthesizes & Validates)    │
└───────────────────────────────┘

3. Parallel Fan-In / Fan-Out (Map-Reduce)  4. Evaluator-Optimizer (Dual-Agent)
┌───────────────────────────────┐        ┌───────────────────────────────┐
│       Task Partitioning       │        │        Generator Agent        │
└───┬───────────────┬───────┬───┘        │     (Drafts implementation)   │
    │ chunk_1       │chunk_2│ chunk_3    └───────────────┬───────────────┘
    ▼               ▼       ▼                            │ Proposed Patch
┌───────┐       ┌───────┐ ┌───────┐                      ▼
│Worker1│       │Worker2│ │Worker3│              ┌───────────────┐
└───┬───┘       └───┬───┘ └───┬───┘              │  Critic Agent │
    │               │       │                    │(Verifies Tests│
    └───────┬───────┴───────┘                    │ & Security)   │
            ▼                                    └───────┬───────┘
┌───────────────────────────────┐                        │ Fails with
│  Consensus / Merged Reducer   │                        │ Counter-Example
└───────────────────────────────┘                        └───────▶ Loops back
```

### Topology Decision Matrix

| Dimension | Monolithic ReAct | Supervisor-Worker | Peer-to-Peer Swarm | Evaluator-Optimizer | Map-Reduce Fan-Out |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Best For** | Short, sequential CLI tasks | Multi-step coding refactorings | Customer support, triage | Code generation, security auditing | Bulk analysis, distributed audit |
| **State Coordination** | Single linear message list | Centralized blackboard / graph | Direct point-to-point transfer | Iterative feedback loop | Independent shards $\to$ merge |
| **Context Leak Risk** | High (grows indefinitely) | Low (isolated worker context) | Medium (state passed on handoff)| Low (structured diffs only) | Very Low (zero cross-talk) |
| **Failure Mode** | Hallucination spiral | Supervisor bottleneck | Infinite ping-pong bounce | Infinite perfectionist loop | Conflicting merge diffs |
| **Token Cost Profile** | $O(N)$ linear | $O(N \cdot K)$ controlled | $O(N)$ with step ceiling | $O(N \cdot M)$ turns bounded | $O(K \times \text{shard})$ |

---

## 2. Context Boundary Isolation & The Anti-Contamination Invariant

The single greatest operational failure in multi-agent systems is **Context Contamination**. Passing the supervisor's entire 50-turn conversation history to a subagent destroys prompt caching, floods working memory with irrelevant noise, and triggers the "Lost-in-the-Middle" degradation.

- ❌ **The Monolithic Context Bleed Trap**:
  ```ts
  // ❌ ANTI-PATTERN: Dumping full primary context into ephemeral worker
  const subagentResponse = await callSubagent({
    model: 'claude-3-7-sonnet',
    messages: [
      ...mainAgentConversationHistory, // 45,000 tokens of irrelevant conversation!
      { role: 'user', content: 'Run test suite and fix the timeout in auth_test.go' }
    ]
  });
  ```
- ✅ **The Clean-Room Subagent Context Invariant**:
  - Subagents MUST execute in a clean-room context: static system prompt + isolated task specification + minimal typed artifacts.
  - Workers MUST return **compact synthesized deliverables** (e.g. structured JSON, patch diffs, concise test reports), never their internal 30-turn tool trace scratchpads.
  ```ts
  // ✅ PRODUCTION DISCIPLINE: Clean-room context with explicit boundary
  interface SubagentInput {
    taskId: string;
    targetFiles: string[];
    taskInstruction: string;
    relevantTypeDefinitions: string; // Trimmed AST slice, not whole files
  }

  interface SubagentResult {
    status: 'success' | 'failed';
    summary: string;
    patchDiff?: string;
    errorAnalysis?: string;
  }

  export async function executeSubagentWorker(input: SubagentInput): Promise<SubagentResult> {
    const response = await aiClient.generateObject({
      model: 'claude-3-7-sonnet',
      system: `You are an isolated surgical code repair worker.
You are tasked with a scoped modification. Do not deviate from the target files.
Return ONLY the structured patch and execution outcome.`,
      prompt: `<task_envelope>
  <task_id>${input.taskId}</task_id>
  <instruction>${input.taskInstruction}</instruction>
  <target_files>${input.targetFiles.join(', ')}</target_files>
  <type_definitions>
${input.relevantTypeDefinitions}
  </type_definitions>
</task_envelope>`,
      schema: subagentResultSchema,
    });

    return response.object;
  }
  ```

---

## 3. Dynamic Swarm Handoff Protocols & The Typed Transfer Contract

In peer-to-peer swarms (e.g. OpenAI Swarm, Anthropic Agentic Workflows), control transfers dynamically between specialized agents using dedicated transfer tools (e.g. `transfer_to_database_agent`, `transfer_to_frontend_agent`). Unchecked handoffs quickly devolve into unstructured conversational noise.

### The Typed Transfer Envelope
Every agent handoff MUST be governed by a typed transfer contract containing:
1. `target_agent`: Identifier of the destination agent.
2. `transfer_reason`: Clear justification for relinquishing control.
3. `accumulated_context`: A distilled, lossless summary of discoveries so far.
4. `task_contract`: Explicit inputs, constraints, and success criteria.
5. `depth_counter`: Monotonically incrementing turn counter to halt ping-pong loops.

```ts
import { z } from 'zod';

export const TransferContractSchema = z.object({
  targetAgent: z.enum(['triage', 'code_analyzer', 'test_runner', 'git_committer', 'human_escalation']),
  transferReason: z.string().min(10).describe('Specific operational trigger requiring transfer'),
  condensedContext: z.string().max(2000).describe('Distilled facts discovered so far; no tool logs'),
  assignedSubtask: z.string().describe('Clear, single-sentence objective for the target agent'),
  constraints: z.array(z.string()).describe('Invariants the target agent must not violate'),
  transferDepth: z.number().int().min(0).max(8).describe('Monotonic handoff counter'),
});

export type TransferContract = z.infer<typeof TransferContractSchema>;
```

### Implementing Stateless Handoffs in Tool Calling
Agents must not maintain hidden shared global state. Transfer functions return the target agent instance and a cleanly partitioned message array:

```python
from typing import Dict, Any, Tuple
from pydantic import BaseModel, Field

class Agent:
    def __init__(self, name: str, system_prompt: str, tools: list):
        self.name = name
        self.system_prompt = system_prompt
        self.tools = tools

class TransferToDatabaseExpert(BaseModel):
    """Call this tool when the task requires SQL schema migrations, index analysis, or query optimization."""
    reason: str = Field(..., description="Why the database expert is required")
    condensed_problem: str = Field(..., description="Clean summary of the SQL problem")
    table_names: list[str] = Field(..., description="Target database tables")

def transfer_to_database_agent(params: TransferToDatabaseExpert, context: Dict[str, Any]) -> Tuple[Agent, str]:
    # Validate transfer depth to prevent infinite ping-pong loops
    current_depth = context.get("transfer_depth", 0)
    if current_depth >= 6:
        raise RuntimeError("Transfer ceiling exceeded: max 6 handoffs permitted before human escalation.")

    context["transfer_depth"] = current_depth + 1
    context["active_problem"] = params.condensed_problem

    # Return target agent and handoff notification
    return database_agent, f"Control transferred to {database_agent.name}. Problem: {params.condensed_problem}"
```

---

## 4. State Graphs, Pregel Execution Semantics & Channel Reducers

When deploying graph-based multi-agent systems (e.g. LangGraph, Pregel state engines), state coordination is managed via explicit graph channels and state reducer functions.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Graph State Channels                           │
├──────────────────────┬──────────────────────────┬───────────────────────┤
│ Channel              │ Reducer Function         │ Semantics             │
├──────────────────────┼──────────────────────────┼───────────────────────┤
│ `messages`           │ `add_messages` (Append)  │ Preserves turn history│
│ `active_artifacts`   │ `merge_dict` (Key-Union) │ Parallel worker write │
│ `execution_errors`   │ `accumulate_list`        │ Error logging         │
│ `iteration_count`    │ `operator.add` (+1)      │ Loop sentinel         │
│ `human_decision`     │ `overwrite` (Last-Write) │ Interruption state    │
└──────────────────────┴──────────────────────────┴───────────────────────┘
```

### Channel Reducer Rules
- ❌ **TOTAL BAN ON IN-PLACE MUTATION**:
  - Never mutate graph state variables in-place within a node function (`state.items.append(x)`). Graph runtimes require pure state returns to support time-travel debugging, rollback checkpoints, and speculative branching.
  - Always return a new delta dictionary from each node: `return {"messages": [new_message]}`.
- **Handling Parallel Branch Merging (Fan-In)**:
  - When two worker nodes execute concurrently and return state updates to the same channel, the channel's reducer MUST be commutative and associative.
  - If two workers modify the same file key, an uncoordinated merge results in silent overwrite. Enforce explicit conflict-detection reducers:

```ts
export type ArtifactMap = Record<string, { content: string; author: string; version: number }>;

export function reconcileArtifactChannel(
  current: ArtifactMap,
  update: ArtifactMap
): ArtifactMap {
  const merged = { ...current };

  for (const [filePath, incoming] of Object.entries(update)) {
    if (merged[filePath] && merged[filePath].version !== incoming.version - 1) {
      throw new Error(
        `State merge conflict detected on ${filePath}: current version ${merged[filePath].version}, ` +
        `incoming version ${incoming.version} authored by ${incoming.author}. Orchestrator must intervene.`
      );
    }
    merged[filePath] = incoming;
  }

  return merged;
}
```

---

## 5. Deadlock Sentinels, Ping-Pong Circuit Breakers & Cycle Detection

Autonomous multi-agent swarms without termination sentinels inevitably encounter **The Infinite Ping-Pong Trap**: Agent A discovers a missing dependency and hands off to Agent B; Agent B believes the dependency requires configuration from Agent A and hands control back. This loop can drain hundreds of dollars of API credits in minutes.

```
┌─────────────────┐   "Need config from A"   ┌─────────────────┐
│     Agent A     ├─────────────────────────▶│     Agent B     │
│                 │◀─────────────────────────┤                 │
└────────┬────────┘   "Need install from B"  └────────┬────────┘
         │                                            │
         │      💥 Unbounded Reciprocal Bouncing      │
         └──────────────────┬─────────────────────────┘
                            │
                            ▼
          ┌──────────────────────────────────┐
          │     The Deadlock Sentinel FSM     │
          │  1. Monotonic Depth Ceiling (≤8) │
          │  2. Direct Cycle Graph Detection │
          │  3. Hard Dollar Budget ($1.50)   │
          │  4. Forced Human Escalation Gate │
          └──────────────────────────────────┘
```

### The 4 Multi-Agent Circuit Breakers
1. **Monotonic Handoff Depth Ceiling ($N \le 8$)**:
   - Every transfer decrements or increments an immutable counter. When `depth > 8`, immediately abort the swarm and escalate to the user.
2. **Directed Graph Cycle Detection**:
   - Maintain an execution path history: `['triage', 'coder', 'tester', 'coder', 'tester']`.
   - If a directed 2-cycle (`A -> B -> A -> B`) or 3-cycle repeats twice, trip the circuit breaker immediately.
3. **Hard Token & Dollar Budget Caps**:
   - Impose an absolute token ceiling per workflow ($B_{\text{tokens}} \le 120,000$) and cost ceiling ($B_{\text{usd}} \le \$1.50$). If cumulative consumption hits the threshold, gracefully finalize or halt with an explanatory summary.
4. **Wall-Clock Execution Timeout**:
   - Multi-agent orchestration workflows must be wrapped in a root `AbortSignal` with a strict wall-clock timeout (default: 120 seconds).

```ts
export class SwarmCycleSentinel {
  private history: string[] = [];
  private maxDepth = 8;

  public recordStep(agentName: string): void {
    this.history.push(agentName);

    if (this.history.length > this.maxDepth) {
      throw new Error(
        `Swarm Execution Terminated: Exceeded max handoff depth (${this.maxDepth}). Trajectory: ${this.history.join(' -> ')}`
      );
    }

    // Detect immediate 2-cycle ping-pong: [A, B, A, B]
    const len = this.history.length;
    if (
      len >= 4 &&
      this.history[len - 1] === this.history[len - 3] &&
      this.history[len - 2] === this.history[len - 4]
    ) {
      throw new Error(
        `Swarm Deadlock Detected: Oscillating ping-pong loop between '${this.history[len - 1]}' and '${this.history[len - 2]}'. Halting.`
      );
    }
  }
}
```

---

## 6. Hierarchical Task Decomposition & Bounded Map-Reduce Fan-Out

When a complex objective is split across multiple parallel workers (e.g. migrating 15 API routes, auditing 20 repository modules):

- **The Planner Decomposition Invariant**:
  - The supervisor MUST decompose the goal into an acyclic Directed Acyclic Graph (DAG) of independent subtasks before initiating worker execution.
  - Workers MUST NOT spawn their own unbounded child workers. Subagent recursion depth MUST be capped at 1 ($Supervisor \to Worker$, never $Supervisor \to Worker \to Subworker \to \dots$).
- **Bounded Concurrency Throttling**:
  - ❌ **The 20-Worker Burst Anti-Pattern**: Spawning 20 parallel LLM calls simultaneously triggers provider 429 rate limit errors (TPM/RPM exhaustion) and saturates local network sockets.
  - ✅ **Production Invariant**: Enforce a strict concurrency pool (max 3–5 simultaneous worker agents) using semaphores:

```ts
import pLimit from 'p-limit';

export async function executeParallelWorkerFanOut<T, R>(
  tasks: T[],
  workerFn: (task: T) => Promise<R>,
  concurrencyLimit = 3
): Promise<R[]> {
  const limit = pLimit(concurrencyLimit);

  const workerPromises = tasks.map((task, index) =>
    limit(async () => {
      try {
        return await workerFn(task);
      } catch (err) {
        throw new Error(`Worker execution failed on task index ${index}: ${err instanceof Error ? err.message : String(err)}`);
      }
    })
  );

  return Promise.all(workerPromises);
}
```

- **The Fan-In Aggregator Node**:
  - Once all workers complete, control passes to an Aggregator agent.
  - The Aggregator validates individual worker diffs for semantic consistency, detects conflicting edits, compiles a unified changelog, and runs root verification tests.

---

## 7. Human-in-the-Loop (HITL) Interruption & Approval Gates

Multi-agent swarms operating autonomously must be intercepted before performing irreversible actions. Autonomous agents must never have unilateral authority to execute Tier 3 destructive mutations.

### The 3 Mutation Tiers

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Action Risk Classification                      │
├────────┬─────────────────────────────┬─────────────────────────────────┤
│ Tier 1 │ Autonomous Execution        │ Read files, run linters, query  │
│        │ (Zero Permission Required)  │ databases (read-only SELECT),   │
│        │                             │ run non-destructive tests       │
├────────┼─────────────────────────────┼─────────────────────────────────┤
│ Tier 2 │ Logged / Sandboxed Mutation │ Create local temp files, branch │
│        │ (Autonomous with Rollback)  │ git checkouts, edit workspace   │
├────────┼─────────────────────────────┼─────────────────────────────────┤
│ Tier 3 │ Mandatory HITL Step-Up Gate │ Schema migrations (DROP/ALTER), │
│        │ (Requires Explicit User Yes)│ git push --force, cloud deploy, │
│        │                             │ issuing payments, credential ops│
└────────┴─────────────────────────────┴─────────────────────────────────┘
```

### Implementing Graph Interrupts
In graph-based systems (e.g. LangGraph), inject explicit interruption checkpoints before high-risk nodes:

```python
from langgraph.graph import StateGraph, END
from langgraph.checkpoint.memory import MemorySaver

# Define graph with an explicit human approval interrupt
workflow = StateGraph(SwarmState)
workflow.add_node("planner", plan_migration)
workflow.add_node("code_generator", generate_patches)
workflow.add_node("human_review_gate", prompt_human_approval)
workflow.add_node("execute_deployment", run_production_deploy)

workflow.add_edge("planner", "code_generator")
workflow.add_edge("code_generator", "human_review_gate")
workflow.add_conditional_edges(
    "human_review_gate",
    lambda state: "execute_deployment" if state.get("human_approved") else END
)

# Interrupt graph execution before the dangerous deployment node
app = workflow.compile(
    checkpointer=MemorySaver(),
    interrupt_before=["execute_deployment"]
)
```

---

## 8. Multi-Agent Consensus, Quorum Voting & Evaluator-Optimizer Loops

For mission-critical tasks (security audits, financial ledger reconciliation, compiler verification), single-agent outputs are vulnerable to confirmation bias. Use the **Evaluator-Optimizer Dual-Agent Pattern**.

```
┌────────────────────────────────────────────────────────────────────────┐
│                    The Evaluator-Optimizer Loop                        │
│                                                                        │
│   ┌────────────────────────┐              Proposed Solution            │
│   │    Generator Agent     ├──────────────────────────────────────┐    │
│   │ (Drafts Implementation)│                                      │    │
│   └───────────▲────────────┘                                      ▼    │
│               │                                       ┌────────────────┐
│               │ Concrete Counter-Example & Rubric Fails│ Evaluator /   │
│               └───────────────────────────────────────┤ Critic Agent   │
│                                                       │(Zero Bias Check│
│                                                       └───────┬────────┘
│                                                               │ Passes All
│                                                               ▼ Verification
│                                                       ┌────────────────┐
│                                                       │ Promoted Patch │
└───────────────────────────────────────────────────────┴────────────────┘
```

- **Separation of Concerns**:
  - The Generator agent writes code and explanations.
  - The Evaluator / Critic agent is stripped of the generator's internal thoughts and receives ONLY the patch diff, problem specification, and machine test results.
  - The Critic MUST NOT produce vague praise. If rejecting, the Critic MUST supply a concrete, failing reproduction input or invariant violation.
- **Max Iteration Bound ($K \le 3$)**:
  - Bound the generator-evaluator loop to at most 3 rounds. If the Generator cannot satisfy the Critic within 3 turns, halt and escalate to a human engineer with the unresolved counter-example.

---

## 9. Fault Tolerance, Worker Failover & Graceful Degradation

Autonomous multi-agent swarms must survive individual node crashes, LLM provider outages, and tool timeouts without losing accumulated progress.

- **Idempotent Retry with Exponential Jitter**:
  - Network-bound worker tasks must be wrapped in retries with exponential backoff and randomized jitter:
    $$t_{\text{wait}} = \min(t_{\text{max}}, t_{\text{base}} \times 2^{\text{attempt}}) \pm \text{random\_jitter}$$
- **Specialist $\to$ Generalist Fallback**:
  - If a specialized agent (e.g. an AST tree-sitter extraction agent) crashes or repeatedly emits invalid JSON schemas, fall back to a robust generalist agent with a simpler unstructured prompt.
- **Partial Batch Success (Best-Effort Aggregation)**:
  - In Map-Reduce operations over $M$ items, if $M-1$ succeed and 1 worker times out, do NOT fail the entire batch. Return the $M-1$ results stamped with an explicit `partial_failure_warnings` notification.

---

## 10. Production Checklist: Multi-Agent Swarm Deployment

Before deploying multi-agent workflows into production CLI tools, IDE extensions, or backend automation pipelines:

- [ ] **Context Boundary**: Are subagents spawned with clean-room context, eliminating monolithic conversation history bleed?
- [ ] **Result Compaction**: Do worker agents return concise structured summaries and patch diffs rather than full tool traces?
- [ ] **Transfer Schemas**: Are all handoffs governed by typed contracts (`targetAgent`, `condensedContext`, `assignedSubtask`, `transferDepth`)?
- [ ] **Circuit Breakers**: Is there a hard ceiling on transfer depth ($N \le 8$) and an active cycle detector halting ping-pong thrashing?
- [ ] **Resource Budgets**: Are execution time ($\le 120\text{s}$), token consumption ($\le 120\text{k}$), and dollar costs ($\le \$1.50$) capped per invocation?
- [ ] **Bounded Concurrency**: Is worker fan-out bounded to max 3–5 simultaneous threads to prevent 429 rate limit exhaustion?
- [ ] **Conflict Resolution**: Do state reducers prevent concurrent workers from silently overwriting each other's file modifications?
- [ ] **HITL Gating**: Are Tier 3 destructive operations (DROP table, force push, payment execution) strictly blocked behind human confirmation gates?
- [ ] **Evaluator Loop Ceiling**: Is the Generator-Critic loop bounded to $\le 3$ rounds before human escalation?
- [ ] **Stateless Resumption**: Is the state graph backed by persistent checkpoint storage allowing resume after failure?
