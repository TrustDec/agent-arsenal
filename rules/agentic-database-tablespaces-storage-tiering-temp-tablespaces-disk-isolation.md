---
description: PostgreSQL tablespaces, storage tiering, temp_tablespaces isolation, physical mount point divergence, standby replica symlink fatal crash defense, ALTER TABLE SET TABLESPACE zero-downtime migrations, DROP TABLESPACE dependency resolution, and pg_dump environmental portability invariants across Go (jackc/pgx/v5), TypeScript (drizzle-orm, prisma, pg), Python (asyncpg, psycopg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{tablespace,storage,tiering,disk,temp_tablespaces,mount,migration}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go,py},**/infra/**/*.{tf,yaml,yml}
alwaysApply: false
---

# Agentic Database Tablespaces, Storage Tiering, temp_tablespaces Isolation, Symlink Divergence & Mount Point Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, provision, configure, or migrate PostgreSQL (13–17+) database tablespaces, disk storage tiering, temporary spillover mounts, cross-host replica topologies, and microservice persistence layers across Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `prisma`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Single Mount Volume I/O Starvation & Root Partition PANIC Disaster" (where heap tables, indexes, WAL records, and unindexed sort/hash temp files share a single filesystem mount, allowing an analytical query or runaway autovacuum to fill the disk to 100%, triggering `PANIC: could not write to log file: No space left on device` and terminating cluster operations), the "`temp_tablespaces` Amnesia & Ephemeral Spill I/O Saturation" (where queries exceeding `work_mem` write transient files into `base/pgsql_tmp/` within the primary transactional SSD rather than dedicated scratch disks, spiking OLTP commit latencies by up to 500%), the "Standby Replica Symlink & Mount Path Divergence Fatal Crash" (where `CREATE TABLESPACE` references a host filesystem path that does not exist or lacks matching permissions on standby replicas, causing WAL replay workers to crash with `FATAL: could not create directory ...` and permanently breaking physical replication), the "`DROP TABLESPACE` Dependency & Orphaned File Leak (`SQLSTATE 2BE00`)" (where dropping tablespaces fails because invisible relations, partition chunks, or toast tables still linger in `pg_class`, or out-of-band directory unlinking corrupts catalog integrity), the "Hardcoded Tablespace Lock-In & `pg_dump` Restore Paralysis (`SQLSTATE 42704`)" (where hardcoded `TABLESPACE` clauses in DDL files break automated CI/CD pipelines, local Docker test suites, and staging environments where those host paths do not exist), and the "Catalog Immutability & `ALTER DATABASE ... SET TABLESPACE` Monolithic Lockout Trap" (where relocating an entire database locks all tables with `ACCESS EXCLUSIVE` for hours while shared catalog objects in `pg_global` remain untransferable) by establishing a strict 5-Tier Tablespace Governance Ladder, mathematical disk exhaustion and spill volume models, an autonomous TypeScript `AgenticDatabaseTablespaceGuardEngine`, cross-runtime telemetry sentinels in Go, TypeScript, Python, and Rust, a 6-state tablespace migration finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Tablespace Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL tablespaces allow database administrators and automated orchestration agents to map logical database relations (tables, indexes, materialized views) to distinct physical filesystem directories on the host operating system. Internally, PostgreSQL manages tablespaces by storing symbolic links in `$PGDATA/pg_tblspc/<tablespace_oid>` pointing to the target directory. Within each tablespace directory, PostgreSQL provisions versioned subdirectory trees (e.g. `PG_16_202307071/<database_oid>/<relation_filenode>`).

However, tablespaces introduce severe physical, operational, and replication coupling:
1. **Physical Symlink Coupling**: A tablespace path is an absolute, host-local path (e.g., `/mnt/nvme_fast/pg_data`). PostgreSQL writes this path into system catalogs (`pg_tablespace.spcoptions`) and emits WAL records containing that exact path.
2. **Homogeneous Path Replay on Replicas**: Physical streaming replication replays WAL records byte-for-byte. When `CREATE TABLESPACE` is executed on the primary, every standby replica attempts to create the identical symbolic link and directory path on its local filesystem. If the path does not exist or permissions differ, replication crashes instantly.
3. **Transient Ephemeral Spills vs Durable Storage**: Queries requiring external merge sorts or hash joins write temporary files. Without explicit `temp_tablespaces` routing, these transient files pollute the primary relational mount, creating disk I/O contention and risking out-of-disk crashes.
4. **Environment Brittleness in DDL**: Inlining `TABLESPACE "fast_ssd"` in application migrations destroys database portability across staging, developer machines, and cloud-managed serverless instances.

When autonomous coding agents generate database administration scripts, provisioning templates, or migration files, LLMs routinely commit 6 catastrophic architectural errors:

### The 6 Tablespace Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: MONOLITHIC SINGLE MOUNT POINT FAILURE
-- Agent sets up a high-throughput production database on a single root volume:
-- All tables, indexes, WAL (pg_wal), and temp files (base/pgsql_tmp) reside on /var/lib/postgresql/data
SELECT customer_id, SUM(amount), RANK() OVER (PARTITION BY region ORDER BY created_at)
FROM massive_sales_ledger
GROUP BY customer_id, region, created_at;

-- 💥 Catastrophe:
-- 1. Query exceeds work_mem (4MB) and generates 45GB of temporary spill files in $PGDATA/base/pgsql_tmp/.
-- 2. Concurrently, a bulk transaction writes 30GB of WAL to $PGDATA/pg_wal/.
-- 3. The root disk hits 100% full. PostgreSQL triggers:
--    PANIC: could not write to log file: No space left on device
-- 4. Database crashes abruptly. Recovery requires manual offline filesystem surgery.
-- Invariant: WAL, ephemeral temp files, and relational heap MUST be physically isolated or strictly quota-bounded.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE TEMP_TABLESPACES AMNESIA
-- Agent provisions secondary NVMe storage but leaves postgresql.conf with:
-- temp_tablespaces = '' (default: empty, meaning default tablespace)

-- 💥 Catastrophe:
-- 1. All sort/hash spills share the same I/O queue and write-amplification channels as primary transaction commits.
-- 2. High-frequency OLTP INSERT/UPDATE p99 latency spikes from 2ms to 240ms during analytics runs.
-- Invariant: Always configure temp_tablespaces = 'temp_scratch_tier' pointing to dedicated high-speed ephemeral scratch storage.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: STANDBY REPLICA DIRECTORY DIVERGENCE FATAL CRASH
-- Agent executes on primary:
CREATE TABLESPACE analytics_tier LOCATION '/mnt/storage/analytics_disk0';

-- 💥 Catastrophe:
-- 1. The WAL record is streamed to 3 read replicas in the cluster.
-- 2. Standby node 2 does NOT have '/mnt/storage/analytics_disk0' mounted or postgres user lacks write permissions.
-- 3. Standby WAL replay worker throws:
--    FATAL: could not create directory "/mnt/storage/analytics_disk0": No such file or directory
-- 4. Streaming replication HALTS. Replica lags indefinitely; replication slot fills primary disk with retained WAL!
-- Invariant: NEVER create a tablespace without pre-flight verifying matching directory existence and UID/GID permissions on 100% of replicas.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: HARDCODED TABLESPACE IN DDL DESTROYS PORTABILITY
-- Agent writes a migration script:
CREATE TABLE transactions (
  id UUID PRIMARY KEY,
  amount NUMERIC(12, 2) NOT NULL
) TABLESPACE fast_nvme;

-- 💥 Catastrophe:
-- 1. The migration runs smoothly in staging where 'fast_nvme' was manually created.
-- 2. CI/CD automated test suite boots a clean ephemeral Postgres container and runs the migration:
--    ERROR: tablespace "fast_nvme" does not exist (SQLSTATE 42704)
-- 3. Local developer onboarding fails completely.
-- Invariant: DDL scripts must NEVER hardcode TABLESPACE clauses. Use default_tablespace or parameter substitution.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: DROP TABLESPACE DEPENDENCY DEADLOCK (SQLSTATE 2BE00)
-- Agent attempts to decommission old storage:
DROP TABLESPACE legacy_storage;

-- 💥 Catastrophe:
-- ERROR: tablespace "legacy_storage" is not empty (SQLSTATE 2BE00)
-- Agent is blind to toast tables, inactive partition children, or dropped database artifacts still residing in pg_class!
-- Invariant: Query pg_class.reltablespace and pg_database.dattablespace to verify zero dependent objects before dropping.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: ALTER DATABASE SET TABLESPACE MONOLITHIC LOCKOUT
-- Agent relocates an entire database to new storage during business hours:
ALTER DATABASE production_app SET TABLESPACE fast_storage;

-- 💥 Catastrophe:
-- 1. ALTER DATABASE acquires an ACCESS EXCLUSIVE lock on the ENTIRE database.
-- 2. All incoming connections and queries queue up behind it, causing instant connection pool exhaustion.
-- 3. System catalogs in pg_global cannot be moved anyway!
-- Invariant: Migrate individual tables and indexes incrementally using ALTER TABLE/INDEX ... SET TABLESPACE with lock_timeout.
```

---

### The 5-Tier Tablespace Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   TIER 4: MACHINE-VERIFIABLE CI GATES & PORTABILITY AUDITING           │
│  - pg_dump --no-tablespaces in 100% of backup/restore pipelines                        │
│  - CI test assertions verifying zero hardcoded TABLESPACE clauses in migration DDL      │
│  - Automated tablespace size balance & drift sentinels (pg_tablespace_size)            │
└───────────────────────────────────────────▲────────────────────────────────────────────┘
                                            │
┌───────────────────────────────────────────┴────────────────────────────────────────────┐
│                   TIER 3: ZERO-DOWNTIME GRANULAR MIGRATION & LOCKOUT FENCING           │
│  - Incremental ALTER TABLE / ALTER INDEX ... SET TABLESPACE with lock_timeout <= 2000ms│
│  - Never issue monolithic ALTER DATABASE SET TABLESPACE in production                  │
│  - Session-scoped SET LOCAL default_tablespace for batch bulk insertions               │
└───────────────────────────────────────────▲────────────────────────────────────────────┘
                                            │
┌───────────────────────────────────────────┴────────────────────────────────────────────┐
│                   TIER 2: STORAGE TIERING ARCHITECTURE & DISK AFFINITY                 │
│  - Hot tier: NVMe SSD for high-write OLTP tables & primary key B-Tree indexes          │
│  - Cold tier: High-capacity Block Storage for read-only historical partitioned chunks  │
│  - Separate WAL volume (pg_wal) on dedicated low-latency direct-attached IOPS          │
└───────────────────────────────────────────▲────────────────────────────────────────────┘
                                            │
┌───────────────────────────────────────────┴────────────────────────────────────────────┐
│                   TIER 1: EPHEMERAL TEMP_TABLESPACES ISOLATION                         │
│  - Mandatory temp_tablespaces = 'ramdisk_scratch,nvme_scratch' in postgresql.conf      │
│  - Zero sort/hash spillover onto primary transaction heap volume                       │
│  - temp_file_limit = 10GB hard fence to prevent runaway query disk depletion           │
└───────────────────────────────────────────▲────────────────────────────────────────────┘
                                            │
┌───────────────────────────────────────────┴────────────────────────────────────────────┐
│                   TIER 0: MOUNT PARITY & REPLICA PRE-FLIGHT VERIFICATION               │
│  - Pre-provision identical filesystem directory paths and UID/GID on primary & replicas│
│  - Pre-flight dry-run validation before executing CREATE TABLESPACE                    │
│  - Strict ban on unmonitored directory unlinking at host OS level                      │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Foundations & Formal Invariant Models

### 1. Disk Exhaustion Time-to-Failure Differential Model

When relational data, write-ahead logs, and unconstrained temporary spill files share an unisolated disk volume, the rate of available disk space depletion is governed by the continuous differential equation:

$$\frac{dD_{\text{free}}(t)}{dt} = -\left( \lambda_{\text{heap}}(t) + \lambda_{\text{wal}}(t) + \lambda_{\text{temp}}(t) \right) + \mu_{\text{drain}}(t)$$

Where:
- $D_{\text{free}}(t)$ is the available byte capacity on the filesystem mount.
- $\lambda_{\text{heap}}$ is the ingestion rate of tuple allocations (including MVCC dead-tuple churn).
- $\lambda_{\text{wal}}$ is the rate of WAL segment generation.
- $\lambda_{\text{temp}}$ is the rate of temporary file creation from sort/hash spills.
- $\mu_{\text{drain}}$ is the recycling rate from autovacuum dead tuple truncation and checkpoint WAL recycling.

During an unindexed analytical query or large `VACUUM FULL`, $\lambda_{\text{temp}} \gg \mu_{\text{drain}}$. The time until catastrophic unrecoverable database panic ($T_{\text{exhaust}}$) is:

$$T_{\text{exhaust}} = \frac{D_{\text{free}}(t_0) - D_{\text{safety}}}{\sum \lambda_i - \mu_{\text{drain}}}$$

Where $D_{\text{safety}}$ is the kernel reserve threshold. When temporary files reside on a dedicated `temp_tablespaces` mount, $\lambda_{\text{temp}}$ is decoupled from the root filesystem:

$$\left(\frac{dD_{\text{root}}}{dt}\right)_{\text{isolated}} = -\left( \lambda_{\text{heap}}(t) + \lambda_{\text{wal}}(t) \right) + \mu_{\text{drain}}(t)$$

This guarantees that an explosive sort spill on the ephemeral scratch volume **cannot** induce a PostgreSQL postmaster storage panic on the transactional relational storage tier.

---

### 2. Temporary Spill Volume & External Merge Sort I/O Complexity

When an analytical query requires sorting $N$ rows with average row width $W_{\text{row}}$, the total data size is $S = N \cdot W_{\text{row}}$. If $S > \text{work\_mem}$, PostgreSQL resorts to an external multi-pass merge sort.

The number of initial sorted runs $R$ written to temporary disk storage is:

$$R = \left\lceil \frac{S}{\text{work\_mem}} \right\rceil$$

With an external merge fan-in factor $K = \left\lfloor \frac{\text{work\_mem}}{\text{page\_size}} \right\rfloor$, the total volume of temporary bytes written to disk $V_{\text{temp}}$ across $\lceil \log_K R \rceil$ merge passes is:

$$V_{\text{temp}} = 2 \cdot S \cdot \left( 1 + \left\lceil \log_K \frac{S}{\text{work\_mem}} \right\rceil \right)$$

**Theorem (I/O Contention Elimination)**: By routing $V_{\text{temp}}$ to a distinct physical device via `temp_tablespaces`, the disk queue length for primary heap and WAL reads/writes $Q_{\text{primary}}$ is reduced by:

$$\Delta Q_{\text{primary}} = \frac{V_{\text{temp}}}{B_{\text{block}} \cdot T_{\text{query}} \cdot \mu_{\text{disk\_iops}}}$$

Preventing transactional commit stalls and eliminating write-amplification cascades on the primary transactional storage array.

---

### 3. Replicated Tablespace Mount Parity Invariant

Let $\mathcal{S} = \{ s_1, s_2, \dots, s_m \}$ be the set of active streaming physical read replicas. Let $\mathcal{P}(T)$ be the target filesystem directory for tablespace $T$.

$$P(\text{StandbyReplayCrash}) = \begin{cases} 
1.0 & \text{if } \exists s_j \in \mathcal{S} : \text{DirectoryExists}(s_j, \mathcal{P}(T)) = \text{False} \lor \text{Writable}(s_j, \mathcal{P}(T)) = \text{False} \\
0.0 & \text{otherwise}
\end{cases}$$

**Invariant**: Prior to executing `CREATE TABLESPACE` on the primary, the orchestrator MUST verify that $\forall s_j \in \mathcal{S}$, the host directory $\mathcal{P}(T)$ exists, is owned by the `postgres` system user, and has POSIX permissions `0700`.

---

### 4. Tablespace Migration Lock Duration Calculus

When migrating a relation $R$ of size $S_{\text{rel}}$ from tablespace $T_{\text{source}}$ to $T_{\text{dest}}$ via:

```sql
ALTER TABLE R SET TABLESPACE T_dest;
```

PostgreSQL acquires a `ShareLock` or `AccessExclusiveLock` on relation $R$. The table rewrite requires sequentially copying all physical fork segments across filesystems. The minimum lock hold duration $T_{\text{migration}}$ is bounded by:

$$T_{\text{migration}} = \frac{S_{\text{rel}}}{\min(R_{\text{read}}(T_{\text{src}}), W_{\text{write}}(T_{\text{dest}}))} + \Delta_{\text{catalog\_update}}$$

To prevent connection exhaustion during large table migrations ($S_{\text{rel}} > 10\text{GB}$), migrations must enforce a multi-tier lock timeout ladder:

$$T_{\text{lock\_timeout}} \le 2000\text{ms}$$

If lock acquisition cannot be achieved within $T_{\text{lock\_timeout}}$, the operation aborts immediately, releases all queue locks, and retries under an exponential backoff schedule with jitter.

---

## 3. Production Invariant Implementation Patterns

### 1. Hardened PostgreSQL Tablespace Provisioning & Ephemeral Configuration

```sql
-- ============================================================================
-- PATTERN 1: IDEMPOTENT & REPLICA-AWARE TABLESPACE CREATION SCRIPT
-- ============================================================================

-- Step 1: Pre-requisite validation query (must return 0 missing replicas)
-- Ensures the DBA or Agent pre-created host directory on all nodes.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_tablespace WHERE spcname = 'fast_nvme_tier') THEN
    -- The path must exist on primary AND 100% of physical standbys!
    EXECUTE 'CREATE TABLESPACE fast_nvme_tier LOCATION ''/var/lib/postgresql/tablespaces/fast_nvme''';
  END IF;
END $$;

-- Step 2: Configure Dedicated Ephemeral Temp Tablespace
-- Prevents unindexed sort/hash spills from exhausting primary storage
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_tablespace WHERE spcname = 'temp_scratch_tier') THEN
    EXECUTE 'CREATE TABLESPACE temp_scratch_tier LOCATION ''/var/lib/postgresql/tablespaces/temp_scratch''';
  END IF;
END $$;

-- Step 3: Register in postgresql.conf (or ALTER SYSTEM in controlled IaC)
-- Multiple tablespaces can be specified for round-robin ephemeral allocation:
ALTER SYSTEM SET temp_tablespaces = 'temp_scratch_tier';
ALTER SYSTEM SET temp_file_limit = '10485760'; -- 10GB safety ceiling per backend (in KB)
SELECT pg_reload_conf();

-- Verify configuration
SELECT name, setting, source FROM pg_settings WHERE name IN ('temp_tablespaces', 'temp_file_limit');
```

---

### 2. Zero-Downtime Safe Table & Index Tablespace Migration

```sql
-- ============================================================================
-- PATTERN 2: LOCK-BOUNDED INCREMENTAL TABLESPACE RELOCATION
-- ============================================================================

-- Function to safely relocate a table with lock timeout protection
CREATE OR REPLACE PROCEDURE safe_relocate_table(
  p_schema_name TEXT,
  p_table_name TEXT,
  p_target_tablespace TEXT,
  p_max_retries INT DEFAULT 5
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_retry_count INT := 0;
  v_success BOOLEAN := FALSE;
  v_current_tablespace TEXT;
BEGIN
  -- Verify target tablespace exists
  IF NOT EXISTS (SELECT 1 FROM pg_tablespace WHERE spcname = p_target_tablespace) THEN
    RAISE EXCEPTION 'Target tablespace "%" does not exist in pg_tablespace catalog', p_target_tablespace
      USING ERRCODE = '42704';
  END IF;

  -- Inspect current tablespace (NULL means database default)
  SELECT c.reltablespace::regtablespace::text
  INTO v_current_tablespace
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = p_schema_name AND c.relname = p_table_name;

  IF v_current_tablespace = p_target_tablespace THEN
    RAISE NOTICE 'Table %.% is already in tablespace %; skipping.', p_schema_name, p_table_name, p_target_tablespace;
    RETURN;
  END IF;

  -- Retry loop with lock_timeout ladder to prevent blocking incoming traffic
  WHILE v_retry_count < p_max_retries AND NOT v_success LOOP
    BEGIN
      -- Enforce strict 2-second lock timeout
      SET LOCAL lock_timeout = '2000ms';
      SET LOCAL statement_timeout = '300000ms'; -- 5 minute maximum migration time

      EXECUTE format('ALTER TABLE %I.%I SET TABLESPACE %I', p_schema_name, p_table_name, p_target_tablespace);
      v_success := TRUE;
      RAISE NOTICE 'Successfully relocated %.% to tablespace %', p_schema_name, p_table_name, p_target_tablespace;
    EXCEPTION
      WHEN lock_not_available THEN
        v_retry_count := v_retry_count + 1;
        IF v_retry_count >= p_max_retries THEN
          RAISE EXCEPTION 'Failed to acquire lock to relocate %.% after % attempts', p_schema_name, p_table_name, p_max_retries;
        END IF;
        -- Jittered backoff (1s - 3s)
        PERFORM pg_sleep(1.0 + (random() * 2.0));
      WHEN OTHERS THEN
        RAISE;
    END;
  END LOOP;
END;
$$;
```

---

### 3. Decommissioning Tablespaces Without Orphaned File Leaks

```sql
-- ============================================================================
-- PATTERN 3: PRE-FLIGHT VERIFICATION PRIOR TO DROP TABLESPACE
-- ============================================================================

-- Query to audit all remaining objects in a tablespace before attempting DROP
CREATE OR REPLACE VIEW view_tablespace_occupants AS
SELECT 
  t.spcname AS tablespace_name,
  n.nspname AS schema_name,
  c.relname AS relation_name,
  c.relkind AS relation_type,
  pg_size_pretty(pg_relation_size(c.oid)) AS relation_size
FROM pg_class c
JOIN pg_tablespace t ON (
  CASE 
    WHEN c.reltablespace = 0 THEN (SELECT dattablespace FROM pg_database WHERE datname = current_database())
    ELSE c.reltablespace 
  END = t.oid
)
LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE t.spcname NOT IN ('pg_default', 'pg_global')
ORDER BY pg_relation_size(c.oid) DESC;

-- Pre-flight verification before dropping:
-- If count > 0, DROP TABLESPACE will fail with SQLSTATE 2BE00 (tablespace_is_not_empty)
DO $$
DECLARE
  v_count INT;
  v_target_spc CONSTANT TEXT := 'legacy_storage';
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM view_tablespace_occupants
  WHERE tablespace_name = v_target_spc;

  IF v_count > 0 THEN
    RAISE EXCEPTION 'Cannot drop tablespace "%": contains % active relations in current database', v_target_spc, v_count
      USING ERRCODE = '2BE00';
  END IF;

  -- Verify no other databases reside in this tablespace
  IF EXISTS (SELECT 1 FROM pg_database WHERE dattablespace = (SELECT oid FROM pg_tablespace WHERE spcname = v_target_spc)) THEN
    RAISE EXCEPTION 'Cannot drop tablespace "%": one or more databases use it as default tablespace', v_target_spc;
  END IF;

  EXECUTE format('DROP TABLESPACE %I', v_target_spc);
  RAISE NOTICE 'Tablespace % successfully dropped from catalog', v_target_spc;
END $$;
```

---

### 4. Go (`jackc/pgx/v5`) Production Tablespace Sentinel & Health Auditing

```go
package tablespace

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TablespaceReport captures storage and operational metrics for a tablespace.
type TablespaceReport struct {
	Name             string `json:"name"`
	Location         string `json:"location"`
	SizeBytes        int64  `json:"size_bytes"`
	RelationCount    int    `json:"relation_count"`
	AvailableBytes   int64  `json:"available_bytes,omitempty"`
	IsDefault        bool   `json:"is_default"`
	IsTempConfigured bool   `json:"is_temp_configured"`
}

// TablespaceSentinel audits tablespace health, temp_tablespaces, and directory parity.
type TablespaceSentinel struct {
	pool *pgxpool.Pool
}

func NewTablespaceSentinel(pool *pgxpool.Pool) *TablespaceSentinel {
	return &TablespaceSentinel{pool: pool}
}

// AuditClusterTablespaces performs a deep health audit on all tablespaces and temp isolation.
func (s *TablespaceSentinel) AuditClusterTablespaces(ctx context.Context) ([]TablespaceReport, error) {
	// 1. Inspect temp_tablespaces configuration
	var tempTablespaces string
	err := s.pool.QueryRow(ctx, "SHOW temp_tablespaces;").Scan(&tempTablespaces)
	if err != nil {
		return nil, fmt.Errorf("failed to check temp_tablespaces: %w", err)
	}

	tempConfigured := strings.TrimSpace(tempTablespaces) != ""

	// 2. Query all tablespaces with sizes and locations
	query := `
		SELECT 
			t.spcname,
			COALESCE(pg_tablespace_location(t.oid), 'DEFAULT_PGDATA') AS location,
			pg_tablespace_size(t.spcname) AS size_bytes,
			COUNT(c.oid) AS relation_count,
			(t.spcname = 'pg_default') AS is_default
		FROM pg_tablespace t
		LEFT JOIN pg_class c ON (
			CASE WHEN c.reltablespace = 0 
				THEN (SELECT dattablespace FROM pg_database WHERE datname = current_database())
				ELSE c.reltablespace 
			END = t.oid
		)
		GROUP BY t.spcname, t.oid
		ORDER BY size_bytes DESC;
	`

	rows, err := s.pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to query pg_tablespace: %w", err)
	}
	defer rows.Close()

	var reports []TablespaceReport
	for rows.Next() {
		var r TablespaceReport
		if err := rows.Scan(&r.Name, &r.Location, &r.SizeBytes, &r.RelationCount, &r.IsDefault); err != nil {
			return nil, fmt.Errorf("failed to scan tablespace row: %w", err)
		}
		r.IsTempConfigured = tempConfigured
		reports = append(reports, r)
	}

	return reports, nil
}

// SafeRelocateRelation relocates a table or index using a strict lock_timeout ladder.
func (s *TablespaceSentinel) SafeRelocateRelation(ctx context.Context, schema, relName, targetTablespace string, timeout time.Duration) error {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("failed to start transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Set local lock timeout to protect incoming traffic
	timeoutMs := timeout.Milliseconds()
	if timeoutMs <= 0 {
		timeoutMs = 2000
	}

	lockStmt := fmt.Sprintf("SET LOCAL lock_timeout = '%dms';", timeoutMs)
	if _, err := tx.Exec(ctx, lockStmt); err != nil {
		return fmt.Errorf("failed to set lock_timeout: %w", err)
	}

	relocateStmt := fmt.Sprintf("ALTER TABLE %s.%s SET TABLESPACE %s;",
		pgx.Identifier{schema}.Sanitize(),
		pgx.Identifier{relName}.Sanitize(),
		pgx.Identifier{targetTablespace}.Sanitize(),
	)

	if _, err := tx.Exec(ctx, relocateStmt); err != nil {
		return fmt.Errorf("failed to relocate relation: %w", err)
	}

	return tx.Commit(ctx)
}

// VerifyHostDirectoryParity verifies local filesystem directory existence and permissions.
func VerifyHostDirectoryParity(targetPath string) error {
	cleaned := filepath.Clean(targetPath)
	info, err := os.Stat(cleaned)
	if os.IsNotExist(err) {
		return fmt.Errorf("tablespace target path does not exist: %s", cleaned)
	}
	if err != nil {
		return fmt.Errorf("failed to stat tablespace path %s: %w", cleaned, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("tablespace target path is not a directory: %s", cleaned)
	}

	// Verify POSIX permissions (PostgreSQL requires directory permissions <= 0700)
	perm := info.Mode().Perm()
	if perm&0077 != 0 {
		return fmt.Errorf("directory permissions too open (%#o); PostgreSQL requires 0700", perm)
	}

	return nil
}
```

---

### 5. Python (`asyncpg`) Safe Tablespace Relocation Sentinel

```python
import asyncio
import logging
from typing import Optional, List, Dict, Any
import asyncpg

logger = logging.getLogger("tablespace_sentinel")

class TablespaceMigrationError(Exception):
    pass

class AsyncTablespaceSentinel:
    def __init__(self, dsn: str):
        self.dsn = dsn

    async def get_temp_tablespaces_status(self, conn: asyncpg.Connection) -> Optional[str]:
        """Verify if dedicated ephemeral temp_tablespaces are configured."""
        val = await conn.fetchval("SHOW temp_tablespaces;")
        return val.strip() if val else None

    async def audit_tablespace_bloat_and_spills(self, conn: asyncpg.Connection) -> List[Dict[str, Any]]:
        """Audit database temp file spills and tablespace distribution."""
        query = """
            SELECT 
                datname,
                temp_files,
                pg_size_pretty(temp_bytes) AS temp_spill_size,
                temp_bytes
            FROM pg_stat_database
            WHERE datname = current_database();
        """
        row = await conn.fetchrow(query)
        temp_status = await self.get_temp_tablespaces_status(conn)

        logger.info(
            f"DB: {row['datname']} | Temp Files: {row['temp_files']} | "
            f"Spill: {row['temp_spill_size']} | Configured temp_tablespaces: '{temp_status}'"
        )

        if not temp_status and row['temp_bytes'] > 1024 * 1024 * 500: # > 500MB
            logger.warning(
                "CRITICAL: Unisolated sort/hash temp files (>500MB) spilling into default tablespace! "
                "Configure dedicated temp_tablespaces immediately."
            )

        return [dict(row)]

    async def relocate_relation_bounded(
        self,
        schema: str,
        table_name: str,
        target_spc: str,
        max_attempts: int = 5,
        lock_timeout_ms: int = 2000
    ) -> bool:
        """Migrate relation tablespace with strict lock_timeout ladder to eliminate HOL blocking."""
        conn = await asyncpg.connect(self.dsn)
        try:
            for attempt in range(1, max_attempts + 1):
                try:
                    async with conn.transaction():
                        await conn.execute(f"SET LOCAL lock_timeout = '{lock_timeout_ms}ms';")
                        await conn.execute(
                            f'ALTER TABLE "{schema}"."{table_name}" SET TABLESPACE "{target_spc}";'
                        )
                        logger.info(f"Successfully moved {schema}.{table_name} -> {target_spc}")
                        return True
                except asyncpg.exceptions.LockNotAvailableError:
                    logger.warning(
                        f"Attempt {attempt}/{max_attempts}: Lock not available for {schema}.{table_name}; backing off."
                    )
                    await asyncio.sleep(1.0 + (0.5 * attempt))
                except Exception as e:
                    logger.error(f"Fatal migration error on {schema}.{table_name}: {e}")
                    raise TablespaceMigrationError(f"Migration failed: {e}") from e

            raise TablespaceMigrationError(
                f"Failed to acquire lock for {schema}.{table_name} after {max_attempts} attempts."
            )
        finally:
            await conn.close()
```

---

### 6. Rust (`tokio-postgres`) Tablespace Metrics Sentinel

```rust
use tokio_postgres::{Client, NoTls, Error};
use std::time::Duration;

#[derive(Debug)]
pub struct TablespaceStat {
    pub name: String,
    pub location: String,
    pub size_bytes: i64,
    pub relation_count: i64,
}

pub struct RustTablespaceSentinel;

impl RustTablespaceSentinel {
    pub async fn audit_tablespaces(client: &Client) -> Result<Vec<TablespaceStat>, Error> {
        // Assert temp_tablespaces is configured
        let temp_row = client.query_one("SHOW temp_tablespaces;", &[]).await?;
        let temp_val: &str = temp_row.get(0);
        if temp_val.trim().is_empty() {
            eprintln!("⚠️ WARNING: temp_tablespaces is EMPTY! Ephemeral spills pollute primary OLTP disk!");
        }

        let query = "
            SELECT 
                t.spcname::text,
                COALESCE(pg_tablespace_location(t.oid), 'DEFAULT_PGDATA')::text AS location,
                pg_tablespace_size(t.spcname)::bigint AS size_bytes,
                COUNT(c.oid)::bigint AS relation_count
            FROM pg_tablespace t
            LEFT JOIN pg_class c ON (
                CASE WHEN c.reltablespace = 0 
                    THEN (SELECT dattablespace FROM pg_database WHERE datname = current_database())
                    ELSE c.reltablespace 
                END = t.oid
            )
            GROUP BY t.spcname, t.oid
            ORDER BY size_bytes DESC;
        ";

        let rows = client.query(query, &[]).await?;
        let mut stats = Vec::new();

        for row in rows {
            stats.push(TablespaceStat {
                name: row.get(0),
                location: row.get(1),
                size_bytes: row.get(2),
                relation_count: row.get(3),
            });
        }

        Ok(stats)
    }

    pub async fn relocate_table_guarded(
        client: &mut Client,
        schema: &str,
        table: &str,
        target_spc: &str,
        lock_timeout_ms: u32,
    ) -> Result<(), Error> {
        let tx = client.transaction().await?;
        
        let timeout_cmd = format!("SET LOCAL lock_timeout = '{}ms';", lock_timeout_ms);
        tx.execute(&timeout_cmd, &[]).await?;

        let move_cmd = format!(
            "ALTER TABLE \"{}\".\"{}\" SET TABLESPACE \"{}\";",
            schema.replace('"', "\"\""),
            table.replace('"', "\"\""),
            target_spc.replace('"', "\"\"")
        );
        tx.execute(&move_cmd, &[]).await?;

        tx.commit().await?;
        Ok(())
    }
}
```

---

## 4. Machine-Verifiable Engine Implementation

Below is the complete production TypeScript implementation of the `AgenticDatabaseTablespaceGuardEngine`, modeling a 6-state Finite State Machine (FSM):

```typescript
/**
 * AgenticDatabaseTablespaceGuardEngine.ts
 *
 * Autonomous Governance Engine for PostgreSQL Tablespaces, Storage Tiering,
 * temp_tablespaces Ephemeral Isolation, Replica Mount Parity, and Lockout Defense.
 */

export type TablespaceFsmState =
  | 'IDENTIFY'
  | 'PREFLIGHT_MOUNT'
  | 'REPLICA_PARITY_VERIFY'
  | 'LOCK_BOUNDED_MIGRATION'
  | 'TEMP_ISOLATION'
  | 'POST_AUDIT';

export interface TablespaceRecord {
  oid: number;
  spcname: string;
  location: string;
  sizeBytes: number;
  relationCount: number;
}

export interface ReplicaNode {
  nodeId: string;
  host: string;
  status: 'STREAMING' | 'DISCONNECTED';
  existingPaths: string[];
}

export interface TablespaceAuditResult {
  state: TablespaceFsmState;
  valid: boolean;
  tempTablespaceConfigured: boolean;
  unisolatedTempSpillBytes: number;
  tablespaces: TablespaceRecord[];
  missingPathsOnReplicas: Array<{ nodeId: string; missingPath: string }>;
  violations: string[];
  remediations: string[];
}

export interface MigrationOptions {
  schema: string;
  relation: string;
  targetTablespace: string;
  lockTimeoutMs?: number;
  maxRetries?: number;
}

export class AgenticDatabaseTablespaceGuardEngine {
  private currentState: TablespaceFsmState = 'IDENTIFY';

  public getState(): TablespaceFsmState {
    return this.currentState;
  }

  /**
   * Evaluates the complete storage and tablespace topology against production invariants.
   */
  public evaluateCluster(
    tablespaces: TablespaceRecord[],
    tempTablespacesSetting: string,
    tempSpillBytes: number,
    replicas: ReplicaNode[]
  ): TablespaceAuditResult {
    const violations: string[] = [];
    const remediations: string[] = [];
    const missingPaths: Array<{ nodeId: string; missingPath: string }> = [];

    // State: IDENTIFY
    this.currentState = 'IDENTIFY';

    // State: TEMP_ISOLATION Check
    this.currentState = 'TEMP_ISOLATION';
    const isTempConfigured = tempTablespacesSetting.trim().length > 0;
    if (!isTempConfigured) {
      violations.push(
        'temp_tablespaces is unset. Large sort/hash spills write to default tablespace, threatening OLTP disk saturation.'
      );
      remediations.push(
        "ALTER SYSTEM SET temp_tablespaces = 'temp_scratch_tier'; SELECT pg_reload_conf();"
      );
    }

    if (!isTempConfigured && tempSpillBytes > 500 * 1024 * 1024) {
      violations.push(
        `High unisolated ephemeral disk spillover (${(tempSpillBytes / (1024 * 1024)).toFixed(1)} MB) detected on primary volume!`
      );
    }

    // State: PREFLIGHT_MOUNT & REPLICA_PARITY_VERIFY
    this.currentState = 'REPLICA_PARITY_VERIFY';
    for (const ts of tablespaces) {
      if (ts.location && ts.location !== 'DEFAULT_PGDATA') {
        for (const replica of replicas) {
          if (!replica.existingPaths.includes(ts.location)) {
            missingPaths.push({
              nodeId: replica.nodeId,
              missingPath: ts.location,
            });
            violations.push(
              `Standby replica '${replica.nodeId}' lacks required tablespace path '${ts.location}'. Physical replication will fail!`
            );
            remediations.push(
              `Pre-create directory '${ts.location}' with 0700 permissions and postgres ownership on replica '${replica.host}'.`
            );
          }
        }
      }
    }

    // State: POST_AUDIT
    this.currentState = 'POST_AUDIT';
    const valid = violations.length === 0;

    return {
      state: this.currentState,
      valid,
      tempTablespaceConfigured: isTempConfigured,
      unisolatedTempSpillBytes: tempSpillBytes,
      tablespaces,
      missingPathsOnReplicas: missingPaths,
      violations,
      remediations,
    };
  }

  /**
   * Generates safe, lock-bounded SQL migration statements for relocating a relation.
   */
  public generateSafeRelocationDdl(options: MigrationOptions): string[] {
    const lockTimeout = options.lockTimeoutMs ?? 2000;
    const { schema, relation, targetTablespace } = options;

    return [
      '-- Lock-bounded tablespace relocation with autonomous backoff fence',
      'BEGIN;',
      `SET LOCAL lock_timeout = '${lockTimeout}ms';`,
      `SET LOCAL statement_timeout = '300000ms'; -- 5 minutes safety ceiling`,
      `ALTER TABLE "${schema}"."${relation}" SET TABLESPACE "${targetTablespace}";`,
      'COMMIT;',
    ];
  }

  /**
   * Generates safe tablespace decommissioning validation script.
   */
  public generateSafeDropTablespaceDdl(tablespaceName: string): string[] {
    return [
      `-- Safe DROP TABLESPACE guard script for: ${tablespaceName}`,
      'DO $$',
      'DECLARE',
      '  v_cnt INT;',
      'BEGIN',
      '  SELECT COUNT(*) INTO v_cnt',
      '  FROM pg_class c',
      '  JOIN pg_tablespace t ON (',
      '    CASE WHEN c.reltablespace = 0 THEN',
      '      (SELECT dattablespace FROM pg_database WHERE datname = current_database())',
      '    ELSE c.reltablespace END = t.oid',
      '  )',
      `  WHERE t.spcname = '${tablespaceName}';`,
      '  IF v_cnt > 0 THEN',
      `    RAISE EXCEPTION 'Cannot drop tablespace "${tablespaceName}": contains % active relations', v_cnt;`,
      '  END IF;',
      `  EXECUTE 'DROP TABLESPACE "${tablespaceName}"';`,
      'END $$;',
    ];
  }
}
```

---

## 5. Definition of Done (DoD) CI Verification Gates & Machine-Checkable Checklist

Before merging any pull request, infrastructure commit, or migration altering PostgreSQL tablespaces, the autonomous agent must verify the following 6 Definition of Done (DoD) gates:

| Gate | Verification Target | Deterministic Invariant Check | Pass Criteria |
| :--- | :--- | :--- | :--- |
| **Gate 1** | `temp_tablespaces` Isolation | `SHOW temp_tablespaces;` | Must return at least one valid, dedicated scratch tablespace (`temp_scratch_tier`). Zero unisolated temp spills into `$PGDATA/base/pgsql_tmp`. |
| **Gate 2** | Temp File Quota Fence | `SHOW temp_file_limit;` | Value must be bounded between `1GB` and `50GB` (`1048576`–`52428800` KB). Never `-1` (unlimited). |
| **Gate 3** | Replica Directory Parity | Filesystem audit across 100% of physical streaming standbys | All `pg_tablespace.spcoptions` and location directories must pre-exist on 100% of replica nodes with POSIX `0700` and `postgres` ownership prior to `CREATE TABLESPACE`. |
| **Gate 4** | DDL Portability Invariant | Static analysis on migration SQL files | **Zero** un-templated `TABLESPACE <name>` clauses in application migrations. Tablespaces must be applied via declarative session defaults or migration management abstractions. |
| **Gate 5** | Lock Timeout Fence | `ALTER TABLE / INDEX ... SET TABLESPACE` | Must execute strictly within a transactional scope declaring `SET LOCAL lock_timeout <= '2000ms'`. Zero indefinite blocking. |
| **Gate 6** | `pg_dump` Portability | Backup and CI restoration commands | Automated CI/CD restore pipelines must declare `pg_dump --no-tablespaces` or `pg_restore --no-tablespaces`, guaranteeing 100% environment-agnostic restore. |

---

### Machine-Checkable Pre-Flight SQL Verification Suite

```sql
-- Continuous Integration Verification Query: Run on database target
SELECT
  CASE 
    WHEN setting = '' THEN 'FAIL: temp_tablespaces is empty! Ephemeral spills pollute primary disk.'
    ELSE 'PASS: temp_tablespaces isolated (' || setting || ')'
  END AS gate_1_temp_isolation
FROM pg_settings WHERE name = 'temp_tablespaces';

SELECT
  CASE 
    WHEN setting = '-1' THEN 'FAIL: temp_file_limit is unlimited! Susceptible to disk space exhaustion.'
    ELSE 'PASS: temp_file_limit bounded at ' || setting || ' KB'
  END AS gate_2_temp_quota
FROM pg_settings WHERE name = 'temp_file_limit';

SELECT
  spcname AS tablespace_name,
  pg_size_pretty(pg_tablespace_size(spcname)) AS size,
  COALESCE(pg_tablespace_location(oid), 'DEFAULT_DATA') AS host_location
FROM pg_tablespace
ORDER BY pg_tablespace_size(spcname) DESC;
```
