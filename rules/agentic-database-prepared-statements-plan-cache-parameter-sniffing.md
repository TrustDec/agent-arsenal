---
description: PostgreSQL Prepared Statements, plan cache invalidation (0A000 / XX000), parameter sniffing, 5-execution generic plan drift (plan_cache_mode = auto / force_custom), PgBouncer transaction-mode collision defense, dynamic IN clause parameter explosion (= ANY($1)), and EXPLAIN (GENERIC_PLAN) CI verification across Go (pgx/sqlc), TypeScript (Drizzle, Prisma, Kysely), Python (asyncpg, SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{query,statement,prepared,plan,cache,sniffing,sql,pgx,prisma,drizzle,kysely,repository,store}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/pgbouncer*.ini
alwaysApply: false
---

# Agentic Database Prepared Statements, Plan Cache Invalidation, Parameter Sniffing & Generic Plan Drift Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to write database queries, configure driver statement caches, deploy connection poolers (PgBouncer, AWS RDS Proxy), design zero-downtime DDL migrations, and optimize high-throughput OLTP/OLAP services across PostgreSQL, Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`asyncpg`, `SQLAlchemy`), or Rust (`sqlx`). Eliminate the "5-Execution Generic Plan Drift & Parameter Sniffing Trap" (where PostgreSQL evaluates custom plans for 5 executions and on the 6th run permanently binds to a generic sequential scan on skewed data distributions, causing 100x latency spikes and pool starvation), the "Cached Plan Must Not Change Result Type DDL Outage" (where zero-downtime DDL changes trigger SQLSTATE `0A000` / `XX000` crashes across long-lived connection pools until applications are forcibly restarted), the "PgBouncer Transaction Pooling Named Statement Collision & Missing Statement Trap" (where multiplexing backend connections triggers `ERROR: prepared statement already exists` or `does not exist`), the "Dynamic `IN (...)` Parameter Explosion & Backend Memory Bloat" (where variable parameter counts spawn tens of thousands of distinct statement handles, exhausting PostgreSQL memory and driver heap), the "Declarative Partition Pruning Elimination in Generic Plans" (where generic plans fail to perform plan-time partition pruning and scan all partitions), and the "Silent Driver Protocol Mismatch" (where simple vs extended protocol mismatches silently defeat pooling multiplexing) by establishing a strict 5-Tier Prepared Statement & Plan Cache Governance Ladder, mathematical generic plan crossover models, production TypeScript guard engines, and machine-verifiable `EXPLAIN (GENERIC_PLAN)` CI gates.

---

## 1. Architectural Taxonomy: The 6 Prepared Statement Catastrophes vs The 5-Tier Governance Ladder

Prepared statements separate SQL parsing and query planning from execution, saving CPU cycles on repetitive statements. However, in distributed cloud architectures using connection poolers, skewed multi-tenant datasets, and continuous DDL deployments, naive prepared statement handling introduces severe production failure modes:

```typescript
// ❌ CATASTROPHIC LLM QUERY IMPLEMENTATION: DYNAMIC IN-CLAUSE + SKEWED FILTER TRAP
// An autonomous agent implements a batched order status query in Node/TypeScript:
export async function getOrdersByStatuses(tenantId: string, orderIds: string[], status: string) {
  // ❌ ANTI-PATTERN 1: Dynamic IN clause builds variable-length SQL strings:
  // For 1 ID:  '... WHERE id IN ($1)' -> Prepared Statement #1
  // For 2 IDs: '... WHERE id IN ($1, $2)' -> Prepared Statement #2
  // For 50 IDs: builds 50 distinct prepared statement handles in pg_prepared_statements!
  // Backend connection memory leaks gigabytes over time!
  const placeholders = orderIds.map((_, i) => `$${i + 3}`).join(', ');

  // ❌ ANTI-PATTERN 2: Skewed status parameter ('FAILED' is 0.01% of rows; 'COMPLETED' is 99.99%)
  // On execution #1..#5: PostgreSQL generates a custom plan using Index Scan (0.2ms).
  // On execution #6: PostgreSQL switches to a generic plan ($2 placeholder).
  // Because status is unknown, the planner assumes uniform distribution and selects a Sequential Scan!
  // Execution time explodes from 0.2ms to 45,000ms! Connection pool collapses!
  const sql = `
    SELECT id, tenant_id, amount_cents, status, created_at
    FROM customer_orders
    WHERE tenant_id = $1
      AND status = $2
      AND id IN (${placeholders})
  `;

  return db.query(sql, [tenantId, status, ...orderIds]);
}

// ✅ PRODUCTION INVARIANT: STATIC SQL WITH = ANY($1) + PLAN CACHE GOVERNANCE
export async function getOrdersByStatusesOptimized(
  tenantId: string,
  orderIds: string[],
  status: string,
  forceCustomPlan: boolean = false
) {
  // 1. Static SQL query string: exactly 3 bind parameters regardless of array length!
  // 100% statement cache reuse; zero backend memory bloat; zero dynamic compilation.
  const sql = `
    SELECT id, tenant_id, amount_cents, status, created_at
    FROM customer_orders
    WHERE tenant_id = $1
      AND status = $2
      AND id = ANY($3::UUID[])
  `;

  // 2. If filtering on a highly skewed column, force custom parameter evaluation
  // to prevent generic plan sequential scan drift.
  if (forceCustomPlan) {
    return db.transaction(async (tx) => {
      await tx.execute("SET LOCAL plan_cache_mode = 'force_custom'");
      return tx.query(sql, [tenantId, status, orderIds]);
    });
  }

  return db.query(sql, [tenantId, status, orderIds]);
}
```

### The 6 Prepared Statement Catastrophes

1. **The 5-Execution Generic Plan Drift & Parameter Sniffing Trap (`plan_cache_mode = auto`)**:
   PostgreSQL executes prepared statements using "custom plans" (evaluating actual parameter literals) for the first 5 runs. On the 6th run, the planner evaluates a "generic plan" (replacing parameters with placeholders `$1, $2, ...`). If the generic plan's estimated cost is less than or equal to the average cost of the custom plans, PostgreSQL binds the prepared statement permanently to the generic plan for that connection. On skewed columns (e.g. `is_active = FALSE` representing 0.01% of rows vs `TRUE` representing 99.99%), the generic plan picks a full sequential scan. When an API passes `is_active = FALSE`, instead of an Index Scan in 0.1ms, it executes a 45-second sequential scan over 50M rows, stalling worker threads and crashing microservices.
2. **The "Cached Plan Must Not Change Result Type" DDL Outage (SQLSTATE `0A000` / `XX000`)**:
   When zero-downtime DDL migrations execute (e.g. `ALTER TABLE t ADD COLUMN c ...`, dropping a column, or replacing a view), existing prepared statements cached in long-running Go/Node/Python backends hold references to the old table schema or tuple descriptor. Subsequent executions fail with `ERROR: cached plan must not change result type` or `ERROR: cached plan is invalid`. Long-lived connection pools keep serving failed queries until manually recycled, turning a zero-downtime migration into a service-wide outage.
3. **The PgBouncer Transaction Pooling Named Statement Collision & Missing Statement Trap**:
   In transaction pooling mode (`pool_mode = transaction`), PgBouncer assigns different backend PostgreSQL connections to different client transactions. If an application or ORM executes `PREPARE stmt_123 AS ...`, the statement only exists on that specific backend. The next query running on another backend throws `ERROR: prepared statement "stmt_123" does not exist`. Conversely, when another client gets the first backend, executing `PREPARE stmt_123` throws `ERROR: prepared statement "stmt_123" already exists`.
4. **Statement Handle Leakage & Backend Memory Bloat (Dynamic `IN (...)` Parameter Explosion)**:
   When ORMs or agents dynamically build SQL queries with varying numbers of bind parameters (e.g. `WHERE id IN ($1, $2)` vs `WHERE id IN ($1, $2, $3, ...)`), each parameter count generates a distinct SQL text and a new prepared statement in the driver's statement cache and backend memory (`pg_prepared_statements`). Over days of traffic, tens of thousands of prepared statements accumulate, bloating PostgreSQL backend memory and driver heap to hundreds of megabytes, causing OOM kills.
5. **Declarative Partition Pruning Elimination in Generic Plans**:
   On declarative range/list partitioned tables, custom plans evaluate parameter values at planning time and prune away 99% of partitions before the execution phase starts (`run-time partition pruning` vs `plan-time partition pruning`). Generic plans cannot perform plan-time partition pruning because parameter values are unknown. In high-partition tables (e.g. 1,000+ daily/hourly partitions), planning generic plans or executing them across unpruned partition trees causes extreme CPU overhead and planner degradation.
6. **The Silent Driver Protocol Mismatch (Simple vs Extended Query Protocol & Cache Size Blindness)**:
   Different language drivers have completely different prepared statement defaults: Go `pgx` automatically manages a statement cache using the Extended Query Protocol; Node `pg` requires explicit `{ name: '...' }` or defaults to unnamed statements; `asyncpg` in Python auto-prepares every statement unless configured; Rust `sqlx` prepares statements by default. When connecting through proxies (PgBouncer, AWS RDS Proxy, Cloud SQL Auth Proxy), failing to configure `prefer_simple_protocol`, `statement_cache_capacity = 0`, or PgBouncer 1.21+ `max_prepared_statements` causes silent connection pinning or catastrophic query crashes.

### The 5-Tier Prepared Statement & Plan Cache Governance Ladder

| Governance Tier | Operational Mechanism | Mathematical / Architectural Invariant | Target Failure Mode Eliminated |
| :--- | :--- | :--- | :--- |
| **Tier 0: Plan Cache Mode Governance** | Enforce `SET LOCAL plan_cache_mode = force_custom` on skewed predicates | $C_{\text{executed}} = C_{\text{custom}}(p) \ll C_{\text{generic}}$ for rare keys | 5-Execution generic plan drift, parameter sniffing sequential scan flip |
| **Tier 1: Static SQL & Array Sargability** | Replace dynamic `IN ($1..$N)` with static `= ANY($1::type[])` | $N_{\text{prepared\_stmts}} = 1$ invariant for all input sizes $N$ | Statement cache explosion, backend memory bloat, driver cache thrashing |
| **Tier 2: PgBouncer Pooling Compatibility** | Enforce unnamed prepared statements or PgBouncer 1.21+ statement tracking | Zero named `PREPARE` without PgBouncer statement multiplexing | `prepared statement already exists` (42P05) / `does not exist` (26000) |
| **Tier 3: Resilient Cached Plan Recovery** | Automatic retry on SQLSTATE `0A000` / `XX000` with `DISCARD PLANS` | $P(\text{DDL outage}) = 0$ during zero-downtime schema evolution | `cached plan must not change result type` post-migration failure |
| **Tier 4: Automated CI Plan Verification** | CI verification using `EXPLAIN (GENERIC_PLAN, BUFFERS)` | $C_{\text{generic}} / C_{\text{custom}} \le 2.0$ gate across all endpoints | Silent production performance regressions before code merge |

---

## 2. Mathematical Invariants & Physical Plan Cache Physics Models

### 1. The Generic Plan Crossover Theorem & Parameter Sniffing Degradation

PostgreSQL evaluates prepared statements using the cost comparison model defined in the optimizer (`src/backend/utils/cache/plancache.c`):

$$\bar{C}_{\text{custom}} = \frac{1}{5} \sum_{k=1}^5 C_{\text{custom}}(p_k)$$

The planner switches to a generic plan on execution $k \ge 6$ if:

$$C_{\text{generic}} \le \bar{C}_{\text{custom}}$$

Let a table relation $R$ have $N$ tuples, and let a column $A$ follow a Zipfian distribution with parameter $s > 1$. The frequency of the $r$-th most common value is:

$$f(r; s, M) = \frac{1 / r^s}{\sum_{n=1}^M (1 / n^s)}$$

If 99% of queries query the most frequent value $r=1$ (e.g., `status = 'COMPLETED'`), the custom plan cost is:

$$C_{\text{custom}}(r_1) = \text{SeqScanCost}(R) \approx N \times \text{cpu\_tuple\_cost}$$

Because $r_1$ matches almost the entire table, an Index Scan would be slower than a sequential scan. Therefore, $\bar{C}_{\text{custom}} \approx \text{SeqScanCost}(R)$.
The planner computes $C_{\text{generic}}$ assuming average selectivity $\sigma_{\text{avg}} = \frac{1}{M}$. If $\sigma_{\text{avg}}$ is large enough, $C_{\text{generic}} = \text{SeqScanCost}(R)$.
Since $C_{\text{generic}} \le \bar{C}_{\text{custom}}$, PostgreSQL locks in the Generic Plan!

When a customer queries the rare value $r_{\text{rare}}$ (e.g., `status = 'FAILED'`, matching 1 row):

$$C_{\text{optimal}} = C_{\text{custom}}(r_{\text{rare}}) = \text{IndexScanCost} \approx \lceil \log_B(N) \rceil \times \text{random\_page\_cost} + \text{cpu\_tuple\_cost} \ll \text{SeqScanCost}(R)$$

The latency degradation factor $\Delta_{\text{degradation}}$ is:

$$\Delta_{\text{degradation}} = \frac{C_{\text{generic}}}{C_{\text{custom}}(r_{\text{rare}})} \approx \frac{N \times \text{cpu\_tuple\_cost}}{\lceil \log_B(N) \rceil \times \text{random\_page\_cost}} \approx \mathcal{O}\left(\frac{N}{\log N}\right)$$

For $N = 10,000,000$ rows, $\Delta_{\text{degradation}} > 10,000\times$, turning a 1ms query into a 10-second pool-locking outage!

### 2. Statement Cache Memory Sizing & Dynamic SQL Explosion Calculus

Let an application pool hold $N_{\text{conn}}$ connections. If queries are constructed with dynamic `IN ($1, $2, ..., $K)` clauses where $K \in [1, K_{\text{max}}]$:
The total number of unique prepared statements $S_{\text{total}}$ allocated across all connections is:

$$S_{\text{total}} = N_{\text{conn}} \times \sum_{q=1}^{Q} K_{\text{max}}(q)$$

Each prepared statement in PostgreSQL backend memory allocates an execution plan tree, parse tree, and tuple descriptor consuming an average of $M_{\text{stmt}} \approx 32\text{ KB}$ to $128\text{ KB}$.
Total memory bloat $M_{\text{total}}$:

$$M_{\text{total}} = N_{\text{conn}} \times S \times M_{\text{stmt}}$$

For $N_{\text{conn}} = 100$ backends, $Q = 20$ endpoints, and $K_{\text{max}} = 500$:

$$M_{\text{total}} = 100 \times 20 \times 500 \times 64\text{ KB} = 64,000,000\text{ KB} \approx 64\text{ GB RAM!}$$

This induces catastrophic OS OOM killing of PostgreSQL backend processes!
By enforcing `= ANY($1::UUID[])`:

$$S_{\text{total}} = N_{\text{conn}} \times Q \times 1 = 100 \times 20 \times 1 \times 64\text{ KB} = 128\text{ MB RAM} \quad (\mathbf{99.8\%\text{ memory reduction}})$$

---

## 3. Production Engine: TypeScript Implementation

Below is the complete, production-grade `AgenticPreparedStatementGuardEngine` that enforces static array parameterization, detects generic plan drift via `EXPLAIN (GENERIC_PLAN)`, governs `plan_cache_mode`, transparently recovers from SQLSTATE `0A000` / `XX000` cached plan invalidations, and validates PgBouncer transaction-mode compatibility.

```typescript
/**
 * AgenticPreparedStatementGuardEngine
 *
 * Industrial-grade governance engine for PostgreSQL prepared statements,
 * plan cache stability, parameter sniffing mitigation, and zero-downtime DDL recovery.
 */

export interface QueryPlanMetrics {
  planType: 'custom' | 'generic';
  totalCost: number;
  planNodes: string[];
  hasSequentialScanOnLargeRelation: boolean;
  costRatioGenericToCustom?: number;
}

export interface StatementInspectionResult {
  sql: string;
  isStaticSargable: boolean;
  dynamicInClauseDetected: boolean;
  recommendedSql: string;
  suggestedPlanCacheMode: 'auto' | 'force_custom' | 'force_generic';
}

export interface ExecutionResult<T> {
  rows: T[];
  planCacheModeUsed: string;
  retriesDueToPlanInvalidation: number;
  durationMs: number;
}

export class AgenticPreparedStatementGuardEngine {
  private readonly maxPlanCostRatioThreshold = 2.0;
  private readonly largeRelationCostFloor = 1000.0;

  /**
   * Inspects SQL text for dynamic IN-clause anti-patterns and rewrites them
   * into static = ANY($1) array formulations to eliminate statement cache bloat.
   */
  public inspectAndSanitizeSql(rawSql: string): StatementInspectionResult {
    // Detect dynamic IN ($1, $2, ...) clauses
    const dynamicInRegex = /\bIN\s*\(\s*\$(\d+)(?:\s*,\s*\$\d+)+\s*\)/gi;
    const hasDynamicIn = dynamicInRegex.test(rawSql);

    let sanitizedSql = rawSql;
    let isStatic = !hasDynamicIn;

    if (hasDynamicIn) {
      // Replace IN ($1, $2, ...) with = ANY($1::type[])
      // In production AST parsers (or regex), replace with the first parameter as array
      sanitizedSql = rawSql.replace(
        /\bIN\s*\(\s*(\$\d+)(?:\s*,\s*\$\d+)*\s*\)/gi,
        '= ANY($1)'
      );
    }

    // Heuristic: If query filters on skewed status/type columns, suggest force_custom
    const skewedColumnPattern = /\b(status|state|type|role|is_active|is_deleted|tenant_id)\s*=/i;
    const hasSkewedPredicate = skewedColumnPattern.test(sanitizedSql);

    return {
      sql: rawSql,
      isStaticSargable: isStatic,
      dynamicInClauseDetected: hasDynamicIn,
      recommendedSql: sanitizedSql,
      suggestedPlanCacheMode: hasSkewedPredicate ? 'force_custom' : 'auto',
    };
  }

  /**
   * Evaluates generic plan vs custom plan costs via EXPLAIN (GENERIC_PLAN, FORMAT JSON)
   * to guard against parameter sniffing flips in CI/CD performance testing.
   */
  public evaluatePlanStability(
    customPlanCost: number,
    genericPlanJson: any
  ): { stable: boolean; reason?: string } {
    const genericNode = genericPlanJson[0]?.Plan;
    if (!genericNode) {
      throw new Error('Invalid EXPLAIN JSON plan structure');
    }

    const genericTotalCost: number = genericNode['Total Cost'];
    const nodeType: string = genericNode['Node Type'];

    // Check if generic plan flips into an expensive Seq Scan on high-volume tables
    const isSeqScan = nodeType === 'Seq Scan';
    const isCostBloated = genericTotalCost > this.largeRelationCostFloor;

    if (isSeqScan && isCostBloated) {
      return {
        stable: false,
        reason: `Generic plan selects un-indexed Seq Scan (Cost: ${genericTotalCost}). Must enforce plan_cache_mode = force_custom.`,
      };
    }

    const costRatio = genericTotalCost / Math.max(customPlanCost, 0.01);
    if (costRatio > this.maxPlanCostRatioThreshold) {
      return {
        stable: false,
        reason: `Generic plan cost (${genericTotalCost}) is ${costRatio.toFixed(2)}x higher than custom plan (${customPlanCost}). Exceeds stability gate of ${this.maxPlanCostRatioThreshold}x.`,
      };
    }

    return { stable: true };
  }

  /**
   * Executes a database query with automatic SQLSTATE 0A000 / XX000 cached plan invalidation
   * recovery and transaction-scoped plan_cache_mode governance.
   */
  public async executeWithPlanGovernance<T>(
    client: {
      query: (sql: string, params?: any[]) => Promise<{ rows: T[] }>;
    },
    sql: string,
    params: any[],
    options: {
      forceCustom?: boolean;
      maxRetries?: number;
    } = {}
  ): Promise<ExecutionResult<T>> {
    const maxRetries = options.maxRetries ?? 2;
    let retries = 0;
    const startTime = Date.now();

    const planMode = options.forceCustom ? 'force_custom' : 'auto';

    while (true) {
      try {
        if (options.forceCustom) {
          // Transaction-scoped plan cache mode override
          await client.query("SET LOCAL plan_cache_mode = 'force_custom'");
        }

        const result = await client.query(sql, params);
        return {
          rows: result.rows,
          planCacheModeUsed: planMode,
          retriesDueToPlanInvalidation: retries,
          durationMs: Date.now() - startTime,
        };
      } catch (err: any) {
        // Detect PostgreSQL SQLSTATE 0A000 (feature_not_supported) or XX000 (internal_error):
        // "cached plan must not change result type" or "cached plan is invalid"
        const isPlanInvalidationError =
          err?.code === '0A000' ||
          err?.code === 'XX000' ||
          (typeof err?.message === 'string' &&
            (err.message.includes('cached plan must not change result type') ||
              err.message.includes('cached plan is invalid')));

        if (isPlanInvalidationError && retries < maxRetries) {
          retries++;
          // Invalidate backend statement plan cache and retry
          try {
            await client.query('DISCARD PLANS');
          } catch {
            // Best effort discard in case transaction block requires rollback
          }
          continue;
        }

        // Re-throw unhandled errors or exhausted retries
        throw err;
      }
    }
  }

  /**
   * Verifies PgBouncer configuration compliance for prepared statements.
   */
  public verifyPgBouncerCompliance(config: {
    poolMode: 'session' | 'transaction' | 'statement';
    maxPreparedStatements: number;
    serverResetQuery: string;
  }): { compliant: boolean; errors: string[] } {
    const errors: string[] = [];

    if (config.poolMode === 'transaction') {
      if (config.maxPreparedStatements === 0) {
        errors.push(
          "PgBouncer is in transaction mode with max_prepared_statements = 0. Applications MUST use unnamed prepared statements or simple protocol to prevent 42P05 / 26000 errors."
        );
      }
      if (!config.serverResetQuery.includes('DISCARD ALL') && !config.serverResetQuery.includes('DISCARD PLANS')) {
        errors.push(
          "PgBouncer server_reset_query must include 'DISCARD ALL' or 'DISCARD PLANS' to purge prepared statements when backends are returned to the pool."
        );
      }
    }

    return {
      compliant: errors.length === 0,
      errors,
    };
  }
}
```

---

## 4. The 6-State Prepared Statement Lifecycle Finite-State Machine (FSM)

```
       ┌────────────────────────────────────────────────────────┐
       │                                                        │
       ▼                                                        │
┌──────────────┐   Execution #1..#5    ┌───────────────────┐    │ SQLSTATE 0A000
│  UNPREPARED  │ ─────────────────────►│  CUSTOM_PLANNING  │    │ Cached Plan
│  STATEMENT   │                       │ (Literal Bound)   │    │ Invalidation
└──────────────┘                       └─────────┬─────────┘    │
                                                 │              │
                                   Execution #6  │ Cost Comp   │
                                                 ▼              │
                                       ┌───────────────────┐    │
                                       │ GENERIC_EVALUATE  │    │
                                       └─────────┬─────────┘    │
                                                 │              │
                    C_generic <= C_custom        │  C_generic > │
                                                 │  C_custom    │
                          ┌──────────────────────┴───────┐      │
                          │                              │      │
                          ▼                              ▼      │
               ┌─────────────────────┐        ┌─────────────────┴─┐
               │   GENERIC_PLAN_PIN  │        │ CUSTOM_PERSISTENT │
               │ (Placeholder Bound) │        │ (Forced Custom)   │
               └──────────┬──────────┘        └─────────┬─────────┘
                          │                             │
                          └──────────────┬──────────────┘
                                         │ DDL / Catalog Invalidation
                                         ▼
                              ┌────────────────────┐
                              │ PLAN_INVALIDATED   │
                              │ (DISCARD PLANS)    │
                              └────────────────────┘
```

### Lifecycle State Invariants

| State | Entry Condition | Invariant Preserved | Exit Action |
| :--- | :--- | :--- | :--- |
| `UNPREPARED_STATEMENT` | Client initiates query execution with parameters | Driver assigns anonymous portal or named statement key | Parse & analyze SQL AST |
| `CUSTOM_PLANNING` | Execution count $N \in [1, 5]$ | Generates customized plan tailored to parameter values $p_1..p_K$ | Log plan cost to rolling average accumulator |
| `GENERIC_EVALUATE` | Execution count reaches threshold $N = 6$ | Generates parameter-agnostic generic plan with placeholders | Compare $C_{\text{generic}}$ against $\bar{C}_{\text{custom}}$ |
| `GENERIC_PLAN_PIN` | $C_{\text{generic}} \le \bar{C}_{\text{custom}}$ | Bound to generic execution tree for connection lifetime | Invalidate on catalog change or `DISCARD PLANS` |
| `CUSTOM_PERSISTENT` | $C_{\text{generic}} > \bar{C}_{\text{custom}}$ or `plan_cache_mode = force_custom` | Every execution plans with actual runtime parameter literals | Retain custom planner pathway |
| `PLAN_INVALIDATED` | DDL migration alters underlying schema (SQLSTATE `0A000`) | Purges stale execution tree via `DISCARD PLANS` | Re-enter `UNPREPARED_STATEMENT` |

---

## 5. Machine-Verifiable Definition of Done (DoD) & Anti-Patterns Matrix

| Quality Gate | Pass Criterion | Automated Enforcement Rule |
| :--- | :--- | :--- |
| **Gate 0: Static Array Sargability** | Zero dynamic `IN ($1..$N)` clauses across repositories | `rg -i "\bIN\s*\(\s*\$\d+,\s*\$\d+" src/` returns 0 hits |
| **Gate 1: Skewed Predicate Fencing** | 100% of queries on skewed state columns use `force_custom` or un-prepared queries | Static AST linter flags un-governed queries on indexed status columns |
| **Gate 2: PgBouncer Multiplexing** | Zero named statements in transaction pooling unless PgBouncer 1.21+ enabled | PgBouncer audit asserts `max_prepared_statements >= 100` or driver cache size = 0 |
| **Gate 3: DDL Resilience & Recovery** | Automated retry on SQLSTATE `0A000` / `XX000` with `DISCARD PLANS` | Connection pool tests simulate table alterations during concurrent load |
| **Gate 4: CI Generic Plan Testing** | CI runs `EXPLAIN (GENERIC_PLAN)`: $C_{\text{generic}} / C_{\text{custom}} \le 2.0$ | Automated test suite fails if generic plan introduces sequential scan |
| **Gate 5: Memory Leak Watchdog** | Total `pg_prepared_statements` per backend connection bounded to $\le 200$ | Monitoring alert on `SELECT COUNT(*) FROM pg_prepared_statements > 200` |

### The 5 Hall of Shame Prepared Statement Traps

- ❌ **Anti-Pattern 1: Dynamic Parameter Concatenation in SQL Loops**:
  ```typescript
  // BAD: Dynamic parameter list generates unique statement names per array size!
  const query = `SELECT * FROM items WHERE id IN (${ids.map((_, i) => `$${i + 1}`).join(',')})`;
  ```
  ```typescript
  // GOOD: Single static parameter using Postgres array containment
  const query = `SELECT * FROM items WHERE id = ANY($1::UUID[])`;
  ```

- ❌ **Anti-Pattern 2: Unchecked Parameter Sniffing on State Machines**:
  ```sql
  -- BAD: Default auto plan switches to Seq Scan on execution #6 for rare 'DEAD_LETTER' status
  SELECT * FROM jobs WHERE queue = $1 AND status = $2;
  ```
  ```sql
  -- GOOD: Force custom plan evaluation on skewed state-machine queries
  BEGIN;
  SET LOCAL plan_cache_mode = 'force_custom';
  SELECT * FROM jobs WHERE queue = $1 AND status = $2;
  COMMIT;
  ```

- ❌ **Anti-Pattern 3: Named Prepared Statements in PgBouncer Transaction Pooling**:
  ```go
  // BAD: Named prepared statement collides across shared backend connections
  _, err := db.Prepare(ctx, "stmt_get_user", "SELECT * FROM users WHERE id = $1")
  ```
  ```go
  // GOOD: Use pgx unnamed statement cache or simple protocol in transaction pooling
  config.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
  ```

- ❌ **Anti-Pattern 4: Unhandled DDL Cached Plan Invalidation**:
  ```typescript
  // BAD: Application crashes permanently after DDL migration until process restart
  try {
    return await pool.query(cachedStmt, [id]);
  } catch (err) {
    throw err; // Crashes with "cached plan must not change result type"
  }
  ```
  ```typescript
  // GOOD: Intercept SQLSTATE 0A000, discard plans, and transparently retry
  try {
    return await pool.query(cachedStmt, [id]);
  } catch (err: any) {
    if (err.code === '0A000' || err.code === 'XX000') {
      await pool.query('DISCARD PLANS');
      return await pool.query(cachedStmt, [id]);
    }
    throw err;
  }
  ```

- ❌ **Anti-Pattern 5: Testing Only Custom Plans with Literals in CI**:
  ```sql
  -- BAD: EXPLAIN ANALYZE with literal evaluates custom plan; masks production generic plan collapse
  EXPLAIN ANALYZE SELECT * FROM orders WHERE tenant_id = 42 AND status = 'PENDING';
  ```
  ```sql
  -- GOOD: Test generic plan explicitly in CI performance tests (PostgreSQL 16+)
  EXPLAIN (GENERIC_PLAN, BUFFERS) SELECT * FROM orders WHERE tenant_id = $1 AND status = $2;
  ```
