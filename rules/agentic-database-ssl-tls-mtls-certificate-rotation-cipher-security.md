---
description: PostgreSQL enterprise transport layer security (SSL/TLS), Mutual TLS (mTLS), zero-downtime certificate rotation, dual-root CA trust bundling, sslmode=verify-full enforcement, Subject Alternative Name (SAN) validation, pg_hba.conf clientcert authentication, pg_ident.conf identity mapping, cipher suite hardening, TLS handshake storm mitigation, and cross-runtime driver invariants across Go (jackc/pgx/v5), TypeScript (drizzle-orm, prisma, pg), Python (asyncpg, psycopg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{ssl,tls,mtls,cert,certificate,pki,security,conn,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/security/**/*.{ts,js,go,rs,py},**/internal/database/**/*.{go,rs},**/migrations/**/*.{sql,ts,go,py},**/config/**/*.{ini,conf,toml,yaml,json}
alwaysApply: false
---

# Agentic Database SSL/TLS, Mutual TLS (mTLS), Certificate Rotation, `sslmode=verify-full`, SAN Validation & Zero-Downtime CA Migration Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design, configure, automate, or maintain PostgreSQL enterprise transport layer security (SSL/TLS), Public Key Infrastructure (PKI), Mutual TLS (`mTLS`) client certificate authentication, certificate life-cycle automation (Let's Encrypt, AWS ACM PCA, HashiCorp Vault, Kubernetes `cert-manager`), or encrypted database connection pipelines across Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `prisma`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Active Man-in-the-Middle (MITM) & Plaintext Downgrade Disaster (`sslmode=prefer` / `sslmode=require`)" (where agents configure permissive SSL modes that allow active network adversaries to silently strip encryption via protocol spoofing or intercept traffic with arbitrary forged certificates), the "Sudden Certificate Expiration Outage & Single-CA Cutover Cliff" (where replacing server certificates signed by a new intermediate/root CA without rolling out a concatenated dual-root CA trust bundle crashes 100% of client connection pools on restart with `x509: certificate signed by unknown authority`), the "Abrupt Postmaster Reboot & Private Key Permission Lockdown Outage (`FATAL: private key file has group or world access`)" (where agents needlessly restart the database engine to rotate certificates—killing thousands of in-flight transactions—or set permissive file permissions causing PostgreSQL to refuse startup), the "Mutual TLS (mTLS) Authentication Failure & `pg_ident.conf` Missing Identity Mapping" (where configuring `clientcert=verify-full` without identity mapping maps the full certificate Common Name to database roles, failing authentication with `SQLSTATE 28000`), the "Insecure Legacy Protocols (TLS 1.0/1.1), Weak CBC Ciphers & SWEET32 / BEAST Vulnerability" (where unhardened TLS defaults trigger immediate PCI-DSS v4.0 Requirement 4.1 audit failure and expose data to cryptographic cracking), and the "Cold TLS Handshake Storm & Connection Pool Latency Spike" (where unsmoothed TLS negotiation spikes database CPU to 100% during autoscaling events) by establishing a strict 5-Tier TLS & Certificate Governance Ladder, MITM vulnerability probability models, dual-root CA cutover transition calculus, an autonomous TypeScript `AgenticDatabaseSSLGuardEngine`, cross-runtime telemetry and connection sentinels in Go, TypeScript, Python, and Rust, a 6-state certificate governance finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 SSL/TLS Catastrophes vs The 5-Tier TLS Governance Ladder

PostgreSQL provides robust native transport layer encryption and certificate verification through OpenSSL. However, autonomous coding agents universally misunderstand the cryptographic semantics of PostgreSQL connection strings (`sslmode`), server certificate reloading mechanics (`pg_reload_conf()`), certificate authority rollover sequences, and client certificate identity mapping. This triggers 6 fatal security breaches and catastrophic production outages:

### The 6 SSL/TLS Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE MITM & PLAINTEXT FALLBACK TRAP (sslmode=prefer / require)
-- Agent writes a database connection string or config for production:
-- postgresql://app_user:secret_pass@db.production.internal:5432/core?sslmode=prefer
-- OR:
-- postgresql://app_user:secret_pass@db.production.internal:5432/core?sslmode=require

-- 💥 Catastrophe 1 (sslmode=prefer):
-- 1. Client sends an SSLRequest packet (protocol code 80877103) during connection initiation.
-- 2. An active adversary on the local network (ARP spoofing, compromised VPC router, or transparent proxy)
--    intercepts the packet and replies with 'N' (server does not support SSL).
-- 3. The client driver (pgx, node-postgres, asyncpg) SILENTLY FALLS BACK to unencrypted plaintext!
-- 4. app_user and secret_pass are transmitted over the wire in cleartext; adversary captures credentials.

-- 💥 Catastrophe 2 (sslmode=require):
-- 1. The client mandates TLS encryption, BUT DOES NOT VERIFY the server certificate chain or hostname!
-- 2. Adversary intercepts DNS or routes and presents ANY self-signed certificate (e.g. CN=attacker.com).
-- 3. Client driver accepts the certificate without error because signature and hostname checks are skipped.
-- 4. Adversary decrypts all queries, captures financial/PII data, and re-encrypts to the real database.
-- Invariant: NEVER use sslmode=prefer or sslmode=require in production; ALWAYS enforce sslmode=verify-full.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE SINGLE-CA REPLACEMENT CLIFF & CLUSTER OUTAGE
-- Agent rotates database SSL certificates in production before updating clients:
-- 1. Old Root CA: "Company Root CA 2024" (Expiring in 7 days).
-- 2. Agent generates new server cert signed by "Company Root CA 2026".
-- 3. Agent installs new server.crt on PostgreSQL primary and standbys.
-- 4. Application containers still have ONLY "Company Root CA 2024" in their sslrootcert file.

-- 💥 Catastrophe:
-- 1. As soon as PostgreSQL starts serving the new certificate, EVERY client connection pool instantly fails:
--    Go (pgx):        "x509: certificate signed by unknown authority"
--    Node.js (pg):    "Error: self signed certificate in certificate chain"
--    Python (asyncpg):"SSLError: certificate verify failed: self signed certificate"
--    Rust (sqlx):     "Tls(CertificateVerifyFailed)"
-- 2. 100% of microservices lose database connectivity simultaneously. Total site outage.
-- 3. Emergency rollback requires rebuilding and redeploying hundreds of container images across clusters.
-- Invariant: Always roll out a concatenated Dual-Root CA Trust Bundle to 100% of clients WEEKS before server cutover.
```

```bash
# ❌ CATASTROPHIC LLM ANTI-PATTERN 3: REBOOT OUTAGE & PERMISSIVE FILE PERMISSIONS
# Agent rotates server.crt and server.key:
chmod 777 /var/lib/postgresql/data/server.key  # "Fixing permission denied errors"
systemctl restart postgresql                   # "Applying rotated certificate"

# 💥 Catastrophe:
# 1. systemctl restart brutally drops 5,000 active client connections and aborts in-flight transactions.
# 2. On restart, the PostgreSQL postmaster inspects server.key and FAILS TO START:
#    FATAL: private key file "/var/lib/postgresql/data/server.key" has group or world access
#    DETAIL: File must have permissions u=rw (0600) or less if owned by the database user, or permissions u=rw,g=r (0640) if owned by root.
# 3. PostgreSQL enters a crash loop. Production remains down until a senior engineer manually SSHs and runs chmod 0600.
# Invariant: Server private keys MUST be 0600 owned by postgres; rotate certificates live via pg_reload_conf().
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: mTLS WITHOUT pg_ident.conf MAPPING BREAKAGE
-- Agent attempts to configure Mutual TLS (mTLS) client certificate authentication:
-- In pg_hba.conf:
hostssl core_db all 10.0.0.0/8 cert clientcert=verify-full

-- 💥 Catastrophe:
-- 1. Microservice connects with client cert Subject: "CN=payment-service.prod.internal".
-- 2. The application database user configured in connection string is "payment_app".
-- 3. Without an explicit 'map=' directive pointing to pg_ident.conf, PostgreSQL matches CN directly:
--    PostgreSQL checks if role "payment-service.prod.internal" exists in pg_roles.
-- 4. Role does not exist; authentication crashes with SQLSTATE 28000:
--    FATAL: 28000: certificate authentication failed for user "payment_app"
--    DETAIL: Provided certificate name "payment-service.prod.internal" did not match user name "payment_app"
-- Invariant: Always declare map=cert_map in pg_hba.conf and map CN regex to PostgreSQL roles in pg_ident.conf.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: INSECURE LEGACY TLS 1.0/1.1 & CBC CIPHERS
-- Agent uses default or outdated postgresql.conf settings:
ssl_min_protocol_version = 'TLSv1'
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'

-- 💥 Catastrophe:
-- 1. SWEET32 vulnerability: 3DES and 64-bit block ciphers allow plaintext recovery via birthday attack after 32 GB.
-- 2. CBC mode allows BEAST and POODLE padding oracle attacks.
-- 3. Instant non-compliance with PCI-DSS v4.0 Requirement 4.1 (Mandates TLS 1.2+ with forward secrecy).
-- Invariant: Lock down ssl_min_protocol_version = 'TLSv1.3' (or TLSv1.2 with strict AEAD ciphers).
```

```text
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: COLD TLS HANDSHAKE AVALANCHE & CPU STARVATION
-- 200 serverless Lambdas / Kubernetes pods scale up simultaneously during a traffic surge.
-- Every instance opens 10 connections directly to PostgreSQL primary without connection pooling or TLS caching.
-- 2,000 cold TLS handshakes hit the database engine within a 500ms window.
-- Asymmetric cryptography (RSA/ECDSA key exchange) consumes 100% of CPU cores.
-- Standard query processing is completely starved; p99 latency spikes from 2ms to 12,000ms.
-- Invariant: Terminate TLS via PgBouncer or sidecar proxy with TLS session resumption enabled.
```

---

### The 5-Tier TLS & Certificate Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   5-TIER POSTGRESQL TLS & PKI GOVERNANCE LADDER                         │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Automated Expiry Watchdogs, Handshake Latency Sentinels & CI DoD Gates        │
│         - Prometheus ssl_certificate_days_to_expiration metric alerting at <= 30d      │
│         - Continuous amcheck and TLS handshake latency monitoring (< 15ms p99)        │
│         - Machine-verifiable CI gate enforcing sslmode=verify-full in 100% repos       │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Mutual TLS (mTLS) & pg_ident.conf Identity Regex Mapping                      │
│         - hostssl ... cert clientcert=verify-full map=service_map                     │
│         - pg_ident.conf: service_map /^(.*)\.services\.internal$ \1                   │
│         - Cryptographic non-repudiation without static passwords in connection strings │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Zero-Downtime Dual-Root CA Trust Bundling & pg_reload_conf() Rotation         │
│         - Concatenated dual-root CA: cat current-ca.crt next-ca.crt > ca-bundle.crt   │
│         - Zero-downtime server rotation via SELECT pg_reload_conf() (No server reboot) │
│         - Strict POSIX file permissions: chmod 0600 server.key, chown postgres        │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Client Verification Mode Enforcement (Mandatory sslmode=verify-full)          │
│         - Permanent ban on sslmode=disable, prefer, require, verify-ca                 │
│         - Explicit sslrootcert=/path/to/ca-bundle.crt with Subject Alternative Name    │
│         - SAN (DNS name / IP) verification eliminates 100% of active MITM attacks     │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Protocol & Cipher Hardening Invariants (TLS 1.3 / AEAD Only)                  │
│         - ssl = on                                                                     │
│         - ssl_min_protocol_version = 'TLSv1.3' (or TLSv1.2 AEAD fallback)              │
│         - ssl_ciphers = 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384...'│
│         - ssl_prefer_server_ciphers = on                                              │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Foundations & Security Invariants

### 2.1 Theorem 1: MITM Insecurity Bounds Across `sslmode` Configurations

Let $\mathcal{A}$ represent an active network adversary capable of intercepting, altering, or re-routing network packets between client $C$ and PostgreSQL server $S$. Let $P(\text{MITM})$ be the probability that $\mathcal{A}$ successfully intercepts and decrypts session plaintext without detection.

$$\begin{aligned}
P(\text{MITM} \mid \text{sslmode}=\text{disable}) &= 1.0 \quad (\text{Plaintext by definition}) \\
P(\text{MITM} \mid \text{sslmode}=\text{prefer}) &= 1.0 \quad (\mathcal{A} \text{ drops SSLRequest, forcing plaintext fallback}) \\
P(\text{MITM} \mid \text{sslmode}=\text{require}) &= 1.0 \quad (\mathcal{A} \text{ presents forged/self-signed cert; } C \text{ accepts}) \\
P(\text{MITM} \mid \text{sslmode}=\text{verify-ca}) &= P(\mathcal{A} \text{ obtains any valid cert from trusted CA}) \approx 1.0 \text{ (Multi-tenant CA)} \\
P(\text{MITM} \mid \text{sslmode}=\text{verify-full}) &\le 2^{-128} \quad (\text{Cryptographically bounded by CA private key \& SHA-256 collision resistance})
\end{aligned}$$

**Proof Statement**:
Under `sslmode=verify-ca`, the client verifies that $\text{Cert}_S$ is signed by a CA in its `sslrootcert`. However, it does not check if the Subject Alternative Name (SAN) matches the target hostname $H_S$. In any enterprise or cloud environment where a shared internal PKI issues certificates for multiple subdomains (e.g., `*.corp.internal`), an attacker who compromises any single internal service certificate (e.g., `test.corp.internal`) can redirect database DNS to their rogue node. `sslmode=verify-ca` will accept this certificate because it is signed by the trusted corporate CA. Only `sslmode=verify-full` enforces both signature validity AND host identity matching:
$$\text{Verified} \iff (\text{VerifyChain}(\text{Cert}_S, \text{RootCAs}) == \text{True}) \land (H_S \in \text{SANs}(\text{Cert}_S))$$
$\blacksquare$

---

### 2.2 Theorem 2: Dual-Root CA Transition Window & Zero-Downtime Migration Invariant

Let $t_{\text{cutover}}$ be the timestamp at which PostgreSQL is reloaded with the new server certificate $\text{Cert}_{\text{new}}$ signed by $\text{CA}_{\text{next}}$.
Let $\mathcal{C} = \{c_1, c_2, \dots, c_N\}$ be the set of all application client instances connecting to PostgreSQL.
Let $\text{TrustStore}(c_i, t)$ denote the set of trusted root/intermediate CA certificates available to client $c_i$ at time $t$.

The system exhibits Zero-Downtime Certificate Transition ($\text{Downtime} = 0$) if and only if:
$$\forall c_i \in \mathcal{C}, \quad \text{CA}_{\text{next}} \in \text{TrustStore}(c_i, t) \quad \forall t \in [t_{\text{deploy\_clients}}, t_{\text{cutover}}]$$
and
$$\forall c_i \in \mathcal{C}, \quad \text{CA}_{\text{current}} \in \text{TrustStore}(c_i, t) \quad \forall t \in [t_{\text{deploy\_clients}}, t_{\text{cutover}} + \Delta t_{\text{drain}}]$$

where $\Delta t_{\text{drain}}$ is the maximum connection lifetime of existing connections established under $\text{Cert}_{\text{old}}$.

**Correlative Invariant**:
The combined trust bundle MUST be generated by concatenating both PEM certificates:
$$\text{ca-bundle.pem} = \text{CA}_{\text{current}} \mathbin{\Vert} \text{CA}_{\text{next}}$$
This ensures that whether a client connects to a server serving $\text{Cert}_{\text{old}}$ (before cutover) or $\text{Cert}_{\text{new}}$ (after cutover), certificate path validation succeeds deterministically.

---

### 2.3 Theorem 3: Cold TLS Handshake Latency Differential & Little's Law CPU Exhaustion

Let $\text{RTT}$ be the network round-trip time between client and database server (typically $0.5\text{ms} - 2.0\text{ms}$ in VPC).
Let $\tau_{\text{crypto}}$ be the CPU time consumed by the asymmetric cryptographic key exchange and signature verification on the database host ($\approx 1.5\text{ms}$ for RSA-2048, $\approx 0.3\text{ms}$ for ECDSA P-256).

The total handshake duration $T_{\text{hs}}$ is governed by:
$$T_{\text{hs}}(\text{TLS 1.2}) = 2 \cdot \text{RTT} + \tau_{\text{crypto}}$$
$$T_{\text{hs}}(\text{TLS 1.3}) = 1 \cdot \text{RTT} + \tau_{\text{crypto}}$$
$$T_{\text{hs}}(\text{TLS 1.3 Resumed}) = 0 \cdot \text{RTT} \text{ (0-RTT PSK)} \text{ or } 1 \cdot \text{RTT} + \tau_{\text{sym}} \quad (\tau_{\text{sym}} \ll \tau_{\text{crypto}})$$

By Little's Law, if connection requests arrive at rate $\lambda_{\text{conn}}$, the number of concurrent handshakes in progress on the server is:
$$L_{\text{hs}} = \lambda_{\text{conn}} \cdot T_{\text{hs}}$$
Host CPU saturation occurs when the rate of asymmetric crypto operations exceeds total CPU throughput:
$$\lambda_{\text{conn}} \cdot \tau_{\text{crypto}} > N_{\text{cores}} \implies \lambda_{\text{max}} = \frac{N_{\text{cores}}}{\tau_{\text{crypto}}}$$

**Numerical Consequence**:
On an 8-core database server with RSA-2048 ($\tau_{\text{crypto}} = 1.5\text{ms}$):
$$\lambda_{\text{max}} = \frac{8}{0.0015\text{s}} \approx 5,333 \text{ connections/sec}$$
A cold connection burst of 6,000 connections/sec completely saturates all 8 CPU cores solely executing TLS handshakes, starving SQL execution and causing query timeouts across all existing sessions.
**Defense**: Enforce ECDSA certificates (P-256 / P-384) to cut $\tau_{\text{crypto}}$ by $5\times$, utilize PgBouncer connection pooling to keep TLS sessions persistent, and enable TLS 1.3.

---

## 3. Production Configuration Sentinels & Implementation Standards

### 3.1 Hardened `postgresql.conf` Transport Security Standard

```ini
# ==============================================================================
# POSTGRESQL ENTERPRISE TLS/SSL PRODUCTION CONFIGURATION
# ==============================================================================

# Enable SSL/TLS engine
ssl = on

# Certificate and Private Key locations (Must be owned by postgres:postgres)
ssl_cert_file = '/var/lib/postgresql/data/certs/server.crt'
ssl_key_file = '/var/lib/postgresql/data/certs/server.key'

# Trusted Certificate Authority for validating client certificates (mTLS)
ssl_ca_file = '/var/lib/postgresql/data/certs/ca-bundle.crt'

# Certificate Revocation List (CRL) for instant revocation of compromised certs
# ssl_crl_file = '/var/lib/postgresql/data/certs/root.crl'

# ------------------------------------------------------------------------------
# Protocol Version & Cipher Suite Hardening
# ------------------------------------------------------------------------------
# Enforce modern TLS protocols only; eradicate TLS 1.0 and TLS 1.1 permanently
ssl_min_protocol_version = 'TLSv1.3'
ssl_max_protocol_version = 'TLSv1.3'

# If TLSv1.2 fallback is mandatory for legacy microservices, use this configuration:
# ssl_min_protocol_version = 'TLSv1.2'
# ssl_ciphers = 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256'
# ssl_prefer_server_ciphers = on

# Diffie-Hellman parameters file (>= 2048-bit prime to defeat Logjam attacks)
# ssl_dh_params_file = '/var/lib/postgresql/data/certs/dh2048.pem'

# Dynamic SSL pass-phrase command (if private key is encrypted)
# ssl_passphrase_command = '/usr/local/bin/fetch_key_passphrase.sh'
```

---

### 3.2 Production `pg_hba.conf` Mutual TLS (mTLS) Standard

```text
# ==============================================================================
# POSTGRESQL pg_hba.conf - STRICT TRANSPORT SECURITY & mTLS ENFORCEMENT
# ==============================================================================
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# 1. Local Unix domain sockets (Administrative access only, bypasses network)
local   all             postgres                                peer
local   all             all                                     scram-sha-256

# 2. Reject ANY unencrypted TCP connections immediately (Defense in Depth)
hostnossl all           all             0.0.0.0/0               reject
hostnossl all           all             ::/0                    reject

# 3. High-Security Microservices: Mutual TLS (mTLS) with identity mapping
# clientcert=verify-full requires client certificate signed by ssl_ca_file
# map=service_cert_map extracts service username from Subject Alternative Name / CN
hostssl core_db         +service_roles  10.0.0.0/8              cert clientcert=verify-full map=service_cert_map
hostssl core_db         +service_roles  172.16.0.0/12           cert clientcert=verify-full map=service_cert_map

# 4. Standard Application Connection Pools: TLS enforced + SCRAM-SHA-256 authentication
# Password is encrypted using SCRAM-SHA-256 (Never md5) over verified TLS tunnel
hostssl core_db         app_user        10.0.0.0/8              scram-sha-256
hostssl analytics_db    analyst_user    10.0.0.0/8              scram-sha-256

# 5. Default-Deny Catch-All: Block any unexpected inbound traffic
host    all             all             0.0.0.0/0               reject
```

---

### 3.3 Production `pg_ident.conf` Identity Regex Mapping

```text
# ==============================================================================
# POSTGRESQL pg_ident.conf - CLIENT CERTIFICATE IDENTITY MAPPING
# MAPNAME          SYSTEM-USERNAME (from cert CN/SAN)       PG-USERNAME
# ==============================================================================

# Map service certificates like "payment-service.prod.internal" -> "payment_app"
service_cert_map   /^payment-service\.(.*)\.internal$        payment_app

# Map service certificates like "order-service.prod.internal" -> "order_app"
service_cert_map   /^order-service\.(.*)\.internal$          order_app

# Map administrative personnel certs "alice.admin@corp.com" -> "alice"
service_cert_map   /^([a-zA-Z0-9_.]+)@corp\.com$            \1
```

---

### 3.4 Zero-Downtime Certificate Rotation Script (`rotate-cert.sh`)

```bash
#!/usr/bin/env bash
# ==============================================================================
# Agentic PostgreSQL Zero-Downtime Certificate Rotation Sentinel
# ==============================================================================
set -euo pipefail

CERT_DIR="/var/lib/postgresql/data/certs"
NEW_CERT="$1"   # Path to newly issued server.crt
NEW_KEY="$2"    # Path to newly issued server.key
NEW_CA_BUNDLE="$3" # Path to dual-root ca-bundle.crt

if [ ! -f "$NEW_CERT" ] || [ ! -f "$NEW_KEY" ] || [ ! -f "$NEW_CA_BUNDLE" ]; then
    echo "❌ Usage: $0 <path_to_new_cert> <path_to_new_key> <path_to_ca_bundle>"
    exit 1
fi

echo "🔍 Step 1: Pre-flight validation of new certificate and key..."

# 1. Verify certificate validity window
if ! openssl x509 -checkend 86400 -noout -in "$NEW_CERT"; then
    echo "❌ Error: New certificate expires within 24 hours or is already expired!"
    exit 1
fi

# 2. Verify that public key in certificate matches private key modulus
CERT_MODULUS=$(openssl x509 -noout -modulus -in "$NEW_CERT" 2>/dev/null | openssl md5 || openssl x509 -noout -pubkey -in "$NEW_CERT" | openssl md5)
KEY_MODULUS=$(openssl rsa -noout -modulus -in "$NEW_KEY" 2>/dev/null | openssl md5 || openssl pkey -pubout -in "$NEW_KEY" | openssl md5)

if [ "$CERT_MODULUS" != "$KEY_MODULUS" ]; then
    echo "❌ FATAL: Certificate public key does not match private key!"
    exit 1
fi

# 3. Verify certificate chain against the trusted CA bundle
if ! openssl verify -CAfile "$NEW_CA_BUNDLE" "$NEW_CERT"; then
    echo "❌ FATAL: Certificate verification against CA bundle failed!"
    exit 1
fi

echo "🔒 Step 2: Staging new certificate files with strict POSIX permissions..."
BACKUP_DIR="${CERT_DIR}/backup_$(date +%s)"
mkdir -p "$BACKUP_DIR"
cp "${CERT_DIR}/server.crt" "${BACKUP_DIR}/" || true
cp "${CERT_DIR}/server.key" "${BACKUP_DIR}/" || true
cp "${CERT_DIR}/ca-bundle.crt" "${BACKUP_DIR}/" || true

# Copy files atomically
cp "$NEW_CERT" "${CERT_DIR}/server.crt.new"
cp "$NEW_KEY" "${CERT_DIR}/server.key.new"
cp "$NEW_CA_BUNDLE" "${CERT_DIR}/ca-bundle.crt.new"

# Enforce PostgreSQL POSIX security invariants: 0600 owned by postgres
chmod 0644 "${CERT_DIR}/server.crt.new"
chmod 0600 "${CERT_DIR}/server.key.new"
chmod 0644 "${CERT_DIR}/ca-bundle.crt.new"
chown postgres:postgres "${CERT_DIR}"/*.new

# Atomic swap
mv -f "${CERT_DIR}/server.crt.new" "${CERT_DIR}/server.crt"
mv -f "${CERT_DIR}/server.key.new" "${CERT_DIR}/server.key"
mv -f "${CERT_DIR}/ca-bundle.crt.new" "${CERT_DIR}/ca-bundle.crt"

echo "⚡ Step 3: Executing live PostgreSQL configuration reload..."
# Zero-downtime hot reload: existing connections remain alive, new handshakes use new cert
RELOAD_RESULT=$(psql -U postgres -d postgres -t -A -c "SELECT pg_reload_conf();")

if [ "$RELOAD_RESULT" != "t" ]; then
    echo "❌ Error: pg_reload_conf() returned false! Check PostgreSQL logs."
    exit 1
fi

echo "🩺 Step 4: Post-reload handshake verification..."
sleep 1
if ! openssl s_client -connect 127.0.0.1:5432 -starttls postgres -CAfile "${CERT_DIR}/ca-bundle.crt" </dev/null 2>&1 | grep -q "Verify return code: 0 (ok)"; then
    echo "❌ FATAL: TLS handshake test failed after reload! Rolling back..."
    mv -f "${BACKUP_DIR}/server.crt" "${CERT_DIR}/server.crt"
    mv -f "${BACKUP_DIR}/server.key" "${CERT_DIR}/server.key"
    mv -f "${BACKUP_DIR}/ca-bundle.crt" "${CERT_DIR}/ca-bundle.crt"
    psql -U postgres -d postgres -c "SELECT pg_reload_conf();"
    exit 1
fi

echo "✅ Success: Zero-downtime certificate rotation verified and completed."
```

---

## 4. Cross-Runtime Client Driver Invariants

### 4.1 Go (`jackc/pgx/v5`) Production TLS & mTLS Sentinel

```go
package database

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PostgresTLSConfig defines the runtime security parameters
type PostgresTLSConfig struct {
	Host             string
	Port             int
	Database         string
	User             string
	Password         string
	CABundlePath     string
	ClientCertPath   string // Optional: for mTLS
	ClientKeyPath    string // Optional: for mTLS
	RequireTLS13     bool
}

// NewHardenedPgxPool constructs a connection pool with strictly enforced verify-full TLS
func NewHardenedPgxPool(ctx context.Context, cfg PostgresTLSConfig) (*pgxpool.Pool, error) {
	// 1. Load Root CA Bundle
	caCertPEM, err := os.ReadFile(cfg.CABundlePath)
	if err != nil {
		return nil, fmt.Errorf("failed to read CA bundle at %s: %w", cfg.CABundlePath, err)
	}

	rootCertPool := x509.NewCertPool()
	if ok := rootCertPool.AppendCertsFromPEM(caCertPEM); !ok {
		return nil, fmt.Errorf("failed to append CA bundle certificates from %s", cfg.CABundlePath)
	}

	// 2. Configure TLS Parameters
	minVersion := uint16(tls.VersionTLS13)
	if !cfg.RequireTLS13 {
		minVersion = tls.VersionTLS12
	}

	tlsConfig := &tls.Config{
		MinVersion: minVersion,
		RootCAs:    rootCertPool,
		ServerName: cfg.Host, // MANDATORY: Enforces Subject Alternative Name (SAN) validation
		// Invariant: InsecureSkipVerify MUST be false (default in Go, never override)
		InsecureSkipVerify: false,
	}

	// 3. Configure Mutual TLS (mTLS) if client credentials provided
	if cfg.ClientCertPath != "" && cfg.ClientKeyPath != "" {
		clientCert, err := tls.LoadX509KeyPair(cfg.ClientCertPath, cfg.ClientKeyPath)
		if err != nil {
			return nil, fmt.Errorf("failed to load client key pair: %w", err)
		}
		tlsConfig.Certificates = []tls.Certificate{clientCert}
	}

	// 4. Construct Connection String
	connStr := fmt.Sprintf(
		"host=%s port=%d dbname=%s user=%s sslmode=verify-full",
		cfg.Host, cfg.Port, cfg.Database, cfg.User,
	)
	if cfg.Password != "" {
		connStr += fmt.Sprintf(" password=%s", cfg.Password)
	}

	poolConfig, err := pgxpool.ParseConfig(connStr)
	if err != nil {
		return nil, fmt.Errorf("failed to parse connection config: %w", err)
	}

	// Attach explicit hardened tls.Config to pgx connection options
	poolConfig.ConnConfig.TLSConfig = tlsConfig

	// Connection Pool Health Invariants
	poolConfig.MaxConns = 50
	poolConfig.MinConns = 10
	poolConfig.MaxConnLifetime = 30 * time.Minute
	poolConfig.MaxConnIdleTime = 5 * time.Minute
	poolConfig.HealthCheckPeriod = 1 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create connection pool: %w", err)
	}

	// 5. Pre-flight Ping to verify TLS handshake and SAN matching
	pingCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("initial TLS handshake ping failed (verify-full check): %w", err)
	}

	return pool, nil
}
```

---

### 4.2 TypeScript (`node-postgres` & `drizzle-orm`) Production TLS Standard

```typescript
import fs from 'node:fs';
import path from 'node:path';
import tls from 'node:tls';
import { Pool, type PoolConfig } from 'pg';
import { drizzle } from 'drizzle-orm/node-postgres';

export interface DatabaseTLSConfig {
  host: string;
  port: number;
  database: string;
  user: string;
  password?: string;
  caCertPath: string;
  clientCertPath?: string; // For mTLS
  clientKeyPath?: string;  // For mTLS
}

/**
 * Creates a hardened, verify-full PostgreSQL pool preventing MITM attacks.
 */
export function createHardenedDatabasePool(cfg: DatabaseTLSConfig): Pool {
  // 1. Read CA certificate bundle
  if (!fs.existsSync(cfg.caCertPath)) {
    throw new Error(`[TLS Invariant] Root CA bundle not found at: ${cfg.caCertPath}`);
  }
  const caCert = fs.readFileSync(path.resolve(cfg.caCertPath), 'utf8');

  // 2. Build explicit TLS configuration
  const sslOptions: tls.ConnectionOptions = {
    // MANDATORY: rejectUnauthorized MUST be true to enforce certificate verification
    rejectUnauthorized: true,
    ca: caCert,
    servername: cfg.host, // Enforces Subject Alternative Name (SAN) match
    minVersion: 'TLSv1.3',
  };

  // 3. Attach mTLS client credentials if provided
  if (cfg.clientCertPath && cfg.clientKeyPath) {
    if (!fs.existsSync(cfg.clientCertPath) || !fs.existsSync(cfg.clientKeyPath)) {
      throw new Error(`[TLS Invariant] Client cert or key missing for mTLS`);
    }
    sslOptions.cert = fs.readFileSync(path.resolve(cfg.clientCertPath), 'utf8');
    sslOptions.key = fs.readFileSync(path.resolve(cfg.clientKeyPath), 'utf8');
  }

  const poolConfig: PoolConfig = {
    host: cfg.host,
    port: cfg.port,
    database: cfg.database,
    user: cfg.user,
    password: cfg.password,
    ssl: sslOptions,
    max: 30,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 5000,
  };

  const pool = new Pool(poolConfig);

  pool.on('error', (err) => {
    console.error('Unexpected error on idle PostgreSQL client (TLS/Network):', err);
  });

  return pool;
}
```

---

### 4.3 Python (`asyncpg`) Production TLS Standard

```python
import ssl
import asyncpg
from typing import Optional

def build_hardened_ssl_context(
    ca_bundle_path: str,
    client_cert_path: Optional[str] = None,
    client_key_path: Optional[str] = None,
    require_tls13: bool = True
) -> ssl.SSLContext:
    """
    Constructs an explicit SSLContext enforcing certificate validation,
    hostname matching, and modern TLS protocol versions.
    """
    # Create default SSL context for client-side connection verification
    ctx = ssl.create_default_context(
        purpose=ssl.Purpose.SERVER_AUTH,
        cafile=ca_bundle_path
    )
    
    # MANDATORY: Verify server certificate authority and hostname
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    
    # Enforce minimum protocol version
    if require_tls13:
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    else:
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2

    # Mutual TLS (mTLS) configuration
    if client_cert_path and client_key_path:
        ctx.load_cert_chain(
            certfile=client_cert_path,
            keyfile=client_key_path
        )
        
    return ctx

async def create_secure_db_pool(
    host: str,
    port: int,
    database: str,
    user: str,
    password: Optional[str],
    ca_bundle_path: str,
    client_cert_path: Optional[str] = None,
    client_key_path: Optional[str] = None
) -> asyncpg.Pool:
    ssl_ctx = build_hardened_ssl_context(
        ca_bundle_path=ca_bundle_path,
        client_cert_path=client_cert_path,
        client_key_path=client_key_path
    )
    
    # asyncpg uses ssl context object directly; server_hostname guarantees SAN match
    pool = await asyncpg.create_pool(
        host=host,
        port=port,
        database=database,
        user=user,
        password=password,
        ssl=ssl_ctx,
        server_settings={
            'application_name': 'python-asyncpg-mtls'
        },
        min_size=5,
        max_size=25,
        timeout=5.0
    )
    return pool
```

---

### 4.4 Rust (`sqlx`) Production TLS Standard

```rust
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgSslMode};
use sqlx::{Pool, Postgres};
use std::path::Path;
use std::time::Duration;

pub struct DbConfig {
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    pub password: Option<String>,
    pub ca_bundle_path: String,
}

pub async fn create_hardened_pg_pool(cfg: DbConfig) -> Result<Pool<Postgres>, sqlx::Error> {
    let mut connect_opts = PgConnectOptions::new()
        .host(&cfg.host)
        .port(cfg.port)
        .database(&cfg.database)
        .username(&cfg.username);

    if let Some(pwd) = cfg.password {
        connect_opts = connect_opts.password(&pwd);
    }

    // MANDATORY: Enforce PgSslMode::VerifyFull and provide CA bundle
    // This activates root certificate verification and SAN hostname matching
    connect_opts = connect_opts
        .ssl_mode(PgSslMode::VerifyFull)
        .ssl_root_cert(Path::new(&cfg.ca_bundle_path));

    let pool = PgPoolOptions::new()
        .max_connections(25)
        .min_connections(5)
        .acquire_timeout(Duration::from_secs(3))
        .idle_timeout(Duration::from_secs(300))
        .connect_with(connect_opts)
        .await?;

    Ok(pool)
}
```

---

## 5. Executable TypeScript Guard Engine: `AgenticDatabaseSSLGuardEngine`

The following production-ready TypeScript engine inspects database connection URIs, PostgreSQL configuration files, and X.509 certificate chains to autonomously detect and block SSL/TLS misconfigurations.

```typescript
import * as crypto from 'node:crypto';
import * as fs from 'node:fs';

export type SSLMode = 'disable' | 'allow' | 'prefer' | 'require' | 'verify-ca' | 'verify-full';

export interface TLSInspectionResult {
  isSecure: boolean;
  sslMode: SSLMode;
  violations: string[];
  warnings: string[];
  certExpiryDays?: number;
  sanMatched?: boolean;
}

export interface CertChainMetadata {
  subject: string;
  issuer: string;
  validFrom: Date;
  validTo: Date;
  subjectAltNames: string[];
  isCA: boolean;
}

export class AgenticDatabaseSSLGuardEngine {
  /**
   * Evaluates a database connection URL or parameter dictionary for TLS compliance.
   */
  public static inspectConnectionUri(uriStr: string): TLSInspectionResult {
    const violations: string[] = [];
    const warnings: string[] = [];
    let sslMode: SSLMode = 'prefer'; // Default if unspecified in standard libpq

    try {
      const url = new URL(uriStr);
      const modeParam = url.searchParams.get('sslmode')?.toLowerCase();
      const sslRootCert = url.searchParams.get('sslrootcert');

      if (modeParam) {
        sslMode = modeParam as SSLMode;
      }

      // Check 1: Insecure sslmode check
      if (sslMode === 'disable') {
        violations.push("CRITICAL: sslmode=disable transmits credentials and data in cleartext.");
      } else if (sslMode === 'allow' || sslMode === 'prefer') {
        violations.push(`CRITICAL: sslmode=${sslMode} is vulnerable to active MITM plaintext downgrade.`);
      } else if (sslMode === 'require') {
        violations.push("HIGH: sslmode=require skips certificate authority and SAN hostname verification.");
      } else if (sslMode === 'verify-ca') {
        warnings.push("WARNING: sslmode=verify-ca verifies CA chain but does NOT match target hostname SAN.");
      }

      // Check 2: Missing sslrootcert in verify-full
      if (sslMode === 'verify-full' && !sslRootCert) {
        warnings.push("ADVISORY: sslmode=verify-full specified without explicit sslrootcert parameter; relying on system trust store.");
      }

      const isSecure = violations.length === 0 && sslMode === 'verify-full';
      return { isSecure, sslMode, violations, warnings };
    } catch (e: any) {
      return {
        isSecure: false,
        sslMode: 'disable',
        violations: [`Invalid connection URI: ${e.message}`],
        warnings: [],
      };
    }
  }

  /**
   * Inspects server certificate and private key file permissions on the filesystem.
   */
  public static inspectServerCertFiles(certPath: string, keyPath: string): { valid: boolean; errors: string[] } {
    const errors: string[] = [];

    if (!fs.existsSync(certPath)) {
      errors.push(`Server certificate file does not exist at ${certPath}`);
    }
    if (!fs.existsSync(keyPath)) {
      errors.push(`Server private key file does not exist at ${keyPath}`);
      return { valid: false, errors };
    }

    try {
      const stats = fs.statSync(keyPath);
      const mode = stats.mode & 0o777;

      // PostgreSQL requires key file to have permissions 0600 or less (or 0640 if group owned by root)
      if ((mode & 0o077) !== 0) {
        errors.push(`FATAL: server.key has permissive permissions (0${mode.toString(8)}). Must be 0600 or 0400.`);
      }
    } catch (e: any) {
      errors.push(`Failed to inspect file permissions: ${e.message}`);
    }

    return { valid: errors.length === 0, errors };
  }

  /**
   * Parses an X.509 certificate and verifies remaining validity days and SAN entries.
   */
  public static inspectCertificateMetadata(certPem: string, expectedHostname: string): TLSInspectionResult {
    const violations: string[] = [];
    const warnings: string[] = [];

    try {
      const x509 = new crypto.X509Certificate(certPem);
      const now = new Date();
      const validTo = new Date(x509.validTo);
      const validFrom = new Date(x509.validFrom);

      if (now < validFrom) {
        violations.push(`Certificate is not yet valid (validFrom: ${x509.validFrom})`);
      }
      if (now > validTo) {
        violations.push(`CRITICAL: Certificate has EXPIRED on ${x509.validTo}`);
      }

      const msPerDay = 1000 * 60 * 60 * 24;
      const daysRemaining = Math.floor((validTo.getTime() - now.getTime()) / msPerDay);

      if (daysRemaining <= 30 && daysRemaining > 0) {
        warnings.push(`URGENT: Certificate will expire in ${daysRemaining} days. Immediate rotation required.`);
      }

      // Parse SANs
      const sanEntries: string[] = [];
      const sanHeader = x509.subjectAltName;
      let sanMatched = false;

      if (sanHeader) {
        const parts = sanHeader.split(',').map((s) => s.trim());
        for (const part of parts) {
          if (part.startsWith('DNS:') || part.startsWith('IP Address:')) {
            const val = part.split(':')[1]?.trim();
            if (val) sanEntries.push(val);
          }
        }
      }

      // Hostname SAN match validation
      sanMatched = sanEntries.some((san) => {
        if (san === expectedHostname) return true;
        if (san.startsWith('*.') && expectedHostname.endsWith(san.slice(2))) return true;
        return false;
      });

      if (!sanMatched) {
        violations.push(`Hostname mismatch: expected '${expectedHostname}', SANs found: [${sanEntries.join(', ')}]`);
      }

      return {
        isSecure: violations.length === 0,
        sslMode: 'verify-full',
        violations,
        warnings,
        certExpiryDays: daysRemaining,
        sanMatched,
      };
    } catch (e: any) {
      return {
        isSecure: false,
        sslMode: 'disable',
        violations: [`Failed to parse X.509 certificate: ${e.message}`],
        warnings: [],
      };
    }
  }
}
```

---

## 6. Six-State TLS Governance Finite State Machine (FSM)

The following state machine governs the end-to-end lifecycle of PostgreSQL TLS and certificate operations:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│              POSTGRESQL TLS & CERTIFICATE GOVERNANCE FSM                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   [1. INITIAL_AUDIT]                                                            │
│          │                                                                      │
│          ▼ (Validate sslmode=verify-full & TLS 1.3 protocol baselines)         │
│   [2. CA_BUNDLE_STAGING]                                                        │
│          │                                                                      │
│          ▼ (Concatenate Dual-Root CA & deploy bundle to 100% client services)   │
│   [3. SERVER_CERT_PROVISIONING]                                                 │
│          │                                                                      │
│          ▼ (Verify key modulus, SAN match & enforce chmod 0600 on server.key)   │
│   [4. ZERO_DOWNTIME_HOT_RELOAD]                                                 │
│          │                                                                      │
│          ▼ (Execute SELECT pg_reload_conf(); zero in-flight connection drop)    │
│   [5. HANDSHAKE_CANARY_VERIFICATION]                                            │
│          │                                                                      │
│          ▼ (Verify OpenSSL s_client handshake & clientcert mTLS identity map)   │
│   [6. CONTINUOUS_TELEMETRY_MONITORING]                                          │
│          │                                                                      │
│          └─► (Alert on cert expiry <= 30d; restart cycle at [2] upon renewal)   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

- **State 1: `INITIAL_AUDIT`**: Static and dynamic analysis of connection URIs across application repos. Forbid `sslmode=disable|prefer|require`. Enforce `verify-full`.
- **State 2: `CA_BUNDLE_STAGING`**: During CA rotation, create concatenated dual-root CA trust bundle. Distribute to all microservice pods and verify client connectivity.
- **State 3: `SERVER_CERT_PROVISIONING`**: Issue new server certificate with Subject Alternative Names (SAN) matching all cluster DNS endpoints. Validate key pair matching with `openssl`. Enforce `chmod 0600` on private key.
- **State 4: `ZERO_DOWNTIME_HOT_RELOAD`**: Stage new certificate and key files via atomic rename. Execute `SELECT pg_reload_conf()`. Never restart PostgreSQL server daemon.
- **State 5: `HANDSHAKE_CANARY_VERIFICATION`**: Run synthetic TLS 1.3 client handshakes against primary and standby replicas. Verify `pg_ident.conf` mapping for mTLS roles.
- **State 6: `CONTINUOUS_TELEMETRY_MONITORING`**: Continuously export `ssl_certificate_days_to_expiration` metric. Trigger automated alert when expiry $\le 30$ days.

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates Matrix

Every pull request, database migration, or infrastructure deployment involving PostgreSQL connection strings or certificates MUST satisfy all 6 DoD gates:

| Gate | Verification Check | Command / Assertion | Exit Criterion |
|---|---|---|---|
| **DoD 1: Strict sslmode CI Gate** | Scan all repository connection URIs | `git grep -E 'sslmode=(prefer\|require\|disable\|allow)'` | **0 occurrences** (Only `sslmode=verify-full` permitted) |
| **DoD 2: Protocol Version Gate** | Verify `postgresql.conf` protocol limits | `psql -c "SHOW ssl_min_protocol_version;"` | Returns **`TLSv1.3`** (or `TLSv1.2` with approved AEAD ciphers) |
| **DoD 3: File Permissions Gate** | Verify private key file security | `stat -c "%a %U" $PGDATA/server.key` | Returns **`600 postgres`** or **`400 postgres`** |
| **DoD 4: SAN Hostname Validation** | Inspect Subject Alternative Names | `openssl x509 -noout -text -in server.crt \| grep -A 1 "Subject Alternative Name"` | Contains exact production DNS hostname |
| **DoD 5: Expiration Horizon Gate** | Check remaining certificate validity | `openssl x509 -checkend 2592000 -noout -in server.crt` | **Exit code 0** (Certificate valid for $> 30$ days) |
| **DoD 6: mTLS Identity Mapping** | Validate `pg_ident.conf` syntax & map | `psql -c "SELECT * FROM pg_ident_file_mappings WHERE error IS NOT NULL;"` | **0 rows returned** (No invalid regex mappings) |
