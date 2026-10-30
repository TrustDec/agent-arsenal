---
description: PostgreSQL row-level locking modes, FOR NO KEY UPDATE vs FOR UPDATE, foreign key KEY SHARE contention elimination, MultiXactId SLRU bloat & autovacuum freeze defense, lock upgrade deadlock elimination (FOR SHARE to UPDATE), and non-blocking wait modes (NOWAIT, SKIP LOCKED) across Go (pgx/sqlc), TypeScript (Drizzle, Prisma, Kysely), Python (SQLAlchemy, asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{lock,mutex,concurrency,transaction,row,update,order,inventory,account,ledger,repo,repository,store}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Row-Level Locking, FOR NO KEY UPDATE vs FOR UPDATE, Foreign Key KEY SHARE Contention & MultiXact Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design transactional data mutations, inventory allocations, financial ledger balance deductions, reservation locks, background task pipelines, or parent-child entity workflows across PostgreSQL, Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`). Eliminate the "Parent `FOR UPDATE` vs Child Foreign Key `FOR KEY SHARE` Starvation Avalanche" (where locking a parent row with naive `FOR UPDATE` blocks all concurrent child foreign key validation inserts across the entire cluster, collapsing throughput from 30,000 TPS to <100 TPS), the "Lock Upgrade Deadlock Trap" (where two concurrent transactions acquire `FOR SHARE` and then attempt to `UPDATE`, creating an unresolvable cyclic wait-for condition that terminates with SQLSTATE `40P01 deadlock_detected`), the "MultiXactId Member & Offset SLRU Exhaustion Storm" (where high-concurrency shared locks spawn millions of MultiXact entries in `pg_multixact`, saturating SLRU control locks and driving the database toward emergency autovacuum wraparound freezing), the "TupleLock Queueing & Connection Pool Collapse" (where unbounded row-lock queues hold database worker connections indefinitely in FIFO wait, exhausting the pool in $< 3$ seconds), the "Long-Lived Lock Network I/O Fence Breach" (where agents hold row locks across slow external Stripe, LLM, or gRPC network calls), and the "ORM Abstraction Blindness" (where ORMs default to heavy exclusive locks when non-key updates require only weak exclusive locks) by establishing a strict 5-Tier Row-Level Locking Governance Ladder, mathematical lock compatibility proofs, production TypeScript guard engines, and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Row-Level Locking Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL (9.3+), row-level concurrency control provides four distinct lock modes:
1. `FOR KEY SHARE` (`LockTupleKeyShare`): Acquired implicitly by foreign key referential integrity checks during child `INSERT` or `UPDATE`.
2. `FOR SHARE` (`LockTupleShare`): Shared read lock, preventing modifications without modifying keys.
3. `FOR NO KEY UPDATE` (`LockTupleNoKeyExclusive`): Weak exclusive lock, acquired implicitly by `UPDATE` statements that do NOT modify any primary key or unique index columns.
4. `FOR UPDATE` (`LockTupleExclusive`): Strong exclusive lock, acquired by `DELETE`, or `UPDATE` touching primary key/unique columns, or explicit `SELECT ... FOR UPDATE`.

When autonomous coding agents write transactional business logic, LLMs almost universally default to `SELECT ... FOR UPDATE`, triggering severe production lock contention:

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: NAIVE FOR UPDATE ON PARENT RECORD
-- Transaction A locks account to deduct balance (a non-key column):
BEGIN;
SELECT id, balance_cents
FROM accounts
WHERE id = 'acc_123'
FOR UPDATE; -- ❌ Takes LockTupleExclusive!

-- Concurrently, Transaction B inserts a new transaction record for this account:
-- PostgreSQL must verify: accounts(id) exists!
-- Child insert implicitly requests: LockTupleKeyShare on accounts WHERE id = 'acc_123'!
INSERT INTO account_transactions (id, account_id, amount_cents)
VALUES (gen_random_uuid(), 'acc_123', 500);
-- ❌ BLOCKED! LockTupleExclusive CONFLICTS WITH LockTupleKeyShare!
-- All child inserts across the company freeze until Transaction A commits!
```

```sql
-- ✅ PRODUCTION INVARIANT: FOR NO KEY UPDATE ALLOWS CONCURRENT CHILD INSERTS
-- Transaction A:
BEGIN;
SELECT id, balance_cents
FROM accounts
WHERE id = 'acc_123'
FOR NO KEY UPDATE; -- ✅ Weak exclusive lock (LockTupleNoKeyExclusive)

-- Transaction B (child insert requesting LockTupleKeyShare):
INSERT INTO account_transactions (id, account_id, amount_cents)
VALUES (gen_random_uuid(), 'acc_123', 500);
-- ✅ PROCEEDS CONCURRENTLY WITH ZERO WAIT!
-- LockTupleNoKeyExclusive is 100% COMPATIBLE with LockTupleKeyShare!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE LOCK UPGRADE DEADLOCK TRAP
-- Transaction 1 reads with shared lock:
BEGIN;
SELECT stock FROM products WHERE id = 42 FOR SHARE; -- Acquired LockTupleShare

-- Concurrently, Transaction 2 reads same row with shared lock:
BEGIN;
SELECT stock FROM products WHERE id = 42 FOR SHARE; -- Acquired LockTupleShare (Compatible!)

-- Transaction 1 attempts to deduct stock:
UPDATE products SET stock = stock - 1 WHERE id = 42;
-- ❌ BLOCKED! Waits for Transaction 2 to release LockTupleShare!

-- Transaction 2 attempts to deduct stock:
UPDATE products SET stock = stock - 1 WHERE id = 42;
-- ❌ FATAL DEADLOCK! Transaction 2 waits for Transaction 1!
-- Result: PostgreSQL ERROR: 40P01: deadlock detected!
```

---

### Row-Level Lock Mode Conflict Matrix

| Requested Mode \ Existing Lock | `FOR KEY SHARE` | `FOR SHARE` | `FOR NO KEY UPDATE` | `FOR UPDATE` |
| :--- | :---: | :---: | :---: | :---: |
| **`FOR KEY SHARE`** (Child FK Check) | Compatible (0ms) | Compatible (0ms) | **Compatible (0ms)** | ❌ **CONFLICT (Blocks!)** |
| **`FOR SHARE`** | Compatible (0ms) | Compatible (0ms) | ❌ **CONFLICT (Blocks!)** | ❌ **CONFLICT (Blocks!)** |
| **`FOR NO KEY UPDATE`** (Non-Key Update) | **Compatible (0ms)** | ❌ **CONFLICT (Blocks!)**| ❌ **CONFLICT (Blocks!)**| ❌ **CONFLICT (Blocks!)** |
| **`FOR UPDATE`** (Key Update / Delete) | ❌ **CONFLICT (Blocks!)**| ❌ **CONFLICT (Blocks!)**| ❌ **CONFLICT (Blocks!)**| ❌ **CONFLICT (Blocks!)** |

---

### The 5-Tier Row-Level Locking Governance Ladder

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Tier 5: Sub-Second lock_timeout Ladders, MultiXact SLRU & mxid Age Watchdogs     │
│   - SET LOCAL lock_timeout = '2000ms'; SET LOCAL statement_timeout = '5000ms'   │
│   - Continuous audit of age(datminmxid) < 200,000,000 before emergency freeze   │
├─────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Non-Blocking Wait Modes (NOWAIT & SKIP LOCKED)                          │
│   - Interactive mutations: FOR NO KEY UPDATE NOWAIT -> fail-fast HTTP 409       │
│   - Task dispatchers: FOR UPDATE SKIP LOCKED -> linear worker throughput        │
├─────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Immediate Exclusive Read (Zero Shared-to-Exclusive Lock Upgrades)       │
│   - NEVER execute FOR SHARE or FOR KEY SHARE before an UPDATE in same tx        │
│   - Always acquire FOR NO KEY UPDATE immediately on initial read                │
├─────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Precision Lock Mode Selection (FOR NO KEY UPDATE vs FOR UPDATE)          │
│   - Non-key column mutations MUST use FOR NO KEY UPDATE                         │
│   - FOR UPDATE exclusively reserved for primary key / unique column updates     │
├─────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Single-Statement Atomic Mutations (Zero Multi-Turn Explicit Locks)      │
│   - Single-statement UPDATE ... WHERE ... RETURNING * eliminates lock overhead  │
│   - Zero network round-trips while holding open tuple locks                     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Invariants & Physical Lock Contention Models

### 2.1 The Foreign Key Concurrency Gain Theorem

Let $\lambda_{\text{child}}$ be the arrival rate of child row insertions (e.g., transactions, order items) requiring `FOR KEY SHARE` on a parent tuple.
Let $T_{\text{parent}}$ be the transaction holding duration for a parent update.

Under naive `FOR UPDATE`:
Because $\text{Conflict}(\text{FOR UPDATE}, \text{FOR KEY SHARE}) = 1$, child transactions are queued behind the parent transaction.
By Little's Law, the mean number of blocked child workers $Q_{\text{blocked}}$ is:
$$Q_{\text{blocked}} = \lambda_{\text{child}} \cdot T_{\text{parent}}$$

If $\lambda_{\text{child}} = 500\text{ req/s}$ and $T_{\text{parent}} = 20\text{ms} = 0.02\text{s}$:
$$Q_{\text{blocked}} = 500 \cdot 0.02 = 10\text{ concurrent database connections pinned}$$

Under `FOR NO KEY UPDATE`:
Because $\text{Conflict}(\text{FOR NO KEY UPDATE}, \text{FOR KEY SHARE}) = 0$:
$$Q_{\text{blocked}} = 0$$
$$\Delta \text{Latency}_{\text{child}} = 0\text{ms}$$

**Theorem (Lock Mode Downgrading Invariance)**:
For any relational update $\mathcal{U}$ where the mutated column set $\mathcal{C}_{\text{mutated}}$ satisfies:
$$\mathcal{C}_{\text{mutated}} \cap \mathcal{C}_{\text{unique\_keys}} = \emptyset$$
the tuple lock mode $\mathcal{M}$ satisfies:
$$\mathcal{M} = \text{LockTupleNoKeyExclusive} \implies \forall \text{ child insert } \mathcal{I}, \quad \text{Wait}(\mathcal{I}, \mathcal{U}) = 0$$

---

### 2.2 The Lock Upgrade Deadlock Probability Model

Let $N$ concurrent transactions read the same row with shared lock $\mathcal{S}$ (`FOR SHARE`), and subsequently attempt an `UPDATE` requiring exclusive lock $\mathcal{X}$.
The probability of deadlock detection $P(\text{Deadlock})$ across $N \ge 2$ concurrent workers is:
$$P(\text{Deadlock} \mid N \ge 2) = 1.0$$

**Proof**:
1. All $N$ transactions acquire $\mathcal{S}$ simultaneously because $\text{Conflict}(\mathcal{S}, \mathcal{S}) = 0$.
2. To execute `UPDATE`, any transaction $T_i$ must acquire $\mathcal{X}$.
3. $\text{Conflict}(\mathcal{X}, \mathcal{S}) = 1 \implies T_i$ cannot acquire $\mathcal{X}$ until all $T_j$ ($j \ne i$) commit or abort.
4. Each $T_j$ also requests $\mathcal{X}$ and waits for $T_i$.
5. The Wait-For Graph contains cycles for all pairs $(T_i, T_j)$.
6. Therefore, at least $N - 1$ transactions are aborted by PostgreSQL's deadlock detector with SQLSTATE `40P01`.

**Invariant**:
$$\text{If } \exists \text{ mutation in } T, \quad \text{LockMode}_{\text{initial}}(T) \ge \text{LockTupleNoKeyExclusive}$$

---

### 2.3 MultiXactId Member Growth & SLRU Queue Collapse

In PostgreSQL, a heap tuple's header allocates 32 bits for `t_xmax` and 16 bits for `t_infomask`.
When multiple transactions acquire shared locks on the same row, PostgreSQL sets:
$$\text{t\_infomask} \mathrel{\&}= \text{HEAP\_XMAX\_IS\_MULTI} \quad (0\text{x}1000)$$
and writes a `MultiXactId` into `t_xmax`.

The MultiXact subsystem records members in SLRU buffers:
- `pg_multixact/offsets`: maps `MultiXactId` to offset in members log.
- `pg_multixact/members`: list of transaction IDs comprising the MultiXact.

Under hot-parent child insertions, the rate of MultiXact creation is:
$$R_{\text{mxid}} = \frac{d(\text{MultiXactId})}{dt} \propto \lambda_{\text{child}} \times N_{\text{concurrent\_locks}}$$

When the oldest unvacuumed MultiXact ID age exceeds threshold:
$$\text{age}(datminmxid) \ge \text{autovacuum\_multixact\_freeze\_max\_age} \quad (\text{default: } 400,000,000)$$
PostgreSQL enters emergency wraparound freeze mode, taking disruptive locks and consuming all storage I/O bandwidth.

---

### 2.4 The Network I/O Fence Breach Calculus

Let $T_{\text{db}}$ be the database lock duration without external I/O ($\approx 2\text{ms}$).
Let $T_{\text{ext}}$ be external network API latency (Stripe, OpenAI, OAuth) ($\approx 800\text{ms}$).

The connection pool starvation multiplier $M_{\text{starve}}$ is:
$$M_{\text{starve}} = \frac{T_{\text{db}} + T_{\text{ext}}}{T_{\text{db}}} = \frac{2 + 800}{2} = 401\times$$

Holding a row lock across external network calls increases connection hold time by over $400\times$, converting a system capable of 5,000 TPS into an unresponsive cluster at 12 TPS.

---

## 3. Production Engine: TypeScript Implementation

Below is the standalone production TypeScript implementation of the **Agentic Database Row-Level Locking Guard Engine** (`AgenticRowLevelLockGuardEngine`). It parses SQL statements, detects dangerous lock upgrades, identifies parent-child `FOR UPDATE` hazards, enforces `FOR NO KEY UPDATE` for non-key mutations, and provides resilient execution wrappers handling SQLSTATE `55P03` (lock not available) and `40P01` (deadlock detected).

```typescript
// agentic-row-level-lock-guard.ts
import { Pool, PoolClient, QueryResult } from 'pg';

export type LockMode =
  | 'FOR UPDATE'
  | 'FOR NO KEY UPDATE'
  | 'FOR SHARE'
  | 'FOR KEY SHARE';

export type WaitMode = 'BLOCK' | 'NOWAIT' | 'SKIP LOCKED';

export interface LockAnalysisResult {
  sql: string;
  hasLock: boolean;
  lockMode?: LockMode;
  waitMode?: WaitMode;
  isKeyColumnMutated: boolean;
  recommendedLockMode: LockMode;
  hasLockUpgradeRisk: boolean;
  hasFkStarvationRisk: boolean;
  hasMissingTimeoutRisk: boolean;
  transformedSql: string;
  reasons: string[];
}

export interface GuardConfig {
  lockTimeoutMs: number;
  statementTimeoutMs: number;
  maxDeadlockRetries: number;
}

const DEFAULT_CONFIG: GuardConfig = {
  lockTimeoutMs: 2000,
  statementTimeoutMs: 5000,
  maxDeadlockRetries: 3,
};

export class AgenticRowLevelLockGuardEngine {
  private config: GuardConfig;

  constructor(config: Partial<GuardConfig> = {}) {
    this.config = { ...DEFAULT_CONFIG, ...config };
  }

  /**
   * Static Analysis: Inspects SQL statements to identify lock modes, FK hazards,
   * and recommends precision lock modes (e.g. FOR NO KEY UPDATE).
   */
  public analyzeLockStatement(
    sql: string,
    mutatedColumns: string[] = [],
    uniqueKeyColumns: string[] = ['id', 'uuid', 'email', 'code']
  ): LockAnalysisResult {
    const upper = sql.toUpperCase();
    const reasons: string[] = [];

    // 1. Detect explicit lock mode
    let lockMode: LockMode | undefined;
    if (upper.includes('FOR UPDATE')) lockMode = 'FOR UPDATE';
    else if (upper.includes('FOR NO KEY UPDATE')) lockMode = 'FOR NO KEY UPDATE';
    else if (upper.includes('FOR SHARE')) lockMode = 'FOR SHARE';
    else if (upper.includes('FOR KEY SHARE')) lockMode = 'FOR KEY SHARE';

    const hasLock = !!lockMode;

    // 2. Detect wait mode
    let waitMode: WaitMode = 'BLOCK';
    if (upper.includes('NOWAIT')) waitMode = 'NOWAIT';
    else if (upper.includes('SKIP LOCKED')) waitMode = 'SKIP LOCKED';

    // 3. Determine if unique/primary key columns are being mutated
    const isKeyColumnMutated = mutatedColumns.some((col) =>
      uniqueKeyColumns.map((k) => k.toLowerCase()).includes(col.toLowerCase())
    );

    let recommendedLockMode: LockMode = 'FOR NO KEY UPDATE';
    let hasFkStarvationRisk = false;
    let hasLockUpgradeRisk = false;

    if (lockMode === 'FOR SHARE' || lockMode === 'FOR KEY SHARE') {
      hasLockUpgradeRisk = true;
      reasons.push(
        'CRITICAL: FOR SHARE or FOR KEY SHARE held prior to mutation triggers deterministic 40P01 deadlock on concurrent writes.'
      );
      recommendedLockMode = isKeyColumnMutated ? 'FOR UPDATE' : 'FOR NO KEY UPDATE';
    } else if (lockMode === 'FOR UPDATE' && !isKeyColumnMutated) {
      hasFkStarvationRisk = true;
      reasons.push(
        'WARNING: FOR UPDATE conflicts with child foreign key validation (LockTupleKeyShare). Use FOR NO KEY UPDATE since no key columns are modified.'
      );
      recommendedLockMode = 'FOR NO KEY UPDATE';
    } else if (isKeyColumnMutated) {
      recommendedLockMode = 'FOR UPDATE';
    }

    const hasMissingTimeoutRisk = waitMode === 'BLOCK';
    if (hasMissingTimeoutRisk) {
      reasons.push(
        'NOTICE: Bare blocking lock detected. Must be executed with transaction-scoped lock_timeout or converted to NOWAIT / SKIP LOCKED.'
      );
    }

    // Auto-transform SQL to recommended mode
    let transformedSql = sql;
    if (hasFkStarvationRisk && lockMode === 'FOR UPDATE') {
      transformedSql = sql.replace(/FOR\s+UPDATE/i, 'FOR NO KEY UPDATE');
    } else if (hasLockUpgradeRisk) {
      transformedSql = sql.replace(/FOR\s+(KEY\s+)?SHARE/i, recommendedLockMode);
    }

    return {
      sql,
      hasLock,
      lockMode,
      waitMode,
      isKeyColumnMutated,
      recommendedLockMode,
      hasLockUpgradeRisk,
      hasFkStarvationRisk,
      hasMissingTimeoutRisk,
      transformedSql,
      reasons,
    };
  }

  /**
   * Resilient Transaction Execution: Executes transactional mutation with
   * sub-second timeout ladders, 55P03 lock-unavailable fast-fail, and 40P01 deadlock retries.
   */
  public async executeWithGuardedLock<T>(
    pool: Pool,
    operation: (client: PoolClient) => Promise<T>,
    customConfig?: Partial<GuardConfig>
  ): Promise<T> {
    const cfg = { ...this.config, ...customConfig };
    let attempt = 0;

    while (attempt <= cfg.maxDeadlockRetries) {
      attempt++;
      const client = await pool.connect();

      try {
        await client.query('BEGIN;');
        // Enforce sub-second lock and statement timeout ladders
        await client.query(`SET LOCAL lock_timeout = '${cfg.lockTimeoutMs}ms';`);
        await client.query(`SET LOCAL statement_timeout = '${cfg.statementTimeoutMs}ms';`);

        const result = await operation(client);

        await client.query('COMMIT;');
        return result;
      } catch (err: any) {
        await client.query('ROLLBACK;').catch(() => {});

        // SQLSTATE 55P03: lock_not_available (NOWAIT triggered)
        if (err?.code === '55P03') {
          throw new LockUnavailableError(
            `Resource is locked by another concurrent transaction (55P03). Fail-fast active.`
          );
        }

        // SQLSTATE 40P01: deadlock_detected -> Exponential Jitter Retry
        if (err?.code === '40P01' && attempt <= cfg.maxDeadlockRetries) {
          const jitterBackoff = Math.floor(Math.random() * (100 * Math.pow(2, attempt)));
          await new Promise((resolve) => setTimeout(resolve, jitterBackoff));
          continue;
        }

        // SQLSTATE 57014: query_canceled / statement_timeout or lock_timeout
        if (err?.code === '57014') {
          throw new LockTimeoutError(
            `Lock acquisition timed out after ${cfg.lockTimeoutMs}ms (57014). Connection preserved.`
          );
        }

        throw err;
      } finally {
        client.release();
      }
    }

    throw new Error(`Transaction failed after ${cfg.maxDeadlockRetries} deadlock retries.`);
  }

  /**
   * Database Diagnostic Query: Inspects active tuple lock contention and MultiXact horizon.
   */
  public static getLockContentionAuditSql(): string {
    return `
      -- Continuous Audit for TupleLock Contention & MultiXact Age
      SELECT
        l.pid,
        a.usename,
        a.client_addr,
        l.locktype,
        l.mode,
        l.granted,
        wait_event_type,
        wait_event,
        now() - a.query_start AS duration,
        a.query
      FROM pg_locks l
      JOIN pg_stat_activity a ON l.pid = a.pid
      WHERE l.locktype IN ('relation', 'tuple', 'transactionid', 'multixactid')
        AND a.pid <> pg_backend_pid()
      ORDER BY duration DESC;
    `;
  }

  public static getMultiXactAgeAuditSql(): string {
    return `
      -- Audit MultiXact Wraparound Headroom
      SELECT
        datname,
        datminmxid,
        age(datminmxid) AS multixact_age,
        2147483648 - age(datminmxid) AS mxid_headroom_remaining
      FROM pg_database
      WHERE datname = current_database();
    `;
  }
}

export class LockUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LockUnavailableError';
  }
}

export class LockTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LockTimeoutError';
  }
}
```

---

## 4. The 6-State Row-Level Locking Finite-State Machine (FSM)

```
       ┌────────────────────────┐
       │      1. UNLOCKED       │
       └───────────┬────────────┘
                   │ Acquire with SET LOCAL lock_timeout <= 2000ms
                   │ Mode: FOR NO KEY UPDATE (or NOWAIT / SKIP LOCKED)
                   ▼
       ┌────────────────────────┐
       │   2. LOCK_REQUESTED    ├──────────────────────────┐
       └───────────┬────────────┘                          │
                   │ Lock Granted                          │ Timeout / Busy
                   ▼                                       │ (57014 / 55P03)
       ┌────────────────────────┐                          │
       │    3. ROW_ACQUIRED     │                          │
       └───────────┬────────────┘                          │
                   │ Direct In-Memory Mutation             │
                   │ (NO External Network I/O!)            │
                   ▼                                       │
       ┌────────────────────────┐                          │
       │      4. MUTATING       ├───────────┐              │
       └───────────┬────────────┘           │              │
                   │ UPDATE ... WHERE       │ 40P01        │
                   │ Primary Key Unaltered  │ Deadlock     │
                   ▼                        ▼              ▼
       ┌────────────────────────┐    ┌─────────────────────────┐
       │     5. COMMITTED       │    │  6. FAILED_OR_ABORTED   │
       │ (Locks Released, 0ms)  │    │  (Rollback, Retry/409)  │
       └────────────────────────┘    └─────────────────────────┘
```

### State Transitions & Mathematical Assertions
1. **`UNLOCKED` $\to$ `LOCK_REQUESTED`**:
   - MUST inject `SET LOCAL lock_timeout = '2000ms'` prior to lock statement.
   - Lock mode MUST be `FOR NO KEY UPDATE` unless unique index keys are mutated.
   - Anti-Pattern: NEVER emit `FOR SHARE` if the transaction plans to update this record.
2. **`LOCK_REQUESTED` $\to$ `ROW_ACQUIRED`**:
   - If contested and `NOWAIT` is specified, raises SQLSTATE `55P03` immediately ($t < 1\text{ms}$).
   - If contested and blocking, waits at most $T_{\text{lock\_timeout}} \le 2000\text{ms}$.
3. **`ROW_ACQUIRED` $\to$ `MUTATING`**:
   - Zero external HTTP, LLM, or microservice calls while holding the lock.
   - The mutating SQL statement MUST NOT modify unique constraint columns; doing so would silently escalate the lock to `LockTupleExclusive`.
4. **`MUTATING` $\to$ `COMMITTED`**:
   - Commits transaction immediately. All tuple locks released; heap tuple headers updated with committing XID.
5. **`MUTATING` $\to$ `FAILED_OR_ABORTED`**:
   - If PostgreSQL detects deadlock (`40P01`), execute exponential backoff with full decorrelated jitter before retrying.

---

## 5. Machine-Verifiable Definition of Done (DoD) & Anti-Patterns Matrix

| Verification Gate | Diagnostic Inspection Command / Metric | Passing Criteria | Catastrophic Failure Mode Prevented |
| :--- | :--- | :--- | :--- |
| **Gate 1: Precision Lock Mode** | `rg -i "FOR\s+UPDATE" src/ internal/` | 100% of non-key mutations use `FOR NO KEY UPDATE` | Eliminates parent-child foreign key `FOR KEY SHARE` starvation avalanche |
| **Gate 2: Lock Upgrade Prohibition** | AST scan for `FOR SHARE` in transactions containing `UPDATE` | Zero instances of `FOR SHARE` $\to$ `UPDATE` | Eliminates SQLSTATE `40P01` cyclic lock upgrade deadlocks |
| **Gate 3: Timeout Ladder Fencing** | `grep -r "lock_timeout" src/ internal/` | Every lock transaction sets `SET LOCAL lock_timeout <= 2000ms` | Prevents FIFO lock queue connection pool exhaustion |
| **Gate 4: Zero Network I/O Inside Lock** | AST linter checking for `fetch()`, `axios`, `http.Client` inside `db.transaction()` | Zero external HTTP / RPC calls between lock and commit | Prevents holding locks across 800ms+ network calls ($400\times$ pool bloat) |
| **Gate 5: MultiXact Age Watchdog** | `SELECT age(datminmxid) FROM pg_database;` | `age(datminmxid) < 200,000,000` | Prevents emergency cluster-wide autovacuum wraparound shutdown |
| **Gate 6: Resilient 55P03 / 40P01 Handlers** | Integration test suite verifying concurrent lock race condition | Raises HTTP 409 on `55P03` (`NOWAIT`) and succeeds within 3 retries on `40P01` | Prevents unhandled 500 errors during peak concurrent inventory / ledger updates |

---

## 6. Multi-Language Production Invariants

### 6.1 PostgreSQL SQL / DDL Invariants
```sql
-- 1. Precision Row Locking: FOR NO KEY UPDATE
-- Allows concurrent child transactions to insert foreign keys without blocking!
BEGIN;
SET LOCAL lock_timeout = '2000ms';

SELECT id, balance_cents, version
FROM user_accounts
WHERE id = $1
FOR NO KEY UPDATE;

UPDATE user_accounts
SET balance_cents = balance_cents - $2,
    version = version + 1,
    updated_at = NOW()
WHERE id = $1;

COMMIT;
```

### 6.2 Go (`jackc/pgx/v5`) Invariant
```go
// internal/store/account_store.go
package store

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type AccountStore struct {
	pool *pgxpool.Pool
}

func NewAccountStore(pool *pgxpool.Pool) *AccountStore {
	return &AccountStore{pool: pool}
}

// DeductBalance performs non-key update using FOR NO KEY UPDATE NOWAIT
// with fail-fast 55P03 handling and jittered 40P01 deadlock retries.
func (s *AccountStore) DeductBalance(ctx context.Context, accountID string, amountCents int64) error {
	const maxRetries = 3

	for attempt := 0; attempt <= maxRetries; attempt++ {
		err := pgx.BeginTxFunc(ctx, s.pool, pgx.TxOptions{IsoLevel: pgx.ReadCommitted}, func(tx pgx.Tx) error {
			// Enforce sub-second lock timeout
			if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2000ms'"); err != nil {
				return fmt.Errorf("set lock_timeout failed: %w", err)
			}

			// Invariant: FOR NO KEY UPDATE does not block concurrent child table FK inserts!
			var currentBalance int64
			query := `
				SELECT balance_cents
				FROM accounts
				WHERE id = $1
				FOR NO KEY UPDATE NOWAIT;
			`
			if err := tx.QueryRow(ctx, query, accountID).Scan(&currentBalance); err != nil {
				return err
			}

			if currentBalance < amountCents {
				return fmt.Errorf("insufficient balance: have %d, need %d", currentBalance, amountCents)
			}

			// Non-key mutation: Primary key 'id' is NOT modified
			updateQuery := `
				UPDATE accounts
				SET balance_cents = balance_cents - $1,
				    updated_at = NOW()
				WHERE id = $2;
			`
			_, err := tx.Exec(ctx, updateQuery, amountCents, accountID)
			return err
		})

		if err == nil {
			return nil
		}

		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) {
			// SQLSTATE 55P03: lock_not_available (NOWAIT contention)
			if pgErr.Code == "55P03" {
				return fmt.Errorf("account %s is concurrently being modified (55P03): %w", accountID, err)
			}
			// SQLSTATE 40P01: deadlock_detected -> Exponential jitter retry
			if pgErr.Code == "40P01" && attempt < maxRetries {
				backoff := time.Duration(10+rand.Intn(50*(1<<attempt))) * time.Millisecond
				select {
				case <-time.After(backoff):
					continue
				case <-ctx.Done():
					return ctx.Err()
				}
			}
		}

		return fmt.Errorf("deduct balance transaction failed: %w", err)
	}

	return fmt.Errorf("deduct balance exceeded max retries on deadlock")
}
```

### 6.3 TypeScript (Drizzle ORM) Invariant
```typescript
// src/repositories/order-repository.ts
import { pgTable, uuid, varchar, integer, timestamp } from 'drizzle-orm/pg-core';
import { sql, eq } from 'drizzle-orm';
import { NodePgDatabase } from 'drizzle-orm/node-postgres';

export const orders = pgTable('orders', {
  id: uuid('id').defaultRandom().primaryKey(),
  tenantId: uuid('tenant_id').notNull(),
  status: varchar('status', { length: 32 }).notNull(),
  amountCents: integer('amount_cents').notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
});

export async function processOrderAllocation(
  db: NodePgDatabase,
  orderId: string,
  newAmount: number
) {
  return await db.transaction(async (tx) => {
    // 1. Multi-tier lock timeout fence
    await tx.execute(sql`SET LOCAL lock_timeout = '2000ms';`);

    // 2. FOR NO KEY UPDATE: Allows concurrent order_items inserts to pass FK checks!
    const [order] = await tx
      .select({ id: orders.id, amount: orders.amountCents, status: orders.status })
      .from(orders)
      .where(eq(orders.id, orderId))
      .for('no key update'); // ✅ Invariant: Weak exclusive lock

    if (!order) {
      throw new Error(`Order ${orderId} not found`);
    }

    // 3. Mutate non-key attributes safely
    await tx
      .update(orders)
      .set({
        amountCents: newAmount,
        updatedAt: new Date(),
      })
      .where(eq(orders.id, orderId));

    return { orderId, success: true };
  });
}
```

### 6.4 Python (`SQLAlchemy 2.0`) Invariant
```python
# src/repositories/inventory_repository.py
from sqlalchemy import select, update, text
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.exc import DBAPIError
import asyncio
import random

async def deduct_inventory_item(
    session: AsyncSession,
    item_id: str,
    quantity: int
) -> bool:
    max_retries = 3
    for attempt in range(max_retries):
        try:
            async with session.begin_nested():
                # Set sub-second lock timeout
                await session.execute(text("SET LOCAL lock_timeout = '2000ms';"))

                # Invariant: with_for_update(key_share=False, read=False, nowait=True) -> FOR NO KEY UPDATE NOWAIT
                # Note: In SQLAlchemy 2.0 postgresql dialect:
                # with_for_update(mode="no_key_update", nowait=True)
                stmt = (
                    select(InventoryItem)
                    .where(InventoryItem.id == item_id)
                    .with_for_update(mode="no_key_update", nowait=True)
                )
                result = await session.execute(stmt)
                item = result.scalar_one_or_none()

                if not item or item.stock < quantity:
                    return False

                item.stock -= quantity
                await session.flush()
                return True

        except DBAPIError as ex:
            pg_code = getattr(ex.orig, "pgcode", None)
            if pg_code == "55P03":  # lock_not_available
                raise RuntimeError(f"Item {item_id} currently locked by another worker.")
            if pg_code == "40P01" and attempt < max_retries - 1:  # deadlock_detected
                backoff = random.uniform(0.01, 0.05 * (2 ** attempt))
                await asyncio.sleep(backoff)
                continue
            raise
    return False
```
