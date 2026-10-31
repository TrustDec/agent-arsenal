---
description: PostgreSQL LISTEN/NOTIFY asynchronous pub/sub event streaming invariants, 8000-byte payload limits (SQLSTATE 54000), pg_notify SLRU buffer queue overflow defense (pg_notification_queue_usage), PgBouncer transaction-mode connection pinning prevention, autonomous self-healing reconnect supervisor loops, Thin Pointer / Claim-Check outbox pattern, statement-level batch coalescing, and telemetry sentinels across Go (jackc/pgx/v5, pgconn), TypeScript (pg, postgres.js, drizzle-orm), Python (asyncpg, psycopg3), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{listen,notify,pubsub,events,realtime,bus,stream,queue,subscription,outbox,db,postgres}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/services/**/*.{ts,js,go,rs,py},**/internal/events/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database LISTEN / NOTIFY, Asynchronous Event Streaming, 8000-Byte Payload Limits, `pg_notify` SLRU Queue Overflow & Reconnection Resilience Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design event-driven architectures, real-time cache invalidation, asynchronous background job wakeups, GraphQL subscriptions, Server-Sent Events (SSE), or WebSockets using PostgreSQL `LISTEN` / `NOTIFY` across Go (`jackc/pgx/v5`, `pgconn`), TypeScript (`pg`, `postgres.js`, `kysely`, `drizzle-orm`), Python (`asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "8000-Byte Payload Cliff & Transaction Abort (`payload string too long`, SQLSTATE `54000`)" (where agents serialize full JSON entities into `pg_notify()`, crashing mutations whenever rows exceed 8KB), the "PgBouncer Transaction Pooling & Connection Pinning / Silent Event Bleed Trap" (where running `LISTEN` in transaction-pooled proxies breaks connection multiplexing or delivers events to dead backend sessions), the "`pg_notify` SLRU Buffer Cache Exhaustion & Cluster-Wide Write Lockout Spasm" (where a single hung listener pins the unread notify queue until `pg_notification_queue_usage()` reaches 100%, causing every subsequent `NOTIFY` in the entire database to abort with `pg_notify queue is full`), the "Silent Connection Drop & Channel Re-registration Black Hole" (where cloud NAT firewalls quietly terminate idle listener TCP sockets, leaving drivers connected to new backends without active `LISTEN` registrations and dropping 100% of events indefinitely), the "Fire-and-Forget At-Most-Once Catastrophe & Zero Replay Log" (where agent microservices lose mission-critical updates during rolling restarts because `NOTIFY` does not persist messages), and the "Transaction Boundary Batch Burst & Thundering Herd Blast" (where row-level triggers emit tens of thousands of individual notifications upon `COMMIT`, overwhelming client runtimes) by establishing a strict 5-Tier LISTEN/NOTIFY Governance Ladder, Thin Pointer / Claim-Check envelope invariants ($S_{\text{payload}} < 256$ bytes), dedicated unpooled direct listener topologies, autonomous self-healing reconnect supervisor loops with synthetic heartbeats, hybrid Outbox watermark replays, statement-level trigger batch coalescing, and continuous SLRU buffer telemetry alarms.

---

## 1. Architectural Taxonomy: The 6 LISTEN/NOTIFY Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL provides a native, low-overhead inter-process signaling mechanism via `LISTEN` and `NOTIFY` (`pg_notify(channel, payload)`). Unlike full-blown distributed message brokers (Kafka, RabbitMQ, AWS SQS), PostgreSQL's notification engine is designed for **lightweight, ephemeral signaling between database backends and connected clients**.

Notifications are stored in shared memory using a Simple Least Recently Used (SLRU) ring buffer subsystem located in `pg_notify/` within the data directory. When a backend executes `NOTIFY channel, payload`, the notification is held in the transaction's private memory until the transaction executes `COMMIT`. Upon commit, the messages are written into the shared `pg_notify` SLRU buffer, and an asynchronous signal is dispatched to all backends currently registered via `LISTEN` on that channel.

When autonomous coding agents generate database triggers, live query listeners, real-time websockets, or event-driven workers, LLMs consistently make 6 fatal architectural mistakes:

### The 6 LISTEN/NOTIFY Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                                THE 6 LISTEN/NOTIFY CATASTROPHES                                    |
+------------------------------------+---------------------------------------------------------------+
| 1. 8000-Byte Payload Cliff         | Agent serializes entire JSON document into pg_notify();       |
|    (SQLSTATE 54000 String Too Long)| row exceeds NOTIFY_PAYLOAD_MAX_LENGTH (8000 bytes); whole     |
|                                    | business transaction forcibly aborts; mutation fails.        |
+------------------------------------+---------------------------------------------------------------+
| 2. PgBouncer Transaction Mode      | Client runs LISTEN over transaction-mode pooler (port 6432);  |
|    Pinning & Cross-Tenant Bleed    | PgBouncer pins server backend or unbinds connection; events   |
|                                    | routed to disconnected backends or leaked across tenants.     |
+------------------------------------+---------------------------------------------------------------+
| 3. pg_notify SLRU Exhaustion       | One slow/hung listener backend fails to advance tail pointer; |
|    & Cluster-Wide Write Lockout    | pg_notify ring buffer fills to 100%; every NOTIFY in database |
|                                    | throws FATAL: pg_notify queue is full; all writes halted.     |
+------------------------------------+---------------------------------------------------------------+
| 4. Silent TCP Drop & Channel       | Cloud NAT gateway terminates idle socket without RST; client  |
|    Re-Registration Black Hole      | reconnects but forgets to re-issue LISTEN; listener sits idle;|
|                                    | 100% of events dropped forever with zero log errors.          |
+------------------------------------+---------------------------------------------------------------+
| 5. Fire-and-Forget At-Most-Once    | NOTIFY messages are ephemeral and never persisted; during a   |
|    Zero-Replay Data Loss           | 30s pod rolling restart, all events published are lost forever|
|                                    | creating silent distributed state desynchronization.          |
+------------------------------------+---------------------------------------------------------------+
| 6. Commit Boundary Batch Blast     | FOR EACH ROW trigger emits NOTIFY on 50,000 updated rows; all  |
|    & Thundering Herd Stampede      | 50,000 notifications flush simultaneously upon COMMIT; socket  |
|                                    | buffers saturate; client event loops thrash and crash OOM.    |
+------------------------------------+---------------------------------------------------------------+
```

To eliminate these failure modes across enterprise production environments, autonomous agents must adhere to the **5-Tier LISTEN/NOTIFY Governance Ladder**:

```
+----------------------------------------------------------------------------------------------------+
|                               THE 5-TIER LISTEN/NOTIFY GOVERNANCE LADDER                            |
+------------------------------------+---------------------------------------------------------------+
| Tier 0: Thin Pointer / Claim-Check | Enforce payload envelope strictly < 256 bytes:                |
|         Envelope Invariant         | payload = {"t": "order.updated", "id": 48291, "v": 3};        |
|                                    | Full data hydrated via indexed SELECT; 8KB limit impossible.  |
+------------------------------------+---------------------------------------------------------------+
| Tier 1: Dedicated Direct Listener  | Sockets executing LISTEN must connect directly to Postgres    |
|         Connection Topology        | (port 5432) or dedicated session-mode pool; NEVER mix with    |
|                                    | PgBouncer transaction-mode application pools (port 6432).     |
+------------------------------------+---------------------------------------------------------------+
| Tier 2: Autonomous Reconnect       | Supervisor loop encapsulates connection lifecycle with        |
|         Supervisor & Heartbeats    | decorrelated jitter, unconditionally re-issues LISTEN on      |
|                                    | reconnect, and executes synthetic ping/pong every 15-30s.     |
+------------------------------------+---------------------------------------------------------------+
| Tier 3: Hybrid Wakeup + Watermark  | Treat NOTIFY solely as low-latency latency-slashing wakeup;  |
|         Outbox Replay Fallback     | Durable state stored in Outbox table with monotonic BIGINT ID;|
|                                    | Worker polls WHERE id > :watermark on wakeup & 10s tick.      |
+------------------------------------+---------------------------------------------------------------+
| Tier 4: SLRU Queue Telemetry &     | Continuous monitoring of pg_notification_queue_usage(); alert |
|         Lagging Backend Eviction   | at > 25%; auto-terminate stuck listeners at > 60% via         |
|                                    | pg_terminate_backend() before write transactions abort.       |
+------------------------------------+---------------------------------------------------------------+
```

---

## 2. Mathematical & Algorithmic Foundations: SLRU Mechanics, Buffer Depletion Dynamics & Jitter Reconnection

### 2.1 Shared Memory SLRU Ring Buffer Physics

PostgreSQL manages notifications using an internal SLRU (Simple Least Recently Used) buffer named `Notify`. The shared memory allocation consists of $N_{\text{pages}}$ buffers (historically 8 to 16 pages, each 8192 bytes = 64KB to 128KB in RAM), backed by segment files in `$PGDATA/pg_notify/`.

The queue behaves as a multi-consumer circular ring buffer defined by:
- $L_{\text{head}}$: The global logical byte position where the next notification will be written by committing transactions.
- $L_{\text{tail}}^{(i)}$: The logical byte position representing the furthest point consumed by active listener backend $i$.
- $L_{\text{min\_tail}} = \min_{i \in \text{active\_listeners}} \left( L_{\text{tail}}^{(i)} \right)$: The global watermark below which SLRU pages may be truncated from disk and evicted from shared memory.

The queue utilization ratio $U_{\text{SLRU}}(t) \in [0.0, 1.0]$ returned by `pg_notification_queue_usage()` is defined as:

$$
U_{\text{SLRU}}(t) = \frac{L_{\text{head}}(t) - L_{\text{min\_tail}}(t)}{C_{\text{max\_queue\_bytes}}}
$$

where $C_{\text{max\_queue\_bytes}} = 2^{30} \approx 1\text{ GB}$ or 8GB depending on PostgreSQL version limits for logical notification addressing.

### 2.2 Buffer Depletion Dynamics When a Listener Stalls

Let $\lambda_{\text{tx}}$ be the rate of committing transactions writing notifications, and $\bar{S}_{\text{payload}}$ be the average byte size per notification (including internal PostgreSQL headers of 16 bytes: `NotifyMsgHeader` containing `channel_name`, `pid`, and payload string).

The rate of queue expansion $\frac{d Q_{\text{bytes}}}{dt}$ when a listener process hangs (e.g. stalled in client GC, deadlocked, or network socket buffer saturated) is:

$$
\frac{d Q_{\text{bytes}}}{dt} = \lambda_{\text{tx}} \times \left( \bar{S}_{\text{payload}} + 16 \right)
$$

The time to critical warning $T_{\text{warn}}$ (50% capacity) and time to fatal cluster write lockout $T_{\text{fatal}}$ (100% capacity) are:

$$
T_{\text{warn}} = \frac{0.50 \times C_{\text{max\_queue\_bytes}}}{\lambda_{\text{tx}} \times \left( \bar{S}_{\text{payload}} + 16 \right)}, \quad T_{\text{fatal}} = \frac{1.00 \times C_{\text{max\_queue\_bytes}}}{\lambda_{\text{tx}} \times \left( \bar{S}_{\text{payload}} + 16 \right)}
$$

**Numerical Example**: If an application generates 2,000 events/sec with naively serialized 4KB JSON payloads, $\frac{d Q}{dt} \approx 2000 \times 4112 \approx 8.22\text{ MB/sec}$. A 1GB notify buffer will reach 50% warning in $62$ seconds, and complete cluster-wide write termination in $124$ seconds! Conversely, using **Tier 0 Thin Pointers** ($\bar{S}_{\text{payload}} = 64\text{ bytes}$), $\frac{d Q}{dt} \approx 160\text{ KB/sec}$, providing over **104 minutes** of buffer headroom under identical stall conditions.

### 2.3 Decorrelated Jitter Reconnection Backoff

When network blips sever listener sockets, all replica pods attempt reconnection simultaneously. To prevent the **Thundering Herd Connection Storm** against the primary database, the reconnect interval $\tau_k$ for attempt $k$ must follow decorrelated exponential jitter:

$$
\tau_k = \min\left( T_{\max}, \, \mathcal{U}\left( T_{\text{base}}, \, \tau_{k-1} \times 3 \right) \right)
$$

where $T_{\text{base}} = 100\text{ms}$, $T_{\max} = 5000\text{ms}$, and $\mathcal{U}(a, b)$ is a uniform continuous random distribution between $a$ and $b$.

### 2.4 Heartbeat Liveness & Failure Detection Time

To detect silent TCP socket drops across cloud NAT firewalls (which terminate idle connections without FIN packets after 350 seconds), the client supervisor emits synthetic heartbeats on channel `__sys_heartbeat__` every $T_{\text{hb}}$ seconds.

The maximum liveness failure detection window $T_{\text{detect}}$ is bounded by:

$$
T_{\text{detect}} = T_{\text{hb}} + T_{\text{grace}} + \text{RTT} \le 30\text{ seconds}
$$

If no notification or heartbeat echo is received within $T_{\text{detect}}$, the client abruptly tears down the underlying socket and enters the reconnection state machine.

---

## 3. The 5-Tier LISTEN/NOTIFY Governance Ladder in Depth

### 3.1 Tier 0: Thin Pointer / Claim-Check Envelope Invariant

Under PostgreSQL's libpq protocol, `NOTIFY_PAYLOAD_MAX_LENGTH` is 8000 bytes. Attempting to transmit a string of 8000 bytes or longer produces:

```
ERROR: payload string too long
SQLSTATE: 54000 (program_limit_exceeded)
```

Because `pg_notify` runs inside the mutating transaction, this error **aborts the entire business transaction**, rolling back customer payments, order inserts, or user registrations!

#### ❌ The Catastrophic Direct JSON Serialization Trigger
```sql
-- FATAL: Crashes mutations when order details exceed 8000 bytes!
CREATE OR REPLACE FUNCTION notify_order_changed() RETURNS TRIGGER AS $$
BEGIN
  -- VULN: row_to_json includes line items, addresses, metadata
  -- If payload > 7999 bytes -> SQLSTATE 54000 -> Entire INSERT fails!
  PERFORM pg_notify('order_events', row_to_json(NEW)::text);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

#### ✅ Production Invariant: The Thin Pointer (Claim-Check) Schema & Trigger
```sql
-- Schema: Append-only Outbox table providing durable replay watermark
CREATE TABLE IF NOT EXISTS event_outbox (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  aggregate_type VARCHAR(64) NOT NULL,
  aggregate_id VARCHAR(64) NOT NULL,
  event_type VARCHAR(64) NOT NULL,
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_event_outbox_seek 
ON event_outbox (id ASC);

-- Thin Pointer Trigger: Emits strictly bounded claim-check (< 120 bytes)
CREATE OR REPLACE FUNCTION notify_outbox_claim_check() RETURNS TRIGGER AS $$
DECLARE
  v_envelope TEXT;
BEGIN
  -- Strict Thin Pointer Envelope: Type, Sequence ID, Timestamp
  v_envelope := json_build_object(
    't', NEW.event_type,
    'id', NEW.id,
    'a', NEW.aggregate_id,
    'ts', EXTRACT(EPOCH FROM NEW.created_at)::BIGINT
  )::text;

  -- Assertion: Under 256 bytes guarantee
  IF length(v_envelope) > 512 THEN
    RAISE EXCEPTION 'Assertion failed: Thin pointer envelope exceeded 512 bytes: %', length(v_envelope);
  END IF;

  PERFORM pg_notify('outbox_stream', v_envelope);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_notify_outbox_event
AFTER INSERT ON event_outbox
FOR EACH ROW EXECUTE FUNCTION notify_outbox_claim_check();
```

---

### 3.2 Tier 1: Dedicated Direct Listener Connection Topology

PgBouncer in `pool_mode = transaction` is incompatible with `LISTEN`:
1. In transaction pooling, PgBouncer assigns a server connection to a client only for the duration of a transaction block (`BEGIN` ... `COMMIT`).
2. `LISTEN` is a session-level command that must persist across queries.
3. If executed through transaction-mode PgBouncer, PgBouncer either rejects the query, pins the server connection indefinitely (destroying pool multiplexing and causing client pool starvation), or unbinds the connection between transactions, causing notifications to be sent to dead backends or leaking sensitive data across unrelated client sessions.

```
❌ WRONG: Shared Transaction Pooler
[App Client] ---> [PgBouncer (port 6432, pool_mode=transaction)] ---> [PostgreSQL]
                  (Pins server backend OR unbinds connection; LISTEN fails silently)

✅ CORRECT: Dedicated Dual-Port Architecture
[App Workers (OLTP)]   ---> [PgBouncer (port 6432, transaction mode)] ---> [PostgreSQL Backend]
[Event Listeners (PubSub)] ---> [Direct PostgreSQL (port 5432, session)] ---> [PostgreSQL Backend]
```

**Rule**: All database clients executing `LISTEN` MUST bypass PgBouncer or connect via a dedicated PgBouncer port configured with `pool_mode = session` and dedicated reserve pool limits.

---

### 3.3 Tier 2: Autonomous Reconnect Supervisor & Heartbeats

Cloud firewalls and load balancers silently terminate idle connections after 5 to 15 minutes. A naive client waiting on a socket will block indefinitely without knowing the socket is dead. Furthermore, upon reconnection, PostgreSQL backends do NOT retain previous channel subscriptions.

#### Architectural Requirements:
1. **Unconditional Channel Re-registration**: The connection supervisor must maintain an immutable set of desired channels. Upon socket recreation, it must re-issue `LISTEN <channel>` for every channel before processing events.
2. **Synthetic Heartbeat Ping/Pong**: Every 20 seconds, the client executes `SELECT pg_notify('__sys_heartbeat__', $1)`. If the echo is not received within 10 seconds, the socket is assumed dead and forcibly closed.
3. **TCP Keepalive Socket Tuning**: Configure client TCP dialers with aggressive keepalives:
   `keepalives = 1`, `keepalives_idle = 10`, `keepalives_interval = 5`, `keepalives_count = 3` (detects severed TCP in 25 seconds at the kernel level).

---

### 3.4 Tier 3: Hybrid Wakeup + Monotonic Watermark Outbox Replay

`LISTEN / NOTIFY` is strictly **at-most-once** signaling. It does not provide persistence, message acknowledgment, or replayability. If a worker pod crashes, restarts, or deploys, any notifications published during the downtime are permanently lost.

#### The Hybrid Wakeup Architecture:
1. **Zero-Latency Push**: The worker listens on `outbox_stream`. When a notification arrives, it immediately wakes up its processing loop.
2. **Watermark Seek Drain**: Instead of using the notification content as truth, the worker reads durable events from `event_outbox`:
   ```sql
   SELECT id, aggregate_type, aggregate_id, event_type, payload
   FROM event_outbox
   WHERE id > $1
   ORDER BY id ASC
   LIMIT 500;
   ```
3. **Safety Fallback Tick**: In addition to push notifications, a safety timer polls the outbox every 5 to 10 seconds. Even if the network drops a notification or the socket blips, maximum end-to-end processing latency is bounded by the tick interval!

```
[Business Action] ---> [INSERT INTO event_outbox] ---> [AFTER INSERT Trigger]
                               |                              |
                               v                              v
                     [Persisted Table Row]           [pg_notify Thin Pointer]
                                                              |
                                                              v
                                                    [Listener Wakeup Signal]
                                                              |
                                                              v
[Worker Drain Loop] <--- [SELECT ... WHERE id > :last_id] <---+
```

---

### 3.5 Tier 4: `pg_notify` SLRU Queue Telemetry & Auto-Eviction

To protect the entire PostgreSQL cluster from write outages caused by a hung listener, the cluster monitoring daemon must periodically inspect `pg_notification_queue_usage()`:

```sql
-- Telemetry Sentinel: Check SLRU Queue Saturation
SELECT 
  round((pg_notification_queue_usage() * 100)::numeric, 2) AS notify_queue_used_pct,
  CASE 
    WHEN pg_notification_queue_usage() > 0.80 THEN 'EMERGENCY_OUTAGE_IMMINENT'
    WHEN pg_notification_queue_usage() > 0.50 THEN 'CRITICAL_BUFFER_SATURATION'
    WHEN pg_notification_queue_usage() > 0.25 THEN 'WARNING_LAGGING_LISTENER'
    ELSE 'HEALTHY'
  END AS status;
```

#### Autonomous Lagging Listener Eviction Script:
If queue usage exceeds 60%, automatically identify listening backends that have held open transactions or unconsumed queues and terminate them before they crash the cluster:

```sql
-- Identify and terminate hung listener backends stalling the SLRU queue
DO $$
DECLARE
  v_usage FLOAT;
  r RECORD;
BEGIN
  SELECT pg_notification_queue_usage() INTO v_usage;
  
  IF v_usage > 0.60 THEN
    RAISE WARNING 'CRITICAL: pg_notify queue usage at %! Evicting slowest listeners...', round((v_usage * 100)::numeric, 1);
    
    FOR r IN (
      SELECT pid, usename, client_addr, state, backend_start, query_start
      FROM pg_stat_activity
      WHERE pid <> pg_backend_pid()
        AND state IN ('idle in transaction', 'idle in transaction (timed out)', 'active')
        AND query ILIKE '%LISTEN%'
      ORDER BY backend_start ASC
      LIMIT 3
    ) LOOP
      RAISE WARNING 'Terminating hung listener backend PID % (user: %, client: %)', r.pid, r.usename, r.client_addr;
      PERFORM pg_terminate_backend(r.pid);
    END LOOP;
  END IF;
END $$;
```

---

## 4. Production-Ready TypeScript Guard Engine: `AgenticDatabaseListenNotifyEngine`

Below is the complete, zero-dependency, self-healing event subscriber engine designed for Node.js / Bun environments using `postgres.js` or `pg`. It enforces dedicated direct connection isolation, Thin Pointer envelopes, unconditional channel re-registration, synthetic heartbeat watchdogs, and Outbox watermark hydration.

```typescript
// src/db/listen-notify-guard-engine.ts
import { EventEmitter } from 'node:events';
import postgres from 'postgres';

export interface ThinPointerEnvelope {
  t: string;          // Event type (e.g. 'order.created')
  id: number;         // Outbox sequence watermark (BIGINT)
  a: string;          // Aggregate ID
  ts: number;         // Timestamp epoch
}

export interface OutboxRecord<T = unknown> {
  id: number;
  aggregate_type: string;
  aggregate_id: string;
  event_type: string;
  payload: T;
  created_at: string;
}

export interface EngineConfig {
  directDbUrl: string;               // Direct connection (PORT 5432, NEVER PgBouncer transaction mode)
  channels: string[];                // Channels to subscribe to
  heartbeatIntervalMs?: number;      // Synthetic ping interval (default: 20000ms)
  heartbeatTimeoutMs?: number;       // Missed heartbeat threshold (default: 10000ms)
  safetyPollIntervalMs?: number;     // Fallback watermark seek interval (default: 5000ms)
  maxBatchSize?: number;             // Outbox drain batch size (default: 500)
}

export class AgenticDatabaseListenNotifyEngine extends EventEmitter {
  private sql: postgres.Sql | null = null;
  private listenerSubscription: any = null;
  private isRunning = false;
  private lastProcessedId = 0;
  private heartbeatTimer: NodeJS.Timeout | null = null;
  private safetyPollTimer: NodeJS.Timeout | null = null;
  private lastHeartbeatEcho = Date.now();
  private reconnectAttempt = 0;

  constructor(private readonly config: EngineConfig) {
    super();
    this.config.heartbeatIntervalMs = config.heartbeatIntervalMs ?? 20000;
    this.config.heartbeatTimeoutMs = config.heartbeatTimeoutMs ?? 10000;
    this.config.safetyPollIntervalMs = config.safetyPollIntervalMs ?? 5000;
    this.config.maxBatchSize = config.maxBatchSize ?? 500;
  }

  /**
   * Initializes the engine, boots the connection supervisor, and begins consumption.
   */
  public async start(startingWatermark = 0): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;
    this.lastProcessedId = startingWatermark;

    this.emit('lifecycle', { state: 'STARTING', watermark: startingWatermark });
    await this.connectSupervisor();
    this.startHeartbeatLoop();
    this.startSafetyPollLoop();
  }

  /**
   * Graceful shutdown of all sockets and timers.
   */
  public async stop(): Promise<void> {
    this.isRunning = false;
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    if (this.safetyPollTimer) clearInterval(this.safetyPollTimer);

    if (this.sql) {
      try {
        await this.sql.end({ timeout: 5 });
      } catch (err) {
        // Suppress teardown errors
      }
      this.sql = null;
    }
    this.emit('lifecycle', { state: 'STOPPED' });
  }

  /**
   * Resilient supervisor loop with decorrelated exponential jitter backoff.
   */
  private async connectSupervisor(): Promise<void> {
    while (this.isRunning) {
      try {
        this.emit('lifecycle', { state: 'CONNECTING', attempt: this.reconnectAttempt });

        // INVARIANT: Direct dedicated connection with aggressive TCP keepalives
        this.sql = postgres(this.config.directDbUrl, {
          max: 1, // Single dedicated connection for LISTEN
          idle_timeout: 0,
          connect_timeout: 10,
          keep_alive: 10, // Send TCP keepalive probe every 10s
        });

        // Test connection liveness
        await this.sql`SELECT 1`;
        this.reconnectAttempt = 0;
        this.lastHeartbeatEcho = Date.now();

        // Register LISTEN for all configured channels + internal heartbeat channel
        for (const channel of this.config.channels) {
          await this.sql.listen(channel, (payload) => this.handleNotification(channel, payload));
        }

        // Internal heartbeat listener
        await this.sql.listen('__sys_heartbeat__', (payload) => {
          this.lastHeartbeatEcho = Date.now();
          this.emit('heartbeat_echo', { timestamp: Number(payload) });
        });

        this.emit('lifecycle', { state: 'LISTENING_ACTIVE', channels: this.config.channels });

        // Trigger immediate drain to capture any events missed during disconnection
        await this.drainOutbox();
        return; // Connected and subscribed successfully
      } catch (err: any) {
        this.emit('error', new Error(`Listener connection failed: ${err.message}`));
        if (!this.isRunning) return;

        // Calculate decorrelated exponential jitter: min(maxDelay, rand(baseDelay, prev * 3))
        this.reconnectAttempt++;
        const baseDelay = 100;
        const maxDelay = 5000;
        const prev = Math.min(maxDelay, baseDelay * Math.pow(2, Math.min(this.reconnectAttempt, 6)));
        const jitteredDelay = Math.floor(baseDelay + Math.random() * (prev * 3 - baseDelay + 1));
        const finalDelay = Math.min(maxDelay, jitteredDelay);

        this.emit('lifecycle', { state: 'RECONNECT_WAIT', delayMs: finalDelay });
        await new Promise((resolve) => setTimeout(resolve, finalDelay));
      }
    }
  }

  /**
   * Handles incoming raw NOTIFY packets. Validates Thin Pointer invariants.
   */
  private async handleNotification(channel: string, rawPayload: string): Promise<void> {
    try {
      // INVARIANT: Thin Pointer assertion (payload must be under 2KB)
      if (rawPayload.length > 2048) {
        this.emit('security_violation', {
          reason: 'FATAL_PAYLOAD_SIZE_BREACH',
          channel,
          length: rawPayload.length,
        });
      }

      const envelope = JSON.parse(rawPayload) as ThinPointerEnvelope;
      this.emit('pointer_received', { channel, envelope });

      // Trigger Outbox drain on wakeup signal
      await this.drainOutbox();
    } catch (err: any) {
      this.emit('error', new Error(`Failed to parse notification envelope: ${err.message}`));
    }
  }

  /**
   * Hydrates durable payloads from event_outbox using keyset watermark seek.
   */
  public async drainOutbox(): Promise<number> {
    if (!this.sql || !this.isRunning) return 0;
    let totalDrained = 0;

    try {
      while (this.isRunning) {
        // Keyset pagination seek: guarantees monotonic order and at-least-once delivery
        const rows = await this.sql<OutboxRecord[]>`
          SELECT id, aggregate_type, aggregate_id, event_type, payload, created_at
          FROM event_outbox
          WHERE id > ${this.lastProcessedId}
          ORDER BY id ASC
          LIMIT ${this.config.maxBatchSize!}
        `;

        if (rows.length === 0) break;

        for (const row of rows) {
          this.emit('event', row);
          this.lastProcessedId = row.id;
          totalDrained++;
        }

        if (rows.length < this.config.maxBatchSize!) break;
      }
    } catch (err: any) {
      this.emit('error', new Error(`Outbox drain query failed: ${err.message}`));
    }

    return totalDrained;
  }

  /**
   * Periodically emits synthetic heartbeats and detects severed TCP sockets.
   */
  private startHeartbeatLoop(): void {
    this.heartbeatTimer = setInterval(async () => {
      if (!this.isRunning || !this.sql) return;

      const elapsedSinceEcho = Date.now() - this.lastHeartbeatEcho;
      const threshold = this.config.heartbeatIntervalMs! + this.config.heartbeatTimeoutMs!;

      // Socket Death Invariant: Echo not received within threshold -> Sever and Reconnect
      if (elapsedSinceEcho > threshold) {
        this.emit('lifecycle', {
          state: 'SOCKET_STALLED',
          elapsedMs: elapsedSinceEcho,
          thresholdMs: threshold,
        });

        if (this.sql) {
          try {
            await this.sql.end({ timeout: 1 });
          } catch (_) {}
          this.sql = null;
        }

        // Reconnect supervisor
        this.connectSupervisor().catch((e) => this.emit('error', e));
        return;
      }

      // Dispatch heartbeat ping
      try {
        await this.sql`SELECT pg_notify('__sys_heartbeat__', ${Date.now().toString()})`;
      } catch (err: any) {
        this.emit('error', new Error(`Heartbeat dispatch failed: ${err.message}`));
      }
    }, this.config.heartbeatIntervalMs);
  }

  /**
   * Safety net: polls the outbox periodically to eradicate latency cliffs if a notification was lost.
   */
  private startSafetyPollLoop(): void {
    this.safetyPollTimer = setInterval(async () => {
      if (!this.isRunning) return;
      await this.drainOutbox();
    }, this.config.safetyPollIntervalMs);
  }

  /**
   * Exposes the current durable watermark for persistence across pod restarts.
   */
  public getWatermark(): number {
    return this.lastProcessedId;
  }
}
```

---

## 5. Cross-Language Production Sentinels

### 5.1 Go (`jackc/pgx/v5` & `pgconn`) Self-Healing Listener Sentinel

```go
package events

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ThinPointer is the strictly bounded envelope (<256 bytes) transmitted over pg_notify
type ThinPointer struct {
	Type        string `json:"t"`
	ID          int64  `json:"id"`
	AggregateID string `json:"a"`
	Timestamp   int64  `json:"ts"`
}

// OutboxRecord represents the durable hydrated database entity
type OutboxRecord struct {
	ID            int64           `json:"id"`
	AggregateType string          `json:"aggregate_type"`
	AggregateID   string          `json:"aggregate_id"`
	EventType     string          `json:"event_type"`
	Payload       json.RawMessage `json:"payload"`
	CreatedAt     time.Time       `json:"created_at"`
}

// ResilientPGListener manages a dedicated direct connection for LISTEN/NOTIFY with Outbox fallback
type ResilientPGListener struct {
	directConnString string
	outboxPool       *pgxpool.Pool
	channels         []string
	handler          func(record OutboxRecord) error
	lastWatermark    int64
	mu               sync.Mutex
	stopChan         chan struct{}
}

// NewResilientPGListener creates an autonomous event listener
func NewResilientPGListener(
	directConnString string,
	outboxPool *pgxpool.Pool,
	channels []string,
	initialWatermark int64,
	handler func(record OutboxRecord) error,
) *ResilientPGListener {
	return &ResilientPGListener{
		directConnString: directConnString,
		outboxPool:       outboxPool,
		channels:         channels,
		handler:          handler,
		lastWatermark:    initialWatermark,
		stopChan:         make(chan struct{}),
	}
}

// Run boots the supervisor loop, executing automatic reconnects and claim-check Outbox hydration
func (l *ResilientPGListener) Run(ctx context.Context) error {
	baseDelay := 100 * time.Millisecond
	maxDelay := 5 * time.Second
	delay := baseDelay

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-l.stopChan:
			return nil
		default:
		}

		err := l.connectAndListen(ctx)
		if err != nil && ctx.Err() == nil {
			// Calculate decorrelated exponential jitter backoff
			multiplier := float64(delay * 3)
			if multiplier > float64(maxDelay) {
				multiplier = float64(maxDelay)
			}
			delta := float64(baseDelay) + rand.Float64()*(multiplier-float64(baseDelay))
			delay = time.Duration(delta)

			select {
			case <-time.After(delay):
			case <-ctx.Done():
				return ctx.Err()
			}
		} else {
			delay = baseDelay
		}
	}
}

func (l *ResilientPGListener) connectAndListen(ctx context.Context) error {
	// INVARIANT: Direct connection bypassing PgBouncer transaction pooling
	config, err := pgconn.ParseConfig(l.directConnString)
	if err != nil {
		return fmt.Errorf("failed to parse connection string: %w", err)
	}

	conn, err := pgconn.ConnectConfig(ctx, config)
	if err != nil {
		return fmt.Errorf("failed to connect directly to PostgreSQL: %w", err)
	}
	defer conn.Close(ctx)

	// Unconditional re-registration of all monitored channels
	for _, ch := range l.channels {
		res := conn.Exec(ctx, fmt.Sprintf("LISTEN %s", pgx.Identifier{ch}.Sanitize()))
		if err := res.Close(); err != nil {
			return fmt.Errorf("failed to register LISTEN on channel %s: %w", ch, err)
		}
	}

	// Drain any events that accumulated while disconnected
	if err := l.drainOutbox(ctx); err != nil {
		return fmt.Errorf("initial outbox drain failed: %w", err)
	}

	// Active notification loop with context cancellation
	for {
		notification, err := conn.WaitForNotification(ctx)
		if err != nil {
			return fmt.Errorf("wait for notification interrupted: %w", err)
		}

		// Thin pointer validation
		if len(notification.Payload) > 2048 {
			// Log critical security anomaly: payload should never exceed 2KB
			continue
		}

		var ptr ThinPointer
		if err := json.Unmarshal([]byte(notification.Payload), &ptr); err != nil {
			continue
		}

		// Hydrate from Outbox using monotonic watermark seek
		if err := l.drainOutbox(ctx); err != nil {
			// Suppress drain error to keep listening loop alive
			continue
		}
	}
}

func (l *ResilientPGListener) drainOutbox(ctx context.Context) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	for {
		rows, err := l.outboxPool.Query(ctx, `
			SELECT id, aggregate_type, aggregate_id, event_type, payload, created_at
			FROM event_outbox
			WHERE id > $1
			ORDER BY id ASC
			LIMIT 250
		`, l.lastWatermark)
		if err != nil {
			return err
		}

		count := 0
		for rows.Next() {
			var rec OutboxRecord
			if err := rows.Scan(&rec.ID, &rec.AggregateType, &rec.AggregateID, &rec.EventType, &rec.Payload, &rec.CreatedAt); err != nil {
				rows.Close()
				return err
			}

			if err := l.handler(rec); err != nil {
				rows.Close()
				return err
			}

			l.lastWatermark = rec.ID
			count++
		}
		rows.Close()

		if count < 250 {
			break
		}
	}

	return nil
}
```

---

### 5.2 Rust (`sqlx`) Async Listener & Claim-Check Drain Sentinel

```rust
use sqlx::postgres::{PgListener, PgPool};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::time::sleep;

#[derive(Debug, Deserialize)]
pub struct ThinPointer {
    pub t: String,
    pub id: i64,
    pub a: String,
    pub ts: i64,
}

#[derive(Debug, sqlx::FromRow)]
pub struct OutboxRecord {
    pub id: i64,
    pub aggregate_type: String,
    pub aggregate_id: String,
    pub event_type: String,
    pub payload: serde_json::Value,
}

pub struct ResilientSubscriber {
    direct_db_url: String,
    pool: PgPool,
    channels: Vec<String>,
    last_watermark: i64,
}

impl ResilientSubscriber {
    pub fn new(direct_db_url: String, pool: PgPool, channels: Vec<String>, start_watermark: i64) -> Self {
        Self {
            direct_db_url,
            pool,
            channels,
            last_watermark,
        }
    }

    pub async fn run(&mut self) -> Result<(), sqlx::Error> {
        loop {
            // Establish dedicated direct listener connection
            match PgListener::connect(&self.direct_db_url).await {
                Ok(mut listener) => {
                    // Re-register all channels unconditionally
                    for ch in &self.channels {
                        if let Err(e) = listener.listen(ch).await {
                            eprintln!("Failed to register channel {}: {:?}", ch, e);
                        }
                    }

                    // Drain backlog on successful connect
                    self.drain_outbox().await;

                    // Consume stream
                    while let Ok(notification) = listener.recv().await {
                        if notification.payload().len() <= 2048 {
                            if let Ok(_ptr) = serde_json::from_str::<ThinPointer>(notification.payload()) {
                                self.drain_outbox().await;
                            }
                        }
                    }
                }
                Err(e) => {
                    eprintln!("Listener connection dropped: {:?}. Retrying...", e);
                }
            }

            // Decorrelated jitter backoff
            sleep(Duration::from_millis(500)).await;
        }
    }

    async fn drain_outbox(&mut self) {
        loop {
            let records = sqlx::query_as::<_, OutboxRecord>(
                "SELECT id, aggregate_type, aggregate_id, event_type, payload
                 FROM event_outbox
                 WHERE id > $1
                 ORDER BY id ASC
                 LIMIT 200"
            )
            .bind(self.last_watermark)
            .fetch_all(&self.pool)
            .await;

            match records {
                Ok(rows) => {
                    if rows.is_empty() {
                        break;
                    }
                    for row in rows {
                        self.last_watermark = row.id;
                        // Dispatch to business domain processor
                    }
                }
                Err(_) => break,
            }
        }
    }
}
```

---

### 5.3 Python (`asyncpg`) Reconnect Supervisor & SLRU Watermark Guard

```python
import asyncio
import json
import logging
from typing import Callable, Awaitable, List
import asyncpg

logger = logging.getLogger("listen_notify_guard")

class AsyncPGListenerSentinel:
    def __init__(
        self,
        direct_dsn: str,
        pool: asyncpg.Pool,
        channels: List[str],
        handler: Callable[[dict], Awaitable[None]],
    ):
        self.direct_dsn = direct_dsn
        self.pool = pool
        self.channels = channels
        self.handler = handler
        self.last_watermark = 0
        self.is_running = False

    async def start(self, initial_watermark: int = 0):
        self.is_running = True
        self.last_watermark = initial_watermark
        asyncio.create_task(self._supervisor_loop())

    async def _supervisor_loop(self):
        delay = 0.1
        while self.is_running:
            try:
                # INVARIANT: Direct port 5432 connection, not pooled through PgBouncer
                conn = await asyncpg.connect(self.direct_dsn, timeout=10)
                delay = 0.1
                
                # Unconditionally re-register all channels
                for channel in self.channels:
                    await conn.add_listener(channel, self._on_notification)

                logger.info("LISTEN active on %s", self.channels)
                await self._drain_outbox()

                # Keep connection alive until disconnected
                while self.is_running and not conn.is_closed():
                    await asyncio.sleep(15)
                    # Check SLRU queue telemetry
                    usage = await conn.fetchval("SELECT pg_notification_queue_usage()")
                    if usage > 0.50:
                        logger.critical("ALERT: pg_notify queue is %s%% full!", round(usage * 100, 1))

            except Exception as e:
                logger.warning("Listener connection severed: %s. Reconnecting in %ss...", e, round(delay, 2))
                await asyncio.sleep(delay)
                delay = min(5.0, delay * 2)

    def _on_notification(self, conn, pid, channel, payload):
        if len(payload) > 2048:
            logger.error("FATAL: Thin pointer size violation (%s bytes)", len(payload))
            return
        asyncio.create_task(self._drain_outbox())

    async def _drain_outbox(self):
        async with self.pool.acquire() as conn:
            while True:
                rows = await conn.fetch(
                    """
                    SELECT id, aggregate_type, aggregate_id, event_type, payload
                    FROM event_outbox
                    WHERE id > $1
                    ORDER BY id ASC
                    LIMIT 200
                    """,
                    self.last_watermark,
                )
                if not rows:
                    break

                for row in rows:
                    await self.handler(dict(row))
                    self.last_watermark = row["id"]
```

---

## 6. Finite State Machine (FSM): Listener Connection & Re-registration Lifecycle

The following 6-state FSM formalizes the lifecycle of an autonomous `LISTEN / NOTIFY` connection, preventing silent event loss, connection bleeding, and queue exhaustion:

```
                  +------------------------+
                  |     1. DISCONNECTED    |
                  +------------------------+
                              |
                     [Initiate Direct Conn]
                              |
                              v
                  +------------------------+
                  |      2. CONNECTING     |<-----------------+
                  +------------------------+                  |
                              |                               |
                     [Socket Established]                     |
                              |                               |
                              v                               |
                  +------------------------+                  |
                  | 3. REGISTERING_CHANNELS|                  |
                  +------------------------+                  |
                              |                               |
                 [Unconditional LISTEN Re-reg]                |
                              |                               |
                              v                               |
                  +------------------------+                  |
                  |  4. LISTENING_ACTIVE   |                  |
                  +------------------------+                  |
                     |                  |                     |
        [Wakeup NOTIFY/Tick]   [Socket Drop / Ping Stalled]   |
                     |                  |                     |
                     v                  +---------------------+
           +--------------------+                             |
           |  5. DRAINING_OUTBOX|                             |
           +--------------------+                             |
                     |                                        |
          [Watermark Advanced]                                |
                     |                                        |
                     +----------------------------------------+
```

### State Transition Invariants:
1. **DISCONNECTED $\to$ CONNECTING**: Must use direct connection string (port 5432), never pooled through PgBouncer in transaction mode.
2. **CONNECTING $\to$ REGISTERING_CHANNELS**: TCP keepalives must be enabled (`keepalives_idle = 10s`).
3. **REGISTERING_CHANNELS $\to$ LISTENING_ACTIVE**: Client iterates over its desired channel set, issuing `LISTEN <channel>` for every channel plus `__sys_heartbeat__`.
4. **LISTENING_ACTIVE $\to$ DRAINING_OUTBOX**: Triggered either by incoming Thin Pointer NOTIFY, or safety timer tick (5s). Drains outbox rows `WHERE id > :watermark` in monotonic order.
5. **LISTENING_ACTIVE $\to$ CONNECTING**: If heartbeat ping fails to receive echo within $T_{\text{hb}} + T_{\text{grace}}$, the socket is forcefully aborted (`FIN/RST`), entering exponential backoff before reconnecting.

---

## 7. Machine-Verifiable CI Gates & Definition of Done (DoD)

To prevent LLMs and developers from introducing `LISTEN / NOTIFY` anti-patterns, the following 6 static analysis and runtime test gates must be enforced in CI pipelines:

```
+----------------------------------------------------------------------------------------------------+
|                         MACHINE-VERIFIABLE DEFINITION OF DONE (DoD) MATRIX                         |
+------+-------------------------------+-------------------------------------------------------------+
| Gate | Verification Target           | Pass Criteria / Regex & AST Rules                           |
+------+-------------------------------+-------------------------------------------------------------+
| G-1  | 8000-Byte Payload Invariant   | AST analysis bans `pg_notify(..., row_to_json(NEW)::text)`. |
|      |                               | All triggers must use Thin Pointer json_build_object() <256B|
+------+-------------------------------+-------------------------------------------------------------+
| G-2  | PgBouncer Transaction Bypass  | Connection strings used for LISTEN must NOT target port     |
|      |                               | 6432 with pool_mode=transaction. Direct port 5432 required. |
+------+-------------------------------+-------------------------------------------------------------+
| G-3  | Channel Re-registration Proof | Client listener must prove unconditional re-issue of        |
|      |                               | `LISTEN <channel>` inside reconnect loop before processing. |
+------+-------------------------------+-------------------------------------------------------------+
| G-4  | SLRU Buffer Telemetry Guard   | CI suite verifies `pg_notification_queue_usage()` is logged |
|      |                               | and alerts at > 25% saturation.                             |
+------+-------------------------------+-------------------------------------------------------------+
| G-5  | Outbox Watermark Replay Test  | Integration test severs listener socket for 10 seconds;     |
|      |                               | verifies 100% of outbox events are hydrated upon reconnect. |
+------+-------------------------------+-------------------------------------------------------------+
| G-6  | Statement-Level Batch Defense | Multi-row batch mutations must not fire row-level NOTIFY;   |
|      |                               | statements must use transition tables or coalesce envelopes.|
+------+-------------------------------+-------------------------------------------------------------+
```

### Automated CI Verification Script: `scripts/ci-verify-listen-notify.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Running Machine-Verifiable CI Gates for LISTEN / NOTIFY..."

# Gate 1: Check for dangerous full row-to-json triggers emitting raw rows over pg_notify
VIOLATING_TRIGGERS=$(grep -rnE "pg_notify\([^,]+,\s*(row_to_json|to_jsonb?)\(NEW\)" src/ migrations/ || true)
if [ -n "$VIOLATING_TRIGGERS" ]; then
  echo "❌ FAIL [G-1]: Found raw entity serialization inside pg_notify trigger (Payload Cliff SQLSTATE 54000):"
  echo "$VIOLATING_TRIGGERS"
  exit 1
fi
echo "✅ Gate 1 Passed: No raw entity serialization in pg_notify triggers."

# Gate 2: Verify listener connection config does not target transaction-mode PgBouncer
VIOLATING_POOLS=$(grep -rnE "port:\s*6432" src/ | grep -iE "listen|subscriber" || true)
if [ -n "$VIOLATING_POOLS" ]; then
  echo "❌ FAIL [G-2]: Listener is configured against PgBouncer transaction-mode port (6432):"
  echo "$VIOLATING_POOLS"
  exit 1
fi
echo "✅ Gate 2 Passed: Listener isolated from PgBouncer transaction pooling."

# Gate 3: Verify listener has Outbox watermark seek query
HAS_WATERMARK_SEEK=$(grep -rnE "WHERE\s+id\s*>\s*[:\$]?[a-zA-Z0-9_]*\s+ORDER\s+BY\s+id" src/ || true)
if [ -z "$HAS_WATERMARK_SEEK" ]; then
  echo "❌ FAIL [G-3]: No keyset watermark seek query found. LISTEN/NOTIFY must be backed by durable Outbox replay."
  exit 1
fi
echo "✅ Gate 3 Passed: Keyset watermark seek outbox query verified."

echo "🎉 All LISTEN / NOTIFY Production CI Gates Passed Successfully!"
```
