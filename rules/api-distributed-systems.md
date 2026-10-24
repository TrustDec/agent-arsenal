---
description: Distributed systems resilience, idempotency contracts, gRPC/REST error discipline, circuit breakers, and OpenTelemetry observability
globs: **/*.{go,ts,js,py,rs,java,proto},**/api/**,**/controllers/**,**/services/**,**/routes/**
alwaysApply: false
---

# Resilient API Design & Distributed Systems Invariants

> Add these rules to your project if developing distributed microservices, REST/gRPC APIs, event-driven backends, or third-party webhook integrations.

## 1. Idempotency & Safe Mutation Contracts
- **Mandatory `Idempotency-Key` for Non-Idempotent Mutations**:
  - All state-altering operations (`POST`, `PATCH`, payments, refunds, resource provisioning) MUST accept and enforce an `Idempotency-Key` header.
- **Atomic Key Reservation Workflow**:
  - Step 1: Check and atomically reserve the idempotency key in a fast distributed store (e.g. Redis `SET key in_progress NX PX 120000` or PostgreSQL `INSERT INTO idempotency_keys ... ON CONFLICT DO NOTHING`).
  - Step 2: If reservation fails and status is `in_progress`, return `409 Conflict` with a `Retry-After: 1` header, or wait up to a bounded lock timeout.
  - Step 3: If status is `completed`, return the cached response with header `Idempotency-Replayed: true` without re-executing business logic.
- **Payload Hash Mismatch Protection**:
  - Store a SHA-256 checksum of the request body alongside the idempotency key.
  - If the client reuses the same `Idempotency-Key` with a divergent request payload, immediately reject with `422 Unprocessable Entity` or `409 Conflict` (Idempotency Key Payload Mismatch). Never execute operations against mismatched payloads.
- **Safe State Release on Fatal Failure**:
  - If execution fails due to a transient infrastructure error before business mutation commits, release the reservation key so the client can safely retry.

## 2. Fault Tolerance: Backoff, Jitter & Circuit Breakers
- ❌ **ABSOLUTE BAN ON NAIVE RETRIES**:
  - Retrying immediately in a tight loop or on a fixed timer causes **Retry Storms** (Thundering Herd) that prevent recovering systems from healing.
- **Full Jitter Exponential Backoff**:
  - All automated retries MUST incorporate exponential backoff with full jitter:
    ```
    sleep = random(0, min(max_backoff, base_backoff * (2 ^ attempt)))
    ```
- **Strict Retry Classification**:
  - ❌ **NEVER retry 4xx client errors** (`400 Bad Request`, `401 Unauthorized`, `403 Forbidden`, `404 Not Found`, `422 Unprocessable Entity`). Client errors will never succeed without modifying the request.
  - Only retry transient network drops, connection resets, and transient 5xx codes (`502 Bad Gateway`, `503 Service Unavailable`, `504 Gateway Timeout`, or `429 Too Many Requests` respecting `Retry-After`).
- **Circuit Breaker State Machine**:
  - Wrap external service and database calls in circuit breakers (`Closed`, `Open`, `Half-Open`):
    - **Closed -> Open**: Trip to OPEN when failure rate exceeds threshold (e.g. >50% errors over a 10s rolling window). All subsequent calls fail fast immediately.
    - **Open -> Half-Open**: After cooldown (e.g. 30s), allow a single canary probe request through.
    - **Half-Open -> Closed / Open**: If the probe succeeds, reset to CLOSED; if it fails, reset timer and remain OPEN.
- **Deadline & Timeout Propagation**:
  - Every outbound HTTP/gRPC call MUST have an explicit deadline (`context.WithTimeout` or `AbortSignal.timeout`).
  - Downstream timeout budgets MUST be strictly smaller than the caller's upstream deadline to prevent orphaned background execution.

## 3. OpenTelemetry & Distributed Tracing Invariants
- **W3C Trace Context Propagation**:
  - All microservices MUST propagate standard W3C `traceparent` (`00-{trace_id}-{span_id}-{trace_flags}`) and `tracestate` across all HTTP headers, gRPC metadata, and asynchronous message broker records (Kafka, RabbitMQ, SQS, Redis PubSub).
- **Correlation ID Injection**:
  - Ingress gateways MUST extract or generate a unique `X-Correlation-ID` / `X-Request-ID`.
  - Inject this correlation identifier into:
    1. Downstream request headers.
    2. Response headers returned to the client.
    3. Structured application logs as a top-level JSON field (`correlation_id`).
- **Span Hygiene & Sensitive Data Redaction**:
  - Create child spans for significant sub-operations (database queries, external API calls, cache lookups).
  - ❌ **NEVER record sensitive PII or credentials** (passwords, JWT bearer tokens, API secrets, credit card numbers) in OpenTelemetry span attributes or log payloads.

## 4. The Dual-Write Trap & Event-Driven Reliability
- ❌ **THE DUAL-WRITE DISASTER**:
  - Never write to a database and then publish a message to a message broker in two separate, non-atomic steps:
    ```ts
    // ❌ CATASTROPHIC: If process crashes between DB and message broker, state is permanently inconsistent!
    await db.orders.create({ data: order });
    await kafkaProducer.send({ topic: 'orders', message: order });
    ```
- **Transactional Outbox Pattern**:
  - Save business mutations and an `outbox_events` record inside the **same atomic database transaction**.
  - Use an asynchronous, reliable relay (Debezium Change Data Capture or a polling outbox worker) to read the outbox table and publish events to the broker.
- **Consumer Idempotency**:
  - Assume at-least-once message delivery. Every message consumer MUST be idempotent.
  - Track processed `message_id` / `event_id` in a deduplication store with unique constraints before applying side-effects.
- **Dead Letter Queue (DLQ) & Poison Pill Isolation**:
  - When a message fails processing after max retry attempts (e.g. 3-5 jittered attempts), route it to a Dead Letter Queue (DLQ) containing:
    - Original message payload and headers.
    - Exception class, stack trace, and error message.
    - Attempt count and timestamp.
  - Never block consumer partitions indefinitely on poison messages or drop messages silently without alerting.

## 5. API Contract, Status Codes & Error Discipline
- **RFC 7807 Problem Details Standard**:
  - Return HTTP errors formatted according to RFC 7807 (`application/problem+json`):
    ```json
    {
      "type": "https://api.example.com/errors/insufficient-balance",
      "title": "Insufficient Account Balance",
      "status": 422,
      "detail": "Account balance of $14.20 cannot cover transaction amount of $50.00.",
      "instance": "/accounts/acc_987/transfers",
      "code": "INSUFFICIENT_BALANCE"
    }
    ```
- ❌ **BAN "HTTP 200 WITH ERROR PAYLOAD"**:
  - Never return HTTP 200 OK with `{ "status": "error", "code": 500 }`. This subverts CDN caching, load balancers, health checks, and API gateways.
- **Internal Error Masking in Production**:
  - Never leak database connection strings, raw SQL queries, or internal file system paths in HTTP responses.
  - Log root-cause stack traces internally against `correlation_id` and return a generic 500 error to the client: `"Internal Server Error (ID: 01HZX876)"`.
- **gRPC to HTTP Status Code Equivalence**:
  | gRPC Status | HTTP Status | Meaning |
  | :--- | :--- | :--- |
  | `INVALID_ARGUMENT` | `400 Bad Request` | Client provided invalid arguments |
  | `UNAUTHENTICATED` | `401 Unauthorized` | Missing or invalid authentication token |
  | `PERMISSION_DENIED` | `403 Forbidden` | Authenticated user lacks permission |
  | `NOT_FOUND` | `404 Not Found` | Target resource does not exist |
  | `ALREADY_EXISTS` | `409 Conflict` | Resource already exists |
  | `FAILED_PRECONDITION` | `412 Precondition Failed` / `409 Conflict` | System not in required state |
  | `RESOURCE_EXHAUSTED` | `429 Too Many Requests` | Rate limit or quota exhausted |
  | `DEADLINE_EXCEEDED` | `504 Gateway Timeout` | Execution exceeded caller deadline |
  | `UNAVAILABLE` | `503 Service Unavailable` | Service temporarily overloaded or down |
  | `INTERNAL` | `500 Internal Server Error` | Unexpected server bug or panic |

## 6. Rate Limiting & Graceful Load Shedding
- **Distributed Sliding Window Rate Limiting**:
  - Rate limiting must be implemented at the API Gateway layer using Redis sliding window log or token bucket algorithms.
  - ❌ **NEVER rely on single-node in-memory rate limiting** for multi-instance distributed services.
- **Mandatory Rate Limit Headers**:
  - Every API response must include standard rate limiting headers:
    - `X-RateLimit-Limit`: Maximum permitted requests in current window.
    - `X-RateLimit-Remaining`: Remaining request quota.
    - `X-RateLimit-Reset`: Unix timestamp when the quota resets.
    - `Retry-After`: Seconds to wait before retrying (mandatory on `429 Too Many Requests`).
- **Load Shedding Under High Saturation**:
  - When system resources exceed safety thresholds (e.g. CPU > 85%, thread pool exhaustion, DB connection pool wait > 1000ms), shed non-critical requests immediately with `503 Service Unavailable` or `429 Too Many Requests` to protect core mission-critical workflows (e.g. checkout, authentication).
