---
description: Apache Kafka & event streaming production invariants, consumer rebalance safety, idempotent producers, and dead-letter queue (DLQ) topologies
globs: **/*.{go,ts,js,py,rs,java},**/kafka/**,**/events/**,**/streaming/**,**/consumers/**,**/producers/**,**/pubsub/**
alwaysApply: false
---

# Apache Kafka & Event Streaming Production Invariants

> Add these rules to your project if developing event-driven architectures, stream processing pipelines, or asynchronous event brokers (Apache Kafka, Redpanda, AWS Kinesis, RabbitMQ Streams).

## 1. Producer Reliability, Idempotence & Ordering Guarantees
- **Mandatory Idempotent Producer**:
  - `enable.idempotence=true` MUST be asserted on all producers (default in Kafka 3.0+, but must be explicitly configured in client setups).
  - Ensures exactly-once semantics per partition, eliminating duplicate messages produced during transient network retries without requiring ad-hoc deduplication code.
- **Strict Acknowledgment Contract (`acks=all`)**:
  - ❌ **NEVER use `acks=0` or `acks=1` for critical business data**:
    - `acks=0`: Fire-and-forget; guarantees zero delivery assurance upon leader failure or network drops.
    - `acks=1`: Acknowledges when only the leader writes to its local log. If the leader crashes before replicating to In-Sync Replicas (ISR), data is permanently lost.
  - ✅ **Always use `acks=all` (or `-1`)** combined with broker topic config `min.insync.replicas=2` (for replication factor 3) to prevent data loss on leader failover.
- **In-Flight Requests & Ordering Guarantees**:
  - In Kafka, message ordering is **strictly guaranteed only within a single partition**, never globally across topics.
  - When `enable.idempotence=true`, `max.in.flight.requests.per.connection` must be `<= 5` (Kafka preserves sequence numbers up to 5 in-flight batches per connection).
  - If idempotence is disabled, `max.in.flight.requests.per.connection` MUST be `1` to prevent out-of-order writes during retries.
- **Asynchronous Callback / Future Error Handling**:
  - ❌ **NEVER fire async produce calls without delivery error handling**:
    ```go
    // ❌ CATASTROPHIC: Silently drops failed messages
    producer.Produce(&kafka.Message{TopicPartition: ..., Value: payload}, nil)
    ```
  - Always handle delivery reports or futures synchronously or via dedicated delivery report channels:
    ```go
    deliveryChan := make(chan kafka.Event, 1)
    err := producer.Produce(&kafka.Message{TopicPartition: ..., Value: payload}, deliveryChan)
    if err != nil {
        return fmt.Errorf("buffer full or client closed: %w", err)
    }
    e := <-deliveryChan
    msg := e.(*kafka.Message)
    if msg.TopicPartition.Error != nil {
        return fmt.Errorf("delivery failed to partition %d: %w", msg.TopicPartition.Partition, msg.TopicPartition.Error)
    }
    ```
- **Partition Key Strategy & Hot Partition Avoidance**:
  - Explicitly supply a deterministic partition key (e.g., `tenant_id`, `account_id`, `order_id`) when causal ordering is required.
  - ❌ **Avoid low-cardinality keys** (e.g. `status: "PENDING"`) or keys with extreme power-law distribution (e.g. single tenant with 90% of all volume), which creates hot partitions and CPU starvation on individual brokers and consumers.
  - If ordering is not required, pass a `null` key so the producer can uniformly distribute messages across all partitions via the RoundRobinPartitioner or StickyPartitioner.

## 2. Consumer Poll Loop & Anti-Rebalance Discipline
- **The Heartbeat & Processing Timeout Invariant**:
  - Kafka consumers maintain membership in consumer groups via background heartbeats (`session.timeout.ms`, default 45s) AND foreground poll calls (`max.poll.interval.ms`, default 5 minutes / 300,000ms).
  - ❌ **THE REBALANCE CASCADE DISASTER**: If your consumer takes longer than `max.poll.interval.ms` to process a single batch of messages, the Kafka coordinator assumes the consumer died, kicks it out of the group, and triggers a full consumer group rebalance. When the zombie consumer finishes and attempts to commit, it throws `CommitFailedException`, crashes, and triggers another rebalance loop (rebalance storm).
- **Decouple Ingestion from Long-Running Work**:
  - Tune `max.poll.records` downward (e.g., 50–100 instead of 500) if downstream message processing includes external network I/O or heavy database operations.
  - Or decouple the poll loop from processing using a bounded worker pool:
    - Main thread exclusively polls the broker and pushes to an internal bounded channel.
    - Worker pool processes tasks and updates an in-memory offset tracker.
    - If worker queues are full, pause the consumer partition (`consumer.pause()`) to preserve flow control without halting heartbeats.
- **Use Cooperative Sticky Assignor**:
  - Configure `partition.assignment.strategy` to include `CooperativeStickyAssignor` (default in Kafka 3.0+).
  - Legacy `RangeAssignor` or `RoundRobinAssignor` triggers **eager rebalancing**: all consumers revoke all assigned partitions and stop processing during rebalances ("stop-the-world").
  - `CooperativeStickyAssignor` uses incremental cooperative rebalancing: unaffected partitions continue consuming without interruption while only migrating partitions are reassigned.

## 3. Offset Commit Discipline & At-Least-Once Delivery
- ❌ **BAN AUTO-COMMIT (`enable.auto.commit=false`) IN PRODUCTION**:
  - `enable.auto.commit=true` commits offsets periodically in the background based on timer intervals (`auto.commit.interval.ms`), completely decoupled from whether your application actually succeeded in processing the messages.
  - If your container crashes or restarts right after pulling messages, all uncommitted-but-polled messages are **permanently lost**.
- **Commit Strictly AFTER Side-Effects Succeed**:
  - Commit offsets synchronously or asynchronously ONLY after the message payload has been written to the backing database or processed downstream:
    ```ts
    for await (const message of consumer) {
      try {
        await processOrder(message.value)
        await consumer.commitOffsets([{ topic, partition, offset: message.offset + 1 }])
      } catch (err) {
        // Handle failure or route to retry/DLT; do NOT commit raw offset
      }
    }
    ```
- **Consumer Idempotency & Deduplication**:
  - Kafka guarantees at-least-once delivery (under network partitions, retries, and rebalances). Duplicate deliveries ARE inevitable.
  - Every consumer operation MUST be idempotent. Deduplicate on `event_id` or `(topic, partition, offset)` using a unique database constraint or distributed cache (Redis with TTL):
    ```sql
    INSERT INTO processed_events (event_id, processed_at) VALUES ($1, NOW())
    ON CONFLICT (event_id) DO NOTHING;
    ```

## 4. Poison Pill Quarantine, Non-Blocking Retries & Dead Letter Topics (DLT)
- ❌ **NEVER LOOP INFINITELY ON MALFORMED MESSAGES (Poison Pills)**:
  - If a message contains unparseable JSON, schema incompatibility, or invalid data, retrying in-place blocks the entire partition indefinitely, causing lag to spike across all subsequent messages in that partition.
- **Three-Tier Non-Blocking Retry Architecture**:
  - **Tier 1 (Immediate In-Memory Retry)**: Retry 2–3 times with micro-backoff only for transient network glitches (database connection blips).
  - **Tier 2 (Delayed Retry Topics)**: Route transient failures to delayed topics (e.g. `orders.retry-1m`, `orders.retry-10m`) using message timestamp headers to prevent blocking the main production stream.
  - **Tier 3 (Dead Letter Topic - DLT)**: Route unrecoverable errors (JSON parse errors, validation failures, business rejections) immediately to `orders.DLT`.
- **Enrich Dead Letter Headers**:
  - When publishing to a DLT, inject diagnostic trace metadata into record headers:
    - `x-original-topic`: Name of the source topic.
    - `x-original-partition`: Source partition index.
    - `x-original-offset`: Source offset.
    - `x-exception-message`: Error string or root-cause message.
    - `x-exception-stacktrace`: Truncated stack trace.
    - `x-retry-count`: Number of attempts before quarantine.
    - `traceparent`: Propagate W3C distributed trace context.

## 5. Schema Registry & Contract Evolution Safety
- **Mandatory Schema Registry for Binary Formats**:
  - When using Apache Avro or Protocol Buffers, always integrate with Confluent Schema Registry, AWS Glue Schema Registry, or Apicurio.
  - Register schemas and serialize messages with magic byte prefix + Schema ID to guarantee deserialization compatibility.
- **Schema Evolution Invariants (BACKWARD or FULL Compatibility)**:
  - Configure compatibility level to `BACKWARD` or `FULL` on all production subjects.
  - **Rule 1: Always provide default values for new fields**:
    ```json
    { "name": "loyalty_tier", "type": "string", "default": "STANDARD" }
    ```
    If a new field lacks a default value, consumers reading with the old schema will fail deserialization.
  - **Rule 2: Never delete required fields**: Deprecate fields first, and only delete if all active consumers have updated schemas.
  - **Rule 3: Never rename fields**: Renaming is equivalent to deleting the old field and adding a new field without defaults.

## 6. Compression, Batching & Graceful Shutdown
- **Producer Compression Invariant**:
  - Always enable producer compression: `compression.type=lz4` or `compression.type=zstd` (or `snappy`).
  - Compression reduces network I/O, disk storage, and broker page cache pressure by 40–70% with negligible CPU overhead.
  - Accompany with bounded batching: `linger.ms=10` to `20` and `batch.size=65536` (64KB) to allow efficient batch compression without noticeable latency.
- **Deterministic Graceful Shutdown Sequence**:
  - On receiving `SIGINT` or `SIGTERM`:
    1. Invoke `consumer.wakeup()` from the signal handler to break the blocking `poll()` call.
    2. Catch `WakeupException` in the poll loop.
    3. Complete or rollback in-flight message processing transactions.
    4. Commit final processed offsets synchronously (`commitSync()`).
    5. Close the consumer (`consumer.close()`) to notify the group coordinator immediately, triggering an instant rebalance instead of waiting for `session.timeout.ms`.
    6. For producers: call `producer.flush()` with a bounded timeout (e.g. 10s) followed by `producer.close()`.
