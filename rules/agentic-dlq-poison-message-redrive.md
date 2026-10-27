---
description: Agentic dead letter queues (DLQ), poison pill message quarantine, non-blocking delayed retry ladder, diagnostic failure envelopes, token-bucket canary redrive governance, and idempotent replay verification across Kafka, RabbitMQ, SQS, NATS, BullMQ, Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{queue,worker,consumer,dlq,retry,redrive,broker,event,kafka,rabbitmq,sqs,nats}*.*,**/src/workers/**/*.{ts,js,go,rs,py},**/src/events/**/*.{ts,js,go,rs,py},**/consumers/**/*.{ts,js,go,rs,py}
alwaysApply: false
---

# Agentic Dead Letter Queues, Poison Message Quarantine & Resilient Redrive Governance Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design asynchronous event consumers, background queue workers, stream processors, or event-driven microservices across Apache Kafka, RabbitMQ, AWS SQS/SNS, NATS JetStream, Redis Streams, or BullMQ. Eliminate the "Poison Pill Infinite Crash Loop Trap" (where un-parseable or malformed messages trigger unbounded consumer crashes, saturating CPU and spamming logs), the "Head-of-Line (HOL) Partition Blocking Disaster" (where in-line consumer sleeps stall entire Kafka partitions and freeze healthy tenant pipelines), the "Dead Letter Black Hole Trap" (where messages are discarded with zero diagnostic metadata, missing stack traces, and absent traceparents), the "Blind Redrive Poison Flood" (where batch replays at wire speed overwhelm recovering downstream databases and crash the consumer fleet a second time), the "Non-Idempotent Duplicate Replay State Mutation Anomaly" (where redriven messages re-execute previously committed financial mutations), and the "Unbounded DLQ Storage Depletion & Poison Injection Vector" by establishing a strict 5-Tier DLQ Governance Ladder, non-blocking retry delay pipelines, diagnostic failure envelopes, token-bucket canary redrive controllers, and automated circuit-breaker trip boundaries.

---

## 1. Architectural Taxonomy: The 6 Dead Letter & Poison Message Catastrophes vs The 5-Tier DLQ Governance Ladder

When autonomous coding agents write event consumers and background workers, LLMs consistently generate naive `try / catch` blocks with catastrophic error handling:

```typescript
// ❌ CATASTROPHIC LLM MESSAGE CONSUMER ENTRYPOINT
channel.consume('orders.v1', async (msg) => {
  try {
    const data = JSON.parse(msg.content.toString()); // VULN 1: SyntaxError if corrupted payload!
    await processOrder(data); // VULN 2: If DB or downstream API fails...
    channel.ack(msg);
  } catch (err) {
    console.error('Processing failed:', err);
    // VULN 3: CATASTROPHIC: Requeuing poison pills causes an infinite loop at 10,000 crashes/sec!
    channel.nack(msg, false, true); 
    // OR VULN 4: Silently dropping the message, losing customer financial orders forever!
  }
});
```

In production event architectures, this naive pattern produces six critical engineering catastrophes:

- **The "Poison Pill Infinite Crash Loop Trap"**:
  - A message with an invalid schema, corrupted JSON bytes, an unexpected null field, or an edge-case value causes an unhandled exception or worker panic.
  - The naive consumer executes `nack(msg, requeue = true)` or simply crashes and is restarted by systemd or Kubernetes.
  - Upon restart or immediate re-delivery, the same poison pill is delivered again to the top of the queue. The consumer crashes again immediately, generating 1,000+ crashes per minute, saturating CPU cores, flooding disks with gigabytes of repetitive stack traces, and completely halting message processing.
  - Invariant: A consumer MUST inspect the broker delivery counter (e.g., RabbitMQ `x-delivery-count`, SQS `ApproximateReceiveCount`, or transactional header state $\kappa_{\text{attempt}}$). Once $\kappa_{\text{attempt}} \ge K_{\text{max}}$, the message MUST be evicted from the active pipeline and routed to DLQ quarantine without throwing an unhandled process crash.

- **The "Head-of-Line (HOL) Partition Blocking Disaster"**:
  - In partitioned logs (Apache Kafka, AWS Kinesis, Pulsar, SQS FIFO), consumer offsets advance monotonically.
  - When an autonomous agent encounters a transient downstream failure (e.g., third-party billing API 503) or a poison pill, it sleeps inside the consumer loop (`time.Sleep(5s)` or `await sleep(5000)`) and retries the same offset in-line.
  - This stalls the entire partition. Thousands of valid, time-sensitive events belonging to hundreds of different tenants queued behind the failing message are delayed indefinitely, violating SLAs.
  - Invariant: In-line retries MUST be strictly bounded ($K_{\text{inline}} \le 2$, max $200\text{ms}$). Subsequent retries MUST use a **Non-Blocking Retry Topic Pipeline** (e.g., `orders.retry-10s`, `orders.retry-60s`, `orders.retry-300s` or delayed exchange) allowing the primary partition offset to advance immediately without stalling healthy messages.

- **The "Dead Letter Black Hole Trap (Silent Data Eviction & Telemetry Blindness)"**:
  - When messages exceed retry limits, agents dump the raw message payload into a dead letter queue or error table with zero diagnostic metadata.
  - SREs and developers have no way to determine: What was the exception? Which microservice failed? What was the stack trace? At what exact microsecond did it fail? What was the correlation ID / traceparent? How many retries did it undergo?
  - The DLQ fills up quietly until disk or broker memory is exhausted, or data is quietly dropped past broker retention TTL.
  - Invariant: Every message transitioning to DLQ MUST be encapsulated in a standardized **Dead Letter Diagnostic Envelope** containing: (1) original payload bytes and SHA-256 fingerprint, (2) failure taxonomy (`DETERMINISTIC_SCHEMA`, `DETERMINISTIC_BUSINESS`, `TRANSIENT_DOWNSTREAM`, `TRANSIENT_RESOURCE`), (3) sanitized root-cause error message and stack trace, (4) W3C traceparent and correlation ID, (5) consumer worker ID and container hostname, (6) retry lineage with timestamped audit trail.

- **The "Blind Redrive Poison Flood (Thundering Redrive Stampede)"**:
  - After a bug fix or downstream outage resolution, an operator or autonomous agent triggers a naive redrive script: `for msg in dlq: publish(mainQueue, msg)`.
  - Thousands or tens of thousands of queued poison pills or delayed events are flushed simultaneously back into the production topic at wire speed ($>10,000\text{ msg/s}$).
  - Downstream databases and external APIs that just recovered are immediately crushed by a thundering herd, and if any unfixed edge cases remain, the entire consumer fleet crashes simultaneously in a secondary cascading outage.
  - Invariant: Redrive operations MUST be governed by a **Rate-Limited Token-Bucket Gate** ($R_{\text{redrive}} \le \alpha \cdot C_{\text{target}}$ where $\alpha \le 0.10$), with **Canary Dry-Run Verification** (redriving a small canary batch first and monitoring health for $\Delta t \ge 60\text{s}$ before bulk redrive) and **Automated Circuit Breaker Interruption**.

- **The "Non-Idempotent Duplicate Replay State Mutation Anomaly"**:
  - A multi-step consumer failed after successfully executing step 1 (e.g., customer credit card charged) but before completing step 2 (updating inventory) or ACK-ing the message.
  - When the message is redriven from the DLQ, naive consumer logic executes step 1 again, charging the customer twice.
  - Invariant: All consumer handlers MUST enforce **Strict Idempotency Invariants** ($f(f(x)) \equiv f(x)$) using cryptographic request fingerprinting or atomic lease checks (`INSERT ... ON CONFLICT DO NOTHING` or PostgreSQL status fencing). Redrive envelopes MUST include an explicit `X-Redrive-Attempt` header and require consumers to verify prior partial commits via transactional outbox or step journals before re-executing state mutations.

- **The "Unbounded DLQ Storage Depletion & Poison Injection Vector"**:
  - Naive DLQ implementations have infinite retention without storage quotas or alerting. Malicious actors or runaway upstream emitters flood the broker with invalid payloads, exhausting broker disk space and causing cluster-wide out-of-memory crashes.
  - Furthermore, administrative redrive dashboards that deserialize payloads without schema validation are vulnerable to remote code execution (RCE) via insecure deserialization (Java gadget chains, Python `pickle`, Ruby `Marshal`).
  - Invariant: DLQs MUST enforce strict storage retention bounds ($\text{TTL} \le 14\text{d}$ and max bytes quota), automated PagerDuty/Slack threshold alerts ($\text{DLQ\_Depth} \ge \theta_{\text{alert}}$), and safe schema validation (Zod/Pydantic/Protobuf) rejecting untrusted binary gadget deserialization.

---

```
                       5-TIER DLQ & POISON PILL GOVERNANCE LADDER
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ Tier 4: Autonomous Resilient Redrive Governance & Self-Healing FSM          │
  │  - Rate-Limited Token-Bucket Ingestion Clamping ($\le 10\%$ Consumer Cap)   │
  │  - Canary Dry-Run Verification ($N=5 \dots 50$, $60\text{s}$ Health Bake)   │
  │  - Circuit-Breaker Auto-Trip ($\text{FailRate} > 2\% \implies \text{Halt}$) │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 3: Strict Idempotency Fencing & Partial-Execution Replay Compensation  │
  │  - Storage Monotonic Fencing ($f(f(x)) \equiv f(x)$)                        │
  │  - Step-Level Journal Verification Before Re-Executing Mutations            │
  │  - Explicit `X-Redrive-Attempt` Header Injection                            │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 2: Diagnostic Dead Letter Enveloping & W3C Distributed Tracing         │
  │  - Canonical Diagnostic Wrapper (SHA-256 Digest, Root Cause, Stack Trace)   │
  │  - W3C `traceparent` Injection & Causality Graph Preservation               │
  │  - Failure Classification (DETERMINISTIC vs TRANSIENT)                      │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 1: Non-Blocking Multi-Stage Retry Delay Ladder                         │
  │  - Decouple Retries to Exponential Delay Topics (`retry-10s`, `retry-60s`)  │
  │  - Immediate Primary Partition Offset Advance (Zero In-Line Sleep Blocking) │
  │  - Decorrelated Full-Jitter Retry Timing                                    │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 0: Delivery Attempt Tracking & Hard Poison Pill Interception           │
  │  - Broker-Level Delivery Counter Inspection ($\kappa \le K_{\text{max}}$)   │
  │  - Instant DLQ Route for Deterministic Syntax / Schema Parse Errors         │
  │  - Absolute Ban on Naive `nack(requeue = true)` Loop                        │
  └─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical & Formal Invariant Calculus

### 2.1 The Poison Pill Eviction & Delivery Ceiling Law

Let $m$ be an event message ingested by consumer $C$ at time $t$. Let $\kappa(m) \in \mathbb{N}_{\ge 1}$ denote the total delivery attempt counter tracked by the messaging substrate, and let $K_{\text{max}} \in \mathbb{N}$ be the configured ceiling (typically $3 \le K_{\text{max}} \le 5$).

Let $\mathcal{E}$ be the failure resulting from processing attempt $\kappa$. The error classifier maps $\mathcal{E}$ to a binary reproducibility partition:

$$\text{ClassifyError}(\mathcal{E}) \in \{\text{DETERMINISTIC}, \, \text{TRANSIENT}\}$$

Where:
- $\text{DETERMINISTIC} = \{\text{SchemaMismatch}, \text{MalformedPayload}, \text{IllegalStateArgument}, \text{BusinessInvariantViolation}\}$
- $\text{TRANSIENT} = \{\text{ConnectionTimeout}, \text{RateLimit429}, \text{DatabaseDeadlock}, \text{ServiceUnavailable503}\}$

The **Poison Pill Eviction Law** states:

$$\text{NextAction}(m, \mathcal{E}) = \begin{cases}
\text{ROUTETO\_DLQ}(m, \mathcal{E}), & \text{if } \text{ClassifyError}(\mathcal{E}) = \text{DETERMINISTIC} \\
\text{ROUTETO\_DLQ}(m, \mathcal{E}), & \text{if } \kappa(m) \ge K_{\text{max}} \\
\text{ENQUEUE\_DELAYED\_RETRY}(m, \kappa(m)), & \text{otherwise}
\end{cases}$$

**Corollary**: Deterministic errors MUST NOT enter retry loops. They transition immediately to the Dead Letter Queue on first failure $\kappa = 1$, conserving $100\%$ of redundant downstream network calls and compute cycles.

### 2.2 Non-Blocking Partition Throughput Conservation Law

Let $\mathcal{P}$ be an ordered Kafka/FIFO message partition with ingestion rate $\lambda_{\text{in}}$ messages per second. Let $T_{\text{process}}$ be the normal message execution duration ($T_{\text{process}} \le 50\text{ms}$).

If a consumer blocks synchronously in-line for duration $T_{\text{sleep}} = 5\text{s}$ upon experiencing transient failure on message $m_i$:

$$\text{Throughput}(\mathcal{P}) = \frac{1}{T_{\text{sleep}} + T_{\text{process}}} \approx 0.2 \text{ msg/s}$$

All subsequent messages $\{m_{i+1}, m_{i+2}, \dots, m_{i+N}\}$ queued behind $m_i$ on partition $\mathcal{P}$ suffer head-of-line delay:

$$D(m_{i+k}) \ge k \cdot T_{\text{sleep}}$$

Under the **Non-Blocking Retry Protocol**, the primary consumer emits $m_i$ to delayed retry queue $Q_{\text{retry}, 1}$, commits primary offset $O_{m_i}$, and immediately pulls $m_{i+1}$:

$$D(m_{i+k}) \equiv 0 \quad \forall k \ge 1, \quad \text{Throughput}(\mathcal{P}) = \frac{1}{T_{\text{process}}}$$

Partition throughput is conserved unconditionally.

### 2.3 The Rate-Limited Canary Redrive Throttle Law

Let $C_{\text{active}}$ be the sustainable processing capacity (messages/second) of the target consumer cluster, and let $\lambda_{\text{live}}$ be the current live production event ingress rate.

During redrive of $N_{\text{dlq}}$ dead-lettered messages, the allowable redrive injection rate $\lambda_{\text{redrive}}$ MUST satisfy the **Headroom Invariant**:

$$\lambda_{\text{redrive}} + \lambda_{\text{live}} \le C_{\text{active}} \cdot (1 - \rho_{\text{headroom}})$$

Where $\rho_{\text{headroom}} \in [0.15, 0.30]$ is the reserved capacity cushion for traffic spikes. The maximum injection rate is bounded by:

$$\lambda_{\text{redrive}} \le \min\left(R_{\text{max\_admin}}, \, \alpha \cdot \max(0, \, C_{\text{active}} \cdot (1 - \rho_{\text{headroom}}) - \lambda_{\text{live}})\right)$$

Where $\alpha \le 0.10$ guarantees redrive traffic consumes at most $10\%$ of available cluster headroom.

### 2.4 Redrive Circuit-Breaker Interruption Condition

During any automated or manual redrive batch, a sliding verification window of size $W \ge 20$ monitors redrive execution outcomes:

$$\text{ErrorRate}(W) = \frac{1}{W} \sum_{j=1}^{W} \mathbb{I}(\text{Result}_j = \text{FAILED})$$

The **Redrive Circuit-Breaker Law** mandates:

$$\text{ErrorRate}(W) > \Theta_{\text{trip}} \implies \text{HALT\_REDRIVE\_IMMEDIATELY}$$

Where the trip threshold is strictly pinned: $\Theta_{\text{trip}} = 0.02$ ($2.0\%$). If tripped, the redrive engine freezes remaining redrive dispatches, alerts operators with the diagnostic IDs of the recurrent failures, and prevents the redrive from triggering a secondary cascading outage.

---

## 3. Complete Production-Ready TypeScript Implementation: `AgenticDeadLetterQueueEngine`

This zero-dependency, production-grade TypeScript implementation encapsulates the entire DLQ lifecycle: error classification, diagnostic failure enveloping, non-blocking exponential backoff scheduling with decorrelated jitter, canary redrive gating, and circuit-breaker monitoring.

```typescript
// agentic-dlq-engine.ts - Industrial Dead Letter Queue, Poison Pill Quarantine & Redrive Engine
import * as crypto from 'node:crypto';

export type ErrorClassification =
  | 'DETERMINISTIC_SCHEMA'
  | 'DETERMINISTIC_BUSINESS'
  | 'TRANSIENT_DOWNSTREAM'
  | 'TRANSIENT_RESOURCE'
  | 'UNKNOWN';

export interface MessageEnvelope<T = unknown> {
  readonly id: string;
  readonly topic: string;
  readonly partition?: number;
  readonly offset?: string;
  readonly payload: T;
  readonly headers: Record<string, string>;
  readonly timestamp: number;
}

export interface DiagnosticDLQEnvelope<T = unknown> {
  readonly dlqId: string;
  readonly originalMessageId: string;
  readonly topic: string;
  readonly payload: T;
  readonly payloadSha256: string;
  readonly attemptCount: number;
  readonly errorClassification: ErrorClassification;
  readonly errorMessage: string;
  readonly errorStack?: string;
  readonly originalHeaders: Record<string, string>;
  readonly traceparent: string;
  readonly consumerId: string;
  readonly hostname: string;
  readonly quarantinedAt: number;
  readonly status: 'QUARANTINED' | 'CANARY_TESTING' | 'RESOLVED' | 'UNRECOVERABLE';
}

export interface DLQPolicy {
  readonly maxAttempts: number;
  readonly inlineRetryLimit: number;
  readonly retryDelaysSec: readonly number[]; // e.g. [10, 60, 300]
  readonly redriveCanaryBatchSize: number;    // e.g. 5
  readonly redriveRatePerSec: number;        // Token bucket rate
  readonly circuitBreakerThreshold: number;  // 0.02 (2% error rate)
  readonly circuitBreakerMinSamples: number; // 20
}

export interface RedriveReport {
  readonly totalQuarantined: number;
  readonly canaryAttempted: number;
  readonly canarySucceeded: number;
  readonly bulkAttempted: number;
  readonly bulkSucceeded: number;
  readonly circuitTripped: boolean;
  readonly abortReason?: string;
  readonly failedIds: string[];
}

/**
 * Industrial Agentic Dead Letter Queue & Resilient Redrive Engine
 */
export class AgenticDeadLetterQueueEngine {
  private readonly policy: DLQPolicy;
  private readonly consumerId: string;
  private readonly hostname: string;
  private readonly dlqStorage = new Map<string, DiagnosticDLQEnvelope<unknown>>();

  constructor(consumerId: string, policyPartial?: Partial<DLQPolicy>) {
    this.consumerId = consumerId;
    this.hostname = process.env.HOSTNAME || 'agent-worker-node';
    this.policy = {
      maxAttempts: 4,
      inlineRetryLimit: 1,
      retryDelaysSec: [10, 60, 300],
      redriveCanaryBatchSize: 5,
      redriveRatePerSec: 25,
      circuitBreakerThreshold: 0.02,
      circuitBreakerMinSamples: 20,
      ...policyPartial,
    };
  }

  /**
   * Evaluates whether an error is deterministic (poison pill) or transient.
   */
  public classifyError(error: unknown): ErrorClassification {
    if (!error) return 'UNKNOWN';

    const err = error as { name?: string; message?: string; status?: number; code?: string };
    const msg = (err.message || '').toLowerCase();
    const name = err.name || '';
    const code = err.code || '';
    const status = err.status || 0;

    // Syntax, Deserialization, or Schema Validation Failures
    if (
      name === 'SyntaxError' ||
      name === 'ZodError' ||
      name === 'ValidationError' ||
      msg.includes('unexpected token') ||
      msg.includes('invalid json') ||
      msg.includes('schema mismatch') ||
      msg.includes('cannot read property')
    ) {
      return 'DETERMINISTIC_SCHEMA';
    }

    // Business Invariant Rejections (Bad input data that will never succeed)
    if (
      status === 400 ||
      status === 422 ||
      code === 'ERR_BAD_REQUEST' ||
      msg.includes('invalid account') ||
      msg.includes('entity not found') ||
      msg.includes('violates foreign key')
    ) {
      return 'DETERMINISTIC_BUSINESS';
    }

    // Transient Network, Downstream Timeouts, or Rate Limits
    if (
      status === 429 ||
      status === 503 ||
      status === 504 ||
      code === 'ETIMEDOUT' ||
      code === 'ECONNRESET' ||
      code === 'ECONNREFUSED' ||
      msg.includes('timeout') ||
      msg.includes('rate limit')
    ) {
      return 'TRANSIENT_DOWNSTREAM';
    }

    // Database Deadlocks or Connection Exhaustion
    if (
      code === '40P01' || // PostgreSQL Deadlock Detected
      code === '53300' || // Too Many Connections
      msg.includes('deadlock') ||
      msg.includes('connection pool')
    ) {
      return 'TRANSIENT_RESOURCE';
    }

    return 'UNKNOWN';
  }

  /**
   * Evaluates an execution failure and determines routing: DLQ Quarantine vs Non-Blocking Retry.
   */
  public handleFailure<T>(
    message: MessageEnvelope<T>,
    error: unknown,
    currentAttempt: number
  ): { action: 'ROUTE_TO_DLQ' | 'ENQUEUE_RETRY'; delaySec?: number; envelope?: DiagnosticDLQEnvelope<T> } {
    const classification = this.classifyError(error);
    const isDeterministic =
      classification === 'DETERMINISTIC_SCHEMA' || classification === 'DETERMINISTIC_BUSINESS';

    // Rule 1: Deterministic errors bypass all retries and enter DLQ immediately.
    // Rule 2: Exceeded maxAttempts enters DLQ.
    if (isDeterministic || currentAttempt >= this.policy.maxAttempts) {
      const envelope = this.createDiagnosticEnvelope(message, error, classification, currentAttempt);
      this.dlqStorage.set(envelope.dlqId, envelope as DiagnosticDLQEnvelope<unknown>);
      return { action: 'ROUTE_TO_DLQ', envelope };
    }

    // Calculate non-blocking delayed retry interval with decorrelated jitter
    const delayIndex = Math.min(currentAttempt - 1, this.policy.retryDelaysSec.length - 1);
    const baseDelay = this.policy.retryDelaysSec[delayIndex];
    // Add ±20% full jitter to eliminate retry wave synchronization
    const jitterFactor = 0.8 + Math.random() * 0.4;
    const finalDelaySec = Math.max(1, Math.round(baseDelay * jitterFactor));

    return { action: 'ENQUEUE_RETRY', delaySec: finalDelaySec };
  }

  /**
   * Synthesizes an immutable diagnostic envelope preserving full context & W3C traceparent.
   */
  public createDiagnosticEnvelope<T>(
    message: MessageEnvelope<T>,
    error: unknown,
    classification: ErrorClassification,
    attempts: number
  ): DiagnosticDLQEnvelope<T> {
    const rawPayload = typeof message.payload === 'string'
      ? message.payload
      : JSON.stringify(message.payload);

    const hash = crypto.createHash('sha256').update(rawPayload).digest('hex');
    const dlqId = `dlq_${crypto.randomUUID()}`;

    const err = error instanceof Error ? error : new Error(String(error));
    const traceparent = message.headers['traceparent'] || `00-${crypto.randomBytes(16).toString('hex')}-${crypto.randomBytes(8).toString('hex')}-01`;

    return {
      dlqId,
      originalMessageId: message.id,
      topic: message.topic,
      payload: message.payload,
      payloadSha256: hash,
      attemptCount: attempts,
      errorClassification: classification,
      errorMessage: err.message || 'Unknown processing failure',
      errorStack: err.stack,
      originalHeaders: { ...message.headers },
      traceparent,
      consumerId: this.consumerId,
      hostname: this.hostname,
      quarantinedAt: Date.now(),
      status: 'QUARANTINED',
    };
  }

  /**
   * Executes rate-limited Canary Redrive with circuit-breaker trip protection.
   */
  public async executeRedrive(
    targetTopic: string,
    replayer: (message: MessageEnvelope<unknown>) => Promise<boolean>
  ): Promise<RedriveReport> {
    const candidates = Array.from(this.dlqStorage.values()).filter(
      (env) => env.topic === targetTopic && env.status === 'QUARANTINED'
    );

    const report: RedriveReport = {
      totalQuarantined: candidates.length,
      canaryAttempted: 0,
      canarySucceeded: 0,
      bulkAttempted: 0,
      bulkSucceeded: 0,
      circuitTripped: false,
      failedIds: [],
    };

    if (candidates.length === 0) {
      return report;
    }

    // Phase 1: Canary Dry-Run Verification (Sub-sample evaluation)
    const canaryBatch = candidates.slice(0, this.policy.redriveCanaryBatchSize);
    for (const envelope of canaryBatch) {
      (envelope as { status: string }).status = 'CANARY_TESTING';
      (report as { canaryAttempted: number }).canaryAttempted++;

      const success = await this.dispatchReplay(envelope, replayer);
      if (success) {
        (report as { canarySucceeded: number }).canarySucceeded++;
        (envelope as { status: string }).status = 'RESOLVED';
      } else {
        (report as { failedIds: string[] }).failedIds.push(envelope.dlqId);
        (envelope as { status: string }).status = 'QUARANTINED';
      }
    }

    // Check Canary Pass Rate: If canary fails by >= 20%, abort immediately
    const canaryFailureRate =
      (report.canaryAttempted - report.canarySucceeded) / Math.max(1, report.canaryAttempted);
    if (canaryFailureRate > 0.20) {
      (report as { circuitTripped: boolean }).circuitTripped = true;
      (report as { abortReason?: string }).abortReason = `Canary failure rate too high: ${(canaryFailureRate * 100).toFixed(1)}%`;
      return report;
    }

    // Phase 2: Token-Bucket Governed Bulk Redrive
    const remainingCandidates = candidates.slice(this.policy.redriveCanaryBatchSize);
    const delayBetweenMs = 1000 / this.policy.redriveRatePerSec;
    const slidingWindow: boolean[] = [];

    for (const envelope of remainingCandidates) {
      // Circuit Breaker Evaluation
      if (slidingWindow.length >= this.policy.circuitBreakerMinSamples) {
        const failureCount = slidingWindow.filter((res) => !res).length;
        const currentErrorRate = failureCount / slidingWindow.length;
        if (currentErrorRate > this.policy.circuitBreakerThreshold) {
          (report as { circuitTripped: boolean }).circuitTripped = true;
          (report as { abortReason?: string }).abortReason = `Circuit Breaker Tripped! Rolling error rate ${(currentErrorRate * 100).toFixed(2)}% exceeded threshold.`;
          break;
        }
      }

      (report as { bulkAttempted: number }).bulkAttempted++;
      const success = await this.dispatchReplay(envelope, replayer);
      slidingWindow.push(success);
      if (slidingWindow.length > 50) slidingWindow.shift();

      if (success) {
        (report as { bulkSucceeded: number }).bulkSucceeded++;
        (envelope as { status: string }).status = 'RESOLVED';
      } else {
        (report as { failedIds: string[] }).failedIds.push(envelope.dlqId);
        (envelope as { status: string }).status = 'QUARANTINED';
      }

      // Rate limiting token pause
      await new Promise((r) => setTimeout(r, delayBetweenMs));
    }

    return report;
  }

  private async dispatchReplay(
    envelope: DiagnosticDLQEnvelope<unknown>,
    replayer: (message: MessageEnvelope<unknown>) => Promise<boolean>
  ): Promise<boolean> {
    try {
      const redriveMessage: MessageEnvelope<unknown> = {
        id: envelope.originalMessageId,
        topic: envelope.topic,
        payload: envelope.payload,
        headers: {
          ...envelope.originalHeaders,
          'x-redrive-attempt': 'true',
          'x-dlq-source-id': envelope.dlqId,
          traceparent: envelope.traceparent,
        },
        timestamp: Date.now(),
      };
      return await replayer(redriveMessage);
    } catch {
      return false;
    }
  }

  public getQuarantined(dlqId: string): DiagnosticDLQEnvelope<unknown> | undefined {
    return this.dlqStorage.get(dlqId);
  }

  public listPending(topic?: string): DiagnosticDLQEnvelope<unknown>[] {
    return Array.from(this.dlqStorage.values()).filter(
      (m) => m.status === 'QUARANTINED' && (!topic || m.topic === topic)
    );
  }
}
```

---

## 4. 6-State Dead-Letter & Redrive Finite-State Machine (FSM)

Every message undergoing asynchronous ingestion follows a strictly verified finite-state machine. Transitions outside this graph are illegal and must be rejected:

```
  ┌──────────────┐
  │ 1. INGESTED  │ ── (Deliver to Domain Handler) ──► ┌───────────────┐
  └──────────────┘                                    │ 2. PROCESSING │
         ▲                                            └───────┬───────┘
         │                                                    │
  (Re-Ingest from Retry Topic)                       ┌────────┴────────┐
         │                                           │                 │
         │                               (Transient & k < Kmax)   (Fatal or k >= Kmax)
         │                                           │                 │
  ┌──────────────┐                                   ▼                 ▼
  │   RETRY_     │                            ┌─────────────┐   ┌───────────────┐
  │  SCHEDULED   │                            │  EVALUATE   │   │ 3. QUARANTINED│
  └──────────────┘                            │ CLASSIFIER  │   │     (DLQ)     │
                                              └─────────────┘   └───────┬───────┘
                                                                        │
                                                         (Admin Canary Redrive Trigger)
                                                                        │
                                                                        ▼
                                                                ┌───────────────┐
                                                                │4. CANARY_TEST │
                                                                └───────┬───────┘
                                                                        │
                                                      ┌─────────────────┴─────────────────┐
                                                      │                                   │
                                            (Canary Pass Rate >= 80%)            (Failure > 20%)
                                                      │                                   │
                                                      ▼                                   ▼
                                              ┌───────────────┐                   ┌───────────────┐
                                              │5. BULK_REDRIVE│                   │6. CIRCUIT_    │
                                              │ (Token Bucket)│                   │   TRIPPED     │
                                              └───────┬───────┘                   │(Halt & Alert) │
                                                      │                           └───────────────┘
                                         (Error Rate > 2% Mid-Run)
                                                      │
                                                      └───────────────────────────────────┘
```

### State Transition Invariant Table

| Initial State | Event Trigger | Guard Condition | Next State | Architectural Side Effect |
| :--- | :--- | :--- | :--- | :--- |
| `INGESTED` | Worker pulls message | Broker delivers payload | `PROCESSING` | Delivery count tracked; traceparent propagated. |
| `PROCESSING` | Exception raised | Deterministic syntax or schema error | `QUARANTINED` | Direct DLQ route; envelope formatted; primary offset committed. |
| `PROCESSING` | Exception raised | Transient error and $\kappa < K_{\text{max}}$ | `RETRY_SCHEDULED` | Emitted to `topic.retry-Xs`; primary offset committed. |
| `PROCESSING` | Exception raised | Transient error and $\kappa \ge K_{\text{max}}$ | `QUARANTINED` | Max retries exhausted; envelope stored in DLQ table. |
| `PROCESSING` | Success | Normal business completion | `ACKNOWLEDGED` | Primary offset committed; memory released. |
| `RETRY_SCHEDULED`| Delay expires | Backoff timer passes | `INGESTED` | Pulled from retry topic with incremented attempt counter. |
| `QUARANTINED` | Redrive initiated | Operator or Agent initiates replay | `CANARY_TEST` | Canary sample ($N=5$) dispatched; status flagged. |
| `CANARY_TEST` | Canary batch finishes | Success rate $< 80\%$ | `CIRCUIT_TRIPPED`| Redrive halted immediately; alert dispatched to PagerDuty. |
| `CANARY_TEST` | Canary batch finishes | Success rate $\ge 80\%$ | `BULK_REDRIVE` | Dispatches remaining messages under token-bucket limiter. |
| `BULK_REDRIVE` | Mid-run batch check | Rolling error rate $> 2.0\%$ | `CIRCUIT_TRIPPED`| Redrive halted; partial progress saved; poison pills isolated. |
| `BULK_REDRIVE` | All messages finish | Error rate $\le 2.0\%$ | `COMPLETED` | Quarantined records marked `RESOLVED`. |

---

## 5. Cross-Language Production Idioms & Hard Anti-Patterns

### 5.1 Golang: Non-Blocking Kafka Retry Topics & Poison Pill Quarantine

```go
// Industrial Go Kafka Consumer with Poison Pill Header Enrichment & Non-Blocking Retry
package consumer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/segmentio/kafka-go"
)

type ErrorCategory int
const (
	DeterministicError ErrorCategory = iota
	TransientError
)

type DiagnosticEnvelope struct {
	DLQID          string    `json:"dlq_id"`
	OriginalTopic  string    `json:"original_topic"`
	PayloadHash    string    `json:"payload_hash"`
	ErrorCategory  string    `json:"error_category"`
	ErrorMessage   string    `json:"error_message"`
	AttemptCount   int       `json:"attempt_count"`
	QuarantinedAt  time.Time `json:"quarantined_at"`
}

func ProcessMessage(ctx context.Context, reader *kafka.Reader, dlqWriter *kafka.Writer, retryWriter *kafka.Writer, msg kafka.Message) error {
	var payload map[string]interface{}
	// Step 1: Detect deterministic poison pill (syntax/deserialization)
	if err := json.Unmarshal(msg.Value, &payload); err != nil {
		return routeToDLQ(ctx, dlqWriter, msg, DeterministicError, err, 1)
	}

	attempt := extractAttempt(msg)
	maxAttempts := 3

	// Step 2: Execute domain processing
	err := executeBusinessLogic(ctx, payload)
	if err == nil {
		return reader.CommitMessages(ctx, msg)
	}

	// Step 3: Route based on attempt threshold
	if attempt >= maxAttempts {
		return routeToDLQ(ctx, dlqWriter, msg, TransientError, err, attempt)
	}

	// Step 4: Non-blocking delayed retry
	return routeToDelayedRetry(ctx, retryWriter, msg, attempt+1)
}

func routeToDLQ(ctx context.Context, writer *kafka.Writer, msg kafka.Message, cat ErrorCategory, err error, attempt int) error {
	h := sha256.Sum256(msg.Value)
	catStr := "TRANSIENT"
	if cat == DeterministicError {
		catStr = "DETERMINISTIC"
	}

	env := DiagnosticEnvelope{
		DLQID:         fmt.Sprintf("dlq_%d", time.Now().UnixNano()),
		OriginalTopic: msg.Topic,
		PayloadHash:   hex.EncodeToString(h[:]),
		ErrorCategory: catStr,
		ErrorMessage:  err.Error(),
		AttemptCount:  attempt,
		QuarantinedAt: time.Now().UTC(),
	}
	envBytes, _ := json.Marshal(env)

	dlqMsg := kafka.Message{
		Key:   msg.Key,
		Value: msg.Value,
		Headers: append(msg.Headers,
			kafka.Header{Key: "x-dlq-diagnostic", Value: envBytes},
			kafka.Header{Key: "x-quarantined", Value: []byte("true")},
		),
	}
	return writer.WriteMessages(ctx, dlqMsg)
}
```

### 5.2 PostgreSQL: Durable Dead-Letter Table Schema & Lock-Free Keyset Redrive

```sql
-- PostgreSQL Production DLQ Schema with JSONB Diagnostics & Keyset Redrive Fencing
CREATE TABLE dead_letter_events (
    dlq_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    original_message_id VARCHAR(128) NOT NULL,
    topic VARCHAR(255) NOT NULL,
    partition INT,
    broker_offset BIGINT,
    payload JSONB NOT NULL,
    payload_sha256 CHAR(64) NOT NULL,
    attempt_count INT NOT NULL DEFAULT 1,
    error_classification VARCHAR(64) NOT NULL,
    error_message TEXT NOT NULL,
    error_stack TEXT,
    traceparent VARCHAR(128),
    consumer_id VARCHAR(128) NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'QUARANTINED',
    quarantined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT valid_status CHECK (status IN ('QUARANTINED', 'CANARY_TESTING', 'RESOLVED', 'ABORTED'))
);

CREATE INDEX idx_dlq_topic_status ON dead_letter_events (topic, status, quarantined_at);
CREATE INDEX idx_dlq_sha256 ON dead_letter_events (payload_sha256);

-- Lock-Free Batched Keyset Redrive Fetcher with SKIP LOCKED
-- Fetches up to 25 items for redrive without blocking concurrent workers
WITH candidates AS (
    SELECT dlq_id
    FROM dead_letter_events
    WHERE topic = 'orders.v1'
      AND status = 'QUARANTINED'
    ORDER BY quarantined_at ASC
    LIMIT 25
    FOR UPDATE SKIP LOCKED
)
UPDATE dead_letter_events e
SET status = 'CANARY_TESTING',
    updated_at = NOW()
FROM candidates c
WHERE e.dlq_id = c.dlq_id
RETURNING e.dlq_id, e.original_message_id, e.payload, e.traceparent;
```

---

## 6. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Category | Verification Method | Enforcement Invariant |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **Poison Pill Interception** | Unit & Fuzz Testing | SyntaxError & malformed JSON bypass retries and transition directly to DLQ on attempt 1. Naive `nack(requeue = true)` without attempt bounds is totally banned. |
| **Gate 2** | **Partition Concurrency** | Benchmarking / Latency Assertion | Zero in-line wall-clock sleeps in primary partition consumer loops. Primary offset MUST advance within $\le 100\text{ms}$ upon transient failure via delayed retry topic. |
| **Gate 3** | **Diagnostic Completeness**| Schema Assertion | Every DLQ message contains SHA-256 payload digest, classified failure category, root-cause message, stack trace, and W3C traceparent. |
| **Gate 4** | **Canary Redrive Gate** | Integration Test | Automated redrives MUST execute canary verification ($N \ge 5$) and halt immediately if canary failure exceeds $20\%$. |
| **Gate 5** | **Circuit-Breaker Safety**| Fault Injection Test | During bulk redrives, if rolling error rate exceeds $2.0\%$, the redrive engine trips the circuit breaker and aborts further replay dispatches. |
| **Gate 6** | **Idempotent Replay** | Property-Based Test | Redriving an already-committed message produces $\Delta \text{State} \equiv 0$. Invariant: $f(f(x)) \equiv f(x)$ with zero double-billing or phantom rows. |
