---
description: PostgreSQL hash join execution, in-memory single-batch vs multi-batch Grace Hash Join spills, work_mem and hash_mem_multiplier dynamic calibration, hash bucket skew and collision defense, inner vs outer build table inversion eradication, Parallel Shared Hash Join barrier synchronization, and Merge/Index join selection across Go (pgx/v5), TypeScript (Kysely, Drizzle, Prisma), Python (SQLAlchemy, asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{join,hash,plan,explain,query,memory,spill,database,db,migration,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Hash Joins, Multi-Batch Spills, Skewed Bucket Elimination, Grace Hash Join Memory Traps & Hybrid Hash Optimization Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design complex multi-table joins, reporting pipelines, data warehouse ETL workflows, or high-throughput transactional queries across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Multi-Batch Hash Spill Latency Cliff (`Batches > 1` & Temp Disk Avalanche)" (where the inner build table exceeds `work_mem * hash_mem_multiplier`, forcing PostgreSQL to decompose the hash table into $2^k$ disk batches and write gigabytes of intermediate tuples to disk, exploding query latency from 12ms to 35 seconds and saturating NVMe write bandwidth), the "Skewed Hash Bucket Hotspot & Hash Collision Meltdown" (where extreme Zipfian value distribution on join keys hashes millions of tuples into a single bucket, degrading $O(1)$ hash probing into an $O(N)$ linear pointer-chasing linked-list scan that pins CPU cores at 100%), the "Uncalibrated `hash_mem_multiplier` & Postmaster OOM Decapitation" (where parallel workers executing multi-join queries allocate up to $W \times K \times \text{hash\_mem\_multiplier} \times \text{work\_mem}$, requesting gigabytes of volatile heap memory and triggering Linux kernel OOM killer termination of the postmaster), the "Outer vs Inner Table Build Inversion Trap" (where stale `pg_stats` or unanalyzed predicates fool the query optimizer into building the hash table on the 10-million row outer table instead of the 5,000-row inner dimension, burning gigabytes of memory), the "Parallel Shared Hash Join Worker Starvation & DSM Memory Exhaustion" (where workers building a shared hash table in Dynamic Shared Memory desynchronize during multi-phase barrier transitions `PHJ_BUILD_HASHING` $\to$ `PHJ_BUILD_DONE`, causing worker lock starvation or DSM segment exhaustion), and the "Hash Join vs Merge Join vs Index Probe Optimizer Plan Drift" (where unindexed join columns force expensive hash operations when a Merge Join or Nested Loop with Index Probe would execute in $O(1)$ memory) by establishing a strict 5-Tier Hash Join Governance Ladder, formal hash join memory calculus, an autonomous TypeScript `AgenticHashJoinGuardEngine`, cross-runtime implementations in Go, Python, and Rust, a 6-state optimization finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Hash Join Catastrophes vs The 5-Tier Governance Ladder

A **Hash Join** is an asymmetric physical join algorithm comprising two distinct phases:
1. **Build Phase (Inner Relation)**: The database reads all rows from the inner relation, evaluates projection predicates, computes a 32-bit hash value for each row's join key, and inserts tuple pointers into an in-memory hash table composed of $N_{\text{buckets}}$ hash buckets.
2. **Probe Phase (Outer Relation)**: The database streams rows from the outer relation, hashes each outer join key, accesses the corresponding hash bucket, and traverses the bucket's collision chain to emit matching joined tuples.

When the inner build relation fits completely within available execution memory ($M_{\text{avail}} = \text{work\_mem} \times \text{hash\_mem\_multiplier}$), the hash join operates in **Single-Batch In-Memory Mode** ($\text{Batches} = 1$). In this mode, probing executes in optimal $O(N_{\text{outer}})$ time with zero disk I/O. However, when autonomous agents construct queries without understanding hash table memory boundaries, six catastrophic failure modes manifest:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   NAIVE HASH JOIN vs PRODUCTION HASH INVARIANTS                        │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Ignore Batches count in EXPLAIN         │ • Single-Batch In-Memory Invariant:        │
│   (Allows Batches = 4, 16, 64; spills     │   Assert Batches = 1 and TempWritten = 0   │
│    gigabytes of tuples to disk)           │   via transaction-scoped work_mem tuning   │
│ • Join on high-skew low-entropy keys      │ • Skew Elimination & Composite Hashing:    │
│   (e.g., status = 'ACTIVE' or tenant_id;  │   Enforce composite join keys or filter    │
│    millions hash into a single bucket)    │   hotspot keys before hash table build     │
│ • Global unbounded work_mem & multiplier  │ • Calibrated Multiplier & OOM Boundary:    │
│   (Postmaster killed by Linux OOM killer   │   Bounding total session memory:           │
│    under concurrent parallel queries)     │   W * K * work_mem * hash_mem_mult <= Cap  │
│ • Stale statistics inverting join roles   │ • Strict Inner Build Sizing & Fresh Stats: │
│   (Hash built on 10M table instead of     │   Verify inner table cardinality < outer;  │
│    10K dimension table; massive bloat)    │   maintain fresh MCV and histogram stats   │
│ • Uncontrolled Parallel Hash Join DSM     │ • Parallel Shared Hash Barrier Governance: │
│   (Workers starve at barrier transitions; │   Tune max_parallel_workers_per_gather and │
│    DSM segment allocation fails)          │   min_parallel_table_scan_size             │
│ • Force Hash Join on pre-sorted data      │ • Sargable Merge/Index Join Selection:     │
│   (Misses $O(1)$ memory Merge Join or     │   Add B-Tree indexes on join keys to allow │
│    Index-Only Scans on ordered datasets)  │   Merge Join or Index Probes without hash  │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 5-Tier Hash Join Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        THE 5-TIER HASH JOIN GOVERNANCE LADDER                          │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Engine Compatibility & Statistical Cardinality Invariance                      │
│   • PostgreSQL 13+ with hash_mem_multiplier support verified                           │
│   • Fresh table statistics (ANALYZE) ensuring accurate inner/outer role assignment     │
│   • Absolute ban on Cartesian joins and cross-type non-sargable join operators         │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Single-Batch Zero-Disk-Spill Memory Fencing                                    │
│   • Enforce Batches = 1 and TempWrittenBlocks = 0 on all critical OLTP & batch paths   │
│   • Compute session-scoped SET LOCAL work_mem and SET LOCAL hash_mem_multiplier        │
│   • Guard against postmaster OOM: Total Memory <= 25% of available system RAM          │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Hash Bucket Skew Elimination & Entropy Distribution                            │
│   • Verify hash chain length: max_bucket_depth <= 10 tuples                            │
│   • Eliminate single-attribute low-cardinality join keys via composite key hashing     │
│   • Deploy partial filtering or CTE pre-aggregation for extreme Zipfian hotspots      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Parallel Shared Hash Join & DSM Calibration                                    │
│   • Parallel Hash with shared memory hash table in Dynamic Shared Memory (DSM)         │
│   • Dynamic worker sizing matching physical CPU cores without worker starvation        │
│   • Zero desynchronization at PHJ_BUILD_HASHING and PHJ_PROBING barriers               │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Autonomous CI EXPLAIN Gate & Continuous Regression Sentinels                   │
│   • Automated CI gate checking EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)                 │
│   • Reject PRs introducing Batches > 1 or WorkMem Temp Spills on production paths      │
│   • Observability sentinels linking pg_stat_statements temp_blks_written to join nodes │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical & Algorithmic Foundations

### Hash Table Memory Sizing Calculus

Let $N_{\text{inner}}$ denote the number of tuples in the inner build relation, $W_{\text{tuple}}$ the average projected tuple width in bytes, and $H_{\text{header}}$ the tuple header overhead ($23\text{ bytes}$ for `HeapTupleHeader` aligned to an 8-byte boundary, totaling $24\text{ bytes}$ or $32\text{ bytes}$ with memory chunk headers).

The physical memory required for an in-memory hash table $S_{\text{hash}}$ is given by:

$$S_{\text{hash}} = N_{\text{inner}} \times \left( \text{MAXALIGN}(W_{\text{tuple}} + H_{\text{header}}) + S_{\text{pointer}} \right) + N_{\text{buckets}} \times S_{\text{pointer}}$$

where $S_{\text{pointer}} = 8\text{ bytes}$ on 64-bit architectures, and $N_{\text{buckets}}$ is dynamically scaled by PostgreSQL to the next power of 2 such that:

$$N_{\text{buckets}} = 2^{\lceil \log_2(N_{\text{inner}} / \text{NTUP\_PER\_BUCKET}) \rceil}$$

with $\text{NTUP\_PER\_BUCKET} = 1$ (PostgreSQL attempts to maintain an average of 1 tuple per bucket).

### Multi-Batch Grace Hash Join Spillage Condition

Available execution memory $M_{\text{avail}}$ for a hash node is governed by:

$$M_{\text{avail}} = \text{work\_mem} \times \text{hash\_mem\_multiplier}$$

When $S_{\text{hash}} > M_{\text{avail}}$, the query engine cannot maintain the hash table in memory and must transition to a **Hybrid Grace Hash Join**. The engine divides the hash domain into $B = 2^k$ batches:

$$B = 2^{\left\lceil \log_2 \left( \frac{S_{\text{hash}}}{M_{\text{avail}}} \right) \right\rceil}$$

In a $B$-batch execution, batch 0 remains in memory while batches $1 \dots (B-1)$ of both inner and outer relations are written to disk files. The total disk I/O volume $V_{\text{disk}}$ generated is:

$$V_{\text{disk}} = 2 \times \sum_{i=1}^{B-1} \left( S_{\text{inner}, i} + S_{\text{outer}, i} \right) = 2 \times (S_{\text{inner}} + S_{\text{outer}}) \times \left( 1 - \frac{1}{B} \right)$$

For a query joining a 2GB inner table with a 10GB outer table that spills into $B = 16$ batches:

$$V_{\text{disk}} = 2 \times (2 + 10) \times \left( 1 - \frac{1}{16} \right) = 2 \times 12 \times \frac{15}{16} = 22.5\text{ GB of NVMe writes and reads}$$

This $22.5\text{ GB}$ disk traffic directly causes the 1,000% latency spike observed during multi-batch spills.

### Hash Bucket Skew Degradation Theorem

Let the join key $K$ follow a Zipfian distribution where the most frequent key occurs with probability $p_{\max}$. If $p_{\max} \gg \frac{1}{N_{\text{buckets}}}$, the maximum bucket depth $D_{\max}$ scales linearly with relation size rather than remaining constant:

$$D_{\max} \approx p_{\max} \times N_{\text{inner}}$$

Under uniform hashing, probing time is $T_{\text{probe}} = O(1)$. Under severe skew ($p_{\max} = 0.40$ on $10^6$ rows), probing a single key requires traversing $400,000$ pointer links in CPU L1/L2 cache lines, causing $400,000 \times 8\text{ns} \approx 3.2\text{ms}$ of memory bus stalls per probe row, degrading overall probe time from $O(N_{\text{outer}})$ to $O(N_{\text{outer}} \times D_{\max})$.

---

## 3. Concrete Implementation: TypeScript `AgenticHashJoinGuardEngine`

```typescript
/**
 * AgenticHashJoinGuardEngine
 * Machine-verifiable governance engine for PostgreSQL Hash Joins.
 * Analyzes execution plans, detects multi-batch disk spills, quantifies
 * memory requirements, identifies bucket skew, and generates transaction-scoped
 * remediation commands.
 */

export interface HashPlanNode {
  nodeType: string;
  relationName?: string;
  alias?: string;
  actualRows?: number;
  planRows?: number;
  actualStartupTime?: number;
  actualTotalTime?: number;
  hashBatches?: number;
  originalHashBatches?: number;
  hashBuckets?: number;
  originalHashBuckets?: number;
  peakMemoryUsageKB?: number;
  plans?: HashPlanNode[];
  tempWrittenBlocks?: number;
  tempReadBlocks?: number;
}

export interface HashJoinAssessment {
  isSingleBatch: boolean;
  batches: number;
  originalBatches: number;
  peakMemoryUsageKB: number;
  tempWrittenBlocks: number;
  tempReadBlocks: number;
  innerTableCardinality: number;
  outerTableCardinality: number;
  isRoleInverted: boolean;
  skewDetected: boolean;
  recommendedWorkMemKB: number;
  recommendedHashMemMultiplier: number;
  violationSeverity: 'NONE' | 'LOW' | 'HIGH' | 'CRITICAL';
  remediationSQL: string;
}

export class AgenticHashJoinGuardEngine {
  private readonly defaultWorkMemKB: number;
  private readonly defaultHashMemMultiplier: number;
  private readonly maxAllowedSessionMemoryKB: number;

  constructor(
    defaultWorkMemKB: number = 4096, // 4MB
    defaultHashMemMultiplier: number = 2.0,
    maxAllowedSessionMemoryKB: number = 1048576 // 1GB safety ceiling
  ) {
    this.defaultWorkMemKB = defaultWorkMemKB;
    this.defaultHashMemMultiplier = defaultHashMemMultiplier;
    this.maxAllowedSessionMemoryKB = maxAllowedSessionMemoryKB;
  }

  /**
   * Evaluates an EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) execution tree
   */
  public assessPlan(rootNode: HashPlanNode): HashJoinAssessment {
    const hashNodes = this.extractHashNodes(rootNode);

    if (hashNodes.length === 0) {
      return {
        isSingleBatch: true,
        batches: 1,
        originalBatches: 1,
        peakMemoryUsageKB: 0,
        tempWrittenBlocks: 0,
        tempReadBlocks: 0,
        innerTableCardinality: 0,
        outerTableCardinality: 0,
        isRoleInverted: false,
        skewDetected: false,
        recommendedWorkMemKB: this.defaultWorkMemKB,
        recommendedHashMemMultiplier: this.defaultHashMemMultiplier,
        violationSeverity: 'NONE',
        remediationSQL: '-- No Hash Join nodes detected in execution plan',
      };
    }

    let maxBatches = 1;
    let maxOriginalBatches = 1;
    let totalPeakMemKB = 0;
    let totalTempWritten = 0;
    let totalTempRead = 0;
    let worstRoleInverted = false;
    let worstSkew = false;
    let maxInnerRows = 0;
    let maxOuterRows = 0;

    for (const node of hashNodes) {
      const batches = node.hashBatches ?? 1;
      const origBatches = node.originalHashBatches ?? 1;
      const memKB = node.peakMemoryUsageKB ?? 0;
      const tempWritten = node.tempWrittenBlocks ?? 0;
      const tempRead = node.tempReadBlocks ?? 0;

      if (batches > maxBatches) maxBatches = batches;
      if (origBatches > maxOriginalBatches) maxOriginalBatches = origBatches;
      totalPeakMemKB += memKB;
      totalTempWritten += tempWritten;
      totalTempRead += tempRead;

      // Check inner vs outer cardinality inversion
      const parentJoin = this.findParentJoinNode(rootNode, node);
      if (parentJoin && parentJoin.plans && parentJoin.plans.length >= 2) {
        const outerNode = parentJoin.plans[0];
        const innerNode = node.plans?.[0] ?? parentJoin.plans[1];

        const innerRows = innerNode.actualRows ?? innerNode.planRows ?? 0;
        const outerRows = outerNode.actualRows ?? outerNode.planRows ?? 0;

        maxInnerRows = Math.max(maxInnerRows, innerRows);
        maxOuterRows = Math.max(maxOuterRows, outerRows);

        // Role inversion: inner build table significantly larger than outer probe table
        if (innerRows > outerRows * 2.5 && innerRows > 50000) {
          worstRoleInverted = true;
        }

        // Skew detection: actual rows deviate >10x from estimated plan rows
        if (node.planRows && node.actualRows) {
          const ratio = node.actualRows / node.planRows;
          if (ratio > 10.0 || ratio < 0.1) {
            worstSkew = true;
          }
        }
      }
    }

    const isSingleBatch = maxBatches === 1 && totalTempWritten === 0;

    // Memory sizing calculation
    let recommendedWorkMem = this.defaultWorkMemKB;
    let recommendedMultiplier = this.defaultHashMemMultiplier;

    if (!isSingleBatch) {
      // Calculate memory required to hold entire inner table in single batch
      const requiredMemKB = Math.ceil(totalPeakMemKB * maxBatches * 1.25); // 25% safety buffer
      const safeMemKB = Math.min(requiredMemKB, this.maxAllowedSessionMemoryKB);

      // Distribute between work_mem and hash_mem_multiplier
      recommendedMultiplier = 2.0;
      recommendedWorkMem = Math.ceil(safeMemKB / recommendedMultiplier);
    }

    // Severity assessment
    let severity: 'NONE' | 'LOW' | 'HIGH' | 'CRITICAL' = 'NONE';
    if (!isSingleBatch || worstRoleInverted) {
      if (maxBatches >= 16 || totalTempWritten > 50000 || worstRoleInverted) {
        severity = 'CRITICAL';
      } else if (maxBatches >= 4 || totalTempWritten > 5000) {
        severity = 'HIGH';
      } else {
        severity = 'LOW';
      }
    }

    // Generate transaction-scoped remediation SQL
    const remediationSQL = this.generateRemediation(
      isSingleBatch,
      recommendedWorkMem,
      recommendedMultiplier,
      worstRoleInverted,
      worstSkew
    );

    return {
      isSingleBatch,
      batches: maxBatches,
      originalBatches: maxOriginalBatches,
      peakMemoryUsageKB: totalPeakMemKB,
      tempWrittenBlocks: totalTempWritten,
      tempReadBlocks: totalTempRead,
      innerTableCardinality: maxInnerRows,
      outerTableCardinality: maxOuterRows,
      isRoleInverted: worstRoleInverted,
      skewDetected: worstSkew,
      recommendedWorkMemKB: recommendedWorkMem,
      recommendedHashMemMultiplier: recommendedMultiplier,
      violationSeverity: severity,
      remediationSQL,
    };
  }

  private extractHashNodes(node: HashPlanNode): HashPlanNode[] {
    const results: HashPlanNode[] = [];
    if (node.nodeType === 'Hash') {
      results.push(node);
    }
    if (node.plans) {
      for (const child of node.plans) {
        results.push(...this.extractHashNodes(child));
      }
    }
    return results;
  }

  private findParentJoinNode(current: HashPlanNode, targetHash: HashPlanNode): HashPlanNode | null {
    if (!current.plans) return null;
    for (const child of current.plans) {
      if (child === targetHash) return current;
      const found = this.findParentJoinNode(child, targetHash);
      if (found) return found;
    }
    return null;
  }

  private generateRemediation(
    isSingleBatch: boolean,
    workMemKB: number,
    multiplier: number,
    roleInverted: boolean,
    skewDetected: boolean
  ): string {
    const lines: string[] = ['-- Automated Hash Join Governance Remediation'];

    if (roleInverted) {
      lines.push('-- [CRITICAL] Inner/Outer table role inversion detected!');
      lines.push('-- Run ANALYZE on joined relations to correct cardinality estimates:');
      lines.push('ANALYZE table_name;');
      lines.push('-- Verify join conditions are sargable and column data types match exactly.');
    }

    if (skewDetected) {
      lines.push('-- [WARNING] Cardinality estimation skew detected (>10x divergence).');
      lines.push('-- Create extended statistics on correlated join columns:');
      lines.push('CREATE STATISTICS IF NOT EXISTS stat_join_skew ON col_a, col_b FROM table_name;');
      lines.push('ANALYZE table_name;');
    }

    if (!isSingleBatch) {
      const workMemMB = Math.max(1, Math.ceil(workMemKB / 1024));
      lines.push('-- [REQUIRED] Enforce single-batch in-memory execution to eliminate disk spilling:');
      lines.push('BEGIN;');
      lines.push(`SET LOCAL work_mem = '${workMemMB}MB';`);
      lines.push(`SET LOCAL hash_mem_multiplier = ${multiplier.toFixed(1)};`);
      lines.push('-- Execute your query here...');
      lines.push('COMMIT;');
    } else {
      lines.push('-- Plan operates in single-batch mode (Batches = 1). Zero disk spillage confirmed.');
    }

    return lines.join('\n');
  }
}
```

---

## 4. Cross-Runtime Implementations

### Go (`jackc/pgx/v5`) Production Implementation

```go
package store

import (
	"context"
	"encoding/json"
	"fmt"
	"math"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// HashJoinPlanMetrics captures physical hash join execution statistics
type HashJoinPlanMetrics struct {
	Batches           int   `json:"Hash Batches"`
	OriginalBatches   int   `json:"Original Hash Batches"`
	PeakMemoryUsageKB int64 `json:"Peak Memory Usage"`
	Buckets           int   `json:"Hash Buckets"`
}

// PlanNode represents a generic PostgreSQL JSON explain node
type PlanNode struct {
	NodeType           string                 `json:"Node Type"`
	ActualRows         float64                `json:"Actual Rows"`
	PlanRows           float64                `json:"Plan Rows"`
	HashBatches        int                    `json:"Hash Batches"`
	OriginalHashBatches int                   `json:"Original Hash Batches"`
	PeakMemoryUsageKB  int64                  `json:"Peak Memory Usage"`
	TempWrittenBlocks  int64                  `json:"Temp Written Blocks"`
	Plans              []PlanNode             `json:"Plans"`
	Extra              map[string]interface{} `json:"-"`
}

// HashJoinSessionGovernor executes queries with guaranteed single-batch hash join invariants
type HashJoinSessionGovernor struct {
	pool *pgxpool.Pool
}

func NewHashJoinSessionGovernor(pool *pgxpool.Pool) *HashJoinSessionGovernor {
	return &HashJoinSessionGovernor{pool: pool}
}

// ExecuteSingleBatchJoin runs a query inside a transaction with calibrated work_mem
func (g *HashJoinSessionGovernor) ExecuteSingleBatchJoin(
	ctx context.Context,
	estimatedInnerRows int64,
	avgRowWidthBytes int,
	queryFn func(tx pgx.Tx) error,
) error {
	// Calculate required work_mem for single-batch execution
	// Tuple overhead: 32 bytes aligned + 8 bytes pointer = 40 bytes per row
	rowMemBytes := int64(avgRowWidthBytes + 40)
	estimatedHashMemBytes := int64(float64(estimatedInnerRows*rowMemBytes) * 1.30) // 30% headroom

	// hash_mem_multiplier defaults to 2.0 in PG 13+
	multiplier := 2.0
	requiredWorkMemBytes := int64(float64(estimatedHashMemBytes) / multiplier)
	requiredWorkMemMB := int(math.Ceil(float64(requiredWorkMemBytes) / (1024 * 1024)))

	if requiredWorkMemMB < 4 {
		requiredWorkMemMB = 4 // Minimum 4MB floor
	}
	if requiredWorkMemMB > 512 {
		requiredWorkMemMB = 512 // 512MB session cap to prevent OOM
	}

	tx, err := g.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Enforce session-level memory bounds
	setWorkMemSQL := fmt.Sprintf("SET LOCAL work_mem = '%dMB'", requiredWorkMemMB)
	if _, err := tx.Exec(ctx, setWorkMemSQL); err != nil {
		return fmt.Errorf("set local work_mem: %w", err)
	}

	if _, err := tx.Exec(ctx, "SET LOCAL hash_mem_multiplier = 2.0"); err != nil {
		return fmt.Errorf("set local hash_mem_multiplier: %w", err)
	}

	// Execute client query function
	if err := queryFn(tx); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// AssertSingleBatchVerification checks execution plan for zero disk spillage
func (g *HashJoinSessionGovernor) AssertSingleBatchVerification(ctx context.Context, query string, args ...any) error {
	explainQuery := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s", query)

	var planJSON []byte
	err := g.pool.QueryRow(ctx, explainQuery, args...).Scan(&planJSON)
	if err != nil {
		return fmt.Errorf("explain query failed: %w", err)
	}

	var rootContainers []struct {
		Plan PlanNode `json:"Plan"`
	}
	if err := json.Unmarshal(planJSON, &rootContainers); err != nil {
		return fmt.Errorf("parse explain json: %w", err)
	}

	if len(rootContainers) == 0 {
		return fmt.Errorf("empty explain plan returned")
	}

	batches, tempBlocks := findMaxBatches(rootContainers[0].Plan)
	if batches > 1 {
		return fmt.Errorf("INVARIANT VIOLATION: Hash Join spilled to disk (%d batches, %d temp blocks written)", batches, tempBlocks)
	}

	return nil
}

func findMaxBatches(node PlanNode) (int, int64) {
	maxBatches := 1
	var totalTempWritten int64 = node.TempWrittenBlocks

	if node.NodeType == "Hash" {
		if node.HashBatches > maxBatches {
			maxBatches = node.HashBatches
		}
	}

	for _, child := range node.Plans {
		childBatches, childTemp := findMaxBatches(child)
		if childBatches > maxBatches {
			maxBatches = childBatches
		}
		totalTempWritten += childTemp
	}

	return maxBatches, totalTempWritten
}
```

### Python (`asyncpg` / `SQLAlchemy 2.0`) Implementation

```python
"""
PostgreSQL Hash Join Single-Batch Invariant Guard for Python (asyncpg / SQLAlchemy 2.0)
"""

import json
import math
from typing import Any, Dict, Optional, Tuple
import asyncpg


class HashJoinSpillError(Exception):
    """Raised when a query executes with Batches > 1 or temp disk spills."""
    pass


class AsyncHashJoinGuard:
    def __init__(self, pool: asyncpg.Pool, max_work_mem_mb: int = 512):
        self.pool = pool
        self.max_work_mem_mb = max_work_mem_mb

    async def execute_in_memory_join(
        self,
        query: str,
        *args: Any,
        estimated_inner_rows: int = 100_000,
        avg_row_width: int = 128
    ) -> list[asyncpg.Record]:
        """
        Executes a query with transaction-scoped work_mem sizing to guarantee
        single-batch in-memory hash join execution.
        """
        # Calculate memory needed: (width + 40 bytes overhead) * rows * 1.3 buffer
        estimated_bytes = int((avg_row_width + 40) * estimated_inner_rows * 1.30)
        # Assuming hash_mem_multiplier = 2.0
        needed_work_mem_mb = max(4, min(self.max_work_mem_mb, math.ceil(estimated_bytes / (2.0 * 1024 * 1024))))

        async with self.pool.acquire() as conn:
            async with conn.transaction():
                await conn.execute(f"SET LOCAL work_mem = '{needed_work_mem_mb}MB'")
                await conn.execute("SET LOCAL hash_mem_multiplier = 2.0")
                return await conn.fetch(query, *args)

    async def verify_single_batch(self, query: str, *args: Any) -> Tuple[bool, int, int]:
        """
        Runs EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) and asserts Batches == 1.
        Returns: (is_single_batch, max_batches, temp_written_blocks)
        """
        explain_sql = f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {query}"
        async with self.pool.acquire() as conn:
            result = await conn.fetchval(explain_sql, *args)
            plan_data = json.loads(result)
            root_plan = plan_data[0]["Plan"]

            max_batches, temp_blocks = self._traverse_plan(root_plan)
            is_single_batch = (max_batches == 1) and (temp_blocks == 0)

            if not is_single_batch:
                raise HashJoinSpillError(
                    f"Hash join violated single-batch invariant: "
                    f"Batches={max_batches}, TempWrittenBlocks={temp_blocks}"
                )

            return True, max_batches, temp_blocks

    def _traverse_plan(self, node: Dict[str, Any]) -> Tuple[int, int]:
        max_batches = 1
        temp_blocks = node.get("Temp Written Blocks", 0)

        if node.get("Node Type") == "Hash":
            batches = node.get("Hash Batches", 1)
            if batches > max_batches:
                max_batches = batches

        for child in node.get("Plans", []):
            child_batches, child_temp = self._traverse_plan(child)
            max_batches = max(max_batches, child_batches)
            temp_blocks += child_temp

        return max_batches, temp_blocks
```

### Rust (`sqlx`) Implementation

```rust
use sqlx::{PgPool, Transaction, Postgres};
use serde_json::Value;

#[derive(Debug)]
pub struct HashJoinVerification {
    pub is_single_batch: bool,
    pub max_batches: i64,
    pub temp_written_blocks: i64,
}

pub struct HashJoinGovernor;

impl HashJoinGovernor {
    /// Executes a transaction with scoped memory tuning to eliminate hash spills
    pub async fn execute_scoped_join<'a, F, R>(
        pool: &'a PgPool,
        work_mem_mb: u32,
        logic: F,
    ) -> Result<R, sqlx::Error>
    where
        F: FnOnce(&mut Transaction<'a, Postgres>) -> std::pin::Pin<Box<dyn std::future::Output<Output = Result<R, sqlx::Error>> + Send + '_>>,
    {
        let mut tx = pool.begin().await?;

        // Guard memory bounds
        let set_mem = format!("SET LOCAL work_mem = '{}MB'", work_mem_mb.clamp(4, 512));
        sqlx::query(&set_mem).execute(&mut *tx).await?;
        sqlx::query("SET LOCAL hash_mem_multiplier = 2.0").execute(&mut *tx).await?;

        let result = logic(&mut tx).await?;
        tx.commit().await?;

        Ok(result)
    }

    /// Verifies that the plan executed with Batches = 1
    pub async fn verify_plan_single_batch(
        pool: &PgPool,
        query: &str,
    ) -> Result<HashJoinVerification, Box<dyn std::error::Error + Send + Sync>> {
        let explain_query = format!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {}", query);
        let row: (Value,) = sqlx::query_as(&explain_query).fetch_one(pool).await?;

        let plan_root = &row.0[0]["Plan"];
        let (max_batches, temp_written) = Self::inspect_node(plan_root);

        Ok(HashJoinVerification {
            is_single_batch: max_batches == 1 && temp_written == 0,
            max_batches,
            temp_written_blocks: temp_written,
        })
    }

    fn inspect_node(node: &Value) -> (i64, i64) {
        let mut max_b = 1;
        let mut temp_w = node.get("Temp Written Blocks").and_then(|v| v.as_i64()).unwrap_or(0);

        if node.get("Node Type").and_then(|v| v.as_str()) == Some("Hash") {
            if let Some(b) = node.get("Hash Batches").and_then(|v| v.as_i64()) {
                if b > max_b {
                    max_b = b;
                }
            }
        }

        if let Some(children) = node.get("Plans").and_then(|v| v.as_array()) {
            for child in children {
                let (cb, ct) = Self::inspect_node(child);
                if cb > max_b {
                    max_b = cb;
                }
                temp_w += ct;
            }
        }

        (max_b, temp_w)
    }
}
```

---

## 5. Six-State Hash Join Optimization Finite-State Machine (FSM)

```
        ┌────────────────────────────────────────────────────────┐
        │            STATE 0: STATISTICAL_AUDIT                  │
        │  • Check pg_stats for inner & outer relations          │
        │  • Verify n_distinct, null_frac & MCV frequencies       │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │            STATE 1: ROLE_INVERSION_GUARD               │
        │  • Assert estimated inner build rows <= outer probe     │
        │  • Reject inverted join plans via ANALYZE / stats      │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │            STATE 2: SKEW_ENTROPY_ANALYSIS              │
        │  • Evaluate join key entropy: H(K) >= 0.70 * H_max     │
        │  • Isolate high-frequency skewed keys via CTE / filter │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │            STATE 3: MEMORY_CALIBRATION                 │
        │  • Calculate required S_hash for single-batch build    │
        │  • Set SET LOCAL work_mem & hash_mem_multiplier        │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │            STATE 4: PARALLEL_DSM_FENCING               │
        │  • Calibrate max_parallel_workers_per_gather           │
        │  • Verify Dynamic Shared Memory (DSM) allocation       │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │            STATE 5: VERIFICATION_GATE                  │
        │  • Run EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)         │
        │  • Assert Batches == 1 and TempWrittenBlocks == 0      │
        └────────────────────────────────────────────────────────┘
```

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate # | DoD Gate Verification Criterion | Validation Mechanism | Production Threshold |
| :--- | :--- | :--- | :--- |
| **Gate 0** | **Single-Batch Invariance** | `EXPLAIN (ANALYZE, FORMAT JSON)` | $\text{Hash Batches} = 1$ unconditionally |
| **Gate 1** | **Zero Disk Spill Invariance** | `EXPLAIN (BUFFERS)` | $\text{Temp Written Blocks} = 0$, $\text{Temp Read Blocks} = 0$ |
| **Gate 2** | **Role Inversion Immunity** | Planner Cardinality Audit | $\text{ActualRows}(\text{inner}) \le \text{ActualRows}(\text{outer}) \times 1.5$ |
| **Gate 3** | **Hash Bucket Skew Bounding** | `pg_stats` MCV Frequency | Max join key frequency $p_{\max} \le 0.15$ or isolated |
| **Gate 4** | **Session Memory Safety Bound** | GUC Allocation Ceiling | $\sum (\text{work\_mem} \times \text{multiplier} \times W) \le \text{RAM}_{\text{avail}} \times 0.25$ |
| **Gate 5** | **Automated CI Regression Gate** | Static AST + EXPLAIN Runner | Zero multi-batch hash joins permitted into production branch |
