---
description: PostgreSQL continuous WAL archiving (archive_mode = on/always), archive_command vs archive_library (C shared libraries in PG 15+), archiver process (pgarch) backpressure, .ready vs .done status files, pg_stat_archiver telemetry, disk exhaustion PANIC prevention, archive_timeout rate-limiting vs zero-padding amplification, and atomic idempotent storage push across Go (pgx/v5), TypeScript (Kysely, Drizzle), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{archive,archiver,wal,pg_stat_archiver,backup,pitr,disk,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/admin/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/storage/**/*.{go,rs},**/config/**/*.{conf,toml,yaml,json}
alwaysApply: false
---

# Agentic Database Continuous WAL Archiving, `archive_command` vs `archive_library`, Archiver Backpressure, `pg_stat_archiver` & Disk Exhaustion Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to configure PostgreSQL disaster recovery pipelines, manage Continuous Write-Ahead Log (WAL) archiving, provision Point-in-Time Recovery (PITR) storage targets (S3, GCS, Ceph, MinIO, Azure Blob, pgBackRest, WAL-G), design high-throughput write microservices, or deploy database infrastructure across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `pg`), Python (`SQLAlchemy 2.0`, `asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Silent Storage Network Blip & Infinite Archiver Retry Loop" (where `archive_command` exits non-zero due to transient S3 503 SlowDown, expired IAM credentials, or an unreachable NFS mount, and because PostgreSQL's archiver process `pgarch` is strictly single-threaded and retries the exact same 16MB file indefinitely without skipping, the entire continuous archiving queue halts), the "Unbounded `pg_wal` Segment Accumulation & Cluster-Wide PANIC Shutdown" (where unarchived WAL segments cannot be recycled or removed by checkpoints because `XLogArchiveCheckDone()` returns false, causing `pg_wal` to grow until disk capacity reaches 100%, forcing PostgreSQL to crash with `PANIC: could not write to file "pg_wal/...": No space left on device` and requiring dangerous manual emergency disk interventions), the "Shell Fork/Exec Storm & Linux Process Table Saturation Under High TPS" (where legacy shell-based `archive_command = 'test ! -f ... && cp %p ...'` spawns a new `/bin/sh -c` subshell for every single 16MB segment, burning CPU in fork context switches and exhausting OS PID space `kernel.pid_max` during write surges of 50–200 WAL files/sec), the "`archive_timeout` Partial Segment Flush & 100x WAL Padding Amplification Trap" (where autonomous agents configure aggressive `archive_timeout = 30s` to force low RPO, but during low-activity periods every timeout forces PostgreSQL to close the current WAL segment and pad it with zeroes up to 16MB, ballooning network upload bandwidth, generating gigabytes of empty WAL files, and multiplying cloud S3 PUT charges by 50x–100x), the "Non-Atomic Upload & Silently Corrupted WAL Archive Trap" (where `archive_command` directly streams to the final destination without atomic `.tmp` staging or overwrite verification `test ! -f`, leaving truncated or half-written 8MB files upon network RST that silently cause future Point-in-Time Recovery to abort with `FATAL: invalid record length in WAL segment`), and the "Missing Archiver Sentinel & `pg_stat_archiver` Blindness" (where operations teams monitor host disk space at 90% but ignore archiver lag, leaving zero warning before high-TPS write spikes exhaust the remaining 10% disk in minutes) by establishing a strict 5-Tier WAL Archival & Retention Governance Ladder, mathematical queueing and disk exhaustion theorems, an autonomous TypeScript `AgenticWALArchiverGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state archiver lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 WAL Archival & Retention Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, **Continuous Archiving** (`src/backend/postmaster/pgarch.c` and `src/backend/access/transam/xlogarchive.c`) is the foundational engine that delivers Point-in-Time Recovery (PITR) and physical backup streaming:

1. **The Archiver Background Process (`pgarch`)**: When `archive_mode` is set to `on` (or `always` for physical replicas), the postmaster forks the `pgarch` daemon.
2. **The Status Directory (`pg_wal/archive_status/`)**:
   - When a 16MB WAL segment file (e.g. `000000010000000A0000005F`) is fully written, closed, and flushed (or closed early via `archive_timeout` or `pg_switch_wal()`), the backend creates an empty trigger file: `pg_wal/archive_status/000000010000000A0000005F.ready`.
   - The archiver scans this directory in lexicographical order, selecting the oldest `.ready` file.
   - Upon successful archival (exit code 0), `pgarch` renames the status file from `.ready` to `.done`.
3. **The Checkpoint Pruning Barrier (`XLogArchiveCheckDone`)**:
   During regular checkpoints, PostgreSQL cleans up old WAL segments via `RemoveOldXlogFiles()`. For every segment older than the checkpoint redo point:
   - If archiving is enabled, PostgreSQL calls `XLogArchiveCheckDone()`.
   - **If the segment status is NOT `.done` (i.e. it is still `.ready` or un-archived), POSTGRESQL IS STRICTLY FORBIDDEN FROM REMOVING OR RECYCLING IT.**
   - Unlike streaming replication slots (which support `max_slot_wal_keep_size` in PostgreSQL 13+ to drop lagging slots and protect disk space), **POSTGRESQL CONTINUOUS ARCHIVING HAS NO NATIVE UPPER BOUND ON DISK RETENTION!**
4. **Execution Mechanics: `archive_command` vs `archive_library`**:
   - **`archive_command` (Shell Invocation)**: PostgreSQL passes the command string to `system()` or `/bin/sh -c "archive_command"`. Tokens `%p` (full path to segment) and `%f` (filename only) are replaced. Each segment incurs a shell fork, exec, memory allocation, and waitpid.
   - **`archive_library` (PostgreSQL 15+ C Shared Library)**: PostgreSQL loads a compiled shared object (`.so` / `.dylib`) into `pgarch` address space and executes the `ArchiveModuleCallbacks.archive_file` function pointer directly in-process with zero fork/exec overhead.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             POSTGRESQL CONTINUOUS ARCHIVING SUBSYSTEM & DISK EXHAUSTION                │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ WAL Writer / Backends                                                                 │
│   │                                                                                    │
│   ├── Writes 16MB WAL Segments -> pg_wal/0000000100000001000000A1                      │
│   └── On Segment Completion    -> Creates pg_wal/archive_status/...A1.ready           │
│                                                                                        │
│ PostgreSQL Archiver Process (pgarch)                                                   │
│   │                                                                                    │
│   ├── Scans pg_wal/archive_status/*.ready (lexicographical FIFO order)                 │
│   │                                                                                    │
│   ├── Executes archive_command (or archive_library in PG 15+)                          │
│   │     │                                                                              │
│   │     ├── SUCCESS (Exit Code 0):                                                     │
│   │     │     Renames .ready -> .done                                                  │
│   │     │     Checkpointer can safely remove/recycle segment at next checkpoint!       │
│   │     │                                                                              │
│   │     └── FAILURE (Exit Code != 0: S3 Timeout, Expired IAM, Full Remote NFS):        │
│   │           Logs LOG: archive command failed with exit code 1                        │
│   │           Sleeps 1s..60s (pgarch_ArchiverCopyLoop exponential backoff)             │
│   │           STRICTLY RETRIES SAME SEGMENT! NEVER SKIPS!                              │
│   │                                                                                    │
│ ❌ THE DISK EXHAUSTION CASCADE (When Archiver Fails Under Write Load):                  │
│                                                                                        │
│   OLTP Backends: Continue writing at 100 MB/s (6.25 segments / sec)                   │
│   pg_wal Growth: +375 MB/min -> +22.5 GB/hour -> +540 GB/day!                          │
│   Checkpointer : Attempts RemoveOldXlogFiles() -> BLOCKED by XLogArchiveCheckDone()!   │
│   Disk Space   : Drops from 500GB -> 200GB -> 50GB -> 0GB                              │
│   CRITICAL CRASH: PANIC: could not write to file "pg_wal/...": No space left on device│
│   Recovery     : PostgreSQL CANNOT BOOT! Recovery requires WAL space! Emergency Outage │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

When autonomous coding agents write database configurations, deployment manifests, or backup automation, LLMs routinely introduce 6 catastrophic WAL archiving flaws:

### The 6 WAL Archival & Retention Catastrophes

```bash
# ❌ CATASTROPHIC LLM ANTI-PATTERN 1: NON-IDEMPOTENT & NON-ATOMIC SHELL ARCHIVE COMMAND
# Autonomous agent configures postgresql.conf with a naive direct copy:
archive_command = 'cp %p /mnt/wal_archive/%f'
# FAILURE MECHANISMS:
# 1. Non-atomic: If network blip or SIGTERM interrupts 'cp', destination has a truncated 8MB file.
# 2. On retry, cp overwrites or fails with EBUSY, corrupting backup integrity.
# 3. No overwrite verification: If destination exists, cp silently overwrites existing WAL!
# 4. Spawns /bin/sh for every 16MB file, bottlenecking high-throughput ingestion.

# ❌ CATASTROPHIC LLM ANTI-PATTERN 2: BLIND S3 UPLOAD WITHOUT CONDITIONAL WRITES
archive_command = 'aws s3 cp %p s3://my-backup-bucket/wal/%f'
# FAILURE MECHANISMS:
# 1. Spawns Python VM + AWS CLI runtime on EVERY 16MB segment (300ms startup latency per file!).
# 2. Maximum archiver throughput capped at ~3 files/sec (48 MB/s), failing to keep up with write surges.
# 3. AWS IAM token expiration triggers endless retry loop; disk fills to 100% in silence.

# ❌ CATASTROPHIC LLM ANTI-PATTERN 3: AGGRESSIVE archive_timeout ZERO-PADDING AMPLIFICATION
archive_timeout = 10s
# Intended for "near-zero RPO".
# FAILURE MECHANISM:
# On low-traffic databases (10 KB/sec writes), every 10 seconds PostgreSQL closes the current
# segment and pads the remaining 15.99 MB with zeroes.
# Generates 360 full 16MB files/hour = 5.76 GB/hour of empty padded WAL!
# Multiplies S3 API PUT costs by 360x and exhausts egress bandwidth.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: DISK HEADROOM BLINDNESS & ZERO ARCHIVER MONITORING
-- Operations scripts monitor df -h at 90%, but never query pg_stat_archiver!
-- When archiver gets stuck during a batch update generating 200 MB/s,
-- the remaining 10% disk space is consumed in less than 5 minutes!
```

```
+----------------------------------------------------------------------------------------------------+
|                         THE 6 WAL ARCHIVAL & RETENTION CATASTROPHES                                |
+------------------------------------+---------------------------------------------------------------+
| 1. Silent Storage Blip & Infinite  | Single-threaded pgarch enters permanent retry loop upon S3    |
|    Archiver Retry Loop             | 503, expired IAM, or network blip; archive queue halts 100%.  |
+------------------------------------+---------------------------------------------------------------+
| 2. Unbounded pg_wal Accumulation & | Checkpointer cannot remove .ready segments; pg_wal grows until|
|    Disk Exhaustion PANIC Shutdown  | disk reaches 100%, causing PANIC crash and unbootable engine. |
+------------------------------------+---------------------------------------------------------------+
| 3. Shell Fork/Exec Storm & Linux   | archive_command forks /bin/sh per 16MB segment, exhausting OS |
|    Process Table Saturation        | kernel.pid_max and burning CPU under write surges >50 files/s.|
+------------------------------------+---------------------------------------------------------------+
| 4. archive_timeout Zero-Padding    | Setting archive_timeout <= 30s on low-traffic clusters forces |
|    100x WAL Amplification Trap     | 16MB zero-padding per interval, ballooning S3 costs and I/O.  |
+------------------------------------+---------------------------------------------------------------+
| 5. Non-Atomic Upload & Silently    | Direct copy/upload leaves half-written truncated files upon   |
|    Corrupted WAL Archive           | interrupt, silently destroying Point-in-Time Recovery (PITR). |
+------------------------------------+---------------------------------------------------------------+
| 6. Missing Archiver Sentinel &     | Monitoring host disk space instead of pg_stat_archiver lag    |
|    pg_stat_archiver Blindness      | leaves zero lead time before write spikes crash the cluster.  |
+------------------------------------+---------------------------------------------------------------+
```

---

## 2. The 5-Tier WAL Archival & Retention Governance Ladder

To eliminate disk crashes, backup corruption, and archiver bottlenecks, autonomous agents must adhere to the **5-Tier WAL Archival & Retention Governance Ladder**:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               THE 5-TIER WAL ARCHIVAL & RETENTION GOVERNANCE LADDER                    │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Atomic, Idempotent Archive Command & C archive_library (PG 15+)               │
│   • Must use atomic staging (.tmp write + atomic rename) or pgBackRest / WAL-G.        │
│   • In PostgreSQL 15+, mandate archive_library (in-process C shared module) over shell.│
│   • Assert strict non-overwrite protection (test ! -f destination/%f).                 │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Sane archive_timeout Sizing & Streaming WAL Complements                       │
│   • Never configure archive_timeout < 300s unless steady write rate exceeds 16MB / T.  │
│   • For sub-minute RPO, use pg_receivewal streaming replication, NOT archive_timeout.  │
│   • Zero-padding amplification factor must satisfy α_pad <= 1.25.                      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Real-Time pg_stat_archiver Telemetry & Backlog Sentinels                       │
│   • Continuously sample pg_stat_archiver (failed_count, last_failed_time, lag_seconds).│
│   • Count pending .ready files in pg_wal/archive_status/: Alert if backlog > 10 files. │
│   • Calculate archiver byte lag: pg_wal_lsn_diff(pg_current_wal_lsn(), archived_lsn).  │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Autonomous Archiver Circuit Breaker & Disk Headroom Fencing                    │
│   • Calculate Dynamic Time-to-Exhaustion: T_exhaust = FreeDiskBytes / WAL_Gen_Rate.     │
│   • When Free Disk < 20% OR T_exhaust < 30min: Shed batch jobs and trigger P1 alerts.  │
│   • Emergency Archival Fallback: Point archive_command to local overflow partition     │
│     before disk fills to 100%, preventing cluster PANIC shutdown.                      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Machine-Verifiable CI Config Linting & Automated PITR Sandboxes                │
│   • CI static analysis gate asserting postgresql.conf archive safety invariants.       │
│   • Daily automated sandbox restore drill validating continuous WAL replay integrity.  │
│   • Zero-failed-archive DoD verification before production deployment.                 │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Mathematical Foundations: Queueing Collapse, Disk Exhaustion & WAL Amplification

### 3.1 Queueing Model of the Archiver Process

Let the WAL segment generation rate be $\lambda_{\text{wal}}$ (segments per second) and the archiver upload service rate be $\mu_{\text{arch}}$ (segments per second):

$$\lambda_{\text{wal}} = \frac{\text{Throughput}_{\text{write}}\ (\text{bytes/sec})}{16 \times 1024 \times 1024}$$

The single-threaded archiver process (`pgarch`) models a deterministic single-server queue ($M/D/1$ or $D/D/1$). For system stability:

$$\rho = \frac{\lambda_{\text{wal}}}{\mu_{\text{arch}}} < 1.0$$

Where $\mu_{\text{arch}}$ is bounded by upload latency $T_{\text{upload}}$ and shell fork overhead $T_{\text{fork}}$:

$$\mu_{\text{arch}} = \frac{1}{T_{\text{fork}} + T_{\text{upload}} + T_{\text{fsync}}}$$

- Under shell-based `archive_command` invoking Python/AWS-CLI: $T_{\text{fork}} \approx 300\text{ms}$. Maximum $\mu_{\text{arch}} \approx 3.3 \text{ segments/sec} \approx 53\text{ MB/s}$.
- Under C `archive_library` (e.g. pgBackRest): $T_{\text{fork}} = 0\text{ms}$. Maximum $\mu_{\text{arch}} \approx 60 \text{ segments/sec} \approx 960\text{ MB/s}$ (saturating 10GbE network).

### 3.2 Time to Disk Exhaustion Under Archiver Stall

When the archiver fails ($\mu_{\text{arch}} = 0$, e.g. S3 outage or expired IAM token), every newly written segment accumulates in `pg_wal`. Let $D_{\text{free}}$ be the currently available disk space on the partition hosting `pg_wal`:

$$T_{\text{exhaust}} = \frac{D_{\text{free}}}{\lambda_{\text{wal}} \times 16\text{MB}} = \frac{D_{\text{free}}}{\text{WriteThroughput}_{\text{bytes/sec}}}$$

**Theorem (Archival Panic Horizon)**: If write throughput is $100\text{ MB/s}$ and available disk space is $50\text{ GB}$:

$$T_{\text{exhaust}} = \frac{50 \times 1024\text{ MB}}{100\text{ MB/s}} = 512\text{ seconds} \approx 8.5\text{ minutes}$$

Relying on standard 1-hour or 15-minute host-level disk polling guarantees a cluster crash. Sentinels must evaluate $T_{\text{exhaust}}$ dynamically at $\le 10$-second intervals!

### 3.3 Zero-Padding Amplification Factor Under `archive_timeout`

When `archive_timeout` $= T_{\text{to}}$ forces a WAL switch, the actual transaction data volume generated during that interval is $V_{\text{actual}} = \lambda_{\text{tx}} \times T_{\text{to}}$. The amplified volume written to disk and uploaded to storage is:

$$V_{\text{archived}} = \max(16\text{MB},\ \lceil \frac{V_{\text{actual}}}{16\text{MB}} \rceil \times 16\text{MB})$$

The amplification coefficient $\alpha_{\text{pad}}$ is:

$$\alpha_{\text{pad}} = \frac{16\text{MB}}{\max(1\text{ byte},\ \lambda_{\text{tx}} \times T_{\text{to}})}$$

If $\lambda_{\text{tx}} = 5\text{ KB/s}$ and $T_{\text{to}} = 30\text{s}$, $V_{\text{actual}} = 150\text{ KB}$. The amplification coefficient is:

$$\alpha_{\text{pad}} = \frac{16,384\text{ KB}}{150\text{ KB}} \approx 109.2\times$$

The cluster burns $109\times$ more storage egress bandwidth and S3 API calls than required by physical transactions!

---

## 4. Production TypeScript Guard Engine: `AgenticWALArchiverGuardEngine`

The following production-ready engine audits PostgreSQL WAL archiving health, detects pending `.ready` backlogs, inspects `pg_stat_archiver`, and computes dynamic time-to-exhaustion:

```typescript
// src/admin/wal-archiver-guard.ts
import { Pool, QueryResult } from 'pg';

export interface ArchiverStatusMetrics {
  archivedCount: number;
  lastArchivedWal: string | null;
  lastArchivedTime: Date | null;
  failedCount: number;
  lastFailedWal: string | null;
  lastFailedTime: Date | null;
  statsReset: Date | null;
  readyFilesCount: number;
  doneFilesCount: number;
  currentWalLsn: string;
  diskFreeBytes: number;
  diskTotalBytes: number;
}

export interface ArchiverEvaluationResult {
  healthy: boolean;
  severity: 'OK' | 'WARNING' | 'CRITICAL' | 'EMERGENCY';
  pendingBacklog: number;
  failureRatePerMin: number;
  timeToExhaustionSeconds: number | null;
  violations: string[];
  recommendations: string[];
}

export class AgenticWALArchiverGuardEngine {
  constructor(
    private readonly pool: Pool,
    private readonly maxAllowedReadyFiles: number = 10,
    private readonly criticalReadyFiles: number = 50,
    private readonly emergencyDiskThresholdBytes: number = 10 * 1024 * 1024 * 1024 // 10 GB
  ) {}

  /**
   * Fetches real-time archiver metrics from pg_stat_archiver and filesystem telemetry.
   */
  public async fetchArchiverMetrics(diskFreeBytes: number, diskTotalBytes: number): Promise<ArchiverStatusMetrics> {
    const statQuery = `
      SELECT
        archived_count,
        last_archived_wal,
        last_archived_time,
        failed_count,
        last_failed_wal,
        last_failed_time,
        stats_reset,
        pg_current_wal_lsn()::text AS current_wal_lsn
      FROM pg_stat_archiver;
    `;

    // Query ready file count from pg_ls_archive_statusdir() in PG 12+
    const statusDirQuery = `
      SELECT
        count(*) FILTER (WHERE name LIKE '%.ready') AS ready_count,
        count(*) FILTER (WHERE name LIKE '%.done')  AS done_count
      FROM pg_ls_archive_statusdir();
    `;

    const statRes: QueryResult = await this.pool.query(statQuery);
    if (statRes.rows.length === 0) {
      throw new Error('pg_stat_archiver view is unavailable. Ensure PostgreSQL is configured with archive_mode != off.');
    }
    const statRow = statRes.rows[0];

    let readyCount = 0;
    let doneCount = 0;
    try {
      const statusRes: QueryResult = await this.pool.query(statusDirQuery);
      if (statusRes.rows.length > 0) {
        readyCount = parseInt(statusRes.rows[0].ready_count, 10) || 0;
        doneCount = parseInt(statusRes.rows[0].done_count, 10) || 0;
      }
    } catch {
      // Fallback for restricted permissions: rely on stat counts
      readyCount = 0;
      doneCount = 0;
    }

    return {
      archivedCount: parseInt(statRow.archived_count, 10),
      lastArchivedWal: statRow.last_archived_wal,
      lastArchivedTime: statRow.last_archived_time ? new Date(statRow.last_archived_time) : null,
      failedCount: parseInt(statRow.failed_count, 10),
      lastFailedWal: statRow.last_failed_wal,
      lastFailedTime: statRow.last_failed_time ? new Date(statRow.last_failed_time) : null,
      statsReset: statRow.stats_reset ? new Date(statRow.stats_reset) : null,
      readyFilesCount: readyCount,
      doneFilesCount: doneCount,
      currentWalLsn: statRow.current_wal_lsn,
      diskFreeBytes,
      diskTotalBytes,
    };
  }

  /**
   * Evaluates archiver health, backlog pressure, and projects disk exhaustion.
   */
  public evaluateHealth(
    current: ArchiverStatusMetrics,
    previous: ArchiverStatusMetrics | null,
    deltaSeconds: number = 60
  ): ArchiverEvaluationResult {
    const violations: string[] = [];
    const recommendations: string[] = [];
    let severity: 'OK' | 'WARNING' | 'CRITICAL' | 'EMERGENCY' = 'OK';

    // 1. Calculate failures in the delta window
    let failuresInWindow = 0;
    if (previous) {
      failuresInWindow = Math.max(0, current.failedCount - previous.failedCount);
    }
    const failureRatePerMin = (failuresInWindow / Math.max(1, deltaSeconds)) * 60;

    // Check recent failure timestamp
    const now = Date.now();
    const hasRecentFailure = current.lastFailedTime !== null && (now - current.lastFailedTime.getTime()) < 120_000;

    if (hasRecentFailure || failuresInWindow > 0) {
      violations.push(
        `ARCHIVER RETRY STALL: Archiver failed ${failuresInWindow} times in last ${deltaSeconds}s. Last failed WAL: ${current.lastFailedWal} at ${current.lastFailedTime?.toISOString()}.`
      );
      recommendations.push(
        'Inspect PostgreSQL log for archive_command exit errors (e.g., S3 rate limits, network timeouts, IAM token expiration).'
      );
      severity = 'WARNING';
    }

    // 2. Check pending .ready file backlog
    const backlog = current.readyFilesCount;
    if (backlog >= this.criticalReadyFiles) {
      severity = 'CRITICAL';
      violations.push(`CRITICAL WAL BACKLOG: ${backlog} segments (.ready) are waiting in pg_wal/archive_status/. Archiver is completely stalled!`);
      recommendations.push('Verify archive storage destination availability and storage credentials immediately.');
    } else if (backlog >= this.maxAllowedReadyFiles) {
      if (severity === 'OK') severity = 'WARNING';
      violations.push(`ELEVATED WAL BACKLOG: ${backlog} un-archived segments queued (threshold: ${this.maxAllowedReadyFiles}).`);
      recommendations.push('Check network throughput to backup storage or consider switching to PostgreSQL 15+ archive_library.');
    }

    // 3. Project dynamic time to disk exhaustion
    let timeToExhaustionSeconds: number | null = null;
    if (previous && backlog > 0) {
      const bytesWritten = (current.readyFilesCount - previous.readyFilesCount) * 16 * 1024 * 1024;
      const rateBytesPerSec = bytesWritten / Math.max(1, deltaSeconds);

      if (rateBytesPerSec > 0) {
        timeToExhaustionSeconds = Math.floor(current.diskFreeBytes / rateBytesPerSec);
        if (timeToExhaustionSeconds < 1800) { // < 30 minutes
          severity = 'EMERGENCY';
          violations.push(
            `IMMINENT DISK EXHAUSTION PANIC: At current WAL accumulation rate (${(rateBytesPerSec / (1024 * 1024)).toFixed(2)} MB/s), available disk (${(current.diskFreeBytes / (1024 * 1024 * 1024)).toFixed(2)} GB) will reach 100% in ${(timeToExhaustionSeconds / 60).toFixed(1)} minutes!`
          );
          recommendations.push(
            'EMERGENCY ACTION: Pause non-critical batch ingest jobs, allocate temporary disk volume, or configure archive_command to local staging disk before database crashes with PANIC.'
          );
        }
      }
    }

    // 4. Absolute disk headroom check
    if (current.diskFreeBytes < this.emergencyDiskThresholdBytes) {
      severity = 'EMERGENCY';
      violations.push(
        `CRITICAL DISK HEADROOM BREACH: Available space is ${(current.diskFreeBytes / (1024 * 1024 * 1024)).toFixed(2)} GB (below ${(this.emergencyDiskThresholdBytes / (1024 * 1024 * 1024)).toFixed(2)} GB threshold).`
      );
      recommendations.push('Immediate disk volume expansion required to prevent emergency postmaster PANIC shutdown.');
    }

    const healthy = severity === 'OK';
    return {
      healthy,
      severity,
      pendingBacklog: backlog,
      failureRatePerMin,
      timeToExhaustionSeconds,
      violations,
      recommendations,
    };
  }
}
```

---

## 5. Cross-Runtime Implementations

### 5.1 Go (`jackc/pgx/v5`): Autonomous Archiver Lag Sentinel & Disk Headroom Sentinel

```go
package storage

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type ArchiverMetrics struct {
	ArchivedCount    int64
	LastArchivedWal  sql.NullString
	LastArchivedTime sql.NullTime
	FailedCount      int64
	LastFailedWal    sql.NullString
	LastFailedTime   sql.NullTime
	ReadyFileCount   int64
	CurrentWalLSN    string
	DiskFreeBytes    uint64
}

type ArchiverSentinel struct {
	pool             *pgxpool.Pool
	walMountPath     string
	maxBacklog       int64
	minFreeDiskBytes uint64
	logger           *slog.Logger
}

func NewArchiverSentinel(pool *pgxpool.Pool, walMountPath string, logger *slog.Logger) *ArchiverSentinel {
	return &ArchiverSentinel{
		pool:             pool,
		walMountPath:     walMountPath,
		maxBacklog:       15,
		minFreeDiskBytes: 15 * 1024 * 1024 * 1024, // 15 GB
		logger:           logger,
	}
}

func (s *ArchiverSentinel) CollectMetrics(ctx context.Context) (*ArchiverMetrics, error) {
	query := `
		SELECT
			a.archived_count,
			a.last_archived_wal,
			a.last_archived_time,
			a.failed_count,
			a.last_failed_wal,
			a.last_failed_time,
			pg_current_wal_lsn()::text,
			COALESCE((
				SELECT count(*)
				FROM pg_ls_archive_statusdir()
				WHERE name LIKE '%.ready'
			), 0) AS ready_count
		FROM pg_stat_archiver a;
	`

	var m ArchiverMetrics
	err := s.pool.QueryRow(ctx, query).Scan(
		&m.ArchivedCount,
		&m.LastArchivedWal,
		&m.LastArchivedTime,
		&m.FailedCount,
		&m.LastFailedWal,
		&m.LastFailedTime,
		&m.CurrentWalLSN,
		&m.ReadyFileCount,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to scan pg_stat_archiver: %w", err)
	}

	// Read physical filesystem disk space on the pg_wal mount
	var stat syscall.Statfs_t
	if err := syscall.Statfs(s.walMountPath, &stat); err == nil {
		m.DiskFreeBytes = stat.Bavail * uint64(stat.Bsize)
	}

	return &m, nil
}

func (s *ArchiverSentinel) AuditAndFence(ctx context.Context) error {
	m, err := s.CollectMetrics(ctx)
	if err != nil {
		return err
	}

	// 1. Backlog check
	if m.ReadyFileCount > s.maxBacklog {
		s.logger.Error("WAL Archiver Backlog Exceeded Safe Threshold!",
			slog.Int64("ready_files", m.ReadyFileCount),
			slog.Int64("failed_count", m.FailedCount),
			slog.String("last_failed_wal", m.LastFailedWal.String),
			slog.Time("last_failed_time", m.LastFailedTime.Time),
		)
		return fmt.Errorf("CRITICAL: WAL archiver backlog (%d files) exceeds threshold (%d)", m.ReadyFileCount, s.maxBacklog)
	}

	// 2. Disk headroom check
	if m.DiskFreeBytes > 0 && m.DiskFreeBytes < s.minFreeDiskBytes {
		s.logger.Error("CRITICAL: Disk headroom for pg_wal is below minimum safety threshold!",
			slog.Uint64("free_bytes_gb", m.DiskFreeBytes/(1024*1024*1024)),
			slog.Uint64("required_min_gb", s.minFreeDiskBytes/(1024*1024*1024)),
		)
		return fmt.Errorf("EMERGENCY: pg_wal disk headroom %d GB < %d GB safety fence",
			m.DiskFreeBytes/(1024*1024*1024), s.minFreeDiskBytes/(1024*1024*1024))
	}

	s.logger.Debug("Archiver status verified healthy",
		slog.Int64("archived_count", m.ArchivedCount),
		slog.Int64("ready_backlog", m.ReadyFileCount),
		slog.String("current_lsn", m.CurrentWalLSN),
	)
	return nil
}
```

---

### 5.2 Python (`asyncpg`): Continuous Archival Lag & Status Exporter

```python
import asyncio
import logging
from typing import Optional, Dict, Any
import asyncpg

logger = logging.getLogger("wal_archiver_sentinel")

class ArchiverHealthProbe:
    def __init__(self, dsn: str, max_ready_tolerance: int = 12):
        self.dsn = dsn
        self.max_ready_tolerance = max_ready_tolerance

    async def probe(self) -> Dict[str, Any]:
        conn: Optional[asyncpg.Connection] = None
        try:
            conn = await asyncpg.connect(self.dsn, timeout=5.0)
            
            row = await conn.fetchrow("""
                SELECT
                    archived_count,
                    last_archived_wal,
                    last_archived_time,
                    failed_count,
                    last_failed_wal,
                    last_failed_time,
                    pg_current_wal_lsn()::text AS current_lsn,
                    COALESCE((
                        SELECT count(*)
                        FROM pg_ls_archive_statusdir()
                        WHERE name LIKE '%.ready'
                    ), 0) AS ready_count
                FROM pg_stat_archiver;
            """)

            if not row:
                raise RuntimeError("pg_stat_archiver returned zero rows")

            ready_count = row["ready_count"]
            failed_count = row["failed_count"]
            last_failed_time = row["last_failed_time"]

            is_failing = False
            if ready_count > self.max_ready_tolerance:
                is_failing = True
                logger.critical(
                    f"WAL Archiver Backlog ALERT: {ready_count} unarchived segments waiting! "
                    f"Last failed WAL: {row['last_failed_wal']} at {last_failed_time}"
                )

            return {
                "healthy": not is_failing,
                "archived_count": row["archived_count"],
                "failed_count": failed_count,
                "ready_backlog": ready_count,
                "current_lsn": row["current_lsn"],
                "last_archived_wal": row["last_archived_wal"],
                "last_failed_time": last_failed_time.isoformat() if last_failed_time else None,
            }
        finally:
            if conn:
                await conn.close()
```

---

### 5.3 Rust (`sqlx`): Real-Time Archiver Health & Status Collector

```rust
use sqlx::{PgPool, FromRow};
use chrono::{DateTime, Utc};
use std::time::Duration;

#[derive(Debug, FromRow)]
pub struct ArchiverRecord {
    pub archived_count: i64,
    pub last_archived_wal: Option<String>,
    pub last_archived_time: Option<DateTime<Utc>>,
    pub failed_count: i64,
    pub last_failed_wal: Option<String>,
    pub last_failed_time: Option<DateTime<Utc>>,
    pub current_lsn: String,
    pub ready_count: i64,
}

pub struct WalArchiverSentinel {
    pool: PgPool,
    max_ready_limit: i64,
}

impl WalArchiverSentinel {
    pub fn new(pool: PgPool, max_ready_limit: i64) -> Self {
        Self { pool, max_ready_limit }
    }

    pub async fn check_archiver_health(&self) -> Result<ArchiverRecord, Box<dyn std::error::Error + Send + Sync>> {
        let record = sqlx::query_as::<_, ArchiverRecord>(
            r#"
            SELECT
                archived_count,
                last_archived_wal,
                last_archived_time,
                failed_count,
                last_failed_wal,
                last_failed_time,
                pg_current_wal_lsn()::text AS current_lsn,
                COALESCE((
                    SELECT count(*)
                    FROM pg_ls_archive_statusdir()
                    WHERE name LIKE '%.ready'
                ), 0) AS ready_count
            FROM pg_stat_archiver
            "#
        )
        .fetch_one(&self.pool)
        .await?;

        if record.ready_count > self.max_ready_limit {
            eprintln!(
                "[CRITICAL] PostgreSQL Archiver Queue Overflow: {} ready files, failed count: {}",
                record.ready_count, record.failed_count
            );
            return Err(format!(
                "Archiver backlog {} exceeds limit {}",
                record.ready_count, self.max_ready_limit
            ).into());
        }

        Ok(record)
    }
}
```

---

## 6. The 6-State Archiver Lifecycle Finite-State Machine (FSM)

The life cycle of every 16MB WAL segment within the archiving subsystem transitions across 6 deterministic states:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               THE 6-STATE WAL SEGMENT ARCHIVAL FINITE-STATE MACHINE                    │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│               [1. ACTIVE_WRITING]                                                      │
│                      │                                                                 │
│                      │ Segment fills to 16MB, or archive_timeout fires                 │
│                      ▼                                                                 │
│               [2. STATUS_READY]  (File: pg_wal/archive_status/<WAL>.ready created)     │
│                      │                                                                 │
│                      │ pgarch picks segment via FIFO scan                              │
│                      ▼                                                                 │
│               [3. ARCHIVING_IN_FLIGHT]                                                 │
│                 (archive_command shell spawned or archive_library C call)              │
│                      │                                       │                         │
│       Upload Succeeded (Exit 0)                              │ Upload Failed (Exit != 0│
│                      ▼                                       ▼                         │
│               [4. STATUS_DONE]                       [5. RETRY_BACKOFF]                │
│       (Renamed to <WAL>.done)                                │                         │
│                      │                                       │ Exponential backoff     │
│                      │ Checkpoint occurs                     │ 1s -> 2s -> ... -> 60s  │
│                      ▼                                       └───────────┐             │
│               [6. RECYCLED_OR_PURGED]                                    │             │
│       (Segment safely unlinked or reused)                                ▼             │
│                                                            Loops back to [3]           │
│                                                            (STRICT NO-SKIP INVARIANT!) │
│                                                                                        │
│ ❌ FAILURE RECOVERY: If in [5] indefinitely, disk fills. Checkpoint CANNOT advance [2]! │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

| State | Entry Condition | Action / Invariant | Exit Condition |
| :--- | :--- | :--- | :--- |
| **1. ACTIVE_WRITING** | New segment opened in `pg_wal` | WAL writer appends transaction records | Segment reaches 16MB or `archive_timeout` triggered |
| **2. STATUS_READY** | Segment closed by PostgreSQL | Backend writes `<WAL>.ready` into `archive_status/` | `pgarch` selects segment in alphabetical order |
| **3. ARCHIVING_IN_FLIGHT** | `pgarch` begins execution | Executes `archive_command` or invokes `archive_library` | Command process terminates |
| **4. STATUS_DONE** | Command exits with code 0 | `pgarch` renames `.ready` to `.done` | Next checkpoint inspects segment |
| **5. RETRY_BACKOFF** | Command exits with code $\ne 0$ | Sleep with exponential backoff (up to 60s); log error | Sleep expires; re-attempts State 3 on exact same segment |
| **6. RECYCLED_OR_PURGED** | Checkpoint runs and segment $< \text{redo\_lsn}$ | Segment is unlinked or renamed for reuse | Slot allocated to new transactions |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Checklist

Before deploying database infrastructure, continuous backup jobs, or storage automation to staging or production, autonomous agents and engineers must verify this 6-gate checklist:

```markdown
### PostgreSQL WAL Archiving & Retention Definition of Done (DoD)

- [ ] **Gate 1: Atomic & Idempotent Archiving Command / Library**
  - Verify that `archive_command` never writes directly to the final path without temporary staging (`.tmp` write followed by atomic `mv`/`rename`).
  - Verify strict non-overwrite protection: `test ! -f destination/%f && ...`.
  - In PostgreSQL 15+, mandate `archive_library` (e.g. pgBackRest or native C connector) to eradicate `/bin/sh` shell fork/exec overhead under high TPS.

- [ ] **Gate 2: Sane `archive_timeout` Sizing & Zero-Padding Audit**
  - Assert that `archive_timeout` is set to `0` (disabled) or $\ge 300\text{s}$ (5 minutes) unless transaction write volume exceeds $16\text{MB} / T_{\text{timeout}}$.
  - For requirements demanding $< 60$s RPO, mandate `pg_receivewal` streaming replication rather than high-frequency `archive_timeout`.
  - Assert that WAL padding amplification ratio $\alpha_{\text{pad}} \le 1.25$.

- [ ] **Gate 3: Continuous `pg_stat_archiver` Real-Time Telemetry**
  - Deploy a continuous health monitor checking `pg_stat_archiver` at $\le 15\text{s}$ intervals.
  - Alert immediately if `failed_count` increases or `last_failed_time` is within the last 2 minutes.
  - Continuously track archiver lag: `pg_wal_lsn_diff(pg_current_wal_lsn(), last_archived_lsn)`.

- [ ] **Gate 4: Unarchived Backlog Queue Sentinel (`.ready` Files)**
  - Assert that `SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready'` is monitored.
  - Alert (Warning) if backlog $> 10$ files; Alert (P1 Critical) if backlog $> 30$ files.

- [ ] **Gate 5: Dynamic Time-to-Exhaustion Sentinel ($T_{\text{exhaust}}$)**
  - Ensure monitoring agent computes $T_{\text{exhaust}} = D_{\text{free}} / \text{Rate}_{\text{wal}}$ dynamically.
  - Trigger automated write rate-limiting or storage circuit breaking if $T_{\text{exhaust}} < 30\text{ minutes}$ or free disk space $< 15\text{ GB}$.

- [ ] **Gate 6: Automated Ephemeral Sandbox PITR Drill**
  - Run automated daily or CI-driven restoration drills restoring from base backup and replaying archived WAL files up to a specific transaction target.
  - Assert zero `invalid record length` or corrupted block errors during recovery replay.
```
