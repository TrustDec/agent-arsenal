---
description: PostgreSQL auto_explain query execution plan logging, gettimeofday timing syscall overhead containment (log_timing=off), high-TPS sampling (sample_rate), buffer cache & WAL diagnostics (log_buffers=on, log_wal=on), nested statement PL/pgSQL log bomb defense (log_nested_statements=off), structured JSON plan emission (log_format=json), cardinality misestimation detection (actual vs estimated rows), and zero-impact query plan observability across Go (jackc/pgx/v5), TypeScript (pg, kysely, drizzle-orm), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{auto_explain,explain,execution_plan,query_plan,slow_query,profiling,telemetry,sql,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database `auto_explain`, Execution Plan Logging, Syscall Timing Overhead Containment & High-TPS Sampling Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to capture real-world slow query execution plans in production, diagnose cardinality estimation errors, evaluate actual buffer and WAL consumption, and isolate query plan regressions without bringing down high-throughput database clusters across PostgreSQL (12–17+) in Go (`jackc/pgx/v5`), TypeScript (`pg`, `kysely`, `drizzle-orm`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "100% Timing Overhead Meltdown (`log_analyze = on` + `log_timing = on` Fallacy)" (where calling kernel clock timers on millions of plan nodes increases query execution latency by 15% to 50% and inflates CPU utilization during peak traffic), the "Nested Statement & PL/pgSQL Log Bomb (`log_nested_statements = on` in Loops)" (where iterative functions or batch triggers emit hundreds of thousands of explain plans per second, saturating disk I/O, filling `/var/log` or journald, and triggering cluster failovers), the "Buffer & WAL Blindness Trap (`log_buffers = off` and `log_wal = off`)" (where logged plans omit buffer cache hits, physical disk reads, and dirty page generations, preventing agents from discerning whether a slow query was CPU-bound, disk-thrashing, or write-stalled), the "Unstructured Multiline Text Ingestion Cliff (`log_format = text` vs `json`)" (where unparsed plain text execution trees split across distributed log forwarders such as FluentBit, Vector, or Datadog, breaking AST parsers and blinding autonomous root-cause analysis engines), the "Zero-Duration / Low Threshold DoS (`auto_explain.log_min_duration = 0`)" (where logging all completed queries saturates log lock queues and starves database worker processes), and the "Session-Level Canary Override Ignorance" (where agents fail to leverage transaction-scoped `SET LOCAL auto_explain.log_min_duration = '50ms'` for targeted canary evaluation and migration profiling) by establishing a strict 5-Tier `auto_explain` Governance Ladder, formal system clock syscall overhead theorems, Poisson sampling rate log volume bounds, cardinality misestimation ratio calculus, a production-ready TypeScript `AgenticAutoExplainGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Execution Plan Logging Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, the `auto_explain` module provides an automated mechanism to capture execution plans of slow queries directly from live backend processes without modifying application code or wrapping statements in explicit `EXPLAIN ANALYZE` commands. When an executed query's elapsed duration exceeds `auto_explain.log_min_duration`, the backend formats the plan tree and writes it to the server log:

$$\text{Executor End Hook} \xrightarrow{T_{\text{exec}} \ge \text{log\_min\_duration}} \text{Sample Filter } (U \le \text{sample\_rate}) \xrightarrow{\text{Serialize AST}} \text{Server Log } (\text{JSON / Buffers})$$

While `auto_explain` is indispensable for diagnosing real-world parameter sniffing, plan drift, and cache temperature issues that cannot be replicated in isolated test environments, improper agent configuration or naive activation in production environments precipitates severe outages:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   NAIVE AUTO_EXPLAIN vs RIGOROUS PRODUCTION OBSERVABILITY              │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE AGENT HEURISTICS            │       RIGOROUS ARSENAL INVARIANTS          │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Enables log_timing = on on high-TPS     │ • Enforces log_timing = off or low sample  │
│   (Kernel timer syscalls spike CPU 30%)   │   rates (sample_rate <= 0.05) under load   │
│ • Activates log_nested_statements in loop │ • Strict ban on nested logging without     │
│   (Emits 100k plans/sec; crashes storage) │   duration filters (log_min_duration > 1s) │
│ • Leaves log_buffers = off                │ • Mandatory log_buffers = on & log_wal=on  │
│   (Blinds agents to buffer cache misses)  │   to correlate I/O reads & dirty pages     │
│ • Uses default plain text format          │ • Enforces log_format = json for lossless  │
│   (Splits multiline plans in log shippers)│   structured AST parsing by AI agents      │
│ • Configures log_min_duration = 0         │ • Sets conservative duration thresholds    │
│   (Causes catastrophic log queue stalls)  │   (>= 250ms globally; transaction locals)  │
│ • Relies on global static settings only   │ • Uses transaction-scoped canary overrides │
│   (Cannot safely profile single queries)  │   SET LOCAL auto_explain.log_min_duration  │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Execution Plan Logging Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                         THE 6 AUTO_EXPLAIN EXECUTION LOGGING CATASTROPHES                          |
+------------------------------------+---------------------------------------------------------------+
| 1. System Clock Syscall Overhead   | log_analyze = on with log_timing = on forces the backend to   |
|    (Kernel gettimeofday Thrash)    | execute gettimeofday / clock_gettime on entry/exit of every   |
|                                    | plan node; nested loops with 1M rows suffer 50% latency cliff!|
+------------------------------------+---------------------------------------------------------------+
| 2. PL/pgSQL Nested Log Bomb        | log_nested_statements = on without duration constraints emits |
|    (Disk Fill & I/O Saturation)    | a separate plan for every iteration in PL/pgSQL loops;       |
|                                    | generates 50GB logs in minutes, filling disk and freezing DB! |
+------------------------------------+---------------------------------------------------------------+
| 3. Buffer & WAL Blindness Trap     | log_buffers = off leaves out shared_blks_hit, read, dirtied   |
|    (Root-Cause Disconnect)         | and temp_blks; agent cannot tell whether latency was CPU, NVMe|
|                                    | read stall, or checkpoint dirty buffer writeback contention!  |
+------------------------------------+---------------------------------------------------------------+
| 4. Multiline Text Ingestion Cliff  | log_format = text outputs multi-line indented strings; log    |
|    (Log Shipper AST Corruption)    | shippers (FluentBit, Logstash) split lines across chunks,     |
|                                    | corrupting AST JSON parsers and blinding autonomous APM!      |
+------------------------------------+---------------------------------------------------------------+
| 5. Zero-Duration High-TPS DoS      | Setting log_min_duration = 0 in production logs every query;  |
|    (Syslog Lock Queue Lockup)      | backends spend 80% of runtime formatting plans and waiting on |
|                                    | logging write locks, causing catastrophic connection timeout! |
+------------------------------------+---------------------------------------------------------------+
| 6. Static Global Override Trap     | Agent changes postgresql.conf globally instead of leveraging  |
|    (Blast Radius Amplification)    | session-scoped SET LOCAL auto_explain.log_min_duration = '50ms'|
|                                    | during canaries, exposing the entire database cluster to risk!|
+------------------------------------+---------------------------------------------------------------+
```

---

## 2. The 5-Tier `auto_explain` Governance Ladder

To eliminate these catastrophes, all autonomous coding agents, DBA automation systems, and reliability engineers must enforce the **5-Tier `auto_explain` Governance Ladder**:

```
[ Tier 4: Machine-Verifiable Plan Parsing & Cardinality Divergence Sentinel ]
           ▲
           │ (Parse JSON plans, calculate Actual/Est row ratios, trigger alerts)
[ Tier 3: Transaction-Scoped Canary Overrides & Nested Statement Fencing ]
           ▲
           │ (Strict ban on nested logging without high duration; use SET LOCAL)
[ Tier 2: Comprehensive I/O & WAL Diagnostics Instrumentation ]
           ▲
           │ (Mandatory log_buffers = on and log_wal = on for complete observability)
[ Tier 1: Syscall Timing Containment & High-TPS Sampling Calibration ]
           ▲
           │ (Enforce log_timing = off on nested loops or set sample_rate <= 0.05)
[ Tier 0: Engine Preload, Structured JSON & Conservative Baseline ]
             (shared_preload_libraries, log_format=json, log_min_duration >= 250ms)
```

### Tier 0: Engine Preload, Structured JSON & Conservative Baseline
- **Preload Verification**: Verify `'auto_explain'` is included in `shared_preload_libraries`. Dynamic `LOAD 'auto_explain';` is only supported in superuser sessions and does not apply to client connection pools.
- **Structured Emission**: Always enforce `auto_explain.log_format = json`. Structured JSON plans allow downstream APM agents, OpenTelemetry collectors, and AI harnesses to parse plan trees deterministically without fragile regex heuristics.
- **Conservative Baseline Duration**: Set `auto_explain.log_min_duration = '500ms'` (or `'250ms'` in low-TPS OLTP) globally. Setting duration lower than `100ms` globally without sampling is strictly prohibited.

### Tier 1: Syscall Timing Containment & High-TPS Sampling Calibration
- **The System Clock Tax**: When `auto_explain.log_analyze = on`, PostgreSQL must instrument plan nodes with timing measurements. On platforms where `clock_gettime(CLOCK_MONOTONIC)` incurs vDSO or kernel trap overhead, executing timing calls for millions of tuples in nested loops degrades query throughput:
  $$T_{\text{overhead}} = 2 \cdot N_{\text{node\_invocations}} \cdot t_{\text{clock\_syscall}}$$
- **Timing Deactivation Invariant**: On high-throughput OLTP systems with deep query trees, set `auto_explain.log_timing = off`. This maintains exact actual row counts (`Actual Rows`) and loop counts (`Actual Loops`) while eliminating up to 90% of the timing syscall overhead!
- **Statistical Sampling (`sample_rate`)**: In PostgreSQL 13+, when profiling high-frequency queries with low duration thresholds (e.g., `log_min_duration = '50ms'`), configure `auto_explain.sample_rate = 0.02` (2% sample). This captures representative slow plans without flooding server logs.

### Tier 2: Comprehensive I/O & WAL Diagnostics Instrumentation
- **Mandatory Buffer Telemetry**: Always enforce `auto_explain.log_buffers = on`. This outputs:
  - `Shared Hit Blocks`: Pages retrieved from `shared_buffers` in memory.
  - `Shared Read Blocks`: Physical 8KB pages read from NVMe/disk storage.
  - `Shared Dirtied Blocks`: Pages modified by query execution.
  - `Shared Written Blocks`: Pages written to disk by backend processes.
  - `Local / Temp Blocks`: Disk spillover from external sort and hash aggregations exceeding `work_mem`.
- **WAL Telemetry (PostgreSQL 14+)**: Enforce `auto_explain.log_wal = on` for write queries. It records WAL records generated, full-page images (FPI), and total WAL bytes, isolating write amplification bugs.

### Tier 3: Transaction-Scoped Canary Overrides & Nested Statement Fencing
- **Nested Statement Fencing**: Keep `auto_explain.log_nested_statements = off` globally. Only enable nested logging inside designated administrative sessions or unit test harnesses where PL/pgSQL function internals must be debugged.
- **Transaction-Scoped Canary Activation**: Never modify cluster-wide configurations to investigate a single slow endpoint. Deploy transaction-local GUC overrides in application code:
  ```sql
  BEGIN;
  SET LOCAL auto_explain.log_min_duration = '50ms';
  SET LOCAL auto_explain.log_analyze = 'on';
  SET LOCAL auto_explain.log_buffers = 'on';
  -- Run canary query
  SELECT * FROM orders WHERE tenant_id = $1 ORDER BY created_at DESC LIMIT 50;
  COMMIT;
  ```

### Tier 4: Machine-Verifiable Plan Parsing & Cardinality Divergence Sentinel
- **Cardinality Estimation Error Ratio ($\mathcal{E}_{\text{card}}$)**:
  $$\mathcal{E}_{\text{card}} = \max\left(\frac{R_{\text{actual}}}{R_{\text{est}}}, \frac{R_{\text{est}}}{R_{\text{actual}}}\right)$$
  Where $R_{\text{actual}} = \text{Actual Rows} \times \text{Actual Loops}$ and $R_{\text{est}} = \text{Plan Rows}$.
- **Regression Severity Thresholds**:
  - $\mathcal{E}_{\text{card}} < 3.0$: Acceptable statistical variation.
  - $3.0 \le \mathcal{E}_{\text{card}} < 10.0$: Moderate skew (evaluate `ANALYZE` frequency or `default_statistics_target`).
  - $\mathcal{E}_{\text{card}} \ge 10.0$: **Catastrophic Cardinality Error**. Triggers suboptimal join strategies (e.g., choosing Nested Loop instead of Hash Join), indicating stale statistics, missing multi-column `CREATE STATISTICS`, or unparameterized queries.
- **Temp Disk Spill Sentinel**: Any plan node exhibiting `Temp Read Blocks > 0` or `Temp Written Blocks > 0` must fail CI performance gates and trigger an immediate index or `work_mem` remediation plan.

---

## 3. Mathematical Foundations of Plan Profiling & Overhead Mitigation

### Theorem 1: Kernel Clock Syscall Overhead Upper Bound

Let $Q$ be a query plan tree with $M$ operator nodes. Let $K_i$ be the number of loops executed by node $i$, and $T_i$ be the number of tuples emitted by node $i$. Under `auto_explain.log_analyze = on` with `auto_explain.log_timing = on`, the executor invokes the timing clock at the start and end of each node execution.

The total measurement time overhead $T_{\text{overhead}}$ incurred exclusively by timing instrumentation is bounded by:

$$T_{\text{overhead}} \ge 2 \cdot \left( \sum_{i=1}^{M} K_i \right) \cdot \tau_{\text{clock}}$$

Where $\tau_{\text{clock}}$ is the hardware/kernel latency of a single clock read (e.g., `clock_gettime(CLOCK_MONOTONIC)` via vDSO $\approx 25\text{ns}$, or unvirtualized kernel trap $\approx 350\text{ns}$).

**Corollary (The Nested Loop Cliff)**: If node $j$ is the inner side of a Nested Loop join processing $N_{\text{outer}} = 100,000$ iterations:
$$K_j = 100,000 \implies T_{\text{overhead}} \ge 2 \cdot 10^5 \cdot 350\text{ns} = 70\text{ms}$$
Setting `auto_explain.log_timing = off` eliminates $\tau_{\text{clock}}$ entirely, reducing $T_{\text{overhead}} \to 0$ while preserving exact cardinality $R_{\text{actual}}$.

---

### Theorem 2: Poisson Sampling Rate Log Volume Inequality

Let $\lambda_{\text{total}}$ be the aggregate query throughput of the database cluster (queries per second). Let $p_{\text{slow}} = P(T_{\text{exec}} \ge \text{log\_min\_duration})$ be the probability that a query breaches the duration threshold. Let $s \in (0, 1]$ be `auto_explain.sample_rate`.

The average log emission rate $\Phi_{\text{log}}$ (bytes per second) is given by:

$$\Phi_{\text{log}} = \lambda_{\text{total}} \cdot p_{\text{slow}} \cdot s \cdot \bar{S}_{\text{plan\_json}}$$

Where $\bar{S}_{\text{plan\_json}}$ is the mean byte size of a serialized JSON execution plan (typically $4\text{KB} - 16\text{KB}$).

To prevent saturating the database logging subsystem and triggering write buffer backpressure on the storage controller, the sample rate $s$ must satisfy:

$$s \le \min\left(1.0, \, \frac{B_{\text{log\_disk\_bandwidth}}}{\lambda_{\text{total}} \cdot p_{\text{slow}} \cdot \bar{S}_{\text{plan\_json}}}\right)$$

**Production Baseline**: For a system with $\lambda_{\text{total}} = 5,000\text{ QPS}$, $p_{\text{slow}} = 0.05$ (250 slow queries/sec), $\bar{S} = 8\text{KB}$, and maximum allowable logging egress $B = 4\text{MB/sec}$:
$$s \le \frac{4 \cdot 10^6}{5000 \cdot 0.05 \cdot 8192} = \frac{4,000,000}{2,048,000} \approx 1.95 \implies s = 0.05 \text{ (Safe 5\% sample)}$$

---

### Theorem 3: Cardinality Estimation Divergence Index ($\mathcal{D}_{\text{card}}$)

The Cardinality Divergence Index $\mathcal{D}_{\text{card}}$ across an entire execution plan tree of $M$ nodes measures the cumulative severity of optimizer estimation failures:

$$\mathcal{D}_{\text{card}}(Q) = \sum_{i=1}^{M} w_i \cdot \ln\left( 1 + \left| \frac{R_{\text{actual}, i} - R_{\text{est}, i}}{\max(1, R_{\text{est}, i})} \right| \right)$$

Where the node weight $w_i = \frac{T_{\text{node}, i}}{T_{\text{total}}}$ is proportional to the fraction of query execution time spent in node $i$.

A plan with $\mathcal{D}_{\text{card}} > 2.5$ in nodes representing $>40\%$ of query duration indicates that the physical plan choice (e.g., Sequential Scan instead of Index Scan, or Hash Join instead of Merge Join) is mathematically compromised by statistical failure.

---

## 4. Production-Ready TypeScript Guard Engine: `AgenticAutoExplainGuardEngine`

The following TypeScript engine provides complete configuration auditing, JSON execution plan parsing, cardinality divergence detection, buffer cache hit profiling, and automated remediation generation.

```typescript
// src/telemetry/AgenticAutoExplainGuardEngine.ts

export interface AutoExplainConfig {
  logMinDurationMs: number;
  logAnalyze: boolean;
  logBuffers: boolean;
  logWal: boolean;
  logTiming: boolean;
  logNestedStatements: boolean;
  logFormat: 'json' | 'text' | 'yaml' | 'xml';
  sampleRate: number;
}

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
  'Actual Startup Time'?: number;
  'Actual Total Time'?: number;
  'Shared Hit Blocks'?: number;
  'Shared Read Blocks'?: number;
  'Shared Dirtied Blocks'?: number;
  'Shared Written Blocks'?: number;
  'Temp Read Blocks'?: number;
  'Temp Written Blocks'?: number;
  'Plans'?: PlanNode[];
}

export interface AutoExplainLogPayload {
  durationMs: number;
  queryText: string;
  plan: PlanNode;
  planningTimeMs?: number;
  executionTimeMs?: number;
}

export interface PlanNodeAnomaly {
  nodeType: string;
  relationName?: string;
  actualRows: number;
  estimatedRows: number;
  cardinalityErrorRatio: number;
  timeSpentMs: number;
  sharedReadBlocks: number;
  tempSpillBlocks: number;
  anomalyType: 'CARDINALITY_MISMATCH' | 'TEMP_DISK_SPILL' | 'CACHE_MISS_STALL' | 'INEFFICIENT_NESTED_LOOP';
  description: string;
}

export interface PlanAuditReport {
  queryText: string;
  totalDurationMs: number;
  cacheHitRatio: number;
  totalDiskReads: number;
  totalTempSpillBlocks: number;
  maxCardinalityError: number;
  hasSevereAnomalies: boolean;
  anomalies: PlanNodeAnomaly[];
  recommendations: string[];
}

export class AgenticAutoExplainGuardEngine {
  /**
   * Audits PostgreSQL server auto_explain configuration against production safety invariants.
   */
  public static auditConfiguration(config: AutoExplainConfig): { isSafe: boolean; violations: string[] } {
    const violations: string[] = [];

    // Invariant 1: Format must be JSON for reliable machine consumption
    if (config.logFormat !== 'json') {
      violations.push(`VIOLATION: log_format is '${config.logFormat}'. Must be 'json' for deterministic AST parsing.`);
    }

    // Invariant 2: Duration threshold cannot be zero in production
    if (config.logMinDurationMs <= 0) {
      violations.push(`VIOLATION: log_min_duration is ${config.logMinDurationMs}ms. Must be >= 250ms globally to avoid log saturation.`);
    }

    // Invariant 3: Nested statements must be disabled by default
    if (config.logNestedStatements && config.logMinDurationMs < 1000) {
      violations.push(`VIOLATION: log_nested_statements=on with duration ${config.logMinDurationMs}ms risks PL/pgSQL loop log flood.`);
    }

    // Invariant 4: Buffers must be enabled
    if (!config.logBuffers) {
      violations.push(`VIOLATION: log_buffers is false. Must be enabled to diagnose NVMe I/O vs memory cache hits.`);
    }

    // Invariant 5: Sample rate bounds
    if (config.sampleRate <= 0 || config.sampleRate > 1.0) {
      violations.push(`VIOLATION: sample_rate must be in range (0.0, 1.0]. Given: ${config.sampleRate}`);
    }

    // Invariant 6: High TPS timing overhead fence
    if (config.logAnalyze && config.logTiming && config.sampleRate > 0.1 && config.logMinDurationMs < 200) {
      violations.push(`WARNING: log_timing=on with sample_rate=${config.sampleRate} and low duration threshold risks kernel clock syscall CPU thrashing.`);
    }

    return {
      isSafe: violations.length === 0,
      violations,
    };
  }

  /**
   * Traverses and audits an auto_explain JSON plan tree.
   */
  public static auditExecutionPlan(payload: AutoExplainLogPayload): PlanAuditReport {
    const anomalies: PlanNodeAnomaly[] = [];
    let totalHitBlocks = 0;
    let totalReadBlocks = 0;
    let totalTempBlocks = 0;
    let maxErrorRatio = 1.0;

    const traverse = (node: PlanNode) => {
      const actualLoops = node['Actual Loops'] ?? 1;
      const actualRowsPerLoop = node['Actual Rows'] ?? 0;
      const totalActualRows = actualRowsPerLoop * actualLoops;
      const estimatedRows = Math.max(1, node['Plan Rows']);

      const hit = node['Shared Hit Blocks'] ?? 0;
      const read = node['Shared Read Blocks'] ?? 0;
      const tempRead = node['Temp Read Blocks'] ?? 0;
      const tempWritten = node['Temp Written Blocks'] ?? 0;

      totalHitBlocks += hit;
      totalReadBlocks += read;
      totalTempBlocks += tempRead + tempWritten;

      const timeSpent = node['Actual Total Time'] ?? 0;

      // Compute Cardinality Error Ratio
      const errorRatio = totalActualRows >= estimatedRows
        ? totalActualRows / estimatedRows
        : estimatedRows / Math.max(1, totalActualRows);

      if (errorRatio > maxErrorRatio) {
        maxErrorRatio = errorRatio;
      }

      // Check Cardinality Mismatch
      if (errorRatio >= 10.0 && timeSpent > 20.0) {
        anomalies.push({
          nodeType: node['Node Type'],
          relationName: node['Relation Name'],
          actualRows: totalActualRows,
          estimatedRows,
          cardinalityErrorRatio: Number(errorRatio.toFixed(2)),
          timeSpentMs: timeSpent,
          sharedReadBlocks: read,
          tempSpillBlocks: tempRead + tempWritten,
          anomalyType: 'CARDINALITY_MISMATCH',
          description: `Severe cardinality divergence: Planner estimated ${estimatedRows} rows, but node processed ${totalActualRows} rows (${errorRatio.toFixed(1)}x error).`,
        });
      }

      // Check Temp Disk Spillage
      if ((tempRead + tempWritten) > 0) {
        anomalies.push({
          nodeType: node['Node Type'],
          relationName: node['Relation Name'],
          actualRows: totalActualRows,
          estimatedRows,
          cardinalityErrorRatio: Number(errorRatio.toFixed(2)),
          timeSpentMs: timeSpent,
          sharedReadBlocks: read,
          tempSpillBlocks: tempRead + tempWritten,
          anomalyType: 'TEMP_DISK_SPILL',
          description: `Disk file spill: Node spilled ${tempRead + tempWritten} 8KB blocks to disk (work_mem exceeded during sort/hash).`,
        });
      }

      // Check Buffer Cache Miss Stall
      if (read > 1000 && timeSpent > 50.0) {
        const localHitRatio = (hit + read) > 0 ? (hit / (hit + read)) * 100 : 100;
        if (localHitRatio < 80.0) {
          anomalies.push({
            nodeType: node['Node Type'],
            relationName: node['Relation Name'],
            actualRows: totalActualRows,
            estimatedRows,
            cardinalityErrorRatio: Number(errorRatio.toFixed(2)),
            timeSpentMs: timeSpent,
            sharedReadBlocks: read,
            tempSpillBlocks: 0,
            anomalyType: 'CACHE_MISS_STALL',
            description: `Buffer cache thrashing: ${read} physical 8KB reads executed (${localHitRatio.toFixed(1)}% cache hit ratio).`,
          });
        }
      }

      // Recurse children
      if (node.Plans && Array.isArray(node.Plans)) {
        for (const child of node.Plans) {
          traverse(child);
        }
      }
    };

    traverse(payload.plan);

    const totalBlocks = totalHitBlocks + totalReadBlocks;
    const globalCHR = totalBlocks > 0 ? (totalHitBlocks / totalBlocks) * 100 : 100;

    const recommendations: string[] = [];

    if (totalTempBlocks > 0) {
      recommendations.push(
        `ELEVATE WORK_MEM: Query spilled ${totalTempBlocks} blocks to disk. Elevate transaction-scoped work_mem or add covering index supporting sort order.`
      );
    }

    if (maxErrorRatio >= 10.0) {
      recommendations.push(
        `REFRESH STATISTICS: Cardinality diverged by ${maxErrorRatio.toFixed(1)}x. Run ANALYZE on involved tables or create multivariate CREATE STATISTICS.`
      );
    }

    if (globalCHR < 95.0 && totalReadBlocks > 500) {
      recommendations.push(
        `OPTIMIZE BUFFER CACHE: Only ${globalCHR.toFixed(1)}% cache hit ratio (${totalReadBlocks} disk reads). Evaluate index coverage (INCLUDE) or pg_prewarm.`
      );
    }

    return {
      queryText: payload.queryText,
      totalDurationMs: payload.durationMs,
      cacheHitRatio: Number(globalCHR.toFixed(2)),
      totalDiskReads: totalReadBlocks,
      totalTempSpillBlocks: totalTempBlocks,
      maxCardinalityError: Number(maxErrorRatio.toFixed(2)),
      hasSevereAnomalies: anomalies.length > 0,
      anomalies,
      recommendations,
    };
  }

  /**
   * Generates safe transaction-scoped SQL statements for canary plan evaluation.
   */
  public static generateCanaryHarness(sql: string, durationThresholdMs: number = 50): string {
    return [
      'BEGIN;',
      `SET LOCAL auto_explain.log_min_duration = '${durationThresholdMs}ms';`,
      'SET LOCAL auto_explain.log_analyze = on;',
      'SET LOCAL auto_explain.log_buffers = on;',
      'SET LOCAL auto_explain.log_wal = on;',
      'SET LOCAL auto_explain.log_timing = off; -- Minimizes timing syscall overhead',
      'SET LOCAL auto_explain.log_format = json;',
      '-- Canary Query Execution:',
      sql.trim().endsWith(';') ? sql.trim() : `${sql.trim()};`,
      'COMMIT;',
    ].join('\n');
  }
}
```

---

## 5. Cross-Runtime Implementations & Production Integrations

### Go (`jackc/pgx/v5`): Canary Query Plan Collector with Transaction-Scoped `auto_explain`

```go
// internal/db/canary_plan_evaluator.go
package db

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type CanaryPlanResult struct {
	QueryText        string                 `json:"query_text"`
	ExecutionTimeMs  float64                `json:"execution_time_ms"`
	SharedHitBlocks  int64                  `json:"shared_hit_blocks"`
	SharedReadBlocks int64                  `json:"shared_read_blocks"`
	TempBlocks       int64                  `json:"temp_blocks"`
	RawPlanJSON      map[string]interface{} `json:"raw_plan_json"`
	Recommendations  []string               `json:"recommendations"`
}

type CanaryPlanEvaluator struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewCanaryPlanEvaluator(pool *pgxpool.Pool, logger *slog.Logger) *CanaryPlanEvaluator {
	return &CanaryPlanEvaluator{pool: pool, logger: logger}
}

// ExecuteWithExplicitExplain runs an isolated EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
// to inspect execution metrics safely without altering global database settings.
func (e *CanaryPlanEvaluator) ExecuteWithExplicitExplain(
	ctx context.Context,
	query string,
	args ...any,
) (*CanaryPlanResult, error) {
	conn, err := e.pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to acquire connection: %w", err)
	}
	defer conn.Release()

	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, fmt.Errorf("failed to begin readonly transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	explainSQL := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) %s", query)

	var planJSONRaw []byte
	start := time.Now()
	err = tx.QueryRow(ctx, explainSQL, args...).Scan(&planJSONRaw)
	duration := time.Since(start)

	if err != nil {
		return nil, fmt.Errorf("explain execution failed: %w", err)
	}

	var rootPlans []map[string]interface{}
	if err := json.Unmarshal(planJSONRaw, &rootPlans); err != nil || len(rootPlans) == 0 {
		return nil, fmt.Errorf("failed to parse explain json: %w", err)
	}

	planObj, ok := rootPlans[0]["Plan"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("malformed plan tree root")
	}

	var hit, read, tempWritten, tempRead int64
	if v, ok := planObj["Shared Hit Blocks"].(float64); ok {
		hit = int64(v)
	}
	if v, ok := planObj["Shared Read Blocks"].(float64); ok {
		read = int64(v)
	}
	if v, ok := planObj["Temp Written Blocks"].(float64); ok {
		tempWritten = int64(v)
	}
	if v, ok := planObj["Temp Read Blocks"].(float64); ok {
		tempRead = int64(v)
	}

	var recs []string
	totalTemp := tempWritten + tempRead
	if totalTemp > 0 {
		recs = append(recs, fmt.Sprintf("TEMP_SPILL: Spilled %d blocks to disk. Hoist sort ordering to B-Tree index or elevate work_mem.", totalTemp))
	}
	totalBlocks := hit + read
	if totalBlocks > 200 {
		chr := float64(hit) / float64(totalBlocks) * 100
		if chr < 98.0 {
			recs = append(recs, fmt.Sprintf("BUFFER_DEFICIT: Cache hit ratio %.1f%% < 98.0%% (%d physical disk reads). Evaluate covering index.", chr, read))
		}
	}

	return &CanaryPlanResult{
		QueryText:        query,
		ExecutionTimeMs:  float64(duration.Microseconds()) / 1000.0,
		SharedHitBlocks:  hit,
		SharedReadBlocks: read,
		TempBlocks:       totalTemp,
		RawPlanJSON:      planObj,
		Recommendations:  recs,
	}, nil
}
```

---

### Python (`asyncpg`): Auto-Explain Plan Stream Parser & Cardinality Divergence Sentinel

```python
# app/telemetry/auto_explain_monitor.py
import json
import logging
from typing import Dict, Any, List, Optional
import asyncpg

logger = logging.getLogger("telemetry.auto_explain")

class AutoExplainSentinel:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def verify_cluster_settings(self) -> Dict[str, Any]:
        """Audits live database settings for auto_explain invariants."""
        async with self.pool.acquire() as conn:
            records = await conn.fetch("""
                SELECT name, setting, unit
                FROM pg_settings
                WHERE name LIKE 'auto_explain.%';
            """)
            settings = {r["name"]: r["setting"] for r in records}

            format_setting = settings.get("auto_explain.log_format", "text")
            min_duration = int(settings.get("auto_explain.log_min_duration", "-1"))

            is_safe = True
            defects: List[str] = []

            if format_setting != "json":
                is_safe = False
                defects.append(f"Format is '{format_setting}', expected 'json'.")

            if 0 <= min_duration < 250:
                is_safe = False
                defects.append(f"log_min_duration is {min_duration}ms, dangerously low without sample_rate.")

            return {
                "is_safe": is_safe,
                "settings": settings,
                "defects": defects,
            }

    @staticmethod
    def inspect_plan_dict(plan_data: Dict[str, Any]) -> Dict[str, Any]:
        """Calculates cardinality estimation divergence and disk spillage from parsed JSON plan."""
        plan_node = plan_data.get("Plan", {})
        anomalies = []

        def traverse(node: Dict[str, Any]):
            node_type = node.get("Node Type", "Unknown")
            est_rows = max(1.0, float(node.get("Plan Rows", 1.0)))
            loops = float(node.get("Actual Loops", 1.0))
            act_rows = float(node.get("Actual Rows", 0.0)) * loops

            error_ratio = act_rows / est_rows if act_rows >= est_rows else est_rows / max(1.0, act_rows)

            temp_written = int(node.get("Temp Written Blocks", 0))
            if temp_written > 0:
                anomalies.append({
                    "node": node_type,
                    "defect": "TEMP_SPILL",
                    "details": f"Spilled {temp_written} 8KB blocks to disk.",
                })

            if error_ratio >= 10.0 and act_rows > 100:
                anomalies.append({
                    "node": node_type,
                    "defect": "CARDINALITY_ERROR",
                    "error_ratio": round(error_ratio, 2),
                    "details": f"Estimated {est_rows} rows vs actual {act_rows} rows ({error_ratio:.1f}x error).",
                })

            for child in node.get("Plans", []):
                traverse(child)

        traverse(plan_node)
        return {
            "has_anomalies": len(anomalies) > 0,
            "anomaly_count": len(anomalies),
            "anomalies": anomalies,
        }
```

---

### Rust (`sqlx`): Zero-Overhead Diagnostic Plan Harness

```rust
// src/telemetry/auto_explain_harness.rs
use sqlx::PgPool;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub struct PlanMetrics {
    #[serde(rename = "Node Type")]
    pub node_type: String,
    #[serde(rename = "Plan Rows")]
    pub plan_rows: f64,
    #[serde(rename = "Actual Rows", default)]
    pub actual_rows: Option<f64>,
    #[serde(rename = "Actual Loops", default)]
    pub actual_loops: Option<f64>,
    #[serde(rename = "Shared Hit Blocks", default)]
    pub shared_hit_blocks: Option<i64>,
    #[serde(rename = "Shared Read Blocks", default)]
    pub shared_read_blocks: Option<i64>,
    #[serde(rename = "Temp Written Blocks", default)]
    pub temp_written_blocks: Option<i64>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ExplainResult {
    #[serde(rename = "Plan")]
    pub plan: PlanMetrics,
    #[serde(rename = "Planning Time", default)]
    pub planning_time: Option<f64>,
    #[serde(rename = "Execution Time", default)]
    pub execution_time: Option<f64>,
}

pub struct DiagnosticPlanHarness {
    pool: PgPool,
}

impl DiagnosticPlanHarness {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Safely obtains an execution plan with buffers and timing disabled to eliminate syscall overhead.
    pub async fn explain_query(&self, sql: &str) -> Result<ExplainResult, sqlx::Error> {
        let explain_sql = format!(
            "EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) {}",
            sql
        );

        let row: (serde_json::Value,) = sqlx::query_as(&explain_sql)
            .fetch_one(&self.pool)
            .await?;

        let mut results: Vec<ExplainResult> = serde_json::from_value(row.0)
            .map_err(|e| sqlx::Error::Decode(Box::new(e)))?;

        results.pop().ok_or_else(|| {
            sqlx::Error::Decode("Empty explain result array".into())
        })
    }
}
```

---

## 6. The 6-State Plan Profiling Finite-State Machine (FSM)

Autonomous agents must transition through the formal **6-State Plan Profiling FSM** when analyzing or resolving slow queries:

```
[ State 0: Engine Configuration Audit ]
         │ (Verify shared_preload_libraries, log_format=json, timing safety)
         ▼
[ State 1: Sampling & Threshold Guard ]
         │ (Enforce log_min_duration >= 250ms, sample_rate <= 0.05 on high-TPS)
         ▼
[ State 2: Transaction-Scoped Canary Injection ]
         │ (Execute SET LOCAL parameters inside isolated test transaction)
         ▼
[ State 3: Structured Plan AST Traversal ]
         │ (Extract Actual vs Estimated Rows, Shared Buffers, Temp Spillage)
         ▼
[ State 4: Divergence & Bottleneck Classification ]
         │ (Compute Cardinality Error Ratio and categorize I/O vs CPU vs Memory)
         ▼
[ State 5: Invariant Verification & Remediation ]
         │ (Generate covering index, CREATE STATISTICS, or work_mem adjustment)
         ▼
[ DoD Machine-Verified Clean Exit ]
```

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

An autonomous coding agent is **STRICTLY PROHIBITED** from declaring a database performance issue resolved or an `auto_explain` configuration safe without satisfying the **6-Gate DoD Matrix**:

| Gate Number | Validation Gate | Required Verification Command / Invariant | Blocking Criteria |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **Structured Format** | `SHOW auto_explain.log_format;` returns `json` | Plain text output breaks automated AST ingestion. |
| **Gate 2** | **Timing Overhead Containment** | `auto_explain.log_timing = off` OR `sample_rate <= 0.05` | Syscall clock overhead $> 5\%$ of CPU runtime. |
| **Gate 3** | **Buffer Telemetry Invariant** | `auto_explain.log_buffers = on` confirmed | Blinds telemetry engine to physical NVMe disk reads. |
| **Gate 4** | **Nested Statement Protection** | `auto_explain.log_nested_statements = off` in OLTP | PL/pgSQL loops emit flood of log statements. |
| **Gate 5** | **Zero Temp Disk Spillage** | `Temp Written Blocks == 0` on targeted query | Hash/Sort operations thrashing disk storage. |
| **Gate 6** | **Cardinality Error Ratio** | $\mathcal{E}_{\text{card}} = \max(R_{\text{act}}/R_{\text{est}}, R_{\text{est}}/R_{\text{act}}) < 3.0$ | Misestimation forces suboptimal Nested Loop joins. |

---

## 8. Anti-Patterns & Prohibited Agent Actions

- ❌ **NEVER enable `auto_explain.log_timing = on` unconditionally on high-TPS clusters**:
  - Calling `clock_gettime` for every node on nested loop iterations burns CPU and inflates p99 latencies.
- ❌ **NEVER set `auto_explain.log_min_duration = 0` in production**:
  - Emitting an execution plan for every single executed query saturates disk I/O, floods journald, and locks backend logging queues.
- ❌ **NEVER configure `auto_explain.log_nested_statements = on` with low duration thresholds**:
  - Functions executing loops with thousands of queries will generate hundreds of megabytes of logs in seconds.
- ❌ **NEVER use plain text `auto_explain.log_format = text` for automated pipelines**:
  - Plain text execution trees split across log aggregators and break automated AST parsers. Always use `log_format = json`.
- ❌ **NEVER omit `auto_explain.log_buffers = on`**:
  - Execution duration alone does not disclose whether a query stalled on NVMe storage reads or CPU execution. Buffers are mandatory.
- ❌ **NEVER apply global configuration changes when canary testing an endpoint**:
  - Use `SET LOCAL auto_explain.log_min_duration = '50ms'` within transaction boundaries to isolate profiling blast radius.
