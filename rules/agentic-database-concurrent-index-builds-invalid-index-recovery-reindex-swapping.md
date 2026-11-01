---
description: PostgreSQL CREATE INDEX CONCURRENTLY, REINDEX CONCURRENTLY, invalid index recovery (indisvalid = false), pg_stat_progress_create_index telemetry, WaitForOlderSnapshots lock convoy mitigation, _ccnew/_ccold cleanup, zero-downtime unique constraint promotion, and migration runner transaction decoupling across Go (pgx/v5), TypeScript (Kysely/Drizzle/Prisma), Python (asyncpg/SQLAlchemy), Rust (sqlx), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{index,migration,reindex,schema,database,ddl,concurrently}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/migrations/**/*.{ts,js,go,rs,py},**/migrations/**/*.{sql,ts,js,py},**/internal/db/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Concurrent Index Builds, Invalid Index Recovery, Progress Telemetry & Online Reindexing Swapping Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to create secondary indexes, rebuild bloated B-Trees (`REINDEX CONCURRENTLY`), apply unique constraints, migrate high-volume relational tables, or orchestrate schema changes across PostgreSQL, Go (`jackc/pgx/v5`, `golang-migrate`), TypeScript (`Kysely`, `Drizzle`, `Prisma`), Python (`asyncpg`, `Alembic`), or Rust (`sqlx`, `refinery`). Eliminate the "Silent Invalid Index Write-Amplification & Storage Zombie Trap" (where failed concurrent builds leave `indisvalid = false` but `indisready = true`, forcing every `INSERT`, `UPDATE`, and `DELETE` to continuously write to an index that the query planner can NEVER use for reads), the "Migration Transaction Block Prohibition Crash (`SQLSTATE 25001`)" (where agents put `CREATE INDEX CONCURRENTLY` inside standard migration files wrapped in `BEGIN ... COMMIT`, causing instant migration crashes and prompting agents to dangerously strip `CONCURRENTLY` and lock entire tables with `SHARE` locks), the "WaitForOlderSnapshots Indefinite Freeze & Lock Convoy Avalanche" (where concurrent index builds stall waiting for lingering read transactions, prompting queuing `ACCESS EXCLUSIVE` DDL to pile behind them and starve the entire connection pool), the "REINDEX CONCURRENTLY `_ccnew` / `_ccold` Abandonment Disaster" (where aborted reindexes leave behind orphaned temporary indexes that block subsequent reindex commands with `relation already exists`), the "Unique Constraint Race Collision & Poison Build Loop" (where concurrent duplicate inserts fail unique index builds halfway through and agents loop blindly creating numbered duplicate invalid indexes), and the "pg_stat_progress_create_index Blindness & Premature Abort Trap" (where unmonitored builds are killed mid-run out of impatience, corrupting execution plans and wasting gigabytes of disk I/O) by establishing a strict 5-Tier Concurrent Index Governance Ladder, non-transactional migration runners, live progress telemetry, automatic `_ccnew` / `_ccold` cleanup, safe `DROP INDEX CONCURRENTLY`, and machine-verifiable CI sentinels.

---

## 1. Architectural Taxonomy: The 6 Concurrent Index Catastrophes vs The 5-Tier Governance Ladder

In high-concurrency production databases, creating an index synchronously via standard `CREATE INDEX` acquires a `SHARE` lock on the target table. This lock permits concurrent `SELECT` queries but strictly **blocks all `INSERT`, `UPDATE`, and `DELETE` operations** until the entire index build completes. On a table with 50 million rows, this write lockout lasts for several minutes to hours, directly causing upstream HTTP 504 gateway timeouts, connection pool exhaustion, and customer-facing downtime.

To avoid write lockouts, PostgreSQL provides `CREATE INDEX CONCURRENTLY` (CIC) and `REINDEX CONCURRENTLY` (RC). Instead of a single atomic transaction, CIC runs across **multiple independent transactions and phases**:
1. **Catalog Registration Phase (Tx 1)**: Declares the index entry in `pg_class` and `pg_index`, marked as `indisvalid = false` and `indisready = false`. Acquires a weak `SHARE UPDATE EXCLUSIVE` lock on the table (allowing concurrent reads and writes). Commits immediately.
2. **First Snapshot Drain Barrier (Wait 1)**: Waits for all existing transactions that opened snapshots before Tx 1 committed to finish (`WaitForOlderSnapshots`). This guarantees that no transaction is unaware of the pending index definition.
3. **Initial Heap Scan Phase (Tx 2)**: Scans the table heap to build the initial B-Tree structure. Sets `indisready = true` so concurrent transactions now write new row modifications into both the heap and the index. Commits.
4. **Second Snapshot Drain Barrier (Wait 2)**: Waits for all transactions that were active during Phase 3 to terminate.
5. **Catch-up Validation Scan Phase (Tx 3)**: Performs a second table scan to index any missing tuples inserted or updated during Phase 3, and verifies uniqueness invariants if `UNIQUE` was declared.
6. **Mark Valid & Old Snapshot Release (Tx 4)**: Marks `indisvalid = true` in `pg_index`. Waits for all remaining snapshots that do not yet recognize the index as valid to terminate. Commits. The index is now active for query planning.

When autonomous coding agents generate schema migrations or remediation scripts, LLMs routinely commit fatal architectural anti-patterns:

```sql
-- ❌ CATASTROPHIC LLM CONCURRENT INDEX & MIGRATION ANTI-PATTERNS

-- Anti-Pattern 1: Running CONCURRENTLY inside a standard migration transaction block
BEGIN; -- Liquibase / Flyway / Drizzle default!
CREATE INDEX CONCURRENTLY idx_users_email ON users (email); 
-- CRASH: SQLSTATE 25001: CREATE INDEX CONCURRENTLY cannot run inside a transaction block
COMMIT;

-- Anti-Pattern 2: LLM "fixes" the error by removing CONCURRENTLY in production!
ALTER TABLE orders ADD COLUMN fulfillment_status VARCHAR(32);
CREATE INDEX idx_orders_status ON orders (fulfillment_status);
-- CATASTROPHE: Acquires SHARE lock, blocks all order creations for 45 minutes!

-- Anti-Pattern 3: Leaving failed invalid indexes to silently bloat and degrade writes forever
-- CIC fails due to statement_timeout. Result in pg_index:
-- indisvalid = false (Never used by SELECT)
-- indisready = true  (Every single INSERT/UPDATE/DELETE MUST update this index!)
-- Write latency jumps 40%, 15 GB of dead storage accumulates silently.

-- Anti-Pattern 4: Blindly dropping an invalid index with plain DROP INDEX
DROP INDEX idx_users_email; 
-- CATASTROPHE: Plain DROP INDEX acquires ACCESS EXCLUSIVE lock on the entire table!
-- Queues behind long reads, blocks all incoming writes, crashes web cluster.

-- Anti-Pattern 5: Re-running REINDEX CONCURRENTLY after a crash without cleaning _ccnew
REINDEX TABLE CONCURRENTLY users;
-- CRASH: ERROR: relation "users_pkey_ccnew" already exists (SQLSTATE 42P07).
```

### The 6 Concurrent Index Catastrophes

| Catastrophe | Root Cause Engine Mechanism | Production Blast Radius | Recovery Complexity |
| :--- | :--- | :--- | :--- |
| **1. Silent Invalid Index Zombie Trap** | CIC aborts (timeout, cancel, unique collision). PostgreSQL marks `indisvalid = false` but leaves `indisready = true`. | Massive write amplification; every write updates an unreadable index; disk bloat. | Medium (Detect via `pg_index`, drop concurrently). |
| **2. Migration Transaction Block Crash** | CIC inherently relies on internal multi-transaction commits. Migration runners wrap files in `BEGIN ... COMMIT`. | Migration crashes with `SQLSTATE 25001`; agent strips `CONCURRENTLY` and locks production table. | High (Requires runner configuration decoupling). |
| **3. WaitForOlderSnapshots Lock Convoy** | CIC waits for older transactions. A waiting `ACCESS EXCLUSIVE` DDL queues behind CIC; fast reads queue behind DDL. | Total cluster paralysis within 5 seconds; client connection pools exhausted. | Extreme (Requires `lock_timeout` & process termination). |
| **4. REINDEX `_ccnew` / `_ccold` Abandonment** | RC crashes or gets cancelled midway, leaving behind shadow indexes (`<idx>_ccnew` or `<idx>_ccold`). | Future `REINDEX CONCURRENTLY` calls permanently fail with `relation already exists`. | High (Requires catalog inspection and targeted concurrent drop). |
| **5. Unique Race Collision Poison Loop** | Live duplicate rows inserted during build phases violate uniqueness; build aborts; agent loops creating new indexes. | Tens of invalid duplicate indexes accumulate on the table, choking heap writes. | Medium (Clean invalid indexes, deduplicate data first). |
| **6. Telemetry Blindness Premature Abort** | Agent lacks visibility into `pg_stat_progress_create_index` phases and kills long-running builds at 98%. | Gigabytes of wasted write I/O, storage churn, and corrupted plan expectations. | Low (Monitor progress phases before acting). |

### The 5-Tier Concurrent Index Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────┐
│      5-TIER CONCURRENT INDEX & REINDEX GOVERNANCE LADDER               │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Autonomous DoD Sentinels & Zero-Invalid-Index CI Enforcement   │
│   • CI migration linting bans non-concurrent index DDL on large tables │
│   • Nightly watchdog queries pg_index for indisvalid = false           │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Zero-Downtime Unique Constraint & PK Hot-Swapping             │
│   • Build UNIQUE INDEX CONCURRENTLY first                             │
│   • Attach via ALTER TABLE ... ADD CONSTRAINT USING INDEX (instant)   │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Orphaned Shadow Index (_ccnew/_ccold) & Invalid Index Cleanup  │
│   • Pre-reindex inspection drops lingering _ccnew / _ccold objects    │
│   • DROP INDEX CONCURRENTLY IF EXISTS with explicit lock_timeout       │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Multi-Phase Progress Telemetry & Lock Convoy Fencing           │
│   • Track pg_stat_progress_create_index blocks_done vs blocks_total    │
│   • Set lock_timeout = '3s' to prevent DDL head-of-line blocking       │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Transactional Decoupling & Pre-Flight Invariant Validation     │
│   • Enforce non-transactional runner execution (transactional: false) │
│   • Drain or abort long-running active transactions before launch      │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Formalisms & Build Storage Physics

### 2.1 Concurrent Index Build Duration & Phase Timing Model

The total wall-clock duration of `CREATE INDEX CONCURRENTLY` ($T_{\text{cic}}$) is the sum of two sequential table heap scans plus two snapshot synchronization delays:

$$T_{\text{cic}} = \frac{V_{\text{heap}}}{R_{\text{seq\_scan}}} + \tau_{\text{drain}}(S_1) + \frac{V_{\text{heap}}}{R_{\text{seq\_scan}}} + \tau_{\text{drain}}(S_2) + \Delta_{\text{sort}}$$

Where:
- $V_{\text{heap}}$ is the total size of the relation heap in bytes.
- $R_{\text{seq\_scan}}$ is the sequential scanning throughput governed by NVMe I/O bandwidth and `maintenance_work_mem`.
- $\tau_{\text{drain}}(S_1)$ is the time required for all backend processes with active snapshots prior to phase 1 to terminate:
  $$\tau_{\text{drain}}(S) = \max_{i \in \text{Backends}} \left( t_{\text{end}}(B_i) - t_{\text{barrier}} \right)$$
- $\Delta_{\text{sort}}$ is external sort duration if the indexed keys exceed `maintenance_work_mem`.

**Critical Insight**: If a single idle-in-transaction connection or uncommitted analytical query runs for 4 hours, $\tau_{\text{drain}}(S) = 4\text{ hours}$. CIC will appear completely frozen at 50% or 95% completion, even though zero I/O is occurring.

### 2.2 Invalid Index Write Amplification Equation

When an invalid index ($I_{\text{invalid}}$ with `indisvalid = false` and `indisready = true`) lingers on a relation $R$, every write mutation incurs an inescapable write amplification factor $A_w$:

$$A_w = 1 + \sum_{j \in \mathcal{I}_{\text{valid}}} \frac{C_{\text{btree\_insert}}(j)}{C_{\text{heap\_insert}}} + \sum_{k \in \mathcal{I}_{\text{invalid}}} \frac{C_{\text{btree\_insert}}(k)}{C_{\text{heap\_insert}}}$$

Because $I_{\text{invalid}}$ provides zero selectivity or read acceleration ($Q_{\text{read}}(I_{\text{invalid}}) = 0$), the efficiency coefficient $\eta$ drops catastrophically:

$$\eta = \frac{\text{Read Acceleration Benefit}}{\text{Write Amplification Cost}} = 0$$

Every additional invalid index permanently consumes $15\%\text{--}35\%$ more CPU and IOPS on high-throughput OLTP tables.

### 2.3 Lock Convoy Head-of-Line Blocking Probability

In PostgreSQL's FIFO lock manager queue, the probability $P_{\text{convoy}}$ that a concurrent index build triggers a database-wide connection stall is governed by the presence of conflicting DDL requests ($L_{\text{exclusive}}$):

$$P_{\text{convoy}} = 1 - e^{-\lambda_{\text{ddl}} \cdot T_{\text{cic}}}$$

Where $\lambda_{\text{ddl}}$ is the arrival rate of schema migrations, `VACUUM FULL`, `CLUSTER`, or table alters. If an `ALTER TABLE` arrives while CIC is running, it queues behind CIC's `SHARE UPDATE EXCLUSIVE` lock. All subsequent fast `SELECT` queries queue behind the `ACCESS EXCLUSIVE` request, driving active connections from 20 to 1,000 within seconds. Enforcing `lock_timeout = '3s'` on all operations bounds this queue window:

$$\lim_{t_{\text{timeout}} \to 3\text{s}} P_{\text{convoy}} \approx 0$$

---

## 3. The 5-Tier Concurrent Index & Reindex Governance Ladder

### Tier 0: Transactional Decoupling & Pre-Flight Validation
- **Rule 0.1**: Never allow `CREATE INDEX CONCURRENTLY` or `REINDEX CONCURRENTLY` inside `BEGIN ... COMMIT` blocks.
  - In Flyway: use `// Non-transactional migration` or split into separate `.sql` files configured with `mixed=false`.
  - In Liquibase: use `<changeSet ... runInTransaction="false">`.
  - In golang-migrate: use file extension or runner setting with non-transactional flags.
  - In Drizzle: use `db.execute(sql.raw('CREATE INDEX CONCURRENTLY ...'))` outside transaction closures.
  - In Prisma: execute in raw un-wrapped statements via `$executeRawUnsafe`.
- **Rule 0.2**: Pre-flight inspection: query `pg_stat_activity` for transactions older than 3 minutes. If found, either wait or cleanly terminate them before launching CIC.

### Tier 1: Multi-Phase Progress Telemetry & Lock Convoy Fencing
- **Rule 1.1**: Set explicit session timeouts before executing CIC:
  ```sql
  SET statement_timeout = '0';           -- Do not let aggressive HTTP client timeouts kill 10-minute builds
  SET lock_timeout = '3000ms';           -- Abort within 3 seconds if unable to acquire SHARE UPDATE EXCLUSIVE
  SET idle_in_transaction_session_timeout = '10000ms';
  ```
- **Rule 1.2**: Monitor `pg_stat_progress_create_index` during migration execution. Track phases:
  - `initializing`
  - `building index: scanning table & writing new index` (Phase 1)
  - `waiting for older snapshots (phase 1)`
  - `building index: scanning table to sort & finalize` (Phase 2)
  - `waiting for older snapshots (phase 2)`
  - `finalizing`

### Tier 2: Orphaned Shadow Index (`_ccnew`/`_ccold`) & Invalid Index Cleanup
- **Rule 2.1**: Before running `REINDEX CONCURRENTLY`, inspect the catalog for aborted shadow indexes matching `%_ccnew` or `%_ccold`.
- **Rule 2.2**: Always drop invalid or orphaned shadow indexes using `DROP INDEX CONCURRENTLY IF EXISTS <name>;`. Never use non-concurrent `DROP INDEX`, which locks the parent table against reads.

### Tier 3: Zero-Downtime Unique Constraint & PK Hot-Swapping
- **Rule 3.1**: Never use `ALTER TABLE users ADD CONSTRAINT uq_email UNIQUE (email);` directly on large tables. It performs a synchronous validation scan under `ACCESS EXCLUSIVE`.
- **Rule 3.2**: Execute the 2-step decoupled pattern:
  ```sql
  -- Step 1: Build unique index concurrently (Zero read/write lockout)
  CREATE UNIQUE INDEX CONCURRENTLY idx_users_email_uq ON users (email);

  -- Step 2: Instant constraint attachment (Sub-millisecond metadata lock)
  ALTER TABLE users ADD CONSTRAINT uq_users_email UNIQUE USING INDEX idx_users_email_uq;
  ```

### Tier 4: Autonomous DoD Sentinels & Zero-Invalid-Index CI Enforcement
- **Rule 4.1**: CI gate failure if `pg_index` contains any relation with `indisvalid = false`.
- **Rule 4.2**: Nightly scheduled database watchdog that alerts on any newly created invalid indexes and automatically executes concurrent remediation.

---

## 4. Production Code Implementations

### 4.1 Go (`jackc/pgx/v5`): Non-Transactional Migration Engine & Telemetry Watchdog

```go
package migration

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// IndexProgress tracks PostgreSQL pg_stat_progress_create_index telemetry.
type IndexProgress struct {
	Phase           string
	BlocksDone      int64
	BlocksTotal     int64
	TuplesDone      int64
	TuplesTotal     int64
	LockersDone     int64
	LockersTotal    int64
	PercentComplete float64
}

type ConcurrentIndexManager struct {
	pool *pgxpool.Pool
}

func NewConcurrentIndexManager(pool *pgxpool.Pool) (*ConcurrentIndexManager, error) {
	if pool == nil {
		return nil, errors.New("pgx pool must not be nil")
	}
	return &ConcurrentIndexManager{pool: pool}, nil
}

// CleanInvalidIndexes detects and safely drops invalid indexes concurrently.
func (m *ConcurrentIndexManager) CleanInvalidIndexes(ctx context.Context, tableName string) ([]string, error) {
	query := `
		SELECT c.relname
		FROM pg_class c
		JOIN pg_index i ON i.indexrelid = c.oid
		JOIN pg_class t ON t.oid = i.indrelid
		WHERE t.relname = $1
		  AND i.indisvalid = false;
	`
	rows, err := m.pool.Query(ctx, query, tableName)
	if err != nil {
		return nil, fmt.Errorf("failed to query invalid indexes: %w", err)
	}
	defer rows.Close()

	var invalidIndexes []string
	for rows.Next() {
		var idxName string
		if err := rows.Scan(&idxName); err != nil {
			return nil, err
		}
		invalidIndexes = append(invalidIndexes, idxName)
	}

	for _, idxName := range invalidIndexes {
		// INVARIANT: Always drop invalid indexes CONCURRENTLY with lock_timeout
		dropSQL := fmt.Sprintf("DROP INDEX CONCURRENTLY IF EXISTS %q;", idxName)
		dropCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		_, err := m.pool.Exec(dropCtx, dropSQL)
		cancel()
		if err != nil {
			return invalidIndexes, fmt.Errorf("failed dropping invalid index %s: %w", idxName, err)
		}
	}

	return invalidIndexes, nil
}

// BuildIndexConcurrently executes CIC outside any transaction block with live telemetry.
func (m *ConcurrentIndexManager) BuildIndexConcurrently(
	ctx context.Context,
	tableName string,
	indexName string,
	columns string,
	isUnique bool,
) error {
	// Step 1: Pre-clean any leftover invalid index with this name
	_, err := m.CleanInvalidIndexes(ctx, tableName)
	if err != nil {
		return fmt.Errorf("pre-flight cleanup failed: %w", err)
	}

	// Step 2: Acquire a dedicated standalone connection (NEVER execute in a transaction)
	conn, err := m.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("failed to acquire connection: %w", err)
	}
	defer conn.Release()

	// Step 3: Configure safety timeouts
	if _, err := conn.Exec(ctx, "SET lock_timeout = '3000ms'; SET statement_timeout = '0';"); err != nil {
		return fmt.Errorf("failed setting session timeouts: %w", err)
	}

	// Step 4: Launch CIC in background goroutine while monitoring telemetry
	uniqueClause := ""
	if isUnique {
		uniqueClause = "UNIQUE"
	}
	createSQL := fmt.Sprintf("CREATE %s INDEX CONCURRENTLY IF NOT EXISTS %q ON %q (%s);",
		uniqueClause, indexName, tableName, columns)

	doneChan := make(chan error, 1)
	go func() {
		_, execErr := conn.Exec(ctx, createSQL)
		doneChan <- execErr
	}()

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case err := <-doneChan:
			if err != nil {
				// Cleanup on failure
				_ = m.dropFailedIndex(context.Background(), indexName)
				return fmt.Errorf("CREATE INDEX CONCURRENTLY failed: %w", err)
			}
			return m.verifyIndexValid(ctx, indexName)

		case <-ticker.C:
			progress, pErr := m.queryProgress(ctx, indexName)
			if pErr == nil && progress != nil {
				fmt.Printf("[CIC Telemetry] Index: %s | Phase: %s | Blocks: %d/%d (%.1f%%)\n",
					indexName, progress.Phase, progress.BlocksDone, progress.BlocksTotal, progress.PercentComplete)
			}
		}
	}
}

func (m *ConcurrentIndexManager) queryProgress(ctx context.Context, indexName string) (*IndexProgress, error) {
	query := `
		SELECT phase, blocks_done, blocks_total, tuples_done, tuples_total, lockers_done, lockers_total
		FROM pg_stat_progress_create_index
		WHERE index_relid = $1::regclass;
	`
	row := m.pool.QueryRow(ctx, query, indexName)
	var p IndexProgress
	var bDone, bTotal, tDone, tTotal, lDone, lTotal sql.NullInt64
	err := row.Scan(&p.Phase, &bDone, &bTotal, &tDone, &tTotal, &lDone, &lTotal)
	if err != nil {
		return nil, err
	}
	p.BlocksDone = bDone.Int64
	p.BlocksTotal = bTotal.Int64
	p.TuplesDone = tDone.Int64
	p.TuplesTotal = tTotal.Int64
	p.LockersDone = lDone.Int64
	p.LockersTotal = lTotal.Int64

	if p.BlocksTotal > 0 {
		p.PercentComplete = (float64(p.BlocksDone) / float64(p.BlocksTotal)) * 100.0
	}
	return &p, nil
}

func (m *ConcurrentIndexManager) verifyIndexValid(ctx context.Context, indexName string) error {
	query := `SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = $1;`
	var isValid bool
	err := m.pool.QueryRow(ctx, query, indexName).Scan(&isValid)
	if err != nil {
		return fmt.Errorf("failed verifying index status: %w", err)
	}
	if !isValid {
		return fmt.Errorf("index %s is marked invalid (indisvalid = false)", indexName)
	}
	return nil
}

func (m *ConcurrentIndexManager) dropFailedIndex(ctx context.Context, indexName string) error {
	dropSQL := fmt.Sprintf("DROP INDEX CONCURRENTLY IF EXISTS %q;", indexName)
	_, err := m.pool.Exec(ctx, dropSQL)
	return err
}
```

---

### 4.2 TypeScript (`Kysely` / `pg`): Zero-Downtime Unique Constraint & Reindex Swapper

```typescript
import { Kysely, sql } from 'kysely';

export interface IndexBuildReport {
  indexName: string;
  tableName: string;
  isValid: boolean;
  durationMs: number;
  cleanedOrphans: string[];
}

export class ConcurrentIndexManager {
  constructor(private readonly db: Kysely<any>) {}

  /**
   * Promotes a unique constraint using the 2-step decoupled pattern:
   * 1. CREATE UNIQUE INDEX CONCURRENTLY (non-blocking)
   * 2. ALTER TABLE ADD CONSTRAINT USING INDEX (instant sub-millisecond lock)
   */
  async promoteUniqueConstraintSafely(
    tableName: string,
    constraintName: string,
    columnNames: string[]
  ): Promise<IndexBuildReport> {
    const tempIndexName = `${constraintName}_idx`;
    const start = Date.now();

    // Step 1: Pre-clean any orphaned invalid index from previous crashes
    const cleaned = await this.cleanOrphanedIndexes(tempIndexName);

    // Step 2: Build the unique index concurrently outside any transaction
    // Enforce lock_timeout to prevent lock convoys
    await sql`SET lock_timeout = '3000ms'`.execute(this.db);
    
    try {
      const cols = columnNames.map((c) => `"${c}"`).join(', ');
      await sql`
        CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ${sql.raw(`"${tempIndexName}"`)}
        ON ${sql.raw(`"${tableName}"`)} (${sql.raw(cols)});
      `.execute(this.db);
    } catch (err: any) {
      // Clean up zombie index if build failed
      await sql`DROP INDEX CONCURRENTLY IF EXISTS ${sql.raw(`"${tempIndexName}"`)}`.execute(this.db);
      throw new Error(`Failed to create concurrent unique index: ${err.message}`);
    }

    // Step 3: Verify the index is marked indisvalid = true
    const isValid = await this.assertIndexValid(tempIndexName);
    if (!isValid) {
      await sql`DROP INDEX CONCURRENTLY IF EXISTS ${sql.raw(`"${tempIndexName}"`)}`.execute(this.db);
      throw new Error(`Index ${tempIndexName} was created with indisvalid = false.`);
    }

    // Step 4: Attach the index as a table constraint (sub-millisecond catalog swap)
    await sql`
      ALTER TABLE ${sql.raw(`"${tableName}"`)}
      ADD CONSTRAINT ${sql.raw(`"${constraintName}"`)}
      UNIQUE USING INDEX ${sql.raw(`"${tempIndexName}"`)};
    `.execute(this.db);

    return {
      indexName: tempIndexName,
      tableName,
      isValid: true,
      durationMs: Date.now() - start,
      cleanedOrphans: cleaned,
    };
  }

  /**
   * Cleans orphaned _ccnew or _ccold indexes left behind by interrupted REINDEX CONCURRENTLY.
   */
  async cleanOrphanedIndexes(baseName: string): Promise<string[]> {
    const result = await sql<{ relname: string }>`
      SELECT c.relname
      FROM pg_class c
      JOIN pg_index i ON i.indexrelid = c.oid
      WHERE (c.relname LIKE ${baseName + '_ccnew%'} 
         OR c.relname LIKE ${baseName + '_ccold%'}
         OR c.relname = ${baseName})
        AND i.indisvalid = false;
    `.execute(this.db);

    const dropped: string[] = [];
    for (const row of result.rows) {
      await sql`DROP INDEX CONCURRENTLY IF EXISTS ${sql.raw(`"${row.relname}"`)}`.execute(this.db);
      dropped.push(row.relname);
    }
    return dropped;
  }

  private async assertIndexValid(indexName: string): Promise<boolean> {
    const res = await sql<{ indisvalid: boolean }>`
      SELECT i.indisvalid
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = ${indexName};
    `.execute(this.db);

    return res.rows.length > 0 && res.rows[0].indisvalid === true;
  }
}
```

---

### 4.3 Python (`asyncpg`): Telemetry Poller & Safe Reindexing Swapper

```python
import asyncio
import logging
from typing import Dict, Any, List

import asyncpg

logger = logging.getLogger("db.concurrent_index")

class ConcurrentIndexOperator:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def safe_reindex_table_concurrently(self, table_name: str) -> Dict[str, Any]:
        """
        Executes REINDEX TABLE CONCURRENTLY with pre-cleanup of orphaned _ccnew/_ccold
        indexes and active progress polling.
        """
        async with self.pool.acquire() as conn:
            # 1. Clean orphaned shadow indexes
            cleaned = await self._clean_shadow_indexes(conn, table_name)
            if cleaned:
                logger.warning(f"Cleaned {len(cleaned)} orphaned shadow indexes on {table_name}: {cleaned}")

            # 2. Set strict lock timeout
            await conn.execute("SET lock_timeout = '4000ms'; SET statement_timeout = '0';")

            # 3. Launch REINDEX CONCURRENTLY as background task
            reindex_task = asyncio.create_task(
                conn.execute(f'REINDEX TABLE CONCURRENTLY "{table_name}";')
            )

            # 4. Poll progress from pg_stat_progress_create_index
            while not reindex_task.done():
                progress = await self._get_reindex_progress(table_name)
                if progress:
                    logger.info(
                        f"Reindexing {table_name}: Phase={progress['phase']}, "
                        f"Blocks={progress['blocks_done']}/{progress['blocks_total']} ({progress['pct']}%)"
                    )
                await asyncio.sleep(2.0)

            # 5. Await result or propagate error
            try:
                await reindex_task
            except Exception as e:
                logger.error(f"REINDEX CONCURRENTLY failed on {table_name}: {e}")
                # Clean up newly orphaned shadow indexes
                await self._clean_shadow_indexes(conn, table_name)
                raise

            return {"table": table_name, "status": "completed", "cleaned_orphans": cleaned}

    async def _clean_shadow_indexes(self, conn: asyncpg.Connection, table_name: str) -> List[str]:
        query = """
            SELECT c.relname
            FROM pg_class c
            JOIN pg_index i ON i.indexrelid = c.oid
            JOIN pg_class t ON t.oid = i.indrelid
            WHERE t.relname = $1
              AND (c.relname LIKE '%_ccnew%' OR c.relname LIKE '%_ccold%' OR i.indisvalid = false);
        """
        rows = await conn.fetch(query, table_name)
        cleaned = []
        for r in rows:
            idx_name = r["relname"]
            await conn.execute(f'DROP INDEX CONCURRENTLY IF EXISTS "{idx_name}";')
            cleaned.append(idx_name)
        return cleaned

    async def _get_reindex_progress(self, table_name: str) -> Dict[str, Any]:
        query = """
            SELECT phase, blocks_done, blocks_total, tuples_done, tuples_total
            FROM pg_stat_progress_create_index p
            JOIN pg_class c ON c.oid = p.relid
            WHERE c.relname = $1;
        """
        row = await self.pool.fetchrow(query, table_name)
        if not row:
            return {}
        b_done = row["blocks_done"] or 0
        b_total = row["blocks_total"] or 1
        pct = round((b_done / max(b_total, 1)) * 100.0, 1)
        return {
            "phase": row["phase"],
            "blocks_done": b_done,
            "blocks_total": b_total,
            "pct": pct,
        }
```

---

### 4.4 Rust (`sqlx`): Zero-Downtime Concurrent Migration Runner

```rust
use sqlx::{PgPool, Error};
use std::time::Duration;
use tokio::time::sleep;

pub struct ConcurrentIndexRunner {
    pool: PgPool,
}

impl ConcurrentIndexRunner {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Executes CREATE INDEX CONCURRENTLY with automated rollback cleanup on failure.
    pub async fn create_index_concurrently(
        &self,
        table_name: &str,
        index_name: &str,
        columns: &str,
    ) -> Result<(), Error> {
        // Step 1: Pre-clean any existing invalid index
        self.drop_invalid_index_if_exists(index_name).await?;

        // Step 2: Obtain dedicated connection outside transaction block
        let mut conn = self.pool.acquire().await?;

        // Step 3: Configure safety timeouts
        sqlx::query("SET lock_timeout = '3000ms'; SET statement_timeout = '0';")
            .execute(&mut *conn)
            .await?;

        let ddl = format!(
            r#"CREATE INDEX CONCURRENTLY IF NOT EXISTS "{}" ON "{}" ({});"#,
            index_name, table_name, columns
        );

        // Step 4: Execute DDL
        match sqlx::query(&ddl).execute(&mut *conn).await {
            Ok(_) => {
                // Step 5: Verify indisvalid = true
                self.assert_index_valid(index_name).await
            }
            Err(e) => {
                eprintln!("[Error] CIC failed for {}: {}. Dropping zombie index...", index_name, e);
                let _ = self.drop_invalid_index_if_exists(index_name).await;
                Err(e)
            }
        }
    }

    async fn drop_invalid_index_if_exists(&self, index_name: &str) -> Result<(), Error> {
        let ddl = format!(r#"DROP INDEX CONCURRENTLY IF EXISTS "{}";"#, index_name);
        sqlx::query(&ddl).execute(&self.pool).await?;
        Ok(())
    }

    async fn assert_index_valid(&self, index_name: &str) -> Result<(), Error> {
        let row: (bool,) = sqlx::query_as(
            r#"
            SELECT i.indisvalid
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            WHERE c.relname = $1;
            "#,
        )
        .bind(index_name)
        .fetch_one(&self.pool)
        .await?;

        if !row.0 {
            let _ = self.drop_invalid_index_if_exists(index_name).await;
            return Err(Error::Protocol(format!(
                "Index {} is marked invalid (indisvalid = false)",
                index_name
            )));
        }
        Ok(())
    }
}
```

---

## 5. Autonomous TypeScript Guard Engine

```typescript
/**
 * AgenticConcurrentIndexGuardEngine
 * Full autonomous sentinel preventing invalid index accumulation,
 * transactional migration failures, and lock convoy catastrophes.
 */
export interface IndexAuditResult {
  invalidIndexes: Array<{
    tableName: string;
    indexName: string;
    indisready: boolean;
    indisvalid: boolean;
    sizeBytes: number;
    wastedWritePenaltyPct: number;
  }>;
  shadowIndexes: Array<{
    shadowName: string;
    parentIndex: string;
    isCcNew: boolean;
  }>;
  blockingTransactions: Array<{
    pid: number;
    durationSeconds: number;
    state: string;
    query: string;
  }>;
  violations: string[];
  remediationDdl: string[];
}

export class AgenticConcurrentIndexGuardEngine {
  constructor(private readonly executor: (query: string, params?: any[]) => Promise<any[]>) {}

  /**
   * Audits the entire PostgreSQL schema for invalid indexes, orphaned shadow
   * indexes (_ccnew/_ccold), and snapshot blocking hazards.
   */
  async auditCluster(): Promise<IndexAuditResult> {
    const violations: string[] = [];
    const remediationDdl: string[] = [];

    // 1. Audit invalid indexes
    const invalidRows = await this.executor(`
      SELECT 
        t.relname AS table_name,
        c.relname AS index_name,
        i.indisready,
        i.indisvalid,
        pg_relation_size(c.oid) AS size_bytes
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_class t ON t.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE i.indisvalid = false
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast');
    `);

    const invalidIndexes = invalidRows.map((r) => {
      violations.push(
        `CRITICAL_INVALID_INDEX: Index "${r.index_name}" on table "${r.table_name}" has indisvalid=false but indisready=${r.indisready}. Wasting disk and degrading write latency.`
      );
      remediationDdl.push(`DROP INDEX CONCURRENTLY IF EXISTS "${r.index_name}";`);
      return {
        tableName: r.table_name,
        indexName: r.index_name,
        indisready: r.indisready,
        indisvalid: r.indisvalid,
        sizeBytes: Number(r.size_bytes),
        wastedWritePenaltyPct: r.indisready ? 25.0 : 0.0,
      };
    });

    // 2. Audit orphaned shadow indexes (_ccnew/_ccold)
    const shadowRows = await this.executor(`
      SELECT c.relname AS shadow_name
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE (c.relname LIKE '%_ccnew%' OR c.relname LIKE '%_ccold%')
        AND c.relkind = 'i'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema');
    `);

    const shadowIndexes = shadowRows.map((r) => {
      const isCcNew = r.shadow_name.includes('_ccnew');
      violations.push(
        `ORPHANED_REINDEX_SHADOW: Found abandoned shadow index "${r.shadow_name}". Subsequent REINDEX CONCURRENTLY will fail with SQLSTATE 42P07.`
      );
      remediationDdl.push(`DROP INDEX CONCURRENTLY IF EXISTS "${r.shadow_name}";`);
      return {
        shadowName: r.shadow_name,
        parentIndex: r.shadow_name.replace(/_cc(new|old).*$/, ''),
        isCcNew,
      };
    });

    // 3. Audit snapshot blocking transactions (> 3 minutes old)
    const blockingRows = await this.executor(`
      SELECT 
        pid,
        EXTRACT(EPOCH FROM (NOW() - xact_start))::int AS duration_sec,
        state,
        LEFT(query, 120) AS query_preview
      FROM pg_stat_activity
      WHERE backend_type = 'client backend'
        AND xact_start < NOW() - INTERVAL '3 minutes'
        AND pid <> pg_backend_pid();
    `);

    const blockingTransactions = blockingRows.map((r) => {
      violations.push(
        `SNAPSHOT_BLOCKER: PID ${r.pid} active for ${r.duration_sec}s in state "${r.state}". Will freeze CREATE INDEX CONCURRENTLY at WaitForOlderSnapshots.`
      );
      return {
        pid: Number(r.pid),
        durationSeconds: Number(r.duration_sec),
        state: r.state,
        query: r.query_preview,
      };
    });

    return {
      invalidIndexes,
      shadowIndexes,
      blockingTransactions,
      violations,
      remediationDdl,
    };
  }

  /**
   * Generates safe migration DDL wrapped in concurrency safeguards.
   */
  generateSafeIndexDdl(tableName: string, indexName: string, columns: string[], unique = false): string {
    const cols = columns.map((c) => `"${c}"`).join(', ');
    const uniqueClause = unique ? 'UNIQUE ' : '';
    return `
-- INVARIANT 1: Execute outside transaction block (transactional: false)
-- INVARIANT 2: Bound lock queue to 3 seconds to eliminate lock convoys
SET lock_timeout = '3000ms';
SET statement_timeout = '0';

-- INVARIANT 3: Pre-clean any aborted invalid index
DROP INDEX CONCURRENTLY IF EXISTS "${indexName}";

-- INVARIANT 4: Build concurrently without write lockout
CREATE ${uniqueClause}INDEX CONCURRENTLY "${indexName}" ON "${tableName}" (${cols});
    `.trim();
  }
}
```

---

## 6. The 6-State Concurrent Index Lifecycle Finite-State Machine (FSM)

```
                       ┌──────────────────────────────────────────────┐
                       │          STATE 0: PRE_FLIGHT_CHECK           │
                       │ Inspect pg_stat_activity for old snapshots.  │
                       │ Clean any lingering _ccnew or _ccold objects.│
                       └──────────────────────┬───────────────────────┘
                                              │ (No blockers, timeouts set)
                                              ▼
                       ┌──────────────────────────────────────────────┐
                       │          STATE 1: CATALOG_INSERTION          │
                       │ Insert into pg_class & pg_index.             │
                       │ indisvalid = false, indisready = false.      │
                       └──────────────────────┬───────────────────────┘
                                              │ (Commit Tx 1)
                                              ▼
                       ┌──────────────────────────────────────────────┐
                       │       STATE 2: WAIT_OLDER_SNAPSHOTS_1        │
                       │ Wait for prior active snapshots to drain.    │
                       │ Failsafe: lock_timeout avoids queue convoys. │
                       └──────────────────────┬───────────────────────┘
                                              │ (Snapshots cleared)
                                              ▼
                       ┌──────────────────────────────────────────────┐
                       │         STATE 3: HEAP_SCAN_BUILD             │
                       │ Full table scan 1; write initial B-tree.     │
                       │ Set indisready = true (writes now dual-write)│
                       └──────────────────────┬───────────────────────┘
                         │                                    │ (Tx 2 commit)
                         │ (Unique collision / timeout)       ▼
                         │                      ┌───────────────────────────────────────┐
                         │                      │    STATE 4: WAIT_OLDER_SNAPSHOTS_2    │
                         │                      │ Wait for transactions active during   │
                         │                      │ scan 1 to finalize.                   │
                         │                      └───────────────────┬───────────────────┘
                         │                                          │ (Snapshots cleared)
                         │                                          ▼
                         │                      ┌───────────────────────────────────────┐
                         │                      │       STATE 5: VALIDATION_SCAN        │
                         │                      │ Table scan 2; catch up missed tuples. │
                         │                      │ Check uniqueness invariant if unique. │
                         │                      └───────────────────┬───────────────────┘
                         │                                          │ (Validated)
                         │                                          ▼
                         │                      ┌───────────────────────────────────────┐
                         │                      │         STATE 6: ACTIVE_VALID         │
                         │                      │ Set indisvalid = true. Commit Tx 3.   │
                         │                      │ Planner now uses index for SELECTs.   │
                         │                      └───────────────────────────────────────┘
                         ▼
        ┌───────────────────────────────────────────────────┐
        │              STATE FAIL: INVALID_ZOMBIE           │
        │ indisvalid = false, indisready = true             │
        │ ACTION: DROP INDEX CONCURRENTLY IF EXISTS         │
        └───────────────────────────────────────────────────┘
```

### FSM State Transition Table

| Current State | Trigger / Event | Next State | Action / Invariant |
| :--- | :--- | :--- | :--- |
| `0. PRE_FLIGHT` | Stale transaction $> 3\text{ min}$ detected | `0. PRE_FLIGHT` | Halt or cancel blocker PID; do not launch CIC. |
| `0. PRE_FLIGHT` | Environment clean, timeouts set | `1. CATALOG_INS` | Acquire `SHARE UPDATE EXCLUSIVE`, insert catalog entries. |
| `1. CATALOG_INS`| Tx 1 commits successfully | `2. WAIT_SNAP_1` | `WaitForOlderSnapshots`; monitor `pg_stat_progress_create_index`. |
| `2. WAIT_SNAP_1`| Snapshot drain timeout $> 10\text{ min}$ | `FAIL: ZOMBIE` | Cancel build; invoke `DROP INDEX CONCURRENTLY`. |
| `2. WAIT_SNAP_1`| Older snapshots drain | `3. HEAP_SCAN` | Scan heap blocks, populate B-Tree; set `indisready = true`. |
| `3. HEAP_SCAN`  | Statement timeout or duplicate key | `FAIL: ZOMBIE` | Catch `23505` or cancel; mark index invalid; trigger cleanup. |
| `3. HEAP_SCAN`  | Scan 1 completes | `4. WAIT_SNAP_2` | `WaitForOlderSnapshots` for active concurrent writers. |
| `4. WAIT_SNAP_2`| Snapshots cleared | `5. VALID_SCAN` | Table scan 2; index newly inserted tuples. |
| `5. VALID_SCAN` | Uniqueness conflict detected | `FAIL: ZOMBIE` | Abort build; report offending duplicate keys. |
| `5. VALID_SCAN` | Verification complete | `6. ACTIVE_VALID`| Set `indisvalid = true`; release memory; verify via CI. |
| `FAIL: ZOMBIE`  | Operator or watchdog trigger | `0. PRE_FLIGHT` | Run `DROP INDEX CONCURRENTLY IF EXISTS <name>;`. |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Every pull request, database migration, or automated agent remediation modifying database indexes must satisfy all 6 Definition of Done gates:

| Gate | Target Metric | Verification Method | Failure Action |
| :--- | :--- | :--- | :--- |
| **Gate 1: Zero Invalid Indexes** | `indisvalid = true` for 100% of indexes | `SELECT count(*) FROM pg_index WHERE indisvalid = false;` returns `0`. | Reject PR / Block deployment until invalid indexes are dropped concurrently. |
| **Gate 2: Non-Transactional Execution** | No transactional wrapping on CIC | Static AST analysis of migration files ensures CIC runs with `transactional: false`. | Migration linter fails build with code `CIC_INSIDE_TX_BLOCK`. |
| **Gate 3: Zero Abandoned Shadow Indexes** | 0 relations matching `%_ccnew%` or `%_ccold%` | `SELECT count(*) FROM pg_class WHERE relname ~ '_cc(new|old)';` returns `0`. | Drop lingering shadow indexes via `DROP INDEX CONCURRENTLY`. |
| **Gate 4: Explicit Lock Timeout Fencing** | `lock_timeout <= 5000ms` | Session environment check confirms `lock_timeout` is configured before DDL execution. | Fail migration runner if un-timed DDL is attempted. |
| **Gate 5: Decoupled Unique Constraints** | Zero direct `ADD CONSTRAINT UNIQUE` on $>1\text{M}$ row tables | Migration linter verifies 2-step `CREATE UNIQUE INDEX CONCURRENTLY` + `USING INDEX`. | Reject single-statement synchronous unique constraint creation. |
| **Gate 6: Safe Drop Hygiene** | 100% `DROP INDEX CONCURRENTLY` | Static analysis verifies no raw `DROP INDEX` without `CONCURRENTLY` exists in migrations. | Flag blocking table lock hazard. |

### CI Automated Verification Script (`verify-index-invariants.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

DB_URL="${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/app_db}"

echo "🔎 Auditing database for invalid and orphaned indexes..."

INVALID_COUNT=$(psql "$DB_URL" -t -A -c "
  SELECT count(*) 
  FROM pg_index i 
  JOIN pg_class c ON c.oid = i.indexrelid 
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE i.indisvalid = false 
    AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast');
")

if [ "$INVALID_COUNT" -gt 0 ]; then
  echo "❌ CRITICAL: Found $INVALID_COUNT invalid indexes (indisvalid = false)!"
  psql "$DB_URL" -c "
    SELECT t.relname AS table_name, c.relname AS index_name, i.indisready, i.indisvalid
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_class t ON t.oid = i.indrelid
    WHERE i.indisvalid = false;
  "
  echo "💡 Remedy: Execute 'DROP INDEX CONCURRENTLY IF EXISTS <index_name>'."
  exit 1
fi

SHADOW_COUNT=$(psql "$DB_URL" -t -A -c "
  SELECT count(*) 
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE (c.relname LIKE '%_ccnew%' OR c.relname LIKE '%_ccold%')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema');
")

if [ "$SHADOW_COUNT" -gt 0 ]; then
  echo "❌ CRITICAL: Found $SHADOW_COUNT abandoned REINDEX CONCURRENTLY shadow indexes!"
  psql "$DB_URL" -c "
    SELECT relname FROM pg_class WHERE relname LIKE '%_ccnew%' OR relname LIKE '%_ccold%';
  "
  exit 1
fi

echo "✅ Index Invariant Verification Passed: 0 invalid indexes, 0 orphaned shadow indexes."
```
