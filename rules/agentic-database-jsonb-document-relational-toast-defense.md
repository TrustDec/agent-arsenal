---
description: PostgreSQL JSONB semi-structured document modeling, jsonb_path_ops inverted indexing, TOAST compression & de-TOASTing memory defense, expression B-tree indexing, CHECK constraint schema fencing, surgical partial mutations, and bounded jsonb_agg streaming across Go (pgx/v5), TypeScript (Drizzle/Kysely/Prisma), Python (psycopg3/SQLAlchemy), Rust (tokio-postgres), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{json,jsonb,toast,document,payload,metadata,repository,schema}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database JSONB Document-Relational Modeling, jsonb_path_ops Inverted Indexing, TOAST Compression & Schema Invariant Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design semi-structured document storage, polymorphic event stores, metadata registries, webhook ingress payloads, dynamic configuration engines, or JSONB-accelerated domain models across PostgreSQL, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `Prisma`), Python (`psycopg3`, `SQLAlchemy`), or Rust (`tokio-postgres`). Eliminate the "TOAST De-TOASTing Memory & I/O Cliff" (where queries execute `SELECT * FROM events` or scan unbounded JSONB columns exceeding `TOAST_TUPLE_THRESHOLD` [2KB], forcing PostgreSQL to read, reconstruct, and decompress out-of-line TOAST chunks across multiple 8KB pages, driving cache eviction in `shared_buffers`, increasing read I/O by $50\times$, and triggering catastrophic p99 latency spikes even when the caller only needed scalar metadata like `id` and `created_at`), the "Whole-Tuple UPDATE & TOAST Duplication Avalanche" (where agents modify a single nested key via `UPDATE t SET payload = jsonb_set(payload, '{status}', '"paid"')`, unaware that PostgreSQL cannot perform partial in-place TOAST modifications, rewriting the entire heap tuple and duplicating multi-kilobyte TOAST chunks, producing massive write amplification, exhausting WAL bandwidth, dirtying disk buffers, and triggering aggressive MVCC bloat), the "Default `jsonb_ops` GIN Index Bloat & Key-Explosion Catastrophe" (where agents execute `CREATE INDEX ON t USING gin (payload)` using default `jsonb_ops`, extracting and indexing every single nested key, path, scalar value, and array element separately, ballooning the GIN index size to $3\times–6\times$ the table heap and slowing write throughput; whereas `jsonb_path_ops` hashes full paths into compact 32-bit integers, yielding up to 65% smaller indexes and faster containment lookups), the "Non-Sargable Arrow Operator `->>` Sequential Table Scan Trap" (where queries execute `WHERE payload->>'customer_id' = $1`, expecting a generic GIN index on `payload` to accelerate it; PostgreSQL GIN indexes ONLY accelerate containment `@>`, `?`, `?|`, and `?&`, causing the planner to silently bypass the GIN index and execute a full-table sequential scan across millions of records), the "Schema-Free Lawlessness & Polymorphic JSON Data Corruption" (where agents treat JSONB as untyped schemaless dumping grounds, causing data drift across services: numbers stored as strings `"120"` vs `120`, missing keys vs `null`, snake_case vs camelCase, and missing mandatory version tags, which causes downstream Go/TypeScript/Rust deserializers to crash with unmarshaling errors), and the "Unbounded `jsonb_agg` Memory Spill & Temp File Exhaustion" (where agents construct nested JSON API responses directly in SQL using `jsonb_agg(jsonb_build_object(...))` across 1:N joins without pagination, causing per-query memory consumption to surpass `work_mem` and spill uncompressed JSON trees to disk temp files, inducing OOM killer decapitations and query timeouts) by establishing a strict 5-Tier JSONB Document-Relational Governance Ladder, vertical table partitioning, `jsonb_path_ops` index specialization, database-level schema constraints, and machine-verifiable CI sentinels.

---

## 1. Architectural Taxonomy: The 6 JSONB Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL provides two storage formats for JSON data:
1. **`json` (Textual Representation)**: Stores exact text representation including whitespace and duplicate keys. Requires reparsing on every read; lacks indexed binary search.
2. **`jsonb` (Binary Decomposed Format)**: Parses text on input into a hierarchical binary format with typed values (numbers, strings, booleans, null, arrays, objects). Supports fast containment operations (`@>`), key existence testing (`?`), and inverted indexing (GIN).

Underlying `jsonb` storage is the **TOAST (The Oversized-Attribute Storage Technique)** subsystem:
- When a tuple exceeds `TOAST_TUPLE_THRESHOLD` (typically 2KB), PostgreSQL compresses large variable-length fields (such as JSONB documents) using `pglz` or `lz4`.
- If compressed size still exceeds `TOAST_TUPLE_TARGET` (typically 2KB), slices of 2KB are pushed out-of-line into a separate auxiliary table (`pg_toast_<oid>`).
- Accessing a TOASTed JSONB column requires reading multiple out-of-line chunks and decompressing them in RAM.

When autonomous coding agents generate JSONB schemas and queries, LLMs routinely commit fatal architectural anti-patterns:

```typescript
// ❌ CATASTROPHIC LLM JSONB & TOAST ANTI-PATTERNS

// 1. Unbounded SELECT * causing massive TOAST de-compression & cache eviction!
// On a 10,000,000 row table where metadata averages 25KB per row,
// SELECT * fetches 250GB of compressed TOAST chunks from disk, evicts hot indexes
// from shared_buffers, and consumes gigabytes of Node.js / Go heap memory!
const events = await db.query(
  `SELECT * FROM audit_events WHERE created_at >= NOW() - INTERVAL '1 day'`
);

// 2. Modifying a single scalar key via jsonb_set() on a large document!
// PostgreSQL CANNOT modify TOAST chunks in place. This single 5-byte edit writes
// a full 25KB new TOAST entry, generates 25KB of WAL records, and dirties 4 buffer pages!
await db.query(
  `UPDATE audit_events SET payload = jsonb_set(payload, '{retry_count}', '1'::jsonb) WHERE id = $1`,
  [eventId]
);

// 3. Default jsonb_ops GIN indexing causing catastrophic index bloat!
// Creates an inverted index entry for EVERY key, sub-key, scalar, and array element.
// On polymorphic payloads with 80+ dynamic keys, index size balloons to 400% of table heap!
await db.query(`CREATE INDEX idx_events_payload ON audit_events USING gin (payload)`);

// 4. Non-sargable arrow operator ->> on GIN-indexed column!
// GIN indexes DO NOT support the -> or ->> operator!
// This query SILENTLY bypasses idx_events_payload and triggers a 10,000,000-row Seq Scan!
const userEvents = await db.query(
  `SELECT id, created_at FROM audit_events WHERE payload->>'user_id' = $1`,
  [userId]
);

// 5. Schemaless lawlessness: missing database-level schema constraints!
// Agents and microservices write incompatible payload variants without validation.
// Downstream Go services fail with `json: cannot unmarshal string into Go struct field Event.amount of type float64`!
await db.query(
  `INSERT INTO orders (id, customer_id, details) VALUES ($1, $2, $3)`,
  [id, customerId, JSON.stringify({ amount: "99.95", status: "pending" })] // amount as string instead of number!
);

// 6. Unbounded jsonb_agg causing work_mem overflow and temp file disk spills!
// Generates a monolithic 150MB JSON tree in memory for high-volume customers,
// spilling temp files to disk and triggering an OOM kill under concurrent load.
const customerHistory = await db.query(
  `SELECT c.id, jsonb_agg(o.*) AS order_history
   FROM customers c
   JOIN orders o ON o.customer_id = c.id
   GROUP BY c.id`
);
```

### The 5-Tier JSONB Document-Relational Governance Ladder

To eliminate these catastrophes, all database interactions must strictly adhere to the **5-Tier JSONB Governance Ladder**:

```
5-Tier JSONB Document-Relational Governance Ladder
├── Tier 0: Physical Column Projection, Vertical Table Partitioning & TOAST Strategy Tuning
├── Tier 1: Database-Level Schema Fencing, jsonb_typeof & Top-Level Key Assertions (?&)
├── Tier 2: Sargable Index Specialization (jsonb_path_ops GIN vs Expression B-Trees & Generated Columns)
├── Tier 3: Partial GIN Indexing, Sparse Attribute Fencing & jsonb_path_query Acceleration
└── Tier 4: Surgical Mutation Isolation, Bounded Streaming jsonb_agg & Zero-Spill CI Gateways
```

- **Tier 0: Physical Column Projection, Vertical Table Partitioning & TOAST Strategy Tuning**:
  - Never execute `SELECT *` on relations containing JSONB columns. Explicitly project only scalar relational columns (`SELECT id, status, created_at`).
  - Vertically partition wide documents: store core relational attributes (`id`, `tenant_id`, `status`, `created_at`) in the primary table, and push large polymorphic payloads (`metadata`, `raw_payload`) into an auxiliary satellite table or dedicated column with `SET STORAGE EXTENDED`.
  - For payloads exceeding 100KB with low read frequency, configure `ALTER TABLE t ALTER COLUMN payload SET STORAGE EXTERNAL` to bypass CPU-intensive compression when decompression cost exceeds disk I/O savings.
- **Tier 1: Database-Level Schema Fencing, `jsonb_typeof` & Top-Level Key Assertions (`?&`)**:
  - Enforce database-level `CHECK` constraints on JSONB fields. Verify mandatory top-level keys using the `?&` (all keys exist) operator: `CHECK (payload ?& array['version', 'event_type'])`.
  - Validate primitive scalar types using `jsonb_typeof(payload->'amount') = 'number'`.
  - Use `STORED GENERATED` columns for immutable business keys extracted from JSONB to enforce foreign keys and relational integrity.
- **Tier 2: Sargable Index Specialization (`jsonb_path_ops` GIN vs Expression B-Trees)**:
  - For containment searches (`WHERE payload @> '{"status": "active"}'`), ALWAYS build GIN indexes using the `jsonb_path_ops` operator class (`USING gin (payload jsonb_path_ops)`). This reduces index footprint by up to $65\%$ compared to default `jsonb_ops`.
  - For equality or range queries using arrow operators (`WHERE (payload->>'user_id')::uuid = $1`), build an **Expression B-Tree index** (`CREATE INDEX ON t (((payload->>'user_id')::uuid))`). Never rely on GIN for scalar equality.
  - When sorting on a JSONB field (`ORDER BY payload->>'created_at' DESC`), a B-Tree expression index is strictly mandatory.
- **Tier 3: Partial GIN Indexing, Sparse Attribute Fencing & `jsonb_path_query`**:
  - If only a subset of rows contains queryable JSONB properties, build a **Partial GIN Index**: `CREATE INDEX idx_sparse ON t USING gin (payload jsonb_path_ops) WHERE payload ? 'flag'`.
  - For complex nested array filtering, leverage `jsonb_path_query` or `@>` containment rather than unnesting arrays in subqueries.
- **Tier 4: Surgical Mutation Isolation, Bounded Streaming `jsonb_agg` & Zero-Spill CI Gateways**:
  - Never store frequently mutated counters, states, or lock flags inside large JSONB documents. Hoist mutable scalar fields into dedicated relational columns to enable Heap-Only Tuples (HOT) updates without TOAST duplication.
  - Bound `jsonb_agg` aggregations with deterministic subquery `LIMIT` and pagination. Enforce CI static audits and `EXPLAIN (ANALYZE, BUFFERS)` testing verifying zero temporary disk buffer spills (`TempWrittenBlocks == 0`).

---

## 2. Mathematical Foundations: TOAST Amplification, GIN Index Cardinality & Sargability Complexity

### 2.1 TOAST Write Amplification Calculus

When updating a single field inside a JSONB document stored out-of-line in a TOAST table, PostgreSQL cannot perform in-place chunk updates due to MVCC invariants. The write amplification factor $A_w$ is defined as the ratio of physical disk bytes written to the logical mutation size $\Delta S_{logical}$:

$$A_w = \frac{\Delta S_{disk}}{\Delta S_{logical}} = \frac{S_{heap\_tuple} + \left\lceil \frac{S_{jsonb\_compressed}}{S_{chunk}} \right\rceil \cdot S_{chunk\_physical} + S_{wal\_bytes}}{\Delta S_{logical}}$$

Where:
- $S_{heap\_tuple} \approx 28\text{ bytes (header)} + \sum \text{column pointers}$.
- $S_{chunk} = 2,000\text{ bytes (standard TOAST chunk size in an 8KB page)}$.
- $S_{chunk\_physical} = S_{chunk} + 32\text{ bytes (chunk header)}$.
- $S_{wal\_bytes}$ contains full-page writes (FPW) after checkpoints plus WAL record overhead.

**Catastrophe Quantification**:
Consider an audit payload of size $S_{jsonb} = 64\text{KB}$ (compressed to $32\text{KB} = 16\text{ chunks}$).
If an autonomous agent modifies a single boolean status ($\Delta S_{logical} = 5\text{ bytes}$) via `jsonb_set(payload, '{status}', '"done"')`:

$$\Delta S_{disk} \approx 64\text{ bytes (heap)} + (16 \times 2,032\text{ bytes}) + 34,000\text{ bytes (WAL)} \approx 66,576\text{ bytes}$$

$$A_w = \frac{66,576}{5} \approx 13,315\times \text{ write amplification!}$$

By hoisting `status` out of the JSONB document into a native `VARCHAR` / `SMALLINT` column, the update modifies only the heap tuple:

$$\Delta S_{disk} \approx 64\text{ bytes (heap)} + 120\text{ bytes (WAL)} = 184\text{ bytes} \implies A_w = \frac{184}{5} \approx 36.8\times$$

**Efficiency Gain**: Hoisting mutable scalars reduces write I/O and WAL generation by $\mathbf{99.7\%}$.

---

### 2.2 GIN Index Entry Sizing Physics: `jsonb_ops` vs `jsonb_path_ops`

Consider a JSONB document tree with nesting depth $D$, average branching factor $B$, and total leaf attributes $N_{leaves} = B^D$.

1. **Default `jsonb_ops` Entry Cardinality**:
   `jsonb_ops` creates separate GIN index entries for:
   - Every object key: $\sum_{i=1}^D B^i = \frac{B(B^D - 1)}{B - 1}$
   - Every scalar value: $B^D$
   - Every key-value pair: $B^D$

   Total GIN posting entries per document $E_{ops}$:
   $$E_{ops} = B^D + B^D + \frac{B(B^D - 1)}{B - 1} = 2B^D + \frac{B(B^D - 1)}{B - 1}$$

2. **Compact `jsonb_path_ops` Entry Cardinality**:
   `jsonb_path_ops` hashes each root-to-leaf path and its value into a single 32-bit CRC hash (e.g., `hash("user.address.postal_code:94103")`).
   Total GIN posting entries per document $E_{path\_ops}$:
   $$E_{path\_ops} = B^D$$

**Index Footprint Ratio Theorem**:
$$\frac{\text{Entries}(jsonb\_path\_ops)}{\text{Entries}(jsonb\_ops)} = \frac{B^D}{2B^D + \frac{B(B^D - 1)}{B - 1}} \approx \frac{1}{2 + \frac{B}{B-1}}$$

For a typical document with $B = 4, D = 3$ ($64$ leaves, $84$ keys):
$$E_{ops} = 128 + 84 = 212\text{ entries/doc}$$
$$E_{path\_ops} = 64\text{ entries/doc}$$

$$\text{Index Space Reduction} = 1 - \frac{64}{212} = \mathbf{69.8\% \text{ index reduction}}.$$

---

### 2.3 Containment Sargability & Complexity Theorem

Let $R$ be a relation of $N$ tuples, where $M$ tuples match predicate $Q$.
- For containment query `WHERE payload @> '{"tenant_id": "t1", "role": "admin"}'` using `jsonb_path_ops`:
  The planner decomposes $Q$ into $K$ path hashes and performs a Bitmap Index Scan intersecting postings:
  $$T_{path\_ops} = O\left(K \cdot \log N_{entries} + M \cdot \log N_{tuples}\right)$$
- For arrow query `WHERE payload->>'tenant_id' = 't1'` without expression index:
  The planner CANNOT use the GIN index and must execute a sequential scan:
  $$T_{arrow\_unindexed} = O\left(N \cdot (T_{tuple\_read} + T_{de-TOAST} + T_{json\_parse})\right)$$

When $N = 10,000,000$ and $M = 100$:
- $T_{path\_ops} \approx 0.8\text{ms}$ (Bitmap Index Scan reading 2 index blocks and 5 heap blocks)
- $T_{arrow\_unindexed} \approx 4,200\text{ms}$ (Sequential scan reading 1,200,000 disk blocks)
- Speedup factor $\mathbf{S \approx 5,250\times}$.

---

## 3. Production Code Implementations: TypeScript, Go & SQL

### 3.1 Production PostgreSQL Migration: Hardened JSONB Schema, Invariants & Indexes

```sql
-- migration_042_agentic_jsonb_hardened_schema.sql
-- Invariant: Relational core + JSONB satellite + CHECK schema fencing + jsonb_path_ops GIN

CREATE TABLE IF NOT EXISTS customer_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL,
  event_type VARCHAR(64) NOT NULL,
  
  -- Hot mutable scalar fields hoisted out of JSONB to enable HOT updates!
  status VARCHAR(32) NOT NULL DEFAULT 'received',
  retry_count INT NOT NULL DEFAULT 0,
  
  -- Stored generated column for hot business lookup key (B-Tree indexable, foreign-key safe)
  external_id VARCHAR(128) GENERATED ALWAYS AS (
    NULLIF(payload->>'external_id', '')
  ) STORED,

  -- Semi-structured document payload
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  
  created_at TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP(),

  -- 1. Tier 1 Schema Fencing: Mandatory Top-Level Keys
  CONSTRAINT chk_payload_required_keys
    CHECK (payload ?& array['schema_version', 'data']),

  -- 2. Tier 1 Schema Fencing: Type Invariants
  CONSTRAINT chk_payload_schema_version_type
    CHECK (jsonb_typeof(payload->'schema_version') = 'number'),
    
  CONSTRAINT chk_payload_data_type
    CHECK (jsonb_typeof(payload->'data') = 'object')
);

-- Optimize TOAST storage for payload
ALTER TABLE customer_events ALTER COLUMN payload SET STORAGE EXTENDED;

-- 3. Tier 2 Index Specialization: GIN index with jsonb_path_ops for containment (@>)
-- Calibrate gin_pending_list_limit to 16MB to prevent user write stalls
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_customer_events_payload_path_ops
  ON customer_events USING gin (payload jsonb_path_ops)
  WITH (fastupdate = on, gin_pending_list_limit = '16MB');

-- 4. Tier 2 Index Specialization: Expression B-Tree Index for Arrow Operator Lookups & Sorting
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_customer_events_external_id
  ON customer_events (external_id)
  WHERE external_id IS NOT NULL;

-- 5. Tier 3 Partial GIN Index: Accelerate sparse error inspection without bloating standard queries
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_customer_events_errors
  ON customer_events USING gin (payload jsonb_path_ops)
  WHERE payload ? 'error';
```

---

### 3.2 High-Performance Go (`jackc/pgx/v5`): Zero-Allocation JSONB & TOAST Defense

```go
package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// EventData represents the strictly-typed inner payload schema.
type EventData struct {
	SchemaVersion int                    `json:"schema_version"`
	Data          map[string]interface{} `json:"data"`
	ExternalID    string                 `json:"external_id,omitempty"`
}

type CustomerEvent struct {
	ID         uuid.UUID
	TenantID   uuid.UUID
	EventType  string
	Status     string
	RetryCount int
	ExternalID *string
	Payload    EventData
	CreatedAt  time.Time
}

type EventStore struct {
	pool *pgxpool.Pool
}

func NewEventStore(pool *pgxpool.Pool) *EventStore {
	return &EventStore{pool: pool}
}

// InsertEvent demonstrates schema validation before DB ingestion and binary JSONB encoding.
func (s *EventStore) InsertEvent(ctx context.Context, tenantID uuid.UUID, eventType string, data EventData) (uuid.UUID, error) {
	// Guard 1: Verify mandatory schema invariants before touching database
	if data.SchemaVersion <= 0 {
		return uuid.Nil, errors.New("schema_version must be positive integer")
	}
	if data.Data == nil {
		return uuid.Nil, errors.New("data payload cannot be nil")
	}

	payloadBytes, err := json.Marshal(data)
	if err != nil {
		return uuid.Nil, fmt.Errorf("marshal jsonb payload: %w", err)
	}

	query := `
		INSERT INTO customer_events (
			tenant_id, event_type, payload
		) VALUES ($1, $2, $3)
		RETURNING id
	`

	var eventID uuid.UUID
	err = s.pool.QueryRow(ctx, query, tenantID, eventType, payloadBytes).Scan(&eventID)
	if err != nil {
		return uuid.Nil, fmt.Errorf("execute insert event: %w", err)
	}

	return eventID, nil
}

// FindByContainment demonstrates sargable @> query utilizing jsonb_path_ops index.
// Never uses string interpolation or dynamic arrow operators.
func (s *EventStore) FindByContainment(ctx context.Context, tenantID uuid.UUID, filter map[string]interface{}) ([]CustomerEvent, error) {
	filterBytes, err := json.Marshal(filter)
	if err != nil {
		return nil, fmt.Errorf("marshal filter containment: %w", err)
	}

	// Invariant: Select ONLY necessary columns; project payload only when strictly needed!
	query := `
		SELECT
			id, tenant_id, event_type, status, retry_count, external_id, payload, created_at
		FROM customer_events
		WHERE tenant_id = $1
		  AND payload @> $2::jsonb
		ORDER BY created_at DESC
		LIMIT 50
	`

	rows, err := s.pool.Query(ctx, query, tenantID, filterBytes)
	if err != nil {
		return nil, fmt.Errorf("query events by containment: %w", err)
	}
	defer rows.Close()

	var events []CustomerEvent
	for rows.Next() {
		var ev CustomerEvent
		var rawPayload []byte

		if err := rows.Scan(
			&ev.ID,
			&ev.TenantID,
			&ev.EventType,
			&ev.Status,
			&ev.RetryCount,
			&ev.ExternalID,
			&rawPayload,
			&ev.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan event row: %w", err)
		}

		if err := json.Unmarshal(rawPayload, &ev.Payload); err != nil {
			return nil, fmt.Errorf("unmarshal payload jsonb: %w", err)
		}

		events = append(events, ev)
	}

	return events, rows.Err()
}

// SurgicalScalarUpdate modifies scalar fields WITHOUT re-serializing or dirtying the multi-KB JSONB TOAST chunks!
func (s *EventStore) SurgicalScalarUpdate(ctx context.Context, eventID uuid.UUID, newStatus string) error {
	query := `
		UPDATE customer_events
		SET status = $2,
		    retry_count = retry_count + 1,
		    updated_at = CLOCK_TIMESTAMP()
		WHERE id = $1
	`
	tag, err := s.pool.Exec(ctx, query, eventID, newStatus)
	if err != nil {
		return fmt.Errorf("surgical update status: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return pgx.ErrNoRows
	}
	return nil
}

// StreamBoundedJSONAgg executes memory-bounded JSON aggregation with LIMIT to prevent work_mem spill.
func (s *EventStore) StreamBoundedJSONAgg(ctx context.Context, tenantID uuid.UUID, limit int) ([]byte, error) {
	if limit > 500 {
		limit = 500 // Defensive ceiling
	}

	query := `
		SELECT coalesce(jsonb_agg(sub.event_data), '[]'::jsonb)
		FROM (
			SELECT jsonb_build_object(
				'id', id,
				'event_type', event_type,
				'status', status,
				'created_at', created_at
			) AS event_data
			FROM customer_events
			WHERE tenant_id = $1
			ORDER BY created_at DESC
			LIMIT $2
		) sub
	`

	var jsonResult []byte
	err := s.pool.QueryRow(ctx, query, tenantID, limit).Scan(&jsonResult)
	if err != nil {
		return nil, fmt.Errorf("stream bounded jsonb_agg: %w", err)
	}
	return jsonResult, nil
}
```

---

### 3.3 TypeScript (`Drizzle ORM` & `pg`): Type-Safe Containment & Sargable Querying

```typescript
import { pgTable, uuid, varchar, integer, timestamp, jsonb, customType } from 'drizzle-orm/pg-core';
import { sql, eq, and } from 'drizzle-orm';
import { z } from 'zod';

// Strict runtime schema validation via Zod
export const EventPayloadSchema = z.object({
  schema_version: z.number().int().positive(),
  data: z.record(z.unknown()),
  external_id: z.string().optional(),
});

export type EventPayload = z.infer<typeof EventPayloadSchema>;

export const customerEvents = pgTable('customer_events', {
  id: uuid('id').defaultRandom().primaryKey(),
  tenantId: uuid('tenant_id').notNull(),
  eventType: varchar('event_type', { length: 64 }).notNull(),
  status: varchar('status', { length: 32 }).notNull().default('received'),
  retryCount: integer('retry_count').notNull().default(0),
  externalId: varchar('external_id', { length: 128 }),
  payload: jsonb('payload').$type<EventPayload>().notNull().default({}),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
});

/**
 * Type-safe sargable containment query builder.
 * Translates filter objects into SQL `@>` containment against `jsonb_path_ops` index.
 */
export function buildJsonbContainmentPredicate(column: any, filter: Record<string, unknown>) {
  return sql`${column} @> ${JSON.stringify(filter)}::jsonb`;
}

/**
 * Example usage: Query events safely without non-sargable arrow operators
 */
export async function findOrdersByStatus(db: any, tenantId: string, orderStatus: string) {
  // ✅ SARGABLE: Hits idx_customer_events_payload_path_ops via Bitmap Index Scan
  const results = await db
    .select({
      id: customerEvents.id,
      tenantId: customerEvents.tenantId,
      eventType: customerEvents.eventType,
      status: customerEvents.status,
      createdAt: customerEvents.createdAt,
    })
    .from(customerEvents)
    .where(
      and(
        eq(customerEvents.tenantId, tenantId),
        buildJsonbContainmentPredicate(customerEvents.payload, {
          data: { order_status: orderStatus },
        })
      )
    )
    .limit(50);

  return results;
}
```

---

## 4. Production TypeScript Governance Engine: `AgenticDatabaseJSONBEngine`

```typescript
import { Pool, PoolClient } from 'pg';

export interface JsonbColumnAudit {
  tableName: string;
  columnName: string;
  totalTableBytes: number;
  totalToastBytes: number;
  toastRatio: number; // toastBytes / (tableBytes + toastBytes)
  storageStrategy: 'EXTENDED' | 'EXTERNAL' | 'MAIN' | 'PLAIN';
  hasCheckConstraint: boolean;
}

export interface JsonbIndexAudit {
  tableName: string;
  indexName: string;
  indexSizeBytes: number;
  indexSizePretty: string;
  operatorClass: 'jsonb_ops' | 'jsonb_path_ops' | 'btree_expression' | 'other';
  isPathOpsOptimized: boolean;
  isBloatedDefaultOps: boolean;
}

export interface SargabilityCheckResult {
  isSargable: boolean;
  detectedAntiPatterns: string[];
  recommendedSqlRewrite?: string;
}

export class AgenticDatabaseJSONBEngine {
  constructor(private pool: Pool) {}

  /**
   * Audits database for JSONB columns, assessing TOAST footprint and storage strategy.
   */
  public async auditJsonbColumns(): Promise<JsonbColumnAudit[]> {
    const query = `
      SELECT
        c.relname AS table_name,
        a.attname AS column_name,
        CASE a.attstorage
          WHEN 'x' THEN 'EXTENDED'
          WHEN 'e' THEN 'EXTERNAL'
          WHEN 'm' THEN 'MAIN'
          WHEN 'p' THEN 'PLAIN'
        END AS storage_strategy,
        pg_relation_size(c.oid) AS table_bytes,
        COALESCE(pg_relation_size(c.reltoastrelid), 0) AS toast_bytes,
        EXISTS (
          SELECT 1 FROM pg_constraint con
          WHERE con.conrelid = c.oid
            AND con.contype = 'c'
            AND pg_get_constraintdef(con.oid) ILIKE '%' || a.attname || '%'
        ) AS has_check_constraint
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_type t ON t.oid = a.atttypid
      WHERE t.typname = 'jsonb'
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND c.relnamespace = 'public'::regnamespace
      ORDER BY toast_bytes DESC;
    `;

    const res = await this.pool.query(query);
    return res.rows.map((r: any) => {
      const tableBytes = parseInt(r.table_bytes, 10);
      const toastBytes = parseInt(r.toast_bytes, 10);
      const total = tableBytes + toastBytes;
      const ratio = total > 0 ? toastBytes / total : 0;

      return {
        tableName: r.table_name,
        columnName: r.column_name,
        totalTableBytes: tableBytes,
        totalToastBytes: toastBytes,
        toastRatio: Math.round(ratio * 1000) / 1000,
        storageStrategy: r.storage_strategy,
        hasCheckConstraint: r.has_check_constraint === true,
      };
    });
  }

  /**
   * Identifies unoptimized default `jsonb_ops` GIN indexes that should be migrated to `jsonb_path_ops`.
   */
  public async auditJsonbIndexes(): Promise<JsonbIndexAudit[]> {
    const query = `
      SELECT
        t.relname AS table_name,
        i.relname AS index_name,
        pg_relation_size(i.oid) AS index_bytes,
        pg_size_pretty(pg_relation_size(i.oid)) AS index_size_pretty,
        opc.opcname AS opclass_name
      FROM pg_index x
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_am am ON am.oid = i.relam
      JOIN pg_opclass opc ON opc.oid = ANY(x.indclass)
      WHERE am.amname = 'gin'
        AND opc.opcname IN ('jsonb_ops', 'jsonb_path_ops')
        AND t.relnamespace = 'public'::regnamespace
      ORDER BY index_bytes DESC;
    `;

    const res = await this.pool.query(query);
    return res.rows.map((r: any) => {
      const bytes = parseInt(r.index_bytes, 10);
      const isPathOps = r.opclass_name === 'jsonb_path_ops';
      return {
        tableName: r.table_name,
        indexName: r.index_name,
        indexSizeBytes: bytes,
        indexSizePretty: r.index_size_pretty,
        operatorClass: isPathOps ? 'jsonb_path_ops' : 'jsonb_ops',
        isPathOpsOptimized: isPathOps,
        isBloatedDefaultOps: !isPathOps && bytes > 50 * 1024 * 1024, // > 50MB
      };
    });
  }

  /**
   * Static AST / Regex query analyzer: detects non-sargable arrow operators on JSONB fields.
   */
  public analyzeQuerySargability(sqlQuery: string): SargabilityCheckResult {
    const antiPatterns: string[] = [];

    // Pattern 1: Non-sargable arrow equality (WHERE payload->>'key' = $1)
    if (/WHERE\s+.*->>\s*['"][a-zA-Z0-9_-]+['"]\s*=/i.test(sqlQuery)) {
      antiPatterns.push(
        "Non-sargable arrow operator '->>' in WHERE equality. GIN index cannot accelerate this without expression index. Use '@>' containment or expression B-Tree."
      );
    }

    // Pattern 2: SELECT * on tables with potential JSONB TOAST columns
    if (/SELECT\s+\*\s+FROM/i.test(sqlQuery)) {
      antiPatterns.push(
        "SELECT * projection detected. Forces full TOAST chunk decompression into RAM. Explicitly project scalar fields."
      );
    }

    // Pattern 3: jsonb_set on large documents
    if (/UPDATE\s+.*SET\s+.*=\s*jsonb_set\(/i.test(sqlQuery)) {
      antiPatterns.push(
        "jsonb_set() in UPDATE statement detected. Triggers full TOAST row duplication and write amplification. Hoist mutable field to relational column."
      );
    }

    return {
      isSargable: antiPatterns.length === 0,
      detectedAntiPatterns: antiPatterns,
    };
  }
}
```

---

## 5. Machine-Verifiable 6-State FSM & Definition of Done (DoD)

### 5.1 JSONB Document Lifecycle Finite State Machine (FSM)

```
       ┌────────────────────────┐
       │ 1. UNVALIDATED_RAW     │
       │  (Ingress payload)     │
       └───────────┬────────────┘
                   │ Validate schema invariants
                   ▼
       ┌────────────────────────┐
       │ 2. SCHEMA_FENCED       │
       │  (?&, jsonb_typeof)    │
       └───────────┬────────────┘
                   │ Vertical partitioning
                   ▼
       ┌────────────────────────┐
       │ 3. TOAST_OPTIMIZED     │
       │ (Scalar col projected) │
       └───────────┬────────────┘
                   │ Index specialization
                   ▼
       ┌────────────────────────┐
       │ 4. SARGABLE_INDEXED    │
       │ (path_ops GIN/B-Tree)  │
       └───────────┬────────────┘
                   │ In-place mutation isolation
                   ▼
       ┌────────────────────────┐
       │ 5. SURGICAL_MUTATION   │
       │ (HOT update friendly)  │
       └───────────┬────────────┘
                   │ CI buffer verification
                   ▼
       ┌────────────────────────┐
       │ 6. BUFFER_SENTINEL_OK  │
       │ (0 temp spills in CI)  │
       └────────────────────────┘
```

### 5.2 6-Gate Machine-Verifiable Definition of Done (DoD)

| Gate | Target Metric / Invariant | Verification Command / Metric |
| :--- | :--- | :--- |
| **Gate 1: Zero TOAST-Leak `SELECT *`** | 100% of queries reading JSONB tables specify explicit column projections | `grep -rn "SELECT \* FROM" src/` returns 0 hits against JSONB relations |
| **Gate 2: Database Schema Fencing** | 100% of JSONB columns have mandatory top-level key (`?&`) and type constraints | `auditJsonbColumns()` confirms `hasCheckConstraint == true` |
| **Gate 3: Inverted Index Precision** | 100% of containment GIN indexes use `jsonb_path_ops` (zero default `jsonb_ops` bloat) | `auditJsonbIndexes()` verifies `isPathOpsOptimized == true` |
| **Gate 4: Arrow Sargability Guarantee** | Zero unindexed `->>` arrow operators in production `WHERE` clauses | Static AST query analyzer flags 0 non-sargable arrow equalities |
| **Gate 5: Surgical Mutation Isolation** | High-frequency mutable counters/statuses hoisted to native relational columns | `grep -rn "jsonb_set" src/` confirms 0 high-concurrency mutation paths |
| **Gate 6: Zero Buffer Spills in Aggregation** | Multi-row `jsonb_agg` queries bounded by subquery `LIMIT` and execute in RAM | `EXPLAIN (ANALYZE, BUFFERS)` confirms `TempWrittenBlocks == 0` |
