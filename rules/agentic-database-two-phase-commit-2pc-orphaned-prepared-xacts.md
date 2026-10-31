---
description: PostgreSQL Two-Phase Commit (2PC), PREPARE TRANSACTION / COMMIT PREPARED / ROLLBACK PREPARED invariants, orphaned prepared transactions (pg_prepared_xacts), in-doubt commit resolution, distributed coordinator crash recovery, xmin vacuum horizon pinning, emergency XID wraparound defense, max_prepared_transactions sizing, PgBouncer pool_mode bypass, and resilient 2PC vs Saga Outbox patterns across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, psycopg3), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{2pc,two_phase,twophase,prepared,coordinator,xa,distributed_tx,saga,outbox,db,postgres}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/services/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Two-Phase Commit (2PC), Orphaned Prepared Transactions, In-Doubt Commit Resolution & $x_{\min}$ Horizon Freezing Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design distributed transactional systems, multi-database atomicity, cross-shard coordination, XA protocols, or foreign table mutations across PostgreSQL (10–17+) in Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "In-Doubt Prepared Transaction & Indefinite Lock Retention Disaster" (where client disconnects, timeouts, or network partitions abandon transactions in `pg_prepared_xacts` holding table and row locks indefinitely across server reboots), the "Cluster-Wide $x_{\min}$ Vacuum Horizon Freezing & XID Wraparound Apocalypse" (where a single orphaned prepared transaction pins the global vacuum horizon, blocking dead tuple reclamation across every table and driving the cluster into emergency stop-the-world wraparound shutdowns), the "Unconfigured `max_prepared_transactions = 0` Runtime Crash (`SQLSTATE 0A000`)" (where executing `PREPARE TRANSACTION` fails immediately because PostgreSQL defaults to disabling two-phase commits), the "PgBouncer Transaction Pooling Desynchronization Trap" (where issuing 2PC commands over transaction-mode connection poolers corrupts session state or rejects prepared verbs), the "Coordinator Split-Brain & One-Sided Commit Anomaly" (where the coordinator crashes between committing Participant 1 and Participant 2 without a durable Write-Ahead Log, permanently shattering distributed ACID consistency), and the "Premature Janitor Rollback Race" (where naive cleanup scripts roll back slow-committing participants while the coordinator is actively finishing on sibling shards) by establishing a strict 5-Tier Two-Phase Commit Governance Ladder, structured Global Transaction Identifier (GID) taxonomies, coordinator WAL journaling, autonomous `pg_prepared_xacts` telemetry sentinels, and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Two-Phase Commit Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL provides native engine support for Two-Phase Commit (2PC) via SQL commands `PREPARE TRANSACTION 'gid'`, `COMMIT PREPARED 'gid'`, and `ROLLBACK PREPARED 'gid'`. When an application executes `PREPARE TRANSACTION`, the database engine performs all transaction commit validations (evaluating deferred constraints, generating WAL records for modified pages, and flushing transaction status to disk in the `$PGDATA/pg_twophase/` directory).

Once prepared, the transaction is **decoupled from the client connection**. Unlike ordinary transactions which automatically abort when the client TCP connection terminates, a prepared transaction **persists indefinitely across client crashes, connection drops, and even full database server restarts**. It remains active in shared memory and on disk until explicitly resolved via `COMMIT PREPARED` or `ROLLBACK PREPARED`.

While 2PC provides a theoretical foundation for atomic distributed transactions across multiple heterogeneous systems, its operational consequences in real-world environments are catastrophic when managed naively by autonomous coding agents:

### The 6 Two-Phase Commit Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                               THE 6 TWO-PHASE COMMIT CATASTROPHES                                  |
+------------------------------------+---------------------------------------------------------------+
| 1. In-Doubt Prepared Transaction & | Coordinator prepares tx on DB 1 & DB 2; network drops before  |
|    Indefinite Lock Retention       | COMMIT; DB client disconnects; prepared tx persists in         |
|                                    | pg_prepared_xacts holding AccessExclusiveLock indefinitely.   |
+------------------------------------+---------------------------------------------------------------+
| 2. Global xmin Horizon Freezing &  | Orphaned prepared transaction pins cluster xmin horizon;      |
|    XID Wraparound Shutdown         | autovacuum cannot clean dead tuples on ANY table; DB hits     |
|                                    | 2^31 wraparound emergency shutdown requiring offline recovery.|
+------------------------------------+---------------------------------------------------------------+
| 3. Unconfigured max_prepared_tx=0  | Agent generates 2PC code on standard PostgreSQL; engine has   |
|    Runtime Crash (SQLSTATE 0A000)  | max_prepared_transactions=0 by default; first query crashes   |
|                                    | with "prepared transactions are disabled" in production.     |
+------------------------------------+---------------------------------------------------------------+
| 4. PgBouncer Transaction Mode      | Agent issues PREPARE TRANSACTION over transaction-mode pool;  |
|    State Desynchronization Trap    | PgBouncer disassociates backend; transaction block unclosed;   |
|                                    | subsequent queries inherit contaminated session or fail.      |
+------------------------------------+---------------------------------------------------------------+
| 5. Coordinator Split-Brain &       | Coordinator commits DB 1, then crashes before committing DB 2;|
|    One-Sided Commit Anomaly        | coordinator has no persistent WAL; DB 1 committed, DB 2 dead;|
|                                    | distributed ledger corrupted with permanent state divergence. |
+------------------------------------+---------------------------------------------------------------+
| 6. Premature Janitor Rollback Race | Janitor script blindly executes ROLLBACK PREPARED on tx > 10s;|
|    (False-Abort Data Divergence)   | coordinator was delayed by 12s GC pause but commits DB 1;     |
|                                    | Janitor rolls back DB 2; distributed atomicity violated.      |
+------------------------------------+---------------------------------------------------------------+
```

To eliminate these catastrophic failure modes, autonomous agents must enforce the **5-Tier Two-Phase Commit Governance Ladder**:

```
+----------------------------------------------------------------------------------------------------+
|                               THE 5-TIER 2PC GOVERNANCE LADDER                                     |
+------------------------------------+---------------------------------------------------------------+
| Tier 0: Architectural Pre-emption  | Enforce Distributed Saga + Transactional Outbox by default;   |
|         (Saga vs 2PC Gate)         | strictly limit 2PC to homogeneous database sharding or strict |
|                                    | statutory ACID regulatory requirements.                       |
+------------------------------------+---------------------------------------------------------------+
| Tier 1: Infrastructure Invariants  | Ensure max_prepared_transactions = max_connections in conf;  |
|         & Direct Session Topology  | Route 2PC connections exclusively through direct port 5432    |
|                                    | or session-mode poolers; ban pool_mode = transaction.         |
+------------------------------------+---------------------------------------------------------------+
| Tier 2: Monotonic Global Identifier| Mandate structured GIDs: app:service:coord_uuid:epoch:shard;  |
|         (GID) Taxonomy             | parseable, regex-validated, bounded <= 200 bytes, traceable.  |
+------------------------------------+---------------------------------------------------------------+
| Tier 3: Coordinator WAL Journaling | Coordinator MUST append COMMITTING decision to durable local  |
|         & Two-Phase State Machine  | storage BEFORE issuing Phase 2 COMMIT PREPARED to any node.   |
+------------------------------------+---------------------------------------------------------------+
| Tier 4: Autonomous Telemetry &     | Continuous pg_prepared_xacts monitoring; age > 30s alert;     |
|         In-Doubt Janitor Sentinel  | age > 60s coordinated reconciliation; auto-rollback fenced.   |
+------------------------------------+---------------------------------------------------------------+
```

---

## 2. The 6 Two-Phase Commit Failure Modes & Root-Cause Analysis

### 2.1 The In-Doubt Prepared Transaction & Indefinite Lock Retention Disaster

When a client application executes:
```sql
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 42;
PREPARE TRANSACTION 'tx_transfer_42_100';
```
PostgreSQL completes the prepare phase and detaches the transaction from the backend session. If the application server crashes, reboots, or encounters a TCP socket timeout before sending `COMMIT PREPARED 'tx_transfer_42_100'`, the PostgreSQL backend process cleans up its connection and terminates.

However, the transaction **remains alive in the engine**. The row-level exclusive lock on `accounts WHERE id = 42` remains held. Any subsequent request attempting to update account 42 will block waiting for `ExclusiveLock`. As new requests arrive, they pile up in PostgreSQL's lock queue, consuming database connections until `max_connections` is saturated and the entire application platform collapses in a cascading connection pool outage.

### 2.2 The Global $x_{\min}$ Vacuum Horizon Freezing & XID Wraparound Apocalypse

Every prepared transaction in `pg_prepared_xacts` holds an assigned Transaction ID ($x_{\text{id}}$). Because this transaction is uncommitted, the database engine cannot determine whether its modifications will become visible or be discarded. Consequently, PostgreSQL must pin the cluster-wide transaction snapshot horizon ($x_{\min}$) to the oldest active transaction, which is now the orphaned prepared transaction.

Under PostgreSQL's Multi-Version Concurrency Control (MVCC), when a row is updated or deleted, the old tuple is marked dead but remains on disk. The background worker `autovacuum` sweeps tables to reclaim dead tuples, but it **can only remove dead tuples whose `xmax` is older than the cluster $x_{\min}$**.

With $x_{\min}$ frozen by an orphaned prepared transaction:
1. `autovacuum` runs continuously across all tables but reclaims **zero** dead tuples.
2. Tables and indexes balloon to multi-gigabyte bloat, degrading cache hit ratios and sequential scan performance.
3. The database transaction counter continues to advance with normal application traffic.
4. The age of `pg_database.datfrozenxid` reaches the safety threshold ($2 \times 10^9 - 10^7$ transactions), triggering PostgreSQL emergency wraparound warnings:
   ```
   WARNING: database "prod" must be vacuumed within 10000000 transactions
   HINT: To avoid a database shutdown, execute a full-database VACUUM in analyze mode.
   ```
5. When the limit is reached, PostgreSQL forces an immediate, unpreventable stop-the-world shutdown:
   ```
   PANIC: out of shared memory
   FATAL: database is not accepting commands to avoid wraparound data loss in database "prod"
   ```
   Recovering from this requires taking the database completely offline and booting in single-user maintenance mode (`postgres --single`) to manually identify and roll back the prepared transaction.

### 2.3 The Unconfigured `max_prepared_transactions = 0` Runtime Crash (SQLSTATE `0A000`)

By default, PostgreSQL ships with:
```ini
# postgresql.conf
max_prepared_transactions = 0
```
This configuration is intentional by the PostgreSQL core team to protect administrators from accidental 2PC leaks. When an autonomous agent attempts to execute:
```sql
PREPARE TRANSACTION 'order_tx_987';
```
PostgreSQL returns a fatal error:
```
ERROR: prepared transactions are disabled (SQLSTATE 0A000: feature_not_supported)
HINT: Set "max_prepared_transactions" to a non-zero value.
```
Furthermore, `max_prepared_transactions` is a server-start parameter; it **cannot** be changed at runtime via `SET` or `pg_reload_conf()`. It requires a full database restart. Additionally, each prepared transaction consumes space in the shared memory lock table:
$$\text{Total Lock Slots} = \text{max\_locks\_per\_transaction} \times (\text{max\_connections} + \text{max\_prepared\_transactions})$$
If an agent configures `max_prepared_transactions = 1000` without increasing shared memory and kernel IPC parameters, PostgreSQL will fail to start with `could not create shared memory segment`.

### 2.4 The PgBouncer Transaction Pooling Desynchronization Trap

In high-concurrency microservices, PgBouncer is frequently deployed in `pool_mode = transaction`. In this mode, PgBouncer assigns a server connection to a client for the duration of a single transaction (`BEGIN` to `COMMIT`/`ROLLBACK`).

When an application executes `PREPARE TRANSACTION 'gid'`:
1. The server completes the prepare phase and responds with `CommandComplete` (`PREPARE TRANSACTION`).
2. To PgBouncer, the transaction has ended because the server connection returns to an idle transaction status (`ReadyForQuery`, status indicator `I`).
3. PgBouncer immediately reassigns that server connection to an entirely different application client.
4. When the original client later attempts to execute `COMMIT PREPARED 'gid'`, PgBouncer might route that command to a completely different backend server connection that has never heard of `'gid'`.
5. Worse, if the prepared transaction left session-level GUC parameters or temp state, the next client using that server connection suffers cross-tenant contamination.
6. Therefore, **2PC operations must strictly bypass transaction-pooling PgBouncer instances**, connecting either directly to PostgreSQL port 5432 or through a dedicated session-mode pool (`pool_mode = session`).

### 2.5 The Coordinator Split-Brain & One-Sided Commit Anomaly

Consider a distributed transfer between Shard 1 (Account A debit) and Shard 2 (Account B credit):
```
Client ----> Coordinator ----Phase 1 (PREPARE)----> Shard 1 (OK)
                   |
                   +---------Phase 1 (PREPARE)----> Shard 2 (OK)
                   |
                   +---------Phase 2 (COMMIT)-----> Shard 1 (Committed!)
                   |
             [COORDINATOR CRASHES]
```
If the coordinator crashes or loses power after committing Shard 1 but before issuing `COMMIT PREPARED` to Shard 2:
- Shard 1 has debited Account A permanently.
- Shard 2 still holds the prepared transaction crediting Account B.
- When the coordinator restarts, if it does not have a durable local Write-Ahead Log (WAL) recording that the distributed transaction reached the `COMMITTING` state, it cannot know whether Phase 2 succeeded. If it naively issues `ROLLBACK` on recovery, Account A lost money and Account B never received it. Distributed ACID consistency is permanently shattered.

### 2.6 The Premature Janitor Rollback Race (False-Abort Data Divergence)

Engineering teams aware of the $x_{\min}$ pinning danger often write background cron jobs or janitor scripts:
```sql
-- DANGEROUS NAIVE JANITOR
SELECT format('ROLLBACK PREPARED %I;', gid)
FROM pg_prepared_xacts
WHERE prepared < now() - interval '10 seconds';
```
This naive logic introduces a lethal race condition. Suppose a high-load analytical query or garbage collection pause on the coordinator delays Phase 2 for 12 seconds. The coordinator has already successfully committed Shard 1 at $t = 11\text{s}$. At $t = 12\text{s}$, the naive janitor runs on Shard 2, sees the transaction is older than 10 seconds, and executes `ROLLBACK PREPARED`. At $t = 13\text{s}$, the coordinator attempts to commit Shard 2, only to receive `ERROR: prepared transaction "..." does not exist`. Shard 1 remains committed; Shard 2 was aborted. The janitor caused the exact split-brain disaster it was intended to prevent!

---

## 3. Mathematical Models: Autovacuum Bloat, Wraparound Horizon & Sizing Calculus

### 3.1 The $x_{\min}$ Horizon Dead Tuple Accumulation Integral

Let $\mu_{\text{churn}}(t)$ be the rate of dead tuple generation across all tables in the database cluster (tuples deleted or updated per second). If an orphaned prepared transaction is created at $t = 0$ with transaction ID $x_{\text{prep}}$, the cluster vacuum horizon $x_{\min}(t)$ is pinned:
$$x_{\min}(t) \le x_{\text{prep}}, \quad \forall t \ge 0$$
Because autovacuum cannot purge any tuple dead after $x_{\min}(t)$, the volume of uncollectable dead tuple bloat $V_{\text{bloat}}(T)$ in bytes after duration $T$ is given by:
$$V_{\text{bloat}}(T) = \int_0^T \mu_{\text{churn}}(t) \cdot \bar{S}_{\text{tuple}} \, dt$$
where $\bar{S}_{\text{tuple}}$ is the average tuple size in bytes.

For an enterprise OLTP database experiencing a modest write churn of $\mu_{\text{churn}} = 2,000$ updates/second with $\bar{S}_{\text{tuple}} = 500$ bytes:
$$\frac{d V_{\text{bloat}}}{dt} = 2000 \times 500 = 1,000,000 \text{ bytes/sec} \approx 3.6 \text{ GB/hour} \approx 86.4 \text{ GB/day}$$
Within 48 hours of an uncollected prepared transaction, the database accumulates over **170 GB of unvacuumable dead heap bloat**, evicting hot pages from `shared_buffers` and degrading read throughput by up to 80%.

### 3.2 Time-to-Wraparound (TTW) Differential Model

PostgreSQL transactions utilize a 32-bit unsigned integer counter wrapping around at $2^{32} \approx 4.29 \times 10^9$. PostgreSQL treats transaction IDs using modular arithmetic on the circle $\mathbb{Z}_{2^{32}}$: a transaction $X$ is considered in the past relative to current transaction $C$ if:
$$0 < (C - X) \pmod{2^{32}} < 2^{31}$$
If the age of the oldest unfrozen transaction exceeds $2^{31} \approx 2.147 \times 10^9$, past transactions appear to be in the future, destroying relational integrity.

Let $\lambda_{\text{xid}}$ be the transaction consumption rate (transactions per second). Let $A_{\text{curr}} = \text{age}(datfrozenxid)$ be the current age of the database. The critical emergency shutdown occurs when $A_{\text{curr}}$ reaches $A_{\text{stop}} = 2^{31} - 10,000,000 = 2,137,483,648$.

The Time-to-Wraparound shutdown ($\text{TTW}$) under a pinned prepared transaction is:
$$\text{TTW} = \frac{A_{\text{stop}} - A_{\text{curr}}}{\lambda_{\text{xid}}}$$

Under high transaction volume ($\lambda_{\text{xid}} = 10,000$ tx/sec) and starting with an age of $A_{\text{curr}} = 500,000,000$:
$$\text{TTW} = \frac{2,137,483,648 - 500,000,000}{10,000} \approx 163,748 \text{ seconds} \approx 45.5 \text{ hours}$$
In less than two days, the database reaches forced stop-the-world shutdown.

### 3.3 Lock Table Memory Sizing Calculus

PostgreSQL allocates the lock table at server startup in shared memory. The total number of lock table entries $N_{\text{locks}}$ is calculated by:
$$N_{\text{locks}} = \text{max\_locks\_per\_transaction} \times (\text{max\_connections} + \text{max\_prepared\_transactions})$$
Each lock entry consumes approximately $S_{\text{lock}} \approx 272$ bytes.

When enabling prepared transactions, if an agent configures:
$$\text{max\_connections} = 500, \quad \text{max\_prepared\_transactions} = 500, \quad \text{max\_locks\_per\_transaction} = 64$$
The required lock table allocations are:
$$N_{\text{locks}} = 64 \times (500 + 500) = 64,000 \text{ lock entries}$$
$$\text{Memory} = 64,000 \times 272 \approx 17.4 \text{ MB shared memory}$$
If `max_prepared_transactions` is set greater than `max_connections`, PostgreSQL logs a startup warning because participants should not exceed concurrent backend capacity:
$$\text{Invariant: } 0 < \text{max\_prepared\_transactions} \le \text{max\_connections}$$

---

## 4. Production-Ready TypeScript Engine: `AgenticDatabaseTwoPhaseCommitEngine`

The following production-ready engine provides structured Global Transaction ID (GID) generation, coordinator write-ahead logging (WAL), safe Phase 1 prepare and Phase 2 commit/rollback, and an autonomous in-doubt transaction telemetry watchdog.

```ts
/**
 * AgenticDatabaseTwoPhaseCommitEngine
 * Enterprise-grade Two-Phase Commit (2PC) coordinator and pg_prepared_xacts guard.
 */

import { Client, PoolClient } from 'pg';
import { randomUUID } from 'node:crypto';
import * as fs from 'node:fs';
import * as path from 'node:path';

export interface GidMetadata {
  app: string;
  service: string;
  coordinatorId: string;
  epochMs: number;
  txUuid: string;
  shardId: string;
}

export interface PreparedTransactionRecord {
  transaction: string;
  gid: string;
  prepared: Date;
  owner: string;
  database: string;
  ageSeconds: number;
}

export type CoordinatorState = 
  | 'INITIAL'
  | 'PREPARING'
  | 'PREPARED'
  | 'COMMITTING'
  | 'COMMITTED'
  | 'ABORTING'
  | 'ABORTED';

export interface CoordinatorJournalEntry {
  txUuid: string;
  state: CoordinatorState;
  timestamp: number;
  participants: Array<{ shardId: string; gid: string }>;
}

export class AgenticDatabaseTwoPhaseCommitEngine {
  private readonly appName: string;
  private readonly serviceName: string;
  private readonly coordinatorId: string;
  private readonly journalDir: string;

  constructor(appName: string, serviceName: string, journalDir: string = '/tmp/2pc_journal') {
    this.appName = appName;
    this.serviceName = serviceName;
    this.coordinatorId = randomUUID().slice(0, 8);
    this.journalDir = journalDir;

    if (!fs.existsSync(this.journalDir)) {
      fs.mkdirSync(this.journalDir, { recursive: true });
    }
  }

  /**
   * Format structured GID complying with Tier 2 taxonomy:
   * Format: app:service:coordId:epochMs:txUuid:shardId
   * Max 200 characters (PostgreSQL GID limit is 200 bytes).
   */
  public generateGid(txUuid: string, shardId: string): string {
    const epochMs = Date.now();
    const gid = `${this.appName}:${this.serviceName}:${this.coordinatorId}:${epochMs}:${txUuid}:${shardId}`;
    if (gid.length > 200) {
      throw new Error(`Generated GID exceeds PostgreSQL 200-byte limit: ${gid.length} bytes`);
    }
    return gid;
  }

  /**
   * Parse structured GID into constituent components.
   */
  public parseGid(gid: string): GidMetadata | null {
    const parts = gid.split(':');
    if (parts.length !== 6) return null;
    return {
      app: parts[0],
      service: parts[1],
      coordinatorId: parts[2],
      epochMs: parseInt(parts[3], 10),
      txUuid: parts[4],
      shardId: parts[5],
    };
  }

  /**
   * Append coordinator state transition to durable local WAL.
   */
  private appendJournal(entry: CoordinatorJournalEntry): void {
    const filePath = path.join(this.journalDir, `${entry.txUuid}.json`);
    fs.writeFileSync(filePath, JSON.stringify(entry, null, 2), { flag: 'w' });
  }

  /**
   * Remove coordinator journal entry upon clean resolution.
   */
  private purgeJournal(txUuid: string): void {
    const filePath = path.join(this.journalDir, `${txUuid}.json`);
    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
    }
  }

  /**
   * Verify target PostgreSQL instance supports 2PC (max_prepared_transactions > 0).
   */
  public async assertTwoPhaseSupported(client: PoolClient | Client): Promise<void> {
    const res = await client.query<{ setting: string }>(
      "SELECT setting FROM pg_settings WHERE name = 'max_prepared_transactions';"
    );
    const limit = parseInt(res.rows[0]?.setting ?? '0', 10);
    if (limit <= 0) {
      throw new Error(
        'PostgreSQL server has max_prepared_transactions = 0. Two-Phase Commit is disabled. ' +
        'Update postgresql.conf with max_prepared_transactions >= max_connections and restart the server.'
      );
    }
  }

  /**
   * Execute atomic distributed transaction across multiple database participants.
   */
  public async executeDistributedTx(
    participants: Array<{ shardId: string; client: PoolClient }>,
    work: (shardId: string, client: PoolClient) => Promise<void>
  ): Promise<void> {
    const txUuid = randomUUID();
    const preparedGids: Array<{ shardId: string; gid: string; client: PoolClient }> = [];

    // Pre-flight check
    for (const p of participants) {
      await this.assertTwoPhaseSupported(p.client);
    }

    // Initialize Journal
    const journal: CoordinatorJournalEntry = {
      txUuid,
      state: 'PREPARING',
      timestamp: Date.now(),
      participants: [],
    };
    this.appendJournal(journal);

    try {
      // Phase 1: Execute operations and PREPARE on all participants
      for (const p of participants) {
        const gid = this.generateGid(txUuid, p.shardId);
        journal.participants.push({ shardId: p.shardId, gid });

        await p.client.query('BEGIN');
        await work(p.shardId, p.client);

        // Issue PREPARE TRANSACTION
        await p.client.query(`PREPARE TRANSACTION '${gid}'`);
        preparedGids.push({ shardId: p.shardId, gid, client: p.client });
      }

      // Phase 1 Succeeded on all participants
      journal.state = 'PREPARED';
      this.appendJournal(journal);

      // Transition to COMMITTING: Persist commit decision to durable storage BEFORE issuing commit
      journal.state = 'COMMITTING';
      this.appendJournal(journal);

      // Phase 2: COMMIT PREPARED on all participants
      for (const item of preparedGids) {
        await item.client.query(`COMMIT PREPARED '${item.gid}'`);
      }

      // Terminal Success
      journal.state = 'COMMITTED';
      this.appendJournal(journal);
      this.purgeJournal(txUuid);

    } catch (error) {
      // Phase 1 failed or partial prepare occurred -> Must Abort
      journal.state = 'ABORTING';
      this.appendJournal(journal);

      // Rollback any participant that was successfully prepared
      for (const item of preparedGids) {
        try {
          await item.client.query(`ROLLBACK PREPARED '${item.gid}'`);
        } catch (rollbackErr) {
          // Log critical alert: background janitor will reconcile via journal
          console.error(`[CRITICAL] Failed to rollback prepared tx ${item.gid}:`, rollbackErr);
        }
      }

      journal.state = 'ABORTED';
      this.appendJournal(journal);
      throw error;
    }
  }

  /**
   * Query database for active in-doubt prepared transactions.
   */
  public async getInDoubtTransactions(client: PoolClient | Client): Promise<PreparedTransactionRecord[]> {
    const sql = `
      SELECT
        transaction,
        gid,
        prepared,
        owner,
        database,
        EXTRACT(EPOCH FROM (clock_timestamp() - prepared)) AS age_seconds
      FROM pg_prepared_xacts
      ORDER BY prepared ASC;
    `;
    const res = await client.query<{
      transaction: string;
      gid: string;
      prepared: Date;
      owner: string;
      database: string;
      age_seconds: string;
    }>(sql);

    return res.rows.map(r => ({
      transaction: r.transaction,
      gid: r.gid,
      prepared: r.prepared,
      owner: r.owner,
      database: r.database,
      ageSeconds: parseFloat(r.age_seconds),
    }));
  }

  /**
   * Autonomous Janitor: inspect in-doubt prepared transactions, check coordinator journal,
   * and safely resolve stalled transactions older than thresholdSeconds.
   */
  public async reconcileInDoubtTransactions(
    client: PoolClient | Client,
    maxAgeSeconds: number = 60
  ): Promise<{ resolved: number; unhandled: number }> {
    const list = await this.getInDoubtTransactions(client);
    let resolved = 0;
    let unhandled = 0;

    for (const record of list) {
      if (record.ageSeconds < maxAgeSeconds) {
        continue; // Still within acceptable latency budget
      }

      const meta = this.parseGid(record.gid);
      if (!meta) {
        console.warn(`[2PC-WATCHDOG] Unrecognized GID format: ${record.gid}. Skipping automated cleanup.`);
        unhandled++;
        continue;
      }

      // Check coordinator journal for durable decision
      const journalFile = path.join(this.journalDir, `${meta.txUuid}.json`);
      if (fs.existsSync(journalFile)) {
        const raw = fs.readFileSync(journalFile, 'utf-8');
        const journal: CoordinatorJournalEntry = JSON.parse(raw);

        if (journal.state === 'COMMITTING' || journal.state === 'COMMITTED') {
          console.log(`[2PC-WATCHDOG] Replaying COMMIT PREPARED for GID: ${record.gid}`);
          await client.query(`COMMIT PREPARED '${record.gid}'`);
          resolved++;
        } else {
          console.log(`[2PC-WATCHDOG] Replaying ROLLBACK PREPARED for GID: ${record.gid}`);
          await client.query(`ROLLBACK PREPARED '${record.gid}'`);
          resolved++;
        }
      } else {
        // No coordinator record found and transaction age is critical (> 300s).
        // Rollback to unpin xmin horizon and release exclusive table locks.
        if (record.ageSeconds > 300) {
          console.warn(`[2PC-WATCHDOG] Emergency ROLLBACK PREPARED for orphaned GID: ${record.gid} (age: ${record.ageSeconds}s)`);
          await client.query(`ROLLBACK PREPARED '${record.gid}'`);
          resolved++;
        } else {
          unhandled++;
        }
      }
    }

    return { resolved, unhandled };
  }
}
```

---

## 5. Production Implementations Across Runtimes

### 5.1 Go (`jackc/pgx/v5`): Resilient Distributed Coordinator & Watchdog

```go
package twophase

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// GidMetadata represents structured GID components.
type GidMetadata struct {
	App       string
	Service   string
	CoordID   string
	Epoch     int64
	TxUUID    string
	ShardID   string
}

// Coordinator orchestrates 2PC across multiple database shards.
type Coordinator struct {
	appName   string
	service   string
	coordID   string
	walDir    string
	mu        sync.Mutex
}

func NewCoordinator(appName, service, walDir string) (*Coordinator, error) {
	if err := os.MkdirAll(walDir, 0700); err != nil {
		return nil, fmt.Errorf("create 2pc wal dir: %w", err)
	}
	return &Coordinator{
		appName: appName,
		service: service,
		coordID: uuid.New().String()[:8],
		walDir:  walDir,
	}, nil
}

// FormatGid formats a bounded GID (<= 200 bytes).
func (c *Coordinator) FormatGid(txUUID, shardID string) string {
	epoch := time.Now().UnixMilli()
	return fmt.Sprintf("%s:%s:%s:%d:%s:%s", c.appName, c.service, c.coordID, epoch, txUUID, shardID)
}

// Participant wraps a database pool connection.
type Participant struct {
	ShardID string
	Conn    *pgxpool.Conn
}

// ExecuteAtomic2PC executes a two-phase transaction across shards with durable coordinator WAL.
func (c *Coordinator) ExecuteAtomic2PC(
	ctx context.Context,
	participants []*Participant,
	fn func(ctx context.Context, shardID string, tx pgx.Tx) error,
) error {
	txUUID := uuid.New().String()
	walPath := filepath.Join(c.walDir, txUUID+".state")

	// Phase 0: Record PREPARING state
	if err := os.WriteFile(walPath, []byte("PREPARING"), 0600); err != nil {
		return fmt.Errorf("write wal preparing: %w", err)
	}

	preparedGids := make([]struct {
		ShardID string
		Gid     string
		Conn    *pgxpool.Conn
	}, 0, len(participants))

	// Phase 1: Prepare all participants
	for _, p := range participants {
		gid := c.FormatGid(txUUID, p.ShardID)

		tx, err := p.Conn.Begin(ctx)
		if err != nil {
			c.abortPrepared(ctx, preparedGids, walPath)
			return fmt.Errorf("begin tx on shard %s: %w", p.ShardID, err)
		}

		if err := fn(ctx, p.ShardID, tx); err != nil {
			_ = tx.Rollback(ctx)
			c.abortPrepared(ctx, preparedGids, walPath)
			return fmt.Errorf("work failed on shard %s: %w", p.ShardID, err)
		}

		// Issue PREPARE TRANSACTION
		prepareSQL := fmt.Sprintf("PREPARE TRANSACTION '%s';", gid)
		if _, err := tx.Exec(ctx, prepareSQL); err != nil {
			_ = tx.Rollback(ctx)
			c.abortPrepared(ctx, preparedGids, walPath)
			return fmt.Errorf("prepare transaction on shard %s: %w", p.ShardID, err)
		}

		preparedGids = append(preparedGids, struct {
			ShardID string
			Gid     string
			Conn    *pgxpool.Conn
		}{ShardID: p.ShardID, Gid: gid, Conn: p.Conn})
	}

	// Phase 1 Succeeded on all nodes -> Persist COMMITTING decision before emitting commits
	if err := os.WriteFile(walPath, []byte("COMMITTING"), 0600); err != nil {
		c.abortPrepared(ctx, preparedGids, walPath)
		return fmt.Errorf("persist committing state to wal: %w", err)
	}

	// Phase 2: COMMIT PREPARED on all shards
	for _, item := range preparedGids {
		commitSQL := fmt.Sprintf("COMMIT PREPARED '%s';", item.Gid)
		if _, err := item.Conn.Exec(ctx, commitSQL); err != nil {
			// Do not rollback; coordinator has decided to commit!
			// Retry or let recovery watchdog complete the commit.
			return fmt.Errorf("commit prepared on shard %s (%s): %w", item.ShardID, item.Gid, err)
		}
	}

	// Clean up local WAL on success
	_ = os.Remove(walPath)
	return nil
}

func (c *Coordinator) abortPrepared(
	ctx context.Context,
	prepared []struct {
		ShardID string
		Gid     string
		Conn    *pgxpool.Conn
	},
	walPath string,
) {
	_ = os.WriteFile(walPath, []byte("ABORTING"), 0600)
	for _, p := range prepared {
		abortSQL := fmt.Sprintf("ROLLBACK PREPARED '%s';", p.Gid)
		_, _ = p.Conn.Exec(ctx, abortSQL)
	}
	_ = os.Remove(walPath)
}

// WatchdogJanitor continuously inspects pg_prepared_xacts and prevents xmin horizon pinning.
func StartWatchdogJanitor(ctx context.Context, pool *pgxpool.Pool, interval time.Duration) {
	ticker := time.NewTicker(interval)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				inspectAndAlert(ctx, pool)
			}
		}
	}()
}

func inspectAndAlert(ctx context.Context, pool *pgxpool.Pool) {
	const query = `
		SELECT gid, EXTRACT(EPOCH FROM (clock_timestamp() - prepared))::bigint AS age_secs
		FROM pg_prepared_xacts
		WHERE prepared < clock_timestamp() - interval '30 seconds';
	`
	rows, err := pool.Query(ctx, query)
	if err != nil {
		return
	}
	defer rows.Close()

	for rows.Next() {
		var gid string
		var ageSecs int64
		if err := rows.Scan(&gid, &ageSecs); err == nil {
			if ageSecs > 120 {
				// Critical threshold: prepared transaction holds xmin and table locks
				fmt.Printf("[CRITICAL-2PC-WATCHDOG] Orphaned prepared tx %s has age %ds! Pinning vacuum horizon!\n", gid, ageSecs)
			} else {
				fmt.Printf("[WARN-2PC-WATCHDOG] In-doubt prepared tx %s has age %ds.\n", gid, ageSecs)
			}
		}
	}
}
```

---

### 5.2 TypeScript (`drizzle-orm` / `pg`): Direct Pool Session Fencing

```ts
// src/services/twoPhaseSession.ts
import { Pool, PoolClient } from 'pg';

export class TwoPhaseSessionGuard {
  private readonly directPool: Pool;

  constructor(directPostgresUrl: string) {
    // Must bypass transaction-mode PgBouncer! Direct port 5432 or session mode
    this.directPool = new Pool({
      connectionString: directPostgresUrl,
      max: 10,
      idleTimeoutMillis: 10_000,
    });
  }

  public async runTwoPhaseParticipant(
    gid: string,
    execute: (client: PoolClient) => Promise<void>
  ): Promise<{ prepared: boolean }> {
    const client = await this.directPool.connect();

    try {
      await client.query('BEGIN');
      await execute(client);
      await client.query(`PREPARE TRANSACTION '${gid}'`);
      return { prepared: true };
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  public async commitPrepared(gid: string): Promise<void> {
    const client = await this.directPool.connect();
    try {
      await client.query(`COMMIT PREPARED '${gid}'`);
    } finally {
      client.release();
    }
  }

  public async rollbackPrepared(gid: string): Promise<void> {
    const client = await this.directPool.connect();
    try {
      await client.query(`ROLLBACK PREPARED '${gid}'`);
    } finally {
      client.release();
    }
  }
}
```

---

## 6. Finite State Machine: 6-State Lifecycle for Two-Phase Commit Execution

```
                        [Client Request Initiated]
                                    │
                                    ▼
                     ┌─────────────────────────────┐
                     │  STATE 1: TX_ACTIVE         │
                     │  - Direct DB port 5432      │
                     │  - Local BEGIN executed     │
                     └──────────────┬──────────────┘
                                    │ Phase 1 Prepare
                                    ▼
                     ┌─────────────────────────────┐
                     │  STATE 2: PREPARING_PHASE1  │
                     │  - Validate deferred constr │
                     │  - Write pg_twophase state  │
                     └───────┬─────────────┬───────┘
                             │             │ Prepare Error
               All Succeeded │             │ or Timeout
                             │             ▼
                             │     ┌─────────────────────────────┐
                             │     │  STATE 5: ABORTING_PHASE2   │
                             │     │  - Issue ROLLBACK PREPARED  │
                             │     │  - Release table locks      │
                             │     └──────────────┬──────────────┘
                             ▼                    │
              ┌─────────────────────────────┐     │
              │  STATE 3: PREPARED_INDOUBT  │     │
              │  - Registered in            │     │
              │    pg_prepared_xacts        │     │
              │  - Session unpinned         │     │
              └──────────────┬──────────────┘     │
                             │ Append COMMITTING  │
                             │ to Coordinator WAL │
                             ▼                    │
              ┌─────────────────────────────┐     │
              │  STATE 4: COMMITTING_PHASE2 │     │
              │  - Issue COMMIT PREPARED    │     │
              │  - Durable across crash     │     │
              └──────────────┬──────────────┘     │
                             │                    │
                             ▼                    ▼
                     ┌─────────────────────────────┐
                     │  STATE 6: RESOLVED_TERMINAL │
                     │  - Purge coordinator WAL    │
                     │  - xmin horizon advances    │
                     └─────────────────────────────┘
```

---

## 7. 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Test Command / Diagnostic Query | Pass Criterion |
| :--- | :--- | :--- | :--- |
| **Gate 1: GID Taxonomy Compliance** | Structured GID format and length | Regex check `^[a-z0-9_-]+:[a-z0-9_-]+:[a-z0-9_-]+:\d+:[a-f0-9-]+:[a-z0-9_-]+$` | Length $\le 200$ bytes; strictly parseable |
| **Gate 2: Server 2PC Support & Session Pooling** | Database server configuration | `SELECT setting::int FROM pg_settings WHERE name = 'max_prepared_transactions'` | `setting > 0` and `setting <= max_connections` |
| **Gate 3: Direct Connection Topology** | Connection pooler mode validation | Check database connection string port | Direct 5432 or PgBouncer `pool_mode = session`; never `transaction` |
| **Gate 4: Durable Coordinator Decision Log** | Coordinator write-ahead journal | Verify file/storage existence before emitting Phase 2 | `COMMITTING` record fsynced to disk prior to `COMMIT PREPARED` |
| **Gate 5: In-Doubt Prepared Tx Sentinel** | Vacuum horizon defense | `SELECT count(*) FROM pg_prepared_xacts WHERE prepared < clock_timestamp() - interval '60s'` | `count === 0` |
| **Gate 6: Deadlock & Lock Table Sizing** | Shared memory lock capacity | `SELECT count(*) FROM pg_locks WHERE transactionid IS NOT NULL` | Unheld orphan locks $= 0$ after transaction completion |

---

## Summary Checklist for Coding Agents

1. [ ] **Verify `max_prepared_transactions > 0`**: Never generate 2PC code without verifying that `max_prepared_transactions` is configured to a non-zero value.
2. [ ] **Bypass Transaction-Mode PgBouncer**: Always route 2PC participant connections to direct PostgreSQL server ports or strict session-mode pools.
3. [ ] **Structure Global Identifiers (GIDs)**: Never generate unstructured or random string GIDs; format with `app:service:coord:epoch:uuid:shard` and bound under 200 bytes.
4. [ ] **Durable Coordinator Commit Logging**: Ensure the coordinator writes its `COMMITTING` decision to persistent disk before issuing `COMMIT PREPARED`.
5. [ ] **Deploy Automated In-Doubt Watchdogs**: Run background health checkers monitoring `pg_prepared_xacts` to detect and safely resolve orphaned transactions before they pin the `$x_{\min}$` horizon and trigger transaction ID wraparound shutdowns.
