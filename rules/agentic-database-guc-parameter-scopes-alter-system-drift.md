---
description: PostgreSQL Grand Unified Configuration (GUC) parameter scopes, parameter contexts (postmaster, sighup, superuser, user, internal), ALTER SYSTEM configuration drift, postgresql.auto.conf vs GitOps IaC desynchronization, pg_file_settings syntax error auditing, SET vs SET LOCAL connection pool pollution, DISCARD ALL vs RESET ALL session resets, and CVE-2018-1058 search_path hardening across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, psycopg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{config,guc,settings,alter_system,pg_file_settings,pool,session,connection,migration}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go,py},**/infra/**/*.{tf,yaml,yml}
alwaysApply: false
---

# Agentic Database GUC Hierarchy, Configuration Invariants, Parameter Context Scopes, ALTER SYSTEM Drift, pg_file_settings Auditing, SET vs SET LOCAL Connection Leaks & Session State Pollution Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to configure, inspect, tune, or migrate PostgreSQL (13–17+) database engines, connection poolers (PgBouncer, Odyssey), ORMs, and query runners across Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Session State Leak & Connection Pool Pollution Catastrophe" (where agents execute `SET statement_timeout = ...`, `SET search_path = ...`, or `SET work_mem = ...` directly on pooled connections instead of `SET LOCAL`, poisoning subsequent unrelated user transactions with corrupted timeouts, memory bloat, or multi-tenant cross-account data leaks), the "Out-of-Band `ALTER SYSTEM` GitOps Desynchronization Trap" (where agents run `ALTER SYSTEM SET ...` to remediate runtime issues, writing unversioned overrides to `postgresql.auto.conf` that silently supersede `postgresql.conf`, break standby replication nodes, and cause container restart crashes), the "Parameter Context Invalidation & Silent Pending Restart Panic (`PGC_POSTMASTER` vs `PGC_SIGHUP`)" (where agents invoke `SELECT pg_reload_conf()` after modifying `postmaster`-context parameters like `shared_buffers`, `max_connections`, or `wal_level`, falsely assuming changes are active while `pg_settings.pending_restart = true` leaves old limits live until an unexpected restart crashes the cluster), the "`pg_file_settings` Silent Syntax Error Trap" (where configuration reloads return `true` despite malformed parameter directives, silently failing to apply settings while logging unmonitored errors in `pg_file_settings`), the "CVE-2018-1058 `search_path` Privilege Escalation Trap" (where `SECURITY DEFINER` functions omit explicit `search_path` pins, allowing unprivileged schemas to hijack superuser executions), and the "`RESET ALL` Connection Sanitization Illusion" (where poolers use `RESET ALL` assuming clean sessions, while prepared statements, advisory locks, and temporary tables leak across clients) by establishing a strict 5-Tier GUC Governance Ladder, formal pool contamination probability physics, an autonomous TypeScript `AgenticDatabaseGucGuardEngine`, cross-runtime telemetry sentinels in Go, TypeScript, Python, and Rust, a 6-state GUC configuration lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 GUC Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL's Grand Unified Configuration (GUC) engine governs every facet of server behavior—from memory allocations (`work_mem`, `shared_buffers`) and planner cost constants (`random_page_cost`) to transactional timeouts (`statement_timeout`, `lock_timeout`) and security isolation (`search_path`, `session_replication_role`).

Every GUC parameter is assigned a rigid context (`pg_settings.context`) determining when, how, and by whom it can be modified:
- **`internal`**: Read-only compile-time constants (`block_size`, `wal_block_size`). Cannot be modified.
- **`postmaster`**: Engine startup parameters (`shared_buffers`, `max_connections`, `wal_level`, `huge_pages`, `shared_preload_libraries`). Can only be set in configuration files before server initialization. Requires a full cluster restart; calling `pg_reload_conf()` marks them `pending_restart = true` without taking effect.
- **`sighup`**: Server configuration parameters (`work_mem`, `statement_timeout`, `log_min_duration_statement`, `max_slot_wal_keep_size`). Can be modified in configuration files and applied dynamically without downtime via `SELECT pg_reload_conf()` (sending `SIGHUP` to the postmaster).
- **`superuser-backend` / `backend`**: Parameters set in configuration files or during connection establishment by superusers. Changes only affect new backend processes.
- **`superuser`**: Session-level parameters settable only by superusers via `SET` (`session_replication_role`).
- **`user`**: Session-level parameters settable by any connected user (`SET statement_timeout`, `SET search_path`, `SET work_mem`).

When autonomous coding agents generate database migrations, optimize queries, or implement connection pooling, LLMs routinely commit 6 catastrophic architectural errors:

### The 6 GUC Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: RAW 'SET' CONNECTION POOL POLLUTION
-- Agent wants a longer timeout or specific schema for a heavy report query:
SET statement_timeout = '600000'; -- 10 minutes!
SET search_path = tenant_corp_a, public;
SELECT * FROM complex_financial_aggregation();

-- 💥 Catastrophe:
-- In PgBouncer (transaction pooling) or application connection pools (pgxpool, pg-pool),
-- 'SET' mutates the physical backend session state.
-- When this transaction finishes, the physical connection returns to the pool with:
-- statement_timeout = 10 minutes (disabling DDoS/runaway query protection)
-- search_path = tenant_corp_a (subsequent user requests for tenant_corp_b query tenant A's data!)
-- Invariant: NEVER use raw 'SET' on pooled connections. Use 'SET LOCAL' inside explicit transactions!

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: OUT-OF-BAND 'ALTER SYSTEM' GitOps DRIFT
-- Agent encounters a connection limit error or memory spill and runs:
ALTER SYSTEM SET max_connections = 1000;
ALTER SYSTEM SET work_mem = '512MB';
SELECT pg_reload_conf();

-- 💥 Catastrophe:
-- 1. 'ALTER SYSTEM' writes overrides directly to '$PGDATA/postgresql.auto.conf'.
--    This silently overrides 'postgresql.conf' and bypasses version control (GitOps, Terraform, Helm).
-- 2. Standby read-replicas and disaster recovery clones do NOT receive postgresql.auto.conf.
--    The primary now runs with divergent configurations, breaking streaming replication or causing
--    replica failover nodes to panic upon promotion.
-- 3. 'max_connections' is a 'postmaster' context parameter! Calling pg_reload_conf() does NOT apply it;
--    it sets pending_restart = true. The agent believes capacity is 1000, but the server rejects connection 101!
-- 4. work_mem = 512MB globally causes concurrent parallel queries (8 workers * 4 joins) to consume
--    16GB RAM each, instantly triggering the Linux kernel OOM Killer and crashing the primary!

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: UNMONITORED pg_file_settings SYNTAX CORRUPTION
-- Agent or automation edits postgresql.conf and triggers reload:
SELECT pg_reload_conf(); -- Returns TRUE!

-- 💥 Catastrophe:
-- Even if postgresql.conf contains a fatal syntax error, typo, or invalid enum value,
-- SELECT pg_reload_conf() returns TRUE!
-- PostgreSQL logs the error silently to server logs and pg_file_settings (error IS NOT NULL).
-- The desired configuration is rejected (applied = false), and all subsequent valid directives
-- in that file are ignored! The agent assumes the database is reconfigured when it is completely stale.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: CVE-2018-1058 search_path PRIVILEGE ESCALATION
-- Agent writes an administrative maintenance routine:
CREATE OR REPLACE FUNCTION clean_stale_records() RETURNS void AS $$
BEGIN
  DELETE FROM audit_events WHERE created_at < NOW() - INTERVAL '90 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER; -- Runs as superuser!

-- 💥 Catastrophe:
-- The function does NOT declare 'SET search_path = pg_catalog, pg_temp;'.
-- When an administrator or cron worker invokes this function, PostgreSQL resolves table
-- names and operators using the caller's active search_path.
-- An unprivileged user can create a malicious schema or table named 'audit_events'
-- or override operators, executing arbitrary code with superuser privileges (CVE-2018-1058).

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: 'RESET ALL' CONNECTION SANITIZATION ILLUSION
-- Agent configures pool cleanup hook:
RESET ALL;

-- 💥 Catastrophe:
-- RESET ALL resets session GUCs to session startup values, but DOES NOT deallocate prepared statements,
-- does NOT drop temporary tables, does NOT release session advisory locks, and does NOT reset sequences!
-- Prepared statements with mismatched parameter types leak across clients, causing SQLSTATE 42P05
-- ("prepared statement already exists") crashes. Only DISCARD ALL guarantees total session hygiene!

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: NON-ATOMIC MULTI-GUC TRANSACTION ROOF EXPLOSION
-- Agent attempts to tune query performance on a single transaction:
SET work_mem = '256MB';
SET max_parallel_workers_per_gather = 8;
-- Network disconnect occurs before RESET!
-- The connection remains pinned with massive memory allocations in the pool forever.
```

---

## 2. The 5-Tier GUC Governance Ladder

To eliminate configuration drift, connection pollution, and silent syntax errors, autonomous agents must adhere to the 5-Tier GUC Governance Ladder:

| Tier | Governance Level | Core Mechanism | Production Invariant |
| :--- | :--- | :--- | :--- |
| **Tier 0** | **Transactional Scoping (`SET LOCAL`)** | Transaction-bound GUCs | **100% of runtime query parameter changes must use `SET LOCAL` inside explicit `BEGIN ... COMMIT` blocks.** Raw `SET` on pooled connections is strictly prohibited. |
| **Tier 1** | **Context Pre-Flight Verification** | `pg_settings.context` audit | Query `pg_settings` for parameter context prior to modification. Never attempt dynamic reload on `postmaster` parameters. Raise alerts on `pending_restart = true`. |
| **Tier 2** | **Syntax & File Auditing** | `pg_file_settings` introspection | Every configuration modification or `pg_reload_conf()` call must immediately verify `SELECT COUNT(*) FROM pg_file_settings WHERE error IS NOT NULL;`. Fail CI if errors exist. |
| **Tier 3** | **GitOps IaC Fencing & Anti-`ALTER SYSTEM`** | Immutable configuration manifests | Prohibit `ALTER SYSTEM` in automated pipelines. Maintain configurations in version-controlled manifests. Audit `$PGDATA/postgresql.auto.conf` for drift. |
| **Tier 4** | **Security Hardening & Pool Hygiene** | `search_path` lockdown & `DISCARD ALL` | Mandatory `SET search_path = pg_catalog, pg_temp;` on 100% of `SECURITY DEFINER` routines. Enforce `server_reset_query = DISCARD ALL` in connection poolers. |

### 2.1 Invariant 1: Transactional Scoping (`SET LOCAL`) vs Raw `SET`

Any dynamic parameter adjustment intended for a specific query or batch operation must be scoped strictly to the transaction using `SET LOCAL`:

```sql
-- ✅ PRODUCTION STANDARD: Atomic Transaction-Scoped Configuration
BEGIN;
  -- SET LOCAL guarantees parameters revert automatically upon COMMIT or ROLLBACK:
  SET LOCAL statement_timeout = '15000ms';
  SET LOCAL lock_timeout = '2000ms';
  SET LOCAL work_mem = '64MB';
  SET LOCAL search_path = tenant_alpha, extensions, pg_catalog, pg_temp;

  -- Execute latency-sensitive or memory-intensive query:
  SELECT * FROM compute_quarterly_analytics();
COMMIT;
-- The physical connection immediately reverts to default pool configuration!
```

### 2.2 Invariant 2: Pooler Sanitization Protocol (`DISCARD ALL` vs `RESET ALL`)

In session-pooling or transaction-pooling architectures, connection recycling must execute `DISCARD ALL`:
- `RESET ALL`: Reverts GUCs to session defaults. Leaves temporary tables, prepared statements, and session locks active.
- `DISCARD ALL`: Executes `SET SESSION AUTHORIZATION DEFAULT; RESET ALL; DEALLOCATE ALL; DISCARD PLANS; DISCARD SEQUENCES; DISCARD TEMP;`.

In `pgbouncer.ini`:
```ini
;; ✅ PRODUCTION STANDARD: Complete session hygiene on connection reuse
server_reset_query = DISCARD ALL
server_reset_query_always = 0
```

### 2.3 Invariant 3: Hardened `SECURITY DEFINER` Routine Isolation

Every function, procedure, or event trigger declared with `SECURITY DEFINER` must explicitly pin `search_path`:

```sql
-- ✅ PRODUCTION STANDARD: Safe SECURITY DEFINER Function (Anti-CVE-2018-1058)
CREATE OR REPLACE FUNCTION audit_purge_stale_events()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
-- Pin search_path to pg_catalog and isolated pg_temp only:
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_purged_count integer;
BEGIN
  DELETE FROM public.audit_events
  WHERE created_at < CURRENT_TIMESTAMP - INTERVAL '180 days';
  GET DIAGNOSTICS v_purged_count = ROW_COUNT;
  RETURN v_purged_count;
END;
$$;
```

---

## 3. Quantitative Mechanics: Pool Leak Probability, Memory Footprint & Drift Calculus

### 3.1 Connection Pool State Contamination Probability

Let $N_{\text{conn}}$ be the total number of physical connections in a connection pool, and $M$ be the client multiplexing factor ($M = N_{\text{clients}} / N_{\text{conn}}$). If an un-scoped `SET` command is executed on a connection with probability $p_{\text{set}}$ per transaction, the probability that a connection in the pool is contaminated with dirty session state after $k$ transactions is given by:

$$P_{\text{dirty}}(k) = 1 - \left(1 - \frac{p_{\text{set}}}{N_{\text{conn}}}\right)^k$$

For a high-throughput microservice processing $\lambda = 1,000\text{ req/sec}$ with $N_{\text{conn}} = 50$:
If a single rogue endpoint executes raw `SET` once every 10 seconds ($p_{\text{set}} = 10^{-4}$):

$$P_{\text{dirty}}(t = 60\text{s}) = 1 - \left(1 - \frac{10^{-4}}{50}\right)^{60,000} \approx 1 - e^{-0.12} \approx 11.3\%$$
$$P_{\text{dirty}}(t = 300\text{s}) = 1 - \left(1 - \frac{10^{-4}}{50}\right)^{300,000} \approx 1 - e^{-0.60} \approx 45.1\%$$

Within 10 minutes, **over 70% of the entire connection pool is contaminated** with poisoned timeouts or mismatched tenant schemas!

```
[Clean Connection Pool]  ──(Raw SET search_path/timeout)──>  [Poisoned Session State]
         │                                                            │
         ▼                                                            ▼
 [Tenant B Requests]   ───(Routed to Poisoned Connection)───>  [Data Leak / OOM Crash]
```

### 3.2 Dynamic Memory Footprint Multiplier ($RAM_{\text{peak}}$)

PostgreSQL allocates `work_mem` independently for *each* sort, hash join, or materialization node in an execution plan, multiplied by the number of active parallel workers.

For a complex analytical query with $N_{\text{nodes}}$ memory-intensive plan operations and $W$ parallel query workers:

$$RAM_{\text{query}} = \sum_{j=1}^{N_{\text{nodes}}} (1 + W_j) \cdot \text{work\_mem}$$

If an agent runs `ALTER SYSTEM SET work_mem = '512MB';` and $C_{\text{active}} = 30$ concurrent queries execute plans with $N_{\text{nodes}} = 4$ and $W = 4$:

$$RAM_{\text{query}} = 4 \times (1 + 4) \times 512\text{MB} = 10,240\text{MB} = 10\text{GB}$$
$$RAM_{\text{total}} = 30 \times 10\text{GB} = 300\text{GB}$$

If the host machine has 64GB of RAM, the Linux Out-Of-Memory (OOM) killer triggers within milliseconds:

$$t_{\text{oom}} \le \frac{\text{RAM}_{\text{available}}}{\lambda_{\text{query}} \cdot RAM_{\text{query}}}$$

Postmaster backends receive `SIGKILL`, the shared memory segment is corrupted, and PostgreSQL enters emergency crash recovery, taking the entire production application offline.

### 3.3 Configuration Drift Index ($D_{\text{config}}$)

We define the Configuration Drift Index $D_{\text{config}}$ across the set of all active cluster parameters $\mathcal{P}$:

$$D_{\text{config}} = \sum_{p \in \mathcal{P}} \left( \mathbb{I}(\text{setting}_p \neq \text{boot\_val}_p \land \text{pending\_restart}_p) \cdot 10 + \mathbb{I}(\text{source}_p = \text{'auto.conf'}) \cdot 5 + \mathbb{I}(\text{error}_p \neq \emptyset) \cdot 50 \right)$$

- **$D_{\text{config}} = 0$**: Healthy, fully synchronized, immutable GitOps configuration.
- **$0 < D_{\text{config}} < 20$**: Minor out-of-band overrides present in `postgresql.auto.conf`.
- **$D_{\text{config}} \ge 20$**: Critical drift! Pending restarts unapplied or syntax errors present in configuration files.

---

## 4. Production TypeScript Engine: AgenticDatabaseGucGuardEngine

The following production-grade TypeScript engine provides comprehensive GUC context inspection, safe transaction-local parameter scoping, `pg_file_settings` error auditing, pending restart detection, and connection sanitization.

```typescript
/**
 * AgenticDatabaseGucGuardEngine
 * Industrial GUC parameter validation, safe transaction scoping, and drift detection.
 */

export type GucContext =
  | 'internal'
  | 'postmaster'
  | 'sighup'
  | 'superuser-backend'
  | 'backend'
  | 'superuser'
  | 'user';

export interface GucSettingInfo {
  name: string;
  setting: string;
  unit: string | null;
  category: string;
  shortDesc: string;
  context: GucContext;
  source: string;
  pendingRestart: boolean;
  bootVal: string;
}

export interface FileSettingError {
  sourcefile: string;
  sourceline: number;
  name: string;
  setting: string;
  applied: boolean;
  error: string;
}

export interface GucValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
  requiresRestart: boolean;
  sqlToApply?: string;
}

export interface IDatabaseClient {
  query<T = any>(sql: string, params?: any[]): Promise<{ rows: T[] }>;
}

export class AgenticDatabaseGucGuardEngine {
  private readonly client: IDatabaseClient;

  // Dangerous parameters that must NEVER be modified via raw session SET:
  private static readonly RESTRICTED_SESSION_GUCS = new Set<string>([
    'search_path',
    'role',
    'session_authorization',
    'statement_timeout',
    'lock_timeout',
    'idle_in_transaction_session_timeout',
    'work_mem',
    'maintenance_work_mem',
    'max_parallel_workers_per_gather',
  ]);

  constructor(client: IDatabaseClient) {
    this.client = client;
  }

  /**
   * Introspect a specific GUC parameter from pg_settings.
   */
  async getGucInfo(paramName: string): Promise<GucSettingInfo | null> {
    const res = await this.client.query<any>(
      `
      SELECT 
        name,
        setting,
        unit,
        category,
        short_desc AS "shortDesc",
        context::text AS context,
        source,
        pending_restart AS "pendingRestart",
        boot_val AS "bootVal"
      FROM pg_settings
      WHERE name = $1;
      `,
      [paramName.toLowerCase().trim()]
    );

    if (res.rows.length === 0) {
      return null;
    }

    const r = res.rows[0];
    return {
      name: r.name,
      setting: r.setting,
      unit: r.unit,
      category: r.category,
      shortDesc: r.shortDesc,
      context: r.context as GucContext,
      source: r.source,
      pendingRestart: Boolean(r.pendingRestart),
      bootVal: r.bootVal,
    };
  }

  /**
   * Audit all configuration files for unapplied lines or syntax errors via pg_file_settings.
   */
  async auditFileSettings(): Promise<FileSettingError[]> {
    const res = await this.client.query<any>(`
      SELECT 
        sourcefile,
        sourceline,
        name,
        setting,
        applied,
        error
      FROM pg_file_settings
      WHERE error IS NOT NULL OR applied = false;
    `);

    return res.rows.map((r) => ({
      sourcefile: r.sourcefile,
      sourceline: Number(r.sourceline),
      name: r.name,
      setting: r.setting,
      applied: Boolean(r.applied),
      error: r.error || 'Parameter not applied',
    }));
  }

  /**
   * Audit all parameters requiring cluster restart to take effect (pending_restart = true).
   */
  async getPendingRestartParameters(): Promise<GucSettingInfo[]> {
    const res = await this.client.query<any>(`
      SELECT 
        name,
        setting,
        unit,
        category,
        short_desc AS "shortDesc",
        context::text AS context,
        source,
        pending_restart AS "pendingRestart",
        boot_val AS "bootVal"
      FROM pg_settings
      WHERE pending_restart = true;
    `);

    return res.rows.map((r) => ({
      name: r.name,
      setting: r.setting,
      unit: r.unit,
      category: r.category,
      shortDesc: r.shortDesc,
      context: r.context as GucContext,
      source: r.source,
      pendingRestart: true,
      bootVal: r.bootVal,
    }));
  }

  /**
   * Validates a proposed parameter mutation and constructs safe SQL.
   * Enforces SET LOCAL within transactions for session overrides.
   */
  async planParameterOverride(
    paramName: string,
    targetValue: string,
    isTransactionScoped: boolean
  ): Promise<GucValidationResult> {
    const info = await this.getGucInfo(paramName);
    if (!info) {
      return {
        valid: false,
        errors: [`GUC parameter '${paramName}' does not exist in pg_settings.`],
        warnings: [],
        requiresRestart: false,
      };
    }

    const errors: string[] = [];
    const warnings: string[] = [];

    // Context validation
    if (info.context === 'internal') {
      errors.push(`Parameter '${paramName}' is 'internal' and cannot be modified.`);
    }

    if (info.context === 'postmaster') {
      if (isTransactionScoped) {
        errors.push(
          `Parameter '${paramName}' context is 'postmaster' and cannot be set dynamically via SET or SET LOCAL.`
        );
      } else {
        warnings.push(
          `Parameter '${paramName}' context is 'postmaster'. Changing it requires writing to configuration and restarting the PostgreSQL service.`
        );
      }
    }

    // Dangerous session overrides check
    if (!isTransactionScoped && AgenticDatabaseGucGuardEngine.RESTRICTED_SESSION_GUCS.has(paramName)) {
      errors.push(
        `Direct session modification via 'SET ${paramName}' is banned to prevent connection pool pollution. Use 'SET LOCAL' inside an explicit transaction block (BEGIN ... COMMIT).`
      );
    }

    if (errors.length > 0) {
      return {
        valid: false,
        errors,
        warnings,
        requiresRestart: info.context === 'postmaster',
      };
    }

    const sanitizedValue = targetValue.replace(/'/g, "''");
    const sqlToApply = isTransactionScoped
      ? `SET LOCAL ${paramName} = '${sanitizedValue}';`
      : `SET ${paramName} = '${sanitizedValue}';`;

    return {
      valid: true,
      errors: [],
      warnings,
      requiresRestart: info.context === 'postmaster',
      sqlToApply,
    };
  }

  /**
   * Execute an operation within a strictly isolated, parameter-scoped transaction.
   * Guarantees zero connection pool leakage.
   */
  async runWithScopedGucs<T>(
    scopedSettings: Record<string, string>,
    operation: (client: IDatabaseClient) => Promise<T>
  ): Promise<T> {
    // 1. Pre-validate all settings
    for (const [key, val] of Object.entries(scopedSettings)) {
      const plan = await this.planParameterOverride(key, val, true);
      if (!plan.valid) {
        throw new Error(`Cannot apply scoped GUC '${key}': ${plan.errors.join('; ')}`);
      }
    }

    // 2. Execute within an explicit BEGIN ... COMMIT block
    await this.client.query('BEGIN;');
    try {
      for (const [key, val] of Object.entries(scopedSettings)) {
        const sanitized = val.replace(/'/g, "''");
        await this.client.query(`SET LOCAL ${key} = '${sanitized}';`);
      }

      const result = await operation(this.client);
      await this.client.query('COMMIT;');
      return result;
    } catch (err) {
      await this.client.query('ROLLBACK;').catch(() => {});
      throw err;
    }
  }

  /**
   * Calculate cluster Configuration Drift Index (D_config).
   */
  async calculateDriftIndex(): Promise<{
    driftIndex: number;
    pendingRestarts: string[];
    fileErrors: FileSettingError[];
    autoConfOverrides: string[];
  }> {
    const [pending, fileErrors, autoConfRes] = await Promise.all([
      this.getPendingRestartParameters(),
      this.auditFileSettings(),
      this.client.query<any>(
        "SELECT name, setting FROM pg_settings WHERE source = 'auto.conf';"
      ),
    ]);

    let score = 0;
    score += pending.length * 10;
    score += fileErrors.filter((e) => e.error).length * 50;
    score += autoConfRes.rows.length * 5;

    return {
      driftIndex: score,
      pendingRestarts: pending.map((p) => p.name),
      fileErrors,
      autoConfOverrides: autoConfRes.rows.map((r) => `${r.name}=${r.setting}`),
    };
  }
}
```

---

## 5. Cross-Runtime Telemetry Sentinels

### 5.1 Go (`jackc/pgx/v5`): Transactional Scoping & GUC Audit Sentinel

```go
package guc

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type GucSentinel struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewGucSentinel(pool *pgxpool.Pool, logger *slog.Logger) *GucSentinel {
	return &GucSentinel{pool: pool, logger: logger}
}

// ExecuteWithScopedGuc executes user logic in a transaction with SET LOCAL parameter bounds.
// Guarantees zero session state leaks across pooled pgx connections.
func (s *GucSentinel) ExecuteWithScopedGuc(ctx context.Context, gucs map[string]string, fn func(tx pgx.Tx) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx) // Safe no-op if committed

	for k, v := range gucs {
		// Parameter sanity check: avoid injection in GUC keys
		if strings.ContainsAny(k, ";'\"\t\n\r =") {
			return fmt.Errorf("invalid GUC key name: %s", k)
		}
		// Escape single quotes in parameter value
		safeVal := strings.ReplaceAll(v, "'", "''")
		setStmt := fmt.Sprintf("SET LOCAL %s = '%s';", k, safeVal)
		if _, err := tx.Exec(ctx, setStmt); err != nil {
			return fmt.Errorf("failed to set local GUC %s: %w", k, err)
		}
	}

	if err := fn(tx); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// AuditClusterGucHealth inspects pending restarts and syntax errors in configuration files.
func (s *GucSentinel) AuditClusterGucHealth(ctx context.Context) error {
	// 1. Audit pg_file_settings for unapplied or erroneous directives
	fileRows, err := s.pool.Query(ctx, `
		SELECT sourcefile, sourceline, name, setting, COALESCE(error, '')
		FROM pg_file_settings
		WHERE error IS NOT NULL OR applied = false;
	`)
	if err != nil {
		return fmt.Errorf("failed to query pg_file_settings: %w", err)
	}
	defer fileRows.Close()

	var fileErrors []string
	for fileRows.Next() {
		var srcFile, name, setting, errStr string
		var srcLine int
		if err := fileRows.Scan(&srcFile, &srcLine, &name, &setting, &errStr); err != nil {
			return err
		}
		fileErrors = append(fileErrors, fmt.Sprintf("%s:%d [%s=%s] Error: %s", srcFile, srcLine, name, setting, errStr))
	}

	if len(fileErrors) > 0 {
		s.logger.Error("FATAL: pg_file_settings contains unapplied or broken configuration",
			slog.String("errors", strings.Join(fileErrors, " | ")))
	}

	// 2. Audit pending restarts
	restartRows, err := s.pool.Query(ctx, `
		SELECT name, setting, context
		FROM pg_settings
		WHERE pending_restart = true;
	`)
	if err != nil {
		return fmt.Errorf("failed to query pg_settings for pending restarts: %w", err)
	}
	defer restartRows.Close()

	var pendingList []string
	for restartRows.Next() {
		var name, setting, contextStr string
		if err := restartRows.Scan(&name, &setting, &contextStr); err != nil {
			return err
		}
		pendingList = append(pendingList, fmt.Sprintf("%s (%s context, current=%s)", name, contextStr, setting))
	}

	if len(pendingList) > 0 {
		s.logger.Warn("PostgreSQL parameters pending cluster restart",
			slog.String("pending_restart_count", fmt.Sprintf("%d", len(pendingList))),
			slog.String("parameters", strings.Join(pendingList, ", ")))
	}

	return nil
}
```

### 5.2 TypeScript (`kysely` / `pg`): Transaction-Bound GUC Runner

```typescript
import { Kysely, sql } from 'kysely';

export async function executeWithLocalGucs<DB, T>(
  db: Kysely<DB>,
  gucOverrides: Record<string, string>,
  task: (trx: Kysely<DB>) => Promise<T>
): Promise<T> {
  return await db.transaction().execute(async (trx) => {
    // Apply SET LOCAL inside the transaction boundary:
    for (const [key, value] of Object.entries(gucOverrides)) {
      if (!/^[a-zA-Z_][a-zA-Z0-9_.]*$/.test(key)) {
        throw new Error(`Invalid GUC key identifier: ${key}`);
      }
      // Sanitized literal escaping:
      await sql`SET LOCAL ${sql.raw(key)} = ${value}`.execute(trx);
    }

    return await task(trx);
  });
}
```

### 5.3 Python (`asyncpg`): Asynchronous GUC Audit & Scoped Session Context

```python
import asyncpg
import logging
from typing import Dict, Any, Callable

logger = logging.getLogger("guc_sentinel")

class AsyncGucSentinel:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def execute_with_scoped_gucs(self, gucs: Dict[str, str], coro_fn: Callable[[asyncpg.Connection], Any]):
        """
        Executes a callable inside an explicit transaction with SET LOCAL parameters.
        Guarantees zero session leaks into asyncpg connection pool.
        """
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                for param, val in gucs.items():
                    safe_param = param.replace(";", "").replace("'", "")
                    await conn.execute(f"SET LOCAL {safe_param} = $1;", str(val))
                return await coro_fn(conn)

    async def verify_configuration_health(self) -> Dict[str, Any]:
        """Audits file errors and pending restarts."""
        async with self.pool.acquire() as conn:
            file_errors = await conn.fetch("""
                SELECT sourcefile, sourceline, name, setting, error
                FROM pg_file_settings
                WHERE error IS NOT NULL OR applied = false;
            """)

            pending_restarts = await conn.fetch("""
                SELECT name, setting, context
                FROM pg_settings
                WHERE pending_restart = true;
            """)

            return {
                "file_error_count": len(file_errors),
                "file_errors": [dict(r) for r in file_errors],
                "pending_restart_count": len(pending_restarts),
                "pending_restarts": [dict(r) for r in pending_restarts]
            }
```

### 5.4 Rust (`tokio-postgres`): Scoped Transaction Invariant Guard

```rust
use tokio_postgres::{Client, Error, Transaction};
use std::collections::HashMap;

pub struct RustGucGuard<'a> {
    client: &'a mut Client,
}

impl<'a> RustGucGuard<'a> {
    pub fn new(client: &'a mut Client) -> Self {
        Self { client }
    }

    /// Executes an operation inside a transaction using SET LOCAL to avoid pool contamination.
    pub async fn run_scoped<F, T>(&mut self, gucs: HashMap<&str, &str>, op: F) -> Result<T, Error>
    where
        F: FnOnce(&Transaction) -> std::pin::Pin<Box<dyn std::future::Output<Result<T, Error>> + Send + '_>>,
    {
        let tx = self.client.transaction().await?;
        for (key, val) in gucs {
            let query = format!("SET LOCAL {} = $1;", key);
            tx.execute(&query, &[&val]).await?;
        }

        let res = op(&tx).await?;
        tx.commit().await?;
        Ok(res)
    }
}
```

---

## 6. Six-State GUC Configuration Lifecycle Finite-State Machine (FSM)

```
        ┌─────────────────────────────────────────────────────────────┐
        │                     [S0: IMMUTABLE_DEFAULT]                 │
        │               PostgreSQL engine defaults active             │
        └──────────────────────────────┬──────────────────────────────┘
                                       │
                        ALTER SYSTEM / File Mutation
                                       ▼
        ┌─────────────────────────────────────────────────────────────┐
        │                 [S1: CONFIG_STAGED_AUDIT]                   │
        │           Introspect context & pg_file_settings             │
        └──────────────┬───────────────────────────────┬──────────────┘
                       │ Syntax Error                  │ Valid Syntax
                       ▼                               ▼
        ┌──────────────────────────────┐ ┌────────────────────────────┐
        │     [S2: SYNTAX_REJECTED]    │ │    [S3: SIGHUP_DISPATCH]   │
        │   error IS NOT NULL alert    │ │     SELECT pg_reload_conf  │
        └──────────────────────────────┘ └─────────────┬──────────────┘
                                                       │
                           ┌───────────────────────────┴──────────┐
              postmaster context (requires restart)               │ sighup context
                           ▼                                      ▼
        ┌──────────────────────────────┐       ┌──────────────────────┐
        │    [S4: PENDING_RESTART]     │       │ [S5: LIVE_SYNCHED]   │
        │  pending_restart = true      │       │ Dynamic reload active│
        └──────────────┬───────────────┘       └──────────────────────┘
                       │
             Postmaster Service Restart
                       ▼
        ┌──────────────────────────────┐
        │      [S5: LIVE_SYNCHED]      │
        │  Active & in-sync with IaC   │
        └──────────────────────────────┘
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

To guarantee zero connection pool leakage, configuration drift, and CVE-2018-1058 vulnerabilities, any automated PR or pipeline must pass these 5 CI gates:

| Gate | Target Invariant | CI Verification Command | DoD Acceptance Threshold |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **Zero Syntax Errors in Configuration** | `SELECT COUNT(*) FROM pg_file_settings WHERE error IS NOT NULL;` | **Must return 0**. Any unapplied directive halts CI. |
| **Gate 2** | **Zero Pending Restarts on Master** | `SELECT COUNT(*) FROM pg_settings WHERE pending_restart = true;` | **Must return 0** in production deployment checks. |
| **Gate 3** | **Zero Raw `SET` on Pool-Bound Queries** | Static analysis / AST grep for `SET (statement_timeout\|search_path\|work_mem)` without `LOCAL`. | **0 occurrences**. Raw `SET` on pooled connections is banned. |
| **Gate 4** | **100% `SECURITY DEFINER` Schema Lockdown** | `SELECT proname FROM pg_proc WHERE prosecdef = true AND NOT (proconfig::text LIKE '%search_path=%');` | **Must return 0 rows**. All SECURITY DEFINER functions must set `search_path`. |
| **Gate 5** | **Zero `postgresql.auto.conf` Drift in GitOps** | `SELECT COUNT(*) FROM pg_settings WHERE source = 'auto.conf';` | **0 unexpected rows**. Must match GitOps declared parameters. |

---

## Summary Directive for Autonomous Agents

1. **Transaction-Scoped Scoping (`SET LOCAL`)**: Never execute bare `SET` on pooled database connections. All parameter overrides must be executed as `SET LOCAL <key> = '<val>'` inside an explicit `BEGIN ... COMMIT` transaction.
2. **Pre-Flight Context Verification**: Inspect `pg_settings.context` prior to altering any setting. If context is `postmaster`, modifying it requires a scheduled restart and cannot be applied via `pg_reload_conf()`.
3. **Syntax Auditing**: Always query `pg_file_settings` after modifying configurations or reloading settings. An empty error column is mandatory.
4. **Security Definer Lockdown**: Every `SECURITY DEFINER` routine must declare `SET search_path = pg_catalog, pg_temp;` to permanently eliminate CVE-2018-1058 attack vectors.
5. **Session Reset Hygiene**: Always configure connection poolers with `server_reset_query = DISCARD ALL` rather than `RESET ALL` to guarantee complete deallocation of prepared statements, plans, and advisory locks.
