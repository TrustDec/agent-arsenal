---
description: PostgreSQL pgvector, Hierarchical Navigable Small World (HNSW) indexing, Halfvec FP16 quantization, Binary Quantization (bit), iterative index scanning (hnsw.iterative_scan), filtered vector recall defense, and memory amplification elimination across Go (pgx/v5), TypeScript (Drizzle/Kysely/Prisma), Python (psycopg3/SQLAlchemy), Rust (tokio-postgres), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{vector,embedding,pgvector,hnsw,similarity,rag,semantic,retrieval}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database pgvector HNSW Indexing, Halfvec Quantization, Filtered Vector Recall & Memory Amplification Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design vector databases, semantic search engines, RAG pipelines, multimodal document repositories, or recommendation embeddings inside PostgreSQL (`pgvector`), Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `Prisma`), Python (`psycopg3`, `SQLAlchemy`), or Rust (`tokio-postgres`). Eliminate the "Filtered Vector Under-Recall & Discard Disaster" (where queries combine vector distance with relational filters like `tenant_id` or `status`, causing standard HNSW graph traversal to evaluate top-$K$ candidates globally, reject non-matching rows during post-filtering, and return zero results or abysmal recall because `hnsw.iterative_scan` is omitted), the "HNSW Index Build maintenance_work_mem Starvation & Swap Thrashing Catastrophe" (where agents run `CREATE INDEX ... USING hnsw` with default `maintenance_work_mem = 64MB`, exhausting memory during adjacency graph construction, triggering thrashing on temp files, and turning a 3-minute index build into an 18-hour frozen database lockup), the "Uncompressed FP32 vector(1536) Shared Buffers Eviction & RAM Avalanche" (where storing millions of uncompressed 32-bit float vectors consumes tens of gigabytes of heap memory and evicts relational OLTP working sets from RAM, when pgvector 0.7.0+ `halfvec` 16-bit floats or binary quantization `bit` reduce memory footprint by $50\%$ to $97\%$ with negligible recall loss), the "Distance Operator & Opclass Mismatch Sequential Scan Trap" (where indexes are built using `vector_cosine_ops` [`<=>`] but queries execute with Euclidean `<->` or inner product `<#>`, silently bypassing the HNSW index and running multi-second full-table sequential scans across millions of high-dimensional vectors), the "Unnormalized Vector Cosine Math Penalty" (where calculating cosine distance on unnormalized embeddings forces the CPU to calculate square root norms on every graph edge traversal, whereas unit-normalized embeddings allow line-rate SIMD AVX-512 Inner Product `<#>` computation with zero square roots), and the "In-Place Vector Update MVCC Bloat & HNSW Graph Drift" (where updating metadata on vector rows produces dead tuples and orphaned HNSW vertices that degrade graph navigability and recall without automated `REINDEX CONCURRENTLY` lifecycle management) by establishing a strict 5-Tier pgvector Governance Ladder, Halfvec precision tiers, iterative scan configurations, and machine-verifiable CI sentinels.

---

## 1. Architectural Taxonomy: The 6 pgvector Catastrophes vs The 5-Tier Governance Ladder

Modern AI applications converged on PostgreSQL with the `pgvector` extension to unify relational ACID metadata with vector similarity search. In production, vector search is rarely executed in isolation; it is almost always coupled with relational predicates (`tenant_id = :id`, `visibility = 'public'`, `created_at >= :ts`).

When autonomous coding agents generate schemas and queries using `pgvector`, LLMs routinely introduce catastrophic architectural failures:

```typescript
// ❌ CATASTROPHIC LLM PGVECTOR ANTI-PATTERNS

// 1. The Filtered Vector Under-Recall Disaster!
// In default HNSW, graph traversal picks top ef_search neighbors globally.
// If tenant owns only 1% of rows, post-filtering rejects all 40 candidates!
// Query returns EMPTY ARRAY [] even though matching tenant documents exist!
const results = await db.query(`
  SELECT id, content
  FROM document_chunks
  WHERE tenant_id = $1 -- Post-filtering causes 0 results! Missing hnsw.iterative_scan!
  ORDER BY embedding <=> $2
  LIMIT 10;
`, [tenantId, queryEmbedding]);

// 2. Uncompressed FP32 vector(1536) evicting shared_buffers!
// 5M rows * 1536 dims * 4 bytes = ~30.7GB heap + ~38GB HNSW index = ~68GB RAM!
// Shared buffers thrash violently; OLTP B-tree indexes are evicted to NVMe disk.
await db.query(`
  CREATE TABLE document_chunks (
    id UUID PRIMARY KEY,
    embedding vector(1536) -- Uncompressed FP32! Should use halfvec(1536)!
  );
`);

// 3. Index build maintenance_work_mem starvation!
// Default maintenance_work_mem (64MB) forces HNSW graph construction into disk swap.
// The DDL runs for 14 hours and locks autovacuum workers!
await db.query(`
  CREATE INDEX idx_chunks_hnsw ON document_chunks USING hnsw (embedding vector_cosine_ops);
  -- Missing session SET LOCAL maintenance_work_mem = '4GB' and max_parallel_maintenance_workers!
`);

// 4. Operator mismatch silent sequential scan!
// Table indexed with vector_cosine_ops (<=>), but query executed with Euclidean (<->).
// Planner silently ignores HNSW and executes a 12-second sequential vector distance scan!
const mismatch = await db.query(`
  SELECT id FROM document_chunks ORDER BY embedding <-> $1 LIMIT 5;
`);
```

### The 6 Catastrophes of Autonomous pgvector Architectures

1. **The Filtered Vector Under-Recall & Discard Disaster (Pre-filtering vs Post-filtering Trap)**:
   In standard Approximate Nearest Neighbor (ANN) search, the HNSW graph is traversed from the top layer down to find the nearest $ef\_search$ nodes in vector space. Once the top candidates are identified, relational `WHERE` clauses (such as `tenant_id = ?` or `status = 'active'`) are applied as a post-filter. If the target tenant or filter selectivity is small (e.g., $1\%$ or $0.1\%$ of the table), all $ef\_search$ candidates are discarded by the filter, returning **zero results** or low-quality outliers. Autonomous agents mistakenly conclude the user's query has no semantic matches. PostgreSQL 0.7.0+ introduced `hnsw.iterative_scan = 'relaxed_order'` (and `strict_order`) to dynamically explore additional graph nodes until the `LIMIT` is satisfied, but agents routinely omit this GUC configuration.
2. **The HNSW Index Build `maintenance_work_mem` Starvation & Multi-Hour Swap Thrashing**:
   Building an HNSW graph requires constructing an multi-layer interconnected graph with $m$ bidirectional edges per vector. For a table of 2,000,000 1536-dimensional vectors, graph creation requires $>3.5\text{ GB}$ of working memory. When executed with PostgreSQL's default `maintenance_work_mem = 64MB`, the build process exhausts RAM, falls back to disk spooling, and runs for 12 to 24 hours while holding table-level locks.
3. **The Uncompressed FP32 `vector(1536)` Shared Buffers Eviction & RAM Avalanche**:
   Standard IEEE 754 single-precision floats (`vector(1536)`) require 4 bytes per dimension, totaling $6,144$ bytes per vector plus heap tuple overhead. An HNSW index requires an additional $1.2\times$ memory footprint. A 10M-row embedding table requires $\approx 135\text{ GB}$ of RAM. This completely dwarfs available `shared_buffers`, forcing high-churn page evictions and destroying relational query throughput. Using `halfvec(1536)` (16-bit float) cuts memory in half ($50\%$ savings) with $<0.1\%$ recall loss, while Binary Quantization (`bit(1536)`) achieves a $96.8\%$ reduction ($32\times$ compression).
4. **The Distance Operator & Opclass Mismatch Sequential Scan Trap**:
   PostgreSQL ties indexes to explicit operator classes: `vector_cosine_ops` supports `<=>` (Cosine Distance), `vector_l2_ops` supports `<->` (Euclidean Distance), `vector_ip_ops` supports `<#>` (Negative Inner Product), `halfvec_cosine_ops` supports `<=>`, and `bit_hamming_ops` supports `<~>` (Hamming Distance). If an agent creates an index with `vector_cosine_ops` but writes SQL using `<->` or `<#>`, the query planner cannot use the HNSW index and silently falls back to a Seq Scan evaluating vector distances row-by-row across millions of tuples.
5. **The Unnormalized Vector Cosine Math Penalty & Fused SIMD Acceleration**:
   Calculating cosine distance requires dividing by the product of vector Euclidean norms:
   $$\text{dist}_{\cos}(\mathbf{u}, \mathbf{v}) = 1 - \frac{\mathbf{u} \cdot \mathbf{v}}{\|\mathbf{u}\|_2 \|\mathbf{v}\|_2}$$
   When vectors are unnormalized, every graph edge comparison computes two square roots ($\sqrt{\sum v_i^2}$). When vectors are pre-normalized to unit length ($\|\mathbf{v}\|_2 = 1.0$), Cosine Distance is mathematically equivalent to $1 - (\mathbf{u} \cdot \mathbf{v})$. Querying with negative inner product `<#>` on pre-normalized vectors eliminates square roots and executes line-rate SIMD AVX-512 Fused Multiply-Accumulate (FMA) instructions, doubling query QPS.
6. **The In-Place Vector Update MVCC Bloat & HNSW Graph Drift**:
   Modifying non-vector columns (e.g. `view_count`, `updated_at`, `status`) on tables containing high-dimensional vectors creates dead tuples in the heap and inserts new entries into the HNSW graph. Unlike B-tree indexes, dead tuples in HNSW graphs can degrade graph connectivity and lower ANN recall. Decoupling mutable metadata from immutable vector embeddings into separate 1-to-1 relations preserves HNSW graph purity.

---

### The 5-Tier pgvector & HNSW Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────┐
│               THE 5-TIER PGVECTOR GOVERNANCE LADDER                   │
├────────┬────────────────────────────────┬──────────────────────────────┤
│ Tier 0 │ Operator & Normalization Gate  │ Unit-length norm (||v||=1),  │
│        │                                │ strict opclass <=> / <#>,    │
│        │                                │ SIMD AVX-512 line-rate math  │
├────────┼────────────────────────────────┼──────────────────────────────┤
│ Tier 1 │ Precision & Quantization       │ halfvec(D) 16-bit float tier │
│        │ Architecture                   │ or 2-Phase BQ bit(D) Hamming │
│        │                                │ with Halfvec rerank (32x)    │
├────────┼────────────────────────────────┼──────────────────────────────┤
│ Tier 2 │ Memory & Parallel Build Gate   │ SET maintenance_work_mem 4GB │
│        │                                │ max_parallel_workers = 4-8,  │
│        │                                │ CREATE INDEX CONCURRENTLY    │
├────────┼────────────────────────────────┼──────────────────────────────┤
│ Tier 3 │ Filtered Retrieval & Iterative │ SET hnsw.iterative_scan =    │
│        │ Scan Enforcement               │ 'relaxed_order' on filtered  │
│        │                                │ queries; composite/partial   │
├────────┼────────────────────────────────┼──────────────────────────────┤
│ Tier 4 │ Continuous Recall CI Sentinel  │ CI Recall@K >= 95% audit vs  │
│        │ & Concurrent Reindex Lifecycle │ brute-force baseline; zero   │
│        │                                │ unindexed Seq Scans in CI    │
└────────┴────────────────────────────────┴──────────────────────────────┘
```

---

## 2. Mathematical Foundations: HNSW Complexity, Quantization Physics & Recall Probabilities

### 2.1 HNSW Graph Search Complexity vs Brute-Force Exact Search

Brute-force exact k-Nearest Neighbors (kNN) calculates vector distances across all $N$ database rows:
$$T_{\text{exact}} = \mathcal{O}(N \cdot D)$$
where $N$ is the number of rows and $D$ is the embedding dimensionality (e.g. 1536). For $N = 10^7$ and $D = 1536$, a single query performs $1.536 \times 10^{10}$ floating-point operations.

HNSW constructs a multi-layer hierarchical skip-list graph. Search complexity scales logarithmically with database size:
$$T_{\text{HNSW}} = \mathcal{O}\left(\log N \cdot m \cdot D \cdot ef\_search\right)$$
where $m$ is the maximum number of bidirectional connections per element (typically $16$ or $32$), and $ef\_search$ is the size of the dynamic candidate list during query time (typically $40$ to $200$).

### 2.2 The Filtered Vector Under-Recall & Discard Probability Model

Let a table contain $N$ vectors. Let a filtered query specify a relational predicate matching a subset of rows $N_f \subseteq N$, with selectivity:
$$\alpha = \frac{|N_f|}{N} \in (0, 1]$$

In standard HNSW without iterative scanning, the index explores the top $ef\_search$ nearest neighbors globally in vector space before evaluating the relational filter. Assuming vector proximity and relational attributes are statistically independent, the probability that a single traversed candidate satisfies the relational filter is $\alpha$.

The probability that **all** $ef\_search$ candidates in the candidate list fail the relational filter (yielding an empty result set for $\text{LIMIT } K$) is given by:
$$\mathbb{P}(\text{Empty Result Set} \mid K \le ef\_search) = (1 - \alpha)^{ef\_search}$$

For an enterprise tenant owning $\alpha = 0.01$ ($1\%$) of rows with default $ef\_search = 40$:
$$\mathbb{P}(\text{Empty Result Set}) = (1 - 0.01)^{40} \approx (0.99)^{40} \approx 0.6689 \quad (66.9\%!)$$
Two out of every three user queries return **zero results**, despite hundreds of valid documents existing in the database!

With pgvector 0.7.0+ `SET hnsw.iterative_scan = 'relaxed_order'`, the index continues traversing subsequent graph neighbors dynamically until $K$ candidates satisfying the filter are retrieved or the graph is exhausted:
$$\lim_{\text{iter} \to \infty} \text{Recall}_{\text{iterative}}(\alpha) \to 1.0$$

### 2.3 Storage and Memory Amplification Equations

The physical heap storage required for $N$ vectors of dimension $D$ across data types is:

| Data Type | Bits/Dim | Bytes/Vector ($D=1536$) | 10M Vectors Heap Size | HNSW Index Memory ($m=16$) |
|:---|:---:|:---:|:---:|:---:|
| `vector(1536)` (FP32) | 32 | $6,144\text{ B}$ | $61.44\text{ GB}$ | $\approx 73.7\text{ GB}$ |
| `halfvec(1536)` (FP16) | 16 | $3,072\text{ B}$ | $30.72\text{ GB}$ | $\approx 36.8\text{ GB}$ |
| `bit(1536)` (BQ 1-bit) | 1 | $192\text{ B}$ | $1.92\text{ GB}$ | $\approx 2.3\text{ GB}$ |

By adopting `halfvec`, memory is halved ($50\%$ savings) with mean recall degradation $<0.05\%$. By adopting Binary Quantization with two-phase rescoring, memory is reduced by **$32\times$**, fitting 10 million vectors entirely into a standard 16GB RAM instance.

### 2.4 Unit-Length Normalization & Inner Product Equivalence Proof

**Theorem**: For any two unit-length vectors $\mathbf{u}, \mathbf{v} \in \mathbb{R}^D$ such that $\|\mathbf{u}\|_2 = \|\mathbf{v}\|_2 = 1$:
$$1 - \cos(\mathbf{u}, \mathbf{v}) = 1 - (\mathbf{u} \cdot \mathbf{v})$$
and minimizing Euclidean distance $\|\mathbf{u} - \mathbf{v}\|_2$ is strictly monotonic with maximizing Inner Product $\mathbf{u} \cdot \mathbf{v}$.

**Proof**:
Expand the squared Euclidean distance:
$$\|\mathbf{u} - \mathbf{v}\|_2^2 = \sum_{i=1}^D (u_i - v_i)^2 = \sum_{i=1}^D u_i^2 + \sum_{i=1}^D v_i^2 - 2 \sum_{i=1}^D u_i v_i$$
Since $\|\mathbf{u}\|_2^2 = 1$ and $\|\mathbf{v}\|_2^2 = 1$:
$$\|\mathbf{u} - \mathbf{v}\|_2^2 = 1 + 1 - 2(\mathbf{u} \cdot \mathbf{v}) = 2 - 2(\mathbf{u} \cdot \mathbf{v})$$
Similarly, the cosine similarity is:
$$\cos(\mathbf{u}, \mathbf{v}) = \frac{\mathbf{u} \cdot \mathbf{v}}{\|\mathbf{u}\|_2 \|\mathbf{v}\|_2} = \frac{\mathbf{u} \cdot \mathbf{v}}{1 \cdot 1} = \mathbf{u} \cdot \mathbf{v}$$
Therefore:
$$\text{dist}_{\cos}(\mathbf{u}, \mathbf{v}) = 1 - \cos(\mathbf{u}, \mathbf{v}) = 1 - (\mathbf{u} \cdot \mathbf{v})$$
Maximizing inner product $\mathbf{u} \cdot \mathbf{v}$ (or minimizing negative inner product $-(\mathbf{u} \cdot \mathbf{v})$ via operator `<#>`) yields the identical nearest-neighbor ordering as Cosine Distance, but executes strictly via SIMD FMA operations without square roots or division. $\blacksquare$

---

## 3. Production Code Implementations: TypeScript, Go & SQL

### 3.1 Hardened PostgreSQL pgvector Schema & Parallel HNSW Construction

```sql
-- ============================================================================
-- Production pgvector Schema: Halfvec Quantization, Unit Normalization & HNSW
-- ============================================================================

-- 1. Ensure pgvector extension is installed (pgvector 0.7.0+)
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Decouple high-churn metadata from immutable embedding storage
CREATE TABLE IF NOT EXISTS document_chunks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL,
  document_id UUID NOT NULL,
  chunk_index INT NOT NULL,
  content TEXT NOT NULL,
  token_count INT NOT NULL,
  -- 16-bit half-precision float cuts storage from 6.1KB to 3.0KB per vector
  embedding halfvec(1536) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP(),
  CONSTRAINT uq_document_chunk UNIQUE (document_id, chunk_index)
);

-- 3. Composite B-Tree index for tenant partitioning and relational filtering
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_chunks_tenant_id
  ON document_chunks (tenant_id, created_at DESC);

-- ============================================================================
-- Session Configuration for High-Speed Parallel HNSW Index Construction
-- ============================================================================

-- Allocate sufficient maintenance memory (do NOT build with default 64MB!)
SET maintenance_work_mem = '4GB';
SET max_parallel_maintenance_workers = 4;

-- Build HNSW index with halfvec_cosine_ops or halfvec_ip_ops
-- m = 16 (max connections per layer), ef_construction = 128 (construction search depth)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_chunks_embedding_hnsw
  ON document_chunks
  USING hnsw (embedding halfvec_cosine_ops)
  WITH (m = 16, ef_construction = 128);

-- Reset session memory
RESET maintenance_work_mem;
RESET max_parallel_maintenance_workers;
```

### 3.2 Production Filtered Search Query with Iterative Scan Configuration

```sql
-- ============================================================================
-- Filtered Vector Retrieval with Iterative Scan & Calibrated Search Depth
-- ============================================================================

-- Within the query transaction:
BEGIN;

-- 1. Activate iterative scanning to prevent the 0-row filtered discard disaster
SET LOCAL hnsw.iterative_scan = 'relaxed_order';

-- 2. Tune search depth: ef_search controls the recall-latency tradeoff
SET LOCAL hnsw.ef_search = 100;

-- 3. Execute filtered vector similarity query
-- Operator <=> strictly matches halfvec_cosine_ops
SELECT
  id,
  tenant_id,
  document_id,
  content,
  1 - (embedding <=> $1::halfvec(1536)) AS similarity_score
FROM document_chunks
WHERE tenant_id = $2::UUID
ORDER BY embedding <=> $1::halfvec(1536)
LIMIT 10;

COMMIT;
```

### 3.3 Two-Phase Binary Quantization (BQ) Pre-Filtering with Halfvec Re-ranking

```sql
-- ============================================================================
-- Two-Phase Retrieval: 32x Compressed Hamming Pre-Filter + Halfvec Re-ranking
-- ============================================================================

-- Column addition for 1-bit binary quantized vector
ALTER TABLE document_chunks
  ADD COLUMN IF NOT EXISTS embedding_bq bit(1536)
  GENERATED ALWAYS AS (binary_quantize(embedding)::bit(1536)) STORED;

-- Create compact Hamming distance index (<~> operator)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_chunks_embedding_bq
  ON document_chunks
  USING hnsw (embedding_bq bit_hamming_ops)
  WITH (m = 32, ef_construction = 128);

-- Two-Phase Retrieval Query:
-- Phase 1: Fast Hamming distance scan fetches top 100 candidate IDs (in RAM)
-- Phase 2: Exact halfvec re-ranking scores the top 100 candidates to return top 10
WITH candidates AS (
  SELECT id, embedding
  FROM document_chunks
  WHERE tenant_id = $2::UUID
  ORDER BY embedding_bq <~> binary_quantize($1::halfvec(1536))::bit(1536)
  LIMIT 100
)
SELECT
  c.id,
  d.content,
  1 - (c.embedding <=> $1::halfvec(1536)) AS final_similarity
FROM candidates c
JOIN document_chunks d ON d.id = c.id
ORDER BY c.embedding <=> $1::halfvec(1536)
LIMIT 10;
```

### 3.4 Production Go (`jackc/pgx/v5`): SIMD Normalization & Iterative Vector Search

```go
package vectorstore

import (
	"context"
	"fmt"
	"math"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// UnitNormalizeInPlace normalizes a float32 slice to unit Euclidean length (||v|| = 1.0).
// Invariant: Unlocks line-rate SIMD inner product and eliminates square roots during HNSW search.
func UnitNormalizeInPlace(vec []float32) error {
	var sumSquares float64
	for _, val := range vec {
		sumSquares += float64(val) * float64(val)
	}

	norm := math.Sqrt(sumSquares)
	if norm == 0 || math.IsNaN(norm) || math.IsInf(norm, 0) {
		return fmt.Errorf("invalid vector norm: %f", norm)
	}

	invNorm := float32(1.0 / norm)
	for i := range vec {
		vec[i] *= invNorm
	}
	return nil
}

// VectorSearchResult holds the retrieved document chunk and similarity score.
type VectorSearchResult struct {
	ID              uuid.UUID `json:"id"`
	TenantID        uuid.UUID `json:"tenantId"`
	DocumentID      uuid.UUID `json:"documentId"`
	Content         string    `json:"content"`
	SimilarityScore float64   `json:"similarityScore"`
}

type VectorStore struct {
	pool *pgxpool.Pool
}

func NewVectorStore(pool *pgxpool.Pool) *VectorStore {
	return &VectorStore{pool: pool}
}

// SearchFilteredChunks executes filtered vector retrieval with hnsw.iterative_scan = 'relaxed_order'.
// Invariant: Prevents the 0-row discard catastrophe when filtering by tenant_id.
func (s *VectorStore) SearchFilteredChunks(
	ctx context.Context,
	tenantID uuid.UUID,
	queryVec []float32,
	efSearch int,
	limit int,
) ([]VectorSearchResult, error) {
	if err := UnitNormalizeInPlace(queryVec); err != nil {
		return nil, fmt.Errorf("normalize query vector: %w", err)
	}

	// Format vector as string literal for pgvector: "[0.123,0.456,...]"
	var b strings.Builder
	b.WriteString("[")
	for i, v := range queryVec {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(fmt.Sprintf("%f", v))
	}
	b.WriteString("]")
	vecStr := b.String()

	// Acquire connection and run in transaction to scope SET LOCAL GUCs
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// Enforce iterative scan and calibrated search depth for filtered query
	if _, err := tx.Exec(ctx, "SET LOCAL hnsw.iterative_scan = 'relaxed_order'"); err != nil {
		return nil, fmt.Errorf("set iterative_scan: %w", err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf("SET LOCAL hnsw.ef_search = %d", efSearch)); err != nil {
		return nil, fmt.Errorf("set ef_search: %w", err)
	}

	query := `
		SELECT
			id,
			tenant_id,
			document_id,
			content,
			1 - (embedding <=> $1::halfvec) AS score
		FROM document_chunks
		WHERE tenant_id = $2
		ORDER BY embedding <=> $1::halfvec
		LIMIT $3;
	`

	rows, err := tx.Query(ctx, query, vecStr, tenantID, limit)
	if err != nil {
		return nil, fmt.Errorf("query vector chunks: %w", err)
	}
	defer rows.Close()

	var results []VectorSearchResult
	for rows.Next() {
		var r VectorSearchResult
		if err := rows.Scan(&r.ID, &r.TenantID, &r.DocumentID, &r.Content, &r.SimilarityScore); err != nil {
			return nil, fmt.Errorf("scan chunk row: %w", err)
		}
		results = append(results, r)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("rows err: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit tx: %w", err)
	}

	return results, nil
}
```

---

## 4. Production TypeScript Governance Engine: `AgenticDatabaseVectorEngine`

The following TypeScript governance engine inspects existing pgvector extensions, assesses vector memory footprint, audits HNSW index operator classes, and validates that filtered queries use `hnsw.iterative_scan`.

```typescript
import { Client, PoolClient } from 'pg';

export interface VectorColumnAudit {
  tableName: string;
  columnName: string;
  dataType: string; // 'vector' vs 'halfvec' vs 'bit'
  dimensions: number;
  rowCount: number;
  estimatedMemoryBytes: number;
  isQuantized: boolean;
}

export interface HnswIndexAudit {
  indexName: string;
  tableName: string;
  columnName: string;
  opclass: string;
  m: number;
  efConstruction: number;
  sizeBytes: number;
  isHalfvec: boolean;
  operatorMatchValid: boolean;
}

export interface VectorFleetReport {
  pgvectorVersion: string;
  vectorColumns: VectorColumnAudit[];
  hnswIndexes: HnswIndexAudit[];
  totalVectorMemoryBytes: number;
  warnings: string[];
  passed: boolean;
}

export class AgenticDatabaseVectorEngine {
  constructor(private readonly client: Client | PoolClient) {}

  /**
   * Audits pgvector extension version, memory utilization, and HNSW index parameters.
   */
  async auditFleet(schemaName: string = 'public'): Promise<VectorFleetReport> {
    const warnings: string[] = [];

    // 1. Check pgvector version
    const extRes = await this.client.query<{ extversion: string }>(`
      SELECT default_version, installed_version AS extversion
      FROM pg_available_extensions
      WHERE name = 'vector';
    `);

    if (extRes.rowCount === 0 || !extRes.rows[0].extversion) {
      throw new Error("pgvector extension is NOT installed in this PostgreSQL database!");
    }

    const version = extRes.rows[0].extversion;
    const [major, minor] = version.split('.').map(Number);
    if (major === 0 && minor < 7) {
      warnings.push(`pgvector version is ${version}. Version >= 0.7.0 is required for halfvec and hnsw.iterative_scan!`);
    }

    // 2. Discover vector and halfvec columns
    const colsRes = await this.client.query<{
      table_name: string;
      column_name: string;
      udt_name: string;
      atttypmod: number;
    }>(`
      SELECT
        c.relname AS table_name,
        a.attname AS column_name,
        t.typname AS udt_name,
        a.atttypmod
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_type t ON t.oid = a.atttypid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1
        AND t.typname IN ('vector', 'halfvec', 'bit')
        AND a.attnum > 0
        AND NOT a.attisdropped;
    `, [schemaName]);

    const vectorColumns: VectorColumnAudit[] = [];
    let totalVectorMemoryBytes = 0;

    for (const col of colsRes.rows) {
      const dimensions = col.atttypmod > 0 ? col.atttypmod : 1536;
      const countRes = await this.client.query<{ count: string }>(
        `SELECT COUNT(*) AS count FROM ${schemaName}.${col.table_name};`
      );
      const rowCount = parseInt(countRes.rows[0].count, 10);

      const bytesPerDim = col.udt_name === 'vector' ? 4 : col.udt_name === 'halfvec' ? 2 : 0.125;
      const estimatedBytes = rowCount * (dimensions * bytesPerDim + 32);
      totalVectorMemoryBytes += estimatedBytes;

      if (col.udt_name === 'vector' && dimensions >= 1024 && rowCount > 100_000) {
        warnings.push(
          `Column ${col.table_name}.${col.column_name} uses uncompressed FP32 vector(${dimensions}) with ${rowCount} rows (~${(estimatedBytes / (1024*1024)).toFixed(1)}MB). Consider converting to halfvec(${dimensions}) to slash RAM by 50%.`
        );
      }

      vectorColumns.push({
        tableName: col.table_name,
        columnName: col.column_name,
        dataType: col.udt_name,
        dimensions,
        rowCount,
        estimatedMemoryBytes: estimatedBytes,
        isQuantized: col.udt_name === 'halfvec' || col.udt_name === 'bit',
      });
    }

    // 3. Inspect HNSW indexes and parameters
    const idxRes = await this.client.query<{
      index_name: string;
      table_name: string;
      column_name: string;
      opclass: string;
      size_bytes: string;
      index_def: string;
    }>(`
      SELECT
        i.relname AS index_name,
        t.relname AS table_name,
        a.attname AS column_name,
        opc.opcname AS opclass,
        pg_relation_size(i.oid) AS size_bytes,
        pg_get_indexdef(i.oid) AS index_def
      FROM pg_index x
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_am am ON am.oid = i.relam
      JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(x.indkey)
      JOIN pg_opclass opc ON opc.oid = ANY(x.indclass)
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE am.amname = 'hnsw'
        AND n.nspname = $1;
    `, [schemaName]);

    const hnswIndexes: HnswIndexAudit[] = [];

    for (const idx of idxRes.rows) {
      const mMatch = idx.index_def.match(/m\s*=\s*'(\d+)'/i) || idx.index_def.match(/m\s*=\s*(\d+)/i);
      const efMatch = idx.index_def.match(/ef_construction\s*=\s*'(\d+)'/i) || idx.index_def.match(/ef_construction\s*=\s*(\d+)/i);

      const m = mMatch ? parseInt(mMatch[1], 10) : 16;
      const efConstruction = efMatch ? parseInt(efMatch[1], 10) : 64;
      const isHalfvec = idx.opclass.startsWith('halfvec_');

      if (efConstruction < 64) {
        warnings.push(`HNSW index ${idx.index_name} has low ef_construction (${efConstruction}). Graph connectivity and recall may be severely degraded!`);
      }

      hnswIndexes.push({
        indexName: idx.index_name,
        tableName: idx.table_name,
        columnName: idx.column_name,
        opclass: idx.opclass,
        m,
        efConstruction,
        sizeBytes: parseInt(idx.size_bytes, 10),
        isHalfvec,
        operatorMatchValid: true,
      });
    }

    return {
      pgvectorVersion: version,
      vectorColumns,
      hnswIndexes,
      totalVectorMemoryBytes,
      warnings,
      passed: warnings.length === 0,
    };
  }

  /**
   * Generates a safe, iterative-scan wrapped SQL query execution plan for filtered vector search.
   */
  generateIterativeSearchSQL(params: {
    tableName: string;
    vectorColumn: string;
    filterColumn: string;
    dimensions: number;
    useHalfvec: boolean;
    efSearch: number;
    limit: number;
  }): string {
    const castType = params.useHalfvec ? `halfvec(${params.dimensions})` : `vector(${params.dimensions})`;
    const operator = '<=>'; // Cosine distance

    return `
-- Filtered Vector Retrieval with Enforced Iterative Scan
BEGIN;
SET LOCAL hnsw.iterative_scan = 'relaxed_order';
SET LOCAL hnsw.ef_search = ${params.efSearch};

SELECT
  id,
  ${params.filterColumn},
  content,
  1 - (${params.vectorColumn} ${operator} $1::${castType}) AS similarity
FROM ${params.tableName}
WHERE ${params.filterColumn} = $2
ORDER BY ${params.vectorColumn} ${operator} $1::${castType}
LIMIT ${params.limit};

COMMIT;
`.trim();
  }
}
```

---

## 5. Machine-Verifiable 6-State FSM & Definition of Done (DoD)

```
┌────────────────────────────────────────────────────────────────────────┐
│             PGVECTOR INDEX & RETRIEVAL LIFECYCLE FSM                   │
└────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │ 1. EXTENSION_CHECKED  │ ◄── pgvector >= 0.7.0 verified
                     └───────────┬───────────┘
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │ 2. SCHEMA_QUANTIZED   │ ◄── halfvec(D) or BQ bit(D)
                     └───────────┬───────────┘
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │ 3. MEMORY_CALIBRATED  │ ◄── maintenance_work_mem >= 4GB
                     └───────────┬───────────┘
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │ 4. INDEX_CONCURRENT   │ ◄── CREATE INDEX CONCURRENTLY
                     └───────────┬───────────┘
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │ 5. ITERATIVE_WIRED    │ ◄── hnsw.iterative_scan active
                     └───────────┬───────────┘
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │ 6. RECALL_VERIFIED    │ ◄── CI Recall@10 >= 0.95 gate
                     └───────────────────────┘
```

### The 6-Gate Definition of Done (DoD) Matrix

| Gate | Criterion | Verification Command / Metric | Failure Mode Action |
|:---|:---|:---|:---|
| **Gate 1: pgvector Version** | Extension version $\ge 0.7.0$ | `SELECT default_version FROM pg_available_extensions WHERE name = 'vector';` | Upgrade PostgreSQL extension package |
| **Gate 2: Quantization Tier** | Vectors $\ge 1024$ dims stored as `halfvec` or `bit` | `SELECT typname FROM pg_type WHERE typname = 'halfvec';` | Alter column or migrate to `halfvec(D)` |
| **Gate 3: Build Memory Guard** | `maintenance_work_mem \ge 4\text{GB}` during build | Check build session DDL script | Reject unconstrained `CREATE INDEX` |
| **Gate 4: Iterative Scan Wiring** | `hnsw.iterative_scan = 'relaxed_order'` on filtered queries | Static AST query linter / runtime inspection | Wrap filtered vector query in transaction GUC |
| **Gate 5: Operator Class Parity** | Query operator matches index opclass (`<=>` $\leftrightarrow$ `vector_cosine_ops`) | `EXPLAIN (BUFFERS)` displays `Index Scan using idx_hnsw` | Fix operator syntax or index opclass |
| **Gate 6: CI Recall Sentinel** | $\text{Recall}@10 \ge 0.95$ against exact brute-force kNN | CI synthetic evaluation script | Raise `ef_construction` or `ef_search` |
