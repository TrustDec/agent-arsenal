---
description: Database foreign keys, referential integrity architecture, unindexed child index traps, ON DELETE CASCADE lock contention storms, cyclic dependency resolution with DEFERRABLE constraints, composite multi-tenant foreign keys, zero-downtime NOT VALID migrations, and deadlock defense across Go (pgx/v5), TypeScript (Drizzle/Prisma), Rust (sqlx), Python (SQLAlchemy), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{foreign-key,fk,referential,relation,schema,migration,cascade,constraint,model,entity}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/models/**/*.{ts,js,go,rs,py},**/src/entities/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Foreign Keys, Referential Integrity, Unindexed Child Traps, Cascading Lock Contention & Deadlock Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design relational database schemas, entity associations, parent-child cascades, multi-tenant boundaries, or background cleanup workers across PostgreSQL, MySQL/InnoDB, SQLite, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Prisma`, `Kysely`, `TypeORM`), Python (`SQLAlchemy`), or Rust (`sqlx`). Eliminate the "Unindexed Foreign Key Sequential Scan & Table Lock Escalation Trap" (where PostgreSQL does NOT auto-index foreign key columns, causing parent `DELETE` or `UPDATE` statements to sequentially scan millions of child rows under `ShareRowExclusiveLock` or blocking tuple locks, stalling the database cluster and exhausting connection pools), the "ON DELETE CASCADE Monolithic Transaction Blast & WAL Avalanche" (where deleting a root tenant or parent record cascades down 5–10 child relations, attempting to delete 500,000 rows in a single monolithic transaction, blowing `statement_timeout`, consuming Postgres lock table slots past `max_locks_per_transaction`, creating gigabytes of unvacuumed WAL, and driving replica lag through the roof), the "Parent-Child Interleaved Lock Deadlock Storm (SQLSTATE 40P01)" (where Transaction A inserts a child row which acquires a `FOR KEY SHARE` tuple lock on parent A, then attempts to update parent B, while Transaction B inserts a child referencing parent B and attempts to update parent A, producing circular Wait-For Graph deadlocks), the "Cyclic Foreign Key Dependency & Immediate Constraint Violation Trap (SQLSTATE 23503)" (where mutually referencing relations like `teams.owner_id -> users.id` and `users.active_team_id -> teams.id` fail immediate insertion orders unless declared `DEFERRABLE INITIALLY DEFERRED` or structured with nullable two-phase initialization), the "Cross-Tenant Referential Integrity Leak & Foreign Key Multi-Tenant Bypass" (where single-column foreign keys `FOREIGN KEY (project_id) REFERENCES projects(id)` allow an issue belonging to Tenant A to reference a project belonging to Tenant B if application logic errs, violating tenant isolation boundaries unless enforced by composite multi-column foreign keys `FOREIGN KEY (tenant_id, project_id) REFERENCES projects(tenant_id, id)`), and the "Synchronous Foreign Key Creation Lockout Catastrophe" (where agents run `ALTER TABLE ... ADD CONSTRAINT fk FOREIGN KEY ...` synchronously without `NOT VALID`, acquiring `ACCESS EXCLUSIVE` on the child relation and `SHARE ROW EXCLUSIVE` on the parent table for the duration of a full-table sequential scan, freezing all production read/write traffic) by establishing a strict 5-Tier Foreign Key & Referential Integrity Governance Ladder, lock contention physics equations, bounded keyset chunked cascading workers, and machine-verifiable CI test gates.

---

## 1. Architectural Taxonomy: The 6 Foreign Key Catastrophes vs The 5-Tier Referential Governance Ladder

Relational foreign keys enforce business invariants and referential integrity between parent and child tables. However, autonomous coding agents routinely make disastrous assumptions about how relational engines (especially PostgreSQL) lock, validate, and cascade foreign keys:

```typescript
// ❌ CATASTROPHIC LLM FOREIGN KEY ANTI-PATTERNS

// 1. The Unindexed Foreign Key Sequential Scan Trap!
// PostgreSQL DOES NOT automatically create an index on the referencing foreign key column!
// Any parent UPDATE (on referenced key) or DELETE requires a full sequential scan of line_items.
// If line_items has 10,000,000 rows, a single parent order cancellation takes 15 seconds!
export const lineItems = pgTable('line_items', {
  id: uuid('id').primaryKey().defaultRandom(),
  orderId: uuid('order_id').notNull().references(() => orders.id), // ❌ Unindexed FK: scans 10M rows on order DELETE!
  sku: text('sku').notNull(),
  priceCents: integer('price_cents').notNull(),
});

// 2. The Monolithic ON DELETE CASCADE Blast!
// Putting ON DELETE CASCADE across deep hierarchy: accounts -> workspaces -> projects -> tasks -> comments.
// Deleting one account deletes 400,000 rows in ONE monolithic transaction!
// Blows statement_timeout, blows lock table memory, generates 12GB of WAL, spikes replica lag to 60s.
export const tasks = pgTable('tasks', {
  id: uuid('id').primaryKey().defaultRandom(),
  projectId: uuid('project_id').notNull().references(() => projects.id, { onDelete: 'cascade' }), // ❌ Unbounded cascade blast!
  title: text('title').notNull(),
});

// 3. The Cross-Tenant Referential Leak Trap!
// Single-column FK allows child from Tenant A to reference parent from Tenant B!
// If API bugs or malicious payload passes project_id of Tenant B, DB accepts it because project_id exists.
export const documents = pgTable('documents', {
  id: uuid('id').primaryKey().defaultRandom(),
  tenantId: uuid('tenant_id').notNull(),
  folderId: uuid('folder_id').notNull().references(() => folders.id), // ❌ Cross-tenant link possible! Needs composite FK!
});

// 4. Synchronous Foreign Key Creation Outage!
// Running synchronous ALTER TABLE in migration file:
// ALTER TABLE payments ADD CONSTRAINT fk_user FOREIGN KEY (user_id) REFERENCES users(id);
// Takes ACCESS EXCLUSIVE on payments and SHARE ROW EXCLUSIVE on users for 3 minutes! Full system freeze!
```

To eliminate these failure modes, production systems enforce the **5-Tier Foreign Key & Referential Integrity Governance Ladder**:

```
+----------------------------------------------------------------------------------------------------+
|                5-TIER FOREIGN KEY & REFERENTIAL INTEGRITY GOVERNANCE LADDER                         |
+----------------------------------------------------------------------------------------------------+
| Tier 0: Mandatory B-Tree Indexing on 100% of Referencing Columns                                   |
|   - Zero unindexed foreign keys across all relational tables.                                      |
|   - Foreign key column MUST form the leftmost prefix of a B-tree index.                            |
|   - Cuts parent deletion / update child-verification cost from O(N) full scan to O(log N) index seek.|
+----------------------------------------------------------------------------------------------------+
| Tier 1: Two-Phase Online Zero-Downtime Foreign Key Migration Protocol                              |
|   - Step 1: CREATE INDEX CONCURRENTLY on child referencing column.                                 |
|   - Step 2: ADD CONSTRAINT ... FOREIGN KEY ... NOT VALID (sub-millisecond catalog lock).           |
|   - Step 3: VALIDATE CONSTRAINT ... (SHARE UPDATE EXCLUSIVE lock; non-blocking to reads & writes).  |
+----------------------------------------------------------------------------------------------------+
| Tier 2: Bounded Keyset Chunked Cascade Deletions & Tombstone Pruning                               |
|   - Prohibit unconstrained ON DELETE CASCADE on tables exceeding 5,000 rows.                       |
|   - Cascade deletions executed by background worker in keyset chunks (LIMIT 1,000).                |
|   - Actively throttles on replication lag (tau_lag < 1.0s) and database CPU headroom.              |
+----------------------------------------------------------------------------------------------------+
| Tier 3: Composite Multi-Tenant Foreign Key Boundaries                                              |
|   - Enforce composite foreign keys containing tenant_id:                                           |
|     FOREIGN KEY (tenant_id, parent_id) REFERENCES parent(tenant_id, id).                           |
|   - Backed by composite UNIQUE (tenant_id, id) constraint on parent.                               |
|   - Enforces cryptographic tenant boundary isolation directly at relational engine layer.          |
+----------------------------------------------------------------------------------------------------+
| Tier 4: Cyclic Dependency Deferral & Canonical Key Share Ordering                                  |
|   - Declare circular foreign keys as DEFERRABLE INITIALLY DEFERRED or decouple via nullable keys.  |
|   - Enforce canonical ascending order sorting when locking parent rows before child mutations.     |
|   - Eliminates Parent-Child interleaved SQLSTATE 40P01 deadlocks in concurrent write transactions. |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. Mathematical Formalism: Lock Contention Physics, Unindexed Scan Penalties & Cascade WAL Sizing

### 2.1 The Unindexed Foreign Key Full Scan & Lock Contention Penalty

When a parent tuple $T_p$ in table $P$ is deleted or has its primary key updated in PostgreSQL, the relational engine must verify that no child tuples $T_c$ in referencing table $C$ point to $T_p$.

1. **If child column is indexed**:
   PostgreSQL executes an Index Scan using the supporting B-tree:
   $$t_{\text{check}} = h_{\text{btree}} \cdot t_{\text{page\_read}} \approx 3 \times 0.05\text{ms} = 0.15\text{ms}$$

2. **If child column is UNINDEXED**:
   PostgreSQL must perform a **Sequential Scan** across all $N_{\text{child}}$ pages of child table $C$:
   $$t_{\text{check}} = \frac{N_{\text{child\_pages}} \times 8192}{\text{Sequential Read Throughput}} = \frac{S_{\text{child\_bytes}}}{\text{Bandwidth}_{\text{disk}}}$$
   For a 10M-row child table ($S_{\text{child}} \approx 4\text{GB}$), on an NVMe SSD reading at $500\text{MB/s}$:
   $$t_{\text{check}} \approx \frac{4096\text{MB}}{500\text{MB/s}} \approx 8.19\text{ seconds!}$$

Under Little's Law, if parent update/delete requests arrive at rate $\lambda_p$, the number of concurrently queued transactions blocked by child scanning is:
$$Q_{\text{blocked}} = \lambda_p \times t_{\text{check}}$$
If $\lambda_p = 20\text{ ops/s}$ and $t_{\text{check}} = 8.19\text{s}$:
$$Q_{\text{blocked}} = 20 \times 8.19 \approx 164 \text{ concurrent blocked transactions!}$$
Because standard PostgreSQL connection pools (`max_connections`) are typically sized at 100–200 connections, an unindexed foreign key causes **complete connection pool exhaustion in under 10 seconds**.

### 2.2 Monolithic Cascade Blast vs Bounded Keyset Chunking

Let a root entity deletion cascade down $K$ child tables, with the total number of affected rows being:
$$N_{\text{cascade}} = \sum_{k=1}^K N_k$$
In a single monolithic transaction (`ON DELETE CASCADE`):
1. **Lock Table Slot Consumption**:
   PostgreSQL tracks locks in a fixed shared memory hash table configured by `max_locks_per_transaction \times max_connections`.
   A single transaction locking $N_{\text{cascade}} > 100,000$ rows risks exhausting the shared lock table, throwing:
   $$\text{FATAL: out of shared memory (HINT: You might need to increase max_locks_per_transaction)}$$
2. **Full-Page Write (FPW) WAL Spike**:
   Deleting $N_{\text{cascade}}$ tuples dirties $P_{\text{dirty}} \approx \frac{N_{\text{cascade}}}{\text{TuplesPerPage}}$ 8KB pages. The first modification of each page after a checkpoint writes a full 8KB image to the WAL:
   $$\text{WAL}_{\text{burst}} \approx P_{\text{dirty}} \times 8192\text{ bytes}$$
   For $N_{\text{cascade}} = 500,000$ and 50 tuples/page, $P_{\text{dirty}} = 10,000\text{ pages} \implies \text{WAL}_{\text{burst}} \ge 81.9\text{MB}$ in a single transaction, saturating WAL write bandwidth and triggering replication lag spikes across all standby replicas:
   $$\tau_{\text{replica\_lag}} = \frac{\text{WAL}_{\text{burst}}}{\text{Replication Replay Rate}}$$

**The Keyset Chunking Solution**:
Divide deletion into $M = \lceil \frac{N_{\text{cascade}}}{B} \rceil$ micro-transactions of size $B = 1,000$ rows:
$$N_{\text{batch}} \le 1000 \implies \text{WAL}_{\text{batch}} \le 163\text{KB}, \quad t_{\text{lock\_hold}} \le 5\text{ms}$$
Between batches, pause $\tau_{\text{sleep}} = 50\text{ms}$ and monitor replication lag:
$$\tau_{\text{lag}} < 1.0\text{s} \implies \text{Continue}; \quad \tau_{\text{lag}} \ge 1.0\text{s} \implies \text{Throttle/Pause}$$

### 2.3 Wait-For Graph Cycle Elimination in Foreign Key Verification

When inserting into child table $C$, PostgreSQL acquires a tuple-level `FOR KEY SHARE` lock on parent tuple $P_1$ to ensure the parent is not concurrently deleted.
If Transaction $T_1$ inserts child referencing $P_1$ and then updates $P_2$:
$$T_1: \text{Lock}(P_1, \text{KeyShare}) \to \text{Lock}(P_2, \text{Exclusive})$$
Concurrently, Transaction $T_2$ inserts child referencing $P_2$ and then updates $P_1$:
$$T_2: \text{Lock}(P_2, \text{KeyShare}) \to \text{Lock}(P_1, \text{Exclusive})$$
Since `Exclusive` locks conflict with `KeyShare` locks:
$$T_1 \text{ waits for } T_2 \text{ on } P_2, \quad T_2 \text{ waits for } T_1 \text{ on } P_1 \implies T_1 \to T_2 \to T_1$$
This produces a cycle in the Wait-For Graph $G = (V, E)$, triggering PostgreSQL `SQLSTATE 40P01 (deadlock_detected)`.

**Invariant**: Canonical sorting of parent entity IDs before multi-row mutations guarantees that edges in the Wait-For Graph are strictly monotonically increasing in key order:
$$e = (T_a, T_b) \implies \text{Key}(T_a) < \text{Key}(T_b) \implies \text{Cycles}(G) = \emptyset \implies \mathbb{P}(\text{Deadlock}) = 0$$

---

## 3. The 5 Core Production Invariants

### Invariant 1: Mandatory B-Tree Indexing on 100% of Referencing Columns
Every column referenced by a foreign key constraint MUST be covered by a B-tree index where the foreign key column is the **leftmost column** of the index. In composite foreign keys `(tenant_id, parent_id)`, the index must begin with `(tenant_id, parent_id)`.

```sql
-- ✅ Production Schema: Child Table with Mandatory B-Tree Index on Referencing Column
CREATE TABLE tenant_invoices (
  invoice_id UUID PRIMARY KEY DEFAULT generate_uuid_v7(),
  tenant_id UUID NOT NULL,
  subscription_id UUID NOT NULL,
  total_cents BIGINT NOT NULL CHECK (total_cents >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  -- Composite Multi-Tenant Foreign Key
  CONSTRAINT fk_invoices_subscription 
    FOREIGN KEY (tenant_id, subscription_id) 
    REFERENCES tenant_subscriptions (tenant_id, subscription_id)
    ON DELETE RESTRICT -- Never blindly cascade; require explicit business archival
);

-- MANDATORY: Supporting Index on the Foreign Key referencing columns
-- Without this, ANY update or delete on tenant_subscriptions forces a full Seq Scan on tenant_invoices!
CREATE INDEX idx_tenant_invoices_tenant_sub
ON tenant_invoices (tenant_id, subscription_id);
```

### Invariant 2: Two-Phase Zero-Downtime Foreign Key Migration Protocol
Never execute synchronous `ALTER TABLE child ADD CONSTRAINT fk FOREIGN KEY ...` on production tables with $>10,000$ rows. Doing so takes an `ACCESS EXCLUSIVE` lock on `child` and a `SHARE ROW EXCLUSIVE` lock on `parent` while sequentially scanning every row in `child`.

Always follow the **Two-Phase Expand-Contract Migration Protocol**:

```sql
-- PHASE 1: Create supporting index concurrently (Zero locking on writes)
CREATE INDEX CONCURRENTLY idx_child_parent_id 
ON child_table (parent_id);

-- PHASE 2: Attach constraint as NOT VALID (Sub-millisecond metadata lock)
-- Validates that future INSERTs/UPDATEs conform, without scanning historical rows.
ALTER TABLE child_table 
ADD CONSTRAINT fk_child_parent 
FOREIGN KEY (parent_id) 
REFERENCES parent_table (id) 
NOT VALID;

-- PHASE 3: Validate constraint asynchronously (Takes only SHARE UPDATE EXCLUSIVE)
-- Reads existing rows without blocking concurrent SELECT, INSERT, UPDATE, or DELETE!
ALTER TABLE child_table 
VALIDATE CONSTRAINT fk_child_parent;
```

### Invariant 3: Bounded Keyset Chunked Cascade Deletions & Tombstone Pruning
Strictly prohibit declarative `ON DELETE CASCADE` on root entities or relations that can accumulate $>5,000$ descendants. Cascade deletions must be orchestrated asynchronously in bounded keyset chunks:

```sql
-- Industrial Batched Keyset Cascade Deletion Worker (Executed in loop by background worker)
-- Takes < 5ms per batch, generates < 200KB WAL, zero connection starvation.
WITH candidate_batch AS (
  SELECT id
  FROM line_items
  WHERE order_id = :target_order_id
  ORDER BY id ASC
  LIMIT 1000
  FOR UPDATE SKIP LOCKED -- Lock-free for other workers
)
DELETE FROM line_items
WHERE id IN (SELECT id FROM candidate_batch);
```

### Invariant 4: Composite Multi-Tenant Foreign Key Boundaries
In multi-tenant schemas, never define single-column foreign keys to parent entities that are also tenant-scoped. A single-column foreign key creates a catastrophic **Cross-Tenant Referential Integrity Leak**: if an application bug allows Tenant A to set `project_id` to a UUID belonging to Tenant B, the database accepts the write because the UUID exists globally!

```sql
-- ❌ DANGEROUS: Single-Column FK Allows Cross-Tenant Association Leak
CREATE TABLE issues (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL,
  project_id UUID NOT NULL REFERENCES projects(id) -- ❌ Tenant A can link to Tenant B's project!
);

-- ✅ BULLETPROOF: Composite Multi-Tenant FK Guarantees Hermetic Tenant Isolation
-- Step 1: Ensure parent has composite unique constraint
ALTER TABLE projects ADD CONSTRAINT uq_projects_tenant_id UNIQUE (tenant_id, id);

-- Step 2: Child references both tenant_id and parent_id
CREATE TABLE issues (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL,
  project_id UUID NOT NULL,
  CONSTRAINT fk_issues_tenant_project
    FOREIGN KEY (tenant_id, project_id)
    REFERENCES projects (tenant_id, id)
    ON DELETE RESTRICT
);
CREATE INDEX idx_issues_tenant_project ON issues (tenant_id, project_id);
```

### Invariant 5: Cyclic Dependency Deferral & Canonical Locking Order
For mutually referencing entities (e.g., `user.active_org_id -> org.id` and `org.owner_id -> user.id`), declare the constraint `DEFERRABLE INITIALLY DEFERRED` or decouple the dependency via nullable initialization. When executing multi-row parent-child mutations within a single transaction, sort parent entity IDs lexicographically before acquiring row locks.

```sql
-- Mutually Referencing Cyclic Foreign Key with Constraint Deferral
CREATE TABLE organizations (
  id UUID PRIMARY KEY,
  name TEXT NOT NULL,
  owner_id UUID NOT NULL -- references users(id) deferred below
);

CREATE TABLE users (
  id UUID PRIMARY KEY,
  email TEXT NOT NULL,
  active_org_id UUID NOT NULL REFERENCES organizations(id)
);

-- Add deferred foreign key to break cyclic creation chicken-and-egg trap
ALTER TABLE organizations 
ADD CONSTRAINT fk_org_owner 
FOREIGN KEY (owner_id) 
REFERENCES users (id) 
DEFERRABLE INITIALLY DEFERRED;
```

---

## 4. Production Reference Implementation: TypeScript & SQL

### 4.1 TypeScript: `AgenticDatabaseForeignKeyEngine`

A complete production governance engine providing schema introspection for unindexed foreign keys, zero-downtime migration generation, and safe chunked cascade deletion workers.

```typescript
import { Pool, PoolClient } from 'pg';

export interface UnindexedForeignKey {
  schema: string;
  table: string;
  constraintName: string;
  columns: string[];
  referencedTable: string;
  referencedColumns: string[];
}

export interface CascadeBatchConfig {
  parentTable: string;
  childTable: string;
  foreignKeyCol: string;
  parentId: string;
  batchSize?: number;
  pauseMs?: number;
  maxReplicaLagSeconds?: number;
}

export interface CascadeResult {
  totalRowsDeleted: number;
  batchCount: number;
  durationMs: number;
}

export class AgenticDatabaseForeignKeyEngine {
  constructor(private readonly pool: Pool) {}

  /**
   * Introspects database catalog and detects 100% of foreign keys
   * that lack a supporting leftmost-prefix B-tree index.
   */
  async findUnindexedForeignKeys(): Promise<UnindexedForeignKey[]> {
    const query = `
      SELECT
        c.connamespace::regnamespace::text AS schema_name,
        c.conrelid::regclass::text AS table_name,
        c.conname AS constraint_name,
        ARRAY_AGG(att.attname ORDER BY u.attposition) AS fk_columns,
        c.confrelid::regclass::text AS referenced_table,
        ARRAY_AGG(ref_att.attname ORDER BY u.attposition) AS ref_columns
      FROM pg_constraint c
      JOIN LATERAL UNNEST(c.conkey) WITH ORDINALITY AS u(attnum, attposition) ON true
      JOIN pg_attribute att ON att.attrelid = c.conrelid AND att.attnum = u.attnum
      JOIN pg_attribute ref_att ON ref_att.attrelid = c.confrelid AND ref_att.attnum = c.confkey[u.attposition]
      WHERE c.contype = 'f'
        AND NOT EXISTS (
          SELECT 1
          FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND i.indisvalid = true
            AND (i.indkey[0:array_length(c.conkey, 1) - 1] = c.conkey)
        )
      GROUP BY c.connamespace, c.conrelid, c.conname, c.confrelid
      ORDER BY schema_name, table_name, constraint_name;
    `;

    const res = await this.pool.query(query);
    return res.rows.map(row => ({
      schema: row.schema_name,
      table: row.table_name,
      constraintName: row.constraint_name,
      columns: row.fk_columns,
      referencedTable: row.referenced_table,
      referencedColumns: row.ref_columns,
    }));
  }

  /**
   * Generates safe, zero-downtime SQL migration statements to attach a foreign key.
   */
  generateZeroDowntimeFK(params: {
    childTable: string;
    parentTable: string;
    childColumns: string[];
    parentColumns: string[];
    constraintName: string;
    onDelete?: 'RESTRICT' | 'CASCADE' | 'SET NULL' | 'NO ACTION';
  }): string[] {
    const { childTable, parentTable, childColumns, parentColumns, constraintName, onDelete = 'RESTRICT' } = params;
    const indexName = `idx_${childTable.replace(/[^a-zA-Z0-9_]/g, '_')}_${childColumns.join('_')}`;

    return [
      `-- Step 1: Create supporting B-tree index concurrently (non-blocking)`,
      `CREATE INDEX CONCURRENTLY IF NOT EXISTS ${indexName} ON ${childTable} (${childColumns.join(', ')});`,
      `\n-- Step 2: Attach foreign key as NOT VALID (sub-millisecond lock, validates future writes)`,
      `ALTER TABLE ${childTable} ADD CONSTRAINT ${constraintName} FOREIGN KEY (${childColumns.join(', ')}) REFERENCES ${parentTable} (${parentColumns.join(', ')}) ON DELETE ${onDelete} NOT VALID;`,
      `\n-- Step 3: Validate constraint asynchronously (reads child table under non-blocking SHARE UPDATE EXCLUSIVE lock)`,
      `ALTER TABLE ${childTable} VALIDATE CONSTRAINT ${constraintName};`,
    ];
  }

  /**
   * Executes bounded, keyset-paginated cascade deletions to safely prune
   * large parent-child associations without locking the database or blowing WAL.
   */
  async executeBoundedCascadeDelete(config: CascadeBatchConfig): Promise<CascadeResult> {
    const {
      childTable,
      foreignKeyCol,
      parentId,
      batchSize = 1000,
      pauseMs = 50,
      maxReplicaLagSeconds = 1.0,
    } = config;

    const startTime = Date.now();
    let totalDeleted = 0;
    let batchCount = 0;

    while (true) {
      // 1. Check replication lag before next batch to prevent replica starvation
      const lag = await this.checkMaxReplicaLagSeconds();
      if (lag > maxReplicaLagSeconds) {
        await new Promise(r => setTimeout(r, 500));
        continue;
      }

      // 2. Delete single bounded batch using primary key keyset
      const deleteQuery = `
        WITH candidates AS (
          SELECT id
          FROM ${childTable}
          WHERE ${foreignKeyCol} = $1
          LIMIT $2
          FOR UPDATE SKIP LOCKED
        )
        DELETE FROM ${childTable}
        WHERE id IN (SELECT id FROM candidates)
        RETURNING id;
      `;

      const res = await this.pool.query(deleteQuery, [parentId, batchSize]);
      const deletedInBatch = res.rowCount ?? 0;
      totalDeleted += deletedInBatch;
      batchCount++;

      if (deletedInBatch < batchSize) {
        // Reached end of child records
        break;
      }

      if (pauseMs > 0) {
        await new Promise(r => setTimeout(r, pauseMs));
      }
    }

    return {
      totalRowsDeleted: totalDeleted,
      batchCount,
      durationMs: Date.now() - startTime,
    };
  }

  /**
   * Inspects active replication lag across connected streaming replicas.
   */
  private async checkMaxReplicaLagSeconds(): Promise<number> {
    const lagQuery = `
      SELECT COALESCE(MAX(EXTRACT(EPOCH FROM (NOW() - replay_lsn_timestamp))), 0) AS max_lag_seconds
      FROM (
        SELECT replay_lsn,
               pg_last_xact_replay_timestamp() AS replay_lsn_timestamp
        FROM pg_stat_replication
      ) s;
    `;
    try {
      const res = await this.pool.query(lagQuery);
      return parseFloat(res.rows[0]?.max_lag_seconds || '0');
    } catch {
      return 0; // Standalone database or unprivileged role
    }
  }
}
```

### 4.2 Diagnostic & Audit SQL: Unindexed Foreign Keys & Cascade Lock Contention

Save this script as `migrations/diagnostic_foreign_keys.sql` to detect unindexed foreign keys and measure lock contention in production:

```sql
-- ============================================================================
-- 1. Introspect Unindexed Foreign Keys in PostgreSQL
-- Run in CI or production health checks to catch missing FK indexes.
-- ============================================================================
SELECT
  c.conrelid::regclass AS table_name,
  c.conname AS foreign_key_name,
  ARRAY_TO_STRING(ARRAY_AGG(att.attname ORDER BY u.attposition), ', ') AS fk_columns,
  c.confrelid::regclass AS referenced_parent_table,
  ARRAY_TO_STRING(ARRAY_AGG(ref_att.attname ORDER BY u.attposition), ', ') AS parent_pk_columns,
  pg_size_pretty(pg_total_relation_size(c.conrelid)) AS child_table_size
FROM pg_constraint c
JOIN LATERAL UNNEST(c.conkey) WITH ORDINALITY AS u(attnum, attposition) ON true
JOIN pg_attribute att ON att.attrelid = c.conrelid AND att.attnum = u.attnum
JOIN pg_attribute ref_att ON ref_att.attrelid = c.confrelid AND ref_att.attnum = c.confkey[u.attposition]
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1
    FROM pg_index i
    WHERE i.indrelid = c.conrelid
      AND i.indisvalid = true
      AND (i.indkey[0:array_length(c.conkey, 1) - 1] = c.conkey)
  )
GROUP BY c.conrelid, c.conname, c.confrelid
ORDER BY pg_total_relation_size(c.conrelid) DESC;

-- ============================================================================
-- 2. Inspect Active Transactions Blocked on Foreign Key Lock Contention
-- Identifies transactions stuck waiting on ShareRowExclusiveLock or tuple locks.
-- ============================================================================
SELECT
  blocked_locks.pid AS blocked_pid,
  blocked_activity.usename AS blocked_user,
  blocking_locks.pid AS blocking_pid,
  blocking_activity.usename AS blocking_user,
  blocked_activity.query AS blocked_statement,
  blocking_activity.query AS blocking_statement,
  NOW() - blocked_activity.query_start AS blocked_duration
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks 
  ON blocking_locks.locktype = blocked_locks.locktype
  AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
  AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
  AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
  AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
  AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
  AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
  AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
  AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
  AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
  AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;
```

---

## 5. Foreign Key Lifecycle Finite-State Machine (FSM)

```
       [ SCHEMA_DESIGN ]
              │
              │ 1. Validate composite tenant_id & supporting index
              ▼
    [ NOT_VALID_ATTACHED ]  ◄── ALTER TABLE ... ADD CONSTRAINT ... NOT VALID
              │
              │ 2. Asynchronous background validation
              ▼
   [ VALIDATING_CONCURRENT ] ◄── ALTER TABLE ... VALIDATE CONSTRAINT (SHARE UPDATE EXCLUSIVE)
              │
              │ 3. Validation complete; zero runtime table locks
              ▼
       [ ACTIVE_INDEXED ]   ─── Enforces referential integrity at O(log N) cost
              │
              │ 4. Parent deletion requested on large hierarchy
              ▼
   [ BATCH_CASCADE_PURGE ]  ─── Keyset chunked deletions (LIMIT 1,000, tau_lag < 1.0s)
              │
              │ 5. Safe uncoupling / deprecation
              ▼
      [ DECOMMISSIONED ]    ─── DROP CONSTRAINT fk
```

### State Transition Invariants:
1. **`SCHEMA_DESIGN` $\to$ `NOT_VALID_ATTACHED`**: Must assert that a supporting B-tree index exists or is created concurrently prior to or simultaneously with constraint creation. Synchronous monolithic constraints without `NOT VALID` are rejected.
2. **`NOT_VALID_ATTACHED` $\to$ `VALIDATING_CONCURRENT`**: Validation statement runs with statement timeout and lock timeout ladders (`SET LOCAL statement_timeout = '30m'`).
3. **`VALIDATING_CONCURRENT` $\to$ `ACTIVE_INDEXED`**: Constraint marked `convalidated = true` in `pg_constraint`.
4. **`ACTIVE_INDEXED` $\to$ `BATCH_CASCADE_PURGE`**: Deletion of parent entities with $>1,000$ descendants MUST route to the batched keyset cascade worker rather than executing declarative synchronous `ON DELETE CASCADE`.

---

## 6. Machine-Verifiable Definition of Done (DoD)

| Gate | Focus Area | Verification Rule | CI / Test Assertion |
| :--- | :--- | :--- | :--- |
| **Gate 0: Zero Unindexed Foreign Keys** | Indexing Governance | 100% of foreign key columns have supporting B-tree indexes where the FK column is the leftmost prefix. | Query `pg_constraint` vs `pg_index`; count of unindexed foreign keys MUST equal 0. |
| **Gate 1: Zero Synchronous FK Additions** | Migration Safety | Zero `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY` without `NOT VALID` in DDL migration files. | Regex linter fails if `ADD CONSTRAINT .* FOREIGN KEY` is not followed by `NOT VALID`. |
| **Gate 2: Composite Tenant Boundaries** | Multi-Tenant Isolation | In multi-tenant tables, all foreign keys to tenant-scoped parents MUST include `tenant_id`. | Catalog audit: every FK to a table possessing `tenant_id` must match `(tenant_id, parent_id)`. |
| **Gate 3: Bounded Cascade Deletion** | WAL & Lock Defense | Large cascade deletions are executed via keyset micro-batches ($\le 1000$ rows) with lag throttling. | Integration test: deleting parent with 50,000 child rows holds row locks for $\le 10\text{ms}$ per batch. |
| **Gate 4: Cyclic Dependency Deferral** | Transaction Integrity | Cyclic foreign keys are declared `DEFERRABLE INITIALLY DEFERRED` or decoupled. | Automated migration replay asserts circular parent-child insertions succeed without error 23503. |
| **Gate 5: Deadlock-Free Canonical Ordering** | Concurrency Safety | Multi-row parent updates and child insertions acquire parent locks in ascending canonical ID order. | Concurrency stress test: 20 parallel workers perform interleaved operations with 0 SQLSTATE 40P01 aborts. |

### Summary of Catastrophes & Automated Remedies

| Failure Mode | Production Impact | Automated Architectural Remedy |
| :--- | :--- | :--- |
| **Unindexed Foreign Key** | Parent updates/deletes trigger full table sequential scans on child, locking rows and exhausting connection pools in seconds. | **Mandatory Leftmost Prefix B-Tree Index**: Every foreign key must have an index starting with the referencing column(s). Verified via CI catalog query. |
| **Monolithic ON DELETE CASCADE** | Deleting a parent deletes hundreds of thousands of child rows in one transaction, blowing lock tables, saturating WAL, and spiking replica lag. | **Bounded Keyset Cascade Worker**: Replace declarative cascade with background keyset chunking (`LIMIT 1000`) throttled on replica lag $\tau_{\text{lag}} < 1.0\text{s}$. |
| **Synchronous FK Creation** | `ALTER TABLE ADD CONSTRAINT FOREIGN KEY` freezes both parent and child relations under `ACCESS EXCLUSIVE` during full-table scan. | **Two-Phase NOT VALID Protocol**: Add constraint with `NOT VALID` (instant metadata lock), then execute non-blocking `VALIDATE CONSTRAINT`. |
| **Cross-Tenant FK Leak** | Single-column FK allows Tenant A's child row to point to Tenant B's parent row if application logic passes corrupted UUID. | **Composite Multi-Tenant Foreign Keys**: Enforce `FOREIGN KEY (tenant_id, parent_id) REFERENCES parent(tenant_id, id)` backed by parent composite unique index. |
| **Cyclic Dependency Abort** | Mutually referencing tables fail initial insertion with immediate SQLSTATE 23503 foreign key violations. | **DEFERRABLE INITIALLY DEFERRED**: Defer constraint checks to `COMMIT` time or use nullable 2-phase insertion. |
| **Parent-Child Deadlocks** | Concurrent transactions interleaving child inserts (`FOR KEY SHARE`) and parent updates deadlock with SQLSTATE 40P01. | **Canonical Lexicographical Ordering**: Sort parent entity IDs in strict ascending order before locking or mutating rows. |
