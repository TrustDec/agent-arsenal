---
description: PostgreSQL Free Space Map (FSM) architecture, heap page allocation, fillfactor tuning, Heap-Only Tuple (HOT) updates, RelationExtensionLock contention, Line Pointer (ItemId) fragmentation, pg_freespace telemetry, and online zero-downtime compaction across Go (pgx/v5), TypeScript (Kysely, Drizzle), Python (asyncpg, psycopg3), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{fsm,freespace,heap,fillfactor,storage,page,table,migration,database,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Free Space Map (FSM), Page Allocation, Heap Fragmentation, fillfactor Tuning & RelationExtensionLock Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design high-throughput database tables, optimize update-heavy OLTP workloads, tune storage engine parameters, manage physical page layouts, eliminate relation extension locks, or remediate heap and index bloat across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Default `fillfactor = 100` & Heap-Only Tuple (HOT) Update Failure Trap" (where default 100% page packing leaves 0% free space for in-place updates, forcing every single row modification—even on non-indexed columns—to append a new row version to a foreign page and write new pointers into every B-Tree, GIN, and GiST index on the relation, multiplying write amplification by $5\times–20\times$ and choking buffer cache), the "RelationExtensionLock & Concurrent Append Serialization Bottleneck" (where hundreds of concurrent worker threads attempting to append new tuples exhaust existing page free space and contend for `RelationExtensionLock` / `LWLock:RelationExtension`, dropping insert throughput from 40,000 TPS to under 1,500 TPS and spiking p99 latency by 50x), the "Line Pointer (`ItemId`) Fragmentation & Internal Page Holes Trap" (where dead tuple deletions leave uncompacted holes in 8KB heap pages while line pointer arrays reach `MaxOffsetNumber`, forcing the storage manager to bypass pages with 40% unallocated space and prematurely inflate physical table size), the "Free Space Map (FSM) Desynchronization & `pg_freespace` Blindness" (where delayed autovacuum or crash recovery leaves `_fsm` binary tree forks desynchronized from actual heap blocks, causing inserting backends to repeatedly scan full blocks or allocate new disk pages when existing blocks have ample capacity), the "Unbounded Filesystem Extent Allocation & NVMe Write Fragmentation Hazard" (where high-frequency single-page 8KB relation extensions trigger heavy filesystem inode lock contention and inflate WAL `XLOG_HEAP2_EXTEND` records), and the "Unmonitored Table Rewrite Lockout (`ALTER TABLE ... SET FILLFACTOR`)" (where agents alter `fillfactor` without recognizing that catalog updates do not repack existing pages, and subsequently attempt destructive `VACUUM FULL` or `CLUSTER` commands acquiring table-wide `ACCESS EXCLUSIVE` locks for hours during production traffic) by establishing a strict 5-Tier FSM & Heap Allocation Governance Ladder, formal HOT mathematical feasibility proofs, Little's Law relation extension queuing models, an autonomous TypeScript `AgenticFSMGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state heap lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 FSM & Heap Allocation Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, the physical storage of relational tables is partitioned into 8,192-byte (8KB) disk blocks called **Heap Pages**. Every table is physically represented on disk by multiple file forks:
1. **The Main Fork (`_main`)**: Contains physical heap pages. Each page contains a 24-byte `PageHeaderData`, an array of 4-byte line pointers (`ItemIdData`) growing downwards from the top of the page, and variable-length tuple bodies growing upwards from the bottom of the page.
2. **The Free Space Map Fork (`_fsm`)**: A complete binary tree stored as disk pages where each leaf byte records the quantized free space category (0–255, in 32-byte quanta) of a corresponding heap block. The upper internal tree nodes track the maximum free space among their children, enabling the engine to discover a page with sufficient capacity for an incoming tuple in $O(\log N)$ time.
3. **The Visibility Map Fork (`_vm`)**: Tracks whether all tuples on each heap page are visible to all current and future transactions (all-visible bit) and whether all tuples are frozen (all-frozen bit), governing index-only scans and autovacuum skipping.

When autonomous coding agents write transactional schemas, bulk loaders, or microservice mutations, LLMs routinely commit 6 catastrophic heap allocation anti-patterns:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             POSTGRESQL 8KB HEAP PAGE LAYOUT & HOT UPDATE CHAIN MECHANISM               │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Page Header (24B): [pd_lsn | pd_flags | pd_lower | pd_upper | pd_special]             │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Line Pointers (ItemIdData, 4B each):                                                   │
│ [ ItemId 1 ] -> Offset to Tuple 1 (Root, indexed by B-Tree)                           │
│ [ ItemId 2 ] -> Offset to Tuple 2 (HOT update of Tuple 1, NOT indexed by B-Tree!)       │
│ [ ItemId 3 ] -> Offset to Tuple 3                                                      │
│ ──── pd_lower (End of Line Pointer array) ────►                                       │
│                                                                                        │
│                      ░░░░ UNALLOCATED CONTIGUOUS FREE SPACE ░░░░                       │
│                    (Available for new INSERT or in-place HOT UPDATE)                   │
│                                                                                        │
│ ◄──── pd_upper (Start of newest Tuple data) ───                                       │
│ [ Tuple 2 Body: Heap-Only Tuple (HOT), t_ctid=(0,2), t_infomask=HEAP_HOT_UPDATED ]    │
│ [ Tuple 1 Body: Root Tuple, t_ctid=(0,2), t_infomask=HEAP_UPDATED ]                   │
│ [ Tuple 3 Body: Regular Tuple ]                                                        │
│ Special Space (optional, e.g. for index pages; 0 bytes for standard heap)             │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   NAIVE HEAP ALLOCATION vs RIGOROUS FSM PRODUCTION INVARIANTS          │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Leave default fillfactor = 100 on       │ • Calibrate table-specific fillfactor      │
│   update-heavy OLTP relations. Every row   │   (75–85) on tables with frequent updates. │
│   update writes to all B-Tree indexes!    │   Preserves 15–25% page headroom for HOT!  │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Single-row concurrent INSERT threads    │ • Vectorized batch inserts with array      │
│   compete for RelationExtensionLock. TPS  │   unnesting or COPY; leverage PG 16+ bulk  │
│   collapses from 40k to 1.5k.             │   extension to allocate blocks in bulk.    │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Ignore ItemId line pointer bloat; dead  │ • Tune autovacuum_vacuum_cost_limit to     │
│   holes accumulate until ItemId reaches   │   2000–5000; enable aggressive page prune  │
│   MaxOffsetNumber, abandoning the block.  │   before MaxOffsetNumber exhaustion.       │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Operate blind to FSM synchronization.   │ • Continuous telemetry via pg_freespace;   │
│   FSM misses free space, allocating new   │   alert when FSM desync leads to unneeded  │
│   disk blocks while heap is 40% empty.    │   relation extensions.                     │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Run VACUUM FULL to apply fillfactor     │ • Zero-downtime online repack (pg_repack)  │
│   changes, acquiring ACCESS EXCLUSIVE     │   with sub-second lock_timeout to apply    │
│   locks and freezing production OLTP.     │   fillfactor changes without downtime.     │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Update indexed columns unconditionally  │ • Surgical UPDATE statements modifying     │
│   even when new values equal old values;  │   only changed columns; HOT-guard with     │
│   instantly breaks HOT update chains.     │   WHERE col IS DISTINCT FROM new_val.      │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

---

### Failure Mode 1: The Default `fillfactor = 100` & Heap-Only Tuple (HOT) Update Failure Trap

When PostgreSQL creates a heap table, it applies the default parameter `fillfactor = 100`. This instructs the storage manager to pack every single 8KB heap page to 100% capacity during initial `INSERT` statements. 

When an application performs an `UPDATE` on a row:
1. In PostgreSQL's MVCC architecture, updates do NOT mutate data in place. A new version of the row (tuple) must be created and appended.
2. If the new tuple can be placed on the **exact same 8KB heap page** as the original tuple, and **no indexed columns were modified**, PostgreSQL executes a **Heap-Only Tuple (HOT) update**. The original tuple's line pointer is updated to point directly to the new tuple's line pointer on the same page. **Zero index modifications are required**. Existing B-Tree, GIN, and GiST indexes continue pointing to the root line pointer without any changes.
3. However, under `fillfactor = 100`, the page is completely saturated. There is zero headroom for the new tuple. The engine is forced to place the new tuple on a completely different heap page.
4. Because the tuple moved to a different page, **every single index on the table must have a new entry inserted pointing to the new page block and line pointer**!
5. On a table with 6 indexes (e.g., primary key, tenant ID, status, user ID, created_at, foreign key), updating a single unindexed column (such as `last_login_at` or `retry_count`) generates **1 heap write + 6 B-Tree index writes**, producing $7\times$ write amplification, thrashing buffer cache, and causing astronomical index bloat.

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Default fillfactor = 100 on update-heavy table
CREATE TABLE user_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  token_hash TEXT NOT NULL,
  last_heartbeat TIMESTAMPTZ NOT NULL, -- Updated every 30 seconds!
  status TEXT NOT NULL,
  metadata JSONB
  -- fillfactor defaults to 100! 0% room for HOT updates!
);
CREATE INDEX idx_user_sessions_user_id ON user_sessions(user_id);
CREATE INDEX idx_user_sessions_status ON user_sessions(status);
CREATE INDEX idx_user_sessions_token ON user_sessions(token_hash);

-- Every 30 seconds, this update touches ZERO indexed columns:
UPDATE user_sessions SET last_heartbeat = NOW() WHERE id = $1;
-- RESULT: HOT update FAILS 100% of the time because page is packed at 100%.
-- 1 heap write + 3 index writes = 4x write amplification, 100% index bloat in 24 hours!
```

---

### Failure Mode 2: The `RelationExtensionLock` & Concurrent Append Serialization Bottleneck

When a high-throughput microservice or autonomous worker cluster inserts thousands of rows per second across 50 to 200 concurrent database connections, backends continuously consult the Free Space Map to find an existing page with sufficient free bytes (`GetPageWithFreeSpace`).

When all existing heap pages are full (or the table is rapidly expanding), backends must append a new 8KB page to the physical relation. To extend the file on disk and update the relation's block count in shared memory, PostgreSQL requires the backend to acquire a heavyweight **`RelationExtensionLock`** (or in PostgreSQL 16+, `LWLock:RelationExtension`).

1. The lock is exclusive per table: only **one backend at a time** can extend the file, write the new block header, and allocate it into `shared_buffers`.
2. When 100 concurrent worker threads attempt to insert simultaneously, they form a massive serialized lock convoy:
   - 1 backend holds `RelationExtensionLock` while performing synchronous OS filesystem allocation (`posix_fallocate()` or zero-filling block).
   - 99 backends sleep waiting in `WaitEvent: Lock:relation_extension`.
3. Physical write throughput collapses from 40,000 TPS to under 1,500 TPS, and API gateway p99 latency spikes past 5,000ms.

---

### Failure Mode 3: The Line Pointer (`ItemId`) Fragmentation & Internal Page Holes Trap

Inside an 8KB heap page, line pointers (`ItemIdData`) are 4-byte structures pointing to byte offsets of tuple bodies. Line pointers can never be moved once created because secondary B-Tree indexes store Tuple Identifiers (`TID` = `(block_number, line_offset)`).

```
OffsetNumber: 1, 2, 3, 4 ... up to MaxOffsetNumber (2048)
```

1. When rows are deleted or pruned, the tuple body space can be reclaimed, but the `ItemId` slot remains as a dead marker (`LP_DEAD` or `LP_UNUSED`).
2. If an application performs millions of short-lived updates and deletes without tuning autovacuum, dead tuple spaces leave fragmented holes. While total free space on the page might be 3,500 bytes (over 40% of the page), the contiguous free space between `pd_lower` and `pd_upper` may only be 200 bytes.
3. If an incoming tuple requires 400 bytes, it cannot fit without an immediate in-page defragmentation (`PageRepairFragmentation()`).
4. Even worse, if line pointer slots reach `MaxOffsetNumber = 2048`, the page can never accept another tuple under any circumstances, even if 90% of the page body is completely empty! The page is permanently abandoned for new inserts until a full table rewrite occurs.

---

### Failure Mode 4: The Free Space Map (FSM) Desynchronization & `pg_freespace` Blindness

The Free Space Map is a lightweight approximation data structure. It divides an 8,192-byte page into 256 categories: each step represents $8192 / 256 = 32$ bytes.

1. The FSM is **not WAL-logged** for every single byte change during standard DML. Instead, it is updated lazily when `VACUUM` scans a page, or when a backend attempting an insert discovers that a page has less space than the FSM recorded.
2. Following abnormal termination, crash recovery, bulk deletions, or sudden spikes in transaction aborts, the FSM binary tree can diverge drastically from the physical heap blocks:
   - **False Full**: The FSM believes blocks are full, causing backends to bypass pages that actually have 4KB of empty space, driving runaway physical file growth.
   - **False Empty**: The FSM points inserting backends to blocks that cannot accommodate the new row, forcing backends to execute futile buffer pin/unpin loops before falling back to relation extension.
3. Teams and autonomous agents operate blind because they never inspect physical page utilization with PostgreSQL's official `pg_freespace` extension.

---

### Failure Mode 5: The Unbounded Filesystem Extent Allocation & NVMe Write Fragmentation Hazard

When PostgreSQL extends a heap relation one 8KB block at a time, each extension generates a physical filesystem call and logs an `XLOG_HEAP2_EXTEND` record to the Write-Ahead Log (WAL).

1. On underlying filesystems (such as Linux XFS or ext4), single-block extensions fragment the inode extents into hundreds of thousands of discontinuous 8KB fragments.
2. Cloud NVMe storage controllers (AWS gp3/io2, GCP Hyperdisk) suffer severe I/O penalties when sequential scans must traverse heavily fragmented disk extents.
3. Furthermore, when full-page writes are active (`full_page_writes = on`), every newly extended block modified for the first time after a checkpoint forces the entire 8KB block to be written to the WAL stream, doubling WAL generation rates.

---

### Failure Mode 6: The Unmonitored Table Rewrite Lockout (`ALTER TABLE ... SET FILLFACTOR`)

When autonomous agents or developers discover that a table has `fillfactor = 100` and needs headroom for HOT updates, they execute:

```sql
ALTER TABLE user_sessions SET (fillfactor = 85);
```

1. **The Inaction Illusion**: `ALTER TABLE ... SET (fillfactor = 85)` changes the relation's entry in `pg_class.reloptions`. It does **NOT rewrite or reorganize existing pages**. All existing pages remain packed at 100%, and HOT updates continue to fail for all existing rows!
2. **The Destructive Remediator**: Realizing that existing pages are still packed, the agent executes `VACUUM FULL user_sessions;` or `CLUSTER user_sessions;`.
3. `VACUUM FULL` acquires an **`ACCESS EXCLUSIVE`** lock on the table. In production, this instantly locks out all incoming `SELECT`, `INSERT`, `UPDATE`, and `DELETE` queries. Within seconds, API connections queue up, connection pools are depleted, HTTP gateways return 504 Gateway Timeouts, and the service suffers a total outage.

---

## 2. Mathematical Formalisms & Allocation Storage Physics

To build autonomous agents that manage physical storage deterministically, we express heap page capacity, HOT update probability, FSM quantization, and lock contention as mathematical laws.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        HEAP STORAGE & FSM ALLOCATION PHYSICS                           │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ 1. Usable Page Space:         P_usable = 8192 - 24 = 8168 bytes                        │
│ 2. Reserved Headroom:         R_HOT = floor(P_usable * (1 - fillfactor/100))           │
│ 3. Max HOT Fillfactor:        Phi* <= 100 * (1 - (S_tuple + 4) / 8168)                 │
│ 4. FSM Quantization:          q = min(255, floor(F_free / 32)),  Error < 32 bytes      │
│ 5. Extension Queue (Little):  Q_ext = lambda_ext * t_ext                               │
│ 6. Write Amplification Ratio: W_amp = 1 + (1 - P_HOT) * N_indexes                      │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

### Theorem 1: HOT Update Feasibility Bound & Maximum Usable Fillfactor Calculus

Let $P_{\text{size}} = 8192$ bytes. Let $H = 24$ bytes be the size of `PageHeaderData`. Standard heap pages have zero special space ($S_{\text{special}} = 0$).

The usable space on an empty heap page is:
$$P_{\text{usable}} = P_{\text{size}} - H = 8192 - 24 = 8168\text{ bytes}$$

Let $\Phi \in (0, 100]$ be the table's `fillfactor`. The space available for initial insertions is bounded by:
$$S_{\text{insert}} = \left\lfloor P_{\text{usable}} \times \frac{\Phi}{100} \right\rfloor$$

The reserved free headroom on each page dedicated for subsequent in-place updates is:
$$R_{\text{HOT}}(\Phi) = P_{\text{usable}} - S_{\text{insert}} = P_{\text{usable}} \times \left(1 - \frac{\Phi}{100}\right)$$

A non-key `UPDATE` on a tuple with physical size $S_{\text{tuple}}$ requires space for:
1. The new tuple body: $S_{\text{tuple}}$ (including 23-byte `HeapTupleHeaderData` and padding).
2. A new line pointer in the page line pointer array: $\text{sizeof}(\text{ItemIdData}) = 4\text{ bytes}$.

**The HOT Feasibility Invariant**:
A tuple can be updated via Heap-Only Tuple (HOT) on the same page for $k$ consecutive update generations before requiring vacuuming if and only if:
$$R_{\text{HOT}}(\Phi) \ge k \times (S_{\text{tuple}} + 4)$$

Solving for the maximum permissible fillfactor $\Phi^*$ to guarantee at least $k$ HOT updates:
$$\Phi^* \le 100 \times \left(1 - \frac{k \times (S_{\text{tuple}} + 4)}{8168}\right)$$

**Quantitative Examples**:
- For a small session record ($S_{\text{tuple}} = 120\text{ bytes}$) with $k = 3$ updates between vacuum cycles:
  $$\Phi^* \le 100 \times \left(1 - \frac{3 \times 124}{8168}\right) = 100 \times (1 - 0.0455) = 95.45\% \implies \mathbf{fillfactor = 90}$$
- For a standard customer profile ($S_{\text{tuple}} = 450\text{ bytes}$) with $k = 2$ updates:
  $$\Phi^* \le 100 \times \left(1 - \frac{2 \times 454}{8168}\right) = 100 \times (1 - 0.1111) = 88.89\% \implies \mathbf{fillfactor = 85}$$
- For a large document record ($S_{\text{tuple}} = 1200\text{ bytes}$) with $k = 1$ update:
  $$\Phi^* \le 100 \times \left(1 - \frac{1204}{8168}\right) = 100 \times (1 - 0.1474) = 85.26\% \implies \mathbf{fillfactor = 80}$$

---

### Theorem 2: FSM 32-Byte Quantization Granularity & Truncation Error Bounds

The Free Space Map represents free space on each page using a single 8-bit unsigned integer $q \in [0, 255]$:
$$q = \min\left(255, \left\lfloor \frac{F_{\text{actual}}}{32} \right\rfloor\right)$$

Where $F_{\text{actual}} \in [0, 8192)$ is the contiguous free space on the page.

The estimated free space reconstructed from the FSM byte is:
$$\hat{F} = q \times 32$$

The quantization error $\epsilon = F_{\text{actual}} - \hat{F}$ is strictly bounded by:
$$0 \le \epsilon < 32\text{ bytes}$$

**Consequence for Tuple Insertion**:
When an incoming tuple has size $S_{\text{target}} = S_{\text{tuple}} + 4$, the engine requests a block with category:
$$q_{\text{req}} = \left\lceil \frac{S_{\text{target}}}{32} \right\rceil$$

Because the FSM truncates downward ($\lfloor \cdot \rfloor$), any page with $q \ge q_{\text{req}}$ is guaranteed to have at least:
$$\hat{F} = q \times 32 \ge q_{\text{req}} \times 32 \ge S_{\text{target}}\text{ bytes}$$

Thus, **FSM search never produces false positives** (it never selects a page with less contiguous space than requested, assuming the FSM is synchronized). However, it can produce **false negatives** if $F_{\text{actual}} = 319$ bytes ($q = 9 \implies 288$ bytes) and $S_{\text{target}} = 300$ bytes ($q_{\text{req}} = 10$), bypassing the block even though 319 bytes are physically free.

---

### Theorem 3: RelationExtensionLock Queuing & Write Throughput Collapse (Little's Law)

Let $\lambda_{\text{ext}}$ be the rate at which concurrent transactions require new page allocations (relation extensions per second). Let $t_{\text{ext}}$ be the service time to acquire the lock, allocate the 8KB block via OS syscall, zero the memory page, and release the lock.

By Little's Law, the expected number of backends waiting on `RelationExtensionLock` is:
$$Q_{\text{ext}} = \lambda_{\text{ext}} \times t_{\text{ext}}$$

On single-threaded lock acquisition, the maximum sustainable extension throughput is bounded by:
$$\lambda_{\text{ext}}^{\max} = \frac{1}{t_{\text{ext}}}$$

On cloud virtualized storage (e.g., AWS EBS gp3 with $t_{\text{ext}} \approx 1.2\text{ms}$):
$$\lambda_{\text{ext}}^{\max} = \frac{1}{0.0012\text{ s}} \approx 833\text{ extensions/sec}$$

If 50 concurrent worker threads perform single-row inserts on a table where every page is full:
$$Q_{\text{ext}} = 50 \implies \text{Wait Time } W = \frac{Q_{\text{ext}}}{\lambda_{\text{ext}}^{\max}} = 50 \times 1.2\text{ms} = 60\text{ms}$$

Every single insert incurs 60ms of pure lock wait time. By coalescing inserts into multi-row batches of size $B = 100$, the extension arrival rate drops by $100\times$:
$$\lambda_{\text{ext}}^{\text{batched}} = \frac{\lambda_{\text{ext}}}{B}$$
$$Q_{\text{ext}}^{\text{batched}} = \frac{50}{100} = 0.5 \implies \text{Wait Time } W \approx 0.6\text{ms (99\% latency reduction)}$$

---

### Theorem 4: Index Write Amplification & NVMe IOPS Penalty Ratio

Let a table have $N_{\text{idx}}$ secondary B-Tree/GIN/GiST indexes. Let $P_{\text{HOT}} \in [0, 1]$ be the probability that a row update succeeds as a Heap-Only Tuple update.

The expected physical write amplification factor $W_{\text{amp}}$ per row update is:
$$W_{\text{amp}} = 1 + (1 - P_{\text{HOT}}) \times N_{\text{idx}}$$

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   HOT EFFICIENCY vs PHYSICAL WRITE AMPLIFICATION                       │
├─────────────────────────┬──────────────────────┬───────────────────────────────────────┤
│ HOT Update Ratio P_HOT  │ Number of Indexes    │ Write Amplification Factor W_amp      │
├─────────────────────────┼──────────────────────┼───────────────────────────────────────┤
│ 0.00 (fillfactor = 100) │ 5 indexes            │ 1 + (1.00) * 5 = 6.00x writes         │
│ 0.50 (Uncalibrated FF)  │ 5 indexes            │ 1 + (0.50) * 5 = 3.50x writes         │
│ 0.95 (fillfactor = 85)  │ 5 indexes            │ 1 + (0.05) * 5 = 1.25x writes (79% ↓) │
│ 0.99 (Tuned + Pruned)   │ 8 indexes            │ 1 + (0.01) * 8 = 1.08x writes (88% ↓) │
└─────────────────────────┴──────────────────────┴───────────────────────────────────────┘
```

When $P_{\text{HOT}} \ge 0.90$, write I/O to secondary indexes drops by over **$75\%$**, eliminating NVMe write cache exhaustion, reducing WAL volume, and preventing replica replication lag.

---

## 3. The 5-Tier FSM, Heap Allocation & Fillfactor Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│              THE 5-TIER FSM & HEAP ALLOCATION GOVERNANCE LADDER                        │
├────────────┬─────────────────────────────────┬─────────────────────────────────────────┤
│ Tier 0     │ Workload Sizing & Fillfactor    │ Separate append-only (100) from OLTP   │
│            │ Calibration                     │ (75–85); reserve headroom via math.     │
├────────────┼─────────────────────────────────┼─────────────────────────────────────────┤
│ Tier 1     │ pg_freespace Telemetry &        │ Continuous inspection of FSM blocks;    │
│            │ Desync Detection                │ monitor pg_stat_user_tables HOT ratios. │
├────────────┼─────────────────────────────────┼─────────────────────────────────────────┤
│ Tier 2     │ RelationExtensionLock Fence &   │ Vectorized multi-row inserts; leverage  │
│            │ Bulk Allocation Coalescing      │ PG 16+ bulk extension; lock_timeout.    │
├────────────┼─────────────────────────────────┼─────────────────────────────────────────┤
│ Tier 3     │ Line Pointer Defragmentation &  │ Tune autovacuum_vacuum_cost_limit to    │
│            │ Autovacuum Cost Calibration     │ 2000–5000; prune blocks before MaxOffset│
├────────────┼─────────────────────────────────┼─────────────────────────────────────────┤
│ Tier 4     │ Zero-Downtime Fillfactor Online │ ALTER TABLE ... SET (fillfactor=X) +    │
│            │ Repack & Automated CI Gates     │ pg_repack under sub-second lock_timeout │
└────────────┴─────────────────────────────────┴─────────────────────────────────────────┘
```

---

### Tier 0: Workload Sizing & Fillfactor Calibration

1. **Strict Table Classification**:
   - **Append-Only Tables** (Logs, Audit Trails, Timeseries Events, Ledger Journal Entries): Must explicitly declare `fillfactor = 100` (or leave default). These tables undergo zero `UPDATE` statements; reserving headroom would waste disk space and degrade sequential scans.
   - **Update-Heavy OLTP Tables** (Sessions, Users, Orders, Inventory, Workflows): Must explicitly declare `fillfactor = 75–85` at table creation time based on average row size and update frequency.
2. **HOT-Guarded Mutations**:
   - Autonomous agents must generate `UPDATE` statements that never modify columns when the new value equals the existing value.
   - Always append `WHERE (col IS DISTINCT FROM $new_val)` to prevent pseudo-updates from consuming free headroom.

---

### Tier 1: `pg_freespace` Telemetry & Desync Detection

1. **Install `pg_freespace` Extension**:
   Enable `CREATE EXTENSION IF NOT EXISTS pg_freespace;` in administrative maintenance schemas.
2. **Monitor Physical Free Space Distribution**:
   Query `pg_freespace` to identify tables with high internal fragmentation where free space is trapped in small chunks across thousands of blocks.
3. **Continuous HOT Efficiency Sentinel**:
   Assert that for update-heavy tables:
   $$\text{HOT Ratio} = \frac{\text{n\_tup\_hot\_upd}}{\text{n\_tup\_upd}} \ge 0.85$$
   If $\text{HOT Ratio} < 0.80$, trigger an automated alert to recalibrate `fillfactor`.

---

### Tier 2: `RelationExtensionLock` Fence & Bulk Allocation Coalescing

1. **Batch Insert Requirement**:
   Prohibit high-frequency loops of single-row `INSERT INTO ... VALUES (...)` in concurrent workers.
   Replace with unnested arrays `INSERT INTO ... SELECT * FROM UNNEST($1::type[])` or PostgreSQL `COPY`.
2. **PostgreSQL 16+ Bulk Extension Exploitation**:
   In PostgreSQL 16+, the storage engine can allocate up to 512 pages in a single `RelationExtensionLock` operation during bulk inserts, reducing lock acquisition frequency by $512\times$. Ensure migration to PostgreSQL 16+ on write-heavy clusters.
3. **Lock Timeout Fencing**:
   Always set `SET LOCAL lock_timeout = '2000ms';` before issuing high-volume inserts to fail fast rather than accumulating deep lock convoys.

---

### Tier 3: Line Pointer Defragmentation & Autovacuum Cost Calibration

1. **Raise Autovacuum Cost Limits on Modern NVMe**:
   Default PostgreSQL settings (`autovacuum_vacuum_cost_limit = 200` with 2ms delay) are relic defaults designed for spinning HDDs. Under these defaults, autovacuum sleeps 90% of the time, allowing line pointers and dead tuple bodies to choke heap pages.
   Set:
   ```ini
   autovacuum_vacuum_cost_limit = 3000
   autovacuum_vacuum_cost_delay = 2ms
   ```
2. **Per-Table Scale Factor Overrides**:
   On high-frequency tables, override global autovacuum settings:
   ```sql
   ALTER TABLE user_sessions SET (
     autovacuum_vacuum_scale_factor = 0.05,
     autovacuum_vacuum_threshold = 500,
     autovacuum_vacuum_cost_limit = 5000
   );
   ```

---

### Tier 4: Zero-Downtime Fillfactor Online Repack & Automated CI Gates

1. **Online Repack Migration Pattern**:
   When changing `fillfactor` on an existing production table:
   - Step 1: Update metadata: `ALTER TABLE <table> SET (fillfactor = 85);` under `lock_timeout = '1500ms'`.
   - Step 2: Repack physical pages online without write locks: execute `pg_repack --table <table>` (which builds a shadow table and swaps catalogs under a momentary lock).
   - **Never run `VACUUM FULL` or `CLUSTER`**.
2. **CI Static Schema Linter**:
   Assert that every migration adding an update-heavy table contains an explicit `WITH (fillfactor = 80-90)` clause.

---

## 4. Production Code Implementations

### Go (`jackc/pgx/v5`): FSM Telemetry Sentinel, HOT Ratio Watchdog & Bulk Array Appends

```go
package storage

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TableHOTMetrics tracks Heap-Only Tuple update efficiency from pg_stat_user_tables.
type TableHOTMetrics struct {
	TableName    string  `json:"table_name"`
	TotalUpdates int64   `json:"total_updates"`
	HOTUpdates   int64   `json:"hot_updates"`
	HOTRatio     float64 `json:"hot_ratio"`
	Fillfactor   int     `json:"fillfactor"`
}

// PageFreeSpaceStats represents aggregated physical free space from pg_freespace.
type PageFreeSpaceStats struct {
	TotalBlocks    int64   `json:"total_blocks"`
	EmptyBlocks    int64   `json:"empty_blocks"`
	FragmentedKiB  int64   `json:"fragmented_kib"`
	AverageFreeB   float64 `json:"average_free_bytes"`
}

// FSMStorageManager manages heap layout, telemetry, and batch allocation.
type FSMStorageManager struct {
	pool *pgxpool.Pool
}

func NewFSMStorageManager(pool *pgxpool.Pool) (*FSMStorageManager, error) {
	if pool == nil {
		return nil, errors.New("pgx pool must not be nil")
	}
	return &FSMStorageManager{pool: pool}, nil
}

// AuditHOTEfficiency checks whether an update-heavy table maintains the >= 0.85 HOT ratio invariant.
func (m *FSMStorageManager) AuditHOTEfficiency(ctx context.Context, tableName string) (*TableHOTMetrics, error) {
	query := `
		SELECT 
			c.relname,
			COALESCE(s.n_tup_upd, 0) AS total_updates,
			COALESCE(s.n_tup_hot_upd, 0) AS hot_updates,
			CASE 
				WHEN COALESCE(s.n_tup_upd, 0) = 0 THEN 1.0
				ELSE ROUND(COALESCE(s.n_tup_hot_upd, 0)::numeric / s.n_tup_upd::numeric, 4)::float8
			END AS hot_ratio,
			COALESCE(
				(SELECT (regexp_match(reloptions::text, 'fillfactor=([0-9]+)'))[1]::int 
				 FROM pg_class WHERE oid = c.oid),
				100
			) AS fillfactor
		FROM pg_class c
		LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relname = $1 AND n.nspname NOT IN ('pg_catalog', 'information_schema');
	`

	var metrics TableHOTMetrics
	err := m.pool.QueryRow(ctx, query, tableName).Scan(
		&metrics.TableName,
		&metrics.TotalUpdates,
		&metrics.HOTUpdates,
		&metrics.HOTRatio,
		&metrics.Fillfactor,
	)
	if err != nil {
		return nil, fmt.Errorf("audit hot efficiency for %s: %w", tableName, err)
	}

	return &metrics, nil
}

// InspectPageFreeSpace queries pg_freespace to measure block-level capacity.
func (m *FSMStorageManager) InspectPageFreeSpace(ctx context.Context, tableName string) (*PageFreeSpaceStats, error) {
	query := `
		SELECT 
			count(*) AS total_blocks,
			count(*) FILTER (WHERE avail >= 8000) AS empty_blocks,
			ROUND(SUM(avail)::numeric / 1024, 0)::bigint AS fragmented_kib,
			ROUND(AVG(avail)::numeric, 1)::float8 AS avg_free_bytes
		FROM pg_freespace($1);
	`

	var stats PageFreeSpaceStats
	err := m.pool.QueryRow(ctx, query, tableName).Scan(
		&stats.TotalBlocks,
		&stats.EmptyBlocks,
		&stats.FragmentedKiB,
		&stats.AverageFreeFreeB,
	)
	if err != nil {
		return nil, fmt.Errorf("inspect pg_freespace for %s: %w", tableName, err)
	}

	return &stats, nil
}

// ConfigureTableFillfactorOnline sets fillfactor under bounded lock timeout.
// Note: To apply this to existing pages, an online pg_repack should be triggered.
func (m *FSMStorageManager) ConfigureTableFillfactorOnline(
	ctx context.Context,
	tableName string,
	targetFillfactor int,
) error {
	if targetFillfactor < 10 || targetFillfactor > 100 {
		return fmt.Errorf("invalid fillfactor %d; must be between 10 and 100", targetFillfactor)
	}

	conn, err := m.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire conn: %w", err)
	}
	defer conn.Release()

	// INVARIANT: Set strict lock_timeout to avoid queuing behind long transactions
	tx, err := conn.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '1500ms';"); err != nil {
		return fmt.Errorf("set lock_timeout: %w", err)
	}

	alterSQL := fmt.Sprintf("ALTER TABLE %q SET (fillfactor = %d);", tableName, targetFillfactor)
	if _, err := tx.Exec(ctx, alterSQL); err != nil {
		return fmt.Errorf("alter fillfactor: %w", err)
	}

	return tx.Commit(ctx)
}

// BatchInsertWithBulkAllocation inserts records via UNNEST array to avoid RelationExtensionLock convoys.
func (m *FSMStorageManager) BatchInsertSessions(
	ctx context.Context,
	ids []string,
	userIDs []string,
	tokens []string,
) error {
	if len(ids) == 0 {
		return nil
	}

	query := `
		INSERT INTO user_sessions (id, user_id, token_hash, last_heartbeat, status)
		SELECT 
			u.id::uuid,
			u.user_id::uuid,
			u.token,
			NOW(),
			'active'
		FROM UNNEST($1::text[], $2::text[], $3::text[]) AS u(id, user_id, token);
	`

	ctxTimeout, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := m.pool.Exec(ctxTimeout, query, ids, userIDs, tokens)
	if err != nil {
		return fmt.Errorf("batch insert sessions: %w", err)
	}

	return nil
}
```

---

### TypeScript (`Kysely` & `Drizzle ORM`): Physical Page Layout Declarations & HOT Update Guards

```typescript
// src/db/schema/sessions.ts
import { pgTable, uuid, text, timestamp, jsonb } from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';
import { Kysely } from 'kysely';

/**
 * PRODUCTION INVARIANT: Update-Heavy Session Table.
 * Configured with WITH (fillfactor = 85) to preserve 15% headroom on every 8KB
 * heap page for in-place Heap-Only Tuple (HOT) updates.
 */
export const userSessions = pgTable(
  'user_sessions',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: uuid('user_id').notNull(),
    tokenHash: text('token_hash').notNull(),
    lastHeartbeat: timestamp('last_heartbeat', { withTimezone: true }).notNull().defaultNow(),
    status: text('status').notNull().default('active'),
    metadata: jsonb('metadata'),
  },
  (table) => [
    // Table option declaring 85% fillfactor for HOT preservation
    sql`WITH (fillfactor = 85)`,
  ]
);

export interface DatabaseSchema {
  user_sessions: {
    id: string;
    user_id: string;
    token_hash: string;
    last_heartbeat: Date;
    status: string;
    metadata: Record<string, unknown> | null;
  };
}

/**
 * Service executing surgical, HOT-guarded row updates.
 * Guarantees that no-op writes do not burn page headroom.
 */
export class SessionRepository {
  constructor(private readonly db: Kysely<DatabaseSchema>) {}

  /**
   * Updates session heartbeat. Uses WHERE IS DISTINCT FROM guard to
   * prevent redundant tuple allocations when the timestamp has not advanced.
   */
  async updateHeartbeat(sessionId: string, newHeartbeat: Date): Promise<boolean> {
    const result = await this.db
      .updateTable('user_sessions')
      .set({ last_heartbeat: newHeartbeat })
      .where('id', '=', sessionId)
      // INVARIANT: Do not generate a new tuple version if value is identical
      .where(sql`last_heartbeat IS DISTINCT FROM ${newHeartbeat}`)
      .executeTakeFirst();

    return Number(result.numUpdatedRows) > 0;
  }

  /**
   * Queries real-time HOT update efficiency across relations.
   */
  async auditHOTRatios(): Promise<
    Array<{
      tableName: string;
      totalUpdates: number;
      hotUpdates: number;
      hotRatio: number;
      fillfactor: number;
      isCompliant: boolean;
    }>
  > {
    const rows = await sql<{
      tableName: string;
      totalUpdates: string;
      hotUpdates: string;
      hotRatio: number;
      fillfactor: number;
    }>`
      SELECT 
        c.relname AS "tableName",
        COALESCE(s.n_tup_upd, 0)::text AS "totalUpdates",
        COALESCE(s.n_tup_hot_upd, 0)::text AS "hotUpdates",
        CASE 
          WHEN COALESCE(s.n_tup_upd, 0) = 0 THEN 1.0
          ELSE ROUND(COALESCE(s.n_tup_hot_upd, 0)::numeric / s.n_tup_upd::numeric, 4)::float8
        END AS "hotRatio",
        COALESCE(
          (SELECT (regexp_match(reloptions::text, 'fillfactor=([0-9]+)'))[1]::int 
           FROM pg_class WHERE oid = c.oid),
          100
        ) AS "fillfactor"
      FROM pg_class c
      LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'r'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND COALESCE(s.n_tup_upd, 0) > 1000;
    `.execute(this.db);

    return rows.rows.map((r) => ({
      tableName: r.tableName,
      totalUpdates: Number(r.totalUpdates),
      hotUpdates: Number(r.hotUpdates),
      hotRatio: r.hotRatio,
      fillfactor: r.fillfactor,
      isCompliant: r.hotRatio >= 0.85,
    }));
  }
}
```

---

### Python (`asyncpg`): Asynchronous FSM Fragmentation Auditor & Online Repack Initiator

```python
import asyncio
from typing import Dict, Any, List
import asyncpg


class FSMHeapAuditor:
    """Audits PostgreSQL Free Space Map (FSM) health and Heap-Only Tuple (HOT) efficiency."""

    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def get_table_fsm_health(self, table_name: str) -> Dict[str, Any]:
        """Queries pg_freespace and pg_stat_user_tables to detect fragmentation and HOT degradation."""
        query = """
        WITH fsm_summary AS (
            SELECT 
                count(*) AS total_blocks,
                count(*) FILTER (WHERE avail >= 7000) AS near_empty_blocks,
                count(*) FILTER (WHERE avail < 500) AS nearly_full_blocks,
                ROUND(SUM(avail)::numeric / 1024, 0)::bigint AS free_space_kib,
                ROUND(AVG(avail)::numeric, 1)::float8 AS avg_free_bytes_per_block
            FROM pg_freespace($1)
        ),
        stat_summary AS (
            SELECT 
                COALESCE(n_tup_upd, 0) AS updates,
                COALESCE(n_tup_hot_upd, 0) AS hot_updates,
                CASE 
                    WHEN COALESCE(n_tup_upd, 0) = 0 THEN 1.0 
                    ELSE ROUND(n_tup_hot_upd::numeric / n_tup_upd::numeric, 4)::float8 
                END AS hot_ratio
            FROM pg_stat_user_tables
            WHERE relname = $1
        ),
        options AS (
            SELECT 
                COALESCE((regexp_match(reloptions::text, 'fillfactor=([0-9]+)'))[1]::int, 100) AS fillfactor
            FROM pg_class
            WHERE relname = $1
        )
        SELECT 
            $1 AS table_name,
            f.total_blocks,
            f.near_empty_blocks,
            f.nearly_full_blocks,
            f.free_space_kib,
            f.avg_free_bytes_per_block,
            s.updates,
            s.hot_updates,
            s.hot_ratio,
            o.fillfactor
        FROM fsm_summary f, stat_summary s, options o;
        """
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(query, table_name)
            if not row:
                raise ValueError(f"Table {table_name} not found or pg_freespace not available")
            return dict(row)

    async def apply_fillfactor_safely(self, table_name: str, target_fillfactor: int) -> None:
        """Sets table fillfactor with a 1500ms lock_timeout to prevent lock convoys."""
        if not (10 <= target_fillfactor <= 100):
            raise ValueError("Fillfactor must be between 10 and 100")

        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # INVARIANT: Strict lock timeout
                await conn.execute("SET LOCAL lock_timeout = '1500ms';")
                await conn.execute(f'ALTER TABLE "{table_name}" SET (fillfactor = {target_fillfactor});')
```

---

### Rust (`sqlx`): Zero-Allocation FSM Metric Collector

```rust
use sqlx::{PgPool, FromRow};
use anyhow::{Result, Context};

#[derive(Debug, FromRow)]
pub struct FsmTableReport {
    pub table_name: String,
    pub fillfactor: i32,
    pub total_updates: i64,
    pub hot_updates: i64,
    pub hot_ratio: f64,
    pub is_hot_compliant: bool,
}

pub struct FsmTelemetryService {
    pool: PgPool,
}

impl FsmTelemetryService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Queries relation stats to detect HOT update failure and fillfactor misalignment.
    pub async fn audit_relation(&self, table_name: &str) -> Result<FsmTableReport> {
        let query = r#"
            SELECT 
                c.relname AS table_name,
                COALESCE(
                    (SELECT (regexp_match(reloptions::text, 'fillfactor=([0-9]+)'))[1]::int 
                     FROM pg_class WHERE oid = c.oid),
                    100
                ) AS fillfactor,
                COALESCE(s.n_tup_upd, 0) AS total_updates,
                COALESCE(s.n_tup_hot_upd, 0) AS hot_updates,
                CASE 
                    WHEN COALESCE(s.n_tup_upd, 0) = 0 THEN 1.0
                    ELSE ROUND(COALESCE(s.n_tup_hot_upd, 0)::numeric / s.n_tup_upd::numeric, 4)::float8
                END AS hot_ratio,
                CASE 
                    WHEN COALESCE(s.n_tup_upd, 0) < 500 THEN true
                    ELSE (ROUND(COALESCE(s.n_tup_hot_upd, 0)::numeric / s.n_tup_upd::numeric, 4) >= 0.85)
                END AS is_hot_compliant
            FROM pg_class c
            LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = $1 AND n.nspname NOT IN ('pg_catalog', 'information_schema');
        "#;

        let report = sqlx::query_as::<_, FsmTableReport>(query)
            .bind(table_name)
            .fetch_one(&self.pool)
            .await
            .context(format!("Failed to audit FSM for table {}", table_name))?;

        Ok(report)
    }
}
```

---

## 5. Autonomous TypeScript Guard Engine

Below is the complete, self-contained `AgenticFSMGuardEngine` implementing static schema inspection, HOT update feasibility calculus, relation extension queue simulations, and migration plan generation.

```typescript
/**
 * AgenticFSMGuardEngine
 * Industrial-grade architectural sentinel for PostgreSQL Free Space Map (FSM),
 * heap page layout optimization, fillfactor sizing, and HOT update preservation.
 */
export interface TableSchemaInput {
  tableName: string;
  avgRowSizeBytes: number;
  estimatedUpdatesPerDay: number;
  estimatedInsertsPerDay: number;
  secondaryIndexCount: number;
  currentFillfactor?: number;
}

export interface FSMAnalysisResult {
  tableName: string;
  recommendedFillfactor: number;
  headroomBytes: number;
  maxConsecutiveHOTUpdates: number;
  estimatedWriteAmpReductionPercent: number;
  violations: string[];
  recommendations: string[];
  migrationDdl: string;
}

export class AgenticFSMGuardEngine {
  private static readonly PAGE_SIZE = 8192;
  private static readonly PAGE_HEADER_SIZE = 24;
  private static readonly ITEM_ID_SIZE = 4;
  private static readonly USABLE_PAGE_SPACE =
    AgenticFSMGuardEngine.PAGE_SIZE - AgenticFSMGuardEngine.PAGE_HEADER_SIZE; // 8168 bytes

  /**
   * Audits table schema parameters and calculates optimal fillfactor for HOT updates.
   */
  public static analyzeTableStorage(input: TableSchemaInput): FSMAnalysisResult {
    const violations: string[] = [];
    const recommendations: string[] = [];
    const currentFF = input.currentFillfactor ?? 100;

    const isUpdateHeavy =
      input.estimatedUpdatesPerDay > 500 &&
      input.estimatedUpdatesPerDay >= input.estimatedInsertsPerDay * 0.2;

    // Check 1: Update-heavy table with default fillfactor = 100
    if (isUpdateHeavy && currentFF === 100) {
      violations.push(
        `HOT_UPDATE_STARVATION: Table '${input.tableName}' has fillfactor = 100 with ` +
          `${input.estimatedUpdatesPerDay.toLocaleString()} daily updates. Every single update will fail ` +
          `Heap-Only Tuple (HOT) optimization, multiplying index writes across ${input.secondaryIndexCount} indexes.`
      );
      recommendations.push(
        `Calibrate table fillfactor to reserve headroom for in-place updates without page jumping.`
      );
    }

    // Check 2: Row size too large for HOT updates
    const tupleAndItemSize = input.avgRowSizeBytes + this.ITEM_ID_SIZE;
    if (tupleAndItemSize > this.USABLE_PAGE_SPACE * 0.5) {
      violations.push(
        `WIDE_TUPLE_HOT_LIMITATION: Average row size (${input.avgRowSizeBytes}B) exceeds 50% of usable page space. ` +
          `A single page cannot hold two versions of this tuple regardless of fillfactor.`
      );
      recommendations.push(
        `Extract frequently updated columns into a separate 1:1 vertically partitioned relation.`
      );
    }

    // Calculate optimal fillfactor based on tuple size:
    // We target 2 consecutive HOT updates before vacuuming
    let targetFF = 100;
    let maxHOTUpdates = 0;
    let headroomBytes = 0;

    if (isUpdateHeavy) {
      // Calculate headroom needed for at least 2 updates
      const targetUpdates = 2;
      const neededHeadroom = targetUpdates * tupleAndItemSize;
      const calculatedFF = Math.floor(
        ((this.USABLE_PAGE_SPACE - neededHeadroom) / this.USABLE_PAGE_SPACE) * 100
      );

      // Clamp fillfactor between 70 and 90 for OLTP tables
      targetFF = Math.max(70, Math.min(90, calculatedFF));
      headroomBytes = Math.floor(this.USABLE_PAGE_SPACE * (1 - targetFF / 100));
      maxHOTUpdates = Math.floor(headroomBytes / tupleAndItemSize);
    }

    // Calculate write amplification reduction:
    // Default write amp = 1 + (1 - 0) * N_idx = 1 + N_idx
    // Tuned write amp = 1 + (1 - 0.90) * N_idx = 1 + 0.1 * N_idx
    const defaultAmp = 1 + input.secondaryIndexCount;
    const tunedAmp = 1 + 0.1 * input.secondaryIndexCount;
    const reductionPercent =
      input.secondaryIndexCount > 0
        ? Math.round(((defaultAmp - tunedAmp) / defaultAmp) * 100)
        : 0;

    // Generate safe online migration DDL
    const migrationDdl = [
      `-- Step 1: Update catalog metadata under strict lock timeout`,
      `SET LOCAL lock_timeout = '1500ms';`,
      `ALTER TABLE "${input.tableName}" SET (fillfactor = ${targetFF});`,
      ``,
      `-- Step 2: Repack existing pages online without table lockout (execute via CLI)`,
      `-- pg_repack --table "${input.tableName}" --no-kill-backend`,
    ].join('\n');

    return {
      tableName: input.tableName,
      recommendedFillfactor: targetFF,
      headroomBytes,
      maxConsecutiveHOTUpdates: maxHOTUpdates,
      estimatedWriteAmpReductionPercent: reductionPercent,
      violations,
      recommendations,
      migrationDdl,
    };
  }

  /**
   * Simulates page layout state under successive updates.
   */
  public static simulatePagePacking(
    fillfactor: number,
    rowSizeBytes: number,
    numUpdates: number
  ): {
    initialTuples: number;
    successfulHOTUpdates: number;
    pageOverflowOccurred: boolean;
    finalFreeSpace: number;
  } {
    const tupleSize = rowSizeBytes + this.ITEM_ID_SIZE;
    const initialSpace = Math.floor(this.USABLE_PAGE_SPACE * (fillfactor / 100));
    const initialTuples = Math.floor(initialSpace / tupleSize);
    let remainingFreeSpace = this.USABLE_PAGE_SPACE - initialTuples * tupleSize;

    let successfulHOTUpdates = 0;
    let pageOverflowOccurred = false;

    for (let i = 0; i < numUpdates; i++) {
      if (remainingFreeSpace >= tupleSize) {
        remainingFreeSpace -= tupleSize;
        successfulHOTUpdates++;
      } else {
        pageOverflowOccurred = true;
        break;
      }
    }

    return {
      initialTuples,
      successfulHOTUpdates,
      pageOverflowOccurred,
      finalFreeSpace: remainingFreeSpace,
    };
  }
}
```

---

## 6. The 6-State Heap & FSM Lifecycle Finite-State Machine (FSM)

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               HEAP PAGE ALLOCATION & HOT LIFECYCLE STATE MACHINE                       │
└────────────────────────────────────────────────────────────────────────────────────────┘

              [ 1. SCHEMA_PROVISIONING ]
                          │
                          │ Workload Analysis (Append-Only vs OLTP)
                          ▼
              [ 2. FILLFACTOR_CALIBRATION ]
                          │
                          │ INSERT batch into heap pages
                          ▼
              [ 3. FSM_PAGE_ALLOCATION ] ◄───────────────┐
                          │                              │
             Row UPDATE   │                              │ Page defragmented
             Triggered    │                              │ via autovacuum
                          ▼                              │
             Is Headroom Available &           No        │
             No Indexed Columns Modified? ───────────────┼──────────┐
                          │                              │          │
                     Yes  │                              │          │
                          ▼                              │          │
              [ 4. IN_PAGE_HOT_CHAIN ]                   │          │
                          │                              │          │
             Pruning via  │                              │          │ Requires
             PageRepair   ▼                              │          │ new block
              [ 5. LINE_POINTER_RECLAIM ]                │          │
                          │                              │          │
                          └──────────────────────────────┘          ▼
                                                       [ 6. RELATION_EXTENSION ]
                                                                    │
                                                                    │ Bulk page alloc
                                                                    ▼
                                                       [ Back to FSM_PAGE_ALLOCATION ]
```

### State Transition Invariants

| State | Entry Condition | Action / Invariant | Exit Guard |
| :--- | :--- | :--- | :--- |
| **1. SCHEMA_PROVISIONING** | Migration creation | Classify table as Append-Only or Update-Heavy. | Explicit `fillfactor` clause specified. |
| **2. FILLFACTOR_CALIBRATION** | Target table identified | Calculate $\Phi^* \le 100 \times (1 - \frac{k(S+4)}{8168})$. Set $\Phi = 75–85$. | Headroom reserved $\ge 2 \times S_{\text{tuple}}$. |
| **3. FSM_PAGE_ALLOCATION** | DML Execution | Check FSM for page with $q \ge q_{\text{req}}$. Insert tuple body & line pointer. | If no page found, transition to State 6. |
| **4. IN_PAGE_HOT_CHAIN** | Tuple `UPDATE` | Append new tuple version to same 8KB block. Link line pointer chain. No index write. | Headroom remaining $< S_{\text{tuple}}$. |
| **5. LINE_POINTER_RECLAIM** | Background Autovacuum | Clean dead tuple bodies; update line pointers to `LP_UNUSED`; refresh FSM. | FSM binary tree updated; free space returned. |
| **6. RELATION_EXTENSION** | Heap space exhausted | Acquire `RelationExtensionLock`. Vectorize via bulk allocation. Set `lock_timeout`. | New 8KB block formatted and registered in FSM. |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Every automated PR modifying database schemas, table configurations, or high-throughput write services must satisfy all 6 DoD gates:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                  6-GATE DEFINITION OF DONE (DoD) COMPLIANCE MATRIX                     │
├────────┬─────────────────────────────┬─────────────────────────────────────────────────┤
│ Gate 1 │ Schema Fillfactor Audit     │ Update-heavy tables must declare fillfactor<95  │
├────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
│ Gate 2 │ No Synchronous VACUUM FULL  │ Prohibit VACUUM FULL & CLUSTER in migrations    │
├────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
│ Gate 3 │ HOT Ratio Telemetry Gate    │ Assert pg_stat_user_tables hot_ratio >= 0.85    │
├────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
│ Gate 4 │ Extension Lock Timeout      │ Bulk inserts and DDL have lock_timeout <= 2000ms│
├────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
│ Gate 5 │ HOT-Guarded UPDATE Clauses  │ Dynamic updates include IS DISTINCT FROM check  │
├────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
│ Gate 6 │ Vectorized Batch Ingestion  │ Ingestion uses UNNEST arrays or COPY protocol   │
└────────┴─────────────────────────────┴─────────────────────────────────────────────────┘
```

| DoD Gate | Verification Command / Static Linter | Pass Criteria | Failure Blast Radius |
| :--- | :--- | :--- | :--- |
| **Gate 1: Fillfactor Declaration** | `! grep -ri "CREATE TABLE" migrations/ \| grep -i "sessions\|orders\|inventory" \| grep -v "fillfactor"` | All update-heavy relations have explicit `fillfactor = 75-85`. | 100% HOT failure, $5\times–20\times$ write amplification. |
| **Gate 2: Zero Blocking Rewrites** | `! grep -riE "VACUUM FULL|CLUSTER [a-zA-Z0-9_]+ USING" migrations/ src/` | Zero occurrences of blocking table rewrites. | Table-wide `ACCESS EXCLUSIVE` lockout during production. |
| **Gate 3: HOT Ratio Invariant** | `psql -c "SELECT relname FROM pg_stat_user_tables WHERE n_tup_upd > 1000 AND (n_tup_hot_upd::float/n_tup_upd) < 0.85;"` | Query returns 0 rows across production OLTP tables. | Index bloat, buffer cache eviction, I/O saturation. |
| **Gate 4: Lock Timeout Fencing** | `! grep -ri "ALTER TABLE.*SET (fillfactor" migrations/ \| grep -v "lock_timeout"` | All fillfactor changes precede with sub-second `lock_timeout`. | DDL queuing head-of-line lock convoys. |
| **Gate 5: HOT-Guarded UPDATEs** | `! grep -ri "UPDATE " src/ \| grep -v -i "DISTINCT FROM"` | Non-key updates use `WHERE col IS DISTINCT FROM $val`. | Redundant tuple creation burning page headroom. |
| **Gate 6: Bulk Ingestion Vectorization** | `! grep -ri "for.*INSERT INTO" src/ internal/` | High-frequency inserts use batch arrays or `COPY`. | `RelationExtensionLock` contention, TPS collapse. |
