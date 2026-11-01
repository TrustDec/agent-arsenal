---
description: PostgreSQL Lock Trees, Head-of-Line Blocking Convoys, recursive pg_blocking_pids() graph traversal, idle-in-transaction connection leaks, LockAcquire wait queue mechanics, surgical root blocker preemption (pg_cancel_backend vs pg_terminate_backend), and multi-tier timeout ladders across Go (pgx/v5), TypeScript (Kysely, Drizzle), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{lock,blocking,convoy,timeout,deadlock,transaction,pg_locks,activity,db,postgres}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/admin/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/storage/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Lock Trees, Head-of-Line Blocking Convoys, Recursive pg_blocking_pids Graph Traversal & Root Blocker Preemption Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design multi-row transactional updates, database migrations, high-concurrency microservice persistence layers, administrative health sentinels, or connection pooling architecture across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `pg`), Python (`SQLAlchemy 2.0`, `asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Head-of-Line Exclusive Lock Queue Avalanche (The FIFO Lock Convoy Trap)" (where an `ALTER TABLE`, migration, or un-timed DDL requests an `AccessExclusiveLock` and queues behind a slow analytical query, and because PostgreSQL's Lock Manager enforces strict FIFO queuing to prevent writer starvation, all subsequent incoming rapid `SELECT` queries are blocked behind the waiting DDL, exhausting the entire 500-connection pool in $< 3$ seconds and causing cluster-wide HTTP 504 gateway timeouts), the "`idle in transaction` Ghost Blocker Trap" (where an application backend opens a transaction, executes an update or read, and then performs an external HTTP RPC, waits on Redis, or crashes without executing `COMMIT` or `ROLLBACK`, holding locks indefinitely at 0% CPU and silently paralyzing the database while evading standard CPU-based APM alerts), the "Multi-Hop Lock Dependency Chain & Recursive `pg_blocking_pids()` Blindness" (where lock contention forms deep dependency DAGs $A \to B \to C \to \dots \to Z$, and naive agents or incident responders inspect `pg_stat_activity` and kill intermediate waiting victims, leaving the true root blocker untouched while triggering cascading transaction retries that amplify the convoy), the "Lock Upgrade Self-Deadlock & Multi-Session Convoy" (where concurrent sessions hold shared locks on identical rows or tables and simultaneously attempt to upgrade to exclusive locks, freezing backends until `deadlock_timeout = 1000ms` triggers `SQLSTATE 40P01` and spawns a retry storm), the "Non-Atomic Victim Kill & Connection Pool Decapitation Disaster" (where autonomous remediation scripts execute indiscriminate bulk terminations against waiting queries, killing healthy pooled PgBouncer connections and aborting thousands of innocent in-flight transactions while the blocker continues executing), and the "Missing Multi-Tier `lock_timeout` & `idle_in_transaction_session_timeout` Safety Rails" (where ad-hoc scripts execute DDL or batch updates without setting `lock_timeout`, allowing a single statement to block production traffic indefinitely) by establishing a strict 5-Tier Lock Tree & Blocking Session Governance Ladder, mathematical queueing collapse and DAG traversal theorems, an autonomous TypeScript `AgenticLockTreeGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state lock lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Lock Tree & Head-of-Line Blocking Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL's concurrency architecture, concurrency control is governed by the **Heavyweight Lock Manager** (`storage/lmgr/lock.c` and `proc.c`). Unlike lightweight locks (LWLocks) and latches that guard in-memory C data structures for microseconds, heavyweight locks protect database objects (relations, partitions, pages, tuples, transaction IDs, advisory keys) across transactions:

1. **The Lock Table (`LockMethodLockHash`)**: A shared-memory hash table mapping `LOCKTAG` objects (e.g., database OID, relation OID) to a `LOCK` struct.
2. **The Per-Process Lock Table (`LockMethodProcHash`)**: Maps `(LOCK, PGPROC)` pairs to a `PROCLOCK` struct tracking lock modes granted and requested by a specific backend process.
3. **The Lock Wait Queue (`LOCK->waitProcs`)**: A doubly linked FIFO queue of `PGPROC` structs waiting for conflicting locks to be released.
4. **The Lock Conflict Matrix & FIFO Head-of-Line Blocking**:
   PostgreSQL defines 8 relation lock modes:
   - `AccessShareLock` (acquired by `SELECT`)
   - `RowShareLock` (acquired by `SELECT FOR UPDATE / FOR SHARE`)
   - `RowExclusiveLock` (acquired by `UPDATE`, `DELETE`, `INSERT`)
   - `ShareUpdateExclusiveLock` (acquired by `VACUUM`, `ANALYZE`, `CREATE INDEX CONCURRENTLY`)
   - `ShareLock` (acquired by `CREATE INDEX`)
   - `ShareRowExclusiveLock` (acquired by `CREATE TRIGGER`, partial DDL)
   - `ExclusiveLock` (blocks concurrent row mutations)
   - `AccessExclusiveLock` (acquired by `ALTER TABLE`, `DROP TABLE`, `TRUNCATE`, `VACUUM FULL`, `REINDEX`)

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             POSTGRESQL LOCK MANAGER WAIT QUEUE & FIFO HEAD-OF-LINE BLOCKING            │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Lock Tag: Relation 'orders' (OID 16402)                                                │
│                                                                                        │
│ Granted Locks:                                                                         │
│   Backend A (PID 101): AccessShareLock [SELECT count(*) FROM orders ...] (Slow: 45s)   │
│                                                                                        │
│ Wait Queue (FIFO Order):                                                               │
│   ┌──────────────────────────────────────────────────────────────────────────────────┐ │
│   │ 1. Backend B (PID 102): AccessExclusiveLock [ALTER TABLE orders ADD COLUMN ...]   │ │
│   │    Status: WAITING for Backend A (101) to release AccessShareLock                │ │
│   └────────────────────────────────────────┬─────────────────────────────────────────┘ │
│                                            │                                           │
│                 CRITICAL HEAD-OF-LINE BLOCKING QUEUE FENCE                             │
│                 (PostgreSQL prevents writer starvation!)                               │
│                                            ▼                                           │
│   ┌──────────────────────────────────────────────────────────────────────────────────┐ │
│   │ 2. Backend C (PID 103): AccessShareLock [SELECT * FROM orders WHERE id = $1]     │ │
│   │    Status: BLOCKED BY Backend B (102)! (Even though C does NOT conflict with A!) │ │
│   ├──────────────────────────────────────────────────────────────────────────────────┤ │
│   │ 3. Backend D (PID 104): AccessShareLock [SELECT * FROM orders WHERE id = $2]     │ │
│   │    Status: BLOCKED BY Backend B (102)!                                           │ │
│   ├──────────────────────────────────────────────────────────────────────────────────┤ │
│   │ ... + 450 Incoming Web Client Connections Queued Behind Backend B ...            │ │
│   │ Connection Pool Exhaustion -> HTTP 504 Gateway Timeout -> Total Cluster Outage!   │ │
│   └──────────────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│             RECURSIVE LOCK DEPENDENCY DIRECTED ACYCLIC GRAPH (DAG)                     │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│     ┌────────────────────────────────────────────────────────────────────────────┐     │
│     │ ROOT BLOCKER: PID 101 (state: 'idle in transaction', duration: 14m 22s)    │     │
│     │ Query: UPDATE accounts SET balance = balance - 100 WHERE id = 42;          │     │
│     │ (App leaked connection: waiting on external third-party HTTP gateway call) │     │
│     └──────────────────────┬───────────────────────────────┬─────────────────────┘     │
│                            │ blocks                        │ blocks                    │
│                            ▼                               ▼                           │
│     ┌──────────────────────────────────────┐  ┌──────────────────────────────────────┐ │
│     │ Intermediate: PID 102                │  │ Intermediate: PID 105                │ │
│     │ UPDATE accounts SET balance = ...    │  │ ALTER TABLE accounts ADD COLUMN ...  │ │
│     └──────────────┬───────────────────────┘  └──────────────┬───────────────────────┘ │
│                    │ blocks                                  │ blocks                  │
│                    ▼                                         ▼                         │
│     ┌──────────────────────────────────────┐  ┌──────────────────────────────────────┐ │
│     │ Waiting Victim: PID 103              │  │ 250 Incoming Reads: PID 106..355     │ │
│     │ SELECT * FROM accounts ...           │  │ SELECT * FROM accounts WHERE id = $1 │ │
│     └──────────────────────────────────────┘  └──────────────────────────────────────┘ │
│                                                                                        │
│ ❌ NAIVE AGENT ERROR: Agent kills PID 103 or 105 (victim/intermediate). Blocker 101   │
│    remains alive, and queue re-accumulates immediately!                                │
│ ✅ SURGICAL RECOVERY: Preempt Root PID 101 via pg_cancel_backend() / pg_terminate.     │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

When autonomous coding agents write transactional business logic, database migrations, or background consumers, LLMs routinely introduce 6 catastrophic locking flaws:

### The 6 Lock Tree & Head-of-Line Blocking Catastrophes

```sql
-- ❌ CATASTROPHIC LLM LOCKING ANTI-PATTERN 1: UN-TIMED DDL TRIGGERING FIFO LOCK CONVOYS
-- Autonomous agent generates a database migration to add a column:
ALTER TABLE orders ADD COLUMN tracking_code VARCHAR(64);
-- FAILURE MECHANISM:
-- 1. ALTER TABLE unconditionally requests AccessExclusiveLock on 'orders'.
-- 2. If a slow read query is running, ALTER TABLE blocks in the wait queue.
-- 3. PostgreSQL FIFO rules prevent subsequent SELECT queries (AccessShareLock) from
--    bypassing the waiting ALTER TABLE.
-- 4. Within 3 seconds, all 500 connections in PgBouncer wait on AccessExclusiveLock,
--    halting the entire production cluster.

-- ❌ CATASTROPHIC LLM LOCKING ANTI-PATTERN 2: LEAKED IDLE IN TRANSACTION CONNECTIONS
-- Application backend code performs an update and leaves the transaction open:
BEGIN;
UPDATE user_sessions SET last_active = NOW() WHERE session_id = 'sess_xyz';
-- Leaked transaction: Application executes an outbound HTTP RPC to payment vendor:
-- await fetch('https://api.payment.com/v1/charge'); -- Network timeout takes 60 seconds!
-- During this entire time, PID sits in state: 'idle in transaction', holding ExclusiveLock
-- on 'user_sessions' and row-level locks, blocking auth for all concurrent requests!

-- ❌ CATASTROPHIC LLM LOCKING ANTI-PATTERN 3: NAIVE VICTIM TERMINATION
-- Agent observes high connection count and blindly kills waiting backends:
SELECT pg_terminate_backend(pid) 
FROM pg_stat_activity 
WHERE wait_event_type = 'Lock';
-- DISASTER: Kills hundreds of innocent waiting web connections (victims), disconnecting
-- active client HTTP sockets, while the actual ROOT BLOCKER (which is NOT in wait_event_type
-- 'Lock' because it is actively computing or idle in transaction) remains 100% alive!
```

---

## 2. Mathematical Theorems, Queueing Models & Invariants

### Theorem 1: The Lock Convoy Queue Collapse Theorem ($M/M/c$ Under Head-of-Line Blocking)

Let an application connection pool possess $c$ database connections with incoming query arrival rate $\lambda$ (queries/second) and normal service rate $\mu$ (queries/second per connection), such that traffic intensity $\rho = \frac{\lambda}{c \cdot \mu} < 1$ (stable queue).

When a transaction requests an incompatible lock mode $M_{\text{req}}$ against a relation currently held by an active query of remaining duration $T_{\text{hold}}$, the Lock Manager places the request into the relation's FIFO wait queue:

$$\text{Queue}_{\text{wait}} = [P_{\text{req}}, \dots]$$

Under PostgreSQL's lock starvation prevention invariant, any subsequent incoming query $Q_i$ whose lock mode $M_i$ conflicts with $M_{\text{req}}$ is strictly enqueued behind $P_{\text{req}}$, even if $M_i$ does not conflict with currently granted locks:

$$\text{Conflict}(M_i, M_{\text{req}}) = \text{true} \implies Q_i \in \text{Queue}_{\text{wait}}$$

Because $M_{\text{req}} = \text{AccessExclusiveLock}$ conflicts with all 8 lock modes, the effective service rate for all queries accessing the relation collapses to:

$$\mu_{\text{effective}}(t) = 0 \quad \text{for } t \in [0, T_{\text{hold}}]$$

The rate of connection pool depletion is purely driven by arrival rate $\lambda$:

$$\frac{d N_{\text{blocked}}(t)}{dt} = \lambda$$

The time to total connection pool exhaustion $T_{\text{exhaust}}$ (where all $c$ connections are blocked, triggering cascading HTTP 504 timeouts) is mathematically bounded by:

$$T_{\text{exhaust}} = \frac{c - N_{\text{active}}}{\lambda}$$

**Numerical Proof**: If $c = 500$, active connections $N_{\text{active}} = 50$, and arrival rate $\lambda = 300\text{ req/sec}$, connection pool exhaustion occurs in:

$$T_{\text{exhaust}} = \frac{500 - 50}{300} = 1.50\text{ seconds}$$

Without transaction-scoped `lock_timeout`, a 10-second background analytical query blocks production within $1.5$ seconds.

---

### Theorem 2: Lock Dependency DAG & Root Blocker Isolation Calculus

Let database lock dependencies at any time $t$ be modeled as a directed graph $G = (V, E)$, where:
- Each vertex $v \in V$ represents an active PostgreSQL backend process (`pid`).
- Each directed edge $(u, v) \in E$ indicates that process $u$ is blocked by process $v$ (i.e., $v \in \text{pg\_blocking\_pids}(u)$).

$$\text{WaitEdge}(u, v) \iff u \text{ awaits lock granted to or queued ahead of } v$$

**Axiom 1 (Deadlock-Free Acyclicity)**: Except for transient cycles during the interval $[0, \text{deadlock\_timeout})$ before the deadlock detector executes, the graph $G$ is a Directed Acyclic Graph (DAG):

$$\text{Cycles}(G) = \emptyset$$

**Definition 1 (Root Blocker Set)**: A backend $v_{\text{root}} \in V$ is defined as a **Root Blocker** if and only if its out-degree in $G$ is zero (it is blocked by no other backend) and its in-degree is strictly positive (it blocks at least one other backend):

$$v_{\text{root}} \in V_{\text{root}} \iff d^+(v_{\text{root}}) = 0 \quad \land \quad d^-(v_{\text{root}}) > 0$$

Where $d^-(v) = |\{u \in V \mid (u, v) \in E\}|$ and $d^+(v) = |\{w \in V \mid (v, w) \in E\}|$.

**Definition 2 (Blast Radius / Transitive Downstream Impact)**: The total impact of a root blocker $v_{\text{root}}$ is the cardinality of its transitive reachability set in the reversed graph $G^R$:

$$\text{BlastRadius}(v_{\text{root}}) = |\text{Reach}(v_{\text{root}}, G^R)| = \left| \{ u \in V \mid u \rightsquigarrow v_{\text{root}} \} \right|$$

**Theorem**: Preempting any non-root intermediate vertex $v_{\text{intermediate}}$ (where $d^+(v) > 0$) fails to drain the lock convoy, because the parent root blocker $v_{\text{root}}$ continues holding the underlying lock, maintaining:

$$\mu_{\text{effective}} = 0$$

Preempting the unique root blocker $v_{\text{root}}$ restores the service rate of the entire subtree $\text{Reach}(v_{\text{root}}, G^R)$ in $O(1)$ operations:

$$\mu_{\text{restored}} = \sum_{u \in \text{Reach}(v_{\text{root}})} \mu_u$$

---

### Theorem 3: The Multi-Tier Timeout Ladder Inequality

To guarantee that no single backend can ever induce a connection pool collapse, all client applications and database configurations must strictly enforce the Multi-Tier Timeout Ladder Inequality:

$$T_{\text{lock\_timeout}} < T_{\text{statement\_timeout}} < T_{\text{transaction\_timeout}} < T_{\text{idle\_in\_transaction\_session\_timeout}}$$

| Timeout Level | Recommended Value | Enforcement Scope | Invariant Purpose |
| :--- | :--- | :--- | :--- |
| **`lock_timeout`** | `1,500ms – 3,000ms` | Transaction / DDL local | Fails fast before exhausting connection pool ($T_{\text{lock}} < T_{\text{exhaust}}$) |
| **`statement_timeout`** | `5,000ms – 15,000ms` | Session / API global | Prevents runaway table scans from holding shared locks |
| **`transaction_timeout`** | `30,000ms – 60,000ms` | PostgreSQL 17+ | Bounds total transaction lifespan across all operations |
| **`idle_in_transaction`** | `10,000ms – 30,000ms` | Server / User global | Automatically severs leaked ORM connections and network partitions |

---

## 3. The 5-Tier Lock Tree & Blocking Session Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               THE 5-TIER LOCK TREE & BLOCKING SESSION GOVERNANCE LADDER                │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Autonomous Telemetry, CI/CD DDL Linting & Machine-Verifiable DoD Gates         │
│         - Static analysis mandates 'SET LOCAL lock_timeout' on 100% of DDL migrations  │
│         - Automated eBPF / pg_stat_activity lock tree watchdog with PagerDuty alerts   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: idle_in_transaction Horizon Protection & Dynamic Session Fencing               │
│         - Global idle_in_transaction_session_timeout = '30s'                           │
│         - Connection pooler client disconnect detection (client_connection_check)      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Surgical Root Blocker Preemption Engine (pg_cancel vs pg_terminate)            │
│         - Recursive CTE traversal over pg_blocking_pids() identifying root blocker PIDs│
│         - Graceful pg_cancel_backend() first -> pg_terminate_backend() escalation      │
│         - STRICT ZERO-VICTIM KILL INVARIANT: Never terminate waiting processes         │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Recursive Lock Graph Traversal & DAG Topology Resolution                       │
│         - Real-time detection of chain depth D_chain >= 2 and blocked count N >= 5     │
│         - Root classification: active worker vs 'idle in transaction' ghost blocker    │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Non-Blocking Lock Acquisition & Multi-Tier Timeout Fencing                     │
│         - Transaction-scoped SET LOCAL lock_timeout = '2000ms' on all writes & DDL     │
│         - Explicit NOWAIT / SKIP LOCKED semantics for high-concurrency queue workers   │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Production TypeScript `AgenticLockTreeGuardEngine`

```typescript
// src/db/AgenticLockTreeGuardEngine.ts
/**
 * Production-Grade PostgreSQL Lock Tree & Root Blocker Preemption Guard Engine
 *
 * Implements recursive lock dependency graph traversal via pg_blocking_pids(),
 * detects lock convoys, calculates blast radius, and safely preempts root blockers
 * while protecting innocent waiting victims from accidental termination.
 */

export interface RawLockActivityRow {
  pid: number;
  usename: string;
  application_name: string;
  client_addr: string | null;
  state: string;
  wait_event_type: string | null;
  wait_event: string | null;
  query_duration_ms: number;
  state_duration_ms: number;
  blocking_pids: number[];
  current_query: string;
}

export interface LockTreeNode {
  pid: number;
  usename: string;
  applicationName: string;
  clientAddr: string | null;
  state: string;
  waitEventType: string | null;
  waitEvent: string | null;
  queryDurationMs: number;
  stateDurationMs: number;
  currentQuery: string;
  blockedPids: number[];
  depth: number;
  isRootBlocker: boolean;
  blastRadius: number; // Count of all downstream blocked processes
}

export interface LockTreeAnalysis {
  timestamp: string;
  hasConvoy: boolean;
  totalBlockedProcesses: number;
  rootBlockers: LockTreeNode[];
  maxChainDepth: number;
  recommendedAction: 'NO_ACTION' | 'CANCEL_ROOT_BLOCKER' | 'TERMINATE_ROOT_BLOCKER';
  actionTargetPid: number | null;
  actionReason: string | null;
}

export class AgenticLockTreeGuardEngine {
  private readonly convoyThresholdCount: number;
  private readonly convoyDurationThresholdMs: number;

  constructor(options?: {
    convoyThresholdCount?: number;
    convoyDurationThresholdMs?: number;
  }) {
    this.convoyThresholdCount = options?.convoyThresholdCount ?? 5;
    this.convoyDurationThresholdMs = options?.convoyDurationThresholdMs ?? 3000;
  }

  /**
   * Generates the SQL query for recursive lock graph extraction.
   * Leverages pg_blocking_pids() available in PostgreSQL 9.6+.
   */
  public static getLockTreeExtractionSQL(): string {
    return `
      WITH RECURSIVE activity AS (
        SELECT
          pid,
          usename,
          application_name,
          client_addr::text,
          state,
          wait_event_type,
          wait_event,
          ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - query_start)) * 1000)::bigint AS query_duration_ms,
          ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - state_change)) * 1000)::bigint AS state_duration_ms,
          pg_blocking_pids(pid) AS blocking_pids,
          query AS current_query
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND state IS NOT NULL
      )
      SELECT * FROM activity;
    `;
  }

  /**
   * Analyzes raw activity records to construct the dependency DAG and identify root blockers.
   */
  public analyzeLockTree(rows: RawLockActivityRow[]): LockTreeAnalysis {
    const nodeMap = new Map<number, LockTreeNode>();
    const blockedByMap = new Map<number, number[]>(); // Blocker PID -> List of Waiter PIDs

    // Step 1: Initialize nodes
    for (const row of rows) {
      nodeMap.set(row.pid, {
        pid: row.pid,
        usename: row.usename,
        applicationName: row.application_name,
        clientAddr: row.client_addr,
        state: row.state,
        waitEventType: row.wait_event_type,
        waitEvent: row.wait_event,
        queryDurationMs: Math.max(0, row.query_duration_ms || 0),
        stateDurationMs: Math.max(0, row.state_duration_ms || 0),
        currentQuery: row.current_query,
        blockedPids: [],
        depth: 0,
        isRootBlocker: false,
        blastRadius: 0,
      });

      // Track incoming edges
      for (const blockerPid of row.blocking_pids) {
        if (!blockedByMap.has(blockerPid)) {
          blockedByMap.set(blockerPid, []);
        }
        blockedByMap.get(blockerPid)!.push(row.pid);
      }
    }

    // Step 2: Populate downstream blocked lists
    for (const [blockerPid, waiters] of blockedByMap.entries()) {
      const blockerNode = nodeMap.get(blockerPid);
      if (blockerNode) {
        blockerNode.blockedPids = waiters;
      }
    }

    // Step 3: Identify Root Blockers
    // A root blocker has at least one waiter (d^- > 0), but is not blocked by anyone in the dataset (d^+ == 0)
    const rootBlockers: LockTreeNode[] = [];
    let totalBlockedProcesses = 0;

    for (const row of rows) {
      if (row.blocking_pids.length > 0) {
        totalBlockedProcesses++;
      }
    }

    for (const [pid, node] of nodeMap.entries()) {
      const isBlocked = rows.find(r => r.pid === pid)?.blocking_pids.length ?? 0;
      if (isBlocked === 0 && node.blockedPids.length > 0) {
        node.isRootBlocker = true;
        node.blastRadius = this.calculateBlastRadius(pid, nodeMap);
        rootBlockers.push(node);
      }
    }

    // Step 4: Sort root blockers by blast radius descending
    rootBlockers.sort((a, b) => b.blastRadius - a.blastRadius);

    // Calculate max depth across all trees
    let maxChainDepth = 0;
    for (const root of rootBlockers) {
      const depth = this.calculateMaxDepth(root.pid, nodeMap, new Set());
      if (depth > maxChainDepth) {
        maxChainDepth = depth;
      }
    }

    // Step 5: Evaluate Convoy Condition and Recommend Action
    const primaryRoot = rootBlockers[0];
    const hasConvoy =
      totalBlockedProcesses >= this.convoyThresholdCount ||
      (primaryRoot && primaryRoot.blastRadius >= this.convoyThresholdCount);

    let recommendedAction: 'NO_ACTION' | 'CANCEL_ROOT_BLOCKER' | 'TERMINATE_ROOT_BLOCKER' = 'NO_ACTION';
    let actionTargetPid: number | null = null;
    let actionReason: string | null = null;

    if (hasConvoy && primaryRoot) {
      actionTargetPid = primaryRoot.pid;

      if (primaryRoot.state === 'idle in transaction') {
        // Idle in transaction holding locks is an abandoned connection: escalate immediately
        recommendedAction = 'TERMINATE_ROOT_BLOCKER';
        actionReason = `Root blocker PID ${primaryRoot.pid} is 'idle in transaction' for ${primaryRoot.stateDurationMs}ms, blocking ${primaryRoot.blastRadius} transactions.`;
      } else if (primaryRoot.queryDurationMs > this.convoyDurationThresholdMs) {
        // Long-running active query blocking a convoy: start with graceful cancel
        recommendedAction = 'CANCEL_ROOT_BLOCKER';
        actionReason = `Root blocker PID ${primaryRoot.pid} active for ${primaryRoot.queryDurationMs}ms, holding locks blocking ${primaryRoot.blastRadius} downstream transactions.`;
      }
    }

    return {
      timestamp: new Date().toISOString(),
      hasConvoy,
      totalBlockedProcesses,
      rootBlockers,
      maxChainDepth,
      recommendedAction,
      actionTargetPid,
      actionReason,
    };
  }

  /**
   * Computes the transitive closure of all downstream blocked processes.
   */
  private calculateBlastRadius(rootPid: number, nodeMap: Map<number, LockTreeNode>): number {
    const visited = new Set<number>();
    const queue = [rootPid];

    while (queue.length > 0) {
      const currentPid = queue.shift()!;
      const node = nodeMap.get(currentPid);
      if (!node) continue;

      for (const waiterPid of node.blockedPids) {
        if (!visited.has(waiterPid)) {
          visited.add(waiterPid);
          queue.push(waiterPid);
        }
      }
    }

    return visited.size;
  }

  /**
   * Computes the maximum tree depth from a root blocker.
   */
  private calculateMaxDepth(
    currentPid: number,
    nodeMap: Map<number, LockTreeNode>,
    visited: Set<number>
  ): number {
    if (visited.has(currentPid)) return 0; // Prevent infinite cycle on transient deadlocks
    visited.add(currentPid);

    const node = nodeMap.get(currentPid);
    if (!node || node.blockedPids.length === 0) return 1;

    let maxChildDepth = 0;
    for (const childPid of node.blockedPids) {
      const depth = this.calculateMaxDepth(childPid, nodeMap, new Set(visited));
      if (depth > maxChildDepth) {
        maxChildDepth = depth;
      }
    }

    return 1 + maxChildDepth;
  }
}
```

---

## 5. Cross-Runtime Implementations

### Go (`jackc/pgx/v5`) Production Lock Tree Watchdog & Preemption Service

```go
package lockguard

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// BlockerInfo models the detected root blocker in a lock tree
type BlockerInfo struct {
	PID             int32     `json:"pid"`
	Username        string    `json:"username"`
	AppName         string    `json:"app_name"`
	State           string    `json:"state"`
	QueryDurationMs int64     `json:"query_duration_ms"`
	StateDurationMs int64     `json:"state_duration_ms"`
	BlastRadius     int       `json:"blast_radius"`
	CurrentQuery    string    `json:"current_query"`
}

// LockTreeWatchdog runs continuously to detect and remediate lock convoys
type LockTreeWatchdog struct {
	pool              *pgxpool.Pool
	logger            *slog.Logger
	convoyThreshold   int
	durationThreshold time.Duration
}

func NewLockTreeWatchdog(pool *pgxpool.Pool, logger *slog.Logger, convoyThreshold int, durationThreshold time.Duration) *LockTreeWatchdog {
	return &LockTreeWatchdog{
		pool:              pool,
		logger:            logger,
		convoyThreshold:   convoyThreshold,
		durationThreshold: durationThreshold,
	}
}

// FindAndPreemptRootBlocker scans for lock convoys and surgically preempts only the root blocker
func (w *LockTreeWatchdog) FindAndPreemptRootBlocker(ctx context.Context) (*BlockerInfo, error) {
	// Recursive CTE to locate root blocker with maximum downstream blocked victims
	query := `
		WITH RECURSIVE lock_tree AS (
			SELECT
				pid,
				usename,
				application_name,
				state,
				ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - query_start)) * 1000)::bigint AS query_duration_ms,
				ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - state_change)) * 1000)::bigint AS state_duration_ms,
				pg_blocking_pids(pid) AS blocking_pids,
				query
			FROM pg_stat_activity
			WHERE pid <> pg_backend_pid()
				AND state IS NOT NULL
		),
		root_candidates AS (
			SELECT
				lt.pid,
				lt.usename,
				lt.application_name,
				lt.state,
				lt.query_duration_ms,
				lt.state_duration_ms,
				lt.query,
				(
					SELECT COUNT(*)
					FROM lock_tree child
					WHERE lt.pid = ANY(child.blocking_pids)
				) AS direct_waiters
			FROM lock_tree lt
			WHERE cardinality(lt.blocking_pids) = 0
		)
		SELECT
			pid,
			usename,
			application_name,
			state,
			query_duration_ms,
			state_duration_ms,
			direct_waiters,
			query
		FROM root_candidates
		WHERE direct_waiters >= $1
		ORDER BY direct_waiters DESC, state_duration_ms DESC
		LIMIT 1;
	`

	var blocker BlockerInfo
	var directWaiters int

	err := w.pool.QueryRow(ctx, query, w.convoyThreshold).Scan(
		&blocker.PID,
		&blocker.Username,
		&blocker.AppName,
		&blocker.State,
		&blocker.QueryDurationMs,
		&blocker.StateDurationMs,
		&directWaiters,
		&blocker.CurrentQuery,
	)

	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil // No lock convoy detected
		}
		return nil, fmt.Errorf("failed to query lock tree: %w", err)
	}

	blocker.BlastRadius = directWaiters
	w.logger.WarnContext(ctx, "CRITICAL: Lock convoy detected. Root blocker identified",
		"root_pid", blocker.PID,
		"state", blocker.State,
		"blast_radius", blocker.BlastRadius,
		"state_duration_ms", blocker.StateDurationMs,
		"query", blocker.CurrentQuery,
	)

	// Surgical Preemption Ladder:
	// If 'idle in transaction', pg_cancel_backend does nothing because no query is running.
	// We must issue pg_terminate_backend to close the leaked transaction socket.
	if blocker.State == "idle in transaction" {
		w.logger.InfoContext(ctx, "Severing leaked idle-in-transaction connection", "pid", blocker.PID)
		var terminated bool
		err = w.pool.QueryRow(ctx, "SELECT pg_terminate_backend($1)", blocker.PID).Scan(&terminated)
		if err != nil {
			return &blocker, fmt.Errorf("failed to terminate idle root blocker %d: %w", blocker.PID, err)
		}
		return &blocker, nil
	}

	// For active queries, attempt graceful query cancellation first (SIGINT)
	w.logger.InfoContext(ctx, "Attempting graceful query cancellation on root blocker", "pid", blocker.PID)
	var cancelled bool
	err = w.pool.QueryRow(ctx, "SELECT pg_cancel_backend($1)", blocker.PID).Scan(&cancelled)
	if err != nil {
		return &blocker, fmt.Errorf("failed to cancel root blocker %d: %w", blocker.PID, err)
	}

	return &blocker, nil
}
```

---

### TypeScript (`Kysely`) Timeout-Hardened DDL & Migration Helper

```typescript
// src/db/migrations/migrationRunner.ts
import { Kysely, sql } from 'kysely';

export interface ResilientMigrationOptions {
  lockTimeoutMs?: number;
  statementTimeoutMs?: number;
  maxAttempts?: number;
  backoffBaseMs?: number;
}

/**
 * Executes high-risk DDL statements under a strict timeout ladder with exponential backoff.
 * Prevents DDL statements from anchoring FIFO lock convoys when blocked by long reads.
 */
export async function executeWithLockTimeout<DB, T>(
  db: Kysely<DB>,
  migrationName: string,
  operation: (trx: Kysely<DB>) => Promise<T>,
  options?: ResilientMigrationOptions
): Promise<T> {
  const lockTimeout = options?.lockTimeoutMs ?? 2000;
  const stmtTimeout = options?.statementTimeoutMs ?? 5000;
  const maxAttempts = options?.maxAttempts ?? 5;
  const backoffBase = options?.backoffBaseMs ?? 1000;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await db.transaction().execute(async (trx) => {
        // CRITICAL INVARIANT: Bound lock acquisition wait time to prevent queue convoy
        await sql`SET LOCAL lock_timeout = ${sql.raw(`'${lockTimeout}ms'`)};`.execute(trx);
        await sql`SET LOCAL statement_timeout = ${sql.raw(`'${stmtTimeout}ms'`)};`.execute(trx);

        return await operation(trx);
      });
    } catch (err: any) {
      // PostgreSQL error code 55P03 is lock_not_available
      const isLockTimeout = err?.code === '55P03' || err?.message?.includes('lock timeout');

      if (isLockTimeout && attempt < maxAttempts) {
        const jitter = Math.floor(Math.random() * 500);
        const sleepMs = backoffBase * Math.pow(2, attempt - 1) + jitter;

        console.warn(
          `[Migration:${migrationName}] Lock timeout (55P03) on attempt ${attempt}/${maxAttempts}. ` +
          `Failed fast to protect connection pool. Backing off for ${sleepMs}ms before retry...`
        );

        await new Promise((resolve) => setTimeout(resolve, sleepMs));
        continue;
      }

      throw err;
    }
  }

  throw new Error(`[Migration:${migrationName}] Exhausted all ${maxAttempts} attempts under lock_timeout.`);
}
```

---

### Python (`asyncpg`) Lock Tree & Blocker Preemption Sentinel

```python
# app/storage/lock_guard.py
import asyncio
import logging
from typing import Optional, Dict, Any
import asyncpg

logger = logging.getLogger("db.lock_guard")

class AsyncLockGuardSentinel:
    def __init__(self, pool: asyncpg.Pool, convoy_threshold: int = 5, duration_threshold_s: float = 3.0):
        self.pool = pool
        self.convoy_threshold = convoy_threshold
        self.duration_threshold_s = duration_threshold_s

    async def inspect_and_remediate(self) -> Optional[Dict[str, Any]]:
        """
        Scans for lock convoys. If detected, surgically terminates or cancels
        ONLY the root blocker. Zero waiting victims are touched.
        """
        query = """
            WITH RECURSIVE lock_activity AS (
                SELECT
                    pid,
                    usename,
                    application_name,
                    state,
                    ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - query_start)) * 1000)::bigint AS query_duration_ms,
                    ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - state_change)) * 1000)::bigint AS state_duration_ms,
                    pg_blocking_pids(pid) AS blocking_pids,
                    query
                FROM pg_stat_activity
                WHERE pid <> pg_backend_pid() AND state IS NOT NULL
            ),
            root_candidates AS (
                SELECT
                    lt.*,
                    (SELECT COUNT(*) FROM lock_activity c WHERE lt.pid = ANY(c.blocking_pids)) AS blocked_count
                FROM lock_activity lt
                WHERE cardinality(lt.blocking_pids) = 0
            )
            SELECT * FROM root_candidates
            WHERE blocked_count >= $1
            ORDER BY blocked_count DESC, state_duration_ms DESC
            LIMIT 1;
        """
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(query, self.convoy_threshold)
            if not row:
                return None

            root_pid = row["pid"]
            state = row["state"]
            blocked_count = row["blocked_count"]
            query_text = row["query"]

            logger.warning(
                f"LOCK CONVOY DETECTED: Root Blocker PID={root_pid}, State='{state}', "
                f"Blocked Victims={blocked_count}, Query='{query_text[:120]}'"
            )

            # Surgical remediation: sever idle connection or cancel active query
            if state == "idle in transaction":
                logger.info(f"Terminating leaked idle-in-transaction root blocker PID={root_pid}")
                await conn.execute("SELECT pg_terminate_backend($1)", root_pid)
                action = "TERMINATED"
            else:
                logger.info(f"Cancelling runaway query on root blocker PID={root_pid}")
                await conn.execute("SELECT pg_cancel_backend($1)", root_pid)
                action = "CANCELLED"

            return {
                "root_pid": root_pid,
                "action": action,
                "state": state,
                "blocked_count": blocked_count,
            }
```

---

### Rust (`sqlx`) Async Lock Tree Audit Sentinel

```rust
// src/db/lock_sentinel.rs
use sqlx::{PgPool, Row};
use std::time::Duration;
use tracing::{error, info, warn};

#[derive(Debug)]
pub struct RootBlockerSummary {
    pub pid: i32,
    pub username: String,
    pub state: String,
    pub blocked_count: i64,
    pub state_duration_ms: i64,
    pub query: String,
}

pub struct LockSentinel {
    pool: PgPool,
    convoy_limit: i64,
}

impl LockSentinel {
    pub fn new(pool: PgPool, convoy_limit: i64) -> Self {
        Self { pool, convoy_limit }
    }

    pub async fn audit_and_remediate(&self) -> Result<Option<RootBlockerSummary>, sqlx::Error> {
        let sql = r#"
            WITH RECURSIVE activity AS (
                SELECT
                    pid,
                    usename,
                    state,
                    ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - query_start)) * 1000)::bigint AS query_duration_ms,
                    ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - state_change)) * 1000)::bigint AS state_duration_ms,
                    pg_blocking_pids(pid) AS blocking_pids,
                    query
                FROM pg_stat_activity
                WHERE pid <> pg_backend_pid() AND state IS NOT NULL
            ),
            roots AS (
                SELECT
                    a.*,
                    (SELECT COUNT(*) FROM activity c WHERE a.pid = ANY(c.blocking_pids)) AS blocked_count
                FROM activity a
                WHERE cardinality(a.blocking_pids) = 0
            )
            SELECT pid, usename, state, blocked_count, state_duration_ms, query
            FROM roots
            WHERE blocked_count >= $1
            ORDER BY blocked_count DESC
            LIMIT 1;
        "#;

        let row = sqlx::query(sql)
            .bind(self.convoy_limit)
            .fetch_optional(&self.pool)
            .await?;

        if let Some(r) = row {
            let pid: i32 = r.get("pid");
            let state: String = r.get("state");
            let blocked_count: i64 = r.get("blocked_count");
            let state_duration_ms: i64 = r.get("state_duration_ms");
            let query: String = r.get("query");
            let username: String = r.get("usename");

            warn!(
                root_pid = pid,
                blocked_victims = blocked_count,
                state = %state,
                "LOCK CONVOY DETECTED: Preempting root blocker"
            );

            if state == "idle in transaction" {
                sqlx::query("SELECT pg_terminate_backend($1)")
                    .bind(pid)
                    .execute(&self.pool)
                    .await?;
                info!(root_pid = pid, "Terminated idle root blocker connection");
            } else {
                sqlx::query("SELECT pg_cancel_backend($1)")
                    .bind(pid)
                    .execute(&self.pool)
                    .await?;
                info!(root_pid = pid, "Cancelled active query on root blocker");
            }

            return Ok(Some(RootBlockerSummary {
                pid,
                username,
                state,
                blocked_count,
                state_duration_ms,
                query,
            }));
        }

        Ok(None)
    }
}
```

---

## 6. The 6-State Lock Lifecycle Finite-State Machine (FSM)

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             THE 6-STATE LOCK LIFECYCLE FINITE-STATE MACHINE (FSM)                      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│   ┌────────────────────┐     lock_timeout configured      ┌───────────────────────┐   │
│   │                    │ ───────────────────────────────► │                       │   │
│   │   [1] IDLE / INIT  │                                  │  [2] LOCK_ACQUISITION │   │
│   │                    │ ◄─────────────────────────────── │                       │   │
│   └────────────────────┘      Timeout (55P03) Fail-Fast   └───────────┬───────────┘   │
│                                                                       │ Lock Granted  │
│                                                                       ▼               │
│   ┌────────────────────┐   Waiters >= Convoy Threshold    ┌───────────────────────┐   │
│   │                    │ ◄─────────────────────────────── │                       │   │
│   │ [4] CONVOY_DETECTED│                                  │   [3] TRANSACTION_HELD│   │
│   │                    │ ───────────────────────────────► │                       │   │
│   └─────────┬──────────┘   Root Preempted / Drained       └───────────┬───────────┘   │
│             │                                                         │ Commit / Abort│
│             ▼                                                         ▼               │
│   ┌────────────────────┐                                  ┌───────────────────────┐   │
│   │                    │      Zero Victims Terminated     │                       │   │
│   │ [5] ROOT_PREEMPTION│ ───────────────────────────────► │     [6] RECOVERED     │   │
│   │                    │                                  │                       │   │
│   └────────────────────┘                                  └───────────────────────┘   │
│                                                                                        │
│   * State 1 (IDLE): Connection clean, timeout ladder configured prior to DDL/write.   │
│   * State 2 (LOCK_ACQUISITION): Waiting for relation lock under lock_timeout.         │
│   * State 3 (TRANSACTION_HELD): Locks held. Monitored for idle_in_transaction.        │
│   * State 4 (CONVOY_DETECTED): Wait queue depth >= threshold. DAG built.              │
│   * State 5 (ROOT_PREEMPTION): Recursive pg_blocking_pids() finds root PID;           │
│     surgical pg_cancel_backend() or pg_terminate_backend() executed.                   │
│   * State 6 (RECOVERED): Waiters unblocked, lock queue drained, service rate restored.│
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates & Static Analysis Rules

| DoD Gate Number | Validation Category | Verification Method & Static Rule | Mandatory Pass Criteria |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **DDL Lock Timeout Fencing** | AST Regex check on all migration `.sql` and `.ts` files | 100% of migrations contain `SET LOCAL lock_timeout` or `lockTimeoutMs` |
| **Gate 2** | **Idle-In-Transaction Configuration** | PostgreSQL cluster config validation (`postgresql.conf`) | `idle_in_transaction_session_timeout <= 30000ms` |
| **Gate 3** | **Zero-Victim Kill Enforcement** | Code review AST scan on remediation scripts | Strictly bans `pg_terminate_backend` where `wait_event_type = 'Lock'` |
| **Gate 4** | **Recursive Lock Tree Inspection** | Integration test executing recursive `pg_blocking_pids()` query | Query resolves root blocker PID within $\le 50\text{ms}$ |
| **Gate 5** | **Preemption Grace Escalation** | Unit test on `AgenticLockTreeGuardEngine` | Recommends `pg_cancel_backend` for active query, `pg_terminate` for idle |
| **Gate 6** | **Pool Headroom Invariance** | Chaos monkey injection test under synthetic lock convoy | Zero pool starvation: lock timeout aborts blocker before pool exhausts |

