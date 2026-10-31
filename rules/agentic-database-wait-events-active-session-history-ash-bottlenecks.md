---
description: PostgreSQL wait events (Activity, BufferPin, Client, Extension, IPC, IO, Lock, LWLock, Timeout), Active Session History (ASH) 1Hz sampling, pg_wait_sampling circular ring buffers, pg_stat_activity diagnosis, distinguishing CPU time vs Wait time, eliminating naive index addition for lock/IO bottlenecks, diagnosing ClientRead zombie idle-in-transaction connection hoarding, IO:DataFileRead disk thrashing, IO:WALSync fsync commit bottlenecks, and Lock:relation lock queues across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, psycopg3), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{wait,event,ash,profiling,stat,bottleneck,lock,activity,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Wait Events, Active Session History (ASH), `pg_stat_activity` Sampling, Lock Contention Profiling & Bottleneck Triaging

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to monitor relational database performance, diagnose query latency regressions, triage production CPU and I/O bottlenecks, inspect transaction lock cascades, and maintain Active Session History (ASH) sampling across PostgreSQL (12–17+) in Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Naive Index Addition Blindness (Speculative Indexing on Lock/IO Bottlenecks)" (where queries time out and agents blindly add indexes without realizing the query was waiting on `Lock:relation` or `LWLock:BufferContent`, multiplying write bloat without reducing wait time), the "ClientRead Zombie Backend Hoarding (`idle in transaction` Lock Starvation)" (where applications open transactions, execute external microservice or LLM HTTP calls, leaving backends parked on wait event `Client:ClientRead` while holding table/row locks, starving concurrent writers and pinning the cluster-wide $x_{\min}$ horizon), the "IO:DataFileRead Working Set Eviction & Disk IOPS Saturation Cliff" (where spikes in `IO:DataFileRead` signal that hot working sets have outgrown `shared_buffers` or unbuffered scans are thrashing cache lines, requiring buffer sizing rather than query rewriting), the "IO:WALSync & LWLock:WALWrite Commit Stalls (Single-Row fsync Storm)" (where thousands of unbatched single-row transactions hammer storage with synchronous fsync calls, stalling concurrent workloads), the "LWLock:BufferMapping / BufferContent Hash Bucket Thrashing" (where extreme concurrency on shared buffer pages or buffer table hash buckets spins on lightweight locks, pinning CPU cores at 100%), and the "Point-in-Time `pg_stat_activity` Amnesia & Missing ASH Ring Buffer" (where relying on ad-hoc point-in-time snapshots misses sub-second lock spikes and transient stalls, leaving post-incident RCA completely blind) by establishing a strict 5-Tier Wait Event & ASH Governance Ladder, Average Active Sessions (AAS) calculus, Cary Millsap's Method R response time models, quadratic lock delay theorems, a production-ready TypeScript `AgenticDatabaseWaitEventGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state wait event lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Wait Event & Active Session History Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, every running backend thread/process is either **on-CPU** (actively computing, evaluating expressions, sorting in `work_mem`, or traversing index nodes) or **waiting on an event** (blocked on I/O, a heavyweight lock, a lightweight lock `LWLock`, an inter-process communication `IPC`, or client network socket reads).

PostgreSQL exposes this telemetry through `pg_stat_activity`:
- `wait_event_type`: The high-level category of wait (`CPU` if `wait_event IS NULL` and `state = 'active'`, `Activity`, `BufferPin`, `Client`, `Extension`, `IPC`, `IO`, `Lock`, `LWLock`, `Timeout`).
- `wait_event`: The specific event name (e.g., `DataFileRead`, `WALSync`, `relation`, `transactionid`, `BufferContent`, `BufferMapping`, `ClientRead`).
- `state`: Backend state (`active`, `idle`, `idle in transaction`, `idle in transaction (aborted)`, `fastpath function call`, `disabled`).

When autonomous coding agents or engineers attempt to optimize slow databases without wait-event decomposition, catastrophic misdiagnoses occur:

### The 6 Wait Event & Active Session History Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                       THE 6 WAIT EVENT & ACTIVE SESSION HISTORY CATASTROPHES                       |
+------------------------------------+---------------------------------------------------------------+
| 1. Naive Index Addition Blindness  | Latency spikes lead agents to run EXPLAIN and blindly add     |
|    (Speculative Index Fallacy)     | indexes; the query was blocked on Lock:relation, so the new   |
|                                    | index adds write amplification and worsens lock contention!   |
+------------------------------------+---------------------------------------------------------------+
| 2. ClientRead Zombie Hoarding      | App opens a transaction, calls external APIs / LLM endpoints, |
|    (idle in transaction Starvation)| leaving backend parked on Client:ClientRead while holding row |
|                                    | locks; blocks all writers and pins the cluster xmin horizon.  |
+------------------------------------+---------------------------------------------------------------+
| 3. IO:DataFileRead Working Set     | Spikes in IO:DataFileRead indicate working set outgrew RAM or |
|    Eviction & IOPS Cliff           | unbuffered scans thrash cache; speculative query rewrites     |
|                                    | fail while shared_buffers sizing & keyset seeks were required.|
+------------------------------------+---------------------------------------------------------------+
| 4. IO:WALSync & LWLock:WALWrite    | Thousands of unbatched single-row auto-commit transactions    |
|    Commit Stalls (fsync Storm)     | hammer storage with synchronous fsync flushes, pinning disk   |
|                                    | IOPS and causing 100x latency spikes on concurrent writes.    |
+------------------------------------+---------------------------------------------------------------+
| 5. LWLock:BufferMapping / Content  | Extreme concurrency on small hot tables or hash buckets spins |
|    Hash Bucket Thrashing           | on lightweight locks (BufferMapping, BufferContent), pinning  |
|                                    | CPU at 100% in kernel spinlocks without making query progress.|
+------------------------------------+---------------------------------------------------------------+
| 6. Point-in-Time Stat Amnesia      | Relying on sporadic manual SELECT * FROM pg_stat_activity     |
|    (Missing ASH Ring Buffer)       | misses transient 500ms lock pileups and sub-second I/O stalls,|
|                                    | leaving incident response completely blind to root causes.    |
+------------------------------------+---------------------------------------------------------------+
```

---

## 2. The 5-Tier Wait Event & ASH Governance Ladder

```
[Tier 4: Autonomous Wait Event Sentinel & Machine-Verifiable CI Gates]
       ▲  Continuous pg_blocking_pids() graph resolution; CI rejects index creation if wait is Lock-dominated
       │
[Tier 3: Bottleneck-Specific Prescription & Method R Decomposition]
       ▲  Decompose AAS into CPU vs IO vs Lock vs LWLock; apply targeted remediation matching root cause
       │
[Tier 2: Continuous 1Hz Active Session History (ASH) Ring Buffer Sampling]
       ▲  Deploy pg_wait_sampling or autonomous 1Hz in-memory ASH sampling table with rolling 24h retention
       │
[Tier 1: ClientRead Zombie & idle in transaction Hard Fencing]
       ▲  Enforce idle_in_transaction_session_timeout <= 5000ms; forbid network I/O inside open transactions
       │
[Tier 0: Wait Event Taxonomy & GUC Telemetry Baseline]
          Mandatory track_activities = on, track_io_timing = on; classify CPU on-core vs Wait states
```

### Tier 0: Wait Event Taxonomy & GUC Telemetry Baseline
- **Enable I/O Timing**: PostgreSQL defaults `track_io_timing = off` to avoid clock read overhead on legacy hardware. On modern hypervisors and bare metal, `track_io_timing` overhead is $< 0.1\%$. Set `track_io_timing = on` in `postgresql.conf` so `IO:DataFileRead` and `IO:WALSync` record accurate microsecond duration.
- **Enable Activity Tracking**: Guarantee `track_activities = on` with `track_activity_query_size >= 2048` (to avoid truncating complex SQL queries).
- **Distinguish CPU vs Wait**:
  - `state = 'active' AND wait_event IS NULL`: Backend is actively utilizing a CPU core.
  - `state = 'active' AND wait_event IS NOT NULL`: Backend is off-CPU, stalled waiting on external resource.
  - `state = 'idle'`: Backend is waiting for the next client command.
  - `state = 'idle in transaction'`: Backend completed a statement inside `BEGIN` and is waiting for client application.

### Tier 1: ClientRead Zombie & Idle-in-Transaction Hard Fencing
- **Enforce Timeout Fencing**: Configure `idle_in_transaction_session_timeout = '5000ms'` in production cluster settings. Any backend remaining `idle in transaction` longer than 5 seconds is terminated immediately with `FATAL: terminating connection due to idle-in-transaction timeout`.
- **Absolute Prohibition of Network I/O in Transactions**:
  - ❌ NEVER make HTTP calls, gRPC requests, S3 uploads, or LLM inferences while holding an open PostgreSQL transaction (`tx.Begin()`).
  - ✅ Execute external network operations *before* opening the transaction or *after* committing. If two-phase coordination is required, utilize the Transactional Outbox pattern.

### Tier 2: Continuous 1Hz Active Session History (ASH) Ring Buffer Sampling
- **The ASH Sampling Protocol**: Every 1,000 milliseconds, query `pg_stat_activity` for all sessions where `state = 'active'` or `state = 'idle in transaction'`.
- Record:
  - `sample_time`: Timestamp of sampling tick.
  - `pid`: Process ID.
  - `user_id`, `database_name`: Context.
  - `wait_event_type`, `wait_event`: Specific bottleneck.
  - `query_id`, `query_snippet`: Normalized statement identifier.
  - `blocking_pids`: Array of upstream blocker PIDs (`pg_blocking_pids(pid)`).
- **Storage Bounds**: Store samples in an unlogged or ring-buffer memory table with bounded retention ($24$ hours), or leverage the `pg_wait_sampling` extension.

### Tier 3: Wait Event Decomposition & Bottleneck-Specific Prescriptions
- Decompose system load using Cary Millsap's Method R:
  - If $\text{AAS}_{\text{CPU}} / \text{AAS} > 0.60$: **CPU-Bound**. Look for sequential scans on unindexed tables, CPU-heavy regex/JSON parsing, missing composite indexes, or excessive parallel query workers.
  - If $\text{AAS}_{\text{IO}} / \text{AAS} > 0.50$ (`IO:DataFileRead`): **I/O Read Bound**. Hot working set exceeds `shared_buffers`. Inspect table fillfactor, implement keyset pagination, or increase `shared_buffers`.
  - If $\text{AAS}_{\text{IO}} / \text{AAS} > 0.50$ (`IO:WALSync`): **I/O Commit Bound**. Too many micro-transactions executing synchronous fsync. Batch mutations or apply `SET LOCAL synchronous_commit = off`.
  - If $\text{AAS}_{\text{Lock}} / \text{AAS} > 0.30$ (`Lock:relation`, `Lock:tuple`): **Locking Contention**. DO NOT add indexes. Reduce transaction duration, sort update operations in canonical order, or use `SKIP LOCKED`.
  - If $\text{AAS}_{\text{LWLock}} / \text{AAS} > 0.30$ (`LWLock:BufferContent`, `LWLock:BufferMapping`): **Memory Latch Contention**. Optimize hot blocks, partition high-traffic tables, or calibrate connection pool size to match physical core count.

### Tier 4: Autonomous Lock Wait Tree Sentinel & Machine-Verifiable CI Gates
- **Lock Wait Tree Resolution**: Continuously compute the directed acyclic graph (DAG) of blocking transactions. Isolate the root blocker (the node with in-degree 0 and out-degree $> 0$ in the wait graph).
- **CI Gate Against Speculative Indexing**: Autonomous agents and developers MUST NOT propose adding an index for a slow query unless telemetry verifies that the query's wait profile is dominated by `CPU` or `IO:DataFileRead`. If the query's latency is dominated by `Lock:*` or `Client:ClientRead`, the pull request is rejected by CI.

---

## 3. Mathematical Foundations: Average Active Sessions (AAS), Method R Response Time Calculus & Lock Contention Physics

### 1. Average Active Sessions (AAS) Calculus

In queueing theory applied to database performance, the fundamental metric of cluster load is **Average Active Sessions (AAS)**:

$$\text{AAS} = \frac{1}{T} \sum_{t=1}^{T} N_{\text{active}}(t)$$

Where $N_{\text{active}}(t)$ is the count of database sessions in `state = 'active'` at sample tick $t$.

Decomposing AAS across wait event categories:

$$\text{AAS} = \text{AAS}_{\text{CPU}} + \text{AAS}_{\text{IO}} + \text{AAS}_{\text{Lock}} + \text{AAS}_{\text{LWLock}} + \text{AAS}_{\text{ClientZombie}} + \text{AAS}_{\text{Other}}$$

Where:
- $\text{AAS}_{\text{CPU}} = \frac{1}{T} \sum_{t=1}^{T} \mathbf{1}_{\{ \text{state} = \text{'active'} \land \text{wait\_event IS NULL} \}}$
- $\text{AAS}_{\text{IO}} = \frac{1}{T} \sum_{t=1}^{T} \mathbf{1}_{\{ \text{wait\_event\_type} = \text{'IO'} \}}$
- $\text{AAS}_{\text{Lock}} = \frac{1}{T} \sum_{t=1}^{T} \mathbf{1}_{\{ \text{wait\_event\_type} = \text{'Lock'} \}}$
- $\text{AAS}_{\text{LWLock}} = \frac{1}{T} \sum_{t=1}^{T} \mathbf{1}_{\{ \text{wait\_event\_type} = \text{'LWLock'} \}}$

#### The CPU Core Capacity Boundary Theorem

Let $N_{\text{cores}}$ be the number of physical CPU cores allocated to the database host:
1. If $\text{AAS}_{\text{CPU}} \le 0.8 \cdot N_{\text{cores}}$: **Healthy CPU Margin**. Queries execute with zero runqueue contention.
2. If $\text{AAS}_{\text{CPU}} > N_{\text{cores}}$: **CPU Starvation**. Operating system runqueues build up; context-switch thrashing degrades throughput exponentially.
3. If $\text{AAS} \gg N_{\text{cores}}$ while $\text{AAS}_{\text{CPU}} \ll N_{\text{cores}}$: **Resource Serialization**. The database is bottlenecked on external resources (I/O disks, row/table locks, or client network delay). Adding more CPU cores will NOT improve performance.

---

### 2. Cary Millsap's Method R Response Time Calculus

The total response time $R(Q)$ of an individual transaction or query $Q$ consists of service time $T_{\text{service}}$ (active CPU processing) plus the sum of all wait event durations $T_{\text{wait}, k}$:

$$R(Q) = T_{\text{service}}(Q) + \sum_{k \in \text{WaitEvents}} T_{\text{wait}, k}(Q)$$

The efficiency index $\eta_{\text{efficiency}}(Q)$ is defined as:

$$\eta_{\text{efficiency}}(Q) = \frac{T_{\text{service}}(Q)}{R(Q)} = \frac{T_{\text{CPU}}(Q)}{T_{\text{CPU}}(Q) + T_{\text{IO}}(Q) + T_{\text{Lock}}(Q) + T_{\text{LWLock}}(Q)}$$

- When $\eta_{\text{efficiency}}(Q) \to 1.0$: Query is compute-limited. Query optimization, expression simplification, and secondary indexes yield direct speedups.
- When $\eta_{\text{efficiency}}(Q) \to 0.0$: Query is wait-limited. Adding an index will have zero effect if $T_{\text{Lock}}$ dominates, and will worsen performance by adding index maintenance overhead to $T_{\text{service}}$.

---

### 3. Quadratic Lock Contention Queueing Calculus

Let transactions arrive at rate $\lambda_{\text{arr}}$ requesting an exclusive lock on relation or row $R$.
If an uncommitted transaction or zombie `Client:ClientRead` backend holds the lock for duration $t_{\text{hold}}$, the number of blocked sessions $Q(t)$ accumulates linearly:

$$Q(t) = \lambda_{\text{arr}} \cdot t, \quad 0 \le t \le t_{\text{hold}}$$

The cumulative transaction delay $D_{\text{total}}$ suffered by the system scales **quadratically** with lock hold time:

$$D_{\text{total}} = \int_{0}^{t_{\text{hold}}} Q(t) \, dt = \int_{0}^{t_{\text{hold}}} \lambda_{\text{arr}} \, t \, dt = \frac{1}{2} \lambda_{\text{arr}} \cdot t_{\text{hold}}^2$$

**The Quadratic Lock Explosion Law**: Doubling the lock hold duration quadruples total system latency delay ($4\times$). Tripling lock hold duration multiplies delay by $9\times$. Terminating idle-in-transaction backends within 5 seconds provides exponential latency savings across concurrent connection pools.

---

## 4. Production TypeScript Sentinel: `AgenticDatabaseWaitEventGuardEngine`

The following production engine implements automated 1Hz ASH wait event profiling, Average Active Sessions (AAS) calculation, blocker tree traversal, bottleneck classification, and speculative index prevention:

```typescript
// src/services/database/AgenticDatabaseWaitEventGuardEngine.ts

export type WaitEventType = 'CPU' | 'Activity' | 'BufferPin' | 'Client' | 'Extension' | 'IPC' | 'IO' | 'Lock' | 'LWLock' | 'Timeout';

export interface ActiveSessionSample {
  pid: number;
  userId: string;
  databaseName: string;
  state: 'active' | 'idle' | 'idle in transaction' | 'idle in transaction (aborted)';
  waitEventType: WaitEventType;
  waitEvent: string | null;
  queryId: string | null;
  querySnippet: string;
  transactionAgeMs: number;
  queryAgeMs: number;
  blockingPids: number[];
}

export interface AshSnapshot {
  timestamp: Date;
  activeSessions: ActiveSessionSample[];
  cpuCores: number;
}

export interface AasMetrics {
  totalAas: number;
  cpuAas: number;
  ioAas: number;
  lockAas: number;
  lwlockAas: number;
  clientZombieAas: number;
  cpuSaturationRatio: number; // cpuAas / cpuCores
  primaryBottleneck: 'CPU' | 'IO_READ' | 'IO_SYNC' | 'LOCK_CONTENTION' | 'LWLOCK_CONTENTION' | 'CLIENT_ZOMBIE' | 'HEALTHY';
}

export interface LockGraphNode {
  pid: number;
  query: string;
  waitEvent: string | null;
  state: string;
  transactionAgeMs: number;
  blockedBy: number[];
  blocking: number[];
}

export interface TriageRecommendation {
  verdict: 'HEALTHY' | 'ADD_INDEX_CANDIDATE' | 'FENCE_ZOMBIES' | 'BATCH_WAL_MUTATIONS' | 'RESOLVE_LOCK_ORDER';
  reason: string;
  suggestedAction: string;
  rootBlockerPids: number[];
}

export class AgenticDatabaseWaitEventGuardEngine {
  private readonly cpuCores: number;
  private readonly historyWindowSize: number;
  private readonly snapshots: AshSnapshot[] = [];

  constructor(cpuCores: number, historyWindowSize: number = 60) {
    if (cpuCores <= 0) throw new Error('cpuCores must be > 0');
    this.cpuCores = cpuCores;
    this.historyWindowSize = historyWindowSize;
  }

  /**
   * Records a 1Hz ASH sample snapshot into the circular buffer.
   */
  public recordSnapshot(sessions: ActiveSessionSample[]): void {
    const snapshot: AshSnapshot = {
      timestamp: new Date(),
      activeSessions: sessions,
      cpuCores: this.cpuCores,
    };

    this.snapshots.push(snapshot);
    if (this.snapshots.length > this.historyWindowSize) {
      this.snapshots.shift();
    }
  }

  /**
   * Computes Average Active Sessions (AAS) over the current history window.
   */
  public computeAas(): AasMetrics {
    if (this.snapshots.length === 0) {
      return {
        totalAas: 0,
        cpuAas: 0,
        ioAas: 0,
        lockAas: 0,
        lwlockAas: 0,
        clientZombieAas: 0,
        cpuSaturationRatio: 0,
        primaryBottleneck: 'HEALTHY',
      };
    }

    const windowCount = this.snapshots.length;
    let totalActiveCount = 0;
    let cpuCount = 0;
    let ioCount = 0;
    let lockCount = 0;
    let lwlockCount = 0;
    let clientZombieCount = 0;
    let ioSyncCount = 0;
    let ioReadCount = 0;

    for (const snap of this.snapshots) {
      for (const s of snap.activeSessions) {
        if (s.state === 'active') {
          totalActiveCount++;
          if (s.waitEventType === 'CPU') {
            cpuCount++;
          } else if (s.waitEventType === 'IO') {
            ioCount++;
            if (s.waitEvent === 'WALSync') ioSyncCount++;
            if (s.waitEvent === 'DataFileRead') ioReadCount++;
          } else if (s.waitEventType === 'Lock') {
            lockCount++;
          } else if (s.waitEventType === 'LWLock') {
            lwlockCount++;
          }
        } else if (s.state === 'idle in transaction') {
          clientZombieCount++;
        }
      }
    }

    const totalAas = totalActiveCount / windowCount;
    const cpuAas = cpuCount / windowCount;
    const ioAas = ioCount / windowCount;
    const lockAas = lockCount / windowCount;
    const lwlockAas = lwlockCount / windowCount;
    const clientZombieAas = clientZombieCount / windowCount;
    const cpuSaturationRatio = cpuAas / this.cpuCores;

    let primaryBottleneck: AasMetrics['primaryBottleneck'] = 'HEALTHY';

    if (clientZombieAas > 2.0) {
      primaryBottleneck = 'CLIENT_ZOMBIE';
    } else if (lockAas > 1.0 && lockAas / (totalAas || 1) > 0.3) {
      primaryBottleneck = 'LOCK_CONTENTION';
    } else if (lwlockAas > 1.0 && lwlockAas / (totalAas || 1) > 0.3) {
      primaryBottleneck = 'LWLOCK_CONTENTION';
    } else if (ioAas > 1.0 && ioAas / (totalAas || 1) > 0.4) {
      primaryBottleneck = (ioSyncCount > ioReadCount) ? 'IO_SYNC' : 'IO_READ';
    } else if (cpuSaturationRatio > 0.8) {
      primaryBottleneck = 'CPU';
    }

    return {
      totalAas,
      cpuAas,
      ioAas,
      lockAas,
      lwlockAas,
      clientZombieAas,
      cpuSaturationRatio,
      primaryBottleneck,
    };
  }

  /**
   * Resolves the directed acyclic graph (DAG) of blocking transactions.
   */
  public resolveLockGraph(currentSessions: ActiveSessionSample[]): {
    nodes: Map<number, LockGraphNode>;
    rootBlockerPids: number[];
  } {
    const nodes = new Map<number, LockGraphNode>();

    for (const s of currentSessions) {
      nodes.set(s.pid, {
        pid: s.pid,
        query: s.querySnippet,
        waitEvent: s.waitEvent,
        state: s.state,
        transactionAgeMs: s.transactionAgeMs,
        blockedBy: [...s.blockingPids],
        blocking: [],
      });
    }

    // Populate the forward "blocking" edges
    for (const [pid, node] of nodes.entries()) {
      for (const blockerPid of node.blockedBy) {
        const blockerNode = nodes.get(blockerPid);
        if (blockerNode) {
          blockerNode.blocking.push(pid);
        }
      }
    }

    // Root blockers are sessions that are blocking others but not blocked themselves
    const rootBlockerPids: number[] = [];
    for (const [pid, node] of nodes.entries()) {
      if (node.blocking.length > 0 && node.blockedBy.length === 0) {
        rootBlockerPids.push(pid);
      }
    }

    return { nodes, rootBlockerPids };
  }

  /**
   * Synthesizes automated triage recommendations based on wait event decomposition.
   */
  public triageBottleneck(currentSessions: ActiveSessionSample[]): TriageRecommendation {
    const aas = this.computeAas();
    const { rootBlockerPids } = this.resolveLockGraph(currentSessions);

    if (aas.primaryBottleneck === 'CLIENT_ZOMBIE') {
      return {
        verdict: 'FENCE_ZOMBIES',
        reason: `Detected ${aas.clientZombieAas.toFixed(1)} average idle-in-transaction sessions holding locks.`,
        suggestedAction: 'Terminate idle-in-transaction sessions exceeding 5000ms using pg_terminate_backend() and enforce idle_in_transaction_session_timeout.',
        rootBlockerPids,
      };
    }

    if (aas.primaryBottleneck === 'LOCK_CONTENTION') {
      return {
        verdict: 'RESOLVE_LOCK_ORDER',
        reason: `System is lock-bound (Lock AAS = ${aas.lockAas.toFixed(1)}). Root blockers detected: [${rootBlockerPids.join(', ')}].`,
        suggestedAction: 'DO NOT add secondary indexes. Resolve lock acquisition order canonically, shorten transaction duration, or inspect pg_blocking_pids().',
        rootBlockerPids,
      };
    }

    if (aas.primaryBottleneck === 'IO_SYNC') {
      return {
        verdict: 'BATCH_WAL_MUTATIONS',
        reason: 'Spike in IO:WALSync indicates commit-bound bottleneck from high-frequency single-row transactions.',
        suggestedAction: 'Batch mutations into multi-row statements or apply SET LOCAL synchronous_commit = off on non-critical ingest transactions.',
        rootBlockerPids: [],
      };
    }

    if (aas.primaryBottleneck === 'CPU' || aas.primaryBottleneck === 'IO_READ') {
      return {
        verdict: 'ADD_INDEX_CANDIDATE',
        reason: `Query latency driven by active compute or IO:DataFileRead (CPU AAS: ${aas.cpuAas.toFixed(1)}, IO AAS: ${aas.ioAas.toFixed(1)}).`,
        suggestedAction: 'Analyze slow query EXPLAIN (ANALYZE, BUFFERS) plans for sequential scans and consider composite or partial B-Tree indexing.',
        rootBlockerPids: [],
      };
    }

    return {
      verdict: 'HEALTHY',
      reason: `System operating within safe capacity limits (Total AAS: ${aas.totalAas.toFixed(1)} / ${this.cpuCores} cores).`,
      suggestedAction: 'Continue 1Hz ASH background sampling.',
      rootBlockerPids: [],
    };
  }

  /**
   * CI Gate: Rejects proposed index additions if the target query is lock-starved.
   */
  public verifyIndexAdditionEligibility(querySnippet: string, waitEventType: WaitEventType): boolean {
    if (waitEventType === 'Lock' || waitEventType === 'Client') {
      throw new Error(
        `CI REJECTED INDEX PROPOSAL: Query "${querySnippet}" is blocked on ${waitEventType} wait event. ` +
        `Adding an index does not eliminate lock contention and increases write amplification. ` +
        `Remediate transaction holding time and lock acquisition ordering instead.`
      );
    }
    return true;
  }
}
```

---

## 5. Multi-Language Production Implementations

### Go (`jackc/pgx/v5`): 1Hz Background Active Session History Sampler

```go
// internal/store/ash_sampler.go
package store

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type WaitEventSample struct {
	PID              int       `json:"pid"`
	Username         string    `json:"username"`
	State            string    `json:"state"`
	WaitEventType    string    `json:"wait_event_type"`
	WaitEvent        string    `json:"wait_event"`
	Query            string    `json:"query"`
	TransactionAgeMs float64   `json:"transaction_age_ms"`
	BlockingPIDs     []int32   `json:"blocking_pids"`
	SampledAt        time.Time `json:"sampled_at"`
}

type AshSampler struct {
	pool    *pgxpool.Pool
	logger  *slog.Logger
	mu      sync.RWMutex
	samples []WaitEventSample
	maxSize int
}

func NewAshSampler(pool *pgxpool.Pool, logger *slog.Logger, maxSize int) *AshSampler {
	return &AshSampler{
		pool:    pool,
		logger:  logger,
		samples: make([]WaitEventSample, 0, maxSize),
		maxSize: maxSize,
	}
}

// StartSampling runs a 1Hz ticker collecting Active Session History.
func (s *AshSampler) StartSampling(ctx context.Context) {
	ticker := time.NewTicker(1 * time.Second)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				s.logger.Info("ASH sampler stopped")
				return
			case <-ticker.C:
				if err := s.collectSample(ctx); err != nil {
					s.logger.Warn("failed to collect ASH sample", "err", err)
				}
			}
		}
	}()
}

const ashQuery = `
SELECT
    pid,
    COALESCE(usename, '') AS username,
    state,
    COALESCE(wait_event_type, 'CPU') AS wait_event_type,
    COALESCE(wait_event, '') AS wait_event,
    LEFT(query, 200) AS query,
    EXTRACT(EPOCH FROM (clock_timestamp() - xact_start)) * 1000.0 AS transaction_age_ms,
    pg_blocking_pids(pid) AS blocking_pids
FROM pg_stat_activity
WHERE state IN ('active', 'idle in transaction')
  AND pid <> pg_backend_pid();
`

func (s *AshSampler) collectSample(ctx context.Context) error {
	reqCtx, cancel := context.WithTimeout(ctx, 800*time.Millisecond)
	defer cancel()

	rows, err := s.pool.Query(reqCtx, ashQuery)
	if err != nil {
		return fmt.Errorf("query pg_stat_activity failed: %w", err)
	}
	defer rows.Close()

	now := time.Now()
	var currentBatch []WaitEventSample

	for rows.Next() {
		var sample WaitEventSample
		sample.SampledAt = now
		var txAge *float64

		if err := rows.Scan(
			&sample.PID,
			&sample.Username,
			&sample.State,
			&sample.WaitEventType,
			&sample.WaitEvent,
			&sample.Query,
			&txAge,
			&sample.BlockingPIDs,
		); err != nil {
			return fmt.Errorf("scan error: %w", err)
		}

		if txAge != nil {
			sample.TransactionAgeMs = *txAge
		}
		currentBatch = append(currentBatch, sample)
	}

	if rows.Err() != nil {
		return rows.Err()
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	for _, sample := range currentBatch {
		if len(s.samples) >= s.maxSize {
			s.samples = s.samples[1:]
		}
		s.samples = append(s.samples, sample)
	}

	return nil
}
```

---

### TypeScript (`pg`): Lock Hierarchy Tree & Blocker Resolution

```typescript
// src/db/lockHierarchyResolver.ts
import { Pool } from 'pg';

export interface BlockingChain {
  blockedPid: number;
  blockedQuery: string;
  waitEvent: string;
  blockerPid: number;
  blockerQuery: string;
  blockerState: string;
  blockerTxDurationSec: number;
}

export async function findRootLockBlockers(pool: Pool): Promise<BlockingChain[]> {
  const query = `
    SELECT
      blocked_act.pid AS blocked_pid,
      blocked_act.query AS blocked_query,
      blocked_act.wait_event AS wait_event,
      blocker_act.pid AS blocker_pid,
      blocker_act.query AS blocker_query,
      blocker_act.state AS blocker_state,
      EXTRACT(EPOCH FROM (clock_timestamp() - blocker_act.xact_start)) AS blocker_tx_duration_sec
    FROM pg_stat_activity blocked_act
    JOIN unnest(pg_blocking_pids(blocked_act.pid)) blocker_pid ON TRUE
    JOIN pg_stat_activity blocker_act ON blocker_act.pid = blocker_pid
    WHERE blocked_act.wait_event_type = 'Lock'
    ORDER BY blocker_tx_duration_sec DESC;
  `;

  const client = await pool.connect();
  try {
    const res = await client.query(query);
    return res.rows.map(row => ({
      blockedPid: row.blocked_pid,
      blockedQuery: row.blocked_query,
      waitEvent: row.wait_event,
      blockerPid: row.blocker_pid,
      blockerQuery: row.blocker_query,
      blockerState: row.blocker_state,
      blockerTxDurationSec: parseFloat(row.blocker_tx_duration_sec || '0'),
    }));
  } finally {
    client.release();
  }
}
```

---

### Python (`asyncpg`): Asynchronous ASH Sampler & AAS Metrics Engine

```python
# app/db/ash_monitor.py
import asyncio
import logging
from typing import List, Dict, Any
import asyncpg

logger = logging.getLogger(__name__)

class AsyncAshMonitor:
    def __init__(self, pool: asyncpg.Pool, cpu_cores: int):
        self.pool = pool
        self.cpu_cores = cpu_cores
        self.running = False

    async def start(self):
        self.running = True
        while self.running:
            try:
                await self._sample_tick()
            except Exception as e:
                logger.warning(f"ASH sampling failed: {e}")
            await asyncio.sleep(1.0)

    def stop(self):
        self.running = False

    async def _sample_tick(self):
        query = """
        SELECT
            COALESCE(wait_event_type, 'CPU') AS wait_event_type,
            COALESCE(wait_event, '') AS wait_event,
            COUNT(*) AS session_count
        FROM pg_stat_activity
        WHERE state = 'active' AND pid <> pg_backend_pid()
        GROUP BY 1, 2;
        """
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)
            cpu_sessions = 0
            total_active = 0
            for r in rows:
                cnt = r['session_count']
                total_active += cnt
                if r['wait_event_type'] == 'CPU':
                    cpu_sessions += cnt

            if cpu_sessions > self.cpu_cores:
                logger.error(
                    f"DATABASE CPU SATURATION ALERT: {cpu_sessions} sessions on-CPU "
                    f"exceeds hardware core count of {self.cpu_cores}!"
                )
```

---

### Rust (`sqlx`): Tokio Lock Wait Tree Sentinel

```rust
// src/db/lock_sentinel.rs
use sqlx::PgPool;
use std::time::Duration;

#[derive(Debug, sqlx::FromRow)]
pub struct LockBlockerRow {
    pub blocker_pid: i32,
    pub blocker_state: String,
    pub blocked_pid: i32,
    pub wait_event: Option<String>,
}

pub struct LockSentinel {
    pool: PgPool,
}

impl LockSentinel {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn audit_lock_queues(&self) -> Result<Vec<LockBlockerRow>, sqlx::Error> {
        let rows = sqlx::query_as::<_, LockBlockerRow>(
            r#"
            SELECT
                blocker.pid AS blocker_pid,
                blocker.state AS blocker_state,
                blocked.pid AS blocked_pid,
                blocked.wait_event AS wait_event
            FROM pg_stat_activity blocked
            JOIN unnest(pg_blocking_pids(blocked.pid)) blocker_pid ON TRUE
            JOIN pg_stat_activity blocker ON blocker.pid = blocker_pid
            WHERE blocked.wait_event_type = 'Lock'
            "#
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows)
    }
}
```

---

## 6. The 6-State Wait Event Lifecycle Finite-State Machine (FSM)

```
        [ 1. IDLE_SAMPLING ]
                 │
                 │ (1Hz ASH snapshot tick)
                 ▼
        [ 2. ASSESSING_AAS ]
         ├── AAS <= 0.8 * Cores ────────────────────────► [ 1. IDLE_SAMPLING ]
         │
         └── AAS > Threshold / Lock Spike ──────────────► [ 3. CLASSIFYING_BOTTLENECK ]
                                                                 │
                  ┌──────────────────────────────────────────────┴─────────────────────────┐
                  │                                                                        │
                  ▼                                                                        ▼
        [ 4. TRACING_LOCK_TREE ]                                                [ 5. EXECUTING_PRESCRIPTION ]
        (Walk pg_blocking_pids DAG,                                             (CPU/IO: verify EXPLAIN plan;
         isolate root blocker PID)                                               WALSync: batch commit fsync)
                  │                                                                        │
                  ▼                                                                        │
        [ 5. EXECUTING_PRESCRIPTION ]                                                      │
        (Terminate zombie idle-in-tx,                                                      │
         enforce lock_timeout)                                                             │
                  │                                                                        │
                  └────────────────────────────────┬───────────────────────────────────────┘
                                                   │
                                                   │ (Verification tick)
                                                   ▼
                                       [ 6. VERIFIED_EQUILIBRIUM ]
                                                   │
                                                   │ (AAS returns below budget)
                                                   ▼
                                        [ 1. IDLE_SAMPLING ]
```

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Test / Metric Command | Pass Condition |
| :--- | :--- | :--- | :--- |
| **Gate 1: Telemetry Activation** | I/O timing & activity tracking | `SHOW track_io_timing; SHOW track_activities;` | Both MUST return `'on'`. |
| **Gate 2: Zombie Elimination** | Idle in transaction timeout guard | `SHOW idle_in_transaction_session_timeout;` | Value MUST be configured $\le 5000\text{ms}$. |
| **Gate 3: 1Hz ASH Sampling** | Regular active session sampling | `SELECT count(*) FROM ash_samples WHERE sampled_at > now() - interval '1 minute'` | MUST yield $\ge 58$ samples per minute. |
| **Gate 4: Anti-Speculative Indexing** | Guard against indexing on lock waits | CI pipeline pull request audit | Proposals to add indexes MUST fail if wait profiling shows $> 30\%$ Lock waits. |
| **Gate 5: Lock Wait Tree Resolution** | Blocking chain DAG traversal | `SELECT count(*) FROM pg_stat_activity WHERE array_length(pg_blocking_pids(pid), 1) > 0` | Blocking chains resolved to root PID within $\le 500\text{ms}$. |
| **Gate 6: Core Capacity Budget** | CPU active session load | `AAS_CPU / N_cores` calculated over 5-minute window | MUST maintain $\le 0.80$ to preserve OS runqueue headroom. |
