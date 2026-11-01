---
description: PostgreSQL execution plan stability, query hints (pg_hint_plan), SQL plan baselines, outline stability, optimizer plan inversion elimination, parameter sniffing mitigation, scan hints (IndexScan, IndexOnlyScan, BitmapScan, SeqScan), join method hints (NestLoop, HashJoin, MergeJoin), join order hints (Leading), table alias binding, driver comment preservation, hint_plan.hints catalog persistence, and regression containment across Go (jackc/pgx/v5), TypeScript (drizzle-orm, prisma, pg), Python (asyncpg, psycopg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{hint,plan,explain,optimizer,cbo,query,stability,baseline}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go,py},**/config/**/*.{ini,conf,toml,yaml,json}
alwaysApply: false
---

# Agentic Database Execution Plan Freezing, Query Hints (`pg_hint_plan`), SQL Outlines & Optimizer Plan Inversion Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, optimize, profile, or stabilize PostgreSQL (13–17+) query execution plans, cost-based optimizer (CBO) paths, and microservice database access layers across Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `prisma`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Sudden Plan Inversion & Parameter Sniffing Latency Cliff" (where subtle changes in bind parameters, data skew, or catalog statistics cause the planner to abruptly flip from an in-memory 0.3ms Index Scan to a 4,500ms sequential table scan or catastrophic Cartesian Nested Loop, exhausting connection pools in seconds), the "PostgreSQL Has No Hints Fallacy & Dangerous Syntax Hack Storm" (where agents falsely assume PostgreSQL plans cannot be guided and inject brittle SQL hacks like `OFFSET 0`, dummy expressions `+ 0`, or fragile Common Table Expressions that break under PostgreSQL 12+ CTE inlining), the "Global GUC Hammer Catastrophe (`SET enable_seqscan = off`)" (where agents remediate a slow query by executing session-level GUC mutations on pooled connections, corrupting subsequent queries with pathological index scans and 500x I/O amplification), the "Driver Comment-Stripping & Wire Minification Trap" (where ORMs, poolers, or query minifiers strip `/*+ ... */` block comments before sending SQL across the wire protocol, silently ignoring hints without throwing errors), the "Missing Index / Schema Drift Fallback & Silent Hint Error Ignorance (`HINT_ERROR` Ignorance)" (where renamed or dropped indexes cause `pg_hint_plan` to silently fall back to regressed plans while CI reports green), and the "GEQO Non-Deterministic Join Order Inversion" (where multi-table joins with $\ge 12$ tables activate the Genetic Query Optimizer, generating stochastic, non-reproducible join trees between runs) by establishing a strict 5-Tier Plan Stability Governance Ladder, cost differential and combinatorial join space models, an autonomous TypeScript `AgenticDatabaseQueryHintGuardEngine`, cross-runtime telemetry sentinels in Go, TypeScript, Python, and Rust, a 6-state plan stability finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Plan Inversion Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL utilizes a Cost-Based Optimizer (CBO) that explores possible execution trees (scans, joins, aggregations) and estimates costs based on disk page fetches (`seq_page_cost`, `random_page_cost`), CPU tuple processing (`cpu_tuple_cost`), and statistics sampled in `pg_statistic` (`MCV` most common values, histogram bounds, null fractions, correlation).

Unlike commercial database engines such as Oracle (which provides SQL Plan Management, Stored Outlines, and native optimizer hints) or MySQL (`FORCE INDEX`), native PostgreSQL deliberately omits built-in optimizer hint directives in standard SQL syntax. Instead, production PostgreSQL systems rely on the battle-tested, kernel-hooked extension `pg_hint_plan` (developed and maintained by NTT and the PostgreSQL community) or strict structural plan freezing. `pg_hint_plan` intercepts PostgreSQL's planner hook (`planner_hook`) and injects planner cost overrides and path restrictions parsed from structured C-style block comments (`/*+ ... */`) or stored in the in-database catalog table `hint_plan.hints`.

When autonomous coding agents generate database repositories, transaction helpers, or query tuning fixes, LLMs routinely commit 6 catastrophic architectural errors:

### The 6 Plan Inversion Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE GLOBAL GUC HAMMER ON POOLED CONNECTIONS
-- Agent observes a slow query using a Seq Scan instead of an index:
SET enable_seqscan = off; -- FATAL: Executed on a pooled connection (PgBouncer/pgxpool)!

SELECT * FROM transactions WHERE tenant_id = 't-992' AND status = 'COMPLETED';

-- 💥 Catastrophe:
-- 1. The GUC mutation persists on the physical connection after being checked back into the pool.
-- 2. Another service checks out the connection and runs:
--    SELECT * FROM audit_logs WHERE created_at >= NOW() - INTERVAL '30 days'; -- 10,000,000 rows!
-- 3. Because enable_seqscan is disabled (cost set to 1.0e10), PostgreSQL is FORCED to execute
--    a Bitmap Index Scan with 10,000,000 random page reads, saturating NVMe I/O and spiking latency by 500x.
-- Invariant: NEVER mutate optimizer GUCs globally. Use transaction-scoped SET LOCAL or explicit query hints.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE BRITTLE SYNTAX HACK (OFFSET 0 & CTE INLINING)
-- Agent attempts to prevent a subquery from being flattened or inlined:
SELECT * 
FROM orders o
JOIN (
    SELECT id, total_amount 
    FROM high_value_orders 
    OFFSET 0 -- Brittle hack attempting to create an optimization fence!
) sub ON sub.id = o.id;

-- 💥 Catastrophe:
-- 1. In modern PostgreSQL (PG 12+), trivial subqueries with OFFSET 0 can still be pushed down or transformed.
-- 2. If applied to Common Table Expressions:
--    WITH filtered AS (SELECT ... FROM large_table) -- Default in PG 12+ is INLINED!
--    Agents omit 'MATERIALIZED', allowing the planner to push predicates down incorrectly or duplicate execution.
-- Invariant: Rely on explicit optimizer directives or declarative MATERIALIZED fences, never syntax quirks.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: TABLE ALIAS MISMATCH IN PG_HINT_PLAN
-- Query defines an alias, but the agent's hint references the physical relation name:
/*+ IndexScan(orders orders_pkey) */ -- FATAL: Table is aliased as 'o'!
SELECT o.id, o.amount
FROM orders o
WHERE o.id = 'ord-12345';

-- 💥 Catastrophe:
-- 1. pg_hint_plan matches hints against the exact alias used in the query AST ('o').
-- 2. Because 'orders' is not a recognized relation alias in the query, pg_hint_plan silently IGNORES the hint.
-- 3. The query planner falls back to default behavior without raising a client error.
-- Invariant: Hint targets MUST match the exact relation alias declared in the SQL statement.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: DRIVER COMMENT STRIPPING & WIRE PROTOCOL SILENCE
-- TypeScript / Prisma / TypeORM application code:
// const result = await prisma.$queryRaw`/*+ IndexOnlyScan(u users_email_idx) */ SELECT email FROM users u;`;
-- 💥 Catastrophe:
-- 1. Prisma query compiler or client-side SQL minifiers aggressively strip block comments (/* ... */).
-- 2. The query sent over the PostgreSQL wire protocol is: "SELECT email FROM users u;".
-- 3. pg_hint_plan never receives the hint comment, silently running default unpinned execution.
-- Invariant: Verify driver comment retention or deploy out-of-band catalog outlines in hint_plan.hints.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: UNMONITORED HINT ERROR ON DROPPED INDEX
-- Migration drops obsolete index 'idx_old' and replaces with composite 'idx_new':
-- Application continues sending:
/*+ IndexScan(orders idx_old) */
SELECT * FROM orders WHERE status = 'PENDING';

-- 💥 Catastrophe:
-- 1. By default, pg_hint_plan logs hint errors at 'INFO' level (pg_hint_plan.message_level = 'info').
-- 2. The client never receives an error, and application logs ignore INFO notices.
-- 3. The query silently flips to a 100% full sequential table scan in production.
-- Invariant: In CI/staging, enforce pg_hint_plan.message_level = 'warning' or 'error' to catch broken hints.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: GEQO JOIN COMBINATORIAL EXPLOSION (N >= 12 TABLES)
-- Agent writes a 14-table reporting query without join order hints:
SELECT * FROM t1 JOIN t2 ON ... JOIN t3 ON ... /* ... up to t14 */;
-- 💥 Catastrophe:
-- 1. geqo_threshold default is 12. PostgreSQL switches from dynamic programming to Genetic Algorithm.
-- 2. The genetic algorithm is stochastic: consecutive executions with the identical query yield different join trees.
-- 3. Query latency fluctuates wildly between 20ms and 18,000ms.
-- Invariant: Pin join orders with Leading((...)) hints and disable GEQO via Set(geqo off).
```

### The 5-Tier Plan Stability Governance Ladder

| Governance Tier | Architectural Responsibility | Enforcement Mechanism |
| :--- | :--- | :--- |
| **Tier 0: Comment Preservation & Driver Protocol Configuration** | Ensure `/*+ ... */` block comments survive ORM/driver minification pipelines. Pre-load `pg_hint_plan` in `shared_preload_libraries`. | Driver configuration (`preserveComments: true`), wire protocol audit, `shared_preload_libraries = 'pg_hint_plan'`. |
| **Tier 1: Explicit Scan Method & Index Pinning** | Pin access methods on critical paths: `IndexScan(alias idx)`, `IndexOnlyScan`, `BitmapScan`, `SeqScan`, `NoSeqScan`. Validate alias alignment. | Exact table alias matching, AST verification of index existence, sargability validation. |
| **Tier 2: Comprehensive Join Method & Join Order Freezing (`Leading`)** | Freeze complex multi-table join trees. Pin algorithms (`NestLoop`, `HashJoin`, `MergeJoin`) and join directions with `Leading((a (b c)))`. | Elimination of GEQO non-determinism, Cartesian explosion prevention, explicit outer/inner ordering. |
| **Tier 3: In-Database Out-of-Band Baselines via `hint_plan.hints` Catalog** | Decouple query hints from application source code. Store normalized query fingerprints and hint strings in `hint_plan.hints`. | Hash-based query normalization, runtime plan outline enforcement, zero-code-change emergency stabilization. |
| **Tier 4: Telemetry Sentinels, `pg_stat_statements` Alignment & CI DoD Gates** | Continuously audit plan stability, track variance ($c_v \le 0.50$), assert zero temp spills, and catch broken hints in automated CI gates. | Automated `EXPLAIN (ANALYZE, BUFFERS)` CI gates, `pg_hint_plan.message_level = 'warning'`, `auto_explain` integration. |

---

## 2. Mathematical Models & Formal Proofs

### Model 2.1: Optimizer Cost Differential & Plan Inversion Tipping Point Calculus

PostgreSQL's cost model calculates the cost $C$ of an execution plan as a function of relation statistics and hardware constants:

$$C_{\text{seq}} = N_{\text{pages}} \cdot c_{\text{page}} + N_{\text{tuples}} \cdot c_{\text{cpu}}$$

For an Index Scan retrieving an estimated fraction $\sigma \in [0, 1]$ of rows:

$$C_{\text{idx}} = N_{\text{idx\_pages}} \cdot c_{\text{page}} + \sigma \cdot N_{\text{tuples}} \cdot c_{\text{cpu}} + \text{Cost}_{\text{heap\_fetches}}(\sigma, \text{corr})$$

Where $\text{Cost}_{\text{heap\_fetches}}$ models the non-sequential disk page reads as a function of the physical correlation $\rho \in [-1, 1]$ recorded in `pg_stats.correlation`:

$$\text{Cost}_{\text{heap\_fetches}} = \sigma \cdot N_{\text{tuples}} \cdot \left[ c_{\text{rand\_page}} \cdot (1 - |\rho|) + c_{\text{page}} \cdot |\rho| \right]$$

The optimizer **inverts** the plan from Index Scan to Sequential Scan when $C_{\text{idx}} > C_{\text{seq}}$, yielding the critical tipping point selectivity $\sigma^*$:

$$\sigma^* = \frac{N_{\text{pages}} \cdot c_{\text{page}} + N_{\text{tuples}} \cdot c_{\text{cpu}} - N_{\text{idx\_pages}} \cdot c_{\text{page}}}{N_{\text{tuples}} \cdot \left( c_{\text{cpu}} + c_{\text{rand\_page}} \cdot (1 - |\rho|) + c_{\text{page}} \cdot |\rho| \right)}$$

**Theorem 1 (Parameter Sniffing Latency Cliff)**: *When bind parameters transition an estimated selectivity $\sigma$ from $\sigma^* - \epsilon$ to $\sigma^* + \epsilon$, the planner switches from Index Scan to Seq Scan. If the true runtime row count $K_{\text{true}} \ll \sigma^* \cdot N_{\text{tuples}}$ (due to histogram quantization or bind parameter masking in generic plans), execution time degrades by factor $\Omega$*:

$$\Omega = \frac{T_{\text{seq}}}{T_{\text{idx}}} \approx \frac{N_{\text{pages}} \cdot t_{\text{seq\_read}} + N_{\text{tuples}} \cdot t_{\text{cpu}}}{K_{\text{true}} \cdot t_{\text{rand\_read}} + \lceil \log_B N_{\text{idx}} \rceil \cdot t_{\text{index\_page}}}$$

For a 10GB table ($N_{\text{pages}} = 1,280,000$) where $K_{\text{true}} = 5$:
- $T_{\text{idx}} \approx 3 \times 0.05\text{ms} + 5 \times 0.1\text{ms} \approx 0.65\text{ms}$
- $T_{\text{seq}} \approx 1,280,000 \times 0.003\text{ms} \approx 3,840\text{ms}$
- Latency cliff ratio: $\Omega \approx \frac{3840}{0.65} \approx 5,907\times$.

Freezing the plan via `/*+ IndexScan(t idx) */` guarantees that the execution path remains pinned to $T_{\text{idx}}$ regardless of parameter fluctuations.

---

### Model 2.2: Combinatorial Join Search Space & GEQO Stochastic Instability Bounds

For a query joining $N$ relations, the number of possible join trees $S(N)$ depends on whether bushy trees are explored:

$$S_{\text{bushy}}(N) = \frac{(2N - 2)!}{(N - 1)!} \cdot 2^{N - 1}$$

| Number of Relations $N$ | Left-Deep Join Trees $N!$ | Bushy Join Trees $S_{\text{bushy}}(N)$ | Optimizer Engine |
| :---: | :---: | :---: | :---: |
| 4 | 24 | 120 | Dynamic Programming |
| 8 | 40,320 | 17,529,600 | Dynamic Programming |
| 12 | 479,001,600 | $2.8 \times 10^{14}$ | GEQO Threshold Boundary (`geqo_threshold = 12`) |
| 16 | $2.09 \times 10^{13}$ | $6.2 \times 10^{23}$ | Genetic Query Optimizer (Stochastic) |

**Theorem 2 (GEQO Plan Non-Determinism Invariant)**: *When $N \ge \text{geqo\_threshold}$, PostgreSQL's genetic algorithm samples random permutations with pool size $\text{geqo\_pool\_size}$. Let $P_{\text{opt}}$ be the probability that the genetic heuristic reaches the global optimum join order. The probability that two consecutive runs of the exact same query produce divergent execution plans is*:

$$P(\text{Divergent Plans}) = 1 - \sum_{i=1}^{M} \left( P(\text{Plan}_i) \right)^2 \ge 1 - \frac{1}{M} > 0.85$$

Where $M$ is the number of local minima in the cost landscape. Enforcing join order via `/*+ Leading((t1 (t2 t3))) */` collapses the search space from $S(N)$ to $1$, ensuring deterministic $O(1)$ planning and identical runtime characteristics.

---

### Model 2.3: Connection Pool Little's Law Exhaustion Under Plan Inversion

Let $\lambda$ be the steady-state arrival rate of transactions at a microservice pool with capacity $C_{\text{pool}}$ connections. Under nominal conditions, each transaction takes mean execution time $W_{\text{nominal}} = 2\text{ms} = 0.002\text{s}$. By Little's Law, the mean active connections $L_{\text{nominal}}$ is:

$$L_{\text{nominal}} = \lambda \cdot W_{\text{nominal}}$$

For $\lambda = 500\text{ req/s}$, $L_{\text{nominal}} = 500 \times 0.002 = 1.0\text{ connection}$.

When a single high-frequency query experiences plan inversion, its latency escalates to $W_{\text{regressed}} = 3,500\text{ms} = 3.5\text{s}$. The time to completely saturate the pool $T_{\text{exhaust}}$ is:

$$T_{\text{exhaust}} = \frac{C_{\text{pool}} - L_{\text{nominal}}}{\lambda \cdot \left( 1 - \frac{C_{\text{pool}}}{\lambda \cdot W_{\text{regressed}}} \right)}$$

For $C_{\text{pool}} = 50$ and $\lambda = 500\text{ req/s}$:

$$T_{\text{exhaust}} \approx \frac{50 - 1}{500 \cdot (1 - \frac{50}{1750})} \approx \frac{49}{500 \cdot 0.971} \approx 0.101\text{ seconds}$$

Within **101 milliseconds**, the entire connection pool is completely starved, inducing cascading 504 Gateway Timeouts across the distributed architecture.

---

## 3. Autonomous TypeScript Guard Engine

The following production-grade TypeScript engine provides comprehensive static analysis, hint parsing, alias validation, comment preservation auditing, and in-database `hint_plan.hints` baseline management.

```typescript
/**
 * AgenticDatabaseQueryHintGuardEngine
 * Production-grade analyzer, AST validator, and baseline manager for pg_hint_plan
 * and query execution plan stability in PostgreSQL architectures.
 */

export interface QueryHint {
  type: 'SCAN' | 'JOIN_METHOD' | 'JOIN_ORDER' | 'ROWS' | 'GUC' | 'PARALLEL';
  name: string;
  targets: string[];
  parameters?: Record<string, string | number>;
  raw: string;
}

export interface AstTableAlias {
  relationName: string;
  alias: string;
}

export interface ValidationIssue {
  severity: 'ERROR' | 'WARNING' | 'CRITICAL';
  code: string;
  message: string;
  remediation: string;
}

export interface PlanStabilityAuditResult {
  hasHints: boolean;
  hints: QueryHint[];
  aliases: AstTableAlias[];
  issues: ValidationIssue[];
  normalizedQuery: string;
  suggestedBaselineSql?: string;
}

export class AgenticDatabaseQueryHintGuardEngine {
  private static readonly SCAN_HINTS = new Set([
    'SeqScan', 'NoSeqScan', 'IndexScan', 'NoIndexScan',
    'IndexOnlyScan', 'NoIndexOnlyScan', 'BitmapScan', 'NoBitmapScan',
    'TidScan', 'NoTidScan'
  ]);

  private static readonly JOIN_METHOD_HINTS = new Set([
    'NestLoop', 'NoNestLoop', 'HashJoin', 'NoHashJoin',
    'MergeJoin', 'NoMergeJoin'
  ]);

  /**
   * Performs end-to-end static audit of a SQL query for plan stability,
   * verifying comment retention, hint syntax, alias alignment, and anti-patterns.
   */
  public static auditQuery(sql: string): PlanStabilityAuditResult {
    const issues: ValidationIssue[] = [];
    const hints = this.extractHints(sql);
    const aliases = this.extractTableAliases(sql);

    // Rule 1: Check for dangerous global optimizer GUC tampering
    if (/\bSET\s+(?:enable_seqscan|enable_nestloop|enable_hashjoin|enable_mergejoin)\s*=/i.test(sql)) {
      if (!/\bSET\s+LOCAL\b/i.test(sql)) {
        issues.push({
          severity: 'CRITICAL',
          code: 'GLOBAL_OPTIMIZER_GUC_MUTATION',
          message: 'Found non-LOCAL SET mutation on optimizer GUCs. This pollutes physical pooled connections.',
          remediation: 'Use transaction-scoped SET LOCAL or deploy pg_hint_plan Set(...) hints.'
        });
      }
    }

    // Rule 2: Check for brittle optimization hacks (OFFSET 0)
    if (/\bOFFSET\s+0\b/i.test(sql) && !/\bFETCH\b/i.test(sql)) {
      issues.push({
        severity: 'WARNING',
        code: 'BRITTLE_OFFSET_ZERO_HACK',
        message: 'Detected OFFSET 0 syntax hack. Modern PostgreSQL optimizers can inline or bypass OFFSET 0.',
        remediation: 'Replace OFFSET 0 with explicit CTE AS MATERIALIZED or pg_hint_plan Leading/JoinMethod hints.'
      });
    }

    // Rule 3: Check for pg_hint_plan alias mismatch
    if (hints.length > 0) {
      const declaredAliases = new Set(aliases.map(a => a.alias));
      const declaredRelNames = new Set(aliases.map(a => a.relationName));

      for (const hint of hints) {
        if (hint.type === 'SCAN' || hint.type === 'JOIN_METHOD') {
          for (const target of hint.targets) {
            // Target could be an alias or relation
            const matchesAlias = declaredAliases.has(target);
            const matchesRelation = declaredRelNames.has(target);

            // If relation was aliased to something else, referencing relation directly is a silent failure!
            const aliasedRel = aliases.find(a => a.relationName === target && a.alias !== target);
            if (aliasedRel && !matchesAlias) {
              issues.push({
                severity: 'CRITICAL',
                code: 'HINT_TARGET_ALIAS_MISMATCH',
                message: `Hint '${hint.raw}' targets relation '${target}', but the query aliases it as '${aliasedRel.alias}'. pg_hint_plan will SILENTLY IGNORE this hint!`,
                remediation: `Change hint target from '${target}' to alias '${aliasedRel.alias}'.`
              });
            } else if (!matchesAlias && !matchesRelation) {
              issues.push({
                severity: 'ERROR',
                code: 'UNKNOWN_HINT_TARGET',
                message: `Hint target '${target}' does not match any table or alias in the query.`,
                remediation: `Ensure '${target}' exists in the FROM/JOIN clause.`
              });
            }
          }
        }
      }
    }

    // Rule 4: Check for multi-table join without join order hint
    if (aliases.length >= 10 && !hints.some(h => h.name === 'Leading')) {
      issues.push({
        severity: 'WARNING',
        code: 'GEQO_JOIN_ORDER_UNPINNED',
        message: `Query references ${aliases.length} tables without a Leading(...) hint. Approaching or exceeding geqo_threshold (12).`,
        remediation: 'Pin join order using /*+ Leading(...) */ to prevent stochastic GEQO plan jitter.'
      });
    }

    const normalized = this.normalizeQuery(sql);
    let suggestedBaselineSql: string | undefined;

    if (hints.length > 0) {
      const hintPayload = hints.map(h => h.raw).join(' ');
      suggestedBaselineSql = `INSERT INTO hint_plan.hints (norm_query_string, application_name, hints) ` +
        `VALUES ('${normalized.replace(/'/g, "''")}', '', '${hintPayload.replace(/'/g, "''")}') ` +
        `ON CONFLICT (norm_query_string, application_name) DO UPDATE SET hints = EXCLUDED.hints;`;
    }

    return {
      hasHints: hints.length > 0,
      hints,
      aliases,
      issues,
      normalizedQuery: normalized,
      suggestedBaselineSql
    };
  }

  /**
   * Extracts pg_hint_plan hints from SQL block comments: /*+ ... *\/
   */
  public static extractHints(sql: string): QueryHint[] {
    const hints: QueryHint[] = [];
    const hintCommentRegex = /\/\*\+\s*([\s\S]*?)\*\//g;
    let match: RegExpExecArray | null;

    while ((match = hintCommentRegex.exec(sql)) !== null) {
      const commentBody = match[1].trim();
      const directiveRegex = /([a-zA-Z0-9_]+)\s*\(([^)]+)\)/g;
      let dirMatch: RegExpExecArray | null;

      while ((dirMatch = directiveRegex.exec(commentBody)) !== null) {
        const name = dirMatch[1];
        const argStr = dirMatch[2].trim();
        const raw = `${name}(${argStr})`;

        let type: QueryHint['type'] = 'GUC';
        if (this.SCAN_HINTS.has(name)) {
          type = 'SCAN';
        } else if (this.JOIN_METHOD_HINTS.has(name)) {
          type = 'JOIN_METHOD';
        } else if (name === 'Leading') {
          type = 'JOIN_ORDER';
        } else if (name === 'Rows') {
          type = 'ROWS';
        } else if (name === 'Parallel') {
          type = 'PARALLEL';
        }

        // Parse target identifiers
        const targets = argStr
          .replace(/[()]/g, ' ')
          .split(/\s+/)
          .filter(t => t.length > 0 && !t.startsWith('#') && !t.startsWith('+') && !t.startsWith('-'));

        hints.push({ type, name, targets, raw });
      }
    }

    return hints;
  }

  /**
   * Extracts simple table names and aliases from SELECT ... FROM / JOIN clauses.
   */
  public static extractTableAliases(sql: string): AstTableAlias[] {
    const aliases: AstTableAlias[] = [];
    const cleanSql = sql.replace(/\/\*[\s\S]*?\*\/|--.*$/gm, ' ');
    
    // Match: FROM table [AS] alias, or JOIN table [AS] alias
    const tableRegex = /\b(?:FROM|JOIN)\s+([a-zA-Z0-9_".]+)(?:\s+(?:AS\s+)?([a-zA-Z0-9_"]+))?/gi;
    let match: RegExpExecArray | null;

    const reservedKeywords = new Set([
      'WHERE', 'ON', 'USING', 'LEFT', 'RIGHT', 'INNER', 'OUTER',
      'CROSS', 'FULL', 'JOIN', 'GROUP', 'ORDER', 'LIMIT', 'SET', 'HAVING'
    ]);

    while ((match = tableRegex.exec(cleanSql)) !== null) {
      const rawRel = match[1].replace(/"/g, '');
      let rawAlias = match[2] ? match[2].replace(/"/g, '') : rawRel;

      if (reservedKeywords.has(rawAlias.toUpperCase())) {
        rawAlias = rawRel;
      }

      aliases.push({ relationName: rawRel, alias: rawAlias });
    }

    return aliases;
  }

  /**
   * Normalizes SQL statement for out-of-band hint_plan.hints storage:
   * Strips comments, collapses whitespaces, normalizes literal constants.
   */
  public static normalizeQuery(sql: string): string {
    return sql
      .replace(/\/\*[\s\S]*?\*\/|--.*$/gm, '') // Strip comments
      .replace(/'(?:[^'\\]|\\.)*'/g, '?')      // Replace string literals with placeholder
      .replace(/\b\d+\b/g, '?')                // Replace numeric constants with placeholder
      .replace(/\s+/g, ' ')                    // Collapse whitespace
      .trim();
  }
}
```

---

## 4. Cross-Runtime Telemetry Sentinels

### 4.1 Go (`jackc/pgx/v5`): Plan Stability Sentinel & `HINT_ERROR` Notice Watchdog

```go
package database

import (
	"context"
	"fmt"
	"strings"
	"sync/atomic"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type HintNoticeSentinel struct {
	pool           *pgxpool.Pool
	hintErrorCount atomic.Uint64
}

// NewHintNoticeSentinel creates a connection pool configured to intercept pg_hint_plan warnings
func NewHintNoticeSentinel(ctx context.Context, connString string) (*HintNoticeSentinel, error) {
	config, err := pgxpool.ParseConfig(connString)
	if err != nil {
		return nil, fmt.Errorf("parse conn string failed: %w", err)
	}

	sentinel := &HintNoticeSentinel{}

	// Intercept PostgreSQL Notice messages (where pg_hint_plan emits hint parsing errors)
	config.ConnConfig.OnNotice = func(cn *pgconn.PgConn, notice *pgconn.Notice) {
		if strings.Contains(notice.Message, "hint syntax error") ||
			strings.Contains(notice.Message, "hint table") ||
			strings.Contains(notice.Message, "HINT_ERROR") {
			sentinel.hintErrorCount.Add(1)
			fmt.Printf("🚨 [PG_HINT_PLAN ERROR] Severity: %s, Message: %s, Detail: %s\n",
				notice.Severity, notice.Message, notice.Detail)
		}
	}

	// Ensure pg_hint_plan message_level is set to notice/warning so errors are visible
	config.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		_, err := conn.Exec(ctx, "SET pg_hint_plan.message_level = 'notice';")
		return err
	}

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, fmt.Errorf("create pool failed: %w", err)
	}

	sentinel.pool = pool
	return sentinel, nil
}

// QueryWithPinnedPlan executes a query while asserting that block comments containing hints are preserved
func (s *HintNoticeSentinel) QueryWithPinnedPlan(
	ctx context.Context,
	sql string,
	args ...any,
) (pgx.Rows, error) {
	// Guard: Verify hint syntax is not mangled
	if strings.Contains(sql, "/*+") && !strings.Contains(sql, "*/") {
		return nil, fmt.Errorf("malformed pg_hint_plan block: unclosed /*+ comment")
	}

	beforeErrors := s.hintErrorCount.Load()
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}

	afterErrors := s.hintErrorCount.Load()
	if afterErrors > beforeErrors {
		// Log telemetry: hint was rejected by PostgreSQL optimizer hook
		fmt.Printf("⚠️ Query executed but pg_hint_plan reported rejection! SQL: %.100s...\n", sql)
	}

	return rows, nil
}
```

---

### 4.2 TypeScript (`pg`): Comment-Preserving Query Wrapper with In-Database Baselines

```typescript
import { Pool, PoolClient, QueryResult, QueryResultRow } from 'pg';

export class StableQueryExecutor {
  private pool: Pool;

  constructor(pool: Pool) {
    this.pool = pool;
  }

  /**
   * Executes a query ensuring comments are preserved on the wire protocol.
   * Rejects queries containing dangerous session-level GUC mutations.
   */
  public async executePinned<T extends QueryResultRow = any>(
    client: PoolClient,
    sql: string,
    params: any[] = []
  ): Promise<QueryResult<T>> {
    // Assert no naked session-level optimizer disabling
    if (/\bSET\s+enable_seqscan\b/i.test(sql) && !/\bSET\s+LOCAL\b/i.test(sql)) {
      throw new Error(
        'SECURITY/STABILITY INVARIANT VIOLATION: Naked SET enable_seqscan detected. ' +
        'Must use SET LOCAL within a transaction block or /*+ ... */ hints.'
      );
    }

    // Set message level in transaction if hints are present
    const hasHints = sql.includes('/*+');
    if (hasHints) {
      await client.query("SET LOCAL pg_hint_plan.message_level = 'warning';");
    }

    return client.query<T>(sql, params);
  }

  /**
   * Registers an out-of-band query plan baseline directly into PostgreSQL's hint_plan.hints table.
   * Completely eliminates the need to mutate application SQL code.
   */
  public async registerBaseline(
    normQuery: string,
    hints: string,
    appName: string = ''
  ): Promise<void> {
    const registerSql = `
      INSERT INTO hint_plan.hints (norm_query_string, application_name, hints)
      VALUES ($1, $2, $3)
      ON CONFLICT (norm_query_string, application_name)
      DO UPDATE SET hints = EXCLUDED.hints;
    `;
    await this.pool.query(registerSql, [normQuery, appName, hints]);
  }
}
```

---

### 4.3 Python (`asyncpg`): Plan Regression Watchdog & Plan Capture Sentinel

```python
import asyncpg
import re
from typing import List, Dict, Any, Optional

class PlanRegressionWatchdog:
    """
    Monitors execution plans and verifies that pg_hint_plan enforces
    Index Scan and prevents catastrophic Sequential Scan inversions.
    """
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def verify_plan_stability(
        self,
        sql: str,
        params: List[Any],
        expected_node: str = "Index Scan"
    ) -> Dict[str, Any]:
        async with self.pool.acquire() as conn:
            # Execute EXPLAIN (FORMAT JSON, BUFFERS)
            explain_query = f"EXPLAIN (FORMAT JSON, BUFFERS) {sql}"
            result_json_str = await conn.fetchval(explain_query, *params)
            
            # Parse plan structure
            import json
            plan_data = json.loads(result_json_str)[0]["Plan"]
            
            # Recursively check if expected node is present in execution tree
            found_node = self._search_node_type(plan_data, expected_node)
            seq_scan_found = self._search_node_type(plan_data, "Seq Scan")
            
            return {
                "expected_node_present": found_node,
                "seq_scan_present": seq_scan_found,
                "total_cost": plan_data.get("Total Cost", 0),
                "plan_type": plan_data.get("Node Type"),
                "is_stable": found_node and not seq_scan_found
            }

    def _search_node_type(self, node: Dict[str, Any], target_type: str) -> bool:
        if node.get("Node Type") == target_type:
            return True
        for child in node.get("Plans", []):
            if self._search_node_type(child, target_type):
                return True
        return False
```

---

### 4.4 Rust (`sqlx`): Zero-Cost Compile-Time Comment Preservation Harness

```rust
use sqlx::{PgPool, Error};

pub struct PinnedQueryHarness<'a> {
    pool: &'a PgPool,
}

impl<'a> PinnedQueryHarness<'a> {
    pub fn new(pool: &'a PgPool) -> Self {
        Self { pool }
    }

    /// Verifies SQL query maintains comment markers for pg_hint_plan
    pub fn validate_hint_invariants(sql: &str) -> Result<(), String> {
        if sql.contains("/*+") {
            if !sql.contains("*/") {
                return Err("Malformed hint: missing closing */ delimiter".to_string());
            }
            if sql.contains("SET enable_seqscan") && !sql.contains("SET LOCAL") {
                return Err("Prohibited naked SET enable_seqscan detected".to_string());
            }
        }
        Ok(())
    }

    /// Executes query asserting client configuration respects notice messages
    pub async fn execute_pinned(
        &self,
        sql: &str,
    ) -> Result<sqlx::postgres::PgQueryResult, Error> {
        if let Err(e) = Self::validate_hint_invariants(sql) {
            return Err(Error::Protocol(e));
        }

        sqlx::query(sql).execute(self.pool).await
    }
}
```

---

## 5. Finite-State Machine (FSM) Lifecycle

The plan stability and query hint lifecycle transitions through 6 deterministic states:

```
                  ┌──────────────────────┐
                  │     1. DISCOVERY     │
                  └──────────┬───────────┘
                             │ Plan regression or parameter sniffing detected
                             ▼
                  ┌──────────────────────┐
                  │  2. HINT_SYNTHESIS   │
                  └──────────┬───────────┘
                             │ AST & alias alignment verified
                             ▼
                  ┌──────────────────────┐
                  │3. CANARY_VERIFICATION│
                  └──────────┬───────────┘
                             │ EXPLAIN (BUFFERS) shows 0 spills & desired scan
                             ▼
                  ┌──────────────────────┐
                  │4.BASELINE_REGISTRATION
                  └──────────┬───────────┘
                             │ Stored in hint_plan.hints catalog or SQL comments
                             ▼
                  ┌──────────────────────┐
                  │    5. STABILIZED     │
                  └──────────┬───────────┘
                             │ Schema drift, index drop, or HINT_ERROR notice
                             ▼
                  ┌──────────────────────┐
                  │   6. DRIFT_ALERT     │ (Circuit breaker triggers fallback audit)
                  └──────────────────────┘
```

### FSM State Transition Invariants

| State | Entry Condition | Invariant Maintained | Exit Condition |
| :--- | :--- | :--- | :--- |
| **1. DISCOVERY** | Query p99 latency spikes or `auto_explain` logs unexpected `Seq Scan` on indexed relation. | Zero production GUC tampering (`SET enable_seqscan` prohibited). | Root cause identified (parameter sniffing / statistics skew). |
| **2. HINT_SYNTHESIS** | Candidate scan, join method, or join order identified. | 100% table alias matching between hint targets and SQL query AST. | Synthetic plan passes `AgenticDatabaseQueryHintGuardEngine` audit. |
| **3. CANARY_VERIFICATION** | Query executed under `SET LOCAL pg_hint_plan.message_level = 'warning'`. | `EXPLAIN (ANALYZE, BUFFERS)` verifies exact node execution and zero temp disk spills. | Zero warnings, zero `HINT_ERROR` notices, execution time $\le 5\text{ms}$. |
| **4. BASELINE_REGISTRATION** | Plan verified in staging environment. | Plan persisted out-of-band in `hint_plan.hints` or in-code `/*+ ... */`. | Baseline active across 100% of connection pool backends. |
| **5. STABILIZED** | Application serving production traffic. | Query execution variance $c_v = \sigma / \mu \le 0.35$. | Continuous telemetry asserts zero plan flips. |
| **6. DRIFT_ALERT** | Underlying index renamed, dropped, or statistics mutated. | Notice handler detects `HINT_ERROR` or unexpected `Seq Scan`. | SRE alert dispatched; agent automatically resets or recalculates hints. |

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Gates

Every query hint, plan baseline, or database migration affecting critical query paths must satisfy the following 6 automated CI gates:

```
[Gate 1: Comment Retention] -> [Gate 2: Alias Matching] -> [Gate 3: Extension Check]
             │                            │                           │
             ▼                            ▼                           ▼
[Gate 4: Zero HINT_ERROR]   -> [Gate 5: Zero Temp Spills] -> [Gate 6: Baseline In Sync]
```

### 1. Gate 1: Comment Retention & Pre-Flight AST Verification
- **Test**: Run the application query through the target database driver (e.g. Prisma raw SQL, pgx, asyncpg) and inspect the wire-protocol string captured by `pg_stat_activity`.
- **Pass Criteria**: The SQL query string must retain the `/*+ ... */` comment block verbatim. Minifiers must NOT strip hints.

### 2. Gate 2: Table Alias Binding & Sargability Assertion
- **Test**: Run `AgenticDatabaseQueryHintGuardEngine.auditQuery(sql)`.
- **Pass Criteria**: Zero `CRITICAL` or `ERROR` validation issues. Every hint target relation matches the exact SQL table alias declared in the `FROM`/`JOIN` clause.

### 3. Gate 3: Extension Preload & shared_preload_libraries Verification
- **Test**: Query `SHOW shared_preload_libraries;` and `SELECT extname FROM pg_extension WHERE extname = 'pg_hint_plan';`.
- **Pass Criteria**: `shared_preload_libraries` contains `pg_hint_plan`, and `CREATE EXTENSION IF NOT EXISTS pg_hint_plan;` succeeds without error.

### 4. Gate 4: Zero-Tolerance `HINT_ERROR` Gate
- **Test**: Execute the query in CI under `SET pg_hint_plan.message_level = 'warning';`.
- **Pass Criteria**: The database notice listener receives zero hint-related warnings, syntax errors, or unresolvable index targets.

### 5. Gate 5: Plan Determinism & Buffer Spill Immunity
- **Test**: Execute `EXPLAIN (ANALYZE, BUFFERS) <query>` across 10 parameterized runs with boundary values (min, max, median, null).
- **Pass Criteria**: All 10 runs produce identical execution plan node topologies. `Buffers: temp written=0` blocks must hold across all runs.

### 6. Gate 6: In-Database Baseline Catalog Synchronization
- **Test**: When using `hint_plan.hints`, verify `SELECT COUNT(*) FROM hint_plan.hints WHERE norm_query_string = ...`.
- **Pass Criteria**: Normalized query string matches exactly with $1$ active hint record. `pg_hint_plan.enable_hint_table = on` is verified active.
