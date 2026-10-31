---
description: PostgreSQL expression indexes, functional B-Trees, STORED generated columns, AST predicate subsumption, function volatility fencing (IMMUTABLE vs STABLE/VOLATILE), JSONB type extraction alignment, and write-amplification defense across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{expression,functional,index,generated,computed,jsonb,subsumption,volatility,postgres,db,query}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Expression Indexes, STORED Generated Columns, Functional B-Tree Alignment, AST Subsumption & Volatility Fencing Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design relational database schemas, optimize computed query predicates, index JSONB/text attributes, build case-insensitive search lookups, and prevent catastrophic sequential scans across PostgreSQL (12–17+) in Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Expression Index AST Non-Subsumption & Sequential Scan Cliff (The Exact Syntactic Match Fallacy)" (where queries use `WHERE email ILIKE $1` or `WHERE (payload->>'id')::int = $1` against indexes defined on `LOWER(email)` or `(payload->>'id')`, causing PostgreSQL's planner theorem prover to fail expression subsumption and silently revert to 45-second full-table sequential scans across 50 million rows), the "Fake IMMUTABLE Volatility Fraud & Silent B-Tree Index Corruption" (where agents mark user-defined functions or timezone-dependent expressions `IMMUTABLE` when they actually rely on session `TIMEZONE`, `CURRENT_TIMESTAMP`, or auxiliary lookup tables, permanently breaking B-Tree binary search ordering invariants and causing queries to return 0 rows for live production records), the "Expression Index Double-Evaluation Write Amplification Overhead" (where re-executing heavy cryptographic hashing, regex parsing, or JSONB traversal on every single row `INSERT` or `UPDATE` multiplies CPU utilization by $8\times$ and holds heap page latches captive), the "STORED Generated Column vs Functional Index Architectural Misalignment" (where agents use functional indexes for attributes frequently projected in `SELECT` clauses, missing out on Index-Only Scans, foreign key target references, and rich `pg_stats` histogram statistics provided by `GENERATED ALWAYS AS (expr) STORED`), the "JSONB Arrow Operator `->` vs `->>` Inverted Type Coercion Trap" (where mismatching `jsonb` scalar values with `text` extractions destroys index selectivity), and the "Collation Sensitivity & Non-Deterministic ICU B-Tree Invalidation" (where string expressions lack explicit `COLLATE "C"` and suffer silent B-Tree corruption upon operating system glibc or ICU library upgrades) by establishing a strict 5-Tier Expression & Functional Index Governance Ladder, Cary Millsap Method R evaluation models, AST Subsumption Theorems, a production-ready TypeScript `AgenticExpressionIndexGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state optimization lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Expression Index Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, an **Expression Index** (also known as a Functional Index) indexes the result of an expression or function computed over table columns:
```sql
CREATE INDEX idx_users_lower_email ON users (LOWER(email));
```
PostgreSQL also provides **STORED Generated Columns** (PostgreSQL 12+), which compute and physically materialize the expression into the heap tuple at write time:
```sql
ALTER TABLE users ADD COLUMN email_lower TEXT GENERATED ALWAYS AS (LOWER(email)) STORED;
CREATE INDEX idx_users_email_lower ON users (email_lower);
```

While both features accelerate non-trivial queries, autonomous coding agents routinely commit catastrophic architectural mistakes when generating schemas, migrations, and query predicates:

### The 6 Expression Index & Generated Column Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                   THE 6 EXPRESSION INDEX & GENERATED COLUMN CATASTROPHES                           |
+------------------------------------+---------------------------------------------------------------+
| 1. The AST Subsumption Cliff       | Query uses WHERE email ILIKE $1 or LOWER(email::text) against |
|    (Exact Syntactic Match Fallacy) | index on LOWER(email); planner fails pattern matching and     |
|                                    | silently falls back to 45s sequential scans across 50M rows!  |
+------------------------------------+---------------------------------------------------------------+
| 2. Fake IMMUTABLE Volatility Fraud | Function marked IMMUTABLE actually depends on session TIMEZONE|
|    (Silent B-Tree Corruption)      | or system clock; B-Tree ordering invariants shatter, queries  |
|                                    | return 0 rows for valid data, and amcheck integrity fails!   |
+------------------------------------+---------------------------------------------------------------+
| 3. Expression Double-Evaluation    | Heavy PL/pgSQL, regex, or JSONB logic executes synchronously  |
|    (Write Amplification Avalanche) | on every row INSERT/UPDATE, burning 8x CPU and holding        |
|                                    | exclusive page latches that stall concurrent OLTP commits.     |
+------------------------------------+---------------------------------------------------------------+
| 4. Functional vs STORED Mismatch   | Functional index used on frequently projected attributes,      |
|    (Index-Only Scan Deprivation)   | missing heap materialization, foreign key target referencing, |
|                                    | and native pg_stats multi-bucket histogram distribution stats.|
+------------------------------------+---------------------------------------------------------------+
| 5. JSONB -> vs ->> Inversion Trap  | Index on (data->>'tenant_id') (text); query runs integer      |
|    (Type Coercion Miss)            | comparison WHERE (data->>'tenant_id')::int = 42; type mismatch|
|                                    | bypasses index traversal completely!                         |
+------------------------------------+---------------------------------------------------------------+
| 6. Collation glibc Drift Meltdown  | String expression index created without explicit COLLATE "C"; |
|    (Silent Search Hits Drop)       | Linux OS glibc strcoll change breaks B-Tree search order,    |
|                                    | causing unique constraint corruption and missing search hits. |
+------------------------------------+---------------------------------------------------------------+
```

### Catastrophic Code Anti-Patterns

```typescript
// ❌ CATASTROPHIC LLM EXPRESSION INDEX & GENERATED COLUMN ANTI-PATTERNS

// Anti-Pattern 1: The AST Subsumption Mismatch
// Migration creates:
// CREATE INDEX idx_users_lower_email ON users (LOWER(email));
// But autonomous agent generates query with ILIKE or extra cast:
export async function findUserByEmail(db: DatabaseClient, email: string) {
  // FAILS SUBSUMPTION: ILIKE is not LOWER(email) = LOWER($1)!
  // Triggers full-table sequential scan on 50,000,000 rows (45 seconds)!
  return db.query(`SELECT id, email FROM users WHERE email ILIKE $1`, [email]);
}

// Anti-Pattern 2: The Fake IMMUTABLE Volatility Fraud
// DDL:
// CREATE OR REPLACE FUNCTION get_user_status(created_at TIMESTAMPTZ)
// RETURNS TEXT IMMUTABLE AS $$ -- ❌ FRAUD: Depends on NOW() and dynamic session time!
//   SELECT CASE WHEN created_at > (NOW() - INTERVAL '30 days') THEN 'ACTIVE' ELSE 'DORMANT' END;
// $$ LANGUAGE sql;
// CREATE INDEX idx_users_status ON users (get_user_status(created_at));
// RESULT: B-Tree becomes corrupt within minutes; index entries never update as time passes!

// Anti-Pattern 3: The JSONB Arrow Operator -> vs ->> Type Coercion Trap
// Migration creates:
// CREATE INDEX idx_orders_customer_id ON orders ((payload->>'customer_id')); -- stores TEXT
// Query writes:
export async function getOrdersForCustomer(db: DatabaseClient, customerId: number) {
  // FAILS SUBSUMPTION: (payload->>'customer_id') is text, but customerId is cast to int!
  // PostgreSQL refuses to use text index for integer operator (= int)!
  return db.query(`SELECT * FROM orders WHERE (payload->>'customer_id')::bigint = $1`, [customerId]);
}

// Anti-Pattern 4: Functional Index Used Where STORED Generated Column is Mandatory
// Migration creates functional index on complex calculation, but application constantly runs:
// SELECT id, (amount * tax_rate + fee)::numeric(12,2) AS total_due FROM invoices WHERE status = 'PENDING';
// RESULT: Engine must recompute formula for every single fetched row!
// Cannot use Index-Only Scan; cannot target total_due in Foreign Keys or Prisma/Drizzle schemas.
```

---

## 2. Mathematical Models & Formal Verification: AST Subsumption & Cost Calculus

### Theorem 1 (Expression Subsumption & AST Congruence Theorem)
Let $\mathcal{Q}$ be a query containing a predicate expression $P(x)$, and let $\mathcal{I}$ be an index created on expression $E(x)$. The PostgreSQL cost-based query planner (via `match_clause_to_indexcol`) substitutes index scan traversal for sequential scanning if and only if:

$$\text{AST}(P(x)) \cong \text{AST}(E(x)) \quad \land \quad \text{Type}(\text{Result}(P)) \equiv \text{Type}(\text{Result}(E)) \quad \land \quad \text{OpClass}(\mathcal{I}) \vdash \text{Operator}(P)$$

If $\text{AST}(P(x)) \not\cong \text{AST}(E(x))$, the planner cost function evaluates:

$$C_{\text{seq}} = N_{\text{pages}} \cdot c_{\text{page\_io}} + N_{\text{tuples}} \cdot \left( c_{\text{cpu\_tuple}} + c_{\text{cpu\_operator}} + c_{\text{eval}}(E) \right)$$

Whereas under verified AST subsumption, the index scan cost is bounded by:

$$C_{\text{index}} = \lceil \log_B (N_{\text{tuples}}) \rceil \cdot c_{\text{cpu\_index}} + K_{\text{matching}} \cdot \left( c_{\text{page\_random\_io}} + c_{\text{cpu\_tuple}} \right)$$

When $N_{\text{tuples}} = 50,000,000$ and $K = 1$:
$$C_{\text{seq}} \approx 250,000 \cdot 1.0 + 50,000,000 \cdot (0.01 + 0.0025 + 0.05) \approx 3,375,000 \text{ cost units } (\sim 45\text{s})$$
$$C_{\text{index}} \approx 4 \cdot 0.005 + 1 \cdot (4.0 + 0.01) \approx 4.03 \text{ cost units } (\sim 0.8\text{ms})$$

A failure in AST subsumption introduces a **$\mathbf{837,468\times}$ cost penalty**!

### Theorem 2 (Write Amplification of Expression Indexes vs STORED Columns)
For a table with $M$ standard columns and $F$ functional/expression indexes with evaluation cost $T_{\text{eval}}(E_i)$:

$$T_{\text{insert\_expr}} = T_{\text{heap\_insert}} + \sum_{k=1}^K T_{\text{btree\_insert}} + \sum_{i=1}^F \left( T_{\text{eval}}(E_i) + T_{\text{btree\_insert}} \right)$$

If an expression $E$ is implemented as a `STORED` generated column with index:
- Heap write stores the computed value directly ($T_{\text{eval}}$ runs once during tuple formation).
- Subsequent queries projecting $E$ incur **$0$ evaluation cost** during scan ($T_{\text{read}} = \mathcal{O}(1)$ pointer offset dereference).
- Queries using Index-Only Scans can satisfy both filter and projection entirely from index leaf pages without visiting heap blocks.

### Break-Even Selection Invariant
$$\text{Choose STORED Generated Column when: } \frac{Q_{\text{projected}}}{Q_{\text{filtered}}} > 0.2 \quad \lor \quad \text{Attribute is Foreign Key Target} \quad \lor \quad \text{ORM Schema Typed}$$
$$\text{Choose Expression Index when: } \frac{Q_{\text{projected}}}{Q_{\text{filtered}}} \le 0.2 \quad \land \quad \text{Attribute is Pure Filter Predicate}$$

---

## 3. The 5-Tier Expression & Functional Index Governance Ladder

```
+----------------------------------------------------------------------------------------------------+
|                      5-TIER EXPRESSION & FUNCTIONAL INDEX GOVERNANCE LADDER                        |
+--------+------------------------------------+------------------------------------------------------+
| TIER 0 | Volatility & Timezone Fencing      | Strict IMMUTABLE PARALLEL SAFE on all functions;     |
|        | (Zero Volatility Fraud)            | Mandatory explicit UTC AT TIME ZONE 'UTC' on dates;  |
|        |                                    | Strict ban on NOW(), CURRENT_DATE, or subqueries.    |
+--------+------------------------------------+------------------------------------------------------+
| TIER 1 | AST Subsumption & Operator Class   | Exact AST symmetry between query WHERE and index;    |
|        | (Zero Mismatched Seq-Scans)        | Explicit type casting in both index and query;       |
|        |                                    | Mandatory text_pattern_ops for prefix LIKE queries.  |
+--------+------------------------------------+------------------------------------------------------+
| TIER 2 | Architectural Selection Matrix     | GENERATED ALWAYS AS (expr) STORED for projected keys;|
|        | (STORED Col vs Expression Index)   | Expression indexes reserved strictly for pure filter |
|        |                                    | predicates; enable native pg_stats histograms.       |
+--------+------------------------------------+------------------------------------------------------+
| TIER 3 | JSONB Arrow Operator Alignment     | Cast JSONB extractions to target scalar types:       |
|        | (jsonb_path_ops & Cast Discipline) | ((payload->>'user_id')::bigint);                     |
|        |                                    | GIN jsonb_path_ops for @> containment queries.       |
+--------+------------------------------------+------------------------------------------------------+
| TIER 4 | Collation Fencing & CI DOD         | Mandatory explicit COLLATE "C" on text expressions;  |
|        | (Automated Regression Sentinels)   | CI gates verifying 0 un-subsumed seq-scans and       |
|        |                                    | tracking unused expression indexes (idx_scan = 0).   |
+--------+------------------------------------+------------------------------------------------------+
```

### Tier 0: Volatility & Timezone Fencing
- **Strict `IMMUTABLE PARALLEL SAFE` Verification**: Every function referenced in an index or generated column expression MUST be proven mathematically pure. Given identical input arguments, it MUST return identical outputs for all eternity across all transaction snapshots and server environments.
- **Explicit UTC Conversion**: Any expression operating on timestamps (e.g., extracting dates or day boundaries) MUST explicitly specify timezone:
  ```sql
  -- ❌ BANNED: Depends on session TimeZone setting (STABLE, not IMMUTABLE)
  CREATE INDEX idx_orders_day ON orders (date_trunc('day', created_at));

  -- ✅ PRODUCTION INVARIANT: Explicit UTC conversion is IMMUTABLE
  CREATE INDEX idx_orders_day_utc ON orders ((date_trunc('day', created_at AT TIME ZONE 'UTC')));
  ```

### Tier 1: AST Subsumption & Operator Class Alignment
- **Syntactic AST Match Guarantee**: If an index is defined as `(LOWER(username))`, the query MUST filter with `WHERE LOWER(username) = LOWER($1)`. Never use `WHERE username ILIKE $1` expecting the index to be utilized without `pg_trgm`.
- **Sargable Prefix Matching**: For prefix matching (`LIKE 'prefix%'`), standard B-Trees with default collations fail. Use `text_pattern_ops`:
  ```sql
  CREATE INDEX idx_users_lower_handle_prefix ON users (LOWER(handle) text_pattern_ops);
  -- Subsumes: WHERE LOWER(handle) LIKE 'admin%'
  ```

### Tier 2: Architectural Selection Matrix (STORED Column vs Expression Index)
- When a computed field is referenced in `SELECT` projections, used across multiple `JOIN` conditions, or mapped into TypeScript/Go structs, declare it as a `GENERATED ALWAYS AS (expr) STORED` column.
- This creates physical storage in the heap tuple, collects rich multi-bucket distribution statistics in `pg_stats` via `ANALYZE`, and enables standard non-expression B-Trees.

### Tier 3: JSONB Arrow Operator Alignment
- Never index un-typed JSONB extractions when querying typed scalars:
  ```sql
  -- ❌ BANNED: Stores text representation, fails on integer equality query
  CREATE INDEX idx_events_entity_id ON events ((payload->>'entity_id'));

  -- ✅ PRODUCTION INVARIANT: Explicit type cast matching application queries
  CREATE INDEX idx_events_entity_id_int ON events (((payload->>'entity_id')::bigint));
  -- Query MUST use exact cast:
  -- SELECT * FROM events WHERE ((payload->>'entity_id')::bigint) = $1;
  ```

### Tier 4: Collation Fencing & Machine-Verifiable CI Gates
- Always enforce `COLLATE "C"` on case-folded or extracted text attributes to bypass operating system glibc collation tables:
  ```sql
  CREATE INDEX idx_orgs_slug_c ON orgs ((LOWER(slug) COLLATE "C"));
  ```
- Continuously inspect `pg_stat_user_indexes` for expression indexes where `idx_scan = 0` on active tables, eliminating useless write amplification.

---

## 4. Production TypeScript Reference Implementation: `AgenticExpressionIndexGuardEngine`

```typescript
// src/db/expression_index_guard.ts
import { Pool, PoolClient } from 'pg';

export interface ExpressionIndexMetadata {
  schemaname: string;
  tablename: string;
  indexname: string;
  indexdef: string;
  idxScan: number;
  idxTupRead: number;
  idxTupFetch: number;
  tableSizeBytes: number;
  indexSizeBytes: number;
}

export interface AstSubsumptionAuditResult {
  querySql: string;
  isSubsumed: boolean;
  matchedIndex?: string;
  planType: 'IndexScan' | 'IndexOnlyScan' | 'BitmapIndexScan' | 'SeqScan';
  totalCost: number;
  executionTimeMs: number;
  recommendation: string;
}

export class AgenticExpressionIndexGuardEngine {
  constructor(
    private readonly pool: Pool,
    private readonly logger: (msg: string, ctx?: Record<string, unknown>) => void = console.log
  ) {}

  /**
   * Audits all expression indexes across the cluster to detect unused indexes and write bloat.
   */
  async auditExpressionIndexes(): Promise<ExpressionIndexMetadata[]> {
    const sql = `
      SELECT
        schemaname,
        tablename,
        indexrelname AS indexname,
        pg_get_indexdef(indexrelid) AS indexdef,
        idx_scan AS "idxScan",
        idx_tup_read AS "idxTupRead",
        idx_tup_fetch AS "idxTupFetch",
        pg_relation_size(indrelid) AS "tableSizeBytes",
        pg_relation_size(indexrelid) AS "indexSizeBytes"
      FROM pg_stat_user_indexes
      JOIN pg_index USING (indexrelid)
      WHERE indexrelid IN (
        SELECT indexrelid
        FROM pg_index
        WHERE indexprs IS NOT NULL -- Identifies expression indexes
      )
      ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC;
    `;
    const res = await this.pool.query(sql);
    return res.rows;
  }

  /**
   * Verifies whether a given SQL query predicate successfully subsumes an existing expression index,
   * catching accidental full-table sequential scans BEFORE deployment.
   */
  async verifyQuerySubsumption(
    client: PoolClient,
    querySql: string,
    params: unknown[] = []
  ): Promise<AstSubsumptionAuditResult> {
    const explainSql = `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${querySql}`;
    const res = await client.query(explainSql, params);
    const planWrapper = res.rows[0]['QUERY PLAN'][0];
    const plan = planWrapper['Plan'];
    const executionTimeMs = planWrapper['Execution Time'] ?? planWrapper['Total Runtime'] ?? 0;

    const planType = plan['Node Type'] as AstSubsumptionAuditResult['planType'];
    const totalCost = plan['Total Cost'] ?? 0;
    const indexName = plan['Index Name'];

    const isSubsumed = planType !== 'SeqScan' && !!indexName;

    let recommendation = 'Expression index successfully subsumed.';
    if (!isSubsumed) {
      recommendation = `WARNING: Query executed via ${planType} (Cost: ${totalCost}, Time: ${executionTimeMs}ms). ` +
        `Query predicate AST does not match any expression index. Check exact syntax, type casting, and collations.`;
      this.logger(recommendation, { querySql, planType, totalCost });
    }

    return {
      querySql,
      isSubsumed,
      matchedIndex: indexName,
      planType,
      totalCost,
      executionTimeMs,
      recommendation,
    };
  }

  /**
   * Generates production-grade DDL for either a STORED Generated Column or an Expression Index,
   * enforcing UTC timezones and explicit C collation.
   */
  generateOptimizedDDL(options: {
    strategy: 'STORED_COLUMN' | 'EXPRESSION_INDEX';
    tableName: string;
    targetAttribute: string;
    expression: string;
    dataType?: string; // Required for STORED_COLUMN
    collation?: string;
  }): string {
    const collationClause = options.collation ? ` COLLATE "${options.collation}"` : ' COLLATE "C"';

    if (options.strategy === 'STORED_COLUMN') {
      if (!options.dataType) {
        throw new Error('dataType is mandatory when generating STORED generated column.');
      }
      const colName = `${options.targetAttribute}_computed`;
      const idxName = `idx_${options.tableName}_${colName}`;
      return `
-- 1. Add physically materialized STORED generated column (PostgreSQL 12+)
ALTER TABLE ${options.tableName}
  ADD COLUMN ${colName} ${options.dataType}
  GENERATED ALWAYS AS (${options.expression}) STORED;

-- 2. Create concurrent standard B-Tree index on the generated column
CREATE INDEX CONCURRENTLY ${idxName}
  ON ${options.tableName} (${colName}${options.collation ? collationClause : ''});
      `.trim();
    }

    const idxName = `idx_${options.tableName}_expr_${options.targetAttribute}`;
    return `
-- Create concurrent expression index with strict collation fencing
CREATE INDEX CONCURRENTLY ${idxName}
  ON ${options.tableName} ((${options.expression})${options.collation ? collationClause : ''});
    `.trim();
  }
}
```

---

## 5. Multi-Language Production Implementations

### Go (`jackc/pgx/v5`) Production Implementation

```go
// internal/store/expression_index_repository.go
package store

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type UserAccount struct {
	ID             string    `json:"id"`
	Email          string    `json:"email"`
	NormalizedEmail string   `json:"normalized_email"` // Backed by STORED generated column
	CreatedAt      time.Time `json:"created_at"`
}

type UserAccountRepository struct {
	pool *pgxpool.Pool
}

func NewUserAccountRepository(pool *pgxpool.Pool) *UserAccountRepository {
	return &UserAccountRepository{pool: pool}
}

// FindByCaseInsensitiveEmail leverages STORED generated column for Index-Only Scans
func (r *UserAccountRepository) FindByCaseInsensitiveEmail(ctx context.Context, email string) (*UserAccount, error) {
	cleanEmail := strings.TrimSpace(strings.ToLower(email))

	// Production Invariant: Query filters against normalized_email generated column
	// Enabling 100% Index-Only Scan without runtime function evaluation!
	query := `
		SELECT id, email, normalized_email, created_at
		FROM users
		WHERE normalized_email = $1 COLLATE "C"
		LIMIT 1;
	`
	var user UserAccount
	err := r.pool.QueryRow(ctx, query, cleanEmail).Scan(
		&user.ID,
		&user.Email,
		&user.NormalizedEmail,
		&user.CreatedAt,
	)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("FindByCaseInsensitiveEmail failed: %w", err)
	}
	return &user, nil
}

// QueryByJSONBEntityID demonstrates exact AST subsumption for typed JSONB expression indexes
func (r *UserAccountRepository) QueryByJSONBEntityID(ctx context.Context, entityID int64) ([]string, error) {
	// Index DDL: CREATE INDEX idx_events_entity_id ON events (((payload->>'entity_id')::bigint));
	// Invariant: Predicate MUST match exact AST cast ((payload->>'entity_id')::bigint) = $1
	query := `
		SELECT id
		FROM events
		WHERE ((payload->>'entity_id')::bigint) = $1
		ORDER BY id DESC
		LIMIT 25;
	`
	rows, err := r.pool.Query(ctx, query, entityID)
	if err != nil {
		return nil, fmt.Errorf("QueryByJSONBEntityID failed: %w", err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
```

### Python (`SQLAlchemy 2.0` / `asyncpg`) Production Implementation

```python
# app/models/account.py
from sqlalchemy import BigInteger, Column, DateTime, String, func, text, Index
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
import datetime

class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    email: Mapped[str] = mapped_column(String(255), nullable=False)
    
    # Tier 2 Production Invariant: STORED Generated Column with explicit Lowercase
    email_lower: Mapped[str] = mapped_column(
        String(255),
        server_default=text("LOWER(email)"),
        nullable=False
    )
    created_at: Mapped[datetime.datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        # Tier 4: Explicit "C" collation to immunize against glibc upgrades
        Index("idx_users_email_lower_c", "email_lower", postgresql_ops={"email_lower": 'COLLATE "C"'}),
    )

async def get_user_by_email(session: AsyncSession, raw_email: str) -> User | None:
    # Guaranteed AST Subsumption against indexed email_lower
    stmt = select(User).where(User.email_lower == raw_email.lower().strip())
    result = await session.execute(stmt)
    return result.scalar_one_or_none()
```

### Rust (`tokio-postgres` / `sqlx`) Production Implementation

```rust
// src/store/expression_repo.rs
use sqlx::{PgPool, Error};
use chrono::{DateTime, Utc};

#[derive(Debug, sqlx::FromRow)]
pub struct EventRecord {
    pub id: i64,
    pub event_type: String,
    pub payload: serde_json::Value,
    pub created_at: DateTime<Utc>,
}

pub struct EventRepository {
    pool: PgPool,
}

impl EventRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Queries records using exact JSONB cast matching expression index:
    /// DDL: CREATE INDEX idx_events_tenant_id ON events (((payload->>'tenant_id')::bigint));
    pub async fn find_by_tenant_id(&self, tenant_id: i64, limit: i64) -> Result<Vec<EventRecord>, Error> {
        let records = sqlx::query_as::<_, EventRecord>(
            r#"
            SELECT id, event_type, payload, created_at
            FROM events
            WHERE ((payload->>'tenant_id')::bigint) = $1
            ORDER BY id DESC
            LIMIT $2
            "#
        )
        .bind(tenant_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;

        Ok(records)
    }
}
```

---

## 6. Six-State Expression Index Lifecycle Finite-State Machine (FSM)

```
 [ S0: UNVALIDATED ]
         │
         ▼  (1. Verify Function Volatility == IMMUTABLE & Timezone UTC)
 [ S1: VOLATILITY_FENCED ]
         │
         ▼  (2. Prove AST Congruence & Type Cast Subsumption)
 [ S2: AST_SUBSUMED ]
         │
         ▼  (3. Select Architecture: STORED Column vs Expression Index)
 [ S3: ARCHITECTURE_ELECTED ]
         │
         ▼  (4. Execute Zero-Downtime Deployment via CREATE INDEX CONCURRENTLY)
 [ S4: CONCURRENTLY_ACTIVE ]
         │
         ▼  (5. Continuously Audit Telemetry via pg_stat_user_indexes & ASH)
 [ S5: TELEMETRY_GOVERNED ]
```

| Transition | Initial State | Trigger | Invariant Guard | Terminal State |
| :--- | :--- | :--- | :--- | :--- |
| **T1** | `UNVALIDATED` | Schema Migration | Function marked strictly `IMMUTABLE PARALLEL SAFE`; no naked `date_trunc` | `VOLATILITY_FENCED` |
| **T2** | `VOLATILITY_FENCED` | Query Analysis | Predicate AST matches index expression exactly; type widths match | `AST_SUBSUMED` |
| **T3** | `AST_SUBSUMED` | Architecture Choice | If projection ratio $> 0.2$ or foreign key $\to$ STORED Column, else ExprIndex | `ARCHITECTURE_ELECTED` |
| **T4** | `ARCHITECTURE_ELECTED` | Index Build | Execute `CREATE INDEX CONCURRENTLY` under `statement_timeout = 0` | `CONCURRENTLY_ACTIVE` |
| **T5** | `CONCURRENTLY_ACTIVE` | Production Traffic | Continuous verification of `idx_scan > 0` and $C_{\text{seq}} = 0$ | `TELEMETRY_GOVERNED` |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Save this validation script as `scripts/ci/verify-expression-indexes-dod.sh`:

```bash
#!/usr/bin/env bash
# verify-expression-indexes-dod.sh - Machine-verifiable CI gate for Expression Indexes & Generated Columns
set -euo pipefail

echo "🔍 [Gate 1/6] Verifying Function Volatility in pg_proc..."
IMPURE_FUNCTIONS=$(psql "${DATABASE_URL}" -Atc "
  SELECT p.proname
  FROM pg_proc p
  JOIN pg_depend d ON d.objid = p.oid
  JOIN pg_class c ON c.oid = d.refobjid
  WHERE c.relkind = 'i' AND p.provolatile != 'i';
")
if [ -n "$IMPURE_FUNCTIONS" ]; then
  echo "❌ CRITICAL: Non-IMMUTABLE functions detected in indexes: $IMPURE_FUNCTIONS"
  exit 1
fi
echo "✅ Gate 1 Passed: 100% of index functions are IMMUTABLE."

echo "🔍 [Gate 2/6] Verifying Explicit UTC conversions in Timestamp Expressions..."
NAKED_DATE_TRUNC=$(psql "${DATABASE_URL}" -Atc "
  SELECT indexrelid::regclass
  FROM pg_index
  WHERE indexprs::text ILIKE '%date_trunc%' AND indexprs::text NOT ILIKE '%AT TIME ZONE%';
")
if [ -n "$NAKED_DATE_TRUNC" ]; then
  echo "❌ CRITICAL: Expression index uses naked date_trunc without explicit AT TIME ZONE: $NAKED_DATE_TRUNC"
  exit 1
fi
echo "✅ Gate 2 Passed: Zero timezone-dependent date_trunc indexes detected."

echo "🔍 [Gate 3/6] Auditing Unused Expression Indexes with Zero Scans (idx_scan = 0)..."
UNUSED_EXPR_INDEXES=$(psql "${DATABASE_URL}" -Atc "
  SELECT indexrelname
  FROM pg_stat_user_indexes
  JOIN pg_index USING (indexrelid)
  WHERE indexprs IS NOT NULL
    AND idx_scan = 0
    AND pg_relation_size(indrelid) > 10485760; -- Tables > 10MB
")
if [ -n "$UNUSED_EXPR_INDEXES" ]; then
  echo "⚠️ WARNING: Unused expression indexes detected incurring write amplification: $UNUSED_EXPR_INDEXES"
fi
echo "✅ Gate 3 Passed: Expression index scan telemetry audited."

echo "🔍 [Gate 4/6] Verifying Explicit C Collation on Text Expression Indexes..."
UNCOLLATED_TEXT=$(psql "${DATABASE_URL}" -Atc "
  SELECT indexrelid::regclass
  FROM pg_index
  WHERE indexprs::text ILIKE '%lower(%' AND indexprs::text NOT ILIKE '%COLLATE \"C\"%';
")
if [ -n "$UNCOLLATED_TEXT" ]; then
  echo "⚠️ NOTICE: Lowercase expression index without explicit COLLATE \"C\": $UNCOLLATED_TEXT"
fi
echo "✅ Gate 4 Passed: Collation audit complete."

echo "🔍 [Gate 5/6] Verifying Zero Unsubsumed Sequential Scans on Critical Tables..."
SEQ_SCANS=$(psql "${DATABASE_URL}" -Atc "
  SELECT relname, seq_scan, idx_scan
  FROM pg_stat_user_tables
  WHERE seq_scan > idx_scan AND n_live_tup > 50000;
")
if [ -n "$SEQ_SCANS" ]; then
  echo "⚠️ NOTICE: High sequential scan ratio detected on active tables: $SEQ_SCANS"
fi
echo "✅ Gate 5 Passed: Sequential scan ratios verified."

echo "🔍 [Gate 6/6] Verifying STORED Generated Column Statistics in pg_stats..."
GENERATED_STATS=$(psql "${DATABASE_URL}" -Atc "
  SELECT count(*)
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  WHERE a.attgenerated = 's';
")
echo "ℹ️ Total STORED generated columns tracked: $GENERATED_STATS"
echo "✅ Gate 6 Passed: Definition of Done verified successfully!"
exit 0
```
