---
description: PostgreSQL bitmap index scan and bitmap heap scan execution, TIDBitmap lossy page degradation elimination, work_mem sizing invariants, index recheck CPU degradation defense, BitmapAnd/BitmapOr composite index consolidation, physical correlation crossover, and early-termination LIMIT ordering preservation across Go (pgx/v5), TypeScript (Kysely, Drizzle, Prisma), Python (SQLAlchemy, asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{bitmap,scan,heap,index,recheck,lossy,plan,explain,query,filter,database,db,migration,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Bitmap Scans, TIDBitmap Lossy Degradation, work_mem Sizing Invariants & Index Recheck Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design high-throughput filtered queries, multi-predicate searches, pagination pipelines, analytical reports, or transactional APIs across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Lossy TIDBitmap Page Degradation & Index Recheck Avalanche (`Rows Removed by Index Recheck: Millions`)" (where an in-memory bitmap of matching tuple pointers exceeds `work_mem`, forcing PostgreSQL to downgrade exact tuple-level pointers into lossy page-level markers, which forces the executor to deserialize, evaluate, and discard millions of non-matching tuples on every page, spiking CPU to 100% and inflating query latency from 12ms to 8,500ms), the "Uncalibrated `work_mem` Sizing & The 4MB Default Trap" (where default session memory settings trigger unexpected lossy bitmap degradation during data growth spikes), the "Multi-Index `BitmapAnd` / `BitmapOr` Composite Index Antipattern" (where developers and agents combine multiple single-column indexes via runtime bitmap boolean operations instead of deploying a single unified composite B-Tree index, causing redundant index traversals and memory bloat), the "Lost Ordering & `ORDER BY ... LIMIT` Early-Termination Collapse" (where `Bitmap Heap Scan` sorts heap pages in physical block order, obliterating B-Tree index ordering and forcing the engine to scan every matching tuple in the entire table and perform an explicit sort instead of streaming the top $K$ tuples via an `Index Scan`), the "Physical Correlation Inversion ($\rho \approx 1$ vs $\rho \approx 0$)" (where highly clustered data incurs redundant bitmap allocation overhead when a plain index scan would execute with near-zero memory), and the "Parallel Bitmap Heap Scan Dynamic Block Allocation & Worker Starvation" (where parallel workers contend on buffer locks or desynchronize on lossy page rechecks) by establishing a strict 5-Tier Bitmap Scan Governance Ladder, formal bitmap memory calculus, an autonomous TypeScript `AgenticBitmapScanGuardEngine`, cross-runtime implementations in Go, Python, and Rust, a 6-state optimization finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Bitmap Scan Catastrophes vs The 5-Tier Governance Ladder

A **Bitmap Scan** in PostgreSQL is a two-phase physical execution path designed to bridge the gap between sequential table scans (`Seq Scan`) and direct index lookups (`Index Scan`):
1. **The Index Phase (`Bitmap Index Scan`)**: The executor evaluates search predicates across one or more indexes (B-Tree, GIN, GiST, BRIN, or Bloom) without accessing heap table pages. It constructs an in-memory data structure called a **TIDBitmap** (Tuple Identifier Bitmap), collecting physical ItemPointers (`BlockNumber`, `OffsetNumber`). If a query filters on multiple columns covered by independent indexes, the executor can generate multiple TIDBitmaps and combine them using bitwise operations (`BitmapAnd` or `BitmapOr`).
2. **The Heap Phase (`Bitmap Heap Scan`)**: The executor iterates through the TIDBitmap in physical block order (`BlockNumber 0, 1, 2, ...`). It fetches each 8KB heap buffer page from `shared_buffers` (or physical storage) exactly once, in sequential or near-sequential order, avoiding the chaotic random I/O disk thrashing that plagues unclustered plain `Index Scan` operations.

When table cardinality is large and physical clustering is low ($\text{correlation} \approx 0$), exact bitmap scans provide substantial I/O efficiency. However, when autonomous agents generate dynamic SQL, ORM filtering queries, or complex dashboard filters without enforcing bitmap scan invariants, six catastrophic failure modes emerge:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               NAIVE BITMAP SCAN vs PRODUCTION BITMAP SCAN INVARIANTS                   │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Lossy TIDBitmap page degradation        │ • Exact Tuple-Level Bitmap Invariant:      │
│   (Bitmap exceeds work_mem; tbm_lossify   │   work_mem dynamically sized to keep all   │
│    converts tuples to lossy pages; CPU    │   pointers exact; EXPLAIN must assert:     │
│    spikes evaluating millions of rechecks)│   "Heap Blocks: exact=N lossy=0"           │
│ • Uncalibrated work_mem (4MB default)     │ • Dynamic Transaction-Scoped Sizing:       │
│   (Large result sets trip memory ceiling; │   Calculate TIDBitmap footprint; inject    │
│    degrades into lossy mode under load)   │   SET LOCAL work_mem = '64MB' on batch runs│
│ • Disjoint multi-index BitmapAnd/BitmapOr │ • Composite Index Consolidation Invariant: │
│   (Scans 3 independent indexes into bitmap│   Replace multi-index bitmap boolean ops   │
│    tables; consumes memory & CPU cycles)  │   with single composite B-Tree (col1, col2)│
│ • ORDER BY ... LIMIT destroyed ordering   │ • Plain Index Scan Early-Termination Guard:│
│   (Bitmap Heap Scan sorts by block number;│   Enforce Index Scan for ORDER BY ... LIMIT│
│    forces full scan + explicit Sort node) │   to stream top K tuples in O(K) time      │
│ • High correlation bitmap scan overhead   │ • Correlation Crossover Thresholding:      │
│   (Running bitmap scan when correlation   │   When |correlation| >= 0.80, prefer plain │
│    >= 0.85; adds pointless memory allocs) │   Index Scan or Index Only Scan            │
│ • Parallel worker recheck desynchronization│ • Worker-Balanced Parallel Bitmap Scan:   │
│   (Workers contend on lossy page buffers; │   Keep parallel bitmap exact; size chunks  │
│    LWLock BufferContent saturates CPU)    │   to avoid worker tail-latency stalls      │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 5-Tier Bitmap Scan Governance Ladder

```
Level 4: CI Machine-Verifiable DoD Gates (EXPLAIN JSON lossy=0 & zero recheck rows)
   ▲
Level 3: Plain Index Scan Early-Termination Invariance (ORDER BY ... LIMIT K preservation)
   ▲
Level 2: Composite Index Consolidation (Eliminate multi-index BitmapAnd / BitmapOr)
   ▲
Level 1: Dynamic Transaction-Scoped work_mem Sizing (Calculated TIDBitmap headroom)
   ▲
Level 0: Exact Tuple-Level Bitmap Prerequisite (Lossy Pages == 0, Recheck Rows == 0)
```

1. **Tier 0: Exact Tuple-Level Bitmap Prerequisite**: In any query plan executing a `Bitmap Heap Scan`, the number of lossy pages must be strictly zero (`Heap Blocks: lossy=0`). Furthermore, the number of tuples discarded by index condition rechecks must be zero (`Rows Removed by Index Recheck: 0`). Any query exhibiting lossy pages is classified as a severe performance defect.
2. **Tier 1: Dynamic Transaction-Scoped `work_mem` Sizing**: Size `work_mem` to comfortably hold the worst-case TIDBitmap for the expected result set cardinality. For analytical or bulk search queries matching $>50,000$ pages, dynamically issue `SET LOCAL work_mem = '64MB'` (or higher within session memory limits) within the transaction boundary.
3. **Tier 2: Composite Index Consolidation**: Audit execution plans exhibiting `BitmapAnd` or `BitmapOr` nodes combining multiple single-column indexes. Replace the fragmented indexes with a unified multi-column composite B-Tree index ordered by `(equality_columns..., range_or_sort_columns...)` to eliminate intermediate bitmap structures and enable single-seek execution.
4. **Tier 3: Plain Index Scan Early-Termination Invariance**: In queries combining filtering with `ORDER BY ... LIMIT K`, prevent the query planner from choosing a `Bitmap Heap Scan` followed by an explicit `Sort`. Ensure composite indexes match the filter AND sort order so the executor can stream tuples through a plain `Index Scan` or `Index Only Scan` with early termination after $K$ rows.
5. **Tier 4: CI Machine-Verifiable Plan Assertion Gates**: Enforce automated CI linting and test harness assertions on query execution plans via `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` to guarantee `Lossy Blocks == 0`, `Rows Removed by Index Recheck == 0`, zero external merge disk spills, and sub-millisecond execution times.

---

## 2. Mathematical & Algorithmic Foundations

### 2.1 The PostgreSQL TIDBitmap Internal Data Structure

In PostgreSQL (`src/backend/nodes/tidbitmap.c`), a **TIDBitmap** (Tuple Identifier Bitmap) stores the physical pointers of candidate tuples identified by an index scan. A physical pointer (TID - Tuple ID, or `ItemPointerData`) consists of a 32-bit `BlockNumber` (page number) and a 16-bit `OffsetNumber` (line pointer index on that page).

A TIDBitmap contains a dynamic hash table of `PagetableEntry` structures:
- **Exact Entry (`entry->is_lossy = false`)**: Contains a bit array representing the individual tuple offsets on that page. Each bit indicates whether the tuple at that offset matched the index condition:
  $$\text{Memory}_{\text{exact\_entry}} \approx \text{sizeof(PagetableEntry)} + \left\lceil \frac{\text{MaxOffsetNumber}}{64} \right\rceil \times 8 \text{ bytes} \approx 80 \text{ to } 128 \text{ bytes}$$
- **Lossy Entry (`entry->is_lossy = true`)**: When the total memory consumed by the hash table and entries reaches the memory limit derived from `work_mem` ($\text{maxbytes} = \text{work\_mem} \times 1024$), PostgreSQL invokes `tbm_lossify()`. It frees the detailed offset bit arrays and converts entries into single-bit page flags:
  $$\text{Memory}_{\text{lossy\_entry}} \approx \text{sizeof(PagetableEntry)} \approx 48 \text{ bytes}$$

### 2.2 The Lossy Recheck Avalanche & Discarded Tuple Amplification

When a `PagetableEntry` becomes lossy, the executor no longer knows *which* tuples on the 8KB page matched the index condition—it only knows that *at least one* tuple on that page might match.

During the subsequent `Bitmap Heap Scan` phase (`nodeBitmapHeapscan.c`), the executor must read the physical 8KB page and perform a **full tuple recheck** against the original search condition (`Recheck Cond: ...`) for *every single tuple* residing on that page.

Let:
- $N_{\text{lossy}}$ = Number of lossy pages in the TIDBitmap
- $D$ = Average tuple density per 8KB page ($D = \frac{N_{\text{total\_tuples}}}{N_{\text{total\_pages}}}$, typically 50 to 200 tuples/page)
- $S$ = True predicate selectivity ($0 < S < 1$)
- $T_{\text{recheck\_cost}}$ = CPU time required to unpack and evaluate the predicate on one tuple

The number of tuples evaluated on lossy pages is:
$$N_{\text{evaluated}} = N_{\text{lossy}} \times D$$

The number of matching tuples found on those lossy pages is:
$$N_{\text{matched}} \approx N_{\text{lossy}} \times D \times S$$

The number of non-matching tuples deserialized, evaluated, and discarded is:
$$N_{\text{discarded}} = N_{\text{evaluated}} - N_{\text{matched}} = N_{\text{lossy}} \times D \times (1 - S)$$

#### Concrete CPU Amplification Example
Consider a table with 10,000,000 rows across 100,000 pages ($D = 100$ tuples/page). A query matches 5% of rows ($S = 0.05$, 500,000 matching rows across 50,000 pages).
If `work_mem` is 4MB, the bitmap degrades to lossy after ~25,000 pages, resulting in 25,000 lossy pages:
$$N_{\text{discarded}} = 25,000 \times 100 \times (1 - 0.05) = 2,375,000 \text{ discarded tuples!}$$
The PostgreSQL executor is forced to evaluate $2.375$ million non-matching tuples in memory, logging:
`Rows Removed by Index Recheck: 2375000`
Query execution latency surges from 18ms to 4,200ms with 100% single-core CPU utilization.

### 2.3 Required `work_mem` Calculus for Exact Bitmaps

To guarantee that a TIDBitmap never degrades into lossy mode, `work_mem` must be sized to accommodate the maximum number of matched pages $P_{\text{match}}$ and tuples $T_{\text{match}}$:

$$M_{\text{TIDBitmap}} = \left( P_{\text{match}} \times 128 + \text{HashOverhead}(P_{\text{match}}) \right) \text{ bytes}$$

Where $\text{HashOverhead}(P) \approx P \times 32 \text{ bytes}$. Therefore:
$$M_{\text{TIDBitmap}} \approx P_{\text{match}} \times 160 \text{ bytes}$$

To ensure zero lossy degradation:
$$\text{work\_mem}_{\text{required}} \ge \left\lceil \frac{P_{\text{match}} \times 160}{1024 \times 1024} \right\rceil \text{ MB} \times \text{SafetyFactor}(1.5)$$

For a query touching 100,000 pages:
$$\text{work\_mem}_{\text{required}} \ge \frac{100,000 \times 160}{1024 \times 1024} \times 1.5 \approx 22.9 \text{ MB} \implies \text{Set } \mathbf{32\text{ MB}}$$

### 2.4 Index Scan vs Bitmap Heap Scan Crossover Dynamics

Let $\rho \in [-1.0, 1.0]$ be the physical correlation between the table heap layout and the index key (measured in `pg_stats.correlation`):

```
Physical Correlation ρ
   -1.0                                 0.0                                 +1.0
     ◄───────────────────────────────────┼───────────────────────────────────►
        Random I/O Thrashing                    Clustered / Sequential I/O
       (Bitmap Heap Scan preferred)             (Plain Index Scan preferred)
```

1. **When $|\rho| \ge 0.85$ (High Physical Clustering)**:
   Consecutive index entries point to tuples on the same or adjacent 8KB heap pages. A plain `Index Scan` reads pages sequentially or hits cached buffers with $O(1)$ overhead. Constructing a TIDBitmap and sorting blocks in a `Bitmap Heap Scan` adds redundant memory allocations and CPU overhead with zero I/O benefit. Plain `Index Scan` or `Index Only Scan` is strictly superior.
2. **When $|\rho| \le 0.40$ (Low Physical Clustering)**:
   Consecutive index entries point to randomly scattered heap pages. A plain `Index Scan` causes random I/O head thrashing across NVMe blocks. `Bitmap Heap Scan` aggregates and sorts block numbers before fetching heap pages, ensuring each physical page is fetched at most once in sequential order. However, it **must** remain 100% exact (`lossy=0`).
3. **The Early-Termination LIMIT Inversion**:
   When a query contains `ORDER BY col LIMIT K`:
   $$\text{Cost}_{\text{IndexScan}} = K \times (\text{page\_access\_cost} + \text{cpu\_tuple\_cost})$$
   $$\text{Cost}_{\text{BitmapScan}} = \text{Cost}_{\text{ScanAllMatches}} + N_{\text{matches}} \log(N_{\text{matches}}) \times \text{cpu\_operator\_cost}$$
   Because `Bitmap Heap Scan` destroys B-Tree ordering, it CANNOT terminate after $K$ rows. For $K=10$ and $N_{\text{matches}} = 100,000$, `Index Scan` is over **$5,000\times$ faster**.

---

## 3. Concrete Implementation: TypeScript `AgenticBitmapScanGuardEngine`

The following production-ready TypeScript engine analyzes PostgreSQL execution plans (`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`), verifies exact vs lossy heap block counts, detects index recheck row discards, audits multi-index `BitmapAnd`/`BitmapOr` operations, calculates required `work_mem` headroom, and enforces machine-verifiable Definition of Done gates.

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
  'Exact Heap Blocks'?: number;
  'Lossy Heap Blocks'?: number;
  'Rows Removed by Index Recheck'?: number;
  'Recheck Cond'?: string;
  'Plans'?: PlanNode[];
  [key: string]: unknown;
}

export interface BitmapScanAuditResult {
  hasBitmapScan: boolean;
  hasLossyDegradation: boolean;
  totalExactBlocks: number;
  totalLossyBlocks: number;
  totalRowsRemovedByRecheck: number;
  hasMultiIndexIntersection: boolean;
  intersectedIndexes: string[];
  hasSortLimitTrap: boolean;
  estimatedMemoryNeededMB: number;
  isCompliant: boolean;
  severity: 'OK' | 'WARNING' | 'CRITICAL';
  recommendations: string[];
}

export class AgenticBitmapScanGuardEngine {
  private readonly maxPermittedLossyBlocks: number;
  private readonly maxPermittedRecheckRows: number;

  constructor(options: { maxPermittedLossyBlocks?: number; maxPermittedRecheckRows?: number } = {}) {
    this.maxPermittedLossyBlocks = options.maxPermittedLossyBlocks ?? 0;
    this.maxPermittedRecheckRows = options.maxPermittedRecheckRows ?? 0;
  }

  /**
   * Parses and audits an EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) execution plan.
   */
  public auditExecutionPlan(planJson: string | object): BitmapScanAuditResult {
    const rawData = typeof planJson === 'string' ? JSON.parse(planJson) : planJson;
    const rootPlan: PlanNode = Array.isArray(rawData) ? rawData[0]?.Plan : (rawData as any)?.Plan;

    if (!rootPlan) {
      throw new Error('Invalid EXPLAIN JSON structure: missing root Plan node');
    }

    let hasBitmapScan = false;
    let totalExactBlocks = 0;
    let totalLossyBlocks = 0;
    let totalRowsRemovedByRecheck = 0;
    let hasMultiIndexIntersection = false;
    const intersectedIndexes: string[] = [];
    let hasSortNode = false;
    let hasLimitNode = false;

    const traverse = (node: PlanNode, parentType: string = '') => {
      const nodeType = node['Node Type'] || '';

      if (nodeType === 'Limit') {
        hasLimitNode = true;
      }
      if (nodeType === 'Sort') {
        hasSortNode = true;
      }

      if (nodeType === 'Bitmap Heap Scan') {
        hasBitmapScan = true;
        totalExactBlocks += node['Exact Heap Blocks'] ?? 0;
        totalLossyBlocks += node['Lossy Heap Blocks'] ?? 0;
        totalRowsRemovedByRecheck += node['Rows Removed by Index Recheck'] ?? 0;
      }

      if (nodeType === 'BitmapAnd' || nodeType === 'BitmapOr') {
        hasMultiIndexIntersection = true;
      }

      if (nodeType === 'Bitmap Index Scan') {
        const indexName = (node as any)['Index Name'];
        if (indexName && !intersectedIndexes.includes(indexName)) {
          intersectedIndexes.push(indexName);
        }
      }

      if (Array.isArray(node.Plans)) {
        for (const child of node.Plans) {
          traverse(child, nodeType);
        }
      }
    };

    traverse(rootPlan);

    const hasLossyDegradation = totalLossyBlocks > this.maxPermittedLossyBlocks || totalRowsRemovedByRecheck > this.maxPermittedRecheckRows;
    const hasSortLimitTrap = hasBitmapScan && hasSortNode && hasLimitNode;

    // Calculate required memory: 160 bytes per block + 50% safety margin
    const totalBlocks = totalExactBlocks + totalLossyBlocks;
    const rawBytesNeeded = totalBlocks * 160 * 1.5;
    const estimatedMemoryNeededMB = Math.max(Math.ceil(rawBytesNeeded / (1024 * 1024)), 4);

    const recommendations: string[] = [];
    let severity: 'OK' | 'WARNING' | 'CRITICAL' = 'OK';

    if (hasLossyDegradation) {
      severity = 'CRITICAL';
      recommendations.push(
        `CRITICAL: Lossy TIDBitmap degradation detected (${totalLossyBlocks.toLocaleString()} lossy blocks, ${totalRowsRemovedByRecheck.toLocaleString()} rows removed by recheck). Increase transaction work_mem: SET LOCAL work_mem = '${estimatedMemoryNeededMB * 2}MB';`
      );
    }

    if (hasSortLimitTrap) {
      if (severity !== 'CRITICAL') severity = 'WARNING';
      recommendations.push(
        'WARNING: ORDER BY ... LIMIT query executed via Bitmap Heap Scan followed by explicit Sort. Replace with a composite B-Tree index covering filter and sort columns to enable early-terminating Index Scan.'
      );
    }

    if (hasMultiIndexIntersection && intersectedIndexes.length > 1) {
      if (severity === 'OK') severity = 'WARNING';
      recommendations.push(
        `RECOMMENDATION: Multi-index bitmap operation detected across [${intersectedIndexes.join(', ')}]. Consolidate into a single composite B-Tree index to eliminate intermediate TIDBitmap overhead.`
      );
    }

    const isCompliant = !hasLossyDegradation && !hasSortLimitTrap;

    return {
      hasBitmapScan,
      hasLossyDegradation,
      totalExactBlocks,
      totalLossyBlocks,
      totalRowsRemovedByRecheck,
      hasMultiIndexIntersection,
      intersectedIndexes,
      hasSortLimitTrap,
      estimatedMemoryNeededMB,
      isCompliant,
      severity,
      recommendations,
    };
  }
}
```

---

## 4. Cross-Runtime Implementations

### 4.1 Go (`jackc/pgx/v5`) Production Bitmap Scan Governor

In Go microservices, database queries executing high-volume filtering or analytical batch scans must calibrate `work_mem` within transaction scopes and assert zero lossy pages during integration testing:

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

// BitmapScanGovernor audits execution plans for lossy heap degradation
type BitmapScanGovernor struct {
	Pool *pgxpool.Pool
}

// ExecuteWithCalibratedMemory executes a query with transaction-scoped work_mem to prevent lossy bitmaps
func (g *BitmapScanGovernor) ExecuteWithCalibratedMemory(ctx context.Context, targetMemMB int, fn func(tx pgx.Tx) error) error {
	tx, err := g.Pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Set session-scoped work_mem for this transaction only
	setSQL := fmt.Sprintf("SET LOCAL work_mem = '%dMB'", targetMemMB)
	if _, err := tx.Exec(ctx, setSQL); err != nil {
		return fmt.Errorf("set local work_mem: %w", err)
	}

	if err := fn(tx); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// AuditBitmapPlan verifies that an EXPLAIN plan contains zero lossy heap blocks and zero rechecks
func (g *BitmapScanGovernor) AuditBitmapPlan(ctx context.Context, querySQL string, args ...any) error {
	explainSQL := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s", querySQL)

	ctxTimeout, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	var rawJSON []byte
	if err := g.Pool.QueryRow(ctxTimeout, explainSQL, args...).Scan(&rawJSON); err != nil {
		return fmt.Errorf("explain query failed: %w", err)
	}

	var plans []struct {
		Plan map[string]any `json:"Plan"`
	}
	if err := json.Unmarshal(rawJSON, &plans); err != nil || len(plans) == 0 {
		return fmt.Errorf("parse explain json: %w", err)
	}

	var lossyBlocks float64
	var recheckRows float64

	var inspect func(node map[string]any)
	inspect = func(node map[string]any) {
		if nodeType, _ := node["Node Type"].(string); nodeType == "Bitmap Heap Scan" {
			if lossy, ok := node["Lossy Heap Blocks"].(float64); ok {
				lossyBlocks += lossy
			}
			if rechecks, ok := node["Rows Removed by Index Recheck"].(float64); ok {
				recheckRows += rechecks
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

	if lossyBlocks > 0 || recheckRows > 0 {
		return fmt.Errorf("bitmap scan invariant violation: detected %.0f lossy blocks and %.0f discarded recheck rows", lossyBlocks, recheckRows)
	}

	return nil
}
```

### 4.2 Python (`SQLAlchemy 2.0` / `asyncpg`) Bitmap Scan Sentinel

```python
import json
import logging
from typing import Any, Dict, Optional
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text

logger = logging.getLogger("db.bitmap_guard")

class BitmapScanSentinel:
    @staticmethod
    async def audit_query_plan(session: AsyncSession, query_sql: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Audits query execution plan to guarantee zero lossy pages and zero index recheck penalties.
        """
        explain_query = f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {query_sql}"
        result = await session.execute(text(explain_query), params or {})
        raw_json = result.scalar()

        parsed = json.loads(raw_json) if isinstance(raw_json, str) else raw_json
        root_plan = parsed[0]["Plan"]

        lossy_blocks = 0
        recheck_rows = 0
        exact_blocks = 0

        def traverse(node: Dict[str, Any]):
            nonlocal lossy_blocks, recheck_rows, exact_blocks
            if node.get("Node Type") == "Bitmap Heap Scan":
                exact_blocks += node.get("Exact Heap Blocks", 0)
                lossy_blocks += node.get("Lossy Heap Blocks", 0)
                recheck_rows += node.get("Rows Removed by Index Recheck", 0)

            for child in node.get("Plans", []):
                traverse(child)

        traverse(root_plan)

        is_compliant = (lossy_blocks == 0) and (recheck_rows == 0)
        audit_payload = {
            "exact_blocks": exact_blocks,
            "lossy_blocks": lossy_blocks,
            "recheck_rows": recheck_rows,
            "is_compliant": is_compliant
        }

        if not is_compliant:
            logger.error("Bitmap scan lossy degradation detected: %s", audit_payload)
            raise ValueError(f"Bitmap scan degraded into lossy mode: {lossy_blocks} lossy pages, {recheck_rows} rechecks")

        return audit_payload
```

### 4.3 Rust (`sqlx`) Zero-Lossy Bitmap Plan Assertion

```rust
use serde_json::Value;
use sqlx::PgPool;
use std::time::Duration;

#[derive(Debug, thiserror::Error)]
pub enum BitmapAuditError {
    #[error("Database error: {0}")]
    Sqlx(#[from] sqlx::Error),
    #[error("JSON parsing error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Lossy bitmap degradation detected: {lossy_blocks} lossy blocks, {recheck_rows} discarded rows")]
    LossyDegradation {
        lossy_blocks: i64,
        recheck_rows: i64,
    },
}

pub struct BitmapPlanAuditor;

impl BitmapPlanAuditor {
    pub async fn assert_exact_bitmap(
        pool: &PgPool,
        query_sql: &str,
    ) -> Result<(), BitmapAuditError> {
        let explain_sql = format!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {}", query_sql);

        let row: (Value,) = sqlx::query_as(&explain_sql)
            .fetch_one(pool)
            .await?;

        let plan_json = &row.0;
        let root_node = plan_json
            .as_array()
            .and_then(|arr| arr.get(0))
            .and_then(|item| item.get("Plan"))
            .ok_or_else(|| serde_json::Error::io(std::io::ErrorKind::InvalidData.into()))?;

        let mut lossy_blocks = 0i64;
        let mut recheck_rows = 0i64;

        Self::inspect_node(root_node, &mut lossy_blocks, &mut recheck_rows);

        if lossy_blocks > 0 || recheck_rows > 0 {
            return Err(BitmapAuditError::LossyDegradation {
                lossy_blocks,
                recheck_rows,
            });
        }

        Ok(())
    }

    fn inspect_node(node: &Value, lossy: &mut i64, rechecks: &mut i64) {
        if let Some(node_type) = node.get("Node Type").and_then(|v| v.as_str()) {
            if node_type == "Bitmap Heap Scan" {
                if let Some(l) = node.get("Lossy Heap Blocks").and_then(|v| v.as_i64()) {
                    *lossy += l;
                }
                if let Some(r) = node.get("Rows Removed by Index Recheck").and_then(|v| v.as_i64()) {
                    *rechecks += r;
                }
            }
        }

        if let Some(children) = node.get("Plans").and_then(|v| v.as_array()) {
            for child in children {
                Self::inspect_node(child, lossy, rechecks);
            }
        }
    }
}
```

---

## 5. Six-State Bitmap Scan Optimization Finite-State Machine (FSM)

Autonomous coding agents must traverse the following 6-state FSM before deploying any filtered query relying on bitmap scans:

```
┌────────────────────────────────────────────────────────────────────────┐
│              BITMAP SCAN OPTIMIZATION FINITE-STATE MACHINE             │
└────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
                     [ 1. Query Intake & Ast ]
                                 │
                                 ▼
                     [ 2. Index Path Analysis ]
                      /                      \
                     /                        \
    (Multiple Single Indexes)        (ORDER BY ... LIMIT present)
                   ▼                                    ▼
       [ 3. Composite Index Consolidation ]   [ 4. Index Scan Early Termination ]
                   \                                    /
                    \                                  /
                     ▼                                ▼
               [ 5. work_mem Calibration & Exactness Verification ]
                                 │
                                 ▼
               [ 6. CI Plan Assertion & Production Promotion ]
```

1. **State 1: Query Intake & AST Decomposition**: Parse filter predicates (`WHERE col1 = ? AND col2 >= ?`), sort directives (`ORDER BY`), and row caps (`LIMIT`).
2. **State 2: Index Path Analysis**: Run `EXPLAIN (FORMAT JSON)` without `ANALYZE` to determine whether PostgreSQL chooses a `Seq Scan`, `Index Scan`, `Index Only Scan`, or `Bitmap Heap Scan`.
3. **State 3: Composite Index Consolidation**: If execution displays `BitmapAnd` or `BitmapOr` combining distinct single-column indexes, synthesize a unified composite B-Tree index:
   ```sql
   CREATE INDEX CONCURRENTLY idx_orders_tenant_status_created 
   ON orders (tenant_id, status, created_at DESC);
   ```
4. **State 4: Index Scan Early Termination Verification**: If query contains `ORDER BY ... LIMIT K`, verify that the engine adopts a direct `Index Scan` or `Index Only Scan`. Prohibit `Bitmap Heap Scan` + `Sort` combinations that scan the entire table before slicing top $K$.
5. **State 5: `work_mem` Calibration & Exactness Verification**: If `Bitmap Heap Scan` is legitimately chosen (due to unclustered data $\rho \approx 0$ matching $>5,000$ rows), calibrate transaction-level `SET LOCAL work_mem` to guarantee `Lossy Heap Blocks == 0`.
6. **State 6: CI Plan Assertion & Production Promotion**: Verify via test harness that the final execution plan exhibits sub-millisecond execution times, `Lossy Blocks == 0`, and `Rows Removed by Index Recheck == 0`.

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Check Name | Verification Mechanism | Threshold / Invariant | Blocking Action |
|:---|:---|:---|:---|:---|
| **DOD-01** | Zero Lossy Heap Blocks | `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` | `Lossy Heap Blocks == 0` | Reject PR; increase `work_mem` or add covering index |
| **DOD-02** | Zero Recheck Discards | `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` | `Rows Removed by Index Recheck == 0` | Reject PR; prevent lossy bitmap degradation |
| **DOD-03** | Composite Index Consolidation | AST & Plan Inspection | Zero `BitmapAnd` / `BitmapOr` across high-frequency queries | Require composite B-Tree index migration |
| **DOD-04** | LIMIT Early-Termination | Query Plan Inspection on `ORDER BY ... LIMIT` | Plan uses `Index Scan` / `Index Only Scan` (no intermediate `Sort`) | Mandate index aligned with sort direction |
| **DOD-05** | Memory Ceilings | Dynamic `work_mem` Validation | `SET LOCAL work_mem <= 25% Available RAM` | Prevent Postmaster Linux OOM killer termination |
| **DOD-06** | CI Automated Assertion | Integration Test Suite Execution | Automated AST gate passes on all target queries | Fail build in CI pipeline |

---

## Conclusion & Operational Discipline

Bitmap Scans are a powerful mechanism to avoid random NVMe I/O on unclustered datasets, but naive implementations suffer from catastrophic CPU spikes when in-memory bitmaps degrade into lossy page markers. Autonomous agents must systematically enforce **exact tuple-level bitmaps (`lossy=0`)**, size `work_mem` dynamically, consolidate fragmented indexes into cohesive composite B-Trees, and protect `LIMIT` streaming pipelines from ordering destruction. Adhere strictly to the 5-Tier Bitmap Scan Governance Ladder to guarantee deterministic sub-millisecond database performance.
