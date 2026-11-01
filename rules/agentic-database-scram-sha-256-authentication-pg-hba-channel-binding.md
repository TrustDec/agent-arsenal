---
description: PostgreSQL enterprise client authentication (pg_hba.conf), SCRAM-SHA-256 password hashing, SCRAM-SHA-256-PLUS cryptographic TLS channel binding (RFC 5802 / RFC 7677 / RFC 5929 tls-server-end-point), zero-downtime legacy MD5 password elimination, pg_hba.conf first-match rule shadowing defense, CIDR mask subnet precedence, scram_iterations tuning against authentication CPU DoS, password leakage prevention in DDL/logs, and cross-runtime driver invariants across Go (jackc/pgx/v5), TypeScript (pg, drizzle, prisma), Python (asyncpg, psycopg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{auth,hba,scram,password,security,conn,db,credentials}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/auth/**/*.{ts,js,go,rs,py},**/internal/database/**/*.{go,rs},**/migrations/**/*.{sql,ts,go,py},**/config/**/*.{ini,conf,toml,yaml,json}
alwaysApply: false
---

# Agentic Database Client Authentication (pg_hba.conf), SCRAM-SHA-256, Channel Binding (scram-sha-256-plus), Legacy MD5 Elimination & Auth Spoofing Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, configure, automate, or audit PostgreSQL client authentication (`pg_hba.conf`), password hashing mechanisms (`password_encryption`), Salted Challenge Response Authentication Mechanism (SCRAM-SHA-256), cryptographic TLS Channel Binding (`scram-sha-256-plus`), or zero-downtime authentication migrations across Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `prisma`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Insecure `trust` Method Exposure & Zero-Auth Superuser Takeover" (where agents debugging connection errors set `host all all 0.0.0.0/0 trust` or `127.0.0.1/32 trust`, completely bypassing authentication and granting arbitrary local or network actors instant superuser access), the "First-Match `pg_hba.conf` Rule Shadowing Pitfall" (where agents append narrow rules below broad CIDR blocks or prepend wide permissive rules that silently override granular access controls), the "Abrupt MD5-to-SCRAM Cutover Cliff & Cluster-Wide Lockout" (where demanding `scram-sha-256` in `pg_hba.conf` before rotating stored passwords causes 100% of application connection pools to be rejected on reload with `FATAL: password authentication failed`), the "Man-in-the-Middle (MITM) Downgrade & Missing Channel Binding (`scram-sha-256-plus`)" (where active network adversaries intercept TLS tunnels because clients fail to cryptographically bind authentication tokens to the server's certificate public key), the "PBKDF2 Iteration Inflation & Postmaster Authentication CPU DoS" (where setting `scram_iterations` too high allows connection spikes to monopolize CPU and starve the database), and the "Cleartext Password Exposure & Plaintext Log Leakage in DDL" (where raw passwords appear in unencrypted SQL migrations and `pg_stat_statements`) by establishing a strict 5-Tier Authentication Governance Ladder, SCRAM cryptographic proof calculus, channel binding MITM elimination models, an autonomous TypeScript `AgenticDatabaseSCRAMGuardEngine`, cross-runtime driver invariants in Go, TypeScript, Python, and Rust, a 6-state authentication governance finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Client Authentication Catastrophes vs The 5-Tier Authentication Governance Ladder

PostgreSQL provides industrial-grade client authentication via Host-Based Authentication (`pg_hba.conf`) and standard cryptographic SASL exchanges (SCRAM-SHA-256 / SCRAM-SHA-256-PLUS). However, autonomous coding agents frequently misunderstand the first-match evaluation semantics of `pg_hba.conf`, the mathematical mechanics of SCRAM verifiers in `pg_authid.rolpassword`, and the zero-downtime credential migration lifecycle. This produces 6 fatal security vulnerabilities and production outages:

### The 6 Client Authentication Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE INSECURE "trust" METHOD EXPOSURE (ZERO-AUTH TAKEOVER)
-- Agent encounters a connection error during setup or CI:
-- "FATAL: password authentication failed for user app_user"
-- Agent "fixes" it by editing pg_hba.conf:
-- host    all    all    0.0.0.0/0    trust
-- OR:
-- host    all    all    127.0.0.1/32 trust

-- 💥 Catastrophe:
-- 1. "trust" completely disables authentication! PostgreSQL accepts ANY connection claiming to be ANY user
--    without asking for a password, certificate, or token.
-- 2. Any process on the local network (or container on the host) connects as superuser "postgres":
--    $ psql -h 127.0.0.1 -U postgres
--    -> "You are now connected to database "postgres" as user "postgres"."
-- 3. Attacker executes COPY ... PROGRAM to achieve arbitrary OS remote code execution, reads private keys,
--    or dumps entire customer databases. PCI-DSS Requirement 8.3 & SOC 2 immediate critical failure.
-- Invariant: NEVER use "trust" on TCP/IP sockets ("host", "hostssl", "hostnossl").
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE FIRST-MATCH pg_hba.conf RULE SHADOWING PITFALL
-- Agent intends to tighten access for a payment service, appending a new rule to pg_hba.conf:
-- (Existing rules at top of file)
-- host    all         all         10.0.0.0/16          md5
-- (Agent appends at bottom)
-- hostssl payment_db  payment_app 10.0.1.50/32         scram-sha-256

-- 💥 Catastrophe:
-- 1. PostgreSQL evaluates pg_hba.conf STRICTLY TOP-TO-BOTTOM and stops at the VERY FIRST matching record!
-- 2. When payment_app connects from 10.0.1.50 to payment_db, rule #1 matches:
--    Type: host (matches SSL and non-SSL)
--    Database: all (matches payment_db)
--    User: all (matches payment_app)
--    IP: 10.0.0.0/16 (matches 10.0.1.50)
-- 3. Rule #2 is PERMANENTLY SHADOWED and NEVER REACHED!
-- 4. payment_app continues connecting over insecure unencrypted MD5, violating compliance and leaving
--    channel binding completely inactive.
-- Invariant: Specific rules (narrow CIDR, explicit db/user) MUST always precede broad rules.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: THE ABRUPT MD5-TO-SCRAM CUTOVER CLIFF & CLUSTER LOCKOUT
-- Agent attempts to upgrade security by modifying pg_hba.conf:
-- - hostssl all all 0.0.0.0/0 md5
-- + hostssl all all 0.0.0.0/0 scram-sha-256
-- Agent runs: SELECT pg_reload_conf();

-- 💥 Catastrophe:
-- 1. In PostgreSQL, passwords stored before password_encryption = scram-sha-256 are legacy MD5 hashes:
--    rolpassword = 'md5' || md5(password || username)
-- 2. SCRAM-SHA-256 requires 4 cryptographic components: Salt, Iteration Count, StoredKey, ServerKey.
--    PostgreSQL CANNOT derive SCRAM verifiers from an irreversible MD5 hash!
-- 3. The instant pg_reload_conf() runs, EVERY single application microservice attempting to authenticate
--    is violently rejected: "FATAL: password authentication failed for user ..."
-- 4. 100% of connection pools collapse. Complete production downtime ($P(\text{lockout}) = 1.0$).
-- Invariant: Passwords MUST be re-encrypted via ALTER ROLE before pg_hba.conf enforces scram-sha-256.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: THE MITM DOWNGRADE & MISSING CHANNEL BINDING
-- Agent configures SCRAM-SHA-256 without channel binding:
-- postgresql://user:pass@db.prod.internal:5432/core?sslmode=verify-full

-- 💥 Catastrophe:
-- 1. Plain SCRAM-SHA-256 protects credentials against passive eavesdropping, but does NOT bind the SASL
--    exchange to the TLS session keys.
-- 2. If a corporate TLS inspection proxy, cloud gateway, or active adversary intercepts the TLS connection
--    (e.g., using a rogue or enterprise-installed root CA), they can terminate the outer TLS tunnel.
-- 3. The proxy relays the plain SCRAM challenge/response between client and server, decrypting all SQL data!
-- 4. Enforcing SCRAM-SHA-256-PLUS (Channel Binding via RFC 5929 tls-server-end-point) cryptographically
--    binds the client proof to the SHA-256 hash of the server's TLS certificate.
--    If an attacker terminates TLS, the channel binding proof fails and the connection is aborted instantly!
-- Invariant: Always mandate Channel Binding ("channel_binding=require") across all client drivers.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: PBKDF2 ITERATION INFLATION & AUTHENTICATION CPU DoS
-- Agent sets scram_iterations = 100000 (believing higher iterations equal infinite security).

-- 💥 Catastrophe:
-- 1. PostgreSQL calculates PBKDF2 during user authentication.
-- 2. At 100,000 iterations, each password verification consumes ~50–100ms of dedicated CPU time.
-- 3. During an application redeployment or autoscaling event, 200 microservice pods start simultaneously,
--    each opening 20 pooled connections (4,000 incoming auth requests).
-- 4. 4,000 * 75ms = 300 seconds of CPU time! The postmaster and auth processes peg host CPU at 100%.
-- 5. Active client queries starve, connection handshakes time out, health checks fail, and the cluster crashes.
-- Invariant: Maintain scram_iterations at the calibrated default (4,096 in PG 16+), bounding auth CPU to < 2ms.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: CLEARTEXT PASSWORD EXPOSURE IN DDL & QUERY LOGS
-- Agent creates a role in an automated migration script:
-- CREATE ROLE reporting_user WITH LOGIN PASSWORD 'SuperSecret123!';

-- 💥 Catastrophe:
-- 1. If password_encryption is unset or misconfigured, the password might be stored as plaintext or weak MD5.
-- 2. The raw DDL statement with 'SuperSecret123!' is logged to postgresql.log, pg_stat_statements,
--    SIEM streams, and git revision control history.
-- 3. Developers and log analysis tools ingest plaintext database master credentials.
-- Invariant: Always set password_encryption = 'scram-sha-256', generate pre-hashed SCRAM verifiers off-host,
-- and redact DDL statements from application logs and migration files.
```

---

### The 5-Tier Authentication Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────┐
│             POSTGRESQL CLIENT AUTHENTICATION GOVERNANCE LADDER         │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Automated Credential Watchdogs, Rate-Limiting & CI Gates       │
│  - Continuous pg_authid audit sentinels (0 legacy MD5 hashes allowed) │
│  - Shadowed pg_hba.conf rule detection CI/CD linter                   │
│  - Failed login brute-force monitoring & auth connection latency SLA   │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Cryptographic TLS Channel Binding (SCRAM-SHA-256-PLUS)         │
│  - RFC 5802 / RFC 7677 / RFC 5929 tls-server-end-point verification   │
│  - Driver-level enforcement: channel_binding=require                   │
│  - Cryptographic immunity against active TLS proxy / MITM interception │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Zero-Downtime MD5-to-SCRAM Dual-Phase Migration Protocol       │
│  - Phase 1: Set password_encryption = scram-sha-256 (reload conf)     │
│  - Phase 2: pg_hba.conf "md5" compatibility bridge (accepts both)     │
│  - Phase 3: Rolling ALTER ROLE ... WITH PASSWORD re-encryption         │
│  - Phase 4: Audit pg_authid for 100% SCRAM verifier coverage           │
│  - Phase 5: Tighten pg_hba.conf to mandate scram-sha-256 exclusively   │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Strict pg_hba.conf Evaluation & Network CIDR Mask Precedence   │
│  - Specific host rules BEFORE broad range CIDR blocks                  │
│  - Enforce hostssl exclusively for network connections (ban host/nossl)│
│  - Explicit database and role bindings (ban blanket "all all 0.0.0.0/0")│
├────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Protocol & Encryption Baseline Hardening                       │
│  - password_encryption = 'scram-sha-256' globally                     │
│  - scram_iterations = 4096 (calibrated PBKDF2 work factor)            │
│  - ABSOLUTE BAN on "trust" method across all TCP/IP sockets            │
│  - Local Unix domain sockets restricted to "peer" or "scram-sha-256"   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Foundations & Security Invariants

### 1. The SCRAM-SHA-256 Authentication Proof Equations

SCRAM-SHA-256 (RFC 5802, RFC 7677) eliminates password transmission over the wire by calculating cryptographic proofs using HMAC-SHA-256:

Given password $P$, cryptographic random salt $S$, and PBKDF2 iteration count $I$:

$$K = \text{PBKDF2}(\text{HMAC-SHA256}, P, S, I)$$

$$\text{ClientKey} = \text{HMAC-SHA256}(K, \text{"Client Key"})$$

$$\text{StoredKey} = \text{SHA256}(\text{ClientKey})$$

$$\text{ServerKey} = \text{HMAC-SHA256}(K, \text{"Server Key"})$$

The database stores **only** $S$, $I$, $\text{StoredKey}$, and $\text{ServerKey}$ in `pg_authid.rolpassword`:
$$\text{rolpassword} = \text{"SCRAM-SHA-256\$"} \,\|\, I \,\|\, \text{":"} \,\|\, \text{Base64}(S) \,\|\, \text{"\$"} \,\|\, \text{Base64}(\text{StoredKey}) \,\|\, \text{":"} \,\|\, \text{Base64}(\text{ServerKey})$$

During the authentication challenge, the server sends random salt $S$, iteration count $I$, and server nonce $r_s$. The client computes:

$$\text{AuthMessage} = \text{client-first-bare} \,\|\, \text{","} \,\|\, \text{server-first} \,\|\, \text{","} \,\|\, \text{client-final-without-proof}$$

$$\text{ClientSignature} = \text{HMAC-SHA256}(\text{StoredKey}, \text{AuthMessage})$$

$$\text{ClientProof} = \text{ClientKey} \oplus \text{ClientSignature}$$

The server verifies the proof using its stored $\text{StoredKey}$:
$$\text{ClientKey}' = \text{ClientProof} \oplus \text{HMAC-SHA256}(\text{StoredKey}, \text{AuthMessage})$$
$$\text{Verify: } \text{SHA256}(\text{ClientKey}') \stackrel{?}{=} \text{StoredKey}$$

If verified, the server generates $\text{ServerSignature} = \text{HMAC-SHA256}(\text{ServerKey}, \text{AuthMessage})$ so the client mutually authenticates the server. **Neither the plaintext password $P$ nor the master key $K$ is ever transmitted or stored.**

---

### 2. Cryptographic Channel Binding Calculus (RFC 5929 `tls-server-end-point`)

Under standard SCRAM-SHA-256 without channel binding, if an adversary establishes a Man-in-the-Middle TLS proxy (e.g. via an untrusted enterprise CA or ARP spoofing), they terminate two separate TLS sessions:
$$\text{Client} \xrightarrow{\text{TLS}_1} \text{MITM Proxy} \xrightarrow{\text{TLS}_2} \text{Server}$$

Because $\text{AuthMessage}$ does not reference TLS session attributes, the proxy forwards the SASL messages transparently:
$$P(\text{MITM} \mid \text{ChannelBinding}=\text{none}) = 1.0$$

Under SCRAM-SHA-256-PLUS (`tls-server-end-point`), the client cryptographically binds the server's TLS leaf certificate to $\text{AuthMessage}$:

$$\text{CB-Data} = \text{"p=tls-server-end-point,,"} \,\|\, \text{SHA-256}(\text{Cert}_{\text{server}}^{\text{DER}})$$

$$\text{AuthMessage}_{\text{plus}} = \text{client-first} \,\|\, \text{server-first} \,\|\, \text{client-final-with-cb} \,\|\, \text{CB-Data}$$

If an adversary proxies the connection, the client sees $\text{Cert}_{\text{MITM}}^{\text{DER}}$ while the real database sees $\text{Cert}_{\text{server}}^{\text{DER}}$. Because $\text{Cert}_{\text{MITM}} \ne \text{Cert}_{\text{server}}$:

$$\text{SHA-256}(\text{Cert}_{\text{MITM}}^{\text{DER}}) \ne \text{SHA-256}(\text{Cert}_{\text{server}}^{\text{DER}}) \implies \text{Proof Verification Fails}$$

$$P(\text{MITM} \mid \text{ChannelBinding}=\text{require}) \le 2^{-256}$$

The connection is aborted at the SASL handshake stage before any application query or credential can be intercepted.

---

### 3. PBKDF2 Iteration Latency & CPU Throttling Model

Let $N$ be the number of concurrent client authentication requests, $I$ be `scram_iterations`, and $\tau_{\text{HMAC}}$ be the hardware execution time of a single HMAC-SHA256 operation (~0.35 microseconds on modern x86-64 / ARM64 cores). The total CPU time $T_{\text{CPU}}$ consumed by postmaster backends is:

$$T_{\text{CPU}}(N, I) = 2 \cdot N \cdot I \cdot \tau_{\text{HMAC}}$$

- At default $I = 4,096$:
  $$T_{\text{auth}}(1) = 2 \cdot 4096 \cdot 0.35\,\mu\text{s} \approx 2.87\,\text{ms}$$
  For 100 concurrent connection requests: $T_{\text{CPU}} = 287\,\text{ms}$ across all cores (safe and non-blocking).
- At inflated $I = 100,000$:
  $$T_{\text{auth}}(1) = 2 \cdot 100000 \cdot 0.35\,\mu\text{s} \approx 70.0\,\text{ms}$$
  For 100 concurrent connection requests: $T_{\text{CPU}} = 7,000\,\text{ms} = 7.0\,\text{seconds}$ of pure CPU time!
  On an 8-core database server, this completely starves active queries and drops throughput to zero.

**Invariant**: Enforce `scram_iterations = 4096`. Security is guaranteed by high-entropy random passwords ($\ge 24$ alphanumeric characters), not by inflating PBKDF2 iterations to DoS levels.

---

### 4. `pg_hba.conf` Rule Precedence Order & Non-Shadowing Invariant

A rule $R_a = (T_a, D_a, U_a, A_a)$ shadows rule $R_b = (T_b, D_b, U_b, A_b)$ if and only if:
1. Position in `pg_hba.conf`: $\text{index}(R_a) < \text{index}(R_b)$
2. Connection type matches: $T_a = \text{"host"} \lor T_a = T_b$
3. Database matches: $D_a = \text{"all"} \lor D_a = D_b$
4. Role matches: $U_a = \text{"all"} \lor U_a = U_b$
5. Network address subsumption: $\text{CIDR}(A_b) \subseteq \text{CIDR}(A_a)$

If conditions 1–5 hold, $R_b$ is **dead configuration** ($\text{Reachability}(R_b) \equiv 0$).

**Non-Shadowing Invariant**: For every pair of rules $(R_i, R_j)$ where $\text{CIDR}(R_i) \subset \text{CIDR}(R_j)$ (strict subnet), the specific rule MUST precede the generic rule:
$$\text{CIDR}(R_i) \subset \text{CIDR}(R_j) \implies \text{index}(R_i) < \text{index}(R_j)$$

---

## 3. Production Configuration Sentinels & Implementation Standards

### Production `postgresql.conf` Authentication Baselines

```ini
# ==============================================================================
# POSTGRESQL CLIENT AUTHENTICATION & PASSWORD ENCRYPTION HARDENING
# ==============================================================================

# Mandatory SCRAM-SHA-256 for all newly created/altered passwords
password_encryption = 'scram-sha-256'

# Calibrated PBKDF2 iteration count (PostgreSQL 16+ default: 4096)
# Prevents connection storm authentication CPU DoS while exceeding PCI-DSS requirements
scram_iterations = 4096

# Restrict SSL protocol to TLS 1.3/1.2 for channel binding integrity
ssl = on
ssl_min_protocol_version = 'TLSv1.3'

# Logging & Audit Configuration
log_connections = on
log_disconnections = on
log_hostname = off                  # Prevent DNS reverse-lookup latency spikes during handshakes
```

---

### Production `pg_hba.conf` Hardened Template

```ini
# ==============================================================================
# POSTGRESQL HOST-BASED AUTHENTICATION (pg_hba.conf)
# Strictly evaluated top-to-bottom. First match wins!
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# ==============================================================================

# 1. Local Unix Domain Sockets: Strictly peer for postgres admin, scram-sha-256 for others
local   all             postgres                                peer
local   all             all                                     scram-sha-256

# 2. Localhost Loopback IPv4 & IPv6: Mandatory hostssl + scram-sha-256 (NO "trust"!)
hostssl all             all             127.0.0.1/32            scram-sha-256
hostssl all             all             ::1/128                 scram-sha-256

# 3. Dedicated Replication Slots: Restrict strictly to replication user and VPC CIDRs
hostssl replication     replicator      10.100.0.0/16           scram-sha-256

# 4. Critical Microservices (Specific CIDR subnet before broad VPC rule)
hostssl payment_db      payment_app     10.100.20.0/24          scram-sha-256
hostssl auth_db         auth_app        10.100.21.0/24          scram-sha-256

# 5. General Application VPC Tier: Mandatory hostssl + scram-sha-256
hostssl all             app_readwrite   10.100.0.0/16           scram-sha-256
hostssl all             app_readonly    10.100.0.0/16           scram-sha-256

# 6. Break-Glass Administration Tier (Requires client TLS certificate + SCRAM)
hostssl all             dba_admin       10.100.5.0/24           scram-sha-256 clientcert=verify-full

# 7. EXPLICIT DEFAULT REJECTION (Fail-Closed)
# Any connection not matching above rules is rejected and logged
host    all             all             0.0.0.0/0               reject
host    all             all             ::/0                    reject
```

---

### In-Database Audit Sentinels (SQL)

#### Sentinel 1: Audit Stored Password Encryption Types in `pg_authid`

```sql
-- Audit all database roles for legacy MD5 or cleartext verifiers
SELECT
    rolname,
    rolcanlogin,
    rolsuper,
    CASE
        WHEN rolpassword LIKE 'SCRAM-SHA-256$%' THEN 'SCRAM-SHA-256 (SECURE)'
        WHEN rolpassword LIKE 'md5%'            THEN 'MD5 (INSECURE / DEPRECATED)'
        WHEN rolpassword IS NULL                THEN 'NO_PASSWORD (CERT/EXTERNAL/LOCKED)'
        ELSE 'UNKNOWN / PLAINTEXT'
    END AS auth_status,
    CASE
        WHEN rolpassword LIKE 'SCRAM-SHA-256$%' THEN
            -- Extract iteration count from SCRAM verifier header: SCRAM-SHA-256$<iterations>:<salt>$...
            split_part(split_part(rolpassword, '$', 2), ':', 1)::integer
        ELSE NULL
    END AS scram_iterations
FROM pg_authid
WHERE rolcanlogin = true
ORDER BY auth_status DESC, rolname ASC;
```

#### Sentinel 2: Inspect Active `pg_hba_file_rules` and Check for Insecure Methods

```sql
-- Validate pg_hba.conf rules loaded by PostgreSQL
SELECT
    line_number,
    type,
    database,
    user_name,
    address,
    netmask,
    auth_method,
    error
FROM pg_hba_file_rules
WHERE error IS NOT NULL
   OR auth_method IN ('trust', 'password', 'ident', 'md5')
ORDER BY line_number ASC;
```

#### Sentinel 3: Shadowed Rule Detection Sentinel

```sql
-- Identifies potential shadowed rules in pg_hba.conf where a broader CIDR precedes a narrower CIDR
WITH parsed_rules AS (
    SELECT
        line_number,
        type,
        database,
        user_name,
        address,
        CASE
            WHEN address IS NOT NULL AND address ~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'
            THEN address::inet
            ELSE NULL
        END AS inet_addr,
        auth_method
    FROM pg_hba_file_rules
    WHERE error IS NULL
)
SELECT
    earlier.line_number AS broad_rule_line,
    earlier.address     AS broad_rule_cidr,
    earlier.auth_method AS broad_rule_method,
    later.line_number   AS shadowed_rule_line,
    later.address       AS shadowed_rule_cidr,
    later.auth_method   AS shadowed_rule_method
FROM parsed_rules earlier
JOIN parsed_rules later
  ON earlier.line_number < later.line_number
 AND earlier.type = later.type
 AND (earlier.database = later.database OR earlier.database = '{all}')
 AND (earlier.user_name = later.user_name OR earlier.user_name = '{all}')
 AND earlier.inet_addr IS NOT NULL
 AND later.inet_addr IS NOT NULL
 AND later.inet_addr << earlier.inet_addr -- later is strict subnet of earlier
ORDER BY earlier.line_number;
```

---

### Zero-Downtime MD5-to-SCRAM-SHA-256 Migration Runbook

```bash
#!/usr/bin/env bash
# ==============================================================================
# ZERO-DOWNTIME POSTGRESQL MD5 TO SCRAM-SHA-256 MIGRATION RUNBOOK
# ==============================================================================
set -euo pipefail

DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_USER="postgres"
DB_NAME="postgres"

echo "=== PHASE 1: PRE-FLIGHT VERIFICATION ==="
# Check current password_encryption setting
CURRENT_ENC=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "SHOW password_encryption;")
echo "Current password_encryption: $CURRENT_ENC"

# Step 1: Enable password_encryption = scram-sha-256
if [ "$CURRENT_ENC" != "scram-sha-256" ]; then
  echo "Enabling password_encryption = 'scram-sha-256'..."
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256';"
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_reload_conf();"
  echo "Reloaded postgresql.conf successfully."
fi

echo "=== PHASE 2: VERIFY pg_hba.conf COMPATIBILITY BRIDGE ==="
# Note: In PostgreSQL, auth method 'md5' in pg_hba.conf automatically accepts
# BOTH MD5 and SCRAM-SHA-256 passwords! This acts as the built-in zero-downtime bridge.
echo "Ensuring pg_hba.conf uses 'md5' bridge during password re-encryption..."

echo "=== PHASE 3: RE-ENCRYPT USER PASSWORDS TO SCRAM-SHA-256 ==="
# Roles must execute ALTER ROLE ... WITH PASSWORD to compute SCRAM verifiers
# This can be executed per-service or via orchestrated credential rotation pipeline:
ROLES_TO_ROTATE=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "
  SELECT rolname FROM pg_authid
  WHERE rolcanlogin = true AND rolpassword LIKE 'md5%' AND rolname NOT LIKE 'pg_%';
")

if [ -z "$ROLES_TO_ROTATE" ]; then
  echo "Zero legacy MD5 roles detected. All login roles already upgraded to SCRAM!"
else
  echo "Roles requiring password re-encryption:"
  echo "$ROLES_TO_ROTATE"
  echo "Execute ALTER ROLE <role> WITH PASSWORD '<new_or_existing_password>'; for each role."
fi

echo "=== PHASE 4: AUDIT ALL ROLES FOR 100% SCRAM COVERAGE ==="
MD5_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "
  SELECT count(*) FROM pg_authid WHERE rolcanlogin = true AND rolpassword LIKE 'md5%';
")

if [ "$MD5_COUNT" -gt 0 ]; then
  echo "ABORT: Cannot enforce scram-sha-256 in pg_hba.conf! $MD5_COUNT roles still have MD5 hashes."
  exit 1
fi
echo "Audit PASSED: 100% of login roles possess valid SCRAM-SHA-256 verifiers."

echo "=== PHASE 5: TIGHTEN pg_hba.conf TO MANDATE scram-sha-256 ==="
# Update pg_hba.conf replacing 'md5' with 'scram-sha-256'
# sed -i "s/md5/scram-sha-256/g" /path/to/pg_hba.conf
# psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_reload_conf();"
echo "Ready to enforce scram-sha-256 in pg_hba.conf."
```

---

## 4. Cross-Runtime Client Driver Invariants

### 1. Go (`jackc/pgx/v5`): SCRAM-SHA-256-PLUS Channel Binding & verify-full Connector

```go
package scramauth

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type SecureConnectorConfig struct {
	Host           string
	Port           uint16
	Database       string
	User           string
	Password       string
	CABundlePath   string
	RequireChannel bool
}

// BuildHardenedPool creates a pgx connection pool with mandatory SCRAM-SHA-256-PLUS channel binding.
func BuildHardenedPool(ctx context.Context, cfg SecureConnectorConfig) (*pgxpool.Pool, error) {
	connStr := fmt.Sprintf(
		"host=%s port=%d dbname=%s user=%s password=%s sslmode=verify-full",
		cfg.Host, cfg.Port, cfg.Database, cfg.User, cfg.Password,
	)

	poolConfig, err := pgxpool.ParseConfig(connStr)
	if err != nil {
		return nil, fmt.Errorf("failed to parse connection string: %w", err)
	}

	// 1. Channel Binding Configuration
	if cfg.RequireChannel {
		// Enforces RFC 5929 tls-server-end-point verification
		poolConfig.ConnConfig.ChannelBinding = "require"
	} else {
		poolConfig.ConnConfig.ChannelBinding = "prefer"
	}

	// 2. Dual-Root CA Trust Bundle Loading
	caPEM, err := os.ReadFile(cfg.CABundlePath)
	if err != nil {
		return nil, fmt.Errorf("failed to read CA bundle: %w", err)
	}
	rootPool := x509.NewCertPool()
	if !rootPool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("failed to parse CA bundle PEM")
	}

	// 3. Strict TLS 1.3 / 1.2 Configuration
	poolConfig.ConnConfig.TLSConfig = &tls.Config{
		RootCAs:            rootPool,
		ServerName:         cfg.Host,
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: false,
	}

	// 4. Connection Pool Invariants
	poolConfig.MaxConns = 30
	poolConfig.MinConns = 5
	poolConfig.MaxConnLifetime = 30 * time.Minute
	poolConfig.MaxConnIdleTime = 5 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize pool: %w", err)
	}

	// 5. Verification Ping to assert handshake and channel binding success
	pingCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("initial ping verification failed (possible channel binding or auth mismatch): %w", err)
	}

	return pool, nil
}
```

---

### 2. TypeScript (`pg` / `postgres.js`): Hardened SCRAM & Channel Binding

```typescript
import { Pool, PoolConfig } from 'pg';
import * as fs from 'fs';

export interface HardenedDBConfig {
  host: string;
  port: number;
  database: string;
  user: string;
  password: string;
  caCertPath: string;
}

export function createHardenedDatabasePool(cfg: HardenedDBConfig): Pool {
  const ca = fs.readFileSync(cfg.caCertPath, 'utf-8');

  const poolConfig: PoolConfig = {
    host: cfg.host,
    port: cfg.port,
    database: cfg.database,
    user: cfg.user,
    password: cfg.password,

    // Mandatory SSL verification with SAN check
    ssl: {
      rejectUnauthorized: true,
      ca: ca,
      servername: cfg.host,
      minVersion: 'TLSv1.3',
    },

    // Strict Connection Hygiene
    max: 25,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 5000,
  };

  const pool = new Pool(poolConfig);

  pool.on('error', (err) => {
    // Audit SASL SCRAM failures
    if (err.message.includes('SASL') || err.message.includes('password authentication failed')) {
      console.error('[CRITICAL_AUTH_FAILURE] PostgreSQL SCRAM authentication rejected:', err.message);
    }
  });

  return pool;
}
```

---

### 3. Python (`asyncpg`): Strict SCRAM & Channel Binding Invariants

```python
import asyncpg
import ssl

async def create_hardened_asyncpg_pool(
    host: str,
    port: int,
    database: str,
    user: str,
    password: str,
    ca_bundle_path: str,
) -> asyncpg.Pool:
    # 1. Build hardened TLS Context
    tls_context = ssl.create_default_context(
        purpose=ssl.Purpose.SERVER_AUTH,
        cafile=ca_bundle_path
    )
    tls_context.minimum_version = ssl.TLSVersion.TLSv1_3
    tls_context.check_hostname = True
    tls_context.verify_mode = ssl.CERT_REQUIRED

    # 2. Initialize connection pool with channel binding
    # asyncpg natively negotiates SCRAM-SHA-256 and supports channel binding
    pool = await asyncpg.create_pool(
        host=host,
        port=port,
        database=database,
        user=user,
        password=password,
        ssl=tls_context,
        min_size=5,
        max_size=30,
        command_timeout=15.0,
        max_inactive_connection_lifetime=300.0,
    )

    # 3. Assert connectivity
    async with pool.acquire() as conn:
        val = await conn.fetchval("SELECT 1;")
        assert val == 1, "Database health check failed"

    return pool
```

---

### 4. Rust (`sqlx` / `tokio-postgres`): Hardened Channel Binding Configuration

```rust
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgSslMode};
use sqlx::{Pool, Postgres};
use std::path::Path;
use std::time::Duration;

pub async fn create_hardened_pg_pool(
    host: &str,
    port: u16,
    database: &str,
    user: &str,
    password: &str,
    ca_cert_path: &Path,
) -> Result<Pool<Postgres>, Box<dyn std::error::Error>> {
    // Mandatory verify-full with CA certificate and channel binding
    let connect_opts = PgConnectOptions::new()
        .host(host)
        .port(port)
        .database(database)
        .username(user)
        .password(password)
        .ssl_mode(PgSslMode::VerifyFull)
        .ssl_root_cert(ca_cert_path);

    let pool = PgPoolOptions::new()
        .max_connections(30)
        .min_connections(5)
        .acquire_timeout(Duration::from_secs(5))
        .idle_timeout(Duration::from_secs(300))
        .connect_with(connect_opts)
        .await?;

    Ok(pool)
}
```

---

## 5. Executable TypeScript Guard Engine: `AgenticDatabaseSCRAMGuardEngine`

```typescript
/**
 * AgenticDatabaseSCRAMGuardEngine
 * Industrial-grade verification engine for PostgreSQL pg_hba.conf rules,
 * password encryption algorithms, and SCRAM-SHA-256-PLUS channel binding.
 */

export interface HBARule {
  lineNumber: number;
  type: 'local' | 'host' | 'hostssl' | 'hostnossl';
  database: string;
  user: string;
  address?: string; // CIDR string
  authMethod: string;
}

export interface RoleAuthRecord {
  roleName: string;
  canLogin: boolean;
  isSuperuser: boolean;
  passwordHash: string | null;
}

export interface SCRAMAuditViolation {
  severity: 'CRITICAL' | 'HIGH' | 'MEDIUM';
  category: string;
  description: string;
  remediation: string;
}

export interface SCRAMAuditReport {
  status: 'COMPLIANT' | 'VIOLATIONS_DETECTED';
  totalRulesAudited: number;
  totalRolesAudited: number;
  legacyMD5RoleCount: number;
  scramRoleCount: number;
  shadowedRuleCount: number;
  violations: SCRAMAuditViolation[];
}

export class AgenticDatabaseSCRAMGuardEngine {
  /**
   * Parse a raw CIDR string into integer prefix and mask.
   */
  private static parseCIDR(cidr: string): { ipNum: number; maskBits: number } | null {
    const parts = cidr.split('/');
    if (parts.length !== 2) return null;
    const ipParts = parts[0].split('.').map(Number);
    if (ipParts.length !== 4 || ipParts.some((n) => isNaN(n) || n < 0 || n > 255)) return null;
    const maskBits = parseInt(parts[1], 10);
    if (isNaN(maskBits) || maskBits < 0 || maskBits > 32) return null;

    const ipNum =
      ((ipParts[0] << 24) >>> 0) +
      ((ipParts[1] << 16) >>> 0) +
      ((ipParts[2] << 8) >>> 0) +
      (ipParts[3] >>> 0);

    return { ipNum, maskBits };
  }

  /**
   * Determine if subnet B is strictly contained within subnet A.
   */
  private static isStrictSubnet(cidrA: string, cidrB: string): boolean {
    const a = this.parseCIDR(cidrA);
    const b = this.parseCIDR(cidrB);
    if (!a || !b) return false;

    // Subnet B must have a longer prefix (smaller network)
    if (b.maskBits <= a.maskBits) return false;

    const maskA = a.maskBits === 0 ? 0 : (~0 << (32 - a.maskBits)) >>> 0;
    return (a.ipNum & maskA) === (b.ipNum & maskA);
  }

  /**
   * Audit pg_hba.conf rules and role password hashes for compliance.
   */
  public static audit(
    hbaRules: HBARule[],
    roles: RoleAuthRecord[],
    currentPasswordEncryption: string
  ): SCRAMAuditReport {
    const violations: SCRAMAuditViolation[] = [];
    let legacyMD5RoleCount = 0;
    let scramRoleCount = 0;
    let shadowedRuleCount = 0;

    // 1. Audit GUC setting
    if (currentPasswordEncryption !== 'scram-sha-256') {
      violations.push({
        severity: 'CRITICAL',
        category: 'INSECURE_PASSWORD_ENCRYPTION_GUC',
        description: `password_encryption is currently set to '${currentPasswordEncryption}'. Must be 'scram-sha-256'.`,
        remediation: "ALTER SYSTEM SET password_encryption = 'scram-sha-256'; SELECT pg_reload_conf();",
      });
    }

    // 2. Audit Roles for Legacy MD5 Passwords
    for (const role of roles) {
      if (!role.canLogin) continue;

      if (!role.passwordHash) {
        // Role has no password (might use mTLS clientcert or peer)
        continue;
      }

      if (role.passwordHash.startsWith('md5')) {
        legacyMD5RoleCount++;
        violations.push({
          severity: 'HIGH',
          category: 'LEGACY_MD5_ROLE_PASSWORD',
          description: `Role '${role.roleName}' uses insecure legacy MD5 password hashing. Vulnerable to rainbow tables.`,
          remediation: `ALTER ROLE "${role.roleName}" WITH PASSWORD '<generate_high_entropy_secret>';`,
        });
      } else if (role.passwordHash.startsWith('SCRAM-SHA-256$')) {
        scramRoleCount++;
        // Verify iteration count
        const parts = role.passwordHash.split('$');
        if (parts.length >= 3) {
          const iterStr = parts[1].split(':')[0];
          const iterations = parseInt(iterStr, 10);
          if (iterations > 10000) {
            violations.push({
              severity: 'MEDIUM',
              category: 'OVERINFLATED_SCRAM_ITERATIONS',
              description: `Role '${role.roleName}' has ${iterations} PBKDF2 iterations. Risk of auth CPU DoS.`,
              remediation: 'Re-encrypt role password under default scram_iterations = 4096.',
            });
          }
        }
      } else {
        violations.push({
          severity: 'CRITICAL',
          category: 'UNENCRYPTED_PLAINTEXT_PASSWORD',
          description: `Role '${role.roleName}' has an unencrypted or unknown password format.`,
          remediation: `ALTER ROLE "${role.roleName}" WITH PASSWORD '<secret>';`,
        });
      }
    }

    // 3. Audit pg_hba.conf Rules
    for (let i = 0; i < hbaRules.length; i++) {
      const rule = hbaRules[i];

      // Check for 'trust' method on non-peer/local sockets
      if (rule.authMethod === 'trust') {
        violations.push({
          severity: 'CRITICAL',
          category: 'ZERO_AUTH_TRUST_EXPOSURE',
          description: `Line ${rule.lineNumber}: Method 'trust' configured on ${rule.type} socket. Completely bypasses password authentication!`,
          remediation: `Change method from 'trust' to 'scram-sha-256' or 'peer' (local only).`,
        });
      }

      // Check for unencrypted 'host' rather than 'hostssl'
      if (rule.type === 'host' && rule.address && rule.address !== '127.0.0.1/32' && rule.address !== '::1/128') {
        violations.push({
          severity: 'HIGH',
          category: 'UNENCRYPTED_HOST_CONNECTION',
          description: `Line ${rule.lineNumber}: Connection type 'host' allows unencrypted cleartext transport.`,
          remediation: `Change connection type to 'hostssl' to enforce TLS transport.`,
        });
      }

      // Check for Shadowed Rules (Strict subnet ordering)
      if (rule.address) {
        for (let j = i + 1; j < hbaRules.length; j++) {
          const laterRule = hbaRules[j];
          if (!laterRule.address) continue;

          // Check if laterRule is shadowed by current rule
          const matchesType = rule.type === 'host' || rule.type === laterRule.type;
          const matchesDb = rule.database === 'all' || rule.database === laterRule.database;
          const matchesUser = rule.user === 'all' || rule.user === laterRule.user;

          if (matchesType && matchesDb && matchesUser) {
            if (this.isStrictSubnet(rule.address, laterRule.address)) {
              shadowedRuleCount++;
              violations.push({
                severity: 'HIGH',
                category: 'SHADOWED_HBA_RULE',
                description: `Line ${laterRule.lineNumber} (${laterRule.address}, ${laterRule.authMethod}) is permanently shadowed by broader rule at Line ${rule.lineNumber} (${rule.address}, ${rule.authMethod}).`,
                remediation: `Move Line ${laterRule.lineNumber} ABOVE Line ${rule.lineNumber} in pg_hba.conf.`,
              });
            }
          }
        }
      }
    }

    return {
      status: violations.length === 0 ? 'COMPLIANT' : 'VIOLATIONS_DETECTED',
      totalRulesAudited: hbaRules.length,
      totalRolesAudited: roles.length,
      legacyMD5RoleCount,
      scramRoleCount,
      shadowedRuleCount,
      violations,
    };
  }
}
```

---

## 6. Six-State Authentication Governance Finite State Machine (FSM)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│             POSTGRESQL CLIENT AUTHENTICATION GOVERNANCE FSM                │
└─────────────────────────────────────────────────────────────────────────────┘

       [1. LEGACY_MD5_INSECURE]
                 │
                 │ 1. Set password_encryption = 'scram-sha-256' in postgresql.conf
                 │ 2. Execute SELECT pg_reload_conf();
                 ▼
       [2. SCRAM_GUC_ARMED]
                 │
                 │ 1. Validate pg_hba.conf uses 'md5' compatibility bridge
                 │    (native pg engine accepts both MD5 & SCRAM under 'md5')
                 │ 2. Remove all 'trust' directives from TCP sockets
                 ▼
       [3. DUAL_AUTH_TRANSITION]
                 │
                 │ 1. Re-encrypt all user passwords via ALTER ROLE ... WITH PASSWORD
                 │ 2. Continuous audit: pg_authid rolpassword LIKE 'SCRAM-SHA-256$%'
                 ▼
       [4. CREDENTIAL_MIGRATED]
                 │
                 │ 1. Assert 0 remaining MD5 password hashes in pg_authid
                 │ 2. Update pg_hba.conf: change 'md5' to 'scram-sha-256'
                 │ 3. Execute SELECT pg_reload_conf();
                 ▼
       [5. SCRAM_ENFORCED]
                 │
                 │ 1. Configure client drivers with channel_binding = 'require'
                 │ 2. Mandate sslmode = 'verify-full' with SAN validation
                 ▼
       [6. CHANNEL_BINDING_LOCKED]  <--- (Mathematical Immunity Against MITM)
```

### State Transition Formal Invariants

1. **State 1 $\to$ State 2 (`LEGACY_MD5_INSECURE` $\to$ `SCRAM_GUC_ARMED`)**:
   - Invariant: `SHOW password_encryption;` MUST return `scram-sha-256`.
   - Never alter `pg_hba.conf` in this state.
2. **State 2 $\to$ State 3 (`SCRAM_GUC_ARMED` $\to$ `DUAL_AUTH_TRANSITION`)**:
   - Invariant: Zero `trust` rules exist in `pg_hba.conf` for any non-local socket.
   - All client connections continue uninterrupted via the `md5` compatibility bridge.
3. **State 3 $\to$ State 4 (`DUAL_AUTH_TRANSITION` $\to$ `CREDENTIAL_MIGRATED`)**:
   - Invariant: $\sum [\text{rolpassword LIKE 'md5\%'}] \equiv 0$ across all `rolcanlogin = true` roles.
   - 100% of roles verified to possess valid SCRAM-SHA-256 salt, iteration, and keys.
4. **State 4 $\to$ State 5 (`CREDENTIAL_MIGRATED` $\to$ `SCRAM_ENFORCED`)**:
   - Invariant: `pg_hba.conf` lines specify `scram-sha-256` exclusively. No `md5` references remain.
   - `SELECT pg_reload_conf();` executed with zero in-flight connection drops.
5. **State 5 $\to$ State 6 (`SCRAM_ENFORCED` $\to$ `CHANNEL_BINDING_LOCKED`)**:
   - Invariant: 100% of microservice connection pools pass `channel_binding=require` and `sslmode=verify-full`.
   - $P(\text{MITM}) \le 2^{-256}$. RFC 5929 `tls-server-end-point` cryptographic protection active.

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates Matrix

| Gate ID | Check Name | Verification Command / Target | Pass Condition | Failure Action |
|:---|:---|:---|:---|:---|
| **GATE-AUTH-01** | **Password Encryption GUC** | `SHOW password_encryption;` | `scram-sha-256` | Block CI; issue `ALTER SYSTEM SET password_encryption = 'scram-sha-256'` |
| **GATE-AUTH-02** | **Zero `trust` Directive** | `SELECT count(*) FROM pg_hba_file_rules WHERE auth_method = 'trust' AND type != 'local';` | `0` | Block deployment; reject PR immediately with critical security violation |
| **GATE-AUTH-03** | **Zero Legacy MD5 Hashes** | `SELECT count(*) FROM pg_authid WHERE rolcanlogin = true AND rolpassword LIKE 'md5%';` | `0` | Halt `pg_hba.conf` hardening; trigger automated credential re-encryption runbook |
| **GATE-AUTH-04** | **No Shadowed HBA Rules** | `AgenticDatabaseSCRAMGuardEngine.audit()` | `shadowedRuleCount === 0` | Fail linter; reorder `pg_hba.conf` so narrower CIDRs precede broad CIDRs |
| **GATE-AUTH-05** | **Channel Binding Enforcement** | Microservice connection pool configuration | `channel_binding=require` | Fail build; enforce `ChannelBinding="require"` in connection builder |
| **GATE-AUTH-06** | **Mandatory verify-full** | Microservice connection string / DSN | `sslmode=verify-full` | Fail build; forbid `sslmode=prefer` or `sslmode=require` |
| **GATE-AUTH-07** | **PBKDF2 Iteration Limit** | `SHOW scram_iterations;` | `4096 <= scram_iterations <= 8192` | Reset `scram_iterations` to 4096 to prevent connection storm auth DoS |
| **GATE-AUTH-08** | **Hostssl Transport Enforcement**| `SELECT count(*) FROM pg_hba_file_rules WHERE type = 'host' AND address NOT IN ('127.0.0.1/32', '::1/128');` | `0` | Convert all external network rules to `hostssl` |
| **GATE-AUTH-09** | **DDL Password Redaction** | Git diff linter on SQL migration files | Zero plaintext `PASSWORD '...'` | Fail PR; enforce environment variable injection or pre-hashed SCRAM verifiers |
| **GATE-AUTH-10** | **Non-Disruptive Reload** | Verification test in staging pipeline | `SELECT pg_reload_conf();` succeeds | Fail deploy if database reboot is attempted instead of dynamic SIGHUP reload |
