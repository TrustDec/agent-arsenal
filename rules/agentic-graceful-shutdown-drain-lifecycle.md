---
description: Agentic graceful shutdown, zero-downtime connection draining, reverse-dependency teardown DAG, Kubernetes preStop quiescence, signal trapping (SIGTERM/SIGINT), WebSocket 1001 close propagation, worker lease re-enqueuing, and watchdog deadline bounds across Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{shutdown,lifecycle,drain,graceful,cleanup,server,worker,process,signal,main}*.*,**/src/index.{ts,js},**/src/main.{ts,js,go,rs,py},**/cmd/**/*.{go,rs},**/server/**/*.{ts,js,py,go,rs}
alwaysApply: false
---

# Agentic Graceful Shutdown, Zero-Downtime Drain & Process Lifecycle Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design HTTP/gRPC services, background worker daemons, message queue consumers, WebSocket/SSE streaming servers, or Model Context Protocol (MCP) tools across Kubernetes, Docker, bare-metal systemd, or serverless containers. Eliminate the "Abrupt `SIGKILL` & Severed In-Flight Transaction Disaster" (where processes terminate mid-request, corrupting half-committed database state), the "Kubernetes Readiness-Drain Race & Ingress 502 Storm" (where servers close listeners immediately on `SIGTERM` while kube-proxy/ingress continues routing traffic), the "Dependency Inversion Teardown Crash" (where database pools or cache connections are destroyed before in-flight HTTP handlers finish responding), the "Zombie Background Consumer & Leaked Lease Trap" (where workers pull fresh jobs during shutdown or abandon active tasks without returning NACKs), the "Unbounded Drain Hang & 30s `SIGKILL` Guillotine" (where stuck external requests block shutdown until the kernel brutally murders the process), and the "Orphaned MCP Subprocess Leak" by establishing a strict 5-Tier Process Lifecycle & Drain Ladder, formal drain budget calculus, reverse-topological DAG teardowns, protocol-aware stream closures, dual-signal emergency interrupts, and bounded watchdog timers.

---

## 1. Architectural Taxonomy: The 6 Process Lifecycle Catastrophes vs The 5-Tier Process Lifecycle & Drain Ladder

When autonomous coding agents are tasked with spinning up backend services, queue consumers, or microservices, LLMs almost universally generate naive entrypoints with zero signal handling or brutal `process.exit(0)` signal callbacks:

```typescript
// ❌ CATASTROPHIC LLM SERVER ENTRYPOINT
const app = express();
const dbPool = new pg.Pool();

app.post('/api/checkout', async (req, res) => {
  const client = await dbPool.connect();
  await client.query('BEGIN');
  await client.query('UPDATE accounts SET balance = balance - 100 WHERE id = $1', [req.body.id]);
  await sleep(3000); // VULN 1: What if SIGTERM arrives here?
  await client.query('COMMIT');
  res.json({ ok: true });
});

const server = app.listen(3000);

// VULN 2: Naive signal handler brutally exits or closes pools out of order
process.on('SIGTERM', () => {
  console.log('Shutting down...');
  dbPool.end(); // VULN 3: Crashes active /checkout handler with "Connection pool closed"!
  process.exit(0); // VULN 4: Brutally severs TCP sockets; clients get ECONNRESET!
});
```

In containerized production clusters (Kubernetes, AWS ECS, Nomad) and rolling deployments, this naive pattern produces six critical engineering catastrophes:

- **The "Abrupt `SIGKILL` & Severed In-Flight Transaction Disaster"**:
  - When a container orchestrator redeploys an application, it issues a `SIGTERM`. If the process has no signal handler or immediately executes `process.exit(0)` / `os.Exit(0)`, the process dies immediately.
  - In-flight database transactions are severed mid-flight. Uncommitted rows hold pessimistic row locks until the database engine detects TCP keepalive timeouts. Files written to disk or S3 multipart uploads are left partially completed.
  - Invariant: A process MUST intercept termination signals (`SIGTERM`, `SIGINT`) and enter a dedicated draining state, allowing currently active requests to complete cleanly up to a bounded watchdog deadline.
- **The "Kubernetes Readiness-Drain Race & Ingress 502 Storm"**:
  - In Kubernetes, when a Pod is deleted, two asynchronous events happen in parallel: (1) `SIGTERM` is dispatched to the Pod's PID 1, and (2) Kubernetes control plane begins removing the Pod IP from the Service Endpoints and propagating updates to kube-proxy, CoreDNS, and Ingress controllers (NGINX, Envoy, Traefik, ALB).
  - Endpoint propagation takes between 1.0 and 5.0 seconds across large clusters.
  - If the agent closes the HTTP listener immediately upon receiving `SIGTERM`, Ingress controllers still consider the Pod healthy and continue forwarding new client requests to the dead socket. Clients experience a burst of `502 Bad Gateway` or `ECONNREFUSED` errors during every rolling release.
  - Invariant: Upon `SIGTERM`, the application MUST immediately flip its readiness probe (`/readyz`) to HTTP 503 (`Serving: false`) while keeping its liveness probe (`/healthz`) at HTTP 200, followed by a mandatory Ingress Quiescence Pause ($T_{\text{quiesce}} \ge 2\text{s}$ or Kubernetes `preStop` exec hook `sleep 5`) *before* closing the HTTP socket listener.
- **The "Dependency Inversion Teardown Crash"**:
  - A backend service depends on a Directed Acyclic Graph (DAG) of infrastructure: $\text{Ingress Traffic} \to \text{Background Workers} \to \text{Redis Cache} \to \text{PostgreSQL Pool} \to \text{Telemetry/Tracer}$.
  - LLM agents close connections either simultaneously via `Promise.all([server.close(), db.end(), redis.quit()])` or in forward initialization order ($\text{db.end()}$ first).
  - As a result, in-flight HTTP requests that are still completing business logic attempt to query the database, throwing unhandled exceptions (`pg: database is closed`, `Cannot read properties of closed pool`), corrupting customer operations at the finish line.
  - Invariant: Teardown MUST proceed in strict **Reverse Topological Order** ($L_{\text{ingress}} \to L_{\text{worker}} \to L_{\text{cache}} \to L_{\text{database}} \to L_{\text{telemetry}}$). Downstream data stores MUST NOT be closed until all upstream callers have completely ceased execution.
- **The "Zombie Background Consumer & Leaked In-Flight Lease Trap"**:
  - In message queue consumers (Kafka, RabbitMQ, SQS, NATS, BullMQ), when `SIGTERM` arrives, naive workers continue polling for new messages or terminate without acknowledging/re-enqueuing active jobs.
  - If a message takes 10 seconds to process and the worker dies at second 4, the message visibility timeout or consumer group rebalance locks the message for minutes, stalling pipeline throughput.
  - Invariant: Upon shutdown signal, consumers MUST immediately stop fetching *new* messages from the broker, allow currently active messages to finish within the drain budget, and explicitly NACK, reject, or return visibility for any tasks that cannot complete before the deadline.
- **The "Unbounded Drain Hang & The 30s `SIGKILL` Guillotine"**:
  - Agents implement graceful shutdown with `await Promise.all(activeRequests)` or `wg.Wait()` without any timeout boundary.
  - If a single client connection hangs on an idle HTTP Keep-Alive connection, an un-chunked streaming response, or an un-responsive third-party API call, the process never exits.
  - At $t = \text{terminationGracePeriodSeconds}$ (default 30 seconds in Kubernetes), the kernel executes an un-catchable `SIGKILL (kill -9)`. The process is murdered violently, completely defeating the purpose of the graceful shutdown attempt.
  - Invariant: Graceful draining MUST be bounded by a monotonic watchdog timer ($T_{\text{watchdog}} \le T_{\text{k8s\_grace}} - \Delta T_{\text{safety}}$). If in-flight work fails to drain before the watchdog expires, the engine forces termination cleanly with an error log detailing the offending in-flight task IDs.
- **The "Orphaned MCP Subprocess & Leaked File Descriptor Leak"**:
  - Model Context Protocol (MCP) servers and CLI tool wrappers spawn child processes (`child_process.spawn()`, `os/exec.Command()`).
  - When the parent process terminates or when the client (Claude Desktop, Cursor, Pi) closes the stdio pipe (`stdin.on('end')`), naive servers leave background worker child processes running as orphaned init-adopted zombies holding ports, file locks, and GPU memory.
  - Invariant: Process shutdown MUST trap parent stdio closure (`EOF` on `stdin`), maintain a registry of spawned child process group IDs (`PGID`), and execute negative PID signal broadcasts (`kill(-pgid, 'SIGTERM')`) with escalation to `SIGKILL` after 2000ms.

---

```
                       5-TIER PROCESS LIFECYCLE & DRAIN LADDER
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ Tier 4: Autonomous Resilient Lifecycle Governance                           │
  │  - Hard Watchdog Deadline Bounded ($T_{\text{drain}} \le T_{\text{grace}} - \Delta$)              │
  │  - Protocol-Aware Stream Draining (WebSocket 1001, SSE Reconnect Hints)     │
  │  - Process-Group Child Reaping (`kill(-pgid)`) & CI Zero-502 Verification   │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 3: Asynchronous Worker Lease Draining & Message Re-Enqueuing           │
  │  - Immediate Consumer Ingestion Freeze (Stop Polling Broker)               │
  │  - Active Job Drain + Explicit NACK / Visibility Reset on Unfinished Jobs  │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 2: Reverse Topological Dependency Teardown DAG                         │
  │  - Strict Reverse Ordering ($L_{\text{ingress}} \to L_{\text{worker}} \to L_{\text{pool}} \to L_{\text{telemetry}}$) │
  │  - Upstream Handlers Finish BEFORE Downstream Connection Pools Close       │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 1: Two-Phase Readiness Probe Quiescence & Ingress Buffer               │
  │  - Flip `/readyz` to 503 (`Serving: false`) while keeping `/healthz` 200    │
  │  - Ingress Quiescence Pause ($T_{\text{quiesce}} \ge 2\text{s}$) before Socket Close       │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 0: Dual-Signal Trap & Idempotent Shutdown Dispatcher                   │
  │  - Intercept `SIGTERM` and `SIGINT` via Atomic Latch                        │
  │  - Second Signal Triggers Immediate Emergency Forced Exit (Code 130/143)    │
  └─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical & Formal Invariant Calculus

### 2.1 The Graceful Drain Budget Inequality

In any containerized or orchestrated environment, the graceful shutdown sequence is governed by a strict temporal budget constraint. Let:
- $T_{\text{k8s\_grace}}$ be the orchestrator grace period (`terminationGracePeriodSeconds`, typically $30.0\text{s}$).
- $T_{\text{pre\_stop}}$ be the duration of the container lifecycle `preStop` hook (or internal sleep pause).
- $T_{\text{endpoint\_prop}}$ be the maximum cluster endpoint propagation latency ($1.0\text{s} \le T_{\text{endpoint\_prop}} \le 3.0\text{s}$).
- $T_{\text{drain\_timeout}}$ be the maximum allowed time for active in-flight requests and queue workers to drain.
- $T_{\text{resource\_teardown}}$ be the time required to flush buffers, commit write-ahead logs, and close database pools.
- $\Delta T_{\text{safety\_margin}}$ be the safety buffer reserved to ensure clean process termination before the kernel fires `SIGKILL` ($2.0\text{s} \le \Delta T_{\text{safety\_margin}} \le 5.0\text{s}$).

The **Graceful Drain Budget Law** states:

$$T_{\text{k8s\_grace}} \ge T_{\text{pre\_stop}} + T_{\text{endpoint\_prop}} + T_{\text{drain\_timeout}} + T_{\text{resource\_teardown}} + \Delta T_{\text{safety\_margin}}$$

If this inequality is violated, the container runtime will issue an un-catchable `SIGKILL` at $t = T_{\text{k8s\_grace}}$, producing non-deterministic state corruption. Therefore, the internal watchdog timeout $T_{\text{watchdog}}$ MUST be derived programmatically:

$$T_{\text{watchdog}} = T_{\text{k8s\_grace}} - T_{\text{pre\_stop}} - \Delta T_{\text{safety\_margin}}$$

```
  0s            T_prestop (3s)         T_drain (20s)         T_teardown (3s)  Margin (4s)  30s
  ├── SIGTERM ──┼──────────────────────┼─────────────────────┼────────────────┼────────────┤
  │             │                      │                     │                │            │
  ▼             ▼                      ▼                     ▼                ▼            ▼
Flip /readyz  Ingress Pod Removal    In-Flight Requests    Close DB Pools,  Process      k8s
to 503        Propagates via k8s     Drain to Zero         Flush Spans/Logs Exits (0)    SIGKILL
```

### 2.2 The Reverse Dependency Teardown DAG Invariant

Let $\mathcal{C} = \{c_1, c_2, \dots, c_n\}$ be the set of system components, and let $E \subset \mathcal{C} \times \mathcal{C}$ be the directed dependency relations where $(c_i, c_j) \in E$ denotes that component $c_i$ depends on component $c_j$ (e.g., $\text{HTTP Router} \to \text{User Service} \to \text{PostgreSQL Pool}$).

Let $\mathcal{G} = (\mathcal{C}, E)$ be a Directed Acyclic Graph (DAG). The teardown sequence is an ordered list of teardown phases $\mathcal{T} = (\tau_1, \tau_2, \dots, \tau_m)$.

**The Teardown Topological Invariant**:
$$\forall (c_i, c_j) \in E \implies \text{Phase}(c_i) < \text{Phase}(c_j)$$

Under this invariant, component $c_j$ (the database or broker) is guaranteed to remain fully functional and open for queries throughout the entirety of $c_i$'s teardown and in-flight request drainage.

### 2.3 The Monotonic Drain Invariant

Let $R_{\text{active}}(t)$ denote the number of currently executing in-flight HTTP requests, gRPC streams, and worker tasks at time $t$. Let $t_{\text{stop\_accept}}$ be the timestamp at which network listeners stop accepting new connections.

$$\forall t > t_{\text{stop\_accept}}: \quad \frac{dR_{\text{active}}(t)}{dt} \le 0$$

$$\lim_{t \to t_{\text{watchdog}}} R_{\text{active}}(t) \equiv 0$$

If $R_{\text{active}}(t_{\text{watchdog}}) > 0$, the system MUST emit an alert log detailing the unique IDs, durations, and endpoints of the remaining stranded requests before initiating emergency resource closure.

### 2.4 The Dual-Signal Interruption Law

Let $S(t) \in \{\text{SIGTERM}, \text{SIGINT}\}$ be the arrival of an external termination signal at time $t$:

$$\text{Action}(S(t)) = \begin{cases}
\text{Initiate Graceful Drain Pipeline with Watchdog}(T_{\text{watchdog}}), & \text{if count}(S) = 1 \\
\text{Immediate Emergency Forced Termination}(\text{exit code } 130/143), & \text{if count}(S) \ge 2
\end{cases}$$

This satisfies both container orchestrators (which issue a single `SIGTERM`) and terminal human developers (who press `Ctrl+C` once to drain, and press `Ctrl+C` twice to force an immediate emergency kill).

---

## 3. Complete Production-Ready TypeScript Implementation: `AgenticGracefulShutdownEngine`

This enterprise-grade, zero-dependency implementation coordinates readiness probes, ingress pauses, in-flight task tracking, reverse DAG teardowns, WebSocket close frames, child process cleanup, and dual-signal interrupts:

```typescript
/**
 * AgenticGracefulShutdownEngine - Enterprise Process Lifecycle & Drain Governor
 * Pure TypeScript, zero external dependencies. Complies with Kubernetes, Docker,
 * systemd, and local terminal execution standards.
 */

import http from 'node:http';
import { EventEmitter } from 'node:events';

export type ComponentPhase =
  | 'INGRESS_GATEWAY'   // HTTP listeners, gRPC servers, WebSockets
  | 'QUEUE_WORKERS'     // Kafka consumers, RabbitMQ consumers, BullMQ workers
  | 'CACHE_STORAGE'     // Redis, Memcached, ephemeral state
  | 'PRIMARY_DATABASE'  // PostgreSQL, MySQL, ClickHouse connection pools
  | 'OBSERVABILITY';    // OpenTelemetry tracer flush, structured log flush

export interface CleanupHandler {
  name: string;
  phase: ComponentPhase;
  timeoutMs: number;
  execute: () => Promise<void>;
}

export interface ShutdownOptions {
  k8sGracePeriodMs?: number;
  ingressQuiesceMs?: number;
  safetyMarginMs?: number;
  logger?: (msg: string, meta?: Record<string, unknown>) => void;
}

export class AgenticGracefulShutdownEngine extends EventEmitter {
  private readonly k8sGracePeriodMs: number;
  private readonly ingressQuiesceMs: number;
  private readonly safetyMarginMs: number;
  private readonly logger: (msg: string, meta?: Record<string, unknown>) => void;

  private state: 'SERVING' | 'QUIESCING' | 'DRAINING' | 'TEARING_DOWN' | 'TERMINATED' = 'SERVING';
  private signalCount = 0;
  private activeInFlightRequests = 0;
  private readonly inFlightTaskMap = new Map<string, { endpoint: string; startTime: number }>();
  private readonly cleanupHandlers: CleanupHandler[] = [];
  private watchdogTimer: NodeJS.Timeout | null = null;

  constructor(options: ShutdownOptions = {}) {
    super();
    this.k8sGracePeriodMs = options.k8sGracePeriodMs ?? 30000;
    this.ingressQuiesceMs = options.ingressQuiesceMs ?? 3000;
    this.safetyMarginMs = options.safetyMarginMs ?? 3000;
    this.logger = options.logger ?? ((msg, meta) => console.log(`[SHUTDOWN] ${msg}`, meta ? JSON.stringify(meta) : ''));

    this.registerSignalHooks();
  }

  /**
   * Register a component cleanup handler bound to a specific architectural phase.
   */
  public registerCleanup(handler: CleanupHandler): void {
    this.cleanupHandlers.push(handler);
  }

  /**
   * Track an active in-flight request or worker task.
   * Returns a release function that MUST be invoked in a finally block.
   */
  public trackInFlight(taskId: string, endpoint: string): () => void {
    if (this.state !== 'SERVING' && this.state !== 'QUIESCING') {
      throw new Error(`Cannot accept new task ${taskId}: server is in ${this.state} state`);
    }

    this.activeInFlightRequests++;
    this.inFlightTaskMap.set(taskId, { endpoint, startTime: Date.now() });

    let released = false;
    return () => {
      if (!released) {
        released = true;
        this.activeInFlightRequests--;
        this.inFlightTaskMap.delete(taskId);
        if (this.activeInFlightRequests === 0 && this.state === 'DRAINING') {
          this.emit('drain:complete');
        }
      }
    };
  }

  /**
   * Express / Fastify / Node HTTP middleware for tracking requests & readiness gating.
   */
  public createHttpMiddleware() {
    return (req: http.IncomingMessage, res: http.ServerResponse, next: () => void) => {
      // 1. Intercept Kubernetes Health & Readiness Probes
      if (req.url === '/readyz') {
        if (this.state === 'SERVING') {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ status: 'READY', serving: true }));
        } else {
          res.writeHead(503, { 'Content-Type': 'application/json', 'Connection': 'close' });
          res.end(JSON.stringify({ status: 'DRAINING', serving: false }));
        }
        return;
      }

      if (req.url === '/healthz') {
        // Liveness probe stays 200 during draining so k8s doesn't SIGKILL prematurely!
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'ALIVE', state: this.state }));
        return;
      }

      // 2. Reject new traffic if already in draining or teardown phase
      if (this.state !== 'SERVING' && this.state !== 'QUIESCING') {
        res.writeHead(503, { 'Content-Type': 'application/json', 'Connection': 'close' });
        res.end(JSON.stringify({ error: 'Service is shutting down. Please retry on alternate replica.' }));
        return;
      }

      // 3. Track in-flight user request
      const reqId = (req.headers['x-request-id'] as string) || `req_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
      const release = this.trackInFlight(reqId, `${req.method} ${req.url}`);

      res.on('finish', release);
      res.on('close', release);

      next();
    };
  }

  /**
   * Initiate the multi-stage graceful shutdown pipeline.
   */
  public async initiateShutdown(reason: string): Promise<void> {
    if (this.state !== 'SERVING') {
      return;
    }

    const tStart = Date.now();
    const allowedDrainMs = Math.max(1000, this.k8sGracePeriodMs - this.ingressQuiesceMs - this.safetyMarginMs);

    this.logger('Initiating graceful shutdown sequence', {
      reason,
      state: this.state,
      inFlightTasks: this.activeInFlightRequests,
      k8sGracePeriodMs: this.k8sGracePeriodMs,
      ingressQuiesceMs: this.ingressQuiesceMs,
      allowedDrainMs,
    });

    // Arm the monotonic watchdog deadline timer
    this.armWatchdog(this.k8sGracePeriodMs - this.safetyMarginMs);

    // =========================================================================
    // STAGE 1: Ingress Quiescence & Readiness Flip
    // =========================================================================
    this.state = 'QUIESCING';
    this.logger('STAGE 1: Flipped /readyz to HTTP 503. Waiting for Ingress endpoint propagation...', {
      quiesceDurationMs: this.ingressQuiesceMs,
    });

    await this.sleep(this.ingressQuiesceMs);

    // =========================================================================
    // STAGE 2: Stop Ingress Listeners & Drain In-Flight Requests
    // =========================================================================
    this.state = 'DRAINING';
    this.logger('STAGE 2: Closing network listeners. Draining in-flight requests...', {
      activeRequests: this.activeInFlightRequests,
    });

    // Execute INGRESS_GATEWAY cleanup (e.g. server.close(), ws.close(1001))
    await this.executePhase('INGRESS_GATEWAY');

    // Await in-flight requests to reach zero or until allowedDrainMs expires
    if (this.activeInFlightRequests > 0) {
      await this.awaitInFlightDrain(allowedDrainMs);
    }

    if (this.activeInFlightRequests > 0) {
      this.logger('WARNING: Drain timeout reached with stranded in-flight requests', {
        strandedCount: this.activeInFlightRequests,
        strandedTasks: Array.from(this.inFlightTaskMap.entries()).map(([id, info]) => ({
          id,
          endpoint: info.endpoint,
          elapsedMs: Date.now() - info.startTime,
        })),
      });
    } else {
      this.logger('All in-flight requests drained cleanly to 0');
    }

    // =========================================================================
    // STAGE 3: Reverse Dependency DAG Teardown
    // =========================================================================
    this.state = 'TEARING_DOWN';
    this.logger('STAGE 3: Executing reverse-dependency component teardowns...');

    const phases: ComponentPhase[] = ['QUEUE_WORKERS', 'CACHE_STORAGE', 'PRIMARY_DATABASE', 'OBSERVABILITY'];
    for (const phase of phases) {
      await this.executePhase(phase);
    }

    // =========================================================================
    // STAGE 4: Process Termination
    // =========================================================================
    this.state = 'TERMINATED';
    this.clearWatchdog();
    const totalElapsedMs = Date.now() - tStart;
    this.logger('Graceful shutdown completed successfully. Exiting.', { totalElapsedMs });
    process.exit(0);
  }

  /**
   * Execute all cleanup handlers belonging to a specific architectural tier.
   */
  private async executePhase(phase: ComponentPhase): Promise<void> {
    const handlers = this.cleanupHandlers.filter((h) => h.phase === phase);
    if (handlers.length === 0) return;

    this.logger(`Executing teardown phase: ${phase} (${handlers.length} handlers)`);

    await Promise.all(
      handlers.map(async (handler) => {
        const pStart = Date.now();
        try {
          await this.withTimeout(
            handler.execute(),
            handler.timeoutMs,
            `Cleanup handler '${handler.name}' timed out after ${handler.timeoutMs}ms`
          );
          this.logger(`Cleaned up: ${handler.name}`, { phase, durationMs: Date.now() - pStart });
        } catch (err) {
          this.logger(`ERROR in cleanup handler: ${handler.name}`, {
            phase,
            error: err instanceof Error ? err.message : String(err),
          });
        }
      })
    );
  }

  private awaitInFlightDrain(timeoutMs: number): Promise<void> {
    return new Promise<void>((resolve) => {
      if (this.activeInFlightRequests === 0) {
        resolve();
        return;
      }

      const timer = setTimeout(() => {
        this.removeListener('drain:complete', onComplete);
        resolve();
      }, timeoutMs);

      const onComplete = () => {
        clearTimeout(timer);
        resolve();
      };

      this.once('drain:complete', onComplete);
    });
  }

  private armWatchdog(timeoutMs: number): void {
    this.watchdogTimer = setTimeout(() => {
      this.logger('FATAL: Monotonic shutdown watchdog expired! Forcing emergency SIGKILL exit.', {
        timeoutMs,
        state: this.state,
        strandedTasks: this.activeInFlightRequests,
      });
      process.exit(1);
    }, timeoutMs);

    // Ensure watchdog does not keep event loop alive if everything finishes
    if (this.watchdogTimer.unref) {
      this.watchdogTimer.unref();
    }
  }

  private clearWatchdog(): void {
    if (this.watchdogTimer) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = null;
    }
  }

  private registerSignalHooks(): void {
    const handleSignal = (sig: string) => {
      this.signalCount++;
      if (this.signalCount === 1) {
        this.logger(`Received signal ${sig}. Starting graceful drain...`);
        this.initiateShutdown(`Signal ${sig}`).catch((err) => {
          this.logger('Fatal error during shutdown', { error: String(err) });
          process.exit(1);
        });
      } else {
        this.logger(`Received second signal ${sig}. Forcing immediate emergency exit!`);
        process.exit(sig === 'SIGINT' ? 130 : 143);
      }
    };

    process.on('SIGTERM', () => handleSignal('SIGTERM'));
    process.on('SIGINT', () => handleSignal('SIGINT'));

    // Handle MCP Stdio EOF (parent process disconnected)
    if (process.stdin.isTTY === false) {
      process.stdin.on('end', () => {
        this.logger('Parent stdin reached EOF. Initiating MCP process cleanup...');
        this.initiateShutdown('Parent stdin closed').catch(() => process.exit(0));
      });
    }
  }

  private withTimeout<T>(promise: Promise<T>, ms: number, errorMsg: string): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(errorMsg)), ms);
      promise
        .then((res) => {
          clearTimeout(timer);
          resolve(res);
        })
        .catch((err) => {
          clearTimeout(timer);
          reject(err);
        });
    });
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((r) => setTimeout(r, ms));
  }
}
```

---

## 4. 6-State Process Lifecycle & Drain Finite-State Machine (FSM)

```
                     ┌──────────────────────────┐
                     │     1. INITIALIZING      │
                     │ (Binding Ports, Pools)   │
                     └─────────────┬────────────┘
                                   │
                                   ▼
                     ┌──────────────────────────┐
                     │   2. SERVING_HEALTHY     │
                     │ /readyz: 200, /healthz: 200│
                     └─────────────┬────────────┘
                                   │ Received SIGTERM / SIGINT
                                   ▼
                     ┌──────────────────────────┐
                     │   3. QUIESCING_INGRESS   │
                     │ /readyz: 503, /healthz: 200│
                     │ Ingress Pause (2-5s)     │
                     └─────────────┬────────────┘
                                   │ Pause Elapsed
                                   ▼
                     ┌──────────────────────────┐
                     │  4. DRAINING_IN_FLIGHT   │
                     │ Listeners Closed         │
                     │ Wait inFlight == 0 (max T)│
                     └─────────────┬────────────┘
                                   │ inFlight == 0 OR Timeout
                                   ▼
                     ┌──────────────────────────┐
                     │ 5. TEARING_DOWN_DAG      │
                     │ Workers -> Cache -> DB   │
                     │ -> Telemetry Flush       │
                     └─────────────┬────────────┘
                                   │ All Resources Closed
                                   ▼
                     ┌──────────────────────────┐
                     │      6. TERMINATED       │
                     │ process.exit(0)          │
                     └──────────────────────────┘
```

### State Transition Invariants:

1. **`INITIALIZING` $\to$ `SERVING_HEALTHY`**:
   - The application binds HTTP listeners, establishes database connection pools, verifies Redis connectivity, and registers signal hooks.
   - `/healthz` and `/readyz` return HTTP 200 only after database migrations and warmup routines succeed.
2. **`SERVING_HEALTHY` $\to$ `QUIESCING_INGRESS`**:
   - Triggered by `SIGTERM`, `SIGINT`, or administrative `/drain` command.
   - **Critical Invariant**: `/readyz` transitions immediately to HTTP 503 (`Serving: false`). Ingress controllers drop the replica from active backend sets.
   - The engine sleeps for $T_{\text{quiesce}}$ (2000–5000ms) to allow network routing tables to converge across kube-proxy nodes.
3. **`QUIESCING_INGRESS` $\to$ `DRAINING_IN_FLIGHT`**:
   - Ingress socket listeners are closed via `server.close()`. No new TCP connections are accepted.
   - Active WebSockets receive a RFC 6455 Close Frame with status code `1001 (Going Away)`.
   - The engine monitors active in-flight request counters, waiting for them to reach zero.
4. **`DRAINING_IN_FLIGHT` $\to$ `TEARING_DOWN_DAG`**:
   - Triggered when active requests reach zero OR when `allowedDrainMs` expires.
   - Teardown proceeds strictly in reverse topological DAG order:
     - Phase 1: `QUEUE_WORKERS` (Stop consumer loops, NACK pending messages).
     - Phase 2: `CACHE_STORAGE` (Close Redis / Memcached connections).
     - Phase 3: `PRIMARY_DATABASE` (Drain PostgreSQL pools, rollback uncommitted idle transactions).
     - Phase 4: `OBSERVABILITY` (Flush OpenTelemetry spans and structured logs).
5. **`TEARING_DOWN_DAG` $\to$ `TERMINATED`**:
   - All connection pools closed cleanly. The monotonic watchdog timer is cancelled.
   - Process exits cleanly with status code `0`.

---

## 5. Cross-Language Production Idioms & Hard Anti-Patterns

### 5.1 Go (Golang) Production Discipline

```go
// ✅ Production-Grade Graceful Shutdown in Go with signal.NotifyContext & Reverse Teardown
package main

import (
    "context"
    "errors"
    "log/slog"
    "net/http"
    "os"
    "os/signal"
    "sync"
    "syscall"
    "time"

    "github.com/jackc/pgx/v5/pgxpool"
)

type ServerLifecycle struct {
    httpServer *http.Server
    dbPool     *pgxpool.Pool
    wg         sync.WaitGroup
    isDraining bool
    mu         sync.RWMutex
}

func (s *ServerLifecycle) ReadinessHandler(w http.ResponseWriter, r *http.Request) {
    s.mu.RLock()
    draining := s.isDraining
    s.mu.RUnlock()

    if draining {
        http.Error(w, `{"status":"DRAINING"}`, http.StatusServiceUnavailable)
        return
    }
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusOK)
    _, _ = w.Write([]byte(`{"status":"READY"}`))
}

func main() {
    ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
    defer stop()

    lifecycle := &ServerLifecycle{}
    // Initialize DB Pool & HTTP Server...

    go func() {
        if err := lifecycle.httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
            slog.Error("HTTP server crash", "error", err)
            os.Exit(1)
        }
    }()

    // Block until SIGTERM / SIGINT
    <-ctx.Done()
    slog.Info("Shutdown signal received. Starting graceful drain...")

    // 1. Quiesce Ingress: Flip readiness probe and pause for kube-proxy propagation
    lifecycle.mu.Lock()
    lifecycle.isDraining = true
    lifecycle.mu.Unlock()

    time.Sleep(3 * time.Second) // K8s endpoint propagation pause

    // 2. Bound remaining drain by strict context deadline
    drainCtx, drainCancel := context.WithTimeout(context.Background(), 22*time.Second)
    defer drainCancel()

    // 3. Stop accepting new HTTP connections & drain in-flight requests
    if err := lifecycle.httpServer.Shutdown(drainCtx); err != nil {
        slog.Error("HTTP server shutdown error", "error", err)
    }

    // 4. Wait for background workers
    lifecycle.wg.Wait()

    // 5. Close Database Pool strictly AFTER all HTTP requests & workers finish
    slog.Info("Closing database connection pool...")
    lifecycle.dbPool.Close()

    slog.Info("Graceful shutdown completed cleanly. Exiting.")
}
```

### 5.2 Python (FastAPI / Uvicorn Lifespan)

```python
# ✅ Production FastAPI Lifespan with Reverse Teardown & Ingress Quiescence
import asyncio
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, Response, status

logger = logging.getLogger("shutdown")
is_draining = False

@asynccontextmanager
async def lifespan(app: FastAPI):
    # STARTUP: Connect DB, Warmup caches
    db_pool = await asyncpg.create_pool(dsn=DATABASE_URL, min_size=5, max_size=20)
    app.state.db_pool = db_pool
    yield
    # SHUTDOWN: Triggered on SIGTERM / SIGINT
    global is_draining
    is_draining = True
    logger.info("Flipped readiness probe. Pausing 3s for ingress endpoint removal...")
    await asyncio.sleep(3.0)  # Kubernetes ingress propagation buffer

    logger.info("Closing database pools in reverse topological order...")
    await db_pool.close()
    logger.info("All resources cleaned up cleanly.")

app = FastAPI(lifespan=lifespan)

@app.get("/readyz")
async def readiness():
    if is_draining:
        return Response(content='{"status":"DRAINING"}', status_code=status.HTTP_503_SERVICE_UNAVAILABLE)
    return {"status": "READY"}
```

### 5.3 Model Context Protocol (MCP) Server Child Process Lifecycle

```typescript
// ✅ Safe MCP Child Process Group Execution & Parent Teardown
import { spawn, ChildProcess } from 'node:child_process';

export class SafeMcpChildRunner {
  private activeChildren = new Set<ChildProcess>();

  public spawnSandboxedTool(command: string, args: string[]): ChildProcess {
    // Spawn child in a detached process group so signals can target the entire tree
    const child = spawn(command, args, {
      detached: true,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    this.activeChildren.add(child);
    child.on('exit', () => this.activeChildren.delete(child));
    return child;
  }

  public async terminateAll(): Promise<void> {
    for (const child of this.activeChildren) {
      if (child.pid && !child.killed) {
        try {
          // Negative PID kills the entire process group, eliminating orphan grand-children
          process.kill(-child.pid, 'SIGTERM');
        } catch {
          // Ignore if process already exited
        }
      }
    }

    // Give children 1500ms to exit gracefully before escalating to SIGKILL
    await new Promise((r) => setTimeout(r, 1500));

    for (const child of this.activeChildren) {
      if (child.pid && !child.killed) {
        try {
          process.kill(-child.pid, 'SIGKILL');
        } catch {
          // Process already dead
        }
      }
    }
    this.activeChildren.clear();
  }
}
```

---

## 6. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Check | Automated Validation Command / Metric | Blocking Failure Condition |
| :--- | :--- | :--- | :--- |
| **Gate 1: Dual-Signal Trap** | Verify application intercepts `SIGTERM` and `SIGINT` without immediate abort | `kill -15 $PID` does not cause exit code 143 within first 2000ms | Immediate crash, unhandled signal exit |
| **Gate 2: Readiness Quiescence** | Verify `/readyz` returns HTTP 503 during drain while `/healthz` returns 200 | `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/readyz` returns `503` | `/readyz` returns 200 during draining phase |
| **Gate 3: Ingress Propagation Delay** | Verify sleep pause exists between signal and listener socket close | Elapsed time between `SIGTERM` and port unbound $\ge 2.0\text{s}$ | Port closed in $<100\text{ms}$ after `SIGTERM` |
| **Gate 4: In-Flight Drain Integrity** | Verify active HTTP requests complete successfully with HTTP 200 | Slow-running 3s request finishes 200 during 10s shutdown window | Client receives `ECONNRESET` or `502` |
| **Gate 5: Reverse DAG Teardown** | Verify DB pool is destroyed strictly *after* HTTP server finishes | Zero `database is closed` or `pool destroyed` exceptions in logs | DB closed before active queries finish |
| **Gate 6: Watchdog Deadline Bound** | Verify process unconditionally exits before orchestrator grace limit | Process exits within $T_{\text{watchdog}} \le T_{\text{k8s\_grace}} - 3\text{s}$ | Process hangs $>30\text{s}$ requiring `SIGKILL` |

---
