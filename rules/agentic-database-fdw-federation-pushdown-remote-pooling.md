---
description: PostgreSQL Foreign Data Wrappers (postgres_fdw), cross-database query federation, remote predicate/aggregate/join pushdown optimization, remote connection pool lifecycle fencing, prepared transaction recovery (pg_prepared_xacts), and sharded routing across Go (pgx/v5), TypeScript (Drizzle/Kysely), Python (psycopg3), Rust (tokio-postgres), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{fdw,federat,foreign,remote,sharding,crossdb,dblink,postgres_fdw,distrib}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Foreign Data Wrappers (FDW), Cross-Database Query Federation, Remote Pushdown Optimization & Distributed Connection Pool Fencing

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design federated architectures, cross-database microservice queries, multi-cluster sharding, data virtualization layers, or remote foreign tables using PostgreSQL Foreign Data Wrappers (`postgres_fdw`), Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `pg`), Python (`psycopg3`), or Rust (`tokio-postgres`). Eliminate the "Missing Predicate & Join Pushdown Wire-Spill Ingestion Avalanche" (where queries against foreign tables omit `use_remote_estimate` or invoke non-immutable functions, forcing PostgreSQL to stream 50 million remote rows across the network wire into local shared buffers, saturating NIC bandwidth and triggering catastrophic local disk temp spills), the "Remote Transaction Leak & Stale Connection Starvation Disaster" (where `keep_connections = on` without bounded connection recycling leaves remote sessions lingering in `idle in transaction`, holding remote table locks, pinning the remote `$x_{\text{min}}$` autovacuum horizon, and exhausting remote `max_connections`), the "FDW Cost Model Estimate Blindness & Nested Loop Join Trap" (where default `use_remote_estimate = false` assumes an arbitrary dummy row count of 1,000 for foreign tables regardless of real size, tricking the query planner into executing catastrophic nested loops over remote relations), the "Distributed Two-Phase Commit (2PC) & Orphaned Prepared Transaction Horizon" (where cross-server mutations with `postgres_fdw` leave in-doubt entries in `pg_prepared_xacts` following network partitions, preventing autovacuum from freezing transaction IDs and leading to emergency cluster shutdowns), the "Sharded Partition Routing & Broadcast Thundering Herd" (where foreign table partitions in declarative sharding fail partition pruning due to non-sargable predicates, broadcasting queries to dozens of remote database instances simultaneously), and the "User Mapping Privilege Escalation & Cleartext Secret Exfiltration Trap" (where `CREATE USER MAPPING` exposes remote superuser credentials in plaintext `pg_user_mappings` readable by unprivileged application roles) by establishing a strict 5-Tier FDW & Distributed Federation Governance Ladder, pushdown verification sentinels, automated in-doubt transaction recovery, and machine-verifiable CI test gates.

---

## 1. Architectural Taxonomy: The 6 FDW Catastrophes vs The 5-Tier Governance Ladder

Cross-database federation allows microservices, analytics pipelines, and multi-tenant architectures to query remote PostgreSQL databases as if they were local tables using the SQL/MED (Management of External Data, ISO/IEC 9075-9) standard via `postgres_fdw`. 

However, autonomous coding agents frequently treat foreign tables identically to local heap tables, entirely oblivious to network wire serialization latency, remote query planning pushdown mechanics, distributed connection retention, and two-phase commit recovery.

```typescript
// ❌ CATASTROPHIC LLM FDW & FEDERATED QUERY ANTI-PATTERNS

// 1. The Missing Pushdown Wire-Spill Ingestion Avalanche!
// Invoking a non-immutable function (NOW()) or mismatched collation prevents postgres_fdw
// from pushing the WHERE filter to the remote server. PostgreSQL downloads 50,000,000 rows
// over the network into local memory, triggering OOM and 45-second latency!
const results = await db.query(`
  SELECT u.id, u.email, o.amount
  FROM foreign_users u
  JOIN local_orders o ON o.user_id = u.id
  WHERE u.created_at >= NOW() - INTERVAL '7 days'; -- Non-immutable NOW() blocks remote pushdown!
`);

// 2. The Cost Model Estimate Blindness & Nested Loop Trap!
// By default, use_remote_estimate is false. PostgreSQL assumes foreign_users has exactly 1,000 rows.
// In reality, foreign_users has 80,000,000 rows. Planner chooses Nested Loop over foreign table,
// issuing 50,000 individual remote round-trips!
await db.query(`
  CREATE SERVER auth_cluster FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'auth-db.internal', dbname 'auth_prod', port '5432');
  -- Missing OPTIONS (use_remote_estimate 'true', fetch_size '2000')!
`);

// 3. The Remote Connection Leak & Idle-In-Transaction Lock Trap!
// Local transaction opens a remote foreign transaction. If the local code encounters an unhandled
// exception or hangs in an external HTTP call, the remote connection stays in "idle in transaction",
// holding RowShareLock on the remote table and blocking remote DDL and autovacuum!
const client = await pool.connect();
await client.query('BEGIN');
await client.query('SELECT * FROM foreign_billing_accounts WHERE id = $1', [accountId]);
await callExternalStripeWebhook(); // ❌ External network call blocks for 30s while remote DB locks!
await client.query('COMMIT');
```

### The 6 Catastrophes of Autonomous FDW & Federated Query Architectures

1. **The Missing Predicate & Join Pushdown Wire-Spill Ingestion Avalanche**:
   Autonomous agents routinely construct queries with expressions, non-immutable operators, or custom functions (such as `NOW()`, user-defined functions, or text operations with default collations) that `postgres_fdw` cannot safely push down to the remote server. When pushdown fails, PostgreSQL is forced to execute a `Foreign Scan` that retrieves **every single row and column** from the remote database across the WAN or VPC network, streaming gigabytes of unneeded raw tuples into local memory and spilling to temporary files on disk. Latency explodes from 5ms to over 60 seconds, saturating network interfaces and exhausting local `work_mem`.

2. **The Remote Transaction Leak & Stale Connection Starvation Disaster**:
   By default, `postgres_fdw` caches open client connections to foreign servers (`keep_connections = on`) to reduce connection establishment overhead. When application code opens a local transaction that accesses a foreign table, a corresponding remote transaction is initiated on the target cluster. If the local backend performs slow non-database I/O, leaks a checked-out connection, or fails to commit promptly, the remote backend remains trapped in `idle in transaction`. This holds remote locks, starves the remote cluster's `max_connections` pool, and pins the remote cluster's `$x_{\text{min}}$` autovacuum horizon, resulting in massive table bloat across the organization.

3. **The FDW Cost Model Estimate Blindness & Nested Loop Join Trap**:
   Without explicit configuration, `postgres_fdw` operates with `use_remote_estimate = false`. In this mode, the local query planner does not issue an `EXPLAIN` query to the remote database to sample real statistical distributions. Instead, it relies on static internal defaults, assuming every foreign table contains exactly 1,000 rows with a fixed cost. When joining a 50,000-row local table with an 80,000,000-row foreign table, the local optimizer erroneously selects a `Nested Loop` join with the foreign table as the inner relation, firing tens of thousands of individual parameterized network queries to the remote server.

4. **The Distributed Two-Phase Commit (2PC) & Orphaned Prepared Transaction Horizon**:
   When an autonomous agent performs write operations (`INSERT`, `UPDATE`, `DELETE`) across multiple foreign servers or combines local writes with foreign table writes, PostgreSQL utilizes distributed transaction semantics. If a network partition, client timeout, or server crash interrupts a transaction during the commit phase, the remote server may retain a prepared transaction in `pg_prepared_xacts`. Unlike standard aborted connections, **prepared transactions survive database restarts and client disconnects indefinitely**. They permanently hold locks and pin `$x_{\text{min}}$`, guaranteeing catastrophic database freezing due to transaction ID wraparound unless actively discovered and rolled back.

5. **The Sharded Partition Routing & Broadcast Thundering Herd**:
   In horizontally sharded architectures where a parent partitioned table routes across multiple foreign server partitions, agents often issue queries with expressions that bypass declarative partition pruning (`enable_partition_pruning = on`). Instead of routing the query to the single target shard holding the partition key, PostgreSQL issues concurrent foreign scans to **all** remote shard nodes. This produces a broadcast thundering herd, multiplying connection consumption and CPU utilization across the entire database fleet.

6. **The User Mapping Privilege Escalation & Cleartext Secret Exfiltration Trap**:
   Agents frequently execute `CREATE USER MAPPING FOR public SERVER foreign_srv OPTIONS (user 'postgres', password 'secret')`, mapping all local users—including read-only or untrusted roles—to a superuser on the remote cluster. The remote credentials are stored in cleartext in `pg_user_mappings` and `pg_shdescription`, accessible to local administrative roles. If a SQL injection vulnerability occurs on the local service, attackers immediately gain unrestricted read/write superuser control over the remote database.

---

## 2. The 5-Tier FDW & Distributed Federation Governance Ladder

To guarantee sub-10ms query execution, zero network wire spills, resilient connection management, and atomic distributed transaction safety, all autonomous agents must enforce the **5-Tier FDW Governance Ladder**:

```
+-----------------------------------------------------------------------------------+
|               5-TIER FDW & DISTRIBUTED FEDERATION GOVERNANCE LADDER               |
+===================================================================================+
| Tier 0: Remote Connection Fencing, Lifetime Management & Timeout Invariance       |
| - keep_connections = on with bounded max_client_conn recycling                     |
| - Mandatory fetch_size = 500-2000 preventing multi-megabyte memory buffers        |
| - Remote statement_timeout = 5s and idle_in_transaction_session_timeout = 3s      |
+-----------------------------------------------------------------------------------+
| Tier 1: Pushdown Invariance, Remote Estimation & Collation Alignment              |
| - Server & foreign table OPTIONS: use_remote_estimate 'true'                      |
| - Verify Remote SQL pushdown via EXPLAIN (VERBOSE): Foreign Scan Remote SQL filter|
| - Strict collation alignment (COLLATE "C") and immutable immutable function calls |
+-----------------------------------------------------------------------------------+
| Tier 2: Two-Phase Commit (2PC) Safety & Orphaned Prepared Transaction Sentinels   |
| - Autonomous watchdog querying pg_prepared_xacts with age(prepared) > 60s alert   |
| - Automated circuit breaker issuing ROLLBACK PREPARED for orphaned in-doubt xacts|
| - Read-only isolation for cross-cluster federation wherever mutations not strictly req|
+-----------------------------------------------------------------------------------+
| Tier 3: Partition-Aware Sharded Federation & Sargable Dynamic Pruning             |
| - Declarative Hash/Range partitioning with postgres_fdw foreign table partitions  |
| - Sargable WHERE predicates with zero functional wrappers on partition key        |
| - Assert EXPLAIN shows exactly 1 Foreign Scan partition node, 0 broadcast sweeps |
+-----------------------------------------------------------------------------------+
| Tier 4: Zero-Trust User Mapping Fencing & Dynamic Vault Token Integration         |
| - Dedicated unprivileged foreign roles with strict GRANT SELECT / INSERT schemas  |
| - Individual explicit USER MAPPINGS (no FOR public or wildcard superusers)        |
| - Automated credential rotation via HashiCorp Vault / AWS Secrets Manager tokens  |
+-----------------------------------------------------------------------------------+
```

---

## 3. Mathematical Foundations of Federated Pushdown & Distributed Connection Queues

### 3.1 Network Ingestion vs Pushdown Latency Differential Model

Let $N_{\text{remote}}$ be the total number of records in the remote foreign table, $S_{\text{tuple}}$ be the average byte size per serialized tuple, and $\sigma \in (0, 1]$ be the query predicate selectivity ($\sigma = \frac{N_{\text{filtered}}}{N_{\text{remote}}}$). Let $B_{\text{net}}$ represent network throughput (bytes/sec) and $\text{RTT}$ denote the round-trip latency between the local and remote clusters.

When predicate pushdown **fails**, the local node must fetch all $N_{\text{remote}}$ rows across the network in batches governed by `fetch_size`:

$$T_{\text{wire}} = \frac{N_{\text{remote}} \cdot S_{\text{tuple}}}{B_{\text{net}}} + \left\lceil \frac{N_{\text{remote}}}{\text{fetch\_size}} \right\rceil \cdot \text{RTT} + T_{\text{local\_filter}}$$

When predicate pushdown **succeeds**, only the matching filtered tuples traverse the wire, and filtering is executed at engine line-rate on the remote node:

$$T_{\text{pushdown}} = T_{\text{remote\_index\_scan}} + \frac{\sigma \cdot N_{\text{remote}} \cdot S_{\text{tuple}}}{B_{\text{net}}} + \left\lceil \frac{\sigma \cdot N_{\text{remote}}}{\text{fetch\_size}} \right\rceil \cdot \text{RTT}$$

The Latency Reduction Factor $\mathcal{G}_{\text{pushdown}}$ achieved by pushdown optimization is:

$$\mathcal{G}_{\text{pushdown}} = \frac{T_{\text{wire}}}{T_{\text{pushdown}}} \approx \frac{1}{\sigma} \quad \text{for } \sigma \ll 1 \text{ and } N_{\text{remote}} \gg 10^5$$

For a table with $10,000,000$ rows ($S_{\text{tuple}} = 200\text{ bytes}$, total size $2\text{ GB}$), an analytical query filtering $\sigma = 0.001$ ($10,000$ matching rows) over a 1 Gbps link ($B_{\text{net}} = 125\text{ MB/s}$, $\text{RTT} = 2\text{ms}$):
- **Without Pushdown**: $T_{\text{wire}} \approx \frac{2000\text{ MB}}{125\text{ MB/s}} + \left\lceil \frac{10^7}{100} \right\rceil \cdot 2\text{ms} = 16\text{s} + 200\text{s} = 216\text{ seconds}$ (Catastrophic timeout!).
- **With Pushdown & `fetch_size = 2000`**: $T_{\text{pushdown}} \approx 10\text{ms} + \frac{2\text{ MB}}{125\text{ MB/s}} + \left\lceil \frac{10^4}{2000} \right\rceil \cdot 2\text{ms} = 10\text{ms} + 16\text{ms} + 10\text{ms} = 36\text{ ms}$.
- **Performance Improvement**: $\mathcal{G}_{\text{pushdown}} = \frac{216,000\text{ms}}{36\text{ms}} = 6,000\times$ speedup.

### 3.2 Remote Connection Pool Starvation & Little's Law

Under `keep_connections = on`, every local PostgreSQL backend process that touches a foreign server retains a dedicated persistent connection to the remote cluster. By **Little's Law**, the steady-state number of concurrent remote connections $C_{\text{remote}}$ held by the local cluster is:

$$C_{\text{remote}} = \lambda_{\text{local}} \cdot W_{\text{hold}}$$

Where $\lambda_{\text{local}}$ is the arrival rate of local transactions accessing foreign tables, and $W_{\text{hold}}$ is the average duration a connection is held. If application code holds local transactions open during external HTTP calls or compute tasks ($W_{\text{hold}} \uparrow$), $C_{\text{remote}}$ surges linearly:

$$\lim_{W_{\text{hold}} \to \infty} C_{\text{remote}} > C_{\text{remote\_max}} \implies \text{Remote Database Rejection: "FATAL: remaining connection slots are reserved"}$$

To prevent remote connection starvation, the foreign server options must enforce strict session boundaries:
1. Local transactions must never perform non-database I/O while holding foreign table locks.
2. Remote servers must enforce `idle_in_transaction_session_timeout = 3000ms`.
3. High-density worker clusters must configure `keep_connections = off` or pool remote traffic through a dedicated foreign PgBouncer transaction-mode layer.

### 3.3 Prepared Transaction Vacuum Horizon Pinning

When a distributed transaction prepares a commit across foreign data wrappers, the transaction ID ($x_{\text{id}}$) is registered in the remote cluster's `pg_prepared_xacts` view. If uncommitted, this prepared transaction holds the global transaction snapshot horizon $x_{\text{min}}$ stationary:

$$x_{\text{min\_horizon}} = \min(x_{\text{active}}, x_{\text{prepared}})$$

As normal write traffic proceeds on the remote cluster, the age of this horizon increases monotonically:

$$\Delta x_{\text{min}} = \text{TxID}_{\text{current}} - \text{TxID}_{\text{prepared}}$$

When $\Delta x_{\text{min}}$ exceeds `autovacuum_freeze_max_age` ($200,000,000$ transactions), PostgreSQL begins issuing urgent warnings and will eventually force the entire remote cluster into **emergency read-only mode** to prevent transaction ID wraparound data corruption.

---

## 4. Production SQL & DDL Invariants for postgres_fdw

### 4.1 Server Definition, Security Mapping & Calibrated Options

```sql
-- 1. Install Extension
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- 2. Create Foreign Server with Calibrated Performance & Safety Invariants
CREATE SERVER IF NOT EXISTS analytics_cluster
  FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (
    host 'analytics-db.internal',
    port '5432',
    dbname 'analytics_dw',
    -- Invariant 1: Calibrated batch fetch size (default 100 causes severe RTT round-trip delays)
    fetch_size '2000',
    -- Invariant 2: Sample remote statistics for accurate query planning cost calculations
    use_remote_estimate 'true',
    -- Invariant 3: Enable remote sorting and limit pushdown
    extensions 'pg_trgm,btree_gist',
    -- Invariant 4: Bounded connection caching (PostgreSQL 14+)
    keep_connections 'on'
  );

-- 3. Dedicated Least-Privilege Foreign User Mapping (Zero Superusers!)
CREATE USER MAPPING IF NOT EXISTS FOR app_user
  SERVER analytics_cluster
  OPTIONS (
    user 'federated_app_readonly',
    password 'c4a9f8e12b7d3f0a9e8b7c6d5e4f3a2b1'
  );

-- 4. Import Foreign Schema with Surgical Table Inclusion (Never Import Entire Catalogs!)
IMPORT FOREIGN SCHEMA reporting_public
  LIMIT TO (daily_active_users, revenue_metrics, audit_events)
  FROM SERVER analytics_cluster
  INTO foreign_analytics;

-- 5. Foreign Table Explicit Definition with Strict Pushdown-Friendly Data Types
CREATE FOREIGN TABLE IF NOT EXISTS foreign_analytics.daily_active_users (
  id UUID NOT NULL,
  tenant_id UUID NOT NULL,
  user_id UUID NOT NULL,
  activity_date DATE NOT NULL,
  event_count INT NOT NULL,
  metadata JSONB
)
SERVER analytics_cluster
OPTIONS (
  schema_name 'reporting_public',
  table_name 'daily_active_users',
  use_remote_estimate 'true',
  fetch_size '2000'
);
```

### 4.2 Pushdown Verification Query Pattern

```sql
-- Production Verification: Ensure Filter, Aggregation, and Limit are Pushed to Foreign Server
EXPLAIN (VERBOSE, BUFFERS)
SELECT
  tenant_id,
  SUM(event_count) AS total_events
FROM foreign_analytics.daily_active_users
WHERE activity_date >= '2025-01-01'::DATE
  AND activity_date < '2025-02-01'::DATE
GROUP BY tenant_id
ORDER BY total_events DESC
LIMIT 10;

-- ✅ DESIRED PLAN OUTPUT:
-- Limit (cost=...)
--   ->  Foreign Scan (cost=...)
--         Output: tenant_id, (sum(event_count))
--         Relations: Aggregate on (reporting_public.daily_active_users)
--         Remote SQL: SELECT tenant_id, sum(event_count) FROM reporting_public.daily_active_users
--                     WHERE ((activity_date >= '2025-01-01'::date) AND (activity_date < '2025-02-01'::date))
--                     GROUP BY tenant_id ORDER BY (sum(event_count)) DESC LIMIT 10
-- (Notice: The entire WHERE, GROUP BY, and LIMIT are executed on the remote database!)
```

### 4.3 Automated Prepared Transaction Watchdog Sentinel

```sql
-- Query to detect orphaned distributed 2PC transactions older than 60 seconds
SELECT
  gid,
  prepared,
  owner,
  database,
  ROUND(EXTRACT(EPOCH FROM (CLOCK_TIMESTAMP() - prepared))) AS age_seconds
FROM pg_prepared_xacts
WHERE prepared < CLOCK_TIMESTAMP() - INTERVAL '60 seconds'
ORDER BY prepared ASC;

-- Automated In-Doubt Prepared Transaction Emergency Cleanup Procedure:
-- If an orphaned prepared transaction from postgres_fdw exceeds safety limits:
-- ROLLBACK PREPARED 'gid_identifier';
```

---

## 5. Complete TypeScript Production Engine: `AgenticDatabaseFDWEngine`

Below is the complete, production-grade TypeScript implementation for managing `postgres_fdw` foreign servers, verifying query pushdown in CI/CD, auditing remote connection pools, and monitoring/recovering distributed in-doubt prepared transactions.

```typescript
/**
 * AgenticDatabaseFDWEngine - Autonomous PostgreSQL Foreign Data Wrapper Federation Engine
 * Enforces remote pushdown invariants, manages connection pooling, and reconciles 2PC transactions.
 */

import { Pool, PoolClient } from 'pg';

export interface FDWServerConfig {
  serverName: string;
  host: string;
  port: number;
  database: string;
  foreignUser: string;
  foreignPasswordSecretRef: string;
  fetchSize: number;
  useRemoteEstimate: boolean;
  keepConnections: boolean;
  remoteStatementTimeoutMs: number;
}

export interface PushdownAuditResult {
  query: string;
  isPushdownSuccessful: boolean;
  isFilterPushed: boolean;
  isAggregatePushed: boolean;
  isLimitPushed: boolean;
  remoteSqlSnippet: string | null;
  rawExplainLines: string[];
  recommendations: string[];
}

export interface PreparedTransactionRecord {
  gid: string;
  preparedAt: Date;
  owner: string;
  database: string;
  ageSeconds: number;
}

export interface ShardRoutingTarget {
  shardId: string;
  foreignServer: string;
  foreignTable: string;
}

export class AgenticDatabaseFDWEngine {
  private localPool: Pool;

  constructor(localPool: Pool) {
    this.localPool = localPool;
  }

  /**
   * Provision or reconcile a postgres_fdw foreign server with strict safety options.
   */
  async provisionForeignServer(config: FDWServerConfig, localAppUser: string): Promise<void> {
    const client = await this.localPool.connect();
    try {
      await client.query('BEGIN');

      // 1. Ensure postgres_fdw extension exists
      await client.query('CREATE EXTENSION IF NOT EXISTS postgres_fdw;');

      // 2. Check if server already exists
      const checkServer = await client.query(
        'SELECT srvname FROM pg_foreign_server WHERE srvname = $1;',
        [config.serverName]
      );

      const serverOptions = [
        `host '${config.host}'`,
        `port '${config.port}'`,
        `dbname '${config.database}'`,
        `fetch_size '${config.fetchSize}'`,
        `use_remote_estimate '${config.useRemoteEstimate ? 'true' : 'false'}'`,
        `keep_connections '${config.keepConnections ? 'on' : 'off'}'`,
      ].join(', ');

      if (checkServer.rows.length === 0) {
        await client.query(`
          CREATE SERVER ${config.serverName}
            FOREIGN DATA WRAPPER postgres_fdw
            OPTIONS (${serverOptions});
        `);
      } else {
        // Reconcile server options
        await client.query(`
          ALTER SERVER ${config.serverName}
            OPTIONS (
              SET fetch_size '${config.fetchSize}',
              SET use_remote_estimate '${config.useRemoteEstimate ? 'true' : 'false'}',
              SET keep_connections '${config.keepConnections ? 'on' : 'off'}'
            );
        `);
      }

      // 3. User mapping for designated local application user
      const checkMapping = await client.query(`
        SELECT um.umid
        FROM pg_user_mapping um
        JOIN pg_roles r ON r.oid = um.umuser
        JOIN pg_foreign_server s ON s.oid = um.umserver
        WHERE r.rolname = $1 AND s.srvname = $2;
      `, [localAppUser, config.serverName]);

      // Resolve plaintext credentials securely from secret manager
      const resolvedPassword = await this.resolveSecret(config.foreignPasswordSecretRef);

      if (checkMapping.rows.length === 0) {
        await client.query(`
          CREATE USER MAPPING FOR ${localAppUser}
            SERVER ${config.serverName}
            OPTIONS (user '${config.foreignUser}', password '${resolvedPassword}');
        `);
      } else {
        await client.query(`
          ALTER USER MAPPING FOR ${localAppUser}
            SERVER ${config.serverName}
            OPTIONS (SET user '${config.foreignUser}', SET password '${resolvedPassword}');
        `);
      }

      // 4. Grant server usage strictly to the application role
      await client.query(`GRANT USAGE ON FOREIGN SERVER ${config.serverName} TO ${localAppUser};`);

      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw new Error(`Failed to provision foreign server ${config.serverName}: ${(error as Error).message}`);
    } finally {
      client.release();
    }
  }

  /**
   * Audit an SQL query against foreign tables to verify that predicates and operations are pushed down.
   */
  async auditQueryPushdown(sql: string, params: any[] = []): Promise<PushdownAuditResult> {
    const client = await this.localPool.connect();
    try {
      // Execute EXPLAIN (VERBOSE) to inspect Remote SQL statements
      const explainQuery = `EXPLAIN (VERBOSE, FORMAT TEXT) ${sql}`;
      const res = await client.query(explainQuery, params);
      const lines: string[] = res.rows.map((r: any) => r['QUERY PLAN']);

      let isFilterPushed = false;
      let isAggregatePushed = false;
      let isLimitPushed = false;
      let remoteSqlSnippet: string | null = null;
      const recommendations: string[] = [];

      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed.startsWith('Remote SQL:')) {
          remoteSqlSnippet = trimmed;
          const upperRemote = trimmed.toUpperCase();

          if (upperRemote.includes('WHERE')) {
            isFilterPushed = true;
          }
          if (upperRemote.includes('GROUP BY') || upperRemote.includes('SUM(') || upperRemote.includes('COUNT(')) {
            isAggregatePushed = true;
          }
          if (upperRemote.includes('LIMIT')) {
            isLimitPushed = true;
          }
        }
      }

      // Check if original query expected filtering but remote SQL lacks WHERE
      const upperQuery = sql.toUpperCase();
      if (upperQuery.includes('WHERE') && !isFilterPushed) {
        recommendations.push(
          'CRITICAL: WHERE clause was not pushed down to remote server! Check for non-immutable functions, unaligned collations, or missing extensions on foreign server.'
        );
      }

      if (upperQuery.includes('GROUP BY') && !isAggregatePushed) {
        recommendations.push(
          'WARNING: Aggregate was evaluated locally. Verify that aggregate expressions only use built-in immutable operators.'
        );
      }

      if (upperQuery.includes('LIMIT') && !isLimitPushed) {
        recommendations.push(
          'WARNING: LIMIT was not pushed down. All candidate rows are traversing the network before being discarded locally.'
        );
      }

      const isPushdownSuccessful = recommendations.length === 0 && remoteSqlSnippet !== null;

      return {
        query: sql,
        isPushdownSuccessful,
        isFilterPushed,
        isAggregatePushed,
        isLimitPushed,
        remoteSqlSnippet,
        rawExplainLines: lines,
        recommendations,
      };
    } finally {
      client.release();
    }
  }

  /**
   * Watchdog to inspect and clean up orphaned distributed prepared transactions (2PC).
   */
  async inspectAndReconcilePreparedTransactions(maxAgeSeconds: number = 60): Promise<PreparedTransactionRecord[]> {
    const client = await this.localPool.connect();
    try {
      const res = await client.query(`
        SELECT
          gid,
          prepared,
          owner,
          database,
          ROUND(EXTRACT(EPOCH FROM (CLOCK_TIMESTAMP() - prepared))) AS age_seconds
        FROM pg_prepared_xacts
        WHERE prepared < CLOCK_TIMESTAMP() - ($1 || ' seconds')::INTERVAL
        ORDER BY prepared ASC;
      `, [maxAgeSeconds]);

      const orphaned: PreparedTransactionRecord[] = res.rows.map((r: any) => ({
        gid: r.gid,
        preparedAt: new Date(r.prepared),
        owner: r.owner,
        database: r.database,
        ageSeconds: Number(r.age_seconds),
      }));

      // Autonomously roll back expired in-doubt prepared transactions
      for (const tx of orphaned) {
        console.warn(`[FDW-WATCHDOG] Rolling back orphaned prepared transaction: ${tx.gid} (age: ${tx.ageSeconds}s)`);
        // Escape GID safely
        const sanitizedGid = tx.gid.replace(/'/g, "''");
        await client.query(`ROLLBACK PREPARED '${sanitizedGid}';`);
      }

      return orphaned;
    } finally {
      client.release();
    }
  }

  /**
   * Safely discard cached remote connections to free up remote backend slots.
   */
  async discardCachedRemoteConnections(serverName?: string): Promise<void> {
    const client = await this.localPool.connect();
    try {
      if (serverName) {
        // Discard connections for specific foreign server (PostgreSQL 14+)
        await client.query('SELECT postgres_fdw_disconnect($1);', [serverName]);
      } else {
        // Discard all cached foreign connections on current backend
        await client.query('SELECT postgres_fdw_disconnect_all();');
      }
    } finally {
      client.release();
    }
  }

  private async resolveSecret(secretRef: string): Promise<string> {
    // In production, integrate with AWS Secrets Manager, HashiCorp Vault, or GCP Secret Manager
    if (process.env[secretRef]) {
      return process.env[secretRef]!;
    }
    return secretRef; // Fallback to provided value in test harness
  }
}
```

---

## 6. The 6-State FDW Lifecycle Finite-State Machine (FSM)

```
                 +-------------------+
                 |   DISCONNECTED    |
                 +-------------------+
                           |
                     (probeRemote)
                           v
                 +-------------------+
                 |     PROBING       |
                 +-------------------+
                     /           \
           (probeSuccess)     (probeFail / Timeout)
                   /               \
                  v                 v
       +--------------------+     +--------------------+
       |  FEDERATED_ACTIVE  |     |  CIRCUIT_TRIPPED   |
       +--------------------+     +--------------------+
             |        ^                      ^
  (pushdownAssert) (recheck)                 |
             v        |                      | (consecutiveTimeout)
       +--------------------+                |
       | PUSHDOWN_VALIDATED |                |
       +--------------------+                |
             |                               |
     (orphan2PCDetected)                     |
             v                               |
       +--------------------+                |
       | RECOVERING_IN_DOUBT|----------------+
       +--------------------+
```

### State Transition Invariants

1. **`DISCONNECTED` $\to$ `PROBING`**:
   Triggered on service initialization or configuration reload. Tests remote TCP reachability, authenticates via user mapping, and validates extension version compatibility.
2. **`PROBING` $\to$ `FEDERATED_ACTIVE`**:
   Remote handshake succeeds, remote latency $\le 20\text{ms}$, and remote server options (`fetch_size`, `use_remote_estimate`) match production thresholds.
3. **`FEDERATED_ACTIVE` $\to$ `PUSHDOWN_VALIDATED`**:
   The CI/CD query auditor or startup self-test executes `EXPLAIN (VERBOSE)` on critical foreign queries, asserting that all `WHERE` and `LIMIT` expressions appear inside `Remote SQL`.
4. **`FEDERATED_ACTIVE` $\to$ `CIRCUIT_TRIPPED`**:
   Remote cluster experiences connection timeouts ($> 3000\text{ms}$), remote `max_connections` exhaustion, or TLS certificate expiration. Trips the local circuit breaker to fast-fail local requests in 0ms without exhausting the local pool.
5. **`PUSHDOWN_VALIDATED` $\to$ `RECOVERING_IN_DOUBT`**:
   The background watchdog detects entries in `pg_prepared_xacts` exceeding 60 seconds. Suspends foreign writes and executes automated `ROLLBACK PREPARED` to protect the `$x_{\text{min}}$` autovacuum horizon.
6. **`RECOVERING_IN_DOUBT` $\to$ `FEDERATED_ACTIVE`**:
   All orphaned prepared transactions are successfully rolled back, and remote autovacuum metrics confirm normal operational status.

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

All pull requests, migrations, and schema modifications involving foreign tables, `postgres_fdw`, or federated queries must satisfy all 6 gates before merging:

| Gate | Verification Target | Automated Command / Assertion | Threshold |
| :--- | :--- | :--- | :--- |
| **Gate 1: Connection & Fetch Sizing** | Server configuration options | `SELECT srvoptions FROM pg_foreign_server WHERE srvname = 'target_srv'` | `fetch_size >= 500`, `use_remote_estimate = true` |
| **Gate 2: Remote Pushdown Invariance** | Wire-spill prevention | `EXPLAIN (VERBOSE) <query>` check for `Remote SQL: ... WHERE` | `isPushdownSuccessful === true`, 0 local filter scans |
| **Gate 3: Remote Statistics Invariance** | Cost model calibration | `SELECT last_analyze FROM pg_stat_user_tables WHERE relname = 'foreign_tbl'` | Remote table analyzed within $\le 24$ hours |
| **Gate 4: In-Doubt 2PC Orphan Sentinel** | Vacuum horizon defense | `SELECT count(*) FROM pg_prepared_xacts WHERE age(prepared) > interval '60s'` | `count === 0` |
| **Gate 5: Partition Pruning Single Shard** | Anti-broadcast sharding | `EXPLAIN <partitioned_query>` count of `Foreign Scan` nodes | Exactly 1 partition scan for point lookups (zero fleet broadcast) |
| **Gate 6: Zero-Trust Privilege Boundary** | User mapping security | `SELECT rolsuper FROM pg_roles WHERE rolname = (foreign mapping user)` | `rolsuper === false`, dedicated unprivileged user |

---

## 8. Autonomous Agent Execution Checklist

When tasked with creating, modifying, or querying foreign tables or federated architectures, coding agents must execute the following sequence:

1. [ ] **Inspect Remote Cluster Topology**: Verify network latency ($\text{RTT} \le 10\text{ms}$) and remote PostgreSQL version compatibility before creating foreign servers.
2. [ ] **Enforce Calibrated Server Options**: Always specify `OPTIONS (fetch_size '2000', use_remote_estimate 'true', keep_connections 'on')` during `CREATE SERVER`.
3. [ ] **Audit Query Plans with EXPLAIN (VERBOSE)**: Verify that all filters, ordering, and aggregations are pushed to the remote cluster. Eliminate any non-immutable functions or collation mismatches.
4. [ ] **Isolate Transactions from External I/O**: Never invoke external HTTP APIs, Stripe webhooks, or slow LLM generation while holding transactions that access foreign tables.
5. [ ] **Deploy Prepared Transaction Watchdogs**: Ensure automated monitoring of `pg_prepared_xacts` to detect and roll back orphaned distributed commits before autovacuum horizons are pinned.
6. [ ] **Enforce Least Privilege User Mappings**: Never map foreign servers to superusers or wildcard roles. Use granular, schema-restricted read/write credentials.
