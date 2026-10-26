---
description: Agentic zero-downtime database migrations, 4-phase Expand-Contract pattern, non-blocking concurrent indexes, DDL lock_timeout safety, chunked cursor backfills, shadow tables, and backward-compatible ORM schema evolution across Claude Code, Cursor, Windsurf, Devin, and Pi
globs: **/*{migration,migrate,schema,ddl,alter,seed,backfill}*.*,**/migrations/**,**/db/**,**/database/**,**/*.sql,**/*.prisma,**/rules/**,**/.cursorrules,**/CLAUDE.md,**/AGENTS.md,**/.agents/**
alwaysApply: false
---

# Agentic Zero-Downtime Database Migrations, Schema Evolution & Lock-Free Data Backfilling

> Add these rules to your project when designing, generating, executing, or auditing database migrations, schema transformations, and data backfills with autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode). Eliminate the "Monolithic DDL Lock Trap" ($O(N)$ connection pool collapse where unconstrained `ALTER TABLE` locks production), the "Breaking Deploy-First Desynchronization Disaster" (where renamed or deleted columns crash running application pods), and the "Unbatched Backfill WAL Saturation Outage" by enforcing a strict 4-Phase Expand-Contract Migration Ladder, mandatory `lock_timeout` boundaries, non-blocking concurrent index and constraint verification, and cursor-based rate-limited asynchronous backfilling with replication lag sentinels.

---

## 1. Architectural Taxonomy: The Naive DDL Trap vs The 4-Phase Expand-Contract Migration Ladder

In high-concurrency production systems, modifying relational database schemas (PostgreSQL, MySQL, CockroachDB, SQLite) is a distributed consensus problem across two asynchronous entities: the **stateful database cluster** and **stateless application service pods**. Naive autonomous coding agents treat schema changes as single-turn atomic scripts, precipitating catastrophic production outages:

- **The Monolithic Table Rewrite Trap ($O(N)$ ACCESS EXCLUSIVE Lock Starvation)**:
  - An agent generates an `ALTER TABLE orders ADD COLUMN fulfillment_status VARCHAR(32) DEFAULT 'pending' NOT NULL;` on a table with 40 million rows.
  - In PostgreSQL (<11) or with volatile default values (`now()`, `gen_random_uuid()`), or in MySQL without `ALGORITHM=INPLACE, LOCK=NONE`, the database rewrites the entire table on disk while holding an `ACCESS EXCLUSIVE` lock.
  - Even if the lock would take only 200ms to acquire, incoming `SELECT`, `UPDATE`, and `INSERT` statements queue behind the requested exclusive lock. Within 5 seconds, all 100 pool connections in `pgbouncer` or HikariCP are blocked waiting for the queue to clear. The API gateway experiences a cascade of 504 Gateway Timeouts, collapsing the public platform.
- **The Deploy-First vs Migrate-First Desynchronization Race**:
  - Application rollouts take minutes across rolling Kubernetes pods. Database DDL takes effect immediately.
  - If an agent renames or drops a column before all running pods are updated, queries referencing the old column immediately crash (`column "customer_name" does not exist`).
  - Conversely, if an agent adds a `NOT NULL` column before application code starts populating it, incoming `INSERT` operations fail (`null value in column violates not-null constraint`).
- **The Unbatched Backfill WAL Saturation & Replication Lag Disaster**:
  - An agent generates an `UPDATE users SET display_name = first_name || ' ' || last_name;` touching 15 million rows in a single monolithic transaction.
  - The transaction generates gigabytes of Write-Ahead Log (WAL) records in seconds, saturating disk I/O, triggering database checkpoint stalls, spiking physical replication lag on read replicas to 45+ minutes, and violating read-your-own-writes consistency for edge replicas.
- **The Synchronous Index Blocking Trap**:
  - An agent issues `CREATE INDEX idx_orders_customer_id ON orders (customer_id);`.
  - Without the `CONCURRENTLY` keyword (or in MySQL without online DDL specifications), PostgreSQL acquires a `SHARE` lock that blocks all writes (`INSERT`, `UPDATE`, `DELETE`) for the 15-minute duration of the index build.
- **The Missing Reversibility & Rollback Amnesia Trap**:
  - An agent writes an up-migration that destructively deletes data (`DROP TABLE legacy_invoices`) or generates an empty `down` migration (`// TODO: down migration not supported`). If the deployment fails midway, rolling back the application code is impossible without restoring from cold backups.
- **The 4-Phase Expand-Contract Migration Ladder**:
  - Zero-downtime database evolution mathematically decouples schema changes into 4 non-breaking operational phases across sequential release cycles:
    - **Phase 1: Expand (Pure Additive Schema Evolution)**: Add new nullable columns, shadow tables, or new tables. Enforce strict `lock_timeout = '2s'`. Deploy application code with dual-writing (writing to both old and new schema fields).
    - **Phase 2: Asynchronous Batched Backfill**: Migrate historical data in chunked keyset cursor batches (1,000–5,000 rows/batch) with explicit inter-batch sleep delays, actively monitoring replica lag ($\tau_{\text{lag}} < 1.0\text{s}$). Never run updates inside the DDL migration file.
    - **Phase 3: Switch Reads & Enforce Invariants**: Verify data parity between old and new columns ($\epsilon \equiv 0$). Switch application read traffic to the new column. Enforce integrity constraints asynchronously using two-phase validation (`CHECK (col IS NOT NULL) NOT VALID` followed by `VALIDATE CONSTRAINT`).
    - **Phase 4: Contract (Deprecated Surface Pruning)**: Decommission dual-writing. Deploy application code that reads and writes strictly to the new schema. Safely drop or ignore deprecated columns using low-lock asynchronous operations.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ User Migration Request ("Rename orders.total_price to amount_cents and convert from float to int")│
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: Monolithic Migration Rewrite]                                   ▼ [PRODUCTION: 4-Phase Expand-Contract Ladder]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ ALTER TABLE orders                              │               │ Phase 1: Expand                                 │
│   DROP COLUMN total_price,                      │               │ • SET lock_timeout = '2s';                      │
│   ADD COLUMN amount_cents BIGINT NOT NULL;      │               │ • ADD COLUMN amount_cents BIGINT NULL;          │
│ ❌ ACCESS EXCLUSIVE lock held for 4 minutes.    │               │ • Deploy App Pods v1.1 (Dual-Write: old + new). │
│ ❌ Running App Pods v1.0 crash on SELECT.       │               ├─────────────────────────────────────────────────┤
│ ❌ Monolithic transaction saturates WAL.        │               │ Phase 2: Batched Keyset Backfill                │
│ ❌ Instant 504 Gateway Outage across cluster.   │               │ • Keyset pagination WHERE id > :cursor LIMIT 2k │
└─────────────────────────────────────────────────┘               │ • Pause if replication lag > 1000ms.            │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Phase 3: Switch Reads & Enforce Invariant       │
                                                                  │ • Deploy App Pods v1.2 (Reads from new column). │
                                                                  │ • ADD CONSTRAINT chk NOT VALID;                 │
                                                                  │ • VALIDATE CONSTRAINT chk; (lock-free scan)     │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Phase 4: Contract & Deprecation                 │
                                                                  │ • Deploy App Pods v1.3 (Decommission old write).│
                                                                  │ • ALTER TABLE orders DROP COLUMN total_price;   │
                                                                  └─────────────────────────────────────────────────┘
```

---

## 2. Lock Contention Physics & DDL Lock Safety Protocol

In PostgreSQL, every schema alteration acquires a lock on the table. While a `SHARE UPDATE EXCLUSIVE` lock allows concurrent reads and writes, an `ACCESS EXCLUSIVE` lock blocks **every single query**, including lightweight read queries (`SELECT 1`).

### The PostgreSQL DDL Lock Matrix
| Operation | Lock Level | Blocks Concurrent Reads? | Blocks Concurrent Writes? | Safe in Production? |
| :--- | :--- | :--- | :--- | :--- |
| `SELECT` | `ACCESS SHARE` | No | No | Yes |
| `INSERT`, `UPDATE`, `DELETE` | `ROW EXCLUSIVE` | No | No | Yes |
| `CREATE INDEX CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` | No | No | **Yes (Lock-Free)** |
| `VACUUM`, `ANALYZE` | `SHARE UPDATE EXCLUSIVE` | No | No | Yes |
| `CREATE INDEX` (non-concurrent) | `SHARE` | No | **Yes (Blocks Writes)** | ❌ **PROHIBITED** |
| `ALTER TABLE ADD COLUMN` (Postgres 11+ constant default) | `ACCESS EXCLUSIVE` | **Yes (Transient <5ms)** | **Yes (Transient <5ms)** | **Yes with `lock_timeout`** |
| `ALTER TABLE ADD COLUMN ... DEFAULT volatile_func()` | `ACCESS EXCLUSIVE` | **Yes (Full Rewrite)** | **Yes (Full Rewrite)** | ❌ **PROHIBITED** |
| `ALTER TABLE ADD CONSTRAINT FOREIGN KEY` (without `NOT VALID`) | `ACCESS EXCLUSIVE` | **Yes (Full Scan)** | **Yes (Full Scan)** | ❌ **PROHIBITED** |
| `ALTER TABLE DROP COLUMN` | `ACCESS EXCLUSIVE` | **Yes (Transient <5ms)** | **Yes (Transient <5ms)** | **Yes with `lock_timeout`** |

### The Mandatory `lock_timeout` & `statement_timeout` Guardrail
Whenever an autonomous agent issues any DDL statement (`ALTER TABLE`, `CREATE INDEX`, `DROP TABLE`), it MUST explicitly set transaction-level timeouts:

```sql
-- ❌ AI Anti-Pattern: Unbounded lock acquisition (deadlocks and starves pool)
ALTER TABLE users ADD COLUMN phone_verified BOOLEAN NOT NULL DEFAULT FALSE;

-- ✅ Production Discipline: Explicit timeout boundaries with automated retry
BEGIN;
-- Abort acquisition immediately if lock cannot be acquired within 2 seconds:
SET LOCAL lock_timeout = '2s';
-- Abort statement execution if execution takes longer than 5 seconds:
SET LOCAL statement_timeout = '5s';

ALTER TABLE users ADD COLUMN phone_verified BOOLEAN DEFAULT FALSE;
COMMIT;
```

If the lock cannot be acquired within `lock_timeout` (e.g. because an analytics report is scanning the table), PostgreSQL throws `error: 55P03: canceling statement due to lock timeout`. The agent harness must catch this error, pause with exponential jitter (1s–5s), and retry up to 5 times rather than waiting in the queue and choking all incoming transactions.

---

## 3. Non-Blocking Index & Constraint Operations

Autonomous agents must never generate synchronous index creation or single-step constraint declarations on populated tables.

### 1. The `CREATE INDEX CONCURRENTLY` Invariant
- `CREATE INDEX CONCURRENTLY` builds the index in three passes without holding an exclusive lock, allowing concurrent `INSERT`, `UPDATE`, and `DELETE` operations throughout the build.
- **Rule of Transaction Disconnection**: `CREATE INDEX CONCURRENTLY` **CANNOT** run inside a multi-statement transaction block (`BEGIN ... COMMIT`).
- **Orphan Invalid Index Cleanup**: If a concurrent index build fails or is canceled, PostgreSQL leaves an invalid index on disk (`indisvalid = false`), which consumes disk space and degrades write performance without serving queries:
  ```sql
  -- Inspect and drop broken orphan indexes before retrying:
  SELECT indexrelid::regclass, indisvalid 
  FROM pg_index 
  WHERE indisvalid = false;

  DROP INDEX CONCURRENTLY IF EXISTS broken_index_name;
  CREATE INDEX CONCURRENTLY idx_users_email ON users (email);
  ```

### 2. The Two-Phase Constraint Validation Pattern
Adding a `CHECK` constraint or `FOREIGN KEY` synchronously performs a full sequential scan under an `ACCESS EXCLUSIVE` lock. On tables with millions of rows, this scan takes minutes and freezes all database traffic.
- **Phase A (Instantaneous Lock)**: Add the constraint marked `NOT VALID`. This acquires an `ACCESS EXCLUSIVE` lock for $<5\text{ms}$ to update catalog metadata. New and updated rows are validated immediately, but existing rows are skipped.
- **Phase B (Non-Blocking Validation)**: Validate the constraint using `VALIDATE CONSTRAINT`. This acquires a `SHARE UPDATE EXCLUSIVE` lock, scanning historical rows without blocking concurrent reads or writes:
  ```sql
  -- Step 1: Enforce constraint on new writes without historical scan:
  ALTER TABLE payments 
    ADD CONSTRAINT chk_payments_amount_positive 
    CHECK (amount_cents > 0) NOT VALID;

  -- Step 2: Validate historical data in separate transaction (non-blocking):
  ALTER TABLE payments 
    VALIDATE CONSTRAINT chk_payments_amount_positive;
  ```

### 3. Non-Blocking Foreign Key Invariant
```sql
-- Step 1: Add foreign key constraint marked NOT VALID:
ALTER TABLE order_items 
  ADD CONSTRAINT fk_order_items_order_id 
  FOREIGN KEY (order_id) REFERENCES orders(id) 
  ON DELETE RESTRICT NOT VALID;

-- Step 2: Concurrently validate historical referential integrity:
ALTER TABLE order_items 
  VALIDATE CONSTRAINT fk_order_items_order_id;
```

---

## 4. Lock-Free Batched Backfills & Keyset Cursor Iteration

When migrating millions of rows (e.g., populating a new column, hashing values, or reformatting phone numbers), agents must NEVER execute an unbatched `UPDATE` or `INSERT ... SELECT`.

### The 4 Mathematical Backfill Laws
1. **The Keyset / Cursor Paging Law**: Never use `OFFSET` ($O(N^2)$ tuple scan penalty). Always paginate using strictly monotonically increasing primary keys or composite keys (`WHERE id > :cursor ORDER BY id ASC LIMIT :batch_size`).
2. **The Bounded Chunk Law**: Batch size must be bounded ($1,000 \le \text{batch\_size} \le 5,000$). Each batch must commit independently in its own transaction.
3. **The Inter-Batch Jitter & Cooldown Law**: Inject an explicit sleep delay ($50\text{ms} \le \tau_{\text{sleep}} \le 200\text{ms}$) between batches to allow PostgreSQL autovacuum workers and WAL writers to flush dirty pages.
4. **The Replication Lag Sentinel Law**: In clusters with read replicas, the backfill worker must query replication lag prior to dispatching each batch. If replica lag exceeds 1,000ms, the worker must pause until replicas catch up:
   $$\tau_{\text{lag}} = \text{EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))} \le 1.0\text{s}$$

```sql
-- Production Batched Keyset Backfill SQL (executed iteratively by migration worker)
WITH batch AS (
  SELECT id 
  FROM orders 
  WHERE id > :last_seen_cursor 
    AND amount_cents IS NULL 
  ORDER BY id ASC 
  LIMIT 2000
)
UPDATE orders o
SET amount_cents = CAST(ROUND(o.total_price * 100) AS BIGINT)
FROM batch
WHERE o.id = batch.id;
```

---

## 5. Dual-Writing Architecture: Database Triggers vs Application Layer

When transforming existing columns (e.g. `total_price` float $\to$ `amount_cents` integer), systems must guarantee that concurrent writes during Phases 1–3 are kept in sync across both columns.

### Approach A: Fast Synchronous Database Triggers (Ephemeral)
For migrations within a single database service, an ephemeral database trigger guarantees immediate consistency with zero application changes required for dual-writing:

```sql
-- 1. Create synchronization function
CREATE OR REPLACE FUNCTION sync_orders_amount_cents() 
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.total_price IS NOT NULL AND NEW.amount_cents IS NULL THEN
    NEW.amount_cents := CAST(ROUND(NEW.total_price * 100) AS BIGINT);
  ELSIF NEW.amount_cents IS NOT NULL AND NEW.total_price IS NULL THEN
    NEW.total_price := CAST(NEW.amount_cents AS NUMERIC) / 100.0;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. Attach trigger to table
CREATE TRIGGER trg_orders_dual_write
BEFORE INSERT OR UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION sync_orders_amount_cents();

-- 3. In Phase 4 (Contract), drop the trigger:
DROP TRIGGER IF EXISTS trg_orders_dual_write ON orders;
DROP FUNCTION IF EXISTS sync_orders_amount_cents();
```

### Approach B: Application-Level Dual-Writing (Prisma / TypeORM / Drizzle / Go)
When business logic dictates complex hashing, external API calls, or multi-tenant sharding, dual-write directly in the application service layer:
```typescript
// Application-Level Dual-Write Service Layer
export async function updateOrderPrice(orderId: string, priceDollars: number): Promise<void> {
  const amountCents = Math.round(priceDollars * 100);
  
  // Phase 1: Dual-Write to both legacy and new column
  await db.order.update({
    where: { id: orderId },
    data: {
      total_price: priceDollars, // Legacy column
      amount_cents: amountCents, // New column
    },
  });
}
```

---

## 6. Complete Executable Engine: TypeScript `AgenticZeroDowntimeMigrationEngine`

Autonomous agent harnesses must use this self-contained, typed engine to validate DDL for lock safety, execute safe 4-phase expand-contract workflows, and throttle backfills against replica lag.

```typescript
import { Client, PoolClient } from 'pg';

export interface MigrationStep {
  name: string;
  phase: 'expand' | 'backfill' | 'validate' | 'contract';
  upSql: string[];
  downSql: string[];
  requiresIndependentTransaction?: boolean;
}

export interface BackfillConfig {
  tableName: string;
  primaryKey: string;
  batchSize: number;
  sleepMsBetweenBatches: number;
  maxReplicaLagSeconds: number;
  updateExpressionSql: string;
  whereClauseSql: string;
}

export interface DdlSafetyReport {
  isSafe: boolean;
  violations: string[];
  warnings: string[];
}

export class AgenticZeroDowntimeMigrationEngine {
  constructor(private poolClient: PoolClient) {}

  /**
   * Static analysis of DDL AST to intercept high-risk migration anti-patterns.
   */
  public static analyzeDdlSafety(sqlStatements: string[]): DdlSafetyReport {
    const violations: string[] = [];
    const warnings: string[] = [];

    for (const sql of sqlStatements) {
      const normalized = sql.trim().replace(/\s+/g, ' ').toUpperCase();

      // Check 1: Non-concurrent index creation
      if (normalized.includes('CREATE INDEX') && !normalized.includes('CONCURRENTLY')) {
        violations.push(
          `UNSAFE INDEX: '${sql}' creates index without CONCURRENTLY. This acquires a SHARE lock blocking all concurrent table writes.`
        );
      }

      // Check 2: Single-step constraint addition without NOT VALID
      if (
        (normalized.includes('ADD CONSTRAINT') || normalized.includes('ADD CHECK') || normalized.includes('FOREIGN KEY')) &&
        !normalized.includes('NOT VALID')
      ) {
        violations.push(
          `UNSAFE CONSTRAINT: '${sql}' adds constraint without 'NOT VALID'. This performs a blocking table scan under ACCESS EXCLUSIVE.`
        );
      }

      // Check 3: Missing lock_timeout guard
      if (normalized.startsWith('ALTER TABLE') && !normalized.includes('SET LOCAL LOCK_TIMEOUT')) {
        warnings.push(
          `LOCK TIMEOUT MISSING: '${sql}' executes without an explicit 'SET LOCAL lock_timeout = ...'. Queue starvations may occur.`
        );
      }

      // Check 4: Unbatched UPDATE / DELETE in DDL
      if ((normalized.startsWith('UPDATE ') || normalized.startsWith('DELETE FROM ')) && !normalized.includes('LIMIT')) {
        violations.push(
          `UNBATCHED DML IN MIGRATION: '${sql}' executes full-table mutation inside DDL. Must be delegated to batched keyset backfill worker.`
        );
      }
    }

    return {
      isSafe: violations.length === 0,
      violations,
      warnings,
    };
  }

  /**
   * Executes DDL statements under strict lock_timeout and statement_timeout boundaries.
   */
  public async executeSafeDdl(
    sqlStatements: string[],
    lockTimeoutMs = 2000,
    statementTimeoutMs = 10000
  ): Promise<void> {
    for (const statement of sqlStatements) {
      let attempts = 0;
      const maxRetries = 5;

      while (attempts < maxRetries) {
        attempts++;
        try {
          await this.poolClient.query('BEGIN;');
          await this.poolClient.query(`SET LOCAL lock_timeout = '${lockTimeoutMs}ms';`);
          await this.poolClient.query(`SET LOCAL statement_timeout = '${statementTimeoutMs}ms';`);
          await this.poolClient.query(statement);
          await this.poolClient.query('COMMIT;');
          break;
        } catch (err: any) {
          await this.poolClient.query('ROLLBACK;').catch(() => {});
          // Error 55P03: lock_not_available (statement canceled due to lock timeout)
          if (err.code === '55P03' && attempts < maxRetries) {
            const jitterMs = Math.floor(Math.random() * 1000) + 1000 * attempts;
            await new Promise((res) => setTimeout(res, jitterMs));
            continue;
          }
          throw new Error(`DDL Execution Failed [Attempt ${attempts}/${maxRetries}]: ${err.message}\nSQL: ${statement}`);
        }
      }
    }
  }

  /**
   * Performs an asynchronous keyset-paginated backfill with replication lag throttling.
   */
  public async executeBatchedBackfill(config: BackfillConfig): Promise<{ totalUpdated: number }> {
    let lastSeenId = 0;
    let totalUpdated = 0;
    let hasMore = true;

    while (hasMore) {
      // Step 1: Sentinel check for read replica lag
      await this.awaitReplicationCatchup(config.maxReplicaLagSeconds);

      // Step 2: Query chunk of IDs to update
      const fetchBatchSql = `
        SELECT ${config.primaryKey} 
        FROM ${config.tableName} 
        WHERE ${config.primaryKey} > $1 
          AND (${config.whereClauseSql})
        ORDER BY ${config.primaryKey} ASC 
        LIMIT $2;
      `;
      const idResult = await this.poolClient.query(fetchBatchSql, [lastSeenId, config.batchSize]);

      if (idResult.rows.length === 0) {
        hasMore = false;
        break;
      }

      const currentIds = idResult.rows.map((row) => row[config.primaryKey]);
      lastSeenId = currentIds[currentIds.length - 1];

      // Step 3: Execute batched update for this primary key slice
      const updateBatchSql = `
        UPDATE ${config.tableName}
        SET ${config.updateExpressionSql}
        WHERE ${config.primaryKey} = ANY($1::bigint[]);
      `;
      const updateResult = await this.poolClient.query(updateBatchSql, [currentIds]);
      totalUpdated += updateResult.rowCount ?? 0;

      // Step 4: Inject inter-batch sleep to allow DB checkpoints & WAL drainage
      if (config.sleepMsBetweenBatches > 0) {
        await new Promise((res) => setTimeout(res, config.sleepMsBetweenBatches));
      }
    }

    return { totalUpdated };
  }

  /**
   * Throttles backfill execution if any connected replica has replication lag > ceiling.
   */
  private async awaitReplicationCatchup(maxLagSeconds: number): Promise<void> {
    const lagQuery = `
      SELECT COALESCE(MAX(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))), 0) AS max_lag_seconds
      FROM pg_stat_replication;
    `;
    let lag = 0;
    let checks = 0;

    do {
      try {
        const res = await this.poolClient.query(lagQuery);
        lag = parseFloat(res.rows[0]?.max_lag_seconds ?? '0');
      } catch {
        // If not running in a cluster with pg_stat_replication permissions, bypass check
        break;
      }

      if (lag > maxLagSeconds) {
        checks++;
        if (checks > 60) {
          throw new Error(`Replication lag exceeded ${maxLagSeconds}s for over 60s. Aborting backfill to protect cluster.`);
        }
        await new Promise((res) => setTimeout(res, 2000));
      }
    } while (lag > maxLagSeconds);
  }
}
```

---

## 7. The 6-State Zero-Downtime Migration Lifecycle Finite-State Machine (FSM)

Autonomous agent migration controllers must progress through 6 deterministic states. Any failure triggers automatic rollback compensation.

```
       ┌────────────────────────┐
       │ 1. PREFLIGHT_AUDIT     │ ──(Violations detected)──► [ABORT & REPORT]
       └───────────┬────────────┘
                   │ Pass (lock_timeout & non-blocking confirmed)
                   ▼
       ┌────────────────────────┐
       │ 2. EXPAND_SCHEMA       │ ──(Lock timeout exceeded)──► [ROLLBACK & JITTER RETRY]
       └───────────┬────────────┘
                   │ Column added (nullable) / index built CONCURRENTLY
                   ▼
       ┌────────────────────────┐
       │ 3. DUAL_WRITE_ACTIVATE │ ──(Trigger/App error)──────► [DISABLE DUAL_WRITE]
       └───────────┬────────────┘
                   │ New writes safely duplicated across old & new schema
                   ▼
       ┌────────────────────────┐
       │ 4. BATCH_BACKFILL      │ ──(Replica lag > 1000ms)───► [PAUSE & THROTTLE]
       └───────────┬────────────┘
                   │ Keyset cursor reaches EOF, parity verified (ε ≡ 0)
                   ▼
       ┌────────────────────────┐
       │ 5. VALIDATE_CONSTRAINTS│ ──(Validation failure)─────► [ISOLATE INVALIDS]
       └───────────┬────────────┘
                   │ VALIDATE CONSTRAINT succeeds without locks
                   ▼
       ┌────────────────────────┐
       │ 6. CONTRACT_PRUNING    │ ──(Success)────────────────► [MIGRATION COMPLETE]
       └────────────────────────┘
```

1. **State 1 (`PREFLIGHT_AUDIT`)**: Static AST analysis of the proposed DDL. Rejects missing `CONCURRENTLY`, unbatched `UPDATE`, non-null additions without defaults, and missing `lock_timeout`.
2. **State 2 (`EXPAND_SCHEMA`)**: Executes additive DDL under `SET LOCAL lock_timeout = '2s'`. Creates nullable columns, shadow tables, and builds indexes concurrently.
3. **State 3 (`DUAL_WRITE_ACTIVATE`)**: Deploys synchronous DB triggers or updates application code to write to both legacy and new structures simultaneously.
4. **State 4 (`BATCH_BACKFILL`)**: Background worker migrates historical records in keyset chunks of 1,000–5,000 rows. Actively throttles on replication lag and database CPU load.
5. **State 5 (`VALIDATE_CONSTRAINTS`)**: Validates data parity ($\epsilon \equiv 0$). Adds constraints via `NOT VALID` then executes `VALIDATE CONSTRAINT`. Switches application reads to the new schema.
6. **State 6 (`CONTRACT_PRUNING`)**: Decommissions dual-writing. Drops legacy triggers and deprecated columns asynchronously using low-lock sweeps.

---

## 8. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

Before any agent can mark a database migration task complete or submit a Pull Request, all 6 gates must evaluate to `PASS`:

| Gate | Verification Target | Machine-Verifiable Command / Proof | Passing Criteria |
| :--- | :--- | :--- | :--- |
| **Gate 1: Lock Timeout Boundary** | DDL Lock Safety | `grep -E "lock_timeout" migration.sql` | Every DDL block sets `lock_timeout <= '2s'` |
| **Gate 2: Concurrent Indexing** | Index Build Safety | `grep -E "CREATE.*INDEX" migration.sql` | 100% of index statements include `CONCURRENTLY` |
| **Gate 3: Two-Phase Constraints** | Constraint Blocking Prevention | `grep -E "ADD CONSTRAINT" migration.sql` | All constraints declared `NOT VALID` prior to validation |
| **Gate 4: Keyset Batched Backfill** | WAL & Lock Elimination | Keyset cursor script with `LIMIT` and replica lag check | Zero unbatched `UPDATE`/`DELETE` in DDL files |
| **Gate 5: Rollback Symmetry** | Zero-Loss Recovery | Test run of `down` migration against shadow database | Clean reversal of DDL without orphan locks or schema residue |
| **Gate 6: Dual-Version Compatibility** | Pod Rolling Restart Safety | Execute test suite of App Pod $V_{t}$ against DB schema $S_{t+1}$ | Zero errors; running app pods remain 100% functional |

---

## 9. Zero-Compromise Database Migration Anti-Patterns

| Anti-Pattern | Fatal Mechanism | Enforced Production Invariant |
| :--- | :--- | :--- |
| **Monolithic `ALTER TABLE` Block** | Combines column additions, renames, and type casts in one statement; acquires and holds `ACCESS EXCLUSIVE` for minutes. | Split into isolated single-action statements, each wrapped in `BEGIN ... COMMIT` with `SET LOCAL lock_timeout = '2s'`. |
| **Volatile Default Column Addition** | Adding a column with `DEFAULT now()` or `DEFAULT gen_random_uuid()` rewrites every tuple on disk. | In Postgres <11 or with volatile expressions, add column as `NULL`, backfill asynchronously in batches, then set default. |
| **Single-Step Column Rename** | Renaming `col_a` to `col_b` instantly breaks all running application pods that query `col_a`. | Expand with new column `col_b`, dual-write to both, backfill historical data, switch reads to `col_b`, then drop `col_a`. |
| **Synchronous `CREATE INDEX`** | Acquires a `SHARE` lock that blocks all `INSERT`, `UPDATE`, and `DELETE` operations for the build duration. | Always use `CREATE INDEX CONCURRENTLY` executed outside multi-statement transaction blocks. |
| **Unbatched Data Migration in DDL** | Running `UPDATE table SET ...` inside a migration file fills the WAL buffer and locks tables indefinitely. | Strictly forbid DML inside DDL. Migrate data via an external keyset-paginated backfill worker. |
| **Adding Synchronous Foreign Keys** | Scans referenced and referencing tables under an exclusive lock, causing deadlocks on active foreign tables. | Add foreign key constraint as `NOT VALID`, then validate in a separate statement via `VALIDATE CONSTRAINT`. |
| **High-Offset Pagination in Backfills** | Using `LIMIT 1000 OFFSET 500000` scans and discards 500,000 rows on every batch, causing $O(N^2)$ I/O degradation. | Always use keyset pagination: `WHERE id > :last_seen_id ORDER BY id ASC LIMIT :batch_size`. |
