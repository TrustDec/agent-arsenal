---
description: Event Sourcing, CQRS, Domain-Driven Design, aggregate roots, append-only event store, pure apply reducers, optimistic stream concurrency, asynchronous read-model projections, idempotency, event snapshotting, schema evolution & upcasters, transactional outbox CDC, and GDPR cryptographic shredding invariants
globs: **/*{eventsourcing,cqrs,aggregate,eventstore,projection,eventshop,outbox,saga,upcaster}*.*,**/aggregates/**,**/projections/**,**/events/**,**/commands/**,**/domain/**
alwaysApply: false
---

# Event Sourcing, CQRS & Domain-Driven Event Architecture Invariants

> Add these rules to your project when architecting, implementing, or auditing event-sourced systems, Command Query Responsibility Segregation (CQRS) architectures, Domain-Driven Design (DDD) aggregate roots, append-only event stores, read-model projections, or event upcasting engines (PostgreSQL, EventStoreDB, Kafka, Go, TypeScript, Java/Kotlin, C#).

---

## 1. Architectural Taxonomy: CQRS & Event Sourcing Engine

In a standard CRUD architecture, state is mutable and destructive: an `UPDATE` statement overwrites previous values, permanently erasing historical context, intent, and auditability. 

In **Event Sourcing**, state is never stored directly as mutable records. Instead, every state change is recorded as an immutable, append-only **Domain Event**. The current state of an entity (an **Aggregate Root**) is derived deterministically by replaying its historical stream of events from the beginning of time (or from a consolidated snapshot).

In **CQRS (Command Query Responsibility Segregation)**, the write model (optimizing for consistency invariants, transactional boundaries, and append-only throughput) is completely segregated from the read model (optimizing for denormalized, fast, and multi-dimensional queries).

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                   Command (Write) Side                                 │
│                                                                                        │
│   ┌─────────────────┐       ┌────────────────────────┐      ┌──────────────────────┐   │
│   │ Client Command  │ ────▶ │ Command Handler        │ ───▶ │ Aggregate Root       │   │
│   │ (e.g. PlaceOrder│       │ (Validates Auth & Env) │      │ (Enforces Business   │   │
│   └─────────────────┘       └────────────────────────┘      │  Invariants)         │   │
│                                                             └──────────┬───────────┘   │
│                                                                        │ 1. Yields     │
│                                                                        ▼    Events     │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │ Append-Only Event Store (PostgreSQL / EventStoreDB)                            │   │
│   │ • stream_id = "order-456"                                                      │   │
│   │ • expected_version = 3 (Optimistic Concurrency Control)                       │   │
│   │ • events: [ OrderCreated(v1), ItemAdded(v2), OrderSubmitted(v3) ]             │   │
│   └───────────────────────────────────────┬────────────────────────────────────────┘   │
└───────────────────────────────────────────┼────────────────────────────────────────────┘
                                            │ 2. Outbox CDC / Log Tailer
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                    Query (Read) Side                                   │
│                                                                                        │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │ Asynchronous Projection Workers (Idempotent Consumers)                         │   │
│   │ • Deduplicates via stream_position checkpoint                                  │   │
│   │ • Updates read tables: customer_orders, order_analytics, inventory_views       │   │
│   └───────────────────────────────────────┬────────────────────────────────────────┘   │
│                                           │ 3. Materialized View Update                │
│                                           ▼                                            │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │ Denormalized Read Models (PostgreSQL / Elasticsearch / Redis)                  │   │
│   │ • High-speed O(1) indexed reads, complex joins, full-text search               │   │
│   └───────────────────────────────────────┬────────────────────────────────────────┘   │
│                                           │ 4. Read Query                              │
│                                           ▼                                            │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │ Client Query API (GET /orders/456 -> Returns pre-computed JSON read model)     │   │
│   └────────────────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. The Aggregate Root Invariant Boundary & Pure `Apply()` Reducer
An **Aggregate Root** is the sole consistency boundary in Domain-Driven Design. Outside actors cannot mutate internal child entities directly; all state changes must pass through the Aggregate Root via explicit Commands.

- ❌ **THE MUTATION IN COMMAND HANDLER ANTI-PATTERN**:
  - Mutating aggregate struct/class fields directly inside the command handler method (`this.status = 'COMPLETED'`).
  - Emitting domain events as mere "after-the-fact notifications" while maintaining mutable internal state.
  - Calling external network APIs, databases, or random generators (`Math.random()`, `time.Now()`, `crypto.randomUUID()`) inside `apply()` reducers during stream replay.
- ✅ **The Separation of Intent vs Fact**:
  - **Command** (Imperative request, can be rejected): `SubmitOrderCommand { orderId, paymentToken }`.
  - **Event** (Past historical fact, immutable, cannot be rejected): `OrderSubmittedEvent { orderId, submittedAt }`.
- ✅ **The Pure `Apply()` State Reducer Rule**:
  - Command handlers validate business rules against current state. If valid, they return/emit **uncommitted events**.
  - Internal aggregate state is modified **exclusively** inside a pure `apply(event)` method.
  - The `apply(event)` method MUST be **strictly deterministic and side-effect free**. When hydrating an aggregate from past events, `apply()` is called repeatedly without re-evaluating command validation rules.

```typescript
// TypeScript: Production-Grade Aggregate Root Pattern
export interface DomainEvent {
  readonly streamId: string;
  readonly version: number;
  readonly eventType: string;
  readonly payload: Record<string, unknown>;
  readonly occurredAt: string; // ISO-8601 UTC
}

export class OrderAggregate {
  private _id: string = '';
  private _status: 'DRAFT' | 'SUBMITTED' | 'PAID' | 'CANCELLED' = 'DRAFT';
  private _totalCents: bigint = 0n;
  private _version: number = 0;
  private readonly _uncommittedEvents: DomainEvent[] = [];

  public get id(): string { return this._id; }
  public get version(): number { return this._version; }
  public get status(): string { return this._status; }
  public get uncommittedEvents(): readonly DomainEvent[] { return this._uncommittedEvents; }

  // 1. Rehydrate aggregate from historical event stream
  public static rehydrate(events: readonly DomainEvent[]): OrderAggregate {
    const aggregate = new OrderAggregate();
    for (const event of events) {
      aggregate.applyEvent(event, false);
    }
    return aggregate;
  }

  // 2. Command Handler: Validates business invariants, produces event
  public submitOrder(submittedAt: string): void {
    if (this._status !== 'DRAFT') {
      throw new Error(`Invalid state transition: Cannot submit order in ${this._status} status`);
    }
    if (this._totalCents <= 0n) {
      throw new Error('Invariant violated: Cannot submit an order with zero or negative total amount');
    }

    const event: DomainEvent = {
      streamId: this._id,
      version: this._version + 1,
      eventType: 'OrderSubmitted',
      payload: { orderId: this._id, submittedAt },
      occurredAt: submittedAt,
    };

    this.applyEvent(event, true);
  }

  // 3. Pure Reducer: Applies state mutation deterministically
  private applyEvent(event: DomainEvent, isNew: boolean): void {
    switch (event.eventType) {
      case 'OrderCreated':
        this._id = event.payload.orderId as string;
        this._totalCents = BigInt(event.payload.totalCents as string);
        this._status = 'DRAFT';
        break;
      case 'OrderSubmitted':
        this._status = 'SUBMITTED';
        break;
      case 'OrderPaid':
        this._status = 'PAID';
        break;
      case 'OrderCancelled':
        this._status = 'CANCELLED';
        break;
      default:
        // Ignore unhandled future events for forward compatibility
        break;
    }

    this._version = event.version;
    if (isNew) {
      this._uncommittedEvents.push(event);
    }
  }

  public clearUncommittedEvents(): void {
    this._uncommittedEvents.length = 0;
  }
}
```

---

## 3. Append-Only Event Store Schema & Optimistic Concurrency Invariants

An event store is fundamentally an append-only sequence of immutable events. To prevent lost updates and race conditions across distributed concurrent commands, every append operation MUST enforce **Optimistic Concurrency Control (OCC)** using stream version counters.

- ❌ **THE SILENT WRITE-SKEW TRAP**:
  - Appending events without verifying the stream version. Two concurrent clients read version 4, and both append version 5 concurrently, leading to branching streams, corrupted aggregate history, or phantom double charges.
  - Using auto-incremented primary keys alone without a composite unique constraint on `(stream_id, version)`.
- ✅ **The PostgreSQL Append-Only Event Store Schema**:
  - Enforce `PRIMARY KEY (stream_id, version)` to make concurrent writes fail at the database engine level with a unique violation code (`23505`).
  - Provide a monotonic global sequence `global_position` (`BIGINT GENERATED ALWAYS AS IDENTITY`) for asynchronous projection workers and CDC tailers.

```sql
-- Production PostgreSQL Event Store Table
CREATE TABLE event_store (
    global_position BIGINT GENERATED ALWAYS AS IDENTITY,
    stream_id VARCHAR(128) NOT NULL,
    version BIGINT NOT NULL,
    event_type VARCHAR(128) NOT NULL,
    payload JSONB NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    -- Invariant: An aggregate stream can have strictly one event per version
    PRIMARY KEY (stream_id, version),
    CONSTRAINT chk_positive_version CHECK (version > 0)
);

-- Index for projection streaming and cross-aggregate replay
CREATE UNIQUE INDEX idx_event_store_global_position 
ON event_store (global_position);

-- Index for aggregate rehydration by stream_id
CREATE INDEX idx_event_store_stream_id_version 
ON event_store (stream_id, version ASC);
```

- ✅ **Atomic Append with Concurrency Check (Go Implementation)**:

```go
package eventstore

import (
    "context"
    "database/sql"
    "encoding/json"
    "errors"
    "fmt"
    "github.com/lib/pq"
)

var ErrConcurrencyConflict = errors.New("eventstore: optimistic concurrency conflict; stream modified")

type EventRecord struct {
    StreamID  string
    Version   int64
    EventType string
    Payload   json.RawMessage
    Metadata  json.RawMessage
}

func AppendEvents(ctx context.Context, db *sql.DB, streamID string, expectedVersion int64, events []EventRecord) error {
    tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
    if err != nil {
        return fmt.Errorf("failed to begin tx: %w", err)
    }
    defer tx.Rollback()

    stmt, err := tx.PrepareContext(ctx, `
        INSERT INTO event_store (stream_id, version, event_type, payload, metadata)
        VALUES ($1, $2, $3, $4, $5)
    `)
    if err != nil {
        return fmt.Errorf("failed to prepare insert: %w", err)
    }
    defer stmt.Close()

    currentVersion := expectedVersion
    for _, evt := range events {
        currentVersion++
        _, err = stmt.ExecContext(ctx, streamID, currentVersion, evt.EventType, evt.Payload, evt.Metadata)
        if err != nil {
            var pqErr *pq.Error
            if errors.As(err, &pqErr) && pqErr.Code == "23505" { // unique_violation
                return fmt.Errorf("%w: expected stream %s at version %d, but version %d already exists",
                    ErrConcurrencyConflict, streamID, expectedVersion, currentVersion)
            }
            return fmt.Errorf("failed to append event: %w", err)
        }
    }

    return tx.Commit()
}
```

---

## 4. Read Model Projections & Asynchronous Eventual Consistency
In CQRS, queries NEVER execute against the write-side aggregate or the raw event store table. The read side maintains dedicated, denormalized database tables (materialized views, Elasticsearch indexes, Redis caches) that are optimized for specific UI screens and reporting queries.

- ❌ **THE SYNCHRONOUS PROJECTION POLLUTION ANTI-PATTERN**:
  - Updating read models inside the same database transaction as the command handler. This reintroduces write-side lock contention, couples aggregate commits to slow reporting indexes, and destroys write throughput.
  - Making projection handlers non-idempotent. In distributed networks, events are delivered **at least once**. If re-projecting an event mutates read tables twice (e.g. `counter = counter + 1`), the read model drifts out of sync.
- ✅ **The Idempotent Projection Invariant**:
  - Every projection consumer MUST maintain a durable checkpoint of its last processed `global_position`.
  - Read-model upserts must be strictly idempotent using deterministic primary keys:
    ```sql
    -- Projection Checkpoint Registry
    CREATE TABLE projection_checkpoints (
        projection_name VARCHAR(128) PRIMARY KEY,
        last_global_position BIGINT NOT NULL DEFAULT 0,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
    );
    ```
- ✅ **Idempotent PostgreSQL Projection Worker**:

```sql
-- Read model: Denormalized orders overview
CREATE TABLE read_customer_orders (
    order_id VARCHAR(128) PRIMARY KEY,
    customer_id VARCHAR(128) NOT NULL,
    total_cents BIGINT NOT NULL,
    order_status VARCHAR(64) NOT NULL,
    last_event_version BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

-- Idempotent upsert handler for OrderSubmitted event:
INSERT INTO read_customer_orders (
    order_id, customer_id, total_cents, order_status, last_event_version, created_at, updated_at
) VALUES (
    :order_id, :customer_id, :total_cents, 'SUBMITTED', :version, :occurred_at, :occurred_at
)
ON CONFLICT (order_id) DO UPDATE SET
    order_status = EXCLUDED.order_status,
    last_event_version = EXCLUDED.last_event_version,
    updated_at = EXCLUDED.updated_at
WHERE read_customer_orders.last_event_version < EXCLUDED.last_event_version;
```

---

## 5. Aggregate Snapshotting & High-Volume Stream Performance
When an aggregate stream accumulates hundreds or thousands of events (e.g., long-lived bank accounts, IoT device telemetry, collaborative documents), replaying the stream from version 1 on every command introduces unacceptable CPU and latency penalties.

- ❌ **THE PERPETUAL REPLAY DISASTER**:
  - Replaying 10,000 events from the database to check a single `status == 'OPEN'` invariant before accepting an order.
  - Saving snapshots without version identifiers, causing partial state overrides.
- ✅ **The Snapshotting Strategy**:
  - Take a snapshot every **$N$ events** (e.g., every 100 events) or when replay exceeds a bounded duration (e.g., >20ms).
  - Persist the serialized aggregate state along with the exact `version` at which the snapshot was taken.
  - When loading the aggregate:
    1. Query the latest snapshot for `stream_id`.
    2. Query only events where `version > snapshot.version ORDER BY version ASC`.
    3. Rehydrate from the snapshot state, then replay only the subsequent delta events.

```sql
-- Production Snapshot Table
CREATE TABLE aggregate_snapshots (
    stream_id VARCHAR(128) PRIMARY KEY,
    aggregate_type VARCHAR(128) NOT NULL,
    version BIGINT NOT NULL,
    state_payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- Query delta events after snapshot:
-- Step 1: SELECT version, state_payload FROM aggregate_snapshots WHERE stream_id = :id;
-- Step 2:
SELECT version, event_type, payload 
FROM event_store 
WHERE stream_id = :id 
  AND version > :snapshot_version 
ORDER BY version ASC;
```

---

## 6. Event Schema Evolution, Versioning & Historical Upcasters
Because events are immutable and stored permanently, business requirements will inevitably evolve: fields will be renamed, split, or deprecated over time. 

- ❌ **THE HISTORICAL DATA MUTATION TRAP**:
  - Running `UPDATE event_store SET payload = ...` to alter historical events. This invalidates cryptographic audit signatures, corrupts event replication logs, and destroys historical truth.
  - Crashing client deserializers when encountering historical V1 events after deploying V2 code.
- ✅ **The Upcaster Transformation Pipeline**:
  - Retain historical events untouched in storage.
  - Implement an in-memory **Upcaster** that intercepts historical events upon deserialization and upgrades them through successive version increments ($V_1 \to V_2 \to V_3$) before the aggregate or projection handles them.

```typescript
// TypeScript: Production Event Upcaster Pipeline
export type RawStoredEvent = {
  eventType: string;
  schemaVersion: number;
  payload: Record<string, unknown>;
};

export type Upcaster = (event: RawStoredEvent) => RawStoredEvent;

export class UpcasterRegistry {
  private readonly upcasters = new Map<string, Map<number, Upcaster>>();

  public register(eventType: string, fromVersion: number, upcastFn: Upcaster): void {
    if (!this.upcasters.has(eventType)) {
      this.upcasters.set(eventType, new Map());
    }
    this.upcasters.get(eventType)!.set(fromVersion, upcastFn);
  }

  public upcastToLatest(raw: RawStoredEvent, targetVersion: number): RawStoredEvent {
    let current = { ...raw };
    const versionMap = this.upcasters.get(current.eventType);
    if (!versionMap) return current;

    while (current.schemaVersion < targetVersion) {
      const upcaster = versionMap.get(current.schemaVersion);
      if (!upcaster) {
        throw new Error(
          `Missing upcaster for ${current.eventType} from version ${current.schemaVersion} to ${current.schemaVersion + 1}`
        );
      }
      current = upcaster(current);
      current.schemaVersion++;
    }

    return current;
  }
}

// Example: Upcasting UserRegistered from V1 (fullName) to V2 (firstName + lastName)
const registry = new UpcasterRegistry();
registry.register('UserRegistered', 1, (v1Event) => {
  const [firstName, ...rest] = ((v1Event.payload.fullName as string) || '').split(' ');
  return {
    ...v1Event,
    payload: {
      userId: v1Event.payload.userId,
      firstName: firstName || '',
      lastName: rest.join(' ') || '',
      email: v1Event.payload.email,
    },
  };
});
```

---

## 7. Downstream Event Publishing: Transactional Outbox vs CDC
A frequent architectural flaw is attempting to publish events directly to an external message broker (Kafka, RabbitMQ, NATS) inside the aggregate command handler.

- ❌ **THE DUAL-WRITE DISASTER**:
  - Writing to the event store database and publishing to Kafka in the same block. If the database commit succeeds but the network drops before Kafka responds, the event is permanently lost from downstream systems. If Kafka succeeds but the database transaction rolls back, phantom events are distributed across the enterprise.
- ✅ **The CDC / Transactional Outbox Invariant**:
  - The Event Store **is** the ultimate source of truth.
  - Publish events downstream using either:
    1. **PostgreSQL Change Data Capture (CDC)**: Stream commits directly from the PostgreSQL Write-Ahead Log (WAL) using `test_decoding` or `pgoutput` via Debezium.
    2. **Transactional Outbox Table**: Write the domain event to both `event_store` and an `outbox` table within the **same local ACID transaction**, and let an asynchronous relay process drain the outbox to Kafka/RabbitMQ with at-least-once delivery guarantees.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Local Database Transaction                      │
│                                                                        │
│   BEGIN;                                                               │
│     1. INSERT INTO event_store (stream_id, version, payload, ...);     │
│     2. INSERT INTO outbox (event_id, destination_topic, payload, ...); │
│   COMMIT;                                                              │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Asynchronous Reliable Poller
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│   Outbox Worker ───▶ Kafka / RabbitMQ / NATS (At-Least-Once Delivery)  │
│   (Deletes or marks outbox row published upon publisher ACK)           │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 8. GDPR "Right to be Forgotten" & Cryptographic Shredding
The European Union GDPR (General Data Protection Regulation) mandates that individuals can demand the total erasure of their Personally Identifiable Information (PII). In a traditional database, this is an `UPDATE users SET name = 'DELETED'` or `DELETE FROM users`. In an append-only event-sourced system, physically deleting rows from `event_store` corrupts stream version sequence numbers, breaks deterministic rehydration, and invalidates cryptographic chain hashes.

- ❌ **THE EVENT LOG TAMPERING ANTI-PATTERN**:
  - Running destructive `DELETE` queries on the append-only event store to erase PII.
- ✅ **The Cryptographic Shredding (Crypto-Shredding) Invariant**:
  - Store all sensitive PII fields in event payloads **encrypted** with a dedicated, per-subject Data Encryption Key (DEK).
  - The DEKs are stored in an auxiliary, mutable key management table: `subject_encryption_keys`.
  - The aggregate and projections decrypt the PII at runtime using the subject's active DEK.
  - When the subject invokes their GDPR "Right to be Forgotten":
    1. Execute a physical delete or overwrite with cryptographic random noise on the subject's DEK in `subject_encryption_keys`.
    2. The historical event stream remains structurally intact (`stream_id`, `version`, `occurred_at`), but all historical PII becomes **mathematically irrecoverable ciphertext**.

```sql
-- Subject Encryption Key Storage for Crypto-Shredding
CREATE TABLE subject_encryption_keys (
    subject_id VARCHAR(128) PRIMARY KEY,
    key_ciphertext BYTEA NOT NULL,
    algorithm VARCHAR(32) NOT NULL DEFAULT 'AES-256-GCM',
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- When GDPR erasure request arrives:
-- Overwrite key with zeros and delete record to render all past events undecryptable:
UPDATE subject_encryption_keys 
SET key_ciphertext = '\x0000000000000000000000000000000000000000000000000000000000000000'
WHERE subject_id = :subject_id;

DELETE FROM subject_encryption_keys WHERE subject_id = :subject_id;
```

---

## 9. Cross-Aggregate Orchestration: Sagas vs Process Managers
When a business process spans multiple aggregate boundaries (e.g. an e-commerce checkout involving `OrderAggregate`, `PaymentAggregate`, and `InventoryAggregate`), aggregates must never invoke each other directly in synchronous database transactions.

- ❌ **THE DISTRIBUTED TWO-PHASE COMMIT ANTI-PATTERN**:
  - Locking multiple aggregate streams simultaneously in one mega-transaction. This causes severe distributed deadlocks and couples unrelated domain boundaries.
- ✅ **The Choreographed / Orchestrated Saga Pattern**:
  - Coordinate multi-aggregate transactions using event-driven compensation workflows:
    1. `OrderPlacedEvent` triggers `ReserveInventoryCommand`.
    2. If inventory succeeds $\to$ `InventoryReservedEvent` triggers `AuthorizePaymentCommand`.
    3. If inventory fails $\to$ `InventoryReservationFailedEvent` triggers `CancelOrderCommand` (Compensating Transaction).
  - Use a persistent **Process Manager** with its own state machine to track the saga's lifecycle, timeout deadlines, and compensation actions.
