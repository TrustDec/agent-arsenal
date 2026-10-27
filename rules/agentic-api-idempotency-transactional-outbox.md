---
description: Agentic API idempotency keys, transactional outbox pattern, exactly-once processing verification, cryptographic request fingerprinting, atomic lease reservation, lock-free deduplication, and replay cache envelopes across Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{idempotency,outbox,dedup,payment,mutation,webhook,consumer,event}*.*,**/api/**/*.{ts,js,py,go},**/services/**/*.{ts,js,py,go},**/routes/**/*.{ts,js,py,go},**/models/**/*.{ts,js,py,go}
alwaysApply: false
---

# Agentic API Idempotency, Transactional Outbox & Exactly-Once Processing Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design REST/gRPC mutation APIs, webhook ingestion engines, payment/billing workflows (Stripe, Adyen, PayPal), or distributed event consumers (Kafka, RabbitMQ, SQS). Eliminate the "Non-Idempotent Mutation Trap" (where network retries execute financial deductions or database mutations twice), the "Dual-Write State Corruption Anomaly" (where database commits succeed but external message publishing fails or phantom events leak), the "TOCTOU Race Condition & Unlocked Stampede" (where concurrent requests with the identical idempotency key bypass un-fenced checks), the "Cryptographic Payload Drift / Replay Poisoning Vulnerability" (where altered payloads hijack existing keys), and "Volatile State Amnesia" by establishing a strict 5-Tier Idempotency & Deduplication Ladder, mathematical idempotence calculus $f(f(x)) \equiv f(x)$, atomic lease reservations with fencing tokens, transactional outbox change data capture (CDC), and full-fidelity HTTP replay envelopes.

---

## 1. Architectural Taxonomy: The Double-Charge & Dual-Write Catastrophes vs The 5-Tier Idempotency Ladder

When autonomous agents are instructed to "implement a payment endpoint", "build a order checkout service", or "consume webhook events", LLMs naturally generate naive happy-path code. In distributed systems, this creates five catastrophic production failure modes:

- **The "Non-Idempotent Mutation" Trap (Double Charge Disaster)**:
  - LLM agents implement `POST /api/v1/orders` or `POST /api/v1/charges` without an `Idempotency-Key` contract.
  - When a transient network hiccup, reverse-proxy 504 timeout, or mobile client disconnect occurs after the database write, the upstream caller retries the request.
  - The server processes the retry as a brand-new mutation, decrementing customer balances twice, generating duplicate shipping orders, or charging a credit card multiple times.
- **The "Dual-Write State Corruption" Catastrophe**:
  - Unconstrained agents write code that performs a local database mutation and then immediately dispatches an external event:
    ```typescript
    // ❌ CATASTROPHIC DUAL-WRITE ANTI-PATTERN
    await db.orders.create({ data: order });
    await kafkaProducer.send({ topic: 'orders.created', message: order });
    ```
  - If the application worker crashes, runs out of memory (OOM), or experiences a network partition between lines 2 and 3, the database transaction is permanently committed, but the downstream event is lost forever.
  - Conversely, if the agent publishes the message inside the transaction block before commit and the transaction subsequently rolls back due to a constraint violation, phantom events pollute downstream consumers.
- **The "TOCTOU Race Condition & Unlocked Stampede"**:
  - Agents often attempt idempotency by writing a naive two-step check:
    ```typescript
    // ❌ VULNERABLE TIME-OF-CHECK TO TIME-OF-USE (TOCTOU)
    const existing = await db.idempotency.findUnique({ where: { key } });
    if (existing) return existing.response;
    // Window of vulnerability: concurrent identical requests pass here simultaneously!
    const result = await processPayment();
    await db.idempotency.create({ data: { key, response: result } });
    ```
  - Under client connection retries or rapid double-clicks, two concurrent HTTP requests arrive at separate worker pods within milliseconds. Both execute `findUnique()`, both find nothing, and both process payment concurrently.
- **The "Cryptographic Payload Drift / Replay Poisoning" Vulnerability**:
  - An agent accepts an `Idempotency-Key: idemp_123` on a request charging \$10.00.
  - A malicious or buggy client later sends another request with the same `Idempotency-Key: idemp_123` but modifies the payload to charge \$1,000.00 to a different recipient.
  - Without canonical cryptographic payload fingerprinting, the server either executes the altered mutation under the existing key, or returns the cached \$10.00 response, hiding fraudulent or corrupted intent.
- **The "Volatile State Amnesia & Deadlock Trap"**:
  - Agents store idempotency locks in ephemeral in-memory Maps or Redis keys without leases (TTL) or fencing tokens.
  - If a worker node crashes mid-execution while holding the lock, the idempotency key remains permanently trapped in `IN_PROGRESS`, locking out all future legitimate client retries.
- **The 5-Tier Idempotency & Deduplication Ladder**:
  - Autonomous agents must strictly adhere to 5 ascending architectural tiers to guarantee distributed safety:
    - **Tier 0: Cryptographic Request Fingerprinting**: Calculating canonical SHA-256 hashes ($H_{\text{req}}$) over HTTP method, normalized route, sorted query parameters, and RFC 8785 canonicalized JSON payloads.
    - **Tier 1: Atomic Lease Reservation & Fencing Locks**: Reserving the key atomically in PostgreSQL (`INSERT INTO idempotency_keys ... ON CONFLICT DO NOTHING`) or distributed Redis (`SET key NX PX <ttl>`) before executing domain logic. Concurrent identical requests receive `409 Conflict` with `Retry-After`.
    - **Tier 2: Transactional Outbox Pattern & CDC Invariance**: Enclosing domain state mutations and outbound event records within the **same single atomic database transaction** ($\mathbb{P}(\text{DB} \oplus \text{Outbox}) \equiv 0$). Asynchronous relays (Debezium CDC or background pollers with `SKIP LOCKED`) dispatch events to message brokers with at-least-once guarantees.
    - **Tier 3: Protocol-Level Replay Enveloping**: Storing complete HTTP execution outcomes (status code, headers like `ETag`/`Content-Type`, and exact body payload). Replayed responses return within $<5\text{ms}$ with the standard header `Idempotency-Replayed: true`.
    - **Tier 4: Consumer-Side Deduplication Gateways**: Asynchronous message consumers maintain persistent deduplication registries with sliding deduplication windows to filter duplicate events generated by at-least-once message brokers.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Autonomous Agent Generates Mutation API (POST/PUT/PATCH) or Webhook Consumer                     │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: Dual-Write & Non-Idempotent Mutation]                            ▼ [PRODUCTION: 5-Tier Idempotency Ladder]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ • No Idempotency-Key or naive in-memory check   │               │ Tier 0: RFC 8785 Canonical Cryptographic Hash   │
│ • TOCTOU race allows concurrent double charge   │               │ • SHA-256(Method + Path + SortedPayload)        │
│ • DB insert followed by kafka.publish()         │               ├─────────────────────────────────────────────────┤
│ • Crash between steps creates permanent drift   │               │ Tier 1: Atomic Lease Reservation (ON CONFLICT)  │
│ • Reused key with altered body returns wrong data│               │ • Returns 409 Conflict + Retry-After on lock    │
│ • Worker crash leaves key locked indefinitely   │               ├─────────────────────────────────────────────────┤
└─────────────────────────────────────────────────┘               │ Tier 2: Transactional Outbox (Same DB Tx)       │
                                                                  │ • Mutate Domain Model + Insert Outbox Event     │
                                                                  │ • Relayed via CDC / SKIP LOCKED worker          │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 3: Complete HTTP Replay Envelope           │
                                                                  │ • Caches Status, ETag, Headers, Body            │
                                                                  │ • Returns Idempotency-Replayed: true (<5ms)     │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 4: Consumer Deduplication Registry         │
                                                                  │ • Sliding window dedup filters broker repeats   │
                                                                  └─────────────────────────────────────────────────┘
```

---

## 2. Mathematical Formulations & Idempotency Invariance Calculus

To mathematically eliminate duplicate side-effects and payload tampering, autonomous agents must formulate idempotency operations through verifiable invariant calculus.

### 2.1 The Mathematical Idempotence Axiom

Let $f: \mathcal{S} \times \mathcal{R} \to \mathcal{S} \times \mathcal{O}$ be a state transition function where $\mathcal{S}$ represents the system state, $\mathcal{R}$ is the client request, and $\mathcal{O}$ is the emitted outcome. Under idempotency key $k$:

$$f(f(s, r_k), r_k) \equiv f(s, r_k)$$

Repeated executions with identical key $k$ and identical request $r_k$ MUST NOT alter system state $\mathcal{S}$ beyond the initial transition, and MUST return identical outcome $\mathcal{O}$.

### 2.2 Canonical Cryptographic Fingerprint ($H_{\text{req}}$)

To prevent replay tampering while allowing legitimate whitespace variations in JSON payloads, the request fingerprint $H_{\text{req}}$ is formulated using RFC 8785 Canonical JSON Formatting (JCS):

$$H_{\text{req}} = \text{SHA256}\Big(\text{Method} \;\Vert\; \text{Path} \;\Vert\; \text{Sort}(\text{QueryParams}) \;\Vert\; \text{JCS}(\text{Body})\Big)$$

Where:
- $\Vert$ represents byte concatenation with a zero-byte delimiter `\x00`.
- $\text{JCS}(\text{Body})$ deterministically sorts all JSON dictionary keys lexicographically and normalizes floating-point representations.

### 2.3 Payload Drift Sentinel ($D_{\text{payload}}$)

When a client transmits an existing idempotency key $k$ with request fingerprint $H_{\text{new}}$, the system evaluates divergence against the stored fingerprint $H_{\text{stored}}$:

$$D_{\text{payload}}(k) = \begin{cases} 
0 & \text{if } H_{\text{new}} = H_{\text{stored}} \implies \text{Proceed to Replay / Await Completion} \\ 
1 & \text{if } H_{\text{new}} \neq H_{\text{stored}} \implies \text{FATAL: Abort with 422 Unprocessable / 409 Conflict}
\end{cases}$$

**Production Invariant**: If $D_{\text{payload}}(k) = 1$, the agent MUST immediately abort execution and return RFC 7807 problem details:
$$\text{Status} = 422 \quad \text{or} \quad 409, \quad \text{Detail} = \text{"Idempotency key payload mismatch"}$$

### 2.4 Atomic Lease Expiration & Fencing Token Invariant

To guarantee that stalled or crashed workers do not lock out keys permanently:

$$\tau_{\text{lease}} = t_{\text{locked}} + \Delta t_{\text{timeout}}, \quad \Delta t_{\text{timeout}} \in [30\text{s}, 120\text{s}]$$

If current time $t_{\text{now}} > \tau_{\text{lease}}$ and status remains `STARTED`, the reservation is expired and eligible for reclamation with monotonically increasing fencing token $\theta_{\text{fence}}$:

$$\theta_{\text{fence}}^{(n+1)} = \theta_{\text{fence}}^{(n)} + 1$$

Any delayed write attempt bearing an outdated fencing token $\theta < \theta_{\text{current}}$ is rejected by the database storage engine.

### 2.5 Transactional Outbox Atomicity Equation

Let $E_{\text{mutation}}$ be the write to business domain tables and $E_{\text{outbox}}$ be the write to the `outbox_events` table:

$$\mathbb{P}\Big((E_{\text{mutation}} \land \neg E_{\text{outbox}}) \lor (\neg E_{\text{mutation}} \land E_{\text{outbox}})\Big) \equiv 0$$

Both events commit or rollback as an indivisible atomic unit in PostgreSQL / MySQL transactional engines.

---

## 3. The 4 Golden Rules of Idempotency & Outbox Discipline

Autonomous agents must strictly abide by four invariant rules when implementing stateful mutations:

### Rule 1: Never Separate State Mutation from Outbox Dispatch (Mandatory Single DB Transaction)
- ❌ **Prohibited**: Invoking `kafkaProducer.send()`, `sns.publish()`, `sqs.sendMessage()`, or external webhooks inside or immediately after application business logic without an outbox table.
- ✅ **Mandatory**: Both domain data and outbox messages MUST be inserted in the **same database transaction**. An asynchronous outbox processor with `FOR UPDATE SKIP LOCKED` or a Change Data Capture (CDC) engine (e.g. Debezium) relays events to the broker.

### Rule 2: Atomic Reservation Prior to Mutation Execution (Zero TOCTOU Window)
- ❌ **Prohibited**: Checking idempotency with `SELECT` followed by conditional application logic and subsequent `INSERT`.
- ✅ **Mandatory**: Use an atomic reservation primitives (`INSERT INTO idempotency_keys ... ON CONFLICT (key) DO NOTHING RETURNING id` or Redis `SET key NX PX`). If the row is not inserted, check whether the previous execution is `COMPLETED` (replay) or `STARTED` (return `409 Conflict` with `Retry-After: 2`).

### Rule 3: Reject Payload Mutation Drift on Identical Keys with 422/409 (Anti-Tampering)
- ❌ **Prohibited**: Ignoring request body changes when an existing idempotency key is presented, or blindly re-executing mutations with different parameters.
- ✅ **Mandatory**: Verify $H_{\text{req}}$. If the hash differs from the stored record, immediately reject the request without executing any business code.

### Rule 4: Replay Complete HTTP Envelopes, Never Raw Partial Data
- ❌ **Prohibited**: Caching only the raw JSON body and returning a generic `200 OK` on replay, discarding original status codes (`201 Created`, `202 Accepted`) and response headers (`Location`, `ETag`).
- ✅ **Mandatory**: Store the complete HTTP response envelope (`status_code`, `headers`, `body`). Replay requests with the exact original status code and inject the header `Idempotency-Replayed: true`.

---

## 4. Production Database Schemas: PostgreSQL Idempotency & Transactional Outbox

Autonomous agents generating PostgreSQL migrations for idempotency and outbox systems must use the following production-hardened schemas:

```sql
-- migration_idempotency_and_outbox.sql
-- Production Idempotency Keys and Transactional Outbox Architecture

CREATE TYPE idempotency_status AS ENUM ('STARTED', 'COMPLETED', 'FAILED');

-- 1. Idempotency Keys Table
CREATE TABLE IF NOT EXISTS idempotency_keys (
    key VARCHAR(255) PRIMARY KEY,
    user_id VARCHAR(128) NOT NULL,
    request_method VARCHAR(16) NOT NULL,
    request_path VARCHAR(512) NOT NULL,
    request_hash CHAR(64) NOT NULL, -- SHA-256 canonical hex digest
    status idempotency_status NOT NULL DEFAULT 'STARTED',
    
    -- HTTP Replay Envelope
    response_status_code SMALLINT NULL,
    response_headers JSONB NULL,
    response_body JSONB NULL,
    
    -- Concurrency & Lease Fencing
    fence_token BIGINT NOT NULL DEFAULT 1,
    lease_expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Fast lookup for user-scoped idempotency audits & cleanup
CREATE INDEX IF NOT EXISTS idx_idempotency_user_created 
    ON idempotency_keys (user_id, created_at DESC);

-- Fast index for expired lease reclamation
CREATE INDEX IF NOT EXISTS idx_idempotency_lease_cleanup 
    ON idempotency_keys (status, lease_expires_at) 
    WHERE status = 'STARTED';

-- 2. Transactional Outbox Table
CREATE TABLE IF NOT EXISTS outbox_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type VARCHAR(128) NOT NULL,
    aggregate_id VARCHAR(128) NOT NULL,
    event_type VARCHAR(128) NOT NULL,
    payload JSONB NOT NULL,
    headers JSONB NOT NULL DEFAULT '{}'::jsonb,
    
    -- Dispatch Tracking
    published_at TIMESTAMPTZ NULL,
    retry_count INT NOT NULL DEFAULT 0,
    last_error TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for lock-free outbox worker polling using SKIP LOCKED
CREATE INDEX IF NOT EXISTS idx_outbox_unprocessed 
    ON outbox_events (created_at ASC) 
    WHERE published_at IS NULL;
```

---

## 5. Production Reference Implementation: `AgenticIdempotencyVerificationEngine`

The following TypeScript engine provides a complete, production-ready idempotency, request fingerprinting, and transactional outbox verification harness. It includes RFC 8785 canonical JSON hashing, atomic reservation simulation, payload mismatch detection, outbox queuing, and cached response replaying.

```typescript
// agentic-idempotency-engine.ts
// Production Reference Implementation for Agentic Idempotency & Transactional Outbox

import * as crypto from 'crypto';

export type IdempotencyStatus = 'STARTED' | 'COMPLETED' | 'FAILED';

export interface HttpResponseEnvelope {
  statusCode: number;
  headers: Record<string, string>;
  body: unknown;
}

export interface IdempotencyRecord {
  key: string;
  userId: string;
  requestMethod: string;
  requestPath: string;
  requestHash: string;
  status: IdempotencyStatus;
  response?: HttpResponseEnvelope;
  fenceToken: number;
  leaseExpiresAt: number; // Unix timestamp ms
  createdAt: number;
  updatedAt: number;
}

export interface OutboxEvent {
  id: string;
  aggregateType: string;
  aggregateId: string;
  eventType: string;
  payload: Record<string, unknown>;
  headers: Record<string, string>;
  publishedAt: number | null;
  retryCount: number;
  createdAt: number;
}

export interface ReservationResult {
  action: 'PROCEED' | 'REPLAY' | 'CONFLICT_LOCKED' | 'PAYLOAD_MISMATCH';
  replayedResponse?: HttpResponseEnvelope;
  retryAfterSeconds?: number;
  errorMessage?: string;
  fenceToken?: number;
}

export class AgenticIdempotencyVerificationEngine {
  private idempotencyStore: Map<string, IdempotencyRecord> = new Map();
  private outboxStore: Map<string, OutboxEvent> = new Map();
  private defaultLeaseDurationMs: number;

  constructor(defaultLeaseDurationMs = 60000) {
    this.defaultLeaseDurationMs = defaultLeaseDurationMs;
  }

  /**
   * RFC 8785 Canonical JSON Stringifier.
   * Deterministically sorts all object keys recursively to ensure identical hashes.
   */
  public canonicalizeJson(obj: unknown): string {
    if (obj === null || typeof obj !== 'object') {
      return JSON.stringify(obj);
    }

    if (Array.isArray(obj)) {
      return '[' + obj.map((item) => this.canonicalizeJson(item)).join(',') + ']';
    }

    const sortedKeys = Object.keys(obj as Record<string, unknown>).sort();
    const pairs = sortedKeys.map((key) => {
      const val = (obj as Record<string, unknown>)[key];
      return JSON.stringify(key) + ':' + this.canonicalizeJson(val);
    });

    return '{' + pairs.join(',') + '}';
  }

  /**
   * Compute deterministic SHA-256 request fingerprint:
   * H_req = SHA256(Method + '\x00' + Path + '\x00' + CanonicalBody)
   */
  public computeRequestFingerprint(method: string, path: string, body: unknown): string {
    const canonicalBody = this.canonicalizeJson(body ?? {});
    const payload = `${method.toUpperCase()}\x00${path.toLowerCase()}\x00${canonicalBody}`;
    return crypto.createHash('sha256').update(payload, 'utf8').digest('hex');
  }

  /**
   * Atomic Reservation Phase:
   * Attempts to reserve the idempotency key. Handles concurrent stampedes, expired leases,
   * payload drift detection, and cached response replay.
   */
  public reserveKey(
    key: string,
    userId: string,
    method: string,
    path: string,
    body: unknown
  ): ReservationResult {
    const now = Date.now();
    const requestHash = this.computeRequestFingerprint(method, path, body);
    const existing = this.idempotencyStore.get(key);

    if (existing) {
      // 1. Verify User Ownership
      if (existing.userId !== userId) {
        return {
          action: 'PAYLOAD_MISMATCH',
          errorMessage: 'Idempotency key does not belong to the authenticated user.',
        };
      }

      // 2. Verify Cryptographic Request Fingerprint (Anti-Tampering)
      if (existing.requestHash !== requestHash) {
        return {
          action: 'PAYLOAD_MISMATCH',
          errorMessage: `Idempotency key '${key}' was previously used with a different request payload.`,
        };
      }

      // 3. Completed State: Replay Cached Response Envelope
      if (existing.status === 'COMPLETED' && existing.response) {
        return {
          action: 'REPLAY',
          replayedResponse: {
            ...existing.response,
            headers: {
              ...existing.response.headers,
              'Idempotency-Replayed': 'true',
            },
          },
        };
      }

      // 4. In-Progress State: Check Lease Expiry
      if (existing.status === 'STARTED') {
        if (now < existing.leaseExpiresAt) {
          // Lock still valid: report concurrency conflict with Retry-After
          const remainingSec = Math.max(1, Math.ceil((existing.leaseExpiresAt - now) / 1000));
          return {
            action: 'CONFLICT_LOCKED',
            retryAfterSeconds: remainingSec,
            errorMessage: 'A concurrent request with this idempotency key is currently being processed.',
          };
        }

        // Lease expired! Reclaim lock with incremented fencing token
        existing.fenceToken += 1;
        existing.leaseExpiresAt = now + this.defaultLeaseDurationMs;
        existing.updatedAt = now;
        return {
          action: 'PROCEED',
          fenceToken: existing.fenceToken,
        };
      }
    }

    // 5. First-time Key Reservation: Atomically insert record
    const newRecord: IdempotencyRecord = {
      key,
      userId,
      requestMethod: method.toUpperCase(),
      requestPath: path.toLowerCase(),
      requestHash,
      status: 'STARTED',
      fenceToken: 1,
      leaseExpiresAt: now + this.defaultLeaseDurationMs,
      createdAt: now,
      updatedAt: now,
    };

    this.idempotencyStore.set(key, newRecord);
    return {
      action: 'PROCEED',
      fenceToken: 1,
    };
  }

  /**
   * Transactional Outbox Atomic Commit:
   * Commits the business response envelope and enqueues an outbox event atomically.
   */
  public commitSuccess(
    key: string,
    fenceToken: number,
    response: HttpResponseEnvelope,
    outboxEventData?: {
      aggregateType: string;
      aggregateId: string;
      eventType: string;
      payload: Record<string, unknown>;
    }
  ): void {
    const record = this.idempotencyStore.get(key);
    if (!record) {
      throw new Error(`Idempotency record '${key}' not found during commit.`);
    }

    // Fencing check: abort if lease was reclaimed by another worker
    if (record.fenceToken !== fenceToken) {
      throw new Error(
        `Fencing token mismatch for key '${key}'. Expected ${record.fenceToken}, got ${fenceToken}. Worker aborted.`
      );
    }

    const now = Date.now();
    record.status = 'COMPLETED';
    record.response = response;
    record.updatedAt = now;

    // Insert outbox event in the same atomic logical unit
    if (outboxEventData) {
      const eventId = crypto.randomUUID();
      const outboxEvent: OutboxEvent = {
        id: eventId,
        aggregateType: outboxEventData.aggregateType,
        aggregateId: outboxEventData.aggregateId,
        eventType: outboxEventData.eventType,
        payload: outboxEventData.payload,
        headers: { 'idempotency-key': key },
        publishedAt: null,
        retryCount: 0,
        createdAt: now,
      };
      this.outboxStore.set(eventId, outboxEvent);
    }
  }

  /**
   * Mark execution as failed, releasing the reservation for immediate client retry.
   */
  public markFailed(key: string, fenceToken: number, errorDetail: string): void {
    const record = this.idempotencyStore.get(key);
    if (record && record.fenceToken === fenceToken) {
      record.status = 'FAILED';
      record.response = {
        statusCode: 500,
        headers: { 'Content-Type': 'application/json' },
        body: { error: errorDetail },
      };
      record.leaseExpiresAt = 0; // Immediate release
      record.updatedAt = Date.now();
    }
  }

  /**
   * Outbox Poller Simulation using SKIP LOCKED semantics.
   */
  public pollUnpublishedOutboxEvents(batchSize = 10): OutboxEvent[] {
    const pending: OutboxEvent[] = [];
    for (const event of this.outboxStore.values()) {
      if (event.publishedAt === null) {
        pending.push(event);
        if (pending.length >= batchSize) break;
      }
    }
    return pending;
  }

  /**
   * Acknowledge outbox event publication to broker.
   */
  public acknowledgeEventPublished(eventId: string): void {
    const event = this.outboxStore.get(eventId);
    if (event) {
      event.publishedAt = Date.now();
    }
  }
}
```

---

## 6. The 6-State Idempotency & Outbox Lifecycle Finite-State Machine (FSM)

Autonomous agents implementing or verifying mutation handlers must strictly follow the 6-state lifecycle state machine:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ The 6-State Idempotency & Outbox Lifecycle Finite-State Machine                                  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘

   [STATE 0: KEY_EXTRACTION_AND_FINGERPRINT]
          │ Extract Idempotency-Key header; compute RFC 8785 SHA-256 fingerprint H_req
          ▼
   [STATE 1: ATOMIC_KEY_RESERVATION]
          │ Execute INSERT ON CONFLICT DO NOTHING with lease expiration tau_lease
          ├── [Existing key with H_req mismatch] ──► [STATE 5: PAYLOAD_DRIFT_REJECT] (422 Unprocessable)
          ├── [Existing key in STARTED & unexpired] ──► [STATE 5: CONFLICT_LOCKED_REJECT] (409 Conflict)
          ├── [Existing key in COMPLETED] ──────────► [STATE 4: IDEMPOTENT_REPLAY] (Return cached envelope)
          ▼ [Reservation Acquired (Action: PROCEED)]
   [STATE 2: TRANSACTIONAL_MUTATION_AND_OUTBOX_WRITE]
          │ Execute business logic + insert outbox_events in single atomic DB transaction
          ├── [Database Transaction Rollback] ─────► [STATE 1b: RELEASE_LEASE_ON_FAILURE]
          ▼ [Transaction Successfully Committed]
   [STATE 3: ENVELOPE_PERSISTENCE_AND_LOCK_RELEASE]
          │ Update idempotency record to COMPLETED; persist status, headers, body envelope
          ▼
   [STATE 4: IDEMPOTENT_REPLAY_DISPATCH]
          │ Return response to client; outbox worker asynchronously relays events to broker
```

1. **State 0: KEY_EXTRACTION_AND_FINGERPRINT**: The server extracts the `Idempotency-Key` HTTP header. If absent on a state-altering mutation (`POST`, `PATCH`), the server returns `400 Bad Request` (Missing Idempotency-Key). It computes the RFC 8785 canonical SHA-256 request fingerprint $H_{\text{req}}$.
2. **State 1: ATOMIC_KEY_RESERVATION**: An atomic reservation is attempted via SQL `INSERT ... ON CONFLICT DO NOTHING` or Redis `SET NX PX`.
3. **State 2: TRANSACTIONAL_MUTATION_AND_OUTBOX_WRITE**: If the lease is acquired, business operations and outbound event records are committed within the **same atomic database transaction**.
4. **State 3: ENVELOPE_PERSISTENCE_AND_LOCK_RELEASE**: The server stores the HTTP status code, selected response headers, and response body inside the idempotency record, transitioning status to `COMPLETED`.
5. **State 4: IDEMPOTENT_REPLAY_DISPATCH**: When a completed key is presented, the server short-circuits execution, replaying the stored envelope in $<5\text{ms}$ with `Idempotency-Replayed: true`.
6. **State 5: PAYLOAD_DRIFT_OR_CONFLICT_REJECT**: If the key was previously used with a different request payload, execution aborts with `422 Unprocessable Entity`. If a concurrent request is currently holding the active lease, the server returns `409 Conflict` with `Retry-After: 2`.

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

Before any mutation API, payment integration, or webhook consumer is merged, it must satisfy all 6 machine-verifiable gates:

| Gate | Verification Dimension | Target Threshold / Invariant | Validation Command |
|---|---|---|---|
| **Gate 1** | **Mathematical Idempotency** | $f(f(x)) \equiv f(x)$; identical response on repeat calls | Automated test executing 5 sequential identical requests; verifies balance mutated exactly once |
| **Gate 2** | **Concurrent Stampede Safety** | 0 race conditions under parallel requests ($N=10$) | High-concurrency test (`Promise.all` or `go test -parallel 10`); exactly 1 returns 200/201, 9 return 409 or replay |
| **Gate 3** | **Payload Tampering Rejection** | $D_{\text{payload}} \equiv 1 \implies \text{Status} \in \{409, 422\}$ | Test mutating 1 field with identical key; verifies immediate rejection without side effects |
| **Gate 4** | **Transactional Outbox Parity** | $\mathbb{P}(\text{DB} \oplus \text{Outbox}) \equiv 0$; zero dual-write anomalies | Failure injection test killing worker mid-transaction; verifies zero orphaned outbox events |
| **Gate 5** | **Complete Replay Fidelity** | Replay matches original status code and body; includes `Idempotency-Replayed: true` | Contract test asserting header existence and status code equality on 2nd invocation |
| **Gate 6** | **Lease Expiry Reclamation** | Stalled keys in `STARTED` reclaimable after $\Delta t_{\text{timeout}}$ | Test simulating hung worker ($t > \tau_{\text{lease}}$); verifies second worker successfully acquires key |

---

## 8. Stack-Specific Implementation Guides & Production Recipes

### 8.1 Go: PostgreSQL `pgx` with Atomic Upsert & Transactional Outbox

In Go microservices, enforce atomic key reservation and the transactional outbox pattern using PostgreSQL and `github.com/jackc/pgx/v5`:

```go
package payment

import (
    "context"
    "crypto/sha256"
    "encoding/hex"
    "encoding/json"
    "errors"
    "fmt"
    "net/http"
    "time"

    "github.com/jackc/pgx/v5"
    "github.com/jackc/pgx/v5/pgxpool"
)

type PaymentService struct {
    db *pgxpool.Pool
}

func (s *PaymentService) ChargeCustomer(
    ctx context.Context,
    idempotencyKey string,
    userID string,
    amountCents int64,
) (*http.Response, error) {
    // 1. Calculate canonical request hash
    hashPayload := fmt.Sprintf("POST\x00/api/v1/charges\x00%s\x00%d", userID, amountCents)
    hashBytes := sha256.Sum256([]byte(hashPayload))
    requestHash := hex.EncodeToString(hashBytes[:])

    tx, err := s.db.Begin(ctx)
    if err != nil {
        return nil, err
    }
    defer tx.Rollback(ctx)

    // 2. Atomic Reservation via INSERT ON CONFLICT DO NOTHING
    query := `
        INSERT INTO idempotency_keys (
            key, user_id, request_method, request_path, request_hash, status, lease_expires_at
        ) VALUES ($1, $2, 'POST', '/api/v1/charges', $3, 'STARTED', NOW() + INTERVAL '60 seconds')
        ON CONFLICT (key) DO NOTHING
        RETURNING key;
    `
    var reservedKey string
    err = tx.QueryRow(ctx, query, idempotencyKey, userID, requestHash).Scan(&reservedKey)

    if errors.Is(err, pgx.ErrNoRows) {
        // Key already exists: check stored record
        var storedHash, status string
        var respBody []byte
        var statusCode int
        selectQuery := `
            SELECT request_hash, status, response_body, response_status_code 
            FROM idempotency_keys WHERE key = $1;
        `
        err = tx.QueryRow(ctx, selectQuery, idempotencyKey).Scan(&storedHash, &status, &respBody, &statusCode)
        if err != nil {
            return nil, err
        }

        // Anti-Tampering Check
        if storedHash != requestHash {
            return nil, fmt.Errorf("HTTP 422: Idempotency key payload mismatch")
        }

        if status == "COMPLETED" {
            // Replay response envelope
            return &http.Response{
                StatusCode: statusCode,
                Header:     http.Header{"Idempotency-Replayed": []string{"true"}},
            }, nil
        }

        return nil, fmt.Errorf("HTTP 409: Concurrent request in progress. Retry-After: 2")
    } else if err != nil {
        return nil, err
    }

    // 3. Business State Mutation: Deduct customer balance
    balanceUpdate := `UPDATE accounts SET balance_cents = balance_cents - $1 WHERE id = $2;`
    if _, err = tx.Exec(ctx, balanceUpdate, amountCents, userID); err != nil {
        return nil, err
    }

    // 4. Transactional Outbox: Insert event in SAME transaction
    outboxQuery := `
        INSERT INTO outbox_events (aggregate_type, aggregate_id, event_type, payload)
        VALUES ('Account', $1, 'AccountDebited', $2);
    `
    eventPayload, _ := json.Marshal(map[string]any{"amount": amountCents, "user_id": userID})
    if _, err = tx.Exec(ctx, outboxQuery, userID, eventPayload); err != nil {
        return nil, err
    }

    // 5. Update Idempotency Record to COMPLETED
    commitEnvelopeQuery := `
        UPDATE idempotency_keys 
        SET status = 'COMPLETED', response_status_code = 201, response_body = $1, updated_at = NOW()
        WHERE key = $2;
    `
    successBody, _ := json.Marshal(map[string]string{"status": "charged", "idempotency_key": idempotencyKey})
    if _, err = tx.Exec(ctx, commitEnvelopeQuery, successBody, idempotencyKey); err != nil {
        return nil, err
    }

    // Atomic Commit: Domain update + Outbox + Idempotency all succeed together!
    if err := tx.Commit(ctx); err != nil {
        return nil, err
    }

    return &http.Response{StatusCode: http.StatusCreated}, nil
}
```

### 8.2 TypeScript / Node.js: Express Middleware with Transactional Outbox

```typescript
// middleware/idempotency.ts
import { Request, Response, NextFunction } from 'express';
import { AgenticIdempotencyVerificationEngine } from './agentic-idempotency-engine';

const engine = new AgenticIdempotencyVerificationEngine(60000);

export function idempotencyMiddleware(req: Request, res: Response, next: NextFunction) {
  // Only state-altering mutation endpoints require Idempotency-Key
  if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) {
    return next();
  }

  const key = req.header('Idempotency-Key');
  if (!key) {
    return res.status(400).json({ error: 'Missing required header: Idempotency-Key' });
  }

  const userId = (req as any).user?.id || 'anonymous';
  const result = engine.reserveKey(key, userId, req.method, req.path, req.body);

  if (result.action === 'PAYLOAD_MISMATCH') {
    return res.status(422).json({ error: result.errorMessage });
  }

  if (result.action === 'CONFLICT_LOCKED') {
    res.setHeader('Retry-After', result.retryAfterSeconds?.toString() || '2');
    return res.status(409).json({ error: result.errorMessage });
  }

  if (result.action === 'REPLAY' && result.replayedResponse) {
    for (const [hKey, hVal] of Object.entries(result.replayedResponse.headers)) {
      res.setHeader(hKey, hVal);
    }
    return res.status(result.replayedResponse.statusCode).json(result.replayedResponse.body);
  }

  // Intercept response to store complete HTTP envelope
  const originalJson = res.json.bind(res);
  res.json = (body: unknown) => {
    engine.commitSuccess(
      key,
      result.fenceToken || 1,
      {
        statusCode: res.statusCode,
        headers: { 'content-type': 'application/json' },
        body,
      },
      {
        aggregateType: 'Order',
        aggregateId: (body as any)?.id || key,
        eventType: 'OrderCreated',
        payload: req.body,
      }
    );
    return originalJson(body);
  };

  next();
}
```

### 8.3 Python / FastAPI: Transactional Outbox Dependency with SQLAlchemy

```python
# dependencies/idempotency.py
import hashlib
import json
from fastapi import Header, HTTPException, Depends, status
from sqlalchemy.orm import Session
from sqlalchemy import text
from datetime import datetime, timedelta

def get_idempotency_key(
    idempotency_key: str = Header(..., alias="Idempotency-Key"),
    db: Session = Depends(get_db_session)
):
    return idempotency_key

def reserve_idempotency_lease(
    key: str,
    method: str,
    path: str,
    body: dict,
    user_id: str,
    db: Session
):
    # RFC 8785 Canonical JSON hashing
    canonical_body = json.dumps(body, sort_keys=True, separators=(',', ':'))
    raw_fingerprint = f"{method.upper()}\x00{path.lower()}\x00{canonical_body}"
    request_hash = hashlib.sha256(raw_fingerprint.encode("utf-8")).hexdigest()

    # PostgreSQL Atomic Upsert
    query = text("""
        INSERT INTO idempotency_keys (key, user_id, request_method, request_path, request_hash, status, lease_expires_at)
        VALUES (:key, :user_id, :method, :path, :hash, 'STARTED', NOW() + INTERVAL '60 seconds')
        ON CONFLICT (key) DO NOTHING
        RETURNING key;
    """)
    result = db.execute(query, {
        "key": key, "user_id": user_id, "method": method, "path": path, "hash": request_hash
    }).fetchone()

    if not result:
        # Check existing record
        row = db.execute(
            text("SELECT request_hash, status, response_body, response_status_code FROM idempotency_keys WHERE key = :key"),
            {"key": key}
        ).fetchone()

        if row.request_hash != request_hash:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Idempotency key payload mismatch"
            )

        if row.status == "COMPLETED":
            return {"action": "REPLAY", "status_code": row.response_status_code, "body": row.response_body}

        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Concurrent request currently processing. Retry shortly.",
            headers={"Retry-After": "2"}
        )

    return {"action": "PROCEED", "request_hash": request_hash}
```
