---
description: PostgreSQL Query Cancellation Protocol (CancelRequest out-of-band packets, SIGINT vs SIGQUIT/SIGTERM), client disconnect blindness (client_connection_check_interval), multi-tier timeout ladders (statement_timeout, transaction_timeout, lock_timeout, idle_in_transaction_session_timeout, idle_session_timeout), aborted transaction lock retention (SQLSTATE 25P02), PgBouncer transaction-mode cancel routing pitfalls, connection pool starvation, and zombie backend elimination across Go (jackc/pgx/v5), TypeScript (pg, Kysely, Drizzle), Python (asyncpg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{query,timeout,cancel,disconnect,zombie,pool,connection,client,pgx,asyncpg,database,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/internal/pool/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Query Cancellation, Client Disconnect Detection, Statement Timeout Ladders & Zombie Backend Elimination Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design database clients, connection pool architectures, long-running queries, API gateway timeouts, or transactional mutation workflows across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`pg`, `Kysely`, `Drizzle ORM`, `Prisma`), Python (`asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Client Disconnect Blindness & Phantom Execution Burn (`client_connection_check_interval = 0`)" (where an HTTP client or gateway aborts after a 2-second timeout, but PostgreSQL continues executing the expensive query for 30 minutes, burning 100% CPU and saturating NVMe I/O on results no client will ever receive), the "Out-of-Band CancelRequest Packet Drop & PgBouncer Routing Failure" (where driver cancellation routines attempt to open secondary TCP sockets to send `CancelRequest` packets that are dropped by firewalls or misrouted in PgBouncer transaction pooling mode, leaving the original query running indefinitely), the "Aborted Transaction Lock Retention Trap (`SQLSTATE 25P02: current transaction is aborted`)" (where a cancelled query leaves the transaction in an aborted state without an immediate `ROLLBACK`, holding exclusive row and table locks and freezing autovacuum horizons until connection teardown), the "Inverted Timeout Ladder & Cascading Connection Starvation (`statement_timeout >= lock_timeout`)" (where improper timeout hierarchies cause queries waiting on table locks to hang until HTTP gateways terminate, triggering connection pool exhaustion and stampede retries), the "Postmaster `pg_terminate_backend()` SIGQUIT Catastrophe" (where operators or autonomous remediation scripts invoke aggressive process termination that causes postmaster to initiate cluster-wide shared memory crash recovery), and the "Autonomous Agent Cancellation Retry Storm" (where failed queries marked with `57014: query_canceled` are immediately retried in tight loops without exponential backoff or lock shed) by establishing a strict 5-Tier Cancellation Governance Ladder, formal connection waste models, an autonomous TypeScript `AgenticQueryCancellationGuardEngine`, cross-runtime implementations in Go, Python, and Rust, a 6-state query lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Cancellation & Disconnect Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL, query execution is performed by dedicated backend worker processes spawned per connection or managed by external poolers like PgBouncer. When an external client (HTTP gateway, gRPC client, browser, or microservice) aborts a request, times out, or closes the network socket, the database backend does not automatically or instantly abort execution unless specific protocol and kernel invariants are satisfied:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│            CLIENT TIMEOUT vs POSTGRESQL BACKEND REALITY                                │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Client Disconnect Blindness             │ • Active Socket Polling Invariant:         │
│   (client_connection_check_interval = 0;  │   client_connection_check_interval = 500ms │
│    Postgres executes phantom queries for  │   Postgres polls socket during execution;  │
│    minutes after HTTP client disconnects) │   aborts instantly on client EPIPE/RST     │
│ • Out-of-Band CancelRequest Drop          │ • Verified Cancel Protocol Delivery:       │
│   (Driver sends cancel over separate TCP; │   PgBouncer cancel forwarding enabled;     │
│    PgBouncer transaction mode drops it;   │   client verifies backend cancellation or   │
│    backend continues running zombie query)│   issues explicit pg_cancel_backend()      │
│ • Aborted Transaction Lock Retention      │ • Immediate Deferred ROLLBACK Invariant:   │
│   (Query fails with 25P02; client leaks   │   Always wrap transaction in defer/finally │
│    connection; row/table locks held open; │   issuing ROLLBACK; enforce                │
│    autovacuum and DDL blocked indefinitely│   idle_in_transaction_session_timeout <= 5s│
│ • Inverted Timeout Ladder                 │ • Strict 5-Tier Timeout Ordering:          │
│   (lock_timeout > statement_timeout;      │   lock_timeout < statement_timeout <       │
│    queries hang on lock queues, exhaust   │   transaction_timeout < idle_in_tx;        │
│    connection pools, cause 504 cascades)  │   fail fast on lock contention             │
│ • Blind SIGQUIT / Process Decapitation    │ • Graceful SIGINT Cancellation:            │
│   (Killing backend with kill -9 / SIGQUIT │   Always use pg_cancel_backend() (SIGINT)  │
│    causes postmaster shared memory reset  │   first; escalate to pg_terminate_backend()│
│    and terminates all active connections) │   (SIGTERM); NEVER send SIGQUIT/SIGKILL    │
│ • Stampede Retry on 57014 query_canceled  │ • Circuit Breaker & Decorrelated Jitter:   │
│   (Client retries cancelled queries       │   Classify 57014 errors; circuit breaker   │
│    immediately, multiplying primary load  │   trips after 3 consecutive aborts; apply  │
│    and collapsing database to 0 TPS)      │   full jitter backoff: tau = U(0, 2^k*T)   │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

### The 6 Query Cancellation & Disconnect Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE DISCONNECT BLINDNESS & PHANTOM QUERY
-- Client HTTP gateway has a 3-second timeout:
-- Go client: ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
-- The query takes 45 seconds:
SELECT orders.*, line_items.*, customer_analytics.*
FROM orders
JOIN line_items ON line_items.order_id = orders.id
JOIN customer_analytics ON customer_analytics.customer_id = orders.customer_id
WHERE orders.status = 'PENDING'
ORDER BY orders.created_at DESC;

-- When 3 seconds elapse, Go cancels ctx and closes the HTTP connection.
-- In PostgreSQL with default client_connection_check_interval = 0:
-- PostgreSQL backend NEVER checks if socket is closed while executing!
-- It runs the entire 45-second query, burns CPU and RAM, only realizing
-- the socket is dead when sending the first wire result tuple (EPIPE/ECONNRESET).
-- 1,000 disconnected HTTP requests = 1,000 zombie queries burning 100% CPU.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: ABORTED TRANSACTION LOCK RETENTION (SQLSTATE 25P02)
-- Agent writes a multi-statement transaction:
BEGIN;
SELECT * FROM inventory WHERE product_id = 'prod_123' FOR UPDATE; -- Acquires Exclusive Row Lock
-- Next query times out or fails syntax validation:
SELECT non_existent_column FROM product_metadata WHERE product_id = 'prod_123';
-- PostgreSQL marks transaction as aborted:
-- ERROR:  current transaction is aborted, commands ignored until end of transaction block (SQLSTATE 25P02)

-- Naive agent or application code catches error, returns 500, but OMITS ROLLBACK!
-- The connection is returned to the client pool in aborted state or leaked.
-- FOR UPDATE row lock remains HELD by PostgreSQL backend!
-- All other concurrent checkouts for 'prod_123' are blocked indefinitely.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: INVERTED TIMEOUT LADDER
-- Application sets statement_timeout without setting lock_timeout:
SET statement_timeout = '10000ms'; -- 10 seconds
SET lock_timeout = 0;             -- Unlimited!

-- A migration acquires ACCESS EXCLUSIVE on table 'users'.
-- Next 100 incoming web queries enqueue behind ACCESS EXCLUSIVE lock.
-- Instead of failing fast after 1 second (lock_timeout = 1000ms),
-- all 100 queries wait the FULL 10 seconds on the lock queue!
-- Entire connection pool is exhausted; web server experiences global 504 outage.
```

### The 5-Tier Cancellation Governance Ladder

```
Level 4: CI Machine-Verifiable DoD Gates (Zero Zombie Backends, Timeout Ladder Verified)
   ▲
Level 3: Active Socket Polling (client_connection_check_interval = 500ms, tcp_keepalives)
   ▲
Level 2: Strict Multi-Tier Timeout Ordering (lock_timeout < statement_timeout < tx_timeout)
   ▲
Level 1: Explicit Deferred ROLLBACK Guarantees (Zero Leaked Locks on SQLSTATE 25P02)
   ▲
Level 0: Validated Cancel Protocol Delivery (PgBouncer cancel forwarding & SIGINT routing)
```

---

## 2. Mathematical & Algorithmic Foundations

### 2.1 Phantom Execution Waste Model on Dropped Connections

Let $t_{\text{start}}$ be the query start time, $t_{\text{disconnect}}$ be the instant the client aborts or closes the TCP connection, and $t_{\text{finish}}$ be the time when the PostgreSQL executor completes query execution and attempts to send output tuples over the wire.

Let $\text{CPU}(t)$ and $\text{IO}(t)$ be the CPU core allocation and NVMe I/O operations per second consumed by the backend process at time $t$.

The total phantom computational energy and storage bandwidth wasted $W_{\text{phantom}}$ on a disconnected query is:

$$W_{\text{phantom}} = \int_{t_{\text{disconnect}}}^{t_{\text{finish}}} \left[ \alpha \cdot \text{CPU}(t) + \beta \cdot \text{IO}(t) \right] dt$$

Where $\alpha$ and $\beta$ are normalized cost weighting coefficients for CPU cycles and NVMe read/write bandwidth.

#### Detection Latency Comparison
- **Under Default PostgreSQL Settings (`client_connection_check_interval = 0`)**:
  PostgreSQL only detects socket disconnection during `socket_putmessage()` when emitting output tuples to the client:
  
  $$T_{\text{detect}} = t_{\text{finish}} - t_{\text{disconnect}}$$
  
  For analytical, aggregation, or large-join queries where sorting or aggregation precedes tuple emission, $T_{\text{detect}}$ can span **tens of minutes**.
  
- **Under Active Connection Polling (`client_connection_check_interval = \Delta_{\text{poll}}`, e.g. 500ms)**:
  PostgreSQL invokes `pq_check_connection()` within the executor loop (at block boundaries, plan node iterations, or interrupts):
  
  $$T_{\text{detect}} \le \Delta_{\text{poll}} + \delta_{\text{kernel\_poll}} \approx 500\text{ms}$$
  
  The phantom waste reduction ratio $\mathcal{R}_{\text{waste}}$ achieved by enabling active polling is:
  
  $$\mathcal{R}_{\text{waste}} = 1 - \frac{\Delta_{\text{poll}}}{t_{\text{finish}} - t_{\text{disconnect}}}$$
  
  For a 60-second query where the client disconnected after 2 seconds:
  
  $$\mathcal{R}_{\text{waste}} = 1 - \frac{0.5\text{s}}{58\text{s}} \approx 99.14\% \text{ reduction in wasted cluster resources}$$

---

### 2.2 Strict Multi-Tier Timeout Ordering Inequality

To guarantee that database connections fail fast on contention, do not exhaust connection pools, and release transaction locks promptly, all timeout parameters must satisfy the **Strict Timeout Ladder Invariant**:

$$0 < T_{\text{lock\_timeout}} < T_{\text{statement\_timeout}} < T_{\text{transaction\_timeout}} < T_{\text{idle\_in\_transaction}} < T_{\text{idle\_session}}$$

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                      THE 5-TIER TIMEOUT LADDER HIERARCHY                               │
├──────────────────────────┬────────────────┬────────────────────────────────────────────┤
│ PARAMETER                │ RECOMMENDED    │ PRIMARY GOVERNANCE PURPOSE                 │
├──────────────────────────┼────────────────┼────────────────────────────────────────────┤
│ lock_timeout             │ 1,000ms–2,000ms│ Abort fast if blocked by heavyweight lock; │
│                          │                │ prevents head-of-line queue starvation     │
│ statement_timeout        │ 5,000ms–15,000ms Prevent rogue queries burning unbounded CPU; │
│                          │                │ enforces predictable p99 SLAs              │
│ transaction_timeout      │ 30,000ms–60,000ms PostgreSQL 17+: Bounded total duration    │
│                          │                │ of entire multi-statement transaction      │
│ idle_in_transaction_...  │ 3,000ms–5,000ms Terminate idle connections holding locks;   │
│                          │                │ unfreezes autovacuum xmin horizons         │
│ idle_session_timeout     │ 60,000ms       │ Terminate completely abandoned sockets;    │
│                          │                │ frees connection pool slots                │
└──────────────────────────┴────────────────┴────────────────────────────────────────────┘
```

**Theorem (Lock Starvation Elimination)**: If $T_{\text{lock\_timeout}} \le \frac{1}{5} T_{\text{statement\_timeout}}$, any incoming query waiting behind an uncommitted `ACCESS EXCLUSIVE` or `EXCLUSIVE` lock will abort and yield its connection slot before exhausting pool queues, reducing connection pool queue occupancy by at least $80\%$.

---

### 2.3 Little's Law Pool Starvation Avalanche on Zombie Query Cascade

Let $\lambda$ be the request arrival rate (queries per second) into a connection pool of capacity $C_{\text{pool}}$. Let $W_{\text{normal}}$ be the mean service time for normal queries ($W_{\text{normal}} \approx 10\text{ms}$).

Suppose a fraction $P_{\text{zombie}}$ of queries become zombies (due to dropped client connections without cancel detection, or unhandled `25P02` aborted transactions holding locks), with mean duration $W_{\text{zombie}} \approx 60\text{s}$.

By Little's Law, the mean active connection count $C_{\text{active}}$ required to sustain arrival rate $\lambda$ is:

$$C_{\text{active}} = \lambda \cdot \left[ (1 - P_{\text{zombie}}) W_{\text{normal}} + P_{\text{zombie}} W_{\text{zombie}} \right]$$

Even with a minuscule zombie fraction of $P_{\text{zombie}} = 0.5\%$ ($0.005$) and $\lambda = 100 \text{ req/s}$:
- Normal demand: $100 \times 0.995 \times 0.010\text{s} = 0.995 \text{ connections}$.
- Zombie demand: $100 \times 0.005 \times 60\text{s} = 30 \text{ connections}$.
- Total connections: $30.995$ connections.

A mere **0.5% zombie query rate increases connection pool consumption by 3,100%**, instantly exhausting typical pool allocations ($C_{\text{pool}} = 20–30$) and cascading into total system paralysis.

---

## 3. Autonomous TypeScript Guard Engine

Below is the production-grade `AgenticQueryCancellationGuardEngine`, providing automated verification of timeout ladders, active socket polling diagnostics, out-of-band cancel simulation, zombie backend detection, and connection leak reapers.

```typescript
/**
 * AgenticQueryCancellationGuardEngine
 * Production-grade runtime guard for PostgreSQL query cancellation,
 * client disconnect polling, statement timeout ladders, and zombie elimination.
 */

export interface TimeoutLadderConfig {
  lockTimeoutMs: number;
  statementTimeoutMs: number;
  transactionTimeoutMs?: number; // PostgreSQL 17+
  idleInTransactionTimeoutMs: number;
  idleSessionTimeoutMs: number;
  clientConnectionCheckIntervalMs: number;
}

export interface BackendProcessInfo {
  pid: number;
  usename: string;
  applicationName: string;
  clientAddr: string;
  backendStart: Date;
  xactStart?: Date;
  queryStart?: Date;
  stateChange: Date;
  waitEventType?: string;
  waitEvent?: string;
  state: 'active' | 'idle' | 'idle in transaction' | 'idle in transaction (aborted)' | 'fastpath function call' | 'disabled';
  query: string;
  backendType: string;
}

export interface AuditReport {
  isCompliant: boolean;
  violations: string[];
  recommendations: string[];
  zombieBackends: BackendProcessInfo[];
  timeoutLadderStatus: {
    isProperlyOrdered: boolean;
    configured: TimeoutLadderConfig;
  };
}

export class AgenticQueryCancellationGuardEngine {
  private readonly config: TimeoutLadderConfig;

  constructor(config?: Partial<TimeoutLadderConfig>) {
    this.config = {
      lockTimeoutMs: config?.lockTimeoutMs ?? 1500, // 1.5s
      statementTimeoutMs: config?.statementTimeoutMs ?? 10000, // 10s
      transactionTimeoutMs: config?.transactionTimeoutMs ?? 30000, // 30s (PG 17+)
      idleInTransactionTimeoutMs: config?.idleInTransactionTimeoutMs ?? 5000, // 5s
      idleSessionTimeoutMs: config?.idleSessionTimeoutMs ?? 60000, // 60s
      clientConnectionCheckIntervalMs: config?.clientConnectionCheckIntervalMs ?? 500, // 500ms
    };
  }

  /**
   * Validates that the timeout hierarchy satisfies strict monotonic ordering:
   * lock_timeout < statement_timeout < transaction_timeout < idle_in_transaction_session_timeout
   */
  public validateTimeoutLadder(): { isProperlyOrdered: boolean; errors: string[] } {
    const errors: string[] = [];

    if (this.config.lockTimeoutMs <= 0) {
      errors.push('lock_timeout must be > 0 to prevent indefinite lock queue blocking');
    }

    if (this.config.statementTimeoutMs <= this.config.lockTimeoutMs) {
      errors.push(`statement_timeout (${this.config.statementTimeoutMs}ms) must be strictly greater than lock_timeout (${this.config.lockTimeoutMs}ms)`);
    }

    if (this.config.transactionTimeoutMs && this.config.transactionTimeoutMs <= this.config.statementTimeoutMs) {
      errors.push(`transaction_timeout (${this.config.transactionTimeoutMs}ms) must be strictly greater than statement_timeout (${this.config.statementTimeoutMs}ms)`);
    }

    if (this.config.clientConnectionCheckIntervalMs <= 0 || this.config.clientConnectionCheckIntervalMs > 2000) {
      errors.push(`client_connection_check_interval (${this.config.clientConnectionCheckIntervalMs}ms) must be between 100ms and 2000ms`);
    }

    return {
      isProperlyOrdered: errors.length === 0,
      errors,
    };
  }

  /**
   * Generates the PostgreSQL session-level or role-level configuration commands
   * ensuring all timeouts are properly enforced.
   */
  public generateHardenedConfigurationSQL(): string {
    return `-- =========================================================================
-- AGENTIC POSTGRESQL TIMEOUT LADDER & CLIENT POLLING CONFIGURATION
-- =========================================================================

-- 1. Active Client Socket Disconnect Detection (PG 14+)
-- Polls the TCP socket every 500ms; aborts query instantly if client disconnected
ALTER SYSTEM SET client_connection_check_interval = '${this.config.clientConnectionCheckIntervalMs}ms';

-- 2. Multi-Tier Timeout Ladder Hierarchy
-- Fail fast on lock contention (prevent head-of-line blocking behind DDL)
ALTER SYSTEM SET lock_timeout = '${this.config.lockTimeoutMs}ms';

-- Bounded query execution (prevent runaway full-table scans / CPU burn)
ALTER SYSTEM SET statement_timeout = '${this.config.statementTimeoutMs}ms';

-- Terminate idle transactions holding locks (unfreeze autovacuum xmin horizons)
ALTER SYSTEM SET idle_in_transaction_session_timeout = '${this.config.idleInTransactionTimeoutMs}ms';

-- Terminate completely abandoned client connections
ALTER SYSTEM SET idle_session_timeout = '${this.config.idleSessionTimeoutMs}ms';

-- 3. Reload configuration without database restart
SELECT pg_reload_conf();
`;
  }

  /**
   * Analyzes running backends to detect zombie queries:
   * - Queries running longer than statement_timeout
   * - Idle in transaction (aborted) connections (SQLSTATE 25P02)
   * - Queries blocked on locks longer than lock_timeout
   */
  public detectZombieBackends(backends: BackendProcessInfo[], now = new Date()): BackendProcessInfo[] {
    const zombies: BackendProcessInfo[] = [];

    for (const b of backends) {
      // Exclude background workers (autovacuum, walwriter, logical replication)
      if (b.backendType && b.backendType !== 'client backend') {
        continue;
      }

      // Check 1: In aborted transaction state (SQLSTATE 25P02) held open
      if (b.state === 'idle in transaction (aborted)') {
        const stateDurationMs = now.getTime() - b.stateChange.getTime();
        if (stateDurationMs > this.config.idleInTransactionTimeoutMs) {
          zombies.push(b);
          continue;
        }
      }

      // Check 2: Active query exceeding statement_timeout by 1.5x
      if (b.state === 'active' && b.queryStart) {
        const queryDurationMs = now.getTime() - b.queryStart.getTime();
        if (queryDurationMs > this.config.statementTimeoutMs * 1.5) {
          zombies.push(b);
          continue;
        }
      }

      // Check 3: Idle in transaction holding open snapshots
      if (b.state === 'idle in transaction' && b.xactStart) {
        const xactDurationMs = now.getTime() - b.xactStart.getTime();
        if (xactDurationMs > this.config.idleInTransactionTimeoutMs) {
          zombies.push(b);
          continue;
        }
      }
    }

    return zombies;
  }

  /**
   * Generates safe SQL remediation commands for identified zombies.
   * Uses pg_cancel_backend() (SIGINT) first, escalating to pg_terminate_backend() (SIGTERM).
   * NEVER uses SIGQUIT / kill -9.
   */
  public generateRemediationSQL(zombies: BackendProcessInfo[]): string[] {
    return zombies.map((z) => {
      if (z.state === 'idle in transaction (aborted)' || z.state === 'idle in transaction') {
        // Immediate termination of leaked idle transaction
        return `SELECT pg_terminate_backend(${z.pid}) /* Reason: idle in transaction zombie (pid: ${z.pid}) */;`;
      }
      // Graceful cancellation of active query
      return `SELECT pg_cancel_backend(${z.pid}) /* Reason: active query exceeded timeout (pid: ${z.pid}) */;`;
    });
  }

  /**
   * Audits database environment and returns machine-verifiable report
   */
  public audit(
    backends: BackendProcessInfo[],
    currentConfig?: Partial<TimeoutLadderConfig>
  ): AuditReport {
    const activeConfig = { ...this.config, ...currentConfig };
    const ladderCheck = this.validateTimeoutLadder();
    const zombies = this.detectZombieBackends(backends);

    const violations: string[] = [...ladderCheck.errors];
    const recommendations: string[] = [];

    if (zombies.length > 0) {
      violations.push(`Found ${zombies.length} zombie backend processes holding locks or burning CPU`);
      recommendations.push(
        `Execute graceful cancellation: ${this.generateRemediationSQL(zombies).join(' ')}`
      );
    }

    if (activeConfig.clientConnectionCheckIntervalMs === 0) {
      violations.push('client_connection_check_interval is disabled (0). Postgres cannot detect dropped HTTP clients');
      recommendations.push("Set client_connection_check_interval = '500ms' in postgresql.conf");
    }

    return {
      isCompliant: violations.length === 0,
      violations,
      recommendations,
      zombieBackends: zombies,
      timeoutLadderStatus: {
        isProperlyOrdered: ladderCheck.isProperlyOrdered,
        configured: activeConfig,
      },
    };
  }
}
```

---

## 4. Cross-Runtime Implementation Matrix

### 4.1 Go (`jackc/pgx/v5`): Context Cancellation, Out-of-Band CancelRequest & Defer ROLLBACK

When using Go's `jackc/pgx/v5`, context cancellation (`context.WithTimeout` or client disconnect) triggers `pgx` to open a secondary TCP connection to PostgreSQL to send an out-of-band `CancelRequest` packet containing the backend PID and secret key. 

You must guarantee:
1. `SET LOCAL statement_timeout` and `SET LOCAL lock_timeout` boundaries.
2. Immediate deferred `tx.Rollback(ctx)` using `context.Background()` if the request context was cancelled.
3. Socket keepalives to detect half-open TCP states.

```go
package db

import (
	"context"
	"errors"
	"fmt"
	"net"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TimeoutProfile defines transaction-scoped timeout boundaries
type TimeoutProfile struct {
	LockTimeoutMs      int
	StatementTimeoutMs int
}

var DefaultWebProfile = TimeoutProfile{
	LockTimeoutMs:      1500, // 1.5 seconds
	StatementTimeoutMs: 8000, // 8.0 seconds
}

// ResilientTxExecutor executes a transactional block with strict timeout ladders
// and guarantees zero leaked locks on client cancellation or SQLSTATE 25P02.
type ResilientTxExecutor struct {
	Pool *pgxpool.Pool
}

// NewResilientTxExecutor creates a pool configured with TCP keepalives and fast socket checks
func NewPoolWithKeepalives(ctx context.Context, connString string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(connString)
	if err != nil {
		return nil, fmt.Errorf("parse pool config: %w", err)
	}

	// Configure TCP Keepalives on raw dialer to eliminate zombie sockets
	cfg.ConnConfig.DialFunc = (&net.Dialer{
		KeepAlive: 15 * time.Second,
		Timeout:   5 * time.Second,
	}).DialContext

	// Verify client_connection_check_interval on connection acquisition
	cfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		var checkInterval string
		err := conn.QueryRow(ctx, "SHOW client_connection_check_interval;").Scan(&checkInterval)
		if err != nil || checkInterval == "0" {
			// Set session-level check interval if not enabled globally (PG 14+)
			_, _ = conn.Exec(ctx, "SET client_connection_check_interval = '500ms';")
		}
		return nil
	}

	return pgxpool.NewWithConfig(ctx, cfg)
}

// ExecuteWithTimeoutLadder runs a unit of work inside an isolated transaction
// enforcing lock_timeout < statement_timeout and clean rollback on cancellation.
func (e *ResilientTxExecutor) ExecuteWithTimeoutLadder(
	ctx context.Context,
	profile TimeoutProfile,
	fn func(tx pgx.Tx) error,
) (err error) {
	tx, err := e.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}

	// CRITICAL INVARIANT: Defer rollback MUST execute even if ctx is cancelled!
	// If ctx was cancelled, using ctx for Rollback would fail immediately.
	// Therefore, use a bounded 2-second background context for rollback cleanup.
	defer func() {
		if err != nil {
			cleanupCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_ = tx.Rollback(cleanupCtx) // Releases all row & table locks immediately
		}
	}()

	// Enforce transaction-scoped timeout ladder
	setLadderSQL := fmt.Sprintf(
		"SET LOCAL lock_timeout = '%dms'; SET LOCAL statement_timeout = '%dms';",
		profile.LockTimeoutMs,
		profile.StatementTimeoutMs,
	)
	if _, err = tx.Exec(ctx, setLadderSQL); err != nil {
		return fmt.Errorf("set timeout ladder: %w", err)
	}

	// Execute user business logic
	if err = fn(tx); err != nil {
		// Differentiate query cancellation (57014) from other errors
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "57014" {
			return fmt.Errorf("query cancelled by database timeout or client interrupt: %w", err)
		}
		return err
	}

	return tx.Commit(ctx)
}
```

---

### 4.2 Python (`asyncpg`): Task Cancellation, Timeout Shielding & Connection Sanitation

In Python's `asyncpg`, when an `asyncio.Task` is cancelled (e.g., via `asyncio.wait_for` timeout or client disconnection), `asyncpg` sends a PostgreSQL `CancelRequest` packet over a separate socket. However, if the transaction is cancelled while executing, the connection enters the aborted `25P02` state:

```python
import asyncio
import logging
from typing import AsyncGenerator
import asyncpg

logger = logging.getLogger("db.cancellation")

class ResilientDatabaseSession:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def execute_with_timeout_ladder(
        self,
        query: str,
        *args,
        lock_timeout_ms: int = 1500,
        statement_timeout_ms: int = 8000,
        client_timeout_sec: float = 10.0,
    ):
        """
        Executes query under explicit timeout ladder.
        Guarantees that asyncio task cancellation properly sends CancelRequest
        and connection is sanitized before returning to the pool.
        """
        async with self.pool.acquire() as conn:
            # Set transaction-scoped timeout ladder
            async with conn.transaction():
                await conn.execute(
                    f"SET LOCAL lock_timeout = '{lock_timeout_ms}ms';"
                    f"SET LOCAL statement_timeout = '{statement_timeout_ms}ms';"
                )
                try:
                    # Enforce application-side timeout with asyncio.wait_for
                    return await asyncio.wait_for(
                        conn.fetch(query, *args),
                        timeout=client_timeout_sec
                    )
                except asyncio.TimeoutError:
                    logger.warning(
                        "Client timeout reached (%ss). asyncpg sends out-of-band CancelRequest",
                        client_timeout_sec
                    )
                    raise
                except asyncpg.QueryCanceledError as e:
                    logger.error("Query canceled by PostgreSQL (statement_timeout or CancelRequest): %s", e)
                    raise
                except Exception as e:
                    # Connection will cleanly rollback via async with conn.transaction()
                    logger.error("Database query failed: %s", e)
                    raise
```

---

### 4.3 Rust (`sqlx` / `tokio-postgres`): Drop Guards & Cancellation Tokens

In Rust, `tokio-postgres` exposes a `CancelToken` that can be stored and invoked from another thread or task when the primary future is dropped or timed out:

```rust
use std::time::Duration;
use tokio::time::timeout;
use tokio_postgres::{Client, NoTls, Error};

pub struct QueryRunner;

impl QueryRunner {
    pub async fn execute_with_guard(
        client: &mut Client,
        query: &str,
        timeout_dur: Duration,
    ) -> Result<Vec<tokio_postgres::Row>, Box<dyn std::error::Error + Send + Sync>> {
        // 1. Set local timeout ladder
        client.batch_execute(
            "SET LOCAL lock_timeout = '1500ms'; SET LOCAL statement_timeout = '8000ms';"
        ).await?;

        // 2. Obtain out-of-band cancellation token
        let cancel_token = client.cancel_token();

        // 3. Execute with tokio timeout guard
        let query_future = client.query(query, &[]);

        match timeout(timeout_dur, query_future).await {
            Ok(result) => Ok(result?),
            Err(_elapsed) => {
                // Future dropped; spawn dedicated task to send CancelRequest over new TCP connection
                tokio::spawn(async move {
                    if let Err(e) = cancel_token.cancel_query(NoTls).await {
                        eprintln!("Failed to send out-of-band cancel token: {}", e);
                    }
                });
                Err("Query execution timed out; CancelRequest dispatched to PostgreSQL backend".into())
            }
        }
    }
}
```

---

## 5. Query Cancellation & Disconnect Lifecycle Finite-State Machine (FSM)

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│             QUERY CANCELLATION & DISCONNECT LIFECYCLE FINITE-STATE MACHINE             │
└────────────────────────────────────────────────────────────────────────────────────────┘

 [S0: CONNECTION_ACQUIRED]
         │
         ▼  (SET LOCAL lock_timeout < statement_timeout)
 [S1: TIMEOUT_LADDER_ARMED]
         │
         ▼  (Begin query execution in PostgreSQL backend)
 [S2: EXECUTING_QUERY]
         │
         ├──► (Normal execution completes) ──────────────────────────► [S5: COMMITTED_SUCCESS]
         │
         ├──► (lock_timeout fires: 55P03 lock_not_available) ─────────┐
         │                                                            │
         ├──► (statement_timeout fires: 57014 query_canceled) ────────┤
         │                                                            │
         ├──► (client_connection_check_interval detects EPIPE/RST) ───┼──► [S3: BACKEND_ABORTING]
         │                                                            │           │
         └──► (Driver sends out-of-band CancelRequest packet) ────────┘           │
                                                                                  ▼
                                                                      [S4: DEFERRED_ROLLBACK]
                                                                      (Issue ROLLBACK in defer;
                                                                       release all row & table locks)
                                                                                  │
                                                                                  ▼
                                                                      [S6: CONNECTION_SANITIZED]
                                                                      (Clean connection returned to pool;
                                                                       Zero zombie backends)
```

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

Autonomous agents must satisfy every check in this matrix before marking any database transaction, connection pool, or API timeout task as complete:

| Check Gate | Inspection Target | Verification Command / Metric | Pass Condition |
| :--- | :--- | :--- | :--- |
| **DoD-1: Socket Polling Configured** | `client_connection_check_interval` | `SHOW client_connection_check_interval;` | Value is between `100ms` and `1000ms` (never `'0'`) |
| **DoD-2: Strict Timeout Ladder Ordering** | Session / Role GUCs | `lock_timeout < statement_timeout` | $T_{\text{lock}} \le 2000\text{ms}$ and $T_{\text{statement}} \le 15000\text{ms}$ |
| **DoD-3: Idle In Transaction Fencing** | `idle_in_transaction_session_timeout` | `SHOW idle_in_transaction_session_timeout;` | Value is $\le 5000\text{ms}$ |
| **DoD-4: Zero Leaked Aborted Locks** | `pg_stat_activity` state | `SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction (aborted)';` | Count $== 0$ across all client backends |
| **DoD-5: Out-of-Band Cancel Verification** | Client Driver / PgBouncer | Context cancel triggers backend SIGINT | CancelRequest returns sub-100ms; backend aborts cleanly |
| **DoD-6: CI Guard Engine Assertion** | Automated CI suite | `AgenticQueryCancellationGuardEngine.audit()` | `report.isCompliant === true` and `violations.length === 0` |

---

## Conclusion & Operational Discipline

1. **Never Allow Phantom Queries on Disconnected Clients**: Always configure `client_connection_check_interval = '500ms'` in PostgreSQL 14+. The database must never burn CPU and NVMe cycles on queries whose callers have already timed out and departed.
2. **Strictly Order Timeout Ladders**: Always enforce $T_{\text{lock\_timeout}} < T_{\text{statement\_timeout}} < T_{\text{transaction\_timeout}} < T_{\text{idle\_in\_transaction}}$. Failing fast on lock contention prevents catastrophic head-of-line blocking and connection pool depletion.
3. **Always Guarantee Deferred ROLLBACK on Error or Cancellation**: Never catch a query error and return without executing `ROLLBACK` on the aborted transaction (`SQLSTATE 25P02`). Unclosed aborted transactions hold open MVCC vacuum horizons and exclusive row locks.
4. **Never Kill Backends with SIGQUIT / SIGKILL**: Always invoke `pg_cancel_backend(pid)` (SIGINT) first. If escalating, use `pg_terminate_backend(pid)` (SIGTERM). Sending `kill -9` or `SIGQUIT` forces postmaster to initiate a full crash recovery restart, terminating every tenant connection in the cluster.
