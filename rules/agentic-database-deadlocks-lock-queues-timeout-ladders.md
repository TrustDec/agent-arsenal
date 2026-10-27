---
description: PostgreSQL heavyweight lock hierarchy, head-of-line blocking prevention, deadlock wait-for graph cycle elimination, canonical lexicographical resource ordering, transaction-scoped advisory locks, unindexed foreign key lock escalation defense, and multi-tier timeout ladders across Go (pgx/sqlc), TypeScript (Drizzle/Prisma), Python (SQLAlchemy), Rust (sqlx), PostgreSQL, Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{lock,deadlock,timeout,concurrency,postgres,transaction}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/repository/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Heavyweight Locks, Deadlock Prevention & Multi-Tier Timeout Ladders

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design multi-row transactional updates, balance transfers, inventory reservations, schema migrations, advisory locking workflows, or database concurrency governance across PostgreSQL, Go (`jackc/pgx`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`SQLAlchemy 2.0`), or Rust (`sqlx`). Eliminate the "ACCESS EXCLUSIVE Head-of-Line Blocking Avalanche" (where an `ALTER TABLE` or un-timed DDL queues behind a long-running read, causing PostgreSQL's FIFO lock manager to queue all subsequent fast reads behind it, exhausting the entire connection pool in $< 3$ seconds), the "Deadlock Detection Sleep Latency Spasm" (where default `deadlock_timeout = 1000ms` forces mutually blocked transactions to freeze database worker threads for a full second before the cycle detector aborts one with `40P01`), the "Non-Canonical Lock Order Deadlock Storm" (where concurrent transactions lock multiple records in disparate orders, producing directed cycles $T_1 \to T_2 \to T_1$ in the wait-for graph), the "Advisory Lock Leak in Connection Poolers" (where session-level `pg_advisory_lock` leaks across recycled connections in PgBouncer transaction pooling, causing ghost locks and tenant starvation), the "Unindexed Foreign Key Lock Escalation Trap" (where deleting parent rows locks the entire child relation or triggers table-wide lock escalation because the foreign key column lacks a supporting B-tree index), and the "Missing Multi-Tier Timeout Ladder & Indefinite Wait Freeze" (where queries execute without `lock_timeout`, hanging indefinitely on contested locks and starving connection pools) by establishing a strict 5-Tier Lock & Deadlock Governance Ladder, canonical total ordering, transaction-scoped advisory locks, and multi-tier timeout ladders.

---

## 1. Architectural Taxonomy: The 6 Lock & Deadlock Catastrophes vs The 5-Tier Governance Ladder

In relational databases (PostgreSQL, MySQL InnoDB), concurrency control relies on two distinct locking subsystems:
1. **Lightweight Locks (LWLocks) / Latches**: In-memory, kernel-level sync primitives protecting shared memory structures (e.g. `shared_buffers`, buffer headers, WAL buffers). Held for microseconds, completely invisible to SQL.
2. **Heavyweight Locks (Regular Locks)**: High-level database objects tracked in shared memory by the Lock Manager (`pg_locks`). They protect user visible entities (tables, partitions, rows, pages, advisory keys) across transactions.

When autonomous coding agents write transactional business logic, batch processors, or database migrations, LLMs routinely commit fatal locking anti-patterns:

```typescript
// ❌ CATASTROPHIC LLM LOCKING & DEADLOCK ANTI-PATTERNS
// 1. Non-canonical multi-row updates in random or user-provided order!
// Transaction A updates user 10 then 20; Transaction B updates user 20 then 10.
// Guaranteed 40P01 deadlock detected under concurrent load!
async function transferFunds(db: DatabaseClient, fromId: number, toId: number, amount: number) {
  await db.transaction(async (tx) => {
    // FATAL: Unordered locking. Concurrent reverse transfers trigger circular wait-for deadlock!
    await tx.query(`UPDATE accounts SET balance = balance - $1 WHERE id = $2`, [amount, fromId]);
    await tx.query(`UPDATE accounts SET balance = balance + $1 WHERE id = $2`, [amount, toId]);
  });
}

// 2. Running DDL or maintenance operations with unbounded lock wait!
// Queues behind an analytical SELECT; blocks ALL incoming application SELECT queries!
async function addColumnWithoutTimeout(db: DatabaseClient) {
  // FATAL: If an active SELECT takes 15s, this statement waits, and ALL subsequent
  // reads on 'users' queue behind it in PostgreSQL's FIFO queue, killing the entire cluster!
  await db.query(`ALTER TABLE users ADD COLUMN is_verified BOOLEAN DEFAULT false`);
}

// 3. Using session-level advisory locks in pooled architectures!
async function acquireDistributedLock(db: DatabaseClient, lockKey: number) {
  // FATAL: pg_advisory_lock() is session-scoped! In PgBouncer transaction pooling,
  // the physical connection is returned to the pool while the lock remains HELD!
  await db.query(`SELECT pg_advisory_lock($1)`, [lockKey]);
}
```

In production architectures, naive locking and timeout configurations trigger six critical engineering disasters:

- **The "ACCESS EXCLUSIVE Head-of-Line Blocking Avalanche" (The Lock Queue Freeze)**:
  - In PostgreSQL, the lock manager implements a **Strict FIFO Queue** with conflict priority. When a statement requests a heavyweight lock that conflicts with an already-held lock, it enters the wait queue.
  - When a transaction requests an `ACCESS EXCLUSIVE` lock (required by `ALTER TABLE`, `DROP TABLE`, `TRUNCATE`, `CLUSTER`, `VACUUM FULL`, `REFRESH MATERIALIZED VIEW` without `CONCURRENTLY`), and an active query holds even an `ACCESS SHARE` lock (a basic `SELECT`), the DDL statement waits.
  - Crucially: **Any subsequent read query requesting `ACCESS SHARE` on that table will NOT jump ahead of the waiting `ACCESS EXCLUSIVE` request**. The reads are placed behind the DDL in the wait queue!
  - Within 2 to 5 seconds, hundreds of incoming HTTP worker requests pile up in the wait queue. The entire application connection pool is 100% depleted. The entire application goes down with gateway 504 timeouts, even though the database CPU is completely idle at 1%!
  - Invariant: NEVER execute DDL or table-locking commands without a sub-second lock timeout: `SET LOCAL lock_timeout = '1500ms'`. If the lock cannot be acquired within 1.5s, immediately abort, back off with jitter, and retry.

- **The "Deadlock Detection Sleep Latency Spasm" (1,000ms Latency Cliff)**:
  - When two transactions mutually block each other ($T_1$ holds Lock $A$, waits for Lock $B$; $T_2$ holds Lock $B$, waits for Lock $A$), neither can proceed.
  - Relational database kernels do not run expensive directed cycle detection on every lock acquisition attempt. Instead, PostgreSQL sleeps for `deadlock_timeout` (default: **$1000\text{ms} = 1\text{ second}$**) before waking up the lock manager to perform cycle detection on the wait-for graph.
  - This means every deadlock incurs an automatic 1,000ms latency penalty. Worker threads and connections remain frozen for a full second before one transaction is murdered with `ERROR: 40P01: deadlock detected`.
  - Invariant: Lower `deadlock_timeout = 100ms` or `250ms` in high-concurrency transactional OLTP systems. Implement automated application-level retry loops with decorrelated jitter specifically intercepting error code `40P01`.

- **The "Non-Canonical Lock Order Deadlock Storm" (Wait-For Graph Cycles)**:
  - Autonomous agents frequently generate multi-row updates, inventory decrements, or ledger transfers by executing queries in the order arguments were received (e.g. `items.forEach(async item => update(item))`).
  - If Client 1 locks Row $X$ then Row $Y$, while Client 2 concurrently locks Row $Y$ then Row $X$, the wait-for graph forms a directed cycle: $T_1 \xrightarrow{\text{waits on } Y} T_2 \xrightarrow{\text{waits on } X} T_1$.
  - Invariant: The **Theorem of Canonical Lexicographical Lock Ordering**. All transactions modifying or locking multiple rows MUST sort the primary keys or resource identifiers in ascending order prior to acquisition: $\text{sort}(ID_1, ID_2, \dots, ID_k)$. In SQL: `SELECT ... WHERE id = ANY($1) ORDER BY id ASC FOR UPDATE`. Sorting converts the wait-for graph into a Directed Acyclic Graph (DAG), mathematically guaranteeing zero cycles and zero deadlocks.

- **The "Advisory Lock Leak in Connection Poolers" (Session State Poisoning)**:
  - PostgreSQL advisory locks are application-defined mutexes. `pg_advisory_lock(key)` acquires a **session-level lock** that is bound to the physical TCP connection, NOT the transaction block. It survives `COMMIT` and `ROLLBACK`!
  - When using PgBouncer in `transaction` pooling mode (or connection poolers with connection recycling like HikariCP, pgxpool, Prisma), returning a connection to the pool leaves the session-level advisory lock held.
  - The next unrelated tenant or request that checks out that physical connection inherits the locked mutex, or subsequent workers attempting to acquire `pg_advisory_lock(key)` hang forever.
  - Invariant: ALWAYS use transaction-scoped advisory locks: `SELECT pg_advisory_xact_lock(key)` or non-blocking `SELECT pg_try_advisory_xact_lock(key)`. These locks are automatically and atomically released by the PostgreSQL kernel on transaction commit or rollback, eliminating 100% of connection pooler leaks.

- **The "Unindexed Foreign Key Lock Escalation Trap" (Table-Level Share Contention)**:
  - When a transaction performs an `UPDATE` or `DELETE` on a row in a parent table (e.g. `DELETE FROM orders WHERE id = $1`), PostgreSQL must ensure that no child rows (e.g. `order_items`) violate foreign key constraints.
  - If the child table's foreign key column (`order_items.order_id`) lacks a supporting B-tree index, PostgreSQL cannot perform a fast index lookup. In legacy PostgreSQL versions it took a `SHARE ROW EXCLUSIVE` lock on the entire child table; in modern versions it performs an expensive sequential scan of the child table while taking locks that serialize concurrent operations and create severe deadlock vulnerabilities.
  - Invariant: Every foreign key constraint MUST have a corresponding B-tree index on the child table column: `CREATE INDEX idx_order_items_order_id ON order_items(order_id)`.

- **The "Missing Multi-Tier Timeout Ladder & Indefinite Wait Freeze" (Unbounded Starvation)**:
  - By default, PostgreSQL has `lock_timeout = 0` (wait forever) and `statement_timeout = 0` (run forever).
  - If a transaction is blocked by another worker or acquires a lock and encounters a stalled network call, it remains frozen indefinitely. The connection pooler wait queue fills up, new requests are rejected with pool starvation errors, and manual DBA intervention (killing backend PIDs via `pg_terminate_backend`) is required.
  - Invariant: Enforce the **Multi-Tier Timeout Ladder**:
    $$T_{\text{lock\_timeout}} \le T_{\text{statement\_timeout}} \le T_{\text{idle\_in\_transaction\_session\_timeout}}$$
    Set `lock_timeout = 2s`, `statement_timeout = 10s`, and `idle_in_transaction_session_timeout = 5s` on all OLTP application pools.

```text
========================================================================================================================
                                     THE 5-TIER LOCK & DEADLOCK GOVERNANCE LADDER
========================================================================================================================

  Tier 4: Automated Deadlock Recovery, Jittered Retries & Circuit Breaking
  ├── Application wrapper intercepting PostgreSQL 40P01 (deadlock) and 55P03 (lock timeout)
  ├── Truncated exponential backoff with full decorrelated jitter: tau = Uniform(0, min(max_backoff, base * 2^k))
  └── Circuit breaker trip on high deadlock frequency (> 2% of transactions), alerting DBAs

  Tier 3: Transaction-Scoped Advisory Locks (pg_advisory_xact_lock) & Pooler Safety
  ├── Strict prohibition of session-scoped pg_advisory_lock() in pooled environments (PgBouncer)
  ├── Mandatory pg_advisory_xact_lock() automatically released on COMMIT or ROLLBACK
  └── Non-blocking pg_try_advisory_xact_lock() for fast 0ms failure on contention

  Tier 2: Mandatory Foreign Key B-Tree Indexing & Cascade Defense
  ├── Automated schema sentinels verifying 100% of foreign keys have supporting B-tree indexes
  ├── Elimination of child table full scans and lock escalation during parent row mutations
  └── Bounded cascade deletions using batched keyset chunks (LIMIT 1000)

  Tier 1: Canonical Lexicographical Lock Ordering (sort(ids) / ORDER BY id ASC)
  ├── Strict total order on multi-resource locks: sort(IDs) ascending prior to SQL execution
  ├── SQL row-level locking: SELECT ... WHERE id = ANY($1) ORDER BY id ASC FOR UPDATE
  └── Mathematical proof: Directed Wait-For Graph is a DAG -> Cycles = empty set -> P(Deadlock) = 0

  Tier 0: Multi-Tier Timeout Ladder & Sub-Second DDL Lock Guarantees
  ├── SET LOCAL lock_timeout = '1500ms' on all migrations and DDL (terminates before blocking pool)
  ├── Global pool timeout ladder: lock_timeout (2s) < statement_timeout (10s) < idle_in_tx (5s)
  └── deadlock_timeout tuned to 100ms - 250ms (slashes deadlock detection latency by 75%-90%)
========================================================================================================================
```

---

## 2. Mathematical Invariants: Total Ordering, Wait-For Graphs & Queue Physics

The physics of database locking and deadlocks are governed by graph theory and queueing models:

### 1. The Theorem of Deadlock-Free Canonical Total Ordering

Let $\mathcal{R} = \{r_1, r_2, \dots, r_m\}$ be a set of database resources (table rows, partitions, advisory keys). Let $\mathcal{T} = \{T_1, T_2, \dots, T_n\}$ be a set of concurrent transactions.

A **Wait-For Graph** is a directed graph $\mathcal{G} = (\mathcal{T}, \mathcal{E})$ where a directed edge $(T_i \to T_j) \in \mathcal{E}$ exists if and only if transaction $T_i$ is waiting for a lock currently held by transaction $T_j$.

**Theorem (Deadlock Condition)**: A deadlock occurs if and only if $\mathcal{G}$ contains at least one directed cycle:

$$\exists \, C = (T_1, T_2, \dots, T_k, T_1) \subseteq \mathcal{E} \iff \text{Deadlock}$$

**Proof of Cycle Elimination via Canonical Total Ordering**:
Define a strict total order relation $<$ over all resource identifiers in $\mathcal{R}$ (e.g. natural integer ordering of Primary Keys or lexicographical string ordering of UUIDs):

$$\forall \, r_a, r_b \in \mathcal{R}, \quad r_a < r_b \lor r_b < r_a \lor r_a = r_b$$

**Invariant**: Enforce the protocol that every transaction $T_i$ acquiring multiple locks $\{r_{\pi(1)}, r_{\pi(2)}, \dots, r_{\pi(k)}\}$ MUST acquire them in strictly increasing order according to $<$:

$$r_{\pi(1)} < r_{\pi(2)} < \dots < r_{\pi(k)}$$

Assume for contradiction that a cycle exists in the wait-for graph: $T_1 \xrightarrow{\text{waits for } r_1} T_2 \xrightarrow{\text{waits for } r_2} \dots \xrightarrow{\text{waits for } r_{k-1}} T_k \xrightarrow{\text{waits for } r_k} T_1$.

For $T_1$ to wait on $T_2$ for resource $r_1$, $T_1$ must already hold some resource $r_0$ such that $r_0 < r_1$, while $T_2$ holds $r_1$. Traversing the cycle of dependencies implies:

$$r_0 < r_1 < r_2 < \dots < r_k < r_0$$

This implies $r_0 < r_0$, which is impossible by the irreflexivity of strict total orders. Therefore, the wait-for graph $\mathcal{G}$ is guaranteed to be a **Directed Acyclic Graph (DAG)**:

$$\text{Cycles}(\mathcal{G}) = \emptyset \implies \mathbb{P}(\text{Deadlock}) = 0$$

### 2. The Lock Contention Queueing Model & Connection Pool Saturation Time

When a transaction requests an `ACCESS EXCLUSIVE` lock on a table $\mathcal{R}$, and a running query holds `ACCESS SHARE`, the lock manager puts the exclusive request into the wait queue. Because PostgreSQL employs FIFO lock ordering, all subsequent incoming queries requesting `ACCESS SHARE` on $\mathcal{R}$ are queued behind it.

Let:
- $\lambda_{\text{read}}$ be the arrival rate of read queries on table $\mathcal{R}$ (queries per second).
- $N_{\text{pool\_free}}$ be the number of currently available connections in the application connection pool.
- $T_{\text{hold}}$ be the remaining execution time of the active blocking query.

The time until **complete application connection pool exhaustion** $T_{\text{exhaust}}$ is given by:

$$T_{\text{exhaust}} = \frac{N_{\text{pool\_free}}}{\lambda_{\text{read}}}$$

**Numerical Example**:
- $N_{\text{pool\_free}} = 100\text{ connections}$
- $\lambda_{\text{read}} = 200\text{ queries/sec}$
- $T_{\text{hold}} = 15\text{ seconds}$ (a standard reporting or analytics query)

$$T_{\text{exhaust}} = \frac{100}{200} = 0.5\text{ seconds}$$

In just **$500\text{ milliseconds}$**, all 100 connections are frozen in PostgreSQL's lock queue waiting for the exclusive lock. Every subsequent HTTP request across the entire system immediately fails or hangs!

**Invariant**: If $T_{\text{lock\_timeout}} = 1.5\text{s}$, the exclusive request is terminated before exhausting the pool, allowing queued reads to execute immediately and preserving cluster uptime.

### 3. The Multi-Tier Timeout Ladder Inequality

To guarantee that no transaction holds locks or consumes connection slots indefinitely, systems MUST enforce the Multi-Tier Timeout Hierarchy:

$$T_{\text{lock}} < T_{\text{statement}} < T_{\text{idle\_in\_transaction}} < T_{\text{client\_timeout}}$$

| Parameter | Recommended OLTP Envelope | Physical Enforcement Reason |
| :--- | :--- | :--- |
| `deadlock_timeout` | $100\text{ms} - 250\text{ms}$ | Wakes cycle detector quickly to resolve cyclic deadlocks without stalling threads |
| `lock_timeout` | $1,000\text{ms} - 2,000\text{ms}$ | Fails fast if contested lock cannot be acquired, preventing queue head-of-line stalls |
| `statement_timeout` | $5,000\text{ms} - 15,000\text{ms}$ | Kills runaway full table scans, Cartesian joins, or unindexed queries |
| `idle_in_transaction_session_timeout` | $3,000\text{ms} - 5,000\text{ms}$ | Terminates abandoned transactions that hold locks across external HTTP/RPC calls |

---

## 3. TypeScript Reference Engine: `AgenticDatabaseLockEngine`

The following production-ready engine provides canonical row ordering, transaction-scoped advisory try-locks, multi-tier timeout ladder injection, automated deadlock jitter retries, and lock contention diagnostics:

```typescript
/**
 * AgenticDatabaseLockEngine - Industrial Lock Management, Deadlock Prevention & Timeout Ladder
 */

export interface TimeoutLadderConfig {
  lockTimeoutMs: number; // e.g. 1500ms
  statementTimeoutMs: number; // e.g. 8000ms
  idleInTxTimeoutMs?: number; // e.g. 5000ms
}

export interface DeadlockRetryOptions {
  maxAttempts: number; // e.g. 5
  baseDelayMs: number; // e.g. 50ms
  maxDelayMs: number; // e.g. 1000ms
}

export interface BlockedLockInfo {
  blockedPid: number;
  blockedUser: string;
  blockingPid: number;
  blockingUser: string;
  blockedStatement: string;
  currentStatementInBlockingProcess: string;
  lockType: string;
  lockMode: string;
  waitDurationSeconds: number;
}

export interface UnindexedForeignKey {
  childTable: string;
  constraintName: string;
  foreignKeyColumns: string[];
  parentTable: string;
}

export interface DatabaseClient {
  query<T = any>(sql: string, params?: any[]): Promise<{ rows: T[] }>;
}

export class AgenticDatabaseLockEngine {
  private readonly defaultLadder: TimeoutLadderConfig = {
    lockTimeoutMs: 1500,
    statementTimeoutMs: 10000,
    idleInTxTimeoutMs: 5000,
  };

  /**
   * Generates a canonical SELECT ... FOR UPDATE query with ascending row ordering
   * Guarantees Directed Acyclic Graph (DAG) in wait-for graph -> Zero Deadlocks
   */
  public buildCanonicalRowLockSQL(
    tableName: string,
    idColumn: string,
    ids: Array<number | string>,
    lockMode: 'FOR UPDATE' | 'FOR NO KEY UPDATE' | 'FOR SHARE' | 'FOR KEY SHARE' = 'FOR UPDATE'
  ): { sql: string; sortedIds: Array<number | string> } {
    if (ids.length === 0) {
      throw new Error('Cannot lock empty ID list');
    }

    // Sort IDs in strict ascending order (canonical total ordering)
    const sortedIds = [...new Set(ids)].sort((a, b) => {
      if (typeof a === 'number' && typeof b === 'number') return a - b;
      return String(a).localeCompare(String(b));
    });

    const sql = `
      SELECT ${idColumn}
      FROM ${tableName}
      WHERE ${idColumn} = ANY($1)
      ORDER BY ${idColumn} ASC
      ${lockMode};
    `;

    return { sql, sortedIds };
  }

  /**
   * Executes work within a transaction armed with the Multi-Tier Timeout Ladder
   */
  public async executeWithTimeoutLadder<T>(
    client: DatabaseClient,
    work: (tx: DatabaseClient) => Promise<T>,
    customConfig?: Partial<TimeoutLadderConfig>
  ): Promise<T> {
    const ladder = { ...this.defaultLadder, ...customConfig };

    await client.query('BEGIN;');
    try {
      // Inject transaction-local timeout ladder
      await client.query(`SET LOCAL lock_timeout = '${ladder.lockTimeoutMs}ms';`);
      await client.query(`SET LOCAL statement_timeout = '${ladder.statementTimeoutMs}ms';`);
      if (ladder.idleInTxTimeoutMs) {
        await client.query(`SET LOCAL idle_in_transaction_session_timeout = '${ladder.idleInTxTimeoutMs}ms';`);
      }

      const result = await work(client);
      await client.query('COMMIT;');
      return result;
    } catch (err: any) {
      await client.query('ROLLBACK;').catch(() => {});
      throw err;
    }
  }

  /**
   * Executes a database operation with exponential backoff and full decorrelated jitter
   * Specifically catches PostgreSQL 40P01 (deadlock_detected) and 55P03 (lock_not_available)
   */
  public async executeWithDeadlockRetry<T>(
    operation: () => Promise<T>,
    options: DeadlockRetryOptions = { maxAttempts: 5, baseDelayMs: 50, maxDelayMs: 1000 }
  ): Promise<T> {
    let attempt = 0;

    while (attempt < options.maxAttempts) {
      try {
        return await operation();
      } catch (error: any) {
        attempt++;
        const errorCode = error?.code || error?.originalError?.code;

        // PostgreSQL error codes:
        // 40P01 = deadlock_detected
        // 55P03 = lock_not_available
        // 40001 = serialization_failure
        const isTransientLockError = errorCode === '40P01' || errorCode === '55P03' || errorCode === '40001';

        if (!isTransientLockError || attempt >= options.maxAttempts) {
          throw error;
        }

        // Full decorrelated jitter: Uniform(0, min(maxDelay, base * 2^attempt))
        const backoffLimit = Math.min(options.maxDelayMs, options.baseDelayMs * Math.pow(2, attempt));
        const jitteredDelay = Math.floor(Math.random() * backoffLimit);

        await new Promise((resolve) => setTimeout(resolve, jitteredDelay));
      }
    }

    throw new Error(`Exceeded max deadlock retry attempts (${options.maxAttempts})`);
  }

  /**
   * Acquires a transaction-scoped advisory lock (safe in PgBouncer transaction pooling)
   * Returns true if lock was acquired, false if try-lock failed without blocking
   */
  public async tryAcquireAdvisoryXactLock(client: DatabaseClient, lockKey: number): Promise<boolean> {
    const res = await client.query<{ acquired: boolean }>(
      `SELECT pg_try_advisory_xact_lock($1) AS acquired;`,
      [lockKey]
    );
    return Boolean(res.rows[0]?.acquired);
  }

  /**
   * Audits active heavyweight lock contention and blocked queries in real-time
   */
  public async auditBlockedLocks(client: DatabaseClient): Promise<BlockedLockInfo[]> {
    const sql = `
      SELECT
        blocked_locks.pid AS blocked_pid,
        blocked_activity.usename AS blocked_user,
        blocking_locks.pid AS blocking_pid,
        blocking_activity.usename AS blocking_user,
        blocked_activity.query AS blocked_statement,
        blocking_activity.query AS current_statement_in_blocking_process,
        blocked_locks.locktype AS lock_type,
        blocked_locks.mode AS lock_mode,
        ROUND(EXTRACT(EPOCH FROM (NOW() - blocked_activity.query_start))::numeric, 2)::float AS wait_duration_seconds
      FROM pg_catalog.pg_locks blocked_locks
      JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
      JOIN pg_catalog.pg_locks blocking_locks
        ON blocking_locks.locktype = blocked_locks.locktype
        AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
        AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
        AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
        AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
        AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
        AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
        AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
        AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
        AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
        AND blocking_locks.pid != blocked_locks.pid
      JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
      WHERE NOT blocked_locks.granted
      ORDER BY blocked_activity.query_start ASC;
    `;

    const res = await client.query(sql);
    return res.rows.map((r: any) => ({
      blockedPid: Number(r.blocked_pid),
      blockedUser: String(r.blocked_user || ''),
      blockingPid: Number(r.blocking_pid),
      blockingUser: String(r.blocking_user || ''),
      blockedStatement: String(r.blocked_statement || ''),
      currentStatementInBlockingProcess: String(r.current_statement_in_blocking_process || ''),
      lockType: String(r.lock_type),
      lockMode: String(r.lock_mode),
      waitDurationSeconds: Number(r.wait_duration_seconds || 0),
    }));
  }

  /**
   * Discovers foreign key constraints lacking supporting B-tree indexes
   * Missing FK indexes trigger expensive sequential scans and table-level lock escalation!
   */
  public async auditUnindexedForeignKeys(client: DatabaseClient): Promise<UnindexedForeignKey[]> {
    const sql = `
      SELECT
        c.conrelid::regclass::text AS child_table,
        c.conname AS constraint_name,
        ARRAY(
          SELECT attname
          FROM pg_attribute
          WHERE attrelid = c.conrelid AND attnum = ANY(c.conkey)
          ORDER BY array_position(c.conkey, attnum)
        ) AS foreign_key_columns,
        c.confrelid::regclass::text AS parent_table
      FROM pg_constraint c
      WHERE c.contype = 'f'
        AND NOT EXISTS (
          SELECT 1
          FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND (i.indkey::smallint[])[0:cardinality(c.conkey)-1] = c.conkey
        )
      ORDER BY c.conrelid::regclass::text;
    `;

    const res = await client.query(sql);
    return res.rows.map((r: any) => ({
      childTable: String(r.child_table),
      constraintName: String(r.constraint_name),
      foreignKeyColumns: Array.isArray(r.foreign_key_columns) ? r.foreign_key_columns : [],
      parentTable: String(r.parent_table),
    }));
  }
}
```

---

## 4. The 6-State Lock & Deadlock Lifecycle Finite-State Machine (FSM)

Every database transaction acquiring contested resources navigates an explicit state machine with bounded timeouts and deterministic recovery:

```text
                  ┌────────────────────────┐
                  │        1. IDLE         │
                  └───────────┬────────────┘
                              │ BEGIN + Inject Timeout Ladder
                              ▼
                  ┌────────────────────────┐
                  │   2. TIMEOUT_ARMED     │
                  └───────────┬────────────┘
                              │ Acquire Locks (Canonical Total Order)
                              ▼
                  ┌────────────────────────┐
                  │   3. LOCK_ACQUIRING    │
                  └──────┬──────────┬──────┘
                         │          │
         Lock Acquired   │          │ Lock Contention / Timeout
                         ▼          ▼
    ┌────────────────────────┐  ┌────────────────────────┐
    │     4. EXECUTING       │  │ 5. RECOVERY_BACKOFF    │
    └───────────┬────────────┘  └───────────┬────────────┘
                │                           │
       Success  │ Commit / Rollback         │ Exponential Jitter Retry
                ▼                           ▼
    ┌────────────────────────┐  ┌────────────────────────┐
    │     6. TERMINATED      │◄─┤ 3. LOCK_ACQUIRING (k+1)│
    └────────────────────────┘  └────────────────────────┘
```

| State | Description | Invariant Target |
| :--- | :--- | :--- |
| **1. IDLE** | Worker connection checked out from pool. | Fresh connection state; zero leaked advisory locks. |
| **2. TIMEOUT_ARMED** | Transaction begun; `lock_timeout` and `statement_timeout` injected. | Injected `SET LOCAL lock_timeout = '1500ms'`. |
| **3. LOCK_ACQUIRING** | Requesting row or table locks. | IDs strictly sorted ascending; non-blocking try-locks for advisory mutexes. |
| **4. EXECUTING** | Heavyweight lock granted; mutating rows. | Zero slow non-DB network/LLM I/O inside the active transaction block. |
| **5. RECOVERY_BACKOFF** | Intercepted `40P01` (deadlock) or `55P03` (timeout). | Immediate rollback; wait `Uniform(0, min(1s, base * 2^k))` before retry. |
| **6. TERMINATED** | Transaction committed or permanently aborted. | All row and transaction-scoped advisory locks released atomically by kernel. |

---

## 5. Polyglot Production Implementations

### Go (`jackc/pgx/v5`) Production Lock Manager & Deadlock Retry Loop

```go
package db

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type LockManager struct {
	pool *pgxpool.Pool
}

func NewLockManager(pool *pgxpool.Pool) *LockManager {
	return &LockManager{pool: pool}
}

// TransferFundsCanonical executes a dual-account transfer with strict canonical order locking
// Mathematically eliminates Directed Wait-For Graph cycles and deadlocks
func (m *LockManager) TransferFundsCanonical(ctx context.Context, fromID, toID int64, amount int64) error {
	// Canonical sorting: always lock smaller account ID first!
	ids := []int64{fromID, toID}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })

	return m.ExecuteWithDeadlockRetry(ctx, func(ctx context.Context) error {
		tx, err := m.pool.Begin(ctx)
		if err != nil {
			return fmt.Errorf("begin tx: %w", err)
		}
		defer tx.Rollback(ctx)

		// 1. Arm Multi-Tier Timeout Ladder
		if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2000ms'; SET LOCAL statement_timeout = '8000ms'"); err != nil {
			return fmt.Errorf("set timeout ladder: %w", err)
		}

		// 2. Acquire row locks in canonical ascending order
		const lockSQL = `
			SELECT id, balance
			FROM accounts
			WHERE id = ANY($1)
			ORDER BY id ASC
			FOR UPDATE;
		`
		rows, err := tx.Query(ctx, lockSQL, ids)
		if err != nil {
			return fmt.Errorf("lock accounts: %w", err)
		}
		defer rows.Close()

		balances := make(map[int64]int64)
		for rows.Next() {
			var id, bal int64
			if err := rows.Scan(&id, &bal); err != nil {
				return err
			}
			balances[id] = bal
		}

		if balances[fromID] < amount {
			return fmt.Errorf("insufficient funds: balance %d < transfer %d", balances[fromID], amount)
		}

		// 3. Execute atomic mutations
		if _, err := tx.Exec(ctx, "UPDATE accounts SET balance = balance - $1 WHERE id = $2", amount, fromID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "UPDATE accounts SET balance = balance + $1 WHERE id = $2", amount, toID); err != nil {
			return err
		}

		return tx.Commit(ctx)
	}, 5)
}

// ExecuteWithDeadlockRetry wraps operations in an exponential backoff retry loop for 40P01 and 55P03
func (m *LockManager) ExecuteWithDeadlockRetry(ctx context.Context, op func(ctx context.Context) error, maxAttempts int) error {
	var err error
	baseDelay := 50 * time.Millisecond
	maxDelay := 1000 * time.Millisecond

	for attempt := 0; attempt < maxAttempts; attempt++ {
		err = op(ctx)
		if err == nil {
			return nil
		}

		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) {
			// 40P01: deadlock_detected | 55P03: lock_not_available | 40001: serialization_failure
			if pgErr.Code == "40P01" || pgErr.Code == "55P03" || pgErr.Code == "40001" {
				limit := min(maxDelay, baseDelay*time.Duration(1<<attempt))
				jitter := time.Duration(rand.Int63n(int64(limit)))

				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(jitter):
					continue
				}
			}
		}

		return err // Non-retryable error
	}
	return fmt.Errorf("exceeded max deadlock retries (%d): %w", maxAttempts, err)
}
```

### TypeScript (`Drizzle ORM` & Raw SQL) Production Advisory Lock

```typescript
import { sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

/**
 * Acquires a non-blocking transaction-scoped advisory lock in Drizzle ORM
 * Safely auto-released upon transaction completion; zero leak in PgBouncer
 */
export async function withTransactionAdvisoryLock<T>(
  db: NodePgDatabase,
  lockKey: number,
  work: (tx: any) => Promise<T>
): Promise<T> {
  return await db.transaction(async (tx) => {
    // 1. Arm lock timeout
    await tx.execute(sql`SET LOCAL lock_timeout = '1500ms'`);

    // 2. Try-lock without blocking indefinitely
    const lockRes = await tx.execute(sql`SELECT pg_try_advisory_xact_lock(${lockKey}) AS acquired`);
    const acquired = Boolean(lockRes.rows[0]?.acquired);

    if (!acquired) {
      throw new Error(`Resource lock [${lockKey}] currently held by another worker`);
    }

    return await work(tx);
  });
}
```

### SQL Diagnostic & Sentinel Queries

```sql
-- 1. Real-time Heavyweight Lock Contention Audit (Identify Blocking vs Blocked PIDs)
SELECT
  blocked_locks.pid AS blocked_pid,
  blocked_activity.usename AS blocked_user,
  blocking_locks.pid AS blocking_pid,
  blocking_activity.usename AS blocking_user,
  blocked_activity.query AS blocked_statement,
  blocking_activity.query AS current_statement_in_blocking_process,
  blocked_locks.locktype,
  blocked_locks.mode AS requested_mode,
  blocking_locks.mode AS held_mode,
  ROUND(EXTRACT(EPOCH FROM (NOW() - blocked_activity.query_start))::numeric, 2) AS wait_secs
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks
  ON blocking_locks.locktype = blocked_locks.locktype
  AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
  AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
  AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
  AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
  AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
  AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
  AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;

-- 2. Audit Foreign Keys Lacking Supporting B-Tree Indexes (Lock Escalation Risk)
SELECT
  c.conrelid::regclass AS child_table,
  c.conname AS foreign_key_name,
  ARRAY(
    SELECT attname FROM pg_attribute
    WHERE attrelid = c.conrelid AND attnum = ANY(c.conkey)
  ) AS fk_columns,
  c.confrelid::regclass AS parent_table
FROM pg_constraint c
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid
      AND (i.indkey::smallint[])[0:cardinality(c.conkey)-1] = c.conkey
  );

-- 3. Database Deadlock Rate Audit (pg_stat_database)
SELECT
  datname,
  deadlocks,
  conflicts,
  stats_reset
FROM pg_stat_database
WHERE datname = current_database();
```

---

## 6. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Industrial Boundary | Verification Tool / Command |
| :--- | :--- | :--- | :--- |
| **Gate 1** | Multi-Tier Timeout Ladder Enforcement | $T_{\text{lock}} \le 2\text{s}$, $T_{\text{stmt}} \le 10\text{s}$ | Verify via `SHOW lock_timeout;` and `SHOW statement_timeout;` |
| **Gate 2** | Fast Deadlock Cycle Detection | `deadlock_timeout <= 250ms` | Verify `SHOW deadlock_timeout;` returns $\le 250\text{ms}$ |
| **Gate 3** | Zero Unindexed Foreign Keys | $N_{\text{unindexed\_fks}} = 0$ | Query `pg_constraint` joined with `pg_index` returns 0 rows |
| **Gate 4** | Canonical Lock Acquisition Ordering | $\text{sort}(\text{IDs})$ ascending before SQL | Static code analysis verifying `ORDER BY ... ASC FOR UPDATE` |
| **Gate 5** | Transaction-Scoped Advisory Locks | Zero `pg_advisory_lock` in poolers | Grep codebase: strictly use `pg_advisory_xact_lock` |
| **Gate 6** | Automated Deadlock Retry Resilience | Intercepts `40P01` and `55P03` | Integration tests verifying jitter retry on simulated deadlocks |

---

## 7. Anti-Patterns vs Industrial Invariants

| Dimension | ❌ CATASTROPHIC LLM ANTI-PATTERN | ✅ AGENT ARSENAL INDUSTRIAL INVARIANT |
| :--- | :--- | :--- |
| **Lock Ordering** | Locking multiple rows in arbitrary or payload-provided order, creating wait-for cycles. | Canonical Total Ordering: IDs strictly sorted ascending prior to `FOR UPDATE` lock acquisition. |
| **DDL Lock Safety** | Executing `ALTER TABLE` or index drops with default `lock_timeout = 0`, blocking reads. | Enforce `SET LOCAL lock_timeout = '1500ms'`; abort and retry with jitter on `55P03`. |
| **Deadlock Timeout** | Leaving default `deadlock_timeout = 1000ms`, freezing connections for 1s on deadlocks. | Tune `deadlock_timeout = 100ms - 250ms`, slashing cycle detection latency by up to 90%. |
| **Advisory Locks** | Using session-level `pg_advisory_lock()`, leaking locks across PgBouncer pooled connections. | Mandatory transaction-scoped `pg_advisory_xact_lock()`, auto-released on commit/rollback. |
| **Foreign Key Indexes**| Omitting indexes on child foreign key columns, causing table locks on parent mutations. | Mandatory B-tree index on every foreign key column, verified via continuous CI schema linting. |
| **Lock Timeouts** | Running transactions without timeouts, freezing indefinitely when locks are contested. | Strict Timeout Ladder: $T_{\text{lock}} (1.5\text{s}) < T_{\text{statement}} (10\text{s}) < T_{\text{idle}} (5\text{s})$. |
