---
description: PostgreSQL (10+), MySQL (8.0+), and distributed SQL server-side cursors, portal execution, streaming result sets, NO SCROLL optimization, client-side memory OOM elimination, transaction snapshot xmin pinning defense, WITH HOLD disk spill prevention, PgBouncer transaction-mode compatibility, and chunked cursor pipelines across Go (jackc/pgx/v5), TypeScript (pg-query-stream, Drizzle, Kysely), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{cursor,stream,export,batch,fetch,portal,etl,drain,pipeline,store,repo,repository,dao,query}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Server-Side Cursors, Portal Fetching, Stream Chunking & Client Memory OOM Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design batch data exports, asynchronous CSV/NDJSON reporting, ETL synchronization pipelines, AI embedding ingestion workers, database migrations, or high-volume table scans across PostgreSQL (10+), MySQL (8.0+), Go (`jackc/pgx/v5`), TypeScript (`pg-query-stream`, `drizzle-orm`, `kysely`), Python (`asyncpg`, `psycopg3`), or Rust (`sqlx`). Eliminate the "Eager Buffered Ingestion & Client OOM Meltdown" (where agents and developers write `const rows = await db.select().from(large_table)` or `rows, _ := db.Query(...)` buffering millions of rows in V8, Go, or Python heap memory, triggering Linux kernel OOM-killer `SIGKILL 137` decapitations and bringing down critical production pods), the "Pinned Transaction Snapshot & Autovacuum Horizon Paralysis Trap" (where a worker opens a server-side cursor inside an unconstrained transaction that runs for hours while streaming data to slow external consumers, pinning the PostgreSQL transaction horizon $x_{\text{min}}$, blocking autovacuum from reclaiming dead tuples database-wide, and causing catastrophic multi-gigabyte table/index bloat and XID wraparound risk), the "`WITH HOLD` Disk Spill & Temp File Bloat Trap" (where agents declare `CURSOR WITH HOLD` to bypass transaction duration limits, forcing PostgreSQL on `COMMIT` to eagerly materialize and copy the entire remaining millions of tuples into `pgsql_tmp` disk files, exhausting NVMe disk space and inducing heavy synchronous write I/O stalls), the "PgBouncer Transaction-Mode De-Synchronization Disaster" (where client code issues `FETCH FORWARD 1000 FROM cur` across multiple network round-trips behind a transaction-pooling connection proxy, routing successive fetches to distinct backend connections and crashing with `ERROR: cursor "cur" does not exist`), the "Non-Deterministic Scrollable Materialization Penalty" (where agents declare cursors without `NO SCROLL`, forcing PostgreSQL to instantiate a memory tuplestore to support bidirectional backward seeking and paralyzing the optimizer's pipelined index-scan streaming), and the "Leaked Cursor & Portal Resource Exhaustion" (where unhandled errors, early loop returns, or network dropouts fail to execute `CLOSE cursor_name`, leaving active portal descriptors pinned in backend memory until session termination) by establishing a strict 5-Tier Cursor & Streaming Governance Ladder, asymptotic memory and disk proofs, a production-ready TypeScript `AgenticServerCursorGuardEngine`, cross-language implementations in Go, TypeScript, Python, and Rust, a complete 6-state cursor execution finite-state machine (FSM), and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Cursor & Streaming Catastrophes vs The 5-Tier Governance Ladder

In high-scale relational database engineering, processing datasets exceeding available client process memory (e.g. 500,000 to 50,000,000 tuples) requires streaming rather than buffered loading. PostgreSQL provides low-level **Portals** and SQL **Cursors** (`DECLARE ... CURSOR FOR SELECT ...`), allowing clients to fetch rows in bounded chunks (`FETCH FORWARD 1000 FROM ...`).

However, the interaction between PostgreSQL's MVCC transaction snapshots, cursor holdability, connection pooling proxies (PgBouncer), and client-side stream backpressure is filled with subtle pitfalls. Autonomous coding agents and developers routinely fall victim to 6 catastrophic failure modes:

### The 6 Cursor & Streaming Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: EAGER BUFFERED RESULT SET & CLIENT OOM MELTDOWN
-- Autonomous agent writes a batch export endpoint:
-- Node.js / TypeScript:
const allEvents = await db.select().from(auditEvents); // ❌ Loads 10,000,000 rows into Node.js heap!
for (const ev of allEvents) {
  await s3Stream.write(JSON.stringify(ev) + '\n');
}
-- Go:
var records []AuditRecord
db.Find(&records) // ❌ Loads 5 GB of raw structs into Go heap!

-- ❌ Catastrophe:
-- 1. Default database drivers (pg, pgx without pgx.Rows chunking, Prisma, Sequelize) buffer ALL matching tuples in RAM before returning.
-- 2. At 10 million rows with 500 bytes per row, memory demand spikes instantly to >5 GB.
-- 3. Container cgroups memory limits (e.g., 512MB or 2GB) trigger Linux kernel OOM-killer:
--    kernel: [12345.678] Out of memory: Killed process 42 (node) total-vm:4194304kB, anon-rss:2097152kB
-- 4. Pod terminates with exit code 137, dropping all concurrent user connections and triggering continuous restart loops.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: PINNED SNAPSHOT & AUTOVACUUM HORIZON PARALYSIS TRAP
-- Agent writes a batch data sync job using a standard cursor:
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

DECLARE event_cursor NO SCROLL CURSOR FOR
    SELECT id, tenant_id, payload, created_at
    FROM audit_events
    ORDER BY created_at ASC;

-- The application streams rows to an external slow REST API / AI Embedding model:
-- Each batch of 1,000 rows takes 5 seconds to process over external network.
-- Total dataset: 5,000,000 rows = 5,000 batches = 25,000 seconds (~7 hours).
FETCH FORWARD 1000 FROM event_cursor;
-- ... [Job runs for 7 hours inside the same transaction] ...
COMMIT;

-- ❌ Catastrophe:
-- 1. In PostgreSQL, a transaction holds its snapshot (and the transaction horizon `xmin`).
-- 2. For the entire 7-hour duration, Autovacuum CANNOT clean any dead tuples generated anywhere in the database
--    with XID >= the cursor transaction's xmin!
-- 3. Tables with high update churn (e.g., orders, accounts, sessions) bloat exponentially.
--    A table of 2 GB grows to 85 GB in hours! Disk utilization reaches 98%, triggering alert pages.
-- 4. If transaction runs long enough, `age(datfrozenxid)` approaches 2 billion, risking emergency read-only shutdown.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: `WITH HOLD` DISK SPILL & TEMP FILE BLOAT TRAP
-- Agent attempts to solve the long transaction problem by declaring a cursor WITH HOLD:
BEGIN;
DECLARE export_cur CURSOR WITH HOLD FOR
    SELECT * FROM transactions WHERE created_at >= '2025-01-01';
COMMIT; -- ❌ Agent assumes cursor continues streaming from disk dynamically!

-- Subsequent fetches outside of transaction:
FETCH FORWARD 5000 FROM export_cur;

-- ❌ Catastrophe:
-- 1. When a transaction commits, PostgreSQL cannot keep an active executor pipeline open without a snapshot.
-- 2. PostgreSQL's internal contract for `CURSOR WITH HOLD`: on COMMIT, PostgreSQL runs the REMAINING query
--    to COMPLETION and copies EVERY single unread row into temporary tuplestore files on disk (`base/pgsql_tmp/`)!
-- 3. If the query matches 50 million rows, PostgreSQL immediately writes 40 GB of temporary files to disk on COMMIT,
--    causing massive I/O saturation, spike in checkpoint delays, and filling up the database disk partition.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: PGBOUNCER TRANSACTION-MODE CONNECTION DE-SYNC DISASTER
-- Microservice architecture runs PgBouncer in `pool_mode = transaction`.
-- Agent implements cursor pagination across client HTTP calls:
-- Client Request 1:
BEGIN;
DECLARE page_cur NO SCROLL CURSOR FOR SELECT * FROM orders ORDER BY id;
FETCH FORWARD 50 FROM page_cur;
-- (HTTP response returned to client, client connection released back to pool!)

-- Client Request 2 (next page):
FETCH FORWARD 50 FROM page_cur;

-- ❌ Catastrophe:
-- 1. Under PgBouncer transaction pooling, the physical server connection is returned to the pool
--    the moment a transaction completes or between independent statements without an open transaction.
-- 2. Request 2 is allocated a DIFFERENT backend PostgreSQL connection process.
-- 3. The backend returns:
--    ERROR: cursor "page_cur" does not exist (SQLSTATE 34000)
-- 4. Microservice fails intermittently and unpredictably under concurrency.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: NON-DETERMINISTIC SCROLLABLE MATERIALIZATION PENALTY
-- Agent omits `NO SCROLL`:
DECLARE order_cur CURSOR FOR
    SELECT id, total_amount, customer_id
    FROM orders
    WHERE status = 'COMPLETED'
    ORDER BY created_at;

-- ❌ Catastrophe:
-- 1. If neither SCROLL nor NO SCROLL is specified, PostgreSQL checks if the query plan can support backward fetching.
-- 2. If the plan cannot natively scan backwards (e.g., hash joins, aggregates, or certain index scans),
--    PostgreSQL forces a `Materialize` node into the execution plan!
-- 3. The executor must pre-calculate and store tuples in `work_mem` or disk tuplestore BEFORE the first `FETCH`
--    can even return, destroying the latency and memory benefits of streaming.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: LEAKED CURSOR & PORTAL RESOURCE EXHAUSTION
-- Agent opens a cursor in code but aborts on early validation failure or panic:
func StreamOrders(ctx context.Context, tx pgx.Tx) error {
    _, err := tx.Exec(ctx, "DECLARE cur NO SCROLL CURSOR FOR SELECT id, payload FROM orders")
    if err != nil {
        return err
    }
    for {
        rows, err := tx.Query(ctx, "FETCH FORWARD 500 FROM cur")
        if err != nil {
            return err // ❌ Returns without executing "CLOSE cur"!
        }
        // ... process rows ...
        if someCondition {
            return nil // ❌ Early loop break without "CLOSE cur"!
        }
    }
    // "CLOSE cur" only reached if loop finishes naturally!
}

-- ❌ Catastrophe:
-- 1. Unclosed cursors hold portal memory descriptors, locks on underlying tables, and pin temp tables.
-- 2. In long-lived connections, repeated unclosed cursors accumulate until backend memory is exhausted
--    or error `ERROR: duplicate cursor "cur"` occurs on subsequent requests on the same connection.
```

---

### The 5-Tier Cursor & Streaming Governance Ladder

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Tier 4: Scoped RAII Lifecycle & Automated Error/Abort Guards                │
│         - Guaranteed `CLOSE cursor` via defer / finally / context abort     │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: PgBouncer Session Affinity & Dedicated Connection Scoping           │
│         - Single connection transaction checkout; never cross-request cursor│
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Mandatory `NO SCROLL` & Direct Index Scan Pipelining                │
│         - Forbid default scrollable cursors; eliminate Materialize nodes    │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Scoped Snapshot Lifetime & Keyset Chunking for Long Batch Jobs       │
│         - Cap cursor duration (<5m); switch to Keyset Seek for multi-hour   │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Constant-Memory Client Streaming & Bounded Buffer Backpressure      │
│         - Bounded chunk iterators (B <= 1000 rows); strict zero-OOM budget  │
└─────────────────────────────────────────────────────────────────────────────┘
```

| Tier | Governance Level | Core Mechanism | Production Invariant | Catastrophe Eradicated |
| :--- | :--- | :--- | :--- | :--- |
| **Tier 0** | **Constant-Memory Streaming** | `pgx.Rows`, `pg-query-stream`, `asyncpg.Cursor` | $M_{\text{client}} = O(B)$ where $B \le 1000$; forbid unbounded `db.Find()` | Client process OOM kills (`SIGKILL 137`) |
| **Tier 1** | **Snapshot Horizon Defense** | Transaction time caps, `idle_in_transaction_session_timeout` | Cursor transactions must finish in $\le 5$ min; use Keyset seek for multi-hour ETL | Database-wide table bloat, Autovacuum stalling |
| **Tier 2** | **Mandatory `NO SCROLL`** | `DECLARE cur NO SCROLL CURSOR` | Explicit `NO SCROLL` prevents executor `Materialize` node tuplestore disk spills | Unnecessary query startup latency and memory thrash |
| **Tier 3** | **PgBouncer Session Scoping** | Single-connection transaction scoping | Keep `DECLARE`, `FETCH` loop, `CLOSE`, and `COMMIT` within one continuous connection checkout | `ERROR: cursor "..." does not exist` connection loss |
| **Tier 4** | **RAII Safe Cleanup** | `defer tx.Exec("CLOSE cur")`, `try/finally` | Deterministic portal destruction regardless of early returns or panics | Portal memory leaks, table lock retention |

---

## 2. Mathematical Complexity Models & Memory Footprint Differentials

### Theorem 1: Client Memory Consumption Differential

Let $N$ be the total number of candidate rows in the query result, $W_{\text{row}}$ be the average byte size of a serialized tuple in client heap, and $B$ be the cursor batch fetch size (e.g., $B = 1,000$).

Under naive buffered loading:
$$M_{\text{eager}}(N) = N \cdot W_{\text{row}} + \mathcal{O}(N) \cdot W_{\text{overhead}}$$

For a typical audit table with $N = 10,000,000$ and $W_{\text{row}} = 650 \text{ bytes}$:
$$M_{\text{eager}} \approx 10^7 \times 650 \text{ bytes} \approx 6.5 \text{ GB}$$

In contrast, under streaming server-side cursor with batch prefetch size $B = 1,000$:
$$M_{\text{stream}}(B) = B \cdot W_{\text{row}} + \mathcal{O}(1)$$
$$M_{\text{stream}} \approx 1,000 \times 650 \text{ bytes} \approx 650 \text{ KB}$$

$$\text{Memory Compression Factor} = \frac{M_{\text{eager}}(N)}{M_{\text{stream}}(B)} = \frac{6.5 \text{ GB}}{650 \text{ KB}} = 10,000\times$$

**Corollary**: Streaming reduces client process memory from linear unbounded $\mathcal{O}(N)$ to constant $\mathcal{O}(1)$ relative to table cardinality, guaranteeing survival under container cgroup memory limits.

---

### Theorem 2: Transaction Snapshot Horizon & Autovacuum Dead Tuple Bloat

Let $T_{\text{open}}$ be the duration an uncommitted transaction holds an active server cursor. Let $\mu_{\text{churn}}$ be the database-wide write churn rate (inserts, updates, deletes per second across all tables). The total volume of dead tuples $V_{\text{dead}}$ that Autovacuum is mathematically blocked from cleaning is:

$$V_{\text{dead}}(T_{\text{open}}) = \int_{0}^{T_{\text{open}}} \mu_{\text{churn}}(t) \, dt$$

If a long-running cursor export runs for $T_{\text{open}} = 4 \text{ hours} = 14,400 \text{ seconds}$ in an e-commerce cluster with $\mu_{\text{churn}} = 2,500 \text{ updates/sec}$:
$$V_{\text{dead}} = 14,400 \times 2,500 = 36,000,000 \text{ unvacuumable dead tuples}$$

Assuming an average tuple size of 300 bytes, unvacuumed bloat accumulates at:
$$\Delta_{\text{bloat}} \approx 36 \times 10^6 \times 300 \text{ bytes} \approx 10.8 \text{ GB of guaranteed table bloat}$$

**Rule**: If a streaming task requires $T > 10 \text{ minutes}$, do NOT use a single server-side cursor. Switch immediately to **Keyset Pagination Seek Batches** where each batch executes in an independent, sub-second transaction.

---

### Theorem 3: Server Cursor vs Keyset Pagination Trade-Off Matrix

| Metric | Server-Side Cursor (`NO SCROLL`) | Keyset Pagination (`WHERE (id) > ($last_id)`) | Unbounded Offset (`OFFSET $N`) |
| :--- | :--- | :--- | :--- |
| **Startup Cost** | $\mathcal{O}(1)$ (Fast index pipeline) | $\mathcal{O}(\log N)$ (Per page B-Tree seek) | $\mathcal{O}(N)$ (Reads and discards offset) |
| **Cost per Page ($K$ rows)** | $\mathcal{O}(K)$ (Pipelined next tuples) | $\mathcal{O}(\log N + K)$ (Index traverse + fetch) | $\mathcal{O}(N + K)$ (Linear scan cliff) |
| **Total Work for $N$ rows** | $\mathcal{O}(N)$ | $\mathcal{O}(N \log N)$ | $\mathcal{O}(N^2)$ (Catastrophic quadratic) |
| **Snapshot Stability** | Pinned throughout transaction | Refreshable per transaction | None (Vulnerable to page drift) |
| **Autovacuum Impact** | Blocks vacuum if $T$ is large | **Zero bloat** (Transactions are $\le 100\text{ms}$) | Zero bloat (but CPU thrashes) |
| **Connection Pooling** | Requires dedicated session / connection | **100% PgBouncer Transaction Compatible** | Compatible |
| **Primary Use Case** | Fast internal ETL ($\le 5\text{ min}$), CSV exports | Multi-hour backfills, public paginated APIs | ❌ STRICTLY FORBIDDEN |

---

## 3. Production TypeScript Guard Engine: `AgenticServerCursorGuardEngine`

The following production TypeScript static and runtime guard engine audits SQL cursor statements, inspects ORM queries for unbounded buffering risks, validates `NO SCROLL` declarations, flags dangerous `WITH HOLD` usage, and enforces RAII cleanup patterns:

```typescript
// src/db/guard/agentic-server-cursor-guard.ts
export interface CursorAuditFinding {
  ruleId: string;
  severity: 'CRITICAL' | 'HIGH' | 'MEDIUM' | 'INFO';
  message: string;
  remediation: string;
  line?: number;
}

export interface CursorAuditResult {
  passed: boolean;
  score: number; // 0 - 100
  findings: CursorAuditFinding[];
}

export class AgenticServerCursorGuardEngine {
  /**
   * Audits SQL DDL/DML statements containing cursor declarations.
   */
  public static auditSqlCursor(sql: string): CursorAuditResult {
    const findings: CursorAuditFinding[] = [];
    const lines = sql.split('\n');

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const lineNum = i + 1;

      // 1. Detect cursor declarations
      if (/\bDECLARE\b\s+\w+\s+(?:BINARY\s+)?(?:INSENSITIVE\s+)?(?:NO\s+SCROLL\s+|SCROLL\s+)?CURSOR\b/i.test(line)) {
        // Check for missing NO SCROLL
        if (!/\bNO\s+SCROLL\b/i.test(line)) {
          findings.push({
            ruleId: 'CURSOR_MISSING_NO_SCROLL',
            severity: 'HIGH',
            message: `Line ${lineNum}: Cursor declaration omits explicit 'NO SCROLL'. PostgreSQL may insert a Materialize node and tuplestore buffer, degrading streaming performance.`,
            remediation: "Add 'NO SCROLL': `DECLARE <cursor_name> NO SCROLL CURSOR FOR SELECT ...`",
            line: lineNum,
          });
        }

        // Check for WITH HOLD usage
        if (/\bWITH\s+HOLD\b/i.test(line)) {
          findings.push({
            ruleId: 'CURSOR_DANGEROUS_WITH_HOLD',
            severity: 'CRITICAL',
            message: `Line ${lineNum}: Cursor declared 'WITH HOLD'. On transaction COMMIT, PostgreSQL will eagerly copy all remaining matching rows into temp disk files (pgsql_tmp), risking disk exhaustion and high I/O spikes.`,
            remediation: "Remove 'WITH HOLD'. Keep the cursor within a short, scoped transaction or switch to keyset pagination.",
            line: lineNum,
          });
        }
      }

      // 2. Detect unbounded queries in batch context without cursor or limit
      if (/\bSELECT\b/i.test(line) && !/\b(LIMIT|FETCH\s+FIRST)\b/i.test(line)) {
        if (/FROM\s+(?:audit_events|events|logs|transactions|orders|ledger_entries)\b/i.test(line)) {
          // If not part of a cursor declaration or subquery
          if (!/\bDECLARE\b/i.test(line) && !/\bIN\s*\(/i.test(line)) {
            findings.push({
              ruleId: 'UNBOUNDED_HIGH_VOLUME_QUERY',
              severity: 'HIGH',
              message: `Line ${lineNum}: Unbounded SELECT on high-churn/high-volume table without LIMIT or cursor streaming. High risk of client process OOM crash.`,
              remediation: "Wrap query in a server-side cursor (`DECLARE cur NO SCROLL CURSOR`), use `pg-query-stream`, or apply keyset pagination.",
              line: lineNum,
            });
          }
        }
      }

      // 3. Detect unindexed ORDER BY in cursor
      if (/\bORDER\s+BY\s+RANDOM\(\)/i.test(line)) {
        findings.push({
          ruleId: 'CURSOR_ORDER_BY_RANDOM',
          severity: 'CRITICAL',
          message: `Line ${lineNum}: Cursor uses 'ORDER BY random()'. Forces full-table sort before any row can be fetched, completely defeating cursor streaming benefits.`,
          remediation: "Sort by indexed, deterministic monotonically increasing columns (e.g. `ORDER BY id`).",
          line: lineNum,
        });
      }
    }

    // 4. Validate presence of explicit CLOSE if DECLARE exists
    const hasDeclare = /\bDECLARE\s+(\w+)\s+.*CURSOR\b/i.exec(sql);
    if (hasDeclare) {
      const cursorName = hasDeclare[1];
      const closeRegex = new RegExp(`\\bCLOSE\\s+(${cursorName}|ALL)\\b`, 'i');
      if (!closeRegex.test(sql)) {
        findings.push({
          ruleId: 'CURSOR_LEAK_MISSING_CLOSE',
          severity: 'HIGH',
          message: `Cursor '${cursorName}' is declared but no corresponding 'CLOSE ${cursorName}' statement was detected in the SQL block.`,
          remediation: `Ensure 'CLOSE ${cursorName};' is executed before transaction commit or in a finally block.`,
        });
      }
    }

    const criticalCount = findings.filter((f) => f.severity === 'CRITICAL').length;
    const highCount = findings.filter((f) => f.severity === 'HIGH').length;
    const score = Math.max(0, 100 - criticalCount * 40 - highCount * 20);

    return {
      passed: criticalCount === 0 && highCount === 0,
      score,
      findings,
    };
  }

  /**
   * Static code audit for TypeScript/JavaScript database client usage.
   * Catches naive `await db.select()` on large tables.
   */
  public static auditTypeScriptCode(code: string): CursorAuditResult {
    const findings: CursorAuditFinding[] = [];
    const lines = code.split('\n');

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const lineNum = i + 1;

      // Detect Prisma findAll / findMany without take or cursor
      if (/\bprisma\.\w+\.findMany\s*\(\s*\{?\s*\}?\s*\)/.test(line)) {
        findings.push({
          ruleId: 'PRISMA_UNBOUNDED_FIND_MANY',
          severity: 'HIGH',
          message: `Line ${lineNum}: Unbounded Prisma findMany() call without 'take' or 'cursor' pagination. Loads entire table into heap.`,
          remediation: "Provide 'take: 1000' and 'cursor' or use an async batch generator.",
          line: lineNum,
        });
      }

      // Detect TypeORM find() without skip/take
      if (/\bgetRepository\(\w+\)\.find\s*\(\s*\)/.test(line)) {
        findings.push({
          ruleId: 'TYPEORM_UNBOUNDED_FIND',
          severity: 'HIGH',
          message: `Line ${lineNum}: TypeORM find() without pagination options loads all entities into Node.js memory.`,
          remediation: "Use QueryBuilder `.stream()` or paginated find.",
          line: lineNum,
        });
      }
    }

    const criticalCount = findings.filter((f) => f.severity === 'CRITICAL').length;
    const highCount = findings.filter((f) => f.severity === 'HIGH').length;

    return {
      passed: criticalCount === 0 && highCount === 0,
      score: Math.max(0, 100 - criticalCount * 40 - highCount * 20),
      findings,
    };
  }
}
```

---

## 4. Cross-Language Production Implementations

### A. Go (`jackc/pgx/v5`): RAII Chunked Server-Side Cursor Batch Streaming

In high-performance Go microservices, reading 10,000,000 rows must never allocate an unbounded slice. The following implementation uses a scoped transaction, declares an explicit `NO SCROLL` cursor, fetches in bounded batches ($B = 2,000$), enforces an absolute statement timeout, and guarantees cleanup with `defer`:

```go
package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type AuditEventRecord struct {
	ID        string    `json:"id"`
	TenantID  string    `json:"tenant_id"`
	Payload   []byte    `json:"payload"`
	CreatedAt time.Time `json:"created_at"`
}

// StreamAuditEventsWithCursor streams high-volume audit logs in bounded chunks of 2,000 rows.
// Memory footprint remains constant at O(batchSize) regardless of table cardinality.
func StreamAuditEventsWithCursor(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	since time.Time,
	batchSize int,
	processBatch func(batch []AuditEventRecord) error,
) error {
	if batchSize <= 0 || batchSize > 5000 {
		batchSize = 2000
	}

	// 1. Acquire dedicated single connection for cursor lifecycle
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("failed acquiring connection from pool: %w", err)
	}
	defer conn.Release()

	// 2. Open transaction with strict timeouts to protect Autovacuum xmin horizon
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{
		IsoLevel:   pgx.ReadCommitted,
		AccessMode: pgx.ReadOnly,
	})
	if err != nil {
		return fmt.Errorf("failed starting read-only cursor transaction: %w", err)
	}
	defer tx.Rollback(ctx) // Safe RAII rollback if process fails or panics

	// Set local idle-in-transaction timeout to 30s to prevent stalled connection bloat
	if _, err := tx.Exec(ctx, "SET LOCAL idle_in_transaction_session_timeout = '30s'"); err != nil {
		return fmt.Errorf("failed setting idle transaction timeout: %w", err)
	}

	// 3. Declare NO SCROLL cursor with deterministic indexed ordering
	cursorName := "audit_stream_cur"
	declareSQL := fmt.Sprintf(
		`DECLARE %s NO SCROLL CURSOR FOR
		 SELECT id, tenant_id, payload, created_at
		 FROM audit_events
		 WHERE tenant_id = $1 AND created_at >= $2
		 ORDER BY created_at ASC, id ASC`,
		cursorName,
	)

	if _, err := tx.Exec(ctx, declareSQL, tenantID, since); err != nil {
		return fmt.Errorf("failed declaring server cursor: %w", err)
	}

	// Ensure cursor is explicitly closed upon function termination
	defer func() {
		closeCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = tx.Exec(closeCtx, fmt.Sprintf("CLOSE %s", cursorName))
	}()

	fetchSQL := fmt.Sprintf("FETCH FORWARD %d FROM %s", batchSize, cursorName)
	buffer := make([]AuditEventRecord, 0, batchSize)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		rows, err := tx.Query(ctx, fetchSQL)
		if err != nil {
			return fmt.Errorf("fetch batch error: %w", err)
		}

		buffer = buffer[:0] // Reset slice length while keeping underlying array capacity
		for rows.Next() {
			var rec AuditEventRecord
			if err := rows.Scan(&rec.ID, &rec.TenantID, &rec.Payload, &rec.CreatedAt); err != nil {
				rows.Close()
				return fmt.Errorf("row scan error: %w", err)
			}
			buffer = append(buffer, rec)
		}
		rows.Close()

		if len(buffer) == 0 {
			break // All tuples consumed cleanly
		}

		// Yield chunk to consumer; memory stays bounded to batchSize
		if err := processBatch(buffer); err != nil {
			return fmt.Errorf("batch processing callback failed: %w", err)
		}

		if len(buffer) < batchSize {
			break // Last partial page received
		}
	}

	// 4. Explicitly close cursor and commit transaction
	if _, err := tx.Exec(ctx, fmt.Sprintf("CLOSE %s", cursorName)); err != nil {
		return fmt.Errorf("failed closing cursor: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("failed committing cursor transaction: %w", err)
	}

	return nil
}
```

---

### B. TypeScript (Node.js): Backpressure-Safe Streaming with `pg-query-stream`

In Node.js, directly returning an array of 2,000,000 rows causes heap exhaustion. Using `pg-query-stream` backed by native PostgreSQL cursors with stream backpressure:

```typescript
// src/services/audit-export-stream.service.ts
import { Pool, PoolClient } from 'pg';
import QueryStream from 'pg-query-stream';
import { Transform, pipeline } from 'node:stream';
import { promisify } from 'node:util';
import type { Writable } from 'node:stream';

const pipelineAsync = promisify(pipeline);

export interface ExportStreamOptions {
  tenantId: string;
  startDate: Date;
  batchSize?: number;
  outputSink: Writable;
}

export class AuditExportStreamService {
  constructor(private readonly pool: Pool) {}

  /**
   * Streams audit events directly to an HTTP response or S3 upload stream
   * with strict constant RAM consumption (<= 15MB) using pg-query-stream.
   */
  public async exportAsNdjson(options: ExportStreamOptions): Promise<number> {
    const batchSize = Math.min(options.batchSize ?? 1000, 5000);
    const client: PoolClient = await this.pool.connect();
    let totalRowsExported = 0;

    try {
      // Begin transaction required for server-side cursor streaming
      await client.query('BEGIN READ ONLY');
      await client.query("SET LOCAL statement_timeout = '600000'"); // 10 min hard safety cap
      await client.query("SET LOCAL idle_in_transaction_session_timeout = '15000'"); // 15s idle cap

      const queryText = `
        SELECT id, tenant_id, payload, created_at
        FROM audit_events
        WHERE tenant_id = $1 AND created_at >= $2
        ORDER BY created_at ASC, id ASC
      `;

      // Instantiate QueryStream (PostgreSQL portal with NO SCROLL and batch prefetch)
      const queryStream = new QueryStream(queryText, [options.tenantId, options.startDate], {
        batchSize,
        highWaterMark: batchSize,
      });

      const pgStream = client.query(queryStream);

      // Transform object records to newline-delimited JSON (NDJSON)
      const ndjsonTransform = new Transform({
        objectMode: true,
        transform(row, _encoding, callback) {
          totalRowsExported++;
          const jsonLine = JSON.stringify(row) + '\n';
          callback(null, jsonLine);
        },
      });

      // Execute backpressure-aware pipeline (automatically pauses DB reads if consumer is slow)
      await pipelineAsync(pgStream, ndjsonTransform, options.outputSink);

      await client.query('COMMIT');
      return totalRowsExported;
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw new Error(`Audit stream export aborted: ${(err as Error).message}`);
    } finally {
      // Crucial: return connection to PgBouncer pool
      client.release();
    }
  }
}
```

---

### C. Python (`asyncpg`): Server-Side Cursor Asynchronous Generator

Python's `asyncpg` provides native asynchronous server-side cursor iteration with prefetch buffering, zeroing out client memory overhead:

```python
# src/db/cursor_streamer.py
import asyncpg
from typing import AsyncGenerator, Dict, Any
from datetime import datetime

async def stream_audit_events(
    pool: asyncpg.Pool,
    tenant_id: str,
    since: datetime,
    prefetch: int = 1000
) -> AsyncGenerator[Dict[str, Any], None]:
    """
    Asynchronously streams audit events row-by-row using a PostgreSQL server-side cursor.
    Maintains O(prefetch) memory in Python process memory.
    """
    # Acquire dedicated connection for transaction-scoped cursor
    async with pool.acquire() as connection:
        # Cursor MUST run within an active transaction block
        async with connection.transaction(readonly=True):
            # Guard against stalled consumers holding snapshot
            await connection.execute("SET LOCAL idle_in_transaction_session_timeout = '20s'")
            await connection.execute("SET LOCAL statement_timeout = '300s'")

            query = """
                SELECT id, tenant_id, payload, created_at
                FROM audit_events
                WHERE tenant_id = $1 AND created_at >= $2
                ORDER BY created_at ASC, id ASC
            """

            # asyncpg cursor() creates a portal with prefetch buffer
            cursor = await connection.cursor(query, tenant_id, since, prefetch=prefetch)
            
            while True:
                # Fetch bounded chunk
                records = await cursor.fetch(prefetch)
                if not records:
                    break
                for record in records:
                    yield dict(record)
```

---

### D. Rust (`sqlx`): Pipelined Stream Sinks with Backpressure

```rust
// src/db/streamer.rs
use sqlx::{PgPool, Row};
use futures::stream::{StreamExt, TryStreamExt};
use chrono::{DateTime, Utc};
use serde::Serialize;
use tokio::io::{AsyncWrite, AsyncWriteExt};

#[derive(Serialize)]
pub struct AuditEventDto {
    pub id: String,
    pub tenant_id: String,
    pub payload: serde_json::Value,
    pub created_at: DateTime<Utc>,
}

pub async fn stream_audit_events_to_writer<W>(
    pool: &PgPool,
    tenant_id: &str,
    since: DateTime<Utc>,
    mut writer: W,
) -> Result<u64, Box<dyn std::error::Error + Send + Sync>>
where
    W: AsyncWrite + Unpin,
{
    // sqlx .fetch() uses PostgreSQL protocol extended query streaming
    let mut stream = sqlx::query(
        r#"
        SELECT id, tenant_id, payload, created_at
        FROM audit_events
        WHERE tenant_id = $1 AND created_at >= $2
        ORDER BY created_at ASC, id ASC
        "#
    )
    .bind(tenant_id)
    .bind(since)
    .fetch(pool);

    let mut row_count = 0u64;

    while let Some(row_result) = stream.next().await {
        let row = row_result?;
        let dto = AuditEventDto {
            id: row.get("id"),
            tenant_id: row.get("tenant_id"),
            payload: row.get("payload"),
            created_at: row.get("created_at"),
        };

        let mut line = serde_json::to_vec(&dto)?;
        line.push(b'\n');
        writer.write_all(&line).await?;
        row_count += 1;
    }

    writer.flush().await?;
    Ok(row_count)
}
```

---

## 5. The 6-State Cursor Execution Lifecycle Finite State Machine (FSM)

```
                    ┌────────────────────────┐
                    │      0. UNBOUNDED      │
                    │      Client Heap       │
                    └───────────┬────────────┘
                                │ Acquire Dedicated Connection
                                ▼
                    ┌────────────────────────┐
                    │    1. INITIALIZED      │
                    │   BEGIN READ ONLY;     │
                    │   Set Session Timeouts │
                    └───────────┬────────────┘
                                │ DECLARE cur NO SCROLL CURSOR FOR ...
                                ▼
                    ┌────────────────────────┐
                    │       2. OPENED        │
                    │  Server Portal Created │
                    │  (Snapshot xmin Pinned)│
                    └───────────┬────────────┘
                                │
        ┌───────────────────────┴───────────────────────┐
        │ FETCH FORWARD B FROM cur                     │
        ▼                                               │
┌────────────────────────┐                             │
│     3. STREAMING       │                             │ Loop until
│ Constant O(B) Buffer   │                             │ Rows < B
│ Backpressure Applied   ├─────────────────────────────┘
└───────────┬────────────┘
            │
            ├───────────────────────────────────────────┐
            │ Success (EOF Reached)                     │ Error / Timeout / Abort
            ▼                                           ▼
┌────────────────────────┐                  ┌────────────────────────┐
│     4. COMMITTED       │                  │       5. ABORTED       │
│ CLOSE cur; COMMIT;     │                  │ CLOSE cur; ROLLBACK;   │
│ Snapshot Released      │                  │ Portal Forcefully Dead │
└───────────┬────────────┘                  └───────────┬────────────┘
            │                                           │
            └─────────────────────┬─────────────────────┘
                                  │ Connection Returned to Pool
                                  ▼
                    ┌────────────────────────┐
                    │     6. TERMINATED      │
                    │ Zero Leak, Zero Bloat  │
                    └────────────────────────┘
```

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Sentinels

Before any pull request or autonomous agent code change introducing batch queries, streaming pipelines, or server cursors is merged, verify compliance with this 6-gate checklist:

```bash
# 1. Reject unbounded findMany / select without limits or streaming in application repositories
! git grep -nE "(prisma\.[a-zA-Z]+\.findMany\(\)|getRepository\([a-zA-Z]+\)\.find\(\))" -- "src/**"

# 2. Reject raw cursors declared without explicit NO SCROLL
! git grep -inE "DECLARE\s+[a-zA-Z0-9_]+\s+(CURSOR\s+FOR|BINARY\s+CURSOR\s+FOR)" -- "src/**" "migrations/**" | grep -iv "NO SCROLL"

# 3. Reject dangerous WITH HOLD cursors in migrations and backend code
! git grep -inE "CURSOR\s+WITH\s+HOLD" -- "src/**" "migrations/**" "internal/**"

# 4. Reject cursors sorting by random() or non-indexed expressions
! git grep -inE "DECLARE\s+.*CURSOR\s+FOR\s+.*ORDER\s+BY\s+RANDOM\(\)" -- "src/**"

# 5. Ensure every declared cursor has a deterministic CLOSE statement
for file in $(git grep -lE "DECLARE\s+[a-zA-Z0-9_]+\s+.*CURSOR" -- "src/**" "internal/**"); do
  CURSOR_NAME=$(grep -oE "DECLARE\s+([a-zA-Z0-9_]+)\s+.*CURSOR" "$file" | awk '{print $2}')
  if ! grep -qE "CLOSE\s+($CURSOR_NAME|ALL)" "$file"; then
    echo "❌ Error: $file declares cursor '$CURSOR_NAME' without matching CLOSE statement!"
    exit 1
  fi
done

# 6. Verify client memory tests pass under restrictive cgroup / heap simulation
npm run test:stream-memory-budget
go test -v -race -run TestStreamAuditEventsMemory
```
