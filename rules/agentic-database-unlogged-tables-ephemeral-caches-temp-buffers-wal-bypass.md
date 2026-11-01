---
description: PostgreSQL UNLOGGED tables, ephemeral caching, high-throughput bulk staging, temp_buffers vs shared_buffers sizing, crash-recovery truncation (_init fork overwriting main fork), standby replication absence (0-row read replica trap), foreign key cross-boundary constraints, and transaction-mode PgBouncer batch isolation across Go (pgx/v5), TypeScript (drizzle/kysely/pg), Python (asyncpg/SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{unlogged,staging,cache,temp,temp_buffers,bulk,ingest,postgres,database,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database UNLOGGED Tables, Ephemeral Caches, High-Throughput Bulk Staging, temp_buffers Sizing & Crash Truncation Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design high-throughput data ingestion pipelines, ephemeral caching layers, ETL staging buffers, batch processing scratchpads, or temporary analytics stores across PostgreSQL (12–17+), Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `SQLAlchemy 2.0`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Streaming Replica 0-Row Mirage & Missing Table Trap" (where unlogged tables bypass Write-Ahead Logging [WAL] and therefore do NOT replicate to streaming read standbys, causing read replicas to query an empty `_init` fork and return 0 rows), the "Crash-Recovery Truncation & Silent Data Vaporization Disaster" (where PostgreSQL automatically resets the `main` fork of every unlogged table to an empty state during crash recovery, causing agents who store non-reconstructible business records or auth sessions in unlogged tables to lose 100% of data upon hardware reboot or OOM kill), the "Foreign Key Cross-Boundary Lockout Trap (`SQLSTATE 42809`)" (where PostgreSQL strictly forbids foreign keys between logged and unlogged tables, aborting migrations and schema alterations), the "Temporary Table Catalog Churn vs `temp_buffers` Memory Contention Trap" (where high-frequency `CREATE TEMP TABLE` calls generate tens of thousands of dead catalog tuples in `pg_class` and `pg_attribute` while inflating per-connection backend process memory), the "MVCC Dead Tuple Accumulation & Autovacuum Scale Factor Neglect" (where unlogged tables undergo rapid batch mutations without aggressive autovacuum tuning or atomic `TRUNCATE`, degrading sequential scans by 20x), and the "PgBouncer Transaction Pooling Session Collision & Cross-Batch Bleed" (where unlogged staging tables shared across pooled connections lack batch isolation or monotonic fencing) by establishing a strict 5-Tier Unlogged Table & Staging Governance Ladder, physical write amplification models, Little's Law throughput equations, an autonomous TypeScript `AgenticUnloggedTableGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state staging lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Unlogged Table Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, every standard relational table (`CREATE TABLE`) is a *logged table*: all data modifications (inserts, updates, deletes, page reorganizations) are written both to shared memory buffers and to the Write-Ahead Log (WAL) before transaction commit. This WAL stream is synchronously flushed to persistent media via `fsync()`, archived for Point-In-Time Recovery (PITR), and streamed across the network to hot standby replicas.

PostgreSQL provides **`UNLOGGED` tables** (`CREATE UNLOGGED TABLE`): these relations write directly to physical storage files (`main` fork), but **completely bypass WAL generation** (except for creating an empty initialization file `_init` fork). Bypassing WAL logging and its attendant `fsync()` barriers provides **$10\times - 50\times$ write throughput surges** for transient data, eliminates WAL archive volume, and avoids replication stream saturation.

However, because unlogged tables decouple physical page storage from WAL-based durability and streaming replication, autonomous coding agents consistently fall victim to 6 catastrophic failure modes:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             POSTGRESQL UNLOGGED TABLES & EPHEMERAL STAGING ARCHITECTURE                │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Streaming Replica 0-Row Mirage          │ • Strict Primary Writer Topology Fencing:  │
│   (Querying unlogged tables on read       │   Route ALL unlogged operations to primary │
│    replicas returns 0 rows; WAL is never  │   node (target_session_attrs=read-write);  │
│    streamed to standbys)                  │   prohibit replica pooler routing.         │
│ • Crash-Recovery Truncation Disaster      │ • Durability & Reconstructibility Bound:  │
│   (Unlogged tables are wiped to 0 rows    │   UNLOGGED tables MUST only hold           │
│    upon postmaster crash recovery; wipes  │   ephemeral, reconstructible data (RPO=∞); │
│    user balances or auth sessions)        │   never store persistent source-of-truth.  │
│ • Cross-Boundary Foreign Key Violations   │ • Disjoint Referential Integrity Fencing:  │
│   (Attempting FOREIGN KEY between logged  │   Logically decouple staging from durable  │
│    and unlogged tables; crashes 42809)    │   tables; enforce application batch IDs.   │
│ • Temp Table Catalog Churn & Memory Bloat │ • Pre-Created Session-Partitioned Tables:  │
│   (CREATE TEMP TABLE bloats pg_attribute; │   Pre-create permanent unlogged tables with│
│    temp_buffers bloats per-conn heap)     │   batch_id UUIDs; eliminate DDL catalog tax│
│ • MVCC Dead Tuple Bloat & Neglected Vacuum│ • Aggressive Autovacuum + Atomic TRUNCATE: │
│   (Unlogged updates generate dead tuples; │   Tune autovacuum_vacuum_scale_factor=0.01;│
│    monolithic DELETE bloats table 50x)    │   use TRUNCATE or DROP PARTITION for resets│
│ • PgBouncer Transaction Pool Collision    │ • Bounded Keyset Leases & Batch Isolation: │
│   (Concurrent workers query unfenced      │   Scope unlogged staging by batch_id UUID; │
│    staging table; corrupts tenant data)   │   run automated lease expiration janitors. │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Unlogged Table & Ephemeral Staging Catastrophes

#### Catastrophe 1: The Streaming Replica 0-Row Mirage & Missing Table Trap
Autonomous coding agents optimize read queries by routing them to standby read replicas (`target_session_attrs=read-only` or read-replica connection pools). When querying an `UNLOGGED` table on a read replica, PostgreSQL returns **0 rows** or raises query errors.
In PostgreSQL physical streaming replication, secondary standbys mirror the primary purely by replaying WAL records. Because modifications to `UNLOGGED` tables are never logged to WAL, standby replicas only contain the empty `_init` fork created at table initialization. Reading from an unlogged table on a standby is effectively reading an empty container. Agents misdiagnose this as missing data or ingestion failure, triggering infinite retry loops or hallucinated bug reports.

#### Catastrophe 2: The Crash-Recovery Truncation & Silent Data Vaporization
When the database crashes (due to power loss, Linux kernel OOM killer `SIGKILL` on a PostgreSQL backend, hardware faults, or `pg_ctl restart -m immediate`), PostgreSQL enters crash recovery mode upon restart. During startup recovery, PostgreSQL traverses the relation tree and **overwrites the `main` fork of every unlogged table and index with its empty `_init` fork**.
If an agent designs a shopping cart, active user authentication token cache, idempotency key registry, or uncommitted ledger in an `UNLOGGED` table without a persistent backing store, 100% of those records are permanently and silently vaporized upon reboot without an audit log.

#### Catastrophe 3: The Cross-Boundary Foreign Key Constraint Violation (`SQLSTATE 42809`)
PostgreSQL enforces a strict relational boundary:
- An `UNLOGGED` table **cannot** reference a logged table via a `FOREIGN KEY`.
- A logged table **cannot** reference an `UNLOGGED` table via a `FOREIGN KEY`.
Attempting either results in:
`ERROR: cannot reference relation "..." from unlogged relation` (`SQLSTATE 42809`) or `ERROR: cannot reference unlogged relation "..." from logged relation`.
Autonomous agents generating DDL migrations for staging or cache tables frequently append foreign keys referencing core production entities (such as `users(id)` or `tenants(id)`), causing migrations to abort instantly.

#### Catastrophe 4: The Temporary Table Catalog Churn vs `temp_buffers` Memory Contention Trap
When handling batch data uploads, agents frequently default to `CREATE TEMP TABLE staging_records (...)`. In production OLTP environments:
1. **Catalog Bloat**: Every `CREATE TEMP TABLE` writes entries into `pg_class`, `pg_attribute`, `pg_type`, `pg_depend`, and `pg_index`. When 1,000 requests per minute create and drop temp tables, system catalog dead tuples explode into gigabytes, filling the `shared_inval` queue, broadcasting cache invalidations, and locking concurrent planning threads.
2. **`temp_buffers` Heap Bloat**: Temporary tables use backend-private memory governed by `temp_buffers`. In high-concurrency pools (e.g. 300 connections with `temp_buffers = 32MB`), private process memory consumes $300 \times 32\text{MB} = 9.6\text{GB}$ of RAM outside `shared_buffers`, driving the OS into swap thrashing and postmaster OOM killer decapitation.
Unlogged tables reside in shared memory (`shared_buffers`), eliminating catalog churn when pre-created, but require partition or batch isolation to prevent buffer thrashing.

#### Catastrophe 5: The MVCC Dead Tuple Accumulation & Autovacuum Scale Factor Neglect
Unlogged tables operate under standard PostgreSQL Multi-Version Concurrency Control (MVCC). Every `UPDATE` writes a new tuple version, and every `DELETE` flags tuples as dead. Although unlogged writes bypass WAL, dead tuples still occupy physical 8KB disk blocks and B-Tree index pages.
Because unlogged tables are often used for high-velocity churn (e.g. updating progress counters, staging CSV rows), they generate millions of dead tuples per hour. Under default `autovacuum_vacuum_scale_factor = 0.20`, a 5-million-row unlogged table will not trigger autovacuum until 1 million rows are updated, causing table bloat to swell from 500MB to 15GB, destroying B-Tree fan-out, and degrading sequential scans by 20x. Furthermore, agents use `DELETE FROM staging` rather than `TRUNCATE`, multiplying dead tuple volume instead of executing instantaneous disk block reallocation.

#### Catastrophe 6: The PgBouncer Transaction Pooling Session Collision & Cross-Batch Bleed
In modern cloud architectures, applications connect through PgBouncer in transaction pooling mode (`pool_mode = transaction`). In this mode, multiple concurrent HTTP API requests or agent workers share backend PostgreSQL server connections.
If an unlogged table is defined as a flat staging area (`unlogged_import_staging`) and concurrent workers issue raw `INSERT` followed by `SELECT`, workers will read each other's interleaved records, causing cross-tenant data leakage, duplicate imports, and nondeterministic calculations. Without batch-scoped keys (`batch_id UUID`) and explicit lease expiries, unlogged tables become contaminated shared memory traps.

---

## 2. Mathematical Formalisms & Commit Storage Physics

### 2.1 Physical Storage Write Amplification Model

Let a database mutation write $S_{\text{heap}}$ bytes of tuple data and $S_{\text{index}}$ bytes of index modifications.
For a standard **Logged Table**, the total physical write amplification $\mathcal{W}_{\text{logged}}$ includes heap blocks, index blocks, Write-Ahead Log (WAL) records, Full-Page Writes (FPW) after checkpoints, and network replication bandwidth:

$$\mathcal{W}_{\text{logged}} = S_{\text{heap}} + S_{\text{index}} + S_{\text{WAL}} + S_{\text{FPW}} + S_{\text{replica}}$$

Where:
- $S_{\text{WAL}} \approx \alpha \cdot (S_{\text{heap}} + S_{\text{index}})$ with overhead factor $\alpha \in [1.2, 2.5]$.
- $S_{\text{FPW}} = \sum_{p=1}^{P} 8192 \text{ bytes}$ for every unique page modified after the first WAL checkpoint record.
- $S_{\text{replica}} = S_{\text{WAL}} \times N_{\text{standbys}}$ bytes transmitted across network sockets.

For an **`UNLOGGED` Table**, WAL generation, full-page writes, and standby replication are completely bypassed:

$$\mathcal{W}_{\text{unlogged}} = S_{\text{heap}} + S_{\text{index}}$$

The physical write reduction ratio $\Delta \mathcal{W}$ is:

$$\Delta \mathcal{W} = 1 - \frac{\mathcal{W}_{\text{unlogged}}}{\mathcal{W}_{\text{logged}}} = 1 - \frac{S_{\text{heap}} + S_{\text{index}}}{S_{\text{heap}} + S_{\text{index}} + S_{\text{WAL}} + S_{\text{FPW}} + N_{\text{standbys}} \cdot S_{\text{WAL}}}$$

Under high-concurrency batch ingestion ($S_{\text{FPW}} > 0, N_{\text{standbys}} \ge 1$), $\Delta \mathcal{W} \ge 0.75 - 0.92$, meaning unlogged tables reduce physical storage and network write bandwidth by **75% to 92%**.

### 2.2 Maximum Single-Thread Throughput Bound (Little's Law)

The transaction duration $T_{\text{tx}}$ for a write transaction of $N$ rows in a logged table is constrained by the storage barrier $T_{\text{fsync}}$:

$$T_{\text{tx, logged}} = T_{\text{parse}} + T_{\text{plan}} + N \cdot (T_{\text{heap}} + T_{\text{index}}) + T_{\text{WAL\_buffer}} + T_{\text{fsync}}$$

On NVMe or cloud SSDs (e.g. AWS EBS gp3), $T_{\text{fsync}} \approx 1.0\text{ms} - 4.0\text{ms}$. Even with optimal batching, single-threaded throughput is bounded by:

$$\text{TPS}_{\text{logged}} \le \frac{1}{T_{\text{tx, logged}}} \le \frac{1}{1.0\text{ms} + N \cdot 0.002\text{ms}} \approx 250 - 800 \text{ tx/sec}$$

For an **`UNLOGGED` Table**, because $T_{\text{fsync}} = 0$ and $T_{\text{WAL\_buffer}} = 0$:

$$T_{\text{tx, unlogged}} = T_{\text{parse}} + T_{\text{plan}} + N \cdot (T_{\text{heap}} + T_{\text{index}})$$

For $N = 100$ rows where memory tuple operations take $0.05\text{ms}$:

$$\text{TPS}_{\text{unlogged}} \approx \frac{1}{0.08\text{ms}} \approx 12,500 \text{ tx/sec}$$

This demonstrates a theoretical and empirical **$15\times - 50\times$ throughput advantage** for unlogged batch operations.

### 2.3 System Catalog Churn Differential Model

When agents dynamically execute `CREATE TEMP TABLE` at an API arrival rate $\lambda$ (queries per second):

$$N_{\text{dead\_catalog\_tuples}}(t) = \lambda \cdot t \cdot \left( k_{\text{class}} + k_{\text{attr}} \cdot C + k_{\text{type}} + k_{\text{depend}} + k_{\text{index}} \right)$$

Where $C$ is the number of columns in the temporary table, and constants $k \ge 1$.
For $C = 15$ columns and $\lambda = 50 \text{ req/sec}$:

$$N_{\text{dead\_catalog\_tuples}}(t) = 50 \cdot (1 + 15 + 2 + 15 + 2) = 1,750 \text{ dead tuples/sec}$$

In 1 hour ($3,600\text{s}$), the PostgreSQL system catalogs accumulate **$6,300,000$ dead catalog tuples**. Because autovacuum on system catalogs cannot perform lock-free truncation without `ACCESS EXCLUSIVE` locks on `pg_attribute`, planning queries degrade from $0.5\text{ms}$ to $>150\text{ms}$ across the entire cluster.
Conversely, pre-creating a permanent `UNLOGGED` table yields:

$$N_{\text{dead\_catalog\_tuples}}(t) = 0$$

Permanently protecting system catalog health and eliminates relcache invalidation storms.

### 2.4 Crash Loss Horizon & Reconstructibility Model

For an unlogged table $\mathcal{U}$, let $t_{\text{crash}}$ be the timestamp of an abrupt server termination. The recovery state satisfies:

$$\text{Rows}(\mathcal{U}, t_{\text{crash}} + \delta) = 0 \quad \forall \, \mathcal{U} \in \text{UnloggedRelations}$$

Therefore, the Recovery Point Objective (RPO) of an unlogged table is strictly infinite with respect to its own contents:

$$\text{RPO}(\mathcal{U}) = \infty$$

**The Reconstructibility Axiom**:
An entity $E$ is legally permissible in an `UNLOGGED` relation if and only if there exists a deterministic reconstruction function $\mathcal{R}$ operating on persistent storage $\mathcal{S}$ or external source $\mathcal{X}$ such that:

$$\mathcal{R}(\mathcal{S} \cup \mathcal{X}) \equiv E \quad \text{within time } T_{\text{reconstruct}} \le T_{\text{SLA}}$$

If $\nexists \mathcal{R}$, storing $E$ in an `UNLOGGED` table violates ACID durability invariants and is prohibited.

---

## 3. The 5-Tier Unlogged Table & Ephemeral Staging Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             THE 5-TIER UNLOGGED TABLE & STAGING GOVERNANCE LADDER                      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Durability Qualification & Domain Whitelist                                    │
│   • Strict mathematical verification of reconstructibility: RPO(table) = ∞             │
│   • Prohibit storing non-reconstructible data (ledgers, user credentials, orders)      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Read-Replica Topology Fencing & Primary Connection Routing                     │
│   • Route all unlogged DML/SELECT exclusively to primary (read-write) connections      │
│   • Hard-fail if driver attempts to execute unlogged queries on standby replicas       │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Zero-Catalog-Churn Pre-Created Session Partitioning                            │
│   • Permanently ban dynamic CREATE TEMP TABLE in hot API paths and worker loops        │
│   • Pre-create permanent UNLOGGED tables partitioned by batch_id UUID & created_at     │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Aggressive Autovacuum Tuning & Atomic TRUNCATE Lifecycle                       │
│   • Configure table-level autovacuum: autovacuum_vacuum_scale_factor = 0.01            │
│   • Mandatory TRUNCATE or DROP PARTITION for batch resets instead of monolithic DELETE │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Crash-Recovery Detection, Cold Cache Rehydration & Janitor Sentinels           │
│   • Startup hook detecting 0-row crash resets and triggering rehydration               │
│   • Autonomous keyset lease expiration janitor cleaning stale batches older than 1h   │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### Tier 0: Durability Qualification & Domain Whitelist
Before declaring any table `UNLOGGED`, the data architect or autonomous agent must certify that the data is **100% ephemeral or reconstructible**:
- **PERMITTED**:
  - Raw bulk file upload staging (CSV/Parquet ingestion before validation and ETL commit).
  - Materialized vector embedding caches where original text resides in a logged table.
  - LLM scratchpad reasoning memories and intermediate tool call buffers.
  - High-frequency rate-limiting sliding window counters and temporary session tokens backed by Redis.
  - Real-time aggregation rollups that can be recalculated from transactional logs.
- **FORBIDDEN**:
  - Financial ledgers, accounting journals, double-entry audit records.
  - User credentials, identity passwords, authorization leases.
  - Customer orders, invoice line items, idempotency token registries.
  - Legal audit trails, regulatory compliance event streams.

### Tier 1: Read-Replica Topology Fencing & Primary Connection Routing
Because unlogged tables do not emit WAL, streaming standbys cannot mirror their contents. Application code and database drivers must enforce topology routing:
- Query routing engines must guarantee that any SQL statement referencing an unlogged relation is dispatched exclusively to the primary writer node (`target_session_attrs=read-write`).
- Drivers must configure connection pool separation: `PrimaryPool` (for all unlogged writes and reads) vs `ReplicaPool` (strictly for logged read queries).
- CI static analysis gates must scan queries joining unlogged relations and assert they do not execute under read-replica annotations.

### Tier 2: Zero-Catalog-Churn Pre-Created Session Partitioning
To eliminate the destructive catalog bloat of `CREATE TEMP TABLE`:
- Define permanent, schema-migrated `UNLOGGED` tables during initial database deployment.
- Incorporate a mandatory `batch_id UUID NOT NULL` and `created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()` column into the unlogged table.
- Use composite indexes `(batch_id, record_id)` to isolate concurrent requests cleanly across PgBouncer transaction-mode connection pools.
- When single batches exceed 500,000 rows, use declarative unlogged partitioning (`PARTITION BY RANGE (created_at)` or `PARTITION BY HASH (batch_id)`), dropping old partition relations rather than deleting tuples.

### Tier 3: Aggressive Autovacuum Tuning & Atomic TRUNCATE Lifecycle
Unlogged tables must not fall victim to default, conservative vacuuming:
```sql
ALTER TABLE staging_unlogged_events SET (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_vacuum_threshold = 100,
  autovacuum_vacuum_cost_limit = 2000,
  autovacuum_analyze_scale_factor = 0.005
);
```
- For batch pipelines that process and discard data, **never execute `DELETE FROM table WHERE batch_id = $1`** on large single-tenant datasets.
- Use `TRUNCATE TABLE staging_unlogged_events` (instantaneous metadata-only pointer reset) when the table serves a dedicated single worker.
- For shared multi-tenant unlogged tables, delete rows using indexed cursor ranges and enforce `VACUUM (ANALYZE)` immediately post-batch, or drop the sub-partition.

### Tier 4: Crash-Recovery Detection, Cold Cache Rehydration & Janitor Sentinels
To handle unexpected node reboots gracefully:
- Implement an application startup health check that inspects unlogged cache tables. If an unlogged cache table that should contain warm embeddings or reference data is empty (`SELECT count(*) == 0` while the primary source is non-empty), execute deterministic cold-cache rehydration before opening the HTTP ingress traffic.
- Deploy an autonomous background janitor goroutine/worker that periodically runs:
  ```sql
  DELETE FROM staging_unlogged_batches 
  WHERE created_at < NOW() - INTERVAL '1 hour'
  LIMIT 5000;
  ```
  Guarded by `SET LOCAL lock_timeout = '2s'` to prevent lock queues and head-of-line blocking.

---

## 4. Production Code Implementations

### 4.1 Go (`jackc/pgx/v5`): Unlogged Bulk Staging Pipeline with Primary Writer Enforcement

```go
package staging

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// StagingRecord represents a transient ingested payload prior to validation and promotion.
type StagingRecord struct {
	BatchID   uuid.UUID
	RowIndex  int
	Payload   []byte
	CreatedAt time.Time
}

// UnloggedStagingManager manages high-velocity unlogged staging operations.
// Enforces primary node routing, batch isolation, and atomic lifecycle cleanup.
type UnloggedStagingManager struct {
	primaryPool *pgxpool.Pool // Strictly target_session_attrs=read-write
}

// NewUnloggedStagingManager initializes the manager with verified primary pool.
func NewUnloggedStagingManager(primaryPool *pgxpool.Pool) (*UnloggedStagingManager, error) {
	if primaryPool == nil {
		return nil, errors.New("primary connection pool must not be nil")
	}
	return &UnloggedStagingManager{primaryPool: primaryPool}, nil
}

// VerifyPrimaryWriter asserts that the active connection pool is pointing to the read-write primary.
// Unlogged tables CANNOT be read or written on read replicas (standbys will see 0 rows).
func (m *UnloggedStagingManager) VerifyPrimaryWriter(ctx context.Context) error {
	var isReadOnly bool
	err := m.primaryPool.QueryRow(ctx, "SHOW transaction_read_only").Scan(&isReadOnly)
	if err != nil {
		return fmt.Errorf("verify primary writer status: %w", err)
	}
	if isReadOnly {
		return errors.New("CRITICAL: Unlogged staging attempted on read replica; standbys do not receive unlogged WAL")
	}
	return nil
}

// IngestBatch performs high-throughput streaming bulk insert into the unlogged table using pgx.CopyFrom.
// Bypasses WAL generation, providing 20x throughput compared to standard logged inserts.
func (m *UnloggedStagingManager) IngestBatch(
	ctx context.Context,
	batchID uuid.UUID,
	records [][]byte,
) (int64, error) {
	if err := m.VerifyPrimaryWriter(ctx); err != nil {
		return 0, err
	}

	conn, err := m.primaryPool.Acquire(ctx)
	if err != nil {
		return 0, fmt.Errorf("acquire primary connection: %w", err)
	}
	defer conn.Release()

	// Build CopyFrom source to stream directly into shared buffers without SQL parsing overhead
	rows := make([][]any, len(records))
	now := time.Now().UTC()
	for i, r := range records {
		rows[i] = []any{batchID, i, r, now}
	}

	copySource := pgx.CopyFromRows(rows)

	// INVARIANT: Unlogged table staging_events pre-created with batch_id index
	count, err := conn.CopyFrom(
		ctx,
		pgx.Identifier{"staging_events"},
		[]string{"batch_id", "row_index", "payload", "created_at"},
		copySource,
	)
	if err != nil {
		return 0, fmt.Errorf("bulk copy to unlogged table failed: %w", err)
	}

	return count, nil
}

// ProcessAndPromote reads the unlogged batch, transforms it, and atomically commits to the logged table.
func (m *UnloggedStagingManager) ProcessAndPromote(
	ctx context.Context,
	batchID uuid.UUID,
	promoteFn func(ctx context.Context, tx pgx.Tx, batchID uuid.UUID) error,
) error {
	tx, err := m.primaryPool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin promotion transaction: %w", err)
	}
	defer tx.Rollback(context.WithoutCancel(ctx))

	// Fast lock timeout ensures staging cleanup never causes head-of-line blocking
	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2000ms'"); err != nil {
		return fmt.Errorf("set lock timeout: %w", err)
	}

	// Execute client validation and promotion into permanent logged tables
	if err := promoteFn(ctx, tx, batchID); err != nil {
		return fmt.Errorf("promotion logic failed: %w", err)
	}

	// Purge the processed batch from the unlogged table
	// For high-velocity systems, indexed deletion bounded by batch_id prevents dead-tuple runaway
	_, err = tx.Exec(ctx, "DELETE FROM staging_events WHERE batch_id = $1", batchID)
	if err != nil {
		return fmt.Errorf("clean up unlogged batch: %w", err)
	}

	return tx.Commit(ctx)
}

// RunJanitor periodically purges orphaned batches left behind by crashed or timed-out workers.
func (m *UnloggedStagingManager) RunJanitor(ctx context.Context, batchRetention time.Duration) (int64, error) {
	threshold := time.Now().UTC().Add(-batchRetention)

	tag, err := m.primaryPool.Exec(ctx, `
		DELETE FROM staging_events 
		WHERE created_at < $1
	`, threshold)
	if err != nil {
		return 0, fmt.Errorf("janitor purge failed: %w", err)
	}
	return tag.RowsAffected(), nil
}
```

---

### 4.2 TypeScript / Node.js (`Kysely` / `pg`): Type-Safe Unlogged Staging & Crash Detection

```typescript
import { Kysely, sql } from 'kysely';

export interface UnloggedStagingTable {
  batch_id: string;
  row_id: number;
  payload: Record<string, unknown>;
  created_at: Date;
}

export interface DatabaseSchema {
  staging_unlogged_payloads: UnloggedStagingTable;
  permanent_orders: { id: string; user_id: string; total: number; created_at: Date };
}

export class UnloggedStagingService {
  constructor(
    private readonly primaryDb: Kysely<DatabaseSchema>,
    private readonly replicaDb?: Kysely<DatabaseSchema>
  ) {}

  /**
   * INVARIANT 1: Topology Fencing.
   * UNLOGGED tables do not stream data to read replicas. Standbys will read 0 rows.
   * Enforce primary connection for all unlogged queries.
   */
  private async assertPrimaryConnection(): Promise<void> {
    const res = await sql<{ is_read_only: string }>`SHOW transaction_read_only`.execute(this.primaryDb);
    const readOnly = res.rows[0]?.is_read_only;
    if (readOnly === 'on') {
      throw new Error('SECURITY_ERROR: Unlogged table operations routed to read replica. UNLOGGED relations have empty _init forks on replicas.');
    }
  }

  /**
   * INVARIANT 2: Cold Crash Recovery Detection.
   * If postmaster suffered an abnormal termination, all unlogged tables were truncated to 0 rows.
   */
  public async detectCrashReset(): Promise<{ wasReset: boolean; rowCount: number }> {
    await this.assertPrimaryConnection();
    const result = await this.primaryDb
      .selectFrom('staging_unlogged_payloads')
      .select(this.primaryDb.fn.countAll().as('count'))
      .executeTakeFirstOrThrow();

    const count = Number(result.count);
    return {
      wasReset: count === 0,
      rowCount: count,
    };
  }

  /**
   * INVARIANT 3: High-Throughput Scoped Ingestion.
   * Pre-created unlogged tables bypass WAL fsync and system catalog bloat.
   */
  public async stageBatch(
    batchId: string,
    items: Array<Record<string, unknown>>
  ): Promise<number> {
    await this.assertPrimaryConnection();

    if (items.length === 0) return 0;

    const rows = items.map((payload, idx) => ({
      batch_id: batchId,
      row_id: idx,
      payload,
      created_at: new Date(),
    }));

    // Bounded chunk insertion to respect PostgreSQL max parameter limits
    const CHUNK_SIZE = 500;
    for (let i = 0; i < rows.length; i += CHUNK_SIZE) {
      const chunk = rows.slice(i, i + CHUNK_SIZE);
      await this.primaryDb
        .insertInto('staging_unlogged_payloads')
        .values(chunk)
        .execute();
    }

    return rows.length;
  }

  /**
   * INVARIANT 4: Atomic Promotion and Truncation.
   * Validates unlogged records, promotes to permanent table, and clears batch.
   */
  public async promoteBatch(
    batchId: string,
    processor: (records: UnloggedStagingTable[], trx: Kysely<DatabaseSchema>) => Promise<void>
  ): Promise<void> {
    await this.assertPrimaryConnection();

    await this.primaryDb.transaction().execute(async (trx) => {
      // Set short lock timeout to avoid queue stalls
      await sql`SET LOCAL lock_timeout = '2000ms'`.execute(trx);

      const stagedRecords = await trx
        .selectFrom('staging_unlogged_payloads')
        .selectAll()
        .where('batch_id', '=', batchId)
        .execute();

      if (stagedRecords.length === 0) {
        throw new Error(`Batch ${batchId} not found or lost to crash truncation.`);
      }

      // Delegate promotion logic
      await processor(stagedRecords as UnloggedStagingTable[], trx);

      // Clean up staged batch immediately
      await trx
        .deleteFrom('staging_unlogged_payloads')
        .where('batch_id', '=', batchId)
        .execute();
    });
  }
}
```

---

### 4.3 Python (`asyncpg`): Context-Managed Unlogged Staging Worker

```python
import asyncio
import json
import uuid
from typing import Any, List, Dict
import asyncpg

class UnloggedStagingPipeline:
    """
    Manages unlogged staging tables in PostgreSQL 14+ via asyncpg.
    Guarantees primary writer routing and eliminates temp table catalog churn.
    """

    def __init__(self, primary_dsn: str):
        self.dsn = primary_dsn
        self.pool: asyncpg.Pool = None

    async def connect(self):
        self.pool = await asyncpg.create_pool(
            dsn=self.dsn,
            min_size=5,
            max_size=20,
            server_settings={"application_name": "unlogged_staging_pipeline"}
        )

    async def verify_primary_writer(self, conn: asyncpg.Connection):
        """Invariant: UNLOGGED tables cannot be read/written on replicas (0-row trap)."""
        is_read_only = await conn.fetchval("SHOW transaction_read_only")
        if is_read_only == "on":
            raise RuntimeError(
                "CRITICAL: Unlogged table queries routed to read replica. "
                "Unlogged tables only have empty _init forks on replicas."
            )

    async def stage_records(self, batch_id: uuid.UUID, records: List[Dict[str, Any]]) -> int:
        """
        Stream records into pre-created UNLOGGED table using binary COPY.
        Bypasses WAL fsync barriers, surging ingest throughput by up to 30x.
        """
        async with self.pool.acquire() as conn:
            await self.verify_primary_writer(conn)

            rows = [
                (batch_id, idx, json.dumps(rec))
                for idx, rec in enumerate(records)
            ]

            # Binary copy directly into the unlogged relation's main fork
            await conn.copy_records_to_table(
                "staging_unlogged_records",
                records=rows,
                columns=["batch_id", "row_index", "payload"]
            )
            return len(rows)

    async def promote_batch(self, batch_id: uuid.UUID):
        """
        Promote verified staged records into durable logged production tables
        inside a single atomic transaction, then clean up the unlogged batch.
        """
        async with self.pool.acquire() as conn:
            await self.verify_primary_writer(conn)

            async with conn.transaction():
                # Enforce lock timeout ladder
                await conn.execute("SET LOCAL lock_timeout = '2000ms'")

                # Validate and insert into permanent table
                await conn.execute("""
                    INSERT INTO orders (id, user_id, amount, created_at)
                    SELECT 
                        (payload->>'id')::uuid,
                        (payload->>'user_id')::uuid,
                        (payload->>'amount')::numeric,
                        NOW()
                    FROM staging_unlogged_records
                    WHERE batch_id = $1
                    ON CONFLICT (id) DO NOTHING
                """, batch_id)

                # Purge unlogged batch to reclaim heap space
                await conn.execute("""
                    DELETE FROM staging_unlogged_records
                    WHERE batch_id = $1
                """, batch_id)

    async def close(self):
        if self.pool:
            await self.pool.close()
```

---

### 4.4 Rust (`sqlx`): Scoped Unlogged Staging Transaction Manager

```rust
use sqlx::{PgPool, Postgres, Transaction, Row};
use uuid::Uuid;
use chrono::{DateTime, Utc};
use serde_json::Value;

pub struct UnloggedStagingEngine {
    primary_pool: PgPool,
}

impl UnloggedStagingEngine {
    pub fn new(primary_pool: PgPool) -> Self {
        Self { primary_pool }
    }

    /// INVARIANT: Verify we are on primary read-write node. Standbys have empty _init forks.
    pub async fn verify_primary_writer(&self) -> Result<(), sqlx::Error> {
        let row = sqlx::query("SHOW transaction_read_only")
            .fetch_one(&self.primary_pool)
            .await?;
        let is_ro: String = row.try_get(0)?;
        if is_ro == "on" {
            return Err(sqlx::Error::Configuration(
                "UNLOGGED tables cannot be accessed on read-only replicas. Standbys will see 0 rows.".into()
            ));
        }
        Ok(())
    }

    /// Stages a batch of JSON records into the pre-created UNLOGGED relation.
    pub async fn stage_batch(
        &self,
        batch_id: Uuid,
        records: Vec<Value>,
    ) -> Result<usize, sqlx::Error> {
        self.verify_primary_writer().await?;

        let mut tx = self.primary_pool.begin().await?;

        // Fast lock timeout protects against lock queues
        sqlx::query("SET LOCAL lock_timeout = '2000ms'")
            .execute(&mut *tx)
            .await?;

        for (idx, record) in records.into_iter().enumerate() {
            sqlx::query!(
                r#"
                INSERT INTO staging_unlogged_events (batch_id, row_index, payload, created_at)
                VALUES ($1, $2, $3, NOW())
                "#,
                batch_id,
                idx as i32,
                record
            )
            .execute(&mut *tx)
            .await?;
        }

        tx.commit().await?;
        Ok(idx + 1)
    }

    /// Promotes staged records into permanent logged tables and purges unlogged batch.
    pub async fn promote_and_purge(
        &self,
        batch_id: Uuid,
    ) -> Result<u64, sqlx::Error> {
        self.verify_primary_writer().await?;

        let mut tx = self.primary_pool.begin().await?;

        sqlx::query("SET LOCAL lock_timeout = '2000ms'")
            .execute(&mut *tx)
            .await?;

        // Atomic promotion from unlogged staging to durable table
        let result = sqlx::query!(
            r#"
            INSERT INTO permanent_events (event_id, event_type, payload, processed_at)
            SELECT 
                (payload->>'event_id')::uuid,
                payload->>'event_type',
                payload,
                NOW()
            FROM staging_unlogged_events
            WHERE batch_id = $1
            ON CONFLICT (event_id) DO NOTHING
            "#,
            batch_id
        )
        .execute(&mut *tx)
        .await?;

        // Delete processed unlogged staging batch
        sqlx::query!(
            r#"
            DELETE FROM staging_unlogged_events
            WHERE batch_id = $1
            "#,
            batch_id
        )
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(result.rows_affected())
    }
}
```

---

## 5. Autonomous TypeScript Guard Engine

```typescript
/**
 * AgenticUnloggedTableGuardEngine
 * Static and runtime inspection engine enforcing the 5-Tier Unlogged Table Governance Ladder.
 * Detects replica routing traps, temp table catalog churn, missing autovacuum parameters,
 * and foreign key cross-boundary violations.
 */

export interface UnloggedTableAuditReport {
  isCompliant: boolean;
  score: number; // 0 - 100
  violations: Array<{
    code: string;
    severity: 'CRITICAL' | 'HIGH' | 'MEDIUM';
    message: string;
    remediation: string;
  }>;
  inspectedStatements: number;
}

export class AgenticUnloggedTableGuardEngine {
  /**
   * Audits a list of SQL DDL / DML statements against unlogged table invariants.
   */
  public auditSqlStatements(statements: string[]): UnloggedTableAuditReport {
    const violations: UnloggedTableAuditReport['violations'] = [];

    for (const sql of statements) {
      const normalized = sql.trim();

      // Check 1: Dynamic CREATE TEMP TABLE anti-pattern in hot paths
      if (/CREATE\s+(TEMP|TEMPORARY)\s+TABLE/i.test(normalized)) {
        violations.push({
          code: 'TEMP_TABLE_CATALOG_CHURN',
          severity: 'HIGH',
          message: 'Found dynamic "CREATE TEMP TABLE". In high-concurrency OLTP, this floods pg_catalog with dead tuples and exhausts temp_buffers.',
          remediation: 'Replace with pre-created permanent UNLOGGED table partitioned by batch_id UUID.',
        });
      }

      // Check 2: Foreign Key between unlogged and logged relations (SQLSTATE 42809)
      const isUnloggedCreate = /CREATE\s+UNLOGGED\s+TABLE/i.test(normalized);
      const hasForeignKey = /REFERENCES\s+[a-zA-Z0-9_.]+/i.test(normalized);
      if (isUnloggedCreate && hasForeignKey) {
        violations.push({
          code: 'UNLOGGED_FOREIGN_KEY_VIOLATION',
          severity: 'CRITICAL',
          message: 'UNLOGGED table declares a FOREIGN KEY REFERENCES constraint. PostgreSQL strictly forbids foreign keys between unlogged and logged tables (SQLSTATE 42809).',
          remediation: 'Remove the foreign key constraint. Enforce referential invariants logically in application code via batch IDs.',
        });
      }

      // Check 3: Missing Autovacuum Scale Factor on UNLOGGED table
      if (isUnloggedCreate) {
        const hasAutovacuumSetting = /autovacuum_vacuum_scale_factor/i.test(normalized);
        if (!hasAutovacuumSetting) {
          violations.push({
            code: 'UNLOGGED_AUTOVACUUM_NEGLECT',
            severity: 'MEDIUM',
            message: 'UNLOGGED table created without aggressive autovacuum tuning. High-churn unlogged tables suffer massive dead tuple bloat under default 20% scale factor.',
            remediation: 'Append "WITH (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 100)" to table definition.',
          });
        }
      }

      // Check 4: Unbounded DELETE instead of TRUNCATE on dedicated unlogged tables
      const isMonolithicDelete = /^DELETE\s+FROM\s+[a-zA-Z0-9_.]+\s*;?$/i.test(normalized);
      if (isMonolithicDelete) {
        violations.push({
          code: 'UNLOGGED_DELETE_BLOAT',
          severity: 'MEDIUM',
          message: 'Executing full DELETE on table without WHERE filter. Generates millions of dead MVCC tuples.',
          remediation: 'Use "TRUNCATE TABLE relation" to instantaneously reset the main fork without dead tuple generation.',
        });
      }
    }

    const criticalCount = violations.filter(v => v.severity === 'CRITICAL').length;
    const highCount = violations.filter(v => v.severity === 'HIGH').length;
    const mediumCount = violations.filter(v => v.severity === 'MEDIUM').length;

    const penalty = criticalCount * 40 + highCount * 20 + mediumCount * 10;
    const score = Math.max(0, 100 - penalty);

    return {
      isCompliant: criticalCount === 0 && highCount === 0,
      score,
      violations,
      inspectedStatements: statements.length,
    };
  }

  /**
   * Validates runtime database routing to prevent 0-row standby replica queries.
   */
  public assertRoutingTopology(isReadOnlyNode: boolean, queryReferencesUnlogged: boolean): void {
    if (isReadOnlyNode && queryReferencesUnlogged) {
      throw new Error(
        'TOPOLOGY_ERROR: Unlogged table queried on read replica. ' +
        'UNLOGGED tables bypass WAL and have empty _init forks on replicas, returning 0 rows.'
      );
    }
  }
}
```

---

## 6. The 6-State Unlogged Table Lifecycle Finite-State Machine (FSM)

```
             ┌──────────────────────────────────────────────────┐
             │                1. UNINITIALIZED                  │
             │   (Table DDL defined with autovacuum settings)   │
             └────────────────────────┬─────────────────────────┘
                                      │ Pre-deploy migration
                                      ▼
             ┌──────────────────────────────────────────────────┐
             │                2. STAGING_ACTIVE                 │
             │   (High-speed ingestion via COPY, WAL bypassed)  │
             └──────────┬────────────────────────────┬──────────┘
                        │ Normal promotion flow      │
                        │                            │ Unexpected crash / SIGKILL
                        ▼                            ▼
   ┌─────────────────────────────────────┐   ┌─────────────────────────────────────┐
   │        3. COMMITTED_LOCAL           │   │          5. CRASH_RESET             │
   │  (Batch validated, promoted to log) │   │ (_init fork overwrites main to 0)   │
   └────────────────────┬────────────────┘   └──────────────────┬──────────────────┘
                        │                                       │
                        │ Batch processed                       │ Application startup check
                        ▼                                       ▼
   ┌─────────────────────────────────────┐   ┌─────────────────────────────────────┐
   │        4. DRAINED_TRUNCATED         │   │         6. RECONSTRUCTING           │
   │ (TRUNCATE or indexed batch deleted) │   │ (Cold cache rehydration from source)│
   └────────────────────┬────────────────┘   └──────────────────┬──────────────────┘
                        │                                       │
                        └───────────────┬───────────────────────┘
                                        │ Ready for next batch
                                        ▼
                           [ Back to 2. STAGING_ACTIVE ]
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

To guarantee zero regression across automated agent modifications, all pull requests must pass the following 6 CI gates:

- [ ] **Gate 1: Non-Durability Classification Audit**: Every `UNLOGGED` relation is checked against the whitelist. No financial ledgers, user accounts, password hashes, or primary domain entities are declared `UNLOGGED`.
- [ ] **Gate 2: Read-Replica Zero-Query Static Analysis**: Static analyzer validates that all queries referencing `UNLOGGED` tables are strictly mapped to primary writer connection pools (`target_session_attrs=read-write`).
- [ ] **Gate 3: Temp Table Elimination in OLTP Hot Paths**: Linter asserts zero occurrences of dynamic `CREATE TEMP TABLE` or `CREATE TEMPORARY TABLE` inside API request handlers or worker goroutines.
- [ ] **Gate 4: Autovacuum Scale Factor Certification**: All unlogged table migration DDL files explicitly specify `autovacuum_vacuum_scale_factor <= 0.05` and `autovacuum_vacuum_threshold <= 200`.
- [ ] **Gate 5: Foreign Key Cross-Boundary Ban Check**: Static AST check verifies zero `REFERENCES` clauses linking unlogged tables to logged tables or vice versa (`SQLSTATE 42809` prevention).
- [ ] **Gate 6: Automated Crash Recovery & Janitor Test Gate**: Integration suite runs an immediate postmaster kill test (`kill -9`) and verifies that application startup gracefully detects unlogged table truncation and triggers cold cache rehydration without crashing.
