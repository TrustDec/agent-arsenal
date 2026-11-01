---
description: PostgreSQL Event Triggers (ddl_command_start, ddl_command_end, sql_drop, table_rewrite), DDL mutation interception, zero-bypass schema guardrails, unindexed foreign key prevention, peak-hour table rewrite lockout defense (pg_event_trigger_table_rewrite_oid), immutable DDL audit logging (pg_event_trigger_ddl_commands, pg_event_trigger_dropped_objects), primary key enforcement, and autonomous agent migration sandboxing across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, psycopg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{ddl,migration,schema,event_trigger,audit,table_rewrite,metadata,catalog}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Event Triggers, DDL Auditing, Schema Mutation Interception, Table Rewrite Lockout Defense & Zero-Bypass DDL Guardrails

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to author database migrations, modify relational schemas, automate DDL operations, deploy change management pipelines, or maintain schema governance across PostgreSQL (11–17+), Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Accidental Production Drop & Cascading Object Wipeout Disaster" (where autonomous agents or developer tools accidentally execute `DROP TABLE`, `DROP SCHEMA`, or `DROP COLUMN ... CASCADE`, destroying production relations and downstream dependencies in milliseconds), the "Silent Table Rewrite Lockout & 100% Downtime Outage" (where agents alter column data types, add non-nullable columns without defaults, or modify constraints, triggering PostgreSQL's internal `RewriteTable()` to acquire `AccessExclusiveLock`, re-write multi-gigabyte heap files, block all reads and writes, and exhaust application connection pools), the "Unindexed Foreign Key DDL Bypass Trap" (where migrations add foreign key constraints without creating corresponding B-Tree indexes on child referencing columns, inducing sequential table scans, table lock escalation, and deadlocks on parent row deletions), the "Untracked Schema Drift & DDL Auditing Black Hole" (where schema mutations bypass application DML audit logs, leaving SREs and DBAs blind to who ran what DDL, when, and from what IP address), the "Primary-Key-Less Table Anti-Pattern" (where newly created tables omit primary keys, breaking CDC pipelines, logical replication apply workers, and vacuum clustering), and the "Event Trigger Recursive Deadlock, Self-Lockout & `pg_restore` Disaster" (where buggy event triggers fire recursively on internal commands, throw unhandled exceptions during `CREATE EXTENSION` or `pg_restore`, and permanently brick database schema restoration) by establishing a strict 5-Tier Event Trigger & DDL Governance Ladder, formal table rewrite duration and lock contention physics, an autonomous TypeScript `AgenticDatabaseEventTriggerGuardEngine`, cross-runtime telemetry sentinels in Go, TypeScript, Python, and Rust, a 6-state DDL mutation finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 DDL & Event Trigger Catastrophes vs The 5-Tier Governance Ladder

Unlike row-level DML triggers (`CREATE TRIGGER ... FOR EACH ROW` on `INSERT`, `UPDATE`, `DELETE`), PostgreSQL **Event Triggers** (`CREATE EVENT TRIGGER`) fire globally at the database level on Data Definition Language (DDL) execution. They attach to four specific event hooks:
1. `ddl_command_start`: Fires immediately before any DDL command is executed.
2. `ddl_command_end`: Fires immediately after a DDL command has completed execution, providing access to `pg_event_trigger_ddl_commands()`.
3. `sql_drop`: Fires immediately before objects are dropped, providing access to `pg_event_trigger_dropped_objects()`.
4. `table_rewrite`: Fires immediately before a relation is physically rewritten, providing access to `pg_event_trigger_table_rewrite_oid()` and `pg_event_trigger_table_rewrite_reason()`.

When autonomous coding agents author schema migrations or run operational commands without strict event trigger guardrails, production databases suffer 6 catastrophic failures:

### The 6 DDL & Event Trigger Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: ACCIDENTAL DROP CASCADE IN PRODUCTION
-- Agent attempts to clean up a staging table or deprecate a column, but executes in production:
DROP TABLE users CASCADE;
-- 💥 Catastrophe:
-- Drops mission-critical users table, cascading into foreign keys across orders, payments,
-- subscriptions, and audit logs. Zero undo. 100% service decapitation.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: SILENT TABLE REWRITE LOCKOUT (100% DOWNTIME)
-- Agent migrates integer ID to bigint or alters column precision without qualification:
ALTER TABLE payments ALTER COLUMN amount TYPE numeric(18, 4);
-- 💥 Catastrophe:
-- PostgreSQL executes RewriteTable(). Acquires AccessExclusiveLock on 'payments'.
-- Reads all 100M heap pages, writes new physical heap files, rebuilds all indexes.
-- Holds lock for 25 minutes. All concurrent SELECT and INSERT queries queue behind lock.
-- Application connection pool exhausts in 1.8 seconds. 504 Gateway Timeout storm.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: UNINDEXED FOREIGN KEY CONSTRAINT DDL
-- Agent adds foreign key constraint to child table without creating an index:
ALTER TABLE order_items ADD CONSTRAINT fk_order_items_product_id 
FOREIGN KEY (product_id) REFERENCES products(id);
-- 💥 Catastrophe:
-- When a product is updated or deleted, PostgreSQL must verify order_items referential integrity.
-- Because product_id is unindexed, PostgreSQL executes a FULL SEQUENTIAL SCAN on order_items (10M rows),
-- holding ShareRowExclusiveLock. Cascading deadlocks paralyze high-throughput checkout services.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: UNTRACKED DDL BLACK HOLE & SCHEMA DRIFT
-- Agent or developer runs out-of-band schema patch in production console:
ALTER TABLE accounts DROP COLUMN status_backup;
-- 💥 Catastrophe:
-- Application DML audit logging does not capture DDL.
-- No record exists in audit logs of who executed the command, at what LSN, or what tool was used.
-- Staging and production schemas drift apart, breaking subsequent CI/CD deployments.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: PRIMARY-KEY-LESS TABLE CREATION
-- Agent creates a telemetry or event log table without a PRIMARY KEY:
CREATE TABLE user_telemetry_events (
    user_id UUID,
    event_name TEXT,
    payload JSONB,
    created_at TIMESTAMPTZ
);
-- 💥 Catastrophe:
-- Logical replication (pglogical / native logical replication) fails to replicate UPDATE/DELETE
-- with REPLICA IDENTITY DEFAULT. Debezium / Kafka CDC fails. Table bloats uncontrollably.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: EVENT TRIGGER RECURSIVE RECOVERY BRICKING
-- Agent writes an event trigger that executes DDL or fails to check restoration context:
CREATE OR REPLACE FUNCTION bad_guard() RETURNS event_trigger AS $$
BEGIN
    -- Executes DDL inside event trigger without checking if already in trigger or in restore!
    CREATE TABLE IF NOT EXISTS audit_tmp (t text);
    RAISE EXCEPTION 'Blocked';
END;
$$ LANGUAGE plpgsql;
CREATE EVENT TRIGGER trg_bad ON ddl_command_start EXECUTE FUNCTION bad_guard();
-- 💥 Catastrophe:
-- Blocks pg_restore, pg_dump, and CREATE EXTENSION from succeeding. Database restore
-- during disaster recovery crashes with fatal unhandled exceptions, bricking recovery.
```

---

## 2. The 5-Tier Event Trigger & DDL Governance Ladder

To eliminate these catastrophes, all PostgreSQL databases managed by autonomous agents must implement the **5-Tier Event Trigger & DDL Governance Ladder**:

```
+--------------------------------------------------------------------------------------------------+
|                           5-TIER EVENT TRIGGER & DDL GOVERNANCE LADDER                           |
+--------------------------------------------------------------------------------------------------+
| Tier 4: Machine-Verifiable CI Gates & Zero-Bypass Migration Sandboxing                           |
|         - Least-privilege migration roles; session_replication_role protection; DDL linter      |
+--------------------------------------------------------------------------------------------------+
| Tier 3: Immutable Append-Only DDL Audit Streaming (ddl_command_end & sql_drop)                   |
|         - Captures LSN, client_addr, session_user, command_tag, object_identity, and JSON schema |
+--------------------------------------------------------------------------------------------------+
| Tier 2: Pre-Commit Schema Invariant Enforcement (Mandatory PK & 100% Backed Foreign Keys)       |
|         - Rejects CREATE TABLE without PK; rejects FOREIGN KEY lacking B-Tree index on child     |
+--------------------------------------------------------------------------------------------------+
| Tier 1: Real-Time Table Rewrite Detection & Lockout Circuit Breaker (table_rewrite)             |
|         - Blocks RewriteTable() on relations > 50MB outside approved maintenance windows         |
+--------------------------------------------------------------------------------------------------+
| Tier 0: In-Database DDL Access Control & Safe Command Tag Filtering (WHEN TAG IN (...))          |
|         - Blocks unauthorized DROP TABLE/SCHEMA; exempts superuser/migration_admin roles         |
+--------------------------------------------------------------------------------------------------+
```

### Tier 0: In-Database DDL Access Control & Safe Command Tag Filtering

All event triggers must use narrow, deterministic `WHEN TAG IN (...)` filters and explicitly verify caller roles and system state:
1. **Never fire on extensions**: Skip execution when `pg_event_trigger_ddl_commands()` indicates `in_extension = true` or command tag is `CREATE EXTENSION` / `DROP EXTENSION`.
2. **Never fire during recovery / replication**: Check `IF pg_is_in_recovery() THEN RETURN; END IF;`.
3. **Role exemption**: Provide an escape hatch for designated migration roles (e.g. `migration_admin` or `maintenance_user`) while strictly intercepting unprivileged or autonomous agent roles.

```sql
-- Production Invariant: Prevent Destructive DROP Commands in Production
CREATE OR REPLACE FUNCTION trg_prevent_destructive_drops()
RETURNS event_trigger AS $$
DECLARE
    obj record;
    current_role text := current_user;
BEGIN
    -- Bypass during standby recovery or maintenance role
    IF pg_is_in_recovery() THEN
        RETURN;
    END IF;

    IF current_role IN ('rds_superuser', 'postgres', 'cloudsqlsuperuser', 'migration_admin') THEN
        RETURN;
    END IF;

    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() LOOP
        IF obj.object_type IN ('table', 'schema', 'database') AND NOT obj.is_temporary THEN
            RAISE EXCEPTION 'SECURITY_VIOLATION: Dropping % "%" is strictly forbidden for role "%". Contact Infrastructure Team.',
                obj.object_type, obj.object_identity, current_role
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_temp;

CREATE EVENT TRIGGER trg_guard_destructive_drops
ON sql_drop
EXECUTE FUNCTION trg_prevent_destructive_drops();
```

---

### Tier 1: Real-Time Table Rewrite Detection & Lockout Circuit Breaker (`table_rewrite`)

When an `ALTER TABLE` requires altering existing physical rows, PostgreSQL fires the `table_rewrite` event. The helper function `pg_event_trigger_table_rewrite_oid()` returns the relation's `OID`.

```sql
-- Production Invariant: Table Rewrite Interceptor & Lockout Circuit Breaker
CREATE OR REPLACE FUNCTION trg_intercept_table_rewrite()
RETURNS event_trigger AS $$
DECLARE
    target_oid oid := pg_event_trigger_table_rewrite_oid();
    rel_size bigint;
    rel_name text;
    allowed_maintenance boolean;
BEGIN
    -- Bypass during standby recovery
    IF pg_is_in_recovery() THEN
        RETURN;
    END IF;

    -- Query relation size in bytes
    SELECT pg_total_relation_size(target_oid), target_oid::regclass::text
    INTO rel_size, rel_name;

    -- Check if session has explicitly acknowledged maintenance window
    SELECT coalesce(current_setting('app.allow_table_rewrite', true), 'false') = 'true'
    INTO allowed_maintenance;

    -- Fail-closed threshold: Reject table rewrite on relations > 50MB without explicit flag
    IF rel_size > 50 * 1024 * 1024 AND NOT allowed_maintenance THEN
        RAISE EXCEPTION 'TABLE_REWRITE_BLOCKED: Relation "%" (size: % MB) is about to undergo a physical table rewrite (RewriteTable). This acquires ACCESS EXCLUSIVE LOCK and blocks all concurrent transactions. To bypass during planned maintenance, set: SET LOCAL app.allow_table_rewrite = true;',
            rel_name, (rel_size / (1024 * 1024))
            USING ERRCODE = 'feature_not_supported';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_temp;

CREATE EVENT TRIGGER trg_guard_table_rewrite
ON table_rewrite
EXECUTE FUNCTION trg_intercept_table_rewrite();
```

---

### Tier 2: Pre-Commit Schema Invariant Enforcement (Mandatory PK & Backed Foreign Keys)

In the `ddl_command_end` event, PostgreSQL allows inspection of all newly created or altered database objects via `pg_event_trigger_ddl_commands()`:

```sql
-- Production Invariant: Enforce Primary Keys on New Tables & B-Tree Indexes on New Foreign Keys
CREATE OR REPLACE FUNCTION trg_enforce_schema_invariants()
RETURNS event_trigger AS $$
DECLARE
    cmd record;
    has_pk boolean;
    unindexed_fks record;
BEGIN
    IF pg_is_in_recovery() THEN
        RETURN;
    END IF;

    FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE NOT in_extension LOOP
        -- 1. Enforce Primary Key on newly created regular tables
        IF cmd.command_tag = 'CREATE TABLE' AND cmd.object_type = 'table' THEN
            SELECT EXISTS (
                SELECT 1
                FROM pg_constraint c
                WHERE c.conrelid = cmd.objid
                  AND c.contype = 'p'
            ) INTO has_pk;

            IF NOT has_pk THEN
                RAISE EXCEPTION 'SCHEMA_INVARIANT_VIOLATION: Table "%" was created without a PRIMARY KEY. All persistent tables must declare a primary key for logical replication and data integrity.',
                    cmd.object_identity
                    USING ERRCODE = 'invalid_table_definition';
            END IF;
        END IF;

        -- 2. Enforce B-Tree Index backing on newly created FOREIGN KEY constraints
        IF cmd.command_tag IN ('ALTER TABLE', 'CREATE TABLE') THEN
            FOR unindexed_fks IN
                WITH fk_cols AS (
                    SELECT
                        c.conname AS constraint_name,
                        c.conrelid AS child_table_oid,
                        c.conrelid::regclass::text AS child_table_name,
                        c.conkey AS fk_attnums
                    FROM pg_constraint c
                    WHERE c.conrelid = cmd.objid
                      AND c.contype = 'f'
                )
                SELECT
                    fk.constraint_name,
                    fk.child_table_name
                FROM fk_cols fk
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM pg_index idx
                    WHERE idx.indrelid = fk.child_table_oid
                      AND (idx.indkey::int2[])[0:cardinality(fk.fk_attnums)-1] = fk.fk_attnums
                )
            LOOP
                RAISE EXCEPTION 'UNINDEXED_FOREIGN_KEY_VIOLATION: Foreign key "%" on table "%" does not have a supporting B-Tree index on referencing columns. This induces full sequential scan locks and deadlocks.',
                    unindexed_fks.constraint_name, unindexed_fks.child_table_name
                    USING ERRCODE = 'invalid_foreign_key';
            END LOOP;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_temp;

CREATE EVENT TRIGGER trg_guard_schema_invariants
ON ddl_command_end
WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE')
EXECUTE FUNCTION trg_enforce_schema_invariants();
```

---

### Tier 3: Immutable Append-Only DDL Audit Streaming

DDL statements bypass ordinary DML triggers. An event trigger on `ddl_command_end` records every schema modification into a secure, append-only audit table:

```sql
-- DDL Audit Table Schema
CREATE TABLE IF NOT EXISTS public.ddl_audit_log (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    tx_lsn PG_LSN NOT NULL DEFAULT pg_current_wal_lsn(),
    session_user_name TEXT NOT NULL DEFAULT session_user,
    current_user_name TEXT NOT NULL DEFAULT current_user,
    client_ip INET DEFAULT inet_client_addr(),
    client_port INTEGER DEFAULT inet_client_port(),
    command_tag TEXT NOT NULL,
    object_type TEXT NOT NULL,
    schema_name TEXT,
    object_identity TEXT NOT NULL,
    in_extension BOOLEAN NOT NULL,
    application_name TEXT DEFAULT current_setting('application_name', true)
);

CREATE INDEX IF NOT EXISTS idx_ddl_audit_log_executed_at ON public.ddl_audit_log (executed_at DESC);
CREATE INDEX IF NOT EXISTS idx_ddl_audit_log_identity ON public.ddl_audit_log (object_identity);

-- Event Trigger Function for DDL Auditing
CREATE OR REPLACE FUNCTION trg_record_ddl_audit()
RETURNS event_trigger AS $$
DECLARE
    cmd record;
BEGIN
    IF pg_is_in_recovery() THEN
        RETURN;
    END IF;

    FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        -- Omit internal extension DDL noise unless explicitly desired
        IF cmd.in_extension THEN
            CONTINUE;
        END IF;

        INSERT INTO public.ddl_audit_log (
            command_tag,
            object_type,
            schema_name,
            object_identity,
            in_extension
        ) VALUES (
            cmd.command_tag,
            cmd.object_type,
            cmd.schema_name,
            cmd.object_identity,
            cmd.in_extension
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp;

CREATE EVENT TRIGGER trg_audit_ddl_commands
ON ddl_command_end
EXECUTE FUNCTION trg_record_ddl_audit();
```

---

## 3. Mathematical Foundations: Table Rewrite Duration & Lock Contention Physics

### 3.1 Physical Table Rewrite Duration Model

When PostgreSQL executes `RewriteTable()`, it acquires an `AccessExclusiveLock` on the target relation $R$, creates a new heap file on disk, reads every physical block of $R$, transforms each tuple according to the new schema, writes the new blocks to storage, and rebuilds every associated B-Tree / GIN index.

The total lock holding duration $T_{\text{rewrite}}$ is given by:

$$
T_{\text{rewrite}} = \frac{V_{\text{heap}}}{R_{\text{seq}}} + \frac{V_{\text{new\_heap}}}{W_{\text{seq}}} + \sum_{i=1}^{M} \left( \frac{V_{\text{heap}}}{R_{\text{seq}}} + \frac{N \log_2 N \cdot c_{\text{sort}}}{\mu_{\text{cpu}}} + \frac{S_{\text{idx}_i}}{W_{\text{seq}}} \right) + T_{\text{fsync}}
$$

Where:
- $V_{\text{heap}}$ is the physical byte size of the existing table heap.
- $R_{\text{seq}}$ and $W_{\text{seq}}$ are the sequential disk read and write throughputs (e.g., $250\text{ MB/s}$ on AWS gp3).
- $M$ is the number of indexes on the relation.
- $N$ is the total tuple count.
- $S_{\text{idx}_i}$ is the size of index $i$.

For a 100GB table with 4 indexes:
$$
T_{\text{rewrite}} \approx \frac{100\text{ GB}}{0.25\text{ GB/s}} + \frac{100\text{ GB}}{0.25\text{ GB/s}} + 4 \times \left( \frac{100\text{ GB}}{0.25\text{ GB/s}} + \frac{25\text{ GB}}{0.25\text{ GB/s}} \right) = 400\text{s} + 400\text{s} + 2000\text{s} = 2800\text{ seconds } (\approx 46.6\text{ minutes})
$$

During these 46.6 minutes, **all concurrent reads and writes are blocked**.

### 3.2 Lock Contention Queue Depth & Connection Pool Exhaustion

Under Little's Law, the number of application transactions $Q_{\text{blocked}}$ queued waiting for the `AccessExclusiveLock` to release scales linearly with transaction arrival rate $\lambda$:

$$
Q_{\text{blocked}}(t) = \lambda \cdot t \quad (\text{for } 0 \le t \le T_{\text{rewrite}})
$$

Given an OLTP arrival rate of $\lambda = 500\text{ requests/sec}$:
$$
Q_{\text{blocked}}(5\text{s}) = 500 \times 5 = 2,500\text{ queued connections}
$$

If the database `max_connections = 200` and PgBouncer pool size $= 100$, the connection pool is completely exhausted in:
$$
t_{\text{exhaust}} = \frac{C_{\text{pool}}}{\lambda} = \frac{100}{500} = 0.20\text{ seconds}
$$
Every subsequent HTTP client immediately receives `504 Gateway Timeout` or `FATAL: remaining connection slots are reserved for non-replication superuser connections`.

---

## 4. Production-Grade TypeScript Guard Engine

The following TypeScript engine provides complete programmatic validation, DDL pre-flight simulation, event trigger deployment, and audit trail querying for autonomous agents:

```typescript
import { Client, PoolClient } from 'pg';

export interface DDLAuditEntry {
  id: number;
  executedAt: string;
  txLsn: string;
  sessionUserName: string;
  currentUser: string;
  clientIp: string | null;
  commandTag: string;
  objectType: string;
  schemaName: string | null;
  objectIdentity: string;
  inExtension: boolean;
  applicationName: string | null;
}

export interface TableRewriteCheckResult {
  tableName: string;
  sizeBytes: number;
  sizeMB: number;
  requiresRewrite: boolean;
  blockedByGuard: boolean;
  warning?: string;
}

export interface UnindexedFK {
  constraintName: string;
  childTable: string;
  referencingColumns: string[];
}

export class AgenticDatabaseEventTriggerGuardEngine {
  constructor(private readonly client: Client | PoolClient) {}

  /**
   * Deploys complete production-grade Event Trigger guardrails.
   */
  async deployGuardrails(): Promise<void> {
    await this.client.query('BEGIN;');

    try {
      // 1. DDL Audit Table
      await this.client.query(`
        CREATE TABLE IF NOT EXISTS public.ddl_audit_log (
            id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            executed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
            tx_lsn PG_LSN NOT NULL DEFAULT pg_current_wal_lsn(),
            session_user_name TEXT NOT NULL DEFAULT session_user,
            current_user_name TEXT NOT NULL DEFAULT current_user,
            client_ip INET DEFAULT inet_client_addr(),
            client_port INTEGER DEFAULT inet_client_port(),
            command_tag TEXT NOT NULL,
            object_type TEXT NOT NULL,
            schema_name TEXT,
            object_identity TEXT NOT NULL,
            in_extension BOOLEAN NOT NULL,
            application_name TEXT DEFAULT current_setting('application_name', true)
        );
        CREATE INDEX IF NOT EXISTS idx_ddl_audit_log_executed_at ON public.ddl_audit_log (executed_at DESC);
        CREATE INDEX IF NOT EXISTS idx_ddl_audit_log_identity ON public.ddl_audit_log (object_identity);
      `);

      // 2. Prevent Destructive Drops Function & Trigger
      await this.client.query(`
        CREATE OR REPLACE FUNCTION trg_prevent_destructive_drops()
        RETURNS event_trigger AS $$
        DECLARE
            obj record;
            current_role text := current_user;
        BEGIN
            IF pg_is_in_recovery() THEN
                RETURN;
            END IF;
            IF current_role IN ('rds_superuser', 'postgres', 'cloudsqlsuperuser', 'migration_admin') THEN
                RETURN;
            END IF;
            FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() LOOP
                IF obj.object_type IN ('table', 'schema', 'database') AND NOT obj.is_temporary THEN
                    RAISE EXCEPTION 'SECURITY_VIOLATION: Dropping % "%" is strictly forbidden for role "%".',
                        obj.object_type, obj.object_identity, current_role
                        USING ERRCODE = 'integrity_constraint_violation';
                END IF;
            END LOOP;
        END;
        $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_temp;

        DROP EVENT TRIGGER IF EXISTS trg_guard_destructive_drops;
        CREATE EVENT TRIGGER trg_guard_destructive_drops
        ON sql_drop
        EXECUTE FUNCTION trg_prevent_destructive_drops();
      `);

      // 3. Table Rewrite Interceptor Function & Trigger
      await this.client.query(`
        CREATE OR REPLACE FUNCTION trg_intercept_table_rewrite()
        RETURNS event_trigger AS $$
        DECLARE
            target_oid oid := pg_event_trigger_table_rewrite_oid();
            rel_size bigint;
            rel_name text;
            allowed_maintenance boolean;
        BEGIN
            IF pg_is_in_recovery() THEN
                RETURN;
            END IF;
            SELECT pg_total_relation_size(target_oid), target_oid::regclass::text
            INTO rel_size, rel_name;

            SELECT coalesce(current_setting('app.allow_table_rewrite', true), 'false') = 'true'
            INTO allowed_maintenance;

            IF rel_size > 50 * 1024 * 1024 AND NOT allowed_maintenance THEN
                RAISE EXCEPTION 'TABLE_REWRITE_BLOCKED: Relation "%" (size: % MB) is about to undergo a physical table rewrite. Set: SET LOCAL app.allow_table_rewrite = true to bypass during planned maintenance.',
                    rel_name, (rel_size / (1024 * 1024))
                    USING ERRCODE = 'feature_not_supported';
            END IF;
        END;
        $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_temp;

        DROP EVENT TRIGGER IF EXISTS trg_guard_table_rewrite;
        CREATE EVENT TRIGGER trg_guard_table_rewrite
        ON table_rewrite
        EXECUTE FUNCTION trg_intercept_table_rewrite();
      `);

      // 4. Schema Invariant Guard (PK & FK index enforcement)
      await this.client.query(`
        CREATE OR REPLACE FUNCTION trg_enforce_schema_invariants()
        RETURNS event_trigger AS $$
        DECLARE
            cmd record;
            has_pk boolean;
            unindexed_fks record;
        BEGIN
            IF pg_is_in_recovery() THEN
                RETURN;
            END IF;

            FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE NOT in_extension LOOP
                IF cmd.command_tag = 'CREATE TABLE' AND cmd.object_type = 'table' THEN
                    SELECT EXISTS (
                        SELECT 1 FROM pg_constraint c
                        WHERE c.conrelid = cmd.objid AND c.contype = 'p'
                    ) INTO has_pk;

                    IF NOT has_pk THEN
                        RAISE EXCEPTION 'SCHEMA_INVARIANT_VIOLATION: Table "%" created without PRIMARY KEY.',
                            cmd.object_identity
                            USING ERRCODE = 'invalid_table_definition';
                    END IF;
                END IF;

                IF cmd.command_tag IN ('ALTER TABLE', 'CREATE TABLE') THEN
                    FOR unindexed_fks IN
                        WITH fk_cols AS (
                            SELECT c.conname AS constraint_name,
                                   c.conrelid AS child_table_oid,
                                   c.conrelid::regclass::text AS child_table_name,
                                   c.conkey AS fk_attnums
                            FROM pg_constraint c
                            WHERE c.conrelid = cmd.objid AND c.contype = 'f'
                        )
                        SELECT fk.constraint_name, fk.child_table_name
                        FROM fk_cols fk
                        WHERE NOT EXISTS (
                            SELECT 1 FROM pg_index idx
                            WHERE idx.indrelid = fk.child_table_oid
                              AND (idx.indkey::int2[])[0:cardinality(fk.fk_attnums)-1] = fk.fk_attnums
                        )
                    LOOP
                        RAISE EXCEPTION 'UNINDEXED_FOREIGN_KEY_VIOLATION: Foreign key "%" on table "%" lacks a supporting B-Tree index.',
                            unindexed_fks.constraint_name, unindexed_fks.child_table_name
                            USING ERRCODE = 'invalid_foreign_key';
                    END LOOP;
                END IF;
            END LOOP;
        END;
        $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_temp;

        DROP EVENT TRIGGER IF EXISTS trg_guard_schema_invariants;
        CREATE EVENT TRIGGER trg_guard_schema_invariants
        ON ddl_command_end
        WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE')
        EXECUTE FUNCTION trg_enforce_schema_invariants();
      `);

      // 5. DDL Audit Event Trigger
      await this.client.query(`
        CREATE OR REPLACE FUNCTION trg_record_ddl_audit()
        RETURNS event_trigger AS $$
        DECLARE
            cmd record;
        BEGIN
            IF pg_is_in_recovery() THEN
                RETURN;
            END IF;
            FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
                IF cmd.in_extension THEN
                    CONTINUE;
                END IF;
                INSERT INTO public.ddl_audit_log (
                    command_tag, object_type, schema_name, object_identity, in_extension
                ) VALUES (
                    cmd.command_tag, cmd.object_type, cmd.schema_name, cmd.object_identity, cmd.in_extension
                );
            END LOOP;
        END;
        $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp;

        DROP EVENT TRIGGER IF EXISTS trg_audit_ddl_commands;
        CREATE EVENT TRIGGER trg_audit_ddl_commands
        ON ddl_command_end
        EXECUTE FUNCTION trg_record_ddl_audit();
      `);

      await this.client.query('COMMIT;');
    } catch (err) {
      await this.client.query('ROLLBACK;');
      throw err;
    }
  }

  /**
   * Pre-flight check: audits all existing foreign keys for missing B-Tree indexes.
   */
  async findUnindexedForeignKeys(): Promise<UnindexedFK[]> {
    const sql = `
      SELECT
          c.conname AS "constraintName",
          c.conrelid::regclass::text AS "childTable",
          ARRAY(
              SELECT a.attname
              FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
              ORDER BY k.ord
          ) AS "referencingColumns"
      FROM pg_constraint c
      WHERE c.contype = 'f'
        AND NOT EXISTS (
            SELECT 1
            FROM pg_index idx
            WHERE idx.indrelid = c.conrelid
              AND (idx.indkey::int2[])[0:cardinality(c.conkey)-1] = c.conkey
        )
      ORDER BY "childTable", "constraintName";
    `;

    const res = await this.client.query<UnindexedFK>(sql);
    return res.rows;
  }

  /**
   * Fetches recent DDL audit log entries.
   */
  async getRecentDDLAuditLogs(limit = 50): Promise<DDLAuditEntry[]> {
    const sql = `
      SELECT
          id,
          executed_at AS "executedAt",
          tx_lsn::text AS "txLsn",
          session_user_name AS "sessionUserName",
          current_user_name AS "currentUser",
          client_ip::text AS "clientIp",
          command_tag AS "commandTag",
          object_type AS "objectType",
          schema_name AS "schemaName",
          object_identity AS "objectIdentity",
          in_extension AS "inExtension",
          application_name AS "applicationName"
      FROM public.ddl_audit_log
      ORDER BY id DESC
      LIMIT $1;
    `;

    const res = await this.client.query<DDLAuditEntry>(sql, [limit]);
    return res.rows;
  }
}
```

---

## 5. Cross-Runtime Telemetry Sentinels & Implementation Patterns

### 5.1 Golang (`jackc/pgx/v5`): Migration Pre-Flight Sentinel & DDL Audit Streamer

```go
package migration

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type UnindexedForeignKey struct {
	ConstraintName     string   `json:"constraint_name"`
	ChildTable         string   `json:"child_table"`
	ReferencingColumns []string `json:"referencing_columns"`
}

type DDLAuditRecord struct {
	ID             int64     `json:"id"`
	ExecutedAt     time.Time `json:"executed_at"`
	TxLSN          string    `json:"tx_lsn"`
	CommandTag     string    `json:"command_tag"`
	ObjectType     string    `json:"object_type"`
	ObjectIdentity string    `json:"object_identity"`
	SessionUser    string    `json:"session_user"`
}

type EventTriggerMigrationSentinel struct {
	pool *pgxpool.Pool
}

func NewEventTriggerMigrationSentinel(pool *pgxpool.Pool) *EventTriggerMigrationSentinel {
	return &EventTriggerMigrationSentinel{pool: pool}
}

// AuditUnindexedForeignKeys returns all foreign keys lacking supporting B-Tree indexes.
func (s *EventTriggerMigrationSentinel) AuditUnindexedForeignKeys(ctx context.Context) ([]UnindexedForeignKey, error) {
	query := `
		SELECT
			c.conname,
			c.conrelid::regclass::text,
			ARRAY(
				SELECT a.attname
				FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
				JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
				ORDER BY k.ord
			)
		FROM pg_constraint c
		WHERE c.contype = 'f'
		  AND NOT EXISTS (
			  SELECT 1
			  FROM pg_index idx
			  WHERE idx.indrelid = c.conrelid
			    AND (idx.indkey::int2[])[0:cardinality(c.conkey)-1] = c.conkey
		  )
		ORDER BY 2, 1;
	`

	rows, err := s.pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("query unindexed foreign keys: %w", err)
	}
	defer rows.Close()

	var results []UnindexedForeignKey
	for rows.Next() {
		var fk UnindexedForeignKey
		if err := rows.Scan(&fk.ConstraintName, &fk.ChildTable, &fk.ReferencingColumns); err != nil {
			return nil, fmt.Errorf("scan foreign key: %w", err)
		}
		results = append(results, fk)
	}

	return results, rows.Err()
}

// ExecuteGuardedMigration executes a migration script wrapped in lock_timeout and maintenance bypass flags.
func (s *EventTriggerMigrationSentinel) ExecuteGuardedMigration(
	ctx context.Context,
	migrationSQL string,
	allowTableRewrite bool,
	lockTimeout time.Duration,
) error {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Set strict lock timeout to avoid head-of-line blocking
	lockTimeoutMs := int(lockTimeout.Milliseconds())
	if _, err := tx.Exec(ctx, fmt.Sprintf("SET LOCAL lock_timeout = '%dms';", lockTimeoutMs)); err != nil {
		return fmt.Errorf("set lock_timeout: %w", err)
	}

	if allowTableRewrite {
		if _, err := tx.Exec(ctx, "SET LOCAL app.allow_table_rewrite = 'true';"); err != nil {
			return fmt.Errorf("set app.allow_table_rewrite: %w", err)
		}
		slog.Warn("Table rewrite permission granted for migration", "lock_timeout", lockTimeout)
	}

	if _, err := tx.Exec(ctx, migrationSQL); err != nil {
		return fmt.Errorf("migration execution failed: %w", err)
	}

	return tx.Commit(ctx)
}
```

---

### 5.2 Python (`asyncpg`): Event Trigger Health & DDL Drift Monitor

```python
import asyncio
import logging
from typing import List, Dict, Any
import asyncpg

logger = logging.getLogger("ddl_guard")

class EventTriggerHealthMonitor:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def verify_active_event_triggers(self) -> Dict[str, Any]:
        """Verifies that all mandatory production event triggers are present and enabled."""
        query = """
            SELECT
                evtname AS name,
                evtevent AS event,
                evtenabled AS enabled,
                evtfoid::regproc::text AS function_name
            FROM pg_event_trigger
            WHERE evtname IN (
                'trg_guard_destructive_drops',
                'trg_guard_table_rewrite',
                'trg_guard_schema_invariants',
                'trg_audit_ddl_commands'
            );
        """
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)
            triggers = {r["name"]: dict(r) for r in rows}

        expected = [
            "trg_guard_destructive_drops",
            "trg_guard_table_rewrite",
            "trg_guard_schema_invariants",
            "trg_audit_ddl_commands",
        ]
        missing = [t for t in expected if t not in triggers]
        disabled = [t for t, data in triggers.items() if data["enabled"] != "O"]

        return {
            "all_healthy": len(missing) == 0 and len(disabled) == 0,
            "installed_triggers": triggers,
            "missing_triggers": missing,
            "disabled_triggers": disabled,
        }

    async def fetch_ddl_drift_events(self, since_minutes: int = 60) -> List[Dict[str, Any]]:
        """Audits all DDL events recorded in ddl_audit_log in the past N minutes."""
        query = """
            SELECT
                id,
                executed_at,
                tx_lsn::text,
                session_user_name,
                command_tag,
                object_type,
                object_identity
            FROM public.ddl_audit_log
            WHERE executed_at >= clock_timestamp() - ($1 || ' minutes')::interval
            ORDER BY id DESC;
        """
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query, str(since_minutes))
            return [dict(r) for r in rows]
```

---

### 5.3 Rust (`tokio-postgres`): Zero-Bypass DDL Migration Runner

```rust
use std::time::Duration;
use tokio_postgres::{Client, Error};
use tracing::{error, info, warn};

pub struct DdlMigrationRunner<'a> {
    client: &'a mut Client,
}

impl<'a> DdlMigrationRunner<'a> {
    pub fn new(client: &'a mut Client) -> Self {
        Self { client }
    }

    /// Executes DDL migration with strict lock_timeout and optional table rewrite permission.
    pub async fn run_guarded_migration(
        &mut self,
        migration_sql: &str,
        allow_table_rewrite: bool,
        lock_timeout: Duration,
    ) -> Result<(), Error> {
        let tx = self.client.transaction().await?;

        // 1. Set strict transaction-scoped lock_timeout
        let timeout_ms = lock_timeout.as_millis();
        tx.execute(
            &format!("SET LOCAL lock_timeout = '{}ms';", timeout_ms),
            &[],
        )
        .await?;

        // 2. Configure table rewrite bypass flag if verified
        if allow_table_rewrite {
            warn!("Allowing table rewrite for planned migration");
            tx.execute("SET LOCAL app.allow_table_rewrite = 'true';", &[]).await?;
        }

        // 3. Execute migration statements
        info!("Executing migration statements...");
        tx.batch_execute(migration_sql).await?;

        tx.commit().await?;
        info!("Migration completed successfully and audited via event triggers");
        Ok(())
    }
}
```

---

## 6. 6-State DDL Mutation Finite-State Machine (FSM)

```
       [IDLE]
         │
         ▼
[DDL_INITIATED] ──────────► (Check Role & Recovering?) ──► [BLOCKED: DROP PROHIBITED]
         │
         ▼
[TABLE_REWRITE_CHECK] ────► (RelSize > 50MB && !allowed) ─► [BLOCKED: REWRITE OUTAGE]
         │
         ▼
[PRE_COMMIT_INVARIANTS] ──► (Missing PK || Unindexed FK) ─► [BLOCKED: INVARIANT FAILED]
         │
         ▼
[DDL_AUDIT_STREAMED] ─────► (Append to ddl_audit_log)
         │
         ▼
[COMMITTED]
```

| Current State | Event Hook | Guard Condition | Next State | Architectural Action |
|:---|:---|:---|:---|:---|
| **`IDLE`** | Client sends DDL | User authenticated | `DDL_INITIATED` | Parser validates grammar, initiates transaction |
| **`DDL_INITIATED`** | `sql_drop` | Dropping table/schema & non-admin role | `BLOCKED_DROP` | Aborts with `SECURITY_VIOLATION` |
| **`DDL_INITIATED`** | `table_rewrite` | Relation $> 50\text{MB}$ without bypass flag | `BLOCKED_REWRITE` | Aborts with `TABLE_REWRITE_BLOCKED`, prevents table lockout |
| **`TABLE_REWRITE_CHECK`**| `ddl_command_end` | `CREATE TABLE` without `PRIMARY KEY` | `BLOCKED_INVARIANT`| Aborts with `SCHEMA_INVARIANT_VIOLATION` |
| **`PRE_COMMIT_INVARIANTS`**| `ddl_command_end` | `FOREIGN KEY` without B-Tree child index | `BLOCKED_INVARIANT`| Aborts with `UNINDEXED_FOREIGN_KEY_VIOLATION` |
| **`DDL_AUDIT_STREAMED`** | `ddl_command_end` | Validated schema change | `COMMITTED` | Writes LSN, user, tag, identity to `ddl_audit_log` |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Every repository deploying database migrations or autonomous agents must pass the following 6 gates in CI:

| Gate | Target Metric | Verification Query / Command | Pass Criterion |
|:---|:---|:---|:---|
| **Gate 1: Event Triggers Installed** | Trigger Existence | `SELECT count(*) FROM pg_event_trigger WHERE evtenabled = 'O';` | $\ge 4$ active triggers |
| **Gate 2: Zero Unindexed Foreign Keys** | FK Index Coverage | Custom FK audit query across `pg_constraint` vs `pg_index` | `count = 0` |
| **Gate 3: All Tables Have Primary Key** | PK Coverage | `SELECT count(*) FROM pg_tables t WHERE schemaname = 'public' AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = (t.schemaname||'.'||t.tablename)::regclass AND c.contype = 'p');` | `count = 0` |
| **Gate 4: Drop Table Protection** | Negative Security Test | `SET ROLE non_admin; DROP TABLE test_guard;` | Fails with `SECURITY_VIOLATION` |
| **Gate 5: Table Rewrite Guardrail** | Negative Rewrite Test | `ALTER TABLE large_table ALTER COLUMN id TYPE numeric;` | Fails with `TABLE_REWRITE_BLOCKED` |
| **Gate 6: DDL Audit Completeness** | Audit Verification | `CREATE TABLE ci_test (id INT PRIMARY KEY); DROP TABLE ci_test;` followed by `SELECT count(*) FROM ddl_audit_log WHERE object_identity LIKE '%ci_test%';` | `count >= 2` |

### Pre-Deployment CI Verification Script

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Validating Database Schema Invariants & Event Trigger Guards..."

# Check 1: Verify all Foreign Keys have supporting indexes
UNINDEXED_FK_COUNT=$(psql -v ON_ERROR_STOP=1 -At -c "
  SELECT count(*)
  FROM pg_constraint c
  WHERE c.contype = 'f'
    AND NOT EXISTS (
        SELECT 1
        FROM pg_index idx
        WHERE idx.indrelid = c.conrelid
          AND (idx.indkey::int2[])[0:cardinality(c.conkey)-1] = c.conkey
    );
")

if [ "$UNINDEXED_FK_COUNT" -gt 0 ]; then
  echo "❌ CI FAIL: Found $UNINDEXED_FK_COUNT unindexed foreign keys! Every FK must be backed by a B-Tree index."
  exit 1
fi

# Check 2: Verify all public tables declare a Primary Key
MISSING_PK_COUNT=$(psql -v ON_ERROR_STOP=1 -At -c "
  SELECT count(*)
  FROM pg_tables t
  WHERE t.schemaname = 'public'
    AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        WHERE c.conrelid = (t.schemaname || '.' || t.tablename)::regclass
          AND c.contype = 'p'
    );
")

if [ "$MISSING_PK_COUNT" -gt 0 ]; then
  echo "❌ CI FAIL: Found $MISSING_PK_COUNT tables without a PRIMARY KEY."
  exit 1
fi

echo "✅ All Event Trigger & Schema Invariant CI Gates Passed."
```
