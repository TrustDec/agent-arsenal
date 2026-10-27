---
description: Database indexing discipline, B-tree traversal physics, query plan stability, N+1 query eradication via DataLoader/batching, keyset cursor pagination, covering/partial indexes, and parameter sniffing defense across Go (pgx/sqlc/GORM), TypeScript (Drizzle/Prisma/Kysely/TypeORM), Python (SQLAlchemy), Rust (sqlx/SeaORM), PostgreSQL, MySQL, Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{query,index,repository,repo,database,db,dao,service,model,schema,migration}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/lib/db/**/*.{ts,js,go,rs,py},**/internal/repository/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Indexing, Query Plan Drift & N+1 Query Elimination Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to write database schemas, SQL queries, ORM/query builder repositories (Go `jackc/pgx`, `sqlc`, `GORM`; TypeScript `Drizzle`, `Prisma`, `Kysely`, `TypeORM`; Python `SQLAlchemy`, `Tortoise`; Rust `sqlx`, `SeaORM`), or pagination and search endpoints. Eliminate the "Catastrophic N+1 Loop & Connection Exhaustion Avalanche" (where queries nested inside application loops multiply roundtrips and lock connection pools), the "Sequential Table Scan & Missing Foreign Key / Composite Index Disaster" (where unindexed foreign keys or misordered multi-column filters force $O(N)$ full table scans across millions of rows), the "Implicit Type Coercion & Expression Index Invalidation Trap" (where functions or mismatched types in `WHERE` clauses silently bypass B-tree indexes), the "Offset Pagination Cliff & I/O Discard Catastrophe" (where `OFFSET 500000 LIMIT 20` forces the database to parse, sort, and discard half a million tuples), the "Query Planner Parameter Sniffing & Generic Plan Drift Trap" (where prepared statements flip from Index Scans to catastrophic Nested Loop Seq Scans due to skewed data distributions), and the "Cartesian Product Multi-JOIN Memory Blast & Index Write Amplification" (where joining multiple 1-to-N relationships explodes memory or over-indexing destroys write throughput and defeats PostgreSQL HOT updates) by establishing a strict 5-Tier Database Query & Indexing Governance Ladder, B-tree traversal physics, deterministic keyset cursor pagination, DataLoader request coalescing, covering index design, and `EXPLAIN (ANALYZE, BUFFERS)` CI verification.

---

## 1. Architectural Taxonomy: The 6 Query & Indexing Catastrophes vs The 5-Tier Governance Ladder

When autonomous coding agents generate database access layers, LLMs frequently write naive query patterns that pass unit tests on empty or 10-row databases, but catastrophically collapse when deployed to production tables with millions of records:

```typescript
// ❌ CATASTROPHIC LLM QUERY PATTERNS (N+1, Unindexed Filters, Offset Cliff, Expression Invalidation)
async function getRecentOrdersWithItems(customerId: string, page: number, pageSize: number) {
  // VULN 1: Offset pagination cliff! OFFSET 100000 scans and discards 100,000 rows.
  // VULN 2: Expression index invalidation! LOWER(status) disables standard index on status.
  const orders = await db.query(
    `SELECT * FROM orders 
     WHERE customer_id = $1 AND LOWER(status) = 'completed' 
     ORDER BY created_at DESC 
     LIMIT $2 OFFSET $3`,
    [customerId, pageSize, (page - 1) * pageSize]
  );

  // VULN 3: Catastrophic N+1 query loop! 1 query becomes 1 + N queries over network!
  for (const order of orders) {
    // VULN 4: Unindexed foreign key order_id in order_items triggers full table scan per iteration!
    order.items = await db.query(
      `SELECT * FROM order_items WHERE order_id = $1`,
      [order.id]
    );
  }
  return orders;
}
```

In high-concurrency microservices, high-traffic SaaS backends, or agentic multi-step tool calls, these patterns trigger six critical database catastrophes:

- **The "Catastrophic N+1 Loop & Connection Exhaustion Avalanche"**:
  - A developer or agent fetches a parent collection of $N$ rows (`SELECT * FROM orders`), then iterates over the results executing a secondary query for each parent row (`SELECT * FROM order_items WHERE order_id = ?`).
  - For $N = 500$, the application initiates 501 distinct database roundtrips. At a modest network RTT of 2ms, the query takes $>1,000\text{ms}$ of pure network transit time, monopolizing a pooled database connection throughout.
  - When 50 concurrent requests hit this endpoint simultaneously, $50 \times 500 = 25,000$ queries flood the database. The connection pool is instantly saturated, worker threads block, CPU spikes to 100%, and incoming requests fail with connection acquisition timeouts.
  - Invariant: Iterative database execution inside application-level loops is STRICTLY PROHIBITED in production code. All 1-to-N relationships MUST be fetched via batch lookups (`WHERE id = ANY($1)` or `IN (...)`), DataLoader coalescing, or single-statement `JOIN LATERAL` aggregations.

- **The "Sequential Table Scan & Missing Foreign Key / Composite Index Disaster"**:
  - Unlike primary keys, relational databases (PostgreSQL, MySQL, SQLite) DO NOT automatically create indexes on foreign key columns (`customer_id`, `tenant_id`, `order_id`).
  - When an agent filters by `customer_id` or executes a cascading `DELETE / UPDATE`, the database planner is forced to execute an $O(N)$ Sequential Scan over the entire table, loading millions of disk blocks into memory.
  - Furthermore, when queries filter by multiple columns (`WHERE tenant_id = ? AND status = ? ORDER BY created_at DESC`), agents frequently create isolated single-column indexes on each field. The engine must either scan one index and filter the rest in memory or perform an expensive Bitmap Index Scan and merge, degrading latency by orders of magnitude compared to an optimal composite index.
  - Invariant: Every foreign key MUST have an explicit B-tree index. Composite indexes MUST strictly follow the Leftmost Prefix Rule ($\text{Equality} \to \text{Range} \to \text{Sort}$).

- **The "Implicit Type Coercion & Expression Index Invalidation Trap"**:
  - Standard B-tree indexes store the raw, unmodified values of columns. When an agent wraps a column in a function (`WHERE LOWER(email) = ?`, `WHERE DATE(created_at) = CURRENT_DATE`, `WHERE jsonb_col->>'user_id' = ?`), the database CANNOT utilize the B-tree index on that column.
  - Similarly, passing a numeric value to a string column (`WHERE phone_number = 13800000000` where `phone_number` is `VARCHAR`) triggers implicit `CAST(phone_number AS bigint)`, silently disabling the index and causing a full table scan.
  - Invariant: Predicate columns in `WHERE` and `JOIN` clauses MUST match the exact column type without wrapping functions, or must be backed by an explicit functional/expression index (e.g., `CREATE INDEX ON users (LOWER(email))`).

- **The "Offset Pagination Cliff & I/O Discard Catastrophe"**:
  - Naive pagination generated by LLMs invariably relies on `LIMIT n OFFSET m`. In relational algebra, `OFFSET m` does not jump directly to row $m$; the engine must parse, seek, and sort $m + n$ tuples from disk and shared buffers, only to discard the first $m$ rows.
  - For page 1 (`OFFSET 0`), latency is 1ms. For page 5,000 (`OFFSET 100000`), the database scans and discards 100,020 tuples, pushing latency to several seconds, saturating IOPS, and evicting hot pages from PostgreSQL `shared_buffers` or MySQL InnoDB Buffer Pool.
  - Invariant: Deep pagination on tables exceeding 10,000 rows MUST utilize deterministic Keyset Cursor Pagination (`WHERE (created_at, id) < (:cursor_created_at, :cursor_id)`), ensuring $O(1)$ constant-time B-tree seeks regardless of page depth.

- **The "Query Planner Parameter Sniffing & Generic Plan Drift Trap"**:
  - When using prepared statements across Go (`pgx`), TypeScript (`pg`), or Python (`asyncpg`), the database engine initial generates custom plans for the first few executions, then switches to a cached generic plan (`plan_cache_mode = auto`).
  - If a column has heavily skewed data distribution (e.g., `status = 'archived'` matches 95% of rows, while `status = 'processing'` matches 0.05%), a generic plan optimized for sequential scan will catastrophically penalize the 0.05% selective queries, or vice-versa, causing unpredictable latency jitter and p99 spikes.
  - Invariant: Skewed status or state-machine columns MUST be addressed via partial indexes (`WHERE status = 'processing'`) or parameterized queries with plan cache awareness (`plan_cache_mode = force_custom` when necessary).

- **The "Cartesian Product Multi-JOIN Memory Blast & Index Write Amplification"**:
  - When an agent attempts to load multiple child collections in one query (`FROM orders LEFT JOIN order_items ON ... LEFT JOIN order_shipments ON ... LEFT JOIN order_notes ON ...`), the result set is the Cartesian product of all joined rows. An order with 10 items, 5 shipments, and 10 notes produces $10 \times 5 \times 10 = 500$ rows of bloated duplicated data across the wire, consuming memory and triggering OOMs in application runtimes.
  - Conversely, agents often blindly index every single column in a table, causing Index Write Amplification: every `INSERT`, `UPDATE`, or `DELETE` must synchronously update 10+ B-tree indexes, blowing up WAL generation and defeating PostgreSQL HOT (Heap-Only Tuples) optimization.
  - Invariant: Never perform multi-collection Cartesian `LEFT JOIN` in a single query; split into separate batch lookups or use JSON aggregation subqueries (`jsonb_agg`). Index count per table MUST NOT exceed 5–7 without explicit access-pattern justification.

---

### The 5-Tier Database Query & Indexing Governance Ladder

To eliminate these vulnerabilities, every query, schema, and repository generated by an autonomous agent MUST ascend the following 5-Tier Governance Ladder:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Tier 4: Query Plan Stability, EXPLAIN (BUFFERS) CI & Slow-Query Guardrails │
│  - Automated EXPLAIN (ANALYZE, BUFFERS) CI regression tests                │
│  - Shared buffer hit ratio >= 99%; Zero unindexed Seq Scans on >1,000 rows │
│  - Statement timeout boundaries & pg_stat_statements query auditing         │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 3: Covering Indexes (Index-Only Scans) & Partial Index Specialization │
│  - CREATE INDEX ... INCLUDE (...) to eliminate heap table fetches           │
│  - Partial indexes WHERE deleted_at IS NULL AND status IN (...)             │
│  - Preserving PostgreSQL HOT (Heap-Only Tuple) update optimization          │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 2: Keyset Cursor Pagination & Strict Anti-OFFSET Invariants           │
│  - Deterministic keyset cursors: WHERE (created_at, id) < (c_time, c_id)    │
│  - O(1) constant-time B-tree tuple seeks; prohibition of OFFSET > 100       │
│  - Base64URL-encoded, tamper-evident opaque cursor tokens                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 1: Anti-N+1 Batch Loading & DataLoader Request Coalescing             │
│  - Prohibit queries inside loops; enforce WHERE id = ANY($1::UUID[])        │
│  - DataLoader batching pattern: in-memory coalescing across async ticks     │
│  - Single-statement JOIN LATERAL subquery aggregations                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 0: Static Index Sentinels & Mandatory Foreign Key B-Trees              │
│  - Mandatory explicit B-tree indexes on ALL foreign key columns             │
│  - Composite index leftmost prefix ordering: (Equality -> Range -> Sort)    │
│  - Strict type alignment; zero implicit casting; functional index sentinels │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Invariants: B-Tree Traversal Physics, Keyset Cursor Seeks & N+1 Cost Models

### 2.1. B-Tree Index Search Complexity vs Full Table Scan Cost

A standard B-tree index of order $B$ indexing $N$ rows has tree height:
$$h \le \left\lceil \log_B \left( \frac{N + 1}{2} \right) \right\rceil$$

For a table with $N = 10,000,000$ rows and average node fanout $B \approx 100$, the index tree height is $h = 4$.
The disk I/O seek cost to locate the first matching tuple is strictly bounded:
$$C_{\text{index\_lookup}} = h \cdot t_{\text{random\_I/O}} + k \cdot t_{\text{sequential\_I/O}}$$
where $k$ is the number of matching tuples satisfying the predicate. When $k \ll N$, $C_{\text{index\_lookup}} \approx 4 \times 0.1\text{ms} = 0.4\text{ms}$.

In contrast, an unindexed Sequential Table Scan (Seq Scan) must read all $M$ disk blocks of the relation:
$$M = \left\lceil \frac{N \cdot S_{\text{tuple}}}{B_{\text{block\_size}}} \right\rceil$$
where $S_{\text{tuple}} = 250\text{ bytes}$ and $B_{\text{block\_size}} = 8192\text{ bytes}$ (PostgreSQL default). For $N = 10,000,000$:
$$M \approx \frac{10^7 \times 250}{8192} \approx 305,175 \text{ pages} \approx 2.44 \text{ GB}$$

At a sequential NVMe read throughput of $1.5\text{ GB/s}$, a Seq Scan consumes:
$$t_{\text{seq}} \approx \frac{2.44\text{ GB}}{1.5\text{ GB/s}} \approx 1,626\text{ ms}$$

**Theorem 1 (Index Traversal Superiority)**: For any selective predicate ($k / N < 0.05$), an index scan reduces I/O consumption and latency by a factor of:
$$\text{Speedup} \approx \frac{M \cdot t_{\text{block}}}{h \cdot t_{\text{seek}} + k \cdot t_{\text{tuple}}} \ge 100\times \text{ to } 4,000\times$$

---

### 2.2. Keyset Cursor Pagination $O(1)$ vs Offset Pagination Linear Degradation $O(N)$

Given page size $L$ and page number $P$, the offset is $O = (P - 1) \cdot L$.
Under Offset pagination, the database engine must traverse and sort all $O + L$ rows:
$$\text{Tuples\_Processed}_{\text{offset}}(P) = P \cdot L$$
The cumulative I/O cost to paginate through $K$ pages is quadratic in $K$:
$$\sum_{p=1}^K \text{Cost}(p) \propto \sum_{p=1}^K (p \cdot L) = \frac{K(K+1)}{2} \cdot L \approx O(K^2 \cdot L)$$

Under Keyset Cursor pagination, using a covering composite index on `(created_at DESC, id DESC)`:
$$\text{Query: } \text{WHERE } (\text{created\_at}, \text{id}) < (c_{\text{time}}, c_{\text{id}}) \text{ ORDER BY } \text{created\_at DESC, id DESC LIMIT } L$$
The database performs an exact B-tree point lookup to the leaf node corresponding to $(c_{\text{time}}, c_{\text{id}})$ in $h$ operations, and scans exactly $L$ adjacent leaf nodes:
$$\text{Tuples\_Processed}_{\text{keyset}} = L \quad (\text{strictly constant } O(1) \text{ independent of } P)$$

**Invariant**: Keyset pagination guarantees identical sub-millisecond execution time whether querying page 1 or page 50,000.

---

### 2.3. The N+1 Network Roundtrip & Pool Starvation Calculus

Let $N$ be the number of parent records returned by the primary query.
If child records are fetched via loop iteration:
- Application-to-Database Network RTT: $t_{\text{RTT}}$ (typically $1\text{ms} - 5\text{ms}$ in VPC, $30\text{ms} - 80\text{ms}$ cross-region/cloud).
- Query execution time: $t_{\text{exec}}$.
- Connection acquisition time: $t_{\text{acquire}}$.

Total elapsed latency for the naive N+1 loop:
$$T_{\text{total}} = (t_{\text{acquire}} + t_{\text{exec\_parent}} + t_{\text{RTT}}) + \sum_{i=1}^N (t_{\text{acquire}} + t_{\text{exec\_child}} + t_{\text{RTT}})$$
Assuming connection is pinned across the loop:
$$T_{\text{total}} = t_{\text{exec\_parent}} + N \cdot t_{\text{exec\_child}} + (N + 1) \cdot t_{\text{RTT}}$$
For $N = 200$ and $t_{\text{RTT}} = 2\text{ms}$:
$$T_{\text{total}} \ge 1 + (200 \times 0.5) + (201 \times 2) = 1 + 100 + 402 = 503\text{ms}$$

Under Batch Loading (`WHERE parent_id = ANY($1)`):
Total database roundtrips is exactly 2:
$$T_{\text{batch}} = (t_{\text{exec\_parent}} + t_{\text{RTT}}) + (t_{\text{exec\_batch\_child}} + t_{\text{RTT}}) = 1 + 2 + 1.2 + 2 = 6.2\text{ms}$$

**Theorem 2 (N+1 Elimination Throughput Gain)**: Batch coalescing reduces total elapsed latency and connection checkout duration by:
$$\Delta T = T_{\text{total}} - T_{\text{batch}} \approx N \cdot t_{\text{RTT}} \quad (\text{an } 80\times \text{ latency reduction for } N=200)$$

---

### 2.4. Composite Index Leftmost Prefix Rule & Selectivity Formula

For a composite index on columns $(C_1, C_2, C_3)$:
1. **Equality columns first**: Columns filtered with `=` or `IS NULL` must appear on the left.
2. **Range columns second**: Columns filtered with `<`, `>`, `<=`, `>=`, `BETWEEN`, or `LIKE 'abc%'` must follow equality columns.
3. **Sort columns third**: Columns used in `ORDER BY` must match the index order to eliminate an in-memory `Sort` node.

The selectivity of a composite index prefix $(C_1, \dots, C_j)$ is defined as:
$$\text{Selectivity} = \frac{|\text{Distinct}(C_1, \dots, C_j)|}{N_{\text{total}}}$$
An index is effective when $\text{Selectivity} \to 1.0$. If $C_1$ is non-selective (e.g. `is_active` boolean, selectivity $\approx 0.5$) and is placed first, the B-tree must branch through half the tree before evaluating $C_2$, violating optimization principles.

---

## 3. Production TypeScript Implementation: `AgenticQueryOptimizerEngine`

Below is the complete, zero-dependency, production-grade TypeScript implementation providing:
1. **Opaque Keyset Cursor Tokenization**: Cryptographically signed, URL-safe Base64 cursors with schema validation.
2. **In-Memory Request Batching / DataLoader Coalescing**: Microtask queue coalescing of isolated single-record requests into single batch queries.
3. **EXPLAIN (BUFFERS) Cost & Plan Verifier**: AST and plan analysis detecting unindexed Sequential Scans, missing indexes, and buffer bloat.

```typescript
import { createHmac, timingSafeEqual } from 'crypto';

// ============================================================================
// 1. Keyset Cursor Pagination Engine (O(1) Seek, Tamper-Evident)
// ============================================================================

export interface CursorPayload {
  readonly v: number;          // Cursor schema version
  readonly sortValue: string;  // Value of the primary sort column (e.g., ISO timestamp)
  readonly id: string;         // Tie-breaking unique ID
}

export interface PaginationParams {
  readonly limit: number;
  readonly cursor?: string;
  readonly direction?: 'forward' | 'backward';
}

export interface PageResult<T> {
  readonly items: readonly T[];
  readonly nextCursor: string | null;
  readonly prevCursor: string | null;
  readonly hasMore: boolean;
}

export class KeysetCursorCodec {
  private readonly secretKey: Buffer;
  private readonly version = 1;

  constructor(secretKey: string) {
    if (!secretKey || secretKey.length < 32) {
      throw new Error('KeysetCursorCodec: Secret key must be at least 32 characters');
    }
    this.secretKey = Buffer.from(secretKey, 'utf-8');
  }

  /**
   * Encodes a sort value and unique ID into an opaque, tamper-evident cursor.
   */
  public encode(sortValue: string | Date | number, id: string): string {
    const serializedSort = sortValue instanceof Date 
      ? sortValue.toISOString() 
      : String(sortValue);

    const payload: CursorPayload = {
      v: this.version,
      sortValue: serializedSort,
      id,
    };

    const jsonStr = JSON.stringify(payload);
    const bodyBase64 = Buffer.from(jsonStr, 'utf-8').toString('base64url');
    const signature = this.sign(bodyBase64);

    return `${bodyBase64}.${signature}`;
  }

  /**
   * Decodes and cryptographically verifies an opaque cursor token.
   */
  public decode(cursorToken: string): CursorPayload {
    const parts = cursorToken.split('.');
    if (parts.length !== 2) {
      throw new Error('Invalid cursor format');
    }

    const [bodyBase64, signature] = parts;
    const expectedSignature = this.sign(bodyBase64);

    const sigBuf = Buffer.from(signature, 'base64url');
    const expectedBuf = Buffer.from(expectedSignature, 'base64url');

    if (sigBuf.length !== expectedBuf.length || !timingSafeEqual(sigBuf, expectedBuf)) {
      throw new Error('Tampered or invalid cursor signature');
    }

    const jsonStr = Buffer.from(bodyBase64, 'base64url').toString('utf-8');
    const payload = JSON.parse(jsonStr) as CursorPayload;

    if (payload.v !== this.version || !payload.id || !payload.sortValue) {
      throw new Error('Malformed cursor payload');
    }

    return payload;
  }

  private sign(data: string): string {
    return createHmac('sha256', this.secretKey)
      .update(data)
      .digest('base64url');
  }
}

// ============================================================================
// 2. Anti-N+1 Batch Loader & Coalescing Engine (DataLoader Equivalent)
// ============================================================================

export type BatchLoadFn<K, V> = (keys: readonly K[]) => Promise<ReadonlyMap<K, V>>;

export class MicrotaskBatchLoader<K extends string | number, V> {
  private queue: Map<K, { resolve: (val: V) => void; reject: (err: Error) => void }[]> = new Map();
  private scheduled = false;
  private readonly batchFn: BatchLoadFn<K, V>;
  private readonly maxBatchSize: number;

  constructor(batchFn: BatchLoadFn<K, V>, maxBatchSize = 1000) {
    this.batchFn = batchFn;
    this.maxBatchSize = maxBatchSize;
  }

  /**
   * Loads a single entity by key. Coalesces concurrent calls within the same event
   * loop tick into a single batch query, completely eliminating N+1 network cascades.
   */
  public async load(key: K): Promise<V> {
    return new Promise<V>((resolve, reject) => {
      const existing = this.queue.get(key) ?? [];
      existing.push({ resolve, reject });
      this.queue.set(key, existing);

      if (!this.scheduled) {
        this.scheduled = true;
        // Schedule dispatch on the next microtask tick
        queueMicrotask(() => this.dispatchQueue());
      }
    });
  }

  /**
   * Bulk loads an array of keys, preserving order.
   */
  public async loadMany(keys: readonly K[]): Promise<V[]> {
    return Promise.all(keys.map((k) => this.load(k)));
  }

  private async dispatchQueue(): Promise<void> {
    this.scheduled = false;
    const currentQueue = this.queue;
    this.queue = new Map();

    const allKeys = Array.from(currentQueue.keys());
    if (allKeys.length === 0) return;

    // Chunk into maximum batch sizes if needed
    for (let i = 0; i < allKeys.length; i += this.maxBatchSize) {
      const chunkKeys = allKeys.slice(i, i + this.maxBatchSize);
      try {
        const resultMap = await this.batchFn(chunkKeys);

        for (const key of chunkKeys) {
          const callbacks = currentQueue.get(key) ?? [];
          const result = resultMap.get(key);

          if (result === undefined) {
            const missingErr = new Error(`BatchLoader: Record not found for key: ${String(key)}`);
            for (const cb of callbacks) cb.reject(missingErr);
          } else {
            for (const cb of callbacks) cb.resolve(result);
          }
        }
      } catch (err: any) {
        for (const key of chunkKeys) {
          const callbacks = currentQueue.get(key) ?? [];
          for (const cb of callbacks) cb.reject(err);
        }
      }
    }
  }
}

// ============================================================================
// 3. EXPLAIN (BUFFERS) Plan Validator & Anti-SeqScan Guardrail
// ============================================================================

export interface ExplainNode {
  ['Node Type']: string;
  ['Relation Name']?: string;
  ['Total Cost']: number;
  ['Actual Total Time']?: number;
  ['Actual Rows']?: number;
  ['Shared Hit Blocks']?: number;
  ['Shared Read Blocks']?: number;
  ['Filter']?: string;
  ['Plans']?: ExplainNode[];
}

export interface PlanAuditReport {
  readonly isHealthy: boolean;
  readonly violations: readonly string[];
  readonly totalCost: number;
  readonly sharedBufferHitRatio: number;
  readonly hasUnindexedSeqScan: boolean;
}

export class QueryPlanAuditor {
  private readonly maxAllowedCost: number;
  private readonly minBufferHitRatio: number;
  private readonly minRowsForSeqScanViolation: number;

  constructor(options?: {
    maxCost?: number;
    minHitRatio?: number;
    minRowsForSeqScanViolation?: number;
  }) {
    this.maxAllowedCost = options?.maxCost ?? 1000.0;
    this.minBufferHitRatio = options?.minHitRatio ?? 0.95; // 95% buffer hit target
    this.minRowsForSeqScanViolation = options?.minRowsForSeqScanViolation ?? 1000;
  }

  /**
   * Audits a raw PostgreSQL EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) output.
   */
  public audit(explainJson: any[]): PlanAuditReport {
    if (!Array.isArray(explainJson) || explainJson.length === 0 || !explainJson[0].Plan) {
      throw new Error('Invalid EXPLAIN JSON payload');
    }

    const rootPlan: ExplainNode = explainJson[0].Plan;
    const violations: string[] = [];

    let totalSharedHit = 0;
    let totalSharedRead = 0;
    let hasUnindexedSeqScan = false;

    const traverse = (node: ExplainNode) => {
      // Accumulate buffer metrics
      totalSharedHit += node['Shared Hit Blocks'] ?? 0;
      totalSharedRead += node['Shared Read Blocks'] ?? 0;

      // Check for dangerous sequential scans on large tables
      if (node['Node Type'] === 'Seq Scan') {
        const rows = node['Actual Rows'] ?? 0;
        const relName = node['Relation Name'] ?? 'unknown_relation';
        if (rows >= this.minRowsForSeqScanViolation) {
          hasUnindexedSeqScan = true;
          violations.push(
            `Unindexed Seq Scan detected on relation '${relName}' (${rows} actual rows scanned). Missing index for filter: ${node['Filter'] ?? 'None'}`
          );
        }
      }

      // Check for expensive Sort operations that should be handled by B-tree order
      if (node['Node Type'] === 'Sort' && (node['Actual Total Time'] ?? 0) > 50) {
        violations.push(
          `Expensive in-memory/disk Sort node detected (${node['Actual Total Time']}ms). Index missing sort columns!`
        );
      }

      if (node.Plans) {
        for (const child of node.Plans) {
          traverse(child);
        }
      }
    };

    traverse(rootPlan);

    const totalBlocks = totalSharedHit + totalSharedRead;
    const hitRatio = totalBlocks > 0 ? totalSharedHit / totalBlocks : 1.0;

    if (rootPlan['Total Cost'] > this.maxAllowedCost) {
      violations.push(
        `Total query cost ${rootPlan['Total Cost']} exceeds maximum allowed ceiling of ${this.maxAllowedCost}`
      );
    }

    if (hitRatio < this.minBufferHitRatio && totalBlocks > 50) {
      violations.push(
        `Shared buffer hit ratio (${(hitRatio * 100).toFixed(2)}%) is below threshold of ${(this.minBufferHitRatio * 100).toFixed(2)}%`
      );
    }

    return {
      isHealthy: violations.length === 0,
      violations,
      totalCost: rootPlan['Total Cost'],
      sharedBufferHitRatio: hitRatio,
      hasUnindexedSeqScan,
    };
  }
}
```

---

## 4. The 6-State Query Execution & Optimization Finite-State Machine (FSM)

Every database query managed by autonomous systems must execute through a deterministic, observable 6-state finite-state machine:

```
                  ┌──────────────────────┐
                  │      1. PARSED       │
                  └──────────┬───────────┘
                             │ Valid SQL AST & Parameter Types Verified
                             ▼
                  ┌──────────────────────┐
                  │  2. INDEX_VERIFIED   │
                  └──────────┬───────────┘
                             │ No Type Coercion / Foreign Key Indexes Validated
                             ▼
                  ┌──────────────────────┐
                  │  3. BATCH_COALESCED  │
                  └──────────┬───────────┘
                             │ N+1 Eradicated / In-Memory Microtask Grouped
                             ▼
                  ┌──────────────────────┐
                  │  4. PLAN_OPTIMIZED   │
                  └──────────┬───────────┘
                             │ Keyset Cursor Applied / No OFFSET > 100 / No Cartesian JOIN
                             ▼
                  ┌──────────────────────┐
                  │     5. EXECUTED      │
                  └──────────┬───────────┘
                             │ Deadline Protected (statement_timeout)
                             ▼
                  ┌──────────────────────┐
                  │     6. AUDITED       │
                  └──────────────────────┘
                    EXPLAIN Shared Buffer & p99 Telemetry Logged
```

### State Transition Invariants

1. **State 1: PARSED**:
   - The query string, parameterized values, and pagination parameters are parsed.
   - Guard: All literal parameters MUST be parameterized ($1, ?, :param). Inlined raw literals in SQL strings are instantly rejected.

2. **State 2: INDEX_VERIFIED**:
   - Schema analyzer verifies that every column in the `WHERE` clause and `JOIN ... ON` clause has a matching B-tree or partial index.
   - Guard: Verify that no functions wrap indexed columns (`LOWER(col)`, `col::date`). Parameter types must strictly match column DDL types (e.g., UUID to UUID, string to string).

3. **State 3: BATCH_COALESCED**:
   - If loading child associations, individual single-record lookups are prohibited. The query is routed through a batch loader or combined into a single array query (`WHERE parent_id = ANY($1)`).
   - Guard: Loop detection static analysis verifies zero `db.query` calls within `for`, `while`, or `map` blocks.

4. **State 4: PLAN_OPTIMIZED**:
   - Pagination queries are inspected. If `OFFSET > 100` is detected, the query is rejected and rewritten into a Keyset Cursor query `(sort_col, id) < (cursor_sort, cursor_id)`.
   - Multi-table `LEFT JOIN` structures are checked to guarantee no Cartesian product $(M \times N)$ row explosion.

5. **State 5: EXECUTED**:
   - Query is executed against the database pool with mandatory execution timeouts (`statement_timeout = 5000` or Go `context.WithTimeout`).
   - If execution exceeds the slow-query threshold (200ms), an automated alert is triggered.

6. **State 6: AUDITED**:
   - Query metrics, row counts, and buffer hits are emitted to OpenTelemetry / `pg_stat_statements`.
   - In CI environments, queries must pass `QueryPlanAuditor` checking for zero unindexed `Seq Scan` on tables with $>1,000$ rows.

---

## 5. Technology-Specific Production Patterns

### 5.1. PostgreSQL: Keyset Cursor, Covering Index & Anti-N+1 Batch Lookups

```sql
-- ============================================================================
-- 1. Optimized Table DDL with Covering B-Tree & Partial Indexes
-- ============================================================================

CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    customer_id UUID NOT NULL,
    status VARCHAR(32) NOT NULL,
    total_amount NUMERIC(12, 2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- MANDATORY: Foreign key indexes
CREATE INDEX idx_orders_customer_id ON orders (customer_id);

-- OPTIMAL: Leftmost Prefix Rule Composite Index for Tenant Keyset Pagination
-- (tenant_id = ?) AND (status = ?) ORDER BY created_at DESC, id DESC
-- Using INCLUDE to enable pure Index-Only Scan (eliminating heap lookups)
CREATE INDEX idx_orders_tenant_status_covering 
ON orders (tenant_id, status, created_at DESC, id DESC)
INCLUDE (total_amount);

-- OPTIMAL: Partial Index for active processing queues (95% smaller than full index)
CREATE INDEX idx_orders_unprocessed 
ON orders (tenant_id, created_at ASC) 
WHERE status IN ('pending', 'processing');

-- ============================================================================
-- 2. Keyset Cursor Pagination Query (O(1) Seek Time at Any Depth)
-- ============================================================================

-- First Page (no cursor)
SELECT id, tenant_id, status, total_amount, created_at
FROM orders
WHERE tenant_id = 'a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d'::UUID
  AND status = 'completed'
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- Subsequent Pages (using keyset tuple comparison)
-- NEVER USE "OFFSET 100000" -- Keyset comparison achieves instant 0.1ms B-tree seek!
SELECT id, tenant_id, status, total_amount, created_at
FROM orders
WHERE tenant_id = 'a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d'::UUID
  AND status = 'completed'
  AND (created_at, id) < ('2026-10-27T10:00:00.000Z'::TIMESTAMPTZ, '9f8e7d6c-5b4a-3210-fedc-ba9876543210'::UUID)
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- ============================================================================
-- 3. Anti-N+1 Batch Lookup via ANY Array Operator (Single Roundtrip)
-- ============================================================================

-- Fetch order items for 500 orders in ONE single query (O(1) roundtrip)
SELECT 
    order_id, 
    id AS item_id, 
    product_id, 
    quantity, 
    unit_price
FROM order_items
WHERE order_id = ANY($1::UUID[]);
```

---

### 5.2. Go: `jackc/pgx/v5` & `sqlc` Keyset Pagination & Anti-N+1 Batch Loading

```go
package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Order struct {
	ID          uuid.UUID
	TenantID    uuid.UUID
	CustomerID  uuid.UUID
	Status      string
	TotalAmount float64
	CreatedAt   time.Time
}

type OrderItem struct {
	ID        uuid.UUID
	OrderID   uuid.UUID
	ProductID uuid.UUID
	Quantity  int
	UnitPrice float64
}

type KeysetCursor struct {
	CreatedAt time.Time
	ID        uuid.UUID
}

type OrderRepository struct {
	pool *pgxpool.Pool
}

func NewOrderRepository(pool *pgxpool.Pool) *OrderRepository {
	return &OrderRepository{pool: pool}
}

// GetOrdersKeyset executes a deterministic, constant-time keyset pagination query.
// It completely avoids OFFSET degradation and guarantees sub-millisecond execution.
func (r *OrderRepository) GetOrdersKeyset(
	ctx context.Context,
	tenantID uuid.UUID,
	status string,
	cursor *KeysetCursor,
	limit int,
) ([]Order, error) {
	queryCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	var query string
	var args []any

	if cursor == nil {
		query = `
			SELECT id, tenant_id, customer_id, status, total_amount, created_at
			FROM orders
			WHERE tenant_id = $1 AND status = $2
			ORDER BY created_at DESC, id DESC
			LIMIT $3`
		args = []any{tenantID, status, limit}
	} else {
		// PostgreSQL composite tuple comparison: (created_at, id) < ($3, $4)
		query = `
			SELECT id, tenant_id, customer_id, status, total_amount, created_at
			FROM orders
			WHERE tenant_id = $1 
			  AND status = $2
			  AND (created_at, id) < ($3, $4)
			ORDER BY created_at DESC, id DESC
			LIMIT $5`
		args = []any{tenantID, status, cursor.CreatedAt, cursor.ID, limit}
	}

	rows, err := r.pool.Query(queryCtx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("query orders keyset: %w", err)
	}
	defer rows.Close()

	var orders []Order
	for rows.Next() {
		var o Order
		if err := rows.Scan(&o.ID, &o.TenantID, &o.CustomerID, &o.Status, &o.TotalAmount, &o.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan order row: %w", err)
		}
		orders = append(orders, o)
	}
	return orders, rows.Err()
}

// BatchGetOrderItems eliminates the N+1 loop by fetching child items for all parent
// orders in a SINGLE network roundtrip using the PostgreSQL '= ANY($1)' construct.
func (r *OrderRepository) BatchGetOrderItems(
	ctx context.Context,
	orderIDs []uuid.UUID,
) (map[uuid.UUID][]OrderItem, error) {
	if len(orderIDs) == 0 {
		return make(map[uuid.UUID][]OrderItem), nil
	}

	queryCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	query := `
		SELECT id, order_id, product_id, quantity, unit_price
		FROM order_items
		WHERE order_id = ANY($1::UUID[])`

	rows, err := r.pool.Query(queryCtx, query, orderIDs)
	if err != nil {
		return nil, fmt.Errorf("batch query order items: %w", err)
	}
	defer rows.Close()

	itemsByOrder := make(map[uuid.UUID][]OrderItem, len(orderIDs))
	for rows.Next() {
		var item OrderItem
		if err := rows.Scan(&item.ID, &item.OrderID, &item.ProductID, &item.Quantity, &item.UnitPrice); err != nil {
			return nil, fmt.Errorf("scan order item: %w", err)
		}
		itemsByOrder[item.OrderID] = append(itemsByOrder[item.OrderID], item)
	}
	return itemsByOrder, rows.Err()
}
```

---

### 5.3. TypeScript: Drizzle ORM Keyset Pagination & Anti-N+1 Invariants

```typescript
import { db } from './db';
import { orders, orderItems } from './schema';
import { eq, and, desc, sql, inArray } from 'drizzle-orm';

export interface KeysetParam {
  createdAt: Date;
  id: string;
}

/**
 * Industrial Keyset Cursor Pagination using Drizzle ORM.
 * Avoids OFFSET; uses SQL tuple comparison for O(1) B-tree seeks.
 */
export async function getOrdersKeyset(
  tenantId: string,
  status: string,
  cursor: KeysetParam | null,
  limit = 20
) {
  const baseConditions = [
    eq(orders.tenantId, tenantId),
    eq(orders.status, status),
  ];

  if (cursor) {
    // Tuple comparison: (created_at, id) < (cursor.createdAt, cursor.id)
    baseConditions.push(
      sql`(${orders.createdAt}, ${orders.id}) < (${cursor.createdAt.toISOString()}, ${cursor.id})`
    );
  }

  const resultOrders = await db
    .select({
      id: orders.id,
      tenantId: orders.tenantId,
      customerId: orders.customerId,
      status: orders.status,
      totalAmount: orders.totalAmount,
      createdAt: orders.createdAt,
    })
    .from(orders)
    .where(and(...baseConditions))
    .orderBy(desc(orders.createdAt), desc(orders.id))
    .limit(limit);

  if (resultOrders.length === 0) {
    return { items: [], nextCursor: null };
  }

  // Eradicate N+1: Batch fetch all child order items in exactly ONE query
  const orderIds = resultOrders.map((o) => o.id);
  const items = await db
    .select()
    .from(orderItems)
    .where(inArray(orderItems.orderId, orderIds));

  // In-memory mapping
  const itemsByOrderId = new Map<string, typeof items>();
  for (const item of items) {
    const list = itemsByOrderId.get(item.orderId) ?? [];
    list.push(item);
    itemsByOrderId.set(item.orderId, list);
  }

  const enriched = resultOrders.map((o) => ({
    ...o,
    items: itemsByOrderId.get(o.id) ?? [],
  }));

  const lastItem = enriched[enriched.length - 1];
  const nextCursor = enriched.length === limit ? {
    createdAt: lastItem.createdAt,
    id: lastItem.id,
  } : null;

  return {
    items: enriched,
    nextCursor,
  };
}
```

---

## 6. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

Before any SQL migration, schema definition, ORM query, or repository implementation generated by an autonomous agent is committed to version control, it MUST satisfy all six machine-verifiable verification gates:

| Gate | Verification Target | Deterministic Metric / Pass Criterion | Enforcement Tool / CLI Command |
| :--- | :--- | :--- | :--- |
| **Gate 1: Mandatory Foreign Key Indexes** | Schema DDL & Migrations | 100% of foreign keys have an explicit B-tree index; composite index columns strictly follow `(Equality -> Range -> Sort)`. | `SELECT conrelid::regclass, a.attname FROM pg_constraint c JOIN pg_attribute a ON a.attnum = ANY(c.conkey) WHERE c.contype = 'f' AND NOT EXISTS (...)` |
| **Gate 2: Anti-N+1 Static Analysis Gate** | Repositories & Data Access Layers | Zero database execution calls (`query()`, `find()`, `select()`) nested inside loops (`for`, `while`, `map`, `forEach`). | AST ESLint rule / `go vet` custom pass / CI static analysis scan |
| **Gate 3: Keyset Cursor Pagination Gate** | Pagination APIs & Endpoints | Strict prohibition of `OFFSET > 100` on production tables ($N > 10,000$ rows); mandatory keyset comparison `(created_at, id) < (...)`. | Automated integration test verifying query plan does not emit `Offset` node; cursor seek $\le 5\text{ms}$ at page depth $P=5,000$ |
| **Gate 4: Zero Expression / Type Coercion Invalidation** | Predicates & Filter Clauses | Zero un-indexed function calls in `WHERE` clauses (`LOWER()`, `DATE()`, `CAST()`); strict parameter type alignment. | CI query linter verifying against `pg_proc` and `pg_type` matches |
| **Gate 5: HOT Preservation & Covering Index Cap** | Table Index Density | Index count per table $\le 7$; high-update columns do not break PostgreSQL HOT (Heap-Only Tuple) optimization; `INCLUDE` used for Index-Only Scans. | `SELECT n_tup_upd, n_tup_hot_upd, (n_tup_hot_upd::float / NULLIF(n_tup_upd, 0)) AS hot_ratio FROM pg_stat_user_tables` |
| **Gate 6: `EXPLAIN (BUFFERS)` CI Regression Gate** | Query Plan & Performance Verification | Automated CI execution of all repository queries with `EXPLAIN (ANALYZE, BUFFERS)`; shared buffer hit ratio $\ge 99\%$; zero `Seq Scan` on relations with $>1,000$ rows. | `QueryPlanAuditor.audit()` pass in CI test harness |

---

## 7. Anti-Patterns vs Industrial Invariants

| Vulnerability / Anti-Pattern | Operational Failure Mode | Industrial Production Invariant |
| :--- | :--- | :--- |
| **N+1 Query Loop** | `for row in rows: db.query(...)` fires $1 + N$ queries; network latency multiplies and database connection pool starves under load. | **Batch Loading**: Use `WHERE id = ANY($1::UUID[])`, `WHERE id IN (...)`, or in-memory `DataLoader` coalescing within single microtask ticks. |
| **Unindexed Foreign Keys** | Cascading deletes and child table lookups trigger $O(N)$ full table scans, locking tables and exhausting I/O. | **Mandatory Foreign Key Indexes**: Every `FOREIGN KEY (parent_id)` MUST have an accompanying `CREATE INDEX idx_table_parent_id ON table (parent_id)`. |
| **Offset Pagination Cliff** | `OFFSET 500000 LIMIT 20` scans and discards 500,000 rows, blowing out buffer caches and p99 latency. | **Keyset Cursor Pagination**: Use `WHERE (created_at, id) < (:cursor_time, :cursor_id) ORDER BY created_at DESC, id DESC LIMIT :limit` for $O(1)$ constant seek time. |
| **Expression Index Invalidation** | `WHERE LOWER(email) = ?` or `WHERE DATE(created_at) = ...` silently invalidates B-tree indexes, forcing full table scans. | **Functional / Expression Indexes**: Create `CREATE INDEX ON users (LOWER(email))` or align application queries to avoid function wrappers. |
| **Implicit Type Casting** | Querying a `VARCHAR` column with an unquoted integer forces PostgreSQL/MySQL to execute `CAST(col AS int)`, disabling index. | **Strict Type Alignment**: Ensure ORM and query parameters match column data types exactly (UUID, BigInt, Text). |
| **Cartesian Multi-JOIN Explosion** | Joining multiple 1-to-N child tables in a single query explodes result sets into millions of duplicated rows, crashing runtimes. | **Isolated Batch Queries**: Split multi-collection queries into separate batched lookups or use Postgres `jsonb_agg` subqueries. |
| **Over-Indexing Write Amplification** | Creating 15+ indexes on write-heavy tables balloons WAL writes, fragments disk, and disables PostgreSQL HOT updates. | **Partial & Covering Indexes**: Limit indexes to 5–7 per table; use partial indexes `WHERE status IN (...)` and `INCLUDE (...)` for Index-Only Scans. |
