---
description: Vector databases, embeddings, semantic retrieval, HNSW index tuning, quantization (SQ/PQ), hybrid search with Reciprocal Rank Fusion, pgvector, and Qdrant production invariants
globs: **/*{vector,embedding,qdrant,pgvector,milvus,chroma,pinecone,rerank}*.*,**/embeddings/**,**/vector/**,**/retrievers/**
alwaysApply: false
---

# Vector Databases, Embeddings & Semantic Retrieval Production Invariants

> Add these rules to your project when architecting, indexing, querying, or scaling vector databases, embedding pipelines, semantic search engines, or hybrid RAG retrieval systems (pgvector, Qdrant, Milvus, Chroma, Pinecone, Cohere, BGE, Voyage).

---

## 1. Distance Metrics, Metric Matching & Pre-Normalization Invariants
Vector distance metrics determine how similarity is computed in high-dimensional embedding space: Cosine Distance (`1 - cosine_similarity`), Dot Product / Inner Product (`<#>`, `ip`), and Euclidean / L2 Distance (`<->`, `l2`).

- ❌ **THE UNNORMALIZED COSINE COMPUTATION OVERHEAD TRAP**:
  - Calculating Cosine Distance on unnormalized vectors requires vector magnitude square root calculations ($\sqrt{\sum v_i^2}$) on every single distance comparison across millions of nodes during HNSW graph traversal. This slashes query throughput (QPS) by 2x to 3x and incurs severe CPU overhead:
    $$\cos(\theta) = \frac{\mathbf{u} \cdot \mathbf{v}}{\|\mathbf{u}\|_2 \|\mathbf{v}\|_2} = \frac{\sum u_i v_i}{\sqrt{\sum u_i^2} \sqrt{\sum v_i^2}}$$
- ✅ **The Pre-Normalized Unit Vector Invariant**:
  - ALWAYS normalize vectors to unit length ($\|\mathbf{v}\|_2 = 1.0$) at embedding generation time before inserting into the database:
    ```python
    import numpy as np

    def normalize_embedding(vec: list[float]) -> list[float]:
        arr = np.array(vec, dtype=np.float32)
        norm = np.linalg.norm(arr)
        if norm == 0:
            return vec
        return (arr / norm).tolist()
    ```
  - When vectors are unit-normalized, **Cosine Distance is mathematically identical to Negative Inner Product**:
    $$1 - \cos(\theta) = 1 - (\mathbf{u} \cdot \mathbf{v})$$
  - Query using **Inner Product / Dot Product** (`<#>` in pgvector, `Distance.DOT` in Qdrant) instead of Cosine. Inner product requires only fused multiply-add (FMA) CPU/SIMD instructions with zero square roots, yielding up to 300% higher QPS.

---

## 2. HNSW Index Construction & Graph Topology Parameter Tuning
Hierarchical Navigable Small World (HNSW) graphs provide approximate nearest neighbor (ANN) search with sub-linear logarithmic time complexity $O(\log N)$.

- ❌ **THE UNDER-RECALL / OOM PARAMETER TRAP**:
  - Using low default values ($M=16, \text{ef\_construction}=64$) yields poor recall (<85%) on high-dimensional vectors (e.g., 1536 or 3072 dimensions from OpenAI or Cohere).
  - Setting excessively high $M$ ($M=128$) without calculating RAM leads to out-of-memory (OOM) crashes during graph construction.
- ✅ **Production HNSW Parameter Tuning Matrix**:
  - **$M$ (Bi-directional links per node)**:
    - 384–768 dimensions: set $M = 16 \sim 24$.
    - 1536–3072 dimensions: set $M = 32 \sim 48$. Higher $M$ maintains recall in dense high-dimensional spaces.
  - **$\text{ef\_construction}$ (Candidate search depth during build time)**:
    - Set $\text{ef\_construction} = 2 \times M \sim 4 \times M$ (typically $128 \sim 256$). Higher values build better graph connectivity at the expense of slower indexing.
  - **$\text{ef\_search}$ (Search candidate list size at query time)**:
    - Tune dynamically per query SLA: $\text{ef\_search} = 40 \sim 64$ for sub-10ms P99 latency; $\text{ef\_search} = 128 \sim 256$ for high-precision retrieval (>98% recall).
- **RAM Footprint Calculation Invariant**:
  - Calculate RAM requirements prior to provisioning infrastructure:
    $$\text{RAM}_{\text{total}} \approx N \times \left( \text{dim} \times 4\text{ bytes} + M \times 2 \times 8\text{ bytes} + \text{payload} \right) \times 1.25$$
  - For 1,000,000 vectors with 1536 dimensions and $M=32$:
    - Vectors (FP32): $10^6 \times 1536 \times 4\text{B} = 6.14\text{ GB}$
    - HNSW Graph edges: $10^6 \times 64 \times 8\text{B} \approx 0.51\text{ GB}$
    - Minimum dedicated RAM: $\approx 8.3\text{ GB}$ working set in memory. Ensure host RAM exceeds this to prevent paging to disk.

---

## 3. The Pre-Filtering vs Post-Filtering Disaster & Payload Indexing
Filtering vector searches by metadata (e.g. `tenant_id`, `created_at`, `status`, `category`) is a frequent failure point in production RAG systems.

- ❌ **THE POST-FILTERING RECALL COLLAPSE**:
  - Executing vector search first for top-$K$ candidates and then filtering out non-matching rows drops valid results: if the 10 closest vectors belong to other tenants, the user receives 0 results even if hundreds of matching tenant vectors exist deeper in the index.
- ❌ **THE UNINDEXED PRE-FILTERING FULL-SCAN TRAP**:
  - Filtering prior to vector search without explicit payload/metadata indexes forces the database to abandon the HNSW index and execute a brute-force sequential scan over millions of vectors, exploding latency from 8ms to 2,000ms.
- ✅ **Production Single-Stage Filtering & Payload Indexing**:
  - ALWAYS create explicit payload/metadata schema indexes on every field used in filter clauses:
    ```python
    from qdrant_client import QdrantClient
    from qdrant_client.http.models import PayloadSchemaType

    client = QdrantClient("http://localhost:6333")
    # INVARIANT: Index payload fields before querying with filters:
    client.create_payload_index(
        collection_name="knowledge_base",
        field_name="tenant_id",
        field_schema=PayloadSchemaType.KEYWORD,
    )
    client.create_payload_index(
        collection_name="knowledge_base",
        field_name="doc_type",
        field_schema=PayloadSchemaType.KEYWORD,
    )
    ```
  - Use single-stage iterated search: modern vector databases traverse the HNSW graph while intersecting against the payload inverted index at each step, ensuring exactly $K$ valid items are returned without full scans.

---

## 4. Quantization Invariants (Scalar Quantization SQ8, Product Quantization PQ, Half-Precision FP16)
Uncompressed 32-bit floating point vectors require massive RAM budgets at scale.

- ❌ **THE RAW FP32 MEMORY OVER-PROVISIONING TRAP**:
  - Storing 10M 1536-dimensional vectors in uncompressed FP32 requires over 60GB of RAM just for vector data, driving up cloud infrastructure costs by orders of magnitude.
- ✅ **Scalar Quantization (SQ8 / int8) with Rescoring**:
  - Scalar Quantization compresses 4-byte FP32 values into 1-byte INT8 values, cutting memory usage by **75%** and speeding up distance calculations with SIMD INT8 instructions while preserving >99% recall when paired with oversampling:
    ```python
    from qdrant_client.http import models

    # Enable Scalar Quantization with oversampling rescore:
    client.update_collection(
        collection_name="knowledge_base",
        quantization_config=models.ScalarQuantization(
            scalar=models.ScalarQuantizationConfig(
                type=models.ScalarType.INT8,
                quantile=0.99,
                always_ram=True,
            )
        )
    )
    ```
  - **Oversampling Invariant**: At query time, retrieve $3 \times K$ candidates using quantized vectors, then rescore only those top candidates against the uncompressed or FP16 vectors on disk (`rescore=True`, `oversampling=3.0`).
- ✅ **pgvector Halfvec (`halfvec` / FP16)**:
  - In PostgreSQL with pgvector 0.7+, use `halfvec` (16-bit floating point):
    ```sql
    -- Store vectors in 16-bit float to slash storage and RAM by 50%:
    ALTER TABLE document_chunks ADD COLUMN embedding halfvec(1536);

    CREATE INDEX idx_chunks_hnsw_halfvec
      ON document_chunks USING hnsw (embedding halfvec_ip_ops)
      WITH (m = 24, ef_construction = 128);
    ```

---

## 5. pgvector Bulk Loading, Maintenance Memory & MVCC Bloat Defense
PostgreSQL with pgvector provides ACID vector storage, but improper configuration causes severe build slowdowns and index bloat.

- ❌ **THE ROW-BY-ROW INSERT INTO EXISTING HNSW INDEX ANTI-PATTERN**:
  - Creating an HNSW index on an empty table and inserting 500,000 vectors row-by-row forces continuous graph splitting and lock contention, taking hours and producing a fragmented graph with degraded recall.
- ✅ **Production Bulk Loading Invariant**:
  - Insert all vector rows FIRST (via `COPY` or batch inserts).
  - Then create the HNSW index with elevated maintenance memory and parallel workers:
    ```sql
    -- Elevate memory for the index build session:
    SET maintenance_work_mem = '4GB';
    SET max_parallel_maintenance_workers = 4;

    -- Build HNSW index with parallel workers:
    CREATE INDEX CONCURRENTLY idx_chunks_hnsw_embedding
      ON document_chunks USING hnsw (embedding vector_ip_ops)
      WITH (m = 32, ef_construction = 128);
    ```
- ❌ **THE HNSW MVCC UPDATE BLOAT TRAP**:
  - PostgreSQL's append-only MVCC architecture creates a new row version on every `UPDATE`. Updating a row with a vector column creates dead tuples in the HNSW index, degrading query performance until an aggressive `VACUUM` runs.
  - **Decouple Dynamic Metadata**: Store frequently mutated fields (`view_count`, `last_accessed_at`, `status`) in a separate metadata table. Keep the vector table immutable:
    ```sql
    -- Immutable vector storage:
    CREATE TABLE document_embeddings (
      id UUID PRIMARY KEY,
      embedding vector(1536) NOT NULL,
      content_hash TEXT NOT NULL
    );

    -- Volatile metadata table:
    CREATE TABLE document_metadata (
      id UUID PRIMARY KEY REFERENCES document_embeddings(id) ON DELETE CASCADE,
      view_count INT DEFAULT 0,
      updated_at TIMESTAMPTZ DEFAULT NOW()
    );
    ```

---

## 6. Embedding Model Provenance, Dimension Invariance & Asymmetric Prefixes
Embedding models map semantic concepts into distinct vector geometries. Mixing models or corrupting prefixes destroys retrieval accuracy.

- ❌ **THE MODEL MIXING / CROSS-DIMENSIONAL QUERY DISASTER**:
  - Querying vectors embedded with `text-embedding-3-small` using `text-embedding-ada-002` (or querying with mismatched dimensions) executes syntactically without error in many databases but produces completely random, hallucinatory results.
- ✅ **Mandatory Embedding Provenance Tracking**:
  - Every vector collection or table MUST store the generating model name and version:
    ```sql
    CREATE TABLE document_chunks (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      embedding vector(1536) NOT NULL,
      model_id VARCHAR(64) NOT NULL, -- e.g., 'text-embedding-3-small'
      model_version VARCHAR(32) NOT NULL,
      created_at TIMESTAMPTZ DEFAULT NOW()
    );
    ```
  - The application query layer MUST verify that the query embedding model matches `model_id` before querying.
- ✅ **Asymmetric Model Instruction Prefixes**:
  - Models such as E5, BGE, and Nomic are asymmetric: documents and queries require distinct prompt prefixes:
    - Indexing Document Chunk: `passage: <document body text>`
    - Executing User Search: `query: <user search question>`
  - Omitting the `passage: ` or `query: ` prefix drops Mean Reciprocal Rank (MRR) by up to 25%.

---

## 7. Hybrid Search (Reciprocal Rank Fusion) & Cross-Encoder Reranking
Dense vector search excels at conceptual similarity but fails at exact keyword matches, SKU codes, error codes, and technical identifiers.

- ❌ **NEVER RELY EXCLUSIVELY ON DENSE VECTORS**:
  - Searching for `"ERR_CONNECTION_RESET"` or `"part-no-8849-B"` via pure dense embeddings frequently misses the target document because rare alphanumerics lack strong semantic embeddings.
- ✅ **Production Reciprocal Rank Fusion (RRF)**:
  - Combine dense vector rank and lexical (BM25 or PostgreSQL `tsvector`) rank using rank positions rather than raw uncalibrated scores:
    $$\text{RRF\_Score}(d) = \frac{w_{\text{dense}}}{k + \text{rank}_{\text{dense}}(d)} + \frac{w_{\text{lexical}}}{k + \text{rank}_{\text{lexical}}(d)} \quad (k = 60)$$
  - PostgreSQL SQL Implementation:
    ```sql
    WITH dense_results AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <#> $1) AS rank
      FROM document_chunks
      WHERE tenant_id = $2
      ORDER BY embedding <#> $1
      LIMIT 50
    ),
    lexical_results AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY ts_rank_cd(search_vector, plainto_tsquery('english', $3)) DESC) AS rank
      FROM document_chunks
      WHERE tenant_id = $2 AND search_vector @@ plainto_tsquery('english', $3)
      LIMIT 50
    )
    SELECT COALESCE(d.id, l.id) AS id,
           (COALESCE(1.0 / (60 + d.rank), 0.0) + COALESCE(1.0 / (60 + l.rank), 0.0)) AS score
    FROM dense_results d
    FULL OUTER JOIN lexical_results l ON d.id = l.id
    ORDER BY score DESC
    LIMIT 10;
    ```
- ✅ **Two-Stage Retrieval with Cross-Encoder Reranking**:
  1. **Stage 1 (High Recall)**: Hybrid dense + lexical search fetches top $K = 50$ candidates.
  2. **Stage 2 (High Precision)**: Pass the 50 candidate pairs `(query, document_chunk)` to a Cross-Encoder model (Cohere Rerank v3, BGE-Reranker-Large, or Voyage-Rerank) to produce the final top $N = 5$ context chunks. Cross-encoders examine full cross-attention between query and passage, eliminating false positives.

---

## 8. Multi-Tenant Vector Partitioning & Tenant Isolation
Multi-tenant applications require strict boundary enforcement to prevent cross-customer data leakage.

- ❌ **THE UNPARTITIONED GLOBAL SEARCH TRAP**:
  - Running vector queries without guaranteed tenant scoping exposes private embeddings to other tenants if an application-level filter is accidentally omitted or overridden.
- ✅ **Production Multi-Tenancy Architecture**:
  - **SaaS with >10,000 Tenants (Single Collection with Shard/Partition Keys)**:
    - Use database-enforced partitioning (e.g. Qdrant `tenant_id` shard key, or PostgreSQL Declarative Table Partitioning by `tenant_id`):
      ```sql
      -- PostgreSQL Declarative List Partitioning by Tenant:
      CREATE TABLE document_chunks (
        tenant_id UUID NOT NULL,
        id UUID NOT NULL,
        embedding vector(1536) NOT NULL,
        PRIMARY KEY (tenant_id, id)
      ) PARTITION BY LIST (tenant_id);

      -- Each partition maintains its own local HNSW index:
      CREATE INDEX idx_tenant_hnsw ON document_chunks_t1 USING hnsw (embedding vector_ip_ops);
      ```
  - **Tenant ID Hard Validation Invariant**:
    - Query builders must assert non-empty `tenant_id` before constructing vector search requests. Reject any vector search lacking a validated tenant identifier.
