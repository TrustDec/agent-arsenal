---
description: PostgreSQL, MySQL, and SQLite keyset pagination, cursor-based seek method, multi-column row-value / tuple comparisons, deferred joins (late lookups), page drift elimination, non-deterministic tie-breaker defense, opaque HMAC cursor tokens, and O(N) offset scraping elimination across Go (pgx/sqlc), TypeScript (Drizzle, Prisma, Kysely), Python (SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{query,index,schema,repo,repository,store,migration,entity,cursor,pagination}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Keyset Pagination, Seek Method, Row-Value Comparisons, Deferred Joins & Cursor Drift Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design paginated APIs, infinite-scroll mobile feeds, message batching queues, data synchronization pipelines, or high-throughput ETL scrapers across PostgreSQL (12+), MySQL (8.0+), SQLite (3.38+), Go (`jackc/pgx/v5`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`SQLAlchemy 2.0`, `asyncpg`), or Rust (`sqlx`). Eliminate the "Offset Linear Scan Cliff" (where `OFFSET 500000 LIMIT 20` forces the database engine to traverse, parse MVCC visibility headers, and discard 500,000 tuples, evicting the entire active working set from `shared_buffers` and causing query latencies to skyrocket from 2ms to 18 seconds), the "Concurrent Mutation Page-Drift Hazard" (where inserts or deletions on earlier pages shift row offsets down or up, silently dropping critical records or duplicating already-processed events in data sync workers), the "Non-Deterministic Tie-Breaker Omission Disaster" (where sorting by non-unique columns like `ORDER BY created_at DESC` returns arbitrary physical disk page ordering across identical timestamps, causing erratic pagination jitter and flaky test assertions), the "Multi-Column Row-Value Index Mismatch Trap" (where tuple comparisons like `(created_at, id) < ($1, $2)` fail to utilize B-Tree composite indexes when column ASC/DESC sort directions diverge or NULL semantics are unhandled), the "Wide-Row Early Join Amplification Trap" (where joining wide dimension tables before applying pagination bounds forces the engine to materialize and join hundreds of thousands of rows in `work_mem` before discarding them, rather than executing a compact Deferred Join / Late Lookup seek), and the "Opaque Cursor Token Tampering Vulnerability" (where exposing raw database primary keys or timestamps in client URLs leaks sequence increments and invites enumeration attacks, requiring base64url HMAC-signed tokens) by establishing a strict 5-Tier Keyset Pagination Governance Ladder, asymptotic complexity proofs, production TypeScript guard engines, and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Keyset & Pagination Catastrophes vs The 5-Tier Governance Ladder

Modern web frameworks, ORMs, and AI coding agents default to `OFFSET` and `LIMIT` pagination because standard documentation presents it as the simplest syntactic construct. However, in production relational databases under sustained OLTP write loads and multi-million-row tables, `OFFSET` pagination causes severe performance degradation, cache eviction, and data corruption.

Autonomous coding agents frequently generate naive pagination queries without understanding database access physics, leading to severe production failures:

### The 6 Keyset & Pagination Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE O(N) OFFSET SCRAPING SCAN OF DEATH
-- Table 'audit_logs' has 100,000,000 rows.
-- Agent implements page 25,000 for an admin dashboard or sync worker:
SELECT id, tenant_id, action, payload, created_at
FROM audit_logs
WHERE tenant_id = 'tenant_enterprise_42'
ORDER BY created_at DESC
LIMIT 20 OFFSET 500000;

-- ❌ Catastrophe:
-- PostgreSQL must traverse the B-Tree index or sequential heap to scan and evaluate
-- MVCC tuple visibility for ALL 500,000 rows before discarding them and returning 20.
-- shared_buffers reads balloon to 150,000 pages (1.2 GB of disk I/O).
-- Latency degrades from 1.5ms on page 1 to 14,800ms on page 25,000!
-- Concurrent queries stall as buffer pool pages are evicted to service the offset scan.
```

```sql
-- ✅ PRODUCTION INVARIANT 1: THE KEYSET SEEK METHOD (O(1) RELATIVE LATENCY)
-- Query directly seeks the exact starting boundary using the B-Tree index:
SELECT id, tenant_id, action, payload, created_at
FROM audit_logs
WHERE tenant_id = 'tenant_enterprise_42'
  AND (created_at, id) < ('2026-10-31 08:00:00.123456+00', '0192df25-9c80-7b22-83b4-f3a1c2d3e4f5')
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- ✅ Production Benefits:
-- 1. PostgreSQL performs an index seek directly to the boundary tuple (log_B M traversals ~ 3-4 pages).
-- 2. Scans exactly 20 index tuples and fetches exactly 20 heap blocks.
-- 3. Execution time is strictly O(K) where K = LIMIT size: 0.8ms regardless of table size (100 rows or 100M rows).
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE CONCURRENT MUTATION PAGE-DRIFT HAZARD
-- Sync worker paginates tasks using OFFSET:
-- Worker reads Page 1 (Offset 0, Limit 10): tasks #1 to #10.
-- While processing Page 1, a new urgent task #0 is inserted with created_at = NOW().
-- Worker requests Page 2 (Offset 10, Limit 10):
-- Database offsets 10 rows: [Task #0, #1, #2, ... #9] are skipped.
-- Task #10 was row 10 on Page 1, but is now row 11 on Page 2!
-- The worker processes Task #10 a SECOND TIME (duplicate execution).
-- If a row on Page 1 was deleted instead, a row moves from Page 2 to Page 1,
-- and is NEVER SEEN BY THE WORKER (silent data omission outage).
```

```sql
-- ✅ PRODUCTION INVARIANT 2: IMMUTABLE ANCHOR POINT
-- Keyset cursor anchors strictly to the last observed tuple's identity:
-- Inserting Task #0 at the top does NOT shift the boundary:
-- (created_at, id) < (task10.created_at, task10.id)
-- Evaluates solely against rows strictly older than Task #10.
-- Zero duplicates, zero skipped records, fully idempotent stream consumption.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: NON-DETERMINISTIC TIE-BREAKER OMISSION
-- Agent sorts by non-unique timestamp:
SELECT id, status, updated_at
FROM payment_orders
WHERE tenant_id = $1
ORDER BY updated_at DESC
LIMIT 50;

-- ❌ Catastrophe:
-- When batch updates occur, 500 rows share identical 'updated_at' timestamps.
-- Relational theory states order among identical keys is UNDEFINED.
-- PostgreSQL returns rows in physical heap block order (CTID).
-- When Autovacuum or concurrent updates reorder heap tuples, subsequent cursor fetches
-- oscillate unpredictably: items bounce between pages, duplicate, or vanish completely!
```

```sql
-- ✅ PRODUCTION INVARIANT 3: STRICT UNIQUE COMPOSITE TIE-BREAKER & NULL PLACEMENT
-- Always append a unique immutable column (Primary Key 'id') to the sort order:
SELECT id, status, updated_at
FROM payment_orders
WHERE tenant_id = $1
  AND (updated_at, id) < ($2, $3)
ORDER BY updated_at DESC NULLS LAST, id DESC
LIMIT 50;
-- Guarantees total ordering across all rows; zero ambiguity in B-Tree traversal.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: MULTI-COLUMN ROW-VALUE COMPARISON INDEX MISMATCH
-- Table has composite index: (tenant_id, priority ASC, created_at DESC, id ASC)
-- Agent naively attempts tuple comparison with mixed sort directions:
SELECT id, priority, created_at
FROM tickets
WHERE tenant_id = $1
  AND (priority, created_at, id) < ($2, $3, $4)
ORDER BY priority ASC, created_at DESC, id ASC
LIMIT 25;

-- ❌ Catastrophe:
-- In SQL standard and PostgreSQL, row-value comparison (a, b, c) < (x, y, z)
-- assumes ALL columns are ordered in the SAME direction!
-- When 'priority' is ASC and 'created_at' is DESC, '<' creates logical chaos:
-- It evaluates (priority < $2) OR (priority = $2 AND created_at < $3)...
-- which INVERTS the descending condition on created_at!
-- The query planner abandons the composite B-Tree index scan and falls back to a Seq Scan!
```

```sql
-- ✅ PRODUCTION INVARIANT 4: NORMALIZED EXPANDED ROW PREDICATES FOR MIXED SORTS
-- For mixed ASC/DESC ordering, expand into explicit disjoint boolean clauses:
SELECT id, priority, created_at
FROM tickets
WHERE tenant_id = $1
  AND (
    (priority > $2)
    OR (priority = $2 AND created_at < $3)
    OR (priority = $2 AND created_at = $3 AND id > $4)
  )
ORDER BY priority ASC, created_at DESC, id ASC
LIMIT 25;
-- Matches composite B-Tree index: (tenant_id, priority ASC, created_at DESC, id ASC) perfectly!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: WIDE-ROW EARLY JOIN AMPLIFICATION TRAP
-- Orders table is joined with customers, addresses, order_items, payments:
SELECT 
    o.id, o.order_number, o.total_amount,
    c.name, c.email,
    a.street, a.city, a.postal_code,
    p.transaction_id, p.card_last4
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN addresses a ON a.id = o.shipping_address_id
LEFT JOIN payments p ON p.order_id = o.id
WHERE o.tenant_id = 'tenant_123'
ORDER BY o.created_at DESC, o.id DESC
LIMIT 20 OFFSET 100000;

-- ❌ Catastrophe:
-- PostgreSQL executes joins for 100,020 rows, allocating hundreds of megabytes in work_mem,
-- constructing large intermediate tuple rows containing text, email, and address strings,
-- only to discard 100,000 joined tuples!
```

```sql
-- ✅ PRODUCTION INVARIANT 5: DEFERRED JOIN (LATE ROW LOOKUP PATTERN)
-- Step 1: Seek only lightweight primary keys via compact index-only scan
-- Step 2: Join the wide tables ONLY on the final 20 matched keys
WITH target_keys AS (
    SELECT id
    FROM orders
    WHERE tenant_id = 'tenant_123'
      AND (created_at, id) < ($1, $2)
    ORDER BY created_at DESC, id DESC
    LIMIT 20
)
SELECT 
    o.id, o.order_number, o.total_amount,
    c.name, c.email,
    a.street, a.city, a.postal_code,
    p.transaction_id, p.card_last4
FROM target_keys k
JOIN orders o ON o.id = k.id
JOIN customers c ON c.id = o.customer_id
JOIN addresses a ON a.id = o.shipping_address_id
LEFT JOIN payments p ON p.order_id = o.id
ORDER BY o.created_at DESC, o.id DESC;

-- ✅ Production Benefits:
-- Index-only seek handles the boundary with minimal I/O.
-- Complex multi-table joins are executed for EXACTLY 20 rows.
-- Latency drops by 98.5%; memory allocation drops from 85 MB to 32 KB.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: RAW CURSOR EXPOSURE & IDOR ENUMERATION
-- API exposes raw internal values in URLs:
-- GET /api/v1/orders?after_id=1048576&after_time=1700000000
-- 1. Attacker learns sequential integer primary key generation rates (business metric leak).
-- 2. Attacker tampers with after_id to probe boundary conditions or bypass tenancy filters.
-- 3. Internal database schema types leak into external API contracts.
```

```sql
-- ✅ PRODUCTION INVARIANT 6: BASE64URL HMAC-SHA256 SIGNED OPAQUE CURSORS
-- GET /api/v1/orders?cursor=eyJjIjoiMjAyNi0xMC0zMVQwODowMDowMFoiLCJpZCI6IjAxOTJkZjI1In0.k9s8D_x4F...
-- 1. Cursor is an opaque token containing serialized boundary values.
-- 2. Signed with server-side secret using HMAC-SHA256: any client tampering is rejected with 400 Bad Request.
-- 3. Prevents parameter manipulation, enumeration attacks, and maintains implementation encapsulation.
```

---

## 2. Mathematical Foundations & Formal Optimization Physics

To understand why keyset pagination is fundamentally superior to offset pagination, we analyze disk page access physics, B-Tree search bounds, buffer pool eviction dynamics, and page-drift probability under continuous write traffic.

### 2.1 Asymptotic Complexity: Linear Scan vs B-Tree Point Seek

Let $M$ be the total number of rows in the table. Let $N$ be the requested offset (e.g. $N = 100,000$), and $K$ be the page size (e.g. $K = 20$). Let $B$ be the B-Tree fan-out factor ($B \approx 200$ to $500$ for standard 8KB pages).

#### Offset Pagination Asymptotic Cost:
$$\mathcal{C}_{\text{offset}}(N, K) = O(N + K)$$
The database must visit every row in the sequence from $1$ to $N + K$. Even with an index on the sort column, the engine must perform $N + K$ index tuple inspections and MVCC transaction status checks.

#### Keyset Pagination Asymptotic Cost:
$$\mathcal{C}_{\text{keyset}}(K) = O(\log_B M + K)$$
The B-Tree search descends from root to leaf in height $h = \lceil \log_B M \rceil$ steps (typically $h \le 4$ even for hundreds of millions of rows), followed by a sequential scan of exactly $K$ contiguous leaf slots.

$$\lim_{N \to \infty} \frac{\mathcal{C}_{\text{offset}}(N, K)}{\mathcal{C}_{\text{keyset}}(K)} = \frac{N + K}{\log_B M + K} \approx \frac{N}{K} \gg 10^4$$

When $N = 500,000$ and $K = 20$, Keyset pagination is over **25,000 times more efficient** in tuple evaluation count.

---

### 2.2 Buffer Pool Eviction Calculus

When an offset query evaluates $N$ rows, it must read the corresponding pages into the database buffer cache (`shared_buffers` in PostgreSQL or `innodb_buffer_pool` in MySQL).

Let $S_{\text{row}}$ be the average row size in bytes, and $P_{\text{page}}$ be the database block size ($8192\text{ bytes}$). The number of heap pages read by an offset query without index-only scan is:
$$B_{\text{offset}} = \min\left( \text{TotalPages}, \lceil \frac{(N + K) \cdot S_{\text{row}}}{P_{\text{page}}} \rceil \right)$$

For $N = 100,000$ and average row size $S_{\text{row}} = 512\text{ bytes}$:
$$B_{\text{offset}} = \frac{100,020 \cdot 512}{8192} \approx 6,251\text{ pages } (50.0\text{ MB})$$

Under sustained concurrent offset scraping (e.g. 10 workers scraping 50 concurrent streams), the database churns through gigabytes of buffer cache per second. By contrast, Keyset pagination reads:
$$B_{\text{keyset}} = h + \lceil \frac{K \cdot S_{\text{row}}}{P_{\text{page}}} \rceil \approx 3 + \lceil \frac{20 \cdot 512}{8192} \rceil = 5\text{ pages } (40\text{ KB})$$

The buffer pool read amplification ratio is:
$$\mathcal{A}_{\text{buffer}} = \frac{B_{\text{offset}}}{B_{\text{keyset}}} = \frac{6,251}{5} \approx 1,250\times$$

---

### 2.3 Page-Drift Divergence Probability Model

Consider an ingestion stream with write arrival rate $\lambda$ (writes per second) distributed according to a Poisson process. Let $\Delta t$ be the elapsed time between a client requesting Page $p$ and Page $p+1$.

The number of mutations occurring before the cursor boundary follows Poisson distribution $X \sim \text{Poisson}(\lambda \cdot \Delta t)$.

The probability of experiencing **Page Drift** (duplicate items or skipped items) in Offset pagination is:
$$P(\text{Drift}_{\text{offset}}) = P(X > 0) = 1 - e^{-\lambda \cdot \Delta t}$$

If $\lambda = 10\text{ inserts/sec}$ and a user spends $\Delta t = 3\text{ seconds}$ viewing a page:
$$P(\text{Drift}_{\text{offset}}) = 1 - e^{-30} \approx 0.99999999999995\text{ (100\% certainty of data glitch)}$$

Under Keyset pagination anchored by $(V_{\text{last}}, \text{ID}_{\text{last}})$:
$$P(\text{Drift}_{\text{keyset}}) \equiv 0$$
Because the boundary is determined by value coordinates rather than array rank, newly inserted tuples with $V > V_{\text{last}}$ are strictly excluded from the next page, eliminating all drift.

---

### 2.4 Deferred Join (Late Lookup) Bandwidth Conservation Model

When querying wide entities with joined tables, let $S_{\text{index}}$ be the size of the compact indexing tuple (e.g., UUID + Timestamp = $24\text{ bytes}$) and $S_{\text{wide}}$ be the wide joined row footprint (e.g., $2048\text{ bytes}$).

In an early-join query across offset $N$:
$$\text{Memory}_{\text{early}} = (N + K) \cdot S_{\text{wide}}$$
In a deferred join keyset query:
$$\text{Memory}_{\text{deferred}} = (\log_B M + K) \cdot S_{\text{index}} + K \cdot S_{\text{wide}}$$

For $N = 50,000$, $K = 20$:
$$\text{Memory}_{\text{early}} = 50,020 \cdot 2048\text{ B} \approx 102.4\text{ MB}$$
$$\text{Memory}_{\text{deferred}} = (4 + 20) \cdot 24\text{ B} + 20 \cdot 2048\text{ B} = 576\text{ B} + 40,960\text{ B} \approx 41.5\text{ KB}$$

$$\text{Memory Reduction Factor } \mathcal{R}_{\text{mem}} = \frac{102.4\text{ MB}}{41.5\text{ KB}} \approx 2,467\times$$

---

## 3. The 5-Tier Keyset Pagination Governance Ladder

To eliminate pagination outages across all production systems, autonomous agents and engineers must enforce the **5-Tier Keyset Pagination Governance Ladder**:

```
┌────────────────────────────────────────────────────────────────────────┐
│             THE 5-TIER KEYSET PAGINATION GOVERNANCE LADDER             │
├──────┬─────────────────────────────────────────────────────────────────┤
│Tier 0│ Strict OFFSET Elimination & Mandatory Keyset Seek Invariant     │
│      │ Disallow OFFSET > 0 in high-throughput and multi-tenant queries │
├──────┼─────────────────────────────────────────────────────────────────┤
│Tier 1│ Deterministic Unique Tie-Breaker & Explicit NULL Ordering       │
│      │ Append primary key 'id' to ORDER BY; enforce NULLS LAST / FIRST  │
├──────┼─────────────────────────────────────────────────────────────────┤
│Tier 2│ Leftmost Composite Index Alignment & Directional Symmetry       │
│      │ Index matches (tenant_id, sort_col DESC, id DESC) exactly       │
├──────┼─────────────────────────────────────────────────────────────────┤
│Tier 3│ Deferred Joins (Late Lookup) for Wide Tables & Deep Feeds        │
│      │ Seek IDs via compact index first, then join wide payload tables │
├──────┼─────────────────────────────────────────────────────────────────┤
│Tier 4│ Opaque, Tamper-Evident HMAC-SHA256 Signed Base64URL Cursors     │
│      │ Seal cursor payload; prevent parameter tampering & IDOR leaks   │
└──────┴─────────────────────────────────────────────────────────────────┘
```

### Tier 0: Strict OFFSET Elimination Invariant
- **Rule**: `OFFSET` must NEVER appear in API endpoints, ETL sync pipelines, or queue consumer loops where table row count exceeds 5,000 rows.
- **Enforcement**: CI linter blocks SQL queries with `OFFSET` without an explicit bypass comment `-- bypass-offset-ok: admin-single-user`.

### Tier 1: Deterministic Unique Tie-Breaker & Explicit NULL Ordering
- **Rule**: Every `ORDER BY` clause in a paginated query MUST end with a strictly unique, immutable column (such as `id`).
- **NULL Safety**: If the primary sort column is nullable, specify `NULLS LAST` (for DESC) or `NULLS FIRST` (for ASC) explicitly in both the SQL query and the supporting composite index.

### Tier 2: Leftmost Composite Index Alignment
- **Rule**: The supporting B-Tree index MUST cover all equality predicates, followed by the primary sort column, followed by the tie-breaker column:
  `CREATE INDEX idx_tbl_tenant_sort_id ON table_name (tenant_id, sort_col DESC, id DESC);`
- **Directional Consistency**: All columns in multi-column tuple comparisons `(a, b) < ($1, $2)` must share identical sort direction in the index, or use expanded disjoint clauses.

### Tier 3: Deferred Joins (Late Lookup) Architecture
- **Rule**: When paginating queries with 2 or more table joins or row payloads $> 512\text{ bytes}$, execute pagination as a two-phase CTE:
  1. Phase 1: Seek only `id` using an index-only scan with `LIMIT K`.
  2. Phase 2: Inner-join the parent table and all satellite dimension tables on `target_ids.id`.

### Tier 4: Opaque HMAC-SHA256 Signed Cursors
- **Rule**: Never transmit raw database IDs, timestamps, or sequential offsets in client-facing API responses.
- **Cursor Envelope**: Encode `{ values: [last_sort_val, last_id], dir: "next" }` as URL-safe Base64 with an HMAC-SHA256 signature to guarantee cryptographic integrity.

---

## 4. Universal Production Code Standards

Below are hardened, battle-tested implementations of Keyset pagination across modern production stacks.

### 4.1 PostgreSQL Raw SQL & Index Schema

```sql
-- DDL: Ensure B-Tree composite index precisely aligns with sort order and tenancy
CREATE TABLE IF NOT EXISTS customer_invoices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id VARCHAR(64) NOT NULL,
    customer_id UUID NOT NULL,
    amount_cents BIGINT NOT NULL,
    status VARCHAR(32) NOT NULL,
    issue_date TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- Leftmost Prefix Composite Index:
-- tenant_id (Equality) -> issue_date DESC (Sort) -> id DESC (Unique Tie-Breaker)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_invoices_tenant_date_id
ON customer_invoices (tenant_id, issue_date DESC, id DESC);

-- PRODUCTION QUERY 1: Standard Single-Table Keyset Seek
-- Fetch first page: pass $2 = NULL, $3 = NULL
-- Fetch next page: pass $2 = last_issue_date, $3 = last_id
SELECT 
    id, tenant_id, customer_id, amount_cents, status, issue_date, created_at
FROM customer_invoices
WHERE tenant_id = :tenant_id
  AND (
    (:cursor_issue_date::timestamptz IS NULL AND :cursor_id::uuid IS NULL)
    OR (issue_date, id) < (:cursor_issue_date, :cursor_id)
  )
ORDER BY issue_date DESC, id DESC
LIMIT 20;

-- PRODUCTION QUERY 2: Deferred Join (Late Lookup) for Multi-Table Joins
WITH page_keys AS (
    SELECT id
    FROM customer_invoices
    WHERE tenant_id = :tenant_id
      AND (
        (:cursor_issue_date::timestamptz IS NULL AND :cursor_id::uuid IS NULL)
        OR (issue_date, id) < (:cursor_issue_date, :cursor_id)
      )
    ORDER BY issue_date DESC, id DESC
    LIMIT 20
)
SELECT 
    i.id, i.amount_cents, i.status, i.issue_date,
    c.name AS customer_name, c.email AS customer_email
FROM page_keys pk
JOIN customer_invoices i ON i.id = pk.id
JOIN customers c ON c.id = i.customer_id
ORDER BY i.issue_date DESC, i.id DESC;
```

---

### 4.2 Go (`jackc/pgx/v5`): Secure HMAC Cursor Keyset Service

```go
package pagination

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type InvoiceRow struct {
	ID          string    `json:"id"`
	TenantID    string    `json:"tenant_id"`
	AmountCents int64     `json:"amount_cents"`
	Status      string    `json:"status"`
	IssueDate   time.Time `json:"issue_date"`
}

type CursorPayload struct {
	IssueDate time.Time `json:"d"`
	ID        string    `json:"i"`
}

type KeysetPage struct {
	Items      []InvoiceRow `json:"items"`
	NextCursor *string      `json:"next_cursor"`
	HasMore    bool         `json:"has_more"`
}

type KeysetService struct {
	pool      *pgxpool.Pool
	hmacKey   []byte
	limitSize int
}

func NewKeysetService(pool *pgxpool.Pool, secretKey string, limitSize int) *KeysetService {
	if limitSize <= 0 || limitSize > 100 {
		limitSize = 25
	}
	return &KeysetService{
		pool:      pool,
		hmacKey:   []byte(secretKey),
		limitSize: limitSize,
	}
}

// EncodeCursor signs and serializes the boundary values into a URL-safe Base64 token.
func (s *KeysetService) EncodeCursor(issueDate time.Time, id string) string {
	payload := CursorPayload{IssueDate: issueDate.UTC(), ID: id}
	bytes, _ := json.Marshal(payload)
	payloadB64 := base64.RawURLEncoding.EncodeToString(bytes)

	mac := hmac.New(sha256.New, s.hmacKey)
	mac.Write([]byte(payloadB64))
	sigB64 := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))

	return fmt.Sprintf("%s.%s", payloadB64, sigB64)
}

// DecodeCursor validates the HMAC signature and unmarshals the cursor payload.
func (s *KeysetService) DecodeCursor(cursorStr string) (*CursorPayload, error) {
	if cursorStr == "" {
		return nil, nil
	}
	var payloadB64, sigB64 string
	_, err := fmt.Sscanf(cursorStr, "%s.%s", &payloadB64, &sigB64)
	if err != nil {
		return nil, errors.New("malformed cursor format")
	}

	expectedMac := hmac.New(sha256.New, s.hmacKey)
	expectedMac.Write([]byte(payloadB64))
	expectedSig := expectedMac.Sum(nil)

	actualSig, err := base64.RawURLEncoding.DecodeString(sigB64)
	if err != nil || !hmac.Equal(expectedSig, actualSig) {
		return nil, errors.New("invalid or tampered cursor signature")
	}

	payloadBytes, err := base64.RawURLEncoding.DecodeString(payloadB64)
	if err != nil {
		return nil, errors.New("invalid cursor payload encoding")
	}

	var payload CursorPayload
	if err := json.Unmarshal(payloadBytes, &payload); err != nil {
		return nil, errors.New("corrupted cursor json")
	}
	return &payload, nil
}

// FetchInvoicesPage executes a deterministic keyset seek query.
// Over-fetches by 1 (limit + 1) to determine has_more without expensive COUNT(*).
func (s *KeysetService) FetchInvoicesPage(ctx context.Context, tenantID string, cursorStr string) (*KeysetPage, error) {
	cursor, err := s.DecodeCursor(cursorStr)
	if err != nil {
		return nil, fmt.Errorf("cursor verification: %w", err)
	}

	fetchLimit := s.limitSize + 1
	var rows pgx.Rows

	if cursor == nil {
		// First page seek
		query := `
			SELECT id, tenant_id, amount_cents, status, issue_date
			FROM customer_invoices
			WHERE tenant_id = $1
			ORDER BY issue_date DESC, id DESC
			LIMIT $2;
		`
		rows, err = s.pool.Query(ctx, query, tenantID, fetchLimit)
	} else {
		// Subsequent keyset seek
		query := `
			SELECT id, tenant_id, amount_cents, status, issue_date
			FROM customer_invoices
			WHERE tenant_id = $1
			  AND (issue_date, id) < ($2, $3)
			ORDER BY issue_date DESC, id DESC
			LIMIT $4;
		`
		rows, err = s.pool.Query(ctx, query, tenantID, cursor.IssueDate, cursor.ID, fetchLimit)
	}
	if err != nil {
		return nil, fmt.Errorf("query execution: %w", err)
	}
	defer rows.Close()

	var items []InvoiceRow
	for rows.Next() {
		var item InvoiceRow
		if err := rows.Scan(&item.ID, &item.TenantID, &item.AmountCents, &item.Status, &item.IssueDate); err != nil {
			return nil, fmt.Errorf("scan invoice row: %w", err)
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate rows: %w", err)
	}

	hasMore := len(items) > s.limitSize
	if hasMore {
		items = items[:s.limitSize]
	}

	var nextCursor *string
	if hasMore && len(items) > 0 {
		lastItem := items[len(items)-1]
		token := s.EncodeCursor(lastItem.IssueDate, lastItem.ID)
		nextCursor = &token
	}

	return &KeysetPage{
		Items:      items,
		NextCursor: nextCursor,
		HasMore:    hasMore,
	}, nil
}
```

---

### 4.3 TypeScript (`Drizzle ORM` + `Kysely`): Type-Safe Keyset Seek Helper

```typescript
import { sql, type Expression, type SqlBool } from 'kysely';
import { createHmac, timingSafeEqual } from 'node:crypto';

export interface KeysetCursor<T> {
  values: T[];
  signature: string;
}

export class KeysetCursorCodec {
  constructor(private readonly secret: string) {}

  public encode(values: (string | number | Date)[]): string {
    const raw = JSON.stringify(values.map(v => v instanceof Date ? v.toISOString() : v));
    const payload = Buffer.from(raw, 'utf8').toString('base64url');
    const hmac = createHmac('sha256', this.secret).update(payload).digest('base64url');
    return `${payload}.${hmac}`;
  }

  public decode<T extends (string | number)[]>(token: string): T | null {
    if (!token) return null;
    const parts = token.split('.');
    if (parts.length !== 2) throw new Error('Invalid cursor format');

    const [payload, sig] = parts;
    const expectedSig = createHmac('sha256', this.secret).update(payload).digest('base64url');
    
    const sigBuf = Buffer.from(sig, 'utf8');
    const expBuf = Buffer.from(expectedSig, 'utf8');

    if (sigBuf.length !== expBuf.length || !timingSafeEqual(sigBuf, expBuf)) {
      throw new Error('Tampered or corrupted cursor signature');
    }

    const json = Buffer.from(payload, 'base64url').toString('utf8');
    return JSON.parse(json) as T;
  }
}

/**
 * Builds a composite row-value comparison SQL expression for Kysely:
 * (col1, col2) < (val1, val2)
 */
export function buildTupleSeek(
  cols: [string, string],
  vals: [any, any],
  direction: 'ASC' | 'DESC' = 'DESC'
): Expression<SqlBool> {
  const operator = direction === 'DESC' ? sql`<` : sql`>`;
  return sql`(${sql.ref(cols[0])}, ${sql.ref(cols[1])}) ${operator} (${vals[0]}, ${vals[1]})`;
}
```

---

### 4.4 Python (`SQLAlchemy 2.0` + `asyncpg`): Keyset Paginator with Deferred Joins

```python
import base64
import hmac
import hashlib
import json
from datetime import datetime, timezone
from typing import Optional, List, Tuple, Any
from pydantic import BaseModel
from sqlalchemy import select, tuple_, desc, asc
from sqlalchemy.ext.asyncio import AsyncSession
from myapp.models import Order, Customer, ShippingAddress

class PageResult(BaseModel):
    items: List[Any]
    next_cursor: Optional[str]
    has_more: bool

class SecureKeysetPaginator:
    def __init__(self, secret_key: str, page_size: int = 20):
        self.secret_key = secret_key.encode('utf-8')
        self.page_size = min(max(1, page_size), 100)

    def encode_cursor(self, sort_val: Any, pk_val: str) -> str:
        if isinstance(sort_val, datetime):
            sort_val = sort_val.astimezone(timezone.utc).isoformat()
        payload_bytes = json.dumps([sort_val, pk_val]).encode('utf-8')
        payload_b64 = base64.urlsafe_b64encode(payload_bytes).decode('utf-8').rstrip('=')
        
        signature = hmac.new(self.secret_key, payload_b64.encode('utf-8'), hashlib.sha256).digest()
        sig_b64 = base64.urlsafe_b64encode(signature).decode('utf-8').rstrip('=')
        return f"{payload_b64}.{sig_b64}"

    def decode_cursor(self, cursor: Optional[str]) -> Optional[Tuple[Any, str]]:
        if not cursor:
            return None
        parts = cursor.split('.')
        if len(parts) != 2:
            raise ValueError("Malformed cursor structure")
        
        payload_b64, sig_b64 = parts
        expected_sig = hmac.new(self.secret_key, payload_b64.encode('utf-8'), hashlib.sha256).digest()
        expected_b64 = base64.urlsafe_b64encode(expected_sig).decode('utf-8').rstrip('=')
        
        if not hmac.compare_digest(sig_b64, expected_b64):
            raise ValueError("Tampered cursor token")
            
        padding = '=' * (-len(payload_b64) % 4)
        raw_json = base64.urlsafe_b64decode(payload_b64 + padding).decode('utf-8')
        data = json.loads(raw_json)
        return tuple(data)

    async def paginate_orders_deferred_join(
        self,
        session: AsyncSession,
        tenant_id: str,
        cursor_token: Optional[str] = None
    ) -> PageResult:
        decoded = self.decode_cursor(cursor_token)
        fetch_limit = self.page_size + 1

        # Phase 1: Seek Primary Keys via Compact Index-Only Scan
        pk_subquery = (
            select(Order.id, Order.created_at)
            .where(Order.tenant_id == tenant_id)
            .order_by(desc(Order.created_at), desc(Order.id))
            .limit(fetch_limit)
        )

        if decoded:
            last_created_at, last_id = decoded
            pk_subquery = pk_subquery.where(
                tuple_(Order.created_at, Order.id) < (last_created_at, last_id)
            )

        pk_cte = pk_subquery.cte('target_pks')

        # Phase 2: Deferred Join on Target Keys
        full_query = (
            select(Order, Customer.name, ShippingAddress.city)
            .join(pk_cte, Order.id == pk_cte.c.id)
            .join(Customer, Customer.id == Order.customer_id)
            .join(ShippingAddress, ShippingAddress.id == Order.shipping_address_id)
            .order_by(desc(Order.created_at), desc(Order.id))
        )

        result = await session.execute(full_query)
        rows = result.all()

        has_more = len(rows) > self.page_size
        if has_more:
            rows = rows[:self.page_size]

        next_cursor = None
        if has_more and rows:
            last_order = rows[-1][0]
            next_cursor = self.encode_cursor(last_order.created_at, str(last_order.id))

        return PageResult(
            items=[{"order": r[0], "customer": r[1], "city": r[2]} for r in rows],
            next_cursor=next_cursor,
            has_more=has_more
        )
```

---

## 5. Production TypeScript Keyset Guard Engine

Autonomous agents must validate that pagination queries strictly comply with keyset invariants, possess supporting composite indexes, and avoid naive offset scans. Below is the production-grade static analysis and runtime verification engine:

```typescript
/**
 * AgenticKeysetPaginationOptimizerEngine
 * Audits SQL queries, ORM expressions, and execution plans for Keyset Pagination invariants.
 */

export interface KeysetAuditReport {
  isCompliant: boolean;
  hasOffsetCatastrophe: boolean;
  hasDeterministicTieBreaker: boolean;
  hasTupleComparison: boolean;
  hasDeferredJoinPattern: boolean;
  detectedOffsetValue?: number;
  identifiedSortColumns: string[];
  findings: string[];
  recommendations: string[];
}

export class AgenticKeysetPaginationOptimizerEngine {
  /**
   * Audits raw SQL query string for pagination antipatterns.
   */
  public auditSqlQuery(sql: string): KeysetAuditReport {
    const normalized = sql.replace(/\s+/g, ' ').trim();
    const findings: string[] = [];
    const recommendations: string[] = [];

    // 1. Detect Offset Catastrophe
    const offsetMatch = normalized.match(/\bOFFSET\s+(\d+)\b/i);
    const hasOffsetCatastrophe = !!offsetMatch;
    let detectedOffsetValue: number | undefined;

    if (offsetMatch) {
      detectedOffsetValue = parseInt(offsetMatch[1], 10);
      if (detectedOffsetValue > 0) {
        findings.push(
          `CATASTROPHIC_OFFSET_USAGE: Query uses 'OFFSET ${detectedOffsetValue}'. ` +
          `Forces database to scan and discard ${detectedOffsetValue} rows, evicting cache buffers.`
        );
        recommendations.push(
          'Eliminate OFFSET entirely. Refactor to keyset seek: WHERE (sort_col, id) < (:cursor_val, :cursor_id).'
        );
      }
    }

    // 2. Inspect ORDER BY Determinism
    const orderByMatch = normalized.match(/\bORDER\s+BY\s+([^;]+?)(?:\bLIMIT\b|\bOFFSET\b|$)/i);
    let hasDeterministicTieBreaker = false;
    const identifiedSortColumns: string[] = [];

    if (orderByMatch) {
      const clause = orderByMatch[1].trim();
      const tokens = clause.split(',').map(t => t.trim().toLowerCase());
      tokens.forEach(t => identifiedSortColumns.push(t));

      // Check if primary key or unique id is in the terminal sort position
      hasDeterministicTieBreaker = tokens.some(t => /\b(id|_id|uuid|pk)\b/.test(t));
      if (!hasDeterministicTieBreaker) {
        findings.push(
          'NON_DETERMINISTIC_SORT: ORDER BY clause lacks unique tie-breaker (e.g. id). ' +
          'Concurrent updates or duplicate values will cause erratic pagination jitter and duplicate/skipped rows.'
        );
        recommendations.push('Append unique primary key (e.g. id DESC) to the terminal position of ORDER BY.');
      }
    } else {
      findings.push('MISSING_ORDER_BY: Paginated query has no explicit ORDER BY clause. Row order is completely undefined.');
      recommendations.push('Add deterministic ORDER BY with primary key tie-breaker.');
    }

    // 3. Inspect Tuple Comparison / Keyset Seek Condition
    const hasTupleComparison = /\(\s*[\w.]+\s*,\s*[\w.]+\s*\)\s*[<>]\s*\(/i.test(normalized);
    const hasExpandedDisjoint = /\bOR\b.*\bAND\b/i.test(normalized) && /([<>]=?)/.test(normalized);

    if (!hasTupleComparison && !hasExpandedDisjoint && !hasOffsetCatastrophe) {
      // Check if simple single-column seek exists (e.g. WHERE id > $1)
      const hasSimpleSeek = /\bWHERE\b.*\b(id|_id|created_at)\s*[<>]\s*/i.test(normalized);
      if (!hasSimpleSeek) {
        findings.push('MISSING_KEYSET_SEEK: Query lacks keyset seek predicate ((col, id) < ($1, $2)).');
        recommendations.push('Implement tuple comparison keyset predicate.');
      }
    }

    // 4. Inspect Deferred Join Pattern for Multi-Join Queries
    const joinCount = (normalized.match(/\bJOIN\b/gi) || []).length;
    const hasDeferredJoinPattern = /\bWITH\b.*\bLIMIT\b.*\bJOIN\b/i.test(normalized);

    if (joinCount >= 2 && !hasDeferredJoinPattern) {
      findings.push(
        `EARLY_JOIN_AMPLIFICATION: Query performs ${joinCount} joins before applying pagination bounds. ` +
        `Materializes wide tuples for discarded rows.`
      );
      recommendations.push(
        'Implement Deferred Join (Late Lookup): Seek target IDs in a CTE with LIMIT, then join wide dimension tables on matched IDs.'
      );
    }

    const isCompliant = findings.length === 0;

    return {
      isCompliant,
      hasOffsetCatastrophe,
      hasDeterministicTieBreaker,
      hasTupleComparison: hasTupleComparison || hasExpandedDisjoint,
      hasDeferredJoinPattern,
      detectedOffsetValue,
      identifiedSortColumns,
      findings,
      recommendations,
    };
  }

  /**
   * Verifies PostgreSQL EXPLAIN (ANALYZE, BUFFERS) plan output.
   */
  public auditExplainPlan(planJson: any): { isIndexSeek: boolean; sharedHitBlocks: number; diskReadBlocks: number } {
    let isIndexSeek = false;
    let sharedHitBlocks = 0;
    let diskReadBlocks = 0;

    const traverse = (node: any) => {
      if (!node) return;
      const nodeType = node['Node Type'] || '';
      if (nodeType.includes('Index Scan') || nodeType.includes('Index Only Scan')) {
        isIndexSeek = true;
      }
      sharedHitBlocks += node['Shared Hit Blocks'] || 0;
      diskReadBlocks += node['Shared Read Blocks'] || 0;

      if (node.Plans) {
        node.Plans.forEach(traverse);
      }
    };

    traverse(planJson[0]?.Plan);
    return { isIndexSeek, sharedHitBlocks, diskReadBlocks };
  }
}
```

---

## 6. Finite-State Machine: Keyset Pagination Lifecycle & Query Execution FSM

Every keyset pagination request must transition strictly through the 6-state lifecycle FSM, preventing bypass of HMAC validation, index seek verification, or over-fetch boundary detection:

```
┌───────────────────────┐
│     STATE 0: INIT     │◄── Client Request with Optional Opaque Cursor
└──────────┬────────────┘
           │ Verify HMAC-SHA256 signature & unmarshal boundary
           ▼
┌───────────────────────┐
│ STATE 1: CURSOR_PARSED│
└──────────┬────────────┘
           │ Match composite B-Tree index (tenant_id, sort_col, id)
           ▼
┌───────────────────────┐
│STATE 2: INDEX_VERIFIED│
└──────────┬────────────┘
           │ Check join count; hoist to Deferred Join CTE if joins >= 2
           ▼
┌───────────────────────┐
│STATE 3: PLAN_OPTIMIZED│
└──────────┬────────────┘
           │ Execute seek with LIMIT K + 1 (over-fetch single tuple)
           ▼
┌───────────────────────┐
│STATE 4: STREAM_SEEKED │
└──────────┬────────────┘
           │ Truncate over-fetch tuple; compute has_more; sign next cursor
           ▼
┌───────────────────────┐
│STATE 5: TOKEN_EMITTED │──► Return JSON { items: K, next_cursor, has_more }
└───────────────────────┘
```

### State Transition Invariants
1. **INIT $\to$ CURSOR_PARSED**: If a cursor string is provided, it MUST undergo constant-time HMAC-SHA256 verification. If the signature is invalid, immediately abort with HTTP 400 Bad Request; NEVER attempt fallback to unverified parameters.
2. **CURSOR_PARSED $\to$ INDEX_VERIFIED**: Ensure the leftmost prefix of a composite B-Tree index strictly covers all equality filters and mirrors the exact ASC/DESC order of the seek tuple.
3. **INDEX_VERIFIED $\to$ PLAN_OPTIMIZED**: If the query touches $\ge 2$ joined tables or projected width $> 512\text{B}$, rewrite to the Deferred Join CTE pattern.
4. **PLAN_OPTIMIZED $\to$ STREAM_SEEKED**: Query parameter `LIMIT` is set to $K + 1$. Database evaluates only $K + 1$ index leaf tuples.
5. **STREAM_SEEKED $\to$ TOKEN_EMITTED**: If rows returned $= K + 1$, set `has_more = true`, pop the $(K+1)$-th row, extract the $K$-th row's sort values, compute the HMAC-SHA256 signature, and emit `next_cursor`. If rows $\le K$, emit `has_more = false` and `next_cursor = null`.

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

Autonomous agents must pass all 6 gates before marking any pagination, infinite-scroll, or batch-processing task complete:

| Gate | Verification Target | Test Method | Pass Criterion |
|---|---|---|---|
| **Gate 1** | **Zero OFFSET Usage** | Static AST / Regex scan on all repository SQL | `grep -i "OFFSET" == 0` (or annotated with explicit exemption) |
| **Gate 2** | **Unique Tie-Breaker** | AST inspection of all `ORDER BY` clauses | Terminal column is strictly `id` or unique PK |
| **Gate 3** | **Index Alignment** | `pg_indexes` / `EXPLAIN (BUFFERS)` inspection | Plan uses `Index Scan` or `Index Only Scan`; zero `Seq Scan` |
| **Gate 4** | **Buffer I/O Bounding** | Buffer read audit at Page 10,000 equivalent | `Shared Read Blocks + Shared Hit Blocks <= 15` per query |
| **Gate 5** | **Deferred Join on Wide Tables** | Schema inspection of multi-join endpoints | Queries with $\ge 2$ joins use 2-phase ID-seek CTE |
| **Gate 6** | **HMAC Cursor Integrity** | Automated unit test with tampered cursor byte | Request returns HTTP 400 Bad Request; zero unhandled panics |
