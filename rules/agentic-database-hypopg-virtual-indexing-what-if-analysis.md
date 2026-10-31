---
description: PostgreSQL HypoPG virtual index simulation (CREATE EXTENSION hypopg), what-if query plan evaluation, cost reduction calculus, non-destructive index recommendation, knapsack storage budgeting, and zero-downtime migration generation across Go (jackc/pgx/v5), TypeScript (pg, kysely, drizzle-orm), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{hypopg,index,advisor,virtual_index,explain,query_optimizer,cost_model,what_if,sql,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database HypoPG, Virtual Index Simulation, What-If Query Plan Evaluation & Non-Destructive Recommendation Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to analyze slow SQL queries, optimize database access patterns, evaluate composite indexing hypotheses, and recommend database performance migrations across PostgreSQL (11–17+) in Go (`jackc/pgx/v5`), TypeScript (`pg`, `kysely`, `drizzle-orm`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Destructive Production DDL Hallucination Catastrophe" (where agents blindly execute `CREATE INDEX` or `CREATE INDEX CONCURRENTLY` directly on multi-gigabyte production tables without knowing if the query planner will actually adopt the index, locking out DDL, generating tens of gigabytes of WAL spikes, and causing replication lag), the "`EXPLAIN ANALYZE` on Virtual Index Blindness Trap" (where agents run `EXPLAIN ANALYZE` instead of `EXPLAIN` on hypothetical indexes, triggering execution engine crashes or silent fallback to physical sequential scans because hypothetical pages do not physically exist on disk), the "Multi-Hypothesis Memory & Relcache Bleed" (where agents test dozens of hypothetical indexes in a single long-lived connection without issuing `SELECT hypopg_reset()`, bloating PostgreSQL backend `relcache` structures and corrupting subsequent planning decisions), the "Knapsack Storage Budget Blindness" (where agents recommend 15 different indexes for slight latency improvements without projecting cumulative disk consumption, eventually inducing 100% disk full panics), the "Cardinality Drift & Missing Table Statistics Mirage" (where agents test HypoPG on newly created or truncated staging tables lacking `ANALYZE` statistics, prompting the optimizer to reject ideal indexes due to default 10-page / 1000-row heuristics), and the "Transaction Pooler Leak & Cross-Session Virtual Index Pollution" (where connections through PgBouncer in session mode leave dangling virtual indexes that alter query plans for unrelated client traffic) by establishing a strict 5-Tier HypoPG Governance Ladder, formal cost reduction theorems, index footprint estimation calculus, multi-query workload knapsack optimization models, a production-ready TypeScript `AgenticHypoPGGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Virtual Indexing Catastrophes vs The 5-Tier Governance Ladder

When engineering autonomous coding agents to resolve database latency bottlenecks or N+1 query regressions, agents face a dangerous dilemma. Testing whether an index resolves a slow query traditionally requires creating the index physically on disk:
$$\text{Cost}(\text{Physical Create}) = \mathcal{O}(N \log N) \text{ CPU} + \mathcal{O}(N) \text{ Disk I/O} + \mathcal{O}(N) \text{ WAL}$$

On large tables (10M–500M rows), running physical `CREATE INDEX CONCURRENTLY`:
1. Requires minutes to hours of intensive disk read/write bandwidth.
2. Consumes gigabytes of RAM in `maintenance_work_mem`.
3. Emits massive streams of Write-Ahead Logs (WAL), saturating replication links and starving hot standby replicas.
4. Holds long-lived lock queues that prevent subsequent DDL operations.
5. If the proposed index turns out to be ineffective (e.g., wrong leftmost column, low selectivity, or optimizer preference for Hash Join), all spent I/O and storage are entirely wasted.

PostgreSQL solves this with **HypoPG** (`CREATE EXTENSION hypopg;`), an extension that allows backend processes to create **hypothetical (virtual) indexes**:
- **Zero Disk Footprint**: Consumes $0$ bytes on NVMe/SSD storage.
- **Zero WAL Overhead**: Generates $0$ bytes of Write-Ahead Log records.
- **Sub-Millisecond Creation**: Injects an ephemeral catalog entry directly into the backend process's `relcache` in $< 1\text{ms}$.
- **Full Optimizer Participation**: PostgreSQL's query planner (`optimizer`) fully recognizes hypothetical indexes during `EXPLAIN (FORMAT JSON)` and evaluates candidate paths using existing table statistics (`pg_class.reltuples`, `pg_stats`).
- **Connection Isolation**: Virtual indexes exist strictly within the current client backend process memory and are completely invisible to other concurrent connections.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             REAL INDEX CREATION vs HYPOPG VIRTUAL INDEX SIMULATION                     │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         PHYSICAL INDEX CREATION           │        HYPOPG VIRTUAL INDEX SIMULATION     │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Execution Time: 5 to 120 minutes        │ • Execution Time: < 1 millisecond          │
│ • Disk Storage: 5GB to 100GB+ NVMe        │ • Disk Storage: 0 bytes (Process RAM only) │
│ • WAL Traffic: Massive WAL generation     │ • WAL Traffic: 0 bytes (No WAL emission)   │
│ • Replica Impact: Replica replay lag      │ • Replica Impact: 0 impact (Session local) │
│ • Concurrency: Acquires ShareUpdateLocks  │ • Concurrency: 0 lock contention on engine │
│ • Rollback: Destructive DROP INDEX required│ • Rollback: Instant SELECT hypopg_reset()  │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

Despite these advantages, autonomous coding agents routinely make fatal mistakes when interacting with HypoPG:

### The 6 Virtual Indexing Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                         THE 6 HYPOPG VIRTUAL INDEXING CATASTROPHES                                 |
+------------------------------------+---------------------------------------------------------------+
| 1. Destructive Production DDL      | Agent generates physical CREATE INDEX directly on production  |
|    (Unverified Index Hallucination)| tables without virtual verification; creates useless 50GB     |
|                                    | unselected indexes that throttle writes and pin locks!        |
+------------------------------------+---------------------------------------------------------------+
| 2. EXPLAIN ANALYZE Blindness Trap  | Agent runs EXPLAIN ANALYZE on hypothetical index; physical    |
|    (Virtual Execution Fallback)    | execution fails or silently reverts to Seq Scan, tricking the |
|                                    | agent into falsely discarding a high-value index candidate!   |
+------------------------------------+---------------------------------------------------------------+
| 3. Relcache Memory Bleed           | Agent tests 50 index permutations in one connection without   |
|    (Dangling Virtual Index Bloat)  | hypopg_reset(); relcache memory leaks and subsequent planner  |
|                                    | decisions become distorted by zombie hypothetical indexes!    |
+------------------------------------+---------------------------------------------------------------+
| 4. Knapsack Storage Budget Blindness| Agent recommends 10 indexes reducing latency by 5%, ignoring  |
|    (Cumulative Disk Exhaustion)    | their combined 80GB physical footprint that will breach 85%   |
|                                    | disk watermark and trigger database readonly emergency shutdown|
+------------------------------------+---------------------------------------------------------------+
| 5. Stale Statistics Mirage         | Agent runs HypoPG on an empty or newly created test table     |
|    (Missing ANALYZE Misestimation) | without ANALYZE; planner estimates 10 pages and rejects the   |
|                                    | virtual index due to default small-table sequential bias!     |
+------------------------------------+---------------------------------------------------------------+
| 6. PgBouncer Session Pollution     | Connection pooling in session mode without connection resets  |
|    (Cross-Tenant Virtual Leak)     | leaves hypothetical indexes active for other client queries,  |
|                                    | leading to plan instability and non-deterministic behavior!   |
+------------------------------------+---------------------------------------------------------------+
```

### Catastrophic Code Anti-Patterns

#### Anti-Pattern 1: The Unverified Physical DDL Hallucination
```sql
-- CATASTROPHIC: Agent observes slow query and immediately emits physical DDL
-- on a 150-million-row production audit_events table!
-- Result: Locks table DDL, saturates disk I/O for 45 minutes, consumes 32GB disk.
-- Worse: The query filters with `WHERE tenant_id = $1 AND LOWER(action) = $2`.
-- Because the index is on (tenant_id, action), the planner CANNOT use it for LOWER(action)!
CREATE INDEX CONCURRENTLY idx_audit_events_tenant_action 
ON audit_events (tenant_id, action);
```

#### Anti-Pattern 2: The `EXPLAIN ANALYZE` on Virtual Index Disaster
```sql
-- CATASTROPHIC: Agent creates a hypothetical index, but attempts to physically execute it!
SELECT * FROM hypopg_create_index('CREATE INDEX ON orders (user_id, created_at)');

-- FATAL ERROR: EXPLAIN ANALYZE attempts to actually read physical index pages.
-- Because hypopg indexes are purely mathematical structures without disk pages,
-- PostgreSQL executes a Sequential Scan during execution!
-- Agent concludes: "The index was not picked by PostgreSQL, discarding proposal."
EXPLAIN (ANALYZE, BUFFERS) 
SELECT * FROM orders WHERE user_id = 'u_123' ORDER BY created_at DESC LIMIT 20;
```

#### Anti-Pattern 3: Dangling Virtual Indexes Across Connection Poolers
```typescript
// CATASTROPHIC: Agent evaluates index hypotheses without guaranteed cleanup.
// If an exception occurs, or when returning connection to PgBouncer,
// the hypothetical index persists in the backend process!
async function evaluateIndex(client: pg.PoolClient, ddl: string, sql: string) {
  await client.query(`SELECT hypopg_create_index($1)`, [ddl]);
  const plan = await client.query(`EXPLAIN (FORMAT JSON) ${sql}`);
  // Missing `defer` or `finally { hypopg_reset() }`!
  // Subsequent client queries on this pooled connection receive unexpected plan changes!
  return plan.rows[0];
}
```

---

## 2. Mathematical Models & Formal Verification: Cost Reduction Delta, Size Sizing & Knapsack Workload Optimization Calculus

Hypothetical indexing must be governed by mathematical optimization. An autonomous agent must never propose an index unless it satisfies formal cost reduction inequalities and fits within global disk storage budgets.

### Theorem 1 (Query Planner Cost Reduction Ratio & Adoption Threshold)

Let $Q$ be a target SQL query. Let $C_{\text{baseline}}(Q)$ denote the baseline query planner total cost computed by PostgreSQL's cost model using only existing physical indexes:
$$C_{\text{baseline}}(Q) = \text{TotalCost}(\text{EXPLAIN}(Q, \mathcal{I}_{\text{physical}}))$$

Let $I_h$ denote a candidate hypothetical index. Let $C_{\text{hypo}}(Q, I_h)$ denote the planner total cost when the optimizer evaluates $Q$ with the virtual index injected:
$$C_{\text{hypo}}(Q, I_h) = \text{TotalCost}(\text{EXPLAIN}(Q, \mathcal{I}_{\text{physical}} \cup \{I_h\}))$$

The **Cost Reduction Ratio** $\Delta C(Q, I_h)$ is defined as:
$$\Delta C(Q, I_h) = \frac{C_{\text{baseline}}(Q) - C_{\text{hypo}}(Q, I_h)}{C_{\text{baseline}}(Q)}$$

**The Adoption Invariant**: An agent shall classify candidate index $I_h$ as viable if and only if:
1. **Planner Adoption**: The generated query execution plan explicitly contains a scan node referencing $I_h$:
   $$\text{Nodes}(\text{Plan}) \cap \{ \text{Index Scan}(I_h), \text{Index Only Scan}(I_h), \text{Bitmap Index Scan}(I_h) \} \neq \emptyset$$
2. **Cost Threshold Fencing**: The relative cost reduction meets or exceeds the minimum adoption threshold $\tau_{\text{adopt}}$ (empirically calibrated to $\ge 0.60$ / $60\%$ reduction):
   $$\Delta C(Q, I_h) \ge \tau_{\text{adopt}} \quad (\tau_{\text{adopt}} = 0.60)$$
3. **Startup Cost Preservation**: The startup cost does not increase by more than $20\%$ for OLTP queries:
   $$C_{\text{hypo}}^{\text{startup}} \le 1.20 \cdot C_{\text{baseline}}^{\text{startup}}$$

---

### Theorem 2 (B-Tree Virtual Index Footprint Sizing Calculus)

Before recommending an index, the agent must mathematically project its physical disk consumption upon creation. HypoPG exposes `hypopg_relation_size(index_oid)`, but agents must also verify the theoretical size using relation statistics to guard against catalog misestimation.

Let $N_{\text{tuples}}$ be the total live row count in table $T$ (`pg_class.reltuples`). Let $K$ be the number of indexed columns. Let $L_i$ be the average byte width of column $i$ (`pg_stats.avg_width`). Let $B_{\text{leaf}} = 8192 - \text{SpecialSpace}$ be the usable page bytes in an 8KB B-Tree leaf page ($\approx 8128$ bytes). Let $\phi_{\text{fill}}$ be the B-Tree leaf page fillfactor (default $0.90$ for new builds, degrading to $\ln(2) \approx 0.693$ under random inserts).

The projected physical index size $S_{\text{hypo}}(I_h)$ in bytes is:
$$\text{TupleSize}_{\text{idx}} = \text{MAXALIGN}\left( \text{sizeof}(\text{IndexTupleData}) + \sum_{i=1}^K L_i + \text{NullBitmap} \right) + \text{sizeof}(\text{ItemIdData})$$
$$\text{TuplesPerPage} = \left\lfloor \frac{B_{\text{leaf}} \cdot \phi_{\text{fill}}}{\text{TupleSize}_{\text{idx}}} \right\rfloor$$
$$\text{LeafPages} = \left\lceil \frac{N_{\text{tuples}}}{\text{TuplesPerPage}} \right\rceil$$
$$\text{InternalPages} \approx \left\lceil \frac{\text{LeafPages}}{\text{FanOut}} \right\rceil \approx 0.01 \cdot \text{LeafPages}$$
$$S_{\text{hypo}}(I_h) = (\text{LeafPages} + \text{InternalPages} + \text{Metapage}) \times 8192$$

**The HypoPG Sizing Invariant**: The agent must query `hypopg_relation_size(index_oid)` and verify:
$$| \text{hypopg\_relation\_size}(I_h) - S_{\text{hypo}}(I_h) | \le 0.25 \cdot S_{\text{hypo}}(I_h)$$
If the discrepancy exceeds $25\%$, the agent must trigger `ANALYZE table_name` to refresh `reltuples` and `avg_width` before continuing.

---

### Theorem 3 (Multi-Query Workload Knapsack Index Selection)

In production workloads, optimizing multiple slow queries $\mathcal{Q} = \{Q_1, Q_2, \dots, Q_M\}$ with candidate indexes $\mathcal{I}_{\text{candidates}} = \{I_1, I_2, \dots, I_P\}$ presents a constrained optimization problem. Each proposed index consumes disk space and induces write amplification overhead $W_{\text{cost}}(I_k)$ on `INSERT`/`UPDATE`/`DELETE` operations.

Given a strict disk storage budget $B_{\text{max}}$ (e.g., maximum 20GB allowed for new indexes):

$$\max \sum_{j=1}^{M} w_j \cdot \Delta C(Q_j, \mathcal{I}_{\text{selected}}) - \sum_{I_k \in \mathcal{I}_{\text{selected}}} \lambda_{\text{write}} \cdot W_{\text{cost}}(I_k)$$
$$\text{subject to} \sum_{I_k \in \mathcal{I}_{\text{selected}}} S_{\text{hypo}}(I_k) \le B_{\text{max}}$$

where:
- $w_j$ is the execution frequency weight of query $Q_j$ (from `pg_stat_statements.calls`).
- $\lambda_{\text{write}}$ is the system write penalty multiplier.
- $S_{\text{hypo}}(I_k)$ is the projected physical footprint of index $I_k$.

An autonomous agent must run greedy 0/1 knapsack selection across candidate virtual indexes, eliminating low-utility redundant indexes and proposing the globally optimal Pareto-efficient subset.

---

### Theorem 4 (The Ephemeral Isolation & Zero-WAL Invariant)

Let $\mathcal{S}_{\text{hypo}}$ represent the session state containing hypothetical index $I_h$. Because HypoPG registers hypothetical indexes in backend process memory (`relcache` hooks):
$$\frac{\partial \text{WAL}}{\partial t}\Bigg|_{\text{HypoPG}} = 0 \quad \text{bytes/sec}$$
$$\text{LocksAcquired}(I_h) = \emptyset \quad (\text{No AccessExclusiveLock or ShareUpdateExclusiveLock on physical relations})$$
$$\text{Visibility}(I_h, \text{Session}_A \mid \text{Session}_B) = 0 \quad (\text{Strict isolation across concurrent clients})$$

The agent must maintain this zero-impact invariant by guaranteeing that no unhandled exception or early return bypasses `SELECT hypopg_reset();`.

---

## 3. The 5-Tier HypoPG Governance Ladder

To systematically eliminate production indexing outages, agents must adhere to the 5-Tier HypoPG Governance Ladder:

```
+----------------------------------------------------------------------------------------------------+
|                             5-TIER HYPOPG GOVERNANCE LADDER                                        |
+------------------------------------+---------------------------------------------------------------+
| Tier 4: Autonomous Migration CI    | Automated 2-Phase online migration generation; wrapped in     |
|         (CONCURRENTLY + Timeouts)  | lock_timeout <= 2000ms & statement_timeout; rollback script   |
+------------------------------------+---------------------------------------------------------------+
| Tier 3: Strict Session Teardown    | Guaranteed hypopg_reset() execution via try/finally / defer;  |
|         (Zero Connection Bleed)    | verify hypopg_list_indexes() == 0 before returning to pool    |
+------------------------------------+---------------------------------------------------------------+
| Tier 2: Storage Budget & Knapsack  | Bound cumulative projected index size <= B_max; penalize      |
|         (Write Amplification Fence)| low-frequency queries; enforce composite index consolidation  |
+------------------------------------+---------------------------------------------------------------+
| Tier 1: Virtual Plan Simulation    | EXPLAIN (FORMAT JSON) without ANALYZE; require >= 60% cost    |
|         (Cost Reduction Threshold) | reduction (Delta C >= 0.60); verify Index Scan plan adoption   |
+------------------------------------+---------------------------------------------------------------+
| Tier 0: Non-Destructive Base       | TOTAL BAN on direct physical DDL during analysis phase;       |
|         (Zero-I/O Ephemeral Hook)  | require CREATE EXTENSION IF NOT EXISTS hypopg; test isolation |
+------------------------------------+---------------------------------------------------------------+
```

### Tier 0: Non-Destructive Base
- **Zero Physical DDL in Exploration Phase**: Never run `CREATE INDEX` or `ALTER TABLE` while diagnosing or exploring query plans. All hypotheses must be evaluated virtually via HypoPG.
- **Extension Preflight**: Check `SELECT * FROM pg_extension WHERE extname = 'hypopg'`. If missing, verify whether permissions allow installation or use a sandboxed read-replica / ephemeral branch.

### Tier 1: Virtual Plan Simulation & Cost Differential
- **Strict Prohibition of `EXPLAIN ANALYZE`**: Run `EXPLAIN (FORMAT JSON, COSTS ON, VERBOSE ON)` exclusively. Never append `ANALYZE` when evaluating hypothetical indexes; physical execution against imaginary pages produces invalid results.
- **Mandatory Cost Verification**: The virtual index MUST be selected by the optimizer, and the cost reduction must satisfy $\Delta C \ge 0.60$ ($60\%$ reduction).
- **Index Scan Type Classification**: Prefer `Index Only Scan` (if all projected columns are covered) or `Index Scan` over `Bitmap Index Scan`.

### Tier 2: Storage Budget & Knapsack Consolidation
- **Footprint Projection**: Query `hypopg_relation_size(index_oid)` and evaluate against table size. If the index exceeds $40\%$ of the base table size, investigate partial indexing (`WHERE ...`) or prefix column reduction.
- **Composite Index Leftmost Prefix Rule**: Before proposing a new index `(A, B)`, check whether an existing index on `(A, B, C)` already exists or can be extended. Never propose duplicate leading prefixes.

### Tier 3: Strict Session Teardown & Pooler Protection
- **Guaranteed Cleanup**: Always wrap HypoPG calls in idiomatic resource guards (`defer` in Go, `finally` in TypeScript/Python, `Drop` in Rust).
- **Session Reset Verification**: Execute `SELECT hypopg_reset();` and assert `SELECT count(*) FROM hypopg_list_indexes()` returns `0`.

### Tier 4: Autonomous Production Promotion Sentinel
- **Two-Phase Online Migration**: Once an index hypothesis is mathematically approved, generate the physical migration using:
  ```sql
  SET statement_timeout = '2h';
  SET lock_timeout = '2000ms';
  CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_name ON table_name (cols);
  ```
- **Post-Creation Verification**: Audit `pg_stat_user_indexes` after deployment to ensure `idx_scan > 0`.

---

## 4. Production TypeScript Reference Implementation: `AgenticHypoPGGuardEngine`

The following production engine manages the full virtual indexing lifecycle, evaluating candidate indexes, projecting sizes, solving knapsack storage constraints, and guaranteeing connection hygiene.

```typescript
// src/database/AgenticHypoPGGuardEngine.ts

import { Pool, PoolClient } from 'pg';

export interface IndexCandidate {
  tableName: string;
  columns: string[];
  includeColumns?: string[];
  whereClause?: string;
  indexType?: 'btree' | 'gist' | 'gin' | 'brin';
}

export interface PlanCostMetrics {
  startupCost: number;
  totalCost: number;
  planType: string;
  usesHypoIndex: boolean;
  hypoIndexName?: string;
}

export interface HypoEvaluationResult {
  candidate: IndexCandidate;
  hypoIndexOid: number;
  hypoIndexName: string;
  baselineCost: PlanCostMetrics;
  optimizedCost: PlanCostMetrics;
  costReductionRatio: number;
  estimatedSizeBytes: number;
  estimatedSizeFormatted: string;
  isAdopted: boolean;
  isApproved: boolean;
  rejectionReason?: string;
}

export interface WorkloadQuery {
  id: string;
  sql: string;
  params: any[];
  frequencyWeight: number; // e.g. from pg_stat_statements.calls
}

export class AgenticHypoPGGuardEngine {
  private readonly pool: Pool;
  private readonly minCostReduction: number;
  private readonly maxStorageBudgetBytes: number;

  constructor(
    pool: Pool,
    minCostReduction = 0.60,
    maxStorageBudgetBytes = 10 * 1024 * 1024 * 1024 // 10 GB default
  ) {
    this.pool = pool;
    this.minCostReduction = minCostReduction;
    this.maxStorageBudgetBytes = maxStorageBudgetBytes;
  }

  /**
   * Generates a canonical CREATE INDEX DDL for HypoPG consumption.
   */
  public buildIndexDDL(candidate: IndexCandidate): string {
    const type = candidate.indexType ?? 'btree';
    const cols = candidate.columns.map((c) => `"${c}"`).join(', ');
    let ddl = `CREATE INDEX ON "${candidate.tableName}" USING ${type} (${cols})`;

    if (candidate.includeColumns && candidate.includeColumns.length > 0) {
      const inc = candidate.includeColumns.map((c) => `"${c}"`).join(', ');
      ddl += ` INCLUDE (${inc})`;
    }

    if (candidate.whereClause && candidate.whereClause.trim().length > 0) {
      ddl += ` WHERE ${candidate.whereClause}`;
    }

    return ddl;
  }

  /**
   * Evaluates a single query against a candidate index in an isolated, non-destructive session.
   */
  public async evaluateIndex(
    query: WorkloadQuery,
    candidate: IndexCandidate
  ): Promise<HypoEvaluationResult> {
    const client: PoolClient = await this.pool.connect();

    try {
      // Step 1: Verify extension existence
      const extCheck = await client.query(
        `SELECT 1 FROM pg_extension WHERE extname = 'hypopg'`
      );
      if (extCheck.rows.length === 0) {
        throw new Error(
          "HypoPG extension not found. Run 'CREATE EXTENSION hypopg;' before running virtual index evaluation."
        );
      }

      // Tier 3 Safety Invariant: Reset any lingering hypothetical indexes first
      await client.query('SELECT hypopg_reset()');

      // Step 2: Capture baseline query plan without hypothetical indexes
      const baselineCost = await this.explainQuery(client, query.sql, query.params);

      // Step 3: Inject the hypothetical index
      const ddl = this.buildIndexDDL(candidate);
      const createRes = await client.query(
        'SELECT indexrelid, indexname FROM hypopg_create_index($1)',
        [ddl]
      );

      if (createRes.rows.length === 0) {
        throw new Error(`Failed to create hypothetical index for DDL: ${ddl}`);
      }

      const hypoOid = Number(createRes.rows[0].indexrelid);
      const hypoName = String(createRes.rows[0].indexname);

      // Step 4: Estimate physical storage footprint
      const sizeRes = await client.query(
        'SELECT hypopg_relation_size($1) AS size_bytes, pg_size_pretty(hypopg_relation_size($1)) AS size_pretty',
        [hypoOid]
      );
      const estimatedSizeBytes = Number(sizeRes.rows[0].size_bytes);
      const estimatedSizeFormatted = String(sizeRes.rows[0].size_pretty);

      // Step 5: Capture optimized query plan with hypothetical index active
      const optimizedCost = await this.explainQuery(client, query.sql, query.params);

      // Step 6: Mathematical Invariant Evaluation
      const costDelta = baselineCost.totalCost - optimizedCost.totalCost;
      const reductionRatio =
        baselineCost.totalCost > 0 ? costDelta / baselineCost.totalCost : 0;

      const isAdopted =
        optimizedCost.usesHypoIndex ||
        (optimizedCost.hypoIndexName !== undefined &&
          optimizedCost.hypoIndexName.includes(String(hypoOid)));

      let isApproved = false;
      let rejectionReason: string | undefined;

      if (!isAdopted) {
        rejectionReason =
          'Planner rejected hypothetical index: query plan structure remained unchanged.';
      } else if (reductionRatio < this.minCostReduction) {
        rejectionReason = `Cost reduction ratio (${(reductionRatio * 100).toFixed(
          1
        )}%) below minimum threshold (${(this.minCostReduction * 100).toFixed(1)}%).`;
      } else if (estimatedSizeBytes > this.maxStorageBudgetBytes) {
        rejectionReason = `Estimated size (${estimatedSizeFormatted}) exceeds storage budget (${(
          this.maxStorageBudgetBytes /
          (1024 * 1024 * 1024)
        ).toFixed(1)} GB).`;
      } else {
        isApproved = true;
      }

      return {
        candidate,
        hypoIndexOid: hypoOid,
        hypoIndexName: hypoName,
        baselineCost,
        optimizedCost,
        costReductionRatio: reductionRatio,
        estimatedSizeBytes,
        estimatedSizeFormatted,
        isAdopted,
        isApproved,
        rejectionReason,
      };
    } finally {
      // Tier 3 Invariant: Guaranteed session reset on return to connection pool
      try {
        await client.query('SELECT hypopg_reset()');
      } finally {
        client.release();
      }
    }
  }

  /**
   * Solves the Knapsack index selection problem for a multi-query workload.
   */
  public async optimizeWorkload(
    queries: WorkloadQuery[],
    candidates: IndexCandidate[]
  ): Promise<{
    recommendedIndexes: HypoEvaluationResult[];
    totalProjectedSizeBytes: number;
    totalWorkloadCostSavings: number;
  }> {
    const evaluations: HypoEvaluationResult[] = [];

    for (const query of queries) {
      for (const candidate of candidates) {
        const result = await this.evaluateIndex(query, candidate);
        if (result.isApproved) {
          evaluations.push(result);
        }
      }
    }

    // Deduplicate identical index candidates across multiple queries
    const uniqueCandidates = new Map<string, HypoEvaluationResult>();
    for (const evalResult of evaluations) {
      const key = `${evalResult.candidate.tableName}:${evalResult.candidate.columns.join(',')}`;
      if (!uniqueCandidates.has(key)) {
        uniqueCandidates.set(key, evalResult);
      }
    }

    // Greedy Knapsack Selection sorted by CostReductionRatio / EstimatedSizeBytes (density)
    const sorted = Array.from(uniqueCandidates.values()).sort((a, b) => {
      const densityA = a.costReductionRatio / Math.max(a.estimatedSizeBytes, 1024);
      const densityB = b.costReductionRatio / Math.max(b.estimatedSizeBytes, 1024);
      return densityB - densityA;
    });

    const recommended: HypoEvaluationResult[] = [];
    let accumulatedBytes = 0;
    let totalSavings = 0;

    for (const item of sorted) {
      if (accumulatedBytes + item.estimatedSizeBytes <= this.maxStorageBudgetBytes) {
        recommended.push(item);
        accumulatedBytes += item.estimatedSizeBytes;
        totalSavings += item.costReductionRatio;
      }
    }

    return {
      recommendedIndexes: recommended,
      totalProjectedSizeBytes: accumulatedBytes,
      totalWorkloadCostSavings: totalSavings,
    };
  }

  /**
   * Executes EXPLAIN (FORMAT JSON) without ANALYZE to parse cost structures.
   */
  private async explainQuery(
    client: PoolClient,
    sql: string,
    params: any[]
  ): Promise<PlanCostMetrics> {
    // Parameterized EXPLAIN execution
    const explainQuery = `EXPLAIN (FORMAT JSON, COSTS ON, VERBOSE ON) ${sql}`;
    const res = await client.query(explainQuery, params);

    const rootPlan = res.rows[0]['QUERY PLAN'][0]['Plan'];
    const startupCost = Number(rootPlan['Startup Cost']);
    const totalCost = Number(rootPlan['Total Cost']);
    const planType = String(rootPlan['Node Type']);

    // Recursively traverse plan tree to search for hypothetical index scans
    let usesHypoIndex = false;
    let hypoIndexName: string | undefined;

    const traverse = (node: any) => {
      const nodeType = node['Node Type'] || '';
      const indexName = node['Index Name'] || '';

      if (
        (nodeType.includes('Index') || nodeType.includes('Bitmap')) &&
        (indexName.includes('hypo') || /<\d+>/.test(indexName))
      ) {
        usesHypoIndex = true;
        hypoIndexName = indexName;
      }

      if (node['Plans'] && Array.isArray(node['Plans'])) {
        for (const child of node['Plans']) {
          traverse(child);
        }
      }
    };

    traverse(rootPlan);

    return {
      startupCost,
      totalCost,
      planType,
      usesHypoIndex,
      hypoIndexName,
    };
  }
}
```

---

## 5. Multi-Language Production Implementations

### PostgreSQL Automated What-If Verification Script

```sql
-- scripts/hypopg_what_if_verify.sql
-- Autonomous agent execution harness for virtual index evaluation

BEGIN;
-- Step 1: Ensure hypopg is available in sandbox
CREATE EXTENSION IF NOT EXISTS hypopg;

-- Step 2: Reset any prior session state
SELECT hypopg_reset();

-- Step 3: Record baseline plan for candidate query
EXPLAIN (FORMAT JSON, COSTS ON)
SELECT id, user_id, status, total_amount, created_at
FROM orders
WHERE tenant_id = 't_tenant_456'
  AND status = 'PENDING'
  AND created_at >= NOW() - INTERVAL '30 days'
ORDER BY created_at DESC
LIMIT 50;

-- Step 4: Create candidate hypothetical index
-- Tests composite B-Tree (tenant_id, status, created_at DESC)
SELECT * FROM hypopg_create_index(
  'CREATE INDEX ON orders (tenant_id, status, created_at DESC) INCLUDE (total_amount)'
);

-- Inspect currently active hypothetical indexes and projected sizes
SELECT 
    indexrelid,
    indexname,
    hypopg_relation_size(indexrelid) AS size_bytes,
    pg_size_pretty(hypopg_relation_size(indexrelid)) AS size_pretty
FROM hypopg_list_indexes();

-- Step 5: Test query again with virtual index active
EXPLAIN (FORMAT JSON, COSTS ON)
SELECT id, user_id, status, total_amount, created_at
FROM orders
WHERE tenant_id = 't_tenant_456'
  AND status = 'PENDING'
  AND created_at >= NOW() - INTERVAL '30 days'
ORDER BY created_at DESC
LIMIT 50;

-- Step 6: Mandatory Tier 3 Session Cleanup
SELECT hypopg_reset();
COMMIT;
```

---

### Go (`jackc/pgx/v5`): Scoped HypoPG Optimizer & Migration Generator

```go
// internal/store/hypopg_advisor.go
package store

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type IndexProposal struct {
	TableName      string
	Columns        []string
	IncludeColumns []string
	WhereClause    string
}

type PlanNode struct {
	NodeType  string     `json:"Node Type"`
	IndexName string     `json:"Index Name"`
	TotalCost float64    `json:"Total Cost"`
	Plans     []PlanNode `json:"Plans"`
}

type ExplainResult struct {
	Plan PlanNode `json:"Plan"`
}

type HypoPGAdvisor struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewHypoPGAdvisor(pool *pgxpool.Pool, logger *slog.Logger) *HypoPGAdvisor {
	return &HypoPGAdvisor{pool: pool, logger: logger}
}

// EvaluateHypothesis runs a non-destructive What-If evaluation of an index proposal.
// Returns the baseline cost, hypothetical cost, cost reduction percentage, and approved status.
func (a *HypoPGAdvisor) EvaluateHypothesis(
	ctx context.Context,
	querySQL string,
	proposal IndexProposal,
) (reductionPct float64, approved bool, err error) {
	conn, err := a.pool.Acquire(ctx)
	if err != nil {
		return 0, false, fmt.Errorf("failed to acquire connection: %w", err)
	}
	defer conn.Release()

	// Invariant: Guaranteed hypopg_reset() on all exit paths
	defer func() {
		if _, resetErr := conn.Exec(ctx, "SELECT hypopg_reset()"); resetErr != nil {
			a.logger.Error("failed to reset hypopg session", "error", resetErr)
		}
	}()

	// 1. Ensure hypopg exists
	var extExists bool
	err = conn.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'hypopg')").Scan(&extExists)
	if err != nil || !extExists {
		return 0, false, fmt.Errorf("hypopg extension is required but not installed: %w", err)
	}

	// 2. Clear any lingering virtual indexes
	if _, err := conn.Exec(ctx, "SELECT hypopg_reset()"); err != nil {
		return 0, false, fmt.Errorf("failed to initialize hypopg: %w", err)
	}

	// 3. Baseline cost
	baselineCost, _, err := a.getPlanCost(ctx, conn.Conn(), querySQL)
	if err != nil {
		return 0, false, fmt.Errorf("failed to get baseline cost: %w", err)
	}

	// 4. Construct HypoPG DDL
	var cols []string
	for _, c := range proposal.Columns {
		cols = append(cols, fmt.Sprintf("%q", c))
	}
	ddl := fmt.Sprintf("CREATE INDEX ON %q (%s)", proposal.TableName, strings.Join(cols, ", "))
	if len(proposal.IncludeColumns) > 0 {
		var inc []string
		for _, c := range proposal.IncludeColumns {
			inc = append(inc, fmt.Sprintf("%q", c))
		}
		ddl += fmt.Sprintf(" INCLUDE (%s)", strings.Join(inc, ", "))
	}
	if proposal.WhereClause != "" {
		ddl += fmt.Sprintf(" WHERE %s", proposal.WhereClause)
	}

	// 5. Create Virtual Index
	var indexRelID uint32
	var indexName string
	err = conn.QueryRow(ctx, "SELECT indexrelid, indexname FROM hypopg_create_index($1)", ddl).Scan(&indexRelID, &indexName)
	if err != nil {
		return 0, false, fmt.Errorf("failed to create hypothetical index: %w", err)
	}

	// 6. Evaluated Cost
	hypoCost, usedHypo, err := a.getPlanCost(ctx, conn.Conn(), querySQL)
	if err != nil {
		return 0, false, fmt.Errorf("failed to get hypothetical cost: %w", err)
	}

	if !usedHypo {
		return 0, false, nil // Planner chose not to use the index
	}

	costDelta := baselineCost - hypoCost
	if baselineCost > 0 {
		reductionPct = (costDelta / baselineCost) * 100.0
	}

	// Invariant: Approve only if cost reduction is >= 60%
	if reductionPct >= 60.0 {
		approved = true
	}

	return reductionPct, approved, nil
}

func (a *HypoPGAdvisor) getPlanCost(ctx context.Context, conn *pgx.Conn, querySQL string) (float64, bool, error) {
	explainSQL := fmt.Sprintf("EXPLAIN (FORMAT JSON, COSTS ON) %s", querySQL)
	var rawJSON []byte
	err := conn.QueryRow(ctx, explainSQL).Scan(&rawJSON)
	if err != nil {
		return 0, false, err
	}

	var results []ExplainResult
	if err := json.Unmarshal(rawJSON, &results); err != nil || len(results) == 0 {
		return 0, false, fmt.Errorf("failed to parse explain json: %w", err)
	}

	root := results[0].Plan
	totalCost := root.TotalCost

	usesHypo := false
	var checkNode func(n PlanNode)
	checkNode = func(n PlanNode) {
		if strings.Contains(n.IndexName, "hypo") || strings.Contains(n.NodeType, "Index") {
			if strings.Contains(n.IndexName, "hypo") {
				usesHypo = true
			}
		}
		for _, child := range n.Plans {
			checkNode(child)
		}
	}
	checkNode(root)

	return totalCost, usesHypo, nil
}
```

---

### Python (`asyncpg`): Asynchronous Scoped Sandbox Context Manager

```python
# database/hypopg_sandbox.py
from contextlib import asynccontextmanager
import asyncpg
import json
from typing import AsyncGenerator, Dict, Any, List

class HypoPGSandbox:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    @asynccontextmanager
    async def session(self) -> AsyncGenerator[asyncpg.Connection, None]:
        """Provides an isolated connection guaranteed to reset HypoPG state on exit."""
        async with self.pool.acquire() as conn:
            try:
                # Pre-clean
                await conn.execute("SELECT hypopg_reset();")
                yield conn
            finally:
                # Tier 3 Guaranteed Teardown
                await conn.execute("SELECT hypopg_reset();")

    async def evaluate_index_proposal(
        self,
        query_sql: str,
        table_name: str,
        columns: List[str],
        min_cost_reduction: float = 0.60
    ) -> Dict[str, Any]:
        """Evaluates whether candidate columns improve query performance by >= 60%."""
        cols_str = ", ".join(f'"{c}"' for c in columns)
        hypo_ddl = f'CREATE INDEX ON "{table_name}" ({cols_str})'

        async with self.session() as conn:
            # 1. Baseline Cost
            baseline_raw = await conn.fetchval(f"EXPLAIN (FORMAT JSON, COSTS ON) {query_sql}")
            baseline_plan = json.loads(baseline_raw)[0]["Plan"]
            baseline_cost = float(baseline_plan["Total Cost"])

            # 2. Virtual Index Creation
            created = await conn.fetchrow("SELECT indexrelid, indexname FROM hypopg_create_index($1)", hypo_ddl)
            hypo_oid = created["indexrelid"]
            hypo_name = created["indexname"]

            # 3. Size Projection
            size_bytes = await conn.fetchval("SELECT hypopg_relation_size($1)", hypo_oid)

            # 4. Optimized Cost
            opt_raw = await conn.fetchval(f"EXPLAIN (FORMAT JSON, COSTS ON) {query_sql}")
            opt_plan = json.loads(opt_raw)[0]["Plan"]
            opt_cost = float(opt_plan["Total Cost"])

            # 5. Check adoption
            plan_str = json.dumps(opt_plan)
            is_adopted = hypo_name in plan_str or "hypo" in plan_str

            reduction = (baseline_cost - opt_cost) / baseline_cost if baseline_cost > 0 else 0.0

            return {
                "hypo_oid": hypo_oid,
                "hypo_name": hypo_name,
                "baseline_cost": baseline_cost,
                "optimized_cost": opt_cost,
                "reduction_ratio": reduction,
                "estimated_size_bytes": size_bytes,
                "is_adopted": is_adopted,
                "is_approved": is_adopted and reduction >= min_cost_reduction
            }
```

---

### Rust (`sqlx`): Scoped Virtual Index Verification Harness

```rust
// src/db/hypopg_verifier.rs
use sqlx::{PgPool, Error};
use serde_json::Value;

pub struct HypoPGVerifier {
    pool: PgPool,
}

impl HypoPGVerifier {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Evaluates an index hypothesis virtually and calculates cost reduction
    pub async fn evaluate(
        &self,
        query: &str,
        table: &str,
        columns: &[&str],
    ) -> Result<(f64, bool), Error> {
        let mut conn = self.pool.acquire().await?;

        // Guard: Reset at start and finish
        sqlx::query("SELECT hypopg_reset()").execute(&mut *conn).await?;

        // 1. Baseline explain
        let baseline_sql = format!("EXPLAIN (FORMAT JSON, COSTS ON) {}", query);
        let baseline_row: (Value,) = sqlx::query_as(&baseline_sql).fetch_one(&mut *conn).await?;
        let baseline_cost = baseline_row.0[0]["Plan"]["Total Cost"].as_f64().unwrap_or(0.0);

        // 2. Create hypothetical index
        let cols_joined = columns.iter().map(|c| format!("\"{}\"", c)).collect::<Vec<_>>().join(", ");
        let ddl = format!("CREATE INDEX ON \"{}\" ({})", table, cols_joined);
        sqlx::query("SELECT hypopg_create_index($1)")
            .bind(&ddl)
            .execute(&mut *conn)
            .await?;

        // 3. Optimized explain
        let opt_row: (Value,) = sqlx::query_as(&baseline_sql).fetch_one(&mut *conn).await?;
        let opt_plan = &opt_row.0[0]["Plan"];
        let opt_cost = opt_plan["Total Cost"].as_f64().unwrap_or(0.0);

        // Check if hypo was picked
        let plan_text = opt_plan.to_string();
        let adopted = plan_text.contains("hypo");

        // Cleanup
        sqlx::query("SELECT hypopg_reset()").execute(&mut *conn).await?;

        let reduction = if baseline_cost > 0.0 {
            (baseline_cost - opt_cost) / baseline_cost
        } else {
            0.0
        };

        Ok((reduction, adopted && reduction >= 0.60))
    }
}
```

---

## 6. Six-State HypoPG Lifecycle Finite-State Machine (FSM)

Autonomous agents must transition through the 6-state FSM sequentially. Skipping states (e.g., jumping from hypothesis directly to physical DDL) is an operational breach.

```
       +---------------------------------------------+
       |                1. UNINDEXED                 |
       |  Slow query identified via pg_stat_stmt     |
       +----------------------┬----------------------+
                              │
                              ▼ [Preflight: EXTENSION hypopg]
       +---------------------------------------------+
       |              2. HYPO_PROPOSED               |
       |  AST analysis produces composite candidates |
       +----------------------┬----------------------+
                              │
                              ▼ [hypopg_create_index(ddl)]
       +---------------------------------------------+
       |             3. VIRTUAL_INDEXED              |
       |  0-byte catalog injected into relcache      |
       +----------------------┬----------------------+
                              │
                              ▼ [EXPLAIN (FORMAT JSON)]
       +---------------------------------------------+
       |             4. PLAN_EVALUATED               |
       |  Verify adoption & Delta C >= 0.60          |
       +----------------------┬----------------------+
                              │
                              ▼ [Knapsack Check: Size <= B_max]
       +---------------------------------------------+
       |            5. KNAPSACK_VERIFIED             |
       |  Cumulative storage budget satisfied        |
       +----------------------┬----------------------+
                              │
            ┌─────────────────┴─────────────────┐
            ▼                                   ▼
+-----------------------+           +-----------------------+
|  6A. PROMOTED ONLINE  |           |   6B. PURGED & RESET  |
| CREATE INDEX CONC...  |           | hypopg_reset() called |
| lock_timeout <= 2000ms|           | 0 disk / 0 WAL impact |
+-----------------------+           +-----------------------+
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Every index optimization proposed by an autonomous agent must satisfy all 6 DoD gates prior to PR merge or migration deployment:

```
+----------------------------------------------------------------------------------------------------+
|                         6-GATE HYPOPG DEFINITION OF DONE (DoD) MATRIX                              |
+---+----------------------------+-------------------------------------+-----------------------------+
| # | Gate Name                  | Verification Mechanism              | Acceptance Criteria         |
+---+----------------------------+-------------------------------------+-----------------------------+
| 1 | Zero-I/O Exploration Gate  | pg_stat_statements & WAL metrics   | 0 bytes WAL emitted during  |
|   |                            | during exploration phase            | virtual evaluation phase    |
+---+----------------------------+-------------------------------------+-----------------------------+
| 2 | Planner Adoption Gate      | EXPLAIN (FORMAT JSON) plan tree     | Target node contains        |
|   |                            | traversal                           | "<oid>_hypo" Index Scan     |
+---+----------------------------+-------------------------------------+-----------------------------+
| 3 | Cost Delta Gate            | Mathematical Cost Ratio             | Delta C >= 0.60 (>= 60%     |
|   |                            | (C_base - C_hypo) / C_base          | total cost reduction)       |
+---+----------------------------+-------------------------------------+-----------------------------+
| 4 | Storage Knapsack Gate      | hypopg_relation_size(oid)           | Projected index size <=     |
|   |                            | vs max_storage_budget               | B_max and <= 40% table size |
+---+----------------------------+-------------------------------------+-----------------------------+
| 5 | Session Purity Gate        | SELECT count(*) FROM                | Count == 0; zero lingering  |
|   |                            | hypopg_list_indexes()               | virtual indexes on teardown |
+---+----------------------------+-------------------------------------+-----------------------------+
| 6 | Safe Online Migration Gate | Automated Migration Linter          | DDL uses CONCURRENTLY with  |
|   |                            | checks SQL migration AST            | lock_timeout <= 2000ms      |
+---+----------------------------+-------------------------------------+-----------------------------+
```
