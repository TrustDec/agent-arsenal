---
description: PostgreSQL B-Tree index deduplication (deduplicate_items = on/off), posting list tuple architecture (BtreePostingTuple), posting list split cascades (_bt_split_posting), high-entropy insertion CPU penalties, dead TID vacuum starvation, INCLUDE clause posting disqualification, amcheck posting list corruption verification, and online zero-downtime reindexing across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, psycopg3), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{index,btree,dedup,posting,schema,migration,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database B-Tree Index Deduplication, Posting List Split Cascades, Key Compression & Deduplication Bloat Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design relational data schemas, audit high-throughput write pipelines, manage secondary indexes, optimize storage footprints, or perform online schema migrations across PostgreSQL (13–17+) in Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Posting List Split Cascade & Leaf-Page Latch Contention Spike" (where concurrent inserts of identical duplicate keys trigger internal `_bt_split_posting()` operations, cascading into leaf page splits, locking adjacent pages with `BTPageOpaque` latches, and causing 50x p99 write latency spikes), the "Inverted High-Entropy Deduplication Penalty ($H \approx \log N$ Overhead)" (where applying default `deduplicate_items = on` to near-unique keys like UUIDv4, microsecond timestamps, or crypto hashes wastes 8%–15% CPU in futile duplicate candidate scans with 0 bytes saved), the "Dead TID Posting List Trapping & Autovacuum Horizon Starvation" (where dead tuples from updates/deletes remain trapped inside posting lists because index scans cannot mark individual TIDs as `LP_DEAD` without full vacuum recompression), the "Collation Drift, OS Glibc Upgrades & Posting List `amcheck` Corruption" (where underlying C-library collation changes break posting list ordering invariants, causing `amcheck` failures and silent omission of rows in Index-Only Scans), the "INCLUDE Column Posting Disqualification Trap" (where declaring volatile non-key columns in `INCLUDE` clauses breaks deduplication eligibility on 100% of rows while still paying the evaluation tax), and the "Synchronous REINDEX AccessExclusiveLock Outage & Bloat Retrofit Crash" (where running naive non-concurrent `REINDEX` locks production tables, exhausting connection pools and taking down OLTP systems) by establishing a strict 5-Tier B-Tree Deduplication Governance Ladder, mathematical space reduction calculus $\mathcal{R}_{\text{space}}$, posting tuple sizing models, a production-ready TypeScript `AgenticBTreeDeduplicationEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state optimization lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 B-Tree Deduplication Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL 13+, the B-Tree index engine (`nbtree`) introduced native **B-Tree Index Deduplication** (`deduplicate_items = on` by default on all non-unique B-Tree indexes). 

In traditional B-Tree implementations, every inserted row generates a dedicated 16-byte index tuple consisting of:
- Tuple Header (`IndexTupleData`, 8 bytes)
- Indexed Key Data ($S_{\text{key}}$ bytes)
- Tuple Item Pointer (`ItemPointerData` / TID: 4-byte Block Number + 2-byte Offset = 6 bytes)

When an indexed column has many duplicate values (e.g., `status = 'PENDING'`, `tenant_id = 42`, `is_active = true`), conventional B-Trees duplicate the identical key value across thousands of leaf tuples, inflating index size, reducing B-Tree page fan-out, and thrashing `shared_buffers`.

With B-Tree Deduplication enabled:
- PostgreSQL coalesces multiple duplicate rows into a single **Posting List Tuple** (`BtreePostingTuple`).
- The tuple stores the common key value **once**, followed by a packed variable-length array ("Posting List") of 6-byte `ItemPointerData` TIDs.
- Space savings on low-to-medium cardinality columns typically range from **60% to 85%**, dramatically shrinking B-Tree leaf pages and keeping working sets entirely within RAM.

However, when autonomous coding agents design schemas or ingest pipelines without understanding the physical mechanics of `nbtree` posting lists, catastrophic production failures emerge:

### The 6 B-Tree Deduplication Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                         THE 6 B-TREE DEDUPLICATION & POSTING SPLIT CATASTROPHES                    |
+------------------------------------+---------------------------------------------------------------+
| 1. Posting List Split Cascade &    | Posting lists capped at INDEX_SIZE_MASK (~2704B, ~440 TIDs);  |
|    Leaf Latch Contention Spike     | concurrent duplicate inserts trigger _bt_split_posting(),     |
|                                    | forcing leaf page splits and 50x p99 write latency spikes.    |
+------------------------------------+---------------------------------------------------------------+
| 2. Inverted High-Entropy Penalty   | Enabling deduplication on unique or near-unique keys (UUIDv4, |
|    (H approx log N Overhead)       | timestamps) forces futile candidate probing on every write;   |
|                                    | burns 8%-15% CPU with exactly 0% storage reduction.           |
+------------------------------------+---------------------------------------------------------------+
| 3. Dead TID Posting Trapping &     | Reader index scans cannot mark individual TIDs as LP_DEAD;   |
|    Autovacuum Horizon Starvation   | dead tuples remain trapped inside posting arrays until full   |
|                                    | VACUUM recompression, accelerating physical index bloat.      |
+------------------------------------+---------------------------------------------------------------+
| 4. Collation Drift, Glibc Upgrades | OS C-library upgrades (e.g. glibc 2.28 -> 2.33) change string |
|    & Posting List amcheck Corrupt  | equality rules; corrupted posting lists silently omit rows in |
|                                    | Index-Only Scans and trigger fatal amcheck invariant errors.  |
+------------------------------------+---------------------------------------------------------------+
| 5. INCLUDE Column Posting          | Deduplication requires 100% equality across both key and ALL  |
|    Disqualification Trap           | INCLUDE columns; variable payload attributes disqualify dedup |
|                                    | on every write while paying the candidate search penalty.     |
+------------------------------------+---------------------------------------------------------------+
| 6. Synchronous REINDEX Lockout     | Naive REINDEX acquires AccessExclusiveLock on live tables;    |
|    & Deduplication Retrofit Crash  | blocks read/write traffic during bloat remediation, crashing   |
|                                    | connection pools and violating 99.99% availability SLAs.      |
+------------------------------------+---------------------------------------------------------------+
```

---

### The 5-Tier B-Tree Deduplication Governance Ladder

To maintain maximum write throughput, zero index bloat, and sub-millisecond query execution, autonomous agents must adhere to the 5-Tier Governance Ladder:

```
+----------------------------------------------------------------------------------------------------+
|                           THE 5-TIER B-TREE DEDUPLICATION GOVERNANCE LADDER                         |
+----------------------------------------------------------------------------------------------------+
| Tier 0: Cardinality & Entropy Profiling                                                            |
|  - Check pg_stats for n_distinct: if n_distinct < 0 (high cardinality) or rho = K/N > 0.10,         |
|    EXPLICITLY declare WITH (deduplicate_items = off) to eliminate useless candidate search loops.   |
+----------------------------------------------------------------------------------------------------+
| Tier 1: Low/Medium Cardinality Deduplication Invariant                                             |
|  - On status enums, foreign keys, and tenant columns (rho <= 0.05), enforce deduplicate_items = on |
|    paired with fillfactor = 90 to reserve headroom for posting list growth and avoid page splits.  |
+----------------------------------------------------------------------------------------------------+
| Tier 2: INCLUDE Column Anti-Churn Governance                                                       |
|  - Never add volatile or high-entropy non-key columns (timestamps, IDs) to INCLUDE on deduplicated   |
|    indexes; ensure INCLUDE columns are immutable or low-cardinality flags to prevent dedup breaks. |
+----------------------------------------------------------------------------------------------------+
| Tier 3: Aggressive Autovacuum for Posting List Compaction                                          |
|  - Configure autovacuum_vacuum_scale_factor = 0.05 and autovacuum_vacuum_cost_limit = 2000 on       |
|    tables with deduplicated indexes to unpack and reclaim dead TIDs before posting splits occur.   |
+----------------------------------------------------------------------------------------------------+
| Tier 4: Autonomous amcheck Health Watchdog & Zero-Downtime Concurrent Reindex                      |
|  - Continuous automated execution of bt_index_parent_check() detecting posting list corruption,    |
|    paired with safe two-phase REINDEX INDEX CONCURRENTLY with lock_timeout = 2000ms.               |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. The 6 Failure Modes & Root-Cause Analysis

### 1. Posting List Split Cascade & Leaf-Page Latch Contention Spike (`_bt_split_posting`)

In PostgreSQL's `nbtree` implementation, a posting list tuple cannot expand indefinitely. It is strictly bounded by `INDEX_SIZE_MASK` (maximum 2704 bytes on standard 8KB pages). Since each TID consumes 6 bytes (`ItemPointerData`: 4-byte `ip_blkid` + 2-byte `ip_posid`), a single posting list tuple can hold at most:

$$M_{\max} = \left\lfloor \frac{2704 - \text{sizeof(IndexTupleData)} - S_{\text{key}}}{6} \right\rfloor \approx 440 \text{ TIDs}$$

When an incoming `INSERT` shares an existing key whose posting list has already reached $M_{\max}$ (or whose insertion would exceed the available free space on the current 8KB leaf page), the engine cannot append the TID in-place. It must execute `_bt_split_posting()`:
1. It allocates a temporary working buffer.
2. It divides the existing $M$ TIDs into two smaller posting lists (or one posting list and a standalone tuple).
3. If the leaf page has insufficient space to hold the new line pointer (`ItemId`) and index tuple header, the posting split immediately forces a **B-Tree Leaf Page Split** (`_bt_split()`).
4. `_bt_split()` acquires exclusive latches (`BTPageOpaque`) on the target leaf page and its right neighbor, allocates a new 8KB disk page from the buffer manager, and updates the parent downlink in the branch page.

Under high-concurrency ingestion (e.g. 10,000 workers inserting rows with `status = 'QUEUED'`), multiple backends concurrently attempt posting splits on the identical leaf page, generating severe latch contention on `buffer_content` locks and spiking write latency from 0.5ms to 25ms+.

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Default fillfactor on heavy duplicate insert table
-- Default fillfactor = 100 leaves zero byte headroom on leaf pages.
-- Every posting list expansion immediately triggers a destructive page split!
CREATE INDEX idx_events_status ON event_log (status);

-- ✅ PRODUCTION INVARIANT: Calibrated fillfactor + posting headroom
-- Reserving 10% page headroom (fillfactor = 90) allows posting lists to expand
-- and absorb duplicate inserts without triggering immediate physical leaf page splits.
CREATE INDEX idx_events_status ON event_log (status)
WITH (deduplicate_items = on, fillfactor = 90);
```

---

### 2. The Inverted High-Entropy Deduplication Penalty ($H \approx \log N$)

When a column contains unique or near-unique values—such as `UUIDv4`, high-resolution timestamps (`timestamptz(6)`), cryptographic tokens, or auto-incrementing surrogate keys—the probability of two consecutive inserts sharing the identical key approaches zero:

$$P(\text{duplicate}) = 1 - \prod_{i=0}^{N-1} \left(1 - \frac{i}{2^{122}}\right) \approx 0$$

Despite this mathematical certainty, if `deduplicate_items = on` (PostgreSQL's default), the index insertion routine (`_bt_insertonpg`) still executes the deduplication candidate inspection logic:
1. It allocates a candidate deduplication state buffer `BTVacState`.
2. It reads neighboring index tuples on the leaf page to evaluate whether the incoming key matches any existing key.
3. It performs full collation comparisons (`bttextcmp` / `btint4cmp`).
4. It determines that 0 duplicate candidates exist, discards the candidate state, and inserts a conventional standalone index tuple.

On streaming write-heavy workloads (e.g. 50,000 inserts/second), this futile candidate search increases CPU consumption by 8% to 15% and degrades overall ingestion throughput without compressing a single byte of storage!

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Leaving default deduplication on high-entropy UUIDs
-- PostgreSQL wastes CPU cycles evaluating duplicate candidates on every insert.
CREATE INDEX idx_api_requests_trace_id ON api_requests (trace_id); -- trace_id is UUIDv4

-- ✅ PRODUCTION INVARIANT: Explicitly disable deduplication on high-entropy keys
-- Bypasses _bt_dedup_start_pending(), slashing insert CPU overhead by 12%.
CREATE INDEX idx_api_requests_trace_id ON api_requests (trace_id)
WITH (deduplicate_items = off);
```

---

### 3. Dead TID Posting List Trapping & Autovacuum Horizon Starvation

In standard (un-deduplicated) B-Tree indexes, when a transaction updates or deletes a row, the corresponding heap tuple becomes dead. During subsequent queries, index scans (`_bt_checkkeys`) observe that the referenced heap tuple is no longer visible to any running transaction and mark the index line pointer with the `LP_DEAD` flag. This allows subsequent inserts on that page to immediately overwrite the dead index tuple (known as opportunistic index tuple deletion), preventing index bloat without waiting for `VACUUM`.

**In deduplicated posting lists, this opportunistic pruning is physically impossible!**
- A line pointer on a leaf page points to the **entire posting list tuple**, which contains up to 440 individual TIDs.
- A reader index scan cannot modify individual 6-byte TIDs inside the packed varlena posting array without taking an exclusive buffer lock and rewriting the entire tuple.
- Consequently, dead TIDs remain trapped inside the posting list until full `VACUUM` runs:

```
[Leaf Page Line Pointer 12] ---> [Posting Tuple: Key="ACTIVE" | TIDs: (Block 1, Off 3)*, (Block 1, Off 8), (Block 2, Off 1)*]
                                                                        * = DEAD TUPLE (cannot be marked LP_DEAD!)
```

If `autovacuum` is delayed (e.g., due to conservative default scale factors `autovacuum_vacuum_scale_factor = 0.20`), dead TIDs accumulate inside posting lists, artificially inflating index size and causing posting lists to hit $M_{\max}$ prematurely, forcing avoidable posting splits!

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Default autovacuum on high-churn duplicate tables
-- Dead TIDs stay trapped in posting lists until 20% of the table is mutated.
ALTER TABLE user_subscriptions SET (autovacuum_vacuum_scale_factor = 0.20);

-- ✅ PRODUCTION INVARIANT: Aggressive autovacuum for deduplicated posting compaction
-- Triggers VACUUM at 5% churn, allowing _bt_delitems_delete() to decompress posting lists,
-- purge dead TIDs, and recompact posting arrays before splits occur.
ALTER TABLE user_subscriptions SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_cost_limit = 2000,
  autovacuum_vacuum_cost_delay = 2
);
```

---

### 4. Collation Drift, OS Glibc Upgrades & Posting List `amcheck` Corruption

B-Tree deduplication relies on strict, deterministic equality: two keys $k_1$ and $k_2$ are coalesced into a single posting list if and only if:

$$\text{compare}(k_1, k_2) = 0$$

When the operating system's C-library (`glibc` on Linux) is updated—for instance, upgrading Debian/Ubuntu or CentOS from `glibc 2.28` to `2.33`—the Unicode collation algorithm and character sorting tables frequently change. 

If an index contains text keys that were deduplicated under the old glibc collation:
1. Under the new collation, two keys previously considered identical may now compare as $k_1 < k_2$ or $k_1 > k_2$.
2. The posting list now illegally merges keys that the current collation considers distinct!
3. When queries execute an **Index-Only Scan**, PostgreSQL returns the single stored key for all matching TIDs, corrupting business data.
4. When `amcheck`'s `bt_index_parent_check()` runs, it detects the broken ordering and raises a fatal exception: `posting list contains out-of-order items`.

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Blindly trusting collations across OS upgrades
-- Leaves silent posting list corruption undetected in production.

-- ✅ PRODUCTION INVARIANT: Autonomous amcheck verification & version pinning
-- Pin deterministic ICU collations or verify posting list integrity after OS changes:
CREATE COLLATION unicode_deterministic (
  provider = icu,
  locale = 'und',
  deterministic = true
);

-- Verification via amcheck (must be part of automated CI and daily cron):
CREATE EXTENSION IF NOT EXISTS amcheck;

SELECT bt_index_parent_check(index => c.oid, check_uniqueness => true)
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam
WHERE am.amname = 'btree'
  AND c.relname = 'idx_user_subscriptions_status';
```

---

### 5. The `INCLUDE` Column Posting Disqualification Trap

PostgreSQL 11 introduced the `INCLUDE` clause, allowing secondary indexes to carry non-key payload attributes directly in leaf pages to enable Index-Only Scans.

In PostgreSQL 13+, B-Tree deduplication was extended to support `INCLUDE` indexes, **but under one non-negotiable physical constraint**:
> Two tuples can ONLY be deduplicated into a posting list if BOTH the indexed key columns AND ALL `INCLUDE` payload columns are byte-for-byte identical!

If an autonomous coding agent creates a covering index like:
```sql
CREATE INDEX idx_audit_type ON audit_events (event_type) INCLUDE (created_at);
```
While `event_type` has low cardinality (e.g. `'LOGIN'`, `'LOGOUT'`, `'PURCHASE'`), `created_at` has microsecond resolution and changes on every row.
- **Result**: Exactly **0%** of rows can ever be deduplicated!
- **Penalty**: The index engine still allocates deduplication tracking state, performs candidate scans on every write, determines that `created_at` differs, and fails to merge.
- The index consumes identical disk space as a pre-PG13 index, while write latency increases by 10%.

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Volatile timestamp in INCLUDE of low-cardinality index
-- 100% deduplication disqualification + candidate search CPU waste.
CREATE INDEX idx_orders_status_created 
ON orders (status) 
INCLUDE (created_at);

-- ✅ PRODUCTION INVARIANT: Composite key for sort/filter OR explicit dedup deactivation
-- Option A: If queries filter on status and sort by created_at, make created_at a key:
CREATE INDEX idx_orders_status_created 
ON orders (status, created_at)
WITH (deduplicate_items = off); -- created_at is unique, disable dedup to save CPU

-- Option B: If created_at is strictly for projection and status is low-cardinality,
-- keep the index thin (status only) with deduplication ON, and fetch created_at from heap:
CREATE INDEX idx_orders_status 
ON orders (status) 
WITH (deduplicate_items = on, fillfactor = 90);
```

---

### 6. The Synchronous REINDEX AccessExclusiveLock Outage & Deduplication Retrofit Crash

When an engineering team upgrades a production database from PostgreSQL 11 or 12 to PostgreSQL 13+, existing B-Tree indexes **are not automatically deduplicated**. They retain their legacy uncompressed tuple format on disk.

To benefit from deduplication, indexes must be rebuilt (`REINDEX`).

If an autonomous agent detects bloat or prepares an upgrade migration and issues:
```sql
REINDEX TABLE orders;
-- OR
REINDEX DATABASE production;
```
PostgreSQL acquires an **`AccessExclusiveLock`** on each table being reindexed:
- All incoming `SELECT`, `INSERT`, `UPDATE`, and `DELETE` queries are immediately blocked.
- Any running query prevents the `REINDEX` from starting, while subsequent queries queue up behind the `AccessExclusiveLock`.
- Within seconds, application connection pools (PgBouncer, HikariCP) are exhausted, triggering cascading 504 gateway timeouts across the entire platform.

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Synchronous REINDEX on production database
-- Instant downtime: locks all tables exclusively.
REINDEX INDEX idx_orders_customer_id;

-- ✅ PRODUCTION INVARIANT: Two-Phase Online Concurrent Reindexing with Timeout Fencing
-- Rebuilds index concurrently without blocking concurrent reads or writes:
SET lock_timeout = '2s';
SET statement_timeout = '2h';
REINDEX INDEX CONCURRENTLY idx_orders_customer_id;
```

---

## 3. Mathematical Models: Deduplication Compression Ratio, Posting Capacity & Split Dynamics

### 1. Deduplication Space Reduction Ratio $\mathcal{R}_{\text{space}}$

Let $N$ be the total number of index rows, $K$ be the number of distinct keys, and $\bar{M} = N / K$ be the average number of duplicates per key.
Let $S_{\text{key}}$ be the byte size of the indexed key datum, and $H_{\text{tuple}} = 8$ bytes be the B-Tree index tuple header (`IndexTupleData`).
A standard un-deduplicated B-Tree tuple occupies:

$$S_{\text{std}} = \text{MAXALIGN}(H_{\text{tuple}} + S_{\text{key}} + 6)$$

A deduplicated posting list tuple containing $M$ duplicates occupies:

$$S_{\text{dedup}}(M) = \text{MAXALIGN}\left(H_{\text{tuple}} + S_{\text{key}} + 6 \times M\right)$$

The overall storage reduction ratio $\mathcal{R}_{\text{space}}$ for an index with average multiplicity $\bar{M}$ is:

$$\mathcal{R}_{\text{space}} = 1 - \frac{\frac{1}{\bar{M}} \cdot S_{\text{dedup}}(\bar{M})}{S_{\text{std}}} = 1 - \frac{\text{MAXALIGN}(H_{\text{tuple}} + S_{\text{key}} + 6 \bar{M})}{\bar{M} \cdot \text{MAXALIGN}(H_{\text{tuple}} + S_{\text{key}} + 6)}$$

As multiplicity $\bar{M} \to \infty$, the asymptotic space reduction converges to:

$$\lim_{\bar{M} \to \infty} \mathcal{R}_{\text{space}} = 1 - \frac{6}{\text{MAXALIGN}(H_{\text{tuple}} + S_{\text{key}} + 6)}$$

For an 8-byte integer key (`int8` / `bigint`):
- $S_{\text{std}} = \text{MAXALIGN}(8 + 8 + 6) = 24$ bytes per tuple.
- For $\bar{M} = 100$ duplicates, uncompressed storage = $100 \times 24 = 2,400$ bytes.
- Deduplicated storage = $\text{MAXALIGN}(8 + 8 + 600) = 616$ bytes.
- **$\mathcal{R}_{\text{space}} = 1 - \frac{616}{2400} = 74.3\%$ physical storage reduction!**

---

### 2. Maximum Posting List TID Capacity $M_{\max}$

Because PostgreSQL restricts index tuples to at most 1/3 of an 8KB page (`INDEX_SIZE_MASK` = 2704 bytes), the maximum number of TIDs that can reside within a single posting tuple is strictly bounded:

$$M_{\max}(S_{\text{key}}) = \left\lfloor \frac{2704 - H_{\text{tuple}} - S_{\text{key}}}{6} \right\rfloor$$

| Key Data Type | Key Size $S_{\text{key}}$ | Max TIDs per Posting List $M_{\max}$ | Max Posting Tuple Size |
| :--- | :--- | :--- | :--- |
| `int2` / `smallint` | 2 bytes | 449 TIDs | 2702 bytes |
| `int4` / `integer` | 4 bytes | 448 TIDs | 2696 bytes |
| `int8` / `bigint` | 8 bytes | 448 TIDs | 2704 bytes |
| `uuid` | 16 bytes | 446 TIDs | 2700 bytes |
| `varchar(64)` | 68 bytes (varlena) | 437 TIDs | 2698 bytes |

When a duplicate key surpasses $M_{\max}$, PostgreSQL automatically spawns a second posting tuple for the same key.

---

### 3. Posting List Split Cascade Probability $P_{\text{split}}(M, \lambda)$

Let $M$ be the current number of TIDs in a posting tuple, and let $\lambda$ be the arrival rate of inserts matching that specific key. Under Poisson arrival dynamics, the probability that the posting list will reach capacity $M_{\max}$ within time window $\Delta t$ and trigger `_bt_split_posting()` is:

$$P_{\text{split}}(\Delta t) = 1 - \sum_{k=0}^{M_{\max} - M - 1} \frac{(\lambda \Delta t)^k e^{-\lambda \Delta t}}{k!}$$

When $M \to M_{\max}$, $P_{\text{split}} \to 1.0$. If the leaf page utilization $U_{\text{page}} \ge 0.95$ (as occurs with default `fillfactor = 100`), the posting split is guaranteed to trigger a subsequent leaf page split:

$$P(\text{leaf\_split} \mid \text{posting\_split}) = \begin{cases} 
0, & \text{if } \text{PageFreeSpace} \ge S_{\text{new\_tuple}} + \text{sizeof(ItemId)} \\
1.0, & \text{otherwise}
\end{cases}$$

This proves why **`fillfactor = 90` is mandatory** for deduplicated indexes experiencing bursty duplicate inserts.

---

### 4. Insertion CPU Overhead Differential $\Delta C_{\text{cpu}}(H)$ vs Shannon Entropy $H$

Let $H$ be the normalized Shannon entropy of the indexed column values:

$$H = -\sum_{i=1}^{K} p_i \log_2(p_i) \quad \text{where } p_i = \frac{n_i}{N}$$

The CPU cost differential between deduplication enabled vs disabled per insertion is modeled as:

$$\Delta C_{\text{cpu}}(H) = C_{\text{probe}} - P(\text{merge} \mid H) \cdot C_{\text{save}}$$

Where:
- $C_{\text{probe}}$ is the CPU cycles spent searching leaf tuples for duplicate candidates ($\approx 120$ CPU cycles).
- $C_{\text{save}}$ is the CPU cycles saved from reduced page allocations and B-Tree height traversals ($\approx 450$ CPU cycles).
- $P(\text{merge} \mid H)$ is the probability of finding a mergeable candidate tuple on the current leaf page, which decays exponentially with entropy: $P(\text{merge} \mid H) \approx 2^{-H / H_{\max}}$.

When $H \to H_{\max}$ (unique keys like UUIDv4 or timestamps):
- $P(\text{merge}) \to 0$.
- $\Delta C_{\text{cpu}} \approx +C_{\text{probe}} > 0$ (a **pure 10%–15% CPU penalty with zero benefit**).
- Therefore, when $H \ge 0.9 \cdot H_{\max}$ or $K/N \ge 0.10$, deduplication **MUST be disabled**.

---

## 4. Production-Ready TypeScript Guard Engine: `AgenticBTreeDeduplicationEngine`

This engine inspects PostgreSQL index catalogs (`pg_index`, `pg_class`, `pg_am`, `pg_stats`), calculates deduplication eligibility, estimates space savings, flags posting list split risks, verifies `amcheck` status, and generates zero-downtime migration DDL.

```typescript
// src/engine/AgenticBTreeDeduplicationEngine.ts

import { Pool, PoolClient } from 'pg';

export interface BTreeIndexAuditResult {
  schemaName: string;
  tableName: string;
  indexName: string;
  columnNames: string[];
  includeColumns: string[];
  totalRows: number;
  distinctKeys: number;
  cardinalityRatio: number;
  isUnique: boolean;
  deduplicateItemsEnabled: boolean;
  fillfactor: number;
  indexSizeBytes: number;
  estimatedSpaceSavingsBytes: number;
  status: 'OPTIMAL' | 'DEDUP_RECOMMENDED' | 'DEDUP_PENALTY_RISK' | 'INCLUDE_DISQUALIFIED' | 'CORRUPTED';
  recommendedDdl: string[];
  reasons: string[];
}

export interface EngineConfig {
  maxCardinalityRatioForDedup: number; // default: 0.05
  minTableRowsForAnalysis: number;     // default: 10,000
  lockTimeoutMs: number;               // default: 2,000ms
}

export class AgenticBTreeDeduplicationEngine {
  private pool: Pool;
  private config: EngineConfig;

  constructor(pool: Pool, config?: Partial<EngineConfig>) {
    this.pool = pool;
    this.config = {
      maxCardinalityRatioForDedup: config?.maxCardinalityRatioForDedup ?? 0.05,
      minTableRowsForAnalysis: config?.minTableRowsForAnalysis ?? 10_000,
      lockTimeoutMs: config?.lockTimeoutMs ?? 2000,
    };
  }

  public async auditIndex(schemaName: string, indexName: string): Promise<BTreeIndexAuditResult> {
    const client: PoolClient = await this.pool.connect();
    try {
      // 1. Fetch index topology, fillfactor, dedup option, and include columns
      const indexQuery = `
        SELECT
          n.nspname AS schema_name,
          t.relname AS table_name,
          i.relname AS index_name,
          ix.indisunique AS is_unique,
          ix.indnatts AS total_attrs,
          ix.indnkeyatts AS key_attrs,
          pg_relation_size(i.oid) AS index_bytes,
          COALESCE(t.reltuples, 0)::bigint AS table_rows,
          COALESCE(
            (SELECT option_value = 'true' OR option_value = 'on'
             FROM pg_options_to_table(i.reloptions)
             WHERE option_name = 'deduplicate_items'),
            true
          ) AS dedup_enabled,
          COALESCE(
            (SELECT option_value::int
             FROM pg_options_to_table(i.reloptions)
             WHERE option_name = 'fillfactor'),
            100
          ) AS current_fillfactor,
          ARRAY(
            SELECT pg_get_indexdef(ix.indexrelid, k + 1, true)
            FROM generate_series(0, ix.indnkeyatts - 1) k
          ) AS key_columns,
          ARRAY(
            SELECT pg_get_indexdef(ix.indexrelid, k + 1, true)
            FROM generate_series(ix.indnkeyatts, ix.indnatts - 1) k
          ) AS include_columns
        FROM pg_index ix
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_class t ON t.oid = ix.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_am am ON am.oid = i.relam
        WHERE n.nspname = $1
          AND i.relname = $2
          AND am.amname = 'btree';
      `;

      const res = await client.query(indexQuery, [schemaName, indexName]);
      if (res.rows.length === 0) {
        throw new Error(`B-Tree index ${schemaName}.${indexName} not found.`);
      }

      const row = res.rows[0];
      const tableRows = Math.max(1, Number(row.table_rows));
      const keyCols: string[] = row.key_columns || [];
      const includeCols: string[] = row.include_columns || [];
      const isUnique: boolean = row.is_unique;
      const dedupEnabled: boolean = row.dedup_enabled;
      const fillfactor: number = row.current_fillfactor;
      const indexBytes: number = Number(row.index_bytes);

      // 2. Fetch column distinct estimate from pg_stats for the primary key column
      const primaryCol = keyCols[0]?.replace(/"/g, '') || '';
      let distinctEstimate = tableRows;

      if (primaryCol && !primaryCol.includes('(')) {
        const statsQuery = `
          SELECT n_distinct
          FROM pg_stats
          WHERE schemaname = $1 AND tablename = $2 AND attname = $3;
        `;
        const statsRes = await client.query(statsQuery, [schemaName, row.table_name, primaryCol]);
        if (statsRes.rows.length > 0) {
          const nDistinct = Number(statsRes.rows[0].n_distinct);
          if (nDistinct < 0) {
            distinctEstimate = Math.abs(nDistinct) * tableRows;
          } else {
            distinctEstimate = nDistinct;
          }
        }
      }

      const cardinalityRatio = distinctEstimate / tableRows;
      const reasons: string[] = [];
      const recommendedDdl: string[] = [];
      let status: BTreeIndexAuditResult['status'] = 'OPTIMAL';
      let estimatedSavings = 0;

      // Deduplication is not applicable to unique indexes
      if (isUnique) {
        return {
          schemaName,
          tableName: row.table_name,
          indexName,
          columnNames: keyCols,
          includeColumns: includeCols,
          totalRows: tableRows,
          distinctKeys: distinctEstimate,
          cardinalityRatio: 1.0,
          isUnique: true,
          deduplicateItemsEnabled: false,
          fillfactor,
          indexSizeBytes: indexBytes,
          estimatedSpaceSavingsBytes: 0,
          status: 'OPTIMAL',
          recommendedDdl: [],
          reasons: ['Index is UNIQUE; B-Tree deduplication is inherently disabled.'],
        };
      }

      // Check for INCLUDE Column Posting Disqualification
      if (includeCols.length > 0 && dedupEnabled) {
        status = 'INCLUDE_DISQUALIFIED';
        reasons.push(
          `Index includes non-key columns [${includeCols.join(', ')}]. If these change across duplicates, deduplication is 100% disqualified while still paying candidate probe CPU tax.`
        );
        recommendedDdl.push(`-- If payload columns vary per row, disable deduplication to eliminate write overhead:`);
        recommendedDdl.push(`ALTER INDEX "${schemaName}"."${indexName}" SET (deduplicate_items = off);`);
        recommendedDdl.push(`-- Run online concurrent reindex:`);
        recommendedDdl.push(`SET lock_timeout = '${this.config.lockTimeoutMs}ms';`);
        recommendedDdl.push(`REINDEX INDEX CONCURRENTLY "${schemaName}"."${indexName}";`);
      }

      // Check for High-Entropy Deduplication Penalty
      else if (cardinalityRatio > this.config.maxCardinalityRatioForDedup && dedupEnabled) {
        status = 'DEDUP_PENALTY_RISK';
        reasons.push(
          `High cardinality detected (distinct ratio ${(cardinalityRatio * 100).toFixed(1)}% > ${(this.config.maxCardinalityRatioForDedup * 100).toFixed(1)}%). Deduplication candidate scans burn 8%-15% CPU with near-zero space savings.`
        );
        recommendedDdl.push(`ALTER INDEX "${schemaName}"."${indexName}" SET (deduplicate_items = off);`);
        recommendedDdl.push(`SET lock_timeout = '${this.config.lockTimeoutMs}ms';`);
        recommendedDdl.push(`REINDEX INDEX CONCURRENTLY "${schemaName}"."${indexName}";`);
      }

      // Check for Low-Cardinality Uncompressed Indexes (Eligible for Deduplication)
      else if (cardinalityRatio <= this.config.maxCardinalityRatioForDedup && !dedupEnabled) {
        status = 'DEDUP_RECOMMENDED';
        estimatedSavings = Math.floor(indexBytes * 0.65);
        reasons.push(
          `Low cardinality detected (distinct ratio ${(cardinalityRatio * 100).toFixed(1)}% <= ${(this.config.maxCardinalityRatioForDedup * 100).toFixed(1)}%). Enabling deduplication can compress index by ~60%-75% (${(estimatedSavings / 1024 / 1024).toFixed(1)} MB projected reduction).`
        );
        recommendedDdl.push(`ALTER INDEX "${schemaName}"."${indexName}" SET (deduplicate_items = on, fillfactor = 90);`);
        recommendedDdl.push(`SET lock_timeout = '${this.config.lockTimeoutMs}ms';`);
        recommendedDdl.push(`REINDEX INDEX CONCURRENTLY "${schemaName}"."${indexName}";`);
      }

      // Check if fillfactor is 100 on a deduplicated index
      else if (dedupEnabled && fillfactor >= 100) {
        reasons.push(`fillfactor is 100 on deduplicated index. Burst duplicate inserts risk immediate page splits on posting expansion.`);
        recommendedDdl.push(`ALTER INDEX "${schemaName}"."${indexName}" SET (fillfactor = 90);`);
      }

      return {
        schemaName,
        tableName: row.table_name,
        indexName,
        columnNames: keyCols,
        includeColumns: includeCols,
        totalRows: tableRows,
        distinctKeys: distinctEstimate,
        cardinalityRatio,
        isUnique: false,
        deduplicateItemsEnabled: dedupEnabled,
        fillfactor,
        indexSizeBytes: indexBytes,
        estimatedSpaceSavingsBytes: estimatedSavings,
        status,
        recommendedDdl,
        reasons: reasons.length > 0 ? reasons : ['B-Tree deduplication and fillfactor configurations are optimal.'],
      };
    } finally {
      client.release();
    }
  }

  public async verifyIndexWithAmcheck(schemaName: string, indexName: string): Promise<{ valid: boolean; error?: string }> {
    const client: PoolClient = await this.pool.connect();
    try {
      await client.query(`CREATE EXTENSION IF NOT EXISTS amcheck;`);
      const verifyQuery = `
        SELECT bt_index_parent_check(c.oid, true)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2;
      `;
      await client.query(verifyQuery, [schemaName, indexName]);
      return { valid: true };
    } catch (err: unknown) {
      return {
        valid: false,
        error: err instanceof Error ? err.message : String(err),
      };
    } finally {
      client.release();
    }
  }
}
```

---

## 5. Production Implementations Across Runtimes

### 1. PostgreSQL Schema Migrations (PG 13–17 Standard DDL)

```sql
-- migrations/20261101000000_btree_deduplication_hardening.sql

-- 1. Create low-cardinality status index WITH DEDUPLICATION and fillfactor = 90
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_invoices_status
ON invoices (status)
WITH (deduplicate_items = on, fillfactor = 90);

-- 2. Create high-entropy UUID foreign key index WITH DEDUPLICATION DISABLED
-- Prevents pointless _bt_dedup_start_pending() candidate search loop on every insert
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_invoices_payment_token
ON invoices (payment_token)
WITH (deduplicate_items = off);

-- 3. Tune table autovacuum to proactively clean dead TIDs from posting lists
ALTER TABLE invoices SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_cost_limit = 2000,
  autovacuum_vacuum_cost_delay = 2
);

-- 4. Automated amcheck integrity validation procedure
CREATE OR REPLACE FUNCTION verify_btree_posting_integrity(target_index text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_oid oid;
BEGIN
  PERFORM 1 FROM pg_extension WHERE extname = 'amcheck';
  IF NOT FOUND THEN
    CREATE EXTENSION amcheck;
  END IF;

  SELECT c.oid INTO v_oid
  FROM pg_class c
  WHERE c.relname = target_index;

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'Index % does not exist', target_index;
  END IF;

  -- Runs parent checks verifying posting lists are sorted and free of corruption
  PERFORM bt_index_parent_check(index => v_oid, check_uniqueness => true);
  RETURN true;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'B-Tree integrity check failed for %: %', target_index, SQLERRM;
    RETURN false;
END;
$$;
```

---

### 2. Go (`jackc/pgx/v5`): Background Health Sentinel & Reindexer

```go
// internal/store/btree_dedup_sentinel.go
package store

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type BTreeIndexAudit struct {
	IndexName        string
	TableName        string
	DedupEnabled     bool
	Fillfactor       int
	IndexSizeMB      float64
	CardinalityRatio float64
	Recommendation   string
}

type BTreeDedupSentinel struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewBTreeDedupSentinel(pool *pgxpool.Pool, logger *slog.Logger) *BTreeDedupSentinel {
	if logger == nil {
		logger = slog.Default()
	}
	return &BTreeDedupSentinel{pool: pool, logger: logger}
}

// AuditIndexes scans all B-Tree indexes on the database and evaluates deduplication efficiency.
func (s *BTreeDedupSentinel) AuditIndexes(ctx context.Context, schema string) ([]BTreeIndexAudit, error) {
	query := `
		SELECT
			c.relname AS index_name,
			t.relname AS table_name,
			COALESCE(
				(SELECT option_value = 'true' OR option_value = 'on'
				 FROM pg_options_to_table(c.reloptions)
				 WHERE option_name = 'deduplicate_items'),
				true
			) AS dedup_enabled,
			COALESCE(
				(SELECT option_value::int
				 FROM pg_options_to_table(c.reloptions)
				 WHERE option_name = 'fillfactor'),
				100
			) AS current_fillfactor,
			ROUND((pg_relation_size(c.oid)::numeric / 1024 / 1024), 2)::float8 AS index_size_mb,
			COALESCE(
				(SELECT ABS(s.n_distinct)::float8 / NULLIF(t.reltuples, 0)::float8
				 FROM pg_stats s
				 WHERE s.schemaname = $1 AND s.tablename = t.relname AND s.attname = pg_get_indexdef(ix.indexrelid, 1, true)),
				1.0
			) AS cardinality_ratio
		FROM pg_index ix
		JOIN pg_class c ON c.oid = ix.indexrelid
		JOIN pg_class t ON t.oid = ix.indrelid
		JOIN pg_namespace n ON n.oid = t.relnamespace
		JOIN pg_am am ON am.oid = c.relam
		WHERE n.nspname = $1
		  AND am.amname = 'btree'
		  AND NOT ix.indisunique
		  AND t.reltuples > 5000;
	`

	rows, err := s.pool.Query(ctx, query, schema)
	if err != nil {
		return nil, fmt.Errorf("failed to audit btree indexes: %w", err)
	}
	defer rows.Close()

	var audits []BTreeIndexAudit
	for rows.Next() {
		var a BTreeIndexAudit
		if err := rows.Scan(
			&a.IndexName,
			&a.TableName,
			&a.DedupEnabled,
			&a.Fillfactor,
			&a.IndexSizeMB,
			&a.CardinalityRatio,
		); err != nil {
			return nil, fmt.Errorf("scan error: %w", err)
		}

		if a.CardinalityRatio > 0.10 && a.DedupEnabled {
			a.Recommendation = "DISABLE_DEDUP: High cardinality wastes CPU searching for duplicate candidates."
		} else if a.CardinalityRatio <= 0.05 && !a.DedupEnabled {
			a.Recommendation = "ENABLE_DEDUP: Low cardinality can save 60%-80% disk space via posting lists."
		} else if a.DedupEnabled && a.Fillfactor >= 100 {
			a.Recommendation = "SET_FILLFACTOR_90: Add headroom to prevent page splits on duplicate bursts."
		} else {
			a.Recommendation = "OPTIMAL"
		}
		audits = append(audits, a)
	}

	return audits, rows.Err()
}

// ReindexConcurrentlySafely applies index option modifications with strict lock timeout fences.
func (s *BTreeDedupSentinel) ReindexConcurrentlySafely(ctx context.Context, schema, indexName string, dedup bool, fillfactor int) error {
	dedupStr := "off"
	if dedup {
		dedupStr = "on"
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// Set safe lock timeout for the metadata update
	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2s';"); err != nil {
		return err
	}

	alterSql := fmt.Sprintf(`ALTER INDEX "%s"."%s" SET (deduplicate_items = %s, fillfactor = %d);`, schema, indexName, dedupStr, fillfactor)
	if _, err := tx.Exec(ctx, alterSql); err != nil {
		return fmt.Errorf("failed to alter index options: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return err
	}

	// Reindex concurrently must be executed outside a transaction block
	reindexSql := fmt.Sprintf(`REINDEX INDEX CONCURRENTLY "%s"."%s";`, schema, indexName)
	s.logger.Info("executing online concurrent reindex", "index", indexName, "dedup", dedupStr, "fillfactor", fillfactor)
	start := time.Now()

	if _, err := s.pool.Exec(ctx, reindexSql); err != nil {
		return fmt.Errorf("concurrent reindex failed: %w", err)
	}

	s.logger.Info("concurrent reindex completed successfully", "index", indexName, "duration", time.Since(start))
	return nil
}
```

---

### 3. TypeScript (`drizzle-orm` / `pg`): Schema Definition & Amcheck Verification

```typescript
// src/db/schema/invoices.ts
import { pgTable, uuid, text, timestamp, index } from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';

export const invoices = pgTable(
  'invoices',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    tenantId: uuid('tenant_id').notNull(),
    status: text('status').notNull(), // 'DRAFT', 'PAID', 'OVERDUE' (Low cardinality)
    paymentRef: text('payment_ref').notNull(), // High-entropy crypto string
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (table) => [
    // Low-cardinality status index: Enable deduplication + fillfactor 90
    index('idx_invoices_status_dedup')
      .on(table.status)
      .with({ deduplicate_items: 'on', fillfactor: 90 }),

    // High-entropy unique token: Explicitly disable deduplication to save CPU cycles
    index('idx_invoices_payment_ref_nodedup')
      .on(table.paymentRef)
      .with({ deduplicate_items: 'off' }),
  ]
);

// src/db/health/btreeHealth.ts
import { sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

export async function verifyPostingIntegrity(db: NodePgDatabase, indexName: string): Promise<boolean> {
  try {
    await db.execute(sql`CREATE EXTENSION IF NOT EXISTS amcheck;`);
    await db.execute(sql`
      SELECT bt_index_parent_check(c.oid, true)
      FROM pg_class c
      WHERE c.relname = ${indexName};
    `);
    return true;
  } catch (error) {
    console.error(`B-Tree posting corruption detected in ${indexName}:`, error);
    return false;
  }
}
```

---

### 4. Python (`asyncpg`): Asynchronous Deduplication Sentinel

```python
# src/db/btree_dedup_sentinel.py
import asyncpg
import logging
from typing import List, Dict, Any

logger = logging.getLogger("btree_sentinel")

async def audit_btree_deduplication(pool: asyncpg.Pool, schema: str = "public") -> List[Dict[str, Any]]:
    """
    Inspects all non-unique B-tree indexes, evaluates entropy and cardinality,
    and returns optimization actions.
    """
    query = """
    SELECT
        c.relname AS index_name,
        t.relname AS table_name,
        COALESCE(
            (SELECT option_value = 'true' OR option_value = 'on'
             FROM pg_options_to_table(c.reloptions)
             WHERE option_name = 'deduplicate_items'),
            true
        ) AS dedup_enabled,
        COALESCE(
            (SELECT option_value::int
             FROM pg_options_to_table(c.reloptions)
             WHERE option_name = 'fillfactor'),
            100
        ) AS current_fillfactor,
        ROUND((pg_relation_size(c.oid)::numeric / 1024 / 1024), 2)::float AS index_size_mb,
        COALESCE(
            (SELECT ABS(s.n_distinct)::float / NULLIF(t.reltuples, 0)::float
             FROM pg_stats s
             WHERE s.schemaname = $1 AND s.tablename = t.relname AND s.attname = pg_get_indexdef(ix.indexrelid, 1, true)),
            1.0
        ) AS cardinality_ratio
    FROM pg_index ix
    JOIN pg_class c ON c.oid = ix.indexrelid
    JOIN pg_class t ON t.oid = ix.indrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    JOIN pg_am am ON am.oid = c.relam
    WHERE n.nspname = $1
      AND am.amname = 'btree'
      AND NOT ix.indisunique
      AND t.reltuples > 10000;
    """

    async with pool.acquire() as conn:
        records = await conn.fetch(query, schema)
        results = []
        for r in records:
            card_ratio = r["cardinality_ratio"]
            dedup = r["dedup_enabled"]
            fillfactor = r["current_fillfactor"]
            name = r["index_name"]

            action = "OK"
            if card_ratio > 0.10 and dedup:
                action = "SET (deduplicate_items = off)"
            elif card_ratio <= 0.05 and not dedup:
                action = "SET (deduplicate_items = on, fillfactor = 90)"
            elif dedup and fillfactor >= 100:
                action = "SET (fillfactor = 90)"

            results.append({
                "index_name": name,
                "table_name": r["table_name"],
                "dedup_enabled": dedup,
                "fillfactor": fillfactor,
                "size_mb": r["index_size_mb"],
                "cardinality_ratio": card_ratio,
                "recommended_action": action,
            })
        return results
```

---

### 5. Rust (`sqlx`): High-Performance B-Tree Deduplication Sentinel

```rust
// src/db/btree_dedup_sentinel.rs
use sqlx::{PgPool, Row};
use std::time::Duration;
use tracing::{error, info, warn};

#[derive(Debug)]
pub struct BTreeIndexHealth {
    pub index_name: String,
    pub table_name: String,
    pub dedup_enabled: bool,
    pub fillfactor: i32,
    pub index_size_mb: f64,
    pub cardinality_ratio: f64,
    pub action_needed: &'static str,
}

pub struct BTreeSentinel {
    pool: PgPool,
}

impl BTreeSentinel {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn check_index_posting_health(&self, schema: &str) -> Result<Vec<BTreeIndexHealth>, sqlx::Error> {
        let sql = r#"
            SELECT
                c.relname AS index_name,
                t.relname AS table_name,
                COALESCE(
                    (SELECT option_value = 'true' OR option_value = 'on'
                     FROM pg_options_to_table(c.reloptions)
                     WHERE option_name = 'deduplicate_items'),
                    true
                ) AS dedup_enabled,
                COALESCE(
                    (SELECT option_value::int
                     FROM pg_options_to_table(c.reloptions)
                     WHERE option_name = 'fillfactor'),
                    100
                ) AS current_fillfactor,
                ROUND((pg_relation_size(c.oid)::numeric / 1024 / 1024), 2)::float8 AS index_size_mb,
                COALESCE(
                    (SELECT ABS(s.n_distinct)::float8 / NULLIF(t.reltuples, 0)::float8
                     FROM pg_stats s
                     WHERE s.schemaname = $1 AND s.tablename = t.relname AND s.attname = pg_get_indexdef(ix.indexrelid, 1, true)),
                    1.0
                ) AS cardinality_ratio
            FROM pg_index ix
            JOIN pg_class c ON c.oid = ix.indexrelid
            JOIN pg_class t ON t.oid = ix.indrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_am am ON am.oid = c.relam
            WHERE n.nspname = $1
              AND am.amname = 'btree'
              AND NOT ix.indisunique
              AND t.reltuples > 10000;
        "#;

        let rows = sqlx::query(sql)
            .bind(schema)
            .fetch_all(&self.pool)
            .await?;

        let mut results = Vec::new();
        for r in rows {
            let index_name: String = r.get("index_name");
            let table_name: String = r.get("table_name");
            let dedup_enabled: bool = r.get("dedup_enabled");
            let fillfactor: i32 = r.get("current_fillfactor");
            let index_size_mb: f64 = r.get("index_size_mb");
            let cardinality_ratio: f64 = r.get("cardinality_ratio");

            let action_needed = if cardinality_ratio > 0.10 && dedup_enabled {
                "DISABLE_DEDUP"
            } else if cardinality_ratio <= 0.05 && !dedup_enabled {
                "ENABLE_DEDUP"
            } else if dedup_enabled && fillfactor >= 100 {
                "REDUCE_FILLFACTOR_90"
            } else {
                "NONE"
            };

            results.push(BTreeIndexHealth {
                index_name,
                table_name,
                dedup_enabled,
                fillfactor,
                index_size_mb,
                cardinality_ratio,
                action_needed,
            });
        }

        Ok(results)
    }

    pub async fn run_amcheck(&self, index_name: &str) -> Result<bool, sqlx::Error> {
        let sql = r#"
            SELECT bt_index_parent_check(c.oid, true)
            FROM pg_class c
            WHERE c.relname = $1;
        "#;

        match sqlx::query(sql).bind(index_name).execute(&self.pool).await {
            Ok(_) => {
                info!(index = index_name, "amcheck posting verification PASSED");
                Ok(true)
            }
            Err(e) => {
                error!(index = index_name, error = %e, "amcheck posting verification FAILED");
                Ok(false)
            }
        }
    }
}
```

---

## 6. Finite State Machine: 6-State Lifecycle for B-Tree Deduplication Optimization

```
+----------------------------------------------------------------------------------------------------+
|                      6-STATE FSM: B-TREE DEDUPLICATION GOVERNANCE LIFECYCLE                        |
+----------------------------------------------------------------------------------------------------+
|                                                                                                    |
|  [State 1: INDEX_DISCOVERY]                                                                        |
|         │                                                                                          |
|         ▼ (Query pg_index & pg_stats for n_distinct and cardinality ratio rho = K/N)               |
|  [State 2: ENTROPY_EVALUATION] ──(rho > 0.10 or Unique)──► [State 5: DEDUP_DISABLED]             |
|         │                                                                                          |
|         ▼ (rho <= 0.05 and Non-Unique)                                                             |
|  [State 3: DEDUP_VALIDATION]                                                                       |
|         │                                                                                          |
|         ├──(INCLUDE columns vary per row)───────────────► [State 5: DEDUP_DISABLED]             |
|         │                                                                                          |
|         ▼ (Key-only or immutable INCLUDE, fillfactor = 90)                                        |
|  [State 4: CONCURRENT_REINDEX] ──(lock_timeout = 2s, REINDEX CONCURRENTLY)                         |
|         │                                                                                          |
|         ▼ (Post-reindex verification)                                                              |
|  [State 6: AMCHECK_VERIFIED] ──(Cron monitoring & autovacuum scale factor = 0.05)                 |
|                                                                                                    |
+----------------------------------------------------------------------------------------------------+
```

---

## 7. 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Industrial Standard Invariant | Machine Failure Mode |
| :--- | :--- | :--- | :--- |
| **Gate 1: High-Entropy Dedup Ban** | UUID / Monotonic Keys | `deduplicate_items = off` on columns with $K/N > 0.10$ | CI scanner alerts if default dedup remains on UUID/timestamp columns |
| **Gate 2: Low-Cardinality Dedup** | Status / Tenant Columns | `deduplicate_items = on` on columns with $K/N \le 0.05$ | Storage audit flags uncompressed low-cardinality index $> 50\text{MB}$ |
| **Gate 3: Fillfactor Headroom** | Deduplicated Indexes | `fillfactor <= 90` to reserve leaf page headroom | Schema linter flags `fillfactor = 100` on deduplicated indexes |
| **Gate 4: INCLUDE Column Neutrality** | Covering Indexes | No volatile / high-entropy attributes in `INCLUDE` | Static analyzer rejects non-deterministic columns in `INCLUDE` clause |
| **Gate 5: Autovacuum Compaction** | Vacuum Tuning | `autovacuum_vacuum_scale_factor <= 0.05` on tables | Alerts when dead tuple ratio exceeds 5% on deduplicated tables |
| **Gate 6: amcheck Integrity CI** | B-Tree Consistency | `bt_index_parent_check(oid, true)` returns success | CI pipeline aborts if posting list corruption or sorting drift detected |

---

## Summary Checklist for Coding Agents

1. **Entropy-Aware Deduction**: Never leave default `deduplicate_items = on` on UUID, microsecond timestamp, or sequential ID columns; explicitly specify `WITH (deduplicate_items = off)` to save 10% write CPU.
2. **Posting Headroom**: Always specify `fillfactor = 90` on deduplicated indexes to prevent duplicate bursts from triggering leaf page splits.
3. **Audit INCLUDE Clauses**: Do not include volatile attributes in `INCLUDE` clauses on deduplicated indexes; verify that non-key attributes do not break deduplication.
4. **Aggressive Autovacuum**: Set `autovacuum_vacuum_scale_factor = 0.05` and `autovacuum_vacuum_cost_limit = 2000` to ensure dead TIDs in posting lists are cleared proactively.
5. **Always REINDEX CONCURRENTLY**: Never execute synchronous `REINDEX`; enforce `SET lock_timeout = '2s'` and `REINDEX INDEX CONCURRENTLY`.
6. **Automate amcheck**: Run `bt_index_parent_check()` in automated testing and CI migrations to catch OS collation drift before corruption hits production users.
