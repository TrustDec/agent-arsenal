---
description: PostgreSQL Role-Based Access Control (RBAC), privilege separation, ALTER DEFAULT PRIVILEGES, superuser deprecation, CREATEROLE privilege escalation defense, schema usage vs create isolation, SECURITY DEFINER search_path hardening, connection limits, and least-privilege invariants across Go (jackc/pgx/v5), TypeScript (drizzle-orm, prisma, pg), Python (asyncpg, psycopg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{role,privilege,grant,acl,rbac,auth,permission,user,schema,migration}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go,py},**/infra/**/*.{tf,yaml,yml}
alwaysApply: false
---

# Agentic Database Roles, RBAC Privilege Separation, ALTER DEFAULT PRIVILEGES, Superuser Deprecation, CREATEROLE Defense & Least-Privilege Security Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, provision, configure, or migrate PostgreSQL (13–17+) database roles, schema permissions, group role hierarchies, migration runners, and microservice connections across Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `prisma`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Monolithic Superuser Anti-Pattern & RLS Bypass Disaster" (where agents connect application runtimes, background workers, or migrations as the `postgres` superuser, completely bypassing Row-Level Security policies, granting untrusted queries access to the host filesystem via `COPY ... PROGRAM` or `pg_read_file`, and exposing production clusters to catastrophic dropped tables upon prompt injection), the "`ALTER DEFAULT PRIVILEGES` Amnesia & Permission Denied Outage (SQLSTATE 42501)" (where migration runners create new tables, views, or sequences, but PostgreSQL assigns access only to the creating role, causing subsequent application service queries to violently abort with `ERROR: permission denied for relation ...` because forward-facing default privileges were never declared), the "`PUBLIC` Schema Creation Vulnerability & CVE-2018-1058 Hijacking" (where the shared `public` schema grants default `CREATE` privileges to the pseudo-role `PUBLIC`, enabling low-privilege users to shadow standard functions or operators and hijack high-privilege `SECURITY DEFINER` executions), the "`CREATEROLE` Privilege Escalation Trap (PostgreSQL <16 vs 16+)" (where granting `CREATEROLE` allows untrusted roles to alter or grant themselves membership in privileged roles without restriction), the "Unbounded `CONNECTION LIMIT` & Admin Starvation Trap" (where application roles lack connection limits, allowing runaway pools or thundering herds to consume all `max_connections` and lock out DBAs and replication sentinels), and the "Permission Fragmentation & Direct User Grant Chaos" (where grants are applied directly to individual login users rather than declarative, non-login group roles, leading to unmaintainable permission drift and accidental data exposure) by establishing a strict 5-Tier RBAC Governance Ladder, mathematical permission collision and connection starvation models, an autonomous TypeScript `AgenticDatabaseRbacGuardEngine`, cross-runtime telemetry sentinels in Go, TypeScript, Python, and Rust, a 6-state RBAC configuration lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 RBAC Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL employs a unified security model where users and groups are both represented as **roles** (`pg_roles`). A role can log in (`LOGIN`), possess superuser powers (`SUPERUSER`), inherit rights from parent roles (`INHERIT`), create databases (`CREATEDB`), or create other roles (`CREATEROLE`).

However, PostgreSQL's authorization subsystem operates under several non-intuitive foundational principles:
1. **Ownership Monopoly**: The role that executes `CREATE TABLE` or `CREATE VIEW` is the permanent owner of that object. Schema owners or database owners do not automatically inherit rights over objects created by other roles unless explicitly granted.
2. **Default Privilege Isolation**: Grants on a schema (`GRANT ALL ON ALL TABLES IN SCHEMA ...`) apply *strictly to existing objects at the moment of execution*. Any table created 1 millisecond later receives **zero** permissions for other roles unless `ALTER DEFAULT PRIVILEGES` was configured *for the specific role creating the table*.
3. **Superuser RLS Bypass**: Superuser accounts bypass 100% of Row-Level Security (RLS) policies by default (`bypassrls`). Testing or running multi-tenant software as superuser creates a false illusion of tenant isolation while leaving production data exposed.
4. **Namespace Collision & Search Path Exploitation**: Objects declared in unisolated schemas can shadow system functions, allowing malicious or low-privileged actors to execute arbitrary code under the security context of `SECURITY DEFINER` functions (CVE-2018-1058).

When autonomous coding agents generate database administration scripts, provisioning templates, or migration files, LLMs routinely commit 6 catastrophic architectural errors:

### The 6 RBAC Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: APPLICATION CONNECTING AS SUPERUSER
-- Agent writes a database connection string or migration runner:
DATABASE_URL="postgres://postgres:password@db.production:5432/core_db"

-- 💥 Catastrophe:
-- 1. Superuser accounts completely BYPASS Row-Level Security (RLS). All tenant isolation policies are ignored!
-- 2. Any SQL injection or agent prompt injection can execute:
--    COPY (SELECT '') TO PROGRAM 'rm -rf /var/lib/postgresql/data';
--    or read arbitrary server files (/etc/passwd, cloud IAM instance tokens).
-- 3. Superuser connections consume 'superuser_reserved_connections', locking out human SREs during outages.
-- Invariant: NEVER connect applications, CI pipelines, or MCP tools as SUPERUSER.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE ALTER DEFAULT PRIVILEGES AMNESIA
-- Agent creates a migration script to set up a new table:
CREATE TABLE orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL,
  total_cents BIGINT NOT NULL
);
-- Agent previously ran: GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
-- But this table was created TODAY by migration_user!

-- 💥 Catastrophe:
-- PostgreSQL grants on existing tables do NOT apply to future tables!
-- When the web application boots and queries 'orders':
-- ERROR: permission denied for table orders (SQLSTATE 42501)
-- Production deployment crashes immediately.
-- Invariant: Migration roles MUST configure ALTER DEFAULT PRIVILEGES FOR ROLE migration_user IN SCHEMA ...

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: UNHARDENED PUBLIC SCHEMA PERMISSIONS
-- Agent relies on default PostgreSQL schema behavior:
CREATE SCHEMA public; -- In PG < 15, PUBLIC pseudo-role has CREATE privilege!

-- 💥 Catastrophe:
-- Any authenticated user can create tables, functions, or operators in 'public'.
-- An attacker creates a custom operator or function (e.g., 'lower(text)') in public.
-- When a superuser or SECURITY DEFINER function invokes 'lower()', the attacker's code executes with root rights!
-- Invariant: REVOKE CREATE ON SCHEMA public FROM PUBLIC; and create dedicated app schemas.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: UNRESTRICTED CREATEROLE IN POSTGRESQL < 16
-- Agent grants role creation to a developer or microservice admin:
ALTER ROLE dev_admin WITH CREATEROLE;

-- 💥 Catastrophe:
-- In PostgreSQL versions prior to 16, a role with CREATEROLE can ALTER ANY OTHER non-superuser role!
-- dev_admin can alter the password of 'migration_user', grant itself membership in admin groups,
-- or drop critical service roles without authorization.
-- Invariant: In PG 16+, use explicit ADMIN OPTION and role ownership. In PG < 16, forbid CREATEROLE on non-DBAs.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: UNBOUNDED CONNECTION LIMITS
-- Agent creates login roles for microservices:
CREATE ROLE svc_checkout WITH LOGIN PASSWORD 'secret';
CREATE ROLE svc_analytics WITH LOGIN PASSWORD 'secret';

-- 💥 Catastrophe:
-- With CONNECTION LIMIT -1 (unlimited), a traffic spike or connection pool leak in 'svc_analytics'
-- opens 400 connections, exhausting 'max_connections = 500'.
-- Core OLTP service 'svc_checkout' and health checks fail with:
-- FATAL: remaining connection slots are reserved for non-replication superuser connections
-- Invariant: Explicitly bound CONNECTION LIMIT on every login role based on pool math.

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: DIRECT PERMISSION GRANTS TO LOGIN USERS
-- Agent grants privileges directly:
GRANT SELECT, INSERT ON orders TO svc_checkout_pod_1;
GRANT SELECT, INSERT ON orders TO svc_checkout_pod_2;

-- 💥 Catastrophe:
-- Permissions become fragmented across individual credentials. When rotating credentials or auditing
-- access, DBAs cannot verify what permissions exist, causing permissions to drift into security vulnerabilities.
-- Invariant: Grant privileges ONLY to abstract NOLOGIN group roles; grant group membership to login roles.
```

---

## 2. The 5-Tier RBAC Governance Ladder

To guarantee deterministic security, zero runtime permission regressions (`SQLSTATE 42501`), and total protection against privilege escalation, all PostgreSQL persistence architectures must adhere to the 5-Tier RBAC Governance Ladder:

```
┌─────────────────────────────────────────────────────────────────────────┐
│            5-TIER POSTGRESQL RBAC & LEAST-PRIVILEGE LADDER               │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Machine-Verifiable CI Gates & Automated Privilege Auditing      │
│         (pg_roles, pg_default_acl, security definer CI linters)        │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Bounded Connection Limits & Scoped Session Switching (SET ROLE) │
│         (Strict CONNECTION LIMIT, reserved connection protection)       │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Public Schema Hardening & Anti-CVE-2018-1058 Search Path        │
│         (REVOKE CREATE ON SCHEMA public FROM PUBLIC, pinned search_path)│
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Declarative ALTER DEFAULT PRIVILEGES across Migration Schemas    │
│         (Mandatory default ACLs on TABLES, SEQUENCES, ROUTINES)         │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Superuser Deprecation & 4-Tier Non-Login Role Archetypes        │
│         (db_owner, app_readwrite, app_readonly, login service roles)    │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.1 The 4-Tier Role Archetype Architecture

Every database cluster must organize permissions into a declarative 4-tier hierarchy:

1. **`db_owner` (NOLOGIN Group)**: The schema and object owner. Owns the tables, views, sequences, and extensions. Only migration runners inherit or set this role.
2. **`app_readwrite` (NOLOGIN Group)**: Granted `USAGE` on schemas, `SELECT, INSERT, UPDATE, DELETE` on all tables, and `USAGE, SELECT` on sequences. Zero DDL rights (`NO CREATE`, `NO DROP`, `NO ALTER`).
3. **`app_readonly` (NOLOGIN Group)**: Granted `USAGE` on schemas, and `SELECT` strictly on tables and views. Zero write rights (`NO INSERT`, `NO UPDATE`, `NO DELETE`, `NO DDL`).
4. **Concrete Login Roles (`LOGIN`, `NOINHERIT`)**: Concrete service accounts (`svc_app`, `svc_reporting`, `migration_runner`) that possess passwords or IAM auth tokens. They are granted membership in group roles and assume permissions either via inheritance or explicit `SET ROLE`.

```sql
-- ✅ PRODUCTION STANDARD: Declarative 4-Tier Role Archetype Hierarchy

-- Step 1: Create Abstract NOLOGIN Group Roles
CREATE ROLE db_owner WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE app_readwrite WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE app_readonly WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;

-- Step 2: Create Dedicated Application Schema Owned by db_owner
CREATE SCHEMA app AUTHORIZATION db_owner;

-- Step 3: Grant Schema USAGE to Read-Write and Read-Only Groups
GRANT USAGE ON SCHEMA app TO app_readwrite;
GRANT USAGE ON SCHEMA app TO app_readonly;

-- Step 4: Configure Existing Object Grants
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_readwrite;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA app TO app_readwrite;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO app_readonly;

-- Step 5: Configure Forward-Facing ALTER DEFAULT PRIVILEGES for db_owner
ALTER DEFAULT PRIVILEGES FOR ROLE db_owner IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_readwrite;

ALTER DEFAULT PRIVILEGES FOR ROLE db_owner IN SCHEMA app
  GRANT USAGE, SELECT ON SEQUENCES TO app_readwrite;

ALTER DEFAULT PRIVILEGES FOR ROLE db_owner IN SCHEMA app
  GRANT SELECT ON TABLES TO app_readonly;

-- Step 6: Create Concrete Application Service Login Roles
CREATE ROLE svc_core_app WITH LOGIN
  PASSWORD 'STRONG_GENERATED_PASSWORD_OR_IAM'
  CONNECTION LIMIT 100
  NOSUPERUSER NOCREATEDB NOCREATEROLE;

GRANT app_readwrite TO svc_core_app;

CREATE ROLE svc_reporting WITH LOGIN
  PASSWORD 'STRONG_GENERATED_PASSWORD_OR_IAM'
  CONNECTION LIMIT 20
  NOSUPERUSER NOCREATEDB NOCREATEROLE;

GRANT app_readonly TO svc_reporting;

-- Step 7: Create Migration Runner Role (Member of db_owner)
CREATE ROLE migration_runner WITH LOGIN
  PASSWORD 'STRONG_MIGRATION_PASSWORD'
  CONNECTION LIMIT 5
  NOSUPERUSER NOCREATEDB NOCREATEROLE;

GRANT db_owner TO migration_runner;
```

---

## 3. Quantitative Mechanics: Privilege Blast Radius & Connection Starvation Physics

### 3.1 Permission Denied Outage Probability ($P_{\text{denied}}$)

Let $\mathcal{T}_{\text{new}}$ be the set of tables created in a schema migration by role $R_{\text{mig}}$, and $R_{\text{app}}$ be the runtime application role. If `ALTER DEFAULT PRIVILEGES` is not executed for $R_{\text{mig}}$, PostgreSQL initializes table ACLs strictly to:

$$\text{ACL}(T) = \{ R_{\text{mig}} \mapsto \text{ALL} \} \quad \forall T \in \mathcal{T}_{\text{new}}$$

The application role $R_{\text{app}}$ possesses permissions $\text{Perm}(R_{\text{app}}, T) = \emptyset$. The probability of an immediate runtime permission failure upon the first transaction targeting any new table is:

$$P_{\text{denied}}(\mathcal{T}_{\text{new}}) = 1 - \prod_{T \in \mathcal{T}_{\text{new}}} \mathbb{I}(R_{\text{app}} \in \text{ACL}(T)) = 1 - 0 = 1.0 \quad (100\%)$$

A single omitted `ALTER DEFAULT PRIVILEGES` directive guarantees 100% downtime for new features upon rollout.

```
[Migration Runner: CREATE TABLE] ──(No Default ACLs)──> [Owner-Only Access]
                                                                │
                                                                ▼
[App Query: SELECT / INSERT]    ──(Non-Owner Role)────> [SQLSTATE 42501 Outage]
```

### 3.2 Connection Pool Starvation Physics ($T_{\text{starve}}$)

Let $C_{\text{total}} = \text{max\_connections}$, $C_{\text{res}} = \text{superuser\_reserved\_connections}$, and $N_{\text{services}}$ be the number of connecting microservices. If service roles lack bounded `CONNECTION LIMIT` ($L_i = \infty$), and a background or analytics service experiences an unthrottled thread storm with arrival rate $\lambda_{\text{conn}}$ and average connection hold time $1 / \mu$:

The expected time to cluster-wide connection exhaustion $T_{\text{starve}}$ is given by:

$$T_{\text{starve}} = \frac{C_{\text{total}} - C_{\text{res}} - C_{\text{active}}}{\lambda_{\text{conn}} - \mu \cdot C_{\text{active}}}$$

When $C_{\text{active}} \to C_{\text{total}} - C_{\text{res}}$, standard application connections are rejected with `FATAL: remaining connection slots are reserved`.

**Invariant Bound**: The sum of all application login connection limits must be strictly bounded:

$$\sum_{i=1}^{N_{\text{services}}} \text{CONNECTION LIMIT}_i \le C_{\text{total}} - C_{\text{res}} - C_{\text{admin\_buffer}}$$

Where $C_{\text{admin\_buffer}} \ge 10$ to ensure DBAs and monitoring agents retain unconstrained access.

### 3.3 Privilege Blast Radius Metric ($\mathcal{B}_{\text{priv}}$)

We define the Privilege Blast Radius Index $\mathcal{B}_{\text{priv}}(R)$ of any database role $R$:

$$\mathcal{B}_{\text{priv}}(R) = w_{\text{super}} \cdot \mathbb{I}(\text{superuser}) + w_{\text{create\_role}} \cdot \mathbb{I}(\text{createrole}) + w_{\text{write}} \cdot |\text{WritableTables}(R)| + w_{\text{ddl}} \cdot |\text{OwnedSchemas}(R)|$$

- For a **Superuser**: $\mathcal{B}_{\text{priv}} = 10,000$ (infinite blast radius; filesystem access, total cluster compromise).
- For a **Misconfigured App Role** (direct table owner + no connection limit): $\mathcal{B}_{\text{priv}} = 850$.
- For a **Hardened Least-Privilege Role** (`app_readwrite`, no DDL, connection limit 50): $\mathcal{B}_{\text{priv}} = 12$.

---

## 4. Production TypeScript Engine: AgenticDatabaseRbacGuardEngine

The following production-grade TypeScript engine introspects PostgreSQL system catalogs (`pg_roles`, `pg_default_acl`, `pg_namespace`, `pg_class`, `pg_proc`), detects superuser misuse, audits default privilege gaps, identifies missing `search_path` declarations on `SECURITY DEFINER` routines, and generates surgical remediation SQL scripts.

```typescript
/**
 * AgenticDatabaseRbacGuardEngine
 * Industrial PostgreSQL RBAC, Default Privileges, and Least-Privilege Governance Engine.
 */

export interface RoleAuditReport {
  roleName: string;
  isSuperuser: boolean;
  canLogin: boolean;
  canCreateRole: boolean;
  connectionLimit: number;
  inheritedGroups: string[];
  blastRadiusScore: number;
  violations: RbacViolation[];
}

export interface DefaultAclAuditReport {
  schema: string;
  ownerRole: string;
  targetRole: string;
  objectType: 'TABLE' | 'SEQUENCE' | 'FUNCTION' | 'TYPE';
  hasDefaultAcl: boolean;
  missingPermissions: string[];
}

export interface SecurityDefinerAuditReport {
  schema: string;
  functionName: string;
  ownerRole: string;
  hasPinnedSearchPath: boolean;
  searchPathSetting: string | null;
  cveVulnerable: boolean;
}

export interface RbacViolation {
  severity: 'CRITICAL' | 'HIGH' | 'MEDIUM' | 'LOW';
  category: 'SUPERUSER_USAGE' | 'MISSING_DEFAULT_ACL' | 'PUBLIC_SCHEMA_CREATION' | 'UNBOUNDED_CONNECTION_LIMIT' | 'SECURITY_DEFINER_LEAK' | 'CREATEROLE_ESCALATION';
  description: string;
  remediationSql: string;
}

export class AgenticDatabaseRbacGuardEngine {
  /**
   * Evaluates role attributes and computes the Privilege Blast Radius Score.
   */
  public evaluateRoleSecurity(role: {
    name: string;
    isSuperuser: boolean;
    canLogin: boolean;
    canCreateRole: boolean;
    connectionLimit: number;
    ownedSchemasCount: number;
    writableTablesCount: number;
  }): RoleAuditReport {
    const violations: RbacViolation[] = [];
    let blastRadius = 0;

    if (role.isSuperuser) {
      blastRadius += 10000;
      violations.push({
        severity: 'CRITICAL',
        category: 'SUPERUSER_USAGE',
        description: `Role '${role.name}' has SUPERUSER privileges. Superusers bypass all RLS and can access host filesystem.`,
        remediationSql: `ALTER ROLE "${role.name}" NOSUPERUSER;`,
      });
    }

    if (role.canCreateRole && !role.isSuperuser) {
      blastRadius += 500;
      violations.push({
        severity: 'HIGH',
        category: 'CREATEROLE_ESCALATION',
        description: `Role '${role.name}' has CREATEROLE. In PostgreSQL < 16, this permits arbitrary role alteration.`,
        remediationSql: `ALTER ROLE "${role.name}" NOCREATEROLE;`,
      });
    }

    if (role.canLogin && role.connectionLimit === -1) {
      blastRadius += 100;
      violations.push({
        severity: 'MEDIUM',
        category: 'UNBOUNDED_CONNECTION_LIMIT',
        description: `Login role '${role.name}' has unbounded connection limit (-1), risking cluster connection starvation.`,
        remediationSql: `ALTER ROLE "${role.name}" CONNECTION LIMIT 50;`,
      });
    }

    blastRadius += role.writableTablesCount * 2 + role.ownedSchemasCount * 10;

    return {
      roleName: role.name,
      isSuperuser: role.isSuperuser,
      canLogin: role.canLogin,
      canCreateRole: role.canCreateRole,
      connectionLimit: role.connectionLimit,
      inheritedGroups: [],
      blastRadiusScore: blastRadius,
      violations,
    };
  }

  /**
   * Generates SQL audit queries to detect missing ALTER DEFAULT PRIVILEGES.
   */
  public static generateDefaultAclAuditQuery(schemas: string[]): string {
    const schemaList = schemas.map((s) => `'${s}'`).join(', ');
    return `
      SELECT
        n.nspname AS schema_name,
        r_owner.rolname AS owner_role,
        r_target.rolname AS target_role,
        a.defaclobjtype AS object_type,
        a.defaclacl::text AS acl_text
      FROM pg_namespace n
      JOIN pg_roles r_owner ON r_owner.oid = n.nspowner
      LEFT JOIN pg_default_acl a ON a.defaclnsp = n.oid AND a.defaclrole = r_owner.oid
      LEFT JOIN pg_roles r_target ON true
      WHERE n.nspname IN (${schemaList})
      ORDER BY n.nspname, r_owner.rolname;
    `;
  }

  /**
   * Generates SQL audit queries to detect unhardened SECURITY DEFINER functions (Anti-CVE-2018-1058).
   */
  public static generateSecurityDefinerAuditQuery(): string {
    return `
      SELECT
        n.nspname AS schema_name,
        p.proname AS function_name,
        r.rolname AS owner_role,
        p.prosecdef AS is_security_definer,
        COALESCE(array_to_string(p.proconfig, ', '), 'NONE') AS config_settings,
        CASE
          WHEN p.prosecdef = true AND (p.proconfig IS NULL OR NOT (p.proconfig::text LIKE '%search_path=%'))
          THEN true
          ELSE false
        END AS is_vulnerable_to_cve_2018_1058
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      JOIN pg_roles r ON p.proowner = r.oid
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND p.prosecdef = true;
    `;
  }

  /**
   * Synthesizes a hardened Least-Privilege bootstrap migration for an application schema.
   */
  public generateBootstrapRbacScript(params: {
    schemaName: string;
    dbOwnerRole: string;
    appRwRole: string;
    appRoRole: string;
    migrationUser: string;
    appLoginUser: string;
    appConnectionLimit: number;
  }): string {
    return `-- ====================================================================
-- AUTOMATED LEAST-PRIVILEGE RBAC BOOTSTRAP: ${params.schemaName}
-- ====================================================================
BEGIN;

-- 1. Create Non-Login Abstract Groups
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${params.dbOwnerRole}') THEN
    CREATE ROLE "${params.dbOwnerRole}" WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${params.appRwRole}') THEN
    CREATE ROLE "${params.appRwRole}" WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${params.appRoRole}') THEN
    CREATE ROLE "${params.appRoRole}" WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END $$;

-- 2. Create Schema Owned by dbOwner
CREATE SCHEMA IF NOT EXISTS "${params.schemaName}" AUTHORIZATION "${params.dbOwnerRole}";

-- 3. Hardened Public Schema Quarantine (Anti-CVE-2018-1058)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA "${params.schemaName}" FROM PUBLIC;

-- 4. Schema USAGE Grants
GRANT USAGE ON SCHEMA "${params.schemaName}" TO "${params.appRwRole}";
GRANT USAGE ON SCHEMA "${params.schemaName}" TO "${params.appRoRole}";

-- 5. Existing Object Access Grants
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "${params.schemaName}" TO "${params.appRwRole}";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "${params.schemaName}" TO "${params.appRwRole}";
GRANT SELECT ON ALL TABLES IN SCHEMA "${params.schemaName}" TO "${params.appRoRole}";

-- 6. Forward-Facing ALTER DEFAULT PRIVILEGES Pinning
ALTER DEFAULT PRIVILEGES FOR ROLE "${params.dbOwnerRole}" IN SCHEMA "${params.schemaName}"
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${params.appRwRole}";

ALTER DEFAULT PRIVILEGES FOR ROLE "${params.dbOwnerRole}" IN SCHEMA "${params.schemaName}"
  GRANT USAGE, SELECT ON SEQUENCES TO "${params.appRwRole}";

ALTER DEFAULT PRIVILEGES FOR ROLE "${params.dbOwnerRole}" IN SCHEMA "${params.schemaName}"
  GRANT SELECT ON TABLES TO "${params.appRoRole}";

-- 7. Configure Login Roles with Connection Limits
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${params.appLoginUser}') THEN
    CREATE ROLE "${params.appLoginUser}" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
      CONNECTION LIMIT ${params.appConnectionLimit};
  ELSE
    ALTER ROLE "${params.appLoginUser}" CONNECTION LIMIT ${params.appConnectionLimit};
  END IF;
END $$;

GRANT "${params.appRwRole}" TO "${params.appLoginUser}";

COMMIT;
`;
  }
}
```

---

## 5. Cross-Runtime Telemetry Sentinels

### 5.1 Go (`jackc/pgx/v5`): Least-Privilege Verification & Scoped Role Sentinel

```go
package rbac

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type RbacSentinel struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewRbacSentinel(pool *pgxpool.Pool, logger *slog.Logger) *RbacSentinel {
	return &RbacSentinel{pool: pool, logger: logger}
}

// AssertNonSuperuser verifies at connection handshake that the application is NOT connecting as superuser.
// Fails immediately if superuser credentials were inadvertently supplied in configuration.
func (s *RbacSentinel) AssertNonSuperuser(ctx context.Context) error {
	var isSuperuser bool
	var currentRole string

	query := `SELECT usesuper, current_user FROM pg_user WHERE usename = CURRENT_USER;`
	if err := s.pool.QueryRow(ctx, query).Scan(&isSuperuser, &currentRole); err != nil {
		return fmt.Errorf("inspect current role security: %w", err)
	}

	if isSuperuser {
		return fmt.Errorf("CRITICAL SECURITY INVARIANT VIOLATION: connected as SUPERUSER (%s). Application connections must use least-privilege roles", currentRole)
	}

	s.logger.Info("RBAC handshake verified: running under unprivileged role", "role", currentRole)
	return nil
}

// ExecuteAsScopedRole runs the given callback under a temporary role using SET LOCAL ROLE.
// Upon transaction commit or rollback, the role automatically reverts, guaranteeing zero connection pool pollution.
func (s *RbacSentinel) ExecuteAsScopedRole(
	ctx context.Context,
	temporaryRole string,
	fn func(tx pgx.Tx) error,
) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Sanitize role name to prevent SQL injection in identifier
	sanitizedRole := pgx.Identifier{temporaryRole}.Sanitize()
	setRoleSql := fmt.Sprintf("SET LOCAL ROLE %s;", sanitizedRole)

	if _, err := tx.Exec(ctx, setRoleSql); err != nil {
		return fmt.Errorf("set local role to %s: %w", temporaryRole, err)
	}

	if err := fn(tx); err != nil {
		return err
	}

	return tx.Commit(ctx)
}
```

### 5.2 TypeScript (`pg` / `drizzle-orm`): Superuser Guard & Default ACL Validator

```typescript
import { Pool, PoolClient } from 'pg';

export interface PreFlightSecurityConfig {
  expectedUser: string;
  enforceNonSuperuser: boolean;
  requiredSchemas: string[];
}

export class RbacPreFlightGuard {
  constructor(
    private readonly pool: Pool,
    private readonly config: PreFlightSecurityConfig
  ) {}

  /**
   * Asserts startup connection credentials comply with Least-Privilege standards.
   */
  public async verifyRuntimeIsolation(): Promise<void> {
    const client: PoolClient = await this.pool.connect();
    try {
      const { rows } = await client.query<{
        current_user: string;
        session_user: string;
        is_superuser: boolean;
      }>(`
        SELECT
          current_user,
          session_user,
          rolsuper AS is_superuser
        FROM pg_roles
        WHERE rolname = CURRENT_USER;
      `);

      const active = rows[0];
      if (!active) {
        throw new Error('Could not introspect database session role identity');
      }

      if (this.config.enforceNonSuperuser && active.is_superuser) {
        throw new Error(
          `CRITICAL VIOLATION: Application connected as SUPERUSER role '${active.current_user}'. Production runtimes must connect using least-privilege service roles.`
        );
      }

      // Check for public schema creation vulnerability
      const publicPermRes = await client.query<{ has_create: boolean }>(`
        SELECT has_schema_privilege('public', 'public', 'CREATE') AS has_create;
      `);

      if (publicPermRes.rows[0]?.has_create) {
        console.warn(
          '⚠️ WARNING: Schema "public" allows CREATE for pseudo-role PUBLIC. Run REVOKE CREATE ON SCHEMA public FROM PUBLIC;'
        );
      }
    } finally {
      client.release();
    }
  }
}
```

### 5.3 Python (`asyncpg`): Strict Least-Privilege Connection Listener

```python
import asyncpg
import logging

logger = logging.getLogger("db.rbac_sentinel")

async def init_rbac_connection_sentinel(conn: asyncpg.Connection) -> None:
    """
    Hook executed on every new connection opened by the asyncpg Pool.
    Fails closed if the connected role possesses SUPERUSER powers.
    """
    row = await conn.fetchrow(
        "SELECT rolname, rolsuper, rolcreaterole FROM pg_roles WHERE rolname = CURRENT_USER;"
    )
    if not row:
        raise RuntimeError("Failed to resolve current database role identity")

    role_name = row["rolname"]
    is_super = row["rolsuper"]
    can_create_role = row["rolcreaterole"]

    if is_super:
        raise PermissionError(
            f"SECURITY FATAL: Application connected as SUPERUSER ({role_name}). "
            "Deprecate superuser credentials for application services immediately."
        )

    logger.debug(
        "Connection verified under least-privilege role: %s (createrole=%s)",
        role_name,
        can_create_role,
    )
```

### 5.4 Rust (`tokio-postgres`): Connection Handshake Role Assertion

```rust
use tokio_postgres::{Client, Error};

pub struct RbacSecurityValidator<'a> {
    client: &'a Client,
}

impl<'a> RbacSecurityValidator<'a> {
    pub fn new(client: &'a Client) -> Self {
        Self { client }
    }

    /// Verifies the connected role is not a superuser and asserts bounded connection isolation.
    pub async fn assert_least_privilege(&self) -> Result<(), Box<dyn std::error::Error>> {
        let row = self
            .client
            .query_one(
                "SELECT rolname, rolsuper, rolconnlimit FROM pg_roles WHERE rolname = CURRENT_USER;",
                &[],
            )
            .await?;

        let role_name: String = row.get(0);
        let is_superuser: bool = row.get(1);
        let conn_limit: i32 = row.get(2);

        if is_superuser {
            return Err(format!(
                "SECURITY INVARIANT BREACH: Role '{}' has SUPERUSER privilege. Application must use unprivileged role.",
                role_name
            ).into());
        }

        if conn_limit == -1 {
            eprintln!(
                "⚠️ RBAC Warning: Role '{}' has unbounded connection limit (-1). Consider bounding with CONNECTION LIMIT.",
                role_name
            );
        }

        Ok(())
    }
}
```

---

## 6. Six-State RBAC Lifecycle Finite-State Machine (FSM)

```
       ┌──────────────────────┐
       │   1. ROLE_DEFINED    │
       │  (NOLOGIN groups     │
       │   created in DB)     │
       └──────────┬───────────┘
                  │
                  ▼
       ┌──────────────────────┐
       │   2. GROUPS_BOUND    │
       │  (Object ownership   │
       │   assigned to owner) │
       └──────────┬───────────┘
                  │
                  ▼
       ┌──────────────────────┐
       │3. DEFAULT_ACLS_ALIGNED
       │  (ALTER DEFAULT      │
       │   PRIVILEGES pinned) │
       └──────────┬───────────┘
                  │
                  ▼
       ┌──────────────────────┐
       │ 4. SCHEMA_HARDENED   │
       │  (PUBLIC revoked,    │
       │   search_path safe)  │
       └──────────┬───────────┘
                  │
                  ▼
       ┌──────────────────────┐
       │5. CONNECTION_BOUND   │
       │  (CONNECTION LIMIT   │
       │   applied to logins) │
       └──────────┬───────────┘
                  │
                  ▼
       ┌──────────────────────┐
       │ 6. LEAST_PRIV_ACTIVE │
       │  (CI DoD verified,   │
       │   zero superuser app)│
       └──────────────────────┘
```

1. **`ROLE_DEFINED`**: Group roles (`db_owner`, `app_readwrite`, `app_readonly`) created with `NOLOGIN` and `NOSUPERUSER`.
2. **`GROUPS_BOUND`**: Application schemas created and assigned `AUTHORIZATION db_owner`.
3. **`DEFAULT_ACLS_ALIGNED`**: `ALTER DEFAULT PRIVILEGES FOR ROLE db_owner IN SCHEMA ...` executed for tables, sequences, and routines.
4. **`SCHEMA_HARDENED`**: `REVOKE CREATE ON SCHEMA public FROM PUBLIC;` enforced; `SECURITY DEFINER` functions pinned to `search_path = pg_catalog, pg_temp;`.
5. **`CONNECTION_BOUND`**: Concrete login roles assigned strict `CONNECTION LIMIT` values satisfying pool capacity bounds.
6. **`LEAST_PRIV_ACTIVE`**: Machine-verifiable CI gate confirms zero superuser application connections, zero default ACL drift, and operational Least-Privilege.

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

| # | CI Gate Check | Verification Command / Invariant SQL | Pass Criteria |
|---|---|---|---|
| **Gate 1** | **Zero Application Superuser Connections** | `SELECT count(*) FROM pg_stat_activity a JOIN pg_roles r ON a.usename = r.rolname WHERE r.rolsuper = true AND a.application_name NOT IN ('pg_dump', 'patroni', 'backup');` | `count = 0` |
| **Gate 2** | **Mandatory ALTER DEFAULT PRIVILEGES Coverage** | `SELECT count(*) FROM pg_namespace n JOIN pg_roles r ON n.nspowner = r.oid LEFT JOIN pg_default_acl a ON a.defaclnsp = n.oid WHERE n.nspname = 'app' AND a.defaclid IS NULL;` | `count = 0` |
| **Gate 3** | **Public Schema Creation Revocation** | `SELECT has_schema_privilege('public', 'public', 'CREATE') AS has_create;` | `has_create = false` |
| **Gate 4** | **Unhardened SECURITY DEFINER Auditing** | `SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE p.prosecdef = true AND (p.proconfig IS NULL OR NOT (p.proconfig::text LIKE '%search_path=%')) AND n.nspname NOT IN ('pg_catalog', 'information_schema');` | `count = 0` |
| **Gate 5** | **Bounded Connection Limits on Login Roles** | `SELECT count(*) FROM pg_roles WHERE rolcanlogin = true AND rolconnlimit = -1 AND rolname NOT IN ('postgres', 'cloudsqladmin', 'rdsadmin');` | `count = 0` |
| **Gate 6** | **Zero Direct Table Grants to Login Users** | `SELECT count(*) FROM information_schema.table_privileges tp JOIN pg_roles r ON tp.grantee = r.rolname WHERE r.rolcanlogin = true AND r.rolsuper = false AND tp.table_schema = 'app';` | `count = 0` |

---

## Summary Directive for Autonomous Agents

1. **NEVER Connect as SUPERUSER**: Autonomous agents and application microservices must never use superuser connection strings. Always connect with dedicated, unprivileged login roles granted group membership.
2. **Pin `ALTER DEFAULT PRIVILEGES` on All Migration Schemas**: Whenever creating a schema or table ownership structure, always declare `ALTER DEFAULT PRIVILEGES FOR ROLE <owner> IN SCHEMA <schema> GRANT ...` to prevent `SQLSTATE 42501` outages.
3. **Hardened Public Schema**: Always enforce `REVOKE CREATE ON SCHEMA public FROM PUBLIC;` and create domain-specific application schemas.
4. **Pin `search_path` on `SECURITY DEFINER`**: 100% of `SECURITY DEFINER` functions must specify `SET search_path = pg_catalog, pg_temp;` to permanently eliminate CVE-2018-1058 privilege escalation.
5. **Bound Connection Limits**: Explicitly set `CONNECTION LIMIT` on every login role according to connection pool sizing formulas to prevent database connection exhaustion.
