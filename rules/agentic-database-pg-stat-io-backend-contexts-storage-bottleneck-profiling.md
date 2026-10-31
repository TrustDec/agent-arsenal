---
description: PostgreSQL 16+ pg_stat_io multi-dimensional storage I/O profiling, backend type segmentation (client backend, autovacuum, background writer, checkpointer), I/O context differentiation (normal, vacuum, bulkread, bulkwrite), target object tracking (relation, temp relation), synchronous client writeback penalty containment (dirty page eviction), temporary disk spill isolation, fsync stall detection, and I/O wait latency observability across Go (jackc/pgx/v5), TypeScript (pg, kysely, drizzle-orm), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{pg_stat_io,stat_io,io_profiling,storage,buffer,disk_io,io_bottleneck,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database `pg_stat_io`, Multi-Dimensional Storage Diagnostics, Backend Contexts, Buffer Eviction & I/O Bottleneck Profiling Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to diagnose real-world storage I/O bottlenecks, monitor buffer pool writeback pressure, detect unindexed sequential scans via ring buffer telemetry, and isolate temporary file spills across PostgreSQL (16–17+) in Go (`jackc/pgx/v5`), TypeScript (`pg`, `kysely`, `drizzle-orm`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Global I/O Blindness & Synchronous Disk Read Guesswork" (where legacy `pg_statio_all_tables` or OS-level `iostat` aggregate all disk activity into a monolithic number, blinding agents to whether I/O load is driven by user transactions, autovacuum maintenance, checkpointer flushes, or background writer deficit), the "Client Backend Eviction & Synchronous Dirty Writeback Penalty (`backend_type = 'client backend', context = 'normal', op = 'write' > 0`)" (where undersized background writers force synchronous client query threads to write dirty buffers to disk during read operations, exploding p99 transaction latency from 1.5ms to >250ms), the "Bulkread Ring Buffer Eviction Mirage (`context = 'bulkread'` vs `normal`)" (where unindexed full table scans consume the 256KB bulkread ring buffer, causing massive disk read churn without showing up as standard shared buffer churn), the "Temp Relation Disk Spill Latency Cliff (`target = 'temp relation', op = 'write' > 0`)" (where queries exceeding `work_mem` silently spill hash tables and sorting nodes to physical temporary disk blocks, exhausting NVMe write IOPS and degrading cluster throughput), the "Autovacuum Storage Starvation vs Throttling Miscalibration (`backend_type = 'autovacuum', context = 'vacuum'`)" (where maintenance processes either monopolize disk channels or starve due to overly conservative cost limits, leading to undetected table bloat), and the "Checkpointer Fsync Stalls & Disk Write Saturation (`op = 'fsync', fsync_time > 0`)" (where checkpoint sync spikes lock storage controllers and elevate write latency across the entire operating system) by establishing a strict 5-Tier `pg_stat_io` Governance Ladder, formal storage physics theorems, differential I/O flux models, a production-ready TypeScript `AgenticPgStatIoGuardEngine`, cross-runtime implementations in Go, Python, and Rust, a 6-state lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Storage I/O Catastrophes vs The 5-Tier Governance Ladder

Prior to PostgreSQL 16, diagnosing disk I/O was one of the most frustrating challenges in database reliability engineering. Legacy views like `pg_statio_all_tables` only reported cumulative block reads and hits per relation, while OS utilities (`iostat`, `vmstat`) reported physical block device reads and writes without any concept of PostgreSQL transactions, backend roles, or execution contexts. 

PostgreSQL 16 introduced `pg_stat_io`, a multi-dimensional matrix view that exposes every disk read, write, extend, and fsync operation broken down across four orthogonal dimensions:
1. **`backend_type`**: The process executing the operation (`client backend`, `background writer`, `checkpointer`, `autovacuum`, `standalone backend`, `walsender`, `background worker`).
2. **`target`**: The underlying object being accessed (`relation` for heap/index data, `temp relation` for temporary sorting/hash tables).
3. **`context`**: The memory management context in which the I/O occurred (`normal` for shared buffers, `vacuum` for autovacuum/manual vacuum, `bulkread` for sequential scans bypassing shared buffers via a 256KB ring buffer, `bulkwrite` for `COPY` or `CREATE TABLE AS`).
4. **`op`**: The exact physical I/O operation (`reads`, `writes`, `extends`, `hits`, `evictions`, `reuses`, `fsyncs`).

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   LEGACY I/O DIAGNOSTICS vs MODERN POSTGRESQL 16+ pg_stat_io           │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         LEGACY / NAIVE AGENT APPROACH     │       RIGOROUS PG_STAT_IO INVARIANTS       │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Relies on OS iostat or pg_statio        │ • Profiles multi-dimensional metrics via   │
│   (Cannot attribute I/O to specific role) │   backend_type, context, and target        │
│ • Ignores client backend synchronous write│ • Enforces Zero Synchronous Client Writes  │
│   (Queries stall writing dirty buffers)   │   (bgwriter must absorb all dirty buffers) │
│ • Fails to distinguish bulkread from hit  │ • Segregates normal shared hits from       │
│   (Treats 256KB ring scans as cache hits) │   bulkread ring buffer sequential sweeps   │
│ • Disregards temp relation disk spills    │ • Implements Zero Temp Spill Sentinel      │
│   (Overlooked work_mem disk thrashing)    │   (target = 'temp relation' writes = 0)    │
│ • Blinds to checkpointer fsync latency    │ • Tracks fsync counts & fsync_time to      │
│   (Unaware of disk controller saturation) │   prevent checkpoint write stalls          │
│ • Uses raw cumulative numbers             │ • Evaluates differential rate windows      │
│   (Amnesiac to sudden traffic spikes)     │   ΔM = M(t2) - M(t1) over time Δt          │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Storage I/O Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                             THE 6 STORAGE I/O PROFILING CATASTROPHES                               |
+------------------------------------+---------------------------------------------------------------+
| 1. Monolithic Global I/O Blindness | Relying on host-level disk metrics or pg_statio_user_tables;  |
|    (Attribution Failure)           | agents cannot determine whether disk spikes are driven by     |
|                                    | client OLTP queries, autovacuum sweeps, or checkpointer writes|
+------------------------------------+---------------------------------------------------------------+
| 2. Client Backend Synchronous Write| Undersized bgwriter_lru_maxpages forces client queries to     |
|    (Dirty Page Eviction Tax)       | synchronously write dirty buffers to NVMe before reading;     |
|                                    | p99 latency spikes from 1.5ms to >250ms on OLTP paths.        |
+------------------------------------+---------------------------------------------------------------+
| 3. Bulkread Ring Buffer Mirage     | Large sequential table scans utilize a 256KB ring buffer      |
|    (BAS_BULKREAD Hidden Scan)      | (context = 'bulkread'); agents miss that a query is repeatedly|
|                                    | thrashing NVMe because shared_buffers hit metrics stay high.  |
+------------------------------------+---------------------------------------------------------------+
| 4. Temp Relation Disk Spill Spikes | Insufficient work_mem forces hash aggregates, sorts, and CTEs |
|    (target = 'temp relation' Tax)  | to spill dirty pages to temporary disk blocks, exhausting IOPS|
|                                    | and blocking concurrent transactions.                         |
+------------------------------------+---------------------------------------------------------------+
| 5. Autovacuum Storage Starvation   | Misconfigured autovacuum cost limits either starve vacuuming  |
|    (context = 'vacuum' Imbalance)  | (inducing table bloat) or allow it to saturate storage paths, |
|                                    | stealing I/O bandwidth from revenue-critical client queries.  |
+------------------------------------+---------------------------------------------------------------+
| 6. Checkpointer Fsync Stalls       | Burst checkpoints flush massive dirty buffer queues at once;  |
|    (Storage Controller Saturation) | fsync latency spikes cause write stalls and kernel writeback  |
|                                    | freezes across all database client threads.                   |
+------------------------------------+---------------------------------------------------------------+
```

---

### The 5-Tier `pg_stat_io` Governance Ladder

```
  Tier 4: Automated CI/CD I/O Regression Verification & Continuous Anomaly Sentinels
       ▲  (Assert Zero Temp Spills, Zero Client Writes, and bounded bulkread ratios in CI)
       │
  Tier 3: Checkpoint & Fsync Smoothing Calibration
       ▲  (Monitor checkpointer fsyncs & write_time; calibrate checkpoint_completion_target = 0.9)
       │
  Tier 2: WorkMem Temp Relation Spill Elimination Enclave
       ▲  (Eliminate target = 'temp relation' writes by tuning work_mem and indexing sort keys)
       │
  Tier 1: Client Backend Zero-Synchronous-Write Protection (Zero Dirty Evictions)
       ▲  (Ensure bgwriter absorbs 100% of dirty buffer flushes; client backend writes == 0)
       │
  Tier 0: PostgreSQL 16+ Engine Compatibility, track_io_timing & Differential Baselines
          (Verify PG >= 16, activate track_io_timing = on, compute ΔM = M(t2) - M(t1))
```

---

## 2. Mathematical Foundations & Formal Storage Physics

### Theorem 1: Client Backend Synchronous Dirty Writeback Latency Penalty

Let $T_{\text{read}}$ denote the baseline latency of an OLTP read query when clean buffer pool pages or OS page cache hits are available. When `shared_buffers` lacks unallocated or clean pages, the client backend must execute the Clock-Sweep eviction algorithm. If the selected victim buffer is dirty ($\text{BM\_DIRTY}$), the client backend itself must issue a synchronous `write()` and wait for I/O completion:

$$T_{\text{client}} = T_{\text{read}} + \mathbb{I}(\text{dirty\_victim}) \cdot \left( T_{\text{seek}} + \frac{S_{\text{block}}}{R_{\text{write}}} + T_{\text{journal\_wait}} \right)$$

Where:
- $\mathbb{I}(\text{dirty\_victim}) \in \{0, 1\}$ is the indicator variable indicating whether the evicted block was dirty.
- $T_{\text{seek}}$ is the storage seek / queue dispatch latency (typically $0.1\text{ms}$ on NVMe, $5\text{ms}$ on EBS/HDD).
- $S_{\text{block}} = 8192\text{ bytes}$ is the standard PostgreSQL block size.
- $R_{\text{write}}$ is the random write throughput of the storage subsystem.
- $T_{\text{journal\_wait}}$ is the file system journal commit delay.

**The Synchronous Writeback Degradation Theorem**: If `client backend` synchronous writes $\Delta W_{\text{client}} > 0$, client p99 latency degrades by an amplification factor $\mathcal{A}_{\text{stall}}$:

$$\mathcal{A}_{\text{stall}} = 1 + \frac{\Delta W_{\text{client}}}{\Delta R_{\text{client}}} \cdot \left( \frac{\bar{T}_{\text{write}}}{\bar{T}_{\text{read}}} \right) \ge 10.0$$

Under production OLTP workloads, any non-zero value for `client backend` writes in `context = 'normal'` indicates a failure of the Background Writer (`bgwriter`) to maintain a sufficient pool of clean buffers.

---

### Theorem 2: Bulkread Ring Buffer Spillover & Eviction Calculus

When an unindexed query or large sequential scan begins, PostgreSQL allocates a fixed-size ring buffer:
- For `bulkread`: $S_{\text{ring}} = 256\text{ KB} = 32\text{ blocks}$.
- For `bulkwrite` (`COPY`, `VACUUM`): $S_{\text{ring}} = 16\text{ MB} = 2048\text{ blocks}$.

The number of blocks reused within the ring buffer is tracked by `reuses`. The ring buffer efficiency ratio $\eta_{\text{bulk}}$ is defined as:

$$\eta_{\text{bulk}} = \frac{\Delta \text{reuses}}{\Delta \text{reads} + \Delta \text{hits} + \Delta \text{reuses}}$$

**The Bulkread Scanning Invariant**: If $\Delta \text{reads}_{\text{bulkread}} \gg \Delta \text{reads}_{\text{normal}}$, an autonomous query is executing unindexed sequential scans that bypass `shared_buffers`. While this prevents the scan from evicting general OLTP cache pages, it indicates high physical NVMe I/O consumption that starves the storage controller:

$$\mathcal{R}_{\text{bulk\_pressure}} = \frac{\Delta \text{reads}_{\text{bulkread}}}{\Delta \text{reads}_{\text{normal}} + \Delta \text{reads}_{\text{bulkread}}}$$

If $\mathcal{R}_{\text{bulk\_pressure}} > 0.40$ during OLTP operational windows, secondary indexing or partition pruning is strictly required.

---

### Theorem 3: Multi-Dimensional Differential I/O Flux Model

Because cumulative counters in `pg_stat_io` increase monotonically from cluster initialization, autonomous agents must never evaluate raw counter values. All audits must measure differential I/O flux $\Delta \mathbf{\Phi}_{\text{io}}$ across a bounded time window $\Delta t = t_2 - t_1$:

$$\Delta \mathbf{\Phi}_{\text{io}}(b, t, c) = \frac{\mathbf{M}_{t_2}(b, t, c) - \mathbf{M}_{t_1}(b, t, c)}{\Delta t}$$

Where:
- $b \in \text{backend\_type}$
- $t \in \text{target}$
- $c \in \text{context}$
- $\mathbf{M} = \begin{bmatrix} \text{reads} & \text{writes} & \text{extends} & \text{hits} & \text{evictions} & \text{reuses} & \text{fsyncs} \end{bmatrix}^T$

**Storage Health Scoring Function**: The overall Storage I/O Health Score $\mathcal{H}_{\text{io}} \in [0, 100]$ is governed by penalty deductions for dirty evictions, temp disk spills, and fsync stalls:

$$\mathcal{H}_{\text{io}} = 100 - \min\left(40, 40 \cdot \frac{\Delta W_{\text{client, normal}}}{\max(1, \Delta R_{\text{client, normal}})}\right) - \min\left(35, 35 \cdot \frac{\Delta W_{\text{temp}}}{\max(1, \Delta W_{\text{total}})}\right) - \min\left(25, 2.5 \cdot \Delta \text{fsync\_time}\right)$$

---

## 3. Production TypeScript Guard Engine (`AgenticPgStatIoGuardEngine`)

```typescript
/**
 * Agentic Database pg_stat_io Guard Engine
 * Production-ready TypeScript module for PostgreSQL 16+ multi-dimensional
 * storage I/O diagnostics, dirty page eviction defense, and temp spill elimination.
 */

export interface PgStatIoRecord {
  backend_type: string;
  target: 'relation' | 'temp relation';
  context: 'normal' | 'vacuum' | 'bulkread' | 'bulkwrite';
  reads: number;
  read_time: number;
  writes: number;
  write_time: number;
  writebacks: number;
  writeback_time: number;
  extends: number;
  extend_time: number;
  op_bytes: number;
  hits: number;
  evictions: number;
  reuses: number;
  fsyncs: number;
  fsync_time: number;
  stats_reset: string | null;
}

export interface DifferentialIoWindow {
  elapsedSeconds: number;
  timestamp: string;
  metrics: DifferentialIoMetric[];
  anomalies: IoAnomaly[];
  healthScore: number;
  recommendations: string[];
}

export interface DifferentialIoMetric {
  backend_type: string;
  target: string;
  context: string;
  deltaReads: number;
  deltaReadRateBps: number;
  deltaWrites: number;
  deltaWriteRateBps: number;
  deltaHits: number;
  deltaEvictions: number;
  deltaReuses: number;
  deltaFsyncs: number;
  readHitRatio: number;
}

export interface IoAnomaly {
  severity: 'CRITICAL' | 'HIGH' | 'MEDIUM';
  category: 'CLIENT_DIRTY_WRITE' | 'TEMP_RELATION_SPILL' | 'BULKREAD_FLOOD' | 'FSYNC_STALL' | 'BGWRITER_DEFICIT';
  backendType: string;
  context: string;
  description: string;
  impact: string;
  mitigation: string;
}

export class AgenticPgStatIoGuardEngine {
  private previousSnapshot: Map<string, PgStatIoRecord> | null = null;
  private previousTimestamp: number = 0;

  /**
   * Generates unique composite key for the multi-dimensional tuple.
   */
  private makeKey(record: { backend_type: string; target: string; context: string }): string {
    return `${record.backend_type}::${record.target}::${record.context}`;
  }

  /**
   * Evaluates a live collection of pg_stat_io rows against previous snapshot.
   */
  public evaluateDifferentialSnapshot(
    currentRecords: PgStatIoRecord[],
    currentTimestamp: number = Date.now()
  ): DifferentialIoWindow | null {
    const currentMap = new Map<string, PgStatIoRecord>();
    for (const rec of currentRecords) {
      currentMap.set(this.makeKey(rec), rec);
    }

    if (!this.previousSnapshot) {
      this.previousSnapshot = currentMap;
      this.previousTimestamp = currentTimestamp;
      return null; // Warmup snapshot captured
    }

    const elapsedSeconds = Math.max(0.001, (currentTimestamp - this.previousTimestamp) / 1000.0);
    const metrics: DifferentialIoMetric[] = [];
    const anomalies: IoAnomaly[] = [];
    const recommendations: string[] = [];

    let totalClientNormalWrites = 0;
    let totalTempWrites = 0;
    let totalFsyncTimeMs = 0;

    for (const [key, curr] of currentMap.entries()) {
      const prev = this.previousSnapshot.get(key) || {
        ...curr,
        reads: 0,
        writes: 0,
        hits: 0,
        evictions: 0,
        reuses: 0,
        fsyncs: 0,
        read_time: 0,
        write_time: 0,
        fsync_time: 0
      };

      const deltaReads = Math.max(0, curr.reads - prev.reads);
      const deltaWrites = Math.max(0, curr.writes - prev.writes);
      const deltaHits = Math.max(0, curr.hits - prev.hits);
      const deltaEvictions = Math.max(0, curr.evictions - prev.evictions);
      const deltaReuses = Math.max(0, curr.reuses - prev.reuses);
      const deltaFsyncs = Math.max(0, curr.fsyncs - prev.fsyncs);
      const deltaFsyncTime = Math.max(0, curr.fsync_time - prev.fsync_time);

      const blockSize = curr.op_bytes || 8192;
      const deltaReadRateBps = (deltaReads * blockSize) / elapsedSeconds;
      const deltaWriteRateBps = (deltaWrites * blockSize) / elapsedSeconds;

      const totalAccesses = deltaReads + deltaHits;
      const readHitRatio = totalAccesses > 0 ? (deltaHits / totalAccesses) * 100 : 100.0;

      metrics.push({
        backend_type: curr.backend_type,
        target: curr.target,
        context: curr.context,
        deltaReads,
        deltaReadRateBps,
        deltaWrites,
        deltaWriteRateBps,
        deltaHits,
        deltaEvictions,
        deltaReuses,
        deltaFsyncs,
        readHitRatio: Math.round(readHitRatio * 10) / 10,
      });

      // Anomaly Check 1: Client Backend Synchronous Dirty Buffer Writes
      if (curr.backend_type === 'client backend' && curr.context === 'normal' && deltaWrites > 0) {
        totalClientNormalWrites += deltaWrites;
        anomalies.push({
          severity: 'CRITICAL',
          category: 'CLIENT_DIRTY_WRITE',
          backendType: curr.backend_type,
          context: curr.context,
          description: `Client backend synchronously wrote ${deltaWrites} dirty buffers (${((deltaWrites * blockSize) / 1024).toFixed(1)} KB) directly to disk.`,
          impact: 'Causes transaction p99 latency spikes and connection pool queue stalls.',
          mitigation: 'Elevate bgwriter_lru_maxpages and reduce bgwriter_delay to let bgwriter flush dirty pages ahead of time.',
        });
      }

      // Anomaly Check 2: Temp Relation Disk Spills
      if (curr.target === 'temp relation' && deltaWrites > 0) {
        totalTempWrites += deltaWrites;
        anomalies.push({
          severity: 'HIGH',
          category: 'TEMP_RELATION_SPILL',
          backendType: curr.backend_type,
          context: curr.context,
          description: `Temporary relations spilled ${deltaWrites} blocks (${((deltaWrites * blockSize) / 1024).toFixed(1)} KB) to disk storage.`,
          impact: 'External merge sorts and hash joins spilling to disk exhaust NVMe write IOPS.',
          mitigation: 'Increase transaction work_mem or create supporting indexes to replace in-memory sorts/hashes with B-Tree scans.',
        });
      }

      // Anomaly Check 3: Bulkread Flood (Table Scan Thrash)
      if (curr.context === 'bulkread' && deltaReads > 5000 && deltaReadRateBps > 10 * 1024 * 1024) {
        anomalies.push({
          severity: 'HIGH',
          category: 'BULKREAD_FLOOD',
          backendType: curr.backend_type,
          context: curr.context,
          description: `Bulkread ring buffer streaming at ${(deltaReadRateBps / (1024 * 1024)).toFixed(1)} MB/s (${deltaReads} blocks read).`,
          impact: 'Large sequential table scans are saturating storage bandwidth without leveraging shared_buffers.',
          mitigation: 'Inspect slow queries for missing composite indexes or non-sargable WHERE predicates.',
        });
      }

      // Track Fsync Stalls
      if (deltaFsyncTime > 50) {
        totalFsyncTimeMs += deltaFsyncTime;
        anomalies.push({
          severity: 'MEDIUM',
          category: 'FSYNC_STALL',
          backendType: curr.backend_type,
          context: curr.context,
          description: `Fsync execution accumulated ${deltaFsyncTime.toFixed(1)}ms across ${deltaFsyncs} calls.`,
          impact: 'Storage controller write cache saturation or disk write latency cliff.',
          mitigation: 'Smooth checkpoints via checkpoint_completion_target = 0.9 and increase checkpoint_timeout.',
        });
      }
    }

    // Recommendations Synthesis
    if (totalClientNormalWrites > 0) {
      recommendations.push(
        `BGWRITER TUNING: Client backends executed ${totalClientNormalWrites} synchronous writes. Increase bgwriter_lru_maxpages (e.g. 400->800) and check bgwriter_lru_multiplier (e.g. 2.0->3.0).`
      );
    }
    if (totalTempWrites > 0) {
      recommendations.push(
        `WORK_MEM TUNING: Temp relations incurred ${totalTempWrites} disk block writes. Elevate default work_mem or configure targeted SET LOCAL work_mem for reporting workloads.`
      );
    }
    if (totalFsyncTimeMs > 200) {
      recommendations.push(
        `CHECKPOINT SMOOTHING: High fsync wait time (${totalFsyncTimeMs.toFixed(1)}ms). Ensure checkpoint_completion_target = 0.9 and checkpoint_timeout >= 15min.`
      );
    }

    // Health Score Calculation
    let healthScore = 100;
    if (totalClientNormalWrites > 0) healthScore -= Math.min(40, totalClientNormalWrites * 2);
    if (totalTempWrites > 0) healthScore -= Math.min(35, totalTempWrites * 1);
    if (totalFsyncTimeMs > 100) healthScore -= Math.min(25, (totalFsyncTimeMs / 100) * 5);
    healthScore = Math.max(0, Math.round(healthScore));

    // Update state for next cycle
    this.previousSnapshot = currentMap;
    this.previousTimestamp = currentTimestamp;

    return {
      elapsedSeconds,
      timestamp: new Date(currentTimestamp).toISOString(),
      metrics,
      anomalies,
      healthScore,
      recommendations,
    };
  }

  /**
   * Canonical SQL query for extracting complete pg_stat_io telemetry in PostgreSQL 16+.
   */
  public static getExtractionSql(): string {
    return `
      SELECT
        backend_type,
        target,
        context,
        reads,
        read_time,
        writes,
        write_time,
        writebacks,
        writeback_time,
        extends,
        extend_time,
        op_bytes,
        hits,
        evictions,
        reuses,
        fsyncs,
        fsync_time,
        stats_reset
      FROM pg_stat_io
      ORDER BY backend_type, target, context;
    `;
  }
}
```

---

## 4. Cross-Runtime Implementations

### 4.1 Go (`jackc/pgx/v5`): Differential Storage I/O Telemetry Collector

```go
package telemetry

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// PgStatIoRow maps exactly to the PostgreSQL 16+ pg_stat_io schema.
type PgStatIoRow struct {
	BackendType   string   `db:"backend_type"`
	Target        string   `db:"target"`
	Context       string   `db:"context"`
	Reads         int64    `db:"reads"`
	ReadTime      float64  `db:"read_time"`
	Writes        int64    `db:"writes"`
	WriteTime     float64  `db:"write_time"`
	Writebacks    int64    `db:"writebacks"`
	WritebackTime float64  `db:"writeback_time"`
	Extends       int64    `db:"extends"`
	ExtendTime    float64  `db:"extend_time"`
	OpBytes       int64    `db:"op_bytes"`
	Hits          int64    `db:"hits"`
	Evictions     int64    `db:"evictions"`
	Reuses        int64    `db:"reuses"`
	Fsyncs        int64    `db:"fsyncs"`
	FsyncTime     float64  `db:"fsync_time"`
}

type StorageIoSentinel struct {
	pool       *pgxpool.Pool
	logger     *slog.Logger
	mu         sync.Mutex
	prevMap    map[string]PgStatIoRow
	prevTime   time.Time
}

func NewStorageIoSentinel(pool *pgxpool.Pool, logger *slog.Logger) *StorageIoSentinel {
	return &StorageIoSentinel{
		pool:    pool,
		logger:  logger,
		prevMap: make(map[string]PgStatIoRow),
	}
}

func (s *StorageIoSentinel) PollAndAudit(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	query := `
		SELECT
			backend_type, target, context,
			reads, read_time, writes, write_time,
			writebacks, writeback_time, extends, extend_time,
			op_bytes, hits, evictions, reuses, fsyncs, fsync_time
		FROM pg_stat_io;
	`

	rows, err := s.pool.Query(ctx, query)
	if err != nil {
		return fmt.Errorf("failed to query pg_stat_io: %w", err)
	}
	defer rows.Close()

	currMap := make(map[string]PgStatIoRow)
	now := time.Now()

	for rows.Next() {
		var r PgStatIoRow
		if err := rows.Scan(
			&r.BackendType, &r.Target, &r.Context,
			&r.Reads, &r.ReadTime, &r.Writes, &r.WriteTime,
			&r.Writebacks, &r.WritebackTime, &r.Extends, &r.ExtendTime,
			&r.OpBytes, &r.Hits, &r.Evictions, &r.Reuses, &r.Fsyncs, &r.FsyncTime,
		); err != nil {
			return fmt.Errorf("failed to scan pg_stat_io row: %w", err)
		}
		key := fmt.Sprintf("%s::%s::%s", r.BackendType, r.Target, r.Context)
		currMap[key] = r
	}

	if len(s.prevMap) == 0 {
		s.prevMap = currMap
		s.prevTime = now
		s.logger.Info("pg_stat_io baseline initialized")
		return nil
	}

	elapsed := now.Sub(s.prevTime).Seconds()
	if elapsed <= 0 {
		elapsed = 1.0
	}

	var clientDirtyWrites int64
	var tempRelationWrites int64

	for key, curr := range currMap {
		prev, ok := s.prevMap[key]
		if !ok {
			continue
		}

		deltaWrites := curr.Writes - prev.Writes
		deltaReads := curr.Reads - prev.Reads
		deltaHits := curr.Hits - prev.Hits

		// Audit 1: Detect Client Backend Synchronous Writes
		if curr.BackendType == "client backend" && curr.Context == "normal" && deltaWrites > 0 {
			clientDirtyWrites += deltaWrites
			s.logger.Error("CRITICAL: client backend dirty buffer synchronous write detected",
				slog.Int64("delta_writes", deltaWrites),
				slog.Float64("elapsed_sec", elapsed),
				slog.String("action", "increase bgwriter_lru_maxpages and check bgwriter_delay"),
			)
		}

		// Audit 2: Detect Temp Relation Spills
		if curr.Target == "temp relation" && deltaWrites > 0 {
			tempRelationWrites += deltaWrites
			s.logger.Warn("HIGH: temp relation disk spill detected",
				slog.String("backend_type", curr.BackendType),
				slog.Int64("delta_writes", deltaWrites),
				slog.String("action", "raise work_mem or optimize sorting queries"),
			)
		}

		// Audit 3: Detect Bulkread Ring Buffer Pressure
		if curr.Context == "bulkread" && deltaReads > 5000 {
			rateMB := (float64(deltaReads*curr.OpBytes) / (1024 * 1024)) / elapsed
			s.logger.Warn("HIGH: high bulkread ring buffer throughput",
				slog.Float64("rate_mb_per_sec", math.Round(rateMB*10)/10),
				slog.Int64("delta_reads", deltaReads),
				slog.String("action", "inspect for missing composite indexes causing sequential table sweeps"),
			)
		}

		_ = deltaHits
	}

	s.prevMap = currMap
	s.prevTime = now
	return nil
}
```

---

### 4.2 Python (`asyncpg`): Storage I/O Assertion Harness

```python
"""
Python asyncpg Sentinel for PostgreSQL 16+ pg_stat_io Storage Auditing.
"""

import asyncio
from typing import Dict, Any, List
import asyncpg


class PgStatIoAuditor:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool
        self._prev_snapshot: Dict[str, Dict[str, Any]] = {}
        self._prev_time: float = 0.0

    async def audit_storage_window(self) -> Dict[str, Any]:
        query = """
            SELECT
                backend_type, target, context,
                reads, read_time, writes, write_time,
                hits, evictions, reuses, fsyncs, fsync_time, op_bytes
            FROM pg_stat_io;
        """
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)

        now = asyncio.get_event_loop().time()
        curr_snapshot: Dict[str, Dict[str, Any]] = {
            f"{r['backend_type']}::{r['target']}::{r['context']}": dict(r)
            for r in rows
        }

        if not self._prev_snapshot:
            self._prev_snapshot = curr_snapshot
            self._prev_time = now
            return {"status": "INITIALIZED", "anomalies": []}

        elapsed = max(0.001, now - self._prev_time)
        anomalies: List[Dict[str, Any]] = []

        for key, curr in curr_snapshot.items():
            prev = self._prev_snapshot.get(key)
            if not prev:
                continue

            delta_writes = max(0, curr["writes"] - prev["writes"])
            delta_reads = max(0, curr["reads"] - prev["reads"])

            # Critical: Synchronous Client Dirty Writes
            if curr["backend_type"] == "client backend" and curr["context"] == "normal" and delta_writes > 0:
                anomalies.append({
                    "severity": "CRITICAL",
                    "type": "CLIENT_DIRTY_WRITE",
                    "delta_writes": delta_writes,
                    "bytes": delta_writes * (curr.get("op_bytes") or 8192),
                    "message": "Client backend synchronously flushed dirty pages. bgwriter is falling behind."
                })

            # High: Temp Relation Spills
            if curr["target"] == "temp relation" and delta_writes > 0:
                anomalies.append({
                    "severity": "HIGH",
                    "type": "TEMP_SPILL",
                    "delta_writes": delta_writes,
                    "message": "Temporary relation written to disk. work_mem is undersized for current queries."
                })

        self._prev_snapshot = curr_snapshot
        self._prev_time = now

        return {
            "status": "PASSED" if not anomalies else "VIOLATIONS_FOUND",
            "elapsed_seconds": elapsed,
            "anomalies": anomalies,
        }
```

---

### 4.3 Rust (`sqlx`): Zero-Allocation Storage I/O Gate

```rust
use sqlx::{PgPool, FromRow};
use std::collections::HashMap;
use std::time::Instant;

#[derive(Debug, FromRow, Clone)]
pub struct PgStatIoMetric {
    pub backend_type: String,
    pub target: String,
    pub context: String,
    pub reads: i64,
    pub writes: i64,
    pub hits: i64,
    pub evictions: i64,
    pub op_bytes: Option<i64>,
}

pub struct StorageIoGate {
    pool: PgPool,
    prev_state: HashMap<String, PgStatIoMetric>,
    last_poll: Option<Instant>,
}

impl StorageIoGate {
    pub fn new(pool: PgPool) -> Self {
        Self {
            pool,
            prev_state: HashMap::new(),
            last_poll: None,
        }
    }

    pub async fn verify_zero_client_writes(&mut self) -> Result<bool, sqlx::Error> {
        let rows = sqlx::query_as::<_, PgStatIoMetric>(
            r#"
            SELECT
                backend_type, target, context,
                reads, writes, hits, evictions, op_bytes
            FROM pg_stat_io;
            "#
        )
        .fetch_all(&self.pool)
        .await?;

        let mut curr_map = HashMap::new();
        for r in rows {
            let key = format!("{}::{}::{}", r.backend_type, r.target, r.context);
            curr_map.insert(key, r);
        }

        if self.prev_state.is_empty() {
            self.prev_state = curr_map;
            self.last_poll = Some(Instant::now());
            return Ok(true);
        }

        let mut violation = false;

        for (key, curr) in &curr_map {
            if let Some(prev) = self.prev_state.get(key) {
                let delta_writes = curr.writes - prev.writes;

                // Enforce Zero Synchronous Client Writes Invariant
                if curr.backend_type == "client backend" && curr.context == "normal" && delta_writes > 0 {
                    eprintln!(
                        "CRITICAL REGRESSION: client backend executed {} synchronous writes!",
                        delta_writes
                    );
                    violation = true;
                }

                // Enforce Zero Temp Spills Invariant
                if curr.target == "temp relation" && delta_writes > 0 {
                    eprintln!(
                        "HIGH REGRESSION: temp relation spilled {} blocks to disk!",
                        delta_writes
                    );
                    violation = true;
                }
            }
        }

        self.prev_state = curr_map;
        self.last_poll = Some(Instant::now());

        Ok(!violation)
    }
}
```

---

## 5. 6-State Storage Profiling Lifecycle Finite-State Machine (FSM)

```
        ┌────────────────────────────────────────────────────────┐
        │  [1] COMPATIBILITY_CHECK (PG 16+ & track_io_timing)   │
        └──────────────────────────┬─────────────────────────────┘
                                   │ Engine >= 16 confirmed
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │  [2] BASELINE_WARMUP (Snapshot Initial pg_stat_io M0)  │
        └──────────────────────────┬─────────────────────────────┘
                                   │ Window Δt elapsed (e.g. 60s)
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │  [3] DIFFERENTIAL_ACQUISITION (Calculate ΔM = M1 - M0) │
        └──────────────────────────┬─────────────────────────────┘
                                   │ Differential flux computed
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │  [4] DIMENSIONAL_TRIAGE & ANOMALY CLASSIFICATION       │
        │      • client backend writes == 0?                     │
        │      • target = 'temp relation' writes == 0?           │
        │      • bulkread / normal ratio <= 0.40?                │
        │      • fsync stalls <= 50ms?                           │
        └───────┬────────────────────────────────────────┬───────┘
                │ Anomalies detected                     │ Zero anomalies
                ▼                                        ▼
   ┌─────────────────────────────┐         ┌─────────────────────────────┐
   │ [5] REMEDIATION_ORCHESTRATION│         │ [6] PRODUCTION_CERTIFICATION│
   │  • Tune bgwriter_lru_maxpage│         │     • DoD Gates Passed      │
   │  • Elevate work_mem         │         │     • Storage Health == 100 │
   │  • Add missing B-Tree index │         │     • CI Gate Green         │
   └────────────┬────────────────┘         └─────────────────────────────┘
                │
                └───────► Loop back to [3] for Re-verification
```

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Matrix & Autonomous Runbook Checklist

### 6.1 Definition of Done (DoD) Gates

| Gate ID | Verification Stage | Exact Metric / Query Expression | Threshold / Acceptance Criterion | Enforcement Point |
| :--- | :--- | :--- | :--- | :--- |
| **Gate 1: Engine Compatibility** | PostgreSQL Engine Check | `SHOW server_version_num;` | $\ge 160000$ (PostgreSQL 16.0+) | Migration Pre-flight Gate |
| **Gate 2: Timer Instrumentation** | I/O Timing Readiness | `SHOW track_io_timing;` | `on` | Configuration Audit Gate |
| **Gate 3: Client Backend Writes** | Dirty Buffer Eviction Check | $\Delta \text{writes}$ for `backend_type = 'client backend'` and `context = 'normal'` | $\Delta \text{writes} = 0$ | High-Concurrency Load Test Gate |
| **Gate 4: Zero Temp Spills** | Memory WorkMem Spillage Check | $\Delta \text{writes}$ for `target = 'temp relation'` | $\Delta \text{writes} = 0$ on all standard query paths | Integration Test Gate |
| **Gate 5: Bulkread Ratio** | Sequential Sweep Containment | $\Delta R_{\text{bulkread}} / (\Delta R_{\text{normal}} + \Delta R_{\text{bulkread}})$ | $\le 0.40$ during operational query runs | Staging Canary Gate |
| **Gate 6: Fsync Stability** | Storage Controller Saturation | $\Delta \text{fsync\_time}$ across checkpointer | $\le 100\text{ms}$ per 60-second window | Continuous APM Watchdog Gate |

---

### 6.2 Autonomous Runbook Checklist

- [ ] **Verify PostgreSQL Version**: Confirm cluster is running PostgreSQL 16 or newer via `SELECT version()`.
- [ ] **Activate I/O Timing**: Ensure `track_io_timing = on` in `postgresql.conf` to capture exact microsecond timings for reads, writes, and fsyncs.
- [ ] **Audit Client Backend Synchronous Writes**: Continuously monitor `pg_stat_io` for `backend_type = 'client backend'` and `context = 'normal'`. If `writes > 0`, immediately elevate `bgwriter_lru_maxpages` (e.g. from 100 to 800) and reduce `bgwriter_delay` (e.g. from 200ms to 20ms).
- [ ] **Eliminate Temp Relation Disk Spills**: Inspect `target = 'temp relation'` writes. If non-zero, identify sort-heavy queries and raise `work_mem` or construct B-Tree indexes matching the `ORDER BY` clause.
- [ ] **Detect Bulkread Infiltration**: Track `context = 'bulkread'` reads. If bulkread throughput dominates normal shared buffer hits, run `EXPLAIN (BUFFERS)` to identify unindexed full table scans.
- [ ] **Smooth Checkpointer Writes**: Check `fsync_time` on the checkpointer. Ensure `checkpoint_completion_target = 0.9` and `checkpoint_timeout` is at least 15 minutes to avoid I/O bursts.
- [ ] **Enforce Windowed Differentials**: Never make architectural decisions based on raw `pg_stat_io` counters; always evaluate delta metrics over 60-second windows ($\Delta M = M(t_2) - M(t_1)$).
