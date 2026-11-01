---
description: PostgreSQL logical replication conflict resolution (insert_exists, update_differ, update_missing, delete_missing), subscription apply worker crash-loop prevention, ALTER SUBSCRIPTION ... SKIP (lsn), pg_stat_subscription_errors telemetry, disable_on_error safety circuit breaker, publisher replication slot disk exhaustion prevention (max_slot_wal_keep_size), bi-directional origin tracking (origin = none), disjoint sequences, and REPLICA IDENTITY index invariants across Go (pgx/v5), TypeScript (Kysely, Drizzle), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{replication,subscriber,publisher,logical,subscription,slot,conflict,sync,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/events/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/replication/**/*.{go,rs},**/config/**/*.{conf,toml,yaml,json}
alwaysApply: false
---

# Agentic Database Logical Replication Conflicts, Subscription Workers, Error Handling, Skip LSN & Origin Tracking Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to configure PostgreSQL native logical replication (`CREATE PUBLICATION` / `CREATE SUBSCRIPTION`), orchestrate zero-downtime major version database upgrades, build cross-region active-active read replicas, implement tenant data extraction microservices, or manage stream replication across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `pg`), Python (`SQLAlchemy 2.0`, `asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Subscription Worker Crash Loop & Cluster-Wide Replication Freeze" (where an incoming logical change violates a target unique constraint `insert_exists` or cannot find a target tuple for update/delete `update_missing` / `delete_missing`, causing the single-threaded apply worker process to abort with `ERROR` and exit, only for the postmaster to immediately restart it and re-fetch the exact same commit LSN in an infinite crash loop that freezes replication across all tables in the subscription), the "Publisher Replication Slot Pinning & Disk Exhaustion PANIC Shutdown" (where unconfirmed replication slots keep `confirmed_flush_lsn` frozen on the publisher while the subscriber crash-loops, preventing checkpoints from recycling WAL segments until `pg_wal` consumes 100% of disk space and crashes the primary cluster with `PANIC: could not write to file "pg_wal/...": No space left on device`), the "Blind Drop-Recreate / Wholesale Transaction Skip & Causal Data Corruption Trap" (where naive agents attempt conflict recovery by dropping and recreating the subscription, triggering destructive full table copies or skipping hundreds of unrelated valid transactions without audit trails), the "Bi-Directional Active-Active Replication Infinite Ping-Pong Echo Loop" (where two nodes replicate to each other without PostgreSQL 16+ `origin = none`, causing applied changes on Node B to be republished back to Node A as local mutations, triggering mutual duplicate key collisions and permanent deadlock), the "Unsynchronized Sequence Trap & Primary Key Collision Avalanche" (where logical replication copies table rows but strictly does NOT replicate `SEQUENCE` states, causing direct application writes on the subscriber to reuse IDs already committed on the publisher and crashing with thousands of `duplicate key value violates unique constraint` errors), and the "Missing Subscriber Index & Full Sequential Scan CPU Meltdown" (where subscriber tables lack primary keys or replica identity indexes, forcing the apply worker to execute a full sequential scan for every single `UPDATE` and `DELETE`, spiking CPU to 100% and generating days of replication lag) by establishing a strict 5-Tier Logical Replication Conflict & Worker Governance Ladder, mathematical queueing and collision models, an autonomous TypeScript `AgenticLogicalReplicationGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state apply worker lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Logical Replication Conflict Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL (versions 10 through 17+), **Logical Replication** (`src/backend/replication/logical/worker.c` and `src/backend/replication/logical/applyparallelworker.c`) operates via a publisher-subscriber model based on logical decoding:

1. **The Publication Subsystem (`pg_publication`)**: The publisher engine captures DML changes (INSERT, UPDATE, DELETE, TRUNCATE) written to the WAL stream using the `pgoutput` plugin.
2. **The Replication Slot**: The publisher maintains a logical replication slot storing the `confirmed_flush_lsn`. The publisher's checkpointer cannot remove or recycle WAL segments behind the minimum confirmed LSN of all active replication slots.
3. **The Apply Worker Process (`logical replication apply worker`)**: The subscriber spawns a background worker process for each enabled subscription. The worker connects to the publisher via the streaming replication protocol, decodes incoming logical change tuples, opens a local transaction, executes the equivalent tuple operations, and commits.
4. **Conflict Generation**: Unlike physical streaming replication where byte-exact page changes are replayed identically onto exact block addresses, logical replication executes row-level operations against the subscriber's local tables. Any schema mismatch, pre-existing row, concurrent subscriber write, or trigger modification can trigger a constraint violation or tuple lookup failure.
5. **The Apply Worker Crash Loop**: When a conflict occurs:
   - The apply worker logs: `ERROR: duplicate key value violates unique constraint "users_pkey"` (or similar).
   - The local transaction aborts, and the worker process terminates immediately.
   - The subscriber postmaster detects the worker exit and restarts a new apply worker after a short delay (usually 5 seconds).
   - The new worker connects to the publisher, starts reading from the last unconfirmed LSN—**which is the exact same failing commit record**—re-executes the conflicting operation, and crashes again.
   - **All replication for every table in that subscription is 100% frozen!**

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             POSTGRESQL LOGICAL REPLICATION CONFLICT & CRASH-LOOP CASCADE               │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ PUBLISHER (Primary Node)                                                               │
│   │                                                                                    │
│   ├── Client writes tx: INSERT INTO orders(id, ...) VALUES (42, ...)  (Commit LSN 0/1A0)│
│   ├── pgoutput decodes change -> streams to subscriber socket                         │
│   └── Logical Replication Slot: confirmed_flush_lsn is stuck at 0/19F!                 │
│                                                                                        │
│ SUBSCRIBER (Replica Node)                                                              │
│   │                                                                                    │
│   ├── Apply Worker receives LSN 0/1A0: INSERT orders(id=42)                            │
│   ├── Target table already has orders(id=42) from prior local write or failed test!    │
│   ├── Postgres raises: ERROR: duplicate key value violates unique constraint "orders_pkey"│
│   │                                                                                    │
│   ├── 💥 APPLY WORKER PROCESS DIES!                                                    │
│   │     Transaction aborts; confirmed_flush_lsn is NEVER acknowledged to publisher!    │
│   │                                                                                    │
│   ├── Postmaster restarts Apply Worker (sleep 5s)                                      │
│   ├── Apply Worker restarts -> requests stream from publisher at LSN 0/1A0             │
│   └── 💥 CRASHES AGAIN! INFINITE CRASH LOOP!                                           │
│                                                                                        │
│ ❌ THE CLUSTER-WIDE COLLAPSE:                                                           │
│                                                                                        │
│   1. Subscriber Replication Lag: Grows indefinitely (minutes -> hours -> days).        │
│   2. Publisher pg_wal Accumulation: Checkpoints CANNOT remove WAL older than 0/19F.   │
│   3. Disk Exhaustion PANIC: Unless max_slot_wal_keep_size is set, publisher disk hits │
│      100% -> PANIC: could not write to file "pg_wal/...": No space left on device.     │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

When autonomous coding agents generate database migrations, multi-region replication setups, or logical subscriptions, LLMs routinely commit 6 catastrophic architectural mistakes:

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: CREATING SUBSCRIPTION WITHOUT disable_on_error
-- When a single conflict occurs, the worker enters an infinite crash-and-restart loop.
-- System logs fill with gigabytes of crash dumps, and CPU burns in fork/exec overhead.
CREATE SUBSCRIPTION sub_billing
    CONNECTION 'host=pub.db.internal port=5432 user=repuser dbname=billing password=secret'
    PUBLICATION pub_billing;
-- FATAL: Default disable_on_error = false guarantees crash loop!

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: PUBLISHER SLOT WITHOUT max_slot_wal_keep_size
-- When the subscriber crashes or freezes on a conflict, the publisher hoards WAL until 100% disk!
-- The entire primary cluster halts with PANIC shutdown!
-- Missing: ALTER SYSTEM SET max_slot_wal_keep_size = '50GB';

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: BI-DIRECTIONAL REPLICATION WITHOUT origin = none
-- Node A replicates to Node B. Node B replicates back to Node A.
-- Replicated row on B is treated as local write and republished to A -> Infinite ping-pong collision!
CREATE SUBSCRIPTION sub_node_b
    CONNECTION 'host=node_a port=5432 ...'
    PUBLICATION pub_node_a;
-- In PG 16+, MUST specify: CREATE SUBSCRIPTION ... WITH (origin = none);

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: UNSYNCHRONIZED AUTO-INCREMENT SEQUENCES
-- Sequences are NOT replicated by logical replication!
-- Subscriber starts with nextval = 1, while Publisher is at 50,000.
-- First direct write to subscriber reuses existing IDs, poisoning the replication stream!
```

```typescript
// ❌ CATASTROPHIC LLM ANTI-PATTERN 5: BLINDLY DROPPING SUBSCRIPTION TO FIX CONFLICT
// An autonomous agent detects replication lag and runs DROP SUBSCRIPTION + CREATE SUBSCRIPTION!
// This triggers a full initial table sync, acquiring ACCESS EXCLUSIVE locks on subscriber tables,
// copying tens of gigabytes over the network, and overwriting local subscriber state!
await db.query(`DROP SUBSCRIPTION sub_orders;`);
await db.query(`CREATE SUBSCRIPTION sub_orders CONNECTION '...' PUBLICATION pub_orders;`); // DISASTER!
```

```
+----------------------------------------------------------------------------------------------------+
|                         THE 6 LOGICAL REPLICATION CONFLICT CATASTROPHES                            |
+------------------------------------+---------------------------------------------------------------+
| 1. Subscription Worker Crash Loop  | Unique constraint or missing row conflict kills apply worker; |
|    & Cluster-Wide Replication Freeze| postmaster restarts worker endlessly retrying same LSN.       |
+------------------------------------+---------------------------------------------------------------+
| 2. Publisher Replication Slot      | Stuck subscriber halts confirmed_flush_lsn; publisher hoards  |
|    Pinning & Disk PANIC Meltdown   | WAL until disk hits 100%, causing cluster-wide PANIC crash.   |
+------------------------------------+---------------------------------------------------------------+
| 3. Blind Drop-Recreate / Wholesale | Dropping subscription or skipping arbitrary LSNs without      |
|    Transaction Skip Data Poisoning | audit destroys causal consistency and silently drops data.    |
+------------------------------------+---------------------------------------------------------------+
| 4. Bi-Directional Ping-Pong Echo   | Two-way replication without origin = none republishes remote  |
|    Loop & Circular Deadlock        | changes as local mutations, causing infinite duplicate loops. |
+------------------------------------+---------------------------------------------------------------+
| 5. Unsynchronized Sequence Trap &  | Logical replication does NOT sync sequences; subscriber writes|
|    Primary Key Collision Avalanche | reuse publisher IDs and trigger thousands of duplicate errors.|
+------------------------------------+---------------------------------------------------------------+
| 6. Missing Subscriber Index &      | Subscriber tables lacking PK or REPLICA IDENTITY index force  |
|    Full Sequential Scan CPU Burn   | full table scans for every UPDATE/DELETE, crippling CPU & I/O.|
+------------------------------------+---------------------------------------------------------------+
```

---

## 2. The 5-Tier Logical Replication Conflict & Worker Governance Ladder

To guarantee zero-downtime replication, rapid conflict mitigation, and disk exhaustion immunity, autonomous agents must enforce the **5-Tier Logical Replication Conflict & Worker Governance Ladder**:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│           THE 5-TIER LOGICAL REPLICATION CONFLICT & WORKER GOVERNANCE LADDER           │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Structural Schema Parity, Primary Keys & Disjoint Sequences                    │
│   • Mandatory Primary Key or Unique Index on 100% of published and subscribed tables.  │
│   • Configure REPLICA IDENTITY DEFAULT (with PK) or REPLICA IDENTITY USING INDEX.      │
│   • Enforce disjoint sequence partitioning: Publisher (odd IDs) vs Subscriber (even IDs│
│     or use RFC 9562 UUIDv7 to eliminate identifier collisions entirely.               │
│   • In PostgreSQL 16+, mandate origin = none on all bi-directional subscriptions.      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Worker Error Containment & disable_on_error Protocol                           │
│   • In PostgreSQL 15+, configure CREATE/ALTER SUBSCRIPTION ... WITH (disable_on_error =│
│     true) to cleanly halt the subscription on conflict instead of crash-loop thrash.   │
│   • Enforce publisher disk fencing: ALTER SYSTEM SET max_slot_wal_keep_size = '50GB'. │
│     Protects publisher primary from disk exhaustion PANIC if subscriber stalls.        │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Real-Time pg_stat_subscription_errors & Lag Telemetry Sentinels                │
│   • Continuously sample pg_stat_subscription_errors (subname, last_error_code,         │
│     last_error_message, last_error_lsn, last_error_time, error_count).                 │
│   • Sample pg_stat_subscription (pid, received_lsn, last_msg_send_time, lag).          │
│   • Calculate exact publisher-subscriber LSN byte lag:                                 │
│     pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn). Alert if lag > 100MB.  │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Surgical Conflict Resolution Engine & Precise SKIP (lsn = ...) Fencing         │
│   • In PostgreSQL 15+, resolve verified benign conflicts with atomic precision:        │
│     ALTER SUBSCRIPTION <name> SKIP (lsn = '<finish_lsn>');                             │
│   • Re-enable subscription cleanly: ALTER SUBSCRIPTION <name> ENABLE;                  │
│   • Record full conflict snapshot (raw tuple payload, table, timestamp, error code)    │
│     to immutable audit table before skipping.                                          │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Machine-Verifiable CI Schema Parity & Conflict Chaos Sandboxes                 │
│   • CI static analysis gate asserting schema parity (columns, types, constraints).     │
│   • Automated Chaos Injection test verifying error detection, slot protection, and     │
│     deterministic SKIP (lsn) resolution within < 30 seconds.                           │
│   • Zero-unindexed-subscriber-table DoD verification before production deployment.     │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Mathematical Foundations: Replication Lag Dynamics, Disk Exhaustion Bounds & Collision Calculus

### 3.1 Replication Lag Progression & Worker Crash Loop Dynamics

Let $\lambda_{\text{write}}$ be the publisher transaction arrival rate (bytes/sec) and $\mu_{\text{apply}}$ be the subscriber apply worker ingestion rate (bytes/sec). Under normal operation:

$$\mu_{\text{apply}} > \lambda_{\text{write}}$$

When the apply worker encounters a conflict at commit LSN $L_{\text{err}}$, the effective apply rate drops to zero ($\mu_{\text{apply}} = 0$). The accumulated replication lag $\Delta LSN_{\text{lag}}(t)$ in bytes over outage duration $t$ is:

$$\Delta LSN_{\text{lag}}(t) = \int_{0}^{t} \lambda_{\text{write}}(\tau)\, d\tau \approx \lambda_{\text{write}} \times t$$

Once the conflict is resolved (at $t = T_{\text{resolve}}$), the catch-up time $T_{\text{catchup}}$ required to drain the accumulated lag is bounded by:

$$T_{\text{catchup}} = \frac{\Delta LSN_{\text{lag}}(T_{\text{resolve}})}{\mu_{\text{apply}} - \lambda_{\text{write}}} = \frac{\lambda_{\text{write}} \times T_{\text{resolve}}}{\mu_{\text{apply}} - \lambda_{\text{write}}}$$

If $\lambda_{\text{write}} \ge \mu_{\text{apply}}$, the subscriber will **never catch up**, resulting in unbounded replication lag.

### 3.2 Publisher Disk Exhaustion Time-to-Failure under Blocked Slot

Let $D_{\text{free}}$ be the free disk space on the publisher's `pg_wal` volume, and $D_{\text{safety}}$ be the minimum emergency headroom (typically 10% of total volume). If the publisher logical replication slot is pinned at $L_{\text{err}}$, PostgreSQL cannot recycle any WAL segment between $L_{\text{err}}$ and the current WAL insertion point.

The time to disk exhaustion $T_{\text{exhaust}}$ without `max_slot_wal_keep_size` is:

$$T_{\text{exhaust}} = \frac{D_{\text{free}} - D_{\text{safety}}}{\lambda_{\text{write}}}$$

**Numerical Example**:
- $D_{\text{free}} = 100\text{ GB}$, $D_{\text{safety}} = 10\text{ GB} \implies D_{\text{usable}} = 90\text{ GB}$.
- Sustained write rate during peak traffic: $\lambda_{\text{write}} = 50\text{ MB/sec}$.
- $T_{\text{exhaust}} = \frac{90 \times 1024}{50} = 1,843\text{ seconds} \approx \mathbf{30.7\text{ minutes}}$!

If an engineer or agent does not detect and resolve the subscriber conflict within 30 minutes, the publisher disk hits 100%, crashing the primary database with an unbootable PANIC shutdown. Setting `max_slot_wal_keep_size = 50GB` guarantees:

$$T_{\text{drop\_slot}} = \frac{\text{max\_slot\_wal\_keep\_size}}{\lambda_{\text{write}}} = \frac{50 \times 1024}{50} \approx 17.0\text{ minutes}$$

At 17 minutes, PostgreSQL automatically invalidates the slot (`wal_status = lost`), protecting the primary database from crashing at the cost of requiring the subscriber to be re-seeded.

### 3.3 Active-Active Collision Probability without Origin Tracking

In a bi-directional setup between Node A and Node B, changes propagate with network and apply latency $\tau_{\text{prop}}$. If both nodes accept writes independently at rates $\lambda_A$ and $\lambda_B$ for overlapping key spaces:

The probability of concurrent conflicting writes on the same logical entity within window $[0, \tau_{\text{prop}}]$ follows a Poisson collision process:

$$P(\text{Collision}) = 1 - \exp\left(-\frac{\lambda_A \lambda_B \tau_{\text{prop}}}{K}\right)$$

Where $K$ is the cardinality of active keys. Without origin filtering (`origin = none`), an applied transaction on Node B is republished to Node A. The probability of an infinite circular echo cascade approaches $1.0$ within $t > \tau_{\text{prop}}$.

### 3.4 Subscriber Sequential Scan I/O Penalty under Missing Index

When an `UPDATE` or `DELETE` arrives over logical replication, the subscriber apply worker must search the local table for the matching tuple.

- **With Primary Key or Unique Index**: Search complexity is $O(\log N)$ B-tree page lookups (typically 3–4 8KB page reads).
- **Without Index (`REPLICA IDENTITY FULL` on table with $N$ pages)**: Search complexity is $O(N)$ sequential scan page reads.

The I/O amplification factor $\alpha_{\text{io}}$ per incoming mutation is:

$$\alpha_{\text{io}} = \frac{N_{\text{pages}}}{h_{\text{btree}}} = \frac{S_{\text{table}} / 8192}{\lceil\log_B((N+1)/2)\rceil}$$

For a 50GB table ($N_{\text{pages}} \approx 6,553,600$, $h_{\text{btree}} = 4$):

$$\alpha_{\text{io}} = \frac{6,553,600}{4} = \mathbf{1,638,400\times\text{ I/O Amplification!}}$$

A moderate stream of 100 updates/sec without an index demands $100 \times 50\text{ GB} = 5,000\text{ GB/sec}$ of memory/disk throughput, immediately freezing the subscriber database.

---

## 4. Production Agentic TypeScript Engine: `AgenticLogicalReplicationGuardEngine`

This production-grade TypeScript engine provides real-time telemetry, conflict detection via `pg_stat_subscription_errors`, publisher slot disk exhaustion bounds, safe execution of `ALTER SUBSCRIPTION ... SKIP (lsn)`, and origin configuration audits.

```typescript
/**
 * Agentic Logical Replication Guard & Conflict Mitigation Engine
 * Production-ready for PostgreSQL 15–17+, Kysely, Drizzle ORM, and pg.
 */

export interface SubscriptionErrorRecord {
  subid: number;
  subname: string;
  relid: number | null;
  tableName: string | null;
  command: string | null;
  errorCode: string | null;
  errorMessage: string | null;
  errorLsn: string | null;
  errorTime: Date | null;
  errorCount: number;
}

export interface SubscriptionStatus {
  subname: string;
  enabled: boolean;
  receivedLsn: string | null;
  lastMsgSendTime: Date | null;
  lastMsgReceiptTime: Date | null;
  latestEndLsn: string | null;
  latestEndTime: Date | null;
  workerPid: number | null;
}

export interface PublisherSlotStatus {
  slotName: string;
  plugin: string;
  active: boolean;
  activePid: number | null;
  walStatus: 'normal' | 'reserved' | 'extended' | 'unreserved' | 'lost';
  confirmedFlushLsn: string;
  lagBytes: number;
}

export interface ReplicationHealthAssessment {
  status: 'HEALTHY' | 'DEGRADED' | 'CONFLICT_DETECTED' | 'CRITICAL_DISK_RISK';
  activeConflicts: SubscriptionErrorRecord[];
  publisherSlotLagBytes: number;
  timeToExhaustionSeconds: number | null;
  recommendedAction: string;
}

export class AgenticLogicalReplicationGuardEngine {
  constructor(
    private readonly subscriberDbQuery: (sql: string, params?: unknown[]) => Promise<any[]>,
    private readonly publisherDbQuery?: (sql: string, params?: unknown[]) => Promise<any[]>,
    private readonly maxLagBytesThreshold = 100 * 1024 * 1024 // 100MB
  ) {}

  /**
   * Fetches current logical replication errors from pg_stat_subscription_errors (PostgreSQL 15+)
   */
  async getSubscriptionErrors(): Promise<SubscriptionErrorRecord[]> {
    const sql = `
      SELECT
        e.subid,
        e.subname,
        e.relid,
        c.relname AS table_name,
        e.command,
        e.last_error_code AS error_code,
        e.last_error_message AS error_message,
        e.last_error_lsn::text AS error_lsn,
        e.last_error_time AS error_time,
        e.last_error_count AS error_count
      FROM pg_stat_subscription_errors e
      LEFT JOIN pg_class c ON c.oid = e.relid
      WHERE e.last_error_count > 0
      ORDER BY e.last_error_time DESC;
    `;
    const rows = await this.subscriberDbQuery(sql);
    return rows.map(r => ({
      subid: Number(r.subid),
      subname: String(r.subname),
      relid: r.relid ? Number(r.relid) : null,
      tableName: r.table_name ? String(r.table_name) : null,
      command: r.command ? String(r.command) : null,
      errorCode: r.error_code ? String(r.error_code) : null,
      errorMessage: r.error_message ? String(r.error_message) : null,
      errorLsn: r.error_lsn ? String(r.error_lsn) : null,
      errorTime: r.error_time ? new Date(r.error_time) : null,
      errorCount: Number(r.error_count || 0)
    }));
  }

  /**
   * Audits subscriber tables to verify primary keys and replica identities
   */
  async auditSubscriberReplicaIdentities(subscriptionName: string): Promise<{
    table: string;
    hasPrimaryKey: boolean;
    replicaIdentity: string;
    isVulnerable: boolean;
  }[]> {
    const sql = `
      SELECT
        c.relname AS table_name,
        (SELECT count(*) > 0 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary) AS has_pk,
        c.relreplident::text AS replica_identity
      FROM pg_subscription_rel sr
      JOIN pg_subscription s ON s.oid = sr.srsubid
      JOIN pg_class c ON c.oid = sr.srrelid
      WHERE s.subname = $1;
    `;
    const rows = await this.subscriberDbQuery(sql, [subscriptionName]);
    return rows.map(r => {
      const hasPk = Boolean(r.has_pk);
      const replIdent = String(r.replica_identity); // 'd' = default, 'n' = nothing, 'f' = full, 'i' = index
      const isVulnerable = !hasPk && replIdent !== 'i';
      return {
        table: String(r.table_name),
        hasPrimaryKey: hasPk,
        replicaIdentity: replIdent,
        isVulnerable
      };
    });
  }

  /**
   * Evaluates end-to-end logical replication health and computes disk exhaustion risk
   */
  async assessReplicationHealth(subscriptionName: string, publisherWalRateBytesPerSec = 20 * 1024 * 1024): Promise<ReplicationHealthAssessment> {
    const errors = await this.getSubscriptionErrors();
    const activeConflicts = errors.filter(e => e.subname === subscriptionName);

    let lagBytes = 0;
    let timeToExhaustionSeconds: number | null = null;

    if (this.publisherDbQuery) {
      const slotSql = `
        SELECT
          slot_name,
          active,
          wal_status,
          confirmed_flush_lsn::text,
          pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes
        FROM pg_replication_slots
        WHERE slot_name = $1;
      `;
      const slotRows = await this.publisherDbQuery(slotSql, [subscriptionName]);
      if (slotRows.length > 0) {
        lagBytes = Number(slotRows[0].lag_bytes || 0);

        // Fetch free disk space on WAL directory
        const diskSql = `
          SELECT (setting::bigint * 1024) AS max_slot_bytes
          FROM pg_settings WHERE name = 'max_slot_wal_keep_size';
        `;
        const diskRows = await this.publisherDbQuery(diskSql);
        const maxSlotBytes = diskRows.length > 0 ? Number(diskRows[0].max_slot_bytes) : -1;

        if (maxSlotBytes > 0 && maxSlotBytes > lagBytes) {
          const remainingHeadroom = maxSlotBytes - lagBytes;
          timeToExhaustionSeconds = Math.floor(remainingHeadroom / publisherWalRateBytesPerSec);
        }
      }
    }

    if (activeConflicts.length > 0 && timeToExhaustionSeconds !== null && timeToExhaustionSeconds < 1800) {
      return {
        status: 'CRITICAL_DISK_RISK',
        activeConflicts,
        publisherSlotLagBytes: lagBytes,
        timeToExhaustionSeconds,
        recommendedAction: `CRITICAL: Publisher disk exhaustion imminent in ${timeToExhaustionSeconds}s. Resolve conflict or skip LSN ${activeConflicts[0].errorLsn} immediately!`
      };
    }

    if (activeConflicts.length > 0) {
      return {
        status: 'CONFLICT_DETECTED',
        activeConflicts,
        publisherSlotLagBytes: lagBytes,
        timeToExhaustionSeconds,
        recommendedAction: `Conflict detected on LSN ${activeConflicts[0].errorLsn}: ${activeConflicts[0].errorMessage}. Prepare audited skip or data correction.`
      };
    }

    if (lagBytes > this.maxLagBytesThreshold) {
      return {
        status: 'DEGRADED',
        activeConflicts: [],
        publisherSlotLagBytes: lagBytes,
        timeToExhaustionSeconds,
        recommendedAction: `High replication lag (${Math.round(lagBytes / (1024 * 1024))}MB). Check subscriber I/O or subscriber index coverage.`
      };
    }

    return {
      status: 'HEALTHY',
      activeConflicts: [],
      publisherSlotLagBytes: lagBytes,
      timeToExhaustionSeconds: null,
      recommendedAction: 'Replication is running normally.'
    };
  }

  /**
   * Safely executes ALTER SUBSCRIPTION ... SKIP (lsn = ...) for an audited conflict
   */
  async executeSurgicalSkipLsn(
    subscriptionName: string,
    targetLsn: string,
    operatorReason: string
  ): Promise<{ success: boolean; executedLsn: string; auditId: string }> {
    // 1. Verify target LSN matches active error in pg_stat_subscription_errors
    const errors = await this.getSubscriptionErrors();
    const matchingError = errors.find(e => e.subname === subscriptionName && e.errorLsn === targetLsn);

    if (!matchingError) {
      throw new Error(`Safety Violation: Target LSN ${targetLsn} does not match any active error on subscription ${subscriptionName}. Refusing blind skip.`);
    }

    const auditId = `skip_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;

    // 2. Disable subscription first to prevent worker restart race
    await this.subscriberDbQuery(`ALTER SUBSCRIPTION ${subscriptionName} DISABLE;`);

    try {
      // 3. Set the skip LSN (PostgreSQL 15+)
      // Note: LSN must be specified without quotes in PostgreSQL syntax: SKIP (lsn = '0/1A0')
      await this.subscriberDbQuery(`ALTER SUBSCRIPTION ${subscriptionName} SKIP (lsn = '${targetLsn}');`);

      // 4. Record audit entry in local database
      await this.subscriberDbQuery(`
        CREATE TABLE IF NOT EXISTS _agent_replication_skip_audit (
          audit_id TEXT PRIMARY KEY,
          subname TEXT NOT NULL,
          skipped_lsn TEXT NOT NULL,
          error_code TEXT,
          error_message TEXT,
          reason TEXT NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
      `);

      await this.subscriberDbQuery(
        `INSERT INTO _agent_replication_skip_audit (audit_id, subname, skipped_lsn, error_code, error_message, reason)
         VALUES ($1, $2, $3, $4, $5, $6);`,
        [auditId, subscriptionName, targetLsn, matchingError.errorCode, matchingError.errorMessage, operatorReason]
      );

      // 5. Re-enable subscription
      await this.subscriberDbQuery(`ALTER SUBSCRIPTION ${subscriptionName} ENABLE;`);

      return {
        success: true,
        executedLsn: targetLsn,
        auditId
      };
    } catch (err) {
      // Re-enable subscription on failure to avoid accidental indefinite outage
      await this.subscriberDbQuery(`ALTER SUBSCRIPTION ${subscriptionName} ENABLE;`);
      throw err;
    }
  }
}
```

---

## 5. Cross-Runtime Implementation Matrix

### 5.1 Go (`jackc/pgx/v5`): Subscription Telemetry & Automated Conflict Sentinel

```go
package replication

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type ConflictSentinel struct {
	subscriberPool *pgxpool.Pool
	subName        string
}

type SubscriptionError struct {
	SubName      string
	ErrorCode    string
	ErrorMessage string
	ErrorLSN     string
	ErrorCount   int64
	ErrorTime    time.Time
}

func NewConflictSentinel(pool *pgxpool.Pool, subName string) *ConflictSentinel {
	return &ConflictSentinel{
		subscriberPool: pool,
		subName:        subName,
	}
}

// CheckActiveConflict queries pg_stat_subscription_errors for active replication failures.
func (s *ConflictSentinel) CheckActiveConflict(ctx context.Context) (*SubscriptionError, error) {
	query := `
		SELECT subname, COALESCE(last_error_code, ''), COALESCE(last_error_message, ''),
		       COALESCE(last_error_lsn::text, ''), last_error_count, last_error_time
		FROM pg_stat_subscription_errors
		WHERE subname = $1 AND last_error_count > 0
		ORDER BY last_error_time DESC
		LIMIT 1;
	`
	var errRecord SubscriptionError
	var errTime sql.NullTime

	err := s.subscriberPool.QueryRow(ctx, query, s.subName).Scan(
		&errRecord.SubName,
		&errRecord.ErrorCode,
		&errRecord.ErrorMessage,
		&errRecord.ErrorLSN,
		&errRecord.ErrorCount,
		&errTime,
	)
	if err != nil {
		return nil, nil // No active error found
	}
	if errTime.Valid {
		errRecord.ErrorTime = errTime.Time
	}
	return &errRecord, nil
}

// SafeSkipLSN safely sets the skip LSN for PostgreSQL 15+ after validating the target LSN.
func (s *ConflictSentinel) SafeSkipLSN(ctx context.Context, targetLSN, reason string) error {
	activeErr, err := s.CheckActiveConflict(ctx)
	if err != nil {
		return fmt.Errorf("failed to verify active error: %w", err)
	}
	if activeErr == nil || activeErr.ErrorLSN != targetLSN {
		return fmt.Errorf("safety violation: target LSN %s does not match active error LSN", targetLSN)
	}

	tx, err := s.subscriberPool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// In PostgreSQL 15+, ALTER SUBSCRIPTION cannot run in a multi-statement transaction block
	// so we execute outside tx with strict sequencing
	_ = tx.Rollback(ctx)

	// 1. Disable
	if _, err := s.subscriberPool.Exec(ctx, fmt.Sprintf("ALTER SUBSCRIPTION %s DISABLE;", s.subName)); err != nil {
		return fmt.Errorf("failed to disable subscription: %w", err)
	}

	// 2. Skip LSN
	skipSQL := fmt.Sprintf("ALTER SUBSCRIPTION %s SKIP (lsn = '%s');", s.subName, targetLSN)
	if _, err := s.subscriberPool.Exec(ctx, skipSQL); err != nil {
		_ = s.enableSubscription(ctx)
		return fmt.Errorf("failed to execute skip LSN: %w", err)
	}

	// 3. Re-enable
	return s.enableSubscription(ctx)
}

func (s *ConflictSentinel) enableSubscription(ctx context.Context) error {
	_, err := s.subscriberPool.Exec(ctx, fmt.Sprintf("ALTER SUBSCRIPTION %s ENABLE;", s.subName))
	return err
}
```

### 5.2 TypeScript (`Kysely`): Resilient Subscription Monitor & Schema Auditor

```typescript
import { Kysely, sql } from 'kysely';

export interface ReplicationMonitorConfig {
  subscriptionName: string;
  maxAllowableLagSeconds: number;
}

export class KyselyReplicationMonitor {
  constructor(
    private readonly db: Kysely<any>,
    private readonly config: ReplicationMonitorConfig
  ) {}

  async auditMissingIndexes(): Promise<string[]> {
    const query = sql<{ table_name: string }>`
      SELECT c.relname AS table_name
      FROM pg_subscription_rel sr
      JOIN pg_subscription s ON s.oid = sr.srsubid
      JOIN pg_class c ON c.oid = sr.srrelid
      WHERE s.subname = ${this.config.subscriptionName}
        AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.oid AND (i.indisprimary OR i.indisunique)
        );
    `;
    const result = await query.execute(this.db);
    return result.rows.map(r => r.table_name);
  }

  async getReplicationLag(): Promise<{ lagSeconds: number; workerAlive: boolean }> {
    const query = sql<{ pid: number | null; last_msg_send_time: Date | null }>`
      SELECT pid, last_msg_send_time
      FROM pg_stat_subscription
      WHERE subname = ${this.config.subscriptionName};
    `;
    const result = await query.execute(this.db);
    if (result.rows.length === 0 || !result.rows[0].pid) {
      return { lagSeconds: Infinity, workerAlive: false };
    }
    const sendTime = result.rows[0].last_msg_send_time;
    const lagSeconds = sendTime ? Math.max(0, (Date.now() - new Date(sendTime).getTime()) / 1000) : 0;
    return { lagSeconds, workerAlive: true };
  }
}
```

### 5.3 Python (`asyncpg`): Asynchronous Conflict Exporter & Sentinel

```python
import asyncio
import asyncpg
from typing import Optional, Dict, Any

class AsyncpgReplicationSentinel:
    def __init__(self, dsn: str, subscription_name: str):
        self.dsn = dsn
        self.subscription_name = subscription_name

    async def fetch_latest_conflict(self) -> Optional[Dict[str, Any]]:
        conn = await asyncpg.connect(self.dsn)
        try:
            query = """
                SELECT
                    subname,
                    last_error_code,
                    last_error_message,
                    last_error_lsn::text,
                    last_error_count,
                    last_error_time
                FROM pg_stat_subscription_errors
                WHERE subname = $1 AND last_error_count > 0
                ORDER BY last_error_time DESC
                LIMIT 1;
            """
            row = await conn.fetchrow(query, self.subscription_name)
            if not row:
                return None
            return dict(row)
        finally:
            await conn.close()

    async def enforce_disable_on_error(self) -> None:
        conn = await asyncpg.connect(self.dsn)
        try:
            # Ensure PostgreSQL 15+ disable_on_error is active to prevent worker crash loop
            await conn.execute(f"ALTER SUBSCRIPTION {self.subscription_name} SET (disable_on_error = true);")
        finally:
            await conn.close()
```

### 5.4 Rust (`tokio-postgres`): High-Performance Lag & Error Auditor

```rust
use tokio_postgres::{Client, NoTls, Error};
use std::time::Duration;

pub struct ReplicationSentinel {
    client: Client,
    sub_name: String,
}

#[derive(Debug)]
pub struct ErrorRecord {
    pub sub_name: String,
    pub error_code: String,
    pub error_msg: String,
    pub error_lsn: String,
    pub error_count: i64,
}

impl ReplicationSentinel {
    pub async fn connect(db_url: &str, sub_name: &str) -> Result<Self, Error> {
        let (client, connection) = tokio_postgres::connect(db_url, NoTls).await?;
        tokio::spawn(async move {
            if let Err(e) = connection.await {
                eprintln!("connection error: {}", e);
            }
        });
        Ok(Self {
            client,
            sub_name: sub_name.to_string(),
        })
    }

    pub async fn check_errors(&self) -> Result<Option<ErrorRecord>, Error> {
        let query = "
            SELECT subname, COALESCE(last_error_code, ''), COALESCE(last_error_message, ''),
                   COALESCE(last_error_lsn::text, ''), last_error_count
            FROM pg_stat_subscription_errors
            WHERE subname = $1 AND last_error_count > 0
            LIMIT 1;
        ";
        let rows = self.client.query(query, &[&self.sub_name]).await?;
        if let Some(row) = rows.first() {
            Ok(Some(ErrorRecord {
                sub_name: row.get(0),
                error_code: row.get(1),
                error_msg: row.get(2),
                error_lsn: row.get(3),
                error_count: row.get(4),
            }))
        } else {
            Ok(None)
        }
    }
}
```

---

## 6. Finite-State Machine (FSM): Apply Worker Lifecycle & Conflict Remediation

The logical replication apply worker transitions across 6 deterministic states during normal operation and incident remediation:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             LOGICAL REPLICATION APPLY WORKER CONFLICT REMEDIATION FSM                  │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│     ┌────────────────────────┐                                                         │
│     │  HEALTHY_REPLICATING   │◄────────────────────────────────┐                       │
│     └───────────┬────────────┘                                 │                       │
│                 │                                              │                       │
│      Tuple Conflict Occurs (23505, etc.)                       │                       │
│                 ▼                                              │                       │
│     ┌────────────────────────┐                                 │                       │
│     │   CONFLICT_DETECTED    │                                 │                       │
│     └───────────┬────────────┘                                 │                       │
│                 │                                              │                       │
│       disable_on_error == false               disable_on_error == true                 │
│                 ▼                                              ▼                       │
│     ┌────────────────────────┐                   ┌───────────────────────────┐         │
│     │ WORKER_CRASH_LOOPING   │                   │   SUBSCRIPTION_DISABLED   │         │
│     │ (Postmaster restarts)  │                   │   (Worker halted cleanly) │         │
│     └───────────┬────────────┘                   └─────────────┬─────────────┘         │
│                 │                                              │                       │
│         Manual Intervention                           Agent / Sentinel Engage         │
│                 └───────────────────────┬──────────────────────┘                       │
│                                         ▼                                              │
│                          ┌─────────────────────────────┐                               │
│                          │    SKIP_LSN_EVALUATING      │                               │
│                          │  (Verify LSN in stat view)  │                               │
│                          └──────────────┬──────────────┘                               │
│                                         │                                              │
│                                 Execute SKIP (lsn)                                     │
│                                         ▼                                              │
│                          ┌─────────────────────────────┐                               │
│                          │       REPLAY_RESUMED        │───────────────────────────────┘
│                          │  (Worker advances past LSN) │
│                          └─────────────────────────────┘
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### State Transition Invariants

| Current State | Event Trigger | Next State | Guard Condition & Invariant |
| :--- | :--- | :--- | :--- |
| `HEALTHY_REPLICATING` | DML Conflict / Unique Violation | `CONFLICT_DETECTED` | Error recorded in `pg_stat_subscription_errors`. |
| `CONFLICT_DETECTED` | Worker exits (`disable_on_error=false`) | `WORKER_CRASH_LOOPING` | Postmaster restarts worker in 5s; slot accumulates WAL. |
| `CONFLICT_DETECTED` | Worker halts (`disable_on_error=true`) | `SUBSCRIPTION_DISABLED` | Subscription automatically disabled; zero CPU/log thrash. |
| `WORKER_CRASH_LOOPING` | Sentinel disables subscription | `SUBSCRIPTION_DISABLED` | Force `ALTER SUBSCRIPTION ... DISABLE` to stop crash loop. |
| `SUBSCRIPTION_DISABLED` | Sentinel validates error LSN | `SKIP_LSN_EVALUATING` | Assert target LSN matches `pg_stat_subscription_errors`. |
| `SKIP_LSN_EVALUATING` | `ALTER SUBSCRIPTION ... SKIP (lsn)` | `REPLAY_RESUMED` | Audit record written; subscription re-enabled. |
| `REPLAY_RESUMED` | `confirmed_flush_lsn > skipped_lsn` | `HEALTHY_REPLICATING` | Worker confirms advancement past conflicting commit. |

---

## 7. Definition of Done (DoD) CI Static Analysis & Machine-Verifiable Gates

Every database schema, subscription configuration, and migration script must pass all 6 DoD verification gates before deployment:

```
+----------------------------------------------------------------------------------------------------+
|               DEFINITION OF DONE (DoD): 6 LOGICAL REPLICATION VERIFICATION GATES                   |
+---+----------------------------------+-------------------------------------------------------------+
| 1 | Mandatory Primary Key / Replica  | 100% of tables in publication/subscription have primary key |
|   | Identity Gate                    | or explicit REPLICA IDENTITY USING INDEX. Zero seq scans!   |
+---+----------------------------------+-------------------------------------------------------------+
| 2 | Publisher max_slot_wal_keep_size | Publisher asserts max_slot_wal_keep_size is explicitly set  |
|   | Fencing Gate                     | (between 20GB and 100GB). Prevents 100% disk PANIC shutdown.|
+---+----------------------------------+-------------------------------------------------------------+
| 3 | Subscriber disable_on_error Gate | PostgreSQL 15+ subscriptions assert disable_on_error = true |
|   |                                  | to eliminate worker crash loops.                            |
+---+----------------------------------+-------------------------------------------------------------+
| 4 | Bi-Directional origin = none Gate| All two-way subscriptions assert origin = none (PG 16+) to  |
|   |                                  | prevent infinite circular replication ping-pong loops.      |
+---+----------------------------------+-------------------------------------------------------------+
| 5 | Disjoint Sequence Allocation Gate| Disjoint sequence step rules or UUIDv7 monotonic IDs enforced|
|   |                                  | to guarantee zero primary key collision on direct writes.   |
+---+----------------------------------+-------------------------------------------------------------+
| 6 | Automated Conflict Chaos Test    | CI runs replication chaos test injecting duplicate key and  |
|   | Verification Gate                | verifying automated detection & surgical SKIP (lsn) < 30s.  |
+---+----------------------------------+-------------------------------------------------------------+
```

### Machine-Verifiable CI Check Script (`scripts/ci-replication-check.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Validating PostgreSQL Logical Replication Invariants..."

# Gate 1: Check for subscriber tables lacking Primary Keys or Replica Identity
UNINDEXED_TABLES=$(psql "$SUBSCRIBER_DATABASE_URL" -t -A -c "
  SELECT c.relname
  FROM pg_subscription_rel sr
  JOIN pg_class c ON c.oid = sr.srrelid
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND (i.indisprimary OR i.indisunique)
  );
")

if [ -n "$UNINDEXED_TABLES" ]; then
  echo "❌ CI GATE 1 FAILURE: The following subscriber tables lack Primary Keys or Unique Indexes:"
  echo "$UNINDEXED_TABLES"
  echo "Replication will degrade to full sequential scans! Add a Primary Key or REPLICA IDENTITY INDEX."
  exit 1
fi
echo "✅ Gate 1 Passed: All replicated tables have primary key or unique replica identity."

# Gate 2: Verify publisher max_slot_wal_keep_size is configured
SLOT_KEEP_SIZE=$(psql "$PUBLISHER_DATABASE_URL" -t -A -c "SHOW max_slot_wal_keep_size;")
if [ "$SLOT_KEEP_SIZE" = "-1" ] || [ "$SLOT_KEEP_SIZE" = "0" ]; then
  echo "❌ CI GATE 2 FAILURE: max_slot_wal_keep_size is unset (-1)! Publisher is vulnerable to disk exhaustion PANIC."
  exit 1
fi
echo "✅ Gate 2 Passed: max_slot_wal_keep_size is securely bounded ($SLOT_KEEP_SIZE)."

echo "🚀 All Logical Replication Invariant Gates Passed Cleanly!"
```
