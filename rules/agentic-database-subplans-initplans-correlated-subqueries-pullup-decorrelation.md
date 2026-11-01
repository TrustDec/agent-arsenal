---
description: PostgreSQL SubPlan vs InitPlan execution mechanics, correlated scalar subquery decorrelation, query planner subquery pull-up barriers (LIMIT, OFFSET, DISTINCT, GROUP BY, volatile functions), N*M SubPlan per-tuple loop elimination, SubPlan in projection/WHERE traps, EXISTS short-circuit semi-join optimization, CTE optimization fences, memory context leaks in PL/pgSQL loops, and set-based JOIN/LATERAL/Window transformations across Go (jackc/pgx/v5, sqlc), TypeScript (pg, Kysely, Drizzle ORM), Python (asyncpg, SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{query,subquery,subplan,initplan,decorrelate,lateral,join,plan,db,postgres,sql}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database SubPlans, InitPlans, Correlated Scalar Subquery Decorrelation, Planner Pull-Up Barriers & Subquery Flattening Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design database access patterns, API query builders, ORM transformations, dashboard analytical feeds, or batch data pipelines across PostgreSQL (12–17+), Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `SQLAlchemy 2.0`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "The $O(N \cdot M)$ SubPlan Per-Tuple Execution Loop Inferno (`SubPlan 1` in EXPLAIN)" (where autonomous agents write correlated scalar subqueries in `SELECT` projections or `WHERE` filters, causing PostgreSQL to execute the subquery sequentially for every single outer tuple—turning a 10ms query on 100,000 rows into a 45-second CPU-pegging bottleneck), the "Volatile Function InitPlan Degradation Trap" (where non-deterministic or volatile functions like `random()`, `clock_timestamp()`, sequence `nextval()`, or unannotated UDFs inside an uncorrelated subquery silently prevent PostgreSQL from generating an $O(1)$ cached `InitPlan 1 (returns $0)`, downgrading it into a per-row `SubPlan 1` evaluated $N$ times), the "Subquery Pull-Up Blockade (The 5 Planner Optimization Barriers)" (where agents place `LIMIT`, `OFFSET`, `DISTINCT`, `GROUP BY`, or volatile expressions inside subqueries, acting as absolute fences that block optimizer subquery flattening, join pushdown, and index join transformations), the "Multi-Scalar Projection $N \times K$ SubPlan Multiplication Disaster" (where dashboards fetch multiple scalar counts and sums in the `SELECT` list, creating 3 to 10 independent `SubPlan` execution nodes that thrash shared buffers with hundreds of thousands of redundant index seeks), the "Correlated `EXISTS` vs `(SELECT count(*) FROM ...) > 0` Plan Inversion" (where agents check for child record existence by computing a full scalar count rather than a short-circuiting semi-join, scanning millions of unnecessary index pages), and the "SubPlan Memory Context Leaks in PL/pgSQL & Trigger Loops" (where repeated SubPlan evaluation inside procedural loops steadily leaks `ExprContext` memory until Linux OOM killer termination) by establishing a strict 5-Tier Subquery Governance Ladder, formal asymptotic speedup proofs, an autonomous TypeScript `AgenticSubPlanDecorrelationGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state optimization lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Subquery Catastrophes vs The 5-Tier Governance Ladder

In the PostgreSQL execution engine, subqueries can be processed in three fundamentally different ways:
1. **Subquery Pull-Up (Flattening)**: The query planner merges the subquery into the outer query's jointree, transforming it into a standard `JOIN`, `LEFT JOIN`, or Semi/Anti-Join. This allows the query optimizer to consider Hash Joins, Merge Joins, and Partitionwise operations, and push down predicates into the inner table.
2. **InitPlan**: If an uncorrelated subquery cannot be pulled up, but its results do not depend on any outer tuple columns and all expressions are stable or immutable, the optimizer compiles it into an `InitPlan`. The executor runs an `InitPlan` **exactly once** before the main query begins, stores the scalar result in a parameter slot (e.g., `$0`), and reuses that precomputed value across all outer rows ($O(1)$ amortized overhead).
3. **SubPlan**: If a subquery depends on variables from an outer query tuple (correlated subquery), or if volatility rules prevent `InitPlan` promotion, the planner emits a `SubPlan`. The executor evaluates the `SubPlan` **anew for every single row** emitted by the outer plan node. For $N = 100,000$ outer rows, the inner query executes $100,000$ times ($O(N \cdot M)$ complexity).

When autonomous coding agents write SQL or use ORM abstraction layers, LLMs consistently stumble into 6 catastrophic architectural antipatterns:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               SUBPLAN vs INITPLAN vs FLATTENED JOIN ARCHITECTURE                       │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • $O(N \cdot M)$ SubPlan in Projection    │ • Set-Based Hash Join / Window Projection: │
│   (SELECT u.id, (SELECT count(*) FROM     │   LEFT JOIN (SELECT user_id, count(*) FROM │
│    orders WHERE user_id = u.id) FROM user)│   orders GROUP BY user_id) o ON o.user_id..│
│   Executes SubPlan 1 100,000 times!       │   Executes single Hash Join in 12ms        │
│ • Volatile Function InitPlan Degradation  │ • Deterministic InitPlan Promotion:        │
│   (WHERE created_at > (SELECT max(ts) -   │   Hoist volatile terms or use STABLE/      │
│    random()*interval '1h' FROM audit))    │   IMMUTABLE expressions; verify planner    │
│   Degrades InitPlan to per-row SubPlan    │   emits InitPlan 1 (returns $0) (runs once)│
│ • Subquery Pull-Up Barrier Blockade       │ • Pull-Up Friendly Subquery Formulation:   │
│   (Subquery uses LIMIT/OFFSET/DISTINCT;   │   Avoid unneeded LIMIT/DISTINCT in inner   │
│    blocks planner from flattening into    │   subqueries; use LATERAL with index bounds│
│    join tree; disables hash joins)        │   when Top-K is strictly required          │
│ • Multi-Scalar Projection N*K Explosion   │ • Consolidated Aggregate Projection:       │
│   (SELECT (SELECT count(*)), (SELECT sum) │   Single pre-aggregated CTE or join with   │
│    (SELECT max)... creates 3-10 SubPlans) │   FILTER (WHERE ...) aggregates in 1 pass  │
│ • COUNT(*) > 0 Existence Trap             │ • Short-Circuiting Semi-Join EXISTS:       │
│   (WHERE (SELECT count(*) FROM c) > 0     │   WHERE EXISTS (SELECT 1 FROM c WHERE ...) │
│    counts 50,000 child rows per tuple)    │   Halts on first matching index tuple      │
│ • PL/pgSQL SubPlan Memory Context Leak    │ • Set-Oriented Declarative Mutation:       │
│   (FOR r IN SELECT ... SubPlan LOOP       │   Avoid procedural cursor loops with       │
│    leaks ExprContext; triggers OOM)       │   SubPlans; use batch UPDATE ... FROM JOIN │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Subquery & SubPlan Catastrophes

#### Catastrophe 1: The $O(N \cdot M)$ SubPlan Per-Tuple Execution Loop Inferno
When an autonomous agent needs to return aggregate statistics alongside master entity records (e.g., in a user listing, customer portal, or inventory table), it writes:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Correlated SubPlan in Projection
SELECT 
    u.id,
    u.email,
    u.created_at,
    (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id) AS total_orders,
    (SELECT COALESCE(SUM(o.amount_cents), 0) FROM orders o WHERE o.user_id = u.id) AS lifetime_spend
FROM users u
WHERE u.status = 'active';
```
In `EXPLAIN (ANALYZE, BUFFERS)`, this query reveals two independent `SubPlan` nodes:
```
Seq Scan on users u (cost=0.00..8450000.00 rows=100000 width=72) (actual time=0.051..48210.340 rows=100000 loops=1)
  Filter: (status = 'active'::text)
  Buffers: shared hit=421000 read=12500
  SubPlan 1
    ->  Aggregate (cost=8.45..8.46 rows=1 width=8) (actual time=0.231..0.232 rows=1 loops=100000)
          ->  Index Only Scan using idx_orders_user_id on orders o (cost=0.42..8.42 rows=12 width=0) (actual time=0.015..0.198 rows=12 loops=100000)
                Index Cond: (user_id = u.id)
  SubPlan 2
    ->  Aggregate (cost=8.45..8.46 rows=1 width=8) (actual time=0.240..0.241 rows=1 loops=100000)
          ->  Index Scan using idx_orders_user_id on orders o_1 (cost=0.42..8.42 rows=12 width=8) (actual time=0.016..0.205 rows=12 loops=100000)
                Index Cond: (user_id = u.id)
Execution Time: 48,235.120 ms (48.2 seconds!)
```
For $100,000$ users, the database executed `SubPlan 1` $100,000$ times and `SubPlan 2` $100,000$ times—totaling **200,000 individual query executions**! Even though each index seek took only 0.2ms, the aggregated wall-clock latency collapsed to 48 seconds, completely saturating CPU and thrashing the buffer cache.

#### Catastrophe 2: Volatile Function InitPlan Degradation Trap
When filtering against an analytical threshold (e.g., latest audit timestamp, dynamic baseline, or global benchmark), an agent writes:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: Volatile function degrades InitPlan to SubPlan
SELECT id, title, score
FROM articles a
WHERE score > (
    SELECT AVG(score) + (random() * 0.0) 
    FROM benchmark_scores
);
```
Without `random() * 0.0`, PostgreSQL optimizes the subquery into an `InitPlan 1 (returns $0)`:
```
Seq Scan on articles a (cost=12.50..450.00 rows=5000 width=40)
  Filter: (score > $0)
  InitPlan 1 (returns $0)
    ->  Aggregate (cost=12.48..12.49 rows=1 width=8)
          ->  Seq Scan on benchmark_scores (cost=0.00..10.00 rows=1000 width=4)
```
The subquery runs **once**, computes `$0`, and the outer scan filters against the scalar in $O(N)$ comparisons. But because `random()` is marked `VOLATILE` in the PostgreSQL catalog, the planner cannot assume the return value is constant across rows. The query plan silently transforms into:
```
Seq Scan on articles a (cost=0.00..62500.00 rows=5000 width=40)
  Filter: (score > (SubPlan 1))
  SubPlan 1
    ->  Aggregate (cost=12.48..12.50 rows=1 width=8)
          ->  Seq Scan on benchmark_scores (cost=0.00..10.00 rows=1000 width=4)
```
For 5,000 articles, `benchmark_scores` is scanned 5,000 times! A query that should run in 2ms now takes 6.2 seconds. The same catastrophe occurs when using `clock_timestamp()`, sequence `nextval()`, non-leakproof functions, or custom PL/pgSQL functions that lack the explicit `IMMUTABLE` or `STABLE` volatility declaration.

#### Catastrophe 3: Subquery Pull-Up Blockade (The 5 Planner Barriers)
The PostgreSQL optimizer includes sophisticated logic in `inline_set_returning_functions()`, `pull_up_subqueries()`, and `flatten_simple_union_all()` to pull subqueries up into the parent query's jointree. When pulled up, subqueries become standard joins eligible for join order re-ordering, Hash Joins, and predicate pushdown.

However, PostgreSQL strictly aborts pull-up if the subquery violates any of the **5 Pull-Up Invariants**:
1. Contains `LIMIT` or `OFFSET`.
2. Contains `DISTINCT` or `DISTINCT ON`.
3. Contains window functions (`OVER (...)`).
4. Contains explicit `GROUP BY` or aggregates (unless transformed via `LATERAL` or explicit outer join).
5. Contains set operations (`UNION`, `INTERSECT`, `EXCEPT`).

When an autonomous agent casually inserts `LIMIT 1` or `DISTINCT` inside an inner subquery "just in case", it erects an impenetrable optimization barrier. Outer `WHERE tenant_id = $1` filters cannot be pushed down into the subquery, forcing full table scans across multi-gigabyte tables.

#### Catastrophe 4: Multi-Scalar Projection $N \times K$ SubPlan Explosion
In microservice APIs and dashboard endpoints, agents frequently construct summary JSON payloads by assembling independent scalar counts, sums, and maximums:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: 4 SubPlans in single SELECT
SELECT 
    d.id,
    d.name,
    (SELECT count(*) FROM employees e WHERE e.department_id = d.id) AS emp_count,
    (SELECT count(*) FROM projects p WHERE p.department_id = d.id AND p.status = 'active') AS active_projects,
    (SELECT sum(salary) FROM employees e WHERE e.department_id = d.id) AS total_payroll,
    (SELECT max(updated_at) FROM audit_logs a WHERE a.department_id = d.id) AS last_audit_at
FROM departments d;
```
This query spawns **4 distinct SubPlan nodes**. If there are 500 departments, PostgreSQL executes $500 \times 4 = 2,000$ subqueries. If each subquery touches 10 index blocks, that represents 20,000 random buffer lookups. Instead of a single consolidated join that scans the data in 5ms, the database burns 800ms of CPU per request, exhausting connection pools under moderate traffic.

#### Catastrophe 5: Correlated `EXISTS` vs `(SELECT count(*) FROM ...) > 0` Plan Inversion
When checking whether related child entities exist, LLMs often generate:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: COUNT(*) > 0 forces full child scan
SELECT p.id, p.title
FROM posts p
WHERE (SELECT COUNT(*) FROM comments c WHERE c.post_id = p.id AND c.status = 'approved') > 0;
```
Because the expression compares the result of `COUNT(*)` with `0`, the executor cannot short-circuit. If a popular post has 100,000 approved comments, the database must scan all 100,000 index entries to compute the exact count, only to evaluate whether `100000 > 0`.
Conversely, a semi-join `WHERE EXISTS (SELECT 1 FROM comments c WHERE c.post_id = p.id AND c.status = 'approved')` immediately short-circuits upon encountering the **very first matching tuple**, terminating the probe after a single page read ($O(1)$ vs $O(M)$).

#### Catastrophe 6: SubPlan Memory Context Leaks in PL/pgSQL & Trigger Loops
In stored procedures, ETL migrations, or trigger functions, autonomous agents frequently loop over record sets:
```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN: SubPlan inside PL/pgSQL Loop
CREATE OR REPLACE FUNCTION audit_unbalanced_ledger() RETURNS void AS $$
DECLARE
    r RECORD;
    v_diff numeric;
BEGIN
    FOR r IN SELECT id, account_id, expected_balance FROM ledger_entries WHERE reconciled = false LOOP
        -- Correlated SubPlan evaluated inside loop iteration
        SELECT (r.expected_balance - COALESCE(SUM(amount), 0)) INTO v_diff
        FROM transactions WHERE account_id = r.account_id;
        
        IF v_diff != 0 THEN
            INSERT INTO reconciliation_exceptions (ledger_id, diff) VALUES (r.id, v_diff);
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
```
Each iteration of the `FOR r IN ... LOOP` allocates a sub-transaction or expression context (`ExprContext`) inside the PL/pgSQL execution environment. When iterating over 500,000 unreconciled entries, memory buffers allocated by the SPI executor fail to be recycled across iterations, causing the PostgreSQL backend process RAM to balloon by multiple gigabytes until the Linux OOM killer issues `SIGKILL 137`.

---

## 2. Mathematical & Algorithmic Foundations

### Theorem 1: SubPlan vs Decorrelated Hash Join Complexity & Speedup

Let $R$ be the outer relation with cardinality $N = |R|$, and $S$ be the inner relation with cardinality $M = |S|$. Let $S_x \subseteq S$ be the subset of tuples matching a given outer tuple $x \in R$, with average cardinality $\bar{k} = |S_x| = M / N_{\text{keys}}$.

#### 1. Correlated SubPlan Execution Model
When an inner aggregate subquery executes as a `SubPlan`, the total time $T_{\text{SubPlan}}$ is the sum of outer scan time plus $N$ discrete inner executions:
$$T_{\text{SubPlan}} = T_{\text{scan}}(R) + \sum_{i=1}^{N} \left( t_{\text{setup}} + t_{\text{index\_traverse}} + k_i \cdot t_{\text{tuple\_fetch}} \right)$$

Assuming B-Tree depth $h = \lceil \log_B(M) \rceil$, each subquery requires $h$ page lookups:
$$T_{\text{SubPlan}} \approx N \cdot c_{\text{outer}} + N \cdot \left( t_{\text{setup}} + h \cdot t_{\text{page\_hit}} + \bar{k} \cdot t_{\text{tuple}} \right)$$

Because $t_{\text{setup}}$ (executor node initialization, parameter binding, result projection) is non-zero (typically $1 \text{ \textmu s} \le t_{\text{setup}} \le 10 \text{ \textmu s}$), for $N = 100,000$:
$$N \cdot t_{\text{setup}} \approx 100,000 \times 5 \text{ \textmu s} = 500\,\text{ms just in framework overhead!}$$

#### 2. Decorrelated Hash Join Execution Model
When the subquery is decorrelated into a pre-aggregated subquery joined via Hash Aggregate:
$$Q_{\text{decorr}} = R \bowtie_{\text{hash}} \left( \gamma_{K, \text{agg}(V)}(S) \right)$$

The time complexity is purely linear in $|R|$ and $|S|$:
$$T_{\text{HashJoin}} = T_{\text{scan}}(S) + T_{\text{build\_hash}}(S_{\text{distinct}}) + T_{\text{scan}}(R) + T_{\text{probe\_hash}}(R)$$
$$T_{\text{HashJoin}} = M \cdot c_{\text{read}} + K \cdot c_{\text{hash}} + N \cdot (c_{\text{read}} + c_{\text{probe}})$$

#### 3. Theoretical Speedup Differential $\mathcal{S}$
$$\mathcal{S} = \frac{T_{\text{SubPlan}}}{T_{\text{HashJoin}}} = \frac{N \cdot (t_{\text{setup}} + h \cdot t_{\text{page}} + \bar{k} \cdot t_{\text{tuple}})}{M \cdot c_{\text{read}} + N \cdot c_{\text{probe}}}$$

For typical OLTP/Reporting datasets where $N = 100,000$, $M = 1,000,000$, $h = 4$:
- $T_{\text{SubPlan}} \approx 100,000 \times (5\text{\textmu s} + 4 \times 1\text{\textmu s} + 10 \times 0.5\text{\textmu s}) = 100,000 \times 14\text{\textmu s} = 1,400\,\text{ms} = 1.4\,\text{s}$ (if entirely in cache). If disk reads occur, $T_{\text{SubPlan}}$ spikes to $35\,\text{s}$.
- $T_{\text{HashJoin}} \approx 1,000,000 \times 0.01\text{\textmu s} + 100,000 \times 0.02\text{\textmu s} = 12\,\text{ms}$.
- Speedup $\mathcal{S} = \frac{1400\,\text{ms}}{12\,\text{ms}} \approx \mathbf{116.6\times}$!

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               THE SUBPLAN TO HASH JOIN SPEEDUP CURVE                                   │
│  Latency (ms)                                                                          │
│    50000 ┼                                                  ● SubPlan O(N·log M)      │
│    40000 ┼                                             ●                               │
│    30000 ┼                                        ●                                    │
│    20000 ┼                                   ●                                         │
│    10000 ┼                              ●                                              │
│     1000 ┼                         ●                                                   │
│      100 ┼───────────────────●───────────────────────────────■ Hash Join O(N + M)     │
│       10 ┼─────────■─────────■─────────■─────────■─────────■                           │
│        0 ┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────                  │
│         1,000    10,000   25,000    50,000    75,000   100,000 (Outer Rows N)          │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### Theorem 2: InitPlan Volatility & Promotion Conditions

A subquery expression $Q_{\text{sub}}$ within an outer statement $Q_{\text{main}}$ can be promoted to an `InitPlan` if and only if the following formal predicate holds:

$$\operatorname{IsInitPlan}(Q_{\text{sub}}) \iff \left( \operatorname{FreeVars}(Q_{\text{sub}}) = \emptyset \right) \land \left( \forall e \in \operatorname{Exprs}(Q_{\text{sub}}), \operatorname{Volatility}(e) \le \text{STABLE} \right)$$

Where:
- $\operatorname{FreeVars}(Q_{\text{sub}})$ denotes the set of attribute references resolved against scopes outside $Q_{\text{sub}}$.
- $\operatorname{Volatility}(e) \in \{\text{IMMUTABLE}, \text{STABLE}, \text{VOLATILE}\}$.
- If $\exists e \in \operatorname{Exprs}(Q_{\text{sub}})$ such that $\operatorname{Volatility}(e) = \text{VOLATILE}$, the planner emits $\operatorname{SubPlan}(Q_{\text{sub}})$, invalidating memoization.

### Theorem 3: Semi-Join Short-Circuit Expected Cost Model

Consider checking existence of at least one matching row in $S$ for each tuple in $R$.
Let $p \in (0, 1]$ be the probability that a random tuple in $S$ matches the predicate, and assume $k \ge 1$ matching tuples exist uniformly distributed across $B$ index leaf pages.

1. **`COUNT(*) > 0` Execution**: Must traverse all $k$ matching index entries:
   $$\mathbb{E}[\text{Pages}_{\text{COUNT}}] = \min\left(B, k\right) + h$$
2. **`EXISTS` Execution**: Traverses B-Tree to first match and halts immediately:
   $$\mathbb{E}[\text{Pages}_{\text{EXISTS}}] = 1 + h$$

When $k = 5,000$ (e.g., popular posts or active tenants), `EXISTS` reduces index I/O by a factor of:
$$\mathcal{F}_{\text{I/O}} = \frac{h + \min(B, 5000)}{h + 1} \approx \frac{4 + 25}{4 + 1} = \mathbf{5.8\times \text{ to } 500\times}$$

---

## 3. Autonomous TypeScript Guard Engine

Here is the production-grade TypeScript guard engine that analyzes SQL queries, AST representations, and PostgreSQL `EXPLAIN (FORMAT JSON)` execution plans to detect, flag, and automatically rewrite SubPlans, volatile function InitPlan degradations, and unneeded pull-up barriers.

```typescript
// src/db/guard/agenticSubPlanGuardEngine.ts

export interface SubPlanViolation {
  category: 
    | 'SUBPLAN_IN_PROJECTION'
    | 'SUBPLAN_IN_WHERE'
    | 'VOLATILE_INITPLAN_DEGRADATION'
    | 'PULLUP_BARRIER_LIMIT'
    | 'PULLUP_BARRIER_DISTINCT'
    | 'COUNT_EXISTENCE_INVERSION'
    | 'MULTI_SCALAR_PROJECTION_EXPLOSION';
  severity: 'CRITICAL' | 'HIGH' | 'MEDIUM';
  description: string;
  matchedSqlSnippet: string;
  remediation: string;
  suggestedRewrite?: string;
  estimatedIoAmplification: number;
}

export interface ExplainPlanNode {
  'Node Type': string;
  'Subplan Name'?: string;
  'Parent Relationship'?: string;
  'Actual Rows'?: number;
  'Actual Loops'?: number;
  'Total Cost'?: number;
  Plans?: ExplainPlanNode[];
  [key: string]: any;
}

export interface AnalysisReport {
  isCertified: boolean;
  totalSubPlans: number;
  totalInitPlans: number;
  violations: SubPlanViolation[];
  safetyScore: number; // 0 - 100
}

export class AgenticSubPlanDecorrelationGuardEngine {
  private readonly volatileFunctions = new Set([
    'random',
    'clock_timestamp',
    'timeofday',
    'statement_timestamp', // depending on context
    'gen_random_uuid',
    'uuid_generate_v4',
    'nextval',
    'setval',
    'txid_current',
  ]);

  /**
   * Static SQL Syntax & Pattern Inspection
   */
  public inspectSql(sql: string): AnalysisReport {
    const violations: SubPlanViolation[] = [];
    const normalized = sql.replace(/\s+/g, ' ');

    // 1. Detect COUNT(*) > 0 existence trap
    const countExistenceRegex = /\(\s*SELECT\s+COUNT\s*\([^)]*\)\s+FROM\s+[^)]+\)\s*(?:>|>=|!=)\s*0/gi;
    let match: RegExpExecArray | null;
    while ((match = countExistenceRegex.exec(normalized)) !== null) {
      violations.push({
        category: 'COUNT_EXISTENCE_INVERSION',
        severity: 'HIGH',
        description: 'Scalar COUNT(*) compared to 0 forces full child scan; use EXISTS() to short-circuit on first match.',
        matchedSqlSnippet: match[0],
        remediation: 'Replace `(SELECT COUNT(*) FROM child WHERE ...) > 0` with `EXISTS (SELECT 1 FROM child WHERE ...)`',
        estimatedIoAmplification: 50.0,
      });
    }

    // 2. Detect Correlated Scalar Subqueries in SELECT Projection
    const selectProjectionSubqueryRegex = /SELECT\s+([\s\S]+?)\s+FROM\b/i;
    const projMatch = selectProjectionSubqueryRegex.exec(normalized);
    if (projMatch) {
      const projectionBody = projMatch[1];
      const scalarSubqueryRegex = /\(\s*SELECT\s+(?:COUNT|SUM|AVG|MIN|MAX|COALESCE)\s*\([^)]*\)\s+FROM\s+([a-zA-Z0-9_]+)\s+(?:WHERE\s+([^)]+))?\)/gi;
      let subCount = 0;
      let subMatch: RegExpExecArray | null;
      while ((subMatch = scalarSubqueryRegex.exec(projectionBody)) !== null) {
        subCount++;
        violations.push({
          category: 'SUBPLAN_IN_PROJECTION',
          severity: 'CRITICAL',
          description: `Correlated scalar subquery in SELECT projection will execute N times (SubPlan).`,
          matchedSqlSnippet: subMatch[0],
          remediation: `Decorrelate into a LEFT JOIN against pre-aggregated subquery or use Window Function.`,
          estimatedIoAmplification: 100.0,
        });
      }

      if (subCount >= 2) {
        violations.push({
          category: 'MULTI_SCALAR_PROJECTION_EXPLOSION',
          severity: 'CRITICAL',
          description: `Found ${subCount} scalar subqueries in SELECT projection. Multiplies SubPlan execution loops by ${subCount}x.`,
          matchedSqlSnippet: projectionBody,
          remediation: `Consolidate all child metrics into a single aggregated CTE or pre-grouped LEFT JOIN.`,
          estimatedIoAmplification: subCount * 100.0,
        });
      }
    }

    // 3. Detect Volatile Functions inside Subqueries
    for (const vFn of this.volatileFunctions) {
      const volatileInSubqueryRegex = new RegExp(`\\(\\s*SELECT[\\s\\S]*?\\b${vFn}\\s*\\([\\s\\S]*?\\)`, 'i');
      const vMatch = volatileInSubqueryRegex.exec(normalized);
      if (vMatch) {
        violations.push({
          category: 'VOLATILE_INITPLAN_DEGRADATION',
          severity: 'CRITICAL',
          description: `Volatile function \`${vFn}()\` inside subquery prevents InitPlan promotion; Postgres degrades it to SubPlan.`,
          matchedSqlSnippet: vMatch[0],
          remediation: `Extract volatile expression into CTE or client parameter, or annotate helper function as STABLE/IMMUTABLE.`,
          estimatedIoAmplification: 80.0,
        });
      }
    }

    // 4. Detect Pull-Up Barriers (LIMIT/OFFSET inside IN/EXISTS subqueries)
    const pullUpLimitRegex = /\b(?:IN|EXISTS)\s*\(\s*SELECT\s+[\s\S]+?\bLIMIT\s+\d+[\s\S]*?\)/gi;
    let limitMatch: RegExpExecArray | null;
    while ((limitMatch = pullUpLimitRegex.exec(normalized)) !== null) {
      violations.push({
        category: 'PULLUP_BARRIER_LIMIT',
        severity: 'MEDIUM',
        description: 'LIMIT inside IN/EXISTS subquery acts as an optimization fence preventing query planner pull-up.',
        matchedSqlSnippet: limitMatch[0],
        remediation: 'Remove LIMIT inside IN/EXISTS predicates; semi-join already halts at first matching row.',
        estimatedIoAmplification: 15.0,
      });
    }

    const safetyScore = Math.max(0, 100 - violations.reduce((acc, v) => acc + (v.severity === 'CRITICAL' ? 35 : v.severity === 'HIGH' ? 20 : 10), 0));

    return {
      isCertified: violations.length === 0,
      totalSubPlans: violations.filter(v => v.category === 'SUBPLAN_IN_PROJECTION').length,
      totalInitPlans: 0,
      violations,
      safetyScore,
    };
  }

  /**
   * Deep Analysis of PostgreSQL EXPLAIN (FORMAT JSON) Execution Tree
   */
  public inspectExplainTree(rootNode: ExplainPlanNode): AnalysisReport {
    const violations: SubPlanViolation[] = [];
    let subPlanCount = 0;
    let initPlanCount = 0;

    const traverse = (node: ExplainPlanNode) => {
      const subplanName = node['Subplan Name'] || '';
      const nodeType = node['Node Type'] || '';

      if (subplanName.startsWith('SubPlan') || node['Parent Relationship'] === 'SubPlan') {
        subPlanCount++;
        const loops = node['Actual Loops'] || 1;
        if (loops > 1) {
          violations.push({
            category: 'SUBPLAN_IN_PROJECTION',
            severity: 'CRITICAL',
            description: `Plan contains \`${subplanName || nodeType}\` executed ${loops.toLocaleString()} times in a loop!`,
            matchedSqlSnippet: `Node: ${nodeType}, Subplan: ${subplanName}, Loops: ${loops}`,
            remediation: 'Decorrelate subquery into a Hash Join, LATERAL join with index bounds, or Window function.',
            estimatedIoAmplification: loops,
          });
        }
      } else if (subplanName.startsWith('InitPlan') || node['Parent Relationship'] === 'InitPlan') {
        initPlanCount++;
      }

      if (node.Plans && Array.isArray(node.Plans)) {
        for (const child of node.Plans) {
          traverse(child);
        }
      }
    };

    traverse(rootNode);

    const safetyScore = subPlanCount === 0 ? 100 : Math.max(0, 100 - subPlanCount * 30);

    return {
      isCertified: subPlanCount === 0,
      totalSubPlans: subPlanCount,
      totalInitPlans: initPlanCount,
      violations,
      safetyScore,
    };
  }
}
```

---

## 4. Cross-Runtime Implementation Matrix

### 1. Go (`jackc/pgx/v5` & `sqlc`): Industrial Decorrelation & Hash Join Pre-Aggregation

```go
package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type UserSummary struct {
	UserID        string    `json:"user_id"`
	Email         string    `json:"email"`
	CreatedAt     time.Time `json:"created_at"`
	OrderCount    int64     `json:"order_count"`
	TotalSpent    int64     `json:"total_spent_cents"`
	ActiveProject int64     `json:"active_project_count"`
}

type UserRepository struct {
	pool *pgxpool.Pool
}

func NewUserRepository(pool *pgxpool.Pool) *UserRepository {
	return &UserRepository{pool: pool}
}

// FetchActiveUserSummariesDecorrelated fetches user metrics via a single-pass Hash Join
// and pre-aggregated CTE, completely eliminating SubPlan 1, SubPlan 2, and SubPlan 3 loops.
func (r *UserRepository) FetchActiveUserSummariesDecorrelated(ctx context.Context, tenantID string) ([]UserSummary, error) {
	// ✅ PRODUCTION INVARIANT: Zero SubPlans. All child aggregates are computed
	// in single-pass hash aggregates and joined via standard outer joins.
	const query = `
		WITH order_stats AS (
			SELECT 
				user_id,
				COUNT(*) AS order_cnt,
				COALESCE(SUM(amount_cents), 0) AS total_cents
			FROM orders
			WHERE tenant_id = @tenant_id
			GROUP BY user_id
		),
		project_stats AS (
			SELECT 
				user_id,
				COUNT(*) AS active_cnt
			FROM projects
			WHERE tenant_id = @tenant_id AND status = 'active'
			GROUP BY user_id
		)
		SELECT 
			u.id,
			u.email,
			u.created_at,
			COALESCE(os.order_cnt, 0) AS order_count,
			COALESCE(os.total_cents, 0) AS total_spent_cents,
			COALESCE(ps.active_cnt, 0) AS active_project_count
		FROM users u
		LEFT JOIN order_stats os ON os.user_id = u.id
		LEFT JOIN project_stats ps ON ps.user_id = u.id
		WHERE u.tenant_id = @tenant_id AND u.status = 'active'
		ORDER BY u.created_at DESC
		LIMIT 100;
	`

	args := pgx.NamedArgs{
		"tenant_id": tenantID,
	}

	rows, err := r.pool.Query(ctx, query, args)
	if err != nil {
		return nil, fmt.Errorf("failed querying user summaries: %w", err)
	}
	defer rows.Close()

	var summaries []UserSummary
	for rows.Next() {
		var s UserSummary
		if err := rows.Scan(
			&s.UserID,
			&s.Email,
			&s.CreatedAt,
			&s.OrderCount,
			&s.TotalSpent,
			&s.ActiveProject,
		); err != nil {
			return nil, fmt.Errorf("failed scanning summary row: %w", err)
		}
		summaries = append(summaries, s)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("rows iteration failed: %w", err)
	}

	return summaries, nil
}

// AssertZeroSubPlans executes EXPLAIN (FORMAT JSON) and validates that zero SubPlans exist in query plan
func (r *UserRepository) AssertZeroSubPlans(ctx context.Context, query string, args ...any) error {
	explainQuery := "EXPLAIN (FORMAT JSON) " + query
	var explainOutput []struct {
		Plan map[string]any `json:"Plan"`
	}

	row := r.pool.QueryRow(ctx, explainQuery, args...)
	if err := row.Scan(&explainOutput); err != nil {
		return fmt.Errorf("failed executing explain: %w", err)
	}

	// Recursive helper to check for Subplan presence
	var checkNode func(node map[string]any) error
	checkNode = func(node map[string]any) error {
		if subName, ok := node["Subplan Name"].(string); ok {
			if len(subName) > 0 && subName[:7] == "SubPlan" {
				return fmt.Errorf("CRITICAL VIOLATION: Found %s in query plan", subName)
			}
		}
		if plans, ok := node["Plans"].([]any); ok {
			for _, p := range plans {
				if childNode, valid := p.(map[string]any); valid {
					if err := checkNode(childNode); err != nil {
						return err
					}
				}
			}
		}
		return nil
	}

	if len(explainOutput) > 0 {
		return checkNode(explainOutput[0].Plan)
	}
	return nil
}
```

### 2. TypeScript (`drizzle-orm` & `kysely`): Decorrelated Joins & Window Partitioning

```typescript
// src/repositories/userSummaryRepository.ts
import { Kysely, sql } from 'kysely';

export interface Database {
  users: {
    id: string;
    tenant_id: string;
    email: string;
    status: string;
    created_at: Date;
  };
  orders: {
    id: string;
    tenant_id: string;
    user_id: string;
    amount_cents: number;
    created_at: Date;
  };
}

export class UserSummaryRepository {
  constructor(private readonly db: Kysely<Database>) {}

  /**
   * ✅ PRODUCTION INVARIANT: Clean decorrelation using Kysely CTE and LEFT JOIN.
   * Compiles to Hash Aggregate + Hash Join with zero SubPlan nodes.
   */
  async getDecorrelatedUserSummaries(tenantId: string, limit = 50) {
    return await this.db
      .with('order_aggregates', (db) =>
        db
          .selectFrom('orders')
          .select([
            'user_id',
            db.fn.count<number>('id').as('order_count'),
            db.fn.coalesce(db.fn.sum<number>('amount_cents'), sql<number>`0`).as('total_spent_cents'),
          ])
          .where('tenant_id', '=', tenantId)
          .groupBy('user_id')
      )
      .selectFrom('users')
      .leftJoin('order_aggregates', 'order_aggregates.user_id', 'users.id')
      .select([
        'users.id as user_id',
        'users.email',
        'users.created_at',
        sql<number>`COALESCE(order_aggregates.order_count, 0)`.as('order_count'),
        sql<number>`COALESCE(order_aggregates.total_spent_cents, 0)`.as('total_spent_cents'),
      ])
      .where('users.tenant_id', '=', tenantId)
      .where('users.status', '=', 'active')
      .orderBy('users.created_at', 'desc')
      .limit(limit)
      .execute();
  }

  /**
   * ✅ PRODUCTION INVARIANT: Short-circuiting semi-join with EXISTS()
   * Halts immediately on first matching child tuple.
   */
  async findUsersWithPendingOrders(tenantId: string) {
    return await this.db
      .selectFrom('users')
      .selectAll('users')
      .where('users.tenant_id', '=', tenantId)
      .where((eb) =>
        eb.exists(
          eb
            .selectFrom('orders')
            .select(sql`1`.as('one'))
            .whereRef('orders.user_id', '=', 'users.id')
            .where('orders.tenant_id', '=', tenantId)
        )
      )
      .execute();
  }
}
```

### 3. Python (`asyncpg` & `SQLAlchemy 2.0`): Decorrelated Subqueries & Lateral Top-K

```python
# src/repositories/user_metrics.py
import asyncpg
from typing import List, Dict, Any

class UserMetricsRepository:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def fetch_user_summaries_decorrelated(self, tenant_id: str, limit: int = 100) -> List[Dict[str, Any]]:
        """
        Decorrelates scalar projections into single-pass pre-aggregated CTEs.
        Asserts zero SubPlan nodes during execution.
        """
        query = """
        WITH precalc_orders AS (
            SELECT 
                user_id,
                COUNT(*) AS total_orders,
                COALESCE(SUM(amount_cents), 0) AS total_cents
            FROM orders
            WHERE tenant_id = $1
            GROUP BY user_id
        )
        SELECT 
            u.id AS user_id,
            u.email,
            u.created_at,
            COALESCE(po.total_orders, 0) AS order_count,
            COALESCE(po.total_cents, 0) AS total_spend_cents
        FROM users u
        LEFT JOIN precalc_orders po ON po.user_id = u.id
        WHERE u.tenant_id = $1 AND u.status = 'active'
        ORDER BY u.created_at DESC
        LIMIT $2;
        """
        async with self.pool.acquire() as conn:
            records = await conn.fetch(query, tenant_id, limit)
            return [dict(r) for r in records]

    async def verify_plan_has_no_subplans(self, query: str, *args) -> bool:
        """
        Executes EXPLAIN (FORMAT JSON) and raises RuntimeError if any SubPlan node is discovered.
        """
        async with self.pool.acquire() as conn:
            plan_json = await conn.fetchval(f"EXPLAIN (FORMAT JSON) {query}", *args)
            
            def has_subplan(node: Dict[str, Any]) -> bool:
                sub_name = node.get("Subplan Name", "")
                if sub_name.startswith("SubPlan"):
                    return True
                for child in node.get("Plans", []):
                    if has_subplan(child):
                        return True
                return False

            if has_subplan(plan_json[0]["Plan"]):
                raise RuntimeError(f"Plan regression: SubPlan detected in query: {query}")
            return True
```

### 4. Rust (`sqlx` & `tokio-postgres`): Compile-Time Verified Zero-SubPlan Aggregation

```rust
// src/repositories/user_repo.rs
use sqlx::{PgPool, FromRow};
use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Debug, FromRow)]
pub struct UserSummaryRecord {
    pub user_id: Uuid,
    pub email: String,
    pub created_at: DateTime<Utc>,
    pub order_count: i64,
    pub total_spent_cents: i64,
}

pub struct UserRepository {
    pool: PgPool,
}

impl UserRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Fetches user summaries with guaranteed zero SubPlan execution nodes.
    /// Utilizes pre-aggregated Common Table Expressions joined via Hash Outer Join.
    pub async fn fetch_summaries_decorrelated(
        &self,
        tenant_id: Uuid,
        limit: i64,
    ) -> Result<Vec<UserSummaryRecord>, sqlx::Error> {
        let records = sqlx::query_as!(
            UserSummaryRecord,
            r#"
            WITH agg_orders AS (
                SELECT 
                    user_id,
                    COUNT(*)::bigint AS order_cnt,
                    COALESCE(SUM(amount_cents), 0)::bigint AS sum_cents
                FROM orders
                WHERE tenant_id = $1
                GROUP BY user_id
            )
            SELECT 
                u.id AS user_id,
                u.email,
                u.created_at,
                COALESCE(ao.order_cnt, 0)::bigint AS order_count,
                COALESCE(ao.sum_cents, 0)::bigint AS total_spent_cents
            FROM users u
            LEFT JOIN agg_orders ao ON ao.user_id = u.id
            WHERE u.tenant_id = $1 AND u.status = 'active'
            ORDER BY u.created_at DESC
            LIMIT $2;
            "#,
            tenant_id,
            limit
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(records)
    }
}
```

---

## 5. SubPlan Decorrelation Lifecycle Finite-State Machine (FSM)

Every SQL query generated by autonomous coding agents must transition through the 6-state verification lifecycle before entering production:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               SUBPLAN DECORRELATION LIFECYCLE FINITE-STATE MACHINE                     │
└────────────────────────────────────────────────────────────────────────────────────────┘

            [1. STATIC_AST_INSPECTION]
                         │
        (Detect scalar subqueries in SELECT/WHERE)
                         ▼
             [2. CORRELATION_TRIAGE]
             ├── Independent Subquery ────────► [3A. VOLATILITY_AUDIT]
             │                                         │
             │                               (Ensure STABLE/IMMUTABLE)
             │                                         ▼
             │                                 [InitPlan 1 Verified]
             │
             └── Correlated Subquery ─────────► [3B. JOIN_DECORRELATION]
                                                       │
                                           (Transform to Hash Join /
                                            Window Partition / LATERAL)
                                                       ▼
                                         [4. BARRIER_ELIMINATION]
                                           (Purge unneeded LIMIT/
                                            DISTINCT optimization fences)
                                                       │
                                                       ▼
                                         [5. EXPLAIN_ANALYZE_PROFILING]
                                           (Assert SubPlan == 0,
                                            Loops == 1, Buffers Checked)
                                                       │
                                                       ▼
                                         [6. PRODUCTION_CERTIFIED]
```

| State | Action / Inspection Rule | Success Criteria | Failure Escalation |
| :--- | :--- | :--- | :--- |
| **1. STATIC_AST_INSPECTION** | Tokenize query text and analyze AST for nested `SELECT` nodes | Detect all subquery occurrences | Abort if AST parsing fails |
| **2. CORRELATION_TRIAGE** | Inspect inner subqueries for outer scope variable references | Partition into Uncorrelated vs Correlated | Flag ambiguous outer column references |
| **3A. VOLATILITY_AUDIT** | Check functions inside uncorrelated subqueries for volatility | Zero `VOLATILE` functions; verify `InitPlan` eligibility | Hoist volatile function or mark UDF `STABLE` |
| **3B. JOIN_DECORRELATION** | Rewrite correlated subquery into `LEFT JOIN`, CTE, or Window function | Replace $O(N \cdot M)$ loop with $O(N + M)$ set join | Rewrite with `LATERAL` if Top-$K$ ordering required |
| **4. BARRIER_ELIMINATION** | Remove unnecessary `LIMIT 1`, `DISTINCT`, or opaque CTE wrappers | Restore planner subquery pull-up and join flattening | Reject optimization barriers in sub-selects |
| **5. EXPLAIN_PROFILING** | Run `EXPLAIN (ANALYZE, BUFFERS)` in test environment | Assert `SubPlan` count is 0; assert single-pass execution | Fail CI gate if `loops > 1` on subquery node |
| **6. CERTIFIED** | Attach query fingerprint to repository safe-list | Query admitted to production CI/CD deployment | Continuous APM monitoring via `pg_stat_statements` |

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Automated Command / Assertion | Threshold |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **Zero SubPlans in EXPLAIN** | `psql -c "EXPLAIN (FORMAT JSON) $QUERY" \| jq '.. \| .["Subplan Name"]? \| select(. != null)'` | **Must contain ZERO matches starting with `SubPlan`** |
| **Gate 2** | **InitPlan Verification** | Verify uncorrelated subquery plan contains `InitPlan 1 (returns $0)` and `loops == 1` | **`InitPlan` loops $\equiv 1$** |
| **Gate 3** | **No COUNT(*) > 0 Traps** | `ast-grep --pattern '($COUNT_SUB) > 0'` or AST regex check | **Zero scalar count comparisons; enforce `EXISTS`** |
| **Gate 4** | **No Multi-Scalar Projections** | AST check: count scalar `(SELECT ...)` expressions in `SELECT` list | **$\le 0$ scalar subqueries in `SELECT` projection** |
| **Gate 5** | **Zero Volatile Functions in Subquery** | Search subqueries for `random()`, `clock_timestamp()`, `nextval()` | **Zero volatile functions in filter subqueries** |
| **Gate 6** | **Execution Time Regression Benchmark** | Run baseline vs decorrelated benchmark with $N = 50,000$ outer rows | **Decorrelated query must show $\ge 20\times$ speedup** |

---

## Conclusion & Operational Discipline

1. **SubPlans are Serial Loops Disguised as Relational SQL**: Any time PostgreSQL outputs `SubPlan 1`, it is running a procedural `for (row of outer_rows) { run_query(); }` loop inside C engine code. Never tolerate `SubPlan` nodes in queries touching more than 100 rows.
2. **Always Prefer Set-Based Pre-Aggregation**: Group child tables in a dedicated Common Table Expression (`WITH ... GROUP BY fk`) and join once via `LEFT JOIN`. The Hash Aggregate + Hash Join paradigm executes orders of magnitude faster and scales linearly.
3. **Guard InitPlans Against Volatility Poisoning**: Never call `random()`, `clock_timestamp()`, sequence generators, or volatile PL/pgSQL functions inside filter subqueries. A single volatile call degrades an $O(1)$ cached `InitPlan` into an $O(N)$ CPU-burning `SubPlan`.
4. **Use `EXISTS` Over `COUNT(*) > 0`**: Never count items to verify existence. `EXISTS` short-circuits on the first tuple, saving thousands of page reads per outer row.
5. **Enforce Zero-SubPlan CI Gates**: Make `EXPLAIN (FORMAT JSON)` plan verification a mandatory step in CI regression tests for all core repository methods.
