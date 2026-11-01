---
description: PostgreSQL replication slots, WAL retention mechanics, disk exhaustion prevention, max_slot_wal_keep_size tuning, orphaned consumer reaping, catalog_xmin vacuum horizon fencing, and PostgreSQL 17 failover slot synchronization across Go (pgx/v5), TypeScript (Kysely, Drizzle), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{slot,replication,wal,cdc,debezium,standby,replica,storage,database,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/cdc/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/replication/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Replication Slots, WAL Disk Exhaustion, Inactive Slot Invalidation & Failover Synchronization Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design physical streaming replicas, Change Data Capture (CDC) pipelines (Debezium, Kafka Connect, Fivetran), logical decoding subscribers, or temporary migration workflows across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Indefinite WAL Pinning & 100% Filesystem Panic Trap" (where a disconnected physical replica, crashed CDC consumer, or orphaned test slot holds `restart_lsn`, forbidding PostgreSQL from recycling 16MB WAL segments until the filesystem reaches 100% capacity and postmaster terminates in an unstartable `PANIC: could not write to log file: No space left on device`), the "Missing `max_slot_wal_keep_size` Hazard" (where default `max_slot_wal_keep_size = -1` allows an unattended slot to sacrifice the entire primary database cluster rather than invalidating the lagging subscriber with `wal_status = 'lost'`), the "Logical Slot `catalog_xmin` Autovacuum Freeze Disaster" (where an inactive logical slot pins the vacuum horizon across system catalogs, preventing autovacuum from cleaning dead tuples in `pg_class`, `pg_attribute`, and `pg_type`, causing catastrophic catalog bloat and multi-second DDL locks), the "Autonomous Test Slot Abandonment Trap" (where agents create ephemeral logical replication slots for testing or data migration but omit `pg_drop_replication_slot()` in error handlers, silently creating zombie disk-eating slots on production and staging clusters), the "Failover Promotion Slot Amnesia" (where pre-PostgreSQL 17 logical slots fail to replicate to physical standbys, causing CDC pipelines to collapse or lose data upon primary failover due to missing subscriber state), and the "Silent Lag Blindness & Unmonitored Inactive Slot Drift" (where monitoring tools track replica query lag in seconds but fail to measure physical WAL byte lag `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)`, hiding impending disk exhaustion until minutes before total outage) by establishing a strict 5-Tier Replication Slot & WAL Governance Ladder, rigorous disk exhaustion differential equations, an autonomous TypeScript `AgenticReplicationSlotGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state slot lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Replication Slot Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, Write-Ahead Logging (WAL) ensures durability (ACID "D") and powers point-in-time recovery (PITR) as well as replication. When transactions commit, their changes are appended to 16MB WAL segments residing in the `pg_wal` directory. Under normal operation, checkpoints recycle or remove WAL segments that have been flushed to heap/index files and are no longer required for crash recovery.

However, when a **Physical Replication Slot** or **Logical Replication Slot** is created (`pg_create_physical_replication_slot()` or `pg_create_logical_replication_slot()`), the PostgreSQL storage engine registers an immutable cursor in `pg_replication_slots`:
1. **The `restart_lsn` Anchor**: PostgreSQL is strictly prohibited by design from recycling or unlinking any WAL segment containing transactions at or newer than the oldest `restart_lsn` across all configured replication slots.
2. **The `confirmed_flush_lsn` (Logical Only)**: Represents the highest LSN up to which the logical consumer has acknowledged receiving and persisting decoded changes.
3. **The `catalog_xmin` (Logical Only)**: Represents the oldest transaction ID whose system catalog tuples must be preserved for logical decoding. Autovacuum CANNOT clean dead tuples in system catalogs (`pg_class`, `pg_attribute`, `pg_type`, `pg_am`, etc.) with `xmin >= catalog_xmin`.

When autonomous coding agents deploy CDC tools, configure read replicas, or execute automated migration scripts, LLMs routinely commit 6 catastrophic replication slot anti-patterns:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             POSTGRESQL WAL RETENTION & REPLICATION SLOT PINNING MECHANISM              │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Transaction Commits ──► [ WAL Segment 001 ] ──► [ WAL Segment 002 ] ──► [ WAL 003 ]     │
│                              │                                             ▲           │
│                              ▼                                             │           │
│                   Slot: cdc_debezium_slot                                  │           │
│                   restart_lsn: 0/1A00000 (Pinned!)                         │           │
│                   active: false (Consumer crashed!)                        │           │
│                              │                                             │           │
│                              ▼                                             │           │
│ Checkpoint Attempts Cleanup: ❌ BLOCKED! Cannot recycle segments >= restart_lsn       │
│                                                                                        │
│ Disk Status:                                                                           │
│ [██████████████████████████████████████████████████████████████░░░░░] 85% Full         │
│ [████████████████████████████████████████████████████████████████████] 100% Full!       │
│                                                                                        │
│ Result: PANIC: could not write to log file: No space left on device                    │
│ Entire Database Shuts Down! Cannot restart without manual emergency intervention!      │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│                NAIVE SLOT MANAGEMENT vs RIGOROUS REPLICATION INVARIANTS                │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Leave default max_slot_wal_keep_size    │ • Enforce max_slot_wal_keep_size = 50GB    │
│   = -1 (unlimited). A stalled replica or  │   (or 25% free disk). Sacrifices the       │
│   crashed CDC slot crashes the primary!   │   lagging slot (wal_status='lost') to save │
│                                           │   the primary database from 100% panic!   │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Create temporary test or migration      │ • Register slots with strict deterministic │
│   slots ('temp_test_slot') without        │   naming, automated TTL leases, and drop   │
│   cleanup, or fail to drop in error paths.│   guards (`pg_drop_replication_slot()`).   │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Ignore inactive slots (active = false). │ • Automated watchdog reaper drops or       │
│   Consumer is dead for days, silently     │   invalidates inactive slots exceeding     │
│   pinning tens of gigabytes of WAL.       │   inactivity threshold (e.g. 15 minutes).  │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Ignore logical catalog_xmin pinning.   │ • Monitor max(age(catalog_xmin)) <= 500k.  │
│   System catalogs bloat by 50x,           │   Terminate consumers pinning catalog      │
│   degrading query planning and DDL locks. │   horizons before catalog autovacuum stops.│
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Unsynchronized logical slots during HA  │ • PostgreSQL 17+: failover = true and      │
│   failover. Downstream CDC loses state.   │   sync_replication_slots = on. Pre-PG17:   │
│                                           │   Patroni pg_failover_slots synchronization│
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Monitor only replica replay lag (time). │ • Instrument byte-accurate WAL lag:        │
│   Misses fast-accumulating WAL bytes on   │   pg_wal_lsn_diff(pg_current_wal_lsn(),    │
│   high-throughput write workloads.        │   restart_lsn) with P1 alarm at >= 10GB.   │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

---

## 2. Mathematical Formalisms & Replication Storage Physics

### 2.1 The WAL Accumulation Differential Equation

Let $R_{\text{gen}}(t)$ be the WAL generation rate in bytes per second on the primary database, driven by transaction concurrency, row payload sizes, and index updates:

$$R_{\text{gen}}(t) = \sum_{i=1}^{N_{\text{tps}}} \left( S_{\text{tuple}, i} + \sum_{k=1}^{M_{\text{idx}}} S_{\text{index\_key}, i, k} + S_{\text{wal\_header}} \right) \cdot \alpha_{\text{full\_page\_writes}}$$

When a replication slot $s$ is active, its consumer acknowledges WAL at consumption rate $R_{\text{consume}, s}(t)$. The rate of retained WAL storage $W_s(t)$ pinned by slot $s$ is governed by the differential equation:

$$\frac{dW_s}{dt} = R_{\text{gen}}(t) - \mathbf{1}_{\{\text{active}(s)\}} \cdot R_{\text{consume}, s}(t)$$

Where $\mathbf{1}_{\{\text{active}(s)\}} \in \{0, 1\}$ represents consumer activity. If the consumer crashes or disconnects ($\mathbf{1} = 0$), consumption drops to zero, and:

$$\frac{dW_s}{dt} = R_{\text{gen}}(t) \implies W_s(t) = W_s(t_0) + \int_{t_0}^{t} R_{\text{gen}}(\tau) \, d\tau$$

### 2.2 Time to Primary Disk Exhaustion ($T_{\text{exhaustion}}$)

Let $D_{\text{avail}}(t)$ be the available disk bytes on the partition housing `pg_wal`. The time remaining until catastrophic disk exhaustion ($D_{\text{avail}} = 0$) under an inactive or lagging slot is:

$$T_{\text{exhaustion}} = \frac{D_{\text{avail}}(t_0)}{\bar{R}_{\text{gen}} - \mathbf{1}_{\{\text{active}\}} \cdot \bar{R}_{\text{consume}}}$$

*Empirical Example*: On a high-throughput payment or streaming system generating $\bar{R}_{\text{gen}} = 50\text{ MB/s}$ of WAL, with $D_{\text{avail}} = 100\text{ GB}$:
$$T_{\text{exhaustion}} = \frac{100 \times 10^9 \text{ bytes}}{50 \times 10^6 \text{ bytes/s}} = 2000 \text{ seconds} \approx 33.3 \text{ minutes}$$

An unmonitored inactive CDC slot will bring down the entire primary production cluster in **33 minutes**!

### 2.3 The `max_slot_wal_keep_size` Bounding Theorem

To prevent total database panic, PostgreSQL introduces `max_slot_wal_keep_size`. When configured to a finite upper bound $K_{\text{wal\_max}}$:

$$W_s(t) = \min\left( \int_{t_{\text{restart}}}^{t} R_{\text{gen}}(\tau) \, d\tau, \; K_{\text{wal\_max}} \right)$$

If $\text{Lag}(s) > K_{\text{wal\_max}}$, PostgreSQL sets:
$$\text{wal\_status} = \text{'lost'}$$
and releases WAL segments older than $K_{\text{wal\_max}}$ for immediate recycling. 

**Theorem (Cluster Survival vs Consumer Sacrificing)**: Setting $K_{\text{wal\_max}} \le \phi \cdot D_{\text{total\_wal\_disk}}$ where $\phi \in [0.20, 0.40]$ guarantees that no individual lagging or dead subscriber can ever drive primary storage into $D_{\text{avail}} = 0$.

### 2.4 System Catalog Vacuum Horizon Drift

For logical replication slots, the slot holds a catalog horizon $x_{\text{min\_cat}}$. The dead catalog tuple accumulation $\Delta N_{\text{dead\_cat}}$ across `pg_class`, `pg_attribute`, and `pg_type` over time $t$ is:

$$\Delta N_{\text{dead\_cat}}(t) = \int_{0}^{t} \lambda_{\text{DDL}}(\tau) \cdot \bar{T}_{\text{meta}} \, d\tau$$

Because autovacuum is legally forbidden to prune tuples where $\text{xmin} \ge x_{\text{min\_cat}}$, catalog scan cost degrades linearly with transaction horizon age:

$$C_{\text{cat\_scan}} \propto O(N_{\text{live\_cat}} + \Delta N_{\text{dead\_cat}}(t))$$

When $\text{age}(x_{\text{min\_cat}}) \ge 1,000,000$, standard catalog cache lookups and schema validations slow down by orders of magnitude, causing connection timeouts and lock queue avalanches.

---

## 3. The 5-Tier Replication Slot & WAL Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             THE 5-TIER REPLICATION SLOT & WAL GOVERNANCE LADDER                        │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Zero-Orphan CI Gates & HA Failover Slot Sync (PG17 failover=true / Patroni)    │
│    ▲                                                                                   │
│    │                                                                                   │
│ Tier 3: Logical Slot catalog_xmin & System Catalog Vacuum Horizon Sentinel            │
│    ▲                                                                                   │
│    │                                                                                   │
│ Tier 2: Inactive & Orphaned Slot Automated Reaper (TTL & Inactivity Expiry)            │
│    ▲                                                                                   │
│    │                                                                                   │
│ Tier 1: Real-Time WAL Byte Lag Telemetry & pg_replication_slots Health Sentinel        │
│    ▲                                                                                   │
│    │                                                                                   │
│ Tier 0: Global Safety Ceiling Configuration (max_slot_wal_keep_size = 50GB, never -1)  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Tier 0: Global Safety Ceiling Configuration (`max_slot_wal_keep_size`)

Never allow `max_slot_wal_keep_size = -1` in production. Always set a bounded limit:
```sql
-- Enforce bounded WAL retention for replication slots
-- Size between 20GB and 100GB depending on disk volume size
ALTER SYSTEM SET max_slot_wal_keep_size = '50GB';
SELECT pg_reload_conf();
```

### 3.2 Tier 1: Real-Time Telemetry & Health Sentinel Query

Continuously audit `pg_replication_slots` for byte lag, `wal_status`, and consumer activity:
```sql
-- Comprehensive Replication Slot Health & Lag Inspection
SELECT 
    slot_name,
    plugin,
    slot_type,
    active,
    active_pid,
    wal_status,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_lag,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS wal_lag_bytes,
    COALESCE(pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)), 'N/A') AS flush_lag,
    age(catalog_xmin) AS catalog_xmin_age,
    safe_wal_size
FROM pg_replication_slots;
```

### 3.3 Tier 2: Inactive & Orphaned Slot Automated Reaper

Any slot where `active = false` for more than 15 minutes or where `wal_status IN ('unreserved', 'lost')` must be terminated before disk space is threatened:
```sql
-- Drop an inactive orphaned replication slot
SELECT pg_drop_replication_slot('orphaned_slot_name');
```

### 3.4 Tier 3: Logical Slot `catalog_xmin` Guard

Monitor `catalog_xmin` age. If `age(catalog_xmin) > 500,000`, alert immediately; if `age(catalog_xmin) > 2,000,000`, drop or reset the slot to prevent transaction ID wraparound emergency:
```sql
SELECT slot_name, age(catalog_xmin) AS xmin_age
FROM pg_replication_slots
WHERE slot_type = 'logical' AND age(catalog_xmin) > 500000;
```

### 3.5 Tier 4: HA Failover Slot Synchronization (PostgreSQL 17+)

In PostgreSQL 17+, configure logical slots with `failover = true` and enable `sync_replication_slots = on` on standby servers:
```sql
-- PostgreSQL 17+ logical slot creation with failover capability
SELECT pg_create_logical_replication_slot(
    slot_name => 'cdc_payment_events',
    plugin => 'pgoutput',
    failover => true
);

-- On standby: verify slot synchronization
SELECT slot_name, synced, failover FROM pg_replication_slots;
```

---

## 4. Production Code Implementations

### 4.1 Go (`jackc/pgx/v5`): Slot Health Sentinel & Orphan Reaper

```go
package replication

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// SlotHealthReport captures point-in-time metrics for a replication slot.
type SlotHealthReport struct {
	SlotName       string
	Plugin         string
	SlotType       string
	Active         bool
	ActivePID      *int32
	WalStatus      string
	WalLagBytes    int64
	CatalogXminAge int64
}

// ReplicationSlotGuard enforces storage protection and orphan reaping invariants.
type ReplicationSlotGuard struct {
	pool            *pgxpool.Pool
	maxLagBytes     int64
	maxInactiveDur  time.Duration
	maxCatXminAge   int64
}

// NewReplicationSlotGuard instantiates a production replication slot sentinel.
func NewReplicationSlotGuard(pool *pgxpool.Pool, maxLagBytes int64, maxCatXminAge int64) (*ReplicationSlotGuard, error) {
	if pool == nil {
		return nil, errors.New("db pool must not be nil")
	}
	if maxLagBytes <= 0 {
		maxLagBytes = 10 * 1024 * 1024 * 1024 // 10GB default safety boundary
	}
	if maxCatXminAge <= 0 {
		maxCatXminAge = 500_000 // 500k transaction age limit
	}
	return &ReplicationSlotGuard{
		pool:           pool,
		maxLagBytes:    maxLagBytes,
		maxCatXminAge:  maxCatXminAge,
		maxInactiveDur: 15 * time.Minute,
	}, nil
}

// AuditSlots inspects all replication slots and returns violations.
func (g *ReplicationSlotGuard) AuditSlots(ctx context.Context) ([]SlotHealthReport, []string, error) {
	query := `
		SELECT 
			slot_name,
			COALESCE(plugin, 'physical') AS plugin,
			slot_type,
			active,
			active_pid,
			COALESCE(wal_status, 'normal') AS wal_status,
			COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0)::bigint AS wal_lag_bytes,
			COALESCE(age(catalog_xmin), 0)::bigint AS catalog_xmin_age
		FROM pg_replication_slots;
	`
	rows, err := g.pool.Query(ctx, query)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to audit pg_replication_slots: %w", err)
	}
	defer rows.Close()

	var reports []SlotHealthReport
	var violations []string

	for rows.Next() {
		var r SlotHealthReport
		if err := rows.Scan(
			&r.SlotName,
			&r.Plugin,
			&r.SlotType,
			&r.Active,
			&r.ActivePID,
			&r.WalStatus,
			&r.WalLagBytes,
			&r.CatalogXminAge,
		); err != nil {
			return nil, nil, fmt.Errorf("failed to scan slot report: %w", err)
		}

		reports = append(reports, r)

		// Assertion 1: WAL status must not be lost or unreserved
		if r.WalStatus == "lost" || r.WalStatus == "unreserved" {
			violations = append(violations, fmt.Sprintf(
				"CRITICAL: Slot %q has wal_status=%q. WAL has been dropped or is unreserved!",
				r.SlotName, r.WalStatus,
			))
		}

		// Assertion 2: WAL lag boundary
		if r.WalLagBytes > g.maxLagBytes {
			violations = append(violations, fmt.Sprintf(
				"STORAGE_WARNING: Slot %q lag (%d MB) exceeds limit (%d MB)",
				r.SlotName, r.WalLagBytes/(1024*1024), g.maxLagBytes/(1024*1024),
			))
		}

		// Assertion 3: Logical slot catalog_xmin age boundary
		if r.SlotType == "logical" && r.CatalogXminAge > g.maxCatXminAge {
			violations = append(violations, fmt.Sprintf(
				"CATALOG_HORIZON_WARNING: Slot %q pins catalog_xmin to age %d (limit: %d)",
				r.SlotName, r.CatalogXminAge, g.maxCatXminAge,
			))
		}
	}

	return reports, violations, rows.Err()
}

// SafelyDropSlot removes an orphaned or invalid replication slot under strict lock timeout.
func (g *ReplicationSlotGuard) SafelyDropSlot(ctx context.Context, slotName string) error {
	tx, err := g.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("failed to initiate tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// Set local lock timeout to prevent blocking concurrent transactions
	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2000ms'"); err != nil {
		return fmt.Errorf("failed to set lock timeout: %w", err)
	}

	var exists bool
	err = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_replication_slots WHERE slot_name = $1 AND NOT active)", slotName).Scan(&exists)
	if err != nil {
		return fmt.Errorf("failed to verify slot state: %w", err)
	}
	if !exists {
		return fmt.Errorf("slot %q does not exist or is currently active", slotName)
	}

	if _, err := tx.Exec(ctx, "SELECT pg_drop_replication_slot($1)", slotName); err != nil {
		return fmt.Errorf("failed to drop replication slot %q: %w", slotName, err)
	}

	return tx.Commit(ctx)
}
```

---

### 4.2 TypeScript (`Kysely` / Node.js): Inactive Slot Sentinel & Auto-Reaper

```typescript
import { Kysely, sql } from 'kysely';

export interface ReplicationSlotRow {
  slot_name: string;
  plugin: string | null;
  slot_type: string;
  active: boolean;
  active_pid: number | null;
  wal_status: string;
  wal_lag_bytes: string;
  catalog_xmin_age: string;
}

export interface SlotAuditResult {
  slots: Array<{
    slotName: string;
    isActive: boolean;
    walStatus: string;
    lagBytes: bigint;
    lagMb: number;
    catalogXminAge: number;
  }>;
  criticalViolations: string[];
}

export class ReplicationSlotSentinel {
  constructor(
    private readonly db: Kysely<unknown>,
    private readonly maxLagBytes: bigint = BigInt(20 * 1024 * 1024 * 1024), // 20GB
    private readonly maxCatalogAge: number = 500_000
  ) {}

  public async auditSlots(): Promise<SlotAuditResult> {
    const rawSlots = await sql<ReplicationSlotRow>`
      SELECT 
        slot_name,
        plugin,
        slot_type,
        active,
        active_pid,
        COALESCE(wal_status, 'normal') AS wal_status,
        COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0)::text AS wal_lag_bytes,
        COALESCE(age(catalog_xmin), 0)::text AS catalog_xmin_age
      FROM pg_replication_slots
    `.execute(this.db);

    const criticalViolations: string[] = [];
    const slots = rawSlots.rows.map((row) => {
      const lagBytes = BigInt(row.wal_lag_bytes);
      const lagMb = Number(lagBytes / BigInt(1024 * 1024));
      const catAge = parseInt(row.catalog_xmin_age, 10);

      if (!row.active && lagBytes > this.maxLagBytes) {
        criticalViolations.push(
          `INACTIVE_SLOT_PINNING_WAL: Slot '${row.slot_name}' is inactive and retains ${lagMb} MB of WAL!`
        );
      }
      if (row.wal_status === 'lost') {
        criticalViolations.push(
          `SLOT_LOST_DATA: Slot '${row.slot_name}' has exceeded max_slot_wal_keep_size and is marked 'lost'.`
        );
      }
      if (row.slot_type === 'logical' && catAge > this.maxCatalogAge) {
        criticalViolations.push(
          `CATALOG_XMIN_FREEZE: Logical slot '${row.slot_name}' pins catalog_xmin to age ${catAge}.`
        );
      }

      return {
        slotName: row.slot_name,
        isActive: row.active,
        walStatus: row.wal_status,
        lagBytes,
        lagMb,
        catalogXminAge: catAge,
      };
    });

    return { slots, criticalViolations };
  }

  public async reapInactiveSlot(slotName: string): Promise<boolean> {
    return await this.db.transaction().execute(async (tx) => {
      await sql`SET LOCAL lock_timeout = '2000ms'`.execute(tx);
      const check = await sql<{ is_inactive: boolean }>`
        SELECT (NOT active) AS is_inactive 
        FROM pg_replication_slots 
        WHERE slot_name = ${slotName}
      `.execute(tx);

      if (!check.rows[0]?.is_inactive) {
        return false;
      }

      await sql`SELECT pg_drop_replication_slot(${slotName})`.execute(tx);
      return true;
    });
  }
}
```

---

### 4.3 Python (`asyncpg`): Replication Slot Horizon Guard

```python
import asyncpg
import logging
from typing import List, Dict, Any, Optional

logger = logging.getLogger("replication_guard")

class AsyncReplicationSlotGuard:
    def __init__(
        self,
        pool: asyncpg.Pool,
        max_lag_bytes: int = 15 * 1024 * 1024 * 1024, # 15GB
        max_catalog_age: int = 500_000,
    ):
        self.pool = pool
        self.max_lag_bytes = max_lag_bytes
        self.max_catalog_age = max_catalog_age

    async def audit_slots(self) -> Dict[str, Any]:
        query = """
            SELECT 
                slot_name,
                COALESCE(plugin, 'physical') AS plugin,
                slot_type,
                active,
                active_pid,
                COALESCE(wal_status, 'normal') AS wal_status,
                COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0)::bigint AS wal_lag_bytes,
                COALESCE(age(catalog_xmin), 0)::bigint AS catalog_xmin_age
            FROM pg_replication_slots;
        """
        async with self.pool.acquire() as conn:
            records = await conn.fetch(query)

        violations: List[str] = []
        slots: List[Dict[str, Any]] = []

        for r in records:
            slot_data = dict(r)
            slots.append(slot_data)
            lag_mb = slot_data["wal_lag_bytes"] / (1024 * 1024)

            if not slot_data["active"] and slot_data["wal_lag_bytes"] > self.max_lag_bytes:
                violations.append(
                    f"CRITICAL: Inactive slot '{slot_data['slot_name']}' is holding {lag_mb:.2f} MB of WAL!"
                )
            if slot_data["wal_status"] in ("lost", "unreserved"):
                violations.append(
                    f"DATA_LOSS: Slot '{slot_data['slot_name']}' has wal_status='{slot_data['wal_status']}'."
                )
            if slot_data["slot_type"] == "logical" and slot_data["catalog_xmin_age"] > self.max_catalog_age:
                violations.append(
                    f"CATALOG_BLOAT: Slot '{slot_data['slot_name']}' pins catalog_xmin to age {slot_data['catalog_xmin_age']}."
                )

        return {"slots": slots, "violations": violations}

    async def drop_inactive_slot(self, slot_name: str) -> bool:
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                await conn.execute("SET LOCAL lock_timeout = '2000ms'")
                is_inactive = await conn.fetchval(
                    "SELECT (NOT active) FROM pg_replication_slots WHERE slot_name = $1",
                    slot_name,
                )
                if not is_inactive:
                    logger.warning(f"Slot '{slot_name}' is currently active or missing; skipping drop.")
                    return False
                await conn.execute("SELECT pg_drop_replication_slot($1)", slot_name)
                logger.info(f"Successfully dropped inactive slot '{slot_name}'.")
                return True
```

---

### 4.4 Rust (`sqlx`): Zero-Allocation Slot Sentinel

```rust
use sqlx::{PgPool, Row};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct SlotMetric {
    pub slot_name: String,
    pub is_active: bool,
    pub wal_status: String,
    pub lag_bytes: i64,
    pub catalog_xmin_age: i64,
}

pub struct ReplicationSlotSentinel {
    pool: PgPool,
    max_lag_bytes: i64,
    max_catalog_age: i64,
}

impl ReplicationSlotSentinel {
    pub fn new(pool: PgPool, max_lag_bytes: i64, max_catalog_age: i64) -> Self {
        Self {
            pool,
            max_lag_bytes,
            max_catalog_age,
        }
    }

    pub async fn check_and_audit(&self) -> Result<(Vec<SlotMetric>, Vec<String>), sqlx::Error> {
        let query = r#"
            SELECT 
                slot_name,
                active,
                COALESCE(wal_status, 'normal') AS wal_status,
                COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0)::bigint AS lag_bytes,
                COALESCE(age(catalog_xmin), 0)::bigint AS cat_age
            FROM pg_replication_slots
        "#;

        let rows = sqlx::query(query).fetch_all(&self.pool).await?;
        let mut metrics = Vec::with_capacity(rows.len());
        let mut violations = Vec::new();

        for row in rows {
            let metric = SlotMetric {
                slot_name: row.try_get("slot_name")?,
                is_active: row.try_get("active")?,
                wal_status: row.try_get("wal_status")?,
                lag_bytes: row.try_get("lag_bytes")?,
                catalog_xmin_age: row.try_get("cat_age")?,
            };

            if !metric.is_active && metric.lag_bytes > self.max_lag_bytes {
                violations.push(format!(
                    "ALARM: Inactive slot '{}' is pinning {} bytes of WAL",
                    metric.slot_name, metric.lag_bytes
                ));
            }

            if metric.wal_status == "lost" {
                violations.push(format!(
                    "CRITICAL: Slot '{}' status is 'lost'", metric.slot_name
                ));
            }

            metrics.push(metric);
        }

        Ok((metrics, violations))
    }
}
```

---

## 5. Autonomous TypeScript Guard Engine

```typescript
export interface SlotInspection {
  slotName: string;
  plugin: string;
  slotType: 'physical' | 'logical';
  active: boolean;
  activePid: number | null;
  walStatus: 'normal' | 'reserved' | 'unreserved' | 'lost';
  restartLsn: string;
  confirmedFlushLsn: string | null;
  walLagBytes: number;
  catalogXminAge: number;
}

export interface SlotRemediationPlan {
  action: 'NOOP' | 'ALERT' | 'DROP_INACTIVE' | 'RECREATE_LOST';
  slotName: string;
  reason: string;
  sqlCommand: string;
}

export class AgenticReplicationSlotGuardEngine {
  private readonly maxLagBytesThreshold: number;
  private readonly maxCatalogAgeThreshold: number;

  constructor(
    maxLagBytesThreshold = 20 * 1024 * 1024 * 1024, // 20GB
    maxCatalogAgeThreshold = 500_000
  ) {
    this.maxLagBytesThreshold = maxLagBytesThreshold;
    this.maxCatalogAgeThreshold = maxCatalogAgeThreshold;
  }

  /**
   * Evaluates slot metrics and generates automated remediation plans.
   */
  public evaluate(slots: SlotInspection[]): SlotRemediationPlan[] {
    const plans: SlotRemediationPlan[] = [];

    for (const slot of slots) {
      // Rule 1: Slot has already lost WAL; it can never catch up
      if (slot.walStatus === 'lost') {
        plans.push({
          action: 'RECREATE_LOST',
          slotName: slot.slotName,
          reason: `Slot '${slot.slotName}' exceeded max_slot_wal_keep_size. Status is 'lost'. Consumer must re-clone state.`,
          sqlCommand: `SELECT pg_drop_replication_slot('${slot.slotName}');`,
        });
        continue;
      }

      // Rule 2: Inactive slot exceeding WAL safety threshold
      if (!slot.active && slot.walLagBytes > this.maxLagBytesThreshold) {
        plans.push({
          action: 'DROP_INACTIVE',
          slotName: slot.slotName,
          reason: `Slot '${slot.slotName}' is inactive and retains ${(slot.walLagBytes / (1024 * 1024 * 1024)).toFixed(2)} GB of WAL, threatening disk capacity.`,
          sqlCommand: `SELECT pg_drop_replication_slot('${slot.slotName}');`,
        });
        continue;
      }

      // Rule 3: Logical slot holding system catalog vacuum horizon
      if (slot.slotType === 'logical' && slot.catalogXminAge > this.maxCatalogAgeThreshold) {
        plans.push({
          action: 'ALERT',
          slotName: slot.slotName,
          reason: `Logical slot '${slot.slotName}' has catalog_xmin age ${slot.catalogXminAge}, inducing system catalog bloat.`,
          sqlCommand: `-- Inspect consumer process or restart subscriber to advance catalog_xmin`,
        });
        continue;
      }

      // Rule 4: Normal operation
      plans.push({
        action: 'NOOP',
        slotName: slot.slotName,
        reason: 'Slot is healthy and within all operational thresholds.',
        sqlCommand: '-- No action required',
      });
    }

    return plans;
  }
}
```

---

## 6. The 6-State Replication Slot Lifecycle Finite-State Machine (FSM)

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             REPLICATION SLOT 6-STATE LIFECYCLE FINITE-STATE MACHINE                    │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│     [ S0: CREATED ] ──(Consumer Connects)──► [ S1: ACTIVE_STREAMING ]                  │
│            │                                         │                                 │
│      (Never connected)                         (Network Lag /                          │
│            │                                  High Write Rate)                         │
│            ▼                                         ▼                                 │
│     [ S3: INACTIVE_ORPHAN ] ◄──(Disconnect)── [ S2: LAGGING_WARNING ]                  │
│            │                                         │                                 │
│       (Exceeds TTL /                         (Lag > max_slot_                          │
│        Disk Danger)                           wal_keep_size)                           │
│            │                                         │                                 │
│            ▼                                         ▼                                 │
│     [ S5: SAFELY_PURGED ] ◄──(Drop Slot)───── [ S4: LOST_INVALIDATED ]                 │
│                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

| State | Definition | Trigger Conditions | Recovery / Guard Action |
| :--- | :--- | :--- | :--- |
| **S0: CREATED** | Slot registered in catalog; no consumer yet attached. | `active = false`, `restart_lsn IS NULL` or initial LSN. | Start heartbeat timer; enforce 30-minute creation TTL. |
| **S1: ACTIVE_STREAMING** | Connected consumer continuously acknowledging WAL. | `active = true`, $\text{Lag} < 5\text{GB}$, `wal_status = 'normal'`. | Normal streaming; continue routine 60s telemetry sampling. |
| **S2: LAGGING_WARNING** | Active consumer falling behind primary WAL write rate. | `active = true`, $5\text{GB} \le \text{Lag} < \text{max\_slot\_size}$. | Emit P2 warning; alert downstream consumer team to scale I/O. |
| **S3: INACTIVE_ORPHAN** | Consumer crashed, disconnected, or orphaned by test run. | `active = false`, $\text{Inactivity} > 15\text{m}$, $\text{Lag} > 10\text{GB}$. | Trigger Automated Reaper; evaluate emergency slot drop. |
| **S4: LOST_INVALIDATED** | Slot exceeded `max_slot_wal_keep_size`; WAL unlinked. | `wal_status = 'lost'`. | Consumer stream broken permanently. Drop slot; re-seed subscriber. |
| **S5: SAFELY_PURGED** | Slot dropped via `pg_drop_replication_slot()`. | Slot unlinked from catalog under `lock_timeout`. | Storage reclaimed; WAL files recycled by next checkpoint. |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

To guarantee no PR or autonomous agent migration degrades database durability or risks storage panics, enforce these 6 automated gates:

| Gate | Check Name | Command / Inspection Query | Acceptance Criteria |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **Safety Ceiling Guard** | `SHOW max_slot_wal_keep_size;` | Value MUST NOT be `-1`; MUST be between `20GB` and `100GB`. |
| **Gate 2** | **Zero Lost Slots** | `SELECT count(*) FROM pg_replication_slots WHERE wal_status = 'lost';` | `count == 0`. Zero slots in invalidated 'lost' state. |
| **Gate 3** | **Zero Orphaned Inactive Slots** | `SELECT count(*) FROM pg_replication_slots WHERE NOT active AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 10737418240;` | `count == 0`. Zero inactive slots holding $> 10\text{GB}$ of WAL. |
| **Gate 4** | **Catalog xmin Vacuum Horizon** | `SELECT COALESCE(max(age(catalog_xmin)), 0) FROM pg_replication_slots WHERE slot_type = 'logical';` | Horizon age $\le 500,000$ transactions. |
| **Gate 5** | **Ephemeral Slot Leak Defense** | `SELECT count(*) FROM pg_replication_slots WHERE slot_name ~ '^(test\|temp\|tmp\|agent)_';` | `count == 0` in staging and production CI environments. |
| **Gate 6** | **PG17 Failover Slot Sync** | `SELECT count(*) FROM pg_replication_slots WHERE slot_type = 'logical' AND NOT failover;` | `count == 0` on PostgreSQL 17+ HA clusters. |
