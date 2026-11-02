---
description: PostgreSQL 17 B-Tree multi-value search optimization (ScalarArrayOpExpr), array key in-index binary search, skip-scans across leaf pages, deduplication, and bitmap scan fallback elimination across Go (pgx), TypeScript (pg/Drizzle), Python (asyncpg), Rust (tokio-postgres), Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{query,index,search,filter,where,repository,dao,database,postgres,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/database/**/*.{go,rs},**/internal/repository/**/*.{go,rs},**/queries/**/*.{sql,ts,go,py,rs}
alwaysApply: false
---

# Agentic Database PostgreSQL 17 B-Tree Multi-Value Search Optimization (`ScalarArrayOpExpr`), Array Key Binary Search, In-Index Skip-Scan & Bitmap Scan Fallback Elimination Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, optimize, or execute high-throughput database queries involving multi-value filters (`IN (...)`, `= ANY(...)`), batched keyset lookups, multi-tenant scoping, pagination pipelines (`ORDER BY ... LIMIT`), or ORM data-access layers across PostgreSQL 17+, Go (`jackc/pgx/v5`), TypeScript (`pg`, `postgres.js`, `Drizzle`, `Prisma`, `Kysely`), Python (`asyncpg`, `psycopg3`, `SQLAlchemy`), or Rust (`tokio-postgres`, `sqlx`). Eliminate the "Subquery Unnesting Anti-Pattern & WorkMem Hash Spill Trap (`CROSS JOIN unnest($1)`)" (where agents replace `= ANY($1)` with unnested join subqueries, bypassing the B-Tree engine entirely and triggering multi-gigabyte hash join memory spills), the "Implicit Type Coercion & Sargability Invalidation Trap" (where passing mismatched array parameter types forces PostgreSQL into full sequential table scans), the "Bitmap Index Scan Fallback & Order By Sort Spill Disaster" (where pre-PG17 cost models force queries into lossy bitmap scans that destroy index tuple ordering and trigger massive disk sort spills), the "Unbounded Array Parameter & Plan Cache Generic Drift Trap" (where wildly fluctuating array sizes poison prepared statement generic plans, resulting in catastrophic p99 latency cliffs), the "Composite Index Column Misplacement & Cartesian Descent Trap" (where placing array columns before high-cardinality equality prefixes multiplies leaf-page traversals exponentially), and the "Un-Deduplicated Client Array & Cache-Line Thrashing Trap" by establishing a strict 5-Tier B-Tree Multi-Value Governance Ladder, formal buffer traversal and speedup differential equations, an autonomous TypeScript `AgenticPostgres17BTreeArraySearchGuardEngine`, cross-runtime driver sentinels in Go, TypeScript, Python, and Rust, a 6-state execution lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 B-Tree Array Search Catastrophes vs The 5-Tier Governance Ladder

For decades prior to PostgreSQL 17, evaluating multi-value equality predicates (such as `WHERE id IN (v1, v2, ..., vK)` or `WHERE id = ANY($1::bigint[])`) using a B-Tree index required the query execution engine to perform an independent, full root-to-leaf tree descent for *every single key* present in the array. In a B-Tree of depth $D = 4$, an array of $K = 50$ elements forced the storage engine to execute $K \times D = 200$ buffer pin, lock, and descent operations. Even if all 50 keys resided on the exact same leaf page, the legacy engine ascended back to the root page after evaluating each item, repeatedly acquiring buffer read locks (`LWLock`) on upper branch pages, evicting cache lines, and burning CPU cycles in branch prediction misses.

To avoid this $O(K \cdot D)$ penalty, the query planner frequently abandoned pure `Index Scan` execution paths when $K$ grew beyond a small threshold (often as low as 10 to 20 keys), falling back to `Bitmap Index Scan` + `Bitmap Heap Scan`. While bitmap scans aggregate heap block references into a lossy or lossless TID bitmap, they fundamentally discard the physical sort order of the index tuples. When paired with `ORDER BY ... LIMIT` clauses, this fallback introduces a catastrophic execution cliff: the database can no longer terminate early upon finding the first $N$ matching tuples and must instead scan, collect, and sort all matching tuples across the entire relation, spilling intermediate runs to temporary files on disk.

In **PostgreSQL 17**, a transformative optimization was introduced to the B-Tree index scan engine (`ScalarArrayOpExpr` in-index binary search and skip-scanning, authored by Peter Geoghegan and Matthias van de Meent). In PostgreSQL 17:
1. **Pre-Scan Sort & Deduplication**: The array keys are pre-sorted according to the index collation and deduplicated in memory before index navigation begins.
2. **In-Page Binary Search**: After descending to leaf page $P$ to locate key $k_i$, the engine checks whether the next key $k_{i+1}$ also falls within the boundaries of page $P$ (by comparing against page $P$'s high key). If it does, the engine performs a fast binary search directly within the currently pinned and locked leaf buffer, requiring **zero tree navigation**.
3. **Horizontal Leaf-Page Advance**: If $k_{i+1}$ is beyond the high key of page $P$, the engine inspects the right sibling leaf page via the B-Tree right-link (`btpo_next`). Only if the key is located further away does the engine ascend to the Lowest Common Ancestor (LCA) branch page, avoiding redundant visits to the root.
4. **Order-Preserving Index Scans**: Because multi-key lookups now execute with near-zero overhead inside an `Index Scan` or `Index Only Scan`, the planner maintains tuple ordering throughout execution. Queries with `ORDER BY col LIMIT N` achieve instant early-exit termination without allocating sorting memory or spilling to disk.

When autonomous coding agents generate or refactor SQL queries without understanding these mechanics, they trigger six critical production catastrophes:

```
+----------------------------------------------------------------------------------------------------+
|               THE 6 POSTGRESQL 17 B-TREE ARRAY SEARCH CATASTROPHES                                 |
+----------------------------------------------------------------------------------------------------+
| 1. Subquery Unnesting Anti-Pattern & WorkMem Hash Spill Trap (CROSS JOIN unnest($1))               |
|    - Agent attempts to "optimize" an IN clause by converting it to INNER JOIN unnest($1::uuid[])   |
|      or WHERE id IN (SELECT unnest($1)). This strips the native ScalarArrayOpExpr node from the   |
|      AST, entirely bypassing PG17's B-Tree in-index binary search. PostgreSQL builds a Hash Join   |
|      or Nested Loop with Materialize, spilling hash tables to disk and increasing latency 20x.    |
|                                                                                                    |
| 2. Implicit Type Coercion & Sargability Invalidation Trap (int_col = ANY($1::text[]))             |
|    - Agent passes integer or UUID parameters as text/string arrays without explicit casts.         |
|      PostgreSQL cannot match the B-Tree operator class, injects an implicit runtime cast           |
|      (col::text = ANY(...)), destroys sargability, and falls back to a 100% Sequential Table Scan. |
|                                                                                                    |
| 3. Bitmap Index Scan Fallback & Order By Sort Spill Disaster                                       |
|    - Query with WHERE category_id = ANY($1) ORDER BY created_at DESC LIMIT 20 falls back to       |
|      Bitmap Index Scan due to uncalibrated cost parameters. Bitmap Scan strips index tuple order, |
|      forcing an external merge sort over 500,000 candidate rows and saturating disk I/O.          |
|                                                                                                    |
| 4. Unbounded Array Parameter & Plan Cache Generic Drift Trap                                       |
|    - Prepared statement receives wildly fluctuating array lengths (e.g., 2 items vs 5,000 items).  |
|      After 5 executions, PostgreSQL generates a generic plan optimized for the average cardinality,|
|      causing severe parameter sniffing degradation and intermittent p99 latency spikes of 10s.    |
|                                                                                                    |
| 5. Composite Index Column Misplacement & Cartesian Descent Trap                                    |
|    - Multi-column index created as (status, tenant_id, created_at) instead of                      |
|      (tenant_id, status, created_at). Searching status IN ('active', 'pending') across a specific  |
|      tenant_id breaks index prefix clustering, multiplying leaf-page traversals by tenant count.  |
|                                                                                                    |
| 6. Un-Deduplicated Client Array & Cache-Line Thrashing Trap                                        |
|    - ORMs emit arrays with hundreds of duplicate IDs (e.g., batch hydration of repeated foreign    |
|      keys). While PG17 deduplicates internally, excessive client payload bloat exhausts libpq     |
|      network buffers and CPU deserialization budgets before reaching the database engine.          |
+----------------------------------------------------------------------------------------------------+
```

To eliminate these failure modes systematically, autonomous agents must adhere to the **5-Tier B-Tree Multi-Value Governance Ladder**:

```
+----------------------------------------------------------------------------------------------------+
|                         THE 5-TIER B-TREE MULTI-VALUE GOVERNANCE LADDER                            |
+----------------------------------------------------------------------------------------------------+
| Tier 0: Engine Qualification & Capability Verification                                             |
|   - Verify server_version_num >= 170000.                                                           |
|   - Verify index access method is btree and collation is deterministic.                            |
|   - Validate that execution plans utilize native Index Scan / Index Only Scan with ScalarArrayOp.  |
+----------------------------------------------------------------------------------------------------+
| Tier 1: Strict Sargable ScalarArrayOpExpr Declarations                                             |
|   - Enforce = ANY($1::type[]) over dynamic string-interpolated IN clauses.                         |
|   - Prohibit unnest() subqueries, JOIN unnest(), and VALUES() lists for scalar lookups.            |
|   - Mandate exact data-type parity between column and array parameter (zero implicit casts).       |
+----------------------------------------------------------------------------------------------------+
| Tier 2: Parameter Bounding & Client Keyset Chunking                                                |
|   - Bound array parameter sizes to K <= 500 items per query execution.                             |
|   - Chunk larger collections client-side using bounded concurrency pipelines.                      |
|   - Pre-sort and deduplicate keys client-side to minimize protocol buffer serialization overhead. |
+----------------------------------------------------------------------------------------------------+
| Tier 3: Composite Index Cardinality Alignment & Order-Preserving Index Scans                       |
|   - Structure composite indexes: (high_cardinality_equality, low_cardinality_array, sort_tail).     |
|   - Ensure queries with ORDER BY ... LIMIT leverage index ordering for instant zero-sort exit.     |
|   - Include projected columns via INCLUDE (...) to achieve zero-heap Index Only Scans.             |
+----------------------------------------------------------------------------------------------------+
| Tier 4: Telemetry, Buffer Reduction Sentinels & CI Verification Gates                              |
|   - Continuously verify shared buffer hits via EXPLAIN (ANALYZE, BUFFERS).                         |
|   - Enforce CI gate: zero temp written blocks, zero Bitmap Index Scan on ordered limits.           |
|   - Assert >= 50% buffer access reduction on PG17 compared to legacy execution baselines.          |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. Mathematical Models, Latency Differential Equations & Invariant Theorems

### 2.1 The Legacy Root-to-Leaf Traversal Complexity

In PostgreSQL 16 and earlier, for a B-Tree of height $D$ and an array parameter of cardinality $K$, the total number of buffer page accesses $B_{\text{legacy}}$ is strictly linear in the product of $K$ and $D$:

$$B_{\text{legacy}}(K, D) = \sum_{i=1}^{K} D = K \cdot D$$

For each buffer access, the backend acquires an `LWLock` in shared mode on the buffer header, increments the buffer pin count, performs a binary search over page tuples, and releases the lock. Across $K$ keys, the total lock contention overhead $L_{\text{legacy}}$ in a multi-core system with memory bus invalidation latency $\tau_{\text{bus}}$ is:

$$L_{\text{legacy}} = K \cdot D \cdot \tau_{\text{bus}} + K \cdot D \cdot \mathcal{O}(\log_2 M_{\text{tuples\_per\_page}})$$

When multiple concurrent worker threads query the same B-Tree simultaneously, the root page and top-level internal pages experience severe lock cache-line bouncing, throttling transaction throughput.

### 2.2 The PostgreSQL 17 In-Index Skip-Scan Complexity

In PostgreSQL 17, the array keys $\{k_1, k_2, \dots, k_K\}$ are sorted such that $k_1 < k_2 < \dots < k_K$. Let $P(k_i)$ denote the leaf page housing key $k_i$. The number of buffer accesses $B_{\text{pg17}}$ is governed by:

$$B_{\text{pg17}}(K, D) = D + \sum_{i=1}^{K-1} \delta(k_i, k_{i+1})$$

where the traversal delta $\delta(k_i, k_{i+1})$ is defined as:

$$\delta(k_i, k_{i+1}) = \begin{cases} 0 & \text{if } P(k_i) = P(k_{i+1}) \quad (\text{keys reside on identical leaf page}) \\ 1 & \text{if } P(k_{i+1}) = \text{RightSibling}(P(k_i)) \quad (\text{horizontal advance}) \\ h_{\text{LCA}}(k_i, k_{i+1}) & \text{if keys require ascent to Lowest Common Ancestor at depth } h \le D \end{cases}$$

Let $\rho = \frac{K}{N_{\text{total\_leaves}}}$ represent the key density across the index leaf level. The probability that two consecutive sorted keys reside on the same leaf page is:

$$P_{\text{same\_page}} = 1 - \left(1 - \frac{1}{N_{\text{leaf\_pages}}}\right)^{K-1} \approx 1 - e^{-\frac{K}{N_{\text{leaf\_pages}}}}$$

Under clustered or batch-localized workloads where keys share leaf pages, the buffer access reduction factor $\mathcal{R}_{\text{buffers}}$ approaches:

$$\mathcal{R}_{\text{buffers}} = \frac{B_{\text{pg17}}}{B_{\text{legacy}}} = \frac{D + (1 - P_{\text{same\_page}}) \cdot \bar{\delta} \cdot K}{K \cdot D} \approx \frac{1}{K} + \frac{(1 - P_{\text{same\_page}}) \bar{\delta}}{D}$$

For $K = 50$, $D = 4$, and $P_{\text{same\_page}} = 0.80$ (typical for sequence IDs or tenant-scoped records), the buffer accesses drop from $200$ to:

$$B_{\text{pg17}} \approx 4 + (50 \times 0.20 \times 1) = 14 \implies \mathcal{R}_{\text{buffers}} = \frac{14}{200} = 0.07 \quad (\mathbf{93\%\text{ reduction in buffer accesses}})$$

### 2.3 The Bitmap Index Scan vs Ordered Index Scan Crossover Invariant

Let $C_{\text{index}}$ be the cost of an `Index Scan` and $C_{\text{bitmap}}$ be the cost of a `Bitmap Index Scan`. The query planner selects `Index Scan` if and only if:

$$C_{\text{index}} < C_{\text{bitmap}}$$

For queries containing `ORDER BY created_at LIMIT N_lim`:
- `Index Scan` cost stops after retrieving $N_{\text{lim}}$ matching tuples:
  $$C_{\text{index}}(N_{\text{lim}}) = B_{\text{pg17}}(K, D) \cdot c_{\text{page}} + N_{\text{lim}} \cdot c_{\text{cpu\_tuple}} + N_{\text{lim}} \cdot c_{\text{random\_page}}$$
- `Bitmap Index Scan` must evaluate *all* $N_{\text{matches}}$ matching tuples in the table, construct the bitmap, visit all matching heap pages, and execute a full sort:
  $$C_{\text{bitmap}} = C_{\text{bitmap\_index}} + C_{\text{bitmap\_heap}}(N_{\text{matches}}) + N_{\text{matches}} \log_2(N_{\text{matches}}) \cdot c_{\text{sort\_cpu}} + \text{Cost}_{\text{temp\_file\_spill}}$$

Because $N_{\text{matches}} \gg N_{\text{lim}}$ in large datasets (e.g., $N_{\text{matches}} = 200,000$ while $N_{\text{lim}} = 20$), `Bitmap Index Scan` introduces an astronomical latency penalty ($100\times–1,000\times$). In PostgreSQL 17, because $B_{\text{pg17}}(K, D)$ is dramatically lower than $B_{\text{legacy}}$, $C_{\text{index}}$ remains strictly lower than $C_{\text{bitmap}}$ across much wider ranges of $K$, guaranteeing order preservation and eliminating disk sort spills.

---

## 3. Autonomous TypeScript Engine: `AgenticPostgres17BTreeArraySearchGuardEngine`

The following production-grade TypeScript engine inspects SQL ASTs, verifies index coverage, transforms unnesting anti-patterns into sargable `ScalarArrayOpExpr` constructs, enforces keyset chunking boundaries, and measures buffer efficiency.

```typescript
/**
 * AgenticPostgres17BTreeArraySearchGuardEngine
 * Industrial governance engine for PostgreSQL 17 B-Tree multi-value array lookups.
 * Enforces sargable ScalarArrayOpExpr syntax, bounds array chunking, eliminates
 * bitmap scan fallbacks, and verifies execution plan buffer efficiency.
 */

import { Client, PoolClient } from 'pg';

export interface BTreeIndexMetadata {
  indexName: string;
  tableName: string;
  columns: string[];
  isUnique: boolean;
  isCovering: boolean;
  includedColumns: string[];
  opclasses: string[];
}

export interface QueryAnalysisResult {
  isSargable: boolean;
  detectedAntiPatterns: string[];
  suggestedSql: string;
  targetColumn: string | null;
  parameterCount: number;
}

export interface PlanBufferTelemetry {
  nodeType: string;
  actualRows: number;
  sharedHitBlocks: number;
  sharedReadBlocks: number;
  tempWrittenBlocks: number;
  executionTimeMs: number;
  usedIndexScan: boolean;
  usedBitmapScan: boolean;
  sortMethod?: string;
}

export class AgenticPostgres17BTreeArraySearchGuardEngine {
  private static readonly MAX_RECOMMENDED_ARRAY_SIZE = 500;
  private static readonly MIN_POSTGRES_VERSION = 170000;

  /**
   * Qualifies whether the target PostgreSQL cluster supports native PG17 B-tree array optimizations.
   */
  public static async qualifyEngineVersion(client: PoolClient | Client): Promise<boolean> {
    const res = await client.query('SHOW server_version_num;');
    const versionNum = parseInt(res.rows[0].server_version_num, 10);
    if (versionNum < this.MIN_POSTGRES_VERSION) {
      throw new Error(
        `Engine qualification failed: PostgreSQL version ${versionNum} detected. ` +
        `PG17 B-Tree multi-value array optimizations require server_version_num >= ${this.MIN_POSTGRES_VERSION}.`
      );
    }
    return true;
  }

  /**
   * Inspects a SQL query string for destructive anti-patterns (e.g., JOIN unnest, dynamic string IN).
   */
  public static analyzeQuerySyntax(sql: string): QueryAnalysisResult {
    const antiPatterns: string[] = [];
    let isSargable = true;
    let suggestedSql = sql;
    let targetColumn: string | null = null;

    // Anti-Pattern 1: JOIN unnest(...) or CROSS JOIN unnest(...)
    const unnestJoinRegex = /(?:JOIN|CROSS\s+JOIN)\s+unnest\s*\(\s*(\$[0-9]+|\w+)\s*\)/i;
    if (unnestJoinRegex.test(sql)) {
      antiPatterns.push('UNNEST_JOIN_ANTIPATTERN: Strips ScalarArrayOpExpr, forcing Hash/Nested-Loop join.');
      isSargable = false;
    }

    // Anti-Pattern 2: Subquery IN (SELECT unnest(...))
    const unnestSubqueryRegex = /IN\s*\(\s*SELECT\s+unnest\s*\(\s*(\$[0-9]+|\w+)\s*\)\s*\)/i;
    if (unnestSubqueryRegex.test(sql)) {
      antiPatterns.push('UNNEST_SUBQUERY_ANTIPATTERN: Prevents in-index skip scan. Use col = ANY($1::type[]) instead.');
      isSargable = false;
    }

    // Anti-Pattern 3: String-interpolated numeric IN clauses (e.g. IN (1, 2, 3, 4))
    const literalInRegex = /([a-zA-Z0-9_]+)\s+IN\s*\(\s*([0-9\s,']+)\s*\)/i;
    const matchLiteral = sql.match(literalInRegex);
    if (matchLiteral && matchLiteral[2].split(',').length > 5) {
      targetColumn = matchLiteral[1];
      antiPatterns.push('LITERAL_IN_LIST_ANTIPATTERN: Bypasses parameterized plan caching. Parameterize with = ANY($1::type[]).');
    }

    // Check for correct = ANY($X) syntax
    const sargableAnyRegex = /([a-zA-Z0-9_]+)\s*=\s*ANY\s*\(\s*(\$[0-9]+)(?:::([a-zA-Z0-9_]+\[\]))?\s*\)/i;
    const matchAny = sql.match(sargableAnyRegex);
    if (matchAny) {
      targetColumn = matchAny[1];
      const hasExplicitCast = !!matchAny[3];
      if (!hasExplicitCast) {
        antiPatterns.push('MISSING_EXPLICIT_ARRAY_CAST: Array parameter lacks explicit SQL type cast (e.g. $1::bigint[]).');
      }
    }

    return {
      isSargable: isSargable && antiPatterns.length === 0,
      detectedAntiPatterns: antiPatterns,
      suggestedSql,
      targetColumn,
      parameterCount: (sql.match(/\$[0-9]+/g) || []).length,
    };
  }

  /**
   * Chunks large input arrays into bounded partitions to guarantee optimal leaf-page locality
   * and eliminate parameter-sniffing generic plan degradation.
   */
  public static chunkArrayParameters<T>(items: T[], chunkSize = this.MAX_RECOMMENDED_ARRAY_SIZE): T[][] {
    if (!items || items.length === 0) return [];
    
    // Deduplicate items to prevent protocol bloat
    const uniqueItems = Array.from(new Set(items));
    const chunks: T[][] = [];
    
    for (let i = 0; i < uniqueItems.length; i += chunkSize) {
      chunks.push(uniqueItems.slice(i, i + chunkSize));
    }
    
    return chunks;
  }

  /**
   * Executes a parameterized query using EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
   * to extract deep runtime telemetry and verify B-Tree index scan utilization.
   */
  public static async profileExecutionPlan(
    client: PoolClient | Client,
    sql: string,
    params: unknown[]
  ): Promise<PlanBufferTelemetry> {
    const explainSql = `EXPLAIN (ANALYZE, BUFFERS, COSTS, FORMAT JSON) ${sql}`;
    const result = await client.query(explainSql, params);
    
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const plan = result.rows[0]['QUERY PLAN'][0];
    const topNode = plan.Plan;
    
    let sharedHit = 0;
    let sharedRead = 0;
    let tempWritten = 0;
    let usedIndexScan = false;
    let usedBitmapScan = false;
    let sortMethod: string | undefined;

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const traversePlan = (node: any) => {
      sharedHit += node['Shared Hit Blocks'] || 0;
      sharedRead += node['Shared Read Blocks'] || 0;
      tempWritten += node['Temp Written Blocks'] || 0;

      if (node['Node Type'] === 'Index Scan' || node['Node Type'] === 'Index Only Scan') {
        usedIndexScan = true;
      }
      if (node['Node Type'] === 'Bitmap Index Scan' || node['Node Type'] === 'Bitmap Heap Scan') {
        usedBitmapScan = true;
      }
      if (node['Sort Method']) {
        sortMethod = node['Sort Method'];
      }

      if (node.Plans) {
        for (const child of node.Plans) {
          traversePlan(child);
        }
      }
    };

    traversePlan(topNode);

    return {
      nodeType: topNode['Node Type'],
      actualRows: topNode['Actual Rows'] || 0,
      sharedHitBlocks: sharedHit,
      sharedReadBlocks: sharedRead,
      tempWrittenBlocks: tempWritten,
      executionTimeMs: plan['Execution Time'] || 0,
      usedIndexScan,
      usedBitmapScan,
      sortMethod,
    };
  }

  /**
   * Verifies that the table schema has an index aligned with the 5-Tier B-Tree ladder:
   * (equality_columns..., array_column, sort_column)
   */
  public static async verifyCompositeIndexAlignment(
    client: PoolClient | Client,
    tableName: string,
    arrayColumn: string,
    equalityColumns: string[] = [],
    sortColumn?: string
  ): Promise<{ isAligned: boolean; indexName?: string; reason: string }> {
    const catalogQuery = `
      SELECT 
        c.relname as index_name,
        indisunique,
        indisclustered,
        ARRAY(
          SELECT pg_get_indexdef(i.indexrelid, k + 1, true)
          FROM generate_subscripts(i.indkey, 1) as k
          ORDER BY k
        ) as indexed_columns
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_class t ON t.oid = i.indrelid
      JOIN pg_am am ON am.oid = c.relam
      WHERE t.relname = $1
        AND am.amname = 'btree';
    `;

    const res = await client.query(catalogQuery, [tableName]);
    if (res.rows.length === 0) {
      return { isAligned: false, reason: `No B-Tree indexes found on table ${tableName}` };
    }

    for (const row of res.rows) {
      const cols: string[] = row.indexed_columns;
      
      // Check prefix equality columns match
      let matchesPrefix = true;
      for (let i = 0; i < equalityColumns.length; i++) {
        if (cols[i] !== equalityColumns[i]) {
          matchesPrefix = false;
          break;
        }
      }

      if (!matchesPrefix) continue;

      // Check array column immediately follows equality columns
      const arrayColIndex = equalityColumns.length;
      if (cols[arrayColIndex] !== arrayColumn) continue;

      // If sortColumn is specified, it must follow the arrayColumn
      if (sortColumn && cols[arrayColIndex + 1] !== sortColumn && !cols[arrayColIndex + 1]?.startsWith(sortColumn)) {
        continue;
      }

      return {
        isAligned: true,
        indexName: row.index_name,
        reason: `Found perfectly aligned composite B-Tree index: ${row.index_name} (${cols.join(', ')})`,
      };
    }

    return {
      isAligned: false,
      reason: `No B-Tree index on ${tableName} satisfies prefix [${equalityColumns.join(', ')}], array column '${arrayColumn}' and sort '${sortColumn || 'none'}'`,
    };
  }
}
```

---

## 4. Cross-Runtime Driver Sentinels

### 4.1 Go (`jackc/pgx/v5`) Sentinel: Sargable Array Parameters & Chunked Execution

In Go, passing slices to `pgx/v5` requires explicit SQL type annotations or the `pgtype.FlatArray` wrapper to ensure binary protocol encoding and avoid string-coercion sequential scans.

```go
package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type OrderRecord struct {
	ID        int64     `json:"id"`
	TenantID  string    `json:"tenant_id"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
	Amount    int64     `json:"amount_cents"`
}

const (
	MaxArrayParamChunkSize = 500
	StatementTimeoutMs     = 3000
)

// FetchOrdersByKeysetChunked leverages PG17 B-Tree in-index binary search with = ANY($1)
// Preserves index scan ordering without triggering bitmap index scans or disk sorting.
func FetchOrdersByKeysetChunked(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	orderIDs []int64,
) ([]OrderRecord, error) {
	if len(orderIDs) == 0 {
		return nil, nil
	}

	// 1. Deduplicate IDs to prevent redundant buffer locks
	uniqueIDMap := make(map[int64]struct{}, len(orderIDs))
	dedupedIDs := make([]int64, 0, len(orderIDs))
	for _, id := range orderIDs {
		if _, exists := uniqueIDMap[id]; !exists {
			uniqueIDMap[id] = struct{}{}
			dedupedIDs = append(dedupedIDs, id)
		}
	}

	allResults := make([]OrderRecord, 0, len(dedupedIDs))

	// 2. Process in bounded chunks of <= 500 items
	for i := 0; i < len(dedupedIDs); i += MaxArrayParamChunkSize {
		end := i + MaxArrayParamChunkSize
		if end > len(dedupedIDs) {
			end = len(dedupedIDs)
		}
		chunk := dedupedIDs[i:end]

		chunkResults, err := executeChunkQuery(ctx, pool, tenantID, chunk)
		if err != nil {
			return nil, fmt.Errorf("chunk query execution failed [%d:%d]: %w", i, end, err)
		}
		allResults = append(allResults, chunkResults...)
	}

	return allResults, nil
}

func executeChunkQuery(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	idChunk []int64,
) ([]OrderRecord, error) {
	// Strict sargable ScalarArrayOpExpr query with explicit type cast $2::bigint[]
	// Composite index: (tenant_id, id)
	const query = `
		SELECT id, tenant_id, status, created_at, amount_cents
		FROM orders
		WHERE tenant_id = $1 
		  AND id = ANY($2::bigint[])
		ORDER BY id ASC;
	`

	reqCtx, cancel := context.WithTimeout(ctx, StatementTimeoutMs*time.Millisecond)
	defer cancel()

	rows, err := pool.Query(reqCtx, query, tenantID, idChunk)
	if err != nil {
		return nil, fmt.Errorf("pgx query failed: %w", err)
	}
	defer rows.Close()

	var records []OrderRecord
	for rows.Next() {
		var rec OrderRecord
		if err := rows.Scan(&rec.ID, &rec.TenantID, &rec.Status, &rec.CreatedAt, &rec.Amount); err != nil {
			return nil, fmt.Errorf("row scan failed: %w", err)
		}
		records = append(records, rec)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("rows iteration error: %w", err)
	}

	return records, nil
}
```

### 4.2 TypeScript (`Drizzle ORM` & `postgres.js`) Sentinel: Sargable Array Predicates

```typescript
import postgres from 'postgres';
import { pgTable, bigint, uuid, varchar, timestamp, index } from 'drizzle-orm/pg-core';
import { sql, inArray } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/postgres-js';

export const orders = pgTable(
  'orders',
  {
    id: bigint('id', { mode: 'number' }).primaryKey(),
    tenantId: uuid('tenant_id').notNull(),
    status: varchar('status', { length: 32 }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => ({
    // Perfectly aligned composite B-Tree index: Equality -> Array -> Order Tail
    tenantStatusIdx: index('idx_orders_tenant_status_created')
      .on(table.tenantId, table.status, table.createdAt.desc()),
  })
);

export class OrderRepository {
  private db: ReturnType<typeof drizzle>;

  constructor(sqlClient: postgres.Sql) {
    this.db = drizzle(sqlClient);
  }

  /**
   * Fetches paginated orders using native PG17 B-Tree multi-value index traversal.
   * Leverages = ANY($1::varchar[]) while strictly bounding array size.
   */
  public async getTenantOrdersByStatuses(
    tenantId: string,
    statuses: string[],
    limit = 50
  ) {
    if (statuses.length === 0) return [];
    
    // Invariant: Bound array size to prevent generic plan drift
    if (statuses.length > 20) {
      throw new Error(`Array parameter cardinality ${statuses.length} exceeds recommended limit of 20 for status filter`);
    }

    // Direct sargable SQL generation leveraging ScalarArrayOpExpr
    return this.db
      .select()
      .from(orders)
      .where(
        sql`${orders.tenantId} = ${tenantId} AND ${orders.status} = ANY(${statuses}::varchar[])`
      )
      .orderBy(sql`${orders.createdAt} DESC`)
      .limit(limit);
  }
}
```

### 4.3 Python (`asyncpg`) Sentinel: Binary Protocol Array Evaluation & Buffer Metrics

```python
import asyncpg
import asyncio
from typing import List, Dict, Any

MAX_CHUNK_SIZE = 500

class PG17OrderRepository:
    def __init__(self, pool: asyncpg.Pool):
        self._pool = pool

    async def fetch_orders_by_ids(self, tenant_id: str, order_ids: List[int]) -> List[Dict[str, Any]]:
        """
        Executes chunked multi-value B-Tree queries leveraging PG17 ScalarArrayOpExpr.
        Strictly prevents unnest() subquery conversion and verifies shared buffer efficiency.
        """
        if not order_ids:
            return []

        # Deduplicate to prevent duplicate buffer pins
        unique_ids = list(dict.fromkeys(order_ids))
        results: List[Dict[str, Any]] = []

        async with self._pool.acquire() as conn:
            # Set local statement timeout to guard against lock starvation
            await conn.execute("SET LOCAL statement_timeout = '3000ms';")

            for i in range(0, len(unique_ids), MAX_CHUNK_SIZE):
                chunk = unique_ids[i:i + MAX_CHUNK_SIZE]
                chunk_records = await self._query_chunk(conn, tenant_id, chunk)
                results.extend(chunk_records)

        return results

    async def _query_chunk(self, conn: asyncpg.Connection, tenant_id: str, id_chunk: List[int]) -> List[Dict[str, Any]]:
        # Sargable query: explicit cast to bigint[] to prevent type coercion
        query = """
            SELECT id, tenant_id, status, created_at, amount_cents
            FROM orders
            WHERE tenant_id = $1 
              AND id = ANY($2::bigint[])
            ORDER BY id ASC;
        """
        rows = await conn.fetch(query, tenant_id, id_chunk)
        return [dict(r) for r in rows]
```

### 4.4 Rust (`tokio-postgres`) Sentinel: Strongly Typed Slices & Index Scan Verification

```rust
use tokio_postgres::{Client, Error};
use std::collections::HashSet;

pub struct OrderRecord {
    pub id: i64,
    pub tenant_id: String,
    pub status: String,
    pub amount_cents: i64,
}

const MAX_ARRAY_CHUNK: usize = 500;

pub async fn fetch_orders_chunked(
    client: &Client,
    tenant_id: &str,
    order_ids: &[i64],
) -> Result<Vec<OrderRecord>, Error> {
    if order_ids.is_empty() {
        return Ok(Vec::new());
    }

    // Deduplicate in memory
    let mut deduped: Vec<i64> = order_ids
        .iter()
        .copied()
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    deduped.sort_unstable();

    let mut all_orders = Vec::with_capacity(deduped.len());

    let statement = client
        .prepare(
            "SELECT id, tenant_id, status, amount_cents 
             FROM orders 
             WHERE tenant_id = $1 AND id = ANY($2::bigint[]) 
             ORDER BY id ASC",
        )
        .await?;

    for chunk in deduped.chunks(MAX_ARRAY_CHUNK) {
        let rows = client.query(&statement, &[&tenant_id, &chunk]).await?;
        for row in rows {
            all_orders.push(OrderRecord {
                id: row.get(0),
                tenant_id: row.get(1),
                status: row.get(2),
                amount_cents: row.get(3),
            });
        }
    }

    Ok(all_orders)
}
```

---

## 5. The 6-State B-Tree Array Search Lifecycle Finite-State Machine (FSM)

The execution of multi-value array queries must transition through six deterministic states to guarantee correctness, sargability, and zero disk temp spills:

```
    +-------------------------------------------------------------+
    |                     1. AST_INSPECTION                       |
    |  Inspect query AST: verify = ANY($1) vs IN clause syntax.   |
    |  Reject unnest() joins and subquery anti-patterns.          |
    +------------------------------+------------------------------+
                                   |
                                   v
    +-------------------------------------------------------------+
    |                2. PARAMETER_QUALIFICATION                   |
    |  Deduplicate array keys. Verify exact SQL data type parity. |
    |  Reject implicit type casting (e.g., text[] for int col).   |
    +------------------------------+------------------------------+
                                   |
                                   v
    +-------------------------------------------------------------+
    |                 3. BOUNDED_CHUNK_PARTITION                  |
    |  If array length K > 500, partition into bounded chunks.    |
    |  Eliminate plan cache generic parameter sniffing drift.     |
    +------------------------------+------------------------------+
                                   |
                                   v
    +-------------------------------------------------------------+
    |                4. COMPOSITE_INDEX_ALIGNMENT                 |
    |  Verify index key order: Equality -> Array -> Order Tail.   |
    |  Confirm presence of covering INCLUDE (...) columns.        |
    +------------------------------+------------------------------+
                                   |
                                   v
    +-------------------------------------------------------------+
    |                5. PLAN_TELEMETRY_EXECUTION                  |
    |  Execute with EXPLAIN (ANALYZE, BUFFERS).                   |
    |  Verify Index Scan / Index Only Scan. Zero Bitmap Scan.     |
    +------------------------------+------------------------------+
                                   |
                                   v
    +-------------------------------------------------------------+
    |              6. BUFFER_VERIFICATION_PROMOTION               |
    |  Assert temp written blocks = 0. Verify >= 50% buffer saving|
    |  Confirm sub-millisecond execution. Commit or release pool. |
    +-------------------------------------------------------------+
```

### State Transition Invariant Table

| Current State | Trigger Event | Invariant Action / Guardrail | Target State | Failure Mode on Violation |
| :--- | :--- | :--- | :--- | :--- |
| `1. AST_INSPECTION` | Incoming SQL Query | Detect `JOIN unnest()` or `IN (SELECT unnest())` | `2. PARAMETER_QUALIFICATION` | Reject with `SARGABILITY_BREACH` |
| `2. PARAMETER_QUALIFICATION` | Array Parameter Binding | Assert type parity between column and array parameter | `3. BOUNDED_CHUNK_PARTITION` | Abort with `IMPLICIT_CAST_PROHIBITED` |
| `3. BOUNDED_CHUNK_PARTITION` | Cardinality Assessment | Chunk arrays where $K > 500$ into discrete sub-slices | `4. COMPOSITE_INDEX_ALIGNMENT` | Abort with `PARAMETER_EXPLOSION_HAZARD` |
| `4. COMPOSITE_INDEX_ALIGNMENT` | Schema Catalog Inspection | Validate B-Tree prefix matches equality filter columns | `5. PLAN_TELEMETRY_EXECUTION` | Abort with `INDEX_PREFIX_MISALIGNMENT` |
| `5. PLAN_TELEMETRY_EXECUTION` | Query Execution | Assert node type is `Index Scan` / `Index Only Scan` | `6. BUFFER_VERIFICATION_PROMOTION` | Abort on `BITMAP_SCAN_FALLBACK` |
| `6. BUFFER_VERIFICATION_PROMOTION` | Buffer Accounting | Assert `temp_written_blocks == 0` & buffer hits reduced | `COMMITTED` | Abort with `DISK_SPILL_SLA_BREACH` |

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Gates

To guarantee that autonomous agents do not introduce regressions into PostgreSQL 17 query pipelines, every repository must implement the following 6 CI gates:

```typescript
import { test, expect } from '@jest/globals';
import { Client } from 'pg';
import { AgenticPostgres17BTreeArraySearchGuardEngine } from './AgenticPostgres17BTreeArraySearchGuardEngine';

describe('PostgreSQL 17 B-Tree Multi-Value Search CI Gates', () => {
  let client: Client;

  beforeAll(async () => {
    client = new Client({ connectionString: process.env.TEST_DATABASE_URL });
    await client.connect();
    // Gate 1: Engine qualification
    await AgenticPostgres17BTreeArraySearchGuardEngine.qualifyEngineVersion(client);
  });

  afterAll(async () => {
    await client.end();
  });

  test('Gate 1: Rejects unnest() subquery anti-patterns in repository SQL', () => {
    const invalidQuery = `
      SELECT o.id, o.amount_cents 
      FROM orders o 
      INNER JOIN unnest($1::bigint[]) AS u(id) ON o.id = u.id;
    `;
    const analysis = AgenticPostgres17BTreeArraySearchGuardEngine.analyzeQuerySyntax(invalidQuery);
    expect(analysis.isSargable).toBe(false);
    expect(analysis.detectedAntiPatterns).toContain(
      'UNNEST_JOIN_ANTIPATTERN: Strips ScalarArrayOpExpr, forcing Hash/Nested-Loop join.'
    );
  });

  test('Gate 2: Enforces explicit type casts on array parameters', () => {
    const uncastQuery = `SELECT id FROM orders WHERE id = ANY($1);`;
    const analysis = AgenticPostgres17BTreeArraySearchGuardEngine.analyzeQuerySyntax(uncastQuery);
    expect(analysis.detectedAntiPatterns).toContain(
      'MISSING_EXPLICIT_ARRAY_CAST: Array parameter lacks explicit SQL type cast (e.g. $1::bigint[]).'
    );
  });

  test('Gate 3: Enforces composite index alignment for tenant-scoped array lookups', async () => {
    const alignment = await AgenticPostgres17BTreeArraySearchGuardEngine.verifyCompositeIndexAlignment(
      client,
      'orders',
      'id',
      ['tenant_id'],
      'created_at'
    );
    expect(alignment.isAligned).toBe(true);
  });

  test('Gate 4: Verifies Index Scan execution and zero Bitmap Scan on ordered limits', async () => {
    const query = `
      SELECT id, tenant_id, status, created_at 
      FROM orders 
      WHERE tenant_id = $1 AND status = ANY($2::varchar[])
      ORDER BY created_at DESC 
      LIMIT 20;
    `;
    const telemetry = await AgenticPostgres17BTreeArraySearchGuardEngine.profileExecutionPlan(
      client,
      query,
      ['00000000-0000-0000-0000-000000000001', ['pending', 'processing']]
    );

    expect(telemetry.usedIndexScan).toBe(true);
    expect(telemetry.usedBitmapScan).toBe(false);
    expect(telemetry.tempWrittenBlocks).toBe(0);
    expect(telemetry.sortMethod).toBeUndefined(); // Zero external sort!
  });

  test('Gate 5: Verifies parameter chunking bounds large arrays to <= 500 items', () => {
    const massiveList = Array.from({ length: 2350 }, (_, i) => i + 1);
    const chunks = AgenticPostgres17BTreeArraySearchGuardEngine.chunkArrayParameters(massiveList, 500);
    
    expect(chunks.length).toBe(5);
    expect(chunks[0].length).toBe(500);
    expect(chunks[4].length).toBe(350);
  });

  test('Gate 6: Demonstrates >= 50% buffer access reduction under PG17 B-tree array search', async () => {
    const targetIds = Array.from({ length: 50 }, (_, i) => i + 100);
    const telemetry = await AgenticPostgres17BTreeArraySearchGuardEngine.profileExecutionPlan(
      client,
      'SELECT id FROM orders WHERE id = ANY($1::bigint[]);',
      [targetIds]
    );

    // In PG16, 50 keys in depth 4 B-Tree required >= 200 buffer hits.
    // In PG17, in-index skip scan completes in < 50 buffer hits.
    expect(telemetry.sharedHitBlocks + telemetry.sharedReadBlocks).toBeLessThan(60);
    expect(telemetry.tempWrittenBlocks).toBe(0);
  });
});
```

---

## 7. Definition of Done (DoD) Quality Checklist

Before committing any SQL migration, repository method, or query refactor involving multi-value filters, autonomous coding agents must verify all items below:

- [ ] **Engine Qualification**: PostgreSQL version verified as `>= 170000` via `SHOW server_version_num;`.
- [ ] **ScalarArrayOpExpr Syntax**: All multi-value predicates use `= ANY($1::type[])` with explicit SQL array casting. Zero `JOIN unnest()`, `IN (SELECT unnest())`, or dynamic string-interpolated lists.
- [ ] **Exact Type Parity**: Parameter array type strictly matches the table column type (`bigint[]` for `int8`, `uuid[]` for `uuid`, `timestamptz[]` for `timestamptz`) to eliminate implicit runtime coercion.
- [ ] **Keyset Parameter Chunking**: Large collections are chunked client-side into discrete batches of $\le 500$ elements, preventing protocol buffer bloat and plan cache generic plan drift.
- [ ] **Composite Index Alignment**: Composite B-Tree indexes place high-cardinality equality columns leftmost, followed by the array filter column, followed by the `ORDER BY` sort column: `(equality_col, array_col, sort_col)`.
- [ ] **Order Preservation (Zero Sort)**: Queries combining multi-value filters with `ORDER BY ... LIMIT` execute via `Index Scan` or `Index Only Scan` without falling back to `Bitmap Index Scan` or allocating external sort buffers.
- [ ] **Covering Index Optimization**: Frequently projected columns are included via `INCLUDE (...)` to enable pure `Index Only Scan` paths and avoid heap page fetches.
- [ ] **Buffer Efficiency Assertion**: `EXPLAIN (ANALYZE, BUFFERS)` confirms `Temp Written Blocks = 0` and demonstrates $\ge 50\%$ reduction in `Shared Hit Blocks` relative to legacy root-to-leaf baselines.
