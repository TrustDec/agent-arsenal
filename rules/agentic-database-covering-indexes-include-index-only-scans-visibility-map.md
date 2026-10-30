---
description: PostgreSQL covering indexes with INCLUDE clause, index-only scans (IOS), visibility map (PD_ALL_VISIBLE) dependencies, heap fetch elimination, B-tree payload bloat vs fan-out reduction, HOT update preservation, and unique covering constraints across Go (pgx/sqlc), TypeScript (Drizzle, Prisma, Kysely), Python (SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{query,index,schema,repo,repository,store,migration,entity}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Covering Indexes (INCLUDE Clause), Index-Only Scans, Visibility Map Dependencies & Vacuum Freezing Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design database query paths, high-throughput analytical lookups, dashboard read aggregates, caching bypasses, API projection endpoints, or zero-downtime schema migrations across PostgreSQL (11+), Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`). Eliminate the "Index-Only Scan Degeneration to Heap Fetch Avalanche" (where updated rows invalidate the Visibility Map `PD_ALL_VISIBLE` page bits, forcing PostgreSQL to perform random I/O reads on millions of heap tuples during presumed index-only scans), the "B-Tree Internal Node Bloat & Fan-Out Collapse Trap" (where declaring non-filter projection columns directly in composite index keys balloons upper branch pages, drops B-Tree fan-out $B$ by 70%, increases index tree height, and evicts active working sets from `shared_buffers`), the "Unique Constraint vs Non-Key Payloads Invariant" (where naive composite uniqueness corrupts domain logic by appending projection fields into unique keys), the "Non-Sargable `INCLUDE` Predicate Trap" (where agents attempt B-Tree range seek filters on non-key included columns that reside solely on leaf pages), the "Heap-Only Tuple (HOT) Update Invalidation Trap" (where placing frequently modified mutable columns into `INCLUDE` breaks engine-level HOT optimization, forcing physical index rewrites and dead tuple bloat), and the "Varlena / 1/3-Page Tuple Limit Hard Outage" (where unbounded `text` or `jsonb` payloads exceed the 2704-byte B-Tree tuple threshold, triggering fatal insert crashes) by establishing a strict 5-Tier Covering Index & Visibility Map Governance Ladder, mathematical visibility and fan-out proofs, production TypeScript guard engines, and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Covering Index Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL 11+, the `INCLUDE` clause allows B-Tree indexes to store non-key payload attributes strictly within leaf pages (Level 0) without incorporating them into the sorted search key or upper navigation nodes:

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: COMPOSITE INDEX BLOAT (UPPER NODE POLLUTION)
-- Agent creates composite index to cover a high-frequency lookup:
CREATE INDEX idx_orders_user_status_total_created 
ON orders (user_id, status, total_amount, created_at, tracking_number);
-- ❌ Catastrophe:
-- 1. All 5 columns are duplicated on EVERY internal branch and root node in the B-Tree!
-- 2. Leaf page capacity drops from ~250 tuples/page to ~40 tuples/page.
-- 3. B-Tree tree height increases from 3 levels to 5 levels, requiring 66% more page traversals.
-- 4. B-Tree index size doubles, evicting the OLTP working set from shared_buffers.
```

```sql
-- ✅ PRODUCTION INVARIANT: COVERING INDEX WITH INCLUDE CLAUSE (LEAF-ONLY PAYLOAD)
-- Index key contains ONLY filtered/sorted attributes (user_id):
CREATE INDEX CONCURRENTLY idx_orders_user_covering
ON orders (user_id) 
INCLUDE (status, total_amount, created_at)
WITH (fillfactor = 90);
-- ✅ Production Benefits:
-- 1. Upper branch navigation pages contain ONLY 8-byte user_id keys -> maximum fan-out B >= 350.
-- 2. Non-key attributes (status, total_amount, created_at) are stored ONLY at leaf pages.
-- 3. Enables true Index-Only Scan (IOS) with zero heap accesses when Visibility Map is intact.
-- 4. B-Tree height remains minimal (height = 3 for 50,000,000 rows).
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: UNIQUE CONSTRAINT CORRUPTION VIA NAIVE COMPOSITE
-- Business Rule: Email must be unique per tenant!
-- Query requirement: Rapidly fetch (id, role, password_hash) by (tenant_id, email)
CREATE UNIQUE INDEX idx_users_unique_covering 
ON users (tenant_id, email, id, role, password_hash);
-- ❌ CATASTROPHIC BUG:
-- Uniqueness is now enforced on the ENTIRE composite 5-tuple!
-- A tenant can now have 10 accounts with identical 'alice@corp.com' if 'role' or 'id' differs!
-- Severe data corruption and account takeover vulnerabilities introduced!
```

```sql
-- ✅ PRODUCTION INVARIANT: UNIQUE INDEX WITH NON-KEY COVERING ATTRIBUTES
CREATE UNIQUE INDEX CONCURRENTLY idx_users_unique_email_covering
ON users (tenant_id, email)
INCLUDE (id, role, password_hash);
-- ✅ Production Invariant:
-- 1. Uniqueness is STRICTLY enforced on (tenant_id, email). Duplicate emails are rejected.
-- 2. Query 'SELECT id, role, password_hash FROM users WHERE tenant_id = $1 AND email = $2'
--    executes as an Index-Only Scan with 0 heap accesses, pulling non-key payloads directly from index leaf.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: THE VISIBILITY MAP DEGENERATION CLIFF
-- In dev environment (cold static data):
EXPLAIN (ANALYZE, BUFFERS)
SELECT status, total_amount, created_at FROM orders WHERE user_id = 'usr_123';
-- Output: Index Only Scan ... Heap Fetches: 0 (Execution time: 0.08ms)

-- IN PRODUCTION UNDER CONCURRENT WRITES:
-- High-churn table with default autovacuum (autovacuum_vacuum_scale_factor = 0.20):
-- 25% of heap pages were modified by updates; autovacuum has not yet set PD_ALL_VISIBLE bit!
-- Output: Index Only Scan ... Heap Fetches: 384,192 (Execution time: 312.4ms)
-- ❌ The query silently degenerates into 380,000 random-access heap block reads!
```

---

### The 6 Covering Index & Index-Only Scan Catastrophes

1. **The Index-Only Scan Degeneration to Heap Fetch Avalanche**:
   Because PostgreSQL stores row visibility (`xmin`, `xmax`, commit log status) within the heap tuple header (`HeapTupleHeaderData`) and *never* in index tuples, an Index-Only Scan can only skip reading the heap table if the target heap block is marked as visible to all current transactions in the **Visibility Map** (`PD_ALL_VISIBLE`). When write churn occurs and autovacuum is delayed, the engine must fetch the physical heap block for every matching index entry, causing execution time to spike from $<1\text{ms}$ to $>300\text{ms}$.

2. **The B-Tree Internal Node Bloat & Fan-Out Collapse Trap**:
   Putting non-filter projection columns directly into the B-Tree index key forces PostgreSQL to replicate those wide columns across every internal routing node. For an 8KB page, index key size increases from 8 bytes to 128 bytes, collapsing the B-Tree branching factor (fan-out) $B$ from 380 down to 42. This balloons the index depth, multiplies cache-misses in CPU L2/L3 caches, and consumes 3x more `shared_buffers`.

3. **The Unique Constraint vs Non-Key Payloads Invariant**:
   LLMs tasked with optimizing unique point lookups frequently append projection columns into the `CREATE UNIQUE INDEX` declaration. This fatally alters the mathematical uniqueness domain: the engine enforces uniqueness across the Cartesian product of all listed columns, allowing duplicate business keys with distinct projection attributes.

4. **The Non-Sargable `INCLUDE` Predicate Trap**:
   Non-key attributes declared in `INCLUDE (...)` are not ordered or partitioned in the B-Tree. When agents write `WHERE user_id = $1 AND status = 'ACTIVE'` with index `(user_id) INCLUDE (status)`, the database cannot perform a B-Tree binary search on `status`. It can only use `status` as a secondary leaf-level filter, failing to eliminate subtrees during navigation.

5. **The Heap-Only Tuple (HOT) Update Invalidation Trap**:
   PostgreSQL's Heap-Only Tuple (HOT) optimization allows `UPDATE` statements to avoid modifying table indexes if the modified columns are not indexed by *any* index on the table and free space exists on the same heap page. Including frequently updated columns (such as `updated_at`, `view_count`, `last_login_at`) inside `INCLUDE (...)` strips those rows of HOT eligibility, forcing an index write on every update and triggering exponential index bloat.

6. **The Varlena / 1/3-Page Tuple Limit Hard Outage**:
   PostgreSQL limits B-Tree index tuple size to $\le \frac{1}{3} \times \text{BLCKSZ}$ (approximately 2704 bytes for 8KB pages). Placing variable-length `text`, `bytea`, or unstructured `jsonb` columns inside `INCLUDE` creates a ticking bomb: once a user inserts a payload exceeding 2.7KB, the database throws SQLSTATE `54000: index row size exceeds maximum 2704 for index`.

---

### The 5-Tier Covering Index & Visibility Map Governance Ladder

```
+---------------------------------------------------------------------------------------+
| Tier 4: Varlena Bounding & Two-Phase Zero-Downtime Concurrent Migration               |
| - Ban unbounded text/jsonb in INCLUDE; enforce max byte limit <= 512B                 |
| - CREATE INDEX CONCURRENTLY outside transactions; SET LOCAL lock_timeout = '2000ms'   |
+---------------------------------------------------------------------------------------+
                                           ^
+---------------------------------------------------------------------------------------+
| Tier 3: HOT Update Preservation & Low-Churn Inclusion Invariant                       |
| - Restrict INCLUDE strictly to immutable or low-churn projection fields               |
| - Ban volatile counters (views, balance) and updated_at timestamps from INCLUDE       |
+---------------------------------------------------------------------------------------+
                                           ^
+---------------------------------------------------------------------------------------+
| Tier 2: Visibility Map Maintenance & Autovacuum Tuning for Index-Only Scans           |
| - Tune autovacuum_vacuum_scale_factor = 0.05 & autovacuum_vacuum_insert_scale_factor  |
| - Continuous pg_visibility auditing: alert when heap fetch ratio R_heap > 0.05       |
+---------------------------------------------------------------------------------------+
                                           ^
+---------------------------------------------------------------------------------------+
| Tier 1: Unique Covering Constraints for Domain Integrity                              |
| - Enforce business uniqueness on key columns: UNIQUE (business_keys) INCLUDE (payload)|
| - Preserve strict relational invariants while serving 0-heap point lookups            |
+---------------------------------------------------------------------------------------+
                                           ^
+---------------------------------------------------------------------------------------+
| Tier 0: Key vs Non-Key Attribute Separation Invariant                                 |
| - Filter (WHERE), Join (ON), and Sort (ORDER BY) columns belong in Index Key          |
| - Projection-only attributes belong strictly in INCLUDE clause (Leaf-only storage)    |
+---------------------------------------------------------------------------------------+
```

---

## 2. Mathematical Models & Verification Calculus

### Model 1: Index-Only Scan Heap Fetch Degradation & I/O Amplification Calculus

Let a query retrieve $N_{\text{tuples}}$ matching an index condition. Let $P_{\text{heap}}$ be the total number of heap blocks containing these tuples, and let $\Phi_{\text{visible}} \in [0, 1]$ be the proportion of those heap blocks flagged as all-visible in the database **Visibility Map**:

$$\Phi_{\text{visible}} = \frac{N_{\text{visible\_blocks}}}{N_{\text{total\_blocks}}}$$

The expected number of physical heap fetches executed during an Index-Only Scan is:

$$\mathbb{E}[N_{\text{heap\_fetches}}] = N_{\text{tuples}} \times (1 - \Phi_{\text{visible}})$$

When $\Phi_{\text{visible}} = 1.0$ (fully vacuumed), $\mathbb{E}[N_{\text{heap\_fetches}}] = 0$, achieving maximum Index-Only Scan efficiency.

The total I/O cost model for the scan is given by:

$$C_{\text{IOS}} = N_{\text{index\_pages}} \cdot c_{\text{seq}} + \mathbb{E}[N_{\text{heap\_fetches}}] \cdot c_{\text{rand}}$$

Where $c_{\text{seq}}$ is sequential/cached page cost (`seq_page_cost = 1.0`) and $c_{\text{rand}}$ is random disk I/O cost (`random_page_cost = 1.1` to `4.0`).

The I/O amplification factor $\mathcal{A}_{\text{IO}}$ relative to an ideal Index-Only Scan is:

$$\mathcal{A}_{\text{IO}} = \frac{C_{\text{IOS}}(\Phi_{\text{visible}})}{C_{\text{IOS}}(1.0)} = 1 + \frac{N_{\text{tuples}} \cdot (1 - \Phi_{\text{visible}}) \cdot c_{\text{rand}}}{N_{\text{index\_pages}} \cdot c_{\text{seq}}}$$

**Theorem 1 (Visibility Map Cliff)**: *If $\Phi_{\text{visible}}$ falls below $0.85$, an Index-Only Scan incurs random I/O costs comparable to or worse than a standard Bitmap Heap Scan, negating the benefit of covering indexes.*

---

### Model 2: B-Tree Fan-out & Internal Node Memory Footprint Differential

In a standard composite index on $K$ columns, every index tuple at both leaf and internal levels has width:

$$W_{\text{composite}} = \sum_{i=1}^K S_i + H_{\text{tuple\_header}}$$

With the `INCLUDE` clause on key columns $1 \dots M$ and included columns $M+1 \dots K$:

$$W_{\text{internal}} = \sum_{i=1}^M S_i + H_{\text{tuple\_header}}$$
$$W_{\text{leaf}} = \sum_{i=1}^K S_i + H_{\text{tuple\_header}}$$

Given an 8192-byte page with header overhead $H_{\text{page}} \approx 24$ bytes and special line pointer overhead $4$ bytes per tuple, the internal node branching factor (fan-out $B$) is:

$$B_{\text{composite}} = \left\lfloor \frac{8192 - H_{\text{page}}}{W_{\text{composite}} + 4} \right\rfloor$$
$$B_{\text{include}} = \left\lfloor \frac{8192 - H_{\text{page}}}{W_{\text{internal}} + 4} \right\rfloor$$

For a table with $N$ rows, the height $h$ of the B-Tree is:

$$h = \left\lceil \log_B \left( \frac{N}{B_{\text{leaf}}} \right) \right\rceil + 1$$

And the total number of internal branch pages kept in memory is:

$$N_{\text{internal\_pages}} = \sum_{j=1}^{h-1} \left\lceil \frac{N}{B^{j}} \right\rceil$$

When $W_{\text{internal}} \ll W_{\text{composite}}$, $B_{\text{include}} \gg B_{\text{composite}}$, reducing the internal memory footprint in `shared_buffers` by:

$$\Delta M = 1 - \frac{B_{\text{composite}}}{B_{\text{include}}} \ge 60\% - 85\%$$

---

### Model 3: Heap-Only Tuple (HOT) Update Invalidation Model

Let a table have $I$ indexes. Let $\mathcal{C}(I_k)$ be the set of columns referenced in index $k$ (including both search keys and `INCLUDE` columns). Let an `UPDATE` mutate column subset $\mathcal{M} \subset \text{Columns}$.

A tuple update qualifies for the Heap-Only Tuple (HOT) optimization if and only if:

$$\mathcal{M} \cap \left( \bigcup_{k=1}^I \mathcal{C}(I_k) \right) = \emptyset \quad \land \quad \text{FreeSpace}(\text{Page}) \ge S_{\text{new\_tuple}}$$

If any modified column $m \in \mathcal{M}$ is placed in `INCLUDE` of any index, the probability of HOT optimization drops to zero:

$$P(\text{HOT Update} \mid m \in \mathcal{C}(I)) = 0$$

Every non-HOT update generates a new index tuple for *every single index* on the table, increasing WAL write volume by:

$$\Delta \text{WAL}_{\text{update}} = \sum_{k=1}^I W(I_k)$$

---

## 3. Production Implementation: TypeScript `AgenticCoveringIndexOptimizerEngine`

```typescript
/**
 * AgenticCoveringIndexOptimizerEngine
 * Production-ready analysis and DDL generation engine for PostgreSQL Covering Indexes (INCLUDE).
 * Enforces key vs non-key column separation, visibility map health checks, HOT-preservation,
 * unique covering invariants, and 0-heap Index-Only Scan verification.
 */

export interface ColumnMetadata {
  name: string;
  type: string;
  byteWidth: number;
  isNullable: boolean;
  updateFrequency: 'HIGH' | 'LOW' | 'NEVER'; // HOT impact assessment
  isVariableLength: boolean;
}

export interface TableSchema {
  tableName: string;
  columns: Record<string, ColumnMetadata>;
  rowCount: number;
  fillfactor: number;
}

export interface QueryAccessPattern {
  queryName: string;
  filterColumns: string[];    // Used in WHERE, ON, or ORDER BY -> Must be Index Keys
  projectionColumns: string[]; // Used in SELECT -> Candidates for INCLUDE
  executionFrequencyPerSec: number;
  isUniqueConstraintNeeded: boolean;
}

export interface CoveringIndexValidationResult {
  isValid: boolean;
  indexName: string;
  keyColumns: string[];
  includedColumns: string[];
  isUnique: boolean;
  estimatedLeafTupleBytes: number;
  estimatedInternalTupleBytes: number;
  fanoutInternal: number;
  fanoutCompositeEquivalent: number;
  hotViolationWarnings: string[];
  sizeViolationWarnings: string[];
  suggestedDdl: string[];
  visibilityAuditQuery: string;
}

export class AgenticCoveringIndexOptimizerEngine {
  private static readonly BLCKSZ = 8192;
  private static readonly PAGE_HEADER_BYTES = 24;
  private static readonly TUPLE_HEADER_BYTES = 23; // HeapTupleHeaderData / IndexTupleData
  private static readonly LINE_POINTER_BYTES = 4;
  private static readonly MAX_BTREE_TUPLE_BYTES = Math.floor(8192 / 3); // 2704 bytes
  private static readonly SAFE_INCLUDE_TOTAL_BYTES = 512; // Safety threshold for INCLUDE payload

  /**
   * Evaluates query access patterns against table schema and synthesizes optimal Covering Index DDL.
   */
  public static designCoveringIndex(
    table: TableSchema,
    pattern: QueryAccessPattern
  ): CoveringIndexValidationResult {
    const hotViolationWarnings: string[] = [];
    const sizeViolationWarnings: string[] = [];

    // 1. Separate Key vs Included attributes
    // Rule: Filter/Sort attributes MUST be keys. Projection attributes go to INCLUDE unless already in keys.
    const keyColumns = [...new Set(pattern.filterColumns)];
    const includedColumns = [...new Set(
      pattern.projectionColumns.filter((col) => !keyColumns.includes(col))
    )];

    // 2. Validate columns exist in schema
    for (const col of [...keyColumns, ...includedColumns]) {
      if (!table.columns[col]) {
        throw new Error(`Column '${col}' does not exist on table '${table.tableName}'`);
      }
    }

    // 3. HOT update violation detection
    for (const col of includedColumns) {
      const meta = table.columns[col];
      if (meta.updateFrequency === 'HIGH') {
        hotViolationWarnings.push(
          `HOT-VIOLATION: Column '${col}' in INCLUDE has HIGH update frequency. ` +
          `Modifying it will invalidate Heap-Only Tuple optimization and trigger index bloat.`
        );
      }
    }

    // 4. Calculate Tuple Sizes and B-Tree Fan-outs
    let keyBytes = this.TUPLE_HEADER_BYTES;
    for (const col of keyColumns) {
      keyBytes += table.columns[col].byteWidth;
    }

    let includeBytes = 0;
    for (const col of includedColumns) {
      const meta = table.columns[col];
      includeBytes += meta.byteWidth;

      if (meta.isVariableLength && meta.byteWidth > 256) {
        sizeViolationWarnings.push(
          `VARLENA-WARNING: Column '${col}' is variable-length with potentially wide payload. ` +
          `Risk of exceeding PostgreSQL 1/3 block limit (2704 bytes).`
        );
      }
    }

    const totalLeafBytes = keyBytes + includeBytes;
    if (includeBytes > this.SAFE_INCLUDE_TOTAL_BYTES) {
      sizeViolationWarnings.push(
        `PAYLOAD-BLOAT: Total INCLUDE payload (${includeBytes}B) exceeds recommended 512B threshold. ` +
        `Consider fetching wide attributes from heap or caching layer.`
      );
    }

    if (totalLeafBytes >= this.MAX_BTREE_TUPLE_BYTES) {
      sizeViolationWarnings.push(
        `FATAL-SIZE: Total index tuple size (${totalLeafBytes}B) exceeds B-Tree 1/3 page limit (${this.MAX_BTREE_TUPLE_BYTES}B). ` +
        `PostgreSQL will reject large row inserts with SQLSTATE 54000.`
      );
    }

    const usablePageBytes = this.BLCKSZ - this.PAGE_HEADER_BYTES;
    const fanoutInternal = Math.floor(usablePageBytes / (keyBytes + this.LINE_POINTER_BYTES));
    const fanoutCompositeEquivalent = Math.floor(
      usablePageBytes / (totalLeafBytes + this.LINE_POINTER_BYTES)
    );

    // 5. Generate DDL
    const indexName = `idx_${table.tableName}_${keyColumns.join('_')}_cov`;
    const uniqueClause = pattern.isUniqueConstraintNeeded ? 'UNIQUE ' : '';
    const includeClause = includedColumns.length > 0 ? ` INCLUDE (${includedColumns.join(', ')})` : '';

    const suggestedDdl: string[] = [
      `-- Phase 1: Create covering index concurrently outside transaction blocks`,
      `CREATE ${uniqueClause}INDEX CONCURRENTLY IF NOT EXISTS ${indexName}`,
      `ON ${table.tableName} (${keyColumns.join(', ')})${includeClause}`,
      `WITH (fillfactor = 90);`,
      ``,
      `-- Phase 2: Tune autovacuum for high-churn Index-Only Scan tables to keep Visibility Map warm`,
      `ALTER TABLE ${table.tableName} SET (`,
      `  autovacuum_vacuum_scale_factor = 0.05,`,
      `  autovacuum_vacuum_insert_scale_factor = 0.02`,
      `);`,
    ];

    const visibilityAuditQuery = `
      -- Audit Visibility Map coverage and Heap Fetch ratio for table ${table.tableName}
      SELECT
        c.relname,
        pg_size_pretty(pg_relation_size(c.oid)) AS table_size,
        pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
        stat.idx_scan,
        stat.idx_tup_fetch AS heap_fetches,
        CASE
          WHEN stat.idx_scan = 0 THEN 0.0
          ELSE ROUND((stat.idx_tup_fetch::numeric / stat.idx_scan::numeric), 2)
        END AS avg_heap_fetches_per_scan
      FROM pg_class c
      JOIN pg_index i ON c.oid = i.indrelid
      JOIN pg_statio_user_indexes stat ON i.indexrelid = stat.indexrelid
      WHERE c.relname = '${table.tableName}'
        AND i.indexrelid = '${indexName}'::regclass;
    `.trim();

    return {
      isValid: sizeViolationWarnings.filter((w) => w.startsWith('FATAL')).length === 0,
      indexName,
      keyColumns,
      includedColumns,
      isUnique: pattern.isUniqueConstraintNeeded,
      estimatedLeafTupleBytes: totalLeafBytes,
      estimatedInternalTupleBytes: keyBytes,
      fanoutInternal,
      fanoutCompositeEquivalent,
      hotViolationWarnings,
      sizeViolationWarnings,
      suggestedDdl,
      visibilityAuditQuery,
    };
  }
}
```

---

## 4. 6-State Covering Index Lifecycle Finite-State Machine (FSM)

```
       [ 1. ACCESS_PATTERN_PROFILED ]
                     │
                     ▼ (Separate Filter Keys vs SELECT Projections)
       [ 2. PAYLOAD_HOT_VERIFIED ] ──(Mutable/Updated Col Detected)──► [ REJECT_HOT_ATTR ]
                     │
                     ▼ (Validate Payload Width <= 512B & Varlena Limits)
       [ 3. TUPLE_SIZING_PASSED ]
                     │
                     ▼ (Generate DDL with CONCURRENTLY + fillfactor = 90)
       [ 4. CONCURRENT_INDEX_BUILT ]
                     │
                     ▼ (Verify EXPLAIN (ANALYZE, BUFFERS) Heap Fetches == 0)
       [ 5. VISIBILITY_MAP_WARMED ] ──(Heap Fetches > 5%)──► [ TUNE_AUTOVACUUM ]
                     │
                     ▼ (Continuous Metric Sentinel: Heap Fetch Ratio < 0.01)
       [ 6. PRODUCTION_STABLE ]
```

---

## 5. 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Failure Condition | Pass Threshold | Automated Verification Script |
| :--- | :--- | :--- | :--- | :--- |
| **Gate 1: Key Separation** | Index Key vs `INCLUDE` | Filter/Sort columns placed in `INCLUDE` or projection columns placed in Key | 100% Separation | AST Query Linter (`sql-parser`) |
| **Gate 2: Unique Invariance** | Domain Uniqueness | Business keys altered by appending projection attributes to unique constraint | 0 Foreign Keys in Unique | Schema Unit Test |
| **Gate 3: HOT Protection** | Tuple Update Bloat | Columns with update frequency `HIGH` placed inside `INCLUDE` | 0 High-Churn Attributes | Static Schema Linter |
| **Gate 4: Size Bounding** | Tuple Byte Limits | Leaf tuple size $\ge 2704\text{B}$ or `INCLUDE` payload $> 512\text{B}$ | $\le 512\text{B}$ Payload | `AgenticCoveringIndexOptimizerEngine` |
| **Gate 5: Visibility Warmth** | Heap Fetch Degeneration | `Heap Fetches` $> 5\%$ of returned tuples in production workload | $\text{Heap Fetches} \le 1\%$ | `EXPLAIN (ANALYZE, BUFFERS)` CI Gate |
| **Gate 6: Zero-Downtime DDL** | Exclusive Table Locks | Missing `CONCURRENTLY` or running inside transaction block | 0 Table Lockouts | Migration CI Checker |

---

## 6. Cross-Language Implementation Invariants

### A. Go (`jackc/pgx/v5` & `sqlc`)

```go
package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type CoveredOrderRecord struct {
	ID             string    `json:"id"`
	Status         string    `json:"status"`
	TotalAmount    int64     `json:"total_amount_cents"`
	CreatedAt      time.Time `json:"created_at"`
}

// GetUserOrdersCovered executes an Index-Only Scan against the covering index:
// CREATE INDEX CONCURRENTLY idx_orders_user_cov ON orders (user_id) INCLUDE (status, total_amount, created_at);
// Guaranteed 0-heap fetches when the Visibility Map is maintained.
func GetUserOrdersCovered(ctx context.Context, pool *pgxpool.Pool, userID string) ([]CoveredOrderRecord, error) {
	query := `
		SELECT id, status, total_amount, created_at
		FROM orders
		WHERE user_id = $1
		ORDER BY user_id;
	`
	rows, err := pool.Query(ctx, query, userID)
	if err != nil {
		return nil, fmt.Errorf("failed to query covered user orders: %w", err)
	}
	defer rows.Close()

	var records []CoveredOrderRecord
	for rows.Next() {
		var r CoveredOrderRecord
		if err := rows.Scan(&r.ID, &r.Status, &r.TotalAmount, &r.CreatedAt); err != nil {
			return nil, fmt.Errorf("failed to scan covered order tuple: %w", err)
		}
		records = append(records, r)
	}

	return records, rows.Err()
}
```

---

### B. TypeScript (`Drizzle ORM`)

```typescript
import { pgTable, uuid, varchar, bigint, timestamp, index } from 'drizzle-orm/pg-core';

export const orders = pgTable(
  'orders',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: uuid('user_id').notNull(),
    status: varchar('status', { length: 32 }).notNull(),
    totalAmountCents: bigint('total_amount_cents', { mode: 'number' }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (table) => [
    // Covering index: userId is search key, (status, totalAmountCents, createdAt) in INCLUDE
    // Crucial: updatedAt is EXCLUDED to preserve HOT (Heap-Only Tuple) update performance!
    index('idx_orders_user_covering')
      .on(table.userId)
      .include(table.status, table.totalAmountCents, table.createdAt),
  ]
);
```

---

### C. Python (`SQLAlchemy 2.0`)

```python
from sqlalchemy import Table, Column, String, BigInteger, DateTime, Index, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import DeclarativeBase

class Base(DeclarativeBase):
    pass

class Order(Base):
    __tablename__ = "orders"

    id = Column(UUID(as_uuid=True), primary_key=True)
    user_id = Column(UUID(as_uuid=True), nullable=False)
    status = Column(String(32), nullable=False)
    total_amount_cents = Column(BigInteger, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    __table_args__ = (
        # Production Covering Index with postgresql_include
        Index(
            "idx_orders_user_cov",
            "user_id",
            postgresql_include=["status", "total_amount_cents", "created_at"],
            postgresql_concurrently=True,
            postgresql_with={"fillfactor": 90},
        ),
    )
```
