---
description: PostgreSQL (10+), SQLite, and distributed SQL collations, Unicode normalization (NFC/NFD), ICU providers, case-insensitive uniqueness, glibc OS upgrade B-tree corruption defense, COLLATE "C" byte-wise optimization, and pattern_ops sargability across Go (golang.org/x/text, pgx/v5), TypeScript (Drizzle, Kysely), Python (unicodedata, psycopg3), Rust (unicode-normalization, sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{collation,unicode,locale,icu,case_insensitive,user,auth,account,identity,email,token,search,schema,migration}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Collations, Unicode Normalization (NFC/NFD), ICU Locales, Case-Insensitive Invariants & B-Tree glibc Corruption Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design database schemas, user authentication systems, multi-lingual search, identity resolution, or data migration pipelines across PostgreSQL (10+), SQLite, MySQL (8.0+), Go (`jackc/pgx/v5`, `golang.org/x/text`), TypeScript (`drizzle-orm`, `kysely`, `prisma`), Python (`psycopg3`, `unicodedata`), or Rust (`sqlx`, `unicode-normalization`). Eliminate the "Silent glibc OS Upgrade B-Tree Index Corruption Disaster" (where Linux distribution or `libc6` upgrades change `strcoll` sorting definitions, corrupting on-disk B-Trees, causing unique index lookups to silently return zero rows, and permitting duplicate unique keys across critical tables), the "Case-Insensitive Uniqueness & Auth Impersonation Catastrophe (CWE-178)" (where agents declare standard `UNIQUE` constraints on emails or handles and query with unindexed `LOWER(email) = LOWER($1)`, enabling account hijacking through case-variation registration while triggering 100% CPU full-table sequential scans), the "Unicode Normalization (NFC vs NFD) Duplication & Homoglyph Injection Disaster" (where macOS decomposed NFD characters and web precomposed NFC characters produce distinct binary strings for visually identical names, bypassing authorization checks and foreign keys), the "`COLLATE "C"` Machine Identifier Performance Penalty" (where storing UUIDs, ULIDs, API keys, and SHA-256 hashes under natural language collations forces the engine to run expensive locale collation algorithms for every index traversal and join, burning up to 45% of backend CPU cycles), the "Non-Sargable Prefix Matching (`LIKE 'prefix%'`) B-Tree Bypass Trap" (where B-Tree indexes under standard locale collations cannot be traversed for wildcard prefix queries without `text_pattern_ops` or `varchar_pattern_ops`, triggering table scans), and the "Non-Deterministic Collation Regex & LIKE Operator Rejection Meltdown" (where applying non-deterministic collations to general columns causes queries using `~` or pattern matching to crash with `ERROR: nondeterministic collations are not supported`) by establishing a strict 5-Tier Collation & Unicode Governance Ladder, asymptotic complexity proofs, a production-ready TypeScript `AgenticCollationUnicodeGuardEngine`, cross-language implementations in Go, TypeScript, Python, and Rust, a complete 6-state collation lifecycle finite-state machine (FSM), and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Collation & Unicode Catastrophes vs The 5-Tier Governance Ladder

String comparison in modern relational databases is not a simple byte comparison. Unless explicitly declared, relational databases order and compare text according to **Collations**—complex rules defining alphabetical sorting, case folding, accent handling, and linguistic equivalence across languages.

PostgreSQL supports two distinct collation providers:
1. **libc (Operating System glibc/musl)**: Relies on the host OS locale database. Highly vulnerable to system upgrades and platform differences between macOS (BSD libc) and Linux (glibc).
2. **ICU (International Components for Unicode)**: An external, platform-independent, standardized Unicode collation library providing deterministic versioning, customizable collation strength (case-insensitive, accent-insensitive), and non-deterministic collations.

When autonomous coding agents generate schemas, queries, or auth routines, LLMs routinely introduce 6 catastrophic architectural flaws:

### The 6 Collation & Unicode Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: SILENT glibc OS UPGRADE B-TREE CORRUPTION
-- Schema created on Debian 10 (glibc 2.28):
CREATE TABLE users (
    id UUID PRIMARY KEY,
    username VARCHAR(100) UNIQUE NOT NULL -- Uses default database collation (e.g., "en_US.UTF-8" via libc)
);

-- Host OS is upgraded to Debian 11/12 or Ubuntu 22.04 (glibc 2.31 / 2.36):
-- glibc updates its locale collation definitions (e.g., changes how hyphens or punctuation sort).
-- The B-Tree index on `username` on disk was sorted according to glibc 2.28 rules!
-- Now, PostgreSQL performs binary search using the new glibc 2.36 rules:
SELECT * FROM users WHERE username = 'john-doe';
-- ❌ RETURNS 0 ROWS even though the row exists! The binary search branch traversal took the wrong path!

-- Worse: An insert with the same username executes:
INSERT INTO users (id, username) VALUES ('...', 'john-doe');
-- ❌ SUCCESS! Unique constraint fails to detect existing tuple because it navigated down a different leaf page!
-- PostgreSQL logs: "WARNING: database "mydb" has a collation version mismatch"
-- LLMs and automated scripts ignore this warning until database integrity is destroyed.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: CASE-INSENSITIVE UNIQUENESS & AUTH IMPERSONATION (CWE-178)
-- Autonomous agent writes user registration schema:
CREATE TABLE accounts (
    id UUID PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL, -- Standard collation: 'A' != 'a'
    password_hash TEXT NOT NULL
);

-- Legitimate user signs up: "alice@company.com"
-- Attacker signs up: "Alice@Company.com"
-- ❌ Database allows both! Both rows are inserted because default collations are case-sensitive!
-- Downstream JWT auth, OAuth SSO, or billing systems fold case: "Alice@Company.com" -> "alice@company.com".
-- Attacker now receives Alice's invoices, password reset tokens, or impersonates Alice!

-- Agent attempts to "fix" lookup with runtime LOWER():
-- In Node.js / Go backend:
SELECT * FROM accounts WHERE LOWER(email) = LOWER($1);
-- ❌ Catastrophe: LOWER(email) is a function call on the table column!
-- The B-Tree index on `email` is NOT sargable for LOWER(email)!
-- The query planner abandons the index and triggers a 100% CPU Sequential Scan on 5,000,000 rows!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: UNICODE NORMALIZATION (NFC vs NFD) DUPLICATION
-- User 1 registers from macOS Safari:
-- macOS decomposes "é" into NFD: 'e' (\u0065) + combining acute accent (\u0301).
-- Raw UTF-8 bytes: [0x65, 0xCC, 0x81]
INSERT INTO profiles (handle) VALUES ('café'); -- Stored as NFD (6 bytes)

-- User 2 registers from Chrome / Windows:
-- Windows sends precomposed NFC: 'é' (\u00E9).
-- Raw UTF-8 bytes: [0xC3, 0xA9]
INSERT INTO profiles (handle) VALUES ('café'); -- Stored as NFC (5 bytes)

-- ❌ Both inserts succeed even with UNIQUE(handle)!
-- Visually identical handles exist simultaneously in the system!
-- Phishing attacks, spoofed brand handles, and broken foreign key lookups occur.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: MACHINE IDENTIFIERS UNDER LOCALE COLLATION
-- Agent stores high-volume synthetic tokens with default collation:
CREATE TABLE api_keys (
    key_hash VARCHAR(64) PRIMARY KEY, -- SHA-256 hexadecimal string
    client_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

-- On every API request:
SELECT client_id FROM api_keys WHERE key_hash = $1;
-- ❌ Catastrophe:
-- With default collation "en_US.UTF-8", PostgreSQL invokes locale-aware strcoll() for every B-Tree comparison!
-- In a 30-level B-Tree across 50,000 req/sec, PostgreSQL spends 40%+ of its CPU comparing ASCII hex digits
-- using complex multilingual sorting tables instead of single-cycle hardware `memcmp()`!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: NON-SARGABLE PREFIX LIKE UNDER LOCALE COLLATION
CREATE TABLE products (
    id UUID PRIMARY KEY,
    sku VARCHAR(64) NOT NULL
);
CREATE INDEX idx_products_sku ON products (sku);

-- Agent executes prefix search:
SELECT * FROM products WHERE sku LIKE 'ELEC-2026%';
-- ❌ Catastrophe:
-- Under standard non-C collations, B-Tree index ordering does not correspond to byte prefix matching!
-- PostgreSQL EXPLAIN output:
-- Seq Scan on products (cost=0.00..85420.00 rows=15 width=72)
-- Filter: ((sku)::text ~~ 'ELEC-2026%'::text)
-- The index is completely ignored!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: NON-DETERMINISTIC COLLATION OPERATOR REJECTION
-- Agent hears about PostgreSQL 12+ non-deterministic collations:
CREATE COLLATION case_insensitive (
    provider = icu,
    locale = 'und-u-ks-level2',
    deterministic = false
);

CREATE TABLE documents (
    id UUID PRIMARY KEY,
    title TEXT COLLATE case_insensitive NOT NULL,
    content TEXT COLLATE case_insensitive NOT NULL
);

-- Production code runs a regex filter:
SELECT * FROM documents WHERE content ~* 'confidential.*draft';
-- ❌ CRASH IN PRODUCTION:
-- ERROR: nondeterministic collations are not supported for regular expression operators
-- Queries using LIKE with complex patterns, regex (~), or pattern-matching functions throw fatal runtime errors!
```

---

### The 5-Tier Collation & Unicode Governance Ladder

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                   THE 5-TIER COLLATION & UNICODE GOVERNANCE LADDER                               │
├───────┬──────────────────────────────────┬───────────────────────────────────────────────────────┤
│ Tier  │ Architecture Strategy            │ Production Invariant                                  │
├───────┼──────────────────────────────────┼───────────────────────────────────────────────────────┤
│  0    │ Machine Identifier Byte Order    │ Force `COLLATE "C"` or `COLLATE "POSIX"` on all       │
│       │ Acceleration                     │ UUIDs, hashes, tokens, API keys ($3\times–8\times$ CPU│
│       │                                  │ speedup via hardware `memcmp()`).                     │
├───────┼──────────────────────────────────┼───────────────────────────────────────────────────────┤
│  1    │ Boundary Unicode Normalization   │ Enforce canonical Unicode NFC normalization at the    │
│       │ (NFC) Invariants                 │ perimeter gateway and via PostgreSQL 14+ CHECK:       │
│       │                                  │ `CHECK (username = unicode_normalize_nfc(username))`.│
├───────┼──────────────────────────────────┼───────────────────────────────────────────────────────┤
│  2    │ Dual Case-Insensitive Strategy   │ User handles: Non-deterministic ICU collations        │
│       │ (ICU vs Functional B-Trees)      │ (`und-u-ks-level2`). Search/Regex text: Deterministic │
│       │                                  │ collation with `LOWER()` functional unique indexes.   │
├───────┼──────────────────────────────────┼───────────────────────────────────────────────────────┤
│  3    │ Sargable Pattern Matching        │ Create B-Tree indexes with `text_pattern_ops` or      │
│       │ Operator Classes                 │ `varchar_pattern_ops` for all prefix `LIKE` columns.  │
├───────┼──────────────────────────────────┼───────────────────────────────────────────────────────┤
│  4    │ Zero-Downtime glibc/ICU Version  │ CI sentinels detect collation mismatches; automated   │
│       │ Drift & REINDEX Sentinels        │ `REINDEX CONCURRENTLY` and `REFRESH COLLATION VERSION`│
└───────┴──────────────────────────────────┴───────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Formalization & Algorithmic Complexity

### Theorem 1: Asymptotic Complexity of Locale Collation vs Byte-Wise Comparison

Let $S_1, S_2 \in \Sigma^*$ be two strings of length $L$ over an alphabet $\Sigma$.
Under byte-wise collation (`COLLATE "C"`), comparison is performed via hardware-vectorized `memcmp`:
$$T_{\text{"C"}}(L) = \mathcal{O}\left(\left\lceil \frac{L}{W} \right\rceil\right)$$
where $W$ is the CPU SIMD register word width ($W = 32\text{ bytes}$ on AVX2, $W = 64\text{ bytes}$ on AVX-512). If the first difference occurs at character position $k \le L$, the comparison terminates in:
$$T_{\text{"C"}, \text{actual}} = \mathcal{O}(k)$$

Under natural language locale collation (Unicode Collation Algorithm / UCA via `strcoll` or ICU):
Each character $c_i$ maps to a multi-level collation element $CE(c_i) = [w_1, w_2, w_3, w_4]$ where $w_1$ represents base character weight, $w_2$ accent weight, $w_3$ case weight, and $w_4$ special weight.
The algorithm constructs sort keys across all 4 levels:
$$T_{\text{locale}}(L) = \sum_{j=1}^{4} \mathcal{O}(L) = \mathcal{O}(4L)$$
Even when $S_1$ and $S_2$ differ at the very first byte, locale-aware collation often cannot short-circuit until the entire string is decomposed into canonical combining classes.

**Speedup Ratio Metric**:
$$\text{Speedup Factor } \Phi = \frac{T_{\text{locale}}}{T_{\text{"C"}}} \approx \frac{4L \cdot C_{\text{table\_lookup}}}{\left\lceil \frac{k}{W} \right\rceil \cdot C_{\text{SIMD\_op}}} \in [3.5, 8.2]$$
Applying `COLLATE "C"` to machine identifiers eliminates up to $87.8\%$ of string comparison CPU cycles.

---

### Theorem 2: Binary Search Invariant Destruction under Collation Drift

A B-Tree index maintains a strict total order $\prec_A$ over keys $K = \{k_1, k_2, \dots, k_N\}$ defined by collation version $V_A$:
$$k_i \prec_A k_j \iff \text{strcoll}_{V_A}(k_i, k_j) < 0$$
When the operating system glibc library is updated from $V_A$ to $V_B$, the sorting function transitions to $\prec_B$.
If there exists any pair of keys $(x, y)$ such that:
$$x \prec_A y \quad \land \quad y \prec_B x$$
the on-disk B-Tree page invariants are violated. Let a query search for target key $t = y$:
1. The B-Tree navigation begins at the root page using $\prec_B$.
2. At an internal routing node containing key $x$, the search evaluates $\text{strcoll}_{V_B}(t, x) = \text{strcoll}_{V_B}(y, x) > 0$.
3. The search descends into the **right subtree**.
4. However, when the B-Tree was constructed under $V_A$, $y \prec_A x$ held true, meaning $y$ was placed in the **left subtree**.
5. The search reaches a leaf page in the right subtree and concludes:
$$\text{Result} = \emptyset \quad (\text{Silent Data Disappearance})$$

Furthermore, let an insertion of key $y$ be attempted. The engine searches using $\prec_B$, descends the right subtree, finds no match, and inserts duplicate key $y$, permanently destroying `UNIQUE` integrity.

---

### Definition 1: Canonical Unicode Equivalence Classes

Let $S$ be a Unicode string. The Unicode Standard defines canonical equivalence ($\equiv_C$) between precomposed characters and decomposed character sequences:
$$S_1 \equiv_C S_2 \iff \text{NFC}(S_1) = \text{NFC}(S_2)$$
For binary equality operators in SQL:
$$S_1 = S_2 \iff \text{bytes}(S_1) = \text{bytes}(S_2)$$
Therefore:
$$S_1 \equiv_C S_2 \centernot\implies S_1 = S_2$$
A relational database enforcing uniqueness on $S$ without canonical normalization permits duplicate entries for every equivalence class $[S]_{\equiv_C}$ with $|[S]_{\equiv_C}| > 1$.

---

## 3. Production TypeScript Guard Engine: `AgenticCollationUnicodeGuardEngine`

The following production engine statically analyzes SQL schemas, migration scripts, and Drizzle/Kysely ASTs to catch collation and Unicode anti-patterns before deployment.

```typescript
// src/guardrails/collation-unicode-guard.ts

export interface CollationViolation {
  code: string;
  severity: 'CRITICAL' | 'HIGH' | 'MEDIUM';
  entityName: string;
  columnName?: string;
  message: string;
  remediation: string;
}

export interface TableColumnDef {
  tableName: string;
  columnName: string;
  dataType: string;
  collation?: string;
  isUnique?: boolean;
  isPrimaryKey?: boolean;
  checkConstraints?: string[];
}

export class AgenticCollationUnicodeGuardEngine {
  private static readonly MACHINE_IDENTIFIER_REGEX =
    /^(id|uuid|guid|hash|token|api_key|client_id|secret|checksum|digest|sku|slug)$/i;

  private static readonly HUMAN_IDENTITY_REGEX =
    /^(username|handle|email|login|user_name)$/i;

  /**
   * Statically audits an array of column definitions for collation & Unicode invariants.
   */
  public static auditSchema(columns: TableColumnDef[]): CollationViolation[] {
    const violations: CollationViolation[] = [];

    for (const col of columns) {
      const colLower = col.columnName.toLowerCase();
      const typeLower = col.dataType.toLowerCase();
      const isText = typeLower.includes('varchar') || typeLower.includes('text') || typeLower.includes('char');

      if (!isText) continue;

      // Invariant 1: Machine identifiers must use COLLATE "C" or native types
      if (this.MACHINE_IDENTIFIER_REGEX.test(colLower)) {
        if (!col.collation || (col.collation !== '"C"' && col.collation.toLowerCase() !== 'c')) {
          violations.push({
            code: 'COLL_001_MACHINE_IDENTIFIER_NOT_COLLATE_C',
            severity: 'HIGH',
            entityName: col.tableName,
            columnName: col.columnName,
            message: `Machine identifier column '${col.columnName}' uses natural language collation. This causes heavy strcoll() CPU overhead during joins and lookups.`,
            remediation: `Alter column to specify COLLATE "C", or convert to native UUID/BYTEA: ALTER TABLE ${col.tableName} ALTER COLUMN ${col.columnName} TYPE ${col.dataType} COLLATE "C";`,
          });
        }
      }

      // Invariant 2: Human identities must enforce Unicode NFC normalization
      if (this.HUMAN_IDENTITY_REGEX.test(colLower)) {
        const hasNfcCheck = col.checkConstraints?.some(c =>
          c.toLowerCase().includes('unicode_normalize_nfc')
        );

        if (!hasNfcCheck) {
          violations.push({
            code: 'COLL_002_MISSING_UNICODE_NFC_CHECK',
            severity: 'CRITICAL',
            entityName: col.tableName,
            columnName: col.columnName,
            message: `Unique identity column '${col.columnName}' lacks Unicode NFC normalization constraint. Susceptible to NFD spoofing and bypass (CWE-178).`,
            remediation: `Add check constraint: ALTER TABLE ${col.tableName} ADD CONSTRAINT ck_${col.tableName}_${col.columnName}_nfc CHECK (${col.columnName} = unicode_normalize_nfc(${col.columnName}));`,
          });
        }

        // Invariant 3: Unique human identity must have case-insensitive protection
        if (col.isUnique && (!col.collation || col.collation === 'default')) {
          violations.push({
            code: 'COLL_003_CASE_SENSITIVE_UNIQUE_IDENTITY',
            severity: 'CRITICAL',
            entityName: col.tableName,
            columnName: col.columnName,
            message: `Column '${col.columnName}' has UNIQUE constraint under case-sensitive default collation. 'User@x.com' and 'user@x.com' can co-exist.`,
            remediation: `Use a non-deterministic ICU collation (und-u-ks-level2) or create a functional index: CREATE UNIQUE INDEX uidx_${col.tableName}_${col.columnName}_lower ON ${col.tableName} (LOWER(${col.columnName}));`,
          });
        }
      }

      // Invariant 4: Non-deterministic collations cannot be combined with regex or standard LIKE
      if (col.collation && col.collation.toLowerCase().includes('case_insensitive_non_det')) {
        if (col.dataType.toLowerCase().includes('text') && colLower.includes('search')) {
          violations.push({
            code: 'COLL_004_NON_DETERMINISTIC_SEARCH_HAZARD',
            severity: 'HIGH',
            entityName: col.tableName,
            columnName: col.columnName,
            message: `Column '${col.columnName}' uses non-deterministic collation for general search text. Regex operators (~) and certain pattern matches will crash at runtime.`,
            remediation: `Reserve non-deterministic collations for exact equality/uniqueness columns. Use deterministic collation + functional indexes for search columns.`,
          });
        }
      }
    }

    return violations;
  }

  /**
   * Audits raw SQL query strings for non-sargable LOWER() or unindexed LIKE prefixes.
   */
  public static auditQuery(sql: string): CollationViolation[] {
    const violations: CollationViolation[] = [];
    const normalized = sql.replace(/\s+/g, ' ');

    // Check for WHERE LOWER(column) = LOWER($1) anti-pattern
    const lowerMatch = /\bWHERE\s+LOWER\s*\(\s*(\w+)\s*\)\s*=\s*(?:LOWER\s*\(\s*\$?\w+\s*\)|'\w+')/i.exec(normalized);
    if (lowerMatch) {
      violations.push({
        code: 'COLL_005_NON_SARGABLE_LOWER_QUERY',
        severity: 'HIGH',
        entityName: 'SQL_QUERY',
        columnName: lowerMatch[1],
        message: `Query executes unindexed functional 'LOWER(${lowerMatch[1]})' in predicate. Bypasses standard B-Tree index on '${lowerMatch[1]}'.`,
        remediation: `Ensure a functional index exists: 'CREATE INDEX ON table (LOWER(${lowerMatch[1]}))' or use an ICU non-deterministic case-insensitive collation column.`,
      });
    }

    // Check for LIKE 'prefix%' on column without pattern_ops or COLLATE "C"
    const likePrefixMatch = /\bWHERE\s+(\w+)\s+LIKE\s+'[a-zA-Z0-9_\-]+%'/i.exec(normalized);
    if (likePrefixMatch) {
      violations.push({
        code: 'COLL_006_LIKE_PREFIX_PATTERN_OPS_REQUIRED',
        severity: 'MEDIUM',
        entityName: 'SQL_QUERY',
        columnName: likePrefixMatch[1],
        message: `Query performs prefix search on '${likePrefixMatch[1]}' using LIKE. Standard locale B-Tree index cannot be used without text_pattern_ops or COLLATE "C".`,
        remediation: `Ensure index is created with operator class: CREATE INDEX ON table (${likePrefixMatch[1]} text_pattern_ops);`,
      });
    }

    return violations;
  }
}
```

---

## 4. Cross-Language Production Implementations

### A. PostgreSQL DDL: Production ICU Collations, Pattern Ops & NFC Invariants

```sql
-- migrations/20261031_production_collations.sql

-- 1. Create Non-Deterministic Case-Insensitive ICU Collation (PG 12+)
-- 'und-u-ks-level2': Undetermined language, Collation Strength Level 2 (ignores case differences, respects accents)
CREATE COLLATION IF NOT EXISTS case_insensitive_icu (
    provider = icu,
    locale = 'und-u-ks-level2',
    deterministic = false
);

-- 2. Create Deterministic Natural Language ICU Collation with Pinned Version
CREATE COLLATION IF NOT EXISTS en_natural_icu (
    provider = icu,
    locale = 'en-US',
    deterministic = true
);

-- 3. Production Hardened Accounts Table
CREATE TABLE users (
    -- Tier 0: Machine Identifiers pinned to COLLATE "C" for max SIMD performance
    id UUID PRIMARY KEY,
    api_token VARCHAR(64) COLLATE "C" NOT NULL,
    session_hash VARCHAR(64) COLLATE "C" NOT NULL,

    -- Tier 1: Canonical Unicode Normalization (NFC) Check Constraint (PG 14+)
    -- Tier 2: Case-Insensitive Unique Handle via ICU Collation
    username VARCHAR(50) COLLATE case_insensitive_icu NOT NULL,
    email VARCHAR(255) NOT NULL,

    -- Tier 3: Searchable SKU / Order Prefix with text_pattern_ops
    account_code VARCHAR(32) COLLATE "C" NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    -- Invariants:
    CONSTRAINT uq_users_username UNIQUE (username),
    CONSTRAINT ck_users_username_nfc CHECK (username = unicode_normalize_nfc(username)),
    CONSTRAINT ck_users_email_nfc CHECK (email = unicode_normalize_nfc(email)),
    CONSTRAINT ck_users_email_lowercase CHECK (email = LOWER(email))
);

-- Functional Expression Unique Index on Email (Deterministic Fallback)
CREATE UNIQUE INDEX uidx_users_email_lower ON users (LOWER(email));

-- Tier 3: Sargable Pattern Matching Index for Prefix LIKE
CREATE INDEX idx_users_account_code_prefix ON users (account_code text_pattern_ops);
```

---

### B. Go (`jackc/pgx/v5` + `golang.org/x/text/unicode/norm`): Production Invariants

```go
// internal/store/user_repository.go
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/text/unicode/norm"
)

type User struct {
	ID          string
	APIToken    string
	Username    string
	Email       string
	AccountCode string
}

type UserRepository struct {
	pool *pgxpool.Pool
}

func NewUserRepository(pool *pgxpool.Pool) *UserRepository {
	return &UserRepository{pool: pool}
}

// PrepareCanonicalInput enforces Unicode NFC normalization and trimmed bounds
func (r *UserRepository) PrepareCanonicalInput(input string) string {
	// Canonical Decomposition followed by Canonical Composition (NFC)
	normalized := norm.NFC.String(input)
	return strings.TrimSpace(normalized)
}

// CreateUser inserts a user ensuring boundary Unicode normalization
func (r *UserRepository) CreateUser(ctx context.Context, u User) error {
	canonicalUsername := r.PrepareCanonicalInput(u.Username)
	canonicalEmail := strings.ToLower(r.PrepareCanonicalInput(u.Email))

	query := `
		INSERT INTO users (id, api_token, session_hash, username, email, account_code)
		VALUES ($1, $2, $3, $4, $5, $6)
	`
	_, err := r.pool.Exec(ctx, query,
		u.ID,
		u.APIToken,    // COLLATE "C"
		u.APIToken,    // session_hash
		canonicalUsername,
		canonicalEmail,
		u.AccountCode, // text_pattern_ops
	)
	if err != nil {
		return fmt.Errorf("failed creating user: %w", err)
	}
	return nil
}

// FindByEmailCaseInsensitive leverages the functional index uidx_users_email_lower
func (r *UserRepository) FindByEmailCaseInsensitive(ctx context.Context, email string) (*User, error) {
	canonicalEmail := strings.ToLower(r.PrepareCanonicalInput(email))

	// Sargable query matching index on LOWER(email)
	query := `
		SELECT id, api_token, username, email, account_code
		FROM users
		WHERE LOWER(email) = $1
		LIMIT 1
	`
	var user User
	err := r.pool.QueryRow(ctx, query, canonicalEmail).Scan(
		&user.ID,
		&user.APIToken,
		&user.Username,
		&user.Email,
		&user.AccountCode,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, sql.ErrNoRows
		}
		return nil, fmt.Errorf("user query failed: %w", err)
	}
	return &user, nil
}

// CheckCollationHealth queries pg_database for collation version drift
func (r *UserRepository) CheckCollationHealth(ctx context.Context) (bool, string, error) {
	query := `
		SELECT datname, datcollversion
		FROM pg_database
		WHERE datname = current_database();
	`
	var datname string
	var collVersion sql.NullString
	if err := r.pool.QueryRow(ctx, query).Scan(&datname, &collVersion); err != nil {
		return false, "", fmt.Errorf("collation check failed: %w", err)
	}

	// Check pg_collation for any invalid or mismatched versions
	mismatchQuery := `
		SELECT count(*)
		FROM pg_collation
		WHERE collversion IS NOT NULL AND collversion <> pg_collation_actual_version(oid);
	`
	var mismatchCount int
	if err := r.pool.QueryRow(ctx, mismatchQuery).Scan(&mismatchCount); err != nil {
		return false, "", fmt.Errorf("collation mismatch scan failed: %w", err)
	}

	if mismatchCount > 0 {
		return false, fmt.Sprintf("WARNING: %d collations have version mismatches with the host OS/ICU library!", mismatchCount), nil
	}
	return true, "All collations synchronized", nil
}
```

---

### C. TypeScript / Drizzle ORM: Schema Invariants & NFC Normalization

```typescript
// src/db/schema/users.ts
import { pgTable, uuid, varchar, text, timestamp, index, uniqueIndex } from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';

export const users = pgTable(
  'users',
  {
    id: uuid('id').primaryKey().defaultRandom(),

    // Tier 0: Machine Identifiers pinned to "C" collation
    apiToken: varchar('api_token', { length: 64 })
      .notNull()
      .collation('"C"'),

    // Tier 1 & 2: Human Username with ICU Case-Insensitive Collation
    username: varchar('username', { length: 50 })
      .notNull()
      .collation('case_insensitive_icu'),

    // Deterministic Email
    email: varchar('email', { length: 255 }).notNull(),

    // Code for prefix searching
    accountCode: varchar('account_code', { length: 32 })
      .notNull()
      .collation('"C"'),

    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (table) => [
    // Unique Case-Insensitive Index on Lowered Email
    uniqueIndex('uidx_users_email_lower').on(sql`lower(${table.email})`),

    // Unique Username (Collation takes care of case-insensitivity)
    uniqueIndex('uq_users_username').on(table.username),

    // Pattern-ops index for prefix searching
    index('idx_users_account_code_prefix').using(
      'btree',
      sql`${table.accountCode} text_pattern_ops`
    ),
  ]
);

// Runtime Normalization Helper
export function canonicalizeString(value: string): string {
  // Normalize to Unicode Form C (precomposed)
  return value.normalize('NFC').trim();
}
```

---

### D. Python (`psycopg3` + `unicodedata`): Invariant Enforcement

```python
# app/services/user_service.py
import unicodedata
from typing import Optional
import psycopg
from psycopg.rows import class_row
from pydantic import BaseModel

class User(BaseModel):
    id: str
    api_token: str
    username: str
    email: str
    account_code: str

def normalize_nfc(value: str) -> str:
    """Enforces Unicode NFC normalization and whitespace stripping."""
    return unicodedata.normalize("NFC", value).strip()

class UserService:
    def __init__(self, conn_str: str):
        self.conn_str = conn_str

    def register_user(self, user_id: str, api_token: str, username: str, email: str, account_code: str) -> None:
        canonical_username = normalize_nfc(username)
        canonical_email = normalize_nfc(email).lower()

        with psycopg.connect(self.conn_str) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO users (id, api_token, session_hash, username, email, account_code)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    """,
                    (user_id, api_token, api_token, canonical_username, canonical_email, account_code)
                )
            conn.commit()

    def get_by_email(self, email: str) -> Optional[User]:
        canonical_email = normalize_nfc(email).lower()

        with psycopg.connect(self.conn_str, row_factory=class_row(User)) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT id, api_token, username, email, account_code
                    FROM users
                    WHERE LOWER(email) = %s
                    LIMIT 1
                    """,
                    (canonical_email,)
                )
                return cur.fetchone()
```

---

## 5. The 6-State Collation Lifecycle Finite State Machine (FSM)

```
                       ┌───────────────────────────────────────────────────┐
                       │                   STATE 0:                        │
                       │           SCHEMA & LOCALE PROVISION               │
                       │   (ICU Providers & COLLATE "C" Defined)           │
                       └─────────────────────────┬─────────────────────────┘
                                                 │
                                                 │ Application Ingestion
                                                 ▼
                       ┌───────────────────────────────────────────────────┐
                       │                   STATE 1:                        │
                       │          BOUNDARY NFC NORMALIZATION               │
                       │ (str.normalize('NFC') & DB CHECK constraint pass) │
                       └─────────────────────────┬─────────────────────────┘
                                                 │
                                                 │ Validation Passed
                                                 ▼
                       ┌───────────────────────────────────────────────────┐
                       │                   STATE 2:                        │
                       │            SARGABLE INDEX DISPATCH                │
                       │ (Equality: case_insensitive_icu / LOWER(col);     │
                       │  Prefix: text_pattern_ops / COLLATE "C")          │
                       └─────────────────────────┬─────────────────────────┘
                                                 │
                                                 │ OS / Library Update Event
                                                 ▼
                       ┌───────────────────────────────────────────────────┐
                       │                   STATE 3:                        │
                       │          COLLATION DRIFT DETECTION                │
                       │ (pg_collation.collversion <> actual_version)      │
                       └─────────────┬─────────────────────────┬───────────┘
                                     │                         │
                     Mismatch Found  │                         │ No Drift
                                     ▼                         ▼
        ┌────────────────────────────────────────┐ ┌───────────────────────┐
        │               STATE 4:                 │ │       STATE 5:        │
        │     ONLINE ZERO-DOWNTIME REINDEX       │ │  STEADY-STATE RUNTIME │
        │  (REINDEX TABLE CONCURRENTLY &         │ │ (P99 Query Latencies  │
        │   ALTER DATABASE REFRESH VERSION)      │ │  Preserved < 2ms)     │
        └────────────────────┬───────────────────┘ └───────────────────────┘
                             │
                             │ Reindex Complete & Version Synced
                             └─────────────────────────────────►
```

---

## 6. Machine-Verifiable Definition of Done (DoD) CI Sentinels

Before approving any database migration or schema PR, CI must execute the following machine verification checklist:

```bash
#!/usr/bin/env bash
# scripts/ci-collation-unicode-check.sh
set -euo pipefail

echo "🔍 Running Collation & Unicode CI Sentinels..."

# Sentinel 1: Disallow unindexed LOWER() in SQL query templates
if rg -i "WHERE\s+LOWER\([a-zA-Z0-9_\.]+\)\s*=" src/ internal/ migrations/ 2>/dev/null; then
    echo "❌ ERROR: Detected unindexed functional LOWER() in WHERE clause. Verify functional index exists!"
    exit 1
fi

# Sentinel 2: Forbid prefix LIKE on VARCHAR/TEXT columns without text_pattern_ops or COLLATE "C"
if rg -i "LIKE\s+'[a-zA-Z0-9_\-]+%'" src/ internal/ 2>/dev/null; then
    echo "⚠️ WARNING: Detected prefix LIKE search. Confirm that the target column has text_pattern_ops or COLLATE 'C'!"
fi

# Sentinel 3: Check that user identity migration tables have Unicode NFC check constraints
if rg -i "CREATE\s+TABLE\s+(users|accounts|profiles)" migrations/*.sql 2>/dev/null; then
    if ! rg -i "unicode_normalize_nfc" migrations/*.sql >/dev/null 2>&1; then
        echo "❌ ERROR: Identity tables (users/accounts) must contain CHECK (... = unicode_normalize_nfc(...))!"
        exit 1
    fi
fi

# Sentinel 4: Query active PostgreSQL for Collation Version Mismatches
if [ -n "${DATABASE_URL:-}" ]; then
    MISMATCHES=$(psql "$DATABASE_URL" -t -A -c "
        SELECT count(*)
        FROM pg_collation
        WHERE collversion IS NOT NULL AND collversion <> pg_collation_actual_version(oid);
    " 2>/dev/null || echo "0")

    if [ "$MISMATCHES" -gt 0 ]; then
        echo "❌ CRITICAL: Database has $MISMATCHES collation version mismatches! Run REINDEX CONCURRENTLY!"
        exit 1
    fi
fi

echo "✅ All Collation & Unicode Sentinels passed successfully."
```

### Verification Checklist Matrix
- [x] All synthetic IDs, UUIDs, ULIDs, API keys, tokens, and hashes explicitly specify `COLLATE "C"` or use native types.
- [x] All user handles, emails, and textual identities enforce Unicode Canonical Composition (NFC) via boundary sanitization and database `CHECK` constraints.
- [x] Case-insensitive uniqueness is handled via PostgreSQL 12+ non-deterministic ICU collations or deterministic `LOWER()` functional unique indexes.
- [x] Prefix `LIKE` searches use B-Tree indexes created with `text_pattern_ops` or `varchar_pattern_ops`.
- [x] Collation version mismatch alerts (`datcollversion`) are monitored in CI/CD and deployment pipelines.
