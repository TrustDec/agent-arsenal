---
description: PostgreSQL, MySQL, and SQLite anti-join and semi-join query optimization, SQL three-valued logic (3VL) NULL semantics trap defense, NOT IN vs NOT EXISTS subquery unnesting, Hash Anti Join and Hash Semi Join plan governance, elimination of JOIN DISTINCT existence bloat, scalar correlated subquery LATERAL flattening, and index alignment across Go (pgx/v5), TypeScript (Kysely, Drizzle, Prisma), Python (SQLAlchemy, asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{query,antijoin,semijoin,sql,join,subquery,exists,database,db,dao,repository,schema,migration}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Anti-Joins, Semi-Joins, 3-Valued Logic NULL Traps, Subquery Unnesting & Short-Circuit Optimization Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to write relational database queries, implement existence checks, filter set differences, design reporting pipelines, or optimize high-throughput OLTP and analytical queries across PostgreSQL (12–17+), MySQL (8.0+), SQLite (3.38+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "The `NOT IN (SELECT ...)` NULL Trap & Three-Valued Logic Silent Data Loss Catastrophe" (where a single `NULL` value inside a subquery forces SQL standard three-valued logic to evaluate `NOT IN` to `UNKNOWN`, causing the outer query to silently return zero rows and corrupting critical business workflows such as unbilled order processing, user notifications, and compliance reporting), the "Quadratic $O(N \times M)$ SubPlan Execution Fence" (where query optimizers cannot unnest `NOT IN` subqueries on nullable columns into Hash Anti Joins, falling back to nested-loop `SubPlan` iteration that turns 10ms queries into 20-minute 100% CPU lockups), the "The `JOIN ... DISTINCT` Semi-Join Multiplier Catastrophe" (where agents check parent record existence using an inner join against a child table combined with `SELECT DISTINCT`, duplicating parent rows millions of times in memory before running an expensive sorting/hashing deduplication pass instead of short-circuiting on the first match via `WHERE EXISTS`), the "The `LEFT JOIN ... WHERE right.id IS NULL` Projection Bloat & Predicate Leak Trap" (where non-key predicates placed in the `WHERE` clause silently convert outer joins into inner joins or pull wide nullable columns into intermediate plan memory), the "Scalar Correlated Subquery N+1 Cartesian Projection Trap" (where placing `(SELECT count(*) ...)` inside a `SELECT` list forces $N$ individual execution passes instead of a vectorized `LEFT JOIN LATERAL` or hash aggregation), and the "Set Difference `EXCEPT` / `EXCEPT ALL` Memory Spill Trap" (where engine-level set difference sorts and deduplicates entire result sets across all columns rather than hashing only the join key) by establishing a strict 5-Tier Anti-Join & Semi-Join Governance Ladder, SQL 3VL mathematical proofs, complexity bounding theorems, a production-ready TypeScript `AgenticAntiJoinSemiJoinGuardEngine`, cross-runtime implementations in Go, Python, and Rust, a 6-state query optimization finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Anti-Join & Semi-Join Catastrophes vs The 5-Tier Governance Ladder

In relational algebra, set difference ($R \setminus S$) and relational filtering based on membership ($R \ltimes S$) are fundamental operations. Relational database engines implement these via physical join operators known as **Anti-Joins** ($R \ \bar{\ltimes}\ S$) and **Semi-Joins** ($R \ltimes S$):
1. **Semi-Join ($R \ltimes S$)**: Returns each row from the outer table $R$ for which there exists at least one matching row in the inner table $S$. It guarantees that rows from $R$ are never duplicated, regardless of how many rows in $S$ match the join condition.
2. **Anti-Join ($R \ \bar{\ltimes}\ S$)**: Returns each row from the outer table $R$ for which there does NOT exist any matching row in the inner table $S$.
3. **Execution Mechanics**: Both operators support early short-circuiting. As soon as the first match in $S$ is identified, evaluation for that outer tuple terminates immediately.

When autonomous coding agents generate SQL queries, repository methods, or ORM expressions, LLMs routinely commit 6 catastrophic architectural mistakes:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   NAIVE AGENT QUERY PATTERNS vs RIGOROUS PRODUCTION INVARIANTS         │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • WHERE id NOT IN (SELECT foreign_id ...) │ • WHERE NOT EXISTS (SELECT 1 FROM ...)     │
│   (Fails on NULL: silently returns 0 rows)│   (2-Valued Boolean logic: immune to NULLs)│
│ • Unnested SubPlan execution: O(N × M)    │ • Hash Anti Join / Merge Anti Join: O(N + M│
│   (100% CPU lockup on production tables)  │   (Optimizers easily unnest NOT EXISTS)    │
│ • SELECT DISTINCT u.* FROM users u JOIN   │ • SELECT u.* FROM users u WHERE EXISTS     │
│   orders o ON u.id = o.user_id            │   (SELECT 1 FROM orders o WHERE ...)       │
│   (Memory bloat, duplicates then hashes)  │   (Hash Semi Join short-circuits instantly)│
│ • LEFT JOIN ... WHERE r.id IS NULL        │ • Strictly calibrated Anti-Join: ensure    │
│   with WHERE predicates on child columns  │   all child filters reside in ON clause    │
│ • SELECT u.id, (SELECT count(*) ...)      │ • LEFT JOIN LATERAL or vectorized GROUP BY │
│   (N correlated subquery executions)      │   (Single hash aggregate pass)             │
│ • EXCEPT / EXCEPT ALL across all columns  │ • Targeted Anti-Join on primary keys       │
│   (Deduplicates entire rows in memory)    │   (Leverages existing B-tree indexes)      │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Anti-Join & Semi-Join Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                               THE 6 ANTI-JOIN & SEMI-JOIN CATASTROPHES                             |
+------------------------------------+---------------------------------------------------------------+
| 1. The NOT IN NULL 3VL Trap        | If the inner query returns a single NULL, SQL 3-valued logic  |
|    (Silent 0-Row Data Omission)    | evaluates NOT IN to UNKNOWN for all rows; entire result drops  |
+------------------------------------+---------------------------------------------------------------+
| 2. Quadratic SubPlan Lockup        | Because of nullable columns, optimizers cannot unnest NOT IN  |
|    (O(N × M) CPU Exhaustion)       | into a Hash Anti Join; falls back to SubPlan nested loops     |
+------------------------------------+---------------------------------------------------------------+
| 3. JOIN ... DISTINCT Multiplier    | Inner join duplicates parent rows per matching child row;     |
|    (Memory & Hash Thrashing)       | wastes gigabytes of memory deduplicating instead of EXISTS   |
+------------------------------------+---------------------------------------------------------------+
| 4. LEFT JOIN Predicate Leak        | Placing filter conditions on right-side columns in WHERE      |
|    (Accidental Outer-to-Inner Join)| turns outer join into inner join, destroying anti-join logic  |
+------------------------------------+---------------------------------------------------------------+
| 5. Scalar Correlated Subquery N+1  | Embedding subqueries in SELECT lists forces N sequential passes|
|    (Execution Engine Thrashing)    | instead of pipelined LEFT JOIN LATERAL or hash aggregation   |
+------------------------------------+---------------------------------------------------------------+
| 6. EXCEPT Full-Row Deduplication   | Set difference forces full-tuple sorting and hashing of both  |
|    (Unindexed Memory Spill)        | relations, bypassing indexes and spilling temp files to disk  |
+------------------------------------+---------------------------------------------------------------+
```

---

## 2. Mathematical Formalism: SQL Three-Valued Logic (3VL), Complexity Bounds & Short-Circuit Gains

### 2.1 The Three-Valued Logic (3VL) Predicate Degeneracy Theorem

Let the universe of Boolean truth values be $\mathbb{B}_3 = \{\text{TRUE}, \text{FALSE}, \text{UNKNOWN}\}$.
Under ANSI/ISO SQL standard logic, comparisons involving `NULL` yield `UNKNOWN`:
$$\forall v, \quad (v = \text{NULL}) \equiv \text{UNKNOWN}, \quad (v \ne \text{NULL}) \equiv \text{UNKNOWN}$$

The truth table for logical conjunction ($\land$) in 3VL is defined as:
$$\text{TRUE} \land \text{UNKNOWN} = \text{UNKNOWN}, \quad \text{FALSE} \land \text{UNKNOWN} = \text{FALSE}, \quad \text{UNKNOWN} \land \text{UNKNOWN} = \text{UNKNOWN}$$

**Theorem 1 (NOT IN Predicate Null Degeneracy)**:
Let $S = \{s_1, s_2, \dots, s_m\}$ be the multiset returned by a subquery. The predicate $v \notin S$ is semantically evaluated as:
$$(v \notin S) \iff \bigwedge_{i=1}^m (v \ne s_i)$$
If $\exists k \in \{1, \dots, m\}$ such that $s_k = \text{NULL}$, then for any value $v \notin (S \setminus \{\text{NULL}\})$:
$$v \ne s_k \equiv \text{UNKNOWN}$$
Consequently:
$$(v \notin S) \equiv \left(\bigwedge_{i \ne k} (v \ne s_i)\right) \land \text{UNKNOWN} \equiv \text{TRUE} \land \text{UNKNOWN} \equiv \text{UNKNOWN}$$
Because SQL `WHERE` clauses retain tuples if and only if the predicate evaluates to $\text{TRUE}$ ($\text{filter}(v) \iff \text{predicate}(v) = \text{TRUE}$):
$$\text{filter}(v) = \text{FALSE} \quad \forall v$$
The result set is identically $\emptyset$ (the empty set), regardless of the contents of the outer relation.

**Contrast with `NOT EXISTS`**:
`NOT EXISTS` evaluates the existential quantifier $\neg \exists x \in S : P(x, v)$. The result of $\exists$ is defined in classical 2-valued Boolean logic $\mathbb{B}_2 = \{\text{TRUE}, \text{FALSE}\}$:
$$\text{EXISTS}(Q) = \begin{cases} \text{TRUE} & \text{if } |Q| > 0 \\ \text{FALSE} & \text{if } |Q| = 0 \end{cases}$$
Because cardinality $|Q|$ is always a non-negative integer, `NOT EXISTS` never yields `UNKNOWN`, rendering it mathematically immune to `NULL` corruption.

### 2.2 Complexity Bounds: Hash Anti-Join vs SubPlan Nested Loop

Let $N = |R|$ be the cardinality of the outer relation, and $M = |S|$ be the cardinality of the inner relation.

1. **Unnested Hash Anti-Join ($R \ \bar{\ltimes}\ S$)**:
   - Build phase: Insert $M$ keys into an in-memory hash table: $T_{\text{build}} = \mathcal{O}(M)$.
   - Probe phase: Stream $N$ outer tuples, probe the hash table. If no match is found, emit $r$: $T_{\text{probe}} = \mathcal{O}(N)$.
   - Total Time Complexity: $\mathcal{O}(N + M)$.
   - Space Complexity: $\mathcal{O}(M)$ (or $\mathcal{O}(\min(N, M))$ with engine optimization).

2. **Un-unnested SubPlan Nested Loop (`NOT IN` on Nullable Column)**:
   - For each of the $N$ outer tuples, the subquery must be evaluated over $M$ inner tuples to check for both inequality and potential NULL values.
   - Total Time Complexity: $\mathcal{O}(N \times M)$.
   - When $N = 10^5$ and $M = 10^6$:
     $$\text{Ops}_{\text{HashAntiJoin}} \approx 1.1 \times 10^6 \implies \sim 15\text{ms}$$
     $$\text{Ops}_{\text{SubPlan}} \approx 10^{11} \implies \sim 1,200,000\text{ms} \ (20 \text{ minutes})$$
   - Performance regression factor: $\frac{N \times M}{N + M} \approx 90,900\times$ slowdown.

### 2.3 Semi-Join Early Short-Circuit Work Reduction

Let $r \in R$ be an outer tuple, and let $k_r$ be the number of matching tuples in $S$ for outer key $r.\text{id}$, with $k_r \ge 1$.
- Under `JOIN ... DISTINCT`: All $k_r$ matching tuples are joined, creating $k_r$ intermediate tuples. Subsequently, the sorting/hash aggregation deduplicates them at cost $\mathcal{O}(k_r \log k_r)$ or $\mathcal{O}(k_r)$.
- Under `WHERE EXISTS` (`Hash Semi Join`): The scan over the hash bucket terminates on the first match.
- If matches are uniformly distributed across bucket depth, expected probes before termination:
  $$\mathbb{E}[\text{Probes}] = \frac{1}{k_r / M_{\text{bucket}}} \ll k_r$$
  Eliminating intermediate tuple construction saves $100\% \times \frac{k_r - 1}{k_r}$ memory allocations.

---

## 3. The 5-Tier Anti-Join & Semi-Join Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   THE 5-TIER ANTI-JOIN & SEMI-JOIN GOVERNANCE LADDER                   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Three-Valued Logic Invariance & Zero `NOT IN (SELECT ...)` Mandate             │
│   • Absolute static ban on NOT IN subqueries across all SQL strings and ORM builders   │
│   • Enforce NOT EXISTS or LEFT JOIN ... WHERE right.id IS NULL                         │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Semi-Join Short-Circuit & Zero `JOIN ... DISTINCT` Mandate                     │
│   • Strict ban on using INNER JOIN + DISTINCT solely to assert child existence         │
│   • Rewrite as SELECT r.* FROM r WHERE EXISTS (SELECT 1 FROM s WHERE s.fk = r.id)      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: SubPlan Unnesting & Anti-Join Execution Plan Verification                      │
│   • EXPLAIN (FORMAT JSON) plan assertions in CI confirming Hash Anti Join / Merge Anti │
│   • Disallow any plan containing SubPlan or InitPlan loops for set difference          │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Non-Correlated Projection & LATERAL Vectorization                              │
│   • Prohibit scalar subqueries in SELECT projection lists                              │
│   • Transform scalar aggregations into LEFT JOIN LATERAL or vectorized GROUP BY        │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Autonomous CI AST Guard Engine & Definition of Done Gates                      │
│   • Static AST query parser flagging 3VL risks, missing foreign key indexes on probe   │
│   • Continuous production query fingerprint auditing against pg_stat_statements        │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Production-Ready TypeScript Guard Engine: `AgenticAntiJoinSemiJoinGuardEngine`

```typescript
/**
 * AgenticAntiJoinSemiJoinGuardEngine
 * Static AST query validator and optimizer detecting 3VL NULL traps,
 * unnested SubPlan execution risks, and JOIN DISTINCT memory bloat.
 */

export interface QueryAnalysisResult {
  sql: string;
  isCompliant: boolean;
  score: number; // 0 - 100
  violations: QueryViolation[];
  suggestedRewrite?: string;
}

export interface QueryViolation {
  code: 'NOT_IN_SUBQUERY_3VL' | 'JOIN_DISTINCT_SEMIJOIN_BLOAT' | 'SCALAR_SUBQUERY_PROJECTION' | 'LEFT_JOIN_WHERE_PREDICATE_LEAK' | 'EXCEPT_FULL_ROW_SPILL';
  severity: 'CRITICAL' | 'HIGH' | 'MEDIUM';
  message: string;
  location?: { line: number; column: number };
}

export class AgenticAntiJoinSemiJoinGuardEngine {
  /**
   * Analyzes a raw SQL query or ORM-generated query string for anti-join/semi-join defects.
   */
  public static analyzeQuery(sql: string): QueryAnalysisResult {
    const normalized = sql.trim();
    const violations: QueryViolation[] = [];
    let suggestedRewrite: string | undefined;

    // Rule 1: Detect NOT IN (SELECT ...) subqueries (3VL NULL Trap & O(N*M) SubPlan risk)
    const notInSubqueryRegex = /\bNOT\s+IN\s*\(\s*SELECT\b/i;
    if (notInSubqueryRegex.test(normalized)) {
      violations.push({
        code: 'NOT_IN_SUBQUERY_3VL',
        severity: 'CRITICAL',
        message: 'Detected NOT IN (SELECT ...). If any subquery row returns NULL, 3-valued logic causes the entire query to return 0 rows. Optimizers cannot unnest this into a Hash Anti Join. Rewrite with NOT EXISTS.',
      });

      // Simple heuristic rewrite recommendation
      suggestedRewrite = this.attemptNotInRewrite(normalized);
    }

    // Rule 2: Detect SELECT DISTINCT ... JOIN ... existence queries
    const selectDistinctJoinRegex = /\bSELECT\s+DISTINCT\b[\s\S]+?\bJOIN\b/i;
    if (selectDistinctJoinRegex.test(normalized) && !/\bWHERE\s+EXISTS\b/i.test(normalized)) {
      violations.push({
        code: 'JOIN_DISTINCT_SEMIJOIN_BLOAT',
        severity: 'HIGH',
        message: 'Detected SELECT DISTINCT with JOIN. If checking child existence, this generates redundant intermediate rows and expensive deduplication. Use WHERE EXISTS (Hash Semi Join).',
      });
    }

    // Rule 3: Detect correlated scalar subqueries in SELECT projection
    const scalarSubqueryInSelectRegex = /\bSELECT\b[\s\S]*?\(\s*SELECT\s+(?:COUNT|SUM|AVG|MAX|MIN|[a-zA-Z0-9_]+)\b[\s\S]*?\bFROM\b[\s\S]*?\)\s*(?:AS\s+[a-zA-Z0-9_]+)?[\s\S]*?\bFROM\b/i;
    if (scalarSubqueryInSelectRegex.test(normalized)) {
      violations.push({
        code: 'SCALAR_SUBQUERY_PROJECTION',
        severity: 'MEDIUM',
        message: 'Detected correlated scalar subquery in SELECT projection. This forces N individual SubPlan iterations. Flatten with LEFT JOIN LATERAL or vectorized GROUP BY.',
      });
    }

    // Rule 4: Detect EXCEPT / EXCEPT ALL whole-row set difference
    const exceptRegex = /\bEXCEPT(?:\s+ALL)?\b/i;
    if (exceptRegex.test(normalized)) {
      violations.push({
        code: 'EXCEPT_FULL_ROW_SPILL',
        severity: 'MEDIUM',
        message: 'Detected EXCEPT set difference. This forces sorting/hashing of all projected columns across both sets. Consider rewriting as NOT EXISTS on primary/foreign keys.',
      });
    }

    // Calculate health score
    let score = 100;
    for (const v of violations) {
      if (v.severity === 'CRITICAL') score -= 50;
      else if (v.severity === 'HIGH') score -= 25;
      else if (v.severity === 'MEDIUM') score -= 10;
    }
    score = Math.max(0, score);

    return {
      sql: normalized,
      isCompliant: violations.length === 0,
      score,
      violations,
      suggestedRewrite,
    };
  }

  /**
   * Helper that suggests a syntactic rewrite for simple NOT IN subqueries into NOT EXISTS
   */
  private static attemptNotInRewrite(sql: string): string {
    // Matches: WHERE col NOT IN (SELECT sub_col FROM sub_table WHERE filter)
    const pattern = /WHERE\s+([a-zA-Z0-9_\.]+)\s+NOT\s+IN\s*\(\s*SELECT\s+([a-zA-Z0-9_\.]+)\s+FROM\s+([a-zA-Z0-9_\.]+)(?:\s+WHERE\s+([\s\S]+?))?\s*\)/i;
    const match = sql.match(pattern);
    if (!match) return '-- Rewrite manually to WHERE NOT EXISTS (SELECT 1 FROM ... WHERE ...)';

    const [, outerCol, innerCol, subTable, existingWhere] = match;
    const innerAlias = 'sub';
    const whereClause = existingWhere ? `${existingWhere} AND ` : '';
    const replacement = `WHERE NOT EXISTS (SELECT 1 FROM ${subTable} AS ${innerAlias} WHERE ${whereClause}${innerAlias}.${innerCol.split('.').pop()} = ${outerCol})`;

    return sql.replace(match[0], replacement);
  }
}
```

---

## 5. Production-Ready Cross-Language Implementations

### 5.1 Go (`jackc/pgx/v5`): Rigorous Anti-Join & Semi-Join Repository Patterns

```go
package repository

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Customer struct {
	ID    int64  `db:"id"`
	Email string `db:"email"`
	Name  string `db:"name"`
}

type CustomerRepository struct {
	pool *pgxpool.Pool
}

func NewCustomerRepository(pool *pgxpool.Pool) *CustomerRepository {
	return &CustomerRepository{pool: pool}
}

// ❌ ANTI-PATTERN 1: NOT IN (SELECT ...) - Vulnerable to NULL values and O(N*M) SubPlan
// If any order has customer_id = NULL, this query returns 0 rows!
func (r *CustomerRepository) GetInactiveCustomersNaive(ctx context.Context) ([]Customer, error) {
	query := `
		SELECT id, email, name
		FROM customers
		WHERE id NOT IN (SELECT customer_id FROM orders); -- FATAL 3VL TRAP!
	`
	rows, err := r.pool.Query(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByName[Customer])
}

// ✅ PRODUCTION INVARIANT 1: WHERE NOT EXISTS - Immune to NULLs, leverages Hash Anti Join
func (r *CustomerRepository) GetInactiveCustomersCompliant(ctx context.Context) ([]Customer, error) {
	// PostgreSQL unrolls NOT EXISTS directly into a Hash Anti Join: O(N + M) execution time.
	query := `
		SELECT c.id, c.email, c.name
		FROM customers c
		WHERE NOT EXISTS (
			SELECT 1
			FROM orders o
			WHERE o.customer_id = c.id
		);
	`
	rows, err := r.pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("query inactive customers: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByName[Customer])
}

// ❌ ANTI-PATTERN 2: SELECT DISTINCT with JOIN - Duplicates rows then sorts/hashes
func (r *CustomerRepository) GetActiveCustomersNaive(ctx context.Context) ([]Customer, error) {
	query := `
		SELECT DISTINCT c.id, c.email, c.name
		FROM customers c
		JOIN orders o ON c.id = o.customer_id
		WHERE o.status = 'completed'; -- Severe memory bloat for customers with 10k orders!
	`
	rows, err := r.pool.Query(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByName[Customer])
}

// ✅ PRODUCTION INVARIANT 2: WHERE EXISTS (Hash Semi Join) - Early short-circuiting
func (r *CustomerRepository) GetActiveCustomersCompliant(ctx context.Context) ([]Customer, error) {
	// The planner uses Hash Semi Join; stops searching immediately after finding the first matching order.
	query := `
		SELECT c.id, c.email, c.name
		FROM customers c
		WHERE EXISTS (
			SELECT 1
			FROM orders o
			WHERE o.customer_id = c.id
			  AND o.status = 'completed'
		);
	`
	rows, err := r.pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("query active customers: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByName[Customer])
}

// ValidateQueryPlan verifies that the database planner compiles the query into an Anti-Join or Semi-Join
func (r *CustomerRepository) AssertPlanIsAntiOrSemiJoin(ctx context.Context, sqlQuery string) (bool, string, error) {
	explainQuery := fmt.Sprintf("EXPLAIN (FORMAT TEXT) %s", sqlQuery)
	var planLines []string

	rows, err := r.pool.Query(ctx, explainQuery)
	if err != nil {
		return false, "", err
	}
	defer rows.Close()

	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			return false, "", err
		}
		planLines = append(planLines, line)
	}

	fullPlan := strings.Join(planLines, "\n")
	hasAntiJoin := strings.Contains(fullPlan, "Anti Join")
	hasSemiJoin := strings.Contains(fullPlan, "Semi Join")
	hasSubPlan := strings.Contains(fullPlan, "SubPlan")

	if hasSubPlan && !hasAntiJoin && !hasSemiJoin {
		return false, fullPlan, fmt.Errorf("detected un-unnested SubPlan loop; optimizer failed to produce an Anti/Semi Join")
	}

	return hasAntiJoin || hasSemiJoin, fullPlan, nil
}
```

### 5.2 TypeScript (`Kysely` & `Drizzle ORM`): Type-Safe Anti-Join & Semi-Join Construction

```typescript
import { Kysely, sql } from 'kysely';

interface Database {
  customers: {
    id: number;
    email: string;
    name: string;
  };
  orders: {
    id: number;
    customer_id: number | null; // Nullable column creates 3VL traps!
    status: string;
    total_cents: number;
  };
}

// ==========================================
// KYSELY REPOSITORY
// ==========================================
export class CustomerKyselyRepository {
  constructor(private readonly db: Kysely<Database>) {}

  // ❌ ANTI-PATTERN: whereNotIn with subquery on nullable customer_id
  public async getUnbilledCustomersNaive() {
    return await this.db
      .selectFrom('customers')
      .selectAll()
      .where('id', 'not in', (eb) =>
        eb.selectFrom('orders').select('customer_id') // FATAL: customer_id is nullable!
      )
      .execute();
  }

  // ✅ PRODUCTION INVARIANT: whereNotExists (Hash Anti Join, 2VL safe)
  public async getUnbilledCustomersCompliant() {
    return await this.db
      .selectFrom('customers')
      .selectAll()
      .where((eb) =>
        eb.not(
          eb.exists(
            eb.selectFrom('orders')
              .select(sql`1`.as('one'))
              .whereRef('orders.customer_id', '=', 'customers.id')
          )
        )
      )
      .execute();
  }

  // ✅ PRODUCTION INVARIANT: whereExists (Hash Semi Join, short-circuits instantly)
  public async getCustomersWithCompletedOrders() {
    return await this.db
      .selectFrom('customers')
      .selectAll()
      .where((eb) =>
        eb.exists(
          eb.selectFrom('orders')
            .select(sql`1`.as('one'))
            .whereRef('orders.customer_id', '=', 'customers.id')
            .where('orders.status', '=', 'completed')
        )
      )
      .execute();
  }
}

// ==========================================
// DRIZZLE ORM REPOSITORY
// ==========================================
import { pgTable, serial, text, integer } from 'drizzle-orm/pg-core';
import { notExists, exists, eq, and } from 'drizzle-orm';
import { NodePgDatabase } from 'drizzle-orm/node-postgres';

export const customersTable = pgTable('customers', {
  id: serial('id').primaryKey(),
  email: text('email').notNull(),
  name: text('name').notNull(),
});

export const ordersTable = pgTable('orders', {
  id: serial('id').primaryKey(),
  customerId: integer('customer_id').references(() => customersTable.id),
  status: text('status').notNull(),
});

export class CustomerDrizzleRepository {
  constructor(private readonly db: NodePgDatabase) {}

  // ✅ Anti-Join via Drizzle notExists
  public async findCustomersWithoutOrders() {
    return await this.db
      .select()
      .from(customersTable)
      .where(
        notExists(
          this.db
            .select({ val: sql`1` })
            .from(ordersTable)
            .where(eq(ordersTable.customerId, customersTable.id))
        )
      );
  }

  // ✅ Semi-Join via Drizzle exists
  public async findCustomersWithActiveOrders() {
    return await this.db
      .select()
      .from(customersTable)
      .where(
        exists(
          this.db
            .select({ val: sql`1` })
            .from(ordersTable)
            .where(
              and(
                eq(ordersTable.customerId, customersTable.id),
                eq(ordersTable.status, 'active')
              )
            )
        )
      );
  }
}
```

### 5.3 Python (`SQLAlchemy 2.0` & `asyncpg`): Declarative Anti-Join & Semi-Join Invariants

```python
"""
SQLAlchemy 2.0 Declarative Anti-Join & Semi-Join Repository
"""
from typing import Sequence
from sqlalchemy import select, exists, not_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship
from sqlalchemy import Integer, String, ForeignKey

class Base(DeclarativeBase):
    pass

class CustomerModel(Base):
    __tablename__ = "customers"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    email: Mapped[str] = mapped_column(String(255), nullable=False)
    name: Mapped[str] = mapped_column(String(255), nullable=False)

class OrderModel(Base):
    __tablename__ = "orders"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    customer_id: Mapped[int | None] = mapped_column(ForeignKey("customers.id"), nullable=True)
    status: Mapped[str] = mapped_column(String(64), nullable=False)

class CustomerAsyncRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    # ❌ ANTI-PATTERN: notin_ subquery (Vulnerable to NULL rows in orders.customer_id)
    async def get_customers_without_orders_unsafe(self) -> Sequence[CustomerModel]:
        # If any OrderModel has customer_id = None, 3VL forces empty result!
        subq = select(OrderModel.customer_id)
        stmt = select(CustomerModel).where(CustomerModel.id.notin_(subq))
        result = await self.session.scalars(stmt)
        return result.all()

    # ✅ PRODUCTION INVARIANT 1: not_(exists(...)) -> Compiles to Hash Anti Join
    async def get_customers_without_orders_compliant(self) -> Sequence[CustomerModel]:
        # Immune to NULLs, unnested into Hash Anti Join: O(N + M)
        subq = (
            select(1)
            .where(OrderModel.customer_id == CustomerModel.id)
            .exists()
        )
        stmt = select(CustomerModel).where(not_(subq))
        result = await self.session.scalars(stmt)
        return result.all()

    # ✅ PRODUCTION INVARIANT 2: exists(...) -> Compiles to Hash Semi Join
    async def get_customers_with_completed_orders(self) -> Sequence[CustomerModel]:
        # Terminates search on first matching order, short-circuiting execution
        subq = (
            select(1)
            .where(
                OrderModel.customer_id == CustomerModel.id,
                OrderModel.status == "completed",
            )
            .exists()
        )
        stmt = select(CustomerModel).where(subq)
        result = await self.session.scalars(stmt)
        return result.all()
```

### 5.4 Rust (`sqlx`): Type-Safe Anti-Join Verification & Plan Assertion

```rust
use sqlx::{PgPool, FromRow};
use std::error::Error;

#[derive(Debug, FromRow)]
pub struct Customer {
    pub id: i64,
    pub email: String,
    pub name: String,
}

pub struct CustomerStore {
    pool: PgPool,
}

impl CustomerStore {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// ✅ PRODUCTION INVARIANT: NOT EXISTS query compiled to Hash Anti Join
    pub async fn find_unattached_customers(&self) -> Result<Vec<Customer>, Box<dyn Error>> {
        let customers = sqlx::query_as!(
            Customer,
            r#"
            SELECT c.id, c.email, c.name
            FROM customers c
            WHERE NOT EXISTS (
                SELECT 1
                FROM orders o
                WHERE o.customer_id = c.id
            )
            "#
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(customers)
    }

    /// ✅ PRODUCTION INVARIANT: WHERE EXISTS query compiled to Hash Semi Join
    pub async fn find_customers_with_active_orders(&self) -> Result<Vec<Customer>, Box<dyn Error>> {
        let customers = sqlx::query_as!(
            Customer,
            r#"
            SELECT c.id, c.email, c.name
            FROM customers c
            WHERE EXISTS (
                SELECT 1
                FROM orders o
                WHERE o.customer_id = c.id
                  AND o.status = 'active'
            )
            "#
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(customers)
    }
}
```

---

## 6. Finite-State Machine (FSM): Query Optimization & Unnesting Lifecycle

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             ANTI-JOIN & SEMI-JOIN OPTIMIZATION FINITE STATE MACHINE (FSM)              │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│   [ S0: QUERY_INGEST ]                                                                 │
│            │                                                                           │
│            ▼ (AST Parse / Query String Extraction)                                     │
│   [ S1: 3VL_ANTI_JOIN_TRIAGE ] ─────────────────────────┐                              │
│            │                                            │ (NOT IN subquery detected)   │
│            │ (Clean / No NOT IN subquery)               ▼                              │
│            │                                  [ S1_ERR: REWRITE_NOT_EXISTS ]           │
│            │                                            │                              │
│            ▼                                            ▼                              │
│   [ S2: SEMI_JOIN_TRIAGE ] ─────────────────────────────┘                              │
│            │                                                                           │
│            │ (JOIN DISTINCT detected for existence)                                    │
│            ├──► [ S2_ERR: REWRITE_WHERE_EXISTS ] ──┐                                   │
│            │                                       │                                   │
│            ▼ (No redundant join duplication)       │                                   │
│   [ S3: CORRELATED_PROJECTION_TRIAGE ] ◄───────────┘                                   │
│            │                                                                           │
│            │ (Scalar subquery in SELECT detected)                                      │
│            ├──► [ S3_ERR: FLATTEN_LATERAL_JOIN ] ──┐                                   │
│            │                                       │                                   │
│            ▼ (No correlated projection)            │                                   │
│   [ S4: EXPLAIN_PLAN_UNNESTING_VERIFICATION ] ◄────┘                                   │
│            │                                                                           │
│            ├──► [ Contains SubPlan Loop ] ────► REJECT (Quadratic CPU regression risk) │
│            │                                                                           │
│            ▼ [ Hash Anti Join / Hash Semi Join confirmed ]                             │
│   [ S5: INDEX_ALIGNMENT_SENTINEL ]                                                     │
│            │                                                                           │
│            ├──► [ Probe key unindexed ] ──────► FLAG (Missing supporting FK index)     │
│            │                                                                           │
│            ▼ [ Index on inner join key verified ]                                      │
│   [ S6: PRODUCTION_CERTIFIED ] ──► (Zero 3VL Risk, O(N+M) Bound, Zero Spill)           │
│                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Definition of Done (DoD) CI Verification Matrix

To certify that relational queries and repository layers are fully protected against 3VL NULL traps, SubPlan quadratic regressions, and semi-join memory blowouts, autonomous agents must satisfy all 6 gates before merging:

| Gate | Verification Target | Metric / Invariant | Enforcement Mechanism |
| :--- | :--- | :--- | :--- |
| **Gate 0** | **Zero `NOT IN (SELECT ...)`** | Total occurrences = 0 across codebase | AST query linter / static analysis regex |
| **Gate 1** | **Two-Valued Logic Invariance** | 100% of anti-joins use `NOT EXISTS` or calibrated `LEFT JOIN` | Repository code review & unit tests |
| **Gate 2** | **Zero `JOIN ... DISTINCT` Existence** | No inner joins paired with `DISTINCT` purely for parent filtering | Static AST analysis enforcing `WHERE EXISTS` |
| **Gate 3** | **Execution Plan Unnesting** | Plan must show `Hash Anti Join`, `Merge Anti Join`, or `Hash Semi Join` | CI integration test running `EXPLAIN (FORMAT JSON)` |
| **Gate 4** | **Zero `SubPlan` Loops** | Plan must have 0 `SubPlan` nodes for set difference filters | Automated CI explain parser assertion |
| **Gate 5** | **Index Alignment on Join Keys** | Foreign key probe column on child table has supporting B-Tree index | Schema audit via `pg_indexes` |
