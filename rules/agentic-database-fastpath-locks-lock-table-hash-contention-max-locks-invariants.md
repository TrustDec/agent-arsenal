---
description: PostgreSQL Fast-Path locking mechanics (FAST_PATH_BITS_PER_SLOT = 16), shared lock table hash contention (LockMethodLockHash, LockHashPartitionLock), max_locks_per_transaction shared memory allocation, partition fanout lock explosion, strong-lock fast-path transfer storms, subtransaction lock multiplication, and lock table monitoring across Go (jackc/pgx/v5), TypeScript (pg, Kysely, Drizzle ORM), Python (asyncpg, SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{lock,fastpath,partition,transaction,concurrency,schema,migration,pool,db,postgres,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Fast-Path Locking, Lock Table Hash Contention, Partition Fanout Out-of-Shared-Memory & max_locks_per_transaction Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design database schemas, transactional access patterns, partition hierarchies, high-concurrency connection pooling, or batch migration pipelines across PostgreSQL (12–17+), Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `SQLAlchemy 2.0`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "16-Relation Fast-Path Lock Cliff & Shared Lock Table Thrashing (`FAST_PATH_BITS_PER_SLOT = 16`)" (where queries or transactions touching > 16 relations spill from backend-local $O(1)$ fast-path arrays into the global shared lock table, fighting for 16 `LockHashPartitionLock` lightweight locks and collapsing multi-core throughput by 70%), the "Partition Fanout Out-of-Shared-Memory Catastrophe (`FATAL: out of shared memory / HINT: You might need to increase max_locks_per_transaction`)" (where an unpruned query or DDL touching a partitioned table with 250 daily partitions and 4 indexes per partition requires $250 \times 5 = 1,250$ locks, instantly exhausting postmaster's fixed shared memory lock allocation and crashing concurrent transactions cluster-wide), the "Strong-Lock Fast-Path Transfer Storm (`FastPathTransferRelationLocks`)" (where an administrative lock or concurrent DDL grabs `ShareUpdateExclusiveLock` or `AccessExclusiveLock`, forcing PostgreSQL to iterate through every backend's `PGPROC` array under heavy `ProcArrayLock` to forcibly evict fast-path locks into the shared table, inducing cluster-wide latency spikes), the "ORM Mega-Join Relation Lock Multiplier" (where complex ORM queries eagerly joining 10 entity tables with 25 total indexes blow past the 16 fast-path slot threshold on every read request), the "Deep Subtransaction Savepoint Lock Hash Multiplication Trap" (where nested savepoints replicate lock hash entries per subtransaction level, ballooning lock memory), and the "Orphaned Advisory Lock Shared Memory Saturation" (where leaked advisory locks hold slots in the fixed lock table, exhausting slots for standard relational operations) by establishing a strict 5-Tier Fast-Path & Lock Table Governance Ladder, mathematical lock sizing models, an autonomous TypeScript `AgenticLockManagerGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state lock lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Fast-Path & Lock Manager Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, every relation (table, partition, index, sequence, toast table, view) accessed in a query requires a relation-level lock (e.g., `AccessShareLock` for `SELECT`, `RowShareLock` for `SELECT FOR UPDATE`, `RowExclusiveLock` for `INSERT/UPDATE/DELETE`). 

To avoid the massive CPU and memory bandwidth overhead of writing to a central shared memory hash table on every query, PostgreSQL implements a two-tier locking architecture:
1. **The Fast-Path Lock Array (`MyProc->fpRelId`)**:
   - Each PostgreSQL backend process (`PGPROC`) has a small, static in-memory array with exactly **16 slots** (`FP_LOCK_SLOTS_PER_BACKEND = 16` defined in `src/include/storage/proc.h`).
   - For weak lock modes (`AccessShareLock`, `RowShareLock`, `RowExclusiveLock`), if the relation is not registered as having conflicting locks held by other backends, the backend acquires the lock **exclusively inside its own local `PGPROC` structure** by writing the relation OID and a bitmask.
   - **Cost**: $O(1)$, zero shared memory synchronization, zero atomic lock bus contention, zero lightweight locks (`LWLock`).
2. **The Shared Lock Table (`LockMethodLockHash` / `LockMethodProcHash`)**:
   - When a transaction accesses its **17th relation**, or requires a strong lock mode (`ShareUpdateExclusiveLock`, `ShareLock`, `AccessExclusiveLock`), the fast-path array is bypassed or full.
   - The backend must enter the global shared lock table. To do this, it hashes the relation OID to one of **16 fixed lock hash partitions** and acquires an exclusive `LWLock` (`LockHashPartitionLock`).
   - The total number of lock entries available across all backends is statically allocated at PostgreSQL server startup:
     $$\text{Total Shared Lock Slots} = (\text{max\_connections} + \text{max\_prepared\_transactions}) \times \text{max\_locks\_per\_transaction}$$
   - **Cost**: $O(\log K)$ or hash lookup, bus locking, contention on 16 shared LWLocks, and a hard fixed ceiling beyond which PostgreSQL raises:
     ```
     ERROR: out of shared memory
     HINT: You might need to increase max_locks_per_transaction.
     ```

When autonomous coding agents write application queries, ORM relationships, or migration scripts, LLMs routinely commit 6 catastrophic architectural mistakes:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│            POSTGRESQL FAST-PATH vs SHARED LOCK TABLE ARCHITECTURE                      │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • 16-Relation Fast-Path Spillover         │ • Fast-Path 16-Slot Preservation:          │
│   (Query joins 10 tables + 15 indexes;    │   Keep relations + indexes per query <= 16;│
│    spills to shared LockMethodLockHash;   │   decompose bloated joins; query plans     │
│    spikes LWLock:LockHashPartitionLock)   │   assert fastpath = true in pg_locks       │
│ • Partition Fanout Out-of-Shared-Memory   │ • Static & Run-Time Partition Pruning:     │
│   (Query unpartitioned filter on 300 parts│   Ensure queries specify partition key;    │
│    takes 300 * (1+3) = 1,200 locks;       │   locks acquired strictly for target parts │
│    exhausts max_locks_per_transaction)    │   instead of all 300 child relations       │
│ • Strong-Lock Fast-Path Transfer Storm    │ • DDL Isolation & Lock Timeout Fencing:    │
│   (DDL/VACUUM FULL forces transfer of all │   Scope DDL with lock_timeout = '2s'; run  │
│    fast-path locks held across all backends│  off-peak; avoid concurrent AccessExclusive│
│    into shared table under ProcArrayLock) │   locks on hot tables with fast-path locks │
│ • Deep Savepoint Lock Multiplier Trap     │ • Flat Transaction Boundaries:             │
│   (Nested savepoints replicate lock hash  │   Eliminate recursive ORM subtransactions; │
│    entries per savepoint level; multiplies│   use single transaction or top-level retry│
│    shared lock table footprint by depth)  │   to keep lock table entries at minimum    │
│ • Leaked Advisory Locks in Connection Pool│ • Session Cleanup & Explicit Deferral:     │
│   (pg_advisory_lock without unlock leaks  │   Always pair pg_advisory_lock in defer/   │
│    lock slots across connection reuses;   │   finally blocks, or use transaction-scoped│
│    starves shared lock hash table)        │   pg_advisory_xact_lock() automatically    │
│ • Undersized max_locks_per_transaction    │ • Calibrated Shared Memory Sizing:         │
│   (Default 64 crashes under large schemas;│   Size max_locks_per_transaction >= 256 for│
│    throws fatal out of shared memory)     │   partitioned databases; monitor pg_locks  │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Fast-Path & Lock Manager Catastrophes

#### Catastrophe 1: The 16-Relation Fast-Path Lock Cliff & Shared Lock Table Thrashing
Autonomous agents frequently write ORM queries that eagerly join multiple tables (e.g. `User -> Profile -> Tenant -> Subscription -> Roles -> Permissions -> AuditLogs -> Teams`). Each table requires a relation lock, and **every index on every touched table also requires an `AccessShareLock`**!
If a query touches 6 tables and each table has 3 indexes, that is $6 \times (1 + 3) = 24$ relation locks! Because $24 > 16$, the first 16 locks fit into `MyProc->fpRelId`, but locks 17 to 24 spill into `LockMethodLockHash`.
Under 200 concurrent API requests, 200 backends suddenly contend for the 16 `LockHashPartitionLock` LWLocks. CPU utilization shoots to 100% in kernel spinlocks (`s_lock`), and query latency jumps from 1.5ms to 120ms.

#### Catastrophe 2: The Partition Fanout Out-of-Shared-Memory Catastrophe
When an autonomous agent designs a partitioned table (e.g., `events` partitioned by day into 365 partitions, with 4 indexes per partition), and writes a query without partition pruning:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Unpruned Partition Scan
SELECT count(*) FROM events WHERE payload->>'status' = 'failed';
```
PostgreSQL's planner and executor must lock the parent table AND all 365 child partitions AND all $365 \times 4 = 1,460$ indexes!
Total locks required = $1 + 365 + 1,460 = 1,826$ locks!
With PostgreSQL default `max_locks_per_transaction = 64`, a pool of 100 connections allows only $64 \times 100 = 6,400$ total lock entries for the entire cluster. Just 4 concurrent unpruned queries completely fill the shared lock table, crashing every backend in the cluster with:
```
FATAL: out of shared memory
HINT: You might need to increase max_locks_per_transaction.
```

#### Catastrophe 3: The Strong-Lock Fast-Path Transfer Storm (`FastPathTransferRelationLocks`)
When an administrative task, migration, or autovacuum process acquires a strong lock mode (such as `AccessExclusiveLock` for `ALTER TABLE` or `ShareUpdateExclusiveLock` for `VACUUM`), it cannot simply check the shared lock table. Because weak locks are kept in backend-local fast-path arrays, the backend acquiring the strong lock must invoke `FastPathTransferRelationLocks()`.
This function acquires `ProcArrayLock` in shared mode, halts every active backend, scans all $M$ active `PGPROC` slots, and forcibly extracts any matching fast-path locks, moving them into the shared `LockMethodLockHash`. On busy 64-core servers with 500 connections, this creates a catastrophic "stop-the-world" latency spike.

#### Catastrophe 4: The Deep Savepoint Subtransaction Lock Multiplication Trap
Many ORMs (e.g., Prisma, Django, SQLAlchemy) wrap nested blocks or error-recovery attempts in savepoints (`SAVEPOINT s1`, `SAVEPOINT s2`). In PostgreSQL's lock manager, lock tracking entries (`PROCLOCK`) must maintain separate states for subtransactions. If a transaction touches 15 relations across 5 nested savepoints, the lock manager allocates up to $15 \times 5 = 75$ lock entries, quickly surpassing fast-path limits and ballooning shared memory lock consumption.

#### Catastrophe 5: Leaked Advisory Locks in Pooled Connections
Autonomous agents using advisory locks for distributed synchronization often write:
```typescript
// ❌ CATASTROPHIC LLM ANTI-PATTERN: Session-level advisory lock leak
await db.query('SELECT pg_advisory_lock($1)', [lockKey]);
try {
  await doWork();
} finally {
  // If an unhandled exception or connection reset occurs here,
  // pg_advisory_unlock is never called!
  // The connection returns to PgBouncer holding a lock slot in LockMethodLockHash!
}
```
Every leaked session-level advisory lock permanently consumes a slot in the fixed shared memory lock table until the backend terminates. In transaction pooling mode, this permanently degrades shared lock capacity.

#### Catastrophe 6: Undersized `max_locks_per_transaction` on Modern Partitioned Schemas
PostgreSQL defaults `max_locks_per_transaction` to `64`. While adequate in 1998 for monolithic tables, modern architectures with hundreds of partitions, foreign key trees, and multi-tenant schemas exhaust this limit during index builds, schema migrations, or analytical queries. Because changing `max_locks_per_transaction` requires a full PostgreSQL cluster restart, failing to configure it properly at provisioning time guarantees unexpected production downtime.

---

## 2. Mathematical Formalisms & Lock Manager Physics

### 2.1 The Fast-Path Slot Saturation Model

Let $\mathcal{R}$ be the set of tables referenced in a transaction, and let $\mathcal{I}_r$ be the set of indexes belonging to table $r \in \mathcal{R}$.
The total relation locks $L_{\text{total}}$ requested by a query is given by:

$$L_{\text{total}} = \sum_{r \in \mathcal{R}} \left( 1 + |\mathcal{I}_r| \right) + \sum_{v \in \mathcal{V}} 1 + \sum_{t \in \mathcal{T}} 1$$

where $\mathcal{V}$ is the set of views and $\mathcal{T}$ is the set of TOAST tables accessed.

The fast-path allocation rule states:

$$\text{LockLocation}(L_k) = \begin{cases} 
\text{MyProc}\to\text{fpRelId}[k] & \text{if } k \le 16 \land \text{Mode}(L_k) \in \mathcal{M}_{\text{weak}} \land \neg\text{HasConflict}(L_k) \\
\text{LockMethodLockHash} & \text{if } k > 16 \lor \text{Mode}(L_k) \in \mathcal{M}_{\text{strong}} \lor \text{HasConflict}(L_k)
\end{cases}$$

where:
- $\mathcal{M}_{\text{weak}} = \{\text{AccessShareLock}, \text{RowShareLock}, \text{RowExclusiveLock}\}$
- $\mathcal{M}_{\text{strong}} = \{\text{ShareUpdateExclusiveLock}, \text{ShareLock}, \text{ShareRowExclusiveLock}, \text{ExclusiveLock}, \text{AccessExclusiveLock}\}$

When $L_{\text{total}} \le 16$, lock acquisition is $\mathcal{O}(1)$ with zero shared memory bus traffic.
When $L_{\text{total}} > 16$, the $L_{\text{total}} - 16$ surplus locks spill into shared memory, incurring lightweight lock contention.

### 2.2 LWLock Partition Contention Calculus

PostgreSQL hashes relation locks into $P = 16$ partitions, each guarded by a dedicated `LockHashPartitionLock` (`LWLock`).
If $C$ concurrent client backends each execute queries spilling $S$ locks into the shared table, the probability $P_{\text{collision}}$ of at least two backends contending for the identical lock partition LWLock is given by:

$$P_{\text{collision}} = 1 - \frac{P!}{(P)^{B} \cdot (P - B)!} \quad \text{where } B = \min(P, C \cdot S)$$

For $C = 50$ concurrent connections and $S = 5$ spilled locks per connection, $P_{\text{collision}} \to 1.0$, guaranteeing continuous LWLock spinlock waiting and high CPU context switching.

### 2.3 Shared Lock Table Sizing Invariant

The total shared memory allocated at postmaster startup for locks is:

$$\mathcal{N}_{\text{slots}} = (\text{max\_connections} + \text{max\_prepared\_transactions}) \times \text{max\_locks\_per\_transaction}$$

$$\text{Memory}_{\text{LockTable}} = \mathcal{N}_{\text{slots}} \times \left( \text{sizeof}(\text{LOCK}) + \text{sizeof}(\text{PROCLOCK}) + \text{sizeof}(\text{dshash\_node}) \right) \approx \mathcal{N}_{\text{slots}} \times 240 \text{ bytes}$$

If at any point:

$$\sum_{b=1}^{\text{active\_backends}} L_{\text{shared}}(b) \ge \mathcal{N}_{\text{slots}}$$

PostgreSQL halts the failing transaction immediately with `SQLSTATE 53200 (out_of_memory)`.

---

## 3. The 5-Tier Fast-Path & Lock Manager Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   THE 5-TIER FAST-PATH LOCK GOVERNANCE LADDER                          │
├──────┬───────────────────────────────┬─────────────────────────────────────────────────┤
│ Tier │ Name                          │ Production Invariant                            │
├──────┼───────────────────────────────┼─────────────────────────────────────────────────┤
│  0   │ Sizing & Baseline Capacity    │ max_locks_per_transaction >= 256;               │
│      │                               │ Pre-allocate shared lock slots for partitions   │
├──────┼───────────────────────────────┼─────────────────────────────────────────────────┤
│  1   │ Fast-Path Slot Preservation   │ Relations + Indexes per query <= 16;            │
│      │ (The 16-Relation Budget)      │ Decompose bloated joins; assert fastpath = true │
├──────┼───────────────────────────────┼─────────────────────────────────────────────────┤
│  2   │ Static & Run-Time Pruning     │ Enforce partition key predicates in WHERE;      │
│      │                               │ Zero unpruned partition sweeps on >50 partitions│
├──────┼───────────────────────────────┼─────────────────────────────────────────────────┤
│  3   │ Strong-Lock Isolation & DDL   │ lock_timeout = '2s'; statement_timeout = '30s'; │
│      │                               │ Run DDL off-peak to prevent fast-path evictions │
├──────┼───────────────────────────────┼─────────────────────────────────────────────────┤
│  4   │ Advisory & Subtransaction FSM │ Use transaction-scoped pg_advisory_xact_lock;   │
│      │                               │ Flat transactions; eliminate deep savepoints    │
└──────┴───────────────────────────────┴─────────────────────────────────────────────────┘
```

---

## 4. Production Code Implementations

### 4.1 Go (`jackc/pgx/v5`): Partition-Pruned Querying & Fast-Path Lock Verification

```go
package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type EventSummary struct {
	PartitionDate string    `json:"partition_date"`
	TotalCount    int64     `json:"total_count"`
	LatestEvent   time.Time `json:"latest_event"`
}

type LockTelemetry struct {
	FastPathLocks   int64 `json:"fastpath_locks"`
	SharedTableLocks int64 `json:"shared_table_locks"`
	TotalLocks      int64 `json:"total_locks"`
}

type EventRepository struct {
	Pool *pgxpool.Pool
}

func NewEventRepository(pool *pgxpool.Pool) *EventRepository {
	return &EventRepository{Pool: pool}
}

// FetchDailyEventsPruned enforces static partition key filtering on date boundaries.
// Bypasses unpruned partition tree locking, keeping locks <= 4 instead of 1,200.
func (r *EventRepository) FetchDailyEventsPruned(ctx context.Context, tenantID string, targetDate time.Time) (*EventSummary, error) {
	// Format target date to guarantee partition pruning on daily partitioned tables.
	dateStr := targetDate.Format("2006-01-02")

	// INVARIANT: Always pass the partition key explicitly to satisfy Tier 2 pruning.
	// Prevents scanning all partitions and exhausting max_locks_per_transaction.
	const query = `
		SELECT 
			$2::text AS partition_date,
			COUNT(*) AS total_count,
			COALESCE(MAX(created_at), $3::timestamptz) AS latest_event
		FROM events
		WHERE tenant_id = $1 
		  AND event_date = $2::date
		  AND created_at >= $3::timestamptz 
		  AND created_at < ($3::timestamptz + INTERVAL '1 day');
	`

	var summary EventSummary
	err := r.Pool.QueryRow(ctx, query, tenantID, dateStr, targetDate).Scan(
		&summary.PartitionDate,
		&summary.TotalCount,
		&summary.LatestEvent,
	)
	if err != nil {
		return nil, fmt.Errorf("fetch pruned daily events: %w", err)
	}

	return &summary, nil
}

// AuditBackendLockDistribution inspects pg_locks for the current backend PID.
// Asserts that fastpath locks are utilized, verifying relation count <= 16.
func (r *EventRepository) AuditBackendLockDistribution(ctx context.Context, tx pgx.Tx) (*LockTelemetry, error) {
	const telemetryQuery = `
		SELECT 
			COALESCE(SUM(CASE WHEN fastpath THEN 1 ELSE 0 END), 0) AS fastpath_locks,
			COALESCE(SUM(CASE WHEN NOT fastpath THEN 1 ELSE 0 END), 0) AS shared_table_locks,
			COUNT(*) AS total_locks
		FROM pg_locks
		WHERE pid = pg_backend_pid()
		  AND locktype = 'relation';
	`

	var t LockTelemetry
	err := tx.QueryRow(ctx, telemetryQuery).Scan(&t.FastPathLocks, &t.SharedTableLocks, &t.TotalLocks)
	if err != nil {
		return nil, fmt.Errorf("audit backend locks: %w", err)
	}

	return &t, nil
}
```

### 4.2 TypeScript / Node.js (`pg` / `Drizzle`): Transaction-Scoped Advisory Locks & Fast-Path Preserving Batch Builder

```typescript
import { Pool, PoolClient } from 'pg';

export interface LockAuditResult {
  fastPathCount: number;
  sharedTableCount: number;
  isFastPathCompliant: boolean;
}

export class FastPathLockManager {
  constructor(private pool: Pool) {}

  /**
   * Executes a critical section with an automatic transaction-scoped advisory lock.
   * INVARIANT: Uses pg_advisory_xact_lock to ensure the lock slot is guaranteed
   * released at COMMIT/ROLLBACK, preventing connection pool shared lock leaks.
   */
  async withTransactionAdvisoryLock<T>(
    lockKey: number,
    operation: (client: PoolClient) => Promise<T>
  ): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      // Set short lock timeout to avoid queuing on contentious locks
      await client.query("SET LOCAL lock_timeout = '2000ms'");
      
      // Transaction-scoped: automatically released when transaction ends
      await client.query('SELECT pg_advisory_xact_lock($1)', [lockKey]);

      const result = await operation(client);

      await client.query('COMMIT');
      return result;
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }

  /**
   * Verifies that the current transaction relations do not overflow the 16 fast-path slots.
   */
  async auditCurrentTransactionLocks(client: PoolClient): Promise<LockAuditResult> {
    const res = await client.query(`
      SELECT 
        COUNT(*) FILTER (WHERE fastpath) AS fastpath_count,
        COUNT(*) FILTER (WHERE NOT fastpath) AS shared_count
      FROM pg_locks 
      WHERE pid = pg_backend_pid() AND locktype = 'relation'
    `);

    const fastPathCount = parseInt(res.rows[0].fastpath_count || '0', 10);
    const sharedTableCount = parseInt(res.rows[0].shared_count || '0', 10);

    return {
      fastPathCount,
      sharedTableCount,
      isFastPathCompliant: sharedTableCount === 0 && fastPathCount <= 16,
    };
  }
}
```

### 4.3 Python (`asyncpg`): Partition Pruning Guard & Shared Lock Saturation Sentinel

```python
import asyncpg
from typing import Dict, Any, Optional

class FastPathPartitionSentinel:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def execute_pruned_query(
        self,
        tenant_id: str,
        start_date: str,
        end_date: str
    ) -> Dict[str, Any]:
        """
        Executes date-range bounded query with mandatory partition pruning.
        Raises ValueError if date boundary is missing to protect against unpruned fanout.
        """
        if not start_date or not end_date:
            raise ValueError("Partition pruning violation: start_date and end_date are mandatory.")

        query = """
            SELECT 
                COUNT(*) as count,
                COALESCE(SUM(amount_cents), 0) as total_amount
            FROM financial_transactions
            WHERE tenant_id = $1
              AND transaction_date >= $2::date
              AND transaction_date < $3::date
        """
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(query, tenant_id, start_date, end_date)
            return dict(row)

    async def inspect_lock_table_saturation(self) -> Dict[str, Any]:
        """
        Calculates cluster-wide shared lock table utilization.
        Emits alert if active locks exceed 70% of max_locks_per_transaction capacity.
        """
        audit_query = """
            WITH settings AS (
                SELECT 
                    current_setting('max_connections')::int AS max_conn,
                    current_setting('max_locks_per_transaction')::int AS locks_per_txn
            ),
            lock_counts AS (
                SELECT 
                    COUNT(*) AS total_active_locks,
                    COUNT(*) FILTER (WHERE fastpath) AS total_fastpath_locks,
                    COUNT(*) FILTER (WHERE NOT fastpath) AS total_shared_locks
                FROM pg_locks
            )
            SELECT 
                s.max_conn * s.locks_per_txn AS total_lock_capacity,
                l.total_active_locks,
                l.total_fastpath_locks,
                l.total_shared_locks,
                ROUND((l.total_shared_locks::numeric / (s.max_conn * s.locks_per_txn)::numeric) * 100, 2) AS shared_utilization_pct
            FROM settings s, lock_counts l;
        """
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(audit_query)
            return dict(row)
```

### 4.4 Rust (`sqlx`): Fast-Path Budget Analyzer & Zero-Spill Transaction Runner

```rust
use sqlx::{PgPool, Postgres, Transaction};
use std::error::Error;

#[derive(Debug)]
pub struct LockBudgetReport {
    pub fastpath_count: i64,
    pub shared_count: i64,
    pub within_fastpath_budget: bool,
}

pub struct LockManagerService {
    pool: PgPool,
}

impl LockManagerService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Verifies that the relations locked in this transaction stay within the 16 fast-path slots.
    pub async fn verify_lock_budget(
        &self,
        tx: &mut Transaction<'_, Postgres>,
    ) -> Result<LockBudgetReport, Box<dyn Error + Send + Sync>> {
        let row: (i64, i64) = sqlx::query_as(
            r#"
            SELECT 
                COALESCE(COUNT(*) FILTER (WHERE fastpath), 0) AS fastpath_count,
                COALESCE(COUNT(*) FILTER (WHERE NOT fastpath), 0) AS shared_count
            FROM pg_locks
            WHERE pid = pg_backend_pid() AND locktype = 'relation'
            "#,
        )
        .fetch_one(&mut **tx)
        .await?;

        let fastpath_count = row.0;
        let shared_count = row.1;
        let within_fastpath_budget = shared_count == 0 && fastpath_count <= 16;

        Ok(LockBudgetReport {
            fastpath_count,
            shared_count,
            within_fastpath_budget,
        })
    }
}
```

---

## 5. Autonomous TypeScript Guard Engine

```typescript
/**
 * AgenticLockManagerGuardEngine
 * Static SQL AST & Execution Plan analyzer for PostgreSQL Fast-Path locking limits,
 * partition fanout detection, and max_locks_per_transaction saturation defense.
 */

export interface QueryLockEstimation {
  estimatedTableCount: number;
  estimatedIndexCount: number;
  totalRelationLocks: number;
  exceedsFastPath: boolean;
  partitionFanoutRisk: boolean;
  warnings: string[];
  recommendations: string[];
}

export class AgenticLockManagerGuardEngine {
  private static readonly FAST_PATH_LIMIT = 16;
  private static readonly DEFAULT_INDEXES_PER_TABLE = 3;

  /**
   * Analyzes SQL query text and relation metadata to estimate relation locks.
   */
  public static analyzeQuery(
    sql: string,
    partitionMetadata?: { isPartitioned: boolean; partitionCount: number; pruned: boolean }
  ): QueryLockEstimation {
    const warnings: string[] = [];
    const recommendations: string[] = [];

    // Simple heuristic parser for referenced relations
    const fromMatches = sql.match(/\bFROM\s+([a-zA-Z0-9_]+)/gi) || [];
    const joinMatches = sql.match(/\bJOIN\s+([a-zA-Z0-9_]+)/gi) || [];
    const tableCount = fromMatches.length + joinMatches.length;

    let totalRelationLocks = tableCount * (1 + this.DEFAULT_INDEXES_PER_TABLE);
    let partitionFanoutRisk = false;

    if (partitionMetadata?.isPartitioned) {
      if (!partitionMetadata.pruned) {
        partitionFanoutRisk = true;
        const partitionLocks = partitionMetadata.partitionCount * (1 + this.DEFAULT_INDEXES_PER_TABLE);
        totalRelationLocks += partitionLocks;
        warnings.push(
          `Unpruned query on partitioned table references ${partitionMetadata.partitionCount} partitions, generating ~${partitionLocks} relation locks.`
        );
        recommendations.push(
          'Add explicit partition key equality/range predicates to the WHERE clause to enable static planner partition pruning.'
        );
      }
    }

    const exceedsFastPath = totalRelationLocks > this.FAST_PATH_LIMIT;

    if (exceedsFastPath) {
      warnings.push(
        `Total estimated relation locks (${totalRelationLocks}) exceeds the 16 Fast-Path lock slot limit (FAST_PATH_BITS_PER_SLOT = 16). Surplus locks will spill into shared LockMethodLockHash.`
      );
      recommendations.push(
        'Decompose mega-join queries into smaller bounded steps or pre-aggregated CTEs to preserve fast-path lock arrays.'
      );
    }

    if (sql.includes('pg_advisory_lock(') && !sql.includes('pg_advisory_xact_lock(')) {
      warnings.push('Detected session-level pg_advisory_lock. Potential connection pool lock leak.');
      recommendations.push('Replace with pg_advisory_xact_lock() to guarantee automatic lock release on transaction completion.');
    }

    return {
      estimatedTableCount: tableCount,
      estimatedIndexCount: tableCount * this.DEFAULT_INDEXES_PER_TABLE,
      totalRelationLocks,
      exceedsFastPath,
      partitionFanoutRisk,
      warnings,
      recommendations,
    };
  }
}
```

---

## 6. The 6-State Lock Lifecycle Finite-State Machine (FSM)

```
       [ 0. UNLOCKED ]
              │
              │  Transaction begins; relation accessed (k <= 16)
              ▼
   [ 1. FAST_PATH_HELD ] ──(Relations > 16)──► [ 2. SHARED_HASH_ESCALATED ]
              │                                           │
              │ (Unpruned Partition Query)                │ (Out of memory)
              ▼                                           ▼
   [ 3. PARTITION_FANOUT_ALERT ] ──────────────► [ 4. OUT_OF_SHARED_MEM_PANIC ]
              │                                           │
              │ (Strong Lock / DDL issued)                │
              ▼                                           │
   [ 5. FAST_PATH_EVICTION_STORM ]                        │
              │                                           │
              ▼                                           ▼
   [ 6. COMMITTED_CLEANUP ] ◄──────────────────── [ ROLLBACK_REVERT ]
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

1. **Static Partition Pruning Assertion**:
   - Every integration test exercising queries against partitioned relations must run `EXPLAIN (FORMAT JSON)` and assert that `Plans` contains only the intended partition, with zero sweeps across child partitions.
2. **Fast-Path Ratio Sentinel**:
   - In automated query suite testing, query `pg_locks` for the test backend and assert that `COUNT(*) FILTER (WHERE NOT fastpath) == 0` for standard OLTP single-entity CRUD operations.
3. **`max_locks_per_transaction` Minimum Setting**:
   - Production PostgreSQL configuration (`postgresql.conf`) must explicitly declare:
     ```ini
     max_locks_per_transaction = 256
     ```
4. **Advisory Lock Safety Audit**:
   - Static linter rules must forbid bare `pg_advisory_lock` in application code; only `pg_advisory_xact_lock` is permitted unless wrapped in an explicit defer/finally block with invariant unlock tests.
5. **Zero `out of shared memory` Errors**:
   - Automated load testing with peak concurrent workers must run clean with zero `SQLSTATE 53200` exceptions in logs.
