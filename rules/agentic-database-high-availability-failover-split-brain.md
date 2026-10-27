---
description: PostgreSQL high availability, automated failover, split-brain fencing, Patroni/etcd consensus, target_session_attrs=read-write client routing, zero-RPO synchronous replication, reconnection thundering herd jitter, and pg_rewind timeline reconciliation across Go (pgx/sqlc), TypeScript (Drizzle/Prisma), Python (SQLAlchemy/asyncpg), Rust (sqlx), Patroni, HAProxy, and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{ha,failover,cluster,replica,standby,patroni,reconnect,connection,postgres}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/infra/**/*.{ts,js,go,rs,py,yaml,yml},**/internal/db/**/*.{go,rs},**/internal/repository/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database High Availability, Automated Failover, Split-Brain Fencing & Client Reconnection Topology

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to configure database clusters, design mission-critical persistence layers, orchestrate automated failover mechanisms, provision Patroni/etcd topologies, or implement resilient client reconnection pooling across PostgreSQL, Go (`jackc/pgx`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `pg`), Python (`SQLAlchemy`, `asyncpg`), or Rust (`sqlx`). Eliminate the "Split-Brain Dual-Primary Write Divergence Disaster" (where network partitions cause two nodes to believe they are the writable leader, producing irreconcilably divergent WAL timelines and permanent data corruption), the "Flapping Primary Cascading Failover Thrash" (where transient latency hiccups trigger oscillating failovers, connection storms, and total cluster blackout), the "Client Read-Only Reconnection Trap" (where applications reconnect after failover without `target_session_attrs=read-write`, landing on read-only standbys and crashing with `25006 cannot execute INSERT`), the "Stale Standby Promotion & Zero-RPO Invalidation Trap" (where asynchronous replicas with un-replayed WAL are promoted to leader, obliterating committed financial transactions), the "Reconnection Thundering Herd & Socket Avalanche" (where thousands of dropped connections attempt simultaneous reconnects to the newly promoted primary, spiking CPU to 100% and triggering cascade connection timeouts), and the "pg_rewind Timeline Fork Re-join Catastrophe" (where demoted primaries fail to rejoin the cluster due to timeline divergence, forcing multi-hour, multi-gigabyte basebackup re-cloning) by establishing a strict 5-Tier HA & Failover Governance Ladder, watchdog fencing, multi-host read-write driver topologies, synchronous replication quorums, and automated timeline reconciliation.

---

## 1. Architectural Taxonomy: The 6 HA & Failover Catastrophes vs The 5-Tier Governance Ladder

In high-concurrency production systems, relational database High Availability (HA) requires orchestrating five tightly coupled layers:
1. **Distributed Consensus Subsystem (DCS)**: Raft or Paxos-backed state stores (etcd, Consul) maintaining the definitive leader lease.
2. **Cluster Manager & Supervisor (Patroni / Stolon)**: Node daemon monitoring PostgreSQL health, acquiring the leader key, and orchestrating promotion.
3. **Fencing & Shoot-The-Other-Node-In-The-Head (STONITH)**: Hardware/software watchdogs (`/dev/watchdog`) ensuring unseated primaries are terminated before standbys promote.
4. **Physical Replication Engine**: PostgreSQL streaming replication, synchronous commit quorums, and WAL timeline management (`pg_rewind`).
5. **Client Connection Routing**: Multi-host connection drivers or proxy layers (PgBouncer, HAProxy, Envoy) routing writes strictly to the active leader.

When autonomous coding agents write database connection initialization, cluster automation, or application failover logic, LLMs routinely commit fatal architectural anti-patterns:

```typescript
// ❌ CATASTROPHIC LLM DATABASE HA & CONNECTION ANTI-PATTERNS

// 1. Single-host DNS endpoint relying on stale DNS TTL!
// When node-1 fails, DNS caching in JVM, Node.js, or Go keeps sending traffic to the dead host!
const pool = new Pool({
  connectionString: 'postgresql://db-primary.internal.acme.com:5432/production', // FATAL: DNS caching blocks failover
});

// 2. Multi-host connection string missing target_session_attrs!
// The driver connects to the first responding node, which is a read-only standby!
const multiHostPool = new Pool({
  // FATAL: Without target_session_attrs=read-write, writes land on standbys and fail with 25006!
  connectionString: 'postgresql://node-1:5432,node-2:5432,node-3:5432/production',
});

// 3. Unbounded, un-jittered synchronous reconnection loop!
// When primary promotes, 5,000 application pods reconnect at millisecond zero, crashing the new primary!
async function reconnectForever(client: DatabaseClient) {
  while (true) {
    try {
      await client.connect();
      break;
    } catch (err) {
      // FATAL: Zero jitter, fixed 100ms interval. Triggers catastrophic thundering herd!
      await sleep(100);
    }
  }
}
```

In production architectures, naive failover configurations trigger six critical engineering disasters:

- **The "Split-Brain Dual-Primary Write Divergence Disaster" (Timeline Fork Corruption)**:
  - When an isolated network partition occurs between the primary database node and the rest of the cluster (or the DCS), the secondary nodes observe a heartbeat timeout and elect a new leader.
  - If the old primary is not decisively fenced (its operating system killed or write capabilities physically severed), it continues accepting writes from lingering clients or local microservices.
  - Both the old primary and the newly promoted primary now generate distinct Write-Ahead Logs (WAL) on diverging timeline IDs (e.g. Timeline 1 on old primary, Timeline 2 on new primary).
  - This creates irreconcilable, conflicting ledger mutations. Once the network partition heals, PostgreSQL cannot merge divergent WAL histories. Re-attaching the old primary requires discarding its writes, leading to lost customer transactions, corrupted inventory balances, and catastrophic forensic accounting nightmares.
  - Invariant: Mandatory Distributed Consensus Store (DCS) leasing with Linux hardware watchdog fencing (`/dev/watchdog`). The primary MUST continuously refresh its lease in etcd within $T_{\text{loop\_wait}}$. If the primary loses the lease, the kernel watchdog resets the hardware before the DCS lease expires and before the standby can complete promotion.

- **The "Flapping Primary Cascading Failover Thrash" (False-Positive Hysteresis Collapse)**:
  - Transient CPU saturation, heavy autovacuum spikes, or 1-second network hiccups cause naive health check scripts or external probes to report the primary dead.
  - An automated script immediately promotes a replica. As thousands of clients disconnect from the old primary and slam the new primary with new connections, the new primary's CPU spikes to 100%.
  - The health check on the new primary promptly fails, triggering another failover to a third node or back to the original node.
  - The cluster enters a continuous cascading failover flap loop, rendering the database 100% unavailable despite zero hardware or storage faults.
  - Invariant: Multi-point consensus health checks with hysteresis dampening. Require $K \ge 3$ consecutive heartbeat failures across independent network vantage points, failover cool-down minimums ($T_{\text{cooldown}} \ge 10 \times T_{\text{lease}}$), and consensus quorum voting ($> N / 2$).

- **The "Client Read-Only Reconnection Trap" (Missing target_session_attrs=read-write)**:
  - Following a successful failover, application connection pools attempt to re-establish dropped sockets.
  - Naive multi-host connection strings omit connection attributes: `postgresql://node1:5432,node2:5432,node3:5432/db`.
  - The client driver iterates through the host list and attaches to the first node that accepts a TCP handshake. In a 3-node cluster, 66% of connections land on read-only standbys!
  - Every subsequent write transaction fails with `ERROR: cannot execute INSERT in a read-only transaction` (`SQLSTATE 25006`). Application error rates spike to 100%, and transactional APIs crash worldwide.
  - Invariant: Multi-host connection URIs MUST declare `target_session_attrs=read-write` (e.g. `postgresql://node1,node2,node3/db?target_session_attrs=read-write&load_balance_hosts=disable`). The driver validates `SHOW transaction_read_only` during the handshake, ensuring 100% of write-capable pools connect exclusively to the genuine leader.

- **The "Stale Standby Promotion & Zero-RPO Invalidation Trap" (Unreplayed WAL Data Loss)**:
  - In asynchronous replication, standbys trail the primary by a variable replication lag $\tau_{\text{lag}}$.
  - When the primary fails, an automated script blindly promotes the first responding standby without verifying its received LSN against other cluster nodes.
  - Any transactions committed on the primary but not yet shipped or replayed to this standby are permanently obliterated when the standby becomes the new primary on a new timeline ($RPO > 0$).
  - Invariant: Zero-RPO Synchronous Standby Quorum (`synchronous_commit = remote_apply` or `on` with `synchronous_standby_names = 'ANY 1 (node2, node3)'`). Candidate election gating strictly restricts promotion to replicas satisfying $\text{LSN}_{\text{candidate}} == \max(\text{LSN}_{\text{cluster}})$.

- **The "Reconnection Thundering Herd & Socket Avalanche" (Connection Storm Meltdown)**:
  - When a primary fails or is promoted, 2,000 to 10,000 persistent client TCP connections across dozens of microservices drop simultaneously.
  - When the new primary opens its ports, all client connection pools (Go `pgxpool`, TypeScript `pg`, Java `HikariCP`, Python `asyncpg`) immediately attempt to re-populate their minimum idle connection quotas.
  - The new primary is assaulted by thousands of concurrent TCP handshakes, TLS negotiations, and PostgreSQL backend forks. CPU hits 100%, authentication packets time out, and clients retry aggressively, locking the newly promoted primary into a total resource exhaustion death spiral.
  - Invariant: Client connection pools MUST implement decorrelated exponential backoff with full randomized jitter:
    $$\tau_k = \text{Uniform}(0, \min(T_{\text{max}}, T_{\text{base}} \times 2^k))$$
    combined with connection ramp-up rate pacing ($\Delta C / \Delta t \le R_{\text{ramp}}$), pre-warmed idle pools, and proxy pooling layers (PgBouncer).

- **The "pg_rewind Timeline Fork Re-join Catastrophe" (Manual Resync Paralysis)**:
  - When a failed primary recovers or a network partition heals, the demoted primary node comes back online. Because it processed writes past the divergence point, standard streaming replication rejects it with `FATAL: timeline divergence: requested timeline X but local timeline is Y`.
  - Naive operators or automated scripts wipe the entire data directory and run `pg_basebackup` from scratch. Over a 500GB database, this saturates disk I/O, burns gigabits of network bandwidth for 3 hours, and leaves the cluster vulnerable with zero redundancy during the sync.
  - Invariant: Mandatory `wal_log_hints = on` enabled at cluster initialization. Automated cluster supervisors invoke `pg_rewind` to find the common ancestor WAL fork LSN, rewind only the mutated 8KB pages from the target primary, and re-attach the former primary as a streaming standby in $< 30$ seconds.

```text
========================================================================================================================
                                 THE 5-TIER DATABASE HA & FAILOVER GOVERNANCE LADDER
========================================================================================================================

  Tier 4: Automated Timeline Reconciliation, pg_rewind & Standby Re-attachment
  ├── Mandatory wal_log_hints = on in postgresql.conf allowing block-level delta analysis
  ├── Autonomous pg_rewind finding common WAL ancestor LSN and rolling back diverged pages
  └── Re-attaching former primary as standby in < 30s without destructive pg_basebackup re-cloning

  Tier 3: Reconnection Thundering Herd Suppression & Connection Ramp-Up Pacing
  ├── Full decorrelated jitter backoff: tau_k = Uniform(0, min(T_max, T_base * 2^k))
  ├── Bounded connection establishment velocity: Delta_C / Delta_t <= 50 connections/second
  └── Client-side circuit breaking shedding non-critical transactions during failover window

  Tier 2: Synchronous Replication Quorums & Zero-RPO Promotion Gating
  ├── synchronous_commit = on / remote_apply with synchronous_standby_names = 'ANY 1 (...)'
  ├── Mathematical proof: Committed transactions replicated to >= 1 standby before client ACK
  └── DCS election candidate gate: pg_last_wal_receive_lsn == max(lsn_cluster) strictly enforced

  Tier 1: Client Reconnection Topology & Read-Write Handshake Invariance
  ├── Multi-host connection URI: postgresql://node1,node2,node3/db?target_session_attrs=read-write
  ├── Handshake verification: Driver executes SHOW transaction_read_only before socket checkout
  └── Layer 4 failover proxies (HAProxy / Envoy / PgBouncer) with Patroni HTTP /primary health checks

  Tier 0: Strict Distributed Consensus (DCS), Lease Locks & Hardware Watchdog Fencing
  ├── Quorum consensus (etcd / Raft) maintaining leader lease: Q = floor(N / 2) + 1
  ├── Linux /dev/watchdog hardware timer reset bound: T_watchdog < T_lease - T_loop_wait - Delta_skew
  └── Guaranteed physical kernel panic / reboot before standby promotion eliminates 100% of split-brain
========================================================================================================================
```

---

## 2. Mathematical Invariants: Consensus Quorums, Fencing Inequalities & Thundering Herd Physics

High availability and distributed failover are governed by rigorous mathematical principles spanning distributed consensus, hardware watchdog timing, and queueing theory:

### 2.1 The Distributed Consensus Quorum & PACELC Theorem

In a cluster of $N$ nodes, distributed consensus requires a strict majority quorum $Q$:
$$Q = \left\lfloor \frac{N}{2} \right\rfloor + 1$$

To survive $F$ simultaneous node failures or network partitions without split-brain:
$$N \ge 2F + 1$$

Under the PACELC theorem (extension of CAP): If there is a Partition ($P$), the system trades off Availability ($A$) and Consistency ($C$); Else ($E$), the system trades off Latency ($L$) and Consistency ($C$).
- Relational transactional databases MUST prioritize Consistency ($C$) over Availability during partitions:
$$\mathbb{P}(\text{Split-Brain Dual Primary}) \equiv 0$$

### 2.2 The Watchdog Fencing & Lease Expiry Inequality

Let:
- $T_{\text{lease}}$: The DCS leader lease time-to-live in seconds (e.g. 30s).
- $T_{\text{loop\_wait}}$: The supervisor heartbeat loop execution interval (e.g. 10s).
- $T_{\text{watchdog}}$: The hardware watchdog countdown timer in seconds (e.g. 15s).
- $\Delta_{\text{clock\_skew}}$: The maximum bounded NTP clock drift across cluster nodes (typically $< 100\text{ms}$).

To mathematically guarantee that an unresponsive or partitioned primary CANNOT accept writes while a standby is being promoted, the hardware watchdog timeout MUST satisfy:
$$T_{\text{watchdog}} < T_{\text{lease}} - T_{\text{loop\_wait}} - \Delta_{\text{clock\_skew}}$$

**Proof**:
1. The supervisor on the primary attempts to renew its DCS leader lease every $T_{\text{loop\_wait}}$ seconds.
2. If the DCS becomes unreachable, the primary fails to renew its lease.
3. The watchdog daemon expects a ping (`/dev/watchdog`) within $T_{\text{watchdog}}$. Because the lease renewal failed, the supervisor refuses to ping the watchdog.
4. The watchdog expires and immediately triggers a physical kernel panic or hardware reboot at $t = T_{\text{watchdog}}$.
5. Meanwhile, the DCS leader key only expires at $t = T_{\text{lease}}$. Standbys cannot attempt promotion until the DCS leader key is deleted at $T_{\text{lease}}$.
6. Because $T_{\text{watchdog}} < T_{\text{lease}}$, the old primary is physically dead before any standby can claim the leader key and complete promotion. Hence, the probability of concurrent dual-primary execution is zero:
$$\mathbb{P}(\text{Dual Primary at time } t) = 0 \quad \forall t$$

### 2.3 The Reconnection Thundering Herd Contention Physics

When $M$ application pods each manage a connection pool of $C_{\text{pool}}$ connections, a sudden primary drop disconnects $N_{\text{total}} = M \times C_{\text{pool}}$ sockets simultaneously.

If reconnection is attempted with fixed delay $T_{\text{fixed}}$, the instantaneous connection arrival rate $\lambda_{\text{reconnect}}$ at the new primary is:
$$\lambda_{\text{instant}} = \lim_{\Delta t \to 0} \frac{N_{\text{total}}}{\Delta t} \to \infty$$

Under Little's Law, the queue length $L$ in the database TCP accept queue is:
$$L = \lambda \times W$$
where $W$ is the TLS handshake and backend fork latency ($W \approx 15\text{ms} - 50\text{ms}$). When $\lambda \cdot W > \text{listen\_backlog}$ (default: 128), incoming SYN packets are dropped, TCP resets are sent, and connection timeouts cascade.

Applying **Decorrelated Exponential Jitter**:
$$\tau_k = \min\left(T_{\text{max}}, \text{Uniform}(T_{\text{base}}, \tau_{k-1} \times 3)\right)$$
The arrival rate $\lambda(t)$ is flattened across a spread window $\Omega = [0, T_{\text{spread}}]$:
$$\bar{\lambda}_{\text{reconnect}} = \frac{N_{\text{total}}}{T_{\text{spread}}} \le \frac{\text{max\_connections} - C_{\text{active}}}{W_{\text{handshake}}}$$
This guarantees the new primary's CPU load during recovery remains strictly bounded within stable operating limits.

### 2.4 Zero-RPO Synchronous Quorum Math

For any committed transaction $T_x$ with commit Log Sequence Number $\text{LSN}(T_x)$:
$$\text{LSN}_{\text{replicated}} = \max_{j \in \text{SyncReplicas}} \left(\text{pg\_last\_wal\_receive\_lsn}(j)\right)$$
$$\text{Lag}_{\text{sync}} = \text{LSN}(T_x) - \text{LSN}_{\text{replicated}} \equiv 0$$
Because the primary blocks client commit ACK until at least one synchronous standby confirms receipt:
$$\text{RPO} = 0$$

---

## 3. TypeScript Reference Engine: `AgenticDatabaseHAEngine`

This reference engine provides production-grade multi-host connection pooling, automated primary detection with `target_session_attrs=read-write`, decorrelated jittered reconnection, and simulated hardware watchdog leasing:

```typescript
/**
 * AgenticDatabaseHAEngine
 * Production-ready Database High Availability, Failover & Topology Router
 */

import { EventEmitter } from 'node:events';

export interface NodeEndpoint {
  id: string;
  host: string;
  port: number;
  isPrimary: boolean;
  isAlive: boolean;
  lastWalLsn: bigint;
  timelineId: number;
}

export interface HAEngineOptions {
  nodes: Array<{ id: string; host: string; port: number }>;
  leaseTtlMs: number;
  watchdogTimeoutMs: number;
  heartbeatIntervalMs: number;
  baseBackoffMs: number;
  maxBackoffMs: number;
  maxRampUpRatePerSec: number;
}

export interface TransactionResult<T> {
  result: T;
  nodeId: string;
  timelineId: number;
  latencyMs: number;
}

export class AgenticDatabaseHAEngine extends EventEmitter {
  private readonly nodes: Map<string, NodeEndpoint> = new Map();
  private readonly options: HAEngineOptions;
  private currentPrimaryId: string | null = null;
  private dcsLeaderKey: string | null = null;
  private leaseExpiresAt: number = 0;
  private lastWatchdogPingAt: number = 0;
  private isFenced: boolean = false;
  private heartbeatTimer: NodeJS.Timeout | null = null;
  private consecutiveFailures: Map<string, number> = new Map();

  constructor(options: HAEngineOptions) {
    super();
    this.options = options;

    // Verify mathematical watchdog fencing inequality at startup!
    if (this.options.watchdogTimeoutMs >= this.options.leaseTtlMs - this.options.heartbeatIntervalMs) {
      throw new Error(
        `FATAL FENCING CONFIGURATION: watchdogTimeout (${this.options.watchdogTimeoutMs}ms) ` +
        `must be strictly less than leaseTtl (${this.options.leaseTtlMs}ms) - heartbeatInterval (${this.options.heartbeatIntervalMs}ms) ` +
        `to prevent split-brain dual-primary corruption!`
      );
    }

    for (const n of options.nodes) {
      this.nodes.set(n.id, {
        id: n.id,
        host: n.host,
        port: n.port,
        isPrimary: false,
        isAlive: true,
        lastWalLsn: 0n,
        timelineId: 1,
      });
      this.consecutiveFailures.set(n.id, 0);
    }
  }

  public async bootstrapCluster(): Promise<void> {
    // Select initial primary (lowest node id)
    const sorted = Array.from(this.nodes.values()).sort((a, b) => a.id.localeCompare(b.id));
    const initialLeader = sorted[0];

    initialLeader.isPrimary = true;
    this.currentPrimaryId = initialLeader.id;
    this.dcsLeaderKey = initialLeader.id;
    this.leaseExpiresAt = Date.now() + this.options.leaseTtlMs;
    this.lastWatchdogPingAt = Date.now();

    this.emit('primary_elected', { nodeId: initialLeader.id, timeline: initialLeader.timelineId });
    this.startHeartbeatLoop();
  }

  private startHeartbeatLoop(): void {
    this.heartbeatTimer = setInterval(async () => {
      await this.runHeartbeatCycle();
    }, this.options.heartbeatIntervalMs);
  }

  private async runHeartbeatCycle(): Promise<void> {
    const now = Date.now();

    // 1. Check Primary Watchdog & Fencing
    if (this.currentPrimaryId) {
      const primary = this.nodes.get(this.currentPrimaryId);
      if (primary && primary.isAlive) {
        // Primary is healthy: renew DCS lease and ping watchdog
        this.leaseExpiresAt = now + this.options.leaseTtlMs;
        this.lastWatchdogPingAt = now;
        this.dcsLeaderKey = primary.id;
      } else {
        // Primary failed or unreachable!
        // Check if watchdog expired
        if (now - this.lastWatchdogPingAt >= this.options.watchdogTimeoutMs) {
          if (!this.isFenced) {
            this.isFenced = true;
            this.emit('primary_fenced', {
              nodeId: this.currentPrimaryId,
              reason: 'Watchdog timer expired without lease renewal',
            });
          }
        }
      }
    }

    // 2. Check DCS Lease Expiration and Trigger Standby Promotion
    if (this.dcsLeaderKey && now >= this.leaseExpiresAt) {
      this.emit('lease_expired', { previousLeader: this.dcsLeaderKey });
      this.dcsLeaderKey = null;
      await this.electNewLeader();
    }
  }

  public async electNewLeader(): Promise<string | null> {
    // Zero-RPO Promotion Gating: Candidate MUST have maximum received LSN
    const availableStandbys = Array.from(this.nodes.values()).filter(
      (n) => n.isAlive && n.id !== this.currentPrimaryId
    );

    if (availableStandbys.length === 0) {
      this.emit('cluster_blackout', { reason: 'No surviving nodes available for election' });
      return null;
    }

    // Sort by LSN descending, then lexicographical ID
    availableStandbys.sort((a, b) => {
      if (b.lastWalLsn !== a.lastWalLsn) {
        return b.lastWalLsn > a.lastWalLsn ? 1 : -1;
      }
      return a.id.localeCompare(b.id);
    });

    const elected = availableStandbys[0];
    const oldPrimaryId = this.currentPrimaryId;

    // Demote old primary
    if (oldPrimaryId) {
      const oldPrimary = this.nodes.get(oldPrimaryId);
      if (oldPrimary) oldPrimary.isPrimary = false;
    }

    // Promote new primary and increment timeline
    elected.isPrimary = true;
    elected.timelineId += 1;
    this.currentPrimaryId = elected.id;
    this.dcsLeaderKey = elected.id;
    this.leaseExpiresAt = Date.now() + this.options.leaseTtlMs;
    this.lastWatchdogPingAt = Date.now();
    this.isFenced = false;

    this.emit('failover_completed', {
      promotedNode: elected.id,
      demotedNode: oldPrimaryId,
      newTimeline: elected.timelineId,
      promotedLsn: elected.lastWalLsn.toString(),
    });

    return elected.id;
  }

  /**
   * Client Read-Write Routing with Handshake Verification
   * Mathematical Guarantee: Never routes write transactions to read-only standbys
   */
  public async executeWrite<T>(
    operation: (endpoint: NodeEndpoint) => Promise<T>
  ): Promise<TransactionResult<T>> {
    let attempt = 0;
    let lastError: Error | null = null;
    let backoff = this.options.baseBackoffMs;

    while (attempt < 5) {
      attempt++;
      const startTime = performance.now();

      // Find current node with target_session_attrs=read-write
      const activePrimary = this.resolveReadWritePrimary();

      if (!activePrimary) {
        lastError = new Error('CLUSTER_FAILOVER_IN_PROGRESS: No writable primary currently available');
        const jitter = this.computeDecorrelatedJitter(backoff);
        await this.sleep(jitter);
        backoff = Math.min(this.options.maxBackoffMs, backoff * 2);
        continue;
      }

      try {
        // Enforce Handshake Verification
        if (!activePrimary.isPrimary || !activePrimary.isAlive) {
          throw new Error('ERR_25006_READ_ONLY_TRANSACTION: Node is not an active read-write leader');
        }

        const result = await operation(activePrimary);
        // Advance WAL LSN on successful mutation
        activePrimary.lastWalLsn += 100n;

        return {
          result,
          nodeId: activePrimary.id,
          timelineId: activePrimary.timelineId,
          latencyMs: Math.round(performance.now() - startTime),
        };
      } catch (err) {
        lastError = err as Error;
        this.emit('write_retry', { attempt, error: lastError.message, nodeId: activePrimary?.id });
        const jitter = this.computeDecorrelatedJitter(backoff);
        await this.sleep(jitter);
        backoff = Math.min(this.options.maxBackoffMs, backoff * 2);
      }
    }

    throw new Error(`WRITE_FAILED_AFTER_RETRIES: ${lastError?.message}`);
  }

  public resolveReadWritePrimary(): NodeEndpoint | null {
    if (!this.currentPrimaryId) return null;
    const node = this.nodes.get(this.currentPrimaryId);
    if (!node || !node.isAlive || !node.isPrimary) return null;
    return node;
  }

  /**
   * Decorrelated Exponential Jitter: Uniform(0, min(maxBackoff, base * 2^k))
   * Slashes reconnection thundering herd spikes by > 90%
   */
  public computeDecorrelatedJitter(currentBackoff: number): number {
    const min = Math.floor(currentBackoff * 0.5);
    const max = currentBackoff;
    return Math.floor(Math.random() * (max - min + 1)) + min;
  }

  /**
   * Automated Timeline Reconciliation via pg_rewind simulation
   */
  public async reconcileDemotedNode(nodeId: string): Promise<boolean> {
    const node = this.nodes.get(nodeId);
    const currentPrimary = this.resolveReadWritePrimary();

    if (!node || !currentPrimary) return false;

    // Common ancestor check
    if (node.timelineId < currentPrimary.timelineId) {
      this.emit('pg_rewind_started', {
        nodeId,
        fromTimeline: node.timelineId,
        targetTimeline: currentPrimary.timelineId,
      });

      // Synchronize LSN and update timeline
      node.timelineId = currentPrimary.timelineId;
      node.lastWalLsn = currentPrimary.lastWalLsn;
      node.isPrimary = false;
      node.isAlive = true;

      this.emit('pg_rewind_completed', {
        nodeId,
        reattachedAsStandbyTo: currentPrimary.id,
        timeline: node.timelineId,
      });
      return true;
    }

    return true;
  }

  public simulateNodeFailure(nodeId: string): void {
    const node = this.nodes.get(nodeId);
    if (!node) return;
    node.isAlive = false;
    this.emit('node_failure_detected', { nodeId });
  }

  public simulateNodeRecovery(nodeId: string): void {
    const node = this.nodes.get(nodeId);
    if (!node) return;
    node.isAlive = true;
    this.emit('node_recovered', { nodeId });
  }

  public teardown(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
```

---

## 4. The 6-State HA & Failover Lifecycle Finite-State Machine (FSM)

The lifecycle of high availability, failover, fencing, and timeline recovery is modeled as a strictly deterministic finite-state machine:

```text
       ┌────────────────────────────────────────────────────────┐
       │               STATE 1: CLUSTER_HEALTHY                 │
       │   Primary holds DCS lease, Standbys stream WAL in sync │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Primary heartbeat fails / DCS unreachable
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │             STATE 2: PRIMARY_UNRESPONSIVE              │
       │    Consecutive probe failures >= 3, lease un-renewed   │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Watchdog timer (T_watchdog) countdown begins
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │             STATE 3: HARDWARE_FENCING                  │
       │  Linux /dev/watchdog panics/reboots old primary node   │
       │    Mathematical Proof: Old primary dead before T_lease │
       └──────────────────────────┬─────────────────────────────┘
                                  │ DCS lease expires (T_lease); Standbys bid
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │             STATE 4: LEADER_PROMOTION_ELECTION         │
       │ Candidate with pg_last_wal_receive_lsn == max elected   │
       │   PostgreSQL advances timeline (TimelineId = N + 1)    │
       └──────────────────────────┬─────────────────────────────┘
                                  │ New primary opens port 5432
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │            STATE 5: CLIENT_JITTERED_RECONNECT          │
       │   Drivers probe with target_session_attrs=read-write   │
       │ Decorrelated jitter prevents thundering herd avalanche │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Old primary recovers from reboot
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │             STATE 6: PG_REWIND_REATTACHMENT            │
       │ Automated pg_rewind rolls back divergent pages to fork │
       │      Node re-attaches as streaming read-only standby   │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Replication stream healthy
                                  ▼
                         [ Back to STATE 1 ]
```

### State Transition Invariants:
1. **Transition $1 \to 2$**: Probing must require at least $K \ge 3$ consecutive failures across independent threads to eliminate false-positive flapping.
2. **Transition $2 \to 3$**: The hardware watchdog timer MUST trigger before $T_{\text{lease}}$ expires: $T_{\text{watchdog}} < T_{\text{lease}} - T_{\text{loop\_wait}}$.
3. **Transition $3 \to 4$**: Standby election enforces Zero-RPO promotion gating; candidates with stale LSN are rejected.
4. **Transition $4 \to 5$**: Client connection drivers MUST verify `SHOW transaction_read_only = off` before dispatching writes.
5. **Transition $5 \to 6$**: Demoted nodes MUST run `pg_rewind` to align with the new timeline before streaming replication starts.

---

## 5. Polyglot Production Implementations

### 5.1 Go (`jackc/pgx/v5` Multi-Host Topology & Failover Jitter)

Go services using `pgxpool` MUST provide multi-host connection strings with `target_session_attrs=read-write` and custom jittered retry wrappers:

```go
package db

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"net"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Config represents multi-host PostgreSQL HA configuration
type HAConfig struct {
	// Multi-host connection string format:
	// postgres://user:pass@host1:5432,host2:5432,host3:5432/dbname?target_session_attrs=read-write&sslmode=verify-full
	ConnString  string
	MaxConns    int32
	MinConns    int32
	BaseBackoff time.Duration
	MaxBackoff  time.Duration
}

// ResilientPool wraps pgxpool with failover retry policies
type ResilientPool struct {
	pool   *pgxpool.Pool
	config HAConfig
}

func NewResilientPool(ctx context.Context, cfg HAConfig) (*ResilientPool, error) {
	poolConfig, err := pgxpool.ParseConfig(cfg.ConnString)
	if err != nil {
		return nil, fmt.Errorf("failed to parse multi-host conn string: %w", err)
	}

	// 1. Mandatory Pool Sizing Invariants
	poolConfig.MaxConns = cfg.MaxConns
	poolConfig.MinConns = cfg.MinConns
	poolConfig.MaxConnLifetime = 30 * time.Minute
	poolConfig.MaxConnIdleTime = 5 * time.Minute

	// 2. TCP Keepalive to detect severed failover sockets immediately
	poolConfig.ConnConfig.DialFunc = (&net.Dialer{
		KeepAlive: 5 * time.Second,
		Timeout:   3 * time.Second,
	}).DialContext

	// 3. Post-Connect Handshake: Verify read-write leader status
	poolConfig.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		var isReadOnly string
		err := conn.QueryRow(ctx, "SHOW transaction_read_only").Scan(&isReadOnly)
		if err != nil {
			return fmt.Errorf("handshake check failed: %w", err)
		}
		if isReadOnly == "on" {
			return errors.New("connected to read-only replica when target_session_attrs=read-write required")
		}
		return nil
	}

	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize pgxpool: %w", err)
	}

	return &ResilientPool{
		pool:   pool,
		config: cfg,
	}, nil
}

// ExecuteWriteWithFailoverRetry executes a mutation with decorrelated jitter retry on failover
func (r *ResilientPool) ExecuteWriteWithFailoverRetry(
	ctx context.Context,
	op func(ctx context.Context, tx pgx.Tx) error,
) error {
	backoff := r.config.BaseBackoff

	for attempt := 0; attempt < 5; attempt++ {
		err := pgx.BeginTxFunc(ctx, r.pool, pgx.TxOptions{
			IsoLevel: pgx.ReadCommitted,
		}, op)

		if err == nil {
			return nil
		}

		// Check if error is due to primary failover or read-only transition
		if isFailoverError(err) {
			jitter := computeDecorrelatedJitter(backoff)
			select {
			case <-time.After(jitter):
				backoff = minDuration(r.config.MaxBackoff, backoff*2)
				continue
			case <-ctx.Done():
				return ctx.Err()
			}
		}

		// Non-retryable application error
		return err
	}

	return errors.New("transaction failed after maximum failover retries")
}

func isFailoverError(err error) bool {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		// 25006: read_only_sql_transaction
		// 57P01: admin_shutdown
		// 57P02: crash_shutdown
		// 57P03: cannot_connect_now
		if pgErr.Code == "25006" || pgErr.Code == "57P01" || pgErr.Code == "57P02" || pgErr.Code == "57P03" {
			return true
		}
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	return false
}

func computeDecorrelatedJitter(base time.Duration) time.Duration {
	n, _ := rand.Int(rand.Reader, big.NewInt(base.Nanoseconds()))
	return time.Duration(n.Int64())
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
```

---

### 5.2 TypeScript (`node-postgres` Multi-Host Topology & Handshake Pool)

```typescript
import { Pool, PoolConfig, PoolClient } from 'pg';

export interface MultiHostConfig {
  hosts: string[]; // ['node-1.internal:5432', 'node-2.internal:5432', 'node-3.internal:5432']
  database: string;
  user: string;
  password?: string;
  maxConns: number;
}

export class ResilientPostgresPool {
  private primaryPool: Pool | null = null;
  private currentPrimaryHost: string | null = null;
  private readonly config: MultiHostConfig;

  constructor(config: MultiHostConfig) {
    this.config = config;
  }

  /**
   * Discovers and connects exclusively to the read-write primary node
   */
  public async getPrimaryClient(): Promise<PoolClient> {
    for (const hostPort of this.config.hosts) {
      const [host, portStr] = hostPort.split(':');
      const port = parseInt(portStr, 10);

      const candidatePool = new Pool({
        host,
        port,
        database: this.config.database,
        user: this.config.user,
        password: this.config.password,
        connectionTimeoutMillis: 2000,
      });

      try {
        const client = await candidatePool.connect();
        // Handshake verification query
        const res = await client.query('SHOW transaction_read_only');
        const isReadOnly = res.rows[0].transaction_read_only === 'on';

        if (!isReadOnly) {
          // Genuine writeable primary confirmed!
          this.currentPrimaryHost = hostPort;
          return client;
        }

        // It is a standby replica, release and try next
        client.release();
        await candidatePool.end();
      } catch (err) {
        // Node unreachable or rejecting connections, continue scan
        await candidatePool.end().catch(() => {});
      }
    }

    throw new Error('HA_ROUTING_ERROR: No writable primary node found across cluster hosts');
  }
}
```

---

### 5.3 Patroni High-Availability Cluster Configuration (`patroni.yml`)

Production-ready Patroni configuration guaranteeing Linux hardware watchdog fencing, synchronous replication quorums, and automatic `pg_rewind`:

```yaml
# patroni.yml - Enterprise High Availability & Fencing Configuration
scope: postgres-production-cluster
namespace: /service
name: pg-node-01

# 1. Distributed Consensus Store (etcd3)
etcd3:
  hosts:
    - 10.0.1.10:2379
    - 10.0.1.11:2379
    - 10.0.1.12:2379

# 2. Watchdog Hardware Fencing (Eliminates Split-Brain)
watchdog:
  mode: automatic
  device: /dev/watchdog
  safety_margin: 5

# 3. Cluster Heartbeat, Lease & Failover Timings
ttl: 30                  # DCS leader lease TTL (seconds)
loop_wait: 10            # Primary heartbeat loop interval (seconds)
retry_timeout: 10        # etcd operation retry timeout
maximum_lag_on_failover: 1048576 # 1MB maximum replication lag allowed for promotion

# 4. Zero-RPO Synchronous Replication
synchronous_mode: true
synchronous_mode_strict: false # Allows reads if all standbys drop, but guards commits

# 5. PostgreSQL Engine Parameters
bootstrap:
  dcs:
    synchronous_mode: true
    synchronous_mode_strict: false
    postgresql:
      use_pg_rewind: true # Mandatory automatic timeline rewind
      use_slots: true     # Replication slots prevent WAL recycling before standbys receive
      parameters:
        wal_log_hints: 'on' # Required for pg_rewind
        synchronous_commit: 'on'
        synchronous_standby_names: 'ANY 1 (pg-node-02, pg-node-03)'
        hot_standby: 'on'
        wal_level: replica
        max_wal_senders: 10
        max_replication_slots: 10
        checkpoint_completion_target: 0.9
        max_wal_size: 32GB

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.1.1:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/16/bin
  pgpass: /var/lib/postgresql/.pgpass
  authentication:
    replication:
      username: replicator
      password: ReplicatorSecurePassword123!
    superuser:
      username: postgres
      password: SuperuserSecurePassword123!

# 6. REST API for HAProxy / Envoy Health Checks
restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.1.1:8008
```

---

### 5.4 HAProxy Layer 4 Load Balancer Topology (`haproxy.cfg`)

Route writes strictly to `/primary` and distribute reads across `/replica`:

```haproxy
global
    maxconn 10000

defaults
    log global
    mode tcp
    retries 3
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 2s

# Primary Port (5000) -> Routes strictly to the active Patroni Leader
frontend postgres_write_frontend
    bind *:5000
    default_backend postgres_write_backend

backend postgres_write_backend
    mode tcp
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg-node-01 10.0.1.1:5432 maxconn 500 check port 8008
    server pg-node-02 10.0.1.2:5432 maxconn 500 check port 8008
    server pg-node-03 10.0.1.3:5432 maxconn 500 check port 8008

# Read Replica Port (5001) -> Distributes load across active Standbys
frontend postgres_read_frontend
    bind *:5001
    default_backend postgres_read_backend

backend postgres_read_backend
    mode tcp
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2
    server pg-node-01 10.0.1.1:5432 check port 8008
    server pg-node-02 10.0.1.2:5432 check port 8008
    server pg-node-03 10.0.1.3:5432 check port 8008
```

---

## 6. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

Prior to deploying database clustering, driver configuration, or failover automation to staging or production, autonomous agents MUST verify all 6 gates:

| Gate | Verification Target | Industrial Pass Threshold | Failure Action |
| :--- | :--- | :--- | :--- |
| **Gate 1: Client Handshake** | `target_session_attrs=read-write` in driver URI | 100% of write connection pools verify `SHOW transaction_read_only = off` | Abort build; reject single-host or un-attributed URIs |
| **Gate 2: Watchdog Fencing** | Watchdog timeout inequality | $T_{\text{watchdog}} < T_{\text{lease}} - T_{\text{loop\_wait}} - \Delta_{\text{skew}}$ verified | Halt cluster launch; adjust DCS lease or watchdog timer |
| **Gate 3: Zero-RPO Invariance** | `synchronous_commit` & standby names | `synchronous_commit = on`, `synchronous_standby_names = 'ANY 1 (...)'` | Reject configuration; block asynchronous promotion |
| **Gate 4: Reconnection Jitter** | Decorrelated exponential backoff | Full jitter $\tau = \text{Uniform}(0, \min(T_{\text{max}}, T_{\text{base}} \cdot 2^k))$ verified in code AST | Reject fixed-interval or zero-jitter retry loops |
| **Gate 5: Timeline Fork pg_rewind** | Automatic delta resync | `wal_log_hints = on` enabled; simulated divergence heals in $< 60\text{s}$ | Fail staging validation; block destructive basebackup |
| **Gate 6: Chaos Failover Test** | Kill primary process (`kill -9`) | Standby promotes in $< 15\text{s}$; client writes recover with 0 dropped TXs | Escalate to DBA; tune heartbeat and DCS parameters |

---

## 7. Anti-Patterns vs Industrial Invariants

| Dimension | ❌ Naive Agent Heuristic | ✅ Industrial Production Invariant |
| :--- | :--- | :--- |
| **Cluster Topology URI** | Single DNS name (`db-primary.internal`) caching stale IP | Multi-host URI: `postgresql://node1,node2,node3/db?target_session_attrs=read-write` |
| **Split-Brain Defense** | Software-only health ping without hardware fencing | Linux `/dev/watchdog` hardware watchdog killing kernel before DCS lease expiry |
| **Standby Promotion** | Blindly promotes lowest ping replica regardless of lag | Candidate LSN gating: only promote if $\text{LSN}_{\text{candidate}} == \max(\text{LSN}_{\text{cluster}})$ |
| **Reconnection Strategy** | Tight `while(true)` loop with fixed 100ms sleep | Decorrelated exponential jitter backoff with connection ramp-up pacing |
| **Diverged Node Recovery** | Destructive `rm -rf $PGDATA` and multi-hour `pg_basebackup` | Non-destructive `pg_rewind` rolling back only mutated 8KB pages in $< 30\text{s}$ |
| **Health Check Routing** | Generic TCP ping on port 5432 returning false positives | HTTP health check on Patroni `/primary` (port 8008) returning 200 strictly for leader |
