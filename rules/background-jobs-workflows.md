---
description: Distributed background jobs, task queues, durable execution workflows (Temporal, BullMQ, Celery, River, Sidekiq, SQS), and worker invariants
globs: **/*{job,worker,task,queue,workflow,activity,cron}*,**/temporal/**,**/jobs/**,**/workers/**,**/tasks/**,**/queues/**
alwaysApply: false
---

# Distributed Background Jobs, Task Queues & Durable Workflows

> Add these rules to your project if developing asynchronous background workers, queue consumers, scheduled tasks (Cron), or durable execution workflows using Temporal, BullMQ, Celery, River, Asynq, Sidekiq, or AWS SQS.

## 1. Message & Job Delivery Guarantees
- **At-Least-Once Delivery Reality**:
  - All distributed queue systems (Redis, SQS, RabbitMQ, Kafka) guarantee **at-least-once** delivery, NEVER exactly-once.
  - A job CAN and WILL be delivered multiple times due to worker crashes, network timeouts, or broker ack retransmissions.
  - ❌ **EVERY job handler MUST be strictly idempotent**.
- **Mandatory Idempotency Keys & Deduplication**:
  - Enforce atomic deduplication at the database or cache layer using unique idempotency keys:
    ```ts
    // BullMQ / Redis atomic deduplication
    await queue.add('charge-customer', payload, {
      jobId: `charge:${orderId}:${attemptNumber}`, // Unique job deduplication key
      removeOnComplete: { age: 86400, count: 5000 },
      removeOnFail: { age: 604800 },
    });
    ```
  - For financial, notification, or external API side-effects, record an idempotency record in the primary database within the same transaction before firing the external side-effect.
- **Payload Minimalism (Pass IDs, Never Live Entities)**:
  - ❌ **NEVER serialize full database entity objects into queue payloads**:
    ```json
    // ❌ AI Anti-Pattern: Stale data, payload bloat, and serialization breakage
    { "user": { "id": "123", "name": "Alice", "balance": 500, "role": "admin" } }
    ```
  - Store only immutable identifiers and version numbers in the job payload. Fetch the latest authoritative state from the database at execution time:
    ```json
    // ✅ Minimal payload invariant
    { "userId": "123", "orderId": "ord_987", "schemaVersion": 1 }
    ```

## 2. Retries, Backoff & Poison Pill Defense
- **Exponential Backoff with Full Jitter**:
  - ❌ **NEVER use immediate retries or fixed linear intervals**: When downstream services experience an outage, immediate retries generate a catastrophic thundering herd (retry storm) that prevents recovery.
  - Always enforce exponential backoff with full randomized jitter:
    $$t_{\text{sleep}} = \text{random}(0, \min(M, B \times 2^{\text{attempt}}))$$
- **Bounded Max Attempts & Dead-Letter Queues (DLQ)**:
  - Set a hard ceiling on maximum retry attempts (e.g., 3–5 attempts).
  - When retries are exhausted, move the job payload and failure stack trace to a Dead-Letter Queue (DLQ) or dead-letter table.
  - ❌ **NEVER drop failed jobs silently into the void**: Alert on DLQ ingestion rate spikes.
- **Poison Pill Isolation**:
  - A poison pill is a malformed message (invalid JSON, schema mismatch, unhandled edge-case exception) that causes workers to crash immediately on receipt.
  - Validate payloads against a strict schema (Zod, Pydantic, protobuf) immediately upon dequeuing.
  - If schema validation fails fatally, route immediately to the DLQ; **never retry unparseable payloads**.

## 3. Durable Execution & Workflow Invariants (Temporal, Cadence, Inngest)
- **Workflows MUST Be 100% Deterministic**:
  - In durable workflow engines (Temporal, Cadence, Inngest), workflow code is replayed from event history from the beginning whenever execution resumes or migrates across worker nodes.
  - ❌ **ABSOLUTE BAN on non-deterministic operations inside workflow functions**:
    - ❌ Never read system time (`time.Now()`, `new Date()`, `datetime.now()`) -> Use workflow-provided virtual clocks (`workflow.Now(ctx)`).
    - ❌ Never generate random numbers (`rand.Int()`, `Math.random()`, `uuid.v4()`) -> Use workflow-deterministic side effects or pass seeds.
    - ❌ Never perform direct network I/O, database queries, or external API calls inside workflow definitions.
    - ❌ Never use non-deterministic iteration over native hash maps without sorting keys first.
    - ❌ Never use raw goroutines or OS threads inside workflows -> Use workflow-native safe primitives (`workflow.Go`).
- **Push All Side-Effects into Activities / Steps**:
  - All non-deterministic logic (HTTP calls, DB reads/writes, file I/O, sending emails) MUST live exclusively inside **Activities / Steps**.
  - Configure explicit timeouts on every activity invocation (`StartToCloseTimeout`, `ScheduleToCloseTimeout`, `HeartbeatTimeout`).
- **Backward-Compatible Workflow Evolution**:
  - When modifying running workflow code, NEVER modify or delete existing workflow paths without versioning checks (`workflow.GetVersion(ctx, ...)` in Temporal).
  - Changing code execution order in an existing workflow breaks replay validation with non-deterministic execution errors.

## 4. Worker Lifecycle, Concurrency & Graceful Drain
- **Graceful Shutdown & Signal Trapping (`SIGTERM` / `SIGINT`)**:
  - When a container orchestrator (Kubernetes) scales down or redeploys a worker pod, it sends `SIGTERM`.
  - The worker MUST:
    1. Immediately stop accepting new jobs from the queue.
    2. Allow currently executing in-flight jobs a bounded grace period (e.g., 30–60 seconds) to complete or reach a safe checkpoint.
    3. If the grace period expires, fail or re-enqueue the uncompleted job and exit before Kubernetes sends `SIGKILL`.
- **Heartbeat & Zombie Job Resuscitation**:
  - For long-running jobs (video encoding, data exports, AI model training), workers MUST send periodic heartbeats to the queue broker (e.g. every 10–30 seconds).
  - If a worker dies abruptly (OOM kill, power failure) without sending heartbeats, the broker must mark the task as a zombie and reassign it to a healthy worker.
- **Worker Concurrency & Connection Pool Budgeting**:
  - ❌ **NEVER configure worker concurrency higher than the database/cache connection pool limit**:
    - If worker concurrency is 50, but the database connection pool is capped at 10, 40 workers will block on connection acquisition timeouts.
    - Always size concurrency: $\text{Worker Concurrency} \le \text{DB Connection Pool Size} \times \text{Safety Factor (0.7)}$.

## 5. Multi-Tenant Fairness, Rate Limiting & Queue Priority
- **Multi-Queue Latency Segregation**:
  - Segregate queues by latency Service Level Objectives (SLO):
    - `critical` / `realtime`: User-waiting jobs (password resets, 2FA codes, immediate transaction receipts) — high worker pool ratio.
    - `default`: Asynchronous standard processing (webhooks, email newsletters).
    - `bulk` / `low`: Heavy batch imports, reporting, data purging — strictly throttled so they cannot starve critical queues.
- **Fair Queuing & Tenant Starvation Defense**:
  - A single high-volume customer must NEVER monopolize the worker fleet and starve all other tenants.
  - Implement per-tenant concurrency limits or round-robin virtual queue dispatching (e.g. BullMQ parent-child queues or Redis prefix partitions).
- **Scheduled & Cron Job Thundering Herd Jitter**:
  - ❌ **NEVER schedule all daily cron jobs at exactly `00:00:00` midnight**:
    - Having 50 recurring tasks fire at the same second spikes CPU, database locks, and third-party API rate limits.
  - Distribute recurring jobs across the hour and add randomized start jitter ($\pm 15$–$60$ seconds) for non-time-critical reports and maintenance tasks.

## 6. Checkpointing & The Saga Pattern
- **Incremental Batch Checkpointing**:
  - When processing large collections (e.g., iterating over 100,000 rows):
    - Chunk work into bounded batches (e.g., 500 records per batch).
    - Persist a cursor / checkpoint (e.g. `last_processed_id`) after each batch.
    - If the worker restarts halfway through, resume from the checkpoint instead of re-processing from the beginning.
- **Distributed Sagas & Compensating Transactions**:
  - For multi-step distributed operations that span separate services (e.g. Reserve Stock -> Authorize Payment -> Create Shipping Label):
    - When step 3 fails fatally, the worker MUST execute explicit compensating activities (e.g. Cancel Payment Authorization -> Release Stock Reservation) in reverse order.
    - Never assume an un-executed operation rolls back automatically across distributed boundaries.
