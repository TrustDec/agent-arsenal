---
description: PostgreSQL full-text search (FTS), tsvector generated columns, websearch_to_tsquery sanitization, trigram fuzzy matching (pg_trgm), GIN vs GiST index selection, gin_pending_list_limit FastUpdate write-stall elimination, GIN index bloat defense, and hybrid semantic-lexical Reciprocal Rank Fusion (RRF) across Go (pgx/v5), TypeScript (Drizzle/Kysely/Prisma), Python (psycopg/SQLAlchemy), Rust (tokio-postgres), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{search,fts,trgm,gin,gist,tsvector,tsquery,rrf,hybrid,query,repository,schema}*.*,**/src/search/**/*.{ts,js,go,rs,py},**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/search/**/*.{go,rs},**/internal/store/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Full-Text Search, Trigram Indexing, GIN FastUpdate & Bloat Elimination Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to implement full-text search, fuzzy autocomplete, trigram similarity matching, multi-column document indexing, or hybrid lexical-vector search across PostgreSQL, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `Prisma`), Python (`psycopg3`, `SQLAlchemy`), or Rust (`tokio-postgres`). Eliminate the "Unbounded ILIKE '%query%' Sequential Table Scan CPU Meltdown" (where developers and agents implement search via `WHERE title ILIKE '%' || $1 || '%'`, forcing the engine to sequentially read millions of heap pages and evaluate substrings on every row, pegging CPU at 100% and increasing p99 latency by $150\times$), the "GIN Pending List FastUpdate Write Stall Avalanche" (where default `fastupdate = on` accumulates inserts in an unindexed buffer until `gin_pending_list_limit = 4MB` is exceeded, forcing an arbitrary user write to stall for 2,500ms–8,000ms while executing an exclusive synchronous posting list cleanup), the "Run-Time to_tsvector() Dynamic Stemming & CPU Burn Trap" (where queries execute `to_tsvector('english', title || ' ' || body)` on the fly inside `WHERE` clauses without a pre-computed generated column, re-tokenizing and stemming text on millions of candidate tuples per query), the "GIN Inverted Index Bloat & Autovacuum Freezing Stagnation" (where high-churn relations generate millions of dead posting items, bloating GIN indexes to $5\times–15\times$ the table volume and choking autovacuum workers), the "Trigram Similarity Threshold Disconnect & Misconfigured Operator Index Bypass" (where queries use `WHERE similarity(col, $1) > 0.3` instead of the sargable `%` or `%>` operators, causing PostgreSQL to bypass trigram indexes and scan the entire table), and the "Hybrid Vector + Lexical Search Rank Inversion Trap" (where agents naively sum raw `ts_rank` and cosine distance scores without Reciprocal Rank Fusion, allowing vector distances to drown exact SKU, email, or serial number hits) by establishing a strict 5-Tier Search & GIN Governance Ladder, generated stored tsvectors, workload-aligned GIN vs GiST index selection, and machine-verifiable search CI sentinels.

---

## 1. Architectural Taxonomy: The 6 Search & GIN Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL provides two primary inverted and geometric indexing mechanisms for text search:
1. **Full-Text Search Engine (`tsvector`, `tsquery`, Snowball Stemming)**: Parses human-language text into normalized lexemes (stems), records token positions and weights (A, B, C, D), and evaluates boolean logic queries (`&`, `|`, `!`, `<->`).
2. **Trigram Indexing (`pg_trgm`, N-gram Deconstruction)**: Breaks strings into 3-consecutive-character substrings (e.g., `"word"` $\to$ `{"  w", " wo", "wor", "ord", "rd "}`), enabling index-accelerated wildcard matching (`LIKE '%term%'`), regular expressions, and fuzzy string similarity.

Underlying these capabilities are two specialized index access methods:
- **GIN (Generalized Inverted Index)**: Maps each unique key (lexeme or trigram) to a sorted list or B-tree of tuple IDs (TIDs) called a *posting tree*. Ideal for read-intensive workloads ($R/W > 10:1$).
- **GiST (Generalized Search Tree)**: Uses hierarchical lossy bounding signatures. Slower for text lookups due to signature false-positives, but incurs zero write-stall pending lists, supports nearest-neighbor distance ordering (`ORDER BY col <-> 'query' LIMIT 10`), and handles high write churn ($R/W \le 3:1$) without catastrophic index bloat.

When autonomous coding agents generate search queries or schemas, LLMs routinely commit fatal architectural anti-patterns:

```typescript
// ❌ CATASTROPHIC LLM SEARCH & GIN ANTI-PATTERNS

// 1. Implementing search with leading wildcard ILIKE on unindexed columns!
// Standard B-Trees CANNOT index leading wildcards ('%term%').
// On a 5,000,000 row table, every keystroke triggers a full sequential table scan!
const results = await db.query(
  `SELECT * FROM articles WHERE title ILIKE '%' || $1 || '%' OR body ILIKE '%' || $1 || '%'`,
  [searchQuery]
);

// 2. Dynamically computing to_tsvector on every query execution!
// Parses, stems, and filters stopwords for EVERY candidate row on the fly!
// Bypasses index acceleration unless a precise functional expression index exists.
const fts = await db.query(
  `SELECT * FROM products WHERE to_tsvector('english', name || ' ' || description) @@ to_tsquery('english', $1)`,
  [userQuery] // If user inputs "c++" or "sales &", to_tsquery throws a fatal syntax error!
);

// 3. Leaving fastupdate = on with default gin_pending_list_limit = 4MB on high-write tables!
// Creates catastrophic p99 write stalls: an innocent INSERT suddenly freezes for 4 seconds
// while PostgreSQL synchronously merges thousands of keys into the GIN posting tree.
await db.query(`CREATE INDEX idx_logs_body ON logs USING gin (to_tsvector('english', message))`);

// 4. Using similarity() function instead of sargable % operator!
// similarity(a, b) > 0.3 CANNOT use the GIN trigram index; causes full table scan!
const fuzzy = await db.query(
  `SELECT * FROM users WHERE similarity(email, $1) > 0.4`,
  [inputEmail]
);

// 5. Naively adding raw vector distances and ts_rank scores!
// ts_rank is unbounded (0.001 - 0.9), while vector cosine distance is [0, 2].
// High vector variance completely annihilates exact keyword, SKU, or email matches!
const hybrid = await db.query(
  `SELECT id, (1 - (embedding <=> $1)) * 0.7 + ts_rank(search_vec, query) * 0.3 AS score ...`
);
```

In production architectures, these anti-patterns manifest as six catastrophic failure modes:

- **The "Unbounded ILIKE '%query%' Sequential Table Scan CPU Meltdown"**:
  - Standard B-tree indexes navigate sorted keys via $\mathcal{O}(\log N)$ binary search. When a search predicate begins with a wildcard (`%keyword%`), the B-tree cannot establish a start key.
  - The query planner falls back to a `Seq Scan`, reading all heap pages from disk into `shared_buffers`, decompressing text attributes, and running CPU-bound string matching algorithms across millions of tuples.
  - At 50 concurrent requests, CPU utilization pegs at 100%, saturating worker pools and causing connection queues to back up until the application layer times out with `504 Gateway Timeout`.
- **The "GIN Pending List FastUpdate Write Stall Avalanche"**:
  - GIN indexes are expensive to update because a single row insert may introduce 50–200 unique lexemes or trigrams, each requiring an update to a separate posting tree.
  - To accelerate writes, PostgreSQL enables `fastupdate = on` by default, buffering newly inserted keys into an unsorted pending list.
  - When the pending list exceeds `gin_pending_list_limit` (default 4MB), the backend executing the next `INSERT` or `UPDATE` is forced to perform an in-line synchronous cleanup (`gin_clean_pending_list()`).
  - This backend acquires an exclusive lock on the GIN index, sorts all accumulated keys, and traverses dozens of posting trees. Normal insert latency of $2\text{ms}$ spikes to $3,000\text{ms}–8,000\text{ms}$, triggering HTTP client aborts and cascading transaction pool exhaustion.
- **The "Run-Time to_tsvector() Dynamic Stemming & CPU Burn Trap"**:
  - Executing `to_tsvector('english', title || ' ' || body)` inside SQL queries forces the backend executor to run the Snowball stemming algorithm, token parsing, and stopword array comparison on every single row candidate.
  - Without a pre-computed column, this calculation is repeated millions of times per minute.
  - Furthermore, if an unescaped raw string is passed to `to_tsquery($1)` (such as `"node.js"` or `"postgres & redis"`), PostgreSQL throws `ERROR: syntax error in tsquery: "node.js"`, crashing the user session.
- **The "GIN Inverted Index Bloat & Autovacuum Freezing Stagnation"**:
  - When indexed documents are updated or deleted, dead TIDs accumulate inside GIN posting lists and posting trees.
  - Unlike B-Trees which can reclaim empty leaf pages efficiently, GIN posting lists use segment compression. Autovacuum must decompress posting lists, filter out dead TIDs, and recompress them.
  - Under high update churn, GIN indexes rapidly bloat to $5\times–15\times$ their baseline size. A 10GB table can spawn a 60GB GIN index that evicts active table pages from `shared_buffers`, degrading cache hit ratios cluster-wide.
- **The "Trigram Similarity Threshold Disconnect & Misconfigured Operator Index Bypass"**:
  - `pg_trgm` exposes the `similarity(text, text)` function and indexable operators: `%` (similarity threshold check), `<%` (word similarity), and `strict_word_similarity`.
  - Calling `WHERE similarity(title, $1) > 0.3` is non-sargable: the query planner cannot map the function call to the index's scan keys and executes a sequential scan.
  - Developers must use `WHERE title % $1` or order by distance `ORDER BY title <-> $1`, which directly invokes the GIN or GiST index scan operator.
- **The "Hybrid Vector + Lexical Search Rank Inversion Trap"**:
  - When combining dense semantic embeddings (from models like text-embedding-3-small) with sparse full-text search, raw score spaces are mathematically incomparable.
  - Cosine distance ranges in $[0, 2]$, where smaller is better; `ts_rank` ranges non-linearly in $[0, 1]$, where larger is better and heavily skewed by document length and term frequency.
  - Linearly weighting these raw numbers produces rank inversion: a document with a mediocre semantic match and low text relevance can easily outrank an exact keyword match containing the user's specific serial number or SKU code.

To eradicate these catastrophes, every production agentic system must enforce the **5-Tier Search & GIN Governance Ladder**:

```
┌────────────────────────────────────────────────────────────────────────┐
│             5-TIER SEARCH & GIN GOVERNANCE LADDER                      │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Reciprocal Rank Fusion (RRF) & Continuous Search Health CI     │
│         - Math-proven RRF: RRF(d) = sum(w_m / (60 + Rank_m(d)))        │
│         - Automated CI Gate: TempWrittenBlocks == 0, GIN pending == 0  │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Sargable Trigram Operators & Safe Websearch Sanitization       │
│         - Mandatory % and %> operators for pg_trgm index activation   │
│         - websearch_to_tsquery() / plainto_tsquery() escaping          │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Workload-Aligned Index Selection (GIN vs GiST)                 │
│         - Read-Heavy (R/W > 10:1): GIN + tuned pending list (16MB)     │
│         - Write-Heavy (R/W <= 3:1): GiST + signature trees             │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Stored Generated tsvector Columns with Immutable Language Config│
│         - GENERATED ALWAYS AS (to_tsvector(...)) STORED                │
│         - Zero run-time stemming overhead; 100% index coverage         │
├────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Engine Extensions, FastUpdate Hardening & Pending Cleanups    │
│         - CREATE EXTENSION IF NOT EXISTS pg_trgm, unaccent             │
│         - fastupdate = off on OLTP hot paths or background maintenance │
│         - Scheduled gin_clean_pending_list() execution                 │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Foundations & Physical Cost Models

### 2.1 Inverted Index Lookup Complexity vs Sequential String Scan

Let $N$ be the total number of documents in the table, $L$ be the average length of each text attribute in bytes, and $Q$ be the search query containing $k$ unique search terms $\{t_1, t_2, \dots, t_k\}$.

Under a naive sequential scan with substring evaluation (`ILIKE`):
$$T_{\text{SeqScan}} = \mathcal{O}\left( N \cdot L \cdot \sum_{i=1}^k |t_i| \right)$$
For $N = 10^7$ rows and $L = 500$ bytes, every search query evaluates $5 \times 10^9$ character comparisons, requiring multiple gigabytes of memory throughput per query.

Under an inverted index (GIN):
Let $P(t_i)$ be the posting list of TIDs matching term $t_i$, with length $|P(t_i)| \ll N$. The GIN index performs $k$ B-tree lookups over the vocabulary of unique terms (size $V$), followed by a sorted intersection of the posting lists:
$$T_{\text{GIN}} = \mathcal{O}\left( \sum_{i=1}^k \log V + \sum_{i=1}^{k-1} \min(|P(t_i)|, |P(t_{i+1})|) \right)$$
Because $V \le 10^6$ and posting lists are pre-sorted by TID, the intersection executes in $\mathcal{O}(|P(t_1)| + |P(t_2)|)$ via linear merge or skip-list skipping, reducing runtime from $3,500\text{ms}$ to $< 2\text{ms}$.

### 2.2 GIN FastUpdate Amortized Write Amplification & Pending List Flush

When `fastupdate = on`, each insert appends $M$ key-TID pairs to the pending list page buffer without sorting. When the pending list size $S_{\text{pending}}$ reaches the threshold $L_{\text{pending}} = \text{gin\_pending\_list\_limit}$:
$$S_{\text{pending}} \ge L_{\text{pending}}$$

PostgreSQL triggers `gin_clean_pending_list()`. The backend must:
1. Lock the GIN index in exclusive mode.
2. Quicksort all $M_{\text{total}}$ buffered entries:
   $$T_{\text{sort}} = \mathcal{O}(M_{\text{total}} \log M_{\text{total}})$$
3. Merge sorted entries into their respective GIN posting trees (height $H_{\text{tree}}$):
   $$T_{\text{merge}} = \mathcal{O}(M_{\text{total}} \cdot H_{\text{tree}})$$

The total synchronous stall time $T_{\text{stall}}$ imposed on the unlucky write query is:
$$T_{\text{stall}} \approx \alpha \cdot M_{\text{total}} \log M_{\text{total}} + \beta \cdot M_{\text{total}} \cdot \text{IOPS}_{\text{disk}}^{-1}$$
For a default $4\text{MB}$ pending list containing $\approx 150,000$ trigram entries on a loaded database, $T_{\text{stall}} \ge 2,500\text{ms}$.
**Production Invariant**: For latency-sensitive write paths, set `WITH (fastupdate = off)` so each insert pays a deterministic micro-cost of $0.8\text{ms}$ rather than subjecting random users to multi-second latency cliffs.

### 2.3 Trigram Jaccard Similarity & N-Gram Bounding

For two strings $s_1$ and $s_2$, let $T(s)$ denote the multiset of 3-character substrings generated after padding $s$ with two leading spaces and one trailing space:
$$\text{Sim}_{\text{trgm}}(s_1, s_2) = \frac{|T(s_1) \cap T(s_2)|}{|T(s_1) \cup T(s_2)|}$$
The similarity score satisfies:
$$0 \le \text{Sim}_{\text{trgm}}(s_1, s_2) \le 1.0$$
A query with similarity threshold $\tau \in (0, 1)$ matches iff:
$$\text{Sim}_{\text{trgm}}(s_1, s_2) \ge \tau$$
To utilize a GIN trigram index, the query MUST use the sargable operator `%`:
$$s_1 \ \% \ s_2 \iff \text{Sim}_{\text{trgm}}(s_1, s_2) \ge \text{current\_setting}('pg\_trgm.similarity\_threshold')::\text{float}$$

### 2.4 Reciprocal Rank Fusion (RRF) Convergence Theorem

Let $M$ be the set of retrieval modalities (e.g., $M = \{\text{lexical}, \text{semantic}\}$). For each modality $m \in M$, let $\text{Rank}_m(d) \in \{1, 2, \dots, K\}$ denote the 1-based rank position of document $d$.

The Reciprocal Rank Fusion score is defined as:
$$\text{RRF}(d) = \sum_{m \in M} \frac{w_m}{k + \text{Rank}_m(d)}$$
where:
- $k$ is the smoothing ranking constant (standard literature $k = 60$).
- $w_m$ is the modality weight ($w_m > 0, \sum w_m = 1.0$).

**Theorem (Scale Invariance & Outlier Robustness)**:
Unlike linear combination $\text{Score}(d) = \sum w_m \cdot S_m(d)$ which is sensitive to monotonic non-linear scaling $\phi(S_m)$, the RRF score depends solely on ordinal ranking permutations $\sigma_m \in S_N$. For any strictly monotonic transformation $g: \mathbb{R} \to \mathbb{R}$ applied to individual similarity scores:
$$\text{Rank}(g(S_m(d))) = \text{Rank}(S_m(d)) \implies \text{RRF}_{g}(d) = \text{RRF}(d)$$
Thus, Reciprocal Rank Fusion guarantees mathematical immunity to calibration drift between vector cosine distance and BM25/ts_rank score distributions.

---

## 3. Production Hardening: SQL, Schema & Migration Patterns

```sql
-- ============================================================================
-- AGENTIC SEARCH & GIN INDEX PRODUCTION MIGRATION PATTERN
-- ============================================================================

-- 1. Enable Required Extensions
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- 2. Create Search Configuration with Unaccent Filter
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_ts_config WHERE cfgname = 'unaccent_english'
  ) THEN
    CREATE TEXT SEARCH CONFIGURATION unaccent_english (COPY = english);
    ALTER TEXT SEARCH CONFIGURATION unaccent_english
      ALTER MAPPING FOR word, asciiword, hword, asciihword, hword_part, asciihword_part
      WITH unaccent, english_stem;
  END IF;
END $$;

-- 3. Production Table with Immutable Stored Generated tsvector Column
CREATE TABLE IF NOT EXISTS knowledge_articles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL,
  title VARCHAR(255) NOT NULL,
  slug VARCHAR(255) NOT NULL,
  content TEXT NOT NULL,
  tags TEXT[] NOT NULL DEFAULT '{}',
  sku_code VARCHAR(64),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_published BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- MANDATORY: Stored Generated tsvector Column
  -- Concatenates title (Weight A), tags (Weight B), and content (Weight C)
  -- Uses immutable text search configuration to prevent index invalidation
  search_vector tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('unaccent_english', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('unaccent_english', array_to_string(tags, ' ')), 'B') ||
    setweight(to_tsvector('unaccent_english', coalesce(sku_code, '')), 'A') ||
    setweight(to_tsvector('unaccent_english', coalesce(content, '')), 'C')
  ) STORED
);

-- 4. Workload-Aligned Indexing Strategy

-- A. Full-Text Search Inverted Index (GIN with FastUpdate Hardening)
-- For read-heavy document tables: fastupdate = on with calibrated pending list (16MB)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_articles_search_vector
  ON knowledge_articles USING gin (search_vector)
  WITH (fastupdate = on, gin_pending_list_limit = '16MB');

-- B. Trigram Autocomplete Index on Title (Fast Autocomplete / Substring Match)
-- For high-traffic user-facing autocomplete: fastupdate = off eliminates write-stall latency cliffs!
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_articles_title_trgm
  ON knowledge_articles USING gin (title gin_trgm_ops)
  WITH (fastupdate = off);

-- C. Exact / Fuzzy SKU & Identifier Index (B-Tree + Trigram)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_articles_sku_trgm
  ON knowledge_articles USING gin (sku_code gin_trgm_ops)
  WHERE sku_code IS NOT NULL;

-- D. Composite Tenant Filtering Support
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_articles_tenant_published
  ON knowledge_articles (tenant_id, is_published, created_at DESC);

-- 5. Periodic Scheduled Maintenance Script (Execute via cron / pg_cron)
-- Prevents unmonitored pending list accumulation during high-write batches
DO $$
DECLARE
  idx RECORD;
BEGIN
  FOR idx IN
    SELECT c.relname AS index_name
    FROM pg_class c
    JOIN pg_am am ON am.oid = c.relam
    WHERE am.amname = 'gin' AND c.relnamespace = 'public'::regnamespace
  LOOP
    BEGIN
      PERFORM gin_clean_pending_list(idx.index_name::regclass);
    EXCEPTION WHEN OTHERS THEN
      -- Log non-fatal error if another worker is currently vacuuming
      RAISE NOTICE 'Skipping pending list cleanup for index %: %', idx.index_name, SQLERRM;
    END;
  END LOOP;
END $$;
```

---

## 4. Production TypeScript Engine: AgenticDatabaseSearchEngine

```typescript
import { Pool, PoolClient } from 'pg';

export interface SearchQueryOptions {
  tenantId: string;
  rawQuery: string;
  limit?: number;
  offset?: number;
  minSimilarity?: number;
}

export interface HybridSearchResult {
  id: string;
  title: string;
  snippet: string;
  lexicalRank: number;
  semanticRank: number;
  rrfScore: number;
}

export interface GinIndexHealth {
  indexName: string;
  tableName: string;
  indexSizeBytes: number;
  indexSizePretty: string;
  pendingListPages: number;
  pendingListBytes: number;
  isPendingListBloated: boolean;
  fastUpdateEnabled: boolean;
}

/**
 * AgenticDatabaseSearchEngine
 * Enforces Tier 0-4 Search & GIN invariants across PostgreSQL applications.
 */
export class AgenticDatabaseSearchEngine {
  constructor(private readonly pool: Pool) {}

  /**
   * Sanitizes raw user input for websearch_to_tsquery.
   * Strips null bytes and escapes pathological regex characters.
   */
  public sanitizeSearchQuery(query: string): string {
    return query
      .replace(/\0/g, '')
      .trim()
      .replace(/[^\w\s\-\"\'\+]/gi, ' ')
      .replace(/\s+/g, ' ');
  }

  /**
   * Executes a robust Full-Text Search query using websearch_to_tsquery.
   * Automatically handles quotes for phrases and minus for negation safely.
   */
  public async executeFullTextSearch(options: SearchQueryOptions): Promise<any[]> {
    const sanitized = this.sanitizeSearchQuery(options.rawQuery);
    if (!sanitized) return [];

    const limit = Math.min(Math.max(options.limit ?? 20, 1), 100);
    const offset = Math.max(options.offset ?? 0, 0);

    const sql = `
      SELECT
        id,
        title,
        ts_headline(
          'unaccent_english',
          content,
          query,
          'StartSel=<mark>, StopSel=</mark>, MaxWords=35, MinWords=15, ShortWord=3, HighlightAll=FALSE, MaxFragments=2'
        ) AS snippet,
        ts_rank_cd(search_vector, query, 32 /* rank/(rank+1) */) AS rank_score
      FROM knowledge_articles,
           websearch_to_tsquery('unaccent_english', $1) query
      WHERE tenant_id = $2
        AND is_published = true
        AND search_vector @@ query
      ORDER BY rank_score DESC, created_at DESC
      LIMIT $3 OFFSET $4;
    `;

    const res = await this.pool.query(sql, [sanitized, options.tenantId, limit, offset]);
    return res.rows;
  }

  /**
   * Executes sargable trigram fuzzy autocomplete on article titles.
   * Uses the % operator and word similarity for sub-millisecond autocomplete.
   */
  public async executeTrigramAutocomplete(
    tenantId: string,
    prefix: string,
    limit: number = 10
  ): Promise<Array<{ id: string; title: string; similarity: number }>> {
    const cleanPrefix = this.sanitizeSearchQuery(prefix);
    if (cleanPrefix.length < 2) return [];

    const boundedLimit = Math.min(Math.max(limit, 1), 20);

    // Uses transaction-scoped threshold elevation
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SET LOCAL pg_trgm.similarity_threshold = '0.3'");

      const sql = `
        SELECT
          id,
          title,
          similarity(title, $1) AS match_similarity
        FROM knowledge_articles
        WHERE tenant_id = $2
          AND is_published = true
          AND title % $1
        ORDER BY match_similarity DESC, created_at DESC
        LIMIT $3;
      `;

      const res = await client.query(sql, [cleanPrefix, tenantId, boundedLimit]);
      await client.query('COMMIT');
      return res.rows;
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  }

  /**
   * Executes Reciprocal Rank Fusion (RRF) combining Lexical FTS and Vector Search.
   * Completely eliminates scale distortion between ts_rank and cosine distance.
   */
  public async executeHybridRrfSearch(
    tenantId: string,
    queryText: string,
    queryEmbedding: number[],
    limit: number = 20,
    kConstant: number = 60
  ): Promise<HybridSearchResult[]> {
    const sanitized = this.sanitizeSearchQuery(queryText);
    const vectorStr = `[${queryEmbedding.join(',')}]`;
    const boundedLimit = Math.min(Math.max(limit, 1), 50);

    const sql = `
      WITH lexical_candidates AS (
        SELECT
          id,
          title,
          content,
          ROW_NUMBER() OVER (ORDER BY ts_rank_cd(search_vector, q) DESC) AS rank
        FROM knowledge_articles,
             websearch_to_tsquery('unaccent_english', $1) q
        WHERE tenant_id = $2 AND is_published = true AND search_vector @@ q
        LIMIT 50
      ),
      semantic_candidates AS (
        SELECT
          id,
          title,
          content,
          ROW_NUMBER() OVER (ORDER BY embedding <=> $3::vector) AS rank
        FROM knowledge_articles
        WHERE tenant_id = $2 AND is_published = true AND embedding IS NOT NULL
        LIMIT 50
      ),
      fused AS (
        SELECT
          coalesce(l.id, s.id) AS id,
          coalesce(l.title, s.title) AS title,
          coalesce(l.content, s.content) AS content,
          coalesce(l.rank, 999) AS lexical_rank,
          coalesce(s.rank, 999) AS semantic_rank,
          (
            coalesce(1.0 / ($4 + l.rank), 0.0) * 0.5 +
            coalesce(1.0 / ($4 + s.rank), 0.0) * 0.5
          ) AS rrf_score
        FROM lexical_candidates l
        FULL OUTER JOIN semantic_candidates s ON l.id = s.id
      )
      SELECT
        id,
        title,
        substring(content from 1 for 150) AS snippet,
        lexical_rank,
        semantic_rank,
        rrf_score
      FROM fused
      ORDER BY rrf_score DESC
      LIMIT $5;
    `;

    const res = await this.pool.query(sql, [
      sanitized,
      tenantId,
      vectorStr,
      kConstant,
      boundedLimit,
    ]);

    return res.rows.map((r: any) => ({
      id: r.id,
      title: r.title,
      snippet: r.snippet,
      lexicalRank: parseInt(r.lexical_rank, 10),
      semanticRank: parseInt(r.semantic_rank, 10),
      rrfScore: parseFloat(r.rrf_score),
    }));
  }

  /**
   * Audits database GIN indexes, inspecting pending list sizes and bloat risks.
   */
  public async auditGinIndexHealth(): Promise<GinIndexHealth[]> {
    const sql = `
      SELECT
        c.relname AS index_name,
        t.relname AS table_name,
        pg_relation_size(c.oid) AS index_bytes,
        pg_size_pretty(pg_relation_size(c.oid)) AS index_size_pretty,
        coalesce(gin_stat.pending_pages, 0) AS pending_pages,
        coalesce(gin_stat.pending_pages, 0) * 8192 AS pending_bytes,
        coalesce(opt.fastupdate, true) AS fast_update_enabled
      FROM pg_class c
      JOIN pg_am am ON am.oid = c.relam
      JOIN pg_index i ON i.indexrelid = c.oid
      JOIN pg_class t ON t.oid = i.indrelid
      LEFT JOIN LATERAL (
        SELECT (regexp_matches(c.reloptions::text, 'fastupdate=(true|false|on|off)'))[1] IN ('true', 'on') AS fastupdate
      ) opt ON true
      LEFT JOIN LATERAL (
        SELECT (gin_stats).pending_pages AS pending_pages
        FROM (SELECT gin_metapage_info(get_raw_page(c.relname, 0)) AS gin_stats) s
      ) gin_stat ON true
      WHERE am.amname = 'gin' AND c.relnamespace = 'public'::regnamespace;
    `;

    // Note: gin_metapage_info requires pageinspect extension if installed;
    // Fallback query if pageinspect is absent:
    const fallbackSql = `
      SELECT
        c.relname AS index_name,
        t.relname AS table_name,
        pg_relation_size(c.oid) AS index_bytes,
        pg_size_pretty(pg_relation_size(c.oid)) AS index_size_pretty,
        0 AS pending_pages,
        0 AS pending_bytes,
        true AS fast_update_enabled
      FROM pg_class c
      JOIN pg_am am ON am.oid = c.relam
      JOIN pg_index i ON i.indexrelid = c.oid
      JOIN pg_class t ON t.oid = i.indrelid
      WHERE am.amname = 'gin' AND c.relnamespace = 'public'::regnamespace;
    `;

    try {
      const res = await this.pool.query(sql);
      return res.rows.map(this.mapGinRow);
    } catch {
      const res = await this.pool.query(fallbackSql);
      return res.rows.map(this.mapGinRow);
    }
  }

  private mapGinRow(r: any): GinIndexHealth {
    const pendingBytes = parseInt(r.pending_bytes, 10);
    return {
      indexName: r.index_name,
      tableName: r.table_name,
      indexSizeBytes: parseInt(r.index_bytes, 10),
      indexSizePretty: r.index_size_pretty,
      pendingListPages: parseInt(r.pending_pages, 10),
      pendingListBytes: pendingBytes,
      isPendingListBloated: pendingBytes > 8 * 1024 * 1024, // > 8MB
      fastUpdateEnabled: r.fast_update_enabled === true,
    };
  }

  /**
   * Manually cleans bloated GIN pending lists to protect user write latency.
   */
  public async cleanGinPendingList(indexName: string): Promise<void> {
    const client = await this.pool.connect();
    try {
      // Validate index name against SQL injection
      const check = await client.query(
        `SELECT c.relname FROM pg_class c JOIN pg_am am ON am.oid = c.relam WHERE am.amname = 'gin' AND c.relname = $1`,
        [indexName]
      );
      if (check.rowCount === 0) {
        throw new Error(`Invalid or non-GIN index: ${indexName}`);
      }
      await client.query(`SELECT gin_clean_pending_list($1::regclass)`, [indexName]);
    } finally {
      client.release();
    }
  }
}
```

---

## 5. Machine-Verifiable 6-State FSM & Definition of Done (DoD)

### 5.1 Search & GIN Lifecycle Finite State Machine (FSM)

```
       ┌────────────────────────┐
       │ 1. EXTENSIONS_ENABLED  │
       │    (pg_trgm, unaccent) │
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │ 2. TSVECTOR_GENERATED  │
       │    (STORED col + Dict) │
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │ 3. INDEX_OPTIMIZED     │
       │    (GIN fastupdate cfg)│
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │ 4. SARGABLE_QUERIES    │
       │    (websearch & % op)  │
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │ 5. HYBRID_RRF_RANKED   │
       │    (Reciprocal Fusion) │
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │ 6. BUFFER_SENTINEL_OK  │
       │ (0 temp spills in CI)  │
       └────────────────────────┘
```

### 5.2 6-Gate Machine-Verifiable Definition of Done (DoD)

| Gate | Target Metric / Requirement | Verification Command / Metric |
| :--- | :--- | :--- |
| **Gate 1: Zero Run-time Stemming** | 100% of FTS queries target `STORED GENERATED` `tsvector` columns | `grep -rn "to_tsvector(" src/` returns 0 query-level dynamic invocations |
| **Gate 2: Safe tsquery Ingestion** | All user queries parsed via `websearch_to_tsquery` or `plainto_tsquery` | Static AST audit passes; raw `to_tsquery($1)` without escape is forbidden |
| **Gate 3: Sargable Trigrams** | All fuzzy matches use `%`, `<%`, or `<->` operators | `EXPLAIN (BUFFERS)` displays `Bitmap Index Scan` on trigram index, 0 `Seq Scan` |
| **Gate 4: Write Stall Elimination** | GIN pending list size bounded $< 16\text{MB}$ or `fastupdate = off` on OLTP | `auditGinIndexHealth()` confirms 0 bloated pending lists |
| **Gate 5: Hybrid RRF Invariance** | Semantic + Lexical fused via Reciprocal Rank Fusion ($k=60$) | RRF rank sensitivity test passes; zero raw score summation |
| **Gate 6: Zero Buffer Spills** | Search queries execute strictly in RAM without disk spill | `EXPLAIN (ANALYZE, BUFFERS)` confirms `TempWrittenBlocks == 0` |
