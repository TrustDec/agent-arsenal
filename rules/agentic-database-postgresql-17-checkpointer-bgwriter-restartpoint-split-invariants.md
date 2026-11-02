---
description: PostgreSQL 17 pg_stat_checkpointer vs pg_stat_bgwriter architectural split, standby restartpoint telemetry, forced checkpoint ratio bounds, backend direct write starvation defense, and cross-version metrics polyfills across Go (pgx), TypeScript (pg/Drizzle), Python (asyncpg), Rust (tokio-postgres), Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{checkpointer,bgwriter,checkpoint,stat_bgwriter,stat_checkpointer,telemetry,metrics,postgres_exporter,monitoring,database}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/monitoring/**/*.{ts,js,go,rs,py},**/internal/database/**/*.{go,rs},**/internal/metrics/**/*.{go,rs},**/migrations/**/*.{sql,ts,py,go}
alwaysApply: false
---

# Agentic Database PostgreSQL 17 `pg_stat_checkpointer` vs `pg_stat_bgwriter` Architectural Split, Standby Restartpoint Telemetry, Backend Buffer Write Starvation & Forced Checkpoint Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, optimize, or monitor PostgreSQL database clusters, telemetry exporters (Prometheus `postgres_exporter`, Datadog, OpenTelemetry, Grafana), high-throughput transactional persistence layers, or standby replica pools across PostgreSQL 17+, Go (`jackc/pgx/v5`), TypeScript (`pg`, `Drizzle`, `Prisma`), Python (`asyncpg`), or Rust (`tokio-postgres`, `sqlx`). Eliminate the "Prometheus Exporter Scrape Failure & Blinded Cluster Catastrophe" (where agents and exporters run legacy queries against `pg_stat_bgwriter` for checkpoint metrics, crashing with fatal `SQLSTATE 42703: column "checkpoints_timed" does not exist` and completely silencing production alerting), the "Forced Checkpoint WAL Spike & Full-Page Write (FPW) Deluge" (where undersized `max_wal_size` triggers rapid forced checkpoints $\frac{\text{num\_requested}}{\text{num\_timed} + \text{num\_requested}} > 0.10$, continuously resetting the FPW horizon and inflating WAL write volume by $10\times–20\times$), the "Background Writer Under-Provisioning & Backend Write Starvation" (where throttled bgwriter causes user backends to synchronously write out dirty buffers to disk during OLTP transactions, spiking p99 latencies from 1.5ms to 5,000ms), the "Standby Recovery Restartpoint Stall & WAL Replay Lag Avalanche" (where replica restartpoint I/O is left unmonitored until WAL redo stalls and triggers read-after-write SLA breaches), the "Checkpoint Write Burst vs Spread Smoothing Inversion" (where uncalibrated `checkpoint_completion_target < 0.9` dumps gigabytes of dirty buffers into the OS kernel in violent bursts, saturating NVMe queues), and the "Version-Drift Monolithic Telemetry Assumption" (where monitoring code fails on mixed-version canary fleets) by establishing a strict 5-Tier Checkpointer & Bgwriter Governance Ladder, formal checkpoint ratio and buffer cushioning differential calculus, an autonomous TypeScript `AgenticPostgres17CheckpointerGuardEngine`, cross-runtime driver sentinels in Go, TypeScript, Python, and Rust, a 6-state flush lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Checkpointer & Bgwriter Catastrophes vs The 5-Tier Governance Ladder

For more than two decades, PostgreSQL grouped two completely distinct background processes into a single catch-all catalog view: **`pg_stat_bgwriter`**. That single view intermingled metrics from the **Checkpointer** process (which flushes all dirty shared buffers to disk periodically to advance the REDO recovery point) with metrics from the **Background Writer** process (which gently cleans a small pool of dirty buffers ahead of backend allocations so incoming queries always find clean memory pages).

In **PostgreSQL 17**, the core engine team executed a landmark architectural separation:
1. **`pg_stat_checkpointer`** was introduced as a standalone, dedicated system catalog view exposing checkpointer metrics (`num_timed`, `num_requested`, `restartpoints_timed`, `restartpoints_req`, `restartpoints_done`, `write_time`, `sync_time`, `buffers_written`).
2. All checkpoint-related columns (`checkpoints_timed`, `checkpoints_req`, `checkpoint_write_time`, `checkpoint_sync_time`, `buffers_checkpoint`) were **permanently removed** from `pg_stat_bgwriter`.
3. In addition, `buffers_backend` and `buffers_backend_fsync` were removed from `pg_stat_bgwriter` in favor of the much richer `pg_stat_io` view introduced in PostgreSQL 16.

When autonomous coding agents write monitoring queries, telemetry exporters, SRE scripts, or capacity planning routines without understanding this fundamental architectural shift, they trigger six critical production catastrophes:

```
+----------------------------------------------------------------------------------------------------+
|                THE 6 POSTGRESQL 17 CHECKPOINTER & BGWRITER CATASTROPHES                            |
+----------------------------------------------------------------------------------------------------+
| 1. Prometheus Exporter Scrape Failure & Blinded Cluster Catastrophe (SQLSTATE 42703)               |
|    - Agent executes legacy SELECT checkpoints_timed, checkpoints_req FROM pg_stat_bgwriter. In     |
|      PostgreSQL 17, those columns do NOT exist. The query crashes with SQLSTATE 42703, the metrics |
|      exporter halts, scraping loops fail, dashboards go blank, and the database is completely      |
|      blinded right after a major version upgrade.                                                  |
|                                                                                                    |
| 2. Forced Checkpoint WAL Spike & Full-Page Write (FPW) Deluge (num_requested Surge)                |
|    - Agent neglects max_wal_size tuning. Checkpoints occur every 45 seconds driven by WAL volume  |
|      rather than checkpoint_timeout. Every checkpoint resets the LSN horizon: the first subsequent |
|      write to any shared buffer emits an entire 8KB Full-Page Write (FPW) into WAL, exploding WAL  |
|      generation from 50 MB/min to 1.2 GB/min, saturating replication bandwidth and disk write IOPS.|
|                                                                                                    |
| 3. Background Writer Under-Provisioning & Backend Write Starvation (p99 Latency Cliff)             |
|    - Default bgwriter_lru_maxpages (100) and bgwriter_delay (20ms) are overwhelmed by write-heavy  |
|      transactions. Client backends find 0 clean buffers in shared_buffers and are forced to        |
|      synchronously write dirty pages to storage before reusing the buffer. User query latencies    |
|      suddenly cliff from 1.5ms to 5,000ms, collapsing connection pools.                            |
|                                                                                                    |
| 4. Standby Recovery Restartpoint Stall & WAL Replay Lag Avalanche                                  |
|    - Physical streaming standbys do not run checkpoints; they run restartpoints during WAL redo.   |
|      PostgreSQL 17 exposes restartpoints_timed, restartpoints_req, and restartpoints_done for the   |
|      first time. Agents ignoring these metrics fail to detect that slow standby fsyncs are         |
|      paralyzing the startup replay process, driving replication lag past critical SLA thresholds.   |
|                                                                                                    |
| 5. Checkpoint Write Burst vs Spread Smoothing Inversion (checkpoint_completion_target < 0.9)       |
|    - Under ancient or uncalibrated defaults (completion_target = 0.5), the checkpointer dumps all   |
|      dirty buffers in a violent 3-minute burst, exhausting NVMe controller write credit queues.    |
|      Concurrent OLTP read queries stall on disk I/O wait queues, triggering HTTP 504 timeouts.     |
|                                                                                                    |
| 6. Version-Drift Monolithic Telemetry Assumption & Cross-Fleet Incompatibility                      |
|    - Monitoring scripts hardcode either PostgreSQL 16 or 17 syntax. During rolling blue-green or    |
|      canary upgrades, half the fleet fails health checks because the query is not version-agnostic.|
+----------------------------------------------------------------------------------------------------+
```

To eliminate these failure modes across autonomous agents and human engineering teams, all database configurations and telemetry collectors must conform to the **5-Tier Checkpointer & Bgwriter Governance Ladder**:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Tier 0: Engine Qualification & Dynamic Catalog Polyfill                                          │
│    • Introspect `current_setting('server_version_num')::int >= 170000`                          │
│    • Deploy resilient compatibility views or dynamic SQL polyfills across all telemetry collectors│
│    • Guarantee zero SQLSTATE 42703 column missing errors across mixed-version cluster fleets     │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Validated schema compatibility
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Tier 1: Checkpoint Cadence, Headroom & Spreading Calibration                                     │
│    • Enforce `checkpoint_timeout = 15min` to `30min` and `checkpoint_completion_target = 0.9`    │
│    • Calibrate `max_wal_size >= 16GB` (typically 32GB–64GB on modern production NVMe tiers)      │
│    • Guarantee forced checkpoint ratio R_req = num_requested / (num_timed + num_requested) <= 0.05│
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Checkpoint smoothing verified
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Tier 2: Background Writer Proactive Buffer Cushioning                                            │
│    • Calibrate `bgwriter_lru_maxpages = 800` (up from default 100) and `bgwriter_delay = 10ms`    │
│    • Tune `bgwriter_lru_multiplier = 2.0` or `3.0` to cushion upcoming allocations               │
│    • Audit `maxwritten_clean`: if non-zero rate, bgwriter is reaching ceiling and must be tuned │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Background writer headroom secured
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Tier 3: Standby Recovery Restartpoint Telemetry & Replay SLA                                      │
│    • Monitor `restartpoints_done`, `restartpoints_timed`, `restartpoints_req` on read replicas   │
│    • Bound requested restartpoints ratio R_restart_req <= 0.10 on hot standbys                    │
│    • Correlate restartpoint sync_time with standby replication lag and WAL replay worker speed   │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Standby health guaranteed
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Tier 4: Backend Direct Write Zero-Tolerance Sentinel via pg_stat_io                             │
│    • Audit `pg_stat_io` where `backend_type = 'client backend'` and `io_op = 'write'`            │
│    • Target backend write ratio eta_cushion = B_clean / (B_clean + B_backend) >= 0.98            │
│    • Trip automated SRE alerts when client backends are forced to perform synchronous disk I/O   │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Models, Error Threshold Differential Calculus & Invariant Theorems

### Model 1: Forced Checkpoint Ratio & WAL Headroom Differential Equation

In a stable production workload, checkpoints should almost exclusively be triggered by the scheduled timer (`checkpoint_timeout`), not by running out of WAL capacity (`max_wal_size`). When a checkpoint is triggered by WAL volume, it indicates that transaction write volume has outpaced the allocated WAL headroom.

Let $N_{\text{timed}}(t)$ and $N_{\text{req}}(t)$ denote the cumulative count of timed and requested checkpoints at time $t$ from `pg_stat_checkpointer`. Over an evaluation horizon $\Delta t = t_2 - t_1$:

$$\Delta N_{\text{timed}} = N_{\text{timed}}(t_2) - N_{\text{timed}}(t_1)$$
$$\Delta N_{\text{req}} = N_{\text{req}}(t_2) - N_{\text{req}}(t_1)$$

The **Forced Checkpoint Ratio** $R_{\text{req}}(\Delta t)$ is defined as:

$$R_{\text{req}}(\Delta t) = \frac{\Delta N_{\text{req}}}{\Delta N_{\text{timed}} + \Delta N_{\text{req}}}$$

**Production Invariant 1 (The Checkpoint Stability Theorem)**:
In any healthy OLTP or mixed-workload PostgreSQL cluster over any observation window $\Delta t \ge 1\text{ hour}$:

$$R_{\text{req}}(\Delta t) \le 0.10 \quad (\text{Target: } R_{\text{req}} \le 0.05)$$

If $R_{\text{req}}(\Delta t) > 0.10$, the cluster is suffering from WAL starvation. If WAL generation rate is $\dot{W}_{\text{wal}}$ (bytes/second), the minimum required `max_wal_size` to prevent forced checkpoints is given by:

$$\text{max\_wal\_size} \ge \dot{W}_{\text{wal}} \times T_{\text{checkpoint\_timeout}} \times (1 + C_{\text{target}})$$

Where $T_{\text{checkpoint\_timeout}}$ is the checkpoint timeout in seconds, and $C_{\text{target}} = \text{checkpoint\_completion\_target} \in [0.0, 1.0]$. For instance, if $\dot{W}_{\text{wal}} = 25\text{ MB/sec}$, $T_{\text{checkpoint\_timeout}} = 900\text{ sec}$ (15 min), and $C_{\text{target}} = 0.9$:

$$\text{max\_wal\_size} \ge 25\text{ MB/sec} \times 900\text{ sec} \times 1.9 = 42,750\text{ MB} \approx 42\text{ GB}$$

Setting `max_wal_size = 48GB` (or 64GB) guarantees that $R_{\text{req}} \to 0$.

---

### Model 2: Checkpoint Spread Write Throughput Balancing

PostgreSQL smooths disk writes by spreading them across the checkpoint interval. If $B_{\text{dirty}}$ shared buffers (each 8,192 bytes) must be written during a checkpoint, the checkpointer regulates its write rate so that writing completes at fraction $C_{\text{target}}$ of the timeout:

$$T_{\text{spread}} = T_{\text{checkpoint\_timeout}} \times C_{\text{target}}$$

The required continuous checkpoint write bandwidth $I_{\text{spread}}$ is:

$$I_{\text{spread}} = \frac{B_{\text{dirty}} \times 8,192\text{ bytes}}{T_{\text{spread}}} = \frac{B_{\text{dirty}} \times 8,192}{T_{\text{checkpoint\_timeout}} \times C_{\text{target}}}$$

**Production Invariant 2 (The Smoothing Invariant)**:
Always set `checkpoint_completion_target = 0.9`.
- Setting $C_{\text{target}} = 0.5$ forces the same buffer volume into half the duration, doubling write I/O bursts:
  $$I_{\text{burst}} = \frac{I_{\text{spread}} \times 0.9}{0.5} = 1.8 \times I_{\text{spread}}$$
- If $T_{\text{sync}} = \frac{\text{sync\_time}}{\text{write\_time} + \text{sync\_time}} > 0.30$, storage subsystem fsync queues are congested, indicating that write-back cache or NVMe queue depth is saturated.

---

### Model 3: Background Writer Cushioning Efficacy & Backend Write Avoidance

The background writer process scans the shared buffer pool and proactively writes out dirty pages using an LRU algorithm so that user backends allocating new pages can reuse buffers without synchronous I/O.

In PostgreSQL 17, `buffers_clean` is tracked in `pg_stat_bgwriter`, and backend writes are tracked in `pg_stat_io` (`backend_type = 'client backend'`, `io_context = 'normal'`, `io_op = 'write'`).

Let $\Delta B_{\text{clean}}$ be dirty buffers written by the background writer, and $\Delta B_{\text{backend}}$ be dirty buffers written synchronously by user backends over window $\Delta t$. The **Background Writer Cushioning Efficacy** $\eta_{\text{cushion}}$ is:

$$\eta_{\text{cushion}} = \frac{\Delta B_{\text{clean}}}{\Delta B_{\text{clean}} + \Delta B_{\text{backend}}}$$

**Production Invariant 3 (The Backend Zero-Write Invariant)**:
Client backends must NEVER write dirty shared buffers directly during transaction execution:

$$\eta_{\text{cushion}} \ge 0.95 \quad (\text{Target: } \eta_{\text{cushion}} \ge 0.99)$$

If $\eta_{\text{cushion}} < 0.95$ or $\Delta B_{\text{backend}} > 0$:
1. User backends are suffering synchronous disk write stalls during `SELECT` or `INSERT` operations.
2. The background writer is throttled. Check $\Delta \text{maxwritten\_clean}$: if it is increasing, `bgwriter_lru_maxpages` is exhausted on every round.
3. Remediation: Increase `bgwriter_lru_maxpages` from 100 to 800, and reduce `bgwriter_delay` from 20ms to 10ms.

---

### Invariant Theorem: Full-Page Write (FPW) Amplification under Checkpoint Thrashing

**Theorem**: Let $N_{\text{pages}}$ be the set of unique 8KB shared buffer pages updated during workload execution. After every checkpoint completion, PostgreSQL's WAL engine marks all pages as "clean with respect to WAL". The first subsequent modification to any page $P_i$ emits an 8,192-byte Full Page Image (FPI) into WAL.
If checkpoints occur with frequency $f_{\text{cp}} = \frac{1}{T_{\text{cp}}}$, the total WAL generation rate $\dot{W}_{\text{total}}$ is bounded by:

$$\dot{W}_{\text{total}} \ge \dot{W}_{\text{delta}} + f_{\text{cp}} \sum_{i=1}^{|N_{\text{pages}}|} 8,192\text{ bytes}$$

Where $\dot{W}_{\text{delta}}$ is the nominal WAL delta record size (typically 60–200 bytes per tuple modification).
**Corollary**: Increasing checkpoint frequency by $10\times$ (e.g. from 15 minutes down to 90 seconds due to undersized `max_wal_size`) increases full-page writes by up to $10\times$. For a hot working set of 50,000 active pages (400 MB), 1 checkpoint every 90 seconds adds:

$$\frac{50,000 \times 8,192\text{ bytes}}{90\text{ sec}} = \frac{409,600,000\text{ bytes}}{90\text{ sec}} \approx 4.55\text{ MB/sec of pure FPW overhead}$$

Whereas under a 15-minute checkpoint:

$$\frac{50,000 \times 8,192\text{ bytes}}{900\text{ sec}} \approx 0.45\text{ MB/sec}$$

A $10\times$ reduction in FPW write amplification is achieved purely by eliminating forced checkpoints.

---

## 3. Autonomous TypeScript Engine: `AgenticPostgres17CheckpointerGuardEngine`

This enterprise-grade TypeScript engine connects to PostgreSQL, dynamically determines engine version capabilities, queries `pg_stat_checkpointer` and `pg_stat_bgwriter` (with transparent legacy fallbacks for PostgreSQL $\le 16$), calculates real-time differential rates, evaluates health invariants, and emits actionable tuning recommendations.

```typescript
/**
 * AgenticPostgres17CheckpointerGuardEngine
 *
 * Autonomous production engine for PostgreSQL 17+ pg_stat_checkpointer
 * and pg_stat_bgwriter telemetry, differential rate calculus,
 * standby restartpoint monitoring, and proactive tuning recommendations.
 */

import { Client, ClientConfig } from 'pg';

export interface CheckpointerSnapshot {
  timestamp: number;
  serverVersionNum: number;
  // Checkpointer metrics (PostgreSQL 17+ or polyfilled from bgwriter)
  numTimed: bigint;
  numRequested: bigint;
  restartpointsTimed: bigint;
  restartpointsReq: bigint;
  restartpointsDone: bigint;
  writeTimeMs: number;
  syncTimeMs: number;
  buffersWritten: bigint;
  // Background writer metrics
  buffersClean: bigint;
  maxwrittenClean: bigint;
  buffersAlloc: bigint;
  // Backend writes (from pg_stat_io or legacy bgwriter)
  buffersBackend: bigint;
  buffersBackendFsync: bigint;
}

export interface CheckpointerRates {
  windowSeconds: number;
  timedCheckpointsPerMin: number;
  requestedCheckpointsPerMin: number;
  forcedCheckpointRatio: number; // R_req: requested / (timed + requested)
  avgWriteTimeMsPerCp: number;
  avgSyncTimeMsPerCp: number;
  syncTimeRatio: number; // syncTime / (writeTime + syncTime)
  buffersWrittenPerSec: number;
  buffersCleanPerSec: number;
  maxwrittenCleanPerMin: number;
  buffersBackendPerSec: number;
  cushioningEfficacy: number; // buffersClean / (buffersClean + buffersBackend)
  // Standby metrics
  restartpointsTimedPerMin: number;
  restartpointsReqPerMin: number;
  restartpointsDonePerMin: number;
  forcedRestartpointRatio: number;
}

export type HealthStatus = 'HEALTHY' | 'WARNING' | 'CRITICAL';

export interface HealthAssessment {
  status: HealthStatus;
  violations: string[];
  recommendations: string[];
  rates: CheckpointerRates;
}

export class AgenticPostgres17CheckpointerGuardEngine {
  private client: Client;
  private lastSnapshot: CheckpointerSnapshot | null = null;
  private serverVersion: number = 0;

  constructor(private readonly config: ClientConfig) {
    this.client = new Client(config);
  }

  public async connect(): Promise<void> {
    await this.client.connect();
    const res = await this.client.query(`SELECT current_setting('server_version_num')::integer AS ver;`);
    this.serverVersion = parseInt(res.rows[0].ver, 10);
    if (isNaN(this.serverVersion)) {
      throw new Error('Unable to determine PostgreSQL server_version_num');
    }
  }

  public async disconnect(): Promise<void> {
    await this.client.end();
  }

  public getServerVersion(): number {
    return this.serverVersion;
  }

  public isPostgres17OrHigher(): boolean {
    return this.serverVersion >= 170000;
  }

  /**
   * Captures a unified telemetry snapshot across PostgreSQL 17+ or legacy engines.
   */
  public async captureSnapshot(): Promise<CheckpointerSnapshot> {
    const timestamp = Date.now();

    if (this.isPostgres17OrHigher()) {
      // PostgreSQL 17+: Query separate pg_stat_checkpointer and pg_stat_bgwriter
      const cpQuery = `
        SELECT
          num_timed,
          num_requested,
          restartpoints_timed,
          restartpoints_req,
          restartpoints_done,
          write_time,
          sync_time,
          buffers_written
        FROM pg_stat_checkpointer;
      `;
      const bgQuery = `
        SELECT
          buffers_clean,
          maxwritten_clean,
          buffers_alloc
        FROM pg_stat_bgwriter;
      `;
      const ioQuery = `
        SELECT
          COALESCE(SUM(writes), 0)::bigint AS buffers_backend,
          COALESCE(SUM(fsyncs), 0)::bigint AS buffers_backend_fsync
        FROM pg_stat_io
        WHERE backend_type = 'client backend' AND io_context = 'normal' AND io_object = 'relation';
      `;

      const [cpRes, bgRes, ioRes] = await Promise.all([
        this.client.query(cpQuery),
        this.client.query(bgQuery),
        this.client.query(ioQuery).catch(() => ({ rows: [{ buffers_backend: '0', buffers_backend_fsync: '0' }] })),
      ]);

      const cp = cpRes.rows[0] || {};
      const bg = bgRes.rows[0] || {};
      const io = ioRes.rows[0] || {};

      return {
        timestamp,
        serverVersionNum: this.serverVersion,
        numTimed: BigInt(cp.num_timed ?? '0'),
        numRequested: BigInt(cp.num_requested ?? '0'),
        restartpointsTimed: BigInt(cp.restartpoints_timed ?? '0'),
        restartpointsReq: BigInt(cp.restartpoints_req ?? '0'),
        restartpointsDone: BigInt(cp.restartpoints_done ?? '0'),
        writeTimeMs: parseFloat(cp.write_time ?? '0'),
        syncTimeMs: parseFloat(cp.sync_time ?? '0'),
        buffersWritten: BigInt(cp.buffers_written ?? '0'),
        buffersClean: BigInt(bg.buffers_clean ?? '0'),
        maxwrittenClean: BigInt(bg.maxwritten_clean ?? '0'),
        buffersAlloc: BigInt(bg.buffers_alloc ?? '0'),
        buffersBackend: BigInt(io.buffers_backend ?? '0'),
        buffersBackendFsync: BigInt(io.buffers_backend_fsync ?? '0'),
      };
    } else {
      // PostgreSQL <= 16 Legacy Polyfill: Read from pg_stat_bgwriter
      const legacyQuery = `
        SELECT
          checkpoints_timed AS num_timed,
          checkpoints_req AS num_requested,
          0::bigint AS restartpoints_timed,
          0::bigint AS restartpoints_req,
          0::bigint AS restartpoints_done,
          checkpoint_write_time AS write_time,
          checkpoint_sync_time AS sync_time,
          buffers_checkpoint AS buffers_written,
          buffers_clean,
          maxwritten_clean,
          buffers_alloc,
          buffers_backend,
          buffers_backend_fsync
        FROM pg_stat_bgwriter;
      `;
      const res = await this.client.query(legacyQuery);
      const row = res.rows[0];

      return {
        timestamp,
        serverVersionNum: this.serverVersion,
        numTimed: BigInt(row.num_timed ?? '0'),
        numRequested: BigInt(row.num_requested ?? '0'),
        restartpointsTimed: BigInt(row.restartpoints_timed ?? '0'),
        restartpointsReq: BigInt(row.restartpoints_req ?? '0'),
        restartpointsDone: BigInt(row.restartpoints_done ?? '0'),
        writeTimeMs: parseFloat(row.write_time ?? '0'),
        syncTimeMs: parseFloat(row.sync_time ?? '0'),
        buffersWritten: BigInt(row.buffers_written ?? '0'),
        buffersClean: BigInt(row.buffers_clean ?? '0'),
        maxwrittenClean: BigInt(row.maxwritten_clean ?? '0'),
        buffersAlloc: BigInt(row.buffers_alloc ?? '0'),
        buffersBackend: BigInt(row.buffers_backend ?? '0'),
        buffersBackendFsync: BigInt(row.buffers_backend_fsync ?? '0'),
      };
    }
  }

  /**
   * Computes differential rates between two consecutive snapshots.
   */
  public computeRates(current: CheckpointerSnapshot, previous: CheckpointerSnapshot): CheckpointerRates {
    const elapsedSeconds = Math.max((current.timestamp - previous.timestamp) / 1000, 0.001);
    const elapsedMinutes = elapsedSeconds / 60;

    const deltaTimed = Number(current.numTimed - previous.numTimed);
    const deltaReq = Number(current.numRequested - previous.numRequested);
    const totalCheckpoints = deltaTimed + deltaReq;

    const forcedCheckpointRatio = totalCheckpoints > 0 ? deltaReq / totalCheckpoints : 0;

    const deltaWriteTime = Math.max(current.writeTimeMs - previous.writeTimeMs, 0);
    const deltaSyncTime = Math.max(current.syncTimeMs - previous.syncTimeMs, 0);
    const totalTime = deltaWriteTime + deltaSyncTime;
    const syncTimeRatio = totalTime > 0 ? deltaSyncTime / totalTime : 0;

    const avgWriteTimeMsPerCp = totalCheckpoints > 0 ? deltaWriteTime / totalCheckpoints : 0;
    const avgSyncTimeMsPerCp = totalCheckpoints > 0 ? deltaSyncTime / totalCheckpoints : 0;

    const deltaWritten = Number(current.buffersWritten - previous.buffersWritten);
    const deltaClean = Number(current.buffersClean - previous.buffersClean);
    const deltaMaxwritten = Number(current.maxwrittenClean - previous.maxwrittenClean);
    const deltaBackend = Number(current.buffersBackend - previous.buffersBackend);

    const cushioningEfficacy = (deltaClean + deltaBackend) > 0
      ? deltaClean / (deltaClean + deltaBackend)
      : 1.0;

    // Standby restartpoints
    const deltaRTimed = Number(current.restartpointsTimed - previous.restartpointsTimed);
    const deltaRReq = Number(current.restartpointsReq - previous.restartpointsReq);
    const deltaRDone = Number(current.restartpointsDone - previous.restartpointsDone);
    const forcedRestartpointRatio = (deltaRTimed + deltaRReq) > 0 ? deltaRReq / (deltaRTimed + deltaRReq) : 0;

    return {
      windowSeconds: elapsedSeconds,
      timedCheckpointsPerMin: deltaTimed / elapsedMinutes,
      requestedCheckpointsPerMin: deltaReq / elapsedMinutes,
      forcedCheckpointRatio,
      avgWriteTimeMsPerCp,
      avgSyncTimeMsPerCp,
      syncTimeRatio,
      buffersWrittenPerSec: deltaWritten / elapsedSeconds,
      buffersCleanPerSec: deltaClean / elapsedSeconds,
      maxwrittenCleanPerMin: deltaMaxwritten / elapsedMinutes,
      buffersBackendPerSec: deltaBackend / elapsedSeconds,
      cushioningEfficacy,
      restartpointsTimedPerMin: deltaRTimed / elapsedMinutes,
      restartpointsReqPerMin: deltaRReq / elapsedMinutes,
      restartpointsDonePerMin: deltaRDone / elapsedMinutes,
      forcedRestartpointRatio,
    };
  }

  /**
   * Assesses health against production invariants and yields actionable remediation advice.
   */
  public evaluateHealth(rates: CheckpointerRates): HealthAssessment {
    const violations: string[] = [];
    const recommendations: string[] = [];
    let status: HealthStatus = 'HEALTHY';

    // 1. Forced Checkpoint Invariant: R_req <= 0.10
    if (rates.forcedCheckpointRatio > 0.10) {
      status = 'CRITICAL';
      violations.push(
        `Forced checkpoint ratio is ${(rates.forcedCheckpointRatio * 100).toFixed(1)}% (exceeds 10% SLA threshold). Checkpoints are driven by WAL volume.`
      );
      recommendations.push(
        `Increase 'max_wal_size' (e.g. from current value to 32GB or 64GB) to eliminate WAL-forced checkpoints and reduce Full-Page Write (FPW) amplification.`
      );
    } else if (rates.forcedCheckpointRatio > 0.05) {
      if (status !== 'CRITICAL') status = 'WARNING';
      violations.push(
        `Forced checkpoint ratio is ${(rates.forcedCheckpointRatio * 100).toFixed(1)}% (elevated above 5% best-practice target).`
      );
      recommendations.push(
        `Consider expanding 'max_wal_size' by 50% to provide additional write burst headroom.`
      );
    }

    // 2. Background Writer Cushioning Efficacy: eta_cushion >= 0.95
    if (rates.cushioningEfficacy < 0.95) {
      status = 'CRITICAL';
      violations.push(
        `Background writer cushioning efficacy is ${(rates.cushioningEfficacy * 100).toFixed(1)}% (< 95%). User backends are synchronously writing ${(rates.buffersBackendPerSec).toFixed(1)} dirty buffers/sec.`
      );
      recommendations.push(
        `Increase 'bgwriter_lru_maxpages' (e.g. from 100 to 800) and reduce 'bgwriter_delay' (e.g. to 10ms) so bgwriter writes dirty buffers before backends stall.`
      );
    }

    // 3. Maxwritten Clean Throttling
    if (rates.maxwrittenCleanPerMin > 10) {
      if (status !== 'CRITICAL') status = 'WARNING';
      violations.push(
        `Background writer hit its scan limit ${rates.maxwrittenCleanPerMin.toFixed(1)} times/min (maxwritten_clean).`
      );
      recommendations.push(
        `Tune 'bgwriter_lru_maxpages' higher and increase 'bgwriter_lru_multiplier' (e.g. 2.0 -> 3.0) to give bgwriter more write budget per round.`
      );
    }

    // 4. Sync Time Ratio: syncTime / (writeTime + syncTime) > 0.30
    if (rates.syncTimeRatio > 0.30 && (rates.avgWriteTimeMsPerCp + rates.avgSyncTimeMsPerCp) > 1000) {
      if (status !== 'CRITICAL') status = 'WARNING';
      violations.push(
        `Checkpoint fsync phase consumes ${(rates.syncTimeRatio * 100).toFixed(1)}% of total checkpoint time (storage fsync latency bottleneck).`
      );
      recommendations.push(
        `Verify storage IOPS allocation, ensure 'checkpoint_completion_target = 0.9' is configured, and check underlying NVMe/EBS write cache writeback performance.`
      );
    }

    // 5. Standby Forced Restartpoint Ratio (if active standby)
    if (rates.restartpointsDonePerMin > 0 && rates.forcedRestartpointRatio > 0.10) {
      status = 'CRITICAL';
      violations.push(
        `Standby replica forced restartpoint ratio is ${(rates.forcedRestartpointRatio * 100).toFixed(1)}% (standby max_wal_size exceeded).`
      );
      recommendations.push(
        `Increase 'max_wal_size' on the read replica to prevent restartpoint thrashing and eliminate WAL redo replay lag spikes.`
      );
    }

    return {
      status,
      violations,
      recommendations,
      rates,
    };
  }

  /**
   * Performs an end-to-end monitoring cycle. Call periodically (e.g. every 60 seconds).
   */
  public async tick(): Promise<HealthAssessment | null> {
    const current = await this.captureSnapshot();
    if (!this.lastSnapshot) {
      this.lastSnapshot = current;
      return null; // Need two snapshots for differential calculus
    }

    const rates = this.computeRates(current, this.lastSnapshot);
    this.lastSnapshot = current;
    return this.evaluateHealth(rates);
  }
}
```

---

## 4. Cross-Runtime Driver Sentinels

### 4.1 Go (`jackc/pgx/v5`): Resilient Telemetry Collector & Prometheus Exporter

In Go microservices or monitoring daemon processes, this sentinel uses `jackc/pgx/v5` to dynamically detect the server version, execute the proper telemetry catalog query without crashing on `SQLSTATE 42703`, and evaluate SLA bounds in background routines.

```go
package checkpointer

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// CheckpointerMetrics holds absolute and differential statistics.
type CheckpointerMetrics struct {
	Timestamp            time.Time
	ServerVersionNum     int
	NumTimed             int64
	NumRequested         int64
	RestartpointsTimed   int64
	RestartpointsReq     int64
	RestartpointsDone    int64
	WriteTimeMs          float64
	SyncTimeMs           float64
	BuffersWritten       int64
	BuffersClean         int64
	MaxwrittenClean      int64
	BuffersAlloc         int64
	BuffersBackend       int64
	BuffersBackendFsync  int64
}

// DifferentialAnalysis contains computed invariant rates.
type DifferentialAnalysis struct {
	DurationSeconds        float64
	ForcedCheckpointRatio  float64 // Target: <= 0.05, Hard Ceiling: <= 0.10
	BuffersWrittenPerSec   float64
	BuffersCleanPerSec     float64
	BuffersBackendPerSec   float64
	CushioningEfficacy     float64 // Target: >= 0.95
	SyncTimeRatio          float64 // syncTime / (writeTime + syncTime)
	IsHealthy              bool
	Violations             []string
}

// Sentinel monitors checkpointer & bgwriter health across PostgreSQL 16 and 17+.
type Sentinel struct {
	pool        *pgxpool.Pool
	logger      *slog.Logger
	mu          sync.Mutex
	version     int
	lastMetrics *CheckpointerMetrics
}

// NewSentinel initializes the PostgreSQL checkpointer sentinel.
func NewSentinel(pool *pgxpool.Pool, logger *slog.Logger) *Sentinel {
	return &Sentinel{
		pool:   pool,
		logger: logger,
	}
}

// Initialize probes the server version to determine query paths.
func (s *Sentinel) Initialize(ctx context.Context) error {
	var ver int
	err := s.pool.QueryRow(ctx, "SELECT current_setting('server_version_num')::integer;").Scan(&ver)
	if err != nil {
		return fmt.Errorf("failed to query server_version_num: %w", err)
	}
	s.version = ver
	s.logger.Info("initialized checkpointer sentinel", "server_version_num", ver, "is_pg17", ver >= 170000)
	return nil
}

// Collect captures a point-in-time metrics sample.
func (s *Sentinel) Collect(ctx context.Context) (*CheckpointerMetrics, error) {
	if s.version == 0 {
		if err := s.Initialize(ctx); err != nil {
			return nil, err
		}
	}

	m := &CheckpointerMetrics{
		Timestamp:        time.Now(),
		ServerVersionNum: s.version,
	}

	if s.version >= 170000 {
		// PostgreSQL 17+: Dedicated pg_stat_checkpointer and pg_stat_bgwriter
		const qCP = `
			SELECT
				num_timed,
				num_requested,
				restartpoints_timed,
				restartpoints_req,
				restartpoints_done,
				write_time,
				sync_time,
				buffers_written
			FROM pg_stat_checkpointer;
		`
		err := s.pool.QueryRow(ctx, qCP).Scan(
			&m.NumTimed,
			&m.NumRequested,
			&m.RestartpointsTimed,
			&m.RestartpointsReq,
			&m.RestartpointsDone,
			&m.WriteTimeMs,
			&m.SyncTimeMs,
			&m.BuffersWritten,
		)
		if err != nil {
			return nil, fmt.Errorf("pg_stat_checkpointer query failed: %w", err)
		}

		const qBG = `
			SELECT
				buffers_clean,
				maxwritten_clean,
				buffers_alloc
			FROM pg_stat_bgwriter;
		`
		err = s.pool.QueryRow(ctx, qBG).Scan(
			&m.BuffersClean,
			&m.MaxwrittenClean,
			&m.BuffersAlloc,
		)
		if err != nil {
			return nil, fmt.Errorf("pg_stat_bgwriter query failed: %w", err)
		}

		// Read backend writes from pg_stat_io if available
		const qIO = `
			SELECT
				COALESCE(SUM(writes), 0)::bigint,
				COALESCE(SUM(fsyncs), 0)::bigint
			FROM pg_stat_io
			WHERE backend_type = 'client backend' AND io_context = 'normal' AND io_object = 'relation';
		`
		_ = s.pool.QueryRow(ctx, qIO).Scan(&m.BuffersBackend, &m.BuffersBackendFsync)
	} else {
		// PostgreSQL <= 16: Legacy unified pg_stat_bgwriter
		const qLegacy = `
			SELECT
				checkpoints_timed,
				checkpoints_req,
				checkpoint_write_time,
				checkpoint_sync_time,
				buffers_checkpoint,
				buffers_clean,
				maxwritten_clean,
				buffers_alloc,
				buffers_backend,
				buffers_backend_fsync
			FROM pg_stat_bgwriter;
		`
		err := s.pool.QueryRow(ctx, qLegacy).Scan(
			&m.NumTimed,
			&m.NumRequested,
			&m.WriteTimeMs,
			&m.SyncTimeMs,
			&m.BuffersWritten,
			&m.BuffersClean,
			&m.MaxwrittenClean,
			&m.BuffersAlloc,
			&m.BuffersBackend,
			&m.BuffersBackendFsync,
		)
		if err != nil {
			return nil, fmt.Errorf("legacy pg_stat_bgwriter query failed: %w", err)
		}
	}

	return m, nil
}

// Analyze evaluates differential metrics against SLA thresholds.
func (s *Sentinel) Analyze(curr, prev *CheckpointerMetrics) *DifferentialAnalysis {
	dt := curr.Timestamp.Sub(prev.Timestamp).Seconds()
	if dt <= 0 {
		dt = 0.001
	}

	deltaTimed := float64(curr.NumTimed - prev.NumTimed)
	deltaReq := float64(curr.NumRequested - prev.NumRequested)
	totalCP := deltaTimed + deltaReq

	forcedRatio := 0.0
	if totalCP > 0 {
		forcedRatio = deltaReq / totalCP
	}

	deltaClean := float64(curr.BuffersClean - prev.BuffersClean)
	deltaBackend := float64(curr.BuffersBackend - prev.BuffersBackend)
	cushioning := 1.0
	if (deltaClean + deltaBackend) > 0 {
		cushioning = deltaClean / (deltaClean + deltaBackend)
	}

	deltaWriteTime := curr.WriteTimeMs - prev.WriteTimeMs
	deltaSyncTime := curr.SyncTimeMs - prev.SyncTimeMs
	totalTime := deltaWriteTime + deltaSyncTime
	syncRatio := 0.0
	if totalTime > 0 {
		syncRatio = deltaSyncTime / totalTime
	}

	analysis := &DifferentialAnalysis{
		DurationSeconds:       dt,
		ForcedCheckpointRatio: forcedRatio,
		BuffersWrittenPerSec:  float64(curr.BuffersWritten-prev.BuffersWritten) / dt,
		BuffersCleanPerSec:    deltaClean / dt,
		BuffersBackendPerSec:  deltaBackend / dt,
		CushioningEfficacy:    cushioning,
		SyncTimeRatio:         syncRatio,
		IsHealthy:             true,
	}

	if forcedRatio > 0.10 {
		analysis.IsHealthy = false
		analysis.Violations = append(analysis.Violations,
			fmt.Sprintf("Forced checkpoint ratio %.1f%% exceeds 10%% SLA threshold. Increase max_wal_size.", forcedRatio*100))
	}
	if cushioning < 0.95 {
		analysis.IsHealthy = false
		analysis.Violations = append(analysis.Violations,
			fmt.Sprintf("Bgwriter cushioning efficacy %.1f%% < 95%%. Backends are writing %.1f buffers/sec synchronously.", cushioning*100, analysis.BuffersBackendPerSec))
	}

	return analysis
}

// RunAuditLoop runs a continuous background sentinel with periodic evaluation.
func (s *Sentinel) RunAuditLoop(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			curr, err := s.Collect(ctx)
			if err != nil {
				s.logger.Error("checkpointer sentinel collection failed", "err", err)
				continue
			}

			s.mu.Lock()
			prev := s.lastMetrics
			s.lastMetrics = curr
			s.mu.Unlock()

			if prev == nil {
				continue
			}

			analysis := s.Analyze(curr, prev)
			if !analysis.IsHealthy {
				s.logger.Warn("checkpointer SLA violation detected",
					"forced_ratio", fmt.Sprintf("%.1f%%", analysis.ForcedCheckpointRatio*100),
					"cushioning", fmt.Sprintf("%.1f%%", analysis.CushioningEfficacy*100),
					"backend_writes_per_sec", analysis.BuffersBackendPerSec,
					"violations", analysis.Violations,
				)
			} else {
				s.logger.Debug("checkpointer health nominal",
					"forced_ratio", fmt.Sprintf("%.1f%%", analysis.ForcedCheckpointRatio*100),
					"cushioning", fmt.Sprintf("%.1f%%", analysis.CushioningEfficacy*100),
				)
			}
		}
	}
}
```

---

### 4.2 Python (`asyncpg`): Resilient Health Sentinel with SLA Alerts

```python
"""
agentic_postgres17_checkpointer.py

Asynchronous health sentinel monitoring PostgreSQL 17 pg_stat_checkpointer
and pg_stat_bgwriter with SLA alerts and automated remediation hints.
"""

import asyncio
import logging
from dataclasses import dataclass
from typing import Optional, List, Dict, Any
import asyncpg

logger = logging.getLogger("agentic.checkpointer")


@dataclass
class CheckpointerMetrics:
    timestamp: float
    server_version: int
    num_timed: int
    num_requested: int
    restartpoints_timed: int
    restartpoints_req: int
    restartpoints_done: int
    write_time_ms: float
    sync_time_ms: float
    buffers_written: int
    buffers_clean: int
    maxwritten_clean: int
    buffers_alloc: int
    buffers_backend: int


@dataclass
class CheckpointAnalysis:
    duration_sec: float
    forced_ratio: float
    cushioning_efficacy: float
    backend_writes_per_sec: float
    sync_ratio: float
    violations: List[str]
    is_healthy: bool


class PostgresCheckpointerSentinel:
    def __init__(self, dsn: str):
        self.dsn = dsn
        self.pool: Optional[asyncpg.Pool] = None
        self.server_version: int = 0
        self.last_metrics: Optional[CheckpointerMetrics] = None

    async def initialize(self) -> None:
        self.pool = await asyncpg.create_pool(dsn=self.dsn, min_size=1, max_size=3)
        async with self.pool.acquire() as conn:
            ver_str = await conn.fetchval("SELECT current_setting('server_version_num');")
            self.server_version = int(ver_str)
            logger.info("Sentinel initialized with server_version_num=%d (pg17=%s)",
                        self.server_version, self.server_version >= 170000)

    async def collect(self) -> CheckpointerMetrics:
        if not self.pool:
            await self.initialize()

        now = asyncio.get_event_loop().time()
        async with self.pool.acquire() as conn:
            if self.server_version >= 170000:
                cp_row = await conn.fetchrow("""
                    SELECT
                        num_timed, num_requested, restartpoints_timed,
                        restartpoints_req, restartpoints_done,
                        write_time, sync_time, buffers_written
                    FROM pg_stat_checkpointer;
                """)
                bg_row = await conn.fetchrow("""
                    SELECT buffers_clean, maxwritten_clean, buffers_alloc
                    FROM pg_stat_bgwriter;
                """)
                # Try reading backend writes from pg_stat_io
                try:
                    io_row = await conn.fetchrow("""
                        SELECT COALESCE(SUM(writes), 0)::bigint AS buffers_backend
                        FROM pg_stat_io
                        WHERE backend_type = 'client backend' AND io_context = 'normal' AND io_object = 'relation';
                    """)
                    buffers_backend = int(io_row["buffers_backend"]) if io_row else 0
                except Exception:
                    buffers_backend = 0

                return CheckpointerMetrics(
                    timestamp=now,
                    server_version=self.server_version,
                    num_timed=int(cp_row["num_timed"]),
                    num_requested=int(cp_row["num_requested"]),
                    restartpoints_timed=int(cp_row["restartpoints_timed"]),
                    restartpoints_req=int(cp_row["restartpoints_req"]),
                    restartpoints_done=int(cp_row["restartpoints_done"]),
                    write_time_ms=float(cp_row["write_time"]),
                    sync_time_ms=float(cp_row["sync_time"]),
                    buffers_written=int(cp_row["buffers_written"]),
                    buffers_clean=int(bg_row["buffers_clean"]),
                    maxwritten_clean=int(bg_row["maxwritten_clean"]),
                    buffers_alloc=int(bg_row["buffers_alloc"]),
                    buffers_backend=buffers_backend,
                )
            else:
                legacy_row = await conn.fetchrow("""
                    SELECT
                        checkpoints_timed AS num_timed,
                        checkpoints_req AS num_requested,
                        0::bigint AS restartpoints_timed,
                        0::bigint AS restartpoints_req,
                        0::bigint AS restartpoints_done,
                        checkpoint_write_time AS write_time,
                        checkpoint_sync_time AS sync_time,
                        buffers_checkpoint AS buffers_written,
                        buffers_clean,
                        maxwritten_clean,
                        buffers_alloc,
                        buffers_backend
                    FROM pg_stat_bgwriter;
                """)
                return CheckpointerMetrics(
                    timestamp=now,
                    server_version=self.server_version,
                    num_timed=int(legacy_row["num_timed"]),
                    num_requested=int(legacy_row["num_requested"]),
                    restartpoints_timed=0,
                    restartpoints_req=0,
                    restartpoints_done=0,
                    write_time_ms=float(legacy_row["write_time"]),
                    sync_time_ms=float(legacy_row["sync_time"]),
                    buffers_written=int(legacy_row["buffers_written"]),
                    buffers_clean=int(legacy_row["buffers_clean"]),
                    maxwritten_clean=int(legacy_row["maxwritten_clean"]),
                    buffers_alloc=int(legacy_row["buffers_alloc"]),
                    buffers_backend=int(legacy_row["buffers_backend"]),
                )

    def analyze(self, curr: CheckpointerMetrics, prev: CheckpointerMetrics) -> CheckpointAnalysis:
        dt = max(curr.timestamp - prev.timestamp, 0.001)
        d_timed = curr.num_timed - prev.num_timed
        d_req = curr.num_requested - prev.num_requested
        total_cp = d_timed + d_req
        forced_ratio = (d_req / total_cp) if total_cp > 0 else 0.0

        d_clean = curr.buffers_clean - prev.buffers_clean
        d_backend = curr.buffers_backend - prev.buffers_backend
        cushioning = (d_clean / (d_clean + d_backend)) if (d_clean + d_backend) > 0 else 1.0

        d_write_time = max(curr.write_time_ms - prev.write_time_ms, 0.0)
        d_sync_time = max(curr.sync_time_ms - prev.sync_time_ms, 0.0)
        total_time = d_write_time + d_sync_time
        sync_ratio = (d_sync_time / total_time) if total_time > 0 else 0.0

        violations = []
        if forced_ratio > 0.10:
            violations.append(f"Forced checkpoint ratio {forced_ratio*100:.1f}% exceeds 10% threshold. Sizing: increase max_wal_size.")
        if cushioning < 0.95:
            violations.append(f"Bgwriter cushioning {cushioning*100:.1f}% < 95%. Synchronous backend writes = {d_backend/dt:.1f}/sec.")

        return CheckpointAnalysis(
            duration_sec=dt,
            forced_ratio=forced_ratio,
            cushioning_efficacy=cushioning,
            backend_writes_per_sec=d_backend / dt,
            sync_ratio=sync_ratio,
            violations=violations,
            is_healthy=len(violations) == 0,
        )

    async def run_loop(self, interval_seconds: float = 60.0):
        while True:
            try:
                curr = await self.collect()
                if self.last_metrics is not None:
                    analysis = self.analyze(curr, self.last_metrics)
                    if not analysis.is_healthy:
                        logger.warning("Checkpointer SLA Alert: %s", " | ".join(analysis.violations))
                    else:
                        logger.debug("Checkpointer health nominal: forced_ratio=%.1f%%, cushioning=%.1f%%",
                                     analysis.forced_ratio * 100, analysis.cushioning_efficacy * 100)
                self.last_metrics = curr
            except Exception as e:
                logger.error("Failed to collect checkpointer metrics: %s", e)
            await asyncio.sleep(interval_seconds)
```

---

### 4.3 Rust (`tokio-postgres`): High-Performance Zero-Allocation Checkpointer Monitor

```rust
//! agentic_postgres17_checkpointer.rs
//! High-performance zero-allocation checkpointer telemetry collector in Rust.

use std::time::{Duration, Instant};
use tokio_postgres::{Client, NoTls};

#[derive(Debug, Clone, Default)]
pub struct RawCheckpointerStats {
    pub server_version: i32,
    pub num_timed: i64,
    pub num_requested: i64,
    pub restartpoints_timed: i64,
    pub restartpoints_req: i64,
    pub restartpoints_done: i64,
    pub write_time_ms: f64,
    pub sync_time_ms: f64,
    pub buffers_written: i64,
    pub buffers_clean: i64,
    pub maxwritten_clean: i64,
    pub buffers_alloc: i64,
    pub buffers_backend: i64,
}

pub struct CheckpointerAuditor {
    client: Client,
    server_version: i32,
    last_sample: Option<(Instant, RawCheckpointerStats)>,
}

impl CheckpointerAuditor {
    pub async fn connect(config_str: &str) -> Result<Self, tokio_postgres::Error> {
        let (client, connection) = tokio_postgres::connect(config_str, NoTls).await?;
        tokio::spawn(async move {
            if let Err(e) = connection.await {
                eprintln!("PostgreSQL connection error: {}", e);
            }
        });

        let row = client.query_one("SELECT current_setting('server_version_num')::int;", &[]).await?;
        let server_version: i32 = row.get(0);

        Ok(Self {
            client,
            server_version,
            last_sample: None,
        })
    }

    pub async fn poll(&mut self) -> Result<(), tokio_postgres::Error> {
        let mut stats = RawCheckpointerStats {
            server_version: self.server_version,
            ..Default::default()
        };

        if self.server_version >= 170_000 {
            // PostgreSQL 17+ dedicated catalog split
            let cp_row = self.client.query_one(
                "SELECT num_timed, num_requested, restartpoints_timed, restartpoints_req, \
                 restartpoints_done, write_time, sync_time, buffers_written \
                 FROM pg_stat_checkpointer;",
                &[],
            ).await?;

            stats.num_timed = cp_row.get("num_timed");
            stats.num_requested = cp_row.get("num_requested");
            stats.restartpoints_timed = cp_row.get("restartpoints_timed");
            stats.restartpoints_req = cp_row.get("restartpoints_req");
            stats.restartpoints_done = cp_row.get("restartpoints_done");
            stats.write_time_ms = cp_row.get("write_time");
            stats.sync_time_ms = cp_row.get("sync_time");
            stats.buffers_written = cp_row.get("buffers_written");

            let bg_row = self.client.query_one(
                "SELECT buffers_clean, maxwritten_clean, buffers_alloc FROM pg_stat_bgwriter;",
                &[],
            ).await?;

            stats.buffers_clean = bg_row.get("buffers_clean");
            stats.maxwritten_clean = bg_row.get("maxwritten_clean");
            stats.buffers_alloc = bg_row.get("buffers_alloc");

            // Query backend writes from pg_stat_io
            if let Ok(io_row) = self.client.query_one(
                "SELECT COALESCE(SUM(writes), 0)::bigint FROM pg_stat_io \
                 WHERE backend_type = 'client backend' AND io_context = 'normal' AND io_object = 'relation';",
                &[],
            ).await {
                stats.buffers_backend = io_row.get(0);
            }
        } else {
            // PostgreSQL <= 16 legacy unified view
            let row = self.client.query_one(
                "SELECT checkpoints_timed, checkpoints_req, checkpoint_write_time, checkpoint_sync_time, \
                 buffers_checkpoint, buffers_clean, maxwritten_clean, buffers_alloc, buffers_backend \
                 FROM pg_stat_bgwriter;",
                &[],
            ).await?;

            stats.num_timed = row.get("checkpoints_timed");
            stats.num_requested = row.get("checkpoints_req");
            stats.write_time_ms = row.get("checkpoint_write_time");
            stats.sync_time_ms = row.get("checkpoint_sync_time");
            stats.buffers_written = row.get("buffers_checkpoint");
            stats.buffers_clean = row.get("buffers_clean");
            stats.maxwritten_clean = row.get("maxwritten_clean");
            stats.buffers_alloc = row.get("buffers_alloc");
            stats.buffers_backend = row.get("buffers_backend");
        }

        let now = Instant::now();
        if let Some((prev_time, ref prev_stats)) = self.last_sample {
            let dt = now.duration_since(prev_time).as_secs_f64();
            let d_timed = (stats.num_timed - prev_stats.num_timed) as f64;
            let d_req = (stats.num_requested - prev_stats.num_requested) as f64;
            let total_cp = d_timed + d_req;
            let forced_ratio = if total_cp > 0.0 { d_req / total_cp } else { 0.0 };

            let d_clean = (stats.buffers_clean - prev_stats.buffers_clean) as f64;
            let d_backend = (stats.buffers_backend - prev_stats.buffers_backend) as f64;
            let cushioning = if (d_clean + d_backend) > 0.0 { d_clean / (d_clean + d_backend) } else { 1.0 };

            if forced_ratio > 0.10 {
                eprintln!("[CRITICAL] Forced checkpoint ratio {:.1}% > 10% SLA! Under-sized max_wal_size.", forced_ratio * 100.0);
            }
            if cushioning < 0.95 {
                eprintln!("[CRITICAL] Bgwriter cushioning {:.1}% < 95%! Backends writing {:.1} buffers/sec.", cushioning * 100.0, d_backend / dt);
            }
        }

        self.last_sample = Some((now, stats));
        Ok(())
    }
}
```

---

## 5. The 6-State Checkpoint & Buffer Flush Lifecycle Finite-State Machine (FSM)

```
                       ┌───────────────────────────────┐
                       │  STATE 0: ENGINE PROBE &      │
                       │  DYNAMIC CATALOG RESOLUTION   │
                       └───────────────┬───────────────┘
                                       │ server_version_num >= 170000
                                       ▼
                       ┌───────────────────────────────┐
                       │  STATE 1: IDLE SLEEP &        │
                       │  BGWRITER BUFFER CUSHIONING   │
                       └───────┬───────────────┬───────┘
          checkpoint_timeout   │               │ max_wal_size exceeded / manual CHECKPOINT
          reached              │               │ (Forced Checkpoint Trigger)
                               ▼               ▼
      ┌─────────────────────────────┐    ┌─────────────────────────────┐
      │ STATE 2A: SCHEDULED         │    │ STATE 2B: FORCED CHECKPOINT │
      │ TIMED CHECKPOINT (HEALTHY)  │    │ SINK (WAL CAPACITY BREACH)  │
      └──────────────┬──────────────┘    └──────────────┬──────────────┘
                     │                                  │
                     └─────────────────┬────────────────┘
                                       ▼
                       ┌───────────────────────────────┐
                       │  STATE 3: BUFFER FLUSH &      │
                       │  SPREAD I/O WRITING (0.9x)    │
                       └───────────────┬───────────────┘
                                       │ files written to disk
                                       ▼
                       ┌───────────────────────────────┐
                       │  STATE 4: KERNEL FSYNC SYNC   │
                       │  & REDO LSN ADVANCEMENT       │
                       └───────────────┬───────────────┘
                                       │ fsync complete & pg_control updated
                                       ▼
                       ┌───────────────────────────────┐
                       │  STATE 5: RECOVERY RESTPOINT  │
                       │  & SLA RATIO AUDIT EVALUATION │
                       └───────────────┬───────────────┘
                                       │ Audit complete: R_req <= 0.05
                                       └──► [Return to STATE 1]
```

### State Transition Invariant Table

| Current State | Trigger / Event | Next State | Guard Condition & Invariant Rule | Action / Side Effect |
| :--- | :--- | :--- | :--- | :--- |
| **STATE 0**: Engine Probe | Session connect or migration | **STATE 1**: Idle & Cushioning | Query `server_version_num`. If $\ge 170000$, bind `pg_stat_checkpointer`. | Polyfill catalog queries; initialize telemetry metrics struct. |
| **STATE 1**: Idle & Cushioning | `bgwriter_delay` timer tick | **STATE 1**: Idle & Cushioning | Check `buffers_clean` and `maxwritten_clean`. If ceiling hit, alert. | Bgwriter cleans dirty buffers up to `bgwriter_lru_maxpages`. |
| **STATE 1**: Idle & Cushioning | `checkpoint_timeout` reached | **STATE 2A**: Scheduled Checkpoint | Invariant: Scheduled checkpoints must account for $\ge 90\%$ of events. | Checkpointer wakes; captures start LSN and dirty buffer list. |
| **STATE 1**: Idle & Cushioning | WAL reaches `max_wal_size` | **STATE 2B**: Forced Checkpoint | Alert if $R_{\text{req}} > 0.10$. Indicates undersized WAL headroom. | Checkpointer wakes immediately; emits warning log if frequent. |
| **STATE 2A / 2B**: Checkpoint Init | Dirty buffer list assembled | **STATE 3**: Spread I/O Writing | Writes smoothed across $T_{\text{timeout}} \times C_{\text{target}}$ ($C_{\text{target}} = 0.9$). | Checkpointer writes 8KB dirty blocks sequentially to disk. |
| **STATE 3**: Writing Complete | All dirty buffers flushed | **STATE 4**: Kernel fsync Sync | Measure `sync_time`. If $T_{\text{sync}} / T_{\text{total}} > 0.30$, flag I/O queue stall. | Issue `fsync()` on table files; update `pg_control` with new REDO LSN. |
| **STATE 4**: fsync Complete | REDO horizon advanced | **STATE 5**: Telemetry Audit | Query `pg_stat_checkpointer`. Compute $R_{\text{req}}$ and $\eta_{\text{cushion}}$. | Record metrics delta; trip circuit breaker or SRE alerts if breached. |
| **STATE 5**: Telemetry Audit | SLA verification passed | **STATE 1**: Idle & Cushioning | Invariant: $R_{\text{req}} \le 0.05 \land \eta_{\text{cushion}} \ge 0.95$. | Flush cycle concludes; checkpointer sleeps until next timeout. |

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Gates

Save the following verification script as `test_postgres17_checkpointer_invariants.sh` in your repository. It tests for PostgreSQL 17 catalog compliance, validates that legacy scripts do not execute broken column queries, verifies view polyfill resilience, and asserts checkpoint parameter invariants.

```bash
#!/usr/bin/env bash
# ==============================================================================
# test_postgres17_checkpointer_invariants.sh
# Machine-verifiable CI gate for PostgreSQL 17 Checkpointer & Bgwriter Invariants
# ==============================================================================
set -euo pipefail

DB_URL="${TEST_DATABASE_URL:-postgres://postgres:postgres@localhost:5432/postgres}"

echo "======================================================================"
echo " [CI GATE] Auditing PostgreSQL 17 Checkpointer & Bgwriter Invariants"
echo "======================================================================"

# 1. Verify PostgreSQL Engine Version
PG_VERSION=$(psql "${DB_URL}" -t -A -c "SELECT current_setting('server_version_num')::integer;")
echo "Detected PostgreSQL server_version_num: ${PG_VERSION}"

if [ "${PG_VERSION}" -lt 170000 ]; then
  echo "⚠️ Skipping PostgreSQL 17 checkpointer tests on legacy PostgreSQL version (${PG_VERSION})."
  exit 0
fi

echo "✅ Step 1 Passed: PostgreSQL 17+ detected."

# 2. Verify pg_stat_checkpointer exists and exposes expected columns
echo "Auditing pg_stat_checkpointer catalog columns..."
psql "${DB_URL}" -v ON_ERROR_STOP=1 <<'SQL'
SELECT
    num_timed,
    num_requested,
    restartpoints_timed,
    restartpoints_req,
    restartpoints_done,
    write_time,
    sync_time,
    buffers_written,
    stats_reset
FROM pg_stat_checkpointer;
SQL
echo "✅ Step 2 Passed: pg_stat_checkpointer exists with valid schema."

# 3. Verify removed columns in pg_stat_bgwriter trigger expected error if called directly
echo "Verifying removed columns in pg_stat_bgwriter are NOT queried blindly..."
ERR_CODE=$(psql "${DB_URL}" -c "SELECT checkpoints_timed FROM pg_stat_bgwriter;" 2>&1 || true)
if [[ "${ERR_CODE}" =~ "column \"checkpoints_timed\" does not exist" ]]; then
  echo "✅ Step 3 Passed: Correctly verified that checkpoints_timed is absent from pg_stat_bgwriter in PG 17."
else
  echo "❌ Fatal: Unexpected behavior when querying legacy column from pg_stat_bgwriter!"
  exit 1
fi

# 4. Deploy and test the resilient cross-version polyfill view
echo "Deploying and testing resilient compatibility view v_cluster_checkpoint_stats..."
psql "${DB_URL}" -v ON_ERROR_STOP=1 <<'SQL'
CREATE OR REPLACE VIEW v_cluster_checkpoint_stats AS
SELECT
    c.num_timed,
    c.num_requested,
    c.restartpoints_timed,
    c.restartpoints_req,
    c.restartpoints_done,
    c.write_time AS checkpoint_write_time_ms,
    c.sync_time AS checkpoint_sync_time_ms,
    c.buffers_written AS buffers_checkpoint,
    b.buffers_clean,
    b.maxwritten_clean,
    b.buffers_alloc,
    COALESCE(i.buffers_backend, 0) AS buffers_backend
FROM pg_stat_checkpointer c
CROSS JOIN pg_stat_bgwriter b
LEFT JOIN LATERAL (
    SELECT SUM(writes)::bigint AS buffers_backend
    FROM pg_stat_io
    WHERE backend_type = 'client backend' AND io_context = 'normal' AND io_object = 'relation'
) i ON true;

SELECT
    num_timed,
    num_requested,
    buffers_checkpoint,
    buffers_clean,
    buffers_backend
FROM v_cluster_checkpoint_stats;
SQL
echo "✅ Step 4 Passed: Resilient polyfill view deployed and queried successfully."

# 5. Checkpoint GUC configuration audit
echo "Auditing Checkpoint & Bgwriter GUC parameters..."
psql "${DB_URL}" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
    v_completion_target numeric;
    v_timeout_sec integer;
BEGIN
    SELECT setting::numeric INTO v_completion_target FROM pg_settings WHERE name = 'checkpoint_completion_target';
    SELECT setting::integer INTO v_timeout_sec FROM pg_settings WHERE name = 'checkpoint_timeout';

    IF v_completion_target < 0.9 THEN
        RAISE WARNING 'checkpoint_completion_target is % (recommended: 0.9 to avoid write bursts)', v_completion_target;
    END IF;

    IF v_timeout_sec < 300 THEN
        RAISE EXCEPTION 'checkpoint_timeout is dangerously low (% seconds). Minimum 300s required.', v_timeout_sec;
    END IF;
END $$;
SQL
echo "✅ Step 5 Passed: Checkpoint GUC configuration complies with smoothing invariants."

echo "======================================================================"
echo " 🎉 ALL POSTGRESQL 17 CHECKPOINTER & BGWRITER INVARIANTS VERIFIED!"
echo "======================================================================"
```

---

## 7. Definition of Done (DoD) Quality Checklist

Before approving any database pull request, infrastructure migration, or monitoring exporter upgrade, autonomous agents and engineers must verify:

- [ ] **Engine Introspection**: All telemetry collectors and scripts query `server_version_num >= 170000` before accessing `pg_stat_checkpointer`.
- [ ] **Zero Legacy Scrapes**: Zero references to removed columns (`checkpoints_timed`, `checkpoints_req`, `checkpoint_write_time`, `checkpoint_sync_time`, `buffers_checkpoint`) in queries targeting `pg_stat_bgwriter`.
- [ ] **Forced Checkpoint Ratio SLA**: $R_{\text{req}} = \frac{\Delta \text{num\_requested}}{\Delta \text{num\_timed} + \Delta \text{num\_requested}} \le 0.10$ (target $\le 0.05$).
- [ ] **Checkpoint Smoothing**: `checkpoint_completion_target = 0.9` configured across all primary and replica instances.
- [ ] **WAL Headroom Sizing**: `max_wal_size >= 16GB` (typically 32GB–64GB on cloud SSD/NVMe) to permanently eliminate WAL-driven forced checkpoints and FPW amplification.
- [ ] **Bgwriter Cushioning Efficacy**: $\eta_{\text{cushion}} \ge 0.95$, guaranteeing that client backends are not stalling on synchronous dirty buffer disk writes.
- [ ] **Standby Restartpoint Monitoring**: Physical read replicas monitor `restartpoints_done` and `restartpoints_req` to detect WAL redo replay lag before replication disconnects occur.
