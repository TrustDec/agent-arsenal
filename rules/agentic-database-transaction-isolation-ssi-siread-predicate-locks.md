---
description: Database transaction isolation levels, PostgreSQL Serializable Snapshot Isolation (SSI), SIREAD predicate lock escalation defense, write skew elimination, SQLSTATE 40001 resilient retry loops, and SERIALIZABLE READ ONLY DEFERRABLE across Go (pgx/v5), TypeScript (Drizzle/Kysely/pg), Python (psycopg3), Rust (sqlx), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{isolation,transaction,serializable,ssi,predicate,lock,tx,retry,concurrency,ledger,financial}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/src/services/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/internal/repository/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Transaction Isolation Levels, Serializable Snapshot Isolation (SSI), SIREAD Predicate Locks & Serialization Anomaly Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to architect financial ledgers, multi-row inventory allocations, billing reconciliations, scheduling reservations, shift rosters, or mission-critical state machines across PostgreSQL, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `pg`), Python (`psycopg3`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Read Committed Read Skew & Inconsistent Multi-Statement Snapshot Mirage" (where autonomous agents execute multiple `SELECT` statements within a single transaction under the default `READ COMMITTED` isolation level, reading inconsistent data states mutated by concurrent commits between statements and executing branching logic on corrupted snapshots), the "Repeatable Read Write Skew & Dual-Constraint Invalidation Trap" (where agents assume Snapshot Isolation prevents all race conditions, only for concurrent transactions modifying disjoint rows—such as the classic Doctor-on-Call, double-spending balances, or meeting room allocations—to cleanly commit and invalidate cross-row business invariants), the "SSI Predicate Lock Escalation & False-Conflict Abort Cascade" (where unindexed range scans or broad predicates under `SERIALIZABLE` exhaust `max_pred_locks_per_transaction`, silently escalating SIREAD locks from tuple to page to relation level and triggering a storm of spurious `40001 serialization_failure` aborts across completely unrelated tables), the "Missing Idempotent Retry Harness & SQLSTATE 40001 Unhandled Crash Storm" (where agents deploy serializable transactions without a resilient exponential jitter retry loop, treating intentional SSI collision aborts as fatal 500 internal server errors), the "Blocking Long-Running Analytical Query & Read-Write Conflict Horizon" (where background reports or AI context scrapers running under serializable isolation register SIREAD locks that force concurrent OLTP writers to abort, failing to use `SERIALIZABLE READ ONLY DEFERRABLE`), and the "Cross-Database Isolation Level Semantic Mismatch" (where agents migrate logic between PostgreSQL SSI, MySQL InnoDB Gap Locking, and SQLite WAL single-writer modes, inducing hidden write skews or deadlock spasms) by establishing a strict 5-Tier Isolation & SSI Governance Ladder, SIREAD predicate lock memory sizing, resilient decorrelated jitter retry wrappers, and machine-verifiable CI test gates.

---

## 1. Architectural Taxonomy: The 6 Isolation Catastrophes vs The 5-Tier Isolation & SSI Governance Ladder

Modern relational database engines offer four standard ANSI SQL isolation levels: `READ UNCOMMITTED`, `READ COMMITTED`, `REPEATABLE READ`, and `SERIALIZABLE`. However, standard ANSI SQL definitions date back to 1992 and fail to capture modern multi-version concurrency control (MVCC) phenomena such as **Snapshot Isolation (SI)**, **Write Skew**, and **Serializable Snapshot Isolation (SSI)**.

Autonomous coding agents routinely make catastrophic assumptions: they either assume the default `READ COMMITTED` ensures a consistent view throughout an entire transaction, or assume `REPEATABLE READ` eliminates all race conditions, or naively enable `SERIALIZABLE` without realizing that serialization failures (`SQLSTATE 40001`) are an expected operational mechanism requiring mandatory application-level retry loops:

```typescript
// ❌ CATASTROPHIC LLM TRANSACTION ISOLATION ANTI-PATTERNS

// 1. The Read Committed Read Skew Mirage!
// Default isolation is READ COMMITTED. Each query sees a DIFFERENT snapshot!
await db.transaction(async (tx) => {
  const accountA = await tx.query('SELECT balance FROM accounts WHERE id = $1', ['A']);
  // Concurrent transaction commits: transfers $500 from B to A right here!
  const accountB = await tx.query('SELECT balance FROM accounts WHERE id = $1', ['B']);
  
  // Total balance calculation is completely invalid and out-of-sync!
  const total = accountA.balance + accountB.balance; // ❌ Read Skew: saw A before transfer, B after transfer!
});

// 2. The Repeatable Read Write Skew Trap!
// Agent thinks REPEATABLE READ prevents races. But Snapshot Isolation permits Write Skew!
// Doctor-on-call policy: At least 1 doctor must remain active.
await db.transaction({ isolationLevel: 'repeatable read' }, async (tx) => {
  const activeCount = await tx.query('SELECT count(*) FROM doctors WHERE on_call = true');
  if (activeCount > 1) {
    // Both Doctor Alice and Doctor Bob execute this concurrently.
    // Both read activeCount = 2!
    // Alice updates her row; Bob updates his row.
    // Disjoint rows mutated -> Both COMMIT cleanly under REPEATABLE READ!
    await tx.query('UPDATE doctors SET on_call = false WHERE id = $1', [doctorId]);
    // ❌ INVARIANT VIOLATED: ZERO DOCTORS REMAIN ON CALL!
  }
});

// 3. The Unhandled 40001 Serialization Crash Storm!
// Agent switches to SERIALIZABLE to prevent write skew, but lacks a retry loop!
// In SSI, PostgreSQL aborts one transaction when dependency cycles (rw-antidependencies) occur.
await db.transaction({ isolationLevel: 'serializable' }, async (tx) => {
  // ❌ When concurrent transactions touch related predicate sets,
  // PostgreSQL throws error: "could not serialize access due to read/write dependencies among transactions (SQLSTATE 40001)"
  // Unhandled exception -> 500 Internal Server Error returned to customer!
});
```

### The 6 Catastrophes of Autonomous Isolation Architectures

1. **The Read Committed Read Skew & Inconsistent Multi-Statement Snapshot Mirage**:
   In PostgreSQL, the default isolation level is `READ COMMITTED`. In this mode, **each statement inside a transaction obtains a fresh snapshot of the database**, taken at the moment that specific statement begins executing. If a transaction executes `SELECT balance FROM accounts WHERE id = 'A'`, pauses or executes business logic, and then executes `SELECT balance FROM accounts WHERE id = 'B'`, any concurrent transaction that committed changes to either account in the interim will be visible to the second query but not the first. Autonomous agents frequently construct multi-step ledger calculations, audit trails, and financial allocations across multiple `SELECT` statements under default isolation, producing corrupted financial calculations, negative balances, and non-deterministic decision branching.

2. **The Repeatable Read Write Skew & Dual-Constraint Invalidation Trap**:
   In PostgreSQL, `REPEATABLE READ` is implemented via **Snapshot Isolation (SI)**. All statements within the transaction see the exact same snapshot, established at the start of the first non-transaction-control statement. While `REPEATABLE READ` prevents dirty reads, non-repeatable reads, and phantom reads, it **does not prevent Write Skew**. Write skew occurs when two concurrent transactions read overlapping data sets, determine that business invariants hold, and subsequently make non-overlapping updates to different rows that together violate the cross-row invariant. Classic examples include:
   - **Doctor on Call**: Hospital invariant requires $\ge 1$ doctor on duty. Alice and Bob both read active count $= 2$, and both go off duty on disjoint rows.
   - **Dual-Account Overdraft Protection**: Invariant requires Account $A + \text{Account } B \ge 0$. Transaction 1 debits $A$ based on total balance; Transaction 2 debits $B$ concurrently. Both commit; total balance becomes deeply negative.
   - **Non-Overlapping Room Bookings Without GiST Constraints**: Transaction 1 books Room 101 from 10:00 to 11:00; Transaction 2 books Room 101 from 10:30 to 11:30.
   Under `REPEATABLE READ`, neither transaction modifies a row that the other modified, so MVCC first-committer-wins conflicts are never triggered. Both transactions commit, corrupting enterprise state.

3. **The SSI Predicate Lock Escalation & False-Conflict Abort Cascade**:
   PostgreSQL achieves true `SERIALIZABLE` isolation without heavyweight Two-Phase Locking (2PL) through **Serializable Snapshot Isolation (SSI)**. SSI tracks read-write dependencies by recording non-blocking **SIREAD predicate locks** in shared memory. SIREAD locks do not block writers or readers; they exist solely as invisible flags to detect cycles in the Serialization Dependency Graph ($rw$-antidependency cycles: $T_1 \xrightarrow{rw} T_2 \xrightarrow{rw} T_1$).
   However, shared memory for predicate locks is finite, governed by `max_pred_locks_per_transaction`, `max_pred_locks_per_relation`, and `max_pred_locks_per_page`. If an agent issues an unindexed query or scans thousands of rows, tuple-level SIREAD locks quickly exceed `max_pred_locks_per_page` (default 2), escalating to page-level locks. If multiple pages are locked, locks escalate to the **relation level**. Once a relation-level SIREAD lock is granted, **any write to any row in the entire table by another concurrent serializable transaction creates a dangerous dependency**, triggering an avalanche of spurious `40001 serialization_failure` aborts for completely disjoint records.

4. **The Missing Idempotent Retry Harness & SQLSTATE 40001 Unhandled Crash Storm**:
   Under `SERIALIZABLE` isolation, serialization failures (`SQLSTATE 40001: could not serialize access due to read/write dependencies among transactions`) are **not software bugs or system anomalies—they are the normal, mathematical mechanism by which the database enforces serial consistency**. PostgreSQL guarantees that if a transaction aborts with `40001`, rolling back and re-executing the transaction from the beginning will succeed once concurrent transactions commit. Autonomous agents almost invariably write transaction handlers with single-attempt execution. When deployed to production, peak traffic triggers hundreds of `40001` exceptions per minute, collapsing user workflows, producing 500 errors, and prompting developers to wrongly conclude that PostgreSQL Serializable mode is "broken" or "too slow."

5. **The Blocking Long-Running Analytical Query & Read-Write Conflict Horizon**:
   When developers need a fully consistent point-in-time snapshot for a complex analytical report, dashboard aggregation, or LLM context prompt compilation, agents wrap the query in `BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE`. However, a standard serializable read-only query registers SIREAD locks across all tables and rows it reads. If concurrent OLTP transactions perform high-frequency updates on those tables, PostgreSQL SSI detects inbound and outbound $rw$-antidependencies and may abort the concurrent OLTP update transactions to protect the serializability of the analytical query!
   PostgreSQL provides a dedicated, mathematically proven solution: **`SERIALIZABLE READ ONLY DEFERRABLE`**. When declared deferrable, the transaction waits before running its first query until it can obtain a snapshot that is guaranteed to be free of any serialization conflicts. Once it starts, it registers **zero SIREAD locks**, can **never abort** due to serialization failure, and **can never cause concurrent writing transactions to abort**. Omission of `DEFERRABLE` for analytical reads cripples production throughput.

6. **The Cross-Database Isolation Level Semantic Mismatch**:
   Autonomous agents trained on varied SQL dialects conflate MySQL InnoDB, PostgreSQL, and SQLite isolation semantics:
   - In **MySQL InnoDB**, `REPEATABLE READ` uses pessimistic **Next-Key Locking** (index-record locks + gap locks) on reads executed with `FOR UPDATE` or `LOCK IN SHARE MODE`. This prevents phantom rows and write skew on indexed predicates, but introduces frequent AB-BA deadlocks (`SQLSTATE 40P01` / error `1213`).
   - In **PostgreSQL**, `REPEATABLE READ` is purely optimistic MVCC Snapshot Isolation with zero gap locking. It never deadlocks on reads, but allows Write Skew.
   - In **SQLite**, write transactions are serialized at the database file level using a single-writer lock in WAL mode; transactions are serializable by default, but concurrent write attempts return `SQLITE_BUSY` requiring busy handler retry tuning.
   When agents migrate code across engines without adjusting concurrency primitives, subtle data corruption or unexpected locking stalls inevitably occur.

---

## 2. The 5-Tier Transaction Isolation & SSI Governance Ladder

Every enterprise application relying on multi-row database transactions must enforce this 5-Tier governance hierarchy:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Tier 4: Zero-Conflict Analytical Snapshots (READ ONLY DEFERRABLE)       │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Predicate Lock Memory Sizing & Splay B-Tree Indexing            │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Resilient Exponential Jitter Retry Harness for SQLSTATE 40001   │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Write Skew Defense via True Serializable or Exclusion Invariants│
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Explicit Isolation Declarations & Read Skew Elimination         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Tier 0: Explicit Isolation Declarations & Read Skew Elimination
- **Zero Implicit Isolation Level Defaults in Multi-Statement Workflows**:
  Never rely on database connection defaults (`READ COMMITTED`) when executing multi-step business logic, financial allocations, or state transitions spanning multiple queries.
- **Explicit Transaction Boundary Declaration**:
  Every transaction must explicitly declare its isolation level at transaction initialization:
  ```sql
  BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
  -- or
  BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
  ```
- **Single-Snapshot Invariance**:
  If business logic reads multiple tables or performs multiple queries that must see a mutually consistent state, the transaction MUST execute at least under `REPEATABLE READ` (or `SERIALIZABLE`). This guarantees that statement $N$ sees the identical database snapshot as statement 1, completely eliminating Read Skew.

### Tier 1: Write Skew Defense via True Serializable or Declarative Exclusion
- **Cross-Row Invariant Defense**:
  Whenever business logic enforces a condition across multiple rows (e.g., "sum of balances $\ge 0$", "count of active shifts $\ge 1$", "no overlapping time ranges for resource $X$"), standard `REPEATABLE READ` is **strictly prohibited**.
- **Dual Defense Mechanisms**:
  1. **PostgreSQL Serializable Snapshot Isolation (SSI)**:
     Use `ISOLATION LEVEL SERIALIZABLE` with an automated retry loop. PostgreSQL's SSI kernel will detect $rw$-antidependency cycles and abort the conflicting transaction before write skew can commit.
  2. **Declarative Exclusion Constraints (`EXCLUDE USING gist`)**:
     For temporal, spatial, or multi-attribute non-overlapping invariants, prefer engine-level exclusion constraints (via `btree_gist`). Exclusion constraints enforce serializability at the storage level with zero SSI overhead and immediate conflict prevention (`SQLSTATE 23P01`).

### Tier 2: Resilient Exponential Jitter Retry Harness for SQLSTATE 40001
- **Mandatory Retry Wrapper for All Serializable Transactions**:
  Every code path executing inside a `SERIALIZABLE` transaction MUST be enclosed in a resilient execution wrapper.
- **Error Classification**:
  Catch transient serialization errors:
  - `SQLSTATE 40001: serialization_failure`
  - `SQLSTATE 40P01: deadlock_detected`
- **Full Decorrelated Jitter Algorithm**:
  Do not retry immediately or with fixed intervals (which causes thundering herds of competing re-executions). Compute backoff with full decorrelated jitter:
  $$\tau_k = \text{Uniform}(0, \min(T_{\max}, T_{\text{base}} \cdot 2^k))$$
- **Transaction Idempotency Invariant**:
  The closure executed within the retry wrapper MUST be strictly idempotent. It must contain zero non-idempotent side effects (e.g., no external credit card charges, no emails, no non-idempotent third-party API calls). All external side effects must be deferred until AFTER the transaction has successfully committed, using the Transactional Outbox pattern.

### Tier 3: Predicate Lock Memory Sizing & Splay B-Tree Indexing
- **Preventing SIREAD Lock Escalation**:
  To prevent tuple-level SIREAD locks from escalating to page or relation locks:
  1. **Index Coverage**: Every query executed within a serializable transaction MUST have an index covering the `WHERE` clause filter. An unindexed query performs a sequential table scan, which immediately acquires a relation-level SIREAD lock, poisoning the entire table for all concurrent writers.
  2. **Selective Range Bounds**: Always bound range queries with tight indexed lower and upper bounds (`WHERE created_at >= $1 AND created_at < $2`).
- **PostgreSQL Configuration Sizing (`postgresql.conf`)**:
  Tune predicate lock memory pools according to workload concurrency:
  - `max_pred_locks_per_transaction = 256` (default 64)
  - `max_pred_locks_per_relation = -2` (scales with max_pred_locks_per_transaction)
  - `max_pred_locks_per_page = 2` (default 2)

### Tier 4: Zero-Conflict Analytical Snapshots with `SERIALIZABLE READ ONLY DEFERRABLE`
- **Analytical & Reporting Queries**:
  When extracting large point-in-time consistent datasets for reporting, data warehousing, or AI model context compilation:
  ```sql
  BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE;
  ```
- **The Deferrable Invariant**:
  - The transaction may pause briefly before its first query while PostgreSQL identifies a clean historical snapshot.
  - Once started, it will **never abort with a 40001 serialization failure**.
  - It tracks **zero SIREAD predicate locks**, completely eliminating the risk of causing concurrent OLTP write transactions to abort.

---

## 3. Mathematical & Theoretical Formal Foundations

### 1. The Serialization Dependency Graph (SDG) & $rw$-Antidependencies

In Serializable Snapshot Isolation (Cahill et al., 2008), the database tracks transactional dependencies using a directed Serialization Dependency Graph $G = (V, E)$, where vertices $V$ are transactions and edges $E$ represent dependencies:
- **$T_1 \xrightarrow{ww} T_2$ (Write-Write Dependency)**: $T_1$ writes a version of a tuple, and $T_2$ overwrites it.
- **$T_1 \xrightarrow{wr} T_2$ (Write-Read Dependency)**: $T_1$ writes a version of a tuple, and $T_2$ reads that version.
- **$T_1 \xrightarrow{rw} T_2$ (Read-Write Anti-Dependency)**: $T_1$ reads a version of a tuple, and concurrent transaction $T_2$ writes a newer version of that tuple (or a tuple matching $T_1$'s predicate).

**Theorem (Serializable Consistency via Cycle Elimination)**:
A concurrent execution history $H$ is equivalent to a serial execution history if and only if the Serialization Dependency Graph $G$ contains **no directed cycles**:
$$\text{Serializability}(H) \iff \text{Cycles}(G) = \emptyset$$

In Snapshot Isolation (SI), $ww$ and $wr$ edges are constrained by MVCC write locks and snapshot timestamps, but $rw$-antidependency edges can form cycles without row-level write conflicts.

**SSI Detection Rule (Dangerous Structure Theorem)**:
SSI proves that any non-serializable execution anomaly in Snapshot Isolation requires at least two consecutive $rw$-antidependency edges in a directed cycle:
$$T_0 \xrightarrow{rw} T_1 \xrightarrow{rw} T_2$$
PostgreSQL monitors in-memory SIREAD flags. The moment an incoming $rw$-edge creates two consecutive $rw$-antidependency links that could complete a cycle, the PostgreSQL kernel aborts the *pivot transaction* ($T_1$) with `SQLSTATE 40001`.

### 2. SIREAD Predicate Lock Escalation Probability & Memory Sizing

PostgreSQL maintains SIREAD locks in a fixed-size shared memory hash table:
$$N_{\text{pred\_slots}} = \text{max\_connections} \times \text{max\_pred\_locks\_per\_transaction}$$

Let $K$ be the number of distinct tuples read by transaction $T$ on table $R$.
- If $K_{\text{page}} > \text{max\_pred\_locks\_per\_page}$, all tuple locks on that 8KB page collapse into a single **Page-Level SIREAD Lock**.
- If $P_{\text{pages}} > |\text{max\_pred\_locks\_per\_relation}|$, all page locks on relation $R$ collapse into a single **Relation-Level SIREAD Lock**.

When a relation lock is active on table $R$, the probability that a random concurrent writer $W$ triggers a false-positive $rw$-antidependency on $R$ is:
$$\mathbb{P}(\text{False Conflict} \mid \text{Relation Lock}) = 1 - \left(1 - \frac{|\text{Writes}_W|}{|R_{\text{tuples}}|}\right) \approx \frac{|\text{Writes}_W|}{|R_{\text{tuples}}|}$$

For high-write tables, $\mathbb{P}(\text{False Conflict}) \to 1.0$, collapsing concurrency. Sizing `max_pred_locks_per_transaction` to at least $4\times$ the maximum expected selective index scan size guarantees that tuple locks never escalate to page/relation locks:
$$\text{max\_pred\_locks\_per\_transaction} \ge 4 \times \max_{Q} \left(\mathbb{E}[\text{Tuples Scanned by } Q]\right)$$

### 3. Full Decorrelated Jitter Retry Calculus

When $N$ concurrent transactions experience serialization failures due to high contention on a hot predicate, naive fixed or exponential retries without jitter synchronize retry attempts, recreating the exact same dependency collision:

```
T0: Collide -> Retry at +100ms -> Collide -> Retry at +200ms -> Collide (Thundering Herd)
```

To achieve optimal convergence and minimize queueing delay, the backoff interval $\tau$ for attempt $k \in [0, K_{\max}]$ must be sampled from a uniform distribution between $0$ and the exponential ceiling:
$$\tau_k = \mathcal{U}\left(0, \min(T_{\max}, T_{\text{base}} \cdot 2^k)\right)$$

The expected collision probability on attempt $k+1$ across $N$ competing workers decaying over interval $W_k = \min(T_{\max}, T_{\text{base}} \cdot 2^k)$ is:
$$\mathbb{P}(\text{Collision}_k) \le 1 - \left(1 - \frac{T_{\text{tx}}}{W_k}\right)^{N-1} \approx \frac{(N-1) \cdot T_{\text{tx}}}{W_k}$$
As $W_k$ expands exponentially, $\mathbb{P}(\text{Collision}_k) \to 0$, ensuring deterministic convergence within $\le 4$ retry iterations.

---

## 4. Production TypeScript Reference Implementation: `AgenticDatabaseIsolationEngine`

The following production-ready engine provides an autonomous, resilient execution wrapper for PostgreSQL transactions, complete with automatic `40001` serialization failure retries, decorrelated jitter backoff, metric telemetry, and analytical deferrable read-only optimization:

```typescript
// src/db/AgenticDatabaseIsolationEngine.ts

import { Pool, PoolClient } from 'pg';

export type IsolationLevel = 'READ COMMITTED' | 'REPEATABLE READ' | 'SERIALIZABLE';

export interface TransactionOptions {
  isolationLevel?: IsolationLevel;
  readOnly?: boolean;
  deferrable?: boolean; // Only valid when isolationLevel === 'SERIALIZABLE' and readOnly === true
  maxRetries?: number;
  baseBackoffMs?: number;
  maxBackoffMs?: number;
  timeoutMs?: number;
  txName?: string;
}

export interface TransactionMetrics {
  txName: string;
  attempts: number;
  totalDurationMs: number;
  committed: boolean;
  serializationFailures: number;
  deadlocks: number;
}

export class SerializationError extends Error {
  constructor(message: string, public readonly code: string, public readonly attempt: number) {
    super(message);
    this.name = 'SerializationError';
  }
}

export class AgenticDatabaseIsolationEngine {
  private static readonly SQLSTATE_SERIALIZATION_FAILURE = '40001';
  private static readonly SQLSTATE_DEADLOCK_DETECTED = '40P01';

  constructor(private readonly pool: Pool) {}

  /**
   * Executes an idempotent transaction closure with full SSI serialization failure retry logic.
   * Enforces zero-side-effects-before-commit discipline.
   */
  public async executeTransaction<T>(
    fn: (client: PoolClient, attempt: number) => Promise<T>,
    options: TransactionOptions = {}
  ): Promise<{ result: T; metrics: TransactionMetrics }> {
    const {
      isolationLevel = 'SERIALIZABLE',
      readOnly = false,
      deferrable = false,
      maxRetries = 5,
      baseBackoffMs = 25,
      maxBackoffMs = 2000,
      timeoutMs = 10000,
      txName = 'unnamed_tx',
    } = options;

    const startTime = Date.now();
    let serializationFailures = 0;
    let deadlocks = 0;

    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      const client = await this.pool.connect();
      try {
        // 1. Build BEGIN declaration
        const parts = ['BEGIN', `ISOLATION LEVEL ${isolationLevel}`];
        if (readOnly) parts.push('READ ONLY');
        if (deferrable && isolationLevel === 'SERIALIZABLE' && readOnly) {
          parts.push('DEFERRABLE');
        }
        const beginQuery = parts.join(' ') + ';';

        await client.query(beginQuery);

        // 2. Set statement and lock timeouts within transaction boundary
        if (timeoutMs > 0) {
          await client.query(`SET LOCAL statement_timeout = ${timeoutMs};`);
          await client.query(`SET LOCAL lock_timeout = ${Math.min(timeoutMs, 3000)};`);
        }

        // 3. Execute user closure
        const result = await fn(client, attempt);

        // 4. Commit transaction
        await client.query('COMMIT;');

        const totalDurationMs = Date.now() - startTime;
        return {
          result,
          metrics: {
            txName,
            attempts: attempt,
            totalDurationMs,
            committed: true,
            serializationFailures,
            deadlocks,
          },
        };
      } catch (err: any) {
        // Always attempt safe rollback on error
        try {
          await client.query('ROLLBACK;');
        } catch {
          // Swallow rollback error if connection already terminated
        }

        const pgCode = err?.code;
        const isSerializationFailure = pgCode === AgenticDatabaseIsolationEngine.SQLSTATE_SERIALIZATION_FAILURE;
        const isDeadlock = pgCode === AgenticDatabaseIsolationEngine.SQLSTATE_DEADLOCK_DETECTED;

        if (isSerializationFailure) serializationFailures++;
        if (isDeadlock) deadlocks++;

        const isRetryable = isSerializationFailure || isDeadlock;

        // If not retryable or max retries exceeded, throw terminal error
        if (!isRetryable || attempt >= maxRetries) {
          throw new SerializationError(
            `Transaction '${txName}' failed permanently after ${attempt} attempt(s): ${err.message}`,
            pgCode || 'UNKNOWN',
            attempt
          );
        }

        // Compute decorrelated exponential backoff with full jitter
        const maxCurrentBackoff = Math.min(maxBackoffMs, baseBackoffMs * Math.pow(2, attempt));
        const jitteredSleepMs = Math.floor(Math.random() * maxCurrentBackoff);

        await new Promise((resolve) => setTimeout(resolve, jitteredSleepMs));
      } finally {
        client.release();
      }
    }

    throw new Error(`Transaction '${txName}' exhausted retry budget without result.`);
  }

  /**
   * Helper for read-only analytical queries running in SERIALIZABLE DEFERRABLE mode.
   * Guaranteed never to abort with 40001 and never to cause OLTP writers to abort.
   */
  public async executeReadOnlySnapshot<T>(
    fn: (client: PoolClient) => Promise<T>,
    txName = 'analytical_snapshot'
  ): Promise<T> {
    const { result } = await this.executeTransaction(
      async (client) => fn(client),
      {
        isolationLevel: 'SERIALIZABLE',
        readOnly: true,
        deferrable: true,
        maxRetries: 3,
        txName,
      }
    );
    return result;
  }
}
```

---

## 5. Language-Specific Invariants & Production Patterns

### 1. Go (`jackc/pgx/v5`): Robust Serializable Transaction Runner

In Go microservices using `pgx/v5`, transactions must handle `pgconn.PgError` with SQLSTATE `40001` and apply exponential decorrelated jitter:

```go
package db

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	SQLStateSerializationFailure = "40001"
	SQLStateDeadlockDetected      = "40P01"
)

type TxOptions struct {
	MaxRetries    int
	BaseBackoff   time.Duration
	MaxBackoff    time.Duration
	TxName        string
	ReadOnly      bool
	Deferrable    bool
}

func DefaultTxOptions() TxOptions {
	return TxOptions{
		MaxRetries:  5,
		BaseBackoff: 25 * time.Millisecond,
		MaxBackoff:  2 * time.Second,
		TxName:      "serializable_tx",
	}
}

// ExecuteSerializable executes an idempotent database operation in SERIALIZABLE isolation,
// retrying automatically on SQLSTATE 40001 (serialization_failure) and 40P01 (deadlock).
func ExecuteSerializable[T any](
	ctx context.Context,
	pool *pgxpool.Pool,
	opts TxOptions,
	fn func(ctx context.Context, tx pgx.Tx) (T, error),
) (T, error) {
	var zero T

	pgxOpts := pgx.TxOptions{
		IsoLevel: pgx.Serializable,
	}
	if opts.ReadOnly {
		pgxOpts.AccessMode = pgx.ReadOnly
	}
	if opts.Deferrable && opts.ReadOnly {
		pgxOpts.DeferrableMode = pgx.Deferrable
	}

	for attempt := 1; attempt <= opts.MaxRetries; attempt++ {
		res, err := func() (T, error) {
			tx, err := pool.BeginTx(ctx, pgxOpts)
			if err != nil {
				return zero, fmt.Errorf("begin tx: %w", err)
			}
			defer tx.Rollback(ctx) // Safe no-op if already committed

			val, err := fn(ctx, tx)
			if err != nil {
				return zero, err
			}

			if err := tx.Commit(ctx); err != nil {
				return zero, err
			}

			return val, nil
		}()

		if err == nil {
			return res, nil
		}

		// Check if error is a retryable serialization or deadlock error
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && (pgErr.Code == SQLStateSerializationFailure || pgErr.Code == SQLStateDeadlockDetected) {
			if attempt >= opts.MaxRetries {
				return zero, fmt.Errorf("transaction %s exhausted retry budget (%d attempts): %w", opts.TxName, attempt, err)
			}

			// Full decorrelated jitter backoff: Uniform(0, min(maxBackoff, baseBackoff * 2^attempt))
			currentMax := float64(opts.BaseBackoff) * float64(int(1)<<attempt)
			if currentMax > float64(opts.MaxBackoff) {
				currentMax = float64(opts.MaxBackoff)
			}
			jitter := time.Duration(rand.Float64() * currentMax)

			select {
			case <-ctx.Done():
				return zero, ctx.Err()
			case <-time.After(jitter):
				continue
			}
		}

		// Non-retryable error: return immediately
		return zero, err
	}

	return zero, fmt.Errorf("transaction %s reached unreachable retry termination", opts.TxName)
}
```

### 2. SQL Schema, `postgresql.conf` SIREAD Tuning & Diagnostic Views

```sql
-- 1. Tuning postgresql.conf for High-Concurrency SSI
-- Prevent premature predicate lock escalation on high-churn relations
ALTER SYSTEM SET max_pred_locks_per_transaction = 256;
ALTER SYSTEM SET max_pred_locks_per_relation = -2; -- Uses max_pred_locks_per_transaction / 2
ALTER SYSTEM SET max_pred_locks_per_page = 2;

-- Reload configuration without restart
SELECT pg_reload_conf();

-- 2. Diagnostic View: Active SIREAD Predicate Locks in PostgreSQL
-- Inspect whether predicate locks are tuple-level (good) or escalated to relation-level (bad!)
CREATE OR REPLACE VIEW view_active_predicate_locks AS
SELECT
  l.locktype,
  l.mode,
  c.relname AS relation_name,
  l.page,
  l.tuple,
  l.virtualtransaction AS vxid,
  l.pid,
  NOW() - a.query_start AS query_age,
  a.query
FROM pg_locks l
LEFT JOIN pg_class c ON l.relation = c.oid
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE l.mode = 'SIReadLock'
ORDER BY l.locktype DESC, query_age DESC;

-- 3. Telemetry: Count SIREAD locks by granularity (tuple vs page vs relation)
-- If relation > 0 on OLTP tables, queries lack selective B-tree indexes!
SELECT
  locktype,
  COUNT(*) AS count
FROM pg_locks
WHERE mode = 'SIReadLock'
GROUP BY locktype;
```

---

## 6. The 6-State Transaction Isolation Lifecycle FSM

Every transaction managed under Serializable Snapshot Isolation transitions through a rigorous 6-state finite-state machine:

```
┌──────────────┐     Acquire Client      ┌──────────────┐
│  0. UNBOUND  │ ──────────────────────> │ 1. DECLARED  │
└──────────────┘                         └──────────────┘
                                                │
                                                │ Execute BEGIN (ISOLATION LEVEL ...)
                                                ▼
┌──────────────┐   SQLSTATE 40001/40P01   ┌──────────────┐
│ 5. RECOVERING│ <────────────────────── │ 2. EXECUTING │
│ (Jitter Wait)│                         └──────────────┘
└──────────────┘                                │
       │                                        │ Successful Closure Execution
       │ Attempt < MaxRetries                   ▼
       └───────────────────────────────> ┌──────────────┐
                                         │ 3. COMMITTING│
                                         └──────────────┘
                                                │
                                                │ COMMIT Success
                                                ▼
                                         ┌──────────────┐
                                         │ 4. FINALIZED │
                                         └──────────────┘
```

1. **State 0: UNBOUND**: Connection acquired from pool; timeouts, isolation level, and read-only flags configured in memory.
2. **State 1: DECLARED**: Explicit `BEGIN ISOLATION LEVEL SERIALIZABLE [READ ONLY] [DEFERRABLE]` executed; statement timeouts pinned.
3. **State 2: EXECUTING**: User closure evaluates business logic; index-supported reads record fine-grained tuple-level SIREAD locks in shared memory; mutations execute without blocking read operations.
4. **State 3: COMMITTING**: `COMMIT` statement issued. PostgreSQL SSI kernel verifies that no directed cycle exists in the Serialization Dependency Graph ($G$).
5. **State 4: FINALIZED**: Commit acknowledged by storage engine; locks released; client connection safely returned to pool.
6. **State 5: RECOVERING**: Engine catches `SQLSTATE 40001` or `40P01`. Transaction rolled back; attempt counter incremented; thread sleeps for decorrelated jitter interval before restarting at State 1. If attempts exceed budget, aborts to State 4 with terminal `SerializationError`.

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Category | Invariant Rule | Verification Method | Pass Criteria |
| :--- | :--- | :--- | :--- | :--- |
| **Gate 1** | **Declaration** | Explicit isolation level on all multi-query transactions | Static Code AST Analysis (`grep / ast-grep`) | 0 transactions with implicit `READ COMMITTED` defaults |
| **Gate 2** | **Write Skew** | Cross-row constraints protected via SSI or Exclusion Constraints | Concurrent Stress Testing (`k6 / pgbench`) | 0 constraint violations under 100 concurrent workers |
| **Gate 3** | **Retry Harness** | 100% of SSI transactions wrapped in idempotent retry loops | Integration Test Suite (`Vitest / go test`) | Zero unhandled `40001` errors exposed to API callers |
| **Gate 4** | **Jitter Backoff** | Retry backoff applies full decorrelated jitter | Unit Test Analysis | $\tau_k \sim \mathcal{U}(0, \min(T_{\max}, 2^k \cdot T_{\text{base}}))$, zero fixed-interval sleeps |
| **Gate 5** | **SIREAD Sizing** | Zero unindexed relation-level SIREAD lock escalations | Continuous `pg_locks` CI Monitoring | `COUNT(*) WHERE locktype = 'relation' AND mode = 'SIReadLock' == 0` |
| **Gate 6** | **Deferrable Snapshots**| Heavy analytical/reporting queries use `READ ONLY DEFERRABLE` | Query Audit Log Scanner | 100% of serializable read-only reports declare `DEFERRABLE` |
