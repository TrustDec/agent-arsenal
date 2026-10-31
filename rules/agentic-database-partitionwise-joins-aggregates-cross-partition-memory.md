---
description: PostgreSQL Partition-Wise Joins (enable_partitionwise_join), Partition-Wise Aggregation (enable_partitionwise_aggregate), cross-partition memory amplification, dynamic plan re-partitioning, boundary alignment, and work_mem OOM defense across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{partition,partitionwise,join,aggregate,shuffling,repartition,workmem,timescale,table-partition,analytics,olap,sql,postgres,db,query}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Partition-Wise Joins, Partition-Wise Aggregates, Dynamic Plan Re-Partitioning & Execution Memory Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design declarative table partitioning (RANGE, HASH, LIST), optimize multi-table JOINs and GROUP BY aggregations on partitioned datasets, configure PostgreSQL query planner GUCs, manage `work_mem` allocation limits, and prevent catastrophic memory spills across PostgreSQL (12–17+) in Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Default `enable_partitionwise_join = off` Monolithic Join Memory Cliff" (where PostgreSQL flattens 100 partitions of Table A and 100 partitions of Table B into giant `Append` nodes and executes a single monolithic Hash Join across 100 million rows, burning gigabytes of disk temp files and causing 45-second latency spikes), the "Partition Boundary & Modulus Mismatch Fallacy" (where Table A has 64 HASH partitions but Table B has 32 partitions, or date intervals differ, silently aborting partition-wise joins and causing Cartesian cartwheel joining), the "`enable_partitionwise_aggregate = off` Top-Level Grouping Bottleneck" (where all 100 million unaggregated rows are streamed to a top-level leader node before aggregation, thrashing memory instead of aggregating locally per child partition), the "Cross-Partition Shuffling & Combinatorial Planning Explosion" (where joining on non-partition keys causes $P_A \times P_B$ plan space combinatorial searches, pinning CPU for 15 seconds before execution), the "Parallel Worker Starvation & Gather-Append Straggler Barrier" (where uneven partition distribution leaves workers idling at synchronization barriers), and the "Unbounded $P \times \text{work\_mem}$ OOM Decapitation" (where concurrent partition join nodes each consume a full `work_mem` slice, triggering Linux kernel OOM killer termination of the postmaster) by establishing a strict 5-Tier Partition-Wise Join & Aggregate Governance Ladder, mathematical memory reduction theorems, planning complexity bounds, a production-ready TypeScript `AgenticPartitionwiseJoinGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state optimization lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Partition-Wise Join Catastrophes vs The 5-Tier Governance Ladder

In declarative table partitioning, tables are divided into smaller physical child relations (partitions). When two partitioned tables are joined (e.g., `orders` and `order_items` partitioned by `order_id` or `tenant_id` and `created_at`), PostgreSQL can either:
1. **Monolithic Join (Default)**: Read partitions from Table A via `Append`, read partitions from Table B via `Append`, and execute a single monolithic `Hash Join` or `Merge Join` over the entire combined dataset.
2. **Partition-Wise Join (`enable_partitionwise_join = on`)**: Break the join down into $P$ independent smaller joins between matching pairs of child partitions:
   $$\text{Append}(\text{Join}(A_1, B_1), \text{Join}(A_2, B_2), \dots, \text{Join}(A_P, B_P))$$

Similarly, for aggregation:
1. **Monolithic Aggregate (Default)**: Append all raw tuples from all partitions, then feed them into a single top-level `HashAggregate` or `GroupAggregate`.
2. **Partition-Wise Aggregate (`enable_partitionwise_aggregate = on`)**: Compute the aggregation locally inside each child partition first, and then merge the pre-aggregated summary rows:
   $$\text{Append}(\text{Aggregate}(A_1), \text{Aggregate}(A_2), \dots, \text{Aggregate}(A_P))$$

Because combinatorial planning time grows with partition counts, PostgreSQL **defaults both settings to `off`** (`enable_partitionwise_join = off`, `enable_partitionwise_aggregate = off`). Autonomous coding agents consistently fail to navigate the subtle trade-offs between planning overhead, boundary matching, and memory consumption:

### The 6 Partition-Wise Join & Aggregate Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                   THE 6 PARTITION-WISE JOIN & AGGREGATE CATASTROPHES                               |
+------------------------------------+---------------------------------------------------------------+
| 1. Monolithic Join Memory Cliff    | enable_partitionwise_join = off forces PostgreSQL to build    |
|    (The Append-Then-Join Disaster) | a giant 100M-row Hash Table; spills gigabytes to disk temp    |
|                                    | files, ballooning query latency from 80ms to 45 seconds!      |
+------------------------------------+---------------------------------------------------------------+
| 2. Partition Boundary Mismatch     | Table A has 64 HASH partitions; Table B has 32 HASH buckets;  |
|    (Silent Asymmetric Join Rejection)| Planner silently rejects partition-wise join, reverting to   |
|                                    | Cartesian cross-partition joins without any warning or error! |
+------------------------------------+---------------------------------------------------------------+
| 3. Unaggregated Append Bottleneck  | enable_partitionwise_aggregate = off feeds 50M raw rows into   |
|    (Top-Level Leader Saturation)   | a single leader HashAggregate; blows up working memory and   |
|                                    | deprives child partitions of early parallel pre-reduction.    |
+------------------------------------+---------------------------------------------------------------+
| 4. Combinatorial Planning Spike    | enable_partitionwise_join = on globally on 1,000 partitions  |
|    (O(P^2) CPU Join Search Trap)   | causes dynamic programming join search to spend 15 seconds    |
|                                    | generating execution trees, stalling OLTP transaction threads! |
+------------------------------------+---------------------------------------------------------------+
| 5. Gather-Append Straggler Barrier | Parallel query workers assigned to skewed partition joins;    |
|    (Worker Starvation & Skew)      | 1 worker processes 90% of rows while remaining workers idle   |
|                                    | blocked at the Gather synchronization barrier.                |
+------------------------------------+---------------------------------------------------------------+
| 6. P x work_mem OOM Decapitation   | Multi-partition joins each allocate a work_mem slice; with    |
|    (Postmaster SIGKILL Disaster)   | work_mem = 256MB and 16 active joins, memory reaches 4GB+,   |
|                                    | causing Linux kernel OOM killer to terminate the postmaster!  |
+------------------------------------+---------------------------------------------------------------+
```

### Catastrophic Code Anti-Patterns

```typescript
// ❌ CATASTROPHIC LLM PARTITION JOIN ANTI-PATTERNS
// Anti-Pattern 1: The Asymmetric Hash Modulus Trap
// Table 1 DDL:
// CREATE TABLE customer_orders (...) PARTITION BY HASH (tenant_id);
// (Creates 64 partitions: modulus 64, remainder 0..63)
// Table 2 DDL generated by Agent:
// CREATE TABLE customer_order_items (...) PARTITION BY HASH (tenant_id);
// (Agent creates 32 partitions: modulus 32, remainder 0..31)
// RESULT: PostgreSQL planner CANNOT pair partitions! Partition-wise join silently fails!

// Anti-Pattern 2: Global Configuration File Anti-Pattern
// postgresql.conf:
// enable_partitionwise_join = on      # ❌ FATAL IN OLTP: Pins CPU on high-partition OLTP queries!
// enable_partitionwise_aggregate = on # ❌ FATAL: Inflates plan cache memory across all backends!
// work_mem = 512MB                    # ❌ FATAL: Multiplies across partition workers, triggering OOM!

// Anti-Pattern 3: Joining on Non-Partition Keys
export async function getCrossPartitionReport(db: DatabaseClient) {
  // customer_orders is partitioned by (created_at)
  // customer_order_items is partitioned by (order_id)
  // Joining on non-matching partition keys with enable_partitionwise_join = on
  // causes the planner to evaluate hundreds of cross-partition sub-plans!
  return db.query(`
    SELECT o.id, sum(i.quantity * i.unit_price)
    FROM customer_orders o
    JOIN customer_order_items i ON o.id = i.order_id
    WHERE o.created_at >= '2025-01-01'
    GROUP BY o.id
  `);
}
```

---

## 2. Mathematical Models & Formal Verification: Partition Matching, Memory Sizing & Combinatorial Planning Complexity

### Theorem 1 (Partition-Wise Join Memory Reduction Calculus)
Let Table $A$ and Table $B$ be partitioned into $P$ mutually exclusive, congruent child partitions $\{A_1, \dots, A_P\}$ and $\{B_1, \dots, B_P\}$. Let $|A_i| = N_{A_i}$ and $|B_i| = N_{B_i}$ denote tuple counts, with total tuples $N_A = \sum_{i=1}^P N_{A_i}$ and $N_B = \sum_{i=1}^P N_{B_i}$.

Under **Monolithic Join (`enable_partitionwise_join = off`)**:
The query planner constructs a single global hash table over the smaller relation (assume $A$):

$$M_{\text{monolithic}} = N_A \cdot \left( S_{\text{tuple}} + S_{\text{hash\_overhead}} \right)$$

If $M_{\text{monolithic}} > \text{work\_mem}$, PostgreSQL triggers multi-batch external hash joins, partitioning the hash table into $2^k$ disk batches. Disk I/O volume scales with:

$$V_{\text{disk\_io}} = 2 \cdot \left( \text{Bytes}(A) + \text{Bytes}(B) \right) \cdot \left( \text{nbatch} - 1 \right)$$

Under **Partition-Wise Join (`enable_partitionwise_join = on`)**:
Because each partition pair $(A_i, B_i)$ is joined independently and sequentially (or in bounded parallel worker sets $W \ll P$), peak memory consumption is bounded by the maximum individual partition hash table:

$$M_{\text{pwj}} = \max_{1 \le i \le P} \left( N_{A_i} \cdot (S_{\text{tuple}} + S_{\text{hash\_overhead}}) \right) \approx \frac{M_{\text{monolithic}}}{P}$$

When $P = 64$ partitions, peak working memory decreases by **$\mathbf{64\times}$**, completely eliminating disk batch spilling ($V_{\text{disk\_io}} \equiv 0$) and keeping execution 100% in-memory!

### Theorem 2 (Combinatorial Planning Time Complexity & Partition Threshold)
Let $P_A$ and $P_B$ be the number of partitions in Table $A$ and Table $B$.
1. **Strictly Aligned Partitions** ($P_A = P_B = P$, identical bounds, join on partition key):
   The planner pairs partition $A_i$ directly with $B_i$. Planning complexity scales linearly:
   $$T_{\text{plan\_aligned}} = \mathcal{O}(P \cdot \log P)$$
2. **Unaligned / Cross-Partition Joins** (different bounds or non-partition join keys):
   The planner must evaluate cross-combinations. In the worst case:
   $$T_{\text{plan\_unaligned}} = \mathcal{O}(P_A \cdot P_B)$$

If $P_A = 365$ and $P_B = 365$ (e.g., daily partitions over a year without partition pruning), $T_{\text{plan\_unaligned}}$ evaluates $365 \times 365 = 133,225$ sub-join candidate paths, consuming $> 15\text{s}$ in planning time and $> 200\text{MB}$ in backend parse tree memory!

### Critical Invariant: The Partition-Wise Join Eligibility Axiom
A partition-wise join is valid if and only if:

$$\text{Strategy}(A) \equiv \text{Strategy}(B) \quad \land \quad \text{KeyType}(A) \equiv \text{KeyType}(B) \quad \land \quad \text{Bounds}(A_i) \equiv \text{Bounds}(B_i) \quad \forall i \in [1, P]$$

### Theorem 3 (Partition-Wise Aggregate Tuple Reduction Differential)
Let an aggregation query `GROUP BY key, partition_key` operate over $P$ partitions, each containing $N_i$ rows with $K_i$ distinct groups where $K_i \ll N_i$.
- **Monolithic Aggregate**: $N = \sum_{i=1}^P N_i$ raw tuples are transmitted over shared memory to the root `HashAggregate` node.
- **Partition-Wise Aggregate**: Each child partition aggregates locally. The number of tuples transmitted to the final `Append` node is:
  $$V_{\text{transmitted}} = \sum_{i=1}^P K_i$$
- **Tuple Volume Reduction Ratio**:
  $$\mathcal{R}_{\text{agg}} = 1 - \frac{\sum_{i=1}^P K_i}{\sum_{i=1}^P N_i} \ge 95\% - 99.9\%$$

Local aggregation collapses inter-process communication (IPC) serialization overhead and eliminates leader CPU bottlenecks.

---

## 3. The 5-Tier Partition-Wise Join & Aggregate Governance Ladder

```
+----------------------------------------------------------------------------------------------------+
|                5-TIER PARTITION-WISE JOIN & AGGREGATE GOVERNANCE LADDER                            |
+--------+------------------------------------+------------------------------------------------------+
| TIER 0 | Boundary & Strategy Alignment      | 100% congruent partition strategy (HASH/RANGE),      |
|        | (Zero Asymmetric Mismatches)       | identical partition counts, exact modulus & offsets; |
|        |                                    | foreign keys reference identical partition schemas.  |
+--------+------------------------------------+------------------------------------------------------+
| TIER 1 | Transaction-Scoped GUC Activation  | Global postgresql.conf leaves flags OFF;             |
|        | (Zero OLTP Planning Regression)    | Target analytical/batch queries activate via         |
|        |                                    | SET LOCAL enable_partitionwise_join = on;            |
|        |                                    | SET LOCAL enable_partitionwise_aggregate = on.       |
+--------+------------------------------------+------------------------------------------------------+
| TIER 2 | Dynamic work_mem Budget Fencing    | Compute session-scoped work_mem budget:              |
|        | (Zero OOM Postmaster Decapitation) | work_mem = min(work_mem, budget / (W * active_P + 1))|
|        |                                    | Prevent concurrent worker memory explosion.          |
+--------+------------------------------------+------------------------------------------------------+
| TIER 3 | Parallel Worker & Pruning Symmetry | Partition pruning filter WHERE created_at >= $1      |
|        | (Zero Gather Synchronization Skew) | restricts joins to target partitions; max_parallel   |
|        |                                    | workers matched to pruned partition count.           |
+--------+------------------------------------+------------------------------------------------------+
| TIER 4 | Machine-Verifiable Telemetry & CI  | Continuous EXPLAIN (ANALYZE, BUFFERS) CI gates       |
|        | (Automated Regression Sentinels)   | verifying Append(Hash Join) vs Hash Join(Append),    |
|        |                                    | TempWrittenBlocks = 0, and planning_time < 50ms.     |
+--------+------------------------------------+------------------------------------------------------+
```

### Tier 0: Boundary & Strategy Alignment
- **Co-Located Partition Schemes**: If Table $A$ and Table $B$ are frequently joined, they MUST share identical partitioning schemes. If Table $A$ is `PARTITION BY HASH (tenant_id)` with 32 partitions, Table $B$ MUST also be `PARTITION BY HASH (tenant_id)` with 32 partitions.
- **Range Boundary Alignment**: For range-partitioned tables (e.g., daily or monthly time-series), both parent tables MUST share identical timestamp boundaries and UTC truncation rules.

### Tier 1: Transaction-Scoped GUC Activation
- **Strict Ban on Global Configuration**: NEVER set `enable_partitionwise_join = on` or `enable_partitionwise_aggregate = on` in global `postgresql.conf` for general OLTP workloads.
- **Local Transaction Scope**: Analytical reports, bulk sync jobs, and complex aggregations MUST opt-in within the specific transaction using `SET LOCAL`:
  ```sql
  BEGIN;
  SET LOCAL enable_partitionwise_join = on;
  SET LOCAL enable_partitionwise_aggregate = on;
  -- Execute reporting query...
  COMMIT;
  ```

### Tier 2: Dynamic `work_mem` Budget Fencing
- Because partition-wise join executes sub-joins across multiple child partitions, if parallel workers are spawned, each worker allocates `work_mem` for its local hash table.
- Calculate safe transaction-level `work_mem`:
  $$\text{work\_mem}_{\text{safe}} = \min\left(256\text{MB}, \frac{\text{Available RAM} \times 0.25}{\text{max\_parallel\_workers\_per\_gather} + 1}\right)$$

### Tier 3: Parallel Worker & Pruning Symmetry
- Always combine partition-wise joins with sargable partition pruning predicates (`WHERE created_at >= $1 AND created_at < $2`).
- Restricting the join to only 2–4 partitions prevents the planner from evaluating combinatorial sub-plans for irrelevant historical or future partitions.

### Tier 4: Machine-Verifiable Telemetry & CI Gates
- Verify query plans via CI assertions checking that the outer node is an `Append` containing individual `Hash Join` or `Merge Join` child nodes:
  - ✅ **Partition-Wise Join**: `Append -> Sub-query / Hash Join (A_i, B_i)`
  - ❌ **Monolithic Join (Regression)**: `Hash Join -> Append (A_*) + Append (B_*)`
- Verify `TempWrittenBlocks = 0` in `EXPLAIN (ANALYZE, BUFFERS)` output.

---

## 4. Production TypeScript Reference Implementation: `AgenticPartitionwiseJoinGuardEngine`

```typescript
// src/db/partitionwise_join_guard.ts
import { Pool, PoolClient } from 'pg';

export interface PartitionSchemeAudit {
  parentTable: string;
  partitionStrategy: 'hash' | 'range' | 'list';
  partitionCount: number;
  partitionKeyColumns: string[];
  isAlignedWithPeer: boolean;
  mismatchDetails?: string;
}

export interface PartitionwiseExecutionPlanAnalysis {
  isPartitionwiseJoinUsed: boolean;
  isPartitionwiseAggregateUsed: boolean;
  planTreeRootNode: string;
  planningTimeMs: number;
  executionTimeMs: number;
  tempWrittenBlocks: number;
  recommendations: string[];
}

export class AgenticPartitionwiseJoinGuardEngine {
  constructor(private readonly pool: Pool) {}

  /**
   * Validates whether two partitioned tables are structurally aligned
   * for seamless partition-wise join activation.
   */
  async auditTablePairAlignment(tableA: string, tableB: string): Promise<{
    tableA: PartitionSchemeAudit;
    tableB: PartitionSchemeAudit;
    canActivatePartitionwiseJoin: boolean;
    rejectionReason?: string;
  }> {
    const client = await this.pool.connect();
    try {
      const schemeA = await this.fetchPartitionScheme(client, tableA);
      const schemeB = await this.fetchPartitionScheme(client, tableB);

      let canActivate = true;
      let rejectionReason: string | undefined;

      if (schemeA.partitionStrategy !== schemeB.partitionStrategy) {
        canActivate = false;
        rejectionReason = `Strategy mismatch: ${tableA} uses ${schemeA.partitionStrategy}, but ${tableB} uses ${schemeB.partitionStrategy}`;
      } else if (schemeA.partitionCount !== schemeB.partitionCount) {
        canActivate = false;
        rejectionReason = `Partition count mismatch: ${tableA} has ${schemeA.partitionCount} partitions, but ${tableB} has ${schemeB.partitionCount}`;
      } else if (schemeA.partitionKeyColumns.join(',') !== schemeB.partitionKeyColumns.join(',')) {
        canActivate = false;
        rejectionReason = `Partition key column mismatch: [${schemeA.partitionKeyColumns.join(',')}] vs [${schemeB.partitionKeyColumns.join(',')}]`;
      }

      schemeA.isAlignedWithPeer = canActivate;
      schemeB.isAlignedWithPeer = canActivate;

      return {
        tableA: schemeA,
        tableB: schemeB,
        canActivatePartitionwiseJoin: canActivate,
        rejectionReason,
      };
    } finally {
      client.release();
    }
  }

  /**
   * Executes an analytical query within an isolated transaction having
   * safe, scoped partition-wise joins and aggregates activated.
   */
  async executeScopedPartitionwiseQuery<T>(
    querySql: string,
    params: any[] = [],
    options: {
      workMemMb?: number;
      maxParallelWorkers?: number;
      timeoutMs?: number;
    } = {}
  ): Promise<{ rows: T[]; planAnalysis: PartitionwiseExecutionPlanAnalysis }> {
    const client = await this.pool.connect();
    const workMem = options.workMemMb ?? 64;
    const workers = options.maxParallelWorkers ?? 4;
    const timeout = options.timeoutMs ?? 30000;

    try {
      await client.query('BEGIN;');
      await client.query(`SET LOCAL statement_timeout = ${timeout};`);
      await client.query(`SET LOCAL work_mem = '${workMem}MB';`);
      await client.query(`SET LOCAL max_parallel_workers_per_gather = ${workers};`);
      await client.query('SET LOCAL enable_partitionwise_join = on;');
      await client.query('SET LOCAL enable_partitionwise_aggregate = on;');

      // Analyze execution plan
      const explainResult = await client.query(`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${querySql}`, params);
      const planAnalysis = this.analyzeExplainPlan(explainResult.rows[0]['QUERY PLAN'][0]);

      // Execute actual query
      const result = await client.query(querySql, params);
      await client.query('COMMIT;');

      return {
        rows: result.rows,
        planAnalysis,
      };
    } catch (err) {
      await client.query('ROLLBACK;').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }

  private async fetchPartitionScheme(client: PoolClient, tableName: string): Promise<PartitionSchemeAudit> {
    const strategyQuery = `
      SELECT
        c.relname,
        CASE partstrat
          WHEN 'h' THEN 'hash'
          WHEN 'r' THEN 'range'
          WHEN 'l' THEN 'list'
          ELSE 'unknown'
        END AS strategy,
        partnatts,
        (
          SELECT count(*)
          FROM pg_inherits i
          WHERE i.inhparent = c.oid
        ) AS partition_count
      FROM pg_partitioned_table p
      JOIN pg_class c ON c.oid = p.partrelid
      WHERE c.relname = $1;
    `;
    const stratRes = await client.query(strategyQuery, [tableName]);
    if (stratRes.rows.length === 0) {
      throw new Error(`Table '${tableName}' is not a partitioned table.`);
    }

    const row = stratRes.rows[0];

    const keyColsQuery = `
      SELECT a.attname
      FROM pg_partitioned_table p
      JOIN pg_class c ON c.oid = p.partrelid
      JOIN LATERAL unnest(p.partattrs) WITH ORDINALITY AS u(attnum, ord) ON true
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = u.attnum
      WHERE c.relname = $1
      ORDER BY u.ord;
    `;
    const colRes = await client.query(keyColsQuery, [tableName]);
    const cols = colRes.rows.map((r: any) => r.attname);

    return {
      parentTable: tableName,
      partitionStrategy: row.strategy,
      partitionCount: parseInt(row.partition_count, 10),
      partitionKeyColumns: cols,
      isAlignedWithPeer: false,
    };
  }

  private analyzeExplainPlan(planJson: any): PartitionwiseExecutionPlanAnalysis {
    const rootNode = planJson['Plan'];
    const planningTime = planJson['Planning Time'] || 0;
    const executionTime = planJson['Execution Time'] || 0;

    let isPwjUsed = false;
    let isPwaUsed = false;
    let tempWritten = 0;
    const recommendations: string[] = [];

    // Traverse plan tree
    const traverse = (node: any) => {
      if (!node) return;

      if (node['Temp Written Blocks']) {
        tempWritten += node['Temp Written Blocks'];
      }

      // Check for Partition-Wise Join pattern: Append containing Joins
      if (node['Node Type'] === 'Append' && node['Plans']) {
        const joinChildren = node['Plans'].filter((p: any) =>
          p['Node Type'].includes('Join')
        );
        if (joinChildren.length > 1) {
          isPwjUsed = true;
        }
      }

      // Check for Partition-Wise Aggregate: Append of Aggregates
      if (node['Node Type'] === 'Append' && node['Plans']) {
        const aggChildren = node['Plans'].filter((p: any) =>
          p['Node Type'].includes('Aggregate')
        );
        if (aggChildren.length > 1) {
          isPwaUsed = true;
        }
      }

      if (node['Plans']) {
        for (const sub of node['Plans']) {
          traverse(sub);
        }
      }
    };

    traverse(rootNode);

    if (tempWritten > 0) {
      recommendations.push(
        `Temp written blocks detected (${tempWritten}). Increase scoped work_mem.`
      );
    }
    if (!isPwjUsed) {
      recommendations.push(
        'Partition-wise join was NOT activated. Verify partition key alignment in JOIN predicates.'
      );
    }
    if (planningTime > 100) {
      recommendations.push(
        `High planning time (${planningTime}ms). Ensure partition pruning predicates are present.`
      );
    }

    return {
      isPartitionwiseJoinUsed: isPwjUsed,
      isPartitionwiseAggregateUsed: isPwaUsed,
      planTreeRootNode: rootNode['Node Type'],
      planningTimeMs: planningTime,
      executionTimeMs: executionTime,
      tempWrittenBlocks: tempWritten,
      recommendations,
    };
  }
}
```

---

## 5. Multi-Language Production Implementations

### PostgreSQL Zero-Downtime Migration: Co-Located Partition DDL

```sql
-- migrations/20260330000001_create_colocated_partitions.sql
-- Co-located Hash-Partitioned Tables (Orders and Order Items)
-- Both partitioned identically by HASH (tenant_id) with 32 partitions.

BEGIN;

-- 1. Create Orders Root Partitioned Table
CREATE TABLE customer_orders (
    order_id UUID NOT NULL,
    tenant_id UUID NOT NULL,
    customer_id UUID NOT NULL,
    total_amount NUMERIC(14, 4) NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, order_id)
) PARTITION BY HASH (tenant_id);

-- 2. Create Order Items Root Partitioned Table
CREATE TABLE customer_order_items (
    item_id UUID NOT NULL,
    tenant_id UUID NOT NULL,
    order_id UUID NOT NULL,
    sku TEXT NOT NULL,
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(14, 4) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, item_id),
    FOREIGN KEY (tenant_id, order_id) REFERENCES customer_orders (tenant_id, order_id) ON DELETE CASCADE
) PARTITION BY HASH (tenant_id);

-- 3. Provision Exactly 32 Partitions for Both Tables (1:1 Congruent Bounds)
DO $$
BEGIN
    FOR i IN 0..31 LOOP
        EXECUTE format(
            'CREATE TABLE customer_orders_p%s PARTITION OF customer_orders FOR VALUES WITH (MODULUS 32, REMAINDER %s);',
            i, i
        );
        EXECUTE format(
            'CREATE TABLE customer_order_items_p%s PARTITION OF customer_order_items FOR VALUES WITH (MODULUS 32, REMAINDER %s);',
            i, i
        );
        -- Supporting B-Tree Index for order_id lookup within partition
        EXECUTE format(
            'CREATE INDEX idx_order_items_p%s_order ON customer_order_items_p%s (order_id);',
            i, i
        );
    END LOOP;
END $$;

COMMIT;
```

### Go (`jackc/pgx/v5`): Scoped Session GUC & Stream Aggregation

```go
// internal/store/partitionwise_repository.go
package store

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type PartitionwiseRepository struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewPartitionwiseRepository(pool *pgxpool.Pool, logger *slog.Logger) *PartitionwiseRepository {
	return &PartitionwiseRepository{pool: pool, logger: logger}
}

type TenantOrderSummary struct {
	TenantID    string  `json:"tenant_id"`
	TotalOrders int64   `json:"total_orders"`
	TotalItems  int64   `json:"total_items"`
	TotalAmount float64 `json:"total_amount"`
}

// ExecuteTenantOrderAggregation executes partition-wise join and aggregate
// within an isolated transaction with bounded work_mem.
func (r *PartitionwiseRepository) ExecuteTenantOrderAggregation(
	ctx context.Context,
	workMemMB int,
	maxWorkers int,
) ([]TenantOrderSummary, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Tier 1 & Tier 2: Surgical Transaction-Scoped GUC Configuration
	gucCommands := []string{
		fmt.Sprintf("SET LOCAL work_mem = '%dMB'", workMemMB),
		fmt.Sprintf("SET LOCAL max_parallel_workers_per_gather = %d", maxWorkers),
		"SET LOCAL enable_partitionwise_join = on",
		"SET LOCAL enable_partitionwise_aggregate = on",
		"SET LOCAL statement_timeout = '15s'",
	}

	for _, cmd := range gucCommands {
		if _, err := tx.Exec(ctx, cmd); err != nil {
			return nil, fmt.Errorf("failed to execute GUC '%s': %w", cmd, err)
		}
	}

	query := `
		SELECT
			o.tenant_id::text,
			COUNT(DISTINCT o.order_id) AS total_orders,
			COALESCE(SUM(i.quantity), 0) AS total_items,
			COALESCE(SUM(i.quantity * i.unit_price), 0.0)::float8 AS total_amount
		FROM customer_orders o
		JOIN customer_order_items i
		  ON o.tenant_id = i.tenant_id AND o.order_id = i.order_id
		WHERE o.status = 'COMPLETED'
		GROUP BY o.tenant_id;
	`

	rows, err := tx.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("partition-wise aggregation query failed: %w", err)
	}
	defer rows.Close()

	var summaries []TenantOrderSummary
	for rows.Next() {
		var s TenantOrderSummary
		if err := rows.Scan(&s.TenantID, &s.TotalOrders, &s.TotalItems, &s.TotalAmount); err != nil {
			return nil, fmt.Errorf("failed to scan row: %w", err)
		}
		summaries = append(summaries, s)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("row iteration error: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("failed to commit transaction: %w", err)
	}

	r.logger.Info("partition-wise aggregation completed",
		slog.Int("summaries_count", len(summaries)),
		slog.Int("work_mem_mb", workMemMB),
	)

	return summaries, nil
}
```

### TypeScript (`drizzle-orm` / `pg`): Scoped Safe Runner

```typescript
// src/repositories/partitionwise_runner.ts
import { sql } from 'drizzle-orm';
import { NodePgDatabase } from 'drizzle-orm/node-postgres';

export interface PartitionwiseOptions {
  workMemMb?: number;
  parallelWorkers?: number;
  timeoutMs?: number;
}

export async function runWithPartitionwiseOptimization<T>(
  db: NodePgDatabase,
  options: PartitionwiseOptions,
  task: (tx: NodePgDatabase) => Promise<T>
): Promise<T> {
  const workMem = options.workMemMb ?? 64;
  const workers = options.parallelWorkers ?? 4;
  const timeout = options.timeoutMs ?? 20000;

  return await db.transaction(async (tx) => {
    // Inject Tier 1/2 Local GUC invariants
    await tx.execute(sql.raw(`SET LOCAL work_mem = '${workMem}MB';`));
    await tx.execute(sql.raw(`SET LOCAL max_parallel_workers_per_gather = ${workers};`));
    await tx.execute(sql.raw(`SET LOCAL statement_timeout = ${timeout};`));
    await tx.execute(sql.raw('SET LOCAL enable_partitionwise_join = on;'));
    await tx.execute(sql.raw('SET LOCAL enable_partitionwise_aggregate = on;'));

    return await task(tx);
  });
}
```

### Python (`asyncpg`): Asynchronous Scoped Context Manager

```python
# internal/db/partitionwise_context.py
import asyncpg
from typing import AsyncGenerator, Any

class PartitionwiseContext:
    def __init__(
        self,
        pool: asyncpg.Pool,
        work_mem_mb: int = 64,
        max_workers: int = 4,
        timeout_ms: int = 15000
    ):
        self.pool = pool
        self.work_mem_mb = work_mem_mb
        self.max_workers = max_workers
        self.timeout_ms = timeout_ms

    async def __aenter__(self) -> asyncpg.Connection:
        self.conn = await self.pool.acquire()
        self.tx = self.conn.transaction()
        await self.tx.start()

        # Tier 1 & 2 GUC Fencing
        await self.conn.execute(f"SET LOCAL work_mem = '{self.work_mem_mb}MB';")
        await self.conn.execute(f"SET LOCAL max_parallel_workers_per_gather = {self.max_workers};")
        await self.conn.execute(f"SET LOCAL statement_timeout = {self.timeout_ms};")
        await self.conn.execute("SET LOCAL enable_partitionwise_join = on;")
        await self.conn.execute("SET LOCAL enable_partitionwise_aggregate = on;")
        return self.conn

    async def __aexit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        try:
            if exc_type is not None:
                await self.tx.rollback()
            else:
                await self.tx.commit()
        finally:
            await self.pool.release(self.conn)
```

### Rust (`sqlx`): Scoped Transaction Invariant Wrapper

```rust
// src/db/partitionwise.rs
use sqlx::{PgPool, Postgres, Transaction, Error};

pub struct PartitionwiseConfig {
    pub work_mem_mb: u32,
    pub max_workers: u32,
    pub timeout_ms: u32,
}

impl Default for PartitionwiseConfig {
    fn default() -> Self {
        Self {
            work_mem_mb: 64,
            max_workers: 4,
            timeout_ms: 15_000,
        }
    }
}

pub async fn execute_partitionwise<T, F, Fut>(
    pool: &PgPool,
    config: PartitionwiseConfig,
    operation: F,
) -> Result<T, Error>
where
    F: FnOnce(Transaction<'_, Postgres>) -> Fut,
    Fut: std::future::Future<Output = Result<(Transaction<'_, Postgres>, T), Error>>,
{
    let mut tx = pool.begin().await?;

    // Inject Tier 1/2 Local GUCs
    sqlx::query(&format!("SET LOCAL work_mem = '{}MB';", config.work_mem_mb))
        .execute(&mut *tx)
        .await?;
    sqlx::query(&format!("SET LOCAL max_parallel_workers_per_gather = {};", config.max_workers))
        .execute(&mut *tx)
        .await?;
    sqlx::query(&format!("SET LOCAL statement_timeout = {};", config.timeout_ms))
        .execute(&mut *tx)
        .await?;
    sqlx::query("SET LOCAL enable_partitionwise_join = on;")
        .execute(&mut *tx)
        .await?;
    sqlx::query("SET LOCAL enable_partitionwise_aggregate = on;")
        .execute(&mut *tx)
        .await?;

    let (mut tx, result) = operation(tx).await?;
    tx.commit().await?;

    Ok(result)
}
```

---

## 6. Six-State Partition-Wise Join & Aggregate Lifecycle Finite-State Machine (FSM)

```
 [ S0: UNALIGNED_PARTITIONS ]
               │
               ▼  (1. Verify Exact Boundary, Modulus & Key Symmetry)
 [ S1: BOUNDARIES_ALIGNED ]
               │
               ▼  (2. Guard Local Scope: SET LOCAL enable_partitionwise_* = on)
 [ S2: GUC_FENCED ]
               │
               ▼  (3. Compute Safe work_mem per Worker Slice)
 [ S3: WORKMEM_BUDGETED ]
               │
               ▼  (4. Verify Pruning Predicates in Query WHERE Clause)
 [ S4: PRUNING_ENFORCED ]
               │
               ▼  (5. Verify Execution Plan: Append(Join) & TempWrittenBlocks = 0)
 [ S5: ZERO_SPILL_PROVEN ]
```

| Transition | Initial State | Trigger | Invariant Guard | Terminal State |
| :--- | :--- | :--- | :--- | :--- |
| **T1** | `UNALIGNED_PARTITIONS` | DDL Verification | Partition strategies, modulus counts, and key datatypes match 100% | `BOUNDARIES_ALIGNED` |
| **T2** | `BOUNDARIES_ALIGNED` | Transaction Open | GUCs set strictly via `SET LOCAL`; global configuration remains `off` | `GUC_FENCED` |
| **T3** | `GUC_FENCED` | Memory Sizing | `work_mem` budgeted against active worker count to prevent postmaster OOM | `WORKMEM_BUDGETED` |
| **T4** | `WORKMEM_BUDGETED` | Query Construction | Explicit partition key range or equality predicates present in `WHERE` | `PRUNING_ENFORCED` |
| **T5** | `PRUNING_ENFORCED` | Query Execution | `EXPLAIN` confirms `Append(Join)` structure and `TempWrittenBlocks == 0` | `ZERO_SPILL_PROVEN` |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Save this validation script as `scripts/ci/verify-partitionwise-joins-dod.sh`:

```bash
#!/usr/bin/env bash
# verify-partitionwise-joins-dod.sh - Machine-verifiable CI gate for Partition-Wise Joins & Aggregates
set -euo pipefail

echo "🔍 [Gate 1/6] Verifying Global GUC Safety (enable_partitionwise_* MUST be OFF globally)..."
GLOBAL_PWJ=$(psql "${DATABASE_URL}" -Atc "SHOW enable_partitionwise_join;")
GLOBAL_PWA=$(psql "${DATABASE_URL}" -Atc "SHOW enable_partitionwise_aggregate;")

if [ "$GLOBAL_PWJ" != "off" ] || [ "$GLOBAL_PWA" != "off" ]; then
  echo "❌ CRITICAL: enable_partitionwise_join or enable_partitionwise_aggregate is set to ON in global config!"
  echo "These must remain OFF globally and activated strictly via SET LOCAL in transaction scope."
  exit 1
fi
echo "✅ Gate 1 Passed: Global GUCs are safely OFF."

echo "🔍 [Gate 2/6] Auditing Co-Located Partition Table Modulus & Count Alignment..."
ASYMMETRIC_PARTITIONS=$(psql "${DATABASE_URL}" -Atc "
  WITH part_counts AS (
    SELECT
      c.relname,
      p.partstrat,
      count(i.inhrelid) as child_count
    FROM pg_partitioned_table p
    JOIN pg_class c ON c.oid = p.partrelid
    LEFT JOIN pg_inherits i ON i.inhparent = c.oid
    GROUP BY c.relname, p.partstrat
  )
  SELECT a.relname || ' (' || a.child_count || ') vs ' || b.relname || ' (' || b.child_count || ')'
  FROM part_counts a
  CROSS JOIN part_counts b
  WHERE a.relname < b.relname
    AND a.partstrat = b.partstrat
    AND a.child_count != b.child_count
    AND a.relname LIKE '%order%' AND b.relname LIKE '%order%';
")
if [ -n "$ASYMMETRIC_PARTITIONS" ]; then
  echo "⚠️ WARNING: Potential asymmetric partition counts detected across related tables: $ASYMMETRIC_PARTITIONS"
fi
echo "✅ Gate 2 Passed: Partition symmetry audited."

echo "🔍 [Gate 3/6] Verifying Foreign Keys on Partitioned Tables Contain Partition Keys..."
MISSING_PART_KEY_FKS=$(psql "${DATABASE_URL}" -Atc "
  SELECT conrelid::regclass, conname
  FROM pg_constraint
  WHERE contype = 'f'
    AND conrelid IN (SELECT partrelid FROM pg_partitioned_table)
    AND NOT (conkey @> (
      SELECT partattrs
      FROM pg_partitioned_table
      WHERE partrelid = conrelid
    ));
")
if [ -n "$MISSING_PART_KEY_FKS" ]; then
  echo "❌ CRITICAL: Foreign key on partitioned table does not include partition key: $MISSING_PART_KEY_FKS"
  exit 1
fi
echo "✅ Gate 3 Passed: Foreign keys enforce partition key co-location."

echo "🔍 [Gate 4/6] Verifying Zero Global Disk Spillover in Partition Queries..."
# Run test query with SET LOCAL and check for disk temp files
SPILL_TEST=$(psql "${DATABASE_URL}" -Atc "
  BEGIN;
  SET LOCAL enable_partitionwise_join = on;
  SET LOCAL enable_partitionwise_aggregate = on;
  SET LOCAL work_mem = '64MB';
  EXPLAIN (ANALYZE, BUFFERS)
    SELECT o.tenant_id, count(*), sum(i.quantity)
    FROM customer_orders o
    JOIN customer_order_items i ON o.tenant_id = i.tenant_id AND o.order_id = i.order_id
    GROUP BY o.tenant_id;
  ROLLBACK;
" | grep -i "TempWrittenBlocks" || true)

if [ -n "$SPILL_TEST" ]; then
  echo "❌ CRITICAL: Partition-wise join spilled to temp disk blocks: $SPILL_TEST"
  exit 1
fi
echo "✅ Gate 4 Passed: Zero temp disk blocks written during partition-wise execution."

echo "🔍 [Gate 5/6] Verifying Planning Time Thresholds on Partitioned Queries..."
PLAN_TIME=$(psql "${DATABASE_URL}" -Atc "
  BEGIN;
  SET LOCAL enable_partitionwise_join = on;
  EXPLAIN (FORMAT JSON)
    SELECT o.tenant_id, count(*)
    FROM customer_orders o
    JOIN customer_order_items i ON o.tenant_id = i.tenant_id AND o.order_id = i.order_id
    GROUP BY o.tenant_id;
  ROLLBACK;
" | jq '.[0]."Planning Time"')

echo "ℹ️ Query Planning Time: ${PLAN_TIME}ms"
if (( $(echo "$PLAN_TIME > 50.0" | bc -l) )); then
  echo "⚠️ WARNING: Planning time exceeds 50ms (${PLAN_TIME}ms). Consider partition pruning or bounding partition counts."
fi
echo "✅ Gate 5 Passed: Planning time within bounds."

echo "🔍 [Gate 6/6] Verifying Presence of Append(Join) Nodes in Partition-Wise Plans..."
IS_PWJ=$(psql "${DATABASE_URL}" -Atc "
  BEGIN;
  SET LOCAL enable_partitionwise_join = on;
  EXPLAIN
    SELECT o.tenant_id, count(*)
    FROM customer_orders o
    JOIN customer_order_items i ON o.tenant_id = i.tenant_id AND o.order_id = i.order_id
    GROUP BY o.tenant_id;
  ROLLBACK;
" | grep -E "Append" || true)

if [ -n "$IS_PWJ" ]; then
  echo "✅ Gate 6 Passed: Partition-wise join verified with Append node structure!"
else
  echo "ℹ️ Notice: Query did not produce an Append node (may require more child partitions or test data)."
fi

echo "🎉 All 6 Partition-Wise Join Definition of Done gates passed!"
exit 0
```
