---
description: PostgreSQL Visibility Map (VM / _vm fork), VISIBILITYMAP_ALL_VISIBLE vs VISIBILITYMAP_ALL_FROZEN bits, lazy vs aggressive vacuum page skipping, Index-Only Scan (IOS) heap fetch elimination, pg_visibility corruption detection and repair, VM bit-clearing lock contention (LWLock:visibilitymap), and anti-wraparound freeze horizon optimization across Go (pgx/v5), TypeScript (Kysely, Drizzle), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{vm,visibility,vacuum,freeze,index,scan,storage,database,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/admin/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/storage/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Visibility Map (VM), All-Visible vs All-Frozen Bits, Aggressive Vacuum Freezing, Page Skipping & Index-Only Scan Degradation Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design high-throughput read/write pipelines, index architectures, batch update workers, or database maintenance automation across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `pg`), Python (`SQLAlchemy 2.0`, `asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Index-Only Scan (IOS) Degeneration to Random Heap Fetch Avalanche" (where autonomous agents rely on index-only scans for high-frequency endpoints, but frequent un-batched updates or inserts clear the Visibility Map's `VISIBILITYMAP_ALL_VISIBLE` bits, forcing the executor to perform random I/O heap fetches for every indexed tuple and collapsing query latency from 0.2ms to 3,500ms), the "Aggressive Freeze Vacuum Table-Wide Scan Spasm (Missing `ALL_FROZEN` Bits)" (where autovacuum escalates to an aggressive vacuum because `relfrozenxid` exceeds `vacuum_freeze_table_age`, and because tuples were not frozen during routine runs, the worker cannot skip pages and must sequentially read multi-terabyte tables from disk, pegging NVMe bandwidth and stalling client transactions), the "VM Bit-Clearing Buffer Lock Contention & `XLOG_VM_BITCLEAR` WAL Storm" (where concurrent write bursts on recently vacuumed pages saturate the `LWLock:visibilitymap` lock and generate a flood of bit-clear WAL records), the "Vacuum Freeze Parameter Miscalibration & Anti-Wraparound Emergency Freeze Lockout" (where default `vacuum_freeze_min_age = 50,000,000` leaves millions of pages unfrozen until `autovacuum_freeze_max_age = 200,000,000` forces an emergency unthrottled vacuum that halts normal operations), the "Visibility Map Desynchronization & Silent Phantom/Deleted Tuple Read Anomaly" (where hardware crashes or torn writes leave the VM marking a page as `ALL_VISIBLE` despite containing aborted or dead tuples, causing Index-Only Scans to return phantom or deleted records without touching the heap), and the "End-of-Vacuum Relation Truncation Lock Convoy on the VM Fork" (where `VACUUM` attempts to truncate trailing empty pages and grab an `ACCESS EXCLUSIVE` lock on both heap and `_vm` forks, blocking all concurrent application reads) by establishing a strict 5-Tier Visibility Map & Vacuum Freezing Governance Ladder, mathematical visibility density and skipping theorems, an autonomous TypeScript `AgenticVisibilityMapGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Visibility Map & Vacuum Freezing Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL's storage engine architecture, every relation is partitioned across distinct physical on-disk files called **forks**:
1. **The Main Fork (`main` / `<relfilenode>`)**: Stores raw 8KB heap pages containing physical tuple versions (headers and user data).
2. **The Free Space Map Fork (`fsm` / `<relfilenode>_fsm`)**: Tracks available byte headroom per heap block to optimize row insertion placement.
3. **The Visibility Map Fork (`vm` / `<relfilenode>_vm`)**: An auxiliary bitmap structure containing exactly **2 bits per 8KB heap block**:
   - **Bit 0: `VISIBILITYMAP_ALL_VISIBLE`**: When set, every single tuple on that 8KB heap block is guaranteed to be visible to all current and future transactions. There are no dead tuples, no in-flight uncommitted transactions, and no `xmax` values newer than the cluster's global `OldestXmin`.
   - **Bit 1: `VISIBILITYMAP_ALL_FROZEN`** (introduced in PostgreSQL 9.6): When set, every tuple on that 8KB heap block has been physically frozen (`HEAP_XMIN_FROZEN`). No transaction ID on the page is newer than `FrozenTransactionId` ($2$).
4. **Physical Bit Density**: Because each 8KB heap block requires only 2 bits, 1 byte in the `_vm` fork represents 4 heap blocks ($32\text{ KB}$ of table data). A single 8KB VM page covers $8192 \times 4 = 32,768$ heap blocks, or $256\text{ MB}$ of table data. A 1TB relation requires a mere $4\text{ MB}$ Visibility Map!

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│              POSTGRESQL RELATION FORK & VISIBILITY MAP (VM) ARCHITECTURE               │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Heap Table (Main Fork):                                                                │
│ ┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐           │
│ │ Block 0: All tuples  │  │ Block 1: 1 uncommitted│ │ Block 2: All tuples  │           │
│ │ committed & frozen   │  │ tuple inserted       │  │ visible, not frozen  │           │
│ └──────────┬───────────┘  └──────────┬───────────┘  └──────────┬───────────┘           │
│            │                         │                         │                       │
│            ▼                         ▼                         ▼                       │
│ Visibility Map Fork (_vm):                                                             │
│ ┌────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ Byte 0: [ Bit 1: FROZEN | Bit 0: VISIBLE ] for Block 0, 1, 2, 3                     │ │
│ │                                                                                    │ │
│ │ Block 0: [1, 1] ──► ALL_VISIBLE = 1, ALL_FROZEN = 1  (Skip during ALL vacuums!)    │ │
│ │ Block 1: [0, 0] ──► ALL_VISIBLE = 0, ALL_FROZEN = 0  (Must scan & fetch heap!)     │ │
│ │ Block 2: [0, 1] ──► ALL_VISIBLE = 1, ALL_FROZEN = 0  (IOS skips heap; scan freeze)│ │
│ └────────────────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│           THE INDEX-ONLY SCAN (IOS) DEGENERATION & HEAP FETCH DISASTER                 │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ 1. Autonomous agent builds covering B-Tree index: CREATE INDEX ON users(email, id);    │
│ 2. Agent runs: SELECT email, id FROM users WHERE email = 'alice@example.com';          │
│ 3. B-Tree leaf node contains 'alice@example.com' and TID (Block 1, Offset 3).          │
│ 4. B-Tree does NOT store transaction visibility (xmin / xmax)!                        │
│ 5. Executor checks Visibility Map for Block 1:                                         │
│    - If ALL_VISIBLE == 1: Returns tuple immediately! Heap Fetches: 0 (Latency: 0.1ms)   │
│    - If ALL_VISIBLE == 0: MUST READ HEAP BLOCK 1 FROM DISK! (Heap Fetches: 1)         │
│ 6. Agent executes background heartbeat: UPDATE users SET last_login = now() WHERE ...  │
│ 7. Every UPDATE clears ALL_VISIBLE for that block!                                     │
│ 8. Presumed "Index-Only Scan" now performs 50,000 random I/O reads. Latency: 3,500ms!  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

When autonomous coding agents generate database code, data migrations, or background maintenance scripts, LLMs routinely commit 6 catastrophic Visibility Map & Vacuum Freezing anti-patterns:

```typescript
// ❌ CATASTROPHIC LLM VISIBILITY MAP & VACUUM FREEZING ANTI-PATTERNS

// 1. Ingesting or updating rows without batching or considering VM bit invalidation!
// Every single UPDATE on a row clears the ALL_VISIBLE bit for the entire 8KB page.
// Presumed high-speed Index-Only Scans immediately collapse into random disk I/O!
async function updateUserHeartbeats(db: DatabaseClient, userIds: string[]) {
  for (const id of userIds) {
    // FATAL: Modifies rows scattered across arbitrary pages, invalidating ALL_VISIBLE bits
    // across the entire heap and destroying index-only scan performance for all other queries!
    await db.query(`UPDATE users SET last_seen_at = NOW() WHERE id = $1`, [id]);
  }
}

// 2. Setting vacuum_freeze_min_age to default or huge values on high-write relations!
// If vacuum_freeze_min_age = 50,000,000, normal autovacuum marks pages ALL_VISIBLE,
// but leaves ALL_FROZEN = 0 because tuples are "too young".
// When vacuum_freeze_table_age (150M) triggers an aggressive vacuum, it CANNOT skip ANY page!
// Result: Autovacuum reads the entire 2TB table from disk in a single frantic burst.
async function applyBadVacuumConfig(db: DatabaseClient) {
  // FATAL: Leaves pages unfrozen for 50M transactions!
  await db.query(`ALTER TABLE audit_events SET (autovacuum_freeze_min_age = 50000000);`);
}
```

---

## 2. Mathematical Formalisms & Storage Engine Physics

### 2.1 The Visibility Map Space Density & Cache Efficiency Theorem

Let $N_{\text{blocks}}$ be the number of physical 8KB heap blocks in a table. Each heap block requires $b = 2$ bits in the VM fork.
The total physical byte size of the Visibility Map fork $S_{\text{VM}}$ is governed by:

$$S_{\text{VM}} = \left\lceil \frac{N_{\text{blocks}} \times 2}{8} \right\rceil = \left\lceil \frac{N_{\text{blocks}}}{4} \right\rceil \text{ bytes}$$

Because each 8KB VM page contains $P_{\text{VM}} = 8192 \text{ bytes} = 65,536 \text{ bits}$, the number of heap blocks mapped by a single VM page is:

$$B_{\text{per\_vm\_page}} = \frac{65,536 \text{ bits}}{2 \text{ bits/block}} = 32,768 \text{ heap blocks} = 268,435,456 \text{ bytes} = 256 \text{ MB}$$

**Theorem 1 (VM Cache Invariance)**: The ratio of Visibility Map memory footprint to Heap Table memory footprint is strictly constant:

$$\frac{S_{\text{VM}}}{S_{\text{Heap}}} = \frac{0.25 \text{ bytes}}{8192 \text{ bytes}} = \frac{1}{32,768} \approx 0.00305\%$$

*Consequence*: Because the VM is $32,768\times$ smaller than the heap, keeping the entire VM in `shared_buffers` or OS page cache consumes negligible RAM. Checking VM bits during an Index-Only Scan costs $O(1)$ memory lookup, completely bypassing heap I/O if `VISIBILITYMAP_ALL_VISIBLE` is set.

---

### 2.2 The Index-Only Scan (IOS) Heap Fetch Degradation Model

Let $Q$ be an Index-Only Scan query returning $K$ tuples. Let $p_{\text{vis}} \in [0, 1]$ represent the proportion of candidate heap blocks marked `VISIBILITYMAP_ALL_VISIBLE`.
The expected number of random physical heap page fetches $\mathbb{E}[N_{\text{fetch}}]$ is given by:

$$\mathbb{E}[N_{\text{fetch}}] = K \times (1 - p_{\text{vis}})$$

Let $t_{\text{idx}}$ be the time to traverse the B-Tree index leaf page ($\approx 0.05\text{ms}$ in memory), and $t_{\text{heap}}$ be the random I/O read latency of an uncached heap page ($\approx 0.1\text{ms}$ NVMe, or $4.0\text{ms}$ EBS block storage). The total execution latency $T_{\text{IOS}}$ is:

$$T_{\text{IOS}} = K \times t_{\text{idx}} + K \times (1 - p_{\text{vis}}) \times t_{\text{heap}}$$

When $p_{\text{vis}} = 1.0$ (perfect Visibility Map):

$$T_{\text{IOS}}(1.0) = K \times 0.05\text{ms}$$

When $p_{\text{vis}} = 0.0$ (completely invalidated Visibility Map):

$$T_{\text{IOS}}(0.0) = K \times (0.05 + 4.0)\text{ms} = 4.05 \times K \text{ ms}$$

The latency degradation factor $\Lambda_{\text{IOS}}$ is:

$$\Lambda_{\text{IOS}} = \frac{T_{\text{IOS}}(0.0)}{T_{\text{IOS}}(1.0)} = \frac{0.05 + 4.0}{0.05} = 81\times$$

A mere $5\%$ un-vacuumed page invalidation ($p_{\text{vis}} = 0.95$) increases query latency by $400\%$ on cloud storage!

---

### 2.3 The Aggressive Vacuum Page-Skipping Conservation Law

PostgreSQL executes two distinct categories of autovacuum cycles:
1. **Lazy Autovacuum**: Triggered by `autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * n_live_tup`. Skips all pages marked `VISIBILITYMAP_ALL_VISIBLE`.
2. **Aggressive (Anti-Wraparound) Autovacuum**: Triggered when `age(relfrozenxid) >= vacuum_freeze_table_age` (or `autovacuum_freeze_max_age`). **CANNOT skip `ALL_VISIBLE` pages!** Can **ONLY** skip pages marked `VISIBILITYMAP_ALL_FROZEN`.

Let $B_{\text{total}}$ be the total heap blocks in relation $R$. Let $f_{\text{frozen}} \in [0, 1]$ be the fraction of blocks marked `VISIBILITYMAP_ALL_FROZEN`.
The physical disk read volume during an aggressive vacuum $V_{\text{aggressive}}$ is:

$$V_{\text{aggressive}} = B_{\text{total}} \times (1 - f_{\text{frozen}}) \times 8\text{ KB}$$

If proactive freezing is ignored, $f_{\text{frozen}} \to 0$, forcing autovacuum to read $100\%$ of table blocks:

$$V_{\text{aggressive}} = B_{\text{total}} \times 8\text{ KB} = \text{Table Size}$$

For a 2TB table, this forces $2\text{ TB}$ of sequential read I/O through `shared_buffers`, burning NVMe bandwidth and monopolizing the autovacuum worker pool for hours.
Conversely, if $f_{\text{frozen}} \ge 0.95$, the read volume collapses to:

$$V_{\text{aggressive}} \le 2\text{ TB} \times 0.05 = 100\text{ GB} \quad (95\%\text{ I/O reduction})$$

---

### 2.4 The VM Bit-Clearing WAL Amplification Model

When a transaction modifies block $B$ (via `INSERT`, `UPDATE`, or `DELETE`), the backend inspects the VM:
If `ALL_VISIBLE` or `ALL_FROZEN` is set:
1. Backend acquires `LWLock:visibilitymap` buffer lock in exclusive mode.
2. Clears the bits in shared memory.
3. Emits an `XLOG_VM_BITCLEAR` record to the WAL stream ($\approx 48\text{ bytes}$).
4. Releases the VM buffer lock.

Let $\lambda_{\text{write}}$ be the row write rate per second. Let $P_{\text{dirty}}$ be the probability that a write hits a page whose VM bits are currently set. The additional WAL bandwidth $\Delta \text{WAL}_{\text{VM}}$ generated by VM bit-clearing is:

$$\Delta \text{WAL}_{\text{VM}} = \lambda_{\text{write}} \times P_{\text{dirty}} \times 48 \text{ bytes/sec}$$

Under burst writes immediately following a full `VACUUM`, $P_{\text{dirty}} \approx 1.0$, introducing instantaneous contention on the single VM buffer holding the range of blocks.

---

## 3. The 5-Tier Visibility Map & Vacuum Freezing Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             THE 5-TIER VISIBILITY MAP & VACUUM FREEZING GOVERNANCE LADDER              │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Machine-Verifiable DoD CI Gates (Assert Heap Fetches == 0 & Zero VM Corruption)│
│   ▲                                                                                    │
│ Tier 3: Isolated Write Partitioning & Vacuum Truncation Fencing (vacuum_truncate=off)  │
│   ▲                                                                                    │
│ Tier 2: Real-Time Observability & pg_visibility Telemetry Sentinels                    │
│   ▲                                                                                    │
│ Tier 1: Proactive Freeze Age Calibration (vacuum_freeze_min_age = 10,000,000)          │
│   ▲                                                                                    │
│ Tier 0: Index-Only Scan Satiation & Visibility Map Preservation (fillfactor + HOT)     │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### Tier 0: Index-Only Scan Satiation & Visibility Map Preservation
- **HOT Update Preservation**: To prevent row updates from invalidating the Visibility Map, tune table `fillfactor = 80-85` on update-heavy tables. In-place Heap-Only Tuple (HOT) updates modify the existing page without creating new index entries. However, **any** update on a page clears `ALL_VISIBLE`!
- **Column Vertical Partitioning**: Separate mutable columns (e.g. `last_login`, `heartbeat_at`, `view_count`) from immutable columns (e.g. `email`, `created_at`, `user_id`) into separate tables. This keeps the primary lookup relation $100\%$ static, maintaining `VISIBILITYMAP_ALL_VISIBLE = 1` indefinitely.
- **Index-Only Scan Verification**: Require all covering indexes to be verified via `EXPLAIN (ANALYZE, BUFFERS)` asserting:
  ```sql
  -- ✅ PRODUCTION VERIFICATION: INDEX-ONLY SCAN WITH ZERO HEAP FETCHES
  EXPLAIN (ANALYZE, BUFFERS)
  SELECT id, email FROM users WHERE email = 'test@example.com';
  -- Plan MUST output:
  -- ->  Index Only Scan using idx_users_email_id on users
  --       Heap Fetches: 0
  ```

### Tier 1: Proactive Freeze Age Calibration
- Never leave default `vacuum_freeze_min_age = 50,000,000` on high-churn relations. Default settings leave rows unfrozen for months, setting only `ALL_VISIBLE` but leaving `ALL_FROZEN = 0`.
- Lower `vacuum_freeze_min_age` to `10,000,000` (or `5,000,000` on high-TPS systems). This causes routine autovacuum passes to freeze tuples early and stamp `VISIBILITYMAP_ALL_FROZEN = 1` on cold pages.
- Calibrate `vacuum_freeze_table_age = 50,000,000` (down from default 150M) to trigger aggressive freeze sweeps while the unfrozen delta is small and fast to process.

```sql
-- ✅ PRODUCTION INVARIANT: PROACTIVE TABLE-LEVEL FREEZE TUNING
ALTER TABLE orders SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_threshold = 1000,
  autovacuum_freeze_min_age = 10000000,
  autovacuum_freeze_table_age = 50000000
);
```

### Tier 2: Real-Time Observability & pg_visibility Telemetry Sentinels
- Deploy the official PostgreSQL `pg_visibility` extension.
- Continuously monitor the percentage of `all_visible` and `all_frozen` pages using `pg_visibility_map_summary`:
  ```sql
  -- ✅ REAL-TIME VISIBILITY MAP SUMMARY SENTINEL
  SELECT 
    c.relname,
    v.all_visible,
    v.all_frozen,
    c.relpages AS total_heap_pages,
    ROUND(100.0 * v.all_visible / NULLIF(c.relpages, 0), 2) AS all_visible_pct,
    ROUND(100.0 * v.all_frozen / NULLIF(c.relpages, 0), 2) AS all_frozen_pct
  FROM pg_class c
  JOIN LATERAL pg_visibility_map_summary(c.oid) v ON true
  WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace
    AND c.relpages > 1000;
  ```
- Continuously audit for VM bit corruption (`pg_check_visible` and `pg_check_frozen`).

### Tier 3: Isolated Write Partitioning & Vacuum Truncation Fencing
- **Vacuum Truncation Fencing**: At the conclusion of vacuuming, PostgreSQL attempts to lock the relation with `ACCESS EXCLUSIVE` to truncate trailing empty pages from disk, locking both heap and `_vm` forks. If high-concurrency client reads are active, this triggers severe lock convoys.
- On mission-critical OLTP relations, disable vacuum truncation:
  ```sql
  -- ✅ PREVENT END-OF-VACUUM ACCESS EXCLUSIVE LOCK CONVOYS
  ALTER TABLE users SET (vacuum_truncate = false);
  ```
- **Declarative Partitioning**: Partition historical data by range (e.g., `PARTITION BY RANGE (created_at)`). Once a partition is closed (e.g. `orders_2024_10`), execute `VACUUM (FREEZE, ANALYZE)` once. Its `_vm` fork will achieve $100\%$ `ALL_FROZEN` and never be scanned again!

### Tier 4: Machine-Verifiable CI Gates & Zero-Heap-Fetch Verification
- Enforce CI regression tests that run queries with `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.
- Assert `Heap Fetches == 0` for all mission-critical queries designed to use Index-Only Scans.
- Assert zero corrupt pages in `pg_visibility`.

---

## 4. Production Code Implementations

### 4.1 Go (`jackc/pgx/v5`): Proactive VM Health Sentinel & IOS Guard

```go
package storage

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TableVisibilitySummary contains VM coverage metrics
type TableVisibilitySummary struct {
	TableName      string  `json:"table_name"`
	TotalPages     int64   `json:"total_pages"`
	AllVisiblePages int64  `json:"all_visible_pages"`
	AllFrozenPages int64   `json:"all_frozen_pages"`
	AllVisiblePct  float64 `json:"all_visible_pct"`
	AllFrozenPct   float64 `json:"all_frozen_pct"`
}

// PlanNode represents a simplified EXPLAIN JSON plan node
type PlanNode struct {
	NodeType    string     `json:"Node Type"`
	IndexName   string     `json:"Index Name,omitempty"`
	HeapFetches *int64     `json:"Heap Fetches,omitempty"`
	Plans       []PlanNode `json:"Plans,omitempty"`
}

// ExplainOutput represents the root EXPLAIN output
type ExplainOutput struct {
	Plan PlanNode `json:"Plan"`
}

// VisibilityMapGuard provides autonomous VM telemetry and IOS validation
type VisibilityMapGuard struct {
	pool *pgxpool.Pool
}

func NewVisibilityMapGuard(pool *pgxpool.Pool) *VisibilityMapGuard {
	return &VisibilityMapGuard{pool: pool}
}

// GetTableVisibility inspects the VM fork using pg_visibility_map_summary
func (g *VisibilityMapGuard) GetTableVisibility(ctx context.Context, tableName string) (*TableVisibilitySummary, error) {
	query := `
		SELECT 
			c.relname,
			c.relpages,
			v.all_visible,
			v.all_frozen,
			COALESCE(ROUND(100.0 * v.all_visible / NULLIF(c.relpages, 0), 2), 0.0),
			COALESCE(ROUND(100.0 * v.all_frozen / NULLIF(c.relpages, 0), 2), 0.0)
		FROM pg_class c
		JOIN LATERAL pg_visibility_map_summary(c.oid) v ON true
		WHERE c.relname = $1 AND c.relnamespace = 'public'::regnamespace;
	`
	row := g.pool.QueryRow(ctx, query, tableName)
	var summary TableVisibilitySummary
	err := row.Scan(
		&summary.TableName,
		&summary.TotalPages,
		&summary.AllVisiblePages,
		&summary.AllFrozenPages,
		&summary.AllVisiblePct,
		&summary.AllFrozenPct,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to scan VM summary for %s: %w", tableName, err)
	}
	return &summary, nil
}

// AssertIndexOnlyScan verifies that an execution plan performs zero heap fetches
func (g *VisibilityMapGuard) AssertIndexOnlyScan(ctx context.Context, sqlQuery string, args ...any) error {
	explainQuery := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s", sqlQuery)
	var rawJSON []byte
	err := g.pool.QueryRow(ctx, explainQuery, args...).Scan(&rawJSON)
	if err != nil {
		return fmt.Errorf("failed to execute explain analyze: %w", err)
	}

	var explanations []ExplainOutput
	if err := json.Unmarshal(rawJSON, &explanations); err != nil {
		return fmt.Errorf("failed to unmarshal explain JSON: %w", err)
	}

	if len(explanations) == 0 {
		return fmt.Errorf("empty explain plan returned")
	}

	var totalHeapFetches int64
	var foundIOS bool
	var walk func(node *PlanNode)
	walk = func(node *PlanNode) {
		if node.NodeType == "Index Only Scan" {
			foundIOS = true
			if node.HeapFetches != nil {
				totalHeapFetches += *node.HeapFetches
			}
		}
		for i := range node.Plans {
			walk(&node.Plans[i])
		}
	}
	walk(&explanations[0].Plan)

	if !foundIOS {
		return fmt.Errorf("query did NOT use an Index-Only Scan (Node Type: %s)", explanations[0].Plan.NodeType)
	}
	if totalHeapFetches > 0 {
		return fmt.Errorf("index-only scan degraded: encountered %d heap fetches (visibility map invalidation)", totalHeapFetches)
	}

	return nil
}

// ProactiveFreeze performs a bounded VACUUM (FREEZE) if all_frozen_pct is below target
func (g *VisibilityMapGuard) ProactiveFreeze(ctx context.Context, tableName string, targetFrozenPct float64) error {
	summary, err := g.GetTableVisibility(ctx, tableName)
	if err != nil {
		return err
	}
	if summary.AllFrozenPct >= targetFrozenPct {
		return nil // Table is already sufficiently frozen
	}

	// Execute vacuum freeze safely
	vacuumSQL := fmt.Sprintf("VACUUM (FREEZE, ANALYZE) %s;", tableName)
	ctxTimeout, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()

	_, err = g.pool.Exec(ctxTimeout, vacuumSQL)
	if err != nil {
		return fmt.Errorf("proactive vacuum freeze failed for %s: %w", tableName, err)
	}
	return nil
}
```

---

### 4.2 TypeScript (`Kysely` / `pg`): VM Telemetry & Heap Fetch Assertion

```typescript
import { Kysely, sql } from 'kysely';

export interface VisibilityMapSummary {
  tableName: string;
  totalPages: number;
  allVisiblePages: number;
  allFrozenPages: number;
  allVisiblePct: number;
  allFrozenPct: number;
}

export class AgenticVisibilityMapGuard {
  constructor(private readonly db: Kysely<any>) {}

  /**
   * Retrieves real-time Visibility Map coverage for a relation.
   */
  async getTableVisibility(tableName: string): Promise<VisibilityMapSummary> {
    const result = await sql<VisibilityMapSummary>`
      SELECT 
        c.relname AS "tableName",
        c.relpages::bigint AS "totalPages",
        v.all_visible::bigint AS "allVisiblePages",
        v.all_frozen::bigint AS "allFrozenPages",
        COALESCE(ROUND((100.0 * v.all_visible / NULLIF(c.relpages, 0))::numeric, 2), 0.0)::float AS "allVisiblePct",
        COALESCE(ROUND((100.0 * v.all_frozen / NULLIF(c.relpages, 0))::numeric, 2), 0.0)::float AS "allFrozenPct"
      FROM pg_class c
      JOIN LATERAL pg_visibility_map_summary(c.oid) v ON true
      WHERE c.relname = ${tableName} 
        AND c.relnamespace = 'public'::regnamespace;
    `.execute(this.db);

    if (result.rows.length === 0) {
      throw new Error(`Relation ${tableName} not found in public schema`);
    }

    return result.rows[0];
  }

  /**
   * Validates that an executed query plan utilizes an Index-Only Scan with ZERO Heap Fetches.
   */
  async assertIndexOnlyScanFidelity(querySql: string, params: unknown[] = []): Promise<void> {
    const explainQuery = `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${querySql}`;
    const result = await this.db.executeQuery<any>({
      sql: explainQuery,
      parameters: params,
      query: { kind: 'RawQueryNode' } as any
    });

    const rootPlan = result.rows[0]?.['QUERY PLAN']?.[0]?.Plan;
    if (!rootPlan) {
      throw new Error('Unable to extract query plan from EXPLAIN output');
    }

    let foundIOS = false;
    let heapFetches = 0;

    const traverse = (node: any) => {
      if (node['Node Type'] === 'Index Only Scan') {
        foundIOS = true;
        heapFetches += Number(node['Heap Fetches'] ?? 0);
      }
      if (Array.isArray(node.Plans)) {
        for (const child of node.Plans) {
          traverse(child);
        }
      }
    };

    traverse(rootPlan);

    if (!foundIOS) {
      throw new Error(`Query failed to use Index-Only Scan. Plan root: ${rootPlan['Node Type']}`);
    }

    if (heapFetches > 0) {
      throw new Error(
        `Index-Only Scan degraded: detected ${heapFetches} heap fetches. Visibility map requires VACUUM.`
      );
    }
  }

  /**
   * Checks for Visibility Map data corruption using pg_visibility.
   */
  async verifyVMIntegrity(tableName: string): Promise<{ corruptBlocks: number[] }> {
    const checkResult = await sql<{ blkno: number }>`
      SELECT blkno FROM pg_check_visible(${tableName}::regclass) LIMIT 100;
    `.execute(this.db);

    return {
      corruptBlocks: checkResult.rows.map(r => Number(r.blkno))
    };
  }
}
```

---

### 4.3 Python (`asyncpg`): Visibility Map Integrity & Freezing Watchdog

```python
import json
import logging
from typing import Dict, Any, List
import asyncpg

logger = logging.getLogger("visibility_guard")

class AsyncVisibilityMapGuard:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def get_visibility_summary(self, table_name: str) -> Dict[str, Any]:
        """Fetches VM summary metrics for a given table."""
        query = """
            SELECT 
                c.relname AS table_name,
                c.relpages::bigint AS total_pages,
                v.all_visible::bigint AS all_visible_pages,
                v.all_frozen::bigint AS all_frozen_pages,
                COALESCE(ROUND((100.0 * v.all_visible / NULLIF(c.relpages, 0))::numeric, 2), 0.0)::float AS all_visible_pct,
                COALESCE(ROUND((100.0 * v.all_frozen / NULLIF(c.relpages, 0))::numeric, 2), 0.0)::float AS all_frozen_pct
            FROM pg_class c
            JOIN LATERAL pg_visibility_map_summary(c.oid) v ON true
            WHERE c.relname = $1 AND c.relnamespace = 'public'::regnamespace;
        """
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(query, table_name)
            if not row:
                raise ValueError(f"Relation {table_name} not found")
            return dict(row)

    async def assert_zero_heap_fetches(self, sql_query: str, *args) -> None:
        """Asserts that query executes as an Index-Only Scan with 0 heap fetches."""
        explain_sql = f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql_query}"
        async with self.pool.acquire() as conn:
            raw = await conn.fetchval(explain_sql, *args)
            plan_data = json.loads(raw)[0]["Plan"]

        heap_fetches = 0
        found_ios = False

        def traverse(node: Dict[str, Any]):
            nonlocal heap_fetches, found_ios
            if node.get("Node Type") == "Index Only Scan":
                found_ios = True
                heap_fetches += node.get("Heap Fetches", 0)
            for child in node.get("Plans", []):
                traverse(child)

        traverse(plan_data)

        if not found_ios:
            raise RuntimeError(f"Query plan did not use Index Only Scan: {plan_data.get('Node Type')}")
        if heap_fetches > 0:
            raise RuntimeError(f"Index-Only Scan degraded: {heap_fetches} heap fetches detected")

    async def check_corruption(self, table_name: str) -> List[int]:
        """Audits table for VM corruption via pg_check_visible."""
        query = "SELECT blkno FROM pg_check_visible($1::regclass) LIMIT 100;"
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query, table_name)
            return [int(r["blkno"]) for r in rows]
```

---

### 4.4 Rust (`sqlx`): High-Performance VM Telemetry & Scan Analyzer

```rust
use sqlx::PgPool;
use serde::Deserialize;

#[derive(Debug, sqlx::FromRow)]
pub struct VisibilitySummary {
    pub table_name: String,
    pub total_pages: i64,
    pub all_visible_pages: i64,
    pub all_frozen_pages: i64,
    pub all_visible_pct: f64,
    pub all_frozen_pct: f64,
}

#[derive(Debug, Deserialize)]
struct PlanNode {
    #[serde(rename = "Node Type")]
    node_type: String,
    #[serde(rename = "Heap Fetches")]
    heap_fetches: Option<i64>,
    #[serde(default)]
    plans: Vec<PlanNode>,
}

#[derive(Debug, Deserialize)]
struct ExplainWrapper {
    #[serde(rename = "Plan")]
    plan: PlanNode,
}

pub struct VisibilityGuard {
    pool: PgPool,
}

impl VisibilityGuard {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn get_visibility_summary(&self, table_name: &str) -> Result<VisibilitySummary, sqlx::Error> {
        let query = r#"
            SELECT 
                c.relname AS table_name,
                c.relpages::bigint AS total_pages,
                v.all_visible::bigint AS all_visible_pages,
                v.all_frozen::bigint AS all_frozen_pages,
                COALESCE(ROUND((100.0 * v.all_visible / NULLIF(c.relpages, 0))::numeric, 2), 0.0)::float8 AS all_visible_pct,
                COALESCE(ROUND((100.0 * v.all_frozen / NULLIF(c.relpages, 0))::numeric, 2), 0.0)::float8 AS all_frozen_pct
            FROM pg_class c
            JOIN LATERAL pg_visibility_map_summary(c.oid) v ON true
            WHERE c.relname = $1 AND c.relnamespace = 'public'::regnamespace;
        "#;

        sqlx::query_as::<_, VisibilitySummary>(query)
            .bind(table_name)
            .fetch_one(&self.pool)
            .await
    }

    pub async fn assert_index_only_scan(&self, query_sql: &str) -> Result<(), Box<dyn std::error::Error>> {
        let explain_sql = format!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {}", query_sql);
        let row: (serde_json::Value,) = sqlx::query_as(&explain_sql)
            .fetch_one(&self.pool)
            .await?;

        let wrappers: Vec<ExplainWrapper> = serde_json::from_value(row.0)?;
        let root = wrappers.first().ok_or("Empty plan returned")?;

        let mut found_ios = false;
        let mut total_fetches = 0;

        fn walk(node: &PlanNode, found_ios: &mut bool, total_fetches: &mut i64) {
            if node.node_type == "Index Only Scan" {
                *found_ios = true;
                if let Some(fetches) = node.heap_fetches {
                    *total_fetches += fetches;
                }
            }
            for child in &node.plans {
                walk(child, found_ios, total_fetches);
            }
        }

        walk(&root.plan, &mut found_ios, &mut total_fetches);

        if !found_ios {
            return Err(format!("Query did not execute as Index-Only Scan: {}", root.plan.node_type).into());
        }
        if total_fetches > 0 {
            return Err(format!("Index-Only Scan degraded: {} heap fetches detected", total_fetches).into());
        }

        Ok(())
    }
}
```

---

## 5. Autonomous TypeScript Guard Engine

```typescript
/**
 * AgenticVisibilityMapGuardEngine
 * Production-grade runtime guard providing telemetry, IOS degradation detection,
 * VM corruption auditing, and proactive vacuum freeze orchestration.
 */
export interface VMTableMetrics {
  tableName: string;
  totalPages: number;
  allVisiblePages: number;
  allFrozenPages: number;
  allVisiblePct: number;
  allFrozenPct: number;
  oldestXidAge: number;
}

export interface IOSAuditResult {
  isIndexOnlyScan: boolean;
  heapFetches: number;
  sharedHitBlocks: number;
  sharedReadBlocks: number;
  executionTimeMs: number;
  fidelityStatus: 'OPTIMAL' | 'DEGRADED' | 'INVALID';
}

export interface VMIntegrityReport {
  tableName: string;
  isClean: boolean;
  corruptVisibleBlocks: number[];
  corruptFrozenBlocks: number[];
}

export class AgenticVisibilityMapGuardEngine {
  constructor(private readonly queryRunner: (sql: string, params?: any[]) => Promise<any[]>) {}

  /**
   * Collects detailed Visibility Map & Freezing metrics for a table.
   */
  async auditTableVisibility(tableName: string): Promise<VMTableMetrics> {
    const sql = `
      SELECT 
        c.relname AS table_name,
        c.relpages::bigint AS total_pages,
        v.all_visible::bigint AS all_visible_pages,
        v.all_frozen::bigint AS all_frozen_pages,
        COALESCE(ROUND((100.0 * v.all_visible / NULLIF(c.relpages, 0))::numeric, 2), 0.0)::float AS all_visible_pct,
        COALESCE(ROUND((100.0 * v.all_frozen / NULLIF(c.relpages, 0))::numeric, 2), 0.0)::float AS all_frozen_pct,
        age(c.relfrozenxid)::bigint AS oldest_xid_age
      FROM pg_class c
      JOIN LATERAL pg_visibility_map_summary(c.oid) v ON true
      WHERE c.relname = $1 AND c.relnamespace = 'public'::regnamespace;
    `;
    const rows = await this.queryRunner(sql, [tableName]);
    if (rows.length === 0) {
      throw new Error(`Table ${tableName} not found in public schema`);
    }
    const r = rows[0];
    return {
      tableName: r.table_name,
      totalPages: Number(r.total_pages),
      allVisiblePages: Number(r.all_visible_pages),
      allFrozenPages: Number(r.all_frozen_pages),
      allVisiblePct: Number(r.all_visible_pct),
      allFrozenPct: Number(r.all_frozen_pct),
      oldestXidAge: Number(r.oldest_xid_age),
    };
  }

  /**
   * Asserts query plan fidelity: requires Index-Only Scan and zero heap fetches.
   */
  async evaluateQueryIOSFidelity(query: string, params: any[] = []): Promise<IOSAuditResult> {
    const explainSql = `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${query}`;
    const result = await this.queryRunner(explainSql, params);
    const planWrapper = result[0]?.['QUERY PLAN']?.[0];
    if (!planWrapper) {
      throw new Error('Unable to parse EXPLAIN output');
    }

    const plan = planWrapper.Plan;
    const executionTime = Number(planWrapper['Execution Time'] ?? 0);

    let isIOS = false;
    let heapFetches = 0;
    let sharedHit = 0;
    let sharedRead = 0;

    const inspectNode = (node: any) => {
      if (node['Node Type'] === 'Index Only Scan') {
        isIOS = true;
        heapFetches += Number(node['Heap Fetches'] ?? 0);
      }
      sharedHit += Number(node['Shared Hit Blocks'] ?? 0);
      sharedRead += Number(node['Shared Read Blocks'] ?? 0);

      if (Array.isArray(node.Plans)) {
        for (const child of node.Plans) {
          inspectNode(child);
        }
      }
    };

    inspectNode(plan);

    let status: 'OPTIMAL' | 'DEGRADED' | 'INVALID' = 'INVALID';
    if (isIOS) {
      status = heapFetches === 0 ? 'OPTIMAL' : 'DEGRADED';
    }

    return {
      isIndexOnlyScan: isIOS,
      heapFetches,
      sharedHitBlocks: sharedHit,
      sharedReadBlocks: sharedRead,
      executionTimeMs: executionTime,
      fidelityStatus: status,
    };
  }

  /**
   * Verifies absence of corrupt VM bits using pg_visibility.
   */
  async verifyIntegrity(tableName: string): Promise<VMIntegrityReport> {
    const visibleCheckSql = `SELECT blkno FROM pg_check_visible($1::regclass) LIMIT 100;`;
    const frozenCheckSql = `SELECT blkno FROM pg_check_frozen($1::regclass) LIMIT 100;`;

    const [visibleRows, frozenRows] = await Promise.all([
      this.queryRunner(visibleCheckSql, [tableName]),
      this.queryRunner(frozenCheckSql, [tableName]),
    ]);

    const corruptVisible = visibleRows.map((r: any) => Number(r.blkno));
    const corruptFrozen = frozenRows.map((r: any) => Number(r.blkno));

    return {
      tableName,
      isClean: corruptVisible.length === 0 && corruptFrozen.length === 0,
      corruptVisibleBlocks: corruptVisible,
      corruptFrozenBlocks: corruptFrozen,
    };
  }

  /**
   * Triggers an online proactive freeze cycle if frozen percentage is below threshold.
   */
  async ensureProactiveFreezing(tableName: string, minFrozenPct = 80.0): Promise<boolean> {
    const metrics = await this.auditTableVisibility(tableName);
    if (metrics.allFrozenPct >= minFrozenPct) {
      return false; // Freezing target satisfied
    }

    // Set lock timeout to avoid blocking active client queries
    await this.queryRunner(`SET LOCAL lock_timeout = '2000ms';`);
    await this.queryRunner(`VACUUM (FREEZE, ANALYZE) ${tableName};`);
    return true;
  }
}
```

---

## 6. The 6-State Visibility Map & Vacuum Lifecycle Finite-State Machine (FSM)

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             THE 6-STATE VISIBILITY MAP & HEAP BLOCK LIFECYCLE FSM                      │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│     [S0: PAGE_INITIALIZED] ──(Tuple Insert/Commit)──► [S1: ALL_VISIBLE]                │
│             │                                                  │                       │
│             │ (Tuple Modified / Deleted)                       │ (Age >= FreezeMinAge) │
│             ▼                                                  ▼                       │
│     [S3: BITS_CLEARED] ◄────(Tuple Update/Delete)────── [S2: ALL_FROZEN]               │
│             │                                                  ▲                       │
│             │ (Autovacuum runs)                                │                       │
│             ▼                                                  │                       │
│     [S4: LAZY_VACUUMED] ───(Aggressive Freeze Vacuum)──────────┘                       │
│                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

| Current State | Event / Action | Guard Condition | Target State | VM Bits (`[Frozen, Visible]`) |
|---|---|---|---|---|
| **S0: PAGE_INITIALIZED** | Backend inserts tuples & commits | All tuples committed before `OldestXmin` | **S1: ALL_VISIBLE** | `01` |
| **S1: ALL_VISIBLE** | `VACUUM` processes page | All tuple XIDs `< FreezeLimit` | **S2: ALL_FROZEN** | `11` |
| **S1: ALL_VISIBLE** | Backend executes `UPDATE` / `DELETE` | Target block touched | **S3: BITS_CLEARED** | `00` (WAL `XLOG_VM_BITCLEAR`) |
| **S2: ALL_FROZEN** | Backend executes `UPDATE` / `DELETE` | Target block modified | **S3: BITS_CLEARED** | `00` (WAL `XLOG_VM_BITCLEAR`) |
| **S3: BITS_CLEARED** | Standard Autovacuum runs | Dead tuples purged, living tuples visible | **S4: LAZY_VACUUMED** | `01` |
| **S4: LAZY_VACUUMED** | Aggressive Vacuum runs | `age(relfrozenxid) >= freeze_table_age` | **S2: ALL_FROZEN** | `11` |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

```bash
#!/usr/bin/env bash
# ==============================================================================
# agentic-visibility-map-ci-gate.sh
# Production machine-verifiable verification gate for PostgreSQL Visibility Maps
# ==============================================================================
set -euo pipefail

DB_URL="${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/postgres}"
export PGCONNECT_TIMEOUT=5

echo "=== [Gate 1/5] Verifying pg_visibility Extension Availability ==="
psql "${DB_URL}" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_visibility;"

echo "=== [Gate 2/5] Auditing Visibility Map Corruption via pg_check_visible ==="
CORRUPT_BLOCKS=$(psql "${DB_URL}" -At -c "
  SELECT count(*) FROM (
    SELECT c.relname, chk.blkno 
    FROM pg_class c
    JOIN LATERAL pg_check_visible(c.oid) chk ON true
    WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace
    LIMIT 10
  ) corrupt;
")

if [ "${CORRUPT_BLOCKS}" -gt 0 ]; then
  echo "❌ CRITICAL: Detected ${CORRUPT_BLOCKS} corrupt blocks in Visibility Map!"
  exit 1
fi
echo "✅ Zero corrupt Visibility Map blocks detected."

echo "=== [Gate 3/5] Verifying High-Frequency Table Visibility Map Coverage ==="
LOW_VISIBILITY_TABLES=$(psql "${DB_URL}" -At -c "
  SELECT count(*)
  FROM pg_class c
  JOIN LATERAL pg_visibility_map_summary(c.oid) v ON true
  WHERE c.relkind = 'r' 
    AND c.relnamespace = 'public'::regnamespace
    AND c.relpages > 500
    AND (100.0 * v.all_visible / c.relpages) < 85.0;
")

if [ "${LOW_VISIBILITY_TABLES}" -gt 0 ]; then
  echo "⚠️ WARNING: ${LOW_VISIBILITY_TABLES} large tables have < 85% all_visible coverage."
fi

echo "=== [Gate 4/5] Auditing Anti-Wraparound Freeze Horizon Safety ==="
MAX_XID_AGE=$(psql "${DB_URL}" -At -c "SELECT max(age(relfrozenxid)) FROM pg_class WHERE relkind = 'r';")
if [ "${MAX_XID_AGE}" -gt 80000000 ]; then
  echo "❌ CRITICAL: Maximum relfrozenxid age (${MAX_XID_AGE}) exceeds safe threshold (80M)!"
  exit 1
fi
echo "✅ Max relfrozenxid age is healthy: ${MAX_XID_AGE} (Threshold: 80,000,000)."

echo "=== [Gate 5/5] Asserting Index-Only Scan Zero-Heap-Fetch Fidelity ==="
HEAP_FETCHES=$(psql "${DB_URL}" -At -c "
  EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
  SELECT id FROM users WHERE id = '00000000-0000-0000-0000-000000000001'::uuid;
" | jq '.[0].Plan."Heap Fetches" // 0')

if [ "${HEAP_FETCHES}" -gt 0 ]; then
  echo "❌ CRITICAL: Index-Only Scan performed ${HEAP_FETCHES} heap fetches!"
  exit 1
fi
echo "✅ Index-Only Scan executed with 0 heap fetches."
echo "=== All Visibility Map & Vacuum Freezing CI Gates Passed! ==="
```
