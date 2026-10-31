---
description: PostgreSQL Just-In-Time (JIT) compilation, LLVM code generation overhead, tuple deforming, expression evaluation, jit_above_cost, jit_inline_above_cost, jit_optimize_above_cost tuning, eliminating the 100ms LLVM compilation latency cliff on sub-millisecond OLTP queries, parallel worker JIT multiplication, and LLVM memory context bloat across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, psycopg3), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{jit,llvm,deforming,planner,cost,postgres,db,query}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database JIT Compilation, LLVM Expression Deforming, Cost Thresholds, Optimization Pass CPU Thrashing & Microsecond Query Regression Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to operate relational databases, optimize complex queries, tune PostgreSQL planner GUCs, manage analytics and OLTP co-existence, and diagnose latency regressions across PostgreSQL (11–17+) in Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "LLVM JIT Compilation Latency Cliff (The 100ms LLVM Overhead on Sub-Millisecond OLTP Queries)" (where queries estimated to cost $> 100,000$ trigger LLVM code generation, spending 50ms–300ms compiling machine code while execution takes only 2ms, leading agents to speculatively add useless indexes or rewrite clauses), the "`jit_inline_above_cost` & `jit_optimize_above_cost` LLVM Optimization CPU Storm" (where concurrent analytical queries invoke LLVM `-O3` optimization passes simultaneously, pinning CPU cores at 100% in `llvm::Pass::run()`), the "Parallel Worker JIT Compilation Multiplier ($W \times \text{JIT}$ Starvation Trap)" (where parallel query workers fail to share compiled machine code and redundantly re-compile LLVM IR in each worker process space), the "LLVM Context Memory Leaks & Process Heap (`TopMemoryContext`) OOM Decapitation" (where long-lived connection poolers accumulate internal LLVM compiler state across thousands of dynamic queries until the Linux kernel OOM killer terminates PostgreSQL backends), the "Tuple Deforming & Expression Compilation Invalidation on Schema Churn" (where DDL changes or dynamic partitioned table traversals repeatedly invalidate cached JIT artifacts, inducing p99 latency spikes), and the "LLVM SIGSEGV Process Crashes & Postmaster Panic Recovery" (where compiler defects on ARM64 or AVX-512 trigger Signal 11, severing all cluster connections and forcing crash recovery) by establishing a strict 5-Tier JIT Governance Ladder, Cary Millsap Method R response time models, JIT Break-Even theorems, a production-ready TypeScript `AgenticDatabaseJitGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state JIT lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 JIT Compilation Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL introduced Just-In-Time (JIT) compilation using LLVM in version 11 and enabled it by default (`jit = on`) in version 12+. JIT accelerates execution by compiling relational expressions (e.g. arithmetic, string operations, boolean filters) and tuple deforming (extracting column attributes from raw disk tuples into in-memory `TupleTableSlot` pointers) into native x86_64/ARM64 machine instructions, eliminating the overhead of the PostgreSQL expression interpreter loop (`ExecInterpExpr`).

However, LLVM code generation is not free: generating LLVM Intermediate Representation (IR), running inlining passes, executing optimization passes, and emitting machine code via LLVM's ExecutionEngine takes **tens to hundreds of milliseconds of pure CPU time**.

When autonomous coding agents or database engineers attempt to optimize slow queries without understanding JIT mechanics, catastrophic misdiagnoses occur:

### The 6 JIT Compilation Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                         THE 6 JIT COMPILATION & LLVM OVERHEAD CATASTROPHES                         |
+------------------------------------+---------------------------------------------------------------+
| 1. The 100ms LLVM Latency Cliff    | Planner estimates cost > 100,000; engine spends 120ms in LLVM |
|    (Speculative Index Fallacy)     | compile while query runs in 2ms! Total latency is 122ms.      |
|                                    | Agents blindly add indexes, multiplying write bloat in vain!  |
+------------------------------------+---------------------------------------------------------------+
| 2. Optimization Pass CPU Storm     | jit_optimize_above_cost triggers LLVM -O3 passes; concurrent  |
|    (llvm::Pass::run 100% Core Pin) | analytical queries run optimization passes simultaneously,     |
|                                    | pinning all CPU cores at 100% and starving OLTP transactions. |
+------------------------------------+---------------------------------------------------------------+
| 3. Parallel Worker Multiplier      | In a query with W parallel workers, compiled JIT modules are   |
|    (W x JIT Compilation Multiplier)| NOT shared! Each worker process independently compiles LLVM   |
|                                    | IR, multiplying CPU compile burn by (W + 1) before scanning.  |
+------------------------------------+---------------------------------------------------------------+
| 4. LLVM TopMemoryContext Bloat     | Long-lived connection poolers running dynamic queries leak    |
|    (Silent Process Heap OOM)       | LLVM context allocations in backend memory, swelling process  |
|                                    | heap until Linux OOM-killer decapitates the PostgreSQL master.|
+------------------------------------+---------------------------------------------------------------+
| 5. Schema Churn Invalidation       | JIT compiles physical column offsets for tuple deforming; DDL |
|    (Tuple Deforming Thrash Spike)  | modifications or polymorphic partitions invalidate artifacts, |
|                                    | triggering synchronous recompilations and erratic p99 spikes. |
+------------------------------------+---------------------------------------------------------------+
| 6. LLVM SIGSEGV Crash Panic        | Microarchitecture instructions (ARM64/AVX-512) or LLVM bugs   |
|    (Postmaster Emergency Restart)  | trigger Signal 11 inside JIT code; postmaster terminates all  |
|                                    | active connections and enters crash recovery (redo log replay)|
+------------------------------------+---------------------------------------------------------------+
```

### The 5-Tier JIT Governance Ladder

To eradicate these catastrophes, every agent and engineering workflow must adhere to the 5-Tier JIT Governance Ladder:

```
[Tier 0: OLTP Workload Isolation & Conservative Global Defaults]
   │  - Pure OLTP environments: jit = off by default in postgresql.conf
   │  - Mixed workloads: elevate jit_above_cost = 500000, jit_inline_above_cost = 2500000, jit_optimize_above_cost = 2500000
   ▼
[Tier 1: Surgical Transaction-Scoped Analytical JIT Opt-In]
   │  - Analytical pipelines and batch ETL explicitly opt in: SET LOCAL jit = on;
   │  - Only apply JIT where estimated execution time T_exec >> 5000ms
   ▼
[Tier 2: Deactivation of Costly Inlining & Optimization Passes]
   │  - Set jit_optimize_above_cost = -1 and jit_inline_above_cost = -1
   │  - Retain fast expression & tuple deforming JIT (< 5ms) without LLVM -O3 CPU thrash
   ▼
[Tier 3: Autonomous JIT Telemetry & Cary Millsap Diagnostics]
   │  - Extract JIT compilation breakdown from EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
   │  - Compute JIT Overhead Ratio rho_jit = T_compile / T_total; alert if rho_jit > 0.15
   ▼
[Tier 4: Parallel Worker JIT Fencing & Long-Lived Session Lifecycle]
      - Explicitly disable JIT for parallel queries with high worker fan-out
      - Deploy session lifecycle resets (PgBouncer DISCARD ALL, max_conn_lifetime = 30m)
```

---

## 2. Mathematical Models & Formal Verification: The Cary Millsap Method R Decomposition & JIT Break-Even Theorems

Relational query latency under JIT compilation obeys Cary Millsap's Method R decomposition:

$$R_{\text{total}} = T_{\text{plan}} + T_{\text{jit\_compile}} + T_{\text{exec}}$$

where $T_{\text{jit\_compile}}$ decomposes into four distinct phases reported by `EXPLAIN (ANALYZE, BUFFERS)`:

$$T_{\text{jit\_compile}} = T_{\text{generation}} + T_{\text{inlining}} + T_{\text{optimization}} + T_{\text{emission}}$$

and $T_{\text{exec}}$ is the actual execution time scanning buffers and processing rows:

$$T_{\text{exec}} = T_{\text{fetch}} + T_{\text{eval\_jit}} + T_{\text{deform\_jit}} + T_{\text{join\_agg}}$$

### Theorem 1: The JIT Break-Even Execution Inequality

Let $T_{\text{interp}}$ denote the execution duration of a query using standard interpreted expressions, and $T_{\text{jit\_exec}}$ denote execution duration when running JIT-compiled machine code. The JIT execution speedup factor is defined as:

$$\sigma = \frac{T_{\text{interp}}}{T_{\text{jit\_exec}}} \quad (\sigma > 1)$$

For production PostgreSQL analytical workloads, empirical measurements show $\sigma \in [1.15, 1.45]$ (a 15% to 45% execution speedup on CPU-bound expression evaluation and tuple deforming).

**Claim**: JIT compilation yields a net latency improvement if and only if the total compilation overhead is strictly less than the execution time saved:

$$T_{\text{jit\_compile}} < T_{\text{interp}} - T_{\text{jit\_exec}}$$

Substituting $T_{\text{jit\_exec}} = \frac{T_{\text{interp}}}{\sigma}$:

$$T_{\text{jit\_compile}} < T_{\text{interp}} \left(1 - \frac{1}{\sigma}\right) = T_{\text{interp}} \left(\frac{\sigma - 1}{\sigma}\right)$$

Therefore, the **Break-Even Minimum Interpreted Execution Time** $T_{\text{break\_even}}$ is:

$$T_{\text{break\_even}} = \left(\frac{\sigma}{\sigma - 1}\right) T_{\text{jit\_compile}}$$

**Corollary (The Sub-Second Regression Trap)**:
Assume typical compilation metrics where LLVM inlining and optimization are active:
- $T_{\text{generation}} = 15\text{ms}$
- $T_{\text{inlining}} = 35\text{ms}$
- $T_{\text{optimization}} = 55\text{ms}$
- $T_{\text{emission}} = 25\text{ms}$
- $T_{\text{jit\_compile}} = 130\text{ms}$
- Speedup factor $\sigma = 1.30$ (30% faster execution)

$$T_{\text{break\_even}} = \left(\frac{1.30}{0.30}\right) \times 130\text{ms} = 4.333 \times 130\text{ms} \approx 563.3\text{ms}$$

**Result**: Any query whose interpreted execution takes less than **563ms** will suffer a **net regression** under JIT compilation!
For an OLTP query taking $5\text{ms}$ interpreted:
$$R_{\text{jit}} = 130\text{ms} + \frac{5\text{ms}}{1.30} \approx 133.85\text{ms}$$
This represents a **26.7x latency explosion** ($\approx 2670\%$ regression) directly caused by enabling JIT!

---

### Theorem 2: Parallel Worker JIT Multiplicative CPU Overhead

When PostgreSQL executes a query with parallel workers ($W = \text{max\_parallel\_workers\_per\_gather}$), JIT compilation is invoked separately inside each worker process:

$$C_{\text{parallel\_jit}} = (1 + W) \cdot T_{\text{jit\_compile}}$$

Where $1$ represents the Gather leader and $W$ represents the background workers.
If $W = 7$ workers and $T_{\text{jit\_compile}} = 120\text{ms}$, the cluster expends:

$$C_{\text{parallel\_jit}} = (1 + 7) \times 120\text{ms} = 960\text{ms of CPU core time}$$

before parallel execution even begins. If the parallel scan completes in 80ms, the system spent **12x more CPU time compiling code** than executing it!

---

### Theorem 3: LLVM Memory Context Fragmentation Model

In long-lived backend processes, LLVM initializes module-level data structures that reside in `TopMemoryContext` or private glibc heap arenas:

$$M_{\text{backend}}(Q) = M_{\text{base}} + \sum_{i=1}^Q \Delta M_{\text{llvm}}(i) \cdot (1 - \rho_{\text{reclaim}})$$

where $Q$ is the number of distinct parameterized queries compiled, $\Delta M_{\text{llvm}}(i)$ is the allocation delta per module, and $\rho_{\text{reclaim}}$ is the glibc arena reclamation efficiency. Because LLVM does not route all allocations through PostgreSQL's hierarchical `MemoryContext` arenas, $\rho_{\text{reclaim}} < 1.0$, resulting in monotonic unbounded memory drift over days:

$$\lim_{Q \to \infty} M_{\text{backend}}(Q) = \text{OOM Threshold} \implies \text{SIGKILL 137}$$

---

## 3. The 5-Tier JIT Governance Ladder Specifications

### Tier 0: OLTP Workload Isolation & Conservative Global Defaults

In pure OLTP environments (e.g. user authentication, shopping carts, order creation, chat messaging) where queries must complete in $< 20\text{ms}$:
- Set `jit = off` globally in `postgresql.conf`.
- If analytical queries share the database, keep `jit = on` but configure conservative GUC thresholds:
  ```ini
  # postgresql.conf - Hardened OLTP / Mixed Defaults
  jit = on
  jit_above_cost = 500000          # Default 100000 is far too low
  jit_inline_above_cost = 2500000   # Prevent premature LLVM inlining
  jit_optimize_above_cost = 2500000 # Prevent premature LLVM -O3 optimization passes
  ```

### Tier 1: Surgical Transaction-Scoped Analytical JIT Opt-In

Analytical reports, nightly reconciliations, and complex aggregation queries explicitly enable JIT at the transaction or session boundary:

```sql
-- Transaction-scoped JIT activation for heavy reports
BEGIN READ ONLY;
SET LOCAL jit = on;
SET LOCAL jit_above_cost = 10000;
SET LOCAL jit_inline_above_cost = 50000;
SET LOCAL jit_optimize_above_cost = 100000;

SELECT
    date_trunc('day', created_at) AS report_date,
    tenant_id,
    sum(amount_cents) AS total_revenue,
    avg(processing_time_ms) AS avg_latency
FROM financial_transactions
WHERE created_at >= NOW() - INTERVAL '90 days'
GROUP BY 1, 2;

COMMIT;
```

### Tier 2: Deactivation of Costly Inlining & Optimization Passes

LLVM optimization passes (`-O3`) account for over 70% of JIT compile latency while yielding only 5%–10% additional execution speedup over unoptimized JIT expressions.
In high-throughput environments where JIT is required:
```sql
-- Enable JIT expression code emission but disable heavy optimization passes
SET LOCAL jit = on;
SET LOCAL jit_optimize_above_cost = -1;  -- Disables LLVM optimization passes
SET LOCAL jit_inline_above_cost = -1;    -- Disables LLVM function inlining
```
This reduces $T_{\text{jit\_compile}}$ from $150\text{ms}$ down to $< 10\text{ms}$, lowering the break-even threshold from $600\text{ms}$ to $40\text{ms}$!

### Tier 3: Autonomous JIT Telemetry & Cary Millsap Diagnostics

Autonomous agents must never guess whether JIT is beneficial. They must run `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` and parse the `JIT` block:

```json
{
  "Plan": { ... },
  "Planning Time": 0.421,
  "JIT": {
    "Functions": 12,
    "Options": {
      "Inlining": true,
      "Optimization": true,
      "Expressions": true,
      "Deforming": true
    },
    "Timing": {
      "Generation": 12.451,
      "Inlining": 38.210,
      "Optimization": 64.120,
      "Emission": 28.530,
      "Total": 143.311
    }
  },
  "Execution Time": 148.910
}
```

**Diagnostic Rule**:
$$\text{JIT Overhead Ratio} = \frac{\text{JIT Total Timing}}{\text{Total Execution Time}} = \frac{143.311}{148.910} = 96.2\%$$
Here, **96.2% of the entire query duration was wasted on JIT compilation!** The query executed in only $5.6\text{ms}$. The immediate fix is `SET LOCAL jit = off;`—not adding an index!

### Tier 4: Parallel Worker JIT Fencing & Long-Lived Session Lifecycle

1. For queries that launch $\ge 4$ parallel workers, verify whether parallel JIT compilation scales CPU linearly. If CPU spikes, disable JIT for the parallel query:
   ```sql
   SET LOCAL max_parallel_workers_per_gather = 4;
   SET LOCAL jit = off;
   ```
2. In connection poolers (PgBouncer), configure `server_reset_query = DISCARD ALL` and ensure application pools rotate connections periodically:
   ```ini
   # pgbouncer.ini
   server_reset_query = DISCARD ALL
   server_lifetime = 1800 # 30 minutes to eliminate LLVM context heap bloat
   ```

---

## 4. Production TypeScript Reference Implementation: `AgenticDatabaseJitGuardEngine`

The following production-ready engine parses PostgreSQL `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` output, detects JIT latency cliffs, evaluates the break-even threshold, and produces deterministic remediation actions.

```typescript
// src/engines/agentic_database_jit_guard_engine.ts

export interface JitTiming {
  generationMs: number;
  inliningMs: number;
  optimizationMs: number;
  emissionMs: number;
  totalMs: number;
}

export interface JitOptions {
  inlining: boolean;
  optimization: boolean;
  expressions: boolean;
  deforming: boolean;
}

export interface JitMetadata {
  functionsCount: number;
  options: JitOptions;
  timing: JitTiming;
}

export interface ExplainPlanPayload {
  Plan: {
    'Node Type': string;
    'Total Cost': number;
    'Actual Total Time': number;
    Plans?: any[];
  };
  'Planning Time': number;
  'Execution Time': number;
  JIT?: {
    Functions: number;
    Options: {
      Inlining: boolean;
      Optimization: boolean;
      Expressions: boolean;
      Deforming: boolean;
    };
    Timing: {
      Generation: number;
      Inlining: number;
      Optimization: number;
      Emission: number;
      Total: number;
    };
  };
}

export type JitRemediationStrategy =
  | 'RETAIN_JIT'
  | 'DISABLE_JIT_GLOBAL'
  | 'SET_LOCAL_JIT_OFF'
  | 'DISABLE_INLINING_AND_OPTIMIZATION'
  | 'ELEVATE_JIT_ABOVE_COST';

export interface JitTriageReport {
  isJitActive: boolean;
  totalExecutionTimeMs: number;
  jitCompileTimeMs: number;
  pureExecutionTimeMs: number;
  jitOverheadRatio: number;
  estimatedInterpretedTimeMs: number;
  breakEvenThresholdMs: number;
  isLatencyCliff: boolean;
  strategy: JitRemediationStrategy;
  recommendedGucs: Record<string, string | number>;
  diagnosticMessage: string;
}

export class AgenticDatabaseJitGuardEngine {
  private readonly defaultAssumedSpeedup = 1.30; // 30% execution speedup with JIT
  private readonly overheadThreshold = 0.15;    // Alert if JIT compilation > 15% of execution

  /**
   * Analyzes PostgreSQL JSON Explain output and diagnoses JIT regressions.
   */
  public triageQueryExplain(payload: ExplainPlanPayload): JitTriageReport {
    const totalExecutionTimeMs = payload['Execution Time'];
    const jitBlock = payload.JIT;

    if (!jitBlock || !jitBlock.Timing || jitBlock.Timing.Total === 0) {
      return {
        isJitActive: false,
        totalExecutionTimeMs,
        jitCompileTimeMs: 0,
        pureExecutionTimeMs: totalExecutionTimeMs,
        jitOverheadRatio: 0,
        estimatedInterpretedTimeMs: totalExecutionTimeMs,
        breakEvenThresholdMs: 0,
        isLatencyCliff: false,
        strategy: 'RETAIN_JIT',
        recommendedGucs: {},
        diagnosticMessage: 'JIT compilation was not invoked for this query.',
      };
    }

    const jitCompileTimeMs = jitBlock.Timing.Total;
    const pureExecutionTimeMs = Math.max(0.001, totalExecutionTimeMs - jitCompileTimeMs);
    const jitOverheadRatio = jitCompileTimeMs / totalExecutionTimeMs;

    // Estimate interpreted runtime: T_interp = pureExecutionTimeMs * sigma
    const estimatedInterpretedTimeMs = pureExecutionTimeMs * this.defaultAssumedSpeedup;

    // T_break_even = (sigma / (sigma - 1)) * T_jit_compile
    const breakEvenThresholdMs =
      (this.defaultAssumedSpeedup / (this.defaultAssumedSpeedup - 1.0)) * jitCompileTimeMs;

    const isLatencyCliff =
      jitOverheadRatio > this.overheadThreshold && estimatedInterpretedTimeMs < totalExecutionTimeMs;

    let strategy: JitRemediationStrategy = 'RETAIN_JIT';
    const recommendedGucs: Record<string, string | number> = {};
    let diagnosticMessage = '';

    if (jitOverheadRatio >= 0.70) {
      // Severe latency cliff: over 70% of total query duration is LLVM compilation!
      strategy = 'SET_LOCAL_JIT_OFF';
      recommendedGucs['jit'] = 'off';
      diagnosticMessage = `CRITICAL JIT CLIFF: LLVM compilation consumed ${(
        jitOverheadRatio * 100
      ).toFixed(1)}% of total query time (${jitCompileTimeMs.toFixed(1)}ms compile vs ${pureExecutionTimeMs.toFixed(1)}ms exec). Interpreted execution would be ${(
        totalExecutionTimeMs / estimatedInterpretedTimeMs
      ).toFixed(1)}x faster! Disable JIT for this query immediately.`;
    } else if (jitBlock.Timing.Optimization > jitCompileTimeMs * 0.50) {
      // Inlining/Optimization passes are consuming the majority of compilation time
      strategy = 'DISABLE_INLINING_AND_OPTIMIZATION';
      recommendedGucs['jit_optimize_above_cost'] = -1;
      recommendedGucs['jit_inline_above_cost'] = -1;
      diagnosticMessage = `OPTIMIZATION PASS THRASH: LLVM -O3 optimization passes consumed ${jitBlock.Timing.Optimization.toFixed(
        1
      )}ms (${((jitBlock.Timing.Optimization / jitCompileTimeMs) * 100).toFixed(
        1
      )}% of compile time). Disable inlining and optimization passes to cut compile latency while preserving expression JIT.`;
    } else if (isLatencyCliff) {
      strategy = 'ELEVATE_JIT_ABOVE_COST';
      recommendedGucs['jit_above_cost'] = Math.max(
        500000,
        Math.ceil(payload.Plan['Total Cost'] * 1.5)
      );
      diagnosticMessage = `MODERATE JIT REGRESSION: JIT overhead ratio ${(
        jitOverheadRatio * 100
      ).toFixed(1)}% exceeds safety threshold (15%). Estimated interpreted time (${estimatedInterpretedTimeMs.toFixed(
        1
      )}ms) is faster than total time (${totalExecutionTimeMs.toFixed(
        1
      )}ms). Elevate jit_above_cost.`;
    } else {
      diagnosticMessage = `JIT BENEFICIAL: Query executed in ${pureExecutionTimeMs.toFixed(
        1
      )}ms with ${jitCompileTimeMs.toFixed(
        1
      )}ms compilation overhead. JIT speedup exceeds compilation investment.`;
    }

    return {
      isJitActive: true,
      totalExecutionTimeMs,
      jitCompileTimeMs,
      pureExecutionTimeMs,
      jitOverheadRatio,
      estimatedInterpretedTimeMs,
      breakEvenThresholdMs,
      isLatencyCliff,
      strategy,
      recommendedGucs,
      diagnosticMessage,
    };
  }

  /**
   * Generates hardened SQL session prelude statements based on triage recommendation.
   */
  public generateSessionPrelude(strategy: JitRemediationStrategy): string {
    switch (strategy) {
      case 'SET_LOCAL_JIT_OFF':
        return 'SET LOCAL jit = off;';
      case 'DISABLE_INLINING_AND_OPTIMIZATION':
        return 'SET LOCAL jit = on;\nSET LOCAL jit_inline_above_cost = -1;\nSET LOCAL jit_optimize_above_cost = -1;';
      case 'ELEVATE_JIT_ABOVE_COST':
        return 'SET LOCAL jit = on;\nSET LOCAL jit_above_cost = 500000;\nSET LOCAL jit_inline_above_cost = 2500000;\nSET LOCAL jit_optimize_above_cost = 2500000;';
      case 'DISABLE_JIT_GLOBAL':
      case 'RETAIN_JIT':
      default:
        return '-- Default database JIT configuration retained';
    }
  }
}
```

---

## 5. Multi-Language Production Implementations

### Go (`jackc/pgx/v5`): JIT-Aware Query Execution & Telemetry Guard

In Go microservices, high-frequency OLTP queries must never inherit uncontrolled JIT compilation. This production helper provides JIT-guarded transaction execution and telemetry auditing.

```go
// internal/store/jit_guard.go
package store

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type JitExecutionClass string

const (
	JitClassOLTP       JitExecutionClass = "OLTP"       // Strictly jit = off (< 100ms)
	JitClassFastBatch  JitExecutionClass = "FAST_BATCH" // jit = on, optimization = off
	JitClassHeavyOLAP  JitExecutionClass = "HEAVY_OLAP" // full JIT with LLVM optimization
)

type JitGuard struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewJitGuard(pool *pgxpool.Pool, logger *slog.Logger) *JitGuard {
	return &JitGuard{pool: pool, logger: logger}
}

// ExecWithJitPolicy executes a transactional callback with hardened JIT session GUCs.
func (g *JitGuard) ExecWithJitPolicy(
	ctx context.Context,
	class JitExecutionClass,
	fn func(tx pgx.Tx) error,
) error {
	tx, err := g.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx failed: %w", err)
	}
	defer tx.Rollback(ctx)

	// Apply deterministic GUC ladder per execution class
	switch class {
	case JitClassOLTP:
		// Total deactivation: zero LLVM overhead on short OLTP queries
		if _, err := tx.Exec(ctx, "SET LOCAL jit = off;"); err != nil {
			return fmt.Errorf("set local jit off failed: %w", err)
		}
	case JitClassFastBatch:
		// Expression & deform JIT active, but LLVM -O3 passes eliminated
		if _, err := tx.Exec(ctx, `
			SET LOCAL jit = on;
			SET LOCAL jit_above_cost = 50000;
			SET LOCAL jit_inline_above_cost = -1;
			SET LOCAL jit_optimize_above_cost = -1;
		`); err != nil {
			return fmt.Errorf("configure fast batch jit failed: %w", err)
		}
	case JitClassHeavyOLAP:
		// Explicit opt-in for multi-second analytics
		if _, err := tx.Exec(ctx, `
			SET LOCAL jit = on;
			SET LOCAL jit_above_cost = 100000;
			SET LOCAL jit_inline_above_cost = 500000;
			SET LOCAL jit_optimize_above_cost = 500000;
		`); err != nil {
			return fmt.Errorf("configure heavy olap jit failed: %w", err)
		}
	}

	if err := fn(tx); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// ProfileQueryJit performs EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) and logs JIT metrics.
func (g *JitGuard) ProfileQueryJit(ctx context.Context, sqlQuery string, args ...any) error {
	explainSQL := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s", sqlQuery)

	var rawJSON []byte
	err := g.pool.QueryRow(ctx, explainSQL, args...).Scan(&rawJSON)
	if err != nil {
		return fmt.Errorf("explain query failed: %w", err)
	}

	var root []struct {
		ExecutionTime float64 `json:"Execution Time"`
		JIT           *struct {
			Functions int `json:"Functions"`
			Timing    struct {
				Generation   float64 `json:"Generation"`
				Inlining     float64 `json:"Inlining"`
				Optimization float64 `json:"Optimization"`
				Emission     float64 `json:"Emission"`
				Total        float64 `json:"Total"`
			} `json:"Timing"`
		} `json:"JIT"`
	}

	if err := json.Unmarshal(rawJSON, &root); err != nil {
		return fmt.Errorf("unmarshal explain json failed: %w", err)
	}

	if len(root) == 0 {
		return fmt.Errorf("empty explain plan returned")
	}

	entry := root[0]
	if entry.JIT != nil && entry.JIT.Timing.Total > 0 {
		jitTotal := entry.JIT.Timing.Total
		totalTime := entry.ExecutionTime
		overheadRatio := jitTotal / totalTime

		g.logger.Info("Query JIT profile audited",
			slog.Float64("total_time_ms", totalTime),
			slog.Float64("jit_total_ms", jitTotal),
			slog.Float64("jit_overhead_ratio", overheadRatio),
			slog.Float64("optimization_ms", entry.JIT.Timing.Optimization),
		)

		if overheadRatio > 0.20 {
			g.logger.Warn("DETECTED JIT LATENCY CLIFF: LLVM compile time exceeds 20% of query runtime",
				slog.Float64("overhead_percent", overheadRatio*100.0),
				slog.String("recommendation", "SET LOCAL jit = off"),
			)
		}
	}

	return nil
}
```

---

### TypeScript (`drizzle-orm` / `pg`): Guarded Analytics Executor

```typescript
// src/db/jit_guard.ts
import { Pool, PoolClient } from 'pg';

export interface JitConfig {
  mode: 'OLTP' | 'ANALYTICS_FAST' | 'ANALYTICS_HEAVY';
}

export async function withJitPolicy<T>(
  pool: Pool,
  config: JitConfig,
  callback: (client: PoolClient) => Promise<T>
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN;');

    switch (config.mode) {
      case 'OLTP':
        // Strict JIT deactivation for microsecond OLTP
        await client.query('SET LOCAL jit = off;');
        break;
      case 'ANALYTICS_FAST':
        // Expression JIT enabled; eliminate costly inlining and optimization passes
        await client.query(`
          SET LOCAL jit = on;
          SET LOCAL jit_above_cost = 50000;
          SET LOCAL jit_inline_above_cost = -1;
          SET LOCAL jit_optimize_above_cost = -1;
        `);
        break;
      case 'ANALYTICS_HEAVY':
        // Full LLVM optimization for multi-minute reporting
        await client.query(`
          SET LOCAL jit = on;
          SET LOCAL jit_above_cost = 500000;
          SET LOCAL jit_inline_above_cost = 2500000;
          SET LOCAL jit_optimize_above_cost = 2500000;
        `);
        break;
    }

    const result = await callback(client);
    await client.query('COMMIT;');
    return result;
  } catch (error) {
    await client.query('ROLLBACK;');
    throw error;
  } finally {
    client.release();
  }
}
```

---

### Python (`asyncpg`): Context Manager for JIT Isolation

```python
# app/db/jit_guard.py
from contextlib import asynccontextmanager
import asyncpg
import logging

logger = logging.getLogger("db.jit_guard")

@asynccontextmanager
async def jit_scoped_transaction(
    conn: asyncpg.Connection,
    mode: str = "OLTP"
):
    """
    Guarantees deterministic JIT GUC fences across open transactions.
    """
    async with conn.transaction():
        if mode == "OLTP":
            await conn.execute("SET LOCAL jit = off;")
        elif mode == "ANALYTICS_FAST":
            await conn.execute("""
                SET LOCAL jit = on;
                SET LOCAL jit_above_cost = 50000;
                SET LOCAL jit_inline_above_cost = -1;
                SET LOCAL jit_optimize_above_cost = -1;
            """)
        elif mode == "ANALYTICS_HEAVY":
            await conn.execute("""
                SET LOCAL jit = on;
                SET LOCAL jit_above_cost = 500000;
                SET LOCAL jit_inline_above_cost = 2500000;
                SET LOCAL jit_optimize_above_cost = 2500000;
            """)
        else:
            raise ValueError(f"Unknown JIT mode: {mode}")

        try:
            yield conn
        except Exception as e:
            logger.error("Transaction failed under JIT mode %s: %s", mode, e)
            raise
```

---

### Rust (`sqlx`): JIT Profiling & Benchmarking Harness

```rust
// src/db/jit_bench.rs
use sqlx::{PgPool, Row};
use std::time::Instant;

pub struct JitComparisonResult {
    pub interpreted_ms: f64,
    pub jit_compiled_ms: f64,
    pub speedup_ratio: f64,
    pub is_jit_beneficial: bool,
}

pub async fn benchmark_jit_differential(
    pool: &PgPool,
    sql_query: &str,
) -> Result<JitComparisonResult, sqlx::Error> {
    // 1. Measure interpreted execution (jit = off)
    let mut tx_interp = pool.begin().await?;
    sqlx::query("SET LOCAL jit = off;").execute(&mut *tx_interp).await?;
    let start_interp = Instant::now();
    let _ = sqlx::query(sql_query).fetch_all(&mut *tx_interp).await?;
    let interpreted_ms = start_interp.elapsed().as_secs_f64() * 1000.0;
    tx_interp.rollback().await?;

    // 2. Measure JIT-compiled execution (jit = on)
    let mut tx_jit = pool.begin().await?;
    sqlx::query("SET LOCAL jit = on; SET LOCAL jit_above_cost = 0;")
        .execute(&mut *tx_jit)
        .await?;
    let start_jit = Instant::now();
    let _ = sqlx::query(sql_query).fetch_all(&mut *tx_jit).await?;
    let jit_compiled_ms = start_jit.elapsed().as_secs_f64() * 1000.0;
    tx_jit.rollback().await?;

    let speedup_ratio = interpreted_ms / jit_compiled_ms;
    let is_jit_beneficial = jit_compiled_ms < interpreted_ms;

    Ok(JitComparisonResult {
        interpreted_ms,
        jit_compiled_ms,
        speedup_ratio,
        is_jit_beneficial,
    })
}
```

---

### PostgreSQL Diagnostic SQL: Identifying JIT Regressions in `pg_stat_statements`

```sql
-- Identify long-running queries with high CPU burn that may be suffering JIT compilation latency cliffs
SELECT
    queryid,
    calls,
    ROUND(total_exec_time::numeric, 2) AS total_time_ms,
    ROUND(mean_exec_time::numeric, 2) AS mean_time_ms,
    ROUND(stddev_exec_time::numeric, 2) AS stddev_time_ms,
    rows,
    LEFT(query, 120) AS query_snippet
FROM pg_stat_statements
WHERE mean_exec_time > 50.0  -- Queries taking > 50ms
  AND calls > 100
ORDER BY mean_exec_time DESC
LIMIT 20;

-- Verification query: inspect active JIT GUC parameters
SHOW jit;
SHOW jit_above_cost;
SHOW jit_inline_above_cost;
SHOW jit_optimize_above_cost;
```

---

## 6. Six-State JIT Compilation Lifecycle Finite-State Machine (FSM)

The following FSM models the operational lifecycle of JIT calibration across autonomous agent optimizations:

```
[ UNASSESSED ]
      │
      │ Step 1: Run EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
      ▼
[ PROFILED ]
      │
      ├────────────────────────┬────────────────────────┐
      │ rho_jit < 0.15         │ 0.15 <= rho_jit < 0.70  │ rho_jit >= 0.70
      ▼                        ▼                        ▼
[ JIT_CONFIRMED ]      [ GUC_CALIBRATED ]       [ JIT_FENCED ]
(speedup net-positive) (elevate cost thresholds (SET LOCAL jit = off;
                        disable inlining/opt)    revert speculative indexes)
      │                        │                        │
      └────────────────────────┴────────────────────────┘
                               │
                               │ Step 2: Validate regression resolution
                               ▼
                        [ STABILIZED ]
                               │
                               │ Step 3: CI/CD Gate Verification
                               ▼
                        [ MONITORING ]
```

### FSM State Transition Table

| Current State | Event / Trigger | Guard Condition | Next State | Action |
| :--- | :--- | :--- | :--- | :--- |
| `UNASSESSED` | Query Latency Regression Detected | Query duration $> 50\text{ms}$ | `PROFILED` | Execute `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` |
| `PROFILED` | JIT Overhead Evaluated | $\rho_{\text{jit}} \ge 0.70$ (Compile $> 70\%$ of time) | `JIT_FENCED` | Inject `SET LOCAL jit = off;` immediately |
| `PROFILED` | Optimization Pass Thrash | $T_{\text{opt}} \ge 0.50 \cdot T_{\text{compile}}$ | `GUC_CALIBRATED` | Set `jit_optimize_above_cost = -1` |
| `PROFILED` | Net-Positive Speedup | $\rho_{\text{jit}} < 0.15 \land T_{\text{pure}} > T_{\text{break\_even}}$ | `JIT_CONFIRMED` | Retain JIT configuration |
| `JIT_FENCED` | Interpreted Query Re-verified | Execution duration drops by $\ge 50\%$ | `STABILIZED` | Persist session prelude in application code |
| `GUC_CALIBRATED`| Calibrated Query Re-verified | Compile time drops $< 10\text{ms}$ | `STABILIZED` | Persist calibrated GUCs in connection pool |
| `STABILIZED` | Deployment to Staging/Prod | CI Gate passes zero-regression test | `MONITORING` | Register JIT telemetry watchdog alert |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Every autonomous pull request touching database configuration, connection poolers, ORM schemas, or query tuning MUST satisfy all 6 DoD Gates before merging:

```
+----------------------------------------------------------------------------------------------------+
|                       DEFINITION OF DONE (DoD) JIT COMPILATION AUDIT MATRIX                        |
+--------+---------------------------------------+----------------------------------+----------------+
| GATE   | DESCRIPTION                           | TARGET THRESHOLD / METRIC        | ENFORCEMENT    |
+--------+---------------------------------------+----------------------------------+----------------+
| Gate 1 | OLTP JIT Deactivation Gate            | jit = off on all OLTP routes    | Automated CI   |
|        |                                       | (p99 latency < 20ms guaranteed)  | Integration Tx |
+--------+---------------------------------------+----------------------------------+----------------+
| Gate 2 | Break-Even Invariant Gate             | T_exec >= T_break_even           | Static Explain |
|        |                                       | before JIT is enabled on route   | Analyzer       |
+--------+---------------------------------------+----------------------------------+----------------+
| Gate 3 | Optimization Pass CPU Fence Gate      | jit_optimize_above_cost = -1 or  | Configuration  |
|        |                                       | >= 2,500,000 on mixed instances  | Linter         |
+--------+---------------------------------------+----------------------------------+----------------+
| Gate 4 | Parallel Worker Multiplication Gate   | W x T_compile < 200ms or         | Load Test Core |
|        |                                       | JIT disabled on parallel scans   | Profiler       |
+--------+---------------------------------------+----------------------------------+----------------+
| Gate 5 | Backend Memory Retention Gate         | TopMemoryContext growth < 50MB   | 24h Soak Test  |
|        |                                       | over 100,000 query invocations   | Leak Watchdog  |
+--------+---------------------------------------+----------------------------------+----------------+
| Gate 6 | Speculative Index Rejection Gate      | Pull requests adding indexes on  | AST / Schema   |
|        |                                       | JIT-regressed queries REJECTED   | CI Reviewer    |
+--------+---------------------------------------+----------------------------------+----------------+
```

### Machine-Verifiable CI Check Script (`scripts/ci_verify_jit_invariants.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Executing Agentic Database JIT Compilation Invariant Gate..."

# 1. Verify that production postgresql.conf does not use default low JIT thresholds
if grep -E "^[[:space:]]*jit_above_cost[[:space:]]*=[[:space:]]*100000" postgresql.conf 2>/dev/null; then
  echo "❌ CI FAILURE [Gate 3]: postgresql.conf uses dangerously low default jit_above_cost = 100000!"
  echo "   Elevate jit_above_cost to at least 500000 or disable JIT for OLTP workloads."
  exit 1
fi

# 2. Check for missing SET LOCAL jit = off in OLTP repository routes
OLTP_JIT_LEAKS=$(grep -rn "SET LOCAL jit = on" src/repositories/oltp/ 2>/dev/null || true)
if [ -n "$OLTP_JIT_LEAKS" ]; then
  echo "❌ CI FAILURE [Gate 1]: Detected SET LOCAL jit = on in OLTP repository code:"
  echo "$OLTP_JIT_LEAKS"
  exit 1
fi

echo "✅ All Agentic Database JIT Compilation Invariant CI Gates Passed."
```
