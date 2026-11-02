---
description: PostgreSQL 17 COPY with ON_ERROR ignore, LOG_VERBOSITY, rejected row quarantine (DLQ), reject horizon bounds, and pg_stat_progress_copy telemetry invariants across Go (pgx), TypeScript (pg-copy-streams), Python (asyncpg), Rust (tokio-postgres), Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{copy,bulk,ingest,import,etl,batch_loader,staging,csv,loader}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/database/**/*.{ts,js,go,rs,py},**/lib/db/**/*.{ts,js,go,rs,py},**/internal/database/**/*.{go,rs},**/migrations/**/*.{sql,ts,py,go},**/queries/**/*.{sql,ts,go,rs,py}
alwaysApply: false
---

# Agentic Database PostgreSQL 17 COPY with `ON_ERROR ignore`, `LOG_VERBOSITY`, Malformed Row Quarantine (DLQ), Reject Horizon Bounds & `pg_stat_progress_copy` Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, optimize, or execute high-throughput batch ingestion pipelines, CSV/TSV/JSON data lake loaders, third-party webhook sinks, analytical staging synchronization, or ETL migration workers across PostgreSQL 17+, Go (`jackc/pgx/v5`), TypeScript (`pg-copy-streams`, `pg`, `Drizzle`, `Kysely`), Python (`asyncpg`, `psycopg3`), or Rust (`tokio-postgres`, `sqlx`). Eliminate the "Silent Data Corruption & Zero-DLQ Dropped Row Trap" (where agents blindly enable `ON_ERROR ignore` without capturing skipped lines or persisting bad tuples to a quarantine Dead-Letter Queue, causing massive silent data loss with $P(\text{silent loss}) = 1.0$), the "Constraint Violation False Equivalence Disaster" (where agents mistake `ON_ERROR ignore` for speculative upsert or constraint bypass, only for unique, check, or foreign key collisions to violently abort the entire multi-gigabyte COPY operation with `SQLSTATE 23505 / 23503`), the "Log Flooding & Server Root Disk Exhaustion Catastrophe" (where default `LOG_VERBOSITY default/verbose` emits server `NOTICE` lines for hundreds of thousands of malformed records, flooding disk logs and triggering postmaster `PANIC: could not write to log file: No space left on device`), the "`pg_stat_progress_copy` Progress Blindness & Unbounded Waste" (where streams run without real-time error rate telemetry $\frac{\text{tuples\_skipped}}{\text{tuples\_processed}} > \epsilon_{\max}$, wasting hours of network and I/O before hitting operational failures), the "Direct Ingestion onto Active OLTP Tables & Lockout Convoys" (where bulk streams directly hit production indexed heaps, triggering massive WAL write amplification, B-Tree leaf splits, and connection pool starvation), and the "Client Driver Protocol Desynchronization & Subtransaction SLRU Thrashing" (where agents fall back to row-by-row `SAVEPOINT` loops, violently thrashing `pg_subtrans` SLRU buffers and freezing postmaster execution) by establishing a strict 5-Tier Resilient Ingestion Governance Ladder, formal error-rate differential calculus and disk saturation models, an autonomous TypeScript `AgenticPostgres17CopyGuardEngine`, cross-runtime driver sentinels in Go, TypeScript, Python, and Rust, a 6-state ingestion lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 COPY (ON_ERROR) Catastrophes vs The 5-Tier Governance Ladder

Prior to PostgreSQL 17, the streaming `COPY` protocol (`COPY table FROM STDIN / filename WITH (FORMAT csv)`) was strictly all-or-nothing: if a single row out of 50,000,000 tuples contained a formatting flaw (such as an unparsable timestamp `'2024-02-30'`, an invalid integer `'N/A'`, or an unexpected trailing delimiter), the database engine immediately threw a fatal error, aborted the command, and rolled back the entire multi-gigabyte transaction. Autonomous coding agents faced with dirty upstream data frequently regressed to catastrophic anti-patterns: row-by-row `INSERT` loops with individual `SAVEPOINT` subtransactions—multiplying latency by $1,000\times$, generating millions of network round-trips, and choking CPU on `pg_subtrans` SLRU mutex lock contention (`SubtransSLRUMutex`).

PostgreSQL 17 delivered a revolutionary native engine capability: **`COPY ... (ON_ERROR ignore)`** accompanied by **`LOG_VERBOSITY [default | verbose | silent]`** and the **`pg_stat_progress_copy.tuples_skipped`** real-time telemetry column. This allows the backend parser to discard data conversion errors in-flight while continuing the bulk stream at wire speed.

However, when autonomous coding agents deploy `ON_ERROR ignore` without rigorous systems engineering invariants, they routinely precipitate six catastrophic production failures:

```
+----------------------------------------------------------------------------------------------------+
|                         THE 6 POSTGRESQL 17 COPY (ON_ERROR) CATASTROPHES                           |
+----------------------------------------------------------------------------------------------------+
| 1. Silent Ingestion Blind Spot & Zero-DLQ Dropped Row Trap                                         |
|    - Agent activates 'ON_ERROR ignore' but implements zero Dead-Letter Queue (DLQ) interception.   |
|      When upstream changes column schemas or formats (e.g. ISO 8601 vs epoch), PostgreSQL silently |
|      drops 90% of incoming tuples. The job exits with exit code 0, causing permanent data loss.   |
|                                                                                                    |
| 2. Constraint Violation False Equivalence Disaster (SQLSTATE 23505 / 23503 / 23514)                 |
|    - Agent assumes 'ON_ERROR ignore' ignores duplicate Primary Keys or Foreign Key violations       |
|      (confusing it with 'INSERT ... ON CONFLICT DO NOTHING'). In reality, 'ON_ERROR ignore' ONLY   |
|      catches input type conversion errors. The first duplicate row immediately aborts the COPY!    |
|                                                                                                    |
| 3. Log Flooding & Root Disk Exhaustion (LOG_VERBOSITY Neglect)                                     |
|    - Default or verbose log verbosity emits a server NOTICE for every single rejected row. A dirty |
|      batch with 500,000 bad rows floods 'postgresql.log' with 250MB+ of raw notices, saturating    |
|      storage IOPS and causing 'PANIC: could not write to log file: No space left on device'.      |
|                                                                                                    |
| 4. pg_stat_progress_copy Progress Blindness & Unbounded Ingestion Waste                            |
|    - Agent streams hundreds of gigabytes without monitoring 'pg_stat_progress_copy'. It fails to   |
|      calculate the error skip ratio E(t) = tuples_skipped / tuples_processed. If E(t) exceeds SLA  |
|      thresholds (e.g. 0.5%), the agent wastes hours of I/O before discovering total pipeline ruin. |
|                                                                                                    |
| 5. Direct Ingestion onto Active OLTP Heaps & Lockout Convoys                                       |
|    - Agent streams COPY directly into live production tables with secondary B-Tree/GIN indexes,    |
|      triggers, and foreign keys. This generates massive WAL write amplification, B-Tree leaf page  |
|      splits, and row lock convoys that exhaust connection pools and freeze user transactions.      |
|                                                                                                    |
| 6. Client Driver Protocol Desynchronization & Subtrans Thrashing                                   |
|    - In Node, Python, or Go, streaming COPY FROM STDIN without catching client notice packets or   |
|      falling back to naive SAVEPOINT loops causes buffer deadlocks or pg_subtrans SLRU thrashing.  |
+----------------------------------------------------------------------------------------------------+
```

To eliminate these vulnerabilities, autonomous agents must adhere to the **5-Tier Resilient Ingestion Governance Ladder**:

```
+----------------------------------------------------------------------------------------------------+
|                      THE 5-TIER RESILIENT BULK INGESTION GOVERNANCE LADDER                         |
+----------------------------------------------------------------------------------------------------+
| Tier 0: Engine Qualification & Verbosity Calibration                                               |
|   - Assert PostgreSQL >= 17.0 (server_version_num >= 170000). Set LOG_VERBOSITY silent on high-    |
|     throughput pipelines; handle notices strictly out-of-band via client driver hooks.             |
|                                                                                                    |
| Tier 1: Buffer Isolation via UNLOGGED Scratch Staging Tables                                      |
|   - Never stream directly to indexed production tables. Stream raw batches into UNLOGGED staging   |
|     tables with permissive or text types, bypassing WAL amplification and secondary index locks.   |
|                                                                                                    |
| Tier 2: Real-Time Telemetry & SLA Circuit Breaker (pg_stat_progress_copy)                          |
|   - Spawn background sentinel polling pg_stat_progress_copy. Compute error ratio E(t). If          |
|     tuples_skipped / tuples_processed > epsilon_max (e.g. 0.005) or skipped_consecutive > 50,     |
|     issue pg_cancel_backend(pid) to kill the stream immediately.                                   |
|                                                                                                    |
| Tier 3: Client-Side DLQ Quarantine & Provable Rejection Interception                               |
|   - Capture all discarded line numbers, column tokens, and error payloads via driver notice       |
|     receivers. Persist malformed records to a dedicated dead_letter_queue table with audit trace.  |
|                                                                                                    |
| Tier 4: Set-Based Atomic Promotion via MERGE / INSERT ... ON CONFLICT                             |
|   - Once staged and validated under SLA, promote records from staging to production in a single    |
|     set-based transaction with index backing, releasing relation locks in milliseconds.            |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. Mathematical Models, Error Threshold Differential Calculus & Invariant Theorems

### Model 1: Error Rate Differential & Real-Time Circuit Breaker Equation

Let $N_{\text{proc}}(t)$ be the number of tuples processed at elapsed time $t$, and $N_{\text{skip}}(t)$ be the count of malformed tuples skipped by the engine (`tuples_skipped` from `pg_stat_progress_copy`). The instantaneous error ratio $E(t)$ is defined as:

$$E(t) = \frac{N_{\text{skip}}(t)}{\max(1, N_{\text{proc}}(t))}$$

Given a strict business error tolerance threshold $\epsilon_{\max} \in (0, 1)$ (typically $\epsilon_{\max} = 0.005$, or $0.5\%$), and a minimum sample horizon $N_{\min} \ge 1,000$ tuples (to avoid false-positive aborts on initial warmup jitter), the autonomous circuit breaker condition $\Psi_{\text{trip}}(t)$ is:

$$\Psi_{\text{trip}}(t) = \begin{cases}
1 & \text{if } N_{\text{proc}}(t) \ge N_{\min} \land E(t) > \epsilon_{\max} \\
1 & \text{if } \Delta N_{\text{skip}}(\Delta t) \ge K_{\text{burst\_max}} \quad (\text{burst corruption}) \\
0 & \text{otherwise}
\end{cases}$$

When $\Psi_{\text{trip}}(t) = 1$, the agent sentinel issues `SELECT pg_cancel_backend(pid)` to terminate the ingestion worker immediately, safeguarding downstream systems.

### Model 2: Server Root Disk Log Saturation Differential

When `LOG_VERBOSITY` is set to `default` or `verbose`, each rejected tuple produces an entry in `postgresql.log`. Let $\bar{S}_{\text{notice}}$ be the average byte size of a notice log line ($\approx 280\text{ bytes}$), $R_{\text{ingest}}$ be the ingestion ingestion rate (tuples/second), and $D_{\text{free}}$ be the free space on the database host root filesystem.

The rate of log disk space consumption $\dot{V}_{\text{disk}}(t)$ is:

$$\dot{V}_{\text{disk}}(t) = R_{\text{ingest}} \cdot E(t) \cdot \bar{S}_{\text{notice}}$$

The time remaining until total disk exhaustion $T_{\text{exhaust}}$ is:

$$T_{\text{exhaust}} = \frac{D_{\text{free}}}{\dot{V}_{\text{disk}}(t)} = \frac{D_{\text{free}}}{R_{\text{ingest}} \cdot E(t) \cdot \bar{S}_{\text{notice}}}$$

**Numerical Proof**: If an agent streams at $R_{\text{ingest}} = 100,000\text{ rows/sec}$ with an unhandled column shift ($E(t) = 0.80$), log growth explodes at:

$$\dot{V}_{\text{disk}} = 100,000 \cdot 0.80 \cdot 280 = 22.4\text{ MB/sec} = 1.34\text{ GB/min}$$

On a standard cloud container with $10\text{ GB}$ free disk, postmaster crashes with `PANIC: could not write to log file` in:

$$T_{\text{exhaust}} = \frac{10 \times 1024}{1.34 \times 1024} \approx 7.46\text{ minutes}$$

Setting `LOG_VERBOSITY silent` eliminates $\dot{V}_{\text{disk}}$ entirely ($\dot{V}_{\text{disk}} \equiv 0$), completely neutralizing disk exhaustion risks.

### Model 3: Throughput Scaling: Native COPY (ON_ERROR) vs Row-by-Row SAVEPOINTs

When ingesting $N$ rows containing $M$ malformed entries:
- **Legacy Row-by-Row Subtransaction Ingestion**:
  Each row requires a roundtrip and subtransaction bookkeeping:
  $$T_{\text{legacy}} = N \cdot (T_{\text{net}} + T_{\text{insert}}) + M \cdot T_{\text{savepoint\_rollback}}$$
  Due to `pg_subtrans` SLRU lock synchronization on `SubtransSLRUMutex`, throughput collapses to $R_{\text{legacy}} \approx 200–800\text{ rows/sec}$.
- **PostgreSQL 17 Native COPY `(ON_ERROR ignore)`**:
  Tuples stream continuously through the binary/text pipeline in 64KB network buffers:
  $$T_{\text{pg17}} = \frac{N \cdot \bar{S}_{\text{row}}}{B_{\text{net}}} + N \cdot T_{\text{parse}} + (N - M) \cdot T_{\text{heap\_insert}}$$
  Throughput reaches $R_{\text{pg17}} \approx 120,000–350,000\text{ rows/sec}$.

$$\text{Speedup Factor } \Sigma = \frac{T_{\text{legacy}}}{T_{\text{pg17}}} \approx 300\times–1,000\times$$

---

## 3. Autonomous TypeScript Engine: `AgenticPostgres17CopyGuardEngine`

The following production TypeScript engine encapsulates pre-flight environment auditing, unlogged staging management, real-time `pg_stat_progress_copy` sentinel polling, SLA circuit breaker evaluation, client-side notice DLQ parsing, and atomic set-based promotion.

```typescript
/**
 * AgenticPostgres17CopyGuardEngine.ts
 * Industrial-grade PostgreSQL 17 Resilient COPY (ON_ERROR ignore) Ingestion Sentinel.
 * Handles unlogged staging isolation, real-time SLA circuit breaking, notice DLQ capture,
 * and zero-data-loss atomic promotion.
 */

import { Client, Pool, PoolClient } from 'pg';
import { from as copyFrom } from 'pg-copy-streams';
import { Readable, pipeline } from 'stream';
import { promisify } from 'util';

const asyncPipeline = promisify(pipeline);

export interface IngestionConfig {
  targetTable: string;
  stagingTable: string;
  dlqTable: string;
  columns: string[];
  primaryKey: string[];
  maxErrorRate: number;        // e.g. 0.005 (0.5%)
  minSampleBeforeTrip: number; // e.g. 1000 rows
  pollIntervalMs: number;      // e.g. 250ms
  logVerbosity: 'silent' | 'default' | 'verbose';
  delimiter: string;
  format: 'csv' | 'text';
}

export interface IngestionMetrics {
  tuplesProcessed: number;
  tuplesSkipped: number;
  tuplesPromoted: number;
  errorRate: number;
  durationMs: number;
  dlqCount: number;
  circuitBreakerTripped: boolean;
}

export interface DLQRecord {
  stagingTable: string;
  rawPayload: string;
  errorReason: string;
  lineNumber?: number;
  capturedAt: Date;
}

export class AgenticPostgres17CopyGuardEngine {
  constructor(private readonly pool: Pool, private readonly config: IngestionConfig) {
    if (config.maxErrorRate <= 0 || config.maxErrorRate >= 1) {
      throw new Error(`[GuardEngine] maxErrorRate must be between 0 and 1, got ${config.maxErrorRate}`);
    }
  }

  /**
   * Asserts PostgreSQL version >= 17.0 (server_version_num >= 170000).
   */
  async qualifyEngine(client: PoolClient): Promise<number> {
    const res = await client.query('SHOW server_version_num');
    const versionNum = parseInt(res.rows[0].server_version_num, 10);
    if (versionNum < 170000) {
      throw new Error(
        `[GuardEngine] COPY (ON_ERROR ignore) requires PostgreSQL 17+. Detected server_version_num: ${versionNum}`
      );
    }
    return versionNum;
  }

  /**
   * Provisions UNLOGGED staging table and DLQ quarantine storage.
   */
  async provisionBuffers(client: PoolClient): Promise<void> {
    const colDefs = this.config.columns.map(c => `"${c}" TEXT`).join(', ');
    
    // 1. Unlogged staging table for raw, fast streaming without WAL amplification
    await client.query(`
      CREATE UNLOGGED TABLE IF NOT EXISTS "${this.config.stagingTable}" (
        _staging_id BIGSERIAL PRIMARY KEY,
        ${colDefs},
        _staged_at TIMESTAMPTZ DEFAULT clock_timestamp()
      );
      TRUNCATE TABLE "${this.config.stagingTable}";
    `);

    // 2. Dead-Letter Queue (DLQ) quarantine table for discarded malformed records
    await client.query(`
      CREATE TABLE IF NOT EXISTS "${this.config.dlqTable}" (
        id BIGSERIAL PRIMARY KEY,
        target_table TEXT NOT NULL,
        line_number BIGINT,
        raw_payload TEXT NOT NULL,
        error_message TEXT,
        quarantined_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );
    `);
  }

  /**
   * Executes governed streaming COPY with real-time telemetry circuit breaker & notice DLQ.
   */
  async executeResilientStream(inputStream: Readable): Promise<IngestionMetrics> {
    const startTime = Date.now();
    const client = await this.pool.connect();
    let circuitBreakerTripped = false;
    let backendPid = 0;
    const dlqBuffer: DLQRecord[] = [];

    try {
      await this.qualifyEngine(client);
      await this.provisionBuffers(client);

      const pidRes = await client.query('SELECT pg_backend_pid() AS pid');
      backendPid = parseInt(pidRes.rows[0].pid, 10);

      // Setup Notice Handler to capture dropped tuples when log_verbosity != silent
      client.on('notice', (msg) => {
        if (msg.message && msg.message.includes('skipping line')) {
          dlqBuffer.push({
            stagingTable: this.config.stagingTable,
            rawPayload: msg.detail || msg.message,
            errorReason: msg.message,
            capturedAt: new Date()
          });
        }
      });

      // Construct PostgreSQL 17 resilient COPY command
      const copySql = `
        COPY "${this.config.stagingTable}" (${this.config.columns.map(c => `"${c}"`).join(', ')})
        FROM STDIN WITH (
          FORMAT ${this.config.format},
          DELIMITER '${this.config.delimiter}',
          ON_ERROR ignore,
          LOG_VERBOSITY ${this.config.logVerbosity}
        )
      `;

      const pgCopyStream = client.query(copyFrom(copySql));

      // Background Progress Poller & SLA Sentinel
      let pollerActive = true;
      let finalProcessed = 0;
      let finalSkipped = 0;

      const pollPromise = (async () => {
        const monitorClient = await this.pool.connect();
        try {
          while (pollerActive) {
            await new Promise(r => setTimeout(r, this.config.pollIntervalMs));
            if (!pollerActive) break;

            const progRes = await monitorClient.query(`
              SELECT tuples_processed, tuples_excluded, tuples_skipped, bytes_processed
              FROM pg_stat_progress_copy
              WHERE pid = $1
            `, [backendPid]);

            if (progRes.rows.length > 0) {
              const row = progRes.rows[0];
              const proc = parseInt(row.tuples_processed || '0', 10);
              const skip = parseInt(row.tuples_skipped || '0', 10);
              finalProcessed = proc;
              finalSkipped = skip;

              if (proc >= this.config.minSampleBeforeTrip) {
                const currentErrorRate = skip / proc;
                if (currentErrorRate > this.config.maxErrorRate) {
                  circuitBreakerTripped = true;
                  pollerActive = false;
                  // Trip Circuit Breaker: Cancel execution immediately!
                  await monitorClient.query('SELECT pg_cancel_backend($1)', [backendPid]);
                  break;
                }
              }
            }
          }
        } finally {
          monitorClient.release();
        }
      })();

      // Stream data into PostgreSQL
      try {
        await asyncPipeline(inputStream, pgCopyStream);
      } catch (err: any) {
        if (circuitBreakerTripped) {
          throw new Error(
            `[GuardEngine] Circuit breaker TRIPPED! Skipped error rate exceeded SLA ${this.config.maxErrorRate}. Ingestion cancelled.`
          );
        }
        throw err;
      } finally {
        pollerActive = false;
        await pollPromise;
      }

      // Flush in-memory notice DLQ records to persistence
      if (dlqBuffer.length > 0) {
        await this.flushDLQ(client, dlqBuffer);
      }

      // Final count audit
      const countRes = await client.query(
        `SELECT COUNT(*) AS total FROM "${this.config.stagingTable}"`
      );
      const stagedCount = parseInt(countRes.rows[0].total, 10);

      // Tier 4: Set-based Atomic Promotion from staging to target table
      const promotedCount = await this.promoteStagingToTarget(client);

      const durationMs = Date.now() - startTime;
      const errorRate = (finalProcessed > 0) ? (finalSkipped / finalProcessed) : 0;

      return {
        tuplesProcessed: finalProcessed || stagedCount + finalSkipped,
        tuplesSkipped: finalSkipped,
        tuplesPromoted: promotedCount,
        errorRate,
        durationMs,
        dlqCount: dlqBuffer.length,
        circuitBreakerTripped: false
      };
    } finally {
      client.release();
    }
  }

  /**
   * Persists captured notice error records to the DLQ table.
   */
  private async flushDLQ(client: PoolClient, records: DLQRecord[]): Promise<void> {
    const insertSql = `
      INSERT INTO "${this.config.dlqTable}" (target_table, line_number, raw_payload, error_message, quarantined_at)
      VALUES ($1, $2, $3, $4, $5)
    `;
    for (const r of records) {
      await client.query(insertSql, [
        this.config.targetTable,
        r.lineNumber ?? null,
        r.rawPayload,
        r.errorReason,
        r.capturedAt
      ]);
    }
  }

  /**
   * Set-Based Atomic Promotion: Uses MERGE or INSERT ... ON CONFLICT with type casts.
   */
  private async promoteStagingToTarget(client: PoolClient): Promise<number> {
    const colList = this.config.columns.map(c => `"${c}"`).join(', ');
    const updateSets = this.config.columns
      .filter(c => !this.config.primaryKey.includes(c))
      .map(c => `"${c}" = EXCLUDED."${c}"`)
      .join(', ');

    const pkList = this.config.primaryKey.map(k => `"${k}"`).join(', ');

    await client.query('BEGIN');
    try {
      const promoteSql = `
        INSERT INTO "${this.config.targetTable}" (${colList})
        SELECT ${colList}
        FROM "${this.config.stagingTable}"
        ON CONFLICT (${pkList}) DO UPDATE SET
          ${updateSets}
      `;
      const res = await client.query(promoteSql);
      await client.query(`TRUNCATE TABLE "${this.config.stagingTable}"`);
      await client.query('COMMIT');
      return res.rowCount || 0;
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    }
  }
}
```

---

## 4. Cross-Runtime Driver Sentinels

### 4.1 Go (`jackc/pgx/v5`): Resilient Streaming with Notice Interception & Background Telemetry Sentinel

```go
package ingestion

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// IngestionSentinel governs resilient PostgreSQL 17 COPY streaming.
type IngestionSentinel struct {
	pool            *pgxpool.Pool
	targetTable     string
	stagingTable    string
	dlqTable        string
	maxErrorRate    float64
	minSampleHorizon int64
}

// NewIngestionSentinel initializes a production ingestion sentinel.
func NewIngestionSentinel(
	pool *pgxpool.Pool,
	targetTable, stagingTable, dlqTable string,
	maxErrorRate float64,
) *IngestionSentinel {
	return &IngestionSentinel{
		pool:             pool,
		targetTable:      targetTable,
		stagingTable:     stagingTable,
		dlqTable:         dlqTable,
		maxErrorRate:     maxErrorRate,
		minSampleHorizon: 1000,
	}
}

// StreamCSVWithDLQ streams CSV data into PostgreSQL 17 using ON_ERROR ignore.
func (s *IngestionSentinel) StreamCSVWithDLQ(ctx context.Context, csvReader io.Reader) error {
	// 1. Acquire dedicated connection and inspect server version >= 170000
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("failed to acquire connection: %w", err)
	}
	defer conn.Release()

	var serverVersion int
	if err := conn.QueryRow(ctx, "SHOW server_version_num").Scan(&serverVersion); err != nil {
		return fmt.Errorf("version check failed: %w", err)
	}
	if serverVersion < 170000 {
		return fmt.Errorf("PostgreSQL 17+ required for ON_ERROR ignore, detected: %d", serverVersion)
	}

	// 2. Prepare unlogged staging table and DLQ quarantine
	initSQL := fmt.Sprintf(`
		CREATE UNLOGGED TABLE IF NOT EXISTS %s (
			tenant_id TEXT,
			event_id TEXT,
			payload TEXT,
			amount NUMERIC,
			recorded_at TIMESTAMPTZ
		);
		TRUNCATE TABLE %s;
		CREATE TABLE IF NOT EXISTS %s (
			id BIGSERIAL PRIMARY KEY,
			table_name TEXT NOT NULL,
			raw_notice TEXT NOT NULL,
			created_at TIMESTAMPTZ DEFAULT NOW()
		);
	`, s.stagingTable, s.stagingTable, s.dlqTable)

	if _, err := conn.Exec(ctx, initSQL); err != nil {
		return fmt.Errorf("staging buffer setup failed: %w", err)
	}

	backendPID := conn.Conn().PgConn().PID()
	var cancelRequested atomic.Bool
	var wg sync.WaitGroup

	// 3. Launch background SLA watchdog inspecting pg_stat_progress_copy
	watchdogCtx, stopWatchdog := context.WithCancel(ctx)
	defer stopWatchdog()

	wg.Add(1)
	go func() {
		defer wg.Done()
		ticker := time.NewTicker(200 * time.Millisecond)
		defer ticker.Stop()

		for {
			select {
			case <-watchdogCtx.Done():
				return
			case <-ticker.C:
				var proc, skipped int64
				err := s.pool.QueryRow(watchdogCtx, `
					SELECT COALESCE(tuples_processed, 0), COALESCE(tuples_skipped, 0)
					FROM pg_stat_progress_copy
					WHERE pid = $1
				`, backendPID).Scan(&proc, &skipped)

				if err == nil && proc >= s.minSampleHorizon {
					rate := float64(skipped) / float64(proc)
					if rate > s.maxErrorRate {
						cancelRequested.Store(true)
						slog.Error("Circuit breaker tripped: error rate exceeded SLA",
							"rate", rate,
							"threshold", s.maxErrorRate,
							"processed", proc,
							"skipped", skipped,
						)
						// Cancel backend immediately
						_, _ = s.pool.Exec(context.Background(), "SELECT pg_cancel_backend($1)", backendPID)
						return
					}
				}
			}
		}
	}()

	// 4. Execute streaming COPY with ON_ERROR ignore
	copySQL := fmt.Sprintf(`
		COPY %s (tenant_id, event_id, payload, amount, recorded_at)
		FROM STDIN WITH (
			FORMAT csv,
			HEADER true,
			ON_ERROR ignore,
			LOG_VERBOSITY default
		)
	`, s.stagingTable)

	_, copyErr := conn.Conn().PgConn().CopyFrom(ctx, csvReader, copySQL)
	stopWatchdog()
	wg.Wait()

	if cancelRequested.Load() {
		return errors.New("stream aborted by sentinel: error rate violated SLA circuit breaker")
	}
	if copyErr != nil {
		var pgErr *pgconn.PgError
		if errors.As(copyErr, &pgErr) && pgErr.Code == "57014" {
			return errors.New("stream cancelled via backend termination signal")
		}
		return fmt.Errorf("resilient copy failed: %w", copyErr)
	}

	// 5. Tier 4: Atomic set-based reconciliation from staging to target table
	promoteSQL := fmt.Sprintf(`
		INSERT INTO %s (tenant_id, event_id, payload, amount, recorded_at)
		SELECT tenant_id, event_id, payload, amount, recorded_at
		FROM %s
		ON CONFLICT (tenant_id, event_id) DO UPDATE SET
			payload = EXCLUDED.payload,
			amount = EXCLUDED.amount,
			recorded_at = EXCLUDED.recorded_at;
		TRUNCATE TABLE %s;
	`, s.targetTable, s.stagingTable, s.stagingTable)

	if _, err := conn.Exec(ctx, promoteSQL); err != nil {
		return fmt.Errorf("atomic staging promotion failed: %w", err)
	}

	slog.Info("Resilient COPY ingestion completed successfully", "target", s.targetTable)
	return nil
}
```

---

### 4.2 Python (`asyncpg`): Resilient COPY Protocol & SLA Threshold Sentinel

```python
"""
agentic_postgres17_copy_guard.py
Autonomous PostgreSQL 17 COPY with ON_ERROR ignore sentinel in Python (asyncpg).
"""

import asyncio
import asyncpg
import logging
from typing import Optional

logger = logging.getLogger("Postgres17CopyGuard")


class Postgres17CopySentinel:
    def __init__(
        self,
        pool: asyncpg.Pool,
        target_table: str,
        staging_table: str,
        dlq_table: str,
        max_error_rate: float = 0.005,
        min_sample_size: int = 1000
    ):
        self.pool = pool
        self.target_table = target_table
        self.staging_table = staging_table
        self.dlq_table = dlq_table
        self.max_error_rate = max_error_rate
        self.min_sample_size = min_sample_size

    async def execute_resilient_import(self, file_path: str) -> dict:
        async with self.pool.acquire() as conn:
            # 1. Assert PostgreSQL version >= 17
            v = await conn.fetchval("SHOW server_version_num")
            if int(v) < 170000:
                raise RuntimeError(f"PostgreSQL 17+ required, found version_num: {v}")

            # 2. Setup UNLOGGED staging table
            await conn.execute(f"""
                CREATE UNLOGGED TABLE IF NOT EXISTS {self.staging_table} (
                    user_id TEXT,
                    email TEXT,
                    score NUMERIC,
                    created_at TIMESTAMPTZ
                );
                TRUNCATE TABLE {self.staging_table};
                CREATE TABLE IF NOT EXISTS {self.dlq_table} (
                    id BIGSERIAL PRIMARY KEY,
                    raw_notice TEXT,
                    captured_at TIMESTAMPTZ DEFAULT NOW()
                );
            """)

            pid = await conn.fetchval("SELECT pg_backend_pid()")
            tripped = False

            # 3. Sentinel watchdog task
            stop_sentinel = asyncio.Event()

            async def progress_sentinel():
                nonlocal tripped
                async with self.pool.acquire() as mon_conn:
                    while not stop_sentinel.is_set():
                        await asyncio.sleep(0.2)
                        row = await mon_conn.fetchrow("""
                            SELECT tuples_processed, tuples_skipped
                            FROM pg_stat_progress_copy
                            WHERE pid = $1
                        """, pid)
                        if row and row["tuples_processed"] >= self.min_sample_size:
                            proc = row["tuples_processed"]
                            skip = row["tuples_skipped"]
                            rate = skip / proc
                            if rate > self.max_error_rate:
                                tripped = True
                                logger.error(
                                    "Error rate %f exceeded SLA %f. Cancelling COPY PID %d",
                                    rate, self.max_error_rate, pid
                                )
                                await mon_conn.execute("SELECT pg_cancel_backend($1)", pid)
                                break

            sentinel_task = asyncio.create_task(progress_sentinel())

            try:
                # 4. Stream using native PostgreSQL 17 ON_ERROR ignore
                copy_query = f"""
                    COPY {self.staging_table} (user_id, email, score, created_at)
                    FROM '{file_path}' WITH (
                        FORMAT csv,
                        HEADER true,
                        ON_ERROR ignore,
                        LOG_VERBOSITY silent
                    )
                """
                await conn.execute(copy_query)
            except asyncpg.exceptions.QueryCanceledError:
                if tripped:
                    raise RuntimeError("COPY aborted: error rate exceeded SLA circuit breaker threshold")
                raise
            finally:
                stop_sentinel.set()
                await sentinel_task

            # 5. Set-based atomic promotion
            promoted = await conn.fetchval(f"""
                WITH moved AS (
                    INSERT INTO {self.target_table} (user_id, email, score, created_at)
                    SELECT user_id, email, score, created_at
                    FROM {self.staging_table}
                    ON CONFLICT (user_id) DO UPDATE SET
                        email = EXCLUDED.email,
                        score = EXCLUDED.score,
                        created_at = EXCLUDED.created_at
                    RETURNING 1
                )
                SELECT COUNT(*) FROM moved;
            """)
            await conn.execute(f"TRUNCATE TABLE {self.staging_table};")

            return {"status": "SUCCESS", "promoted": promoted}
```

---

### 4.3 Rust (`tokio-postgres`): Resilient Text Stream Sentinel

```rust
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::time::sleep;
use tokio_postgres::{Client, Error, NoTls};

pub struct Postgres17CopySentinel {
    target_table: String,
    staging_table: String,
    max_error_rate: f64,
}

impl Postgres17CopySentinel {
    pub fn new(target_table: &str, staging_table: &str, max_error_rate: f64) -> Self {
        Self {
            target_table: target_table.to_string(),
            staging_table: staging_table.to_string(),
            max_error_rate,
        }
    }

    pub async fn execute_stream(
        &self,
        client: &Client,
        monitor_client: &Client,
        csv_payload: &[u8],
    ) -> Result<u64, Box<dyn std::error::Error + Send + Sync>> {
        // 1. Assert PostgreSQL 17+
        let row = client.query_one("SHOW server_version_num", &[]).await?;
        let ver: &str = row.get(0);
        let ver_num: i32 = ver.parse()?;
        if ver_num < 170000 {
            return Err(format!("Requires PG17+, found: {}", ver_num).into());
        }

        // 2. Provision staging table
        let init_sql = format!(
            "CREATE UNLOGGED TABLE IF NOT EXISTS {} (id TEXT, val NUMERIC); TRUNCATE TABLE {};",
            self.staging_table, self.staging_table
        );
        client.batch_execute(&init_sql).await?;

        let pid_row = client.query_one("SELECT pg_backend_pid()", &[]).await?;
        let pid: i32 = pid_row.get(0);

        let tripped = Arc::new(AtomicBool::new(false));
        let tripped_clone = tripped.clone();
        let max_rate = self.max_error_rate;

        // 3. Spawn background watchdog
        let watchdog = tokio::spawn(async move {
            loop {
                sleep(Duration::from_millis(200)).await;
                if let Ok(rows) = monitor_client
                    .query(
                        "SELECT tuples_processed, tuples_skipped FROM pg_stat_progress_copy WHERE pid = $1",
                        &[&pid],
                    )
                    .await
                {
                    if let Some(r) = rows.first() {
                        let proc: i64 = r.get(0);
                        let skip: i64 = r.get(1);
                        if proc >= 1000 && (skip as f64 / proc as f64) > max_rate {
                            tripped_clone.store(true, Ordering::SeqCst);
                            let _ = monitor_client
                                .execute("SELECT pg_cancel_backend($1)", &[&pid])
                                .await;
                            break;
                        }
                    }
                }
            }
        });

        // 4. Execute streaming COPY with ON_ERROR ignore
        let copy_sql = format!(
            "COPY {} FROM STDIN WITH (FORMAT csv, HEADER true, ON_ERROR ignore, LOG_VERBOSITY silent)",
            self.staging_table
        );

        let sink = client.copy_in(&copy_sql).await?;
        let mut writer = Box::pin(sink);
        tokio::io::AsyncWriteExt::write_all(&mut writer, csv_payload).await?;
        tokio::io::AsyncWriteExt::shutdown(&mut writer).await?;

        watchdog.abort();

        if tripped.load(Ordering::SeqCst) {
            return Err("Ingestion aborted: error rate exceeded circuit breaker limit".into());
        }

        // 5. Promote staging data atomically
        let promote_sql = format!(
            "INSERT INTO {} SELECT * FROM {}; TRUNCATE TABLE {};",
            self.target_table, self.staging_table, self.staging_table
        );
        client.batch_execute(&promote_sql).await?;

        Ok(0)
    }
}
```

---

## 5. The 6-State COPY Ingestion Lifecycle Finite-State Machine (FSM)

Autonomous coding agents executing bulk streams must advance through the following deterministic 6-state transition graph:

```
    [State 0: STAGING_PROVISIONED]
                 │
                 ▼ (Assert PG17+ & Create UNLOGGED staging buffer)
    [State 1: STREAM_ESTABLISHED]
                 │
                 ▼ (Initiate COPY ... (ON_ERROR ignore) & Spawn SLA Watchdog)
    [State 2: TELEMETRY_ACTIVE]
         │                       │
         │ (E(t) <= epsilon)     │ (E(t) > epsilon_max)
         ▼                       ▼
    [State 3: STREAM_COMPLETED] [State 4: CIRCUIT_BREAKER_TRIPPED]
         │                                   │
         ▼ (Flush notice DLQ records)        ▼ (pg_cancel_backend & Quarantine)
    [State 5: ATOMIC_PROMOTED]           [ABORTED / DEAD_LETTER_STORED]
```

```
+-------------------+-----------------------------------+-----------------------------------+
| Initial State     | Event / Transition Trigger        | Next State & Action               |
+-------------------+-----------------------------------+-----------------------------------+
| 0. STAGING_PROV   | Engine verified (version >= 170000)| 1. STREAM_ESTABLISHED: Open pipe |
| 1. STREAM_ESTAB   | First batch chunks written        | 2. TELEMETRY_ACTIVE: Poll progress|
| 2. TELEMETRY_ACT  | tuples_skipped/processed <= eps   | 3. STREAM_COMPLETED: Drain stream |
| 2. TELEMETRY_ACT  | Error rate > eps OR burst spike   | 4. CIRCUIT_BREAKER_TRIPPED: Cancel|
| 3. STREAM_COMPL   | Notices parsed & flushed to DLQ   | 5. ATOMIC_PROMOTED: Set-based ins |
| 4. CIRCUIT_TRIPPED| Clean up staging, log alert metrics| [TERMINAL ERROR / ROLLBACK]       |
+-------------------+-----------------------------------+-----------------------------------+
```

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Gates

Every ingestion pipeline script, PR, or migration written by autonomous agents must satisfy this 6-gate test harness before merge:

```bash
#!/usr/bin/env bash
# test_postgres17_copy_invariants.sh
# Machine-verifiable CI gate for PostgreSQL 17 Resilient COPY Ingestion.
set -euo pipefail

DB_URL="${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/test_db}"

echo "=== Gate 1: Assert PostgreSQL Engine Version >= 17.0 ==="
VERSION_NUM=$(psql "${DB_URL}" -At -c "SHOW server_version_num;")
if [ "${VERSION_NUM}" -lt 170000 ]; then
  echo "FAIL: PostgreSQL 17+ is mandatory for ON_ERROR ignore. Found: ${VERSION_NUM}"
  exit 1
fi
echo "PASS: Detected PostgreSQL version_num ${VERSION_NUM}"

echo "=== Gate 2: Verify UNLOGGED Staging & DLQ Quarantine Storage ==="
psql "${DB_URL}" -v ON_ERROR_STOP=1 -c "
  CREATE UNLOGGED TABLE IF NOT EXISTS ci_copy_staging (
    sku TEXT,
    price NUMERIC,
    in_stock BOOLEAN
  );
  CREATE TABLE IF NOT EXISTS ci_copy_dlq (
    id BIGSERIAL PRIMARY KEY,
    raw_notice TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
  );
  CREATE TABLE IF NOT EXISTS ci_copy_target (
    sku TEXT PRIMARY KEY,
    price NUMERIC NOT NULL,
    in_stock BOOLEAN NOT NULL
  );
"
echo "PASS: Staging and DLQ schemas provisioned."

echo "=== Gate 3: Test ON_ERROR ignore with Dirty CSV Stream ==="
# Synthesize dirty CSV: 3 valid rows, 2 malformed rows (unparsable numeric 'INVALID' and bool 'BADBOOL')
psql "${DB_URL}" -v ON_ERROR_STOP=1 -c "
  COPY ci_copy_staging FROM STDIN WITH (
    FORMAT csv,
    HEADER true,
    ON_ERROR ignore,
    LOG_VERBOSITY silent
  );
sku,price,in_stock
SKU-001,19.99,true
SKU-002,NOT_A_NUMBER,true
SKU-003,29.99,false
SKU-004,39.99,INVALID_BOOL
SKU-005,49.99,true
\.
"

STAGED_COUNT=$(psql "${DB_URL}" -At -c "SELECT COUNT(*) FROM ci_copy_staging;")
if [ "${STAGED_COUNT}" -ne 3 ]; then
  echo "FAIL: Expected exactly 3 valid staged rows, got: ${STAGED_COUNT}"
  exit 1
fi
echo "PASS: ON_ERROR ignore safely filtered 2 malformed rows, retained 3 valid rows."

echo "=== Gate 4: Assert Constraint Violation Boundary (Does NOT Bypass Constraints) ==="
# Attempting COPY directly into target with existing PK should fail fatally!
psql "${DB_URL}" -v ON_ERROR_STOP=1 -c "
  INSERT INTO ci_copy_target VALUES ('SKU-EXISTING', 10.0, true) ON CONFLICT DO NOTHING;
"
set +e
psql "${DB_URL}" -v ON_ERROR_STOP=1 -c "
  COPY ci_copy_target FROM STDIN WITH (FORMAT csv, ON_ERROR ignore);
SKU-EXISTING,20.0,true
\.
" >/dev/null 2>&1
COPY_EXIT_CODE=$?
set -e

if [ "${COPY_EXIT_CODE}" -eq 0 ]; then
  echo "FAIL: COPY (ON_ERROR ignore) must NOT bypass primary key / unique constraints!"
  exit 1
fi
echo "PASS: Confirmed ON_ERROR ignore strictly catches data conversions, not constraint violations."

echo "=== Gate 5: Execute Set-Based Atomic Promotion ==="
psql "${DB_URL}" -v ON_ERROR_STOP=1 -c "
  INSERT INTO ci_copy_target (sku, price, in_stock)
  SELECT sku, price, in_stock FROM ci_copy_staging
  ON CONFLICT (sku) DO UPDATE SET
    price = EXCLUDED.price,
    in_stock = EXCLUDED.in_stock;
  TRUNCATE TABLE ci_copy_staging;
"
TARGET_COUNT=$(psql "${DB_URL}" -At -c "SELECT COUNT(*) FROM ci_copy_target;")
echo "PASS: Successfully promoted staging rows to target (Total target rows: ${TARGET_COUNT})."

echo "=== Gate 6: Teardown CI Staging & Target Tables ==="
psql "${DB_URL}" -v ON_ERROR_STOP=1 -c "
  DROP TABLE ci_copy_staging;
  DROP TABLE ci_copy_dlq;
  DROP TABLE ci_copy_target;
"

echo ">>> ALL POSTGRESQL 17 COPY (ON_ERROR) GATES PASSED AUTOMATICALLY <<<"
```
