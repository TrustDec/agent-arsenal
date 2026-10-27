---
description: Agentic durable workflows, Saga compensation orchestration, backward/forward recovery state machines, event-sourced checkpointing, deterministic workflow replays, activity heartbeats, and compensation DLQs across Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{workflow,saga,orchestrat,durable,temporal,cadence,inngest,state-machine,compensation}*.*,**/workflows/**/*.{ts,js,py,go},**/activities/**/*.{ts,js,py,go},**/sagas/**/*.{ts,js,py,go},**/services/**/*workflow*.*
alwaysApply: false
---

# Agentic Durable Workflows, Saga Orchestration & Distributed Compensation Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design multi-step distributed operations, infrastructure provisioning pipelines, e-commerce checkouts, long-running agentic tasks, external service orchestrations, or asynchronous business processes across Temporal, Cadence, Inngest, Hatchet, DBOS, or custom event-driven databases. Eliminate the "Partial Failure Orphan Resource Leak" (where intermediate step failures abandon un-compensated cloud resources, locked inventory, or dangling authorizations), the "In-Memory Transient Execution Trap" (where process restarts or deployments cause amnesia and double-execution), the "Non-Deterministic Replay Divergence Catastrophe" (where workflow definitions invoke un-isolated clocks, random numbers, or network I/O, breaking event-sourced state reconstruction), the "Compensating Transaction Failure Trap (The Saga Dilemma)" (where compensation steps fail mid-rollback leaving systems corrupted), the "Zombie Activity & Missing Heartbeat Stagnation" (where crashed activity workers stall workflows indefinitely), and the "Concurrent Workflow Split-Brain Anomaly" by establishing a strict 5-Tier Durable Workflow & Saga Governance Ladder, formal algebraic compensation invariants, write-ahead event journaling, idempotent activity tokens, activity heartbeat watchdogs, and dead-letter queue (DLQ) escalations.

---

## 1. Architectural Taxonomy: The 6 Distributed Workflow Catastrophes vs The 5-Tier Durable Workflow & Saga Governance Ladder

When autonomous coding agents are tasked with orchestrating multi-step distributed tasks (e.g., "create tenant $\to$ provision S3 bucket $\to$ spin up PostgreSQL schema $\to$ charge credit card $\to$ dispatch welcome email"), LLMs almost universally generate naive sequential `try/catch` or `async/await` blocks inside transient process memory:

```typescript
// ❌ CATASTROPHIC LLM WORKFLOW IMPLEMENTATION
app.post('/api/provision-tenant', async (req, res) => {
  const tenant = await db.tenants.create(req.body);
  const bucket = await s3.createBucket({ Bucket: tenant.id }); // VULN 1: What if this fails?
  const dbSchema = await rds.createDatabase(tenant.id);        // VULN 2: If this crashes, bucket is leaked!
  await stripe.charges.create({ amount: 5000 });              // VULN 3: If process restarts here, state is lost!
  await mailer.sendWelcome(tenant.email);
  res.json({ ok: true });
});
```

In production distributed systems and long-horizon autonomous agent executions, this naive pattern produces six critical engineering catastrophes:

- **The "Partial Failure Orphan Resource Leak"**:
  - In a 5-step distributed operation, step 4 (charging the card or creating DNS records) fails due to a network timeout or invalid credit limit.
  - The naive agent handler aborts immediately or re-throws the error. Steps 1, 2, and 3 (database tenant record, S3 bucket, RDS schema) are left dangling in production.
  - Result: Thousands of orphan cloud resources accumulate, costing real infrastructure dollars, consuming unique namespaces, and holding row locks indefinitely.
  - Invariant: Every forward action $T_k$ that mutates external state MUST register a corresponding compensating undo action $C_k$ in a durable, reverse-ordered compensation stack before execution proceeds to step $k+1$.
- **The "In-Memory Transient Execution Trap & Volatile State Amnesia"**:
  - Unconstrained agents store workflow execution state (which steps have completed, pending promises, intermediate payloads) in Node.js event loop memory, Python global variables, or Go heap pointers.
  - When the hosting pod undergoes an autoscaling event, rolling deployment, node drain, or OOM crash, all memory is instantly obliterated.
  - Upon process restart, the system either abandons the workflow completely (silent data loss, customer never receives their purchased service) or restarts the workflow from step 1 (executing duplicate charges, provisioning duplicate infrastructure, and corrupting relational integrity).
  - Invariant: Workflow state transitions MUST be durably checkpointed to an append-only event ledger (Write-Ahead Journaling) *before* external activity dispatch and *after* activity completion.
- **The "Non-Deterministic Replay Divergence Catastrophe"**:
  - When agents adopt durable execution runtimes (Temporal, Cadence, Inngest, DBOS), workflows achieve fault tolerance by replaying event history: when a worker recovers from a crash, it re-runs the workflow code from the beginning, matching executed activities against past event records.
  - Agents unaware of replay physics introduce non-deterministic operations directly inside workflow functions: calling `Math.random()`, `crypto.randomUUID()`, `Date.now()`, inspecting environment variables, or executing direct HTTP fetches (`fetch()` / `axios.get()`).
  - During history replay, the re-computed random value or timestamp differs from the recorded event history, or the HTTP call returns different data. The runtime detects a `NonDeterministicWorkflowError` or replay divergence panic, permanently bricking the workflow in an unrecoverable state.
  - Invariant: **The Determinism Equivalence Law**: Workflow code must be a pure mathematical state machine. All side effects, network requests, wall-clock measurements, and randomness MUST be strictly sequestered into Activities.
- **The "Compensating Transaction Failure Trap (The Saga Dilemma)"**:
  - When step $k$ aborts, the backward compensation sequence begins rolling back steps $k-1, \dots, 1$. However, what happens if compensation step $C_2$ (e.g., deleting an S3 bucket or refunding a charge) encounters a `503 Service Unavailable` or connection reset?
  - Naive agents catch the error and log a console warning or crash the worker, terminating the rollback midway. Steps prior to $C_2$ are never compensated, leaving the system in a fractured, half-unwound split-brain state.
  - Invariant: Compensating transactions MUST be designed with guaranteed idempotence ($C_i(C_i(S)) \equiv C_i(S)$) and executed under bounded exponential retry backoff. If permanently failing, the saga MUST transition to a durable Saga Dead-Letter Queue (DLQ) with automated Human-in-the-Loop escalation alerts.
- **The "Zombie Activity & Missing Heartbeat Stagnation"**:
  - An activity worker picks up a long-running task (e.g., downloading a 5GB dataset, training a model, or executing an LLM synthesis step with a 120-second timeout).
  - The worker process crashes, gets killed by the Kubernetes OOM killer, or encounters an OS network freeze.
  - Without an explicit activity heartbeat watchdog, the orchestrator has no way of knowing whether the worker is still actively computing or dead. The workflow hangs in `RUNNING` state for hours until the overall schedule timeout expires.
  - Invariant: Long-running activities MUST issue periodic heartbeats ($\tau_{\text{hb}} \le \frac{1}{3}\tau_{\text{timeout}}$). If a worker fails to heartbeat within the prescribed window, the orchestrator immediately marks the activity failed and reassigns it to an alternative worker.
- **The "Concurrent Workflow Split-Brain Anomaly"**:
  - Two distinct agent workflows receive concurrent trigger requests targeting the exact same domain aggregate (e.g., two concurrent workflows resizing the same cluster or updating the same customer billing plan).
  - Without unique business-key workflow deduplication or distributed fencing, both workflows execute concurrently, interleaving forward steps and compensations unpredictably and leaving storage in an undefined state.
  - Invariant: Every workflow execution MUST be uniquely identified by a deterministic Business Execution ID (`WorkflowID = {TenantID}:{AggregateType}:{ActionKey}`) and enforce single-flight concurrency at the orchestrator boundary.

---

### The 5-Tier Durable Workflow & Saga Governance Ladder

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Tier 4: Durable Saga DLQ, External Signal Gates & HITL Escalation           │
│         Unrecoverable compensation failures routed to persistent DLQ;       │
│         workflows suspend awaiting external cryptographic human approval    │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Idempotent Activity Invariants, Leased Tokens & Heartbeat Watchdogs │
│         Every activity accepts deterministic IdempotencyKey; long activities│
│         emit heartbeats at 1/3 timeout; dead workers reclaimed immediately  │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Two-Phase Saga Compensation Protocol                                │
│         Forward execution with jittered retries; failure triggers reverse   │
│         topological compensation stack C_k -> C_{k-1} -> ... -> C_1         │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Write-Ahead Event Journaling & Deterministic Checkpointing          │
│         Workflow state, step inputs, and step outputs persisted to append-  │
│         only event ledger; worker crash resumes from exact last checkpoint  │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Strict Workflow / Activity Purity & Replay Determinism Equivalence   │
│         Workflow definitions are pure functions; zero raw I/O, no unseeded  │
│         randomness, no wall clocks outside Activities; deterministic replay │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical & Formal Invariant Calculus

### 2.1 The Formal Algebraic Saga Compensation Model

Let a distributed transaction (Saga) $\mathcal{S}$ be defined as a directed sequence of $n$ atomic forward transactions:

$$\mathcal{T} = (T_1, T_2, \dots, T_n)$$

For each forward transaction $T_i$ where $1 \le i < n$, there exists a corresponding compensating transaction $C_i$:

$$\mathcal{C} = (C_1, C_2, \dots, C_{n-1})$$

Let $S_0$ denote the initial durable system state. The application of a forward transaction transitions the system from state $S_{i-1}$ to $S_i$:

$$S_i = T_i(S_{i-1})$$

A Saga execution succeeds if and only if all $n$ forward transactions commit:

$$S_{\text{final}} = (T_n \circ T_{n-1} \circ \dots \circ T_1)(S_0)$$

#### The Abort Invariant & Backward Compensation Stack

If transaction $T_k$ fails ($1 \le k \le n$) and forward retries are exhausted, the forward execution terminates. The system MUST apply the backward compensation sequence in strict reverse topological order:

$$\mathcal{C}_k^{-1} = (C_{k-1}, C_{k-2}, \dots, C_1)$$

The final state resulting from backward compensation is:

$$S_{\text{compensated}} = (C_1 \circ C_2 \circ \dots \circ C_{k-1} \circ T_{k-1} \circ \dots \circ T_1)(S_0)$$

**The Semantic Equivalence Axiom**: The backward compensation sequence must return the business domain to a semantically equivalent zero-mutation state with respect to the initial state:

$$S_{\text{compensated}} \approx S_0$$

*(Note: In distributed systems, semantic equivalence $\approx$ accounts for immutable audit traces or incurred third-party transaction fees, while all reserved capacities, temporary authorizations, and allocated resources are fully released).*

#### The Compensation Idempotency Invariant

Compensating transactions may fail transiently and be retried multiple times. Therefore, every compensating transaction $C_i$ MUST be strictly idempotent:

$$C_i(C_i(S)) \equiv C_i(S) \quad \forall S$$

#### The Topological Dependency Ordering Invariant

If transaction $T_j$ depends on state produced by $T_i$ ($i < j$), the compensation $C_i$ MUST NOT execute before compensation $C_j$:

$$\text{Order}(C_j) \prec \text{Order}(C_i) \quad \forall i < j$$

---

### 2.2 Replay Determinism & Event Sourcing Equivalence

In an event-sourced durable workflow engine, the current workflow state $S_t$ at event index $t$ is reconstructed by folding the ordered event history $H = [e_1, e_2, \dots, e_m]$ over a pure state transition reducer function $\delta$:

$$S_t = \delta(S_{t-1}, e_t) = \delta(\dots \delta(\delta(S_0, e_1), e_2) \dots, e_m)$$

Let $W$ be the workflow orchestration function. When evaluated on history $H$, $W$ produces a deterministic vector of outward activity commands $\vec{c}$:

$$W(H) \to \vec{c}_t$$

**The Deterministic Replay Invariance Theorem**:

$$\forall H_1, H_2 \text{ such that } H_1 \equiv H_2 \implies W(H_1) = W(H_2) \text{ and } \vec{c}_t(H_1) \equiv \vec{c}_t(H_2)$$

If $W$ invokes any un-isolated source of non-determinism $\xi$ (e.g., system wall clock, pseudo-random generator, memory address formatting, external HTTP socket reads):

$$W(H, \xi_1) \neq W(H, \xi_2) \implies \text{NonDeterministicReplayException}$$

Therefore, autonomous agents are strictly forbidden from executing any non-deterministic primitives inside workflow definitions.

---

### 2.3 Activity Timeout & Heartbeat Watchdog Calculus

Every activity $A$ registered within a durable workflow MUST specify three bounded temporal constraints:

1. **Schedule-To-Start Timeout ($\tau_{\text{sts}}$)**: Maximum queue waiting time before a worker picks up the task.
2. **Start-To-Close Timeout ($\tau_{\text{stc}}$)**: Absolute upper bound for total activity execution time.
3. **Heartbeat Timeout ($\tau_{\text{hb}}$)**: Maximum allowable interval between successive worker liveness signals.

Let $t_k$ and $t_{k+1}$ be consecutive heartbeat emission timestamps from an activity worker:

$$\Delta t_{\text{hb}} = t_{k+1} - t_k$$

The orchestrator enforces the liveness condition:

$$\Delta t_{\text{hb}} \le \tau_{\text{hb}}$$

If $\Delta t_{\text{hb}} > \tau_{\text{hb}}$, the worker is declared dead ($\text{DEAD\_WORKER}$). The activity execution lock is revoked immediately, and the activity is re-enqueued for an available alternative worker.

**Worker Emission Rule**: The worker must emit heartbeats at an interval bounded by one-third of the timeout to prevent false partitions due to network jitter:

$$t_{\text{interval}} \le \frac{1}{3}\tau_{\text{hb}}$$

---

## 3. Complete Production-Ready TypeScript Implementation: `AgenticDurableSagaEngine`

The following production-ready engine implements event-sourced write-ahead journaling, forward step execution with decorrelated jitter, reverse topological saga compensation, idempotent activity execution keys, activity heartbeat tracking, and DLQ escalation:

```typescript
// agentic-durable-saga-engine.ts
import { randomUUID } from 'node:crypto';

export type StepStatus = 'PENDING' | 'RUNNING' | 'COMPLETED' | 'FAILED' | 'COMPENSATED' | 'COMPENSATION_FAILED';
export type SagaStatus = 'INITIALIZED' | 'RUNNING' | 'COMPLETED' | 'COMPENSATING' | 'COMPENSATED' | 'FAILED_DLQ';

export interface ActivityContext {
  workflowId: string;
  stepId: string;
  idempotencyKey: string;
  attempt: number;
  heartbeat: (progress?: Record<string, unknown>) => Promise<void>;
  signal: AbortSignal;
}

export interface SagaStep<TInput, TOutput> {
  id: string;
  name: string;
  timeoutMs: number;
  heartbeatTimeoutMs?: number;
  maxAttempts: number;
  execute: (input: TInput, ctx: ActivityContext) => Promise<TOutput>;
  compensate: (input: TInput, output: TOutput | undefined, ctx: ActivityContext) => Promise<void>;
}

export interface JournalRecord {
  journalId: string;
  workflowId: string;
  stepId: string;
  eventType: 'STEP_STARTED' | 'STEP_HEARTBEAT' | 'STEP_COMPLETED' | 'STEP_FAILED' | 'COMPENSATION_STARTED' | 'COMPENSATION_COMPLETED' | 'COMPENSATION_FAILED';
  payload?: unknown;
  timestamp: string;
}

export interface DurableJournalStore {
  append(record: JournalRecord): Promise<void>;
  getHistory(workflowId: string): Promise<JournalRecord[]>;
  saveWorkflowState(workflowId: string, status: SagaStatus, stateData: Record<string, unknown>): Promise<void>;
  enqueueDLQ(workflowId: string, failedStepId: string, error: string, stateData: Record<string, unknown>): Promise<void>;
}

export class MemoryJournalStore implements DurableJournalStore {
  private records: JournalRecord[] = [];
  private states = new Map<string, { status: SagaStatus; data: Record<string, unknown> }>();
  public dlq: Array<{ workflowId: string; stepId: string; error: string; data: Record<string, unknown> }> = [];

  async append(record: JournalRecord): Promise<void> {
    this.records.push({ ...record, timestamp: new Date().toISOString() });
  }

  async getHistory(workflowId: string): Promise<JournalRecord[]> {
    return this.records.filter((r) => r.workflowId === workflowId);
  }

  async saveWorkflowState(workflowId: string, status: SagaStatus, stateData: Record<string, unknown>): Promise<void> {
    this.states.set(workflowId, { status, data: stateData });
  }

  async enqueueDLQ(workflowId: string, failedStepId: string, error: string, stateData: Record<string, unknown>): Promise<void> {
    this.dlq.push({ workflowId, stepId: failedStepId, error, data: stateData });
  }
}

export class AgenticDurableSagaEngine {
  private steps: SagaStep<any, any>[] = [];
  private completedSteps: Array<{ step: SagaStep<any, any>; input: any; output: any }> = [];

  constructor(
    private readonly workflowId: string,
    private readonly journal: DurableJournalStore
  ) {}

  public registerStep<TIn, TOut>(step: SagaStep<TIn, TOut>): this {
    this.steps.push(step);
    return this;
  }

  public async execute(initialInput: Record<string, unknown>): Promise<{ status: SagaStatus; result?: unknown; error?: string }> {
    let currentInput = initialInput;
    await this.journal.saveWorkflowState(this.workflowId, 'RUNNING', { initialInput });

    for (const step of this.steps) {
      const stepIdempotencyKey = `${this.workflowId}:${step.id}:exec`;
      let attempt = 0;
      let stepSuccess = false;
      let stepOutput: unknown = undefined;

      while (attempt < step.maxAttempts && !stepSuccess) {
        attempt++;
        const abortController = new AbortController();
        const timeoutTimer = setTimeout(() => abortController.abort(), step.timeoutMs);
        let lastHeartbeat = Date.now();

        const heartbeatTimer = step.heartbeatTimeoutMs
          ? setInterval(() => {
              const elapsed = Date.now() - lastHeartbeat;
              if (elapsed > step.heartbeatTimeoutMs!) {
                abortController.abort(new Error(`Activity heartbeat timed out after ${elapsed}ms`));
              }
            }, Math.floor(step.heartbeatTimeoutMs / 3))
          : undefined;

        const ctx: ActivityContext = {
          workflowId: this.workflowId,
          stepId: step.id,
          idempotencyKey: stepIdempotencyKey,
          attempt,
          signal: abortController.signal,
          heartbeat: async (progress) => {
            lastHeartbeat = Date.now();
            await this.journal.append({
              journalId: randomUUID(),
              workflowId: this.workflowId,
              stepId: step.id,
              eventType: 'STEP_HEARTBEAT',
              payload: progress,
              timestamp: new Date().toISOString(),
            });
          },
        };

        try {
          await this.journal.append({
            journalId: randomUUID(),
            workflowId: this.workflowId,
            stepId: step.id,
            eventType: 'STEP_STARTED',
            payload: { attempt, input: currentInput },
            timestamp: new Date().toISOString(),
          });

          stepOutput = await step.execute(currentInput, ctx);
          stepSuccess = true;

          await this.journal.append({
            journalId: randomUUID(),
            workflowId: this.workflowId,
            stepId: step.id,
            eventType: 'STEP_COMPLETED',
            payload: { output: stepOutput },
            timestamp: new Date().toISOString(),
          });

          this.completedSteps.push({ step, input: currentInput, output: stepOutput });
          currentInput = (stepOutput && typeof stepOutput === 'object')
            ? { ...currentInput, ...(stepOutput as Record<string, unknown>) }
            : stepOutput;
        } catch (err: any) {
          const isFinalAttempt = attempt >= step.maxAttempts;
          await this.journal.append({
            journalId: randomUUID(),
            workflowId: this.workflowId,
            stepId: step.id,
            eventType: 'STEP_FAILED',
            payload: { attempt, error: err.message, willRetry: !isFinalAttempt },
            timestamp: new Date().toISOString(),
          });

          if (isFinalAttempt) {
            // Forward retries exhausted -> Initiate backward compensation
            const compResult = await this.rollback(step.id, err.message);
            return compResult;
          }

          // Full decorrelated jitter backoff: t = min(maxWait, Uniform(base, prev * 3))
          const backoff = Math.min(10000, Math.floor(Math.random() * (100 * Math.pow(2, attempt))));
          await new Promise((r) => setTimeout(r, backoff));
        } finally {
          clearTimeout(timeoutTimer);
          if (heartbeatTimer) clearInterval(heartbeatTimer);
        }
      }
    }

    await this.journal.saveWorkflowState(this.workflowId, 'COMPLETED', { finalOutput: currentInput });
    return { status: 'COMPLETED', result: currentInput };
  }

  private async rollback(failingStepId: string, rootError: string): Promise<{ status: SagaStatus; error: string }> {
    await this.journal.saveWorkflowState(this.workflowId, 'COMPENSATING', { failingStepId, rootError });

    // Unwind completed steps in reverse topological order (LIFO stack)
    const compensationStack = [...this.completedSteps].reverse();

    for (const record of compensationStack) {
      const compIdempotencyKey = `${this.workflowId}:${record.step.id}:comp`;
      let compAttempts = 0;
      const maxCompAttempts = 3;
      let compSuccess = false;

      while (compAttempts < maxCompAttempts && !compSuccess) {
        compAttempts++;
        const abortController = new AbortController();
        const timeoutTimer = setTimeout(() => abortController.abort(), record.step.timeoutMs);

        const ctx: ActivityContext = {
          workflowId: this.workflowId,
          stepId: record.step.id,
          idempotencyKey: compIdempotencyKey,
          attempt: compAttempts,
          signal: abortController.signal,
          heartbeat: async () => {},
        };

        try {
          await this.journal.append({
            journalId: randomUUID(),
            workflowId: this.workflowId,
            stepId: record.step.id,
            eventType: 'COMPENSATION_STARTED',
            payload: { attempt: compAttempts },
            timestamp: new Date().toISOString(),
          });

          await record.step.compensate(record.input, record.output, ctx);
          compSuccess = true;

          await this.journal.append({
            journalId: randomUUID(),
            workflowId: this.workflowId,
            stepId: record.step.id,
            eventType: 'COMPENSATION_COMPLETED',
            payload: { attempt: compAttempts },
            timestamp: new Date().toISOString(),
          });
        } catch (compErr: any) {
          await this.journal.append({
            journalId: randomUUID(),
            workflowId: this.workflowId,
            stepId: record.step.id,
            eventType: 'COMPENSATION_FAILED',
            payload: { attempt: compAttempts, error: compErr.message },
            timestamp: new Date().toISOString(),
          });

          if (compAttempts >= maxCompAttempts) {
            // Unrecoverable compensation error -> Escalate to Dead-Letter Queue
            await this.journal.enqueueDLQ(
              this.workflowId,
              record.step.id,
              `Compensation permanently failed: ${compErr.message}. Root cause: ${rootError}`,
              { failingStepId, completedSteps: this.completedSteps.map((c) => c.step.id) }
            );
            await this.journal.saveWorkflowState(this.workflowId, 'FAILED_DLQ', {
              fatalStepId: record.step.id,
              rootError,
              compError: compErr.message,
            });
            return {
              status: 'FAILED_DLQ',
              error: `Fatal Saga Rollback Failure at step ${record.step.id}: ${compErr.message}. Workflow transferred to DLQ for Human-in-the-Loop intervention.`,
            };
          }

          await new Promise((r) => setTimeout(r, 1000 * compAttempts));
        } finally {
          clearTimeout(timeoutTimer);
        }
      }
    }

    await this.journal.saveWorkflowState(this.workflowId, 'COMPENSATED', { failingStepId, rootError });
    return { status: 'COMPENSATED', error: `Workflow safely rolled back. Root cause: ${rootError}` };
  }
}
```

---

## 4. 6-State Durable Workflow & Saga Lifecycle Finite-State Machine (FSM)

The workflow runtime transitions through a deterministic, strictly verified finite-state machine. No state transition may bypass the write-ahead journal:

```
                  ┌──────────────────────┐
                  │    1. INITIALIZED    │
                  └──────────┬───────────┘
                             │ Start Execution
                             ▼
                  ┌──────────────────────┐
       ┌─────────▶│      2. RUNNING      │◀───────────┐
       │          └──────────┬───────────┘            │
       │ Next Step           │ Activity Step Fails    │ External Signal
       │ Succeeded           │ (Retries Exhausted)    │ Received
       │                     ▼                        │
       │          ┌──────────────────────┐   Suspend  │
       │          │   4. COMPENSATING    │   Awaiting ├──────────────────────┐
       │          └──────────┬───────────┘   Signal   │ 6. AWAITING_SIGNAL   │
       │                     │                        │    (Human Approval)  │
       │          ┌──────────┴───────────┐            └──────────────────────┘
       │          │                      │
       │          ▼ All Compensations    ▼ Any Compensation
       │            Succeed (LIFO)         Permanently Fails
       │  ┌──────────────────┐   ┌──────────────────────┐
       │  │  5. COMPENSATED  │   │    7. FAILED_DLQ     │
       │  │  (Zero-Mutation  │   │  (Dead-Letter Queue  │
       │  │   Semantic Safe) │   │   HITL Escalation)   │
       │  └──────────────────┘   └──────────────────────┘
       │
┌──────┴──────────────┐
│    3. COMPLETED     │
│ (All Steps Success) │
└─────────────────────┘
```

### State Transition Verification Matrix

| Current State | Event Trigger | Next State | Required Invariant Verification |
| :--- | :--- | :--- | :--- |
| `INITIALIZED` | `execute(initialPayload)` | `RUNNING` | Write-Ahead Record `WORKFLOW_STARTED` committed to journal table. |
| `RUNNING` | Step $k$ succeeds | `RUNNING` or `COMPLETED` | Step output recorded in journal; step registered to LIFO compensation stack. If $k=n$, transitions to `COMPLETED`. |
| `RUNNING` | Step $k$ fails & retries exhausted | `COMPENSATING` | Reverse compensation stack verified: $[C_{k-1}, \dots, C_1]$ loaded into execution memory. |
| `RUNNING` | Step requests human gate | `AWAITING_SIGNAL` | Workflow timers suspended; external signal channel opened with bounded expiry deadline ($\tau_{\text{signal}} \le 7\text{ days}$). |
| `AWAITING_SIGNAL` | Valid cryptographic signal received | `RUNNING` | Caller signature verified against authorization registry; payload appended to event history. |
| `COMPENSATING` | All $C_i$ succeed | `COMPENSATED` | Semantic equivalence verified ($S_{\text{final}} \approx S_0$); all leased resources and authorizations revoked. |
| `COMPENSATING` | Any $C_i$ exceeds max retries | `FAILED_DLQ` | Event written to persistent DLQ table; PagerDuty / alerting webhook triggered for human-in-the-loop intervention. |

---

## 5. Cross-Language Production Idioms & Hard Anti-Patterns

### 5.1 Go (Temporal SDK / Custom Distributed Sagas)

- ❌ **Anti-Pattern: Raw Wall Clocks, Non-Deterministic Goroutines & Direct Network Calls inside Workflows**:
  ```go
  // ❌ FATAL TEMPORAL GO SDK ANTI-PATTERN
  func TenantProvisionWorkflow(ctx workflow.Context, tenantID string) error {
      now := time.Now() // BUG: Replay will produce a different time! Panic!
      go backgroundNotify() // BUG: Raw goroutine unmanaged by workflow scheduler!
      http.Post("https://api.stripe.com/...", ...) // BUG: Direct I/O inside workflow!
      return nil
  }
  ```
- ✅ **Production Invariant**: Use `workflow.Now(ctx)`, `workflow.Go(ctx, ...)`, and execute all external calls inside Activities with Activity Heartbeats and Context propagation:
  ```go
  // ✅ INDUSTRIAL TEMPORAL WORKFLOW WITH SAGA COMPENSATION IN GO
  func ProvisionTenantWorkflow(ctx workflow.Context, tenant Req) (err error) {
      ao := workflow.ActivityOptions{
          StartToCloseTimeout: 30 * time.Second,
          HeartbeatTimeout:    5 * time.Second,
          RetryPolicy: &temporal.RetryPolicy{
              InitialInterval:    time.Second,
              BackoffCoefficient: 2.0,
              MaximumAttempts:    5,
          },
      }
      ctx = workflow.WithActivityOptions(ctx, ao)

      var compensations []func(workflow.Context) error
      defer func() {
          if err != nil {
              // DisconnectedContext allows compensation even after workflow ctx is cancelled
              dCtx, _ := workflow.NewDisconnectedContext(ctx)
              for i := len(compensations) - 1; i >= 0; i-- {
                  _ = compensations[i](dCtx)
              }
          }
      }()

      var resDBSchema SchemaResult
      if err = workflow.ExecuteActivity(ctx, CreateDBSchemaActivity, tenant).Get(ctx, &resDBSchema); err != nil {
          return err
      }
      compensations = append(compensations, func(c workflow.Context) error {
          return workflow.ExecuteActivity(c, DropDBSchemaActivity, resDBSchema.ID).Get(c, nil)
      })

      var resBucket S3Result
      if err = workflow.ExecuteActivity(ctx, ProvisionS3BucketActivity, tenant).Get(ctx, &resBucket); err != nil {
          return err
      }
      compensations = append(compensations, func(c workflow.Context) error {
          return workflow.ExecuteActivity(c, DeleteS3BucketActivity, resBucket.Name).Get(c, nil)
      })

      return nil
  }
  ```

---

### 5.2 PostgreSQL / SQL Schema for Durable Saga Journaling

When building durable workflows on top of relational databases without external orchestrators, use explicit `saga_instances` and `saga_step_journal` tables with lock-free polling via `FOR UPDATE SKIP LOCKED`:

```sql
-- Production Durable Saga Execution Tables
CREATE TABLE saga_instances (
    id VARCHAR(64) PRIMARY KEY,
    workflow_name VARCHAR(128) NOT NULL,
    business_key VARCHAR(128) NOT NULL,
    status VARCHAR(32) NOT NULL CHECK (status IN ('INITIALIZED', 'RUNNING', 'COMPLETED', 'COMPENSATING', 'COMPENSATED', 'FAILED_DLQ')),
    initial_payload JSONB NOT NULL,
    current_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_saga_business_key UNIQUE (workflow_name, business_key)
);

CREATE TABLE saga_step_journal (
    id BIGSERIAL PRIMARY KEY,
    saga_id VARCHAR(64) NOT NULL REFERENCES saga_instances(id) ON DELETE RESTRICT,
    step_sequence INT NOT NULL,
    step_id VARCHAR(64) NOT NULL,
    event_type VARCHAR(32) NOT NULL,
    payload JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_saga_journal_order ON saga_step_journal(saga_id, step_sequence, id);

-- Worker Lock-Free Polling for Pending Workflow Steps
SELECT s.id, s.workflow_name, s.current_state
FROM saga_instances s
WHERE s.status IN ('RUNNING', 'COMPENSATING')
ORDER BY s.updated_at ASC
LIMIT 10
FOR UPDATE SKIP LOCKED;
```

---

## 6. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

Prior to approving any pull request, deploying code, or finishing an autonomous agent trajectory that orchestrates multi-step distributed operations, all 6 gates MUST be verified:

| Verification Gate | Machine Verification Criterion | Failure Mode Action |
| :--- | :--- | :--- |
| **Gate 1: Replay Determinism** | Static AST analysis confirms zero unseeded `Math.random()`, `Date.now()`, `crypto.randomUUID()`, or direct `fetch()` calls inside workflow definitions. | Reject PR. Force isolation of non-deterministic calls into Activities. |
| **Gate 2: Idempotent Activity Keys** | Every activity invocation passes a deterministic idempotency key derived from `${workflowId}:${stepId}:${attempt}`. | Build fails. Enforce explicit idempotency tokens. |
| **Gate 3: Compensation Completeness** | For every mutating activity $A_k$, an inverse compensating activity $C_k$ is registered in a LIFO compensation stack. | Reject PR. Autonomous agent must define exact compensating undo logic. |
| **Gate 4: Heartbeat & Timeout Boundaries** | All activities define explicit `timeoutMs` and long-running activities ($\ge 30\text{s}$) define `heartbeatTimeoutMs` with $\Delta t_{\text{interval}} \le \frac{1}{3}\tau_{\text{hb}}$. | Linter fails. Add heartbeat watchdogs. |
| **Gate 5: Persistent DLQ Routing** | Any permanently failing compensation step transitions the workflow to `FAILED_DLQ` with an alert payload. Under zero circumstances may compensation errors be silently swallowed. | Integration test assertion fails. Verify DLQ record emission. |
| **Gate 6: Chaos Crash-Resume Verification** | A kill-switch terminates the worker process mid-workflow (`kill -9`). On restart, the engine reads the journal history and resumes from the exact last uncommitted step without duplicate side effects. | Chaos test fails. Checkpoint state before advancing. |
