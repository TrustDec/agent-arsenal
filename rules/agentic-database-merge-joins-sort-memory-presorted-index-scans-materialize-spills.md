---
description: PostgreSQL merge join execution, presorted B-Tree index scan leveraging, external merge sort disk spill elimination, work_mem calibration, inner duplicate materialize spooling defense, collation/null ordering alignment, many-to-many Cartesian degradation prevention, and streaming Full Outer Join memory bounds across Go (pgx/v5), TypeScript (Kysely, Drizzle, Prisma), Python (SQLAlchemy, asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{join,merge,sort,order,index,plan,explain,query,memory,spill,database,db,migration,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Merge Joins, Presorted B-Tree Index Scans, Materialize Spooling Elimination, External Merge Sort Spills & Full Outer Join Memory Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design high-throughput transactional joins, ordered pagination streams, time-series alignments, full outer joins, or ETL pipelines across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Double External Merge Sort Disk Spill Avalanche (`Sort Method: external merge Disk`)" (where unindexed join columns force PostgreSQL to inject two sorting nodes that exceed `work_mem`, spilling intermediate runs to disk temp files and causing $15\times–80\times$ latency degradation with massive NVMe write thrashing), the "Inner Duplicate Materialize Spooling & Rescan Buffer Exhaustion Trap" (where non-unique inner join keys force the planner to inject a `Materialize` node that spills to disk when duplicate groups exceed memory), the "Mismatched Collation & Ordering B-Tree Index Bypass Trap" (where differences in collation like `COLLATE "C"` vs `COLLATE "en_US"`, sort order `ASC` vs `DESC`, or `NULLS FIRST` vs `NULLS LAST` prevent the planner from recognizing presorted indexes, silently injecting redundant multi-megabyte sort passes), the "Many-to-Many Merge Join Cartesian Amplification ($O(M \times N)$ Duplicate Run Degradation)" (where high duplicate key counts on both relations force repeated mark-and-restore rescans that turn linear streaming into quadratic nested loops), the "Full Outer Join Streaming Invariance & Memory Starvation" (where unindexed full outer joins exhaust memory or spill to disk instead of executing in $O(1)$ streaming memory over presorted B-Tree paths), and the "Parallel Gather Merge Coordinator Bottleneck" (where worker sort skew overwhelms the coordinator process with multi-stream heap merging) by establishing a strict 5-Tier Merge Join Governance Ladder, formal merge join and external sorting calculus, an autonomous TypeScript `AgenticMergeJoinGuardEngine`, cross-runtime implementations in Go, Python, and Rust, a 6-state optimization finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Merge Join Catastrophes vs The 5-Tier Governance Ladder

A **Merge Join (Sort-Merge Join)** is a symmetric physical join algorithm that merges two input streams ordered by the join keys:
1. **Presorted Scanning or Sorting Phase**: Both the outer and inner relations must produce tuples sorted in identical order by the join attributes. If pre-existing B-Tree indexes provide this ordering (`Index Scan` or `Index Only Scan`), sorting cost is zero ($O(0)$ auxiliary memory). If unindexed, explicit `Sort` nodes are executed.
2. **Merge & Mark-and-Restore Phase**: The engine steps through both streams in lockstep. When keys match, joined tuples are emitted. If the inner relation has duplicate join keys, the join engine marks the first tuple of the duplicate run and restores the scan pointer for subsequent outer matches.

When both inputs are backed by matching B-Tree indexes and the inner relation is unique (e.g. `PRIMARY KEY` or `UNIQUE`), a Merge Join operates in **Zero-Sort Purely Streaming Mode** ($O(M + N)$ linear time and $O(1)$ memory consumption), outperforming Hash Joins on large datasets and eliminating memory pressure completely. However, when autonomous agents generate queries without enforcing Merge Join invariants, six catastrophic failure modes manifest:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   NAIVE MERGE JOIN vs PRODUCTION MERGE INVARIANTS                      │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Unindexed join columns trigger Sort     │ • Presorted B-Tree Index Scan Invariant:   │
│   (Engine executes two Sort nodes; spills │   Join columns backed by matching B-Trees; │
│    to disk: external merge Disk)          │   zero Sort nodes in EXPLAIN plan          │
│ • Non-unique inner join keys spill memory │ • Inner Uniqueness & Materialize Fencing:  │
│   (Materialize node spools duplicate runs │   Inner relation enforces UNIQUE or PK;    │
│    to disk: temp_blks_written > 0)        │   Materialize node eliminated or in-memory │
│ • Collation / NULL ordering mismatch      │ • Collation & Null Ordering Exact Match:   │
│   (Index created with COLLATE "C", query  │   Index definition and ORDER BY/join clause│
│    omits collation -> planner forces Sort)│   share identical collation and NULL rule  │
│ • Many-to-many join on low-entropy keys   │ • Composite Distinct Entropy Invariant:    │
│   (Thousands of duplicate matches force   │   Composite join keys eliminate duplicate  │
│    quadratic O(M * N) mark-and-restore)   │   runs, preserving linear O(M + N) stream  │
│ • Full Outer Join memory exhaustion       │ • Streaming Full Outer Join Memory Bounds: │
│   (Unindexed Full Outer Join spills to    │   Presorted B-Tree scans stream full outer │
│    disk; Hash Join runs out of work_mem)  │   joins in O(1) memory without buffer cliff│
│ • Parallel Gather Merge worker skew       │ • Calibrated Parallel Gather Merge:        │
│   (Single worker finishes early;          │   Parallel workers partition sorted ranges │
│    coordinator CPU pinned on heap merge)  │   evenly to avoid single-thread heap stall │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 5-Tier Merge Join Governance Ladder

```
Level 4: CI Machine-Verifiable DoD Gates (EXPLAIN JSON zero Sort nodes & zero disk spills)
   ▲
Level 3: Streaming Full Outer Join & Pipelined Early-Termination (Zero-buffer streaming)
   ▲
Level 2: Duplicate Run Minimization & Materialize Spooling Fencing (Unique inner keys)
   ▲
Level 1: Single-Pass Zero-Disk-Spill Sorting Memory Calibration (work_mem >= peak sort size)
   ▲
Level 0: Presorted Index Scan Compatibility & Collation Invariance (Matching B-Tree indexes)
```

1. **Tier 0: Presorted Index Scan Compatibility & Collation Invariance**: Ensure B-Tree indexes exist on join columns with exact matching sort order (`ASC`/`DESC`), `NULLS FIRST`/`NULLS LAST`, and identical collation (`COLLATE "C"` or deterministic ICU). The query planner can then execute `Index Scan` or `Index Only Scan` directly, bypassing explicit `Sort` nodes completely.
2. **Tier 1: Single-Pass Zero-Disk-Spill Sorting Memory Calibration**: When sorting is unavoidable (e.g. ad-hoc transformations or partitioned merges), dynamically calibrate `SET LOCAL work_mem` to guarantee that all sorting completes in memory (`Sort Method: quicksort` or `top-N heapsort`), strictly asserting `Sort Method != external merge Disk` and `temp_blks_written == 0`.
3. **Tier 2: Duplicate Run Minimization & Materialize Spooling Fencing**: Ensure that at least one side of the join is strictly unique (`PRIMARY KEY` or `UNIQUE NOT NULL`). When the inner relation is unique, each outer key matches at most once, completely eliminating mark-and-restore rewinds and preventing `Materialize` node disk spillage.
4. **Tier 3: Streaming Full Outer Join & Pipelined Early-Termination**: Utilize index-backed Merge Joins for `FULL OUTER JOIN` operations and queries with matching `ORDER BY ... LIMIT K` clauses. Because both streams are presorted, the engine can emit rows immediately without materializing the full dataset, enabling sub-millisecond early termination.
5. **Tier 4: CI Machine-Verifiable Plan Assertion Gates**: Enforce automated CI linting and test harness assertions on query execution plans via `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` to guarantee zero disk spills (`Temp Written Blocks == 0`), verify the presence of `Merge Join`, and assert absence of redundant `Sort` nodes on indexed pathways.

---

## 2. Mathematical & Algorithmic Foundations

### 2.1 The Two-Way Merge Join Cost Model

Given an outer relation $R$ with $N_R$ tuples occupying $B_R$ pages, and an inner relation $S$ with $N_S$ tuples occupying $B_S$ pages:

When both relations are presorted via B-Tree index scans:
$$\text{Cost}_{\text{presorted}} = \text{Cost}_{\text{IndexScan}}(R) + \text{Cost}_{\text{IndexScan}}(S) + (N_R + N_S) \cdot \text{cpu\_tuple\_cost} + N_{\text{matches}} \cdot \text{cpu\_operator\_cost}$$

Auxiliary memory consumption in presorted mode:
$$M_{\text{presorted}} = O(1) \quad (\text{only current tuple buffers in memory})$$

When relations are unindexed, explicit sorting is required:
$$\text{Cost}_{\text{sort-merge}} = \text{Cost}_{\text{scan}}(R) + \text{Cost}_{\text{scan}}(S) + \text{Cost}_{\text{sort}}(R) + \text{Cost}_{\text{sort}}(S) + (N_R + N_S) \cdot \text{cpu\_tuple\_cost}$$

Where in-memory sort cost ($S_R \le \text{work\_mem}$) is:
$$\text{Cost}_{\text{in-mem-sort}}(R) = 2 \cdot B_R \cdot \text{seq\_page\_cost} + N_R \log_2(N_R) \cdot \text{cpu\_operator\_cost}$$

### 2.2 External Merge Sort Disk Spill Physics

When the size of relation $R$ exceeds available `work_mem` ($S_R > \text{work\_mem}$), PostgreSQL switches from in-memory quicksort to external multi-pass merge sort (`external merge Disk`):

1. **Initial Run Generation**: The engine fills `work_mem` with tuples, sorts them in memory via quicksort, and writes them to a temporary spill file on disk as a sorted run of size $M = \text{work\_mem}$.
2. **Total Runs Generated**:
   $$K = \left\lceil \frac{S_R}{\text{work\_mem}} \right\rceil$$
3. **Merge Passes**: In each pass, the engine merges up to $B - 1$ runs simultaneously (where $B$ is the fan-in buffer capacity):
   $$P = \left\lceil \log_{B-1} (K) \right\rceil = \left\lceil \log_{B-1} \left( \frac{S_R}{\text{work\_mem}} \right) \right\rceil$$
4. **Total Disk I/O Volume**:
   $$V_{\text{disk}} = 2 \cdot S_R \cdot P \cdot 8192 \text{ bytes}$$

For a 10 GB table with default `work_mem = 4MB`:
$$K = \frac{10240}{4} = 2560 \text{ runs}, \quad P = \lceil \log_{31} (2560) \rceil = 3 \text{ passes}$$
$$V_{\text{disk}} = 2 \cdot 10\text{GB} \cdot 3 = 60 \text{ GB of NVMe disk writes and reads!}$$
This turns a 1.2-second in-memory sort into a 45-second I/O-bound disk stall.

### 2.3 Inner Materialize Node Buffer Calculus & Spill Threshold

When inner join keys are non-unique, the planner injects a `Materialize` node to cache the duplicate run. Let $L_{\text{dup}}$ be the maximum duplicate key group size in $S$, and $W_{\text{tuple}}$ be average tuple width:
$$M_{\text{dup}} = L_{\text{dup}} \cdot (W_{\text{tuple}} + 32) \text{ bytes}$$

If $M_{\text{dup}} > \text{work\_mem}$, the `Materialize` node spills the duplicate group to temporary disk files:
$$\text{Spill}_{\text{materialize}} \iff L_{\text{dup}} \cdot (W_{\text{tuple}} + 32) > \text{work\_mem}$$

When inner key uniqueness is guaranteed ($\forall s \in S, \text{count}(s.\text{key}) = 1$):
$$L_{\text{dup}} = 1 \implies M_{\text{dup}} = W_{\text{tuple}} + 32 \ll \text{work\_mem}$$
No `Materialize` disk spill can ever occur, and mark-and-restore cost collapses to $O(1)$.

### 2.4 Duplicate Group Cartesian Degradation Theorem

Let $R$ and $S$ have duplicate runs for key $k_i$ of lengths $m_i$ and $n_i$ respectively. Total Merge Join execution time is:
$$T_{\text{exec}} = \Theta\left(N_R + N_S + \sum_{i} (m_i \cdot n_i)\right)$$

- **Case 1 (Unique Inner, $\forall i, n_i \le 1$)**:
  $$\sum_i (m_i \cdot n_i) \le \sum_i m_i \le N_R \implies T_{\text{exec}} = O(N_R + N_S) \quad \text{[Linear Streaming]}$$
- **Case 2 (Many-to-Many Skew, $m_i \approx N_R, n_i \approx N_S$)**:
  $$\sum_i (m_i \cdot n_i) \approx N_R \cdot N_S \implies T_{\text{exec}} = O(N_R \cdot N_S) \quad \text{[Quadratic Collapse]}$$

---

## 3. Concrete Implementation: TypeScript `AgenticMergeJoinGuardEngine`

The following TypeScript engine analyzes PostgreSQL query plans (`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`), detects unindexed Merge Joins, verifies presorted B-Tree scan compliance, calculates required `work_mem` to prevent external merge sort spills, and enforces machine-verifiable Definition of Done gates.

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
  'Sort Method'?: string;
  'Sort Space Used'?: number;
  'Sort Space Type'?: string;
  'Shared Hit Blocks'?: number;
  'Shared Read Blocks'?: number;
  'Temp Read Blocks'?: number;
  'Temp Written Blocks'?: number;
  'Plans'?: PlanNode[];
  [key: string]: unknown;
}

export interface MergeJoinAuditResult {
  hasMergeJoin: boolean;
  presortedIndexScans: boolean;
  explicitSortCount: number;
  hasDiskSpill: boolean;
  tempWrittenBlocks: number;
  materializeSpills: boolean;
  maxSortSpaceUsedKB: number;
  recommendedWorkMemMB: number;
  status: 'compliant' | 'sort_spill' | 'materialize_spill' | 'unindexed_sort' | 'no_merge_join';
  violations: string[];
  recommendations: string[];
}

export class AgenticMergeJoinGuardEngine {
  private readonly maxPermissibleSessionMemoryMB: number;

  constructor(maxPermissibleSessionMemoryMB: number = 512) {
    this.maxPermissibleSessionMemoryMB = maxPermissibleSessionMemoryMB;
  }

  public auditPlan(explainJson: string): MergeJoinAuditResult {
    const parsed = JSON.parse(explainJson);
    const rootNode: PlanNode = parsed[0]?.Plan;
    if (!rootNode) {
      throw new Error('Invalid EXPLAIN JSON: root Plan node not found');
    }

    const violations: string[] = [];
    const recommendations: string[] = [];
    let hasMergeJoin = false;
    let explicitSortCount = 0;
    let tempWrittenBlocks = 0;
    let materializeSpills = false;
    let maxSortSpaceUsedKB = 0;
    let hasExternalDiskSort = false;

    const traverse = (node: PlanNode, parentNodeType?: string) => {
      if (node['Node Type'] === 'Merge Join') {
        hasMergeJoin = true;
      }

      if (node['Node Type'] === 'Sort') {
        explicitSortCount++;
        const sortMethod = node['Sort Method'] ?? '';
        const sortSpaceType = node['Sort Space Type'] ?? '';
        const sortSpaceUsed = node['Sort Space Used'] ?? 0;

        if (sortSpaceUsed > maxSortSpaceUsedKB) {
          maxSortSpaceUsedKB = sortSpaceUsed;
        }

        if (sortMethod.includes('external merge') || sortSpaceType.toLowerCase() === 'disk') {
          hasExternalDiskSort = true;
          violations.push(
            `Sort node on relation '${node['Relation Name'] ?? 'subplan'}' spilled to disk: method='${sortMethod}', spaceUsed=${sortSpaceUsed}KB`
          );
        }
      }

      if (node['Node Type'] === 'Materialize') {
        const tempWritten = (node['Temp Written Blocks'] as number) ?? 0;
        if (tempWritten > 0) {
          materializeSpills = true;
          violations.push(
            `Materialize node under '${parentNodeType ?? 'parent'}' spilled ${tempWritten} blocks to temporary disk files`
          );
        }
      }

      tempWrittenBlocks += (node['Temp Written Blocks'] as number) ?? 0;

      if (Array.isArray(node.Plans)) {
        for (const child of node.Plans) {
          traverse(child, node['Node Type']);
        }
      }
    };

    traverse(rootNode);

    const presortedIndexScans = hasMergeJoin && explicitSortCount === 0;
    const hasDiskSpill = hasExternalDiskSort || tempWrittenBlocks > 0 || materializeSpills;

    let recommendedWorkMemMB = 4;
    if (maxSortSpaceUsedKB > 0) {
      // Allocate 1.35x peak observed sort memory rounded up to nearest MB
      const calculatedMB = Math.ceil((maxSortSpaceUsedKB * 1.35) / 1024);
      recommendedWorkMemMB = Math.min(this.maxPermissibleSessionMemoryMB, Math.max(4, calculatedMB));
    }

    if (!hasMergeJoin) {
      return {
        hasMergeJoin: false,
        presortedIndexScans: false,
        explicitSortCount: 0,
        hasDiskSpill: false,
        tempWrittenBlocks: 0,
        materializeSpills: false,
        maxSortSpaceUsedKB: 0,
        recommendedWorkMemMB: 4,
        status: 'no_merge_join',
        violations: [],
        recommendations: ['Query does not utilize Merge Join nodes.'],
      };
    }

    if (hasExternalDiskSort) {
      recommendations.push(
        `Eliminate disk sort spills by tuning memory: SET LOCAL work_mem = '${recommendedWorkMemMB}MB'; or adding B-Tree indexes matching join keys.`
      );
    }

    if (explicitSortCount > 0 && !hasDiskSpill) {
      recommendations.push(
        `Query contains ${explicitSortCount} in-memory Sort node(s). Consider creating composite B-Tree indexes on join keys to achieve zero-sort presorted Index Scans.`
      );
    }

    if (materializeSpills) {
      recommendations.push(
        `Materialize node disk spill detected. Enforce a UNIQUE or PRIMARY KEY constraint on the inner join table to eliminate duplicate runs.`
      );
    }

    let status: MergeJoinAuditResult['status'] = 'compliant';
    if (hasExternalDiskSort) status = 'sort_spill';
    else if (materializeSpills) status = 'materialize_spill';
    else if (explicitSortCount > 0) status = 'unindexed_sort';

    return {
      hasMergeJoin,
      presortedIndexScans,
      explicitSortCount,
      hasDiskSpill,
      tempWrittenBlocks,
      materializeSpills,
      maxSortSpaceUsedKB,
      recommendedWorkMemMB,
      status,
      violations,
      recommendations,
    };
  }

  public generateIndexRecommendation(
    outerTable: string,
    outerJoinCol: string,
    innerTable: string,
    innerJoinCol: string,
    collation?: string
  ): string {
    const colClause = collation ? ` COLLATE "${collation}"` : '';
    return [
      `-- Production Invariant: Presorted B-Tree Index Coverage for Merge Join`,
      `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_${outerTable}_${outerJoinCol}_merge`,
      `  ON ${outerTable} (${outerJoinCol}${colClause} ASC);`,
      ``,
      `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_${innerTable}_${innerJoinCol}_merge`,
      `  ON ${innerTable} (${innerJoinCol}${colClause} ASC);`,
    ].join('\n');
  }
}
```

---

## 4. Cross-Runtime Implementations

### 4.1 Go (`jackc/pgx/v5`) Production Implementation

In Go production systems, use transaction-scoped memory governors to ensure zero-disk-spill Merge Joins, verify inner uniqueness, and assert presorted execution:

```go
package db

import (
	"context"
	"encoding/json"
	"fmt"
	"math"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// MergeJoinGovernor manages transaction-scoped memory for zero-disk-spill merge joins
type MergeJoinGovernor struct {
	Pool *pgxpool.Pool
}

// PlanAudit contains parsed execution metrics for merge join inspection
type PlanAudit struct {
	HasMergeJoin       bool
	HasDiskSort        bool
	SortMethod         string
	TempWrittenBlocks  int
	PresortedScans     bool
}

// ExecutePresortedMerge runs a query inside a transaction with calibrated work_mem
func (g *MergeJoinGovernor) ExecutePresortedMerge(
	ctx context.Context,
	estimatedSortRows int64,
	avgRowWidthBytes int,
	fn func(tx pgx.Tx) error,
) error {
	tx, err := g.Pool.BeginTx(ctx, pgx.TxOptions{
		IsoLevel: pgx.ReadCommitted,
	})
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Calculate memory needed if explicit sort is triggered: (width + 32) * rows * 1.35
	totalBytes := int64(float64(estimatedSortRows*int64(avgRowWidthBytes+32)) * 1.35)
	workMemMB := int(math.Ceil(float64(totalBytes) / (1024 * 1024)))
	if workMemMB < 4 {
		workMemMB = 4
	}
	if workMemMB > 512 {
		workMemMB = 512 // Session ceiling to protect host RAM
	}

	// Apply transaction-scoped work_mem
	setQuery := fmt.Sprintf("SET LOCAL work_mem = '%dMB'", workMemMB)
	if _, err := tx.Exec(ctx, setQuery); err != nil {
		return fmt.Errorf("failed to set local work_mem: %w", err)
	}

	if err := fn(tx); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// AssertZeroDiskSpill verifies that an EXPLAIN ANALYZE execution had zero disk spills
func (g *MergeJoinGovernor) AssertZeroDiskSpill(ctx context.Context, query string, args ...any) (*PlanAudit, error) {
	explainQuery := "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + query
	var rawJSON []byte
	err := g.Pool.QueryRow(ctx, explainQuery, args...).Scan(&rawJSON)
	if err != nil {
		return nil, fmt.Errorf("explain analyze failed: %w", err)
	}

	var root []struct {
		Plan map[string]any `json:"Plan"`
	}
	if err := json.Unmarshal(rawJSON, &root); err != nil {
		return nil, fmt.Errorf("unmarshal explain json: %w", err)
	}

	audit := &PlanAudit{PresortedScans: true}
	var inspect func(node map[string]any)
	inspect = func(node map[string]any) {
		nodeType, _ := node["Node Type"].(string)
		if nodeType == "Merge Join" {
			audit.HasMergeJoin = true
		}
		if nodeType == "Sort" {
			audit.PresortedScans = false
			if method, ok := node["Sort Method"].(string); ok {
				audit.SortMethod = method
				if method == "external merge Disk" {
					audit.HasDiskSort = true
				}
			}
		}
		if temp, ok := node["Temp Written Blocks"].(float64); ok {
			audit.TempWrittenBlocks += int(temp)
		}
		if plans, ok := node["Plans"].([]any); ok {
			for _, child := range plans {
				if childMap, ok := child.(map[string]any); ok {
					inspect(childMap)
				}
			}
		}
	}

	if len(root) > 0 && root[0].Plan != nil {
		inspect(root[0].Plan)
	}

	if audit.HasDiskSort || audit.TempWrittenBlocks > 0 {
		return audit, fmt.Errorf("merge join violation: temp_written_blocks=%d, sort_method=%s",
			audit.TempWrittenBlocks, audit.SortMethod)
	}

	return audit, nil
}
```

### 4.2 Python (`SQLAlchemy 2.0` / `asyncpg`) Production Implementation

```python
from typing import AsyncGenerator, Dict, Any, Optional
import json
import math
from contextlib import asynccontextmanager
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text


class MergeJoinMemoryGovernor:
    """Manages transaction-scoped work_mem to eliminate external merge sort disk spills."""

    def __init__(self, session: AsyncSession, max_session_work_mem_mb: int = 512):
        self.session = session
        self.max_work_mem_mb = max_session_work_mem_mb

    @asynccontextmanager
    async def scoped_work_mem(
        self, estimated_sort_rows: int, avg_row_width_bytes: int
    ) -> AsyncGenerator[None, None]:
        # Sizing model: (width + 32) * rows * 1.35 overhead buffer
        total_bytes = int(estimated_sort_rows * (avg_row_width_bytes + 32) * 1.35)
        work_mem_mb = max(4, min(self.max_work_mem_mb, math.ceil(total_bytes / (1024 * 1024))))

        await self.session.execute(text(f"SET LOCAL work_mem = '{work_mem_mb}MB'"))
        try:
            yield
        finally:
            pass  # SET LOCAL is automatically rolled back at transaction completion

    async def verify_zero_spill_merge_join(self, query_sql: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        explain_sql = f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {query_sql}"
        result = await self.session.execute(text(explain_sql), params or {})
        plan_json = result.scalar()
        root = plan_json[0]["Plan"]

        metrics = {
            "has_merge_join": False,
            "has_disk_sort": False,
            "sort_methods": [],
            "temp_written_blocks": 0,
            "presorted_scans": True,
        }

        def traverse(node: Dict[str, Any]):
            node_type = node.get("Node Type", "")
            if node_type == "Merge Join":
                metrics["has_merge_join"] = True
            elif node_type == "Sort":
                metrics["presorted_scans"] = False
                method = node.get("Sort Method", "")
                metrics["sort_methods"].append(method)
                if "external merge" in method or node.get("Sort Space Type") == "Disk":
                    metrics["has_disk_sort"] = True

            metrics["temp_written_blocks"] += node.get("Temp Written Blocks", 0)
            for child in node.get("Plans", []):
                traverse(child)

        traverse(root)

        if metrics["has_disk_sort"] or metrics["temp_written_blocks"] > 0:
            raise RuntimeError(
                f"Merge Join Disk Spill Violation: temp_written_blocks={metrics['temp_written_blocks']}, "
                f"sort_methods={metrics['sort_methods']}"
            )

        return metrics
```

### 4.3 Rust (`sqlx`) Production Implementation

```rust
use sqlx::{PgPool, Postgres, Transaction};
use serde_json::Value;

pub struct MergeJoinGuard {
    pool: PgPool,
    max_work_mem_mb: u32,
}

impl MergeJoinGuard {
    pub fn new(pool: PgPool, max_work_mem_mb: u32) -> Self {
        Self { pool, max_work_mem_mb }
    }

    /// Pre-calibrates transaction work_mem before executing merge-join heavy pipelines
    pub async fn execute_with_calibrated_memory<F, T>(&self, rows: u64, row_width: u32, f: F) -> Result<T, sqlx::Error>
    where
        F: FnOnce(&mut Transaction<'_, Postgres>) -> std::pin::Pin<Box<dyn std::future::Output<Result<T, sqlx::Error>> + Send + '_>>,
    {
        let mut tx = self.pool.begin().await?;
        let required_bytes = ((rows as f64) * ((row_width + 32) as f64) * 1.35) as u64;
        let work_mem_mb = ((required_bytes as f64) / (1024.0 * 1024.0)).ceil() as u32;
        let tuned_mb = work_mem_mb.max(4).min(self.max_work_mem_mb);

        let query = format!("SET LOCAL work_mem = '{}MB'", tuned_mb);
        sqlx::query(&query).execute(&mut *tx).await?;

        let res = f(&mut tx).await?;
        tx.commit().await?;
        Ok(res)
    }

    /// Asserts that a query executes via Merge Join without writing any temporary blocks
    pub async fn assert_zero_spill_plan(&self, sql: &str) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
        let explain_sql = format!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {}", sql);
        let row: (Value,) = sqlx::query_as(&explain_sql).fetch_one(&self.pool).await?;
        let plan_root = &row.0[0]["Plan"];

        let mut has_merge_join = false;
        let mut temp_written_blocks = 0i64;
        let mut has_disk_sort = false;

        let mut stack = vec![plan_root];
        while let Some(node) = stack.pop() {
            if let Some(nt) = node.get("Node Type").and_then(|v| v.as_str()) {
                if nt == "Merge Join" {
                    has_merge_join = true;
                }
                if nt == "Sort" {
                    if let Some(method) = node.get("Sort Method").and_then(|v| v.as_str()) {
                        if method.contains("external merge") {
                            has_disk_sort = true;
                        }
                    }
                }
            }
            if let Some(tw) = node.get("Temp Written Blocks").and_then(|v| v.as_i64()) {
                temp_written_blocks += tw;
            }
            if let Some(children) = node.get("Plans").and_then(|v| v.as_array()) {
                for child in children {
                    stack.push(child);
                }
            }
        }

        if has_disk_sort || temp_written_blocks > 0 {
            return Err(format!(
                "Merge Join Disk Spill: disk_sort={}, temp_written_blocks={}",
                has_disk_sort, temp_written_blocks
            ).into());
        }

        Ok(has_merge_join)
    }
}
```

---

## 5. Six-State Merge Join Optimization Finite-State Machine (FSM)

```
 [S0: JOIN KEY AUDIT]
          │
          ▼ (Check join column indexes & collation parity)
 [S1: PRESORTED INDEX MATCHING]
   ├── [Matches B-Tree Order & Collation] ──► [S4: INNER UNIQUENESS VERIFICATION]
   └── [No Matching B-Tree Index]
          │
          ▼
 [S2: SORT WORK_MEM CALIBRATION]
          │ (Tune SET LOCAL work_mem to absorb in-memory quicksort)
          ▼
 [S3: ZERO-DISK-SPILL ASSERTION]
          │ (Confirm Sort Method != external merge Disk)
          ▼
 [S4: INNER UNIQUENESS VERIFICATION]
   ├── [Inner is UNIQUE or PRIMARY KEY] ──► [S5: ZERO-MATERIALIZE STREAMING]
   └── [Inner Has Duplicate Join Keys]
          │
          ▼ (Fence Materialize buffer: work_mem >= max_duplicate_run * tuple_width)
 [S5: ZERO-MATERIALIZE STREAMING]
          │
          ▼
 [S6: CI EXPLAIN GATE VERIFICATION] ──► [PRODUCTION COMPLETE]
```

- **S0: JOIN KEY AUDIT**: Identify join key columns, data types, and equality operators. Confirm that equality is defined over standard scalar comparison.
- **S1: PRESORTED INDEX MATCHING**: Verify whether B-Tree indexes exist on both tables matching the join columns in identical ordering (`ASC/DESC`), `NULLS FIRST/LAST`, and deterministic collation. If true, bypass sorting completely.
- **S2: SORT WORK_MEM CALIBRATION**: If explicit sorting cannot be avoided, compute expected sort volume using row count and tuple width. Calculate $M_{\text{sort}} = 1.35 \times \text{Rows} \times (\text{Width} + 32)$ and apply transaction-scoped `SET LOCAL work_mem`.
- **S3: ZERO-DISK-SPILL ASSERTION**: Execute `EXPLAIN (ANALYZE, BUFFERS)` to assert that sorting completes via in-memory quicksort or top-N heapsort, with zero temporary blocks written.
- **S4: INNER UNIQUENESS VERIFICATION**: Assert whether the inner relation is unique on the join key. If inner uniqueness is satisfied, eliminate the mark-and-restore duplicate run overhead.
- **S5: ZERO-MATERIALIZE STREAMING**: If duplicates exist, verify that the `Materialize` node does not spill to disk. For `FULL OUTER JOIN`, ensure streaming mode is preserved.
- **S6: CI EXPLAIN GATE VERIFICATION**: Run automated CI static test assertions checking that execution plans contain zero `external merge Disk` methods and `Temp Written Blocks == 0`.

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Metric / Assertion | Failure Remediation |
|---|---|---|---|
| **Gate 1** | Presorted B-Tree Index Scans | Zero `Sort` nodes on indexed join pathways | Create matching `CREATE INDEX ... ON relation (join_col ASC)` on both sides |
| **Gate 2** | Zero External Merge Sort Spills | `Sort Method != 'external merge Disk'` | Increase transaction `SET LOCAL work_mem` or add B-Tree index coverage |
| **Gate 3** | Inner Key Uniqueness Guarantee | `Materialize` node absent or `Temp Written Blocks == 0` | Place unique relation on inner side or enforce `PRIMARY KEY` / `UNIQUE` |
| **Gate 4** | Collation & Sort Order Parity | Collation (`COLLATE "C"`) and direction (`ASC/DESC`) identical | Align index definition and SQL query clauses to identical collation |
| **Gate 5** | Zero Temporary Disk Block Writes | `Temp Written Blocks == 0` across entire plan tree | Calibrate `work_mem` to cover peak sort and materialize memory demands |
| **Gate 6** | Automated CI EXPLAIN Gate | Machine-verifiable JSON audit passes via `AgenticMergeJoinGuardEngine` | Block PR merges if unindexed disk sorts or materialize spills are detected |

By enforcing this 5-Tier Merge Join Governance Ladder, autonomous agents design bulletproof, high-performance relational joins that eliminate external merge sort thrashing, eradicate materialize disk spills, and unlock zero-memory pipelined streaming across modern database fleets.
