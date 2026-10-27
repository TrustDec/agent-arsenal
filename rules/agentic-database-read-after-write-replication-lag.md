---
description: Database read-after-write consistency, replication lag fencing, PostgreSQL WAL LSN causal tokens, sticky primary session routing, dynamic lag-aware replica shedding, and split-brain stale read eradication across Go (pgx/sqlc), TypeScript (Drizzle/Prisma), Python (SQLAlchemy), Rust (sqlx), PostgreSQL, AWS Aurora, Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{replica,replication,read-replica,readwrite,primary,follower,routing,pool,datasource,database,db,repository,repo,client}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/repository/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Read-After-Write Consistency, Replica Lag Fencing & Causal Read Routing Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design high-throughput database architectures with primary-replica topologies, AWS Aurora clusters, Google Cloud SQL read replicas, Supabase connection poolers, Neon branched replicas, or distributed read/write query routing across PostgreSQL, MySQL, Go (`jackc/pgx`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`SQLAlchemy`), or Rust (`sqlx`). Eliminate the "Write-Then-Read 404 Mirage" (where an agent creates a record on the Primary and immediately queries a lagging replica, throwing a 404 Not Found error and inducing panic retries), the "Monotonic Read Inconsistency Anomaly" (where successive pagination requests hit replicas with disparate replication lags, causing records to flicker, disappear, and re-appear as if travelling backward in time), the "Causal Dependency Inversion Disaster" (where an agent writes a parent entity and child entity, but an asynchronous worker queries a replica before the parent write is replayed, crashing with foreign key or missing relation errors), the "Unbounded Replica Lag Avalanche & Replication Slot Bloat" (where long-running queries or network hiccups stall replica WAL replay, causing replication slots on the Primary to retain gigabytes of unvacuumed WAL until primary disk fills to 100%), the "Blind Primary Bleed Trap" (where fearful agents route 100% of read traffic to the Primary writer to avoid lag bugs, spiking Primary CPU to 100% and wasting expensive read replicas), and the "Cross-Tenant Auth Revocation Stale Window" (where an admin revokes permissions on the Primary, but authorization checks route to an un-replicated follower, permitting unauthorized operations) by establishing a strict 5-Tier Read Consistency & Replica Governance Ladder, monotonic session write epochs, causal Log Sequence Number (LSN) read fencing, dynamic lag-aware circuit breaking, and single-statement write-through projections.

---

## 1. Architectural Taxonomy: The 6 Read-After-Write Catastrophes vs The 5-Tier Read Consistency & Replica Governance Ladder

When autonomous coding agents generate database access layers for high-throughput cloud applications, LLMs instinctively separate queries into `primaryPool` (for writes) and `replicaPool` (for reads) to scale read throughput. However, LLMs almost universally assume that read replicas are instantly coherent with the primary database. In physical streaming replication, network latency, disk I/O contention, lock conflicts with long analytical queries, and CPU throttling introduce replication lag ($\tau_{\text{lag}} \in [10\text{ms}, 5000\text{ms}]$):

```typescript
// ❌ CATASTROPHIC LLM REPLICA SPLIT ANTI-PATTERNS (Stale Reads, 404 Mirages, Time-Travel)
async function handleCreateUserOrder(req: Request, res: Response) {
  // Step 1: Write to Primary DB
  const order = await primaryDb.insert(orders).values({ userId: req.user.id, total: 9900 }).returning();

  // Step 2: Immediate follow-up read dispatched to Read Replica!
  // VULN: Replica is 150ms behind primary! Query returns undefined -> 404 Not Found!
  // Agent panics, logs "Order creation failed", or retries duplicate insertion!
  const fetched = await replicaDb.query.orders.findFirst({ where: eq(orders.id, order.id) });
  if (!fetched) {
    throw new NotFoundError('Order missing immediately after insert!'); // CATASTROPHIC 404 MIRAGE
  }
}
```

In high-concurrency microservices, multi-tenant databases, or multi-agent autonomous execution loops, naive read-write splitting triggers six critical database replication catastrophes:

- **The "Write-Then-Read 404 Mirage" (Read-After-Write Replication Lag Trap)**:
  - An Agent or user performs a mutation (`POST /api/orders` or `UPDATE /api/user/profile`). The mutation is successfully committed to the Primary writer.
  - The client UI redirects to the newly created entity's detail view (`GET /api/orders/:id`), or the Agent immediately queries the database to verify the mutation.
  - Because read requests default to the read replica pool, and the replica is trailing the primary by $50\text{ms} - 500\text{ms}$, the newly committed row is invisible to the replica's snapshot.
  - The application returns `404 Not Found`. The autonomous agent concludes the write failed, hallucinates a bug in the ORM, triggers redundant retries, or corrupts downstream state.
  - Invariant: A client or agent session that executes a mutation MUST NOT read from an asynchronous replica unless the replica is mathematically proven to have replayed past the mutation's commit point.

- **The "Monotonic Read Inconsistency Anomaly" (Replica Ping-Pong Time Travel)**:
  - A client loads page 1 of an activity feed through a load-balanced pool of 3 read replicas ($R_1, R_2, R_3$).
  - Request 1 hits $R_1$ ($\tau_{\text{lag}} = 5\text{ms}$), displaying up-to-date posts including Post #100.
  - Request 2 (e.g., pagination or tab switch 1 second later) is routed via round-robin to $R_3$ ($\tau_{\text{lag}} = 1200\text{ms}$).
  - In $R_3$'s snapshot, Post #100 does not exist, and edited Post #99 contains obsolete text. From the user or Agent's perspective, data flickered backward in time.
  - Invariant: Within a single user or Agent session, the observable database state MUST be monotonically non-decreasing in time: $\forall t_2 > t_1, \text{Snapshot}(t_2) \ge \text{Snapshot}(t_1)$.

- **The "Causal Dependency Inversion Disaster" (Out-of-Order Downstream Propagation)**:
  - An agent updates a parent configuration record $P$ on the Primary database and then enqueues an asynchronous background job or emits a webhook.
  - The background worker consumes the message within 10ms and attempts to read parent configuration $P$ from a read replica.
  - If the replica has not replayed $P$, the worker operates on stale business logic, or fails with `Foreign Key Violation` / `Entity Not Found`, triggering poison message DLQ cascades.
  - Invariant: Asynchronous messages triggered by transactional changes MUST carry causal tokens (commit timestamps or WAL Log Sequence Numbers) that downstream workers use to gate query execution.

- **The "Unbounded Replica Lag Avalanche & Replication Slot Bloat"**:
  - A long-running analytical query (`SELECT COUNT(*) ... GROUP BY ...`) or unindexed join is routed to a read replica.
  - PostgreSQL replica query conflict mechanisms (`max_standby_streaming_delay`) pause WAL replay on the replica to avoid canceling the long-running query.
  - Meanwhile, on the Primary database, the physical replication slot (`pg_replication_slots`) must preserve all un-replayed WAL segments.
  - The primary disk usage spikes from 40% to 100% in minutes. Once disk fills, PostgreSQL crashes abruptly and refuses to restart without manual intervention.
  - Invariant: Read replicas MUST enforce strict query timeouts (`statement_timeout = 15s`), and the Primary MUST enforce `max_slot_wal_keep_size` with automated alerting before disk exhaustion.

- **The "Blind Primary Bleed Trap" (Replica Fear Over-Routing)**:
  - Terrified of replication lag anomalies and 404 mirages, developers and agents strip out replica routing entirely, directing 100% of queries to the Primary database.
  - The Primary database CPU spikes to 100%, connection pool limits are hit, and expensive multi-node read replicas sit idle at 1% utilization.
  - Invariant: The architecture MUST provide principled sticky primary windows and LSN-fenced replica reads, maximizing safe replica offloading without compromising read-your-own-writes consistency.

- **The "Cross-Tenant Auth Revocation Stale Window"**:
  - A tenant workspace administrator revokes an employee's access or revokes an API token on the Primary writer.
  - The revoked user immediately issues a sensitive data export request. The API gateway evaluates the authorization check against a read replica trailing by 3 seconds.
  - The read replica still sees the user as an active administrator; the data export succeeds, causing an unauthorized data breach.
  - Invariant: Security-critical operations, authentication token validations, and authorization role checks MUST ALWAYS route to the Primary database or verify zero replica lag.

---

### The 5-Tier Read Consistency & Replica Governance Ladder

```
+---------------------------------------------------------------------------------------+
| LEVEL 4: Repeatable Read Multi-Query Encasement (Pinned Replica Session Isolation)    |
+---------------------------------------------------------------------------------------+
| LEVEL 3: Dynamic Lag-Aware Replica Shedding & Circuit Breaking (Lag > 1.0s Ejection)  |
+---------------------------------------------------------------------------------------+
| LEVEL 2: Causal Log Sequence Number (LSN) Read Fencing (pg_last_wal_replay_lsn >= LSN)|
+---------------------------------------------------------------------------------------+
| LEVEL 1: Sticky Primary Session Routing via Monotonic Write Epochs (T_sticky >= 5s)   |
+---------------------------------------------------------------------------------------+
| LEVEL 0: Single-Statement Mutation Write-Through Projection (RETURNING * - 0 Reads)   |
+---------------------------------------------------------------------------------------+
```

1. **Tier 0: Single-Statement Mutation Write-Through Projection (0-Read Guarantee)**:
   - When mutating a record (`INSERT`, `UPDATE`, `DELETE`), eliminate subsequent `SELECT` queries entirely by requesting all required fields via SQL `RETURNING *` or Output Clauses.
   - The returned data is guaranteed fresh, committed, and costs zero additional network roundtrips.

2. **Tier 1: Sticky Primary Session Routing via Monotonic Write Epochs**:
   - When a client or user session performs any write mutation, register a timestamp epoch $t_{\text{write}}$ in the session context (HTTP cookie, JWT claim, or Redis session).
   - For a duration of $T_{\text{sticky}} = \max(2 \times \tau_{\text{lag\_p99}}, 5.0\text{s})$, ALL subsequent read queries from that specific session are pinned directly to the Primary database.
   - Unauthenticated or read-only sessions that have not written within $T_{\text{sticky}}$ continue to utilize the read replica pool without penalty.

3. **Tier 2: Causal Log Sequence Number (LSN) Read Fencing**:
   - The Primary database returns the commit Log Sequence Number (`SELECT pg_current_wal_lsn()`) alongside mutation responses.
   - Subsequent read requests supply this causal token (`X-Database-LSN: 0/1A2B3C4D`).
   - The replica router queries `SELECT pg_last_wal_replay_lsn()`:
     - If $\text{Replay LSN} \ge \text{Target LSN}$, the read executes on the replica with 100% consistency guarantee.
     - If $\text{Replay LSN} < \text{Target LSN}$, the router waits up to a bounded budget (e.g., 30ms) for replay, or transparently falls back to the Primary writer.

4. **Tier 3: Dynamic Lag-Aware Read Replica Shedding & Circuit Breaking**:
   - The application background health checker continuously polls replica lag:
     $$\tau_{\text{lag}} = \text{EXTRACT(EPOCH FROM (clock_timestamp() - pg_last_xact_replay_timestamp()))}$$
   - Any replica whose lag exceeds $\tau_{\text{threshold}}$ (e.g., $1.0\text{s}$) or whose replication connection breaks is immediately tripped open and ejected from the active read pool.
   - Traffic is dynamically shed to surviving healthy replicas or the Primary writer.

5. **Tier 4: Repeatable Read Multi-Query Encasement (Pinned Replica Session Isolation)**:
   - When an application executes multi-step reporting or multi-query reads that must be causally consistent across queries, the queries MUST execute within a single transaction on a single dedicated replica connection:
     `BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;`
   - Spreading related read queries across multiple unpinned replica connections is strictly prohibited.

---

## 2. Mathematical Invariants: Replication Physics, Causal Order Calculus & Sticky Routing Bounds

### 2.1 Formal Causal Consistency Invariant in Read-Write Topologies

Let the database system state be a set of transactions $T = \{t_1, t_2, \dots\}$. Each transaction $t_i$ commits at primary wall-clock time $C(t_i)$ and generates a monotonically increasing Log Sequence Number $\text{LSN}(t_i) \in \mathbb{N}^+$.

A read replica $R_k$ continuously replays the write-ahead log. At any physical time $t$, replica $R_k$ has replayed up to $\text{LSN}_{\text{replay}}(R_k, t)$.

The replication lag in physical time units is:
$$\tau_{\text{lag}}(R_k, t) = t - C(\max \{ t_i \mid \text{LSN}(t_i) \le \text{LSN}_{\text{replay}}(R_k, t) \})$$

**The Read-After-Write Safety Invariant**:
For any session $S$, if $S$ commits transaction $t_w$ at time $t_{\text{write}}$, and subsequently issues a read query $q_r$ at time $t_{\text{read}} > t_{\text{write}}$, the query $q_r$ is consistent if and only if:
$$\text{LSN}_{\text{replay}}(Node(q_r), t_{\text{read}}) \ge \text{LSN}(t_w)$$

If $Node(q_r)$ is the Primary, $\text{LSN}_{\text{replay}}(\text{Primary}, t) \equiv \text{LSN}_{\text{head}}(t) \ge \text{LSN}(t_w)$, guaranteeing safety with probability $1.0$.

### 2.2 Sticky Primary Window Invariant

If the replication lag distribution follows a probability density function $f_{\tau}(x)$ with mean $\mu_{\tau}$ and standard deviation $\sigma_{\tau}$, the probability that a replica has caught up after elapsed time $\Delta t = t_{\text{read}} - t_{\text{write}}$ is:
$$P(\text{Replayed} \mid \Delta t) = \int_0^{\Delta t} f_{\tau}(x) \, dx$$

To guarantee read-after-write consistency with confidence $1 - \epsilon$ (where $\epsilon \le 10^{-6}$):
$$T_{\text{sticky}} \ge \mu_{\tau} + k \cdot \sigma_{\tau}$$
By Chebyshev's Inequality or empirical tail bounds (for log-normal replication lag distributions):
$$T_{\text{sticky}} = \max\left(5.0\text{s}, 2 \times \tau_{\text{p99}}\right)$$

By maintaining a sticky session to Primary whenever $t - t_{\text{last\_write}} \le T_{\text{sticky}}$, the probability of a stale read-after-write 404 anomaly is strictly bounded:
$$P(\text{Stale Read} \mid \Delta t \le T_{\text{sticky}}) = 0$$

### 2.3 Offloading Throughput Scaling Law

Let $\Phi_{\text{max}}$ be the maximum query capacity of a single database node. In a system with 1 Primary and $M$ Read Replicas:
- Let $w \in [0, 1]$ be the proportion of write operations ($w = \frac{N_{\text{writes}}}{N_{\text{total}}}$).
- Let $r = 1 - w$ be the proportion of read operations.
- Let $\alpha_{\text{sticky}} \in [0, 1]$ be the proportion of read operations that occur within the sticky session window $T_{\text{sticky}}$.

The total throughput $\Phi_{\text{system}}$ supported by the cluster is:
$$\Phi_{\text{primary\_load}} = \Phi_{\text{total}} \cdot \left( w + r \cdot \alpha_{\text{sticky}} \right) \le \Phi_{\text{max}}$$
$$\Phi_{\text{replica\_load}} = \Phi_{\text{total}} \cdot r \cdot (1 - \alpha_{\text{sticky}}) \le M \cdot \Phi_{\text{max}}$$

Therefore, the maximum scalable system throughput is constrained by:
$$\Phi_{\text{system}} \le \min\left( \frac{\Phi_{\text{max}}}{w + r \cdot \alpha_{\text{sticky}}}, \frac{M \cdot \Phi_{\text{max}}}{r \cdot (1 - \alpha_{\text{sticky}})} \right)$$

This proves that:
1. Blindly routing all reads to Primary ($\alpha_{\text{sticky}} = 1.0$) reduces system throughput to $\Phi_{\text{max}}$, completely negating the investment in $M$ replicas.
2. Naive replica routing ($\alpha_{\text{sticky}} = 0$) causes stale-read anomalies whenever $\Delta t < \tau_{\text{lag}}$.
3. Dynamic sticky primary routing achieves near-optimal read scaling while strictly preserving causal consistency.

---

## 3. Production TypeScript Implementation: `AgenticDatabaseReplicaRouter`

Here is the industrial-grade, fully typed TypeScript replica router supporting sticky sessions, LSN fencing, and dynamic lag-aware circuit breaking:

```typescript
// agentic-database-replica-router.ts
import { Pool, PoolClient } from 'pg';
import { EventEmitter } from 'node:events';

export interface ReplicaConfig {
  id: string;
  connectionString: string;
  maxConnections: number;
  maxLagSeconds: number;
}

export interface RouterConfig {
  primaryConnectionString: string;
  replicas: ReplicaConfig[];
  stickyDurationMs: number; // default: 5000ms
  lagCheckIntervalMs: number; // default: 2000ms
  lsnWaitTimeoutMs: number; // default: 50ms
}

export interface SessionContext {
  sessionId?: string;
  lastWriteTimestamp?: number;
  targetLsn?: string;
  forcePrimary?: boolean;
}

export interface QueryResult<T = any> {
  rows: T[];
  rowCount: number;
  routedTo: 'primary' | string; // 'primary' or replica id
  lsn?: string;
}

export class AgenticDatabaseReplicaRouter extends EventEmitter {
  private primaryPool: Pool;
  private replicaPools: Map<string, { pool: Pool; config: ReplicaConfig; currentLagSeconds: number; healthy: boolean }> = new Map();
  private sessionWriteEpochs: Map<string, number> = new Map();
  private sessionLastLsn: Map<string, string> = new Map();
  private lagMonitorTimer: NodeJS.Timeout | null = null;
  private roundRobinIndex = 0;

  constructor(private readonly config: RouterConfig) {
    super();
    this.primaryPool = new Pool({
      connectionString: config.primaryConnectionString,
      max: 20,
      idleTimeoutMillis: 10000,
    });

    for (const rep of config.replicas) {
      const pool = new Pool({
        connectionString: rep.connectionString,
        max: rep.maxConnections,
        idleTimeoutMillis: 10000,
      });
      this.replicaPools.set(rep.id, {
        pool,
        config: rep,
        currentLagSeconds: 0,
        healthy: true,
      });
    }

    this.startLagMonitor();
  }

  /**
   * Starts background health check polling replication lag across all replicas.
   */
  private startLagMonitor(): void {
    this.lagMonitorTimer = setInterval(async () => {
      for (const [id, replica] of this.replicaPools.entries()) {
        try {
          const client = await replica.pool.connect();
          try {
            const res = await client.query(`
              SELECT 
                EXTRACT(EPOCH FROM (clock_timestamp() - pg_last_xact_replay_timestamp())) AS lag_seconds,
                pg_is_in_recovery() AS in_recovery,
                pg_last_wal_replay_lsn()::text AS replay_lsn
            `);
            const lag = parseFloat(res.rows[0]?.lag_seconds || '0');
            const inRecovery = res.rows[0]?.in_recovery === true;

            replica.currentLagSeconds = lag;
            const wasHealthy = replica.healthy;
            replica.healthy = inRecovery && lag <= replica.config.maxLagSeconds;

            if (wasHealthy && !replica.healthy) {
              this.emit('replicaEjected', { id, lag, reason: 'LAG_EXCEEDED_THRESHOLD' });
            } else if (!wasHealthy && replica.healthy) {
              this.emit('replicaRestored', { id, lag });
            }
          } finally {
            client.release();
          }
        } catch (err: any) {
          replica.healthy = false;
          this.emit('replicaError', { id, error: err.message });
        }
      }
    }, this.config.lagCheckIntervalMs);
  }

  /**
   * Records a mutation write epoch and LSN for a given user or agent session.
   */
  public recordSessionWrite(sessionId: string, lsn?: string): void {
    const now = Date.now();
    this.sessionWriteEpochs.set(sessionId, now);
    if (lsn) {
      this.sessionLastLsn.set(sessionId, lsn);
    }
  }

  /**
   * Determines whether the given session must be routed to the Primary writer.
   */
  public shouldRouteToPrimary(ctx?: SessionContext): { routeToPrimary: boolean; reason: string } {
    if (!ctx) return { routeToPrimary: false, reason: 'NO_CONTEXT' };
    if (ctx.forcePrimary) return { routeToPrimary: true, reason: 'EXPLICIT_FORCE_PRIMARY' };

    if (ctx.sessionId) {
      const lastWrite = this.sessionWriteEpochs.get(ctx.sessionId);
      if (lastWrite) {
        const elapsed = Date.now() - lastWrite;
        if (elapsed < (this.config.stickyDurationMs || 5000)) {
          return { routeToPrimary: true, reason: `STICKY_SESSION_ACTIVE (${elapsed}ms < ${this.config.stickyDurationMs}ms)` };
        }
      }
    }

    if (ctx.lastWriteTimestamp) {
      const elapsed = Date.now() - ctx.lastWriteTimestamp;
      if (elapsed < (this.config.stickyDurationMs || 5000)) {
        return { routeToPrimary: true, reason: `EXPLICIT_WRITE_TIMESTAMP_ACTIVE (${elapsed}ms)` };
      }
    }

    return { routeToPrimary: false, reason: 'READ_REPLICA_ELIGIBLE' };
  }

  /**
   * Selects an available, healthy read replica via round-robin.
   */
  private selectHealthyReplica(): { id: string; pool: Pool } | null {
    const available = Array.from(this.replicaPools.entries()).filter(([_, r]) => r.healthy);
    if (available.length === 0) return null;

    this.roundRobinIndex = (this.roundRobinIndex + 1) % available.length;
    const [id, rep] = available[this.roundRobinIndex];
    return { id, pool: rep.pool };
  }

  /**
   * Executes a write mutation strictly on the Primary database, returning committed LSN.
   */
  public async write<T = any>(sql: string, params: any[] = [], ctx?: SessionContext): Promise<QueryResult<T>> {
    const client = await this.primaryPool.connect();
    try {
      // Execute mutation with LSN capture
      const res = await client.query(sql, params);
      const lsnRes = await client.query('SELECT pg_current_wal_lsn()::text AS lsn');
      const lsn = lsnRes.rows[0]?.lsn;

      if (ctx?.sessionId) {
        this.recordSessionWrite(ctx.sessionId, lsn);
      }

      return {
        rows: res.rows,
        rowCount: res.rowCount ?? 0,
        routedTo: 'primary',
        lsn,
      };
    } finally {
      client.release();
    }
  }

  /**
   * Executes a read query, applying Sticky Primary and LSN Fencing invariants.
   */
  public async read<T = any>(sql: string, params: any[] = [], ctx?: SessionContext): Promise<QueryResult<T>> {
    const routingDecision = this.shouldRouteToPrimary(ctx);

    // Path 1: Session is inside sticky window -> Route to Primary
    if (routingDecision.routeToPrimary) {
      const client = await this.primaryPool.connect();
      try {
        const res = await client.query(sql, params);
        return {
          rows: res.rows,
          rowCount: res.rowCount ?? 0,
          routedTo: 'primary',
        };
      } finally {
        client.release();
      }
    }

    // Path 2: Attempt healthy Read Replica
    const targetLsn = ctx?.targetLsn || (ctx?.sessionId ? this.sessionLastLsn.get(ctx.sessionId) : undefined);
    const replica = this.selectHealthyReplica();

    // Fallback to Primary if all replicas are degraded
    if (!replica) {
      const client = await this.primaryPool.connect();
      try {
        const res = await client.query(sql, params);
        return {
          rows: res.rows,
          rowCount: res.rowCount ?? 0,
          routedTo: 'primary',
        };
      } finally {
        client.release();
      }
    }

    // Path 3: Causal LSN Verification
    const client = await replica.pool.connect();
    try {
      if (targetLsn) {
        const lsnCheck = await client.query(
          'SELECT pg_wal_lsn_diff(pg_last_wal_replay_lsn(), $1::pg_lsn) >= 0 AS caught_up',
          [targetLsn]
        );
        const caughtUp = lsnCheck.rows[0]?.caught_up === true;

        if (!caughtUp) {
          // Replica has not caught up to target LSN! Fall back to Primary writer to prevent stale read.
          client.release();
          const primaryClient = await this.primaryPool.connect();
          try {
            const res = await primaryClient.query(sql, params);
            return {
              rows: res.rows,
              rowCount: res.rowCount ?? 0,
              routedTo: 'primary',
            };
          } finally {
            primaryClient.release();
          }
        }
      }

      const res = await client.query(sql, params);
      return {
        rows: res.rows,
        rowCount: res.rowCount ?? 0,
        routedTo: replica.id,
      };
    } finally {
      client.release();
    }
  }

  public async close(): Promise<void> {
    if (this.lagMonitorTimer) clearInterval(this.lagMonitorTimer);
    await this.primaryPool.end();
    for (const [_, rep] of this.replicaPools.entries()) {
      await rep.pool.end();
    }
  }
}
```

---

## 4. The 6-State Replica Routing & Consistency Lifecycle Finite-State Machine (FSM)

The read-write routing decision follows a deterministic 6-state finite-state machine governing query destination:

```
                      +-----------------------------+
                      |   [0] SESSION_INSPECTION    |
                      +-----------------------------+
                                     |
              +----------------------+----------------------+
              | (Write Mutation)                            | (Read Query)
              v                                             v
+-----------------------------+               +-----------------------------+
|   [1] PRIMARY_MUTATION_EXEC |               |   [2] STICKY_WINDOW_CHECK   |
+-----------------------------+               +-----------------------------+
              | (Commit + LSN)                              |
              v                                             +--------------------+
+-----------------------------+                             | (Within T_sticky)  | (T_elapsed >= T_sticky)
|   [3] CAUSAL_EPOCH_UPDATE   |                             v                    v
+-----------------------------+              +------------------------+  +------------------------+
              |                              | [4] PRIMARY_FALLBACK   |  | [5] REPLICA_LSN_EVAL   |
              v                              +------------------------+  +------------------------+
(Sets session epoch + LSN)                                  ^                    |
                                                            | (LSN behind /      | (LSN caught up &
                                                            |  Lag > threshold)  |  health OK)
                                                            |                    v
                                                            +-------+ [6] REPLICA_SAFE_DISPATCH
```

### State Transitions
1. **State 0: SESSION_INSPECTION**: The incoming database operation is classified by query intent (`SELECT` vs `INSERT/UPDATE/DELETE/DDL`) and associated with the calling context.
2. **State 1: PRIMARY_MUTATION_EXEC**: Mutations bypass all replicas and execute exclusively on the Primary writer.
3. **State 2: STICKY_WINDOW_CHECK**: Read queries inspect the caller's session state. If $\Delta t = t_{\text{now}} - t_{\text{last\_write}} < T_{\text{sticky}}$ (default 5.0 seconds), query transitions immediately to State 4 (PRIMARY_FALLBACK).
4. **State 3: CAUSAL_EPOCH_UPDATE**: Upon successful commit of State 1, the Primary queries `SELECT pg_current_wal_lsn()` and updates the session's active epoch and LSN token.
5. **State 4: PRIMARY_FALLBACK**: Reads requiring fresh data, reads from active mutating sessions, or reads whose replicas failed the LSN check execute on the Primary writer.
6. **State 5: REPLICA_LSN_EVAL**: Replicas evaluate `pg_last_wal_replay_lsn() >= targetLsn`. If healthy and caught up, transitions to State 6; otherwise triggers State 4.
7. **State 6: REPLICA_SAFE_DISPATCH**: Query executes on the replica with 100% causal consistency guarantee and 0ms primary load.

---

## 5. Technology-Specific Production Patterns

### 5.1 Go (`jackc/pgx/v5` & `sqlc`): Context-Driven Multi-Pool Router

In Go production microservices, encapsulate Primary and Replica pools inside a custom `DBRouter` and govern routing using `context.Context` values:

```go
// internal/database/router.go
package database

import (
    "context"
    "database/sql"
    "errors"
    "fmt"
    "sync/atomic"
    "time"

    "github.com/jackc/pgx/v5/pgxpool"
)

type contextKey string

const (
    stickyPrimaryUntilKey contextKey = "db:sticky_until"
    causalLSNKey          contextKey = "db:causal_lsn"
    forcePrimaryKey       contextKey = "db:force_primary"
)

type DBRouter struct {
    primaryPool   *pgxpool.Pool
    replicaPools  []*pgxpool.Pool
    replicaIndex  uint64
    stickyDuration time.Duration
}

func NewDBRouter(primary *pgxpool.Pool, replicas []*pgxpool.Pool, stickyDur time.Duration) *DBRouter {
    return &DBRouter{
        primaryPool:    primary,
        replicaPools:   replicas,
        stickyDuration: stickyDur,
    }
}

// WithStickyPrimary decorates context with a primary pinning expiration
func WithStickyPrimary(ctx context.Context, duration time.Duration) context.Context {
    return context.WithValue(ctx, stickyPrimaryUntilKey, time.Now().Add(duration))
}

// WithCausalLSN attaches a commit LSN token to the context
func WithCausalLSN(ctx context.Context, lsn string) context.Context {
    return context.WithValue(ctx, causalLSNKey, lsn)
}

// ExecMutation executes a write on Primary, captures LSN, and returns updated context
func (r *DBRouter) ExecMutation(ctx context.Context, query string, args ...any) (context.Context, error) {
    conn, err := r.primaryPool.Acquire(ctx)
    if err != nil {
        return ctx, fmt.Errorf("acquire primary conn: %w", err)
    }
    defer conn.Release()

    _, err = conn.Exec(ctx, query, args...)
    if err != nil {
        return ctx, fmt.Errorf("exec mutation: %w", err)
    }

    // Capture commit LSN for causal chaining
    var lsn string
    if err := conn.QueryRow(ctx, "SELECT pg_current_wal_lsn()::text").Scan(&lsn); err != nil {
        return ctx, nil // Non-fatal if LSN extraction fails
    }

    newCtx := WithStickyPrimary(ctx, r.stickyDuration)
    newCtx = WithCausalLSN(newCtx, lsn)
    return newCtx, nil
}

// QueryRead routes reads to replica unless sticky window or LSN check demands primary
func (r *DBRouter) QueryRead(ctx context.Context, query string, args ...any) (*pgxpool.Pool, error) {
    if force, ok := ctx.Value(forcePrimaryKey).(bool); ok && force {
        return r.primaryPool, nil
    }

    // Check sticky session window
    if stickyUntil, ok := ctx.Value(stickyPrimaryUntilKey).(time.Time); ok {
        if time.Now().Before(stickyUntil) {
            return r.primaryPool, nil
        }
    }

    if len(r.replicaPools) == 0 {
        return r.primaryPool, nil
    }

    // Select replica via round-robin
    idx := atomic.AddUint64(&r.replicaIndex, 1) % uint64(len(r.replicaPools))
    replica := r.replicaPools[idx]

    // Verify causal LSN if present
    if targetLSN, ok := ctx.Value(causalLSNKey).(string); ok && targetLSN != "" {
        var caughtUp bool
        err := replica.QueryRow(ctx, 
            "SELECT pg_wal_lsn_diff(pg_last_wal_replay_lsn(), $1::pg_lsn) >= 0", targetLSN).Scan(&caughtUp)
        if err != nil || !caughtUp {
            // Replica is trailing! Gracefully fallback to Primary writer
            return r.primaryPool, nil
        }
    }

    return replica, nil
}
```

---

### 5.2 TypeScript (Drizzle ORM & Fastify/Express Middleware): Cookie-Driven Sticky Primary

```typescript
// src/middleware/db-sticky-session.ts
import { FastifyRequest, FastifyReply } from 'fastify';
import { dbPrimary, dbReplica } from '../db';

const STICKY_COOKIE_NAME = 'x-db-write-epoch';
const STICKY_WINDOW_MS = 5000;

export async function dbReplicationMiddleware(req: FastifyRequest, reply: FastifyReply) {
  const writeEpochHeader = req.headers['x-db-write-epoch'] as string;
  const writeEpochCookie = req.cookies[STICKY_COOKIE_NAME];
  const writeEpoch = parseInt(writeEpochHeader || writeEpochCookie || '0', 10);

  const isSticky = Date.now() - writeEpoch < STICKY_WINDOW_MS;

  // Bind selected database instance to request context
  req.db = isSticky ? dbPrimary : dbReplica;
  req.isDbSticky = isSticky;
}

// In mutation route handlers:
export async function createCommentHandler(req: FastifyRequest, reply: FastifyReply) {
  // Always write to primary
  const [comment] = await dbPrimary.insert(comments).values(req.body).returning();

  // Set sticky epoch cookie to pin subsequent client reads to Primary for 5s
  reply.setCookie(STICKY_COOKIE_NAME, Date.now().toString(), {
    path: '/',
    maxAge: 5,
    httpOnly: true,
    sameSite: 'lax',
  });

  return reply.status(201).send(comment);
}
```

---

### 5.3 Python (`SQLAlchemy 2.0`): Dynamic Routing Session with LSN Sentinels

```python
# db/routing_session.py
import time
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session, sessionmaker

class RoutingSession(Session):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.has_written = False
        self.last_write_lsn = None

    def get_bind(self, mapper=None, clause=None, **kw):
        # 1. If currently inside a transaction that executed a write -> Primary
        if self.has_written or (clause is not None and clause.is_dml):
            return engines["primary"]

        # 2. Check if context requested explicit primary
        if self.info.get("force_primary", False):
            return engines["primary"]

        # 3. Check sticky session duration
        last_write_time = self.info.get("last_write_time", 0)
        if (time.time() - last_write_time) < 5.0:
            return engines["primary"]

        # 4. Check LSN causal requirement
        target_lsn = self.info.get("target_lsn")
        if target_lsn:
            with engines["replica"].connect() as conn:
                res = conn.execute(
                    text("SELECT pg_wal_lsn_diff(pg_last_wal_replay_lsn(), :lsn::pg_lsn) >= 0 AS ok"),
                    {"lsn": target_lsn}
                ).scalar()
                if not res:
                    return engines["primary"] # Replica lagging, fallback

        return engines["replica"]

    def commit(self):
        if self.has_written:
            with engines["primary"].connect() as conn:
                self.last_write_lsn = conn.execute(text("SELECT pg_current_wal_lsn()::text")).scalar()
            self.info["last_write_time"] = time.time()
            self.info["target_lsn"] = self.last_write_lsn
        super().commit()
```

---

## 6. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

Before declaring any database read-write replica architecture, ORM split, or agent-generated database service production-ready, verify all six gates:

```
+---------------------------------------------------------------------------------------+
| GATE 1: ZERO READ-AFTER-WRITE 404 TESTS (Test Harness Invariant)                      |
| [ ] Automated integration test performs 10,000 rapid Write -> Read cycles under       |
|     simulated 200ms replica lag; 0 stale reads and 0 404 errors observed.             |
+---------------------------------------------------------------------------------------+
| GATE 2: STICKY PRIMARY SESSION PINNING (Session Invariant)                            |
| [ ] Mutations register a write epoch in session context/cookie; subsequent reads for  |
|     T_sticky (>= 5.0s) route to Primary writer without exception.                     |
+---------------------------------------------------------------------------------------+
| GATE 3: CAUSAL LSN TOKEN VERIFICATION (Replica Gate)                                  |
| [ ] When an operation carries an LSN token, replica verifies replay state; trailing   |
|     replicas trigger immediate transparent fallback to Primary.                       |
+---------------------------------------------------------------------------------------+
| GATE 4: DYNAMIC LAG-AWARE CIRCUIT BREAKING (High-Availability Gate)                   |
| [ ] Health monitor samples replica lag every <= 2s; any replica with lag > 1.0s or   |
|     broken replication stream is evicted within 1 interval.                           |
+---------------------------------------------------------------------------------------+
| GATE 5: REPLICATION SLOT DISK BLOAT DEFENSE (Storage Invariant)                       |
| [ ] Primary database enforces max_slot_wal_keep_size; metrics alert on unconsumed     |
|     WAL > 5GB to prevent 100% primary disk fill panics.                               |
+---------------------------------------------------------------------------------------+
| GATE 6: ZERO-READ MUTATION PROJECTIONS (Performance Invariant)                        |
| [ ] INSERT, UPDATE, and DELETE queries utilize RETURNING * to eliminate unnecessary   |
|     immediate read-after-write roundtrips at the network layer.                       |
+---------------------------------------------------------------------------------------+
```

---

## 7. Anti-Patterns vs Industrial Invariants

| Anti-Pattern (Vulnerable to Stale Reads & Crashes) | Industrial Production Invariant (Deterministic & Resilient) |
| :--- | :--- |
| **Naive ORM Read-Write Splitting**: Routing all `SELECT` queries to `replicaPool` unconditionally, triggering 404 Not Found immediately following inserts. | **Sticky Primary Session Pinning**: Pin all session reads to Primary writer for $T_{\text{sticky}} = \max(2 \times \tau_{\text{p99}}, 5\text{s})$ after any mutation. |
| **Blind Primary Routing**: Routing all queries to Primary to avoid lag bugs, overloading Primary CPU and idling replicas. | **Dynamic Causal LSN Fencing**: Route reads to replicas while verifying `pg_last_wal_replay_lsn() >= target_lsn`, falling back to Primary only when lagging. |
| **Round-Robin Multi-Replica Pagination**: User pagination hits random replicas with varying lag, causing items to vanish and reappear. | **Monotonic Session Replica Pinning**: Pin a user session to a single replica instance or verify non-decreasing replay timestamps across requests. |
| **Separate Mutation Then Read Roundtrip**: Executing `INSERT` or `UPDATE`, followed by `SELECT * FROM tbl WHERE id = :id`. | **Atomic Single-Statement Write-Through**: Execute `INSERT/UPDATE ... RETURNING *` to populate the caller with fresh state in zero extra roundtrips. |
| **Unbounded Replication Slots**: Allowing idle or lagging replicas to hold replication slots indefinitely until Primary disk fills to 100%. | **Storage Guardrails**: Set `max_slot_wal_keep_size = 10GB` and instrument Prometheus alerts on `pg_replication_slots.active` and lag bytes. |
| **Unprotected Multi-Query Reports on Replicas**: Executing 5 related analytical queries across random replica connections with drifting snapshots. | **Repeatable Read Transaction Encasement**: Wrap multi-query analytical batches in `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY` on a single connection. |
| **Stale Auth & Privilege Checks on Replicas**: Checking user permissions or revoked tokens against read replicas trailing by several seconds. | **Primary-Pinned Security Invariant**: Route all authentication validation, token revocation checks, and RBAC authorization reads to the Primary writer. |
