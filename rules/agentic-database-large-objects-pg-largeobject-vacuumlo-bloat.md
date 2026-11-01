---
description: PostgreSQL Large Objects (pg_largeobject, pg_largeobject_metadata), lo_create/lo_unlink API, system catalog bloat, orphan leak elimination, vacuumlo lock contention, bytea vs LOB memory boundaries, O(1) chunked streaming, and S3/object storage crossover across Go (pgx/v5), TypeScript (pg, Kysely), Python (asyncpg, psycopg3), Rust (tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{blob,lob,largeobject,attachment,upload,file,storage,postgres,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Large Objects (LOBs / BLOBs), pg_largeobject Catalog Bloat, lo_unlink Orphan Leaks, vacuumlo Lock Contention & Chunked Streaming Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design PostgreSQL binary storage architectures across file storage repositories (PDFs, images, attachments, audio, firmwares, cryptographic bundles) in Go (`jackc/pgx/v5`), TypeScript (`node-postgres`, `Kysely`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`, `psycopg3`), or Rust (`tokio-postgres`, `sqlx`). Eliminate the "Silent Orphan Leak & System Catalog Disk Exhaustion Catastrophe" (where relational `DELETE` drops referencing rows while referenced LOB chunks remain forever in `pg_largeobject`, swelling system catalogs into hundreds of gigabytes and exhausting disk space), the "`vacuumlo` Access Exclusive System Catalog Lockout & Connection Stall" (where running unthrottled `vacuumlo` or monolithic unlinking loops locks `pg_largeobject`, blocks concurrent file operations, spikes WAL volume, and collapses application connection pools), the "Transaction Scoping & `SQLSTATE 25000` Invalidation Trap" (where opening LOB descriptors outside active transactions or across async HTTP chunks triggers `invalid large object descriptor`), the "`bytea` Inline RAM Explosion vs LOB Chunk Streaming Boundary" (where storing multi-megabyte files in `bytea` forces de-TOASTing into contiguous RAM, provoking OOM killer terminations), the "Logical Replication & CDC Complete Blindness Trap" (where PostgreSQL native logical replication strictly omits system catalogs, leaving logical replicas with dangling 32-bit OID references and failing queries), and the "External Object Storage (S3 / R2 / MinIO) Architectural Crossover Fallacy" (where storing multi-megabyte binary assets in OLTP tables causes $2\times–4\times$ WAL amplification and inflates backup restore times from minutes to hours) by establishing a strict 5-Tier Large Object Governance Ladder, mathematical sizing and amplification proofs, an autonomous TypeScript `AgenticDatabaseLargeObjectGuardEngine`, cross-runtime telemetry sentinels in Go, TypeScript, Python, and Rust, a 6-state large object lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Large Object Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL (version 10 through 17+), binary data storage is bifurcated between **TOAST-compressed `bytea`** and **PostgreSQL Large Objects** (`src/backend/storage/large_object/inv_api.c`):

1. **Physical On-Disk Structure of Large Objects**:
   - Unlike standard user tables whose data resides in user-defined relation forks, Large Objects reside in the core system catalog tables `pg_largeobject` and `pg_largeobject_metadata`.
   - `pg_largeobject` splits binary data into fixed 2,048-byte chunks (`PAGE_SIZE / 4`):
     ```sql
     -- Definition of pg_largeobject (system catalog)
     CREATE TABLE pg_largeobject (
         loid    oid,       -- Large object identifier
         pageno  integer,   -- Sequential page number (0, 1, 2, ...)
         data    bytea      -- Binary chunk payload (up to 2048 bytes)
     );
     CREATE UNIQUE INDEX pg_largeobject_loid_pn_index ON pg_largeobject (loid, pageno);
     ```
   - `pg_largeobject_metadata` tracks ownership and Access Control Lists (`lomowner`, `lomacl`).
   - A single Large Object can span up to 4 TB in size ($2^{31}-1$ pages $\times$ 2,048 bytes), addressed by an unsigned 32-bit `OID`.
2. **The 6 Large Object Catastrophes**:
   - **Catastrophe 1: The "Silent Orphan Leak & System Catalog Disk Exhaustion Catastrophe"**: PostgreSQL `OID` references lack relational referential integrity. Executing `DELETE FROM attachments WHERE id = $1;` removes the application row containing the `file_oid` integer, but does NOT remove a single chunk from `pg_largeobject`. In active systems with high document turnover, hundreds of thousands of orphaned LOBs accumulate invisibly. System catalogs swell from 50 MB to 500 GB, bloating `pg_largeobject_loid_pn_index`, saturating `shared_buffers`, slowing system catalog lookups across all database backends, and eventually causing `PANIC: could not write to file ...: No space left on device`.
   - **Catastrophe 2: The "`vacuumlo` Access Exclusive System Catalog Lockout & Connection Stall"**: When teams discover 300 GB of orphaned LOBs, they run PostgreSQL's bundled utility `vacuumlo` or write custom loops calling `SELECT lo_unlink(unref_oid)` in a single transaction. Running `vacuumlo` without chunking or lock timeouts acquires table-level locks, thrashes catalog pages, creates heavy WAL traffic ($2\times$ the volume of purged LOBs), triggers checkpointer write stalls, and causes connection pool exhaustion for all active application queries.
   - **Catastrophe 3: The "Transaction Scoping & `SQLSTATE 25000` Invalidation Trap"**: Large object file descriptors returned by `lo_open(loid, mode)` are strictly bound to the active transaction (`CurrentResourceOwner`). If an autonomous agent opens an LOB descriptor, completes or commits the database transaction, and subsequently attempts to stream the bytes to an HTTP client or file writer, PostgreSQL immediately throws `ERROR: invalid large object descriptor` or `SQLSTATE 25000: active sql transaction required`.
   - **Catastrophe 4: The "`bytea` Inline RAM Explosion vs LOB Chunk Streaming Boundary"**: Storing 50 MB files in standard `bytea` columns causes severe memory blowup. Although PostgreSQL stores large `bytea` values out-of-line in TOAST tables, reading or updating a `bytea` column forces the database engine to reconstruct the entire byte array in memory, and the client driver (e.g., Node.js Buffer, Python bytes, Go []byte) must allocate the contiguous buffer. Under concurrent requests, this triggers memory thrashing and postmaster OOM killer decapitation. Large Objects permit bounded $O(1)$ RAM streaming via 64 KB / 128 KB chunk reads (`lo_read()`), but only when governed properly.
   - **Catastrophe 5: The "Logical Replication & CDC Complete Blindness Trap"**: PostgreSQL native logical replication (`CREATE PUBLICATION ... FOR ALL TABLES`) strictly replicates user tables and explicitly DOES NOT replicate system catalogs (`pg_largeobject` and `pg_largeobject_metadata`). When an application table with an `OID` column replicates to a subscriber, the subscriber receives the numeric OID, but the referenced chunks do not exist in the subscriber's `pg_largeobject` catalog. Any subsequent `lo_get(oid)` or `lo_open(oid)` call on the read replica crashes with `ERROR: large object ... does not exist`.
   - **Catastrophe 6: The "External Object Storage (S3 / R2 / MinIO) Architectural Crossover Fallacy"**: Persisting multi-megabyte files ($> 5\text{MB}$) directly inside relational database tables incurs massive WAL amplification ($2\times–4\times$), swells PITR backup archives by terabytes, extends recovery time objective (RTO) from minutes to days, and drives cloud database storage bills up by $10\times–25\times$ compared to S3/Cloudflare R2 object storage.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               POSTGRESQL BINARY STORAGE TOPOLOGY & ORPHAN ACCUMULATION                 │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ USER SPACE (Application Tables)                                                        │
│   Table: documents                                                                     │
│   ┌────────┬───────────────────────────┬──────────────┐                                │
│   │ id     │ title                     │ lob_oid      │                                │
│   ├────────┼───────────────────────────┼──────────────┤                                │
│   │ 101    │ contract_2026.pdf         │ 48102        │ ──┐                            │
│   │ 102    │ passport_scan.png         │ 48103        │ ──┼──┐                         │
│   │ [DEL]  │ [DELETED ROW: ID 99]      │ [48101]      │ ──┼──┼──┐ (RELATIONAL ROW GONE)│
│   └────────┴───────────────────────────┴──────────────┘   │  │  │                      │
├───────────────────────────────────────────────────────────┼──┼──┼──────────────────────┤
│ SYSTEM CATALOG: pg_largeobject_metadata                   │  │  │                      │
│   ┌────────┬───────────┬─────────┐                        │  │  │                      │
│   │ gomid  │ lomowner  │ lomacl  │                        │  │  │                      │
│   ├────────┼───────────┼─────────┤                        │  │  │                      │
│   │ 48101  │ 10 (dba)  │ NULL    │ <──────────────────────┼──┼──┘ 💥 ORPHAN METADATA!  │
│   │ 48102  │ 10 (dba)  │ NULL    │ <──────────────────────┘  │                         │
│   │ 48103  │ 10 (dba)  │ NULL    │ <─────────────────────────┘                         │
│   └────────┴───────────┴─────────┘                                                     │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ SYSTEM CATALOG: pg_largeobject (2,048-Byte Chunks)                                     │
│   ┌────────┬────────┬─────────────────────────────┐                                    │
│   │ loid   │ pageno │ data (2KB chunk payload)    │                                    │
│   ├────────┼────────┼─────────────────────────────┤                                    │
│   │ 48101  │ 0      │ 0x255044462D312E37... (2KB) │ 💥 ORPHAN CHUNK (Consuming disk!)  │
│   │ 48101  │ 1      │ 0x8A120042...        (2KB) │ 💥 ORPHAN CHUNK (Consuming disk!)  │
│   │ ...    │ ...    │ ... (50,000 chunks = 100MB) │ 💥 ORPHAN CHUNKS (Never unlinked!) │
│   │ 48102  │ 0      │ 0x255044462D312E37... (2KB) │ Active Chunk                       │
│   │ 48103  │ 0      │ 0x89504E470D0A1A...   (2KB) │ Active Chunk                       │
│   └────────┴────────┴─────────────────────────────┘                                    │
│                                                                                        │
│   💥 THE CATASTROPHE:                                                                  │
│      DELETE FROM documents WHERE id = 99 removes the relational pointer, but leaves    │
│      50,000 chunks (100MB) permanently pinned in pg_largeobject!                       │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. The 5-Tier Large Object Governance Ladder

To eradicate system catalog bloat, eliminate OOM crashes, and maintain zero-downtime streaming, autonomous agents must enforce the 5-Tier Large Object Governance Ladder:

```
┌───────────────────────────────────────────────────────────────────────────────────────┐
│                     THE 5-TIER LARGE OBJECT GOVERNANCE LADDER                         │
├───────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Architectural Storage Qualification & Size Crossover Thresholds               │
│         - Files <= 256 KB: Inline bytea with LZ4 TOAST compression.                   │
│         - Files 256 KB - 5 MB: Transaction-scoped Large Objects with automated unlink.│
│         - Files >= 5 MB: Cloud Object Storage (S3 / R2 / MinIO) + Presigned URLs.     │
├───────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Automated Deletion Integrity via Database Triggers (`lo_manage`)              │
│         - Mandatory BEFORE/AFTER DELETE & UPDATE triggers unlinking referenced OIDs.  │
│         - Elimination of silent orphan leaks at the relational database schema tier.  │
├───────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Transaction-Scoped Bounded Chunk Streaming Harnesses                         │
│         - O(1) Memory usage: streaming in 64 KB / 128 KB buffers via lo_read/lo_write.│
│         - Strict transaction scope bounding with statement_timeout = '30s'.           │
├───────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Out-of-Band Non-Blocking Orphan Purging Sentinels                             │
│         - Non-blocking advisory lock fencing (pg_try_advisory_lock).                  │
│         - Keyset-paginated chunked lo_unlink (LIMIT 500) with sleep backoff intervals. │
│         - Zero AccessExclusiveLock table stalls and zero connection pool exhaustion.   │
├───────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Machine-Verifiable CI Gates & Logical Replication Parity Safeguards           │
│         - Static DDL analysis banning naked OID columns lacking unlink triggers.      │
│         - Dual-target replication synchronization for hybrid database/S3 assets.      │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

### Tier 0: Architectural Storage Qualification & Size Crossover Thresholds
Autonomous agents must apply the strict Three-Zone Binary Storage Rule:
1. **Zone 1: Small Payloads ($\le 256\text{ KB}$)**:
   - Use standard `bytea` with PostgreSQL 14+ `COMPRESSION lz4`.
   - Stored inline or in table-specific TOAST forks. No catalog bloat, zero orphan risk, fully supported by native Logical Replication.
2. **Zone 2: Medium Payloads ($256\text{ KB} < \text{Size} \le 5\text{ MB}$)**:
   - Permissible to use PostgreSQL Large Objects (`OID`) *strictly if* bounded streaming is required and relational atomicity with surrounding business entities is legally or architecturally mandated.
   - MUST be equipped with Tier 1 automated unlink triggers.
3. **Zone 3: Large Payloads ($> 5\text{ MB}$)**:
   - Strictly FORBID storing inside PostgreSQL (`bytea` or `LargeObject`).
   - Store binary payloads in S3-compatible Object Storage (AWS S3, Cloudflare R2, MinIO, GCP Cloud Storage). Store only the immutable URI/key, content type, SHA-256 checksum, and byte length in PostgreSQL.
   - Serve reads via pre-signed GET URLs and accept writes via pre-signed PUT URLs.

### Tier 1: Automated Deletion Integrity via Database Triggers (`lo_manage`)
PostgreSQL provides the built-in extension module `lo` containing the `lo_manage()` trigger function, or agents can write explicit PL/pgSQL triggers to guarantee referential unlinking:

```sql
-- Hardened Trigger Ensuring Zero Orphaned Large Objects
CREATE OR REPLACE FUNCTION trg_unlink_document_blob()
RETURNS TRIGGER AS $$
BEGIN
    -- If updating and the OID changed, unlink old LOB
    IF (TG_OP = 'UPDATE') THEN
        IF (OLD.lob_oid IS NOT NULL AND OLD.lob_oid IS DISTINCT FROM NEW.lob_oid) THEN
            PERFORM lo_unlink(OLD.lob_oid);
        END IF;
        RETURN NEW;
    END IF;

    -- If deleting, unlink referenced LOB
    IF (TG_OP = 'DELETE') THEN
        IF (OLD.lob_oid IS NOT NULL) THEN
            PERFORM lo_unlink(OLD.lob_oid);
        END IF;
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_temp;

-- Attach trigger to application table
DROP TRIGGER IF EXISTS trg_documents_lob_cleanup ON documents;
CREATE TRIGGER trg_documents_lob_cleanup
BEFORE UPDATE OF lob_oid OR DELETE ON documents
FOR EACH ROW
EXECUTE FUNCTION trg_unlink_document_blob();
```

---

## 3. Mathematical Foundations: Storage Amplification & Purge Contention Models

### 3.1 Catalog Chunk Amplification Model
When a binary payload of size $S_{\text{bytes}}$ is ingested as a Large Object, the total disk space consumed in `pg_largeobject` $S_{\text{cat}}$ is modeled by:

$$N_{\text{pages}} = \left\lceil \frac{S_{\text{bytes}}}{2048} \right\rceil$$

$$S_{\text{cat}} = N_{\text{pages}} \times \left( S_{\text{tuple\_hdr}} + S_{\text{loid}} + S_{\text{pageno}} + S_{\text{chunk\_data}} + S_{\text{line\_ptr}} \right)$$

Where in standard PostgreSQL 64-bit architecture:
- $S_{\text{tuple\_hdr}} = 24\text{ bytes}$ (Heap tuple header)
- $S_{\text{loid}} = 4\text{ bytes}$ (`OID`)
- $S_{\text{pageno}} = 4\text{ bytes}$ (`INT4`)
- $S_{\text{line\_ptr}} = 4\text{ bytes}$ (Page item pointer)
- Average chunk overhead per 2,048 bytes of data: $\approx 36\text{ bytes}$ ($1.75\%$ heap metadata overhead).

Additionally, the B-Tree index `pg_largeobject_loid_pn_index` stores:

$$S_{\text{index}} \approx N_{\text{pages}} \times 16\text{ bytes}$$

Thus, storing 100 GB of binary data in `pg_largeobject` produces over $50,000,000$ index entries in `pg_largeobject_loid_pn_index`, saturating `shared_buffers` and forcing random disk seeks.

### 3.2 Time-to-Disk-Exhaustion Model for Orphan Leaks
If an application churns $R_{\text{delete}}$ records per second with average binary size $\overline{S_{\text{lob}}}$, without unlinking triggers:

$$\frac{d(\text{Bloat})}{dt} = R_{\text{delete}} \times \overline{S_{\text{lob}}} \times \left(1 + \frac{36}{2048}\right)$$

$$T_{\text{exhaust}} = \frac{D_{\text{free}} - D_{\text{safety}}}{\frac{d(\text{Bloat})}{dt}}$$

For an application with $R_{\text{delete}} = 5\text{ ops/sec}$, $\overline{S_{\text{lob}}} = 2\text{ MB}$, and $D_{\text{free}} = 200\text{ GB}$:

$$\frac{d(\text{Bloat})}{dt} = 5 \times 2\text{ MB} \times 1.0175 \approx 10.18\text{ MB/sec} = 36.6\text{ GB/hour}$$

$$T_{\text{exhaust}} \approx \frac{160\text{ GB}}{36.6\text{ GB/hour}} \approx 4.37\text{ hours to catastrophic PANIC shutdown!}$$

---

## 4. Production-Grade TypeScript Guard Engine

```typescript
/**
 * AgenticDatabaseLargeObjectGuardEngine
 * Industrial-grade governance, chunked streaming, trigger generation,
 * and non-blocking batched orphan cleaner for PostgreSQL Large Objects.
 */

export interface LargeObjectStorageAssessment {
  recommendedStorage: 'INLINE_BYTEA' | 'LARGE_OBJECT' | 'EXTERNAL_S3';
  maxByteSize: number;
  warnings: string[];
  recommendedDDL?: string;
}

export interface OrphanAuditResult {
  totalMetadataLOBs: number;
  unreferencedOrphanCount: number;
  estimatedOrphanBytes: number;
  sampleOrphanOids: number[];
}

export class AgenticDatabaseLargeObjectGuardEngine {
  private static readonly MAX_BYTEA_THRESHOLD = 256 * 1024; // 256 KB
  private static readonly MAX_LOB_THRESHOLD = 5 * 1024 * 1024; // 5 MB

  /**
   * Qualifies whether a binary column should use bytea, LargeObject, or S3.
   */
  public static qualifyStorage(
    tableName: string,
    columnName: string,
    estimatedMaxBytes: number,
    isStreamed: boolean
  ): LargeObjectStorageAssessment {
    const warnings: string[] = [];

    if (estimatedMaxBytes <= this.MAX_BYTEA_THRESHOLD) {
      return {
        recommendedStorage: 'INLINE_BYTEA',
        maxByteSize: estimatedMaxBytes,
        warnings,
        recommendedDDL: `ALTER TABLE ${tableName} ADD COLUMN ${columnName} BYTEA; -- Use LZ4 compression in PG 14+`,
      };
    }

    if (estimatedMaxBytes <= this.MAX_LOB_THRESHOLD) {
      if (!isStreamed) {
        warnings.push(
          'Payload between 256KB and 5MB should use chunked streaming (lo_read/lo_write) to avoid contiguous memory allocation.'
        );
      }
      warnings.push(
        'PostgreSQL Large Objects (OID) DO NOT auto-unlink on relational row deletion. Mandatory trigger required.'
      );

      const ddl = `
-- 1. Add OID column referencing Large Object
ALTER TABLE ${tableName} ADD COLUMN ${columnName} OID;

-- 2. Attach cleanup trigger to prevent orphan catalog bloat
CREATE OR REPLACE FUNCTION trg_cleanup_${tableName}_${columnName}()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'UPDATE') THEN
        IF (OLD.${columnName} IS NOT NULL AND OLD.${columnName} IS DISTINCT FROM NEW.${columnName}) THEN
            PERFORM lo_unlink(OLD.${columnName});
        END IF;
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        IF (OLD.${columnName} IS NOT NULL) THEN
            PERFORM lo_unlink(OLD.${columnName});
        END IF;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_temp;

CREATE TRIGGER trg_${tableName}_${columnName}_unlink
BEFORE UPDATE OF ${columnName} OR DELETE ON ${tableName}
FOR EACH ROW EXECUTE FUNCTION trg_cleanup_${tableName}_${columnName}();
      `.trim();

      return {
        recommendedStorage: 'LARGE_OBJECT',
        maxByteSize: estimatedMaxBytes,
        warnings,
        recommendedDDL: ddl,
      };
    }

    // Size exceeds 5MB: Must use S3/Object Storage
    warnings.push(
      `File size (${(estimatedMaxBytes / 1024 / 1024).toFixed(1)}MB) exceeds 5MB relational database threshold. Storing in database causes severe WAL amplification and backup degradation.`
    );
    return {
      recommendedStorage: 'EXTERNAL_S3',
      maxByteSize: estimatedMaxBytes,
      warnings,
      recommendedDDL: `
-- Store only object metadata in PostgreSQL. Binary asset belongs in S3 / Cloudflare R2.
ALTER TABLE ${tableName} ADD COLUMN ${columnName}_s3_key TEXT NOT NULL;
ALTER TABLE ${tableName} ADD COLUMN ${columnName}_sha256 TEXT NOT NULL;
ALTER TABLE ${tableName} ADD COLUMN ${columnName}_byte_size BIGINT NOT NULL;
ALTER TABLE ${tableName} ADD COLUMN ${columnName}_content_type TEXT NOT NULL;
      `.trim(),
    };
  }

  /**
   * Generates a SQL query for non-blocking batched orphan detection.
   */
  public static generateOrphanAuditSQL(referencingTables: Array<{ table: string; column: string }>): string {
    const unionClauses = referencingTables
      .map((ref) => `SELECT ${ref.column} AS referenced_oid FROM ${ref.table} WHERE ${ref.column} IS NOT NULL`)
      .join('\nUNION\n');

    return `
WITH referenced_lobs AS (
    ${unionClauses}
)
SELECT 
    m.oid AS orphan_oid,
    COALESCE(SUM(octet_length(lo.data)), 0)::bigint AS estimated_bytes
FROM pg_largeobject_metadata m
LEFT JOIN referenced_lobs r ON m.oid = r.referenced_oid
LEFT JOIN pg_largeobject lo ON m.oid = lo.loid
WHERE r.referenced_oid IS NULL
GROUP BY m.oid
LIMIT 500;
    `.trim();
  }
}
```

---

## 5. Cross-Runtime Telemetry Sentinels & Implementation Patterns

### 5.1 Golang (`jackc/pgx/v5`): Chunked Streaming & Non-Blocking Orphan Purger
In Go, using `pgx`, Large Objects MUST be manipulated through `pgx.Tx.LargeObjects()` inside an active transaction. Streaming uses $O(1)$ memory by piping directly via `io.Copy()`:

```go
package store

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type LargeObjectManager struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewLargeObjectManager(pool *pgxpool.Pool, logger *slog.Logger) *LargeObjectManager {
	return &LargeObjectManager{pool: pool, logger: logger}
}

// WriteStream stores an io.Reader into pg_largeobject using 64KB bounded chunks.
func (m *LargeObjectManager) WriteStream(ctx context.Context, r io.Reader) (uint32, error) {
	tx, err := m.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Set statement timeout to eliminate lock hangs
	if _, err := tx.Exec(ctx, "SET LOCAL statement_timeout = '30000ms';"); err != nil {
		return 0, fmt.Errorf("set timeout: %w", err)
	}

	los := tx.LargeObjects()
	oid, err := los.Create(ctx, 0)
	if err != nil {
		return 0, fmt.Errorf("create large object: %w", err)
	}

	obj, err := los.Open(ctx, oid, pgx.LargeObjectModeWrite)
	if err != nil {
		return 0, fmt.Errorf("open large object for writing: %w", err)
	}

	// 64KB bounded chunk streaming buffer
	buf := make([]byte, 64*1024)
	if _, err := io.CopyBuffer(obj, r, buf); err != nil {
		return 0, fmt.Errorf("streaming write failed: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("commit large object: %w", err)
	}

	return oid, nil
}

// ReadStream pipes an LOB to an io.Writer with O(1) RAM usage.
func (m *LargeObjectManager) ReadStream(ctx context.Context, oid uint32, w io.Writer) error {
	tx, err := m.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin read transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	los := tx.LargeObjects()
	obj, err := los.Open(ctx, oid, pgx.LargeObjectModeRead)
	if err != nil {
		return fmt.Errorf("open large object oid %d: %w", oid, err)
	}

	buf := make([]byte, 64*1024)
	if _, err := io.CopyBuffer(w, obj, buf); err != nil {
		return fmt.Errorf("streaming read failed: %w", err)
	}

	return tx.Commit(ctx)
}

// PurgeOrphansBatched sweeps unreferenced Large Objects in discrete batches of 500
// protected by non-blocking advisory locks to eliminate lock convoys and connection exhaustion.
func (m *LargeObjectManager) PurgeOrphansBatched(ctx context.Context, batchSize int) (int, error) {
	conn, err := m.pool.Acquire(ctx)
	if err != nil {
		return 0, fmt.Errorf("acquire connection: %w", err)
	}
	defer conn.Release()

	// Acquire advisory lock to prevent concurrent cleaner collisions
	var acquired bool
	err = conn.QueryRow(ctx, "SELECT pg_try_advisory_lock(hashtext('pg_lob_orphan_cleaner'));").Scan(&acquired)
	if err != nil || !acquired {
		m.logger.WarnContext(ctx, "orphan cleaner skipped: advisory lock currently held")
		return 0, nil
	}
	defer func() {
		_, _ = conn.Exec(context.Background(), "SELECT pg_advisory_unlock(hashtext('pg_lob_orphan_cleaner'));")
	}()

	// Find orphaned OIDs (example with attachments table)
	query := fmt.Sprintf(`
		SELECT m.oid 
		FROM pg_largeobject_metadata m
		LEFT JOIN attachments a ON m.oid = a.lob_oid
		WHERE a.lob_oid IS NULL
		LIMIT %d;`, batchSize)

	rows, err := conn.Query(ctx, query)
	if err != nil {
		return 0, fmt.Errorf("querying orphaned lobs: %w", err)
	}
	defer rows.Close()

	var oids []uint32
	for rows.Next() {
		var o uint32
		if err := rows.Scan(&o); err != nil {
			return 0, err
		}
		oids = append(oids, o)
	}

	purgedCount := 0
	for _, targetOid := range oids {
		// Unlink in individual transactions to prevent transaction catalog lock accumulation
		_, unlinkErr := conn.Exec(ctx, "SELECT lo_unlink($1);", targetOid)
		if unlinkErr == nil {
			purgedCount++
		}
		time.Sleep(2 * time.Millisecond) // Throttling to protect WAL rate
	}

	m.logger.InfoContext(ctx, "batched orphan purge completed", "purged", purgedCount)
	return purgedCount, nil
}
```

### 5.2 TypeScript / Node.js: Chunked Streaming with Bounded HTTP Piping
```typescript
import { Pool, PoolClient } from 'pg';
import { Readable, Writable } from 'node:stream';

export class NodeLargeObjectStreamer {
  constructor(private readonly pool: Pool) {}

  /**
   * Streams a binary Readable stream directly into a PostgreSQL Large Object.
   */
  public async writeStream(stream: Readable): Promise<number> {
    const client: PoolClient = await this.pool.connect();
    try {
      await client.query('BEGIN;');
      await client.query("SET LOCAL statement_timeout = '30000ms';");

      const createRes = await client.query<{ oid: number }>('SELECT lo_creat(0) AS oid;');
      const oid = createRes.rows[0].oid;

      // Mode: INV_WRITE = 0x00020000
      const openRes = await client.query<{ fd: number }>('SELECT lo_open($1, 131072) AS fd;', [oid]);
      const fd = openRes.rows[0].fd;

      // Stream in 64KB bounded chunks
      for await (const chunk of stream) {
        const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        await client.query('SELECT lowrite($1, $2);', [fd, buffer]);
      }

      await client.query('SELECT lo_close($1);', [fd]);
      await client.query('COMMIT;');
      return oid;
    } catch (err) {
      await client.query('ROLLBACK;');
      throw err;
    } finally {
      client.release();
    }
  }
}
```

### 5.3 Python (`asyncpg`): Safe Large Object Retrieval & Orphan Audit Sentinel
```python
import asyncpg
import asyncio
import logging

logger = logging.getLogger("pg_lob_sentinel")

async def audit_lob_orphans(pool: asyncpg.Pool) -> dict:
    """
    Audits pg_largeobject_metadata against application tables and returns orphan metrics.
    """
    query = """
    WITH app_refs AS (
        SELECT lob_oid FROM document_attachments WHERE lob_oid IS NOT NULL
        UNION
        SELECT avatar_oid FROM user_profiles WHERE avatar_oid IS NOT NULL
    )
    SELECT 
        COUNT(m.oid) FILTER (WHERE r.lob_oid IS NULL) AS orphan_count,
        COUNT(m.oid) AS total_count
    FROM pg_largeobject_metadata m
    LEFT JOIN app_refs r ON m.oid = r.lob_oid;
    """
    async with pool.acquire() as conn:
        row = await conn.fetchrow(query)
        orphan_count = row["orphan_count"] or 0
        total_count = row["total_count"] or 0
        orphan_ratio = (orphan_count / total_count) if total_count > 0 else 0.0

        metrics = {
            "total_lobs": total_count,
            "orphan_count": orphan_count,
            "orphan_ratio": orphan_ratio,
            "alert": orphan_ratio > 0.05,
        }
        if metrics["alert"]:
            logger.warning("Large Object orphan ratio exceeds 5%%: %s", metrics)
        return metrics
```

### 5.4 Rust (`tokio-postgres`): Chunked LOB Reader Sentinel
```rust
use tokio_postgres::{Client, Error, Transaction};
use std::io::Write;

pub struct LargeObjectReader;

impl LargeObjectReader {
    pub async fn stream_lob_to_writer<W: Write>(
        client: &mut Client,
        oid: u32,
        writer: &mut W,
    ) -> Result<u64, Error> {
        let tx = client.transaction().await?;
        tx.execute("SET LOCAL statement_timeout = '30000ms';", &[]).await?;

        // Open LOB in read mode (0x00040000)
        let open_row = tx.query_one("SELECT lo_open($1, 262144) AS fd;", &[&(oid as i64)]).await?;
        let fd: i32 = open_row.get("fd");

        let mut total_bytes: u64 = 0;
        let chunk_size: i32 = 65536; // 64KB chunks

        loop {
            let read_row = tx.query_one("SELECT loread($1, $2) AS chunk;", &[&fd, &chunk_size]).await?;
            let chunk: Vec<u8> = read_row.get("chunk");
            if chunk.is_empty() {
                break;
            }
            total_bytes += chunk.len() as u64;
            writer.write_all(&chunk).expect("write failed");
        }

        tx.query_one("SELECT lo_close($1);", &[&fd]).await?;
        tx.commit().await?;

        Ok(total_bytes)
    }
}
```

---

## 6. 6-State Large Object Lifecycle Finite-State Machine (FSM)

```
┌───────────────────────────────────────────────────────────────────────────────────────┐
│                   6-STATE LARGE OBJECT LIFECYCLE FINITE-STATE MACHINE                 │
├───────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                       │
│  [1. UNQUALIFIED] ───(Storage Sizing Matrix)───► [2. QUALIFIED_STORAGE]               │
│                                                   ├── Size <= 256KB: BYTEA (Exit)     │
│                                                   ├── Size >= 5MB: External S3 (Exit) │
│                                                   └── Size 256KB-5MB: LOB Pipeline    │
│                                                                                       │
│  [2. QUALIFIED_STORAGE] ──(Attach Unlink Trigger)──► [3. ACTIVE_STREAMING]            │
│                                                        │                              │
│                                                (Relational Delete)                    │
│                                                        ▼                              │
│  [5. SURGICALLY_PURGED] ◄──(Batched lo_unlink)─── [4. ORPHAN_DETECTED]                │
│            ▲                                                                          │
│            └──────────────(Trigger Fires Successfully)────────────────────────────────┤
│                                                                                       │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

To guarantee that no schema migration or application code introduces catalog bloat or OOM crashes, every automated PR must pass this 6-Gate DoD Matrix:

1. **Gate 1: Storage Qualification Gate**: Any pull request introducing a column intended to store files $> 5\text{MB}$ inside PostgreSQL (`bytea` or `OID`) fails CI immediately. External object storage (S3 / R2) must be utilized.
2. **Gate 2: Unlinking Trigger Coverage Gate**: 100% of tables containing `OID` columns referencing Large Objects MUST have an active `BEFORE UPDATE OF ... OR DELETE` trigger executing `lo_unlink()`.
3. **Gate 3: Memory Boundary & Chunked Streaming Gate**: All application endpoints handling Large Objects must use chunked streams ($64\text{KB} \le \text{Buffer} \le 128\text{KB}$). Loading entire LOBs into contiguous memory via single-call buffers is blocked by static AST analysis.
4. **Gate 4: Zero Orphan Catalog Invariant**: In CI test suites executing CRUD workflows, the count of unreferenced rows in `pg_largeobject_metadata` after tests execute MUST strictly equal `0`.
5. **Gate 5: Non-Blocking Purge Fencing Gate**: Any background job or script invoking `lo_unlink` must acquire a transaction-scoped advisory lock (`pg_try_advisory_lock`), enforce `LIMIT <= 500`, and set `lock_timeout <= 2000ms`.
6. **Gate 6: Logical Replication Parity Gate**: Tables with `OID` columns are verified against active publications (`pg_publication_tables`). If an OID table is published to a subscriber, CI asserts that the subscriber has an external artifact sync mechanism to prevent broken replica reads.
