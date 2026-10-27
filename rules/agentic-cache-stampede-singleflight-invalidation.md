---
description: Agentic cache stampede mitigation, singleflight request coalescing, probabilistic early expiration (XFetch), multi-tier L1/L2 coherence, Redis Pub/Sub invalidation bus, negative caching sentinels, and Bloom filter penetration defense across Redis, PostgreSQL, Memcached, Go, TypeScript, Node.js, Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{cache,singleflight,redis,lru,memoize,xfetch,store,readthrough}*.*,**/src/cache/**/*.{ts,js,go,rs,py},**/src/services/**/*.{ts,js,go,rs,py},**/lib/cache/**/*.{ts,js,go,rs,py}
alwaysApply: false
---

# Agentic Cache Stampede, Singleflight Request Coalescing & Distributed Invalidation Governance Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design caching layers, read-through services, LLM embedding memoization, database query caches, or multi-tier distributed state architectures across Redis, PostgreSQL, Memcached, Go, TypeScript, or Python. Eliminate the "Cache Stampede / Thundering Herd Collapse" (where high-concurrency key expiry causes thousands of concurrent requests to hammer downstream databases and LLM gateways simultaneously), the "Dogpiling & Duplicate Computation Token Burn Disaster" (where parallel sub-agents or goroutines execute identical expensive LLM completions, embeddings, or DB queries concurrently without coalescing), the "Multi-Tier L1 Memory Cache Coherence Drift & Ghost State Trap" (where in-process LRU caches serve stale or unauthorized data across multi-replica services due to missing cross-node invalidation buses), the "Probabilistic Early Expiration Deficit (Deterministic Expiry Cliff)" (where hard TTLs guarantee latency spikes and stampedes for hot keys), the "Cache Penetration / Null-Key Exhaustion DoS Attack" (where non-existent keys bypass cache to crash backend datastores), and the "Cache Avalanche & Uniform TTL Resonant Harmonic Collapse" by establishing a strict 5-Tier Cache Coherence & Anti-Stampede Governance Ladder, singleflight request coalescing, Vitter's XFetch probabilistic early recomputation, distributed mutex fencing with Stale-While-Revalidate (SWR), and multi-tier L1/L2 Pub/Sub invalidation buses.

---

## 1. Architectural Taxonomy: The 6 Cache Stampede & Coherence Catastrophes vs The 5-Tier Cache Governance Ladder

When autonomous coding agents implement caching layers or read-through wrappers, LLMs consistently produce naive cache-aside code with critical concurrency hazards:

```typescript
// ❌ CATASTROPHIC LLM CACHE-ASIDE PATTERN
async function getUserProfile(userId: string) {
  // VULN 1: Cache Penetration: non-existent userId misses cache and hits DB every time!
  const cached = await redis.get(`user:${userId}`);
  if (cached) return JSON.parse(cached);

  // VULN 2: CATASTROPHIC: If key expires, 10,000 concurrent requests execute this DB query at once!
  // VULN 3: No singleflight coalescing: 10,000 concurrent DB queries and JSON serializations!
  const profile = await db.query('SELECT * FROM users WHERE id = $1', [userId]);

  // VULN 4: Uniform TTL: all keys written in a batch expire at the exact same millisecond!
  await redis.set(`user:${userId}`, JSON.stringify(profile), 'EX', 3600);
  return profile;
}
```

In high-concurrency, distributed, or agentic systems (such as LLM embedding lookups, multi-agent swarms querying workspace ASTs, and production microservices), this naive pattern triggers six catastrophic failure modes:

- **The "Cache Stampede / Thundering Herd Collapse"**:
  - A popular key (e.g., active workspace config, system prompt template, homepage catalog, top-ranked document) expires or is evicted under load.
  - At that exact millisecond, hundreds or thousands of concurrent incoming HTTP requests, WebSocket messages, or autonomous agent tool workers observe the cache miss simultaneously.
  - Every worker bypasses the cache and executes the expensive backend operation concurrently (PostgreSQL query with heavy joins, vector search, or 10-second external API call).
  - The database connection pool is immediately exhausted, CPU spikes to 100%, query latency balloons past 30 seconds, connection timeouts cascade through the service mesh, and the entire backend crashes.
  - Invariant: Concurrent requests for an expired or missing key MUST be coalesced in-process via **Singleflight Request Coalescing** so that exactly **one** upstream computation executes, while all other concurrent callers await the single promise/channel result.

- **The "Dogpiling & Duplicate Computation Token Burn Disaster"**:
  - In multi-agent swarms, parallel tools, or concurrent HTTP requests, multiple workers simultaneously compute the same expensive idempotent operation: generating embeddings for the same markdown file, running identical AST parses, or synthesizing the same complex SQL report.
  - Without in-flight request deduplication, $N$ identical LLM completions or vector database queries execute in parallel, burning thousands of dollars in unnecessary LLM token spend, exhausting rate limits, and introducing extreme GC memory churn.
  - Invariant: Expensive computations MUST be guarded by an atomic singleflight deduplication group. If an execution for key $K$ is already in-flight, subsequent requests MUST latch onto the existing task rather than initiating duplicate work.

- **The "Multi-Tier L1 Memory Cache Coherence Drift & Ghost State Trap"**:
  - To achieve sub-microsecond latency, services introduce an L1 in-process memory cache (V8 `Map`, LRU cache, or Go `sync.Map`) in front of L2 (Redis).
  - In a Kubernetes cluster with 20 pods, Pod 1 handles an update (`UPDATE users SET role = 'admin' WHERE id = 1`) and invalidates its local L1 cache and L2 Redis.
  - Pods 2 through 20 have no mechanism to learn of this update. Their local L1 memory caches continue serving the stale, revoked role until their arbitrary local TTL expires (e.g. 10 minutes later), causing permission bypasses, lost database updates, and intermittent split-brain bugs.
  - Invariant: Multi-tier caching MUST utilize an active **Pub/Sub Invalidation Bus** (or Redis stream) where write operations broadcast a cache invalidation event $E_{\text{inv}}(K, \text{epoch})$ to all cluster nodes, immediately evicting key $K$ from all replica L1 memory tiers.

- **The "Probabilistic Early Expiration Deficit (Deterministic Expiry Cliff)"**:
  - Hard deterministic TTLs guarantee that a hot cache key will inevitably expire while active traffic is flowing. The request that arrives 1 millisecond after TTL experiences a latency cliff, and if singleflight is missing across distributed nodes, triggers a cross-node stampede.
  - Invariant: Hot keys MUST employ **Vitter's Optimal Probabilistic Early Expiration Algorithm (XFetch)**: as a key approaches expiration, incoming reads evaluate a probabilistic recomputation condition based on remaining TTL, computation latency $\delta$, and aggressiveness factor $\beta$. A single background worker re-fetches and warms the cache before hard expiry occurs, achieving zero-latency cache hits continuously.

- **The "Cache Penetration / Null-Key Exhaustion DoS Attack"**:
  - Attackers, automated scrapers, or buggy agent loops repeatedly query non-existent identifiers (e.g., `user_id = "non-existent-uuid"` or random hash keys).
  - Because `null` or empty results are not cached by naive systems, 100% of these requests result in cache misses and penetrate directly to the underlying datastore.
  - Invariant: Missing or non-existent keys MUST either be filtered at the boundary via a **Bloom Filter** or cached as an explicit **Negative Sentinel Entry** (`NULL_SENTINEL` with a short, bounded TTL such as $30\text{s} \le \text{TTL}_{\text{neg}} \le 120\text{s}$).

- **The "Cache Avalanche & Uniform TTL Resonant Harmonic Collapse"**:
  - During system startup, daily batch data sync, or cache warming, tens of thousands of keys are written with the exact same static expiration (e.g., `redis.set(k, v, 'EX', 3600)`).
  - Exactly 3600 seconds later, all tens of thousands of keys expire at the exact same second.
  - The sudden mass evaporation of cache coverage instantly shifts all read traffic onto the database, triggering a catastrophic cluster-wide outage.
  - Invariant: All cache expiration durations MUST incorporate **Decorrelated TTL Jitter**: $\text{TTL}_{\text{actual}} = \text{TTL}_{\text{base}} \pm \text{Uniform}(0, \sigma_{\text{jitter}})$, spreading key expirations smoothly across time and eliminating resonant expiration waves.

---

```
             5-TIER CACHE COHERENCE & ANTI-STAMPEDE GOVERNANCE LADDER
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ Tier 4: Multi-Tier L1/L2 Invalidation Bus & Write-Through CDC Invariance    │
  │  - L1 In-Memory LRU (0.01ms) + L2 Redis Distributed (1ms)                  │
  │  - Monotonic Revision Epochs & Redis Pub/Sub Invalidation Multicast         │
  │  - Transactional Outbox / CDC Stream to Evict Stale Replicas Globally       │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 3: Distributed Mutex Fencing with Stale-While-Revalidate (SWR)         │
  │  - Redis `SET key val NX EX` Nonce Mutex for Cross-Node L2 Recomputation    │
  │  - Stale Serving on Contention: Return Stale Cache ($X\text{-Cache: STALE}$) │
  │  - Zero Upstream Latency Spikes for Concurrent Callers                      │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 2: Probabilistic Early Expiration (Vitter's XFetch Algorithm)          │
  │  - Asynchronous Background Recomputation: $-\beta \cdot \delta \cdot \ln(U) > \text{TTL}_{\text{rem}}│
  │  - Preemptive Cache Refresh Before Deterministic Expiry Cliff Occurs        │
  │  - Smooth Continuous Cache Hit Rates for Hot Keys                           │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 1: Singleflight In-Process Request Coalescing                          │
  │  - Coalesce $K$ Concurrent In-Flight Reads into Exactly 1 Execution Channel │
  │  - Shared Promise / Channel Fanout with Zero Duplicate Backend Work         │
  │  - Context Cancellation & Timeout Isolation for Subscribed Callers          │
  ├─────────────────────────────────────────────────────────────────────────────┤
  │ Tier 0: Static TTL Jittering & Negative Sentinel Caching                    │
  │  - Mandatory Decorrelated Jitter: $\text{TTL} = \text{TTL}_0 \pm \text{Uniform}(0, \sigma)$│
  │  - Cache Negative Hits with Bounded TTL: Banish Cache Penetration DoS       │
  │  - Bloom Filter Pre-Flight Screening for High-Cardinals                     │
  └─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical & Formal Invariant Calculus

### 2.1 The XFetch Probabilistic Early Recomputation Calculus

Let $m$ be a cached value with remaining time-to-live $\Delta t_{\text{ttl}} = T_{\text{expiry}} - t_{\text{now}}$ (in seconds). Let $\delta > 0$ denote the observed historical computation latency (in seconds) required to regenerate the value from the authoritative source (database, vector index, or LLM API). Let $\beta > 0$ be a dimensionless tuning parameter representing recomputation aggressiveness (typically $\beta = 1.0$).

Let $U \sim \text{Uniform}(0, 1)$ be a freshly sampled uniform random variable.

The **XFetch Early Recomputation Condition** (Vitter et al.) states that the current worker MUST initiate background recomputation of key $K$ if and only if:

$$-\beta \cdot \delta \cdot \ln(U) > \Delta t_{\text{ttl}}$$

#### Formal Mathematical Properties:
1. **Asymptotic Convergence**: As $\Delta t_{\text{ttl}} \to 0$ (approaching hard expiration), the probability of recomputation $P(\text{recompute}) \to 1$:
   $$P\left(U < e^{-\frac{\Delta t_{\text{ttl}}}{\beta \cdot \delta}}\right) = e^{-\frac{\Delta t_{\text{ttl}}}{\beta \cdot \delta}}$$
2. **Computational Adaptation**: If the backend operation is slow (large $\delta$, e.g. $\delta = 5\text{s}$ for an LLM embedding or heavy SQL aggregation), early recomputation triggers significantly earlier before expiry, providing a wide safety window.
3. **Stampede Elimination**: The probability that two independent concurrent requests simultaneously evaluate to `true` is small, naturally selecting a single background refresher while returning the still-valid cached value to all callers with zero waiting time.

### 2.2 The Singleflight Request Coalescing Throughput Inequality

Let $N_{\text{in}}$ be the number of concurrent requests arriving for key $K$ during the time interval $[t_0, t_0 + \delta]$ where $\delta$ is the upstream query execution latency.

Under naive cache-aside architectures without singleflight:

$$N_{\text{upstream\_calls}} = N_{\text{in}}, \quad \text{CPU}_{\text{db}} \propto N_{\text{in}}, \quad \text{PoolConns}_{\text{consumed}} = N_{\text{in}}$$

Under the **Singleflight Coalescing Invariant**:

$$N_{\text{upstream\_calls}} \equiv 1, \quad \forall N_{\text{in}} \ge 1$$

$$\text{Throughput Conservation Ratio} = \frac{N_{\text{in}} - 1}{N_{\text{in}}} \xrightarrow{N_{\text{in}} \to \infty} 100\%$$

All $N_{\text{in}} - 1$ secondary callers subscribe to the leader's completion broadcast channel. If caller $C_j$ aborts its request via HTTP client disconnect or context cancellation, the in-flight upstream execution continues uninterrupted to populate the cache for remaining callers, while caller $C_j$'s local channel listener is immediately cleaned up to prevent goroutine/promise leaks.

### 2.3 The Decorrelated TTL Jitter Variance Model

Let $T_{\text{base}}$ be the desired base cache expiration TTL (in seconds). Let $J \in [0, 1)$ denote the maximum jitter fraction (typically $J = 0.15$, representing $\pm 15\%$).

The generated TTL MUST satisfy:

$$\text{TTL}_{\text{effective}} = T_{\text{base}} \cdot \left(1 - J + 2J \cdot U\right), \quad U \sim \text{Uniform}(0, 1)$$

$$\mathbb{E}[\text{TTL}_{\text{effective}}] = T_{\text{base}}, \quad \operatorname{Var}(\text{TTL}_{\text{effective}}) = \frac{(2 \cdot J \cdot T_{\text{base}})^2}{12} > 0$$

By guaranteeing $\operatorname{Var}(\text{TTL}) > 0$, the probability that $M$ keys written at timestamp $t_0$ expire in the infinitesimal interval $[t_0 + T_{\text{base}}, t_0 + T_{\text{base}} + \Delta \tau]$ decays from 1 to:

$$P(\text{Collision}) \approx \frac{\Delta \tau}{2 \cdot J \cdot T_{\text{base}}} \ll 1$$

Eliminating harmonic cache avalanches.

### 2.4 Multi-Tier Invalidation Monotonic Epoch & Revision Invariant

Let $L_1(i)$ denote the in-process local memory cache of node $i \in \{1, \dots, M\}$. Let $L_2$ denote the shared distributed Redis tier, and let $S_{\text{authoritative}}$ be the underlying PostgreSQL database.

Each cache entry encapsulates a monotonic revision epoch $\mathbb{E} \in \mathbb{N}_{\ge 1}$ (e.g. database row version or microsecond timestamp):

$$\text{Entry}(K) = \langle \text{Value}, \mathbb{E}, \text{TTL}, \delta \rangle$$

The **Multi-Tier Coherence Invariant** requires:

$$\forall i, \quad \mathbb{E}(L_1(i)[K]) \le \mathbb{E}(L_2[K]) \le \mathbb{E}(S_{\text{authoritative}}[K])$$

Upon mutation of entity $K$ at epoch $\mathbb{E}_{\text{new}}$:
1. $S_{\text{authoritative}}$ is updated and commits with $\mathbb{E}_{\text{new}}$.
2. $L_2$ is updated or evicted.
3. An invalidation message $\mathcal{M}_{\text{inv}} = \langle K, \mathbb{E}_{\text{new}} \rangle$ is published to the cluster-wide invalidation bus.
4. Each node $j$ receiving $\mathcal{M}_{\text{inv}}$ compares epochs: if $\mathbb{E}(L_1(j)[K]) < \mathbb{E}_{\text{new}}$, node $j$ atomically evicts $K$ from its local $L_1$ memory tier.

---

## 3. Industrial Production TypeScript Reference Implementation: `AgenticMultiTierCacheEngine`

Below is the complete, production-ready, fully typed TypeScript reference implementation implementing all 5 tiers: in-process L1 LRU cache, distributed L2 Redis interface, Singleflight request coalescing, Vitter's XFetch probabilistic early refresh, negative caching sentinels, decorrelated TTL jitter, and cluster-wide invalidation event dispatching.

```typescript
/**
 * AgenticMultiTierCacheEngine.ts
 * Production-ready Multi-Tier Cache with Singleflight Coalescing & XFetch
 */

import { EventEmitter } from 'node:events';
import * as crypto from 'node:crypto';

export interface CacheEntry<T> {
  value: T;
  epoch: number;
  expiresAt: number;        // Epoch ms: hard TTL
  delta: number;            // Observed recomputation latency in ms
  isNegativeSentinel?: boolean;
}

export interface DistributedCacheDriver {
  get(key: string): Promise<string | null>;
  set(key: string, raw: string, ttlSeconds: number): Promise<void>;
  del(key: string): Promise<void>;
  setNx(key: string, value: string, ttlSeconds: number): Promise<boolean>;
  publish(channel: string, message: string): Promise<void>;
  subscribe(channel: string, onMessage: (msg: string) => void): Promise<void>;
}

export interface MultiTierCacheOptions {
  l1MaxItems?: number;
  l1TtlSeconds?: number;
  l2TtlSeconds?: number;
  jitterRatio?: number;     // e.g. 0.15 for +/- 15%
  xfetchBeta?: number;      // e.g. 1.0 (0 to disable XFetch)
  negativeTtlSeconds?: number;
  invalidationChannel?: string;
}

export interface CacheMetrics {
  l1Hits: number;
  l2Hits: number;
  singleflightCoalesced: number;
  xfetchEarlyRefreshes: number;
  negativeHits: number;
  backendComputations: number;
}

export class SingleflightGroup<T> {
  private inFlight = new Map<string, Promise<T>>();

  /**
   * Coalesces concurrent calls for the same key into a single execution.
   */
  public async do(key: string, fn: () => Promise<T>): Promise<{ result: T; shared: boolean }> {
    const existing = this.inFlight.get(key);
    if (existing) {
      const result = await existing;
      return { result, shared: true };
    }

    const promise = (async () => {
      try {
        return await fn();
      } finally {
        this.inFlight.delete(key);
      }
    })();

    this.inFlight.set(key, promise);
    const result = await promise;
    return { result, shared: false };
  }
}

/**
 * Minimal high-performance L1 LRU Cache
 */
class SimpleLruCache<T> {
  private cache = new Map<string, CacheEntry<T>>();
  constructor(private maxItems: number) {}

  get(key: string): CacheEntry<T> | undefined {
    const entry = this.cache.get(key);
    if (!entry) return undefined;
    if (Date.now() > entry.expiresAt) {
      this.cache.delete(key);
      return undefined;
    }
    // Refresh LRU order
    this.cache.delete(key);
    this.cache.set(key, entry);
    return entry;
  }

  set(key: string, entry: CacheEntry<T>): void {
    if (this.cache.has(key)) {
      this.cache.delete(key);
    } else if (this.cache.size >= this.maxItems) {
      // Evict oldest (first item in Map)
      const oldestKey = this.cache.keys().next().value;
      if (oldestKey) this.cache.delete(oldestKey);
    }
    this.cache.set(key, entry);
  }

  delete(key: string): void {
    this.cache.delete(key);
  }

  clear(): void {
    this.cache.clear();
  }
}

export class AgenticMultiTierCacheEngine {
  private l1: SimpleLruCache<any>;
  private singleflight = new SingleflightGroup<any>();
  private readonly l1TtlMs: number;
  private readonly l2TtlSeconds: number;
  private readonly jitterRatio: number;
  private readonly xfetchBeta: number;
  private readonly negativeTtlSeconds: number;
  private readonly invalidationChannel: string;
  private nodeId = crypto.randomUUID();

  public metrics: CacheMetrics = {
    l1Hits: 0,
    l2Hits: 0,
    singleflightCoalesced: 0,
    xfetchEarlyRefreshes: 0,
    negativeHits: 0,
    backendComputations: 0,
  };

  constructor(
    private l2Driver: DistributedCacheDriver,
    options: MultiTierCacheOptions = {}
  ) {
    this.l1 = new SimpleLruCache<any>(options.l1MaxItems ?? 5000);
    this.l1TtlMs = (options.l1TtlSeconds ?? 60) * 1000;
    this.l2TtlSeconds = options.l2TtlSeconds ?? 3600;
    this.jitterRatio = options.jitterRatio ?? 0.15;
    this.xfetchBeta = options.xfetchBeta ?? 1.0;
    this.negativeTtlSeconds = options.negativeTtlSeconds ?? 30;
    this.invalidationChannel = options.invalidationChannel ?? 'cache:invalidation:bus';

    this.initInvalidationBus();
  }

  private async initInvalidationBus(): Promise<void> {
    try {
      await this.l2Driver.subscribe(this.invalidationChannel, (rawMsg) => {
        try {
          const payload = JSON.parse(rawMsg);
          if (payload.originNodeId === this.nodeId) return; // Ignore own echoes
          if (payload.key) {
            this.l1.delete(payload.key);
          }
        } catch {
          // Ignore malformed invalidation frames
        }
      });
    } catch (err) {
      console.warn('[CacheEngine] Invalidation bus subscription failed; operating in autonomous L1 mode', err);
    }
  }

  /**
   * Applies decorrelated jitter to TTL: T * (1 - J + 2 * J * rand)
   */
  public computeJitteredTtl(baseSeconds: number): number {
    const rand = Math.random();
    const multiplier = 1 - this.jitterRatio + 2 * this.jitterRatio * rand;
    return Math.max(1, Math.round(baseSeconds * multiplier));
  }

  /**
   * Evaluates Vitter's XFetch algorithm: -beta * delta * ln(U) > delta_ttl
   */
  public shouldEarlyRefresh(entry: CacheEntry<any>): boolean {
    if (this.xfetchBeta <= 0 || entry.delta <= 0 || entry.isNegativeSentinel) {
      return false;
    }
    const remainingTtlMs = entry.expiresAt - Date.now();
    if (remainingTtlMs <= 0) return true; // Already expired

    const u = Math.max(1e-9, Math.random());
    const xfetchThreshold = -this.xfetchBeta * entry.delta * Math.log(u);
    return xfetchThreshold > remainingTtlMs;
  }

  /**
   * Primary entry point: Get or compute with full anti-stampede protections
   */
  public async getOrCompute<T>(
    key: string,
    computeFn: () => Promise<T | null>,
    customTtlSeconds?: number
  ): Promise<T | null> {
    // 1. Tier 0 & 1: Evaluate L1 In-Process Memory Cache
    const l1Entry = this.l1.get(key);
    if (l1Entry) {
      if (l1Entry.isNegativeSentinel) {
        this.metrics.negativeHits++;
        return null;
      }

      // Check XFetch Probabilistic Early Refresh
      if (this.shouldEarlyRefresh(l1Entry)) {
        this.metrics.xfetchEarlyRefreshes++;
        // Trigger non-blocking asynchronous background refresh
        this.triggerBackgroundRefresh(key, computeFn, customTtlSeconds).catch(() => {});
      }

      this.metrics.l1Hits++;
      return l1Entry.value as T;
    }

    // 2. Coalesce concurrent requests via Singleflight to protect L2 and DB
    const { result, shared } = await this.singleflight.do(key, async () => {
      // Re-check L1 in case a previous singleflight execution just populated it
      const freshL1 = this.l1.get(key);
      if (freshL1) return freshL1.value;

      // 3. Query L2 Distributed Redis Tier
      const rawL2 = await this.l2Driver.get(key);
      if (rawL2) {
        try {
          const entry: CacheEntry<T> = JSON.parse(rawL2);
          if (Date.now() <= entry.expiresAt) {
            // Populate L1 cache from L2 hit
            const l1Expires = Date.now() + Math.min(this.l1TtlMs, entry.expiresAt - Date.now());
            this.l1.set(key, { ...entry, expiresAt: l1Expires });

            if (entry.isNegativeSentinel) {
              this.metrics.negativeHits++;
              return null;
            }

            // Check XFetch on L2 entry
            if (this.shouldEarlyRefresh(entry)) {
              this.metrics.xfetchEarlyRefreshes++;
              this.triggerBackgroundRefresh(key, computeFn, customTtlSeconds).catch(() => {});
            }

            this.metrics.l2Hits++;
            return entry.value;
          }
        } catch {
          // JSON parse failed; treat as cache miss
        }
      }

      // 4. Cache Miss across L1 and L2: Execute Upstream Authoritative Compute
      const t0 = performance.now();
      this.metrics.backendComputations++;
      const computedValue = await computeFn();
      const deltaMs = Math.round(performance.now() - t0);

      // 5. Handle Null / Cache Penetration Defense
      const isNull = computedValue === null || computedValue === undefined;
      const ttlSec = isNull
        ? this.computeJitteredTtl(this.negativeTtlSeconds)
        : this.computeJitteredTtl(customTtlSeconds ?? this.l2TtlSeconds);

      const entry: CacheEntry<T | null> = {
        value: computedValue,
        epoch: Date.now(),
        expiresAt: Date.now() + ttlSec * 1000,
        delta: deltaMs,
        isNegativeSentinel: isNull,
      };

      // Write to L2 Redis with jittered expiration
      await this.l2Driver.set(key, JSON.stringify(entry), ttlSec);

      // Write to L1 in-memory cache
      const l1Ttl = Math.min(this.l1TtlMs, ttlSec * 1000);
      this.l1.set(key, { ...entry, expiresAt: Date.now() + l1Ttl });

      return computedValue;
    });

    if (shared) {
      this.metrics.singleflightCoalesced++;
    }

    return result as T | null;
  }

  /**
   * Asynchronous non-blocking background refresh triggered by XFetch
   */
  private async triggerBackgroundRefresh<T>(
    key: string,
    computeFn: () => Promise<T | null>,
    customTtlSeconds?: number
  ): Promise<void> {
    // Acquire a short distributed mutex lock in Redis to avoid cross-node stampede on refresh
    const lockKey = `lock:refresh:${key}`;
    const acquired = await this.l2Driver.setNx(lockKey, this.nodeId, 10);
    if (!acquired) return; // Another cluster pod is already refreshing this key

    try {
      const t0 = performance.now();
      const freshValue = await computeFn();
      const deltaMs = Math.round(performance.now() - t0);

      const isNull = freshValue === null || freshValue === undefined;
      const ttlSec = isNull
        ? this.computeJitteredTtl(this.negativeTtlSeconds)
        : this.computeJitteredTtl(customTtlSeconds ?? this.l2TtlSeconds);

      const entry: CacheEntry<T | null> = {
        value: freshValue,
        epoch: Date.now(),
        expiresAt: Date.now() + ttlSec * 1000,
        delta: deltaMs,
        isNegativeSentinel: isNull,
      };

      await this.l2Driver.set(key, JSON.stringify(entry), ttlSec);
      this.l1.set(key, { ...entry, expiresAt: Date.now() + Math.min(this.l1TtlMs, ttlSec * 1000) });

      // Notify other nodes to evict their stale L1 caches
      await this.broadcastInvalidation(key);
    } finally {
      await this.l2Driver.del(lockKey).catch(() => {});
    }
  }

  /**
   * Broadcast invalidation event to all cluster nodes
   */
  public async invalidate(key: string): Promise<void> {
    // Evict local L1 immediately
    this.l1.delete(key);
    // Evict distributed L2
    await this.l2Driver.del(key);
    // Multicast to all cluster peers
    await this.broadcastInvalidation(key);
  }

  private async broadcastInvalidation(key: string): Promise<void> {
    const payload = JSON.stringify({
      originNodeId: this.nodeId,
      key,
      timestamp: Date.now(),
    });
    await this.l2Driver.publish(this.invalidationChannel, payload).catch((err) => {
      console.warn('[CacheEngine] Invalidation broadcast failed', err);
    });
  }
}
```

---

## 4. 6-State Cache Coherence & Anti-Stampede Finite-State Machine (FSM)

Every cache read-through and invalidation request traverses a deterministic 6-state finite-state machine guaranteeing zero un-coalesced upstream stampedes:

```
                          ┌───────────────────────────┐
                          │       1. L1_EVAL          │
                          └─────────────┬─────────────┘
                                        │
                         Hit (Valid)    │   Miss / Expired
                   ┌────────────────────┴────────────────────┐
                   ▼                                         ▼
        ┌──────────────────────┐                  ┌──────────────────────┐
        │   2. XFETCH_CHECK    │                  │      3. L2_EVAL      │
        └──────────┬───────────┘                  └──────────┬───────────┘
                   │                                         │
        Threshold  │  Threshold                   Hit        │  Miss
        Exceeded   │  Normal                ┌────────────────┴────────────────┐
                   ▼       │                ▼                                 ▼
         ┌───────────────┐ │     ┌──────────────────────┐          ┌──────────────────────┐
         │ 4. ASYNC_WARM │ │     │    L1_POPULATE &     │          │  5. SINGLEFLIGHT_IN  │
         │ (Mutex Latch) │ │     │      RETURN_L2       │          │   (Coalesce Group)   │
         └───────────────┘ │     └──────────────────────┘          └──────────┬───────────┘
                   │       │                                                  │
                   ▼       ▼                                                  │ Leader Computes
            [RETURN_VALUE] ◀──────────────────────────────────────────────────┴───────┐
                   ▲                                                                  │
                   │                                                                  ▼
                   │                                                       ┌──────────────────────┐
                   │                                                       │  6. DB_COMPUTE &     │
                   │                                                       │   MULTICAST_INVALID  │
                   │                                                       └──────────┬───────────┘
                   │                                                                  │
                   └────────────────── Cache Write & Singleflight Broadcast ──────────┘
```

### State Transition Invariants:
1. `L1_EVAL`: Inspect in-process LRU cache. Memory access overhead is bounded by $t_{\text{l1}} \le 0.05\text{ms}$. If hit and not expired, transition to `XFETCH_CHECK`. If miss or expired, transition to `L2_EVAL`.
2. `XFETCH_CHECK`: Evaluate Vitter's probabilistic inequality $- \beta \cdot \delta \ln(U) > \Delta t_{\text{ttl}}$. If false, return cached value immediately. If true, spawn background `ASYNC_WARM` task under a non-blocking Redis `SET NX` mutex, returning the current cached value to caller with zero latency overhead.
3. `L2_EVAL`: Check shared Redis cache. If hit, parse entry, populate local L1 tier, and return. If miss, transition to `SINGLEFLIGHT_IN`.
4. `ASYNC_WARM`: Background worker recomputes authoritative state, writes updated value and delta to L2, refreshes local L1, broadcasts invalidation frame, and releases mutex.
5. `SINGLEFLIGHT_IN`: Enqueue request into `SingleflightGroup`. If an in-flight computation is active, caller suspends execution and subscribes to the leader promise. If caller is the leader, transition to `DB_COMPUTE`.
6. `DB_COMPUTE & MULTICAST_INVALID`: Leader executes backend query, records measured duration $\delta$, calculates decorrelated jittered TTL, persists entry to L2 Redis, populates local L1, broadcasts completion to all waiting singleflight callers, and emits invalidation payload to peer nodes.

---

## 5. Machine-Verifiable Definition of Done (DoD) Matrix

All caching layers, database read-through wrappers, and LLM memoization engines created by autonomous agents MUST satisfy the 6-gate machine-verifiable verification matrix before pull request merge:

| Gate | Category | Verification Harness | Pass Criterion |
| :--- | :--- | :--- | :--- |
| **Gate 0** | **Singleflight Coalescing** | Concurrency Burst Test ($N=100$) | Under 100 simultaneous concurrent calls for an uncached key, the upstream computation mock MUST be invoked exactly **1 time** ($N_{\text{exec}} \equiv 1$). |
| **Gate 1** | **XFetch Probabilistic Refresh**| Continuous Read Simulation | Hot keys under steady load MUST refresh in the background before hard expiry without a single cache miss or read latency spike ($P(\text{miss}) \equiv 0$). |
| **Gate 2** | **Decorrelated TTL Jitter** | Statistical Variance Check | Over $M=1000$ generated TTL values, the standard deviation $\sigma > 0$ and min/max span MUST cover at least $\pm 10\%$ of base TTL. |
| **Gate 3** | **Negative Sentinel Defense** | Cache Penetration Stress Test | Querying 500 non-existent keys repeatedly MUST result in zero database hits after the initial query ($N_{\text{db\_queries}} \le 500$). |
| **Gate 4** | **Multi-Tier Invalidation Bus** | Multi-Replica Pub/Sub Test | Mutating a key on Replica A MUST evict the key from Replica B's in-memory L1 cache within $\Delta t \le 20\text{ms}$. |
| **Gate 5** | **Context Cancellation Safety** | Client Disconnect Interruption | When a waiting singleflight caller aborts its request via context cancellation or timeout, upstream execution MUST NOT crash, and remaining callers MUST receive valid results. |

---

## 6. Cross-Language Production Invariants

### 6.1 Go Production Invariants (`singleflight.Group`, `DoChan` & Jittered Redis)
- ❌ **Anti-Pattern: Blind Mutex Contention or Uncoalesced Goroutine Floods**: Launching raw goroutines that simultaneously query PostgreSQL on cache miss, or locking a global `sync.Mutex` during heavy I/O, stalling all concurrent HTTP requests.
- ✅ **Production Invariant**: Use `golang.org/x/sync/singleflight` with `Group.DoChan` to support caller context cancellation without interrupting in-flight cache population:
  ```go
  // Industrial Go Singleflight & Decorrelated Jitter Caching
  type CacheService struct {
      redisClient *redis.Client
      db          *sql.DB
      sfGroup     singleflight.Group
  }

  func (s *CacheService) GetUserProfile(ctx context.Context, userID string) (*UserProfile, error) {
      cacheKey := fmt.Sprintf("user:%s", userID)

      // 1. Check Redis Cache
      val, err := s.redisClient.Get(ctx, cacheKey).Result()
      if err == nil {
          var profile UserProfile
          if val == "__NULL__" {
              return nil, ErrNotFound // Negative sentinel hit
          }
          if json.Unmarshal([]byte(val), &profile) == nil {
              return &profile, nil
          }
      }

      // 2. Coalesce concurrent requests via singleflight with Context Cancellation
      ch := s.sfGroup.DoChan(cacheKey, func() (interface{}, error) {
          // Dedicated timeout context for upstream compute
          computeCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
          defer cancel()

          profile, err := s.queryDatabase(computeCtx, userID)
          if errors.Is(err, sql.ErrNoRows) {
              // Cache negative sentinel for 60s
              s.redisClient.Set(computeCtx, cacheKey, "__NULL__", 60*time.Second)
              return nil, ErrNotFound
          }
          if err != nil {
              return nil, err
          }

          // Decorrelated TTL Jitter: 1 hour +/- 15%
          jitter := time.Duration(rand.Intn(18)-9) * time.Minute
          ttl := 60*time.Minute + jitter

          data, _ := json.Marshal(profile)
          s.redisClient.Set(computeCtx, cacheKey, data, ttl)
          return profile, nil
      })

      select {
      case <-ctx.Done():
          return nil, ctx.Err() // Caller canceled, but singleflight worker completes in background
      case res := <-ch:
          if res.Err != nil {
              return nil, res.Err
          }
          if res.Val == nil {
              return nil, ErrNotFound
          }
          return res.Val.(*UserProfile), nil
      }
  }
  ```

### 6.2 PostgreSQL / Database Invariants (CDC Invalidation & Negative Sentinel Tables)
- ❌ **Anti-Pattern: Unconditional Query Thundering on Cold Replicas**: Allowing cold database read replicas to receive un-throttled query stampedes on service restarts without cache pre-warming.
- ✅ **Production Invariant**: Drive cache invalidations asynchronously from PostgreSQL Transaction Logs (CDC via Debezium or PostgreSQL `pg_logical`) rather than unpredictable application-side dual-writes:
  ```sql
  -- PostgreSQL Cache Invalidation CDC Table & Keyset-Warming Support
  CREATE TABLE IF NOT EXISTS cache_invalidation_events (
      invalidation_id BIGSERIAL PRIMARY KEY,
      cache_namespace VARCHAR(64) NOT NULL,
      cache_key VARCHAR(255) NOT NULL,
      entity_epoch BIGINT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );

  CREATE INDEX IF NOT EXISTS idx_cache_inv_stream 
    ON cache_invalidation_events (invalidation_id ASC);

  -- Trigger automatically publishing invalidation on entity row update
  CREATE OR REPLACE FUNCTION notify_cache_invalidation() RETURNS TRIGGER AS $$
  BEGIN
      INSERT INTO cache_invalidation_events (cache_namespace, cache_key, entity_epoch)
      VALUES (TG_TABLE_NAME, CONCAT(TG_TABLE_NAME, ':', NEW.id::text), EXTRACT(EPOCH FROM NOW())::BIGINT);
      RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;
  ```

### 6.3 MCP Server Production Invariants (Memoized Tool Calling with Singleflight Deduplication)
- ❌ **Anti-Pattern: Duplicate Expensive Tool Invocations Across Sub-Agents**: When autonomous agent swarms (Claude Code, Cursor Composer, Pi) invoke identical read-only tools concurrently (e.g. `ast_search`, `read_large_file`, `git_log`), executing redundant I/O and parsing operations.
- ✅ **Production Invariant**: Implement in-process singleflight deduplication on MCP tool dispatchers to return coalesced tool results:
  ```typescript
  // Industrial MCP Tool Coalescing Middleware
  const toolSingleflight = new SingleflightGroup<any>();

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    
    // Only coalesce idempotent read-only tool operations
    if (isReadOnlyTool(name)) {
      const callSignature = `${name}:${crypto.createHash('sha256').update(JSON.stringify(args ?? {})).digest('hex')}`;
      
      const { result } = await toolSingleflight.do(callSignature, async () => {
        return await executeActualTool(name, args);
      });

      return { content: [{ type: 'text', text: JSON.stringify(result) }] };
    }

    // Mutating tools bypass singleflight deduplication
    const result = await executeActualTool(name, args);
    return { content: [{ type: 'text', text: JSON.stringify(result) }] };
  });
  ```

### 6.4 SvelteKit Production Invariants (SSR L1 In-Process Cache & Client SWR)
- ❌ **Anti-Pattern: Server-Side Request Stampede on SSR Mount**: SvelteKit `load` functions performing identical database queries on every simultaneous page request during high-traffic campaigns.
- ✅ **Production Invariant**: Wrap SSR data queries in a shared in-memory singleflight cache with `stale-while-revalidate` headers:
  ```typescript
  // src/routes/catalog/[id]/+page.server.ts - SvelteKit Resilient Read-Through
  import type { PageServerLoad } from './$types';
  import { multiTierCache } from '$lib/server/cache';

  export const load: PageServerLoad = async ({ params, setHeaders }) => {
    const product = await multiTierCache.getOrCompute(`product:${params.id}`, async () => {
      return await db.product.findUnique({ where: { id: params.id } });
    }, 300);

    setHeaders({
      'cache-control': 'public, max-age=60, s-maxage=300, stale-while-revalidate=600'
    });

    return { product };
  };
  ```

### 6.5 Vue / Nuxt Production Invariants (Nitro Multi-Tier Driver & `useCoalescedFetch`)
- ❌ **Anti-Pattern: Un-Deduplicated Parallel Component Fetches**: Multiple child Vue components simultaneously calling `useFetch('/api/settings')` on initial render, firing duplicate network requests.
- ✅ **Production Invariant**: Provide a coalesced client composable that shares active request promises across component lifecycles:
  ```typescript
  // composables/useCoalescedFetch.ts - Vue 3 / Nuxt Request Coalescing Composable
  const clientInFlight = new Map<string, Promise<any>>();

  export function useCoalescedFetch<T>(url: string, opts?: any) {
    if (clientInFlight.has(url)) {
      return { data: fromPromise<T>(clientInFlight.get(url)!), pending: ref(true) };
    }

    const promise = $fetch<T>(url, opts).finally(() => {
      clientInFlight.delete(url);
    });

    clientInFlight.set(url, promise);
    return useAsyncData<T>(url, () => promise);
  }
  ```
