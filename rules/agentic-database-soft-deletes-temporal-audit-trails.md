---
description: Database soft deletes, partial unique indexes, transparent RLS filtering, atomic recursive cascade CTEs, bi-temporal data modeling, immutable change-data audit ledgers, and cryptographic hash-chaining across Go (pgx/sqlc), TypeScript (Drizzle/Prisma), Python (SQLAlchemy), Rust (sqlx), PostgreSQL, Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{soft-delete,softdelete,temporal,audit,auditing,history,versioning,ledger,bitemporal,event-log,changelog,tstzrange,undo,restore}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/repository/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Soft Deletes, Temporal Versioning & Immutable Audit Trail Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design entity lifecycle management, soft-delete mechanisms, undo/restore capabilities, bi-temporal records, regulatory compliance audit trails (SOC 2 Type II, HIPAA, GDPR, ISO 27001), or financial historical ledgers across PostgreSQL, Go (`jackc/pgx`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`SQLAlchemy 2.0`), or Rust (`sqlx`). Eliminate the "Ghost Record Zombie Query Leak" (where queries omit `WHERE deleted_at IS NULL` across complex multi-table joins or nested aggregations, resurrecting deleted accounts, cancelled orders, or revoked API keys), the "Unique Constraint Re-registration Collision" (where naive `UNIQUE(email)` or `UNIQUE(tenant_id, slug)` constraints block legitimate re-creation of previously soft-deleted entities), the "Missing Cascade Soft-Delete Orphan Trap" (where database foreign key `ON DELETE CASCADE` fails to trigger on `UPDATE ... SET deleted_at = NOW()`, stranding active child records linked to a ghost parent), the "Cascade Soft Delete Lock Convulsion & Memory Avalanche" (where agents attempt iterative in-memory child updates, triggering deadlocks and transaction timeouts), the "Mutable Audit Log Tampering & Provenance Falsification Trap" (where update-in-place mutations destroy change provenance and allow historical modification), and the "Bi-Temporal Amnesia & Time-Travel Distortion Catastrophe" (where business logic conflates System/Transaction Time with Valid/Business Time, corrupting historical point-in-time financial reconciliation) by establishing a strict 5-Tier Soft Delete & Temporal Data Governance Ladder, partial unique indexes, transparent Row-Level Security (RLS) filter policies, single-statement recursive cascade CTEs, cryptographic hash-chained audit ledgers, and PostgreSQL range-type exclusion constraints.

---

## 1. Architectural Taxonomy: The 6 Soft Delete & Temporal Catastrophes vs The 5-Tier Soft Delete & Temporal Data Governance Ladder

When autonomous coding agents generate database access layers for web applications, LLMs universally default to adding a `deleted_at TIMESTAMP NULL` or `is_deleted BOOLEAN DEFAULT false` column to simulate non-destructive deletion. However, LLMs fail to anticipate the profound relational, indexing, and compliance consequences of soft deletion. In complex relational schemas, soft deletion alters the fundamental semantics of uniqueness, foreign keys, set completeness, and query optimization:

```typescript
// ❌ CATASTROPHIC LLM SOFT DELETE ANTI-PATTERNS (Ghost Records, Constraint Collisions, Broken Cascades)
// Migration: Table created with standard UNIQUE constraint
// CREATE TABLE organizations (id UUID PRIMARY KEY, slug TEXT UNIQUE NOT NULL, deleted_at TIMESTAMPTZ);

async function deleteAndRecreateWorkspace(oldOrgId: string, slug: string) {
  // Bug 1: Soft-delete organization
  await db.update(organizations).set({ deletedAt: new Date() }).where(eq(organizations.id, oldOrgId));
  // BUG: Child projects, api_keys, and members are STILL ACTIVE! ON DELETE CASCADE does not fire on UPDATE!

  // Bug 2: Recreate organization with same slug
  // CATASTROPHIC ERROR: duplicate key value violates unique constraint "organizations_slug_key"!
  // Standard UNIQUE index includes both active AND soft-deleted rows!
  await db.insert(organizations).values({ slug, name: 'New Org' });

  // Bug 3: Analytical query leaking soft-deleted ghost records
  // Agent forgets `where(isNull(organizations.deletedAt))` in nested JOIN
  const activeStats = await db.select({ count: count() }).from(organizations)
    .innerJoin(projects, eq(organizations.id, projects.orgId)); // Leaks deleted orgs!
}
```

In high-concurrency microservices, multi-tenant databases, or multi-agent autonomous execution loops, naive soft delete and temporal implementations trigger six critical architectural catastrophes:

- **The "Ghost Record Zombie Query Leak" (Unfiltered Join & Aggregation Amnesia)**:
  - An Agent or engineer implements 50 queries across the repository. In 46 queries, they remember to write `WHERE deleted_at IS NULL`. In 4 queries (such as cross-tenant reporting, subqueries, elasticsearch synchronization jobs, or `LEFT JOIN` aggregations), the filter is inadvertently omitted.
  - Soft-deleted users reappear in employee directories, cancelled subscriptions generate unauthorized invoice renewals, and revoked OAuth tokens pass validation checks.
  - Invariant: Application queries MUST NOT rely on manual, discretionary `WHERE deleted_at IS NULL` clauses. Soft-deletion filtering MUST be enforced declaratively at the database catalog layer via filtered Views or transparent PostgreSQL Row-Level Security (RLS) policies.

- **The "Unique Constraint Re-registration Collision" (Active-Row Index Contamination)**:
  - A user soft-deletes their account (`deleted_at = NOW()`), releasing their username or email `alice@company.com`.
  - Later, Alice re-registers or another employee joins with the same email.
  - The database rejects the insertion with PostgreSQL error `23505: unique_violation` because the standard B-tree index `UNIQUE (email)` indexes all rows regardless of deletion status.
  - Naive agents attempt dangerous workarounds like appending random UUID suffixes to emails (`alice@company.com_deleted_1672531199`), irreversibly destroying historical identity, breaking search indexes, and corrupting foreign key audit records.
  - Invariant: Unique constraints on soft-deletable tables MUST be declared as partial indexes scoped strictly to active rows: `CREATE UNIQUE INDEX ... WHERE deleted_at IS NULL;`.

- **The "Missing Cascade Soft-Delete Orphan Trap" (Relational Integrity Decoupling)**:
  - In standard SQL schemas, referential integrity is preserved via `FOREIGN KEY (parent_id) REFERENCES parents(id) ON DELETE CASCADE`.
  - When an Agent executes a soft delete (`UPDATE parents SET deleted_at = NOW() WHERE id = :id`), the SQL engine executes an `UPDATE`—the database physical `ON DELETE CASCADE` rule NEVER fires.
  - Hundreds of thousands of child records (`tasks`, `documents`, `comments`, `permissions`) remain with `deleted_at IS NULL`.
  - Child records remain directly addressable by primary key (`GET /api/documents/:child_id`), exposing sensitive documents belonging to a "deleted" parent organization.
  - Invariant: Deleting a parent entity MUST cascade deletion to all dependent children atomically in the exact same transaction, either via recursive Common Table Expressions (CTEs) or database triggers, tagging all affected records with an identical tombstone batch identifier.

- **The "Cascade Soft Delete Lock Convulsion & Memory Avalanche"**:
  - To solve the orphan trap, an Agent fetches all dependent child IDs into application memory in Node.js or Python (`SELECT id FROM items WHERE project_id = :id`) and runs iterative batch updates.
  - When deleting an enterprise project with 100,000 items, the application exhausts heap memory, exceeds gateway HTTP timeouts ($>30\text{s}$), and acquires long-lived row locks across multiple tables, triggering database deadlocks (`40P01`) and starving the connection pool.
  - Invariant: Cascade soft deletions MUST execute entirely inside the database engine via single-statement recursive CTEs, executing in $O(1)$ database roundtrips with bounded statement timeouts (`statement_timeout <= 5000ms`).

- **The "Mutable Audit Log Tampering & Provenance Falsification Trap"**:
  - An Agent implements an "audit log" table. However, the table allows `UPDATE` and `DELETE` operations.
  - A buggy migration, rogue script, or compromised credential executes an update or delete against the audit table, permanently destroying forensic provenance.
  - SOC 2 Type II, HIPAA, and ISO 27001 compliance auditors reject the architecture because audit records lack cryptographic immutability and forward integrity.
  - Invariant: Audit logs MUST be append-only tables guarded by database triggers that raise exceptions on any `UPDATE` or `DELETE`, and each audit entry MUST include a cryptographic hash linking to the previous entry ($H_n = \text{SHA256}(H_{n-1} \parallel \text{data})$).

- **The "Bi-Temporal Amnesia & Time-Travel Distortion Catastrophe"**:
  - In financial ledgers, payroll systems, or medical billing, an Agent modifies a contract rate retroactive to the previous month.
  - If the database only stores a single timestamp or overwrites the record in-place, the business loses the ability to reconstruct what the ledger state was *as known on October 1st* versus *what actually occurred on October 1st*.
  - Historical financial audits fail, and retroactive billing recalculations produce phantom discrepancies.
  - Invariant: Mission-critical state changes MUST be modeled bi-temporally, decoupling Valid Time (business validity interval) from System / Transaction Time (database physical commit interval) using PostgreSQL range types (`tstzrange`) and non-overlapping GiST exclusion constraints (`EXCLUDE USING gist`).

---

### The 5-Tier Soft Delete & Temporal Data Governance Ladder

```
[Tier 4: Native Bi-Temporal Modeling & GiST Non-Overlapping Exclusion Constraints]
       ▲  (tstzrange Valid/System Time, AS OF Point-in-Time Traversal, GiST Temporal Invariance)
[Tier 3: Append-Only Immutable Change Ledgers with Cryptographic Hash-Chaining]
       ▲  (BEFORE UPDATE/DELETE Triggers RAISE EXCEPTION, SHA-256 Merkle Chaining, SOC2 Immutability)
[Tier 2: Single-Statement Recursive Cascade CTEs & Tombstone Batch Tagging]
       ▲  (Atomic Parent-Child Soft Deletes, Zero-Orphan Tree Guarantee, Tombstone Batch ID for Safe Undos)
[Tier 1: Declarative Transparent Soft-Delete RLS Policies & Filtered Views]
       ▲  (FORCE ROW LEVEL SECURITY, USING (deleted_at IS NULL), Zero-Omission Query Completeness)
[Tier 0: Partial Unique Indexes & Explicit Active-State Projections]
          (CREATE UNIQUE INDEX ... WHERE deleted_at IS NULL, Explicit Projections, Sane Nullable Timestamps)
```

| Governance Tier | Primary Mechanism | Guaranteed Invariant | Performance Impact | Failure Mode Prevented |
| :--- | :--- | :--- | :--- | :--- |
| **Tier 0: Partial Unique Indexes** | `UNIQUE (...) WHERE deleted_at IS NULL` | Allows re-creating deleted slugs; index excludes tombstones | $0\%$ query overhead; smaller B-tree size | Unique constraint collision on re-registration |
| **Tier 1: Transparent RLS Policies** | `CREATE POLICY ... USING (deleted_at IS NULL)` | Prevents accidental query omissions across 100% of joins | $<2\%$ planner evaluation overhead | Ghost record leaks into public APIs or search |
| **Tier 2: Recursive Cascade CTEs** | `WITH del_p AS (...), del_c AS (...) UPDATE ...` | Single-statement atomic multi-table soft deletion | 1 roundtrip; eliminates memory exhaustion | Stranded active child orphans; lock exhaustion |
| **Tier 3: Hash-Chained Audit Ledgers** | Append-only triggers + SHA-256 cryptographic chain | Forward-integrity; impossible to tamper with history | Minimal insert overhead; tamper-evident verification | Audit trail falsification; compliance failure |
| **Tier 4: Native Bi-Temporal Ranges** | `valid_period tstzrange`, `EXCLUDE USING gist` | Disjoint historical validity intervals; reproducible state | GiST index seek; deterministic `AS OF` time-travel | Historical financial reconciliation distortion |

---

## 2. Mathematical Invariants: Query Completeness, Partial Index Physics, Cascade Graphs & Cryptographic Audit Chains

### 1. The Query Completeness Theorem & RLS Equivalence
Let $\mathcal{T}$ be a relational relation containing tuples $t \in \mathcal{T}$. Each tuple contains attributes $\text{Attrs}(t)$ and a temporal tombstone attribute $\text{deleted\_at} \in \mathbb{T} \cup \{ \bot \}$, where $\bot$ denotes `NULL` (active state).
The active subset of relation $\mathcal{T}$ is formally defined as:
$$\mathcal{T}_{\text{active}} \triangleq \{ t \in \mathcal{T} \mid t.\text{deleted\_at} = \bot \}$$
The soft-deleted tombstone subset is:
$$\mathcal{T}_{\text{tombstone}} \triangleq \{ t \in \mathcal{T} \mid t.\text{deleted\_at} \neq \bot \}$$
Clearly, $\mathcal{T}_{\text{active}} \cap \mathcal{T}_{\text{tombstone}} = \emptyset$ and $\mathcal{T}_{\text{active}} \cup \mathcal{T}_{\text{tombstone}} = \mathcal{T}$.

An arbitrary application query $Q$ operating over relations $\mathcal{T}_1, \mathcal{T}_2, \dots, \mathcal{T}_k$ is sound under soft deletion if and only if:
$$Q(\mathcal{T}_1, \dots, \mathcal{T}_k) \equiv Q(\mathcal{T}_{1, \text{active}}, \dots, \mathcal{T}_{k, \text{active}})$$
When queries rely on manual developer discipline, the probability of query leakage $P(\text{leak})$ over $N$ queries with per-query omission probability $p > 0$ is:
$$P(\text{leak}) = 1 - (1 - p)^N \xrightarrow[N \to \infty]{} 1$$
By contrast, applying PostgreSQL Row-Level Security (RLS) with security filter predicate $\Phi(t) \equiv (t.\text{deleted\_at IS NULL})$ guarantees:
$$Q_{\text{RLS}}(\mathcal{T}) \equiv \sigma_{\Phi}(Q(\mathcal{T})) \equiv Q(\mathcal{T}_{\text{active}}) \implies P(\text{leak}) \equiv 0$$

### 2. Partial Unique Index Physics & Re-registration Invariance
A conventional unique B-tree constraint over columns $\mathbf{K} = (c_1, \dots, c_m)$ enforces:
$$\forall t_1, t_2 \in \mathcal{T}, \quad \left( \bigwedge_{i=1}^m t_1.c_i = t_2.c_i \right) \implies t_1.\text{id} = t_2.\text{id}$$
If $t_1 \in \mathcal{T}_{\text{tombstone}}$, no active tuple $t_2 \in \mathcal{T}_{\text{active}}$ may ever be inserted with matching keys $\mathbf{K}$, causing the **Re-registration Collision Catastrophe**.

A Partial Unique Index enforces uniqueness strictly over the active predicate:
$$\forall t_1, t_2 \in \mathcal{T}, \quad \left( \bigwedge_{i=1}^m t_1.c_i = t_2.c_i \land t_1.\text{deleted\_at} = \bot \land t_2.\text{deleted\_at} = \bot \right) \implies t_1.\text{id} = t_2.\text{id}$$
This guarantees:
1. Active key uniqueness: $|\{ t \in \mathcal{T}_{\text{active}} \mid t.\mathbf{K} = \mathbf{k} \}| \le 1$.
2. Infinite tombstone retention: $|\{ t \in \mathcal{T}_{\text{tombstone}} \mid t.\mathbf{K} = \mathbf{k} \}| = M \ge 0$.
3. Minimal index footprint: The B-tree index stores only $|\mathcal{T}_{\text{active}}|$ pointers, reducing index size by $\frac{|\mathcal{T}_{\text{tombstone}}|}{|\mathcal{T}|} \times 100\%$ and maximizing buffer pool cache hit ratios.

### 3. Cascade Invariant & Tombstone Batch Coherence
Let $G = (V, E)$ be the directed acyclic graph of relational dependencies, where vertices $v \in V$ represent tables and directed edges $(u, v) \in E$ represent foreign key dependencies from parent $u$ to child $v$.
When a parent record $p \in u$ is soft-deleted at timestamp $t_{\text{del}}$, the Zero-Orphan Invariant mandates:
$$\forall v \in \text{Descendants}(u), \forall c \in v \text{ such that } c \to^* p \implies c.\text{deleted\_at} \neq \bot$$
Furthermore, to enable deterministic, un-ambiguous restoration ("Undo"), all records deleted in the same logical cascade operation MUST share an identical, unique **Tombstone Batch Identifier** $\beta \in \text{UUID}$:
$$t \in \text{Cascade}(p) \implies t.\text{deleted\_batch\_id} = \beta_{p}$$
When restoring parent $p$, only child records where $c.\text{deleted\_batch\_id} = \beta_p$ are restored, preventing the accidental resurrection of child records that were independently deleted *prior* to the parent deletion.

### 4. Cryptographic Forward-Integrity Audit Chain
Let $A = (a_1, a_2, \dots, a_n)$ be the sequence of immutable audit records for an entity. Each audit record $a_i$ contains:
$$a_i = \langle \text{id}_i, \text{entity\_id}, \tau_i, \text{actor\_id}, \text{action}, \Delta_i, H_{i-1}, H_i \rangle$$
Where $\Delta_i \in \text{JSONB}$ is the canonical JSON diff of the mutation, and $H_i$ is computed via HMAC-SHA256:
$$H_0 \triangleq \text{SHA256}(\text{"GENESIS:"} \parallel \text{entity\_id})$$
$$H_i \triangleq \text{HMAC-SHA256}\left( K_{\text{audit}}, H_{i-1} \parallel \text{id}_i \parallel \tau_i \parallel \text{actor\_id} \parallel \text{action} \parallel \text{Canonical}(\Delta_i) \right)$$
If an adversary or rogue query alters any historical audit record $a_k$ ($1 \le k < n$), then for all subsequent records $j \ge k$, $H_j \neq \text{Recomputed}(H_j)$, immediately exposing tampering with mathematical certainty.

### 5. Bi-Temporal Interval Disjointness & Containment
A bi-temporal tuple $t$ has two independent temporal intervals:
- **Valid Time Interval** $V(t) = [v_{\text{start}}, v_{\text{end}}) \in \mathbb{T}^2$: The real-world timeframe during which the state was true in reality.
- **System / Transaction Time Interval** $S(t) = [s_{\text{start}}, s_{\text{end}}) \in \mathbb{T}^2$: The database timeframe during which the record was physically stored in the database.

The Non-Overlapping Valid Time Invariant mandates that for any given entity identifier $\text{entity\_id}$, at any historical system time $s \in \mathbb{T}$, the valid time intervals MUST be strictly disjoint:
$$\forall t_1, t_2 \in \mathcal{T}, \quad \left( t_1.\text{entity\_id} = t_2.\text{entity\_id} \land t_1 \neq t_2 \land S(t_1) \cap S(t_2) \neq \emptyset \right) \implies V(t_1) \cap V(t_2) = \emptyset$$
In PostgreSQL, this invariant is enforced at the storage engine layer using a GiST exclusion constraint:
$$\text{EXCLUDE USING gist (entity\_id WITH =, valid\_period WITH \&\&)}$$

---

## 3. Production TypeScript Implementation: `AgenticSoftDeleteTemporalEngine`

Below is the complete, production-ready, zero-dependency TypeScript implementation of `AgenticSoftDeleteTemporalEngine`. It provides atomic cascade soft-deletion with tombstone batch tracking, collision-free restoration with active unique pre-flight verification, transparent RLS configuration, and cryptographic audit hash-chaining.

```typescript
// agentic-soft-delete-temporal-engine.ts
import { createHmac, createHash } from 'node:crypto';

export type EntityId = string;
export type TombstoneBatchId = string;

export interface AuditRecord<T = Record<string, unknown>> {
  id: string;
  entityName: string;
  entityId: EntityId;
  action: 'INSERT' | 'UPDATE' | 'SOFT_DELETE' | 'RESTORE' | 'HARD_PURGE';
  actorId: string;
  timestamp: string; // ISO-8601 UTC
  delta: {
    before?: Partial<T>;
    after?: Partial<T>;
  };
  previousHash: string;
  hash: string;
}

export interface SoftDeletableEntity {
  id: EntityId;
  deletedAt: Date | null;
  deletedBy: string | null;
  deletedBatchId: TombstoneBatchId | null;
  version: number;
  [key: string]: unknown;
}

export interface CascadeRelation {
  childTable: string;
  foreignKey: string;
  softDeletable: boolean;
}

export interface EngineConfig {
  hmacSecret: string;
  enforceRls?: boolean;
}

export interface QueryOptions {
  includeDeleted?: boolean;
  asOfSystemTime?: Date;
}

export class AgenticSoftDeleteTemporalEngine {
  private readonly hmacSecret: string;
  private readonly cascadeRegistry: Map<string, CascadeRelation[]> = new Map();

  constructor(config: EngineConfig) {
    this.hmacSecret = config.hmacSecret;
  }

  /**
   * Register child relationships for cascading soft-deletions
   */
  public registerCascade(parentTable: string, relation: CascadeRelation): void {
    const existing = this.cascadeRegistry.get(parentTable) || [];
    existing.push(relation);
    this.cascadeRegistry.set(parentTable, existing);
  }

  /**
   * Computes the canonical genesis hash for an entity audit chain
   */
  public computeGenesisHash(entityName: string, entityId: EntityId): string {
    return createHash('sha256')
      .update(`GENESIS:${entityName}:${entityId}`)
      .digest('hex');
  }

  /**
   * Computes the HMAC-SHA256 signature for an audit record, enforcing forward integrity
   */
  public computeAuditHash(
    previousHash: string,
    record: Omit<AuditRecord, 'hash' | 'previousHash'>
  ): string {
    const canonicalPayload = JSON.stringify({
      id: record.id,
      entityName: record.entityName,
      entityId: record.entityId,
      action: record.action,
      actorId: record.actorId,
      timestamp: record.timestamp,
      delta: record.delta,
      previousHash,
    });

    return createHmac('sha256', this.hmacSecret)
      .update(canonicalPayload)
      .digest('hex');
  }

  /**
   * Verifies the cryptographic integrity of an entire entity audit trail.
   * Returns true if all hashes match and chain is unbroken.
   */
  public verifyAuditChain(records: AuditRecord[]): { valid: boolean; corruptedAtId?: string } {
    if (records.length === 0) return { valid: true };

    let expectedPrevHash = this.computeGenesisHash(records[0].entityName, records[0].entityId);

    for (const record of records) {
      if (record.previousHash !== expectedPrevHash) {
        return { valid: false, corruptedAtId: record.id };
      }

      const recomputedHash = this.computeAuditHash(record.previousHash, record);
      if (recomputedHash !== record.hash) {
        return { valid: false, corruptedAtId: record.id };
      }

      expectedPrevHash = record.hash;
    }

    return { valid: true };
  }

  /**
   * Generates a single-statement recursive SQL CTE for PostgreSQL to atomically
   * soft-delete a parent entity and all registered cascade children with an identical batch ID.
   */
  public generateCascadeSoftDeleteSQL(
    parentTable: string,
    parentId: EntityId,
    actorId: string,
    batchId: TombstoneBatchId
  ): { sql: string; params: unknown[] } {
    const relations = this.cascadeRegistry.get(parentTable) || [];
    const now = new Date().toISOString();

    let sql = `WITH target_parent AS (\n`;
    sql += `  UPDATE ${parentTable} SET\n`;
    sql += `    deleted_at = $1::timestamptz,\n`;
    sql += `    deleted_by = $2,\n`;
    sql += `    deleted_batch_id = $3::uuid,\n`;
    sql += `    version = version + 1\n`;
    sql += `  WHERE id = $4 AND deleted_at IS NULL\n`;
    sql += `  RETURNING id, deleted_batch_id\n`;
    sql += `)\n`;

    relations.forEach((rel, index) => {
      if (rel.softDeletable) {
        sql += `, del_child_${index} AS (\n`;
        sql += `  UPDATE ${rel.childTable} SET\n`;
        sql += `    deleted_at = $1::timestamptz,\n`;
        sql += `    deleted_by = $2,\n`;
        sql += `    deleted_batch_id = $3::uuid,\n`;
        sql += `    version = version + 1\n`;
        sql += `  WHERE ${rel.foreignKey} IN (SELECT id FROM target_parent) AND deleted_at IS NULL\n`;
        sql += `  RETURNING id\n`;
        sql += `)\n`;
      }
    });

    sql += `SELECT id, deleted_batch_id FROM target_parent;`;

    return {
      sql,
      params: [now, actorId, batchId, parentId],
    };
  }

  /**
   * Generates a single-statement SQL query to atomically restore a soft-deleted parent
   * and ONLY the children that were soft-deleted in that exact same batch ID.
   * Child records that were deleted prior to parent deletion remain safely tombstones.
   */
  public generateCascadeRestoreSQL(
    parentTable: string,
    parentId: EntityId,
    targetBatchId: TombstoneBatchId
  ): { sql: string; params: unknown[] } {
    const relations = this.cascadeRegistry.get(parentTable) || [];

    let sql = `WITH target_parent AS (\n`;
    sql += `  UPDATE ${parentTable} SET\n`;
    sql += `    deleted_at = NULL,\n`;
    sql += `    deleted_by = NULL,\n`;
    sql += `    deleted_batch_id = NULL,\n`;
    sql += `    version = version + 1\n`;
    sql += `  WHERE id = $1 AND deleted_batch_id = $2::uuid\n`;
    sql += `  RETURNING id\n`;
    sql += `)\n`;

    relations.forEach((rel, index) => {
      if (rel.softDeletable) {
        sql += `, res_child_${index} AS (\n`;
        sql += `  UPDATE ${rel.childTable} SET\n`;
        sql += `    deleted_at = NULL,\n`;
        sql += `    deleted_by = NULL,\n`;
        sql += `    deleted_batch_id = NULL,\n`;
        sql += `    version = version + 1\n`;
        sql += `  WHERE ${rel.foreignKey} IN (SELECT id FROM target_parent) AND deleted_batch_id = $2::uuid\n`;
        sql += `  RETURNING id\n`;
        sql += `)\n`;
      }
    });

    sql += `SELECT id FROM target_parent;`;

    return {
      sql,
      params: [parentId, targetBatchId],
    };
  }

  /**
   * Generates the standard PostgreSQL DDL for partial unique indexes, RLS policies,
   * and tamper-proof audit triggers for a soft-deletable table.
   */
  public generatePostgresHardeningDDL(tableName: string, uniqueColumns: string[]): string {
    const colList = uniqueColumns.join(', ');
    const indexName = `idx_${tableName}_unique_active`;
    const rlsPolicyName = `rls_${tableName}_active_isolation`;

    return `
-- 1. Partial Unique Index: Active uniqueness invariant, collision-free tombstone retention
CREATE UNIQUE INDEX IF NOT EXISTS ${indexName}
ON ${tableName} (${colList})
WHERE deleted_at IS NULL;

-- 2. Force Row-Level Security: Mathematically eliminates query omissions across all joins
ALTER TABLE ${tableName} ENABLE ROW LEVEL SECURITY;
ALTER TABLE ${tableName} FORCE ROW LEVEL SECURITY;

-- 3. Declarative Active Policy: Default-deny on soft-deleted rows
DROP POLICY IF EXISTS ${rlsPolicyName} ON ${tableName};
CREATE POLICY ${rlsPolicyName} ON ${tableName}
FOR ALL
TO authenticated, anon, service_role
USING (
  -- Active rows are accessible to all standard queries
  deleted_at IS NULL
  OR
  -- Allow audit/admin bypass ONLY when explicit transaction context setting is activated
  current_setting('app.include_soft_deleted', true) = 'true'
);
`.trim();
  }
}
```

---

## 4. The 6-State Soft Delete, Temporal Versioning & Audit Lifecycle Finite-State Machine (FSM)

Soft-deleted entities and temporal audit ledgers follow a strict, non-reversible, deterministic finite-state transition lifecycle:

```
                ┌─────────────────────────────────────────────────────────┐
                │                                                         │
                ▼                                                         │
  ┌─────────────────────────┐           ┌───────────────────────────┐     │
  │        1. ACTIVE        │──────────▶│     2. SOFT_DELETING      │     │
  │  (deleted_at IS NULL,   │           │ (Cascade CTE in-flight,   │     │
  │   visible in RLS/Views) │           │  Canonical key order lock)│     │
  └─────────────────────────┘           └─────────────┬─────────────┘     │
                ▲                                     │                   │
                │                                     ▼                   │
                │                       ┌───────────────────────────┐     │
                │                       │ 3. SOFT_DELETED_TOMBSTONE │     │
                │                       │ (Batch ID set, RLS hidden,│     │
                │                       │  Audit SHA-256 appended)  │     │
                │                       └─────────────┬─────────────┘     │
                │                                     │                   │
                │                                     ▼                   │
  ┌─────────────────────────┐           ┌───────────────────────────┐     │
  │       5. RESTORED       │◀──────────│    4. RESTORE_STAGING     │     │
  │ (Batch unmasked, audit  │           │ (Preflight unique check,  │     │
  │  RESTORE logged)        │           │  Confirm slug available)  │     │
  └─────────────┬───────────┘           └───────────────────────────┘     │
                │                                                         │
                └─────────────────────────────────────────────────────────┘
                                      │
                                      ▼
                        ┌───────────────────────────┐
                        │     6. PURGED_EXPUNGED    │
                        │ (Hard-delete after TTL,   │
                        │  GDPR Right to be Erasure)│
                        └───────────────────────────┘
```

| Current State | Event Trigger | Next State | Database Action & Invariant Check | Rollback Behavior |
| :--- | :--- | :--- | :--- | :--- |
| **1. ACTIVE** | `softDelete(entityId)` | **2. SOFT_DELETING** | Begin transaction; acquire `ROW EXCLUSIVE` locks on parent and children in canonical lexicographical order. | Transaction aborts; no rows modified. |
| **2. SOFT_DELETING** | `COMMIT` cascade CTE | **3. SOFT_DELETED_TOMBSTONE** | Set `deleted_at = NOW()`, `deleted_batch_id = UUID`. Insert immutable audit record with HMAC-SHA256 hash. | Rollback reverts all parent and child modifications. |
| **3. SOFT_DELETED_TOMBSTONE** | `restore(entityId)` | **4. RESTORE_STAGING** | Verify partial unique index constraints (ensure no active record registered with conflicting unique columns). | Return `409 Conflict: Unique key occupied by new active entity`. |
| **4. RESTORE_STAGING** | Preflight check passes | **5. RESTORED** | Set `deleted_at = NULL` strictly WHERE `deleted_batch_id = :targetBatchId`. Append `RESTORE` audit record. | Rollback leaves entity in `SOFT_DELETED_TOMBSTONE`. |
| **5. RESTORED** | Return to normal operations | **1. ACTIVE** | Entity and matching batch children are fully visible to standard RLS filters and application queries. | N/A |
| **3. SOFT_DELETED_TOMBSTONE** | Retention period expired | **6. PURGED_EXPUNGED** | Physical `DELETE FROM ...` under GDPR/compliance. Tombstone removed; audit ledger retains anonymized record. | Rollback aborts physical purge. |

---

## 5. Technology-Specific Production Patterns

### 1. PostgreSQL Native: Partial Unique Indexes, Transparent RLS & Recursive CTE Cascades

```sql
-- schema.sql: Production PostgreSQL Soft Delete & Tamper-Proof Audit Hardening

-- Step 1: Base Entities with Tombstone Columns
CREATE TABLE workspaces (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug TEXT NOT NULL,
    name TEXT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    deleted_at TIMESTAMPTZ NULL,
    deleted_by TEXT NULL,
    deleted_batch_id UUID NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id),
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    deleted_at TIMESTAMPTZ NULL,
    deleted_by TEXT NULL,
    deleted_batch_id UUID NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Step 2: Partial Unique Indexes (Prevents re-registration collision while permitting soft deletes)
CREATE UNIQUE INDEX idx_workspaces_slug_active 
ON workspaces (slug) 
WHERE deleted_at IS NULL;

-- Step 3: Enforce PostgreSQL Row-Level Security (RLS) for Zero-Omission Query Safety
ALTER TABLE workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspaces FORCE ROW LEVEL SECURITY;
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE ROW LEVEL SECURITY;

CREATE POLICY workspace_active_isolation ON workspaces
FOR ALL TO authenticated, service_role
USING (deleted_at IS NULL OR current_setting('app.include_soft_deleted', true) = 'true');

CREATE POLICY document_active_isolation ON documents
FOR ALL TO authenticated, service_role
USING (deleted_at IS NULL OR current_setting('app.include_soft_deleted', true) = 'true');

-- Step 4: Immutable Audit Ledger with Tamper-Proof Trigger
CREATE TABLE entity_audit_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_name TEXT NOT NULL,
    entity_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delta JSONB NOT NULL,
    previous_hash TEXT NOT NULL,
    hash TEXT NOT NULL
);

-- Trigger: Prohibit ANY UPDATE or DELETE on Audit Ledger
CREATE OR REPLACE FUNCTION prevent_audit_tampering()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'SECURITY VIOLATION: entity_audit_ledger records are append-only and cryptographically immutable';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_protect_audit_ledger
BEFORE UPDATE OR DELETE ON entity_audit_ledger
FOR EACH ROW EXECUTE FUNCTION prevent_audit_tampering();

-- Step 5: Native Bi-Temporal Range Table with GiST Non-Overlapping Invariance
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE employee_contracts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL,
    salary_cents INT NOT NULL,
    valid_period TSTZRANGE NOT NULL,   -- Business / Valid Time
    system_period TSTZRANGE NOT NULL,  -- System / Transaction Time
    -- Invariant: An employee can NEVER have overlapping contract terms for the same valid time!
    EXCLUDE USING gist (employee_id WITH =, valid_period WITH &&)
);
```

---

### 2. Go (`jackc/pgx/v5` & `sqlc`): Atomic Cascade Soft Delete & Cryptographic Audit Logging

```go
package repository

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type SoftDeleteRepository struct {
	pool       *pgxpool.Pool
	hmacSecret []byte
}

func NewSoftDeleteRepository(pool *pgxpool.Pool, secret string) *SoftDeleteRepository {
	return &SoftDeleteRepository{
		pool:       pool,
		hmacSecret: []byte(secret),
	}
}

// CascadeSoftDeleteWorkspace atomically marks a workspace and all child documents as deleted
// using a single CTE query and logs an immutable audit entry with HMAC-SHA256 verification.
func (r *SoftDeleteRepository) CascadeSoftDeleteWorkspace(
	ctx context.Context,
	workspaceID uuid.UUID,
	actorID string,
) (uuid.UUID, error) {
	batchID := uuid.New()
	now := time.Now().UTC()

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return uuid.Nil, fmt.Errorf("failed to begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// Invariant: Single-statement recursive CTE guarantees atomic multi-table soft deletion
	query := `
		WITH del_workspace AS (
			UPDATE workspaces SET
				deleted_at = $1,
				deleted_by = $2,
				deleted_batch_id = $3,
				version = version + 1
			WHERE id = $4 AND deleted_at IS NULL
			RETURNING id, slug, name
		),
		del_docs AS (
			UPDATE documents SET
				deleted_at = $1,
				deleted_by = $2,
				deleted_batch_id = $3,
				version = version + 1
			WHERE workspace_id IN (SELECT id FROM del_workspace) AND deleted_at IS NULL
			RETURNING id
		)
		SELECT id, slug, name FROM del_workspace;
	`

	var wsID uuid.UUID
	var slug, name string
	err = tx.QueryRow(ctx, query, now, actorID, batchID, workspaceID).Scan(&wsID, &slug, &name)
	if err == pgx.ErrNoRows {
		return uuid.Nil, fmt.Errorf("workspace not found or already soft-deleted")
	} else if err != nil {
		return uuid.Nil, fmt.Errorf("cascade soft-delete failed: %w", err)
	}

	// Fetch previous hash for audit chain
	var prevHash string
	err = tx.QueryRow(ctx, `
		SELECT hash FROM entity_audit_ledger 
		WHERE entity_id = $1 ORDER BY timestamp DESC LIMIT 1
	`, workspaceID).Scan(&prevHash)
	if err == pgx.ErrNoRows {
		genesis := sha256.Sum256([]byte(fmt.Sprintf("GENESIS:workspaces:%s", workspaceID.String())))
		prevHash = hex.EncodeToString(genesis[:])
	} else if err != nil {
		return uuid.Nil, fmt.Errorf("failed to fetch previous audit hash: %w", err)
	}

	// Compute HMAC-SHA256 signature for audit record
	deltaJSON, _ := json.Marshal(map[string]interface{}{
		"deleted_at":       now,
		"deleted_batch_id": batchID,
		"slug":             slug,
	})

	canonicalStr := fmt.Sprintf("%s:%s:%s:%s:%s", prevHash, workspaceID, "SOFT_DELETE", actorID, string(deltaJSON))
	mac := hmac.New(sha256.New, r.hmacSecret)
	mac.Write([]byte(canonicalStr))
	currentHash := hex.EncodeToString(mac.Sum(nil))

	// Insert immutable audit record
	_, err = tx.Exec(ctx, `
		INSERT INTO entity_audit_ledger (
			entity_name, entity_id, action, actor_id, timestamp, delta, previous_hash, hash
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
	`, "workspaces", workspaceID, "SOFT_DELETE", actorID, now, deltaJSON, prevHash, currentHash)
	if err != nil {
		return uuid.Nil, fmt.Errorf("failed to append audit record: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return uuid.Nil, fmt.Errorf("failed to commit cascade deletion: %w", err)
	}

	return batchID, nil
}
```

---

### 3. TypeScript & Drizzle ORM: Transparent Soft-Delete Extensions & Safe Undo

```typescript
// db/soft-delete-extension.ts
import { sql, eq, and, isNull } from 'drizzle-orm';
import { pgTable, uuid, text, timestamp, integer } from 'drizzle-orm/pg-core';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

// Define workspaces schema with partial unique index
export const workspaces = pgTable('workspaces', {
  id: uuid('id').primaryKey().defaultRandom(),
  slug: text('slug').notNull(),
  name: text('name').notNull(),
  version: integer('version').notNull().default(1),
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
  deletedBy: text('deleted_by'),
  deletedBatchId: uuid('deleted_batch_id'),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
});

export const documents = pgTable('documents', {
  id: uuid('id').primaryKey().defaultRandom(),
  workspaceId: uuid('workspace_id').notNull().references(() => workspaces.id),
  title: text('title').notNull(),
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
  deletedBatchId: uuid('deleted_batch_id'),
});

/**
 * Executes a preflight check before restoring a soft-deleted workspace:
 * Verifies that no active record has claimed the slug during the tombstone window.
 */
export async function safeRestoreWorkspace(
  db: NodePgDatabase,
  workspaceId: string,
  batchId: string
): Promise<{ success: boolean; conflict?: string }> {
  return await db.transaction(async (tx) => {
    // 1. Fetch soft-deleted workspace metadata
    const target = await tx.select().from(workspaces)
      .where(and(eq(workspaces.id, workspaceId), eq(workspaces.deletedBatchId, batchId)))
      .limit(1);

    if (target.length === 0) {
      return { success: false, conflict: 'Tombstone record not found or batch mismatch' };
    }

    const { slug } = target[0];

    // 2. Preflight verification: Is the slug occupied by an active workspace?
    const conflict = await tx.select({ id: workspaces.id }).from(workspaces)
      .where(and(eq(workspaces.slug, slug), isNull(workspaces.deletedAt)))
      .limit(1);

    if (conflict.length > 0) {
      return {
        success: false,
        conflict: `Cannot restore: Slug '${slug}' is currently in use by active workspace ${conflict[0].id}`,
      };
    }

    // 3. Atomically restore workspace and ONLY the children belonging to the same deletion batch
    await tx.execute(sql`
      WITH res_workspace AS (
        UPDATE workspaces SET
          deleted_at = NULL,
          deleted_by = NULL,
          deleted_batch_id = NULL,
          version = version + 1
        WHERE id = ${workspaceId} AND deleted_batch_id = ${batchId}::uuid
        RETURNING id
      )
      UPDATE documents SET
        deleted_at = NULL,
        deleted_by = NULL,
        deleted_batch_id = NULL
      WHERE workspace_id IN (SELECT id FROM res_workspace) AND deleted_batch_id = ${batchId}::uuid;
    `);

    return { success: true };
  });
}
```

---

### 4. Python (`SQLAlchemy 2.0`): Transparent Global Criteria & Bi-Temporal Point-in-Time Traversal

```python
# database/temporal_models.py
from datetime import datetime, timezone
import uuid
from typing import Optional
from sqlalchemy import (
    Column, String, Integer, DateTime, Boolean, event, select, and_
)
from sqlalchemy.dialects.postgresql import UUID, TSTZRANGE
from sqlalchemy.orm import DeclarativeBase, Session, with_loader_criteria

class Base(DeclarativeBase):
    pass

class SoftDeletableMixin:
    """Mixin enforcing uniform soft-delete attributes across all models"""
    deleted_at = Column(DateTime(timezone=True), nullable=True)
    deleted_by = Column(String, nullable=True)
    deleted_batch_id = Column(UUID(as_uuid=True), nullable=True)
    version = Column(Integer, nullable=False, default=1)

class Workspace(Base, SoftDeletableMixin):
    __tablename__ = "workspaces"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    slug = Column(String, nullable=False)
    name = Column(String, nullable=False)

# Invariant: Global loader criteria guarantees that ALL SELECT queries
# automatically filter soft-deleted entities unless explicitly opted out via execution option.
@event.listens_for(Session, "do_orm_execute")
def _add_soft_delete_filtering(execute_state):
    if (
        execute_state.is_select
        and not execute_state.execution_options.get("include_deleted", False)
    ):
        execute_state.statement = execute_state.statement.options(
            with_loader_criteria(
                SoftDeletableMixin,
                lambda cls: cls.deleted_at.is_(None),
                include_aliases=True,
            )
        )

def get_active_workspaces(session: Session):
    # Transparently injects WHERE deleted_at IS NULL:
    return session.scalars(select(Workspace)).all()

def get_all_workspaces_including_deleted(session: Session):
    # Explicit admin bypass option:
    return session.scalars(
        select(Workspace).execution_options(include_deleted=True)
    ).all()
```

---

## 6. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

Before any soft delete, entity lifecycle, or audit trail implementation is committed or merged to production, the codebase MUST satisfy all six machine-verifiable gates:

```
[Gate 1: Partial Unique Index & DDL Audit]
  └─ Verified: All unique constraints on soft-deletable tables declare `WHERE deleted_at IS NULL`
[Gate 2: Database Catalog Transparent RLS or View Enforcement]
  └─ Verified: `FORCE ROW LEVEL SECURITY` active with `USING (deleted_at IS NULL)` or filtered Views
[Gate 3: Atomic Recursive Cascade CTE Verification]
  └─ Verified: Multi-table soft deletes execute in 1 roundtrip CTE with shared `deleted_batch_id`
[Gate 4: Preflight Restore Conflict Guardrails]
  └─ Verified: Restore API performs active-key conflict verification before clearing `deleted_at`
[Gate 5: Cryptographic Append-Only Audit Immutability]
  └─ Verified: `BEFORE UPDATE OR DELETE RAISE EXCEPTION` trigger active on audit table with HMAC-SHA256
[Gate 6: Bi-Temporal Point-in-Time Traversal Testing]
  └─ Verified: Point-in-time test queries prove identical historical snapshots across retroactive edits
```

| Verification Gate | Machine-Checkable Command / SQL Query | Required Acceptance Threshold |
| :--- | :--- | :--- |
| **Gate 1: Partial Unique Constraints** | `SELECT indexrelid::regclass, indisunique, indpred FROM pg_index WHERE indisunique AND indpred IS NULL AND ...` | Zero unique indexes on soft-deletable tables without `WHERE deleted_at IS NULL` |
| **Gate 2: RLS Protection** | `SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname IN ('workspaces', 'documents');` | `relrowsecurity = true` AND `relforcerowsecurity = true` on 100% of soft-deletable tables |
| **Gate 3: Cascade Atomicity** | `EXPLAIN (ANALYZE, BUFFERS) WITH del_p AS (...) UPDATE ...` | Single-statement execution plan; 0 secondary roundtrips; 0 orphaned active children |
| **Gate 4: Restore Re-registration Conflict** | Integration test inserting active entity with colliding slug prior to `restore()` | Restore operation returns HTTP 409 Conflict with precise conflict diagnostic |
| **Gate 5: Audit Ledger Immutability** | `UPDATE entity_audit_ledger SET action = 'HACKED';` | Fails immediately with PostgreSQL `SECURITY VIOLATION` exception |
| **Gate 6: Cryptographic Chain Verification** | `npm test -- audit-chain.spec.ts` / `go test -v ./... -run TestAuditChain` | 100% valid SHA-256 HMAC linkage across all historical entity mutations |

---

## 7. Anti-Patterns vs Industrial Invariants

| Anti-Pattern | Failure Mode | Industrial Production Invariant |
| :--- | :--- | :--- |
| **Boolean `is_deleted` column** | Loses temporal metadata; cannot establish when, by whom, or in what batch deletion occurred | Use `deleted_at TIMESTAMPTZ NULL`, `deleted_by TEXT`, and `deleted_batch_id UUID` |
| **Standard `UNIQUE (slug)` index** | Re-creating a previously deleted slug throws fatal `23505 unique_violation` | `CREATE UNIQUE INDEX ... (slug) WHERE deleted_at IS NULL;` |
| **Relying on application-layer `WHERE deleted_at IS NULL`** | Forgotten in nested joins, search sync, or aggregations, leaking ghost records | Enforce `FORCE ROW LEVEL SECURITY` with `USING (deleted_at IS NULL)` at database level |
| **App-memory loop child soft-deletions** | 10,000 roundtrips; memory exhaustion; deadlock crashes on long lock holds | Single-statement recursive CTE updating parent and children with shared `batch_id` |
| **Unconditional cascade restoration** | Resurrects child records that were independently deleted *before* the parent | Restore strictly `WHERE deleted_batch_id = :targetBatchId` |
| **Mutable `audit_logs` table** | History can be modified or deleted by rogue scripts, invalidating SOC 2 / HIPAA | Trigger `BEFORE UPDATE OR DELETE RAISE EXCEPTION` + HMAC-SHA256 Merkle chain |
| **Overwriting financial/billing records** | Destroys historical snapshot; makes historical reconciliation impossible | Bi-temporal modeling with Valid Time & System Time `tstzrange` + GiST exclusion |
