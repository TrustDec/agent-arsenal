---
description: PostgreSQL nested loop join execution, parameterized B-Tree index scan probing, cardinality underestimation defense, unindexed inner sequential scan elimination, materialize caching buffer fences, physical correlation random I/O mitigation, and correlated LATERAL top-K index alignment across Go (pgx/v5), TypeScript (Kysely, Drizzle, Prisma), Python (SQLAlchemy, asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{join,loop,nested,index,scan,plan,explain,query,lateral,cartesian,database,db,migration,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Nested Loop Joins, Parameterized Index Probes, Cardinality Underestimation Elimination, Materialize Caching & Cartesian Degradation Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design high-throughput transactional queries, point-lookup joins, correlated subqueries (`LATERAL`), pagination streams, or OLTP analytical pipelines across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Unindexed Inner Sequential Scan Catastrophe ($O(M \times N)$ Cartesian Degeneracy)" (where an unindexed inner join column forces PostgreSQL to execute a full sequential scan of the entire child relation for every outer row, turning a 2ms query into a 25-minute 100% CPU lockup that exhausts connection pools), the "Cardinality Underestimation Latency Cliff (The 1 Row Estimated vs 100,000 Actual Trap)" (where stale statistics, correlated predicates, or unanalyzed columns lead the query planner to estimate 1 outer row and select a Nested Loop with Index Scan, which at runtime explodes into 100,000 random I/O index seeks and heap fetches that wipe out `shared_buffers`), the "Unclustered Parameterized Random I/O Thrashing (Low Physical Correlation $\rho \approx 0$)" (where parameterized index probes against physically unclustered tables trigger non-sequential 8KB page fetches for every match, pinning NVMe storage controllers at 100% IOPS), the "Inner `Materialize` Node Buffer Disk Spill Trap" (where unindexed inner subplans cached by a `Materialize` node exceed `work_mem` and spill gigabytes to temporary disk files, amplifying I/O on every rescan), the "Correlated `LATERAL` Top-K Limit Bypass & Cartesian Blowup" (where missing `LIMIT` clauses or misordered composite index keys `(sort_col, fk)` instead of `(fk, sort_col)` force full partition scans on every iteration), and the "Parallel Gather Nested Loop Worker Serialization & Buffer Content Latch Storm" (where worker threads desynchronize or contend on the inner B-Tree root page latches) by establishing a strict 5-Tier Nested Loop Governance Ladder, formal nested loop and cardinality calculus, an autonomous TypeScript `AgenticNestedLoopGuardEngine`, cross-runtime implementations in Go, Python, and Rust, a 6-state optimization finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Nested Loop Join Catastrophes vs The 5-Tier Governance Ladder

A **Nested Loop Join** is the foundational iterative join algorithm in relational database engines. The executor iterates over an outer relation $R$ (the driving table), and for each emitted outer tuple, evaluates an inner relation $S$:
1. **The Parameterized Index Probe Path (`Nested Loop with Index Scan`)**: The outer row's join key is passed as a run-time parameter into an inner B-Tree index scan (`Index Scan using idx_s_on_fk on s (fk = r.id)`). For small outer cardinalities ($M \le 100$), this path executes in $O(M \log N)$ time with near-zero auxiliary memory, achieving sub-millisecond latencies for OLTP transactions.
2. **The Inner Sequential Scan Path (`Nested Loop with Seq Scan`)**: If the inner relation lacks an index on the join key (or the index is ignored due to non-Sargable predicates or type mismatches), the executor scans the *entire* inner relation from beginning to end for *every single outer row*. Computational complexity degrades to $O(M \times N)$ with catastrophic physical I/O.
3. **The Materialized Inner Path (`Nested Loop with Materialize`)**: When the inner relation is unparameterized but scanned multiple times, the planner inserts a `Materialize` node to memoize the inner tuples into memory. If the materialized set exceeds `work_mem`, intermediate pages spill to disk temporary files (`Temp Written Blocks > 0`), causing disk thrashing across rescans.

When properly indexed and planned with accurate cardinality statistics, Nested Loop Joins are the fastest physical join operator in PostgreSQL. However, when autonomous agents generate dynamic SQL, complex ORM joins, or batch reporting queries without verifying nested loop invariants, six catastrophic failure modes emerge:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               NAIVE NESTED LOOP JOIN vs PRODUCTION NESTED LOOP INVARIANTS               │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Unindexed inner relation join key       │ • Parameterized Index Scan Invariant:      │
│   (Engine performs Seq Scan on inner for  │   Inner join key backed by B-Tree index;   │
│    every outer row; O(M * N) collapse)    │   zero inner Seq Scan nodes in EXPLAIN plan│
│ • Cardinality underestimation trap        │ • Cardinality Error Ratio Bound (E/A):     │
│   (Planner expects 1 row, gets 100,000;   │   Extended statistics & fresh ANALYZE keep │
│    100,000 index seeks thrash cache)      │   |log10(Est / Act)| <= 1.0; no blind loops│
│ • Low physical correlation random I/O     │ • Physical Clustering & Bitmap Heap Guard: │
│   (Inner table unclustered; each probe    │   Require correlation >= 0.8, CLUSTER, or  │
│    fetches distinct 8KB heap page)        │   Index-Only Scan with clean Visibility Map│
│ • Materialize node temp disk spill        │ • Zero-Spill Materialize Buffer Ceiling:   │
│   (Materialized inner dataset > work_mem; │   work_mem sized to absorb inner dataset;  │
│    spills to disk temp_blks_written > 0)  │   assert Temp Written Blocks == 0 in plans │
│ • LATERAL Top-K wrong index column order  │ • Composite (FK, Sort DESC) Index Order:   │
│   (idx on (sort_col, fk) forces full child│   Leading column matches parent FK, trailing│
│    partition scans on every iteration)    │   matches ORDER BY; executes pure seeks    │
│ • Parallel worker B-Tree latch contention │ • Calibrated Parallel Nested Loop Workers: │
│   (Workers contend on inner index root;   │   Bound parallel workers per gather <= 4;  │
│    BufferContent LWLock stalls cluster)   │   prevent worker skew on outer relation    │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 5-Tier Nested Loop Governance Ladder

```
Level 4: CI Machine-Verifiable DoD Gates (EXPLAIN JSON zero inner Seq Scan & zero disk spills)
   ▲
Level 3: Correlated LATERAL Top-K Composite Index Alignment (Leading FK + trailing sort key)
   ▲
Level 2: Physical Layout Correlation & Heap Page Random I/O Defense (correlation >= 0.8)
   ▲
Level 1: Cardinality Estimation Error Ratio Bound (0.1 <= Est / Act <= 10.0; fresh statistics)
   ▲
Level 0: Parameterized Index Scan Prerequisite (Inner join key indexed; zero inner Seq Scan)
```

1. **Tier 0: Parameterized Index Scan Prerequisite**: Join columns on the inner relation must be covered by a selective B-Tree index (`Index Scan` or `Index Only Scan`). Under no circumstances may an inner child node execute an unindexed `Seq Scan` under a `Nested Loop`. If an index cannot be used, the query must be restructured into a `Hash Join` or `Merge Join`.
2. **Tier 1: Cardinality Estimation Error Ratio Bound**: Maintain fresh statistics (`ANALYZE`) and declare extended statistics (`CREATE STATISTICS ... (dependencies) ON col_a, col_b`) for correlated filter predicates. In CI test suites, assert that the outer relation's estimated row count vs actual row count ratio satisfies $0.1 \le \frac{E}{A} \le 10.0$. Prevent "1 row estimated vs 100,000 actual" planning catastrophes.
3. **Tier 2: Physical Layout Correlation & Heap Page Random I/O Defense**: For high-volume nested loops ($M \ge 5,000$), verify that the inner relation's physical correlation with the join key is high ($\text{correlation} \ge 0.80$ in `pg_stats`). If unclustered, deploy `Bitmap Index Scan` with dynamic bitmap page sorting, execute table clustering (`CLUSTER`), or enforce covering indexes (`INCLUDE`) for `Index Only Scan` execution with clean Visibility Maps.
4. **Tier 3: Correlated `LATERAL` Top-K Composite Index Alignment**: In correlated subqueries and `CROSS JOIN LATERAL` pipelines fetching top-$K$ child items per parent, mandate a composite B-Tree index where the leading column is the foreign key and trailing columns match the `ORDER BY` clause (e.g. `(parent_id, created_at DESC)`). The executor seeks directly to the $K$ rows per parent, avoiding partition sorting.
5. **Tier 4: CI Machine-Verifiable Plan Assertion Gates**: Enforce automated CI linting and test harness assertions on query execution plans via `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` to guarantee zero inner sequential scans, zero temporary disk blocks written (`Temp Written Blocks == 0`), and execution times adhering to strict p95 latency budgets.

---

## 2. Mathematical & Algorithmic Foundations

### 2.1 Nested Loop Join Physical Cost Models

Given an outer relation $R$ with $N_R$ tuples occupying $B_R$ pages, and an inner relation $S$ with $N_S$ tuples occupying $B_S$ pages:

#### Case A: Unindexed Sequential Scan (The Cartesian Disaster)
When the inner relation lacks an index on the join key, the executor performs a full scan of $S$ for each of the $N_R$ outer tuples:
$$\text{Cost}_{\text{NL-SeqScan}} = \text{Cost}_{\text{scan}}(R) + N_R \cdot \text{Cost}_{\text{scan}}(S) + (N_R \cdot N_S) \cdot \text{cpu\_tuple\_cost} + N_{\text{matches}} \cdot \text{cpu\_operator\_cost}$$

Expanding the disk page access cost where $B_R$ and $B_S$ are physical page counts:
$$\text{Cost}_{\text{NL-SeqScan}} \approx B_R \cdot \text{seq\_page\_cost} + N_R \cdot (B_S \cdot \text{seq\_page\_cost} + N_S \cdot \text{cpu\_tuple\_cost})$$

If $N_R = 10,000$ and $B_S = 50,000$ (a 400MB table), the engine attempts to read:
$$\text{Total Pages Scanned} = B_R + N_R \cdot B_S = B_R + 10,000 \times 50,000 = 500,000,000 \text{ pages} \approx 4.0 \text{ Terabytes of buffer accesses}$$

#### Case B: Parameterized B-Tree Index Probe (Production Optimum)
When the inner relation is indexed on the join key with B-Tree height $H_S = \lceil \log_{F}(N_S) \rceil$ (where $F$ is B-Tree node fanout $\approx 200–400$) and average matching rows per outer tuple $k = N_{\text{matches}} / N_R$:
$$\text{Cost}_{\text{NL-IndexScan}} = \text{Cost}_{\text{scan}}(R) + N_R \cdot (H_S \cdot \text{random\_page\_cost} + k \cdot (\text{cpu\_tuple\_cost} + \text{random\_page\_cost} \cdot (1 - \rho)))$$

Where $\rho \in [0, 1]$ represents the physical clustering correlation. When the root and branch pages reside in `shared_buffers`, the effective cost is dominated by $O(N_R \cdot H_S)$ cache hits and $O(N_R \cdot k)$ leaf/heap accesses.

#### Case C: Nested Loop with Materialize
When an unparameterized inner subplan is materialized into memory:
$$\text{Cost}_{\text{NL-Materialize}} = \text{Cost}_{\text{scan}}(R) + \text{Cost}_{\text{scan}}(S) + \text{Cost}_{\text{materialize\_initial}}(S) + (N_R - 1) \cdot \text{Cost}_{\text{materialize\_rescan}}(S)$$

If the materialized size $M_S = N_S \cdot W_S$ exceeds `work_mem`:
$$\text{Pages Spilled} = \left\lceil \frac{M_S - \text{work\_mem}}{8192} \right\rceil$$
The engine incurs physical write costs on the initial materialization pass and physical read costs on all $N_R - 1$ subsequent rescans:
$$\text{Disk I/O Penalty} = \text{Pages Spilled} \cdot (\text{seq\_page\_cost} + (N_R - 1) \cdot \text{seq\_page\_cost})$$

### 2.2 Unindexed Inner Scan Cartesian Degradation Theorem

**Theorem 1 (Cartesian Degradation Under Unindexed Loops)**:
Let $R$ and $S$ be two relations of cardinality $M = |R|$ and $N = |S|$. An unindexed nested loop join exhibits time complexity:
$$T(M, N) = \Theta(M \cdot N)$$

Whereas a Hash Join exhibits:
$$T_{\text{hash}}(M, N) = \Theta(M + N) \quad (\text{assuming single-batch in-memory})$$

And an index-backed Nested Loop exhibits:
$$T_{\text{idx}}(M, N) = \Theta(M \log N + M \cdot k)$$

**Corollary (Speedup Factor of Index Probes)**:
For $N = 10^6, M = 10^3, H \approx 3, k = 1$:
$$\text{Speedup} = \frac{\Theta(M \cdot N)}{\Theta(M \log N + M \cdot k)} = \frac{10^3 \cdot 10^6}{10^3 \cdot 3 + 10^3 \cdot 1} \approx \frac{10^9}{4 \cdot 10^3} = 250,000\times$$

An unindexed nested loop is over 250,000 times slower than a parameterized index probe on a one-million row relation.

### 2.3 Cardinality Underestimation Latency Cliff Calculus

The query optimizer chooses between Nested Loop, Hash Join, and Merge Join by minimizing total estimated cost. Let $E_R$ be the estimated cardinality of the outer relation, and $A_R$ be the actual runtime cardinality.

Define the **Cardinality Estimation Error Multiplier** $\gamma$:
$$\gamma = \frac{A_R}{E_R}$$

If the planner underestimates $E_R = 1$ due to correlated attributes or missing statistics, while $A_R = 50,000$ ($\gamma = 50,000$):
1. **At Planning Time**: The optimizer calculates:
   $$\text{Cost}_{\text{estimated}} = \text{Cost}(R) + 1 \cdot \text{Cost}_{\text{probe}}(S) \ll \text{Cost}_{\text{HashJoin}}(R, S)$$
   Because $1$ probe is infinitely cheaper than building a hash table of $S$ or sorting $S$, the planner selects `Nested Loop with Index Scan`.
2. **At Execution Time**: The executor must run $50,000$ index seeks:
   $$\text{Actual Execution Time} = T_R + 50,000 \cdot T_{\text{probe}}(S)$$
   If each random probe requires 0.5ms (uncached NVMe seek):
   $$\text{Total Time} = 50,000 \times 0.5\text{ms} = 25.0 \text{ seconds}$$
   Had the planner known $A_R = 50,000$, it would have selected a Hash Join or Bitmap Index Scan completing in $120\text{ms}$.

**The Log-Divergence Index $\mathcal{D}_{\text{card}}$**:
$$\mathcal{D}_{\text{card}} = \left| \log_{10} \left( \frac{\max(A_R, 1)}{\max(E_R, 1)} \right) \right|$$
- $\mathcal{D}_{\text{card}} \le 0.5$: Safe, high-accuracy estimation.
- $0.5 < \mathcal{D}_{\text{card}} \le 1.0$: Moderate divergence, acceptable for small loops.
- $\mathcal{D}_{\text{card}} > 1.0$: **Severe Cardinality Cliff** (over 10x error). Triggers query plan inversion and must be remediated via `ANALYZE` or `CREATE STATISTICS`.

### 2.4 Index Physical Correlation & Random Heap Page I/O Equation

In a parameterized index scan, fetching an inner tuple requires an index page seek followed by a heap page read.

According to the **Mackert & Lohman I/O Model**, the expected number of distinct heap pages accessed ($B_{\text{accessed}}$) when retrieving $k$ tuples from a table of $N$ tuples stored across $B$ pages depends on the physical correlation $\rho \in [-1, 1]$ recorded in `pg_stats.correlation`:

$$\text{Pages}(k, B, N, \rho) = (1 - |\rho|) \cdot \text{Yao}(k, B, N) + |\rho| \cdot \left\lceil \frac{k \cdot B}{N} \right\rceil$$

Where $\text{Yao}(k, B, N)$ is Yao's exact formula for random I/O block fetching:
$$\text{Yao}(k, B, N) = B \cdot \left( 1 - \prod_{i=1}^k \frac{N - \frac{N}{B} - i + 1}{N - i + 1} \right) \approx B \cdot \left( 1 - \left(1 - \frac{1}{B}\right)^k \right)$$

- When $|\rho| \approx 1.0$ (perfect physical clustering): Tuples with contiguous join keys reside on identical 8KB heap pages. Fetching $k$ tuples requires only $\lceil k \cdot B / N \rceil$ page accesses (often just 1 or 2 pages).
- When $|\rho| \approx 0.0$ (random physical scatter): Every single matching tuple resides on a different 8KB heap page. Fetching 10,000 tuples triggers up to 10,000 distinct page accesses, causing catastrophic cache churn.

---

## 3. Concrete Implementation: TypeScript `AgenticNestedLoopGuardEngine`

The following production-ready TypeScript engine analyzes PostgreSQL execution plans (`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`), detects unindexed inner sequential scans, identifies cardinality underestimation divergence, verifies `Materialize` node disk spillage, and enforces machine-verifiable Definition of Done gates.

```typescript
import { z } from 'zod';

export interface PlanNode {
  'Node Type': string;
  'Relation Name'?: string;
  'Alias'?: string;
  'Startup Cost': number;
  'Total Cost': number;
  'Plan Rows': number;
  'Plan Width': number;
  'Actual Rows'?: number;
  'Actual Loops'?: number;
  'Actual Total Time'?: number;
  'Shared Hit Blocks'?: number;
  'Shared Read Blocks'?: number;
  'Temp Read Blocks'?: number;
  'Temp Written Blocks'?: number;
  'Inner Unique'?: boolean;
  'Plans'?: PlanNode[];
  [key: string]: unknown;
}

export interface NestedLoopAuditResult {
  hasNestedLoop: boolean;
  innerSeqScanDetected: boolean;
  offendingRelations: string[];
  maxCardinalityDivergence: number;
  underestimatedNode?: {
    nodeType: string;
    relationName?: string;
    planRows: number;
    actualRows: number;
    divergenceFactor: number;
  };
  materializeSpillDetected: boolean;
  tempWrittenBlocks: number;
  totalNestedLoopNodes: number;
  isCompliant: boolean;
  severity: 'OK' | 'WARNING' | 'CRITICAL';
  recommendations: string[];
}

export class AgenticNestedLoopGuardEngine {
  private readonly maxAllowedDivergence: number;
  private readonly maxAllowedLoopsForSeqScan: number;

  constructor(options: { maxAllowedDivergence?: number; maxAllowedLoopsForSeqScan?: number } = {}) {
    this.maxAllowedDivergence = options.maxAllowedDivergence ?? 5.0; // 5x error threshold
    this.maxAllowedLoopsForSeqScan = options.maxAllowedLoopsForSeqScan ?? 1; // Never permit inner seq scans with >1 loops
  }

  /**
   * Parses and audits an EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) execution plan.
   */
  public auditExecutionPlan(planJson: string | object): NestedLoopAuditResult {
    const rawData = typeof planJson === 'string' ? JSON.parse(planJson) : planJson;
    const rootPlan: PlanNode = Array.isArray(rawData) ? rawData[0]?.Plan : (rawData as any)?.Plan;

    if (!rootPlan) {
      throw new Error('Invalid EXPLAIN JSON format: Missing root Plan node');
    }

    let hasNestedLoop = false;
    let innerSeqScanDetected = false;
    const offendingRelations: string[] = [];
    let maxCardinalityDivergence = 1.0;
    let worstUnderestimatedNode: NestedLoopAuditResult['underestimatedNode'] = undefined;
    let materializeSpillDetected = false;
    let tempWrittenBlocks = 0;
    let totalNestedLoopNodes = 0;
    const recommendations: string[] = [];

    const traverse = (node: PlanNode, parentNode?: PlanNode, isInnerChild: boolean = false) => {
      const nodeType = node['Node Type'];

      if (nodeType === 'Nested Loop') {
        hasNestedLoop = true;
        totalNestedLoopNodes++;
      }

      // Check for unindexed inner sequential scan catastrophe
      if (isInnerChild && (nodeType === 'Seq Scan' || nodeType === 'Bitmap Heap Scan')) {
        const actualLoops = node['Actual Loops'] ?? 1;
        if (actualLoops > this.maxAllowedLoopsForSeqScan) {
          innerSeqScanDetected = true;
          const relName = node['Relation Name'] || node['Alias'] || 'unknown_relation';
          if (!offendingRelations.includes(relName)) {
            offendingRelations.push(relName);
          }
          recommendations.push(
            `CRITICAL: Unindexed inner ${nodeType} on '${relName}' executed ${actualLoops} times inside Nested Loop. ` +
            `Create a selective B-Tree index on the foreign key/join column immediately.`
          );
        }
      }

      // Check for Materialize node disk spills
      if (nodeType === 'Materialize') {
        const tw = node['Temp Written Blocks'] ?? 0;
        if (tw > 0) {
          materializeSpillDetected = true;
          recommendations.push(
            `CRITICAL: Materialize node spilled ${tw} temporary blocks (${(tw * 8) / 1024} MB) to disk. ` +
            `Increase transaction work_mem or index the underlying relation to eliminate caching.`
          );
        }
      }

      // Accumulate temporary disk blocks written
      const nodeTempWritten = node['Temp Written Blocks'] ?? 0;
      tempWrittenBlocks += nodeTempWritten;

      // Check Cardinality Divergence on outer loop driving tables
      if (node['Actual Rows'] !== undefined && node['Plan Rows'] !== undefined) {
        const act = Math.max(node['Actual Rows'], 1);
        const est = Math.max(node['Plan Rows'], 1);
        const divergenceFactor = act > est ? act / est : est / act;

        if (divergenceFactor > maxCardinalityDivergence) {
          maxCardinalityDivergence = divergenceFactor;
          worstUnderestimatedNode = {
            nodeType: node['Node Type'],
            relationName: node['Relation Name'] || node['Alias'],
            planRows: node['Plan Rows'],
            actualRows: node['Actual Rows'],
            divergenceFactor: parseFloat(divergenceFactor.toFixed(2)),
          };
        }
      }

      // Traverse children with inner/outer identification
      if (Array.isArray(node.Plans) && node.Plans.length > 0) {
        for (let i = 0; i < node.Plans.length; i++) {
          const child = node.Plans[i];
          // For Nested Loop nodes, index 0 is outer relation, index 1 is inner relation
          const isInner = nodeType === 'Nested Loop' && i === 1;
          traverse(child, node, isInner);
        }
      }
    };

    traverse(rootPlan);

    // Evaluate cardinality divergence severity
    if (maxCardinalityDivergence > this.maxAllowedDivergence && worstUnderestimatedNode) {
      recommendations.push(
        `WARNING: Severe cardinality estimation error detected on ${worstUnderestimatedNode.nodeType} ` +
        `('${worstUnderestimatedNode.relationName || 'unknown'}'): estimated ${worstUnderestimatedNode.planRows} rows, ` +
        `actual ${worstUnderestimatedNode.actualRows} rows (${worstUnderestimatedNode.divergenceFactor}x divergence). ` +
        `Run 'ANALYZE ${worstUnderestimatedNode.relationName || ''};' or add extended statistics.`
      );
    }

    const isCompliant = !innerSeqScanDetected && !materializeSpillDetected && tempWrittenBlocks === 0;
    const severity: NestedLoopAuditResult['severity'] = (!isCompliant || innerSeqScanDetected)
      ? 'CRITICAL'
      : maxCardinalityDivergence > this.maxAllowedDivergence
      ? 'WARNING'
      : 'OK';

    return {
      hasNestedLoop,
      innerSeqScanDetected,
      offendingRelations,
      maxCardinalityDivergence: parseFloat(maxCardinalityDivergence.toFixed(2)),
      underestimatedNode: worstUnderestimatedNode,
      materializeSpillDetected,
      tempWrittenBlocks,
      totalNestedLoopNodes,
      isCompliant,
      severity,
      recommendations,
    };
  }

  /**
   * Asserts machine-verifiable Definition of Done compliance. Throws if critical violations occur.
   */
  public assertDoDCompliance(planJson: string | object): void {
    const audit = this.auditExecutionPlan(planJson);

    if (audit.innerSeqScanDetected) {
      throw new Error(
        `[DoD Gate 1 Failure] Unindexed inner sequential scan detected in Nested Loop against relations: ` +
        `${audit.offendingRelations.join(', ')}. Query degraded to O(M * N) Cartesian complexity.`
      );
    }

    if (audit.materializeSpillDetected || audit.tempWrittenBlocks > 0) {
      throw new Error(
        `[DoD Gate 2 Failure] Materialize node disk spill detected: ${audit.tempWrittenBlocks} blocks written to disk. ` +
        `Increase work_mem or provide indexed access paths.`
      );
    }

    if (audit.maxCardinalityDivergence > 50.0 && audit.underestimatedNode) {
      throw new Error(
        `[DoD Gate 3 Failure] Extreme cardinality divergence (${audit.maxCardinalityDivergence}x) on ` +
        `${audit.underestimatedNode.relationName}. Refresh table statistics via ANALYZE.`
      );
    }
  }
}
```

---

## 4. Cross-Runtime Implementations

### 4.1 Go (`jackc/pgx/v5`) Production Implementation

In high-throughput Go microservices, database calls must verify that parameterized queries utilize inner index seeks rather than sequential scans. The following `NestedLoopGovernor` executes queries with safety timeouts and plan assertion gates:

```go
package dbgovernor

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type NestedLoopGovernor struct {
	Pool *pgxpool.Pool
}

type ExplainNode struct {
	NodeType          string        `json:"Node Type"`
	RelationName      string        `json:"Relation Name,omitempty"`
	Alias             string        `json:"Alias,omitempty"`
	PlanRows          float64       `json:"Plan Rows"`
	ActualRows        float64       `json:"Actual Rows"`
	ActualLoops       float64       `json:"Actual Loops"`
	TempWrittenBlocks int64         `json:"Temp Written Blocks"`
	Plans             []ExplainNode `json:"Plans,omitempty"`
}

type ExplainRoot struct {
	Plan ExplainNode `json:"Plan"`
}

// AuditNestedLoopPlan executes EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) and asserts zero inner sequential scans
func (g *NestedLoopGovernor) AuditNestedLoopPlan(ctx context.Context, sqlQuery string, args ...any) error {
	explainSQL := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s", sqlQuery)

	ctxTimeout, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var rawJSON []byte
	err := g.Pool.QueryRow(ctxTimeout, explainSQL, args...).Scan(&rawJSON)
	if err != nil {
		return fmt.Errorf("explain execution failed: %w", err)
	}

	var roots []ExplainRoot
	if err := json.Unmarshal(rawJSON, &roots); err != nil || len(roots) == 0 {
		return fmt.Errorf("failed to parse explain json: %w", err)
	}

	root := roots[0].Plan
	hasInnerSeqScan := false
	var offendingRel string
	var tempWritten int64

	var inspect func(node ExplainNode, isInner bool)
	inspect = func(node ExplainNode, isInner bool) {
		if isInner && node.NodeType == "Seq Scan" && node.ActualLoops > 1 {
			hasInnerSeqScan = true
			offendingRel = node.RelationName
		}
		tempWritten += node.TempWrittenBlocks

		for i, child := range node.Plans {
			isChildInner := (node.NodeType == "Nested Loop" && i == 1)
			inspect(child, isChildInner)
		}
	}

	inspect(root, false)

	if hasInnerSeqScan {
		return fmt.Errorf("nested loop invariant violation: unindexed Seq Scan on '%s' across multiple loops", offendingRel)
	}
	if tempWritten > 0 {
		return fmt.Errorf("nested loop invariant violation: temp written blocks = %d (materialize spill)", tempWritten)
	}

	return nil
}

// ExecuteWithCardinalityProtection runs a query with localized lock_timeout and statement_timeout
func (g *NestedLoopGovernor) ExecuteWithCardinalityProtection(
	ctx context.Context,
	fn func(tx pgx.Tx) error,
) error {
	tx, err := g.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Bounded guardrails against unindexed Cartesian blowups
	guards := []string{
		"SET LOCAL statement_timeout = '3000ms'",
		"SET LOCAL lock_timeout = '1000ms'",
	}
	for _, guard := range guards {
		if _, err := tx.Exec(ctx, guard); err != nil {
			return fmt.Errorf("apply safety guard: %w", err)
		}
	}

	if err := fn(tx); err != nil {
		return err
	}

	return tx.Commit(ctx)
}
```

### 4.2 Python (`SQLAlchemy 2.0` / `asyncpg`) Production Implementation

In asynchronous Python backends, the following guard engine audits execution plans and prevents Cartesian loops:

```python
from typing import Any, Dict, List, Optional
import json
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

class NestedLoopGuard:
    def __init__(self, session: AsyncSession, max_allowed_divergence: float = 10.0):
        self.session = session
        self.max_allowed_divergence = max_allowed_divergence

    async def verify_nested_loop_plan(self, query_sql: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        explain_sql = f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {query_sql}"
        result = await self.session.execute(text(explain_sql), params or {})
        plan_json = result.scalar()
        root = plan_json[0]["Plan"]

        metrics = {
            "has_nested_loop": False,
            "inner_seq_scan_detected": False,
            "offending_relations": [],
            "temp_written_blocks": 0,
            "max_divergence": 1.0,
        }

        def traverse(node: Dict[str, Any], is_inner: bool = False):
            node_type = node.get("Node Type", "")
            if node_type == "Nested Loop":
                metrics["has_nested_loop"] = True

            actual_loops = node.get("Actual Loops", 1)
            if is_inner and node_type in ("Seq Scan", "Bitmap Heap Scan") and actual_loops > 1:
                metrics["inner_seq_scan_detected"] = True
                rel_name = node.get("Relation Name", "unknown")
                metrics["offending_relations"].append(rel_name)

            metrics["temp_written_blocks"] += node.get("Temp Written Blocks", 0)

            # Cardinality check
            plan_rows = max(node.get("Plan Rows", 1), 1)
            actual_rows = max(node.get("Actual Rows", 1), 1)
            ratio = max(actual_rows / plan_rows, plan_rows / actual_rows)
            if ratio > metrics["max_divergence"]:
                metrics["max_divergence"] = ratio

            plans = node.get("Plans", [])
            for i, child in enumerate(plans):
                is_child_inner = (node_type == "Nested Loop" and i == 1)
                traverse(child, is_child_inner)

        traverse(root, False)

        if metrics["inner_seq_scan_detected"]:
            raise RuntimeError(
                f"Cartesian Violation: Unindexed inner sequential scan detected on {metrics['offending_relations']} "
                f"inside Nested Loop. Index foreign keys immediately."
            )

        if metrics["temp_written_blocks"] > 0:
            raise RuntimeError(
                f"Materialize Spill Violation: Temp written blocks = {metrics['temp_written_blocks']}. "
                f"Increase work_mem or index the inner subplan."
            )

        return metrics
```

### 4.3 Rust (`sqlx`) Production Implementation

In high-concurrency Rust services using `sqlx` and `tokio-postgres`:

```rust
use sqlx::{PgPool, Error as SqlxError};
use serde_json::Value;

pub struct NestedLoopGuard {
    pool: PgPool,
}

impl NestedLoopGuard {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn assert_zero_inner_seq_scan(&self, query_sql: &str) -> Result<(), Box<dyn std::error::Error>> {
        let explain_sql = format!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {}", query_sql);
        let row: (Value,) = sqlx::query_as(&explain_sql)
            .fetch_one(&self.pool)
            .await?;

        let plan_root = &row.0[0]["Plan"];
        let mut stack: Vec<(&Value, bool)> = vec![(plan_root, false)];
        let mut temp_written_blocks: i64 = 0;

        while let Some((node, is_inner)) = stack.pop() {
            let node_type = node.get("Node Type").and_then(|v| v.as_str()).unwrap_or("");
            let actual_loops = node.get("Actual Loops").and_then(|v| v.as_f64()).unwrap_or(1.0);

            if is_inner && node_type == "Seq Scan" && actual_loops > 1.0 {
                let rel = node.get("Relation Name").and_then(|v| v.as_str()).unwrap_or("unknown");
                return Err(format!(
                    "Nested Loop Cartesian Invariant Failed: Unindexed inner Seq Scan on relation '{}' across {} loops",
                    rel, actual_loops
                ).into());
            }

            if let Some(tw) = node.get("Temp Written Blocks").and_then(|v| v.as_i64()) {
                temp_written_blocks += tw;
            }

            if let Some(children) = node.get("Plans").and_then(|v| v.as_array()) {
                for (i, child) in children.iter().enumerate() {
                    let is_child_inner = node_type == "Nested Loop" && i == 1;
                    stack.push((child, is_child_inner));
                }
            }
        }

        if temp_written_blocks > 0 {
            return Err(format!(
                "Materialize Spill Violation: {} temp blocks written to disk",
                temp_written_blocks
            ).into());
        }

        Ok(())
    }
}
```

---

## 5. Six-State Nested Loop Join Optimization Finite-State Machine (FSM)

```
 [S0: JOIN PREDICATE & ACCESS AUDIT]
          │
          ▼ (Identify join keys & inner relation)
 [S1: INNER INDEX SARGABILITY VERIFICATION]
   ├── [Indexed B-Tree Probe Available] ──► [S2: CARDINALITY ESTIMATION BOUNDING]
   └── [Unindexed Inner Relation]
          │
          ▼ (Fatal: O(M * N) Cartesian Degeneracy)
 [S1.1: CREATE CONCURRENT INDEX MIGRATION]
          │
          ▼
 [S2: CARDINALITY ESTIMATION BOUNDING]
   ├── [0.1 <= Est / Act <= 10.0] ────────► [S3: CLUSTERING & RANDOM I/O PROFILING]
   └── [Severe Divergence: Est << Act]
          │
          ▼ (Trigger ANALYZE or CREATE STATISTICS)
 [S2.1: STATISTICS REFRESH & EXTENDED CORRELATION]
          │
          ▼
 [S3: CLUSTERING & RANDOM I/O PROFILING]
   ├── [Correlation >= 0.8 OR Index-Only Scan] ──► [S4: LATERAL TOP-K COMPOSITE INDEX]
   └── [Low Correlation: rho < 0.8 & Large Loop]
          │
          ▼ (Switch to Bitmap Scan or CLUSTER table)
 [S3.1: BITMAP HEAP CONVERSION OR CLUSTER]
          │
          ▼
 [S4: LATERAL TOP-K COMPOSITE INDEX ALIGNMENT]
          │ (Ensure (parent_fk, sort_col DESC) ordering)
          ▼
 [S5: ZERO-SPILL MATERIALIZE VERIFICATION]
          │ (Confirm Temp Written Blocks == 0)
          ▼
 [S6: CI EXPLAIN GATE VERIFICATION] ──────► [PRODUCTION COMPLETE]
```

- **S0: JOIN PREDICATE & ACCESS AUDIT**: Identify the driving (outer) relation and probe (inner) relation. Verify whether the join predicate is an equijoin or range join.
- **S1: INNER INDEX SARGABILITY VERIFICATION**: Check `pg_indexes` for a matching B-Tree index on the inner relation's join attributes. Verify that join keys share identical data types (e.g. `bigint` to `bigint`) to prevent implicit casting that invalidates B-Tree index scans.
- **S1.1: CREATE CONCURRENT INDEX MIGRATION**: If the inner relation is unindexed, generate an online migration using `CREATE INDEX CONCURRENTLY idx_rel_on_fk ON rel (fk)` guarded by `lock_timeout = 2000ms`.
- **S2: CARDINALITY ESTIMATION BOUNDING**: Compare `Plan Rows` vs `Actual Rows` for the outer relation. If the planner expects 1 row but the query returns 10,000, trigger state **S2.1**.
- **S2.1: STATISTICS REFRESH & EXTENDED CORRELATION**: Run `ANALYZE` on the driving table. If predicates are correlated (e.g. `status = 'ACTIVE' AND tenant_id = 42`), create extended statistics (`CREATE STATISTICS st_corr (dependencies) ON status, tenant_id FROM table`).
- **S3: CLUSTERING & RANDOM I/O PROFILING**: Query `pg_stats` for the inner column's `correlation`. If $\rho < 0.8$ and outer rows $M > 5,000$, verify whether a `Bitmap Index Scan` batches heap fetches to eliminate NVMe random seeks.
- **S4: LATERAL TOP-K COMPOSITE INDEX ALIGNMENT**: For `CROSS JOIN LATERAL` or correlated subqueries with `ORDER BY ... LIMIT K`, assert that the inner relation has a composite index with the foreign key as the leading attribute and the sorting attribute as the trailing attribute.
- **S5: ZERO-SPILL MATERIALIZE VERIFICATION**: If a `Materialize` node is present, verify that `Temp Written Blocks == 0`. If spillage occurs, increase transaction-scoped `SET LOCAL work_mem` or index the underlying relation to eliminate materialization.
- **S6: CI EXPLAIN GATE VERIFICATION**: Run automated test assertions via `AgenticNestedLoopGuardEngine` to confirm zero inner sequential scans, acceptable cardinality divergence, and zero disk temp files.

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Metric / Assertion | Failure Remediation |
|---|---|---|---|
| **Gate 1** | Parameterized Inner Index Probe | Zero `Seq Scan` on inner loop child (`Actual Loops > 1`) | Add `CREATE INDEX CONCURRENTLY` on inner relation join attributes |
| **Gate 2** | Zero Materialize Disk Spills | `Temp Written Blocks == 0` on all `Materialize` nodes | Calibrate `SET LOCAL work_mem` or eliminate materialization via indexing |
| **Gate 3** | Cardinality Divergence Bound | Log divergence $\mathcal{D}_{\text{card}} \le 1.0$ ($0.1 \le \frac{E}{A} \le 10.0$) | Execute `ANALYZE` or create multivariate `CREATE STATISTICS` |
| **Gate 4** | Sargable Data Type Parity | No implicit type casting functions on join predicates | Align column types across relations (e.g., matching `int4` or `int8`) |
| **Gate 5** | LATERAL Top-K Index Congruence | Direct `Index Scan` seeking without in-loop `Sort` | Composite index matching `(parent_id, order_column DESC)` |
| **Gate 6** | Automated CI EXPLAIN Gate | Machine-verifiable JSON audit passes via `AgenticNestedLoopGuardEngine` | Block PR merges if inner sequential scans or disk spills are detected |

By enforcing this 5-Tier Nested Loop Governance Ladder, autonomous agents design lightning-fast transactional queries that harness parameterized B-Tree index probes, eliminate catastrophic $O(M \times N)$ sequential loops, prevent cardinality underestimation cliffs, and protect database clusters from NVMe write thrashing and connection pool exhaustion.
