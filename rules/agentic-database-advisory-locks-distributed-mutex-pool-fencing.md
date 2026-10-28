---
description: PostgreSQL Advisory Locks, application-level mutexes, 64-bit hash namespaces, transaction-scoped fencing (pg_advisory_xact_lock), PgBouncer connection pooler leak elimination, canonical multi-resource ordering, and distributed leader election across Go (pgx/v5), TypeScript (Drizzle/Kysely/pg), Python (psycopg3/asyncpg), Rust (tokio-postgres/sqlx), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{advisory,lock,mutex,lease,leader,election,migration,singleflight,concurrency}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/src/services/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/internal/lock/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Advisory Locks, Application Leases, 64-Bit Hash Namespaces & Connection Pooler Fencing

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design application-level synchronization, distributed mutual exclusion, migration leader election, scheduled cron task deduplication, singleflight query caches, checkout double-spend prevention, or multi-tenant transactional fencing using PostgreSQL Advisory Locks, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `pg`), Python (`psycopg3`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Session-Mode Advisory Lock Leak in Transaction Poolers (PgBouncer/pgpool)" (where executing `pg_advisory_lock` in `pool_mode = transaction` holds locks on physical backend server connections after client queries return, mysteriously transferring locks to unrelated tenants and triggering untraceable cluster deadlocks), the "Missing Transaction-Scoped `pg_advisory_xact_lock` & Dangling Mutex on Worker Panic" (where worker crashes or OOM events leave session locks held indefinitely until DBA manual intervention), the "32-bit vs 64-bit Integer Hash Collision Catastrophe" (where agents naively hash strings into 32-bit ints or reuse raw entity IDs without namespace partitioning, causing completely unrelated business domains to block each other), the "Synchronous Blocking `pg_advisory_lock` Connection Pool Exhaustion Avalanche" (where waiting requests block pooled database connections indefinitely during slow external I/O, exhausting connection pools in milliseconds and triggering 504 gateway outages), the "Unfenced Cross-Tenant Resource Contention" (where multi-tenant databases lock raw entity IDs without tenant isolation, allowing Tenant A's batch payout to lock Tenant B's checkout), and the "Non-Canonical Lock Acquisition AB-BA Deadlock Spasm" (where acquiring multiple advisory locks in un-sorted order causes circular wait-for graph deadlocks) by establishing a strict 5-Tier Advisory Lock Governance Ladder, deterministic 64-bit cryptographic namespacing, non-blocking `pg_try_advisory_xact_lock` primitives, canonical lexicographical lock ordering, and machine-verifiable CI test gates.

---

## 1. Architectural Taxonomy: The 6 Advisory Lock Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL Advisory Locks provide an ultra-fast, in-memory application-level locking mechanism managed directly by the database engine without touching disk, heap tuples, or index structures. They allow developers to create distributed mutexes, serialize sensitive workflows, and coordinate background workers without deploying complex external distributed lock managers (such as Redis/Redlock, ZooKeeper, or etcd).

However, autonomous coding agents frequently treat advisory locks as generic in-memory mutexes, completely oblivious to connection pool topologies (PgBouncer/pgpool transaction mode), lock scoping rules (session-level vs transaction-level), hash collision mathematics, and connection exhaustion dynamics:

```typescript
// ❌ CATASTROPHIC LLM ADVISORY LOCK ANTI-PATTERNS

// 1. The Session-Mode Lock Leak in PgBouncer (Transaction Pooling)!
// Calling pg_advisory_lock locks the physical connection, NOT the transaction!
// When used with PgBouncer pool_mode = transaction, the client returns the connection,
// but the lock remains held on the underlying PostgreSQL server PID!
// The next completely unrelated customer borrows this connection and inherits the lock!
await db.query(`SELECT pg_advisory_lock(12345);`);
await executeSensitiveOperation();
await db.query(`SELECT pg_advisory_unlock(12345);`); // ❌ If executeSensitiveOperation throws, unlock NEVER runs!

// 2. The 32-Bit Hash Collision & Raw ID Collision Trap!
// Locking raw integer IDs without namespace partitioning:
// Table orders has ID 42; Table users has ID 42; Table invoices has ID 42.
// Tenant 1 has order 42; Tenant 2 has order 42.
// An order update for Tenant 1 blocks Tenant 2's user login!
await db.query(`SELECT pg_advisory_xact_lock($1);`, [order.id]); // ❌ No namespace, no tenant isolation!

// 3. The Synchronous Blocking Pool Exhaustion Avalanche!
// Calling blocking pg_advisory_lock inside an HTTP request handler.
// When worker 1 takes 5 seconds, 50 concurrent HTTP requests all block on pg_advisory_lock.
// Each waiting request holds an open connection from the connection pool!
// Connection pool exhausts in 200ms -> API Gateway 504 Gateway Timeout!
app.post('/api/checkout', async (req, res) => {
  await db.query('SELECT pg_advisory_lock($1)', [req.user.id]); // ❌ Blocks connection pool!
  await chargeCardWithStripe(); // 1500ms external HTTP call
  await db.query('SELECT pg_advisory_unlock($1)', [req.user.id]);
});
```

### The 6 Catastrophes of Autonomous Advisory Lock Architectures

1. **The Session-Mode Advisory Lock Leak in Transaction Poolers (PgBouncer/pgpool)**:
   PostgreSQL provides two scoping models for advisory locks: **Session-level** (`pg_advisory_lock`) and **Transaction-level** (`pg_advisory_xact_lock`). Session-level locks persist for the lifetime of the underlying backend server process until explicitly released with `pg_advisory_unlock` or when the physical TCP connection closes. In modern cloud architectures, virtually all PostgreSQL deployments sit behind connection poolers running in `transaction` mode (e.g. PgBouncer, Supabase Pooler, AWS RDS Proxy). In transaction mode, a client borrows a server connection for a single transaction or query, after which the pooler immediately reassigns that physical connection to another client. If an agent executes `pg_advisory_lock`, the physical backend connection retains the lock. The client that requested the lock loses access to that backend connection, leaving the lock active forever. Meanwhile, an unsuspecting client that checks out that physical connection unexpectedly holds an exclusive lock on someone else's resource, causing bizarre, unreproducible deadlocks, worker stalls, and total cluster paralysis.

2. **The Missing Transaction-Scoped `pg_advisory_xact_lock` & Dangling Mutex on Worker Panic**:
   When agents use session-level advisory locks in custom code, they rely on application-level `try ... finally` blocks to execute `SELECT pg_advisory_unlock($1)`. However, when a Node.js process crashes with an unhandled rejection, a Go worker panics, a Python process hits a segmentation fault, or Kubernetes terminates a pod via `SIGKILL` (OOM or node preemption), the `finally` block never executes. If the TCP connection is pooled or maintained by an intermediate proxy, the lock remains held in the PostgreSQL lock table indefinitely. Subsequent runs of the background job or migration runner observe the lock as permanently held, causing mission-critical automated pipelines (e.g., nightly billing, payroll settlement, CDC indexing) to freeze forever until a DBA manually queries `pg_locks` and calls `pg_terminate_backend`.

3. **The 32-bit vs 64-bit Integer Hash Collision & Unfenced Namespace Catastrophe**:
   PostgreSQL supports two function signatures: `pg_advisory_lock(key bigint)` (signed 64-bit integer from $-2^{63}$ to $2^{63}-1$) and `pg_advisory_lock(key1 int, key2 int)` (two signed 32-bit integers from $-2^{31}$ to $2^{31}-1$). Autonomous agents frequently generate lock keys by computing a 32-bit hash (e.g. `crc32`, simple string hash codes, or `parseInt`) of string resource names. Under the Birthday Paradox, a 32-bit hash space begins experiencing a 50% collision probability after only $\approx 77,000$ unique keys. Furthermore, agents frequently pass raw primary key integers directly into `pg_advisory_lock(record_id)`. In a relational schema with multiple tables, `orders.id = 101`, `users.id = 101`, and `invoices.id = 101` all map to identical lock keys! An invoice generation job for user 500 will mysteriously block an order update for user 101, creating silent performance degradation and artificial lock contention.

4. **The Synchronous Blocking `pg_advisory_lock` Connection Pool Exhaustion Avalanche**:
   When multiple workers or HTTP requests compete for a shared resource, agents issue synchronous, blocking `SELECT pg_advisory_lock($1)`. If the lock holder is delayed—by slow external API calls, third-party payment gateways, heavy garbage collection, or disk I/O stalls—all waiting workers remain blocked in the PostgreSQL query engine. In connection-pooled environments, **every waiting thread holds an active pooled connection open**. If the application has a connection pool size of 50 and 50 incoming HTTP requests queue on the advisory lock, the pool is depleted in milliseconds. Health check endpoints (`/healthz`) that perform simple `SELECT 1` queries cannot acquire a connection and fail, causing Kubernetes readiness probes to mark pods unhealthy, triggering cascading pod restarts and total service collapse.

5. **The Unfenced Cross-Tenant Resource Contention in Multi-Tenant Databases**:
   In multi-tenant SaaS platforms sharing a single database, multiple tenants possess entities with identical numerical identifiers (e.g., Tenant 1 has `subscription_id = 55`, Tenant 2 has `subscription_id = 55`). When an agent generates transactional code to renew a subscription using `pg_advisory_xact_lock(subscription_id)`, Tenant 1's subscription renewal serializes and blocks Tenant 2's subscription renewal. In severe cases, an adversarial or high-volume tenant can intentionally or unintentionally lock out all other tenants across the entire platform by locking shared numerical keys.

6. **The Non-Canonical Lock Acquisition AB-BA Deadlock Spasm**:
   When a transactional workflow must acquire locks on multiple distinct resources (such as moving funds between two user accounts, coordinating a multi-item inventory deduction, or reserving several rooms simultaneously), agents acquire advisory locks sequentially as resources appear in request payloads or loops. If Request 1 locks Resource A then Resource B, while concurrent Request 2 locks Resource B then Resource A, a classic circular Wait-For Graph dependency ($T_1 \to T_2 \to T_1$) is created. PostgreSQL's deadlock detection algorithm must wake up, scan the lock graph, and abort one of the transactions with `SQLSTATE 40P01: deadlock detected`, failing customer transactions and corrupting business flows.

---

## 2. The 5-Tier Advisory Lock Governance Ladder

Every production system utilizing PostgreSQL Advisory Locks must enforce this 5-Tier governance hierarchy:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Tier 4: Autonomous pg_locks Observability, Timeout Ladders & Watchdogs  │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Canonical Lexicographical Ordering for Multi-Lock Deadlock Immunity │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 2: 64-Bit Deterministic Hash Namespacing & Tenant Isolation        │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Non-Blocking CAS Mutexes (pg_try_advisory_xact_lock) & 0-Wait   │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Transaction-Scoped Lock Invariance (xact) & Pooler Fencing      │
└─────────────────────────────────────────────────────────────────────────┘
```

### Tier 0: Transaction-Scoped Lock Invariance (`pg_advisory_xact_lock`) & Pooler Fencing
- **Zero Session Locks in Transaction Connection Pools**:
  In applications communicating with PostgreSQL through PgBouncer, pgpool, RDS Proxy, or serverless connection routers configured in `pool_mode = transaction`, calling session-level `pg_advisory_lock` or `pg_advisory_unlock` is **strictly prohibited**.
- **Mandatory Transaction Scoping**:
  All application-level mutual exclusion MUST use `pg_advisory_xact_lock` or `pg_try_advisory_xact_lock`. These locks are automatically, unconditionally released by the PostgreSQL kernel the microsecond the enclosing transaction completes (`COMMIT` or `ROLLBACK`). Even if the client process terminates abruptly, suffers an OOM kill, or network cables are severed, PostgreSQL guarantees the lock is freed immediately upon transaction teardown.
- **Dedicated Non-Pooled Connections for Migration / Long-Lived Locks**:
  If a multi-step database schema migration runner (e.g. Flyway, Goose, Liquibase, Prisma Migrate) requires a session-level lock that spans multiple transactions or DDL operations, it MUST connect via a dedicated, direct database connection (`pool_mode = session` or direct port 5432) and execute `SELECT pg_advisory_unlock_all()` inside an unhandled error / process exit handler.

### Tier 1: Non-Blocking CAS Mutexes (`pg_try_advisory_xact_lock`) & Zero-Wait Semantics
- **Zero Blocking Locks in Request Paths**:
  Never execute blocking `SELECT pg_advisory_xact_lock(...)` inside user-facing API request paths or concurrent background workers.
- **Compare-And-Swap (CAS) Immediate Return**:
  Always use the non-blocking variant `SELECT pg_try_advisory_xact_lock(...)`. This function evaluates immediately:
  - Returns `true` if the lock was acquired.
  - Returns `false` immediately if another process or thread already holds the lock.
- **Failsafe Flow Control**:
  If the non-blocking lock returns `false`, the application must NEVER block in an unconstrained sleep loop. It must immediately:
  1. Return `HTTP 409 Conflict` (or `429 Too Many Requests`) with a `Retry-After` header to the API client.
  2. For background workers/cron: gracefully skip the iteration (singleflight deduplication), knowing another worker is already processing the task.
  3. For message queue consumers: release the connection immediately and nack/re-queue the message with an exponential jitter delay.

### Tier 2: 64-Bit Deterministic Hash Namespacing & Tenant Isolation Invariants
- **Namespace Discrimination**:
  PostgreSQL's advisory lock space is global across the entire database. To prevent collisions between different entity types, every lock key must be partitioned by a distinct 16-bit or 32-bit namespace ID, or hashed using a 64-bit cryptographic function.
- **Two-Integer Signature vs 64-Bit Bigint Packing**:
  Use PostgreSQL's native two-integer signature `pg_try_advisory_xact_lock(class_id int, obj_id int)`:
  - `class_id`: A static, registered 32-bit integer constant representing the domain class (e.g., `1001` for `ORDERS`, `1002` for `USERS`, `1003` for `MIGRATIONS`).
  - `obj_id`: A 32-bit integer representing the specific entity or hashed string identifier.
- **Deterministic 64-Bit Hashing with Tenant Isolation**:
  For string identifiers, UUIDs, or multi-tenant architectures, combine the tenant ID, entity class, and entity ID into a canonical string, and hash it using PostgreSQL's native `hashtextextended()` or application-side 64-bit MurmurHash3 / FNV-1a:
  ```sql
  SELECT pg_try_advisory_xact_lock(
    CAST(hashtextextended('tenant:' || $1 || ':entity:' || $2 || ':id:' || $3, 0) AS bigint)
  );
  ```

### Tier 3: Canonical Lexicographical Ordering for Multi-Lock Deadlock Immunity
- **Canonical Sorting Before Acquisition**:
  When a business operation requires acquiring advisory locks on multiple entities (e.g. transferring funds between Account A and Account B, or acquiring locks on 5 batch items):
  1. Compute the 64-bit integer lock keys for all targets.
  2. Deduplicate the keys to prevent self-deadlock.
  3. Sort the array of keys in strict ascending numerical order:
     $$K_1 < K_2 < \dots < K_n$$
  4. Acquire the locks sequentially in this sorted order within the transaction.
- **Deadlock-Free Mathematical Guarantee**:
  Because all concurrent transactions acquire resources according to an identical global total order, the resource allocation graph cannot contain directed cycles ($\text{Cycles}(G) = \emptyset$), mathematically eliminating the possibility of AB-BA deadlocks.

### Tier 4: Autonomous `pg_locks` Observability, Timeout Ladders & Watchdogs
- **Strict Statement & Lock Timeout Ladders**:
  When a blocking advisory lock is explicitly necessary (e.g. a worker queue partition coordinator that must wait for a handoff), it MUST be protected by a sub-second lock timeout:
  ```sql
  SET LOCAL lock_timeout = '2000ms';
  SET LOCAL statement_timeout = '10000ms';
  SELECT pg_advisory_xact_lock($1);
  ```
- **Shared vs Exclusive Advisory Modes**:
  Use `pg_advisory_xact_lock_shared` for read-heavy operations that need mutual exclusion only against write/maintenance tasks. Multiple readers can hold the shared lock simultaneously without blocking each other, while an exclusive lock (`pg_advisory_xact_lock`) blocks and is blocked by all other holders.
- **Automated Orphan Lock Sentinel**:
  Run an autonomous watchdog query inspecting `pg_locks` for active advisory locks held longer than 60 seconds, correlating with `pg_stat_activity` to detect hung backend connections and alert alerting channels before connection pool starvation occurs.

---

## 3. Mathematical Foundations: Hash Collision Probability & Pool Saturation Physics

### 3.1 The Birthday Paradox in Advisory Lock Hash Spaces

When mapping string identifiers or UUIDs into PostgreSQL's advisory lock keys, selecting between a 32-bit integer space and a 64-bit `bigint` space dictates the probability of silent hash collisions.

Under the Generalized Birthday Paradox, given $k$ distinct concurrently active locks drawn uniformly at random from a discrete hash space of size $N$, the probability $\mathbb{P}_{\text{collision}}(k, N)$ that at least two distinct resources collide on the same advisory lock key is given by:

$$\mathbb{P}_{\text{collision}}(k, N) = 1 - \prod_{i=0}^{k-1} \left(1 - \frac{i}{N}\right) \approx 1 - \exp\left(-\frac{k(k-1)}{2N}\right) \approx 1 - \exp\left(-\frac{k^2}{2N}\right)$$

For small probabilities ($\frac{k^2}{2N} \ll 1$), Taylor series expansion yields the linear approximation:

$$\mathbb{P}_{\text{collision}}(k, N) \approx \frac{k^2}{2N}$$

Now consider the stark reality between 32-bit and 64-bit spaces:

1. **32-bit Signed Integer Space ($N = 2^{32} \approx 4.29 \times 10^9$)**:
   If an application maintains $k = 10,000$ concurrent active lock keys:
   $$\mathbb{P}_{\text{collision}}(10^4, 2^{32}) \approx \frac{10^8}{2 \times 4.29 \times 10^9} \approx 1.16 \times 10^{-2} = \mathbf{1.16\%}$$
   More than 1 out of every 100 lock operations suffers an artificial, cross-domain collision! At $k = 77,000$ active keys, collision probability reaches **50%**.

2. **64-bit Signed Bigint Space ($N = 2^{64} \approx 1.84 \times 10^{19}$)**:
   If an application maintains $k = 1,000,000$ concurrent active lock keys:
   $$\mathbb{P}_{\text{collision}}(10^6, 2^{64}) \approx \frac{10^{12}}{2 \times 1.84 \times 10^{19}} \approx \mathbf{2.71 \times 10^{-8}}$$
   The probability of a hash collision is less than 3 in 100 million, providing cryptographic-grade isolation.

**Production Invariant**: Autonomous agents must NEVER hash resource names into 32-bit integers. All string-based advisory locks MUST use 64-bit signed `bigint` keys via 64-bit hash algorithms (e.g. PostgreSQL `hashtextextended(str, 0)` or MurmurHash3_x64_128).

---

### 3.2 Connection Pool Saturation Physics under Blocking Advisory Locks

Let $\lambda$ be the arrival rate of incoming requests requiring an advisory lock (requests per second), and let $W$ be the average duration a connection is held open during the lock execution window.

By Little's Law, the average number of database connections $C_{\text{active}}$ occupied by these requests is:

$$C_{\text{active}} = \lambda \cdot W$$

Under non-blocking compare-and-swap (`pg_try_advisory_xact_lock`), the lock acquisition check completes in $t_{\text{check}} \approx 0.5\text{ms}$. If the lock is held, the query returns immediately:

$$W_{\text{non-blocking}} \approx t_{\text{check}} + t_{\text{work}} \quad (\text{if acquired}) \quad \text{or} \quad t_{\text{check}} \quad (\text{if rejected})$$

However, under blocking `pg_advisory_xact_lock`, if a transaction holds the lock for $T_{\text{hold}} = 5.0\text{s}$ (e.g. during an external Stripe call or slow network query), all subsequent $\lambda$ incoming requests block inside the database:

$$W_{\text{blocking}} = \frac{T_{\text{hold}}}{2} + t_{\text{work}} \approx 2.5\text{s} + t_{\text{work}}$$

If $\lambda = 50 \text{ req/s}$ and the connection pool size is $C_{\text{pool}} = 40$:

$$C_{\text{demanded}} = 50 \times 2.5 = 125 \text{ connections} \gg C_{\text{pool}} = 40$$

The connection pool saturates completely in:

$$T_{\text{exhaust}} = \frac{C_{\text{pool}}}{\lambda} = \frac{40}{50} = \mathbf{0.8 \text{ seconds}}$$

Within 800 milliseconds, the entire application connection pool is depleted. Zero connections remain for health checks, login flows, or critical reads, collapsing the entire web service.

---

## 4. Production SQL & DDL Invariants for PostgreSQL Advisory Locks

### 4.1 Canonical Hash Key Generation Functions (PostgreSQL PL/pgSQL)

Ensure that all advisory lock keys are generated using deterministic, collision-resistant 64-bit functions that cleanly isolate tenants and domain namespaces:

```sql
-- Migration: Add deterministic 64-bit advisory lock key generators
CREATE OR REPLACE FUNCTION generate_advisory_key(
    p_namespace_id INT, -- Registered namespace: 1=checkout, 2=billing, 3=reports
    p_tenant_id TEXT,   -- Multi-tenant isolation boundary
    p_resource_id TEXT  -- Entity UUID or identifier
) RETURNS BIGINT AS $$
DECLARE
    v_combined TEXT;
BEGIN
    -- Format: <namespace_id>:<tenant_id>:<resource_id>
    v_combined := p_namespace_id::TEXT || ':' || COALESCE(p_tenant_id, 'global') || ':' || p_resource_id;
    -- PostgreSQL hashtextextended returns a signed 64-bit bigint
    RETURN hashtextextended(v_combined, 0);
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE;
```

---

### 4.2 Non-Blocking Singleflight Worker Pattern (Go with `jackc/pgx/v5`)

```go
package lock

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrLockBusy = errors.New("advisory lock is held by another process; skipping execution")

// AdvisoryLockManager coordinates deterministic transaction-scoped PostgreSQL advisory locks.
type AdvisoryLockManager struct {
	pool *pgxpool.Pool
}

func NewAdvisoryLockManager(pool *pgxpool.Pool) *AdvisoryLockManager {
	return &AdvisoryLockManager{pool: pool}
}

// Compute64BitKey generates a deterministic, signed 64-bit bigint key from namespace, tenant, and entity ID.
func Compute64BitKey(namespace int32, tenantID, entityID string) int64 {
	h := sha256.New()
	_, _ = fmt.Fprintf(h, "%d:%s:%s", namespace, tenantID, entityID)
	digest := h.Sum(nil)
	// Cast high 8 bytes to signed int64 (PostgreSQL bigint)
	return int64(binary.BigEndian.Uint64(digest[:8]))
}

// WithTryXactLock executes a critical section inside a transaction guarded by pg_try_advisory_xact_lock.
// If the lock cannot be acquired immediately, it returns ErrLockBusy without blocking connections.
func (m *AdvisoryLockManager) WithTryXactLock(
	ctx context.Context,
	namespace int32,
	tenantID, entityID string,
	fn func(ctx context.Context, tx pgx.Tx) error,
) error {
	lockKey := Compute64BitKey(namespace, tenantID, entityID)

	// Begin standard transaction
	tx, err := m.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer func() {
		_ = tx.Rollback(ctx) // Safe no-op if committed
	}()

	// Execute non-blocking CAS lock check
	var acquired bool
	query := "SELECT pg_try_advisory_xact_lock($1);"
	if err := tx.QueryRow(ctx, query, lockKey).Scan(&acquired); err != nil {
		return fmt.Errorf("failed to execute pg_try_advisory_xact_lock: %w", err)
	}

	if !acquired {
		return ErrLockBusy
	}

	// Execute business critical section
	if err := fn(ctx, tx); err != nil {
		return err
	}

	// Commit automatically releases the transaction-scoped advisory lock in PostgreSQL
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("failed to commit transaction: %w", err)
	}

	return nil
}
```

---

### 4.3 Autonomous `pg_locks` Watchdog Query

Run this diagnostic query to detect active advisory locks and identify blocking or orphaned locks:

```sql
-- Diagnostic: Inspect all currently held advisory locks with backend activity details
SELECT
    l.pid,
    a.usename,
    a.client_addr,
    a.application_name,
    a.state,
    NOW() - a.state_change AS state_duration,
    NOW() - a.query_start AS query_duration,
    l.locktype,
    l.mode,
    l.granted,
    -- PostgreSQL stores 64-bit advisory keys in objid or (classid, objid)
    CASE 
        WHEN l.objsubid = 1 THEN '64-bit bigint: ' || l.objid::bigint
        ELSE '32-bit pair: (' || l.classid || ', ' || l.objid || ')'
    END AS lock_identifier,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE l.locktype = 'advisory'
ORDER BY a.query_start ASC;
```

---

## 5. Complete TypeScript Production Engine: `AgenticDatabaseAdvisoryLockEngine`

```typescript
/**
 * AgenticDatabaseAdvisoryLockEngine
 * Production-ready TypeScript implementation for PostgreSQL Advisory Locks.
 * Supports deterministic 64-bit hash keys, transaction-scoped compare-and-swap,
 * canonical lexicographical sorting for multi-resource locking, and timeout ladders.
 */

import { Pool, PoolClient } from 'pg';
import { createHash } from 'node:crypto';

export interface LockTarget {
  namespace: number; // Registered namespace constant
  tenantId: string;  // Tenant identifier for SaaS isolation
  entityId: string;  // Resource UUID or identifier
}

export interface LockMetrics {
  pid: number;
  userName: string;
  clientAddr: string | null;
  state: string;
  stateDurationSeconds: number;
  lockMode: string;
  granted: boolean;
  lockIdentifier: string;
}

export class LockAcquisitionError extends Error {
  constructor(message: string, public readonly isBusy: boolean) {
    super(message);
    this.name = 'LockAcquisitionError';
  }
}

export class AgenticDatabaseAdvisoryLockEngine {
  constructor(private readonly pool: Pool) {}

  /**
   * Deterministically computes a signed 64-bit bigint lock key from namespace, tenant, and entity ID.
   * Utilizes SHA-256 and extracts the high 8 bytes as a signed BigInt (-2^63 to 2^63 - 1).
   */
  public compute64BitKey(target: LockTarget): bigint {
    const input = `${target.namespace}:${target.tenantId}:${target.entityId}`;
    const hash = createHash('sha256').update(input, 'utf8').digest();
    // Read high 64 bits as a signed BigInt
    return hash.readBigInt64BE(0);
  }

  /**
   * Executes a callback within a transaction secured by a non-blocking pg_try_advisory_xact_lock.
   * Immediately throws LockAcquisitionError(isBusy=true) if another process holds the lock.
   * Automatically releases the lock upon transaction commit or rollback.
   */
  public async withTryXactLock<T>(
    target: LockTarget,
    fn: (client: PoolClient) => Promise<T>
  ): Promise<T> {
    const lockKey = this.compute64BitKey(target);
    const client = await this.pool.connect();

    try {
      await client.query('BEGIN;');

      const result = await client.query<{ acquired: boolean }>(
        'SELECT pg_try_advisory_xact_lock($1) AS acquired;',
        [lockKey.toString()] // pg driver supports passing BigInt strings
      );

      const acquired = result.rows[0]?.acquired ?? false;
      if (!acquired) {
        await client.query('ROLLBACK;');
        throw new LockAcquisitionError(
          `Advisory lock busy for target [ns=${target.namespace}, tenant=${target.tenantId}, entity=${target.entityId}]`,
          true
        );
      }

      const outcome = await fn(client);
      await client.query('COMMIT;');
      return outcome;
    } catch (err) {
      try {
        await client.query('ROLLBACK;');
      } catch {
        // Suppress rollback errors if connection already closed
      }
      throw err;
    } finally {
      client.release();
    }
  }

  /**
   * Acquires multiple advisory locks in strict canonical ascending order to prevent deadlocks.
   * Enforces a sub-second lock_timeout to prevent pool starvation if forced to block.
   */
  public async withCanonicalMultiLock<T>(
    targets: LockTarget[],
    timeoutMs: number,
    fn: (client: PoolClient) => Promise<T>
  ): Promise<T> {
    if (targets.length === 0) {
      throw new Error('At least one lock target must be provided.');
    }

    // 1. Calculate and deduplicate 64-bit keys
    const rawKeys = targets.map((t) => this.compute64BitKey(t));
    const uniqueKeys = Array.from(new Set(rawKeys));

    // 2. CANONICAL SORTING: Sort keys in ascending order
    uniqueKeys.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

    const client = await this.pool.connect();

    try {
      await client.query('BEGIN;');
      // Set strict local lock timeout
      await client.query(`SET LOCAL lock_timeout = '${Math.max(100, timeoutMs)}ms';`);

      // 3. Sequentially acquire each lock in canonical order
      for (const key of uniqueKeys) {
        await client.query('SELECT pg_advisory_xact_lock($1);', [key.toString()]);
      }

      const outcome = await fn(client);
      await client.query('COMMIT;');
      return outcome;
    } catch (err) {
      try {
        await client.query('ROLLBACK;');
      } catch {
        // Suppress
      }
      throw err;
    } finally {
      client.release();
    }
  }

  /**
   * Diagnostic method inspecting currently active advisory locks from pg_locks.
   */
  public async getActiveAdvisoryLocks(): Promise<LockMetrics[]> {
    const query = `
      SELECT
        l.pid,
        a.usename AS "userName",
        a.client_addr::TEXT AS "clientAddr",
        a.state,
        EXTRACT(EPOCH FROM (NOW() - a.state_change)) AS "stateDurationSeconds",
        l.mode AS "lockMode",
        l.granted,
        CASE 
          WHEN l.objsubid = 1 THEN '64-bit bigint: ' || l.objid::BIGINT
          ELSE '32-bit pair: (' || l.classid || ', ' || l.objid || ')'
        END AS "lockIdentifier"
      FROM pg_locks l
      JOIN pg_stat_activity a ON l.pid = a.pid
      WHERE l.locktype = 'advisory'
      ORDER BY a.query_start ASC;
    `;
    const result = await this.pool.query<LockMetrics>(query);
    return result.rows;
  }
}
```

---

## 6. The 6-State Advisory Lock Lifecycle Finite-State Machine (FSM)

```
       ┌──────────────────────────────┐
       │         S0: IDLE             │
       └──────────────┬───────────────┘
                      │ Generate 64-bit deterministic hash key
                      ▼
       ┌──────────────────────────────┐
       │      S1: KEY_SYNTHESIZED     │
       └──────────────┬───────────────┘
                      │ BEGIN Transaction + pg_try_advisory_xact_lock
                      ▼
            /───────────────────\
           <   Lock Acquired?    >
            \───────────────────/
             /                 \
    [No]    /                   \   [Yes]
           ▼                     ▼
┌──────────────────────┐  ┌──────────────────────┐
│  S2: LOCK_REJECTED   │  │   S3: LOCK_HELD_TX   │
│  (Zero-Wait / 409)   │  │ (Transaction Scoped) │
└──────────┬───────────┘  └──────────┬───────────┘
           │                         │ Execute Critical Section
           ▼                         ▼
┌──────────────────────┐  ┌──────────────────────┐
│   S4: ROLLBACK_TX    │  │ S5: COMMIT_AND_FREE  │
│  (Connection Freed)  │  │(Kernel Auto-Release) │
└──────────────────────┘  └──────────────────────┘
```

1. **State 0: IDLE**
   The application or background agent identifies a critical section requiring mutual exclusion (e.g. payout disbursement, migration execution, singleflight refresh).
2. **State 1: KEY_SYNTHESIZED**
   The agent formats `<namespace_id>:<tenant_id>:<entity_id>` and computes a deterministic, signed 64-bit integer key via SHA-256 or MurmurHash3. If acquiring multiple resources, keys are deduplicated and sorted in ascending numerical order.
3. **State 2: LOCK_REJECTED (Fast-Fail)**
   `pg_try_advisory_xact_lock` returns `false`. The transaction immediately executes `ROLLBACK`, the connection is returned to the pool within $<1\text{ms}$, and the caller receives an explicit `409 Conflict` or graceful worker skip.
4. **State 3: LOCK_HELD_TX**
   `pg_try_advisory_xact_lock` returns `true`. The lock is actively registered in PostgreSQL shared memory tied strictly to the current `xid`.
5. **State 4: ROLLBACK_TX**
   On application error, timeout, or fast-fail, `ROLLBACK` terminates the transaction. The PostgreSQL kernel immediately unlinks the advisory lock from the shared lock table.
6. **State 5: COMMIT_AND_FREE**
   The critical section completes successfully. `COMMIT` is executed. The lock is released atomically with data persistence, guaranteeing zero connection pool leaks under PgBouncer transaction pooling.

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Check | Automated Validation Command / Metric | Pass Criterion |
|---|---|---|---|
| **Gate 1: Pooler Fencing** | Zero session locks in codebase | `rg "pg_advisory_lock\(" --type ts --type go --type py` | 0 occurrences in application request paths (only `pg_advisory_xact_lock` or `pg_try_advisory_xact_lock`) |
| **Gate 2: Non-Blocking CAS** | Non-blocking try-lock used in APIs | `rg "pg_try_advisory_xact_lock" src/` | Matches 100% of user-facing or background worker mutex paths |
| **Gate 3: 64-Bit Hash Discipline** | No 32-bit integer truncation | Static analysis / Unit tests of key generation | Output keys are signed 64-bit BigInts with collision probability $\le 10^{-7}$ |
| **Gate 4: Canonical Sort** | Multi-lock sorting verification | Unit test verifying ascending key ordering | Test asserts input `[30, 10, 20]` acquires `10 -> 20 -> 30` |
| **Gate 5: Leak Prevention** | Zero dangling locks after panic | Integration test simulating worker crash/error | `SELECT count(*) FROM pg_locks WHERE locktype = 'advisory'` returns `0` |
| **Gate 6: Timeout Fencing** | Strict lock timeout configured | `SET LOCAL lock_timeout` preceding any blocking lock | `lock_timeout <= 2000ms` enforced |

---

## 8. Autonomous Agent Execution Checklist

1. [ ] **Verify Connection Pool Mode**:
   Determine if the PostgreSQL connection runs via PgBouncer or proxy in `transaction` mode. If true, strictly prohibit `pg_advisory_lock` and enforce `pg_advisory_xact_lock`.
2. [ ] **Register Namespaces**:
   Establish a centralized enum of 32-bit namespace integer constants (e.g. `1 = Checkouts`, `2 = DailyRollup`, `3 = UserSync`).
3. [ ] **Partition by Tenant & Entity**:
   Always combine `namespace`, `tenant_id`, and `entity_id` before hashing to prevent cross-tenant and cross-table collisions.
4. [ ] **Enforce Non-Blocking CAS (`pg_try_advisory_xact_lock`)**:
   Implement fast-fail logic returning HTTP 409 or worker skip instead of blocking pooled connections.
5. [ ] **Sort Multi-Resource Keys**:
   When locking $>1$ resource in a single transaction, deduplicate and sort keys in ascending numerical order.
6. [ ] **Add `pg_locks` Watchdogs**:
   Provide observability queries or prometheus metrics monitoring advisory lock duration and alerting if any lock exceeds 60 seconds.
