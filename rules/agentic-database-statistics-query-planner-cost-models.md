---
description: PostgreSQL query planner optimization, extended statistics (CREATE STATISTICS), cardinality misestimation defense, random_page_cost SSD calibration, JIT OLTP disabling, generic vs custom plan cache governance, and EXPLAIN (ANALYZE, BUFFERS) CI verification across Go (pgx/v5), TypeScript (Drizzle/Kysely/Prisma), Python (psycopg/SQLAlchemy), Rust (tokio-postgres), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{query,planner,explain,stats,statistics,cost,database,db,dao,repository,schema,migration}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Statistics, Extended Statistics (`CREATE STATISTICS`), Cardinality Misestimation & Cost Model Calibration Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to write database queries, configure PostgreSQL query planner cost parameters, design multi-column filtering endpoints, optimize complex multi-table joins, or establish continuous database performance regression testing across PostgreSQL, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `Prisma`), Python (`psycopg3`, `SQLAlchemy`), or Rust (`tokio-postgres`). Eliminate the "Correlated Columns & Multi-Predicate Cardinality Underestimation Disaster" (where the planner assumes column independence, multiplying selectivities and underestimating row counts by $1,000\times$, forcing catastrophic Nested Loop joins on large datasets), the "Outdated Table Statistics & Stale pg_statistic Disaster" (where high-write or newly migrated tables lack fresh statistics due to conservative `autovacuum_analyze_scale_factor = 0.10`, causing the planner to select sequential scans and undersized `work_mem` hash buckets that spill gigabytes to disk), the "Default Statistics Target Blindness & Zipfian Skew Meltdown" (where `default_statistics_target = 100` truncates the Most Common Values (MCV) list, causing extreme estimation errors on power-law distributed user/tenant/SKU attributes), the "JIT Compilation Overhead Latency Spike in OLTP Workloads" (where PostgreSQL LLVM JIT compiles queries whose estimated cost exceeds 100,000, adding 30ms–150ms of CPU compilation overhead to transactional queries that execute in 2ms), the "Storage Cost Model Mismatch & SSD Random I/O Penalty Trap" (where default `random_page_cost = 4.0` from 1990s spinning hard drives penalizes B-tree index scans on NVMe SSDs, triggering sequential table scans on multi-million row relations), and the "Prepared Statement Generic Plan Drift & Parameter Sniffing Mirage" (where the driver-level statement cache switches to an unparameterized generic plan on the 6th execution, choosing an index scan suited for small tenants that locks up when executed with an enterprise tenant) by establishing a strict 5-Tier Statistics & Cost Model Governance Ladder, multivariate `CREATE STATISTICS`, modern NVMe cost constants, and machine-verifiable `EXPLAIN (ANALYZE, BUFFERS)` CI gates.

---

## 1. Architectural Taxonomy: The 6 Statistics & Planner Catastrophes vs The 5-Tier Governance Ladder

The PostgreSQL Cost-Based Optimizer (CBO) transforms declarative SQL queries into physical execution plans (Index Scan, Bitmap Heap Scan, Hash Join, Merge Join, Nested Loop) by calculating synthetic execution costs using internal catalog statistics (`pg_statistic`, `pg_stats`, `pg_statistic_ext`). A complete query planner governance subsystem comprises six core elements:
1. **Catalog Statistical Model (`pg_statistic` / `pg_stats`)**: Per-column histograms, Most Common Values (MCVs), distinct value counts (`n_distinct`), null fractions, and average column widths sampled by `ANALYZE`.
2. **Multivariate Extended Statistics (`pg_statistic_ext`)**: User-defined statistical relations capturing functional dependencies, n-distinct coefficients, and multivariate MCV lists across multiple correlated columns (`CREATE STATISTICS`).
3. **Hardware Storage Cost Model (`random_page_cost` & `seq_page_cost`)**: Physical I/O weighting constants establishing the relative penalty of random B-tree page traversals versus sequential heap page reads.
4. **Execution Engine Resource Allocators (`work_mem` & `hash_mem_multiplier`)**: Memory budgets allocated per sort, hash join, and bitmap operation before execution nodes spill intermediate batches to temporary disk files.
5. **JIT Compilation Governor (`jit`, `jit_above_cost`)**: Compiler threshold rules determining whether expressions and tuple deforming are compiled via LLVM bytecode or executed by the built-in interpreter.
6. **Statement Plan Cache Governor (`plan_cache_mode`)**: Dynamic logic balancing parameter-tailored custom plans against cached generic execution trees in prepared statement pooling.

When autonomous coding agents generate database schemas, queries, or configuration scripts, LLMs frequently fall prey to catastrophic architectural misconceptions:

```typescript
// ❌ CATASTROPHIC LLM DATABASE QUERY & PLANNER ANTI-PATTERNS

// 1. Assuming PostgreSQL understands correlated columns without CREATE STATISTICS!
// PostgreSQL assumes Attribute Value Independence (AVI): P(city='San Francisco' AND state='CA') = P(city) * P(state).
// The optimizer underestimates result rows by 500x, picking a Nested Loop Join that locks up CPU for minutes!
await db.query(`
  SELECT * FROM store_inventories 
  WHERE warehouse_country = 'US' AND warehouse_state = 'CA' AND sku_category = 'ELECTRONICS';
`); // FATAL: Planner assumes independent probabilities, severely underestimating row count

// 2. Relying on default random_page_cost = 4.0 on modern NVMe cloud SSDs!
// The planner penalizes random page reads by 4x compared to sequential reads.
// On NVMe SSDs where random read seek latency is negligible, the planner irrationally avoids
// valid B-tree indexes, choosing a catastrophic 20GB Sequential Scan instead!
// Default settings: seq_page_cost = 1.0, random_page_cost = 4.0 (Calibrated for 1995 spinning HDDs)

// 3. Leaving JIT enabled on low-latency transactional OLTP services!
// With jit = on, queries exceeding jit_above_cost (100,000) trigger LLVM compilation.
// Compilation takes 45ms for a query that executes in 1.2ms, inflating p99 API latency by 35x!

// 4. Incurring the 6th prepared statement Generic Plan Drift!
// pgx / pg drivers prepare statements: the first 5 runs use custom plans.
// On the 6th run, PostgreSQL generates a generic plan. If parameter data distribution is skewed,
// the generic plan locks up when called with large tenant IDs, inducing 504 Gateway Timeouts!
```

In production architectures, these anti-patterns manifest as six catastrophic failure modes:

- **The "Correlated Columns & Multi-Predicate Cardinality Underestimation Disaster"**:
  - The PostgreSQL optimizer fundamentally assumes Attribute Value Independence (AVI):
    $$\mathbb{P}(C_1 = v_1 \land C_2 = v_2) = \mathbb{P}(C_1 = v_1) \times \mathbb{P}(C_2 = v_2)$$
  - In real-world data, columns are intensely correlated: `make = 'Audi'` and `model = 'A4'`, or `country = 'US'` and `state = 'CA'`, or `department_id = 4` and `role_id = 12`.
  - When an application filters on both columns, the planner multiplies their individual selectivities (e.g., $0.005 \times 0.004 = 0.00002$), estimating that the query will produce **1 row**. In reality, 40,000 rows match.
  - Relying on the 1-row estimation, the planner chooses a **Nested Loop Join** against a downstream table instead of a Hash Join or Merge Join.
  - The Nested Loop executes 40,000 index lookups instead of the expected 1, spiking execution time from 5ms to 90 seconds, saturating CPU cores at 100%, and holding open database connection pool slots.
  - Invariant: Mandatory multivariate extended statistics: `CREATE STATISTICS <name> (dependencies, ndistinct, mcv) ON col_a, col_b FROM <table>;` followed immediately by `ANALYZE <table>;`.

- **The "Outdated Table Statistics & Stale pg_statistic Disaster"**:
  - PostgreSQL autovacuum/analyze daemon triggers `ANALYZE` only when modified tuples exceed:
    $$\text{Threshold} = \text{autovacuum\_vacuum\_analyze\_threshold} + \text{autovacuum\_analyze\_scale\_factor} \times \text{n\_live\_tup}$$
  - For a table with 50,000,000 rows and the default `autovacuum_analyze_scale_factor = 0.10`, the database requires **5,000,000 inserted, updated, or deleted tuples** before triggering an automatic statistics refresh.
  - After large bulk ingestion pipelines, data backfills, or partition roll-ins, `pg_statistic` remains completely stale. The planner believes the table has 10,000 rows when it actually contains 3,000,000 rows.
  - The optimizer calculates an undersized hash table based on the stale count, allocates insufficient `work_mem`, and triggers catastrophic disk spills (`SortMethod: external merge Disk: 450000kB` or `Hash Batches: 128`), saturating disk I/O and creating query latency cliffs.
  - Invariant: Explicit post-migration and post-batch `ANALYZE <table>;` execution, alongside aggressive per-table tuning: `ALTER TABLE <table> SET (autovacuum_analyze_scale_factor = 0.02, autovacuum_analyze_threshold = 1000);`.

- **The "Default Statistics Target Blindness & Zipfian Skew Meltdown"**:
  - By default, `default_statistics_target = 100`. The engine samples at most 100 Most Common Values (MCVs) and computes 100 histogram quantiles.
  - High-cardinality attributes (e.g. user IDs, organization IDs, SKUs, category tags) frequently follow power-law or Zipfian distributions, where the top 100 values cover only 30% of total rows, leaving thousands of frequent keys unlisted in the MCV catalog.
  - When filtering by an unlisted frequent key, the planner falls back to a naive uniform distribution assumption across the histogram, vastly underestimating the matching cardinality (e.g. estimating 15 rows instead of 250,000).
  - The planner selects an un-buffered Index Scan that initiates 250,000 random page reads across the disk subsystem instead of an optimal Bitmap Heap Scan or Parallel Sequential Scan.
  - Invariant: Target-specific statistics enlargement: `ALTER TABLE <table> ALTER COLUMN <column> SET STATISTICS 1000;` on all primary filtering, grouping, and partition discriminator keys.

- **The "JIT Compilation Overhead Latency Spike in OLTP Workloads"**:
  - In PostgreSQL 11+, Just-In-Time (JIT) compilation is enabled by default (`jit = on`), with `jit_above_cost = 100000`, `jit_inline_above_cost = 500000`, and `jit_optimize_above_cost = 500000`.
  - In complex OLTP queries involving multiple joins, views, and expression evaluations, the estimated plan cost frequently crosses the 100,000 synthetic cost threshold.
  - PostgreSQL pauses execution to invoke LLVM to compile query expressions and tuple deforming into machine code. The LLVM compilation phase adds **25ms to 150ms** of synchronous CPU overhead.
  - The actual execution of the compiled plan takes only 1.5ms. The net query latency explodes by $20\times$ to $50\times$, purely attributable to JIT compilation tax on transactional paths.
  - Invariant: Enforce `jit = off` on OLTP workloads, reserving JIT strictly for long-running batch analytics and OLAP queries where total execution duration exceeds several seconds.

- **The "Storage Cost Model Mismatch & SSD Random I/O Penalty Trap"**:
  - PostgreSQL defaults `seq_page_cost = 1.0` and `random_page_cost = 4.0`. This 4:1 ratio was established for mechanical spinning hard disk drives (HDDs), where physical drive head seeks incurred severe physical latency.
  - On modern cloud NVMe SSDs, AWS EBS gp3/io2, and enterprise SANs, random I/O incurs zero mechanical seek latency. The true ratio between random page access and sequential page access is near parity ($1.05$ to $1.20$).
  - When `random_page_cost` remains at 4.0, the optimizer artificially inflates the estimated cost of B-tree index scans. For queries matching as little as 2% to 5% of a table, the optimizer rejects index scans in favor of a full sequential table scan.
  - Under concurrent load, sequential scans flood the buffer pool (`shared_buffers`), evicting hot cached pages and degrading cluster-wide read throughput.
  - Invariant: Mandatory hardware calibration: `ALTER SYSTEM SET random_page_cost = 1.1;` (or `1.0` if entire dataset resides in RAM/NVMe cache) and `ALTER SYSTEM SET effective_io_concurrency = 200;`.

- **The "Prepared Statement Generic Plan Drift & Parameter Sniffing Mirage"**:
  - Production database drivers (Go `pgx`, Java JDBC, Node.js `pg`, Python `psycopg`) execute parameterized queries via the PostgreSQL extended query protocol (`PREPARE` and `EXECUTE`).
  - By default, the engine generates custom plans tailored to parameter values for the first 5 executions. On the 6th execution, it computes a generic plan (independent of parameter values) and permanently switches to it if the generic plan cost is within threshold (`plan_cache_mode = auto`).
  - If parameter distributions are non-uniform (e.g. `tenant_id = 'small_tenant'` matches 10 rows, while `tenant_id = 'mega_corp'` matches 10,000,000 rows), the generic plan freezes an Index Scan optimal for small tenants.
  - When subsequently invoked with `tenant_id = 'mega_corp'`, the index scan performs millions of random lookups, freezing backend workers, triggering client timeouts, and cascading connection exhaustion across the service pool.
  - Invariant: Explicit driver-level or transaction-level plan cache mode governance: `SET plan_cache_mode = force_custom;` on skewed endpoints, or utilizing dynamic SQL un-prepared execution on high-variance parameters.

---

## 2. Mathematical Theorems & Formal Optimization Proofs

### Theorem 1: Attribute Value Independence (AVI) Cardinality Error Ratio

Let a query predicate filter on two attributes $A$ and $B$: $\mathcal{Q} \equiv \sigma_{A = v_a \land B = v_b}(R)$. Under the PostgreSQL default optimizer assumption of attribute value independence (AVI), the estimated selectivity $\widehat{S}$ is:

$$\widehat{S}_{\text{AVI}} = \mathbb{P}(A = v_a) \times \mathbb{P}(B = v_b) = S_A \times S_B$$

The true joint selectivity $S_{\text{true}}$ is governed by conditional probability:

$$S_{\text{true}} = \mathbb{P}(A = v_a \land B = v_b) = \mathbb{P}(A = v_a) \times \mathbb{P}(B = v_b \mid A = v_a) = S_A \times S_{B \mid A}$$

The Cardinality Error Ratio $\mathcal{E}_{\text{AVI}}$ is defined as:

$$\mathcal{E}_{\text{AVI}} = \frac{S_{\text{true}}}{\widehat{S}_{\text{AVI}}} = \frac{S_A \times S_{B \mid A}}{S_A \times S_B} = \frac{S_{B \mid A}}{S_B}$$

For functionally dependent or strongly correlated columns (e.g., $B \implies A$, where $S_{B \mid A} \approx 1$ while $S_B \ll 1$):

$$\mathcal{E}_{\text{AVI}} = \frac{1}{S_B}$$

When $S_B = 0.001$ ($0.1\%$ selectivity), the planner underestimates row cardinality by a factor of:

$$\mathcal{E}_{\text{AVI}} = \frac{1}{0.001} = 1,000\times$$

**Consequence for Join Selection**: The estimated cost of a Nested Loop join with inner index scan over $N$ outer rows is $\mathcal{O}(N_{\text{est}} \log M)$. If $N_{\text{est}} = 1$, the estimated cost is minimal, causing the optimizer to prefer Nested Loop over Hash Join ($\text{Cost}_{\text{hash}} = \mathcal{O}(N + M)$). The actual runtime cost scales with $N_{\text{true}} = 1000 \times N_{\text{est}}$, degrading performance by three orders of magnitude. Extended statistics (`CREATE STATISTICS (dependencies, mcv)`) stores the joint distribution table, eliminating $\mathcal{E}_{\text{AVI}}$ and forcing $\mathcal{E} \to 1.0$.

---

### Theorem 2: NVMe SSD Random Page Cost Convergence Calculus

Let total estimated I/O cost of an Index Scan reading $K$ candidate rows from a relation of $T$ tuples and $B$ heap pages be:

$$\text{Cost}_{\text{index}} = B_{\text{idx}} \times C_{\text{seq}} + B_{\text{heap\_rand}} \times C_{\text{rand}} + K \times C_{\text{cpu}}$$

where $B_{\text{heap\_rand}} = B \times \left(1 - \left(1 - \frac{1}{B}\right)^K\right)$ according to the Mackert-Lohman approximation.

Let the cost of a Sequential Scan over relation $R$ be:

$$\text{Cost}_{\text{seq}} = B \times C_{\text{seq}} + T \times C_{\text{cpu}}$$

The optimizer switches from Index Scan to Sequential Scan when $\text{Cost}_{\text{index}} > \text{Cost}_{\text{seq}}$, yielding the crossover selectivity threshold $\alpha^* = \frac{K^*}{T}$:

$$\alpha^* \approx \frac{B \times C_{\text{seq}} + T \times C_{\text{cpu}} - B_{\text{idx}} \times C_{\text{seq}}}{T \times C_{\text{cpu}} + B \times C_{\text{rand}}}$$

Assuming $B_{\text{idx}} \ll B$ and $C_{\text{cpu}} \approx 0.01$:

$$\alpha^* \propto \frac{C_{\text{seq}}}{C_{\text{rand}}}$$

Under default HDD settings where $C_{\text{seq}} = 1.0$ and $C_{\text{rand}} = 4.0$, the ratio is $\frac{1.0}{4.0} = 0.25$, causing the planner to abandon index scans at very low selectivities ($\alpha^* \approx 3\% - 5\%$).
On modern NVMe SSDs where hardware seek latency $\tau_{\text{seek}} \approx 0$, physical access cost satisfies $C_{\text{rand}} \approx 1.1 \times C_{\text{seq}}$.
Setting $C_{\text{rand}} = 1.1$ increases the crossover selectivity threshold to $\alpha^* \approx 25\% - 35\%$, allowing the planner to correctly utilize B-tree indexes for selective queries without regressing to sequential scans.

---

### Theorem 3: Dvoretzky-Kiefer-Wolfowitz Sample Size & Zipfian Bound

Let $F(x)$ be the true cumulative distribution function of an attribute and $F_n(x)$ be the empirical distribution function derived from a sample of size $n$. By the Dvoretzky-Kiefer-Wolfowitz (DKW) inequality:

$$\mathbb{P}\left(\sup_{x} |F_n(x) - F(x)| > \epsilon\right) \le 2 e^{-2n\epsilon^2}$$

For statistical confidence $1 - \delta$, the required sample size $n$ bounding error $\epsilon$ satisfies:

$$n \ge \frac{\ln(2/\delta)}{2\epsilon^2}$$

In PostgreSQL, the sample size $n$ drawn during `ANALYZE` is directly determined by the statistics target parameter $S$ ($S \in [1, 10000]$):

$$n = 300 \times S$$

At default $S = 100$, sample size is $n = 30,000$. For a table with $N = 10^8$ rows exhibiting a Zipfian distribution with exponent $s \ge 1.2$, low-frequency values in the heavy tail have occurrence probabilities $p_k \ll \frac{1}{30000}$, resulting in $\mathbb{P}(\text{tuple sampled}) \to 0$.
Increasing the target to $S = 1000$ scales the sample to $n = 300,000$ rows, reducing the maximum quantile estimation error $\epsilon$ by:

$$\frac{\epsilon_{1000}}{\epsilon_{100}} = \sqrt{\frac{100}{1000}} = \frac{1}{\sqrt{10}} \approx 0.316$$

This guarantees a **68.4% reduction in cardinality estimation error** across high-cardinality and skewed columns.

---

## 3. 5-Tier Statistics & Cost Model Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────┐
│               5-TIER STATISTICS & PLANNER GOVERNANCE LADDER            │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Continuous EXPLAIN (ANALYZE, BUFFERS) CI Regression Sentinel   │
│         - Ratio actual_rows / estimated_rows in [0.2, 5.0]             │
│         - Zero disk temporary buffer spill on production queries       │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Plan Cache Mode & CTE Materialization Invariants              │
│         - Dynamic SET plan_cache_mode = force_custom on skewed paths   │
│         - Explicit AS NOT MATERIALIZED on optimizer-fenced CTEs        │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Multivariate Extended Statistics (CREATE STATISTICS)           │
│         - (dependencies, ndistinct, mcv) on correlated predicates      │
│         - Immediate ANALYZE post-definition synchronization            │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Granular Per-Column Targets & Churn Autovacuum Tuning          │
│         - ALTER COLUMN ... SET STATISTICS 1000 on high-skew keys       │
│         - autovacuum_analyze_scale_factor = 0.02 (2% churn trigger)    │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Engine Hardware Calibration & OLTP JIT Deactivation            │
│         - random_page_cost = 1.1, seq_page_cost = 1.0 (NVMe SSD)       │
│         - effective_io_concurrency = 200, work_mem = 64MB-256MB        │
│         - ALTER SYSTEM SET jit = off (Zero OLTP LLVM latency penalty)  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Production TypeScript Verification Engine: `AgenticDatabaseStatisticsEngine`

```typescript
/**
 * AgenticDatabaseStatisticsEngine
 * Production-grade TypeScript validation engine enforcing PostgreSQL statistics,
 * extended multivariate statistics, NVMe cost calibration, and plan stability invariants.
 */

export interface QueryPlanNode {
  nodeType: string;
  relationName?: string;
  actualRows: number;
  planRows: number;
  actualTotalTime: number;
  sharedHitBlocks: number;
  sharedReadBlocks: number;
  tempReadBlocks: number;
  tempWrittenBlocks: number;
  plans?: QueryPlanNode[];
}

export interface ExplainAnalyzeOutput {
  plan: QueryPlanNode;
  planningTime: number;
  executionTime: number;
  jitEnabled?: boolean;
  jitTimeMs?: number;
}

export interface StatisticsAuditConfig {
  maxAllowedRowRatioVariance: number; // e.g. 5.0 (ratio > 5.0 or < 0.2 fails)
  maxAllowedTempBlocksWritten: number; // e.g. 0 (zero disk spill allowed)
  maxAllowedJitOverheadMs: number; // e.g. 5ms in OLTP paths
  expectedRandomPageCost: number; // e.g. 1.1 for NVMe SSDs
}

export interface ExtendedStatisticsProposal {
  tableName: string;
  statisticsName: string;
  columns: string[];
  kinds: ('dependencies' | 'ndistinct' | 'mcv')[];
  rationale: string;
}

export type StatisticsFSMState =
  | 'UNANALYZED'
  | 'ANALYZING'
  | 'CALIBRATED'
  | 'SKEW_DETECTED'
  | 'EXTENDED_STATS_BUILDING'
  | 'OPTIMIZED';

export class AgenticDatabaseStatisticsEngine {
  private state: StatisticsFSMState = 'UNANALYZED';

  constructor(private readonly config: StatisticsAuditConfig) {}

  public getState(): StatisticsFSMState {
    return this.state;
  }

  /**
   * Evaluates an EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) execution tree
   * detecting cardinality misestimations, temp disk spills, and JIT overheads.
   */
  public analyzeExecutionPlan(output: ExplainAnalyzeOutput): {
    passed: boolean;
    violations: string[];
    maxRowDivergence: number;
    totalTempWrittenBlocks: number;
  } {
    this.state = 'ANALYZING';
    const violations: string[] = [];
    let maxDivergence = 1.0;
    let totalTempWritten = 0;

    // Check JIT overhead in OLTP
    if (output.jitEnabled && (output.jitTimeMs ?? 0) > this.config.maxAllowedJitOverheadMs) {
      violations.push(
        `JIT compilation overhead (${output.jitTimeMs}ms) exceeds limit of ${this.config.maxAllowedJitOverheadMs}ms. Recommend setting jit = off.`
      );
    }

    const traverse = (node: QueryPlanNode) => {
      // Check temp buffer spills (sorting / hash join disk spilling)
      if (node.tempWrittenBlocks > 0) {
        totalTempWritten += node.tempWrittenBlocks;
        violations.push(
          `Node [${node.nodeType}] spilled ${node.tempWrittenBlocks} 8KB blocks to temporary disk! Increase work_mem.`
        );
      }

      // Check cardinality misestimation
      if (node.planRows > 0 && node.actualRows > 0) {
        const ratio = node.actualRows / node.planRows;
        const normalizedDivergence = ratio < 1 ? 1 / ratio : ratio;
        if (normalizedDivergence > maxDivergence) {
          maxDivergence = normalizedDivergence;
        }

        if (normalizedDivergence > this.config.maxAllowedRowRatioVariance) {
          violations.push(
            `Cardinality misestimation on [${node.nodeType}]: planned ${node.planRows} rows, but actual was ${node.actualRows} rows (divergence: ${normalizedDivergence.toFixed(2)}x).`
          );
        }
      }

      if (node.plans) {
        for (const child of node.plans) {
          traverse(child);
        }
      }
    };

    traverse(output.plan);

    const passed = violations.length === 0;
    if (maxDivergence > this.config.maxAllowedRowRatioVariance) {
      this.state = 'SKEW_DETECTED';
    } else if (passed) {
      this.state = 'OPTIMIZED';
    } else {
      this.state = 'CALIBRATED';
    }

    return {
      passed,
      violations,
      maxRowDivergence: maxDivergence,
      totalTempWrittenBlocks: totalTempWritten,
    };
  }

  /**
   * Generates SQL statements for multivariate extended statistics
   * to eliminate Attribute Value Independence (AVI) cardinality underestimation.
   */
  public generateExtendedStatisticsDDL(proposal: ExtendedStatisticsProposal): string[] {
    this.state = 'EXTENDED_STATS_BUILDING';
    const kindsStr = proposal.kinds.join(', ');
    const colsStr = proposal.columns.join(', ');

    return [
      `-- Eliminate correlated column cardinality misestimation on ${proposal.tableName}`,
      `CREATE STATISTICS IF NOT EXISTS ${proposal.statisticsName}`,
      `  ON (${kindsStr})`,
      `  FROM ${proposal.tableName} (${colsStr});`,
      `ANALYZE ${proposal.tableName};`,
    ];
  }

  /**
   * Generates standard PostgreSQL cost-calibration SQL for modern NVMe storage.
   */
  public generateHardwareCalibrationDDL(): string[] {
    return [
      `-- Modern NVMe / Cloud SSD Hardware Cost Calibration`,
      `ALTER SYSTEM SET seq_page_cost = 1.0;`,
      `ALTER SYSTEM SET random_page_cost = 1.1;`,
      `ALTER SYSTEM SET effective_io_concurrency = 200;`,
      `ALTER SYSTEM SET work_mem = '64MB';`,
      `ALTER SYSTEM SET hash_mem_multiplier = 2.0;`,
      `ALTER SYSTEM SET jit = off;`,
      `SELECT pg_reload_conf();`,
    ];
  }
}
```

---

## 5. Cross-Language Implementation Invariants

### 5.1. PostgreSQL Production Database Configuration & Extended Statistics

```sql
-- ============================================================================
-- 1. HARDWARE STORAGE COST & PLANNER ENGINE CALIBRATION (NVMe SSDs)
-- ============================================================================
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET seq_page_cost = 1.0;
ALTER SYSTEM SET effective_io_concurrency = 200;
ALTER SYSTEM SET work_mem = '64MB';
ALTER SYSTEM SET hash_mem_multiplier = 2.0;
ALTER SYSTEM SET jit = off; -- Eliminate 30ms-150ms LLVM compilation tax on OLTP
SELECT pg_reload_conf();

-- ============================================================================
-- 2. HIGH-CHURN AUTOVACUUM ANALYZE & TARGET HARDENING
-- ============================================================================
-- Increase sample target to 1000 on skewed, high-cardinality filtering columns
ALTER TABLE orders ALTER COLUMN customer_id SET STATISTICS 1000;
ALTER TABLE orders ALTER COLUMN status SET STATISTICS 500;

-- Trigger autovacuum analyze after 2% table churn instead of default 10%
ALTER TABLE orders SET (
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_analyze_threshold = 1000
);

-- ============================================================================
-- 3. MULTIVARIATE EXTENDED STATISTICS (CORRELATED COLUMNS)
-- ============================================================================
-- Eradicate Attribute Value Independence (AVI) underestimation on correlated predicates
CREATE STATISTICS IF NOT EXISTS stat_orders_status_tenant
  ON (dependencies, ndistinct, mcv)
  FROM orders (tenant_id, status);

CREATE STATISTICS IF NOT EXISTS stat_geo_locations
  ON (dependencies, mcv)
  FROM user_addresses (country_code, state_province, postal_code);

ANALYZE orders;
ANALYZE user_addresses;

-- ============================================================================
-- 4. CTE OPTIMIZATION FENCE AVOIDANCE (PostgreSQL 12+)
-- ============================================================================
-- By default in PG12+, unreferenced CTEs are inlined unless explicitly materialized.
-- Force inlining to allow the optimizer to push predicates into the CTE:
WITH filtered_events AS NOT MATERIALIZED (
  SELECT event_id, tenant_id, payload, created_at
  FROM domain_events
  WHERE created_at >= NOW() - INTERVAL '7 days'
)
SELECT * FROM filtered_events
WHERE tenant_id = 'c0a80101-0000-0000-0000-000000000001'::uuid
LIMIT 50;
```

---

### 5.2. Go (`jackc/pgx/v5`): Plan Stability & Explain Verifier

```go
package database

import (
	"context"
	"encoding/json"
	"fmt"
	"math"

	"github.com/jackc/pgx/v5/pgxpool"
)

type PlanNode struct {
	NodeType           string     `json:"Node Type"`
	RelationName       string     `json:"Relation Name,omitempty"`
	ActualRows         float64    `json:"Actual Rows"`
	PlanRows           float64    `json:"Plan Rows"`
	ActualTotalTime    float64    `json:"Actual Total Time"`
	SharedHitBlocks    int64      `json:"Shared Hit Blocks"`
	SharedReadBlocks   int64      `json:"Shared Read Blocks"`
	TempWrittenBlocks  int64      `json:"Temp Written Blocks"`
	Plans              []PlanNode `json:"Plans,omitempty"`
}

type ExplainPlanWrapper struct {
	Plan           PlanNode `json:"Plan"`
	PlanningTime   float64  `json:"Planning Time"`
	ExecutionTime  float64  `json:"Execution Time"`
	JITEnabled     bool     `json:"JIT,omitempty"`
}

type QueryPlanAuditResult struct {
	MaxDivergenceRatio float64
	TotalTempBlocks    int64
	ExecutionTimeMs    float64
	HasSpill           bool
	Violations         []string
}

// AuditQueryPlan executes EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) and asserts planner stability
func AuditQueryPlan(
	ctx context.Context,
	pool *pgxpool.Pool,
	sqlQuery string,
	maxAllowedVariance float64,
	args ...any,
) (*QueryPlanAuditResult, error) {
	explainSQL := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s", sqlQuery)

	var rawJSON []byte
	err := pool.QueryRow(ctx, explainSQL, args...).Scan(&rawJSON)
	if err != nil {
		return nil, fmt.Errorf("execute explain analyze: %w", err)
	}

	var wrappers []ExplainPlanWrapper
	if err := json.Unmarshal(rawJSON, &wrappers); err != nil {
		return nil, fmt.Errorf("unmarshal explain output: %w", err)
	}

	if len(wrappers) == 0 {
		return nil, fmt.Errorf("empty explain plan returned")
	}

	root := wrappers[0]
	result := &QueryPlanAuditResult{
		MaxDivergenceRatio: 1.0,
		ExecutionTimeMs:    root.ExecutionTime,
		Violations:         make([]string, 0),
	}

	var traverse func(node *PlanNode)
	traverse = func(node *PlanNode) {
		if node.TempWrittenBlocks > 0 {
			result.TotalTempBlocks += node.TempWrittenBlocks
			result.HasSpill = true
			result.Violations = append(result.Violations,
				fmt.Sprintf("Node [%s] spilled %d 8KB blocks to disk; work_mem insufficient",
					node.NodeType, node.TempWrittenBlocks))
		}

		if node.PlanRows > 0 && node.ActualRows > 0 {
			ratio := node.ActualRows / node.PlanRows
			normRatio := ratio
			if normRatio < 1.0 {
				normRatio = 1.0 / normRatio
			}

			if normRatio > result.MaxDivergenceRatio {
				result.MaxDivergenceRatio = normRatio
			}

			if normRatio > maxAllowedVariance {
				result.Violations = append(result.Violations,
					fmt.Sprintf("Cardinality divergence on [%s]: planned %.0f rows, actual %.0f rows (variance: %.2fx)",
						node.NodeType, node.PlanRows, node.ActualRows, normRatio))
			}
		}

		for i := range node.Plans {
			traverse(&node.Plans[i])
		}
	}

	traverse(&root.Plan)
	return result, nil
}
```

---

## 6. Machine-Verifiable 6-Gate Definition of Done (DoD) Matrix

| Gate | Verification Target | Formal Verification Invariant | Automated Enforcement Tooling |
| :--- | :--- | :--- | :--- |
| **Gate 1** | NVMe Storage Cost Calibration | `random_page_cost <= 1.2` AND `seq_page_cost == 1.0` | `SHOW random_page_cost;` in CI initialization |
| **Gate 2** | OLTP JIT Overhead Elimination | `jit = off` on transactional connection pools | `SHOW jit;` asserting `'off'` in pool health-checks |
| **Gate 3** | Churn-Aware Autovacuum Analyze | `autovacuum_analyze_scale_factor <= 0.05` on tables $>1\text{M}$ rows | `SELECT reloptions FROM pg_class` audit query |
| **Gate 4** | Extended Statistics Coverage | 100% of multi-predicate correlated queries have matching `pg_statistic_ext` | Automated query AST catalog introspection script |
| **Gate 5** | Temp Buffer Zero-Spill Invariant | `temp_written_blocks == 0` during `EXPLAIN (ANALYZE, BUFFERS)` | CI test-suite regression runner asserting zero spills |
| **Gate 6** | Cardinality Divergence Bounding | $\frac{\text{actual\_rows}}{\text{plan\_rows}} \in [0.2, 5.0]$ across all critical queries | `AgenticDatabaseStatisticsEngine.analyzeExecutionPlan` |

---

## 7. Operational Runbook & Disaster Recovery

### S1 Incident: Severe Query Freeze from Generic Plan Parameter Sniffing
1. **Immediate Mitigation**: Execute transaction-level or session-level custom plan forcing:
   ```sql
   ALTER ROLE app_user SET plan_cache_mode = force_custom;
   SELECT pg_reload_conf();
   ```
2. **Cardinality Verification**: Inspect `pg_stat_statements` for queries with anomalous `max_exec_time / mean_exec_time > 50`:
   ```sql
   SELECT query, calls, mean_exec_time, max_exec_time, stddev_exec_time
   FROM pg_stat_statements
   WHERE max_exec_time > 5000
   ORDER BY stddev_exec_time DESC
   LIMIT 10;
   ```
3. **Remediation**: Create multivariate extended statistics on the correlated parameter columns and execute `ANALYZE <table>;`.
