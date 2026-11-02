---
description: PostgreSQL 17 execution plan profiling via EXPLAIN (ANALYZE, MEMORY, SERIALIZE text/binary, BUFFERS), MemoryContext peak allocation tracking, Dynamic Shared Memory (DSM) worker footprint analysis, client wire protocol serialization latency attribution, text vs binary encoding cliffs, column projection pruning, and OOM-killer defense across Go (jackc/pgx/v5), TypeScript (pg, postgres.js, drizzle, prisma), Python (asyncpg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{explain,memory,serialize,query_profiling,performance,telemetry,slow_query,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/internal/database/**/*.{go,rs},**/internal/store/**/*.{go,rs},**/tests/perf/**/*.{ts,go,py,rs}
alwaysApply: false
---

# Agentic Database PostgreSQL 17 EXPLAIN (MEMORY, SERIALIZE), Memory Footprint Tracking, Network Buffer Serialization & Worker DSM Spills Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, optimize, profile, or benchmark PostgreSQL 17+ query workloads, high-concurrency microservice APIs, distributed analytical endpoints, or batch extraction pipelines across Go (`jackc/pgx/v5`), TypeScript (`pg`, `postgres.js`, `drizzle-orm`, `prisma`), Python (`asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Execution vs Serialization Latency Attribution Illusion" (where `EXPLAIN ANALYZE` reports an execution duration of 4.2 ms, but microservice clients experience 380 ms p99 latencies because legacy engines discarded rows without measuring the CPU and memory cost of converting millions of fields into text wire protocol format), the "MemoryContext Bloat & Untracked Executor RAM Explosion (OOM Decapitation)" (where complex joins, window functions, and user-defined functions allocate gigabytes across unmonitored MemoryContexts, triggering Linux OOM killer `SIGKILL 137` postmaster crashes), the "Parallel Worker Dynamic Shared Memory (DSM) Sizing & Coordinator Bottleneck" (where parallel query workers silently exhaust DSM segments while coordinator threads stall serializing intermediate worker tuples), the "`SELECT *` Column Bloat & Text Wire Protocol Serialization Cliff" (where wide rows with unpruned JSONB and timestamp datums burn hundreds of milliseconds in `textout` formatting), the "Prepared Statement Generic Plan Memory Creep" (where long-lived connection poolers accumulate bloated `PlanCacheContext` instances across days), and the "Unsampled Production Profiling DoS" (where running un-metered profiling in production saturates CPU and locks query execution) by establishing a strict 5-Tier Execution Profiling Governance Ladder, formal latency attribution physics equations, serialization scaling laws, an autonomous TypeScript `AgenticExplainMemorySerializeGuardEngine`, cross-runtime driver invariants in Go, TypeScript, Python, and Rust, a 6-state optimization lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Execution Plan & Serialization Catastrophes vs The 5-Tier Governance Ladder

In relational database systems, query optimization historically focused exclusively on two physical dimensions: **CPU plan execution time** and **Disk/Buffer Cache I/O**. For over two decades, running `EXPLAIN (ANALYZE, BUFFERS)` in PostgreSQL informed engineers about index scan loops, buffer hits, disk reads, and sort spills. 

However, this produced a massive operational blind spot. When PostgreSQL executes a query under `EXPLAIN ANALYZE`, it runs executor plan nodes and then **immediately discards the resulting tuples** without serializing them into client wire protocol buffers.

In modern microservice architectures, an API endpoint frequently fetches 5,000 to 50,000 rows containing complex JSONB objects, UUIDs, numeric decimals, arrays, and timestamptz values. The true latency bottleneck is often **not** the planner or executor, but the CPU cost of running type output conversion functions (`textout`, `numeric_out`, `jsonb_out`) and copying serialized bytes across network socket buffers. Furthermore, MemoryContext allocations within executor nodes (`WindowAggContext`, `HashBatchContext`, `TuplestoreContext`) remained invisible, leading to mysterious Linux kernel Out-Of-Memory (OOM) killer terminations.

PostgreSQL 17 fundamentally revolutionizes database observability with two breakthrough `EXPLAIN` parameters:
1. **`MEMORY` (`EXPLAIN (ANALYZE, MEMORY)`)**: Directly profiles per-node and per-worker memory usage across all MemoryContexts. It exposes exact `used` and `allocated` memory bytes for scan nodes, joins, aggregates, window functions, and User-Defined Functions (UDFs).
2. **`SERIALIZE [text | binary]` (`EXPLAIN (ANALYZE, SERIALIZE text)` / `SERIALIZE binary`)**: Forces PostgreSQL to fully serialize all resulting tuples into the specified wire format (text or binary), measuring the exact serialization time in milliseconds and the wire payload byte volume, without sending the data across the network socket.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│              POSTGRESQL 17+ QUERY EXECUTION & SERIALIZATION PIPELINE                   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                              PLANNER & EXECUTOR PHASE                            │  │
│  │                                                                                  │  │
│  │   SQL Query ──► Parser ──► Optimizer Plan Tree (SeqScan / IndexScan / HashJoin)  │  │
│  │                                 │                                                │  │
│  │   ┌─────────────────────────────┴─────────────────────────────┐                  │  │
│  │   ▼                                                           ▼                  │  │
│  │ ┌───────────────────────────────┐               ┌──────────────────────────────┐ │  │
│  │ │ Parallel Workers (DSM)        │               │ Coordinator Process          │ │  │
│  │ │ • Worker 0 Memory: used / alloc│               │ • Coordinator Memory         │ │  │
│  │ │ • Worker 1 Memory: used / alloc│               │ • ExecutorState Context      │ │  │
│  │ └───────────────┬───────────────┘               └──────────────┬───────────────┘ │  │
│  │                 └─────────────────► Gather ◄───────────────────┘                 │  │
│  │                                        │ Tuples Produced                         │  │
│  │                                        ▼                                         │  │
│  │                        [ EXPLAIN (MEMORY) PROFILES HERE ]                        │  │
│  └────────────────────────────────────────┬─────────────────────────────────────────┘  │
│                                           │                                            │
│  ┌────────────────────────────────────────▼─────────────────────────────────────────┐  │
│  │                     WIRE SERIALIZATION & TRANSFER PHASE                          │  │
│  │                                                                                  │  │
│  │   Tuples ──► Type Conversion Routines:                                           │  │
│  │              • textout / jsonb_out / timestamptz_out (Text Format: CPU-heavy)    │  │
│  │              • pq_sendint32 / bytea (Binary Format: Zero-copy memcpy)            │  │
│  │                                        │                                         │  │
│  │                                        ▼                                         │  │
│  │   Wire Buffer ──► [ EXPLAIN (SERIALIZE) PROFILES HERE: Time & Wire Bytes ]       │  │
│  │                                        │                                         │  │
│  │                                        ▼ Network Socket (libpq / TCP Window)     │  │
│  │                                  Client App                                      │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

When autonomous coding agents optimize database queries without mastering PostgreSQL 17 `MEMORY` and `SERIALIZE`, they routinely trigger the following catastrophes:

---

### The 6 Execution Plan & Serialization Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE EXECUTION VS SERIALIZATION ATTRIBUTION ILLUSION
-- Agent diagnoses a slow dashboard API endpoint that takes 450 ms in production.
-- Agent runs standard EXPLAIN ANALYZE:
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, tenant_id, metadata, payload, created_at, tags
FROM audit_logs
WHERE tenant_id = 'c0a80101-8b6b-4c2e-8d5f-9e1b2c3d4e5f'
ORDER BY created_at DESC
LIMIT 5000;

-- Output:
-- Execution Time: 6.421 ms (Planning Time: 0.312 ms)
-- 💥 Catastrophe:
-- The agent concludes: "The SQL query is blazing fast (6.4ms). The bottleneck must be
-- network latency or ORM overhead in the Node.js/Go service!"
-- The agent hallucinates adding Redis caches and raising connection pool limits.
-- In reality: Running PostgreSQL 17 EXPLAIN (ANALYZE, SERIALIZE text) reveals:
--   Serialization: time=392.14 ms  output=38.6 MB  format=text
-- PostgreSQL spent 392 ms serializing 5,000 JSONB payloads and timestamptz datums to text!
-- Execution was 6.4 ms, but wire formatting was 392 ms ($P(\text{misdiagnosis}) = 1.0$).
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: UNTRACKED MEMORYCONTEXT BLOAT & OOM DECAPITATION
-- Agent authors an analytical query with multi-level window functions and custom PL/pgSQL:
EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id,
       dense_rank() OVER (PARTITION BY org_id ORDER BY score DESC) as rank,
       calculate_compound_risk(user_id, risk_factors) as risk_profile,
       array_agg(event_id) OVER (PARTITION BY org_id ROWS BETWEEN 500 PRECEDING AND 500 FOLLOWING)
FROM user_risk_events;

-- 💥 Catastrophe:
-- In PG <= 16, EXPLAIN ANALYZE only reported Sort and Hash memory. The massive memory
-- consumed by WindowAgg tuplestores, array accumulators, and PL/pgSQL expression contexts
-- was completely hidden.
-- Under concurrent production load, 10 workers allocate 4GB each, exceeding system RAM.
-- Linux kernel triggers Out-Of-Memory Killer:
--   kernel: [ 1042.842 ] Out of memory: Kill process 18492 (postgres) score 842 or sacrifice child
--   kernel: [ 1042.843 ] Killed process 18492 (postgres) total-vm:42949672kB, anon-rss:33554432kB
-- Postmaster dies, terminating all active connections across the entire cluster.
-- Invariant: Must run EXPLAIN (ANALYZE, MEMORY) to audit MemoryContext used vs allocated!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: PARALLEL WORKER DSM EXHAUSTION & COORDINATOR SPILL
-- Agent observes a slow aggregation query and aggressively tunes parallel query:
SET max_parallel_workers_per_gather = 8;
SET parallel_tuple_cost = 0;
EXPLAIN (ANALYZE, BUFFERS)
SELECT department_id, count(*), percentile_cont(0.99) WITHIN GROUP (ORDER BY latency_us)
FROM telemetry_spans
GROUP BY department_id;

-- 💥 Catastrophe:
-- Each of the 8 parallel workers initializes its own Dynamic Shared Memory (DSM) segment
-- and allocates worker-local MemoryContexts.
-- The coordinator process is pinned at 100% CPU attempting to deserialize and merge
-- worker memory states across the Gather Merge node.
-- Because the agent did not inspect EXPLAIN (ANALYZE, MEMORY), it failed to notice that
-- Worker 0-7 consumed 350MB each ($8 \times 350\text{MB} = 2.8\text{GB}$) in DSM,
-- causing DSM segment thrashing and slowing the query by 3.2x compared to 2 workers.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: SELECT * COLUMN BLOAT & TEXT WIRE FORMAT CLIFF
-- Application microservice queries customer entity for an API response:
-- Code: SELECT * FROM customers WHERE status = 'ACTIVE' LIMIT 2000;
-- Table has 45 columns: 10 TEXT fields, 4 JSONB blobs, 6 NUMERIC metrics, 5 TIMESTAMPTZ.

-- 💥 Catastrophe:
-- Running EXPLAIN (ANALYZE, SERIALIZE text):
--   Serialization: time=184.2 ms  output=18.4 MB  format=text
-- Running EXPLAIN (ANALYZE, SERIALIZE binary):
--   Serialization: time=14.1 ms   output=6.2 MB   format=binary
-- Text serialization was 13x slower and generated 3x larger wire payload!
-- By projecting ONLY needed columns (SELECT id, name, email), serialization drops to:
--   Serialization: time=1.2 ms    output=180 kB   format=binary
-- Unpruned SELECT * caused a 150x latency penalty on every client invocation.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: PREPARED STATEMENT GENERIC PLAN CACHE MEMORY CREEP
-- Application uses PgBouncer in transaction pooling mode with prepared statements:
PREPARE customer_lookup(uuid) AS
SELECT c.*, o.order_history, p.preferences
FROM customers c
LEFT JOIN LATERAL (SELECT jsonb_agg(orders) as order_history FROM orders WHERE customer_id = c.id) o ON true
LEFT JOIN LATERAL (SELECT jsonb_agg(prefs) as preferences FROM preferences WHERE customer_id = c.id) p ON true
WHERE c.id = $1;

-- 💥 Catastrophe:
-- Over 5 executions, PostgreSQL transitions from custom plan to generic plan.
-- In PG 17, EXPLAIN (MEMORY) reveals that the cached generic plan tree in `PlanCacheContext`
-- retains 4.2 MB of allocated memory per prepared statement on every backend connection!
-- With 200 backend connections, prepared statements consume 840 MB of un-freed RAM,
-- causing backend memory fragmentation and gradual connection thrashing.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: UNSAMPLED PRODUCTION PROFILING DoS
-- Agent sets up a cron job or telemetry hook running:
-- EXPLAIN (ANALYZE, MEMORY, SERIALIZE text, BUFFERS) on every slow query in production!

-- 💥 Catastrophe:
-- ANALYZE actually executes the query (including all write operations if run on mutations).
-- SERIALIZE text causes PostgreSQL to format every row in memory, consuming additional CPU.
-- Under peak load, this synthetic profiling load doubles CPU utilization on the primary,
-- exhausting database CPU and causing connection timeouts across all services.
-- Invariant: Must use auto_explain with strict sample_rate (< 0.05) or run in CI/staging!
```

---

### The 5-Tier PostgreSQL 17 Execution Profiling Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               5-TIER POSTGRESQL 17 EXECUTION PROFILING GOVERNANCE LADDER               │
├───────┬──────────────────────────────────┬─────────────────────────────────────────────┤
│ Level │ Tier Name                        │ Production Invariant & Machine Verification │
├───────┼──────────────────────────────────┼─────────────────────────────────────────────┤
│ L0    │ Engine & Parameter Qualification │ Require PostgreSQL >= 17.0 for MEMORY and   │
│       │                                  │ SERIALIZE support. Verify server version.   │
├───────┼──────────────────────────────────┼─────────────────────────────────────────────┤
│ L1    │ Dual-Axis Attribution Protocol   │ Profile (T_exec, T_serialize, M_alloc).     │
│       │                                  │ Gate: T_serialize / T_total <= 0.25.        │
├───────┼──────────────────────────────────┼─────────────────────────────────────────────┤
│ L2    │ Wire Protocol Format Calibration │ Require binary wire format for APIs returning│
│       │                                  │ > 500 rows or varlena/JSONB datums.         │
├───────┼──────────────────────────────────┼─────────────────────────────────────────────┤
│ L3    │ MemoryContext & DSM Bounding     │ Enforce M_used / M_alloc >= 0.50. Cap peak  │
│       │                                  │ query memory <= 256MB; cap worker DSM <= 64MB│
├───────┼──────────────────────────────────┼─────────────────────────────────────────────┤
│ L4    │ Autonomous CI/CD Regression Gates│ Validate EXPLAIN JSON in CI test pipelines. │
│       │                                  │ Reject PRs violating memory or wire ceilings│
└───────┴──────────────────────────────────┴─────────────────────────────────────────────┘
```

---

## 2. Mathematical Models & Formal Proofs: Latency Attribution Physics, Serialization Scaling & Memory Efficiency

### 2.1 The Latency Attribution Decomposition Theorem

The total client-perceived wall-clock duration of a database request $T_{\text{client}}$ decomposes into four disjoint physical phases:

$$T_{\text{client}} = T_{\text{net\_rtt}} + T_{\text{plan}} + T_{\text{exec}} + T_{\text{serialize}} + \frac{S_{\text{wire}}}{B_{\text{net}}}$$

Where:
- $T_{\text{net\_rtt}}$: Network round-trip transmission latency between application pod and PostgreSQL server.
- $T_{\text{plan}}$: Query parse, rewrite, and optimizer plan synthesis duration (`Planning Time`).
- $T_{\text{exec}}$: Engine execution time traversing plan nodes and processing heap/index buffers (`Execution Time` in standard `EXPLAIN ANALYZE`).
- $T_{\text{serialize}}$: CPU time spent formatting internal tuple datums into network wire protocol buffers (**Unmeasured prior to PostgreSQL 17**; measured via `EXPLAIN (ANALYZE, SERIALIZE)`).
- $S_{\text{wire}}$: Total serialized payload volume in bytes.
- $B_{\text{net}}$: Effective network bandwidth between database and client.

**Theorem 1 (The Wire Serialization Dominance Law)**:
For queries returning $N_{\text{rows}} \ge 1,000$ containing $K_{\text{varlen}}$ variable-length or composite columns (JSONB, TEXT, NUMERIC, TIMESTAMP):

$$\lim_{N_{\text{rows}} \to \infty} \frac{T_{\text{serialize}}}{T_{\text{exec}}} > 1.0 \quad \text{under Text Protocol}$$

*Proof*:
In index scans with pre-warmed buffer cache, tuple retrieval complexity is $O(1)$ page lookups per row ($t_{\text{exec}} \approx 0.8\text{–}2.5\,\mu\text{s}$ per row).
In contrast, text serialization requires executing `textout()`, `jsonb_out()`, character escaping, and string buffer memory reallocations for each column:

$$\tau_{\text{serialize}}(c) = \sum_{j=1}^{K} \left( \kappa_{\text{conv}}(t_j) + \beta \cdot \text{len}(v_j) \right) \approx 15\text{–}85\,\mu\text{s per row}$$

Therefore:

$$\frac{T_{\text{serialize}}}{T_{\text{exec}}} = \frac{N \cdot \tau_{\text{serialize}}}{N \cdot \tau_{\text{exec}}} \approx \frac{45\,\mu\text{s}}{1.5\,\mu\text{s}} = 30.0 \gg 1.0$$

The query spend is dominated by serialization, rendering index optimizations mathematically irrelevant without projection pruning or binary wire encoding. $\blacksquare$

---

### 2.2 Text vs Binary Wire Protocol Efficiency Scaling

Let $S_{\text{wire,text}}$ and $S_{\text{wire,binary}}$ denote the serialized payload sizes under text and binary protocol formats:

$$S_{\text{wire,text}} = \sum_{r=1}^N \sum_{c=1}^C \left( 4 + \text{strlen}(f_{\text{text}}(v_{r,c})) \right)$$

$$S_{\text{wire,binary}} = \sum_{r=1}^N \sum_{c=1}^C \left( 4 + \text{sizeof}_{\text{bin}}(v_{r,c}) \right)$$

For native numeric, integer, and temporal types:
- `INT8` (`bigint`): Binary is 8 bytes. Text is up to 20 ASCII bytes ($\Delta = -60\%$).
- `TIMESTAMPTZ`: Binary is 8 bytes (microsecond integer). Text is 35 ASCII bytes ISO-8601 ($\Delta = -77\%$).
- `UUID`: Binary is 16 bytes. Text is 36 ASCII bytes with hyphens ($\Delta = -55.5\%$).

The serialization speedup factor $G_{\text{ser}}$ is bounded by:

$$G_{\text{ser}} = \frac{T_{\text{serialize,text}}}{T_{\text{serialize,binary}}} \in [4.5, 18.2]$$

---

### 2.3 MemoryContext Allocation Efficiency Calculus

PostgreSQL allocates memory in hierarchical `MemoryContext` arenas using `AllocSet` or `Generation` allocators. The ratio of actual bytes used to total allocated virtual memory is defined as:

$$\eta_{\text{mem}} = \frac{M_{\text{used}}}{M_{\text{allocated}}}$$

When $\eta_{\text{mem}} < 0.50$, the query suffers from **MemoryContext Fragmentation**:
$$M_{\text{wasted}} = M_{\text{allocated}} - M_{\text{used}} > 0.50 \cdot M_{\text{allocated}}$$

This condition occurs when:
1. Dynamic functions repeatedly allocate temporary memory in long-lived contexts (e.g. `ExecutorState`) rather than per-tuple contexts (`ExprContext`).
2. Hash tables allocate power-of-two bucket arrays that are sparsely populated due to cardinality misestimation.

---

### 2.4 Parallel Worker Dynamic Shared Memory (DSM) Footprint

When parallel execution is enabled with $W$ workers, total memory consumption $M_{\text{parallel}}$ satisfies:

$$M_{\text{parallel}} = M_{\text{coord}} + \sum_{w=1}^W M_{\text{worker},w} + W \cdot S_{\text{dsm\_ring}}$$

Where $S_{\text{dsm\_ring}}$ is the tuple queue ring buffer (typically 4MB–16MB per worker). Peak memory must satisfy the system safety bound:

$$M_{\text{parallel}} \le \min\left( \text{work\_mem} \cdot W \cdot \text{hash\_mem\_multiplier}, \; \frac{\text{RAM}_{\text{avail}}}{2 \cdot C_{\text{max}}} \right)$$

---

## 3. Autonomous TypeScript Implementation: `AgenticExplainMemorySerializeGuardEngine`

The following production-grade TypeScript engine parses PostgreSQL 17 `EXPLAIN (ANALYZE, MEMORY, SERIALIZE, BUFFERS, FORMAT JSON)` plan trees, evaluates memory allocation efficiency, quantifies wire serialization penalties, detects DSM worker memory skew, and generates automated remediation recommendations.

```typescript
/**
 * AgenticExplainMemorySerializeGuardEngine.ts
 * Production-grade PostgreSQL 17 execution plan profiling, memory context analysis,
 * wire protocol serialization latency evaluation, and automated CI gate enforcement.
 */

export interface MemoryMetrics {
  usedBytes: number;
  allocatedBytes: number;
  peakBytes?: number;
}

export interface SerializationMetrics {
  format: 'text' | 'binary';
  timeMs: number;
  outputBytes: number;
}

export interface WorkerMemoryMetrics {
  workerNumber: number;
  memory: MemoryMetrics;
}

export interface ExplainPlanNode {
  'Node Type': string;
  'Total Cost': number;
  'Plan Rows': number;
  'Actual Rows': number;
  'Actual Loops': number;
  'Actual Startup Time': number;
  'Actual Total Time': number;
  'Shared Hit Blocks'?: number;
  'Shared Read Blocks'?: number;
  'Shared Written Blocks'?: number;
  'Local Hit Blocks'?: number;
  'Local Read Blocks'?: number;
  'Temp Read Blocks'?: number;
  'Temp Written Blocks'?: number;
  'Memory'?: {
    'Used'?: number;
    'Allocated'?: number;
    'Peak'?: number;
  };
  'Workers'?: Array<{
    'Worker Number': number;
    'Memory'?: {
      'Used'?: number;
      'Allocated'?: number;
      'Peak'?: number;
    };
  }>;
  Plans?: ExplainPlanNode[];
}

export interface RootExplainPlan {
  Plan: ExplainPlanNode;
  'Planning Time': number;
  'Execution Time': number;
  'Serialization'?: {
    'Format': 'text' | 'binary';
    'Serialization Time': number;
    'Output Volume': number;
  };
}

export interface AggregatedMemoryAnalysis {
  totalUsedBytes: number;
  totalAllocatedBytes: number;
  efficiencyRatio: number;
  peakNode: {
    nodeType: string;
    allocatedBytes: number;
  };
  workerAllocations: Array<{ workerNumber: number; allocatedBytes: number }>;
}

export interface SerializationAnalysis {
  format: 'text' | 'binary';
  timeMs: number;
  outputBytes: number;
  serializationRatio: number; // timeMs / (timeMs + executionTimeMs)
  isDominantBottleneck: boolean;
  wireThroughputMBps: number;
}

export interface RemediationRecommendation {
  priority: 'CRITICAL' | 'HIGH' | 'MEDIUM';
  category: 'SERIALIZATION' | 'MEMORY_BLOAT' | 'DSM_WORKERS' | 'PROJECTION_PRUNING';
  issue: string;
  remediationSqlOrConfig: string;
}

export interface PlanProfileReport {
  executionTimeMs: number;
  planningTimeMs: number;
  memory: AggregatedMemoryAnalysis;
  serialization?: SerializationAnalysis;
  remediations: RemediationRecommendation[];
  passedCiGates: boolean;
  gateViolations: string[];
}

export interface GuardThresholds {
  maxExecutionTimeMs: number;
  maxSerializationRatio: number; // e.g. 0.25 (25%)
  minMemoryEfficiency: number;   // e.g. 0.50 (50%)
  maxAllocatedMemoryBytes: number; // e.g. 128 * 1024 * 1024 (128MB)
  maxWireOutputBytes: number;     // e.g. 10 * 1024 * 1024 (10MB)
}

export class AgenticExplainMemorySerializeGuardEngine {
  private thresholds: GuardThresholds;

  constructor(customThresholds?: Partial<GuardThresholds>) {
    this.thresholds = {
      maxExecutionTimeMs: 500,
      maxSerializationRatio: 0.25,
      minMemoryEfficiency: 0.50,
      maxAllocatedMemoryBytes: 128 * 1024 * 1024, // 128MB
      maxWireOutputBytes: 10 * 1024 * 1024,      // 10MB
      ...customThresholds,
    };
  }

  /**
   * Parse raw PostgreSQL 17 EXPLAIN (FORMAT JSON) string
   */
  public parseExplainOutput(rawJson: string): RootExplainPlan {
    const parsed = JSON.parse(rawJson);
    if (!Array.isArray(parsed) || parsed.length === 0 || !parsed[0].Plan) {
      throw new Error('Invalid EXPLAIN JSON payload: root must be an array containing a Plan object.');
    }
    return parsed[0] as RootExplainPlan;
  }

  /**
   * Traverse plan tree recursively to aggregate MemoryContext metrics across all nodes & workers
   */
  public analyzeMemoryContexts(root: RootExplainPlan): AggregatedMemoryAnalysis {
    let totalUsed = 0;
    let totalAllocated = 0;
    let peakAllocated = 0;
    let peakNodeType = 'None';
    const workerMap = new Map<number, number>();

    const traverse = (node: ExplainPlanNode) => {
      if (node.Memory) {
        const u = node.Memory.Used ?? 0;
        const a = node.Memory.Allocated ?? 0;
        totalUsed += u;
        totalAllocated += a;
        if (a > peakAllocated) {
          peakAllocated = a;
          peakNodeType = node['Node Type'];
        }
      }

      if (node.Workers) {
        for (const w of node.Workers) {
          if (w.Memory) {
            const wAlloc = w.Memory.Allocated ?? 0;
            const current = workerMap.get(w['Worker Number']) ?? 0;
            workerMap.set(w['Worker Number'], current + wAlloc);
          }
        }
      }

      if (node.Plans && Array.isArray(node.Plans)) {
        for (const child of node.Plans) {
          traverse(child);
        }
      }
    };

    traverse(root.Plan);

    const efficiencyRatio = totalAllocated > 0 ? totalUsed / totalAllocated : 1.0;
    const workerAllocations = Array.from(workerMap.entries()).map(([workerNumber, allocatedBytes]) => ({
      workerNumber,
      allocatedBytes,
    }));

    return {
      totalUsedBytes: totalUsed,
      totalAllocatedBytes: totalAllocated,
      efficiencyRatio,
      peakNode: {
        nodeType: peakNodeType,
        allocatedBytes: peakAllocated,
      },
      workerAllocations,
    };
  }

  /**
   * Evaluate PostgreSQL 17 wire serialization time and volume metrics
   */
  public analyzeSerialization(root: RootExplainPlan): SerializationAnalysis | undefined {
    if (!root.Serialization) {
      return undefined;
    }

    const s = root.Serialization;
    const timeMs = s['Serialization Time'];
    const outputBytes = s['Output Volume'];
    const format = s.Format;
    const execTime = root['Execution Time'];

    const totalTime = timeMs + execTime;
    const serializationRatio = totalTime > 0 ? timeMs / totalTime : 0;
    const isDominantBottleneck = serializationRatio > 0.40;
    const seconds = timeMs / 1000;
    const wireThroughputMBps = seconds > 0 ? (outputBytes / (1024 * 1024)) / seconds : 0;

    return {
      format,
      timeMs,
      outputBytes,
      serializationRatio,
      isDominantBottleneck,
      wireThroughputMBps,
    };
  }

  /**
   * Synthesize actionable architectural remediation steps
   */
  public generateRemediations(
    root: RootExplainPlan,
    mem: AggregatedMemoryAnalysis,
    ser?: SerializationAnalysis
  ): RemediationRecommendation[] {
    const list: RemediationRecommendation[] = [];

    // 1. Serialization Bottleneck Remediation
    if (ser) {
      if (ser.format === 'text' && ser.serializationRatio > 0.30) {
        list.push({
          priority: 'CRITICAL',
          category: 'SERIALIZATION',
          issue: `Text wire format serialization accounts for ${(ser.serializationRatio * 100).toFixed(1)}% of total server duration (${ser.timeMs.toFixed(2)}ms vs ${root['Execution Time'].toFixed(2)}ms exec).`,
          remediationSqlOrConfig: `Switch client driver to PostgreSQL Binary Protocol (e.g. pgx binary mode in Go, binary: true in pg). Prune unused columns (eliminate SELECT *). Expected gain: 4x-12x latency reduction.`,
        });
      }

      if (ser.outputBytes > this.thresholds.maxWireOutputBytes) {
        list.push({
          priority: 'HIGH',
          category: 'PROJECTION_PRUNING',
          issue: `Wire payload volume of ${(ser.outputBytes / (1024 * 1024)).toFixed(2)}MB exceeds safety ceiling of ${(this.thresholds.maxWireOutputBytes / (1024 * 1024)).toFixed(2)}MB.`,
          remediationSqlOrConfig: `Enforce keyset pagination with bounded LIMIT (<= 500 rows). Exclude large JSONB / TEXT fields from primary API projection.`,
        });
      }
    }

    // 2. Memory Bloat & Low Efficiency Remediation
    if (mem.totalAllocatedBytes > this.thresholds.maxAllocatedMemoryBytes) {
      list.push({
        priority: 'CRITICAL',
        category: 'MEMORY_BLOAT',
        issue: `Total MemoryContext allocated (${(mem.totalAllocatedBytes / (1024 * 1024)).toFixed(2)}MB) exceeds upper bound (${(this.thresholds.maxAllocatedMemoryBytes / (1024 * 1024)).toFixed(2)}MB). Peak node: ${mem.peakNode.nodeType}.`,
        remediationSqlOrConfig: `Bound work_mem for this statement: SET LOCAL work_mem = '32MB'; or index underlying tables to convert HashAggregate / Materialize nodes to streaming GroupAggregate / IndexScan.`,
      });
    }

    if (mem.efficiencyRatio < this.thresholds.minMemoryEfficiency && mem.totalAllocatedBytes > 10 * 1024 * 1024) {
      list.push({
        priority: 'MEDIUM',
        category: 'MEMORY_BLOAT',
        issue: `MemoryContext efficiency is only ${(mem.efficiencyRatio * 100).toFixed(1)}% (${(mem.totalUsedBytes / 1024).toFixed(0)}kB used of ${(mem.totalAllocatedBytes / 1024).toFixed(0)}kB allocated). Severe internal fragmentation detected.`,
        remediationSqlOrConfig: `Re-evaluate custom PL/pgSQL functions or aggregate accumulators to ensure memory contexts are reset per batch.`,
      });
    }

    // 3. Parallel Worker Memory Remediation
    if (mem.workerAllocations.length > 0) {
      const maxWorkerBytes = Math.max(...mem.workerAllocations.map(w => w.allocatedBytes));
      if (maxWorkerBytes > 64 * 1024 * 1024) {
        list.push({
          priority: 'HIGH',
          category: 'DSM_WORKERS',
          issue: `Parallel worker allocated ${(maxWorkerBytes / (1024 * 1024)).toFixed(2)}MB in Dynamic Shared Memory (DSM). Multiple parallel workers risk DSM segment exhaustion and host OOM.`,
          remediationSqlOrConfig: `Reduce max_parallel_workers_per_gather to 2 or reduce work_mem for parallel queries to prevent DSM pool depletion.`,
        });
      }
    }

    return list;
  }

  /**
   * Run full profile inspection and assert CI / Production DoD Gate readiness
   */
  public evaluate(rawJson: string): PlanProfileReport {
    const root = this.parseExplainOutput(rawJson);
    const memory = this.analyzeMemoryContexts(root);
    const serialization = this.analyzeSerialization(root);
    const remediations = this.generateRemediations(root, memory, serialization);

    const gateViolations: string[];
    const violations: string[] = [];

    if (root['Execution Time'] > this.thresholds.maxExecutionTimeMs) {
      violations.push(`Gate 1 Failed: Execution time ${root['Execution Time'].toFixed(2)}ms exceeds threshold ${this.thresholds.maxExecutionTimeMs}ms.`);
    }

    if (serialization && serialization.serializationRatio > this.thresholds.maxSerializationRatio) {
      violations.push(`Gate 2 Failed: Serialization ratio ${(serialization.serializationRatio * 100).toFixed(1)}% exceeds ceiling ${(this.thresholds.maxSerializationRatio * 100).toFixed(1)}%.`);
    }

    if (memory.totalAllocatedBytes > this.thresholds.maxAllocatedMemoryBytes) {
      violations.push(`Gate 3 Failed: Total allocated memory ${(memory.totalAllocatedBytes / (1024 * 1024)).toFixed(2)}MB exceeds limit ${(this.thresholds.maxAllocatedMemoryBytes / (1024 * 1024)).toFixed(2)}MB.`);
    }

    if (serialization && serialization.outputBytes > this.thresholds.maxWireOutputBytes) {
      violations.push(`Gate 4 Failed: Wire payload volume ${(serialization.outputBytes / (1024 * 1024)).toFixed(2)}MB exceeds limit ${(this.thresholds.maxWireOutputBytes / (1024 * 1024)).toFixed(2)}MB.`);
    }

    const passedCiGates = violations.length === 0;

    return {
      executionTimeMs: root['Execution Time'],
      planningTimeMs: root['Planning Time'],
      memory,
      serialization,
      remediations,
      passedCiGates,
      gateViolations: violations,
    };
  }
}
```

---

## 4. Cross-Runtime Production Implementation

### 4.1 Go (`jackc/pgx/v5`): Automated PostgreSQL 17 Plan Profiling & Binary Protocol Enforcement

In Go microservices using `jackc/pgx/v5`, simple SQL execution uses the binary wire format by default for native types. However, when executing analytical queries or raw text statements, agents must verify memory allocations and wire serialization performance using transactional canary tests.

```go
// internal/database/explain_profiler.go
package database

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

// ExplainSerializationMetrics captures PG 17 serialization diagnostics
type ExplainSerializationMetrics struct {
	Format            string  `json:"Format"`
	SerializationTime float64 `json:"Serialization Time"`
	OutputVolume      int64   `json:"Output Volume"`
}

// ExplainPlanNode captures plan node memory contexts
type ExplainPlanNode struct {
	NodeType   string  `json:"Node Type"`
	ActualRows float64 `json:"Actual Rows"`
	ActualTime float64 `json:"Actual Total Time"`
	Memory     *struct {
		Used      int64 `json:"Used"`
		Allocated int64 `json:"Allocated"`
		Peak      int64 `json:"Peak"`
	} `json:"Memory,omitempty"`
	Plans []ExplainPlanNode `json:"Plans,omitempty"`
}

// ExplainRootModel captures the root JSON output of EXPLAIN
type ExplainRootModel struct {
	Plan          ExplainPlanNode              `json:"Plan"`
	PlanningTime  float64                      `json:"Planning Time"`
	ExecutionTime float64                      `json:"Execution Time"`
	Serialization *ExplainSerializationMetrics `json:"Serialization,omitempty"`
}

type ProfilerResult struct {
	ExecutionTimeMs     float64
	SerializationTimeMs float64
	TotalMemoryAllocMB  float64
	OutputVolumeKB      float64
	Format              string
	PassedInvariants    bool
	ViolationReason     string
}

// ProfileQueryPostgres17 executes a canary query with PG 17 MEMORY and SERIALIZE metrics
func ProfileQueryPostgres17(
	ctx context.Context,
	pool *pgxpool.Pool,
	logger *slog.Logger,
	query string,
	format string, // "binary" or "text"
	args ...any,
) (*ProfilerResult, error) {
	if format != "binary" && format != "text" {
		format = "binary"
	}

	explainSql := fmt.Sprintf("EXPLAIN (ANALYZE, MEMORY, SERIALIZE %s, BUFFERS, FORMAT JSON) %s", format, query)

	// Execute within read-only transaction with strict timeout
	txCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	tx, err := pool.BeginTx(txCtx, pgx.TxOptions{
		IsoLevel:   pgx.ReadCommitted,
		AccessMode: pgx.ReadOnly,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to begin profiling transaction: %w", err)
	}
	defer tx.Rollback(context.Background())

	var rawJson []byte
	err = tx.QueryRow(txCtx, explainSql, args...).Scan(&rawJson)
	if err != nil {
		return nil, fmt.Errorf("failed to execute EXPLAIN (MEMORY, SERIALIZE): %w", err)
	}

	var parsedRoots []ExplainRootModel
	if err := json.Unmarshal(rawJson, &parsedRoots); err != nil || len(parsedRoots) == 0 {
		return nil, fmt.Errorf("failed to parse EXPLAIN JSON output: %w", err)
	}

	root := parsedRoots[0]

	// Aggregate allocated memory
	var totalAllocatedBytes int64
	var traverse func(node ExplainPlanNode)
	traverse = func(node ExplainPlanNode) {
		if node.Memory != nil {
			totalAllocatedBytes += node.Memory.Allocated
		}
		for _, child := range node.Plans {
			traverse(child)
		}
	}
	traverse(root.Plan)

	result := &ProfilerResult{
		ExecutionTimeMs:    root.ExecutionTime,
		TotalMemoryAllocMB: float64(totalAllocatedBytes) / (1024 * 1024),
		PassedInvariants:   true,
	}

	if root.Serialization != nil {
		result.SerializationTimeMs = root.Serialization.SerializationTime
		result.OutputVolumeKB = float64(root.Serialization.OutputVolume) / 1024
		result.Format = root.Serialization.Format

		// Invariant Gate: Serialization time must not exceed 25% of total time
		totalTime := result.ExecutionTimeMs + result.SerializationTimeMs
		if totalTime > 10.0 { // only evaluate for queries >= 10ms
			ratio := result.SerializationTimeMs / totalTime
			if ratio > 0.25 {
				result.PassedInvariants = false
				result.ViolationReason = fmt.Sprintf("Serialization ratio %.1f%% exceeds 25%% ceiling (ser=%.2fms, exec=%.2fms)",
					ratio*100, result.SerializationTimeMs, result.ExecutionTimeMs)
			}
		}
	}

	// Invariant Gate: Total allocated memory must not exceed 64MB for standard OLTP
	if result.TotalMemoryAllocMB > 64.0 {
		result.PassedInvariants = false
		result.ViolationReason = fmt.Sprintf("Allocated memory %.2fMB exceeds 64MB OLTP threshold", result.TotalMemoryAllocMB)
	}

	logger.InfoContext(ctx, "PostgreSQL 17 Query Profile Captured",
		slog.Float64("exec_ms", result.ExecutionTimeMs),
		slog.Float64("ser_ms", result.SerializationTimeMs),
		slog.Float64("mem_mb", result.TotalMemoryAllocMB),
		slog.Float64("wire_kb", result.OutputVolumeKB),
		slog.String("format", result.Format),
		slog.Bool("passed", result.PassedInvariants),
	)

	return result, nil
}
```

---

### 4.2 TypeScript (`postgres.js`): Production Execution & Wire Serialization Sentinel

```typescript
// src/database/postgres17Profiler.ts
import postgres from 'postgres';

export interface ProfileOutput {
  executionMs: number;
  serializationMs: number;
  wireVolumeKb: number;
  allocatedMemoryMb: number;
  format: 'text' | 'binary';
  isCompliant: boolean;
  alert?: string;
}

export async function profileQueryPg17(
  sql: postgres.Sql,
  queryText: string,
  format: 'binary' | 'text' = 'binary'
): Promise<ProfileOutput> {
  const explainQuery = `EXPLAIN (ANALYZE, MEMORY, SERIALIZE ${format}, BUFFERS, FORMAT JSON) ${queryText}`;

  // Execute within transaction with bounded statement_timeout
  const result = await sql.begin(async (tx) => {
    await tx`SET LOCAL statement_timeout = '4000ms'`;
    const rows = await tx.unsafe(explainQuery);
    return rows[0]['QUERY PLAN'][0];
  });

  const execTime = result['Execution Time'] as number;
  const ser = result['Serialization'] as {
    Format: 'text' | 'binary';
    'Serialization Time': number;
    'Output Volume': number;
  } | undefined;

  let totalAllocBytes = 0;
  function sumMem(node: any) {
    if (node['Memory'] && node['Memory']['Allocated']) {
      totalAllocBytes += node['Memory']['Allocated'];
    }
    if (node['Plans']) {
      for (const p of node['Plans']) sumMem(p);
    }
  }
  sumMem(result['Plan']);

  const serMs = ser ? ser['Serialization Time'] : 0;
  const wireKb = ser ? ser['Output Volume'] / 1024 : 0;
  const memMb = totalAllocBytes / (1024 * 1024);

  const totalTime = execTime + serMs;
  const serRatio = totalTime > 0 ? serMs / totalTime : 0;

  let isCompliant = true;
  let alert: string | undefined;

  if (serRatio > 0.30 && totalTime > 15) {
    isCompliant = false;
    alert = `Wire serialization is ${ (serRatio * 100).toFixed(1) }% of response latency. Switch to binary wire protocol or prune columns.`;
  } else if (memMb > 128) {
    isCompliant = false;
    alert = `Allocated MemoryContext (${ memMb.toFixed(1) }MB) exceeds 128MB safety limit.`;
  }

  return {
    executionMs: execTime,
    serializationMs: serMs,
    wireVolumeKb: wireKb,
    allocatedMemoryMb: memMb,
    format,
    isCompliant,
    alert,
  };
}
```

---

### 4.3 Python (`asyncpg`): Async Diagnostic Engine for Memory & Binary Format

```python
# database/explain_profiler.py
import json
import logging
from typing import Dict, Any, Tuple
import asyncpg

logger = logging.getLogger("db.profiler")

async def profile_query_pg17(
    conn: asyncpg.Connection,
    query: str,
    wire_format: str = "binary",
    timeout_sec: float = 5.0
) -> Dict[str, Any]:
    """
    Executes query with PostgreSQL 17 MEMORY and SERIALIZE options.
    Evaluates memory allocation and serialization wire ratio.
    """
    format_opt = "binary" if wire_format.lower() == "binary" else "text"
    explain_sql = f"EXPLAIN (ANALYZE, MEMORY, SERIALIZE {format_opt}, BUFFERS, FORMAT JSON) {query}"

    async with conn.transaction():
        await conn.execute(f"SET LOCAL statement_timeout = '{int(timeout_sec * 1000)}ms'")
        row = await conn.fetchval(explain_sql)
        plan_data = json.loads(row)[0]

    exec_ms = plan_data.get("Execution Time", 0.0)
    ser_meta = plan_data.get("Serialization", {})
    ser_ms = ser_meta.get("Serialization Time", 0.0)
    wire_bytes = ser_meta.get("Output Volume", 0)

    # Recursive memory aggregation
    total_alloc_bytes = 0
    def aggregate_memory(node: Dict[str, Any]):
        nonlocal total_alloc_bytes
        if "Memory" in node and "Allocated" in node["Memory"]:
            total_alloc_bytes += node["Memory"]["Allocated"]
        for child in node.get("Plans", []):
            aggregate_memory(child)

    aggregate_memory(plan_data["Plan"])

    alloc_mb = total_alloc_bytes / (1024 * 1024)
    total_time = exec_ms + ser_ms
    ser_ratio = (ser_ms / total_time) if total_time > 0 else 0.0

    is_compliant = True
    violation = None

    if ser_ratio > 0.25 and total_time > 10.0:
        is_compliant = False
        violation = f"Serialization took {ser_ratio * 100:.1f}% of total duration ({ser_ms:.2f}ms vs {exec_ms:.2f}ms exec)."
    elif alloc_mb > 64.0:
        is_compliant = False
        violation = f"Allocated MemoryContext {alloc_mb:.2f}MB exceeds 64MB limit."

    logger.info(
        "PG17 Profile: exec=%.2fms ser=%.2fms alloc=%.2fMB wire=%.1fKB format=%s compliant=%s",
        exec_ms, ser_ms, alloc_mb, wire_bytes / 1024, format_opt, is_compliant
    )

    return {
        "execution_ms": exec_ms,
        "serialization_ms": ser_ms,
        "allocated_mb": alloc_mb,
        "wire_bytes": wire_bytes,
        "format": format_opt,
        "is_compliant": is_compliant,
        "violation": violation
    }
```

---

### 4.4 Rust (`tokio-postgres`): Serde Plan Validation & Zero-Copy Binary Decoding

```rust
// src/db/explain_profiler.rs
use serde::Deserialize;
use std::time::Duration;
use tokio_postgres::{Client, Error};

#[derive(Debug, Deserialize)]
pub struct MemoryContextInfo {
    #[serde(rename = "Used")]
    pub used: Option<i64>,
    #[serde(rename = "Allocated")]
    pub allocated: Option<i64>,
    #[serde(rename = "Peak")]
    pub peak: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct PlanNode {
    #[serde(rename = "Node Type")]
    pub node_type: String,
    #[serde(rename = "Actual Total Time")]
    pub actual_total_time: f64,
    #[serde(rename = "Memory")]
    pub memory: Option<MemoryContextInfo>,
    #[serde(rename = "Plans")]
    pub plans: Option<Vec<PlanNode>>,
}

#[derive(Debug, Deserialize)]
pub struct SerializationInfo {
    #[serde(rename = "Format")]
    pub format: String,
    #[serde(rename = "Serialization Time")]
    pub serialization_time: f64,
    #[serde(rename = "Output Volume")]
    pub output_volume: i64,
}

#[derive(Debug, Deserialize)]
pub struct ExplainRoot {
    #[serde(rename = "Plan")]
    pub plan: PlanNode,
    #[serde(rename = "Execution Time")]
    pub execution_time: f64,
    #[serde(rename = "Serialization")]
    pub serialization: Option<SerializationInfo>,
}

pub struct ProfileSummary {
    pub execution_time_ms: f64,
    pub serialization_time_ms: f64,
    pub allocated_memory_mb: f64,
    pub wire_volume_kb: f64,
    pub is_valid: bool,
    pub error_msg: Option<String>,
}

pub async fn profile_query_pg17(
    client: &Client,
    query: &str,
    use_binary: bool,
) -> Result<ProfileSummary, Box<dyn std::error::Error>> {
    let format_str = if use_binary { "binary" } else { "text" };
    let explain_sql = format!(
        "EXPLAIN (ANALYZE, MEMORY, SERIALIZE {}, BUFFERS, FORMAT JSON) {}",
        format_str, query
    );

    let row = client.query_one(&explain_sql, &[]).await?;
    let raw_json: serde_json::Value = row.get(0);

    let parsed: Vec<ExplainRoot> = serde_json::from_value(raw_json)?;
    let root = parsed.into_iter().next().ok_or("Empty EXPLAIN output")?;

    let mut total_allocated: i64 = 0;
    fn sum_memory(node: &PlanNode, total: &mut i64) {
        if let Some(ref m) = node.memory {
            if let Some(alloc) = m.allocated {
                *total += alloc;
            }
        }
        if let Some(ref children) = node.plans {
            for child in children {
                sum_memory(child, total);
            }
        }
    }
    sum_memory(&root.plan, &mut total_allocated);

    let exec_ms = root.execution_time;
    let (ser_ms, wire_bytes) = if let Some(ref s) = root.serialization {
        (s.serialization_time, s.output_volume)
    } else {
        (0.0, 0)
    };

    let total_time = exec_ms + ser_ms;
    let ser_ratio = if total_time > 0.0 { ser_ms / total_time } else { 0.0 };
    let alloc_mb = (total_allocated as f64) / (1024.0 * 1024.0);

    let mut is_valid = true;
    let mut error_msg = None;

    if ser_ratio > 0.25 && total_time > 10.0 {
        is_valid = false;
        error_msg = Some(format!(
            "Serialization ratio {:.1}% exceeds 25% threshold",
            ser_ratio * 100.0
        ));
    } else if alloc_mb > 64.0 {
        is_valid = false;
        error_msg = Some(format!("Allocated memory {:.2}MB exceeds 64MB", alloc_mb));
    }

    Ok(ProfileSummary {
        execution_time_ms: exec_ms,
        serialization_time_ms: ser_ms,
        allocated_memory_mb: alloc_mb,
        wire_volume_kb: (wire_bytes as f64) / 1024.0,
        is_valid,
        error_msg,
    })
}
```

---

## 5. The 6-State Lifecycle Finite-State Machine (FSM)

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             POSTGRESQL 17 EXECUTION PROFILING & REMEDIATION LIFECYCLE FSM             │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│     ┌──────────────────┐             PostgreSQL >= 17 Verified                         │
│     │   UNPROFILED     │───────────────────────────────────────────────┐               │
│     └────────┬─────────┘                                               ▼               │
│              │                                              ┌─────────────────────┐    │
│              │ Trigger Profile Canary                       │  PROFILING_ACTIVE   │    │
│              └─────────────────────────────────────────────►│ (EXPLAIN MEMORY/SER)│    │
│                                                             └──────────┬──────────┘    │
│                                                                        │ JSON Emitted  │
│                                                                        ▼               │
│     ┌─────────────────────────────────────────────────────────────────────────────┐    │
│     │                              METRICS_EVALUATED                              │    │
│     │  • Extract (T_exec, T_serialize, S_wire, M_used, M_allocated, Workers)      │    │
│     └───────┬──────────────────────────────────────────────────────────────┬──────┘    │
│             │                                                              │           │
│             │ Violations Found (ser_ratio > 0.25 || alloc > 64MB)           │ All Gates │
│             ▼                                                              │ Passed    │
│     ┌──────────────────────┐                                               │           │
│     │ BOTTLENECK_ISOLATED  │                                               │           │
│     │ • Classify Root Cause│                                               │           │
│     └───────┬──────────────┘                                               │           │
│             │ Apply Targeted Fix                                           │           │
│             ▼                                                              │           │
│     ┌──────────────────────┐        Re-Profile & Verify Improvement        │           │
│     │ REMEDIATION_APPLIED  │───────────────────────────────────────────────┘           │
│     │ (Binary wire / prune)│                                               │           │
│     └──────────────────────┘                                               ▼           │
│                                                                  ┌───────────────────┐ │
│                                                                  │   CI_CERTIFIED    │ │
│                                                                  │ (Production Ready)│ │
│                                                                  └───────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### State Transition Table

| Current State | Event / Trigger | Guard Condition | Next State | Action / Invariant |
|---|---|---|---|---|
| `UNPROFILED` | `INITIATE_PROFILE` | Cluster version $\ge 17.0$ verified | `PROFILING_ACTIVE` | Execute `EXPLAIN (ANALYZE, MEMORY, SERIALIZE binary/text, BUFFERS, FORMAT JSON)`. |
| `PROFILING_ACTIVE` | `JSON_RETURNED` | JSON payload contains `Plan` and `Execution Time` | `METRICS_EVALUATED` | Parse tree; compute $T_{\text{ser}} / T_{\text{total}}$, $M_{\text{used}} / M_{\text{alloc}}$, and DSM memory. |
| `METRICS_EVALUATED` | `GATES_SATISFIED` | All 6 DoD gates evaluated without violation | `CI_CERTIFIED` | Query approved for production traffic; log baseline profile metrics. |
| `METRICS_EVALUATED` | `VIOLATION_DETECTED`| $\frac{T_{\text{ser}}}{T_{\text{total}}} > 0.25$ or $M_{\text{alloc}} > 64\text{MB}$ | `BOTTLENECK_ISOLATED` | Categorize defect: Text Serialization, Column Bloat, or MemoryContext leak. |
| `BOTTLENECK_ISOLATED`| `REMEDIATION_READY` | Automated fix synthesized | `REMEDIATION_APPLIED` | Switch to binary protocol, prune unneeded columns, or tune `work_mem`. |
| `REMEDIATION_APPLIED`| `RE_PROFILE` | Query rewritten / client calibrated | `PROFILING_ACTIVE` | Re-run `EXPLAIN` to prove quantitative latency and memory reduction. |

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Gates

To guarantee that autonomous agents do not ship queries with unmeasured serialization bottlenecks, memory bloat, or OOM hazards, the following **6 DoD Gates** must be executed within automated CI test suites.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        6-GATE MACHINE-VERIFIABLE DEFINITION OF DONE                    │
├───────┬─────────────────────────────┬──────────────────────────────────────────────────┤
│ Gate  │ Invariant Name              │ Exact Machine-Verifiable Verification Threshold  │
├───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
│ G1    │ PostgreSQL 17 Qualification │ `SHOW server_version_num` >= 170000.             │
├───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
│ G2    │ Serialization Ratio Ceiling │ Serialization Time / Total Time <= 0.25 (25%).   │
├───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
│ G3    │ Wire Payload Volume Bound   │ Total Output Volume <= 10.0 MB per query.        │
├───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
│ G4    │ MemoryContext Cap           │ Total Allocated MemoryContext <= 64 MB for OLTP. │
├───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
│ G5    │ Memory Efficiency Baseline  │ Used Memory / Allocated Memory >= 0.50 (50%).    │
├───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
│ G6    │ Parallel Worker DSM Bounding│ Max Memory per DSM Worker <= 32 MB.              │
└───────┴─────────────────────────────┴──────────────────────────────────────────────────┘
```

### Automated CI Verification Script (`ci-verify-explain-memory-serialize.sh`)

```bash
#!/usr/bin/env bash
# ci-verify-explain-memory-serialize.sh
# Automated CI test runner asserting PostgreSQL 17 MEMORY and SERIALIZE invariants
set -euo pipefail

DB_URL="${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/postgres}"

echo "================================================================="
echo "  PostgreSQL 17 EXPLAIN (MEMORY, SERIALIZE) CI Verification Gate "
echo "================================================================="

# 1. Gate 1: Engine Qualification (PG >= 17)
PG_VER=$(psql "${DB_URL}" -At -c "SHOW server_version_num;")
if [ "${PG_VER}" -lt 170000 ]; then
  echo "❌ FAIL [Gate 1]: PostgreSQL version (${PG_VER}) is less than 17.0 (170000). MEMORY and SERIALIZE are unsupported."
  exit 1
fi
echo "✅ PASS [Gate 1]: PostgreSQL version ${PG_VER} >= 170000 confirmed."

# 2. Gate 2, 3, 4, 5, 6: Profile Target Canary Queries
TEST_SQL="
SELECT u.id, u.email, u.metadata, count(o.id) as order_count
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.id, u.email, u.metadata
LIMIT 1000;
"

EXPLAIN_CMD="EXPLAIN (ANALYZE, MEMORY, SERIALIZE binary, BUFFERS, FORMAT JSON) ${TEST_SQL}"

echo "Executing canary query profile..."
JSON_OUTPUT=$(psql "${DB_URL}" -At -c "${EXPLAIN_CMD}")

# Evaluate using Python JSON analyzer
python3 - <<EOF
import json, sys

data = json.loads('''${JSON_OUTPUT}''')
root = data[0]

exec_ms = root.get('Execution Time', 0.0)
planning_ms = root.get('Planning Time', 0.0)
ser = root.get('Serialization', {})
ser_ms = ser.get('Serialization Time', 0.0)
wire_bytes = ser.get('Output Volume', 0)
format_used = ser.get('Format', 'unknown')

total_time = exec_ms + ser_ms
ser_ratio = (ser_ms / total_time) if total_time > 0 else 0.0

total_alloc = 0
total_used = 0
max_worker_alloc = 0

def traverse(node):
    global total_alloc, total_used, max_worker_alloc
    m = node.get('Memory')
    if m:
        total_alloc += m.get('Allocated', 0)
        total_used += m.get('Used', 0)
    for w in node.get('Workers', []):
        wm = w.get('Memory')
        if wm:
            walloc = wm.get('Allocated', 0)
            if walloc > max_worker_alloc:
                max_worker_alloc = walloc
    for child in node.get('Plans', []):
        traverse(child)

traverse(root['Plan'])

alloc_mb = total_alloc / (1024 * 1024)
wire_mb = wire_bytes / (1024 * 1024)
efficiency = (total_used / total_alloc) if total_alloc > 0 else 1.0

print(f"Profile Metrics: exec={exec_ms:.2f}ms, ser={ser_ms:.2f}ms (ratio: {ser_ratio*100:.1f}%), wire={wire_mb:.2f}MB, alloc={alloc_mb:.2f}MB, eff={efficiency*100:.1f}%")

# Assert Gates
failures = []
if ser_ratio > 0.25 and total_time > 10.0:
    failures.append(f"Gate 2 Failed: Serialization ratio {ser_ratio*100:.1f}% > 25%")
if wire_mb > 10.0:
    failures.append(f"Gate 3 Failed: Wire payload {wire_mb:.2f}MB > 10MB")
if alloc_mb > 64.0:
    failures.append(f"Gate 4 Failed: Allocated memory {alloc_mb:.2f}MB > 64MB")
if efficiency < 0.50 and total_alloc > (5 * 1024 * 1024):
    failures.append(f"Gate 5 Failed: Memory efficiency {efficiency*100:.1f}% < 50%")
if (max_worker_alloc / (1024 * 1024)) > 32.0:
    failures.append(f"Gate 6 Failed: Worker DSM allocation {max_worker_alloc/(1024*1024):.2f}MB > 32MB")

if failures:
    for f in failures:
        print(f"❌ {f}")
    sys.exit(1)

print("✅ PASS: All 6 PostgreSQL 17 Execution Profiling DoD Gates Satisfied!")
sys.exit(0)
EOF

echo "================================================================="
echo "  All PostgreSQL 17 Execution & Serialization Invariants PASSED  "
echo "================================================================="
```
