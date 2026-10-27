---
description: Agentic distributed locking, mutual exclusion guarantees, Martin Kleppmann fencing tokens, lease renewal watchdogs, cycle-free lock ordering, and deadlock prevention across Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{lock,mutex,fencing,lease,concurrency,semaphore,distributed,redlock}*.*,**/services/**/*.{ts,js,py,go},**/workers/**/*.{ts,js,py,go},**/infrastructure/**/*.{ts,js,py,go},**/concurrency/**/*.{ts,js,py,go}
alwaysApply: false
---

# Agentic Distributed Locking, Concurrency Fencing & Deadlock Prevention Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design distributed workers, leader election routines, cluster schedulers, multi-resource atomic workflows, or shared resource mutation gates across Redis, PostgreSQL, or etcd. Eliminate the "Lease Expiry Ghost Mutation" (The Kleppmann Trap, where un-fenced workers wake from GC pauses to corrupt storage), the "Deadlock Cyclic Lock Acquisition Trap" (where concurrent workers lock multiple resources in non-deterministic order), the "Asynchronous Split-Brain Lock Release Vulnerability" (where expired workers delete subsequent owners' locks), the "Missing Heartbeat Watchdog Pitfall" (where long tasks lose mutual exclusion mid-flight), and "Thundering Herd Spinning Stampedes" by establishing a strict 5-Tier Distributed Concurrency Ladder, monotonic fencing token calculus, canonical topological resource ordering, atomic Lua CAS primitives, and background heartbeat watchdogs.

---

## 1. Architectural Taxonomy: The 5 Concurrency Catastrophes vs The 5-Tier Distributed Concurrency Ladder

When autonomous agents are instructed to "synchronize background workers", "prevent concurrent task execution", or "acquire a lock across multiple resources", LLMs almost universally generate naive lock-unlock wrappers (`redis.set("lock", "1", "EX", 10)` followed by `redis.del("lock")`). In distributed systems, this creates five catastrophic production failure modes:

- **The "Lease Expiry Ghost Mutation" (The Kleppmann Trap)**:
  - An autonomous agent provisions a Redis lock with a 10-second TTL.
  - A long Stop-the-World garbage collection (GC) pause, unindexed slow database query, paging swap event, or network hiccup delays worker Node 1 for 12 seconds.
  - Meanwhile, the Redis TTL expires at $t=10\text{s}$. Node 2 queries Redis, successfully acquires the newly freed lock, and begins mutating shared storage.
  - At $t=12\text{s}$, Node 1 awakens from its pause, completely oblivious that its lease has expired, and executes its pending storage write.
  - Result: Node 1 overwrites Node 2's mutations, causing silent, irreversible data corruption in customer ledgers, inventory tables, or file stores. Without **monotonic fencing tokens** verified at the storage engine boundary (`WHERE fencing_token < :token`), distributed locks cannot guarantee mutual exclusion!
- **The "Deadlock Cyclic Acquisition Catastrophe"**:
  - When agents orchestrate multi-resource workflows (e.g., balance transfers between Account A and Account B, or multi-item order reservations), they acquire locks in arbitrary order:
    - Worker 1 processes transfer A $\to$ B: locks A, attempts to lock B.
    - Worker 2 processes transfer B $\to$ A: locks B, attempts to lock A.
  - Neither worker can proceed. Both hold resources desired by the other. The Wait-For Graph contains a directed cycle: $W_1 \to R_B \to W_2 \to R_A \to W_1$. The entire worker pool deadlocks, exhausting thread pools and starving system traffic.
- **The "Asynchronous Split-Brain Lock Release / Unowned Unlock Vulnerability"**:
  - Naive agent code wraps execution in standard try/finally or defer blocks:
    ```typescript
    // ❌ CATASTROPHIC UNCHECKED RELEASE ANTI-PATTERN
    await redis.set(`lock:${resource}`, '1', 'EX', 10);
    try {
      await processData();
    } finally {
      await redis.del(`lock:${resource}`); // BUG: Deletes another node's lock!
    }
    ```
  - If `processData()` takes 11 seconds, the lock expires at 10 seconds and is acquired by another server pod.
  - The first worker finishes and hits `finally`, executing `DEL lock:resource`. It deletes the *second worker's* valid, active lock.
  - A third worker now acquires the lock. Multiple workers are now executing concurrently, cascading mutual exclusion collapse across the entire cluster.
- **The "Amnesiac Single-Master Replication Fallacy (Redlock vs Consensus)"**:
  - Unconstrained agents rely on single-node Redis instances or asynchronous Redis master-replica pairs for mission-critical distributed locks.
  - In standard Redis replication, `SET` commands are replicated asynchronously. If the master crashes and fails over to a replica before the key replicates, the lock disappears on the new master. Two nodes concurrently obtain the "exclusive" lock.
  - Production architectures requiring absolute safety must utilize monotonic consensus engines (Raft, etcd, ZooKeeper) or multi-master Redlock with strict clock drift deductions.
- **The "Thundering Herd Spinning Stampede & Unjittered Retry Collapse"**:
  - Agents implement lock contention via tight while-loops with constant sleeps:
    ```typescript
    // ❌ SYNCHRONIZED SPINNING STAMPEDE
    while (!(await tryLock(key))) {
      await sleep(100); // Thousands of workers synchronize retry pulses!
    }
    ```
  - When the lock holder releases the key, hundreds of contending workers awaken at the exact same millisecond, slamming Redis with concurrent `SET NX` commands, exhausting Redis connection sockets and CPU cores.
- **The 5-Tier Distributed Concurrency Ladder**:
  - Autonomous agents must strictly adhere to 5 ascending architectural tiers to guarantee distributed safety:
    - **Tier 0: Canonical Topological Resource Ordering**: When acquiring multiple locks, keys MUST be sorted lexicographically ($\text{sort}(K_1, K_2, \dots, K_n)$) before sequential acquisition to mathematically guarantee cycle-free wait graphs.
    - **Tier 1: Cryptographic Nonce & Atomic Lua CAS Release**: Every lock acquisition MUST generate a unique cryptographic nonce (UUIDv7 or high-entropy random token). Locks MUST only be released via atomic Lua Compare-And-Swap (CAS) scripts verifying ownership.
    - **Tier 2: Monotonic Fencing Tokens ($\theta_{\text{fence}}$)**: Lock acquisitions MUST generate a monotonically increasing integer token ($1, 2, 3, \dots$). The backing storage engine (SQL, document store, S3) MUST verify and store the fencing token on every write (`WHERE fencing_token < :token`), rejecting delayed ghost writes.
    - **Tier 3: Asynchronous Heartbeat Watchdogs (Lease Auto-Renewal)**: Long-running processes MUST spawn a non-blocking background heartbeat timer that extends lock TTL at $\frac{1}{3}\tau_{\text{ttl}}$ intervals while the worker is actively alive. If heartbeat renewal fails, the worker's execution context (`AbortSignal` / `context.Context`) MUST be cancelled immediately.
    - **Tier 4: Jittered Truncated Exponential Backoff & Contention Telemetry**: Retries MUST use decorrelated full jitter ($t = \min(t_{\text{max}}, t_{\text{base}} \times 2^i) \pm \text{rand}$) with Prometheus/OpenTelemetry lock acquisition metrics exported to observability backends.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Autonomous Agent Requests Distributed Lock Acquisition (Single or Multi-Resource)               │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Tier 0: Canonical Topological Resource Ordering                                                  │
│ Sort multi-resource lock keys: [res_order_1, res_account_2] -> Deterministic lexical order       │
│ Graph-Theoretic Cycle Elimination: Prevents cyclic wait-for deadlocks across concurrent nodes     │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Tier 1: Cryptographic Nonce & Atomic Acquisition                                                 │
│ Generate UUIDv7 ownerNonce. Issue atomic Redis SET resource ownerNonce NX PX 10000               │
│ Acquisition failed? -> Apply Tier 4 Jittered Truncated Exponential Backoff retry                 │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Tier 2: Monotonic Fencing Token Generation (theta_fence)                                         │
│ Increment global fence sequence (Redis INCR / SQL sequence / Raft log index)                     │
│ Pass theta_fence to domain worker context. Storage layer enforces: WHERE fencing_token < :theta  │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Tier 3: Asynchronous Heartbeat Watchdog Daemon                                                   │
│ Spawn background timer extending TTL at interval = TTL / 3 while worker is active                │
│ Heartbeat failed or network partitioned? -> Immediately trigger AbortSignal / context cancel!    │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Critical Section Work Execution -> Storage Mutation Guarded by Monotonic Fencing Token          │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Tier 1 Release: Atomic Compare-And-Swap (CAS) Lua Script                                         │
│ redis.call('get', KEYS[1]) == ARGV[1] -> redis.call('del', KEYS[1])                              │
│ Teardown watchdog daemon. Never delete locks held by subsequent owners!                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical & Formal Invariant Calculus

### 2.1 The Kleppmann Storage Invariant: Mutual Exclusion Across Lease Expiry

Let a distributed lock lease have duration $\tau_{\text{ttl}}$. Let $t_{\text{acq}}$ be the timestamp when the lock service grants the lease. Let $t_{\text{commit}}$ be the timestamp when the worker commits its state mutation to persistent storage.

Under pure lease-based distributed locks without fencing, mutual exclusion holds if and only if:

$$t_{\text{commit}} < t_{\text{acq}} + \tau_{\text{ttl}} - \Delta t_{\text{drift}}$$

where $\Delta t_{\text{drift}}$ accounts for clock skew and network transit time. In real-world distributed systems, process pauses (Stop-the-World GC, hypervisor CPU throttling, disk I/O stalls) can introduce an arbitrary delay $\delta_{\text{pause}} \ge 0$ such that:

$$t_{\text{commit}} = t_{\text{acq}} + \delta_{\text{work}} + \delta_{\text{pause}} > t_{\text{acq}} + \tau_{\text{ttl}}$$

When this condition occurs, another node $B$ is granted the lock at $t_B > t_{\text{acq}} + \tau_{\text{ttl}}$. If node $A$ commits after node $B$, mutual exclusion is violated.

**The Kleppmann Storage Invariant**: Storage engines MUST enforce a strict monotonic ordering check on all write operations guarded by distributed locks:

$$\forall \text{ Write } W(\text{state}, \theta) : \theta > \max_{\text{committed}} (\theta_{\text{stored}})$$

If a write arrives with fencing token $\theta \le \theta_{\text{stored}}$, the write MUST be rejected atomically with a concurrency serialization error (`409 Conflict` / `FencingTokenRejectedException`).

### 2.2 Graph-Theoretic Cycle Elimination (Coffman Conditions & Total Order)

A distributed deadlock occurs if and only if the four Coffman conditions hold simultaneously:
1. Mutual Exclusion: Resources cannot be shared.
2. Hold and Wait: Workers hold resources while requesting new ones.
3. No Preemption: Resources cannot be forcibly revoked.
4. Circular Wait: A closed loop exists in the Resource Allocation Graph $G = (V, E)$.

Let $\mathcal{R} = \{r_1, r_2, \dots, r_n\}$ be the universal set of all resources. Define a strict total ordering $\prec$ over $\mathcal{R}$ such that:

$$\forall r_i, r_j \in \mathcal{R} \quad (r_i \neq r_j) \implies (r_i \prec r_j \lor r_j \prec r_i)$$

**Theorem (Deadlock-Free Lock Hierarchy)**: If every worker acquires multiple resources in ascending order according to $\prec$ (i.e., acquiring $r_b$ while holding $r_a$ is permitted only if $r_a \prec r_b$), the Resource Allocation Graph $G = (V, E)$ is a Directed Acyclic Graph (DAG) and contains zero cycles:

$$\text{Cycles}(G) \equiv \emptyset \implies \mathbb{P}(\text{Deadlock}) = 0$$

Autonomous agents MUST sort all multi-resource lock keys lexicographically prior to acquisition.

### 2.3 Redlock Validity & Clock Drift Formula

When acquiring a lock across $N$ independent master nodes, the lock is acquired if and only if:
1. The client acquires the lock in a majority of nodes: $M \ge \lfloor \frac{N}{2} \rfloor + 1$.
2. The total time elapsed during acquisition $\tau_{\text{elapsed}} = t_{\text{end}} - t_{\text{start}}$ is less than total validity time.

The effective validity time $T_{\text{validity}}$ of the lock is:

$$T_{\text{validity}} = \tau_{\text{ttl}} - \tau_{\text{elapsed}} - \Delta t_{\text{drift}}$$

where clock drift $\Delta t_{\text{drift}} = (\tau_{\text{ttl}} \times \alpha) + \epsilon_{\text{ntp}}$ (with typical clock drift factor $\alpha = 0.01$ and NTP sync variance $\epsilon_{\text{ntp}} = 2\text{ms}$). If $T_{\text{validity}} \le 0$ or majority is not achieved, the client MUST immediately unlock all instances and retry.

### 2.4 Decorrelated Exponential Jitter Distribution

When contending for a contested lock, fixed backoff intervals cause harmonic retry collisions. Workers MUST use Decorrelated Full Jitter to maximize distribution entropy:

$$t_{k+1} = \min(t_{\text{max}}, \text{Uniform}(t_{\text{base}}, t_k \times 3))$$

where $t_{\text{base}}$ is initial backoff (e.g., $50\text{ms}$), $t_{\text{max}}$ is the ceiling (e.g., $2000\text{ms}$), and $t_k$ is the previous sleep duration.

---

## 3. Multi-Language Production Invariants & Code Patterns

### 3.1 Go: Monotonic Fencing Tokens, Atomic Lua Release & Watchdog Goroutine

```go
package lock

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"
)

// Atomic Compare-And-Swap Lua script: releases lock ONLY if nonce matches.
var releaseLuaScript = redis.NewScript(`
	if redis.call("get", KEYS[1]) == ARGV[1] then
		return redis.call("del", KEYS[1])
	else
		return 0
	end
`)

// Atomic Heartbeat renewal Lua script: extends TTL ONLY if nonce matches.
var renewLuaScript = redis.NewScript(`
	if redis.call("get", KEYS[1]) == ARGV[1] then
		return redis.call("pexpire", KEYS[1], ARGV[2])
	else
		return 0
	end
`)

var (
	ErrLockAcquisitionFailed = errors.New("failed to acquire distributed lock within timeout")
	ErrLockLostDuringWork    = errors.New("distributed lock lost or heartbeat renewal failed")
)

type DistributedLockManager struct {
	client     *redis.Client
	fenceSeq   atomic.Uint64
}

func NewDistributedLockManager(client *redis.Client) *DistributedLockManager {
	return &DistributedLockManager{client: client}
}

// Generate cryptographic owner nonce
func generateNonce() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// WithLock executes fn within an exclusive distributed lock protected by a monotonic fencing token and watchdog.
func (m *DistributedLockManager) WithLock(
	ctx context.Context,
	resourceKey string,
	ttl time.Duration,
	fn func(workCtx context.Context, fenceToken uint64) error,
) error {
	nonce := generateNonce()
	lockKey := fmt.Sprintf("lock:%s", resourceKey)

	// Tier 1: Atomic Acquisition
	acquired, err := m.client.SetNX(ctx, lockKey, nonce, ttl).Result()
	if err != nil {
		return fmt.Errorf("redis setnx error: %w", err)
	}
	if !acquired {
		return ErrLockAcquisitionFailed
	}

	// Tier 2: Monotonic Fencing Token (Redis INCR for global cluster monotonicity)
	fenceToken, err := m.client.Incr(ctx, "seq:fence:distributed").Result()
	if err != nil {
		// Rollback lock on sequence failure
		_ = releaseLuaScript.Run(ctx, m.client, []string{lockKey}, nonce)
		return fmt.Errorf("failed to generate fencing token: %w", err)
	}

	// Tier 3: Watchdog Context with Auto-Renewal
	workCtx, cancelWork := context.WithCancel(ctx)
	defer cancelWork()

	var wg sync.WaitGroup
	stopWatchdog := make(chan struct{})
	watchdogErr := make(chan error, 1)

	wg.Add(1)
	go func() {
		defer wg.Done()
		ticker := time.NewTicker(ttl / 3)
		defer ticker.Stop()

		for {
			select {
			case <-stopWatchdog:
				return
			case <-ticker.C:
				res, err := renewLuaScript.Run(ctx, m.client, []string{lockKey}, nonce, int(ttl.Milliseconds())).Result()
				if err != nil || res.(int64) == 0 {
					// Lock lost or network partition! Cancel work context immediately.
					cancelWork()
					watchdogErr <- ErrLockLostDuringWork
					return
				}
			}
		}
	}()

	// Execute critical section
	workErr := fn(workCtx, uint64(fenceToken))

	// Teardown Watchdog
	close(stopWatchdog)
	wg.Wait()

	// Tier 1: Atomic CAS Release
	releaseCtx, releaseCancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer releaseCancel()
	_, _ = releaseLuaScript.Run(releaseCtx, m.client, []string{lockKey}, nonce)

	if workErr != nil {
		return workErr
	}
	select {
	case err := <-watchdogErr:
		return err
	default:
		return nil
	}
}

// AcquireMultiLock guarantees cycle-free deadlock prevention via canonical sorting.
func (m *DistributedLockManager) AcquireMultiLock(ctx context.Context, resources []string, ttl time.Duration) ([]string, string, error) {
	// Tier 0: Canonical Topological Resource Ordering
	sorted := make([]string, len(resources))
	copy(sorted, resources)
	sort.Strings(sorted) // Deterministic ascending lexicographical order

	nonce := generateNonce()
	acquiredKeys := make([]string, 0, len(sorted))

	for _, res := range sorted {
		lockKey := fmt.Sprintf("lock:%s", res)
		ok, err := m.client.SetNX(ctx, lockKey, nonce, ttl).Result()
		if err != nil || !ok {
			// Rollback previously acquired locks in reverse order
			for i := len(acquiredKeys) - 1; i >= 0; i-- {
				_ = releaseLuaScript.Run(ctx, m.client, []string{acquiredKeys[i]}, nonce)
			}
			return nil, "", ErrLockAcquisitionFailed
		}
		acquiredKeys = append(acquiredKeys, lockKey)
	}

	return acquiredKeys, nonce, nil
}
```

### 3.2 SQL / PostgreSQL: Advisory Locks with Deterministic Sorting & Monotonic Storage Fencing

```sql
-- 1. Storage Table with Monotonic Fencing Token Protection
CREATE TABLE bank_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_number VARCHAR(32) NOT NULL UNIQUE,
    balance NUMERIC(18, 4) NOT NULL CHECK (balance >= 0),
    fencing_token BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Monotonic Fencing Token Update Mutation (Rejects Stale Delayed Writes)
-- If a delayed worker awakens and attempts to apply an outdated token, 0 rows are updated!
UPDATE bank_accounts
SET balance = balance - 100.00,
    fencing_token = :worker_fence_token,
    updated_at = NOW()
WHERE id = :target_account_id
  AND fencing_token < :worker_fence_token; -- Absolute storage fence invariant!

-- In application code (Go/TypeScript):
-- If RowsAffected == 0, THROW FencingConflictException("Delayed write rejected: storage has advanced").

-- 3. Deadlock-Free PostgreSQL Multi-Resource Advisory Lock Acquisition
-- When locking accounts A and B, ALWAYS order by hashed ID to eliminate circular wait deadlocks:
BEGIN;

-- Sort IDs lexicographically before locking:
-- Suppose accounts are 'acc_xyz' and 'acc_abc'. Sorted order is 'acc_abc', then 'acc_xyz'.
SELECT pg_advisory_xact_lock(hashtext('acc_abc'));
SELECT pg_advisory_xact_lock(hashtext('acc_xyz'));

-- Execute safe financial mutations here...
COMMIT; -- Transaction commit automatically releases all advisory locks atomically!
```

---

## 4. Complete Production-Ready TypeScript Engine: `AgenticDistributedLockEngine`

```typescript
import { createHash, randomUUID } from 'node:crypto';

export interface RedisCompatibleClient {
  set(key: string, value: string, mode: 'PX', ttl: number, flag: 'NX'): Promise<'OK' | null>;
  get(key: string): Promise<string | null>;
  incr(key: string): Promise<number>;
  eval(script: string, numkeys: number, ...args: (string | number)[]): Promise<any>;
}

export interface LockAcquisitionOptions {
  ttlMs?: number;
  timeoutMs?: number;
  baseRetryDelayMs?: number;
  maxRetryDelayMs?: number;
  enableWatchdog?: boolean;
}

export interface LockHandle {
  resource: string;
  nonce: string;
  fenceToken: number;
  ttlMs: number;
  signal: AbortSignal;
  release(): Promise<boolean>;
}

export class AgenticDistributedLockEngine {
  private static readonly RELEASE_LUA = `
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
  `;

  private static readonly RENEW_LUA = `
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("pexpire", KEYS[1], ARGV[2])
    else
      return 0
    end
  `;

  private readonly client: RedisCompatibleClient;
  private readonly defaultTtlMs: number;
  private readonly globalFenceKey: string;

  constructor(client: RedisCompatibleClient, defaultTtlMs = 10000, globalFenceKey = 'seq:distributed:fence') {
    this.client = client;
    this.defaultTtlMs = defaultTtlMs;
    this.globalFenceKey = globalFenceKey;
  }

  /**
   * Acquire a distributed lock with monotonic fencing token and auto-renewal watchdog.
   */
  public async acquire(
    resource: string,
    options: LockAcquisitionOptions = {}
  ): Promise<LockHandle> {
    const ttlMs = options.ttlMs ?? this.defaultTtlMs;
    const timeoutMs = options.timeoutMs ?? 5000;
    const baseRetry = options.baseRetryDelayMs ?? 50;
    const maxRetry = options.maxRetryDelayMs ?? 1000;
    const enableWatchdog = options.enableWatchdog ?? true;

    const lockKey = `lock:${resource}`;
    const nonce = randomUUID();
    const startTime = Date.now();
    let attempt = 0;
    let currentDelay = baseRetry;

    // Retry loop with Decorrelated Full Jitter
    while (Date.now() - startTime < timeoutMs) {
      attempt++;
      const result = await this.client.set(lockKey, nonce, 'PX', ttlMs, 'NX');

      if (result === 'OK') {
        // Tier 2: Monotonic Fencing Token Generation
        const fenceToken = await this.client.incr(this.globalFenceKey);

        const abortController = new AbortController();
        let watchdogTimer: NodeJS.Timeout | null = null;
        let isReleased = false;

        // Tier 3: Heartbeat Auto-Renewal Watchdog
        if (enableWatchdog) {
          const renewInterval = Math.max(100, Math.floor(ttlMs / 3));
          watchdogTimer = setInterval(async () => {
            if (isReleased) {
              if (watchdogTimer) clearInterval(watchdogTimer);
              return;
            }
            try {
              const renewed = await this.client.eval(
                AgenticDistributedLockEngine.RENEW_LUA,
                1,
                lockKey,
                nonce,
                ttlMs
              );
              if (renewed !== 1) {
                // Lock was lost or stolen! Abort critical section immediately
                if (watchdogTimer) clearInterval(watchdogTimer);
                abortController.abort(new Error(`Distributed lock for '${resource}' lost during execution`));
              }
            } catch (err) {
              if (watchdogTimer) clearInterval(watchdogTimer);
              abortController.abort(err);
            }
          }, renewInterval);
          // Unref timer so it does not hold the Node process open
          if (typeof watchdogTimer.unref === 'function') {
            watchdogTimer.unref();
          }
        }

        const release = async (): Promise<boolean> => {
          if (isReleased) return false;
          isReleased = true;
          if (watchdogTimer) clearInterval(watchdogTimer);

          // Tier 1: Atomic CAS Lua Release
          const res = await this.client.eval(
            AgenticDistributedLockEngine.RELEASE_LUA,
            1,
            lockKey,
            nonce
          );
          return res === 1;
        };

        return {
          resource,
          nonce,
          fenceToken,
          ttlMs,
          signal: abortController.signal,
          release,
        };
      }

      // Tier 4: Decorrelated Jitter Backoff
      const jitter = Math.floor(Math.random() * currentDelay);
      const sleepTime = Math.min(maxRetry, currentDelay + jitter);
      currentDelay = Math.min(maxRetry, Math.floor(currentDelay * 1.5));

      const remainingTime = timeoutMs - (Date.now() - startTime);
      if (remainingTime <= 0) break;
      await new Promise((resolve) => setTimeout(resolve, Math.min(sleepTime, remainingTime)));
    }

    throw new Error(
      `Failed to acquire distributed lock for '${resource}' within ${timeoutMs}ms (${attempt} attempts)`
    );
  }

  /**
   * Acquire locks over multiple resources in cycle-free canonical order.
   */
  public async acquireMulti(
    resources: string[],
    options: LockAcquisitionOptions = {}
  ): Promise<{ handles: LockHandle[]; fenceToken: number; releaseAll(): Promise<void> }> {
    // Tier 0: Canonical Topological Resource Ordering
    // Remove duplicates and sort lexicographically
    const uniqueSorted = Array.from(new Set(resources)).sort();
    const handles: LockHandle[] = [];

    try {
      for (const res of uniqueSorted) {
        const handle = await this.acquire(res, options);
        handles.push(handle);
      }

      // Max fence token among all locks governs the aggregate multi-mutation
      const fenceToken = Math.max(...handles.map((h) => h.fenceToken));

      const releaseAll = async () => {
        // Release in reverse acquisition order
        for (let i = handles.length - 1; i >= 0; i--) {
          try {
            await handles[i].release();
          } catch {
            // Best effort release of remaining locks
          }
        }
      };

      return { handles, fenceToken, releaseAll };
    } catch (err) {
      // Rollback already acquired locks
      for (let i = handles.length - 1; i >= 0; i--) {
        try {
          await handles[i].release();
        } catch {
          // Swallow rollback error
        }
      }
      throw err;
    }
  }

  /**
   * Execute task inside an exclusive distributed lock with automatic release.
   */
  public async runWithLock<T>(
    resource: string,
    task: (fenceToken: number, signal: AbortSignal) => Promise<T>,
    options: LockAcquisitionOptions = {}
  ): Promise<T> {
    const lock = await this.acquire(resource, options);
    try {
      return await task(lock.fenceToken, lock.signal);
    } finally {
      await lock.release();
    }
  }
}
```

---

## 5. The 6 Absolute Anti-Pattern Prohibitions

1. ❌ **TOTAL BAN ON BARE `DEL lock_key` WITHOUT NONCE VERIFICATION**:
   - Calling `redis.del(key)` inside `finally` or `defer` blocks without verifying that the lock value matches the caller's unique cryptographic nonce is strictly prohibited. If the lock expired and was acquired by another process, bare `DEL` unlocks the new owner's lock, destroying cluster mutual exclusion.
2. ❌ **TOTAL BAN ON UNORDERED MULTI-RESOURCE LOCK ACQUISITION**:
   - Acquiring multiple locks in the order they happen to appear in business payloads (e.g. `transfer(from, to) -> lock(from), lock(to)`) is strictly prohibited. All multi-resource locks MUST be sorted lexicographically prior to acquisition ($\text{sort}(K_1, \dots, K_n)$) to mathematically prevent cyclic deadlocks.
3. ❌ **TOTAL BAN ON TRUSTING DISTRIBUTED LOCKS WITHOUT STORAGE FENCING TOKENS**:
   - Assuming that distributed lock acquisition alone guarantees safe database mutation is strictly prohibited. Long GC pauses and network splits invalidate in-memory lock leases. Database mutations MUST check `WHERE fencing_token < :token` to reject delayed ghost writes.
4. ❌ **TOTAL BAN ON UNCONSTRAINED SPIN-LOCK LOOPS WITHOUT JITTER**:
   - Polling Redis in tight loops `while (!tryLock()) { sleep(100) }` without exponential backoff and randomized decorrelated jitter is strictly prohibited. Contending workers synchronize retry waves and collapse Redis CPU and network interfaces.
5. ❌ **TOTAL BAN ON HOLDING DISTRIBUTED LOCKS ACROSS EXTERNAL NETWORK EGRESS**:
   - Holding a distributed lock while invoking slow third-party HTTP APIs (e.g., calling Stripe, OpenAI, or external webhooks) is strictly prohibited. Network timeouts and socket hangs tie up critical cluster mutexes. External network calls MUST be completed before acquiring the lock or scheduled via outbox queues.
6. ❌ **TOTAL BAN ON SILENT HEARTBEAT AUTO-RENEWAL FAILURE**:
   - Swallowing lease renewal exceptions in background watchdog routines without cancelling the worker's execution context is strictly prohibited. When a watchdog fails to renew a lock, it MUST immediately trip the worker's `AbortSignal` or cancel its `context.Context` to halt execution before storage corruption occurs.

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Machine Verification Command | Pass Criteria |
|---|---|---|---|
| **Gate 1** | **CAS Lua Release Invariant** | `grep -rn "redis.del" . \| grep -v "eval" \| grep -i "lock"` | Zero instances of bare `DEL` calls on lock keys without CAS verification |
| **Gate 2** | **Topological Multi-Lock Sort** | AST inspector verifying all multi-resource lock acquisitions invoke `sort()` | $100\%$ of multi-lock routines sort keys lexicographically before acquisition |
| **Gate 3** | **Monotonic Storage Fence Guard** | `grep -rn "UPDATE" . \| grep -i "fencing_token"` | All lock-guarded SQL mutations assert `WHERE fencing_token < :token` |
| **Gate 4** | **Watchdog Auto-Renewal & Abort** | Unit test simulating 3x TTL execution duration with mock Redis | Lock lease extended automatically; context aborted if renewal fails |
| **Gate 5** | **Jittered Backoff Verification** | Property-based test asserting randomized sleep distribution | Zero constant-interval retry loops; retry intervals strictly jittered |
| **Gate 6** | **Deadlock Concurrency Stress** | Stress test running 100 concurrent workers shuffling 10 resources | Zero deadlocks observed across 1,000 iterations ($P(\text{deadlock}) \equiv 0$) |
