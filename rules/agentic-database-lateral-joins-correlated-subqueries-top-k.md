---
description: PostgreSQL (9.3+), MySQL (8.0.14+), and SQLite (3.34+) LATERAL joins, CROSS JOIN LATERAL, LEFT JOIN LATERAL, per-group Top-K optimizations, index-driven nested loop seeks, correlated subquery consolidation, JSONB/array set-returning functions unnesting WITH ORDINALITY, computed expression aliasing via LATERAL VALUES, Cartesian product defense, and query optimization across Go (pgx/v5), TypeScript (Drizzle, Kysely, Prisma), Python (SQLAlchemy, asyncpg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{lateral,join,query,topk,correlated,subquery,repo,repository,store,dao,model,service}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database LATERAL Joins, Correlated Subqueries, Per-Group Top-K Optimization & Cartesian Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design complex relational queries, grouped aggregations, top-N per category listings, parent-child feeds, JSONB/array expansion pipelines, or analytical summary endpoints across PostgreSQL (9.3+), MySQL (8.0.14+), SQLite (3.34+ with table-valued functions), Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `prisma`), Python (`SQLAlchemy`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Full-Table Window Function Scan Disaster" (where agents use `ROW_NUMBER() OVER (PARTITION BY ...)` to fetch Top-$K$ items per category, forcing the query engine to sequence-scan and sort 50 million rows in memory or disk temp files when only 3 rows per group are needed), the "$M$-Times Correlated Scalar Subquery Explosion" (where agents embed multiple independent `(SELECT count(*) ...)` and `(SELECT max(...) ...)` subqueries in the `SELECT` projection, multiplying index seeks by $M \times N$ and thrashing database buffer pools), the "Missing `LEFT JOIN LATERAL` Ghost Entity Deletion Disaster" (where agents use `CROSS JOIN LATERAL` instead of `LEFT JOIN LATERAL`, causing parent rows with zero matching child entities—such as new users or empty categories—to vanish silently from API responses), the "Unindexed Nested Loop Cartesian Apocalypse" (where a `LATERAL` join executes without an index matching `(parent_id, sort_column DESC)`, turning an intended millisecond seek into an $O(|R| \cdot |S|)$ CPU-exhausting full-table nested loop scan), the "Array & JSONB Cartesian Multiplication Nightmare" (where unnesting array columns or JSONB collections using comma joins or unindexed functions causes duplicate row multiplication and metric distortion), and the "Repeated Complex Expression Computation Churn" (where heavy computed formulas or JSON extractions are duplicated identically across `SELECT`, `WHERE`, and `ORDER BY`) by establishing a strict 5-Tier LATERAL Join Governance Ladder, formal index seek vs sequential scan cost models, production-ready TypeScript `AgenticLateralJoinGuardEngine`, cross-language implementations in Go, TypeScript, Python, and Rust, a complete 6-state query execution finite-state machine (FSM), and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 LATERAL & Correlated Subquery Catastrophes vs The 5-Tier Governance Ladder

In SQL standard relational theory, a subquery in the `FROM` clause is evaluated independently of other relations in the same `FROM` list. PostgreSQL 9.3+ and MySQL 8.0.14+ introduced the `LATERAL` join keyword (analogous to Microsoft SQL Server's `CROSS APPLY` / `OUTER APPLY`), which acts as an in-database `foreach` loop: for each row evaluated in the preceding table expression, the `LATERAL` subquery is evaluated with access to columns from that outer row.

When autonomous coding agents generate queries involving grouped Top-N records, correlated aggregates, or document unnesting, they consistently stumble into 6 architectural anti-patterns:

### The 6 LATERAL & Correlated Subquery Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE FULL-TABLE TOP-K WINDOW FUNCTION SCAN
-- Agent is asked: "Fetch the 3 latest orders for each active customer"
-- Agent writes naive CTE with ROW_NUMBER():
WITH ranked_orders AS (
    SELECT
        id, customer_id, total_amount, created_at,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at DESC) AS rn
    FROM orders
    WHERE status != 'cancelled'
)
SELECT c.id, c.name, ro.id, ro.total_amount, ro.created_at
FROM customers c
JOIN ranked_orders ro ON ro.customer_id = c.id
WHERE c.is_active = true AND ro.rn <= 3;

-- ❌ Catastrophe:
-- If orders has 50,000,000 rows and customers has 10,000 active rows:
-- The database CANNOT push down the LIMIT 3 into the window function!
-- PostgreSQL must Seq Scan all 50M rows in orders, sort all 50M rows in memory/temp files (spilling work_mem),
-- calculate row numbers for all 50M rows, and then discard 99.7% of the computed tuples!
-- Query takes 45,000ms and saturates server disk I/O.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE M-TIMES CORRELATED SCALAR SUBQUERY EXPLOSION
-- Agent is asked: "Return customer summary with order count, lifetime spend, and last order details"
-- Agent generates multiple independent scalar subqueries in SELECT:
SELECT
    c.id,
    c.name,
    (SELECT COUNT(*) FROM orders o WHERE o.customer_id = c.id) AS total_orders,
    (SELECT COALESCE(SUM(total_amount), 0) FROM orders o WHERE o.customer_id = c.id) AS lifetime_value,
    (SELECT created_at FROM orders o WHERE o.customer_id = c.id ORDER BY created_at DESC LIMIT 1) AS last_order_at,
    (SELECT status FROM orders o WHERE o.customer_id = c.id ORDER BY created_at DESC LIMIT 1) AS last_order_status
FROM customers c
WHERE c.organization_id = $1;

-- ❌ Catastrophe:
-- For 5,000 customers in the organization, PostgreSQL executes 4 separate index traversals per row:
-- 5,000 * 4 = 20,000 independent subquery evaluations!
-- Identical index pages are fetched and pinned repeatedly, thrashing shared_buffers and CPU cache lines.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: THE MISSING LEFT JOIN LATERAL GHOST ROW DELETION
-- Agent attempts to use LATERAL for Top-1 order, but uses CROSS JOIN LATERAL:
SELECT c.id, c.name, latest_order.id AS order_id, latest_order.total_amount
FROM customers c
CROSS JOIN LATERAL (
    SELECT o.id, o.total_amount
    FROM orders o
    WHERE o.customer_id = c.id
    ORDER BY o.created_at DESC
    LIMIT 1
) latest_order;

-- ❌ Catastrophe:
-- CROSS JOIN LATERAL has INNER JOIN semantics!
-- Any customer who has registered but NOT YET placed an order produces ZERO rows in latest_order.
-- The CROSS JOIN completely drops the customer from the result set!
-- Customer counts, onboarded users lists, and CRM dashboards silently lose valid records!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: THE UNINDEXED NESTED LOOP CARTESIAN APOCALYPSE
-- Agent correctly writes LATERAL join, but fails to verify or create the composite index:
SELECT c.id, c.name, o.id, o.amount
FROM categories c
CROSS JOIN LATERAL (
    SELECT id, amount
    FROM products p
    WHERE p.category_id = c.id AND p.is_available = true
    ORDER BY p.sales_rank ASC
    LIMIT 5
) o;
-- No index on products(category_id, is_available, sales_rank ASC)!

-- ❌ Catastrophe:
-- The query planner chooses a Nested Loop. For each of 500 categories,
-- PostgreSQL executes a sequential scan of products (2,000,000 rows):
-- Total rows inspected: 500 * 2,000,000 = 1,000,000,000 tuples!
-- Query locks backend CPU for 120 seconds, triggering statement timeouts.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: ARRAY / JSONB CARTESIAN MULTIPLICATION NIGHTMARE
-- Agent attempts to unnest JSONB tags array and join with user attributes:
SELECT u.id, u.name, jsonb_array_elements_text(u.metadata->'tags') AS tag, a.login_count
FROM users u, user_activity a
WHERE a.user_id = u.id;

-- ❌ Catastrophe:
-- Invoking set-returning functions in SELECT list alongside multi-table joins produces
-- indeterminate Cartesian products and violates SQL standard relation projections.
-- Furthermore, if metadata->'tags' is empty or NULL, users disappear without LEFT JOIN LATERAL.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: REPEATED COMPUTED EXPRESSION CHURN
-- Agent calculates haversine distance or complex tax calculation:
SELECT
    id, name,
    (6371 * acos(cos(radians($1)) * cos(radians(lat)) * cos(radians(lng) - radians($2)) + sin(radians($1)) * sin(radians(lat)))) AS distance_km
FROM stores
WHERE (6371 * acos(cos(radians($1)) * cos(radians(lat)) * cos(radians(lng) - radians($2)) + sin(radians($1)) * sin(radians(lat)))) < 50
ORDER BY (6371 * acos(cos(radians($1)) * cos(radians(lat)) * cos(radians(lng) - radians($2)) + sin(radians($1)) * sin(radians(lat)))) ASC;

-- ❌ Catastrophe:
-- Agent duplicates the identical mathematical expression 3 times (SELECT, WHERE, ORDER BY).
-- Without LATERAL aliasing, PostgreSQL may evaluate the expensive trigonometric function
-- 3 separate times per row, doubling CPU cycle consumption.
```

---

### The 5-Tier LATERAL Join Governance Ladder

To eliminate these failures, autonomous agents must adhere to the 5-Tier LATERAL Join Governance Ladder:

| Tier | Name | Target Use Case | Performance & Integrity Invariant |
| :--- | :--- | :--- | :--- |
| **Tier 0** | **Scalar Expression Factoring (`CROSS JOIN LATERAL (VALUES (...))`)** | Complex formulas, JSON extractions, date truncations reused across clauses | Evaluate expensive expressions exactly once per row. Expose clean column alias to `SELECT`, `WHERE`, `GROUP BY`, and `ORDER BY` with zero CTE overhead. |
| **Tier 1** | **Index-Seek Per-Group Top-$K$ (`CROSS JOIN LATERAL ... LIMIT K`)** | "Top 3 comments per post", "Latest 5 transactions per account" | Mandatory composite index `(group_fk, sort_col DESC)`. Replaces $O(N \log N)$ full-table window functions with $O(G \cdot K \log N)$ index seeks. Drops latency from 45,000ms to 2ms. |
| **Tier 2** | **Null-Preserving Correlation (`LEFT JOIN LATERAL ... ON true`)** | Parent-child relations where parent must survive zero children; multi-metric consolidation | Mandate `LEFT JOIN LATERAL ... ON true`. Consolidates $M$ scalar subqueries into a single lateral evaluation without dropping zero-child parents. |
| **Tier 3** | **Set-Returning Function Relational Expansion (`LATERAL unnest(...) WITH ORDINALITY`)** | Unnesting arrays, `jsonb_array_elements`, `jsonb_to_recordset` | Must use `CROSS JOIN LATERAL` or `LEFT JOIN LATERAL` with `WITH ORDINALITY` to maintain deterministic row ordering and isolate set expansion from outer Cartesian traps. |
| **Tier 4** | **Adaptive Recursive Skip-Scan / Distinct Group Traversal** | Emulating Loose Index Scan across high-cardinality foreign keys on unpartitioned tables | Pair Recursive CTE with `CROSS JOIN LATERAL` to perform B-Tree root-to-leaf skipping, avoiding full index scans when retrieving distinct keys. |

---

## 2. Mathematical Foundations & Execution Engine Physics

Understanding why LATERAL joins dramatically outperform window functions and scalar subqueries requires analyzing database physical execution engine cost models.

### Asymptotic Complexity Comparison: Window Functions vs LATERAL Joins for Top-$K$ per Group

Let:
- $N$ = Total rows in the child relation ($|R_{\text{child}}|$), e.g., 50,000,000 orders.
- $G$ = Number of qualifying parent groups ($|R_{\text{parent}}|$), e.g., 10,000 active customers.
- $K$ = Number of requested items per group, e.g., 3.
- $h$ = Height of the B-Tree index on the child table ($h = \lceil \log_B N \rceil \approx 3 - 4$).

#### 1. Naive Window Function Approach (`ROW_NUMBER() OVER (PARTITION BY ...)`):
To compute `ROW_NUMBER()`, the executor cannot inspect the outer filter $G$ or the inner filter $K$ during scan time because the window frame covers the entire partitioned relation:
$$C_{\text{window}} = C_{\text{SeqScan}}(N) + C_{\text{Sort}}(N \log N) + C_{\text{WindowAgg}}(N) + C_{\text{Filter}}(N)$$
- **I/O Complexity**: $O(N)$ sequential or index page reads.
- **CPU Complexity**: $O(N \log N)$ comparison operations for sorting.
- **Memory Footprint**: $O(N)$ tuples buffered in `work_mem`. If $N \cdot \text{tuple\_size} > \text{work\_mem}$, Postgres spills to disk run files via external merge sort, multiplying disk I/O by $2 \times \lceil \log_{M} (N/M) \rceil$.

#### 2. Indexed LATERAL Join Approach (`CROSS JOIN LATERAL (SELECT ... LIMIT K)`):
With a composite B-Tree index `(customer_id, created_at DESC)` on the child table:
$$C_{\text{lateral}} = C_{\text{Scan}}(G) + \sum_{i=1}^{G} \left[ C_{\text{BTreeSeek}}(h) + K \cdot C_{\text{LeafTupleFetch}} \right]$$
$$C_{\text{lateral}} = O(G) + O(G \cdot (h + K)) = O(G \cdot (\log N + K))$$
- **I/O Complexity**: Exactly $G$ index root-to-leaf traversals and $G \cdot K$ index leaf tuple fetches.
- **CPU Complexity**: Zero full-table sorting! $O(G \cdot K)$ tuples processed.
- **Memory Footprint**: $O(K)$ tuples in working memory (constant $O(1)$ relative to $N$).

#### Quantitative Speedup Theorem:
$$\text{Speedup Ratio } S = \frac{C_{\text{window}}}{C_{\text{lateral}}} \approx \frac{N \log N}{G \cdot (\log N + K)}$$
For $N = 50,000,000$, $G = 10,000$, $K = 3$, and $\log_2(5 \cdot 10^7) \approx 26$:
$$S \approx \frac{50,000,000 \times 26}{10,000 \times (26 + 3)} = \frac{1,300,000,000}{290,000} \approx 4,482 \times$$
The LATERAL join reduces total engine work by more than **4,400 times**, shrinking execution latency from **45 seconds** to **10 milliseconds**!

---

### Cost Formula for Correlated Scalar Subqueries vs Single Consolidating `LEFT JOIN LATERAL`

When an agent executes $M$ scalar subqueries in `SELECT`:
$$\text{Cost}_{\text{scalar}} = G \times \sum_{j=1}^{M} \left( \text{Cost}_{\text{Seek}}(j) + \text{Cost}_{\text{Eval}}(j) \right)$$
Each scalar subquery independently invokes the query executor, acquires buffer pins on index root pages, and checks transaction visibility.

With a single consolidated `LEFT JOIN LATERAL`:
$$\text{Cost}_{\text{lateral\_consolidated}} = G \times \left( \text{Cost}_{\text{Seek}}(1) + \text{Cost}_{\text{MultiAggregate}} \right)$$
By fetching child rows once per parent, the database engine computes `COUNT(*)`, `SUM(amount)`, `MAX(created_at)`, and `MIN(created_at)` in a single stream pass, reducing buffer pin operations by a factor of $M$.

---

## 3. Industrial Implementations Across Languages & Frameworks

### 1. PostgreSQL Native SQL Production Patterns

```sql
-- ============================================================================
-- PATTERN 1: Top-3 Items Per Category with Zero Full-Table Scans
-- Mandatory Index: CREATE INDEX idx_products_cat_sales ON products (category_id, sales_count DESC);
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    c.id AS category_id,
    c.name AS category_name,
    top_p.id AS product_id,
    top_p.name AS product_name,
    top_p.sales_count
FROM categories c
CROSS JOIN LATERAL (
    SELECT p.id, p.name, p.sales_count
    FROM products p
    WHERE p.category_id = c.id AND p.is_active = true
    ORDER BY p.sales_count DESC
    LIMIT 3
) top_p
WHERE c.is_visible = true;

-- ============================================================================
-- PATTERN 2: Null-Preserving Consolidating LEFT JOIN LATERAL (Replaces 4 Scalar Subqueries)
-- Mandatory Index: CREATE INDEX idx_orders_cust_created ON orders (customer_id, created_at DESC);
-- ============================================================================
SELECT
    c.id AS customer_id,
    c.email,
    COALESCE(stats.order_count, 0) AS total_orders,
    COALESCE(stats.lifetime_spend, 0.00) AS lifetime_spend,
    stats.last_order_at,
    stats.last_order_status
FROM customers c
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) AS order_count,
        SUM(o.total_amount) AS lifetime_spend,
        (ARRAY_AGG(o.created_at ORDER BY o.created_at DESC))[1] AS last_order_at,
        (ARRAY_AGG(o.status ORDER BY o.created_at DESC))[1] AS last_order_status
    FROM orders o
    WHERE o.customer_id = c.id
) stats ON true
WHERE c.organization_id = '018f3a2b-1000-7000-8000-000000000001'::uuid;

-- ============================================================================
-- PATTERN 3: Array & JSONB Unnesting with ORDINALITY (Safe Relational Expansion)
-- ============================================================================
SELECT
    u.id AS user_id,
    u.email,
    skill.idx AS skill_order,
    skill.name AS skill_name
FROM users u
CROSS JOIN LATERAL unnest(u.skills) WITH ORDINALITY AS skill(name, idx)
WHERE u.is_active = true
ORDER BY u.id, skill.idx ASC;

-- ============================================================================
-- PATTERN 4: Complex Computed Formula Factoring via LATERAL VALUES
-- Calculates expensive Geospatial Distance exactly ONCE per row
-- ============================================================================
SELECT
    s.id,
    s.name,
    geo.distance_km,
    geo.is_within_delivery_zone
FROM stores s
CROSS JOIN LATERAL (
    VALUES (
        (6371 * acos(
            least(1.0, greatest(-1.0,
                cos(radians(37.7749)) * cos(radians(s.latitude)) *
                cos(radians(s.longitude) - radians(-122.4194)) +
                sin(radians(37.7749)) * sin(radians(s.latitude))
            ))
        ))
    )
) AS calc(dist)
CROSS JOIN LATERAL (
    VALUES (
        round(calc.dist::numeric, 2),
        calc.dist <= s.delivery_radius_km
    )
) AS geo(distance_km, is_within_delivery_zone)
WHERE geo.is_within_delivery_zone = true
ORDER BY geo.distance_km ASC;
```

---

### 2. Go (`jackc/pgx/v5`): High-Throughput Top-K Customer Orders

```go
package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// CustomerTopOrder models a customer paired with their recent top orders.
type CustomerTopOrder struct {
	CustomerID   string    `json:"customer_id"`
	CustomerName string    `json:"customer_name"`
	OrderID      string    `json:"order_id"`
	TotalAmount  float64   `json:"total_amount"`
	CreatedAt    time.Time `json:"created_at"`
}

// FetchActiveCustomersTopOrders executes an index-driven LATERAL join to fetch
// the top K latest orders per customer with constant working memory and zero full-table sorts.
func FetchActiveCustomersTopOrders(
	ctx context.Context,
	pool *pgxpool.Pool,
	orgID string,
	topK int,
) ([]CustomerTopOrder, error) {
	if topK <= 0 || topK > 50 {
		topK = 5 // Guard against unconstrained memory allocation
	}

	// Invariant: Requires composite index on orders (customer_id, created_at DESC)
	// and index on customers (organization_id) WHERE is_active = true
	const lateralSQL = `
		SELECT
			c.id AS customer_id,
			c.name AS customer_name,
			o.id AS order_id,
			o.total_amount,
			o.created_at
		FROM customers c
		CROSS JOIN LATERAL (
			SELECT o.id, o.total_amount, o.created_at
			FROM orders o
			WHERE o.customer_id = c.id AND o.status != 'cancelled'
			ORDER BY o.created_at DESC
			LIMIT $2
		) o
		WHERE c.organization_id = $1 AND c.is_active = true
		ORDER BY c.name ASC, o.created_at DESC;
	`

	rows, err := pool.Query(ctx, lateralSQL, orgID, topK)
	if err != nil {
		return nil, fmt.Errorf("lateral query execution failed: %w", err)
	}
	defer rows.Close()

	var results []CustomerTopOrder
	for rows.Next() {
		var item CustomerTopOrder
		if err := rows.Scan(
			&item.CustomerID,
			&item.CustomerName,
			&item.OrderID,
			&item.TotalAmount,
			&item.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("failed scanning lateral row: %w", err)
		}
		results = append(results, item)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("row iteration error: %w", err)
	}

	return results, nil
}
```

---

### 3. TypeScript (`Kysely` & `Drizzle ORM`): Production Safe Lateral Join Patterns

```typescript
import { sql } from 'drizzle-orm';
import { pgTable, uuid, varchar, numeric, timestamp, boolean, index } from 'drizzle-orm/pg-core';
import type { PgDatabase } from 'drizzle-orm/pg-core';

// Drizzle Schema Definitions with Mandatory Composite Indexes
export const customers = pgTable('customers', {
  id: uuid('id').primaryKey().defaultRandom(),
  organizationId: uuid('organization_id').notNull(),
  name: varchar('name', { length: 255 }).notNull(),
  isActive: boolean('is_active').notNull().default(true),
});

export const orders = pgTable('orders', {
  id: uuid('id').primaryKey().defaultRandom(),
  customerId: uuid('customer_id').notNull().references(() => customers.id),
  totalAmount: numeric('total_amount', { precision: 12, scale: 2 }).notNull(),
  status: varchar('status', { length: 32 }).notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  // Mandatory composite index enabling Index Only / Index Seek inside LATERAL
  custCreatedIdx: index('idx_orders_customer_created').on(table.customerId, table.createdAt.desc()),
}));

export interface TopOrderRow {
  customerId: string;
  customerName: string;
  orderId: string | null;
  totalAmount: string | null;
  createdAt: Date | null;
}

/**
 * Executes a null-preserving LEFT JOIN LATERAL query using Drizzle SQL template literals.
 * Guarantees customers without orders are preserved while preventing full-table window scans.
 */
export async function getCustomersWithLatestTopOrders(
  db: PgDatabase<any>,
  organizationId: string,
  limitPerCustomer: number = 3
): Promise<TopOrderRow[]> {
  const safeLimit = Math.max(1, Math.min(limitPerCustomer, 20));

  const query = sql<TopOrderRow>`
    SELECT
      c.id AS "customerId",
      c.name AS "customerName",
      latest.id AS "orderId",
      latest.total_amount AS "totalAmount",
      latest.created_at AS "createdAt"
    FROM ${customers} c
    LEFT JOIN LATERAL (
      SELECT o.id, o.total_amount, o.created_at
      FROM ${orders} o
      WHERE o.customer_id = c.id AND o.status != 'cancelled'
      ORDER BY o.created_at DESC
      LIMIT ${safeLimit}
    ) latest ON true
    WHERE c.organization_id = ${organizationId} AND c.is_active = true
    ORDER BY c.name ASC, latest.created_at DESC NULLS LAST;
  `;

  const result = await db.execute(query);
  return result.rows as unknown as TopOrderRow[];
}
```

---

### 4. Python (`SQLAlchemy` 2.0 & `asyncpg`): Lateral Joins with Explicit Correlation

```python
import uuid
from typing import List, Optional
from pydantic import BaseModel
from sqlalchemy import (
    Column, String, Boolean, Numeric, DateTime, ForeignKey,
    Index, select, func, desc
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import declarative_base
from sqlalchemy.ext.asyncio import AsyncSession

Base = declarative_base()

class Customer(Base):
    __tablename__ = 'customers'
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), nullable=False, index=True)
    name = Column(String(255), nullable=False)
    is_active = Column(Boolean, nullable=False, default=True)

class Order(Base):
    __tablename__ = 'orders'
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id = Column(UUID(as_uuid=True), ForeignKey('customers.id'), nullable=False)
    total_amount = Column(Numeric(12, 2), nullable=False)
    status = Column(String(32), nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

    __table_args__ = (
        # Mandatory composite index for LATERAL seek optimization
        Index('idx_orders_customer_created_desc', 'customer_id', desc('created_at')),
    )

class CustomerOrderDTO(BaseModel):
    customer_id: uuid.UUID
    customer_name: str
    order_id: Optional[uuid.UUID]
    total_amount: Optional[float]

async def get_customers_with_top_orders_lateral(
    session: AsyncSession,
    org_id: uuid.UUID,
    top_k: int = 3
) -> List[CustomerOrderDTO]:
    """
    Constructs an index-backed LATERAL subquery via SQLAlchemy 2.0 select.lateral().
    Eliminates full-table window partition scans and prevents O(N log N) sorts.
    """
    safe_k = min(max(1, top_k), 20)

    # Correlated subquery with LIMIT K
    lateral_subquery = (
        select(Order.id, Order.total_amount, Order.created_at)
        .where(Order.customer_id == Customer.id)
        .where(Order.status != 'cancelled')
        .order_by(Order.created_at.desc())
        .limit(safe_k)
        .lateral("latest_orders")
    )

    # Null-preserving outer join
    stmt = (
        select(
            Customer.id.label("customer_id"),
            Customer.name.label("customer_name"),
            lateral_subquery.c.id.label("order_id"),
            lateral_subquery.c.total_amount.label("total_amount")
        )
        .outerjoin(lateral_subquery, True)
        .where(Customer.organization_id == org_id, Customer.is_active == True)
        .order_by(Customer.name.asc())
    )

    result = await session.execute(stmt)
    return [
        CustomerOrderDTO(
            customer_id=row.customer_id,
            customer_name=row.customer_name,
            order_id=row.order_id,
            total_amount=float(row.total_amount) if row.total_amount is not None else None
        )
        for row in result.all()
    ]
```

---

### 5. Rust (`sqlx`): Compile-Time Checked Index-Seek Lateral Joins

```rust
use sqlx::{PgPool, FromRow};
use uuid::Uuid;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;

#[derive(Debug, FromRow, serde::Serialize)]
pub struct CategoryTopProduct {
    pub category_id: Uuid,
    pub category_name: String,
    pub product_id: Option<Uuid>,
    pub product_name: Option<String>,
    pub price: Option<Decimal>,
    pub sales_count: Option<i32>,
}

/// Executes a compile-time checked LEFT JOIN LATERAL query using sqlx.
/// Retrieves top K products per category without window function memory overhead.
pub async fn fetch_categories_with_top_products(
    pool: &PgPool,
    tenant_id: Uuid,
    top_k: i64,
) -> Result<Vec<CategoryTopProduct>, sqlx::Error> {
    let safe_k = top_k.clamp(1, 20);

    let rows = sqlx::query_as!(
        CategoryTopProduct,
        r#"
        SELECT
            c.id AS category_id,
            c.name AS category_name,
            p.id AS product_id,
            p.name AS product_name,
            p.price AS price,
            p.sales_count AS sales_count
        FROM categories c
        LEFT JOIN LATERAL (
            SELECT prod.id, prod.name, prod.price, prod.sales_count
            FROM products prod
            WHERE prod.category_id = c.id AND prod.is_active = true
            ORDER BY prod.sales_count DESC
            LIMIT $2
        ) p ON true
        WHERE c.tenant_id = $1 AND c.is_visible = true
        ORDER BY c.name ASC, p.sales_count DESC NULLS LAST
        "#,
        tenant_id,
        safe_k
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}
```

---

## 4. Production TypeScript Guard Engine: `AgenticLateralJoinGuardEngine`

The following TypeScript static analysis engine inspects SQL statements, detects dangerous window function anti-patterns, flags missing index clauses, warns against missing `LEFT JOIN LATERAL` null dropped rows, and verifies expression deduplication:

```typescript
/**
 * AgenticLateralJoinGuardEngine
 * Static AST and semantic validator enforcing LATERAL join invariants,
 * per-group Top-K optimizations, and Cartesian product defense.
 */
export interface LateralAuditReport {
  hasViolations: boolean;
  score: number; // 0 - 100
  violations: Array<{
    code: string;
    severity: 'CRITICAL' | 'HIGH' | 'MEDIUM';
    message: string;
    remediation: string;
    line?: number;
  }>;
  suggestedIndexes: string[];
}

export class AgenticLateralJoinGuardEngine {
  /**
   * Audits raw SQL statements for LATERAL join and subquery patterns.
   */
  public static audit(sqlQuery: string): LateralAuditReport {
    const violations: LateralAuditReport['violations'] = [];
    const suggestedIndexes: string[] = [];
    const normalized = sqlQuery.replace(/\s+/g, ' ');

    // 1. Detect Window Function Partition Top-K Anti-Pattern
    // e.g., ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...) in CTE with rn <= K
    const windowTopKRegex = /ROW_NUMBER\s*\(\s*\)\s*OVER\s*\(\s*PARTITION\s+BY\s+([a-zA-Z0-9_.,\s]+)\s+ORDER\s+BY\s+([a-zA-Z0-9_.,\s]+)\)/i;
    const whereRnRegex = /WHERE\s+([a-zA-Z0-9_]+\.)?rn\s*(<=|<|=)\s*(\d+)/i;

    if (windowTopKRegex.test(normalized) && whereRnRegex.test(normalized)) {
      const match = normalized.match(windowTopKRegex);
      const partitionKeys = match ? match[1].trim() : 'partition_keys';
      const orderKeys = match ? match[2].trim() : 'order_keys';

      violations.push({
        code: 'WINDOW_FUNCTION_TOP_K_DETECTED',
        severity: 'CRITICAL',
        message: 'Query uses ROW_NUMBER() OVER (PARTITION BY ...) to filter Top-K rows. This forces a full-table scan and memory sort of all rows before discarding non-qualifying records.',
        remediation: `Refactor to CROSS JOIN LATERAL or LEFT JOIN LATERAL with subquery LIMIT K. Add composite index on (${partitionKeys}, ${orderKeys}).`,
      });

      suggestedIndexes.push(`CREATE INDEX idx_lateral_seek ON child_table (${partitionKeys}, ${orderKeys});`);
    }

    // 2. Proliferation of Correlated Scalar Subqueries in SELECT
    // Counts occurrences of (SELECT ... FROM ... WHERE ... = outer....) in the projection
    const scalarSubqueryRegex = /SELECT\b([\s\S]*?)\bFROM\b/i;
    const selectProjectionMatch = normalized.match(scalarSubqueryRegex);
    if (selectProjectionMatch) {
      const projection = selectProjectionMatch[1];
      const correlatedSubqueries = (projection.match(/\(\s*SELECT\b[\s\S]*?\bFROM\b/gi) || []).length;

      if (correlatedSubqueries >= 2) {
        violations.push({
          code: 'CORRELATED_SCALAR_SUBQUERY_PROLIFERATION',
          severity: 'HIGH',
          message: `Detected ${correlatedSubqueries} correlated scalar subqueries in SELECT projection. Each subquery executes an independent index scan per outer row, multiplying buffer reads by ${correlatedSubqueries}x.`,
          remediation: 'Consolidate multiple scalar subqueries into a single LEFT JOIN LATERAL (SELECT count(*), max(...) ... WHERE child.fk = parent.id) ON true.',
        });
      }
    }

    // 3. Danger of CROSS JOIN LATERAL Dropping Zero-Child Parents
    if (/\bCROSS\s+JOIN\s+LATERAL\b/i.test(normalized)) {
      // Check if the query appears to be querying an entity-relationship where outer entities could have 0 children
      if (!/WHERE[\s\S]*?\bLIMIT\s+1\b/i.test(normalized) && !/\bWITH\s+ORDINALITY\b/i.test(normalized)) {
        violations.push({
          code: 'CROSS_JOIN_LATERAL_NULL_LOSS_RISK',
          severity: 'HIGH',
          message: 'CROSS JOIN LATERAL has INNER JOIN semantics. Outer rows with zero matching inner rows will be silently dropped from the result set.',
          remediation: 'Replace CROSS JOIN LATERAL with LEFT JOIN LATERAL ... ON true unless dropping unmatched outer entities is mathematically desired.',
        });
      }
    }

    // 4. Repeated Computed Expression Detection
    // Checks if the same formula appears in SELECT, WHERE, and ORDER BY
    const formulaRegex = /\(([0-9.]+\s*[\*\+\-\/]\s*[a-zA-Z0-9_().,\s]+)\)/g;
    const formulas = normalized.match(formulaRegex);
    if (formulas && formulas.length >= 3) {
      const counts = new Map<string, number>();
      formulas.forEach((f) => counts.set(f, (counts.get(f) || 0) + 1));
      for (const [formula, count] of counts.entries()) {
        if (count >= 2 && formula.length > 25) {
          violations.push({
            code: 'REPEATED_COMPUTED_EXPRESSION',
            severity: 'MEDIUM',
            message: `Complex mathematical expression "${formula.slice(0, 40)}..." is repeated ${count} times across query clauses.`,
            remediation: 'Wrap the formula once in a CROSS JOIN LATERAL (VALUES (...)) AS calc(val) clause and reference calc.val downstream.',
          });
          break;
        }
      }
    }

    // 5. Unnesting Without ORDINALITY
    if (/\bLATERAL\s+unnest\s*\(/i.test(normalized) && !/\bWITH\s+ORDINALITY\b/i.test(normalized)) {
      violations.push({
        code: 'UNNEST_MISSING_ORDINALITY',
        severity: 'MEDIUM',
        message: 'Array unnesting via LATERAL without WITH ORDINALITY loses array element indices and deterministic ordering.',
        remediation: 'Append WITH ORDINALITY AS alias(element, idx) to preserve position metadata.',
      });
    }

    const score = Math.max(0, 100 - violations.reduce((acc, v) => {
      if (v.severity === 'CRITICAL') return acc + 40;
      if (v.severity === 'HIGH') return acc + 25;
      return acc + 10;
    }, 0));

    return {
      hasViolations: violations.length > 0,
      score,
      violations,
      suggestedIndexes,
    };
  }
}
```

---

## 5. LATERAL Query Execution Lifecycle Finite-State Machine (FSM)

The execution of a production-grade LATERAL query proceeds through a deterministic 6-state finite-state machine to prevent Cartesian explosion and unindexed nested loops:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│               LATERAL QUERY EXECUTION LIFECYCLE FINITE-STATE MACHINE         │
└─────────────────────────────────────────────────────────────────────────────┘

       [1. QUERY INTENT CLASSIFICATION]
         │ (Identify Top-K per group, correlated stats, or unnesting)
         ▼
       [2. CARDINALITY & OUTER BOUND ANALYSIS]
         │ Outer relation cardinality |G|: Bounded (<100K) or unbounded?
         │ Child relation cardinality |N|: Massive (>1M rows)?
         ▼
       [3. INDEX PREREQUISITE VERIFICATION] ───(Missing Index)──► [REJECT / WARN]
         │ Check for B-Tree index on (child.fk, child.sort_col DESC)
         │ Index exists?
         ▼ (Yes)
       [4. NULL-SAFETY EVALUATION]
         │ Does outer entity require preservation when child has 0 rows?
         ├─► YES: Enforce `LEFT JOIN LATERAL (...) ON true`
         └─► NO:  Allow `CROSS JOIN LATERAL (...)`
         ▼
       [5. BOUNDED LIMIT INJECTION]
         │ Ensure LATERAL subquery contains explicit `LIMIT K` parameter
         │ (K clamped to [1, 100])
         ▼
       [6. PLAN VERIFICATION & BUFFER MONITORING]
         │ EXPLAIN (ANALYZE, BUFFERS): Verify "Nested Loop" + "Index Scan"
         │ Confirm 0 temporary disk files generated
         ▼
       [EXECUTION COMPLETE / METRICS LOGGED]
```

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

Autonomous agents must pass every gate in this verification matrix before submitting any PR or migration containing LATERAL or grouped Top-K queries:

| Gate | Verification Check | Command / Validation Regex | Expected Result |
| :--- | :--- | :--- | :--- |
| **Gate 1: Top-K Window Elimination** | No `ROW_NUMBER() OVER (PARTITION BY ...)` in Top-K queries | `! grep -ri "ROW_NUMBER().*PARTITION BY.*ORDER BY" src/ internal/` | 0 occurrences where filtered by `<= K`; refactored to LATERAL |
| **Gate 2: Composite Index Alignment** | Verify existence of composite index on `(foreign_key, sort_column DESC)` | `grep -E "CREATE INDEX.*ON.*\(.*,.*DESC\)" migrations/` | Composite index present matching LATERAL correlation & order |
| **Gate 3: Null Preservation Safety** | Check whether outer entities can have 0 children | Verify `LEFT JOIN LATERAL ... ON true` used for parent-child listings | Zero dropped parent entities in edge-case tests |
| **Gate 4: Bounded Limit Enforcement** | Subquery contains explicit clamped parameter | `grep -E "LIMIT\s+(\$[0-9]+|\:[a-zA-Z0-9_]+|[0-9]+)"` | Subquery strictly limits retrieved tuples ($K \le 100$) |
| **Gate 5: ORDINALITY on Unnest** | Array unnesting includes `WITH ORDINALITY` | `grep -E "unnest\(.*\)\s+WITH\s+ORDINALITY"` | Element position deterministically preserved |
| **Gate 6: Zero Disk Spill Proof** | Verify query execution plan in staging | `EXPLAIN (ANALYZE, BUFFERS) <query>` | `Sort Method: quicksort` or Index Scan only; `Disk: 0 bytes` |

---

## 7. Summary: Autonomous Agent Quick Reference Card

```sql
-- ❌ NEVER DO THIS: Window function scanning 50,000,000 rows for Top-3 per category
WITH r AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY cat_id ORDER BY created_at DESC) AS rn
    FROM items
) SELECT * FROM r WHERE rn <= 3;

-- ✅ ALWAYS DO THIS: Index-seek LATERAL retrieving only 3 rows per category in milliseconds
SELECT c.id, c.name, top_i.*
FROM categories c
LEFT JOIN LATERAL (
    SELECT i.id, i.name, i.price, i.created_at
    FROM items i
    WHERE i.cat_id = c.id AND i.is_active = true
    ORDER BY i.created_at DESC
    LIMIT 3
) top_i ON true
WHERE c.is_visible = true;

-- Required Index for O(G * K log N) execution:
CREATE INDEX idx_items_cat_created ON items (cat_id, created_at DESC) WHERE is_active = true;
```
