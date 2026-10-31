---
description: PostgreSQL page checksums (data_checksums = on), torn page protection (full_page_writes = on), block corruption detection (ERROR invalid page in block X of relation checksum verification failed), zero_damaged_pages silent data loss catastrophe, amcheck integrity auditing (bt_index_check, bt_index_parent_check, verify_heapam), pageinspect tuple extraction, surgical block-level recovery, standby page transplantation, and offline verification (pg_checksums) across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, psycopg3), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{checksum,corruption,amcheck,pageinspect,repair,backup,migration,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Page Checksums, Torn Page Protection, amcheck Integrity Verification, zero_damaged_pages Pitfalls & Block-Level Corruption Repair

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design relational data persistence architectures, audit high-reliability OLTP storage, configure cluster durability and backup regimes, verify physical block integrity, or perform zero-downtime disaster remediation across PostgreSQL (12–17+) in Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "zero_damaged_pages Amnesiac Silent Data Annihilation" (where encountering `invalid page in block X: checksum verification failed` causes engineers or autonomous agents to enable `SET zero_damaged_pages = on;` to make queries pass, forcing PostgreSQL to overwrite the corrupted 8KB page with zeroes in `shared_buffers` and silently vaporizing 50–250 live production records forever without an audit trail), the "Disabled data_checksums Silent Bit-Rot Illusion" (where clusters initialized without `-k` / `--data-checksums` silently read and write corrupted pages caused by NVMe controller silent bitflips, SAN degradation, or memory faults, replicating corrupted blocks to standbys and backups for months until cascading query aborts strike), the "Torn Page & full_page_writes = off High-Throughput Gamble" (where operators disable `full_page_writes` to save WAL write bandwidth during heavy write workloads, causing partial 4KB/512B operating system writes during an unexpected power loss or kernel panic, permanently corrupting physical page headers and preventing postmaster crash recovery), the "Naive REINDEX on Corrupted Heap Catastrophe" (where agents run naive `REINDEX` against tables with corrupted heap line pointers `ItemPointerData`, baking corrupted offset pointers into fresh B-Trees and spreading query failure across secondary indexes), the "Missing amcheck Proactive Integrity Sentinel" (where systems only discover physical page or B-Tree pointer corruption when client customer transactions crash with 500 errors, rather than detecting bitflips proactively via non-blocking `verify_heapam()` and `bt_index_parent_check()`), and the "Unsafe In-Place Page Surgery & pg_surgery Foreign Key Severing" (where operators blindly invoke `heap_force_kill()` without salvaging surviving live tuples via `pageinspect`, permanently severing referential integrity and generating dangling foreign key orphans) by establishing a strict 5-Tier Page Integrity & Corruption Governance Ladder, torn write risk calculus $\mathcal{T}_{\text{torn}}$, mathematical bit-flip detection bounds, a production-ready TypeScript `AgenticPageIntegrityGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state integrity verification finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Page Checksum Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, relations (tables, indexes, materialized views, sequences, and TOAST tables) are physically divided into fixed-size **8192-byte disk pages** (blocks). Each 8KB page consists of:
- **PageHeaderData** (24 bytes): Contains `pd_lsn` (Log Sequence Number of the last WAL record affecting the page), `pd_checksum` (16-bit CRC/checksum computed over the page), `pd_flags`, `pd_lower` (byte offset to start of free space), `pd_upper` (byte offset to end of free space), `pd_special` (index-specific data offset), and `pd_pagesize_version`.
- **Line Pointer Array** (`ItemIdData`, 4 bytes each): `lp_offset`, `lp_flags` (`LP_UNUSED`, `LP_NORMAL`, `LP_REDIRECT`, `LP_DEAD`), and `lp_len`.
- **Free Space** ($[pd\_lower, pd\_upper]$).
- **Tuple Storage** (growing downwards from the end of the page).

When `data_checksums = on`, PostgreSQL calculates a checksum over the entire 8192-byte page (with the checksum field zeroed) before writing it to disk via `PageSetChecksumInplace()`. When a page is read from the operating system page cache or disk into `shared_buffers`, `PageIsVerified()` re-evaluates the checksum. If the checksum does not match, PostgreSQL emits `ERROR: invalid page in block X of relation ...: checksum verification failed` (SQLSTATE `XX001`).

When autonomous coding agents, junior DBAs, or automated remediation scripts interact with corrupted pages, disastrous anti-patterns routinely emerge:

### The 6 Page Checksum & Block Corruption Catastrophes

```
+----------------------------------------------------------------------------------------------------+
|                       THE 6 PAGE CHECKSUM & BLOCK CORRUPTION CATASTROPHES                          |
+------------------------------------+---------------------------------------------------------------+
| 1. zero_damaged_pages Amnesiac     | Encountering checksum verification failure leads agents to    |
|    Silent Data Annihilation        | execute SET zero_damaged_pages = on; PostgreSQL overwrites    |
|                                    | corrupted 8KB block with all zeroes, vaporizing 50-250 rows!  |
+------------------------------------+---------------------------------------------------------------+
| 2. Disabled data_checksums Silent  | Initializing clusters without --data-checksums allows silent  |
|    Bit-Rot Illusion                | NVMe bitflips to persist unnoticed, replicating silent        |
|                                    | corruption to replicas and backups for months undetected.     |
+------------------------------------+---------------------------------------------------------------+
| 3. Torn Page & full_page_writes    | Disabling full_page_writes = off saves WAL IOPS but causes    |
|    High-Throughput Gamble          | partial 4KB OS writes during OS crashes; redo replay crashes   |
|                                    | with fatal unrecoverable page header corruption.              |
+------------------------------------+---------------------------------------------------------------+
| 4. Naive REINDEX on Corrupted Heap | Running REINDEX on tables with corrupted heap line pointers   |
|    Catastrophe                     | indexes phantom/torn offsets, propagating corrupted pointers  |
|                                    | into secondary indexes and poisoning Index-Only Scans.        |
+------------------------------------+---------------------------------------------------------------+
| 5. Missing amcheck Proactive       | Relying on user queries to discover bit-rot causes production |
|    Integrity Sentinel              | outages; absence of verify_heapam() and bt_index_parent_check |
|                                    | means latent corruption goes unquarantined until P1 outage.   |
+------------------------------------+---------------------------------------------------------------+
| 6. Unsafe In-Place Page Surgery    | Executing heap_force_kill() without extracting surviving rows |
|    & pg_surgery FK Severing        | via pageinspect destroys recoverable tuples and leaves        |
|                                    | orphaned child foreign keys across relational hierarchies.    |
+------------------------------------+---------------------------------------------------------------+
```

---

## 2. The 5-Tier Page Integrity & Corruption Governance Ladder

To eliminate silent corruption, data loss from naive zeroing, and cascade downtime, all applications and autonomous agents MUST conform to the 5-Tier Page Integrity Ladder:

```
+----------------------------------------------------------------------------------------------------+
|                     THE 5-TIER PAGE INTEGRITY & CORRUPTION GOVERNANCE LADDER                       |
+------+------------------------------+--------------------------------------------------------------+
| Tier | Name                         | Core Invariants & Architectural Mandate                      |
+------+------------------------------+--------------------------------------------------------------+
|  0   | Storage Durability Base      | Cluster initialized with data_checksums = on (-k).           |
|      |                              | Mandatory full_page_writes = on. Verify via pg_checksums.    |
+------+------------------------------+--------------------------------------------------------------+
|  1   | zero_damaged_pages Fencing   | zero_damaged_pages MUST BE off in production configs.        |
|      |                              | Prohibit global or session-level enabling; quarantine block. |
+------+------------------------------+--------------------------------------------------------------+
|  2   | Proactive amcheck Auditing   | Scheduled verify_heapam() and bt_index_parent_check(true)   |
|      |                              | with statement_timeout = 30s and cost limit throttling.      |
+------+------------------------------+--------------------------------------------------------------+
|  3   | Surgical Tuple Salvage       | When block B is corrupted: inspect with get_raw_page and     |
|      |                              | heap_page_items; extract surviving live tuples before repair.|
+------+------------------------------+--------------------------------------------------------------+
|  4   | Zero-Downtime Block Patching | Transplant intact page from standby replica via dd/pg_surgery|
|      | & Standby Transplantation    | or execute PITR block replacement; REINDEX CONCURRENTLY.     |
+------+------------------------------+--------------------------------------------------------------+
```

---

## 3. Mathematical Foundations: Checksum Physics, Torn Write Risk & Tuple Yield

### 3.1 Checksum Bit-Flip Detection Model

PostgreSQL computes a 16-bit checksum algorithm over each 8192-byte buffer. The checksum algorithm uses a vectorized lookup table over 32-bit words with rotate-left operations.

Let $N_{\text{bits}} = 8192 \times 8 = 65,536\text{ bits}$ per page. For an independent random bit-flip error rate $p_{\text{error}}$ per bit (from cosmic rays, memory decay, or storage channel noise), the probability of undetected corruption $P_{\text{undetected}}$ across a 16-bit checksum space is:

$$P_{\text{undetected}} \approx \frac{1}{2^{16}} = \frac{1}{65,536} \approx 1.526 \times 10^{-5}$$

For single-bit, double-bit, and burst errors $\le 16\text{ bits}$, the CRC-like checksum guarantees **100% detection rate**:

$$P_{\text{detection}}(\text{burst} \le 16) = 1.0$$

### 3.2 Torn Page Risk Probability Calculus

A "torn page" occurs when an 8192-byte page write is interrupted halfway through by an ungraceful operating system crash or hardware loss. Because POSIX filesystem atomic block size is typically $S_{\text{fs}} = 4096\text{ bytes}$ or $S_{\text{sector}} = 512\text{ bytes}$, writing an 8KB PostgreSQL block requires at least two separate sector writes.

If a crash occurs during the intermediate state:
- Top 4KB: New version (with modern `pd_lsn` and updated header).
- Bottom 4KB: Old version (with outdated tuple data or fragmented offsets).

The expected number of torn pages $\mathcal{N}_{\text{torn}}$ during a crash with $D$ dirty shared buffers without Full Page Writes is:

$$\mathcal{N}_{\text{torn}} = D_{\text{dirty}} \times P(\text{crash during write window}) = D_{\text{dirty}} \times \left( \frac{\tau_{\text{disk\_write}}}{T_{\text{checkpoint}}} \right)$$

When `full_page_writes = on`, PostgreSQL writes the entire 8KB page image into WAL during the first modification after each checkpoint. During crash recovery, PostgreSQL overrides the torn page on disk with the pristine full-page image from WAL, guaranteeing:

$$\mathcal{N}_{\text{torn}}^{\text{FPW=on}} = 0$$

### 3.3 Tuple Salvage Yield Calculus

When block $B$ of relation $R$ suffers single-block header or tuple corruption, let $K$ be the total line pointers (`ItemIdData`) originally present in the block.
Using `pageinspect`, the salvaged tuple yield $Y_{\text{tuples}}$ is defined as:

$$Y_{\text{tuples}} = \frac{\sum_{i=1}^{K} \mathbb{I}(\text{tuple } i \text{ passes header \& schema validation})}{K}$$

By salvaging tuples before any zeroing or killing operation, recovery preserves up to $95\%$ of live data instead of $0\%$ under `zero_damaged_pages = on`.

---

## 4. Production TypeScript Sentinel: `AgenticPageIntegrityGuardEngine`

The following TypeScript engine provides complete proactive integrity verification via `amcheck`, torn page quarantine, tuple salvage extraction via `pageinspect`, and safe zero-downtime remediation.

```typescript
// src/db/page_integrity_guard_engine.ts
import { Pool, PoolClient } from 'pg';

export interface CorruptionAuditResult {
  relationName: string;
  relationType: 'table' | 'index' | 'toast';
  status: 'HEALTHY' | 'CORRUPTED' | 'UNCHECKED';
  corruptedBlocks: number[];
  errorMessage?: string;
  checkTimestamp: Date;
}

export interface SalvagedTuple {
  linePointer: number;
  t_xmin: string;
  t_xmax: string;
  t_field3: string;
  t_ctid: string;
  t_infomask: number;
  t_infomask2: number;
  dataRawHex: string;
}

export class AgenticPageIntegrityGuardEngine {
  constructor(private readonly pool: Pool) {}

  /**
   * Verifies cluster-wide checksum configuration (Tier 0).
   */
  async verifyClusterChecksums(): Promise<{ dataChecksums: boolean; fullPageWrites: boolean }> {
    const client = await this.pool.connect();
    try {
      const resChecksums = await client.query<{ data_checksums: string }>(
        "SHOW data_checksums;"
      );
      const resFPW = await client.query<{ full_page_writes: string }>(
        "SHOW full_page_writes;"
      );

      const dataChecksums = resChecksums.rows[0]?.data_checksums === 'on';
      const fullPageWrites = resFPW.rows[0]?.full_page_writes === 'on';

      if (!dataChecksums) {
        console.warn(
          'CRITICAL: data_checksums is OFF! Silent hardware bitflips will not be detected. Enable via pg_checksums offline.'
        );
      }
      if (!fullPageWrites) {
        throw new Error(
          'FATAL: full_page_writes is OFF! Torn page protection is completely broken. Refusing to operate in production.'
        );
      }

      return { dataChecksums, fullPageWrites };
    } finally {
      client.release();
    }
  }

  /**
   * Executes non-blocking amcheck verification on a B-Tree index (Tier 2).
   */
  async verifyIndexIntegrity(indexName: string): Promise<CorruptionAuditResult> {
    const client = await this.pool.connect();
    try {
      // statement_timeout avoids blocking queries during heavy lock wait
      await client.query("SET statement_timeout = '30s';");
      await client.query("SET lock_timeout = '2s';");

      // bt_index_parent_check checks child-parent B-Tree invariants
      await client.query('SELECT bt_index_parent_check($1::regclass, true);', [
        indexName,
      ]);

      return {
        relationName: indexName,
        relationType: 'index',
        status: 'HEALTHY',
        corruptedBlocks: [],
        checkTimestamp: new Date(),
      };
    } catch (err: any) {
      return {
        relationName: indexName,
        relationType: 'index',
        status: 'CORRUPTED',
        corruptedBlocks: [],
        errorMessage: err.message,
        checkTimestamp: new Date(),
      };
    } finally {
      client.release();
    }
  }

  /**
   * Executes verify_heapam on PostgreSQL 14+ to detect torn or corrupted heap pages (Tier 2).
   */
  async verifyHeapIntegrity(tableName: string): Promise<CorruptionAuditResult> {
    const client = await this.pool.connect();
    try {
      await client.query("SET statement_timeout = '60s';");
      await client.query("SET lock_timeout = '3s';");

      const res = await client.query<{ blkno: number; offnum: number; attnum: number; msg: string }>(
        `SELECT blkno, offnum, attnum, msg
         FROM verify_heapam($1::regclass, on_error_stop := false, check_toast := true)
         LIMIT 50;`,
        [tableName]
      );

      if (res.rows.length === 0) {
        return {
          relationName: tableName,
          relationType: 'table',
          status: 'HEALTHY',
          corruptedBlocks: [],
          checkTimestamp: new Date(),
        };
      }

      const corruptedBlocks = Array.from(new Set(res.rows.map((r) => r.blkno)));
      return {
        relationName: tableName,
        relationType: 'table',
        status: 'CORRUPTED',
        corruptedBlocks,
        errorMessage: `verify_heapam detected ${res.rows.length} corruptions. Example: ${res.rows[0].msg}`,
        checkTimestamp: new Date(),
      };
    } catch (err: any) {
      return {
        relationName: tableName,
        relationType: 'table',
        status: 'CORRUPTED',
        corruptedBlocks: [],
        errorMessage: err.message,
        checkTimestamp: new Date(),
      };
    } finally {
      client.release();
    }
  }

  /**
   * Salvages surviving tuples from a corrupted block using pageinspect (Tier 3).
   * NEVER runs zero_damaged_pages!
   */
  async salvageBlockTuples(tableName: string, blockNo: number): Promise<SalvagedTuple[]> {
    const client = await this.pool.connect();
    try {
      // Ensure zero_damaged_pages is strictly OFF
      await client.query("SET zero_damaged_pages = off;");

      const query = `
        SELECT
          lp AS line_pointer,
          t_xmin::text,
          t_xmax::text,
          t_field3::text,
          t_ctid::text,
          t_infomask,
          t_infomask2,
          t_data::text AS data_hex
        FROM heap_page_items(get_raw_page($1, $2))
        WHERE lp_flags = 1; -- LP_NORMAL (valid tuple pointer)
      `;

      const res = await client.query(query, [tableName, blockNo]);
      return res.rows.map((r) => ({
        linePointer: r.line_pointer,
        t_xmin: r.t_xmin,
        t_xmax: r.t_xmax,
        t_field3: r.t_field3,
        t_ctid: r.t_ctid,
        t_infomask: r.t_infomask,
        t_infomask2: r.t_infomask2,
        dataRawHex: r.data_hex,
      }));
    } finally {
      client.release();
    }
  }

  /**
   * Generates safe zero-downtime remediation plan (Tier 4).
   */
  generateRemediationPlan(audit: CorruptionAuditResult): {
    strategy: string;
    ddlStatements: string[];
    safeToAutomate: boolean;
  } {
    if (audit.status === 'HEALTHY') {
      return { strategy: 'NO_ACTION', ddlStatements: [], safeToAutomate: true };
    }

    if (audit.relationType === 'index') {
      return {
        strategy: 'CONCURRENT_INDEX_REBUILD',
        ddlStatements: [
          `SET lock_timeout = '2000ms';`,
          `REINDEX INDEX CONCURRENTLY ${audit.relationName};`,
        ],
        safeToAutomate: true,
      };
    }

    // Heap relation corruption: requires tuple salvage + surgical intervention
    return {
      strategy: 'SURGICAL_STANDBY_PATCH_OR_TUPLE_EXTRACTION',
      ddlStatements: [
        `-- STEP 1: DO NOT run zero_damaged_pages = on!`,
        `-- STEP 2: Extract surviving tuples via pageinspect.heap_page_items(get_raw_page('${audit.relationName}', ${audit.corruptedBlocks[0] ?? 0}))`,
        `-- STEP 3: Check if standby replica has an undamaged page for block ${audit.corruptedBlocks.join(', ')}`,
        `-- STEP 4: If index corruption, REINDEX CONCURRENTLY after heap repair.`,
      ],
      safeToAutomate: false,
    };
  }
}
```

---

## 5. Multi-Language Production Implementations

### 5.1 Golang Implementation (`jackc/pgx/v5`)

```go
// internal/store/checksum_watchdog.go
package store

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type ChecksumHealth struct {
	DataChecksumsEnabled bool      `json:"data_checksums_enabled"`
	FullPageWrites       bool      `json:"full_page_writes"`
	ZeroDamagedPages     bool      `json:"zero_damaged_pages"`
	AuditedAt            time.Time `json:"audited_at"`
	Status               string    `json:"status"`
}

type ChecksumWatchdog struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewChecksumWatchdog(pool *pgxpool.Pool, logger *slog.Logger) *ChecksumWatchdog {
	return &ChecksumWatchdog{pool: pool, logger: logger}
}

// AuditClusterDurability verifies Tier 0 & Tier 1 invariants.
func (w *ChecksumWatchdog) AuditClusterDurability(ctx context.Context) (*ChecksumHealth, error) {
	conn, err := w.pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to acquire db connection: %w", err)
	}
	defer conn.Release()

	var dataChecksums, fpw, zeroDamaged string
	if err := conn.QueryRow(ctx, "SHOW data_checksums;").Scan(&dataChecksums); err != nil {
		return nil, fmt.Errorf("query data_checksums failed: %w", err)
	}
	if err := conn.QueryRow(ctx, "SHOW full_page_writes;").Scan(&fpw); err != nil {
		return nil, fmt.Errorf("query full_page_writes failed: %w", err)
	}
	if err := conn.QueryRow(ctx, "SHOW zero_damaged_pages;").Scan(&zeroDamaged); err != nil {
		return nil, fmt.Errorf("query zero_damaged_pages failed: %w", err)
	}

	health := &ChecksumHealth{
		DataChecksumsEnabled: dataChecksums == "on",
		FullPageWrites:       fpw == "on",
		ZeroDamagedPages:     zeroDamaged == "on",
		AuditedAt:            time.Now().UTC(),
		Status:               "HEALTHY",
	}

	if health.ZeroDamagedPages {
		health.Status = "CRITICAL_RISK"
		w.logger.Error("FATAL: zero_damaged_pages is ON! Corrupted pages will be silently destroyed. Set to OFF immediately.")
	} else if !health.FullPageWrites {
		health.Status = "DURABILITY_BREACH"
		w.logger.Error("FATAL: full_page_writes is OFF! Torn page protection disabled.")
	} else if !health.DataChecksumsEnabled {
		health.Status = "WARNING"
		w.logger.Warn("WARNING: data_checksums is OFF! Hardware bitflips will not be caught.")
	}

	return health, nil
}

// VerifyBTreeIndex runs non-blocking amcheck on secondary indexes.
func (w *ChecksumWatchdog) VerifyBTreeIndex(ctx context.Context, indexName string) error {
	conn, err := w.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()

	// Apply strict timeouts to prevent holding locks
	_, err = conn.Exec(ctx, `
		SET LOCAL statement_timeout = '20s';
		SET LOCAL lock_timeout = '2s';
	`)
	if err != nil {
		return fmt.Errorf("failed to configure timeout guards: %w", err)
	}

	// bt_index_parent_check checks cross-page order invariants
	_, err = conn.Exec(ctx, "SELECT bt_index_parent_check($1::regclass, true);", indexName)
	if err != nil {
		return fmt.Errorf("amcheck verification failed on %s: %w", indexName, err)
	}

	w.logger.Info("amcheck index verification passed", "index", indexName)
	return nil
}
```

---

### 5.2 Python Implementation (`asyncpg`)

```python
# scripts/database/amcheck_verifier.py
import asyncio
import logging
from typing import Dict, List, Optional
import asyncpg

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("checksum_sentinel")

async def verify_cluster_integrity(pool: asyncpg.Pool) -> Dict[str, any]:
    """Audits PostgreSQL cluster checksum configuration and scans critical tables."""
    async with pool.acquire() as conn:
        checksums = await conn.fetchval("SHOW data_checksums;")
        fpw = await conn.fetchval("SHOW full_page_writes;")
        zero_damaged = await conn.fetchval("SHOW zero_damaged_pages;")

        if zero_damaged == "on":
            logger.critical("FATAL: zero_damaged_pages is ON! Potential silent data loss in progress!")

        # Scan critical tables using amcheck verify_heapam (PG 14+)
        heap_issues: List[Dict[str, any]] = []
        try:
            rows = await conn.fetch("""
                SELECT c.relname, v.blkno, v.offnum, v.msg
                FROM pg_class c
                CROSS JOIN LATERAL verify_heapam(c.oid, on_error_stop := false) v
                WHERE c.relnamespace = 'public'::regnamespace
                  AND c.relkind = 'r'
                LIMIT 50;
            """)
            for r in rows:
                heap_issues.append({
                    "table": r["relname"],
                    "block": r["blkno"],
                    "offset": r["offnum"],
                    "message": r["msg"],
                })
        except Exception as ex:
            logger.warning("verify_heapam skipped or failed: %s", ex)

        return {
            "data_checksums": checksums == "on",
            "full_page_writes": fpw == "on",
            "zero_damaged_pages": zero_damaged == "on",
            "heap_issues": heap_issues,
            "is_healthy": len(heap_issues) == 0 and zero_damaged == "off" and fpw == "on"
        }
```

---

### 5.3 Rust Implementation (`sqlx`)

```rust
// src/db/checksum_guard.rs
use sqlx::{PgPool, Row};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct ClusterDurabilityAudit {
    pub data_checksums: bool,
    pub full_page_writes: bool,
    pub zero_damaged_pages: bool,
    pub is_production_safe: bool,
}

pub async fn audit_durability(pool: &PgPool) -> Result<ClusterDurabilityAudit, sqlx::Error> {
    let row = sqlx::query(
        r#"
        SELECT
            current_setting('data_checksums') = 'on' AS checksums,
            current_setting('full_page_writes') = 'on' AS fpw,
            current_setting('zero_damaged_pages') = 'on' AS zero_damaged;
        "#
    )
    .fetch_one(pool)
    .await?;

    let checksums: bool = row.get("checksums");
    let fpw: bool = row.get("fpw");
    let zero_damaged: bool = row.get("zero_damaged");

    let is_safe = !zero_damaged && fpw;

    Ok(ClusterDurabilityAudit {
        data_checksums: checksums,
        full_page_writes: fpw,
        zero_damaged_pages: zero_damaged,
        is_production_safe: is_safe,
    })
}

pub async fn verify_btree_parent(pool: &PgPool, index_name: &str) -> Result<bool, sqlx::Error> {
    let mut conn = pool.acquire().await?;
    
    // Set 5-second statement timeout to prevent lock queue stalls
    sqlx::query("SET LOCAL statement_timeout = '5000ms';")
        .execute(&mut *conn)
        .await?;

    let result = sqlx::query("SELECT bt_index_parent_check($1::regclass, true);")
        .bind(index_name)
        .execute(&mut *conn)
        .await;

    match result {
        Ok(_) => Ok(true),
        Err(e) => {
            eprintln!("B-Tree integrity failure on {}: {:?}", index_name, e);
            Err(e)
        }
    }
}
```

---

## 6. The 6-State Page Integrity Lifecycle Finite-State Machine (FSM)

```
       [ 1. UNCHECKED ]
              │
              │ (Scheduled Watchdog / amcheck)
              ▼
       [ 2. AUDITING ]
        ├── Checksums match & amcheck 0 errors ────────► [ 3. HEALTHY ]
        │                                                     │
        │                                                     │ (Periodic interval)
        │                                                     ▼
        │                                              [ 2. AUDITING ]
        │
        └── Checksum mismatch / verify_heapam error ──► [ 4. CORRUPTION_DETECTED ]
                                                              │
                                                              │ (Fence relation & isolate)
                                                              ▼
                                                        [ 5. QUARANTINED ]
                                                              │
                                                              │ (pageinspect extraction &
                                                              │  standby page transplantation)
                                                              ▼
                                                        [ 6. RESTORING ]
                                                              │
                                                              │ (REINDEX CONCURRENTLY & verify)
                                                              ▼
                                                        [ 3. HEALTHY ]
```

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Test / Metric Command | Pass Condition |
| :--- | :--- | :--- | :--- |
| **Gate 1: Checksum Activation** | Physical block checksumming | `SHOW data_checksums;` | MUST return `'on'`. |
| **Gate 2: Torn Page Guard** | Full page WAL image logging | `SHOW full_page_writes;` | MUST return `'on'`. |
| **Gate 3: Anti-Amnesia Fence** | Zero damaged page overwrite prohibition | `SHOW zero_damaged_pages;` | MUST return `'off'` across all roles and configs. |
| **Gate 4: B-Tree Verification** | Secondary index integrity | `SELECT bt_index_parent_check(c.oid, true) FROM pg_index ...` | 0 SQL errors; passes all parent/child invariant assertions. |
| **Gate 5: Heap Page Verification** | Heap & TOAST integrity | `SELECT * FROM verify_heapam('critical_table'::regclass)` | 0 rows returned (no corrupted blocks). |
| **Gate 6: Zero-Downtime Repair** | Reindexing without table lockout | Audit script validation | All index repairs executed via `REINDEX ... CONCURRENTLY`. |
