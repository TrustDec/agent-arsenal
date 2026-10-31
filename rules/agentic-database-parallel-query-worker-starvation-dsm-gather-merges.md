---
description: PostgreSQL parallel query execution invariants, background worker pool starvation defense (max_parallel_workers, max_parallel_workers_per_gather, max_worker_processes), silent runtime plan downgrades (Workers Planned vs Workers Launched 0), Dynamic Shared Memory (DSM) exhaustion (dsm_create out of memory), multi-worker work_mem multiplication (N * work_mem) OOM prevention, Gather and Gather Merge leader IPC serialization bottlenecks, parallel-safety function volatility fences (PARALLEL SAFE, RESTRICTED, UNSAFE), partial aggregation pushdown (Partial Aggregate vs full tuple streaming), worker skew & straggler mitigation across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, psycopg3), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{parallel,worker,gather,dsm,shm,analytics,aggregate,query,report,batch,olap,db,postgres}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/services/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Parallel Query Execution, Worker Starvation, Dynamic Shared Memory (DSM) Allocations, Gather Merges & Partial Aggregate Serialization Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design analytical query pipelines, massive reporting aggregations, batch processing scans, or read-heavy database architectures across PostgreSQL (9.6–17+) in Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Worker Pool Starvation & Silent Serial Plan Downgrade Cliff (`Workers Planned > Workers Launched: 0`)" (where queries planned for 4 parallel workers execute sequentially on a single leader core because concurrent traffic exhausted `max_parallel_workers`, blowing up latency by 10x–40x without error logs), the "Multiplied `work_mem` OOM-Killer Avalanche ($N \times \text{work\_mem}$)" (where each parallel worker allocates its own `work_mem` for hash joins and sorts, multiplying memory consumption across workers and triggering Linux kernel `SIGKILL` on the postmaster), the "Dynamic Shared Memory (DSM) Exhaustion & Segment Lockout (`dsm_create: out of memory` / `No space left on device`)" (where concurrent parallel queries exhaust `/dev/shm` tmpfs or internal DSM slots), the "Gather / Gather Merge Leader IPC Serialization Bottleneck (The 100% Core Pinning Trap)" (where parallel workers push millions of unaggregated tuples over `shm_mq`, pegging a single leader CPU core at 100% while workers sit idle), the "Parallel-Unsafe Function Volatility & Query Tree Poisoning" (where calling a single unannotated PL/pgSQL function or `VOLATILE` expression silently suppresses parallelism across the entire query tree), and the "Worker Skew & Straggler Latency Barrier" (where uneven physical page distribution or skewed join keys cause one worker to process 95% of rows while others idle at the synchronization barrier) by establishing a strict 5-Tier Parallel Query Governance Ladder, dynamic session-level `work_mem` scaling, partial aggregation pushdown invariants, automated worker starvation telemetry sentinels, and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Parallel Query Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL provides a sophisticated multi-process parallel execution engine capable of parallelizing sequential scans, index scans, bitmap heap scans, hash joins, nested loops, merges, and aggregations across multiple CPU cores. Parallelism is coordinated through **Dynamic Shared Memory (DSM)** segments and shared-memory message queues (`shm_mq`), supervised by background worker processes registered with the postmaster.

When the PostgreSQL query optimizer determines that a parallel scan is cheaper than a serial scan, it generates a query plan containing a `Gather` or `Gather Merge` node. The planner decides how many background workers to request based on table size (`min_parallel_table_scan_size`) and the parameter `max_parallel_workers_per_gather`.

However, the transition from single-threaded relational operations to parallel multi-process execution introduces profound operational and resource constraints. When autonomous coding agents write complex reporting queries or configure database instances, LLMs consistently stumble into 6 catastrophic failure modes:

### The 6 Parallel Query Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                               THE 6 PARALLEL QUERY CATASTROPHES                                    |
+------------------------------------+---------------------------------------------------------------+
| 1. Worker Starvation & Silent Plan | Query planned for 4 workers; runtime worker pool is saturated;|
|    Downgrade (Workers Launched: 0) | PostgreSQL silently launches 0 workers; single leader core    |
|                                    | runs multi-GB scan; 200ms query stalls for 45s (504 timeout). |
+------------------------------------+---------------------------------------------------------------+
| 2. Multiplied work_mem OOM-Killer  | Agent sets work_mem = 512MB for large hash join; 4 workers    |
|    Avalanche (N * work_mem)        | each allocate 512MB; single query claims 2.5GB RAM; 5 queries |
|                                    | trigger Linux kernel OOM killer (SIGKILL postmaster).         |
+------------------------------------+---------------------------------------------------------------+
| 3. Dynamic Shared Memory (DSM)     | High query concurrency exhausts /dev/shm tmpfs or kernel IPC  |
|    Exhaustion & Segment Lockout    | segment limits; queries fail with "dsm_create: out of memory"|
|                                    | or "could not resize shared memory segment: No space left".   |
+------------------------------------+---------------------------------------------------------------+
| 4. Gather Leader Serialization     | Query streams millions of raw tuples across Gather node;      |
|    Bottleneck (100% Core Pinning)  | leader backend pegs 1 CPU core at 100% de-serializing IPC     |
|                                    | tuples; workers idle; negative scaling compared to index seek.|
+------------------------------------+---------------------------------------------------------------+
| 5. Parallel-Unsafe Function & CTE  | Calling a single unannotated PL/pgSQL function (defaults to   |
|    Query Tree Poisoning            | VOLATILE) or referencing nextval() poisons the entire plan;   |
|                                    | planner silently suppresses all parallel scans and joins.     |
+------------------------------------+---------------------------------------------------------------+
| 6. Worker Skew & Straggler Barrier | Clustered MVCC dead tuples or skewed hash keys concentrate    |
|    (The 95% Worker Stall)          | 95% of tuples on 1 worker; sibling workers finish in 20ms and |
|                                    | stall at ExecParallelFinish barrier; total runtime unreduced. |
+------------------------------------+---------------------------------------------------------------+
```

To eliminate these failure modes across enterprise production environments, autonomous agents must adhere to the **5-Tier Parallel Query Governance Ladder**:

```
+----------------------------------------------------------------------------------------------------+
|                               THE 5-TIER PARALLEL QUERY GOVERNANCE LADDER                          |
+------------------------------------+---------------------------------------------------------------+
| Tier 0: Worker Capacity Calculus   | Calibrate max_worker_processes, max_parallel_workers, and     |
|         & Hardware Invariants      | max_parallel_workers_per_gather based on available CPU cores;  |
|                                    | ensure OLTP queries do not trigger wasteful parallel setups.  |
+------------------------------------+---------------------------------------------------------------+
| Tier 1: Aggregate Pushdown &       | Strictly push down aggregations into Partial Aggregate nodes;  |
|         Tuple Volume Invariant     | enforce Gather nodes to transmit condensed partial aggregates |
|                                    | (< 10,000 rows), never raw unaggregated tuple streams.        |
+------------------------------------+---------------------------------------------------------------+
| Tier 2: Dynamic work_mem Budget    | Compute session-level work_mem dynamically:                   |
|         Fencing                    | work_mem_session = min(work_mem, work_mem_budget / (W + 1));  |
|                                    | prevent multi-worker memory multiplication OOM cascades.      |
+------------------------------------+---------------------------------------------------------------+
| Tier 3: Strict Parallel-Safety     | Verify PARALLEL SAFE annotations across all referenced        |
|         Volatility Auditing        | functions, operators, and expressions; isolate unsafe steps   |
|                                    | into distinct non-parallel CTEs or temporary tables.          |
+------------------------------------+---------------------------------------------------------------+
| Tier 4: Autonomous Telemetry &     | Monitor Workers Planned vs Workers Launched drift; alert on  |
|         Worker Starvation Sentinel | worker starvation rate > 5%; monitor /dev/shm DSM allocation  |
|                                    | saturation and auto_explain execution plan regressions.       |
+------------------------------------+---------------------------------------------------------------+
```

---

## 2. The 6 Parallel Query Failure Modes & Root-Cause Analysis

### Catastrophe 1: Worker Pool Starvation & Silent Serial Plan Downgrade (`Workers Launched: 0`)

```sql
-- ❌ CATASTROPHIC ANTI-PATTERN: Silent Parallel Plan Downgrade Under Concurrency
-- Staging Test (Single User):
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, SUM(amount), COUNT(*)
FROM transactions
WHERE transaction_date >= '2025-01-01'
GROUP BY customer_id;

-- In staging, planner allocates 4 workers:
-- -> Finalize GroupAggregate (cost=14520.12..14580.45 rows=12000 width=24)
--      -> Gather Merge (cost=14520.12..14550.23 rows=48000 width=24)
--           Workers Planned: 4
--           Workers Launched: 4
--           -> Partial GroupAggregate (cost=13520.12..13540.00 ...)
--                -> Sort ...
--                     -> Parallel Seq Scan on transactions (actual time=0.082..124.521 rows=2500000 ...)
-- Total Execution Time: 340.125 ms. Agent declares query "fast & optimized".

-- 💥 What Happens in Production Under Concurrency:
-- The database has max_parallel_workers = 8 and max_worker_processes = 16.
-- Two other analytical queries or background vacuum workers are running, occupying all 8 slots.
-- When our query executes:
-- PostgreSQL checks if workers are available in the background worker pool.
-- 0 workers are available!
-- PostgreSQL does NOT wait, does NOT return a retryable error, and does NOT re-plan.
-- It executes the Parallel Seq Scan using ONLY THE LEADER PROCESS:
-- Workers Planned: 4
-- Workers Launched: 0
-- The leader process sequentially scans 10,000,000 rows across 8GB of disk blocks alone!
-- Execution Time explodes from 340ms -> 38,450ms (38.4 seconds)!
-- Upstream reverse proxy (Nginx / ALB) times out with 504 Gateway Timeout.
```

### Catastrophe 2: Multiplied `work_mem` OOM-Killer Avalanche ($N \times \text{work\_mem}$)

```sql
-- ❌ CATASTROPHIC ANTI-PATTERN: Unbounded work_mem Setting for Parallel Hash Joins
-- Agent notices an external sort/hash spill to disk in EXPLAIN output:
-- "Sort Method: external merge  Disk: 18432kB"
-- Agent naively attempts to eliminate disk spills by increasing work_mem:
ALTER DATABASE production_db SET work_mem = '512MB';

-- Query contains a Parallel Hash Join and a Parallel Sort:
EXPLAIN (ANALYZE)
SELECT t.tenant_id, o.order_id, sum(oi.quantity * oi.price)
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
JOIN tenants t ON o.tenant_id = t.tenant_id
WHERE o.created_at >= '2025-01-01'
GROUP BY t.tenant_id, o.order_id;

-- 💥 Why This Causes Instant Database Cluster Crashes:
-- In a non-parallel query, work_mem is allocated per sort/hash operation (e.g. 512MB).
-- In a parallel query with max_parallel_workers_per_gather = 4:
-- 1. Each of the 4 workers allocates up to 512MB for its private Hash Join table: 4 * 512MB = 2048MB.
-- 2. Each of the 4 workers allocates up to 512MB for its private Partial Sort: 4 * 512MB = 2048MB.
-- 3. The leader process allocates up to 512MB for the Finalize Sort: 512MB.
-- Total memory required by this SINGLE query:
-- M_query = (4 * 512MB) + (4 * 512MB) + 512MB = 4,608MB (4.5GB)!
--
-- If 4 API requests execute this endpoint concurrently:
-- Total RAM demanded = 4 * 4.5GB = 18GB of active dynamic memory!
-- If the server has 16GB of RAM, Linux kernel invokes the Out-Of-Memory (OOM) Killer:
-- [dmesg]: Out of memory: Kill process 14205 (postgres: postmaster) score 852 or sacrifice child.
-- Postmaster receives SIGKILL. All connections terminate immediately.
-- Database enters crash recovery (WAL replay on startup), taking 15 minutes to come back online!
```

### Catastrophe 3: Dynamic Shared Memory (DSM) Exhaustion & Segment Lockout

```sql
-- ❌ CATASTROPHIC ANTI-PATTERN: Saturated /dev/shm Shared Memory
-- In containerized environments (Kubernetes, Docker), /dev/shm defaults to 64MB unless overridden!
-- When PostgreSQL starts parallel query workers:
-- 1. Leader allocates DSM segment via posix shm_open().
-- 2. Message queues (shm_mq) and tuple buffers are mapped into the DSM segment.
-- 3. If multiple parallel queries run simultaneously in Kubernetes pods with default 64MB /dev/shm:
--
-- 💥 Catastrophic Failure:
-- ERROR: could not resize shared memory segment "/PostgreSQL.1829401": No space left on device
-- or:
-- ERROR: dsm_create: out of memory
--
-- Transactions abort immediately with SQLSTATE 53100 (out_of_memory) or 53200 (too_many_buffers).
```

### Catastrophe 4: Gather Leader IPC Serialization Bottleneck (100% Core Pinning)

```sql
-- ❌ CATASTROPHIC ANTI-PATTERN: Streaming Massive Unaggregated Rows Over Gather
EXPLAIN (ANALYZE)
SELECT id, payload, event_type, created_at
FROM event_stream
WHERE created_at >= NOW() - INTERVAL '7 days';

-- Plan:
-- -> Gather (cost=1000.00..892400.00 rows=5000000 width=180)
--      Workers Planned: 4
--      Workers Launched: 4
--      -> Parallel Seq Scan on event_stream (cost=0.00..391400.00 rows=1250000 width=180)

-- 💥 What Happens Under the Hood:
-- 4 background workers read 5,000,000 rows (totaling 900MB of data) from disk/OS cache.
-- Each worker writes serialized binary tuples into its private shm_mq queue.
-- The SINGLE leader backend process must:
--   1. Poll 4 shm_mq message queues in round-robin fashion.
--   2. De-serialize every tuple from shared memory into private backend memory.
--   3. Form virtual tuples and format them for the client wire protocol.
--   4. Push packets across the TCP socket to the client.
--
-- Result:
-- The leader process CPU core runs at 100% utilization.
-- The 4 worker processes frequently block on `shm_mq_send: wait for queue free`.
-- Total execution time is SLOWER than a single-threaded index scan, burning 5 CPU cores for zero gain!
```

### Catastrophe 5: Parallel-Unsafe Function Volatility & Query Tree Poisoning

```sql
-- ❌ CATASTROPHIC ANTI-PATTERN: Unannotated PL/pgSQL Function Disables Parallelism
CREATE OR REPLACE FUNCTION calculate_risk_score(amount numeric, country text)
RETURNS numeric AS $$
BEGIN
    IF country = 'US' THEN
        RETURN amount * 0.05;
    ELSE
        RETURN amount * 0.12;
    END IF;
END;
$$ LANGUAGE plpgsql;
-- Note: Function does NOT specify PARALLEL SAFE, STABLE, or IMMUTABLE!
-- In PostgreSQL, functions default to VOLATILE and PARALLEL UNSAFE!

-- Query using the function:
EXPLAIN (ANALYZE)
SELECT customer_id, sum(calculate_risk_score(amount, country))
FROM transactions
WHERE transaction_date >= '2025-01-01'
GROUP BY customer_id;

-- 💥 Catastrophic Result:
-- Because calculate_risk_score() is PARALLEL UNSAFE, the planner REFUSES to parallelize the query:
-- -> HashAggregate (cost=854200.00..892400.00 rows=250000 width=40)
--      -> Seq Scan on transactions (cost=0.00..654200.00 rows=10000000 width=28)
--
-- A 10,000,000-row table scan on a 64-core server runs on ONE single CPU core!
-- Execution time: 24.8 seconds instead of 1.2 seconds!
```

---

## 3. Mathematical Models: Parallel Speedup, Memory Scaling & Straggler Latency

### 1. Extended Amdahl's Law for PostgreSQL Parallel Query Execution

In a database engine, the theoretical speedup $S(W)$ of a query utilizing $W$ parallel workers is bounded by sequential setup overhead, Dynamic Shared Memory allocation, and leader process Gather deserialization.

Let:
- $T_{\text{serial}}$ be the baseline single-threaded execution time.
- $f_p \in [0, 1]$ be the parallelizable fraction of the query (e.g. table scan, filter, partial aggregation).
- $f_s = 1 - f_p$ be the strictly serial fraction (e.g. final sort, client socket streaming).
- $T_{\text{setup}}$ be the fixed cost of postmaster background worker signaling and DSM segment creation ($\approx 1\text{ms} - 5\text{ms}$).
- $C_{\text{ipc}}$ be the IPC serialization cost per tuple streamed across shared memory queues ($\approx 0.08\mu\text{s} - 0.25\mu\text{s}$ per tuple).
- $N_{\text{tuples}}$ be the number of rows transmitted through the `Gather` node.

The execution time with $W$ workers is modeled as:

$$T(W) = T_{\text{setup}} + f_s T_{\text{serial}} + \frac{f_p T_{\text{serial}}}{W} + \left( N_{\text{tuples}} \times C_{\text{ipc}} \right)$$

The resulting speedup $S(W) = \frac{T_{\text{serial}}}{T(W)}$ yields:

$$S(W) = \frac{T_{\text{serial}}}{T_{\text{setup}} + (1 - f_p)T_{\text{serial}} + \frac{f_p T_{\text{serial}}}{W} + N_{\text{tuples}} C_{\text{ipc}}}$$

#### Key Architectural Takeaways:
1. **The IPC Death Threshold**: If $N_{\text{tuples}}$ is large (millions of unaggregated rows), $N_{\text{tuples}} C_{\text{ipc}} \gg \frac{f_p T_{\text{serial}}}{W}$. In this regime, adding more workers **decreases** performance due to lock contention on shared memory message queues.
2. **Partial Aggregation is Mandatory**: By pushing aggregation into `Partial Aggregate`, $N_{\text{tuples}}$ is reduced by a factor of 1,000x to 100,000x, rendering $N_{\text{tuples}} C_{\text{ipc}} \approx 0$ and enabling near-linear speedup with $W \le 8$.

---

### 2. Multi-Worker Memory Consumption Calculus

The total working memory allocated during a parallel query execution tree containing $K$ hash/sort operations with $W$ active workers is bounded by:

$$M_{\text{total}} = \sum_{k=1}^{K} \left( M_{\text{leader}, k} + \sum_{i=1}^{W} M_{\text{worker}, i, k} \right) \le K \cdot (W + 1) \cdot \text{work\_mem}$$

For $C_{\text{concurrent}}$ concurrent parallel queries running simultaneously:

$$M_{\text{cluster\_peak}} = \sum_{j=1}^{C_{\text{concurrent}}} K_j \cdot (W_j + 1) \cdot \text{work\_mem}_j$$

#### Production Invariant:
To prevent Linux kernel OOM-killer invocations, total dynamic query memory must never exceed available physical RAM minus OS and PostgreSQL shared buffers:

$$M_{\text{cluster\_peak}} \le \text{RAM}_{\text{total}} - \text{shared\_buffers} - \text{OS\_reserved}$$

---

### 3. Worker Straggler Effect & Skew Distribution

When tuples are partitioned across $W$ workers, ideal load balancing assigns $\frac{N}{W}$ tuples per worker. However, in the presence of physical page clustering or skewed join keys, the number of tuples processed by worker $i$ follows a skewed distribution with max tuple count $N_{\max} = \max_{i} (N_i)$.

Because the `Gather` or `Gather Merge` synchronization barrier (`ExecParallelFinish`) must wait for the slowest worker:

$$T_{\text{parallel\_actual}} = \max_{i \in [1, W]} \left( T_{\text{worker}, i} \right) \approx \frac{N_{\max}}{R_{\text{scan}}}$$

If key skew causes 1 worker to receive $N_{\max} = 0.85 N$ tuples:

$$S_{\text{skewed}}(W) \approx \frac{T_{\text{serial}}}{0.85 T_{\text{serial}}} \approx 1.17$$

The parallel query achieves only a **1.17x speedup regardless of whether $W = 4, 8, \text{ or } 16$!**

---

## 4. Production-Ready TypeScript Engine: `AgenticDatabaseParallelQueryGuardEngine`

The following TypeScript engine provides full-lifecycle validation, plan analysis, dynamic session memory budgeting, and worker starvation sentinels for PostgreSQL queries.

```typescript
/**
 * Agentic Database Parallel Query Guard Engine
 *
 * Implements strict 5-Tier governance for PostgreSQL parallel query execution:
 * - Worker allocation calculus & hardware constraint checks
 * - Plan inspection (Workers Planned vs Workers Launched detection)
 * - Dynamic session-level work_mem budgeting to prevent OOM
 * - Partial aggregation pushdown validation
 * - Dynamic Shared Memory (DSM) sizing invariants
 */

export interface SystemHardwareSpecs {
  totalCpuCores: number;
  totalRamBytes: number;
  sharedBuffersBytes: number;
  osReservedBytes: number;
  shmTotalBytes: number; // /dev/shm tmpfs size
}

export interface ParallelConfigOptions {
  maxWorkerProcesses: number;
  maxParallelWorkers: number;
  maxParallelWorkersPerGather: number;
  minParallelTableScanSizeKb: number;
  workMemKb: number;
}

export interface ExplainPlanNode {
  'Node Type': string;
  'Workers Planned'?: number;
  'Workers Launched'?: number;
  'Single Copy'?: boolean;
  'Plans'?: ExplainPlanNode[];
  'Actual Rows'?: number;
  'Plan Rows'?: number;
  'Sort Method'?: string;
  'Sort Space Used'?: number;
  'Sort Space Type'?: string;
  'Hash Batches'?: number;
  'Hash Buckets'?: number;
  'Peak Memory Usage'?: number;
  [key: string]: any;
}

export interface QueryAnalysisResult {
  isSafeForProduction: boolean;
  plannedWorkers: number;
  launchedWorkers: number;
  isStarved: boolean;
  hasMultipliedMemoryOomRisk: boolean;
  recommendedSessionWorkMemKb: number;
  hasIpcGatherBottleneck: boolean;
  hasParallelUnsafePoisoning: boolean;
  violations: string[];
  remediationSql: string[];
}

export class AgenticDatabaseParallelQueryGuardEngine {
  private readonly specs: SystemHardwareSpecs;
  private readonly config: ParallelConfigOptions;

  constructor(specs: SystemHardwareSpecs, config: ParallelConfigOptions) {
    this.specs = specs;
    this.config = config;
    this.validateSystemConfiguration();
  }

  /**
   * Tier 0: Validate hardware alignment and DSM configuration
   */
  public validateSystemConfiguration(): { isValid: boolean; warnings: string[] } {
    const warnings: string[] = [];

    // Rule 1: DSM size (/dev/shm) must be at least 25% of RAM or 1GB
    const minRecommendedShm = Math.min(1024 * 1024 * 1024, this.specs.totalRamBytes * 0.25);
    if (this.specs.shmTotalBytes < minRecommendedShm) {
      warnings.push(
        `CRITICAL: /dev/shm size (${(this.specs.shmTotalBytes / (1024 * 1024)).toFixed(1)}MB) is below ` +
        `safe threshold (${(minRecommendedShm / (1024 * 1024)).toFixed(1)}MB). ` +
        `Parallel queries risk "dsm_create: out of memory" or "No space left on device" crashes.`
      );
    }

    // Rule 2: max_parallel_workers_per_gather should not exceed half of CPU cores
    const safeWorkersPerGather = Math.max(1, Math.floor(this.specs.totalCpuCores / 2));
    if (this.config.maxParallelWorkersPerGather > safeWorkersPerGather) {
      warnings.push(
        `WARNING: max_parallel_workers_per_gather (${this.config.maxParallelWorkersPerGather}) ` +
        `exceeds recommended core budget (${safeWorkersPerGather}). High risk of CPU thrashing.`
      );
    }

    // Rule 3: max_parallel_workers must not exceed max_worker_processes
    if (this.config.maxParallelWorkers > this.config.maxWorkerProcesses) {
      warnings.push(
        `CONFIGURATION ERROR: max_parallel_workers (${this.config.maxParallelWorkers}) ` +
        `is greater than max_worker_processes (${this.config.maxWorkerProcesses}). Workers will fail to launch.`
      );
    }

    return { isValid: warnings.length === 0, warnings };
  }

  /**
   * Tier 2: Calculate safe dynamic session-level work_mem
   */
  public calculateSafeSessionWorkMemKb(
    estimatedConcurrentParallelQueries: number,
    workersForQuery?: number
  ): number {
    const workers = workersForQuery ?? this.config.maxParallelWorkersPerGather;
    const availableDynamicRamBytes =
      this.specs.totalRamBytes - this.specs.sharedBuffersBytes - this.specs.osReservedBytes;

    if (availableDynamicRamBytes <= 0) {
      return 64 * 1024; // Safe fallback: 64MB
    }

    const availableDynamicRamKb = Math.floor(availableDynamicRamBytes / 1024);
    // Budget 60% of available dynamic RAM for concurrent parallel operations
    const totalParallelPoolKb = Math.floor(availableDynamicRamKb * 0.6);

    const memoryPerQueryKb = Math.floor(totalParallelPoolKb / Math.max(1, estimatedConcurrentParallelQueries));
    // Each query distributes memory across (workers + 1) processes
    const safeWorkerMemKb = Math.floor(memoryPerQueryKb / (workers + 1));

    // Cap between 16MB and 256MB
    return Math.max(16 * 1024, Math.min(256 * 1024, safeWorkerMemKb));
  }

  /**
   * Tier 1 & Tier 4: Analyze EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) output
   */
  public analyzeExplainPlan(planRoot: ExplainPlanNode): QueryAnalysisResult {
    const violations: string[] = [];
    const remediationSql: string[] = [];

    let plannedWorkers = 0;
    let launchedWorkers = 0;
    let hasGatherNode = false;
    let gatherActualRows = 0;
    let isStarved = false;
    let hasPartialAggregate = false;
    let parallelWorkMemOperations = 0;

    const traverse = (node: ExplainPlanNode) => {
      const nodeType = node['Node Type'] || '';

      if (nodeType === 'Gather' || nodeType === 'Gather Merge') {
        hasGatherNode = true;
        plannedWorkers = Math.max(plannedWorkers, node['Workers Planned'] ?? 0);
        launchedWorkers = Math.max(launchedWorkers, node['Workers Launched'] ?? 0);
        gatherActualRows = Math.max(gatherActualRows, node['Actual Rows'] ?? 0);

        if (plannedWorkers > 0 && launchedWorkers === 0) {
          isStarved = true;
          violations.push(
            `WORKER STARVATION: Query planned for ${plannedWorkers} workers, but 0 workers were launched! ` +
            `PostgreSQL silently degraded execution to a single-threaded leader scan.`
          );
          remediationSql.push(
            `-- Check active background workers in pg_stat_activity:`,
            `SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'parallel worker';`,
            `-- Consider increasing max_parallel_workers if host CPU capacity allows.`
          );
        }
      }

      if (nodeType.startsWith('Partial') && (nodeType.includes('Aggregate') || nodeType.includes('Group'))) {
        hasPartialAggregate = true;
      }

      // Check for memory-intensive parallel operations
      if (nodeType.includes('Hash') || nodeType.includes('Sort')) {
        parallelWorkMemOperations++;
      }

      if (node.Plans && Array.isArray(node.Plans)) {
        for (const child of node.Plans) {
          traverse(child);
        }
      }
    };

    traverse(planRoot);

    // Tier 1 Check: IPC Gather Bottleneck
    const hasIpcGatherBottleneck = hasGatherNode && !hasPartialAggregate && gatherActualRows > 50000;
    if (hasIpcGatherBottleneck) {
      violations.push(
        `IPC SERIALIZATION BOTTLENECK: Gather node transmitted ${gatherActualRows.toLocaleString()} unaggregated ` +
        `rows to the leader process. Pushing raw rows across shared memory message queues pins leader CPU to 100%.`
      );
      remediationSql.push(
        `-- Push down filtering and grouping to enable Partial Aggregate:`,
        `-- Ensure aggregate functions are marked PARALLEL SAFE so workers pre-aggregate locally.`
      );
    }

    // Tier 2 Check: Multiplied work_mem risk
    const effectiveWorkers = launchedWorkers > 0 ? launchedWorkers : plannedWorkers;
    const totalPotentialMemKb = parallelWorkMemOperations * (effectiveWorkers + 1) * this.config.workMemKb;
    const maxSafeQueryMemKb = Math.floor((this.specs.totalRamBytes * 0.2) / 1024);
    const hasMultipliedMemoryOomRisk = totalPotentialMemKb > maxSafeQueryMemKb;

    if (hasMultipliedMemoryOomRisk) {
      violations.push(
        `OOM KILLER RISK: Parallel query has ${parallelWorkMemOperations} sort/hash operations across ` +
        `${effectiveWorkers} workers with work_mem = ${(this.config.workMemKb / 1024).toFixed(0)}MB. ` +
        `Peak query memory could reach ${(totalPotentialMemKb / 1024).toFixed(0)}MB (safe ceiling: ${(maxSafeQueryMemKb / 1024).toFixed(0)}MB).`
      );
      const safeSessionMem = this.calculateSafeSessionWorkMemKb(4, effectiveWorkers);
      remediationSql.push(
        `-- Apply dynamic session-level work_mem before executing heavy parallel query:`,
        `SET LOCAL work_mem = '${safeSessionMem}kB';`
      );
    }

    const recommendedSessionWorkMemKb = this.calculateSafeSessionWorkMemKb(4, effectiveWorkers);

    return {
      isSafeForProduction: violations.length === 0,
      plannedWorkers,
      launchedWorkers,
      isStarved,
      hasMultipliedMemoryOomRisk,
      recommendedSessionWorkMemKb,
      hasIpcGatherBottleneck,
      hasParallelUnsafePoisoning: false,
      violations,
      remediationSql,
    };
  }
}
```

---

## 5. Production Implementations Across Runtimes

### Go (`jackc/pgx/v5`): Safe Parallel Analytical Execution with Worker Starvation Circuit Breaker

```go
package analytics

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ParallelExecutionGuard coordinates safe parallel queries on PostgreSQL
type ParallelExecutionGuard struct {
	pool               *pgxpool.Pool
	logger             *slog.Logger
	maxWorkersPerQuery int
	safeSessionWorkMem string
}

func NewParallelExecutionGuard(pool *pgxpool.Pool, logger *slog.Logger, maxWorkers int, sessionWorkMem string) *ParallelExecutionGuard {
	if maxWorkers <= 0 {
		maxWorkers = 4
	}
	if sessionWorkMem == "" {
		sessionWorkMem = "64MB"
	}
	return &ParallelExecutionGuard{
		pool:               pool,
		logger:             logger,
		maxWorkersPerQuery: maxWorkers,
		safeSessionWorkMem: sessionWorkMem,
	}
}

type ExplainNode struct {
	NodeType        string        `json:"Node Type"`
	WorkersPlanned  *int          `json:"Workers Planned,omitempty"`
	WorkersLaunched *int          `json:"Workers Launched,omitempty"`
	ActualRows      *int          `json:"Actual Rows,omitempty"`
	Plans           []ExplainNode `json:"Plans,omitempty"`
}

type ExplainContainer struct {
	Plan ExplainNode `json:"Plan"`
}

// ExecuteAnalyticalQuery runs an intensive aggregation query inside a protected transaction with calibrated work_mem
func (g *ParallelExecutionGuard) ExecuteAnalyticalQuery(ctx context.Context, sqlQuery string, args ...any) (pgx.Rows, func(), error) {
	conn, err := g.pool.Acquire(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to acquire connection from pool: %w", err)
	}

	tx, err := conn.BeginTx(ctx, pgx.TxOptions{
		IsoLevel:   pgx.ReadCommitted,
		AccessMode: pgx.ReadOnly,
	})
	if err != nil {
		conn.Release()
		return nil, nil, fmt.Errorf("failed to start readonly analytical transaction: %w", err)
	}

	cleanup := func() {
		_ = tx.Rollback(ctx)
		conn.Release()
	}

	// Tier 2: Enforce strict bounded session work_mem and worker limits within the transaction
	cfgCmds := []string{
		fmt.Sprintf("SET LOCAL max_parallel_workers_per_gather = %d;", g.maxWorkersPerQuery),
		fmt.Sprintf("SET LOCAL work_mem = '%s';", g.safeSessionWorkMem),
		"SET LOCAL statement_timeout = '30s';",
	}

	for _, cmd := range cfgCmds {
		if _, err := tx.Exec(ctx, cmd); err != nil {
			cleanup()
			return nil, nil, fmt.Errorf("failed to set local parallel governance parameters: %w", err)
		}
	}

	// Verify plan and worker allocation using EXPLAIN
	explainSQL := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s", sqlQuery)
	var explainRaw []byte
	err = tx.QueryRow(ctx, explainSQL, args...).Scan(&explainRaw)
	if err != nil {
		cleanup()
		return nil, nil, fmt.Errorf("explain validation failed: %w", err)
	}

	var containers []ExplainContainer
	if err := json.Unmarshal(explainRaw, &containers); err == nil && len(containers) > 0 {
		g.inspectPlanWorkers(containers[0].Plan)
	}

	// Execute actual query within same transaction context
	rows, err := tx.Query(ctx, sqlQuery, args...)
	if err != nil {
		cleanup()
		return nil, nil, fmt.Errorf("parallel query execution failed: %w", err)
	}

	return rows, cleanup, nil
}

func (g *ParallelExecutionGuard) inspectPlanWorkers(node ExplainNode) {
	if (node.NodeType == "Gather" || node.NodeType == "Gather Merge") && node.WorkersPlanned != nil {
		planned := *node.WorkersPlanned
		launched := 0
		if node.WorkersLaunched != nil {
			launched = *node.WorkersLaunched
		}

		if planned > 0 && launched == 0 {
			g.logger.Warn("PARALLEL WORKER STARVATION DETECTED: Silent plan downgrade to serial scan",
				slog.Int("workers_planned", planned),
				slog.Int("workers_launched", launched),
				slog.String("hint", "Background worker pool saturated. Check max_parallel_workers."),
			)
		} else if launched < planned {
			g.logger.Info("Partial worker starvation",
				slog.Int("workers_planned", planned),
				slog.Int("workers_launched", launched),
			)
		}
	}

	for _, child := range node.Plans {
		g.inspectPlanWorkers(child)
	}
}
```

---

### TypeScript (`pg` / `kysely` / `drizzle-orm`): Dynamic `SET LOCAL` Analytical Worker Runner

```typescript
import { Pool, PoolClient } from 'pg';

export interface ParallelQueryOptions {
  maxWorkers?: number;
  workMemMb?: number;
  statementTimeoutMs?: number;
}

export class SafeParallelQueryRunner {
  private readonly pool: Pool;

  constructor(pool: Pool) {
    this.pool = pool;
  }

  /**
   * Executes a heavy parallel reporting query with strict resource isolation
   */
  public async executeReportingQuery<T = any>(
    queryText: string,
    params: any[] = [],
    options: ParallelQueryOptions = {}
  ): Promise<T[]> {
    const maxWorkers = options.maxWorkers ?? 4;
    const workMemMb = options.workMemMb ?? 64;
    const timeoutMs = options.statementTimeoutMs ?? 30000;

    const client: PoolClient = await this.pool.connect();

    try {
      // Must be wrapped in a transaction so SET LOCAL resets automatically upon COMMIT/ROLLBACK
      await client.query('BEGIN READ ONLY');

      // Tier 0 & Tier 2: Strict isolation using SET LOCAL
      await client.query(`SET LOCAL max_parallel_workers_per_gather = $1`, [maxWorkers]);
      await client.query(`SET LOCAL work_mem = $1`, [`${workMemMb}MB`]);
      await client.query(`SET LOCAL statement_timeout = $1`, [`${timeoutMs}ms`]);

      const startTime = performance.now();
      const result = await client.query(queryText, params);
      const durationMs = performance.now() - startTime;

      if (durationMs > 5000) {
        console.warn(`[ParallelQueryRunner] Slow parallel query took ${durationMs.toFixed(0)}ms: ${queryText.slice(0, 100)}...`);
      }

      await client.query('COMMIT');
      return result.rows;
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

### Python (`asyncpg`): Worker Starvation & DSM Telemetry Sentinel

```python
import asyncio
import json
import logging
from typing import Any, Dict, List, Optional
import asyncpg

logger = logging.getLogger("agentic_database_parallel")

class ParallelQuerySupervisor:
    """
    Supervises PostgreSQL parallel query execution under asyncpg:
    - Bounded session memory budgeting via SET LOCAL
    - Workers Planned vs Workers Launched drift detection
    - Real-time background worker pool telemetry
    """

    def __init__(self, pool: asyncpg.Pool, max_workers: int = 4, work_mem_mb: int = 64):
        self.pool = pool
        self.max_workers = max_workers
        self.work_mem_mb = work_mem_mb

    async def execute_analytical_query(self, query: str, *args) -> List[Dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.transaction(readonly=True):
                # Tier 2: Dynamic session calibration
                await conn.execute(f"SET LOCAL max_parallel_workers_per_gather = {self.max_workers};")
                await conn.execute(f"SET LOCAL work_mem = '{self.work_mem_mb}MB';")
                await conn.execute("SET LOCAL statement_timeout = '45s';")

                # Verify execution plan for starvation
                explain_query = f"EXPLAIN (ANALYZE, FORMAT JSON) {query}"
                explain_res = await conn.fetchval(explain_query, *args)
                plan_data = json.loads(explain_res)[0]["Plan"]

                self._check_worker_starvation(plan_data)

                # Execute actual query
                records = await conn.fetch(query, *args)
                return [dict(r) for r in records]

    def _check_worker_starvation(self, node: Dict[str, Any]) -> None:
        node_type = node.get("Node Type", "")
        if node_type in ("Gather", "Gather Merge"):
            planned = node.get("Workers Planned", 0)
            launched = node.get("Workers Launched", 0)

            if planned > 0 and launched == 0:
                logger.error(
                    f"CRITICAL PARALLEL STARVATION: Planned {planned} workers but 0 launched! "
                    "Global background worker pool is exhausted."
                )
            elif launched < planned:
                logger.warning(
                    f"PARTIAL PARALLEL STARVATION: Planned {planned} workers, only {launched} launched."
                )

        for child in node.get("Plans", []):
            self._check_worker_starvation(child)
```

---

## 6. Finite State Machine: 6-State Lifecycle for Parallel Query Execution

Every parallel database query transitions through 6 deterministic execution phases:

```
  [1. IDLE / INIT]
         |
         v (Client issues query)
  [2. PLANNING & COSTING] ───────────────> (Unsafe functions / small table)
         |                                           |
         | (Cost < threshold, parallel plan selected)|
         v                                           v
  [3. DSM & WORKER ALLOCATION]                 [FALLBACK: SERIAL EXECUTION]
         |                                           |
         +-----------------------+                   |
         | (Workers available)   | (Pool exhausted)  |
         v                       v                   |
  [4. PARALLEL WORKER EXECUTION] [SILENT DEGRADATION]|
         |                       (Workers: 0)        |
         | (Partial Aggregates)          |           |
         v                               v           v
  [5. GATHER / GATHER MERGE] <───────────+───────────+
         |
         v (Tuple deserialization & Finalize Aggregate)
  [6. EMIT & RESOURCE RELEASE] (DSM destroyed, workers returned to pool)
```

---

## 7. 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Inspection Command / Invariant | Pass Criterion |
|---|---|---|---|
| **Gate 1** | **DSM OS Sizing** | `df -h /dev/shm` / `k8s volume emptyDir.medium: Memory` | `/dev/shm` size $\ge \max(1\text{GB}, 0.25 \times \text{RAM})$ |
| **Gate 2** | **Worker Sizing** | `SHOW max_parallel_workers_per_gather;` | Value $\le \lfloor C_{\text{cores}} / 2 \rfloor$ |
| **Gate 3** | **Memory Budgeting** | Static analysis of query runners | `work_mem` set dynamically via `SET LOCAL` or capped $\le 128\text{MB}$ |
| **Gate 4** | **Partial Aggregation** | `EXPLAIN (FORMAT JSON)` on analytical queries | Presence of `Partial Aggregate` / `Partial Hash` under `Gather` |
| **Gate 5** | **Zero Function Poisoning**| Schema audit query for `proparallel` in `pg_proc` | Zero `VOLATILE` functions used in parallel scan predicates |
| **Gate 6** | **Starvation Telemetry** | Automated test with concurrent queries | `Workers Launched > 0` on all parallel test assertions |

---

## Summary Checklist for Coding Agents
- [ ] Calibrate `max_parallel_workers_per_gather` to $\le \lfloor C_{\text{cores}} / 2 \rfloor$ and ensure `max_parallel_workers \le max_worker_processes`.
- [ ] Enforce containerized `/dev/shm` tmpfs allocation $\ge 1\text{GB}$ to eliminate `dsm_create: out of memory`.
- [ ] Never stream raw unaggregated tuples across `Gather` nodes; enforce `Partial Aggregate` pushdown.
- [ ] Dynamically compute and apply `SET LOCAL work_mem` during parallel reporting jobs to prevent Linux OOM-killer invocations.
- [ ] Audit user-defined functions for `PARALLEL SAFE` annotations to prevent query tree parallelism poisoning.
- [ ] Monitor `Workers Planned vs Workers Launched` in `auto_explain` logs to catch silent serial plan degradation.
