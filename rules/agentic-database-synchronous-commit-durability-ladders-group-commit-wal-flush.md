---
description: PostgreSQL Synchronous Commit (synchronous_commit = off, local, remote_write, on, remote_apply), replication quorum durability ladders (synchronous_standby_names ANY/FIRST), group commit physics (commit_delay, commit_siblings), NVMe fsync write stalls, WAL flush bottlenecks, and transaction-scoped durability (SET LOCAL) across Go (pgx/v5), TypeScript (drizzle/kysely/pg), Python (asyncpg/SQLAlchemy), Rust (sqlx), PostgreSQL (12-17+), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{commit,durability,wal,fsync,replication,syncrep,rpo,standby,flush,postgres,database,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Synchronous Commit, Replication Quorum Durability Ladders, Group Commit & Storage NVMe Write Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design high-throughput write pipelines, streaming event ingestion, financial ledgers, transactional outboxes, or distributed replication topologies across PostgreSQL (12–17+), Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `SQLAlchemy 2.0`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Global Synchronous Fsync Bottleneck & IOPS Burn Cliff" (where default `synchronous_commit = on` forces an `fdatasync()` system call on every single commit, capping single-threaded write throughput at 200–500 TPS due to 1–5ms storage I/O barriers and saturating disk queues), the "Global Asynchronous Blind Durability Meltdown" (where developers panicked by write latency globally disable `synchronous_commit = off` in `postgresql.conf`, leaving a 30–100ms window where acknowledged financial transactions evaporate upon hardware failure or cause catastrophic split-brain during automated failover), the "SyncRep Standby Partition & Cluster Paralysis Blockade" (where configuring `synchronous_standby_names` without health circuit breakers causes all write queries to hang indefinitely in `WaitEvent: SyncRep` when replicas experience network jitter or replay lag), the "Read-Your-Own-Writes Replica Lag Hazard" (where clients receive HTTP 200 from primary mutations under `synchronous_commit = on` but read stale data immediately from read replicas because WAL was flushed to standby disk but not yet applied into the standby buffer cache), the "Group Commit Misconfiguration Trap" (where poorly chosen `commit_delay` and `commit_siblings` add artificial latency on low-concurrency systems or fail to coalesce concurrent commits under peak load), and the "Transaction-Scope Durability Amnesia & Connection Pool Bleed" (where agents execute session-level `SET synchronous_commit` that contaminates pooled connections across transactions) by establishing a strict 5-Tier Durability Governance Ladder, commit latency physics equations, an autonomous TypeScript `AgenticDurabilityLadderGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state commit lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Durability Catastrophes vs The 5-Tier Governance Ladder

In relational database systems, the **D** (Durability) in ACID guarantees that once a transaction commits, its modifications survive crashes, power cuts, and hardware faults. PostgreSQL guarantees durability through Write-Ahead Logging (WAL): dirty shared buffer pages need not be flushed immediately to disk at commit time, provided that the transaction's commit WAL record is written and flushed to persistent media.

However, invoking an operating system `fsync()` or `fdatasync()` barrier on NVMe, SSD, or cloud-attached block storage (AWS EBS gp3/io2, GCP Persistent Disk, Azure Managed Disks) imposes a physical latency floor of **0.5ms to 5.0ms**. Under default configurations (`synchronous_commit = on`), PostgreSQL backend worker threads stall synchronously until the OS acknowledges physical storage synchronization.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│            POSTGRESQL SYNCHRONOUS COMMIT & REPLICATION DURABILITY LADDER               │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Global Fsync Bottleneck                 │ • 5-Tier Differentiated Durability:        │
│   (Default synchronous_commit=on forces   │   Enforce SET LOCAL synchronous_commit     │
│    fsync on high-velocity telemetry & logs;│   per-transaction (off for ingest/metrics, │
│    caps throughput at 350 TPS per worker) │   on for financial/auth, remote_apply read)│
│ • Global Asynchronous Blind Meltdown       │ • Strict Global Safety Default:            │
│   (Setting synchronous_commit=off globally│   postgresql.conf MUST default to 'on' or  │
│    in postgresql.conf; loses financial    │   'local'; lower durability is permitted   │
│    records upon node panic or failover)   │   STRICTLY via explicit SET LOCAL in tx.   │
│ • SyncRep Cluster Paralysis Blockade      │ • Quorum Quotas & Timeout Fallbacks:       │
│   (synchronous_standby_names = 'FIRST 1'  │   Use ANY M (s1, s2, ...) quorum replicas; │
│    causes write cluster hang when standby │   pair with statement/lock timeouts and    │
│    lags; saturates connection pool)       │   active replication health monitoring.    │
│ • Read-Your-Own-Writes Replica Lag Hazard │ • Linearizable remote_apply Routing:       │
│   (Using synchronous_commit=on causes     │   Use synchronous_commit = remote_apply    │
│    read-after-write anomalies on replicas;│   for workflows requiring instant read-    │
│    standby has flushed WAL but not applied)│  replica consistency without client lag.  │
│ • Group Commit Tuning Neglect             │ • Mathematically Tuned Group Commit:       │
│   (commit_delay left at 0; misses batch   │   Configure commit_delay (10-100µs) with   │
│    coalescence under high concurrency;    │   commit_siblings >= 5 to merge concurrent │
│    or set blindly on single-thread loads) │   WAL flushes into a single fsync barrier. │
│ • Connection Pool Setting Bleed           │ • Scoped Transaction Isolation:            │
│   (Executing SET synchronous_commit = off │   ALWAYS execute SET LOCAL within an       │
│    at session level leaks into next pooled│   explicit BEGIN...COMMIT block; clear     │
│    transaction; breaks durability silently)│  state deterministically on DISCARD ALL.  │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Durability & Synchronous Commit Catastrophes

#### Catastrophe 1: The Global Synchronous Fsync Bottleneck & IOPS Burn Cliff
Autonomous agents and developers frequently execute high-velocity event ingestion, telemetry writes, or audit logging using standard transactional drivers without tuning durability:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Default synchronous_commit on high-frequency events
BEGIN;
INSERT INTO sensor_telemetry (device_id, metric, val, recorded_at) VALUES ($1, $2, $3, NOW());
COMMIT; -- Stalls 1.5ms on EBS fsync! Capped at 600 writes/sec per connection
```
When hundreds of concurrent worker processes each issue separate `COMMIT` statements with `synchronous_commit = on`, storage IOPS queues saturate (`WaitEvent: IO:WALSync`). P99 write latency spikes from 2ms to over 250ms, while CPU utilization hovers below 15% due to threads waiting on kernel storage barriers.

#### Catastrophe 2: The Global Asynchronous Blind Durability Meltdown
In an attempt to fix Catastrophe 1, agents frequently search documentation or web forums and emit migrations or configuration changes that set `synchronous_commit = off` globally:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Disabling durability globally
ALTER SYSTEM SET synchronous_commit = 'off';
SELECT pg_reload_conf();
```
While write throughput surges, this creates a catastrophic vulnerability:
1. If the database crashes, power fails, or the OS kernel panics, up to $3 \times \text{wal\_writer\_delay}$ (by default 30–100ms) of committed transactions **evaporate**.
2. Financial ledger transactions, order payments, and password resets that returned HTTP 200 "Success" to end users disappear permanently.
3. In distributed Patroni / HA clusters, asynchronous primary loss forces failover to a replica missing those transactions, triggering split-brain and reconciliation nightmares.

#### Catastrophe 3: The SyncRep Standby Partition & Cluster Paralysis Blockade
To achieve Zero Recovery Point Objective (RPO = 0), administrators configure synchronous replication:
```sql
-- ❌ NAIVE CONFIGURATION: Single point of failure in replication quorum
synchronous_commit = 'on'
synchronous_standby_names = 'FIRST 1 (standby_node_a)'
```
If `standby_node_a` suffers transient network packet loss, high replication replay lag, or disk saturation, it stops acknowledging WAL flushes to the primary. Every subsequent write transaction on the primary database blocks indefinitely in `WaitEvent: SyncRep`. Within seconds, all application connection pool slots fill up with stalled backends, collapsing the entire microservice ecosystem.

#### Catastrophe 4: The Read-Your-Own-Writes Replica Lag Hazard (`on` vs `remote_apply`)
Developers implementing read-write splitting route mutations to primary and queries to replicas. They configure `synchronous_commit = on` expecting read consistency:
1. User updates profile picture on Primary (`synchronous_commit = on`).
2. Primary flushes WAL locally and receives confirmation that the Standby has written and fsynced the WAL record to disk. Primary returns HTTP 200 to client.
3. Client immediately requests profile picture via Read Replica.
4. **Failure**: The Standby's recovery process has NOT yet replayed the WAL record into its shared buffer cache. The user sees their old profile picture (stale read anomaly).
Only `synchronous_commit = remote_apply` guarantees that the standby has actually applied the change into memory before the primary reports success.

#### Catastrophe 5: The Group Commit Misconfiguration Trap
PostgreSQL includes a "group commit" mechanism: when multiple backend processes commit simultaneously, one backend can issue the `fsync()` for all pending commit records.
However, naive configuration induces severe penalties:
- Setting `commit_delay > 0` when `commit_siblings` is too low adds an unconditional sleep (in microseconds) to *every single transaction*, even when no other concurrent transactions exist to share the fsync.
- Leaving `commit_delay = 0` on highly concurrent systems misses the opportunity to coalesce hundreds of concurrent commits into a single disk sync.

#### Catastrophe 6: Transaction-Scope Durability Amnesia & Connection Pool Bleed
When agents attempt to use asynchronous commit for bulk jobs, they execute:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Session-level SET without transaction scoping
SET synchronous_commit = 'off';
-- Batch inserts run here...
-- Connection returned to pool without resetting synchronous_commit!
```
Because connection poolers (PgBouncer in transaction mode or HikariCP/pgx pools) reuse database sessions, subsequent critical financial transactions executed on that borrowed connection silently inherit `synchronous_commit = off`, destroying durability guarantees without throwing any errors.

---

## 2. Mathematical Formalisms & Commit Physics

### 2.1 The Commit Latency Decomposition Equation

Let $T_{\text{commit}}$ be the elapsed time between a client issuing `COMMIT` and receiving the transaction acknowledgment packet from PostgreSQL:

$$T_{\text{commit}}(\text{level}) = T_{\text{wal\_format}} + T_{\text{local\_sync}}(\text{level}) + T_{\text{network\_rep}}(\text{level}) + T_{\text{remote\_sync}}(\text{level}) + T_{\text{remote\_apply}}(\text{level})$$

Where each durability level determines which components are executed synchronously:

| Durability Level | $T_{\text{local\_sync}}$ | $T_{\text{network\_rep}}$ | $T_{\text{remote\_sync}}$ | $T_{\text{remote\_apply}}$ | Typical Commit Latency ($T_{\text{commit}}$) |
|---|---|---|---|---|---|
| `off` | $0$ (async flush) | $0$ | $0$ | $0$ | $\approx 0.05\text{ ms} - 0.2\text{ ms}$ |
| `local` | $T_{\text{fsync\_local}}$ | $0$ | $0$ | $0$ | $\approx 1.0\text{ ms} - 4.0\text{ ms}$ |
| `remote_write` | $T_{\text{fsync\_local}}$ | $2 \times \text{RTT}$ | $0$ (standby RAM write) | $0$ | $\approx 1.5\text{ ms} - 6.0\text{ ms}$ |
| `on` | $T_{\text{fsync\_local}}$ | $2 \times \text{RTT}$ | $T_{\text{fsync\_remote}}$ | $0$ | $\approx 2.5\text{ ms} - 8.0\text{ ms}$ |
| `remote_apply` | $T_{\text{fsync\_local}}$ | $2 \times \text{RTT}$ | $T_{\text{fsync\_remote}}$ | $T_{\text{replay}}$ | $\approx 3.0\text{ ms} - 12.0\text{ ms}$ |

### 2.2 Maximum Single-Thread Throughput Bound (Little's Law)

For a single dedicated database connection performing sequential transactions:

$$\text{TPS}_{\max} = \frac{1}{T_{\text{tx\_work}} + T_{\text{commit}}(\text{level})}$$

Assuming computational transaction work $T_{\text{tx\_work}} \approx 0.5\text{ ms}$:
- Under `synchronous_commit = on` on AWS EBS gp3 ($T_{\text{commit}} \approx 2.5\text{ ms}$):
  $$\text{TPS}_{\max} = \frac{1}{0.0005 + 0.0025} = 333.3 \text{ transactions/sec}$$
- Under `SET LOCAL synchronous_commit = off` ($T_{\text{commit}} \approx 0.05\text{ ms}$):
  $$\text{TPS}_{\max} = \frac{1}{0.0005 + 0.00005} = 1,818.2 \text{ transactions/sec}$$
  *(A **5.45x** single-thread throughput increase and **50x** reduction in commit barrier latency)*.

### 2.3 Asynchronous Commit RPO Upper Bound

When `synchronous_commit = off`, transactions are committed to the PostgreSQL WAL buffer in shared memory. The background `walwriter` process flushes WAL buffers to disk periodically:

$$\Delta_{\text{data\_loss\_window}} \le 3 \times \text{wal\_writer\_delay} + \delta_{\text{kernel\_flush\_jitter}}$$

With default `wal_writer_delay = 10ms`, the maximum potential data loss upon an ungraceful hardware power cut is bounded by:

$$\Delta_{\text{data\_loss\_window}} \le 3 \times 10\text{ms} + 5\text{ms} = 35\text{ms}$$

Crucially: **Zero database corruption occurs**. Upon restart, PostgreSQL crash recovery runs REDO from the last flushed checkpoint. Atomicity and consistency are preserved; only transactions committed within the final $35\text{ms}$ are omitted as if they never occurred.

### 2.4 Group Commit Coalescence Efficiency Model

When concurrency $C \ge \text{commit\_siblings}$, PostgreSQL delays the flush by $\tau = \text{commit\_delay}$ microseconds. The number of coalesced transactions $K$ sharing a single storage `fsync()` barrier follows:

$$K = 1 + \int_{0}^{\tau} \lambda_{\text{commit}}(t) \, dt \approx 1 + \lambda_{\text{commit}} \cdot \tau$$

Where $\lambda_{\text{commit}}$ is the transaction arrival rate. Effective storage I/O operations per transaction:

$$\text{IOPS}_{\text{eff}} = \frac{1}{K} = \frac{1}{1 + \lambda_{\text{commit}} \cdot \tau}$$

When $\lambda_{\text{commit}} = 10,000 \text{ tx/s}$ and $\tau = 50\mu\text{s}$:

$$K = 1 + 10,000 \times 0.00005 = 1.5 \implies 33\% \text{ reduction in physical fsync syscalls}.$$

### 2.5 Replication Quorum Availability Model

For an HA cluster with $N$ standby nodes where each standby has independent availability $p$:
Using a `FIRST 1` policy:
$$A_{\text{FIRST 1}} = p$$
Using an `ANY M (node_1, \dots, node_N)` quorum policy:
$$A_{\text{ANY M}} = \sum_{k=M}^{N} \binom{N}{k} p^k (1 - p)^{N - k}$$
For $N = 3$ standbys with individual availability $p = 0.98$, an `ANY 1` quorum yields:
$$A_{\text{ANY 1}} = 1 - (1 - 0.98)^3 = 1 - 0.000008 = 0.999992 \quad (\text{"Five Nines" availability vs 98\% for FIRST 1})$$

---

## 3. The 5-Tier Durability & Synchronous Commit Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               THE 5-TIER DURABILITY & SYNCHRONOUS COMMIT LADDER                        │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Remote Apply (Read-Your-Own-Writes Linearizability on Read Replicas)           │
│         SET LOCAL synchronous_commit = 'remote_apply'                                  │
│         Standby flushes WAL AND applies to buffer cache before primary returns ACK.    │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Synchronous Standby Quorum (Zero RPO Distributed Persistence)                 │
│         synchronous_commit = 'on' with synchronous_standby_names = 'ANY 1 (...)'       │
│         WAL fsynced to local disk + standby disk. Financial transactions & auth tokens. │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Remote OS Buffer Durability (Low-Latency Distributed Survival)                 │
│         SET LOCAL synchronous_commit = 'remote_write'                                  │
│         WAL fsynced locally, written to standby RAM. Survives primary node crash.      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Local Media Persistence (Single-Node Hardware Durability)                      │
│         synchronous_commit = 'local'                                                   │
│         WAL fsynced to local disk only. Survives local crash, replicates async.        │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: High-Throughput Asynchronous Commit (Maximum Throughput Ingest)                │
│         SET LOCAL synchronous_commit = 'off'                                           │
│         WAL committed to shared RAM buffer; no fsync wait. Bounded ~30ms loss on crash.│
└────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Tier 0: High-Throughput Asynchronous Commit (`SET LOCAL synchronous_commit = 'off'`)**:
  - Scope: Bulk staging data, batch ETL updates, telemetry ingestion, access audit logs, unread message counters, ephemeral session touches.
  - Invariant: Must always be applied via `SET LOCAL` within an explicit transaction. Never set globally in `postgresql.conf`.

- **Tier 1: Local Media Persistence (`synchronous_commit = 'local'`)**:
  - Scope: Non-distributed instances or workloads where replication lag must not block writes on the primary node, but local crashes must never lose committed data.
  - Invariant: Requires verified NVMe write barrier support and Battery-Backed Write Cache (BBWC) or reliable SSD flush.

- **Tier 2: Remote OS Buffer Durability (`SET LOCAL synchronous_commit = 'remote_write'`)**:
  - Scope: High-volume operational state where cross-node survival is required but waiting for secondary disk I/O causes unacceptably high p99 latency spikes.
  - Invariant: Standby nodes must run on separate failure domains (separate availability zones or racks).

- **Tier 3: Synchronous Standby Quorum (`synchronous_commit = 'on'`)**:
  - Scope: Financial ledgers, monetary balances, user authentication credentials, payment state transitions, idempotency key reservations.
  - Invariant: Cluster replication MUST configure quorum matching (`synchronous_standby_names = 'ANY M (node1, node2, ...)'`), never fragile priority matching (`FIRST 1`).

- **Tier 4: Remote Apply Consistency (`SET LOCAL synchronous_commit = 'remote_apply'`)**:
  - Scope: Workflows where a user immediately modifies a resource and is redirected to a read-replica-backed view (e.g. checkout confirmation, order history page).
  - Invariant: Standby recovery processes must not be bottlenecked by long-running analytical queries (`max_standby_streaming_delay` must be tuned).

---

## 4. Production Code Implementations

### 4.1 Go (`jackc/pgx/v5`): Differentiated Durability Pipeline with Quorum Fallbacks

```go
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// DurabilityLevel defines explicit transaction-scoped persistence guarantees.
type DurabilityLevel string

const (
	DurabilityAsync       DurabilityLevel = "off"
	DurabilityLocal       DurabilityLevel = "local"
	DurabilityRemoteWrite DurabilityLevel = "remote_write"
	DurabilitySyncStandby DurabilityLevel = "on"
	DurabilityRemoteApply DurabilityLevel = "remote_apply"
)

type DurabilityConfig struct {
	Level   DurabilityLevel
	Timeout time.Duration
}

type LedgerRepository struct {
	pool *pgxpool.Pool
}

func NewLedgerRepository(pool *pgxpool.Pool) *LedgerRepository {
	return &LedgerRepository{pool: pool}
}

// ExecuteWithDurability runs a transaction with guaranteed transaction-scoped synchronous_commit.
// INVARIANT: Uses SET LOCAL to ensure durability settings never leak into pooled connections.
func (r *LedgerRepository) ExecuteWithDurability(
	ctx context.Context,
	cfg DurabilityConfig,
	fn func(tx pgx.Tx) error,
) error {
	txTimeout := cfg.Timeout
	if txTimeout <= 0 {
		txTimeout = 5 * time.Second
	}

	txCtx, cancel := context.WithTimeout(ctx, txTimeout)
	defer cancel()

	tx, err := r.pool.Begin(txCtx)
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(context.WithoutCancel(txCtx))

	// 1. Enforce transaction-scoped durability level via SET LOCAL
	setQuery := fmt.Sprintf("SET LOCAL synchronous_commit = '%s'", cfg.Level)
	if _, err := tx.Exec(txCtx, setQuery); err != nil {
		return fmt.Errorf("set local synchronous_commit (%s): %w", cfg.Level, err)
	}

	// 2. Execute business logic within transaction
	if err := fn(tx); err != nil {
		return err
	}

	// 3. Commit with specified durability. If SyncRep times out, surface explicit error.
	if err := tx.Commit(txCtx); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.SQLState() == "57014" {
			return fmt.Errorf("transaction commit timed out waiting for replication quorum (%s): %w", cfg.Level, err)
		}
		return fmt.Errorf("commit transaction: %w", err)
	}

	return nil
}

// RecordFinancialMutation records critical double-entry transfers under Tier 3 synchronous standby durability.
func (r *LedgerRepository) RecordFinancialMutation(
	ctx context.Context,
	sourceAccountID string,
	targetAccountID string,
	amountCents int64,
) error {
	cfg := DurabilityConfig{
		Level:   DurabilitySyncStandby, // Tier 3: Zero-RPO guarantee across standby quorum
		Timeout: 3 * time.Second,
	}

	return r.ExecuteWithDurability(ctx, cfg, func(tx pgx.Tx) error {
		// Debit source
		_, err := tx.Exec(ctx, `
			UPDATE accounts 
			SET balance_cents = balance_cents - $1, updated_at = NOW() 
			WHERE id = $2 AND balance_cents >= $1;
		`, amountCents, sourceAccountID)
		if err != nil {
			return fmt.Errorf("debit source account: %w", err)
		}

		// Credit target
		_, err = tx.Exec(ctx, `
			UPDATE accounts 
			SET balance_cents = balance_cents + $1, updated_at = NOW() 
			WHERE id = $2;
		`, amountCents, targetAccountID)
		if err != nil {
			return fmt.Errorf("credit target account: %w", err)
		}

		return nil
	})
}

// IngestTelemetryBatch inserts high-volume telemetry events under Tier 0 asynchronous commit.
// INVARIANT: Achieves 30,000+ writes/sec by bypassing fsync while maintaining ACID atomicity.
func (r *LedgerRepository) IngestTelemetryBatch(
	ctx context.Context,
	events []struct {
		DeviceID string
		Metric   string
		Value    float64
	},
) error {
	cfg := DurabilityConfig{
		Level:   DurabilityAsync, // Tier 0: Bypasses fsync barrier for maximum throughput
		Timeout: 2 * time.Second,
	}

	return r.ExecuteWithDurability(ctx, cfg, func(tx pgx.Tx) error {
		b := &pgx.Batch{}
		for _, e := range events {
			b.Queue(`
				INSERT INTO device_telemetry (device_id, metric, value, recorded_at)
				VALUES ($1, $2, $3, NOW());
			`, e.DeviceID, e.Metric, e.Value)
		}

		br := tx.SendBatch(ctx, b)
		defer br.Close()

		for i := 0; i < len(events); i++ {
			if _, err := br.Exec(); err != nil {
				return fmt.Errorf("exec batch item %d: %w", i, err)
			}
		}

		return nil
	})
}
```

### 4.2 TypeScript / Node.js (`Kysely` / `pg`): Scoped Durability Helper

```typescript
import { Kysely, sql, Transaction } from 'kysely';

export type DurabilityTier = 'off' | 'local' | 'remote_write' | 'on' | 'remote_apply';

export interface DurabilityOptions {
  tier: DurabilityTier;
  timeoutMs?: number;
}

/**
 * Executes a database operation within an explicit transaction with scoped durability.
 * Uses `SET LOCAL synchronous_commit` to eliminate connection pool pollution.
 */
export async function withDurability<DB, T>(
  db: Kysely<DB>,
  options: DurabilityOptions,
  operation: (tx: Transaction<DB>) => Promise<T>
): Promise<T> {
  const { tier, timeoutMs = 5000 } = options;

  return await db.transaction().execute(async (tx) => {
    // 1. Apply timeout ladder for the transaction
    await sql`SET LOCAL statement_timeout = ${sql.raw(timeoutMs.toString())}`.execute(tx);

    // 2. Set transaction-scoped synchronous_commit
    await sql`SET LOCAL synchronous_commit = ${sql.raw(`'${tier}'`)}`.execute(tx);

    // 3. Execute payload
    return await operation(tx);
  });
}

// Example usage: Critical Auth Token vs Non-Critical Access Log
export async function authenticateAndLog(
  db: Kysely<any>,
  userId: string,
  tokenHash: string,
  ipAddress: string
): Promise<void> {
  // Financial/Auth: Tier 3 (Synchronous Standby Durability)
  await withDurability(db, { tier: 'on' }, async (tx) => {
    await tx
      .insertInto('user_sessions')
      .values({
        user_id: userId,
        session_token: tokenHash,
        created_at: new Date(),
      })
      .execute();
  });

  // Access Log: Tier 0 (Asynchronous Commit - Zero fsync wait)
  await withDurability(db, { tier: 'off' }, async (tx) => {
    await tx
      .insertInto('access_audit_logs')
      .values({
        user_id: userId,
        action: 'LOGIN',
        ip_address: ipAddress,
        logged_at: new Date(),
      })
      .execute();
  });
}
```

### 4.3 Python (`asyncpg`): Context-Managed Durability Scoping

```python
import asyncpg
from typing import AsyncGenerator, Callable, Any
from contextlib import asynccontextmanager

DURABILITY_TIERS = {"off", "local", "remote_write", "on", "remote_apply"}

@asynccontextmanager
async def transactional_durability(
    pool: asyncpg.Pool,
    tier: str = "on",
    timeout_sec: float = 5.0
) -> AsyncGenerator[asyncpg.Connection, None]:
    """
    Async context manager enforcing transaction-scoped synchronous_commit.
    Guarantees no session bleeding across connection pool reuse.
    """
    if tier not in DURABILITY_TIERS:
        raise ValueError(f"Invalid durability tier: {tier}. Must be one of {DURABILITY_TIERS}")

    async with pool.acquire() as conn:
        async with conn.transaction():
            # Set transaction-scoped durability and statement timeout
            await conn.execute(f"SET LOCAL synchronous_commit = '{tier}'")
            await conn.execute(f"SET LOCAL statement_timeout = '{int(timeout_sec * 1000)}ms'")
            try:
                yield conn
            except Exception:
                raise

async def record_payment(pool: asyncpg.Pool, order_id: str, amount_cents: int) -> None:
    # Tier 4: Remote apply ensures read replica immediately reflects paid state
    async with transactional_durability(pool, tier="remote_apply", timeout_sec=3.0) as conn:
        await conn.execute(
            """
            UPDATE orders 
            SET status = 'PAID', paid_amount_cents = $1, updated_at = NOW()
            WHERE id = $2;
            """,
            amount_cents, order_id
        )
```

### 4.4 Rust (`sqlx`): Strict Scoped Durability Transactions

```rust
use sqlx::{PgPool, Postgres, Transaction, Error};

#[derive(Debug, Clone, Copy)]
pub enum DurabilityTier {
    Async,        // "off"
    Local,        // "local"
    RemoteWrite,  // "remote_write"
    SyncStandby,  // "on"
    RemoteApply,  // "remote_apply"
}

impl DurabilityTier {
    pub fn as_sql(&self) -> &'static str {
        match self {
            Self::Async => "off",
            Self::Local => "local",
            Self::RemoteWrite => "remote_write",
            Self::SyncStandby => "on",
            Self::RemoteApply => "remote_apply",
        }
    }
}

pub async fn execute_with_durability<F, T>(
    pool: &PgPool,
    tier: DurabilityTier,
    f: F,
) -> Result<T, Error>
where
    F: for<'c> FnOnce(&'c mut Transaction<'_, Postgres>) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<T, Error>> + Send + 'c>>,
{
    let mut tx = pool.begin().await?;

    // INVARIANT: Always use SET LOCAL within explicit transaction to avoid connection leak
    let set_cmd = format!("SET LOCAL synchronous_commit = '{}'", tier.as_sql());
    sqlx::query(&set_cmd).execute(&mut *tx).await?;

    let result = f(&mut tx).await?;

    tx.commit().await?;
    Ok(result)
}
```

---

## 5. Autonomous TypeScript Guard Engine

```typescript
import { z } from 'zod';

export interface DurabilityAuditReport {
  isCompliant: boolean;
  clusterSetting: string;
  standbyQuorumMode: 'priority' | 'quorum' | 'none';
  riskScore: number; // 0 - 100
  violations: string[];
  recommendations: string[];
  remediatedConfig: Record<string, string>;
}

export class AgenticDurabilityLadderGuardEngine {
  /**
   * Audits PostgreSQL postgresql.conf and active session configurations for
   * synchronous commit and group commit durability hazards.
   */
  public static auditConfiguration(config: {
    synchronous_commit: string;
    synchronous_standby_names: string;
    commit_delay: number;
    commit_siblings: number;
    wal_writer_delay: number;
  }): DurabilityAuditReport {
    const violations: string[] = [];
    const recommendations: string[] = [];
    let riskScore = 0;
    const remediatedConfig: Record<string, string> = {};

    const syncCommit = config.synchronous_commit.toLowerCase().trim();
    const standbyNames = config.synchronous_standby_names.trim();
    const commitDelay = config.commit_delay;
    const commitSiblings = config.commit_siblings;

    // 1. Check Global synchronous_commit = off hazard
    if (syncCommit === 'off') {
      riskScore += 50;
      violations.push(
        'GLOBAL_ASYNC_COMMIT_DANGER: synchronous_commit is globally set to "off". A sudden server crash or kernel panic will cause unrecoverable loss of committed financial, auth, and state data.'
      );
      recommendations.push(
        'Set global synchronous_commit = "on" in postgresql.conf. Use "SET LOCAL synchronous_commit = off" strictly inside individual non-critical transactions (e.g. bulk ingest, telemetry).'
      );
      remediatedConfig['synchronous_commit'] = 'on';
    }

    // 2. Check Synchronous Standby Quorum Architecture
    let standbyQuorumMode: 'priority' | 'quorum' | 'none' = 'none';
    if (standbyNames.length > 0) {
      if (/^ANY\s+\d+/i.test(standbyNames)) {
        standbyQuorumMode = 'quorum';
      } else if (/^FIRST\s+\d+/i.test(standbyNames) || !/^(ANY|FIRST)/i.test(standbyNames)) {
        standbyQuorumMode = 'priority';
        riskScore += 25;
        violations.push(
          `STANDBY_PRIORITY_HAZARD: synchronous_standby_names uses FIRST priority ('${standbyNames}'). If the primary standby lags or drops, writes will stall even if other standbys are healthy.`
        );
        recommendations.push(
          'Migrate to quorum replication: synchronous_standby_names = "ANY 1 (node1, node2, node3)".'
        );
        remediatedConfig['synchronous_standby_names'] = standbyNames.replace(/^FIRST/i, 'ANY');
      }
    }

    // 3. Check Group Commit Misconfiguration
    if (commitDelay > 0 && commitSiblings < 1) {
      riskScore += 20;
      violations.push(
        `GROUP_COMMIT_UNCONDITIONAL_STALL: commit_delay is ${commitDelay}µs but commit_siblings is ${commitSiblings}. Every transaction unconditionally sleeps without waiting for concurrent peers.`
      );
      recommendations.push(
        'Ensure commit_siblings >= 5 when commit_delay > 0, or set commit_delay = 0 for single-client workloads.'
      );
      remediatedConfig['commit_siblings'] = '5';
    }

    if (commitDelay === 0 && commitSiblings > 0) {
      recommendations.push(
        'High concurrency detected: Consider setting commit_delay = 20-50µs with commit_siblings = 5 to coalesce concurrent WAL fsync calls.'
      );
    }

    return {
      isCompliant: violations.length === 0,
      clusterSetting: syncCommit,
      standbyQuorumMode,
      riskScore: Math.min(100, riskScore),
      violations,
      recommendations,
      remediatedConfig,
    };
  }

  /**
   * Audits application SQL queries for connection pool bleed of session-level synchronous_commit.
   */
  public static auditApplicationQuery(sqlQuery: string): { isCompliant: boolean; warning?: string } {
    const isSessionLevelSet = /^\s*SET\s+synchronous_commit\s*=/i.test(sqlQuery);
    const isSetLocal = /^\s*SET\s+LOCAL\s+synchronous_commit\s*=/i.test(sqlQuery);

    if (isSessionLevelSet && !isSetLocal) {
      return {
        isCompliant: false,
        warning:
          'CONNECTION_POOL_BLEED: Executing session-level "SET synchronous_commit" bleeds into subsequent pooled transactions. Always use "SET LOCAL synchronous_commit" inside an explicit BEGIN...COMMIT block.',
      };
    }

    return { isCompliant: true };
  }
}
```

---

## 6. The 6-State Commit & Durability Lifecycle Finite-State Machine (FSM)

```
        ┌────────────────────────────────────────────────────────┐
        │ 1. IN_FLIGHT (Mutations buffered in shared_buffers)    │
        └───────────────────────────┬────────────────────────────┘
                                    │ Backend calls COMMIT
                                    ▼
        ┌────────────────────────────────────────────────────────┐
        │ 2. WAL_DIRTIED (Commit record queued in wal_buffers)   │
        └───────────────────────────┬────────────────────────────┘
                                    │
           ┌────────────────────────┴────────────────────────┐
           │ Level == 'off'                                  │ Level >= 'local'
           ▼                                                 ▼
┌───────────────────────┐                         ┌───────────────────────┐
│ 3. ASYNC_LOCAL_ACK    │                         │ 4. LOCAL_FSYNC_STALL  │
│ (0ms wait; client ACK)│                         │ (fdatasync to NVMe)   │
└───────────────────────┘                         └───────────┬───────────┘
                                                              │
                     ┌────────────────────────────────────────┴─────────────────────┐
                     │ Level == 'local' or standalone                               │ Level >= 'remote_write'
                     ▼                                                              ▼
          ┌───────────────────────┐                                     ┌───────────────────────┐
          │ 5. LOCAL_MEDIA_DURABLE│                                     │ 6. SYNC_REP_BROADCAST │
          │ (Acknowledged to user)│                                     │ (WaitEvent: SyncRep)  │
          └───────────────────────┘                                     └───────────┬───────────┘
                                                                                    │
                                 ┌──────────────────────────────────────────────────┴─────────────┐
                                 │ Level == 'remote_write'                                        │ Level == 'on' or 'remote_apply'
                                 ▼                                                                ▼
                      ┌──────────────────────┐                                         ┌──────────────────────┐
                      │ STANDBY_RAM_CONFIRMED│                                         │ STANDBY_FSYNC_OR_APP │
                      │ (ACK to client)      │                                         │ (Full zero-RPO ACK)  │
                      └──────────────────────┘                                         └──────────────────────┘
```

| State | Entry Trigger | Exit Condition | Invariant Bound |
|---|---|---|---|
| **1. IN_FLIGHT** | DML Execution (`INSERT`/`UPDATE`) | Client issues `COMMIT` | Rows reside in dirty shared memory buffers |
| **2. WAL_DIRTIED** | `COMMIT` parsed by backend | Check `synchronous_commit` | Commit LSN assigned in `wal_buffers` |
| **3. ASYNC_LOCAL_ACK** | `synchronous_commit = off` | Immediate packet write to client | Latency $\le 0.1\text{ms}$; data loss risk $\le 35\text{ms}$ |
| **4. LOCAL_FSYNC_STALL** | `synchronous_commit >= local` | Kernel returns from `fdatasync()` | Physical disk barrier latency $0.5\text{ms} - 4.0\text{ms}$ |
| **5. LOCAL_MEDIA_DURABLE**| Local fsync acknowledged | Complete transaction if local | Local RPO = 0; survives primary power loss |
| **6. SYNC_REP_BROADCAST** | `synchronous_commit >= remote`| Standby confirms WAL reception | Stalls on network RTT + standby flush/apply |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Every autonomous pull request, migration, and infrastructure change altering database durability, replication, or high-throughput write paths MUST satisfy the following six automated gates:

```sql
-- GATE 1: Verify global synchronous_commit is NOT disabled in cluster configuration
SELECT name, setting, source 
FROM pg_settings 
WHERE name = 'synchronous_commit';
-- ASSERTION: setting IN ('on', 'local', 'remote_write', 'remote_apply'). 
-- 'off' is STRICTLY FORBIDDEN at the cluster (postgresql.conf) level.

-- GATE 2: Verify synchronous standby quorum uses ANY M, not fragile FIRST
SELECT name, setting 
FROM pg_settings 
WHERE name = 'synchronous_standby_names';
-- ASSERTION: If non-empty, MUST match '^ANY\s+\d+' or contain multi-node quorum.

-- GATE 3: Verify Group Commit invariants (commit_delay requires commit_siblings >= 5)
SELECT 
  (SELECT setting::int FROM pg_settings WHERE name = 'commit_delay') AS delay,
  (SELECT setting::int FROM pg_settings WHERE name = 'commit_siblings') AS siblings;
-- ASSERTION: (delay == 0) OR (delay > 0 AND siblings >= 5).

-- GATE 4: Inspect active replication sync state and sync_priority
SELECT application_name, client_addr, state, sync_state, sync_priority 
FROM pg_stat_replication;
-- ASSERTION: sync_state IN ('sync', 'quorum') for active synchronous standbys.

-- GATE 5: Audit codebase for session-level SET synchronous_commit leaks
-- Shell regex check across all SQL/repository files:
-- grep -rnE "^\s*SET\s+synchronous_commit" src/ internal/
-- ASSERTION: 0 matches. All occurrences MUST use "SET LOCAL synchronous_commit".

-- GATE 6: Monitor WAL write sync wait events during load testing
SELECT wait_event, count(*) 
FROM pg_stat_activity 
WHERE wait_event IN ('SyncRep', 'WALSync', 'WALWrite')
GROUP BY wait_event;
-- ASSERTION: SyncRep stall count must remain < 5% of active backend pool under peak TPS.
```
