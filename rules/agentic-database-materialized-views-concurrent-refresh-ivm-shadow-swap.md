---
description: PostgreSQL Materialized Views, REFRESH MATERIALIZED VIEW CONCURRENTLY, Incremental View Maintenance (IVM), zero-downtime shadow table swap, singleflight advisory lock fencing, unique index invariants, and MVCC bloat mitigation across Go (pgx/v5), TypeScript (Drizzle/Kysely), Python (psycopg3), Rust (tokio-postgres), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{matview,materialized,view,aggregate,rollup,ivm,shadow_swap,reporting,analytics}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Materialized Views, Concurrent Refresh (`REFRESH MATERIALIZED VIEW CONCURRENTLY`), Incremental View Maintenance (IVM) & Zero-Downtime Shadow Swapping

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design pre-aggregated reporting views, analytics caching layers, dashboard rollups, or continuous data projections using PostgreSQL Materialized Views, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `pg`), Python (`psycopg3`), or Rust (`tokio-postgres`). Eliminate the "Blocking ACCESS EXCLUSIVE Lock Outage" (where executing standard `REFRESH MATERIALIZED VIEW` takes an exclusive lock, blocking all application read queries for minutes or hours and saturating connection pools until cascading 504 gateway timeouts collapse the frontend), the "Missing Unique Index & `CONCURRENTLY` Fatal Crash" (where autonomous agents attempt `REFRESH MATERIALIZED VIEW CONCURRENTLY` on a view lacking a non-partial unique index on non-nullable columns, causing background worker crash loops and silent reporting failures), the "Concurrent Refresh MVCC Bloat, Dead Tuple Avalanche & Autovacuum Freezing Storm" (where `REFRESH CONCURRENTLY` joins the old view with a fresh temp diff table, generating millions of dead tuples per refresh cycle, ballooning physical disk usage by 20x, and forcing emergency vacuum freezes), the "Long-Running Refresh Snapshot Pinning & Cluster-Wide Autovacuum Horizon Paralysis" (where an unindexed, multi-table aggregate refresh query running for 45 minutes pins the database `$x_{\text{min}}$` horizon, preventing vacuum from cleaning dead tuples across all unrelated OLTP tables and driving database-wide table bloat), the "Missing Incremental View Maintenance (IVM) & Full Recomputation Token/CPU Burn" (where agents trigger full table scans across billions of historical records to refresh rollups when only 50 rows changed, pegging database CPU at 100% and consuming IOPS budgets), and the "Stale Read Blindness & Double-Refresh Thundering Herd Stampede" (where lack of staleness metadata serves dangerously outdated reporting metrics or causes dozens of parallel API calls to trigger duplicate, competing refreshes simultaneously) by establishing a strict 5-Tier Materialized View Governance Ladder, singleflight advisory locking, atomic shadow-table swap rotations, and machine-verifiable CI test gates.

---

## 1. Architectural Taxonomy: The 6 Materialized View Catastrophes vs The 5-Tier Governance Ladder

Materialized views allow relational databases to store the physical pre-computed results of heavy multi-table `JOIN`, `GROUP BY`, and window function queries on disk, transforming complex analytical queries from seconds down to sub-millisecond point lookups.

However, autonomous coding agents frequently treat materialized views as magical zero-cost query caches, remaining entirely blind to table locking modes, MVCC dead tuple amplification during diff generation, snapshot horizon freezing, and unique index prerequisites.

```typescript
// ❌ CATASTROPHIC LLM MATERIALIZED VIEW ANTI-PATTERNS

// 1. The Blocking ACCESS EXCLUSIVE Lock Outage!
// Running standard REFRESH MATERIALIZED VIEW acquires an ACCESS EXCLUSIVE lock.
// Every single user SELECT query against mv_daily_sales is blocked for the entire 12-minute refresh!
// The connection pool fills up in 3 seconds, bringing down the entire SaaS web app!
await db.query(`
  REFRESH MATERIALIZED VIEW mv_daily_sales; -- ❌ Blocks all reads! AccessExclusiveLock!
`);

// 2. The Missing Unique Index & CONCURRENTLY Crash!
// The developer tries to fix the lock by adding CONCURRENTLY, but forgot to create a unique index.
// PostgreSQL immediately throws: ERROR: cannot refresh materialized view "..." concurrently without a unique index!
// The background worker crashes in an unhandled rejection loop!
await db.query(`
  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales; -- ❌ Crashes without UNIQUE INDEX!
`);

// 3. The Unbounded Multi-Refresh Thundering Herd!
// 10 concurrent requests notice the dashboard cache is cold and execute REFRESH simultaneously.
// 10 parallel refresh queries execute huge table scans, maxing out database CPU at 100% and disk IOPS!
app.get('/api/analytics', async (req, res) => {
  const isStale = await checkStaleness();
  if (isStale) {
    // ❌ No advisory lock, no singleflight mutex, no background queue!
    await db.query('REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales;');
  }
  const data = await db.query('SELECT * FROM mv_daily_sales');
  res.json(data.rows);
});
```

### The 6 Catastrophes of Autonomous Materialized View Architectures

1. **The Blocking ACCESS EXCLUSIVE Lock Outage**:
   Standard `REFRESH MATERIALIZED VIEW mv_name` acquires an `ACCESS EXCLUSIVE` lock on the materialized view relation. In PostgreSQL's lock hierarchy, `ACCESS EXCLUSIVE` conflicts with every other lock level, including `ACCESS SHARE` (which is held by standard `SELECT` queries). When an agent executes a standard refresh during business hours, every incoming user read query queues behind the refresh. In a high-traffic production service with 100 requests per second, a 2-minute refresh queues 12,000 requests, exhausting connection pools, tripping load balancer health checks, and triggering cascading HTTP 504 outages.

2. **The Missing Unique Index & `CONCURRENTLY` Fatal Crash**:
   To avoid blocking reads, PostgreSQL provides `REFRESH MATERIALIZED VIEW CONCURRENTLY`. However, the engine requires that the materialized view has at least one **unique index** that covers non-nullable columns and has no `WHERE` clause (cannot be a partial index). Autonomous agents frequently omit this prerequisite or create an index that includes nullable columns. When `REFRESH CONCURRENTLY` runs, PostgreSQL rejects the command with `SQLSTATE 55000: cannot refresh materialized view concurrently without a unique index`, causing automated background workers or cron pods to crash repeatedly.

3. **The Concurrent Refresh MVCC Bloat, Dead Tuple Avalanche & Autovacuum Freezing Storm**:
   Under `CONCURRENTLY`, PostgreSQL does not truncate and repopulate the table. Instead, it runs the defining query, populates a temporary heap table, performs an expensive diff (using an outer join on the unique key) between the existing materialized view tuples and the new result set, and issues individual `INSERT`, `UPDATE`, and `DELETE` operations on the underlying heap. If a view contains 5 million rows and refreshes every 15 minutes, this process creates up to 5 million dead tuples per cycle! Physical disk consumption balloons by 10x–30x, index bloat explodes, and autovacuum is forced into aggressive freezing cycles, causing severe I/O degradation.

4. **The Long-Running Refresh Snapshot Pinning & Cluster-Wide Autovacuum Horizon Paralysis**:
   A complex materialized view query that joins dozens of tables or aggregates billions of rows can take 30 to 60 minutes to compute. For the entire duration of the refresh transaction, PostgreSQL holds open an active snapshot with a pinned transaction ID horizon (`$x_{\text{min}}$`). This pins the global autovacuum cleanup horizon across the **entire database cluster**. Autovacuum cannot prune dead tuples from high-throughput OLTP tables (such as `orders`, `users`, or `events`), causing database-wide heap and index bloat, cache pollution, and degradation of primary transactional workloads.

5. **The Missing Incremental View Maintenance (IVM) & Full Recomputation Token/CPU Burn**:
   In standard PostgreSQL, materialized views require full recomputation of the entire dataset on every refresh, even when only a fraction of a percent of base table rows have been inserted or updated. Autonomous agents execute massive aggregations across tens of millions of rows on fixed 5-minute schedules, burning thousands of dollars in cloud database compute. Without Incremental View Maintenance (`pg_ivm` or change-data-capture/trigger-based delta rollups), the database engine wastes gigabytes of I/O bandwidth recalculating unchanged historical data.

6. **The Stale Read Blindness & Double-Refresh Thundering Herd Stampede**:
   Materialized views are static snapshots as of the time they were refreshed. When agents query materialized views without staleness metadata (`refreshed_at` timestamps or TTL indicators), users make critical decisions based on stale financial or inventory data. Even worse, when multiple user sessions or background agents detect stale data simultaneously, they all issue concurrent `REFRESH MATERIALIZED VIEW` commands. Without distributed advisory locks (`pg_try_advisory_lock`) or application-level singleflight coalescing, parallel refreshes compete for CPU, memory, and lock resources, grinding the database to a halt.

---

## 2. The 5-Tier Materialized View & Reporting Governance Ladder

Every production project utilizing materialized views or reporting caches must enforce this 5-Tier governance hierarchy:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Tier 5: Autonomous Staleness Telemetry, CI Plan & Autovacuum Guard      │
│  - Continuous prometheus exporter for view staleness: age(now(), ts)    │
│  - CI gate: EXPLAIN (ANALYZE, BUFFERS) validation on MV query definition│
│  - Autovacuum tuning: vacuum_cost_limit=2000, scale_factor=0.05 on MVs  │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Incremental View Maintenance (IVM / Delta Change-Log Rollups)   │
│  - pg_ivm (create_incremental_materialized_view) for real-time deltas  │
│  - Trigger/CDC differential rollups for high-throughput append tables   │
│  - Mathematical delta calculation: ΔV = V(T_new) - V(T_old)            │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Zero-Bloat Shadow Table Swap (Blue-Green View Rotation)         │
│  - CREATE TABLE mv_shadow AS SELECT ... (Out-of-band heap generation)  │
│  - CREATE INDEX CONCURRENTLY on mv_shadow (Zero read blockage)          │
│  - Sub-millisecond atomic swap: ALTER TABLE RENAME inside 1ms TX block  │
│  - Completely bypasses MVCC dead tuple churn on huge analytical views   │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Singleflight Advisory Locking & Refresh Timeout Ladders         │
│  - Dedicated pg_try_advisory_lock(hashtext('mv_name')) mutex fencing    │
│  - Non-blocking lock acquisition: abort or join if already running      │
│  - Strict session timeouts: statement_timeout=15min, lock_timeout=2s    │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Non-Blocking Concurrent Refresh & Mandatory Unique Indexes     │
│  - Zero non-concurrent REFRESH in production application code           │
│  - Mandatory non-partial, non-nullable UNIQUE INDEX on every MV         │
│  - WITH NO DATA creation during migrations to prevent deployment pauses │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Mathematical Foundations of View Maintenance & Write Amplification

### 3.1. Write Amplification Calculus: `REFRESH CONCURRENTLY` vs Shadow Swap

When `REFRESH MATERIALIZED VIEW CONCURRENTLY` executes, PostgreSQL calculates the diff between the existing view relation $V_{\text{old}}$ and the freshly computed query relation $V_{\text{new}}$.

Let $N = |V_{\text{old}}|$ be the existing row count, and $M = |V_{\text{new}}|$ be the new row count. Let $\Delta_{\text{ins}}$ be the inserted rows, $\Delta_{\text{del}}$ be deleted rows, and $\Delta_{\text{upd}}$ be updated rows.

The write I/O volume for `REFRESH CONCURRENTLY` is given by:

$$I/O_{\text{concurrent}} = \underbrace{\text{Size}(V_{\text{new}})}_{\text{temp heap write}} + \underbrace{2 \cdot (N + M) \log(N + M)}_{\text{diff sort / hash join}} + \underbrace{(\Delta_{\text{ins}} + \Delta_{\text{del}} + 2 \cdot \Delta_{\text{upd}}) \cdot (\text{TupleSize} + \sum \text{IndexBytes})}_{\text{heap mutations + index updates}} + \text{WAL}_{\text{churn}}$$

When $V_{\text{old}}$ and $V_{\text{new}}$ have high cardinality (e.g. $N \ge 10^7$) and updates affect more than 20% of the rows ($\Delta_{\text{upd}} \ge 0.2 N$), `REFRESH CONCURRENTLY` generates more write I/O and dead tuple bloat than a clean rewrite!

In contrast, the **Shadow Table Swap (Blue-Green Rotation)** writes only the final table once sequentially:

$$I/O_{\text{shadow}} = \underbrace{\text{Size}(V_{\text{new}})}_{\text{sequential heap write}} + \sum \underbrace{\text{SortAndWrite}(\text{Index}_i)}_{\text{clean btree build}} + \underbrace{\mathcal{O}(1)}_{\text{catalog metadata rename}}$$

$$\text{Dead Tuples Produced}_{\text{shadow}} = 0 \quad (\text{old table is simply dropped or truncated})$$

**Decision Boundary Theorem**:
- If change percentage $\rho = \frac{\Delta_{\text{ins}} + \Delta_{\text{del}} + \Delta_{\text{upd}}}{N} < 0.15$ and $N \le 2 \times 10^6$: Use `REFRESH MATERIALIZED VIEW CONCURRENTLY`.
- If $\rho \ge 0.15$ or $N > 2 \times 10^6$: Use **Tier 3 Shadow Table Swap** to achieve zero dead tuple bloat, optimal index density, and sub-millisecond atomic catalog switchover.

### 3.2. Lock Contention Physics & Little's Law Pool Saturation

Let the arrival rate of user read queries to a materialized view be $\lambda$ (queries/second).
Let the duration of a standard non-concurrent refresh be $T_{\text{refresh}}$ (seconds).

Standard non-concurrent `REFRESH MATERIALIZED VIEW` takes an `ACCESS EXCLUSIVE` lock. By Little's Law, the expected number of blocked queries $Q_{\text{blocked}}$ queued behind the refresh is:

$$Q_{\text{blocked}} = \lambda \cdot T_{\text{refresh}}$$

If $\lambda = 40 \text{ req/s}$ and $T_{\text{refresh}} = 45 \text{ s}$:

$$Q_{\text{blocked}} = 40 \times 45 = 1,800 \text{ connections queued}$$

Given that a production database connection pool typically caps `max_connections` at 100–300, the pool is completely saturated at $t = \frac{\text{PoolSize}}{\lambda} = \frac{150}{40} = 3.75 \text{ seconds}$. 

Every subsequent connection fails, triggering an immediate complete outage.

**The Invariant**: Production code must **NEVER** issue a non-concurrent `REFRESH MATERIALIZED VIEW` without an exclusive maintenance window and drained client connections.

### 3.3. Unique Index Invariant for Concurrent Refresh

PostgreSQL requires a unique index to identify rows for the diff join. The formal correctness invariant requires:

$$\exists \, \text{Index } I \text{ on } V \quad \text{s.t.} \quad I = \text{UNIQUE}(C_1, C_2, \dots, C_k) \quad \land \quad \forall i, \, C_i \text{ IS NOT NULL} \quad \land \quad \text{Predicate}(I) = \text{NONE}$$

If any column $C_i$ can contain `NULL`, or if the index contains a `WHERE` clause (partial index), PostgreSQL `REFRESH CONCURRENTLY` fails with an invariant violation.

---

## 4. Production SQL & DDL Invariants for PostgreSQL Materialized Views

### 4.1. Creating Materialized Views with `WITH NO DATA` & Mandatory Unique Indexes

When executing database migrations (via Liquibase, Flyway, Goose, Drizzle-Kit, Prisma), **NEVER** create a materialized view with data in the migration transaction. If the underlying query scans 50GB of data, the entire migration hangs, holding locks and causing deployment timeouts.

Always use `WITH NO DATA`, create the unique index concurrently outside a transaction block, and populate the data in a post-deployment background job.

```sql
-- ============================================================================
-- 1. MIGRATION STEP (Fast DDL, zero deployment hang)
-- ============================================================================

-- Create the materialized view structure without executing the query
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_tenant_daily_revenue AS
SELECT
  o.tenant_id,
  DATE_TRUNC('day', o.created_at) AS report_date,
  COUNT(o.id) AS total_orders,
  SUM(o.amount_cents) AS gross_revenue_cents,
  COUNT(DISTINCT o.customer_id) AS active_customers,
  NOW() AS refreshed_at
FROM orders o
WHERE o.status = 'completed'
GROUP BY o.tenant_id, DATE_TRUNC('day', o.created_at)
WITH NO DATA; -- ✅ Invariant: Instant migration, zero table scan!

-- ============================================================================
-- 2. MANDATORY UNIQUE INDEX STEP (Executed outside transaction)
-- ============================================================================

-- CONCURRENT refresh requires a strictly unique, non-partial, non-nullable index
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_mv_tenant_daily_revenue_pk
  ON mv_tenant_daily_revenue (tenant_id, report_date);

-- Auxiliary covering indexes for accelerated query performance
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mv_tenant_daily_revenue_date
  ON mv_tenant_daily_revenue (report_date DESC);

-- ============================================================================
-- 3. INITIAL POPULATION (Run via background worker or post-deploy script)
-- ============================================================================

-- Initial population can be standard REFRESH because the view is brand new and not yet in use
REFRESH MATERIALIZED VIEW mv_tenant_daily_revenue;
```

### 4.2. Safe Concurrent Refresh with Advisory Lock Fencing

Autonomous agents and background workers must use session-level advisory locks to prevent the **Thundering Herd** problem where multiple workers attempt to refresh the same view simultaneously:

```sql
-- ============================================================================
-- SAFE CONCURRENT REFRESH PROCEDURE WITH ADVISORY LOCK & TIMEOUTS
-- ============================================================================

CREATE OR REPLACE FUNCTION refresh_matview_safely(
  p_view_name TEXT,
  p_timeout_ms INT DEFAULT 900000 -- 15 minute safety timeout
)
RETURNS TABLE (
  view_name TEXT,
  status TEXT,
  duration_ms NUMERIC,
  message TEXT
) 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_lock_key BIGINT;
  v_lock_acquired BOOLEAN;
  v_start_time TIMESTAMPTZ;
  v_duration_ms NUMERIC;
BEGIN
  -- Generate deterministic 64-bit advisory lock key from view name
  v_lock_key := ('x' || SUBSTR(MD5(p_view_name), 1, 16))::BIT(64)::BIGINT;
  v_start_time := CLOCK_TIMESTAMP();

  -- Attempt non-blocking advisory lock
  v_lock_acquired := pg_try_advisory_lock(v_lock_key);

  IF NOT v_lock_acquired THEN
    -- Another worker is already refreshing this view; exit gracefully!
    RETURN QUERY SELECT 
      p_view_name,
      'SKIPPED'::TEXT,
      0.0::NUMERIC,
      'Another refresh is currently active for this view. Execution coalesced.'::TEXT;
    RETURN;
  END IF;

  BEGIN
    -- Configure strict timeouts for this refresh session
    EXECUTE FORMAT('SET LOCAL statement_timeout = %L', p_timeout_ms);
    EXECUTE 'SET LOCAL lock_timeout = 5000'; -- 5s max wait for lock acquisition

    -- Execute concurrent non-blocking refresh
    EXECUTE FORMAT('REFRESH MATERIALIZED VIEW CONCURRENTLY %I', p_view_name);

    v_duration_ms := EXTRACT(EPOCH FROM (CLOCK_TIMESTAMP() - v_start_time)) * 1000.0;

    -- Release advisory lock
    PERFORM pg_advisory_unlock(v_lock_key);

    RETURN QUERY SELECT 
      p_view_name,
      'SUCCESS'::TEXT,
      ROUND(v_duration_ms, 2),
      'Concurrent refresh completed successfully.'::TEXT;

  EXCEPTION WHEN OTHERS THEN
    -- Guarantee advisory lock release even on error
    PERFORM pg_advisory_unlock(v_lock_key);
    RAISE;
  END;
END;
$$;
```

### 4.3. The Zero-Bloat Shadow Table Swap (Blue-Green View Rotation)

For massive analytical rollups with millions of rows where `REFRESH CONCURRENTLY` generates excessive MVCC dead tuples or is too slow, use the **Shadow Table Swap** pattern. This builds a clean heap table out-of-band and performs a sub-millisecond atomic rename:

```sql
-- ============================================================================
-- SHADOW TABLE ROTATION (BLUE-GREEN ZERO-BLOAT REFRESH)
-- ============================================================================

-- Step 1: Create an unlogged or standard staging table matching target schema
DROP TABLE IF EXISTS mv_tenant_daily_revenue_shadow;

CREATE TABLE mv_tenant_daily_revenue_shadow AS
SELECT
  o.tenant_id,
  DATE_TRUNC('day', o.created_at) AS report_date,
  COUNT(o.id) AS total_orders,
  SUM(o.amount_cents) AS gross_revenue_cents,
  COUNT(DISTINCT o.customer_id) AS active_customers,
  NOW() AS refreshed_at
FROM orders o
WHERE o.status = 'completed'
GROUP BY o.tenant_id, DATE_TRUNC('day', o.created_at);

-- Step 2: Build indexes concurrently or directly on shadow table (no traffic yet!)
CREATE UNIQUE INDEX idx_mv_tenant_daily_revenue_shadow_pk
  ON mv_tenant_daily_revenue_shadow (tenant_id, report_date);

CREATE INDEX idx_mv_tenant_daily_revenue_shadow_date
  ON mv_tenant_daily_revenue_shadow (report_date DESC);

-- Analyze statistics before swapping
ANALYZE mv_tenant_daily_revenue_shadow;

-- Step 3: Atomic Swap in a sub-millisecond transaction with tight lock_timeout
DO $$
BEGIN
  -- Strict 1000ms lock timeout to avoid queuing incoming read queries
  SET LOCAL lock_timeout = '1000ms';

  -- Rename current active table to old
  ALTER TABLE mv_tenant_daily_revenue RENAME TO mv_tenant_daily_revenue_old;
  -- Rename shadow table to active
  ALTER TABLE mv_tenant_daily_revenue_shadow RENAME TO mv_tenant_daily_revenue;

  -- Drop old table out-of-band or asynchronously
  DROP TABLE mv_tenant_daily_revenue_old;
EXCEPTION
  WHEN lock_not_available THEN
    RAISE EXCEPTION 'Could not acquire lock to swap materialized view shadow table within 1000ms';
END $$;
```

---

## 5. Complete TypeScript Production Engine: `AgenticDatabaseMaterializedViewEngine`

Here is the battle-tested, production-grade TypeScript engine managing materialized views, concurrent refreshes, advisory lock singleflight coalescing, staleness health monitoring, and shadow-swap failovers.

```typescript
import { Pool, PoolClient } from 'pg';
import crypto from 'node:crypto';

export interface MatViewConfig {
  name: string;
  uniqueKeyColumns: string[];
  maxStalenessSeconds: number;
  refreshTimeoutMs?: number;
  useShadowSwapThresholdRows?: number;
}

export interface MatViewRefreshResult {
  viewName: string;
  status: 'SUCCESS' | 'SKIPPED' | 'SWAPPED' | 'FAILED';
  durationMs: number;
  refreshedAt: Date;
  rowsAffected?: number;
  error?: string;
}

export interface MatViewHealthReport {
  viewName: string;
  isPopulated: boolean;
  hasUniqueIndex: boolean;
  rowCount: number;
  lastRefreshedAt: Date | null;
  stalenessSeconds: number;
  isStale: boolean;
  deadTupleRatio: number;
}

export class AgenticDatabaseMaterializedViewEngine {
  private inFlightRefreshes = new Map<string, Promise<MatViewRefreshResult>>();

  constructor(private readonly pool: Pool) {}

  /**
   * Generates a deterministic 64-bit signed integer advisory lock key from view name
   */
  private generateAdvisoryKey(viewName: string): string {
    const hash = crypto.createHash('sha256').update(viewName).digest('hex');
    // Take first 15 hex chars to fit safely in positive signed 64-bit integer
    const intVal = BigInt('0x' + hash.slice(0, 15));
    return intVal.toString();
  }

  /**
   * Refreshes a materialized view concurrently with singleflight coalescing and advisory locking.
   * If a refresh is already in flight for this view in this process or on another cluster node,
   * it coalesces or skips without blocking.
   */
  public async refreshConcurrently(config: MatViewConfig): Promise<MatViewRefreshResult> {
    // 1. Process-level singleflight coalescing
    if (this.inFlightRefreshes.has(config.name)) {
      return this.inFlightRefreshes.get(config.name)!;
    }

    const refreshPromise = this.executeRefreshWithAdvisoryLock(config);
    this.inFlightRefreshes.set(config.name, refreshPromise);

    try {
      return await refreshPromise;
    } finally {
      this.inFlightRefreshes.delete(config.name);
    }
  }

  private async executeRefreshWithAdvisoryLock(config: MatViewConfig): Promise<MatViewRefreshResult> {
    const startTime = Date.now();
    const lockKey = this.generateAdvisoryKey(config.name);
    const timeoutMs = config.refreshTimeoutMs ?? 900_000; // 15 min default
    let client: PoolClient | null = null;

    try {
      client = await this.pool.connect();

      // Step 1: Pre-flight Unique Index Validation
      const indexCheck = await client.query<{ exists: boolean }>(
        `
        SELECT EXISTS (
          SELECT 1
          FROM pg_index i
          JOIN pg_class c ON c.oid = i.indrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relname = $1
            AND i.indisunique = true
            AND i.indpred IS NULL -- Must not be partial
        ) as exists;
        `,
        [config.name]
      );

      if (!indexCheck.rows[0]?.exists) {
        throw new Error(
          `Materialized view "${config.name}" lacks a non-partial UNIQUE INDEX! REFRESH CONCURRENTLY will fail.`
        );
      }

      // Step 2: Attempt Database-Level Non-Blocking Advisory Lock
      const lockRes = await client.query<{ acquired: boolean }>(
        `SELECT pg_try_advisory_lock($1::bigint) as acquired;`,
        [lockKey]
      );

      if (!lockRes.rows[0]?.acquired) {
        return {
          viewName: config.name,
          status: 'SKIPPED',
          durationMs: Date.now() - startTime,
          refreshedAt: new Date(),
        };
      }

      // Step 3: Set strict session timeouts for the refresh operation
      await client.query(`SET LOCAL statement_timeout = ${timeoutMs};`);
      await client.query(`SET LOCAL lock_timeout = '3000ms';`);

      // Step 4: Execute Non-Blocking Concurrent Refresh
      await client.query(`REFRESH MATERIALIZED VIEW CONCURRENTLY ${client.escapeIdentifier(config.name)};`);

      // Step 5: Update staleness tracker metadata table if present
      await client.query(
        `
        INSERT INTO matview_refresh_telemetry (view_name, last_refreshed_at, duration_ms)
        VALUES ($1, NOW(), $2)
        ON CONFLICT (view_name) DO UPDATE
        SET last_refreshed_at = EXCLUDED.last_refreshed_at,
            duration_ms = EXCLUDED.duration_ms;
        `,
        [config.name, Date.now() - startTime]
      ).catch(() => {
        // Non-fatal if telemetry table doesn't exist yet
      });

      return {
        viewName: config.name,
        status: 'SUCCESS',
        durationMs: Date.now() - startTime,
        refreshedAt: new Date(),
      };
    } catch (err: any) {
      return {
        viewName: config.name,
        status: 'FAILED',
        durationMs: Date.now() - startTime,
        refreshedAt: new Date(),
        error: err?.message ?? String(err),
      };
    } finally {
      if (client) {
        // Guarantee advisory lock release
        await client.query(`SELECT pg_advisory_unlock($1::bigint);`, [lockKey]).catch(() => {});
        client.release();
      }
    }
  }

  /**
   * Inspects the health, row count, bloat ratio, and staleness of a materialized view.
   */
  public async getHealthReport(viewName: string, maxStalenessSeconds: number): Promise<MatViewHealthReport> {
    const client = await this.pool.connect();
    try {
      const res = await client.query<{
        is_populated: boolean;
        has_unique_index: boolean;
        row_count: string;
        dead_tuples: string;
        last_refreshed_at: Date | null;
      }>(
        `
        SELECT
          c.relispopulated as is_populated,
          EXISTS (
            SELECT 1 FROM pg_index i 
            WHERE i.indrelid = c.oid AND i.indisunique = true AND i.indpred IS NULL
          ) as has_unique_index,
          COALESCE(s.n_live_tup, 0) as row_count,
          COALESCE(s.n_dead_tup, 0) as dead_tuples,
          t.last_refreshed_at
        FROM pg_class c
        LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
        LEFT JOIN matview_refresh_telemetry t ON t.view_name = c.relname
        WHERE c.relname = $1 AND c.relkind = 'm';
        `,
        [viewName]
      );

      if (res.rows.length === 0) {
        throw new Error(`Materialized view "${viewName}" does not exist in pg_class.`);
      }

      const row = res.rows[0];
      const rowCount = Number(row.row_count);
      const deadTuples = Number(row.dead_tuples);
      const deadTupleRatio = rowCount + deadTuples > 0 ? deadTuples / (rowCount + deadTuples) : 0;
      
      const lastRefreshedAt = row.last_refreshed_at ? new Date(row.last_refreshed_at) : null;
      const stalenessSeconds = lastRefreshedAt
        ? Math.floor((Date.now() - lastRefreshedAt.getTime()) / 1000)
        : Number.MAX_SAFE_INTEGER;

      return {
        viewName,
        isPopulated: row.is_populated,
        hasUniqueIndex: row.has_unique_index,
        rowCount,
        lastRefreshedAt,
        stalenessSeconds,
        isStale: stalenessSeconds > maxStalenessSeconds,
        deadTupleRatio: Math.round(deadTupleRatio * 100) / 100,
      };
    } finally {
      client.release();
    }
  }
}
```

---

## 6. The 6-State Materialized View Lifecycle Finite-State Machine (FSM)

```
        ┌─────────────────────────────────────────────────────────────┐
        │                                                             │
        ▼                                                             │
┌───────────────┐  Validate Indexes   ┌────────────────┐  Acquire Mutex  ┌───────────────┐
│  UNPOPULATED  │ ──────────────────> │  INDEX_SYNCED  │ ──────────────> │ LOCK_ACQUIRED │
│ (WITH NO DATA)│                     │ (Unique Index) │                 │(Advisory Lock)│
└───────────────┘                     └────────────────┘                 └───────────────┘
                                                                                 │
                                                                                 │ Stream Refresh
                                                                                 ▼
┌───────────────┐  Zero-Lock Rename   ┌────────────────┐  Diff Finished  ┌───────────────┐
│ ACTIVE_READY  │ <────────────────── │ SHADOW_SWAPPED │ <────────────── │ REFRESHING_   │
│ (Refreshed At)│                     │  (Tier 3 Swap) │  (or In-Place)  │  CONCURRENTLY │
└───────────────┘                     └────────────────┘                 └───────────────┘
        │                                                                        │
        │ Staleness Threshold Exceeded (age > TTL)                              │ Lock Conflict
        └────────────────────────────────────────────────────────────────────────┴─> SKIPPED
```

1. **`UNPOPULATED`**: The view was created during migration using `WITH NO DATA`. Zero locks, zero table scans.
2. **`INDEX_SYNCED`**: A non-partial, non-nullable `UNIQUE INDEX` has been constructed concurrently outside transaction boundaries.
3. **`LOCK_ACQUIRED`**: Worker invokes `pg_try_advisory_lock`. If another process holds the lock, execution gracefully transitions to `SKIPPED`.
4. **`REFRESHING_CONCURRENTLY`**: PostgreSQL computes query results in a temp heap and performs non-blocking diff updates.
5. **`SHADOW_SWAPPED`** (Optional Tier 3): If row count exceeds threshold, staging shadow table is populated out-of-band and atomically renamed.
6. **`ACTIVE_READY`**: Telemetry metadata is updated with completion duration and timestamp. Read queries are routed to fresh data.

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Category | Invariant Rule | Verification Command / Check | Severity |
|---|---|---|---|---|
| **G1** | **Migration Safety** | Materialized views must be defined `WITH NO DATA` in migrations | Search migration files for `CREATE MATERIALIZED VIEW` without `WITH NO DATA` | **FATAL** |
| **G2** | **Unique Index** | Must have at least one non-partial unique index before concurrent refresh | `SELECT indisunique FROM pg_index WHERE indrelid = 'mv_name'::regclass AND indpred IS NULL` | **FATAL** |
| **G3** | **Locking Invariant** | Production code must NEVER call `REFRESH MATERIALIZED VIEW` without `CONCURRENTLY` | `git grep -i "REFRESH MATERIALIZED VIEW" \| grep -v "CONCURRENTLY"` | **FATAL** |
| **G4** | **Thundering Herd** | Must use `pg_try_advisory_lock` or singleflight before initiating refresh | Code review checking advisory lock wrapper presence | **HIGH** |
| **G5** | **Timeout Ladder** | Refresh session must enforce `statement_timeout` <= 15m and `lock_timeout` <= 5s | Validate `SET LOCAL statement_timeout` in refresh handler | **HIGH** |
| **G6** | **Bloat Defense** | Autovacuum cost limits must be raised (`vacuum_cost_limit >= 2000`) for high-churn MVs | `SELECT reloptions FROM pg_class WHERE relname = 'mv_name'` | **MEDIUM** |

---

## 8. Autonomous Agent Execution Checklist

Before modifying any materialized view, reporting rollup, or analytics caching pipeline:

- [ ] **Mandatory Pre-Flight Checks**:
  - [ ] Confirm migration scripts use `CREATE MATERIALIZED VIEW ... WITH NO DATA`.
  - [ ] Verify that a `CREATE UNIQUE INDEX CONCURRENTLY` statement is present covering non-nullable key columns.
  - [ ] Check if the view is referenced by other queries before altering column definitions.
- [ ] **During Refresh Execution**:
  - [ ] Ensure all refreshes use `REFRESH MATERIALIZED VIEW CONCURRENTLY`.
  - [ ] Wrap refreshes with `pg_try_advisory_lock(hashtext('mv_name'))` to prevent parallel thundering herds.
  - [ ] Set `statement_timeout` and `lock_timeout` to prevent hung queries from pinning `$x_{\text{min}}$`.
- [ ] **High-Volume Datasets ($N > 2\times 10^6$)**:
  - [ ] Evaluate the **Tier 3 Shadow Table Swap** pattern instead of `CONCURRENTLY` to avoid generating millions of dead tuples.
  - [ ] Test the atomic rename block with a 1000ms `lock_timeout` rollback guarantee.
- [ ] **Post-Execution Verification**:
  - [ ] Query `pg_stat_user_tables` to confirm dead tuple ratio is below 20%.
  - [ ] Verify frontend dashboard receives fresh `refreshed_at` timestamps and responds with HTTP 200.
