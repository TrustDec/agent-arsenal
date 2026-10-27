---
description: Agentic circuit breakers, sliding-window failure rate detectors, bulkhead isolation, adaptive concurrency limits (Vegas/AIMD/Gradient), graceful load shedding, hedged requests, and multi-tier fallback degradation across Go, TypeScript, Node.js, Python, PostgreSQL, Redis, MCP servers, Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{circuit,breaker,bulkhead,resilience,fallback,hedging,shedding,concurrency,retry,timeout}*.*,**/src/resilience/**/*.{ts,js,go,rs,py},**/src/services/**/*.{ts,js,go,rs,py},**/src/client/**/*.{ts,js,go,rs,py},**/lib/resilience/**/*.{ts,js,go,rs,py}
alwaysApply: false
---

# Agentic Circuit Breakers, Adaptive Bulkheading & Graceful Load Shedding Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design fault-tolerant HTTP/gRPC clients, LLM API gateway integrations, database connection wrappers, vector search callers, or microservice service-to-service communication layers across Go, TypeScript, Node.js, Python, or Rust. Eliminate the "Cascading Latency Avalanche & Thread Starvation Disaster" (where downstream slowdowns cause upstream thread/goroutine pools to block indefinitely until memory exhausts and healthchecks fail), the "Retry Storm & Self-Inflicted Thundering Herd Amplification" (where unconstrained client retries multiply traffic against an already saturated downstream dependency), the "Unbounded Concurrency & Bulkhead Breach" (where a secondary non-critical integration consumes 100% of connection capacity and topples core transaction flows), the "Little's Law Latency Spiral & Lack of Adaptive Concurrency" (where static concurrency caps fail to adapt to ballooning latency $L = \lambda W$), the "Half-Open Stampede & Premature Recovery Collapse" (where circuit breakers transition from OPEN to HALF_OPEN and instantly admit 100% of waiting traffic, immediately crashing recovering services), and the "Fail-Closed Total Outage Trap" (where circuit trips throw unhandled exceptions instead of activating multi-tier degraded fallbacks) by establishing a strict 5-Tier Circuit Breaker & Concurrency Governance Ladder, sliding-window failure rate detectors, semaphore-isolated bulkheads, gradient-based adaptive concurrency limits, retry budgets, and multi-tier fallback cascades.

---

## 1. Architectural Taxonomy: The 6 Cascading Failure & Capacity Catastrophes vs The 5-Tier Circuit Governance Ladder

When autonomous coding agents implement client HTTP callers, database adapters, or external LLM API clients, LLMs consistently write naive try-catch retry loops:

```typescript
// ❌ CATASTROPHIC LLM CLIENT IMPLEMENTATION
async function callExternalService(payload: any) {
  // VULN 1: No timeout - hangs indefinitely if remote socket stays silent!
  // VULN 2: No bulkhead - unbounded parallel executions exhaust file descriptors & memory!
  // VULN 3: Toxic retry storm: 3 rapid retries amplify traffic by 300% on downstream outage!
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch('https://api.external.com/v1/predict', {
        method: 'POST',
        body: JSON.stringify(payload),
      });
      return await res.json();
    } catch (err) {
      if (attempt === 2) throw err; // VULN 4: Hard crash, zero degraded fallback!
    }
  }
}
```

In high-concurrency microservices, multi-agent swarms, or real-time web applications, this naive pattern triggers six catastrophic failure modes:

- **The "Cascading Latency Avalanche & Upstream Thread/Goroutine Pool Starvation Disaster"**:
  - A downstream LLM provider, vector database, or payment gateway experiences severe degradation: p99 latency climbs from 80ms to 25 seconds.
  - Upstream web servers (Node.js event loop, Go goroutines, Java worker threads) continue accepting new client requests and dispatching calls to the degraded dependency without timeouts or concurrency barriers.
  - Within seconds, thousands of in-flight requests accumulate, holding open TCP sockets, file descriptors, and heap memory allocations.
  - The upstream server's worker pool reaches capacity: incoming Kubernetes liveness/readiness probes (`/healthz`, `/readyz`) time out because no threads/event loops are available to respond.
  - Kubernetes marks the upstream pods unready or kills them via `SIGKILL`. Traffic shifts to the remaining pods, immediately crashing them. A minor hiccup in a non-essential third-party API has cascaded into a complete cluster-wide outage.
  - Invariant: Every outbound dependency call MUST enforce an absolute timeout budget, an isolated concurrency bulkhead, and a fast-failing circuit breaker that terminates calls in 0 milliseconds once downstream failure exceeds threshold $\Theta_{\text{trip}}$.

- **The "Retry Storm & Self-Inflicted Thundering Herd Amplification (The Toxic Retry Trap)"**:
  - Downstream service experiences transient CPU saturation, dropping 15% of requests with 503 or 504.
  - Hundreds of upstream client instances, executing naive retry loops (`for attempt < 3`), immediately re-issue failed requests.
  - The aggregate request volume hitting the downstream service instantaneously doubles or triples: amplification factor $A = 1 + \sum_{k=1}^R P_{\text{retry}}^k$.
  - Downstream CPU hits 100%, queue memory overflows, and the service crashes completely. What was a momentary 15% transient degradation is escalated into a sustained, multi-hour outage entirely driven by self-inflicted client retry traffic.
  - Invariant: Retries MUST be bounded by a global **Retry Budget** (maximum 10% of total outbound requests), enforced with full decorrelated exponential jitter, and strictly suppressed when the circuit breaker is in `OPEN` or `HALF_OPEN` states.

- **The "Unbounded Concurrency & Bulkhead Breach (Compartmentalization Failure)"**:
  - A monolith or microservice interacts with both critical services (Auth, Checkout, Core DB) and non-critical services (Avatar Generation, Marketing Webhooks, Analytics Enrichment).
  - All outbound calls share a single default HTTP client and global connection pool.
  - When the non-critical Marketing Webhook server hangs, all shared HTTP client connections become saturated with waiting webhook requests.
  - Core Checkout and Authentication requests cannot acquire a connection from the pool and fail with `ConnectionPoolTimeoutException`.
  - Invariant: Dependencies MUST be compartmentalized using **Bulkheads** (isolated semaphores with bounded waiting queues). A failure or hang in dependency $B$ MUST never consume concurrency capacity reserved for dependency $A$.

- **The "Little's Law Latency Spiral & Lack of Adaptive Concurrency (Load Shedding Deficit)"**:
  - By Little's Law ($L = \lambda W$), where $L$ is in-flight concurrency, $\lambda$ is arrival throughput, and $W$ is response latency: when downstream latency $W$ increases by $10\times$, in-flight concurrency $L$ must increase by $10\times$ to process the same arrival rate.
  - Static concurrency limits fail: if set too high, the system enters a brownout memory collapse; if set too low, throughput is throttled during normal fast operation.
  - Systems without **Adaptive Concurrency Limits** (e.g. Netflix Vegas or Gradient algorithms) fail to detect rising round-trip times (RTT) and continue queuing requests until queues overflow.
  - Invariant: Services MUST implement dynamic queue length boundaries and Gradient/Vegas adaptive concurrency limits that automatically contract permissible in-flight concurrency $L_{\text{max}}$ when measured RTT drifts above baseline $\text{RTT}_{\text{min}}$, rejecting excess low-priority traffic at the ingress boundary (Graceful Load Shedding).

- **The "Half-Open Stampede & Premature Recovery Collapse"**:
  - A tripped circuit breaker waits for a fixed cool-down period (e.g., 30 seconds) and transitions from `OPEN` to `HALF_OPEN`.
  - Upon entering `HALF_OPEN`, the breaker immediately allows all queued or newly arriving requests to flood the downstream service simultaneously.
  - The downstream service, which was in the middle of cold startup or database index warming, is struck by a thundering herd and immediately crashes again, bouncing back to `OPEN`.
  - The system becomes trapped in a perpetual oscillation loop (`OPEN` $\leftrightarrow$ `HALF_OPEN`), never permitting downstream recovery.
  - Invariant: The `HALF_OPEN` state MUST permit strictly **one** (or a strictly bounded canary trial $k \le 3$) probe request at a time. All other incoming traffic during `HALF_OPEN` MUST continue executing fallback paths until the canary confirms health across $M_{\text{success}}$ consecutive successes.

- **The "Fail-Closed Total Outage Trap (Missing Graceful Degradation & Static Fallback)"**:
  - When downstream services trip a circuit breaker, naive code re-throws the raw error or returns generic HTTP 500 responses to end users.
  - Features that could comfortably operate in degraded modes (e.g., personalized recommendations falling back to cached popular items; vector search falling back to keyword BM25; AI summarization falling back to raw text excerpt) fail completely.
  - Invariant: Circuit breakers MUST provide a structured **Fallback Cascade**: Level 1: In-process L1 cache $\to$ Level 2: Stale L2 cache with `X-Degraded: Stale` flag $\to$ Level 3: Deterministic synthetic default $\to$ Level 4: Asynchronous durable queue (Transactional Outbox) $\to$ Terminal: Graceful HTTP 200/202 degraded payload.

---

### The 5-Tier Circuit Breaker & Concurrency Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────┐
│ Tier 4: Multi-Tier Degradation, OpenTelemetry & Hedged Requests        │
│   • Multi-tier fallback hierarchy (L1 -> Stale L2 -> Synthetic Default)│
│   • Hedged speculative requests for p99 tail latency reduction          │
│   • W3C OpenTelemetry metrics & span baggage propagation               │
└────────────────────────────────────▲───────────────────────────────────┘
                                     │
┌────────────────────────────────────┴───────────────────────────────────┐
│ Tier 3: Adaptive Concurrency Limits & Ingress Load Shedding            │
│   • Gradient / TCP Vegas adaptive concurrency limits based on RTT drift │
│   • Priority-based load shedding (Critical vs Sheddable traffic)       │
│   • Token-bucket retry budget enforcement (retries <= 10% of total)    │
└────────────────────────────────────▲───────────────────────────────────┘
                                     │
┌────────────────────────────────────┴───────────────────────────────────┐
│ Tier 2: Isolated Bulkheads & Queue Compartmentalization                │
│   • Per-dependency semaphore concurrency boundaries                    │
│   • Bounded waiting queues with fast-rejection on queue saturation     │
│   • Strict zero-leak lifecycle guarantees via try/finally guards      │
└────────────────────────────────────▲───────────────────────────────────┘
                                     │
┌────────────────────────────────────┴───────────────────────────────────┐
│ Tier 1: Three-State Circuit Breaker FSM (Closed -> Open -> Half-Open)  │
│   • Sliding-window error rate and slow-call rate tracking              │
│   • Canary pacing in HALF_OPEN (strictly 1 probe request at a time)    │
│   • Immediate fast-fail (0ms) during OPEN state with fallback dispatch │
└────────────────────────────────────▲───────────────────────────────────┘
                                     │
┌────────────────────────────────────┴───────────────────────────────────┐
│ Tier 0: Strict Deadlines, Cancellation Propagation & Hard Timeouts     │
│   • Mandatory AbortController / context.WithTimeout on every I/O call   │
│   • No un-timed network sockets or unbounded waiting promises         │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical & Formal Invariant Calculus

### 2.1 Sliding Window Error Rate Calculus & Trip Thresholds

Let time be divided into a sliding window of $N$ discrete execution buckets or a rolling window of duration $T_{\text{window}}$ (e.g., $T_{\text{window}} = 10\text{s}$ divided into 10 one-second slices).

Each completed execution $i$ records:
- Status $S_i \in \{\text{SUCCESS}, \text{FAILURE}, \text{SLOW}\}$
- Latency $L_i$ in milliseconds

Given slow call latency threshold $L_{\text{slow}}$, execution $i$ is classified as slow if:
$$\text{isSlow}(i) = \mathbb{I}(L_i \ge L_{\text{slow}})$$

Within the current sliding window, let $N_{\text{total}}$ be total recorded calls, $N_{\text{failed}}$ be failed calls, and $N_{\text{slow}}$ be slow calls:
$$N_{\text{total}} = \sum_{i \in W} 1, \quad N_{\text{failed}} = \sum_{i \in W} \mathbb{I}(S_i = \text{FAILURE}), \quad N_{\text{slow}} = \sum_{i \in W} \text{isSlow}(i)$$

The aggregate failure rate $R_{\text{fail}}$ and slow-call rate $R_{\text{slow}}$ are:
$$R_{\text{fail}} = \frac{N_{\text{failed}}}{N_{\text{total}}}, \quad R_{\text{slow}} = \frac{N_{\text{slow}}}{N_{\text{total}}}$$

**Trip Condition Invariant**: The circuit breaker transitions from `CLOSED` to `OPEN` if and only if:
$$N_{\text{total}} \ge N_{\text{min}} \quad \land \quad \left( R_{\text{fail}} \ge \Theta_{\text{trip}} \;\lor\; R_{\text{slow}} \ge \Theta_{\text{slow}} \right)$$

where:
- $N_{\text{min}}$ is the minimum sample volume (prevents tripping on a single transient error during low traffic, e.g. $N_{\text{min}} = 20$).
- $\Theta_{\text{trip}}$ is the error rate trip threshold (e.g., $0.50$, representing 50% failures).
- $\Theta_{\text{slow}}$ is the slow-call rate trip threshold (e.g., $0.75$, representing 75% calls exceeding $L_{\text{slow}}$).

### 2.2 Little's Law & Adaptive Gradient Concurrency Limits

According to Little's Law, the mean number of concurrent requests in a stable system $L$ equals the arrival rate $\lambda$ multiplied by the average latency $W$:
$$L = \lambda \cdot W$$

When downstream degradation increases latency from $W_0$ to $W_{\text{deg}}$, in-flight concurrency explodes if arrival rate $\lambda$ is maintained:
$$L_{\text{deg}} = \lambda \cdot W_{\text{deg}} = L_0 \cdot \frac{W_{\text{deg}}}{W_0}$$

To prevent upstream thread and memory starvation without manual tuning, the system dynamically adjusts its maximum allowable concurrency $C_t$ using the **Gradient Concurrency Algorithm**:

Let $\text{RTT}_{\text{min}}$ be the baseline observed latency (the minimum latency measured over a long rolling window, e.g. 5 minutes). Let $\text{RTT}_{\text{measured}}$ be the smoothed exponential moving average (EMA) of latency over the current sample window.

The gradient $G_t$ is defined as:
$$G_t = \frac{\text{RTT}_{\text{min}}}{\text{RTT}_{\text{measured}}}$$

- When downstream is healthy ($\text{RTT}_{\text{measured}} \approx \text{RTT}_{\text{min}}$), $G_t \approx 1.0$.
- When downstream experiences queue buildup ($\text{RTT}_{\text{measured}} > \text{RTT}_{\text{min}}$), $G_t < 1.0$.

The new concurrency limit $C_{t+1}$ is computed per evaluation interval:
$$C_{t+1} = \max\left( C_{\text{min}}, \; \min\left( C_{\text{max}}, \; C_t \cdot G_t + \beta \right) \right)$$

where:
- $\beta$ is a headroom buffer (e.g., $\beta = \sqrt{C_t}$ or a constant like $2.0$) allowing gradual exploration of capacity.
- $C_{\text{min}}$ is the absolute concurrency floor (e.g. $C_{\text{min}} = 5$).
- $C_{\text{max}}$ is the ceiling (e.g. $C_{\text{max}} = 500$).

**Load Shedding Condition**: If current in-flight concurrency $I_t \ge C_t$, newly arriving requests are immediately rejected at the ingress bulkhead with HTTP 429 / 503 (`X-Shed-Reason: AdaptiveConcurrencyLimitReached`) before any downstream socket is allocated.

### 2.3 Retry Storm Amplification Factor & Retry Budget Token Bucket

In a distributed system where $M$ clients retry failed requests up to $R$ times with failure probability $P_f$, the total expected request volume multiplier $A$ (Amplification Factor) is:
$$A = \sum_{k=0}^{R} P_f^k = \frac{1 - P_f^{R+1}}{1 - P_f}$$

If $P_f = 0.5$ and $R = 3$, $A = 1 + 0.5 + 0.25 + 0.125 = 1.875$ ($87.5\%$ traffic amplification). If downstream is already saturated, this guarantee crashes the system.

**The Retry Budget Invariant**:
Retries MUST draw from a dedicated **Token Bucket Retry Budget**:
- Let $T_{\text{regular}}$ be the stream of initial outbound calls. Each successful initial call deposits tokens into the retry bucket:
  $$\Delta B = \rho \cdot 1, \quad \text{where } \rho \le 0.10 \text{ (10\% retry ceiling)}$$
- A retry execution MUST consume 1 retry token ($B \leftarrow B - 1$).
- If $B \le 0$, retries are strictly **forbidden**: the client MUST fast-fail immediately without re-issuing the request.
- The maximum bucket capacity is bounded: $B_{\text{max}} = 100$.

### 2.4 Half-Open Canary Pacing & Step-Recovery Equation

When the cool-down timer $T_{\text{reset}}$ expires in state `OPEN`, the circuit transitions to `HALF_OPEN`.

To prevent the **Half-Open Stampede Disaster**, in-flight canary concurrency $K_{\text{canary}}$ in `HALF_OPEN` is strictly constrained:
$$K_{\text{canary}} = 1$$

All subsequent concurrent requests arriving while the canary probe is in-flight MUST NOT hit the downstream dependency. They MUST immediately execute the fallback path:
$$\forall \text{req} \in \text{Arrivals} \setminus \{\text{Probe}_1\}, \quad \text{Dispatch}(\text{req}) \to \text{FallbackCascade}$$

The circuit breaker transitions from `HALF_OPEN` to `CLOSED` if and only if $M_{\text{consecutive}}$ consecutive canary probes succeed:
$$\sum_{j=1}^{M_{\text{consecutive}}} \mathbb{I}(S_j = \text{SUCCESS}) = M_{\text{consecutive}} \quad (M_{\text{consecutive}} \ge 3)$$

If any single canary probe fails ($S_j = \text{FAILURE}$), the circuit instantly reverts to `OPEN` and resets the backoff timer with exponential scaling:
$$T_{\text{reset}}^{\text{next}} = \min(T_{\text{reset}}^{\text{max}}, \; T_{\text{reset}} \cdot 2)$$

---

## 3. Industrial Production TypeScript Reference Implementation: `AgenticCircuitBreakerEngine`

Below is the zero-dependency, production-ready implementation of the unified Circuit Breaker, Semaphore Bulkhead, Adaptive Concurrency Limiter, and Fallback Cascade engine.

```typescript
// src/resilience/circuit-breaker.ts
import { EventEmitter } from 'node:events';

export type CircuitState = 'CLOSED' | 'OPEN' | 'HALF_OPEN';

export interface CircuitBreakerOptions {
  failureThresholdPercentage: number; // e.g. 50 (50%)
  slowCallThresholdMs: number;         // e.g. 2000 (2s)
  slowCallRateThresholdPercentage: number; // e.g. 60 (60%)
  slidingWindowSize: number;           // e.g. 20 calls
  minimumNumberOfCalls: number;        // e.g. 10 calls before evaluation
  openDurationMs: number;              // Cool-down time before HALF_OPEN, e.g. 10000 (10s)
  maxHalfOpenCanaryCalls: number;      // e.g. 3 consecutive successes to heal
  bulkheadMaxConcurrent: number;       // Max in-flight executions, e.g. 50
  bulkheadMaxQueue: number;            // Max waiting callers before shedding, e.g. 20
  adaptiveConcurrencyEnabled?: boolean;// Enable RTT-based dynamic limit tuning
  minAdaptiveConcurrency?: number;     // Concurrency floor, e.g. 5
}

interface CallExecutionRecord {
  durationMs: number;
  success: boolean;
  isSlow: boolean;
  timestamp: number;
}

export class BulkheadRejectionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'BulkheadRejectionError';
  }
}

export class CircuitOpenError extends Error {
  constructor(public readonly openUntil: number) {
    super(`Circuit breaker is OPEN until ${new Date(openUntil).toISOString()}. Fast-failing.`);
    this.name = 'CircuitOpenError';
  }
}

export class AgenticCircuitBreakerEngine extends EventEmitter {
  private state: CircuitState = 'CLOSED';
  private openUntilTimestamp = 0;
  private readonly records: CallExecutionRecord[] = [];
  
  // Bulkhead state
  private activeExecutions = 0;
  private waitingQueue: Array<{
    resolve: () => void;
    reject: (err: Error) => void;
    timeoutId: NodeJS.Timeout;
  }> = [];

  // Half-open canary tracker
  private halfOpenSuccessCount = 0;
  private halfOpenInFlight = 0;

  // Adaptive concurrency & RTT baseline
  private currentConcurrencyLimit: number;
  private minObservedRttMs = Infinity;
  private smoothedRttMs = 0;

  // Retry Budget Token Bucket (max 100 tokens, 10% gain per success)
  private retryTokens = 20;
  private readonly maxRetryTokens = 100;

  constructor(
    public readonly name: string,
    private readonly opts: CircuitBreakerOptions
  ) {
    super();
    this.currentConcurrencyLimit = opts.bulkheadMaxConcurrent;
  }

  public getState(): CircuitState {
    if (this.state === 'OPEN' && Date.now() >= this.openUntilTimestamp) {
      this.transitionTo('HALF_OPEN');
    }
    return this.state;
  }

  public getMetrics() {
    return {
      name: this.name,
      state: this.getState(),
      activeExecutions: this.activeExecutions,
      queuedCallers: this.waitingQueue.length,
      adaptiveConcurrencyLimit: Math.round(this.currentConcurrencyLimit),
      minRttMs: this.minObservedRttMs === Infinity ? 0 : Math.round(this.minObservedRttMs),
      smoothedRttMs: Math.round(this.smoothedRttMs),
      retryTokensAvailable: Math.round(this.retryTokens),
    };
  }

  /**
   * Primary entry point: executes operation through Bulkhead, Circuit Breaker,
   * Adaptive Concurrency Limiter, and Fallback Cascade.
   */
  public async execute<T>(
    operation: (signal: AbortSignal) => Promise<T>,
    fallback?: (err: Error) => Promise<T> | T,
    timeoutMs: number = 5000
  ): Promise<T> {
    const currentState = this.getState();

    // 1. FAST-FAIL CIRCUIT OPEN CHECK
    if (currentState === 'OPEN') {
      const err = new CircuitOpenError(this.openUntilTimestamp);
      this.emit('callRejected', { reason: 'CIRCUIT_OPEN', error: err });
      if (fallback) return await fallback(err);
      throw err;
    }

    // 2. HALF-OPEN CANARY PACING GATE
    if (currentState === 'HALF_OPEN') {
      if (this.halfOpenInFlight >= 1) {
        // Only allow 1 canary probe at a time. All other traffic diverts to fallback
        const err = new CircuitOpenError(this.openUntilTimestamp);
        this.emit('callRejected', { reason: 'HALF_OPEN_CANARY_ACTIVE', error: err });
        if (fallback) return await fallback(err);
        throw err;
      }
      this.halfOpenInFlight++;
    }

    // 3. BULKHEAD ADMISSION & QUEUE BOUNDARY
    try {
      await this.acquireBulkheadSlot(timeoutMs);
    } catch (err: any) {
      if (currentState === 'HALF_OPEN') this.halfOpenInFlight--;
      this.emit('callRejected', { reason: 'BULKHEAD_SHEDDING', error: err });
      if (fallback) return await fallback(err);
      throw err;
    }

    // 4. TIMEOUT & CANCELLATION SENTINEL
    const ac = new AbortController();
    const timeoutHandle = setTimeout(() => {
      ac.abort(new Error(`Operation timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    const startTime = Date.now();
    let isSuccess = false;
    let callError: Error | null = null;

    try {
      const result = await operation(ac.signal);
      isSuccess = true;
      return result;
    } catch (err: any) {
      callError = err;
      throw err;
    } finally {
      clearTimeout(timeoutHandle);
      const durationMs = Date.now() - startTime;
      this.releaseBulkheadSlot();

      if (currentState === 'HALF_OPEN') {
        this.halfOpenInFlight--;
      }

      // Record telemetry & update circuit state
      this.recordExecution(durationMs, isSuccess);

      // Adaptive Concurrency RTT gradient calculation
      if (this.opts.adaptiveConcurrencyEnabled && isSuccess) {
        this.updateAdaptiveConcurrency(durationMs);
      }

      // Replenish retry tokens on success
      if (isSuccess) {
        this.retryTokens = Math.min(this.maxRetryTokens, this.retryTokens + 0.1);
      }
    }
  }

  /**
   * Acquire execution slot under bulkhead limits and adaptive limits
   */
  private acquireBulkheadSlot(timeoutMs: number): Promise<void> {
    const effectiveLimit = Math.min(
      this.opts.bulkheadMaxConcurrent,
      Math.max(this.opts.minAdaptiveConcurrency ?? 5, this.currentConcurrencyLimit)
    );

    if (this.activeExecutions < effectiveLimit) {
      this.activeExecutions++;
      return Promise.resolve();
    }

    // Queue admission check
    if (this.waitingQueue.length >= this.opts.bulkheadMaxQueue) {
      throw new BulkheadRejectionError(
        `Bulkhead [${this.name}] queue saturated (${this.waitingQueue.length}/${this.opts.bulkheadMaxQueue}). Load shedding applied.`
      );
    }

    return new Promise<void>((resolve, reject) => {
      const waitTimeout = Math.min(timeoutMs, 1000); // Wait max 1s in queue
      const timeoutId = setTimeout(() => {
        const index = this.waitingQueue.findIndex(w => w.timeoutId === timeoutId);
        if (index !== -1) {
          this.waitingQueue.splice(index, 1);
        }
        reject(new BulkheadRejectionError(`Bulkhead [${this.name}] queue wait timed out after ${waitTimeout}ms.`));
      }, waitTimeout);

      this.waitingQueue.push({ resolve, reject, timeoutId });
    });
  }

  private releaseBulkheadSlot(): void {
    this.activeExecutions = Math.max(0, this.activeExecutions - 1);
    
    // Drain next queued caller
    if (this.waitingQueue.length > 0 && this.activeExecutions < this.currentConcurrencyLimit) {
      const next = this.waitingQueue.shift()!;
      clearTimeout(next.timeoutId);
      this.activeExecutions++;
      next.resolve();
    }
  }

  private recordExecution(durationMs: number, success: boolean): void {
    const isSlow = durationMs >= this.opts.slowCallThresholdMs;
    const record: CallExecutionRecord = {
      durationMs,
      success,
      isSlow,
      timestamp: Date.now(),
    };

    this.records.push(record);
    if (this.records.length > this.opts.slidingWindowSize) {
      this.records.shift();
    }

    this.evaluateStateTransitions(success);
  }

  private evaluateStateTransitions(lastCallSuccess: boolean): void {
    const currentState = this.state;

    if (currentState === 'HALF_OPEN') {
      if (!lastCallSuccess) {
        // Canary failed! Revert immediately to OPEN with backoff
        this.emit('canaryFailed', { name: this.name });
        this.transitionTo('OPEN');
      } else {
        this.halfOpenSuccessCount++;
        this.emit('canarySuccess', { count: this.halfOpenSuccessCount, target: this.opts.maxHalfOpenCanaryCalls });
        if (this.halfOpenSuccessCount >= this.opts.maxHalfOpenCanaryCalls) {
          // Canaries succeeded: Circuit is now fully healed
          this.transitionTo('CLOSED');
        }
      }
      return;
    }

    if (currentState === 'CLOSED') {
      if (this.records.length < this.opts.minimumNumberOfCalls) {
        return; // Insufficient statistical sample
      }

      const failures = this.records.filter(r => !r.success).length;
      const slowCalls = this.records.filter(r => r.isSlow).length;
      const total = this.records.length;

      const failureRate = (failures / total) * 100;
      const slowCallRate = (slowCalls / total) * 100;

      if (
        failureRate >= this.opts.failureThresholdPercentage ||
        slowCallRate >= this.opts.slowCallRateThresholdPercentage
      ) {
        this.emit('circuitTripped', {
          name: this.name,
          failureRate: failureRate.toFixed(1),
          slowCallRate: slowCallRate.toFixed(1),
          sampleSize: total,
        });
        this.transitionTo('OPEN');
      }
    }
  }

  private transitionTo(newState: CircuitState): void {
    const oldState = this.state;
    this.state = newState;

    if (newState === 'OPEN') {
      this.openUntilTimestamp = Date.now() + this.opts.openDurationMs;
      this.halfOpenSuccessCount = 0;
      this.halfOpenInFlight = 0;
    } else if (newState === 'HALF_OPEN') {
      this.halfOpenSuccessCount = 0;
      this.halfOpenInFlight = 0;
    } else if (newState === 'CLOSED') {
      this.records.length = 0; // Reset rolling metrics on full recovery
      this.halfOpenSuccessCount = 0;
      this.halfOpenInFlight = 0;
    }

    this.emit('stateChanged', { name: this.name, from: oldState, to: newState, timestamp: Date.now() });
  }

  /**
   * Vegas / Gradient adaptive concurrency calculations based on measured RTT
   */
  private updateAdaptiveConcurrency(measuredRttMs: number): void {
    if (measuredRttMs < this.minObservedRttMs) {
      this.minObservedRttMs = measuredRttMs;
    }

    if (this.smoothedRttMs === 0) {
      this.smoothedRttMs = measuredRttMs;
    } else {
      // Exponential moving average: alpha = 0.2
      this.smoothedRttMs = 0.8 * this.smoothedRttMs + 0.2 * measuredRttMs;
    }

    // Gradient G = RTT_min / RTT_measured
    const gradient = Math.max(0.5, Math.min(1.0, this.minObservedRttMs / this.smoothedRttMs));
    const headroom = Math.sqrt(this.currentConcurrencyLimit);

    // C_{t+1} = max(C_min, min(C_max, C_t * G + headroom))
    const nextLimit = this.currentConcurrencyLimit * gradient + headroom;
    const floor = this.opts.minAdaptiveConcurrency ?? 5;
    this.currentConcurrencyLimit = Math.max(floor, Math.min(this.opts.bulkheadMaxConcurrent, nextLimit));
  }

  /**
   * Check if a retry may proceed under the global retry budget
   */
  public acquireRetryToken(): boolean {
    if (this.retryTokens >= 1 && this.getState() === 'CLOSED') {
      this.retryTokens -= 1;
      return true;
    }
    return false;
  }
}
```

---

## 4. 6-State Circuit Breaker & Resilient Load Shedding Finite-State Machine (FSM)

```
                     ┌───────────────────────────┐
                     │          CLOSED           │◄─────────────────────────────┐
                     │  (Normal Fast Execution)  │                              │
                     └─────────────┬─────────────┘                              │
                                   │ Failure Rate >= Θ_trip                     │
                                   │ OR Slow Rate >= Θ_slow                     │
                                   ▼                                            │
                     ┌───────────────────────────┐                              │
                     │           OPEN            │                              │
                     │  (Fast-Fail & Shed Load)  │                              │
                     └─────────────┬─────────────┘                              │
                                   │ Wait T_reset cool-down                     │
                                   │ (Timestamp >= openUntil)                   │
                                   ▼                                            │
                     ┌───────────────────────────┐                              │
       ┌────────────►│         HALF_OPEN         ├─────────────┐                │
       │             │   (Paced Single Canary)   │             │                │
       │             └─────────────┬─────────────┘             │                │
       │                           │                           │                │
       │ Canary probe fails (0/1)  │ Canary probe succeeds     │ Over-concurrency│
       │ OR timeout in flight      │ (k / M_success)           │ shedding       │
       ▼                           ▼                           ▼                │
┌──────────────┐     ┌───────────────────────────┐     ┌──────────────┐         │
│  REVERT_OPEN │     │        RECOVERING         │     │ SHED_TRAFFIC │         │
│(Double Reset)│     │   (Canary Verification)   │     │ (HTTP 429/503│         │
└──────┬───────┘     └─────────────┬─────────────┘     └──────┬───────┘         │
       │                           │                          │                 │
       │ Backoff reset             │ M_success reached        │ Ingress bypass  │
       └───────────────────────────┼──────────────────────────┴─────────────────┘
                                   │ (Consecutive healthy canaries)
                                   └───────────────────────────┘
```

### State Transition Invariant Table

| Origin State | Event Trigger | Guard Condition | Next State | System Actions & Invariants |
| :--- | :--- | :--- | :--- | :--- |
| **`CLOSED`** | Call Completion | $N \ge N_{\text{min}} \land (R_{\text{fail}} \ge \Theta_{\text{fail}} \lor R_{\text{slow}} \ge \Theta_{\text{slow}})$ | **`OPEN`** | Set `openUntil = now + T_reset`. Fast-fail all new requests in 0ms. Dispatch directly to fallback cascade. |
| **`CLOSED`** | Arrival Ingress | $I_t \ge C_t$ (Bulkhead or Adaptive Concurrency Exceeded) | **`CLOSED`** (Shed) | Fast-reject excess request with `BulkheadRejectionError` / HTTP 429. Downstream sockets protected. |
| **`OPEN`** | Wall Clock Tick | $\text{now} \ge \text{openUntil}$ | **`HALF_OPEN`** | Reset canary success counter to 0. Lock concurrency gate to $K_{\text{canary}} = 1$. |
| **`HALF_OPEN`** | Canary Arrival | $I_{\text{canary}} = 0$ | **`RECOVERING`** | Admit exactly 1 single probe request downstream. Increment $I_{\text{canary}}$. |
| **`HALF_OPEN`** | Concurrent Arrival | $I_{\text{canary}} \ge 1$ | **`HALF_OPEN`** | Reject request from downstream access; execute fallback immediately without marking failure. |
| **`RECOVERING`**| Canary Probe Success | $\text{Successes} < M_{\text{consecutive}}$ | **`HALF_OPEN`** | Increment canary counter. Next request admitted as subsequent canary. |
| **`RECOVERING`**| Canary Probe Success | $\text{Successes} \ge M_{\text{consecutive}}$ | **`CLOSED`** | Reset sliding window error records. Reopen bulkhead to normal capacity $C_{\text{max}}$. |
| **`RECOVERING`**| Canary Probe Failure | Any failure or timeout | **`OPEN`** | Exponential backoff: $T_{\text{reset}} \leftarrow \min(2 \cdot T_{\text{reset}}, T_{\text{max}})$. Re-trip circuit immediately. |

---

## 5. Machine-Verifiable Definition of Done (DoD) Matrix

Autonomous agents MUST satisfy all 6 machine-verifiable verification gates before marking any networking, client, database, or API task complete:

| Gate | Verification Area | Verification Invariant & Falsification Criteria | Machine-Verification Command / Test |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **Sliding Window & Trip Sensitivity** | Under 60% injected upstream 500 errors, circuit MUST trip from `CLOSED` to `OPEN` within $N_{\text{min}}$ executions. Once `OPEN`, subsequent invocations MUST reject in $<1\text{ms}$ with `CircuitOpenError` without dispatching network I/O. | `vitest run tests/resilience/circuit-breaker-trip.test.ts` or `go test -v -run TestCircuitBreaker_Tripping` |
| **Gate 2** | **Bulkhead Isolation & Bounded Queue** | When downstream latency artificially jumps to 10s, parallel caller volume exceeding `bulkheadMaxConcurrent + bulkheadMaxQueue` MUST immediately throw `BulkheadRejectionError` (HTTP 429/503) without leaking memory or thread pool slots. | `vitest run tests/resilience/bulkhead-saturation.test.ts` |
| **Gate 3** | **Adaptive Concurrency Gradient** | In simulated high-latency scenarios ($\text{RTT}$ increases from 20ms to 200ms), adaptive concurrency limiter MUST contract permissible in-flight slots to $\le C_{\text{min}} + 2$ within 3 sampling windows. | `vitest run tests/resilience/adaptive-concurrency.test.ts` |
| **Gate 4** | **Half-Open Canary Pacing** | In `HALF_OPEN`, strictly $1$ concurrent probe request is dispatched downstream. 50 concurrent incoming requests during canary flight MUST cleanly execute fallback without hitting downstream mock server. | `vitest run tests/resilience/half-open-canary.test.ts` |
| **Gate 5** | **Retry Budget Suppression** | In a failure scenario, retries MUST NOT exceed $10\%$ of total initial calls. When token bucket reaches 0, retry attempts MUST be rejected with zero downstream invocations. | `vitest run tests/resilience/retry-budget.test.ts` |
| **Gate 6** | **Multi-Tier Fallback Fidelity** | When circuit trips, calls with fallback handlers MUST return valid degraded payloads (e.g. cached data with `X-Degraded: true`) with HTTP 200/202 status, never throwing raw uncaught 500 exceptions to end-users. | `vitest run tests/resilience/fallback-cascade.test.ts` |

---

## 6. Cross-Language Production Invariants

### 6.1 Go Production Invariants (Sony Gobreaker + Semaphore Bulkhead + Context Budget)

- ❌ **Anti-Pattern: Raw `http.Client.Do` without Breaker or Semaphore**: Spawning thousands of unconstrained goroutines calling external services, leaking goroutines when remote hosts hang.
- ✅ **Production Invariant**: Pair `sony/gobreaker` with weighted semaphores and context cancellation budgets:

```go
// Industrial Go Circuit Breaker with Bulkhead Isolation & Context Deadline
package resilience

import (
    "context"
    "errors"
    "net/http"
    "time"

    "github.com/sony/gobreaker"
    "golang.org/x/sync/semaphore"
)

type ResilientClient struct {
    client    *http.Client
    breaker   *gobreaker.CircuitBreaker
    bulkhead  *semaphore.Weighted
    fallback  func(ctx context.Context, err error) (*http.Response, error)
}

func NewResilientClient(maxConcurrent int64) *ResilientClient {
    settings := gobreaker.Settings{
        Name:        "downstream-llm-service",
        MaxRequests: 1, // Strictly 1 canary probe in HALF_OPEN
        Interval:    10 * time.Second,
        Timeout:     15 * time.Second, // Cool-down duration in OPEN
        ReadyToTrip: func(counts gobreaker.Counts) bool {
            failureRatio := float64(counts.TotalFailures) / float64(counts.Requests)
            return counts.Requests >= 10 && failureRatio >= 0.50
        },
    }

    return &ResilientClient{
        client:   &http.Client{Timeout: 5 * time.Second},
        breaker:  gobreaker.NewCircuitBreaker(settings),
        bulkhead: semaphore.NewWeighted(maxConcurrent),
    }
}

func (c *ResilientClient) Do(ctx context.Context, req *http.Request) (*http.Response, error) {
    // 1. Bulkhead admission with non-blocking try-acquire or fast context abort
    if !c.bulkhead.TryAcquire(1) {
        return nil, errors.New("bulkhead capacity saturated: load shedding triggered")
    }
    defer c.bulkhead.Release(1)

    // 2. Execute via Circuit Breaker
    res, err := c.breaker.Execute(func() (interface{}, error) {
        resp, doErr := c.client.Do(req.WithContext(ctx))
        if doErr != nil {
            return nil, doErr
        }
        if resp.StatusCode >= 500 {
            return resp, errors.New("downstream 5xx server error")
        }
        return resp, nil
    })

    if err != nil {
        if c.fallback != nil {
            return c.fallback(ctx, err)
        }
        return nil, err
    }

    return res.(*http.Response), nil
}
```

### 6.2 PostgreSQL & Relational Database Production Invariants (Connection Bulkhead & Statement Timeouts)

- ❌ **Anti-Pattern: Shared Connection Pool Collapse on Slow Analytical Queries**: Allowing long-running ad-hoc reporting queries to occupy all pooled database connections, starving fast OLTP web requests.
- ✅ **Production Invariant**: Compartmentalize database pools into distinct bulkheads (OLTP pool vs Analytics pool), enforce strict session `statement_timeout` circuit breakers, and shed slow queries:

```sql
-- Industrial PostgreSQL Connection Pool Bulkhead & Statement Timeout Circuit Configuration

-- 1. Create dedicated user roles with isolated session resource ceilings
CREATE ROLE app_oltp_worker WITH LOGIN PASSWORD 'secure_oltp_pwd';
CREATE ROLE app_reporting_worker WITH LOGIN PASSWORD 'secure_report_pwd';

-- 2. Bulkhead statement timeout circuits per role:
-- OLTP transactions fail-fast if blocked past 3 seconds
ALTER ROLE app_oltp_worker SET statement_timeout = '3000ms';
ALTER ROLE app_oltp_worker SET lock_timeout = '1000ms';
ALTER ROLE app_oltp_worker SET idle_in_transaction_session_timeout = '5000ms';

-- Analytical reporting transactions bounded to 30 seconds
ALTER ROLE app_reporting_worker SET statement_timeout = '30000ms';
ALTER ROLE app_reporting_worker SET default_transaction_read_only = 'on';

-- 3. In-flight Query Shedding Monitor (Runs periodically to kill queries exceeding SLA)
CREATE OR REPLACE FUNCTION shed_stuck_backend_queries(max_duration_seconds INT)
RETURNS INT AS $$
DECLARE
    shed_count INT := 0;
BEGIN
    SELECT COUNT(*) INTO shed_count
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query NOT ILIKE '%pg_stat_activity%'
      AND (NOW() - query_start) > (max_duration_seconds || ' seconds')::INTERVAL;

    PERFORM pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query NOT ILIKE '%pg_stat_activity%'
      AND (NOW() - query_start) > (max_duration_seconds || ' seconds')::INTERVAL;

    RETURN shed_count;
END;
$$ LANGUAGE plpgsql;
```

### 6.3 MCP Server Production Invariants (Tool-Call Bulkhead Isolation & Graceful Tool Degradation)

- ❌ **Anti-Pattern: Subprocess Hang Freezing MCP Server Event Loop**: An external CLI or LSP tool executed via MCP hangs, blocking the MCP stdio/SSE server and rendering all other tools unresponsive to Claude Code or Cursor.
- ✅ **Production Invariant**: Wrap each tool dispatcher in an isolated concurrency bulkhead with circuit-breaking and degraded synthetic output:

```typescript
// Industrial MCP Server Resilient Tool Dispatcher with Circuit Breaker
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { AgenticCircuitBreakerEngine } from '../resilience/circuit-breaker.js';

const toolBreakers = new Map<string, AgenticCircuitBreakerEngine>();

function getBreakerForTool(toolName: string): AgenticCircuitBreakerEngine {
  if (!toolBreakers.has(toolName)) {
    toolBreakers.set(toolName, new AgenticCircuitBreakerEngine(`mcp-tool:${toolName}`, {
      failureThresholdPercentage: 50,
      slowCallThresholdMs: 4000,
      slowCallRateThresholdPercentage: 60,
      slidingWindowSize: 10,
      minimumNumberOfCalls: 5,
      openDurationMs: 15000,
      maxHalfOpenCanaryCalls: 2,
      bulkheadMaxConcurrent: 4, // Max 4 concurrent processes per tool
      bulkheadMaxQueue: 2,
    }));
  }
  return toolBreakers.get(toolName)!;
}

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const breaker = getBreakerForTool(name);

  try {
    const result = await breaker.execute(
      async (signal) => {
        return await executeToolWithTimeout(name, args, signal);
      },
      // Degraded fallback handler: informs agent that tool is temporarily in degraded mode
      async (err) => {
        return {
          isDegraded: true,
          notice: `Tool [${name}] circuit breaker is active (${err.message}). Returning safe fallback.`,
          data: getCachedOrEmptyFallbackForTool(name, args),
        };
      },
      8000 // 8s absolute timeout
    );

    return { content: [{ type: 'text', text: JSON.stringify(result) }] };
  } catch (err: any) {
    return {
      content: [{ type: 'text', text: JSON.stringify({ error: `Tool execution failed: ${err.message}` }) }],
      isError: true,
    };
  }
});
```

### 6.4 SvelteKit Production Invariants (Resilient Load Function Fallbacks & Server Bulkheads)

- ❌ **Anti-Pattern: Unhandled 500 Page Crash on Dependency Outage**: A third-party pricing API goes down, causing SvelteKit SSR `load` to crash and display an unformatted 500 error page.
- ✅ **Production Invariant**: Protect SvelteKit server `load` functions with circuit breakers returning cached or static fallback props:

```typescript
// src/routes/dashboard/+page.server.ts - SvelteKit Resilient Load
import type { PageServerLoad } from './$types';
import { AgenticCircuitBreakerEngine } from '$lib/server/circuit-breaker';

const analyticsBreaker = new AgenticCircuitBreakerEngine('analytics-api', {
  failureThresholdPercentage: 40,
  slowCallThresholdMs: 1500,
  slowCallRateThresholdPercentage: 50,
  slidingWindowSize: 15,
  minimumNumberOfCalls: 5,
  openDurationMs: 10000,
  maxHalfOpenCanaryCalls: 2,
  bulkheadMaxConcurrent: 20,
  bulkheadMaxQueue: 5,
});

export const load: PageServerLoad = async ({ fetch }) => {
  const metrics = await analyticsBreaker.execute(
    async (signal) => {
      const res = await fetch('https://analytics.internal/v1/summary', { signal });
      if (!res.ok) throw new Error(`Analytics API error: ${res.status}`);
      return await res.json();
    },
    // Graceful fallback: return empty summary with warning indicator
    () => ({
      summary: { totalUsers: 0, activeNow: 0 },
      isDegraded: true,
      cachedAt: new Date().toISOString(),
    }),
    2000 // 2s budget
  );

  return { metrics };
};
```

### 6.5 Vue / Nuxt Production Invariants (Nitro Resilient Fetch & Composable Fallbacks)

- ❌ **Anti-Pattern: Component Freeze on External API Failure**: Nuxt components hanging indefinitely on hydration because server-side `$fetch` blocks without timeout or bulkhead.
- ✅ **Production Invariant**: Provide a resilient composable with built-in circuit-breaking and client fallback state:

```typescript
// composables/useResilientFetch.ts - Vue 3 / Nuxt 3 Resilient Composable
export function useResilientFetch<T>(
  url: string,
  opts?: { timeoutMs?: number; fallbackData?: T }
) {
  const isDegraded = ref(false);
  const circuitOpen = ref(false);

  const { data, pending, error, refresh } = useAsyncData<T>(
    `resilient:${url}`,
    async () => {
      const timeoutMs = opts?.timeoutMs ?? 3000;
      const ac = new AbortController();
      const timer = setTimeout(() => ac.abort(), timeoutMs);

      try {
        const response = await $fetch<T>(url, { signal: ac.signal });
        circuitOpen.value = false;
        return response;
      } catch (err: any) {
        if (opts?.fallbackData !== undefined) {
          isDegraded.value = true;
          return opts.fallbackData;
        }
        throw err;
      } finally {
        clearTimeout(timer);
      }
    }
  );

  return { data, pending, error, isDegraded, circuitOpen, refresh };
}
```
