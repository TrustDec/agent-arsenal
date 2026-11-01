---
description: PostgreSQL enterprise audit logging (pgaudit), SOC 2 Type II, PCI-DSS v4.0, HIPAA, and GDPR compliance, session auditing (pgaudit.log) vs object auditing (pgaudit.role), sensitive parameter leakage elimination (pgaudit.log_parameter), log explosion disk exhaustion defense, system catalog noise suppression (pgaudit.log_catalog), structured SIEM log streaming (Vector/Fluentbit), superuser auditing bypass prevention, and cross-runtime invariants across Go (jackc/pgx/v5), TypeScript (drizzle-orm, prisma, pg), Python (asyncpg, psycopg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{audit,pgaudit,compliance,security,log,siem,soc2,pci}*.*,**/src/audit/**/*.{ts,js,go,rs,py},**/src/security/**/*.{ts,js,go,rs,py},**/internal/audit/**/*.{go,rs},**/migrations/**/*.{sql,ts,go,py},**/config/**/*.{ini,conf,toml,yaml,json}
alwaysApply: false
---

# Agentic Database Audit Logging (`pgaudit`), Enterprise Compliance (SOC 2, PCI-DSS, HIPAA), Session vs Object Auditing, Sensitive Parameter Masking & Disk Exhaustion Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, configure, automate, or maintain PostgreSQL enterprise audit logging (`pgaudit`), compliance frameworks (SOC 2 Type II, PCI-DSS v4.0, HIPAA Security Rule, GDPR Article 32, ISO/IEC 27001), forensic security pipelines, or data access tracking across Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `prisma`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Global Log Flooding & Disk Exhaustion Disaster (`pgaudit.log = 'all'`)" (where enabling blanket session auditing on high-throughput OLTP databases generates hundreds of gigabytes of log files per hour, filling host partitions to 100% and crashing the postmaster with `PANIC: could not write to log file: No space left on device`), the "Sensitive Parameter Leakage & Plaintext Secret Exposure Trap (`pgaudit.log_parameter = on`)" (where enabling query parameter logging prints plaintext passwords, authentication tokens, credit card PANs, and SSNs directly into audit logs and streams them to third-party SIEMs, violating PCI-DSS Requirement 3.4 and HIPAA encryption rules), the "Session vs Object Auditing Conflation & CPU Overhead Cliff" (where agents apply blanket session auditing across all operations rather than granular object-level role auditing, degrading database CPU by 25%–40% and logging millions of harmless health checks and connection pings), the "System Catalog Noise Flooding & Autovacuum Log Storm (`pgaudit.log_catalog = on`)" (where internal catalog queries executed by autovacuum, `pg_stat_statements`, and monitoring exporters overwhelm log pipelines and bury forensic signals in terabytes of noise), the "Superuser & Anonymous Service Account Non-Repudiation Failure" (where shared application pool connections execute audited queries without injecting transactional user metadata or session attribution tags, leaving forensic auditors unable to trace actions to specific human identities or API callers), and the "Unstructured 14-Field CSV Parsing Breakdown in SIEM Streaming" (where ingestion agents fail to parse pgaudit's multi-part CSV log records, dropping critical audit events and failing automated compliance checks) by establishing a strict 5-Tier Audit Governance Ladder, disk exhaustion differential calculus, mathematical signal-to-noise ratio (SNR) models, an autonomous TypeScript `AgenticDatabasePgauditGuardEngine`, cross-runtime telemetry and session-attribution sentinels in Go, TypeScript, Python, and Rust, a 6-state audit governance finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 PGAudit Catastrophes vs The 5-Tier Audit Governance Ladder

The official PostgreSQL Audit Extension (**`pgaudit`**) provides detailed session and object audit logging via standard PostgreSQL logging facilities (`stderr`, `csvlog`, or `syslog`). Unlike native PostgreSQL statement logging (`log_statement = 'all'`), which naively logs raw strings without relational structure, `pgaudit` intercepts statement execution inside the PostgreSQL executor hook, evaluates user roles, commands, schemas, and target relations, and emits structured 14-field audit records formatted for enterprise Security Information and Event Management (SIEM) systems (Splunk, Datadog, Elastic, AWS CloudWatch).

However, autonomous coding agents universally misunderstand `pgaudit`'s two fundamentally distinct logging modes—**Session Auditing** (`pgaudit.log`) and **Object Auditing** (`pgaudit.role`)—as well as the catastrophic storage and data-leakage implications of executor-level parameter logging. This triggers 6 fatal operational and compliance disasters in production:

### The 6 PGAudit Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE BLANKET SESSION LOG FLOOD & DISK CRASH
-- Agent attempts to satisfy "Audit all database actions for SOC 2 compliance" in postgresql.conf:
shared_preload_libraries = 'pgaudit'
pgaudit.log = 'all'                       -- 💥 LOGS READ, WRITE, FUNCTION, ROLE, DDL, MISC!
pgaudit.log_catalog = on                  -- 💥 LOGS EVERY INTERNAL SYSTEM CATALOG QUERY!
pgaudit.log_parameter = on                -- 💥 PRINTS EVERY SINGLE BIND PARAMETER!

-- 💥 Catastrophe:
-- 1. In a production cluster running 20,000 queries/sec:
--    Every SELECT, INSERT, UPDATE, DELETE produces a 400-byte pgaudit entry in PostgreSQL logs.
-- 2. Log generation rate: 20,000 * 400 bytes = 8 MB/s = ~29 GB/hour = ~700 GB/day!
-- 3. autovacuum and pg_stat_statements queries against pg_class, pg_attribute are logged continuously.
-- 4. Within 4 hours, the local log disk partition hits 100% capacity:
--    PANIC: could not write to log file: No space left on device
-- 5. The PostgreSQL postmaster terminates violently, dropping all client connections. Recovery requires
--    emergency disk expansion or manual shell rm under outage conditions.
-- Invariant: NEVER use pgaudit.log = 'all' in production OLTP; use targeted Object Auditing (pgaudit.role).

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: PLAINTEXT CREDENTIAL & PII LEAKAGE IN LOGS
-- Agent sets pgaudit.log_parameter = on to "debug production queries":
-- Application executes user password reset or payment processing:
UPDATE users SET password_hash = $1, ssn = $2, api_token = $3 WHERE id = $4;
-- [Parameters: $1 = '$2a$12$e8k...Zq', $2 = '123-45-6789', $3 = 'ghp_secret_token_abc123', $4 = '101']

-- 💥 Catastrophe:
-- 1. pgaudit logs the entire SQL statement AND the exact plaintext parameter values:
--    AUDIT: SESSION,1,1,WRITE,UPDATE,TABLE,public.users,"UPDATE users SET ...",<none>,<parameters: '$2a$12$e8k...', '123-45-6789', 'ghp_secret_token_abc123', '101'>
-- 2. These plaintext credentials and SSNs are written to PostgreSQL log files and shipped to CloudWatch/Datadog.
-- 3. Over 200 developers, DevOps engineers, and third-party SaaS vendors now have read access to plaintext PII.
-- 4. Instant PCI-DSS v4.0 Requirement 3.4 violation (unmasked cardholder data) and HIPAA Security Rule breach.
--    Statutory fines exceed $1,500,000 + mandatory breach notification disclosures.
-- Invariant: pgaudit.log_parameter MUST remain 'off' globally; mask sensitive attributes before execution.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: UNBOUNDED CATALOG NOISE & ZERO FORENSIC SIGNAL
-- Agent enables pgaudit.log_catalog = on:
-- Datadog agent or Prometheus postgres_exporter polls pg_stat_database every 5 seconds.
-- Autovacuum inspects dead tuples across 5,000 tables every 10 seconds.

-- 💥 Catastrophe:
-- 1. In a 24-hour period, pgaudit generates 40,000,000 log lines of SELECT * FROM pg_catalog.pg_class...
-- 2. The SIEM system (Datadog / Splunk) charges $0.20 per GB of ingested log data; monthly bill spikes by $18,000.
-- 3. During an actual security incident (unauthorized exfiltration of customer table), security analysts
--    cannot isolate malicious queries because forensic signals are buried in 99.98% catalog noise.
-- Invariant: Always configure pgaudit.log_catalog = off in production configurations.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: ANONYMOUS CONNECTION POOL IDENTITY BLINDNESS
-- Microservices connect via shared PgBouncer connection pool as user 'app_user':
-- Query issued on behalf of customer Alice:
SELECT * FROM financial_records WHERE tenant_id = 'c91e4f...';

-- 💥 Catastrophe:
-- 1. pgaudit logs: AUDIT: OBJECT,2,1,READ,SELECT,TABLE,public.financial_records,...,user: app_user
-- 2. The audit log only identifies the generic database user 'app_user'.
-- 3. There is ZERO record of which human user (Alice? Bob? Compromised API key?) triggered the query.
-- 4. SOC 2 Type II audit fails the "Non-Repudiation & User Attribution" control ($CC6.1, CC6.3).
-- Invariant: Application connections must set transactional session variables (SET LOCAL audit.actor_id = ...).

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: SUPERUSER AUDIT EVASION & MISSING DDL AUDITING
-- DBA or rogue agent connects as 'postgres' (superuser) and executes:
DROP TABLE audit_trail;
ALTER TABLE payments ALTER COLUMN amount TYPE float;

-- 💥 Catastrophe:
-- 1. If pgaudit is configured ONLY with pgaudit.role for object auditing, superuser queries that do NOT
--    match the specific granted role are NOT audited!
-- 2. Schema destructions, privilege escalations, and DDL table drops by superusers happen completely unlogged.
-- Invariant: Configure pgaudit.log = 'ddl, role' in session auditing to capture ALL schema and role mutations.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: UNSTRUCTURED 14-FIELD CSV LOG PARSER FAILURE
-- Agent configures log streaming using naive single-line regex parser:
-- Query with multiline formatting or embedded commas/quotes:
SELECT id, 'hello, world' AS msg, notes FROM ledger WHERE status = 'FAILED';

-- 💥 Catastrophe:
-- 1. pgaudit outputs 14 comma-separated fields where the statement field contains internal commas and quotes.
-- 2. Naive Fluentbit / Vector regex splits on commas, scrambling columns:
--    audit_type="AUDIT: SESSION", statement="SELECT id", target_relation="'hello", rest="world'..."
-- 3. Automated alert triggers fail to fire, and security compliance dashboards report corrupted data.
-- Invariant: Use RFC 4180 compliant CSV parsers with multiline log handling for pgaudit streams.
```

---

## 2. Mathematical Systems Invariants & Compliance Calculus

### 2.1 The Disk Exhaustion Time Horizon Equation

Let $D_{\text{free}}$ be available disk space on the database storage mount (bytes), $D_{\text{safety}}$ be the required emergency disk buffer ($20\%$ of total capacity), $\lambda_{\text{ops}}$ be transaction throughput (operations per second), and $\overline{S_{\text{log}}}$ be the mean size of an emitted `pgaudit` record (bytes, typically $350–650$ bytes).

When blanket session auditing is enabled (`pgaudit.log = 'all'`), every transaction emits at least one audit record. The time until postmaster panic crash $T_{\text{exhaust}}$ is:

$$T_{\text{exhaust}} = \frac{D_{\text{free}} - D_{\text{safety}}}{\lambda_{\text{ops}} \times \overline{S_{\text{log}}} \times (1 + \beta_{\text{param}} + \gamma_{\text{catalog}})}$$

Where:
- $\beta_{\text{param}}$ is the parameter multiplier ($\beta_{\text{param}} \approx 2.5–5.0$ if `pgaudit.log_parameter = on`, representing string argument serialization).
- $\gamma_{\text{catalog}}$ is the system catalog query amplification factor ($\gamma_{\text{catalog}} \ge 3.0$ if `pgaudit.log_catalog = on` under monitoring agents).

#### Proof of Disk Collapse under Blanket Auditing
Consider a production cluster with:
- $D_{\text{free}} = 100\text{ GB} = 100 \times 10^9\text{ bytes}$
- $D_{\text{safety}} = 20\text{ GB} = 20 \times 10^9\text{ bytes} \implies D_{\text{net}} = 80 \times 10^9\text{ bytes}$
- $\lambda_{\text{ops}} = 15,000\text{ queries/sec}$
- $\overline{S_{\text{log}}} = 450\text{ bytes}$
- $\beta_{\text{param}} = 3.0$ (`pgaudit.log_parameter = on`)
- $\gamma_{\text{catalog}} = 2.0$ (`pgaudit.log_catalog = on`)

$$\text{Log Ingestion Rate} = 15,000 \times 450 \times (1 + 3.0 + 2.0) = 15,000 \times 450 \times 6.0 = 40,500,000\text{ bytes/sec} \approx 40.5\text{ MB/sec}$$

$$T_{\text{exhaust}} = \frac{80 \times 10^9\text{ bytes}}{40.5 \times 10^6\text{ bytes/sec}} \approx 1,975\text{ seconds} \approx 32.9\text{ minutes}$$

**Conclusion**: Under blanket session logging with parameters and catalog queries enabled, the database runs completely out of disk in **under 33 minutes**, causing an unrecoverable `PANIC` crash.

---

### 2.2 The Signal-to-Noise Ratio (SNR) and Security Efficacy Theorem

Let $N_{\text{audit}}$ be the total volume of audit log entries generated in time interval $\Delta t$, $N_{\text{critical}}$ be the volume of security-sensitive operations (access to PII, credit cards, authentication changes, DDL), and $N_{\text{catalog}}$ be queries against system catalogs (`pg_class`, `pg_database`, `pg_stat_*`).

The Forensic Signal-to-Noise Ratio $\text{SNR}_{\text{audit}}$ is defined as:

$$\text{SNR}_{\text{audit}} = \frac{N_{\text{critical}}}{N_{\text{critical}} + N_{\text{noise}} + N_{\text{catalog}}}$$

Under naive agent configurations (`pgaudit.log = 'all'`, `pgaudit.log_catalog = on`):
$$N_{\text{critical}} \approx 0.01 \times N_{\text{total}}$$
$$N_{\text{noise}} \approx 0.70 \times N_{\text{total}} \quad (\text{health checks, non-sensitive OLTP reads})$$
$$N_{\text{catalog}} \approx 0.29 \times N_{\text{total}} \quad (\text{monitoring, autovacuum})$$

$$\text{SNR}_{\text{naive}} = \frac{0.01}{0.01 + 0.70 + 0.29} = 0.01 = 1.0\%$$

Under Tier 1 Object Auditing (`pgaudit.role = 'rds_pgaudit'`, `pgaudit.log_catalog = off`, `pgaudit.log = 'ddl, role'`):
$$N_{\text{noise}} \equiv 0 \quad (\text{un-granted tables completely bypass audit logger})$$
$$N_{\text{catalog}} \equiv 0 \quad (\text{catalog queries explicitly suppressed})$$

$$\text{SNR}_{\text{governed}} = \frac{N_{\text{critical}}}{N_{\text{critical}} + 0 + 0} \equiv 1.0 = 100\%$$

**Theorem**: Object Auditing increases the Forensic Signal-to-Noise Ratio by **100x**, while reducing disk I/O and SIEM ingestion bills by **99%**.

---

### 2.3 The 5-Tier Audit Governance Ladder

| Tier | Level | Mechanism | Scope | Production SLA |
| :--- | :--- | :--- | :--- | :--- |
| **Tier 0** | **Extension Pre-Flight & Baseline Hardening** | `shared_preload_libraries = 'pgaudit'`<br>`pgaudit.log_catalog = off`<br>`pgaudit.log_parameter = off` | Cluster-wide (`postgresql.conf`) | Mandatory for all database instances |
| **Tier 1** | **DDL & RBAC Session Governance** | `pgaudit.log = 'ddl, role'` | All Sessions | Captures all schema drops, role creations, and grants without logging DML |
| **Tier 2** | **Granular Object Auditing via Dedicated Role** | `pgaudit.role = 'audit_reader'`<br>`GRANT SELECT, INSERT, UPDATE, DELETE ON <sensitive_tables> TO audit_reader` | Specific Sensitive Relations (PII, Ledgers) | 0% overhead on high-throughput non-sensitive tables |
| **Tier 3** | **Transactional Actor Attribution** | `SET LOCAL audit.actor_id = '<uuid>'`<br>`SET LOCAL audit.client_ip = '<ip>'` | Microservice Connection Pools | Resolves shared-pool non-repudiation in SOC 2 / HIPAA |
| **Tier 4** | **Structured SIEM Ingestion & Watchdogs** | Vector / Fluentbit RFC 4180 CSV Parser $\to$ Datadog / Splunk with Disk Sentinel | Telemetry Pipeline | Automatic alert on log disk $> 80\%$ or unmasked PAN patterns |

---

## 3. Concrete Production Implementations

### 3.1 Hardened PostgreSQL Audit Configuration (`postgresql.conf`)

```ini
# ==============================================================================
# PGAUDIT HARDENED ENTERPRISE COMPLIANCE CONFIGURATION
# Compliant with SOC 2 Type II, PCI-DSS v4.0 (Req 10), HIPAA Security Rule
# ==============================================================================

# 1. Mandatory C-extension preload during postmaster startup
shared_preload_libraries = 'pgaudit'

# 2. Session Auditing: Strictly audit DDL and Role mutations cluster-wide
# DO NOT include 'read', 'write', or 'all' here! That belongs in Object Auditing.
pgaudit.log = 'ddl, role'

# 3. Object Auditing Role: The dedicated audit interceptor role
pgaudit.role = 'rds_pgaudit'

# 4. Strictly suppress internal catalog queries (eliminates 99% of log noise)
pgaudit.log_catalog = off

# 5. Strictly FORBID query parameter logging in production!
# Prevents passwords, SSNs, credit cards, and auth tokens from leaking into logs.
pgaudit.log_parameter = off

# 6. Audit relation logging: Disclose exact relation name in CSV/stderr output
pgaudit.log_relation = on

# 7. Audit statement text logging: Include the executed SQL statement
pgaudit.log_statement = on

# 8. Log format and level calibration
pgaudit.log_level = 'log'

# 9. Standard PostgreSQL logging format for flawless SIEM CSV/JSON extraction
log_destination = 'csvlog'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1440
log_rotation_size = 102400
log_truncate_on_rotation = off

# 10. Prefix formatting: Include timestamp, PID, user, database, and client IP
log_line_prefix = '%m [%p] %q%u@%d %a (%r): '
```

---

### 3.2 Granular Object Auditing Migration (`migrations/audit_setup.sql`)

```sql
-- ==============================================================================
-- DECLARATIVE OBJECT AUDITING WITH LEAST PRIVILEGE
-- Zero table locks, zero DML logging on high-speed telemetry
-- ==============================================================================

BEGIN;

-- 1. Create the dedicated non-login audit role (matches pgaudit.role setting)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rds_pgaudit') THEN
    CREATE ROLE rds_pgaudit NOLOGIN NOINHERIT;
  END IF;
END $$;

-- 2. Audit Sensitive Table 1: Financial Ledgers (Full CRUD Auditing)
-- Every SELECT, INSERT, UPDATE, DELETE on ledger_entries will trigger a pgaudit entry
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.ledger_entries TO rds_pgaudit;

-- 3. Audit Sensitive Table 2: User Profiles (Audit PII reads and mutations)
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.users TO rds_pgaudit;

-- 4. Audit Sensitive Table 3: Authentication Credentials (Audit all access)
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.api_keys TO rds_pgaudit;

-- 5. Non-sensitive tables (e.g. system_metrics, clickstream_events, cache_store)
-- DO NOT grant permissions on these to rds_pgaudit!
-- Result: High-frequency operational writes execute with 0% pgaudit log overhead!

-- 6. Forward-facing Default Privileges for newly created compliance tables
ALTER DEFAULT PRIVILEGES IN SCHEMA compliance
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO rds_pgaudit;

COMMIT;
```

---

### 3.3 Vector Structured Log Shipper Configuration (`vector.yaml`)

```yaml
# ==============================================================================
# VECTOR LOG PIPELINE FOR PGAUDIT RFC 4180 CSV LOG SHIPPER
# Parses 14-field pgaudit lines, masks accidental secrets, streams to SIEM
# ==============================================================================

sources:
  postgres_csv_logs:
    type: file
    include:
      - /var/log/postgresql/*.csv
    read_from: beginning
    multiline:
      start_pattern: '^"?[0-9]{4}-[0-9]{2}-[0-9]{2}'
      mode: halt_before
      condition_pattern: '^"?[0-9]{4}-[0-9]{2}-[0-9]{2}'
      timeout_ms: 1000

transforms:
  parse_pgaudit_csv:
    type: remap
    inputs:
      - postgres_csv_logs
    source: |
      # 1. Parse standard PostgreSQL CSV log row
      parsed_csv, err = parse_csv(.message)
      if err != null {
        abort
      }

      # 2. Extract standard PostgreSQL log attributes
      .log_time = parsed_csv[0]
      .user_name = parsed_csv[1]
      .database_name = parsed_csv[2]
      .process_id = to_int!(parsed_csv[3])
      .connection_from = parsed_csv[4]
      .session_id = parsed_csv[5]
      .session_line_num = to_int!(parsed_csv[6])
      .command_tag = parsed_csv[7]
      .session_start_time = parsed_csv[8]
      .virtual_transaction_id = parsed_csv[9]
      .transaction_id = parsed_csv[10]
      .error_severity = parsed_csv[11]
      .sql_state_code = parsed_csv[12]
      raw_message = parsed_csv[13]

      # 3. Check if message is a structured PGAUDIT event
      if starts_with(raw_message, "AUDIT: ") {
        audit_payload = replace(raw_message, "AUDIT: ", "")
        fields, pgaudit_err = parse_csv(audit_payload)
        
        if pgaudit_err == null && length(fields) >= 11 {
          .audit = {
            "audit_type": fields[0],           # SESSION or OBJECT
            "statement_id": to_int!(fields[1]),# Unique statement identifier
            "substatement_id": to_int!(fields[2]),
            "audit_class": fields[3],          # READ, WRITE, DDL, ROLE, FUNCTION, MISC
            "command": fields[4],              # SELECT, INSERT, UPDATE, DELETE, etc.
            "object_type": fields[5],          # TABLE, VIEW, FUNCTION, etc.
            "object_name": fields[6],          # Fully qualified name (e.g. public.users)
            "statement": fields[7],            # Executed SQL text
            "parameter": fields[8]             # Parameter values (must be <none> in prod)
          }

          # 4. Zero-Trust PII Masking: Redact card numbers or SSNs in SQL literals
          .audit.statement = replace(.audit.statement, r'\b\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}\b', "[REDACTED_PAN]")
          .audit.statement = replace(.audit.statement, r'\b\d{3}-\d{2}-\d{4}\b', "[REDACTED_SSN]")
          
          .is_pgaudit_event = true
        }
      } else {
        .is_pgaudit_event = false
      }

sinks:
  siem_destination:
    type: datadog_logs
    inputs:
      - parse_pgaudit_csv
    default_api_key: "${DATADOG_API_KEY}"
    compression: gzip
```

---

## 4. Production-Grade TypeScript Guard Engine (`AgenticDatabasePgauditGuardEngine`)

The following TypeScript engine provides complete runtime verification of `pgaudit` settings, auditing role grants, disk exhaustion time projections, and parameter masking defense:

```typescript
import { Client } from 'pg';

export interface PgauditClusterSettings {
  sharedPreloadLibraries: string[];
  pgauditLoaded: boolean;
  pgauditLog: string;
  pgauditRole: string;
  pgauditLogCatalog: boolean;
  pgauditLogParameter: boolean;
  pgauditLogRelation: boolean;
  pgauditLogStatement: boolean;
}

export interface DiskExhaustionForecast {
  freeSpaceBytes: number;
  queriesPerSecond: number;
  projectedHoursUntilPanic: number;
  isDangerous: boolean;
  recommendations: string[];
}

export interface AuditedTableReport {
  tableName: string;
  schemaName: string;
  isAudited: boolean;
  grantedPrivileges: string[];
}

export class AgenticDatabasePgauditGuardEngine {
  constructor(private readonly client: Client) {}

  /**
   * Introspects pgaudit GUC configuration directly from pg_settings.
   */
  async inspectAuditSettings(): Promise<PgauditClusterSettings> {
    const res = await this.client.query<{ name: string; setting: string }>(`
      SELECT name, setting 
      FROM pg_settings 
      WHERE name IN (
        'shared_preload_libraries',
        'pgaudit.log',
        'pgaudit.role',
        'pgaudit.log_catalog',
        'pgaudit.log_parameter',
        'pgaudit.log_relation',
        'pgaudit.log_statement'
      );
    `);

    const map = new Map<string, string>();
    for (const row of res.rows) {
      map.set(row.name, row.setting);
    }

    const preloads = (map.get('shared_preload_libraries') || '')
      .split(',')
      .map(s => s.trim().toLowerCase())
      .filter(Boolean);

    return {
      sharedPreloadLibraries: preloads,
      pgauditLoaded: preloads.includes('pgaudit'),
      pgauditLog: map.get('pgaudit.log') || '',
      pgauditRole: map.get('pgaudit.role') || '',
      pgauditLogCatalog: map.get('pgaudit.log_catalog') === 'on',
      pgauditLogParameter: map.get('pgaudit.log_parameter') === 'on',
      pgauditLogRelation: map.get('pgaudit.log_relation') === 'on',
      pgauditLogStatement: map.get('pgaudit.log_statement') === 'on',
    };
  }

  /**
   * Validates production readiness against the 5-Tier Audit Governance Ladder.
   */
  async validateComplianceGate(): Promise<{ pass: boolean; violations: string[] }> {
    const settings = await this.inspectAuditSettings();
    const violations: string[] = [];

    if (!settings.pgauditLoaded) {
      violations.push(
        'CRITICAL: pgaudit is NOT present in shared_preload_libraries! Postmaster restart required.'
      );
    }

    if (settings.pgauditLogParameter) {
      violations.push(
        'SECURITY_VIOLATION: pgaudit.log_parameter is ON! Plaintext passwords and PII are leaking into logs. Must set to OFF.'
      );
    }

    if (settings.pgauditLogCatalog) {
      violations.push(
        'PERFORMANCE_VIOLATION: pgaudit.log_catalog is ON! System catalogs will flood SIEM with millions of noise events. Must set to OFF.'
      );
    }

    const sessionLogModes = settings.pgauditLog.toLowerCase().split(',').map(s => s.trim());
    if (sessionLogModes.includes('all') || sessionLogModes.includes('read') || sessionLogModes.includes('write')) {
      violations.push(
        `CAPACITY_VIOLATION: pgaudit.log contains '${settings.pgauditLog}'. Blanket session logging on DML causes disk exhaustion! Restrict to 'ddl, role' and use Object Auditing for DML.`
      );
    }

    if (!settings.pgauditRole) {
      violations.push(
        'COMPLIANCE_VIOLATION: pgaudit.role is unset! Object auditing is disabled. Fine-grained table access is unmonitored.'
      );
    }

    return {
      pass: violations.length === 0,
      violations,
    };
  }

  /**
   * Computes disk exhaustion time horizon given available storage and query throughput.
   */
  async calculateDiskExhaustionHorizon(
    freeDiskBytes: number,
    estimatedQps: number
  ): Promise<DiskExhaustionForecast> {
    const settings = await this.inspectAuditSettings();
    const recommendations: string[] = [];

    // Base average log size
    let bytesPerQuery = 0;

    const isBlanketDML =
      settings.pgauditLog.includes('all') ||
      settings.pgauditLog.includes('read') ||
      settings.pgauditLog.includes('write');

    if (isBlanketDML) {
      bytesPerQuery += 450;
      recommendations.push("Disable session DML auditing in pgaudit.log; migrate to pgaudit.role");
    }

    if (settings.pgauditLogParameter) {
      bytesPerQuery += 800; // Average serialized parameters size
      recommendations.push("Disable pgaudit.log_parameter to prevent log size explosion and secret leaks");
    }

    if (settings.pgauditLogCatalog) {
      bytesPerQuery += 500; // Catalog inspection amplification
      recommendations.push("Set pgaudit.log_catalog = off to suppress internal monitoring overhead");
    }

    // Safety margin: 20% reserved
    const netFreeBytes = Math.max(0, freeDiskBytes * 0.8);
    const bytesPerSecond = estimatedQps * bytesPerQuery;

    let projectedHours = Infinity;
    if (bytesPerSecond > 0) {
      const secondsUntilPanic = netFreeBytes / bytesPerSecond;
      projectedHours = Number((secondsUntilPanic / 3600).toFixed(2));
    }

    const isDangerous = projectedHours < 24;

    return {
      freeSpaceBytes: freeDiskBytes,
      queriesPerSecond: estimatedQps,
      projectedHoursUntilPanic: projectedHours,
      isDangerous,
      recommendations,
    };
  }

  /**
   * Verifies that sensitive tables have explicit object-audit permissions granted to pgaudit.role.
   */
  async auditSensitiveTables(
    auditRole: string,
    sensitiveTables: string[]
  ): Promise<AuditedTableReport[]> {
    const reports: AuditedTableReport[] = [];

    for (const table of sensitiveTables) {
      const [schema, name] = table.includes('.') ? table.split('.') : ['public', table];

      const res = await this.client.query<{ privilege_type: string }>(`
        SELECT privilege_type
        FROM information_schema.role_table_grants
        WHERE grantee = $1
          AND table_schema = $2
          AND table_name = $3;
      `, [auditRole, schema, name]);

      const privs = res.rows.map(r => r.privilege_type);
      reports.push({
        tableName: name,
        schemaName: schema,
        isAudited: privs.length > 0,
        grantedPrivileges: privs,
      });
    }

    return reports;
  }
}
```

---

## 5. Cross-Runtime Implementation Sentinels

### 5.1 Go (`jackc/pgx/v5`): Scoped Session Attribution Sentinel

When microservices connect through shared pools, enforce transaction-scoped actor attribution so `pgaudit` captures the true human or service identity:

```go
package audit

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ActorContext represents human or service identity for SOC 2 / HIPAA attribution
type ActorContext struct {
	UserID    uuid.UUID
	TenantID  uuid.UUID
	ClientIP  string
	SessionID string
}

// ExecWithAuditContext executes business logic within a transaction tagged with actor metadata
func ExecWithAuditContext(
	ctx context.Context,
	pool *pgxpool.Pool,
	actor ActorContext,
	fn func(tx pgx.Tx) error,
) error {
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{
		IsoLevel: pgx.ReadCommitted,
	})
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// MANDATORY: Inject session attribution variables scoped strictly to this transaction!
	// These are picked up in log_line_prefix or custom SIEM parsers without persisting across pool reuses.
	auditPreamble := fmt.Sprintf(
		"SET LOCAL application_name = 'svc:%s'; "+
			"SET LOCAL audit.actor_id = '%s'; "+
			"SET LOCAL audit.tenant_id = '%s'; "+
			"SET LOCAL audit.client_ip = '%s';",
		actor.SessionID,
		actor.UserID.String(),
		actor.TenantID.String(),
		actor.ClientIP,
	)

	if _, err := tx.Exec(ctx, auditPreamble); err != nil {
		return fmt.Errorf("failed to inject audit attribution: %w", err)
	}

	// Execute business domain queries (will be logged by pgaudit with actor metadata)
	if err := fn(tx); err != nil {
		return err
	}

	return tx.Commit(ctx)
}
```

---

### 5.2 TypeScript (`drizzle-orm` / `pg`): Transactional Attribution Middleware

```typescript
import { Pool, PoolClient } from 'pg';

export interface AuditMetadata {
  userId: string;
  tenantId: string;
  clientIp: string;
  traceId: string;
}

export async function withAuditSession<T>(
  pool: Pool,
  metadata: AuditMetadata,
  callback: (client: PoolClient) => Promise<T>
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // Scoped transaction parameters for pgaudit attribution
    await client.query(`
      SET LOCAL application_name = $1;
      SET LOCAL audit.actor_id = $2;
      SET LOCAL audit.tenant_id = $3;
      SET LOCAL audit.client_ip = $4;
    `, [
      `app:${metadata.traceId}`,
      metadata.userId,
      metadata.tenantId,
      metadata.clientIp,
    ]);

    const result = await callback(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
```

---

### 5.3 Python (`asyncpg`): Scoped Session Attribution Sentinel

```python
import asyncpg
from typing import Callable, Any, Dict
from uuid import UUID

async def execute_audited_transaction(
    pool: asyncpg.Pool,
    actor_metadata: Dict[str, Any],
    transaction_fn: Callable[[asyncpg.Connection], Any]
) -> Any:
    """
    Executes a database transaction with injected PGAudit session attribution tags.
    Ensures zero cross-connection parameter leakage using transaction-scoped SET LOCAL.
    """
    async with pool.acquire() as conn:
        async with conn.transaction():
            actor_id = str(actor_metadata.get("user_id", "anonymous"))
            tenant_id = str(actor_metadata.get("tenant_id", "default"))
            client_ip = str(actor_metadata.get("client_ip", "127.0.0.1"))
            trace_id = str(actor_metadata.get("trace_id", "none"))

            # Inject actor attribution into the transaction scope
            await conn.execute(f"""
                SET LOCAL application_name = 'worker:{trace_id}';
                SET LOCAL audit.actor_id = '{actor_id}';
                SET LOCAL audit.tenant_id = '{tenant_id}';
                SET LOCAL audit.client_ip = '{client_ip}';
            """)

            return await transaction_fn(conn)
```

---

### 5.4 Rust (`tokio-postgres`): Scoped Session Attribution Sentinel

```rust
use tokio_postgres::{Client, Error, Transaction};
use uuid::Uuid;

pub struct ActorMetadata {
    pub user_id: Uuid,
    pub tenant_id: Uuid,
    pub client_ip: String,
    pub trace_id: String,
}

pub async fn execute_audited_transaction<F, T>(
    client: &mut Client,
    meta: ActorMetadata,
    logic: F,
) -> Result<T, Error>
where
    F: FnOnce(&Transaction<'_>) -> std::pin::Pin<Box<dyn std::future<Output = Result<T, Error>> + Send + '_>>,
{
    let tx = client.transaction().await?;

    // Inject attribution tags strictly scoped to this transaction
    let preamble = format!(
        "SET LOCAL application_name = 'rust:{trace}'; \
         SET LOCAL audit.actor_id = '{user}'; \
         SET LOCAL audit.tenant_id = '{tenant}'; \
         SET LOCAL audit.client_ip = '{ip}';",
        trace = meta.trace_id,
        user = meta.user_id,
        tenant = meta.tenant_id,
        ip = meta.client_ip
    );

    tx.batch_execute(&preamble).await?;

    let result = logic(&tx).await?;

    tx.commit().await?;
    Ok(result)
}
```

---

## 6. Audit Governance Finite State Machine (FSM)

```
        ┌────────────────────────────────────────────────────────┐
        │            STATE 0: UNCONFIGURED / INSECURE            │
        │  (pgaudit missing from preload or blanket 'all' active)│
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   │ Preload pgaudit in shared_preload_libraries
                                   │ Set pgaudit.log = 'ddl, role', log_catalog = off
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │           STATE 1: BASELINE HARDENED SESSION           │
        │      (DDL & role mutations audited; catalogs quiet)    │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   │ CREATE ROLE rds_pgaudit NOLOGIN
                                   │ Set pgaudit.role = 'rds_pgaudit'
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │          STATE 2: OBJECT AUDITING ACTIVE               │
        │ (Granular table grants: ledger, credentials, PII)      │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   │ Assert pgaudit.log_parameter = off
                                   │ Apply regex sanitizers for card numbers/SSNs
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │         STATE 3: PARAMETER SANITIZED & MASKED          │
        │       (Zero plaintext credentials or PANs in logs)     │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   │ Enforce SET LOCAL audit.actor_id in pool
                                   │ Deploy Vector RFC 4180 CSV SIEM shipper
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │       STATE 4: FULL NON-REPUDIATION & ATTRIBUTION       │
        │   (Every audited query maps to authenticated user/IP)  │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   │ Continuous disk capacity monitoring
                                   │ Automated CI linting against blanket logging
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │        STATE 5: CONTINUOUS COMPLIANCE ASSURANCE        │
        │   (SOC 2 Type II, PCI-DSS v4.0, HIPAA verified DoD)    │
        └────────────────────────────────────────────────────────┘
```

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

To guarantee that autonomous agents and human developers do not introduce storage-exhausting or credential-leaking auditing configurations, enforce these 7 automated CI gates:

| Gate | Target Invariant | Machine Check Command | Pass Condition |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **Zero Parameter Leakage** | `psql -c "SHOW pgaudit.log_parameter;"` | Returns `off` |
| **Gate 2** | **Zero Catalog Noise** | `psql -c "SHOW pgaudit.log_catalog;"` | Returns `off` |
| **Gate 3** | **Anti-Blanket DML Session Logging** | `psql -c "SHOW pgaudit.log;"` | Does NOT contain `all`, `read`, or `write` |
| **Gate 4** | **Dedicated Object Role Configured** | `psql -c "SHOW pgaudit.role;"` | Non-empty string (e.g. `rds_pgaudit`) |
| **Gate 5** | **Sensitive Table Coverage** | Inspect `information_schema.role_table_grants` | 100% of PII and financial tables granted to `pgaudit.role` |
| **Gate 6** | **Log Partition Disk Quota** | Storage monitoring sentinel | Free disk space $> 20\%$ at all times |
| **Gate 7** | **RFC 4180 CSV SIEM Parsing** | Vector/Fluentbit pipeline test | Zero unparsed lines on multi-line statements with embedded quotes |

### Autonomous Agent Verification Checklist
- [ ] `shared_preload_libraries` contains `'pgaudit'` in `postgresql.conf`.
- [ ] `pgaudit.log = 'ddl, role'` is configured for session auditing (never blanket `all` or `write`).
- [ ] `pgaudit.role = 'rds_pgaudit'` is active, and sensitive tables are explicitly granted access.
- [ ] `pgaudit.log_catalog = off` is set to suppress internal catalog query noise.
- [ ] `pgaudit.log_parameter = off` is verified to protect credentials, SSNs, and credit cards from log leakage.
- [ ] `pgaudit.log_relation = on` and `pgaudit.log_statement = on` provide necessary SIEM attribution.
- [ ] Application database clients inject transaction-scoped attribution tags (`SET LOCAL audit.actor_id = ...`).
