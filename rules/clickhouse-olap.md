---
description: ClickHouse columnar database production invariants, MergeTree engine family, async insert batching, partition pruning, materialized views, and real-time OLAP performance
globs: **/*.{sql,ch.sql,clickhouse.sql},**/clickhouse/**,**/migrations/clickhouse/**,**/analytics/**,**/clickhouse-client*
alwaysApply: false
---

# ClickHouse & Real-Time Columnar OLAP Production Invariants

> Add these rules to your project if writing ClickHouse DDL/DML, analytical queries, real-time ingestion pipelines, telemetry/event analytics, or designing schemas using the MergeTree engine family.

## 1. Storage Architecture & MergeTree Family Engine Selection
- **Columnar Storage Model vs Row-Oriented OLTP**:
  - ClickHouse physically stores data organized by column on disk inside immutable compressed files called **data parts**.
  - Queries reading 3 columns from a 100-column table read *only* those 3 columns from disk. Vectorized SIMD instructions execute operations across thousands of rows per CPU cycle.
- **Engine Selection Matrix**:
  - **`MergeTree`**: Default engine for immutable, append-only logs, event streams, time-series metrics, and audit trails.
  - **`ReplacingMergeTree([ver])`**: For eventual deduplication by primary key. Merges keep only the latest record during background compaction.
  - **`VersionedCollapsingMergeTree(sign, ver)` / `CollapsingMergeTree(sign)`**: For high-frequency updates and soft/hard deletes without expensive row mutations. Rows are canceled out via `Sign = -1` and updated via `Sign = 1`.
  - **`AggregatingMergeTree`**: For pre-aggregated incremental summaries (hyper-fast rollups, real-time dashboards) paired with Materialized Views.
  - ❌ **NEVER default to `TinyLog` or `Memory` engines in production**: They do not support indexing, parallel multi-threaded queries, or disk-backed crash recovery.

---

## 2. The "Too Many Parts" Crisis & Write Batching Invariants
- ❌ **TOTAL BAN ON SINGLE-ROW OLTP INSERTS**:
  - ClickHouse is NOT an OLTP database. Every `INSERT` statement creates at least one new immutable data part on disk (per partition).
  - Executing 500 single-row `INSERT INTO events VALUES (...)` per second creates 500 data parts per second. The background merge thread cannot keep pace, resulting in catastrophic database crashes:
    ```text
    DB::Exception: Too many parts (300) in all data in table. Merges are processing significantly slower than inserts. (TOO_MANY_PARTS)
    ```
- **Production Ingestion Discipline**:
  - **Application-Level Batching**: Buffer incoming writes at the application or queue tier (Kafka, Vector, BullMQ, Go worker) and flush in batches of **10,000 to 100,000 rows** (or every 1–5 seconds).
  - **ClickHouse Asynchronous Inserts (`async_insert`)**:
    - When client-side micro-batching is impossible (e.g. distributed microservices or serverless workers inserting directly), enable native server-side async buffer pooling:
      ```sql
      -- Enable on the user, session, or connection string:
      SET async_insert = 1;
      SET wait_for_async_insert = 1; -- Blocks client until batch is flushed to disk (guarantees durability)
      SET async_insert_busy_timeout_ms = 200; -- Max wait time before flushing buffer
      SET async_insert_max_data_size = 10485760; -- 10MB buffer threshold
      ```
    - ClickHouse coalesces incoming inserts into shared in-memory buffers and writes consolidated large parts to disk, eliminating part exhaustion.

---

## 3. Partition Key vs Primary Key vs Order By Discipline
- **`PARTITION BY` (Coarse-Grained Data Lifecycle Boundary)**:
  - Partitions physically segregate data into isolated directory structures on disk.
  - ❌ **NEVER partition by high-cardinality values** (e.g. `user_id`, `device_id`, or daily timestamp `toDate(created_at)` for multi-year tables):
    - Partitioning by day over 5 years generates 1,825 disk directories per table. This causes file descriptor exhaustion, excessive RAM usage, and crippling filesystem metadata overhead.
  - ✅ **Partitioning Invariant**: Partition by month using `toYYYYMM(event_time)`:
    ```sql
    PARTITION BY toYYYYMM(event_time)
    ```
  - Total active partitions per table MUST stay below **1,000**.
  - Partitions exist primarily to facilitate lifecycle pruning: dropping or detaching old data via instantaneous metadata operations:
    ```sql
    ALTER TABLE events DROP PARTITION '202301'; -- Milliseconds, zero I/O rewrite
    ```
- **`ORDER BY` (Sorting Key & Sparse Index Invariant)**:
  - In ClickHouse, `ORDER BY` defines the physical byte sorting of data on disk and generates the primary sparse index (one index mark every 8,192 rows by default).
  - **The Column Ordering Rule**: Sort from lowest cardinality to highest cardinality, matching common equality filters:
    ```sql
    -- ✅ Optimal: tenant_id (low cardinality) -> status -> event_time (high cardinality range)
    ORDER BY (tenant_id, status, event_time, id)
    ```
  - Data sorted this way achieves maximum LZ4/ZSTD compression ratios (identical consecutive values compress tightly) and allows ClickHouse to skip entire 8,192-row granules during index scans.
- **`PRIMARY KEY` vs `ORDER BY` Distinction**:
  - If `PRIMARY KEY` is omitted, it defaults to the exact `ORDER BY` tuple.
  - If the sorting key has many columns, define `PRIMARY KEY` as a prefix of `ORDER BY` to keep the primary index small enough to fit completely in CPU L2/L3 cache:
    ```sql
    ORDER BY (tenant_id, status, event_time, payload_hash)
    PRIMARY KEY (tenant_id, status, event_time)
    ```

---

## 4. The `FINAL` Modifier Performance Trap & Real-Time Deduplication
- **The Cost of `SELECT ... FINAL` on `ReplacingMergeTree`**:
  - `ReplacingMergeTree` does NOT instantly deduplicate rows upon insertion. Duplicates remain across unmerged parts until background merges occur.
  - Querying with `SELECT * FROM users FINAL` forces ClickHouse to perform an on-the-fly, single-threaded or CPU-intensive multi-way merge across all parts at query execution time.
  - On large tables (>10M rows), `FINAL` can increase query execution time by **10x to 50x** and trigger severe memory spikes.
- **Vectorized Deduplication Alternatives**:
  - **Prune Partitions First**: If `FINAL` is strictly required, always supply strict partition and primary key filters to bound the parts merged:
    ```sql
    SELECT * FROM users FINAL 
    WHERE tenant_id = 't_123' AND toYYYYMM(created_at) = 202603;
    ```
  - **Analytical Aggregation via `argMax`**:
    - For analytical rollups and aggregations, bypass `FINAL` entirely using SIMD-accelerated `argMax(value, version)`:
      ```sql
      -- ✅ Lightning-fast SIMD parallel scan across all parts without table merge:
      SELECT 
        user_id,
        argMax(user_email, updated_at) AS latest_email,
        argMax(plan_tier, updated_at)  AS latest_plan
      FROM users
      WHERE tenant_id = 't_123'
      GROUP BY user_id;
      ```

---

## 5. Asynchronous Mutations vs In-Place Updates
- ❌ **CLICKHOUSE IS NOT AN OLTP IN-PLACE UPDATE ENGINE**:
  - Running `ALTER TABLE events UPDATE status = 'processed' WHERE id = 123;` is NOT a lightweight row update.
  - It triggers a **heavy asynchronous mutation**: ClickHouse creates brand new data parts and rewrites the entire column data from disk.
  - Running continuous updates starves the merge thread, causes write amplification, and degrades read query performance across the entire cluster.
- **Production Invariants for Changing State**:
  - **Append State Changes**: Write new state events with an incremented version number using `ReplacingMergeTree` or `VersionedCollapsingMergeTree`.
  - **Batch Necessary Mutations**: If data must be updated/deleted for GDPR or compliance, execute mutations in large batches during off-peak maintenance windows:
    ```sql
    -- Batch by date or condition, NEVER row-by-row
    ALTER TABLE events DELETE WHERE user_id = 'usr_delete_request' AND event_time < '2026-01-01';
    ```
  - Track mutation progress via system tables:
    ```sql
    SELECT command, is_done, parts_to_do FROM system.mutations WHERE is_done = 0;
    ```
  - **Data Retention via Native TTL**:
    - Purge expired rows automatically using declarative TTLs instead of external deletion cron jobs:
      ```sql
      ALTER TABLE logs MODIFY TTL event_time + INTERVAL 30 DAY;
      ```

---

## 6. Data Types, Nullable Overhead & LowCardinality Discipline
- **LowCardinality Dictionary Encoding**:
  - For string columns with $< 10,000$ unique values (e.g., `status`, `http_method`, `country_code`, `environment`, `log_level`), ALWAYS use `LowCardinality(String)`.
    ```sql
    status LowCardinality(String),
    http_method LowCardinality(String),
    country LowCardinality(FixedString(2))
    ```
  - ClickHouse stores a dictionary index and replaces column values with compact 8-bit or 16-bit integers, reducing disk storage by up to 85% and accelerating string equality filters by 5x–10x.
- ❌ **AVOID `Nullable(T)` UNLESS STRICTLY MANDATED**:
  - In ClickHouse, `Nullable(T)` creates a secondary `.null` mask byte-array file for every column on disk.
  - It breaks SIMD vectorized CPU execution pipelines, inhibits compression, and adds up to 20% query latency penalty.
  - **Production Invariant**: Use empty sentinel values instead of NULL:
    - Strings: `''` (empty string)
    - Integers: `0` or `-1`
    - Timestamps: `'1970-01-01 00:00:00'`
- **Explicit Millisecond Timestamps**:
  - Always declare `DateTime64(3, 'UTC')` for timestamps requiring millisecond resolution:
    ```sql
    event_time DateTime64(3, 'UTC') DEFAULT now64(3)
    ```
  - Specifying the timezone `'UTC'` prevents subtle timezone discrepancies between different database client locales.

---

## 7. Streaming Materialized Views with AggregatingMergeTree
- **Materialized Views are Streaming Triggers, Not Query Caches**:
  - Unlike PostgreSQL or Oracle, a ClickHouse Materialized View does NOT run on a schedule or store pre-calculated static snapshots.
  - It is an **insert-time push stream trigger**: when new blocks are inserted into the source table, ClickHouse pipes the transformed block into the target table (`TO target_table`).
- **Real-Time Pre-Aggregation Pattern (`AggregatingMergeTree`)**:
  - Store billion-row telemetry data without paying real-time query aggregation taxes:
    ```sql
    -- 1. Target table storing pre-aggregated states:
    CREATE TABLE metrics_hourly (
      hour DateTime,
      service LowCardinality(String),
      request_count SimpleAggregateFunction(sum, UInt64),
      unique_users_state AggregateFunction(uniq, UUID),
      latency_p99_state AggregateFunction(quantilesExactWeighted(0.99), Float64, UInt32)
    ) ENGINE = AggregatingMergeTree()
    PARTITION BY toYYYYMM(hour)
    ORDER BY (service, hour);

    -- 2. Materialized View streaming insert pipeline:
    CREATE MATERIALIZED VIEW mv_metrics_hourly TO metrics_hourly AS
    SELECT
      toStartOfHour(event_time) AS hour,
      service,
      count() AS request_count,
      uniqState(user_id) AS unique_users_state,
      quantilesExactWeightedState(0.99)(latency_ms, 1) AS latency_p99_state
    FROM raw_events
    GROUP BY hour, service;

    -- 3. Querying pre-aggregated metrics using -Merge combinators:
    SELECT
      hour,
      service,
      sum(request_count) AS total_requests,
      uniqMerge(unique_users_state) AS total_unique_users,
      quantilesExactWeightedMerge(0.99)(latency_p99_state) AS p99_latency
    FROM metrics_hourly
    WHERE hour >= now() - INTERVAL 7 DAY
    GROUP BY hour, service
    ORDER BY hour DESC;
    ```
  - This architecture queries hundreds of millions of events in **under 15 milliseconds**.

---

## 8. Query Memory Guardrails, Distributed JOINs & Cardinality Hygiene
- **Memory Ceiling & Disk Spill Configuration**:
  - Analytical queries can exhaust server memory if grouping over unbounded keys. Always configure memory boundaries:
    ```sql
    SET max_memory_usage = 10000000000; -- 10 GB per-query RAM limit
    SET max_bytes_before_external_group_by = 5000000000; -- 5 GB: spill heavy GROUP BY hash tables to disk
    SET max_bytes_before_external_sort = 5000000000; -- Spill large ORDER BY to disk
    ```
- **Distributed JOIN Strategy (`GLOBAL JOIN` vs `JOIN`)**:
  - In a multi-node ClickHouse cluster:
    - Standard `JOIN` causes every shard to query the right-hand table independently. If the right-hand table is distributed, this causes an $N \times N$ network query explosion.
    - **Use `GLOBAL JOIN`** or `GLOBAL IN` when joining against a distributed table. The coordinator node executes the right-hand query once, caches the result in an in-memory hash table, and broadcasts it to all remote shards.
- **Approximation for Big Data Cardinality (`uniq` vs `count(DISTINCT)`):**
  - ❌ Avoid `count(DISTINCT user_id)` on tables with hundreds of millions of unique IDs; it allocates massive hash sets and blows past memory limits.
  - ✅ **Use Vectorized HyperLogLog Approximations**:
    - `uniq(user_id)` or `uniqCombined64(user_id)`: Provides approximate unique count with $< 1\%$ error margin, executing 5x–10x faster using a tiny fraction of RAM.
    - Only use `uniqExact(user_id)` when regulatory or financial precision is strictly mandatory.
