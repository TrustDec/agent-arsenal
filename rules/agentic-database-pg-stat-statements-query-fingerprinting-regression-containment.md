---
description: PostgreSQL pg_stat_statements query profiling, normalized query fingerprinting (queryid), execution time variance (stddev_exec_time), Coefficient of Variation tail latency profiling, disk I/O timing (blk_read_time/blk_write_time), buffer cache hit ratio calculus, temp disk file spillage (temp_blks_written), eviction storm defense (dealloc), zero-reset differential snapshotting, and performance regression containment across Go (jackc/pgx/v5), TypeScript (pg, kysely, drizzle-orm), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{pg_stat_statements,profiling,stat,queryid,telemetry,query_optimizer,slow_query,latency,sql,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database `pg_stat_statements`, Query Fingerprinting, Coefficient of Variation Profiling & Performance Regression Containment Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to monitor database query throughput, profile production SQL workloads, triage latency regressions, identify tail performance outliers, and evaluate database migration impact across PostgreSQL (12–17+) in Go (`jackc/pgx/v5`), TypeScript (`pg`, `kysely`, `drizzle-orm`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Global Average Latency Mirage & Tail Variance Masking Trap" (where sorting queries by `mean_exec_time` completely conceals critical p99/p99.9 latency spikes and parameter sniffing anomalies because millions of 0.5ms executions drown out hundreds of 45-second lock stalls or nested-loop cliffs), the "Dynamic Literal / Variable IN-Clause Fingerprint Explosion" (where applications string-interpolate SQL literals or emit variable-length `WHERE id IN (...)` clauses, exhausting `pg_stat_statements.max` and triggering continuous `dealloc` evictions that blind telemetry engines during active incidents), the "Zero-I/O Timing Blindness (`track_io_timing = off` Fallacy)" (where agents observe `blk_read_time = 0` and `blk_write_time = 0` due to disabled kernel timer instrumentation, falsely diagnosing disk-thrashing queries as CPU-bound and wasting tokens on futile code rewrites), the "Post-Deployment Cumulative Amnesia & Destructive `pg_stat_statements_reset()` Catastrophe" (where agents either compare raw cumulative multi-month metrics against immediate post-migration runs, or destructively execute `SELECT pg_stat_statements_reset()` globally on production, wiping out organizational APM baselines and alerting thresholds), the "Buffer Cache Hit Ratio Deficit & Temp Disk Spillover Horizon" (where queries appear fast in low-data test environments but in production execute hundreds of thousands of physical buffer reads or spill gigabytes of external merge sort/hash tables to disk via `temp_blks_written > 0`), and the "`compute_query_id` Mismatch & Distributed Trace / APM Disconnect" (where unaligned query IDs or lack of application comment tagging breaks correlation between OpenTelemetry trace spans and database engine fingerprints) by establishing a strict 5-Tier `pg_stat_statements` Governance Ladder, formal Coefficient of Variation ($c_v$) tail latency theorems, buffer cache hit ratio calculus, Total Workload Impact Score (TWIS) models, a production-ready TypeScript `AgenticPgStatStatementsGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Profiling Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, `pg_stat_statements` is the foundational extension for continuous execution profiling. It intercepts all completed queries, parses SQL syntax into an abstract normalized tree, masks constant literals with parameter placeholders (`$1, $2, ...`), computes a 64-bit query hash (`queryid`), and records cumulative execution metrics into a shared-memory hash table:

$$\text{Query Engine Intercept} \xrightarrow{\text{Parse \& Normalize}} \text{Fingerprint }( \text{queryid} ) \xrightarrow{\text{Lock Free Update}} \text{Shared Memory Buffer } (N \le \text{pg\_stat\_statements.max})$$

While `pg_stat_statements` provides unmatched visibility into relational database execution, autonomous coding agents frequently misinterpret its telemetry or misuse its management functions, precipitating severe production outages:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   NAIVE QUERY PROFILING vs RIGOROUS STATEMENTS TRIAGE                   │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE AGENT HEURISTICS            │       RIGOROUS ARSENAL INVARIANTS          │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Sorts naively by mean_exec_time         │ • Calculates Coefficient of Variation      │
│   (Masks severe p99 / parameter sniffing) │   c_v = stddev / mean to catch tail cliffs │
│ • Blind to disabled track_io_timing       │ • Validates track_io_timing = on to        │
│   (Misdiagnoses I/O waits as CPU work)    │   isolate NVMe read/write wait stalls      │
│ • Tolerates dynamic literal sprawl        │ • Enforces array binds = ANY($1::type[])   │
│   (Causes continuous dealloc evictions)   │   preventing hash table capacity churn     │
│ • Executes global pg_stat_statements_reset│ • Uses zero-wipe differential snapshots    │
│   (Wipes out baseline APM telemetry)      │   Delta M = M(t2) - M(t1) across canaries  │
│ • Ignores temp_blks_written disk spills   │ • Enforces temp_blks_written == 0 gate     │
│   (Permits disk I/O thrashing in OLTP)    │   preventing external merge sorts on disk  │
│ • Disconnected from application traces    │ • Injects SQL comment tags /* trace_id */  │
│   (Cannot correlate slow queries to code) │   linking OpenTelemetry spans to queryid   │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Query Profiling Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                         THE 6 PG_STAT_STATEMENTS PROFILING CATASTROPHES                            |
+------------------------------------+---------------------------------------------------------------+
| 1. Global Average Latency Mirage   | Agent sorts queries by mean_exec_time; 1,000,000 runs at      |
|    (Tail Variance Masking Trap)    | 0.5ms mask 100 executions taking 45 seconds; agent reports     |
|                                    | "query is fast", hiding catastrophic p99 timeouts and outages! |
+------------------------------------+---------------------------------------------------------------+
| 2. Dynamic Literal / IN Sprawl     | Unparameterized SQL or variable-length WHERE id IN (...)      |
|    (Ring Buffer Eviction Storm)    | floods distinct queries, exhausting pg_stat_statements.max;   |
|                                    | continuous deallocations evict true slow queries from memory! |
+------------------------------------+---------------------------------------------------------------+
| 3. Zero-I/O Timing Blindness       | track_io_timing is disabled by default; blk_read_time and     |
|    (track_io_timing = off Fallacy) | blk_write_time report 0.0ms; agent falsely diagnoses disk I/O  |
|                                    | bottlenecks as CPU burn, generating futile code rewrites!     |
+------------------------------------+---------------------------------------------------------------+
| 4. Post-Deployment Reset Disaster  | Agent either compares cumulative multi-month numbers against  |
|    (Telemetry Baseline Amnesia)    | new canary runs, or runs SELECT pg_stat_statements_reset()    |
|                                    | globally, destroying production APM baselines and alerting!    |
+------------------------------------+---------------------------------------------------------------+
| 5. Buffer Hit Deficit & Temp Spill | Agent ignores shared_blks_hit vs shared_blks_read and         |
|    (Disk Thrashing Horizon)        | temp_blks_written; query seems fast on small staging tables   |
|                                    | but in production spills 200MB temp files and trashes cache!  |
+------------------------------------+---------------------------------------------------------------+
| 6. Missing compute_query_id        | Query IDs disabled or queries rewritten dynamically without   |
|    (APM Distributed Trace Sever)   | SQL comment tags; breaks correlation between APM trace spans  |
|                                    | and database queryid, making root-cause triage impossible!    |
+------------------------------------+---------------------------------------------------------------+
```

---

## 2. The 5-Tier `pg_stat_statements` Governance Ladder

To eliminate these catastrophes, all autonomous coding agents, migration systems, and performance engineers must enforce the **5-Tier `pg_stat_statements` Governance Ladder**:

```
[ Tier 4: Machine-Verifiable CI Gate & APM Trace Correlation Sentinel ]
           ▲
           │ (Enforce SQL comment tags, array binds, and verify queryid in traces)
[ Tier 3: Differential Window Snapshotting & Zero-Wipe Baseline Auditing ]
           ▲
           │ (Calculate Delta M = M(t2) - M(t1); strictly forbid global resets)
[ Tier 2: Page Access Calculus & Temp File Spillover Hardening ]
           ▲
           │ (Assert Cache Hit Ratio >= 99% and zero temp_blks_written in OLTP)
[ Tier 1: Tail Latency, Coefficient of Variation & Variance Profiling ]
           ▲
           │ (Compute c_v = stddev / mean; flag c_v >= 2.0 parameter sniffing)
[ Tier 0: Engine Configuration, Extension Verification & Timer Instrumentation ]
             (shared_preload_libraries, track_io_timing=on, compute_query_id=on)
```

### Tier 0: Engine Configuration, Extension Verification & Timer Instrumentation
- **Preload Requirement**: Verify that `'pg_stat_statements'` is explicitly loaded via `shared_preload_libraries` in `postgresql.conf`. Dynamic `LOAD 'pg_stat_statements';` into an active session is insufficient for shared-memory allocation.
- **Timer Activation**: Explicitly activate `track_io_timing = on`. Without this GUC parameter, PostgreSQL does not query the CPU clock before and after page read/write system calls (`read()`, `write()`, `preadv()`), leaving `blk_read_time` and `blk_write_time` permanently zero.
- **Capacity Sizing**: Set `pg_stat_statements.max = 10000` (default 5000 is inadequate for large enterprise schemas) to prevent memory ring buffer evictions.
- **Query ID Computation**: In PostgreSQL 14+, guarantee `compute_query_id = on` (or `'auto'`) so that the core backend computes stable 64-bit query IDs visible in both `pg_stat_statements` and `pg_stat_activity`.

### Tier 1: Tail Latency, Coefficient of Variation & Variance Profiling
- **The Outlier Invariant**: Never sort queries solely by `mean_exec_time` or `total_exec_time`.
- **Coefficient of Variation ($c_v$)**: Compute the normalized execution variance:
  $$c_v = \frac{\sigma_{\text{exec}}}{\mu_{\text{exec}}} = \frac{\text{stddev\_exec\_time}}{\text{mean\_exec\_time}}$$
- **Variance Thresholds**:
  - $c_v < 0.5$: Highly deterministic, stable execution (uniform index point lookups).
  - $0.5 \le c_v < 1.5$: Normal operational variance (variations in result set sizes or concurrency).
  - $c_v \ge 2.0$: **Severe Bimodal / Tail Regression**. Indicates parameter sniffing (where the planner switches between Index Scan and Seq Scan depending on input parameters), lock queue wait stalls, or intermittent temp file disk spillage.

### Tier 2: Page Access Calculus & Temp File Spillover Hardening
- **Shared Buffer Cache Hit Ratio (CHR)**:
  $$\text{CHR}(Q) = \frac{\text{shared\_blks\_hit}}{\text{shared\_blks\_hit} + \text{shared\_blks\_read}}$$
  Enforce $\text{CHR}(Q) \ge 0.99$ for high-frequency OLTP queries. Queries with $\text{CHR} < 0.95$ must be prioritized for covering index creation (`INCLUDE`), column pruning, or buffer pool prewarming.
- **Zero Temp Spillage Invariant**:
  $$\text{temp\_blks\_written} = 0 \quad \text{and} \quad \text{temp\_blks\_read} = 0$$
  Any OLTP query exhibiting $\text{temp\_blks\_written} > 0$ indicates that sort, hash, or materialization operations exceeded per-node `work_mem`. The agent must either add an index supporting the sort ordering (`ORDER BY`) or elevate `work_mem` within the transaction scope.

### Tier 3: Differential Window Snapshotting & Zero-Wipe Baseline Auditing
- **Strict Prohibition on Production Resets**: Agents must **never** execute `SELECT pg_stat_statements_reset()` or `pg_stat_statements_reset(dbid, userid, queryid)` on production clusters. Doing so erases cumulative performance baselines and breaks external APM integrations (Datadog, New Relic, pganalyze).
- **Differential Snapshot Calculus**: To measure the performance impact of a deployment or migration, capture two point-in-time snapshots $S_1$ at $t_1$ and $S_2$ at $t_2$:
  $$\Delta \text{calls} = \text{calls}(S_2) - \text{calls}(S_1)$$
  $$\Delta \text{time} = \text{total\_exec\_time}(S_2) - \text{total\_exec\_time}(S_1)$$
  $$\Delta \text{mean} = \frac{\Delta \text{time}}{\Delta \text{calls}}$$
  If $\Delta \text{calls} = 0$, the query was not invoked during the observation window.

### Tier 4: Machine-Verifiable CI Gate & APM Trace Correlation Sentinel
- **Parameterization Enforcement**: Ban raw string interpolation in SQL. Require parameterized query binds ($1, $2) or static array containment (`= ANY($1::bigint[])`) for dynamic item lists, preventing `dealloc` evictions.
- **SQL Comment Tagging**: Require applications to prepend structured comment headers to SQL queries:
  ```sql
  /* app:order-svc,action:get_by_id,trace_id:4bf92f3577b34da6a3ce929d0e0e4736 */
  SELECT id, status, total_cents FROM orders WHERE id = $1;
  ```
- **Correlation**: Link the PostgreSQL 64-bit `queryid` directly into OpenTelemetry trace spans (`db.query_id`), allowing instant cross-referencing between APM flamegraphs and engine statistics.

---

## 3. Mathematical Foundations & Workload Calculus

### 3.1 Total Workload Impact Score (TWIS)
Evaluating query severity cannot rely solely on execution time. A query running 10,000,000 times taking 1ms consumes far more cluster resources than a query running once taking 2,000ms. Furthermore, queries that perform disk I/O or spill to temp files degrade concurrent transactions.

The **Total Workload Impact Score** $\mathcal{W}(Q)$ is defined as:

$$\mathcal{W}(Q) = \mathcal{T}_{\text{exec}}(Q) \cdot \left[ 1 + \omega_{\text{io}} \cdot \frac{\mathcal{T}_{\text{io}}(Q)}{\mathcal{T}_{\text{exec}}(Q) + \epsilon} + \omega_{\text{temp}} \cdot \frac{\mathcal{B}_{\text{temp}}(Q)}{\mathcal{B}_{\text{hit}}(Q) + \mathcal{B}_{\text{read}}(Q) + 1} \right]$$

Where:
- $\mathcal{T}_{\text{exec}}(Q) = \text{total\_exec\_time}$: Total cumulative CPU + I/O wall clock time in milliseconds.
- $\mathcal{T}_{\text{io}}(Q) = \text{blk\_read\_time} + \text{blk\_write\_time}$: Total disk I/O wait time in milliseconds.
- $\mathcal{B}_{\text{temp}}(Q) = \text{temp\_blks\_written}$: Number of 8KB disk pages spilled to temp storage.
- $\mathcal{B}_{\text{hit}}(Q) = \text{shared\_blks\_hit}$, $\mathcal{B}_{\text{read}}(Q) = \text{shared\_blks\_read}$: Total shared buffer page accesses.
- $\omega_{\text{io}} = 2.5$: Penalty weight for synchronous physical disk block read stalls.
- $\omega_{\text{temp}} = 5.0$: Severe penalty weight for disk-spilling external merge sorts / hash aggregations.
- $\epsilon = 0.001$: Smoothing term preventing division by zero.

### 3.2 Tail Latency Skew Theorem & Parameter Sniffing Detection
Let execution time of query $Q$ be represented by random variable $X$ with empirical mean $\mu = \text{mean\_exec\_time}$ and empirical standard deviation $\sigma = \text{stddev\_exec\_time}$.

By Chebyshev's Inequality, for any $k > 1$:
$$P(|X - \mu| \ge k \sigma) \le \frac{1}{k^2}$$

When an agent detects a Coefficient of Variation:
$$c_v = \frac{\sigma}{\mu} \ge 2.0$$

The 99th percentile execution time $X_{p99}$ satisfies:
$$X_{p99} \ge \mu + \sigma \sqrt{\frac{p}{1-p}} = \mu + 2\mu \sqrt{99} \approx 20.9 \cdot \mu$$

Thus, for any query where $c_v \ge 2.0$, **the 99th percentile latency is guaranteed to be at least $20\times$ higher than the reported mean latency**. Autonomous agents that rely on `mean_exec_time` will underestimate tail latency by more than an entire order of magnitude.

### 3.3 Dynamic Parameterization vs Ring Buffer Eviction Physics
Let $M = \text{pg\_stat\_statements.max}$ be the maximum hash table capacity (default 5,000). Let $\lambda_{\text{unique}}$ be the arrival rate of unique SQL normalized texts per second.

When an application uses dynamic unparameterized queries:
```sql
-- ❌ CATASTROPHIC SPRAWL: 1 unique entry per permutation!
SELECT * FROM users WHERE id IN (1, 2);
SELECT * FROM users WHERE id IN (1, 2, 3);
SELECT * FROM users WHERE id IN (1, 2, 3, 4);
```

The number of distinct normalized queries $N_{\text{queries}}(K)$ for variable length $K \le K_{\text{max}}$ expands combinatorially:
$$N_{\text{queries}}(K) = \sum_{k=1}^{K_{\text{max}}} 1 = K_{\text{max}}$$

If the application dynamically embeds integer IDs directly without binds (`WHERE tenant_id = 42` vs `WHERE tenant_id = 43` in non-parameterized statements), $N_{\text{queries}} \to \infty$.

Once the entry count reaches $M$, PostgreSQL must deallocate the least-used query entry via LRU eviction to insert new queries. The cumulative number of evicted queries is exposed via `pg_stat_statements_info.dealloc`:

$$\text{Eviction Rate} = \frac{\Delta \text{dealloc}}{\Delta t}$$

If $\Delta \text{dealloc} / \Delta t > 0.05 \text{ evictions/sec}$, the ring buffer is thrashing. Historical execution metrics for slow queries are evicted before monitoring systems can capture them.

---

## 4. Production Implementation: TypeScript `AgenticPgStatStatementsGuardEngine`

The following production-ready engine demonstrates how autonomous systems must query, parse, differentiate, and audit `pg_stat_statements` metrics without global resets:

```typescript
// src/db/pgStatStatementsGuardEngine.ts
import { Pool, PoolClient } from 'pg';

export interface RawPgStatEntry {
  queryid: string;
  query: string;
  calls: string;
  total_exec_time: number;
  mean_exec_time: number;
  stddev_exec_time: number;
  min_exec_time: number;
  max_exec_time: number;
  rows: string;
  shared_blks_hit: string;
  shared_blks_read: string;
  shared_blks_dirtied: string;
  shared_blks_written: string;
  local_blks_hit: string;
  local_blks_read: string;
  local_blks_dirtied: string;
  local_blks_written: string;
  temp_blks_read: string;
  temp_blks_written: string;
  blk_read_time: number;
  blk_write_time: number;
}

export interface StatementMetricSnapshot {
  timestampMs: number;
  entries: Map<string, RawPgStatEntry>;
}

export interface StatementDiff {
  queryid: string;
  query: string;
  deltaCalls: number;
  deltaTotalTimeMs: number;
  meanExecTimeMs: number;
  stddevExecTimeMs: number;
  coefVariation: number;
  cacheHitRatio: number;
  tempBlocksWritten: number;
  ioWaitTimeMs: number;
  ioTimePercent: number;
  totalWorkloadImpactScore: number;
  anomalies: string[];
}

export interface TriageReport {
  observationWindowSec: number;
  totalQueriesEvaluated: number;
  topWorkloadQueries: StatementDiff[];
  anomalousQueries: StatementDiff[];
  deallocCount: number;
  ioTimingEnabled: boolean;
}

export class AgenticPgStatStatementsGuardEngine {
  constructor(private readonly pool: Pool) {}

  /**
   * Validates database GUC parameters for accurate profiling.
   * Ensures track_io_timing is enabled and inspects hash table capacity.
   */
  async verifyInstrumentationPrerequisites(client?: PoolClient): Promise<{
    isPreloaded: boolean;
    trackIoTiming: boolean;
    maxEntries: number;
    deallocCount: number;
  }> {
    const db = client ?? (await this.pool.connect());
    try {
      // 1. Verify extension is preloaded & installed
      const extCheck = await db.query<{ installed: boolean }>(`
        SELECT EXISTS (
          SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'
        ) AS installed;
      `);

      if (!extCheck.rows[0]?.installed) {
        throw new Error(
          "INVARIANT_BREACH: pg_stat_statements extension is not installed in database. " +
          "Run 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'"
        );
      }

      // 2. Check track_io_timing
      const ioTimingCheck = await db.query<{ setting: string }>(`
        SHOW track_io_timing;
      `);
      const trackIoTiming = ioTimingCheck.rows[0]?.setting === 'on';

      // 3. Check capacity and deallocations
      const configCheck = await db.query<{ setting: string }>(`
        SHOW pg_stat_statements.max;
      `);
      const maxEntries = parseInt(configCheck.rows[0]?.setting ?? '5000', 10);

      // Check deallocations if pg_stat_statements_info is available (PG 14+)
      let deallocCount = 0;
      try {
        const infoRes = await db.query<{ dealloc: string }>(`
          SELECT dealloc FROM pg_stat_statements_info;
        `);
        deallocCount = parseInt(infoRes.rows[0]?.dealloc ?? '0', 10);
      } catch {
        // PG 13 and below do not have pg_stat_statements_info
      }

      return {
        isPreloaded: true,
        trackIoTiming,
        maxEntries,
        deallocCount,
      };
    } finally {
      if (!client) (db as PoolClient).release();
    }
  }

  /**
   * Captures an immutable point-in-time snapshot of pg_stat_statements.
   * Guaranteed zero-wipe: does NOT execute pg_stat_statements_reset().
   */
  async captureSnapshot(client?: PoolClient): Promise<StatementMetricSnapshot> {
    const db = client ?? (await this.pool.connect());
    try {
      const res = await db.query<RawPgStatEntry>(`
        SELECT
          queryid::text,
          query,
          calls::text,
          total_exec_time,
          mean_exec_time,
          stddev_exec_time,
          min_exec_time,
          max_exec_time,
          rows::text,
          shared_blks_hit::text,
          shared_blks_read::text,
          shared_blks_dirtied::text,
          shared_blks_written::text,
          local_blks_hit::text,
          local_blks_read::text,
          local_blks_dirtied::text,
          local_blks_written::text,
          temp_blks_read::text,
          temp_blks_written::text,
          blk_read_time,
          blk_write_time
        FROM pg_stat_statements
        WHERE query NOT LIKE '%pg_stat_statements%'
          AND query NOT LIKE '/* heartbeat */%';
      `);

      const entries = new Map<string, RawPgStatEntry>();
      for (const row of res.rows) {
        entries.set(row.queryid, row);
      }

      return {
        timestampMs: Date.now(),
        entries,
      };
    } finally {
      if (!client) (db as PoolClient).release();
    }
  }

  /**
   * Computes the mathematical differential between two snapshots.
   * Evaluates Coefficient of Variation, Cache Hit Ratio, Temp Spills, and TWIS.
   */
  computeDifferential(
    snapBefore: StatementMetricSnapshot,
    snapAfter: StatementMetricSnapshot
  ): StatementDiff[] {
    const results: StatementDiff[] = [];
    const windowSec = (snapAfter.timestampMs - snapBefore.timestampMs) / 1000;

    for (const [queryid, after] of snapAfter.entries.entries()) {
      const before = snapBefore.entries.get(queryid);

      const callsBefore = before ? BigInt(before.calls) : 0n;
      const callsAfter = BigInt(after.calls);
      const deltaCalls = Number(callsAfter - callsBefore);

      if (deltaCalls <= 0) {
        continue; // Query was not called during this observation window
      }

      const totalTimeBefore = before ? before.total_exec_time : 0;
      const deltaTotalTimeMs = Math.max(0, after.total_exec_time - totalTimeBefore);
      const meanExecTimeMs = deltaTotalTimeMs / deltaCalls;

      // Variance from engine telemetry
      const stddevExecTimeMs = after.stddev_exec_time;
      const coefVariation = meanExecTimeMs > 0 ? stddevExecTimeMs / meanExecTimeMs : 0;

      // Shared Buffer calculations
      const sharedHitBefore = before ? BigInt(before.shared_blks_hit) : 0n;
      const sharedReadBefore = before ? BigInt(before.shared_blks_read) : 0n;
      const deltaHit = Number(BigInt(after.shared_blks_hit) - sharedHitBefore);
      const deltaRead = Number(BigInt(after.shared_blks_read) - sharedReadBefore);
      const totalBlocks = deltaHit + deltaRead;
      const cacheHitRatio = totalBlocks > 0 ? deltaHit / totalBlocks : 1.0;

      // Temp blocks written (disk spill)
      const tempWrittenBefore = before ? BigInt(before.temp_blks_written) : 0n;
      const tempBlocksWritten = Number(BigInt(after.temp_blks_written) - tempWrittenBefore);

      // I/O Wait calculations
      const ioTimeBefore = before ? (before.blk_read_time + before.blk_write_time) : 0;
      const ioTimeAfter = after.blk_read_time + after.blk_write_time;
      const ioWaitTimeMs = Math.max(0, ioTimeAfter - ioTimeBefore);
      const ioTimePercent = deltaTotalTimeMs > 0 ? (ioWaitTimeMs / deltaTotalTimeMs) * 100 : 0;

      // Total Workload Impact Score (TWIS)
      // TWIS = deltaTotalTimeMs * (1 + 2.5 * (ioWaitTimeMs / (deltaTotalTimeMs + 0.001)) + 5.0 * (tempBlocks / (totalBlocks + 1)))
      const ioPenalty = deltaTotalTimeMs > 0 ? (ioWaitTimeMs / deltaTotalTimeMs) : 0;
      const tempPenalty = totalBlocks > 0 ? (tempBlocksWritten / (totalBlocks + 1)) : (tempBlocksWritten > 0 ? 1.0 : 0);
      const totalWorkloadImpactScore = deltaTotalTimeMs * (1.0 + 2.5 * ioPenalty + 5.0 * tempPenalty);

      // Anomaly Detection
      const anomalies: string[] = [];
      if (coefVariation >= 2.0 && meanExecTimeMs >= 5.0) {
        anomalies.push(
          `HIGH_VARIANCE_TAIL_OUTLIER: c_v=${coefVariation.toFixed(2)} >= 2.0 (Possible parameter sniffing or lock contention)`
        );
      }
      if (cacheHitRatio < 0.98 && totalBlocks > 500) {
        anomalies.push(
          `LOW_CACHE_HIT_RATIO: CHR=${(cacheHitRatio * 100).toFixed(1)}% < 98% (${deltaRead} disk blocks read)`
        );
      }
      if (tempBlocksWritten > 0) {
        anomalies.push(
          `TEMP_DISK_SPILLOVER: ${tempBlocksWritten} 8KB blocks spilled to disk (Exceeded work_mem limit)`
        );
      }
      if (ioTimePercent >= 40.0 && deltaTotalTimeMs >= 50.0) {
        anomalies.push(
          `IO_BOUND_STALL: ${ioTimePercent.toFixed(1)}% of execution time spent waiting on disk read/write`
        );
      }

      results.push({
        queryid,
        query: after.query,
        deltaCalls,
        deltaTotalTimeMs,
        meanExecTimeMs,
        stddevExecTimeMs,
        coefVariation,
        cacheHitRatio,
        tempBlocksWritten,
        ioWaitTimeMs,
        ioTimePercent,
        totalWorkloadImpactScore,
        anomalies,
      });
    }

    // Sort by Total Workload Impact Score descending
    results.sort((a, b) => b.totalWorkloadImpactScore - a.totalWorkloadImpactScore);
    return results;
  }

  /**
   * Generates a structured triage audit report from two snapshots.
   */
  async generateTriageReport(
    snapBefore: StatementMetricSnapshot,
    snapAfter: StatementMetricSnapshot
  ): Promise<TriageReport> {
    const prereqs = await this.verifyInstrumentationPrerequisites();
    const diffs = this.computeDifferential(snapBefore, snapAfter);
    const windowSec = (snapAfter.timestampMs - snapBefore.timestampMs) / 1000;

    const anomalousQueries = diffs.filter((d) => d.anomalies.length > 0);
    const topWorkloadQueries = diffs.slice(0, 10);

    return {
      observationWindowSec: windowSec,
      totalQueriesEvaluated: diffs.length,
      topWorkloadQueries,
      anomalousQueries,
      deallocCount: prereqs.deallocCount,
      ioTimingEnabled: prereqs.trackIoTiming,
    };
  }
}
```

---

## 5. Multi-Runtime Production Implementations

### 5.1 Go (`jackc/pgx/v5`): Automated Canary Differential Verifier & Anomaly Detector

```go
// internal/store/pgstat_sentinel.go
package store

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type StatementMetrics struct {
	QueryID          int64     `json:"query_id"`
	Query            string    `json:"query"`
	Calls            int64     `json:"calls"`
	TotalExecTimeMs  float64   `json:"total_exec_time_ms"`
	MeanExecTimeMs   float64   `json:"mean_exec_time_ms"`
	StddevExecTimeMs float64   `json:"stddev_exec_time_ms"`
	SharedBlksHit    int64     `json:"shared_blks_hit"`
	SharedBlksRead   int64     `json:"shared_blks_read"`
	TempBlksWritten  int64     `json:"temp_blks_written"`
	BlkReadTimeMs    float64   `json:"blk_read_time_ms"`
	BlkWriteTimeMs   float64   `json:"blk_write_time_ms"`
	CapturedAt       time.Time `json:"captured_at"`
}

type StatementDifferential struct {
	QueryID          int64   `json:"query_id"`
	Query            string  `json:"query"`
	DeltaCalls       int64   `json:"delta_calls"`
	DeltaTimeMs      float64 `json:"delta_time_ms"`
	MeanTimeMs       float64 `json:"mean_time_ms"`
	CoefVariation    float64 `json:"coef_variation"`
	CacheHitRatio    float64 `json:"cache_hit_ratio"`
	TempBlksWritten  int64   `json:"temp_blks_written"`
	IsAnomaly        bool    `json:"is_anomaly"`
	AnomalyReason    string  `json:"anomaly_reason,omitempty"`
}

type PgStatSentinel struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewPgStatSentinel(pool *pgxpool.Pool, logger *slog.Logger) *PgStatSentinel {
	return &PgStatSentinel{pool: pool, logger: logger}
}

// CaptureSnapshot collects all current statements without resetting baseline.
func (s *PgStatSentinel) CaptureSnapshot(ctx context.Context) (map[int64]StatementMetrics, error) {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to acquire connection for pg_stat snapshot: %w", err)
	}
	defer conn.Release()

	// Verify track_io_timing
	var trackIOTiming string
	if err := conn.QueryRow(ctx, "SHOW track_io_timing;").Scan(&trackIOTiming); err != nil {
		return nil, fmt.Errorf("failed to check track_io_timing: %w", err)
	}
	if trackIOTiming != "on" {
		s.logger.WarnContext(ctx, "track_io_timing is DISABLED; I/O metrics will read 0.0ms")
	}

	rows, err := conn.Query(ctx, `
		SELECT
			queryid,
			query,
			calls,
			total_exec_time,
			mean_exec_time,
			stddev_exec_time,
			shared_blks_hit,
			shared_blks_read,
			temp_blks_written,
			blk_read_time,
			blk_write_time
		FROM pg_stat_statements
		WHERE query NOT LIKE '%pg_stat_statements%'
	`)
	if err != nil {
		return nil, fmt.Errorf("failed to query pg_stat_statements: %w", err)
	}
	defer rows.Close()

	snapshot := make(map[int64]StatementMetrics)
	now := time.Now()

	for rows.Next() {
		var m StatementMetrics
		m.CapturedAt = now
		if err := rows.Scan(
			&m.QueryID,
			&m.Query,
			&m.Calls,
			&m.TotalExecTimeMs,
			&m.MeanExecTimeMs,
			&m.StddevExecTimeMs,
			&m.SharedBlksHit,
			&m.SharedBlksRead,
			&m.TempBlksWritten,
			&m.BlkReadTimeMs,
			&m.BlkWriteTimeMs,
		); err != nil {
			return nil, fmt.Errorf("failed to scan pg_stat row: %w", err)
		}
		snapshot[m.QueryID] = m
	}

	return snapshot, nil
}

// ComputeDiff calculates the delta between two snapshots and evaluates invariants.
func (s *PgStatSentinel) ComputeDiff(
	before, after map[int64]StatementMetrics,
) []StatementDifferential {
	var diffs []StatementDifferential

	for qid, post := range after {
		pre, exists := before[qid]
		var deltaCalls int64
		var deltaTimeMs float64

		if exists {
			deltaCalls = post.Calls - pre.Calls
			deltaTimeMs = math.Max(0, post.TotalExecTimeMs-pre.TotalExecTimeMs)
		} else {
			deltaCalls = post.Calls
			deltaTimeMs = post.TotalExecTimeMs
		}

		if deltaCalls <= 0 {
			continue
		}

		meanMs := deltaTimeMs / float64(deltaCalls)
		cv := 0.0
		if meanMs > 0 {
			cv = post.StddevExecTimeMs / meanMs
		}

		// Cache Hit Ratio
		var deltaHit, deltaRead, deltaTemp int64
		if exists {
			deltaHit = post.SharedBlksHit - pre.SharedBlksHit
			deltaRead = post.SharedBlksRead - pre.SharedBlksRead
			deltaTemp = post.TempBlksWritten - pre.TempBlksWritten
		} else {
			deltaHit = post.SharedBlksHit
			deltaRead = post.SharedBlksRead
			deltaTemp = post.TempBlksWritten
		}

		totalBlks := deltaHit + deltaRead
		chr := 1.0
		if totalBlks > 0 {
			chr = float64(deltaHit) / float64(totalBlks)
		}

		diff := StatementDifferential{
			QueryID:         qid,
			Query:           post.Query,
			DeltaCalls:      deltaCalls,
			DeltaTimeMs:     deltaTimeMs,
			MeanTimeMs:      meanMs,
			CoefVariation:   cv,
			CacheHitRatio:   chr,
			TempBlksWritten: deltaTemp,
		}

		// Enforce DoD Invariants
		if cv >= 2.0 && meanMs >= 5.0 {
			diff.IsAnomaly = true
			diff.AnomalyReason = fmt.Sprintf("High tail variance: c_v=%.2f >= 2.0 (Parameter sniffing suspected)", cv)
		} else if chr < 0.98 && totalBlks > 200 {
			diff.IsAnomaly = true
			diff.AnomalyReason = fmt.Sprintf("Low cache hit ratio: %.1f%% < 98%% (%d disk blocks read)", chr*100, deltaRead)
		} else if deltaTemp > 0 {
			diff.IsAnomaly = true
			diff.AnomalyReason = fmt.Sprintf("Disk spill: %d temp 8KB blocks written to disk (work_mem overflow)", deltaTemp)
		}

		diffs = append(diffs, diff)
	}

	return diffs
}
```

### 5.2 Python (`asyncpg`): Pre/Post Migration Regression Verification Harness

```python
# db/pgstat_canary_verifier.py
import asyncio
from typing import Dict, Any, List
import asyncpg


class PgStatCanaryVerifier:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def capture_snapshot(self) -> Dict[int, Dict[str, Any]]:
        """Captures statements snapshot without destructive reset."""
        async with self.pool.acquire() as conn:
            # Assert track_io_timing is active
            io_val = await conn.fetchval("SHOW track_io_timing;")
            if io_val != "on":
                print("WARNING: track_io_timing is off. Disk I/O timers will read 0.")

            rows = await conn.fetch("""
                SELECT
                    queryid,
                    query,
                    calls,
                    total_exec_time,
                    mean_exec_time,
                    stddev_exec_time,
                    shared_blks_hit,
                    shared_blks_read,
                    temp_blks_written,
                    blk_read_time,
                    blk_write_time
                FROM pg_stat_statements
                WHERE query NOT LIKE '%pg_stat_statements%';
            """)

            return {
                r["queryid"]: {
                    "query": r["query"],
                    "calls": r["calls"],
                    "total_exec_time": float(r["total_exec_time"]),
                    "mean_exec_time": float(r["mean_exec_time"]),
                    "stddev_exec_time": float(r["stddev_exec_time"]),
                    "shared_blks_hit": r["shared_blks_hit"],
                    "shared_blks_read": r["shared_blks_read"],
                    "temp_blks_written": r["temp_blks_written"],
                    "blk_read_time": float(r["blk_read_time"]),
                    "blk_write_time": float(r["blk_write_time"]),
                }
                for r in rows
            }

    def verify_no_regressions(
        self,
        before: Dict[int, Dict[str, Any]],
        after: Dict[int, Dict[str, Any]],
        max_allowed_cv: float = 2.0,
        min_chr: float = 0.98,
    ) -> List[str]:
        """Validates that no queries regressed in tail variance, CHR, or temp spill."""
        violations = []

        for qid, post in after.items():
            pre = before.get(qid)
            if pre:
                delta_calls = post["calls"] - pre["calls"]
                delta_time = max(0.0, post["total_exec_time"] - pre["total_exec_time"])
                delta_hit = post["shared_blks_hit"] - pre["shared_blks_hit"]
                delta_read = post["shared_blks_read"] - pre["shared_blks_read"]
                delta_temp = post["temp_blks_written"] - pre["temp_blks_written"]
            else:
                delta_calls = post["calls"]
                delta_time = post["total_exec_time"]
                delta_hit = post["shared_blks_hit"]
                delta_read = post["shared_blks_read"]
                delta_temp = post["temp_blks_written"]

            if delta_calls <= 0:
                continue

            mean_ms = delta_time / delta_calls
            cv = post["stddev_exec_time"] / mean_ms if mean_ms > 0 else 0.0

            total_blks = delta_hit + delta_read
            chr_ratio = (delta_hit / total_blks) if total_blks > 0 else 1.0

            # 1. Gate: Temp Disk Spill
            if delta_temp > 0:
                violations.append(
                    f"REGRESSION [QueryID {qid}]: Spilled {delta_temp} blocks to temp disk! "
                    f"SQL: {post['query'][:80]}..."
                )

            # 2. Gate: Tail Latency Skew / Parameter Sniffing
            if cv >= max_allowed_cv and mean_ms >= 5.0:
                violations.append(
                    f"REGRESSION [QueryID {qid}]: High tail variance c_v={cv:.2f} >= {max_allowed_cv}. "
                    f"Mean={mean_ms:.2f}ms, Stddev={post['stddev_exec_time']:.2f}ms."
                )

            # 3. Gate: Cache Hit Ratio
            if chr_ratio < min_chr and total_blks > 500:
                violations.append(
                    f"REGRESSION [QueryID {qid}]: Cache Hit Ratio degraded to {chr_ratio*100:.1f}% < {min_chr*100}%. "
                    f"Disk Reads={delta_read} blocks."
                )

        return violations
```

### 5.3 Rust (`sqlx`): Zero-Overhead Query Telemetry & Differential Diff

```rust
// src/telemetry/pgstat.rs
use sqlx::{PgPool, Row};
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct PgStatRecord {
    pub queryid: i64,
    pub query: String,
    pub calls: i64,
    pub total_exec_time: f64,
    pub mean_exec_time: f64,
    pub stddev_exec_time: f64,
    pub shared_blks_hit: i64,
    pub shared_blks_read: i64,
    pub temp_blks_written: i64,
}

pub struct PgStatAuditor {
    pool: PgPool,
}

impl PgStatAuditor {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn take_snapshot(&self) -> Result<HashMap<i64, PgStatRecord>, sqlx::Error> {
        let rows = sqlx::query(
            r#"
            SELECT
                queryid,
                query,
                calls,
                total_exec_time,
                mean_exec_time,
                stddev_exec_time,
                shared_blks_hit,
                shared_blks_read,
                temp_blks_written
            FROM pg_stat_statements
            WHERE query NOT LIKE '%pg_stat_statements%'
            "#
        )
        .fetch_all(&self.pool)
        .await?;

        let mut map = HashMap::with_capacity(rows.len());
        for row in rows {
            let record = PgStatRecord {
                queryid: row.get("queryid"),
                query: row.get("query"),
                calls: row.get("calls"),
                total_exec_time: row.get("total_exec_time"),
                mean_exec_time: row.get("mean_exec_time"),
                stddev_exec_time: row.get("stddev_exec_time"),
                shared_blks_hit: row.get("shared_blks_hit"),
                shared_blks_read: row.get("shared_blks_read"),
                temp_blks_written: row.get("temp_blks_written"),
            };
            map.insert(record.queryid, record);
        }

        Ok(map)
    }

    pub fn compute_regressions(
        &self,
        before: &HashMap<i64, PgStatRecord>,
        after: &HashMap<i64, PgStatRecord>,
    ) -> Vec<String> {
        let mut alerts = Vec::new();

        for (qid, post) in after {
            let (delta_calls, delta_time, delta_temp, delta_hit, delta_read) = match before.get(qid) {
                Some(pre) => (
                    post.calls - pre.calls,
                    (post.total_exec_time - pre.total_exec_time).max(0.0),
                    post.temp_blks_written - pre.temp_blks_written,
                    post.shared_blks_hit - pre.shared_blks_hit,
                    post.shared_blks_read - pre.shared_blks_read,
                ),
                None => (
                    post.calls,
                    post.total_exec_time,
                    post.temp_blks_written,
                    post.shared_blks_hit,
                    post.shared_blks_read,
                ),
            };

            if delta_calls <= 0 {
                continue;
            }

            let mean_ms = delta_time / (delta_calls as f64);
            let cv = if mean_ms > 0.0 {
                post.stddev_exec_time / mean_ms
            } else {
                0.0
            };

            let total_blks = delta_hit + delta_read;
            let chr = if total_blks > 0 {
                (delta_hit as f64) / (total_blks as f64)
            } else {
                1.0
            };

            if delta_temp > 0 {
                alerts.push(format!(
                    "Query {} spilled {} disk blocks to temp storage!",
                    qid, delta_temp
                ));
            }
            if cv >= 2.0 && mean_ms >= 5.0 {
                alerts.push(format!(
                    "Query {} tail variance c_v={:.2} >= 2.0 (Mean: {:.2}ms, Stddev: {:.2}ms)",
                    qid, cv, mean_ms, post.stddev_exec_time
                ));
            }
            if chr < 0.98 && total_blks > 300 {
                alerts.push(format!(
                    "Query {} CHR dropped to {:.1}% ({} disk reads)",
                    qid, chr * 100.0, delta_read
                ));
            }
        }

        alerts
    }
}
```

---

## 6. Finite-State Machine: Differential Query Audit Lifecycle

Autonomous performance testing and canary verification pipelines must transition through the 6-state auditing FSM:

```
       +---------------------------------------------+
       |           1. EXTENSION_VERIFIED             |
       |  Preload checked & track_io_timing verified |
       +----------------------┬----------------------+
                              │
                              ▼ [captureSnapshot(T1)]
       +---------------------------------------------+
       |           2. SNAPSHOT_T1_CAPTURED           |
       |  Baseline metrics frozen; zero reset called |
       +----------------------┬----------------------+
                              │
                              ▼ [Execute Canary / Load Test / Migration]
       +---------------------------------------------+
       |           3. WORKLOAD_EXECUTED              |
       |  Canary traffic routed; DB executes queries |
       +----------------------┬----------------------+
                              │
                              ▼ [captureSnapshot(T2)]
       +---------------------------------------------+
       |         4. SNAPSHOT_T2_DIFFERENTIAL         |
       |  Compute Delta M = M(T2) - M(T1) & TWIS     |
       +----------------------┬----------------------+
                              │
                              ▼ [Evaluate c_v, CHR, temp_blks]
       +---------------------------------------------+
       |          5. VARIANCE_CHR_ANALYZED           |
       |  Check tail latency skew & disk spillage    |
       +----------------------┬----------------------+
                              │
            ┌─────────────────┴─────────────────┐
            ▼                                   ▼
+-----------------------+           +-----------------------+
| 6A. REGRESSION_ALERT  |           | 6B. BASELINE_CERTIFIED|
| c_v >= 2.0 OR Temp > 0|           | All 6 Gates Passed;   |
| Halt deploy & rollback|           | Proceed with release  |
+-----------------------+           +-----------------------+
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Every database change, canary run, or agentic optimization must satisfy all 6 DoD gates prior to production sign-off:

```
+----------------------------------------------------------------------------------------------------+
|                   6-GATE PG_STAT_STATEMENTS DEFINITION OF DONE (DoD) MATRIX                        |
+---+----------------------------+-------------------------------------+-----------------------------+
| # | Gate Name                  | Verification Mechanism              | Acceptance Criteria         |
+---+----------------------------+-------------------------------------+-----------------------------+
| 1 | Zero-Reset Audit Gate      | AST check & query audit log         | 0 invocations of            |
|   |                            | during verification pipeline        | pg_stat_statements_reset()  |
+---+----------------------------+-------------------------------------+-----------------------------+
| 2 | Timer Instrumentation Gate | SHOW track_io_timing                | Setting == 'on';            |
|   |                            | query check in CI harness           | non-zero I/O clock metrics  |
+---+----------------------------+-------------------------------------+-----------------------------+
| 3 | Parameterized Bind Gate    | pg_stat_statements_info.dealloc     | Dealloc rate < 0.01/s;      |
|   |                            | rate during load test               | no dynamic string literals  |
+---+----------------------------+-------------------------------------+-----------------------------+
| 4 | Buffer Cache Hit Gate      | shared_blks_hit / total_blocks      | CHR >= 98.5% across all     |
|   |                            | on top 20 queries                   | high-frequency OLTP routes  |
+---+----------------------------+-------------------------------------+-----------------------------+
| 5 | Temp Disk Spill Gate       | delta(temp_blks_written)            | TempWrittenBlocks == 0      |
|   |                            | in test transactions                | for all OLTP statements     |
+---+----------------------------+-------------------------------------+-----------------------------+
| 6 | Tail Variance Gate         | Coefficient of Variation            | c_v <= 1.5 (or mitigated by |
|   |                            | c_v = stddev / mean on top queries  | plan_cache_mode custom)     |
+---+----------------------------+-------------------------------------+-----------------------------+
```
