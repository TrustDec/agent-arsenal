---
description: PostgreSQL in-database job scheduling (pg_cron), background worker allocation (max_worker_processes, cron.max_running_jobs), overlapping execution serialization, advisory lock concurrency fencing, cron.job_run_details catalog bloat elimination, partitioned history rotation, transaction isolation, non-transactional DDL boundaries, search_path injection defense (CVE-2018-1058), physical replica crash-loop defense, and failover promotion invariants across Go (jackc/pgx/v5), TypeScript (drizzle-orm, prisma, pg), Python (asyncpg, psycopg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{cron,schedule,job,worker,background,batch,task,maintenance}*.*,**/src/jobs/**/*.{ts,js,go,rs,py},**/src/workers/**/*.{ts,js,go,rs,py},**/internal/cron/**/*.{go,rs},**/internal/worker/**/*.{go,rs},**/migrations/**/*.{sql,ts,go,py},**/config/**/*.{ini,conf,toml,yaml,json}
alwaysApply: false
---

# Agentic Database Scheduled Jobs (`pg_cron`), Background Workers, Concurrency Overlap, Catalog Bloat & Worker Starvation Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, schedule, automate, or maintain PostgreSQL (13–17+) in-database background jobs (`pg_cron`), partition maintenance routines (`pg_partman`), materialized view refreshes, rollup aggregations, dead-letter queue (DLQ) redrives, or cleanup tasks across Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `prisma`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Single Master Database Target Disconnect (`cron.database_name`)" (where jobs scheduled from application databases silently target the administrative `postgres` database and fail with `SQLSTATE 42P01: relation does not exist` every minute without alerting the caller), the "Overlapping Execution Avalanche & Background Worker Starvation" (where jobs taking longer than their schedule period spawn overlapping instances, exhausting `cron.max_running_jobs` and `max_worker_processes`, starving autovacuum and parallel query workers, and collapsing cluster performance), the "`cron.job_run_details` Catalog Bloat & Disk Outage Timebomb" (where un-pruned run logs accumulate millions of unindexed rows, bloating B-Trees, timing out diagnostics, and filling disks), the "Non-Transactional Multi-Statement Half-Commit & DDL Barrier Disaster" (where combining `VACUUM` or `CREATE INDEX CONCURRENTLY` in multi-statement jobs triggers `SQLSTATE 25001`, or unhandled mid-script failures leave databases half-mutated), the "Unpinned `search_path` & CVE-2018-1058 Privilege Escalation in Background Workers" (where unqualified table and function calls in background cron jobs allow low-privilege users to hijack superuser worker executions), and the "Streaming Standby Replica Crash Loop & Failover Split-Brain" (where `pg_cron` starts on read-only physical standbys and crash-loops with `SQLSTATE 25006: cannot execute INSERT in a read-only transaction`) by establishing a strict 5-Tier Scheduled Job Governance Ladder, background worker capacity calculus, non-blocking advisory lock fencing, an autonomous TypeScript `AgenticDatabaseCronGuardEngine`, cross-runtime telemetry sentinels in Go, TypeScript, Python, and Rust, a 6-state job lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Scheduled Job Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL provides a background worker infrastructure (`BackgroundWorker`) that allows C extensions to fork long-lived processes managed directly by the postmaster. The standard extension for scheduling recurring tasks inside PostgreSQL is **`pg_cron`**. 

`pg_cron` operates via a master background worker (`pg_cron launcher`) initialized during postmaster startup (requiring `shared_preload_libraries = 'pg_cron'`). The launcher wakes every second, inspects the `cron.job` catalog table for jobs whose standard cron expressions (`minute hour day-of-month month day-of-week`) match the current wall-clock timestamp, and forks ephemeral background workers or connects via PostgreSQL's internal libpq loopback interface to execute the scheduled SQL command.

While `pg_cron` simplifies database operations by eliminating external crontab daemons, Kubernetes CronJobs, and distributed task schedulers, autonomous coding agents universally misunderstand PostgreSQL's process architecture, transaction semantics, and background worker memory constraints. This creates 6 catastrophic operational failure modes in production:

### The 6 Scheduled Job Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE TARGET DATABASE DISCONNECT & SILENT FAILURE LOOP
-- Agent connects to application database 'commerce_prod' and schedules an order cleanup job:
SELECT cron.schedule('prune_abandoned_carts', '*/5 * * * *', 'SELECT prune_old_carts();');

-- 💥 Catastrophe:
-- 1. By default, pg_cron GUC 'cron.database_name' is set to 'postgres' (or cluster default).
-- 2. Unless cron.schedule_in_database() is used or cron.database_name is explicitly configured,
--    pg_cron launches the job against the administrative 'postgres' database!
-- 3. 'prune_old_carts()' does not exist in 'postgres', throwing:
--    ERROR: function prune_old_carts() does not exist (SQLSTATE 42883)
-- 4. The job fails every 5 minutes silently. Client applications and agents receive NO error notifications.
--    Abandoned carts accumulate indefinitely until storage alerts trigger.
-- Invariant: Always use cron.schedule_in_database(...) with current_database() or explicit DB target.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: OVERLAPPING EXECUTION HERD & WORKER STARVATION
-- Agent schedules heavy aggregation rollup every minute:
SELECT cron.schedule('minute_rollup', '* * * * *', 'INSERT INTO hourly_stats SELECT ... FROM events WHERE ...');

-- 💥 Catastrophe:
-- 1. Under peak traffic or table growth, the aggregation query runtime degrades from 35s to 95s.
-- 2. At t = 60s, pg_cron spawns a SECOND worker for the same job; at t = 120s, a THIRD worker spawns.
-- 3. The concurrent instances contend for table locks and shared memory, further slowing each other down.
-- 4. Active jobs hit cron.max_running_jobs (default 5 or 32) and deplete PostgreSQL's max_worker_processes!
-- 5. Collateral damage: PostgreSQL can no longer allocate parallel query workers or autovacuum workers.
--    The entire cluster grinds to a halt under 100% CPU lock contention.
-- Invariant: Guard every scheduled job with non-blocking advisory locks (pg_try_advisory_xact_lock).

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: UNBOUNDED cron.job_run_details BLOAT & DISK PANIC
-- Agent schedules 10 micro-batch sync jobs running every 30 seconds:
-- 10 jobs * 2 runs/min * 60 min * 24 hr = 28,800 rows per day in cron.job_run_details!
-- 💥 Catastrophe:
-- 1. pg_cron NEVER automatically prunes or rotates cron.job_run_details.
-- 2. Within 6 months, cron.job_run_details contains > 5,000,000 rows with heavy text error messages.
-- 3. The table and its B-tree indexes consume gigabytes of storage, bloating shared_buffers.
-- 4. Monitoring queries checking cron status timeout, and on small disk volumes, disk hits 100% PANIC.
-- Invariant: Deploy a mandatory self-pruning retention job purging records older than 7 days in bounded batches.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: MULTI-STATEMENT TRANSACTION & DDL BARRIER CRASH
-- Agent schedules a nightly maintenance batch:
SELECT cron.schedule('nightly_maint', '0 3 * * *', 
    'VACUUM ANALYZE orders; REFRESH MATERIALIZED VIEW CONCURRENTLY order_summary; UPDATE sync_state SET ...;'
);

-- 💥 Catastrophe:
-- 1. pg_cron runs the command string inside a transaction block if multi-statement libpq mode is active.
-- 2. VACUUM and CREATE INDEX CONCURRENTLY cannot execute inside an active transaction block!
--    ERROR: 25001: VACUUM cannot run inside a transaction block.
-- 3. The job aborts instantly every night. Maintenance is never performed; table bloat explodes.
-- 4. If run without transaction boundaries, failure in statement 2 leaves statement 1 committed and 
--    statement 3 aborted, causing inconsistent half-mutated application state.
-- Invariant: Isolate non-transactional DDL (VACUUM/REINDEX) into dedicated single-statement jobs.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: UNPINNED search_path & CVE-2018-1058 ESCALATION
-- Agent schedules an unqualified cleanup procedure running as superuser/owner:
SELECT cron.schedule('security_cleanup', '0 * * * *', 'SELECT delete_expired_tokens();');

-- 💥 Catastrophe:
-- 1. Background worker executes as the scheduling role (e.g. postgres or service owner).
-- 2. No search_path is specified, so PostgreSQL falls back to default: "$user", public, pg_catalog.
-- 3. If an unprivileged user has CREATE privileges in public (or creates temporary objects),
--    they can define a malicious function delete_expired_tokens() or malicious operator '='.
-- 4. The superuser cron worker executes the malicious Trojan code, achieving full privilege escalation.
-- Invariant: Explicitly schema-qualify all objects and pin search_path = app_schema, pg_catalog, pg_temp.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: PHYSICAL REPLICA CRASH-LOOP & FAILOVER SPLIT-BRAIN
-- pg_cron is enabled in shared_preload_libraries on all nodes in an HA cluster.
-- On the streaming read-only standby replica:
-- 💥 Catastrophe:
-- 1. pg_cron launcher initializes on the standby. It attempts to check cron.job and log into cron.job_run_details.
-- 2. Writing to tables on a read-only standby fails violently:
--    ERROR: cannot execute INSERT in a read-only transaction (SQLSTATE 25006).
-- 3. The worker crashes and restarts continuously, spamming gigabytes of logs per day and wasting CPU.
-- 4. After HA failover, if the old primary is re-joined as a standby while pg_cron remains active without
--    recovery guards, both nodes may attempt to fire cron tasks, causing dual-master split-brain writes.
-- Invariant: Guard scheduled procedures with IF pg_is_in_recovery() THEN RETURN; END IF;.
```

### The 5-Tier Scheduled Job Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   THE 5-TIER PG_CRON SCHEDULED JOB GOVERNANCE LADDER                   │
├─────────┬───────────────────────────────────┬──────────────────────────────────────────┤
│ TIER 0  │ Pre-Flight Preload & DB Targeting │ shared_preload_libraries, explicit DB    │
│         │                                   │ binding via cron.schedule_in_database    │
├─────────┼───────────────────────────────────┼──────────────────────────────────────────┤
│ TIER 1  │ Concurrency Fencing & Non-Overlap │ Non-blocking pg_try_advisory_xact_lock   │
│         │                                   │ ensures O(1) skip on overlapping tasks   │
├─────────┼───────────────────────────────────┼──────────────────────────────────────────┤
│ TIER 2  │ Least Privilege & Pinned Schema   │ Strict non-superuser role, schema-       │
│         │                                   │ qualified calls, explicit search_path    │
├─────────┼───────────────────────────────────┼──────────────────────────────────────────┤
│ TIER 3  │ DDL / DML Transaction Separation  │ Single-statement non-transactional DDL;  │
│         │ & Standby Recovery Fencing        │ pg_is_in_recovery() replica short-circuit│
├─────────┼───────────────────────────────────┼──────────────────────────────────────────┤
│ TIER 4  │ Catalog Retention & Telemetry     │ Automated bounded cron.job_run_details   │
│         │                                   │ pruning, run-time variance DoD CI gates  │
└─────────┴───────────────────────────────────┴──────────────────────────────────────────┘
```

| Governance Tier | Architectural Scope | Primary Operational Guarantee |
| :--- | :--- | :--- |
| **Tier 0: Pre-Flight Preload & DB Targeting** | `shared_preload_libraries` introspection and explicit database binding. | Query `pg_settings` for `pg_cron` before setup; use `cron.schedule_in_database(name, spec, cmd, current_database())`. Eliminates cross-DB silent execution failures. |
| **Tier 1: Concurrency Fencing & Non-Overlap** | Advisory lock fencing against long-running execution overlap. | Every scheduled task acquires `pg_try_advisory_xact_lock(hashtext('job_name'))`. If already running, short-circuits in $< 0.1\text{ms}$, preventing worker starvation. |
| **Tier 2: Least Privilege & Pinned Schema** | RBAC separation and CVE-2018-1058 search-path hardening. | Execute jobs under dedicated application service roles; prepend commands with `SET search_path = app, pg_catalog, pg_temp;` and fully schema-qualify all function calls. |
| **Tier 3: Transaction Separation & Standby Safety** | Transactional boundaries and read-only physical standby guards. | Separate `VACUUM`/`REINDEX` from transactional DML; guard all scheduled routines with `IF pg_is_in_recovery() THEN RETURN; END IF;` to eliminate replica crash-loops. |
| **Tier 4: Catalog Retention & Telemetry DoD** | Automated history pruning and machine-verifiable CI gates. | Scheduled daily bounded pruning (`DELETE FROM cron.job_run_details WHERE end_time < NOW() - INTERVAL '7 days' LIMIT 5000`); active sentinels monitoring worker capacity. |

---

## 2. Mathematical Models & Formal Proofs

### Model 2.1: Background Worker Pool Saturation & Starvation Differential Calculus

PostgreSQL allocates a fixed total capacity of background worker processes, denoted $W_{\text{max}} = \text{max\_worker\_processes}$. At any timestamp $t$, the active worker pool is partitioned across concurrent subsystems:

$$W_{\text{active}}(t) = W_{\text{cron}}(t) + W_{\text{parallel}}(t) + W_{\text{logical\_rep}}(t) + W_{\text{autovacuum}}(t) \le W_{\text{max}}$$

Let a scheduled job $J_k$ have invocation schedule period $\tau_k$ (e.g. $\tau_k = 60\text{s}$ for `* * * * *`). Let its execution duration under nominal conditions be $D_{\text{nom}} < \tau_k$. 

Under data accumulation or lock contention, the execution duration inflates to $D_{\text{inflated}}(t) > \tau_k$. In the absence of concurrency fencing, `pg_cron` spawns a new worker process every $\tau_k$ seconds. The number of concurrent overlapping instances $N_k(t)$ of job $J_k$ at steady state satisfies:

$$N_k(t) = \left\lceil \frac{D_{\text{inflated}}(t)}{\tau_k} \right\rceil$$

If $M$ un-fenced jobs experience latency inflation, the total workers demanded by `pg_cron` is:

$$W_{\text{cron}}(t) = \sum_{k=1}^{M} N_k(t) = \sum_{k=1}^{M} \left\lceil \frac{D_k(t)}{\tau_k} \right\rceil$$

**Theorem 1 (Worker Exhaustion & Query Latency Collapse)**: *When $W_{\text{cron}}(t) \ge W_{\text{max}} - W_{\text{logical\_rep}}$, the available worker allocation for parallel query execution collapses to zero ($W_{\text{parallel}} \to 0$). Any analytical or OLTP query relying on parallel Gather / Gather Merge nodes collapses to single-worker sequential scans, increasing query latency by factor $\Gamma$*:

$$\Gamma = \frac{T_{\text{single}}}{T_{\text{parallel}}} \approx 1 + (P - 1) \cdot \eta_{\text{parallel}}$$

Where $P = \text{max\_parallel\_workers\_per\_gather} \in [2, 8]$ and $\eta_{\text{parallel}} \approx 0.85$ is the parallel scaling efficiency. For an 8-worker query, $\Gamma \approx 1 + 7 \times 0.85 \approx 6.95\times$.

Furthermore, if $W_{\text{cron}}(t) \ge W_{\text{max}}$, incoming logical replication apply workers and background writers fail to fork, causing cluster replication lag to diverge to infinity ($\Delta_{\text{lag}} \to \infty$).

---

### Model 2.2: Advisory Lock Non-Blocking CAS Fencing Stability Proof

To prevent $N_k(t) > 1$, every scheduled job $J_k$ must execute an atomic Compare-And-Swap (CAS) mutex prior to executing workload payload $L_k$.

PostgreSQL provides 64-bit transaction-scoped advisory locks: `pg_try_advisory_xact_lock(key BIGINT)`.

Let $K_k = \text{hashtext}(J_k.\text{name}) \in [-2^{63}, 2^{63}-1]$. The execution wrapper is defined as:

$$\mathcal{E}(J_k) = \begin{cases} 
\text{Execute } L_k, & \text{if } \text{pg\_try\_advisory\_xact\_lock}(K_k) = \text{TRUE} \\
\text{No-Op Short Circuit } (< 0.1\text{ms}), & \text{if } \text{pg\_try\_advisory\_xact\_lock}(K_k) = \text{FALSE}
\end{cases}$$

**Theorem 2 (Strict Concurrency Bounding)**: *Under the non-blocking advisory lock wrapper $\mathcal{E}(J_k)$, the maximum concurrent worker allocation for job $J_k$ is strictly bounded by 1, regardless of execution duration $D_k(t)$ or schedule frequency $\tau_k$*:

$$\max_{t \ge 0} N_k(t) \equiv 1 \quad \forall \; D_k(t) \in [0, \infty), \; \tau_k > 0$$

*Proof*: 
1. Suppose at timestamp $t_1$, worker $W_1$ invokes $\mathcal{E}(J_k)$ and acquires the lock $K_k$. The lock is held in PostgreSQL's shared lock hash table (`LockMethodLockHash`) for the duration of $W_1$'s transaction.
2. At timestamp $t_2 = t_1 + \tau_k < t_1 + D_k(t)$, worker $W_2$ is launched by `pg_cron` and executes $\text{pg\_try\_advisory\_xact\_lock}(K_k)$.
3. Because lock $K_k$ is held with `ExclusiveLock` mode by transaction $T_1$, PostgreSQL's lock manager immediately evaluates the non-blocking test, returns `FALSE` without queueing in `WaitEvent: Lock`, and terminates transaction $T_2$ within $< 0.1\text{ms}$.
4. $W_2$ releases its worker slot immediately back to the postmaster pool.
5. Thus, $N_k(t) \le 1$ for all $t$. Worker saturation is mathematically eradicated. $\blacksquare$

---

### Model 2.3: `cron.job_run_details` Catalog Bloat & Pruning Calculus

Let $J$ be the number of active recurring jobs in `cron.job`. The aggregate insertion rate of diagnostic records into `cron.job_run_details` is:

$$\Phi_{\text{runs}} = \sum_{j=1}^{J} \frac{1}{\tau_j} \quad [\text{records/second}]$$

For an environment with 5 jobs running every minute ($\tau = 60\text{s}$) and 2 jobs running every 10 seconds ($\tau = 10\text{s}$):

$$\Phi_{\text{runs}} = 5 \times \frac{1}{60} + 2 \times \frac{1}{10} = \frac{5}{60} + \frac{12}{60} = \frac{17}{60} \approx 0.2833\text{ records/s} \approx 24,480\text{ records/day}$$

Without automated pruning, after time $T$, the total row count $R(T)$ and storage volume $V(T)$ grow linearly:

$$R(T) = \Phi_{\text{runs}} \cdot T$$

$$V(T) = R(T) \cdot \left[ S_{\text{heap\_tuple}} + S_{\text{toast}} + \sum_{i=1}^{I} S_{\text{index\_entry}, i} \right]$$

Assuming average tuple size $S_{\text{heap}} \approx 250\text{ bytes}$ (with error strings) and 2 B-tree indexes (`jobid`, `start_time` totaling $\approx 100\text{ bytes}$):

$$V(180\text{ days}) = (24,480 \times 180) \times 350\text{ bytes} \approx 4,406,400 \times 350 \approx 1.54\text{ GB}$$

Because `DELETE` operations generate dead tuples, running a naive monolithic purge `DELETE FROM cron.job_run_details WHERE end_time < NOW() - INTERVAL '7 days'` deletes $4.2\text{ million}$ rows in a single transaction, holding row locks, pinning the autovacuum horizon, generating gigabytes of WAL, and causing replication lag spikes.

**Theorem 3 (Optimal Bounded Batch Pruning)**: *To bound lock hold time to $t_{\text{hold}} \le 50\text{ms}$ and prevent WAL write bursts, deletion must be partitioned into keyset batches of size $B^*$*:

$$B^* = \min \left( 5000, \; \left\lfloor \frac{\text{Rate}_{\text{IOPS}} \cdot t_{\text{target}}}{c_{\text{tuple\_delete}}} \right\rfloor \right)$$

Executing batch pruning daily with $B^* = 5,000$ bounds the maximum catalog footprint to a constant steady-state volume $V_{\text{steady}} = \Phi_{\text{runs}} \cdot T_{\text{retention}} \cdot 350\text{ bytes}$.

---

## 3. Autonomous TypeScript Guard Engine

Below is the complete, production-grade TypeScript guard engine `AgenticDatabaseCronGuardEngine`. It validates scheduled job definitions, inspects cron syntax, verifies advisory lock concurrency fencing, enforces explicit database targeting, detects dangerous non-transactional DDL in multi-statement jobs, verifies search-path hardening, and checks standby recovery guards.

```typescript
/**
 * AgenticDatabaseCronGuardEngine
 * Industrial-grade verification engine for PostgreSQL pg_cron scheduled jobs.
 * Enforces Tier 0-4 governance rules across migrations, DDL scripts, and runtime schedulers.
 */

export interface CronJobDefinition {
  jobName: string;
  schedule: string;
  command: string;
  database?: string;
  username?: string;
  active?: boolean;
}

export interface CronValidationViolation {
  ruleId: string;
  severity: 'FATAL' | 'CRITICAL' | 'WARNING';
  jobName: string;
  message: string;
  remediation: string;
}

export interface CronValidationReport {
  isValid: boolean;
  violations: CronValidationViolation[];
  auditedJobsCount: number;
  fixedCommands: Map<string, string>;
}

export class AgenticDatabaseCronGuardEngine {
  private readonly standardCronRegex = 
    /^(\*|([0-5]?\d)(-[0-5]?\d)?(\/[0-9]+)?(,[0-5]?\d)*)\s+(\*|(1?[0-9]|2[0-3])(-(1?[0-9]|2[0-3]))?(\/[0-9]+)?(,(1?[0-9]|2[0-3]))*)\s+(\*|([1-9]|[12][0-9]|3[01])(-([1-9]|[12][0-9]|3[01]))?(\/[0-9]+)?(,([1-9]|[12][0-9]|3[01]))*)\s+(\*|([1-9]|1[0-2])(-([1-9]|1[0-2]))?(\/[0-9]+)?(,([1-9]|1[0-2]))*)\s+(\*|([0-6])(-[0-6])?(\/[0-9]+)?(,[0-6])*)$/;

  /**
   * Audits a list of cron job registrations against production invariants.
   */
  public auditJobs(jobs: CronJobDefinition[], targetDatabaseName: string): CronValidationReport {
    const violations: CronValidationViolation[] = [];
    const fixedCommands = new Map<string, string>();

    let hasRetentionPruningJob = false;

    for (const job of jobs) {
      // 1. Validate Cron Syntax
      if (!this.isValidCronExpression(job.schedule)) {
        violations.push({
          ruleId: 'PGCRON_001_INVALID_SCHEDULE_SYNTAX',
          severity: 'FATAL',
          jobName: job.jobName,
          message: `Job '${job.jobName}' possesses invalid cron expression '${job.schedule}'.`,
          remediation: `Use valid 5-part cron syntax: 'minute hour day-of-month month day-of-week'.`
        });
      }

      // 2. Validate Database Target (Tier 0)
      if (!job.database || job.database.trim() === '' || job.database === 'postgres') {
        violations.push({
          ruleId: 'PGCRON_002_UNSPECIFIED_DATABASE_TARGET',
          severity: 'CRITICAL',
          jobName: job.jobName,
          message: `Job '${job.jobName}' does not specify an explicit application database target (defaults to '${job.database ?? 'postgres'}').`,
          remediation: `Use 'SELECT cron.schedule_in_database('${job.jobName}', '${job.schedule}', command, '${targetDatabaseName}')'.`
        });
      }

      // 3. Verify Concurrency Fencing via Advisory Locks (Tier 1)
      const hasAdvisoryLock = this.detectAdvisoryLock(job.command);
      if (!hasAdvisoryLock) {
        violations.push({
          ruleId: 'PGCRON_003_MISSING_ADVISORY_LOCK_FENCE',
          severity: 'CRITICAL',
          jobName: job.jobName,
          message: `Job '${job.jobName}' lacks non-blocking advisory lock fencing (pg_try_advisory_xact_lock). Overlapping runs will exhaust background workers.`,
          remediation: `Wrap command: DO $$ BEGIN IF pg_try_advisory_xact_lock(hashtext('${job.jobName}')) THEN ... END IF; END $$;`
        });

        // Generate auto-remediation command
        const fixed = this.wrapWithAdvisoryLock(job.jobName, job.command);
        fixedCommands.set(job.jobName, fixed);
      }

      // 4. Check for Non-Transactional DDL inside Transactions (Tier 3)
      if (this.containsIllegalTransactionalDDL(job.command)) {
        violations.push({
          ruleId: 'PGCRON_004_NON_TRANSACTIONAL_DDL_CONFLICT',
          severity: 'FATAL',
          jobName: job.jobName,
          message: `Job '${job.jobName}' combines VACUUM or CREATE INDEX CONCURRENTLY with multi-statement transactions, causing SQLSTATE 25001.`,
          remediation: `Isolate VACUUM / CREATE INDEX CONCURRENTLY into dedicated standalone single-statement jobs.`
        });
      }

      // 5. Check search_path Hardening (Tier 2 - CVE-2018-1058)
      if (!this.isSearchPathHardened(job.command)) {
        violations.push({
          ruleId: 'PGCRON_005_UNHARDENED_SEARCH_PATH',
          severity: 'WARNING',
          jobName: job.jobName,
          message: `Job '${job.jobName}' does not explicitly pin search_path, exposing background workers to search-path hijacking.`,
          remediation: `Prepend execution with 'SET search_path = app_schema, pg_catalog, pg_temp;' or fully schema-qualify all objects.`
        });
      }

      // 6. Check Standby Recovery Guards (Tier 3)
      if (!this.hasStandbyRecoveryGuard(job.command) && this.isMutatingCommand(job.command)) {
        violations.push({
          ruleId: 'PGCRON_006_MISSING_STANDBY_RECOVERY_GUARD',
          severity: 'WARNING',
          jobName: job.jobName,
          message: `Job '${job.jobName}' performs mutations but lacks recovery guards. If executed on a read replica, it will crash-loop with SQLSTATE 25006.`,
          remediation: `Prepend logic with 'IF NOT pg_is_in_recovery() THEN ... END IF;' inside a PL/pgSQL block.`
        });
      }

      // Track if retention pruning job exists
      if (job.command.includes('cron.job_run_details') && job.command.toUpperCase().includes('DELETE')) {
        hasRetentionPruningJob = true;
      }
    }

    // 7. Check for Catalog Retention Policy (Tier 4)
    if (!hasRetentionPruningJob && jobs.length > 0) {
      violations.push({
        ruleId: 'PGCRON_007_MISSING_RETENTION_PRUNING_JOB',
        severity: 'CRITICAL',
        jobName: '__GLOBAL__',
        message: `No automated maintenance job exists to prune 'cron.job_run_details'. The table will bloat indefinitely.`,
        remediation: `Schedule daily maintenance: SELECT cron.schedule('prune_cron_run_details', '0 4 * * *', 'DELETE FROM cron.job_run_details WHERE end_time < NOW() - INTERVAL ''7 days''');`
      });
    }

    return {
      isValid: violations.filter(v => v.severity === 'FATAL' || v.severity === 'CRITICAL').length === 0,
      violations,
      auditedJobsCount: jobs.length,
      fixedCommands
    };
  }

  private isValidCronExpression(schedule: string): boolean {
    const trimmed = schedule.trim();
    if (trimmed === '@hourly') return true;
    if (trimmed === '@daily') return true;
    if (trimmed === '@weekly') return true;
    if (trimmed === '@monthly') return true;
    if (trimmed === '@yearly') return true;
    if (trimmed === '@reboot') return true;
    return this.standardCronRegex.test(trimmed);
  }

  private detectAdvisoryLock(command: string): boolean {
    const lower = command.toLowerCase();
    return (
      lower.includes('pg_try_advisory_xact_lock') ||
      lower.includes('pg_try_advisory_lock')
    );
  }

  private containsIllegalTransactionalDDL(command: string): boolean {
    const upper = command.toUpperCase();
    const hasVacuumOrConcurrentIndex = 
      upper.includes('VACUUM') ||
      (upper.includes('CREATE') && upper.includes('INDEX') && upper.includes('CONCURRENTLY')) ||
      (upper.includes('REINDEX') && upper.includes('CONCURRENTLY'));

    const hasMultiStatement = command.includes(';') && command.trim().split(';').filter(s => s.trim().length > 0).length > 1;
    const hasExplicitTransaction = upper.includes('BEGIN') || upper.includes('START TRANSACTION');

    return hasVacuumOrConcurrentIndex && (hasMultiStatement || hasExplicitTransaction);
  }

  private isSearchPathHardened(command: string): boolean {
    const lower = command.toLowerCase();
    return lower.includes('set search_path') || lower.includes('set local search_path');
  }

  private hasStandbyRecoveryGuard(command: string): boolean {
    const lower = command.toLowerCase();
    return lower.includes('pg_is_in_recovery()');
  }

  private isMutatingCommand(command: string): boolean {
    const upper = command.toUpperCase();
    return (
      upper.includes('INSERT') ||
      upper.includes('UPDATE') ||
      upper.includes('DELETE') ||
      upper.includes('DROP') ||
      upper.includes('ALTER') ||
      upper.includes('TRUNCATE') ||
      upper.includes('REFRESH MATERIALIZED VIEW')
    );
  }

  public wrapWithAdvisoryLock(jobName: string, rawCommand: string): string {
    const escapedCommand = rawCommand.replace(/'/g, "''");
    return `DO $$
BEGIN
    -- Guard against execution on read-only streaming replicas
    IF pg_is_in_recovery() THEN
        RETURN;
    END IF;

    -- Non-blocking advisory lock fencing to prevent overlapping workers
    IF pg_try_advisory_xact_lock(hashtext('${jobName}')) THEN
        -- Harden search_path against CVE-2018-1058
        SET LOCAL search_path = public, pg_catalog, pg_temp;
        
        -- Execute scheduled workload
        EXECUTE '${escapedCommand}';
    ELSE
        RAISE NOTICE 'pg_cron job % skipped: previous execution still in progress', '${jobName}';
    END IF;
END $$;`;
  }
}
```

---

## 4. Cross-Runtime Telemetry Sentinels

### 4.1 Go (`jackc/pgx/v5`) Production Sentinel

```go
package cronwatcher

import (
	"context"
	"fmt"
	"hash/fnv"
	"log"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// CronJobStatus represents the telemetry snapshot of a pg_cron scheduled job.
type CronJobStatus struct {
	JobID          int64
	JobName        string
	Schedule       string
	Database       string
	Active         bool
	LastRunStatus  string
	LastStartTime  time.Time
	LastReturnMsg  string
	DurationMillis int64
}

// PgCronSentinel audits and monitors in-database cron jobs.
type PgCronSentinel struct {
	pool *pgxpool.Pool
}

func NewPgCronSentinel(pool *pgxpool.Pool) *PgCronSentinel {
	return &PgCronSentinel{pool: pool}
}

// AuditJobHealth inspects cron.job and cron.job_run_details for failed or stalled runs.
func (s *PgCronSentinel) AuditJobHealth(ctx context.Context) ([]CronJobStatus, error) {
	query := `
		SELECT 
			j.jobid,
			j.jobname,
			j.schedule,
			j.database,
			j.active,
			COALESCE(r.status, 'never_run') AS last_status,
			COALESCE(r.start_time, '1970-01-01 00:00:00Z') AS start_time,
			COALESCE(r.return_message, '') AS return_message,
			COALESCE(EXTRACT(EPOCH FROM (r.end_time - r.start_time)) * 1000, 0)::BIGINT AS duration_ms
		FROM cron.job j
		LEFT JOIN LATERAL (
			SELECT status, start_time, end_time, return_message
			FROM cron.job_run_details
			WHERE jobid = j.jobid
			ORDER BY runid DESC
			LIMIT 1
		) r ON true
		ORDER BY j.jobid ASC;
	`

	rows, err := s.pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to query pg_cron status: %w", err)
	}
	defer rows.Close()

	var statuses []CronJobStatus
	for rows.Next() {
		var s CronJobStatus
		if err := rows.Scan(
			&s.JobID, &s.JobName, &s.Schedule, &s.Database, &s.Active,
			&s.LastRunStatus, &s.LastStartTime, &s.LastReturnMsg, &s.DurationMillis,
		); err != nil {
			return nil, fmt.Errorf("failed to scan pg_cron row: %w", err)
		}

		if s.LastRunStatus == "failed" {
			log.Printf("⚠️ [PG_CRON_ALERT] Job '%s' (ID %d) failed on DB '%s': %s",
				s.JobName, s.JobID, s.Database, s.LastReturnMsg)
		}
		statuses = append(statuses, s)
	}

	return statuses, rows.Err()
}

// ScheduleSafeJob schedules a job with mandatory advisory lock fencing and DB target.
func (s *PgCronSentinel) ScheduleSafeJob(
	ctx context.Context,
	jobName string,
	schedule string,
	sqlCommand string,
	targetDB string,
) (int64, error) {
	// 1. Generate 64-bit lock hash
	hasher := fnv.New64a()
	hasher.Write([]byte(jobName))
	lockKey := int64(hasher.Sum64())

	// 2. Wrap command in PL/pgSQL advisory lock fence
	fencedCommand := fmt.Sprintf(`
DO $$
BEGIN
    IF pg_is_in_recovery() THEN
        RETURN;
    END IF;

    IF pg_try_advisory_xact_lock(%d) THEN
        SET LOCAL search_path = public, pg_catalog, pg_temp;
        EXECUTE %s;
    ELSE
        RAISE NOTICE 'pg_cron job %s skipped: previous run still in flight';
    END IF;
END $$;
	`, lockKey, quoteLiteral(sqlCommand), jobName)

	// 3. Register via cron.schedule_in_database
	var jobID int64
	scheduleQuery := `SELECT cron.schedule_in_database($1, $2, $3, $4);`
	err := s.pool.QueryRow(ctx, scheduleQuery, jobName, schedule, fencedCommand, targetDB).Scan(&jobID)
	if err != nil {
		return 0, fmt.Errorf("failed to schedule safe pg_cron job '%s': %w", jobName, err)
	}

	log.Printf("✅ Scheduled pg_cron job '%s' (ID: %d) on DB '%s' with lock key %d",
		jobName, jobID, targetDB, lockKey)
	return jobID, nil
}

// PruneRunDetailsDaily removes diagnostic rows older than retentionDays in bounded batches.
func (s *PgCronSentinel) PruneRunDetailsDaily(ctx context.Context, retentionDays int, batchSize int) (int64, error) {
	pruneQuery := `
		WITH candidates AS (
			SELECT runid 
			FROM cron.job_run_details 
			WHERE end_time < NOW() - ($1 || ' days')::INTERVAL
			ORDER BY runid ASC
			LIMIT $2
		)
		DELETE FROM cron.job_run_details
		WHERE runid IN (SELECT runid FROM candidates);
	`
	tag, err := s.pool.Exec(ctx, pruneQuery, fmt.Sprintf("%d", retentionDays), batchSize)
	if err != nil {
		return 0, fmt.Errorf("failed to prune cron.job_run_details: %w", err)
	}
	return tag.RowsAffected(), nil
}

func quoteLiteral(s string) string {
	// Simple SQL dollar quoting for script containment
	return fmt.Sprintf("$cmd$%s$cmd$", s)
}
```

---

### 4.2 TypeScript (`drizzle-orm` / `pg`) Telemetry Sentinel

```typescript
import { Pool, PoolClient } from 'pg';

export interface CronTelemetryEvent {
  jobId: number;
  jobName: string;
  status: 'succeeded' | 'failed' | 'running';
  runDurationMs: number;
  returnMessage: string;
  timestamp: Date;
}

export class PgCronTelemetryMonitor {
  private readonly pool: Pool;

  constructor(pool: Pool) {
    this.pool = pool;
  }

  /**
   * Continuous telemetry check asserting zero crashed workers and bounded history size.
   */
  public async collectTelemetry(): Promise<CronTelemetryEvent[]> {
    const client: PoolClient = await this.pool.connect();
    try {
      // 1. Audit active background worker allocation
      const workerRes = await client.query<{ current_workers: number; max_workers: number }>(`
        SELECT 
          (SELECT count(*)::int FROM pg_stat_activity WHERE backend_type LIKE '%worker%') as current_workers,
          current_setting('max_worker_processes')::int as max_workers;
      `);

      const { current_workers, max_workers } = workerRes.rows[0];
      const utilization = current_workers / max_workers;
      if (utilization >= 0.85) {
        console.warn(`🚨 [PG_CRON_WARNING] Background worker saturation critical: ${current_workers}/${max_workers} (${(utilization * 100).toFixed(1)}%)`);
      }

      // 2. Fetch latest execution details
      const detailsRes = await client.query<any>(`
        SELECT 
          r.jobid,
          j.jobname,
          r.status,
          COALESCE(EXTRACT(EPOCH FROM (r.end_time - r.start_time)) * 1000, 0)::int as duration_ms,
          COALESCE(r.return_message, '') as return_msg,
          r.start_time
        FROM cron.job_run_details r
        JOIN cron.job j ON j.jobid = r.jobid
        WHERE r.start_time >= NOW() - INTERVAL '15 minutes'
        ORDER BY r.runid DESC;
      `);

      return detailsRes.rows.map(row => ({
        jobId: row.jobid,
        jobName: row.jobname,
        status: row.status,
        runDurationMs: row.duration_ms,
        returnMessage: row.return_msg,
        timestamp: row.start_time
      }));
    } finally {
      client.release();
    }
  }

  /**
   * Executes bounded batch cleanup of history logs.
   */
  public async executeRetentionPurge(retentionDays: number = 7, batchSize: number = 2500): Promise<number> {
    const client = await this.pool.connect();
    try {
      const res = await client.query<{ deleted_count: number }>(`
        WITH to_delete AS (
          SELECT runid 
          FROM cron.job_run_details 
          WHERE end_time < NOW() - ($1 || ' days')::INTERVAL
          ORDER BY runid ASC
          LIMIT $2
        ),
        deleted AS (
          DELETE FROM cron.job_run_details
          WHERE runid IN (SELECT runid FROM to_delete)
          RETURNING runid
        )
        SELECT count(*)::int as deleted_count FROM deleted;
      `, [retentionDays, batchSize]);

      return res.rows[0]?.deleted_count ?? 0;
    } finally {
      client.release();
    }
  }
}
```

---

### 4.3 Python (`asyncpg`) Telemetry Sentinel

```python
import asyncio
import logging
from typing import List, Dict, Any
import asyncpg

logger = logging.getLogger("pg_cron_sentinel")

class AsyncPgCronSentinel:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def check_standby_safety(self) -> bool:
        """Asserts whether current connection is connected to primary writer."""
        async with self.pool.acquire() as conn:
            is_recovery = await conn.fetchval("SELECT pg_is_in_recovery();")
            return not is_recovery

    async def audit_recent_failures(self, window_minutes: int = 30) -> List[Dict[str, Any]]:
        """Queries for jobs that failed within the specified time window."""
        query = """
            SELECT 
                j.jobid,
                j.jobname,
                j.database,
                r.runid,
                r.status,
                r.return_message,
                r.start_time,
                r.end_time
            FROM cron.job_run_details r
            JOIN cron.job j ON j.jobid = r.jobid
            WHERE r.status = 'failed'
              AND r.start_time >= NOW() - ($1 || ' minutes')::INTERVAL
            ORDER BY r.runid DESC;
        """
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query, str(window_minutes))
            return [dict(row) for row in rows]

    async def purge_stale_history(self, retention_days: int = 7, limit: int = 5000) -> int:
        """Executes bounded batch pruning of cron.job_run_details."""
        query = """
            WITH batch AS (
                SELECT runid 
                FROM cron.job_run_details 
                WHERE end_time < NOW() - ($1 || ' days')::INTERVAL 
                ORDER BY runid ASC 
                LIMIT $2
            )
            DELETE FROM cron.job_run_details 
            WHERE runid IN (SELECT runid FROM batch);
        """
        async with self.pool.acquire() as conn:
            status = await conn.execute(query, str(retention_days), limit)
            # Format: 'DELETE <count>'
            deleted = int(status.split()[-1])
            if deleted > 0:
                logger.info("Purged %d stale pg_cron history rows.", deleted)
            return deleted
```

---

### 4.4 Rust (`tokio-postgres`) Sentinel

```rust
use std::time::Duration;
use tokio_postgres::{Client, Error};

pub struct RustCronWatchdog {
    client: Client,
}

impl RustCronWatchdog {
    pub fn new(client: Client) -> Self {
        Self { client }
    }

    /// Verifies that pg_cron extension is loaded and active.
    pub async fn verify_preload_installed(&self) -> Result<bool, Error> {
        let row = self
            .client
            .query_one(
                "SELECT count(*)::int as cnt FROM pg_extension WHERE extname = 'pg_cron';",
                &[],
            )
            .await?;
        let count: i32 = row.get("cnt");
        Ok(count > 0)
    }

    /// Audits active worker headroom and warns if worker capacity is saturated.
    pub async fn assert_worker_headroom(&self) -> Result<(i32, i32), Error> {
        let row = self
            .client
            .query_one(
                "SELECT 
                    (SELECT count(*)::int FROM pg_stat_activity WHERE backend_type LIKE '%worker%') as active_workers,
                    current_setting('max_worker_processes')::int as max_workers;",
                &[],
            )
            .await?;

        let active: i32 = row.get("active_workers");
        let max: i32 = row.get("max_workers");

        if active >= (max * 8 / 10) {
            eprintln!(
                "⚠️ [PG_CRON_HEADROOM] Active background workers ({}/{}) exceed 80% threshold",
                active, max
            );
        }

        Ok((active, max))
    }
}
```

---

## 5. Finite-State Machine (FSM) Lifecycle

The execution lifecycle of an enterprise-grade in-database scheduled task follows a 6-state finite-state machine (FSM). Redundant overlapping executions short-circuit cleanly at the `LOCK_ACQUISITION` phase, ensuring strict $O(1)$ constant memory and zero thread starvation.

```
       ┌───────────────────────────────────────────────────────────┐
       │                   STATE 1: IDLE_SCHEDULED                │
       │     pg_cron Launcher scans cron.job catalog table         │
       └─────────────────────────────┬─────────────────────────────┘
                                     │ Timestamp match
                                     ▼
       ┌───────────────────────────────────────────────────────────┐
       │             STATE 2: PRE_FLIGHT_VALIDATION                │
       │  Assert current_database() == target & NOT in_recovery()  │
       └──────────────┬─────────────────────────────┬──────────────┘
                      │ Pass                        │ Standby / DB Mismatch
                      ▼                             ▼
       ┌──────────────────────────────┐     ┌───────────────────────┐
       │   STATE 3: LOCK_ACQUISITION  │     │   TERMINATE_NO_OP     │
       │  pg_try_advisory_xact_lock() │     │ Return with 0 changes │
       └───────┬──────────────┬───────┘     └───────────────────────┘
               │ Acquired     │ Contended (Previous run in flight)
               ▼              ▼
       ┌───────────────┐  ┌────────────────────────────────────────┐
       │   STATE 4:    │  │          SKIP_WITH_NOTICE              │
       │  TRANSACTION  │  │ Log NOTICE & abort early in < 0.1ms    │
       │   EXECUTION   │  └────────────────────────────────────────┘
       └───────┬───────┘
               │ Complete / Error
               ▼
       ┌──────────────────────────────┐
       │  STATE 5: STATUS_RECORDING   │
       │ Append cron.job_run_details  │
       └──────────────┬───────────────┘
                      │
                      ▼
       ┌──────────────────────────────┐
       │  STATE 6: RETENTION_PRUNING  │
       │ Bounded batch purge older >7d│
       └──────────────────────────────┘
```

### FSM State Transition Table

| Current State | Event / Condition | Target State | Operational Action |
| :--- | :--- | :--- | :--- |
| **`IDLE_SCHEDULED`** | Wall-clock matches cron specification | **`PRE_FLIGHT_VALIDATION`** | Launcher spawns worker; verifies target connection. |
| **`PRE_FLIGHT_VALIDATION`** | `pg_is_in_recovery() == TRUE` | **`TERMINATE_NO_OP`** | Immediately exits to prevent read-only replica crash loop (`SQLSTATE 25006`). |
| **`PRE_FLIGHT_VALIDATION`** | `pg_is_in_recovery() == FALSE` | **`LOCK_ACQUISITION`** | Evaluates `pg_try_advisory_xact_lock(hashtext(job_name))`. |
| **`LOCK_ACQUISITION`** | Lock returned `FALSE` | **`SKIP_WITH_NOTICE`** | Emits NOTICE: previous job still running; releases worker slot ($< 0.1\text{ms}$). |
| **`LOCK_ACQUISITION`** | Lock returned `TRUE` | **`TRANSACTION_EXECUTION`** | Pins `search_path`, executes schema-qualified application payload. |
| **`TRANSACTION_EXECUTION`** | Payload succeeds or raises exception | **`STATUS_RECORDING`** | Writes execution duration, status (`succeeded` / `failed`), and return text. |
| **`STATUS_RECORDING`** | Run count exceeds batch threshold | **`RETENTION_PRUNING`** | Executes bounded batch purge of run details older than 7 days. |

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Gates

To guarantee zero operational incidents, autonomous agents and CI/CD pipelines must verify these 7 machine-enforced SQL gates before certifying database migrations or scheduled jobs as complete:

| Gate Number | Audit Check Description | Machine-Verifiable SQL Query | Pass/Fail Criterion |
| :---: | :--- | :--- | :--- |
| **Gate 1** | **Zero Database Target Mismatches** | `SELECT count(*) FROM cron.job WHERE database != current_database() AND database = 'postgres';` | **FAIL if count > 0**: Jobs must explicitly target the application database. |
| **Gate 2** | **100% Advisory Lock Concurrency Fencing** | `SELECT count(*) FROM cron.job WHERE command NOT LIKE '%pg_try_advisory%lock%';` | **FAIL if count > 0**: Every job must include non-blocking advisory lock fencing. |
| **Gate 3** | **100% Schema-Qualified / Hardened Commands** | `SELECT count(*) FROM cron.job WHERE command NOT LIKE '%search_path%' AND command NOT LIKE '%.%';` | **FAIL if count > 0**: Commands must be schema-qualified to prevent CVE-2018-1058. |
| **Gate 4** | **Zero Illegal Transactional DDL** | `SELECT count(*) FROM cron.job WHERE (command ILIKE '%VACUUM%' OR command ILIKE '%CREATE INDEX CONCURRENTLY%') AND (command LIKE '%;%');` | **FAIL if count > 0**: Multi-statement transactions cannot include `VACUUM` or concurrent DDL. |
| **Gate 5** | **Standby Replica Recovery Guards** | `SELECT count(*) FROM cron.job WHERE (command ILIKE '%INSERT%' OR command ILIKE '%UPDATE%' OR command ILIKE '%DELETE%') AND command NOT LIKE '%pg_is_in_recovery%';` | **FAIL if count > 0**: Mutating jobs must check `pg_is_in_recovery()` before running. |
| **Gate 6** | **Mandatory Catalog Retention Pruning Job** | `SELECT count(*) FROM cron.job WHERE command ILIKE '%DELETE FROM cron.job_run_details%';` | **FAIL if count == 0**: System must contain a recurring purge task for `job_run_details`. |
| **Gate 7** | **Zero Recent Unresolved Cron Failures** | `SELECT count(*) FROM cron.job_run_details WHERE status = 'failed' AND start_time >= NOW() - INTERVAL '1 hour';` | **FAIL if count > 0**: Review error logs and remediate root causes of failing jobs. |
