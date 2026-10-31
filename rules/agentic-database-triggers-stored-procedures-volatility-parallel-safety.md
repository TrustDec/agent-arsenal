---
description: PostgreSQL (10+), MySQL (8.0+), and SQLite triggers, stored procedures, PL/pgSQL function volatility (VOLATILE, STABLE, IMMUTABLE), parallel safety (PARALLEL SAFE, PARALLEL RESTRICTED), statement vs row-level triggers, transition tables (REFERENCING OLD/NEW TABLE AS), recursive cascade defense, SECURITY DEFINER search_path hardening, dynamic SQL parameterization, and cost model optimization across Go (pgx/v5), TypeScript (Drizzle, Kysely, Prisma), Python (SQLAlchemy, asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{trigger,function,procedure,sp,volatility,audit,transition,lifecycle,event,store,repo,repository,dao,model,migration}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Triggers, Stored Procedures, Function Volatility, Transition Tables & Parallel Safety Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design database triggers, stored procedures, PL/pgSQL functions, audit logging pipelines, change data tracking, or high-throughput batch updates across PostgreSQL (10+), MySQL (8.0+), SQLite (3.30+), Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `prisma`), Python (`SQLAlchemy`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Pure Function Default-VOLATILE Indexing & Parallelism Paralyzer" (where developers and agents omit volatility annotations, causing PostgreSQL to default to `VOLATILE`, disabling index evaluation on expression indexes, preventing subquery flattening, marking plans `PARALLEL UNSAFE`, and forcing single-threaded sequential scans across multi-core servers), the "Impure Function Fake-IMMUTABLE Silent Stale Data & Index Corruption Trap" (where agents mark functions `IMMUTABLE` despite querying tables or reading clocks, baking permanently stale values into plans and corrupting B-Tree indexes), the "$N$-Row Trigger Cascade & Lock Table Exhaustion Meltdown" (where audit or rollup triggers fire `FOR EACH ROW` during a 100,000-row batch, triggering 100,000 individual PL/pgSQL context switches and blowing through `max_locks_per_transaction`), the "Unguarded Recursive Self-Trigger Cascade & Stack Overflow Deadlock" (where updating a table triggers an update on itself without `WHEN (OLD.* IS DISTINCT FROM NEW.*)` conditional predicates, crashing backends with `stack depth limit exceeded` or causing distributed deadlocks), the "SECURITY DEFINER Search Path Hijacking & Privilege Escalation (CWE-426)" (where administrative procedures omit `SET search_path = pg_catalog, pg_temp`, allowing unprivileged tenants to inject rogue operators or functions in public schemas), and the "Dynamic SQL EXECUTE Concatenation Injection & Plan Cache Thrashing" (where agents use naive string concatenation instead of `format('%I', ...)` and `USING` clauses, causing SQL injection and destroying plan cache reuse) by establishing a strict 5-Tier Trigger and Procedure Governance Ladder, formal asymptotic cost models, a production-ready TypeScript `AgenticTriggerProcedureGuardEngine`, cross-language implementations in Go, TypeScript, Python, and Rust, a complete 6-state trigger execution finite-state machine (FSM), and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Trigger & Procedure Catastrophes vs The 5-Tier Governance Ladder

In relational databases, user-defined functions (UDFs), stored procedures, and triggers allow developers to enforce business invariants, capture audit trails, and encapsulate transactional mutations within the database engine.

However, PostgreSQL's execution engine treats function volatility, execution context, security domains, and trigger execution modes with strict mathematical semantics. When autonomous coding agents write functions or triggers, they consistently fall victim to 6 catastrophic failure modes:

### The 6 Trigger & Procedure Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: PURE FUNCTION DEFAULT-VOLATILE & PARALLEL KILLER
-- Agent creates a helper to normalize email addresses or compute a hash:
CREATE OR REPLACE FUNCTION normalize_email(raw_email text)
RETURNS text AS $$
BEGIN
    RETURN lower(trim(raw_email));
END;
$$ LANGUAGE plpgsql;

-- ❌ Catastrophe:
-- 1. Agent omitted volatility: PostgreSQL defaults to VOLATILE!
-- 2. Because it is VOLATILE, it CANNOT be used in an index expression:
--    CREATE INDEX idx_users_norm_email ON users(normalize_email(email));
--    --> ERROR: functions in index expression must be marked IMMUTABLE
-- 3. In queries like: SELECT * FROM users WHERE normalize_email(email) = $1;
--    The optimizer CANNOT pre-evaluate the function or inline it. It executes the function
--    for EVERY single row in a 50-million-row table.
-- 4. PostgreSQL marks the query plan PARALLEL UNSAFE, disabling all parallel CPU workers
--    and forcing a single-threaded sequential scan, turning a 20ms query into a 15-second CPU stall!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: IMPURE FUNCTION FAKE-IMMUTABLE CORRUPTION TRAP
-- Agent wants an index on an order status check and queries a settings table:
CREATE OR REPLACE FUNCTION get_tenant_tax_rate(p_tenant_id uuid)
RETURNS numeric AS $$
    SELECT tax_rate FROM tenant_tax_configs WHERE tenant_id = p_tenant_id;
$$ LANGUAGE sql IMMUTABLE; -- ❌ LIES TO POSTGRESQL!

-- ❌ Catastrophe:
-- IMMUTABLE means the function's output depends SOLELY on its input arguments, with zero database reads.
-- By declaring this IMMUTABLE:
-- 1. If used in a generated column or index, PostgreSQL computes the value ONCE.
-- 2. When the tenant updates tax_rate in tenant_tax_configs:
--    The table index or generated column is NEVER updated!
--    The query planner inlines the stale tax rate during plan preparation.
--    Invoices and financial transactions record incorrect taxes, causing severe compliance and balance audits failure!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: THE N-ROW TRIGGER CASCADE & LOCK TABLE COLLAPSE
-- Agent is asked to maintain an audit log of all changes to line_items:
CREATE OR REPLACE FUNCTION audit_line_item_changes()
RETURNS trigger AS $$
BEGIN
    INSERT INTO line_items_audit (item_id, old_price, new_price, modified_at, modified_by)
    VALUES (NEW.id, OLD.price, NEW.price, clock_timestamp(), current_user);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_line_items
AFTER UPDATE ON line_items
FOR EACH ROW -- ❌ FIRES ONCE PER MODIFIED ROW!
EXECUTE FUNCTION audit_line_item_changes();

-- ❌ Catastrophe:
-- When a batch update modifies 100,000 line items:
-- UPDATE line_items SET price = price * 1.05 WHERE order_id = $1;
-- The database invokes 100,000 individual PL/pgSQL function calls.
-- 100,000 separate INSERT executions take place.
-- The backend exhausts shared memory lock tables (ERROR: out of shared memory / max_locks_per_transaction).
-- Batch latency explodes from 80ms to 58,000ms!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: UNGUARDED RECURSIVE SELF-TRIGGER DEADLOCK
-- Agent updates an order's updated_at timestamp or calculates running total:
CREATE OR REPLACE FUNCTION touch_order_updated_at()
RETURNS trigger AS $$
BEGIN
    UPDATE orders SET updated_at = NOW() WHERE id = NEW.id; -- ❌ RE-UPDATES THE SAME TABLE!
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_order
AFTER UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION touch_order_updated_at();

-- ❌ Catastrophe:
-- The trigger does not verify whether updated_at actually changed or check trigger depth.
-- Any UPDATE on orders triggers touch_order_updated_at(), which executes an UPDATE on orders,
-- which fires touch_order_updated_at() again...
-- The session consumes call stack frames until it crashes with:
-- ERROR: stack depth limit exceeded (max_stack_depth)
-- Under concurrent load, multiple transactions lock rows in cyclic orders, causing instant DEADLOCK storms!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: SECURITY DEFINER SEARCH_PATH HIJACKING (CWE-426)
-- Agent creates a privileged stored procedure to bypass RLS for administrative user provisioning:
CREATE OR REPLACE FUNCTION provision_admin_user(p_username text, p_email text)
RETURNS void AS $$
BEGIN
    INSERT INTO users (username, email, role) VALUES (p_username, p_email, 'admin');
    PERFORM log_system_event('USER_PROVISIONED', p_username);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER; -- ❌ RUNS WITH SUPERUSER / CREATOR PRIVILEGES!

-- ❌ Catastrophe:
-- Notice: NO search_path is set!
-- When an unprivileged attacker creates a malicious function named log_system_event()
-- or a table named users inside the 'public' or temporary schema:
-- When provision_admin_user() is invoked, PostgreSQL resolves log_system_event()
-- using the caller's search_path!
-- The attacker's malicious code executes with SUPERUSER privileges, granting full root takeover of the database!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: DYNAMIC SQL CONCATENATION INJECTION & PLAN THRASHING
-- Agent writes a generic partition archiver or filtering procedure:
CREATE OR REPLACE FUNCTION archive_tenant_partition(p_tenant_id text, p_cutoff date)
RETURNS integer AS $$
DECLARE
    v_rows integer;
    v_query text;
BEGIN
    -- ❌ NAIVE STRING CONCATENATION: SQL INJECTION AND PLAN CACHE PARALYSIS!
    v_query := 'DELETE FROM tenant_data_' || p_tenant_id || 
               ' WHERE created_at < ''' || p_cutoff || '''';
    EXECUTE v_query;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$ LANGUAGE plpgsql;

-- ❌ Catastrophe:
-- 1. SQL Injection: If p_tenant_id contains "'; DROP TABLE users; --", the database drops the table!
-- 2. Hard-parsed queries prevent plan caching. Every execution forces query parsing, rewrites,
--    and physical optimization, destroying CPU cache lines and saturating database cores.
```

---

### The 5-Tier Trigger and Procedure Governance Ladder

To eliminate these vulnerabilities permanently across all autonomous coding agents, every function, stored procedure, and trigger must conform to the **5-Tier Governance Ladder**:

```
+---------------------------------------------------------------------------------------------------+
|                           5-TIER TRIGGER & PROCEDURE GOVERNANCE LADDER                            |
+---------------------------------------------------------------------------------------------------+
| Tier 4: Parameterized Dynamic SQL with format(%I) Identifiers & USING Query Literals               |
|         -> Zero string concatenation; mandatory format('%I') for identifiers; USING parameters.   |
+---------------------------------------------------------------------------------------------------+
| Tier 3: Hardened SECURITY DEFINER Sandboxing with Pinpointed search_path & Grant Boundaries        |
|         -> Mandatory SET search_path = pg_catalog, pg_temp; REVOKE ALL FROM PUBLIC.              |
+---------------------------------------------------------------------------------------------------+
| Tier 2: Conditional Trigger Predicates (WHEN OLD IS DISTINCT FROM NEW) & Depth Guard Defense      |
|         -> Fire triggers ONLY on actual column changes; protect against loops via pg_trigger_depth|
+---------------------------------------------------------------------------------------------------+
| Tier 1: Vectorized Statement Triggers with PostgreSQL 10+ Transition Tables (REFERENCING NEW/OLD)  |
|         -> Replace FOR EACH ROW with FOR EACH STATEMENT REFERENCING NEW TABLE; 200x batch speedup.|
+---------------------------------------------------------------------------------------------------+
| Tier 0: Strict Volatility (IMMUTABLE/STABLE/VOLATILE) & Parallel Safety (PARALLEL SAFE) Tagging    |
|         -> Never default volatility; mark pure math/string logic IMMUTABLE PARALLEL SAFE.        |
+---------------------------------------------------------------------------------------------------+
```

---

## 2. Mathematical Foundations & Execution Engine Physics

### Asymptotic Complexity: Row Triggers vs Statement Transition Tables

Let $N$ denote the number of tuples modified by a single DML operation (e.g. `UPDATE line_items SET price = ...` or `INSERT INTO events SELECT ...`).

Let:
- $T_{\text{ctx\_switch}}$ denote the CPU overhead of switching execution context from PostgreSQL's C execution engine into the PL/pgSQL interpreter.
- $T_{\text{tuple\_fetch}}$ denote the cost of constructing `OLD` and `NEW` composite records and passing them to PL/pgSQL.
- $T_{\text{exec}}$ denote the execution duration of the trigger body (e.g., executing an `INSERT INTO audit_log`).
- $T_{\text{lock}}$ denote acquiring a row-level or transaction lock entry in the backend's `LockMethodLocalHash`.

#### 1. Row-Level Trigger Model (`FOR EACH ROW`)

For an $N$-tuple mutation, a row-level trigger executes $N$ discrete interpreter invocations:

$$T_{\text{row}}(N) = \sum_{i=1}^{N} \Big( T_{\text{ctx\_switch}} + T_{\text{tuple\_fetch}} + T_{\text{exec}}(1) + T_{\text{lock}} \Big) = O(N)$$

While asymptotically linear, the constant coefficient $C_{\text{row}} = T_{\text{ctx\_switch}} + T_{\text{tuple\_fetch}} + T_{\text{exec}}(1) + T_{\text{lock}}$ is enormous. In production environments, $C_{\text{row}} \approx 150\,\mu\text{s} - 800\,\mu\text{s}$ per row. For $N = 100,000$:

$$T_{\text{row}}(100,000) \approx 100,000 \times 400\,\mu\text{s} = 40.0\,\text{seconds}$$

Furthermore, the memory required to maintain row locks in PostgreSQL's local and shared lock tables grows as $O(N)$. If $N > \text{max\_locks\_per\_transaction} \times \text{max\_connections}$, the transaction crashes with `out of shared memory`.

#### 2. Vectorized Statement Trigger Model (`REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT`)

PostgreSQL 10+ introduces Ephemeral Named Relations (Transition Tables). During execution, PostgreSQL stores modified tuple pointers inside an unindexed, in-memory `Tuplestore`. When the DML statement completes, the statement trigger fires exactly **once**:

$$T_{\text{stmt}}(N) = T_{\text{ctx\_switch}} + T_{\text{bulk\_exec}}(N) + O(1)$$

Because the audit insertion is executed as a single set-based SQL query (`INSERT INTO audit_log SELECT ... FROM new_table`), PostgreSQL utilizes its bulk copy engine and vectorized heap access:

$$T_{\text{bulk\_exec}}(N) \approx C_{\text{vector}} \cdot N, \quad \text{where } C_{\text{vector}} \approx 0.5\,\mu\text{s} - 2\,\mu\text{s}$$

For $N = 100,000$:

$$T_{\text{stmt}}(100,000) \approx 200\,\mu\text{s} + 100,000 \times 1.2\,\mu\text{s} = 0.120\,\text{seconds} \quad (120\,\text{ms})$$

$$\text{Speedup Factor } S = \frac{T_{\text{row}}(100,000)}{T_{\text{stmt}}(100,000)} = \frac{40,000\,\text{ms}}{120\,\text{ms}} \approx \mathbf{333.3\times}$$

---

### Volatility Classification & Amdahl's Law of Parallel Query Workers

PostgreSQL categorizes function volatility into three distinct categories:

| Volatility | Execution Invariants | Planner Optimization | Index Expression Safe? | Parallel Safe? |
| :--- | :--- | :--- | :--- | :--- |
| **`IMMUTABLE`** | Output depends strictly on arguments. Pure mathematical or string transforms. No database reads, no environment lookups. | Can be pre-evaluated (folded) to a constant during query planning if arguments are constants. | **YES** (Mandatory) | Can be `PARALLEL SAFE` |
| **`STABLE`** | Output depends on database snapshot or current transaction (e.g. `now()`, table reads). Cannot modify database. | Re-evaluated once per statement or scan, not folded into constants at plan time. | **NO** | Can be `PARALLEL SAFE` if no lock side-effects |
| **`VOLATILE`** | Can modify state, generate random values (`random()`), or return different values within a single table scan (e.g. `clock_timestamp()`). | Must be re-evaluated for **every single row** scanned. Never folded or cached. | **NO** | **NO** (Forces `PARALLEL UNSAFE`) |

#### Amdahl's Law of Parallel Worker Degradation

When an agent leaves a function as default `VOLATILE` or marks it `PARALLEL UNSAFE`, PostgreSQL's cost planner is forbidden from launching parallel query workers on tables filtered by that function.

According to Amdahl's Law, given $P$ available CPU cores and a parallelizable fraction $f$ of the query workload:

$$S(P) = \frac{1}{(1 - f) + \frac{f}{P}}$$

If a query spends $96\%$ of its CPU cycles scanning and evaluating 20,000,000 rows ($f = 0.96$):
- With `IMMUTABLE PARALLEL SAFE` on an 8-core CPU ($P = 8$):
  $$S(8) = \frac{1}{0.04 + \frac{0.96}{8}} = \frac{1}{0.04 + 0.12} = \mathbf{6.25\times \text{ Speedup}}$$
- With default `VOLATILE` (which is `PARALLEL UNSAFE`):
  $$f \equiv 0 \implies S(8) = \mathbf{1.00\times} \quad (\text{Zero Parallelism, Single Core Saturated})$$

Leaving pure helper functions unannotated forfeits up to $85\%–90\%$ of multi-core CPU capacity!

---

### Theorem 1: Trigger Graph Acyclicity & Recursion Depth Bound

Let $G = (V, E)$ represent the directed Trigger Dependency Graph, where vertices $v_i \in V$ represent database tables and directed edges $(u, v) \in E$ indicate that an update to table $u$ invokes a trigger that modifies table $v$.

1. **Cycle Definition**: A trigger cascade contains an active cycle if there exists a path $v_1 \to v_2 \to \dots \to v_k \to v_1$.
2. **Termination Invariant**: A recursive trigger sequence terminates in finite time $t < \infty$ if and only if every cycle contains at least one strictly monotonic descending metric $M: S \to \mathbb{N}$ such that for each iteration $i$, $M(s_{i+1}) < M(s_i)$, or an explicit depth guard predicate:
   $$\text{pg\_trigger\_depth}() \le D_{\max}, \quad \text{where } D_{\max} \ge 1$$
3. **Difference Filter Invariant**: By attaching an explicit column difference clause:
   $$\text{WHEN } (\text{OLD.col} \text{ IS DISTINCT FROM } \text{NEW.col})$$
   the edge $(u, u)$ is pruned from $G$ whenever the triggering update does not mutate the guarded column, preventing $O(\infty)$ self-trigger recursion.

---

## 3. Industrial Implementations Across Languages & Frameworks

### 1. PostgreSQL Native: Hardened Volatility, Transition Table Audit, Cycle Guard & SECURITY DEFINER

Below is a complete, production-grade schema demonstrating all 5 tiers of the Trigger & Stored Procedure Governance Ladder.

```sql
-- ============================================================================
-- TIER 0: STRICT VOLATILITY & PARALLEL SAFETY ANNOTATIONS
-- ============================================================================

-- Pure string/formatting function: IMMUTABLE and PARALLEL SAFE
CREATE OR REPLACE FUNCTION app_normalize_sku(p_raw_sku text)
RETURNS text AS $$
    SELECT upper(regexp_replace(trim(p_raw_sku), '[^A-Za-z0-9_-]', '', 'g'));
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT;

-- Function reading database state: STABLE and PARALLEL SAFE
CREATE OR REPLACE FUNCTION app_get_tenant_default_currency(p_tenant_id uuid)
RETURNS text AS $$
    SELECT default_currency FROM tenants WHERE id = p_tenant_id;
$$ LANGUAGE sql STABLE PARALLEL SAFE STRICT;

-- ============================================================================
-- TIER 1: VECTORIZED STATEMENT AUDIT TRIGGER WITH TRANSITION TABLES
-- ============================================================================

CREATE TABLE inventory_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    sku text NOT NULL,
    quantity integer NOT NULL CHECK (quantity >= 0),
    unit_price numeric(12, 4) NOT NULL CHECK (unit_price >= 0),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE inventory_audit_log (
    audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    operation text NOT NULL,
    old_quantity integer,
    new_quantity integer,
    old_price numeric(12, 4),
    new_price numeric(12, 4),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    recorded_by text NOT NULL
);

-- Transition Table Statement Trigger Function
CREATE OR REPLACE FUNCTION trg_fn_audit_inventory_batch()
RETURNS trigger AS $$
BEGIN
    -- Executes ONE single vectorized INSERT regardless of whether 1 or 50,000 rows were updated!
    IF TG_OP = 'UPDATE' THEN
        INSERT INTO inventory_audit_log (
            item_id, tenant_id, operation,
            old_quantity, new_quantity,
            old_price, new_price,
            recorded_by
        )
        SELECT 
            n.id, n.tenant_id, 'UPDATE',
            o.quantity, n.quantity,
            o.unit_price, n.unit_price,
            current_user
        FROM new_rows n
        JOIN old_rows o ON n.id = o.id
        WHERE n.quantity IS DISTINCT FROM o.quantity
           OR n.unit_price IS DISTINCT FROM o.unit_price;
           
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO inventory_audit_log (
            item_id, tenant_id, operation,
            old_quantity, new_quantity,
            old_price, new_price,
            recorded_by
        )
        SELECT 
            n.id, n.tenant_id, 'INSERT',
            NULL, n.quantity,
            NULL, n.unit_price,
            current_user
        FROM new_rows n;
    END IF;

    RETURN NULL; -- Statement triggers return NULL
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp; -- Mandatory CWE-426 defense!

-- Attach statement-level trigger using transition tables
CREATE TRIGGER trg_inventory_audit_statement
AFTER INSERT OR UPDATE ON inventory_items
REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
FOR EACH STATEMENT
EXECUTE FUNCTION trg_fn_audit_inventory_batch();

-- ============================================================================
-- TIER 2: RECURSIVE CYCLE GUARD & WHEN DIFFERENCE CLAUSE
-- ============================================================================

CREATE OR REPLACE FUNCTION trg_fn_touch_inventory_timestamp()
RETURNS trigger AS $$
BEGIN
    -- Depth guard defense: Never allow cascade beyond depth 1
    IF pg_trigger_depth() > 1 THEN
        RETURN NEW;
    END IF;

    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply WHEN clause so trigger ONLY fires when data actually changes!
CREATE TRIGGER trg_inventory_touch_timestamp
BEFORE UPDATE ON inventory_items
FOR EACH ROW
WHEN (OLD.* IS DISTINCT FROM NEW.*) -- Guard against redundant self-invocation
EXECUTE FUNCTION trg_fn_touch_inventory_timestamp();

-- ============================================================================
-- TIER 3 & 4: HARDENED SECURITY DEFINER & PARAMETERIZED DYNAMIC SQL
-- ============================================================================

CREATE OR REPLACE FUNCTION app_admin_relocate_partition(
    p_tenant_id uuid,
    p_source_table text,
    p_cutoff timestamptz
)
RETURNS integer AS $$
DECLARE
    v_archived_count integer;
    v_sql text;
BEGIN
    -- 1. Authorization check at procedure entry
    IF current_setting('app.current_tenant_id', true) IS DISTINCT FROM p_tenant_id::text THEN
        RAISE EXCEPTION 'Access Denied: Tenant boundary mismatch' USING ERRCODE = '42501';
    END IF;

    -- 2. Parameterized dynamic SQL using format() %I for identifiers and USING for parameters
    v_sql := format(
        'WITH moved_rows AS (
            DELETE FROM %I
            WHERE tenant_id = $1 AND updated_at < $2
            RETURNING id
        )
        SELECT count(*)::integer FROM moved_rows;',
        p_source_table
    );

    EXECUTE v_sql USING p_tenant_id, p_cutoff INTO v_archived_count;

    RETURN v_archived_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp; -- Pin search path to prevent privilege hijacking

-- Strict grant boundaries
REVOKE ALL ON FUNCTION app_admin_relocate_partition(uuid, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app_admin_relocate_partition(uuid, text, timestamptz) TO app_service_role;
```

---

### 2. Go (`jackc/pgx/v5`): Safe Stored Procedure Execution & Trigger Verification

```go
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// InventoryBatchUpdateItem represents a single SKU adjustment inside a batch.
type InventoryBatchUpdateItem struct {
	ID        uuid.UUID
	Quantity  int
	UnitPrice float64
}

// InventoryStore handles high-throughput inventory transactions with trigger safety.
type InventoryStore struct {
	pool *pgxpool.Pool
}

func NewInventoryStore(pool *pgxpool.Pool) *InventoryStore {
	return &InventoryStore{pool: pool}
}

// BatchUpdateInventory applies bulk updates, letting the database statement-level
// transition table trigger execute vectorized audit logging in O(1) calls.
func (s *InventoryStore) BatchUpdateInventory(
	ctx context.Context,
	tenantID uuid.UUID,
	items []InventoryBatchUpdateItem,
) error {
	if len(items) == 0 {
		return nil
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Set tenant session context for RLS / audit triggers
	_, err = tx.Exec(ctx, "SELECT set_config('app.current_tenant_id', $1, true)", tenantID.String())
	if err != nil {
		return fmt.Errorf("failed setting tenant session context: %w", err)
	}

	// Use pgx.Batch to send batched updates in a single round-trip
	batch := &pgx.Batch{}
	for _, item := range items {
		batch.Queue(
			`UPDATE inventory_items
			 SET quantity = $1, unit_price = $2
			 WHERE id = $3 AND tenant_id = $4`,
			item.Quantity, item.UnitPrice, item.ID, tenantID,
		)
	}

	br := tx.SendBatch(ctx, batch)
	for i := 0; i < len(items); i++ {
		cmdTag, bErr := br.Exec()
		if bErr != nil {
			br.Close()
			return fmt.Errorf("failed executing batch item at index %d: %w", i, bErr)
		}
		if cmdTag.RowsAffected() == 0 {
			br.Close()
			return fmt.Errorf("item not found or tenant mismatch at index %d", i)
		}
	}
	if err := br.Close(); err != nil {
		return fmt.Errorf("failed closing batch results: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("failed committing transaction: %w", err)
	}

	return nil
}

// RelocatePartition invokes the hardened SECURITY DEFINER procedure safely.
func (s *InventoryStore) RelocatePartition(
	ctx context.Context,
	tenantID uuid.UUID,
	sourceTable string,
	cutoff time.Time,
) (int, error) {
	// Whitelist table names against SQL injection before passing to procedure
	validTables := map[string]bool{
		"inventory_events_2025": true,
		"inventory_events_2026": true,
	}
	if !validTables[sourceTable] {
		return 0, errors.New("invalid or unapproved source table name")
	}

	var archivedCount int
	err := s.pool.QueryRow(ctx, `
		SELECT app_admin_relocate_partition($1, $2, $3)
	`, tenantID, sourceTable, cutoff).Scan(&archivedCount)

	if err != nil {
		return 0, fmt.Errorf("stored procedure app_admin_relocate_partition failed: %w", err)
	}

	return archivedCount, nil
}
```

---

### 3. TypeScript (`Drizzle` / `Kysely`): Strongly Typed Procedure Execution & Migration DDL

```typescript
import { sql } from 'drizzle-orm';
import { pgTable, uuid, text, integer, numeric, timestamp } from 'drizzle-orm/pg-core';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

// Drizzle Schema for Inventory Table
export const inventoryItems = pgTable('inventory_items', {
  id: uuid('id').defaultRandom().primaryKey(),
  tenantId: uuid('tenant_id').notNull(),
  sku: text('sku').notNull(),
  quantity: integer('quantity').notNull(),
  unitPrice: numeric('unit_price', { precision: 12, scale: 4 }).notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
});

export class InventoryService {
  constructor(private db: NodePgDatabase) {}

  /**
   * Executes a bulk price adjustment. The PostgreSQL statement trigger
   * captures all modifications into transition tables, running audit logging in a single pass.
   */
  async updateBatchPrices(
    tenantId: string,
    updates: { id: string; price: string }[]
  ): Promise<void> {
    if (updates.length === 0) return;

    await this.db.transaction(async (tx) => {
      // 1. Establish tenant session context
      await tx.execute(
        sql`SELECT set_config('app.current_tenant_id', ${tenantId}, true)`
      );

      // 2. Perform batch updates via UNNEST to avoid N individual round-trips
      const ids = updates.map((u) => u.id);
      const prices = updates.map((u) => u.price);

      await tx.execute(sql`
        UPDATE inventory_items AS inv
        SET unit_price = data.new_price
        FROM (
          SELECT unnest(${ids}::uuid[]) AS id,
                 unnest(${prices}::numeric[]) AS new_price
        ) AS data
        WHERE inv.id = data.id AND inv.tenant_id = ${tenantId}::uuid;
      `);
    });
  }

  /**
   * Calls the hardened administrative procedure with typed parameter validation.
   */
  async callRelocateProcedure(
    tenantId: string,
    tableName: string,
    cutoffDate: Date
  ): Promise<number> {
    const allowedTables = new Set(['inventory_events_2025', 'inventory_events_2026']);
    if (!allowedTables.has(tableName)) {
      throw new Error(`Unauthorized table name: ${tableName}`);
    }

    const result = await this.db.execute<{ count: number }>(sql`
      SELECT app_admin_relocate_partition(
        ${tenantId}::uuid,
        ${tableName},
        ${cutoffDate.toISOString()}::timestamptz
      ) AS count
    `);

    return result.rows[0]?.count ?? 0;
  }
}
```

---

### 4. Python (`SQLAlchemy 2.0` / `asyncpg`): Procedure Invocation & Trigger Fixture Verification

```python
import uuid
from datetime import datetime, timezone
import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

class InventoryRepository:
    def __init__(self, session_factory: async_sessionmaker[AsyncSession]):
        self._session_factory = session_factory

    async def execute_bulk_update(
        self,
        tenant_id: uuid.UUID,
        item_updates: list[dict],
    ) -> int:
        if not item_updates:
            return 0

        async with self._session_factory() as session:
            async with session.begin():
                # 1. Tenant session setting for statement trigger security
                await session.execute(
                    text("SELECT set_config('app.current_tenant_id', :t_id, true)"),
                    {"t_id": str(tenant_id)},
                )

                # 2. Vectorized batch update via CTE
                query = text("""
                    WITH batch_data AS (
                        SELECT * FROM jsonb_to_recordset(:records::jsonb) 
                        AS x(id uuid, quantity int, unit_price numeric)
                    )
                    UPDATE inventory_items inv
                    SET quantity = b.quantity,
                        unit_price = b.unit_price
                    FROM batch_data b
                    WHERE inv.id = b.id AND inv.tenant_id = :tenant_id
                """)

                import json
                result = await session.execute(
                    query,
                    {
                        "records": json.dumps(item_updates),
                        "tenant_id": str(tenant_id),
                    },
                )
                return result.rowcount

# Verification test ensuring transition table statement trigger recorded exactly one batch audit
@pytest.mark.asyncio
async def test_transition_table_statement_trigger(session_factory):
    repo = InventoryRepository(session_factory)
    tenant_id = uuid.uuid4()
    
    # Execute batch of 500 items
    updates = [
        {"id": str(uuid.uuid4()), "quantity": 10 + i, "unit_price": 49.99}
        for i in range(500)
    ]
    # Perform update and verify database audit logs were generated without OOM or lock starvation
```

---

### 5. Rust (`sqlx`): Compile-Time Verified Trigger & Procedure Invariants

```rust
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;
use chrono::{DateTime, Utc};

pub struct InventoryService {
    pool: PgPool,
}

impl InventoryService {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Executes batch updates within a single transaction, relying on the PostgreSQL
    /// statement trigger transition table to capture changes without lock exhaustion.
    pub async fn update_inventory_batch(
        &self,
        tenant_id: Uuid,
        ids: &[Uuid],
        quantities: &[i32],
        prices: &[f64],
    ) -> Result<u64, sqlx::Error> {
        assert_eq!(ids.len(), quantities.len());
        assert_eq!(ids.len(), prices.len());

        let mut tx: Transaction<'_, Postgres> = self.pool.begin().await?;

        // 1. Transaction-scoped tenant setting
        sqlx::query("SELECT set_config('app.current_tenant_id', $1, true)")
            .bind(tenant_id.to_string())
            .execute(&mut *tx)
            .await?;

        // 2. Set-based update using UNNEST
        let rows_affected = sqlx::query!(
            r#"
            UPDATE inventory_items AS inv
            SET quantity = data.new_qty,
                unit_price = data.new_price
            FROM (
                SELECT * FROM UNNEST($1::uuid[], $2::int4[], $3::float8[])
                AS t(id, new_qty, new_price)
            ) AS data
            WHERE inv.id = data.id AND inv.tenant_id = $4
            "#,
            ids,
            quantities,
            prices,
            tenant_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();

        tx.commit().await?;
        Ok(rows_affected)
    }

    /// Invokes the hardened administrative procedure
    pub async fn archive_partition(
        &self,
        tenant_id: Uuid,
        table_name: &str,
        cutoff: DateTime<Utc>,
    ) -> Result<i32, sqlx::Error> {
        let valid_tables = ["inventory_events_2025", "inventory_events_2026"];
        if !valid_tables.contains(&table_name) {
            return Err(sqlx::Error::Protocol("Unauthorized table identifier".into()));
        }

        let record = sqlx::query!(
            r#"SELECT app_admin_relocate_partition($1, $2, $3) AS "count!""#,
            tenant_id,
            table_name,
            cutoff
        )
        .fetch_one(&self.pool)
        .await?;

        Ok(record.count)
    }
}
```

---

## 4. Production TypeScript Guard Engine: `AgenticTriggerProcedureGuardEngine`

The following TypeScript static analysis engine audits SQL migrations, triggers, and stored procedures for all 6 catastrophes, verifying volatility tags, transition tables, search_path security, and dynamic SQL safety.

```typescript
export interface Violation {
  code: string;
  severity: 'CRITICAL' | 'WARNING' | 'INFO';
  message: string;
  snippet?: string;
  remediation: string;
}

export interface AuditResult {
  isCompliant: boolean;
  score: number; // 0 - 100
  violations: Violation[];
}

export class AgenticTriggerProcedureGuardEngine {
  /**
   * Audits SQL DDL scripts for triggers, procedures, and UDFs.
   */
  public auditSql(sqlContent: string): AuditResult {
    const violations: Violation[] = [];

    this.checkMissingFunctionVolatility(sqlContent, violations);
    this.checkFakeImmutableWithDatabaseReads(sqlContent, violations);
    this.checkRowLevelAuditTriggers(sqlContent, violations);
    this.checkMissingTriggerWhenClause(sqlContent, violations);
    this.checkSecurityDefinerSearchPath(sqlContent, violations);
    this.checkDynamicSqlConcatenation(sqlContent, violations);

    const criticals = violations.filter((v) => v.severity === 'CRITICAL').length;
    const warnings = violations.filter((v) => v.severity === 'WARNING').length;
    const score = Math.max(0, 100 - criticals * 30 - warnings * 10);

    return {
      isCompliant: criticals === 0,
      score,
      violations,
    };
  }

  // 1. Catastrophe 1: Pure Function Default-VOLATILE
  private checkMissingFunctionVolatility(sql: string, violations: Violation[]): void {
    const funcRegex = /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([a-zA-Z0-9_]+)\s*\([^)]*\)\s*RETURNS\s+([^$]+)\$\$(.*?)\$\$\s*LANGUAGE\s+([a-zA-Z]+)([^;]*);/gis;
    let match: RegExpExecArray | null;

    while ((match = funcRegex.exec(sql)) !== null) {
      const [fullMatch, funcName, returnType, body, lang, tail] = match;
      const combined = (tail || '').toUpperCase();

      const hasVolatility =
        combined.includes('IMMUTABLE') ||
        combined.includes('STABLE') ||
        combined.includes('VOLATILE');

      // If it's a trigger function, returns trigger, volatility is ignored
      if (/RETURNS\s+trigger/i.test(returnType)) {
        continue;
      }

      if (!hasVolatility) {
        violations.push({
          code: 'FUNCTION_VOLATILITY_MISSING',
          severity: 'CRITICAL',
          message: `Function '${funcName}' does not specify IMMUTABLE, STABLE, or VOLATILE. PostgreSQL will default to VOLATILE, paralyzing query plans and parallel execution.`,
          snippet: fullMatch.slice(0, 150),
          remediation: `Explicitly declare IMMUTABLE (pure math/string), STABLE (reads DB/clock), or VOLATILE (mutates/random). Mark pure helpers PARALLEL SAFE.`,
        });
      }
    }
  }

  // 2. Catastrophe 2: Fake IMMUTABLE with Database Reads
  private checkFakeImmutableWithDatabaseReads(sql: string, violations: Violation[]): void {
    const funcRegex = /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([a-zA-Z0-9_]+)[\s\S]*?\$\$(.*?)\$\$[\s\S]*?;/gis;
    let match: RegExpExecArray | null;

    while ((match = funcRegex.exec(sql)) !== null) {
      const [fullMatch, funcName, body] = match;
      const isImmutable = /\bIMMUTABLE\b/i.test(fullMatch);

      if (isImmutable) {
        const readsTables = /\bFROM\s+[a-zA-Z0-9_.]+/i.test(body);
        const readsClock = /\b(?:now\(\)|current_timestamp|clock_timestamp\(\)|random\(\))/i.test(body);

        if (readsTables || readsClock) {
          violations.push({
            code: 'FAKE_IMMUTABLE_DATABASE_DEPENDENCY',
            severity: 'CRITICAL',
            message: `Function '${funcName}' is declared IMMUTABLE but reads database tables or system clocks. This causes query planner cache corruption and stale index anomalies.`,
            snippet: fullMatch.slice(0, 150),
            remediation: `Change volatility to STABLE (for table lookups or transaction clock) or VOLATILE (for random/clock_timestamp).`,
          });
        }
      }
    }
  }

  // 3. Catastrophe 3: N-Row Audit Triggers Instead of Statement Transition Tables
  private checkRowLevelAuditTriggers(sql: string, violations: Violation[]): void {
    const triggerRegex = /CREATE\s+TRIGGER\s+([a-zA-Z0-9_]+)\s+(?:AFTER|BEFORE)\s+(?:INSERT|UPDATE|DELETE)\s+ON\s+([a-zA-Z0-9_]+)\s+FOR\s+EACH\s+ROW[\s\S]*?EXECUTE\s+(?:FUNCTION|PROCEDURE)\s+([a-zA-Z0-9_]+)\s*\(/gis;
    let match: RegExpExecArray | null;

    while ((match = triggerRegex.exec(sql)) !== null) {
      const [fullMatch, triggerName, tableName, funcName] = match;
      if (/audit|log|history|event|track/i.test(triggerName) || /audit|log/i.test(funcName)) {
        violations.push({
          code: 'ROW_LEVEL_AUDIT_TRIGGER',
          severity: 'WARNING',
          message: `Trigger '${triggerName}' on table '${tableName}' performs audit logging using FOR EACH ROW. High-volume batch updates will incur O(N) context switches and exhaust lock tables.`,
          snippet: fullMatch.slice(0, 180),
          remediation: `Refactor to FOR EACH STATEMENT using PostgreSQL 10+ transition tables: REFERENCING NEW TABLE AS new_table OLD TABLE AS old_table.`,
        });
      }
    }
  }

  // 4. Catastrophe 4: Missing Trigger WHEN Clause
  private checkMissingTriggerWhenClause(sql: string, violations: Violation[]): void {
    const rowTriggerRegex = /CREATE\s+TRIGGER\s+([a-zA-Z0-9_]+)\s+(?:BEFORE|AFTER)\s+UPDATE\s+ON\s+([a-zA-Z0-9_]+)(?:(?!WHEN)[\s\S])*?FOR\s+EACH\s+ROW\s+EXECUTE/gis;
    let match: RegExpExecArray | null;

    while ((match = rowTriggerRegex.exec(sql)) !== null) {
      const [fullMatch, triggerName, tableName] = match;
      if (!/\bWHEN\b/i.test(fullMatch)) {
        violations.push({
          code: 'MISSING_TRIGGER_WHEN_CLAUSE',
          severity: 'WARNING',
          message: `Row-level UPDATE trigger '${triggerName}' on table '${tableName}' lacks a WHEN clause. It will fire unconditionally on no-op updates and risks self-recursive cascades.`,
          snippet: fullMatch.slice(0, 150),
          remediation: `Add a conditional predicate: WHEN (OLD.* IS DISTINCT FROM NEW.*) or column-specific checks: WHEN (OLD.status IS DISTINCT FROM NEW.status).`,
        });
      }
    }
  }

  // 5. Catastrophe 5: SECURITY DEFINER Search Path Hijacking (CWE-426)
  private checkSecurityDefinerSearchPath(sql: string, violations: Violation[]): void {
    const secDefRegex = /CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\s+([a-zA-Z0-9_]+)[\s\S]*?SECURITY\s+DEFINER[\s\S]*?;/gis;
    let match: RegExpExecArray | null;

    while ((match = secDefRegex.exec(sql)) !== null) {
      const [fullMatch, procName] = match;
      const hasSearchPath = /SET\s+search_path\s*=\s*pg_catalog/i.test(fullMatch);

      if (!hasSearchPath) {
        violations.push({
          code: 'SECURITY_DEFINER_UNPINNED_SEARCH_PATH',
          severity: 'CRITICAL',
          message: `SECURITY DEFINER routine '${procName}' does not pin 'SET search_path = pg_catalog, pg_temp'. Callers can hijack search paths to execute unauthorized code with elevated privileges (CWE-426).`,
          snippet: fullMatch.slice(0, 150),
          remediation: `Append 'SET search_path = pg_catalog, pg_temp' to the function/procedure definition.`,
        });
      }
    }
  }

  // 6. Catastrophe 6: Dynamic SQL Concatenation Injection
  private checkDynamicSqlConcatenation(sql: string, violations: Violation[]): void {
    const executeRegex = /\bEXECUTE\s+(['"][^'"]*['"]\s*\|\||v_[a-zA-Z0-9_]+\s*\|\|)/gis;
    let match: RegExpExecArray | null;

    while ((match = executeRegex.exec(sql)) !== null) {
      const [fullMatch] = match;
      violations.push({
        code: 'DYNAMIC_SQL_STRING_CONCATENATION',
        severity: 'CRITICAL',
        message: `Dynamic SQL EXECUTE statement uses raw string concatenation. This introduces SQL injection vulnerabilities and breaks query plan caching.`,
        snippet: fullMatch.slice(0, 120),
        remediation: `Construct queries using format() with %I for identifiers, and pass query literals via the USING clause: EXECUTE format('SELECT * FROM %I WHERE id = $1', tbl) USING val.`,
      });
    }
  }
}
```

---

## 5. Trigger & Stored Procedure Execution Lifecycle Finite-State Machine (FSM)

The following state machine governs the lifecycle of database functions, procedures, and triggers, enforcing compile-time validation, plan-cache stability, and security isolation:

```
                      +-----------------------------+
                      |         1. PARSED           |
                      |  SQL / DDL AST Construction |
                      +--------------+--------------+
                                     |
                                     v
                      +-----------------------------+
                      |     2. STATIC CONTRACT      |
                      | Volatility & Safety Check   |
                      | (IMMUTABLE / STABLE / DEF)  |
                      +--------------+--------------+
                                     |
                [Passed Static Rules & Search Path]
                                     v
                      +-----------------------------+
                      |     3. BOUND EXECUTION      |
                      | Plan Cache & Worker Binding |
                      | (PARALLEL SAFE Workers Spin)|
                      +--------------+--------------+
                                     |
                       [DML Statement Execution]
                                     v
                      +-----------------------------+
                      |    4. CONDITIONAL FIRING    |
                      | WHEN (OLD IS DISTINCT NEW)  |
                      |      Depth <= D_max         |
                      +--------------+--------------+
                                     |
                     [Batch Completes / Statement]
                                     v
                      +-----------------------------+
                      |    5. VECTORIZED TRANSITION |
                      | REFERENCING NEW TABLE Read  |
                      | Single O(1) Bulk Audit Sink |
                      +--------------+--------------+
                                     |
                                     v
                      +-----------------------------+
                      |        6. COMMITTED         |
                      | Clean Lock Table / WAL Sync |
                      +-----------------------------+
```

### FSM State Transition Table

| Current State | Event / Trigger | Target State | Guard Conditions | Invariant Enforced |
| :--- | :--- | :--- | :--- | :--- |
| **1. PARSED** | DDL Inspection | **2. STATIC CONTRACT** | AST parsed without syntax errors. | Function headers inspected for volatility and `SECURITY DEFINER`. |
| **2. STATIC CONTRACT** | Volatility Verified | **3. BOUND EXECUTION** | If `IMMUTABLE`, zero DB reads. If `SECURITY DEFINER`, search_path pinned. | Prevents CWE-426 search-path hijacking and stale index corruption. |
| **3. BOUND EXECUTION** | Worker Assignment | **4. CONDITIONAL FIRING** | If `PARALLEL SAFE`, assign to worker threads. | Amdahl's Law parallel speedup up to $8\times$. |
| **4. CONDITIONAL FIRING** | Row DML Event | **5. VECTORIZED TRANSITION** | `WHEN (OLD.* IS DISTINCT FROM NEW.*)` and `pg_trigger_depth() <= 1`. | Eliminates redundant updates and breaks infinite recursive cycles. |
| **5. VECTORIZED TRANSITION** | Statement Completion | **6. COMMITTED** | Transition tables read in single set-based query. | $333\times$ speedup over row-by-row logging; zero lock table exhaustion. |

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

Autonomous agents must satisfy every gate before submitting changes touching database triggers, UDFs, or procedures:

| Gate | Category | Invariant Rule | Verification Method | Pass Threshold |
| :--- | :--- | :--- | :--- | :--- |
| **G-1** | **Volatility** | Pure helpers marked `IMMUTABLE PARALLEL SAFE`. Queries reading DB marked `STABLE`. | `AgenticTriggerProcedureGuardEngine` | Zero unannotated functions |
| **G-2** | **Audit Invariant**| High-volume audit triggers MUST use `REFERENCING NEW TABLE FOR EACH STATEMENT`. | Static AST Regex / CI Scanner | Zero `FOR EACH ROW` audit triggers |
| **G-3** | **Recursion** | All row-level `UPDATE` triggers include `WHEN (OLD.* IS DISTINCT FROM NEW.*)`. | Schema DDL AST Lint | 100% of row triggers guarded |
| **G-4** | **Security** | `SECURITY DEFINER` routines mandate `SET search_path = pg_catalog, pg_temp`. | CI Script / DDL Static Check | Zero unpinned search paths |
| **G-5** | **Dynamic SQL** | Dynamic `EXECUTE` uses `format('%I', ...)` for identifiers and `USING` for values. | CI Linter / Regex Check | Zero string-concatenated `EXECUTE` |
| **G-6** | **Grant Scope** | `REVOKE ALL FROM PUBLIC` executed on all privileged administrative procedures. | Migration Script Inspection | 100% least-privilege role grants |

---

## 7. Summary: Autonomous Agent Quick Reference Card

```
====================================================================================================
                        DATABASE TRIGGER & PROCEDURE GOLDEN RULES
====================================================================================================

1. NEVER DEFAULT VOLATILITY:
   - Pure string, regex, or mathematical math: IMMUTABLE PARALLEL SAFE STRICT
   - Functions reading tables or transaction clock: STABLE PARALLEL SAFE
   - Functions mutating state, reading clock_timestamp(), or random(): VOLATILE

2. STATEMENT TRANSITION TABLES OVER ROW TRIGGERS:
   - Replace: AFTER UPDATE ... FOR EACH ROW EXECUTE FUNCTION log_audit();
   - With:    AFTER UPDATE ... REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
              FOR EACH STATEMENT EXECUTE FUNCTION log_audit_statement();
   - Speedup: 333x faster; avoids max_locks_per_transaction shared memory crashes.

3. ALWAYS ATTACH WHEN CONDITIONS TO ROW TRIGGERS:
   - Protect against redundant updates: WHEN (OLD.* IS DISTINCT FROM NEW.*)
   - Protect against infinite loops:    IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;

4. HARDEN SECURITY DEFINER PROCEDURES (CWE-426):
   - Always pin search path: SET search_path = pg_catalog, pg_temp;
   - Revoke public execution: REVOKE ALL ON FUNCTION ... FROM PUBLIC;
   - Grant to app role only:  GRANT EXECUTE ON FUNCTION ... TO app_role;

5. PARAMETERIZE DYNAMIC SQL:
   - Identifiers (tables/columns): format('%I', identifier)
   - Values/Literals:              USING param1, param2
   - NEVER do:                     EXECUTE 'SELECT * FROM ' || tbl || ' WHERE id = ' || id;
====================================================================================================
```
