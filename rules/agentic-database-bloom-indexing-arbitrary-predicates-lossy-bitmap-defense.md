---
description: PostgreSQL Bloom Indexing (CREATE EXTENSION bloom), multi-column equality query optimization, arbitrary subset predicate filtering, signature length calibration, bit allocation per column, lossy bitmap heap scan defense, and work_mem memory sizing across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{bloom,index,facet,equality,filter,bitmap,lossy,search,workmem,multivalue,predicate,sql,postgres,db,query}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Bloom Indexing, Multi-Column Equality Permutations, Arbitrary Subset Predicates & Lossy Bitmap Scan Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design multi-column filtering systems, faceted search engines, audit log query layers, and multi-tenant catalog lookups across PostgreSQL (11–17+) in Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Combinatorial B-Tree Index Explosion Catastrophe" (where tables with 8–15 filterable attributes require dozens of composite B-Tree indexes to satisfy arbitrary subset equality queries, ballooning disk storage by $15\times$ and collapsing write throughput under massive index maintenance locks), the "Leftmost Prefix B-Tree Abandonment Cliff" (where queries filtering on non-leading columns silently abandon composite B-Tree indexes and revert to 45-second sequential scans across 50 million rows), the "Uncalibrated Bit-Length & Hash Collision False-Positive Storm" (where default 80-bit Bloom signatures saturate under high-cardinality keys, causing false-positive collision rates $> 40\%$ and forcing Bitmap Heap Scans to re-evaluate millions of irrelevant disk pages), the "Non-Sargable Range Query Trap" (where agents apply `<`, `>`, `BETWEEN`, or `ILIKE` predicates against Bloom indexes, triggering silent planner index abandonment), the "`work_mem` Bitmap Heap Scan Degradation to Lossy Pages" (where undersized `work_mem` forces PostgreSQL to convert exact tuple TID bitmaps into lossy page-level bitmaps, inducing $100\%$ tuple rechecks and CPU spikes), and the "Dead Signature Accumulation & Vacuum Starvation Bloat" (where in-place row updates leave dead signatures in Bloom pages without automatic compaction) by establishing a strict 5-Tier Bloom Index Governance Ladder, mathematical false-positive probability models, optimal entropy bit-allocation calculus, a production-ready TypeScript `AgenticBloomIndexGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state optimization lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Bloom Indexing Catastrophes vs The 5-Tier Governance Ladder

In relational databases, applications frequently present users with multi-faceted search interfaces: e-commerce product catalogs, security audit trails, analytics dashboards, and customer filtering tools. These interfaces allow clients to query arbitrary subsets of $N$ columns (e.g., `tenant_id`, `category_id`, `status`, `country_code`, `vendor_id`, `priority`, `channel`).

With standard **B-Tree indexes**, a composite index `(col1, col2, col3)` can only be used effectively if the query provides a filter on the leftmost column (`col1`). To support queries filtering on any arbitrary combination of $N$ columns, an engineer or autonomous coding agent would theoretically need $\mathcal{O}(2^N)$ B-Tree index permutations!

PostgreSQL provides the official **`bloom` extension** (`CREATE EXTENSION bloom;`), which implements an index access method based on space-efficient Bloom filters:
1. **Signature-Based Indexing**: Each index tuple contains a bit signature of fixed length $M$ (default 80 bits, configurable up to 4096 bits).
2. **Deterministic Bit Hashing**: For each column value, $k_i$ bits are deterministically set in the signature using a 32-bit hash function. When multiple columns have values, their individual bit patterns are superimposed using bitwise OR ($\lor$).
3. **Arbitrary Subset Querying**: When a query specifies equality constraints (`=`) on any subset of indexed columns $Q \subseteq \{1 \dots N\}$, PostgreSQL constructs a query bitmask and scans the Bloom index using a **Bitmap Index Scan**. Any index tuple whose signature contains all 1-bits of the query mask is treated as a candidate match.
4. **Bitmap Heap Scan Recheck**: Because different values can hash to overlapping bit positions (false positives), the candidate heap pages are visited during a **Bitmap Heap Scan**, and PostgreSQL evaluates the exact `Recheck Cond` to discard false-positive tuples.

Autonomous coding agents routinely fail to configure and tune Bloom indexes, triggering catastrophic production failures:

### The 6 Bloom Indexing Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                         THE 6 BLOOM INDEXING CATASTROPHES                                          |
+------------------------------------+---------------------------------------------------------------+
| 1. Combinatorial B-Tree Explosion  | Creating 12 composite B-Trees to satisfy multi-facet queries; |
|    (The 2^N Permutations Trap)     | burns 80GB of disk space and degrades write TPS by 85%!       |
+------------------------------------+---------------------------------------------------------------+
| 2. Leftmost Prefix Abandonment     | Query filters on (status, country) but B-Tree starts with     |
|    (The Non-Prefix Scan Cliff)     | tenant_id; planner abandons index, triggering 45s Seq Scan!   |
+------------------------------------+---------------------------------------------------------------+
| 3. Uncalibrated Signature Storm    | Default 80-bit length used on high-cardinality UUIDs/IDs;     |
|    (False-Positive Collision Spasm)| Bloom signature saturates (all 1s), producing 65% false      |
|                                    | positives and thrashing disk IO during Bitmap Heap Recheck!   |
+------------------------------------+---------------------------------------------------------------+
| 4. Non-Sargable Range Query Trap   | Agent issues WHERE created_at >= $1 on Bloom index; Bloom     |
|    (Silent Index Rejection)        | only supports equality (=); query silently drops to Seq Scan! |
+------------------------------------+---------------------------------------------------------------+
| 5. work_mem Bitmap Lossy Spillover | Bitmap exceeds work_mem; PostgreSQL downgrades exact TID      |
|    (Exact-to-Lossy Page Recheck)   | bitmap to lossy page pointers, forcing full-page rechecks!    |
+------------------------------------+---------------------------------------------------------------+
| 6. Dead Signature Vacuum Bloat     | High UPDATE/DELETE churn accumulates dead signatures; Bloom   |
|    (Non-Compacting Page Bloat)     | lacks in-place compaction, requiring explicit scheduled VACUUM|
+------------------------------------+---------------------------------------------------------------+
```

### Catastrophic Code Anti-Patterns

#### Anti-Pattern 1: The Combinatorial B-Tree Permutation Trap
```sql
-- CATASTROPHIC: Agent attempts to satisfy 6 multi-facet filter columns
-- with a sprawl of composite B-Tree indexes!
-- Result: 6 separate 8GB B-Tree indexes = 48GB storage waste, massive INSERT lock contention
CREATE INDEX idx_orders_t_c_s ON orders (tenant_id, category_id, status);
CREATE INDEX idx_orders_s_c_r ON orders (status, country_code, region);
CREATE INDEX idx_orders_c_v_p ON orders (category_id, vendor_id, priority);
CREATE INDEX idx_orders_t_v_s ON orders (tenant_id, vendor_id, status);
CREATE INDEX idx_orders_r_s_p ON orders (region, status, priority);
-- And a query filtering on (category_id, country_code) STILL triggers a Sequential Scan!
```

#### Anti-Pattern 2: The Default 80-Bit Uncalibrated Bloom Index
```sql
-- CATASTROPHIC: Creating a Bloom index with default length (80 bits) and default 2 bits/col
-- across 7 columns including high-cardinality UUIDs and IDs!
CREATE EXTENSION IF NOT EXISTS bloom;

CREATE INDEX idx_events_bloom ON events USING bloom (
    tenant_id,    -- high cardinality (100,000 distinct)
    user_id,      -- high cardinality (1,000,000 distinct)
    action_type,  -- low cardinality (20 distinct)
    resource_id,  -- high cardinality (500,000 distinct)
    status,       -- low cardinality (5 distinct)
    country_code, -- low cardinality (150 distinct)
    device_type   -- low cardinality (10 distinct)
);
-- Result: With only 80 bits total, 7 columns saturate the signature bitmask with 1s.
-- P(false positive) exceeds 50%! Bitmap Heap Scan reads virtually every heap page!
```

#### Anti-Pattern 3: Non-Sargable Predicates on Bloom Indexes
```sql
-- CATASTROPHIC: Bloom indexes ONLY support the equality operator (=).
-- Autonomous agent writes range, inequality, or pattern matches:
SELECT * FROM audit_logs 
WHERE tenant_id = 't_123' 
  AND created_at >= '2025-01-01'  -- RANGE PREDICATE! Bloom CANNOT evaluate this!
  AND action ILIKE 'LOGIN%';       -- PATTERN PREDICATE! Bloom CANNOT evaluate this!
-- Result: Query planner drops the Bloom index entirely; reverts to 50M-row Seq Scan!
```

---

## 2. Mathematical Models & Formal Verification: False Positive Probability, Signature Sizing & Bit Allocation Calculus

Bloom indexes rely on hash representations. To prevent the false-positive storm and memory degradation, agents must calibrate parameters using formal mathematics.

### Theorem 1 (Bloom Filter False Positive Probability Calculus)

Let $M$ be the total signature length in bits ($80 \le M \le 4096$, must be a multiple of 16). Let $m$ be the total number of indexed columns, and let $k_i$ be the number of bits set for column $i$ ($1 \le k_i \le 64$).

When a tuple is inserted, the total number of bits set into the signature $S_{\text{tuple}}$ is at most:
$$K_{\text{total}} = \sum_{i=1}^{m} k_i$$

Assuming independent uniform hash distributions, the probability that any specific bit in the signature is still 0 after all $m$ column values are hashed is:
$$p_0 = \left( 1 - \frac{1}{M} \right)^{K_{\text{total}}} \approx e^{-\frac{K_{\text{total}}}{M}}$$

Therefore, the fraction of bits set to 1 in a typical stored signature is:
$$p_1 = 1 - p_0 \approx 1 - e^{-\frac{K_{\text{total}}}{M}}$$

When a query supplies equality predicates for a subset of columns $Q \subseteq \{1 \dots m\}$, the query signature sets $K_Q = \sum_{j \in Q} k_j$ bits. An unrelated stored tuple will falsely match the query signature if and only if all $K_Q$ bit positions are already set to 1 in its stored signature:

$$P_{\text{fp}}(Q) = (p_1)^{K_Q} \approx \left( 1 - e^{-\frac{\sum_{i=1}^m k_i}{M}} \right)^{\sum_{j \in Q} k_j}$$

To minimize the false-positive collision rate, the total fraction of set bits $p_1$ should ideally satisfy the Shannon entropy condition $p_1 \approx 0.5$, which yields:
$$K_{\text{total}} \approx M \cdot \ln(2) \approx 0.693 \cdot M$$

If $K_{\text{total}} \gg M \cdot \ln(2)$, the signature becomes **saturated** ($p_1 \to 1.0$), driving $P_{\text{fp}} \to 100\%$ and destroying index selectivity!

### Theorem 2 (Optimal Bit Allocation per Column Entropy Theorem)

In a multi-attribute table, columns have vastly different cardinalities (number of distinct values $N_i = \text{n\_distinct}$). Allocating a uniform $k_i = 2$ bits to all columns wastes bits on low-cardinality status flags while starving high-cardinality identifiers.

The information entropy of column $i$ is:
$$H(C_i) = \log_2(N_i)$$

The mathematically optimal bit allocation $k_i$ allocates bits proportionally to column entropy $H(C_i)$, bounded by PostgreSQL's Bloom limits ($2 \le k_i \le 64$):

$$k_i = \max\left(2, \min\left(64, \text{round}\left( \frac{\log_2(N_i)}{\sum_{j=1}^m \log_2(N_j)} \cdot (M \cdot \ln 2) \right)\right)\right)$$

Subject to the signature length constraint:
$$\sum_{i=1}^m k_i \le M \cdot \ln 2 \approx 0.693 \cdot M$$

### Theorem 3 (`work_mem` Bitmap Exact-to-Lossy Degradation Invariant)

When PostgreSQL executes a Bloom query, it generates an in-memory **TID Bitmap**:
1. **Exact Bitmap**: Stores the exact physical item pointers (`ItemPointerData`, 6 bytes per tuple) of candidate rows.
2. **Lossy Bitmap**: If the memory required to store exact TIDs exceeds `work_mem`, PostgreSQL dynamically degrades the bitmap into a page-level bit array (1 bit per 8KB page). When reading a lossy page, PostgreSQL **must evaluate every single tuple on that page** against the query predicate!

Let $N_{\text{cand}}$ be the expected number of candidate matching tuples, and let $P_{\text{touched}}$ be the number of touched 8KB heap pages:
$$\text{Mem}_{\text{exact}} = N_{\text{cand}} \times 6\text{ bytes} + P_{\text{touched}} \times 8\text{ bytes}$$

To guarantee that the Bitmap Index Scan **NEVER degrades to lossy mode**, the session or transaction must guarantee:
$$\text{work\_mem} \ge \gamma \cdot \left( N_{\text{cand}} \times 6 + P_{\text{touched}} \times 8 \right), \quad \gamma \ge 1.5$$

If `Lossy: > 0` appears in `EXPLAIN (ANALYZE, BUFFERS)`, the query has suffered a **Lossy Degradation Disaster**, increasing CPU instruction count by up to $10\times$.

### Theorem 4 (Storage & Write Amplification Reduction Ratio)

Comparing a single calibrated Bloom index covering $m$ columns against $C$ composite B-Tree indexes:
$$\mathcal{R}_{\text{storage}} = \frac{S_{\text{bloom}}}{\sum_{j=1}^{C} S_{\text{btree}, j}} \le \frac{1}{C} \times \frac{M / 8 + 8}{\text{avg\_tuple\_size}_{\text{btree}}}$$

For an 8-column faceted catalog table with 20 million rows:
- 6 composite B-Trees require $\approx 42\text{GB}$.
- 1 calibrated Bloom index ($M = 256$ bits) requires $\approx 2.4\text{GB}$.
- Storage reduction: $\mathcal{R}_{\text{storage}} \approx \frac{2.4}{42} = 5.7\%$ (a $94.3\%$ space savings!).
- Insert write amplification reduced from 6 index writes to 1 index write per inserted tuple!

---

## 3. The 5-Tier Bloom Index Governance Ladder

```
+----------------------------------------------------------------------------------------------------+
|                         THE 5-TIER BLOOM INDEX GOVERNANCE LADDER                                   |
+------------------------------------+---------------------------------------------------------------+
| Tier 4: CI & Vacuum Sentinels      | Continuous idx_scan verification, bloat auditing, scheduled   |
|                                    | VACUUM compaction, zero-spill EXPLAIN gates (Lossy: 0).      |
+------------------------------------+---------------------------------------------------------------+
| Tier 3: Hybrid Index Topology      | Segregate equality facets to Bloom; reserve B-Trees for PKs,  |
|                                    | UNIQUE constraints, and monotonic temporal range filters.     |
+------------------------------------+---------------------------------------------------------------+
| Tier 2: work_mem Lossless Fencing  | Dynamic transaction work_mem budgeting guaranteeing Exact     |
|                                    | Bitmap Scans with zero Lossy page downgrades.                 |
+------------------------------------+---------------------------------------------------------------+
| Tier 1: Entropy & Bit Allocation   | Explicit length = M (256-1024) and per-column bits col_i = k |
|                                    | derived from column entropy H(C_i) = log2(n_distinct).        |
+------------------------------------+---------------------------------------------------------------+
| Tier 0: Operator Sargability Base  | Strict ban on range (<, >, BETWEEN) or LIKE on Bloom indexes; |
|                                    | enforce 100% equality (=) predicates and extension loading.   |
+------------------------------------+---------------------------------------------------------------+
```

### Tier 0: Operator Sargability Base
- **Equality Invariant**: Bloom indexes can evaluate **only** the `=` (equality) operator. Never create a Bloom index expecting it to optimize range filters (`<`, `>`, `<=`, `>=`), pattern matching (`LIKE`, `ILIKE`, `~`), or null tests (`IS NULL` unless explicitly converted).
- **Extension Assurance**: Always execute `CREATE EXTENSION IF NOT EXISTS bloom;` before defining Bloom indexes.
- **Data Type Compatibility**: Verify that all indexed columns have a default bloom opclass (supports `int2`, `int4`, `int8`, `float4`, `float8`, `timestamp`, `timestamptz`, `date`, `text`, `varchar`, `uuid`).

### Tier 1: Column Entropy Profiling & Signature Calibration
- **Ban Default Sizing**: Never use bare `USING bloom (col1, col2, ...)` without explicit `WITH (length = ..., col1 = ..., ...)`.
- **Signature Length $M$**: Sized between 256 and 1024 bits based on column count and expected subset queries:
  - 4–6 columns: `length = 256`
  - 7–10 columns: `length = 512`
  - 11–16 columns: `length = 1024`
- **Bit Budget**: Set $k_i$ per column such that $\sum k_i \approx 0.693 \cdot M$. High-cardinality keys receive 10–32 bits; low-cardinality status flags receive 2–4 bits.

### Tier 2: `work_mem` Dynamic Lossless Fencing
- Before running multi-facet equality queries, verify that `work_mem` is budgeted to keep the Bitmap Index Scan in **Exact** mode (`Lossy: 0`).
- Analytical and dashboard sessions must set `SET LOCAL work_mem = '64MB'` or compute dynamic memory based on candidate selectivity.

### Tier 3: Hybrid Architecture: Bloom for Facets, B-Tree for Ranges
- Do not attempt to replace primary keys, unique constraints, or foreign keys with Bloom indexes.
- Isolate equality search columns to a single Bloom index, and pair with single-column B-Trees for range columns (e.g., `created_at` timestamp). PostgreSQL's optimizer will combine them via `BitmapAnd`:
  - `BitmapIndexScan on idx_orders_bloom` (evaluates facets)
  - `BitmapIndexScan on idx_orders_created_at_btree` (evaluates range)
  - `BitmapAnd` $\to$ `BitmapHeapScan` (single composite lookup!)

### Tier 4: Autonomous Telemetry & Vacuum Maintenance Sentinel
- Bloom indexes do not prune dead signatures during ordinary row updates. Regular `VACUUM` (or autovacuum with calibrated scale factor `autovacuum_vacuum_scale_factor = 0.05`) must be enforced to prevent signature degradation.
- Continuously monitor `pg_stat_user_indexes` where `indexrelname LIKE '%_bloom'` to verify `idx_scan > 0`. If `idx_scan == 0`, audit application queries for non-equality predicates or planner cost miscalibration.

---

## 4. Production TypeScript Reference Implementation: `AgenticBloomIndexGuardEngine`

The following production engine validates table columns, computes mathematically optimal Bloom signature lengths and per-column bit allocations, detects anti-patterns, generates zero-downtime DDL, and audits execution plans:

```typescript
// src/db/guardrails/AgenticBloomIndexGuardEngine.ts

export interface ColumnEntropyProfile {
  name: string;
  dataType: string;
  nDistinct: number; // Estimated distinct values from pg_stats
  isEqualityFiltered: boolean;
  isRangeFiltered: boolean;
}

export interface BloomIndexConfig {
  tableName: string;
  indexName: string;
  signatureLength: number; // M bits (multiple of 16, e.g. 256, 512, 1024)
  columnBits: Record<string, number>; // col_name -> k_i bits
}

export interface BloomAuditResult {
  valid: boolean;
  signatureLength: number;
  totalBitsAllocated: number;
  saturationRatio: number;
  theoreticalFalsePositiveRate: number; // for a 2-column query subset
  columnAllocations: Record<string, number>;
  warnings: string[];
  generatedDDL: string;
}

export class AgenticBloomIndexGuardEngine {
  /**
   * Calculates mathematically optimal Bloom filter parameters based on column entropy
   * and verifies that no range-filtered columns are included.
   */
  public static designBloomIndex(
    tableName: string,
    indexName: string,
    columns: ColumnEntropyProfile[],
    options: { targetFalsePositiveRate?: number; maxSignatureLength?: number } = {}
  ): BloomAuditResult {
    const warnings: string[] = [];
    const maxM = options.maxSignatureLength ?? 1024;
    const targetFPR = options.targetFalsePositiveRate ?? 0.01;

    // 1. Validate Operator Eligibility (Tier 0)
    for (const col of columns) {
      if (col.isRangeFiltered) {
        warnings.push(
          `Column '${col.name}' is queried with range/inequality operators (<, >, BETWEEN). ` +
          `Bloom indexes ONLY support equality (=). Segregate '${col.name}' to a separate B-Tree!`
        );
      }
    }

    const equalityCols = columns.filter((c) => c.isEqualityFiltered);
    if (equalityCols.length < 2) {
      warnings.push(
        `Table '${tableName}' has only ${equalityCols.length} equality columns. ` +
        `Bloom indexes are optimized for multi-column arbitrary subsets (>= 3 columns). ` +
        `Prefer standard B-Tree for 1-2 columns.`
      );
    }

    // 2. Select Signature Length M (multiple of 16)
    let M = 256;
    if (equalityCols.length >= 10 || equalityCols.some((c) => c.nDistinct > 100_000)) {
      M = Math.min(1024, maxM);
    } else if (equalityCols.length >= 6 || equalityCols.some((c) => c.nDistinct > 10_000)) {
      M = Math.min(512, maxM);
    }

    // Target total bits K_total = M * ln(2) for maximum Shannon entropy
    const targetTotalBits = Math.floor(M * Math.LN2);

    // 3. Compute Entropy Weights: H(C_i) = log2(nDistinct)
    const logDistArray = equalityCols.map((col) => {
      const distinct = Math.max(2, col.nDistinct > 0 ? col.nDistinct : 100);
      return Math.log2(distinct);
    });
    const totalEntropy = logDistArray.reduce((acc, val) => acc + val, 0);

    // 4. Allocate Bits per Column
    const columnAllocations: Record<string, number> = {};
    let allocatedSum = 0;

    for (let i = 0; i < equalityCols.length; i++) {
      const col = equalityCols[i];
      const entropyFraction = logDistArray[i] / totalEntropy;
      // Raw allocation
      let bits = Math.round(entropyFraction * targetTotalBits);
      // Hard clamp between 2 and 64 (PostgreSQL bloom limits)
      bits = Math.max(2, Math.min(64, bits));
      columnAllocations[col.name] = bits;
      allocatedSum += bits;
    }

    // Normalize if allocatedSum exceeds M * 0.85
    if (allocatedSum > M * 0.85) {
      warnings.push(
        `Total allocated bits (${allocatedSum}) exceeds 85% of signature length (${M}). ` +
        `Elevating signature length to prevent saturation.`
      );
      M = Math.min(maxM, Math.ceil(allocatedSum / 0.693 / 16) * 16);
    }

    const saturationRatio = allocatedSum / M;

    // Theoretical False Positive Rate for a typical 2-column query subset
    const avgSubsetBits = (allocatedSum / equalityCols.length) * 2;
    const p1 = 1 - Math.exp(-allocatedSum / M);
    const theoreticalFPR = Math.pow(p1, avgSubsetBits);

    if (theoreticalFPR > targetFPR * 2) {
      warnings.push(
        `Theoretical false positive rate (${(theoreticalFPR * 100).toFixed(2)}%) ` +
        `exceeds target (${(targetFPR * 100).toFixed(2)}%). Consider elevating M to ${M * 2}.`
      );
    }

    // 5. Generate Zero-Downtime Hardened DDL
    const colParams = equalityCols
      .map((col, idx) => `col${idx + 1} = ${columnAllocations[col.name]}`)
      .join(', ');

    const colList = equalityCols.map((c) => c.name).join(', ');
    const ddl = [
      `-- Enable official bloom extension`,
      `CREATE EXTENSION IF NOT EXISTS bloom;`,
      ``,
      `-- Calibrated Bloom Index with entropy-proportional bit allocations`,
      `-- M = ${M} bits, Total bits = ${allocatedSum}, Saturation = ${(saturationRatio * 100).toFixed(1)}%`,
      `CREATE INDEX CONCURRENTLY IF NOT EXISTS ${indexName}`,
      `ON ${tableName} USING bloom (${colList})`,
      `WITH (length = ${M}, ${colParams});`,
    ].join('\n');

    return {
      valid: warnings.length === 0,
      signatureLength: M,
      totalBitsAllocated: allocatedSum,
      saturationRatio,
      theoreticalFalsePositiveRate: theoreticalFPR,
      columnAllocations,
      warnings,
      generatedDDL: ddl,
    };
  }

  /**
   * Audits EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) execution plan to detect
   * lossy bitmap heap scans or missing bloom index usage.
   */
  public static auditExplainPlan(planJson: any): {
    usesBloomIndex: boolean;
    isLossy: boolean;
    lossyHeapPages: number;
    exactHeapPages: number;
    recheckRowsRemoved: number;
    actionableFeedback: string;
  } {
    let usesBloomIndex = false;
    let isLossy = false;
    let lossyHeapPages = 0;
    let exactHeapPages = 0;
    let recheckRowsRemoved = 0;

    const traverse = (node: any) => {
      if (!node) return;

      if (node['Node Type'] === 'Bitmap Index Scan') {
        const indexName = node['Index Name'] || '';
        if (indexName.includes('bloom') || node['Index Technique'] === 'Bloom') {
          usesBloomIndex = true;
        }
      }

      if (node['Node Type'] === 'Bitmap Heap Scan') {
        exactHeapPages += node['Exact Heap Blocks'] || 0;
        lossyHeapPages += node['Lossy Heap Blocks'] || 0;
        recheckRowsRemoved += node['Rows Removed by Index Recheck'] || 0;

        if (lossyHeapPages > 0) {
          isLossy = true;
        }
      }

      if (node.Plans) {
        for (const child of node.Plans) {
          traverse(child);
        }
      }
    };

    traverse(Array.isArray(planJson) ? planJson[0]?.Plan : planJson?.Plan);

    let feedback = 'Execution plan optimal.';
    if (!usesBloomIndex) {
      feedback = 'WARNING: Bloom index was not used by the query planner. Verify equality predicates.';
    } else if (isLossy) {
      feedback = `CRITICAL: Bitmap Heap Scan degraded to ${lossyHeapPages} lossy pages! ` +
        `work_mem is insufficient. Increase transaction work_mem via SET LOCAL work_mem = '64MB'.`;
    } else if (recheckRowsRemoved > 50_000) {
      feedback = `ELEVATED COLLISION: ${recheckRowsRemoved} candidate rows discarded during recheck. ` +
        `Re-calibrate Bloom index with larger signature length M to reduce hash collisions.`;
    }

    return {
      usesBloomIndex,
      isLossy,
      lossyHeapPages,
      exactHeapPages,
      recheckRowsRemoved,
      actionableFeedback: feedback,
    };
  }
}
```

---

## 5. Multi-Language Production Implementations

### PostgreSQL Zero-Downtime Migration: Calibrated Bloom DDL

```sql
-- migrations/20260401000000_create_audit_logs_bloom_index.sql
-- Invariant: Install extension first, set lock_timeout to avoid blocking writers,
-- and build concurrently with explicit length and per-column bit parameters.

CREATE EXTENSION IF NOT EXISTS bloom;

SET LOCAL lock_timeout = '2000ms';
SET LOCAL statement_timeout = '0';

-- Audit logs table with multi-facet query attributes
-- Columns: tenant_id (1), user_id (2), action_type (3), resource_type (4), status (5), region (6), severity (7)
-- Total length = 512 bits, Target K_total ~ 355 bits
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_logs_bloom_facets
ON audit_logs USING bloom (
    tenant_id,     -- col1: high distinct (100k)   -> 48 bits
    user_id,       -- col2: high distinct (500k)   -> 52 bits
    action_type,   -- col3: medium distinct (80)   -> 18 bits
    resource_type, -- col4: medium distinct (150)  -> 20 bits
    status,        -- col5: low distinct (8)       -> 8 bits
    region,        -- col6: low distinct (25)      -> 12 bits
    severity       -- col7: low distinct (5)       -> 6 bits
)
WITH (
    length = 512,
    col1 = 48,
    col2 = 52,
    col3 = 18,
    col4 = 20,
    col5 = 8,
    col6 = 12,
    col7 = 6
);

-- Tune autovacuum to proactively compact dead signatures
ALTER TABLE audit_logs SET (
    autovacuum_vacuum_scale_factor = 0.05,
    autovacuum_vacuum_cost_limit = 2000
);
```

### Go (`jackc/pgx/v5`): Scoped Session Facet Search & Memory Guard

```go
// internal/store/audit_logs_bloom_search.go
package store

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type AuditLogFilter struct {
	TenantID     *string
	UserID       *string
	ActionType   *string
	ResourceType *string
	Status       *string
	Region       *string
	Severity     *string
	// Range filter: must be handled by B-Tree, NOT Bloom
	StartTime    *time.Time
	EndTime      *time.Time
	Limit        int
	Offset       int
}

type AuditLogRecord struct {
	ID           string    `json:"id"`
	TenantID     string    `json:"tenant_id"`
	UserID       string    `json:"user_id"`
	ActionType   string    `json:"action_type"`
	ResourceType string    `json:"resource_type"`
	Status       string    `json:"status"`
	Region       string    `json:"region"`
	Severity     string    `json:"severity"`
	CreatedAt    time.Time `json:"created_at"`
}

type BloomAuditRepository struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewBloomAuditRepository(pool *pgxpool.Pool, logger *slog.Logger) *BloomAuditRepository {
	return &BloomAuditRepository{pool: pool, logger: logger}
}

// SearchFaceted executes dynamic multi-facet equality queries with transaction-scoped
// work_mem elevation, guaranteeing zero lossy bitmap degradation.
func (r *BloomAuditRepository) SearchFaceted(
	ctx context.Context,
	filter AuditLogFilter,
) ([]AuditLogRecord, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Invariant: Elevate work_mem to 64MB for the duration of the faceted search transaction
	// to prevent Bitmap Index Scan from degrading to lossy page pointers.
	if _, err := tx.Exec(ctx, "SET LOCAL work_mem = '64MB'"); err != nil {
		return nil, fmt.Errorf("failed to elevate work_mem: %w", err)
	}

	var conditions []string
	var args []any
	argIdx := 1

	// Invariant: Bloom index ONLY evaluates equality (=) predicates
	if filter.TenantID != nil {
		conditions = append(conditions, fmt.Sprintf("tenant_id = $%d", argIdx))
		args = append(args, *filter.TenantID)
		argIdx++
	}
	if filter.UserID != nil {
		conditions = append(conditions, fmt.Sprintf("user_id = $%d", argIdx))
		args = append(args, *filter.UserID)
		argIdx++
	}
	if filter.ActionType != nil {
		conditions = append(conditions, fmt.Sprintf("action_type = $%d", argIdx))
		args = append(args, *filter.ActionType)
		argIdx++
	}
	if filter.ResourceType != nil {
		conditions = append(conditions, fmt.Sprintf("resource_type = $%d", argIdx))
		args = append(args, *filter.ResourceType)
		argIdx++
	}
	if filter.Status != nil {
		conditions = append(conditions, fmt.Sprintf("status = $%d", argIdx))
		args = append(args, *filter.Status)
		argIdx++
	}
	if filter.Region != nil {
		conditions = append(conditions, fmt.Sprintf("region = $%d", argIdx))
		args = append(args, *filter.Region)
		argIdx++
	}
	if filter.Severity != nil {
		conditions = append(conditions, fmt.Sprintf("severity = $%d", argIdx))
		args = append(args, *filter.Severity)
		argIdx++
	}

	// Temporal range filters handled by composite BitmapAnd with created_at B-Tree
	if filter.StartTime != nil {
		conditions = append(conditions, fmt.Sprintf("created_at >= $%d", argIdx))
		args = append(args, *filter.StartTime)
		argIdx++
	}
	if filter.EndTime != nil {
		conditions = append(conditions, fmt.Sprintf("created_at <= $%d", argIdx))
		args = append(args, *filter.EndTime)
		argIdx++
	}

	whereClause := ""
	if len(conditions) > 0 {
		whereClause = "WHERE " + strings.Join(conditions, " AND ")
	}

	limit := filter.Limit
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	offset := filter.Offset
	if offset < 0 {
		offset = 0
	}

	query := fmt.Sprintf(`
		SELECT id, tenant_id, user_id, action_type, resource_type, status, region, severity, created_at
		FROM audit_logs
		%s
		ORDER BY created_at DESC
		LIMIT %d OFFSET %d
	`, whereClause, limit, offset)

	rows, err := tx.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("faceted query execution failed: %w", err)
	}
	defer rows.Close()

	var records []AuditLogRecord
	for rows.Next() {
		var rec AuditLogRecord
		if err := rows.Scan(
			&rec.ID,
			&rec.TenantID,
			&rec.UserID,
			&rec.ActionType,
			&rec.ResourceType,
			&rec.Status,
			&rec.Region,
			&rec.Severity,
			&rec.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("failed to scan audit record: %w", err)
		}
		records = append(records, rec)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("row iteration error: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("failed to commit transaction: %w", err)
	}

	return records, nil
}
```

### TypeScript (`drizzle-orm` / `pg`): Scoped Safe Runner

```typescript
// src/repositories/FacetedSearchRepository.ts
import { Pool } from 'pg';

export interface FacetFilter {
  tenantId?: string;
  userId?: string;
  actionType?: string;
  resourceType?: string;
  status?: string;
  region?: string;
  severity?: string;
  limit?: number;
  offset?: number;
}

export class FacetedSearchRepository {
  constructor(private readonly pool: Pool) {}

  /**
   * Executes multi-facet search using transaction-scoped work_mem to guarantee
   * exact Bitmap Heap Scans against PostgreSQL Bloom indexes.
   */
  async search(filter: FacetFilter) {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      // Elevate work_mem to protect bitmap index scan from lossy page degradation
      await client.query("SET LOCAL work_mem = '64MB'");
      await client.query("SET LOCAL statement_timeout = '5000'");

      const clauses: string[] = [];
      const values: any[] = [];
      let paramIdx = 1;

      const addEquality = (col: string, val: string | undefined) => {
        if (val !== undefined && val !== null) {
          clauses.push(`${col} = $${paramIdx++}`);
          values.push(val);
        }
      };

      addEquality('tenant_id', filter.tenantId);
      addEquality('user_id', filter.userId);
      addEquality('action_type', filter.actionType);
      addEquality('resource_type', filter.resourceType);
      addEquality('status', filter.status);
      addEquality('region', filter.region);
      addEquality('severity', filter.severity);

      const whereClause = clauses.length > 0 ? `WHERE ${clauses.join(' AND ')}` : '';
      const limit = Math.min(filter.limit ?? 50, 500);
      const offset = filter.offset ?? 0;

      const sql = `
        SELECT id, tenant_id, user_id, action_type, resource_type, status, region, severity, created_at
        FROM audit_logs
        ${whereClause}
        ORDER BY created_at DESC
        LIMIT ${limit} OFFSET ${offset};
      `;

      const result = await client.query(sql, values);
      await client.query('COMMIT');
      return result.rows;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }
}
```

### Python (`asyncpg`): Asynchronous Scoped Context Manager

```python
# app/repositories/faceted_bloom_repository.py
import asyncpg
from typing import Optional, Dict, Any, List

class FacetedBloomRepository:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def search_facets(
        self,
        filters: Dict[str, Optional[str]],
        limit: int = 50,
        offset: int = 0
    ) -> List[Dict[str, Any]]:
        """
        Executes faceted search against Bloom-indexed columns with transaction-scoped
        work_mem allocation to eliminate lossy bitmap heap scans.
        """
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # Elevate work_mem for exact bitmap preservation
                await conn.execute("SET LOCAL work_mem = '64MB'")
                await conn.execute("SET LOCAL statement_timeout = '5000ms'")

                clauses = []
                values = []
                idx = 1

                allowed_columns = {
                    "tenant_id", "user_id", "action_type",
                    "resource_type", "status", "region", "severity"
                }

                for col, val in filters.items():
                    if col in allowed_columns and val is not None:
                        clauses.append(f"{col} = ${idx}")
                        values.append(val)
                        idx += 1

                where_sql = f"WHERE {' AND '.join(clauses)}" if clauses else ""
                values.extend([min(limit, 500), max(offset, 0)])

                query = f"""
                    SELECT id, tenant_id, user_id, action_type, resource_type,
                           status, region, severity, created_at
                    FROM audit_logs
                    {where_sql}
                    ORDER BY created_at DESC
                    LIMIT ${idx} OFFSET ${idx + 1}
                """

                rows = await conn.fetch(query, *values)
                return [dict(r) for r in rows]
```

### Rust (`sqlx`): Scoped Transaction Invariant Wrapper

```rust
// src/repositories/bloom_audit_store.rs
use sqlx::{PgPool, Transaction, Postgres};
use std::time::Duration;

pub struct AuditFilter {
    pub tenant_id: Option<String>,
    pub user_id: Option<String>,
    pub action_type: Option<String>,
    pub status: Option<String>,
    pub limit: i64,
    pub offset: i64,
}

pub struct AuditRecord {
    pub id: String,
    pub tenant_id: String,
    pub user_id: String,
    pub action_type: String,
    pub status: String,
}

pub async fn search_bloom_facets(
    pool: &PgPool,
    filter: AuditFilter,
) -> Result<Vec<AuditRecord>, sqlx::Error> {
    let mut tx: Transaction<'_, Postgres> = pool.begin().await?;

    // Elevate transaction work_mem to prevent lossy bitmap degradation
    sqlx::query("SET LOCAL work_mem = '64MB'")
        .execute(&mut *tx)
        .await?;

    let mut query_builder = sqlx::QueryBuilder::<Postgres>::new(
        "SELECT id, tenant_id, user_id, action_type, status FROM audit_logs WHERE 1=1 "
    );

    if let Some(t_id) = &filter.tenant_id {
        query_builder.push(" AND tenant_id = ").push_bind(t_id);
    }
    if let Some(u_id) = &filter.user_id {
        query_builder.push(" AND user_id = ").push_bind(u_id);
    }
    if let Some(action) = &filter.action_type {
        query_builder.push(" AND action_type = ").push_bind(action);
    }
    if let Some(st) = &filter.status {
        query_builder.push(" AND status = ").push_bind(st);
    }

    query_builder.push(" ORDER BY created_at DESC LIMIT ")
        .push_bind(filter.limit.min(500))
        .push(" OFFSET ")
        .push_bind(filter.offset.max(0));

    let records = query_builder.build_query_as::<AuditRecord>()
        .fetch_all(&mut *tx)
        .await?;

    tx.commit().await?;
    Ok(records)
}
```

---

## 6. Six-State Bloom Index Lifecycle Finite-State Machine (FSM)

```
       +---------------------------------------------+
       |                1. UNINDEXED                 |
       |  (Table has multi-column facet predicates;  |
       |   suffering Seq Scans or B-Tree bloat)      |
       +---------------------------------------------+
                              |
                              | [Entropy Profile Audited]
                              v
       +---------------------------------------------+
       |         2. COLUMN_ENTROPY_AUDIT             |
       |  (Validate all predicates are equality '='; |
       |   compute log2(nDistinct) per column)       |
       +---------------------------------------------+
                              |
                              | [Parameters Calibrated]
                              v
       +---------------------------------------------+
       |        3. BIT_ALLOCATION_CALIBRATED         |
       |  (Compute M = 256..1024, set k_i per col;   |
       |   verify saturation ratio <= 0.70)          |
       +---------------------------------------------+
                              |
                              | [Execute CREATE CONCURRENTLY]
                              v
       +---------------------------------------------+
       |            4. CONCURRENT_BUILD              |
       |  (Run DDL under lock_timeout = 2000ms;      |
       |   verify zero impact on live writers)       |
       +---------------------------------------------+
                              |
                              | [EXPLAIN Verified: Lossy == 0]
                              v
       +---------------------------------------------+
       |          5. ACTIVE_LOSSLESS_SCAN            |
       |  (Bitmap Index Scan active; Exact TIDs;     |
       |   work_mem budgeted; false-positive < 2%)   |
       +---------------------------------------------+
                              |
                              | [Dead Signature Compaction]
                              v
       +---------------------------------------------+
       |       6. SCHEDULED_VACUUM_MAINTENANCE       |
       |  (Autovacuum scale factor = 0.05;           |
       |   purge dead signatures, prevent bloat)     |
       +---------------------------------------------+
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

```
+----------------------------------------------------------------------------------------------------+
|                BLOOM INDEX MACHINE-VERIFIABLE DEFINITION OF DONE (DoD)                             |
+--------+---------------------------------+---------------------------------------------------------+
| Gate 1 | Operator Sargability Invariant  | 100% of predicates targeting Bloom index use '='.       |
|        |                                 | Zero range (<, >, BETWEEN) or LIKE operators allowed.   |
+--------+---------------------------------+---------------------------------------------------------+
| Gate 2 | Bit Allocation Calibration      | Signature length M in [256, 1024]. Sum of k_i <= 0.70*M.|
|        |                                 | Cardinality entropy allocated; no uniform default 2-bit.|
+--------+---------------------------------+---------------------------------------------------------+
| Gate 3 | Lossless Bitmap Scan Invariant  | EXPLAIN (ANALYZE, BUFFERS) MUST show 'Lossy: 0'.        |
|        |                                 | work_mem sized to prevent exact-to-lossy degradation.   |
+--------+---------------------------------+---------------------------------------------------------+
| Gate 4 | Storage Reduction & Write TPS   | Index footprint <= 15% of equivalent B-Tree sprawl.    |
|        |                                 | Single write per tuple instead of N composite B-Trees.  |
+--------+---------------------------------+---------------------------------------------------------+
| Gate 5 | Non-Blocking DDL Deployment     | Built with CREATE INDEX CONCURRENTLY under              |
|        |                                 | lock_timeout <= 2000ms; zero AccessExclusiveLock.       |
+--------+---------------------------------+---------------------------------------------------------+
| Gate 6 | Autovacuum & Telemetry Sentinel | autovacuum_vacuum_scale_factor <= 0.05 configured.       |
|        |                                 | pg_stat_user_indexes shows idx_scan > 0 in telemetry.   |
+--------+---------------------------------+---------------------------------------------------------+
```
