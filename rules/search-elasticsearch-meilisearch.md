---
description: Elasticsearch, OpenSearch, and Meilisearch production search engine invariants, index aliases, dynamic mapping prevention, bulk indexing backpressure, deep pagination with PIT/search_after, and hybrid BM25/k-NN vector search
globs: **/elasticsearch/**,**/opensearch/**,**/meilisearch/**,**/*search*/**,**/indices/**,**/mappings/**,**/*es*/**,**/*search*.ts,**/*search*.go,**/*search*.py
alwaysApply: false
---

# Search Engine & Inverted Index Invariants (Elasticsearch, OpenSearch & Meilisearch)

> Add these rules to your project if developing full-text search, multi-tenant search engines, vector/lexical hybrid retrieval, faceted e-commerce catalogs, or high-throughput log/analytics indexing using Elasticsearch, OpenSearch, or Meilisearch.

---

## 1. Zero-Downtime Index Migrations & The Mandatory Alias Pattern
In production search clusters, Lucene index mappings are largely immutable: you cannot rename fields, alter existing tokenizers, or change field data types in-place without rebuilding the inverted index.

- ❌ **TOTAL BAN ON DIRECT PHYSICAL INDEX ACCESS**:
  - Applications must NEVER execute read queries or write mutations directly against physical index names (e.g., `client.search({ index: 'products_v1', ... })`).
  - Directly targeting physical index names makes schema evolution impossible without application downtime or extensive code deployments.
- ✅ **The Dual Alias Invariant (`_read` & `_write`)**:
  - Every logical data collection must be accessed exclusively through two dedicated aliases:
    - `<resource>_search` (or `<resource>_read`): Used for all application search and retrieval queries. Can span multiple historical or partitioned indices.
    - `<resource>_write`: Points strictly to the single active index accepting new document inserts and updates.
- **Atomic Zero-Downtime Reindex Protocol**:
  When migrating index schema, changing analyzers, or modifying shard counts:
  1. Create the new physical index with updated mappings and settings: `products_v2`.
  2. Initiate background reindexing from old to new:
     ```json
     POST /_reindex?slices=auto&wait_for_completion=false
     {
       "source": { "index": "products_v1" },
       "dest": { "index": "products_v2" }
     }
     ```
  3. Monitor task progress via `GET /_tasks/<task_id>`.
  4. Perform an **atomic alias swap** in a single cluster state transaction:
     ```json
     POST /_aliases
     {
       "actions": [
         { "remove": { "index": "products_v1", "alias": "products_search" } },
         { "add":    { "index": "products_v2", "alias": "products_search" } },
         { "remove": { "index": "products_v1", "alias": "products_write" } },
         { "add":    { "index": "products_v2", "alias": "products_write" } }
       ]
     }
     ```
  5. Verify search traffic metrics on `products_v2`. After the retention window, delete `products_v1`.

---

## 2. Explicit Mapping Discipline & Mapping Explosion Prevention
Elasticsearch and OpenSearch default to dynamic mapping, which automatically detects field types from ingested JSON. In production, dynamic mapping is a catastrophic failure mode.

- ❌ **TOTAL BAN ON UNRESTRICTED DYNAMIC MAPPING**:
  - `"dynamic": true` allows arbitrary or malformed JSON payloads (e.g., dynamic webhook bodies or user metadata) to introduce thousands of unique keys into the index mapping.
  - **The Mapping Explosion Outage**: Each new field creates metadata stored in the JVM heap of every master and data node. Reaching the `index.mapping.total_fields.limit` (default 1,000) causes subsequent inserts to fail; breaching it risks unrecoverable cluster-wide JVM Out-Of-Memory (OOM) crashes and master node instability.
  - Production invariant: explicitly set `"dynamic": "strict"` (rejects undeclared fields) or `"dynamic": false"` (indexes known fields, ignores undeclared fields without indexing them):
    ```json
    PUT /products_v1
    {
      "mappings": {
        "dynamic": "strict",
        "properties": {
          "id": { "type": "keyword" },
          "tenant_id": { "type": "keyword" },
          "title": {
            "type": "text",
            "analyzer": "standard",
            "fields": {
              "keyword": { "type": "keyword", "ignore_above": 256 }
            }
          },
          "price_cents": { "type": "integer" },
          "status": { "type": "keyword" },
          "metadata": { "type": "object", "dynamic": false },
          "created_at": { "type": "date" }
        }
      }
    }
    ```
- **`text` vs `keyword` Discipline**:
  - `text`: Analyzed and tokenized into inverted index terms. Used strictly for full-text search. Unsuitable for sorting, exact matching, or aggregations.
  - `keyword`: Stored verbatim as an exact token in column-oriented `doc_values`. Mandatory for filtering, sorting, aggregations, and exact ID lookups.
  - ❌ **Fielddata Memory Leak Ban**: Never enable `fielddata: true` on `text` fields to bypass sorting/aggregation errors. Fielddata loads analyzed terms into the JVM heap and does not free them until GC pressure, causing chronic JVM garbage collection pauses. Always use a `.keyword` multi-field instead.

---

## 3. The Deep Pagination Trap: `search_after` & Point-in-Time (PIT)
- ❌ **The `from + size > 10,000` Trap**:
  - Requesting `{ "from": 9000, "size": 1000 }` forces every participating shard to fetch, deserialize, and rank 10,000 candidate documents in memory, transmit them over the network to the coordinating node, which then sorts `(shards * 10,000)` records before discarding 9,000 of them.
  - At scale, deep pagination causes coordinating node OOM crashes and high CPU spikes. Clusters enforce `index.max_result_window = 10000` as a hard circuit breaker.
- ✅ **Interactive Search Constraint**:
  - Constrain interactive UI pagination to shallow windows (`from + size <= 1000`). If a human user is browsing page 200, the search query is poorly scoped; guide them with faceted filtering.
- ✅ **Deep Pagination Invariant (`search_after` with Point-in-Time)**:
  - For continuous scrolling, large dataset navigation, or exports, use `search_after` tied to an immutable Point-in-Time (PIT) snapshot:
    ```json
    // Step 1: Open Point-in-Time context
    POST /products_search/_pit?keep_alive=1m
    // Returns: { "id": "46ToAwEMcHJvZHVjdHM..." }

    // Step 2: Search with search_after using unique tie-breaker sort
    POST /_search
    {
      "size": 100,
      "query": { "term": { "status": "active" } },
      "pit": {
        "id": "46ToAwEMcHJvZHVjdHM...",
        "keep_alive": "1m"
      },
      "sort": [
        { "created_at": "desc" },
        { "id": "asc" }
      ],
      "search_after": [1735689600000, "prod_01J8ABC"]
    }
    ```
  - **Tie-Breaker Rule**: The `sort` array MUST terminate with a uniquely identifying field (like `id` or `_shard_doc`) to guarantee deterministic document ordering across shard boundaries.
  - **Resource Cleanup**: Always close the PIT explicitly upon completion:
    ```json
    DELETE /_pit
    { "id": "46ToAwEMcHJvZHVjdHM..." }
    ```

---

## 4. Bulk API Invariants & Backpressure Handling
- ❌ **Total Ban on Single-Document Indexing Loops**:
  - Indexing individual documents (`POST /products/_doc/123`) in loops generates massive HTTP roundtrip overhead, creates hundreds of tiny Lucene segments per second, and triggers relentless background merge thrashing.
- ✅ **Bulk API Batch Sizing Invariant**:
  - Always ingest via the `_bulk` endpoint in batches sized between **5 MB to 15 MB** or **1,000 to 5,000 documents**:
    ```json
    POST /_bulk
    { "index": { "_index": "products_write", "_id": "prod_101" } }
    { "title": "Wireless Ergonomic Mouse", "price_cents": 4999 }
    { "index": { "_index": "products_write", "_id": "prod_102" } }
    { "title": "Mechanical Keyboard", "price_cents": 8999 }
    ```
- **Backpressure & 429 (`TOO_MANY_REQUESTS`) Handling**:
  - When data nodes cannot keep pace with write ingestion, their internal write threadpool queues fill up, throwing `EsRejectedExecutionException` / HTTP 429.
  - The client MUST inspect the `errors: true` flag in the bulk response and check each item's `status`:
    ```ts
    const bulkResponse = await client.bulk({ body: operations });
    if (bulkResponse.errors) {
      const rejectedItems: typeof operations = [];
      for (const item of bulkResponse.items) {
        const action = Object.values(item)[0];
        if (action.status === 429) {
          // Collect for exponential backoff retry with full jitter
          rejectedItems.push(findOriginalDoc(action._id));
        } else if (action.error) {
          logger.error("Permanent indexing error", { error: action.error, id: action._id });
        }
      }
      if (rejectedItems.length > 0) {
        await backoffRetry(rejectedItems);
      }
    }
    ```
- **High-Throughput Ingestion Tuning**:
  - During massive initial data migrations or batch syncs:
    1. Set `"index.refresh_interval": "-1"` (stops periodic Lucene segment flushes).
    2. Set `"index.number_of_replicas": 0` (stops inter-node replica synchronization).
    3. Perform bulk indexing.
    4. Restore `"index.refresh_interval": "1s"` and `"index.number_of_replicas": 1`.
    5. Trigger `POST /products_v2/_forcemerge?max_num_segments=1` to optimize segment structures.

---

## 5. Shard Sizing, Multi-Tenancy & Custom Routing Keys
- **Primary Shard Sizing Rule of Thumb**:
  - For search workloads: Keep primary shard sizes between **10 GB and 30 GB**.
  - For time-series / log analytics workloads: Keep shard sizes between **30 GB and 50 GB**.
  - **Oversharding Trap**: Having 200 small shards of 200MB each wastes gigabytes of node memory on segment headers, file handles, and term dictionaries. Aim for fewer, appropriately sized shards.
- **Custom Shard Routing for Multi-Tenant SaaS**:
  - In a standard search query, the coordinating node broadcasts the request to every primary shard in the index (scatter-gather) and merges the results.
  - In multi-tenant systems, route documents by `tenant_id`:
    ```json
    // Indexing with routing
    PUT /tenant_documents/_doc/doc_456?routing=org_acme
    {
      "tenant_id": "org_acme",
      "title": "Confidential Roadmaps"
    }

    // Searching with routing
    POST /tenant_documents/_search?routing=org_acme
    {
      "query": {
        "bool": {
          "filter": [{ "term": { "tenant_id": "org_acme" } }],
          "must":   [{ "match": { "title": "Roadmaps" } }]
        }
      }
    }
    ```
  - **Performance Impact**: Supplying the routing parameter constrains the query execution to the exact single shard holding that tenant's data, eliminating cluster-wide scatter-gather network hops.

---

## 6. Query Construction: Filter Context vs Query Context & Anti-Wildcard Guards
- **Filter Context vs Query (Scoring) Context**:
  - Clauses inside `bool.filter` and `bool.must_not` run in **Filter Context**:
    - They ask binary yes/no questions ("Is status == active?", "Is created_at >= 2025-01-01?").
    - They do NOT compute relevance scores (`_score`).
    - Their matching bitsets are automatically cached in node memory as compact Roaring Bitmaps.
  - Clauses inside `bool.must` and `bool.should` run in **Query Context**:
    - They compute BM25 relevance scores and cannot be cached as pure bitsets.
  - ✅ **Production Invariant**: Always place exact matches, range filters, permissions, and status checks inside `filter`:
    ```json
    POST /products_search/_search
    {
      "query": {
        "bool": {
          "filter": [
            { "term": { "status": "published" } },
            { "term": { "tenant_id": "tenant_42" } },
            { "range": { "price_cents": { "gte": 1000, "lte": 50000 } } }
          ],
          "must": [
            {
              "multi_match": {
                "query": "ergonomic mechanical keyboard",
                "fields": ["title^3", "description"],
                "fuzziness": "AUTO"
              }
            }
          ]
        }
      }
    }
    ```
- ❌ **Leading Wildcard & Unbounded Regexp Ban**:
  - Never execute leading wildcard queries like `{"wildcard": { "title": "*phone*" }}`.
  - In an inverted index, terms are sorted lexicographically. Leading wildcards require scanning every single term in the entire term dictionary, causing 100% CPU lockups.
  - ✅ **Production Invariant**:
    - For search-as-you-type autocomplete: use `edge_ngram` token filters at index time.
    - For arbitrary substring matches: use the specialized `wildcard` field type (which indexes n-grams internally) or trigram analyzers.

---

## 7. Hybrid Search: BM25 Lexical + Dense Vector k-NN (RRF)
Modern retrieval augmented generation (RAG) and semantic search architectures combine keyword precision (BM25) with semantic vector embeddings.

- **Explicit `dense_vector` Field Configuration**:
  ```json
  PUT /knowledge_articles_v1
  {
    "mappings": {
      "properties": {
        "content": { "type": "text" },
        "content_vector": {
          "type": "dense_vector",
          "dims": 1536,
          "index": true,
          "similarity": "cosine",
          "index_options": {
            "type": "hnsw",
            "m": 16,
            "ef_construction": 100
          }
        }
      }
    }
  }
  ```
- **Reciprocal Rank Fusion (RRF) Invariant**:
  - Combining raw BM25 scores (unbounded floats) with cosine similarities (0 to 1) directly using addition produces skewed, uncalibrated rankings.
  - ✅ **Production Invariant**: Use Reciprocal Rank Fusion (`rrf`) to score candidates based on their relative ranks in each individual retrieval set:
    ```json
    POST /knowledge_articles_search/_search
    {
      "retriever": {
        "rrf": {
          "retrievers": [
            {
              "standard": {
                "query": { "match": { "content": "zero downtime postgres migration" } }
              }
            },
            {
              "knn": {
                "field": "content_vector",
                "query_vector": [0.012, -0.045, ...],
                "k": 50,
                "num_candidates": 100
              }
            }
          ],
          "rank_window_size": 50,
          "rank_constant": 60
        }
      }
    }
    ```

---

## 8. Meilisearch Production Invariants
Meilisearch is a high-speed, lightweight, typo-tolerant search engine designed for instant end-user search-as-you-type experiences.

- **Explicit Settings Configuration Invariant**:
  - By default, Meilisearch marks every JSON field as searchable, increasing index size and RAM consumption.
  - Explicitly define `searchableAttributes`, `filterableAttributes`, and `sortableAttributes`:
    ```ts
    await client.index('movies').updateSettings({
      searchableAttributes: [
        'title',
        'overview',
        'director'
      ],
      filterableAttributes: [
        'genres',
        'release_year',
        'rating'
      ],
      sortableAttributes: [
        'release_year',
        'rating'
      ],
      rankingRules: [
        'words',
        'typo',
        'proximity',
        'attribute',
        'sort',
        'exactness'
      ]
    });
    ```
- **Primary Key Safety & Deterministic Document IDs**:
  - Document IDs must strictly contain only alphanumeric characters (`a-zA-Z0-9`), hyphens (`-`), and underscores (`_`). Whitespace and special characters (`/`, `:`, `@`) cause immediate rejection.
  - The primary key cannot be modified after document creation without deleting and re-inserting the record.
- **Asynchronous Task Queue Discipline**:
  - All write mutations (`addDocuments`, `deleteDocuments`, `updateSettings`) in Meilisearch are asynchronous tasks added to a queue, returning a `{ taskUid: number }`.
  - ❌ Never assume an inserted document is immediately readable in the subsequent line of code.
  - ✅ In integration tests or synchronization pipelines, explicitly await task resolution:
    ```ts
    const task = await client.index('movies').addDocuments(documents);
    await client.waitForTask(task.taskUid, { timeOutMs: 10000 });
    ```
- **Faceted Navigation Safeguards**:
  - Restrict maximum facet values per search to avoid payload bloat:
    ```ts
    const searchResults = await client.index('products').search('headphones', {
      facets: ['brand', 'category'],
      facetSearch: true
    });
    ```
