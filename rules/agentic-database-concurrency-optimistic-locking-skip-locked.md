---
description: Database concurrency control, optimistic locking (OCC) version epochs, write skew elimination, deadlock-free lexicographical lock ordering, SELECT FOR UPDATE SKIP LOCKED queues, and serializable retry loops across Go (pgx/sqlc/GORM), TypeScript (Drizzle/Prisma/Kysely/TypeORM), Python (SQLAlchemy), Rust (sqlx/SeaORM), PostgreSQL, MySQL, Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{concurrency,transaction,lock,mutex,occ,version,queue,worker,repository,repo,database,db,dao,service,model}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/src/workers/**/*.{ts,js,go,rs,py},**/internal/repository/**/*.{go,rs},**/internal/worker/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Concurrency Control, Optimistic Locking (OCC), Write Skew Elimination & SKIP LOCKED Queue Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design transactional data mutations, financial ledgers, inventory deductions, background task queues, reservation systems, or distributed multi-user updates across PostgreSQL, MySQL, SQLite, Go (`jackc/pgx`, `sqlc`, `GORM`), TypeScript (`Drizzle`, `Prisma`, `Kysely`, `TypeORM`), Python (`SQLAlchemy`), or Rust (`sqlx`, `SeaORM`). Eliminate the "Lost Update Blind Overwrite Disaster" (where concurrent read-modify-write cycles silently obliterate intervening writes), the "Write Skew & Phantom Read Illusion in Snapshot Isolation" (where multi-row constraints fail under `REPEATABLE READ` transactions without predicate locks or exclusion constraints), the "Pessimistic Lock Order Deadlock Spasm" (where arbitrary `SELECT ... FOR UPDATE` row locking orders trigger Wait-For Graph cycles and PostgreSQL `ERROR: 40P01 deadlock_detected`), the "Job Queue Serial Head-of-Line Blocking & Worker Lock Thrashing" (where workers query `LIMIT 1 FOR UPDATE` without `SKIP LOCKED`, serializing concurrent workers on identical rows), the "Missing Version Epoch & Web API Stale Mutation Hazard" (where concurrent REST/tRPC/gRPC submissions blindly overwrite each other without `version` checking or `If-Match` ETags), and the "Long-Lived Lock Connection Exhaustion & Transaction Lockout" (where agents hold database row locks across slow external Stripe, LLM, or network calls, starving connection pools) by establishing a strict 5-Tier Concurrency Governance Ladder, deadlock-free lexicographical resource ordering, monotonic OCC version epochs, `SELECT ... FOR UPDATE SKIP LOCKED` non-blocking queueing, and automated serialization failure (`40001`) retry loops.

---

## 1. Architectural Taxonomy: The 6 Concurrency Catastrophes vs The 5-Tier Concurrency Governance Ladder

When autonomous coding agents generate database transactional code, LLMs almost universally write naive read-modify-write patterns that pass single-threaded unit tests with flying colors, but catastrophically corrupt data or deadlock under concurrent production traffic:

```typescript
// ❌ CATASTROPHIC LLM CONCURRENCY ANTI-PATTERNS (Lost Updates, Race Conditions, Deadlocks, HOL Blocking)
async function transferInventory(orderId: string, fromWarehouse: string, toWarehouse: string, sku: string, qty: number) {
  // VULN 1: Read-modify-write lost update! Concurrent requests read identical stock and overwrite each other.
  const sourceItem = await db.query('SELECT stock FROM inventory WHERE warehouse = $1 AND sku = $2', [fromWarehouse, sku]);
  if (sourceItem.stock < qty) throw new Error('Insufficient stock');

  // VULN 2: Non-atomic application-level mutation!
  await db.query('UPDATE inventory SET stock = $1 WHERE warehouse = $2 AND sku = $3', [sourceItem.stock - qty, fromWarehouse, sku]);

  // VULN 3: Deadlock hazard! Locking rows in arbitrary order without lexicographical sorting.
  // Transaction 1 locks fromWarehouse -> toWarehouse; Transaction 2 locks toWarehouse -> fromWarehouse.
  // Result: PostgreSQL ERROR: 40P01 deadlock detected!
  await db.query('SELECT * FROM inventory WHERE warehouse = $1 FOR UPDATE', [fromWarehouse]);
  await db.query('SELECT * FROM inventory WHERE warehouse = $1 FOR UPDATE', [toWarehouse]);

  // VULN 4: Long-lived lock across external I/O! Holding row locks during slow external HTTP/LLM call.
  await stripe.paymentIntents.create({ ... }); // 1200ms latency locks connection pool!
}
```

In high-concurrency microservices, multi-tenant databases, or multi-agent autonomous execution loops, these patterns trigger six critical database concurrency catastrophes:

- **The "Lost Update Blind Overwrite Disaster"**:
  - Worker A reads row $R$ at version 1 (e.g., account balance \$1,000). Worker B reads row $R$ at version 1 concurrently.
  - Worker A calculates $\$1,000 - \$200 = \$800$ in application memory and writes `UPDATE accounts SET balance = 800 WHERE id = 1`.
  - Worker B calculates $\$1,000 - \$300 = \$700$ in application memory and writes `UPDATE accounts SET balance = 700 WHERE id = 1`.
  - Worker B's commit completely obliterates Worker A's \$200 debit! The \$200 vanishes into thin air.
  - Invariant: Multi-step read-modify-write loops in application memory are STRICTLY PROHIBITED. All state updates MUST use single-statement atomic SQL expressions (`UPDATE accounts SET balance = balance - 200 WHERE id = 1 AND balance >= 200`), or enforce Optimistic Concurrency Control with monotonic version verification (`WHERE id = 1 AND version = :expected_version`).

- **The "Write Skew & Phantom Read Illusion in Snapshot Isolation"**:
  - Developers and agents mistakenly believe PostgreSQL `REPEATABLE READ` prevents all concurrency anomalies. However, ANSI SQL `REPEATABLE READ` in PostgreSQL is implemented as Snapshot Isolation (SI), which is vulnerable to **Write Skew**.
  - Classic Example (The On-Call Doctor Problem): Hospital policy requires at least one doctor on call. Doctors Alice and Bob are both on call. Alice and Bob simultaneously request to go off call.
    - Transaction A (Alice): Reads `SELECT COUNT(*) FROM doctors WHERE on_call = true` (returns 2). Updates Alice `UPDATE doctors SET on_call = false WHERE id = 'alice'`.
    - Transaction B (Bob): Reads `SELECT COUNT(*) FROM doctors WHERE on_call = true` (returns 2). Updates Bob `UPDATE doctors SET on_call = false WHERE id = 'bob'`.
  - Because Alice and Bob updated disjoint rows, both transactions commit cleanly under Snapshot Isolation (`REPEATABLE READ`). The invariant $\text{COUNT} \ge 1$ is completely violated; ZERO doctors remain on call!
  - Invariant: Multi-row constraint invariants CANNOT rely on `READ COMMITTED` or `REPEATABLE READ`. They MUST use PostgreSQL `SERIALIZABLE` isolation (with automated retry on error code `40001`), explicit pessimistic predicate locks (`SELECT ... FOR UPDATE`), or declarative PostgreSQL Exclusion Constraints (`EXCLUDE USING gist`).

- **The "Pessimistic Lock Order Deadlock Spasm"**:
  - When workflows require locking multiple rows (e.g., double-entry ledger transfers, multi-item order checkouts), agents lock rows in the arbitrary order received from user payloads or API arrays.
  - Transaction 1 processes transfer from Account $A$ to Account $B$: locks $A$, then attempts to lock $B$.
  - Transaction 2 processes transfer from Account $B$ to Account $A$: locks $B$, then attempts to lock $A$.
  - Neither transaction can proceed. PostgreSQL detects the cycle in the Wait-For Graph and abruptly aborts one transaction with `ERROR: 40P01 deadlock_detected`.
  - Invariant: When acquiring pessimistic locks on multiple rows within a single transaction, the application MUST sort all primary keys in strict **lexicographical / ascending order** prior to executing `SELECT ... FOR UPDATE`. Directed cycles in the Wait-For Graph are mathematically impossible when resources are locked in total canonical order.

- **The "Job Queue Serial Head-of-Line Blocking & Worker Lock Thrashing"**:
  - Agents implementing task queues or worker dispatch loops frequently write: `SELECT * FROM tasks WHERE status = 'pending' ORDER BY created_at ASC LIMIT 1 FOR UPDATE`.
  - When 50 concurrent worker threads execute this query, Worker 1 acquires the lock on the top pending row. Workers 2 through 50 do NOT skip to row 2; instead, they all block and wait on Worker 1 to commit or roll back!
  - Once Worker 1 commits, Worker 2 acquires the lock, realizes the status is now 'processing', discards it, and fetches the next row. The worker pool is completely serialized, throughput collapses to $O(1)$, and database connection pools are pinned waiting on locks.
  - Invariant: All concurrent job queue and worker consumption queries MUST use `SELECT ... FOR UPDATE SKIP LOCKED` or `NOWAIT`. Workers skip locked rows instantly with zero blocking, achieving linear horizontal scalability.

- **The "Missing Version Epoch & Web API Stale Mutation Hazard"**:
  - In distributed web apps, Client A loads a customer profile form at $t_0$ (version 4). Client B loads the same form at $t_1$ (version 4).
  - Client B updates the phone number and saves at $t_2$. The database updates to version 5.
  - Client A updates the email address and saves at $t_3$. Naive agent code executes `UPDATE customers SET email = $1 WHERE id = $2`.
  - Result: Client A's save silently overwrites Client B's updated phone number with stale data from $t_0$.
  - Invariant: User-facing entity schemas MUST contain a `version INT NOT NULL DEFAULT 1`. Updates MUST execute `UPDATE tbl SET ..., version = version + 1 WHERE id = $1 AND version = $2 RETURNING version`. If rows affected is 0, the API MUST reject with `409 Conflict` (or HTTP `ETag` / `If-Match` mismatch).

- **The "Long-Lived Lock Connection Exhaustion & Transaction Lockout"**:
  - An agent opens a database transaction, locks an account row via `SELECT ... FOR UPDATE`, and then performs an external Stripe payment, OpenAI LLM completion, or PDF generation before committing.
  - A 1,500ms network roundtrip holds the row lock and pins the pooled database connection. Hundreds of incoming user requests attempting to access the same account queue up, depleting the HikariCP/pgx connection pool within seconds and bringing the entire system down.
  - Invariant: External network I/O, LLM invocations, and slow operations are ABSOLUTELY FORBIDDEN inside active database transactions holding row locks. Transactions MUST be kept minimal, purely executing in-memory operations and instant database statements.

---

### The 5-Tier Concurrency Governance Ladder

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Tier 4: SERIALIZABLE SNAPSHOT ISOLATION & DECLARATIVE EXCLUSION            │
│ (PostgreSQL SERIALIZABLE with 40001 retry backoff, EXCLUDE USING gist)      │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: NON-BLOCKING SKIP LOCKED WORKER QUEUEING                            │
│ (SELECT ... FOR UPDATE SKIP LOCKED, zero worker head-of-line serialization) │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: DEADLOCK-FREE LEXICOGRAPHICAL PESSIMISTIC LOCKING                   │
│ (Sort keys in total canonical order: sort(ids) -> SELECT ... FOR UPDATE)    │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: OPTIMISTIC CONCURRENCY CONTROL (OCC) WITH VERSION EPOCHS            │
│ (WHERE id = :id AND version = :expected_version, ETag If-Match, 409 Conflict)│
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: SINGLE-STATEMENT ATOMIC MUTATION INVARIANCE                         │
│ (UPDATE tbl SET val = val - :delta WHERE id = :id AND val >= :delta RETURNING)│
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Invariants: Total Ordering Deadlock Proof, OCC Calculus & Queue Scaling

### 2.1 The Deadlock-Free Mutual Exclusion Theorem (Total Resource Ordering)

Let $R = \{r_1, r_2, \dots, r_m\}$ be the set of database row resources. Let $\prec$ be a strict total order over $R$ (e.g., lexicographical ordering of primary keys: $r_a \prec r_b \iff \text{PK}(r_a) < \text{PK}(r_b)$).

Let $T = \{T_1, T_2, \dots, T_n\}$ be the set of concurrent active database transactions. Each transaction $T_i$ requires a subset of locks $L_i \subseteq R$.

**Theorem**: If every transaction acquires locks in the strict order defined by $\prec$ (i.e., $T_i$ requests $r_a$ before $r_b$ if and only if $r_a \prec r_b$), then the Wait-For Graph $G = (V, E)$ is acyclic, and database deadlock is mathematically impossible ($P(\text{deadlock}) = 0$).

**Proof**:
1. Suppose for contradiction that a deadlock occurs. Then there exists a directed cycle in the Wait-For Graph:
   $$T_1 \to T_2 \to T_3 \to \dots \to T_k \to T_1$$
2. An edge $T_i \to T_j$ means $T_i$ is waiting for a lock on resource $r_x$ currently held by $T_j$.
3. Since $T_j$ holds $r_x$ and is waiting for another resource $r_y$ (where $T_j \to T_{j+1}$), and transactions only acquire resources in increasing order according to $\prec$, it must be that:
   $$r_x \prec r_y$$
4. Chaining the inequalities along the cycle yields:
   $$r_{x_1} \prec r_{x_2} \prec \dots \prec r_{x_k} \prec r_{x_1}$$
5. By transitivity of the strict total order $\prec$, we have $r_{x_1} \prec r_{x_1}$, which is a contradiction (no element can be strictly less than itself).
6. Therefore, no directed cycle can exist in $G$. The Wait-For Graph is a Directed Acyclic Graph (DAG), proving that deadlock cannot occur under canonical key sorting. $\blacksquare$

---

### 2.2 Optimistic Concurrency Control (OCC) Throughput & Crossover Calculus

Consider a database workload with $N$ concurrent workers mutating items chosen uniformly at random from a hot state space of size $S$. Each transaction executes in time $T_{\text{exec}}$.

Under Optimistic Concurrency Control (OCC), a transaction reads version $v$, executes, and commits if `version == v`. The probability of conflict $P_{\text{conflict}}$ for a transaction when $N$ workers are active concurrently is:
$$P_{\text{conflict}} = 1 - \left(1 - \frac{1}{S}\right)^{N-1}$$

For large $S$, using the approximation $(1 - 1/S)^{N-1} \approx e^{-(N-1)/S}$:
$$P_{\text{conflict}} \approx 1 - e^{-\frac{N-1}{S}}$$

Under Pessimistic 2-Phase Locking (2PL), workers queue on row locks. Total transaction duration under 2PL includes lock waiting time:
$$T_{\text{pessimistic}} = T_{\text{exec}} + T_{\text{lock\_wait}}$$
Where average lock wait time under M/M/1 queuing grows non-linearly with contention:
$$T_{\text{lock\_wait}} \approx \frac{\rho}{1 - \rho} \cdot T_{\text{exec}} \quad \text{where } \rho = \frac{N \cdot T_{\text{exec}}}{S \cdot \tau}$$

**The OCC Crossover Invariant**: OCC is strictly superior to Pessimistic Locking when the expected retry cost is lower than the lock queuing delay:
$$\mathbb{E}[T_{\text{occ}}] = T_{\text{exec}} + P_{\text{conflict}} \cdot (\mathbb{E}[T_{\text{backoff}}] + T_{\text{exec}}) < T_{\text{pessimistic}}$$

When contention is moderate to low ($N/S < 0.2$), OCC minimizes connection hold time by avoiding lock acquisition delays entirely, maximizing database connection pool throughput.

---

### 2.3 Worker Queue Throughput Scaling: Standard `FOR UPDATE` vs `SKIP LOCKED`

Let $W$ be the number of concurrent queue workers. Let $\mu = 1 / T_{\text{job}}$ be the service rate per worker.

- **Standard `LIMIT 1 FOR UPDATE`**:
  All $W$ workers attempt to lock the row at index 0. Worker 1 acquires the lock; Workers $2 \dots W$ serialize in the lock queue.
  $$\text{Effective Throughput}_{\text{Standard}} = \min(W \cdot \mu, \mu) = \mu \quad (\Theta(1) \text{ scalability})$$
  Adding more workers creates zero additional throughput and exponentially increases lock wait latency and connection pool saturation.

- **Non-Blocking `LIMIT 1 FOR UPDATE SKIP LOCKED`**:
  Worker 1 locks row 0. Worker 2 immediately skips row 0 and locks row 1. Worker $k$ locks row $k-1$ in 0ms without blocking.
  $$\text{Effective Throughput}_{\text{SKIP LOCKED}} = \sum_{k=1}^{W} \mu = W \cdot \mu \quad (\Theta(W) \text{ linear scalability})$$
  Lock contention is eliminated, worker throughput scales linearly with worker count, and latency variance drops to near zero.

---

## 3. Production TypeScript Implementation: `AgenticDatabaseConcurrencyEngine`

The following production engine provides type-safe atomic conditional execution, monotonic OCC version validation with decorrelated exponential jitter retry loops, canonical lexicographical lock key sorting, and `SKIP LOCKED` queue dispatching:

```typescript
import { EventEmitter } from 'node:events';
import crypto from 'node:crypto';

export interface ConcurrencyEntity {
  id: string;
  version: number;
  [key: string]: any;
}

export interface OCCExecutionOptions {
  maxRetries?: number;
  baseBackoffMs?: number;
  maxBackoffMs?: number;
  isolationLevel?: 'READ COMMITTED' | 'REPEATABLE READ' | 'SERIALIZABLE';
}

export interface QueueTask {
  id: string;
  payload: Record<string, any>;
  status: 'pending' | 'processing' | 'completed' | 'failed';
  attempts: number;
  lockedAt?: Date;
}

export class ConcurrencyConflictError extends Error {
  constructor(message: string, public readonly entityId: string, public readonly currentVersion: number) {
    super(message);
    name = 'ConcurrencyConflictError';
  }
}

export class SerializationFailureError extends Error {
  constructor(message: string, public readonly sqlState: string = '40001') {
    super(message);
    name = 'SerializationFailureError';
  }
}

/**
 * Production-grade Database Concurrency & OCC Governance Engine
 */
export class AgenticDatabaseConcurrencyEngine extends EventEmitter {
  private readonly defaultOptions: Required<OCCExecutionOptions> = {
    maxRetries: 4,
    baseBackoffMs: 50,
    maxBackoffMs: 2000,
    isolationLevel: 'READ COMMITTED',
  };

  /**
   * Sorts resource IDs in strict lexicographical order to prevent deadlocks.
   * Guarantees an acyclic Wait-For Graph (DAG) across concurrent transactions.
   */
  public sortKeysForLocking(ids: string[]): string[] {
    return [...new Set(ids)].sort((a, b) => a.localeCompare(b));
  }

  /**
   * Generates a safe SELECT ... FOR UPDATE query with canonical lexicographical ordering.
   */
  public buildPessimisticLockQuery(tableName: string, sortedIds: string[], mode: 'WAIT' | 'NOWAIT' | 'SKIP LOCKED' = 'WAIT'): { sql: string; params: string[] } {
    const placeholders = sortedIds.map((_, i) => `$${i + 1}`).join(', ');
    let clause = 'FOR UPDATE';
    if (mode === 'NOWAIT') clause = 'FOR UPDATE NOWAIT';
    if (mode === 'SKIP LOCKED') clause = 'FOR UPDATE SKIP LOCKED';

    const sql = `SELECT * FROM ${tableName} WHERE id IN (${placeholders}) ORDER BY id ASC ${clause}`;
    return { sql, params: sortedIds };
  }

  /**
   * Builds an atomic conditional decrement statement (Tier 0 Single-Statement Invariant).
   * 0ms lock wait time, 100% immune to application-level read-modify-write lost updates.
   */
  public buildAtomicDeductionQuery(tableName: string, id: string, amount: number, balanceColumn: string = 'balance'): { sql: string; params: [number, string] } {
    const sql = `
      UPDATE ${tableName} 
      SET ${balanceColumn} = ${balanceColumn} - $1,
          updated_at = NOW()
      WHERE id = $2 AND ${balanceColumn} >= $1
      RETURNING id, ${balanceColumn}, updated_at;
    `.trim();
    return { sql, params: [amount, id] };
  }

  /**
   * Builds an Optimistic Concurrency Control (OCC) mutation statement with monotonic version increment.
   */
  public buildOCCUpdateQuery(tableName: string, entityId: string, expectedVersion: number, updates: Record<string, any>): { sql: string; params: any[] } {
    const setClauses: string[] = ['version = version + 1', 'updated_at = NOW()'];
    const params: any[] = [];
    let paramIndex = 1;

    for (const [key, value] of Object.entries(updates)) {
      if (key === 'id' || key === 'version' || key === 'updated_at') continue;
      setClauses.push(`${key} = $${paramIndex}`);
      params.push(value);
      paramIndex++;
    }

    params.push(entityId);
    const idParam = paramIndex++;
    params.push(expectedVersion);
    const versionParam = paramIndex;

    const sql = `
      UPDATE ${tableName}
      SET ${setClauses.join(', ')}
      WHERE id = $${idParam} AND version = $${versionParam}
      RETURNING id, version, updated_at;
    `.trim();

    return { sql, params };
  }

  /**
   * Executes an operation with Optimistic Concurrency Control (OCC) and automatic decorrelated jitter backoff.
   */
  public async executeWithOCC<T>(
    operationName: string,
    entityId: string,
    action: (attempt: number) => Promise<{ success: boolean; versionMismatch?: boolean; result: T }>,
    options?: OCCExecutionOptions
  ): Promise<T> {
    const opts = { ...this.defaultOptions, ...options };
    let attempt = 0;

    while (attempt <= opts.maxRetries) {
      try {
        const { success, versionMismatch, result } = await action(attempt);
        if (success) {
          if (attempt > 0) {
            this.emit('occ:recovered', { operationName, entityId, attempts: attempt + 1 });
          }
          return result;
        }

        if (versionMismatch) {
          if (attempt === opts.maxRetries) {
            this.emit('occ:exhausted', { operationName, entityId, attempts: attempt + 1 });
            throw new ConcurrencyConflictError(`OCC max retries (${opts.maxRetries}) exhausted for entity ${entityId}`, entityId, -1);
          }

          const sleepMs = this.calculateJitterBackoff(attempt, opts.baseBackoffMs, opts.maxBackoffMs);
          this.emit('occ:retry', { operationName, entityId, attempt: attempt + 1, sleepMs });
          await this.sleep(sleepMs);
          attempt++;
          continue;
        }

        return result;
      } catch (err: any) {
        // Detect PostgreSQL Serialization Failure (40001) or Deadlock Detected (40P01)
        if (err.code === '40001' || err.code === '40P01' || err.name === 'SerializationFailureError') {
          if (attempt === opts.maxRetries) {
            this.emit('serialization:exhausted', { operationName, entityId, attempts: attempt + 1, code: err.code });
            throw err;
          }
          const sleepMs = this.calculateJitterBackoff(attempt, opts.baseBackoffMs, opts.maxBackoffMs);
          this.emit('serialization:retry', { operationName, entityId, attempt: attempt + 1, sleepMs, code: err.code });
          await this.sleep(sleepMs);
          attempt++;
          continue;
        }
        throw err;
      }
    }

    throw new ConcurrencyConflictError(`OCC max retries exhausted for entity ${entityId}`, entityId, -1);
  }

  /**
   * Generates a non-blocking queue consumer query using FOR UPDATE SKIP LOCKED.
   */
  public buildQueuePollQuery(queueTable: string, batchSize: number): string {
    return `
      WITH claimable_tasks AS (
        SELECT id
        FROM ${queueTable}
        WHERE status = 'pending'
        ORDER BY priority DESC, created_at ASC
        LIMIT ${Math.max(1, Math.min(batchSize, 500))}
        FOR UPDATE SKIP LOCKED
      )
      UPDATE ${queueTable}
      SET status = 'processing',
          locked_at = NOW(),
          attempts = attempts + 1
      WHERE id IN (SELECT id FROM claimable_tasks)
      RETURNING id, payload, status, attempts, locked_at;
    `.trim();
  }

  /**
   * Full jitter decorrelated exponential backoff: sleep = Uniform(0, min(maxBackoff, base * 2^attempt))
   */
  private calculateJitterBackoff(attempt: number, baseMs: number, maxMs: number): number {
    const exponential = Math.min(maxMs, baseMs * Math.pow(2, attempt));
    return Math.floor(Math.random() * exponential);
  }

  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
```

---

## 4. The 6-State Concurrency & Transaction Lifecycle Finite-State Machine (FSM)

Every concurrent state transition MUST follow this deterministic finite-state machine to prevent lock leaks, deadlocks, and silent data corruption:

```
               ┌───────────────────────┐
               │         IDLE          │
               └───────────┬───────────┘
                           │ BEGIN (Sort IDs lexicographically)
                           ▼
               ┌───────────────────────┐
               │    VALIDATING_KEYS    │◄──────────────┐
               └───────────┬───────────┘               │
                           │ IDs sorted & verified      │
                           ▼                           │
               ┌───────────────────────┐               │
        ┌─────►│    ACQUIRING_LOCKS    │               │
        │      │ (OCC Read or Locking) │               │
        │      └───────────┬───────────┘               │
        │                  │ Locks held or Snapshot    │
        │                  ▼                           │
        │      ┌───────────────────────┐               │
        │      │  EXECUTING_MUTATION   │               │
        │      └───────────┬───────────┘               │
        │                  │ Mutation ready            │
        │                  ▼                           │
        │      ┌───────────────────────┐               │
        │      │      COMMITTING       │               │
        │      └───────────┬───────────┘               │
        │                  │                           │
        │  OCC Version     │ 40001 / Version Mismatch  │
        │  Retry / Backoff └───────────────────────────┤
        └──────────────────────────────────────────────┘
                           │ Clean Commit
                           ▼
               ┌───────────────────────┐
               │       COMPLETED       │
               └───────────────────────┘
```

### State Transition Invariant Table

| Current State | Target State | Trigger / Condition | Mandatory Action / Guard | Error State Fallback |
| :--- | :--- | :--- | :--- | :--- |
| `IDLE` | `VALIDATING_KEYS` | Transaction requested | Extract all target resource IDs; sort lexicographically | `ABORTED` (Invalid IDs) |
| `VALIDATING_KEYS` | `ACQUIRING_LOCKS` | Keys strictly sorted | If pessimistic: `SELECT ... FOR UPDATE` in sorted order; If OCC: read `version` | `ROLLED_BACK` (Lock timeout) |
| `ACQUIRING_LOCKS` | `EXECUTING_MUTATION` | Resource locks held | Execute in-memory mutations; ZERO external network I/O | `ROLLED_BACK` (Statement error) |
| `EXECUTING_MUTATION` | `COMMITTING` | SQL mutation applied | Verify `rows_affected == 1` for OCC or check constraints | `CONFLICT_BACKOFF` (Rows == 0) |
| `COMMITTING` | `CONFLICT_BACKOFF` | SQL error `40001` or `version` mismatch | `ROLLBACK`; calculate full jitter sleep: `Uniform(0, min(max, base*2^k))` | `ABORTED` (Max retries hit) |
| `CONFLICT_BACKOFF` | `ACQUIRING_LOCKS` | Jitter backoff elapsed | Re-read fresh state and fresh version number | `ABORTED` (Context timeout) |
| `COMMITTING` | `COMPLETED` | PostgreSQL `COMMIT` successful | Release connection to pool; emit metric `tx.commit.success` | `ROLLED_BACK` (Commit failure) |

---

## 5. Technology-Specific Production Patterns

### 5.1 Go (`jackc/pgx/v5`): Deadlock-Free Lexicographical Locking & OCC Version Checks

```go
package repository

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgerrcode"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrConcurrencyConflict = errors.New("concurrency conflict: version mismatch")

type AccountRepo struct {
	pool *pgxpool.Pool
}

// TransferBalance atomically transfers funds between two accounts without deadlocks.
// Enforces strict lexicographical locking order to guarantee zero deadlocks.
func (r *AccountRepo) TransferBalance(ctx context.Context, fromID, toID uuid.UUID, amount int64) error {
	if fromID == toID {
		return errors.New("cannot transfer to identical account")
	}

	// 1. Lexicographical Sorting: Guarantee Wait-For Graph is a DAG
	orderedIDs := []uuid.UUID{fromID, toID}
	sort.Slice(orderedIDs, func(i, j int) bool {
		return orderedIDs[i].String() < orderedIDs[j].String()
	})

	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// 2. Lock rows in strict canonical order
	for _, id := range orderedIDs {
		var dummy int64
		err := tx.QueryRow(ctx, "SELECT balance FROM accounts WHERE id = $1 FOR UPDATE", id).Scan(&dummy)
		if err != nil {
			return fmt.Errorf("lock account %s: %w", id, err)
		}
	}

	// 3. Atomic conditional debit: verifies balance >= amount at database engine boundary
	res, err := tx.Exec(ctx, `
		UPDATE accounts 
		SET balance = balance - $1, updated_at = NOW() 
		WHERE id = $2 AND balance >= $1`,
		amount, fromID)
	if err != nil {
		return fmt.Errorf("debit: %w", err)
	}
	if res.RowsAffected() == 0 {
		return errors.New("insufficient funds or concurrent debit conflict")
	}

	// 4. Credit destination
	_, err = tx.Exec(ctx, "UPDATE accounts SET balance = balance + $1, updated_at = NOW() WHERE id = $2", amount, toID)
	if err != nil {
		return fmt.Errorf("credit: %w", err)
	}

	return tx.Commit(ctx)
}

// UpdateCustomerWithOCC updates customer profile with Optimistic Concurrency Control and exponential jitter retry.
func (r *AccountRepo) UpdateCustomerWithOCC(ctx context.Context, id uuid.UUID, newEmail string, expectedVersion int) error {
	maxRetries := 4
	baseBackoff := 30 * time.Millisecond
	maxBackoff := 1 * time.Second

	for attempt := 0; attempt <= maxRetries; attempt++ {
		tag, err := r.pool.Exec(ctx, `
			UPDATE customers 
			SET email = $1, version = version + 1, updated_at = NOW() 
			WHERE id = $2 AND version = $3`,
			newEmail, id, expectedVersion)

		if err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == pgerrcode.SerializationFailure {
				// Retry on PostgreSQL 40001 serialization failure
				time.Sleep(calculateJitter(attempt, baseBackoff, maxBackoff))
				continue
			}
			return fmt.Errorf("db update: %w", err)
		}

		if tag.RowsAffected() == 0 {
			if attempt == maxRetries {
				return ErrConcurrencyConflict
			}
			// Refresh expectedVersion and retry
			err := r.pool.QueryRow(ctx, "SELECT version FROM customers WHERE id = $1", id).Scan(&expectedVersion)
			if err != nil {
				return fmt.Errorf("refresh version: %w", err)
			}
			time.Sleep(calculateJitter(attempt, baseBackoff, maxBackoff))
			continue
		}

		return nil // Success
	}

	return ErrConcurrencyConflict
}

// ClaimPendingTasks claims queue tasks concurrently with zero worker head-of-line blocking using SKIP LOCKED.
func (r *AccountRepo) ClaimPendingTasks(ctx context.Context, batchSize int) ([]uuid.UUID, error) {
	queryCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	query := `
		WITH claimable AS (
			SELECT id FROM tasks 
			WHERE status = 'pending' 
			ORDER BY priority DESC, created_at ASC 
			LIMIT $1 
			FOR UPDATE SKIP LOCKED
		)
		UPDATE tasks 
		SET status = 'processing', locked_at = NOW(), attempts = attempts + 1 
		WHERE id IN (SELECT id FROM claimable) 
		RETURNING id`

	rows, err := r.pool.Query(queryCtx, query, batchSize)
	if err != nil {
		return nil, fmt.Errorf("claim tasks: %w", err)
	}
	defer rows.Close()

	var claimedIDs []uuid.UUID
	for rows.Next() {
		var id uuid.UUID
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		claimedIDs = append(claimedIDs, id)
	}
	return claimedIDs, rows.Err()
}

func calculateJitter(attempt int, base, max time.Duration) time.Duration {
	exp := base * time.Duration(1<<attempt)
	if exp > max {
		exp = max
	}
	return time.Duration(rand.Int63n(int64(exp)))
}
```

---

### 5.2 PostgreSQL / SQL: Schema Design, Exclusion Constraints & SKIP LOCKED Queues

```sql
-- 1. Optimistic Concurrency Control (OCC) Table Standard
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sku VARCHAR(64) NOT NULL UNIQUE,
    name VARCHAR(255) NOT NULL,
    stock INT NOT NULL CHECK (stock >= 0),
    version INT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tier 0: Single-Statement Atomic Deduction (Zero Read-Modify-Write Race)
UPDATE products 
SET stock = stock - 5,
    version = version + 1,
    updated_at = NOW()
WHERE id = 'a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d'::UUID 
  AND stock >= 5
RETURNING id, stock, version;

-- 2. Declarative Write Skew Prevention: Room Reservation Exclusion Constraint
-- Prevents overlapping room reservations at database engine level without needing application locks!
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE room_reservations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id UUID NOT NULL,
    during TSRANGE NOT NULL,
    reserved_by VARCHAR(255) NOT NULL,
    -- GiST Exclusion: No two rows for the same room can have overlapping time ranges!
    CONSTRAINT no_overlapping_reservations EXCLUDE USING gist (
        room_id WITH =,
        during WITH &&
    )
);

-- 3. High-Throughput Worker Queue Table with SKIP LOCKED Support
CREATE TABLE background_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    queue_name VARCHAR(64) NOT NULL DEFAULT 'default',
    payload JSONB NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    priority INT NOT NULL DEFAULT 0,
    attempts INT NOT NULL DEFAULT 0,
    locked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- High-speed index specifically optimized for FOR UPDATE SKIP LOCKED
CREATE INDEX idx_background_jobs_claim 
ON background_jobs (queue_name, priority DESC, created_at ASC) 
WHERE status = 'pending';

-- Non-Blocking Queue Worker Claim Query
WITH candidate_jobs AS (
    SELECT id 
    FROM background_jobs 
    WHERE queue_name = 'orders' 
      AND status = 'pending' 
    ORDER BY priority DESC, created_at ASC 
    LIMIT 10 
    FOR UPDATE SKIP LOCKED
)
UPDATE background_jobs 
SET status = 'processing',
    locked_at = NOW(),
    attempts = attempts + 1
WHERE id IN (SELECT id FROM candidate_jobs)
RETURNING id, payload, attempts;
```

---

### 5.3 TypeScript (Drizzle ORM): Type-Safe OCC Updates & Conflict Handling

```typescript
import { eq, and, sql } from 'drizzle-orm';
import { db } from './db';
import { products } from './schema';

export async function updateProductStockOCC(
  productId: string,
  deductQuantity: number,
  expectedVersion: number
): Promise<{ success: boolean; newVersion?: number }> {
  // Atomic OCC update with version increment & stock check
  const result = await db
    .update(products)
    .set({
      stock: sql`${products.stock} - ${deductQuantity}`,
      version: sql`${products.version} + 1`,
      updatedAt: sql`NOW()`,
    })
    .where(
      and(
        eq(products.id, productId),
        eq(products.version, expectedVersion),
        sql`${products.stock} >= ${deductQuantity}`
      )
    )
    .returning({ id: products.id, version: products.version, stock: products.stock });

  if (result.length === 0) {
    // Zero rows affected indicates version mismatch OR stock insufficient!
    return { success: false };
  }

  return { success: true, newVersion: result[0].version };
}
```

---

## 6. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

Before any transactional code, database repository, worker queue consumer, or entity mutation PR is merged, it MUST satisfy all six machine-verifiable gates:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   MACHINE-VERIFIABLE DEFINITION OF DONE                     │
├──────┬───────────────────────────────┬──────────────────────────────────────┤
│ Gate │ Verification Rule             │ Inspection Command / Automated Check │
├──────┼───────────────────────────────┼──────────────────────────────────────┤
│  1   │ Zero In-Memory Lost Updates   │ ast-grep --pattern 'stock = $x - $y' │
│  2   │ Monotonic Version Epoch (OCC) │ grep -rn "version = version + 1" src/│
│  3   │ Canonical Key Lock Ordering   │ AST verify sort(ids) prior to FOR UPD│
│  4   │ Mandatory SKIP LOCKED / NOWAIT│ grep -rn "FOR UPDATE" src/ | !grep   │
│  5   │ Zero Network I/O in Locked TX │ Static analysis: no fetch/http in tx │
│  6   │ Automated 40001 Retry Loop    │ Unit test: mock 40001 triggers retry │
└──────┴───────────────────────────────┴──────────────────────────────────────┘
```

- **Gate 1: Zero In-Memory Lost Updates (AST Verification)**:
  - Application code MUST NOT fetch numeric balances/stocks, perform mathematical operations in JavaScript/Python/Go memory, and blindly write back the result.
  - Verification: `ast-grep` or linter checks ensuring numeric adjustments execute via `SET col = col +/- :delta WHERE col >= :delta` or OCC version constraints.

- **Gate 2: Monotonic Version Epoch on Multi-User Entities**:
  - All mutable entities accessible via user-facing REST/tRPC/GraphQL APIs MUST possess a `version INT NOT NULL DEFAULT 1` column.
  - Updates MUST verify `WHERE version = :expected` and increment `version = version + 1`.

- **Gate 3: Canonical Key Lock Ordering Invariant**:
  - Any transaction acquiring pessimistic locks on multiple rows via `SELECT ... FOR UPDATE` MUST explicitly sort the primary keys prior to query execution.

- **Gate 4: Mandatory `SKIP LOCKED` or `NOWAIT` on Queue Workers**:
  - Background worker queries querying pending tasks with `FOR UPDATE` MUST include `SKIP LOCKED` or `NOWAIT`. Raw `LIMIT N FOR UPDATE` is strictly prohibited.

- **Gate 5: Zero Network I/O in Active Locked Transactions**:
  - Static code analysis MUST verify that no HTTP requests, LLM API calls, Stripe charges, or third-party I/O occur between `BEGIN` and `COMMIT` of transactions holding row locks.

- **Gate 6: Automated Serialization Failure (`40001`) Retry Loop**:
  - Transactions configured with `SERIALIZABLE` or `REPEATABLE READ` MUST be wrapped in an automated retry handler capable of catching PostgreSQL error code `40001` and retrying with full jitter.

---

## 7. Anti-Patterns vs Industrial Invariants

| Anti-Pattern (Vulnerable Code) | Root Failure Mode | Industrial Invariant (Production Standard) | Impact / Benefit |
| :--- | :--- | :--- | :--- |
| `SELECT balance ...; UPDATE balance = balance - 100` | Lost Update: concurrent writes silently overwrite each other | `UPDATE accounts SET balance = balance - 100 WHERE id = $1 AND balance >= 100 RETURNING balance;` | 0ms lock hold, 100% race-free atomic database mutation |
| `SELECT * FROM tasks WHERE status='pending' LIMIT 1 FOR UPDATE;` | Head-of-Line Worker Blocking: $W$ workers serialize behind row 1 | `SELECT * FROM tasks WHERE status='pending' ORDER BY priority DESC LIMIT 1 FOR UPDATE SKIP LOCKED;` | Linear worker horizontal scalability $\Theta(W)$, zero worker queue lock stalls |
| Locking Transfer: Account A then B (Worker 1) vs B then A (Worker 2) | Cyclic Wait-For Graph: PostgreSQL `ERROR: 40P01 deadlock detected` | Sort account IDs lexicographically (`sort(ids)`) before locking | Deadlocks mathematically eliminated ($P(\text{deadlock}) = 0$) |
| Multi-user REST update: `UPDATE users SET name = $1 WHERE id = $2` | Stale Overwrite: user A overwrites user B's concurrent edit | Monotonic versioning: `WHERE id = $1 AND version = $2 SET version = version + 1` | `409 Conflict` on race, guarantees data integrity |
| Checking Doctor On-Call count under `REPEATABLE READ` | Write Skew Anomaly: disjoint writes bypass snapshot isolation | Elevation to `SERIALIZABLE` with `40001` retry OR PostgreSQL `EXCLUDE USING gist` | Zero phantom schedule violations or double bookings |
| Calling `stripe.charges.create()` inside transaction holding `FOR UPDATE` | Connection Pool Starvation: slow 1,500ms network call locks DB pool | Complete network I/O prior to transaction or execute asynchronously via Outbox | Connection pool hold time drops from 1,500ms to <2ms |
| Unbounded retries without jitter on OCC conflict | Retrying in lockstep triggers persistent live-lock retry storm | Full Decorrelated Jitter: `Uniform(0, min(max, base * 2^attempt))` | Resolves conflicts within 1-2 attempts, avoids thundering herd |
| Blindly ignoring `RowsAffected() == 0` on conditional update | Silent Failure: application assumes update succeeded when balance was low | Explicit check: if `rows == 0` throw `InsufficientFundsError` or `ConflictError` | Fail-fast correctness, zero phantom order fulfillment |
