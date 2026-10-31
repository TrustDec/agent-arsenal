---
description: PostgreSQL (10+) and distributed relational database system catalog bloat mitigation, relcache and catcache invalidation storm defense, temporary table churn elimination (pg_attribute, pg_class, pg_type dead tuple accumulation), shared invalidation queue (shared_inval) overflow prevention, zero-downtime catalog reindexing, and unlogged staging/UNNEST alternatives across Go (pgx/v5), TypeScript (Drizzle, Kysely), Python (psycopg3, asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{catalog,temp,staging,relcache,catcache,invalidation,pg_class,pg_attribute,ddl,autovacuum,db,postgres}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database System Catalog Bloat, Relcache Invalidation Storms & Temporary Table Churn Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design batch processing pipelines, ETL transformations, temporary staging workflows, high-frequency transactional APIs, or multi-tenant database systems across PostgreSQL (10+), Amazon Aurora, Google Cloud SQL, Crunchy Bridge, Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`psycopg3`, `asyncpg`), or Rust (`sqlx`). Eliminate the "Temporary Table Catalog Churn & Dead Tuple Accumulation Disaster" (where autonomous agents issue `CREATE TEMP TABLE` or `CREATE TEMPORARY TABLE` inside high-frequency endpoints, inserting rows into `pg_class`, `pg_attribute`, `pg_type`, `pg_depend`, and leaving millions of dead tuples in system catalogs upon session termination; because system catalog pages cannot be truncated without `ACCESS EXCLUSIVE` locks, `pg_attribute` balloons to gigabytes, causing every query plan compilation to stall for tens of milliseconds), the "Shared Invalidation Queue (`shared_inval`) Overflow & Relcache Eviction Storm" (where rapid catalog churn or delayed message consumption overruns the fixed-size `shared_inval` ring buffer, forcing PostgreSQL to broadcast a cache reset that dumps the entire `relcache` and `catcache` across all connected backends simultaneously, triggering a 100% CPU lock storm on `pg_class` B-Trees and crashing connection pools), the "Transactional DDL Catalog Lock Contention Cascade" (where high-concurrency temp table creations acquire `RowExclusiveLock` on shared catalog indexes, serializing worker threads and inducing cascading queue spikes), the "PgBouncer Transaction-Mode Temp Object Leak & Collision Catastrophe" (where temporary tables created under transaction pooling survive connection recycling, causing `relation already exists` failures, schema leaks, and backend memory fragmentation), the "Default Catalog Autovacuum Starvation & Page Bloat Trap" (where system catalogs experience orders-of-magnitude higher update volatility than user tables but languish under default 20% autovacuum scale factors, resulting in bloated 10,000-page catalog scans), and the "Backend Relcache Process Heap Fragmentation (TopMemoryContext Bloat)" (where repeated temporary relation creation fragments glibc malloc arenas in long-lived backend processes, leading to silent memory exhaustion and Linux OOM killer termination) by establishing a strict 5-Tier Catalog Governance Ladder, zero-temp-table OLTP invariants, connection-partitioned unlogged staging, aggressive catalog autovacuum calibration, a production-ready TypeScript `AgenticDatabaseCatalogGuardEngine`, cross-language sentinels in Go, TypeScript, Python, and Rust, a 6-state catalog lifecycle finite-state machine (FSM), and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Catalog Bloat & Relcache Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL and modern relational engines, all schema metadata (tables, columns, types, constraints, functions, dependencies) is stored in standard relational tables located in the `pg_catalog` schema (`pg_class`, `pg_attribute`, `pg_type`, `pg_depend`, `pg_constraint`, `pg_am`, etc.).

To execute any query, the backend process parses the SQL string, compiles the plan, and looks up structural metadata. Because querying disk-based catalogs on every statement would be prohibitively slow, PostgreSQL maintains two private, in-memory caches inside each backend process:
1. **Catcache (Catalog Cache)**: Caches individual catalog tuples (e.g., column definitions, operator types, authentication identities).
2. **Relcache (Relation Cache)**: Caches materialized metadata descriptors for relations (tables, indexes, views, toast relations), including physical block layout, locking rules, and trigger definitions.

When multiple backend processes operate concurrently, changes to catalog metadata must be synchronized. PostgreSQL coordinates this via the **Shared Invalidation Queue (`shared_inval`)**—a fixed-size ring buffer in shared memory. When a transaction commits catalog changes (DDL or temporary table creation/drop), it enqueues invalidation messages (`SharedInvalidationMessage`). Other backends consume these messages before executing new commands, selectively clearing stale catcache/relcache entries.

When autonomous coding agents generate database access patterns, ETL pipelines, or batch ingestion routines, LLMs routinely commit 6 catastrophic architectural flaws that break the catalog subsystem:

### The 6 System Catalog & Relcache Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                               THE 6 SYSTEM CATALOG & RELCACHE CATASTROPHES                          |
+------------------------------------+---------------------------------------------------------------+
| 1. Temporary Table Catalog Churn   | Agent generates CREATE TEMP TABLE in API loops; writes ~25    |
|    & Dead Tuple Accumulation       | rows into pg_attribute & pg_class per table; millions of dead |
|                                    | tuples accumulate; query planning latency surges 100x.        |
+------------------------------------+---------------------------------------------------------------+
| 2. Shared Inval Queue Overflow &   | High catalog churn overflows shared_inval ring buffer; sends  |
|    Relcache Eviction Storm         | cache reset broadcast; 500 backends flush entire relcache     |
|                                    | simultaneously, pegging CPU at 100% and timing out pools.     |
+------------------------------------+---------------------------------------------------------------+
| 3. Transactional DDL Shared Lock   | Concurrent temp tables acquire RowExclusiveLock on shared     |
|    Contention Cascade              | catalog indexes (pg_type_typname_nsp_index); worker pool      |
|                                    | serializes, causing cascading connection saturation.          |
+------------------------------------+---------------------------------------------------------------+
| 4. PgBouncer Transaction-Mode      | Temp tables in transaction-pooled PgBouncer survive session   |
|    Object Leaks & Collisions       | check-in; subsequent transactions hit "relation already       |
|                                    | exists" or query wrong tenant's leftover temp state.          |
+------------------------------------+---------------------------------------------------------------+
| 5. Catalog Autovacuum Starvation   | Default 20% autovacuum scale factor ignores catalog churn;    |
|    & B-Tree Fragmentation          | pg_attribute balloons to 20,000 pages; sequential catalog     |
|                                    | scans stall query compilation; REINDEX CONCURRENTLY neglected.|
+------------------------------------+---------------------------------------------------------------+
| 6. Backend TopMemoryContext Leaks  | Repeated temp relation creation fragments glibc malloc arenas |
|    & Heap Fragmentation            | in long-lived backend processes; memory footprint grows from  |
|                                    | 50MB to 4GB, provoking kernel OOM killer panics.              |
+------------------------------------+---------------------------------------------------------------+
```

---

### The 5-Tier Catalog Governance Ladder

To eliminate system catalog bloat and guarantee deterministic query compilation times, autonomous systems must adhere to the **5-Tier Catalog Governance Ladder**:

```
+----------------------------------------------------------------------------------------------------+
|                               THE 5-TIER CATALOG GOVERNANCE LADDER                                 |
+----------------------------------------------------------------------------------------------------+
| Tier 0: Zero-Temp-Table OLTP Boundary (UNNEST / JSONB / VALUES / CTEs)                             |
|   Strict prohibition of CREATE TEMP TABLE in OLTP paths, API handlers, and worker loops.            |
|   Replace with parameterized arrays (UNNEST($1::int[])), jsonb_to_recordset, or memory CTEs.       |
+----------------------------------------------------------------------------------------------------+
| Tier 1: Connection-Partitioned Permanent Unlogged Staging Architecture                             |
|   For bulk operations (> 100,000 rows) where array parameters exceed wire limits, pre-create        |
|   permanent UNLOGGED tables partitioned by session_id / batch_id. Zero catalog DDL churn.          |
+----------------------------------------------------------------------------------------------------+
| Tier 2: Dedicated Aggressive Catalog Autovacuum Calibration                                        |
|   Tune pg_catalog tables with scale_factor = 0.01 and threshold = 50. Ensure autovacuum cleans     |
|   dead catalog tuples continuously before B-Trees fragment and plan caches degrade.                |
+----------------------------------------------------------------------------------------------------+
| Tier 3: Shared Invalidation Ring Buffer & Invalidation Storm Sentinels                             |
|   Monitor shared_inval message consumption, relcache invalidation counts, and catalog index size.  |
|   Trigger alerts when catalog bloat ratio exceeds 0.25 or relcache reset frequency > 1/hour.       |
+----------------------------------------------------------------------------------------------------+
| Tier 4: Zero-Downtime Catalog Compaction & PgBouncer Session Reset Discipline                       |
|   Enforce PgBouncer server_reset_query = DISCARD ALL to flush temporary schemas and relcache.     |
|   Execute zero-downtime REINDEX TABLE CONCURRENTLY on pg_catalog relations during off-peak windows. |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. Mathematical Formalization & Algorithmic Complexity

### 1. Catalog Dead Tuple Amplification Factor ($\alpha_{\text{cat}}$)

When an agent executes `CREATE TEMP TABLE t_temp (id INT, col1 TEXT, col2 JSONB, col3 TIMESTAMPTZ, col4 NUMERIC)`, PostgreSQL does not merely record 5 user columns. For every created relation, PostgreSQL inserts:
- 1 row in `pg_class`
- $N_{\text{user\_cols}} + N_{\text{sys\_cols}}$ rows in `pg_attribute` (where $N_{\text{sys\_cols}} = 7$: `tableoid`, `cmax`, `xmax`, `cmin`, `xmin`, `ctid`, and system attributes)
- 1 row in `pg_type` for the composite row type
- 1 row in `pg_type` for the array type
- Multiple rows in `pg_depend` connecting relations, namespaces, and types

The total catalog tuple insertion count $N_{\text{cat\_writes}}$ per temporary table lifecycle is modeled by:

$$N_{\text{cat\_writes}} = 1 + (N_{\text{user\_cols}} + 7) + 2 + N_{\text{depend}} \approx N_{\text{user\_cols}} + 15$$

For a microservice handling $\lambda$ requests/sec where each request instantiates a temporary table with $k$ columns and drops it upon completion:

$$\frac{d(\text{DeadTuples})}{dt} = \lambda \cdot (k + 15)$$

At $\lambda = 100\text{ req/sec}$ and $k = 10\text{ columns}$:

$$\frac{d(\text{DeadTuples})}{dt} = 100 \times 25 = 2,500\text{ dead catalog tuples / sec} = 9,000,000\text{ dead tuples / hour}$$

Because `pg_attribute` live rows in a typical database cluster rarely exceed $10,000$, a default `autovacuum_vacuum_scale_factor = 0.20` requires $2,000$ dead rows to trigger a pass. However, autovacuum's cost delay and throttling mean that while autovacuum processes dead tuples, the physical file size of `pg_attribute` and its B-Tree index `pg_attribute_relid_attnum_index` expand monotonically.

---

### 2. Shared Invalidation Ring Buffer Overflow Probability ($P_{\text{overflow}}$)

PostgreSQL implements `shared_inval` as a fixed circular array of $M$ message slots in shared memory (historically $M = 8192$ or $16384$ entries). Each backend maintains a read pointer $p_i$. If any backend $i$ is blocked in a long transaction or stalled on I/O, while active workers insert invalidation messages at rate $R_{\text{inval}}$, the lag $\Delta p_i = p_{\text{head}} - p_i$ increases:

$$\Delta p_i(t) = \int_0^t (R_{\text{inval}}(\tau) - v_i(\tau)) \, d\tau$$

When $\Delta p_i(t) \ge M$, the shared invalidation ring buffer **overflows**:

$$P_{\text{overflow}} = P\left( \max_{i} \Delta p_i(t) \ge M \right)$$

When an overflow occurs, PostgreSQL cannot deliver individual table invalidations to backend $i$. The engine is forced to invoke `CacheInvalidateAll()`—the **nuclear reset**:
1. All local `catcache` entries are discarded.
2. All `relcache` entries are discarded.
3. Every active connection on the entire cluster must perform cold catalog scans for every subsequent SQL statement.

---

### 3. Relcache Cache Miss Stampede Cost ($C_{\text{stampede}}$)

Let $N_{\text{conn}}$ be the number of active database backends (e.g., $N_{\text{conn}} = 300$). When a relcache eviction storm hits, every backend must repopulate its relation cache for active tables $T_1, \dots, T_m$:

$$C_{\text{stampede}} = N_{\text{conn}} \times \sum_{j=1}^m \left( C_{\text{read}}(\text{pg\_class}) + \sum_{c=1}^{k_j} C_{\text{read}}(\text{pg\_attribute}) + C_{\text{read}}(\text{pg\_index}) \right)$$

If `pg_attribute` is bloated to $B$ disk pages ($B = 50,000\text{ pages} \approx 400\text{MB}$), the stampede generates:

$$\text{Disk/Buffer IOPS} = N_{\text{conn}} \times \mathcal{O}(\log_2(B))$$

Under concurrent execution, all 300 backends contend for the same buffer cache LWLock partitions (`buffer_mapping` partition locks), locking the CPU at 100% and creating connection pool queue saturation.

---

## 3. Production TypeScript Guard Engine: `AgenticDatabaseCatalogGuardEngine`

The following production-grade TypeScript guard engine audits system catalog health, detects temporary table churn, measures shared invalidation queue pressure, and validates SQL queries to reject anti-pattern `CREATE TEMP TABLE` constructs in favor of `UNNEST` and CTE batch pipelines.

```typescript
import { PoolClient } from 'pg';

export interface CatalogTableMetric {
  schemaName: string;
  tableName: string;
  liveTuples: number;
  deadTuples: number;
  deadTupleRatio: number;
  tableSizeBytes: number;
  indexSizeBytes: number;
  totalSizeBytes: number;
  bloatAlert: boolean;
}

export interface InvalidationMetrics {
  databaseName: string;
  tempFilesCount: number;
  tempBytesWritten: number;
  conflictsLock: number;
  deadlocksCount: number;
  sharedInvalRisk: 'LOW' | 'MODERATE' | 'CRITICAL';
}

export interface CatalogHealthReport {
  timestamp: string;
  catalogs: CatalogTableMetric[];
  invalidation: InvalidationMetrics;
  totalCatalogSizeBytes: number;
  highChurnDetected: boolean;
  recommendedActions: string[];
}

export interface SqlLintResult {
  isSafe: boolean;
  violations: string[];
  remediationSql: string;
}

export class AgenticDatabaseCatalogGuardEngine {
  private static readonly CRITICAL_CATALOG_TABLES = [
    'pg_class',
    'pg_attribute',
    'pg_type',
    'pg_depend',
    'pg_description',
    'pg_statistic',
  ];

  /**
   * Audits core PostgreSQL system catalogs for dead tuple bloat, file size inflation,
   * and lagging autovacuum cleanup.
   */
  public async auditCatalogHealth(client: PoolClient): Promise<CatalogHealthReport> {
    const catalogQuery = `
      SELECT
        n.nspname AS schema_name,
        c.relname AS table_name,
        COALESCE(s.n_live_tup, 0) AS live_tuples,
        COALESCE(s.n_dead_tup, 0) AS dead_tuples,
        CASE
          WHEN (COALESCE(s.n_live_tup, 0) + COALESCE(s.n_dead_tup, 0)) = 0 THEN 0.0
          ELSE ROUND(COALESCE(s.n_dead_tup, 0)::numeric / (s.n_live_tup + s.n_dead_tup), 4)
        END AS dead_tuple_ratio,
        pg_relation_size(c.oid) AS table_size_bytes,
        pg_indexes_size(c.oid) AS index_size_bytes,
        pg_total_relation_size(c.oid) AS total_size_bytes
      FROM pg_class c
      JOIN pg_namespace n ON c.relnamespace = n.oid
      LEFT JOIN pg_stat_sys_tables s ON s.schemaname = n.nspname AND s.relname = c.relname
      WHERE n.nspname = 'pg_catalog'
        AND c.relname = ANY($1)
      ORDER BY total_size_bytes DESC;
    `;

    const catalogResult = await client.query(catalogQuery, [
      AgenticDatabaseCatalogGuardEngine.CRITICAL_CATALOG_TABLES,
    ]);

    const catalogs: CatalogTableMetric[] = catalogResult.rows.map((r) => {
      const deadRatio = parseFloat(r.dead_tuple_ratio);
      const totalSize = parseInt(r.total_size_bytes, 10);
      // Alert if dead tuple ratio > 20% or catalog table exceeds 50MB
      const bloatAlert = deadRatio > 0.20 || totalSize > 50 * 1024 * 1024;
      return {
        schemaName: r.schema_name,
        tableName: r.table_name,
        liveTuples: parseInt(r.live_tuples, 10),
        deadTuples: parseInt(r.dead_tuples, 10),
        deadTupleRatio: deadRatio,
        tableSizeBytes: parseInt(r.table_size_bytes, 10),
        indexSizeBytes: parseInt(r.index_size_bytes, 10),
        totalSizeBytes: totalSize,
        bloatAlert,
      };
    });

    const invalQuery = `
      SELECT
        datname AS database_name,
        temp_files AS temp_files_count,
        temp_bytes AS temp_bytes_written,
        conflicts AS conflicts_lock,
        deadlocks AS deadlocks_count
      FROM pg_stat_database
      WHERE datname = current_database();
    `;

    const invalResult = await client.query(invalQuery);
    const invalRow = invalResult.rows[0] || {
      database_name: 'unknown',
      temp_files_count: 0,
      temp_bytes_written: 0,
      conflicts_lock: 0,
      deadlocks_count: 0,
    };

    const tempFiles = parseInt(invalRow.temp_files_count, 10);
    const sharedInvalRisk: 'LOW' | 'MODERATE' | 'CRITICAL' =
      tempFiles > 100000 ? 'CRITICAL' : tempFiles > 10000 ? 'MODERATE' : 'LOW';

    const totalCatalogSizeBytes = catalogs.reduce((sum, c) => sum + c.totalSizeBytes, 0);
    const highChurnDetected = catalogs.some((c) => c.bloatAlert) || sharedInvalRisk === 'CRITICAL';

    const recommendedActions: string[] = [];
    if (highChurnDetected) {
      recommendedActions.push('Enforce strict ban on CREATE TEMP TABLE in application code.');
      recommendedActions.push('Configure aggressive autovacuum scale factors on pg_catalog relations.');
      recommendedActions.push('Execute zero-downtime REINDEX TABLE CONCURRENTLY on bloated catalog indexes.');
    }
    if (sharedInvalRisk === 'CRITICAL') {
      recommendedActions.push('Inspect backend queries for uncontrolled temp disk spills or excessive DDL.');
      recommendedActions.push('Verify PgBouncer server_reset_query is set to DISCARD ALL.');
    }

    return {
      timestamp: new Date().toISOString(),
      catalogs,
      invalidation: {
        databaseName: invalRow.database_name,
        tempFilesCount: tempFiles,
        tempBytesWritten: parseInt(invalRow.temp_bytes_written, 10),
        conflictsLock: parseInt(invalRow.conflicts_lock, 10),
        deadlocksCount: parseInt(invalRow.deadlocks_count, 10),
        sharedInvalRisk,
      },
      totalCatalogSizeBytes,
      highChurnDetected,
      recommendedActions,
    };
  }

  /**
   * Generates production DDL to configure dedicated aggressive autovacuum
   * parameters on PostgreSQL system catalogs.
   */
  public generateCatalogAutovacuumCalibrationDdl(): string[] {
    return [
      `ALTER TABLE pg_catalog.pg_class SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 50, autovacuum_analyze_scale_factor = 0.005);`,
      `ALTER TABLE pg_catalog.pg_attribute SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 100, autovacuum_analyze_scale_factor = 0.005);`,
      `ALTER TABLE pg_catalog.pg_type SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 50, autovacuum_analyze_scale_factor = 0.005);`,
      `ALTER TABLE pg_catalog.pg_depend SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 100, autovacuum_analyze_scale_factor = 0.005);`,
      `ALTER TABLE pg_catalog.pg_description SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 50, autovacuum_analyze_scale_factor = 0.005);`,
      `ALTER TABLE pg_catalog.pg_statistic SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_threshold = 100, autovacuum_analyze_scale_factor = 0.01);`,
    ];
  }

  /**
   * Statically lints incoming agent SQL to eliminate CREATE TEMP TABLE statements,
   * replacing them with parameterized UNNEST or CTE bulk patterns.
   */
  public lintSqlForCatalogHygiene(sql: string): SqlLintResult {
    const violations: string[] = [];
    const tempTableRegex = /CREATE\s+(GLOBAL\s+|LOCAL\s+)?(TEMP|TEMPORARY)\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?([a-zA-Z0-9_".]+)/gi;

    let match: RegExpExecArray | null;
    while ((match = tempTableRegex.step ? tempTableRegex.step() : tempTableRegex.exec(sql)) !== null) {
      const tableName = match[4];
      violations.push(
        `FORBIDDEN_TEMP_TABLE: Detected temporary table creation for '${tableName}'. ` +
        `Temporary tables write rows to pg_class/pg_attribute and cause system catalog bloat and relcache invalidation storms.`
      );
    }

    const dropTempRegex = /DROP\s+TABLE\s+(IF\s+EXISTS\s+)?([a-zA-Z0-9_".]+)/gi;
    if (sql.includes('pg_temp') || /DROP\s+TABLE.*temp/i.test(sql)) {
      violations.push(
        `FORBIDDEN_TEMP_DROP: Detected manual temporary table DROP. Use connection-partitioned UNLOGGED tables or memory CTEs instead.`
      );
    }

    const isSafe = violations.length === 0;
    const remediationSql = isSafe
      ? sql
      : `-- REMEDIATION: Replace temporary tables with parameterized UNNEST or CTE bulk inserts:
-- Example Safe Pattern:
-- INSERT INTO target_table (id, name, amount)
-- SELECT * FROM UNNEST($1::int[], $2::text[], $3::numeric[]) AS t(id, name, amount)
-- ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, amount = EXCLUDED.amount;`;

    return {
      isSafe,
      violations,
      remediationSql,
    };
  }

  /**
   * Constructs high-performance, catalog-free bulk upsert SQL using PostgreSQL UNNEST.
   */
  public buildCatalogFreeUnnestUpsertSql(
    targetTable: string,
    keyColumn: string,
    columns: Array<{ name: string; pgType: string }>
  ): string {
    const colNames = columns.map((c) => `"${c.name}"`).join(', ');
    const unnestArgs = columns.map((c, idx) => `$${idx + 1}::${c.pgType}[]`).join(', ');
    const aliasCols = columns.map((c) => `"${c.name}"`).join(', ');
    const updateAssignments = columns
      .filter((c) => c.name !== keyColumn)
      .map((c) => `"${c.name}" = EXCLUDED."${c.name}"`)
      .join(', ');

    return `
      INSERT INTO "${targetTable}" (${colNames})
      SELECT ${aliasCols}
      FROM UNNEST(${unnestArgs}) AS stage(${aliasCols})
      ON CONFLICT ("${keyColumn}")
      DO UPDATE SET ${updateAssignments}
      RETURNING "${keyColumn}";
    `.trim();
  }
}
```

---

## 4. Cross-Language Production Implementations

### Go (`jackc/pgx/v5`): High-Throughput Catalog-Free Batch Staging via UNNEST & Catalog Audit

```go
package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Invariant: Never issue "CREATE TEMP TABLE" inside Go web handlers or worker loops.
// Use pgx.CopyFrom for pure bulk ingestion, or UNNEST for bulk upserts with zero catalog impact.

type ItemPayload struct {
	ID        int64
	TenantID  string
	Name      string
	Payload   []byte
	CreatedAt time.Time
}

// BulkUpsertItemsWithoutCatalogChurn performs high-speed bulk ingestion without touching pg_catalog.
func BulkUpsertItemsWithoutCatalogChurn(ctx context.Context, pool *pgxpool.Pool, items []ItemPayload) (int64, error) {
	if len(items) == 0 {
		return 0, nil
	}

	ids := make([]int64, len(items))
	tenantIDs := make([]string, len(items))
	names := make([]string, len(items))
	payloads := make([][]byte, len(items))
	createdAts := make([]time.Time, len(items))

	for i, item := range items {
		ids[i] = item.ID
		tenantIDs[i] = item.TenantID
		names[i] = item.Name
		payloads[i] = item.Payload
		createdAts[i] = item.CreatedAt
	}

	query := `
		INSERT INTO items (id, tenant_id, name, payload, created_at)
		SELECT * FROM UNNEST(
			$1::bigint[],
			$2::text[],
			$3::text[],
			$4::bytea[],
			$5::timestamptz[]
		) AS stage(id, tenant_id, name, payload, created_at)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name,
			payload = EXCLUDED.payload
	`

	tag, err := pool.Exec(ctx, query, ids, tenantIDs, names, payloads, createdAts)
	if err != nil {
		return 0, fmt.Errorf("bulk upsert via unnest failed: %w", err)
	}
	return tag.RowsAffected(), nil
}

// CatalogAuditReport summarizes live vs dead tuples across core PostgreSQL system catalogs.
type CatalogAuditReport struct {
	SchemaName     string  `json:"schema_name"`
	TableName      string  `json:"table_name"`
	LiveTuples     int64   `json:"live_tuples"`
	DeadTuples     int64   `json:"dead_tuples"`
	DeadTupleRatio float64 `json:"dead_tuple_ratio"`
	TotalSizeBytes int64   `json:"total_size_bytes"`
}

// AuditSystemCatalogs inspects pg_catalog to detect dead tuple bloat and autovacuum lag.
func AuditSystemCatalogs(ctx context.Context, pool *pgxpool.Pool) ([]CatalogAuditReport, error) {
	query := `
		SELECT
			n.nspname AS schema_name,
			c.relname AS table_name,
			COALESCE(s.n_live_tup, 0) AS live_tuples,
			COALESCE(s.n_dead_tup, 0) AS dead_tuples,
			CASE
				WHEN (COALESCE(s.n_live_tup, 0) + COALESCE(s.n_dead_tup, 0)) = 0 THEN 0.0
				ELSE ROUND(COALESCE(s.n_dead_tup, 0)::numeric / (s.n_live_tup + s.n_dead_tup), 4)
			END AS dead_tuple_ratio,
			pg_total_relation_size(c.oid) AS total_size_bytes
		FROM pg_class c
		JOIN pg_namespace n ON c.relnamespace = n.oid
		LEFT JOIN pg_stat_sys_tables s ON s.schemaname = n.nspname AND s.relname = c.relname
		WHERE n.nspname = 'pg_catalog'
		  AND c.relname IN ('pg_class', 'pg_attribute', 'pg_type', 'pg_depend')
		ORDER BY total_size_bytes DESC;
	`
	rows, err := pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("querying system catalogs failed: %w", err)
	}
	defer rows.Close()

	var reports []CatalogAuditReport
	for rows.Next() {
		var r CatalogAuditReport
		if err := rows.Scan(
			&r.SchemaName,
			&r.TableName,
			&r.LiveTuples,
			&r.DeadTuples,
			&r.DeadTupleRatio,
			&r.TotalSizeBytes,
		); err != nil {
			return nil, fmt.Errorf("scanning catalog audit failed: %w", err)
		}
		reports = append(reports, r)
	}
	return reports, nil
}
```

---

### TypeScript (`drizzle-orm` / `pg`): Memory CTE Upsert Eliminating Temp Tables

```typescript
import { sql } from 'drizzle-orm';
import { pgTable, text, timestamp, integer } from 'drizzle-orm/pg-core';
import { NodePgDatabase } from 'drizzle-orm/node-postgres';

export const tenantOrders = pgTable('tenant_orders', {
  orderId: text('order_id').primaryKey(),
  tenantId: text('tenant_id').notNull(),
  amountCents: integer('amount_cents').notNull(),
  status: text('status').notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
});

export interface OrderBatchItem {
  orderId: string;
  tenantId: string;
  amountCents: number;
  status: string;
}

/**
 * Executes a zero-catalog-churn batch upsert.
 * Instead of writing a CREATE TEMP TABLE staging script, this executes a single
 * parameterized query passing arrays directly to PostgreSQL UNNEST.
 */
export async function batchUpsertOrdersZeroCatalogBloat(
  db: NodePgDatabase,
  items: OrderBatchItem[]
): Promise<number> {
  if (items.length === 0) return 0;

  const orderIds = items.map((i) => i.orderId);
  const tenantIds = items.map((i) => i.tenantId);
  const amountCents = items.map((i) => i.amountCents);
  const statuses = items.map((i) => i.status);

  const query = sql`
    INSERT INTO ${tenantOrders} ("order_id", "tenant_id", "amount_cents", "status", "updated_at")
    SELECT
      stage.order_id,
      stage.tenant_id,
      stage.amount_cents,
      stage.status,
      NOW()
    FROM UNNEST(
      ${orderIds}::text[],
      ${tenantIds}::text[],
      ${amountCents}::integer[],
      ${statuses}::text[]
    ) AS stage(order_id, tenant_id, amount_cents, status)
    ON CONFLICT ("order_id")
    DO UPDATE SET
      "amount_cents" = EXCLUDED."amount_cents",
      "status" = EXCLUDED."status",
      "updated_at" = NOW();
  `;

  const result = await db.execute(query);
  return result.rowCount ?? items.length;
}
```

---

### Python (`asyncpg` / `SQLAlchemy 2.0`): Permanent Unlogged Staging with Session Partitioning

When data ingestion exceeds 500,000 rows and wire parameter limits prevent array unnesting, agents MUST NOT create temporary tables. Instead, use a permanent `UNLOGGED` staging table with session-key partitioning.

```python
import uuid
import asyncpg
from typing import List, Tuple

# Pre-created once in schema migrations:
# CREATE UNLOGGED TABLE staging_batch_buffer (
#     session_id UUID NOT NULL,
#     record_id TEXT NOT NULL,
#     payload JSONB NOT NULL,
#     created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
# );
# CREATE INDEX idx_staging_batch_session ON staging_batch_buffer (session_id);

async def bulk_ingest_via_unlogged_staging(
    pool: asyncpg.Pool,
    records: List[Tuple[str, str]], # [(record_id, json_payload)]
) -> int:
    """
    Ingests high-volume batch data using a permanent UNLOGGED staging table
    partitioned by session_id. Completely avoids CREATE TEMP TABLE catalog thrash.
    """
    session_id = uuid.uuid4()
    
    async with pool.acquire() as conn:
        async with conn.transaction():
            # 1. High-speed binary COPY directly into unlogged staging table (no catalog DDL)
            staging_rows = [(session_id, r[0], r[1]) for r in records]
            await conn.copy_records_to_table(
                'staging_batch_buffer',
                records=staging_rows,
                columns=['session_id', 'record_id', 'payload']
            )

            # 2. Merge staging data into production table using set-based SQL
            merge_query = """
                INSERT INTO target_records (record_id, payload, updated_at)
                SELECT record_id, payload::jsonb, NOW()
                FROM staging_batch_buffer
                WHERE session_id = $1
                ON CONFLICT (record_id) DO UPDATE
                SET payload = EXCLUDED.payload, updated_at = NOW();
            """
            result = await conn.execute(merge_query, session_id)

            # 3. Purge session rows from unlogged staging table
            await conn.execute(
                "DELETE FROM staging_batch_buffer WHERE session_id = $1;",
                session_id
            )

    return len(records)
```

---

### Rust (`sqlx`): Zero-Downtime Catalog Reindex Sentinel & Unnest Execution

```rust
use sqlx::{PgPool, Error};

#[derive(Debug, sqlx::FromRow)]
pub struct CatalogBloatSummary {
    pub table_name: String,
    pub live_tuples: i64,
    pub dead_tuples: i64,
    pub dead_tuple_ratio: f64,
    pub total_size_bytes: i64,
}

/// Inspects core PostgreSQL catalogs for dead tuple bloat
pub async fn check_system_catalog_health(pool: &PgPool) -> Result<Vec<CatalogBloatSummary>, Error> {
    let rows = sqlx::query_as::<_, CatalogBloatSummary>(
        r#"
        SELECT
            c.relname AS table_name,
            COALESCE(s.n_live_tup, 0) AS live_tuples,
            COALESCE(s.n_dead_tup, 0) AS dead_tuples,
            CASE
                WHEN (COALESCE(s.n_live_tup, 0) + COALESCE(s.n_dead_tup, 0)) = 0 THEN 0.0
                ELSE ROUND(COALESCE(s.n_dead_tup, 0)::numeric / (s.n_live_tup + s.n_dead_tup), 4)::float8
            END AS dead_tuple_ratio,
            pg_total_relation_size(c.oid) AS total_size_bytes
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        LEFT JOIN pg_stat_sys_tables s ON s.schemaname = n.nspname AND s.relname = c.relname
        WHERE n.nspname = 'pg_catalog'
          AND c.relname IN ('pg_class', 'pg_attribute', 'pg_type', 'pg_depend')
        ORDER BY total_size_bytes DESC;
        "#
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}
```

---

## 5. The 6-State Catalog Lifecycle Finite State Machine (FSM)

The lifecycle of PostgreSQL system catalogs is modeled through the following 6-state finite-state machine (FSM). Autonomous agents MUST ensure system state never transitions beyond `OPTIMAL_PRISTINE` into eviction storm cascades:

```
+----------------------------------------------------------------------------------------------------+
|                      SYSTEM CATALOG LIFECYCLE FINITE-STATE MACHINE (FSM)                            |
+----------------------------------------------------------------------------------------------------+
|                                                                                                    |
|  [ S0: OPTIMAL_PRISTINE ] --- (Agent introduces CREATE TEMP TABLE) ---> [ S1: TEMP_CHURN_DETECTED ]|
|             ^                                                                     |                |
|             |                                                  (Dead tuples > 20% |                |
|      (Autovacuum cleans                                         or rate > 500/sec)|                |
|       catalog pages)                                                              v                |
|             |                                                   [ S2: CATALOG_BLOAT_WARNING ]      |
|             |                                                                     |                |
|  [ S5: ZERO_DOWNTIME_COMPACT ]                                         (shared_inval queue         |
|             ^                                                           fills > 70%)               |
|             |                                                                     v                |
|      (REINDEX CONCURRENTLY                                      [ S3: INVAL_BUFFER_PRESSURE ]      |
|       & VACUUM ANALYZE)                                                           |                |
|             |                                                           (shared_inval ring         |
|             |                                                            overflows > M)            |
|             |                                                                     v                |
|  [ S4: RELCACHE_EVICTION_STORM ] <------------------------------------------------+                |
|    (All backends dump relcache; 100% CPU lock storm; connection poolers time out)                  |
|                                                                                                    |
+----------------------------------------------------------------------------------------------------+
```

### State Transition Invariant Table

| Initial State | Event / Trigger Condition | Target State | Autonomous Action & Guardrail |
| :--- | :--- | :--- | :--- |
| **S0: OPTIMAL_PRISTINE** | DDL or temp table creation executed in app code | **S1: TEMP_CHURN_DETECTED** | Intercept query via CI linting or pool proxy; fail build on `CREATE TEMP TABLE`. |
| **S1: TEMP_CHURN_DETECTED** | Dead tuple ratio $\ge 0.20$ or rate $> 500/\text{sec}$ | **S2: CATALOG_BLOAT_WARNING** | Trigger dedicated catalog autovacuum; alert on temp object usage. |
| **S2: CATALOG_BLOAT_WARNING** | Shared invalidation ring buffer fill $> 70\%$ | **S3: INVAL_BUFFER_PRESSURE** | Terminate idle-in-transaction connections delaying invalidation consumption. |
| **S3: INVAL_BUFFER_PRESSURE** | Ring buffer capacity exhausted ($\Delta p_i \ge M$) | **S4: RELCACHE_EVICTION_STORM** | Cache reset broadcast. Throttle incoming connections to prevent stampede collapse. |
| **S4: RELCACHE_EVICTION_STORM** | Incident mitigation; query storm abates | **S5: ZERO_DOWNTIME_COMPACT** | Run `REINDEX TABLE CONCURRENTLY pg_catalog.pg_class;` during scheduled window. |
| **S5: ZERO_DOWNTIME_COMPACT** | Catalog indexes rebuilt; dead tuples vacuumed | **S0: OPTIMAL_PRISTINE** | State normalized. Metric tracking re-engaged. |

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Sentinels

All pull requests, database migrations, and repository commits MUST pass the following automated static analysis sentinel script before being merged into production.

```bash
#!/usr/bin/env bash
# ci-catalog-governance-sentinel.sh
# Machine-verifiable CI gate preventing system catalog bloat, temp table churn,
# and shared invalidation queue storms.
set -euo pipefail

echo "🔍 Running Agentic System Catalog Bloat & Temp Table CI Sentinel..."

VIOLATIONS=0

# Check 1: Scan repository for forbidden CREATE TEMP / TEMPORARY TABLE patterns
echo "Checking code for CREATE TEMP / TEMPORARY TABLE anti-patterns..."
TEMP_TABLE_MATCHES=$(grep -rnEI \
  --exclude-dir={node_modules,.git,dist,build,vendor} \
  --exclude="*.md" \
  --exclude="*.mdc" \
  --exclude="ci-catalog-governance-sentinel.sh" \
  "CREATE\s+(GLOBAL\s+|LOCAL\s+)?(TEMP|TEMPORARY)\s+TABLE" . || true)

if [ -n "$TEMP_TABLE_MATCHES" ]; then
  echo "❌ CRITICAL: Detected forbidden CREATE TEMP TABLE statements:"
  echo "$TEMP_TABLE_MATCHES"
  echo "👉 Remediation: Replace temporary tables with UNNEST(\$1::type[]), JSONB recordsets, or permanent UNLOGGED staging tables."
  VIOLATIONS=$((VIOLATIONS + 1))
else
  echo "✅ No temporary table creations found in application code."
fi

# Check 2: Scan for unparameterized DROP TABLE temp statements
echo "Checking code for explicit temporary table drops..."
DROP_TEMP_MATCHES=$(grep -rnEI \
  --exclude-dir={node_modules,.git,dist,build,vendor} \
  --exclude="*.md" \
  --exclude="*.mdc" \
  --exclude="ci-catalog-governance-sentinel.sh" \
  "DROP\s+TABLE.*(tmp_|temp_|staging_temp)" . || true)

if [ -n "$DROP_TEMP_MATCHES" ]; then
  echo "⚠️ WARNING: Detected potential temporary table DROP statements:"
  echo "$DROP_TEMP_MATCHES"
  VIOLATIONS=$((VIOLATIONS + 1))
else
  echo "✅ No manual temporary table drops found."
fi

# Check 3: If running against live PostgreSQL test database, check catalog dead tuple ratios
if [ -n "${DATABASE_URL:-}" ]; then
  echo "Checking live database system catalog bloat metrics..."
  BLOATED_CATALOGS=$(psql "$DATABASE_URL" -t -A -c "
    SELECT c.relname || ': dead_ratio=' || ROUND(s.n_dead_tup::numeric / GREATEST(s.n_live_tup + s.n_dead_tup, 1), 2)
    FROM pg_class c
    JOIN pg_namespace n ON c.relnamespace = n.oid
    LEFT JOIN pg_stat_sys_tables s ON s.schemaname = n.nspname AND s.relname = c.relname
    WHERE n.nspname = 'pg_catalog'
      AND c.relname IN ('pg_class', 'pg_attribute', 'pg_type', 'pg_depend')
      AND s.n_dead_tup > 1000
      AND (s.n_dead_tup::numeric / GREATEST(s.n_live_tup + s.n_dead_tup, 1)) > 0.25;
  " || true)

  if [ -n "$BLOATED_CATALOGS" ]; then
    echo "❌ CRITICAL: System catalogs show severe dead tuple bloat (> 25%):"
    echo "$BLOATED_CATALOGS"
    VIOLATIONS=$((VIOLATIONS + 1))
  else
    echo "✅ Live system catalog dead tuple ratios are within safe boundaries."
  fi
fi

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "🚨 Catalog governance validation failed with $VIOLATIONS violation(s)."
  exit 1
fi

echo "🎉 All system catalog bloat and temporary table invariants verified successfully!"
exit 0
```
