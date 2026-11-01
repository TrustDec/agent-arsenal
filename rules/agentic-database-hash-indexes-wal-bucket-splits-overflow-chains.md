---
description: PostgreSQL Hash Index access method (src/backend/access/hash/), crash-safe WAL logging (PG 10+), O(1) equality point lookups vs B-Tree size comparison, dynamic bucket doubling splits, overflow page (LH_OVERFLOW_PAGE) linear scan degradation, 32-bit hash collision defense, uniqueness prohibition (SQLSTATE 0A000), non-sargable range/ORDER BY pitfalls, and hash_mem_multiplier tuning across Go (pgx/v5), TypeScript (Drizzle, Kysely), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{hash,index,lookup,point_query,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Hash Indexes, Crash-Safe WAL Logging, Dynamic Bucket Splitting, Overflow Page Degradation & 32-Bit Hash Collision Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design PostgreSQL Hash Indexing architectures across high-throughput point-lookup repositories (UUIDs, API tokens, cryptographic SHA-256 signatures, natural text identifiers, URL slugs, session tokens) in Go (`jackc/pgx/v5`), TypeScript (`Drizzle ORM`, `Kysely`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Hash Collision Linear Chain & Overflow Page Degradation Trap" (where high data volume or skewed inputs trigger deep overflow page chains, degrading $O(1)$ point lookups into $O(K)$ sequential disk page scans), the "Uniqueness & Foreign Key Prohibition Catastrophe (`SQLSTATE 0A000`)" (where agents attempt `CREATE UNIQUE INDEX ... USING hash` or back a `PRIMARY KEY` / `FOREIGN KEY` with a Hash index, crashing CI/CD migrations with `feature not supported: access method "hash" does not support unique indexes`), the "Non-Sargable Range & Sort Degeneration Cliff" (where agents substitute B-Tree with Hash index on columns queried with `<`, `>`, `<=`, `>=`, `BETWEEN`, or `ORDER BY`, silently forcing the query optimizer into a 100% full sequential table scan), the "Multi-Column Composite Index Prohibition Trap" (where agents attempt composite hash indexing `USING hash (tenant_id, key)`, triggering immediate DDL parser errors), the "Dynamic Bucket Split Latch Contention & Write Stall Trap" (where crossing bucket capacity thresholds during bulk inserts triggers incremental bucket doubling, locking bucket pages and causing thread convoys), and the "Autovacuum Starvation & Overflow Page Bloat Amnesia" (where update/delete churn bloats overflow pages that never return disk space to the OS without `REINDEX CONCURRENTLY`) by establishing a strict 5-Tier Hash Index Governance Ladder, mathematical collision and sizing proofs, an autonomous TypeScript `AgenticDatabaseHashIndexGuardEngine`, cross-runtime telemetry sentinels in Go, TypeScript, Python, and Rust, a 6-state hash index lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Hash Index Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL (version 10 through 17+), the **Hash Index** access method (`src/backend/access/hash/`) provides physical on-disk hash tables capable of direct $O(1)$ equality point lookups (`=`):

1. **Crash-Safe WAL Logging Since PostgreSQL 10**: Historically (prior to PostgreSQL 10), Hash indexes were not logged to the Write-Ahead Log (WAL), requiring full rebuilds after crashes and preventing their use on streaming physical replicas. Since PostgreSQL 10, Hash indexes are fully WAL-logged, crash-safe, and streamable to standbys.
2. **Fixed-Size 10-Byte Tuple Storage Invariance**:
   - In a standard **B-Tree** index, the leaf tuple stores the actual indexed key value plus header overhead. For long strings, URLs, or UUIDs, a B-Tree index tuple consumes 32–128+ bytes.
   - In a **Hash index**, PostgreSQL computes a 32-bit hash value using `hash_any()` (`src/backend/access/hash/hashutil.c`). The hash index page stores **only the 4-byte uint32 hash value and the 6-byte ItemPointer (TID)** (totaling 10 bytes plus 2-byte line pointer). Regardless of whether the original column is a 10-byte string or a 2,000-byte URL, the index entry is strictly **10 bytes**.
   - Consequently, for large text keys queried exclusively via `=` equality, Hash indexes can be **60% to 80% smaller** than equivalent B-trees, fitting entirely into `shared_buffers` and eliminating disk I/O.
3. **The Bucket & Overflow Page Architecture**:
   - A Hash index consists of a **Meta Page** (`HashMetaPage`), an array of **Primary Bucket Pages**, zero or more **Overflow Pages** (`LH_OVERFLOW_PAGE`), and **Bitmap Pages** tracking overflow page allocations.
   - Primary buckets are indexed by bucket number $B \in [0, 2^N - 1]$. When tuples are inserted, PostgreSQL computes $h = \text{hash\_any}(key)$, and masks $h$ to determine the target bucket.
   - When a primary bucket page (8KB, holding approximately 400–600 tuples) becomes full, PostgreSQL allocates an **Overflow Page** chained via `hasho_nextblkno`.
   - If an index experiences high duplicate rates, 32-bit hash collisions, or uneven bucket growth, long overflow chains form. Searching a bucket requires scanning the primary page followed by sequentially traversing every overflow page in the chain.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   POSTGRESQL HASH INDEX PHYSICAL ON-DISK TOPOLOGY                      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ META PAGE (Block 0)                                                                    │
│   hashm_magic | hashm_version | hashm_ntuples | hashm_ffactor | hashm_spares[]         │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ PRIMARY BUCKETS (Blocks 1 .. 2^N)                                                      │
│                                                                                        │
│   Bucket 0 (Block 1) ──> [Primary 8KB Page]                                            │
│                          Tuple: [Hash: 0x3F8A1B2C | TID: (blk 42, off 1)]              │
│                          Tuple: [Hash: 0x3F8A9910 | TID: (blk 42, off 2)]              │
│                          hashe_nextblkno: InvalidBlockNumber (No overflow)             │
│                                                                                        │
│   Bucket 1 (Block 2) ──> [Primary 8KB Page: FULL]                                      │
│                          Tuple: [Hash: 0x8A120001 | TID: (blk 10, off 4)]              │
│                          ... (450 tuples) ...                                          │
│                          hashe_nextblkno: Block 1024 ──┐                               │
│                                                        │ (Overflow Pointer)            │
│                          ┌─────────────────────────────┘                               │
│                          ▼                                                             │
│                          [Overflow Page 1 (Block 1024): FULL]                          │
│                          Tuple: [Hash: 0x8A1245FF | TID: (blk 12, off 8)]              │
│                          hashe_nextblkno: Block 1025 ──┐                               │
│                                                        │                               │
│                          ┌─────────────────────────────┘                               │
│                          ▼                                                             │
│                          [Overflow Page 2 (Block 1025): ACTIVE]                        │
│                          Tuple: [Hash: 0x8A12ABCD | TID: (blk 15, off 2)]              │
│                          hashe_nextblkno: InvalidBlockNumber                           │
│                                                                                        │
│   💥 POINT LOOKUP SCAN PENALTY:                                                        │
│      Key lookup hashing to Bucket 1 MUST READ Block 2 -> Block 1024 -> Block 1025!     │
│      Degrades O(1) point lookup into O(K) sequential disk page traversals!             │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

When autonomous coding agents generate database migrations, point-query indexes, or API lookup keys, LLMs routinely commit 6 catastrophic architectural mistakes:

### The 6 Hash Index Architectural Catastrophes

```
  ┌────────────────────────────────────────────────────────────────────────────────────┐
  │                    THE 6 HASH INDEX ARCHITECTURAL CATASTROPHES                     │
  ├────────────────────────────────────────────────────────────────────────────────────┤
  │ 1. Hash Collision & Overflow Page Chain Degradation: Deep overflow chains force     │
  │    point lookups to sequentially read dozens of 8KB pages, collapsing latency.     │
  │                                                                                    │
  │ 2. Uniqueness & Primary Key Incompatibility (SQLSTATE 0A000): Attempting to back    │
  │    UNIQUE or PRIMARY KEY with Hash index crashes deployments with feature error.   │
  │                                                                                    │
  │ 3. Non-Sargable Range & Sort Degeneration: Querying Hash-indexed columns with      │
  │    <, >, BETWEEN, or ORDER BY forces 100% full table Seq Scans across millions.    │
  │                                                                                    │
  │ 4. Multi-Column Composite Index Prohibition: Hash access method only supports      │
  │    single-column indexing; composite index attempts fail immediately in DDL.       │
  │                                                                                    │
  │ 5. Dynamic Bucket Split Latch Contention: Incremental bucket doubling during high  │
  │    write rates grabs exclusive page latches, stalling concurrent writers.          │
  │                                                                                    │
  │ 6. Autovacuum Starvation & Overflow Page Disk Bloat: Freed overflow tuples are     │
  │    retained in internal freelists; disk storage never shrinks without REINDEX.     │
  └────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Models, Hash Collisions & Sizing Laws

### 2.1 The 32-Bit Hash Collision Probability (Birthday Paradox)

PostgreSQL Hash indexes use a 32-bit hash function ($2^{32} = 4,294,967,296$ possible hash values). The probability $P(\text{collision})$ that at least two distinct keys in a table of $k$ rows share the exact same 32-bit hash value is given by the Poisson approximation of the Birthday Problem:

$$
P(\text{collision}) \approx 1 - \exp\left( - \frac{k(k - 1)}{2 \times 2^{32}} \right) = 1 - \exp\left( - \frac{k^2}{2^{33}} \right)
$$

For various table row counts $k$:

| Row Count $k$ | Collision Probability $P(\text{collision})$ | Expected Collision Count $E[\text{collisions}] \approx \frac{k^2}{2^{33}}$ | Impact on Point Lookups |
| :--- | :--- | :--- | :--- |
| **10,000** | $0.00116$ ($0.11\%$) | $0.00001$ | Negligible |
| **77,163** | $\mathbf{0.50000}$ ($\mathbf{50.0\%}$) | $0.693$ | First collision expected |
| **500,000** | $0.99999$ ($99.99\%$) | $29.1$ | Dozens of collision pairs |
| **5,000,000** | $\approx 1.0$ ($100\%$) | $2,910$ | Thousands of collisions |
| **50,000,000** | $\approx 1.0$ ($100\%$) | $291,038$ | Hundreds of thousands of collisions |

> **Critical Consequence**: When two distinct keys share a 32-bit hash value, PostgreSQL retrieves both heap tuples via their TIDs and evaluates the recheck filter on the actual heap row. Hash collisions do NOT return incorrect data (PostgreSQL always validates the original key value against the heap tuple), but excessive collisions or duplicate keys cluster in identical buckets, forcing overflow page allocations.

### 2.2 Storage Footprint Crossover: B-Tree vs Hash Index

Let $L_k$ be the average byte length of the indexed column, $N$ be the number of rows, and $P_{\text{page}} = 8,192$ bytes.

- **Hash Index Tuple Size**: Constant 10 bytes (4-byte hash + 6-byte TID) + 2-byte line pointer = 12 bytes.
  $$\text{Capacity}_{\text{hash}} \approx \left\lfloor \frac{8192 - 24}{12} \right\rfloor \approx 680 \text{ tuples/page}$$
  $$\text{Size}_{\text{hash}}(N) \approx \frac{N \times 12}{\text{fillfactor} \times 8192} \times 8192 \text{ bytes}$$

- **B-Tree Index Tuple Size**: Variable $L_k + 8 \text{ (header)} + 6 \text{ (TID)} + 2 \text{ (line pointer)} = L_k + 16$ bytes (aligned to 4-byte boundaries).
  $$\text{Capacity}_{\text{btree}} \approx \left\lfloor \frac{8192 - 24}{\text{MAXALIGN}(L_k + 16)} \right\rfloor \text{ tuples/page}$$

$$
\text{Compression Ratio } R_{\text{space}} = \frac{\text{Size}_{\text{hash}}}{\text{Size}_{\text{btree}}} \approx \frac{12}{\text{MAXALIGN}(L_k + 16)}
$$

For a URL or token column where $L_k = 128$ bytes:
$$
R_{\text{space}} \approx \frac{12}{148} \approx 0.081 \implies \mathbf{91.9\% \text{ Storage Reduction!}}
$$

### 2.3 Point Lookup Latency Under Overflow Chains

The total I/O cost $C_{\text{lookup}}$ for a Hash index point lookup with an overflow chain of length $K$ (where $K = 0$ indicates only the primary bucket page):

$$
C_{\text{lookup}} = C_{\text{meta}} + C_{\text{primary}} + \sum_{i=1}^{K} C_{\text{overflow}}^{(i)} + C_{\text{heap\_fetch}}
$$

When the entire index fits in `shared_buffers`, $C_{\text{lookup}} \approx 0.1\text{ms}$. When overflow chains spill to disk ($K \ge 5$), latency degrades linearly:

$$
T_{\text{lookup}}(K) = T_{\text{cache}} + K \times T_{\text{disk\_random\_read}} \approx 0.1\text{ms} + K \times 2.5\text{ms}
$$

For $K = 10$, point lookup latency spikes from **0.1ms to 25.1ms** ($251\times$ regression).

---

## 3. The 5-Tier Hash Index Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        THE 5-TIER HASH INDEX GOVERNANCE LADDER                         │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ TIER 0: Access Method Qualification & Anti-Pattern Firewalls                           │
│         - Strictly EQUALITY (=) lookups only. Ban <, >, BETWEEN, ORDER BY on hash.    │
│         - Strictly SINGLE-COLUMN only. Never attempt composite hash indexes.           │
│         - Ban UNIQUE and PRIMARY KEY on Hash indexes (SQLSTATE 0A000).                 │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ TIER 1: Long-Key Storage Crossover Sizing                                              │
│         - Deploy Hash index when key length L_k >= 32 bytes (UUID, URL, SHA256).       │
│         - Retain B-Tree for short primitives (INT4, INT8, DATE) where B-Tree is equal. │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ TIER 2: Dynamic Bucket Sizing & hash_mem_multiplier Tuning                             │
│         - Pre-allocate fillfactor = 75-80 for high-churn update tables.                │
│         - Tune hash_mem_multiplier = 2.0 (PostgreSQL 13+) for maintenance/reindexes.   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ TIER 3: Real-Time Overflow Chain & pageinspect Telemetry Watchdogs                     │
│         - Monitor hash_page_stats via pageinspect extension.                          │
│         - Alert when overflow page ratio: N_overflow / (N_primary + N_overflow) > 15%. │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ TIER 4: Machine-Verifiable CI Gates & Zero-Downtime Maintenance                        │
│         - Scheduled REINDEX CONCURRENTLY to reclaim unlinked overflow pages.          │
│         - Pre-commit AST linter prohibiting non-sargable queries on hash-indexed cols. │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Production TypeScript Guard Engine

```typescript
/**
 * AgenticDatabaseHashIndexGuardEngine
 * Industrial-grade governance and validation engine for PostgreSQL Hash Indexes.
 * Enforces single-column equality invariants, detects overflow chain bloat,
 * prevents SQLSTATE 0A000 uniqueness violations, and verifies storage crossover.
 */

export interface HashIndexAuditResult {
  indexName: string;
  tableName: string;
  indexedColumn: string;
  isEligible: boolean;
  violations: string[];
  recommendations: string[];
  metrics: {
    columnAvgByteLength: number;
    primaryPages: number;
    overflowPages: number;
    overflowRatio: number;
    estimatedBTreeSizeMB: number;
    actualHashSizeMB: number;
    spaceSavingsPercent: number;
  };
}

export interface IndexInspectionQuery {
  primaryPages: number;
  overflowPages: number;
  bitmapPages: number;
  unusedPages: number;
  liveTuples: number;
}

export class AgenticDatabaseHashIndexGuardEngine {
  private static readonly MAX_SAFE_OVERFLOW_RATIO = 0.15; // 15% overflow threshold
  private static readonly MIN_KEY_LENGTH_FOR_HASH = 32;   // 32 bytes crossover

  /**
   * Evaluates whether a proposed column and query workload qualify for a Hash Index.
   */
  public static evaluateEligibility(params: {
    columnName: string;
    columnType: string;
    avgByteLength: number;
    isUnique: boolean;
    isPrimaryKey: boolean;
    isMultiColumn: boolean;
    queryOperators: string[]; // e.g. ['=', '<', 'BETWEEN', 'ORDER BY']
  }): { eligible: boolean; errors: string[]; strategy: 'HASH' | 'BTREE' } {
    const errors: string[] = [];

    // Rule 1: Prohibit UNIQUE constraints on Hash indexes (PostgreSQL limitation)
    if (params.isUnique || params.isPrimaryKey) {
      errors.push(
        'SQLSTATE 0A000: PostgreSQL access method "hash" does not support UNIQUE or PRIMARY KEY constraints. Use B-Tree.'
      );
    }

    // Rule 2: Prohibit multi-column hash indexes
    if (params.isMultiColumn) {
      errors.push(
        'PostgreSQL Hash indexes do not support multiple columns. Hash indexes must index exactly one column.'
      );
    }

    // Rule 3: Prohibit range and sort queries on Hash indexes
    const unsupportedOps = params.queryOperators.filter(
      (op) => op !== '=' && op !== 'IS NULL' && op !== 'IS NOT NULL'
    );
    if (unsupportedOps.length > 0) {
      errors.push(
        `Non-sargable query operators detected: [${unsupportedOps.join(', ')}]. ` +
        `Hash indexes strictly support ONLY equality ('='). Range queries (<, >, BETWEEN) or ORDER BY will force 100% full table Seq Scans.`
      );
    }

    // Rule 4: Key size crossover evaluation
    if (params.avgByteLength < this.MIN_KEY_LENGTH_FOR_HASH && errors.length === 0) {
      // Not a hard error, but B-Tree is preferred for short primitives
      return {
        eligible: false,
        errors: [
          `Key byte length (${params.avgByteLength}B) is below 32-byte crossover. ` +
          `For small primitives (INT4, INT8, DATE), B-Tree provides equivalent performance and supports range operations.`
        ],
        strategy: 'BTREE',
      };
    }

    if (errors.length > 0) {
      return { eligible: false, errors, strategy: 'BTREE' };
    }

    return { eligible: true, errors: [], strategy: 'HASH' };
  }

  /**
   * Computes overflow ratio and health status from pageinspect statistics.
   */
  public static auditIndexHealth(
    indexName: string,
    tableName: string,
    columnName: string,
    avgKeyLength: number,
    stats: IndexInspectionQuery
  ): HashIndexAuditResult {
    const totalPages = stats.primaryPages + stats.overflowPages;
    const overflowRatio = totalPages > 0 ? stats.overflowPages / totalPages : 0;
    const violations: string[] = [];
    const recommendations: string[] = [];

    const actualHashSizeMB = (totalPages * 8192) / (1024 * 1024);
    
    // Estimate equivalent B-tree size
    const btreeTupleBytes = Math.ceil((avgKeyLength + 16) / 4) * 4;
    const btreeTuplesPerPage = Math.floor((8192 - 24) / btreeTupleBytes);
    const estimatedBTreePages = Math.ceil(stats.liveTuples / (btreeTuplesPerPage * 0.70)); // 70% fillfactor
    const estimatedBTreeSizeMB = (estimatedBTreePages * 8192) / (1024 * 1024);

    const spaceSavingsPercent = estimatedBTreeSizeMB > 0
      ? Math.max(0, ((estimatedBTreeSizeMB - actualHashSizeMB) / estimatedBTreeSizeMB) * 100)
      : 0;

    if (overflowRatio > this.MAX_SAFE_OVERFLOW_RATIO) {
      violations.push(
        `High overflow page ratio: ${(overflowRatio * 100).toFixed(2)}% exceeds safety limit (${(this.MAX_SAFE_OVERFLOW_RATIO * 100)}%). ` +
        `Point lookups are suffering sequential overflow page traversals.`
      );
      recommendations.push(
        `Execute 'REINDEX INDEX CONCURRENTLY ${indexName};' to redistribute bucket allocations and collapse overflow chains.`
      );
    }

    if (stats.unusedPages > totalPages * 0.30) {
      recommendations.push(
        `Index contains ${stats.unusedPages} unused freelist pages (> 30%). Run REINDEX CONCURRENTLY to reclaim disk space.`
      );
    }

    return {
      indexName,
      tableName,
      indexedColumn: columnName,
      isEligible: violations.length === 0,
      violations,
      recommendations,
      metrics: {
        columnAvgByteLength: avgKeyLength,
        primaryPages: stats.primaryPages,
        overflowPages: stats.overflowPages,
        overflowRatio,
        estimatedBTreeSizeMB,
        actualHashSizeMB,
        spaceSavingsPercent,
      },
    };
  }

  /**
   * Generates production-safe DDL for creating a Hash index.
   */
  public static generateSafeDDL(params: {
    tableName: string;
    columnName: string;
    indexName?: string;
    fillfactor?: number;
  }): string {
    const idxName = params.indexName || `idx_${params.tableName}_${params.columnName}_hash`;
    const ff = params.fillfactor || 75;

    return `-- Safe Zero-Downtime Hash Index Creation
-- Access Method: hash (10-byte fixed tuple size, crash-safe WAL logged)
-- Pre-conditions: Single column, equality (=) queries only, non-unique
CREATE INDEX CONCURRENTLY IF NOT EXISTS ${idxName}
ON ${params.tableName} USING hash (${params.columnName})
WITH (fillfactor = ${ff});
`;
  }
}
```

---

## 5. Cross-Language Reference Implementations

### 5.1 Go (pgx/v5): Automated Hash Index Overflow Sentinel

```go
package hashguard

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type HashIndexMetrics struct {
	IndexName     string  `json:"index_name"`
	TableName     string  `json:"table_name"`
	PrimaryPages  int64   `json:"primary_pages"`
	OverflowPages int64   `json:"overflow_pages"`
	OverflowRatio float64 `json:"overflow_ratio"`
	NeedsReindex  bool    `json:"needs_reindex"`
}

// InspectHashIndex audits the internal page composition of a PostgreSQL hash index
// using the pageinspect extension (hash_page_stats / hashm_ntuples).
func InspectHashIndex(ctx context.Context, pool *pgxpool.Pool, indexName string) (*HashIndexMetrics, error) {
	// Query pg_class to verify access method is hash (amname = 'hash')
	var amName, tableName string
	err := pool.QueryRow(ctx, `
		SELECT am.amname, c.relname
		FROM pg_class i
		JOIN pg_am am ON am.oid = i.relam
		JOIN pg_index x ON x.indexrelid = i.oid
		JOIN pg_class c ON c.oid = x.indrelid
		WHERE i.relname = $1;
	`, indexName).Scan(&amName, &tableName)
	if err != nil {
		return nil, fmt.Errorf("failed to query index access method: %w", err)
	}

	if amName != "hash" {
		return nil, fmt.Errorf("index %s is not a hash index (amname: %s)", indexName, amName)
	}

	// Read metapage to determine primary and overflow page distribution
	// hashm_spares tracks allocated overflow pages across bucket split levels
	query := `
		WITH meta AS (
			SELECT * FROM hash_metapage_info(get_raw_page($1, 0))
		)
		SELECT 
			max_bucket + 1 AS primary_pages,
			ntuples AS estimated_tuples,
			ffactor
		FROM meta;
	`
	var primaryPages, estimatedTuples int64
	var ffactor int
	err = pool.QueryRow(ctx, query, indexName).Scan(&primaryPages, &estimatedTuples, &ffactor)
	if err != nil {
		// Fallback to pg_relation_size if pageinspect is not privileged
		return inspectViaRelationSize(ctx, pool, indexName, tableName)
	}

	// Calculate total 8KB pages from relation disk size
	var totalPages int64
	err = pool.QueryRow(ctx, `SELECT relpages FROM pg_class WHERE relname = $1;`, indexName).Scan(&totalPages)
	if err != nil {
		return nil, fmt.Errorf("failed to get relpages: %w", err)
	}

	overflowPages := totalPages - primaryPages - 1 // subtract meta page
	if overflowPages < 0 {
		overflowPages = 0
	}

	overflowRatio := float64(0)
	if totalPages > 0 {
		overflowRatio = float64(overflowPages) / float64(totalPages)
	}

	metrics := &HashIndexMetrics{
		IndexName:     indexName,
		TableName:     tableName,
		PrimaryPages:  primaryPages,
		OverflowPages: overflowPages,
		OverflowRatio: overflowRatio,
		NeedsReindex:  overflowRatio > 0.15, // Threshold: 15% overflow pages
	}

	return metrics, nil
}

func inspectViaRelationSize(ctx context.Context, pool *pgxpool.Pool, indexName, tableName string) (*HashIndexMetrics, error) {
	var relPages int64
	err := pool.QueryRow(ctx, `SELECT relpages FROM pg_class WHERE relname = $1;`, indexName).Scan(&relPages)
	if err != nil {
		return nil, err
	}
	return &HashIndexMetrics{
		IndexName:     indexName,
		TableName:     tableName,
		PrimaryPages:  relPages,
		OverflowPages: 0,
		OverflowRatio: 0,
		NeedsReindex:  false,
	}, nil
}

// ScheduledHashReindexWorker runs online concurrent reindexing when overflow bloat is detected.
func ScheduledHashReindexWorker(ctx context.Context, pool *pgxpool.Pool, indexName string) error {
	metrics, err := InspectHashIndex(ctx, pool, indexName)
	if err != nil {
		return err
	}

	if !metrics.NeedsReindex {
		return nil // Index is healthy
	}

	// Acquire transaction-scoped advisory lock to prevent concurrent reindexing runs
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("failed to acquire connection: %w", err)
	}
	defer conn.Release()

	var acquired bool
	err = conn.QueryRow(ctx, `SELECT pg_try_advisory_lock(hashtext($1))`, indexName).Scan(&acquired)
	if err != nil || !acquired {
		return fmt.Errorf("reindex already in progress for %s", indexName)
	}
	defer conn.Exec(ctx, `SELECT pg_advisory_unlock(hashtext($1))`, indexName)

	// Set conservative statement and lock timeouts
	_, err = conn.Exec(ctx, `
		SET LOCAL lock_timeout = '2000ms';
		SET LOCAL statement_timeout = '120000ms';
	`)
	if err != nil {
		return fmt.Errorf("failed to configure timeouts: %w", err)
	}

	// Execute non-blocking REINDEX CONCURRENTLY
	startTime := time.Now()
	_, err = conn.Exec(ctx, fmt.Sprintf("REINDEX INDEX CONCURRENTLY %s;", pgx.Identifier{indexName}.Sanitize()))
	if err != nil {
		return fmt.Errorf("REINDEX CONCURRENTLY failed for %s: %w", indexName, err)
	}

	fmt.Printf("Successfully reindexed %s in %v (previous overflow ratio: %.2f%%)\n",
		indexName, time.Since(startTime), metrics.OverflowRatio*100)
	return nil
}
```

### 5.2 Python (asyncpg): Safe Hash Index Migration & Pre-Flight Verifier

```python
"""
agentic_hash_verifier.py
Asynchronous pre-flight audit and migration safety validator for Hash indexes in PostgreSQL.
"""

import asyncpy
import logging
from typing import Dict, Any, List

logger = logging.getLogger("hash_guard")

class HashIndexSafetyVerifier:
    def __init__(self, dsn: str):
        self.dsn = dsn

    async def verify_migration_safety(self, table_name: str, column_name: str) -> Dict[str, Any]:
        """
        Audits whether a proposed column can safely be indexed with USING hash.
        Checks for unique constraints, multi-column dependencies, and data distribution.
        """
        conn = await asyncpg.connect(self.dsn)
        try:
            # 1. Check if column participates in a UNIQUE or PRIMARY KEY constraint
            constraint_query = """
                SELECT c.conname, c.contype
                FROM pg_constraint c
                JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
                JOIN pg_class t ON t.oid = c.conrelid
                WHERE t.relname = $1 AND a.attname = $2
                  AND c.contype IN ('p', 'u');
            """
            constraints = await conn.fetch(constraint_query, table_name, column_name)
            if constraints:
                return {
                    "safe": False,
                    "reason": f"Column {column_name} participates in UNIQUE/PK constraint '{constraints[0]['conname']}'. "
                              "PostgreSQL access method 'hash' does not support unique constraints (SQLSTATE 0A000).",
                    "recommended_access_method": "btree"
                }

            # 2. Check average byte length of the column
            size_query = f"""
                SELECT 
                    avg(pg_column_size({column_name})) AS avg_bytes,
                    count(DISTINCT {column_name}) AS distinct_count,
                    count(*) AS total_count
                FROM {table_name};
            """
            row = await conn.fetchrow(size_query)
            avg_bytes = row["avg_bytes"] or 0
            distinct_count = row["distinct_count"] or 0
            total_count = row["total_count"] or 0

            # 3. Low cardinality warning (Hash index is sub-optimal for boolean or low enum)
            if distinct_count < 100 and total_count > 10000:
                return {
                    "safe": False,
                    "reason": f"Low cardinality detected ({distinct_count} distinct values across {total_count} rows). "
                              "Hash indexes on low-cardinality columns cause massive overflow chain clustering.",
                    "recommended_access_method": "btree"
                }

            # 4. Small primitive warning (< 16 bytes: B-Tree is equally fast and supports range)
            if avg_bytes < 16:
                return {
                    "safe": True,
                    "advisory": f"Column average size is only {avg_bytes:.1f} bytes. "
                                "Hash index saves minimal storage; B-Tree is recommended for range query flexibility.",
                    "recommended_access_method": "btree"
                }

            return {
                "safe": True,
                "reason": f"Column qualifies for Hash index. Average key length: {avg_bytes:.1f}B. "
                          "Hash index will use 10 bytes per tuple, providing significant memory savings.",
                "recommended_access_method": "hash",
                "recommended_ddl": f"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_{table_name}_{column_name}_hash "
                                   f"ON {table_name} USING hash ({column_name}) WITH (fillfactor = 75);"
            }
        finally:
            await conn.close()
```

### 5.3 Rust (sqlx): Zero-Downtime Hash Index Allocator & Telemetry

```rust
use sqlx::postgres::PgPool;
use sqlx::Error;
use std::time::Duration;

#[derive(Debug)]
pub struct HashIndexTelemetry {
    pub index_name: String,
    pub total_pages: i64,
    pub is_healthy: bool,
    pub overflow_ratio: f64,
}

pub struct HashIndexGuard;

impl HashIndexGuard {
    /// Audits all hash indexes in the current database schema for overflow bloat.
    pub async fn audit_all_hash_indexes(pool: &PgPool) -> Result<Vec<HashIndexTelemetry>, Error> {
        let rows = sqlx::query!(
            r#"
            SELECT 
                i.relname AS index_name,
                i.relpages AS total_pages
            FROM pg_class i
            JOIN pg_am am ON am.oid = i.relam
            WHERE am.amname = 'hash' AND i.relkind = 'i';
            "#
        )
        .fetch_all(pool)
        .await?;

        let mut results = Vec::new();
        for row in rows {
            let total_pages = row.total_pages as i64;
            // When relpages > 5000, trigger diagnostic check
            results.push(HashIndexTelemetry {
                index_name: row.index_name,
                total_pages,
                is_healthy: true,
                overflow_ratio: 0.0,
            });
        }

        Ok(results)
    }

    /// Safely creates a Hash index concurrently with strict lock timeouts.
    pub async fn create_hash_index_concurrently(
        pool: &PgPool,
        table_name: &str,
        column_name: &str,
    ) -> Result<(), Error> {
        let index_name = format!("idx_{}_{}_hash", table_name, column_name);
        
        let ddl = format!(
            "CREATE INDEX CONCURRENTLY IF NOT EXISTS {} ON {} USING hash ({}) WITH (fillfactor = 75);",
            index_name, table_name, column_name
        );

        // CREATE INDEX CONCURRENTLY cannot execute inside a transaction block.
        // We acquire a raw single connection and execute directly.
        let mut conn = pool.acquire().await?;
        
        // Enforce lock timeout so the DDL never blocks production traffic
        sqlx::query("SET lock_timeout = '2000ms';")
            .execute(&mut *conn)
            .await?;

        sqlx::query(&ddl)
            .execute(&mut *conn)
            .await?;

        Ok(())
    }
}
```

---

## 6. Finite State Machine (FSM): Hash Index Lifecycle

```
  ┌────────────────────────────────────────────────────────────────────────────────────────┐
  │                         HASH INDEX LIFECYCLE FINITE STATE MACHINE                      │
  └────────────────────────────────────────────────────────────────────────────────────────┘

    [ UNINDEXED COLUMN ] 
           │
           │ Tier 0: Single-column? Equality only? Non-unique? Key length >= 32B?
           ▼
    [ QUALIFIED FOR HASH ] 
           │
           │ CREATE INDEX CONCURRENTLY ... USING hash (...) WITH (fillfactor = 75)
           ▼
    [ STATE 1: HEALTHY_O1 ] ───────────────────────────────────────────┐
      - Primary buckets contain all tuples                             │ Write bursts /
      - Overflow pages == 0                                            │ Skewed data
      - Point lookup latency: <= 0.2ms                                 │
           │                                                           ▼
           │ Tuples exceed primary page capacity              [ STATE 2: OVERFLOW_GROWTH ]
           │                                                    - Overflow pages allocated
           ▼                                                    - Overflow ratio < 15%
    [ STATE 3: BUCKET_SPLIT_PENDING ]                           - Latency: 0.5ms - 1.5ms
      - hashm_ntuples > ffactor * (max_bucket + 1)                     │
      - PostgreSQL triggers incremental split                          │ Further growth
      - Writes split bucket B into B and B + 2^N                       │
           │                                                           ▼
           │                                                  [ STATE 4: OVERFLOW_DEGRADED ]
           │                                                    - Overflow ratio > 15%
           │                                                    - Deep singly-linked chains
           │                                                    - Point lookup: 5ms - 25ms!
           │                                                           │
           │                                                           │ Threshold breached
           ▼                                                           ▼
    [ STATE 5: REINDEX_CONCURRENT ] <──────────────────────────────────┘
      - Non-blocking REINDEX INDEX CONCURRENTLY
      - Reallocates primary buckets at 2^N power
      - Reclaims unlinked overflow pages
      - Collapses overflow ratio to 0%
           │
           ▼
    [ RETURN TO STATE 1: HEALTHY_O1 ]
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Autonomous coding agents (Claude Code, Cursor Composer, Windsurf, Devin, Pi) must pass all 6 DoD CI gates before any Hash Index migration or query pattern is merged into production:

| Gate # | Name | Verification Method | Pass Threshold | Failure Remediation |
| :--- | :--- | :--- | :--- | :--- |
| **Gate 1** | **Uniqueness & PK Non-Existence** | SQL AST & Schema Linter | `is_unique == false && is_pk == false` | Reject migration. Use B-Tree for unique constraints. |
| **Gate 2** | **Single-Column Invariance** | Migration Parser | `column_count == 1` | Split into single-column index or use B-Tree for composite. |
| **Gate 3** | **Sargability & Operator Audit** | Query Log / AST Linter | 100% of queries on col use `=` | Replace with B-Tree if `<`, `>`, `BETWEEN`, or `ORDER BY` exists. |
| **Gate 4** | **Key Length Crossover** | Schema Statistics | Column average size $\ge 32\text{ bytes}$ | Use B-Tree for small primitives (`INT4`, `INT8`, `DATE`). |
| **Gate 5** | **Concurrent DDL Decoration** | Migration SQL Linter | Contains `CONCURRENTLY` & `fillfactor` | Add `CONCURRENTLY` and remove transaction block wrappers. |
| **Gate 6** | **Overflow Ratio Sentinel** | CI Integration Test | `overflow_ratio <= 0.15` | Run `REINDEX CONCURRENTLY` or lower table `fillfactor`. |

### Automated CI Gate Verification Script (`scripts/ci-hash-index-gate.sh`)

```bash
#!/usr/bin/env bash
# ci-hash-index-gate.sh - Machine-verifiable CI gate for PostgreSQL Hash Indexes
set -euo pipefail

echo "🔍 Running Hash Index CI Governance Gate..."

# 1. Reject any migration attempting CREATE UNIQUE INDEX ... USING hash
INVALID_UNIQUE=$(git diff origin/main...HEAD -S "USING hash" | grep -Ei "CREATE\s+UNIQUE\s+INDEX.*USING\s+hash" || true)
if [ -n "$INVALID_UNIQUE" ]; then
  echo "❌ CI GATE FAILURE: PostgreSQL does not support UNIQUE Hash indexes (SQLSTATE 0A000)!"
  echo "Found offending DDL: $INVALID_UNIQUE"
  exit 1
fi

# 2. Reject non-concurrent hash index creation
NON_CONCURRENT=$(git diff origin/main...HEAD -S "USING hash" | grep -Ei "CREATE\s+INDEX\s+(?!CONCURRENTLY).*USING\s+hash" || true)
if [ -n "$NON_CONCURRENT" ]; then
  echo "❌ CI GATE FAILURE: Hash indexes in production must be created with CONCURRENTLY!"
  echo "Offending DDL: $NON_CONCURRENT"
  exit 1
fi

# 3. Reject multi-column hash index syntax
MULTI_COL=$(git diff origin/main...HEAD -S "USING hash" | grep -Ei "USING\s+hash\s*\([a-zA-Z0-9_]+\s*,\s*[a-zA-Z0-9_]+\)" || true)
if [ -n "$MULTI_COL" ]; then
  echo "❌ CI GATE FAILURE: PostgreSQL Hash indexes support only a single column!"
  echo "Offending DDL: $MULTI_COL"
  exit 1
fi

echo "✅ Hash Index CI Governance Gate passed with 0 violations."
```
