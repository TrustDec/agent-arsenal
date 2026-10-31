---
description: PostgreSQL HashAggregate vs GroupAggregate execution strategy optimization, hash table disk spill elimination, hashagg_max_mem and work_mem sizing invariants, pre-sorted B-Tree streaming aggregation, jsonb_agg/array_agg memory explosion defense, and early-termination LIMIT group preservation across Go (pgx/v5), TypeScript (Kysely, Drizzle, Prisma), Python (SQLAlchemy, asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{aggregate,agg,group,groupby,group_by,distinct,sum,count,having,plan,explain,query,database,db,migration,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database HashAggregate vs GroupAggregate, Disk Spilling Batches, hashagg_max_mem Sizing & Streaming Aggregation Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design high-throughput aggregation queries, analytical pipelines, dashboard rollups, multi-tenant metric summaries, or paginated group reporting across PostgreSQL (13–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "HashAggregate Multi-Batch Disk Spill Avalanche (`Spilled Batches: N, Disk Usage: X kB`)" (where an in-memory hash table for grouping exceeds `hashagg_max_mem`, forcing PostgreSQL to partition the hash table into recursive disk-spilled buckets using hash radix partitioning, spiking NVMe write I/O and inflating query latency from 45ms to 18,500ms), the "Group Cardinality Underestimation Cliff ($E_{\text{groups}} \ll A_{\text{groups}}$) & Hash Table Explosion" (where stale `n_distinct` statistics or correlated grouping keys mislead the optimizer into choosing HashAggregate with an undersized bucket array, triggering severe hash chaining and multi-phase disk spills), the "Unindexed GroupAggregate Explicit Sort Spill Trap (`Sort Method: external merge Disk`)" (where forcing GroupAggregate without backing B-Tree index ordering causes PostgreSQL to insert a blocking `Sort` node that exceeds `work_mem` and spills to disk via external merge sorts), the "Array / JSONB Aggregation Memory Explosion Trap (`jsonb_agg` / `array_agg` OOM)" (where stateful collection accumulators dynamically expand beyond tuple sizing estimates, bypassing disk-spill checks and triggering Linux kernel OOM killer `SIGKILL 137` postmaster decapitation), the "Lost Streaming Pipelining & `GROUP BY ... ORDER BY ... LIMIT K` Early-Termination Collapse" (where HashAggregate consumes 100% of input rows to build a complete hash table before returning a single group, while an index-backed GroupAggregate streams groups in $O(K)$ time and $O(1)$ memory), and the "Parallel HashAggregate Dynamic Shared Memory (DSM) Saturation & Leader Serialization Bottleneck" (where every parallel worker builds its own partial hash table, multiplying memory by `max_parallel_workers` and saturating coordinator CPU during gather merges) by establishing a strict 5-Tier Aggregation Governance Ladder, formal hash and streaming aggregation calculus, an autonomous TypeScript `AgenticAggregationGuardEngine`, cross-runtime implementations in Go, Python, and Rust, a 6-state optimization finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Aggregation Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, relational grouping and scalar aggregations (`GROUP BY`, `DISTINCT`, `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`, `array_agg`, `jsonb_agg`) are evaluated through two fundamental execution engines:
1. **HashAggregate**:
   - The executor reads input rows and populates an in-memory hash table keyed by the grouping expressions.
   - For each incoming row, the grouping key is hashed to locate the corresponding hash bucket. If an entry exists, its transition state values (accumulators) are updated in place; if not, a new entry is allocated.
   - **PostgreSQL 13+ Disk Spilling**: If memory exceeds `hashagg_max_mem` (which defaults to `work_mem * hash_mem_multiplier`), the executor dynamically switches to disk-spilling mode. It partitions the entries into radix-based temporary files on disk and processes them in subsequent batches.
2. **GroupAggregate**:
   - Requires input rows to arrive **pre-sorted** by the grouping keys.
   - Because rows belonging to the same group arrive contiguously, the executor only needs to maintain the transition state for the **single currently active group**.
   - When the grouping key changes, the completed aggregate tuple is immediately emitted to the parent plan node, and state accumulators are reset for the next group.
   - Space complexity is constant: $O(1)$ memory overhead. When backed by a presorted B-Tree index scan, GroupAggregate achieves pure streaming pipelining with zero memory pressure and instantaneous early termination.

When autonomous agents or developers write analytical queries or dashboard aggregations without enforcing physical aggregation invariants, six critical failure modes emerge:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             NAIVE AGGREGATION vs PRODUCTION AGGREGATION INVARIANTS                     │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • HashAggregate disk spillover            │ • Single-Batch In-Memory HashAgg Invariant:│
│   (Hash table exceeds hashagg_max_mem;    │   work_mem sized to keep hash table in RAM;│
│    spills to disk batches; p99 latency    │   EXPLAIN must assert:                     │
│    explodes from 50ms to 20,000ms)        │   "Batches: 1, Memory Usage: < work_mem"   │
│ • Cardinality underestimation cliff       │ • Multivariate Statistics & Crossover Fencing:│
│   (Stale n_distinct or correlated columns │   Deploy CREATE STATISTICS (ndistinct) on  │
│    trick planner to pick undersized Hash) │   multi-column groups; fence K >= 100k     │
│ • Unindexed GroupAggregate Sort spill     │ • Presorted B-Tree Index Coverage:         │
│   (Forcing GroupAggregate with no index;  │   Provide composite B-Tree index matching  │
│    triggers external merge sort on disk)  │   group keys; eliminate intermediate Sort  │
│ • jsonb_agg / array_agg Memory OOM        │ • Bounded Accumulation & Streaming Chunks: │
│   (Dynamic payload expansion blows past   │   Enforce bounded subquery limits or array │
│    work_mem; kernel OOM kills postmaster) │   cardinality guards; ban raw huge arrays  │
│ • ORDER BY ... LIMIT destroyed pipelining │ • Early-Termination Presorted Pipelining:  │
│   (HashAggregate blocks on 100% of rows;  │   Pair index-backed GroupAggregate with    │
│    fails early termination; wastes IO)    │   ORDER BY ... LIMIT to stream in O(K) time│
│ • Parallel Hash worker DSM saturation     │ • Worker-Budgeted Dynamic Shared Memory:   │
│   (Workers allocate duplicate hash tables;│   Size work_mem <= Budget / (W + 1); push  │
│    DSM exhaustion & leader bottleneck)    │   down partial aggregates to reduce tuples │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 5-Tier Aggregation Governance Ladder

```
Level 4: CI Machine-Verifiable DoD Gates (EXPLAIN JSON Batches=1, Disk Usage=0, Zero Sort Spills)
   ▲
Level 3: Early-Termination Presorted Streaming (Index-backed GroupAggregate for Top-K groups)
   ▲
Level 2: Composite B-Tree Index Coverage (Eliminate explicit Sort nodes for GroupAggregate)
   ▲
Level 1: Dynamic Transaction-Scoped Memory Calibration (SET LOCAL work_mem & hash_mem_multiplier)
   ▲
Level 0: Single-Batch Memory Prerequisite (Batches == 1, Disk Usage == 0 kB, Zero Spills)
```

---

## 2. Mathematical & Algorithmic Foundations

### 2.1 HashAggregate Memory Footprint Model

Let $K$ be the number of distinct groups produced by the `GROUP BY` clause, $S_{\text{key}}$ be the aggregate byte width of the grouping expressions, $S_{\text{state}}$ be the cumulative byte width of all aggregate transition state accumulators, and $N_{\text{buckets}}$ be the number of hash table bucket pointers (power of 2, typically $N_{\text{buckets}} \ge 1.5 \times K$).

The physical memory footprint $M_{\text{hash}}(K)$ required to maintain the complete hash table in memory without disk spilling is:

$$M_{\text{hash}}(K) = K \times \left( S_{\text{key}} + S_{\text{state}} + S_{\text{entry\_header}} \right) + N_{\text{buckets}} \times 8 \text{ bytes}$$

Where:
- $S_{\text{entry\_header}} = 32 \text{ bytes}$ (PostgreSQL `TupleHashTableEntry` containing `TupleTableSlot`, hash key pointer, and collision link).
- $N_{\text{buckets}} \times 8 \text{ bytes}$ represents the primary hash pointer array allocated in the backend process memory context.

In PostgreSQL 13+, the threshold for disk spilling is governed by `hashagg_max_mem`:

$$\text{hashagg\_max\_mem} = \text{work\_mem} \times \text{hash\_mem\_multiplier}$$

Where `hash_mem_multiplier` defaults to `1.0` (or `2.0` in PostgreSQL 15+).

The condition for **zero-spill in-memory HashAggregate** is:

$$M_{\text{hash}}(K) \le \text{hashagg\_max\_mem}$$

If $M_{\text{hash}}(K) > \text{hashagg\_max\_mem}$, PostgreSQL triggers disk spilling:
- The executor selects a radix bitmask (e.g. 32 to 256 partitions).
- Tuples belonging to overflow partitions are serialized and flushed to disk temporary files (`pgsql_tmp`).
- Total disk write volume for a multi-batch spill with $N_{\text{spill}}$ overflow rows is:

$$V_{\text{disk\_spill}} = 2 \times N_{\text{spill}} \times S_{\text{tuple}} \quad \text{(write to disk during build + read back during batch probe)}$$

### 2.2 GroupAggregate Constant-Memory Streaming Model

Unlike HashAggregate, an index-backed `GroupAggregate` maintains only the current group's transition state in memory:

$$M_{\text{group\_stream}} = S_{\text{key}} + S_{\text{state}} + S_{\text{slot\_header}} = \mathcal{O}(1)$$

Regardless of whether the table contains $10^2$ or $10^9$ rows, memory usage remains constant at a few hundred bytes.

However, if input rows are **not** pre-sorted by a B-Tree index, PostgreSQL must execute an explicit `Sort` node prior to `GroupAggregate`. The memory requirement for `Sort` is:

$$M_{\text{sort}}(N) = N \times \left( S_{\text{key}} + S_{\text{tuple\_header}} + 8 \right)$$

If $M_{\text{sort}}(N) > \text{work\_mem}$, the sort spills to disk via external merge sort (`Sort Method: external merge Disk`), reading and writing temporary runs to disk across $\lceil \log_B(N/M) \rceil$ merge passes, completely negating any streaming advantages.

### 2.3 Early-Termination Speedup Calculus for `GROUP BY ... LIMIT K`

Consider a query aggregating rows and returning the top $K$ groups:
```sql
SELECT tenant_id, count(*), sum(amount)
FROM transactions
GROUP BY tenant_id
ORDER BY tenant_id
LIMIT K;
```

Let $N$ be total table rows, and $G$ be total distinct groups uniformly distributed ($N/G$ rows per group).

- **HashAggregate Pipeline**: Must read all $N$ rows, build the hash table containing all $G$ groups, sort the $G$ groups, and return $K$ rows:
  $$T_{\text{hash}} = \mathcal{O}(N + G \log G)$$
- **Index-Backed GroupAggregate Streaming**: Scans the index on `tenant_id` sequentially, aggregating rows for the current group and emitting each group as soon as the key changes. To produce $K$ groups, it only scans until the $(K+1)$-th group key is reached:
  $$E[\text{tuples scanned}] = K \times \frac{N}{G}$$
  $$T_{\text{group\_stream}} = \mathcal{O}\left(K \times \frac{N}{G}\right)$$

The theoretical speedup factor $\mathcal{S}_{\text{early}}$ is:

$$\mathcal{S}_{\text{early}} = \frac{T_{\text{hash}}}{T_{\text{group\_stream}}} \approx \frac{N}{K \cdot \frac{N}{G}} = \frac{G}{K}$$

For a table with $G = 200,000$ distinct tenants and a query with `LIMIT 20`:

$$\mathcal{S}_{\text{early}} \approx \frac{200,000}{20} = 10,000\times \text{ latency reduction}$$

---

## 3. Concrete Implementation: TypeScript `AgenticAggregationGuardEngine`

The following production-ready engine audits PostgreSQL `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` execution plans, identifies HashAggregate disk spills, unindexed GroupAggregate sort spills, `jsonb_agg` OOM risks, and recommends calibrated indexes and transaction-scoped memory settings.

```typescript
// agentic-aggregation-guard-engine.ts
// Autonomous Plan Auditor & GUC Governor for PostgreSQL HashAggregate and GroupAggregate

export interface AggregationPlanViolation {
  nodeType: 'HashAggregate' | 'GroupAggregate' | 'Sort';
  severity: 'CRITICAL' | 'WARNING' | 'INFO';
  issue: string;
  remedy: string;
  recommendedGucSql?: string;
  recommendedIndexSql?: string;
  metrics: {
    batches?: number;
    diskUsageKb?: number;
    memoryUsageKb?: number;
    sortMethod?: string;
    sortSpaceUsedKb?: number;
    sortSpaceType?: string;
    rowsRemovedByFilter?: number;
    actualRows?: number;
    planRows?: number;
  };
}

export interface AggregationAuditReport {
  isCompliant: boolean;
  hasSpill: boolean;
  hasUnindexedSort: boolean;
  hasEarlyTerminationTrap: boolean;
  violations: AggregationPlanViolation[];
  suggestedWorkMemMB: number;
}

export class AgenticAggregationGuardEngine {
  private readonly defaultWorkMemMB: number;

  constructor(defaultWorkMemMB: number = 4) {
    this.defaultWorkMemMB = defaultWorkMemMB;
  }

  /**
   * Evaluates EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) execution trees.
   */
  public auditPlan(explainJson: string, tableName?: string): AggregationAuditReport {
    let parsed: any;
    try {
      parsed = JSON.parse(explainJson);
    } catch {
      throw new Error('AgenticAggregationGuardEngine: Invalid EXPLAIN JSON input.');
    }

    const rootPlan = Array.isArray(parsed) ? parsed[0]?.Plan : parsed?.Plan;
    if (!rootPlan) {
      throw new Error('AgenticAggregationGuardEngine: Missing root Plan node.');
    }

    const violations: AggregationPlanViolation[] = [];
    let hasSpill = false;
    let hasUnindexedSort = false;
    let hasEarlyTerminationTrap = false;
    let maxMemoryObservedKb = 0;

    const traverse = (node: any, parentNode: any | null) => {
      const nodeType = node['Node Type'] ?? '';
      const actualRows = node['Actual Rows'] ?? 0;
      const planRows = node['Plan Rows'] ?? 0;

      // 1. Audit HashAggregate
      if (nodeType === 'Aggregate' && node['Strategy'] === 'Hashed') {
        const batches = node['Batches'] ?? 1;
        const diskUsageKb = node['Disk Usage'] ?? 0;
        const memoryUsageKb = node['Memory Usage'] ?? 0;
        if (memoryUsageKb > maxMemoryObservedKb) {
          maxMemoryObservedKb = memoryUsageKb;
        }

        // Catastrophe 1: Disk Spill detected
        if (batches > 1 || diskUsageKb > 0) {
          hasSpill = true;
          const neededMemMb = Math.ceil((memoryUsageKb + diskUsageKb * 1.5) / 1024);
          violations.push({
            nodeType: 'HashAggregate',
            severity: 'CRITICAL',
            issue: `HashAggregate multi-batch disk spillover detected: ${batches} batches, ${diskUsageKb.toLocaleString()} kB disk written.`,
            remedy: `Dynamically increase transaction-scoped work_mem to eliminate disk temp file spilling.`,
            recommendedGucSql: `SET LOCAL work_mem = '${Math.max(neededMemMb, 64)}MB'; SET LOCAL hash_mem_multiplier = 2.0;`,
            metrics: { batches, diskUsageKb, memoryUsageKb, actualRows, planRows },
          });
        }

        // Catastrophe 2: Severe Cardinality Underestimation
        if (planRows > 0 && actualRows / planRows > 10.0 && actualRows > 50000) {
          violations.push({
            nodeType: 'HashAggregate',
            severity: 'WARNING',
            issue: `Severe group cardinality underestimation: planned ${planRows} groups vs actual ${actualRows} groups (${(actualRows / planRows).toFixed(1)}x error).`,
            remedy: `Run ANALYZE or deploy CREATE STATISTICS (ndistinct) across multi-column GROUP BY keys.`,
            metrics: { actualRows, planRows },
          });
        }

        // Catastrophe 5: Early-Termination destroyed on ORDER BY ... LIMIT
        if (parentNode && parentNode['Node Type'] === 'Limit') {
          hasEarlyTerminationTrap = true;
          violations.push({
            nodeType: 'HashAggregate',
            severity: 'WARNING',
            issue: `HashAggregate executed under a LIMIT node: must materialize all ${actualRows} groups before emitting top rows.`,
            remedy: `Deploy a composite B-Tree index covering grouping keys to switch to index-backed streaming GroupAggregate with O(K) early termination.`,
            recommendedIndexSql: tableName ? `CREATE INDEX CONCURRENTLY idx_${tableName}_streaming ON ${tableName} (group_col);` : undefined,
            metrics: { actualRows, planRows },
          });
        }
      }

      // 2. Audit GroupAggregate & Underlying Sort
      if (nodeType === 'Aggregate' && (node['Strategy'] === 'Sorted' || node['Strategy'] === 'Plain')) {
        // Check if child node is an explicit Sort node (unindexed)
        if (Array.isArray(node.Plans)) {
          for (const child of node.Plans) {
            if (child['Node Type'] === 'Sort') {
              hasUnindexedSort = true;
              const sortMethod = child['Sort Method'] ?? 'unknown';
              const sortSpaceUsedKb = child['Sort Space Used'] ?? 0;
              const sortSpaceType = child['Sort Space Type'] ?? 'Memory';

              if (sortSpaceType === 'Disk' || sortMethod.includes('external merge')) {
                hasSpill = true;
                const neededMemMb = Math.ceil((sortSpaceUsedKb * 2.0) / 1024);
                violations.push({
                  nodeType: 'Sort',
                  severity: 'CRITICAL',
                  issue: `Explicit Sort prior to GroupAggregate spilled to disk: ${sortMethod} using ${sortSpaceUsedKb.toLocaleString()} kB of disk.`,
                  remedy: `Create a B-Tree index on grouping keys to achieve zero-sort streaming GroupAggregate, or increase work_mem.`,
                  recommendedGucSql: `SET LOCAL work_mem = '${Math.max(neededMemMb, 64)}MB';`,
                  metrics: { sortMethod, sortSpaceUsedKb, sortSpaceType },
                });
              } else {
                violations.push({
                  nodeType: 'Sort',
                  severity: 'INFO',
                  issue: `GroupAggregate requires explicit in-memory Sort (${sortMethod}, ${sortSpaceUsedKb} kB).`,
                  remedy: `Provide a presorted B-Tree index matching group expressions to eliminate the Sort node entirely.`,
                  metrics: { sortMethod, sortSpaceUsedKb, sortSpaceType },
                });
              }
            }
          }
        }
      }

      // Recurse child plans
      if (Array.isArray(node.Plans)) {
        for (const child of node.Plans) {
          traverse(child, node);
        }
      }
    };

    traverse(rootPlan, null);

    const suggestedWorkMemMB = maxMemoryObservedKb > 0
      ? Math.max(Math.ceil((maxMemoryObservedKb * 1.5) / 1024), this.defaultWorkMemMB)
      : this.defaultWorkMemMB;

    return {
      isCompliant: violations.filter(v => v.severity === 'CRITICAL').length === 0,
      hasSpill,
      hasUnindexedSort,
      hasEarlyTerminationTrap,
      violations,
      suggestedWorkMemMB,
    };
  }

  /**
   * Generates optimal composite B-Tree index DDL to convert HashAggregate into zero-sort GroupAggregate.
   */
  public generateIndexDDL(table: string, groupByColumns: string[], orderByColumns: string[] = []): string {
    const cols = [...groupByColumns];
    for (const ob of orderByColumns) {
      if (!cols.includes(ob)) {
        cols.push(ob);
      }
    }
    const idxName = `idx_${table.replace(/[^a-zA-Z0-9_]/g, '')}_${groupByColumns.join('_')}`.slice(0, 63);
    return `CREATE INDEX CONCURRENTLY IF NOT EXISTS ${idxName} ON ${table} (${cols.join(', ')});`;
  }
}
```

---

## 4. Cross-Runtime Implementations

### 4.1 Go (`jackc/pgx/v5`) Production Aggregation Governor & Plan Auditor

In Go microservices and background analytical handlers, dynamically calibrate `SET LOCAL work_mem` and assert zero-spill HashAggregate compliance:

```go
package db

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// AggregationGovernor guarantees zero-spill aggregation execution
type AggregationGovernor struct {
	Pool *pgxpool.Pool
}

// ExecuteWithCalibratedAggMemory executes an analytical aggregation query with transaction-scoped memory
func (g *AggregationGovernor) ExecuteWithCalibratedAggMemory(
	ctx context.Context,
	workMemMB int,
	hashMemMultiplier float64,
	fn func(tx pgx.Tx) error,
) error {
	tx, err := g.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Inject transaction-scoped memory barriers
	setMemSQL := fmt.Sprintf("SET LOCAL work_mem = '%dMB'", workMemMB)
	if _, err := tx.Exec(ctx, setMemSQL); err != nil {
		return fmt.Errorf("set local work_mem failed: %w", err)
	}

	if hashMemMultiplier > 1.0 {
		setMultSQL := fmt.Sprintf("SET LOCAL hash_mem_multiplier = '%.1f'", hashMemMultiplier)
		if _, err := tx.Exec(ctx, setMultSQL); err != nil {
			return fmt.Errorf("set local hash_mem_multiplier failed: %w", err)
		}
	}

	if err := fn(tx); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// AuditAggregationPlan verifies that an EXPLAIN plan contains zero disk spills and batches == 1
func (g *AggregationGovernor) AuditAggregationPlan(ctx context.Context, querySQL string, args ...any) error {
	explainSQL := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s", querySQL)

	ctxTimeout, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	var rawJSON []byte
	if err := g.Pool.QueryRow(ctxTimeout, explainSQL, args...).Scan(&rawJSON); err != nil {
		return fmt.Errorf("explain query failed: %w", err)
	}

	var plans []struct {
		Plan map[string]any `json:"Plan"`
	}
	if err := json.Unmarshal(rawJSON, &plans); err != nil || len(plans) == 0 {
		return fmt.Errorf("parse explain json failed: %w", err)
	}

	var totalSpilledBatches float64
	var totalDiskUsageKb float64
	var externalMergeSortFound bool

	var inspect func(node map[string]any)
	inspect = func(node map[string]any) {
		nodeType, _ := node["Node Type"].(string)
		strategy, _ := node["Strategy"].(string)

		// Check HashAggregate disk spill
		if nodeType == "Aggregate" && strategy == "Hashed" {
			if batches, ok := node["Batches"].(float64); ok && batches > 1 {
				totalSpilledBatches += (batches - 1)
			}
			if diskUsage, ok := node["Disk Usage"].(float64); ok && diskUsage > 0 {
				totalDiskUsageKb += diskUsage
			}
		}

		// Check Sort disk spill prior to GroupAggregate
		if nodeType == "Sort" {
			if sortSpaceType, ok := node["Sort Space Type"].(string); ok && sortSpaceType == "Disk" {
				externalMergeSortFound = true
			}
			if sortMethod, ok := node["Sort Method"].(string); ok && sortMethod == "external merge Disk" {
				externalMergeSortFound = true
			}
		}

		if children, ok := node["Plans"].([]any); ok {
			for _, c := range children {
				if childMap, ok := c.(map[string]any); ok {
					inspect(childMap)
				}
			}
		}
	}

	inspect(plans[0].Plan)

	if totalSpilledBatches > 0 || totalDiskUsageKb > 0 {
		return fmt.Errorf("aggregation spill violation: %.0f spilled batches, %.0f kB disk used", totalSpilledBatches, totalDiskUsageKb)
	}
	if externalMergeSortFound {
		return fmt.Errorf("sort spill violation: explicit Sort spilled to disk prior to GroupAggregate")
	}

	return nil
}
```

### 4.2 Python (`SQLAlchemy 2.0` / `asyncpg`) Plan Invariant Assertion

In Python FastAPI or Celery tasks, intercept aggregation queries to guarantee zero disk spills:

```python
import json
import logging
from typing import Any, Dict
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text

logger = logging.getLogger(__name__)

async def execute_zero_spill_aggregation(
    session: AsyncSession,
    query_sql: str,
    params: Dict[str, Any],
    work_mem_mb: int = 64
) -> list[dict]:
    """Executes aggregation with transaction-scoped memory to prevent disk spills."""
    async with session.begin_nested():
        # Calibrate memory bounds inside subtransaction
        await session.execute(text(f"SET LOCAL work_mem = '{work_mem_mb}MB'"))
        await session.execute(text("SET LOCAL hash_mem_multiplier = '2.0'"))

        result = await session.execute(text(query_sql), params)
        return [dict(row._mapping) for row in result.fetchall()]

async def assert_plan_zero_spill(
    session: AsyncSession,
    query_sql: str,
    params: Dict[str, Any]
) -> None:
    """Verifies that the query execution plan contains 0 spilled batches and 0 kB disk writes."""
    explain_sql = f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {query_sql}"
    res = await session.execute(text(explain_sql), params)
    raw_json = res.scalar()
    parsed = json.loads(raw_json)[0]["Plan"]

    def check_node(node: dict):
        node_type = node.get("Node Type")
        strategy = node.get("Strategy")

        if node_type == "Aggregate" and strategy == "Hashed":
            batches = node.get("Batches", 1)
            disk_usage = node.get("Disk Usage", 0)
            if batches > 1 or disk_usage > 0:
                raise RuntimeError(
                    f"HashAggregate disk spill violation: {batches} batches, {disk_usage} kB disk written"
                )

        if node_type == "Sort":
            if node.get("Sort Space Type") == "Disk" or "external merge" in node.get("Sort Method", ""):
                raise RuntimeError("Sort node spilled to disk prior to GroupAggregate")

        for child in node.get("Plans", []):
            check_node(child)

    check_node(parsed)
```

### 4.3 Rust (`sqlx`) Zero-Spill Aggregation Harness

```rust
use sqlx::{PgPool, Postgres, Transaction};
use serde_json::Value;

pub async fn execute_calibrated_aggregation<'a, F, T>(
    pool: &PgPool,
    work_mem_mb: u32,
    f: F,
) -> Result<T, Box<dyn std::error::Error + Send + Sync>>
where
    F: for<'c> FnOnce(&'c mut Transaction<'_, Postgres>) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<T, sqlx::Error>> + Send + 'c>>,
{
    let mut tx = pool.begin().await?;

    // Transaction-scoped memory governance
    let set_mem = format!("SET LOCAL work_mem = '{}MB'", work_mem_mb);
    sqlx::query(&set_mem).execute(&mut *tx).await?;
    sqlx::query("SET LOCAL hash_mem_multiplier = '2.0'").execute(&mut *tx).await?;

    let res = f(&mut tx).await?;
    tx.commit().await?;
    Ok(res)
}

pub async fn verify_plan_zero_spill(
    pool: &PgPool,
    query: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let explain_query = format!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {}", query);
    let row: (Value,) = sqlx::query_as(&explain_query).fetch_one(pool).await?;
    let root = &row.0[0]["Plan"];

    fn inspect(node: &Value) -> Result<(), String> {
        let node_type = node["Node Type"].as_str().unwrap_or_default();
        let strategy = node["Strategy"].as_str().unwrap_or_default();

        if node_type == "Aggregate" && strategy == "Hashed" {
            let batches = node["Batches"].as_i64().unwrap_or(1);
            let disk_usage = node["Disk Usage"].as_i64().unwrap_or(0);
            if batches > 1 || disk_usage > 0 {
                return Err(format!("HashAggregate disk spill: {} batches, {} kB disk used", batches, disk_usage));
            }
        }

        if node_type == "Sort" {
            let space_type = node["Sort Space Type"].as_str().unwrap_or_default();
            if space_type == "Disk" {
                return Err("Sort node spilled to disk prior to GroupAggregate".to_string());
            }
        }

        if let Some(plans) = node["Plans"].as_array() {
            for child in plans {
                inspect(child)?;
            }
        }
        Ok(())
    }

    inspect(root).map_err(|e| e.into())
}
```

### 4.4 PostgreSQL Canary Schema, Presorted B-Tree Indexing & GUC Test Harness

```sql
-- canary-aggregation-benchmark.sql
-- Demonstrates HashAggregate disk spillover vs presorted GroupAggregate streaming

CREATE TABLE IF NOT EXISTS customer_events (
    id BIGSERIAL PRIMARY KEY,
    tenant_id INT NOT NULL,
    status VARCHAR(32) NOT NULL,
    amount NUMERIC(12, 2) NOT NULL,
    payload JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed with 1,000,000 events across 50,000 distinct tenants
INSERT INTO customer_events (tenant_id, status, amount, payload, created_at)
SELECT
    (random() * 50000)::INT,
    (ARRAY['COMPLETED', 'PENDING', 'FAILED', 'REFUNDED'])[(random() * 3 + 1)::INT],
    (random() * 500 + 10)::NUMERIC(12,2),
    jsonb_build_object('trace_id', gen_random_uuid()),
    NOW() - (random() * interval '30 days')
FROM generate_series(1, 1000000);

ANALYZE customer_events;

-- ANTI-PATTERN 1: Undersized work_mem triggers HashAggregate disk spill
SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT tenant_id, count(*), sum(amount)
FROM customer_events
GROUP BY tenant_id;
-- Output reveals:
-- -> HashAggregate (cost=... rows=50000 width=40) (actual rows=50000 ...)
--      Batches: 5  Memory Usage: 4129kB  Disk Usage: 8432kB

-- PRODUCTION INVARIANT 1: Calibrated transaction-scoped memory eliminates disk spill
BEGIN;
SET LOCAL work_mem = '64MB';
SET LOCAL hash_mem_multiplier = '2.0';
EXPLAIN (ANALYZE, BUFFERS)
SELECT tenant_id, count(*), sum(amount)
FROM customer_events
GROUP BY tenant_id;
-- Output reveals:
-- -> HashAggregate (cost=... rows=50000 width=40) (actual rows=50000 ...)
--      Batches: 1  Memory Usage: 12540kB  Disk Usage: 0kB
COMMIT;

-- PRODUCTION INVARIANT 2: Presorted B-Tree Index enables zero-memory GroupAggregate
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_cust_events_tenant_status
ON customer_events (tenant_id, status);

-- Pipelined streaming GroupAggregate with ORDER BY ... LIMIT K early termination:
EXPLAIN (ANALYZE, BUFFERS)
SELECT tenant_id, status, count(*), sum(amount)
FROM customer_events
GROUP BY tenant_id, status
ORDER BY tenant_id, status
LIMIT 20;
-- Output reveals:
-- -> Limit (actual rows=20 time=0.045..0.082 loops=1)
--      -> GroupAggregate (actual rows=20 time=0.044..0.079 loops=1)
--           -> Index Scan using idx_cust_events_tenant_status (actual rows=422 time=0.021..0.054 loops=1)
-- Execution Time: 0.112 ms (vs 125 ms for full HashAggregate!)
```

---

## 5. Six-State Aggregation Optimization Finite-State Machine (FSM)

```
        ┌─────────────────────────────────────────────────────────────┐
        │ [State 0: UNPROFILED]                                       │
        │ Initial SQL aggregation query generated by agent/developer  │
        └──────────────────────────────┬──────────────────────────────┘
                                       │ Profile via EXPLAIN (ANALYZE, BUFFERS)
                                       ▼
        ┌─────────────────────────────────────────────────────────────┐
        │ [State 1: CARDINALITY_PROFILED]                             │
        │ Check actual distinct groups K vs estimated plan rows E     │
        └───────┬─────────────────────────────────────────────┬───────┘
                │ K < 100,000 (Low/Med Cardinality)            │ K >= 100,000 or ORDER BY ... LIMIT K
                ▼                                             ▼
┌───────────────────────────────────────────┐ ┌───────────────────────────────────────────┐
│ [State 2A: HASH_AGG_CANDIDATE]            │ │ [State 2B: STREAMING_GROUP_CANDIDATE]     │
│ Calculate peak M_hash memory footprint    │ │ Evaluate B-Tree presorted index coverage  │
└─────────────────────┬─────────────────────┘ └─────────────────────┬─────────────────────┘
                      │                                             │
                      │ M_hash > work_mem                           │ Missing index on grouping keys
                      ▼                                             ▼
┌───────────────────────────────────────────┐ ┌───────────────────────────────────────────┐
│ [State 3A: MEMORY_CALIBRATION]            │ │ [State 3B: COMPOSITE_INDEX_SYNTHESIS]     │
│ Inject SET LOCAL work_mem + hash_mem_mult │ │ Emit CREATE INDEX CONCURRENTLY (cols...)  │
└─────────────────────┬─────────────────────┘ └─────────────────────┬─────────────────────┘
                      │                                             │
                      └──────────────────────┬──────────────────────┘
                                             │ Re-run EXPLAIN (FORMAT JSON)
                                             ▼
        ┌─────────────────────────────────────────────────────────────┐
        │ [State 4: PLAN_VERIFIED]                                    │
        │ Assert: Batches == 1, Disk Usage == 0, Sort Spills == 0     │
        └──────────────────────────────┬──────────────────────────────┘
                                       │ Pass 6-Gate DoD CI Verification
                                       ▼
        ┌─────────────────────────────────────────────────────────────┐
        │ [State 5: PRODUCTION_LOCKED]                                │
        │ Immutable AST template committed; continuous APM telemetry  │
        └─────────────────────────────────────────────────────────────┘
```

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Check | Failure Condition | Remediating Action |
|:---|:---|:---|:---|
| **Gate 1: Zero Disk Spills** | `EXPLAIN (ANALYZE, FORMAT JSON)` | `node.Batches > 1` or `node.Disk Usage > 0` | Size `SET LOCAL work_mem` $\ge 1.5 \times M_{\text{hash}}$ |
| **Gate 2: Zero External Merge Sorts** | `EXPLAIN (ANALYZE, FORMAT JSON)` | `node.Sort Space Type == 'Disk'` | Create presorted B-Tree index or increase `work_mem` |
| **Gate 3: Early-Termination Pipelining** | Query has `ORDER BY ... LIMIT K` | Plan uses `HashAggregate` on 100% rows | Replace with index-backed `GroupAggregate` |
| **Gate 4: Multi-Column Cardinality** | Cross-column correlation check | $|E - A| / A > 0.80$ on $>50\text{k}$ rows | Deploy `CREATE STATISTICS (ndistinct)` on group cols |
| **Gate 5: Memory Leak & Scope Fencing** | GUC session safety audit | `SET work_mem` leaked outside transaction | Mandate `SET LOCAL` within explicit transaction block |
| **Gate 6: Array/JSON Accumulation Guard** | `jsonb_agg` / `array_agg` check | Unbounded group array aggregation | Enforce subquery row-limit or streaming cursor |

---

## Conclusion & Operational Discipline

Autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi) MUST NOT generate aggregation queries without verifying physical execution plans. Always assert `Batches == 1` and `Disk Usage == 0 kB` for in-memory HashAggregates, back high-cardinality groups ($K \ge 100,000$) and Top-$K$ paginated queries with composite B-Tree presorted indexes, and scope all GUC adjustments strictly via `SET LOCAL` within explicit transaction boundaries.
