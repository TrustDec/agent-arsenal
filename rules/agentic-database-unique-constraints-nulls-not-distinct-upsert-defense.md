---
description: Database unique constraints, NULLS NOT DISTINCT (PostgreSQL 15+), partial unique indexes for soft-deleted tables, atomic UPSERTs (ON CONFLICT DO UPDATE/NOTHING), case-insensitive expression indexes, and zero-downtime concurrent migration across Go (pgx/v5), TypeScript (Drizzle/Prisma/Kysely), Python (SQLAlchemy), Rust (sqlx), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{unique,upsert,conflict,constraint,index,schema,migration,model,entity}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/models/**/*.{ts,js,go,rs,py},**/src/entities/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Unique Constraints, NULLS NOT DISTINCT, Partial Unique Indexes, Atomic UPSERTs & Duplicate Race Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design relational database schemas, uniqueness invariants, upsert pipelines, migration scripts, or multi-tenant isolation layers across PostgreSQL, MySQL/InnoDB, SQLite, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Prisma`, `Kysely`, `TypeORM`), Python (`SQLAlchemy`), or Rust (`sqlx`). Eliminate the "Check-Then-Insert Race Condition & `SQLSTATE 23505` Collision Outage" (where agents naively query `SELECT id FROM table WHERE key = $1` followed by `INSERT INTO table ...`, creating critical race windows under concurrent API calls, webhooks, or parallel workers where duplicate keys crash downstream transactions with 500 errors and unhandled exceptions), the "ANSI SQL-92 NULL Bypass Illusion & Missing `NULLS NOT DISTINCT`" (where SQL standard `NULL != NULL` semantics allow an infinite number of duplicate rows with `(tenant_id, NULL)` under composite unique constraints, silently violating 1:1 business rules), the "Soft-Delete Unique Constraint Deadlock Trap" (where tables using `deleted_at TIMESTAMPTZ` have a monolithic `UNIQUE (tenant_id, email)` constraint that permanently blocks soft-deleted users from re-registering or being re-invited), the "Case-Insensitive String Uniqueness & Expression Index Blindness Trap" (where raw `UNIQUE(email)` permits `Alice@corp.com` alongside `alice@corp.com`, introducing account takeover vulnerabilities, impersonation, and fractured billing records), the "Naive `ON CONFLICT DO UPDATE` Deadlock Storm & MVCC Churn Trap" (where multi-row batch upserts executed in non-deterministic order trigger cyclic row-lock deadlocks `SQLSTATE 40P01`, and unguarded updates overwrite identical data, causing catastrophic dead tuple bloat and de-optimizing Heap-Only Tuple HOT updates), and the "Synchronous `ALTER TABLE ADD CONSTRAINT UNIQUE` Table-Lockout Disaster" (where direct unique constraint creation grabs `ACCESS EXCLUSIVE` table locks for minutes or hours, halting all concurrent read and write queries) by establishing a strict 5-Tier Unique Constraint & Upsert Governance Ladder, mathematical collision models, atomic upsert patterns with HOT churn guards, and machine-verifiable CI test gates.

---

## 1. Architectural Taxonomy: The 6 Unique Constraint Catastrophes vs The 5-Tier Governance Ladder

Relational databases guarantee declarative data integrity at the storage layer. However, autonomous coding agents frequently attempt to enforce uniqueness in application memory or generate naive SQL statements that collapse under high concurrency:

```typescript
// ❌ CATASTROPHIC LLM UNIQUE CONSTRAINT & UPSERT ANTI-PATTERNS

// 1. The Check-Then-Insert Race Condition!
// Autonomous agent attempts to enforce uniqueness via application-level check:
export async function registerUser(email: string, name: string) {
  const existing = await db.query('SELECT id FROM users WHERE email = $1', [email]);
  if (!existing.rows.length) {
    // ❌ Critical race window! Concurrent requests both see zero rows and both execute INSERT!
    // The second request crashes with unhandled SQLSTATE 23505 (unique_violation)!
    await db.query('INSERT INTO users (email, name) VALUES ($1, $2)', [email, name]);
  }
}

// 2. The ANSI SQL-92 NULL Bypass Illusion!
// Standard SQL treats every NULL as distinct (NULL != NULL).
// LLM declares composite unique constraint on nullable column:
// ALTER TABLE tenant_integrations ADD CONSTRAINT uq_provider UNIQUE (tenant_id, integration_code);
// ❌ If integration_code is NULL, Postgres permits 10,000 duplicate rows for the same tenant_id!
// Corrupts multi-tenant 1:1 cardinality and triggers downstream "Expected 1 row, got 8" crashes!

// 3. The Soft-Delete Unique Constraint Re-registration Wall!
// Table uses soft deletes (deleted_at TIMESTAMPTZ).
// LLM adds table-level unique constraint:
// ALTER TABLE users ADD CONSTRAINT uq_user_email UNIQUE (tenant_id, email);
// ❌ User is soft-deleted (deleted_at = NOW()). When user re-registers or is re-invited,
// INSERT crashes with SQLSTATE 23505! The user is permanently locked out!

// 4. The Case-Insensitive Impersonation Hole!
// LLM creates raw unique constraint on string field:
// CREATE TABLE accounts (id UUID PRIMARY KEY, username VARCHAR(50) UNIQUE);
// ❌ Allows 'JohnDoe' and 'johndoe' to co-exist! Enables account impersonation and routing bugs!

// 5. Naive ON CONFLICT Multi-Row Batch Deadlock & MVCC Bloat!
// INSERT INTO inventory (item_id, warehouse_id, qty) VALUES ...
// ON CONFLICT (item_id, warehouse_id) DO UPDATE SET qty = EXCLUDED.qty, updated_at = NOW();
// ❌ Issue A: Unordered concurrent batches lock rows in arbitrary orders -> SQLSTATE 40P01 Deadlock!
// ❌ Issue B: Every upsert creates a new dead tuple even when qty didn't change -> MVCC heap explosion!
```

| Governance Tier | Architectural Responsibility | Concrete Production Invariant |
| :--- | :--- | :--- |
| **Tier 0: Atomic Upsert Invariance & Canonical Sorting** | Eradicate Check-Then-Insert Races & Deadlocks | Eradicate application `SELECT ... IF NOT EXISTS INSERT`. Enforce atomic `INSERT ... ON CONFLICT (key) DO UPDATE / DO NOTHING`. Canonical lexicographical sorting on multi-row batches before sending to database. |
| **Tier 1: Partial Unique Indexes for Soft-Deleted Tables** | Zero Re-registration Lockouts on Soft Deletes | For tables with `deleted_at`, forbid table-level `UNIQUE`. Enforce partial B-Tree unique indexes: `CREATE UNIQUE INDEX ... WHERE deleted_at IS NULL`. |
| **Tier 2: Explicit NULL Uniqueness (`NULLS NOT DISTINCT`)** | Eliminate ANSI NULL Bypass Multi-Tenant Leaks | On PostgreSQL 15+, explicitly declare `UNIQUE NULLS NOT DISTINCT (tenant_id, nullable_col)`. On older engines, use dual partial unique indexes or surrogate coalesce sentinels. |
| **Tier 3: Case-Insensitive Functional Expression Indexing** | Eradicate Impersonation & Casing Split-Brain | Enforce functional unique indexes on normalized strings: `CREATE UNIQUE INDEX ... ON users (tenant_id, LOWER(TRIM(email)))`. |
| **Tier 4: Zero-Downtime Concurrent Migration & HOT Preservation** | Zero Lockouts & Zero MVCC Dead-Tuple Bloat | New unique constraints MUST use 2-phase migration (`CREATE UNIQUE INDEX CONCURRENTLY` $\to$ `ALTER TABLE ... ADD CONSTRAINT ... USING INDEX`). Guard all `DO UPDATE` statements with `WHERE target IS DISTINCT FROM EXCLUDED.target`. |

---

## 2. Mathematical Formalism: Race Probabilities, Lock Queues & MVCC Bloat Differential

### 2.1 Check-Then-Insert Race Condition Probability Model
Let arrivals of requests attempting to insert or claim the same unique resource (e.g. user signup, idempotency key, webhook event) follow a Poisson process with arrival rate $\lambda$ (requests per second). Let $\Delta t$ be the execution time window between the application issuing `SELECT` and the subsequent `INSERT` committing on the database:

$$\Delta t = t_{\text{select\_rtt}} + t_{\text{app\_processing}} + t_{\text{insert\_rtt}}$$

The probability $P(\text{Collision})$ that at least one concurrent request enters the critical race window during $\Delta t$ and triggers a `SQLSTATE 23505 unique_violation` crash is:

$$P(\text{Collision}) = 1 - e^{-\lambda \Delta t}$$

**Empirical Example**: Under moderate webhook arrival burstiness of $\lambda = 50 \text{ req/sec}$ and a standard network round-trip time $\Delta t = 20\text{ ms} = 0.020\text{ s}$:

$$P(\text{Collision}) = 1 - e^{-50 \times 0.020} = 1 - e^{-1.0} \approx 63.2\%$$

Over $63\%$ of concurrent requests under check-then-insert crash. Under atomic `INSERT ... ON CONFLICT`, database row locks serialize the operation within the kernel:

$$P(\text{Collision})_{\text{Atomic UPSERT}} \equiv 0\%$$

### 2.2 Lock Contention Differential: Synchronous DDL vs Concurrent 2-Phase Migration
When executing a naive synchronous unique constraint migration:
$$\text{DDL: } \texttt{ALTER TABLE users ADD CONSTRAINT uq\_email UNIQUE (email);}$$
The engine requires an `ACCESS EXCLUSIVE` lock on `users` for the entire duration of the table scan and B-tree index generation:
$$t_{\text{lock\_sync}} = \frac{N_{\text{rows}}}{R_{\text{index\_build\_rate}}} + t_{\text{validation}}$$

For a table with $N_{\text{rows}} = 20,000,000$ rows, building an index at $50,000 \text{ rows/sec}$ requires $t_{\text{lock\_sync}} \approx 400 \text{ seconds}$. Under an incoming query arrival rate of $\lambda = 2,000 \text{ req/sec}$, the queued blocked transactions $Q_{\text{blocked}}$ is:
$$Q_{\text{blocked}} = \lambda \times t_{\text{lock\_sync}} = 2,000 \times 400 = 800,000 \text{ transactions}$$

This exhausts `max_connections` (e.g., 200–500) within 250 milliseconds, terminating the database cluster with cascade connection dropouts.

Under the 2-phase online migration protocol:
- **Phase 1**: `CREATE UNIQUE INDEX CONCURRENTLY idx_email ON users (email);` acquires only `SHARE UPDATE EXCLUSIVE` lock. Concurrent `SELECT`, `INSERT`, `UPDATE`, and `DELETE` execute unimpeded:
  $$t_{\text{blocked\_traffic}} = 0 \text{ ms}$$
- **Phase 2**: `ALTER TABLE users ADD CONSTRAINT uq_email UNIQUE USING INDEX idx_email;` acquires `ACCESS EXCLUSIVE` strictly to update the `pg_constraint` catalog dictionary:
  $$t_{\text{lock\_metadata}} \le 2 \text{ ms}$$
  $$Q_{\text{blocked}} = 2,000 \times 0.002 = 4 \text{ transactions}$$

Traffic blockage is reduced by $99.9995\%$.

### 2.3 MVCC Write Amplification Differential in High-Frequency UPSERTs
When an upsert executes `ON CONFLICT (id) DO UPDATE SET col1 = EXCLUDED.col1, updated_at = NOW();` unconditionally on every request, PostgreSQL creates a new heap tuple version (MVCC dead tuple) and marks the old version as dead, even if `col1` did not change.

Let $f_{\text{redundant}}$ be the fraction of upserts where data values remain identical (e.g. idempotent syncs, heartbeat updates, webhook retries, where typically $f_{\text{redundant}} \ge 85\%$). The write amplification factor $W_{\text{amp}}$ is:

$$W_{\text{amp\_naive}} = 1.0 \times (\text{Heap Tuple} + \sum \text{Index Pointers})$$

By applying the guarded clause:
$$\texttt{WHERE (users.col1) IS DISTINCT FROM (EXCLUDED.col1)}$$

The write amplification collapses to:
$$W_{\text{amp\_guarded}} = (1 - f_{\text{redundant}}) \times (\text{Heap Tuple} + \sum \text{Index Pointers}) + f_{\text{redundant}} \times 0$$

For $f_{\text{redundant}} = 90\%$, dead tuple generation, WAL disk traffic, and autovacuum load are reduced by $90.0\%$.

---

## 3. The 6-State Unique Constraint & Upsert Lifecycle Finite-State Machine (FSM)

Autonomous agents deploying unique constraints or upsert pipelines must transition through a strict, deterministic 6-state machine:

```
  ┌─────────────────────────────────────────────────────────┐
  │                 [1] DRAFT_SPECIFICATION                 │
  │     (Identify keys, NULL semantics & soft-delete rules) │
  └────────────────────────────┬────────────────────────────┘
                               │
                               ▼
  ┌─────────────────────────────────────────────────────────┐
  │              [2] DUPLICATE_SCRUB_AUDIT                  │
  │   (Run pre-flight GROUP BY query to detect collisions)  │
  └──────────────┬───────────────────────────┬──────────────┘
                 │ Collisions Found          │ Clean (0 duplicates)
                 ▼                           ▼
  ┌─────────────────────────────┐   ┌────────────────────────┐
  │ [3] REPAIR_DE_DUPLICATION   │   │ [4] CONCURRENT_INDEX   │
  │ (Execute deterministic CTID │   │ (CREATE UNIQUE INDEX   │
  │  tie-breaker deduplication) │   │  CONCURRENTLY)         │
  └──────────────┬──────────────┘   └───────────┬────────────┘
                 │                              │
                 └──────────────┬───────────────┘
                                │ Index Built Valid
                                ▼
  ┌─────────────────────────────────────────────────────────┐
  │           [5] METADATA_CONSTRAINT_ATTACH                │
  │  (SET lock_timeout = '2s'; ADD CONSTRAINT USING INDEX)  │
  └────────────────────────────┬────────────────────────────┘
                               │
                               ▼
  ┌─────────────────────────────────────────────────────────┐
  │          [6] ENFORCED_ATOMIC_UPSERT_ACTIVE              │
  │   (Canonical sorted batch writes + guarded DO UPDATE)   │
  └─────────────────────────────────────────────────────────┘
```

---

## 4. Production-Grade TypeScript Reference Implementation: `AgenticDatabaseUniqueConstraintEngine`

This self-contained TypeScript engine generates validated zero-downtime unique index migrations, produces guarded idempotent upsert SQL, enforces canonical batch sorting to prevent deadlocks, and provides automated health auditing:

```typescript
import { z } from 'zod';

export interface UniqueConstraintColumn {
  name: string;
  expression?: string; // e.g. "LOWER(TRIM(email))"
  order?: 'ASC' | 'DESC';
}

export interface UniqueConstraintConfig {
  tableName: string;
  constraintName: string;
  columns: UniqueConstraintColumn[];
  softDeleteColumn?: string; // e.g. "deleted_at"
  nullsNotDistinct?: boolean; // PostgreSQL 15+
  predicateWhere?: string; // Custom partial index predicate
}

export interface UpsertBatchRecord {
  [columnName: string]: unknown;
}

export interface UpsertConfig {
  tableName: string;
  conflictColumns: string[];
  partialIndexWhere?: string;
  updateColumns: string[];
  preserveOriginalColumns?: string[]; // Columns never overwritten on update (e.g. created_at)
}

export class AgenticDatabaseUniqueConstraintEngine {
  /**
   * Phase 1: Generates the pre-flight audit SQL query to detect existing duplicates
   * before attempting to build the unique index.
   */
  public generateDuplicateAuditQuery(config: UniqueConstraintConfig): string {
    const colExpressions = config.columns.map((c) => c.expression || `"${c.name}"`);
    const selectCols = colExpressions.join(', ');
    
    let whereClause = '';
    const conditions: string[] = [];
    if (config.softDeleteColumn) {
      conditions.push(`"${config.softDeleteColumn}" IS NULL`);
    }
    if (config.predicateWhere) {
      conditions.push(config.predicateWhere);
    }
    if (conditions.length > 0) {
      whereClause = `WHERE ${conditions.join(' AND ')}`;
    }

    return `
-- Step 1: Pre-flight Uniqueness Validation Audit
SELECT
  ${selectCols},
  COUNT(*) AS collision_count,
  ARRAY_AGG(ctid) AS collision_ctids
FROM "${config.tableName}"
${whereClause}
GROUP BY ${selectCols}
HAVING COUNT(*) > 1
ORDER BY collision_count DESC;
    `.trim();
  }

  /**
   * Phase 2: Generates the deterministic de-duplication script preserving
   * the latest record by created_at or ctid tie-breaker.
   */
  public generateDeduplicationCleanupSQL(config: UniqueConstraintConfig, orderingCol = 'created_at'): string {
    const colExpressions = config.columns.map((c) => c.expression || `"${c.name}"`).join(', ');
    let whereFilter = '';
    if (config.softDeleteColumn) {
      whereFilter = `AND "${config.softDeleteColumn}" IS NULL`;
    }

    return `
-- Step 2: Deterministic Deduplication Cleanup (Preserves newest record)
DELETE FROM "${config.tableName}"
WHERE ctid IN (
  SELECT ctid
  FROM (
    SELECT
      ctid,
      ROW_NUMBER() OVER (
        PARTITION BY ${colExpressions}
        ORDER BY "${orderingCol}" DESC, ctid DESC
      ) AS rnum
    FROM "${config.tableName}"
    WHERE 1=1 ${whereFilter}
  ) ranked
  WHERE ranked.rnum > 1
);
    `.trim();
  }

  /**
   * Phase 3: Generates the two-phase Zero-Downtime Migration script.
   * Phase A: Concurrent Index Build (non-blocking).
   * Phase B: Atomic metadata attach under bounded lock_timeout.
   */
  public generateZeroDowntimeMigration(config: UniqueConstraintConfig): {
    phase1CreateIndexConcurrently: string;
    phase2AttachConstraint: string;
  } {
    const colDefinitions = config.columns
      .map((c) => {
        const expr = c.expression || `"${c.name}"`;
        return c.order ? `${expr} ${c.order}` : expr;
      })
      .join(', ');

    const indexName = `idx_${config.tableName}_${config.constraintName}`;
    const nullsNotDistinctClause = config.nullsNotDistinct ? ' NULLS NOT DISTINCT' : '';

    const conditions: string[] = [];
    if (config.softDeleteColumn) {
      conditions.push(`"${config.softDeleteColumn}" IS NULL`);
    }
    if (config.predicateWhere) {
      conditions.push(config.predicateWhere);
    }
    const whereClause = conditions.length > 0 ? ` WHERE ${conditions.join(' AND ')}` : '';

    const phase1 = `
-- PHASE 1: Build Unique Index Concurrently (Non-blocking, SHARE UPDATE EXCLUSIVE)
-- Invariant: Must run OUTSIDE any transaction block!
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "${indexName}"
ON "${config.tableName}"${nullsNotDistinctClause} (${colDefinitions})${whereClause};
    `.trim();

    // Partial indexes cannot be promoted to formal table-level constraints in PostgreSQL,
    // so partial unique indexes remain as indexes (which enforce uniqueness identically).
    const isPartialIndex = conditions.length > 0;
    let phase2 = '';

    if (isPartialIndex) {
      phase2 = `
-- PHASE 2: Partial Index Verification
-- Note: Partial indexes enforce uniqueness at database level directly.
-- Verifying index validity:
SELECT
  c.relname AS index_name,
  i.indisvalid AS is_valid
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
WHERE c.relname = '${indexName}' AND i.indisvalid = true;
      `.trim();
    } else {
      phase2 = `
-- PHASE 2: Attach Index as Formal Table Constraint under Sub-Second lock_timeout
SET lock_timeout = '2s';
SET statement_timeout = '5s';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = '${config.constraintName}'
  ) THEN
    ALTER TABLE "${config.tableName}"
    ADD CONSTRAINT "${config.constraintName}"
    UNIQUE USING INDEX "${indexName}";
  END IF;
END $$;
      `.trim();
    }

    return { phase1CreateIndexConcurrently: phase1, phase2AttachConstraint: phase2 };
  }

  /**
   * Generates production-grade, atomic, deadlock-free UPSERT SQL
   * with HOT update optimization (WHERE IS DISTINCT FROM).
   */
  public generateGuardedUpsertSQL(config: UpsertConfig, batchSize: number): string {
    if (batchSize < 1) throw new Error('Batch size must be >= 1');

    const conflictTarget = config.conflictColumns.map((c) => `"${c}"`).join(', ');
    const partialWhere = config.partialIndexWhere ? ` WHERE ${config.partialIndexWhere}` : '';

    const allColumns = Array.from(
      new Set([...config.conflictColumns, ...config.updateColumns, ...(config.preserveOriginalColumns || [])])
    );

    // Build parameterized value placeholders ($1, $2, etc.)
    const valuePlaceholders: string[] = [];
    let paramIndex = 1;
    for (let r = 0; r < batchSize; r++) {
      const rowParams: string[] = [];
      for (let c = 0; c < allColumns.length; c++) {
        rowParams.push(`$${paramIndex++}`);
      }
      valuePlaceholders.push(`(${rowParams.join(', ')})`);
    }

    // Build guarded DO UPDATE SET clause with HOT dead-tuple prevention
    const updateClauses = config.updateColumns.map((col) => `"${col}" = EXCLUDED."${col}"`);
    updateClauses.push(`"updated_at" = clock_timestamp()`);

    const distinctChecks = config.updateColumns.map(
      (col) => `"${config.tableName}"."${col}" IS DISTINCT FROM EXCLUDED."${col}"`
    );

    return `
INSERT INTO "${config.tableName}" (${allColumns.map((c) => `"${c}"`).join(', ')})
VALUES
  ${valuePlaceholders.join(',\n  ')}
ON CONFLICT (${conflictTarget})${partialWhere}
DO UPDATE SET
  ${updateClauses.join(',\n  ')}
WHERE (
  ${distinctChecks.join(' OR\n  ')}
)
RETURNING *;
    `.trim();
  }

  /**
   * Sorts batch records canonically by conflict key before issuing SQL.
   * Mathematical Invariant: Prevents cyclic row-lock dependencies (SQLSTATE 40P01 Deadlocks).
   */
  public sortBatchDeterministically<T extends Record<string, unknown>>(
    records: T[],
    conflictKeys: (keyof T)[]
  ): T[] {
    return [...records].sort((a, b) => {
      for (const key of conflictKeys) {
        const valA = String(a[key] ?? '');
        const valB = String(b[key] ?? '');
        if (valA < valB) return -1;
        if (valA > valB) return 1;
      }
      return 0;
    });
  }
}
```

---

## 5. Cross-Language Production Patterns

### 5.1 Go (`jackc/pgx/v5`): Deadlock-Free Batch Upsert with Canonical Sorting & HOT Protection

```go
package store

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type InventoryRecord struct {
	WarehouseID string    `json:"warehouse_id"`
	SKU         string    `json:"sku"`
	Quantity    int64     `json:"quantity"`
	UpdatedAt   time.Time `json:"updated_at"`
}

type InventoryStore struct {
	pool *pgxpool.Pool
}

func NewInventoryStore(pool *pgxpool.Pool) *InventoryStore {
	return &InventoryStore{pool: pool}
}

// UpsertBatch performs an atomic, deadlock-free upsert on inventory items.
// Invariant 1: Sorts items canonically by (warehouse_id, sku) to eliminate SQLSTATE 40P01 deadlocks.
// Invariant 2: Uses WHERE inventory.quantity IS DISTINCT FROM EXCLUDED.quantity to retain HOT updates.
func (s *InventoryStore) UpsertBatch(ctx context.Context, items []InventoryRecord) error {
	if len(items) == 0 {
		return nil
	}

	// Step 1: Canonical Lexicographical Sorting (Cycles(G) = ∅)
	sortedItems := make([]InventoryRecord, len(items))
	copy(sortedItems, items)
	sort.Slice(sortedItems, func(i, j int) bool {
		if sortedItems[i].WarehouseID != sortedItems[j].WarehouseID {
			return sortedItems[i].WarehouseID < sortedItems[j].WarehouseID
		}
		return strings.ToLower(sortedItems[i].SKU) < strings.ToLower(sortedItems[j].SKU)
	})

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("failed to begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// Build batch query
	batch := &pgx.Batch{}
	query := `
		INSERT INTO inventory (warehouse_id, sku, quantity, updated_at)
		VALUES ($1, LOWER(TRIM($2)), $3, clock_timestamp())
		ON CONFLICT (warehouse_id, LOWER(TRIM(sku)))
		DO UPDATE SET
			quantity = EXCLUDED.quantity,
			updated_at = clock_timestamp()
		WHERE inventory.quantity IS DISTINCT FROM EXCLUDED.quantity
		RETURNING warehouse_id, sku, quantity, updated_at;
	`

	for _, item := range sortedItems {
		batch.Queue(query, item.WarehouseID, item.SKU, item.Quantity)
	}

	br := tx.SendBatch(ctx, batch)
	for i := 0; i < len(sortedItems); i++ {
		_, err := br.Exec()
		if err != nil {
			br.Close()
			if pgErr, ok := err.(*pgconn.PgError); ok {
				if pgErr.Code == "23505" {
					return fmt.Errorf("concurrent conflict on key (SQLSTATE 23505): %w", err)
				}
				if pgErr.Code == "40P01" {
					return fmt.Errorf("deadlock detected during batch upsert (SQLSTATE 40P01): %w", err)
				}
			}
			return fmt.Errorf("failed to exec batch row %d: %w", i, err)
		}
	}
	if err := br.Close(); err != nil {
		return fmt.Errorf("failed to close batch results: %w", err)
	}

	return tx.Commit(ctx)
}
```

### 5.2 TypeScript (`Drizzle ORM`): Partial Unique Index & Soft-Delete Invariant

```typescript
import { pgTable, uuid, varchar, timestamp, uniqueIndex } from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';

// Production Table Schema: Users with Tenant Isolation and Soft Deletes
export const users = pgTable(
  'users',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    tenantId: uuid('tenant_id').notNull(),
    email: varchar('email', { length: 255 }).notNull(),
    name: varchar('name', { length: 255 }).notNull(),
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (table) => [
    // Invariant: MUST use partial unique index where deleted_at IS NULL.
    // Normalized to LOWER(TRIM(email)) to prevent casing collisions.
    uniqueIndex('idx_users_active_tenant_lower_email')
      .on(table.tenantId, sql`LOWER(TRIM(${table.email}))`)
      .where(sql`${table.deletedAt} IS NULL`),
  ]
);

// Atomic Upsert Example with Drizzle
export async function upsertActiveUser(
  db: any,
  data: { tenantId: string; email: string; name: string }
) {
  const normalizedEmail = data.email.trim().toLowerCase();

  return await db
    .insert(users)
    .values({
      tenantId: data.tenantId,
      email: normalizedEmail,
      name: data.name,
    })
    .onConflictDoUpdate({
      target: [users.tenantId, sql`LOWER(TRIM(${users.email}))`],
      targetWhere: sql`${users.deletedAt} IS NULL`,
      set: {
        name: sql`EXCLUDED.name`,
        updatedAt: sql`clock_timestamp()`,
      },
      setWhere: sql`${users.name} IS DISTINCT FROM EXCLUDED.name`,
    })
    .returning();
}
```

### 5.3 Python (`SQLAlchemy 2.0`): PostgreSQL 15 `postgresql_nulls_not_distinct`

```python
from sqlalchemy import Column, String, DateTime, Index, func, text
from sqlalchemy.dialects.postgresql import UUID, insert
from sqlalchemy.orm import declarative_base
import uuid

Base = declarative_base()

class TenantIntegration(Base):
    __tablename__ = "tenant_integrations"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), nullable=False)
    integration_code = Column(String(64), nullable=True)  # Nullable external connector
    api_key_encrypted = Column(String(512), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.clock_timestamp())

    # Invariant: Enforce uniqueness across (tenant_id, integration_code) even when NULL!
    # Prevents multiple NULL entries for the same tenant.
    __table_args__ = (
        Index(
            "uq_tenant_integration_code",
            "tenant_id",
            "integration_code",
            unique=True,
            postgresql_nulls_not_distinct=True,  # Emits NULLS NOT DISTINCT on PostgreSQL 15+
        ),
    )

def execute_atomic_upsert(session, tenant_id: uuid.UUID, code: str, key_enc: str):
    stmt = insert(TenantIntegration).values(
        tenant_id=tenant_id,
        integration_code=code,
        api_key_encrypted=key_enc,
    )
    
    # Guard against unnecessary MVCC writes when key is unchanged
    upsert_stmt = stmt.on_conflict_do_update(
        index_elements=["tenant_id", "integration_code"],
        set_={
            "api_key_encrypted": stmt.excluded.api_key_encrypted,
            "updated_at": func.clock_timestamp(),
        },
        where=(TenantIntegration.api_key_encrypted.is_distinct_from(stmt.excluded.api_key_encrypted)),
    ).returning(TenantIntegration)

    return session.execute(upsert_stmt).scalar_one()
```

### 5.4 Rust (`sqlx`): Zero-Downtime Safe Unique Constraint Migration Harness

```rust
use sqlx::{PgPool, Error};

pub struct UniqueConstraintMigrator;

impl UniqueConstraintMigrator {
    /// Applies a unique index concurrently and validates its health before attaching as a table constraint.
    pub async fn apply_concurrent_unique_constraint(
        pool: &PgPool,
        table: &str,
        constraint_name: &str,
        columns: &str,
    ) -> Result<(), Error> {
        let index_name = format!("idx_{}_{}", table, constraint_name);

        // Step 1: Create Unique Index Concurrently (Requires non-transactional execution)
        let create_idx_sql = format!(
            "CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS \"{}\" ON \"{}\" ({});",
            index_name, table, columns
        );
        sqlx::query(&create_idx_sql).execute(pool).await?;

        // Step 2: Verify that the concurrent index is valid (not marked indisvalid = false due to collision)
        let verify_sql = "
            SELECT indisvalid
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            WHERE c.relname = $1;
        ";
        let is_valid: bool = sqlx::query_scalar(verify_sql)
            .bind(&index_name)
            .fetch_one(pool)
            .await?;

        if !is_valid {
            return Err(Error::Protocol(format!(
                "Index {} was built with invalid status (indisvalid = false); resolve duplicate rows first",
                index_name
            )));
        }

        // Step 3: Attach index to table under sub-second lock timeout
        let attach_sql = format!(
            "
            SET lock_timeout = '2s';
            ALTER TABLE \"{}\"
            ADD CONSTRAINT \"{}\" UNIQUE USING INDEX \"{}\";
            ",
            table, constraint_name, index_name
        );
        sqlx::query(&attach_sql).execute(pool).await?;

        Ok(())
    }
}
```

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Matrix

Every pull request, schema migration, or repository patch touching unique constraints or upsert logic must satisfy all 6 gates before merge approval:

| Gate | Verification Target | Autonomous Command / Query | Hard Failure Threshold |
| :--- | :--- | :--- | :--- |
| **Gate 1: Zero Check-Then-Insert** | Code AST / Ripgrep | `rg -i "SELECT.*FROM.*WHERE" -A 5 | rg -i "INSERT INTO"` | **Any unhandled check-then-insert pattern** triggers immediate PR failure. |
| **Gate 2: Soft-Delete Partial Index** | Database Schema Audit | `SELECT relname FROM pg_class WHERE relname IN (SELECT conrelid::regclass::text FROM pg_constraint WHERE contype = 'u') AND EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = pg_class.oid AND attname = 'deleted_at');` | **Any table with `deleted_at` having a full non-partial unique constraint** fails CI. |
| **Gate 3: Safe Concurrent DDL** | Migration Linter | `rg -i "ALTER TABLE.*ADD CONSTRAINT.*UNIQUE" migrations/` | **Any migration adding a unique constraint without `USING INDEX`** fails CI. |
| **Gate 4: HOT Update Guard in UPSERTs** | SQL AST Scanner | `rg -i "ON CONFLICT.*DO UPDATE SET" -A 10 | rg -v -i "IS DISTINCT FROM"` | **Any `DO UPDATE` statement missing `IS DISTINCT FROM` filter** fails CI. |
| **Gate 5: Canonical Batch Sorting** | Unit Test Concurrency | Parallel batch upsert execution test with 20 concurrent goroutines/workers | **Any `SQLSTATE 40P01` deadlock occurrence** fails CI. |
| **Gate 6: Zero Invalid Indexes** | Schema Health Check | `SELECT relname FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid WHERE i.indisvalid = false;` | **Count > 0 (invalid index detected)** fails deployment. |
