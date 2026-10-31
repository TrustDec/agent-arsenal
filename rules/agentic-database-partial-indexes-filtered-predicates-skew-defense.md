---
description: PostgreSQL partial indexes (filtered indexes), predicate subsumption logic, NULL compaction, asymmetric queue skew optimization, soft-delete unique constraint invariants, generic plan parameter non-match defense, and vacuum churn tuning across Go (pgx/sqlc), TypeScript (Drizzle, Prisma, Kysely), Python (SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{query,index,schema,repo,repository,store,migration,entity}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Partial Indexes, Filtered Predicates, NULL Compaction, Asymmetric Skew & Soft-Delete Uniqueness Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design database query paths, asymmetric queue processing, soft-delete lifecycle architectures, sparse column indexing, or zero-downtime schema migrations across PostgreSQL (11+), Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`). Eliminate the "Asymmetric Status Queue Monolithic Index Bloat Trap" (where indexing a 200M-row queue table across all status values wastes 25GB of RAM on 99.5% finished tasks when workers only poll pending jobs, blowing out `shared_buffers` and triggering continuous B-Tree leaf page splits), the "Parameterized Predicate Non-Match & Generic Plan Seq-Scan Trap" (where passing dynamic parameters `$1` in prepared statements prevents the PostgreSQL query planner from proving predicate implication, causing queries to silently abandon the partial index and collapse into 45-second sequential scans across 200M rows), the "Soft-Delete Unique Constraint Domain Corruption Trap" (where applying naive unique constraints on soft-delete tables blocks users from re-registering previously deleted emails or, if dropped, allows duplicate active entities), the "Predicate Subsumption & Sargability Invalidation Trap" (where slight syntax divergences like `is_active IS TRUE` vs `is_active = true`, non-immutable function calls, or mismatched integer cast widths prevent the query planner theorem prover from validating predicate inclusion), the "NULL Compaction Neglect Trap" (where indexing sparse foreign keys and error markers across millions of NULL tuples balloons index size by 90% without query benefit), and the "High-Turnover Queue Leaf Fragmentation & Dead Index Tuple Churn Trap" (where rapid inserts and status transitions prune tuples from the partial index, leaving behind orphaned leaf slots that trigger severe index bloat without aggressive autovacuum tuning and fillfactor allocation) by establishing a strict 5-Tier Partial Index Governance Ladder, predicate subsumption mathematical proofs, production TypeScript guard engines, and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Partial Index Catastrophes vs The 5-Tier Governance Ladder

A partial index (also known as a filtered index) in PostgreSQL is an index built over a subset of a table defined by a conditional `WHERE` clause:

$$\mathcal{I}_{\text{partial}} = \{ \text{tuple } t \in \mathcal{T} \mid \mathcal{P}(t) = \text{TRUE} \}$$

Autonomous coding agents frequently misuse or omit partial indexes, leading to six catastrophic failure modes in high-scale production systems:

### The 6 Partial Index Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: MONOLITHIC INDEXING ON HIGHLY ASYMMETRIC QUEUES
-- Table has 200,000,000 total task rows.
-- 99.7% of rows are 'COMPLETED' or 'FAILED' (historical tombstones).
-- Only 0.3% (600,000 rows) are 'PENDING' or 'PROCESSING'.
-- Agent creates a standard composite index on the entire table:
CREATE INDEX idx_tasks_tenant_status_created 
ON tasks (tenant_id, status, created_at);

-- ❌ Catastrophe:
-- 1. All 200,000,000 tuples are indexed into a monolithic 18 GB B-Tree.
-- 2. 99.7% of the index leaf blocks store dormant, completed tasks that workers never query.
-- 3. Cache thrashing: Active workers evict hot table pages to traverse cold branch nodes.
-- 4. High write amplification: Every insert and status transition splits leaves in this 18 GB monster.
```

```sql
-- ✅ PRODUCTION INVARIANT: ASYMMETRIC PARTIAL QUEUE INDEX
-- Index ONLY the active pending work queue:
CREATE INDEX CONCURRENTLY idx_tasks_pending_queue
ON tasks (tenant_id, created_at)
WHERE status IN ('PENDING', 'QUEUED')
WITH (fillfactor = 85);

-- ✅ Production Benefits:
-- 1. Index footprint shrinks from 18 GB to 35 MB (99.8% reduction!).
-- 2. Index fits 100% inside CPU L3 / RAM cache; workers achieve sub-0.2ms seek times.
-- 3. Updates to 'COMPLETED' prune the index entry, keeping the working set razor-thin.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: PARAMETERIZED PREDICATE NON-MATCH IN PREPARED STATEMENTS
-- Agent creates a partial index for active items:
CREATE INDEX idx_orders_active ON orders (customer_id, created_at) WHERE status = 'PENDING';

-- Then the agent writes a parameterized query in the application:
-- SELECT * FROM orders WHERE customer_id = $1 AND status = $2 ORDER BY created_at;
-- Parameters passed at runtime: ($1 = 'cust_123', $2 = 'PENDING')

-- ❌ Catastrophe:
-- In prepared statements or generic query plans (the default after 5 executions in pgx/pg/jdbc),
-- PostgreSQL evaluates the plan without knowing the value of $2!
-- Because $2 could be 'COMPLETED', the planner cannot prove that the query predicate implies
-- the partial index predicate.
-- Result: PostgreSQL abandons the partial index and executes a catastrophic SEQ SCAN across 50M rows!
```

```sql
-- ✅ PRODUCTION INVARIANT: STATIC PREDICATE HARDCODING FOR PARTIAL MATCH
-- Ensure the conditional filter expression is statically present in the SQL text:
SELECT id, customer_id, total_amount, created_at
FROM orders
WHERE customer_id = $1
  AND status = 'PENDING' -- Statically hardcoded literal expression guarantees partial index match!
ORDER BY created_at;
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: SOFT-DELETE UNIQUE CONSTRAINT DOMAIN CORRUPTION
-- Requirement: Email must be unique per tenant, but users can be soft-deleted.
-- Agent creates standard unique constraint:
ALTER TABLE users ADD CONSTRAINT uq_users_tenant_email UNIQUE (tenant_id, email);

-- ❌ Catastrophe:
-- 1. User registers 'alice@company.com'.
-- 2. User deletes account: UPDATE users SET deleted_at = NOW() WHERE id = '...';
-- 3. User attempts to re-register with 'alice@company.com'.
-- 4. BOOM: SQLSTATE 23505 (unique_violation). The customer cannot sign up!
-- 5. If agent "fixes" this by dropping the constraint, duplicate active users corrupt financial and auth flows.
```

```sql
-- ✅ PRODUCTION INVARIANT: PARTIAL UNIQUE CONSTRAINT ON ACTIVE ROWS
CREATE UNIQUE INDEX CONCURRENTLY idx_users_active_unique_email
ON users (tenant_id, lower(email))
WHERE deleted_at IS NULL;

-- ✅ Production Benefits:
-- 1. Guarantees 100% uniqueness among active, non-deleted users.
-- 2. Allows unlimited historical soft-deleted tombstone records.
-- 3. Re-registration succeeds instantly without domain integrity violations.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: PREDICATE SUBSUMPTION / SARGABILITY MISMATCH
-- Partial index declared with integer comparison:
CREATE INDEX idx_shipments_unassigned ON shipments (scheduled_date) WHERE attempts < 5;

-- Agent writes query with syntactically different or type-coerced condition:
SELECT * FROM shipments WHERE attempts <= 4 AND scheduled_date = $1;
-- Or query uses volatile expression:
-- SELECT * FROM shipments WHERE attempts < 5 AND scheduled_date > NOW();

-- ❌ Catastrophe:
-- PostgreSQL's query planner uses mathematical theorem proving (clause subsumption).
-- If types, operators, or expressions fail exact subsumption proof, the index is bypassed.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: UNCOMPACTED SPARSE COLUMNS (NULL BLOAT)
-- Table with 100,000,000 orders. Only 0.05% have a dispute ID (sparse attribute).
CREATE INDEX idx_orders_dispute_id ON orders (dispute_id);

-- ❌ Catastrophe:
-- PostgreSQL B-Trees store NULL values by default!
-- The index stores 99,950,000 NULL entries, taking 2.8 GB of disk space.
-- 99.95% of the index is useless dead weight.
```

```sql
-- ✅ PRODUCTION INVARIANT: SPARSE NULL COMPACTION INDEX
CREATE INDEX CONCURRENTLY idx_orders_active_disputes
ON orders (dispute_id, customer_id, created_at)
WHERE dispute_id IS NOT NULL;

-- ✅ Production Benefits:
-- Index stores only 50,000 dispute entries -> Size is 1.2 MB instead of 2.8 GB (99.96% savings).
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: HIGH-TURNOVER PARTIAL QUEUE CHURN & BLOAT
-- Queue tasks are inserted as 'PENDING', picked up, and updated to 'COMPLETED'.
-- High turnover prunes tuples from the partial index rapidly.
-- Table retains default autovacuum (scale_factor = 0.20, requiring 40,000,000 dead tuples before vacuum!).

-- ❌ Catastrophe:
-- The partial index accumulates thousands of dead index pointers on leaf pages.
-- Without space reclamation, the 35 MB partial index balloons to 5 GB of fragmented, empty pages.
```

---

### The 5-Tier Covering & Partial Index Governance Ladder

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Tier 0: Domain Predicate Constant Hardcoding Invariant                     │
│  - Literal constant predicates in SQL text (WHERE status = 'PENDING')       │
│  - Never parameterize the partial filter predicate ($2) in generic queries   │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 1: Soft-Delete Partial Unique Constraints                             │
│  - Enforce business uniqueness exclusively on active records                │
│  - CREATE UNIQUE INDEX ... (keys) WHERE deleted_at IS NULL                  │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 2: Asymmetric Skew & Hot-Queue Compaction                             │
│  - Isolate hot 1% pending working sets from 99% cold historical tombstones   │
│  - Dedicated queue indexes: WHERE status IN ('PENDING', 'QUEUED')           │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 3: Sparse NULL Compaction Invariant                                   │
│  - Eliminate indexing billions of NULL values on optional attributes        │
│  - CREATE INDEX ... (foreign_key) WHERE foreign_key IS NOT NULL             │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 4: Predicate Subsumption Verification & High-Turnover Vacuum Defense  │
│  - Exact type matching, immutable clauses, fillfactor = 85 on churn queues   │
│  - autovacuum_vacuum_scale_factor = 0.05 on partial queue tables            │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Models & Verification Calculus

### Model 1: Partial Index Compression Ratio & Working Set RAM Sizing Differential

Let a table contain $N$ total rows with average tuple size $W_{\text{tuple}}$. Let $\mathcal{P}$ be the filter predicate of a partial index, with selectivity $\sigma_{\mathcal{P}} \in [0, 1]$:

$$\sigma_{\mathcal{P}} = \frac{|\{ t \in \mathcal{T} \mid \mathcal{P}(t) = \text{TRUE} \}|}{N}$$

For a standard monolithic B-Tree index on $K$ key columns of combined width $W_{\text{key}}$, the number of index pages required is:

$$P_{\text{full}} = \left\lceil \frac{N \cdot (W_{\text{key}} + H_{\text{tuple}})}{\text{PageSize} - H_{\text{page}}} \cdot \frac{1}{\phi_{\text{fill}}} \right\rceil$$

Where $\phi_{\text{fill}}$ is the page fill factor (default $0.90$ for B-trees) and $H_{\text{tuple}} \approx 8$ bytes (ItemPointer overhead).

For a partial index defined with predicate $\mathcal{P}$, the number of indexed tuples is $N_{\text{partial}} = \sigma_{\mathcal{P}} \cdot N$. Thus:

$$P_{\text{partial}} = \left\lceil \frac{\sigma_{\mathcal{P}} \cdot N \cdot (W_{\text{key}} + H_{\text{tuple}})}{\text{PageSize} - H_{\text{page}}} \cdot \frac{1}{\phi_{\text{fill}}} \right\rceil = \sigma_{\mathcal{P}} \cdot P_{\text{full}}$$

The total index memory footprint reduction in `shared_buffers` is:

$$\Delta S_{\text{RAM}} = P_{\text{full}} \cdot (1 - \sigma_{\mathcal{P}}) \cdot \text{PageSize}$$

**Theorem 1 (Asymmetric Memory Domination)**: *In an asymmetric status queue where $\sigma_{\mathcal{P}} \le 0.01$ (e.g., $99\%$ finished tasks), a partial index reduces working set memory consumption by $\ge 99\%$, ensuring the active traversal tree remains $100\%$ resident in CPU L3/RAM cache.*

$$\lim_{\sigma_{\mathcal{P}} \to 0} \frac{S_{\text{partial}}}{S_{\text{full}}} = 0$$

---

### Model 2: Predicate Subsumption Theorem & Generic Plan Parameter Invalidation

PostgreSQL uses clause implication (theorem prover) during query optimization to determine whether a query can use a partial index.

Let $\mathcal{C}_{\text{query}}$ be the set of boolean clauses in the query's `WHERE` clause:

$$\mathcal{Q}_{\text{pred}} = \bigwedge_{j=1}^m C_j$$

Let $\mathcal{I}_{\text{pred}}$ be the boolean predicate defining the partial index:

$$\mathcal{I}_{\text{pred}} = \bigwedge_{k=1}^n P_k$$

**The Subsumption Rule**: The query planner can utilize index $\mathcal{I}$ for query $\mathcal{Q}$ if and only if:

$$\mathcal{Q}_{\text{pred}} \implies \mathcal{I}_{\text{pred}}$$

That is, the query predicate must logically imply the index predicate (query must be a subset of index rows).

#### The Generic Plan Breakdown Proof

Consider a query with dynamic parameter substitution:

$$\mathcal{Q}_{\text{generic}}(\$1, \$2) : \quad \text{tenant\_id} = \$1 \land \text{status} = \$2$$

During generic plan generation (prepared statement evaluation), the optimizer must evaluate implication for *all possible values* in domain $\mathcal{D}_{\text{status}}$:

$$\forall v \in \mathcal{D}_{\text{status}}, \quad (\text{status} = v) \implies (\text{status} = \text{'PENDING'})$$

Since $\exists v = \text{'COMPLETED'} \in \mathcal{D}_{\text{status}}$ such that $(\text{'COMPLETED'} = \text{'PENDING'}) \equiv \text{FALSE}$, the implication fails:

$$\mathcal{Q}_{\text{generic}} \not\implies \mathcal{I}_{\text{pred}}$$

**Corollary**: *Generic plans with dynamic bind variables on the partial predicate column can NEVER match the partial index, forcing $O(N)$ sequential table scans.*

---

### Model 3: B-Tree Leaf Node Churn & Dead Tuple Retention Differential

In a task queue table with arrival rate $\lambda$ (tasks inserted/sec) and completion rate $\mu$ (tasks transitioned from `PENDING` $\to$ `COMPLETED`/sec):

When status changes from `PENDING` to `COMPLETED`, PostgreSQL deletes the index pointer from the partial index. The rate of dead tuple generation in the partial index is:

$$\mathcal{R}_{\text{dead}} = \mu$$

The default PostgreSQL autovacuum threshold for triggering vacuum on relation $\mathcal{R}$ is:

$$\text{Threshold}_{\text{vacuum}} = \text{autovacuum\_vacuum\_threshold} + \text{autovacuum\_vacuum\_scale\_factor} \cdot N_{\text{table}}$$

Notice that $N_{\text{table}}$ is the *total table row count* ($200\text{M}$ rows), while the partial index only contains $N_{\text{partial}} = 600,000$ rows!

Under default settings:
$$\text{Threshold}_{\text{vacuum}} = 50 + 0.20 \cdot 200,000,000 = 40,000,050 \text{ dead tuples!}$$

Before autovacuum ever triggers, the partial index will have processed $40,000,000$ completions, creating an internal bloat ratio of:

$$\text{BloatRatio} = \frac{\text{Dead Tuples}}{N_{\text{partial}}} = \frac{40,000,000}{600,000} \approx 66.7 \times$$

**Theorem 2 (Partial Index Churn Starvation)**: *Because autovacuum triggers based on table-level dead tuples rather than partial index dead tuples, high-throughput partial queues on massive tables suffer terminal leaf bloat unless table-level scale factors are tuned down to $\le 0.05$ or $0.02$.*

---

## 3. Production Implementation: TypeScript `AgenticPartialIndexGuardEngine`

```typescript
/**
 * AgenticPartialIndexGuardEngine
 * Production-ready analysis and DDL generation engine for PostgreSQL Partial / Filtered Indexes.
 * Enforces predicate subsumption, soft-delete active uniqueness, asymmetric queue compaction,
 * sparse NULL pruning, and high-turnover fillfactor defense.
 */

export interface ColumnProfile {
  name: string;
  dataType: string;
  nullRatio: number; // 0.0 to 1.0 (ratio of NULL values in table)
  cardinality: number;
  distinctValues?: string[];
  isSoftDeleteColumn: boolean; // e.g. deleted_at, archived_at
}

export interface TableProfile {
  tableName: string;
  totalRows: number;
  columns: Record<string, ColumnProfile>;
  indexes: IndexDefinition[];
  isHighTurnoverQueue: boolean;
}

export interface IndexDefinition {
  indexName: string;
  columns: string[];
  isUnique: boolean;
  whereClause?: string;
  fillfactor?: number;
}

export interface PartialIndexRecommendation {
  type: 'HOT_QUEUE' | 'SOFT_DELETE_UNIQUE' | 'SPARSE_NULL_COMPACTION' | 'PARAM_PREDICATE_FIX';
  tableName: string;
  recommendedIndexName: string;
  ddl: string;
  estimatedSpaceSavingsBytes: number;
  reason: string;
}

export interface QueryAnalysisResult {
  isSafe: boolean;
  bypassesPartialIndex: boolean;
  warnings: string[];
  suggestedRewrite?: string;
}

export class AgenticPartialIndexGuardEngine {
  private static readonly HIGH_SKEW_THRESHOLD = 0.05; // 5% active, 95% historical
  private static readonly HIGH_NULL_THRESHOLD = 0.80; // 80%+ NULLs

  /**
   * Analyzes table profiles and identifies critical partial index optimization opportunities.
   */
  public static analyzeTable(profile: TableProfile): PartialIndexRecommendation[] {
    const recommendations: PartialIndexRecommendation[] = [];

    // 1. Audit Soft-Delete Active Uniqueness
    const softDeleteCol = Object.values(profile.columns).find(c => c.isSoftDeleteColumn);
    if (softDeleteCol) {
      const emailOrUsernameCol = Object.values(profile.columns).find(c => 
        ['email', 'username', 'slug', 'account_number'].includes(c.name.toLowerCase())
      );

      if (emailOrUsernameCol) {
        const hasActiveUnique = profile.indexes.some(idx => 
          idx.isUnique && 
          idx.columns.includes(emailOrUsernameCol.name) &&
          idx.whereClause?.includes(`${softDeleteCol.name} IS NULL`)
        );

        const hasNaiveUnique = profile.indexes.some(idx =>
          idx.isUnique &&
          idx.columns.includes(emailOrUsernameCol.name) &&
          !idx.whereClause
        );

        if (hasNaiveUnique && !hasActiveUnique) {
          recommendations.push({
            type: 'SOFT_DELETE_UNIQUE',
            tableName: profile.tableName,
            recommendedIndexName: `uq_${profile.tableName}_active_${emailOrUsernameCol.name}`,
            ddl: `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS uq_${profile.tableName}_active_${emailOrUsernameCol.name} ` +
                 `ON ${profile.tableName} (${emailOrUsernameCol.name}) ` +
                 `WHERE ${softDeleteCol.name} IS NULL;`,
            estimatedSpaceSavingsBytes: 0,
            reason: `Naive UNIQUE constraint on '${emailOrUsernameCol.name}' breaks re-registration after soft deletion. ` +
                    `Replace with partial unique index where ${softDeleteCol.name} IS NULL.`,
          });
        }
      }
    }

    // 2. Audit Asymmetric Status Queues
    const statusCol = Object.values(profile.columns).find(c => 
      ['status', 'state', 'phase'].includes(c.name.toLowerCase())
    );

    if (statusCol && profile.isHighTurnoverQueue && profile.totalRows >= 100_000) {
      const hasMonolithicStatusIndex = profile.indexes.some(idx => 
        idx.columns.includes(statusCol.name) && !idx.whereClause
      );

      const hasPartialQueueIndex = profile.indexes.some(idx =>
        idx.whereClause?.includes(statusCol.name) &&
        (idx.whereClause.includes('PENDING') || idx.whereClause.includes('QUEUED'))
      );

      if (!hasPartialQueueIndex) {
        const estimatedActiveRows = Math.floor(profile.totalRows * 0.02); // 2% active
        const bytesPerTuple = 32;
        const savings = (profile.totalRows - estimatedActiveRows) * bytesPerTuple;

        recommendations.push({
          type: 'HOT_QUEUE',
          tableName: profile.tableName,
          recommendedIndexName: `idx_${profile.tableName}_pending_queue`,
          ddl: `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_${profile.tableName}_pending_queue ` +
               `ON ${profile.tableName} (tenant_id, created_at) ` +
               `WHERE ${statusCol.name} IN ('PENDING', 'QUEUED') ` +
               `WITH (fillfactor = 85);`,
          estimatedSpaceSavingsBytes: savings,
          reason: `High-turnover table has monolithic status index. 98% of rows are historical tombstones. ` +
                  `Partial index reduces B-Tree footprint by >95% and prevents buffer cache eviction.`,
        });
      }
    }

    // 3. Audit Sparse Columns (High NULL Compaction)
    for (const col of Object.values(profile.columns)) {
      if (col.nullRatio >= this.HIGH_NULL_THRESHOLD && !col.isSoftDeleteColumn) {
        const hasUnfilteredIndex = profile.indexes.some(idx =>
          idx.columns[0] === col.name && !idx.whereClause
        );

        if (hasUnfilteredIndex) {
          const savings = Math.floor(profile.totalRows * col.nullRatio * 24);
          recommendations.push({
            type: 'SPARSE_NULL_COMPACTION',
            tableName: profile.tableName,
            recommendedIndexName: `idx_${profile.tableName}_sparse_${col.name}`,
            ddl: `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_${profile.tableName}_sparse_${col.name} ` +
                 `ON ${profile.tableName} (${col.name}) ` +
                 `WHERE ${col.name} IS NOT NULL;`,
            estimatedSpaceSavingsBytes: savings,
            reason: `Column '${col.name}' has ${(col.nullRatio * 100).toFixed(1)}% NULL values. ` +
                    `Existing index wastes storage on NULL pointers. Use WHERE ${col.name} IS NOT NULL.`,
          });
        }
      }
    }

    return recommendations;
  }

  /**
   * Verifies an application query against a partial index to catch dynamic parameterization traps.
   */
  public static verifyQueryPredicate(
    sqlQuery: string,
    partialIndex: IndexDefinition
  ): QueryAnalysisResult {
    const warnings: string[] = [];
    let bypassesPartialIndex = false;

    if (!partialIndex.whereClause) {
      return { isSafe: true, bypassesPartialIndex: false, warnings: [] };
    }

    // Normalized index predicate
    const normalizedIndexPredicate = partialIndex.whereClause
      .replace(/\s+/g, ' ')
      .trim()
      .toUpperCase();

    // Check if query is parameterized on the predicate column
    const predicateColMatch = partialIndex.whereClause.match(/([a-zA-Z0-9_]+)\s*(=|IN|IS)/i);
    if (predicateColMatch) {
      const colName = predicateColMatch[1];
      // Regex checking for parameterized bind (e.g. status = $1 or status = ?)
      const paramPattern = new RegExp(`${colName}\\s*=\\s*(\\$[0-9]+|\\?)`, 'i');
      if (paramPattern.test(sqlQuery)) {
        bypassesPartialIndex = true;
        warnings.push(
          `PARAMETERIZED_PREDICATE_TRAP: Query parameterizes '${colName} = $N' against partial index with predicate '${partialIndex.whereClause}'. ` +
          `PostgreSQL query planner will NOT match generic plans to this partial index, causing SEQ SCANS.`
        );
      }
    }

    // Check if query WHERE clause omits the partial index condition entirely
    const cleanQuery = sqlQuery.toUpperCase();
    if (!cleanQuery.includes(normalizedIndexPredicate) && !cleanQuery.includes(normalizedIndexPredicate.replace(/'/g, ''))) {
      if (bypassesPartialIndex) {
        // already flagged
      } else {
        warnings.push(
          `PREDICATE_OMISSION: Query does not statically include condition '${partialIndex.whereClause}'. ` +
          `Planner clause subsumption may fail.`
        );
      }
    }

    return {
      isSafe: warnings.length === 0,
      bypassesPartialIndex,
      warnings,
      suggestedRewrite: bypassesPartialIndex
        ? sqlQuery.replace(
            new RegExp(`(${predicateColMatch?.[1]}\\s*=\\s*\\$[0-9]+)`, 'gi'),
            `${predicateColMatch?.[1]} = 'PENDING'`
          )
        : undefined,
    };
  }
}
```

---

## 4. 6-State Partial Index Lifecycle Finite-State Machine (FSM)

```
       [ 1. SKEW_DISTRIBUTION_PROFILED ]
                     │
                     ▼ (Profile Table Selectivity & Skew: sigma_P <= 0.05)
       [ 2. PREDICATE_SUBSUMPTION_VERIFIED ] ──(Dynamic Param in Predicate)──► [ HARDCODE_CONSTANT_PREDICATE ]
                     │
                     ▼ (Validate Fillfactor & Autovacuum Churn Scale Factor)
       [ 3. CHURN_CONFIG_APPLIED ]
                     │
                     ▼ (Generate DDL with CONCURRENTLY + fillfactor = 85)
       [ 4. CONCURRENT_PARTIAL_BUILT ]
                     │
                     ▼ (Verify EXPLAIN (ANALYZE, BUFFERS) Index Scan Selected)
       [ 5. PLANNER_SUBSUMPTION_VALIDATED ] ──(Seq Scan Detected)──► [ ALIGN_QUERY_CLAUSE ]
                     │
                     ▼ (Continuous Sentinel: Bloat Ratio < 0.15, Hit Rate > 0.99)
       [ 6. PRODUCTION_STABLE ]
```

---

## 5. 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Failure Condition | Pass Threshold | Automated Verification Script |
| :--- | :--- | :--- | :--- | :--- |
| **Gate 1: Literal Invariance** | Parameterized Predicate | Query binds `$N` to partial filter column instead of literal SQL expression | 0 Dynamic Parameter Binds | Static AST Query Analyzer |
| **Gate 2: Soft-Delete Unique** | Active Integrity | Standard `UNIQUE(tenant_id, email)` on soft-delete tables blocking re-registration | 100% `WHERE deleted_at IS NULL` | Migration Schema Linter |
| **Gate 3: Hot-Queue Compaction** | Asymmetric Skew Bloat | Full table B-tree index on tables with $\ge 95\%$ terminal/completed rows | $\le 5\%$ Index Row Footprint | `AgenticPartialIndexGuardEngine` |
| **Gate 4: Sparse Compaction** | High NULL Pruning | B-Tree indexing columns with $\ge 80\%$ NULLs without `WHERE col IS NOT NULL` | 0 Unpruned Sparse B-Trees | PostgreSQL Catalog Inspector |
| **Gate 5: Subsumption Sargability** | Clause Implication | Type mismatch, boolean divergence (`IS TRUE` vs `= true`), or volatile expressions | 0 Planner Rejections | `EXPLAIN (ANALYZE, BUFFERS)` CI |
| **Gate 6: Zero-Downtime DDL** | Migration Locks | Missing `CONCURRENTLY` or executed inside transactional block | 0 Table Lockouts | Migration CI Checker |

---

## 6. Cross-Language Implementation Invariants

### A. Go (`jackc/pgx/v5` & `sqlc`)

```go
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type PendingTask struct {
	ID        string    `json:"id"`
	TenantID  string    `json:"tenant_id"`
	Payload   string    `json:"payload"`
	CreatedAt time.Time `json:"created_at"`
}

// DequeuePendingTask fetches the next available task using the partial queue index:
// CREATE INDEX idx_tasks_pending_queue ON tasks (tenant_id, created_at) WHERE status = 'PENDING' WITH (fillfactor = 85);
// INVARIANT: The query text hardcodes "status = 'PENDING'" literally to ensure the PostgreSQL planner
// always matches the partial index under both custom and generic prepared statement plans.
func DequeuePendingTask(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
) (*PendingTask, error) {
	// Literal predicate 'status = 'PENDING'' guarantees 100% partial index match.
	// FOR UPDATE SKIP LOCKED guarantees non-blocking concurrent worker consumption.
	query := `
		UPDATE tasks
		SET status = 'PROCESSING',
		    updated_at = CLOCK_TIMESTAMP()
		WHERE id = (
			SELECT id
			FROM tasks
			WHERE tenant_id = $1
			  AND status = 'PENDING'
			ORDER BY created_at ASC
			LIMIT 1
			FOR UPDATE SKIP LOCKED
		)
		RETURNING id, tenant_id, payload, created_at;
	`

	var task PendingTask
	err := pool.QueryRow(ctx, query, tenantID).Scan(
		&task.ID,
		&task.TenantID,
		&task.Payload,
		&task.CreatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil // Queue is empty
		}
		return nil, fmt.Errorf("dequeue pending task failed: %w", err)
	}

	return &task, nil
}

// RegisterActiveUser inserts an active user while honoring the soft-delete partial unique index:
// CREATE UNIQUE INDEX uq_users_active_email ON users (tenant_id, lower(email)) WHERE deleted_at IS NULL;
func RegisterActiveUser(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	email string,
	hashedPassword string,
) (string, error) {
	query := `
		INSERT INTO users (tenant_id, email, password_hash, created_at)
		VALUES ($1, lower($2), $3, CLOCK_TIMESTAMP())
		RETURNING id;
	`
	var userID string
	err := pool.QueryRow(ctx, query, tenantID, email, hashedPassword).Scan(&userID)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return "", fmt.Errorf("an active user with this email already exists: %w", err)
		}
		return "", fmt.Errorf("failed to register user: %w", err)
	}

	return userID, nil
}

// AuditPartialIndexHealth inspects partial index usage, size, and scans.
func AuditPartialIndexHealth(ctx context.Context, pool *pgxpool.Pool, tableName string) ([]map[string]any, error) {
	query := `
		SELECT
			i.relname AS index_name,
			pg_get_expr(idx.indpred, idx.indrelid) AS partial_predicate,
			stat.idx_scan,
			stat.idx_tup_read,
			stat.idx_tup_fetch,
			pg_size_pretty(pg_relation_size(i.oid)) AS index_size
		FROM pg_class c
		JOIN pg_index idx ON c.oid = idx.indrelid
		JOIN pg_class i ON i.oid = idx.indexrelid
		JOIN pg_stat_user_indexes stat ON stat.indexrelid = idx.indexrelid
		WHERE c.relname = $1
		  AND idx.indpred IS NOT NULL
		ORDER BY stat.idx_scan DESC;
	`
	rows, err := pool.Query(ctx, query, tableName)
	if err != nil {
		return nil, fmt.Errorf("failed to audit partial indexes: %w", err)
	}
	defer rows.Close()

	var results []map[string]any
	for rows.Next() {
		var indexName, indexSize string
		var partialPredicate *string
		var idxScan, idxTupRead, idxTupFetch int64

		if err := rows.Scan(&indexName, &partialPredicate, &idxScan, &idxTupRead, &idxTupFetch, &indexSize); err != nil {
			return nil, err
		}

		results = append(results, map[string]any{
			"index_name":        indexName,
			"partial_predicate": partialPredicate,
			"idx_scan":          idxScan,
			"idx_tup_read":      idxTupRead,
			"idx_tup_fetch":     idxTupFetch,
			"index_size":        indexSize,
		})
	}
	return results, nil
}
```

---

### B. TypeScript (`Drizzle ORM`)

```typescript
import { pgTable, uuid, text, timestamp, uniqueIndex, index } from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';

/**
 * Tasks Table Schema with Asymmetric Partial Queue Index and Soft-Delete Unique Index.
 */
export const tasks = pgTable(
  'tasks',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    tenantId: uuid('tenant_id').notNull(),
    status: text('status').notNull().default('PENDING'),
    payload: text('payload').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
  },
  (table) => [
    // 1. Partial index on active pending queue only.
    // Compresses index footprint by >95% compared to monolithic indexing.
    index('idx_tasks_pending_queue')
      .on(table.tenantId, table.createdAt)
      .where(sql`status IN ('PENDING', 'QUEUED')`),

    // 2. Partial unique index for active records with soft-delete support.
    uniqueIndex('uq_tasks_active_tenant_id')
      .on(table.tenantId, table.id)
      .where(sql`deleted_at IS NULL`),
  ]
);

/**
 * Worker Service Query Pattern:
 * Always preserve the literal predicate in SQL to guarantee partial index subsumption.
 */
export async function pollNextPendingTask(db: any, tenantId: string) {
  // Use raw SQL or typed builder with matching constant predicate:
  const result = await db.execute(sql`
    UPDATE tasks
    SET status = 'PROCESSING',
        updated_at = NOW()
    WHERE id = (
      SELECT id
      FROM tasks
      WHERE tenant_id = ${tenantId}
        AND status = 'PENDING' -- Invariant: literal matching guarantees partial index seek!
      ORDER BY created_at ASC
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    RETURNING id, tenant_id, payload, created_at;
  `);

  return result.rows[0] ?? null;
}
```

---

### C. Python (`SQLAlchemy 2.0`)

```python
"""
SQLAlchemy 2.0 Partial Index Declarations & Deterministic Predicate Queries
"""
import uuid
from datetime import datetime
from sqlalchemy import (
    Column,
    String,
    DateTime,
    Text,
    Index,
    select,
    update,
    text,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import declarative_base

Base = declarative_base()

class TaskModel(Base):
    __tablename__ = "tasks"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), nullable=False)
    status = Column(String(32), nullable=False, default="PENDING")
    payload = Column(Text, nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, default=datetime.utcnow)
    deleted_at = Column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        # 1. Asymmetric Queue Partial Index
        Index(
            "idx_tasks_pending_queue",
            "tenant_id",
            "created_at",
            postgresql_where=text("status = 'PENDING'"),
            postgresql_with={"fillfactor": 85},
        ),
        # 2. Soft-Delete Partial Unique Index
        Index(
            "uq_tasks_active_tenant_payload",
            "tenant_id",
            "payload",
            unique=True,
            postgresql_where=text("deleted_at IS NULL"),
        ),
    )


async def dequeue_next_task(session, tenant_id: uuid.UUID):
    """
    Dequeues the next pending task using PostgreSQL FOR UPDATE SKIP LOCKED
    over the partial queue index.
    """
    subquery = (
        select(TaskModel.id)
        .where(TaskModel.tenant_id == tenant_id)
        .where(text("tasks.status = 'PENDING'"))  # Hardcoded literal matches partial index
        .order_by(TaskModel.created_at.asc())
        .limit(1)
        .with_for_update(skip_locked=True)
        .scalar_subquery()
    )

    stmt = (
        update(TaskModel)
        .where(TaskModel.id == subquery)
        .values(status="PROCESSING")
        .returning(TaskModel.id, TaskModel.tenant_id, TaskModel.payload)
    )

    result = await session.execute(stmt)
    await session.commit()
    return result.mappings().first()
```
