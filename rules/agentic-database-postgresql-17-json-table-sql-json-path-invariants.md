---
description: PostgreSQL 17 SQL/JSON standard JSON_TABLE, JSON_QUERY, JSON_VALUE, JSON_EXISTS, strict vs lax path expressions, nested path projection, jsonb_path_ops GIN indexing, TOAST decompression defense, and error-handling invariants across Go (pgx), TypeScript (pg/Drizzle), Python (asyncpg), Rust (sqlx), Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{json,jsonb,json_table,jsonpath,sql_json,document,relational,projection,toast}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/database/**/*.{ts,js,go,rs,py},**/lib/db/**/*.{ts,js,go,rs,py},**/internal/database/**/*.{go,rs},**/migrations/**/*.{sql,ts,py,go},**/queries/**/*.{sql,ts,go,rs,py}
alwaysApply: false
---

# Agentic Database PostgreSQL 17 JSON_TABLE, SQL/JSON Standard, JSON Path & Relational Projection Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, optimize, or migrate semi-structured document transformations, polymorphic event projections, nested JSON API integrations, or real-time JSON analytics across PostgreSQL 17+, Go (`jackc/pgx/v5`), TypeScript (`pg`, `Drizzle`, `Kysely`, `Prisma`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Legacy `CROSS JOIN LATERAL jsonb_array_elements` Cartesian Explosion & RAM Spill Trap" (where unnesting nested JSON arrays with lateral joins generates massive intermediate tuple streams, spilling uncompressed JSON chunks to temporary files on disk and slowing analytical queries by $20\times–50\times$), the "`JSON_TABLE` Silent Data Truncation & Null Coercion Trap (`ON ERROR EMPTY / NULL` vs `ON ERROR ERROR`)" (where defaulting error clauses silently transform JSON syntax anomalies, type mismatch violations, missing mandatory keys, or numeric overflow into `NULL` or dropped rows, leading to silent data corruption in accounting ledgers and ETL pipelines), the "Semantic Drift & Implicit Array Flattening Ambiguity: `lax` vs `strict` Mode" (where implicit scalar unwrapping and silent singleton array conversions in `lax` mode produce phantom duplicate or missing records, whereas `strict` mode enforces deterministic structural integrity), the "Multi-Branch `NESTED PATH` Combinatorial Multiplication Disaster" (where misconfigured sibling `NESTED PATH` clauses inadvertently synthesize multi-million row Cartesian cross-products instead of aligned relational projections), the "Unindexed JSON Path Evaluation & Full Table Sequential Scan Catastrophe" (where agents execute SQL/JSON path queries assuming generic B-Trees accelerate them, forcing PostgreSQL to perform 100% full sequential scans with CPU-intensive on-the-fly JSON parsing across millions of rows), and the "TOAST Out-of-Line Memory Thrashing & Unbounded Subtree Projection Memory Bloat" (where queries project multi-megabyte intermediate JSON subtrees into memory rather than narrow scalar primitives, blowing L1/L2 CPU caches and triggering Linux OOM-killer `SIGKILL 137` postmaster decapitations) by establishing a strict 5-Tier SQL/JSON Governance Ladder, formal relational unnesting and memory complexity differential models, an autonomous TypeScript `AgenticPostgres17JsonTableGuardEngine`, cross-runtime driver sentinels in Go, TypeScript, Python, and Rust, a 6-state projection lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 SQL/JSON Catastrophes vs The 5-Tier Governance Ladder

For over a decade, developers and autonomous AI agents processing semi-structured JSON documents in PostgreSQL were forced to rely on non-standard, fragmented procedural functions:
- `jsonb_to_recordset()` and `jsonb_to_record()` requiring fragile, repetitive column definition lists (`AS (id int, name text, ...)`) that fail dynamically on mismatched schemas.
- `CROSS JOIN LATERAL jsonb_array_elements()` and `jsonb_array_elements_text()` chains that force PostgreSQL's executor into nested-loop scans, generating combinatorial intermediate row copies that allocate memory in unmonitored `MemoryContexts` and spill megabytes of unindexed varlena buffers to scratch disks.
- Ad-hoc arrow operators (`->`, `->>`) and `#>` path traversals that lack standard type coercion, structural error handling, and ordinal sequence tracking.

PostgreSQL 17 achieved a historic milestone by implementing the full **ISO/IEC 9075 SQL:2023 SQL/JSON standard**, headlined by the high-performance native table function **`JSON_TABLE`**, alongside constructors (`JSON`, `JSON_ARRAY`, `JSON_OBJECT`) and standard query functions (`JSON_QUERY`, `JSON_VALUE`, `JSON_EXISTS`). 

`JSON_TABLE` enables database engines to evaluate SQL/JSON path expressions directly against JSONB binaries in a single execution pass, decomposing hierarchical trees into fully typed relational columns with inline ordinal sequences (`FOR ORDINALITY`), deterministic error bounds (`ERROR ON ERROR`), fallback defaults (`DEFAULT ... ON EMPTY`), and multi-level branch unwrapping (`NESTED PATH`).

However, when autonomous coding agents adopt PostgreSQL 17 SQL/JSON syntax without strict governance, they routinely trigger six critical production catastrophes:

```
+----------------------------------------------------------------------------------------------------+
|                         THE 6 POSTGRESQL 17 SQL/JSON & JSON_TABLE CATASTROPHES                     |
+----------------------------------------------------------------------------------------------------+
| 1. Legacy CROSS JOIN LATERAL Cartesian Explosion & RAM Spill Trap                                  |
|    - Agent chains multiple LATERAL jsonb_array_elements() to unnest nested items. The executor     |
|      materializes an O(N * M * K) Cartesian product, exceeding work_mem, creating temp disk files, |
|      and spiking CPU serialization latency by 35x.                                                |
|                                                                                                    |
| 2. JSON_TABLE Silent Data Truncation & Null Coercion Trap (EMPTY / NULL vs ERROR)                  |
|    - Agent leaves default ON ERROR NULL in JSON_TABLE column clauses. When incoming webhook JSON    |
|      contains schema drift (e.g. string "123.45" instead of number, or malformed UUID), the engine  |
|      silently converts the column to NULL, corrupting financial ledgers without throwing errors.   |
|                                                                                                    |
| 3. Semantic Drift & Implicit Array Flattening: lax vs strict Path Modes                            |
|    - Agent uses lax mode (default). A single scalar value matches an array path via auto-unwrapping |
|      or missing elements return empty instead of failing. Queries return unexpected partial rows,  |
|      destroying referential integrity across downstream analytics pipelines.                       |
|                                                                                                    |
| 4. Multi-Branch NESTED PATH Combinatorial Multiplication Disaster                                  |
|    - Agent defines parallel sibling NESTED PATH clauses (e.g. orders.discounts and orders.items)    |
|      without recognizing they execute as Cartesian joins when placed at the same nesting level,    |
|      multiplying item rows by discount rows and corrupting aggregate sums.                         |
|                                                                                                    |
| 5. Unindexed JSON Path Predicates & Full Table Scan (Seq Scan) Catastrophe                         |
|    - Agent filters queries using JSON_EXISTS(payload, '$.items[*] ? (@.sku == $1)') without        |
|      supporting jsonb_path_ops GIN indexes or functional B-Trees. The planner falls back to a     |
|      100% full sequential heap scan with CPU-intensive on-the-fly path parsing across 50M rows.   |
|                                                                                                    |
| 6. TOAST Out-of-Line Memory Thrashing & Unbounded Subtree Projection Bloat                         |
|    - JSON_TABLE projects large intermediate JSON subtrees (FORMAT JSON) into RAM rather than       |
|      extracting scalar primitives directly, causing repeated out-of-line TOAST decompressions      |
|      and exhausting backend MemoryContexts, triggering Linux OOM killer SIGKILL 137.               |
+----------------------------------------------------------------------------------------------------+
```

---

### The 5-Tier SQL/JSON Governance Ladder

To guarantee sub-millisecond execution, zero silent data corruption, and robust memory safety, autonomous agents must adhere strictly to the **5-Tier SQL/JSON Governance Ladder**:

```
+----------------------------------------------------------------------------------------------------+
|                              THE 5-TIER SQL/JSON GOVERNANCE LADDER                                 |
+----------------------------------------------------------------------------------------------------+
| Tier 0: Engine & Schema Qualification                                                              |
| - Assert PostgreSQL >= 17.0 (SELECT current_setting('server_version_num')::int >= 170000).        |
| - Verify underlying storage is binary JSONB with LZ4 compression (ALTER TABLE ... SET COMPRESSION).|
| - Enforce strict mode path expressions by default ('strict $.path') for transactional integrity.   |
+----------------------------------------------------------------------------------------------------+
| Tier 1: Deterministic Error Handling & Type Coercion Protocol                                      |
| - Mandate ERROR ON ERROR for all financial, identity, and foreign key relational projections.     |
| - For optional or polymorphic attributes, mandate explicit DEFAULT <literal> ON EMPTY / ERROR.     |
| - Ban unadorned column declarations that default silently to NULL ON ERROR.                        |
+----------------------------------------------------------------------------------------------------+
| Tier 2: Sargable Path Indexing & GIN Containment Synergy                                           |
| - Back JSON_EXISTS and path predicates with CREATE INDEX ... USING gin (payload jsonb_path_ops).   |
| - For high-frequency equality lookups on scalar path values, define functional B-Tree indexes:    |
|   CREATE INDEX ... ON t (((payload #>> '{customer_id}')::uuid)).                                  |
+----------------------------------------------------------------------------------------------------+
| Tier 3: Memory-Bounded Projection & Sibling NESTED PATH Alignment                                 |
| - Extract scalar primitives directly (int, numeric, text, uuid, timestamptz); ban FORMAT JSON      |
|   intermediate allocations unless the downstream consumer explicitly requires raw JSON chunks.    |
| - Disallow sibling NESTED PATH combinations that generate Cartesian multiplication; split into     |
|   independent JSON_TABLE calls or union projections.                                               |
| - Mandate FOR ORDINALITY on primary repeating arrays to preserve sequence order and row keys.     |
+----------------------------------------------------------------------------------------------------+
| Tier 4: Autonomous CI/CD Regression Gates & Automated Linting                                      |
| - Enforce AST linting verifying zero legacy CROSS JOIN LATERAL jsonb_array_elements in migrations. |
| - Automated EXPLAIN (ANALYZE, MEMORY) regression gates verifying zero disk scratch spills.        |
| - Definition of Done (DoD) machine-verifiable verification matrix in CI/CD pipelines.              |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. Mathematical Formulations & Latency / Memory Models

### 2.1. Relational Unnesting Complexity: Legacy Lateral Joins vs Single-Pass `JSON_TABLE`

Consider a table with $N$ rows, where each row contains a JSON document with $M$ nested entities (e.g., order line items), and each entity has $K$ child items (e.g., item options or discounts).

In legacy PostgreSQL unnesting via nested lateral loops:
$$T_{\text{lateral}}(N, M, K) = \sum_{i=1}^{N} \left( \tau_{\text{fetch}} + \tau_{\text{parse}}(S_i) + M \cdot \tau_{\text{unnest}} + M \cdot K \cdot (\tau_{\text{tuple\_alloc}} + \tau_{\text{context\_switch}}) \right)$$

Because each lateral function call (`jsonb_array_elements`) creates an independent iterator that reconstructs JSONB binary datums into intermediate memory tuples, the peak memory allocated during query execution scales with:
$$M_{\text{lateral\_peak}} = \mathcal{O}(N_{\text{batch}} \cdot M \cdot K \cdot \bar{S}_{\text{jsonb\_tuple}})$$

When $M_{\text{lateral\_peak}} > \text{work\_mem}$, the PostgreSQL executor is forced to materialize intermediate relation spools into temporary files on disk:
$$\text{DiskSpill}_{\text{lateral}} = M_{\text{lateral\_peak}} - \text{work\_mem}$$
Spilling to disk introduces NVMe block I/O write and read barriers, degrading query execution speed by a factor of $15\times$ to $50\times$.

In contrast, PostgreSQL 17's native **`JSON_TABLE`** performs single-pass streaming evaluation directly across the binary JSONB memory buffer:
$$T_{\text{json\_table}}(N, M, K) = \sum_{i=1}^{N} \left( \tau_{\text{fetch}} + \tau_{\text{decompress\_toast}}(S_i) + \tau_{\text{eval\_path}}(M \cdot K) + (M \cdot K) \cdot \tau_{\text{slot\_store}} \right)$$

Memory is allocated in a single transient `ExprContext` that is immediately reset per outer row:
$$M_{\text{json\_table\_peak}} = \mathcal{O}(\bar{S}_{\text{single\_row}} + \max(S_i)) \ll \text{work\_mem}$$

The acceleration factor achieved by transitioning from legacy lateral joins to native `JSON_TABLE` is modeled as:
$$\text{Speedup} = \frac{T_{\text{lateral}}}{T_{\text{json\_table}}} \approx \frac{M \cdot K \cdot \tau_{\text{tuple\_alloc}}}{\tau_{\text{eval\_path}} + \tau_{\text{slot\_store}}} \in [4.8, 42.6]$$

---

### 2.2. Error Coercion Hazard & Silent Data Loss Probability

When `JSON_TABLE` is invoked with permissive error clauses (`ON ERROR NULL` or `ON ERROR EMPTY`), incoming malformed datums are silently discarded or coerced. Let $X \sim \text{Bernoulli}(p_{\text{corrupt}})$ represent the arrival of a malformed or drift-affected JSON payload (e.g., numeric string `"NaN"`, out-of-range integer, invalid date string, or missing mandatory identity key):

$$P(\text{Silent Corruption} \mid \text{Permissive Error Clause}) = 1 - (1 - p_{\text{corrupt}})^B$$
where $B$ is the batch ingestion volume. In production workloads ingesting $B = 1,000,000$ events daily with even a minor schema drift rate $p_{\text{corrupt}} = 0.0001$ ($0.01\%$):
$$P(\text{Silent Corruption}) = 1 - (1 - 0.0001)^{1,000,000} \approx 1 - e^{-100} \approx 1.0 \quad (100\%)$$

By establishing **Tier 1 Invariant: Mandatory `ERROR ON ERROR` on Critical Relational Columns**, the silent corruption probability is mathematically bounded to zero:
$$P(\text{Silent Corruption} \mid \text{ERROR ON ERROR}) \equiv 0$$
Any schema drift immediately raises an auditable SQL exception, preventing corrupted accounting state from reaching downstream tables.

---

### 2.3. Path Mode Cardinality & Lax vs Strict Invariants

The SQL/JSON standard differentiates between `lax` mode and `strict` mode path evaluation:

| Feature | `lax` Mode (Default) | `strict` Mode (Mandatory Invariant) |
| :--- | :--- | :--- |
| **Array Auto-Unwrapping** | Automatically extracts elements from arrays if array accessor `[*]` is omitted: `$.items.price` walks into `$.items[*].price`. | Structural mismatch raises an immediate path error. Array accessors `[*]` must be explicit. |
| **Singleton Array Conversion** | A scalar primitive `100` is treated as a 1-element array `[100]` if queried with `[*]`. | Fails immediately: primitive cannot be subscripted as an array. |
| **Missing Object Keys** | Returns an empty sequence without error. | Returns an empty sequence unless queried in value extraction where type enforcement applies. |
| **Multiple Matches for Scalar Column** | Returns `NULL` or throws runtime error depending on column clause. | Explicitly governed: multiple matches violate scalar projection axioms. |

Under **Tier 0 Invariants**, autonomous agents MUST explicitly declare `strict` mode in all production JSON Path expressions:
$$\text{Path} \equiv \text{"strict \$\dots"}$$

This guarantees that deviations in upstream document structures fail immediately during continuous integration or schema ingestion rather than generating undefined query plans.

---

## 3. Autonomous TypeScript Guard Engine

Here is the complete production TypeScript implementation of the `AgenticPostgres17JsonTableGuardEngine`. It parses queries, analyzes legacy anti-patterns, audits `JSON_TABLE` syntax, enforces path mode discipline, validates error clauses, and generates automated migration transformations:

```typescript
/**
 * AgenticPostgres17JsonTableGuardEngine.ts
 * Production-grade AST & Query Inspector for PostgreSQL 17 SQL/JSON & JSON_TABLE.
 */

export interface SqlJsonViolation {
  ruleId: string;
  severity: 'CRITICAL' | 'HIGH' | 'MEDIUM';
  message: string;
  querySnippet: string;
  remediation: string;
}

export interface JsonTableAuditResult {
  valid: boolean;
  score: number; // 0 to 100
  violations: SqlJsonViolation[];
  suggestedSql?: string;
  recommendedIndexes: string[];
}

export interface JsonTableColumnDef {
  name: string;
  type: string;
  path: string;
  errorClause?: string;
  emptyClause?: string;
  isOrdinality?: boolean;
}

export class AgenticPostgres17JsonTableGuardEngine {
  private static readonly LEGACY_LATERAL_REGEX = 
    /cross\s+join\s+lateral\s+jsonb_array_elements(?:_text)?\s*\(([^)]+)\)/gi;

  private static readonly JSON_TABLE_REGEX = 
    /json_table\s*\(\s*([^,]+),\s*'(lax|strict)?\s*([^']+)'\s+columns\s*\(([\s\S]*?)\)\s*\)/gi;

  private static readonly SIBLING_NESTED_PATH_REGEX = 
    /nested\s+path\s+'([^']+)'\s+columns[\s\S]*?nested\s+path\s+'([^']+)'\s+columns/gi;

  /**
   * Evaluates SQL query strings or migration scripts against the 5-Tier SQL/JSON Ladder.
   */
  public static auditQuery(sql: string): JsonTableAuditResult {
    const violations: SqlJsonViolation[] = [];
    const recommendedIndexes: string[] = [];

    // 1. Detect Legacy CROSS JOIN LATERAL anti-patterns
    let lateralMatch: RegExpExecArray | null;
    const legacyMatches: string[] = [];
    while ((lateralMatch = this.LEGACY_LATERAL_REGEX.exec(sql)) !== null) {
      legacyMatches.push(lateralMatch[0]);
    }

    if (legacyMatches.length > 0) {
      violations.push({
        ruleId: 'SQLJSON-001',
        severity: 'CRITICAL',
        message: `Detected ${legacyMatches.length} legacy CROSS JOIN LATERAL jsonb_array_elements invocations. This triggers O(N*M) Cartesian memory allocation and temp file disk spills.`,
        querySnippet: legacyMatches.slice(0, 2).join('; '),
        remediation: 'Refactor using PostgreSQL 17 native JSON_TABLE() with explicit COLUMNS projection.'
      });
    }

    // 2. Audit Native JSON_TABLE invocations
    let jsonTableMatch: RegExpExecArray | null;
    let foundJsonTable = false;

    while ((jsonTableMatch = this.JSON_TABLE_REGEX.exec(sql)) !== null) {
      foundJsonTable = true;
      const [fullMatch, contextExpr, pathMode, rootPath, columnDefinitions] = jsonTableMatch;

      // 2a. Check Path Mode (strict vs lax)
      if (!pathMode || pathMode.toLowerCase() === 'lax') {
        violations.push({
          ruleId: 'SQLJSON-002',
          severity: 'HIGH',
          message: `JSON_TABLE path expression '${rootPath}' uses default 'lax' mode. Implicit array unwrapping and silent singleton conversions can lead to semantic drift and duplicate rows.`,
          querySnippet: fullMatch.slice(0, 80) + '...',
          remediation: `Prepend 'strict' to the path expression: 'strict ${rootPath}'`
        });
      }

      // 2b. Audit Column Definitions & Error Clauses
      const columns = this.parseColumns(columnDefinitions);
      let hasOrdinality = false;
      let unshieldedErrorColumns = 0;

      for (const col of columns) {
        if (col.isOrdinality) {
          hasOrdinality = true;
          continue;
        }

        // Critical columns (id, uuid, numeric, amounts) must enforce ERROR ON ERROR
        const isCriticalType = /(?:uuid|int(?:eger|8|4|2)?|numeric|decimal|boolean)/i.test(col.type);
        const hasErrorClause = col.errorClause && /error\s+on\s+error/i.test(col.errorClause);
        const hasEmptyClause = col.emptyClause && /(?:default|error|null)\s+on\s+empty/i.test(col.emptyClause);

        if (isCriticalType && !hasErrorClause) {
          unshieldedErrorColumns++;
          violations.push({
            ruleId: 'SQLJSON-003',
            severity: 'CRITICAL',
            message: `Column '${col.name}' of type '${col.type}' lacks explicit 'ERROR ON ERROR'. Default behavior converts type errors or missing attributes to NULL silently.`,
            querySnippet: `${col.name} ${col.type} PATH '${col.path}'`,
            remediation: `Append 'ERROR ON ERROR' to the column declaration: '${col.name} ${col.type} PATH \\'${col.path}\\' ERROR ON ERROR'`
          });
        }
      }

      // 2c. Check for Ordinality in unnesting arrays
      if (rootPath.includes('[*]') && !hasOrdinality) {
        violations.push({
          ruleId: 'SQLJSON-004',
          severity: 'MEDIUM',
          message: `JSON_TABLE unnesting array expression '${rootPath}' lacks a 'FOR ORDINALITY' column. Unindexed arrays cannot guarantee deterministic relational row ordering upon re-querying.`,
          querySnippet: fullMatch.slice(0, 80) + '...',
          remediation: `Add an integer sequence column: 'line_number FOR ORDINALITY' to the COLUMNS block.`
        });
      }

      // Index recommendations for filtered paths
      if (sql.includes('WHERE') || sql.includes('JOIN')) {
        recommendedIndexes.push(
          `CREATE INDEX IF NOT EXISTS idx_${this.sanitizeIdentifier(contextExpr)}_path_ops ON ${this.extractTableName(sql)} USING gin (${contextExpr.trim()} jsonb_path_ops);`
        );
      }
    }

    // 3. Audit Sibling NESTED PATH Combinatorial Multiplication
    let siblingMatch: RegExpExecArray | null;
    while ((siblingMatch = this.SIBLING_NESTED_PATH_REGEX.exec(sql)) !== null) {
      violations.push({
        ruleId: 'SQLJSON-005',
        severity: 'CRITICAL',
        message: `Detected sibling NESTED PATH clauses at the same structural level ('${siblingMatch[1]}' and '${siblingMatch[2]}'). In SQL/JSON, sibling nested paths evaluate as a Cartesian cross-product, multiplying row output and inflating aggregations.`,
        querySnippet: siblingMatch[0].slice(0, 100) + '...',
        remediation: 'Decompose parallel nested arrays into separate JSON_TABLE expressions or join on distinct ordinal sequence IDs.'
      });
    }

    // Calculate score based on violations
    let score = 100;
    for (const v of violations) {
      if (v.severity === 'CRITICAL') score -= 35;
      else if (v.severity === 'HIGH') score -= 15;
      else if (v.severity === 'MEDIUM') score -= 5;
    }
    score = Math.max(0, score);

    return {
      valid: violations.filter(v => v.severity === 'CRITICAL').length === 0,
      score,
      violations,
      recommendedIndexes: Array.from(new Set(recommendedIndexes))
    };
  }

  /**
   * Helper to parse comma-separated column definitions in JSON_TABLE COLUMNS block.
   */
  private static parseColumns(columnsText: string): JsonTableColumnDef[] {
    const results: JsonTableColumnDef[] = [];
    const rawTokens = columnsText.split(/,(?![^(]*\))/g);

    for (const token of rawTokens) {
      const clean = token.trim();
      if (!clean) continue;

      if (/for\s+ordinality/i.test(clean)) {
        const parts = clean.split(/\s+/);
        results.push({
          name: parts[0],
          type: 'integer',
          path: '',
          isOrdinality: true
        });
        continue;
      }

      // Match: name type PATH '...' [ERROR/EMPTY clauses]
      const colMatch = clean.match(/^([a-zA-Z0-9_]+)\s+([a-zA-Z0-9_()\[\]]+)(?:\s+PATH\s+'([^']+)')?(.*)$/i);
      if (colMatch) {
        const [, name, type, path, rest] = colMatch;
        let errorClause: string | undefined;
        let emptyClause: string | undefined;

        const errMatch = rest.match(/(?:error|null|default\s+[^)]+)\s+on\s+error/i);
        if (errMatch) errorClause = errMatch[0];

        const emptyMatch = rest.match(/(?:error|null|default\s+[^)]+)\s+on\s+empty/i);
        if (emptyMatch) emptyClause = emptyMatch[0];

        results.push({
          name,
          type,
          path: path || `$.${name}`,
          errorClause,
          emptyClause,
          isOrdinality: false
        });
      }
    }
    return results;
  }

  private static sanitizeIdentifier(id: string): string {
    return id.replace(/[^a-zA-Z0-9_]/g, '_').replace(/^_+|_+$/g, '');
  }

  private static extractTableName(sql: string): string {
    const fromMatch = sql.match(/FROM\s+([a-zA-Z0-9_."]+)/i);
    return fromMatch ? fromMatch[1] : 'target_table';
  }
}
```

---

## 4. Production Cross-Runtime Driver Sentinels

### 4.1. Go (`jackc/pgx/v5`) Production Sentinel

This Go service executes a governed PostgreSQL 17 `JSON_TABLE` query with strict path mode, ordinality ordering, error handling assertions, and telemetry:

```go
package database

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// OrderItemProjection represents a relational row extracted from a semi-structured JSON document
type OrderItemProjection struct {
	OrderID     uuid.UUID `json:"order_id"`
	LineNumber  int32     `json:"line_number"`
	SKU         string    `json:"sku"`
	Quantity    int32     `json:"quantity"`
	UnitPrice   float64   `json:"unit_price"`
	Currency    string    `json:"currency"`
	DiscountPct float64   `json:"discount_pct"`
}

type JsonTableQueryConfig struct {
	Pool        *pgxpool.Pool
	Logger      *slog.Logger
	BatchCutoff time.Time
	Limit       int
}

// FetchOrderItemsRelational executes governed PostgreSQL 17 JSON_TABLE relational extraction
func FetchOrderItemsRelational(ctx context.Context, cfg JsonTableQueryConfig) ([]OrderItemProjection, error) {
	if cfg.Pool == nil {
		return nil, errors.New("pgxpool pointer cannot be nil")
	}

	start := time.Now()

	// Strict SQL/JSON query:
	// 1. strict mode enforces schema integrity (no silent singleton array unwrapping)
	// 2. ERROR ON ERROR on numeric/scalar fields guarantees zero silent corruption
	// 3. DEFAULT 0.0 ON EMPTY handles optional discount gracefully
	// 4. FOR ORDINALITY guarantees stable line-item sorting
	const query = `
		SELECT 
			jt.order_id,
			jt.line_number,
			jt.sku,
			jt.quantity,
			jt.unit_price,
			jt.currency,
			jt.discount_pct
		FROM orders o,
		JSON_TABLE(
			o.payload,
			'strict $.orders[*]'
			COLUMNS (
				order_id     UUID             PATH '$.order_id' ERROR ON ERROR,
				line_number  FOR ORDINALITY,
				sku          TEXT             PATH '$.sku' ERROR ON ERROR,
				quantity     INT              PATH '$.quantity' ERROR ON ERROR,
				unit_price   NUMERIC(12, 4)   PATH '$.pricing.unit_price' ERROR ON ERROR,
				currency     VARCHAR(3)       PATH '$.pricing.currency' ERROR ON ERROR,
				discount_pct NUMERIC(5, 2)    PATH '$.pricing.discount_pct' 
				                                DEFAULT '0.00' ON EMPTY 
				                                ERROR ON ERROR
			)
		) AS jt
		WHERE o.created_at >= $1
		ORDER BY jt.order_id, jt.line_number
		LIMIT $2;
	`

	// Enforce 10-second query cancellation barrier
	queryCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	rows, err := cfg.Pool.Query(queryCtx, query, cfg.BatchCutoff, cfg.Limit)
	if err != nil {
		cfg.Logger.ErrorContext(ctx, "PostgreSQL 17 JSON_TABLE query execution failed",
			slog.String("error", err.Error()),
			slog.Time("cutoff", cfg.BatchCutoff),
		)
		return nil, fmt.Errorf("JSON_TABLE query error: %w", err)
	}
	defer rows.Close()

	var results []OrderItemProjection
	for rows.Next() {
		var item OrderItemProjection
		scanErr := rows.Scan(
			&item.OrderID,
			&item.LineNumber,
			&item.SKU,
			&item.Quantity,
			&item.UnitPrice,
			&item.Currency,
			&item.DiscountPct,
		)
		if scanErr != nil {
			return nil, fmt.Errorf("failed to scan JSON_TABLE projection tuple: %w", scanErr)
		}
		results = append(results, item)
	}

	if rows.Err() != nil {
		return nil, fmt.Errorf("row iteration error in JSON_TABLE: %w", rows.Err())
	}

	duration := time.Since(start)
	cfg.Logger.InfoContext(ctx, "JSON_TABLE projection completed successfully",
		slog.Int("rows_extracted", len(results)),
		slog.Duration("latency", duration),
		slog.Float64("tuples_per_ms", float64(len(results))/float64(duration.Milliseconds()+1)),
	)

	return results, nil
}
```

---

### 4.2. TypeScript (`pg` / `Drizzle`) Production Sentinel

This TypeScript driver implements end-to-end schema validation with `Zod`, transactional isolation, and PostgreSQL 17 `JSON_TABLE` projection:

```typescript
import { Pool, PoolClient } from 'pg';
import { z } from 'zod';

export const OrderItemSchema = z.object({
  orderId: z.string().uuid(),
  lineNumber: z.number().int().positive(),
  sku: z.string().min(1),
  quantity: z.number().int().positive(),
  unitPrice: z.number().positive(),
  currency: z.string().length(3),
  discountPct: z.number().min(0).max(100),
});

export type OrderItem = z.infer<typeof OrderItemSchema>;

export class Postgres17JsonTableService {
  constructor(private readonly pool: Pool) {}

  /**
   * Performs high-speed relational unnesting of JSONB documents using PG17 JSON_TABLE.
   */
  async extractOrderItems(since: Date, limit: number = 5000): Promise<OrderItem[]> {
    const client: PoolClient = await this.pool.connect();
    const startTime = performance.now();

    try {
      // Tier 0 & Tier 1 Enforced SQL
      const query = `
        SELECT 
          jt.order_id     AS "orderId",
          jt.line_number  AS "lineNumber",
          jt.sku          AS "sku",
          jt.quantity     AS "quantity",
          jt.unit_price   AS "unitPrice",
          jt.currency     AS "currency",
          jt.discount_pct AS "discountPct"
        FROM raw_order_events e,
        JSON_TABLE(
          e.document,
          'strict $.order.items[*]'
          COLUMNS (
            order_id     UUID           PATH '$.order_id' ERROR ON ERROR,
            line_number  FOR ORDINALITY,
            sku          TEXT           PATH '$.sku' ERROR ON ERROR,
            quantity     INT            PATH '$.qty' ERROR ON ERROR,
            unit_price   NUMERIC(10,2)  PATH '$.price' ERROR ON ERROR,
            currency     VARCHAR(3)     PATH '$.currency' ERROR ON ERROR,
            discount_pct NUMERIC(5,2)   PATH '$.discount' DEFAULT '0.00' ON EMPTY ERROR ON ERROR
          )
        ) AS jt
        WHERE e.ingested_at >= $1
        ORDER BY jt.order_id, jt.line_number
        LIMIT $2;
      `;

      const result = await client.query(query, [since, limit]);
      const latencyMs = performance.now() - startTime;

      // Runtime structural validation asserting zero null-coercion leaks
      const validated = z.array(OrderItemSchema).parse(result.rows);

      console.info(`[PG17 JSON_TABLE] Extracted ${validated.length} items in ${latencyMs.toFixed(2)}ms`);
      return validated;
    } catch (err: any) {
      console.error(`[PG17 JSON_TABLE FATAL] Relational projection failed: ${err.message}`);
      throw err;
    } finally {
      client.release();
    }
  }
}
```

---

### 4.3. Python (`asyncpg`) Production Sentinel

This Python module executes governed asynchronous SQL/JSON operations with telemetry and plan profiling:

```python
"""
PostgreSQL 17 SQL/JSON & JSON_TABLE asyncpg Sentinel.
"""
import asyncpy
import logging
import time
from typing import List, Dict, Any
from uuid import UUID

logger = logging.getLogger("db.sql_json")

async def query_json_table_metrics(
    conn: asyncpg.Connection, 
    account_id: UUID, 
    start_date: str
) -> List[Dict[str, Any]]:
    """
    Executes PostgreSQL 17 JSON_TABLE projection with strict error bounds.
    """
    t_start = time.perf_counter()
    
    sql = """
        SELECT 
            jt.txn_id,
            jt.seq_id,
            jt.category,
            jt.amount,
            jt.is_settled
        FROM account_audit_logs a,
        JSON_TABLE(
            a.event_payload,
            'strict $.ledger.entries[*]'
            COLUMNS (
                txn_id      UUID          PATH '$.id' ERROR ON ERROR,
                seq_id      FOR ORDINALITY,
                category    TEXT          PATH '$.meta.category' ERROR ON ERROR,
                amount      NUMERIC(14,2) PATH '$.amount' ERROR ON ERROR,
                is_settled  BOOLEAN       PATH '$.settled' DEFAULT 'false' ON EMPTY ERROR ON ERROR
            )
        ) AS jt
        WHERE a.account_id = $1 
          AND a.logged_at >= $2::timestamptz
        ORDER BY jt.txn_id, jt.seq_id;
    """
    
    try:
        rows = await conn.fetch(sql, account_id, start_date)
        duration_ms = (time.perf_counter() - t_start) * 1000.0
        
        logger.info(
            "PG17 JSON_TABLE extraction succeeded",
            extra={
                "row_count": len(rows),
                "duration_ms": duration_ms,
                "account_id": str(account_id)
            }
        )
        return [dict(r) for r in rows]
        
    except asyncpg.DataError as e:
        logger.critical(
            "JSON_TABLE data coercion violation: Schema drift detected in source payload",
            extra={"error": str(e), "account_id": str(account_id)}
        )
        raise
```

---

### 4.4. Rust (`sqlx`) Production Sentinel

This Rust module uses `sqlx` with compile-time checked queries and typed struct mappings:

```rust
use sqlx::{PgPool, FromRow};
use uuid::Uuid;
use chrono::{DateTime, Utc};
use std::time::Instant;

#[derive(Debug, FromRow)]
pub struct RelationalInvoiceItem {
    pub invoice_id: Uuid,
    pub item_ordinal: i32,
    pub product_code: String,
    pub quantity: i32,
    pub subtotal: rust_decimal::Decimal,
}

pub async fn extract_invoice_items(
    pool: &PgPool,
    cutoff: DateTime<Utc>,
    limit: i64,
) -> Result<Vec<RelationalInvoiceItem>, sqlx::Error> {
    let start = Instant::now();

    let rows = sqlx::query_as::<_, RelationalInvoiceItem>(
        r#"
        SELECT 
            jt.invoice_id,
            jt.item_ordinal,
            jt.product_code,
            jt.quantity,
            jt.subtotal
        FROM raw_invoices i,
        JSON_TABLE(
            i.json_doc,
            'strict $.invoice.line_items[*]'
            COLUMNS (
                invoice_id   UUID           PATH '$.header.uuid' ERROR ON ERROR,
                item_ordinal FOR ORDINALITY,
                product_code VARCHAR(32)    PATH '$.sku' ERROR ON ERROR,
                quantity     INT            PATH '$.qty' ERROR ON ERROR,
                subtotal     NUMERIC(12,2)  PATH '$.total' ERROR ON ERROR
            )
        ) AS jt
        WHERE i.received_at >= $1
        ORDER BY jt.invoice_id, jt.item_ordinal
        LIMIT $2
        "#,
    )
    .bind(cutoff)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    let elapsed = start.elapsed();
    tracing::info!(
        items_count = rows.len(),
        elapsed_us = elapsed.as_micros(),
        "PG17 JSON_TABLE unnesting complete"
    );

    Ok(rows)
}
```

---

## 5. Finite-State Machine (FSM) Lifecycle: SQL/JSON Query Execution

The lifecycle of a governed SQL/JSON projection query moves through six deterministic states:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          STATE 1: PRE-FLIGHT AUDIT                              │
│ - Validate server_version_num >= 170000.                                       │
│ - Assert query uses 'strict' path expressions.                                  │
│ - Verify zero legacy CROSS JOIN LATERAL jsonb_array_elements.                   │
└────────────────────────────────────────┬────────────────────────────────────────┘
                                         │ Pass
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                      STATE 2: PATH & INDEX VERIFICATION                         │
│ - Check pg_stat_user_indexes for jsonb_path_ops GIN or functional B-Trees.     │
│ - Assert query predicate pushdown avoids full sequential heap scans.            │
└────────────────────────────────────────┬────────────────────────────────────────┘
                                         │ Pass
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     STATE 3: TOAST & MEMORY BOUNDING                            │
│ - Verify scalar projections only (eliminate intermediate FORMAT JSON).          │
│ - Set statement_timeout and work_mem limits for analytical extractions.        │
└────────────────────────────────────────┬────────────────────────────────────────┘
                                         │ Execution
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                       STATE 4: STREAMING EVALUATION                             │
│ - Single-pass binary traversal across JSONB buffers.                            │
│ - FOR ORDINALITY sequence counter incrementation.                               │
└──────────────────┬───────────────────────────────────────────┬──────────────────┘
                   │ Malformed schema / type mismatch          │ All rows valid
                   ▼                                           ▼
┌──────────────────────────────────────┐  ┌───────────────────────────────────────┐
│       STATE 5: FAULT ISOLATION       │  │        STATE 6: DISPATCH & DoD        │
│ - ERROR ON ERROR triggers exception. │  │ - Relational rows emitted to client.  │
│ - Transaction aborts cleanly.        │  │ - Assert 0 null-coercion anomalies.   │
│ - Alert emitted to telemetry/SIEM.   │  │ - P99 query latency < 15ms verified.  │
└──────────────────────────────────────┘  └───────────────────────────────────────┘
```

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Gates Matrix

| Gate ID | Target Invariant | CI / Verification Mechanism | Pass Threshold | Fatal Violation Action |
| :--- | :--- | :--- | :--- | :--- |
| **DOD-JSON-01** | **PostgreSQL Version** | `SELECT current_setting('server_version_num')::int` | $\ge 170000$ | Halt pipeline. Reject deployment to PG $\le 16$. |
| **DOD-JSON-02** | **Zero Legacy Lateral Unnesting** | Ast Grep / Linter scanning migrations & repository queries | 0 instances of `CROSS JOIN LATERAL jsonb_array_elements` | Block PR merge. Force migration to `JSON_TABLE`. |
| **DOD-JSON-03** | **Strict Mode Invariant** | Regex validation on all JSON Path strings | 100% paths start with `'strict ...'` | Block CI. Flag `lax` mode as schema hazard. |
| **DOD-JSON-04** | **ERROR ON ERROR Enforcement** | `AgenticPostgres17JsonTableGuardEngine.auditQuery()` | 0 critical columns with default `NULL ON ERROR` | Reject migration. Append `ERROR ON ERROR`. |
| **DOD-JSON-05** | **Sibling NESTED PATH Prevention** | AST parse of `COLUMNS` clause | 0 sibling `NESTED PATH` clauses at same depth | Fail build. Decompose into distinct table functions. |
| **DOD-JSON-06** | **Ordinality Indexing** | Schema check on array unnesting projections | 100% of array unnestings declare `FOR ORDINALITY` | Warning flag in CI; required on ordered streams. |
| **DOD-JSON-07** | **Zero Disk Spill Assertion** | `EXPLAIN (ANALYZE, BUFFERS)` execution in test harness | `Temp written blocks == 0` | Fail test. Optimize `work_mem` or project fewer cols. |
| **DOD-JSON-08** | **Index Path Sargability** | `EXPLAIN (FORMAT JSON)` plan tree inspection | `Plan[0]["Node Type"] != "Seq Scan"` on filtered paths | Mandate `jsonb_path_ops` GIN index creation. |

---

## 7. Migration Runbook: Upgrading Legacy Lateral Unnesting to PostgreSQL 17 `JSON_TABLE`

When refactoring legacy codebases, follow this exact before-and-after template:

### ❌ The Legacy Anti-Pattern (Pre-PostgreSQL 17)
```sql
-- ❌ SLOW, CARTESIAN EXPLOSION, WORK_MEM DISK SPILLS, FRAGILE COLUMN LISTS
SELECT 
    e.id AS event_id,
    item.value->>'sku' AS sku,
    (item.value->>'qty')::int AS quantity,
    (item.value->'pricing'->>'price')::numeric AS unit_price,
    opt.value->>'option_name' AS option_name
FROM raw_orders e
CROSS JOIN LATERAL jsonb_array_elements(e.payload->'items') AS item
CROSS JOIN LATERAL jsonb_array_elements(item.value->'options') AS opt
WHERE e.created_at >= NOW() - INTERVAL '7 days';
```

### ✅ The Production Invariant (PostgreSQL 17+)
```sql
-- ✅ SINGLE-PASS BINARY PARSING, STREAMING EVALUATION, ZERO DISK SPILLS, ERROR GATED
SELECT 
    e.id AS event_id,
    jt.item_seq,
    jt.sku,
    jt.quantity,
    jt.unit_price,
    jt.option_seq,
    jt.option_name
FROM raw_orders e,
JSON_TABLE(
    e.payload,
    'strict $.items[*]'
    COLUMNS (
        item_seq   FOR ORDINALITY,
        sku        TEXT           PATH '$.sku' ERROR ON ERROR,
        quantity   INT            PATH '$.qty' ERROR ON ERROR,
        unit_price NUMERIC(10, 2) PATH '$.pricing.price' ERROR ON ERROR,
        NESTED PATH 'strict $.options[*]'
        COLUMNS (
            option_seq  FOR ORDINALITY,
            option_name TEXT PATH '$.option_name' ERROR ON ERROR
        )
    )
) AS jt
WHERE e.created_at >= NOW() - INTERVAL '7 days';
```
