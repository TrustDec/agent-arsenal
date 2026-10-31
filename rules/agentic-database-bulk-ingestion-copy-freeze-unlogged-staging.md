---
description: PostgreSQL binary and text COPY streaming protocol (COPY FROM STDIN), COPY FREEZE tuple optimization, UNLOGGED scratch staging tables, multi-row parameterized batch INSERT sizing, WAL amplification defense, index deferral and parallel B-tree build, connection pool protection, and streaming bulk ingestion across Go (pgx.CopyFrom), TypeScript (pg-copy-streams, Drizzle), Python (asyncpg.copy_records_to_table), Rust (tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{bulk,copy,ingest,import,batch,etl,seed,stream,staging}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Bulk Ingestion, PostgreSQL COPY Protocol, FREEZE Tuples, UNLOGGED Staging & WAL Amplification Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design high-throughput data ingestion pipelines, CSV/JSON file importers, webhook event batch sinks, database seeding routines, ETL migration workers, or analytical staging layers across PostgreSQL (12+), Go (`jackc/pgx/v5`), TypeScript (`pg-copy-streams`, `drizzle-orm`, `kysely`), Python (`asyncpg`, `psycopg3`), or Rust (`tokio-postgres`, `sqlx`). Eliminate the "$N$-Individual `INSERT` Round-Trip & Connection Pool Collapse Disaster" (where agents execute single-row `INSERT` statements inside loops, multiplying network latency by $10^5$, monopolizing pool connections for dozens of minutes, and choking CPU on transaction commits), the "65,535 Parameter Placeholder Limit Explosion" (where dynamic multi-row `INSERT INTO t VALUES ($1, $2, ...)` exceeds PostgreSQL's maximum 65,535 parameter limit or SQLite's 999/32,766 limit, crashing ingestion with `SQLSTATE 54000` or `08P01`), the "WAL Write Amplification & Emergency Checkpoint Stalling Avalanche" (where inserting millions of rows into standard logged tables with active secondary indexes generates $15\times$ write amplification, forcing continuous disk checkpoints and stalling concurrent OLTP transactions), the "Active Index & Foreign Key Constraint Maintenance Meltdown" (where inserting into indexed tables forces random B-tree leaf page splits and parent foreign key verification scans, multiplying ingest duration by $50\times$), the "Monolithic Transaction Memory Spill & Pinned $x_{\text{min}}$ Autovacuum Paralysis" (where wrapping multi-million row insertions into a single `BEGIN ... COMMIT` pins the cluster snapshot horizon for hours, blocking table cleanup and triggering massive bloat), and the "Unfrozen Heap Tuple Vacuum Freezing Debt Trap" (where bulk-loaded tuples retain current transaction IDs, forcing subsequent emergency autovacuum freeze rewrites) by establishing a strict 5-Tier Bulk Ingestion Governance Ladder, formal network and WAL amplification proofs, production TypeScript guard engines, and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Bulk Ingestion Catastrophes vs The 5-Tier Governance Ladder

Bulk data ingestion is a critical operational bottleneck in modern data-intensive architectures. When autonomous coding agents implement import endpoints, batch data migrations, event stream consumers, or database seeders, they routinely default to naive ORM loops, uncalculated batch parameter arrays, or unindexed bulk insertions that degrade production database clusters.

### The 6 Bulk Ingestion Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE N-INDIVIDUAL INSERT ROUND-TRIP DISASTER
-- Agent implements CSV record importer:
-- for row in records:
--     db.Exec("INSERT INTO user_events (id, user_id, event_type, payload, created_at) VALUES ($1, $2, $3, $4, $5)", ...)

-- ❌ Catastrophe 1 (Network Latency Multiplier):
-- Inserting 100,000 rows generates 100,000 individual TCP network round-trips!
-- At 1ms round-trip latency, ingestion takes at minimum 100 seconds of pure idle network wait.
-- ❌ Catastrophe 2 (Transaction & WAL Overhead):
-- Each auto-commit statement issues an fsync write to WAL (unless synchronous_commit=off),
-- saturating storage IOPS, holding connection pool slots, and blocking concurrent OLTP transactions.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE 65,535 PARAMETER LIMIT EXPLOSION
-- Agent attempts naive multi-row batching:
-- INSERT INTO sensor_readings (device_id, metric, val, status, unit, note, recorded_at)
-- VALUES ($1, $2, $3, $4, $5, $6, $7), ($8, ...), ... ($70000);

-- ❌ Catastrophe:
-- In PostgreSQL wire protocol (and libpq), the maximum parameter placeholder index is 65,535 (uint16).
-- A table with 10 columns inserting 7,000 rows attempts 70,000 parameters.
-- Result: Immediate fatal crash with SQLSTATE 54000 (program_limit_exceeded) or 08P01 (protocol_violation).
-- The ingestion pipeline fails midway, leaving partial unrecoverable state!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: ACTIVE INDEX & FOREIGN KEY MAINTENANCE MELTDOWN
-- Agent inserts 5,000,000 rows directly into an active table with 4 secondary B-Tree indexes:
-- CREATE TABLE customer_events (
--     id UUID PRIMARY KEY, customer_id UUID REFERENCES customers(id),
--     event_name TEXT, score NUMERIC, created_at TIMESTAMPTZ
-- );
-- CREATE INDEX idx_cust ON customer_events(customer_id);
-- CREATE INDEX idx_name ON customer_events(event_name);
-- CREATE INDEX idx_created ON customer_events(created_at);

-- ❌ Catastrophe:
-- For every single inserted row:
-- 1. Engine must verify the foreign key in 'customers' table (read I/O).
-- 2. Engine must insert leaf keys into 4 separate B-Tree indexes. Because incoming keys are unordered,
--    traversals hit random 8KB leaf pages, causing 50% fillfactor page splits and massive buffer pool eviction.
-- Total ingest time: 4 hours.
-- If secondary indexes were dropped, data loaded via COPY, and indexes recreated in parallel: Total time: 3.5 minutes!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: MONOLITHIC TRANSACTION & PINNED XMIN VACUUM PARALYSIS
-- Agent wraps 10,000,000 row ETL load in a single transaction:
-- BEGIN;
-- ... [Loads 10 million rows over 90 minutes] ...
-- COMMIT;

-- ❌ Catastrophe:
-- The transaction holds a single snapshot for 90 minutes.
-- In PostgreSQL MVCC, autovacuum CANNOT clean up dead tuples from ANY table in the cluster if their
-- deletion occurred after this transaction's xmin horizon!
-- High-churn OLTP tables (e.g. sessions, queues) balloon by gigabytes of dead tuple bloat during the load.
-- If an error occurs at minute 89, the entire 90 minutes of work is rolled back, generating gigabytes of WAL churn.
```

```sql
-- ✅ PRODUCTION INVARIANT 1: UNLOGGED STAGING TABLE & ATOMIC SET-BASED UPSERT
-- Step 1: Create ephemeral unlogged staging table (bypasses WAL logging)
CREATE UNLOGGED TABLE staging_sensor_readings (
    device_id UUID NOT NULL,
    metric VARCHAR(64) NOT NULL,
    val DOUBLE PRECISION NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL
);

-- Step 2: Stream records at hardware line-rate via COPY protocol (10x-50x faster than INSERT)
-- COPY staging_sensor_readings (device_id, metric, val, recorded_at) FROM STDIN WITH (FORMAT binary);

-- Step 3: Atomic, set-based merge into target table in a single fast transaction
INSERT INTO sensor_readings (device_id, metric, val, recorded_at)
SELECT device_id, metric, val, recorded_at
FROM staging_sensor_readings
ON CONFLICT (device_id, recorded_at, metric) DO UPDATE 
SET val = EXCLUDED.val;

-- Step 4: Truncate staging table for instant zero-fragmentation space reclamation
TRUNCATE TABLE staging_sensor_readings;
```

```sql
-- ✅ PRODUCTION INVARIANT 2: NEW PARTITION INGESTION WITH COPY FREEZE
-- When loading historical partitions or initial database seed tables created in the same transaction:
BEGIN;

CREATE TABLE audit_logs_2026_q1 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-01-01 00:00:00+00') TO ('2026-04-01 00:00:00+00');

-- COPY FREEZE marks all inserted tuples as FrozenTransactionId immediately!
-- Bypasses transaction status lookups and guarantees Autovacuum will NEVER need to run an
-- aggressive freeze scan on these pages in the future!
COPY audit_logs_2026_q1 FROM STDIN WITH (FREEZE on, FORMAT csv, HEADER true);

COMMIT;
```

### The 5-Tier Bulk Ingestion Governance Ladder

| Tier | Strategy | Target Workload | Parameter Limits & Protocol | WAL & Lock Impact | Throughput Expectation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Tier 0** | **Parameter-Safe Chunked Multi-Row INSERT** | Webhooks, REST API payloads ($100 - 5,000$ rows) | Multi-row `INSERT` bounded by $B = \min(1000, \lfloor 65535 / C_{\text{cols}} \rfloor)$ | Standard WAL; Row-level locks; Brief transaction | $5,000 - 15,000$ rows/sec |
| **Tier 1** | **Native Streaming COPY Protocol** | CSV imports, event sinks ($5,000 - 500,000$ rows) | `COPY table FROM STDIN [WITH (FORMAT binary)]` | Standard WAL; Append lock on heap; No SQL parsing | $50,000 - 150,000$ rows/sec |
| **Tier 2** | **UNLOGGED Staging + Set-Based MERGE** | ETL pipelines, bulk webhook syncing with deduplication | Stream into `UNLOGGED` staging table $\to$ `INSERT ... SELECT ON CONFLICT` | **Zero WAL on ingestion**; WAL generated only during final atomic merge | $100,000 - 250,000$ rows/sec |
| **Tier 3** | **Index Deferral & Parallel Sort Rebuild** | Bulk data migration, historical reload ($> 1,000,000$ rows) | Drop non-unique secondary indexes $\to$ Stream COPY $\to$ Rebuild indexes with `maintenance_work_mem` | Sequential heap append; B-tree sorted build with zero random page splits | $200,000 - 400,000$ rows/sec |
| **Tier 4** | **COPY FREEZE for Zero-Debt Relational Partitions** | Partition pre-warming, cold data loads, archival sync | `COPY ... FREEZE` inside relation creation transaction | **Zero freeze debt forever**; Tuples marked frozen; Immediate visibility | Maximum hardware NVMe saturation |

---

## 2. Mathematical Foundations & Asymptotic Complexity Analysis

### Network Round-Trip Latency & Throughput Model

Let $N$ denote the total number of records to ingest, and $RTT$ denote the network round-trip time between application server and database (typically $0.5\text{ms} - 3\text{ms}$ in cloud availability zones).

For single-row transactional `INSERT` statements:
$$T_{\text{single}}(N) = N \cdot \left( RTT + T_{\text{parse}} + T_{\text{plan}} + T_{\text{exec}} + T_{\text{wal\_fsync}} \right)$$

Assuming $RTT = 1.0\text{ms}$ and server processing $T_{\text{proc}} = 0.5\text{ms}$, ingesting $N = 100,000$ rows yields:
$$T_{\text{single}}(100,000) = 100,000 \times 1.5\text{ms} = 150,000\text{ms} = 150\text{ seconds}$$

For chunked multi-row `INSERT` with batch size $B$:
$$T_{\text{batch}}(N, B) = \left\lceil \frac{N}{B} \right\rceil \cdot RTT + \sum_{k=1}^{\lceil N/B \rceil} \left( T_{\text{parse}}(B) + T_{\text{exec}}(B) \right) + T_{\text{wal}}$$

For native streaming PostgreSQL `COPY` protocol:
$$T_{\text{copy}}(N) = 1 \cdot RTT + \frac{N \cdot S_{\text{row}}}{\text{Network Bandwidth}} + \frac{N \cdot S_{\text{row}}}{\text{Disk Sequential Write Speed}}$$

Where $S_{\text{row}}$ is the binary/text tuple size in bytes. Under `COPY`, network latency is paid exactly **once** for the entire stream, converting an $O(N \cdot RTT)$ latency-bound operation into an $O(N)$ streaming throughput-bound operation.

### Parameter Capacity Boundary Calculus

PostgreSQL's wire protocol encodes parameter count as an unsigned 16-bit integer ($uint16$), enforcing an absolute theoretical upper bound:
$$P_{\text{postgres}} = 65,535$$

For a relational table with $C$ columns, attempting to insert $R$ rows in a single multi-row `INSERT INTO t VALUES ($1, ...), ...` requires $P = R \cdot C$ parameter placeholders.

The strictly safe batch size $B_{\text{safe}}$ must satisfy:
$$B_{\text{safe}} = \min \left( B_{\text{max\_chunk}}, \left\lfloor \frac{65,535 - P_{\text{overhead}}}{C} \right\rfloor \right)$$

Where $B_{\text{max\_chunk}} = 1,000$ (to maintain bounded query parsing overhead in engine memory) and $P_{\text{overhead}} \ge 10$ (to reserve parameters for multi-tenant identifiers or batch metadata).

```text
Parameter Bounds Matrix:
Columns (C) | Safe Chunk Size (B_safe) | Total Parameters | Protocol Headroom
-----------------------------------------------------------------------------
5 columns   | 1,000 rows               | 5,000 params     | 60,535 (Safe)
25 columns  | 1,000 rows               | 25,000 params    | 40,535 (Safe)
50 columns  | 1,000 rows               | 50,000 params    | 15,535 (Safe)
70 columns  | 900 rows                 | 63,000 params    | 2,535 (Safe)
100 columns | 650 rows                 | 65,000 params    | 535 (Safe)
```

### WAL Write Amplification Differential Theorem

In standard logged PostgreSQL tables with $I$ secondary B-Tree indexes, every row insertion generates WAL records for:
1. The heap tuple insertion.
2. An index leaf tuple insertion for each of the $I$ secondary indexes.
3. Full-Page Writes (FPWs) whenever an 8KB heap or B-tree page is modified for the first time following a checkpoint.

The total WAL volume $W_{\text{logged}}$ generated by inserting $N$ tuples is:
$$W_{\text{logged}}(N) = N \cdot S_{\text{heap}} + N \sum_{i=1}^I S_{\text{index\_entry}}^{(i)} + \alpha_{\text{fpw}} \cdot 8192 \cdot \left( \frac{N \cdot S_{\text{heap}}}{8192} + \sum_{i=1}^I N_{\text{splits}}^{(i)} \right)$$

Where $\alpha_{\text{fpw}} \in [0.1, 0.8]$ is the full-page write ratio and $N_{\text{splits}}^{(i)}$ is the number of B-tree leaf page splits caused by random key insertion.

In contrast, when ingesting via an `UNLOGGED` staging table:
$$W_{\text{unlogged}}(N) \equiv 0\text{ bytes of WAL}$$

WAL is emitted only during the final atomic set-based `INSERT INTO target SELECT ... FROM staging` transaction, slashing total cluster WAL write volume by up to $80\% - 95\%$ during massive ETL ingest.

### B-Tree Index Maintenance: Random Page Splits vs Sequential Merge Sort Build

When $N$ rows are inserted into a table with an existing B-Tree index of size $M$ keys:
If the inserted keys are random (e.g. UUIDv4, email, hash), each insertion performs a random traversal of depth $h = \lceil \log_B M \rceil$, reading an 8KB leaf page.
If the leaf page is full, it triggers a page split, allocating a new 8KB block and modifying the parent branch page:
$$C_{\text{incremental}}(N) = N \cdot \left( h \cdot T_{\text{random\_cache\_or\_disk}} + P_{\text{split}} \cdot T_{\text{alloc}} \right)$$

When secondary indexes are dropped prior to bulk load and rebuilt via `CREATE INDEX`:
PostgreSQL loads all keys into memory (`maintenance_work_mem`), performs an external merge sort in $O(N \log N)$ sequential steps, and writes dense B-Tree leaf pages with optimal `fillfactor` packing:
$$C_{\text{bulk\_sort}}(N) = O\left( \frac{N}{P} \log_K \frac{N}{P} \cdot T_{\text{seq\_io}} \right)$$

Because sequential I/O on NVMe/SSD is $5\times - 20\times$ faster than random I/O and page splits are completely avoided, bulk index rebuilding is orders of magnitude faster:
$$\frac{C_{\text{incremental}}(N)}{C_{\text{bulk\_sort}}(N)} \approx 10\times - 50\times \quad \text{for } N > 1,000,000$$

### Autovacuum Freezing Horizon Debt Theorem

PostgreSQL uses 32-bit transaction IDs. Every row written by standard `INSERT` or `COPY` records `t_xmin = current_txid`.
When the age of `datfrozenxid` reaches `autovacuum_freeze_max_age` (default 200 million transactions), autovacuum is forced to enter emergency aggressive freeze mode (`VACUUM FREEZE`), reading every 8KB block of the table from disk, rewriting tuples to replace `t_xmin` with `FrozenTransactionId`, and writing dirty pages back to disk.

For a table of size $S_{\text{table}}$ bytes:
$$\text{Freezing Disk I/O} = 2 \times S_{\text{table}} = 2 \times \left\lceil \frac{N \cdot S_{\text{row}}}{8192} \right\rceil \times 8192\text{ bytes}$$

If the relation is created and populated within the same transaction using `COPY ... FREEZE`:
$$\text{PostgreSQL Engine Invariant: } t\_xmin \equiv \text{FrozenTransactionId} \implies \text{Freezing Disk I/O} \equiv 0$$
All rows are born frozen. The cluster incurs zero autovacuum freeze I/O debt for the entire operational life of the loaded dataset.

---

## 3. Industrial Implementations Across Languages & Frameworks

### Go (`jackc/pgx/v5`): High-Throughput Streaming CopyFrom

In Go, the golden standard for bulk ingestion is `pgx.Conn.CopyFrom` or `pgx.Tx.CopyFrom`. Never accumulate millions of structs in a slice before ingestion, which exhausts Go heap RAM and induces GC pause spikes. Instead, implement a streaming channel-backed `pgx.CopyFromSource`.

```go
package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// SensorReading represents a time-series event payload.
type SensorReading struct {
	DeviceID   string    `json:"device_id"`
	Metric     string    `json:"metric"`
	Val        float64   `json:"val"`
	RecordedAt time.Time `json:"recorded_at"`
}

// ChannelCopySource implements pgx.CopyFromSource over a Go channel.
// Guarantees O(1) memory residency regardless of dataset size (e.g. 50M rows).
type ChannelCopySource struct {
	ch      <-chan SensorReading
	current SensorReading
	err     error
}

func NewChannelCopySource(ch <-chan SensorReading) *ChannelCopySource {
	return &ChannelCopySource{ch: ch}
}

func (s *ChannelCopySource) Next() bool {
	item, ok := <-s.ch
	if !ok {
		return false
	}
	s.current = item
	return true
}

func (s *ChannelCopySource) Values() ([]any, error) {
	return []any{
		s.current.DeviceID,
		s.current.Metric,
		s.current.Val,
		s.current.RecordedAt,
	}, nil
}

func (s *ChannelCopySource) Err() error {
	return s.err
}

// IngestSensorReadingsStream streams records directly into PostgreSQL via native binary COPY protocol.
// Enforces zero-WAL overhead staging and safe memory bounding.
func IngestSensorReadingsStream(
	ctx context.Context,
	pool *pgxpool.Pool,
	readingsCh <-chan SensorReading,
) (int64, error) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return 0, fmt.Errorf("failed acquiring connection from pool: %w", err)
	}
	defer conn.Release()

	tx, err := conn.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("failed initiating transaction: %w", err)
	}
	defer tx.Rollback(ctx) // Safe no-op if committed

	// Optimize staging ingestion: Turn off synchronous_commit for staging operations
	if _, err := tx.Exec(ctx, "SET LOCAL synchronous_commit = off"); err != nil {
		return 0, fmt.Errorf("failed setting synchronous_commit: %w", err)
	}

	source := NewChannelCopySource(readingsCh)
	columns := []string{"device_id", "metric", "val", "recorded_at"}

	rowsCopied, err := tx.CopyFrom(
		ctx,
		pgx.Identifier{"staging_sensor_readings"},
		columns,
		source,
	)
	if err != nil {
		return 0, fmt.Errorf("streaming COPY failed: %w", err)
	}

	// Atomic set-based merge from staging into production relation
	const mergeSQL = `
		INSERT INTO sensor_readings (device_id, metric, val, recorded_at)
		SELECT device_id, metric, val, recorded_at
		FROM staging_sensor_readings
		ON CONFLICT (device_id, recorded_at, metric) DO UPDATE
		SET val = EXCLUDED.val;
		TRUNCATE TABLE staging_sensor_readings;
	`
	if _, err := tx.Exec(ctx, mergeSQL); err != nil {
		return 0, fmt.Errorf("failed executing atomic set merge: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("failed committing bulk ingest transaction: %w", err)
	}

	return rowsCopied, nil
}
```

### TypeScript / Node.js (`pg-copy-streams` & Chunked Batch Sizing)

```typescript
import { Pool, PoolClient } from 'pg';
import { from as copyFrom } from 'pg-copy-streams';
import { Readable, pipeline } from 'node:stream';
import { promisify } from 'node:util';

const pipelineAsync = promisify(pipeline);

export interface IngestRecord {
  deviceId: string;
  metric: string;
  val: number;
  recordedAt: string;
}

/**
 * Calculates parameter-safe chunk size to prevent PostgreSQL 65,535 parameter limit crash.
 */
export function calculateSafeBatchSize(columnsCount: number, maxChunkSize = 1000): number {
  const PG_MAX_PARAMS = 65535;
  const SAFETY_BUFFER = 535;
  const availableParams = PG_MAX_PARAMS - SAFETY_BUFFER;
  const safeByColumns = Math.floor(availableParams / columnsCount);
  return Math.min(maxChunkSize, safeByColumns);
}

/**
 * Streams millions of rows into PostgreSQL using native COPY protocol via pg-copy-streams.
 * Consumes constant O(1) memory using Node.js backpressure-regulated streams.
 */
export async function streamBulkIngestCopy(
  pool: Pool,
  recordStream: Readable
): Promise<void> {
  const client: PoolClient = await pool.connect();

  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL synchronous_commit = off');

    const copySql = `
      COPY staging_sensor_readings (device_id, metric, val, recorded_at)
      FROM STDIN WITH (FORMAT csv, HEADER false, DELIMITER ',')
    `;
    const dbStream = client.query(copyFrom(copySql));

    // Stream CSV chunks with automatic backpressure handling
    await pipelineAsync(recordStream, dbStream);

    // Atomic set-based reconciliation into target table
    await client.query(`
      INSERT INTO sensor_readings (device_id, metric, val, recorded_at)
      SELECT device_id, metric, val, recorded_at
      FROM staging_sensor_readings
      ON CONFLICT (device_id, recorded_at, metric) DO UPDATE
      SET val = EXCLUDED.val;
      TRUNCATE TABLE staging_sensor_readings;
    `);

    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}
```

### Python (`asyncpg`): Native Streaming `copy_records_to_table`

```python
import asyncio
from typing import AsyncIterator, Tuple, Any
import asyncpg

async def generate_records(total: int) -> AsyncIterator[Tuple[Any, ...]]:
    """Generates tuples asynchronously without pre-allocating millions in memory."""
    for i in range(total):
        yield (
            f"0192df25-7b3c-7000-8000-{i:012x}",
            "temperature_celsius",
            21.5 + (i % 10),
            "2026-03-31T12:00:00Z"
        )

async def bulk_ingest_asyncpg(pool: asyncpg.Pool, total_records: int) -> int:
    async with pool.acquire() as conn:
        async with conn.transaction():
            # Turn off synchronous_commit for staging batch
            await conn.execute("SET LOCAL synchronous_commit = off")

            # Stream records directly into staging table using PostgreSQL binary protocol
            await conn.copy_records_to_table(
                "staging_sensor_readings",
                records=generate_records(total_records),
                columns=["device_id", "metric", "val", "recorded_at"],
            )

            # Atomic set merge into production
            await conn.execute("""
                INSERT INTO sensor_readings (device_id, metric, val, recorded_at)
                SELECT device_id, metric, val, recorded_at
                FROM staging_sensor_readings
                ON CONFLICT (device_id, recorded_at, metric) DO UPDATE
                SET val = EXCLUDED.val;
                TRUNCATE TABLE staging_sensor_readings;
            """)

    return total_records
```

---

## 4. Production TypeScript Verification Engine

The following complete, production-ready TypeScript engine audits SQL queries, migration scripts, and application code to verify bulk ingestion invariants: detecting unbatched loops, parameter limit violations, missing COPY protocol usage, missing UNLOGGED staging table cleanups, and unfrozen partition loads.

```typescript
/**
 * AgenticDatabaseBulkIngestionEngine
 * Validates bulk data ingestion patterns, parameter thresholds, COPY protocol compliance,
 * UNLOGGED staging lifecycle, and COPY FREEZE optimization across database access layers.
 */

export interface BulkIngestAnalysisRequest {
  codeSnippet: string;
  sqlStatements: string[];
  estimatedRowCount: number;
  columnCount: number;
  engine: 'postgresql' | 'sqlite' | 'mysql';
}

export type BulkViolationSeverity = 'CRITICAL' | 'HIGH' | 'MEDIUM' | 'INFO';

export interface BulkIngestViolation {
  code: string;
  severity: BulkViolationSeverity;
  message: string;
  recommendation: string;
  lineSnippet?: string;
}

export interface BulkIngestAuditReport {
  status: 'PASSED' | 'REJECTED' | 'WARNING';
  recommendedTier: number;
  maxSafeBatchSize: number;
  estimatedParamCount: number;
  violations: BulkIngestViolation[];
  suggestedSql?: string;
}

export class AgenticDatabaseBulkIngestionEngine {
  private static readonly PG_PARAM_LIMIT = 65535;
  private static readonly SQLITE_PARAM_LIMIT = 32766;

  public static audit(request: BulkIngestAnalysisRequest): BulkIngestAuditReport {
    const violations: BulkIngestViolation[] = [];
    const maxSafeBatchSize = this.calculateSafeChunk(request.columnCount, request.engine);
    const estimatedParams = request.estimatedRowCount * request.columnCount;

    // 1. Detect Single-Row INSERT inside loops
    const loopInsertPattern = /(for|while|forEach|map)\s*\([^)]*?\)\s*\{[^}]*?\b(INSERT\s+INTO|\.save\(|\.create\(|\.insertOne\()/is;
    if (loopInsertPattern.test(request.codeSnippet)) {
      violations.push({
        code: 'LOOP_SINGLE_INSERT_DISASTER',
        severity: 'CRITICAL',
        message: 'Detected single-row INSERT or ORM create inside a loop. Multiplies network RTT and exhausts connection pools.',
        recommendation: 'Replace loop with native COPY streaming (for >5k rows) or chunked parameter-safe multi-row INSERT.',
      });
    }

    // 2. Detect Parameter Placeholder Explosion (> 65,535 params)
    const engineLimit = request.engine === 'sqlite' ? this.SQLITE_PARAM_LIMIT : this.PG_PARAM_LIMIT;
    if (estimatedParams > engineLimit) {
      // Check if code uses multi-row INSERT with unchunked parameters
      const multiRowInsertRegex = /INSERT\s+INTO\s+[\w.]+\s*\([^)]+\)\s*VALUES\s*\(\s*\$[0-9]+/i;
      const ormBatchInsertRegex = /\binsertMany\s*\(|\.bulkCreate\s*\(|\.insert\s*\(\s*\[/i;
      if (multiRowInsertRegex.test(request.codeSnippet) || ormBatchInsertRegex.test(request.codeSnippet)) {
        violations.push({
          code: 'PARAMETER_LIMIT_EXPLOSION',
          severity: 'CRITICAL',
          message: `Estimated parameter count (${estimatedParams}) exceeds engine limit (${engineLimit}). Will crash with SQLSTATE 54000/08P01.`,
          recommendation: `Chunk inputs into batches of at most ${maxSafeBatchSize} rows, or switch to the streaming COPY protocol.`,
        });
      }
    }

    // 3. Detect Large Ingestion (> 10,000 rows) using standard INSERT instead of COPY
    if (request.estimatedRowCount > 10000 && !/\bCOPY\b/i.test(request.codeSnippet)) {
      violations.push({
        code: 'MISSING_COPY_PROTOCOL',
        severity: 'HIGH',
        message: `High volume dataset (${request.estimatedRowCount} rows) uses standard INSERT. Generates 10x higher WAL volume and CPU parsing overhead.`,
        recommendation: 'Migrate to streaming COPY FROM STDIN protocol (e.g. pgx.CopyFrom, pg-copy-streams, or asyncpg copy_records_to_table).',
      });
    }

    // 4. Inspect UNLOGGED Staging Table Lifecycle
    const hasUnloggedCreate = request.sqlStatements.some(s => /CREATE\s+UNLOGGED\s+TABLE/i.test(s));
    if (hasUnloggedCreate) {
      const hasTruncateOrDrop = request.sqlStatements.some(s => /TRUNCATE\s+(TABLE\s+)?staging_|DROP\s+TABLE\s+staging_/i.test(s));
      if (!hasTruncateOrDrop) {
        violations.push({
          code: 'UNLOGGED_STAGING_LEAK',
          severity: 'HIGH',
          message: 'Created UNLOGGED staging table without subsequent TRUNCATE or DROP. Staging relations must be cleaned immediately post-merge.',
          recommendation: 'Append TRUNCATE staging_table after the atomic INSERT ... SELECT ON CONFLICT merge.',
        });
      }
    }

    // 5. Detect Initial Table Creation / Partition Loading without FREEZE
    const hasPartitionOrTableCreate = request.sqlStatements.some(s => /CREATE\s+TABLE\s+.*?(PARTITION\s+OF)?/i.test(s));
    const hasCopy = request.sqlStatements.some(s => /\bCOPY\s+.*?FROM\s+STDIN/i.test(s));
    const hasFreeze = request.sqlStatements.some(s => /\bFREEZE\b/i.test(s));

    if (hasPartitionOrTableCreate && hasCopy && !hasFreeze && request.estimatedRowCount > 50000) {
      violations.push({
        code: 'MISSING_COPY_FREEZE',
        severity: 'MEDIUM',
        message: 'Relation created and populated in bulk without COPY FREEZE. Tuples will incur subsequent autovacuum freeze I/O rewrites.',
        recommendation: 'Add WITH (FREEZE on) to COPY statement when relation is created within the same transaction.',
      });
    }

    // Determine governance tier
    let recommendedTier = 0;
    if (request.estimatedRowCount > 500000) {
      recommendedTier = 4;
    } else if (request.estimatedRowCount > 100000) {
      recommendedTier = 3;
    } else if (request.estimatedRowCount > 10000) {
      recommendedTier = 2;
    } else if (request.estimatedRowCount > 1000) {
      recommendedTier = 1;
    }

    const hasCritical = violations.some(v => v.severity === 'CRITICAL');
    const hasHigh = violations.some(v => v.severity === 'HIGH');

    return {
      status: hasCritical || hasHigh ? 'REJECTED' : violations.length > 0 ? 'WARNING' : 'PASSED',
      recommendedTier,
      maxSafeBatchSize,
      estimatedParamCount: estimatedParams,
      violations,
    };
  }

  public static calculateSafeChunk(columnCount: number, engine: 'postgresql' | 'sqlite' | 'mysql'): number {
    const limit = engine === 'sqlite' ? this.SQLITE_PARAM_LIMIT : this.PG_PARAM_LIMIT;
    const safetyBuffer = 500;
    const available = limit - safetyBuffer;
    const maxByCols = Math.floor(available / Math.max(1, columnCount));
    return Math.min(1000, Math.max(1, maxByCols));
  }
}
```

---

## 5. Verification & Machine-Verifiable CI Gates

Enforce bulk ingestion invariants in CI/CD via automated static analysis and pre-commit checks:

```bash
#!/usr/bin/env bash
# ci-gate-bulk-ingestion.sh
# Scans codebase for single-row insert loops and parameter limit hazards
set -euo pipefail

echo "🔍 Auditing database ingestion code against bulk invariants..."

# Gate 1: Check for single-row ORM / query executions inside loops
echo "Gate 1: Verifying absence of single-row inserts inside iterative loops..."
if grep -rnE '(for|while)\s*\(.*?\)\s*\{[^}]*?\b(INSERT\s+INTO|\.save\(|\.create\(|\.insertOne\()' src/ internal/; then
  echo "❌ CRITICAL: Detected single-row database mutation inside a loop. Use batch chunking or COPY protocol."
  exit 1
fi

# Gate 2: Verify parameter limits in chunked queries
echo "Gate 2: Verifying batch chunk size boundaries..."
if grep -rnE 'chunkSize\s*=\s*([2-9][0-9]{4,}|[1-9][0-9]{5,})' src/ internal/; then
  echo "❌ CRITICAL: Detected chunk size exceeding 10,000. Risk of PostgreSQL 65,535 parameter limit crash."
  exit 1
fi

# Gate 3: Verify UNLOGGED staging tables include TRUNCATE or DROP
echo "Gate 3: Verifying UNLOGGED staging table lifecycle..."
if grep -rnE 'CREATE\s+UNLOGGED\s+TABLE' src/ internal/ migrations/ > /dev/null; then
  if ! grep -rnE 'TRUNCATE\s+(TABLE\s+)?staging_' src/ internal/ migrations/ > /dev/null; then
    echo "⚠️ WARNING: Found UNLOGGED staging table without matching TRUNCATE. Ensure staging rows are reclaimed."
  fi
fi

echo "✅ All bulk ingestion CI gates passed successfully."
```

---

## 6. Definition of Done (DoD) & Autonomous Agent Verification Funnel

Before declaring any data ingestion pipeline, migration script, or batch import feature complete, autonomous coding agents must satisfy the 6-Gate DoD Matrix:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                 6-GATE BULK INGESTION VERIFICATION FUNNEL                   │
├─────────┬────────────────────────────┬──────────────────────────────────────┤
│ Gate 1  │ Protocol Selection         │ Ingestion > 5,000 rows MUST use      │
│         │                            │ native COPY streaming protocol.      │
├─────────┼────────────────────────────┼──────────────────────────────────────┤
│ Gate 2  │ Parameter Boundary Sizing  │ Multi-row INSERT chunk sizes MUST    │
│         │                            │ satisfy B <= floor(65535 / C_cols).  │
├─────────┼────────────────────────────┼──────────────────────────────────────┤
│ Gate 3  │ Staging WAL Bypass         │ ETL transformations MUST ingest into │
│         │                            │ UNLOGGED staging relations.          │
├─────────┼────────────────────────────┼──────────────────────────────────────┤
│ Gate 4  │ Index Deferral Strategy    │ Loads > 1,000,000 rows MUST drop and │
│         │                            │ rebuild secondary indexes in parallel│
├─────────┼────────────────────────────┼──────────────────────────────────────┤
│ Gate 5  │ Zero Freeze Debt           │ New partitions/tables loaded via     │
│         │                            │ COPY MUST include WITH (FREEZE on).  │
├─────────┼────────────────────────────┼──────────────────────────────────────┤
│ Gate 6  │ Constant Memory Streaming  │ Application code MUST stream records │
│         │                            │ without pre-allocating slice/array.  │
└─────────┴────────────────────────────┴──────────────────────────────────────┘
```
