---
description: Message brokers, RabbitMQ, AMQP 0-9-1, NATS JetStream, MQTT, channel safety, prefetch bounded buffers, publisher confirms, quorum queues, DLX dead-letter loops, backpressure and at-least-once invariants
globs: **/*{rabbitmq,amqp,nats,jetstream,mqtt,broker,pubsub,queue,consumer,publisher}*.*,**/messaging/**,**/queues/**,**/brokers/**
alwaysApply: false
---

# Message Brokers & Queue Protocols: RabbitMQ, NATS JetStream & MQTT Invariants

> Add these rules to your project when designing, implementing, or auditing distributed message brokers, task queues, pub/sub architectures, or edge event routers using RabbitMQ (AMQP 0-9-1), NATS (Core & JetStream), or MQTT.

---

## 1. Architectural Taxonomy: Choosing the Right Messaging Protocol
Selecting the wrong broker protocol creates severe technical debt and operational instability.

| Feature / Dimension | RabbitMQ (AMQP 0-9-1) | NATS JetStream | Apache Kafka | MQTT 3.1.1 / 5.0 |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Topology** | Smart broker, dumb consumer (Routing key, exchanges, queues) | Stream storage + subject pub/sub (Raft replicated) | Log-centric streaming, partition-ordered log | Pub/Sub topic tree for constrained IoT / edge |
| **Consumer Model** | Push (with prefetch flow control) or Pull | Pull (recommended) or Push | Pull (consumer group poll loops) | Push |
| **Delivery Guarantee** | At-least-once (with ACKs & Confirms) | At-least-once (with JetStream ACKs) | At-least-once / Exactly-once (Transactional) | QoS 0, QoS 1, QoS 2 |
| **Queue Semantics** | Transient / durable queues with DLX | Durable streams, ephemeral/durable consumers | Append-only partitions with offset retention | Volatile or persistent session subscriptions |
| **Throughput / Latency** | 20k–100k msg/sec (~1–5ms) | 1M+ msg/sec (<500µs) | Millions msg/sec (batch throughput) | Lightweight, low-overhead edge networks |
| **Best Used For** | Complex routing, task queues, financial workflows | Ultra-low latency microservices, distributed events | Big data pipelines, audit logs, CDC streams | Mobile apps, IoT telemetry, battery-constrained devices |

---

## 2. RabbitMQ / AMQP 0-9-1 Concurrency: The Channel Thread-Safety Law
AMQP 0-9-1 connections are long-lived full-duplex TCP connections multiplexed into multiple lightweight virtual channels. **Channels are NOT thread-safe or goroutine-safe.**

- ❌ **THE CONCURRENT CHANNEL MUTATION DISASTER**:
  - Sharing a single AMQP `Channel` across multiple concurrent threads, goroutines, or asynchronous event callbacks causes frame interleaving. The broker receives garbled, out-of-order protocol frames and immediately closes the entire channel or connection with `504: CHANNEL_ERROR` or `503: COMMAND_INVALID`.
- ✅ **The Channel Isolation Invariants**:
  1. **Strictly One Channel Per Worker**: Assign exactly one dedicated AMQP channel per worker thread or goroutine.
  2. **Channel Pooling vs Connection Pooling**:
     - Keep **one shared `Connection`** per process (or a small pool of 2–4 connections to prevent TCP socket saturation).
     - Maintain a bounded pool of `Channel` instances, or allocate a new channel per worker lifecycle and close it upon completion.
     - Never share a channel across concurrent publishes or ACKs.

```go
// Go: Safe channel-per-worker model
func StartWorker(conn *amqp091.Connection, queueName string) error {
    // Dedicated channel per worker goroutine:
    ch, err := conn.Channel()
    if err != nil {
        return fmt.Errorf("open channel: %w", err)
    }
    defer ch.Close()

    // Bounded prefetch to prevent memory explosion:
    if err := ch.Qos(100, 0, false); err != nil {
        return fmt.Errorf("set qos: %w", err)
    }

    deliveries, err := ch.Consume(queueName, "", false /* autoAck */, false, false, false, nil)
    if err != nil {
        return fmt.Errorf("consume: %w", err)
    }

    for msg := range deliveries {
        if err := process(msg.Body); err != nil {
            _ = msg.Nack(false /* multiple */, false /* requeue -> send to DLX */)
        } else {
            _ = msg.Ack(false)
        }
    }
    return nil
}
```

---

## 3. The Unacked Message Flood & Mandatory Prefetch Count (`basic.qos`)
By default, RabbitMQ pushes messages to consumers as fast as the network permits if `prefetch_count` is not explicitly set (`prefetch_count = 0` means unlimited).

- ❌ **THE UNBOUNDED PREFETCH OOM CASCADE**:
  - A newly started consumer joins a queue with 500,000 backlog messages.
  - The broker pushes hundreds of thousands of messages across the TCP socket into the client process's in-memory buffer.
  - The consumer's heap memory spikes rapidly, triggering OS `OOMKilled` or GC pause thrashing.
  - Upon process crash, all unacknowledged messages are returned to the queue.
  - The next consumer boots up, accepts the same massive burst, and also crashes — triggering a cascading cluster-wide crash loop.
- ✅ **The Prefetch Bounding Invariant**:
  - **Always invoke `basic.qos(prefetch_count, 0, false)` before consuming.**
  - **Sizing Guidelines**:
    - **Fast, non-blocking workers** (<10ms): `prefetch_count = 50` to `200`. Keeps the network pipeline full without memory bloat.
    - **Heavy CPU or I/O workers** (>100ms): `prefetch_count = 1` to `10`. Ensures fair load distribution across horizontal worker nodes.
    - **Never leave prefetch at 0.**

---

## 4. Publisher Confirms & Delivery Guarantees (`confirm.select`)
Standard `basic.publish` is asynchronous and fire-and-forget; the AMQP protocol does not wait for broker disk fsync or queue placement before returning control to the caller.

- ❌ **THE SILENT MESSAGE DROP TRAP**:
  - A publisher pushes a critical order message. If the broker crashes before flushing its buffer, or if the routing key matches zero queues, the message is silently discarded with zero errors thrown to the application.
- ✅ **Production Invariants for Publishers**:
  1. **Enable Publisher Confirms (`confirm.select`)**: Force the broker to return an `Ack` or `Nack` for every published message.
  2. **Set Delivery Mode 2 (Persistent)**: Ensure messages are written to disk / quorum log (`DeliveryMode: amqp091.Persistent`).
  3. **Handle Unroutable Messages (`mandatory = true` or Alternate Exchanges)**:
     - Set `mandatory: true` to receive `BasicReturn` callbacks when a message cannot be routed to any queue.
     - Alternatively, configure an **Alternate Exchange** (`x-alternate-exchange`) on the primary exchange to automatically route dead messages to an unroutable audit queue.

```ts
// Node.js (amqplib): Reliable Publisher with Confirms
import amqp from 'amqplib';

export async function publishReliable(
  channel: amqp.ConfirmChannel,
  exchange: string,
  routingKey: string,
  payload: Buffer
): Promise<void> {
  return new Promise((resolve, reject) => {
    channel.publish(
      exchange,
      routingKey,
      payload,
      {
        persistent: true, // DeliveryMode = 2
        contentType: 'application/json',
        timestamp: Date.now(),
        messageId: crypto.randomUUID(),
      },
      (err) => {
        if (err !== null) {
          // Broker rejected message (Nack) or connection dropped
          return reject(new Error(`Publish NACKed by broker: ${err.message}`));
        }
        resolve(); // Broker confirmed message is fsynced/queued
      }
    );
  });
}
```

---

## 5. Quorum Queues vs Deprecated Classic Mirrored Queues
Classic Mirrored Queues (`x-ha-policy: all`) are officially deprecated in modern RabbitMQ (4.x+) and suffer from severe design flaws:
- They use an ad-hoc synchronization protocol that halts the entire cluster during master node failure.
- Network partitions ("split-brain") frequently cause catastrophic silent data loss or queue corruption.

- ✅ **The Quorum Queue Production Standard**:
  - Always configure modern replicated queues with `x-queue-type: "quorum"`.
  - Quorum queues implement the **Raft consensus algorithm**, guaranteeing strong consistency, predictable failover, and strict FIFO ordering even during network partitions.
  - **Quorum Queue Invariants**:
    1. Set cluster quorum size to an odd number (3 or 5 nodes).
    2. Set `x-max-in-memory-length` or `x-max-in-memory-bytes` to keep memory usage bounded by offloading older message bodies to disk.
    3. Configure `x-delivery-limit` to automatically isolate poison pill messages that crash consumers repeatedly.

```yaml
# Declaring a Quorum Queue with safe bounds:
QueueArguments:
  x-queue-type: "quorum"
  x-delivery-limit: 5               # Poison pill threshold -> automatically routed to DLX
  x-max-in-memory-length: 10000      # Keep max 10k messages in RAM; spill rest to disk
  x-dead-letter-exchange: "app.dlx" # Forward exhausted messages here
```

---

## 6. Dead Letter Exchanges (DLX), Poison Pills & Infinite Redelivery Loops
When a message fails processing (due to a bug, malformed payload, or downstream timeout), improper error handling leads to infinite crash loops.

- ❌ **THE `requeue = true` INFINITE LOOP DISASTER**:
  - A malformed JSON payload reaches a worker.
  - The worker throws a syntax parsing error and executes `msg.Nack(requeue = true)`.
  - RabbitMQ immediately pushes the exact same message right back to the top of the queue.
  - The worker consumes it, fails, and requeues again — consuming 100% CPU, generating gigabytes of error logs per minute, and blocking all valid traffic behind it.
- ✅ **The Dead Letter Exchange & Poison Pill Protocol**:
  1. **Strictly Reject without Requeue**: In error handlers, call `msg.Nack(requeue = false)` or `msg.Reject(requeue = false)`.
  2. **Bind a Dead Letter Exchange**:
     - Configure `x-dead-letter-exchange` on every business queue.
     - Rejected messages are automatically diverted to the DLX with diagnostic headers (`x-death`: count, reason, original exchange, timestamp).
  3. **Non-Blocking Exponential Retries via TTL Queues**:
     - Route retriable errors to a sequence of retry delay queues (e.g., `retry.10s`, `retry.60s`, `retry.300s`) configured with `x-message-ttl` and an `x-dead-letter-exchange` pointing back to the main worker queue.
     - Messages sleep in the delay queue until the TTL expires, at which point the broker automatically routes them back for reprocessing without tying up worker threads.

---

## 7. Flow Control, Alarms & Connection Blocked Handling
RabbitMQ incorporates built-in resource alarms to protect cluster stability:
- **Memory High Watermark**: Default 40% of host RAM.
- **Free Disk Space Limit**: Triggers when available disk falls below threshold (e.g., 50MB or 1.5x RAM).

- ❌ **THE BLIND TIMEOUT CRASH ON ALARM**:
  - When an alarm is triggered, RabbitMQ **blocks all client TCP socket reads** from publishers.
  - Application threads attempting to publish hang indefinitely, eventually exhausting HTTP connection pools and bringing down user-facing web services.
- ✅ **Production Invariants**:
  1. **Listen for Connection Blocked Events**: Register handlers for `connection.blocked` and `connection.unblocked`.
  2. **Circuit Break Immediately**: When the broker signals blocked state, fail fast or spill incoming writes to an emergency local fallback cache (e.g., Redis or local disk) rather than blocking backend threads.
  3. **Independent Connections for Consumers**: Always keep consumer connections separate from publisher connections. Even when publishing is blocked by alarms, consumers must continue draining queues to relieve memory pressure!

---

## 8. NATS JetStream: Architecture & Production Discipline
NATS JetStream provides high-performance, Raft-backed at-least-once streaming and pub/sub.

- ❌ **THE CORE NATS PERSISTENCE MISCONCEPTION**:
  - Publishing messages to standard Core NATS subjects (`nc.Publish("orders.created", data)`) without an underlying JetStream stream provides **zero persistence**. If no subscriber is actively connected at the millisecond of emission, the message is permanently lost.
- ✅ **JetStream Production Invariants**:

### A. Subject Hierarchy & Wildcards
- Use dot-delimited hierarchical tokens: `<domain>.<entity>.<action>` (e.g., `ecommerce.orders.created`).
- Wildcards:
  - `*` matches exactly **one** token: `ecommerce.orders.*` matches `ecommerce.orders.created`, but NOT `ecommerce.orders.us.created`.
  - `>` matches **one or more trailing tokens**: `ecommerce.orders.>` matches any sub-subject.
  - Never define overlapping wildcard subjects across different streams that compete for the same messages.

### B. Pull Consumers with Explicit Acks
- Push consumers in high-throughput environments cause buffer overflows. Always use **Pull Consumers** with `AckExplicit`.
- Process each message, persist application state, then invoke `msg.Ack()`.
- On transient failure, invoke `msg.NakWithDelay(backoff)` so JetStream delays redelivery.

```go
// Go: NATS JetStream Resilient Pull Consumer
func ConsumeJetStream(ctx context.Context, js jetstream.JetStream, streamName, consumerName string) error {
    cons, err := js.Consumer(ctx, streamName, consumerName)
    if err != nil {
        return fmt.Errorf("bind consumer: %w", err)
    }

    iter, err := cons.Messages(jetstream.PullMaxMessages(50))
    if err != nil {
        return fmt.Errorf("fetch messages: %w", err)
    }
    defer iter.Stop()

    for {
        msg, err := iter.Next()
        if err != nil {
            if errors.Is(err, jetstream.ErrMsgIteratorClosed) || ctx.Err() != nil {
                return nil
            }
            continue
        }

        // Process message with idempotency
        if err := handleOrder(ctx, msg.Data()); err != nil {
            // Negative ACK with 5-second backoff delay
            _ = msg.NakWithDelay(5 * time.Second)
            continue
        }

        // Explicit acknowledgment
        if err := msg.Ack(); err != nil {
            log.Printf("Failed to ack message: %v", err)
        }
    }
}
```

### C. Message Deduplication (`Nats-Msg-Id`)
JetStream provides native publisher deduplication:
- Set the `Nats-Msg-Id` header to a unique deterministic transaction or idempotency key (e.g., UUIDv7 or `order_${orderId}_attempt_${attempt}`).
- Configure the stream's `Duplicates` window (`duplicate_window: 2m`). JetStream automatically drops duplicate messages published within that window, guaranteeing idempotent ingestion.

---

## 9. MQTT Protocol Discipline: IoT, Telemetry & Real-Time Edge
MQTT is engineered for battery-constrained devices, flaky mobile connections, and high-concurrency sensor networks.

- ❌ **THE QOS 2 OVERHEAD TRAP & MISSING LWT**:
  - Choosing QoS 2 ("Exactly Once") for every telemetry event imposes a 4-step protocol handshake (`PUBLISH -> PUBREC -> PUBREL -> PUBCOMP`) with high round-trip latency and state storage on both broker and edge devices.
  - Failing to configure Last Will and Testament (LWT) leaves dead client sessions marked active indefinitely when TCP sockets die abruptly.
- ✅ **MQTT Production Invariants**:
  1. **QoS Selection Protocol**:
     - **QoS 0 (At Most Once)**: High-frequency ephemeral sensor metrics where dropped frames are harmless (e.g., GPS telemetry every 1s).
     - **QoS 1 (At Least Once)**: Financial, alert, and command messages. **Pair QoS 1 with application-level idempotency keys** rather than paying QoS 2 latency costs.
     - **QoS 2 (Exactly Once)**: Reserve strictly for non-idempotent billing actions where latency is secondary.
  2. **Last Will and Testament (LWT)**:
     - Always configure an LWT payload during the initial MQTT `CONNECT` packet.
     - If the client drops offline without sending a clean `DISCONNECT`, the broker immediately publishes the LWT message (e.g. `devices/{id}/status` -> `{"online": false}`) to alert other services.
  3. **Keep-Alive & Half-Open Socket Reaping**:
     - Set `keep_alive` interval (typically 30s to 60s). The broker must prune half-open dead TCP sockets if no packet or `PINGREQ` is received within $1.5 \times \text{keep\_alive}$.
  4. **Clean Session & ClientID Invariants**:
     - Always use a persistent, deterministic `ClientID` for devices.
     - Set `clean_session: false` (or MQTT 5 `CleanStart: false` with `SessionExpiryInterval`) so subscriptions and undelivered QoS 1 messages survive brief mobile reconnections.
     - Monitor broker session storage to prevent memory exhaustion from millions of abandoned client IDs.

---

## 10. Graceful Shutdown & In-Flight Drain Protocol
Terminating a message worker abruptly drops unacknowledged messages back into the broker, triggering duplicate processing or partial state mutations.

- ✅ **The 4-Step Worker Drain Sequence**:
  1. **Stop Ingress**: Unsubscribe or issue `basic.cancel(consumer_tag)` so the broker stops dispatching new messages to this worker.
  2. **Drain In-Flight Work**: Allow currently active jobs to finish processing within a bounded timeout (`SIGTERM` grace period, typically 15–30s).
  3. **Flush ACKs**: Acknowledge all completed messages before closing the channel.
  4. **Close AMQP/NATS Connection**: Close individual channels first, then terminate the TCP connection.
path: rules/message-brokers-rabbitmq-nats.md
