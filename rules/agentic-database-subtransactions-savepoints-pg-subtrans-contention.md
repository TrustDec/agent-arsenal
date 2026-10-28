---
description: Database subtransactions, SAVEPOINT pitfalls, pg_subtrans SLRU lock contention, 64-subxid cache overflow elimination, PL/pgSQL EXCEPTION traps, MultiXact thrashing, and zero-savepoint atomic workflows across Go (pgx/v5, GORM), TypeScript (Drizzle, Prisma, Kysely), Python (SQLAlchemy, asyncpg), Rust (sqlx), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{subtrans,savepoint,nested,transaction,tx,pgx,gorm,prisma,drizzle,sqlalchemy,kysely,sqlx,store,repo}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/models/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Subtransactions, SAVEPOINT Pitfalls, pg_subtrans Cache Overflow & MultiXact Contention Elimination Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design transaction boundaries, batch ingestion pipelines, nested transactions, PL/pgSQL stored procedures, or ORM retry handlers across PostgreSQL, Go (`jackc/pgx/v5`, `gorm`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`SQLAlchemy`, `asyncpg`), or Rust (`sqlx`). Eliminate the "64-Subtransaction Shared Memory Overflow Trap" (where PostgreSQL backends allocate a fixed 64-slot `PGPROC.subxids` cache, and the 65th savepoint sets `subxid-overflowed = true`, permanently disabling in-memory visibility lookups across the entire instance), the "Global `SubtransSLRULock` Contention & 100x TPS Collapse" (where concurrent transactions checking tuple visibility are forced to acquire a single global lock to read `pg_subtrans` on disk or page cache, driving server throughput from 60,000 TPS to <100 TPS while CPU spikes to 100% in kernel spinlocks), the "Hidden PL/pgSQL `BEGIN ... EXCEPTION` In-Loop Catastrophe" (where stored procedures with exception handling inside loops silently spawn thousands of subtransactions per transaction), the "ORM Nested Transaction Auto-Savepoint Cascade" (where frameworks like SQLAlchemy `begin_nested()`, Django `transaction.atomic()`, or GORM `SavePoint()` naively wrap individual row retries inside savepoints during large batches), the "MultiXactId Spill & Autovacuum Wraparound Threat" (where subtransaction row locks multiply MultiXacts in `pg_multixact`, exhausting 32-bit MultiXact IDs and triggering emergency freezing autovacuums), and the "Standby Replica Replay Delays" (where replica single-threaded WAL replay stalls reading `pg_subtrans`, creating massive replication lag spikes) by establishing a strict 5-Tier Subtransaction Governance Ladder, SLRU lock queuing models, zero-savepoint atomic SQL paradigms, and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Subtransaction Catastrophes vs The 5-Tier Governance Ladder

Subtransactions (created by `SAVEPOINT` in SQL, `begin_nested()` in SQLAlchemy, `atomic()` in Django, or `BEGIN ... EXCEPTION` in PL/pgSQL) permit partial rollbacks without aborting outer transactions. However, autonomous coding agents treat savepoints as cheap software try-catch blocks, oblivious to PostgreSQL's internal C engine constraints:

```typescript
// ❌ CATASTROPHIC LLM SUBTRANSACTION & SAVEPOINT ANTI-PATTERNS

// 1. The ORM Savepoint-in-Loop Batch Disaster!
// Autonomous agent attempts error resilience by wrapping each loop item in a savepoint:
export async function importInventoryItems(tx: PrismaClient, items: InventoryItem[]) {
  for (const item of items) {
    try {
      // ❌ Agent creates a SAVEPOINT per iteration!
      // In SQLAlchemy: with session.begin_nested():
      // In raw SQL / Go / Prisma: await tx.$executeRaw`SAVEPOINT sp_${item.id}`;
      await tx.inventory.create({ data: item });
    } catch (err) {
      // Rollback to savepoint and ignore duplicates
      await tx.$executeRaw`ROLLBACK TO SAVEPOINT sp_${item.id}`;
    }
  }
  // ❌ When items.length > 64, PGPROC.subxids overflows!
  // Every active transaction on Postgres now locks SubtransSLRULock on EVERY row visibility check!
  // Server-wide TPS drops 99%, p99 latency jumps from 2ms to 25,000ms!
}

// 2. The PL/pgSQL EXCEPTION Block in a Loop Trap!
// CREATE OR REPLACE FUNCTION batch_process_leads(lead_ids BIGINT[]) RETURNS VOID AS $$
// DECLARE l_id BIGINT;
// BEGIN
//   FOREACH l_id IN ARRAY lead_ids LOOP
//     BEGIN
//       -- ❌ In PostgreSQL, EVERY EXCEPTION block implicitly executes:
//       -- Savepoint "s_savepoint" -> try code -> on exception rollback to "s_savepoint"
//       INSERT INTO processed_leads (id) VALUES (l_id);
//     EXCEPTION WHEN unique_violation THEN
//       -- Silent catch
//     END;
//   END LOOP;
// END;
// $$ LANGUAGE plpgsql;
// ❌ A batch of 1,000 IDs generates 1,000 subxids! Triggers cluster-wide pg_subtrans meltdown!

// 3. MultiXact ID Exhaustion via Subtransaction Row-Locks!
// Outer transaction locks parent rows (SELECT FOR UPDATE / FOR SHARE).
// Inner savepoints lock child rows. Postgres creates MultiXactIds combining parent + subxid.
// ❌ Under high concurrent volume, consumes billions of MultiXacts, triggering emergency autovacuum!
```

| Governance Tier | Architectural Responsibility | Concrete Production Invariant |
| :--- | :--- | :--- |
| **Tier 0: Atomic SQL Elimination of Savepoints** | Eradicate Savepoint Retry Loops Entirely | Replace try-savepoint-catch with atomic single-statement SQL: `INSERT ... ON CONFLICT DO NOTHING / UPDATE`, `UPDATE ... WHERE ... RETURNING`, or `MERGE`. Zero subxids allocated. |
| **Tier 1: PL/pgSQL Exception-Free Set Logic** | Eradicate Implicit Subtransactions in Functions | Forbid `BEGIN ... EXCEPTION` inside loops in PL/pgSQL. Convert procedural row-by-row loops to declarative set operations (`INSERT ... SELECT ... ON CONFLICT`). |
| **Tier 2: ORM Auto-Savepoint Fencing & Chunked Transactions** | Hard Ceiling of $\le 1$ Savepoint & Micro-Batches | Forbid `begin_nested()` or `SavePoint()` inside iteration loops. Partition batch mutations into autonomous discrete transactions of $\le 500$ rows rather than monolithic transactions with nested savepoints. |
| **Tier 3: Observability & `SubtransSLRU` Wait Event Watchdogs** | Real-Time Detection of Overflowed Backends | Continuously query `pg_stat_activity` for `wait_event = 'SubtransSLRU'` or `SubtransBuffer`. Alert when `pg_stat_get_backend_subxact_info` reports `subxid-overflowed = true`. |
| **Tier 4: Machine-Verifiable CI AST & DDL Gates** | Automated Pull Request Gatekeeping | Static analysis linters (ESLint, golangci-lint, flake8/ruff, AST parser) failing CI if `SAVEPOINT`, `begin_nested()`, or PL/pgSQL `EXCEPTION` appear within loop bodies. |

---

## 2. Mathematical Formalism: Subxid Overflow, SLRU Queuing & Lock Thrashing

PostgreSQL tracks transaction IDs ($XID$) and subtransaction IDs ($SubXID$). Understanding the physical architecture of `PGPROC` and `pg_subtrans` reveals why savepoints must never be used in loops:

```
┌────────────────────────────────────────────────────────────────────────┐
│                   PostgreSQL Shared Memory (SRAM)                      │
│                                                                        │
│   Backend 1 (PGPROC)                  Backend 2 (PGPROC)               │
│   ┌──────────────────────────┐        ┌──────────────────────────┐     │
│   │ xid: 100452              │        │ xid: 100453              │     │
│   │ subxid_cache: [1..42]    │        │ subxid_cache: [1..64]    │     │
│   │ overflowed: FALSE (0)    │        │ overflowed: TRUE  (1) ───┼─┐   │
│   └──────────────────────────┘        └──────────────────────────┘ │   │
│                ▲                                                   │   │
│                │ FAST PATH: In-memory CPU cache check (< 50ns)     │   │
│                └──────────────────────────────────┐                │   │
│                                                   │                │   │
│   Concurrent Backend Checking Visibility          │                │   │
│   TransactionIdIsCurrentTransactionId()           │                │   │
│   "Are any active backends overflowed?" ──────────┴────────────────┘   │
│                               │                                        │
│                               ▼ IF ANY OVERFLOWED == TRUE              │
│               SLOW PATH: Must query SLRU Disk Cache!                  │
│                                                                        │
│   ┌────────────────────────────────────────────────────────────────┐   │
│   │                      SubtransSLRULock                          │   │
│   │      (Single Global Lightweight Lock for all 100+ Backends)    │   │
│   └────────────────────────────────┬───────────────────────────────┘   │
│                                    │                                   │
│                                    ▼                                   │
│   ┌────────────────────────────────────────────────────────────────┐   │
│   │             pg_subtrans Shared Memory Buffers (SLRU)           │   │
│   │   (Only 32 pages / 256KB in default PostgreSQL configuration!) │   │
│   └────────────────────────────────┬───────────────────────────────┘   │
│                                    │                                   │
│                        Buffer Miss │ Page Eviction                     │
│                                    ▼                                   │
│                    $PGDATA/pg_subtrans Disk I/O                        │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.1 The Subxid Cache Capacity & Overflow Invariant

Each PostgreSQL process descriptor `PGPROC` contains:
$$N_{\text{cached\_subxids}} \le \text{PGPROC\_MAX\_CACHED\_SUBXIDS} = 64$$

When a backend creates its $k$-th subtransaction:
$$\text{Overflowed}(T) = \begin{cases} 
0 \quad (\text{Fast Path Cached}), & k \le 64 \\ 
1 \quad (\text{Subxid Overflow}), & k > 64 
\end{cases}$$

### 2.2 The Global Visibility Check Penalty

When backend $B_i$ checks if a tuple modified by transaction $X$ is visible, it calls `TransactionIdIsCurrentTransactionId(X)`:
- If $\sum_{j=1}^M \text{Overflowed}(T_j) = 0$ (no active transaction has $>64$ subtransactions):
  The check evaluates exclusively in CPU L1/L2 cache over the local and peer `PGPROC` arrays. Time complexity is $O(M \cdot 64)$, taking $\tau_{\text{fast}} \approx 20\text{ns}$ to $50\text{ns}$.
- If $\sum_{j=1}^M \text{Overflowed}(T_j) \ge 1$ (even a single background worker or batch job has overflowed!):
  The fast path is invalidated globally. Backend $B_i$ must acquire `SubtransSLRULock` in shared mode, map $X$ to its parent by traversing the tree in `pg_subtrans`:
  $$\tau_{\text{slow}} = \tau_{\text{lock\_acquire}} + \sum_{p \in \text{Ancestors}(X)} \tau_{\text{slru\_page\_read}}(p)$$

### 2.3 Little's Law & SLRU Queue Collapse

Let $\lambda_{\text{vis}}$ be the cluster-wide arrival rate of tuple visibility checks ($\approx 500{,}000\text{ checks/sec}$ in OLTP). Under normal conditions, $\tau_{\text{vis}} = 50\text{ns}$.
When overflow occurs, $\tau_{\text{vis}}$ degrades to $50\mu\text{s}$ due to lock contention and SLRU buffer cache misses (a 1,000x increase).

By Little's Law, the queue length of backends waiting on `SubtransSLRULock` is:
$$Q_{\text{slru}} = \lambda_{\text{vis}} \cdot W_{\text{slru}}$$

If $\lambda_{\text{vis}} = 200{,}000\text{ checks/s}$ and $W_{\text{slru}} = 1\text{ms}$:
$$Q_{\text{slru}} = 200{,}000 \times 0.001 = 200\text{ backends blocked}$$

Since PostgreSQL maximum connections are typically $100$ to $300$, **100% of available backend connections are frozen in lock contention**, producing total system starvation.

### 2.4 MultiXact Member Growth & Freezing Horizon

When savepoints lock rows (explicitly via `SELECT ... FOR UPDATE/SHARE` or implicitly via foreign key validation), PostgreSQL records multiple transaction IDs on the same tuple using MultiXacts:
$$M_{\text{rate}} = \frac{d(\text{MultiXactId})}{dt} \propto N_{\text{subxids}} \times R_{\text{batch}}$$

When MultiXact IDs approach $2^{31} - 1$, PostgreSQL enters emergency shutdown mode to prevent wraparound corruption, forcing an offline or blocking `VACUUM FREEZE`.

---

## 3. The 6-State Subtransaction Elimination & Resilient Batch Lifecycle Finite-State Machine (FSM)

Autonomous agents must transition from naive nested savepoint retry loops to deterministic atomic operations:

```
┌────────────────────────────────────────────────────────────────────────┐
│         AGENTIC SUBTRANSACTION ELIMINATION & RESILIENT BATCH FSM       │
└────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │ 1. STATIC AST AUDIT   │
                     │ Scan code for         │
                     │ SAVEPOINT,            │
                     │ begin_nested(),       │
                     │ EXCEPTION in loops    │
                     └───────────┬───────────┘
                                 │
               Contains Savepoints in Iteration?
                                 │
                  ┌──────────────┴──────────────┐
                  │ YES                         │ NO
                  ▼                             ▼
       ┌──────────────────────┐     ┌───────────────────────┐
       │ 2. ATOMIC REWRITE    │     │ 3. STATEMENT BOUNDING │
       │ Transform to:        │     │ Configure timeouts:   │
       │ ON CONFLICT DO ...   │     │ lock_timeout = 2s     │
       │ or set-based MERGE   │     │ idle_in_tx = 5s       │
       └──────────┬───────────┘     └───────────┬───────────┘
                  │                             │
                  └──────────────┬──────────────┘
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │ 4. CHUNKING & BOUNDS  │
                     │ Partition batches     │
                     │ chunk_size <= 500     │
                     │ Discrete transactions │
                     └───────────┬───────────┘
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │ 5. EXECUTION & PROOF  │
                     │ Run batch with zero   │
                     │ subxids allocated;    │
                     │ RETURNING * feedback  │
                     └───────────┬───────────┘
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │ 6. SLRU SENTINEL GATE │
                     │ Verify wait_events:   │
                     │ SubtransSLRU == 0     │
                     │ overflowed == FALSE   │
                     └───────────────────────┘
```

---

## 4. Production-Grade TypeScript Reference Implementation: `AgenticDatabaseSubtransactionGuardEngine`

Autonomous agents must use this production engine to detect savepoint antipatterns in application code, rewrite loops into atomic SQL, and monitor PostgreSQL SLRU health:

```typescript
import { Client, PoolClient } from 'pg';

export interface SavepointViolation {
  file: string;
  line: number;
  pattern: 'RAW_SAVEPOINT' | 'ORM_NESTED_TX' | 'PLPGSQL_EXCEPTION_IN_LOOP';
  snippet: string;
  remediation: string;
}

export interface SubtransSLRUReport {
  timestamp: string;
  activeBackends: number;
  overflowedBackends: number;
  subtransWaitingBackends: number;
  status: 'HEALTHY' | 'DEGRADED' | 'EMERGENCY_MELTDOWN';
  recommendations: string[];
}

export class AgenticDatabaseSubtransactionGuardEngine {
  /**
   * Static AST Regex Scanner: Detects dangerous savepoint usage inside loops
   * in TypeScript, Go, Python, and SQL migration files.
   */
  public static scanCodeForSavepointHazards(code: string, filename: string): SavepointViolation[] {
    const violations: SavepointViolation[] = [];
    const lines = code.split('\n');

    let insideLoop = false;
    let loopDepth = 0;

    const loopStartRegex = /\b(for\s*\(|while\s*\(|for\s+[a-zA-Z0-9_]+\s+in|\.forEach\s*\(|\bLOOP\b)/i;
    const loopEndRegex = /(\}\s*$|\bEND\s+LOOP\b|\bEND;\b)/i;

    const savepointRegex = /\b(SAVEPOINT\s+[a-zA-Z0-9_]+|begin_nested\s*\(|tx\.SavePoint|\$executeRaw.*SAVEPOINT)\b/i;
    const plpgsqlExceptionRegex = /\bEXCEPTION\s+WHEN\b/i;

    for (let i = 0; i < lines.length; i++) {
      const lineText = lines[i];

      if (loopStartRegex.test(lineText)) {
        insideLoop = true;
        loopDepth++;
      }

      if (insideLoop) {
        if (savepointRegex.test(lineText)) {
          violations.push({
            file: filename,
            line: i + 1,
            pattern: 'RAW_SAVEPOINT',
            snippet: lineText.trim(),
            remediation: 'Eliminate SAVEPOINT inside loop. Replace with INSERT ... ON CONFLICT DO NOTHING or batch multi-values with discrete transactions.',
          });
        }

        if (plpgsqlExceptionRegex.test(lineText)) {
          violations.push({
            file: filename,
            line: i + 1,
            pattern: 'PLPGSQL_EXCEPTION_IN_LOOP',
            snippet: lineText.trim(),
            remediation: 'PL/pgSQL EXCEPTION inside a LOOP allocates an internal subtransaction per iteration. Refactor to IF NOT EXISTS check or INSERT ... ON CONFLICT.',
          });
        }
      }

      if (loopEndRegex.test(lineText)) {
        loopDepth = Math.max(0, loopDepth - 1);
        if (loopDepth === 0) insideLoop = false;
      }
    }

    return violations;
  }

  /**
   * Diagnostic Sentinel: Inspects PostgreSQL for SubtransSLRU lock contention
   * and identifies any backends that have exceeded the 64-subxid cache.
   */
  public static async inspectSLRUHealth(client: PoolClient | Client): Promise<SubtransSLRUReport> {
    // Check 1: Active backends waiting on SubtransSLRU Lightweight Locks
    const waitEventsQuery = `
      SELECT
        COUNT(*) AS total_backends,
        COUNT(*) FILTER (WHERE wait_event IN ('SubtransSLRU', 'SubtransBuffer')) AS subtrans_waiters
      FROM pg_stat_activity
      WHERE state = 'active';
    `;
    const waitRes = await client.query(waitEventsQuery);
    const totalBackends = parseInt(waitRes.rows[0].total_backends, 10) || 0;
    const subtransWaiters = parseInt(waitRes.rows[0].subtrans_waiters, 10) || 0;

    // Check 2: Inspect subxid status for current backends
    // In PostgreSQL 13+, pg_stat_get_backend_subxact_status is available internally,
    // or inspect through pg_locks where locktype = 'transactionid' with large count per pid
    const subxidSpillQuery = `
      SELECT
        pid,
        COUNT(*) AS lock_count
      FROM pg_locks
      WHERE locktype = 'transactionid'
      GROUP BY pid
      HAVING COUNT(*) > 64;
    `;
    const spillRes = await client.query(subxidSpillQuery);
    const overflowedBackends = spillRes.rows.length;

    let status: 'HEALTHY' | 'DEGRADED' | 'EMERGENCY_MELTDOWN' = 'HEALTHY';
    const recs: string[] = [];

    if (subtransWaiters > 0) {
      status = 'EMERGENCY_MELTDOWN';
      recs.push(`CRITICAL: ${subtransWaiters} backend(s) actively blocked waiting on SubtransSLRULock. Throughput is stalling!`);
      recs.push('Immediately terminate queries causing high subtransaction generation using pg_terminate_backend().');
    } else if (overflowedBackends > 0) {
      status = 'DEGRADED';
      recs.push(`WARNING: ${overflowedBackends} backend(s) hold > 64 transaction locks, indicating subxid overflow risk.`);
      recs.push('Refactor application batch workers to avoid SAVEPOINT / begin_nested() in loops.');
    } else {
      recs.push('SLRU subtransaction subsystem is healthy. All active transactions within 64-subxid shared cache.');
    }

    return {
      timestamp: new Date().toISOString(),
      activeBackends: totalBackends,
      overflowedBackends,
      subtransWaitingBackends: subtransWaiters,
      status,
      recommendations: recs,
    };
  }

  /**
   * Resilient Zero-Savepoint Batch Runner: Partitions items into bounded chunks
   * and executes single-statement atomic upserts with zero subxid allocation.
   */
  public static async executeAtomicBatchWithoutSavepoints<T, R>(
    client: PoolClient,
    items: T[],
    chunkSize: number,
    queryBuilder: (chunk: T[]) => { text: string; values: any[] }
  ): Promise<R[]> {
    if (items.length === 0) return [];
    if (chunkSize > 500) {
      throw new Error(`Safety Violation: Chunk size ${chunkSize} exceeds recommended 500-item ceiling.`);
    }

    const results: R[] = [];

    // Process chunk by chunk in discrete transactions (zero savepoints)
    for (let i = 0; i < items.length; i += chunkSize) {
      const chunk = items.slice(i, i + chunkSize);
      const { text, values } = queryBuilder(chunk);

      await client.query('BEGIN');
      try {
        await client.query('SET LOCAL lock_timeout = 2000'); // 2s lock ceiling
        await client.query('SET LOCAL statement_timeout = 5000'); // 5s query ceiling

        const res = await client.query(text, values);
        results.push(...(res.rows as R[]));
        await client.query('COMMIT');
      } catch (err) {
        await client.query('ROLLBACK');
        throw new Error(`Batch execution failed on chunk starting at index ${i}: ${(err as Error).message}`);
      }
    }

    return results;
  }
}
```

---

## 5. Cross-Language Production Patterns

### 5.1 PostgreSQL & PL/pgSQL: Eradicate `EXCEPTION` Inside Loops

```sql
-- ❌ CATASTROPHIC ANTI-PATTERN: EXCEPTION inside LOOP in PL/pgSQL
-- Every iteration allocates an internal savepoint. At loop count > 64, overflows PGPROC.subxids!
CREATE OR REPLACE FUNCTION naive_process_items(p_items JSONB) RETURNS VOID AS $$
DECLARE
  v_item JSONB;
BEGIN
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    BEGIN
      INSERT INTO inventory (item_id, qty)
      VALUES ((v_item->>'id')::UUID, (v_item->>'qty')::INT);
    EXCEPTION WHEN unique_violation THEN
      -- Implicit subtransaction rollback on collision!
      UPDATE inventory SET qty = qty + (v_item->>'qty')::INT
      WHERE item_id = (v_item->>'id')::UUID;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ✅ PRODUCTION INVARIANT: Pure Declarative Atomic Upsert (Zero Subtransactions!)
-- Single SQL statement, 0 savepoints, 100x faster execution, perfectly safe under concurrency.
CREATE OR REPLACE FUNCTION production_process_items(p_items JSONB) RETURNS VOID AS $$
BEGIN
  INSERT INTO inventory (item_id, qty, updated_at)
  SELECT 
    (elem->>'id')::UUID,
    (elem->>'qty')::INT,
    clock_timestamp()
  FROM jsonb_array_elements(p_items) AS elem
  ON CONFLICT (item_id)
  DO UPDATE SET
    qty = inventory.qty + EXCLUDED.qty,
    updated_at = clock_timestamp()
  WHERE inventory.qty != inventory.qty + EXCLUDED.qty;
END;
$$ LANGUAGE plpgsql;
```

---

### 5.2 Go (`jackc/pgx/v5`): Replace Savepoint Retries with Atomic Queries

```go
package store

import (
	"context"
	"fmt"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type EventLog struct {
	EventID   string
	Payload   string
}

// ❌ ANTI-PATTERN: Using tx.BeginSubTx (SAVEPOINT) inside a batch loop!
func NaiveIngestLogs(ctx context.Context, pool *pgxpool.Pool, logs []EventLog) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	for _, log := range logs {
		// ❌ Creates SAVEPOINT per row. After 64 rows, triggers SLRU spill!
		subTx, err := tx.Begin(ctx)
		if err != nil {
			return err
		}
		_, err = subTx.Exec(ctx, "INSERT INTO event_logs (event_id, payload) VALUES ($1, $2)", log.EventID, log.Payload)
		if err != nil {
			subTx.Rollback(ctx) // Rollback to savepoint
		} else {
			subTx.Commit(ctx)   // Release savepoint
		}
	}
	return tx.Commit(ctx)
}

// ✅ PRODUCTION INVARIANT: Atomic Batch Insertion with ON CONFLICT DO NOTHING
// Zero subtransactions allocated. Batch executes via pgx.Batch in a single roundtrip.
func ProductionIngestLogs(ctx context.Context, pool *pgxpool.Pool, logs []EventLog) error {
	if len(logs) == 0 {
		return nil
	}

	tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("failed to begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// Guard against long lock stalls
	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2000ms'; SET LOCAL statement_timeout = '5000ms'"); err != nil {
		return fmt.Errorf("failed to set timeouts: %w", err)
	}

	batch := &pgx.Batch{}
	query := `
		INSERT INTO event_logs (event_id, payload, created_at)
		VALUES ($1, $2, clock_timestamp())
		ON CONFLICT (event_id) DO NOTHING;
	`
	for _, l := range logs {
		batch.Queue(query, l.EventID, l.Payload)
	}

	br := tx.SendBatch(ctx, batch)
	for i := 0; i < len(logs); i++ {
		if _, err := br.Exec(); err != nil {
			br.Close()
			return fmt.Errorf("batch failed at item %d: %w", i, err)
		}
	}
	if err := br.Close(); err != nil {
		return fmt.Errorf("failed to close batch: %w", err)
	}

	return tx.Commit(ctx)
}
```

---

### 5.3 Python (`SQLAlchemy` / `asyncpg`): Forbid `begin_nested()` Inside Loops

```python
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy import text
from typing import List, Dict

# ❌ ANTI-PATTERN: begin_nested() inside a loop in SQLAlchemy
async def naive_bulk_sync(session: AsyncSession, records: List[Dict]):
    async with session.begin():
        for rec in records:
            # ❌ begin_nested() issues SAVEPOINT in PostgreSQL!
            # If records has 200 items, creates 200 subxids -> causes subxid overflow!
            async with session.begin_nested():
                await session.execute(
                    text("INSERT INTO devices (serial, status) VALUES (:s, :st)"),
                    {"s": rec["serial"], "st": rec["status"]}
                )

# ✅ PRODUCTION INVARIANT: Bulk Insert via ON CONFLICT DO UPDATE (Single Statement, Zero Savepoints)
async def production_bulk_sync(session: AsyncSession, records: List[Dict]):
    if not records:
        return

    # Chunk into 500 records max
    chunk_size = 500
    for i in range(0, len(records), chunk_size):
        chunk = records[i:i + chunk_size]
        async with session.begin():
            # Set defensive timeouts
            await session.execute(text("SET LOCAL lock_timeout = '2000ms'"))
            
            stmt = insert(devices_table).values(chunk)
            upsert_stmt = stmt.on_conflict_do_update(
                index_elements=['serial'],
                set_={
                    'status': stmt.excluded.status,
                    'updated_at': text('clock_timestamp()')
                },
                where=(devices_table.c.status.is_distinct_from(stmt.excluded.status))
            )
            await session.execute(upsert_stmt)
```

---

### 5.4 TypeScript (`Drizzle` / `Kysely`): Bounded Micro-Batches Without Savepoints

```typescript
import { db } from './db';
import { users } from './schema';
import { sql } from 'drizzle-orm';

interface UserInput {
  tenantId: string;
  email: string;
  fullName: string;
}

// ✅ PRODUCTION INVARIANT: Drizzle Batch Insert with ON CONFLICT & Zero Savepoints
export async function syncTenantUsers(tenantId: string, userInputs: UserInput[]) {
  if (userInputs.length === 0) return;

  const CHUNK_SIZE = 500;
  for (let i = 0; i < userInputs.length; i += CHUNK_SIZE) {
    const chunk = userInputs.slice(i, i + CHUNK_SIZE);

    // Each chunk runs in an independent, clean top-level transaction. Zero savepoints!
    await db.transaction(async (tx) => {
      await tx.execute(sql`SET LOCAL lock_timeout = '2000ms'`);

      await tx
        .insert(users)
        .values(
          chunk.map((u) => ({
            tenantId,
            email: u.email.toLowerCase().trim(),
            fullName: u.fullName,
          }))
        )
        .onConflictDoUpdate({
          target: [users.tenantId, users.email],
          set: {
            fullName: sql`EXCLUDED.full_name`,
            updatedAt: sql`clock_timestamp()`,
          },
          where: sql`${users.fullName} IS DISTINCT FROM EXCLUDED.full_name`,
        });
    });
  }
}
```

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Matrix

Every autonomous coding agent workflow modifying transactions, batch imports, or database functions must satisfy this 6-gate verification matrix:

```bash
# Gate 1: Static AST Check for SAVEPOINT & begin_nested() in iteration loops
rg -n -i 'SAVEPOINT|begin_nested|BeginSubTx|SavePoint' src/ internal/ migrations/ | \
  grep -E 'for|while|loop' && echo "❌ GATE 1 FAILED: Savepoint found in loop!" || echo "✅ GATE 1 PASSED"

# Gate 2: PL/pgSQL In-Loop EXCEPTION Sentinel
rg -i 'EXCEPTION\s+WHEN' migrations/ src/ internal/ | \
  grep -v -E 'CREATE FUNCTION.*EXCEPTION' && echo "⚠️ Manual audit required" || echo "✅ GATE 2 PASSED"

# Gate 3: Check Cluster for Active SubtransSLRU Lightweight Lock Contention
psql "$DATABASE_URL" -c "
  SELECT pid, wait_event, wait_event_type, query, state 
  FROM pg_stat_activity 
  WHERE wait_event IN ('SubtransSLRU', 'SubtransBuffer');
"

# Gate 4: Identify Transactions with High Subxid Counts (> 64)
psql "$DATABASE_URL" -c "
  SELECT pid, count(*) as subxid_lock_count 
  FROM pg_locks 
  WHERE locktype = 'transactionid' 
  GROUP BY pid 
  HAVING count(*) > 64;
"

# Gate 5: Unit & Concurrency Test Verification
# Verify batch operations execute under high concurrency without subxid overflow
npm test -- --grep "atomic-batch" || go test -race ./internal/store/...

# Gate 6: Statement & Lock Timeout Verification
# Ensure all transactional wrappers enforce lock_timeout <= 2000ms
rg -i 'SET LOCAL lock_timeout' src/ internal/
```
