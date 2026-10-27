---
description: PostgreSQL Row-Level Security (RLS), multi-tenant data isolation, FORCE ROW LEVEL SECURITY, session context bleed defense, SET LOCAL vs SET SESSION, security_invoker views, security_barrier optimization fences, composite tenant indexing, composite foreign key isolation, and SECURITY DEFINER hardening across Go (pgx/v5), TypeScript (Drizzle/Kysely/Prisma), Python (psycopg/SQLAlchemy), Rust (tokio-postgres), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{rls,tenant,multitenant,multi_tenant,isolation,policy,security_invoker,security_barrier}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/middleware/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/tenant/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Row-Level Security (RLS), Multi-Tenant Isolation & Policy Bypass Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design multi-tenant SaaS architectures, configure PostgreSQL Row-Level Security (RLS) policies, establish tenant session context via PgBouncer or connection pools, construct views over multi-tenant tables, or implement tenant-aware data access layers across PostgreSQL, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `Prisma`), Python (`psycopg3`, `SQLAlchemy`), or Rust (`tokio-postgres`). Eliminate the "Table Owner & Superuser RLS Bypass Trap" (where developers and autonomous agents execute `ALTER TABLE t ENABLE ROW LEVEL SECURITY` but omit `FORCE ROW LEVEL SECURITY`, causing queries executed by the table owner or administrative role to silently bypass RLS and leak multi-tenant data cluster-wide), the "Connection Pooler Session Setting Bleed & Stale Tenant GUC Trap" (where agents set tenant context using `SET app.current_tenant_id` or `SET SESSION`, causing recycled connections in PgBouncer transaction pooling or client connection pools to leak the previous tenant's ID to subsequent requests), the "View Security Inversion & Leaky CTE Optimization Fence Trap" (where views defined over RLS tables execute with the view creator's permissions due to missing `WITH (security_invoker = true)`, or where PostgreSQL query optimizer pushes non-leakproof functions ahead of RLS filters, leaking confidential data via side-channel errors), the "Unindexed RLS Policy & Sequential Table Scan CPU Meltdown" (where RLS policies evaluate `tenant_id` on tables lacking a composite index with `tenant_id` as the leading column, turning single-row point lookups into catastrophic full-table sequential scans that peg CPU at 100%), the "Cross-Tenant Foreign Key & Unique Constraint Information Oracle" (where single-column foreign keys reference parent tables across tenants, allowing malicious tenants to detect record existence in competitor tenants via foreign key violation error codes), and the "SECURITY DEFINER Privilege Escalation & Mutable Search Path Catastrophe" (where administrative helper functions run with creator privileges and mutable search paths, allowing schema hijacking and unauthorized cross-tenant data exfiltration) by establishing a strict 5-Tier RLS & Multi-Tenant Governance Ladder, mandatory `FORCE ROW LEVEL SECURITY`, transaction-scoped `SET LOCAL` context management, composite leftmost B-tree indexing, and `security_invoker` views.

---

## 1. Architectural Taxonomy: The 6 RLS Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL Row-Level Security (RLS) provides kernel-level data filtering, dynamically rewriting client queries to ensure that every `SELECT`, `INSERT`, `UPDATE`, and `DELETE` operates strictly within authorized tenant boundaries. A complete multi-tenant RLS architecture comprises six core subsystems:
1. **Engine Policy Subsystem (`pg_policy`)**: The declarative rule layer evaluating row-level visibility predicates (`USING`) and mutation validity contracts (`WITH CHECK`).
2. **Table Enforcement Sentinel (`relrowsecurity` & `relforcerowsecurity`)**: Engine flags determining whether RLS is active (`ENABLE RLS`) and whether table owners are subjected to policy evaluation (`FORCE RLS`).
3. **Tenant Context Provider (GUC Plane)**: The runtime configuration mechanism (`current_setting('app.current_tenant_id', true)`) injecting the authenticated caller's identity into transaction memory.
4. **Optimization Barrier & Invoker Plane**: Query planner contracts (`WITH (security_invoker = true)` and `WITH (security_barrier = true)`) preventing optimizer function pushdown and preserving invoker permissions across views and CTEs.
5. **Leftmost Composite Indexing Subsystem**: B-tree index structures (`(tenant_id, id)`) guaranteeing that RLS-rewritten queries maintain logarithmic $O(\log N)$ traversal rather than degrading to linear sequential scans.
6. **Relational Isolation Boundary (Composite Keys & FKs)**: Relational integrity constraints ensuring that primary keys, unique constraints, and foreign keys strictly incorporate `tenant_id` to eliminate cross-tenant oracle probes.

When autonomous coding agents write database migrations, backend middleware, or ORM schemas, LLMs routinely commit fatal architectural anti-patterns:

```typescript
// ❌ CATASTROPHIC LLM ROW-LEVEL SECURITY & MULTI-TENANT ANTI-PATTERNS

// 1. Enabling RLS without FORCE ROW LEVEL SECURITY!
// By default in PostgreSQL, the TABLE OWNER and SUPERUSER silently bypass RLS policies!
// If your backend service connects as the database migration owner (standard default in many setups),
// RLS is completely ignored: SELECT * FROM documents returns EVERY tenant's private documents!
await db.query(`ALTER TABLE documents ENABLE ROW LEVEL SECURITY;`); // FATAL: Table owner bypasses silently

// 2. Setting tenant context with session scope (SET instead of SET LOCAL)!
// In PgBouncer (transaction pooling) or Node.js/Go connection pools, the physical TCP connection is reused.
// When request A completes, the connection retains tenant_A's GUC.
// If request B fails to set a tenant or runs an unauthenticated query, it operates as tenant_A!
await db.query(`SET app.current_tenant_id = '${tenantId}';`); // FATAL: Cross-tenant connection pool bleed

// 3. Creating views over RLS tables without security_invoker = true!
// In PostgreSQL 15+, views execute by default with the permissions of the view creator (security_definer).
// Any user querying the view bypasses RLS and inspects all rows across all tenants!
await db.query(`CREATE VIEW active_documents AS SELECT * FROM documents WHERE status = 'active';`); // FATAL: View creator bypass

// 4. Indexing primary key (id) without tenant_id as the leading column!
// When RLS rewrites SELECT * FROM documents WHERE id = $1 into
// SELECT * FROM documents WHERE (tenant_id = current_setting('...')) AND (id = $1),
// an index on (id) forces PostgreSQL to evaluate the policy on matches or perform full index/seq scans!
await db.query(`CREATE INDEX idx_documents_id ON documents (id);`); // FATAL: Unindexed tenant predicate
```

In production architectures, naive RLS implementations trigger six critical engineering disasters:

- **The "Table Owner & Superuser RLS Bypass Trap"**:
  - Developers or autonomous agents create tables and execute `ALTER TABLE <name> ENABLE ROW LEVEL SECURITY`.
  - In PostgreSQL, table owners, superusers, and roles with the `BYPASSRLS` attribute are **exempt from RLS by default**.
  - In modern serverless and containerized deployments, application connection pools frequently connect using the same administrative database role that executed migrations (`postgres` or `app_owner`).
  - As a result, RLS policies are **silently bypassed**. An application query with an accidental missing `WHERE` filter returns millions of confidential records belonging to competitor organizations.
  - Invariant: Mandatory execution of `ALTER TABLE <name> FORCE ROW LEVEL SECURITY;` on every multi-tenant table, coupled with dedicated unprivileged application roles (`CREATE ROLE app_user WITH NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS`) that own zero database tables.

- **The "Connection Pooler Session Setting Bleed & Stale Tenant GUC Trap"**:
  - Web frameworks set tenant context via `SET app.current_tenant_id = '<uuid>'`.
  - When connection pooling is active (PgBouncer in transaction mode or backend connection pools like `pgxpool`, HikariCP, or Prisma pool), physical TCP connections are shared and recycled across disparate user requests.
  - If a transaction commits or errors out, `SET` remains persistent on the underlying session.
  - The next transaction assigned to that socket—such as a background health check, an unauthenticated signup endpoint, or a request whose tenant lookup failed—inherits the prior tenant's GUC value.
  - Invariant: Mandatory transaction scoping using `SET LOCAL app.current_tenant_id = '<uuid>'` (which automatically reverts on `COMMIT` or `ROLLBACK`) or parameterized helper calls `SELECT set_config('app.current_tenant_id', $1, true)`. In addition, client pools must configure reset sentinels (`DISCARD ALL` or `RESET ALL`) upon connection return.

- **The "View Security Inversion & Leaky CTE Optimization Fence Trap"**:
  - Autonomous agents construct reporting or analytical views over RLS-enabled tables (`CREATE VIEW customer_invoices AS ...`).
  - Without `WITH (security_invoker = true)`, PostgreSQL executes the view under the security context of the view creator (`SECURITY DEFINER` semantics), discarding the caller's RLS policies and exposing all tenant records.
  - Furthermore, PostgreSQL's cost-based query optimizer can reorder execution nodes to evaluate user-supplied `WHERE` conditions (such as string parsing or arithmetic functions) *before* evaluating the RLS `USING` filter if doing so reduces estimated disk page scans.
  - If the user function throws an error or measures execution latency on candidate rows, an attacker can extract confidential records from other tenants through side-channel timing or boolean error oracles.
  - Invariant: Mandatory `WITH (security_invoker = true)` on all views over RLS relations, explicit `WITH (security_barrier = true)` on sensitive security views to prevent optimizer pushdown across the RLS boundary, and marking trusted filter operators as `LEAKPROOF`.

- **The "Unindexed RLS Policy & Sequential Table Scan CPU Meltdown"**:
  - LLMs define an RLS policy: `CREATE POLICY tenant_isolation ON orders USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)`.
  - However, the table index is defined simply as `CREATE INDEX idx_orders_user_id ON orders (user_id)` or `PRIMARY KEY (id)`.
  - When an application executes `SELECT * FROM orders WHERE id = $1`, the PostgreSQL engine rewrites the query tree into:
    $$\sigma_{\text{tenant\_id} = \text{GUC} \land \text{id} = \$1}(\text{orders})$$
  - If the B-Tree index does not have `tenant_id` as the leftmost leading key, the index cannot be traversed efficiently, or worse, the planner switches to a catastrophic sequential scan across 50,000,000 rows.
  - Under peak traffic of 2,000 queries/sec, the database saturates 100% CPU on all cores, query latencies spike from 2ms to 30,000ms, and all pool connections exhaust.
  - Invariant: Mandatory composite leftmost B-tree indexing: `PRIMARY KEY (tenant_id, id)` and composite indexes with `tenant_id` as the leading column (`tenant_id, user_id`, `tenant_id, created_at DESC`).

- **The "Cross-Tenant Foreign Key & Unique Constraint Information Oracle"**:
  - When tables define single-column foreign keys (`FOREIGN KEY (parent_id) REFERENCES parent(id)`), PostgreSQL validates referential integrity at the engine level without executing RLS policies.
  - A malicious tenant can attempt to insert a record into a child table referencing an arbitrary `parent_id` belonging to a competitor tenant.
  - If PostgreSQL raises error `23503 foreign_key_violation`, the attacker learns that the `parent_id` does NOT exist; if PostgreSQL accepts the row (or raises an RLS error), the attacker confirms that the secret UUID exists in another tenant's private dataset.
  - Similarly, global single-column `UNIQUE (slug)` constraints allow malicious tenants to probe competitor project names or account handles.
  - Invariant: Mandatory composite foreign keys and composite unique constraints incorporating `tenant_id`: `FOREIGN KEY (tenant_id, parent_id) REFERENCES parent(tenant_id, id)` and `UNIQUE (tenant_id, slug)`.

- **The "SECURITY DEFINER Privilege Escalation & Mutable Search Path Catastrophe"**:
  - Engineers and agents create database stored functions with `SECURITY DEFINER` to perform administrative operations (e.g., tenant provisioning, cross-tenant telemetry aggregation).
  - When a function declared with `SECURITY DEFINER` omits an explicit `SET search_path = pg_temp, public`, PostgreSQL searches schemas in the caller's search path.
  - A malicious tenant can create an unprivileged table or operator in their own schema that shadows standard functions, hijacking the execution context of the superuser role that created the function.
  - Invariant: Mandatory configuration of `SET search_path = pg_temp, public` on every `SECURITY DEFINER` function, strict parameter authorization checks at the procedure entry point, and preferring `SECURITY INVOKER` for all data-manipulation helpers.

---

### The 5-Tier RLS & Multi-Tenant Governance Ladder

To eliminate multi-tenant data leaks and query planner degradation, autonomous agents must adhere to the 5-Tier Governance Ladder:

```
+---------------------------------------------------------------------------------------------------+
|                           5-TIER RLS & MULTI-TENANT GOVERNANCE LADDER                             |
+---+-----------------------------------+-----------------------------------------------------------+
| 0 | Kernel Enforcement & FORCE RLS   | ALTER TABLE FORCE ROW LEVEL SECURITY on 100% tenant tables|
|   | & Unprivileged Application Role   | App connects strictly as unprivileged app_user (NO OWNER) |
+---+-----------------------------------+-----------------------------------------------------------+
| 1 | Transaction-Scoped GUC Context    | SET LOCAL app.current_tenant_id (Strict TX Scoping)       |
|   | & Fail-Closed Null Coalescing     | USING (tenant_id = NULLIF(current_setting(...), '')::UUID)|
+---+-----------------------------------+-----------------------------------------------------------+
| 2 | Leftmost Composite Indexing       | Composite PK (tenant_id, id) & Leftmost (tenant_id, col)  |
|   | & Plan Index-Only Invariance      | Guarantee O(log N_tenant) B-Tree Traversal, Zero Seq Scans|
+---+-----------------------------------+-----------------------------------------------------------+
| 3 | Security Invoker & Barrier Views  | WITH (security_invoker = true) on 100% RLS Views          |
|   | & Leakproof Optimizer Fencing     | WITH (security_barrier = true) to prevent filter pushdown |
+---+-----------------------------------+-----------------------------------------------------------+
| 4 | Relational Boundary Fencing &     | Composite FK (tenant_id, parent_id) REFERENCES parent(...) |
|   | SECURITY DEFINER Hardening        | SET search_path = pg_temp, public & Param Authorization   |
+---+-----------------------------------+-----------------------------------------------------------+
```

---

## 2. Mathematical Formalization: Security Barriers, Traversal Complexity & Session Proofs

### Theorem 1: Security Barrier Optimization Fence & Information Leak Prevention
Let $\mathcal{R}$ be a multi-tenant relation containing tuples $t \in \mathcal{R}$. Each tuple has a tenant identifier $\tau(t) \in \mathcal{T}$. Let $\tau_{\text{auth}}$ be the active tenant context. Let $\mathcal{P}_{\text{RLS}}(t) \equiv (\tau(t) = \tau_{\text{auth}})$ be the RLS security filter, and let $\mathcal{P}_{\text{user}}(t)$ be a user-supplied query predicate containing a potentially leaky function $f_{\text{leak}}(t)$ that can throw an exception or induce observable timing variances $\Delta T$.

In standard view execution or non-barrier subqueries, PostgreSQL's Cost-Based Optimizer (CBO) evaluates operator cost $\mathcal{C}(\mathcal{P})$. If $\mathcal{C}(\mathcal{P}_{\text{user}}) < \mathcal{C}(\mathcal{P}_{\text{RLS}})$, the optimizer reorders evaluation:
$$\mathcal{E}_{\text{standard}} = \sigma_{\mathcal{P}_{\text{RLS}}}(\sigma_{\mathcal{P}_{\text{user}}}(\mathcal{R}))$$
Under $\mathcal{E}_{\text{standard}}$, $\mathcal{P}_{\text{user}}(t)$ executes on tuples where $\tau(t) \neq \tau_{\text{auth}}$, producing a side-channel information leak probability:
$$\mathbb{P}(\text{SideChannelLeak}) = 1 - \prod_{t \in \mathcal{R} \setminus \mathcal{R}_{\tau}} (1 - \mathbb{P}(f_{\text{leak}}(t) \text{ leaks})) > 0$$

When the view is declared with `WITH (security_barrier = true)`:
$$\mathcal{E}_{\text{barrier}} = \sigma_{\mathcal{P}_{\text{user}}}(\sigma_{\mathcal{P}_{\text{RLS}}}^{\text{FENCE}}(\mathcal{R}))$$
The optimization barrier establishes an immutable fence across which predicates cannot be pushed down:
$$\forall t \text{ evaluated by } \mathcal{P}_{\text{user}}, \quad t \in \sigma_{\mathcal{P}_{\text{RLS}}}(\mathcal{R}) \implies \tau(t) \equiv \tau_{\text{auth}}$$
Consequently:
$$\mathbb{P}(\text{SideChannelLeak}) \equiv 0 \quad \blacksquare$$

---

### Theorem 2: Leftmost Composite Index B-Tree Traversal vs Catastrophic Seq Scan
Let a database table $\mathcal{R}$ contain $N$ total rows distributed across $K$ tenants, with an average of $n_k = \frac{N}{K}$ rows per tenant. Let $B$ be the B-Tree fanout (typically $B \approx 100$ to $300$).

When a query filters by tenant context and primary key (`WHERE id = $1` with RLS active):
1. **Case A: Single-column index on `id` without leading `tenant_id`**:
   The query planner traverses the `id` index in $\lceil \log_B(N) \rceil$ steps to locate candidate leaf tuples, but must fetch the heap tuple to evaluate the RLS filter $\tau(t) = \tau_{\text{auth}}$. If the query filters by non-unique columns (`WHERE status = 'pending'`), the absence of `tenant_id` as the leading index key forces the planner to choose between scanning all index entries matching the filter across all $K$ tenants or falling back to a full sequential table scan:
   $$\text{I/O Cost}_{\text{seq}} = \frac{N \times \text{TupleSize}}{\text{PageSize}} = \mathcal{O}(N)$$
2. **Case B: Leftmost composite index on `(tenant_id, status)`**:
   The search space is strictly bounded to the subtree of tenant $\tau_{\text{auth}}$. The number of leaf pages traversed is:
   $$\text{I/O Cost}_{\text{comp}} = \lceil \log_B(N) \rceil + \left\lceil \frac{n_{\text{auth, matching}}}{\text{LeafPageCapacity}} \right\rceil = \mathcal{O}(\log_B(N) + n_k)$$
   The throughput speedup factor $\mathcal{S}$ is given by:
   $$\mathcal{S} = \frac{\text{I/O Cost}_{\text{seq}}}{\text{I/O Cost}_{\text{comp}}} \approx \frac{N}{\log_B(N) + \frac{N}{K}} \xrightarrow{K \gg 1} \frac{K}{\frac{K \log_B(N)}{N} + 1} \approx K$$
   For $K = 5,000$ tenants and $N = 50,000,000$ rows, composite leftmost indexing reduces query disk page access and CPU cycles by up to $5,000\times$.

---

### Theorem 3: Connection Pool Session Bleed & Transaction Scoping Invariant
Let a connection pool $\mathcal{C}$ contain $M$ physical database connections $\{c_1, c_2, \dots, c_M\}$ serving an arrival stream of transactions $T_1, T_2, \dots$ across tenants $\tau(T_i) \in \mathcal{T}$.

Let $\mathcal{S}(c_j, t)$ be the session configuration state of connection $c_j$ at time $t$.
1. **Under Session-Level Configuration (`SET app.current_tenant_id = \tau`)**:
   $$\mathcal{S}(c_j, t_{\text{commit}}) = \tau(T_i)$$
   When connection $c_j$ is subsequently leased to transaction $T_{i+1}$ with tenant $\tau(T_{i+1})$:
   If $T_{i+1}$ executes an initial query before setting its GUC (or fails to set it due to an unhandled application exception):
   $$\tau_{\text{effective}}(T_{i+1}) = \mathcal{S}(c_j, t) = \tau(T_i) \neq \tau(T_{i+1})$$
   $$\mathbb{P}(\text{CrossTenantBleed}) > 0$$
2. **Under Transaction-Scoped Configuration (`SET LOCAL app.current_tenant_id = \tau`)**:
   PostgreSQL transaction semantics guarantee that `SET LOCAL` modifies the GUC state strictly within the transaction descriptor:
   $$\lim_{t \to t_{\text{end}}} \mathcal{S}(c_j, t) = \mathcal{S}_{\text{default}}(c_j) = \emptyset$$
   Combined with fail-closed policy evaluation:
   $$\text{USING} \left( \tau(t) = \text{NULLIF}(\text{current\_setting}('app.current\_tenant\_id', \text{true}), '')::\text{UUID} \right)$$
   When $\mathcal{S}_{\text{default}}(c_j) = \emptyset$, the policy evaluates to $\tau(t) = \text{NULL}$, which yields `FALSE` for all rows.
   Therefore:
   $$\mathbb{P}(\text{CrossTenantBleed}) \equiv 0 \quad \blacksquare$$

---

## 3. Production Hardening: SQL Engine Invariants & Schema Migration Blueprint

The following SQL migration blueprint demonstrates a battle-tested, zero-leak Row-Level Security architecture:

```sql
-- ============================================================================
-- AGENTIC DATABASE ROW-LEVEL SECURITY PRODUCTION HARDENING BLUEPRINT
-- Enforces: FORCE RLS, Unprivileged App Role, Leftmost Composite Indexes,
--           Security Invoker Views & Composite Foreign Key Boundaries.
-- ============================================================================

-- 1. Create Dedicated Unprivileged Runtime Application Role (NO SUPERUSER, NO OWNER)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
END $$;

-- 2. Create Multi-Tenant Organizations Relation
CREATE TABLE IF NOT EXISTS organizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  slug VARCHAR(100) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT uq_organizations_slug UNIQUE (slug)
);

-- 3. Create Multi-Tenant Documents Relation with Leftmost Composite Primary Key
CREATE TABLE IF NOT EXISTS documents (
  tenant_id UUID NOT NULL,
  id UUID NOT NULL DEFAULT gen_random_uuid(),
  title VARCHAR(255) NOT NULL,
  content TEXT NOT NULL,
  status VARCHAR(50) NOT NULL DEFAULT 'draft',
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  -- Composite Primary Key: Guarantees tenant_id is the leftmost index column
  PRIMARY KEY (tenant_id, id),
  -- Composite Foreign Key: Guarantees referential integrity within tenant boundary
  CONSTRAINT fk_documents_tenant FOREIGN KEY (tenant_id)
    REFERENCES organizations (id) ON DELETE CASCADE
);

-- 4. Leftmost Composite Secondary Indexes for Common Query Patterns
CREATE INDEX IF NOT EXISTS idx_documents_tenant_status_created
  ON documents (tenant_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_documents_tenant_created
  ON documents (tenant_id, created_at DESC);

-- 5. MANDATORY ENFORCEMENT: ENABLE and FORCE Row-Level Security
-- Invariant: FORCE RLS ensures that table owners cannot bypass policies.
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE ROW LEVEL SECURITY;

-- 6. Fail-Closed RLS Policies for All DML Operations
-- Uses NULLIF to ensure unset or empty strings evaluate to NULL, yielding 0 rows.
DROP POLICY IF EXISTS documents_tenant_isolation_select ON documents;
CREATE POLICY documents_tenant_isolation_select ON documents
  FOR SELECT
  TO app_user
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID
  );

DROP POLICY IF EXISTS documents_tenant_isolation_insert ON documents;
CREATE POLICY documents_tenant_isolation_insert ON documents
  FOR INSERT
  TO app_user
  WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID
  );

DROP POLICY IF EXISTS documents_tenant_isolation_update ON documents;
CREATE POLICY documents_tenant_isolation_update ON documents
  FOR UPDATE
  TO app_user
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID
  )
  WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID
  );

DROP POLICY IF EXISTS documents_tenant_isolation_delete ON documents;
CREATE POLICY documents_tenant_isolation_delete ON documents
  FOR DELETE
  TO app_user
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID
  );

-- 7. Secure Multi-Tenant View: MANDATORY WITH (security_invoker = true, security_barrier = true)
DROP VIEW IF EXISTS active_documents_view;
CREATE VIEW active_documents_view
WITH (security_invoker = true, security_barrier = true) AS
SELECT
  tenant_id,
  id,
  title,
  status,
  created_at
FROM documents
WHERE status = 'active';

-- 8. Hardened SECURITY DEFINER Helper Function (Safe Tenant Context Setting)
-- Invariant: Must explicitly set search_path to pg_temp, public to prevent hijacking.
CREATE OR REPLACE FUNCTION set_tenant_context(p_tenant_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_temp, public
AS $$
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'RLS_SECURITY_VIOLATION: tenant_id cannot be null'
      USING ERRCODE = '28000';
  END IF;

  -- Verify tenant exists before setting context
  IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = p_tenant_id) THEN
    RAISE EXCEPTION 'RLS_TENANT_NOT_FOUND: tenant % does not exist', p_tenant_id
      USING ERRCODE = '28000';
  END IF;

  -- Set transaction-scoped setting (is_local = true)
  PERFORM set_config('app.current_tenant_id', p_tenant_id::TEXT, true);
END;
$$;

-- Grant minimal permissions to runtime application role
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE organizations TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE documents TO app_user;
GRANT SELECT ON active_documents_view TO app_user;
GRANT EXECUTE ON FUNCTION set_tenant_context(UUID) TO app_user;
```

---

## 4. Production Implementation: TypeScript `AgenticDatabaseRLSEngine`

The following production-ready TypeScript implementation provides automated RLS policy generation, transaction-scoped tenant execution wrappers, and comprehensive audit diagnostics querying PostgreSQL catalog tables (`pg_class`, `pg_policy`, `pg_views`, `pg_index`):

```typescript
import { Pool, PoolClient, QueryResult } from 'pg';

export interface RLSTableAudit {
  schemaname: string;
  tablename: string;
  tableowner: string;
  rowsecurity: boolean;
  forcerowsecurity: boolean;
  hasPolicies: boolean;
  policyCount: number;
  hasLeftmostTenantIndex: boolean;
  isCompliant: boolean;
  violationReason?: string;
}

export interface RLSViewAudit {
  schemaname: string;
  viewname: string;
  viewowner: string;
  securityInvoker: boolean;
  securityBarrier: boolean;
  isCompliant: boolean;
  violationReason?: string;
}

export class AgenticDatabaseRLSEngine {
  constructor(private readonly pool: Pool) {}

  /**
   * Executes a database operation within an isolated transaction scoped strictly
   * to the provided tenantId using SET LOCAL app.current_tenant_id.
   * Guarantees zero session leaks across pooled PgBouncer connections.
   */
  public async withTenantTransaction<T>(
    tenantId: string,
    callback: (client: PoolClient) => Promise<T>
  ): Promise<T> {
    if (!tenantId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(tenantId)) {
      throw new Error(`AgenticRLSEngine: Invalid tenant UUID format: "${tenantId}"`);
    }

    const client = await this.pool.connect();
    try {
      await client.query('BEGIN;');

      // Invariant: Use transaction-scoped setting via set_config(..., true)
      // or SET LOCAL. This automatically reverts upon COMMIT or ROLLBACK.
      await client.query(`SELECT set_config('app.current_tenant_id', $1, true);`, [tenantId]);

      // Execute caller business logic within tenant boundary
      const result = await callback(client);

      await client.query('COMMIT;');
      return result;
    } catch (error) {
      await client.query('ROLLBACK;').catch(() => {});
      throw error;
    } finally {
      // Invariant: Explicitly reset GUC upon return to pool as defense-in-depth
      await client.query(`SELECT set_config('app.current_tenant_id', '', false);`).catch(() => {});
      client.release();
    }
  }

  /**
   * Audits all tables in the specified schema to verify that:
   * 1. RLS is enabled (relrowsecurity = true)
   * 2. RLS is FORCED (relforcerowsecurity = true)
   * 3. Policies exist for the table
   * 4. A composite index exists with tenant_id as the leading column
   */
  public async auditTables(schema: string = 'public'): Promise<RLSTableAudit[]> {
    const query = `
      WITH table_meta AS (
        SELECT
          c.oid AS table_oid,
          n.nspname AS schemaname,
          c.relname AS tablename,
          pg_get_userbyid(c.relowner) AS tableowner,
          c.relrowsecurity AS rowsecurity,
          c.relforcerowsecurity AS forcerowsecurity
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND n.nspname = $1
          AND c.relname NOT IN ('schema_migrations', 'spatial_ref_sys')
      ),
      policies_meta AS (
        SELECT
          polrelid,
          count(*) AS policy_count
        FROM pg_policy
        GROUP BY polrelid
      ),
      tenant_indexes AS (
        SELECT
          i.indrelid,
          bool_or(
            a.attname = 'tenant_id' AND i.indkey[0] = a.attnum
          ) AS has_leftmost_tenant_index
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
        GROUP BY i.indrelid
      )
      SELECT
        tm.schemaname,
        tm.tablename,
        tm.tableowner,
        tm.rowsecurity,
        tm.forcerowsecurity,
        COALESCE(pm.policy_count, 0) > 0 AS has_policies,
        COALESCE(pm.policy_count, 0)::int AS policy_count,
        COALESCE(ti.has_leftmost_tenant_index, false) AS has_leftmost_tenant_index
      FROM table_meta tm
      LEFT JOIN policies_meta pm ON pm.polrelid = tm.table_oid
      LEFT JOIN tenant_indexes ti ON ti.indrelid = tm.table_oid
      ORDER BY tm.tablename;
    `;

    const result: QueryResult = await this.pool.query(query, [schema]);

    return result.rows.map((row) => {
      let violationReason: string | undefined;

      if (!row.rowsecurity) {
        violationReason = 'RLS is NOT enabled (ENABLE ROW LEVEL SECURITY missing)';
      } else if (!row.forcerowsecurity) {
        violationReason = 'RLS is NOT forced (FORCE ROW LEVEL SECURITY missing; table owner will bypass)';
      } else if (!row.has_policies) {
        violationReason = 'No RLS policies defined; table blocks all operations or operates insecurely';
      } else if (!row.has_leftmost_tenant_index) {
        violationReason = 'Missing composite index with tenant_id as leftmost column; risk of sequential table scans';
      }

      return {
        schemaname: row.schemaname,
        tablename: row.tablename,
        tableowner: row.tableowner,
        rowsecurity: row.rowsecurity,
        forcerowsecurity: row.forcerowsecurity,
        hasPolicies: row.has_policies,
        policyCount: row.policy_count,
        hasLeftmostTenantIndex: row.has_leftmost_tenant_index,
        isCompliant: !violationReason,
        violationReason,
      };
    });
  }

  /**
   * Audits all views in the specified schema to verify that:
   * 1. security_invoker is enabled (PostgreSQL 15+)
   * 2. security_barrier is enabled for security-critical views
   */
  public async auditViews(schema: string = 'public'): Promise<RLSViewAudit[]> {
    const query = `
      SELECT
        n.nspname AS schemaname,
        c.relname AS viewname,
        pg_get_userbyid(c.relowner) AS viewowner,
        COALESCE(
          (SELECT 'security_invoker=true' = ANY(c.reloptions)),
          false
        ) AS security_invoker,
        COALESCE(
          (SELECT 'security_barrier=true' = ANY(c.reloptions)),
          false
        ) AS security_barrier
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'v'
        AND n.nspname = $1
      ORDER BY c.relname;
    `;

    const result: QueryResult = await this.pool.query(query, [schema]);

    return result.rows.map((row) => {
      let violationReason: string | undefined;

      if (!row.security_invoker) {
        violationReason = 'View lacks security_invoker = true; executes under view owner context bypassing caller RLS';
      }

      return {
        schemaname: row.schemaname,
        viewname: row.viewname,
        viewowner: row.viewowner,
        securityInvoker: row.security_invoker,
        securityBarrier: row.security_barrier,
        isCompliant: !violationReason,
        violationReason,
      };
    });
  }
}
```

---

## 5. RLS Lifecycle State Machine (FSM)

A deterministic 6-state finite-state machine governs multi-tenant relation provisioning and security hardening:

```
    +-------------------------------------------------------------------------+
    |                    RLS LIFECYCLE STATE MACHINE (FSM)                    |
    +-------------------------------------------------------------------------+
                                         |
                                         v
                            [ 1. SCHEMA_PROVISIONED ]
                                         |
                                         | ALTER TABLE ENABLE ROW LEVEL SECURITY
                                         v
                            [ 2. RLS_ACTIVE_UNFORCED ]
                                         |
                                         | ALTER TABLE FORCE ROW LEVEL SECURITY
                                         v
                             [ 3. RLS_OWNER_FENCED ]
                                         |
                                         | CREATE POLICY ... USING (tenant_id = ...)
                                         v
                             [ 4. POLICIES_INSTALLED ]
                                         |
                                         | CREATE INDEX (tenant_id, ...)
                                         v
                             [ 5. LEFTMOST_INDEXED ]
                                         |
                                         | WITH (security_invoker = true) & App Role
                                         v
                             [ 6. PRODUCTION_HARDENED ]
```

### State Transition Invariants:
1. **`SCHEMA_PROVISIONED` $\to$ `RLS_ACTIVE_UNFORCED`**: Table created with `tenant_id UUID NOT NULL`. RLS enabled via `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`. Table remains vulnerable to table owner bypass.
2. **`RLS_ACTIVE_UNFORCED` $\to$ `RLS_OWNER_FENCED`**: Table owner bypass permanently eliminated via `ALTER TABLE ... FORCE ROW LEVEL SECURITY`. Both table owners and normal roles are subject to RLS.
3. **`RLS_OWNER_FENCED` $\to$ `POLICIES_INSTALLED`**: Permissive or restrictive policies installed for `SELECT`, `INSERT`, `UPDATE`, `DELETE` targeting the unprivileged `app_user` role with `NULLIF(current_setting(...), '')::UUID`.
4. **`POLICIES_INSTALLED` $\to$ `LEFTMOST_INDEXED`**: Composite primary key `PRIMARY KEY (tenant_id, id)` and composite secondary indexes verified. Sequential scan risk eliminated.
5. **`LEFTMOST_INDEXED` $\to$ `PRODUCTION_HARDENED`**: All reporting views configured with `WITH (security_invoker = true, security_barrier = true)`. Application pool connects strictly via `app_user`. Zero superuser access.

---

## 6. Definition of Done (DoD): 6-Gate Machine-Verifiable Verification Matrix

| Gate | Verification Check | Command / Verification Query | Acceptance Criteria |
| :--- | :--- | :--- | :--- |
| **Gate 1: RLS & FORCE Flags** | Verify RLS and FORCE RLS are active on all tenant tables | `SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'documents';` | `relrowsecurity = true` AND `relforcerowsecurity = true` |
| **Gate 2: App Role Isolation** | Assert application connects as unprivileged role without `BYPASSRLS` | `SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user;` | `rolsuper = false` AND `rolbypassrls = false` |
| **Gate 3: Leftmost Composite Indexing** | Verify `tenant_id` is the leading attribute of composite indexes | `SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0] WHERE i.indrelid = 'documents'::regclass;` | First column must be `tenant_id` |
| **Gate 4: Transaction Scoping** | Verify `app.current_tenant_id` does not persist after transaction commit | Run `SELECT current_setting('app.current_tenant_id', true);` on newly checked-out pooled connection | Must return empty string or NULL |
| **Gate 5: View Security Invoker** | Assert all views over RLS tables specify `security_invoker` | `SELECT reloptions FROM pg_class WHERE relname = 'active_documents_view';` | `reloptions` contains `security_invoker=true` |
| **Gate 6: Fail-Closed Boundary** | Query table with empty/null tenant setting | `SET LOCAL app.current_tenant_id = ''; SELECT count(*) FROM documents;` | Returns exactly 0 rows |
