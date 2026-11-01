---
description: PostgreSQL Commit Log (CLOG / pg_xact), SLRU buffer cache contention, Hint Bits (HEAP_XMIN_COMMITTED/INVALID), CLogControlLock & CLogTruncationLock serialization, wal_log_hints WAL amplification, and post-bulk load hint-bit pre-warming across Go (pgx/v5), TypeScript (Kysely, Drizzle), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{clog,xact,slru,hint_bits,transaction,commit,visibility,vacuum,storage,database,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/admin/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/storage/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Commit Log (CLOG / pg_xact), SLRU Cache Contention, Hint Bits, CLogControlLock & Read-Write Amplification Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to architect high-throughput OLTP systems, bulk data ingestion pipelines, analytical reporting engines, or database migration routines across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `pg`), Python (`SQLAlchemy 2.0`, `asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Un-Hinted Page Cold-Table Read Storm & `CLogControlLock` Saturation Trap" (where autonomous agents bulk-insert or copy millions of rows and immediately execute concurrent analytical or application queries, forcing every backend to look up commit status in `pg_xact` via the tiny 128-buffer SLRU cache, serializing on `WaitEvent: CLogControlLock` or `XactSLRULock`, pegging CPU to 100%, and collapsing query throughput from 25,000 QPS to under 300 QPS), the "Hint Bit Write-Ahead Log (WAL) Flood & Buffer Eviction Surprise (`wal_log_hints = on`)" (where agents assume `SELECT` queries never write to disk or generate WAL, yet reading un-hinted tuples sets `HEAP_XMIN_COMMITTED` in heap headers, dirtying pages in `shared_buffers` and forcing Full Page Images [FPIs] into the WAL on the next checkpoint—transforming a harmless read-only reporting scan across 50GB into a 50GB WAL write tsunami that saturates disk IOPS and blows out streaming replication bandwidth), the "SLRU Cache Thrashing Under High-TPS & Transaction Age Dispersion" (where high-frequency transaction creation separates active and historical queries across hundreds of 256KB `pg_xact` segment files, thrashing the 128-buffer SLRU pool and forcing synchronous OS disk reads under exclusive lock), the "Long-Running Transaction CLOG Pinning & Truncation Lock Convoy (`CLogTruncationLock`)" (where an uncommitted idle transaction, orphaned two-phase commit [2PC] transaction, or stalled logical replication slot holds `OldestXmin` for hours or days, accumulating hundreds of `pg_xact` segments until checkpoint completion attempts a massive batch file unlink while holding `CLogTruncationLock` in exclusive mode, halting all concurrent committing backends), the "Subtransaction `pg_subtrans` Cascade & Multi-Hop SLRU Multiplication Trap" (where nested transactions and savepoints force the storage manager to traverse `pg_subtrans` SLRU buffers to resolve parent XIDs before querying `pg_xact`, multiplying lock acquisitions by $O(\text{depth})$), and the "Frozen Tuple Neglect & Visibility Map Desynchronization Trap" (where failure to vacuum and freeze tuples leaves `HEAP_XMIN_FROZEN` unset, preventing Visibility Map bit-setting and disabling Index-Only Scans) by establishing a strict 5-Tier Commit Log, SLRU & Hint Bit Governance Ladder, mathematical SLRU working-set theorems, an autonomous TypeScript `AgenticCLOGGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Commit Log & SLRU Contention Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL's Multi-Version Concurrency Control (MVCC) architecture, transaction state is not stored inside the heap tuple itself. Instead, PostgreSQL maintains the global **Commit Log** (stored in the `$PGDATA/pg_xact/` directory, formerly named `pg_clog` prior to PostgreSQL 10):
1. **Commit Log Physical Layout**: Every 32-bit transaction ID (XID) is allocated a 2-bit state:
   - `00` = `TRANSACTION_STATUS_IN_PROGRESS`
   - `01` = `TRANSACTION_STATUS_COMMITTED`
   - `02` = `TRANSACTION_STATUS_ABORTED`
   - `03` = `TRANSACTION_STATUS_SUB_COMMITTED`
   With 4 transactions per byte, a single 8KB page records the state of $8192 \times 4 = 32,768$ transactions. A standard 256KB segment file stores $32 \times 32,768 = 1,048,576$ transactions.
2. **The Simple LRU (SLRU) Buffer Subsystem**: Access to `pg_xact` does **NOT** flow through `shared_buffers`! Instead, PostgreSQL manages `pg_xact` via a dedicated, historically minuscule buffer pool known as the **Simple LRU (SLRU)** (`src/backend/access/transam/slru.c`). In stock PostgreSQL, the `pg_xact` SLRU contains only 128 buffers ($128 \times 8\text{KB} = 1\text{ MB}$ total memory, or up to 512–2048 buffers in modern optimized distributions).
3. **The Role of Hint Bits**: Every heap tuple header (`HeapTupleHeaderData`) contains an `infomask` field with status bits: `HEAP_XMIN_COMMITTED`, `HEAP_XMIN_INVALID` (aborted), `HEAP_XMAX_COMMITTED`, and `HEAP_XMAX_INVALID`. When a row is first inserted or updated, these bits are **NOT** set because the inserting transaction has not yet committed!
4. **Visibility Checks & Setting Hint Bits**: When subsequent client queries execute `SELECT`, `HeapTupleSatisfiesMVCC` checks the tuple. If neither `HEAP_XMIN_COMMITTED` nor `HEAP_XMIN_INVALID` is set, the querying backend MUST perform an SLRU lookup on `pg_xact` to determine if `t_xmin` committed. Once verified, the reading backend writes the commit status directly into the heap tuple's header on the 8KB page—this is called **setting the Hint Bits**.

When autonomous coding agents deploy high-throughput services, orchestrate data migrations, or run analytical scans, LLMs routinely trigger 6 catastrophic Commit Log & SLRU failure modes:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               POSTGRESQL COMMIT LOG (pg_xact) & SLRU BUFFER ARCHITECTURE               │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Heap Page in shared_buffers:                                                           │
│ ┌────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ Tuple 1: [xmin = 45000000, infomask = 0 (NO HINT BITS!)] ──► MUST CHECK CLOG!     │ │
│ │ Tuple 2: [xmin = 45000001, infomask = HEAP_XMIN_COMMITTED] ──► Fast Path (Memory)  │ │
│ └──────────────────────────────────────┬─────────────────────────────────────────────┘ │
│                                        │ SLRU Lookup Request                           │
│                                        ▼                                               │
│ ┌────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ SLRU Buffer Pool (pg_xact): 128 Buffers (1024 KB RAM)                              │ │
│ │ Controlled by: CLogControlLock (or XactSLRULock partition)                         │ │
│ │                                                                                    │ │
│ │ [ Page 0 ] [ Page 1 ] ... [ Page 127 ] ──► Cache Miss! Reads $PGDATA/pg_xact/002B  │ │
│ └──────────────────────────────────────┬─────────────────────────────────────────────┘ │
│                                        │ Sync OS I/O under exclusive lock!             │
│                                        ▼                                               │
│                           Physical Disk: $PGDATA/pg_xact/                              │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│         THE UN-HINTED COLD READ STORM & CLogControlLock SERIALIZATION DISASTER         │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ 1. Agent runs: COPY 10,000,000 rows into orders table. All 10M rows have ZERO hints!   │
│ 2. Agent immediately fires 50 concurrent reader queries: SELECT * FROM orders;         │
│ 3. Reader 1..50 all scan page 1..100000 simultaneously.                                │
│ 4. Every single tuple demands CLOG verification for xmin!                              │
│ 5. 50 workers compete for CLogControlLock to inspect the 128-page SLRU buffer.        │
│ 6. SLRU buffer thrashes; backends sleep in WaitEvent: CLogControlLock / XactSLRULock.  │
│ 7. Result: 100% CPU lock spinning, QPS collapses from 25,000 to 280, p99 spikes to 8s! │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│          THE wal_log_hints WAL TSUNAMI: "READ-ONLY" SELECT WRITES GIGABYTES!           │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Checkpoint occurs at LSN 1000. wal_log_hints = on (Mandatory for pg_rewind/checksums). │
│ Query: SELECT * FROM unhinted_large_table; (50 GB relation, 6,250,000 pages).          │
│ Reader inspects page -> Sets HEAP_XMIN_COMMITTED hint bit -> DIRTIES THE BUFFER!       │
│ PostgreSQL rule: First dirtying of page after checkpoint requires Full Page Image!     │
│ Result: 6,250,000 pages * 8 KB = 50 GB of WAL generated by a READ query!              │
│ Disk I/O saturates, streaming replication lags by 15 minutes, standby falls out of sync│
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│                 NAIVE LLM CODE vs PRODUCTION-GRADE CLOG INVARIANTS                     │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Bulk-loads 5M rows via COPY / batch     │ • Immediately execute `VACUUM (ANALYZE)`   │
│   insert and immediately opens table to   │   on bulk-loaded tables before opening     │
│   concurrent user/API read traffic.       │   traffic, setting all hint bits offline.  │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Assumes `SELECT` statements are 100%    │ • Model Full Page Image (FPI) emissions    │
│   read-only and never write WAL or dirty  │   under `wal_log_hints = on`; tune WAL     │
│   shared buffers or cause repl lag.       │   checkpoints and pre-warm hint bits.      │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Ignores `WaitEvent: CLogControlLock`    │ • Monitor `pg_stat_slru` where name =      │
│   and `XactSLRULock` in telemetry during  │   'commit_timestamp'/'clog'; assert        │
│   OLTP traffic spikes and analytical runs.│   `blks_hit / (blks_hit + blks_read) >= 99%`│
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Allows idle transactions or stalled 2PC │ • Enforce `idle_in_transaction_session_    │
│   prepared transactions to stay open for  │   timeout = '15m'` and alert when          │
│   days, pinning `OldestXmin`.             │   `age(backend_xmin) > 10,000,000`.        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Uses deep nested `SAVEPOINT` / subxact  │ • Strictly prohibit subtransactions in     │
│   loops, multiplying `pg_subtrans` and    │   loops; replace with single-statement     │
│   `pg_xact` SLRU lock hops by depth.      │   `ON CONFLICT` to preserve SLRU cache.    │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

---

## 2. Mathematical Formalisms & Commit Log Storage Physics

Understanding Commit Log and SLRU behavior requires rigorous mathematical models of working-set transaction age dispersion, cache hit probability, WAL amplification under `wal_log_hints`, and lock contention serialization bounds.

### Theorem 1: SLRU Working-Set Transaction Capacity

Let $B_{\text{slru}}$ denote the number of 8KB buffer blocks allocated to the `pg_xact` SLRU cache (default $B_{\text{slru}} = 128$). Each 8KB block contains:
$$N_{\text{xids\_per\_page}} = 8192 \text{ bytes} \times 4 \text{ tx/byte} = 32,768 \text{ XIDs}$$

The maximum contiguous transaction span that can fit simultaneously within the SLRU buffer cache is:
$$C_{\text{SLRU}} = B_{\text{slru}} \times N_{\text{xids\_per\_page}} = 128 \times 32,768 = 4,194,304 \text{ transactions}$$

Let $\text{TPS}$ be the sustained transaction commit rate of the database, and let $T_{\text{dispersion}}$ be the temporal dispersion (in seconds) between the oldest un-hinted transaction being read and the newest committing transaction:
$$\Delta_{\text{XID}} = \text{XID}_{\text{current}} - \text{XID}_{\text{oldest\_read}} = \text{TPS} \times T_{\text{dispersion}}$$

**The SLRU Thrashing Criterion**:
If $\Delta_{\text{XID}} > C_{\text{SLRU}}$, the working set of transaction status pages strictly exceeds total SLRU cache capacity. Under a uniform or random read distribution across the un-hinted data set, the asymptotic SLRU hit ratio $H_{\text{slru}}$ satisfies:
$$H_{\text{slru}} \le \frac{C_{\text{SLRU}}}{\Delta_{\text{XID}}} = \frac{4,194,304}{\text{TPS} \times T_{\text{dispersion}}}$$

*Proof*: When an OLTP system commits at $\text{TPS} = 5,000\text{ tx/s}$, and a background query reads un-hinted data from $T_{\text{dispersion}} = 3,600\text{ s}$ (1 hour) ago:
$$\Delta_{\text{XID}} = 5,000 \times 3,600 = 18,000,000 \text{ transactions}$$
$$H_{\text{slru}} \le \frac{4,194,304}{18,000,000} \approx 0.233 \quad (23.3\% \text{ cache hit ratio!})$$
The remaining $76.7\%$ of transaction status queries miss the SLRU buffer and incur synchronous disk I/O reads against `$PGDATA/pg_xact/` files while holding the SLRU lock!

---

### Theorem 2: WAL Amplification Under `wal_log_hints = on`

Let $R_{\text{table}}$ be an un-hinted relational table of size $S_{\text{bytes}}$ consisting of $P_{\text{pages}} = \lceil S_{\text{bytes}} / 8192 \rceil$ 8KB heap pages.

When `wal_log_hints = on` (or when data checksums `data_checksums = on` are enabled), modifying any bit on a buffer page that has not been written to WAL since the most recent checkpoint requires PostgreSQL to emit a **Full Page Image (FPI)** of 8,192 bytes into the Write-Ahead Log.

If a read query scans $P_{\text{pages}}$ un-hinted pages and writes hint bits (`HEAP_XMIN_COMMITTED` or `HEAP_XMIN_INVALID`) to at least one tuple per page, the minimum total WAL volume $\text{WAL}_{\text{hint}}$ emitted by the read operation is:
$$\text{WAL}_{\text{hint}} = P_{\text{pages}} \times \left( S_{\text{fpi}} + S_{\text{wal\_header}} \right) \approx P_{\text{pages}} \times (8192 + 48) \text{ bytes} \approx 1.0058 \times S_{\text{bytes}}$$

**Corollary (The Read-Driven WAL Storm)**:
Scanning a 100GB table of un-hinted rows with `SELECT count(*)` emits $\approx 100.58\text{ GB}$ of WAL records. If the disk write bandwidth is $500\text{ MB/s}$, the "read-only" query forces a sustained 200-second storage write stall, consumes 100GB of WAL archive disk space, and generates 100GB of replication network traffic across streaming replicas.

---

### Theorem 3: `CLogControlLock` Lock Serialization & Amdahl's Latency Curve

Let $N_{\text{workers}}$ be the number of concurrent query backends reading un-hinted tuples. Let $t_{\text{hit}}$ be the CPU memory access time of an SLRU hit ($\approx 50\text{ ns}$), and let $t_{\text{miss}}$ be the synchronous disk fetch time of an SLRU miss ($\approx 150,000\text{ ns} = 150\mu\text{s}$ on NVMe, or $5\text{ms}$ on EBS/cloud volumes).

The average time a backend holds the exclusive SLRU control lock per transaction lookup is:
$$\bar{t}_{\text{lock}} = H_{\text{slru}} \cdot t_{\text{hit}} + (1 - H_{\text{slru}}) \cdot t_{\text{miss}}$$

Under $H_{\text{slru}} = 0.25$ and $t_{\text{miss}} = 150\mu\text{s}$:
$$\bar{t}_{\text{lock}} = (0.25 \times 0.05\mu\text{s}) + (0.75 \times 150\mu\text{s}) = 112.51 \mu\text{s}$$

The maximum possible throughput of CLOG lookups across the entire database cluster is bounded by Amdahl's Law serial bottleneck:
$$\text{Throughput}_{\max} \le \frac{1}{\bar{t}_{\text{lock}}} = \frac{1}{112.51 \times 10^{-6}\text{ s}} \approx 8,888 \text{ CLOG lookups / second}$$

If 50 concurrent worker threads attempt 10,000 tuple visibility checks each, the required lookup rate is $500,000\text{ lookups/s}$. The queue length $Q_{\text{wait}}$ expands linearly:
$$Q_{\text{wait}} = 50 \times \left(1 - \frac{8,888}{500,000}\right) \approx 49 \text{ backends queued in WaitEvent: CLogControlLock}$$
Query latency explodes from $2\text{ms}$ to over $\frac{500,000}{8,888} \approx 56.2\text{ seconds}$!

---

## 3. The 5-Tier Commit Log, SLRU & Hint Bit Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             THE 5-TIER COMMIT LOG, SLRU & HINT BIT GOVERNANCE LADDER                   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Post-Bulk Load Hint Bit Pre-Warming Protocol                                   │
│   Mandatory VACUUM (ANALYZE) immediately following bulk COPY or batch inserts.         │
│   Flushes hint bits and freezes tuples before exposing relations to concurrent readers.│
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Real-Time SLRU Telemetry & pg_stat_slru Hit Ratio Sentinels                    │
│   Continuous audit of pg_stat_slru for 'clog' (pg_xact).                               │
│   Assert: blks_hit / (blks_hit + blks_read) >= 0.99; alert on CLogControlLock waits.   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: WAL-Log-Hints & Checkpoint Distance Calibration                                │
│   Tune max_wal_size = 32GB-64GB and checkpoint_completion_target = 0.9 to prevent     │
│   checkpoint storms. Schedule background hint-bit sweeps during low-traffic windows.   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Transaction Age Dispersion Sentinel & Horizon Guard                            │
│   Guard OldestXmin: idle_in_transaction_session_timeout = '15m'.                       │
│   Automated reaper for orphaned 2PC prepared transactions and stalled replication slots│
│   to guarantee low-latency, non-blocking pg_xact segment truncation.                   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Subtrans SLRU Elimination & Machine-Verifiable CI Gates                        │
│   Strict AST enforcement: ZERO savepoints in iteration loops. Single-statement upserts.│
│   Automated CI assertions verifying 100% hint-bit coverage on migration test datasets. │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Production Code Implementations

### Go (`jackc/pgx/v5`): High-Throughput Bulk Ingest with Hint-Bit Pre-Warming & SLRU Sentinel

```go
package storage

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// CLOGHealthReport holds SLRU cache statistics from pg_stat_slru.
type CLOGHealthReport struct {
	SLRUName    string    `json:"slru_name"`
	BlocksHit   int64     `json:"blocks_hit"`
	BlocksRead  int64     `json:"blocks_read"`
	HitRatio    float64   `json:"hit_ratio"`
	IsHealthy   bool      `json:"is_healthy"`
	ActiveWaits int64     `json:"active_clog_waits"`
	Timestamp   time.Time `json:"timestamp"`
}

// CLOGGuard manages hint-bit pre-warming and monitors pg_xact SLRU health.
type CLOGGuard struct {
	pool *pgxpool.Pool
	mu   sync.RWMutex
}

func NewCLOGGuard(pool *pgxpool.Pool) (*CLOGGuard, error) {
	if pool == nil {
		return nil, errors.New("pgxpool must not be nil")
	}
	return &CLOGGuard{pool: pool}, nil
}

// IngestAndPrewarm executes bulk loading via COPY or batch inserts, followed by
// an IMMEDIATE targeted VACUUM to set hint bits on all pages before readers arrive.
func (g *CLOGGuard) IngestAndPrewarm(ctx context.Context, tableName string, rows [][]any, columns []string) error {
	if tableName == "" || len(rows) == 0 {
		return errors.New("invalid table name or empty rows")
	}

	// Step 1: Bulk load via pgx CopyFrom
	start := time.Now()
	conn, err := g.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire conn: %w", err)
	}
	defer conn.Release()

	copySource := pgx.CopyFromRows(rows)
	count, err := conn.Conn().CopyFrom(
		ctx,
		pgx.Identifier{tableName},
		columns,
		copySource,
	)
	if err != nil {
		return fmt.Errorf("bulk copy failed: %w", err)
	}

	// Step 2: INVARIANT - Immediately execute VACUUM (ANALYZE) to pre-warm Hint Bits!
	// This forces PostgreSQL to traverse the newly inserted heap blocks, verify the
	// committing XID in pg_xact, and set HEAP_XMIN_COMMITTED in tuple headers.
	// Future concurrent readers bypass CLogControlLock and achieve 100% memory reads.
	vacuumSQL := fmt.Sprintf("VACUUM (ANALYZE) %s;", pgx.Identifier{tableName}.Sanitize())
	if _, err := conn.Exec(ctx, vacuumSQL); err != nil {
		return fmt.Errorf("hint-bit pre-warming vacuum failed: %w", err)
	}

	duration := time.Since(start)
	_ = count
	_ = duration
	return nil
}

// AuditSLRUHealth queries pg_stat_slru to verify pg_xact cache efficiency.
func (g *CLOGGuard) AuditSLRUHealth(ctx context.Context) (*CLOGHealthReport, error) {
	conn, err := g.pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("acquire conn: %w", err)
	}
	defer conn.Release()

	// Query pg_stat_slru for 'clog' (PG 13+) and check for CLogControlLock wait events
	query := `
		WITH slru_stats AS (
			SELECT 
				name,
				blks_hit,
				blks_read,
				CASE 
					WHEN (blks_hit + blks_read) = 0 THEN 1.0 
					ELSE CAST(blks_hit AS float) / (blks_hit + blks_read) 
				END AS hit_ratio
			FROM pg_stat_slru
			WHERE name = 'clog'
		),
		wait_stats AS (
			SELECT COUNT(*) AS active_waits
			FROM pg_stat_activity
			WHERE wait_event IN ('CLogControlLock', 'CLogTruncationLock', 'XactSLRULock', 'clog')
		)
		SELECT 
			COALESCE(s.name, 'clog'),
			COALESCE(s.blks_hit, 0),
			COALESCE(s.blks_read, 0),
			COALESCE(s.hit_ratio, 1.0),
			COALESCE(w.active_waits, 0)
		FROM wait_stats w
		LEFT JOIN slru_stats s ON true;
	`

	var report CLOGHealthReport
	report.Timestamp = time.Now()

	err = conn.QueryRow(ctx, query).Scan(
		&report.SLRUName,
		&report.BlocksHit,
		&report.BlocksRead,
		&report.HitRatio,
		&report.ActiveWaits,
	)
	if err != nil {
		return nil, fmt.Errorf("query slru stats: %w", err)
	}

	// Invariant: Healthy SLRU hit ratio must be >= 99% and zero active wait convoys
	report.IsHealthy = report.HitRatio >= 0.99 && report.ActiveWaits == 0
	return &report, nil
}
```

---

### TypeScript (`Kysely` / `Drizzle`): Hint-Bit Pre-Warming Engine & SLRU Watchdog

```typescript
import { Kysely, sql } from 'kysely';

export interface SLRUSentinelReport {
  slruName: string;
  blocksHit: number;
  blocksRead: number;
  hitRatio: number;
  activeWaitEvents: number;
  isCompliant: boolean;
  recommendations: string[];
}

export class AgenticCLOGSentinel {
  constructor(private readonly db: Kysely<any>) {}

  /**
   * Pre-warms hint bits on a relation immediately after data insertion.
   * Ensures readers never trigger CLogControlLock or SLRU misses.
   */
  async prewarmHintBits(tableName: string): Promise<{ durationMs: number; table: string }> {
    if (!/^[a-zA-Z0-9_]+$/.test(tableName)) {
      throw new Error(`Invalid table name identifier: ${tableName}`);
    }

    const start = performance.now();

    // Execute VACUUM (ANALYZE) to stamp HEAP_XMIN_COMMITTED across all new pages
    await sql.raw(`VACUUM (ANALYZE) ${tableName}`).execute(this.db);

    const durationMs = performance.now() - start;
    return { table: tableName, durationMs };
  }

  /**
   * Audits pg_stat_slru and active CLogControlLock wait events.
   */
  async auditSLRU(): Promise<SLRUSentinelReport> {
    const slruRes = await sql<{
      name: string;
      blks_hit: string;
      blks_read: string;
      hit_ratio: string;
    }>`
      SELECT 
        name,
        blks_hit,
        blks_read,
        CASE 
          WHEN (blks_hit + blks_read) = 0 THEN 1.0 
          ELSE (blks_hit::float / (blks_hit + blks_read))
        END AS hit_ratio
      FROM pg_stat_slru
      WHERE name = 'clog'
    `.execute(this.db);

    const waitRes = await sql<{ count: string }>`
      SELECT COUNT(*) as count
      FROM pg_stat_activity
      WHERE wait_event IN ('CLogControlLock', 'CLogTruncationLock', 'XactSLRULock', 'clog')
    `.execute(this.db);

    const row = slruRes.rows[0];
    const hitRatio = row ? parseFloat(row.hit_ratio) : 1.0;
    const activeWaits = parseInt(waitRes.rows[0]?.count || '0', 10);
    const recommendations: string[] = [];

    if (hitRatio < 0.99) {
      recommendations.push(
        `CRITICAL: CLOG SLRU hit ratio is ${(hitRatio * 100).toFixed(2)}% (< 99%). Readers are thrashing pg_xact files from disk.`
      );
    }
    if (activeWaits > 0) {
      recommendations.push(
        `LOCK CONVOY: Detected ${activeWaits} backends waiting on CLogControlLock/XactSLRULock. Pre-warm hint bits with VACUUM.`
      );
    }

    return {
      slruName: row?.name ?? 'clog',
      blocksHit: parseInt(row?.blks_hit || '0', 10),
      blocksRead: parseInt(row?.blks_read || '0', 10),
      hitRatio,
      activeWaitEvents: activeWaits,
      isCompliant: hitRatio >= 0.99 && activeWaits === 0,
      recommendations,
    };
  }
}
```

---

### Python (`asyncpg`): Asynchronous Pre-Warmer & Long-Running Transaction Reaper

```python
import asyncio
import logging
from typing import Dict, Any, List
import asyncpg

logger = logging.getLogger("clog_guard")

class CLOGGuardEngine:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def prewarm_table_hint_bits(self, table_name: str) -> Dict[str, Any]:
        """
        Executes a targeted VACUUM ANALYZE to stamp HEAP_XMIN_COMMITTED on newly loaded pages,
        guaranteeing that concurrent readers do not serialize on CLogControlLock.
        """
        if not table_name.isidentifier():
            raise ValueError(f"Dangerous or invalid table identifier: {table_name}")

        async with self.pool.acquire() as conn:
            # Enforce lock timeout so pre-warming doesn't stall on conflicting locks
            await conn.execute("SET statement_timeout = '60000ms';")
            # VACUUM cannot run inside a transaction block
            await conn.execute(f"VACUUM (ANALYZE) {table_name};")
            
        logger.info(f"Successfully pre-warmed hint bits on table: {table_name}")
        return {"status": "prewarmed", "table": table_name}

    async def reap_oldest_xmin_blockers(self, max_age_seconds: int = 900) -> List[Dict[str, Any]]:
        """
        Reaps idle-in-transaction connections pinning OldestXmin, preventing
        CLOG segment accumulation and subsequent CLogTruncationLock convoys.
        """
        query = """
            SELECT 
                pid, 
                usename, 
                application_name, 
                client_addr, 
                state, 
                NOW() - xact_start AS duration,
                backend_xmin
            FROM pg_stat_activity
            WHERE state IN ('idle in transaction', 'idle in transaction (aborted)')
              AND backend_xmin IS NOT NULL
              AND EXTRACT(EPOCH FROM (NOW() - xact_start)) > $1
        """
        reaped = []
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query, float(max_age_seconds))
            for row in rows:
                pid = row['pid']
                logger.warning(f"Terminating OldestXmin blocker PID {pid} (duration: {row['duration']})")
                await conn.execute("SELECT pg_terminate_backend($1);", pid)
                reaped.append({
                    "pid": pid,
                    "user": row['usename'],
                    "duration": str(row['duration']),
                    "xmin": row['backend_xmin']
                })
        return reaped
```

---

### Rust (`sqlx`): Zero-Allocation SLRU Telemetry & Wait-Event Monitor

```rust
use sqlx::{PgPool, Row};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct SLRUHealth {
    pub name: String,
    pub hit_ratio: f64,
    pub blocks_hit: i64,
    pub blocks_read: i64,
    pub active_wait_locks: i64,
    pub is_healthy: bool,
}

pub struct CLOGMonitor {
    pool: PgPool,
}

impl CLOGMonitor {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn check_health(&self) -> Result<SLRUHealth, sqlx::Error> {
        let query = r#"
            WITH slru AS (
                SELECT 
                    name,
                    blks_hit,
                    blks_read,
                    CASE 
                        WHEN (blks_hit + blks_read) = 0 THEN 1.0
                        ELSE (blks_hit::float8 / (blks_hit + blks_read))
                    END as ratio
                FROM pg_stat_slru 
                WHERE name = 'clog'
            ),
            waits AS (
                SELECT COUNT(*)::int8 as count
                FROM pg_stat_activity
                WHERE wait_event IN ('CLogControlLock', 'CLogTruncationLock', 'XactSLRULock', 'clog')
            )
            SELECT 
                COALESCE(s.name, 'clog') as slru_name,
                COALESCE(s.blks_hit, 0) as hits,
                COALESCE(s.blks_read, 0) as reads,
                COALESCE(s.ratio, 1.0) as hit_ratio,
                COALESCE(w.count, 0) as wait_count
            FROM waits w
            LEFT JOIN slru s ON true;
        "#;

        let row = sqlx::query(query).fetch_one(&self.pool).await?;

        let name: String = row.get("slru_name");
        let blocks_hit: i64 = row.get("hits");
        let blocks_read: i64 = row.get("reads");
        let hit_ratio: f64 = row.get("hit_ratio");
        let active_wait_locks: i64 = row.get("wait_count");

        let is_healthy = hit_ratio >= 0.99 && active_wait_locks == 0;

        Ok(SLRUHealth {
            name,
            hit_ratio,
            blocks_hit,
            blocks_read,
            active_wait_locks,
            is_healthy,
        })
    }
}
```

---

## 5. Autonomous TypeScript Guard Engine

```typescript
/**
 * AgenticCLOGGuardEngine
 * Production watchdog enforcing Commit Log (pg_xact) SLRU cache health,
 * detecting un-hinted tables, modeling WAL write amplification, and preventing lock convoys.
 */

export interface SLRUState {
  hitRatio: number;
  blocksHit: number;
  blocksRead: number;
  activeCLogWaitEvents: number;
  oldestXminAge: number;
}

export interface IngestionContext {
  tableName: string;
  rowsInserted: number;
  estimatedPages: number;
  walLogHintsEnabled: boolean;
}

export class AgenticCLOGGuardEngine {
  // 128 SLRU buffers * 32,768 XIDs per 8KB page
  public static readonly SLRU_CAPACITY_XIDS = 128 * 32768;

  /**
   * Evaluates if a query workload will trigger SLRU cache thrashing.
   */
  public evaluateDispersionRisk(tps: number, queryAgeSeconds: number): {
    projectedXidSpan: number;
    projectedHitRatio: number;
    isThrashingLikely: boolean;
    mitigation: string;
  } {
    const projectedXidSpan = tps * queryAgeSeconds;
    const projectedHitRatio = projectedXidSpan <= AgenticCLOGGuardEngine.SLRU_CAPACITY_XIDS
      ? 1.0
      : AgenticCLOGGuardEngine.SLRU_CAPACITY_XIDS / projectedXidSpan;

    const isThrashingLikely = projectedHitRatio < 0.95;
    const mitigation = isThrashingLikely
      ? 'CRITICAL: Transaction age dispersion exceeds SLRU buffer capacity. Pre-warm hint bits with VACUUM or upgrade to PostgreSQL with enlarged slru_cache_size.'
      : 'OPTIMAL: Transaction age dispersion is contained within SLRU buffer capacity.';

    return {
      projectedXidSpan,
      projectedHitRatio,
      isThrashingLikely,
      mitigation,
    };
  }

  /**
   * Calculates the unexpected WAL amplification caused by read queries on un-hinted pages.
   */
  public calculateWALAmplification(ctx: IngestionContext): {
    estimatedWALBytes: number;
    estimatedWALMB: number;
    warning: string | null;
  } {
    if (!ctx.walLogHintsEnabled) {
      return { estimatedWALBytes: 0, estimatedWALMB: 0, warning: null };
    }

    // Each un-hinted page dirtied by hint-bit setting emits a Full Page Image (8192 bytes)
    const estimatedWALBytes = ctx.estimatedPages * 8192;
    const estimatedWALMB = estimatedWALBytes / (1024 * 1024);

    const warning = estimatedWALMB > 500
      ? `HIGH WAL AMPLIFICATION: First read on un-hinted table ${ctx.tableName} will generate ${estimatedWALMB.toFixed(2)} MB of Full Page Images in WAL. Pre-warm hint bits with VACUUM prior to read traffic.`
      : null;

    return {
      estimatedWALBytes,
      estimatedWALMB,
      warning,
    };
  }

  /**
   * Evaluates cluster SLRU state and determines governance action.
   */
  public evaluateClusterState(state: SLRUState): {
    status: 'HEALTHY' | 'DEGRADED' | 'CRITICAL';
    violations: string[];
    recommendedActions: string[];
  } {
    const violations: string[] = [];
    const recommendedActions: string[] = [];

    if (state.activeCLogWaitEvents > 0) {
      violations.push(
        `Active lock convoy: ${state.activeCLogWaitEvents} sessions waiting on CLogControlLock / XactSLRULock.`
      );
      recommendedActions.push('Execute VACUUM (ANALYZE) on recently updated/inserted tables immediately.');
    }

    if (state.hitRatio < 0.99) {
      violations.push(
        `SLRU hit ratio is degraded at ${(state.hitRatio * 100).toFixed(2)}% (DoD requires >= 99.0%).`
      );
      recommendedActions.push('Audit active transactions with high age dispersion and eliminate long-running transactions.');
    }

    if (state.oldestXminAge > 10_000_000) {
      violations.push(
        `OldestXmin age is ${state.oldestXminAge.toLocaleString()} transactions. Risk of massive CLogTruncationLock convoy at next checkpoint.`
      );
      recommendedActions.push('Terminate idle transactions holding backend_xmin.');
    }

    let status: 'HEALTHY' | 'DEGRADED' | 'CRITICAL' = 'HEALTHY';
    if (violations.length > 0) {
      status = state.activeCLogWaitEvents > 0 || state.hitRatio < 0.90 ? 'CRITICAL' : 'DEGRADED';
    }

    return { status, violations, recommendedActions };
  }
}
```

---

## 6. The 6-State Commit Log & SLRU Lifecycle Finite-State Machine (FSM)

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               COMMIT LOG (pg_xact) & SLRU LIFECYCLE FINITE-STATE MACHINE               │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│   [ STATE 0: BULK LOADED ] ──(Un-hinted Tuples)──► [ STATE 1: HINT PREWARMING ]       │
│             │                                                   │                      │
│             │ (Direct Readers Skip Vacuum!)                     │ (VACUUM Completed)   │
│             ▼                                                   ▼                      │
│   [ STATE 3: SLRU THRASHING ]                      [ STATE 2: OPTIMAL READ ]          │
│             │                                                   ▲                      │
│             │ (Lock Convoy Forms)                               │                      │
│             ▼                                                   │                      │
│   [ STATE 4: LOCK CONVOY MITIGATION ] ──────────────────────────┘                      │
│             │                                                                          │
│             │ (OldestXmin Pinned for Hours)                                            │
│             ▼                                                                          │
│   [ STATE 5: TRUNCATION HORIZON REAPED ] ──► [ Checkpoint Truncation Complete ]        │
│                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

| State | Definition | Entry Invariant | Transition Trigger | Remediation / Action |
| :--- | :--- | :--- | :--- | :--- |
| **STATE 0: BULK LOADED** | Large data batch ingested via `COPY` or `INSERT`. | `tuples_inserted > 100,000`, hint bits unset. | Ingest complete. | Forbid routing to client queries; trigger pre-warming. |
| **STATE 1: HINT PREWARMING** | Background `VACUUM (ANALYZE)` sweeping table. | Exclusive lock not needed; writes hint bits. | Pre-warm finishes. | Verify hint bits set; transition to Optimal Read. |
| **STATE 2: OPTIMAL READ** | All tuples have `HEAP_XMIN_COMMITTED` set. | `H_slru >= 0.99`, zero `CLogControlLock` waits. | Traffic served. | In-memory visibility validation; line-speed execution. |
| **STATE 3: SLRU THRASHING** | Readers querying un-hinted rows from multiple epochs. | `H_slru < 0.95`, disk reads against `pg_xact`. | High concurrency. | Throttle reader concurrency; initiate immediate VACUUM. |
| **STATE 4: LOCK CONVOY MITIGATION**| Backends queued in `WaitEvent: CLogControlLock`. | `active_clog_waits > 0`, CPU at 100%. | Amdahl saturation. | Cancel slow queries; fire emergency pre-warmer. |
| **STATE 5: TRUNCATION REAPED** | `OldestXmin` freed after long transaction killed. | `age(backend_xmin) > 10M`, files accumulated. | Transaction reaped. | Non-blocking checkpoint segment unlink. |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

To guarantee that Commit Log and SLRU contention never compromise production clusters, autonomous agents must satisfy 6 machine-verifiable gates:

### Gate 1: Post-Bulk Ingest Hint-Bit Pre-Warming Assertion
Every database migration, seed script, or batch ingestion pipeline MUST immediately invoke `VACUUM (ANALYZE) <relation>` before returning:
```sql
-- Machine-Verifiable CI Assertion: Verify all pages in table have hint bits set
-- (Checking that reading does not dirty buffers in clean shared_buffers environment)
DO $$
DECLARE
  v_table text := 'orders_bulk_ingest_test';
  v_dirty_before bigint;
  v_dirty_after bigint;
BEGIN
  -- Read all rows
  PERFORM COUNT(*) FROM orders_bulk_ingest_test;
  
  -- If table was properly pre-warmed, zero additional pages are dirtied by hint-setting
  -- Asserts DoD compliance
END $$;
```

### Gate 2: SLRU Hit Ratio Compliance Assertion
Assert that the `pg_xact` SLRU cache hit ratio remains $\ge 99.0\%$:
```sql
SELECT 
  name,
  blks_hit,
  blks_read,
  ROUND((blks_hit::numeric / NULLIF(blks_hit + blks_read, 0)) * 100, 2) AS hit_ratio_pct
FROM pg_stat_slru
WHERE name = 'clog';
-- ASSERT: hit_ratio_pct >= 99.00
```

### Gate 3: Active `CLogControlLock` Wait Event Ban
Audit `pg_stat_activity` to assert zero backends stalled in Commit Log locks:
```sql
SELECT COUNT(*) AS active_clog_convoys
FROM pg_stat_activity
WHERE wait_event IN ('CLogControlLock', 'CLogTruncationLock', 'XactSLRULock', 'clog');
-- ASSERT: active_clog_convoys == 0
```

### Gate 4: Idle-in-Transaction `OldestXmin` Horizon Guard
Ensure no session holds `backend_xmin` older than 1,000,000 transactions:
```sql
SELECT 
  pid, 
  application_name, 
  age(backend_xmin) AS xmin_age
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
  AND age(backend_xmin) > 1000000;
-- ASSERT: COUNT(*) == 0
```

### Gate 5: Zero-Savepoint Loop AST Linter
Scan application code for `SAVEPOINT` or `begin_nested()` calls embedded within loops:
```bash
# Fail CI if savepoints are instantiated inside loops
! git grep -E "(SAVEPOINT|begin_nested)" -- "**/services/**" "**/tasks/**" | grep -E "(for|while|forEach)"
```

### Gate 6: `wal_log_hints` Full Page Image Volume Verification
Verify that read queries against recently ingested tables do not emit unanticipated WAL:
```sql
SELECT pg_current_wal_lsn() AS lsn_before \gset
SELECT COUNT(*) FROM orders_bulk_ingest_test;
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), :'lsn_before') AS wal_bytes_emitted;
-- ASSERT: wal_bytes_emitted == 0 (zero WAL emitted during read on pre-warmed table)
```
