---
description: PostgreSQL online table bloat compaction, zero-downtime index rebuilds, elimination of destructive VACUUM FULL table lockouts, 2.2x disk safety margins, WAL replication lag throttling, DDL lock queue head-of-line blocking defense, and orphaned trigger cleanup via pg_repack across Go (pgx/v5), TypeScript (Kysely, Drizzle, Prisma), Python (asyncpg, SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{repack,bloat,vacuum,compact,reindex,maintenance,database,db,migration,storage}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/maintenance/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database `pg_repack`, Online Table Bloat Compaction, Zero-Downtime Index Rebuilds & Exclusive Lock Minimization Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to remediate database bloat, compact fragmented relations, rebuild bloated B-Tree indexes, restore physical clustering, or perform online schema and heap defragmentation across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Destructive `VACUUM FULL` Outage Catastrophe" (where agents run `VACUUM FULL`, acquiring multi-hour `ACCESS EXCLUSIVE` locks that block all concurrent reads and writes, bringing down production OLTP applications and causing connection pool exhaustion), the "2.2x Disk Storage Exhaustion Meltdown" (where `pg_repack` builds a full shadow table and secondary indexes while recording incoming write mutations, consuming over $2.2 \times$ relation size and driving disk capacity to 100% full, crashing PostgreSQL into an emergency read-only state), the "WAL Ingestion Storm & Standby Replication Lag Tsunami" (where high-speed bulk tuple copies generate gigabytes of write-ahead logs per minute, overflowing replication slots and driving replica lag to hours), the "Head-of-Line DDL Lock Queue Blockade" (where `pg_repack` requests an `ACCESS EXCLUSIVE` lock for catalog swapping without strict `lock_timeout`, queuing behind slow transactions and blocking all subsequent application queries), the "Orphaned Shadow Objects & Zombie Trigger Space Leak" (where aborted or ungracefully terminated repack jobs leave change-capture triggers and log tables active, permanently inflating write IOPS and disk consumption until manual cleanup), and the "Missing Primary Key / NOT NULL Constraint Rejection Trap" (where unvalidated tables lack primary keys, causing repack jobs to abort after hours of wasted I/O) by establishing a strict 5-Tier `pg_repack` Governance Ladder, bloat compaction mathematics, an autonomous TypeScript `AgenticPgRepackGuardEngine`, cross-runtime implementations in Go, Python, and Rust, a 6-state compaction finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Online Compaction Catastrophes vs The 5-Tier Governance Ladder

Relational databases utilizing Multi-Version Concurrency Control (MVCC) do not overwrite data in-place during updates or deletions; they append new tuple versions and mark obsolete versions as dead. Standard background `autovacuum` sweeps mark dead tuple space as reusable within existing disk pages, but it **never returns physical disk pages to the host operating system** unless pages at the very end of the physical file happen to become completely empty.

Over time, sporadic updates, delete bursts, and suboptimal fillfactors generate massive **heap and index bloat**: tables consume 5x to 50x more disk space than the live tuples require, cache hit ratios plummet, and sequential scans must read gigabytes of empty space. When agents attempt to compact this space, naive approaches cause severe outages:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   NAIVE BLOAT COMPACTION vs PRODUCTION pg_repack INVARIANTS            │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Run VACUUM FULL table_name;             │ • Strict Prohibition of VACUUM FULL:       │
│   (Acquires ACCESS EXCLUSIVE lock; blocks │   Use pg_repack --table for zero-downtime  │
│    all SELECT, INSERT, UPDATE for hours)  │   online compaction with millisecond swap  │
│ • Launch repack without disk check        │ • Enforce Free Space >= 2.2x (Table + Idx):│
│   (Disks fill to 100%, causing cluster-   │   Pre-flight check blocks repack if disk   │
│    wide emergency crash / read-only)      │   headroom is insufficient                 │
│ • Repack during peak business traffic     │ • Maintenance Window + WAL Rate Throttling:│
│   (Spikes replication lag into hours;     │   Monitor pg_stat_replication lag; abort   │
│    saturates write I/O bandwidth)         │   if standby lag exceeds 30 seconds        │
│ • Run repack without lock timeouts        │ • Mandatory lock_timeout & --wait-timeout: │
│   (Queues behind slow query; blocks all   │   pg_repack --wait-timeout 2 --no-kill-    │
│    subsequent transactions in lock queue) │   specified to prevent head-of-line freezes│
│ • Kill crashed repack with kill -9        │ • Automated Orphan Cleaner Sentinel:       │
│   (Leaves repack_trigger active; log table│   Detect repack schema artifacts; execute  │
│    leaks disk space permanently)          │   pg_repack --clean before & after jobs    │
│ • Attempt repack on table without PK      │ • Strict PK / NOT NULL Unique Assertion:   │
│   (Fails after hours of processing;       │   Verify primary key existence before      │
│    incompatible with log table replay)    │   allocating system resources              │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Online Compaction Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                                THE 6 ONLINE COMPACTION CATASTROPHES                                |
+------------------------------------+---------------------------------------------------------------+
| 1. The VACUUM FULL Outage Trap     | Acquires ACCESS EXCLUSIVE lock for entire duration; halts all |
|    (Multi-Hour Cluster Freeze)     | reads and writes, inducing connection pool starvation storms. |
+------------------------------------+---------------------------------------------------------------+
| 2. 2.2x Storage Exhaustion Crash   | Building shadow table + shadow indexes + log tables consumes  |
|    (Filesystem 100% Full Panics)   | >2.2x relation size; exhausts disk, forcing PostgreSQL crash. |
+------------------------------------+---------------------------------------------------------------+
| 3. Replication Lag Tsunami         | Bulk copy generates gigabytes of WAL per minute; saturates    |
|    (Read Replica Drift & Drop)     | replication channels, causing replica queries to fail.        |
+------------------------------------+---------------------------------------------------------------+
| 4. DDL Head-of-Line Blockade       | Catalog swap requests exclusive lock without timeout; queues  |
|    (Lock Queue Cascading Outage)   | behind long queries, blocking all new incoming application SQL|
+------------------------------------+---------------------------------------------------------------+
| 5. Orphaned Trigger Space Leak     | Aborted repack leaves repack_trigger and repack.log active;   |
|    (Silent Permanent Disk Bleed)   | incoming writes silently inflate orphaned log tables forever. |
+------------------------------------+---------------------------------------------------------------+
| 6. Missing Primary Key Rejection   | pg_repack relies on PK / UNIQUE NOT NULL for replay; fails on |
|    (Pre-Condition Ignorance)       | tables lacking keys, aborting after heavy lock/disk activity. |
+------------------------------------+---------------------------------------------------------------+
```

### The 5-Tier `pg_repack` Governance Ladder

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                   5-TIER pg_repack GOVERNANCE LADDER                             │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Engine Prerequisite, PK Verification & Absolute Zero VACUUM FULL Mandate │
│   - Check pg_repack extension installed in cluster                               │
│   - Assert target table has PRIMARY KEY or UNIQUE NOT NULL constraint            │
│   - Ban `VACUUM FULL` in all automated scripts, migrations, and runbooks         │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Storage Headroom Invariance (Disk Free Space >= 2.2x Total Size)         │
│   - Free Space >= 2.2 * (pg_total_relation_size(target))                         │
│   - Calculate max expected mutation churn volume during rebuild duration         │
│   - Abort immediately with actionable error if free storage is insufficient      │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Replication Lag Throttling & Off-Peak Execution Guard                    │
│   - Check pg_stat_replication replay_lag before and during repack                │
│   - Enforce circuit breaker: cancel repack if replica lag > 30 seconds           │
│   - Run exclusively during designated low-traffic or maintenance windows         │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Lock-Timeout Ladders & Head-of-Line Blocking Eradication                 │
│   - Mandatory `--wait-timeout 2` (or 3 seconds max)                              │
│   - Avoid killing concurrent transactions (`--no-kill-backend`)                  │
│   - Limit catalog swap lock acquisition attempt to <= 2000ms                     │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Automated Post-Repack Cleanup, Bloat Verification & Zombie Sentinels     │
│   - Run pg_repack --clean prior to execution to clear stale log tables           │
│   - Assert post-compaction bloat ratio B <= 0.05                                 │
│   - Scheduled sentinel queries alerting on any leftover `repack` schema objects  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Formalization & Physical Mechanics of `pg_repack`

### 2.1 The Internal Mechanics of Zero-Downtime Repack

`pg_repack` achieves online compaction by decoupling the data copy from the primary relation:

```
[Target Table (live)] ────(1. CREATE TRIGGER)───> [repack.log_table]
         │                                               │
         │ (2. Concurrent COPY live tuples)              │ (4. Replay delta logs)
         ▼                                               ▼
[repack.table_XXXX (shadow)] ──(3. CREATE INDEXES)──> [Catch-up Sync]
         │                                               │
         └─────────────(5. Brief ACCESS EXCLUSIVE lock)──┘
                                   │
                                   ▼
                       [Atomic Catalog Swap (relfilenode)]
                                   │
                                   ▼
                       [Old Table Dropped / Reclaimed]
```

1. **Schema Extraction & Shadow Table Creation**: Creates an empty shadow table `repack.table_<oid>` matching the column layout, nullability, and storage attributes of the target table.
2. **Change Capture Trigger Installation**: Installs an `AFTER INSERT / UPDATE / DELETE` trigger (`repack.trigger_<oid>`) on the live target table. Any concurrent application writes are inserted into `repack.log_<oid>`.
3. **Live Tuple Population**: Performs an initial copy: `INSERT INTO repack.table_<oid> SELECT * FROM target_table` with `ACCESS SHARE` lock (allowing uninterrupted concurrent reads and writes).
4. **Index Building**: Concurrently constructs all secondary indexes on the shadow table.
5. **Delta Replay**: Drains rows from `repack.log_<oid>` and applies them to `repack.table_<oid>` in batches using the table's Primary Key.
6. **Atomic Catalog Swap**: Acquires a brief `ACCESS EXCLUSIVE` lock on the target table (typically for 10–50ms), plays the remaining delta log rows, swaps the catalog entries (`pg_class.relfilenode`), drops the trigger, and releases the lock.
7. **Cleanup**: Drops the original storage files and cleans up temporary repack metadata.

### 2.2 Table and Index Bloat Formulation

Let a table have $N_{\text{live}}$ live tuples and $N_{\text{dead}}$ dead tuples. Let $S_{\text{live\_tuple}}$ be the average byte size of a live tuple, and let $S_{\text{page}} = 8192$ bytes (standard PostgreSQL page size):

$$\text{Optimal Bytes} = N_{\text{live}} \times S_{\text{live\_tuple}} \times \frac{100}{\text{fillfactor}}$$

$$\text{Actual Bytes} = \text{pg\_relation\_size}(\text{relation})$$

$$\text{Bloat Ratio } \mathcal{B} = 1 - \frac{\text{Optimal Bytes}}{\text{Actual Bytes}} = \frac{\text{Actual Bytes} - \text{Optimal Bytes}}{\text{Actual Bytes}}$$

When $\mathcal{B} \ge 0.40$ (more than 40% of the relation consists of dead or empty space), compaction is recommended.

### 2.3 Free Disk Space Safety Theorem

$$\text{Required Free Space } D_{\text{free}} \ge 2.2 \times (S_{\text{table}} + S_{\text{indexes}}) + (\mathcal{R}_{\text{write}} \times T_{\text{repack}})$$

Where:
- $S_{\text{table}}$ is the physical on-disk size of the target heap relation.
- $S_{\text{indexes}}$ is the cumulative size of all secondary indexes.
- The factor $2.2$ accounts for the full shadow table, shadow indexes, WAL buffer spikes during construction, and temporary sorting runs in `work_mem` / disk spills.
- $\mathcal{R}_{\text{write}}$ is the peak write throughput (bytes/second) of concurrent application traffic.
- $T_{\text{repack}}$ is the estimated duration of the repack operation.

**The Space Exhaustion Invariant**: If $D_{\text{available}} < D_{\text{free}}$, `pg_repack` MUST NOT be started.

---

## 3. Detecting Bloat & Identifying Compaction Candidates

Autonomous agents must execute diagnostic inspection queries to accurately calculate bloat percentages without running intrusive scans.

### 3.1 Accurate Table Bloat Diagnostic Query

```sql
-- Comprehensive PostgreSQL Table Bloat Diagnostic (PostgreSQL 12+)
WITH constants AS (
  SELECT current_setting('block_size')::numeric AS bs, 23 AS hdr, 8 AS ma
),
table_estimates AS (
  SELECT
    schemaname, tablename,
    tbl.reltuples, tbl.relpages,
    bs,
    CEIL((tbl.reltuples * (
      hdr + ma - (CASE WHEN hdr%ma=0 THEN ma ELSE hdr%ma END) +
      sum((1-null_frac)*avg_width) +
      ma - (CASE WHEN sum((1-null_frac)*avg_width)::integer%ma=0 THEN ma ELSE sum((1-null_frac)*avg_width)::integer%ma END)
    )) / (bs - 24)) AS expected_pages
  FROM pg_tables tbl_meta
  JOIN pg_class tbl ON tbl.relname = tbl_meta.tablename
  JOIN pg_namespace ns ON ns.oid = tbl.relnamespace AND ns.nspname = tbl_meta.schemaname
  JOIN pg_stats s ON s.schemaname = tbl_meta.schemaname AND s.tablename = tbl_meta.tablename
  CROSS JOIN constants
  WHERE tbl.relkind = 'r'
    AND tbl_meta.schemaname NOT IN ('pg_catalog', 'information_schema', 'repack')
  GROUP BY schemaname, tablename, tbl.reltuples, tbl.relpages, bs, hdr, ma
)
SELECT
  schemaname,
  tablename,
  pg_size_pretty(relpages::bigint * bs::bigint) AS actual_size,
  pg_size_pretty(expected_pages::bigint * bs::bigint) AS estimated_optimal_size,
  CASE
    WHEN relpages > expected_pages
    THEN ROUND(100.0 * (relpages - expected_pages) / relpages, 2)
    ELSE 0.0
  END AS bloat_pct,
  pg_size_pretty(GREATEST(0, (relpages - expected_pages)::bigint * bs::bigint)) AS wasted_bytes
FROM table_estimates
WHERE relpages > 100
ORDER BY (relpages - expected_pages) DESC
LIMIT 20;
```

### 3.2 B-Tree Index Bloat Diagnostic Query

```sql
-- B-Tree Index Bloat Diagnostic Query
WITH btree_bloat AS (
  SELECT
    current_setting('block_size')::numeric AS bs,
    ns.nspname AS schemaname,
    tbl.relname AS tablename,
    idx.relname AS indexname,
    idx.reltuples,
    idx.relpages,
    COALESCE(
      CEIL((idx.reltuples * (
        -- Standard B-Tree tuple header (8 bytes) + index data estimate
        8 + 4 + (CASE WHEN s.avg_width IS NULL THEN 8 ELSE s.avg_width END)
      )) / (current_setting('block_size')::numeric - 24)),
      1
    ) AS expected_pages
  FROM pg_index i
  JOIN pg_class idx ON idx.oid = i.indexrelid
  JOIN pg_class tbl ON tbl.oid = i.indrelid
  JOIN pg_namespace ns ON ns.oid = tbl.relnamespace
  LEFT JOIN pg_stats s ON s.schemaname = ns.nspname AND s.tablename = tbl.relname
  WHERE idx.relam = 403 -- btree
    AND ns.nspname NOT IN ('pg_catalog', 'information_schema', 'repack')
    AND idx.relpages > 50
)
SELECT
  schemaname,
  tablename,
  indexname,
  pg_size_pretty(relpages::bigint * bs::bigint) AS index_size,
  CASE
    WHEN relpages > expected_pages
    THEN ROUND(100.0 * (relpages - expected_pages) / relpages, 2)
    ELSE 0.0
  END AS bloat_pct,
  pg_size_pretty(GREATEST(0, (relpages - expected_pages)::bigint * bs::bigint)) AS wasted_bytes
FROM btree_bloat
ORDER BY (relpages - expected_pages) DESC
LIMIT 20;
```

---

## 4. Production Execution Discipline & Safety Flags

When executing `pg_repack`, agents must adhere to strict invocation flags and safety checks.

### 4.1 Required CLI Flags

```bash
# Standard Production Invocation Pattern
pg_repack \
  --dbname="${PGDATABASE}" \
  --host="${PGHOST}" \
  --port="${PGPORT}" \
  --username="${PGUSER}" \
  --table="public.orders" \
  --wait-timeout=2 \
  --no-kill-backend \
  --echo-queries \
  --no-order
```

Flag semantics and requirements:
- `--table="public.orders"`: Always repack specific relations one at a time. Never run `--all` in an automated workflow.
- `--wait-timeout=2`: Sets the maximum time (2 seconds) `pg_repack` will wait in lock queues during the initial trigger setup and final catalog swap. If another transaction holds a conflicting lock, `pg_repack` cancels its lock request and retries later, preventing head-of-line blocking.
- `--no-kill-backend`: Prevents `pg_repack` from forcefully terminating conflicting client transactions when its lock acquisition times out.
- `--no-order`: Avoids sorting the table during repack unless explicit physical re-clustering via a monotonic B-tree index is intentionally desired. (Sorting increases temp disk spills and doubles CPU overhead).

### 4.2 Pre-Flight Primary Key & Constraint Validation

`pg_repack` strictly requires a Primary Key or a UNIQUE constraint where all columns are `NOT NULL`.

```sql
-- Assert Primary Key or NOT NULL Unique Constraint Exists
SELECT
  c.relname AS table_name,
  i.relname AS index_name,
  con.contype AS constraint_type
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_class i ON i.oid = con.conindid
WHERE n.nspname = 'public'
  AND c.relname = 'orders'
  AND con.contype IN ('p', 'u')
  AND NOT EXISTS (
    SELECT 1 FROM pg_attribute a
    WHERE a.attrelid = c.oid
      AND a.attnum = ANY(con.conkey)
      AND NOT a.attnotnull
  );
```

If zero rows return, `pg_repack` cannot run on this table. Running it will abort with:
`ERROR: table "orders" must have a primary key or not-null unique index`

---

## 5. Detecting and Purging Stale Zombie Objects (`pg_repack --clean`)

If a previous `pg_repack` run was terminated via `kill -9`, network drop, or pod eviction, the `repack` schema and trigger remain active on the table.

### 5.1 Zombie Trigger Inspection Query

```sql
-- Check for Orphaned Repack Triggers and Stale Log Tables
SELECT
  trg.tgname AS trigger_name,
  rel.relname AS target_table,
  ns.nspname AS target_schema,
  log_rel.relname AS log_table_name,
  pg_size_pretty(pg_total_relation_size(log_rel.oid)) AS log_table_size
FROM pg_trigger trg
JOIN pg_class rel ON rel.oid = trg.tgrelid
JOIN pg_namespace ns ON ns.oid = rel.relnamespace
LEFT JOIN pg_class log_rel ON log_rel.relname = 'log_' || rel.oid
WHERE trg.tgname LIKE 'repack_trigger%'
   OR rel.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'repack');
```

### 5.2 Safe Autonomous Cleanup Command

Before launching any new repack job, execute the cleanup command:

```bash
# Clean stale temporary objects and orphaned triggers from aborted jobs
pg_repack --dbname="${PGDATABASE}" --clean
```

---

## 6. Complete Production-Ready TypeScript Guard Engine

Below is the complete, zero-dependency, production-grade `AgenticPgRepackGuardEngine`. Autonomous agents must execute this engine before and during any online compaction operation to guarantee safety.

```typescript
/**
 * AgenticPgRepackGuardEngine
 * Production-grade safety validator, disk headroom verifier, lock-timeout enforcer,
 * and lifecycle manager for zero-downtime PostgreSQL table bloat compaction.
 */

export interface RelationBloatMetrics {
  schemaName: string;
  tableName: string;
  totalSizeBytes: number;
  heapSizeBytes: number;
  indexesSizeBytes: number;
  bloatPercentage: number;
  wastedBytes: number;
  hasValidPrimaryKey: boolean;
  activeRepackTriggers: string[];
}

export interface StorageHeadroom {
  availableBytes: number;
  totalDiskBytes: number;
  diskFreePercentage: number;
}

export interface ReplicationHealth {
  replicaCount: number;
  maxReplicationLagSeconds: number;
  isReplicationSafe: boolean;
}

export interface RepackPreflightDecision {
  canExecute: boolean;
  requiredDiskBytes: number;
  availableDiskBytes: number;
  blockingReasons: string[];
  warnings: string[];
  recommendedCommand: string;
}

export class AgenticPgRepackGuardEngine {
  private readonly SAFETY_DISK_MULTIPLIER = 2.2;
  private readonly MAX_ACCEPTABLE_REPLICATION_LAG_SEC = 30;
  private readonly MIN_BLOAT_THRESHOLD_PERCENT = 20.0;
  private readonly MAX_LOCK_WAIT_TIMEOUT_SEC = 2;

  /**
   * Evaluates all preflight invariants before permitting pg_repack execution.
   */
  public evaluatePreflight(
    metrics: RelationBloatMetrics,
    storage: StorageHeadroom,
    replication: ReplicationHealth
  ): RepackPreflightDecision {
    const blockingReasons: string[] = [];
    const warnings: string[] = [];

    // 1. Primary Key / Unique Not-Null Invariant
    if (!metrics.hasValidPrimaryKey) {
      blockingReasons.push(
        `Table "${metrics.schemaName}.${metrics.tableName}" lacks a PRIMARY KEY or NOT-NULL UNIQUE constraint. pg_repack cannot replay mutations.`
      );
    }

    // 2. Storage Headroom Invariant (2.2x multiplier)
    const requiredDiskBytes = Math.ceil(
      metrics.totalSizeBytes * this.SAFETY_DISK_MULTIPLIER
    );
    if (storage.availableBytes < requiredDiskBytes) {
      const neededPretty = (requiredDiskBytes / 1024 / 1024 / 1024).toFixed(2);
      const availPretty = (storage.availableBytes / 1024 / 1024 / 1024).toFixed(2);
      blockingReasons.push(
        `Insufficient disk space: Compaction of "${metrics.tableName}" requires at least ${neededPretty} GB (2.2x), but only ${availPretty} GB is available.`
      );
    }

    // 3. Stale Orphaned Trigger Sentinel
    if (metrics.activeRepackTriggers.length > 0) {
      blockingReasons.push(
        `Table "${metrics.tableName}" has stale orphaned repack triggers: [${metrics.activeRepackTriggers.join(
          ', '
        )}]. Run "pg_repack --clean" before proceeding.`
      );
    }

    // 4. Standby Replication Lag Check
    if (
      replication.replicaCount > 0 &&
      replication.maxReplicationLagSeconds > this.MAX_ACCEPTABLE_REPLICATION_LAG_SEC
    ) {
      blockingReasons.push(
        `Standby replica lag is too high (${replication.maxReplicationLagSeconds.toFixed(
          1
        )}s > ${this.MAX_ACCEPTABLE_REPLICATION_LAG_SEC}s threshold). Repack would trigger catastrophic standby query cancellations.`
      );
    }

    // 5. Bloat Threshold Warning
    if (metrics.bloatPercentage < this.MIN_BLOAT_THRESHOLD_PERCENT) {
      warnings.push(
        `Table bloat is only ${metrics.bloatPercentage.toFixed(
          1
        )}% (below ${this.MIN_BLOAT_THRESHOLD_PERCENT}%). Repack I/O cost may outweigh compaction benefits.`
      );
    }

    // Generate safe CLI command
    const recommendedCommand = [
      'pg_repack',
      `--table="${metrics.schemaName}.${metrics.tableName}"`,
      `--wait-timeout=${this.MAX_LOCK_WAIT_TIMEOUT_SEC}`,
      '--no-kill-backend',
      '--echo-queries',
      '--no-order',
    ].join(' ');

    return {
      canExecute: blockingReasons.length === 0,
      requiredDiskBytes,
      availableDiskBytes: storage.availableBytes,
      blockingReasons,
      warnings,
      recommendedCommand,
    };
  }

  /**
   * Generates a safe diagnostic query string for agent execution.
   */
  public generateBloatInspectionQuery(schemaName: string, tableName: string): string {
    return `
      SELECT
        c.relname AS table_name,
        pg_total_relation_size(c.oid) AS total_size_bytes,
        pg_relation_size(c.oid) AS heap_size_bytes,
        pg_indexes_size(c.oid) AS indexes_size_bytes,
        EXISTS (
          SELECT 1 FROM pg_constraint con
          WHERE con.conrelid = c.oid
            AND con.contype IN ('p', 'u')
        ) AS has_pk_or_unique
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = '${schemaName}'
        AND c.relname = '${tableName}';
    `.trim();
  }
}
```

---

## 7. Cross-Runtime Implementations

### 7.1 Go (`jackc/pgx/v5`) Production Bloat Sentinel & Safe Executor

```go
package maintenance

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type BloatAssessment struct {
	TableName        string
	TotalSizeBytes   int64
	HasPrimaryKey    bool
	OrphanTriggerCnt int
	EstimatedBloat   float64
}

// InspectRelation assesses table bloat and prerequisites before repack
func InspectRelation(ctx context.Context, pool *pgxpool.Pool, schema, table string) (*BloatAssessment, error) {
	query := `
		SELECT
			c.relname,
			pg_total_relation_size(c.oid) AS total_bytes,
			EXISTS (
				SELECT 1 FROM pg_constraint con
				WHERE con.conrelid = c.oid AND con.contype = 'p'
			) AS has_pk,
			(
				SELECT COUNT(*) FROM pg_trigger trg
				WHERE trg.tgrelid = c.oid AND trg.tgname LIKE 'repack_trigger%'
			) AS orphan_triggers
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2;
	`

	var b BloatAssessment
	err := pool.QueryRow(ctx, query, schema, table).Scan(
		&b.TableName,
		&b.TotalSizeBytes,
		&b.HasPrimaryKey,
		&b.OrphanTriggerCnt,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to inspect relation %s.%s: %w", schema, table, err)
	}

	return &b, nil
}

// ExecuteSafeRepack runs pg_repack with strict timeout and safety flags
func ExecuteSafeRepack(ctx context.Context, connStr, schema, table string) error {
	fullTable := fmt.Sprintf("%s.%s", schema, table)

	// Set execution context with timeout
	cmdCtx, cancel := context.WithTimeout(ctx, 4*time.Hour)
	defer cancel()

	// Build non-blocking command
	args := []string{
		connStr,
		fmt.Sprintf("--table=%s", fullTable),
		"--wait-timeout=2",
		"--no-kill-backend",
		"--no-order",
		"--echo-queries",
	}

	cmd := exec.CommandContext(cmdCtx, "pg_repack", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("pg_repack failed for %s: %s (%w)", fullTable, strings.TrimSpace(string(out)), err)
	}

	return nil
}
```

### 7.2 Python (`asyncpg`) Preflight & Clean Engine

```python
import asyncio
import asyncpg
from typing import NamedTuple, Optional, List

class TableBloatMetrics(NamedTuple):
    table_name: str
    total_bytes: int
    has_pk: bool
    orphan_triggers: int

async def preflight_repack_check(
    conn: asyncpg.Connection,
    schema: str,
    table: str,
    available_disk_bytes: int
) -> tuple[bool, List[str]]:
    query = """
    SELECT
        c.relname,
        pg_total_relation_size(c.oid) AS total_bytes,
        EXISTS (
            SELECT 1 FROM pg_constraint con
            WHERE con.conrelid = c.oid AND con.contype = 'p'
        ) AS has_pk,
        (
            SELECT COUNT(*) FROM pg_trigger trg
            WHERE trg.tgrelid = c.oid AND trg.tgname LIKE 'repack_trigger%'
        ) AS orphan_triggers
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = $2;
    """
    row = await conn.fetchrow(query, schema, table)
    if not row:
        return False, [f"Table {schema}.{table} not found"]

    metrics = TableBloatMetrics(
        table_name=row["relname"],
        total_bytes=row["total_bytes"],
        has_pk=row["has_pk"],
        orphan_triggers=row["orphan_triggers"]
    )

    errors = []
    if not metrics.has_pk:
        errors.append("Target table missing primary key constraint")

    if metrics.orphan_triggers > 0:
        errors.append(f"Found {metrics.orphan_triggers} stale repack trigger(s); run pg_repack --clean")

    # Verify 2.2x free disk space
    required_bytes = int(metrics.total_bytes * 2.2)
    if available_disk_bytes < required_bytes:
        errors.append(
            f"Insufficient disk: needs {required_bytes // (1024**3)} GB, available {available_disk_bytes // (1024**3)} GB"
        )

    return len(errors) == 0, errors
```

### 7.3 Rust (`tokio-postgres`) Automated Sentinel

```rust
use tokio_postgres::{Client, Error};

#[derive(Debug)]
pub struct RepackSafetyCheck {
    pub table_name: String,
    pub total_size_bytes: i64,
    pub has_primary_key: bool,
    pub orphaned_triggers: i64,
}

pub async fn inspect_repack_prerequisites(
    client: &Client,
    schema: &str,
    table: &str,
) -> Result<RepackSafetyCheck, Error> {
    let stmt = client
        .prepare(
            "SELECT
                c.relname::text,
                pg_total_relation_size(c.oid)::int8,
                EXISTS (
                    SELECT 1 FROM pg_constraint con
                    WHERE con.conrelid = c.oid AND con.contype = 'p'
                ) AS has_pk,
                (
                    SELECT COUNT(*)::int8 FROM pg_trigger trg
                    WHERE trg.tgrelid = c.oid AND trg.tgname LIKE 'repack_trigger%'
                ) AS orphan_count
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2;",
        )
        .await?;

    let row = client.query_one(&stmt, &[&schema, &table]).await?;

    Ok(RepackSafetyCheck {
        table_name: row.get(0),
        total_size_bytes: row.get(1),
        has_primary_key: row.get(2),
        orphaned_triggers: row.get(3),
    })
}
```

---

## 8. Finite-State Machine: Online Compaction Lifecycle

Autonomous agents orchestrating `pg_repack` must execute transitions through this 6-state lifecycle:

```
  ┌────────────────────────────────────────────────────────┐
  │                        [IDLE]                          │
  └──────────────────────────┬─────────────────────────────┘
                             │ Preflight: PK, Disk >= 2.2x, No Stale Triggers
                             ▼
  ┌────────────────────────────────────────────────────────┐
  │                 [PREFLIGHT_VERIFIED]                   │
  └──────────────────────────┬─────────────────────────────┘
                             │ pg_repack --table=... --wait-timeout=2
                             ▼
  ┌────────────────────────────────────────────────────────┐
  │                   [SHADOW_COPYING]                     │
  │        (Live reads & writes normal; delta logged)      │
  └──────────────────────────┬─────────────────────────────┘
                             │ Initial tuple copy completed
                             ▼
  ┌────────────────────────────────────────────────────────┐
  │                   [INDEX_BUILDING]                     │
  │    (Concurrent index construction on shadow table)     │
  └──────────────────────────┬─────────────────────────────┘
                             │ Indexes ready; delta log caught up
                             ▼
  ┌────────────────────────────────────────────────────────┐
  │              [ATOMIC_SWAP_HANDSHAKE]                   │
  │    (Brief ACCESS EXCLUSIVE < 50ms; relfilenode swap)   │
  └──────────────────────────┬─────────────────────────────┘
                             │ Lock acquired, swap succeeded, triggers dropped
                             ▼
  ┌────────────────────────────────────────────────────────┐
  │                 [CLEANUP_VERIFIED]                     │
  │           (Disk reclaimed, bloat < 5%)                 │
  └────────────────────────────────────────────────────────┘

  [FAIL-SAFE RECOVERY / TIMEOUT PATH]
  From any active state:
  If lock_timeout exceeded or replica lag > 30s:
  ──> Abort repack process
  ──> Execute `pg_repack --clean`
  ──> Transition to [CLEAN_ORPHAN_DRAINED]
```

---

## 9. Definition of Done (DoD) Matrix: Machine-Verifiable Gates

Every autonomous pull request, maintenance script, or agent runbook that introduces or modifies database bloat compaction routines must pass this 6-gate verification matrix:

```
+----------------------------------------------------------------------------------------------------------+
|                                  MACHINE-VERIFIABLE DEFINITION OF DONE GATES                             |
+---+----------------------------+------------------------------------------+------------------------------+
| # | Gate Name                  | Verification Mechanism                   | Pass / Fail Invariant        |
+---+----------------------------+------------------------------------------+------------------------------+
| 1 | Zero VACUUM FULL           | Static code & AST search across all repo | Zero occurrences of          |
|   | Prohibition                | files, migrations, and CI scripts        | `VACUUM FULL` in codebase    |
+---+----------------------------+------------------------------------------+------------------------------+
| 2 | Primary Key Assertion      | Preflight SQL assertion on pg_constraint | Returns true; PK or NOT NULL |
|   |                            | contype IN ('p', 'u')                    | unique constraint confirmed  |
+---+----------------------------+------------------------------------------+------------------------------+
| 3 | 2.2x Free Storage Headroom | OS / RDS storage API validation check    | Available Disk >=            |
|   |                            | against pg_total_relation_size(oid)      | 2.2 * total_relation_size    |
+---+----------------------------+------------------------------------------+------------------------------+
| 4 | Mandatory Lock Timeout     | Command-line arg / script audit          | `--wait-timeout` <= 2s and   |
|   | Parameterization           |                                          | `--no-kill-backend` present  |
+---+----------------------------+------------------------------------------+------------------------------+
| 5 | Zero Orphaned Trigger      | Query pg_trigger for repack_trigger%     | Trigger count == 0 before    |
|   | Sentinel Cleanliness       | before and after execution               | start and after completion   |
+---+----------------------------+------------------------------------------+------------------------------+
| 6 | Post-Compaction Bloat      | Table bloat estimation formula post-run  | Verified Bloat Ratio         |
|   | Reclamation                | on target relation                       | B <= 0.05 (5% bloat)         |
+---+----------------------------+------------------------------------------+------------------------------+
```
