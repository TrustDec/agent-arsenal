---
description: PostgreSQL Common Table Expressions (CTEs), AS MATERIALIZED vs AS NOT MATERIALIZED controls, query optimization fences, predicate pushdown barrier defense, recursive CTE cycle detection (CYCLE clause), volatile function multiple-evaluation hazards, tuplestore temp file disk spillage, and data-modifying CTE snapshot isolation invariants across Go (pgx/sqlc), TypeScript (Drizzle, Prisma, Kysely), Python (SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{query,index,schema,repo,repository,store,migration,entity}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Common Table Expressions (CTEs), Materialization Controls, Inlining Optimization Fences, Recursive Cycle Defense & Data-Modifying Mutation Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design complex SQL queries, hierarchical graph traversals, data pipeline transformations, analytical aggregations, or zero-downtime batch mutations across PostgreSQL (12+), Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`). Eliminate the "Multiple-Reference Implicit Materialization Trap" (where PostgreSQL 12+ silently switches from inlining to materializing CTEs when referenced two or more times, constructing an unbounded temporary tuplestore that dumps gigabytes to disk, strips index scans from outer joins, and causes query latencies to spike from 5ms to 90 seconds), the "Optimization Fence & Predicate Pushdown Blockade Trap" (where forcing `AS MATERIALIZED` or referencing a CTE multiple times prevents the query planner from pushing outer `WHERE tenant_id = $1` filters into the CTE body, forcing full table scans across all tenants and causing multi-tenant data bleed or query timeouts), the "Implicit Inlining Volatile Function & Multiple Execution Trap" (where inlined CTEs containing non-deterministic or volatile functions like `random()`, `gen_random_uuid()`, or sequence `nextval` get re-evaluated for every outer row reference, generating mismatched primary-foreign key pairs or corrupted audit state), the "Recursive CTE Infinite Graph Loop & Cycle Detection Disaster" (where `WITH RECURSIVE` traversing organizational hierarchies, dependency DAGs, or category trees encounters circular references and loops indefinitely until backend RAM is exhausted and the OOM killer decapitates the connection), the "Data-Modifying CTE Single-Snapshot Blindness Trap" (where `WITH moved AS (DELETE FROM tasks RETURNING *) INSERT INTO archive ...` executes against a single transaction snapshot, causing concurrent writes or sequential sub-statements within the same query to observe stale state or drop concurrent mutations), and the "Unbounded Tuplestore `work_mem` Spillage & Disk Thrashing Trap" (where large analytical CTEs overflow per-operation `work_mem` and write temporary disk files, creating NVMe write amplification and stalling concurrent OLTP throughput) by establishing a strict 5-Tier CTE Governance Ladder, tuplestore memory physics, predicate pushdown mathematical proofs, production TypeScript guard engines, and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 CTE Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL 12+, Common Table Expressions (`WITH` queries) underwent a fundamental architectural shift. Prior to PG 12, CTEs were unconditional **optimization fences**—they were always materialized into an ephemeral tuplestore once and never inlined. In PG 12+, non-recursive, side-effect-free CTEs are **inlined by default** if they are referenced only once. However, if a CTE is referenced **two or more times**, PostgreSQL automatically switches back to **materializing** the CTE unless explicitly instructed otherwise with `AS NOT MATERIALIZED`.

Autonomous coding agents (and human developers relying on step-by-step reasoning) frequently write deep CTE chains without understanding this planner behavior, causing catastrophic production outages:

### The 6 CTE Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: MULTIPLE-REFERENCE IMPLICIT MATERIALIZATION TRAP
-- Table 'orders' has 50,000,000 rows. Table 'order_items' has 200,000,000 rows.
-- Agent creates a CTE to calculate customer metrics, then joins it twice:
WITH customer_order_summary AS (
    SELECT 
        customer_id,
        COUNT(id) AS total_orders,
        SUM(total_amount) AS lifetime_spend,
        MAX(created_at) AS last_order_at
    FROM orders
    GROUP BY customer_id
)
SELECT 
    c.id,
    c.email,
    s.total_orders,
    s.lifetime_spend
FROM customers c
JOIN customer_order_summary s ON s.customer_id = c.id
WHERE c.tenant_id = 'tenant_enterprise_99'
  AND c.status = 'ACTIVE';

-- ❌ Catastrophe:
-- In PG 12+, if 'customer_order_summary' is referenced once here, it CAN be inlined.
-- BUT if the agent joins it again (e.g. for cohort comparison or subquery union):
-- PostgreSQL detects RefCount >= 2 and SILENTLY switches to MATERIALIZATION.
-- It executes the aggregation over ALL 50,000,000 rows across ALL tenants,
-- builds an 8 GB temporary tuplestore on disk, ignores all customer_id indexes,
-- and query latency explodes from 8ms to 110,000ms!
```

```sql
-- ✅ PRODUCTION INVARIANT: EXPLICIT INLINING OR PREDICATE HOISTING
-- Option A: Explicitly force inlining even if referenced multiple times (PG 12+)
WITH customer_order_summary AS NOT MATERIALIZED (
    SELECT 
        customer_id,
        COUNT(id) AS total_orders,
        SUM(total_amount) AS lifetime_spend
    FROM orders
    WHERE tenant_id = 'tenant_enterprise_99' -- Filter pushed inside!
    GROUP BY customer_id
)
SELECT 
    c.id, c.email, s.total_orders, s.lifetime_spend
FROM customers c
JOIN customer_order_summary s ON s.customer_id = c.id
WHERE c.tenant_id = 'tenant_enterprise_99';

-- ✅ Production Benefits:
-- 1. Outer filters are pushed directly into the B-Tree index scan (idx_orders_tenant_cust).
-- 2. Zero disk tuplestore allocation; shared_buffers reads drop from 2,000,000 pages to 45 pages.
-- 3. Execution time drops from 110s to 1.8ms.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE OPTIMIZATION FENCE & PREDICATE BLOCKADE
-- Agent writes modular CTE believing PostgreSQL will optimize across boundaries:
WITH all_tenant_events AS MATERIALIZED (
    SELECT id, tenant_id, event_type, payload, created_at
    FROM audit_events
    WHERE created_at >= NOW() - INTERVAL '30 days'
)
SELECT id, event_type, payload
FROM all_tenant_events
WHERE tenant_id = 'tenant_alpha' -- ❌ BLOCKED BY OPTIMIZATION FENCE!
ORDER BY created_at DESC
LIMIT 50;

-- ❌ Catastrophe:
-- 'AS MATERIALIZED' forces an impenetrable optimization fence.
-- The query planner evaluates 'all_tenant_events' in complete isolation.
-- It reads 100,000,000 events across 5,000 tenants, materializes them into disk temp files,
-- and ONLY THEN applies the 'tenant_id = tenant_alpha' filter on the materialized tuplestore!
-- Result: Disk full PANIC, worker CPU at 100%, and multi-tenant noisy neighbor outage.
```

```sql
-- ✅ PRODUCTION INVARIANT: PREDICATE SARGABILITY WITHIN CTE OR AS NOT MATERIALIZED
-- Always declare AS NOT MATERIALIZED when filtering downstream:
WITH tenant_events AS NOT MATERIALIZED (
    SELECT id, tenant_id, event_type, payload, created_at
    FROM audit_events
    WHERE created_at >= NOW() - INTERVAL '30 days'
)
SELECT id, event_type, payload
FROM tenant_events
WHERE tenant_id = 'tenant_alpha'
ORDER BY created_at DESC
LIMIT 50;
-- The planner flattens this into:
-- SELECT id, event_type, payload FROM audit_events 
-- WHERE created_at >= ... AND tenant_id = 'tenant_alpha' ...
-- Utilizing index (tenant_id, created_at DESC) for an instantaneous 0.4ms Index Scan!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: VOLATILE FUNCTION MULTIPLE EXECUTION TRAP
-- Agent writes a CTE generating an ephemeral token or UUID:
WITH generated_keys AS (
    SELECT 
        id AS user_id,
        gen_random_uuid() AS session_token,
        CLOCK_TIMESTAMP() AS issued_at
    FROM users
    WHERE tenant_id = 'tenant_123'
)
SELECT 
    k.user_id,
    k.session_token AS primary_token,
    k.session_token AS confirm_token, -- ❌ Inlined volatile function!
    k.issued_at
FROM generated_keys k;

-- ❌ Catastrophe:
-- Because 'generated_keys' is referenced only once, PG 12+ INLINES IT!
-- The planner substitutes 'gen_random_uuid()' directly into both select expressions.
-- Result: 'primary_token' and 'confirm_token' receive TWO DIFFERENT UUIDs!
-- Session verification fails immediately, breaking authentication.
```

```sql
-- ✅ PRODUCTION INVARIANT: EXPLICIT MATERIALIZATION FENCE FOR VOLATILE FUNCTIONS
WITH generated_keys AS MATERIALIZED (
    SELECT 
        id AS user_id,
        gen_random_uuid() AS session_token,
        CLOCK_TIMESTAMP() AS issued_at
    FROM users
    WHERE tenant_id = 'tenant_123'
)
SELECT 
    k.user_id,
    k.session_token AS primary_token,
    k.session_token AS confirm_token, -- ✅ Guaranteed identical value!
    k.issued_at
FROM generated_keys k;
-- 'AS MATERIALIZED' forces single execution into an ephemeral buffer.
-- Both columns are guaranteed identical bit-for-bit values.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: RECURSIVE CTE INFINITE GRAPH LOOP
-- Graph table: node_edges (parent_id, child_id).
-- LLM writes recursive query to find all descendants:
WITH RECURSIVE descendants AS (
    SELECT child_id, 1 AS depth
    FROM node_edges
    WHERE parent_id = 'node_root'
    
    UNION ALL
    
    SELECT e.child_id, d.depth + 1
    FROM node_edges e
    JOIN descendants d ON e.parent_id = d.child_id
)
SELECT * FROM descendants;

-- ❌ Catastrophe:
-- If any cyclical reference exists (e.g. Node A -> Node B -> Node A):
-- The recursion NEVER terminates.
-- It generates billions of duplicate rows, consumes 100% CPU, expands backend memory
-- until the Linux OOM Killer executes SIGKILL on PostgreSQL postmaster!
```

```sql
-- ✅ PRODUCTION INVARIANT: POSTGRESQL 14+ CYCLE CLAUSE OR DEPTH/PATH BOUNDS
-- In PostgreSQL 14+, declare declarative CYCLE defense:
WITH RECURSIVE descendants AS (
    SELECT child_id, 1 AS depth
    FROM node_edges
    WHERE parent_id = 'node_root'
    
    UNION ALL
    
    SELECT e.child_id, d.depth + 1
    FROM node_edges e
    JOIN descendants d ON e.parent_id = d.child_id
    WHERE d.depth < 50 -- Bounded recursion depth fence!
)
CYCLE child_id SET is_cycle USING path
SELECT child_id, depth, path
FROM descendants
WHERE NOT is_cycle;
-- Terminating, deterministic, cycle-free, and safe for production!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: DATA-MODIFYING CTE SNAPSHOT BLINDNESS
-- Agent attempts to atomically transfer funds between two accounts in one query:
WITH debit AS (
    UPDATE accounts 
    SET balance = balance - 100 
    WHERE id = 'acc_alice' AND balance >= 100
    RETURNING balance AS new_alice_balance
),
credit AS (
    UPDATE accounts 
    SET balance = balance + 100 
    WHERE id = 'acc_bob' AND (SELECT COUNT(*) FROM debit) > 0
    RETURNING balance AS new_bob_balance
)
-- Agent tries to read final state from accounts in the same query:
SELECT a.id, a.balance
FROM accounts a
WHERE a.id IN ('acc_alice', 'acc_bob');

-- ❌ Catastrophe:
-- In PostgreSQL, all CTEs and the main query execute against the EXACT SAME SNAPSHOT.
-- The outer SELECT reads the state of 'accounts' as it was BEFORE the CTE updates ran!
-- The outer SELECT returns the OLD balances, tricking the caller into believing
-- the mutation failed or reporting stale data to financial ledgers.
```

```sql
-- ✅ PRODUCTION INVARIANT: PROJECT MUTATION RESULTS DIRECTLY FROM RETURNING
WITH debit AS (
    UPDATE accounts 
    SET balance = balance - 100 
    WHERE id = 'acc_alice' AND balance >= 100
    RETURNING id, balance, 'DEBIT' AS operation
),
credit AS (
    UPDATE accounts 
    SET balance = balance + 100 
    WHERE id = 'acc_bob' AND EXISTS (SELECT 1 FROM debit)
    RETURNING id, balance, 'CREDIT' AS operation
)
SELECT * FROM debit
UNION ALL
SELECT * FROM credit;
-- Directly consumes RETURNING buffers; zero snapshot blindness!
```

---

## 2. Mathematical Foundations & Formal Optimization Physics

### Theorem 1: Tuplestore Disk Spillage and `work_mem` Threshold

Let a materialized CTE produce $N$ intermediate tuples, each with average physical width $W_{\text{tuple}}$ bytes. Let $H_{\text{overhead}}$ denote the tuplestore node header overhead (~32 bytes per tuple).

The total in-memory working footprint $S_{\text{tuplestore}}$ is given by:

$$S_{\text{tuplestore}} = \sum_{i=1}^{N} (W_{\text{tuple}}^{(i)} + H_{\text{overhead}}) + B_{\text{tuplestore\_meta}}$$

If $S_{\text{tuplestore}} > \text{work\_mem}$, PostgreSQL's tuplestore transitions from state `TSS_INMEM` to `TSS_WRITEFILE`, creating temporary disk files in `pgsql_tmp`:

$$V_{\text{spill}} = \max(0, \; S_{\text{tuplestore}} - \text{work\_mem})$$

When $V_{\text{spill}} > 0$:
1. Write I/O penalty: $N$ tuples written sequentially to NVMe temp storage ($O(N)$ writes).
2. Read I/O penalty: Outer query reads $N$ tuples from disk ($O(N)$ reads).
3. Total I/O amplification: $A_{\text{I/O}} = 2 \cdot V_{\text{spill}}$.
4. If `temp_file_limit` is exceeded, PostgreSQL raises SQLSTATE `53400` (`configuration_limit_exceeded`) and aborts the transaction.

### Theorem 2: Predicate Pushdown Selectivity & I/O Complexity Differential

Let table $\mathcal{T}$ have total cardinality $|\mathcal{T}| = M$.
Let the outer query filter predicate $\mathcal{P}_{\text{outer}}$ have selectivity $\sigma = \frac{|\sigma(\mathcal{T})|}{M} \ll 1$.

**Case A: Materialized CTE (Optimization Fence Intact)**:
1. Inner CTE executes full table scan / wide index scan over $M$ tuples:
   $$\text{Cost}_{\text{inner}} = O(M)$$
2. Tuplestore materialization of $M$ tuples:
   $$\text{Cost}_{\text{mat}} = O(M)$$
3. Outer query scans materialized tuplestore to apply $\mathcal{P}_{\text{outer}}$:
   $$\text{Cost}_{\text{outer}} = O(M \cdot \sigma)$$
4. Total execution cost:
   $$\text{Cost}_{\text{fenced}} = O(2M + \sigma M) \approx \Theta(M)$$

**Case B: Inlined CTE (`AS NOT MATERIALIZED` or Single-Ref Inlined)**:
1. Planner pushes predicate $\mathcal{P}_{\text{outer}}$ directly into the scan of $\mathcal{T}$.
2. If B-Tree index $\mathcal{I}$ exists on the filtered columns:
   $$\text{Cost}_{\text{inlined}} = O(\log_B(M) + \sigma M)$$
3. The Speedup Factor $\mathcal{S}_{\text{pushdown}}$ is:
   $$\mathcal{S}_{\text{pushdown}} = \frac{\text{Cost}_{\text{fenced}}}{\text{Cost}_{\text{inlined}}} \approx \frac{2M}{\log_B(M) + \sigma M}$$

When $M = 50,000,000$ and $\sigma = 0.0001$ (5,000 target rows):
$$\mathcal{S}_{\text{pushdown}} \approx \frac{100,000,000}{4 + 5,000} \approx 20,000 \times \text{ faster!}$$

### Theorem 3: Recursive CTE Termination Bounds & Cycle Invariance

A recursive CTE on a directed graph $G = (V, E)$ computes the transitive closure:

$$R_{k+1} = R_k \cup \{ v \in V \mid \exists u \in R_k, \; (u, v) \in E \}$$

Without cycle detection:
- If $G$ contains a directed cycle $C = (v_1, v_2, \dots, v_k, v_1)$, then $|R_{\infty}| = \infty$.
- Space and time complexity diverge: $\lim_{t \to \infty} \text{Memory}(t) = \infty$, guaranteeing an out-of-memory crash.

With `CYCLE` detection or path tracking array $P$:
- For any step $k$, a candidate node $v$ is added if and only if $v \notin P_k$.
- Because $|V|$ is finite, the maximum path length without cycles is bounded by $|V| - 1$.
- Maximum iterations: $k_{\max} \le |V|$.
- Time complexity: $O(|V| + |E|)$, guaranteeing deterministic termination.

---

## 3. The 5-Tier CTE Governance Ladder

| Tier | Name | Target Problem | Production Rule |
| :--- | :--- | :--- | :--- |
| **Tier 0** | **Explicit Materialization Declaration** | Planner guessing on multi-ref CTEs | Declare `AS MATERIALIZED` or `AS NOT MATERIALIZED` explicitly whenever a CTE is referenced $\ge 2$ times or contains aggregations. |
| **Tier 1** | **Predicate Pushdown & Scope Inlining** | 20,000x slow table scans across all tenants | Never filter outer queries against materialized CTEs. Enforce `AS NOT MATERIALIZED` or hoist `tenant_id` filters directly into CTE bodies. |
| **Tier 2** | **Volatile Function Fencing** | Inlined functions (`random()`, `uuid()`) re-evaluating | Wrap volatile functions in `AS MATERIALIZED` CTEs to guarantee single-pass computation and bitwise consistency across references. |
| **Tier 3** | **Recursive Graph Cycle Defense** | Infinite loops, OOM server crashes | Every `WITH RECURSIVE` must declare PostgreSQL 14+ `CYCLE col SET is_cycle USING path` and a hard depth fence `WHERE depth <= :max_depth`. |
| **Tier 4** | **Data-Modifying Snapshot Coherence** | Lost updates, stale reads in mutation queries | Read atomic mutations directly from `RETURNING` clauses; never query the modified table in the same statement expecting to see CTE mutations. |

---

## 4. Universal Production Code Standards

### Go (`jackc/pgx/v5` & `sqlc`): High-Throughput Predicate-Pushdown CTE & Recursive Hierarchy

```go
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// OrgNode represents an organizational hierarchy element fetched via cycle-safe recursive CTE.
type OrgNode struct {
	ID       string `json:"id"`
	ParentID *string `json:"parent_id"`
	Name     string `json:"name"`
	Depth    int    `json:"depth"`
	Path     string `json:"path"`
}

// FetchOrgHierarchy recursively traverses an organizational tree with guaranteed cycle prevention
// and depth bounding using PostgreSQL 14+ CYCLE clause.
func FetchOrgHierarchy(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	rootNodeID string,
	maxDepth int,
) ([]OrgNode, error) {
	if maxDepth <= 0 || maxDepth > 50 {
		maxDepth = 25 // Strict guardrail against runaway recursion
	}

	query := `
		WITH RECURSIVE org_tree AS (
			-- Anchor Member: Find root node scoped strictly by tenant_id
			SELECT 
				id,
				parent_id,
				name,
				1 AS depth
			FROM org_nodes
			WHERE tenant_id = $1 
			  AND id = $2
			  AND deleted_at IS NULL

			UNION ALL

			-- Recursive Member: Join children with depth bound
			SELECT 
				c.id,
				c.parent_id,
				c.name,
				t.depth + 1 AS depth
			FROM org_nodes c
			JOIN org_tree t ON c.parent_id = t.id
			WHERE c.tenant_id = $1
			  AND c.deleted_at IS NULL
			  AND t.depth < $3 -- Hard depth fence
		)
		CYCLE id SET is_cycle USING path
		SELECT 
			id,
			parent_id,
			name,
			depth,
			array_to_string(path, ' -> ') AS path_str
		FROM org_tree
		WHERE NOT is_cycle
		ORDER BY depth ASC, name ASC;
	`

	rows, err := pool.Query(ctx, query, tenantID, rootNodeID, maxDepth)
	if err != nil {
		return nil, fmt.Errorf("fetch org hierarchy query failed: %w", err)
	}
	defer rows.Close()

	var nodes []OrgNode
	for rows.Next() {
		var n OrgNode
		if err := rows.Scan(&n.ID, &n.ParentID, &n.Name, &n.Depth, &n.Path); err != nil {
			return nil, fmt.Errorf("scan org node row: %w", err)
		}
		nodes = append(nodes, n)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("org tree iteration error: %w", err)
	}

	return nodes, nil
}

// DrainAndArchiveBatch atomically moves expired tasks to an archive table using a data-modifying CTE
// without snapshot blindness.
func DrainAndArchiveBatch(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	batchSize int,
) (int64, error) {
	if batchSize <= 0 || batchSize > 1000 {
		batchSize = 500
	}

	query := `
		WITH deleted_tasks AS (
			DELETE FROM task_queue
			WHERE id IN (
				SELECT id 
				FROM task_queue
				WHERE tenant_id = $1
				  AND status = 'COMPLETED'
				  AND updated_at < CLOCK_TIMESTAMP() - INTERVAL '7 days'
				ORDER BY updated_at ASC
				LIMIT $2
				FOR UPDATE SKIP LOCKED
			)
			RETURNING id, tenant_id, payload, created_at, updated_at
		),
		archived_tasks AS (
			INSERT INTO task_archive (id, tenant_id, payload, created_at, archived_at)
			SELECT 
				id, 
				tenant_id, 
				payload, 
				created_at, 
				CLOCK_TIMESTAMP()
			FROM deleted_tasks
			RETURNING id
		)
		SELECT count(*) FROM archived_tasks;
	`

	var archivedCount int64
	err := pool.QueryRow(ctx, query, tenantID, batchSize).Scan(&archivedCount)
	if err != nil {
		return 0, fmt.Errorf("drain and archive batch failed: %w", err)
	}

	return archivedCount, nil
}
```

---

## 5. Production TypeScript CTE Guard Engine

This self-contained TypeScript static analysis harness validates SQL CTE queries before deployment:

```typescript
// agentic-cte-guard-engine.ts
export interface CTEAnalysisResult {
  isValid: boolean;
  violations: string[];
  recommendations: string[];
  cteCount: number;
  detectedRecursive: boolean;
  detectedDataModifying: boolean;
}

export class AgenticCTEGuardEngine {
  /**
   * Analyzes SQL query text for common CTE performance hazards and logic bugs.
   */
  public static auditQuery(sql: string): CTEAnalysisResult {
    const violations: string[] = [];
    const recommendations: string[] = [];
    const normalized = sql.replace(/\s+/g, ' ').trim();

    // Check if query uses CTE
    const hasCTE = /\bWITH\b/i.test(normalized);
    if (!hasCTE) {
      return {
        isValid: true,
        violations: [],
        recommendations: [],
        cteCount: 0,
        detectedRecursive: false,
        detectedDataModifying: false,
      };
    }

    const isRecursive = /\bWITH\s+RECURSIVE\b/i.test(normalized);
    const isDataModifying = /\b(INSERT|UPDATE|DELETE)\b/i.test(normalized) &&
                            /\bRETURNING\b/i.test(normalized);

    // Extract CTE names defined in WITH clause
    const cteDefinitions = this.extractCTENames(normalized);

    // Hazard 1: Recursive CTE without cycle detection or depth bounding
    if (isRecursive) {
      const hasCycleClause = /\bCYCLE\b/i.test(normalized);
      const hasDepthFence = /\bdepth\s*(<|<=)\s*\d+/i.test(normalized) ||
                            /\bLIMIT\b/i.test(normalized);

      if (!hasCycleClause && !hasDepthFence) {
        violations.push(
          'UNBOUNDED_RECURSIVE_CTE: Recursive CTE found without PostgreSQL 14+ CYCLE clause ' +
          'or explicit depth boundary condition. Risk of infinite loops and postmaster OOM.'
        );
        recommendations.push(
          'Append "CYCLE <primary_key> SET is_cycle USING path" and include WHERE NOT is_cycle.'
        );
      }
    }

    // Hazard 2: Multiple references to CTE without explicit MATERIALIZED declaration
    for (const cteName of cteDefinitions) {
      const refCount = this.countOccurrences(normalized, cteName);
      // If referenced more than once (one in definition, at least 2 in body => total count > 2)
      if (refCount > 2) {
        const hasExplicitMat = new RegExp(`\\b${cteName}\\s+AS\\s+(MATERIALIZED|NOT\\s+MATERIALIZED)\\b`, 'i').test(normalized);
        if (!hasExplicitMat) {
          recommendations.push(
            `MULTI_REF_CTE_UNSPECIFIED_MATERIALIZATION: CTE "${cteName}" is referenced ${refCount - 1} times ` +
            'without explicit "AS MATERIALIZED" or "AS NOT MATERIALIZED". PostgreSQL 12+ will implicitly materialize ' +
            'this into a tuplestore, blocking index scans on outer joins.'
          );
        }
      }
    }

    // Hazard 3: Outer WHERE clause with tenant_id filtering against materialized CTE
    if (/\bAS\s+MATERIALIZED\b/i.test(normalized)) {
      const hasOuterTenantFilter = /\bWHERE\b.*?\btenant_id\b/i.test(normalized);
      const cteHasTenantFilter = /\bWITH\b.*?\btenant_id\b.*?\bAS\s+MATERIALIZED\b/i.test(normalized);

      if (hasOuterTenantFilter && !cteHasTenantFilter) {
        violations.push(
          'MATERIALIZED_PREDICATE_BLOCKADE: Outer query filters by tenant_id, but the CTE is explicitly ' +
          'declared AS MATERIALIZED without tenant filtering inside. The optimization fence will force ' +
          'a full table scan across all tenants.'
        );
        recommendations.push(
          'Hoist "WHERE tenant_id = :tenant_id" directly into the materialized CTE body.'
        );
      }
    }

    // Hazard 4: Volatile function in potentially inlined CTE
    const containsVolatile = /\b(random\(\)|gen_random_uuid\(\)|clock_timestamp\(\)|nextval\()/i.test(normalized);
    if (containsVolatile && !/\bAS\s+MATERIALIZED\b/i.test(normalized)) {
      recommendations.push(
        'VOLATILE_FUNCTION_INLINING_RISK: CTE contains volatile functions (random, uuid, nextval) ' +
        'without "AS MATERIALIZED". If inlined, PostgreSQL may evaluate the function multiple times per outer row.'
      );
    }

    return {
      isValid: violations.length === 0,
      violations,
      recommendations,
      cteCount: cteDefinitions.length,
      detectedRecursive: isRecursive,
      detectedDataModifying: isDataModifying,
    };
  }

  private static extractCTENames(sql: string): string[] {
    const cteNames: string[] = [];
    const withMatch = sql.match(/\bWITH\s+(?:RECURSIVE\s+)?([a-zA-Z0-9_]+)\s+AS/gi);
    if (withMatch) {
      for (const match of withMatch) {
        const parts = match.split(/\s+/);
        const nameIndex = parts.findIndex(p => /^as$/i.test(p)) - 1;
        if (nameIndex >= 0 && parts[nameIndex]) {
          cteNames.push(parts[nameIndex]);
        }
      }
    }
    return cteNames;
  }

  private static countOccurrences(text: string, word: string): number {
    const regex = new RegExp(`\\b${word}\\b`, 'gi');
    return (text.match(regex) || []).length;
  }
}
```

---

## 6. Finite-State Machine: CTE Execution & Lifecycle Optimization FSM

```
+-------------------------------------------------------------+
|                [1] CTE QUERY ANALYSIS                      |
| Parse AST: Extract CTE names, ref counts, volatile funcs,  |
| recursion markers, and outer predicate expressions          |
+------------------------------+------------------------------+
                               |
                               v
+-------------------------------------------------------------+
|             [2] INLINING VS MATERIALIZATION DECISION        |
| - RefCount == 1 AND No Volatiles => AS NOT MATERIALIZED     |
| - RefCount >= 2 OR Volatile Key => AS MATERIALIZED          |
| - Downstream Selective Filters => Hoist into CTE Body       |
+------------------------------+------------------------------+
                               |
                               v
+-------------------------------------------------------------+
|             [3] RECURSIVE TERMINATION GOVERNANCE           |
| Is Recursive == true?                                       |
| - Verify CYCLE clause exists (PG 14+)                       |
| - Verify depth <= :max_depth fence exists                   |
+------------------------------+------------------------------+
                               |
                               v
+-------------------------------------------------------------+
|             [4] SNAPSHOT COHERENCE & MUTATION CHECK        |
| Is Data-Modifying CTE?                                      |
| - Verify results projected strictly via RETURNING           |
| - Ensure zero duplicate reads of modified tables in main    |
+------------------------------+------------------------------+
                               |
                               v
+-------------------------------------------------------------+
|             [5] BUFFER & WORK_MEM SPILLAGE VERIFICATION    |
| Run EXPLAIN (ANALYZE, BUFFERS):                             |
| - Verify TempWrittenBlocks == 0 (zero disk spill)           |
| - Verify Index Scans utilized on underlying heap            |
+------------------------------+------------------------------+
                               |
                               v
+-------------------------------------------------------------+
|             [6] CI GATE APPROVAL & DEPLOYMENT              |
| Query passes static guard engine and satisfies DoD matrix   |
+-------------------------------------------------------------+
```

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Automated Command / Assertion | Pass Criteria |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **Explicit Materialization** | Static Code Analysis AST regex | All CTEs referenced $\ge 2$ times explicitly declare `MATERIALIZED` or `NOT MATERIALIZED`. |
| **Gate 2** | **Recursive Cycle Guard** | Static Analysis / SQL parser | Every `WITH RECURSIVE` has `CYCLE` clause and bounded depth condition. |
| **Gate 3** | **Predicate Pushdown** | `EXPLAIN (ANALYZE, BUFFERS)` | Scans on underlying tables show `Filter` pushed down to index level; no sequential scans on large tables. |
| **Gate 4** | **Zero Temp Disk Spill** | `EXPLAIN (ANALYZE, BUFFERS)` | `TempWrittenBlocks = 0` and `temp_file_limit` not approached. |
| **Gate 5** | **Volatile Determinism** | Test Harness verification | Multiple references to generated keys within a CTE produce identical results. |
| **Gate 6** | **Mutation Coherence** | Unit Integration Tests | Data-modifying CTE mutations return correct count without reading stale snapshots. |
