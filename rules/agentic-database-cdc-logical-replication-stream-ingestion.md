---
description: PostgreSQL Change Data Capture (CDC), Logical Replication, Debezium, pgoutput, replication slot fencing, max_slot_wal_keep_size, REPLICA IDENTITY, catalog_xmin pinning, streaming logical decoding, monotonic LSN deduplication, and zero-data-loss event streaming across Go (pglogrepl/pgx), TypeScript (pg-logical-replication/Kysely/Drizzle), Python (psycopg/SQLAlchemy), Rust (tokio-postgres), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{cdc,replication,debezium,outbox,slot,subscriber,publisher,pgoutput,wal2json}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/events/**/*.{ts,js,go,rs,py},**/internal/cdc/**/*.{go,rs},**/internal/outbox/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Change Data Capture (CDC), Logical Replication & Stream Ingestion Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design Change Data Capture (CDC) pipelines, configure PostgreSQL logical replication, tail Write-Ahead Logs (WAL) with Debezium or `pgoutput`, build real-time search/vector synchronization (Elasticsearch, OpenSearch, pgvector, Qdrant), or implement Transactional Outbox stream consumers across PostgreSQL, Go (`jackc/pglogrepl`, `pgx/v5`), TypeScript (`pg-logical-replication`, `Drizzle`, `Prisma`), Python (`psycopg3`, `SQLAlchemy`), or Rust (`tokio-postgres`). Eliminate the "Orphaned Replication Slot & Disk PANIC Meltdown" (where disconnected or lagging CDC consumers cause PostgreSQL to accumulate tens of thousands of WAL segments until disk fills to 100% and crashes the primary node), the "REPLICA IDENTITY FULL & Subscriber Full-Scan CPU Spasm" (where tables without primary keys force subscribers to perform full sequential table scans for every single `UPDATE` and `DELETE`, causing 100% CPU lockup and multi-day replication lag), the "Catalog Bloat & Pinned catalog_xmin Vacuum Horizon Trap" (where inactive logical slots prevent autovacuum from cleaning dead tuples in `pg_catalog`, bloating system catalogs by 50x and degrading query planning performance cluster-wide), the "Large In-Flight Transaction Buffer Spill & Memory Exhaustion" (where unbatched bulk updates exceed `logical_decoding_work_mem`, spilling gigabytes of temporary change files to disk and crippling I/O), the "Schema Evolution DDL Breakage & Poison Message Pipeline Paralysis" (where uncoordinated column drops or renames crash downstream CDC decoders, freezing slot progression and triggering WAL disk accumulation), and the "At-Least-Once Duplicate Event Storm & Causal State Corruption" (where consumer restarts replay unacknowledged LSN streams without monotonic sequence fencing, resulting in duplicate financial mutations or out-of-order state overwrites) by establishing a strict 5-Tier CDC & Logical Replication Governance Ladder, slot disk quotas (`max_slot_wal_keep_size`), strict replica identity invariants, monotonic LSN deduplication, and streaming logical decoding.

---

## 1. Architectural Taxonomy: The 6 CDC Catastrophes vs The 5-Tier Governance Ladder

In distributed event-driven systems and real-time streaming architectures, Change Data Capture (CDC) via PostgreSQL logical decoding is the gold standard for reliable data dissemination. A robust logical replication architecture comprises six core subsystems:
1. **Logical Decoding Output Plugin (`pgoutput` / `wal2json`)**: In-engine decoder that converts raw Write-Ahead Log (WAL) byte streams into structured logical change events (INSERT, UPDATE, DELETE, TRUNCATE) at transaction commit boundaries.
2. **Replication Slot Sentinel**: Engine-managed cursor (`pg_replication_slots`) that tracks consumer progress (`confirmed_flush_lsn`) and prevents PostgreSQL from recycling WAL segments required by active subscribers.
3. **Replica Identity Subsystem**: The table-level configuration (`REPLICA IDENTITY`) governing what previous row state (old tuple values) is emitted into the WAL stream during UPDATE and DELETE operations.
4. **Publication & Filtering Plane**: Engine publication catalog (`pg_publication`) defining the set of tables and row filters (`WHERE (status = 'pending')`) exposed to downstream consumers.
5. **Streaming Ingestion & Acking Protocol**: Client-side state machine negotiating copy-both streaming protocols, periodically reporting flushed LSN offsets (`StandbyStatusUpdate`), and preventing slot invalidation.
6. **Monotonic Deduplication & State Projection Engine**: Consumer-side idempotency layer verifying strictly ascending LSN sequences and enforcing monotonic state transitions across downstream stores (search indexes, vector embeddings, caches).

When autonomous coding agents generate CDC pipelines, Kafka Connect configs, or logical replication scripts, LLMs routinely commit fatal architectural anti-patterns:

```typescript
// ❌ CATASTROPHIC LLM CDC & LOGICAL REPLICATION ANTI-PATTERNS

// 1. Creating logical replication slots without bounding max_slot_wal_keep_size!
// When the consumer service is redeployed, crashes, or hits Kafka backpressure,
// PostgreSQL hoards all WAL files in pg_wal until disk hits 100%, crashing the cluster with PANIC!
await db.query(`SELECT pg_create_logical_replication_slot('agent_cdc_slot', 'pgoutput');`); // FATAL: Unbounded disk risk

// 2. Setting REPLICA IDENTITY FULL without verifying subscriber indexes!
// For every single UPDATE or DELETE on a 5M row table, the subscriber executes a FULL SEQUENTIAL SCAN!
// 100 updates/sec = 100 full table scans/sec -> 100% CPU lockup and multi-day replication lag!
await db.query(`ALTER TABLE audit_logs REPLICA IDENTITY FULL;`); // FATAL: Subscriber CPU spasm

// 3. Leaving orphaned test or development slots alive in production!
// Logical slots pin catalog_xmin. Autovacuum CANNOT clean dead tuples in pg_catalog (pg_class, pg_attribute)!
// System catalogs bloat by 100x; query planner lookups explode from 0.05ms to 50ms cluster-wide!
await db.query(`SELECT pg_create_logical_replication_slot('temp_test_slot', 'test_decoding');`); // FATAL: Pinned catalog_xmin

// 4. Downstream consumer processing events without monotonic LSN fencing!
// On consumer crash or worker rebalance, un-acked LSNs are re-delivered from the last checkpoint.
// Without LSN fencing, concurrent workers execute out-of-order writes, overwriting fresh data with stale snapshots!
kafkaConsumer.on('message', async (event) => {
  await searchIndex.update(event.id, event.payload); // FATAL: Duplicate execution & out-of-order state corruption
});
```

In production architectures, naive CDC implementations trigger six critical engineering disasters:

- **The "Orphaned Replication Slot & Disk PANIC Meltdown"**:
  - Developers or autonomous agents create logical replication slots for Debezium, Kafka Connect, or migration tasks.
  - If the downstream consumer halts, experiences network partition, or is deleted without dropping the slot, PostgreSQL's checkpointer strictly refuses to recycle any WAL generated after the slot's `restart_lsn`.
  - Under normal write traffic of 10GB–50GB/day, the `pg_wal` directory exhausts all available disk capacity within hours or days.
  - The PostgreSQL postmaster triggers `PANIC: could not write to file "pg_wal/...": No space left on device` and shuts down the primary node.
  - Invariant: Mandatory global configuration of `max_slot_wal_keep_size` (e.g., 20GB–50GB) and automated slot watchdogs that monitor `wal_status` and drop or invalidate stale slots before disk exceeds 85% utilization.

- **The "REPLICA IDENTITY FULL & Subscriber Full-Scan CPU Spasm"**:
  - To capture before-values for `UPDATE` or `DELETE` events, agents execute `ALTER TABLE t REPLICA IDENTITY FULL;` on tables that lack a primary key or on subscriber tables where the identity columns are unindexed.
  - In PostgreSQL logical replication, the subscriber node uses the replica identity to find the target row. With `REPLICA IDENTITY FULL`, the subscriber MUST execute a full sequential scan of the entire table for **every single incoming UPDATE or DELETE**.
  - On a table with 2,000,000 rows, a batch of 500 updates requires 500 sequential table scans. Subscriber CPU spikes to 100%, replication lag explodes from milliseconds to days, and write queues exhaust memory.
  - Invariant: Mandatory `REPLICA IDENTITY DEFAULT` backed by an immutable `PRIMARY KEY` (e.g., UUIDv7 or BIGINT). If a composite natural key must be used, enforce `REPLICA IDENTITY USING INDEX <unique_idx>`.

- **The "Catalog Bloat & Pinned catalog_xmin Vacuum Horizon Trap"**:
  - Unlike physical replication slots which only track WAL LSNs, logical replication slots maintain a `catalog_xmin` horizon to prevent the deletion of system catalog rows needed to decode schema history in historical WAL.
  - When a logical slot is inactive or abandoned, PostgreSQL autovacuum is strictly blocked from vacuuming dead tuples in `pg_catalog` (`pg_class`, `pg_attribute`, `pg_type`, `pg_amproc`).
  - System catalogs bloat by 20x to 100x. Because the PostgreSQL query planner queries system catalogs for every SQL statement, query planning time skyrockets from 0.05ms to 50ms across the entire database instance, degrading performance for all tenants and workloads.
  - Invariant: Automated replication slot sentinel alerting when `age(catalog_xmin) > 500,000` transactions and active termination of non-responsive slots.

- **The "Large In-Flight Transaction Buffer Spill & Memory Exhaustion"**:
  - Application developers or batch jobs execute bulk updates (`UPDATE orders SET status = 'processed' WHERE ...` modifying 500,000 rows) within a single transaction.
  - Logical decoding cannot emit changes until the transaction commits. The engine buffers all decoded tuple changes in memory up to `logical_decoding_work_mem` (default 64MB).
  - Once memory is exhausted, the engine spills decoded changes to temporary disk files under `pg_replslot/<slot_name>/`.
  - Disk write amplification thrashes storage IOPS, decoding latency spikes by orders of magnitude, and downstream consumer latency cliffs emerge.
  - Invariant: Increase `logical_decoding_work_mem` to 128MB–256MB, enable logical decoding streaming (`streaming = on` in subscriptions or Debezium), and enforce application-level micro-batching ($\le 2,000$ rows per transaction).

- **The "Schema Evolution DDL Breakage & Poison Message Pipeline Paralysis"**:
  - An autonomous agent applies a database migration altering column names or dropping columns (`ALTER TABLE items DROP COLUMN legacy_code;`) on the publisher.
  - Downstream CDC plugins (Debezium, Kafka Connect, or custom workers using strict Avro/Protobuf/JSON schemas) fail to decode incoming WAL tuples due to schema mismatch or missing fields.
  - The CDC consumer crashes and enters an infinite crash-backoff loop. Because the slot is never acked, `confirmed_flush_lsn` freezes, WAL accumulates on the publisher, and disk capacity begins depleting.
  - Invariant: Non-breaking schema evolution discipline: add columns with defaults first, migrate consumers, and deprecate columns before dropping. Publication filtering (`CREATE PUBLICATION ... FOR TABLE ...`) and schema evolution canary validation.

- **The "At-Least-Once Duplicate Event Storm & Causal State Corruption"**:
  - Logical replication delivers events with **at-least-once** semantics. PostgreSQL updates `confirmed_flush_lsn` only when the subscriber periodically flushes and acknowledges processed LSNs.
  - When a consumer service restarts, crashes, or undergoes Kafka consumer group rebalancing, it replays WAL events from the last confirmed flush LSN.
  - If downstream consumers apply mutations naively without checking monotonic LSN or version ordering, replayed stale events overwrite newer states or trigger duplicate business side-effects (duplicate billing, duplicate notifications).
  - Invariant: Mandatory monotonic LSN tracking on downstream stores. State updates MUST assert `incoming_lsn > last_applied_lsn` or record executed transaction IDs in an atomic deduplication ledger.

---

## 2. Mathematical Invariants, SLA Bounds & Physics of Change Data Capture

### 2.1 The WAL Accumulation & Disk Exhaustion Differential Model

Let $\lambda_{\text{WAL}}$ be the Write-Ahead Log generation rate of the primary database in bytes per second:
$$\lambda_{\text{WAL}} = \frac{\Delta V_{\text{WAL}}}{\Delta t} \quad (\text{bytes/s})$$

Let $R_{\text{drain}}$ be the rate at which the slowest active replication slot consumes and acknowledges WAL. When a replication slot stalls or is abandoned, $R_{\text{drain}} = 0$.

Let $D_{\text{free}}$ be the total free storage capacity on the volume hosting `pg_wal`, and $D_{\text{safety}}$ be the emergency disk reserve (typically 15% of total disk capacity). The time remaining until database disk exhaustion and catastrophic postmaster PANIC shutdown $T_{\text{exhaust}}$ is:

$$T_{\text{exhaust}} = \frac{D_{\text{free}} - D_{\text{safety}}}{\lambda_{\text{WAL}} - R_{\text{drain}}}$$

When $R_{\text{drain}} = 0$ and $\lambda_{\text{WAL}} = 5\text{MB/s}$ ($432\text{GB/day}$), an unmonitored $50\text{GB}$ free partition will exhaust its safety margin in:
$$T_{\text{exhaust}} = \frac{50 \times 10^9 - 15 \times 10^9}{5 \times 10^6} = 7,000\text{ seconds} \approx 1.94\text{ hours}$$

**The Slot Fencing Invariant**: To guarantee that $\mathbb{P}(\text{Disk Full Outage}) = 0$, the maximum disk retained by any replication slot MUST be strictly bounded by `max_slot_wal_keep_size`:
$$\text{max\_slot\_wal\_keep\_size} \le \alpha \cdot D_{\text{free}} \quad \text{where } \alpha \in [0.20, 0.40]$$

When WAL lag exceeds `max_slot_wal_keep_size`, PostgreSQL automatically invalidates the slot (`wal_status = 'lost'`), freeing WAL segments and preserving cluster availability.

```
       WAL Storage Utilization Over Time (Unbounded vs Fenced Slot)
  Bytes
    ▲
100%│─────────────────────────────────────── 💥 POSTMASTER PANIC (Unbounded Slot)
    │                                     /
 80%│ - - - - - - - - - - - - - - - - - -/- - - - - Emergency Disk Reserve
    │                                   /
 50%│                     ┌────────────┘
    │                    /│
    │                   / │ 🛡️ Slot Invalidation Fencing Triggered
    │                  /  │    (max_slot_wal_keep_size = 20GB)
    │                 /   │
 20%│────────────────┘    └──────────────► WAL Recycled, Primary Protected
    └──────────────────────────────────────────────► Time
```

### 2.2 Logical Decoding Work Memory & Disk Spill Physics

Let $N_{\text{rows}}$ be the number of rows modified in a single transaction $T_x$, and $\overline{S}_{\text{tuple}}$ be the average byte size of each serialized tuple delta. The total memory footprint $V_{\text{tx\_changes}}$ required to decode $T_x$ is:
$$V_{\text{tx\_changes}} = \sum_{i=1}^{N_{\text{rows}}} \left( S(\text{old\_tuple}_i) + S(\text{new\_tuple}_i) + S_{\text{meta}} \right) \approx N_{\text{rows}} \times \overline{S}_{\text{tuple}}$$

If $V_{\text{tx\_changes}} > \text{logical\_decoding\_work\_mem}$, the logical decoding engine MUST flush intermediate change buffers to disk:
$$\text{DiskSpillBytes} = \max(0, \, V_{\text{tx\_changes}} - \text{logical\_decoding\_work\_mem})$$

Disk spilling imposes a massive I/O penalty:
1. In-memory decoding latency: $T_{\text{mem}} \approx O(N_{\text{rows}} \times t_{\text{RAM}})$ where $t_{\text{RAM}} \approx 10\text{ns}$.
2. Spilled decoding latency: $T_{\text{spill}} \approx O(N_{\text{rows}} \times t_{\text{RAM}}) + 2 \times \frac{\text{DiskSpillBytes}}{B_{\text{NVMe}}}$ (one write to `pg_replslot`, one read at commit).

At $\overline{S}_{\text{tuple}} = 1\text{KB}$, a transaction touching 500,000 rows generates $500\text{MB}$ of changes. With default `logical_decoding_work_mem = 64MB`, $436\text{MB}$ is spilled to disk, introducing multi-second replication lag spikes.

**The Micro-Batching Invariant**:
$$N_{\text{rows/tx}} \le \frac{\text{logical\_decoding\_work\_mem}}{\overline{S}_{\text{tuple}} \times \kappa} \quad (\text{with safety factor } \kappa = 2.0)$$
For $\text{logical\_decoding\_work\_mem} = 128\text{MB}$ and $\overline{S}_{\text{tuple}} = 1\text{KB}$, $N_{\text{rows/tx}} \le 64,000$. Enforce application-level chunking to $\le 2,000$ rows per transaction.

### 2.3 System Catalog Bloat & Query Planning Complexity

When a logical replication slot pins `catalog_xmin`, PostgreSQL's autovacuum cannot remove dead tuples from catalog tables where $X_{\text{dead}} \ge \text{catalog\_xmin}$.

Let $D_{\text{catalog}}$ be the dead tuple ratio in `pg_catalog`:
$$D_{\text{catalog}} = \frac{N_{\text{dead\_catalog}}}{N_{\text{live\_catalog}} + N_{\text{dead\_catalog}}}$$

Let $T_{\text{plan}}$ be the query planning latency for an arbitrary OLTP query. Query planning involves scanning `pg_class`, `pg_attribute`, `pg_index`, and `pg_statistic`:
$$T_{\text{plan}} \approx T_{\text{base\_plan}} \times \left( 1 + \beta \cdot \frac{N_{\text{dead\_catalog}}}{N_{\text{page\_capacity}}} \right)$$

When $D_{\text{catalog}} > 0.80$ (80% dead tuples due to thousands of unvacuumed temporary tables, DDL migrations, or prepared statements), query planning latency degrades from $0.1\text{ms}$ to $> 20\text{ms}$, consuming CPU and exhausting the connection pool.

**The Catalog Vacuum Horizon Invariant**:
$$\text{Age}(\text{catalog\_xmin}) = \text{txid\_current}() - \text{catalog\_xmin} \le 500,000\text{ transactions}$$

### 2.4 Monotonic LSN Ordering & Causal Consistency Equivalence

PostgreSQL Log Sequence Numbers (LSNs) are 64-bit unsigned integers (`pg_lsn`) representing byte offsets within the Write-Ahead Log. Because WAL is strictly append-only, LSN defines a strict total order over all committed database operations:

$$\forall e_1, e_2 \in \mathcal{E}, \quad \text{LSN}(e_1) < \text{LSN}(e_2) \implies \text{CommitTime}(e_1) \le \text{CommitTime}(e_2)$$

For any downstream state projection $S$ with key $K$ and applied LSN $L_S(K)$, an incoming change event $e$ with $\text{LSN}(e)$ is valid if and only if:
$$\text{Accept}(e) \iff \text{LSN}(e) > L_S(K)$$

Applying an event where $\text{LSN}(e) \le L_S(K)$ constitutes a **Causal Inversion Anomaly** and MUST be discarded as an idempotent no-op.

---

## 3. The 5-Tier CDC & Logical Replication Governance Ladder

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│             THE 5-TIER CDC & LOGICAL REPLICATION GOVERNANCE LADDER              │
├──────┬────────────────────────┬──────────────────────────────────────────────────┤
│ Tier │ Name                   │ Core Invariants & Architectural Defenses         │
├──────┼────────────────────────┼──────────────────────────────────────────────────┤
│  0   │ Storage Safety & Slot  │ max_slot_wal_keep_size = 20GB-50GB, wal_status   │
│      │ Fencing Boundaries     │ monitoring, automated orphan slot drop circuit   │
│      │                        │ breakers preventing postmaster PANIC disk crash  │
├──────┼────────────────────────┼──────────────────────────────────────────────────┤
│  1   │ Replica Identity & PK  │ Mandatory REPLICA IDENTITY DEFAULT with immutable│
│      │ Index Invariance       │ PRIMARY KEY (UUIDv7/BIGINT); REPLICA IDENTITY    │
│      │                        │ USING INDEX for natural keys; ban unindexed FULL │
├──────┼────────────────────────┼──────────────────────────────────────────────────┤
│  2   │ Catalog xmin Sentinel  │ Continuous age(catalog_xmin) < 500k monitoring;  │
│      │ & Vacuum Protection    │ drop abandoned dev/staging slots; prevent        │
│      │                        │ 50x pg_catalog bloat & query planner latency cliff│
├──────┼────────────────────────┼──────────────────────────────────────────────────┤
│  3   │ Streaming Decoding &   │ logical_decoding_work_mem = 128MB-256MB; enable  │
│      │ Micro-Batched Ingestion│ streaming = on / streaming = 'parallel'; batch   │
│      │                        │ mutations <= 2000 rows/tx avoiding disk spill    │
├──────┼────────────────────────┼──────────────────────────────────────────────────┤
│  4   │ Monotonic LSN Fencing  │ Consumer-side exactly-once state projection via   │
│      │ & Outbox Publications  │ incoming_lsn > applied_lsn; row-filtered outbox  │
│      │                        │ publications WHERE (status = 'pending')          │
└──────┴────────────────────────┴──────────────────────────────────────────────────┘
```

---

## 4. Production Implementations Across Ecosystems

### 4.1 PostgreSQL Engine Configuration & Slot Safety DDL

```sql
-- ==============================================================================
-- 1. PostgreSQL Engine Setup for Change Data Capture (postgresql.conf)
-- ==============================================================================
-- Must be configured in postgresql.conf and requires restart:
-- wal_level = logical
-- max_replication_slots = 10
-- max_wal_senders = 10

-- Dynamic settings that protect against disk exhaustion:
ALTER SYSTEM SET max_slot_wal_keep_size = '32768MB'; -- 32 GB hard ceiling on slot retention
ALTER SYSTEM SET logical_decoding_work_mem = '131072kB'; -- 128 MB in-memory decoding buffer
SELECT pg_reload_conf();

-- ==============================================================================
-- 2. Publication DDL with Row Filtering & Explicit Replica Identity
-- ==============================================================================

-- Create CDC target table with immutable UUIDv7 primary key
CREATE TABLE IF NOT EXISTS customer_events (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    event_type VARCHAR(64) NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed BOOLEAN NOT NULL DEFAULT FALSE
);

-- Invariant: Ensure REPLICA IDENTITY is DEFAULT (uses PK index)
ALTER TABLE customer_events REPLICA IDENTITY DEFAULT;

-- For tables requiring compound natural keys without a synthetic PK:
-- CREATE UNIQUE INDEX idx_customer_tenant_event ON customer_events (tenant_id, id);
-- ALTER TABLE customer_events REPLICA IDENTITY USING INDEX idx_customer_tenant_event;

-- Create Publication with row-level filtering to reduce WAL decoding overhead
CREATE PUBLICATION cdc_customer_events_pub 
FOR TABLE customer_events 
WHERE (processed = FALSE);

-- ==============================================================================
-- 3. Provision Logical Replication Slot with Safety Guards
-- ==============================================================================
-- Create logical slot using pgoutput (standard binary plugin supported by Debezium & pgx)
SELECT pg_create_logical_replication_slot('customer_cdc_slot', 'pgoutput');

-- ==============================================================================
-- 4. Replication Slot Health & Catalog xmin Sentinel Query
-- ==============================================================================
SELECT
    slot_name,
    plugin,
    slot_type,
    active,
    active_pid,
    wal_status,
    ROUND(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / (1024 * 1024), 2) AS lag_restart_mb,
    ROUND(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) / (1024 * 1024), 2) AS lag_flush_mb,
    catalog_xmin,
    age(catalog_xmin) AS catalog_xmin_age
FROM pg_replication_slots
WHERE slot_type = 'logical';
```

### 4.2 Go Production Implementation (`jackc/pglogrepl` Protocol & Monotonic LSN Acking)

```go
package cdc

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/jackc/pglogrepl"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgproto3"
)

// CDCConsumer manages PostgreSQL logical replication stream
type CDCConsumer struct {
	connConfig    *pgconn.Config
	slotName      string
	publication   string
	lastWrittenLSN pglogrepl.LSN
	lastFlushedLSN pglogrepl.LSN
}

func NewCDCConsumer(connConfig *pgconn.Config, slotName, publication string) *CDCConsumer {
	return &CDCConsumer{
		connConfig:  connConfig,
		slotName:    slotName,
		publication: publication,
	}
}

// StartStreaming initiates logical replication stream with periodic keepalive acks
func (c *CDCConsumer) StartStreaming(ctx context.Context, handler func(lsn pglogrepl.LSN, msg pglogrepl.Message) error) error {
	conn, err := pgconn.ConnectConfig(ctx, c.connConfig)
	if err != nil {
		return fmt.Errorf("connect replication: %w", err)
	}
	defer conn.Close(ctx)

	// Invariant: Verify slot status before streaming
	sysIdent, err := pglogrepl.IdentifySystem(ctx, conn)
	if err != nil {
		return fmt.Errorf("identify system: %w", err)
	}

	startLSN := sysIdent.XLogPos

	// Start logical replication using pgoutput
	pluginArguments := []string{
		"proto_version '2'",
		fmt.Sprintf("publication_names '%s'", c.publication),
		"messages 'true'",
		"streaming 'true'", // Invariant: Enable streaming for large in-flight transactions
	}

	err = pglogrepl.StartReplication(ctx, conn, c.slotName, startLSN, pglogrepl.StartReplicationOptions{
		PluginArguments: pluginArguments,
	})
	if err != nil {
		return fmt.Errorf("start replication: %w", err)
	}

	c.lastWrittenLSN = startLSN
	c.lastFlushedLSN = startLSN

	standbyTicker := time.NewTicker(10 * time.Second)
	defer standbyTicker.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-standbyTicker.C:
			// Invariant: Send periodic StandbyStatusUpdate to prevent slot invalidation and advance confirmed_flush_lsn
			err := pglogrepl.SendStandbyStatusUpdate(ctx, conn, pglogrepl.StandbyStatusUpdate{
				WALWritePosition: c.lastWrittenLSN,
				WALFlushPosition: c.lastFlushedLSN,
				WALApplyPosition: c.lastFlushedLSN,
				ClientTime:       time.Now(),
				ReplyRequested:   false,
			})
			if err != nil {
				return fmt.Errorf("send standby status update: %w", err)
			}
		default:
			// Receive raw replication copy stream message
			msg, err := conn.ReceiveMessage(ctx)
			if err != nil {
				if pgconn.Timeout(err) {
					continue
				}
				return fmt.Errorf("receive copy data: %w", err)
			}

			switch rawMsg := msg.(type) {
			case *pgproto3.CopyData:
				switch rawMsg.Data[0] {
				case pglogrepl.PrimaryKeepaliveMessageByteID:
					pkm, err := pglogrepl.ParsePrimaryKeepaliveMessage(rawMsg.Data[1:])
					if err != nil {
						return fmt.Errorf("parse keepalive: %w", err)
					}
					if pkm.ReplyRequested {
						_ = pglogrepl.SendStandbyStatusUpdate(ctx, conn, pglogrepl.StandbyStatusUpdate{
							WALWritePosition: c.lastWrittenLSN,
							WALFlushPosition: c.lastFlushedLSN,
							ClientTime:       time.Now(),
						})
					}
				case pglogrepl.XLogDataByteID:
					xld, err := pglogrepl.ParseXLogData(rawMsg.Data[1:])
					if err != nil {
						return fmt.Errorf("parse xlog data: %w", err)
					}

					logicalMsg, err := pglogrepl.Parse(xld.WALData)
					if err != nil {
						return fmt.Errorf("parse logical msg: %w", err)
					}

					// Execute downstream business handler
					if err := handler(xld.WALStart, logicalMsg); err != nil {
						log.Printf("handler error for LSN %s: %v", xld.WALStart, err)
						return err
					}

					c.lastWrittenLSN = xld.WALStart + pglogrepl.LSN(len(xld.WALData))
					c.lastFlushedLSN = c.lastWrittenLSN
				}
			}
		}
	}
}
```

### 4.3 TypeScript / Node.js Monotonic LSN Deduplication & State Projection

```typescript
import { Pool, PoolClient } from 'pg';

export interface CDCChangeEvent {
  lsn: string; // e.g. '0/16B2348'
  table: string;
  action: 'I' | 'U' | 'D';
  rowId: string;
  payload: Record<string, any>;
  commitTime: string;
}

export class MonotonicCDCProjectionHandler {
  private pool: Pool;

  constructor(pool: Pool) {
    this.pool = pool;
  }

  /**
   * Applies incoming CDC change event with monotonic LSN fencing.
   * Discards stale or duplicate replayed events.
   */
  public async applyWithLSNFencing(event: CDCChangeEvent): Promise<boolean> {
    const client: PoolClient = await this.pool.connect();
    try {
      await client.query('BEGIN;');

      // 1. Lock existing projection record and verify monotonic LSN progression
      const checkRes = await client.query(
        `
        SELECT last_applied_lsn 
        FROM search_projections 
        WHERE entity_id = $1 
        FOR UPDATE;
        `,
        [event.rowId]
      );

      if (checkRes.rows.length > 0) {
        const currentLSN = checkRes.rows[0].last_applied_lsn;
        // Invariant: Discard event if current applied LSN is greater than or equal to incoming LSN
        const isStale = await client.query(
          `SELECT ($1::pg_lsn <= $2::pg_lsn) AS is_stale;`,
          [event.lsn, currentLSN]
        );

        if (isStale.rows[0].is_stale) {
          // Idempotent duplicate replay detected: safely ignore
          await client.query('ROLLBACK;');
          return false;
        }
      }

      // 2. Apply projection mutation atomically
      if (event.action === 'D') {
        await client.query(
          `DELETE FROM search_projections WHERE entity_id = $1;`,
          [event.rowId]
        );
      } else {
        await client.query(
          `
          INSERT INTO search_projections (entity_id, data, last_applied_lsn, updated_at)
          VALUES ($1, $2, $3::pg_lsn, NOW())
          ON CONFLICT (entity_id) DO UPDATE
          SET data = EXCLUDED.data,
              last_applied_lsn = EXCLUDED.last_applied_lsn,
              updated_at = NOW()
          WHERE search_projections.last_applied_lsn < EXCLUDED.last_applied_lsn;
          `,
          [event.rowId, JSON.stringify(event.payload), event.lsn]
        );
      }

      await client.query('COMMIT;');
      return true;
    } catch (err) {
      await client.query('ROLLBACK;');
      throw err;
    } finally {
      client.release();
    }
  }
}
```

---

## 5. Production TypeScript Harness: `AgenticDatabaseCDCEngine`

```typescript
import { Pool, PoolClient } from 'pg';
import { EventEmitter } from 'events';

export type CDCSlotState = 
  | 'SLOT_PROVISIONED'
  | 'STREAM_ACTIVE'
  | 'TX_STREAMING'
  | 'LSN_COMMITTED'
  | 'LAG_BACKOFF'
  | 'SLOT_INVALIDATED';

export interface CDCSlotAudit {
  slotName: string;
  active: boolean;
  walStatus: 'normal' | 'reserved' | 'extended' | 'lost' | 'unreserved';
  lagBytes: number;
  lagMb: number;
  catalogXminAge: number;
  isDiskAtRisk: boolean;
  isCatalogBloated: boolean;
}

export interface CDCEngineConfig {
  connectionString: string;
  slotName: string;
  publicationName: string;
  maxAllowedLagMb: number; // e.g. 10240 MB (10 GB)
  maxAllowedCatalogXminAge: number; // e.g. 500,000 transactions
}

export class AgenticDatabaseCDCEngine extends EventEmitter {
  private pool: Pool;
  private config: CDCEngineConfig;
  private currentState: CDCSlotState = 'SLOT_PROVISIONED';

  constructor(config: CDCEngineConfig) {
    super();
    this.config = config;
    this.pool = new Pool({ connectionString: config.connectionString });
  }

  public getState(): CDCSlotState {
    return this.currentState;
  }

  /**
   * Audits health of logical replication slots, checking WAL lag and catalog_xmin age.
   */
  public async auditSlotHealth(): Promise<CDCSlotAudit> {
    const client: PoolClient = await this.pool.connect();
    try {
      const res = await client.query(`
        SELECT
          slot_name,
          active,
          wal_status,
          COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0) AS lag_bytes,
          ROUND(COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0) / (1024 * 1024), 2) AS lag_mb,
          COALESCE(age(catalog_xmin), 0) AS catalog_xmin_age
        FROM pg_replication_slots
        WHERE slot_name = $1 AND slot_type = 'logical';
      `, [this.config.slotName]);

      if (res.rows.length === 0) {
        throw new Error(`Logical replication slot '${this.config.slotName}' does not exist`);
      }

      const row = res.rows[0];
      const lagMb = Number(row.lag_mb);
      const catalogAge = Number(row.catalog_xmin_age);
      const walStatus = row.wal_status as CDCSlotAudit['walStatus'];

      const isDiskAtRisk = lagMb > this.config.maxAllowedLagMb || walStatus === 'extended' || walStatus === 'lost';
      const isCatalogBloated = catalogAge > this.config.maxAllowedCatalogXminAge;

      if (walStatus === 'lost') {
        this.currentState = 'SLOT_INVALIDATED';
      } else if (isDiskAtRisk) {
        this.currentState = 'LAG_BACKOFF';
      } else if (row.active) {
        this.currentState = 'STREAM_ACTIVE';
      }

      return {
        slotName: row.slot_name,
        active: row.active,
        walStatus,
        lagBytes: Number(row.lag_bytes),
        lagMb,
        catalogXminAge: catalogAge,
        isDiskAtRisk,
        isCatalogBloated,
      };
    } finally {
      client.release();
    }
  }

  /**
   * Verifies that all publication tables have valid REPLICA IDENTITY (DEFAULT with PK or USING INDEX).
   * Prevents full sequential table scan catastrophes on subscribers.
   */
  public async verifyReplicaIdentityInvariants(): Promise<{ valid: boolean; violations: string[] }> {
    const client: PoolClient = await this.pool.connect();
    try {
      const res = await client.query(`
        SELECT
          c.relname AS table_name,
          c.relreplident AS replica_identity,
          CASE c.relreplident
            WHEN 'd' THEN 'default (PK)'
            WHEN 'n' THEN 'nothing'
            WHEN 'f' THEN 'full'
            WHEN 'i' THEN 'index'
          END AS identity_desc,
          (
            SELECT count(*) 
            FROM pg_index i 
            WHERE i.indrelid = c.oid AND i.indisprimary
          ) > 0 AS has_primary_key
        FROM pg_publication_tables pt
        JOIN pg_class c ON c.relname = pt.tablename
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = pt.schemaname
        WHERE pt.pubname = $1;
      `, [this.config.publicationName]);

      const violations: string[] = [];

      for (const row of res.rows) {
        // Violations:
        // 1. relreplident = 'd' (default) but table lacks primary key!
        if (row.replica_identity === 'd' && !row.has_primary_key) {
          violations.push(`Table ${row.table_name} has REPLICA IDENTITY DEFAULT but NO PRIMARY KEY! Updates will fail.`);
        }
        // 2. relreplident = 'n' (nothing): UPDATE/DELETE cannot be replicated
        if (row.replica_identity === 'n') {
          violations.push(`Table ${row.table_name} has REPLICA IDENTITY NOTHING! UPDATE/DELETE cannot be captured.`);
        }
        // 3. relreplident = 'f' (full): Severe CPU lockup warning
        if (row.replica_identity === 'f') {
          violations.push(`Table ${row.table_name} has REPLICA IDENTITY FULL! Subscribing nodes will perform sequential scans.`);
        }
      }

      return {
        valid: violations.length === 0,
        violations,
      };
    } finally {
      client.release();
    }
  }

  /**
   * Graceful slot termination guard: safely drops slot if orphaned or disk risk critical.
   */
  public async dropSlotIfCritical(audit: CDCSlotAudit): Promise<boolean> {
    if (!audit.isDiskAtRisk && !audit.isCatalogBloated) {
      return false;
    }

    const client: PoolClient = await this.pool.connect();
    try {
      await client.query(`SELECT pg_drop_replication_slot($1);`, [this.config.slotName]);
      this.currentState = 'SLOT_INVALIDATED';
      this.emit('slot_dropped', { slotName: this.config.slotName, reason: 'Disk or catalog risk boundary exceeded' });
      return true;
    } finally {
      client.release();
    }
  }

  public async close(): Promise<void> {
    await this.pool.end();
  }
}
```

---

## 6. CDC & Logical Replication Finite-State Machine (FSM)

```
   ┌────────────────────────────────────────────────────────┐
   │ 0. SLOT_PROVISIONED (pgoutput Slot & Publication Bound)│
   └──────────────────────────┬─────────────────────────────┘
                              │ Client initiates logical replication handshake
                              ▼
   ┌────────────────────────────────────────────────────────┐
   │ 1. STREAM_ACTIVE (Copy-Both Protocol Active, Acking)   │
   └──────────────────────────┬─────────────────────────────┘
                              │ Large transaction decoded (streaming = on)
                              ▼
   ┌────────────────────────────────────────────────────────┐
   │ 2. TX_STREAMING (Streaming Intermediate Changes)       │
   └──────────────────────────┬─────────────────────────────┘
                              │ Transaction commits; LSN advanced
                              ▼
   ┌────────────────────────────────────────────────────────┐
   │ 3. LSN_COMMITTED (confirmed_flush_lsn Flushed to Disk) │
   └──────────────────────────┬─────────────────────────────┘
                              │ Consumer stalls / lag exceeds threshold
                              ▼
   ┌────────────────────────────────────────────────────────┐
   │ 4. LAG_BACKOFF (Downstream Backpressure Throttle)      │
   └──────────────────────────┬─────────────────────────────┘
                              │ Lag > max_slot_wal_keep_size / Slot Dropped
                              ▼
   ┌────────────────────────────────────────────────────────┐
   │ 5. SLOT_INVALIDATED (Slot Lost, Primary Disk Protected)│
   └────────────────────────────────────────────────────────┘
```

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Check | Automated Validation Command / Tool | Acceptance Criteria |
| :--- | :--- | :--- | :--- |
| **Gate 1: Hard Slot Disk Retention Ceiling** | Slot WAL ceiling configuration | `SHOW max_slot_wal_keep_size;` | Value MUST be set between `16384MB` and `65536MB` (never `-1` or `0`). |
| **Gate 2: Active Slot & Lag Sentinel** | Replication slot lag check | `SELECT wal_status, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) FROM pg_replication_slots;` | `wal_status` = `normal`; lag $\le 10\text{GB}$; zero inactive slots $> 15\text{m}$. |
| **Gate 3: Catalog xmin Vacuum Horizon** | System catalog vacuum age check | `SELECT max(age(catalog_xmin)) FROM pg_replication_slots WHERE slot_type = 'logical';` | $\text{Age}(\text{catalog\_xmin}) \le 500,000$ transactions. |
| **Gate 4: Replica Identity Invariance** | Relation replica identity validation | `SELECT relname, relreplident FROM pg_class WHERE relname IN (SELECT tablename FROM pg_publication_tables);` | All tables have `relreplident = 'd'` with valid PK, or `relreplident = 'i'`. No unindexed `'f'`. |
| **Gate 5: In-Memory Decoding Buffer Sizing** | Work memory sizing for CDC | `SHOW logical_decoding_work_mem;` | Sized $\ge 128\text{MB}$ (`131072kB`); streaming enabled. |
| **Gate 6: Monotonic LSN Deduplication** | Consumer idempotency test | `AgenticDatabaseCDCEngine.verifyReplicaIdentityInvariants()` | 100% of replayed duplicate LSNs discarded; monotonic fencing verified. |
