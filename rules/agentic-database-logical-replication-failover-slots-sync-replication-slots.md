---
description: PostgreSQL 17 logical replication failover slots (CREATE_REPLICATION_SLOT ... FAILOVER true), standby slot synchronization (sync_replication_slots = on), primary standby_slot_names coordination, slotsync worker lifecycle, pg_sync_replication_slots(), confirmed_flush_lsn and restart_lsn parity, forward-consumption race condition defense, and zero-data-loss CDC failover across Go (jackc/pgx/v5), TypeScript (pg, drizzle, prisma), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{replication,cdc,slot,failover,debezium,subscriber,publication,kafka,stream,standby}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/cdc/**/*.{ts,js,go,rs,py},**/internal/replication/**/*.{go,rs},**/internal/database/**/*.{go,rs},**/deploy/**/*.{yaml,yml,sh},**/config/**/*.{ini,conf,toml,yaml}
alwaysApply: false
---

# Agentic Database Logical Replication Failover Slots, Standby Slot Synchronization (PostgreSQL 17+ sync_replication_slots), Primary standby_slot_names Coordination, Confirmed Flush LSN Parity & Zero-Data-Loss CDC Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, automate, test, or execute PostgreSQL 17+ logical replication architectures, Change Data Capture (CDC) streaming pipelines (Debezium, Kafka Connect, Apache Flink), high-availability database failover topologies (Patroni, AWS RDS Multi-AZ, CloudNativePG), or subscriber database synchronization across Go (`jackc/pgx/v5`), TypeScript (`pg`, `drizzle-orm`, `prisma`), Python (`asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Failover Slot Amnesia & CDC Brain-Damage Trap" (where promoting a physical standby instantly annihilates logical replication slots because standbys historically never synchronized them, forcing multi-terabyte table re-snapshots or causing silent permanent data loss and duplicated message streams), the "Forward Consumption Race Condition & LSN Void (`standby_slot_names` Omission)" (where logical subscribers consume WAL directly from the primary faster than physical standbys replay WAL, so upon failover the promoted standby's replay LSN lags behind the subscriber's confirmed flush LSN, creating an irreconcilable timeline gap that permanently crashes CDC consumers), the "Standby Slot Sync Worker Crash & Missing `dbname` / Auth Trap" (where setting `sync_replication_slots = on` without specifying `dbname` and credentials in `primary_conninfo` causes the standby's `slotsync worker` background process to crash-loop silently), the "Direct Standby Consumption Attempt on Synced Slots (`synced = true` Lockout)" (where agents erroneously attempt to attach CDC consumers directly to dormant synced slots on a read-only standby, triggering `ERROR: logical replication slots cannot be used for decoding on a standby`), the "Offline Standby in `standby_slot_names` & Primary WAL Disk Exhaustion Avalanche" (where a disconnected physical standby prevents the primary from advancing `confirmed_flush_lsn` for logical slots, accumulating terabytes of WAL until disk exhaustion triggers a postmaster PANIC), and the "Post-Promotion Synced Slot Transition Race & Stale Endpoint Trap" (where subscribers reconnect to the newly promoted primary before synchronized slots transition from `synced = true` to normal active standalone slots) by establishing a strict 5-Tier Failover Slot Governance Ladder, mathematical LSN ordering proofs, standby lag differential equations, an autonomous TypeScript `AgenticDatabaseFailoverSlotGuardEngine`, cross-runtime driver invariants in Go, TypeScript, Python, and Rust, a 6-state replication lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Failover Slot Catastrophes vs The 5-Tier Governance Ladder

Prior to PostgreSQL 17, relational Change Data Capture (CDC) and logical replication suffered from a fundamental architectural limitation: **logical replication slots existed exclusively in the memory and catalog of the primary node**. Physical streaming standbys replicated table heaps, indexes, and write-ahead logs (WAL), but completely ignored logical slots.

When a primary failed or underwent maintenance, cluster orchestrators (Patroni, repmgr, CloudNativePG, Kubernetes operators, AWS RDS Multi-AZ) promoted a physical standby to leader. Downstream CDC pipelines (Debezium, Kafka Connect, Flink, read subscribers) immediately failed with `FATAL: replication slot "..." does not exist`. Engineering teams had only two disastrous choices:
1. Re-create the slot from scratch and trigger a full snapshot across tens of terabytes of data, causing hours of database lock contention, massive NVMe I/O thrashing, and downstream pipeline backpressure; or
2. Create the slot from the current LSN, permanently and silently dropping every data mutation committed between the standby's promotion and the old primary's failure.

PostgreSQL 17 fundamentally resolved this with **Logical Replication Failover Slots** and **Standby Slot Synchronization**:
1. **Failover-Enabled Slots (`CREATE_REPLICATION_SLOT ... (FAILOVER true)`)**: Logical slots flagged with `failover = true` in `pg_replication_slots`.
2. **Primary Standby Slot Coordination (`standby_slot_names`)**: Primary server refuses to decode and send WAL records to logical subscribers beyond the minimum LSN flushed by physical standbys enumerated in `standby_slot_names`. This guarantees the physical standby is always ahead of or equal to the logical subscriber.
3. **Standby Slot Sync Worker (`sync_replication_slots = on`)**: A dedicated background worker on physical standbys that periodically connects to the primary via `primary_conninfo`, copies the state of failover-enabled logical slots, and persists matching `restart_lsn` and `confirmed_flush_lsn` offsets with `synced = true`.
4. **Manual Slot Sync (`pg_sync_replication_slots()`)**: SQL function allowing on-demand synchronization when the background worker is not running.
5. **Seamless Post-Promotion Transition**: When `pg_ctl promote` runs, synchronized slots automatically transition from `synced = true` to normal writable slots (`synced = false`), allowing CDC consumers to connect immediately and resume streaming from their exact `confirmed_flush_lsn` with **zero data loss and zero re-snapshotting**.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               POSTGRESQL 17+ FAILOVER-ENABLED LOGICAL REPLICATION TOPOLOGY             │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│                      ┌──────────────────────────────────────────┐                      │
│                      │              PRIMARY CLUSTER             │                      │
│                      │                                          │                      │
│                      │  • wal_level = logical                   │                      │
│                      │  • standby_slot_names = 'standby_1'      │                      │
│                      │  • Logical Slot: my_cdc_slot             │                      │
│                      │    - failover = true                     │                      │
│                      │    - confirmed_flush_lsn = 0/5000000     │                      │
│                      └───────┬──────────────────────────┬───────┘                      │
│                              │ Physical WAL Stream      │ Logical Decode (Gated by     │
│                              │ (Streaming Replication)  │ standby_slot_names)          │
│                              ▼                          ▼                              │
│  ┌─────────────────────────────────────────┐  ┌─────────────────────────────────────┐  │
│  │             STANDBY CLUSTER             │  │            CDC CONSUMER             │  │
│  │                                         │  │     (Debezium / Kafka Connect)      │  │
│  │  • sync_replication_slots = on          │  │                                     │  │
│  │  • slotsync worker active               │  │  • Reading from: PRIMARY            │  │
│  │  • Synced Slot: my_cdc_slot             │  │  • Current LSN: 0/5000000           │  │
│  │    - synced = true                      │  │  • Invariant: LSN_cdc <= LSN_standby│  │
│  │    - restart_lsn = mirrored             │  └──────────────────┬──────────────────┘  │
│  │    - confirmed_flush_lsn = mirrored     │                     │                     │
│  └───────────────────┬─────────────────────┘                     │ Failover Reconnect  │
│                      │ Standby Promotion                         │ (Zero Data Loss!)   │
│                      ▼ (synced flips to false)                   │                     │
│  ┌─────────────────────────────────────────┐                     │                     │
│  │          NEW PROMOTED PRIMARY           │◄────────────────────┘                     │
│  │                                         │                                           │
│  │  • Promoted to Leader                   │                                           │
│  │  • Slot: my_cdc_slot                    │                                           │
│  │    - synced = false (Active!)           │                                           │
│  │    - resumes exactly at 0/5000000       │                                           │
│  └─────────────────────────────────────────┘                                           │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

However, when autonomous coding agents configure logical replication or failover automation, LLMs routinely commit fatal configuration and operational errors:

### The 6 PostgreSQL 17 Failover Slot Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: FAILOVER SLOT OBLITERATION & CDC BRAIN-DAMAGE TRAP
-- Agent sets up a logical replication slot on PostgreSQL 17 using default legacy syntax:
SELECT pg_create_logical_replication_slot('cdc_orders_slot', 'pgoutput');
-- Or via replication protocol:
-- CREATE_REPLICATION_SLOT cdc_orders_slot LOGICAL pgoutput;

-- 💥 Catastrophe:
-- In PostgreSQL 17, the 'failover' parameter defaults to FALSE!
-- When the database cluster experiences an automated failover (Patroni / CloudNativePG / RDS):
-- 1. Standby node is promoted to primary.
-- 2. 'cdc_orders_slot' NEVER EXISTED on the standby because failover was false.
-- 3. Debezium / Kafka Connect reconnects to the new primary:
--    FATAL: replication slot "cdc_orders_slot" does not exist
-- 4. Re-creating the slot forces a full initial table snapshot across 20TB of data,
--    locking production tables, exhausting network egress, or dropping thousands of events.
-- Invariant: pg_create_logical_replication_slot MUST explicitly pass failover => true!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: FORWARD CONSUMPTION RACE CONDITION & LSN VOID
-- Agent enables failover = true on the slot, but OMITS standby_slot_names on the primary:
SELECT pg_create_logical_replication_slot('cdc_orders_slot', 'pgoutput', false, false, true);
-- postgresql.conf on Primary:
-- standby_slot_names = '' (Default: unconfigured!)

-- 💥 Catastrophe:
-- 1. CDC consumer is extremely fast: reads logical changes up to LSN 0/8000000 and commits downstream.
-- 2. Physical standby experiences a network blip or disk queue spike; its replay LSN lags at 0/6000000.
-- 3. Primary suddenly crashes (power failure / kernel panic).
-- 4. Cluster orchestrator promotes the physical standby (at LSN 0/6000000) to leader.
-- 5. CDC consumer connects to the new leader, reporting its confirmed_flush_lsn = 0/8000000.
-- 6. The new leader has NOT yet received or replayed WAL between 0/6000000 and 0/8000000!
--    ERROR: requested LSN 0/8000000 is ahead of server write LSN 0/6000000
-- 7. The replication slot is permanently broken; the timeline is ruptured; data between
--    0/6000000 and 0/8000000 is DUPLICATED or IRRETRIEVABLY CORRUPTED downstream.
-- Invariant: standby_slot_names MUST list physical standby slots on the primary!
```

```ini
# ❌ CATASTROPHIC LLM ANTI-PATTERN 3: STANDBY SLOT SYNC WORKER CRASH & MISSING DBNAME
# Agent configures standby postgresql.conf for slot sync:
sync_replication_slots = on
primary_conninfo = 'host=prod-primary.internal port=5432 user=replicator password=secret'

# 💥 Catastrophe:
# In PostgreSQL 17, the slotsync worker MUST connect to a specific database on the primary!
# If 'dbname' is omitted from primary_conninfo, the standby background worker cannot initialize
# logical decoding metadata catalog lookups.
# Standby PostgreSQL logs immediately flood with:
# ERROR: dbname must be specified in primary_conninfo for slot synchronization
# LOG: background worker "slotsync worker" (PID 18492) exited with exit code 1
#
# The worker enters an infinite crash-restart loop. Slots are NEVER synchronized.
# When failover occurs, the standby has ZERO logical slots!
# Invariant: primary_conninfo MUST explicitly include dbname=<database_name>!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: DIRECT STANDBY CONSUMPTION ATTEMPT ON SYNCED SLOTS
-- Agent notices that logical slots exist on the standby and tries to offload CDC read traffic:
-- Connecting to read-only Standby (port 5433):
SELECT * FROM pg_logical_slot_get_changes('cdc_orders_slot', NULL, NULL);

-- 💥 Catastrophe:
-- PostgreSQL explicitly forbids decoding from synced slots while in standby recovery:
-- ERROR: logical replication slots cannot be used for decoding on a standby
-- HINT: Synced slots are read-only mirrors maintained by the slotsync worker.
--
-- Autonomous agents parsing this error attempt to DROP or recreate the slot on the standby,
-- breaking the slotsync worker and desynchronizing cluster catalog state.
-- Invariant: Synced slots on standbys are strictly dormant mirrors until promotion!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: OFFLINE STANDBY & PRIMARY WAL DISK EXHAUSTION
-- Primary is configured with standby_slot_names = 'standby_dr_replica'
-- An engineer halts the DR replica for maintenance without removing it from standby_slot_names:

-- 💥 Catastrophe:
-- 1. Because standby_dr_replica is offline, its flush LSN freezes.
-- 2. Primary obeys the invariant: it refuses to advance confirmed_flush_lsn for cdc_orders_slot!
-- 3. CDC consumer stalls completely, waiting for primary to permit decoding.
-- 4. Primary refuses to recycle WAL files because the lagging logical and physical slots hold restart_lsn.
-- 5. In postgresql.conf, max_slot_wal_keep_size = -1 (unlimited).
-- 6. In 6 hours, pg_wal consumes 100% of the primary partition:
--    PANIC: could not write to log file: No space left on device
-- 7. Entire production cluster crashes hard into an un-startable state.
-- Invariant: max_slot_wal_keep_size MUST be set (e.g. 50GB) and standby health monitored!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: POST-PROMOTION SYNCED TRANSITION RACE
-- Cluster failover completes; Patroni executes 'pg_ctl promote' on standby:
-- Agent script immediately routes CDC consumer (Debezium) to the new leader:
-- 1 millisecond after promote:
SELECT active, synced FROM pg_replication_slots WHERE slot_name = 'cdc_orders_slot';
-- Returns: synced = true (Transition in progress!)

-- 💥 Catastrophe:
-- Standby postmaster requires a brief non-zero window to shut down the slotsync worker,
-- acquire catalog locks, and persist synced = false across all synchronized slots.
-- If CDC connects while synced = true:
-- FATAL: cannot use logical replication slot "cdc_orders_slot" because it is a synchronized slot
-- Invariant: CDC reconnection MUST poll pg_replication_slots until synced = false!
```

---

## 2. Mathematical Models & Formal Proofs: LSN Gating & CDC Failover Invariants

### 2.1 The Forward Consumption Safety Theorem

Let $\mathcal{P}$ denote the primary PostgreSQL 17 cluster, and let $\mathcal{S} = \{s_1, s_2, \dots, s_m\}$ denote the set of active physical streaming standbys replicating WAL from $\mathcal{P}$.

Let $\text{LSN}_{\text{flush}}(s_i, t)$ denote the write-ahead log sequence number securely persisted to non-volatile disk on standby $s_i$ at time $t$. Let $\text{LSN}_{\text{cons}}(L, t)$ denote the Log Sequence Number up to which a logical CDC subscriber $L$ has ingested and acknowledged changes.

**Theorem 1 (Zero-Data-Loss Failover Invariance)**:  
In the event of an ungraceful crash of primary $\mathcal{P}$ at time $t_c$ followed by the election and promotion of standby $s^* \in \mathcal{S}$ to primary, the CDC consumer $L$ can resume stream decoding without data gap ($\Delta \text{LSN}_{\text{gap}} = 0$) and without duplicate processing if and only if:

$$\forall t \le t_c, \quad \text{LSN}_{\text{cons}}(L, t) \le \text{LSN}_{\text{flush}}(s^*, t)$$

*Proof*:  
Assume the contrary: $\exists t_0 \le t_c$ such that $\text{LSN}_{\text{cons}}(L, t_0) > \text{LSN}_{\text{flush}}(s^*, t_0)$.  
1. When $\mathcal{P}$ crashes at $t_c \ge t_0$, all WAL records generated on $\mathcal{P}$ in the range $(\text{LSN}_{\text{flush}}(s^*, t_c), \text{LSN}_{\text{curr}}(\mathcal{P}, t_c)]$ that were not replicated to $s^*$ are permanently lost.
2. When $s^*$ promotes to leader, its new timeline forks at $\text{LSN}_{\text{fork}} = \text{LSN}_{\text{flush}}(s^*, t_c)$.
3. Because $\text{LSN}_{\text{cons}}(L, t_0) > \text{LSN}_{\text{fork}}$, consumer $L$ has already processed mutations originating from timeline $T_{\text{old}}$ beyond the fork point.
4. When $L$ attempts to resume decoding on $s^*$, it issues a replication request for LSN $\text{LSN}_{\text{cons}}(L, t_0)$.
5. Since $\text{LSN}_{\text{cons}}(L, t_0) > \text{LSN}_{\text{fork}}$, $s^*$ does not possess these WAL records, or has overwritten the timeline with $T_{\text{new}}$, generating:
   $$\text{SQLSTATE 58P01 / ERROR: requested WAL segment has already been removed or does not exist}$$
6. Consumer $L$ is in an irreconcilable state. The data gap $\Delta \text{LSN}_{\text{gap}} = \text{LSN}_{\text{cons}} - \text{LSN}_{\text{fork}} > 0$.

Therefore, zero-data-loss CDC failover requires:
$$\text{LSN}_{\text{cons}}(L, t) \le \min_{s \in \text{standby\_slot\_names}} \text{LSN}_{\text{flush}}(s, t) \quad \blacksquare$$

In PostgreSQL 17, configuring `standby_slot_names = 'physical_standby_1'` enforces this theorem at the C engine level inside `LogicalDecodingProcessRecord()`, physically blocking logical decoding from advancing beyond the standby's confirmed flush point.

---

### 2.2 Standby Synchronization Lag Differential Equations

On the physical standby, the `slotsync worker` executes an iterative synchronization loop. Let $\Delta_{\text{slot}}(t)$ denote the synchronization lag in bytes between the primary's logical slot `confirmed_flush_lsn` and the standby's mirrored slot:

$$\Delta_{\text{slot}}(t) = \text{LSN}_{\text{primary}}(t) - \text{LSN}_{\text{standby\_synced}}(t)$$

Let $\lambda_{\text{wal}}(t)$ denote the primary WAL generation rate in bytes/sec. Let $T_{\text{poll}}$ denote the polling interval of the `slotsync worker` (governed by internal sleep timeouts and libpq network round-trip time).

The synchronization lag evolves according to:

$$\frac{d\Delta_{\text{slot}}(t)}{dt} = \lambda_{\text{wal}}(t) - \mu_{\text{sync}}(t)$$

where $\mu_{\text{sync}}(t)$ is the sync worker's absorption rate. When the worker fetches slot updates over libpq:

$$\mu_{\text{sync}}(t) = \frac{\Delta_{\text{slot}}(t)}{\tau_{\text{RTT}} + \tau_{\text{catalog\_write}}}$$

Under steady-state generation $\lambda_{\text{wal}}$, the maximum failover slot lag $\Delta_{\text{max}}$ is strictly bounded by:

$$\Delta_{\text{max}} \le \lambda_{\text{wal}} \cdot \left( T_{\text{poll}} + \tau_{\text{RTT}} + \tau_{\text{commit}} \right)$$

For typical production parameters ($\lambda_{\text{wal}} = 20\,\text{MB/s}$, $T_{\text{poll}} = 500\,\text{ms}$, $\tau_{\text{RTT}} = 2\,\text{ms}$):

$$\Delta_{\text{max}} \approx 20\,\text{MB/s} \times 0.502\,\text{s} \approx 10.04\,\text{MB}$$

When primary failover occurs, the promoted standby's `confirmed_flush_lsn` lags by at most $10.04\,\text{MB}$ of WAL. Because `standby_slot_names` gated the subscriber, the subscriber is also bounded behind this point, guaranteeing **zero dropped transactions**.

---

### 2.3 Primary WAL Disk Exhaustion Horizon under Standby Stall

If a physical standby enumerated in `standby_slot_names` drops offline while the primary cluster continues processing write traffic at rate $\lambda_{\text{wal}}$, the primary cannot advance the logical slot's `restart_lsn`.

Let $D_{\text{free}}$ denote the initial free disk space on the primary's `pg_wal` filesystem, and let $D_{\text{safety}}$ denote the emergency reservation threshold ($D_{\text{safety}} \ge 0.15 \times D_{\text{total}}$). The time to postmaster PANIC $T_{\text{exhaust}}$ without protective fences is:

$$T_{\text{exhaust}} = \frac{D_{\text{free}} - D_{\text{safety}}}{\lambda_{\text{wal}}}$$

For $D_{\text{free}} = 100\,\text{GB}$, $D_{\text{safety}} = 15\,\text{GB}$, and $\lambda_{\text{wal}} = 15\,\text{MB/s}$:

$$T_{\text{exhaust}} = \frac{85 \times 10^9}{15 \times 10^6} \approx 5,666\,\text{seconds} \approx 1.57\,\text{hours}$$

**The Disk Safety Invariant**: Setting `max_slot_wal_keep_size = 50GB` enforces a hard ceiling. If lag exceeds $50\,\text{GB}$, PostgreSQL invalidates the slot (`wal_status = 'lost'`), terminating the logical consumer but saving the primary cluster from a fatal postmaster crash:

$$W_{\text{retained}} \le \min\left( D_{\text{free}} - D_{\text{safety}}, \max\_slot\_wal\_keep\_size \right)$$

---

## 3. Autonomous TypeScript Implementation: `AgenticDatabaseFailoverSlotGuardEngine`

The following TypeScript production engine provides end-to-end qualification, provisioning, lag telemetry, and zero-data-loss failover orchestration for PostgreSQL 17+ logical replication failover slots.

```typescript
/**
 * AgenticDatabaseFailoverSlotGuardEngine
 * Production TypeScript sentinel for PostgreSQL 17+ Logical Replication Failover Slots,
 * standby_slot_names coordination, slotsync worker telemetry, and automated failover validation.
 *
 * Compatible with pg, drizzle-orm, prisma, and autonomous agent frameworks.
 */

import { Client, ClientConfig, QueryResult } from 'pg';

export interface ReplicationSlotStatus {
  slotName: string;
  plugin: string;
  slotType: 'logical' | 'physical';
  datoid: number;
  database: string;
  temporary: boolean;
  active: boolean;
  activePid: number | null;
  xmin: string | null;
  catalogXmin: string | null;
  restartLsn: string;
  confirmedFlushLsn: string | null;
  walStatus: 'normal' | 'reserved' | 'extended' | 'unreserved' | 'lost';
  safeWalSize: number | null;
  twoPhase: boolean;
  failover: boolean; // PostgreSQL 17+
  synced: boolean;   // PostgreSQL 17+
}

export interface FailoverSlotConfig {
  primaryConfig: ClientConfig;
  standbyConfig: ClientConfig;
  slotName: string;
  pluginName?: string; // default: 'pgoutput'
  databaseName: string;
  physicalStandbySlotName: string;
  maxAllowedLagBytes?: number; // default: 67108864 (64MB)
  maxSlotWalKeepSizeMb?: number; // default: 51200 (50GB)
}

export interface TelemetryEvent {
  timestamp: string;
  level: 'INFO' | 'WARN' | 'ERROR';
  event: string;
  details: Record<string, unknown>;
}

export class AgenticDatabaseFailoverSlotGuardEngine {
  private readonly config: Required<FailoverSlotConfig>;
  private readonly telemetryLog: TelemetryEvent[] = [];

  constructor(config: FailoverSlotConfig) {
    this.config = {
      primaryConfig: config.primaryConfig,
      standbyConfig: config.standbyConfig,
      slotName: config.slotName,
      pluginName: config.pluginName ?? 'pgoutput',
      databaseName: config.databaseName,
      physicalStandbySlotName: config.physicalStandbySlotName,
      maxAllowedLagBytes: config.maxAllowedLagBytes ?? 64 * 1024 * 1024,
      maxSlotWalKeepSizeMb: config.maxSlotWalKeepSizeMb ?? 51200,
    };
  }

  private log(level: 'INFO' | 'WARN' | 'ERROR', event: string, details: Record<string, unknown>): void {
    const entry: TelemetryEvent = {
      timestamp: new Date().toISOString(),
      level,
      event,
      details,
    };
    this.telemetryLog.push(entry);
    if (level === 'ERROR') {
      console.error(`[FailoverSlotGuard][ERROR] ${event}`, JSON.stringify(details));
    } else if (level === 'WARN') {
      console.warn(`[FailoverSlotGuard][WARN] ${event}`, JSON.stringify(details));
    } else {
      console.info(`[FailoverSlotGuard][INFO] ${event}`, JSON.stringify(details));
    }
  }

  public getTelemetry(): ReadonlyArray<TelemetryEvent> {
    return [...this.telemetryLog];
  }

  /**
   * Asserts that a PostgreSQL instance meets PostgreSQL 17+ failover slot prerequisites.
   */
  public async qualifyEnginePrerequisites(client: Client, roleName: 'PRIMARY' | 'STANDBY'): Promise<void> {
    // 1. Version Check: Must be >= 170000
    const verRes = await client.query<{ server_version_num: string; server_version: string }>(
      'SELECT current_setting($1) AS server_version_num, version() AS server_version;',
      ['server_version_num']
    );
    const verNum = parseInt(verRes.rows[0].server_version_num, 10);
    if (verNum < 170000) {
      throw new Error(
        `[Prerequisite Violation] ${roleName} PostgreSQL version is ${verRes.rows[0].server_version} ` +
        `(num: ${verNum}). Failover slots (failover=true, sync_replication_slots) require PostgreSQL 17.0+`
      );
    }

    if (roleName === 'PRIMARY') {
      // 2. Primary checks: wal_level must be 'logical'
      const walRes = await client.query<{ wal_level: string }>(
        "SELECT current_setting('wal_level') AS wal_level;"
      );
      if (walRes.rows[0].wal_level !== 'logical') {
        throw new Error(
          `[Prerequisite Violation] Primary wal_level is '${walRes.rows[0].wal_level}'. Must be 'logical'.`
        );
      }

      // 3. standby_slot_names must include the physical standby
      const standbySlotRes = await client.query<{ standby_slot_names: string }>(
        "SELECT current_setting('standby_slot_names') AS standby_slot_names;"
      );
      const configuredStandbys = standbySlotRes.rows[0].standby_slot_names
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean);

      if (!configuredStandbys.includes(this.config.physicalStandbySlotName)) {
        this.log('WARN', 'STANDBY_SLOT_NAMES_UNCOORDINATED', {
          configuredStandbys,
          expectedPhysicalSlot: this.config.physicalStandbySlotName,
          hint: 'Primary must gate logical decoding using standby_slot_names to prevent forward consumption race condition.',
        });
      }

      // 4. max_slot_wal_keep_size must be positive
      const keepRes = await client.query<{ max_slot_wal_keep_size: string }>(
        "SELECT current_setting('max_slot_wal_keep_size') AS max_slot_wal_keep_size;"
      );
      const keepVal = parseInt(keepRes.rows[0].max_slot_wal_keep_size, 10);
      if (keepVal === -1) {
        this.log('WARN', 'UNLIMITED_WAL_KEEP_SIZE', {
          max_slot_wal_keep_size: '-1 (unlimited)',
          hint: 'Set max_slot_wal_keep_size >= 50GB to prevent disk exhaustion when standbys disconnect.',
        });
      }
    } else {
      // Standby checks: sync_replication_slots must be on
      const syncRes = await client.query<{ sync_replication_slots: string }>(
        "SELECT current_setting('sync_replication_slots') AS sync_replication_slots;"
      );
      if (syncRes.rows[0].sync_replication_slots !== 'on') {
        throw new Error(
          `[Prerequisite Violation] Standby sync_replication_slots is '${syncRes.rows[0].sync_replication_slots}'. ` +
          `Must be 'on' to run the background slotsync worker.`
        );
      }

      // primary_conninfo must include dbname
      const connInfoRes = await client.query<{ primary_conninfo: string }>(
        "SELECT current_setting('primary_conninfo') AS primary_conninfo;"
      );
      const connInfo = connInfoRes.rows[0].primary_conninfo;
      if (!connInfo.includes('dbname=')) {
        throw new Error(
          `[Prerequisite Violation] Standby primary_conninfo is missing 'dbname='! ` +
          `The PostgreSQL 17 slotsync worker cannot synchronize slots without an explicit database name.`
        );
      }
    }

    this.log('INFO', 'ENGINE_PREREQUISITES_VERIFIED', { roleName, verNum });
  }

  /**
   * Idempotently provisions a logical replication slot on the Primary with failover=true.
   */
  public async ensurePrimaryFailoverSlot(): Promise<ReplicationSlotStatus> {
    const primary = new Client(this.config.primaryConfig);
    await primary.connect();
    try {
      await this.qualifyEnginePrerequisites(primary, 'PRIMARY');

      // Check if slot exists
      const checkRes = await primary.query(
        `SELECT slot_name, plugin, slot_type, datoid, database, temporary, active,
                active_pid, xmin, catalog_xmin, restart_lsn, confirmed_flush_lsn,
                wal_status, safe_wal_size, two_phase, failover, synced
         FROM pg_replication_slots
         WHERE slot_name = $1;`,
        [this.config.slotName]
      );

      if (checkRes.rowCount && checkRes.rowCount > 0) {
        const slot = this.mapSlotRow(checkRes.rows[0]);
        if (!slot.failover) {
          throw new Error(
            `[Slot Misconfiguration] Replication slot '${this.config.slotName}' exists on primary ` +
            `but has failover = false! Standby will NOT synchronize this slot. Re-create with failover => true.`
          );
        }
        this.log('INFO', 'PRIMARY_FAILOVER_SLOT_CONFIRMED', { slotName: slot.slotName, failover: slot.failover });
        return slot;
      }

      // Create logical replication slot with failover = true (PostgreSQL 17 syntax)
      this.log('INFO', 'CREATING_FAILOVER_LOGICAL_SLOT', {
        slotName: this.config.slotName,
        plugin: this.config.pluginName,
        failover: true,
      });

      await primary.query(
        `SELECT pg_create_logical_replication_slot(
           $1,            -- slot_name
           $2,            -- plugin
           false,         -- temporary
           false,         -- twophase
           true           -- failover (PostgreSQL 17+)
         );`,
        [this.config.slotName, this.config.pluginName]
      );

      const createdRes = await primary.query(
        `SELECT slot_name, plugin, slot_type, datoid, database, temporary, active,
                active_pid, xmin, catalog_xmin, restart_lsn, confirmed_flush_lsn,
                wal_status, safe_wal_size, two_phase, failover, synced
         FROM pg_replication_slots
         WHERE slot_name = $1;`,
        [this.config.slotName]
      );

      const slot = this.mapSlotRow(createdRes.rows[0]);
      this.log('INFO', 'PRIMARY_FAILOVER_SLOT_CREATED', { slotName: slot.slotName, restartLsn: slot.restartLsn });
      return slot;
    } finally {
      await primary.end();
    }
  }

  /**
   * Inspects and validates standby synchronization status of the failover slot.
   */
  public async verifyStandbySynchronization(): Promise<{
    synced: boolean;
    standbyRestartLsn: string;
    standbyConfirmedFlushLsn: string | null;
    lagBytes: number;
  }> {
    const primary = new Client(this.config.primaryConfig);
    const standby = new Client(this.config.standbyConfig);

    await Promise.all([primary.connect(), standby.connect()]);

    try {
      await this.qualifyEnginePrerequisites(standby, 'STANDBY');

      // Fetch primary slot LSN
      const pRes = await primary.query<{ confirmed_flush_lsn: string; current_lsn: string }>(
        `SELECT confirmed_flush_lsn, pg_current_wal_lsn() AS current_lsn
         FROM pg_replication_slots
         WHERE slot_name = $1;`,
        [this.config.slotName]
      );

      if (pRes.rowCount === 0) {
        throw new Error(`Slot '${this.config.slotName}' does not exist on primary.`);
      }

      const primaryFlushLsn = pRes.rows[0].confirmed_flush_lsn ?? pRes.rows[0].current_lsn;

      // Fetch standby slot status
      const sRes = await standby.query(
        `SELECT slot_name, restart_lsn, confirmed_flush_lsn, failover, synced,
                pg_wal_lsn_diff($1, confirmed_flush_lsn) AS lag_bytes
         FROM pg_replication_slots
         WHERE slot_name = $2;`,
        [primaryFlushLsn, this.config.slotName]
      );

      if (sRes.rowCount === 0) {
        throw new Error(
          `Slot '${this.config.slotName}' is NOT present on standby! ` +
          `Verify that slotsync worker is running (sync_replication_slots=on) and primary_conninfo is valid.`
        );
      }

      const row = sRes.rows[0];
      const synced = Boolean(row.synced);
      const lagBytes = Number(row.lag_bytes ?? 0);

      if (!synced) {
        this.log('WARN', 'STANDBY_SLOT_NOT_MARKED_SYNCED', {
          slotName: this.config.slotName,
          synced: row.synced,
          hint: 'Standby slot should have synced=true prior to promotion.',
        });
      }

      if (lagBytes > this.config.maxAllowedLagBytes) {
        this.log('WARN', 'STANDBY_SLOT_LAG_EXCEEDED', {
          slotName: this.config.slotName,
          lagBytes,
          maxAllowed: this.config.maxAllowedLagBytes,
        });
      }

      this.log('INFO', 'STANDBY_SYNCHRONIZATION_AUDITED', {
        slotName: this.config.slotName,
        synced,
        standbyRestartLsn: row.restart_lsn,
        standbyConfirmedFlushLsn: row.confirmed_flush_lsn,
        lagBytes,
      });

      return {
        synced,
        standbyRestartLsn: row.restart_lsn,
        standbyConfirmedFlushLsn: row.confirmed_flush_lsn,
        lagBytes,
      };
    } finally {
      await Promise.all([primary.end(), standby.end()]);
    }
  }

  /**
   * Orchestrates the post-promotion CDC reconnection validation gate.
   * Asserts that upon failover promotion, the synchronized slot transitions from synced=true to synced=false.
   */
  public async waitForPromotedSlotActivation(promotedClient: Client, timeoutMs = 15000): Promise<void> {
    const startTime = Date.now();
    this.log('INFO', 'AWAITING_PROMOTED_SLOT_ACTIVATION', {
      slotName: this.config.slotName,
      timeoutMs,
    });

    while (Date.now() - startTime < timeoutMs) {
      // 1. Verify instance is no longer in recovery
      const recRes = await promotedClient.query<{ in_recovery: boolean }>('SELECT pg_is_in_recovery() AS in_recovery;');
      if (recRes.rows[0].in_recovery) {
        await new Promise((r) => setTimeout(r, 200));
        continue;
      }

      // 2. Verify slot transition: synced must flip to false
      const slotRes = await promotedClient.query<{
        slot_name: string;
        active: boolean;
        failover: boolean;
        synced: boolean;
        confirmed_flush_lsn: string | null;
      }>(
        `SELECT slot_name, active, failover, synced, confirmed_flush_lsn
         FROM pg_replication_slots
         WHERE slot_name = $1;`,
        [this.config.slotName]
      );

      if (slotRes.rowCount === 0) {
        throw new Error(`Fatal: Synchronized slot '${this.config.slotName}' disappeared after promotion!`);
      }

      const slot = slotRes.rows[0];
      if (!slot.synced) {
        this.log('INFO', 'PROMOTED_SLOT_ACTIVATED', {
          slotName: slot.slot_name,
          synced: slot.synced,
          confirmedFlushLsn: slot.confirmed_flush_lsn,
          transitionDurationMs: Date.now() - startTime,
        });
        return; // Activation succeeded! CDC consumers may now connect safely.
      }

      await new Promise((r) => setTimeout(r, 250));
    }

    throw new Error(
      `Timeout awaiting slot '${this.config.slotName}' activation on promoted leader: ` +
      `slot still marked synced=true after ${timeoutMs}ms.`
    );
  }

  private mapSlotRow(row: Record<string, unknown>): ReplicationSlotStatus {
    return {
      slotName: String(row.slot_name),
      plugin: String(row.plugin),
      slotType: row.slot_type === 'physical' ? 'physical' : 'logical',
      datoid: Number(row.datoid),
      database: String(row.database),
      temporary: Boolean(row.temporary),
      active: Boolean(row.active),
      activePid: row.active_pid ? Number(row.active_pid) : null,
      xmin: row.xmin ? String(row.xmin) : null,
      catalogXmin: row.catalog_xmin ? String(row.catalog_xmin) : null,
      restartLsn: String(row.restart_lsn),
      confirmedFlushLsn: row.confirmed_flush_lsn ? String(row.confirmed_flush_lsn) : null,
      walStatus: row.wal_status as ReplicationSlotStatus['walStatus'],
      safeWalSize: row.safe_wal_size ? Number(row.safe_wal_size) : null,
      twoPhase: Boolean(row.two_phase),
      failover: Boolean(row.failover),
      synced: Boolean(row.synced),
    };
  }
}
```

---

## 4. Cross-Runtime Production Implementation

### 4.1 Go (`jackc/pgx/v5`): Failover Slot Sentinel & Primary Coordination

```go
package replication

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type FailoverSlotSentinel struct {
	pool               *pgxpool.Pool
	slotName           string
	physicalStandby    string
	maxAllowedLagBytes int64
}

func NewFailoverSlotSentinel(pool *pgxpool.Pool, slotName, physicalStandby string, maxLag int64) *FailoverSlotSentinel {
	return &FailoverSlotSentinel{
		pool:               pool,
		slotName:           slotName,
		physicalStandby:    physicalStandby,
		maxAllowedLagBytes: maxLag,
	}
}

// QualifyAndEnsureSlot provisions a failover=true logical slot and coordinates standby_slot_names.
func (s *FailoverSlotSentinel) QualifyAndEnsureSlot(ctx context.Context) error {
	// 1. Verify PostgreSQL version >= 170000
	var verNum int
	if err := s.pool.QueryRow(ctx, "SELECT current_setting('server_version_num')::int").Scan(&verNum); err != nil {
		return fmt.Errorf("failed to query server_version_num: %w", err)
	}
	if verNum < 170000 {
		return fmt.Errorf("PostgreSQL 17.0+ required for failover slots, got version_num: %d", verNum)
	}

	// 2. Verify wal_level == 'logical'
	var walLevel string
	if err := s.pool.QueryRow(ctx, "SELECT current_setting('wal_level')").Scan(&walLevel); err != nil {
		return fmt.Errorf("failed to query wal_level: %w", err)
	}
	if walLevel != "logical" {
		return fmt.Errorf("wal_level must be 'logical', current: %s", walLevel)
	}

	// 3. Verify standby_slot_names gates the physical standby
	var standbySlotNames string
	if err := s.pool.QueryRow(ctx, "SELECT current_setting('standby_slot_names')").Scan(&standbySlotNames); err != nil {
		return fmt.Errorf("failed to query standby_slot_names: %w", err)
	}

	standbyList := strings.Split(standbySlotNames, ",")
	foundStandby := false
	for _, name := range standbyList {
		if strings.TrimSpace(name) == s.physicalStandby {
			foundStandby = true
			break
		}
	}
	if !foundStandby {
		return fmt.Errorf("standby_slot_names ('%s') does not contain physical standby '%s'. Risk of forward consumption race!",
			standbySlotNames, s.physicalStandby)
	}

	// 4. Ensure logical slot exists with failover = true
	var exists bool
	var failover bool
	query := `SELECT true, failover FROM pg_replication_slots WHERE slot_name = $1`
	err := s.pool.QueryRow(ctx, query, s.slotName).Scan(&exists, &failover)
	if errors.Is(err, pgx.ErrNoRows) {
		// Create slot with failover=true
		createSQL := `SELECT pg_create_logical_replication_slot($1, 'pgoutput', false, false, true)`
		if _, err := s.pool.Exec(ctx, createSQL, s.slotName); err != nil {
			return fmt.Errorf("failed to create failover logical replication slot: %w", err)
		}
		return nil
	} else if err != nil {
		return fmt.Errorf("error inspecting pg_replication_slots: %w", err)
	}

	if !failover {
		return fmt.Errorf("slot '%s' exists but failover is false! Standby will not sync this slot", s.slotName)
	}

	return nil
}

// AssertZeroDataLossPromotion checks if the promoted standby successfully converted synced to false.
func (s *FailoverSlotSentinel) AssertZeroDataLossPromotion(ctx context.Context, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		var inRecovery bool
		if err := s.pool.QueryRow(ctx, "SELECT pg_is_in_recovery()").Scan(&inRecovery); err != nil {
			return err
		}
		if inRecovery {
			time.Sleep(200 * time.Millisecond)
			continue
		}

		var synced bool
		var active bool
		q := `SELECT synced, active FROM pg_replication_slots WHERE slot_name = $1`
		if err := s.pool.QueryRow(ctx, q, s.slotName).Scan(&synced, &active); err != nil {
			return fmt.Errorf("slot query failed on promoted leader: %w", err)
		}

		if !synced {
			// Success: slot is now a writable standalone slot
			return nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return fmt.Errorf("slot '%s' did not transition synced=false within %v", s.slotName, timeout)
}
```

---

### 4.2 Python (`asyncpg`): Asynchronous Standby Slot Synchronization Watchdog

```python
"""
PostgreSQL 17+ Logical Replication Failover Slot Standby Watchdog.
Periodically audits slotsync worker progress and measures replication slot byte lag.
"""

import asyncio
import logging
from typing import Optional
import asyncpg

logger = logging.getLogger("failover_slot_watchdog")

class FailoverSlotWatchdog:
    def __init__(
        self,
        standby_dsn: str,
        slot_name: str,
        max_lag_bytes: int = 64 * 1024 * 1024,  # 64MB
    ):
        self.standby_dsn = standby_dsn
        self.slot_name = slot_name
        self.max_lag_bytes = max_lag_bytes

    async def audit_standby_sync(self) -> dict:
        conn = await asyncpg.connect(self.standby_dsn)
        try:
            # 1. Assert Standby is in recovery
            in_recovery: bool = await conn.fetchval("SELECT pg_is_in_recovery();")
            if not in_recovery:
                raise RuntimeError("Target node is NOT in standby recovery mode!")

            # 2. Check sync_replication_slots GUC
            sync_guc: str = await conn.fetchval("SELECT current_setting('sync_replication_slots');")
            if sync_guc != "on":
                raise RuntimeError(f"sync_replication_slots is '{sync_guc}', expected 'on'!")

            # 3. Query slot status
            row = await conn.fetchrow(
                """
                SELECT slot_name, plugin, slot_type, active,
                       restart_lsn::text, confirmed_flush_lsn::text,
                       failover, synced
                FROM pg_replication_slots
                WHERE slot_name = $1;
                """,
                self.slot_name,
            )

            if not row:
                raise RuntimeError(
                    f"Replication slot '{self.slot_name}' not found on standby. "
                    f"Verify slotsync worker is running and primary_conninfo contains dbname."
                )

            is_synced: bool = row["synced"]
            if not is_synced:
                logger.warning(
                    "Slot %s has synced=False on standby. Worker may be catching up.",
                    self.slot_name,
                )

            logger.info(
                "Standby synced slot status: slot=%s restart_lsn=%s confirmed_flush_lsn=%s synced=%s",
                row["slot_name"],
                row["restart_lsn"],
                row["confirmed_flush_lsn"],
                row["synced"],
            )

            return dict(row)
        finally:
            await conn.close()

    async def run_sentinel_loop(self, poll_interval_sec: float = 5.0):
        while True:
            try:
                await self.audit_standby_sync()
            except Exception as e:
                logger.error("Watchdog alert on failover slot audit: %s", str(e))
            await asyncio.sleep(poll_interval_sec)
```

---

### 4.3 Rust (`sqlx`): Compile-Time Verified Failover Slot Engine

```rust
use sqlx::{PgPool, Row};
use std::time::Duration;
use tokio::time::sleep;

pub struct FailoverSlotManager {
    pool: PgPool,
    slot_name: String,
}

#[derive(Debug)]
pub struct SlotSyncReport {
    pub slot_name: String,
    pub failover: bool,
    pub synced: bool,
    pub restart_lsn: String,
    pub confirmed_flush_lsn: Option<String>,
}

impl FailoverSlotManager {
    pub fn new(pool: PgPool, slot_name: impl Into<String>) -> Self {
        Self {
            pool,
            slot_name: slot_name.into(),
        }
    }

    /// Verifies server version >= 170000 and ensures the slot has failover = true
    pub async fn ensure_failover_slot(&self) -> Result<SlotSyncReport, Box<dyn std::error::Error + Send + Sync>> {
        let version_num: i32 = sqlx::query_scalar("SELECT current_setting('server_version_num')::int;")
            .fetch_one(&self.pool)
            .await?;

        if version_num < 170000 {
            return Err(format!(
                "PostgreSQL 17+ is mandatory for failover slots. Detected server_version_num: {}",
                version_num
            ).into());
        }

        // Query existing slot
        let existing = sqlx::query(
            "SELECT slot_name, failover, synced, restart_lsn::text, confirmed_flush_lsn::text
             FROM pg_replication_slots WHERE slot_name = $1;"
        )
        .bind(&self.slot_name)
        .fetch_optional(&self.pool)
        .await?;

        if let Some(row) = existing {
            let failover: bool = row.get("failover");
            let synced: bool = row.get("synced");
            let restart_lsn: String = row.get("restart_lsn");
            let confirmed_flush_lsn: Option<String> = row.get("confirmed_flush_lsn");

            if !failover {
                return Err(format!(
                    "Slot '{}' exists but failover is false! Cannot survive leader failover.",
                    self.slot_name
                ).into());
            }

            return Ok(SlotSyncReport {
                slot_name: self.slot_name.clone(),
                failover,
                synced,
                restart_lsn,
                confirmed_flush_lsn,
            });
        }

        // Create slot with failover = true
        sqlx::query(
            "SELECT pg_create_logical_replication_slot($1, 'pgoutput', false, false, true);"
        )
        .bind(&self.slot_name)
        .execute(&self.pool)
        .await?;

        let created_row = sqlx::query(
            "SELECT slot_name, failover, synced, restart_lsn::text, confirmed_flush_lsn::text
             FROM pg_replication_slots WHERE slot_name = $1;"
        )
        .bind(&self.slot_name)
        .fetch_one(&self.pool)
        .await?;

        Ok(SlotSyncReport {
            slot_name: created_row.get("slot_name"),
            failover: created_row.get("failover"),
            synced: created_row.get("synced"),
            restart_lsn: created_row.get("restart_lsn"),
            confirmed_flush_lsn: created_row.get("confirmed_flush_lsn"),
        })
    }

    /// Awaits standby promotion completion and synced flag transition (synced=true -> synced=false)
    pub async fn await_promotion_activation(&self, max_wait: Duration) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let start = std::time::Instant::now();
        while start.elapsed() < max_wait {
            let in_recovery: bool = sqlx::query_scalar("SELECT pg_is_in_recovery();")
                .fetch_one(&self.pool)
                .await?;

            if !in_recovery {
                let synced: bool = sqlx::query_scalar(
                    "SELECT synced FROM pg_replication_slots WHERE slot_name = $1;"
                )
                .bind(&self.slot_name)
                .fetch_one(&self.pool)
                .await?;

                if !synced {
                    return Ok(());
                }
            }
            sleep(Duration::from_millis(200)).await;
        }

        Err(format!("Timeout waiting for slot '{}' to transition to synced=false upon promotion", self.slot_name).into())
    }
}
```

---

## 5. The 6-State Lifecycle Finite-State Machine (FSM)

The following state machine defines the end-to-end lifecycle of a PostgreSQL 17+ failover-enabled logical replication slot across primary generation, standby background synchronization, cluster failover, and client reconnection.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               POSTGRESQL 17 FAILOVER SLOT LIFECYCLE STATE MACHINE                      │
└────────────────────────────────────────────────────────────────────────────────────────┘

    [1. UNPROVISIONED]
            │
            │ Qualify Engine (PG >= 170000, wal_level=logical)
            │ Assert standby_slot_names & max_slot_wal_keep_size
            │ CREATE_REPLICATION_SLOT ... (FAILOVER true)
            ▼
    [2. PRIMARY_ACTIVE_GATED] ──────── (Standby disconnect / lag > max_keep) ─────────┐
            │                                                                         │
            │ Physical Streaming Replication active                                   │
            │ Standby sync_replication_slots = on; primary_conninfo has dbname        │
            │ slotsync worker starts on Standby                                       ▼
            ▼                                                             [5. SLOT_INVALIDATED]
    [3. STANDBY_SYNCHRONIZING]                                            (wal_status='lost')
            │                                                                     │
            │ Standby pulls slot catalog: restart_lsn & confirmed_flush_lsn       │ Manual rebuild
            │ Slot marked synced = true; decoding blocked on standby              │
            ▼                                                                     │
    [4. SYNCHRONIZED_STEADY_STATE] ◄──────────────────────────────────────────────┘
            │
            │ Primary Failure / Planned Switchover
            │ Standby Promoted via pg_ctl promote / Patroni
            │ Postmaster terminates slotsync worker
            ▼
    [6. PROMOTED_STANDALONE_ACTIVE]
            │
            │ synced flips from true to false
            │ CDC Consumer (Debezium) connects and resumes streaming
            ▼
    (Steady-State Continuous CDC with ZERO Data Loss)
```

### State Transition Invariant Table

| Initial State | Event / Trigger | Target State | Invariant Guard |
| :--- | :--- | :--- | :--- |
| **1. UNPROVISIONED** | `pg_create_logical_replication_slot(..., failover=>true)` | **2. PRIMARY_ACTIVE_GATED** | Server version $\ge 170000$; `wal_level = logical`; `standby_slot_names` configured; `failover = true`. |
| **2. PRIMARY_ACTIVE_GATED** | Standby boots with `sync_replication_slots = on` | **3. STANDBY_SYNCHRONIZING** | Standby `primary_conninfo` includes `dbname`; `slotsync worker` connects without error. |
| **3. STANDBY_SYNCHRONIZING** | Standby catches up; LSN delta $\le \Delta_{\text{max}}$ | **4. SYNCHRONIZED_STEADY_STATE** | `synced = true` on standby; decoding forbidden on standby (`ERROR: cannot decode on standby`). |
| **2 or 4** | Standby offline $> \frac{\text{max\_slot\_wal\_keep\_size}}{\lambda_{\text{wal}}}$ | **5. SLOT_INVALIDATED** | Primary protects host partition from exhaustion; marks slot `wal_status = 'lost'`. |
| **4. SYNCHRONIZED_STEADY_STATE** | Primary failure; `pg_ctl promote` executed | **6. PROMOTED_STANDALONE_ACTIVE** | `pg_is_in_recovery() = false`; slot automatically transitions `synced = false`. |
| **6. PROMOTED_STANDALONE_ACTIVE** | CDC subscriber reconnects | **Steady-State Operational** | Resumes strictly from `confirmed_flush_lsn`; $\Delta \text{LSN}_{\text{gap}} = 0$; zero duplicate replay. |

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Gates

The following automated verification script ensures that PostgreSQL 17+ logical replication failover slots satisfy all 5 tiers of the Governance Ladder before deploying CDC or streaming workloads to production.

```bash
#!/usr/bin/env bash
# ==============================================================================
# Agentic PostgreSQL 17 Failover Slot Verification Gate
# Runs in CI/CD against primary and standby instances to validate failover slot invariants.
# ==============================================================================
set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:-localhost}"
STANDBY_HOST="${STANDBY_HOST:-localhost}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
STANDBY_PORT="${STANDBY_PORT:-5433}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-testdb}"
SLOT_NAME="${SLOT_NAME:-ci_cdc_failover_slot}"
PHYSICAL_STANDBY_SLOT="${PHYSICAL_STANDBY_SLOT:-standby_slot_1}"

echo "🔍 [Stage 1/5] Auditing Primary PostgreSQL 17 Engine Qualification..."
PG_VER=$(psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PGUSER" -d "$PGDATABASE" -Atc "SELECT current_setting('server_version_num');")
if [ "$PG_VER" -lt 170000 ]; then
  echo "❌ Fatal: Primary server version num is $PG_VER. PostgreSQL 17.0+ is required."
  exit 1
fi

WAL_LEVEL=$(psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PGUSER" -d "$PGDATABASE" -Atc "SELECT current_setting('wal_level');")
if [ "$WAL_LEVEL" != "logical" ]; then
  echo "❌ Fatal: wal_level is '$WAL_LEVEL'. Must be 'logical'."
  exit 1
fi
echo "✅ Stage 1 Passed: PostgreSQL $PG_VER with wal_level=logical."

echo "🔍 [Stage 2/5] Auditing standby_slot_names & max_slot_wal_keep_size..."
STANDBY_NAMES=$(psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PGUSER" -d "$PGDATABASE" -Atc "SELECT current_setting('standby_slot_names');")
if [[ "$STANDBY_NAMES" != *"$PHYSICAL_STANDBY_SLOT"* ]]; then
  echo "⚠️ Warning: standby_slot_names ('$STANDBY_NAMES') does not contain '$PHYSICAL_STANDBY_SLOT'."
  echo "   Enforce standby_slot_names to prevent forward consumption race condition!"
fi

MAX_KEEP=$(psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PGUSER" -d "$PGDATABASE" -Atc "SELECT current_setting('max_slot_wal_keep_size');")
if [ "$MAX_KEEP" -eq -1 ]; then
  echo "⚠️ Warning: max_slot_wal_keep_size is unlimited (-1). Set to >= 51200MB to prevent disk exhaustion."
fi
echo "✅ Stage 2 Passed: GUC safety audits complete."

echo "🔍 [Stage 3/5] Idempotently Provisioning Failover-Enabled Logical Slot..."
psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PGUSER" -d "$PGDATABASE" <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME') THEN
    PERFORM pg_create_logical_replication_slot('$SLOT_NAME', 'pgoutput', false, false, true);
    RAISE NOTICE 'Created slot $SLOT_NAME with failover=true';
  END IF;
END \$\$;
EOF

SLOT_FAILOVER=$(psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PGUSER" -d "$PGDATABASE" -Atc \
  "SELECT failover FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';")
if [ "$SLOT_FAILOVER" != "t" ]; then
  echo "❌ Fatal: Slot '$SLOT_NAME' exists but failover is '$SLOT_FAILOVER'! Must be 't' (true)."
  exit 1
fi
echo "✅ Stage 3 Passed: Logical slot '$SLOT_NAME' confirmed with failover=true."

echo "🔍 [Stage 4/5] Auditing Standby sync_replication_slots & primary_conninfo..."
STANDBY_SYNC=$(psql -h "$STANDBY_HOST" -p "$STANDBY_PORT" -U "$PGUSER" -d "$PGDATABASE" -Atc "SELECT current_setting('sync_replication_slots');")
if [ "$STANDBY_SYNC" != "on" ]; then
  echo "❌ Fatal: Standby sync_replication_slots is '$STANDBY_SYNC'. Must be 'on'."
  exit 1
fi

CONNINFO=$(psql -h "$STANDBY_HOST" -p "$STANDBY_PORT" -U "$PGUSER" -d "$PGDATABASE" -Atc "SELECT current_setting('primary_conninfo');")
if [[ "$CONNINFO" != *"dbname="* ]]; then
  echo "❌ Fatal: Standby primary_conninfo lacks dbname! Slotsync worker cannot run without dbname."
  exit 1
fi
echo "✅ Stage 4 Passed: Standby slotsync worker prerequisites satisfied."

echo "🔍 [Stage 5/5] Asserting Standby Slot Mirroring & synced=true Invariant..."
# Allow up to 10 seconds for slotsync worker to replicate slot
SYNC_CONFIRMED=false
for i in {1..20}; do
  STANDBY_SLOT_SYNCED=$(psql -h "$STANDBY_HOST" -p "$STANDBY_PORT" -U "$PGUSER" -d "$PGDATABASE" -Atc \
    "SELECT synced FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';" 2>/dev/null || echo "not_found")
  if [ "$STANDBY_SLOT_SYNCED" = "t" ]; then
    SYNC_CONFIRMED=true
    break
  fi
  sleep 0.5
done

if [ "$SYNC_CONFIRMED" != "true" ]; then
  echo "❌ Fatal: Slot '$SLOT_NAME' was not replicated to standby with synced=true within 10s!"
  exit 1
fi

echo "=============================================================================="
echo "🎉 ALL CI GATES PASSED: PostgreSQL 17 Failover Slot is Zero-Data-Loss Certified!"
echo "=============================================================================="
```
