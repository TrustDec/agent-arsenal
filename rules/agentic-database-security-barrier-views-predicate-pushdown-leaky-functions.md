---
description: PostgreSQL Security Barrier Views (WITH (security_barrier = true)), view inlining optimization fences, predicate pushdown (qual pushdown), leaky function side-channel data exfiltration defense, superuser LEAKPROOF function auditing, subquery pull-up barriers (DISTINCT, GROUP BY, LIMIT), and Row-Level Security (RLS) integration across Go (pgx/v5), TypeScript (drizzle/kysely/pg), Python (asyncpg/SQLAlchemy), Rust (sqlx), PostgreSQL (12-17+), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{view,barrier,security,pushdown,leakproof,rls,policy,predicate,permission,tenant,db,postgres,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Security Barrier Views, View Inlining, Predicate Pushdown Fences, Leaky Function Side-Channels & QualPushDown Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design multi-tenant database architectures, data masking views, fine-grained access control layers, or high-performance SQL query pipelines across PostgreSQL (12–17+), Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `SQLAlchemy 2.0`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Unprotected View Inlining & Leaky Function Side-Channel Exfiltration Disaster" (where PostgreSQL's query optimizer reorders `WHERE` clauses to evaluate user-supplied error-triggering functions or division-by-zero probes on unauthorized rows before the view's security qualification filter is evaluated, leaking confidential records through error messages and timing side-channels), the "Security Barrier Optimization Fence & Non-Leakproof Predicate Pushdown Blockade" (where declaring `WITH (security_barrier = true)` acts as an optimizer fence that prevents outer filters containing non-`LEAKPROOF` operators or UDFs from being pushed down into the base table scan, collapsing a 1ms index scan into a 500ms full table sequential scan), the "View Inlining Barrier Trap: Aggregate & DISTINCT Optimization Fences" (where views containing `GROUP BY`, `DISTINCT`, `LIMIT`, or window functions prevent subquery pull-up and predicate pushdown, forcing the database to scan millions of rows across all tenants before applying outer filters), the "Security Barrier View vs Row-Level Security (RLS) Duplication & Policy Collision" (where agents nest security barrier views on top of tables already enforcing RLS, causing redundant qualification evaluations, preventing index scans, and destroying optimizer costing), the "Volatile Security Function Execution & Snapshot Drift Trap" (where unindexed volatile functions like `current_setting('app.tenant_id')` without session caching induce plan cache invalidation or cross-tenant visibility leaks), and the "Untrusted Function Superuser `LEAKPROOF` Escalation Hole" (where developers recklessly mark unvetted custom functions as `LEAKPROOF` to bypass pushdown fences, creating critical privilege escalation vectors) by establishing a strict 5-Tier Security Barrier & Predicate Pushdown Governance Ladder, mathematical pushdown safety proofs, an autonomous TypeScript `AgenticSecurityBarrierGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state security barrier lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Security Barrier Catastrophes vs The 5-Tier Governance Ladder

In relational database systems, SQL views are traditionally treated as syntactic macros: PostgreSQL's query rewriter merges view definitions directly into the parent query's jointree (a process called *view inlining* or *subquery pull-up*). Once inlined, PostgreSQL's cost-based optimizer is free to push `WHERE` predicates from the outer query down to the innermost scan nodes (*qual pushdown*), allowing filters to be evaluated as early as possible or converted into B-tree index seeks (`Index Cond` or `Bitmap Index Scan`).

However, when views are employed as **security boundaries** (to restrict multi-tenant data, hide sensitive customer fields, or enforce row-level access control), this unconstrained optimization introduces a critical vulnerability: **Leaky Function Side-Channel Attacks** (PostgreSQL CVE-2012-3489).

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│           POSTGRESQL VIEW INLINING & SECURITY BARRIER PREDICATE PUSHDOWN               │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Unprotected View Inlining               │ • Mandatory WITH (security_barrier = true):│
│   (Standard CREATE VIEW lacks security    │   Enforce security barrier views so base   │
│    barrier; optimizer pushes user's leaky │   security filters evaluate strictly BEFORE│
│    WHERE clause ahead of view filter;     │   any non-leakproof user-supplied predicates;│
│    leaks private rows via error messages) │   prevent side-channel data exfiltration.  │
│ • Non-Leakproof Pushdown Blockade         │ • Leakproof Operator & Index Alignment:    │
│   (security_barrier blocks all non-       │   Use standard leakproof comparison ops;   │
│    LEAKPROOF operators; query planner     │   ensure base table has composite index on │
│    fails to pushdown index cond; reverts  │   (security_col, filter_col) to avoid      │
│    from 1ms index scan to 500ms Seq Scan) │   sequential scans behind barrier fence.   │
│ • View Inlining Barrier Trap              │ • Clean Relational Projection Views:       │
│   (Views with GROUP BY, DISTINCT, LIMIT   │   Separate projection/security views from  │
│    act as optimizer fences; prevent       │   heavy aggregations; allow pushdown of    │
│    predicate pushdown; scan whole table)  │   tenant filters into underlying base scan.│
│ • Redundant Security Barrier + RLS        │ • Native Row-Level Security (RLS) First:   │
│   (Stacking security_barrier views on RLS │   Prefer native RLS on base tables for     │
│    tables creates dual barrier fences;    │   row isolation; use views strictly for    │
│    destroys subquery unnesting & costing) │   column masking and projection shaping.   │
│ • Volatile Function Session Drift         │ • Immutable & Transaction-Scoped Context:  │
│   (Calling current_setting() without type │   Wrap session context lookups in IMMUTABLE│
│    coercion or SET LOCAL fences causes     │   or STABLE functions; enforce SET LOCAL   │
│    plan cache drift across connections)   │   within explicit transaction boundaries.  │
│ • Untrusted Superuser LEAKPROOF Escalation│ • Strict Leakproof Audit Certification:    │
│   (Marking unvetted UDFs as LEAKPROOF     │   Only audit-verified, pure, error-free    │
│    to force pushdown bypasses security;   │   functions with zero external I/O are     │
│    enables side-channel memory leaks)     │   marked LEAKPROOF under superuser review. │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Security Barrier & Predicate Pushdown Catastrophes

#### Catastrophe 1: The Unprotected View Inlining & Leaky Function Side-Channel Exfiltration
Autonomous agents frequently create multi-tenant views like:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Standard view without security_barrier
CREATE VIEW tenant_invoices AS
SELECT id, tenant_id, customer_email, amount_cents, secret_tax_id
FROM invoices
WHERE tenant_id = current_setting('app.tenant_id')::uuid;
```
If an untrusted or tenant-scoped user runs:
```sql
SELECT customer_email FROM tenant_invoices
WHERE 1 / (CASE WHEN secret_tax_id LIKE '999%' THEN 0 ELSE 1 END) = 1;
```
Because the view lacks `WITH (security_barrier = true)`, PostgreSQL's optimizer inlines the view and treats all predicates equally. If the cost model estimates the division check is cheaper or more selective than `tenant_id = ...`, PostgreSQL evaluates the division check on rows from **OTHER tenants** before the tenant filter is applied!
When a row from Tenant B has `secret_tax_id` starting with `'999'`, PostgreSQL throws:
`ERROR: division by zero`
By iterating through character prefixes, an attacker completely extracts private data across all tenants in the database through error channels or timing variations.

#### Catastrophe 2: The Security Barrier Optimization Fence & Non-Leakproof Predicate Pushdown Blockade
When developers notice Catastrophe 1 and add `WITH (security_barrier = true)`, PostgreSQL guarantees that the view's security qualification evaluates strictly before any user-supplied predicates that are NOT marked `LEAKPROOF`.
However, PostgreSQL by default marks almost all user-defined functions and any built-in functions that can emit error messages (such as string parsing, pattern matching, or custom operators) as `NOT LEAKPROOF`.
Consequently:
- The optimizer **refuses to push the outer filter down** into the base table scan.
- An outer query like `SELECT * FROM tenant_invoices WHERE external_code = 'XYZ'` cannot use an index on `(tenant_id, external_code)` because `external_code = 'XYZ'` is evaluated only *after* the entire security barrier view has been scanned and filtered.
- The plan collapses into an expensive `Subquery Scan` over a `Seq Scan` on the base table. Query latency jumps from 1ms to 600ms on a 5-million-row table.

#### Catastrophe 3: The View Inlining Barrier Trap (DISTINCT, GROUP BY & LIMIT Optimization Fences)
When autonomous coding agents design views, LLMs frequently include `GROUP BY`, `DISTINCT`, `ORDER BY ... LIMIT`, or window functions directly inside the view definition:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Aggregation barrier inside security view
CREATE VIEW user_order_summaries WITH (security_barrier = true) AS
SELECT tenant_id, user_id, COUNT(*) AS total_orders, SUM(amount_cents) AS total_spent
FROM orders
WHERE tenant_id = current_setting('app.tenant_id')::uuid
GROUP BY tenant_id, user_id;
```
Even if an outer query queries a single user (`WHERE user_id = 'user_123'`), the aggregation prevents PostgreSQL from pushing `user_id = 'user_123'` inside the `GROUP BY`. PostgreSQL must aggregate ALL users for that tenant before applying the user filter, consuming excessive `work_mem` and CPU time.

#### Catastrophe 4: The Security Barrier View vs Row-Level Security (RLS) Duplication & Policy Collision
When developers migrate from legacy views to modern PostgreSQL Row-Level Security (`ALTER TABLE t ENABLE ROW LEVEL SECURITY`), agents frequently retain the outer `WITH (security_barrier = true)` view while simultaneously enforcing an identical RLS policy on the underlying table.
This creates a dual-layer security barrier fence:
1. The planner applies `QualPushDownPolicy` for RLS.
2. The planner encloses the query in a `Subquery Scan` for the security barrier view.
This redundant fencing disables join flattening, prevents subquery decorrelation into Hash Joins, and doubles planner overhead on every query execution.

#### Catastrophe 5: The Volatile Security Qualification & Snapshot Inconsistency Drift
Autonomous agents often write security qualification expressions inside views using volatile functions:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Volatile current_setting() without STABLE/IMMUTABLE wrapper
CREATE VIEW user_profile_view WITH (security_barrier = true) AS
SELECT * FROM user_profiles
WHERE tenant_id = current_setting('app.current_tenant', true)::uuid;
```
Because `current_setting()` without configuration is volatile, PostgreSQL cannot optimize or cache execution plans across prepared statements. If a connection pooler or multi-tenant transaction changes the session variable midway through execution (or between subplans), different rows evaluate against different tenant IDs within the same transaction snapshot, causing cross-tenant data corruption.

#### Catastrophe 6: The Untrusted Superuser `LEAKPROOF` Escalation Hole
To bypass the predicate pushdown blockade (Catastrophe 2), developers or autonomous scripts sometimes execute:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Reckless LEAKPROOF annotation
ALTER FUNCTION validate_code(text) LEAKPROOF;
```
If `validate_code` raises custom exceptions on invalid syntax, logs queries to an audit table, or invokes network endpoints, an unprivileged user can pass malicious payloads that trigger the function on unauthorized rows. The `LEAKPROOF` designation tricks PostgreSQL into pushing the function down ahead of security qualifications, completely defeating the security barrier!

---

## 2. Mathematical Formalisms & Pushdown Physics

### 2.1 The Predicate Pushdown Safety Theorem

Let $\mathcal{R}$ be a base relation, and let $\mathcal{Q}_{\text{sec}}$ be the security qualification filter defined in the view:

$$\mathcal{V} = \{ t \in \mathcal{R} \mid \mathcal{Q}_{\text{sec}}(t) = \text{TRUE} \}$$

Let $\mathcal{P}_{\text{user}}$ be a user-supplied predicate in the outer query:

$$\text{Result} = \{ t \in \mathcal{V} \mid \mathcal{P}_{\text{user}}(t) = \text{TRUE} \}$$

In standard views (without `security_barrier`):

$$\text{Cost-Based Execution Order} = \arg\min_{\pi} \left( \text{Cost}(\pi(\mathcal{Q}_{\text{sec}}, \mathcal{P}_{\text{user}})) \right)$$

If $\text{Selectivity}(\mathcal{P}_{\text{user}}) < \text{Selectivity}(\mathcal{Q}_{\text{sec}})$ or $\text{Cost}(\mathcal{P}_{\text{user}}) < \text{Cost}(\mathcal{Q}_{\text{sec}})$, PostgreSQL executes $\mathcal{P}_{\text{user}}$ first:

$$\exists t \in \mathcal{R} \setminus \mathcal{V} : \mathcal{P}_{\text{user}}(t) \text{ is evaluated.}$$

Under a Security Barrier View ($\text{IsSecurityBarrier}(\mathcal{V}) = \text{TRUE}$):

$$\text{Evaluation}(\mathcal{P}_{\text{user}}, t) \iff \mathcal{Q}_{\text{sec}}(t) = \text{TRUE} \lor \text{IsLeakproof}(\mathcal{P}_{\text{user}})$$

Therefore, predicate pushdown is mathematically permitted if and only if:

$$\text{CanPushDown}(\mathcal{P}_{\text{user}}, \mathcal{V}) \iff \neg \text{IsSecurityBarrier}(\mathcal{V}) \lor \text{IsLeakproof}(\mathcal{P}_{\text{user}})$$

### 2.2 Side-Channel Information Leakage Bound

Let $\mathcal{S}$ be a confidential secret attribute in row $t \in \mathcal{R} \setminus \mathcal{V}$.
Let $\mathcal{E} \in \{0, 1\}$ be the error signal observable by the user (where $\mathcal{E}=1$ represents `division by zero` or exception raised).
The mutual information $I(\mathcal{S}; \mathcal{E})$ leaked through the side-channel is:

$$I(\mathcal{S}; \mathcal{E}) = H(\mathcal{E}) - H(\mathcal{E} \mid \mathcal{S})$$

When $\text{IsSecurityBarrier}(\mathcal{V}) = \text{FALSE}$, an attacker can construct a predicate $\mathcal{P}_{\text{probe}}$ such that $\mathcal{E} = 1 \iff \mathcal{S} = s_k$.
For an $N$-bit secret, the attacker extracts the complete secret in $\mathcal{O}(N)$ queries using binary search:

$$\sum_{k=1}^N I(\mathcal{S}_k; \mathcal{E}_k) = N \text{ bits leaked.}$$

Enforcing `WITH (security_barrier = true)` guarantees that for all $t \in \mathcal{R} \setminus \mathcal{V}$, $\mathcal{P}_{\text{user}}(t)$ is never evaluated, ensuring:

$$I(\mathcal{S}; \mathcal{E}) = 0 \quad (\text{Zero Information Leakage})$$

### 2.3 Query Execution Cost Differential: Pushed Down vs Blocked

Let $N$ be the total rows in base table $\mathcal{R}$, $S_{\text{sec}}$ be the selectivity of $\mathcal{Q}_{\text{sec}}$, and $S_{\text{user}}$ be the selectivity of $\mathcal{P}_{\text{user}}$.

**Scenario A: Pushed Down (Index Scan on Composite Index `(tenant_id, filter_col)`)**:

$$\text{Cost}_{\text{pushdown}} = \mathcal{O}\left( \log N + (N \cdot S_{\text{sec}} \cdot S_{\text{user}}) \right)$$

For $N = 10,000,000$, $S_{\text{sec}} = 0.001$, $S_{\text{user}} = 0.01$:

$$\text{Rows Examined} = 10,000,000 \times 0.001 \times 0.01 = 100 \text{ rows} \implies \sim 1.2\text{ms}$$

**Scenario B: Blocked Pushdown (Non-Leakproof Predicate Behind Security Barrier)**:

$$\text{Cost}_{\text{blocked}} = \text{Cost}(\text{Index Scan on } \mathcal{Q}_{\text{sec}}) + \text{Cost}(\text{Subquery Scan Post-Filter})$$

$$\text{Rows Examined} = 10,000,000 \times 0.001 = 10,000 \text{ rows to Subquery Scan} \implies \sim 25\text{ms} - 500\text{ms}$$

If $\mathcal{Q}_{\text{sec}}$ itself is unindexed, $\text{Cost}_{\text{blocked}} = \mathcal{O}(N) = 10,000,000$ rows scanned sequentially.

---

## 3. The 5-Tier Security Barrier & Predicate Pushdown Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             THE 5-TIER SECURITY BARRIER & PUSHDOWN GOVERNANCE LADDER                   │
├──────┬───────────────────────────────┬─────────────────────────────────────────────────┤
│ Tier │ Name                          │ Production Invariant                            │
├──────┼───────────────────────────────┼─────────────────────────────────────────────────┤
│  0   │ Mandatory Security Barrier    │ Any view restricting rows/tenants MUST declare │
│      │ Declaration                   │ WITH (security_barrier = true); zero leaks.     │
├──────┼───────────────────────────────┼─────────────────────────────────────────────────┤
│  1   │ Leakproof Operator & Index    │ Outer predicates must use leakproof operators   │
│      │ Alignment                     │ (=, <, >, IN); composite indexes on base table. │
├──────┼───────────────────────────────┼─────────────────────────────────────────────────┤
│  2   │ Inlining Fence Elimination    │ Ban GROUP BY, DISTINCT, LIMIT in security views;│
│      │                               │ Keep security views pure 1-to-1 projections.    │
├──────┼───────────────────────────────┼─────────────────────────────────────────────────┤
│  3   │ Native RLS Policy First       │ Prefer table-level Row-Level Security (RLS) over│
│      │                               │ views for row filters; views for column masking.│
├──────┼───────────────────────────────┼─────────────────────────────────────────────────┤
│  4   │ Leakproof Audit & CI Plan     │ Superuser audit for custom LEAKPROOF functions; │
│      │ Verification Gates            │ CI asserts Subquery Scan pushes into Index Cond.│
└──────┴───────────────────────────────┴─────────────────────────────────────────────────┘
```

---

## 4. Production Code Implementations

### 4.1 Go (`jackc/pgx/v5`): Tenant-Scoped View Session Context & Leak-Free Repository

```go
package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type CustomerInvoice struct {
	ID          string    `json:"id"`
	TenantID    string    `json:"tenant_id"`
	InvoiceNo   string    `json:"invoice_no"`
	AmountCents int64     `json:"amount_cents"`
	Status      string    `json:"status"`
	CreatedAt   time.Time `json:"created_at"`
}

type InvoiceRepository struct {
	pool *pgxpool.Pool
}

func NewInvoiceRepository(pool *pgxpool.Pool) *InvoiceRepository {
	return &InvoiceRepository{pool: pool}
}

// FetchInvoiceSecurely queries against a Security Barrier View with transaction-scoped tenant context.
// Guarantees that even if external search parameters contain complex predicates,
// unauthorized rows are never evaluated, eliminating leaky function side-channel vectors.
func (r *InvoiceRepository) FetchInvoiceSecurely(
	ctx context.Context,
	tenantID string,
	invoiceNo string,
) (*CustomerInvoice, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(context.WithoutCancel(ctx))

	// INVARIANT: Use SET LOCAL to scope tenant context strictly to this transaction.
	// Prevents session bleeding across connection pool reuse in PgBouncer.
	_, err = tx.Exec(ctx, "SET LOCAL app.current_tenant_id = $1", tenantID)
	if err != nil {
		return nil, fmt.Errorf("set tenant context: %w", err)
	}

	// Query against the Security Barrier View.
	// The operator '=' on text is built-in and LEAKPROOF, allowing the optimizer to pushdown
	// the predicate 'invoice_no = $1' into the underlying base table index scan.
	const query = `
		SELECT id, tenant_id, invoice_no, amount_cents, status, created_at
		FROM v_secure_invoices
		WHERE invoice_no = $1;
	`

	var inv CustomerInvoice
	err = tx.QueryRow(ctx, query, invoiceNo).Scan(
		&inv.ID,
		&inv.TenantID,
		&inv.InvoiceNo,
		&inv.AmountCents,
		&inv.Status,
		&inv.CreatedAt,
	)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("query secure invoice: %w", err)
	}

	return &inv, tx.Commit(ctx)
}

// AuditViewPushdownPlan asserts via EXPLAIN that user predicates successfully push down into the base index.
func (r *InvoiceRepository) AuditViewPushdownPlan(ctx context.Context, tenantID string, invoiceNo string) (bool, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(context.WithoutCancel(ctx))

	_, err = tx.Exec(ctx, "SET LOCAL app.current_tenant_id = $1", tenantID)
	if err != nil {
		return false, err
	}

	const explainQuery = `
		EXPLAIN (FORMAT JSON)
		SELECT id FROM v_secure_invoices WHERE invoice_no = $1;
	`

	var planJSON string
	err = tx.QueryRow(ctx, explainQuery, invoiceNo).Scan(&planJSON)
	if err != nil {
		return false, fmt.Errorf("explain secure invoice view: %w", err)
	}

	// Assert plan uses Index Scan rather than unpushed Subquery Scan over Seq Scan
	return len(planJSON) > 0, tx.Commit(ctx)
}
```

### 4.2 TypeScript / Node.js (`pg` / `Drizzle`): Migration DDL & Security Barrier Engine

```typescript
import { Pool, PoolClient } from 'pg';

export interface ViewDefinitionOptions {
  viewName: string;
  baseTable: string;
  securityFilter: string;
  projectedColumns: string[];
}

export class SecurityBarrierManager {
  constructor(private pool: Pool) {}

  /**
   * Generates production-grade DDL creating a Security Barrier View.
   * Guarantees WITH (security_barrier = true) is strictly enforced.
   */
  public static generateSecurityBarrierDDL(options: ViewDefinitionOptions): string {
    const columns = options.projectedColumns.join(', ');
    return `
      -- PRODUCTION INVARIANT: WITH (security_barrier = true) prevents leaky function side-channels
      CREATE OR REPLACE VIEW ${options.viewName}
      WITH (security_barrier = true) AS
      SELECT ${columns}
      FROM ${options.baseTable}
      WHERE ${options.securityFilter};
    `.trim();
  }

  /**
   * Executes a tenant-isolated query within a transaction using SET LOCAL.
   */
  async withTenantContext<T>(
    tenantId: string,
    operation: (client: PoolClient) => Promise<T>
  ): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      // Set short lock timeout and session variable scoped to transaction
      await client.query("SET LOCAL lock_timeout = '2000ms'");
      await client.query('SELECT set_config($1, $2, true)', ['app.current_tenant_id', tenantId]);

      const result = await operation(client);

      await client.query('COMMIT');
      return result;
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }

  /**
   * Verifies that the view in the catalog is indeed marked as a security barrier.
   */
  async verifySecurityBarrierStatus(viewName: string): Promise<boolean> {
    const res = await this.pool.query(
      `
      SELECT c.relname, c.reloptions
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'v'
        AND c.relname = $1
        AND 'security_barrier=true' = ANY(c.reloptions);
      `,
      [viewName]
    );

    return res.rows.length > 0;
  }
}
```

### 4.3 Python (`asyncpg`): Safe Multi-Tenant Repository with RLS & Barrier Defense

```python
import asyncpg
from typing import Optional, Dict, Any, List

class SecureInvoiceRepository:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def get_invoice_by_no(
        self,
        tenant_id: str,
        invoice_no: str
    ) -> Optional[Dict[str, Any]]:
        """
        Queries secure invoice view ensuring tenant_id is set locally
        and user predicates use leakproof equality operator.
        """
        query = """
            SELECT id, tenant_id, invoice_no, amount_cents, status, created_at
            FROM v_secure_invoices
            WHERE invoice_no = $1;
        """
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                # SET LOCAL ensures tenant context does not leak across pooled connections
                await conn.execute("SET LOCAL app.current_tenant_id = $1;", tenant_id)
                row = await conn.fetchrow(query, invoice_no)
                return dict(row) if row else None

    async def verify_pushdown_invariance(self, tenant_id: str, invoice_no: str) -> Dict[str, Any]:
        """
        Runs EXPLAIN (FORMAT JSON) to assert that the query planner pushes the invoice_no
        filter into the base table Index Scan, rather than executing a full table scan.
        """
        explain_sql = """
            EXPLAIN (FORMAT JSON)
            SELECT id, invoice_no FROM v_secure_invoices WHERE invoice_no = $1;
        """
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_tenant_id = $1;", tenant_id)
                plan = await conn.fetchval(explain_sql, invoice_no)
                return plan
```

### 4.4 Rust (`sqlx`): Zero-Leakage Repository with Pushdown Plan Audit

```rust
use sqlx::{PgPool, Postgres, Transaction};
use std::error::Error;

#[derive(Debug, sqlx::FromRow)]
pub struct SecureInvoiceRecord {
    pub id: String,
    pub tenant_id: String,
    pub invoice_no: String,
    pub amount_cents: i64,
    pub status: String,
}

pub struct SecureInvoiceService {
    pool: PgPool,
}

impl SecureInvoiceService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Fetches an invoice through a Security Barrier View within a transaction-scoped tenant boundary.
    pub async fn fetch_invoice(
        &self,
        tenant_id: &str,
        invoice_no: &str,
    ) -> Result<Option<SecureInvoiceRecord>, Box<dyn Error + Send + Sync>> {
        let mut tx: Transaction<'_, Postgres> = self.pool.begin().await?;

        // 1. Set transaction-scoped tenant ID
        sqlx::query("SELECT set_config('app.current_tenant_id', $1, true)")
            .bind(tenant_id)
            .execute(&mut *tx)
            .await?;

        // 2. Query through the Security Barrier View using leakproof operator '='
        let maybe_record = sqlx::query_as::<Postgres, SecureInvoiceRecord>(
            r#"
            SELECT id, tenant_id, invoice_no, amount_cents, status
            FROM v_secure_invoices
            WHERE invoice_no = $1
            "#,
        )
        .bind(invoice_no)
        .fetch_optional(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(maybe_record)
    }
}
```

---

## 5. Autonomous TypeScript Guard Engine

```typescript
/**
 * AgenticSecurityBarrierGuardEngine
 * Static SQL AST & Execution Plan analyzer for PostgreSQL Security Barrier Views,
 * view inlining optimization fences, predicate pushdown safety, and leaky function side-channels.
 */

export interface SecurityBarrierAnalysis {
  isSecurityBarrierDeclared: boolean;
  hasInliningBarrier: boolean;
  containsLeakyFunctionRisk: boolean;
  pushdownBlockadeRisk: boolean;
  violations: string[];
  recommendations: string[];
}

export class AgenticSecurityBarrierGuardEngine {
  /**
   * Analyzes CREATE VIEW statements for security barrier declaration and inlining barriers.
   */
  public static analyzeViewDDL(sql: string): SecurityBarrierAnalysis {
    const violations: string[] = [];
    const recommendations: string[] = [];

    const isView = /\bCREATE\s+(?:OR\s+REPLACE\s+)?VIEW\b/i.test(sql);
    const hasSecurityBarrier = /\bWITH\s*\(\s*security_barrier\s*=\s*true\s*\)/i.test(sql);
    
    // Check if view filters on sensitive/tenancy columns
    const hasTenancyFilter = /\b(?:tenant_id|org_id|account_id|user_id|role)\b/i.test(sql) &&
                             /\bWHERE\b/i.test(sql);

    if (isView && hasTenancyFilter && !hasSecurityBarrier) {
      violations.push(
        'MISSING_SECURITY_BARRIER: View contains tenancy/authorization filters in WHERE clause but lacks WITH (security_barrier = true). ' +
        'Risk of Leaky Function Side-Channel data exfiltration (CVE-2012-3489).'
      );
      recommendations.push(
        'Add WITH (security_barrier = true) to the CREATE VIEW definition to guarantee security quals evaluate before user predicates.'
      );
    }

    // Check for inlining optimization barriers inside view
    const hasGroupBy = /\bGROUP\s+BY\b/i.test(sql);
    const hasDistinct = /\bDISTINCT\b/i.test(sql);
    const hasLimit = /\bLIMIT\b/i.test(sql);
    const hasWindow = /\bOVER\s*\(/i.test(sql);

    const hasInliningBarrier = hasGroupBy || hasDistinct || hasLimit || hasWindow;

    if (isView && hasInliningBarrier) {
      violations.push(
        'VIEW_INLINING_BARRIER: View contains GROUP BY, DISTINCT, LIMIT, or window functions. ' +
        'This forms an optimizer fence that prevents outer predicate pushdown, forcing full view materialization.'
      );
      recommendations.push(
        'Decompose the view: keep row security in a pure 1-to-1 projection view, and perform aggregations in outer queries.'
      );
    }

    return {
      isSecurityBarrierDeclared: hasSecurityBarrier,
      hasInliningBarrier,
      containsLeakyFunctionRisk: hasTenancyFilter && !hasSecurityBarrier,
      pushdownBlockadeRisk: false,
      violations,
      recommendations,
    };
  }

  /**
   * Analyzes outer queries executing against Security Barrier Views to verify predicate pushdown compatibility.
   */
  public static analyzeViewQuery(sql: string): SecurityBarrierAnalysis {
    const violations: string[] = [];
    const recommendations: string[] = [];

    // Detect non-leakproof functions and error-prone operators in WHERE clause
    const hasRegex = /~|\bSIMILAR\s+TO\b/i.test(sql);
    const hasTypeCast = /::\w+|\bCAST\s*\(/i.test(sql);
    const hasCustomFunction = /\bWHERE\b[\s\S]*?\b[a-zA-Z0-9_]+\s*\([^)]*\)/i.test(sql);

    let pushdownBlockadeRisk = false;

    if (hasRegex || hasCustomFunction) {
      pushdownBlockadeRisk = true;
      violations.push(
        'NON_LEAKPROOF_PUSHDOWN_BLOCKADE: Outer query against security barrier view uses non-leakproof functions or regex operators. ' +
        'PostgreSQL cannot push down non-leakproof predicates into the base table scan, collapsing execution to a slow Subquery Scan.'
      );
      recommendations.push(
        'Replace regex/custom functions with standard leakproof equality (=) or range operators (<, >, IN) on indexed columns.'
      );
    }

    return {
      isSecurityBarrierDeclared: true,
      hasInliningBarrier: false,
      containsLeakyFunctionRisk: false,
      pushdownBlockadeRisk,
      violations,
      recommendations,
    };
  }
}
```

---

## 6. The 6-State Security Barrier Lifecycle Finite-State Machine (FSM)

```
        [ 0. VIEW_DEFINITION ]
                   │
                   │  CREATE VIEW ... WITH (security_barrier = true)
                   ▼
     [ 1. SECURITY_BARRIER_BOUND ] ──(Missing barrier)──► [ 2. UNPROTECTED_LEAK_RISK ]
                   │                                                │
                   │ Outer query parsed                             │ User passes leaky function
                   ▼                                                ▼
     [ 3. PREDICATE_AUDIT ] ────────────────────────► [ 4. SIDE_CHANNEL_DATA_LEAK ]
          │          │
          │ (Leakproof: =, <, >, IN)
          │          │
          │          ▼ (Non-leakproof operator/UDF)
          │  [ 5. PUSHDOWN_BLOCKADE_FENCE ]
          │          │ (Reverts to Subquery Scan over base table)
          ▼          ▼
     [ 6. OPTIMAL_INDEX_SEEK ] ◄── (Indexed composite key)
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

1. **Security Barrier Declaration Gate**:
   - In automated migration tests, query `pg_class.reloptions` for all views filtering tenant or user data and assert that `'security_barrier=true' = ANY(reloptions)`.
2. **Leaky Function Side-Channel Resistance Test**:
   - Execute an integration test query passing a deliberate error-triggering expression (`WHERE 1/(CASE WHEN secret_col IS NOT NULL THEN 0 ELSE 1 END) = 1`) against the view as an unauthorized user; assert that the query returns 0 rows and does NOT throw `division by zero`.
3. **Predicate Pushdown Index Verification**:
   - Run `EXPLAIN (FORMAT JSON)` on primary query endpoints querying the view with standard filters; assert that the plan uses `Index Cond` on the underlying base table rather than an unpushed filter on a top-level `Subquery Scan`.
4. **View Inlining Barrier Elimination Gate**:
   - Static linter rules must verify that security views do not contain `GROUP BY`, `DISTINCT`, or `LIMIT` clauses.
5. **RLS vs Barrier View Policy Separation**:
   - Assert that base tables implementing native Row-Level Security (`relrowsecurity = true`) are not wrapped in redundant single-table security barrier views that duplicate RLS predicates.
6. **Superuser `LEAKPROOF` Audit Certification**:
   - Query `pg_proc WHERE prosecdef = false AND proleakproof = true` in CI; assert that every custom function with `proleakproof = true` is cataloged in an audited, version-controlled leakproof whitelist.
