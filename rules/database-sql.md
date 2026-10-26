---
description: SQL and database production invariants, zero-downtime migrations, lock safety, and query performance
globs: **/*.{sql,prisma},**/migrations/**
alwaysApply: false
---

# SQL & Database Production Invariants

> Add these rules to your project if writing relational database migrations, SQL queries, or ORM data models (PostgreSQL, MySQL, SQLite).

## 1. Zero-Downtime Migrations (Expand & Contract)
- **Never Break Running Services**:
  - Database schema changes and application deployments are asynchronous. All migrations must be backwards-compatible with running versions of the app.
- **Three-Phase Migration Discipline**:
  1. **Expand**: Add new nullable columns or tables; deploy dual-write application logic.
  2. **Backfill**: Backfill historical rows asynchronously in small batches (e.g., 1,000 rows per batch) with rate-limiting.
  3. **Contract**: Switch reads to new columns; remove old application code; drop deprecated columns in a subsequent release.
- **Lock Contention Invariant**:
  - PostgreSQL: Always use `CREATE INDEX CONCURRENTLY` (must run outside a transaction block).
  - ❌ **NEVER add non-null columns without defaults on high-traffic tables** in older database engines that rewrite the entire table.
  - Set a strict `lock_timeout` before executing DDL migrations to avoid queuing behind long queries and taking down production:
    ```sql
    SET lock_timeout = '2s';
    ALTER TABLE orders ADD COLUMN fulfillment_status varchar(32);
    ```

## 2. Query Discipline & Indexing Hygiene
- ❌ **BAN `SELECT *` IN PRODUCTION**:
  - Explicitly enumerate needed columns to reduce network overhead, prevent memory bloat, and avoid breaking when columns are added, renamed, or dropped.
- **Compound Index Leftmost Prefix Rule**:
  - In composite indexes `(tenant_id, status, created_at)`:
    - Place equality filter columns first (`tenant_id = :tid AND status = :st`).
    - Place range filters and sorting columns last (`created_at >= :ts ORDER BY created_at DESC`).
  - An index on `(a, b)` does NOT accelerate queries filtering only on `b`.
- **Partial Indexes for Soft Deletes & Statuses**:
  - For soft-deleting tables, avoid indexing millions of deleted rows:
    ```sql
    CREATE INDEX idx_users_active_email ON users (email) WHERE deleted_at IS NULL;
    ```
- **Mandatory Foreign Key Indexing**:
  - Every foreign key column (`user_id`, `org_id`, etc.) MUST have a corresponding index to avoid table-lock escalations and full table scans during cascade deletes and joins.
- **Keyset / Cursor Pagination Safety**:
  - ❌ **NEVER use high-offset `LIMIT 100 OFFSET 100000`** on large tables (forces engine to scan and discard 100,000 rows).
  - Use keyset pagination:
    ```sql
    WHERE id > :last_seen_id ORDER BY id ASC LIMIT :page_size
    ```
- **N+1 Prevention**:
  - In ORM operations (Prisma, TypeORM, SQLAlchemy, GORM, ActiveRecord), always use eager loading / batch fetching (`include`, `select_related`, `preload`). Never execute queries inside loops.

## 3. Parameterization & SQL Injection Immunity
- ❌ **STRICT BAN ON STRING CONCATENATION FOR QUERY VALUES**:
  - Never interpolate variables into SQL strings:
    ```ts
    // ❌ Catastrophic SQL Injection:
    db.query(`SELECT * FROM users WHERE email = '${email}'`);

    // ✅ Enforce parameterized placeholders:
    db.query(`SELECT id, email, created_at FROM users WHERE email = $1`, [email]);
    ```
- **Dynamic Identifiers (Table / Column Names)**:
  - If column or table names must be dynamic in reporting queries, strictly validate them against a compile-time whitelist or use identifier quoting functions (`quote_ident` in PostgreSQL). Never allow raw user input into identifiers.

## 4. Transaction Hygiene & Deadlock Prevention
- **Keep Transactions Micro-Short**:
  - Hold transactions open only for the absolute minimal number of write operations.
- ❌ **ZERO NETWORK I/O INSIDE TRANSACTIONS**:
  - Never make external HTTP calls, RPC calls, email triggers, or file uploads while holding an active database transaction. Network latency will exhaust database connection pools.
- **Deterministic Lock Acquisition Order**:
  - To prevent cyclic deadlocks between concurrent workers, always acquire row locks in a consistent order:
    ```sql
    -- Sort IDs before batch locking:
    SELECT id FROM accounts WHERE id IN (10, 42, 99) ORDER BY id ASC FOR UPDATE;
    ```
- **Idempotent Mutations**:
  - Design state-changing mutations with idempotency keys or unique constraints (`ON CONFLICT (idempotency_key) DO NOTHING`) to gracefully handle network retries without duplicate billing or data corruption.

## 5. Connection Pool & Statement Limits
- Every production database connection MUST configure:
  - `statement_timeout`: Abort runaway queries before exhausting connection slots (e.g., `SET statement_timeout = '5s'`).
  - `idle_in_transaction_session_timeout`: Kill transactions abandoned by crashed application pods or leaked connections (e.g., `SET idle_in_transaction_session_timeout = '10s'`).
  - `max_open_conns` and `max_idle_conns`: Prevent connection spikes from crashing database clusters.
  - `conn_max_lifetime`: Recycle stale connections to handle DNS failovers and load balancer recycles cleanly.

## 6. Concurrency Control, Advisory Locks & Safe Chunking
- **Optimistic Concurrency Control (OCC) Over Heavy Locks**:
  - For high-read, low-contention entities (e.g. inventory counters, profile updates), avoid heavy pessimistic locks (`SELECT FOR UPDATE`). Use version checking:
    ```sql
    UPDATE inventory 
    SET quantity = quantity - 1, version = version + 1 
    WHERE id = :item_id AND version = :expected_version;
    ```
    If 0 rows are updated, notify the application layer to reload and retry.
- **PostgreSQL Advisory Locks for Distributed Jobs**:
  - Prevent concurrent cron runners or migration containers from colliding by leveraging application-level advisory locks:
    ```sql
    SELECT pg_try_advisory_lock(hashtext('nightly_billing_reconciliation'));
    -- Returns TRUE if lock acquired; FALSE if already running elsewhere
    ```
- **Chunked Deletion for Historical Data (Anti-WAL Blowup)**:
  - ❌ **NEVER run unbounded large deletes** (`DELETE FROM logs WHERE created_at < NOW() - INTERVAL '90 days'`). A single query deleting millions of rows locks the table, exhausts memory, and generates massive WAL write spikes.
  - Delete in bounded batches with pauses to allow replication and vacuuming:
    ```sql
    -- Batch loop in application / migration script:
    DELETE FROM logs 
    WHERE id IN (
      SELECT id FROM logs WHERE created_at < NOW() - INTERVAL '90 days' LIMIT 2000
    );
    ```

## 7. PostgreSQL Hardening, PgBouncer & Storage Safety
- **PgBouncer Transaction Pooling Mode Invariants**:
  - In transaction pooling mode (standard in RDS Proxy, Supabase, Neon, and high-concurrency PgBouncer setups), database connections are returned to the pool immediately upon transaction completion (`COMMIT` / `ROLLBACK`).
  - ❌ **NEVER rely on session-level state**:
    - Avoid session-level `SET timezone` or `SET search_path` (leaks into other tenants' queries).
    - ❌ **NEVER use session advisory locks** (`pg_advisory_lock`); ALWAYS use transaction-scoped advisory locks: `pg_advisory_xact_lock()`.
    - ❌ **NEVER use `LISTEN` / `NOTIFY`** on transaction-pooled connections; use dedicated direct connections or message brokers (Redis/Kafka).
    - Disable client-side unnamed prepared statements or configure `binary_parameters=yes` / `server_reset_query`.
- **JSONB Indexing Hygiene (GIN vs Expression Indexes)**:
  - ❌ **NEVER query large unstructured JSONB columns with sequential scans**:
    - For `@>` containment filtering, build a GIN index with `jsonb_path_ops` (produces 50-70% smaller index size and faster lookup than default `jsonb_ops`):
      ```sql
      CREATE INDEX idx_events_payload ON events USING GIN (payload jsonb_path_ops);
      ```
    - For specific frequently-queried keys, prefer deterministic B-Tree expression indexes or generated columns over blanket GIN indexing:
      ```sql
      CREATE INDEX idx_events_customer_id ON events (((payload->>'customer_id')::uuid));
      ```
- **Transaction ID (XID) Wraparound & Autovacuum Discipline**:
  - PostgreSQL uses 32-bit transaction IDs; running out of IDs causes catastrophic forced shutdown into read-only mode to prevent data corruption.
  - ❌ **NEVER disable autovacuum (`autovacuum = off`)**.
  - Monitor `age(datfrozenxid)` in Prometheus/metrics and alert when `age > 1,000,000,000`. Tune `autovacuum_vacuum_cost_limit` (e.g. 2000) and `autovacuum_cost_delay` (e.g. 2ms) to prevent vacuum starvation on high-write databases.
- **Declarative Range Partitioning for Append-Only Datasets**:
  - For tables projected to exceed 50M-100M rows (audit logs, time-series events, webhook logs), use declarative partitioning:
    ```sql
    CREATE TABLE audit_logs (
      id uuid NOT NULL,
      created_at timestamptz NOT NULL,
      payload jsonb
    ) PARTITION BY RANGE (created_at);
    ```
  - Purging historical partitions via `DROP TABLE audit_logs_2024_01` is an instantaneous $O(1)$ DDL operation with zero vacuum overhead or WAL spikes, completely replacing high-risk batch deletes.

## 8. Index Architecture, Covering Indexes (INCLUDE) & Key Safety
- **PostgreSQL Index-Only Scans with Covering Indexes (`INCLUDE`)**:
  - When an endpoint frequently queries specific columns along with filter predicates, add non-key columns to the index payload using `INCLUDE`:
    ```sql
    -- Eliminates table heap page lookups entirely (pure Index-Only Scan):
    CREATE INDEX idx_orders_customer_status ON orders (customer_id, status) INCLUDE (total_cents, created_at);
    ```
  - Unlike multi-column index keys, `INCLUDE` columns are stored only at the leaf level, reducing B-tree traversal overhead and index bloat.
- **Sequential UUIDv7 over Random UUIDv4**:
  - ❌ **TOTAL BAN on random UUIDv4 as primary keys on high-insert tables**: UUIDv4 inserts randomly across the entire B-Tree, shattering page locality, inducing constant B-Tree page splits, and causing massive cache thrashing in `shared_buffers`.
  - Use time-ordered sequential UUIDs (**UUIDv7**) or BigInt/Snowflake IDs for clustered insert efficiency. UUIDv7 appends sequentially at the right edge of the index while maintaining 128-bit global uniqueness.
- **Mandatory Foreign Key Indexing**:
  - Relational databases (PostgreSQL/MySQL) DO NOT automatically create indexes on foreign key referencing columns.
  - ❌ **Missing FK indexes cause full-table share locks** on the child table whenever a referenced row in the parent table is updated or deleted:
    ```sql
    -- MANDATORY for all foreign key relationships:
    CREATE INDEX idx_order_items_order_id ON order_items (order_id);
    ```
- **Partial Unique Indexes for Soft-Delete Tables**:
  - Standard unique constraints (`UNIQUE (email)`) break when soft-deleting users (`deleted_at IS NOT NULL`), preventing re-registration with the same email.
  - Enforce uniqueness exclusively for active rows via partial unique indexes:
    ```sql
    CREATE UNIQUE INDEX uq_users_active_email ON users (email) WHERE deleted_at IS NULL;
    ```

## 9. DDL Lock Timeouts, Advisory Locks & Connection Pool Mathematics
- **Mandatory DDL Lock & Statement Timeouts**:
  - ❌ **NEVER run DDL migrations without setting `lock_timeout` and `statement_timeout` first**:
    ```sql
    -- MANDATORY migration transaction wrapper:
    BEGIN;
    SET LOCAL lock_timeout = '2s';
    SET LOCAL statement_timeout = '5s';

    ALTER TABLE users ADD COLUMN is_verified boolean DEFAULT false;
    COMMIT;
    ```
  - Without `lock_timeout`, an `ALTER TABLE` requiring an `ACCESS EXCLUSIVE` lock will wait indefinitely behind an active long query. All subsequent reads/writes queue up behind the pending lock, instantly exhausting the entire database connection pool and causing a cascading outage.
- **PostgreSQL Advisory Locks for Single-Worker Coordination**:
  - For coordinating distributed schema migrations or singleton background jobs across multiple application instances, use transaction-level advisory locks:
    ```sql
    -- Returns true immediately if lock is acquired; false if another worker holds it:
    SELECT pg_try_advisory_xact_lock(hashtext('migration_lock_schema_v42'));
    ```
  - `pg_try_advisory_xact_lock` releases automatically when the transaction completes (commit or rollback), eliminating orphaned locks even if the worker pod crashes.
- **Connection Pool Sizing Mathematics (Little's Law)**:
  - ❌ **NEVER set application connection pools to hundreds of connections**:
    - PostgreSQL processes are OS processes, not lightweight threads. 500 connections competing for CPU cores degrade throughput via catastrophic context-switching overhead and disk I/O thrashing.
  - Sizing baseline:
    $$\text{Connections} \approx (2 \times \text{CPU Cores}) + \text{Disk Spindles/IOPS Factor}$$
    For an 8-core database server, a pool size of 20–30 connections per service handles peak load far faster and more reliably than 200 unmanaged connections.
- **Query Plan Deep Inspection (`EXPLAIN (ANALYZE, BUFFERS)`)**:
  - Always profile queries using `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` rather than raw wall-clock duration.
  - Inspect `Buffers: shared hit=... read=... dirtied=...`. A query that appears fast on warm cache (`shared hit=50000`) but reads 50,000 pages will grind the database to a halt when cache evictions occur or cold storage reads are required.

## 10. Concurrency Isolation, Partial Status Indexes & Extended Statistics
- **Lost Update Prevention in Read-Modify-Write Cycles**:
  - Under PostgreSQL's default `READ COMMITTED` isolation level, two concurrent transactions executing `SELECT balance ...` followed by `UPDATE accounts SET balance = balance - 50` will silently overwrite each other, causing money or inventory duplication.
  - Mitigate with one of three proven strategies:
    1. **Atomic In-Database Arithmetic**:
       ```sql
       UPDATE accounts SET balance = balance - 50 WHERE id = 42 AND balance >= 50;
       ```
    2. **Pessimistic Row Locks (`SELECT ... FOR UPDATE`)**:
       ```sql
       SELECT balance FROM accounts WHERE id = 42 FOR UPDATE;
       ```
    3. **Optimistic Concurrency Control (OCC) with Monotonic Version**:
       ```sql
       UPDATE accounts SET balance = 150, version = version + 1
       WHERE id = 42 AND version = 3; -- If rows_affected == 0, abort and retry
       ```
- **Partial Indexing on High-Turnover Status Queues**:
  - In task queues, order systems, or event tables, 98% of rows are in terminal states (`completed`, `archived`, `cancelled`).
  - ❌ **NEVER index the entire table on `(status, created_at)`**:
    - A 20-million-row index consumes gigabytes of RAM and slows down every single write.
  - Use a targeted partial index covering ONLY active/pending states:
    ```sql
    CREATE INDEX idx_orders_active_queue ON orders (created_at)
    WHERE status IN ('pending', 'processing');
    ```
    This reduces index size by 98% (e.g., from 800MB to 12MB), fitting entirely within CPU L3 cache or RAM buffers for lightning-fast polling.
- **Correlated Column Statistics (`CREATE STATISTICS`)**:
  - The PostgreSQL query planner assumes columns are statistically independent. When querying correlated columns (e.g., `WHERE make = 'Audi' AND model = 'R8'`), the planner multiplies individual selectivities, estimating 1 row instead of 50,000.
  - This gross underestimation triggers catastrophic query plans (e.g., choosing a Nested Loop with 50,000 index lookups over an efficient Hash Join or Bitmap Scan).
  - Fix by defining explicit multivariate extended statistics:
    ```sql
    CREATE STATISTICS stat_car_make_model (dependencies, ndistinct)
    ON make, model FROM vehicles;
    ANALYZE vehicles;
    ```

## 11. pgvector Production Invariants, MVCC Bloat Defense & Transaction Anomalies
- **pgvector Index Selection & Invariants (HNSW vs IVFFlat)**:
  - For AI embeddings and vector search in PostgreSQL:
    - **Use HNSW (Hierarchical Navigable Small World)** as default for production:
      ```sql
      CREATE INDEX idx_items_embedding ON items 
      USING hnsw (embedding vector_cosine_ops) 
      WITH (m = 16, ef_construction = 64);
      ```
    - HNSW maintains high query recall without rebuilding the index after new inserts (unlike IVFFlat which degrades as cluster centers drift).
    - **Index Construction Memory**: Boost `SET maintenance_work_mem = '2GB';` before building vector indexes on large tables to prevent spilling graph building to disk.
    - **Distance Operator Discipline**:
      - Cosine distance: `<=>` (uses `vector_cosine_ops`). If vectors are pre-normalized to unit length, use Inner Product `<#>` (`vector_ip_ops`) for up to 3x faster index searches.
      - Euclidean L2 distance: `<->` (`vector_l2_ops`).
    - **Runtime Query Recall Tuning**: Configure `SET hnsw.ef_search = 100;` before executing vector queries to trade search latency for higher recall.
- **PostgreSQL MVCC Dead Tuple Bloat & Autovacuum Tuning**:
  - PostgreSQL updates and deletes do not overwrite in place; they write new row versions (tuples) and mark old ones dead.
  - On high-churn tables (queues, active sessions, real-time metrics), default autovacuum thresholds (20% of table) trigger too late, causing table bloat and cache thrashing:
    ```sql
    ALTER TABLE active_jobs SET (
      autovacuum_vacuum_scale_factor = 0.05,
      autovacuum_vacuum_threshold = 1000
    );
    ```
  - ❌ **NEVER allow idle in transaction connections**: A single uncommitted transaction holding an `xmin` horizon blocks autovacuum from freeing dead tuples across the *entire* database cluster, causing runaway disk growth. Always enforce `idle_in_transaction_session_timeout = '30s'`.
- **Transaction Isolation Anomaly Matrix & Serialization Retries**:
  - `READ COMMITTED` (default): Vulnerable to non-repeatable reads, phantom reads, and lost updates in read-modify-write patterns.
  - `REPEATABLE READ`: Guarantees a consistent snapshot at the start of the transaction. If two concurrent transactions modify the same row, the second fails with SQLSTATE `40001` (`could not serialize access due to concurrent update`).
  - **Application Retry Loop Invariant**: When running under `REPEATABLE READ` or `SERIALIZABLE`, the application layer MUST wrap database transactions in an idempotent retry loop with jittered backoff to handle transient serialization errors automatically.

## 12. Row-Level Security (RLS) Performance, JSONB GIN Operator Invariants & WAL Amplification
- **Row-Level Security (RLS) Query Planner Traps & `security_invoker`**:
  - PostgreSQL RLS policies (`CREATE POLICY ... USING (tenant_id = current_setting('app.tenant_id'))`) are dynamically injected into every query execution plan.
  - ❌ **The Unindexed RLS Policy Disaster**: If the policy expression column (`tenant_id`) is not indexed as the leftmost column in table indexes, EVERY query—regardless of user-specified filters—degrades into a catastrophic full table sequential scan.
  - **PostgreSQL 15+ View Security Invariant**: When defining views over RLS-enabled tables, ALWAYS specify `WITH (security_invoker = true)`:
    ```sql
    CREATE VIEW active_tenant_users WITH (security_invoker = true) AS
    SELECT id, email, created_at FROM users WHERE status = 'active';
    ```
    Without `security_invoker = true`, PostgreSQL defaults to checking permissions as the view creator (`security_definer` semantics), silently bypassing RLS and leaking multi-tenant data.
- **JSONB GIN Operator Class Selection (`jsonb_ops` vs `jsonb_path_ops`)**:
  - Default `CREATE INDEX USING gin (payload)` uses `jsonb_ops`, which indexes every key, value, and nested element separately to support `@>`, `?` (key exists), `?|`, and `?&`.
  - For containment-only queries (`WHERE payload @> '{"status": "paid"}'`), ALWAYS specify `jsonb_path_ops`:
    ```sql
    CREATE INDEX idx_orders_payload_containment ON orders USING gin (payload jsonb_path_ops);
    ```
    `jsonb_path_ops` hashes full paths (key-value pairs) together, producing an index that is **up to 70% smaller** and substantially faster for containment scans.
  - **Targeted B-Tree Expression Indexing**: If querying a specific JSON field frequently (`payload->>'account_id' = :id`), do NOT use GIN. Create a standard B-tree expression index: `CREATE INDEX idx_orders_account ON orders ((payload->>'account_id'))`.
- **Write-Ahead Log (WAL) Volume Defense with `UNLOGGED` Tables**:
  - High-frequency bulk ingestion, temporary ETL staging, and ephemeral queue processing generate colossal WAL disk write volume, triggering replication lag on read replicas and disk IOPS throttling.
  - **The `UNLOGGED` Invariant**: For temporary processing tables or bulk staging pipelines where durability across unexpected database crashes is unnecessary:
    ```sql
    CREATE UNLOGGED TABLE staging_events ( ... );
    ```
    `UNLOGGED` tables bypass WAL generation entirely, cutting write disk I/O in half and shielding replication streams from transient data bloat.

## 13. PostgreSQL Advisory Locks, Autovacuum Tuning & Connection Pool Mathematical Sizing
- **PostgreSQL Advisory Locks for Distributed Coordination**:
  - Application workflows often require exclusive execution (e.g. running an hourly billing reconciliation or preventing concurrent balance settlement for a tenant) without locking an entire database table or creating dummy lock rows.
  - ✅ **Transaction-Scoped Advisory Locks (`pg_advisory_xact_lock`)**:
    ```sql
    -- Blocks until the advisory lock for tenant hash is acquired; auto-released on COMMIT or ROLLBACK:
    SELECT pg_advisory_xact_lock(hashtext('tenant:org_12345'));

    -- Non-blocking try-lock: returns FALSE immediately if another worker is currently processing:
    SELECT pg_try_advisory_xact_lock(hashtext('reconciliation:daily_20251025'));
    ```
  - Invariant: Always use `xact` variants (`pg_advisory_xact_lock`). Non-xact advisory locks (`pg_advisory_lock`) survive transaction commit and cause permanent lock leaks if the application crashes before executing `pg_advisory_unlock`.
- **Autovacuum Bloat Tuning on High-Churn Tables**:
  - Default PostgreSQL autovacuum triggers only when dead tuples exceed `50 + 20%` of the table (`autovacuum_vacuum_scale_factor = 0.2`). On a table with 20,000,000 rows, 4,000,000 dead rows accumulate before vacuum runs, causing massive table bloat, cache eviction, and sequential scan degradation.
  - ✅ **Per-Table Autovacuum Aggressive Invariant**:
    ```sql
    -- For high-churn queue, session, or audit tables:
    ALTER TABLE active_jobs SET (
        autovacuum_vacuum_scale_factor = 0.02,  -- Trigger vacuum after 2% churn
        autovacuum_vacuum_threshold = 1000,
        autovacuum_vacuum_cost_limit = 2000     -- Increase I/O budget so vacuum finishes rapidly
    );
    ```
- **Connection Pool Sizing: The Mathematical Little's Law Invariant**:
  - ❌ **The "More Connections = Faster DB" Delusion**: Setting application connection pools to 100 or 500 connections per pod starves CPU caches, causes massive OS context-switching storms, and exhausts backend RAM.
  - ✅ **The Spindle Formula (PostgreSQL & CockroachDB benchmark standard)**:
    $$\text{Optimal Connections} = (\text{CPU Cores} \times 2) + \text{Effective Spindle Count}$$
    On a modern 8-core NVMe server, the optimal pool size across *all* active application pods is typically **16 to 25 connections**.
  - **Transaction Pooling with PgBouncer**:
    - When hundreds of microservice instances or serverless workers connect, insert PgBouncer in `pool_mode = transaction`.
    - Invariant: In transaction pooling, session-level constructs are prohibited: never use `PREPARE` without PgBouncer prepared statement support, never use `LISTEN`/`NOTIFY`, and ensure connections clean state between transactions.

---

## 14. Declarative Table Partitioning, Safe Constraint Addition (`NOT VALID`) & Zero-Downtime Column Evolution
- **Declarative Range Partitioning for High-Volume Tables**:
  - Tables with millions of time-series records, audit logs, or ledger events degrade B-tree indexes and cause huge autovacuum penalties.
  - ✅ **Declarative Range Partitioning Invariant**:
    ```sql
    -- Parent partition table
    CREATE TABLE audit_logs (
        id bigint GENERATED ALWAYS AS IDENTITY,
        event_name text NOT NULL,
        created_at timestamptz NOT NULL,
        payload jsonb
    ) PARTITION BY RANGE (created_at);

    -- Child partitions per month
    CREATE TABLE audit_logs_2025_01 PARTITION OF audit_logs
        FOR VALUES FROM ('2025-01-01 00:00:00+00') TO ('2025-02-01 00:00:00+00');
    CREATE TABLE audit_logs_2025_02 PARTITION OF audit_logs
        FOR VALUES FROM ('2025-02-01 00:00:00+00') TO ('2025-03-01 00:00:00+00');
    ```
  - **Instant Retention Purging**: Never run `DELETE FROM audit_logs WHERE created_at < NOW() - INTERVAL '1 year'`. It generates massive WAL churn, dead tuple bloat, and table locks. Simply drop or detach the old partition instantly:
    ```sql
    ALTER TABLE audit_logs DETACH PARTITION audit_logs_2024_01 CONCURRENTLY;
    DROP TABLE audit_logs_2024_01;
    ```
  - **Partition Pruning**: Ensure queries filter by the partition key (`created_at`) so PostgreSQL scans only the relevant partition, bypassing 95%+ of table data.
- **Two-Step Zero-Downtime Foreign Key & Check Constraints (`NOT VALID` -> `VALIDATE CONSTRAINT`)**:
  - ❌ **The Direct Constraint Addition Outage**: Adding a foreign key directly on a 10M row table (`ALTER TABLE orders ADD CONSTRAINT fk_user FOREIGN KEY (user_id) REFERENCES users(id);`) acquires an `ACCESS EXCLUSIVE` lock while sequentially scanning the entire table. It blocks ALL queries and causes connection pool starvation.
  - ✅ **The Two-Step Production Invariant**:
    ```sql
    -- Step 1: Add constraint with NOT VALID (instant; acquires brief lock and validates new rows only)
    ALTER TABLE orders
      ADD CONSTRAINT fk_orders_user_id
      FOREIGN KEY (user_id) REFERENCES users(id)
      NOT VALID;

    -- Step 2: Validate existing historical data in the background (SHARE UPDATE EXCLUSIVE lock; does NOT block reads/writes)
    ALTER TABLE orders
      VALIDATE CONSTRAINT fk_orders_user_id;
    ```
- **Zero-Downtime Column Renaming & Type Evolution (The Expand-Contract Pattern)**:
  - ❌ Running `ALTER TABLE users RENAME COLUMN phone TO mobile;` immediately breaks older deployed application instances still querying `phone`.
  - ✅ **Production Expansion Invariant**:
    1. Add new column `mobile` as nullable.
    2. Write to both `phone` and `mobile` in application code (or via sync trigger).
    3. Backfill historical rows in chunks (`UPDATE users SET mobile = phone WHERE mobile IS NULL AND id BETWEEN ...`).
    4. Deploy application code reading and writing strictly to `mobile`.
    5. Drop the old column `phone` in a subsequent release after all old pods have terminated.
- **Zero-Downtime `NOT NULL` Addition on Existing Large Tables**:
  - In PostgreSQL 11+, adding a *new* column with a non-volatile default and `NOT NULL` (`ALTER TABLE users ADD COLUMN is_verified boolean DEFAULT false NOT NULL;`) is instantaneous because defaults are recorded in system catalogs without rewriting table rows.
  - ❌ **The Existing Column Lock Trap**: Running `ALTER TABLE orders ALTER COLUMN user_id SET NOT NULL;` on a pre-existing column acquires an `ACCESS EXCLUSIVE` lock and forces a full sequential table scan to check for nulls, freezing live traffic.
  - ✅ **Safe 3-Step Production Invariant**:
    ```sql
    -- Step 1: Add a NOT VALID check constraint (instant metadata update, no full scan)
    ALTER TABLE orders
      ADD CONSTRAINT orders_user_id_not_null
      CHECK (user_id IS NOT NULL) NOT VALID;

    -- Step 2: Validate existing data concurrently in background (does NOT block reads/writes)
    ALTER TABLE orders
      VALIDATE CONSTRAINT orders_user_id_not_null;

    -- Step 3: Set column NOT NULL (PostgreSQL 12+ proves it via constraint instantly without table scan)
    ALTER TABLE orders
      ALTER COLUMN user_id SET NOT NULL;

    -- Step 4: Drop redundant check constraint
    ALTER TABLE orders
      DROP CONSTRAINT orders_user_id_not_null;
    ```
- **High-Throughput Task Queues with `FOR UPDATE SKIP LOCKED`**:
  - ❌ **The Worker Serialization Trap**: Using `SELECT ... FOR UPDATE LIMIT 1` causes all worker threads to wait on the exact same locked row, destroying horizontal concurrency.
  - ✅ **Production Invariant**: Use `FOR UPDATE SKIP LOCKED` to allow worker processes to instantly claim distinct pending jobs in a single atomic CTE:
    ```sql
    WITH next_job AS (
      SELECT id
      FROM task_queue
      WHERE status = 'pending' AND scheduled_at <= NOW()
      ORDER BY priority DESC, id ASC
      FOR UPDATE SKIP LOCKED
      LIMIT 1
    )
    UPDATE task_queue
    SET status = 'processing',
        locked_by = 'worker_a',
        started_at = NOW()
    FROM next_job
    WHERE task_queue.id = next_job.id
    RETURNING task_queue.*;
    ```
- **PostgreSQL `work_mem` Sizing & Transaction-Scoped Allocation**:
  - ❌ **The Global `work_mem` OOM Catastrophe**: Setting `work_mem = '512MB'` globally in `postgresql.conf` causes server-wide Linux OOM-killer crashes. `work_mem` is NOT allocated per connection or per query—it is allocated **per sort/hash operation within each query execution plan node**. A single complex query with 4 sorts and 2 hash joins can consume `6 * 512MB = 3GB` of RAM. Under 50 concurrent connections, the instance crashes instantly.
  - ✅ **Production Invariant**: Keep global `work_mem` conservative (e.g., `16MB` to `64MB`) to safeguard OLTP operations. For heavy analytical or batch jobs, elevate `work_mem` strictly within the dedicated session or transaction scope:
    ```sql
    BEGIN;
    -- Elevate memory strictly for this analytical transaction:
    SET LOCAL work_mem = '256MB';

    SELECT customer_id, SUM(amount), DENSE_RANK() OVER (ORDER BY SUM(amount) DESC)
    FROM transactions
    WHERE created_at >= NOW() - INTERVAL '30 days'
    GROUP BY customer_id;

    COMMIT; -- Automatically resets work_mem back to server default
    ```
- **Production Query Bottleneck Diagnostics with `track_io_timing` & `auto_explain`**:
  - ❌ Running manual `EXPLAIN (ANALYZE, BUFFERS)` requires reproducing production traffic manually and cannot diagnose transient spikes or lock contention in real-time.
  - ✅ **Production Invariant**:
    - Enable `track_io_timing = on` in `postgresql.conf` (negligible CPU overhead on modern hypervisors, reveals whether queries are CPU-bound or disk I/O-bound in `pg_stat_database`).
    - Use `auto_explain` to log execution plans of slow queries automatically without modifying application code:
      ```ini
      # postgresql.conf
      shared_preload_libraries = 'auto_explain'
      auto_explain.log_min_duration = '500ms' # Log plans for queries taking >500ms
      auto_explain.log_analyze = 'on'
      auto_explain.log_buffers = 'on'
      auto_explain.log_timing = 'off'         # Minimizes measurement overhead
      auto_explain.log_format = 'json'
      ```
- **PostgreSQL Connection Pool Sizing & CPU Core Saturation Invariant**:
  - ❌ **The `max_connections = 1000` Throughput Collapse**: PostgreSQL allocates an isolated OS process per client connection. Setting high connection counts (e.g. 500–1000) under concurrent load causes CPU thrashing, spinlock/latch contention, and TLB cache invalidation. Throughput plummets while query latency increases exponentially.
  - ✅ **Production Invariant**:
    - Calculate backend database connections using the empirical Little's Law formula:
      $$\text{connections} = (2 \times \text{CPU cores}) + \text{effective disk spindle count}$$
      An 8-core server achieves peak query throughput with ~16–25 active backend database connections.
    - Deploy **PgBouncer** or **Odyssey** in front of PostgreSQL in `transaction` pooling mode to multiplex thousands of microservice clients into a compact, high-efficiency backend connection pool.
- **Transaction ID (TXID) Wraparound Catastrophe & Autovacuum Tuning**:
  - ❌ **The Emergency Read-Only Shutdown Trap**: PostgreSQL uses a 32-bit transaction counter (2.1 billion transactions). If autovacuum is throttled by conservative defaults on high-throughput databases, old row transaction IDs fail to freeze before reaching the 2-billion threshold. PostgreSQL enters a forced emergency read-only shutdown mode (`FATAL: database is not accepting commands to avoid wraparound data loss`) that requires manual single-user mode vacuuming during prolonged outages.
  - ✅ **Production Invariant**:
    - Unthrottle autovacuum for modern NVMe storage in `postgresql.conf`:
      ```ini
      autovacuum_max_workers = 5
      autovacuum_vacuum_cost_limit = 2000   # Raised from default 200 to allow autovacuum to complete rapidly
      autovacuum_vacuum_cost_delay = 2ms     # Reduced from default 20ms
      autovacuum_freeze_max_age = 1000000000 # Freeze aggressively before reaching crisis
      ```
    - Monitor transaction age continuously with Prometheus/Datadog:
      ```sql
      SELECT datname, age(datfrozenxid) AS xid_age
      FROM pg_database
      WHERE datallowconn
      ORDER BY xid_age DESC;
      ```

---

## 15. Zero-Downtime Enum Evolution, Safe `NOT NULL` Defaults & DDL Queue Starvation Defense
- **Zero-Downtime PostgreSQL Enum Evolution**:
  - ❌ **The In-Transaction `ALTER TYPE ADD VALUE` Trap**: In PostgreSQL, `ALTER TYPE ... ADD VALUE` cannot be committed inside an active multi-statement transaction block if the new enum value is used within that same transaction, triggering `ERROR: ALTER TYPE ... ADD VALUE cannot be executed from a function or multi-command string`.
  - ✅ **Production Invariant**: Execute `ALTER TYPE ... ADD VALUE IF NOT EXISTS 'new_val';` as an isolated, standalone autocommit statement before running application migrations that insert rows referencing the new enum value.
- **Safe `NOT NULL` Columns with Defaults**:
  - ❌ **The Volatile Default Full-Table Rewrite Freeze**: In PostgreSQL 11+, adding a column with a constant default (`DEFAULT 0` or `DEFAULT 'pending'`) is metadata-only ($O(1)$) and avoids table rewrites. However, using a volatile default function (e.g. `DEFAULT clock_timestamp()`, `DEFAULT gen_random_uuid()` without immutable wrapper) forces an immediate full table rewrite under an `ACCESS EXCLUSIVE` table lock, halting all client queries.
  - ✅ **Production Invariant**: Verify that defaults are strictly compile-time immutable constants, or add the column as nullable first, populate via chunked batches, and then attach `CHECK (col IS NOT NULL) NOT VALID` followed by `VALIDATE CONSTRAINT`.
- **Lock Queue Starvation & Explicit DDL `lock_timeout` Guard**:
  - ❌ **The Cascading Connection Saturation Outage**: When a DDL migration requests `ACCESS EXCLUSIVE` lock on a busy table, PostgreSQL puts the DDL statement in the lock wait queue. ALL subsequent incoming `SELECT`, `INSERT`, and `UPDATE` queries on that table queue up BEHIND the DDL lock request. In seconds, client connection pools saturate and the entire application crashes.
  - ✅ **Production Invariant**: ALWAYS configure explicit `lock_timeout` before executing DDL migrations:
    ```sql
    -- Abort DDL if table lock cannot be acquired within 2 seconds:
    SET lock_timeout = '2s';
    SET statement_timeout = '10s';

    ALTER TABLE orders ADD COLUMN notes TEXT;
    ```
    If another long-running query is holding a lock, the migration fails immediately without cascading into a site-wide queuing outage.

---

## 16. Heap-Only Tuple (`HOT`) Updates, Partition Pruning & Lock Ordering
- **PostgreSQL Heap-Only Tuple (`HOT`) Updates & `fillfactor` Optimization**:
  - ❌ **The Index Write Amplification Catastrophe**: By default (`fillfactor = 100`), PostgreSQL fills table pages to 100% capacity. Any `UPDATE` statement creates a new row tuple in a different disk page and must update EVERY index on the table, generating massive WAL traffic and disk I/O bottlenecks.
  - ✅ **Production Invariant**: For high-frequency update tables (e.g., counters, sessions, payment states), set `fillfactor = 80 ~ 90` and ensure frequently updated columns are not indexed. This enables **Heap-Only Tuple (HOT)** updates, modifying rows within the same page without updating any indexes:
    ```sql
    ALTER TABLE user_sessions SET (fillfactor = 85);
    VACUUM FULL user_sessions; -- Apply page reorganization
    ```
    Verify HOT optimization efficiency via `pg_stat_user_tables`:
    ```sql
    SELECT relname, n_tup_upd, n_tup_hot_upd,
           round((n_tup_hot_upd::numeric / NULLIF(n_tup_upd, 0)) * 100, 2) AS hot_ratio
    FROM pg_stat_user_tables
    WHERE n_tup_upd > 1000;
    ```
- **Declarative Partitioning & Zero-Cost Partition Pruning Invariant**:
  - ❌ **The Missing Partition Key Scan Penalty**: Creating monthly partitions on audit logs or ledger entries (`PARTITION BY RANGE (created_at)`), but issuing queries that filter only by `account_id` without `created_at`, forces PostgreSQL to execute a full sequential scan across every single child partition.
  - ✅ **Production Invariant**: Always include the partition key in all query filters to enable **Partition Pruning**:
    ```sql
    -- ✅ Scans only 1 partition (orders_2026_10):
    SELECT id, amount, status FROM orders
    WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01'
      AND account_id = :acc_id;
    ```
    Retire historical data instantly via `ALTER TABLE orders DETACH PARTITION orders_2023_01; DROP TABLE orders_2023_01;` instead of running `DELETE FROM orders WHERE ...`, freeing gigabytes of disk in milliseconds with zero autovacuum debt.
- **Deterministic Multi-Row Lock Ordering to Eliminate Deadlocks**:
  - ❌ **The Interleaved Lock Deadlock**: Transaction 1 updates rows in order `[ID: 10, ID: 20]`, while Transaction 2 concurrently updates rows in order `[ID: 20, ID: 10]`. Both transactions acquire one row lock and block waiting for the other, triggering `ERROR: deadlock detected`.
  - ✅ **Production Invariant**: Always sort IDs ascending in application logic or in SQL before acquiring row-level locks or executing bulk updates:
    ```sql
    -- Batch update with deterministic ascending lock acquisition:
    UPDATE accounts
    SET balance = balance + v.delta
    FROM (
        SELECT unnest($1::uuid[]) AS id, unnest($2::bigint[]) AS delta
        ORDER BY 1 ASC
    ) AS v
    WHERE accounts.id = v.id;
    ```

---

## 17. `work_mem` Per-Operation Sizing, REINDEX CONCURRENTLY & Automated Slow Query Plans
- **PostgreSQL `work_mem` Per-Operation Sizing & Server-Wide OOM Defense**:
  - ❌ **The Multiplied `work_mem` Server Crash Trap**: `work_mem` is allocated **per sort and per hash operation per query**, NOT per connection. A single complex query with 4 sorts and 2 hash joins across 50 concurrent connections will consume $6 \times 50 = 300 \times \text{work\_mem}$. Setting `work_mem = 512MB` globally will instantly cause the Linux kernel OOM killer to invoke `SIGKILL` on the PostgreSQL primary process.
  - ✅ **Production Invariant**: Keep global `work_mem` modest (`16MB`–`32MB`), and dynamically raise it per transaction for heavy batch/analytical reporting:
    ```sql
    BEGIN;
    -- Temporarily elevate work_mem only for this analytical reporting session:
    SET LOCAL work_mem = '256MB';

    SELECT customer_id, sum(amount), percent_rank() OVER (ORDER BY sum(amount) DESC)
    FROM orders
    GROUP BY customer_id;
    COMMIT;
    ```
- **Zero-Downtime Index Corruption & Bloat Repair via `REINDEX CONCURRENTLY`**:
  - ❌ **The Table Lock Freeze Trap**: Executing standard `REINDEX TABLE orders;` acquires an `ACCESS EXCLUSIVE` lock on the entire table, blocking all concurrent `SELECT`, `INSERT`, `UPDATE`, and `DELETE` queries until completion.
  - ✅ **Production Invariant**: In production environments, always execute `REINDEX CONCURRENTLY`:
    ```sql
    -- Builds replacement index in background without blocking reads or writes:
    REINDEX TABLE CONCURRENTLY orders;
    ```
- **Automated Slow Query Plan Diagnostics with `track_io_timing = on` and `auto_explain`**:
  - ❌ **The Missing I/O Visibility Blindspot**: Default PostgreSQL metrics only report elapsed execution time, concealing whether a 2-second query was stalled on CPU or blocked waiting for disk blocks to read into memory.
  - ✅ **Production Invariant**: Enable I/O timing and automated query plan logging in `postgresql.conf`:
    ```ini
    track_io_timing = on
    shared_preload_libraries = 'auto_explain'
    auto_explain.log_min_duration = '500ms'
    auto_explain.log_analyze = on
    auto_explain.log_buffers = on
    auto_explain.log_timing = on
    auto_explain.log_nested_statements = on
    ```

---

## 18. Sequence Integer Overflow (`INT4` -> `BIGINT`), `maintenance_work_mem` Sizing & Extended Statistics
- **The PostgreSQL 2-Billion Integer (`INT4`) Serial Sequence Overflow Catastrophe**:
  - ❌ **The Ticking Sequence Exhaustion Time Bomb**: Tables created with `SERIAL` or `INT4` auto-incrementing primary keys cap out at $2^{31}-1 = 2,147,483,647$. When the sequence hits the maximum value, all subsequent `INSERT` statements fail with `integer out of range`, triggering a total outage of critical production services. Executing `ALTER TABLE orders ALTER COLUMN id TYPE BIGINT;` on a 2-billion row table acquires an `ACCESS EXCLUSIVE` lock and rewrites the entire multi-hundred-gigabyte table on disk, causing hours of catastrophic downtime!
  - ✅ **Production Invariant**: Always create primary keys with `BIGINT GENERATED ALWAYS AS IDENTITY` (or sequential UUIDv7). For migrating an existing active table approaching the `INT4` limit without downtime, use the expand-and-contract dual-column backfill pattern with a sync trigger.
- **`maintenance_work_mem` Sizing & Parallel Index Workers**:
  - ❌ **The Truncated Index Build & Thrashing Vacuum**: By default, `maintenance_work_mem` is only 64MB. Running `CREATE INDEX CONCURRENTLY` or `VACUUM` on a 100M row table with 64MB forces the process into multiple temporary disk spill sorting cycles, increasing index build duration by $5\times$ to $10\times$.
  - ✅ **Production Invariant**: Tune `maintenance_work_mem` and `max_parallel_maintenance_workers` appropriately for index creation and autovacuum maintenance:
    ```sql
    -- For session performing heavy index builds:
    SET maintenance_work_mem = '2GB';
    SET max_parallel_maintenance_workers = 4;
    CREATE INDEX CONCURRENTLY idx_orders_customer_created ON orders (customer_id, created_at DESC);
    ```
- **Extended Statistics on Correlated Columns (`CREATE STATISTICS`)**:
  - ❌ **The Multiplication Assumption Estimation Catastrophe**: The query planner assumes column independence by default. For strongly correlated columns (e.g. `country = 'US'` and `state = 'CA'`), it multiplies their individual selectivities ($0.05 \times 0.05 = 0.0025$), drastically underestimating row counts by orders of magnitude and choosing devastating Nested Loop plans instead of Hash Joins.
  - ✅ **Production Invariant**: Define multivariate extended statistics on correlated columns:
    ```sql
    CREATE STATISTICS stats_orders_country_state (dependencies, ndistinct) ON country, state FROM addresses;
    ANALYZE addresses;
    ```

---

## 19. Zero-Downtime Column Renaming, `pg_stat_statements` & Transaction Wraparound Safety
- **Zero-Downtime Column Renaming via Updatable Views / Dual-Write**:
  - ❌ **The Immediate Breaking Rename**: Executing `ALTER TABLE users RENAME COLUMN phone TO mobile_phone;` acquires an `ACCESS EXCLUSIVE` lock and instantly crashes all running microservices that are currently executing queries referencing `phone`.
  - ✅ **Production Invariant**: Use the Expand-Migrate-Contract pattern:
    1. **Expand**: Add `mobile_phone` as a nullable column and create a bi-directional trigger to synchronize `phone <-> mobile_phone`.
    2. **Backfill**: Batch-update existing rows in non-blocking batches (`WHERE mobile_phone IS NULL LIMIT 5000`).
    3. **Migrate**: Deploy code pointing to `mobile_phone`.
    4. **Contract**: Drop the sync trigger and old `phone` column safely during off-peak hours.
- **`pg_stat_statements` & Buffer Hit Ratio Diagnostics**:
  - ❌ **The Blind Index Creation Habit**: Guessing slow queries without profiling PostgreSQL's internal shared buffer usage.
  - ✅ **Production Invariant**: Identify top I/O consumers via `pg_stat_statements`:
    ```sql
    SELECT 
      queryid,
      substring(query, 1, 50) AS query_preview,
      calls,
      round(mean_exec_time::numeric, 2) AS avg_ms,
      round((100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0))::numeric, 2) AS hit_percent
    FROM pg_stat_statements
    ORDER BY total_exec_time DESC
    LIMIT 10;
    ```
- **Partial Uniqueness Constraints on Soft-Deleted Tables**:
  - ❌ **The Plain `UNIQUE` Soft-Delete Bug**: Creating a standard table constraint `UNIQUE (tenant_id, email)` when soft deletes (`deleted_at TIMESTAMP NULL`) are present permanently prevents an offboarded user or deleted record from ever re-registering with the same email address.
  - ✅ **Production Invariant**: Always implement uniqueness on soft-deleted tables using a partial unique index filtered strictly to active records:
    ```sql
    -- Allows unlimited soft-deleted historical rows while guaranteeing single active uniqueness:
    CREATE UNIQUE INDEX CONCURRENTLY idx_users_tenant_email_active 
    ON users (tenant_id, lower(email)) 
    WHERE deleted_at IS NULL;
    ```
- **Optimistic Concurrency Control (OCC) with Monotonic Version Tokens**:
  - ❌ **The Blind Overwrite / Lost Update Catastrophe**: Executing a read-modify-write cycle (`SELECT` then in-memory calculation then `UPDATE products SET stock = :new_stock WHERE id = :id`) allows concurrent HTTP requests to interleave, silently overwriting each other's state changes and creating ghost inventory or double-spends.
  - ✅ **Production Invariant**: Enforce OCC using an atomic version token condition. If another transaction committed first, the update affects 0 rows, triggering an application-level retry loop:
    ```sql
    UPDATE inventory 
    SET 
      stock = stock - :quantity,
      version = version + 1,
      updated_at = NOW()
    WHERE id = :item_id 
      AND version = :expected_version 
      AND stock >= :quantity;
    ```
- **PostgreSQL Connection Starvation Defense: `idle_in_transaction_session_timeout`**:
  - ❌ **The Hanging Transaction Autovacuum Freeze**: A web server begins a transaction (`BEGIN`), queries rows, and then makes an external slow HTTP call or crashes. The connection remains in `idle in transaction` status, holding row/table locks and preventing PostgreSQL's autovacuum from advancing the `datfrozenxid` horizon. Eventually, this leads to cluster-wide database write freeze from transaction ID wraparound.
  - ✅ **Production Invariant**: Enforce a strict session ceiling at the user or database level to terminate abandoned transactions automatically:
    ```sql
    -- Kill any session lingering in an open transaction beyond 15 seconds:
    ALTER DATABASE app_production SET idle_in_transaction_session_timeout = '15s';
    
    -- Or configure per connection in pooled application roles:
    ALTER ROLE app_user SET idle_in_transaction_session_timeout = '10s';
    ```
- **PostgreSQL JSONB Subscripting (PG 14+) & Functional Expression Indexing**:
  - ❌ **The String Extraction Type Coercion Trap**: Using text extraction `(metadata->>'price')::numeric > 100` without matching expression indexes causes PostgreSQL to perform full sequential table scans over multi-gigabyte JSONB tables.
  - ✅ **Production Invariant**: In PostgreSQL 14+, use native bracket subscripting `metadata['price']` and build targeted functional indexes matching exact type casts:
    ```sql
    -- Functional B-tree index on casted numeric JSONB property:
    CREATE INDEX CONCURRENTLY idx_orders_metadata_amount 
    ON orders (((metadata['payment']['amount_cents'])::text::bigint))
    WHERE metadata['payment'] IS NOT NULL;

    -- Query executes via high-speed Index Scan:
    SELECT id, tenant_id 
    FROM orders 
    WHERE (metadata['payment']['amount_cents'])::text::bigint >= 5000;
    ```
- **PostgreSQL 15+ `UNIQUE NULLS NOT DISTINCT` vs Partial Unique Indexes**:
  - ❌ **The Infinite Duplicate NULL Hole**: Standard SQL-92 treats `NULL != NULL`. A unique constraint on `(tenant_id, slug, parent_id)` allows unlimited duplicate rows where `parent_id IS NULL`, causing silent business rule violations for root items. Historically, developers patched this with fragile dual partial indexes (`WHERE parent_id IS NOT NULL` and `WHERE parent_id IS NULL`).
  - ✅ **Production Invariant**: In PostgreSQL 15+, declare `NULLS NOT DISTINCT` directly in the unique constraint:
    ```sql
    -- PostgreSQL 15+: Treats NULLs as equal for uniqueness enforcement
    CREATE TABLE categories (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id UUID NOT NULL,
        slug VARCHAR(64) NOT NULL,
        parent_id UUID,
        CONSTRAINT uq_tenant_slug_parent UNIQUE NULLS NOT DISTINCT (tenant_id, slug, parent_id)
    );
    ```
- **`EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` Shared Buffer Hit Ratio Diagnosis**:
  - ❌ **Misleading Wall-Clock Timings in `EXPLAIN ANALYZE`**: Relying solely on raw execution times in development. A query that executes in 2ms on warm OS page cache during local testing will collapse in production under real disk I/O when buffer pages are evicted.
  - ✅ **Production Invariant**: Always inspect `BUFFERS` when optimizing SQL queries. Calculate the Shared Buffer Hit Ratio:
    $$\text{Hit Ratio} = \frac{\text{shared hit}}{\text{shared hit} + \text{shared read}} \times 100\%$$
    ```sql
    EXPLAIN (ANALYZE, BUFFERS, SETTINGS, TIMING)
    SELECT id, status, total_cents 
    FROM orders 
    WHERE tenant_id = 'c8b2...' AND status = 'pending';
    
    -- Invariant: Target >99% Hit Ratio on OLTP paths. If 'shared read' is high,
    -- add covering index columns (INCLUDE) or refine composite index ordering.
    ```
- **PostgreSQL Heap-Only Tuples (`HOT`) Updates & `fillfactor` Optimization**:
  - ❌ **The Index Write Amplification & Table Bloat Trap**: When updating a row in PostgreSQL, standard MVCC writes a new tuple and creates a new pointer in *every single index* on that table, even if none of the indexed columns were modified. On high-frequency update tables (e.g. user sessions, heartbeat statuses, account counters), this triggers severe index bloat and disk I/O thrashing.
  - ✅ **Production Invariant**: When an update modifies only non-indexed columns and free space exists on the same 8KB disk page, PostgreSQL performs a **Heap-Only Tuple (`HOT`) update**—chaining the new version on the same page without touching any index pointers. For write-heavy update tables, configure `fillfactor` to reserve page headroom:
    ```sql
    -- Reserve 15-20% free space per page for HOT updates:
    ALTER TABLE user_sessions SET (fillfactor = 85);
    
    -- Rebuild the table once to apply page headroom:
    VACUUM FULL user_sessions; -- Or pg_repack for zero-downtime online repack
    
    -- Verify HOT update ratio in production:
    SELECT 
        relname, 
        n_tup_upd, 
        n_tup_hot_upd,
        ROUND((n_tup_hot_upd::numeric / NULLIF(n_tup_upd, 0)) * 100, 2) AS hot_update_ratio_pct
    FROM pg_stat_user_tables
    WHERE relname = 'user_sessions';
    -- Invariant: Target >90% HOT update ratio on update-heavy OLTP tables.
    ```
- **PostgreSQL CTE (`WITH`) Optimization Fence: `AS MATERIALIZED` vs `AS NOT MATERIALIZED`**:
  - ❌ **The Accidental Multiple CTE Execution & Planner Trap**: In PostgreSQL 12+, CTEs are automatically inlined (`AS NOT MATERIALIZED`) by default. While this allows predicate pushdown, referencing a complex non-trivial CTE multiple times causes PostgreSQL to execute the expensive subquery multiple times! Conversely, forcing CTE materialization on large datasets prevents PostgreSQL from pushing outer `WHERE` filters down into the CTE.
  - ✅ **Production Invariant**: Explicitly declare `AS MATERIALIZED` when an expensive calculation is referenced across multiple joins and must be computed exactly once, and use `AS NOT MATERIALIZED` when outer filter pushdown is required:
    ```sql
    -- Enforce single execution of heavy aggregation shared by multiple branches:
    WITH high_value_cohort AS MATERIALIZED (
        SELECT user_id, SUM(amount_cents) as total_spend
        FROM orders
        WHERE created_at >= NOW() - INTERVAL '30 days'
        GROUP BY user_id
        HAVING SUM(amount_cents) > 100000
    )
    SELECT u.id, u.email, c.total_spend
    FROM users u
    JOIN high_value_cohort c ON c.user_id = u.id
    WHERE u.country_code = 'US';
    ```
- **PostgreSQL Subtransactions (`SAVEPOINT`) & `pg_subtrans` SLRU Thrashing Trap**:
  - ❌ **The Excessive Savepoint Performance Collapse**: Using nested transactions or ORMs with automatic savepoint rollback wrappers inside high-throughput loops or batch workers. In PostgreSQL, subtransactions are tracked in the shared memory `pg_subtrans` ring buffer. When a single top-level transaction exceeds 64 subtransactions, PostgreSQL can no longer cache subtransaction membership in the proc array; every subsequent visibility check incurs disk lookups and severe lock contention on `SubtransSLRU`, causing CPU usage to spike to 100% and stalling the entire database.
  - ✅ **Production Invariant**: Strictly prohibit `SAVEPOINT` inside high-frequency loops. For batch worker processing, commit top-level transactions in bounded chunks ($N = 1,000$) or catch and handle errors at the application boundary rather than relying on nested SQL savepoints.
- **PostgreSQL `TRUNCATE TABLE` AccessExclusiveLock Queue Starvation Trap**:
  - ❌ **The Cluster-Freezing Table Truncate**: Executing `TRUNCATE TABLE logs;` on an active production system. `TRUNCATE` requires an `ACCESS EXCLUSIVE` lock on the target table AND all tables referencing it with foreign keys. If long-running read queries are in flight, `TRUNCATE` queues up behind them, and subsequent incoming `SELECT` queries queue behind `TRUNCATE`, locking up all application traffic within seconds.
  - ✅ **Production Invariant**: Always guard `TRUNCATE` with a strict `lock_timeout`, or prefer chunked `DELETE` in batched loops yielding I/O:
    ```sql
    -- Method A: Guarded truncate with immediate fallback
    BEGIN;
    SET LOCAL lock_timeout = '2s';
    TRUNCATE TABLE audit_logs;
    COMMIT;

    -- Method B: Safe chunked deletion loop for high-traffic tables
    DO $$
    DECLARE
        rows_deleted INT := 1;
    BEGIN
        WHILE rows_deleted > 0 LOOP
            DELETE FROM audit_logs
            WHERE id IN (
                SELECT id FROM audit_logs
                WHERE created_at < NOW() - INTERVAL '90 days'
                LIMIT 5000
            );
            GET DIAGNOSTICS rows_deleted = ROW_COUNT;
            COMMIT; -- Release row locks and allow concurrent queries to breathe
            PERFORM pg_sleep(0.05); -- 50ms cooldown prevents replication lag
        END LOOP;
    END $$;
    ```
- **PostgreSQL `GENERATED ALWAYS AS IDENTITY` vs Deprecated `SERIAL`**:
  - ❌ **The Desynchronized Sequence Collision Bug**: Declaring primary keys with legacy `SERIAL` / `BIGSERIAL`. `SERIAL` is non-standard syntactic sugar that merely creates an independent sequence with default values. It allows applications to manually insert explicit IDs (`INSERT INTO users (id, name) VALUES (10, 'Alice')`) without advancing the underlying sequence. Days or weeks later, normal sequence-driven inserts collide with ID 10 and crash with duplicate key violation `23505`. Furthermore, dropping or altering the column does not automatically clean up permissions or sequence dependencies.
  - ✅ **Production Invariant**: In PostgreSQL 10+, always use SQL-standard `GENERATED ALWAYS AS IDENTITY` (or `BY DEFAULT` if explicit external migration IDs are needed). `GENERATED ALWAYS` strictly blocks accidental manual ID injection unless the caller explicitly supplies `OVERRIDING SYSTEM VALUE`:
    ```sql
    -- Production standard: SQL-conforming, tamper-proof auto-incrementing key
    CREATE TABLE orders (
        id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        customer_id UUID NOT NULL REFERENCES customers(id),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    ```
- **Top-N per Category / Cohort Queries: `LATERAL` Joins vs Window Function Scans**:
  - ❌ **The Full-Table Sort Window Function Trap**: Writing `ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY created_at DESC) as rn` to retrieve the latest 3 items per category. The query planner is forced to perform a complete sequential scan and sort across the ENTIRE table (e.g. 50 million rows) before discarding rows where `rn > 3`.
  - ✅ **Production Invariant**: Use `CROSS JOIN LATERAL` or `LEFT JOIN LATERAL` paired with a composite index `(category_id, created_at DESC)`. The database performs an instantaneous index seek for each category, dropping query latency from 8,500ms to 1.2ms:
    ```sql
    -- Requires index: CREATE INDEX idx_products_cat_created ON products (category_id, created_at DESC);
    SELECT c.name AS category_name, p.id, p.title, p.price_cents, p.created_at
    FROM categories c
    CROSS JOIN LATERAL (
        SELECT id, title, price_cents, created_at
        FROM products
        WHERE category_id = c.id
        ORDER BY created_at DESC
        LIMIT 3
    ) p;
    ```
- **Partial (Filtered) Indexes for Active Queues & Soft-Deletions**:
  - ❌ **The Bloated Index Thrash**: Creating a standard B-tree index on `(status, created_at)` in a high-throughput queue or events table where 99% of rows are `status = 'COMPLETED'`. The index grows to tens of gigabytes, wastes buffer pool RAM, and slows every update with unnecessary index maintenance.
  - ✅ **Production Invariant**: Build partial indexes filtering exclusively for active/unprocessed states or non-deleted rows. The resulting index is often 98% smaller, fits entirely in L3/RAM cache, and accelerates queries (`SELECT ... FOR UPDATE SKIP LOCKED`) by orders of magnitude:
    ```sql
    -- High-performance queue worker index: Only indexes actionable rows
    CREATE INDEX CONCURRENTLY idx_orders_active_queue
    ON orders (priority DESC, created_at ASC)
    WHERE status IN ('PENDING', 'PROCESSING');

    -- High-performance soft-delete unique constraint:
    CREATE UNIQUE INDEX CONCURRENTLY idx_users_active_email
    ON users (email)
    WHERE deleted_at IS NULL;
    ```
- **Mandatory Foreign Key Supporting Indexes to Prevent Table-Level Lockout Deadlocks**:
  - ❌ **The Cascading ShareRowExclusiveLock Disaster**: Creating a foreign key constraint without creating an index on the referencing column in the child table. When a row is deleted or primary key updated in the parent table, PostgreSQL is forced to perform a sequential scan on the child table, acquiring a restrictive `ShareRowExclusiveLock`. Under concurrency, this blocks all inserts and updates to the child table, causing cascading connection pool exhaustion and deadlocks.
  - ✅ **Production Invariant**: Every foreign key MUST have an explicit index on the foreign key column in the child table:
    ```sql
    -- Always index the referencing column!
    CREATE TABLE order_items (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
        product_id UUID NOT NULL REFERENCES products(id),
        quantity INT NOT NULL CHECK (quantity > 0)
    );

    -- Mandatory supporting indexes:
    CREATE INDEX CONCURRENTLY idx_order_items_order_id ON order_items (order_id);
    CREATE INDEX CONCURRENTLY idx_order_items_product_id ON order_items (product_id);
    ```
- **PostgreSQL TOAST Table Bloat & In-Line JSONB Thrashing**:
  - ❌ **The Unfiltered TOAST Scan & Write Amplification**: Storing multi-megabyte `JSONB` or large `TEXT` documents directly in high-velocity transaction tables (e.g., `events`, `orders`, `audit_logs`). In PostgreSQL, attributes exceeding ~2KB are compressed and pushed into out-of-line TOAST tables. Even though a query only updates `status = 'PROCESSED'`, PostgreSQL's MVCC creates a new tuple and duplicates TOAST references; and if the JSONB itself is updated, full TOAST chunks are rewritten, multiplying disk I/O by 10x and causing massive VACUUM degradation.
  - ✅ **Production Invariant**: Vertically partition large semi-structured payloads into dedicated auxiliary storage tables, keeping the high-velocity operational table lean, fast, and cache-friendly:
    ```sql
    -- High-throughput operational table: Fits entirely in buffer cache
    CREATE TABLE webhook_events (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id UUID NOT NULL,
        event_type VARCHAR(64) NOT NULL,
        status VARCHAR(32) NOT NULL DEFAULT 'PENDING',
        retry_count INT NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
    );

    -- Isolated heavyweight payload table: Read only upon final processing
    CREATE TABLE webhook_payloads (
        event_id UUID PRIMARY KEY REFERENCES webhook_events(id) ON DELETE CASCADE,
        headers JSONB NOT NULL,
        raw_body TEXT NOT NULL,
        decompressed_size INT GENERATED ALWAYS AS (octet_length(raw_body)) STORED
    );
    ```
- **Session-Level `idle_in_transaction_session_timeout` to Prevent Connection Pool Exhaustion**:
  - ❌ **The Dormant Transaction Lock Freeze**: An application handler starts a database transaction (`BEGIN`), then executes a slow external network call (e.g. Stripe payment, OpenAI LLM completion, or S3 upload) while holding row locks. If the HTTP call hangs or takes 30 seconds, PostgreSQL transaction IDs stay open, active locks block other transactions, autovacuum is blocked from cleaning dead tuples, and the connection pool saturates.
  - ✅ **Production Invariant**: Enforce strict session and database timeouts, and NEVER execute external I/O or network requests inside database transactions:
    ```sql
    -- Enforce at database or user level:
    ALTER DATABASE production_db SET idle_in_transaction_session_timeout = '5000ms';
    ALTER DATABASE production_db SET statement_timeout = '15000ms';
    ```
- **BRIN vs B-Tree Index Selection for Massive Append-Only Time-Series Tables**:
  - ❌ **The Multi-Gigabyte B-Tree Index RAM Bloat**: Creating standard B-Tree indexes on monotonically increasing timestamps (`created_at`) across tables with hundreds of millions of append-only audit, event, or telemetry logs. A B-Tree index on a 200M row table can consume 8GB–15GB of RAM, evicting active database buffer cache and degrading write throughput with constant tree rebalancing.
  - ✅ **Production Invariant**: Use Block Range Indexes (BRIN) for append-only tables where physical disk order naturally correlates with column values. A BRIN index only stores minimum and maximum values for physical disk page ranges (e.g. 128 pages), shrinking index footprint from 10 GB down to 5 MB (a 99.9% reduction) while preserving fast range-scan performance:
    ```sql
    -- Massive append-only logs table:
    CREATE TABLE audit_logs (
        id UUID DEFAULT gen_random_uuid(),
        tenant_id UUID NOT NULL,
        event_name VARCHAR(128) NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
    );

    -- 99% smaller index footprint with near-zero write maintenance overhead:
    CREATE INDEX CONCURRENTLY idx_audit_logs_created_at_brin
    ON audit_logs USING BRIN (created_at)
    WITH (pages_per_range = 128);
    ```
- **PgBouncer Transaction Pooling Mode Prepared Statement Traps & Server Reset**:
  - ❌ **The "Prepared Statement Already Exists" Collision**: Using server-side named prepared statements (`PREPARE stmt AS ...`) with connection poolers (PgBouncer, AWS RDS Proxy) running in `transaction` pooling mode. Because physical backend connections are reallocated to different client sessions across transactions, named statements from Client A persist into Client B's session, triggering `ERROR: prepared statement "..." already exists` or `does not exist`.
  - ✅ **Production Invariant**: When deploying with PgBouncer transaction mode, configure database drivers to use client-side parameter interpolation, protocol-level unnamed prepared statements, or configure `server_reset_query = DISCARD ALL` in PgBouncer to wipe session state between transactions:
    ```ini
    # pgbouncer.ini
    pool_mode = transaction
    server_reset_query = DISCARD ALL
    max_prepared_statements = 0
    ```
- **Transaction ID (XID) Wraparound Catastrophe & Autovacuum Aggressiveness**:
  - ❌ **The Emergency Read-Only Lockout Disaster**: PostgreSQL uses 32-bit transaction IDs, wrapping around after 2 billion transactions. If long-running transactions, orphaned replication slots, or disabled autovacuum prevent the vacuum worker from freezing old tuples, PostgreSQL reaches `autovacuum_freeze_max_age` and forces the entire database cluster into read-only emergency mode (`FATAL: database is not accepting commands to avoid wraparound data loss`).
  - ✅ **Production Invariant**: Monitor `SELECT max(age(datfrozenxid)) FROM pg_database;` in Prometheus alerting (trigger critical alarm at > 1.2 billion), drop abandoned replication slots, and configure aggressive autovacuum freeze worker settings so freeze passes complete continuously in the background without causing transaction starvation.
- **Recursive CTEs (`WITH RECURSIVE`) & Infinite Graph Cycle Protection**:
  - ❌ **The Infinite Loop Memory & CPU Exhaustion**: Querying hierarchical graphs (knowledge graphs, organization charts, file directory trees, task dependency DAGs) using naive `WITH RECURSIVE` queries without cycle detection. If any circular reference or bidirectional edge exists (Entity A -> Entity B -> Entity A), the query worker enters an infinite loop, allocating gigabytes of memory until killed by OOM or connection timeout.
  - ✅ **Production Invariant**: Always enforce a hard depth ceiling (`depth <= 10`) and track visited nodes using an array (`path`) or PostgreSQL 14+ native `CYCLE ... SET is_cycle USING path` clause to short-circuit recursion immediately upon detecting cycles:
    ```sql
    -- PostgreSQL 14+ idiomatic graph traversal with cycle guard:
    WITH RECURSIVE entity_hierarchy AS (
        -- Anchor member:
        SELECT id, parent_id, name, 1 AS depth
        FROM knowledge_nodes
        WHERE id = :root_entity_id

        UNION ALL

        -- Recursive member:
        SELECT kn.id, kn.parent_id, kn.name, eh.depth + 1
        FROM knowledge_nodes kn
        JOIN entity_hierarchy eh ON kn.parent_id = eh.id
        WHERE eh.depth < 10 -- Mandatory hard depth ceiling
    )
    CYCLE id SET is_cycle USING path -- Halts recursion instantly on cycle detection
    SELECT id, parent_id, name, depth, path
    FROM entity_hierarchy
    WHERE NOT is_cycle;
    ```
- **Zero-Downtime Partition Attachment via Pre-Validated Check Constraints**:
  - ❌ **The `ACCESS EXCLUSIVE` Lock Contention Freeze**: Running `ALTER TABLE parent ATTACH PARTITION child FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');` directly on a live high-throughput table. PostgreSQL must scan every single row of `child` to verify that values fall strictly within the partition bounds. During this full table scan, PostgreSQL holds an `ACCESS EXCLUSIVE` lock on `parent`, queueing behind slow queries and instantly deadlocking all incoming reads and writes.
  - ✅ **Production Invariant**: Always create an exact matching `CHECK` constraint on `child` with `NOT VALID`, validate it separately (`VALIDATE CONSTRAINT` acquires only a weak `SHARE UPDATE EXCLUSIVE` lock that allows concurrent reads and writes), and then attach the partition. PostgreSQL detects the validated constraint and skips the full scan, attaching in under 5 milliseconds:
    ```sql
    -- Step 1: Add non-blocking check constraint
    ALTER TABLE orders_2026_03
      ADD CONSTRAINT check_partition_bounds
      CHECK (created_at >= '2026-03-01' AND created_at < '2026-04-01')
      NOT VALID;

    -- Step 2: Validate constraint concurrently (no write blocking)
    ALTER TABLE orders_2026_03
      VALIDATE CONSTRAINT check_partition_bounds;

    -- Step 3: Attach partition instantly (skips table scan, <5ms metadata lock)
    SET lock_timeout = '2s';
    ALTER TABLE orders
      ATTACH PARTITION orders_2026_03
      FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');

    -- Step 4: Drop redundant check constraint (partition bounds supersede it)
    ALTER TABLE orders_2026_03
      DROP CONSTRAINT check_partition_bounds;
    ```
- **PostgreSQL `GENERATED ALWAYS AS (expr) STORED` vs Expression Indexes**:
  - ❌ **The STORED Generated Column WAL & Tuple Bloat**: Using `STORED` generated columns for frequently updated JSON extractions or string formatting (`full_name TEXT GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED`). STORED columns physically write duplicate bytes to disk on every row, reducing row density per 8KB page, increasing I/O cache misses, and doubling WAL generation during write spikes.
  - ✅ **Production Invariant**: For read-heavy query filtering or sorting on derived attributes, prefer Expression Indexes (`CREATE INDEX idx_users_full_name ON users ((first_name || ' ' || last_name));`) or virtual generated views. Only use `STORED` generated columns when the column must be directly referenced by foreign key constraints or exported via replication tools.
- **PostgreSQL Concurrent Work Queues via `FOR UPDATE SKIP LOCKED`**:
  - ❌ **The `FOR UPDATE` Lock Convoy & Head-of-Line Blocking Trap**: Building background task queues with `SELECT id FROM jobs WHERE status = 'pending' ORDER BY created_at ASC LIMIT 1 FOR UPDATE;`. When multiple worker processes poll the queue concurrently, every worker waits behind the first worker's transaction lock. If worker 1 takes 2 seconds to process its job, all other workers are frozen in a lock convoy, collapsing concurrency from $N$ workers to strictly 1 serialized worker.
  - ✅ **Production Invariant**: Always use `FOR UPDATE SKIP LOCKED`. PostgreSQL skips rows locked by concurrent transactions, allowing $N$ workers to claim $N$ distinct jobs simultaneously with zero lock contention:
    ```sql
    -- Atomic, non-blocking job claim across concurrent workers
    WITH claimed_job AS (
      SELECT id
      FROM background_jobs
      WHERE status = 'pending'
        AND scheduled_at <= CLOCK_TIMESTAMP()
      ORDER BY priority DESC, scheduled_at ASC
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    UPDATE background_jobs j
    SET status = 'processing',
        locked_at = CLOCK_TIMESTAMP(),
        worker_id = $1
    FROM claimed_job
    WHERE j.id = claimed_job.id
    RETURNING j.*;
    ```
- **PostgreSQL TOAST Storage Discipline & Hot-Row Updates**:
  - ❌ **The In-Page TOAST Thrashing & WAL Bloat**: Storing large payloads (e.g. 10KB+ JSONB execution traces or prompt histories) directly in primary entity rows with frequent status updates. Updating unrelated columns (e.g. `UPDATE agent_tasks SET status = 'active'`) still writes new row versions to the heap. If large JSONB attributes are modified repeatedly, uncompressed updates trigger massive WAL amplification and exhaust autovacuum workers.
  - ✅ **Production Invariant**: Segregate volatile status columns from large semi-static payloads into a 1:1 auxiliary table (e.g., `agent_tasks` vs `agent_task_payloads`). For pre-compressed data (gzipped bytes or images), alter column storage to `EXTERNAL` (`ALTER TABLE agent_task_payloads ALTER COLUMN raw_blob SET STORAGE EXTERNAL;`) to skip redundant and costly lz4/pglz compression CPU cycles.
- **PostgreSQL `LISTEN` / `NOTIFY` Payload Limits & Outbox Decoupling**:
  - ❌ **The 8,000-Byte Notification Crash**: Attempting to broadcast large JSON payloads directly through `pg_notify('channel', large_json)`. PostgreSQL enforces a strict hard ceiling of 8,000 bytes on notify payloads; exceeding this causes an immediate `54000: payload string too long` database error and aborts the enclosing transaction.
  - ✅ **Production Invariant**: Broadcast only a lightweight reference envelope containing the table name, event type, and primary key UUID:
    ```sql
    -- Send lightweight event envelope (<128 bytes)
    PERFORM pg_notify('agent_events', json_build_object(
      'table', 'agent_runs',
      'action', 'COMPLETED',
      'id', NEW.id
    )::text);
    ```
    Subscribers receive the notification and fetch the full entity state via primary key lookup.
- **Partition Pruning Invariants & Dynamic Query Anti-Patterns**:
  - ❌ **The Runtime Pruning De-Optimization**: Partitioning large event tables (e.g., `audit_logs` by month) but querying using non-immutable functions or un-indexed expressions (e.g. `WHERE DATE_TRUNC('month', created_at) = '2026-03-01'::timestamptz`). PostgreSQL cannot prune partition branches at planning time, forcing sequential scans across all hundreds of sub-partitions.
  - ✅ **Production Invariant**: Always provide direct, sargable range boundaries on the exact partitioning key (`WHERE created_at >= '2026-03-01' AND created_at < '2026-04-01'`). Verify partition pruning in `EXPLAIN` output: look for `Partitions pruned: N` and ensure only the targeted partition table is scanned.
- **PostgreSQL Transaction ID (TXID) Wraparound Prevention & Freeze Map Tuning**:
  - ❌ **The 2-Billion Transaction Catastrophic Read-Only Shutdown**: High-throughput write workloads and agent event stores generate billions of transaction IDs. If autovacuum cannot keep up with freezing old tuples, PostgreSQL reaches `autovacuum_freeze_max_age` (default 200M) and ultimately shuts down into single-user emergency read-only mode at 2.1 billion transactions to prevent silent data corruption.
  - ✅ **Production Invariant**: Proactively monitor TXID age (`SELECT max(age(datfrozenxid)) FROM pg_database;`). On modern NVMe storage, raise `autovacuum_vacuum_cost_limit = 2000` (up from default 200) and lower `autovacuum_vacuum_cost_delay = 2ms` so autovacuum freezes old tuples at 10x throughput without starving client connections.
- **Foreign Key Index Invariants & Cascade Lock Serialization**:
  - ❌ **The Missing Foreign Key Index Cascade Lock**: PostgreSQL creates unique indexes for `PRIMARY KEY` and `UNIQUE` constraints, but **NEVER** automatically indexes referencing foreign key columns (`REFERENCES users(id)`). Deleting or updating a parent record forces a table scan or row-level share locks on the child table, serializing concurrent writes and triggering massive production deadlock spikes.
  - ✅ **Production Invariant**: Always create explicit B-tree indexes on foreign key columns referencing parent tables:
    ```sql
    -- Mandatory child foreign key index preventing table lock serialization
    CREATE INDEX CONCURRENTLY idx_orders_user_id ON orders(user_id);
    CREATE INDEX CONCURRENTLY idx_order_items_order_id ON order_items(order_id);
    ```
- **PostgreSQL 16+ `pg_stat_io` Storage Diagnostics & Buffer Contention**:
  - ❌ **The Opaque I/O Bottleneck Guesswork**: Assuming high query latency is CPU-bound or guessing table scan bottlenecks without inspecting physical storage metrics. Historically, database administrators had to infer whether slow queries were waiting on client backends, autovacuum I/O thrashing, or background writer dirty page flushes.
  - ✅ **Production Invariant**: In PostgreSQL 16+, use `pg_stat_io` to identify exact I/O bottlenecks segmented by backend type (`client backend`, `autovacuum`, `background writer`), target object type (`relation`, `temp relation`), and I/O context (`normal`, `vacuum`, `bulkread`, `bulkwrite`):
    ```sql
    -- Diagnostic query: Identify backend disk reads vs buffer cache hits
    SELECT backend_type, io_object, io_context, reads, writes, extends, hits, evictions, reuses
    FROM pg_stat_io
    WHERE reads > 0 OR writes > 0
    ORDER BY reads DESC;
    ```
    If `evictions` spike in `client backend` under `normal` context, increase `shared_buffers` to eliminate disk read thrashing.
- **B-Tree Index Deduplication & High-Cardinality Sizing (PostgreSQL 13+)**:
  - ❌ **Disabling B-Tree Deduplication on Low-Uniqueness Columns**: Leaving default un-deduplicated B-tree structures on columns with recurring duplicates (e.g., status flags, category codes, foreign keys). This inflates index sizes on NVMe by 300–400% and triggers unnecessary page splits.
  - ✅ **Production Invariant**: Ensure B-Tree deduplication is enabled (`deduplicate_items = on`, default since PG13) on non-unique indexes. This coalesces duplicate posting lists into compact B-tree leaf pages, dramatically boosting shared buffer hit ratios and reducing index scan latency.
- **PostgreSQL 17+ Radix Tree Vacuum Optimization (`tidstore`) & Dead Tuple Management**:
  - ❌ **Inflating `maintenance_work_mem` to Prevent Multi-Pass Vacuuming**: In PostgreSQL 16 and older, `VACUUM` tracked dead tuple TIDs in a flat array limited by `maintenance_work_mem` (up to 1 GB holding ~178 million TIDs). When dead tuples exceeded this threshold, `VACUUM` was forced into expensive multi-pass index vacuuming, causing severe NVMe I/O thrashing.
  - ✅ **Production Invariant**: PostgreSQL 17 replaces flat TID arrays with an adaptive radix tree structure (`tidstore`). It reduces vacuum memory consumption by up to 20× and completely eliminates multi-pass index vacuuming on large bloats. Keep `maintenance_work_mem` reasonably bounded (e.g. 512MB to 1GB) rather than over-allocating, and monitor `pg_stat_progress_vacuum` to verify that `index_vacuum_count` remains 1 even under tens of millions of dead tuples.
- **Logical Replication Standby Failover Slots (`failover = true` & `sync_replication_slots`)**:
  - ❌ **The Post-Failover Replication Slot Desynchronization Disaster**: Promoting a physical read replica to primary during high-availability failover (e.g. Patroni) when downstream logical subscribers (ETL pipelines, analytics, microservices) consume logical slots from the old primary. The newly promoted primary lacks the subscriber's confirmed flush LSN, resulting in broken subscriptions (`replication slot does not exist`) and requiring catastrophic full table re-syncs.
  - ✅ **Production Invariant**: In PostgreSQL 17+, enable logical replication slot synchronization on physical standbys:
    ```sql
    -- On primary: Create logical failover slot
    SELECT pg_create_logical_replication_slot('sub_orders_slot', 'pgoutput', false, false, true); -- failover = true

    -- In postgresql.conf on physical standby:
    sync_replication_slots = true
    hot_standby_feedback = on
    ```
    Standby instances continuously synchronize logical slot confirmation points from the primary, enabling zero-downtime subscriber reconnection after primary failover without replay gap data loss.
- **PostgreSQL 16/17+ `pg_stat_io` Multi-Dimensional I/O Bottleneck Profiling**:
  - ❌ **Guessing Disk vs OS Page Cache I/O Bottlenecks**: Relying solely on `pg_stat_database` or cloud host metrics to diagnose slow queries, unable to distinguish whether reads were satisfied from PostgreSQL `shared_buffers`, the OS page cache, or physical NVMe disk blocks.
  - ✅ **Production Invariant**: Query `pg_stat_io` to observe granular breakdown of reads, writes, extends, hits, and evictions partitioned by backend type (`client backend`, `checkpointer`, `autovacuum`, `background writer`) and target context (`normal`, `vacuum`, `bulkread`, `bulkwrite`):
    ```sql
    SELECT
        backend_type,
        context,
        io_object,
        reads,
        writes,
        hits,
        round(100.0 * hits / nullif(hits + reads, 0), 2) AS buffer_hit_pct
    FROM pg_stat_io
    WHERE reads + writes + hits > 0
    ORDER BY reads DESC;
    ```
    If `evictions` spike in `client backend` under `normal` context, increase `shared_buffers` to eliminate disk read thrashing.
- **GIN `fastupdate` Bloat Defense & Background List Vacuuming**:
  - ❌ **Uncontrolled GIN Pending List Bloat**: Leaving `fastupdate = on` on high-ingestion JSONB or full-text GIN indexes without tuning `gin_pending_list_limit`. The pending list grows to tens of megabytes, causing random reader queries to stall for hundreds of milliseconds while performing inline list in-place reorganization (`gin_clean_pending_list`).
  - ✅ **Production Invariant**: Bound `gin_pending_list_limit` (e.g. `ALTER INDEX idx_events_payload SET (gin_pending_list_limit = '4MB')`) and schedule periodic off-peak invocations of `SELECT gin_clean_pending_list('idx_events_payload');` or disable `fastupdate` on read-critical search tables.
- **NVMe Storage `effective_io_concurrency` & `random_page_cost` Tuning**:
  - ❌ **Leaving Spinning-Disk Defaults on Cloud NVMe Instances**: Running modern cloud SSD / NVMe instances with default PostgreSQL settings (`effective_io_concurrency = 1`, `random_page_cost = 4.0`). The query planner penalizes index scans and executes slow sequential table scans, while the engine submits synchronous, serialized I/O requests that leave NVMe read queues idle.
  - ✅ **Production Invariant**: On SSD/NVMe storage (AWS EBS gp3/io2, Google Extreme SSD), set `random_page_cost = 1.1` (reflecting nearly identical random vs sequential latency) and tune `effective_io_concurrency = 200` to 300. This enables asynchronous prefetching (`posix_fadvise`) during Bitmap Heap Scans, saturating NVMe controller parallelism.
- **PostgreSQL 17+ Resilient `COPY` Streaming Ingestion (`ON_ERROR ignore`)**:
  - ❌ **Single-Row Failure Aborting Multi-Gigabyte Bulk Ingestions**: In PostgreSQL 16 and older, executing `COPY raw_events FROM STDIN` failed entirely if a single malformed row or invalid encoding was encountered after ingesting 50 million records, discarding all progress and rolling back the transaction.
  - ✅ **Production Invariant**: In PostgreSQL 17+, leverage `ON_ERROR ignore` to stream high-throughput batch imports without atomic total aborts:
    ```sql
    COPY raw_events FROM '/tmp/events_stream.csv' WITH (
        FORMAT csv,
        HEADER true,
        ON_ERROR ignore
    );
    ```
    Monitor skipped rows via `pg_stat_progress_copy` to inspect error counts without stalling critical ingestion pipelines.
- **`idle_in_transaction_session_timeout` & Vacuum Freeze Starvation Defense**:
  - ❌ **Abandoned Transactions Blocking Autovacuum & Fueling Wraparound**: A client opens a transaction (`BEGIN`), performs a query, and either stalls on a slow network call or crashes without calling `COMMIT` or `ROLLBACK`. The idle transaction holds the database-wide transaction horizon ($x_{\text{min}}$) hostage, preventing `VACUUM` from cleaning dead tuples across all tables, leading to catastrophic table bloat and emergency shutdowns from transaction ID wraparound.
  - ✅ **Production Invariant**: Always enforce a strict `idle_in_transaction_session_timeout` (e.g. `SET idle_in_transaction_session_timeout = '30s';` globally in `postgresql.conf` or per connection pool). Any connection idling inside an open transaction is forcibly terminated, reclaiming locks and advancing the vacuum horizon.
- **Transactional Queue Polling via `FOR UPDATE SKIP LOCKED`**:
  - ❌ **Head-of-Line Blocking & Deadlocks with Naked `SELECT ... FOR UPDATE`**: Polling job or task queues with `SELECT id FROM queue WHERE status = 'pending' LIMIT 1 FOR UPDATE;`. Multiple concurrent worker threads block on the exact same row lock, causing high latency, thread starvation, and frequent deadlock exceptions.
  - ✅ **Production Invariant**: Always append `SKIP LOCKED` in queue consumer workers:
    ```sql
    WITH next_task AS (
        SELECT id
        FROM task_queue
        WHERE status = 'pending'
        ORDER BY priority DESC, created_at ASC
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    )
    UPDATE task_queue
    SET status = 'processing', locked_at = NOW()
    FROM next_task
    WHERE task_queue.id = next_task.id
    RETURNING task_queue.*;
    ```
    Workers concurrently skip in-flight rows without blocking, achieving lock-free linear scale.
- **PostgreSQL 17+ `MERGE ... RETURNING` for Atomic Upserts with Mutation Tracking**:
  - ❌ **Two-Step Upsert or Blind `ON CONFLICT DO UPDATE` Without Action Audit**: Needing to know whether an atomic upsert operation actually inserted a new record or updated an existing one, forcing developers into separate `SELECT` pre-flight queries or ambiguous `RETURNING (xmax = 0) AS inserted` heuristics.
  - ✅ **Production Invariant**: In PostgreSQL 17+, use `MERGE` with `RETURNING merge_action()` to atomically apply updates/inserts and determine exact mutation actions in a single roundtrip:
    ```sql
    MERGE INTO user_profiles AS target
    USING incoming_profiles AS source
    ON target.user_id = source.user_id
    WHEN MATCHED AND target.updated_at < source.updated_at THEN
        UPDATE SET display_name = source.display_name, updated_at = source.updated_at
    WHEN NOT MATCHED THEN
        INSERT (user_id, display_name, updated_at)
        VALUES (source.user_id, source.display_name, source.updated_at)
    RETURNING merge_action(), target.user_id;
    ```
- **JSONB Path Subscripting vs Legacy `->>` Operator Index Selectivity**:
  - ❌ **Mixing Extraction Operators Breaking B-Tree Index Matching**: Creating a functional B-tree index using `(payload->>'user_id')` but querying with `payload['user_id']` or `payload->'user_id'`. PostgreSQL does not treat different extraction operators as interchangeable, resulting in silent index misses and full sequential scans.
  - ✅ **Production Invariant**: Standardize on PostgreSQL modern JSONB path subscripting (`payload['user_id']`) consistently across both index DDL and query DML, or define typed generated columns (`GENERATED ALWAYS AS (payload->>'user_id') STORED`) to decouple application queries from JSON extraction mechanics.


