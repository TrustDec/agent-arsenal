---
description: PostgreSQL transaction snapshot export (pg_export_snapshot), snapshot import (SET TRANSACTION SNAPSHOT), parallel reader swarms, chunked ingestion workers, oldestxmin snapshot horizon pinning defense, autovacuum starvation mitigation, and CDC initial-sync coordination across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, psycopg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{snapshot,pg_export_snapshot,parallel_worker,export_snapshot,bulk_export,ingestion,etl,backfill,vacuum,oldestxmin,horizon}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/internal/worker/**/*.{go,rs},**/src/workers/**/*.{ts,js,py}
alwaysApply: false
---

# Agentic Database Transaction Snapshots, pg_export_snapshot(), Parallel Worker Swarms, Snapshot Horizon Pinning & Autovacuum Starvation Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to orchestrate multi-worker parallel data exports, distributed bulk ingestion pipelines, vector embedding backfills, table re-indexing swarms, cross-table analytical dumps, or CDC (Change Data Capture) initial syncs across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Snapshot Drift & Inconsistent Chunk Boundary Disaster" (where independent parallel worker connections open separate MVCC transactions at staggered timestamps, causing concurrent DML updates to move records across partition boundaries so that rows are duplicated or skipped entirely, and foreign key relations are captured in fractured, corrupt states), the "Snapshot Horizon Freezing & Cluster-Wide Autovacuum Starvation Meltdown" (where coordinator or worker transactions remain open for hours during slow LLM inference or network transfers, pinning `oldestxmin` / `backend_xmin` and completely barring autovacuum from cleaning dead tuples across the entire cluster, driving catastrophic table bloat and transaction ID wraparound emergencies), the "Coordinator Drop & Orphan Snapshot File Crash" (where coordinator transactions commit or drop connections before workers finish importing, triggering fatal `ERROR: snapshot "..." does not exist` exceptions), the "PgBouncer Transaction-Mode Multiplexing & Preamble Collision Trap" (where connection poolers or driver warmup probes like `SELECT 1` execute before `SET TRANSACTION SNAPSHOT`, aborting transactions with `ERROR: transaction snapshot was already established`), the "CDC Replication Slot Snapshot Desynchronization Gap" (where initial bulk table dumps fail to synchronize with `CREATE_REPLICATION_SLOT ... EXPORT_SNAPSHOT`, losing writes committed between dump start and WAL stream start), and the "Hot Standby Recovery Conflict Termination" (where read replica snapshot workers are abruptly killed with `terminating connection due to conflict with recovery` when primary WAL replay forces vacuum page prunes) by establishing a strict 5-Tier Snapshot & Worker Swarm Governance Ladder, formal tuple bloat accumulation physics, an autonomous TypeScript `AgenticDatabaseSnapshotExportEngine`, cross-runtime telemetry sentinels in Go, TypeScript, Python, and Rust, a 6-state snapshot lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Snapshot Export Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL MVCC (Multi-Version Concurrency Control), a transaction's visibility view is governed by a `SnapshotData` structure consisting of:
- `xmin`: Lowest transaction ID (XID) that was still active when the snapshot was taken. All tuples created by transactions with $XID < xmin$ are visible (if committed).
- `xmax`: Highest XID assigned plus one at snapshot creation. All tuples created by transactions with $XID \ge xmax$ are invisible.
- `xip[]`: Array of active transaction IDs between `xmin` and `xmax` at the moment of snapshot capture.
- `subxip[]`: Subtransaction IDs belonging to currently active top-level transactions.

When autonomous coding agents author parallel processing pipelines, chunked table migrators, or LLM embedding generators, agents instinctively spawn multiple concurrent threads, goroutines, or worker containers. However, lacking snapshot coordination primitives, agents trigger 6 catastrophic database failures:

### The 6 Snapshot Export & Parallel Worker Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: INDEPENDENT SNAPSHOT DRIFT ACROSS WORKERS
-- Agent divides 100M rows across 8 worker connections without snapshot coordination:
-- Worker 1: BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED; SELECT * FROM orders WHERE id BETWEEN 1 AND 12500000;
-- Worker 2: BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED; SELECT * FROM orders WHERE id BETWEEN 12500001 AND 25000000;
-- 💥 Catastrophe:
-- Worker 1 starts at T0. Worker 2 starts at T0 + 800ms.
-- During that 800ms window, an order at id=12500005 is updated and re-keyed or shifted in status,
-- or orders are inserted/deleted. Worker 1 missed it, Worker 2 either double-reads it or misses it.
-- Cross-table referential integrity is violated: payments read by Worker 1 do not match orders read by Worker 2!

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: PINNED OLDESTXMIN & VACUUM STARVATION MELTDOWN
-- Agent opens a single REPEATABLE READ transaction to orchestrate slow LLM embeddings:
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT id, content FROM documents WHERE status = 'pending';
-- Agent loops over 500,000 documents, calling OpenAI API (takes 6 hours).
-- Transaction remains open across the entire 6 hours.
-- 💥 Catastrophe:
-- pg_stat_activity shows backend_xmin pinned to XID 45,000,000.
-- Autovacuum CANNOT reclaim ANY dead tuple with xmax >= 45,000,000 anywhere in the cluster!
-- High-throughput OLTP tables (users, sessions, payments) generate 40GB of dead tuples per hour.
-- Table bloat explodes by 240GB. Buffer cache hit ratio drops from 99.4% to 42%. 100% CPU lockup!

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: PREMATURE COORDINATOR COMMIT / ORPHAN SNAPSHOT CRASH
-- Agent writes a Go or Node.js coordinator that exports a snapshot, pushes jobs to SQS/Celery, and exits:
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT pg_export_snapshot(); -- Returns '00000003-0000004B-1'
COMMIT; -- ❌ WRONG! Coordinator commits immediately after exporting!
-- 💥 Catastrophe:
-- PostgreSQL deletes $PGDATA/pg_snapshots/00000003-0000004B-1 immediately upon COMMIT.
-- When Celery / Goroutine workers start up and execute:
-- BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
-- SET TRANSACTION SNAPSHOT '00000003-0000004B-1';
-- Engine throws: ERROR: snapshot "00000003-0000004B-1" does not exist (SQLSTATE 08P01 / 25000).

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: PREAMBLE QUERY INJECTION IN CONNECTION POOLERS
-- Worker acquires connection from pool and driver issues warmup/telemetry query before snapshot import:
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT 1; -- ❌ Hidden healthcheck probe executed by ORM/Pooler!
SET TRANSACTION SNAPSHOT '00000003-0000004B-1';
-- 💥 Catastrophe:
-- PostgreSQL immediately throws:
-- ERROR: SET TRANSACTION SNAPSHOT must be called before any query (SQLSTATE 25P03).
-- Transaction is aborted. Entire parallel swarm collapses.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: CDC SLOT INITIAL SYNC DESYNCHRONIZATION GAP
-- Agent creates logical replication slot and dumps table concurrently without linking snapshot:
SELECT * FROM pg_create_logical_replication_slot('cdc_orders', 'pgoutput');
-- Agent uses regular pg_dump or SELECT * FROM orders;
-- 💥 Catastrophe:
-- Writes occurring between slot creation and dump execution are either duplicated
-- or lost when logical consumer begins streaming WAL from slot's restart_lsn.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: HOT STANDBY RECOVERY CONFLICT CANCELLATION
-- Agent runs parallel export workers on a read replica without hot_standby_feedback:
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET TRANSACTION SNAPSHOT '00000004-0000001A-1';
-- Standby receives WAL record from primary requesting page vacuum or lock.
-- 💥 Catastrophe:
-- Standby waits for max_standby_streaming_delay (e.g. 30s), then forcibly kills worker:
-- ERROR: canceling statement due to conflict with recovery (SQLSTATE 40001 / 57014).
```

### The 5-Tier Transaction Snapshot Governance Ladder

| Tier | Governance Layer | Core Invariant | Mechanical Implementation | Failure Modes Mitigated |
| :--- | :--- | :--- | :--- | :--- |
| **Tier 0** | **Coordinator Isolation & Lifecycle Binding** | Snapshot lifespan strictly tied to active transaction block | Open `REPEATABLE READ READ ONLY` transaction; hold open until barrier releases; export snapshot identifier | Catastrophe 1 (Drift), Catastrophe 3 (Orphan snapshot crash) |
| **Tier 1** | **Strict Zero-Preamble Snapshot Import** | `SET TRANSACTION SNAPSHOT` must precede all query statements | Dedicated un-pooled raw connection; bypass ORM pings; set snapshot immediately after `BEGIN` | Catastrophe 4 (Preamble collision / SQLSTATE 25P03) |
| **Tier 2** | **Snapshot Horizon & VACUUM Starvation Defense** | Oldest `xmin` pinned strictly bounded by time-to-live ($T_{\text{max}} \le 900\text{s}$) | Heartbeat watchdog monitoring `backend_xmin` and table dead-tuple bloat; emergency cancellation circuit breaker | Catastrophe 2 (Bloat meltdown & wraparound danger) |
| **Tier 3** | **Barrier-Synchronized Parallel Swarm Orchestration** | All $N$ workers import before data streaming; zero early worker exits | Atomic rendezvous barrier (CountDownLatch / Go `sync.WaitGroup` / Redis barrier); graceful batch streaming | Catastrophe 1 (Partition drift), Catastrophe 3 (Race crashes) |
| **Tier 4** | **Replication Slot Synchronization & CI DoD Gates** | CDC initial snapshot aligned with `confirmed_flush_lsn`; machine gates | `EXPORT_SNAPSHOT` parameter in slot creation; CI pipeline validating zero bloat leak and tuple identity | Catastrophe 5 (CDC gap), Catastrophe 6 (Replica conflict) |

---

## 2. Mathematical Physics: Snapshot Horizon Pinning & Vacuum Starvation

When a PostgreSQL backend holds an exported snapshot open in a `REPEATABLE READ` or `SERIALIZABLE` transaction, that backend's `xmin` becomes the lower boundary for tuple visibility cluster-wide:

$$\text{Global Horizon } X_{\text{horizon}} = \min_{k \in \text{backends}} (\text{backend\_xmin}_k)$$

### 2.1 The Dead Tuple Accumulation Integral

For any table $R$ undergoing continuous DML mutations with write throughput $\lambda_w$ (tuples modified/deleted per second) and average tuple size $\overline{S_{\text{tuple}}}$, the volume of dead tuples that PostgreSQL's autovacuum is **physically prohibited** from purging during snapshot lifetime $t$ is:

$$B_{\text{dead}}(t) = \int_0^t \sum_{i \in \text{tables}} \lambda_{w, i}(\tau) \cdot \overline{S_{\text{tuple}, i}} \, d\tau$$

If autovacuum attempts to vacuum table $R$, it inspects tuple commit statuses. For any dead tuple where:

$$\text{tuple.xmax} \ge X_{\text{horizon}}$$

PostgreSQL must retain the dead tuple because the transaction holding $X_{\text{horizon}}$ might still require access to the historical MVCC version.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       POSTGRESQL MVCC VISIBILITY HORIZON                     │
├─────────────────────────────────────────────────────────────────────────────┤
│  XID 1000      XID 1050               XID 1100               XID 1200       │
│  ──────────────┬──────────────────────┬──────────────────────┬───────────►  │
│                ▲                      ▲                                     │
│                │                      │                                     │
│        X_horizon (Pinned)      Current Active XIDs         Future XIDs      │
│   (pg_export_snapshot worker)                                               │
│                                                                             │
│  ◄─ PURGEABLE DEAD TUPLES ─►│◄──────── UNPURGEABLE DEAD TUPLES ──────────►  │
│    (tuple.xmax < X_horizon) │         (tuple.xmax >= X_horizon)             │
│    Vacuum CAN reclaim!      │         Vacuum FORCED TO RETAIN!              │
│                             │         ==> RAPID HEAP & INDEX BLOAT!         │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Time to Connection Pool & Memory Saturation Bounds

Let $C_{\text{pool}}$ be total application connection capacity, $\lambda_{\text{conn}}$ the rate of incoming client requests, and $T_{\text{query}}(B)$ the query duration as a function of heap bloat $B$:

$$T_{\text{query}}(B) \approx T_0 \cdot \left(1 + \frac{B}{V_{\text{heap}}}\right)$$

As bloat $B$ increases due to pinned $X_{\text{horizon}}$, queries that perform sequential scans or bitmap heap scans must read proportionally more dead pages from disk into `shared_buffers`, displacing active pages:

$$t_{\text{exhaust}} = \frac{C_{\text{pool}}}{\lambda_{\text{conn}} \cdot \max\left(0, 1 - \frac{1}{\mu \cdot T_{\text{query}}(B)}\right)}$$

When $T_{\text{query}}(B)$ exceeds client timeout thresholds, the connection pool exhausts completely in $t < 2.5\text{ seconds}$.

---

## 3. Production Snapshot Architecture & The 5 Invariants

### 3.1 Invariant 1: Dedicated Coordinator Connection Lifecycle

The snapshot identifier returned by `SELECT pg_export_snapshot()` is valid **only** as long as the exporting transaction is active:
- The coordinator connection must never be released back to a transaction-mode connection pool while child workers are operating.
- The coordinator transaction must be explicitly declared as:
  ```sql
  BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
  SELECT pg_export_snapshot();
  ```
- The coordinator holds this transaction open using an application-level barrier or heartbeat until all child workers have imported the snapshot and completed their reads, or until a hard TTL timeout triggers.

### 3.2 Invariant 2: Zero-Preamble Worker Snapshot Import Protocol

To import a snapshot in a worker backend:
- The worker must establish a clean connection.
- The worker must issue:
  ```sql
  BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
  SET TRANSACTION SNAPSHOT '00000003-0000004B-1';
  ```
- **Zero preceding statements**: Any `SELECT`, `SET timezone`, `SHOW`, or ORM keepalive probe executed after `BEGIN` and before `SET TRANSACTION SNAPSHOT` creates an internal transaction snapshot immediately, causing `SET TRANSACTION SNAPSHOT` to throw SQLSTATE `25P03`.

### 3.3 Invariant 3: Pinned Horizon Time-to-Live (TTL) & Circuit Breaker

To prevent cluster-wide autovacuum starvation:
- No transaction holding an exported snapshot may run longer than $T_{\text{TTL}} = 900\text{ seconds}$ ($15\text{ minutes}$) under OLTP production workloads.
- Background sentinels must query `pg_stat_activity` for `backend_xmin`:
  ```sql
  SELECT pid, client_addr, now() - xact_start AS duration, backend_xmin
  FROM pg_stat_activity
  WHERE backend_xmin IS NOT NULL AND now() - xact_start > interval '15 minutes';
  ```
- If duration exceeds $T_{\text{TTL}}$, the coordinator or sentinel must terminate the transaction via `pg_cancel_backend(pid)` or `pg_terminate_backend(pid)` before table bloat causes cascading outages.

### 3.4 Invariant 4: Chunked Sargable Read Splitting Across Parallel Workers

When workers read large tables using the imported snapshot:
- Workers must split work by an immutable, strictly monotonic indexed column (e.g., `id` or composite `(created_at, id)`).
- Never split by non-sargable offsets (`LIMIT 10000 OFFSET 5000000`).
- Because all workers share the exact same exported snapshot, each worker queries disjoint primary key ranges:
  ```sql
  -- Worker 1:
  SELECT * FROM documents WHERE id >= 1 AND id < 1000000;
  -- Worker 2:
  SELECT * FROM documents WHERE id >= 1000000 AND id < 2000000;
  ```
- Visibility is 100% frozen at the snapshot's point in time. Even if concurrent transactions insert or update rows in `documents`, no worker will see phantom rows, double-read records, or encounter deadlocks.

### 3.5 Invariant 5: Logical Replication Slot Initial Sync Alignment

When building Change Data Capture (CDC) pipelines:
- Never dump table data independently of replication slot creation.
- Execute replication command:
  ```sql
  CREATE_REPLICATION_SLOT cdc_slot LOGICAL pgoutput EXPORT_SNAPSHOT;
  ```
- Capture the returned `snapshot_name` and `consistent_point` (LSN).
- Dispatch the table export workers using `SET TRANSACTION SNAPSHOT '<snapshot_name>'`.
- Once initial table export completes, begin logical replication streaming starting strictly from the recorded `consistent_point` LSN. Zero writes are skipped and zero writes are duplicated.

---

## 4. Production TypeScript Engine: AgenticDatabaseSnapshotExportEngine

The following production engine coordinates an autonomous multi-worker parallel read swarm using `pg_export_snapshot()`, an atomic countdown barrier, a horizon TTL watchdog, and zero-preamble worker initialization:

```typescript
// agentic-database-snapshot-engine.ts
import { Pool, PoolClient } from 'pg';
import { EventEmitter } from 'events';

export interface SnapshotEngineConfig {
  connectionString: string;
  workerCount: number;
  maxSnapshotDurationMs: number; // e.g., 900,000ms (15 mins)
  chunkSize: number;
}

export interface ChunkRange {
  minId: bigint;
  maxId: bigint;
}

export class AgenticDatabaseSnapshotExportEngine extends EventEmitter {
  private coordinatorPool: Pool;
  private workerPool: Pool;
  private config: SnapshotEngineConfig;
  private isTerminated: boolean = false;

  constructor(config: SnapshotEngineConfig) {
    super();
    this.config = config;
    // Dedicated unpooled or 1-size pool for coordinator to prevent connection recycling
    this.coordinatorPool = new Pool({
      connectionString: config.connectionString,
      max: 1,
      idleTimeoutMillis: 0,
    });
    // Worker pool sized to exact worker count
    this.workerPool = new Pool({
      connectionString: config.connectionString,
      max: config.workerCount,
      idleTimeoutMillis: 10000,
    });
  }

  /**
   * Orchestrates parallel chunked export with guaranteed point-in-time snapshot parity.
   */
  public async executeParallelExport<T>(
    tableName: string,
    idColumn: string,
    processChunk: (records: T[], workerId: number) => Promise<void>
  ): Promise<{ totalProcessed: bigint; durationMs: number }> {
    const startTime = Date.now();
    let coordinatorClient: PoolClient | null = null;
    let snapshotId: string | null = null;
    let ttlTimer: NodeJS.Timeout | null = null;

    try {
      // Step 1: Acquire dedicated coordinator connection
      coordinatorClient = await this.coordinatorPool.connect();

      // Step 2: Open coordinator REPEATABLE READ READ ONLY transaction
      await coordinatorClient.query('BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY');

      // Step 3: Export snapshot
      const exportRes = await coordinatorClient.query<{ pg_export_snapshot: string }>(
        'SELECT pg_export_snapshot()'
      );
      snapshotId = exportRes.rows[0].pg_export_snapshot;
      this.emit('snapshot_exported', { snapshotId, timestamp: new Date().toISOString() });

      // Step 4: Calculate table key bounds using coordinator's snapshot
      const boundsRes = await coordinatorClient.query<{ min_id: string; max_id: string }>(`
        SELECT
          COALESCE(MIN(${idColumn}), 0)::text AS min_id,
          COALESCE(MAX(${idColumn}), 0)::text AS max_id
        FROM ${tableName}
      `);

      const minId = BigInt(boundsRes.rows[0].min_id);
      const maxId = BigInt(boundsRes.rows[0].max_id);

      if (maxId === 0n && minId === 0n) {
        await coordinatorClient.query('COMMIT');
        return { totalProcessed: 0n, durationMs: Date.now() - startTime };
      }

      // Step 5: Start Horizon Pinning Watchdog (Prevents autovacuum starvation)
      const abortController = new AbortController();
      ttlTimer = setTimeout(() => {
        this.emit('horizon_timeout_warning', {
          snapshotId,
          elapsedMs: this.config.maxSnapshotDurationMs,
        });
        abortController.abort();
      }, this.config.maxSnapshotDurationMs);

      // Step 6: Generate chunk partitions
      const chunks = this.partitionRanges(minId, maxId, BigInt(this.config.chunkSize));

      // Step 7: Launch worker swarm with barrier rendezvous
      let totalProcessed = 0n;
      let chunkIndex = 0;

      const workerPromises = Array.from({ length: this.config.workerCount }, async (_, workerId) => {
        let workerClient: PoolClient | null = null;
        try {
          workerClient = await this.workerPool.connect();

          // CRITICAL INVARIANT: Zero preamble statements!
          // Issue BEGIN followed immediately by SET TRANSACTION SNAPSHOT.
          await workerClient.query('BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY');
          await workerClient.query(`SET TRANSACTION SNAPSHOT '${snapshotId}'`);

          this.emit('worker_snapshot_attached', { workerId, snapshotId });

          while (!abortController.signal.aborted) {
            let currentChunk: ChunkRange | null = null;
            // Atomic chunk pull
            if (chunkIndex < chunks.length) {
              currentChunk = chunks[chunkIndex++];
            } else {
              break; // All chunks dispatched
            }

            const query = `
              SELECT *
              FROM ${tableName}
              WHERE ${idColumn} >= $1 AND ${idColumn} < $2
              ORDER BY ${idColumn} ASC
            `;

            const res = await workerClient.query<T>(query, [
              currentChunk.minId.toString(),
              currentChunk.maxId.toString(),
            ]);

            if (res.rows.length > 0) {
              await processChunk(res.rows, workerId);
              totalProcessed += BigInt(res.rows.length);
            }
          }

          if (abortController.signal.aborted) {
            throw new Error(`Worker ${workerId} aborted: Snapshot TTL limit exceeded.`);
          }

          await workerClient.query('COMMIT');
        } catch (err) {
          if (workerClient) {
            await workerClient.query('ROLLBACK').catch(() => {});
          }
          throw err;
        } finally {
          if (workerClient) {
            workerClient.release();
          }
        }
      });

      // Await all workers
      await Promise.all(workerPromises);

      // Step 8: Safely commit coordinator transaction to release snapshot and horizon
      await coordinatorClient.query('COMMIT');
      this.emit('snapshot_released', { snapshotId, totalProcessed: totalProcessed.toString() });

      return { totalProcessed, durationMs: Date.now() - startTime };
    } catch (error) {
      if (coordinatorClient) {
        await coordinatorClient.query('ROLLBACK').catch(() => {});
      }
      this.emit('snapshot_export_error', { snapshotId, error });
      throw error;
    } finally {
      if (ttlTimer) clearTimeout(ttlTimer);
      if (coordinatorClient) coordinatorClient.release();
    }
  }

  private partitionRanges(minId: bigint, maxId: bigint, chunkSize: bigint): ChunkRange[] {
    const ranges: ChunkRange[] = [];
    let current = minId;
    while (current <= maxId) {
      const next = current + chunkSize;
      ranges.push({ minId: current, maxId: next });
      current = next;
    }
    return ranges;
  }

  public async close(): Promise<void> {
    this.isTerminated = true;
    await this.coordinatorPool.end();
    await this.workerPool.end();
  }
}
```

---

## 5. Cross-Runtime Telemetry Sentinels

### 5.1 Go (`jackc/pgx/v5`): Coordinator Barrier & Zero-Preamble Worker Swarm

```go
package snapshot

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type WorkerTask struct {
	MinID int64
	MaxID int64
}

type SwarmResult struct {
	TotalProcessed int64
	Duration       time.Duration
}

// ExecuteConsistentParallelSwarm exports a snapshot on coordinator and imports into N workers.
func ExecuteConsistentParallelSwarm(
	ctx context.Context,
	pool *pgxpool.Pool,
	tableName string,
	idColumn string,
	workerCount int,
	chunkSize int64,
	handler func(ctx context.Context, rows []map[string]any, workerID int) error,
) (*SwarmResult, error) {
	start := time.Now()

	// 1. Establish coordinator connection
	coordConn, err := pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to acquire coordinator connection: %w", err)
	}
	defer coordConn.Release()

	// 2. Open Repeatable Read transaction on coordinator
	coordTx, err := coordConn.BeginTx(ctx, pgx.TxOptions{
		IsoLevel:   pgx.RepeatableRead,
		AccessMode: pgx.ReadOnly,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to begin coordinator tx: %w", err)
	}
	defer coordTx.Rollback(ctx)

	// 3. Export Snapshot
	var snapshotID string
	err = coordTx.QueryRow(ctx, "SELECT pg_export_snapshot()").Scan(&snapshotID)
	if err != nil {
		return nil, fmt.Errorf("failed to export snapshot: %w", err)
	}
	slog.Info("Exported PostgreSQL snapshot", "snapshot_id", snapshotID)

	// 4. Query table bounds inside coordinator's snapshot
	var minID, maxID int64
	boundsQuery := fmt.Sprintf("SELECT COALESCE(MIN(%s), 0), COALESCE(MAX(%s), 0) FROM %s", idColumn, idColumn, tableName)
	err = coordTx.QueryRow(ctx, boundsQuery).Scan(&minID, &maxID)
	if err != nil {
		return nil, fmt.Errorf("failed to scan table bounds: %w", err)
	}

	if minID == 0 && maxID == 0 {
		_ = coordTx.Commit(ctx)
		return &SwarmResult{TotalProcessed: 0, Duration: time.Since(start)}, nil
	}

	// 5. Partition chunks into channel
	tasks := make(chan WorkerTask, (maxID-minID)/chunkSize+1)
	for cur := minID; cur <= maxID; cur += chunkSize {
		tasks <- WorkerTask{MinID: cur, MaxID: cur + chunkSize}
	}
	close(tasks)

	// 6. Horizon watchdog context (max 15 mins to avoid autovacuum starvation)
	watchdogCtx, cancelWatchdog := context.WithTimeout(ctx, 15*time.Minute)
	defer cancelWatchdog()

	var wg sync.WaitGroup
	var totalProcessed atomic.Int64
	errChan := make(chan error, workerCount)

	// 7. Spawn parallel workers
	for w := 0; w < workerCount; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()

			wConn, err := pool.Acquire(watchdogCtx)
			if err != nil {
				errChan <- fmt.Errorf("worker %d failed to acquire conn: %w", workerID, err)
				return
			}
			defer wConn.Release()

			// ZERO PREAMBLE INVARIANT:
			// Begin tx with matching RepeatableRead isolation level
			wTx, err := wConn.BeginTx(watchdogCtx, pgx.TxOptions{
				IsoLevel:   pgx.RepeatableRead,
				AccessMode: pgx.ReadOnly,
			})
			if err != nil {
				errChan <- fmt.Errorf("worker %d failed to begin tx: %w", workerID, err)
				return
			}
			defer wTx.Rollback(watchdogCtx)

			// Import snapshot immediately
			importQuery := fmt.Sprintf("SET TRANSACTION SNAPSHOT '%s'", snapshotID)
			if _, err := wTx.Exec(watchdogCtx, importQuery); err != nil {
				errChan <- fmt.Errorf("worker %d failed to set snapshot: %w", workerID, err)
				return
			}

			// Process assigned chunks
			for task := range tasks {
				select {
				case <-watchdogCtx.Done():
					errChan <- fmt.Errorf("worker %d aborted by watchdog context: %w", workerID, watchdogCtx.Err())
					return
				default:
				}

				chunkSQL := fmt.Sprintf("SELECT * FROM %s WHERE %s >= $1 AND %s < $2 ORDER BY %s ASC",
					tableName, idColumn, idColumn, idColumn)
				rows, err := wTx.Query(watchdogCtx, chunkSQL, task.MinID, task.MaxID)
				if err != nil {
					errChan <- fmt.Errorf("worker %d chunk query failed: %w", workerID, err)
					return
				}

				var batch []map[string]any
				for rows.Next() {
					values, err := rows.Values()
					if err != nil {
						rows.Close()
						errChan <- err
						return
					}
					fieldDescs := rows.FieldDescriptions()
					rowMap := make(map[string]any, len(values))
					for i, fd := range fieldDescs {
						rowMap[fd.Name] = values[i]
					}
					batch = append(batch, rowMap)
				}
				rows.Close()

				if len(batch) > 0 {
					if err := handler(watchdogCtx, batch, workerID); err != nil {
						errChan <- fmt.Errorf("worker %d handler failed: %w", workerID, err)
						return
					}
					totalProcessed.Add(int64(len(batch)))
				}
			}

			if err := wTx.Commit(watchdogCtx); err != nil {
				errChan <- fmt.Errorf("worker %d commit failed: %w", workerID, err)
			}
		}(w)
	}

	wg.Wait()
	close(errChan)

	if len(errChan) > 0 {
		return nil, <-errChan
	}

	// 8. Safely commit coordinator transaction to release snapshot and unpin oldestxmin
	if err := coordTx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("failed to commit coordinator tx: %w", err)
	}

	return &SwarmResult{
		TotalProcessed: totalProcessed.Load(),
		Duration:       time.Since(start),
	}, nil
}
```

### 5.2 Python (`asyncpg`): Horizon Pinning Sentinel & Vacuum Starvation Watchdog

```python
import asyncio
import asyncpg
from typing import Optional, Dict, Any, List

class PostgreSQLSnapshotSentinel:
    """
    Guards PostgreSQL cluster against autovacuum starvation by tracking
    pinned backend_xmin horizons and enforcing snapshot TTL limits.
    """
    def __init__(self, dsn: str, max_horizon_seconds: int = 900):
        self.dsn = dsn
        self.max_horizon_seconds = max_horizon_seconds

    async def audit_active_snapshots_and_horizons(self) -> List[Dict[str, Any]]:
        """
        Audits active transaction snapshots and reports long-running backends
        that are pinning oldestxmin and blocking autovacuum dead-tuple cleanup.
        """
        conn = await asyncpg.connect(self.dsn)
        try:
            query = """
            SELECT
                a.pid,
                a.usename AS user_name,
                a.client_addr::text AS client_ip,
                a.application_name,
                a.backend_xmin::text AS backend_xmin,
                EXTRACT(EPOCH FROM (clock_timestamp() - a.xact_start))::numeric(10, 1) AS xact_duration_seconds,
                a.state,
                a.wait_event_type,
                a.wait_event,
                pg_isolation_test_session_is_blocked(a.pid, a.pid) AS is_blocked,
                CASE
                    WHEN EXTRACT(EPOCH FROM (clock_timestamp() - a.xact_start)) > $1 THEN 'DANGER_AUTOVACUUM_STARVATION'
                    WHEN EXTRACT(EPOCH FROM (clock_timestamp() - a.xact_start)) > ($1 / 2) THEN 'WARNING_ELEVATED_HORIZON'
                    ELSE 'HEALTHY'
                END AS horizon_risk_tier
            FROM pg_stat_activity a
            WHERE a.backend_xmin IS NOT NULL
              AND a.pid <> pg_backend_pid()
            ORDER BY a.xact_start ASC;
            """
            rows = await conn.fetch(query, float(self.max_horizon_seconds))
            return [dict(r) for r in rows]
        finally:
            await conn.close()

    async def terminate_starving_snapshots(self) -> int:
        """
        Terminates rogue snapshot backends exceeding the max duration threshold
        to relieve cluster-wide autovacuum starvation.
        """
        conn = await asyncpg.connect(self.dsn)
        try:
            terminated_count = 0
            records = await self.audit_active_snapshots_and_horizons()
            for rec in records:
                if rec["horizon_risk_tier"] == "DANGER_AUTOVACUUM_STARVATION":
                    pid = rec["pid"]
                    # Issue terminate signal
                    success = await conn.fetchval("SELECT pg_terminate_backend($1)", pid)
                    if success:
                        terminated_count += 1
            return terminated_count
        finally:
            await conn.close()
```

### 5.3 Rust (`tokio-postgres`): Zero-Preamble Worker Snapshot Importer

```rust
use tokio_postgres::{Client, NoTls, Error};

/// Imports an exported snapshot into a newly acquired worker client.
/// Strictly enforces zero preamble queries between BEGIN and SET TRANSACTION SNAPSHOT.
pub async fn import_snapshot_into_worker(
    client: &mut Client,
    snapshot_id: &str,
) -> Result<(), Error> {
    // 1. Begin REPEATABLE READ READ ONLY transaction
    client
        .batch_execute("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;")
        .await?;

    // 2. Immediately set transaction snapshot before ANY other statement
    let sql = format!("SET TRANSACTION SNAPSHOT '{}';", snapshot_id);
    if let Err(e) = client.batch_execute(&sql).await {
        // Rollback on snapshot import failure (e.g. coordinator already closed)
        let _ = client.batch_execute("ROLLBACK;").await;
        return Err(e);
    }

    Ok(())
}
```

---

## 6. Six-State Snapshot Lifecycle Finite-State Machine (FSM)

```
        ┌────────────────────────────────────────────────────────┐
        │                       INITIATED                        │
        │  Coordinator opens REPEATABLE READ READ ONLY Tx        │
        └───────────────────────────┬────────────────────────────┘
                                    │ SELECT pg_export_snapshot()
                                    ▼
        ┌────────────────────────────────────────────────────────┐
        │                   SNAPSHOT_EXPORTED                    │
        │  Snapshot written to $PGDATA/pg_snapshots/             │
        │  oldestxmin horizon pinned at coordinator's xmin       │
        └───────┬────────────────────────────────────────┬───────┘
                │ Barrier: Dispatch to N Workers         │ TTL Watchdog
                ▼                                        │ (> 900s)
        ┌────────────────────────────────┐               │
        │      WORKERS_IMPORTING         │               │
        │  SET TRANSACTION SNAPSHOT      │               │
        │  (Zero preambles verified)     │               │
        └───────┬────────────────────────┘               │
                │ All Workers Attached                   │
                ▼                                        │
        ┌────────────────────────────────┐               │
        │      PARALLEL_STREAMING        │               │
        │  Sargable range scans executed │               │
        │  Tuple visibility 100% frozen  │               │
        └───────┬────────────────────────┘               │
                │ All Chunks Completed                   │
                ▼                                        │
        ┌────────────────────────────────┐               ▼
        │        DRAINED_RELEASED        │    ┌──────────────────────┐
        │  Workers COMMIT                │    │ HORIZON_TERMINATION  │
        │  Coordinator COMMITS           │    │ Watchdog aborts tx   │
        │  Snapshot file unlinked        │    │ to save autovacuum   │
        │  oldestxmin horizon unpinned   │    └──────────────────────┘
        └────────────────────────────────┘
```

### State Transitions Table

| Initial State | Event / Trigger | Target State | Invariant Guard |
| :--- | :--- | :--- | :--- |
| `INITIATED` | `SELECT pg_export_snapshot()` succeeds | `SNAPSHOT_EXPORTED` | Transaction isolation level must be `REPEATABLE READ` or `SERIALIZABLE`. |
| `SNAPSHOT_EXPORTED` | Workers spawned with snapshot ID | `WORKERS_IMPORTING` | Worker connection must issue `SET TRANSACTION SNAPSHOT` before any other SQL. |
| `WORKERS_IMPORTING` | Barrier releases after all workers attach | `PARALLEL_STREAMING` | Disjoint indexed range partitions assigned to each worker. |
| `PARALLEL_STREAMING` | All chunks processed successfully | `DRAINED_RELEASED` | Workers commit; coordinator commits, releasing snapshot and unpinning `xmin`. |
| Any Active State | Snapshot elapsed time $> T_{\text{TTL}}$ | `HORIZON_TERMINATION` | Watchdog cancels coordinator to prevent autovacuum starvation. |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Every parallel ingestion script, batch export tool, or vector backfill worker must pass these 5 automated verification gates before merging into production:

### Gate 1: Preamble Collision & Snapshot Validity Gate (SQLSTATE 25P03 Prevention)

```bash
# Verify worker implementation does not execute warmup queries before snapshot import
python3 -c "
import re, sys

code = open(sys.argv[1]).read()
# Check for bad patterns where a query occurs between BEGIN and SET TRANSACTION SNAPSHOT
pattern = r'BEGIN.*?;\s*(?!SET TRANSACTION SNAPSHOT)[a-zA-Z]+'
if re.search(pattern, code, re.IGNORECASE | re.DOTALL):
    print('❌ CI GATE FAILED: Found statement between BEGIN and SET TRANSACTION SNAPSHOT')
    sys.exit(1)
print('✅ CI GATE PASSED: Zero-preamble snapshot import verified')
" path/to/worker_file.ts
```

### Gate 2: Cluster-Wide Horizon Pinning & Vacuum Starvation Sentinel Check

```sql
-- Assert zero backends are pinning backend_xmin for more than 15 minutes
SELECT
    pid,
    usename,
    backend_xmin,
    now() - xact_start AS active_duration
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
  AND now() - xact_start > interval '15 minutes';
-- Expected result: 0 rows returned.
```

### Gate 3: Snapshot File Cleanup Verification

```sql
-- Assert that after job completion, no orphaned snapshot exports linger in pg_snapshots
-- (Run as superuser or monitoring role)
SELECT count(*) AS lingering_snapshots
FROM pg_ls_dir('pg_snapshots')
WHERE pg_ls_dir <> '.' AND pg_ls_dir <> '..';
-- Expected result: 0 lingering snapshots.
```

### Gate 4: Point-in-Time Tuple Parity Assertion

```sql
-- In integration tests: Verify that a concurrent INSERT committed after snapshot export
-- is NOT visible to workers importing the snapshot.
-- 1. Coordinator exports snapshot S_1.
-- 2. External connection inserts row R_new into test_table and commits.
-- 3. Worker imports S_1 and queries count(*).
-- 4. Assert count matches pre-insertion count (zero snapshot drift).
```

### Gate 5: Unbounded Query Timeout Sentinel

```sql
-- All export transactions must explicitly set statement_timeout and idle_in_transaction_session_timeout
SHOW statement_timeout;
SHOW idle_in_transaction_session_timeout;
-- Invariant: idle_in_transaction_session_timeout must be <= 60000ms.
```
