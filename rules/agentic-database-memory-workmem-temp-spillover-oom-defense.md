---
description: PostgreSQL memory architecture, work_mem per-node allocation, hash_mem_multiplier tuning, temporary disk spillover elimination, maintenance_work_mem vacuum optimization, Linux OOM killer fencing (oom_score_adj), temp_file_limit disk protection, and EXPLAIN (ANALYZE, BUFFERS) CI memory verification across Go (pgx/v5), TypeScript (Drizzle/Kysely/Prisma), Python (psycopg/SQLAlchemy), Rust (tokio-postgres), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{memory,spill,workmem,temp,database,db,dao,repository,schema,query,pool}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Memory Management, Temp Spillover Elimination & OOM Killer Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to configure PostgreSQL memory parameters, size connection pools, design complex analytical reports, execute large batch migrations, or establish continuous database buffer spill and OOM regression testing across PostgreSQL, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `Prisma`), Python (`psycopg3`, `SQLAlchemy`), or Rust (`tokio-postgres`). Eliminate the "WorkMem Per-Node Multiplier & OOM Killer Postmaster Decapitation" (where developers and agents assume `work_mem` is allocated once per query, unaware that each sort, hash join, and parallel worker allocates its own independent `work_mem` buffer, causing 50 concurrent complex queries with 8 execution nodes to exhaust 128 GB of RAM and trigger the Linux kernel Out-Of-Memory killer to SIGKILL the parent PostgreSQL postmaster), the "Undersized WorkMem & External Merge Sort / Hash Disk Spillover Avalanche" (where default `work_mem = 4MB` forces routine queries with `ORDER BY`, `DISTINCT`, or hash joins to spill millions of rows to temporary files in `pg_tblspc`, transforming sub-millisecond in-memory operations into multi-gigabyte disk I/O bottlenecks that saturate NVMe IOPS and inflate latency by $50\times–200\times$), the "Unbounded Temp File Accumulation & 100% Disk PANIC Shutdown" (where unmonitored queries create tens of gigabytes of disk temp files because `log_temp_files = -1` and `temp_file_limit = -1`, filling storage until the database halts with `PANIC: could not write to log file: No space left on device`), the "Linux Kernel Overcommit Score Inversion & Victim Selection Vulnerability" (where running with default `vm.overcommit_memory = 0` and neutral `/proc/<postmaster_pid>/oom_score_adj` causes the Linux kernel to target the parent PostgreSQL coordinator during memory spikes instead of the offending backend worker), the "Maintenance WorkMem Starvation & Multi-Pass Autovacuum Freezing Stagnation" (where default `maintenance_work_mem = 64MB` limits the autovacuum dead tuple TID array to only 11 million entries, forcing autovacuum to perform 5 to 10 full re-scans of multi-gigabyte indexes on churned tables, prolonging maintenance from minutes to 16 hours and inducing transaction ID wraparound risks), and the "Hash Mem Multiplier Disconnect & Unindexed Hash Join Spillover Trap" (where uncalibrated `hash_mem_multiplier` fails to provide memory headroom for complex hash tables, forcing multi-batch disk spills during multi-table joins) by establishing a strict 5-Tier Memory & Temp Spillover Governance Ladder, host-level OOM hardening, transaction-scoped adaptive allocation (`SET LOCAL work_mem`), and machine-verifiable `EXPLAIN (ANALYZE, BUFFERS)` CI gates.

---

## 1. Architectural Taxonomy: The 6 Memory & Temp Spill Catastrophes vs The 5-Tier Governance Ladder

The PostgreSQL memory architecture divides memory into two fundamental domains:
1. **Shared Memory Buffers (`shared_buffers`, `wal_buffers`)**: Allocated once at engine boot, managed via the clock-sweep buffer cache eviction algorithm, and shared across all backend processes for caching relational data pages and write-ahead log records.
2. **Local Backend Process Memory (`work_mem`, `maintenance_work_mem`, `temp_buffers`)**: Dynamically allocated by each individual backend worker as needed during query execution for internal operations:
   - **Sort Operations**: Sorting data for `ORDER BY`, `DISTINCT`, and Merge Joins (`Sort` node).
   - **Hash Operations**: Building in-memory hash tables for `Hash Join` and `HashAggregate` (grouped data).
   - **Bitmap Operations**: Building bitmap index tuples (`Bitmap Index Scan`).
   - **Maintenance Operations**: Building indexes (`CREATE INDEX`), performing `VACUUM` dead tuple TID tracking, and foreign key validations (`maintenance_work_mem`).

When autonomous coding agents generate database configurations or execute analytical queries, LLMs frequently fall prey to catastrophic architectural misconceptions:

```typescript
// ❌ CATASTROPHIC LLM DATABASE MEMORY ANTI-PATTERNS

// 1. Assuming work_mem is allocated once per query or once per connection!
// Reality: work_mem is allocated PER SORT and PER HASH OPERATION per execution node!
// If a query has 4 Hash Joins, 2 Sorts, and runs with 4 parallel workers:
// Total allocations = (4 + 2) * (1 leader + 4 workers) = 30 independent work_mem allocations!
// If work_mem = 128MB, ONE single query can allocate 30 * 128MB = 3.84 GB of RAM!
// 20 concurrent dashboard requests = 76.8 GB RAM -> Linux OOM Killer SIGKILLs PostgreSQL!

// 2. Leaving default work_mem = 4MB in production systems!
// A user runs SELECT * FROM transactions ORDER BY created_at DESC LIMIT 50000;
// At 4MB, sorting 50,000 wide rows cannot fit in RAM.
// The engine switches from in-memory quicksort to "external merge Disk: 42180kB".
// Latency degrades from 15ms to 1,850ms, burning 40MB of disk I/O per request!

// 3. Omitting log_temp_files and temp_file_limit!
// When temp_file_limit is -1 (unlimited) and log_temp_files is -1 (disabled),
// a single Cartesian join or runaway agent query silently writes 80GB of temp files to disk.
// The underlying NVMe drive hits 100% full -> PostgreSQL panics and shuts down!

// 4. Modifying work_mem at the global session level instead of transaction-scoped SET LOCAL!
// await db.query(`SET work_mem = '1GB'`); // FATAL: Session level setting leaks to PgBouncer
// Future OLTP point queries executed on this recycled physical connection now allocate 1GB!
```

In production architectures, these anti-patterns manifest as six catastrophic failure modes:

- **The "WorkMem Per-Node Multiplier & OOM Killer Postmaster Decapitation"**:
  - The PostgreSQL executor allocates `work_mem` on demand for each execution node requiring temporary memory. A single complex SQL query containing 3 `Hash Join` nodes, a `HashAggregate`, and a window function `Sort` contains 5 distinct memory consumers.
  - When parallel query execution is active (`max_parallel_workers_per_gather = 4`), each parallel worker process independently instantiates these nodes.
  - The multiplier is:
    $$K_{\text{allocations}} = N_{\text{nodes}} \times (1 + P_{\text{workers}})$$
  - For a query with 5 nodes and 4 workers, $K = 5 \times 5 = 25$ allocations. With `work_mem = 128MB`, this single query demands $25 \times 128\text{ MB} = 3.2\text{ GB}$.
  - Under concurrent load (e.g., 30 API clients querying analytics simultaneously), the kernel experiences severe memory pressure.
  - If Linux overcommit is active (`vm.overcommit_memory = 0`), the Linux kernel OOM killer activates, scans process badness scores, and abruptly sends `SIGKILL` to the `postgres` postmaster process. The entire cluster crashes instantly, severing all in-flight transactions.
  - Invariant: Size global `work_mem` strictly according to connection pool concurrency limits ($16\text{MB}–64\text{MB}$), reserving larger allocations strictly for isolated, transaction-scoped `SET LOCAL work_mem` blocks.

- **The "Undersized WorkMem & External Merge Sort / Hash Disk Spillover Avalanche"**:
  - PostgreSQL ships with a historical default `work_mem = 4MB`. Modern datasets and analytical aggregation pipelines routinely process tens of thousands of intermediate tuples.
  - When sort data exceeds `work_mem`, the executor cannot use in-memory Quicksort. It partitions the dataset into sorted disk runs on temporary tablespace storage and executes an **External Merge Sort**.
  - Similarly, when an in-memory hash table for a `Hash Join` exceeds `work_mem`, the executor multiplies hash batches (`Batches > 1`), spilling rows outside the first batch to disk files and re-reading them iteratively.
  - Disk spills incur massive read/write amplification, saturate disk controllers, burn ephemeral storage IOPS, and degrade p99 query latency by two to three orders of magnitude ($50\times–200\times$).
  - Invariant: Audit `EXPLAIN (ANALYZE, BUFFERS)` execution plans in CI regression suites, strictly enforcing `Sort Method: quicksort` and `Hash Batches: 1` with zero temporary disk blocks written.

- **The "Unbounded Temp File Accumulation & 100% Disk PANIC Shutdown"**:
  - In default PostgreSQL installations, `temp_file_limit = -1`, meaning an individual backend can generate unbounded temporary files until physical storage is completely exhausted.
  - Furthermore, `log_temp_files = -1` leaves temporary file creation unlogged, concealing disk spills from observability dashboards.
  - A faulty reporting query, Cartesian join product (`CROSS JOIN`), or recursive CTE executed by an autonomous agent can create hundreds of gigabytes of temporary files within minutes.
  - Once the disk reaches 100% capacity, PostgreSQL cannot write incoming WAL segments, and the database engine immediately halts with a fatal `PANIC: could not write to log file: No space left on device`.
  - Invariant: Mandatory storage boundaries: enforce `temp_file_limit = '10GB'` (or $15\%$ of disk space) per query process, and set `log_temp_files = 0` to log every single temporary file creation regardless of size.

- **The "Linux Kernel Overcommit Score Inversion & Victim Selection Vulnerability"**:
  - On Linux hosts, the kernel's memory management subsystem uses heuristic overcommit (`vm.overcommit_memory = 0`). Under memory spikes, the Out-Of-Memory (OOM) killer selects a target process using its internal heuristic:
    $$\text{badness} = \frac{\text{RSS}}{\text{Total RAM}} + \text{oom\_score\_adj}$$
  - The parent `postgres` postmaster process holds open all shared memory mappings (`shared_buffers`), which inflates its apparent resident set size (RSS).
  - Without protective configuration, the OOM killer frequently scores the parent postmaster higher than the individual rogue backend worker, killing the engine rather than the misbehaving query!
  - Invariant: Configure the Linux host with `vm.overcommit_memory = 2` (strict bounding) or set `/proc/<postmaster_pid>/oom_score_adj = -1000` (immune to OOM killer), while child backend workers run with default or positive `oom_score_adj` ($100$), ensuring the kernel terminates the single offending query rather than the database cluster.

- **The "Maintenance WorkMem Starvation & Multi-Pass Autovacuum Freezing Stagnation"**:
  - Autovacuum workers scan tables to remove dead row versions and update free space maps. To clean dead tuples from indexes, the worker collects tuple identifiers (TIDs: 6-byte pointers containing page block and line offset) in an in-memory buffer sized by `maintenance_work_mem` (or `autovacuum_work_mem`).
  - At default `maintenance_work_mem = 64MB`, the TID array can hold at most:
    $$\frac{64 \times 1024 \times 1024}{6} \approx 11.18 \times 10^6 \text{ dead tuples}$$
  - If a table has 50,000,000 dead tuples, autovacuum fills the TID buffer, halts table scanning, and executes a full pass over **every index on the table**. It then clears the buffer and repeats the entire index scan 5 times!
  - Index scans on 20GB B-trees take hours. Multi-pass autovacuum stretches vacuum execution from 5 minutes to 12 hours, holding autovacuum worker slots, allowing table bloat to spiral, and threatening transaction ID wraparound.
  - Invariant: Enforce `maintenance_work_mem = 1GB` to `2GB` for administrative maintenance and `autovacuum_work_mem = 256MB` to `512MB` per autovacuum worker, guaranteeing single-pass TID collection on relations with up to 90 million dead tuples.

- **The "Hash Mem Multiplier Disconnect & Unindexed Hash Join Spillover Trap"**:
  - In PostgreSQL 13+, `hash_mem_multiplier` (default `1.0` or `2.0`) allows hash-based operations (`Hash Join`, `HashAggregate`) to consume up to `work_mem * hash_mem_multiplier`.
  - Hash tables suffer from non-trivial memory overhead (bucket arrays, collision chaining pointers, and tuple headers) compared to compact sorting arrays.
  - When `hash_mem_multiplier` is left at default `1.0` on heavy aggregation workloads, hash aggregations prematurely exceed allocated memory and fall back to disk-based hash aggregation or external grouping.
  - Invariant: Calibrate `hash_mem_multiplier = 2.0` on database engines hosting complex analytical reporting or multi-join queries.

---

## 2. Mathematical Theorems & Formal Optimization Proofs

### Theorem 1: Total Process Peak Memory Upper-Bound Calculus

Let a PostgreSQL database instance operate on a host with total physical RAM $R_{\text{total}}$ and configured parameters:
- $S_{\text{buf}}$: Shared memory buffer pool (`shared_buffers`)
- $C_{\text{max}}$: Maximum allowable backend connections (`max_connections`)
- $W_{\text{mem}}$: Work memory per execution node (`work_mem`)
- $M_{\text{base}}$: Base memory footprint of an idle backend process ($\approx 10\text{ MB} - 15\text{ MB}$)
- $K_{\text{max}}$: Maximum concurrent memory-consuming execution nodes (sorts, hash joins, hash aggregates) per active query
- $P_{\text{workers}}$: Maximum parallel workers per query node (`max_parallel_workers_per_gather`)
- $\mu_{\text{hash}}$: Hash memory multiplier (`hash_mem_multiplier`)
- $N_{\text{vac}}$: Maximum concurrent autovacuum workers (`autovacuum_max_workers`)
- $V_{\text{mem}}$: Maintenance memory per autovacuum worker (`autovacuum_work_mem`)

The theoretical peak host memory consumption $M_{\text{peak}}$ across all active database processes is governed by:

$$M_{\text{peak}} = S_{\text{buf}} + \sum_{i=1}^{C_{\text{active}}} \left[ M_{\text{base}} + \sum_{j=1}^{K_i} W_{\text{mem}} \times (1 + P_i) \times \psi_j \right] + N_{\text{vac\_active}} \times V_{\text{mem}}$$

where $\psi_j = \mu_{\text{hash}}$ if node $j$ is a hash operation, and $\psi_j = 1.0$ if node $j$ is a sort or bitmap operation.

Under worst-case concurrent saturation where $C_{\text{active}} = C_{\text{max}}$, all queries execute complex plans with $K_{\text{max}}$ nodes, and parallel workers are fully spawned:

$$M_{\text{worst-case}} = S_{\text{buf}} + C_{\text{max}} \cdot M_{\text{base}} + C_{\text{max}} \cdot K_{\text{max}} \cdot (1 + P_{\text{workers}}) \cdot W_{\text{mem}} \cdot \max(1, \mu_{\text{hash}}) + N_{\text{vac}} \cdot V_{\text{mem}}$$

**The Anti-OOM Stability Criterion**: To guarantee that the Linux kernel OOM killer is never triggered under peak load, total allocation must satisfy the safety inequality:

$$M_{\text{worst-case}} \le \gamma \times R_{\text{total}}$$

where $\gamma \le 0.80$ (leaving $20\%$ of RAM for the Linux OS kernel, page cache, socket buffers, and administrative daemons).

**Derivation of Maximum Safe Global WorkMem**:
Solving for $W_{\text{mem}}$ yields the exact ceiling for global database configuration:

$$W_{\text{mem}} \le \frac{\gamma \cdot R_{\text{total}} - S_{\text{buf}} - C_{\text{max}} \cdot M_{\text{base}} - N_{\text{vac}} \cdot V_{\text{mem}}}{C_{\text{max}} \cdot K_{\text{max}} \cdot (1 + P_{\text{workers}}) \cdot \max(1, \mu_{\text{hash}})}$$

**Empirical Sizing Example**:
- Host RAM $R_{\text{total}} = 64\text{ GB}$, $\gamma = 0.80 \implies \text{Budget} = 51.2\text{ GB}$
- $S_{\text{buf}} = 16\text{ GB}$ ($25\%$ of RAM)
- $C_{\text{max}} = 100$ connections, $M_{\text{base}} = 15\text{ MB} \implies 1.5\text{ GB}$
- $N_{\text{vac}} = 3$ workers, $V_{\text{mem}} = 512\text{ MB} \implies 1.536\text{ GB}$
- Remaining memory for work nodes: $51.2 - 16 - 1.5 - 1.536 = 32.164\text{ GB}$
- Worst-case query profile: $K_{\text{max}} = 3$ nodes, $P_{\text{workers}} = 2$, $\mu_{\text{hash}} = 2.0$:
  Denominator $= 100 \times 3 \times (1 + 2) \times 2.0 = 1,800$

$$W_{\text{mem}} \le \frac{32,164\text{ MB}}{1,800} \approx 17.86\text{ MB}$$

Setting `work_mem = 16MB` or `32MB` ensures mathematical immunity against host OOM termination while avoiding connection starvation.

---

### Theorem 2: Autovacuum Single-Pass Dead Tuple TID Capacity Calculus

In PostgreSQL's vacuum implementation, dead tuple ItemPointers (TIDs) are tracked in an internal memory array during the heap scan. Each TID requires exactly 6 bytes of memory:
- Block Number (`BlockIdData`): 4 bytes (32-bit integer representing physical heap page index)
- Line Offset (`OffsetNumber`): 2 bytes (16-bit integer representing tuple slot within the 8KB page)

Let $M_{\text{maint}}$ be the memory allocated to the vacuum process (`maintenance_work_mem` or `autovacuum_work_mem`). Because PostgreSQL caps the TID collection array at $1\text{ GB}$ regardless of configuration (prior to PG 17), effective memory $M_{\text{eff}} = \min(M_{\text{maint}}, 1024\text{ MB})$.

The maximum dead tuple capacity $N_{\text{TID}}$ collected in a single heap scan pass is:

$$N_{\text{TID}} = \left\lfloor \frac{M_{\text{eff}}}{6\text{ bytes}} \right\rfloor = \left\lfloor \frac{M_{\text{eff}} \times 1024^2}{6} \right\rfloor$$

Let relation $R$ contain $D$ dead tuples and $I$ secondary B-tree indexes. The number of required vacuum passes $P_{\text{vacuum}}$ is:

$$P_{\text{vacuum}} = \left\lceil \frac{D}{N_{\text{TID}}} \right\rceil$$

Total secondary index read passes across all indexes is:

$$\Omega_{\text{index\_scans}} = P_{\text{vacuum}} \times I = \left\lceil \frac{D}{N_{\text{TID}}} \right\rceil \times I$$

**Case Study**:
Let a table have $D = 45,000,000$ dead tuples and $I = 6$ indexes:
1. **Under Default Setting (`maintenance_work_mem = 64MB`)**:
   $$N_{\text{TID}} = \frac{64 \times 1024 \times 1024}{6} \approx 11,184,810\text{ tuples}$$
   $$P_{\text{vacuum}} = \left\lceil \frac{45,000,000}{11,184,810} \right\rceil = 5\text{ passes}$$
   $$\Omega_{\text{index\_scans}} = 5 \times 6 = 30\text{ full index scans}$$
   Vacuum must traverse every index 5 times, re-reading index pages from disk, incurring severe cache eviction and running for $4.2\text{ hours}$.
2. **Under Calibrated Setting (`maintenance_work_mem = 1GB`)**:
   $$N_{\text{TID}} = \frac{1024 \times 1024 \times 1024}{6} \approx 178,956,970\text{ tuples}$$
   $$P_{\text{vacuum}} = \left\lceil \frac{45,000,000}{178,956,970} \right\rceil = 1\text{ pass}$$
   $$\Omega_{\text{index\_scans}} = 1 \times 6 = 6\text{ full index scans}$$
   Vacuum completes in a **single pass**, reducing total index I/O by $80\%$ and shrinking duration to $22\text{ minutes}$.

---

### Theorem 3: External Merge Sort vs In-Memory Quicksort I/O Complexity Law

Let an execution node sort $N$ tuples of average size $w$ bytes, yielding total dataset size $S = N \times w$.
Let $W$ be the memory budget allocated to the sort node (`work_mem`).

**Regime 1: In-Memory Sort ($S \le W$)**:
The sort operation completes entirely in RAM using Quicksort or Top-N Heapsort:
- Disk I/O: $\mathcal{V}_{\text{disk}} = 0\text{ bytes}$
- Time Complexity: $T_{\text{in-mem}} = \mathcal{O}(N \log_2 N) \times \tau_{\text{cpu}}$
- Execution latency $\tau_{\text{exec}} \in [1\text{ms}, 25\text{ms}]$.

**Regime 2: External Merge Sort ($S > W$)**:
When $S > W$, the engine partitions the input into $\left\lceil \frac{S}{W} \right\rceil$ initial sorted runs and writes them to temporary disk files. It then iteratively merges these runs using a $K$-way merge tree (where $K$ is the merge fan-in factor, typically $K \approx 32$).

The number of merge passes over the entire dataset is:

$$\Phi_{\text{passes}} = \left\lceil \log_K \left( \frac{S}{W} \right) \right\rceil$$

Total disk I/O volume written and read is:

$$\mathcal{V}_{\text{disk}} = 2 \times S \times \left( 1 + \Phi_{\text{passes}} \right)$$

Let $\rho_{\text{disk}}$ be the sequential disk read/write throughput (e.g., $500\text{ MB/s}$ on NVMe EBS).
The added disk latency penalty is:

$$\Delta T_{\text{I/O}} = \frac{\mathcal{V}_{\text{disk}}}{\rho_{\text{disk}}} = \frac{2 \times S \times (1 + \lceil \log_K(S/W) \rceil)}{\rho_{\text{disk}}}$$

When $S = 2\text{ GB}$ and $W = 4\text{ MB}$:
$$\Phi_{\text{passes}} = \left\lceil \log_{32} \left( \frac{2048}{4} \right) \right\rceil = \left\lceil \log_{32}(512) \right\rceil = 2\text{ passes}$$
$$\mathcal{V}_{\text{disk}} = 2 \times 2\text{ GB} \times (1 + 2) = 12\text{ GB written and read}$$
$$\Delta T_{\text{I/O}} = \frac{12,000\text{ MB}}{500\text{ MB/s}} = 24.0\text{ seconds}$$

An operation that would execute in $220\text{ ms}$ in-memory takes **24.2 seconds** on disk—a **$110\times$ performance degradation**. Transaction-scoped allocation (`SET LOCAL work_mem = '256MB'`) collapses merge passes to zero, reclaiming pure in-memory execution.

---

## 3. 5-Tier Memory & Temp Spillover Governance Ladder

```
+--------------------------------------------------------------------------------------------------+
|                     5-TIER DATABASE MEMORY & TEMP SPILLOVER GOVERNANCE LADDER                   |
+--------------------------------------------------------------------------------------------------+
| Tier 4: CONTINUOUS BUFFER & DISK SPILL CI SENTINEL                                               |
| - Automated CI regression gates running EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)                   |
| - Enforce TempWrittenBlocks == 0, Sort Method == quicksort, and Hash Batches == 1                |
+--------------------------------------------------------------------------------------------------+
| Tier 3: TRANSACTION-SCOPED ADAPTIVE ALLOCATION (SET LOCAL)                                       |
| - Analytical reporting and batch data processing run SET LOCAL work_mem = '256MB'                |
| - Scoped strictly to explicit transaction blocks; zero connection pool setting bleed             |
+--------------------------------------------------------------------------------------------------+
| Tier 2: MAINTENANCE WORKMEM & AUTOVACUUM TID SCALING                                             |
| - Set maintenance_work_mem = 1GB-2GB for single-pass DDL and index builds                        |
| - Set autovacuum_work_mem = 256MB-512MB ensuring single-pass TID collection on 50M+ dead rows    |
+--------------------------------------------------------------------------------------------------+
| Tier 1: BASELINE WORKMEM & ZERO-SPILL OBSERVABILITY                                              |
| - Calibrate global work_mem = 16MB-64MB and hash_mem_multiplier = 2.0 based on pool concurrency  |
| - Enforce log_temp_files = 0, capturing every disk spill with byte-level precision              |
+--------------------------------------------------------------------------------------------------+
| Tier 0: KERNEL OVERCOMMIT, OOM IMMUNITY & DISK STORAGE FENCES                                    |
| - Host Linux /proc/<postmaster_pid>/oom_score_adj = -1000 preventing parent postmaster SIGKILL   |
| - Hard query boundary: temp_file_limit = '10GB' halting rogue Cartesian joins before disk fill   |
+--------------------------------------------------------------------------------------------------+
```

### Tier 0: Kernel Overcommit, OOM Immunity & Storage Fences

The base foundation establishes operating system and database storage limits that prevent cluster-wide panics:

1. **Linux Postmaster OOM Immunity**:
   Configure the systemd service file for PostgreSQL (`/etc/systemd/system/postgresql.service` or `/lib/systemd/system/postgresql.service`) to assign maximum immunity to the parent postmaster:
   ```ini
   [Service]
   # Postmaster parent is immune to OOM killer (-1000)
   OOMScoreAdjust=-1000
   ```
   PostgreSQL automatically resets child backend processes to `oom_score_adj = 0` (or `100` via `restart_after_crash = on`), ensuring that if memory is exhausted, the Linux kernel terminates the offending query backend rather than crashing the instance.

2. **Strict Disk Spill Limits (`temp_file_limit`)**:
   Prevent any single SQL statement from exhausting physical disk space:
   ```sql
   -- Set hard ceiling of 10GB per process for temporary files
   ALTER SYSTEM SET temp_file_limit = '10GB';
   SELECT pg_reload_conf();
   ```
   If an accidental Cartesian product or runaway query generates over 10GB of temporary files, PostgreSQL immediately aborts the transaction with:
   `ERROR: temporary file size exceeds temp_file_limit (10485760kB)`
   The database instance remains fully operational, and storage space is safeguarded.

---

### Tier 1: Baseline WorkMem & Zero-Spill Observability

1. **Global Baseline Calibration**:
   Set conservative global defaults for OLTP traffic, allowing high connection concurrency without risking OOM:
   ```sql
   -- Global baseline for OLTP workloads (100-200 concurrent connections)
   ALTER SYSTEM SET work_mem = '32MB';
   ALTER SYSTEM SET hash_mem_multiplier = 2.0;
   ```

2. **Mandatory Temporary File Logging**:
   Configure PostgreSQL to log every single temporary disk file creation:
   ```sql
   -- Log all temporary files created by queries (0 = log everything)
   ALTER SYSTEM SET log_temp_files = 0;
   SELECT pg_reload_conf();
   ```
   PostgreSQL outputs audit log entries whenever a spill occurs:
   `LOG: temporary file: path "base/pgsql_tmp/pgsql_tmp1234.0", size 42180000 bytes`

3. **Cluster-Wide Temp Spill Forensics**:
   Query `pg_stat_database` to detect cumulative disk spills:
   ```sql
   SELECT
     datname,
     temp_files AS total_temp_files_created,
     pg_size_pretty(temp_bytes) AS total_temp_bytes_spilled
   FROM pg_stat_database
   WHERE datname = current_database();
   ```

---

### Tier 2: Maintenance WorkMem & Autovacuum TID Scaling

Autovacuum and DDL index builds (`CREATE INDEX CONCURRENTLY`, `ALTER TABLE`) operate under maintenance memory budgets:

1. **Maintenance Memory Sizing**:
   ```sql
   -- 1GB to 2GB for manual DDL maintenance and reindexing
   ALTER SYSTEM SET maintenance_work_mem = '1GB';

   -- 256MB to 512MB dedicated per autovacuum worker
   ALTER SYSTEM SET autovacuum_work_mem = '256MB';

   -- Enable up to 4 parallel maintenance workers for large index builds
   ALTER SYSTEM SET max_parallel_maintenance_workers = 4;
   SELECT pg_reload_conf();
   ```
   At `autovacuum_work_mem = 256MB`, each worker can hold up to $44,739,242$ dead tuple TIDs in a single pass, eliminating multi-pass index thrashing on large production tables.

---

### Tier 3: Transaction-Scoped Adaptive Allocation (`SET LOCAL work_mem`)

Analytical reporting queries, periodic aggregation cron jobs, and large batch migrations must never permanently mutate session-level or global memory parameters. They must elevate memory strictly within an explicit transaction boundary:

```sql
BEGIN;
  -- Elevate work_mem ONLY for this transaction
  SET LOCAL work_mem = '256MB';
  SET LOCAL hash_mem_multiplier = 2.0;

  -- Heavy analytical aggregation runs entirely in RAM
  SELECT 
    tenant_id,
    date_trunc('day', created_at) AS day,
    count(*),
    sum(amount_cents),
    avg(processing_time_ms)
  FROM transactions
  WHERE created_at >= NOW() - INTERVAL '30 days'
  GROUP BY tenant_id, date_trunc('day', created_at)
  ORDER BY sum(amount_cents) DESC;

COMMIT;
-- Upon COMMIT or ROLLBACK, work_mem immediately reverts to the 32MB global baseline!
```

---

### Tier 4: Continuous Buffer & Disk Spill CI Sentinel

Establish automated CI tests that execute `EXPLAIN (ANALYZE, BUFFERS)` on critical queries, asserting zero disk spills:

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT * FROM orders ORDER BY created_at DESC LIMIT 5000;
```

**JSON Output Inspection Gate**:
- `Plan.TempWrittenBlocks`: Must equal `0`.
- `Plan.TempReadBlocks`: Must equal `0`.
- `Plan.Sort.Sort Method`: Must match `quicksort` or `top-N heapsort`, NEVER `external merge`.
- `Plan.Hash.Hash Batches`: Must equal `1`.

---

## 4. Production TypeScript Verification Engine: `AgenticDatabaseMemoryEngine`

```typescript
import { Pool, PoolClient } from 'pg';

export interface MemoryConfigLimits {
  totalHostRamBytes: number;
  maxConnections: number;
  sharedBuffersBytes: number;
  maxParallelWorkersPerGather: number;
  targetMaxRamUsageRatio: number; // e.g. 0.80
}

export interface MemoryAuditResult {
  settings: {
    workMemBytes: number;
    sharedBuffersBytes: number;
    maintenanceWorkMemBytes: number;
    autovacuumWorkMemBytes: number;
    tempFileLimitBytes: number;
    logTempFiles: number;
    hashMemMultiplier: number;
  };
  worstCasePeakMemoryBytes: number;
  isOOMSafe: boolean;
  recommendedWorkMemBytes: number;
  violations: string[];
}

export interface QuerySpillAuditReport {
  query: string;
  executionTimeMs: number;
  tempWrittenBytes: number;
  tempReadBytes: number;
  hasDiskSpill: boolean;
  sortMethod?: string;
  hashBatches?: number;
  violations: string[];
}

export enum MemoryLifecycleState {
  AUDITING_HOST_MEMORY = 'AUDITING_HOST_MEMORY',
  CALCULATING_WORK_MEM_BUDGET = 'CALCULATING_WORK_MEM_BUDGET',
  CALIBRATING_STORAGE_FENCES = 'CALIBRATING_STORAGE_FENCES',
  INSPECTING_SPILL_TELEMETRY = 'INSPECTING_SPILL_TELEMETRY',
  ISOLATING_ANALYTIC_GUC = 'ISOLATING_ANALYTIC_GUC',
  VERIFYING_CI_EXPLAIN_BUFFERS = 'VERIFYING_CI_EXPLAIN_BUFFERS',
}

export class AgenticDatabaseMemoryEngine {
  private currentState: MemoryLifecycleState = MemoryLifecycleState.AUDITING_HOST_MEMORY;

  constructor(private pool: Pool) {}

  public getState(): MemoryLifecycleState {
    return this.currentState;
  }

  /**
   * Parses human memory string (e.g. '32MB', '1GB', '4096kB') into bytes.
   */
  public parseMemoryStringToBytes(value: string): number {
    const trimmed = value.trim().toUpperCase();
    const match = trimmed.match(/^(\d+(?:\.\d+)?)\s*([A-Z]*)$/);
    if (!match) return 0;

    const num = parseFloat(match[1]);
    const unit = match[2];

    switch (unit) {
      case 'KB':
      case 'K':
        return Math.floor(num * 1024);
      case 'MB':
      case 'M':
        return Math.floor(num * 1024 * 1024);
      case 'GB':
      case 'G':
        return Math.floor(num * 1024 * 1024 * 1024);
      case 'TB':
      case 'T':
        return Math.floor(num * 1024 * 1024 * 1024 * 1024);
      default:
        // Default in PostgreSQL pg_settings is usually 8kB pages or kB depending on context
        return Math.floor(num * 1024);
    }
  }

  /**
   * Calculates maximum mathematically safe work_mem to prevent Linux OOM kills.
   */
  public calculateSafeWorkMem(config: MemoryConfigLimits): number {
    const usableRam = config.totalHostRamBytes * config.targetMaxRamUsageRatio;
    const baseBackendMemory = config.maxConnections * (15 * 1024 * 1024); // 15MB base
    const vacuumMemory = 3 * (256 * 1024 * 1024); // 3 autovacuum workers at 256MB

    const availableWorkPool = usableRam - config.sharedBuffersBytes - baseBackendMemory - vacuumMemory;
    if (availableWorkPool <= 0) {
      return 4 * 1024 * 1024; // Fallback floor
    }

    // Assume average query has 3 memory-intensive nodes, parallel workers, and hash multiplier 2.0
    const queryConcurrencyMultiplier = config.maxConnections * 3 * (1 + config.maxParallelWorkersPerGather) * 2.0;
    const safeBytes = Math.floor(availableWorkPool / queryConcurrencyMultiplier);

    // Bound between 16MB and 128MB for general OLTP safety
    return Math.max(16 * 1024 * 1024, Math.min(safeBytes, 128 * 1024 * 1024));
  }

  /**
   * Audits live PostgreSQL memory configuration against safety invariants.
   */
  public async auditClusterMemorySettings(limits: MemoryConfigLimits): Promise<MemoryAuditResult> {
    this.currentState = MemoryLifecycleState.AUDITING_HOST_MEMORY;
    const client = await this.pool.connect();

    try {
      const res = await client.query(`
        SELECT name, setting, unit
        FROM pg_settings
        WHERE name IN (
          'work_mem',
          'shared_buffers',
          'maintenance_work_mem',
          'autovacuum_work_mem',
          'temp_file_limit',
          'log_temp_files',
          'hash_mem_multiplier'
        );
      `);

      const settingsMap = new Map<string, string>();
      for (const row of res.rows) {
        settingsMap.set(row.name, row.setting + (row.unit || ''));
      }

      const workMemBytes = this.parseMemoryStringToBytes(settingsMap.get('work_mem') || '4MB');
      const sharedBuffersBytes = this.parseMemoryStringToBytes(settingsMap.get('shared_buffers') || '128MB');
      const maintenanceWorkMemBytes = this.parseMemoryStringToBytes(settingsMap.get('maintenance_work_mem') || '64MB');
      const autovacuumWorkMemBytes = this.parseMemoryStringToBytes(settingsMap.get('autovacuum_work_mem') || '64MB');
      const tempFileLimitKb = parseInt(settingsMap.get('temp_file_limit') || '-1', 10);
      const tempFileLimitBytes = tempFileLimitKb === -1 ? -1 : tempFileLimitKb * 1024;
      const logTempFiles = parseInt(settingsMap.get('log_temp_files') || '-1', 10);
      const hashMemMultiplier = parseFloat(settingsMap.get('hash_mem_multiplier') || '1.0');

      this.currentState = MemoryLifecycleState.CALCULATING_WORK_MEM_BUDGET;
      const recommendedWorkMemBytes = this.calculateSafeWorkMem(limits);

      const worstCaseNodesPerQuery = 3;
      const parallelWorkers = limits.maxParallelWorkersPerGather;
      const totalConcurrentNodes = limits.maxConnections * worstCaseNodesPerQuery * (1 + parallelWorkers);
      const worstCaseWorkMemTotal = totalConcurrentNodes * workMemBytes * hashMemMultiplier;
      const worstCasePeakMemoryBytes = sharedBuffersBytes + worstCaseWorkMemTotal + (3 * autovacuumWorkMemBytes);

      const violations: string[] = [];
      const allowedBudget = limits.totalHostRamBytes * limits.targetMaxRamUsageRatio;

      if (worstCasePeakMemoryBytes > allowedBudget) {
        violations.push(
          `Worst-case peak memory (${(worstCasePeakMemoryBytes / (1024 ** 3)).toFixed(2)} GB) exceeds safe RAM budget (${(allowedBudget / (1024 ** 3)).toFixed(2)} GB). Risk of Linux OOM killer postmaster crash!`
        );
      }

      this.currentState = MemoryLifecycleState.CALIBRATING_STORAGE_FENCES;
      if (tempFileLimitBytes === -1) {
        violations.push('temp_file_limit is unlimited (-1). Single rogue query can fill 100% disk and crash engine.');
      }

      if (logTempFiles !== 0) {
        violations.push(`log_temp_files is ${logTempFiles}. Must be set to 0 to log all disk spills.`);
      }

      if (autovacuumWorkMemBytes < 128 * 1024 * 1024) {
        violations.push(
          `autovacuum_work_mem is ${(autovacuumWorkMemBytes / (1024 ** 2)).toFixed(0)}MB. Sized too low; causes multi-pass index vacuum thrashing.`
        );
      }

      return {
        settings: {
          workMemBytes,
          sharedBuffersBytes,
          maintenanceWorkMemBytes,
          autovacuumWorkMemBytes,
          tempFileLimitBytes,
          logTempFiles,
          hashMemMultiplier,
        },
        worstCasePeakMemoryBytes,
        isOOMSafe: violations.length === 0,
        recommendedWorkMemBytes,
        violations,
      };
    } finally {
      client.release();
    }
  }

  /**
   * Executes EXPLAIN (ANALYZE, BUFFERS) to verify zero temporary disk spills.
   */
  public async verifyQueryMemoryInvariance(sql: string, params: any[] = []): Promise<QuerySpillAuditReport> {
    this.currentState = MemoryLifecycleState.VERIFYING_CI_EXPLAIN_BUFFERS;
    const client = await this.pool.connect();

    try {
      const explainSQL = `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${sql}`;
      const res = await client.query(explainSQL, params);
      const rawPlan = res.rows[0]['QUERY PLAN'][0];

      let tempWrittenBlocks = 0;
      let tempReadBlocks = 0;
      let sortMethod: string | undefined;
      let hashBatches: number | undefined;
      const violations: string[] = [];

      const traverseNode = (node: any) => {
        if (node['Temp Written Blocks']) {
          tempWrittenBlocks += node['Temp Written Blocks'];
        }
        if (node['Temp Read Blocks']) {
          tempReadBlocks += node['Temp Read Blocks'];
        }
        if (node['Sort Method']) {
          sortMethod = node['Sort Method'];
          if (node['Sort Method'].toLowerCase().includes('external merge')) {
            violations.push(`Sort spilled to disk: Sort Method is ${node['Sort Method']}`);
          }
        }
        if (node['Hash Batches'] && node['Hash Batches'] > 1) {
          hashBatches = node['Hash Batches'];
          violations.push(`Hash Join spilled to disk: Hash Batches is ${node['Hash Batches']} (expected 1)`);
        }
        if (node.Plans) {
          for (const subPlan of node.Plans) {
            traverseNode(subPlan);
          }
        }
      };

      traverseNode(rawPlan.Plan);

      const tempWrittenBytes = tempWrittenBlocks * 8192;
      const tempReadBytes = tempReadBlocks * 8192;

      if (tempWrittenBytes > 0) {
        violations.push(`Disk spill detected: ${tempWrittenBytes} bytes written to temporary tablespace.`);
      }

      return {
        query: sql,
        executionTimeMs: rawPlan['Execution Time'] || 0,
        tempWrittenBytes,
        tempReadBytes,
        hasDiskSpill: tempWrittenBytes > 0 || violations.length > 0,
        sortMethod,
        hashBatches,
        violations,
      };
    } finally {
      client.release();
    }
  }

  /**
   * Executes an analytical routine inside a transaction-scoped elevated work_mem envelope.
   */
  public async executeWithAdaptiveWorkMem<T>(
    elevatedWorkMem: string,
    operation: (client: PoolClient) => Promise<T>
  ): Promise<T> {
    this.currentState = MemoryLifecycleState.ISOLATING_ANALYTIC_GUC;
    const client = await this.pool.connect();

    try {
      await client.query('BEGIN');
      // SET LOCAL guarantees parameter reset upon COMMIT or ROLLBACK
      await client.query(`SET LOCAL work_mem = $1`, [elevatedWorkMem]);
      await client.query(`SET LOCAL hash_mem_multiplier = 2.0`);

      const result = await operation(client);
      await client.query('COMMIT');
      return result;
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  }
}
```

---

## 5. Cross-Language Implementation Invariants

### 1. Go (`jackc/pgx/v5`) Implementation

```go
package store

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// AdaptiveWorkMemExecutor executes heavy analytical queries inside an isolated SET LOCAL work_mem transaction.
func ExecuteWithAdaptiveWorkMem[T any](
	ctx context.Context,
	pool *pgxpool.Pool,
	elevatedWorkMem string,
	fn func(tx pgx.Tx) (T, error),
) (T, error) {
	var zero T
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return zero, fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// SET LOCAL strictly scopes the elevated allocation to this transaction
	setSQL := fmt.Sprintf("SET LOCAL work_mem = '%s'", elevatedWorkMem)
	if _, err := tx.Exec(ctx, setSQL); err != nil {
		return zero, fmt.Errorf("set local work_mem: %w", err)
	}
	if _, err := tx.Exec(ctx, "SET LOCAL hash_mem_multiplier = 2.0"); err != nil {
		return zero, fmt.Errorf("set local hash_mem_multiplier: %w", err)
	}

	result, err := fn(tx)
	if err != nil {
		return zero, err
	}

	if err := tx.Commit(ctx); err != nil {
		return zero, fmt.Errorf("commit transaction: %w", err)
	}

	return result, nil
}

// MemorySpillAudit audits EXPLAIN (ANALYZE, BUFFERS) JSON output for disk spills.
type MemorySpillAudit struct {
	TempWrittenBytes int64    `json:"temp_written_bytes"`
	SortMethod       string   `json:"sort_method"`
	HasSpill         bool     `json:"has_spill"`
	Violations       []string `json:"violations"`
}

func AuditQueryMemorySpill(ctx context.Context, pool *pgxpool.Pool, query string, args ...any) (*MemorySpillAudit, error) {
	explainSQL := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s", query)
	var rawJSON []byte

	if err := pool.QueryRow(ctx, explainSQL, args...).Scan(&rawJSON); err != nil {
		return nil, fmt.Errorf("execute explain: %w", err)
	}

	var root []struct {
		Plan map[string]any `json:"Plan"`
	}
	if err := json.Unmarshal(rawJSON, &root); err != nil {
		return nil, fmt.Errorf("unmarshal plan: %w", err)
	}

	audit := &MemorySpillAudit{Violations: make([]string, 0)}
	inspectNode(root[0].Plan, audit)

	audit.HasSpill = audit.TempWrittenBytes > 0 || len(audit.Violations) > 0
	return audit, nil
}

func inspectNode(node map[string]any, audit *MemorySpillAudit) {
	if tempWritten, ok := node["Temp Written Blocks"].(float64); ok && tempWritten > 0 {
		audit.TempWrittenBytes += int64(tempWritten) * 8192
		audit.Violations = append(audit.Violations, fmt.Sprintf("Spilled %.0f blocks to disk temp files", tempWritten))
	}
	if method, ok := node["Sort Method"].(string); ok {
		audit.SortMethod = method
		if method != "quicksort" && method != "top-N heapsort" {
			audit.Violations = append(audit.Violations, fmt.Sprintf("Inefficient sort method: %s", method))
		}
	}
	if batches, ok := node["Hash Batches"].(float64); ok && batches > 1 {
		audit.Violations = append(audit.Violations, fmt.Sprintf("Multi-batch hash join: %.0f batches", batches))
	}
	if subPlans, ok := node["Plans"].([]any); ok {
		for _, sp := range subPlans {
			if subNode, valid := sp.(map[string]any); valid {
				inspectNode(subNode, audit)
			}
		}
	}
}
```

---

### 2. TypeScript (`Kysely` / `Drizzle`) Implementation

```typescript
import { sql } from 'kysely';

export async function runAnalyticalQueryWithMemoryEnvelope<T>(
  db: any,
  elevatedWorkMem: string,
  operation: (trx: any) => Promise<T>
): Promise<T> {
  return await db.transaction().execute(async (trx: any) => {
    // Elevate memory strictly inside transaction
    await sql`SET LOCAL work_mem = ${sql.raw(`'${elevatedWorkMem}'`)}`.execute(trx);
    await sql`SET LOCAL hash_mem_multiplier = 2.0`.execute(trx);

    return await operation(trx);
  });
}
```

---

### 3. Python (`psycopg3`) Implementation

```python
from contextlib import contextmanager
import psycopg

@contextmanager
def adaptive_work_mem(conn: psycopg.Connection, work_mem: str = "256MB"):
    """
    Context manager elevating work_mem strictly within an explicit transaction block.
    """
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("SET LOCAL work_mem = %s;", (work_mem,))
            cur.execute("SET LOCAL hash_mem_multiplier = 2.0;")
        yield conn
```

---

## 6. Machine-Verifiable 6-Gate Definition of Done (DoD) Matrix

| Gate | Verification Target | Machine Assertion Command | Passing Threshold |
| :--- | :--- | :--- | :--- |
| **Gate 1: Linux Host OOM Immunity** | Postmaster OOM killer protection | `cat /proc/$(head -n 1 /var/lib/postgresql/data/postmaster.pid)/oom_score_adj` | **Score == `-1000`** |
| **Gate 2: Storage Disk Space Fence** | Disk overflow boundary | `SHOW temp_file_limit;` | **`> 0` and `<= 20GB`** (never `-1`) |
| **Gate 3: Universal Spill Observability** | Zero-spill logging transparency | `SHOW log_temp_files;` | **Setting == `0`** |
| **Gate 4: Autovacuum Single-Pass Sizing** | Dead tuple TID array capacity | `SHOW autovacuum_work_mem;` | **`>= 256MB`** |
| **Gate 5: Zero CI Temporary Disk Spills** | Regression query buffers verification | `EXPLAIN (ANALYZE, BUFFERS) ...` | **`TempWrittenBlocks == 0`** |
| **Gate 6: Transaction-Scoped GUC Invariance**| Session leak prevention | Audit code for raw `SET work_mem` vs `SET LOCAL` | **100% `SET LOCAL` compliance** |

---

## 7. Operational Runbook & Disaster Recovery

### 1. Emergency Forensics: Identifying Temp-Spilling Rogue Queries

When disk I/O spikes or `pg_stat_database.temp_bytes` grows rapidly:

```sql
-- 1. Identify active queries currently generating high backend activity
SELECT
  pid,
  now() - query_start AS duration,
  state,
  wait_event_type,
  wait_event,
  query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY duration DESC;

-- 2. Inspect cumulative temporary disk file volume by database
SELECT
  datname,
  temp_files,
  pg_size_pretty(temp_bytes) AS temp_volume
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

### 2. Surgical Backend Cancellation

```sql
-- Gracefully cancel the rogue analytical query spilling gigabytes to disk
SELECT pg_cancel_backend(12345);

-- If backend ignores cancel within 5 seconds, terminate process
SELECT pg_terminate_backend(12345);
```

### 3. Immediate Storage Recovery & Temp File Cleanup

Temporary files in PostgreSQL are stored in `$PGDATA/base/pgsql_tmp/` and are automatically unlinked upon backend termination. If orphaned temporary files remain after an unexpected hard reboot:
```bash
# Check size of orphaned temporary files
du -sh /var/lib/postgresql/data/base/pgsql_tmp/

# Confirm no backend processes are running before unlinking orphaned files
systemctl stop postgresql
rm -rf /var/lib/postgresql/data/base/pgsql_tmp/*
systemctl start postgresql
```
