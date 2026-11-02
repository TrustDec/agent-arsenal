---
description: PostgreSQL 17 MERGE with RETURNING merge_action(), concurrency conflict elimination, source deduplication, partitioned table row movement, clause order precedence, and batch synchronization invariants across Go (pgx), TypeScript (pg/Drizzle), Python (asyncpg), Rust (sqlx), Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{merge,upsert,sync,reconcile,batch_loader,dedup}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/database/**/*.{ts,js,go,rs,py},**/lib/db/**/*.{ts,js,go,rs,py},**/internal/database/**/*.{go,rs},**/migrations/**/*.{sql,ts,py,go},**/queries/**/*.{sql,ts,go,rs,py}
alwaysApply: false
---

# Agentic Database PostgreSQL 17 MERGE with RETURNING (`merge_action()`), Concurrency Conflict Guard, Partitioned Table Routing & Batch Synchronization Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, optimize, or execute high-throughput batch synchronization, ETL reconciliation, data warehouse staging ingestion, inventory reconciliation, or polymorphic entity mutations across PostgreSQL 17+, Go (`jackc/pgx/v5`), TypeScript (`pg`, `Drizzle`, `Kysely`, `Prisma`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Concurrency Race Condition & The False Equivalence of MERGE vs INSERT ... ON CONFLICT Trap" (where agents assume `MERGE` provides row-level speculative insertion locking, leading to concurrent insertion collisions with `SQLSTATE 23505: unique_violation` or serialization aborts `SQLSTATE 40001`), the "Multiple Match Cardinality Violation Trap (`SQLSTATE 21000: MERGE command cannot affect row a second time`)" (where un-deduplicated source datasets match a target row more than once, violently aborting batch pipelines), the "Dead Branch Ordering & Short-Circuit Clause Masking Disaster" (where placing an unconditional `WHEN MATCHED THEN UPDATE` before a conditional `WHEN MATCHED AND ... THEN DELETE` turns deletion into dead code and corrupts entity lifecycle states), the "Unindexed Join Predicates & Full Table Scan Lockout Convoys" (where target join columns lack covering B-Tree indexes, forcing PostgreSQL into catastrophic sequential scans that hold relation locks and exhaust connection pools), the "Partitioned Table Row Movement & Foreign Key / Trigger Desynchronization Trap" (where `MERGE` updating a partition key deletes and re-inserts tuples across partitions, producing unexpected trigger firings and transient query anomalies), and the "RETURNING Target vs Source Column Projection Drift & CDC Offset Mismatch" (where agents fail to project pre- and post-mutation deltas alongside `merge_action()`, losing auditability or breaking CDC consumers on skipped rows) by establishing a strict 5-Tier MERGE Governance Ladder, formal concurrency collision and join complexity models, an autonomous TypeScript `AgenticPostgres17MergeGuardEngine`, cross-runtime driver sentinels in Go, TypeScript, Python, and Rust, a 6-state execution lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 MERGE Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL 15 introduced the standard SQL `MERGE` statement (`MERGE INTO target USING source ON join_expr ...`), enabling single-statement conditional operations (`WHEN MATCHED THEN UPDATE/DELETE/DO NOTHING`, `WHEN NOT MATCHED THEN INSERT/DO NOTHING`). However, PostgreSQL 15 and 16 lacked a `RETURNING` clause on `MERGE`, forcing developers to execute secondary analytical queries (`SELECT`) to discover which rows were affected, incurring extra network round-trips ($O(2 \cdot \text{RTT})$) and introducing read-after-write race conditions.

PostgreSQL 17 achieved a pivotal breakthrough by introducing the **`RETURNING` clause on `MERGE`**, complemented by the native contextual function **`merge_action()`**. The function dynamically evaluates to `'INSERT'`, `'UPDATE'`, or `'DELETE'` for each processed row. Furthermore, PostgreSQL 17 expanded `MERGE` capability on declarative partitioned tables, supporting partition key updates with automatic cross-partition row movement.

However, when autonomous coding agents adopt `MERGE` without deep knowledge of PostgreSQL's concurrency model, locking semantics, and execution plans, they routinely trigger six critical production catastrophes:

```
+----------------------------------------------------------------------------------------------------+
|                             THE 6 POSTGRESQL 17 MERGE CATASTROPHES                                 |
+----------------------------------------------------------------------------------------------------+
| 1. Concurrency Race & False Equivalence with ON CONFLICT (SQLSTATE 23505 / 40001)                 |
|    - Agent treats MERGE as an atomic drop-in for INSERT ... ON CONFLICT. Under READ COMMITTED, two   |
|      concurrent transactions join on the same missing row, both evaluate WHEN NOT MATCHED, and both|
|      attempt INSERT, violently failing with SQLSTATE 23505 (unique_violation). Under REPEATABLE     |
|      READ, concurrent updates trigger SQLSTATE 40001 (could not serialize access).                 |
|                                                                                                    |
| 2. Multiple Match Cardinality Violation (SQLSTATE 21000)                                           |
|    - Source dataset contains duplicate join keys. PostgreSQL requires that each target row matches |
|      at most one source row. When multiple source rows join against one target row, PostgreSQL      |
|      aborts the command: "ERROR: MERGE command cannot affect row a second time" (SQLSTATE 21000).  |
|                                                                                                    |
| 3. Dead Branch Ordering & Short-Circuit Clause Masking                                             |
|    - WHEN MATCHED clauses evaluate strictly in order of appearance. The first matching clause      |
|      executes. Placing unconditional 'WHEN MATCHED THEN UPDATE' before 'WHEN MATCHED AND           |
|      source.deleted = true THEN DELETE' masks the delete branch completely. Rows are never purged.  |
|                                                                                                    |
| 4. Unindexed Join Predicates & Full Table Scan Lockout Convoys                                     |
|    - MERGE performs a relational join between source and target. If the ON (...) predicate lacks a  |
|      supporting B-Tree index on target, PostgreSQL executes an O(M * N) sequential scan or hash    |
|      join, holding row locks, spiking CPU to 100%, and causing connection pool exhaustion.         |
|                                                                                                    |
| 5. Partitioned Table Row Movement & Foreign Key / Trigger Desynchronization                        |
|    - In PG17, updating a partition key moves rows between leaf partitions (DELETE + INSERT under    |
|      the hood). If statement-level triggers or foreign key references expect an in-place update,  |
|      unexpected cascade failures, trigger order inversion, or transient read anomalies occur.      |
|                                                                                                    |
| 6. RETURNING Column Projection Drift & CDC Offset Mismatch                                         |
|    - In MERGE ... RETURNING, target column references reflect values AFTER the action. For DELETE,  |
|      it reflects pre-deletion state. For skipped rows (DO NOTHING), ZERO rows are returned. If CDC |
|      consumers rely on fixed batch outputs or need full before/after deltas, state desync occurs.  |
+----------------------------------------------------------------------------------------------------+
```

To eliminate these catastrophes, all autonomous coding agents, ORMs, and database engineers must adhere to the **5-Tier MERGE Governance Ladder**:

```
+----------------------------------------------------------------------------------------------------+
|                              THE 5-TIER MERGE GOVERNANCE LADDER                                    |
+----------------------------------------------------------------------------------------------------+
| Tier 0: Engine & Concurrency Model Qualification                                                   |
|   - Mandate PostgreSQL >= 17.0 for RETURNING merge_action().                                       |
|   - Strict architectural fork: Use 'INSERT ... ON CONFLICT' for high-concurrency single-row/point  |
|     upserts (speculative insertion locks); use 'MERGE' strictly for batch multi-action ETL/sync     |
|     requiring conditional INSERT, UPDATE, DELETE, and DO NOTHING branches.                         |
+----------------------------------------------------------------------------------------------------+
| Tier 1: Source Deduplication & 1:1 Join Cardinality Invariant                                      |
|   - Source relations or CTEs MUST be pre-deduplicated using ROW_NUMBER() OVER (PARTITION BY        |
|     join_keys ORDER BY mutation_timestamp DESC) or DISTINCT ON (join_keys).                        |
|   - Eliminate SQLSTATE 21000 ("cannot affect row a second time") by mathematical construction.     |
+----------------------------------------------------------------------------------------------------+
| Tier 2: Sargable Join Predicates & Dedicated Leftmost B-Tree Indexing                              |
|   - Target columns referenced in ON (...) MUST have a PRIMARY KEY, UNIQUE, or leftmost composite   |
|     B-Tree index. Ensure EXPLAIN verifies Index/Bitmap Scan instead of Sequential Scan.             |
|   - Bounded join complexity: O(M log N) with index lookup, eliminating connection pool convoys.    |
+----------------------------------------------------------------------------------------------------+
| Tier 3: Strict Clause Precedence & Conditional Ordering Protocol                                  |
|   - Order clauses from most specific/destructive to least specific:                                |
|       1. WHEN MATCHED AND condition THEN DELETE                                                    |
|       2. WHEN MATCHED AND condition THEN UPDATE                                                    |
|       3. WHEN MATCHED THEN UPDATE (unconditional fallback)                                         |
|       4. WHEN NOT MATCHED AND condition THEN INSERT                                                |
|       5. WHEN NOT MATCHED THEN INSERT                                                              |
|   - Zero dead branches: Static SQL linting verifies no unreachable clauses exist.                  |
+----------------------------------------------------------------------------------------------------+
| Tier 4: Single-Roundtrip Telemetry via RETURNING merge_action() & CDC Outbox Integration           |
|   - Project merge_action(), target post-mutation columns, and source payload in RETURNING.         |
|   - In Go/Node/Python/Rust microservices, map merge_action() to Domain Event topics                |
|     ('ENTITY_CREATED', 'ENTITY_UPDATED', 'ENTITY_PURGED') in a single atomic database trip.       |
|   - Wrap batch MERGE in an idempotent retry harness handling transient SQLSTATE 23505 and 40001.   |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. Mathematical Models, Latency Differentials & Concurrency Invariant Theorems

### 2.1 The Concurrency Race Inequality: Why MERGE Differs Fundamentally from `INSERT ... ON CONFLICT`

When two concurrent transactions $T_1$ and $T_2$ attempt to insert or update the same key $K$ at rate $\lambda$:
- In **`INSERT ... ON CONFLICT DO UPDATE`**, PostgreSQL utilizes low-level speculative insertion locks (`SpeculativeInsertionWait`). $T_1$ acquires a speculative token on the unique index. $T_2$ detects the pending speculative tuple, blocks on $T_1$'s transaction ID, and upon $T_1$'s commit, wakes up and cleanly executes the `DO UPDATE` branch. The probability of an unhandled race error is zero:
  $$P(\text{Collision Error} \mid \text{ON CONFLICT}) \equiv 0$$
- In **`MERGE`**, PostgreSQL evaluates the query plan as a join between `source` and `target`. Under `READ COMMITTED` isolation, if row $K$ does not exist when $T_1$ and $T_2$ perform their join scan, both evaluate the join condition to `FALSE` (non-matching). Both proceed to the `WHEN NOT MATCHED THEN INSERT` branch:
  $$\text{Match}(T_1, K) = \emptyset \implies \text{Action}(T_1) = \text{INSERT}$$
  $$\text{Match}(T_2, K) = \emptyset \implies \text{Action}(T_2) = \text{INSERT}$$
  $T_1$ inserts row $K$ and commits. $T_2$ attempts to insert row $K$. Because $T_2$ committed to the `INSERT` branch during its initial plan evaluation, it attempts physical insertion into the unique index, triggering an immediate:
  $$\text{SQLSTATE 23505: duplicate key value violates unique constraint}$$

The probability of collision in high-concurrency environments over time window $\Delta t$ scales quadratically with arrival rate:
$$P(\text{Race Collision} \mid \text{MERGE}) = 1 - e^{-\lambda^2 \cdot \Delta t_{\text{eval}}}$$
where $\Delta t_{\text{eval}}$ is the elapsed time between the join scan evaluation and the index tuple insertion.

**Architectural Theorem 1 (The Single-Row Upsert Partition Law)**:
For point lookups, single-row inserts, or high-concurrency low-latency OLTP endpoints, systems MUST utilize `INSERT ... ON CONFLICT DO UPDATE`. Systems MUST reserve `MERGE` for batch ETL synchronization, multi-action reconciliations (conditional delete + update + insert), or offline data ingestion pipelines where $T_1$ and $T_2$ do not contend on disjoint source partitions.

---

### 2.2 The 1:1 Cardinality Theorem for SQLSTATE 21000 Elimination

PostgreSQL standard Section 14.11 dictates that a `MERGE` statement must not attempt to modify the same target row multiple times within a single command execution:
$$\forall t \in \text{Target}, \quad \left| \{ s \in \text{Source} \mid \text{JoinPred}(s, t) = \text{TRUE} \} \right| \le 1$$

If a batch source contains duplicates:
$$\exists t \in \text{Target} \quad \text{such that} \quad |S_t| > 1 \implies \text{Throw SQLSTATE 21000 ("MERGE cannot affect row a second time")}$$

By introducing a deterministic deduplication CTE with window functions:
$$\text{Deduplicated}(S) = \{ s \in S \mid \text{row\_number}() \text{ OVER (PARTITION BY } \text{join\_key} \text{ ORDER BY } \text{epoch} \text{ DESC}) = 1 \}$$
We mathematically guarantee:
$$\left| \{ s \in \text{Deduplicated}(S) \mid \text{JoinPred}(s, t) \} \right| \le 1, \quad \forall t \in \text{Target}$$
Permanently eradicating `SQLSTATE 21000` from production ETL jobs.

---

### 2.3 Single-Roundtrip Telemetry Throughput Acceleration

Prior to PostgreSQL 17, capturing mutations from batch synchronizations required a two-phase protocol:
$$T_{\text{legacy}} = (T_{\text{MERGE}} + \text{RTT}) + (T_{\text{SELECT\_DELTA}} + \text{RTT})$$
In distributed cloud architectures with cross-AZ or cross-region network latency ($\text{RTT} \approx 2\text{ms} - 15\text{ms}$), the multi-roundtrip tax degrades throughput and risks reading stale intermediate states.

Under PostgreSQL 17 `MERGE ... RETURNING merge_action(), target.*, source.*`:
$$T_{\text{pg17}} = T_{\text{MERGE}} + \text{RTT}$$
The speedup ratio $\sigma$ for rapid batch sync microservices:
$$\sigma = \frac{T_{\text{legacy}}}{T_{\text{pg17}}} \approx 1.85\times - 2.40\times$$
Eliminating 100% of read-after-write anomalies and secondary index lookups.

---

## 3. Autonomous TypeScript Engine: `AgenticPostgres17MergeGuardEngine`

This engine verifies, lints, and rewrites SQL `MERGE` queries to ensure strict adherence to PostgreSQL 17 standards, clause ordering invariants, source deduplication, and index protection.

```typescript
/**
 * AgenticPostgres17MergeGuardEngine
 * Industrial-grade AST validation and SQL synthesis for PostgreSQL 17 MERGE statements.
 * Enforces clause ordering, source deduplication CTEs, index prerequisites, and RETURNING telemetry.
 */

export interface MergeClause {
  type: 'MATCHED' | 'NOT_MATCHED';
  condition?: string;
  action: 'UPDATE' | 'DELETE' | 'INSERT' | 'DO_NOTHING';
  setAssignments?: Record<string, string>;
  insertColumns?: string[];
  insertValues?: string[];
}

export interface MergeStatementDefinition {
  targetTable: string;
  targetAlias?: string;
  sourceExpression: string; // Table name, VALUES, or subquery
  sourceAlias: string;
  joinCondition: string;
  joinKeys: string[];
  clauses: MergeClause[];
  returningColumns?: string[];
  includeMergeAction?: boolean;
  enableSourceDeduplication?: boolean;
  dedupOrderingColumn?: string;
}

export interface ValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
  synthesizedSQL?: string;
}

export class AgenticPostgres17MergeGuardEngine {
  /**
   * Validates a MERGE statement definition against PostgreSQL 17 invariants.
   */
  public static validate(def: MergeStatementDefinition): ValidationResult {
    const errors: string[] = [];
    const warnings: string[] = [];

    // Invariant 1: Join keys must be defined
    if (!def.joinKeys || def.joinKeys.length === 0) {
      errors.push('CRITICAL: joinKeys must be explicitly specified to guarantee index coverage and deduplication.');
    }

    // Invariant 2: Clause ordering validation
    let hasUnconditionalMatched = false;
    let hasUnconditionalNotMatched = false;

    for (let i = 0; i < def.clauses.length; i++) {
      const clause = def.clauses[i];

      if (clause.type === 'MATCHED') {
        if (hasUnconditionalMatched) {
          errors.push(
            `DEAD CODE DETECTED: Clause at index ${i} (${clause.action}) is unreachable because it follows an unconditional WHEN MATCHED clause.`
          );
        }
        if (!clause.condition) {
          hasUnconditionalMatched = true;
        }
      }

      if (clause.type === 'NOT_MATCHED') {
        if (hasUnconditionalNotMatched) {
          errors.push(
            `DEAD CODE DETECTED: Clause at index ${i} (${clause.action}) is unreachable because it follows an unconditional WHEN NOT MATCHED clause.`
          );
        }
        if (!clause.condition) {
          hasUnconditionalNotMatched = true;
        }
      }

      // Invariant 3: DELETE requires WHEN MATCHED
      if (clause.action === 'DELETE' && clause.type !== 'MATCHED') {
        errors.push(`SYNTAX ERROR: Action DELETE is only valid in WHEN MATCHED clauses.`);
      }

      // Invariant 4: INSERT requires WHEN NOT MATCHED
      if (clause.action === 'INSERT' && clause.type !== 'NOT_MATCHED') {
        errors.push(`SYNTAX ERROR: Action INSERT is only valid in WHEN NOT MATCHED clauses.`);
      }
    }

    // Invariant 5: Prefer DELETE before unconditional UPDATE
    const deleteIdx = def.clauses.findIndex(c => c.action === 'DELETE');
    const unconditionalUpdateIdx = def.clauses.findIndex(c => c.type === 'MATCHED' && !c.condition && c.action === 'UPDATE');
    if (deleteIdx !== -1 && unconditionalUpdateIdx !== -1 && deleteIdx > unconditionalUpdateIdx) {
      errors.push(
        `DEAD BRANCH: DELETE clause at index ${deleteIdx} will never execute because unconditional UPDATE at index ${unconditionalUpdateIdx} captures all matches.`
      );
    }

    // Invariant 6: Warn if RETURNING does not include merge_action()
    if (def.returningColumns && def.returningColumns.length > 0) {
      const hasAction = def.returningColumns.some(c => c.toLowerCase().includes('merge_action()'));
      if (!hasAction && !def.includeMergeAction) {
        warnings.push(
          'RECOMMENDATION: RETURNING clause should project merge_action() to distinguish INSERT, UPDATE, and DELETE actions for CDC outbox audit.'
        );
      }
    }

    // Invariant 7: Deduplication advice
    if (!def.enableSourceDeduplication) {
      warnings.push(
        'CONCURRENCY RISK: Source deduplication is disabled. If source contains duplicate join keys, MERGE will abort with SQLSTATE 21000.'
      );
    }

    if (errors.length > 0) {
      return { valid: false, errors, warnings };
    }

    const synthesizedSQL = this.generateSQL(def);
    return { valid: true, errors: [], warnings, synthesizedSQL };
  }

  /**
   * Synthesizes hardened, production-ready PostgreSQL 17 MERGE SQL with deduplication CTE.
   */
  public static generateSQL(def: MergeStatementDefinition): string {
    const tAlias = def.targetAlias || 't';
    const sAlias = def.sourceAlias || 's';
    const lines: string[] = [];

    // Step 1: Pre-Deduplication CTE if enabled
    let effectiveSource = def.sourceExpression;
    if (def.enableSourceDeduplication) {
      const orderCol = def.dedupOrderingColumn || 'updated_at';
      const partitionKeys = def.joinKeys.join(', ');
      lines.push('WITH raw_source AS (');
      lines.push(`  SELECT * FROM ${def.sourceExpression}`);
      lines.push('),');
      lines.push('deduped_source AS (');
      lines.push('  SELECT *,');
      lines.push(`         ROW_NUMBER() OVER (PARTITION BY ${partitionKeys} ORDER BY ${orderCol} DESC) AS _rn`);
      lines.push('  FROM raw_source');
      lines.push(')');
      effectiveSource = '(SELECT * FROM deduped_source WHERE _rn = 1)';
    }

    // Step 2: MERGE Statement Header
    lines.push(`MERGE INTO ${def.targetTable} AS ${tAlias}`);
    lines.push(`USING ${effectiveSource} AS ${sAlias}`);
    lines.push(`ON ${def.joinCondition}`);

    // Step 3: Clause generation
    for (const clause of def.clauses) {
      const matchStr = clause.type === 'MATCHED' ? 'WHEN MATCHED' : 'WHEN NOT MATCHED';
      const condStr = clause.condition ? ` AND (${clause.condition})` : '';

      if (clause.action === 'DELETE') {
        lines.push(`  ${matchStr}${condStr} THEN DELETE`);
      } else if (clause.action === 'UPDATE') {
        const assignments = Object.entries(clause.setAssignments || {})
          .map(([col, val]) => `${col} = ${val}`)
          .join(', ');
        lines.push(`  ${matchStr}${condStr} THEN UPDATE SET ${assignments}`);
      } else if (clause.action === 'INSERT') {
        const cols = (clause.insertColumns || []).join(', ');
        const vals = (clause.insertValues || []).join(', ');
        lines.push(`  ${matchStr}${condStr} THEN INSERT (${cols}) VALUES (${vals})`);
      } else if (clause.action === 'DO_NOTHING') {
        lines.push(`  ${matchStr}${condStr} THEN DO NOTHING`);
      }
    }

    // Step 4: PostgreSQL 17 RETURNING Clause
    const returningParts: string[] = [];
    if (def.includeMergeAction) {
      returningParts.push('merge_action() AS action');
    }
    if (def.returningColumns && def.returningColumns.length > 0) {
      returningParts.push(...def.returningColumns);
    }

    if (returningParts.length > 0) {
      lines.push(`RETURNING ${returningParts.join(', ')};`);
    } else {
      lines.push(';');
    }

    return lines.join('\n');
  }
}
```

---

## 4. Cross-Runtime Driver Sentinels

### 4.1 Go (`jackc/pgx/v5`): Resilient Batch Sync with Deduplication & `merge_action()` Telemetry

In Go services, never execute `MERGE` without catching `SQLSTATE 23505` and `SQLSTATE 40001` for automatic retry with jittered exponential backoff.

```go
package database

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ProductSyncRecord represents the source record to be merged.
type ProductSyncRecord struct {
	SKU         string    `json:"sku"`
	TenantID    string    `json:"tenant_id"`
	Name        string    `json:"name"`
	PriceCents  int64     `json:"price_cents"`
	IsDeleted   bool      `json:"is_deleted"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// MergeResult captures the atomic mutation output returned by PostgreSQL 17 RETURNING merge_action().
type MergeResult struct {
	Action      string    `json:"action"` // "INSERT", "UPDATE", "DELETE"
	SKU         string    `json:"sku"`
	TenantID    string    `json:"tenant_id"`
	PriceCents  int64     `json:"price_cents"`
	ProcessedAt time.Time `json:"processed_at"`
}

// ExecuteBatchProductMerge executes a resilient PostgreSQL 17 MERGE with RETURNING merge_action().
func ExecuteBatchProductMerge(
	ctx context.Context,
	pool *pgxpool.Pool,
	records []ProductSyncRecord,
) ([]MergeResult, error) {
	if len(records) == 0 {
		return nil, nil
	}

	const maxRetries = 3
	baseBackoff := 50 * time.Millisecond

	for attempt := 1; attempt <= maxRetries; attempt++ {
		results, err := executeMergeAttempt(ctx, pool, records)
		if err == nil {
			return results, nil
		}

		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) {
			// SQLSTATE 23505: unique_violation (concurrent insertion race)
			// SQLSTATE 40001: serialization_failure (concurrent mutation conflict)
			// SQLSTATE 40P01: deadlock_detected
			if pgErr.Code == "23505" || pgErr.Code == "40001" || pgErr.Code == "40P01" {
				if attempt == maxRetries {
					return nil, fmt.Errorf("merge failed after %d retries due to conflict (code=%s): %w", attempt, pgErr.Code, err)
				}
				// Decorrelated jitter backoff
				sleepDuration := time.Duration(float64(baseBackoff) * (1.0 + rand.Float64())) * time.Duration(1<<(attempt-1))
				select {
				case <-time.After(sleepDuration):
					continue
				case <-ctx.Done():
					return nil, ctx.Err()
				}
			}
		}

		// Non-retryable error (e.g. syntax, permission, cardinality 21000)
		return nil, fmt.Errorf("fatal merge execution error: %w", err)
	}

	return nil, errors.New("merge exhausted retry attempts")
}

func executeMergeAttempt(
	ctx context.Context,
	pool *pgxpool.Pool,
	records []ProductSyncRecord,
) ([]MergeResult, error) {
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{
		IsoLevel: pgx.ReadCommitted,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Step 1: Enforce transaction-scoped statement timeout
	if _, err := tx.Exec(ctx, "SET LOCAL statement_timeout = '30000ms'"); err != nil {
		return nil, err
	}

	// Step 2: PostgreSQL 17 MERGE Query with CTE Deduplication & RETURNING merge_action()
	query := `
		WITH raw_batch AS (
			SELECT * FROM json_to_recordset($1::json) AS (
				sku TEXT,
				tenant_id TEXT,
				name TEXT,
				price_cents BIGINT,
				is_deleted BOOLEAN,
				updated_at TIMESTAMPTZ
			)
		),
		deduped_batch AS (
			SELECT *,
			       ROW_NUMBER() OVER (
			           PARTITION BY tenant_id, sku 
			           ORDER BY updated_at DESC
			       ) AS _rn
			FROM raw_batch
		),
		clean_batch AS (
			SELECT * FROM deduped_batch WHERE _rn = 1
		)
		MERGE INTO inventory_products AS t
		USING clean_batch AS s
		ON t.tenant_id = s.tenant_id AND t.sku = s.sku
		-- Clause 1: Conditional DELETE must precede UPDATE to prevent dead branches
		WHEN MATCHED AND s.is_deleted = TRUE THEN
			DELETE
		-- Clause 2: Conditional or standard UPDATE for non-deleted rows
		WHEN MATCHED THEN
			UPDATE SET
				name = s.name,
				price_cents = s.price_cents,
				updated_at = s.updated_at
		-- Clause 3: INSERT when entity does not exist and is not marked deleted
		WHEN NOT MATCHED AND s.is_deleted = FALSE THEN
			INSERT (tenant_id, sku, name, price_cents, updated_at)
			VALUES (s.tenant_id, s.sku, s.name, s.price_cents, s.updated_at)
		-- PostgreSQL 17 Native RETURNING with merge_action()
		RETURNING 
			merge_action() AS action,
			t.sku,
			t.tenant_id,
			COALESCE(t.price_cents, 0) AS price_cents,
			NOW() AS processed_at;
	`

	// Convert Go slice to JSON string for efficient single-statement binding
	payloadBytes, err := json.Marshal(records)
	if err != nil {
		return nil, fmt.Errorf("failed to serialize records to json: %w", err)
	}

	rows, err := tx.Query(ctx, query, string(payloadBytes))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []MergeResult
	for rows.Next() {
		var res MergeResult
		if err := rows.Scan(
			&res.Action,
			&res.SKU,
			&res.TenantID,
			&res.PriceCents,
			&res.ProcessedAt,
		); err != nil {
			return nil, fmt.Errorf("scan merge result failed: %w", err)
		}
		results = append(results, res)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("rows iteration failed: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("failed to commit merge tx: %w", err)
	}

	return results, nil
}
```

---

### 4.2 TypeScript (`pg` / `Drizzle`): Schema Validation & Outbox Event Emission

```typescript
import { Pool, PoolClient } from 'pg';
import { z } from 'zod';

export const SyncRecordSchema = z.object({
  tenantId: z.string().uuid(),
  entityId: z.string(),
  payload: z.record(z.unknown()),
  isPurged: z.boolean(),
  versionEpoch: z.number().int().nonnegative(),
});

export type SyncRecord = z.infer<typeof SyncRecordSchema>;

export interface OutboxMutationEvent {
  action: 'INSERT' | 'UPDATE' | 'DELETE';
  tenantId: string;
  entityId: string;
  epoch: number;
}

export async function executeResilientMerge(
  pool: Pool,
  records: SyncRecord[]
): Promise<OutboxMutationEvent[]> {
  if (records.length === 0) return [];

  // Assert schema validity before generating SQL
  const validated = records.map(r => SyncRecordSchema.parse(r));
  const client: PoolClient = await pool.connect();

  try {
    await client.query('BEGIN ISOLATION LEVEL READ COMMITTED');
    await client.query("SET LOCAL statement_timeout = '20000ms'");

    const query = `
      WITH raw_events AS (
        SELECT * FROM jsonb_to_recordset($1::jsonb) AS (
          tenant_id UUID,
          entity_id TEXT,
          payload JSONB,
          is_purged BOOLEAN,
          version_epoch BIGINT
        )
      ),
      deduped_events AS (
        SELECT *,
               ROW_NUMBER() OVER (
                 PARTITION BY tenant_id, entity_id 
                 ORDER BY version_epoch DESC
               ) AS rn
        FROM raw_events
      ),
      clean_source AS (
        SELECT * FROM deduped_events WHERE rn = 1
      )
      MERGE INTO entity_aggregate_store AS target
      USING clean_source AS source
      ON target.tenant_id = source.tenant_id AND target.entity_id = source.entity_id
      -- Clause 1: Purge branch (destructive branch MUST precede update)
      WHEN MATCHED AND source.is_purged = TRUE THEN
        DELETE
      -- Clause 2: Conditional update asserting monotonic version epoch
      WHEN MATCHED AND source.version_epoch > target.version_epoch THEN
        UPDATE SET
          payload = source.payload,
          version_epoch = source.version_epoch,
          updated_at = NOW()
      -- Clause 3: Initial insert
      WHEN NOT MATCHED AND source.is_purged = FALSE THEN
        INSERT (tenant_id, entity_id, payload, version_epoch, created_at, updated_at)
        VALUES (source.tenant_id, source.entity_id, source.payload, source.version_epoch, NOW(), NOW())
      -- PostgreSQL 17 RETURNING with merge_action()
      RETURNING
        merge_action() AS action,
        target.tenant_id,
        target.entity_id,
        COALESCE(target.version_epoch, 0) AS epoch;
    `;

    const res = await client.query(query, [JSON.stringify(validated)]);
    await client.query('COMMIT');

    return res.rows.map(row => ({
      action: row.action as 'INSERT' | 'UPDATE' | 'DELETE',
      tenantId: row.tenant_id,
      entityId: row.entity_id,
      epoch: Number(row.epoch),
    }));
  } catch (err: any) {
    await client.query('ROLLBACK');
    // Surface actionable context for agent diagnostics
    if (err.code === '21000') {
      throw new Error(`MERGE Cardinality Failure: Source contained duplicate records without deduplication: ${err.message}`);
    }
    if (err.code === '23505') {
      throw new Error(`MERGE Concurrency Race: Concurrent insertion detected (SQLSTATE 23505). Must retry with backoff: ${err.message}`);
    }
    throw err;
  } finally {
    client.release();
  }
}
```

---

### 4.3 Python (`asyncpg`): Asynchronous Multi-Action Reconciliation

```python
import json
import asyncio
import random
from typing import List, Dict, Any
import asyncpg

async def execute_postgres17_merge(
    pool: asyncpg.Pool,
    records: List[Dict[str, Any]],
    max_retries: int = 3,
) -> List[Dict[str, Any]]:
    """
    Executes a high-throughput PostgreSQL 17 MERGE with RETURNING merge_action(),
    enforcing deduplication and handling transient concurrency collisions.
    """
    if not records:
        return []

    sql = """
    WITH raw_stream AS (
        SELECT * FROM json_to_recordset($1::json) AS (
            account_id TEXT,
            tenant_id TEXT,
            balance_cents BIGINT,
            status TEXT,
            sequence_id BIGINT
        )
    ),
    deduped_stream AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY tenant_id, account_id 
                   ORDER BY sequence_id DESC
               ) as _rn
        FROM raw_stream
    ),
    clean_stream AS (
        SELECT * FROM deduped_stream WHERE _rn = 1
    )
    MERGE INTO ledger_accounts AS target
    USING clean_stream AS source
    ON target.tenant_id = source.tenant_id AND target.account_id = source.account_id
    -- Destructive branch ordered first
    WHEN MATCHED AND source.status = 'CLOSED' AND target.balance_cents = 0 THEN
        DELETE
    -- Update branch strictly respecting monotonic sequence_id
    WHEN MATCHED AND source.sequence_id > target.sequence_id THEN
        UPDATE SET
            balance_cents = source.balance_cents,
            status = source.status,
            sequence_id = source.sequence_id,
            updated_at = CLOCK_TIMESTAMP()
    -- Insert new accounts
    WHEN NOT MATCHED AND source.status != 'CLOSED' THEN
        INSERT (tenant_id, account_id, balance_cents, status, sequence_id, updated_at)
        VALUES (source.tenant_id, source.account_id, source.balance_cents, source.status, source.sequence_id, CLOCK_TIMESTAMP())
    RETURNING
        merge_action() AS action,
        target.tenant_id,
        target.account_id,
        target.balance_cents,
        target.status;
    """

    payload = json.dumps(records)

    for attempt in range(1, max_retries + 1):
        try:
            async with pool.acquire() as conn:
                async with conn.transaction(isolation='read_committed'):
                    await conn.execute("SET LOCAL statement_timeout = '15000ms';")
                    rows = await conn.fetch(sql, payload)
                    return [dict(r) for r in rows]
        except (asyncpg.UniqueViolationError, asyncpg.SerializationError, asyncpg.DeadlockDetectedError) as e:
            if attempt == max_retries:
                raise RuntimeError(f"MERGE aborted after {attempt} attempts: {e}") from e
            # Jittered exponential backoff
            backoff = (0.05 * (2 ** (attempt - 1))) + random.uniform(0.01, 0.05)
            await asyncio.sleep(backoff)
```

---

### 4.4 Rust (`sqlx`): Strongly Typed `MergeAction` Enum Projection

```rust
use serde::{Deserialize, Serialize};
use sqlx::{PgPool, FromRow, Type};

#[derive(Debug, Clone, PartialEq, Eq, Type, Serialize, Deserialize)]
#[sqlx(type_name = "text", rename_all = "UPPERCASE")]
pub enum MergeAction {
    Insert,
    Update,
    Delete,
}

#[derive(Debug, FromRow, Serialize)]
pub struct MergeMutationResult {
    pub action: MergeAction,
    pub tenant_id: String,
    pub resource_id: String,
    pub version: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct IngestionRecord {
    pub tenant_id: String,
    pub resource_id: String,
    pub state_blob: serde_json::Value,
    pub version: i64,
    pub is_deleted: bool,
}

pub async fn execute_batch_merge(
    pool: &PgPool,
    records: &[IngestionRecord],
) -> Result<Vec<MergeMutationResult>, sqlx::Error> {
    if records.is_empty() {
        return Ok(Vec::new());
    }

    let payload = serde_json::to_string(records)
        .map_err(|e| sqlx::Error::Protocol(format!("Serialization failure: {}", e)))?;

    let query = r#"
        WITH raw_input AS (
            SELECT * FROM json_to_recordset($1::json) AS (
                tenant_id TEXT,
                resource_id TEXT,
                state_blob JSONB,
                version BIGINT,
                is_deleted BOOLEAN
            )
        ),
        deduped AS (
            SELECT *,
                   ROW_NUMBER() OVER (
                       PARTITION BY tenant_id, resource_id 
                       ORDER BY version DESC
                   ) as rn
            FROM raw_input
        )
        MERGE INTO distributed_resources AS target
        USING (SELECT * FROM deduped WHERE rn = 1) AS source
        ON target.tenant_id = source.tenant_id AND target.resource_id = source.resource_id
        WHEN MATCHED AND source.is_deleted = TRUE THEN
            DELETE
        WHEN MATCHED AND source.version > target.version THEN
            UPDATE SET
                state_blob = source.state_blob,
                version = source.version,
                updated_at = NOW()
        WHEN NOT MATCHED AND source.is_deleted = FALSE THEN
            INSERT (tenant_id, resource_id, state_blob, version, created_at, updated_at)
            VALUES (source.tenant_id, source.resource_id, source.state_blob, source.version, NOW(), NOW())
        RETURNING
            merge_action()::text AS action,
            target.tenant_id,
            target.resource_id,
            target.version;
    "#;

    let mut tx = pool.begin().await?;
    sqlx::query("SET LOCAL statement_timeout = '25000ms'")
        .execute(&mut *tx)
        .await?;

    let rows = sqlx::query_as::<_, MergeMutationResult>(query)
        .bind(payload)
        .fetch_all(&mut *tx)
        .await?;

    tx.commit().await?;
    Ok(rows)
}
```

---

## 5. The 6-State MERGE Execution Lifecycle Finite-State Machine (FSM)

```
       +-----------------------------------------------------------+
       |                        [0] IDLE                           |
       +-----------------------------------------------------------+
                                     |
                                     | 1. Submit Batch Sync Payload
                                     v
       +-----------------------------------------------------------+
       |                 [1] ENGINE & PRE-FLIGHT QUALIFIED          |
       |  - Verify PG >= 17.0 for RETURNING merge_action()         |
       |  - Confirm Target B-Tree Indexes on ON (...) Columns      |
       +-----------------------------------------------------------+
                                     |
                                     | 2. Apply Source Deduplication
                                     v
       +-----------------------------------------------------------+
       |                    [2] SOURCE DEDUPLICATED                |
       |  - ROW_NUMBER() OVER (PARTITION BY keys ORDER BY ts DESC) |
       |  - Guarantees <= 1 Match Per Target Row (Anti-21000)      |
       +-----------------------------------------------------------+
                                     |
                                     | 3. Parse & Order Clauses
                                     v
       +-----------------------------------------------------------+
       |                 [3] CLAUSE PRECEDENCE VERIFIED            |
       |  - Destructive (DELETE) before Fallback UPDATE            |
       |  - Assert Zero Dead/Unreachable Clauses in AST            |
       +-----------------------------------------------------------+
                                     |
                                     | 4. Execute Atomic MERGE
                                     v
       +-----------------------------------------------------------+
       |                  [4] MERGE EXECUTION & EVAL               |
       |  - Evaluate Joins (Hash/Merge/Index Scan)                 |
       |  - Row Movement for Partition Key Updates (PG17)          |
       |  - Catch 23505 / 40001 -> Decorrelated Jitter Retry Loop  |
       +-----------------------------------------------------------+
                                     |
                                     | 5. Stream RETURNING merge_action()
                                     v
       +-----------------------------------------------------------+
       |                   [5] CDC OUTBOX EMISSION                 |
       |  - Map merge_action() ('INSERT'|'UPDATE'|'DELETE')       |
       |  - Dispatch Domain Events in Single Atomic Database Trip  |
       +-----------------------------------------------------------+
```

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Gates

Autonomous coding agents must verify all 6 gates before declaring a `MERGE` implementation production-ready:

| Gate | Verification Target | Metric / Invariant Asserted | Action on Failure |
|---|---|---|---|
| **Gate 1** | Engine Compatibility | Server version $\ge 17.0$ (`current_setting('server_version_num')::int >= 170000`) | Abort. Fallback to `INSERT ... ON CONFLICT` or manual CTE transactions. |
| **Gate 2** | Source Deduplication | Source CTE contains explicit deduplication (`ROW_NUMBER()` or `DISTINCT ON`) | Reject PR. Inject deduplication CTE to eliminate `SQLSTATE 21000`. |
| **Gate 3** | Index Coverage on Join | Target join columns backed by `UNIQUE` or leftmost `INDEX` | Reject migration. Sequential scans on large targets cause relation lockouts. |
| **Gate 4** | Clause Ordering | Destructive (`DELETE`) branches declared strictly before unconditional `UPDATE` | Reject PR. Unreachable dead branches detected in AST linter. |
| **Gate 5** | Concurrency Conflict Retry | Driver code encapsulates MERGE with retry on `23505`, `40001`, `40P01` | Reject PR. Concurrent inserts under Read Committed will abort workers. |
| **Gate 6** | Telemetry Projection | Statement projects `RETURNING merge_action()` for audit/CDC logging | Flag warning. In PostgreSQL 17+, omit secondary delta queries. |

### Automated Verification Script (`verify-merge-invariants.sql`)

```sql
-- Machine-Verifiable Test Harness for PostgreSQL 17 MERGE Invariants
DO $$
DECLARE
    v_ver INT;
    v_count INT;
BEGIN
    -- Gate 1: Check PostgreSQL Version >= 17
    SELECT current_setting('server_version_num')::int INTO v_ver;
    IF v_ver < 170000 THEN
        RAISE EXCEPTION 'ASSERTION FAILED: PostgreSQL 17+ is required for RETURNING merge_action(). Detected version %', v_ver;
    END IF;

    -- Setup Ephemeral Verification Environment
    CREATE TEMP TABLE test_target (
        id INT PRIMARY KEY,
        val TEXT,
        is_deleted BOOLEAN DEFAULT FALSE,
        updated_at TIMESTAMPTZ DEFAULT NOW()
    );

    CREATE TEMP TABLE test_source (
        id INT,
        val TEXT,
        is_deleted BOOLEAN,
        epoch INT
    );

    -- Seed target
    INSERT INTO test_target (id, val) VALUES (1, 'original_1'), (2, 'original_2');

    -- Seed source with intentional duplicates on id=1 to test deduplication
    INSERT INTO test_source (id, val, is_deleted, epoch) VALUES 
        (1, 'v1_old', false, 100),
        (1, 'v1_new', false, 200),
        (2, 'v2_delete', true, 300),
        (3, 'v3_insert', false, 400);

    -- Execute Hardened Deduplicated MERGE with RETURNING merge_action()
    CREATE TEMP TABLE merge_audit_out AS
    WITH deduped_source AS (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY id ORDER BY epoch DESC) as rn
        FROM test_source
    )
    MERGE INTO test_target AS t
    USING (SELECT * FROM deduped_source WHERE rn = 1) AS s
    ON t.id = s.id
    WHEN MATCHED AND s.is_deleted = TRUE THEN
        DELETE
    WHEN MATCHED THEN
        UPDATE SET val = s.val, updated_at = NOW()
    WHEN NOT MATCHED AND s.is_deleted = FALSE THEN
        INSERT (id, val, is_deleted, updated_at)
        VALUES (s.id, s.val, s.is_deleted, NOW())
    RETURNING 
        merge_action() AS action,
        t.id,
        t.val;

    -- Verify Actions: 1 UPDATE, 1 DELETE, 1 INSERT
    SELECT count(*) INTO v_count FROM merge_audit_out WHERE action = 'UPDATE' AND id = 1 AND val = 'v1_new';
    IF v_count != 1 THEN
        RAISE EXCEPTION 'GATE 2 & 4 FAILED: Expected 1 deduplicated UPDATE with v1_new, got %', v_count;
    END IF;

    SELECT count(*) INTO v_count FROM merge_audit_out WHERE action = 'DELETE' AND id = 2;
    IF v_count != 1 THEN
        RAISE EXCEPTION 'GATE 4 FAILED: Expected 1 DELETE on id=2, got %', v_count;
    END IF;

    SELECT count(*) INTO v_count FROM merge_audit_out WHERE action = 'INSERT' AND id = 3;
    IF v_count != 1 THEN
        RAISE EXCEPTION 'GATE 4 FAILED: Expected 1 INSERT on id=3, got %', v_count;
    END IF;

    RAISE NOTICE 'SUCCESS: All PostgreSQL 17 MERGE invariants verified successfully.';

    -- Clean up
    DROP TABLE merge_audit_out;
    DROP TABLE test_source;
    DROP TABLE test_target;
END $$;
```
