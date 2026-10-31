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
- **PostgreSQL 16/17 `EXPLAIN (GENERIC_PLAN)` for Prepared Statement Plan Regression Diagnostics**:
  - ❌ **The Literal Parameter Estimation Trap**: Profiling slow queries by manually running `EXPLAIN ANALYZE` with a single literal value (e.g. `WHERE tenant_id = 42`). PostgreSQL computes a customized plan for that literal. However, in production microservices using connection pooling or ORMs, the server switches to a generic plan after 5 executions (`plan_cache_mode = auto`), which may pick a sequential scan or degraded nested loop, masking the true bottleneck.
  - ✅ **Production Invariant**: Inspect parameter-agnostic query plans using `EXPLAIN (GENERIC_PLAN)` to verify index usage and join strategies under generalized parameter distributions:
    ```sql
    EXPLAIN (GENERIC_PLAN, BUFFERS)
    SELECT id, status, amount
    FROM orders
    WHERE tenant_id = $1 AND status = $2
    ORDER BY created_at DESC
    LIMIT 20;
    ```
- **Composite Index Column Ordering: ESR Rule (Equality, Sort, Range)**:
  - ❌ **Placing Range Conditions Before Equality in Multi-Column Indexes**: Creating an index on `(created_at, tenant_id, status)` for a query filtering `WHERE tenant_id = 't_100' AND status = 'paid' AND created_at >= '2025-01-01'`. The B-Tree index scan traverses `created_at`, but because it is a range scan, the index cannot efficiently seek subsequent equality columns `tenant_id` and `status`, resulting in scanning thousands of irrelevant index pages.
  - ✅ **Production Invariant**: Strictly apply the ESR (Equality, Sort, Range) ordering rule: define exact equality columns first, sort columns second, and range bounds last:
    ```sql
    -- Correct: Equality columns first, then range/sort
    CREATE INDEX idx_orders_tenant_status_created 
    ON orders (tenant_id, status, created_at DESC);
    ```
- **PostgreSQL Partial Indexes for High-Churn Soft-Delete & State Queues**:
  - ❌ **Full-Table B-Tree Bloat on Soft-Deleted or Terminal States**: Indexing every row in a 50-million row `users` or `jobs` table when 95% of rows are soft-deleted (`deleted_at IS NOT NULL`) or in a completed state (`status = 'completed'`). The index consumes tens of gigabytes of RAM, bloats the buffer pool, and forces costly index write maintenance on every status update.
  - ✅ **Production Invariant**: Always create partial indexes scoped strictly to active, queryable rows via `WHERE deleted_at IS NULL` or active queue states:
    ```sql
    -- Index only active, un-deleted rows (slashing index RAM footprint by up to 90%)
    CREATE UNIQUE INDEX uq_users_active_email
    ON users (email)
    WHERE deleted_at IS NULL;

    -- Index only actionable pending jobs for queue consumer polling
    CREATE INDEX idx_jobs_pending_priority
    ON background_jobs (priority DESC, run_at ASC)
    WHERE status = 'pending';
    ```
- **PostgreSQL Transactional Advisory Locks (`pg_advisory_xact_lock`) for Single-Flight Worker Coordination**:
  - ❌ **Row-Level Mutex Contention & Table Bloat for Singleton Jobs**: Creating a `lock_table` in the database and issuing `UPDATE locks SET locked = true` to ensure only one worker runs a periodic cron task. If the worker crashes, the row remains locked indefinitely, requiring manual cleanup, or generates deadlocks under connection drops.
  - ✅ **Production Invariant**: Use 64-bit transactional advisory locks (`pg_advisory_xact_lock(bigint)` or `pg_try_advisory_xact_lock`). They require zero table storage, survive worker process crashes, and release automatically when the transaction completes or rolls back:
    ```sql
    -- Non-blocking attempt to acquire singleton cron lock:
    SELECT pg_try_advisory_xact_lock(hashtext('daily_subscription_renewal'));
    -- Returns TRUE if lock acquired; FALSE if another worker is currently executing.
    ```
- **PostgreSQL Safe Column Renames & Type Alterations: Expand-Contract Zero-Downtime Migration**:
  - ❌ **Instant Table Lock & App Crash Anti-Pattern**: Running `ALTER TABLE orders RENAME COLUMN old_name TO new_name;` or modifying column types directly on a multi-gigabyte table with live production traffic. This takes an exclusive `AccessExclusiveLock`, blocking all reads and writes until complete, and immediately causes `column does not exist` query exceptions on existing running application containers.
  - ✅ **Production Invariant**: Always execute the 3-phase Expand-Contract pattern:
    1. **Expand**: Add the new column as nullable (`ALTER TABLE orders ADD COLUMN new_name text;`). Attach a lightweight synchronized trigger to mirror writes from old $\to$ new:
       ```sql
       CREATE OR REPLACE FUNCTION sync_order_new_name()
       RETURNS trigger AS $$
       BEGIN
         NEW.new_name := NEW.old_name;
         RETURN NEW;
       END;
       $$ LANGUAGE plpgsql;

       CREATE TRIGGER trg_sync_order_name
       BEFORE INSERT OR UPDATE ON orders
       FOR EACH ROW EXECUTE FUNCTION sync_order_new_name();
       ```
    2. **Backfill**: Incrementally backfill historical rows in small chunked transactions (`LIMIT 5000`) with short sleep pauses to yield I/O to production traffic.
    3. **Contract**: Deploy application code pointing to `new_name`. Drop the trigger and old column asynchronously (`ALTER TABLE orders DROP COLUMN old_name;`).
- **PostgreSQL Generated Columns (`GENERATED ALWAYS AS ... STORED`) vs Expression Indexes**:
  - ❌ **Repetitive Expression Computation & Parsing Overhead**: Writing queries repeatedly computing string transformations or JSON extraction (e.g., `LOWER(TRIM(email))` or `(metadata->>'user_id')::uuid`). Each query forces PostgreSQL to re-evaluate the expression, wasting CPU cycles and complicating query plans.
  - ✅ **Production Invariant**: Use deterministic `GENERATED ALWAYS AS (expr) STORED` columns with standard B-tree indexing for read-heavy synthetic or extracted keys:
    ```sql
    ALTER TABLE users 
    ADD COLUMN normalized_email text 
    GENERATED ALWAYS AS (LOWER(TRIM(email))) STORED;

    CREATE UNIQUE INDEX uq_users_normalized_email 
    ON users (normalized_email);
    ```
- **PostgreSQL UUIDv7 (Time-Ordered Sequential) vs UUIDv4 Random B-Tree Index Fragmentation**:
  - ❌ **Anti-Pattern: Unsorted `gen_random_uuid()` (UUIDv4) Primary Keys at Scale**: Using completely random UUIDv4 as primary keys on high-ingestion tables ($> 10\text{M}$ rows). Because UUIDv4 values are uniformly random, each insert lands on an arbitrary page across the entire B-tree index, causing continuous cache misses, random disk I/O thrashing, and massive index page splitting/bloat.
  - ✅ **Production Invariant**: Use time-ordered sequential UUIDv7 (RFC 9562). The timestamp prefix ensures inserts append sequentially to right-most B-tree index pages, preserving cache locality and reducing index disk footprint by up to $60\%$:
    ```sql
    -- PostgreSQL 16/17 extension or custom function for sequential UUIDv7:
    CREATE OR REPLACE FUNCTION generate_uuid_v7()
    RETURNS uuid AS $$
    DECLARE
      unix_time_ms bytea;
      rand_bytes bytea;
    BEGIN
      unix_time_ms := substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3 for 6);
      rand_bytes := gen_random_bytes(10);
      RETURN encode(
        set_bit(set_bit(set_byte(unix_time_ms || rand_bytes, 6, get_byte(rand_bytes, 0) & 15 | 112), 52, 1), 53, 0),
        'hex'
      )::uuid;
    END;
    $$ LANGUAGE plpgsql VOLATILE;

    -- Sequential primary key with zero index page thrashing:
    CREATE TABLE events (
      id uuid PRIMARY KEY DEFAULT generate_uuid_v7(),
      payload jsonb NOT NULL,
      created_at timestamptz DEFAULT clock_timestamp() NOT NULL
    );
    ```
- **High-Throughput Distributed Task Queues via `SELECT ... FOR UPDATE SKIP LOCKED`**:
  - ❌ **Lock Contention Anti-Pattern: Blocking `FOR UPDATE` Without `SKIP LOCKED`**: Multiple worker instances running `SELECT * FROM queue WHERE status = 'pending' LIMIT 1 FOR UPDATE;`. When Worker 1 acquires the row, Workers 2 through 10 block completely on Worker 1's lock, collapsing concurrent worker throughput down to sequential serialization.
  - ✅ **Production Invariant**: Always append `SKIP LOCKED`. Concurrent workers skip rows currently locked by other transactions, achieving lock-free parallel job dispatch with zero blocking:
    ```sql
    -- Atomically dequeue next actionable job without worker contention:
    WITH next_job AS (
      SELECT id 
      FROM task_queue
      WHERE status = 'pending' AND run_at <= clock_timestamp()
      ORDER BY priority DESC, run_at ASC
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    UPDATE task_queue
    SET status = 'processing', locked_at = clock_timestamp(), attempts = attempts + 1
    WHERE id = (SELECT id FROM next_job)
    RETURNING id, payload, attempts;
    ```
- **Declarative Table Partitioning & Partition Pruning Verification**:
  - ❌ **Anti-Pattern: Unpartitioned Multi-Terabyte Time-Series / Audit Tables**: Keeping 500 million immutable audit logs or sensor readings in a single monolithic table. Vacuuming takes hours, deletes cause massive dead-tuple bloat, and queries must traverse gigantic indexes.
  - ✅ **Production Invariant**: Use declarative range partitioning on immutable time dimensions (`PARTITION BY RANGE (created_at)`), and verify partition pruning in `EXPLAIN ANALYZE`:
    ```sql
    CREATE TABLE audit_logs (
      id uuid NOT NULL,
      tenant_id uuid NOT NULL,
      action text NOT NULL,
      created_at timestamptz NOT NULL
    ) PARTITION BY RANGE (created_at);

    -- Monthly sub-tables (or automated pg_partman):
    CREATE TABLE audit_logs_2026_10 PARTITION OF audit_logs
      FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2026-11-01 00:00:00+00');

    -- Ensure query planner prunes irrelevant partitions:
    -- Verify in EXPLAIN that "Partitions removed: N" appears:
    EXPLAIN SELECT * FROM audit_logs 
    WHERE created_at >= '2026-10-15' AND created_at < '2026-10-20';
    ```
- **Zero-Downtime PostgreSQL `NOT NULL` Constraint Addition on High-Scale Tables**:
  - ❌ **Lock Contention Anti-Pattern: Direct `ALTER COLUMN SET NOT NULL` on Large Tables**: Executing `ALTER TABLE orders ALTER COLUMN customer_id SET NOT NULL;` on a table with 50 million rows. This acquires an `ACCESS EXCLUSIVE` lock and performs a full table sequential scan while holding the lock, completely blocking all concurrent SELECT, INSERT, and UPDATE queries for minutes.
  - ✅ **Production Invariant**: Use a 2-step validated check constraint pattern. First, add an unvalidated check constraint (instant lock release), validate it asynchronously in the background without blocking writes, and then safely promote to a native `NOT NULL` constraint (which skips the table scan in PostgreSQL 12+):
    ```sql
    -- Step 1: Add constraint without scanning existing rows (instant, minimal lock):
    ALTER TABLE orders 
    ADD CONSTRAINT chk_orders_customer_id_not_null 
    CHECK (customer_id IS NOT NULL) NOT VALID;

    -- Step 2: Validate existing rows in the background (SHARE UPDATE EXCLUSIVE lock; writes continue unblocked):
    ALTER TABLE orders 
    VALIDATE CONSTRAINT chk_orders_customer_id_not_null;

    -- Step 3: Convert to native NOT NULL; PostgreSQL recognizes the valid constraint and skips full scan:
    ALTER TABLE orders 
    ALTER COLUMN customer_id SET NOT NULL;

    -- Step 4: Drop redundant check constraint:
    ALTER TABLE orders 
    DROP CONSTRAINT chk_orders_customer_id_not_null;
    ```
- **High-Performance JSONB Querying via `jsonb_path_ops` GIN Indexing vs Default GIN Bloat**:
  - ❌ **Anti-Pattern: Default GIN Index Bloat on Deep JSONB Payloads**: Creating standard GIN indexes (`USING gin (payload)`). The default `jsonb_ops` operator class creates index entries for every distinct key and value separately, resulting in massive index bloat, elevated disk I/O, and severe write amplification on high-throughput inserts.
  - ✅ **Production Invariant**: Use `jsonb_path_ops` GIN indexing and the `@>` containment operator. It generates compact 32-bit hashes of full key-value paths, reducing index size by up to $65\%$ and delivering orders of magnitude faster lookups:
    ```sql
    -- Compact, high-throughput path-based GIN index:
    CREATE INDEX idx_events_payload_path 
    ON events USING gin (payload jsonb_path_ops);

    -- Query using containment operator (@>) to guarantee index scan:
    SELECT id, payload 
    FROM events 
    WHERE payload @> '{"tenant_id": "org_987", "status": "active"}';
    ```
- **PostgreSQL Read Replica Recovery Conflict Defense (`hot_standby_feedback`)**:
  - ❌ **Anti-Pattern: Unconfigured Read Replicas Aborting Analytical Queries**: Running analytical queries or batch exports on read replicas with default settings. When the primary node runs `VACUUM` and purges dead tuples, the replica WAL receiver abruptly cancels active queries with `ERROR: canceling statement due to conflict with recovery`.
  - ✅ **Production Invariant**: Enable `hot_standby_feedback = on` on read replicas so the replica continuously informs the primary of its oldest active snapshot transaction ID (`xmin`), preventing the primary from vacuuming tuples currently read by replica queries:
    ```sql
    -- In postgresql.conf (or via ALTER SYSTEM) on read replica:
    -- Prevents primary autovacuum from purging tuples needed by active replica queries:
    hot_standby_feedback = on;
    -- Bounded grace period for DDL / table lock conflicts:
    max_standby_streaming_delay = '180s';
    ```
- **PostgreSQL Transaction Wraparound Defense & Autovacuum Freeze Optimization**:
  - ❌ **Anti-Pattern: Ignoring XID Consumption Until Emergency Single-User Shutdown**: Allowing transaction ID (`txid`) consumption to climb unmonitored towards the 2-billion transaction horizon. When unvacuumed tables exceed `autovacuum_freeze_max_age` (default 200M XIDs), PostgreSQL initiates aggressive, I/O-saturating anti-wraparound vacuums that ignore cost delay limits, and eventually forces the cluster into read-only single-user mode to prevent data corruption.
  - ✅ **Production Invariant**: Continuously monitor `datfrozenxid` age, allocate dedicated freeze vacuum resources, and proactively tune freeze parameters:
    ```sql
    -- Query transaction ID age across databases (Alert when age > 100,000,000):
    SELECT datname, age(datfrozenxid) AS xid_age,
           current_setting('autovacuum_freeze_max_age')::bigint AS freeze_max_age
    FROM pg_database
    ORDER BY age(datfrozenxid) DESC;

    -- Tune aggressive freeze parameters on high-write tables:
    ALTER TABLE transactions SET (
      autovacuum_vacuum_cost_limit = 2000,
      autovacuum_vacuum_cost_delay = 2,
      vacuum_freeze_min_age = 50000000,
      vacuum_freeze_table_age = 150000000
    );
    ```
- **PgBouncer Transaction-Mode Prepared Statement Conflict Defense**:
  - ❌ **Anti-Pattern: Named Prepared Statements in Transaction Pooling Mode**: Executing `PREPARE stmt ...` or using ORMs (Prisma, GORM, Hibernate) with default server-side named prepared statements when connected through PgBouncer in `pool_mode = transaction`. Because each transaction is assigned a different backend PostgreSQL connection, queries crash with `ERROR: prepared statement "s0" does not exist`.
  - ✅ **Production Invariant**: In transaction pooling setups, either use client-side prepared statement parameter substitution, configure the database driver to use unnamed prepared statements (`statement_cache_size = 0` / `prefer_simple_protocol = true`), or enable PgBouncer 1.21+ protocol-level prepared statement tracking:
    ```ini
    ; In pgbouncer.ini (PgBouncer 1.21+):
    pool_mode = transaction
    max_prepared_statements = 100

    ; In database connection string / ORM configuration:
    ; Go pgx driver:
    ; connConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
    ; Prisma:
    ; DATABASE_URL="postgresql://user:pass@bouncer:6432/db?pgbouncer=true"
    ```
- **PostgreSQL BRIN (Block Range Index) for Massive Append-Only Time-Series Tables**:
  - ❌ **Anti-Pattern: Giant B-Tree Indexes on Monotonic Time-Series & Audit Tables**: Creating standard B-tree indexes (`CREATE INDEX idx_logs_timestamp ON logs(created_at)`) on tables with 100+ million append-only rows. The B-tree index consumes 10GB–50GB of RAM and disk, pushing hot business tables out of `shared_buffers` and causing severe write amplification.
  - ✅ **Production Invariant**: Use a BRIN (Block Range Index) on naturally ordered or append-only time columns. A BRIN index stores only the min/max values for groups of disk pages (`pages_per_range`), reducing index footprint by up to $99.5\%$ (e.g. 15MB instead of 10GB) while maintaining fast range queries:
    ```sql
    -- Compact BRIN index for append-only audit trail:
    CREATE INDEX idx_audit_logs_brin_created_at 
    ON audit_logs USING brin (created_at) 
    WITH (pages_per_range = 32);

    -- Ensure query planner leverages BRIN index range scans:
    EXPLAIN ANALYZE 
    SELECT COUNT(*) 
    FROM audit_logs 
    WHERE created_at >= NOW() - INTERVAL '7 days';
    ```
- **PostgreSQL 16+ `VACUUM (BUFFER_USAGE_LIMIT)` & Shared Buffer Cache Protection**:
  - ❌ **Anti-Pattern: Unconstrained Vacuum Flushing Hot Cache Pages**: Running manual or scheduled vacuums on massive tables without buffer limits. The vacuum operation sweeps through gigabytes of table pages, evicting frequently queried index blocks and hot data from `shared_buffers`, causing sudden latency spikes on production APIs.
  - ✅ **Production Invariant**: In PostgreSQL 16+, use `BUFFER_USAGE_LIMIT` to constrain the vacuum process to a dedicated ring buffer (e.g. 128MB or 256MB), preventing cache eviction while aggressively freeing dead tuples:
    ```sql
    -- Vacuum large table with bounded shared_buffers consumption:
    VACUUM (VERBOSE, BUFFER_USAGE_LIMIT '128 MB') high_volume_events;
    ```
- **Transaction Timeout Hierarchy: Preventing Connection Pool Starvation & Zombie Locks**:
  - ❌ **Anti-Pattern: Relying Solely on `statement_timeout`**: Setting only `statement_timeout = '30s'`. If an application opens a transaction, runs an `UPDATE`, and then pauses waiting for an external HTTP call or crashes, the transaction remains open (`idle in transaction`), holding row exclusive locks and exhausting the connection pool.
  - ✅ **Production Invariant**: Enforce a strict 3-tier timeout hierarchy at the role or database level:
    ```sql
    -- 1. Abort idle transactions holding locks after 10s:
    ALTER ROLE app_user SET idle_in_transaction_session_timeout = '10000'; -- 10s

    -- 2. Fail fast if unable to acquire lock within 5s (prevents queue buildup behind DDL):
    ALTER ROLE app_user SET lock_timeout = '5000'; -- 5s

    -- 3. Hard ceiling for individual SQL statement execution:
    ALTER ROLE app_user SET statement_timeout = '30000'; -- 30s
    ```
- **TOAST Out-of-Line Storage Amplification & LZ4 Compression**:
  - ❌ **Anti-Pattern: Blind JSONB Updates on Massive Documents without Compression**: Storing 100KB JSON documents with default `pglz` compression and repeatedly executing small `jsonb_set` updates. Each update re-writes out-of-line TOAST chunks, causing immense write amplification and WAL bloat.
  - ✅ **Production Invariant**: In PostgreSQL 14+, configure modern LZ4 compression for TOAST columns for $2\times$ faster decompression and reduced CPU overhead. For columns frequently queried but rarely modified, set storage parameters appropriately:
    ```sql
    -- Enable fast LZ4 compression for wide JSONB or TEXT columns:
    ALTER TABLE user_profiles ALTER COLUMN metadata SET COMPRESSION lz4;

    -- Inspect TOAST size and table bloat:
    SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS total_size
    FROM pg_catalog.pg_statio_user_tables
    WHERE relname = 'user_profiles';
    ```
- **PostgreSQL 16+ `pg_stat_io` Real-Time Storage & Cache Diagnostic Invariants**:
  - ❌ **Anti-Pattern: Blindly Guessing Disk Bottlenecks via OS `iostat`**: Attempting to troubleshoot database slowdowns using host-level metrics without knowing whether the I/O bottleneck originates from client reads, autovacuum sweeps, WAL fsyncs, or background checkpointer flushing.
  - ✅ **Production Invariant**: In PostgreSQL 16+, inspect `pg_stat_io` to observe granular read/write/extend/fsync activity categorized by backend type and I/O context. Immediately identify whether normal client queries are hitting physical disk or burning memory bandwidth:
    ```sql
    -- Diagnostic query to isolate physical I/O read spikes and cache misses by backend type:
    SELECT
        backend_type,
        context,
        io_object,
        reads,
        writes,
        writebacks,
        extends,
        op_bytes
    FROM pg_stat_io
    WHERE reads > 0 OR writes > 0
    ORDER BY reads DESC;
    ```
- **Partial Indexing for Soft-Deleted Tables (`deleted_at IS NULL`)**:
  - ❌ **Anti-Pattern: Full B-Tree Indexes on Tables with Soft Deletions**: Creating global indexes on `(tenant_id, email)` without filtering `deleted_at`. As archived and soft-deleted rows accumulate over time, the index bloats with dead entries that live application queries never request, evicting active data pages from `shared_buffers`.
  - ✅ **Production Invariant**: Always attach a `WHERE deleted_at IS NULL` predicate to unique and lookup indexes on soft-deleted entities. The index size shrinks by 80–90%, write throughput improves, and unique constraints correctly allow re-registration of previously deleted emails:
    ```sql
    -- Partial unique index ensuring uniqueness only among active accounts:
    CREATE UNIQUE INDEX CONCURRENTLY idx_users_active_tenant_email
    ON users (tenant_id, email)
    WHERE deleted_at IS NULL;
    ```
- **PostgreSQL `SERIALIZABLE` Isolation & Exclusion Constraints for Write Skew Defense**:
  - ❌ **Anti-Pattern: Relying on `SELECT ... FOR UPDATE` to Guard Missing Row Invariants**: Using row-level locking (`FOR UPDATE`) to verify conditions across non-existent rows (e.g. "at least one doctor on duty", "room cannot be double-booked between times $T_1$ and $T_2$"). `FOR UPDATE` only locks rows that already exist in the snapshot; concurrent transactions insert overlapping rows simultaneously because neither blocks the other, violating the business invariant (Write Skew).
  - ✅ **Production Invariant**: For time-range overlaps or resource allocations, utilize PostgreSQL Exclusion Constraints (`EXCLUDE USING gist`) with the `btree_gist` extension, or execute the transaction under true `SERIALIZABLE` isolation with automated retry loops on serialization failures (`SQLSTATE 40001`):
    ```sql
    -- 1. Deterministic database-level exclusion constraint preventing overlapping bookings:
    CREATE EXTENSION IF NOT EXISTS btree_gist;

    CREATE TABLE room_reservations (
        reservation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        room_id INT NOT NULL,
        during TSTZRANGE NOT NULL,
        EXCLUDE USING gist (
            room_id WITH =,
            during WITH &&
        )
    );

    -- 2. For complex multi-table predicate invariants, use SERIALIZABLE isolation with exponential retry backoff:
    -- BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
    -- Catch SQLSTATE '40001' (serialization_failure) and retry transaction up to 3 times.
    ```
- **Deterministic `GENERATED ALWAYS AS (expr) STORED` Columns with B-Tree Indexing**:
  - ❌ **Anti-Pattern: Application-Side Normalization or Trigger Overhead for Query Filters**: Maintaining denormalized lowercase columns or JSON field extractions via `BEFORE INSERT OR UPDATE` triggers or application code. If any bulk insert or script bypasses the application layer, the index and search results become inconsistent.
  - ✅ **Production Invariant**: In PostgreSQL 12+, define deterministic expressions as `GENERATED ALWAYS AS (...) STORED` columns, and attach standard B-Tree or unique indexes directly to the generated column:
    ```sql
    CREATE TABLE customer_orders (
        order_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        raw_metadata JSONB NOT NULL,
        -- Deterministic stored generated column extracting nested JSON key:
        customer_tier TEXT GENERATED ALWAYS AS (raw_metadata ->> 'tier') STORED,
        order_amount_cents INT GENERATED ALWAYS AS ((raw_metadata ->> 'amount_cents')::INT) STORED
    );

    -- Clean, high-performance B-Tree index on generated column:
    CREATE INDEX idx_customer_orders_tier_amount ON customer_orders (customer_tier, order_amount_cents);
    ```
- **PostgreSQL Heap-Only Tuples (HOT) Optimization & `FILLFACTOR` Tuning**:
  - ❌ **Anti-Pattern: Default 100% `FILLFACTOR` on High-Frequency Update Tables**: Leaving default `fillfactor = 100` on tables with hundreds of updates per second (e.g. `heartbeats`, `session_tokens`, `order_status`). Every update forces Postgres to allocate space on a new disk page and insert new entries into EVERY index on the table, causing massive index bloat, write amplification, and autovacuum thrashing.
  - ✅ **Production Invariant**: When an update modifies only non-indexed columns, Postgres can perform a Heap-Only Tuple (HOT) update on the same disk page if spare space exists—updating the tuple in-place with ZERO index modifications. Set `WITH (fillfactor = 70–85)` on write-heavy tables so 15–30% of each 8KB page is reserved for in-place updates:
    ```sql
    -- Tune fillfactor to allow in-place HOT updates on high-frequency tables:
    ALTER TABLE user_sessions SET (fillfactor = 80);

    -- Ensure frequently updated columns (e.g. last_activity_at) are NOT indexed:
    -- Query HOT update ratio to verify optimization efficacy (aim for > 85% HOT updates):
    SELECT relname, n_tup_upd, n_tup_hot_upd,
           ROUND(100.0 * n_tup_hot_upd / NULLIF(n_tup_upd, 0), 2) AS hot_ratio
    FROM pg_stat_user_tables
    WHERE relname = 'user_sessions';
    ```
- **PostgreSQL Transactional Advisory Locks (`pg_try_advisory_xact_lock`) for Distributed Singletons**:
  - ❌ **Anti-Pattern: Creating Dummy Lock Tables or Long-Running `FOR UPDATE` Rows**: Managing distributed locks or cron jobs by writing to a `locks` table with `SELECT ... FOR UPDATE`. If a worker crashes or encounters network partition, rows remain locked until TCP keepalive timeouts expire, or transaction rollbacks stall other concurrent jobs.
  - ✅ **Production Invariant**: Use 64-bit transactional advisory locks (`pg_try_advisory_xact_lock(bigint)`). They execute in-memory inside the Postgres lock manager, acquire instantly without table I/O, return a non-blocking boolean immediately (`false` if already held), and automatically release the moment the transaction commits or aborts:
    ```sql
    BEGIN;
    -- Try to acquire unique lock for background payout worker (hash of "payout_scheduler"):
    SELECT pg_try_advisory_xact_lock(hashtext('payout_scheduler')) AS acquired;

    -- If acquired is TRUE: execute batch payout logic.
    -- If acquired is FALSE: another worker is currently running; exit cleanly immediately without waiting.
    COMMIT; -- Lock automatically released upon COMMIT or ROLLBACK.
    ```
- **PostgreSQL 16+ `pg_stat_io` for Disk vs Buffer Cache I/O Bottleneck Diagnostics**:
  - ❌ **Anti-Pattern: Guessing Storage Bottlenecks via Generic CPU or Load Averages**: Troubleshooting slow queries by looking only at overall server I/O or `EXPLAIN ANALYZE` without visibility into whether disk waits stem from client reads, WAL writes, background workers, or vacuum thrashing.
  - ✅ **Production Invariant**: In PostgreSQL 16+, inspect `pg_stat_io`. It decomposes disk read/write/extend operations by backend type (client backend, autovacuum, checkpointer) and context (normal, vacuum, bulkread), identifying exact I/O bottlenecks without guessing:
    ```sql
    -- Pinpoint backend read vs write I/O operations and buffer cache hit rates:
    SELECT backend_type, io_object, io_context,
           reads, writes, extends, hits,
           ROUND(100.0 * hits / NULLIF(hits + reads, 0), 2) AS cache_hit_pct
    FROM pg_stat_io
    WHERE io_object = 'relation'
    ORDER BY reads DESC;
    ```
- **Prepared Statement Memory Deallocation & Plan Cache Invalidation (`DISCARD PLANS`)**:
  - ❌ **Anti-Pattern: Connection Pooler Prepared Statement Leakage & Generic Plan Drift**: Using session-level pooling (`PgBouncer` in transaction mode or long-lived server connections) with unnamed or dynamically named prepared statements. Over time, cached generic plans degrade due to parameter sniffing, and backend connection memory balloons from unpurged statement handles.
  - ✅ **Production Invariant**: Whenever recycling pooled database connections or concluding long-running batch workers, issue `DISCARD PLANS` (or `DEALLOCATE ALL`) to free cached query plans and force PostgreSQL to re-evaluate statistics and partition pruning:
    ```sql
    -- Free memory and force clean parameter-specific plans upon transaction pool recycling:
    DISCARD PLANS;
    ```
- **Hermetic Ephemeral Schema Isolation for Parallel Integration Tests (`search_path`)**:
  - ❌ **Anti-Pattern: Shared Table Mutation & Database Collisions Across Parallel Test Workers**: Running parallel tests against a shared test database where multiple workers execute concurrent `INSERT`, `UPDATE`, or `TRUNCATE` operations on the same tables. This causes intermittent unique key collisions, serialization failures, and flaky test assertions.
  - ✅ **Production Invariant**: Isolate each parallel test worker inside an ephemeral PostgreSQL schema. Set the connection's `search_path` to the worker schema, execute schema DDL once, and drop the schema on worker teardown:
    ```sql
    -- Setup in test worker:
    CREATE SCHEMA test_worker_7c2b;
    SET search_path TO test_worker_7c2b, public;

    -- Worker executes all queries against its completely isolated private tables:
    CREATE TABLE orders (id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY, amount NUMERIC(12, 2));
    INSERT INTO orders (amount) VALUES (150.00);

    -- Teardown in test worker cleanup:
    DROP SCHEMA test_worker_7c2b CASCADE;
    ```
- **Deterministic Relational Pagination Tie-Breakers & Explicit Null Invariants (`NULLS LAST`)**:
  - ❌ **Anti-Pattern: Non-Deterministic Cursor / Offset Pagination without Unique Tie-Breakers**: Paginating queries via `LIMIT 20 OFFSET 40` or keyset `WHERE created_at < $1` without a unique secondary tie-breaker. When multiple rows share identical timestamps, PostgreSQL returns them in arbitrary order depending on disk heap page layout, causing skipped or duplicated records across page boundaries.
  - ✅ **Production Invariant**: Every paginated or test-asserted query MUST include a deterministic unique column (such as the primary key `id`) and explicit NULL placement:
    ```sql
    -- ✅ Fully deterministic keyset cursor query with null safety:
    SELECT id, created_at, status
    FROM transactions
    WHERE (created_at, id) < ($1, $2)
    ORDER BY created_at DESC NULLS LAST, id DESC
    LIMIT 20;
    ```
- **PR Migration Lock Auditing & Safe DDL Gating (`lock_timeout`)**:
  - ❌ **Anti-Pattern: Unvetted DDL in Pull Requests Acquiring Production Table Locks**: Opening PRs with raw `ALTER TABLE ... ADD CONSTRAINT` or synchronous column additions without timeout guards. During deployment, the migration blocks waiting for concurrent queries, causing incoming connections to pile up and exhaust the pool.
  - ✅ **Production Invariant**: In CI PR verification, execute automated migration linters (`squawk` or `atlas migrate lint`) and mandate `lock_timeout` in every migration script. Adding foreign keys MUST follow the two-phase `NOT VALID` pattern:
    ```sql
    -- Step 1 in PR: Add constraint without scanning existing rows (instant):
    SET LOCAL lock_timeout = '2s';
    ALTER TABLE orders ADD CONSTRAINT fk_orders_user_id
      FOREIGN KEY (user_id) REFERENCES users(id) NOT VALID;

    -- Step 2 in PR: Validate existing rows in background with SHARE UPDATE EXCLUSIVE lock (non-blocking):
    ALTER TABLE orders VALIDATE CONSTRAINT fk_orders_user_id;
    ```
- **Explicit Foreign Key Cascades & Ledger Safety (`ON DELETE RESTRICT`)**:
  - ❌ **Anti-Pattern: Indiscriminate `ON DELETE CASCADE` on Financial & Audit Entities**: Applying `ON DELETE CASCADE` to invoices, audit entries, or transaction records. Deleting a parent customer or organization record triggers a silent recursive purge across all dependent tables, destroying financial compliance records.
  - ✅ **Production Invariant**: Always enforce `ON DELETE RESTRICT` (or `ON DELETE NO ACTION`) on immutable ledgers, invoices, payments, and audit tables. Cascades are strictly limited to ephemeral child data (such as temporary cache entries or session tokens):
    ```sql
    CREATE TABLE invoices (
      id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
      account_id BIGINT NOT NULL,
      amount NUMERIC(14, 2) NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      -- Prohibits deletion of account while historical invoices exist:
      CONSTRAINT fk_invoices_account
        FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE RESTRICT
    );
    ```
- **PostgreSQL Serializable Isolation with Automated Retry Loops (`40001`)**:
  - ❌ **Anti-Pattern: Relying on `READ COMMITTED` to Prevent Write Skew Anomalies**: Executing multi-row balance transfers or room-booking checks under default `READ COMMITTED`. Concurrent transactions read the same initial state, pass application validation, and perform concurrent inserts/updates, causing double bookings or negative balances without row-level lock contention.
  - ✅ **Production Invariant**: For distributed multi-row state mutations, enforce `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE` paired with an automated exponential-jitter retry harness intercepting SQLSTATE `40001` (`serialization_failure`):
    ```typescript
    async function executeSerializableWithRetry<T>(
      pool: pg.Pool,
      operation: (client: pg.PoolClient) => Promise<T>,
      maxRetries = 5
    ): Promise<T> {
      for (let attempt = 1; attempt <= maxRetries; attempt++) {
        const client = await pool.connect();
        try {
          await client.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
          const result = await operation(client);
          await client.query('COMMIT');
          return result;
        } catch (err: any) {
          await client.query('ROLLBACK');
          if (err.code === '40001' && attempt < maxRetries) {
            // SQLSTATE 40001: serialization_failure; retry with exponential jitter
            const backoffMs = Math.min(500, Math.pow(2, attempt) * 20 + Math.random() * 50);
            await new Promise((r) => setTimeout(r, backoffMs));
            continue;
          }
          throw err;
        } finally {
          client.release();
        }
      }
      throw new Error(`Exceeded max retries (${maxRetries}) under SERIALIZABLE isolation`);
    }
    ```
- **High-Throughput Transactional Outbox Partitioning & Instant Deletion (`DROP TABLE`)**:
  - ❌ **Anti-Pattern: Bulk Deleting Processed Outbox Events via `DELETE WHERE`**: Running periodic cron jobs `DELETE FROM outbox_events WHERE published_at < NOW() - INTERVAL '7 days'`. In high-throughput systems processing millions of events daily, bulk `DELETE` generates massive transaction log (WAL) bloat, leaves dead tuples requiring vacuuming, and induces table lock contention with concurrent workers.
  - ✅ **Production Invariant**: Partition high-throughput outbox tables by range on `created_at` (`PARTITION BY RANGE (created_at)`). Prune historical processed partitions using `DROP TABLE` ($O(1)$ metadata operation with zero disk I/O and zero WAL generation):
    ```sql
    -- Declarative partitioned outbox table:
    CREATE TABLE outbox_events (
        id UUID NOT NULL DEFAULT gen_random_uuid(),
        aggregate_type VARCHAR(128) NOT NULL,
        aggregate_id VARCHAR(128) NOT NULL,
        event_type VARCHAR(128) NOT NULL,
        payload JSONB NOT NULL,
        published_at TIMESTAMPTZ NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (created_at, id)
    ) PARTITION BY RANGE (created_at);

    -- Create weekly partition:
    CREATE TABLE outbox_events_y2026w14 PARTITION OF outbox_events
        FOR VALUES FROM ('2026-03-30 00:00:00+00') TO ('2026-04-06 00:00:00+00');

    -- Instant O(1) zero-bloat retirement of old partition:
    DROP TABLE outbox_events_y2026w13;
    ```
- **PostgreSQL Advisory Locks for In-Flight Distributed Mutation Coordination**:
  - ❌ **Anti-Pattern: Polling with Application Sleep to Await Lock Release**: When a worker encounters an in-progress idempotency key, calling `sleep(1)` repeatedly in a loop while re-querying the database. This floods the connection pool and wastes database CPU.
  - ✅ **Production Invariant**: Use PostgreSQL transaction-level advisory locks (`pg_try_advisory_xact_lock(hashtext(key))`) for fast atomic acquisition without row table lock overhead. If the lock cannot be acquired immediately, return HTTP `409 Conflict` with `Retry-After`:
    ```sql
    -- Attempt non-blocking transaction-scoped advisory lock by hashed key:
    SELECT pg_try_advisory_xact_lock(hashtext('idemp_checkout_98765')) AS acquired;
    -- Returns true if acquired immediately; false if held by another concurrent transaction.
    -- Released automatically upon COMMIT or ROLLBACK of current transaction!
    ```
- **Storage-Level Monotonic Fencing Token Check Against Lease Expiry (`WHERE fencing_token < :token`)**:
  - ❌ **Anti-Pattern: Unconditional Writes Guarded Only by Application Locks**: Believing that holding an in-memory lock or distributed Redis lease makes `UPDATE items SET quantity = quantity - :qty WHERE id = :id` safe without checking fencing versions. If a network blip or GC pause causes the lock lease to expire, another node acquires the lock and proceeds. The delayed node then executes its update, overwriting newer state without detection.
  - ✅ **Production Invariant**: Every mutable row guarded by distributed leases MUST maintain a `fencing_token BIGINT NOT NULL DEFAULT 0`. The database write MUST enforce monotonic progression:
    ```sql
    UPDATE inventory_items
    SET quantity = quantity - 5,
        fencing_token = :fencing_token,
        updated_at = NOW()
    WHERE id = :item_id
      AND fencing_token < :fencing_token;
    -- If 0 rows updated, the storage engine detects an outdated lease and rejects the stale write!
    ```
- **PostgreSQL Multi-Resource Advisory Lock Sorting Invariant (`ORDER BY hashtext`)**:
  - ❌ **Anti-Pattern: Unsorted Advisory Lock Acquisition in Distributed Transactions**: When reserving multiple database resources, acquiring advisory locks in arbitrary order: `SELECT pg_advisory_xact_lock(hashtext(a)); SELECT pg_advisory_xact_lock(hashtext(b));`. Concurrent transactions with reversed arguments produce PostgreSQL deadlock exceptions (`40P01 deadlocks detected`).
  - ✅ **Production Invariant**: Deterministically sort all resource keys using `ORDER BY hashtext(resource_key)` before acquiring transaction-level advisory locks:
    ```sql
    -- Atomic deadlock-free multi-resource advisory locking:
    SELECT pg_advisory_xact_lock(hashtext(resource_key))
    FROM unnest(ARRAY['account_001', 'account_002', 'order_999']) AS resource_key
    ORDER BY hashtext(resource_key) ASC;
    ```
- **Inbound Webhook Idempotent Ingestion Ledger & Outbound Delivery Outbox Schema**:
  - ❌ **Anti-Pattern: Processing Webhooks Directly Without Unique Constraint Inbox or Transactional Outbox**: Ingesting webhooks directly without a deduplication table, or dispatching external HTTP webhooks directly within database transactions. If an uncommitted transaction rolls back, external subscribers receive phantom webhooks that never existed in the database.
  - ✅ **Production Invariant**: Ingest inbound events into `webhook_inbound_events` with `UNIQUE (source, event_id)` using `INSERT ... ON CONFLICT DO NOTHING`. For outbound webhooks, insert into `webhook_outbound_deliveries` in the same database transaction as domain mutations, and poll using `FOR UPDATE SKIP LOCKED`:
    ```sql
    -- Atomic Inbound Webhook Ingestion Reservation
    INSERT INTO webhook_inbound_events (source, event_id, raw_payload, status)
    VALUES ('stripe', 'evt_123456789', :raw_json, 'pending')
    ON CONFLICT (source, event_id) DO NOTHING;

    -- Lock-free worker polling for outbound webhook delivery:
    SELECT id, target_url, payload, secret_key_id, attempt_count
    FROM webhook_outbound_deliveries
    WHERE status IN ('pending', 'failed')
      AND next_retry_at <= NOW()
    ORDER BY next_retry_at ASC
    LIMIT 25
    FOR UPDATE SKIP LOCKED;
    ```
- **Durable Saga Step State Machine Ledger & Lock-Free Execution Worker Polling**:
  - ❌ **Anti-Pattern: Transient Workflow Execution or Mutating Workflow State Without Append-Only History**: Storing multi-step distributed operations in un-journaled status flags or updating rows in-place without write-ahead step logging. If a worker terminates, there is no way to audit what steps completed or calculate the reverse compensation stack.
  - ✅ **Production Invariant**: Maintain dual tables `saga_instances` (instance state) and `saga_step_journal` (append-only events). Poll executable steps using `FOR UPDATE SKIP LOCKED` to prevent worker race conditions without table locks:
    ```sql
    -- Atomic Saga Step Journaling & Lock-Free Polling
    INSERT INTO saga_step_journal (saga_id, step_sequence, step_name, event_type, payload)
    VALUES (:saga_id, :step_seq, 'charge_customer', 'STEP_STARTED', :payload_json);

    -- Lock-free worker polling for pending or compensating sagas:
    SELECT id, workflow_name, status, current_step_sequence, execution_context
    FROM saga_instances
    WHERE status IN ('RUNNING', 'COMPENSATING')
      AND next_retry_at <= NOW()
    ORDER BY priority DESC, next_retry_at ASC
    LIMIT 10
    FOR UPDATE SKIP LOCKED;
    ```
- **Connection Pool Draining, In-Flight Transaction Completion & Idle Connection Termination on Shutdown**:
  - ❌ **Anti-Pattern: Hard Abrupt Pool Destruction or Hanging Shutdown Locks**: Destroying database connection pools immediately while transactions are in-flight, leaving stranded uncommitted locks on the server side until `idle_in_transaction_session_timeout` expires, or allowing shutdown scripts to hang indefinitely on unclosed transactions.
  - ✅ **Production Invariant**: Enforce server-side transaction timeouts (`idle_in_transaction_session_timeout = '10s'`) and client-side pool drain barriers. Explicitly rollback uncommitted transactions, allow active transactions to commit within the drain window, and close the pool with a bounded timeout:
    ```sql
    -- PostgreSQL Server-Side Safeguards Against Stranded Connections from Abrupt Restarts
    ALTER SYSTEM SET idle_in_transaction_session_timeout = '10s';
    ALTER SYSTEM SET statement_timeout = '30s';
    SELECT pg_reload_conf();

    -- Administrative Terminating Query for Drain & Eviction Verification:
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = current_database()
      AND pid <> pg_backend_pid()
      AND state = 'idle in transaction'
      AND state_change < NOW() - INTERVAL '15 seconds';
    ```
- **Durable Dead-Letter Queue (DLQ) Schema, Keyset Redrive Fencing & FOR UPDATE SKIP LOCKED Consumption**:
  - ❌ **Anti-Pattern: Transient In-Memory Error Dropping or Full-Table Lock Redrives**: Storing failed asynchronous events in memory or unindexed error tables, or executing redrives with monolithic unindexed `UPDATE errors SET retried = true` queries that lock thousands of rows and block concurrent ingestion workers.
  - ✅ **Production Invariant**: Implement durable DLQ tables with `jsonb` payloads, SHA-256 payload digests, structured error taxonomy, and keyset cursor paging with `FOR UPDATE SKIP LOCKED` for zero-contention concurrent canary redrive workers:
    ```sql
    -- Industrial PostgreSQL Dead Letter Queue Table & Concurrent Batched Redrive
    CREATE TABLE IF NOT EXISTS dead_letter_events (
        dlq_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        topic VARCHAR(255) NOT NULL,
        payload JSONB NOT NULL,
        payload_sha256 CHAR(64) NOT NULL,
        attempt_count INT NOT NULL DEFAULT 1,
        error_category VARCHAR(64) NOT NULL,
        error_message TEXT NOT NULL,
        traceparent VARCHAR(128),
        status VARCHAR(32) NOT NULL DEFAULT 'QUARANTINED',
        quarantined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE INDEX IF NOT EXISTS idx_dlq_topic_quarantined 
      ON dead_letter_events (topic, quarantined_at) 
      WHERE status = 'QUARANTINED';

    -- Non-blocking batched reservation for concurrent redrive workers
    WITH leased_batch AS (
        SELECT dlq_id
        FROM dead_letter_events
        WHERE topic = 'orders.v1'
          AND status = 'QUARANTINED'
        ORDER BY quarantined_at ASC
        LIMIT 25
        FOR UPDATE SKIP LOCKED
    )
    UPDATE dead_letter_events d
    SET status = 'REDRIVING',
        updated_at = NOW()
    FROM leased_batch b
    WHERE d.dlq_id = b.dlq_id
    RETURNING d.dlq_id, d.payload, d.traceparent;
    ```
- **PostgreSQL Cache Stampede Mitigation, CDC Invalidation Streams & Negative Sentinel Indexing**:
  - ❌ **Anti-Pattern: Un-Coalesced Database Query Stampedes & Missing Negative Cache Indexing**: Permitting expired cache keys to burst into hundreds of unconstrained full-table or heavy analytical queries simultaneously, or allowing missing foreign keys to trigger repeated full table index scans without caching negative results.
  - ✅ **Production Invariant**: Implement asynchronous Transaction Log CDC invalidation streams (or logical replication notify triggers) combined with negative sentinel caching and statement timeout guards to isolate relational storage from cache miss stampedes:
    ```sql
    -- Industrial PostgreSQL Cache Invalidation Stream & Negative Hit Sentinel Table
    CREATE TABLE IF NOT EXISTS entity_invalidation_events (
        event_id BIGSERIAL PRIMARY KEY,
        table_name VARCHAR(64) NOT NULL,
        entity_id VARCHAR(128) NOT NULL,
        entity_version BIGINT NOT NULL,
        emitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE INDEX IF NOT EXISTS idx_invalidation_stream 
      ON entity_invalidation_events (event_id ASC) 
      WHERE emitted_at >= NOW() - INTERVAL '1 hour';

    -- Low-overhead trigger recording row mutation epochs for cache invalidation workers
    CREATE OR REPLACE FUNCTION trg_record_cache_invalidation() RETURNS TRIGGER AS $$
    BEGIN
        INSERT INTO entity_invalidation_events (table_name, entity_id, entity_version)
        VALUES (TG_TABLE_NAME, COALESCE(NEW.id::text, OLD.id::text), EXTRACT(EPOCH FROM NOW())::BIGINT);
        RETURN COALESCE(NEW, OLD);
    END;
    $$ LANGUAGE plpgsql;
    ```
- **PostgreSQL Connection Pool Bulkhead Isolation, Statement Timeout Circuits & Active Query Shedding**:
  - ❌ **Anti-Pattern: Monolithic Shared Connection Pool Contention**: Allowing long-running batch or analytical reporting transactions to saturate database connections, starving sub-millisecond OLTP web endpoints and causing connection pool exhaustion timeouts.
  - ✅ **Production Invariant**: Enforce distinct user role bulkheads with isolated `statement_timeout` and `lock_timeout` circuit limits, paired with automated query shedding monitors:
    ```sql
    -- Industrial PostgreSQL Workload Bulkheading & Circuit Protection
    CREATE ROLE app_oltp_user WITH LOGIN PASSWORD 'prod_oltp_secret';
    CREATE ROLE app_analytics_user WITH LOGIN PASSWORD 'prod_analytics_secret';

    -- OLTP Bulkhead: 3s statement circuit, 1s lock acquisition boundary
    ALTER ROLE app_oltp_user SET statement_timeout = '3000ms';
    ALTER ROLE app_oltp_user SET lock_timeout = '1000ms';
    ALTER ROLE app_oltp_user SET idle_in_transaction_session_timeout = '5000ms';

    -- Analytics Bulkhead: 30s statement circuit, read-only enforcement
    ALTER ROLE app_analytics_user SET statement_timeout = '30000ms';
    ALTER ROLE app_analytics_user SET default_transaction_read_only = 'on';

    -- Shed queries exceeding SLA threshold to protect database cluster health
    CREATE OR REPLACE FUNCTION shed_excessive_active_queries(max_runtime_sec INT) RETURNS INT AS $$
    DECLARE
        killed_count INT;
    BEGIN
        SELECT COUNT(*) INTO killed_count
        FROM pg_stat_activity
        WHERE state = 'active'
          AND query NOT ILIKE '%pg_stat_activity%'
          AND (NOW() - query_start) > (max_runtime_sec || ' seconds')::INTERVAL;

        PERFORM pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE state = 'active'
          AND query NOT ILIKE '%pg_stat_activity%'
          AND (NOW() - query_start) > (max_runtime_sec || ' seconds')::INTERVAL;

        RETURN killed_count;
    END;
    $$ LANGUAGE plpgsql;
    ```

- **PgBouncer Transaction-Mode Compatibility, Session Pinning & Leak Defense**:
  - ❌ **Anti-Pattern: Session State Mutations in Transaction Pooling**: Running `SET search_path = ...`, `SET timezone = ...`, `LISTEN/NOTIFY`, or un-named prepared statements in PgBouncer transaction mode (`pool_mode = transaction`), corrupting shared physical connections across different client requests or triggering permanent server connection pinning.
  - ✅ **Production Invariant**: Use transaction-scoped `SET LOCAL`, enforce `server_reset_query = DISCARD ALL`, mandate `idle_in_transaction_session_timeout`, and isolate pub/sub to dedicated session pools:
    ```sql
    -- Transaction-safe tenant context setting in PgBouncer transaction pooling mode
    -- NEVER use "SET app.current_tenant = ...", which persists across transactions!
    BEGIN;
      -- SET LOCAL automatically rolls back when transaction commits or aborts
      SET LOCAL app.current_tenant_id = 'a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d';
      
      SELECT * FROM tenant_records 
      WHERE tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
    COMMIT;

    -- Query to detect and terminate runaway connections stuck in "idle in transaction"
    SELECT 
        pid, 
        usename, 
        client_addr, 
        state, 
        NOW() - state_change AS idle_duration,
        query
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
      AND (NOW() - state_change) > INTERVAL '10 seconds';
    ```

- **Query Indexing Physics, Leftmost Prefix Ordering & Anti-N+1 Batch Loading**:
  - ❌ **Anti-Pattern: Unindexed Foreign Keys, Offset Pagination Cliffs & N+1 Iteration**: Leaving foreign keys unindexed, paginating large tables with `OFFSET 500000`, or querying child records within application iteration loops.
  - ✅ **Production Invariant**: Mandate B-tree indexes on all foreign keys, enforce composite index leftmost prefix ordering `(Equality -> Range -> Sort)`, implement keyset cursor pagination `(created_at, id) < (:time, :id)`, and batch child lookups via `WHERE parent_id = ANY($1)`:
    ```sql
    -- Covering Composite Index: Leftmost Prefix Rule (tenant_id = ?) AND (status = ?) ORDER BY created_at DESC, id DESC
    -- Using INCLUDE for Index-Only Scans avoiding table heap access
    CREATE INDEX idx_orders_tenant_status_covering 
    ON orders (tenant_id, status, created_at DESC, id DESC)
    INCLUDE (total_amount);

    -- Deterministic O(1) Keyset Cursor Pagination (No OFFSET)
    SELECT id, tenant_id, status, total_amount, created_at
    FROM orders
    WHERE tenant_id = 'a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d'::UUID
      AND status = 'completed'
      AND (created_at, id) < ('2026-10-27T10:00:00.000Z'::TIMESTAMPTZ, '9f8e7d6c-5b4a-3210-fedc-ba9876543210'::UUID)
    ORDER BY created_at DESC, id DESC
    LIMIT 20;

    -- Anti-N+1: Batch fetch all child records across 500 orders in ONE roundtrip
    SELECT order_id, id AS item_id, product_id, quantity, unit_price
    FROM order_items
    WHERE order_id = ANY($1::UUID[]);
    ```

- **Concurrency Control: Optimistic Locking (OCC), Canonical Lock Ordering & SKIP LOCKED Queues**:
  - ❌ **Anti-Pattern: In-Memory Lost Updates & Blocking Queue Locks**: Fetching stock/balance into application memory, updating blindly (`UPDATE accounts SET balance = :val`), or consuming task queues with `LIMIT 1 FOR UPDATE` which serializes all worker threads on row 1.
  - ✅ **Production Invariant**: Enforce single-statement atomic updates with predicate checks, monotonic version epochs (`version = version + 1 WHERE version = :v`), canonical primary key ordering before batch row locks, and non-blocking `FOR UPDATE SKIP LOCKED` for worker queues:
    ```sql
    -- Atomic Single-Statement Mutation (0ms lock wait, zero lost update race)
    UPDATE inventory 
    SET stock = stock - 2, version = version + 1, updated_at = NOW() 
    WHERE id = 'b2c3d4e5-f6a7-8b9c-0d1e-2f3a4b5c6d7e'::UUID AND stock >= 2
    RETURNING id, stock, version;

    -- Deadlock-Free Lexicographical Multi-Row Lock Ordering (Sort IDs in application first)
    SELECT id, balance 
    FROM accounts 
    WHERE id IN ('00000000-0000-0000-0000-000000000001'::UUID, '00000000-0000-0000-0000-000000000002'::UUID) 
    ORDER BY id ASC 
    FOR UPDATE;

    -- High-Throughput Non-Blocking Queue Worker Claim (Linear Theta(W) scalability)
    WITH claimable AS (
        SELECT id FROM background_jobs 
        WHERE status = 'pending' 
        ORDER BY priority DESC, created_at ASC 
        LIMIT 10 
        FOR UPDATE SKIP LOCKED
    )
    UPDATE background_jobs 
    SET status = 'processing', locked_at = NOW(), attempts = attempts + 1 
    WHERE id IN (SELECT id FROM claimable) 
    RETURNING id, payload, attempts;
    ```

- **Read-After-Write Consistency, Replica Lag Fencing & Causal Read Routing**:
  - ❌ **Anti-Pattern: Blind Replica Routing & 404 Mirages**: Routing all `SELECT` queries to an asynchronous read replica immediately following an `INSERT` or `UPDATE`, causing intermittent 404 Not Found errors or data reversion due to replication lag ($\tau_{\text{lag}} \in [50\text{ms}, 2000\text{ms}]$).
  - ✅ **Production Invariant**: Return fresh mutation projections immediately via `RETURNING *` (0 read roundtrips), pin client sessions to the Primary writer for $T_{\text{sticky}} \ge 5.0\text{s}$ following any write, capture the Primary WAL Log Sequence Number via `pg_current_wal_lsn()`, and verify replica replay readiness with `pg_last_wal_replay_lsn()` before serving reads from replicas:
    ```sql
    -- 1. Single-Statement Write-Through Return (Eliminates subsequent read roundtrips)
    INSERT INTO orders (user_id, status, total_cents) 
    VALUES ('a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d'::UUID, 'pending', 9900)
    RETURNING id, user_id, status, total_cents, created_at;

    -- 2. Capture Primary WAL LSN for Causal Session Fencing
    SELECT pg_current_wal_lsn()::text AS commit_lsn;

    -- 3. Verify Replica Replay Readiness before Dispatching Read
    -- Returns TRUE if replica has replayed at or beyond the client's causal mutation LSN
    SELECT pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '0/1A2B3C4D'::pg_lsn) >= 0 AS caught_up;

    -- 4. Monitor Replication Lag in Seconds & Byte Offset
    SELECT 
        EXTRACT(EPOCH FROM (clock_timestamp() - pg_last_xact_replay_timestamp())) AS lag_seconds,
        pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS replay_pending_bytes;
    ```

- **Soft Deletes, Partial Unique Indexes, Recursive Cascade CTEs & Immutable Audit Trails**:
  - ❌ **Anti-Pattern: Plain UNIQUE on Soft-Deletable Tables & Broken Cascades**: Using standard `UNIQUE (slug)` or boolean `is_deleted = true`, which prevents re-registering previously deleted records, leaves child records orphaned because physical `ON DELETE CASCADE` never fires on `UPDATE`, and leaks soft-deleted ghost records when `WHERE deleted_at IS NULL` is omitted in multi-table joins.
  - ✅ **Production Invariant**: Use `deleted_at TIMESTAMPTZ NULL` with partial unique indexes `WHERE deleted_at IS NULL`, enforce transparent isolation via PostgreSQL `FORCE ROW LEVEL SECURITY`, execute cascade soft-deletions in a single recursive CTE with a shared `deleted_batch_id`, and protect audit tables with an immutable append-only exception trigger:
    ```sql
    -- 1. Partial Unique Index: Allows slug reuse after soft deletion
    CREATE UNIQUE INDEX idx_organizations_slug_active 
    ON organizations (tenant_id, slug) 
    WHERE deleted_at IS NULL;

    -- 2. Declarative Transparent Soft-Delete RLS Policy
    ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
    ALTER TABLE organizations FORCE ROW LEVEL SECURITY;

    CREATE POLICY organizations_active_isolation ON organizations
    FOR ALL TO authenticated, service_role
    USING (deleted_at IS NULL OR current_setting('app.include_soft_deleted', true) = 'true');

    -- 3. Atomic Recursive Cascade Soft-Delete CTE with Shared Batch UUID
    WITH target_org AS (
      UPDATE organizations SET
        deleted_at = NOW(),
        deleted_by = 'usr_admin123',
        deleted_batch_id = 'b3f5c7d2-4e1a-4c8f-9a1b-2c3d4e5f6a7b'::UUID,
        version = version + 1
      WHERE id = 'a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d'::UUID AND deleted_at IS NULL
      RETURNING id, deleted_batch_id
    ),
    del_projects AS (
      UPDATE projects SET
        deleted_at = NOW(),
        deleted_by = 'usr_admin123',
        deleted_batch_id = 'b3f5c7d2-4e1a-4c8f-9a1b-2c3d4e5f6a7b'::UUID,
        version = version + 1
      WHERE org_id IN (SELECT id FROM target_org) AND deleted_at IS NULL
      RETURNING id
    )
    SELECT id, deleted_batch_id FROM target_org;

    -- 4. Immutable Audit Ledger Protection (Append-Only Invariant)
    CREATE OR REPLACE FUNCTION prevent_audit_ledger_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      RAISE EXCEPTION 'SECURITY ERROR: Audit ledger records are append-only and cryptographically immutable';
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER trg_audit_ledger_immutable
    BEFORE UPDATE OR DELETE ON entity_audit_ledger
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_ledger_mutation();
    ```

- **Declarative Range Partitioning, Sargable Pruning Invariants & Concurrent Detachment (`DETACH CONCURRENTLY`)**:
  - ❌ **Anti-Pattern: Non-Sargable WHERE Predicates, Single-Column PKs & Transactional Detach**:
    - Declaring `PRIMARY KEY (id)` on a table partitioned by `created_at` (causing migration failure `ERROR: 0A000: insufficient columns in PRIMARY KEY constraint definition`).
    - Querying partitioned tables using `WHERE DATE_TRUNC('month', created_at) = '2026-03-01'` or casting `created_at::date`, which destroys static and run-time partition pruning and forces an exhaustive sequential table scan across all child partitions.
    - Executing `ALTER TABLE events DETACH PARTITION child;` inside a multi-statement transaction, which escalates to an `ACCESS EXCLUSIVE` lock on the parent table and stalls all concurrent production read/write queries.
  - ✅ **Production Invariant**:
    - Declare composite primary keys `PRIMARY KEY (id, created_at)` containing the partitioning column.
    - Guarantee sargable, type-aligned direct range comparisons `WHERE created_at >= $1 AND created_at < $2` to achieve $O(1)$ partition pruning.
    - Execute partition detachment via `ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY;` strictly outside any transaction block with an aggressive `SET lock_timeout = '2000ms'`:
    ```sql
    -- 1. Declarative Range Partitioning with Composite Primary Key
    CREATE TABLE high_throughput_events (
      id UUID NOT NULL,
      tenant_id UUID NOT NULL,
      event_type VARCHAR(64) NOT NULL,
      payload JSONB NOT NULL DEFAULT '{}',
      created_at TIMESTAMPTZ NOT NULL,
      CONSTRAINT pk_high_throughput_events PRIMARY KEY (id, created_at)
    ) PARTITION BY RANGE (created_at);

    -- 2. Local Index on (tenant_id, created_at DESC)
    CREATE INDEX idx_events_tenant_created
    ON high_throughput_events (tenant_id, created_at DESC);

    -- 3. Idempotent Monthly Partition Pre-Warming
    CREATE TABLE IF NOT EXISTS high_throughput_events_y2026m04
    PARTITION OF high_throughput_events
    FOR VALUES FROM ('2026-04-01 00:00:00+00') TO ('2026-05-01 00:00:00+00');

    -- 4. Sargable Query with Verified Partition Pruning
    EXPLAIN (ANALYZE, BUFFERS)
    SELECT id, event_type, created_at
    FROM high_throughput_events
    WHERE tenant_id = '018f3a52-9b24-7832-849a-7c9b0e9f1a23'::UUID
      AND created_at >= '2026-04-01 00:00:00+00'
      AND created_at < '2026-05-01 00:00:00+00';

    -- 5. Zero-Downtime Concurrent Detach (MUST RUN OUTSIDE TRANSACTION BLOCK)
    SET lock_timeout = '2000ms';
    ALTER TABLE high_throughput_events DETACH PARTITION high_throughput_events_y2026m04 CONCURRENTLY;

    -- 6. Lock-Free Isolated Drop (Zero parent table locks)
    DROP TABLE IF EXISTS high_throughput_events_y2026m04;
    ```

- **MVCC Bloat Elimination, Heap-Only Tuples (HOT) Invariance, Aggressive Autovacuum & Wraparound Defense**:
  - ❌ **Anti-Pattern: Indexing Volatile Timestamp/Counter Columns, Running VACUUM FULL & Default 20% Scale Factors**:
    - Adding secondary indexes on columns updated on every heartbeat or counter increment (e.g. `updated_at`, `ping_count`), forcing secondary index page writes on 100% of updates and destroying HOT updates.
    - Running `VACUUM FULL table_name;` to reclaim disk space, which acquires an `ACCESS EXCLUSIVE` table lock and stalls all concurrent reads and writes for hours.
    - Leaving default `autovacuum_vacuum_scale_factor = 0.20` and `autovacuum_vacuum_cost_limit = 200`, causing autovacuum to sleep while millions of dead rows accumulate on modern NVMe drives.
  - ✅ **Production Invariant**:
    - Set `fillfactor = 85` on update-heavy relations to reserve page headroom for HOT updates, ensuring $\eta_{\text{HOT}} \ge 0.90$.
    - Configure aggressive per-table autovacuum (`scale_factor = 0.01`, `threshold = 1000`, `cost_limit = 3000`).
    - Enforce `idle_in_transaction_session_timeout = '5s'` to prevent pinned $x_{\text{min}}$ transaction horizons.
    - Reclaim bloat with zero downtime via `REINDEX TABLE CONCURRENTLY` and `pg_repack`.
    ```sql
    -- 1. Configure Table Storage Parameters for HOT Updates & Micro-Vacuums
    ALTER TABLE user_sessions SET (
      fillfactor = 85,
      autovacuum_vacuum_scale_factor = 0.01,
      autovacuum_vacuum_threshold = 1000,
      autovacuum_analyze_scale_factor = 0.005,
      autovacuum_vacuum_cost_limit = 3000,
      autovacuum_vacuum_cost_delay = 2
    );

    -- 2. Audit HOT Update Efficiency (Target: hot_pct >= 90%)
    SELECT
      relname,
      n_tup_upd,
      n_tup_hot_upd,
      ROUND((n_tup_hot_upd::numeric / NULLIF(n_tup_upd, 0)) * 100, 2) AS hot_pct,
      n_dead_tup,
      ROUND((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 2) AS dead_ratio_pct
    FROM pg_stat_user_tables
    WHERE relname = 'user_sessions';

    -- 3. Detect Stale Transactions Pinning Global xmin Horizon
    SELECT
      pid,
      usename,
      state,
      EXTRACT(EPOCH FROM (NOW() - xact_start))::int AS age_seconds,
      query
    FROM pg_stat_activity
    WHERE backend_xmin IS NOT NULL
      AND pid <> pg_backend_pid()
      AND (NOW() - xact_start) > INTERVAL '30 seconds'
    ORDER BY xact_start ASC;

    -- 4. Reindex B-Tree Indexes Concurrently (Zero Table Read/Write Locks)
    REINDEX TABLE CONCURRENTLY user_sessions;

    -- 5. Audit Transaction ID (XID) Horizon to Prevent 2B Wraparound Shutdown
    SELECT
      max(age(datfrozenxid)) AS oldest_xid_age,
      2000000000 - max(age(datfrozenxid)) AS xids_until_wraparound
    FROM pg_database
    WHERE datallowconn;
    ```

- **Write-Ahead Logging (WAL), Checkpoint Smoothing, Asynchronous Commit & Replication Slot Boundaries**:
  - ❌ **Anti-Pattern: Checkpoint I/O Spikes, Unbounded Replication Slots & fsync Bottleneck**:
    - Leaving `checkpoint_completion_target = 0.5` and `max_wal_size = 1GB`, causing checkpoints to trigger every 60 seconds and dump gigabytes of dirty buffers into the OS cache in frantic bursts that saturate NVMe write bandwidth and spike p99 latency by 50x.
    - Defaulting to `synchronous_commit = on` on high-frequency streaming events, metrics, and logs, bottlenecking write throughput at 400 TPS due to storage fsync latency.
    - Creating physical or logical replication slots without `max_slot_wal_keep_size`, allowing a dead consumer to retain WAL files indefinitely until the disk fills to 100% and crashes the primary cluster.
    - Disabling `full_page_writes = off` to speed up synthetic benchmarks, risking silent torn-page block corruption upon power or kernel failure.
  - ✅ **Production Invariant**:
    - Configure `checkpoint_completion_target = 0.9` and `checkpoint_timeout = 15min` to trickle dirty page flushes smoothly over 90% of the interval.
    - Enforce `wal_compression = lz4` to slash full-page write (FPW) WAL amplification by 65%.
    - Apply Differentiated Durability: enforce `synchronous_commit = on` for financial/auth operations, and `SET LOCAL synchronous_commit = off` for high-throughput event logging.
    - Cap `max_slot_wal_keep_size = 10240MB` (10 GB) to guarantee that orphaned or disconnected slots are automatically invalidated before disk capacity hits 85%.
    ```sql
    -- 1. Configure Cluster-Wide Checkpoint Smoothing & LZ4 WAL Compression
    ALTER SYSTEM SET checkpoint_timeout = '15min';
    ALTER SYSTEM SET checkpoint_completion_target = 0.9;
    ALTER SYSTEM SET max_wal_size = '24GB';
    ALTER SYSTEM SET min_wal_size = '4GB';
    ALTER SYSTEM SET wal_compression = lz4;
    ALTER SYSTEM SET full_page_writes = on; -- Non-negotiable anti-torn-page invariant
    ALTER SYSTEM SET max_slot_wal_keep_size = '10240MB'; -- Prevent 100% disk filling outages

    -- 2. Audit Checkpoint Health & Timed vs Requested Ratio (Target: timed_pct >= 95%)
    SELECT
      checkpoints_timed,
      checkpoints_req,
      ROUND((checkpoints_timed::numeric / NULLIF(checkpoints_timed + checkpoints_req, 0)) * 100, 2) AS timed_pct,
      checkpoint_write_time,
      checkpoint_sync_time
    FROM pg_stat_bgwriter;

    -- 3. Audit Replication Slot Retained WAL Volume (Alert if retained_bytes > 5GB)
    SELECT
      slot_name,
      plugin,
      slot_type,
      active,
      wal_status,
      pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
    FROM pg_replication_slots
    ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;

    -- 4. High-Throughput Ingestion with Transaction-Local Asynchronous Commit
    BEGIN;
    SET LOCAL synchronous_commit = off; -- Eliminates 2ms fsync bottleneck; preserves transactional atomicity
    INSERT INTO device_telemetry (device_id, payload, recorded_at) VALUES ('d-123', '{"val": 42}', NOW());
    COMMIT;
    ```

- **Heavyweight Locks, Head-of-Line Blocking, Multi-Tier Timeout Ladders & Deadlock Prevention**:
  - ❌ **Anti-Pattern: Un-timed DDL Freezing Pools, Non-Canonical Deadlocks & Leaked Advisory Locks**:
    - Executing migrations, `ALTER TABLE`, or index drops with default `lock_timeout = 0`, queueing behind an active read and blocking all subsequent application reads in PostgreSQL's FIFO lock queue until connection pools exhaust.
    - Updating multiple rows in random or client-provided order, creating circular dependencies in the wait-for graph and triggering `40P01 deadlock_detected`.
    - Leaving `deadlock_timeout = 1000ms`, forcing mutually blocked worker threads to freeze for a full second before the cycle detector aborts one.
    - Using session-level `pg_advisory_lock()` in connection-pooled environments (PgBouncer), leaking held locks across transactions to unrelated clients.
    - Mutating parent rows without B-tree indexes on child foreign keys, triggering expensive child table scans and table-level lock contention.
  - ✅ **Production Invariant**:
    - Arm transactions with the Multi-Tier Timeout Ladder: `SET LOCAL lock_timeout = '1500ms'` and `SET LOCAL statement_timeout = '10000ms'`.
    - Enforce Canonical Lexicographical Ordering: sort all primary keys ascending before acquiring locks via `SELECT ... WHERE id = ANY($1) ORDER BY id ASC FOR UPDATE`, mathematically proving an acyclic DAG.
    - Tune `deadlock_timeout = 200ms` to slash deadlock detection latency by 80%.
    - Use transaction-scoped advisory locks `pg_advisory_xact_lock()` or non-blocking `pg_try_advisory_xact_lock()`, auto-released on commit or rollback.
    - Continuously audit and index 100% of foreign key columns to eliminate child table lock escalation.
    ```sql
    -- 1. Cluster-Wide Deadlock & Timeout Tuning
    ALTER SYSTEM SET deadlock_timeout = '200ms';
    ALTER SYSTEM SET lock_timeout = '2000ms';
    ALTER SYSTEM SET statement_timeout = '10000ms';
    ALTER SYSTEM SET idle_in_transaction_session_timeout = '5000ms';

    -- 2. Audit Real-Time Contested Heavyweight Locks & Blocking PIDs
    SELECT
      blocked_locks.pid AS blocked_pid,
      blocked_activity.usename AS blocked_user,
      blocking_locks.pid AS blocking_pid,
      blocking_activity.usename AS blocking_user,
      blocked_activity.query AS blocked_statement,
      blocking_activity.query AS current_statement_in_blocking_process,
      blocked_locks.locktype,
      blocked_locks.mode AS requested_mode,
      blocking_locks.mode AS held_mode,
      ROUND(EXTRACT(EPOCH FROM (NOW() - blocked_activity.query_start))::numeric, 2) AS wait_seconds
    FROM pg_catalog.pg_locks blocked_locks
    JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
    JOIN pg_catalog.pg_locks blocking_locks
      ON blocking_locks.locktype = blocked_locks.locktype
      AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
      AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
      AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
      AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
      AND blocking_locks.pid != blocked_locks.pid
    JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
    WHERE NOT blocked_locks.granted;

    -- 3. Audit Foreign Keys Lacking Supporting B-Tree Indexes
    SELECT
      c.conrelid::regclass AS child_table,
      c.conname AS foreign_key_name,
      ARRAY(
        SELECT attname FROM pg_attribute
        WHERE attrelid = c.conrelid AND attnum = ANY(c.conkey)
      ) AS fk_columns,
      c.confrelid::regclass AS parent_table
    FROM pg_constraint c
    WHERE c.contype = 'f'
      AND NOT EXISTS (
        SELECT 1 FROM pg_index i
        WHERE i.indrelid = c.conrelid
          AND (i.indkey::smallint[])[0:cardinality(c.conkey)-1] = c.conkey
      );

    -- 4. Canonical Row-Level Locking with Timeout Ladder & Safe Advisory Lock
    BEGIN;
    SET LOCAL lock_timeout = '1500ms';
    SET LOCAL statement_timeout = '5000ms';
    -- Transaction-scoped advisory lock (safe in PgBouncer)
    SELECT pg_advisory_xact_lock(hashtext('user-reconciliation-42'));
    -- Canonical ascending lock acquisition eliminating wait-for cycles
    SELECT id, balance FROM accounts WHERE id IN (10, 20) ORDER BY id ASC FOR UPDATE;
    UPDATE accounts SET balance = balance - 100 WHERE id = 10;
    UPDATE accounts SET balance = balance + 100 WHERE id = 20;
    COMMIT;
    ```

- **High Availability, Automated Failover, Split-Brain Fencing & Client Reconnection Topology**:
  - ❌ **Anti-Pattern: Single-Host DNS Caching, Read-Only Connection Landings & Split-Brain Divergence**:
    - Configuring connection strings with a single DNS host relying on DNS TTL caching, causing application clients to hammer dead primaries during failovers.
    - Specifying multi-host connection URIs without `target_session_attrs=read-write`, causing write pools to connect to read-only standbys and fail with `25006 cannot execute INSERT in a read-only transaction`.
    - Relying on software-only ping health checks without hardware/software watchdog fencing (`/dev/watchdog`), allowing isolated primaries to accept rogue writes and create divergent WAL timelines (split-brain).
    - Promoting asynchronous standbys with un-replayed WAL, violating Zero-RPO financial guarantees ($RPO > 0$).
    - Wiping out entire data directories on demoted nodes and running multi-hour `pg_basebackup` clones instead of automated `pg_rewind` delta reconciliation.
  - ✅ **Production Invariant**:
    - Multi-host connection URI with explicit `target_session_attrs=read-write&load_balance_hosts=disable`, validating `SHOW transaction_read_only = off` at handshake.
    - Zero-RPO Synchronous Quorum: configure `synchronous_commit = on` (or `remote_apply`) with `synchronous_standby_names = 'ANY 1 (node2, node3)'`.
    - Distributed Consensus & Watchdog Fencing: enforce $T_{\text{watchdog}} < T_{\text{lease}} - T_{\text{loop\_wait}} - \Delta_{\text{skew}}$ via Patroni + etcd, guaranteeing hardware reboot before standby promotion.
    - Always enable `wal_log_hints = on` to permit automated, sub-minute `pg_rewind` timeline resynchronization without destructive re-cloning.
    ```sql
    -- 1. Cluster Status & Role Auditing
    SELECT
      pg_is_in_recovery() AS is_standby,
      current_setting('transaction_read_only') AS is_read_only,
      pg_current_wal_lsn() AS primary_lsn,
      pg_last_wal_receive_lsn() AS standby_receive_lsn,
      pg_last_wal_replay_lsn() AS standby_replay_lsn;

    -- 2. Synchronous Standby Replication & WAL Flush Health
    SELECT
      client_addr,
      application_name,
      sync_state,
      sync_priority,
      state,
      sent_lsn,
      write_lsn,
      flush_lsn,
      replay_lsn,
      ROUND(EXTRACT(EPOCH FROM (NOW() - reply_time))::numeric, 2) AS lag_seconds
    FROM pg_stat_replication;

    -- 3. Zero-RPO Synchronous Commit Cluster Invariant
    ALTER SYSTEM SET wal_log_hints = 'on';
    ALTER SYSTEM SET synchronous_commit = 'on';
    ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (pg-node-02, pg-node-03)';
    SELECT pg_reload_conf();
    ```

- **Disaster Recovery, Continuous WAL Archiving, Point-in-Time Recovery (PITR) & amcheck Integrity**:
  - ❌ **Anti-Pattern: Monolithic Logical Dumps, Unverified Backups & Insecure S3 Repositories**:
    - Relying exclusively on daily `pg_dump` cron jobs on databases $> 50\text{GB}$, which take hours, lock tables, exhaust memory, and provide zero Point-in-Time Recovery ($RPO > 12\text{h}$).
    - Misconfiguring `archive_command` with synchronous shell commands without timeouts or error handling, causing PostgreSQL to hoard WAL segments until disk fills and engine triggers a `PANIC` crash.
    - Executing PITR with `recovery_target_inclusive = true` and `recovery_target_action = 'promote'`, accidentally replaying past the destructive drop/truncate statement and triggering immediate promotion without verification.
    - Running production without `data_checksums = on`, allowing silent NVMe/SAN bit rot to corrupt heap pages and persist undetected across months of backups.
  - ✅ **Production Invariant**:
    - Physical chunked basebackups via `pgBackRest` with multi-core ZSTD compression offloaded to standby nodes.
    - Continuous asynchronous WAL archiving (`archive_timeout = 300`, `archive_mode = on`) pushing to WORM S3 Object Lock repositories in Compliance Mode.
    - Surgical PITR invariant: `recovery_target_inclusive = false`, `recovery_target_action = 'pause'`, and `recovery_target_timeline = 'latest'`. Programmatic integrity checks MUST pass before issuing `SELECT pg_wal_replay_resume()`.
    - Mandatory cluster checksums (`initdb -k`) and weekly read-only `amcheck` index structural verification.
    ```sql
    -- 1. Continuous Archiving & WAL Backlog Health Sentinel
    SELECT
      archived_count,
      last_archived_wal,
      last_archived_time,
      failed_count,
      last_failed_wal,
      last_failed_time,
      ROUND(EXTRACT(EPOCH FROM (NOW() - last_archived_time))::numeric, 2) AS seconds_since_last_archive
    FROM pg_stat_archiver;

    -- 2. Verify Page Checksums Active on Running Cluster
    SHOW data_checksums;

    -- 3. amcheck Structural B-Tree Index Corruption Verification (Non-Blocking)
    CREATE EXTENSION IF NOT EXISTS amcheck;

    SELECT
      c.oid::regclass AS verified_index,
      bt_index_parent_check(c.oid, true) AS is_structurally_valid
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relam = 403 -- B-Tree access method
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND c.relpersistence = 'p'
    LIMIT 100;
    ```

- **Change Data Capture (CDC), Logical Replication Slots & Replica Identity Invariants**:
  - ❌ **Anti-Pattern: Unbounded Logical Slots, Unindexed REPLICA IDENTITY FULL & Catalog Bloat**:
    - Creating logical replication slots (`pg_create_logical_replication_slot`) without setting `max_slot_wal_keep_size`, causing disconnected CDC consumers to hoard WAL segments until disk fills to 100% and crashes the cluster with postmaster `PANIC`.
    - Blindly executing `ALTER TABLE t REPLICA IDENTITY FULL` on high-traffic tables without verified subscriber indexes, forcing subscribing nodes to execute sequential full-table scans for every single `UPDATE`/`DELETE`, locking CPU at 100%.
    - Leaving orphaned development or testing logical slots active, permanently pinning `catalog_xmin` and preventing autovacuum from cleaning dead tuples in `pg_catalog`, degrading query planning latency cluster-wide by 50x.
    - Consuming CDC streams downstream without monotonic LSN fencing, causing out-of-order state overwrites or duplicate side-effects on consumer restarts.
  - ✅ **Production Invariant**:
    - Bound replication slot WAL retention with `max_slot_wal_keep_size = '32768MB'` and tune `logical_decoding_work_mem = '131072kB'`.
    - Mandatory `REPLICA IDENTITY DEFAULT` backed by an immutable primary key (`UUIDv7` or `BIGINT`), or explicit `REPLICA IDENTITY USING INDEX <unique_idx>`.
    - Automated sentinel alerting when `age(catalog_xmin) > 500000` transactions or when slot lag exceeds 10GB.
    - Monotonic LSN fencing on downstream projections: discard incoming events where `incoming_lsn <= last_applied_lsn`.
    ```sql
    -- 1. Logical Replication Slot Health, Lag & Catalog xmin Sentinel
    SELECT
      slot_name,
      plugin,
      slot_type,
      active,
      active_pid,
      wal_status,
      ROUND(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / (1024 * 1024), 2) AS lag_restart_mb,
      ROUND(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) / (1024 * 1024), 2) AS lag_flush_mb,
      catalog_xmin,
      age(catalog_xmin) AS catalog_xmin_age
    FROM pg_replication_slots
    WHERE slot_type = 'logical';

    -- 2. Publication Replica Identity & Primary Key Audit
    SELECT
      c.relname AS table_name,
      c.relreplident AS replica_identity,
      CASE c.relreplident
        WHEN 'd' THEN 'default (PK)'
        WHEN 'n' THEN 'nothing'
        WHEN 'f' THEN 'full'
        WHEN 'i' THEN 'index'
      END AS identity_desc,
      (SELECT count(*) FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary) > 0 AS has_primary_key
    FROM pg_publication_tables pt
    JOIN pg_class c ON c.relname = pt.tablename
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = pt.schemaname;

    -- 3. Disk Fencing Boundary Configuration
    ALTER SYSTEM SET max_slot_wal_keep_size = '32768MB';
    ALTER SYSTEM SET logical_decoding_work_mem = '131072kB';
    SELECT pg_reload_conf();
    ```

- **Row-Level Security (RLS), `FORCE ROW LEVEL SECURITY` & Multi-Tenant Isolation Invariants**:
  - ❌ **Anti-Pattern: Table Owner Bypass, Session Context Bleed & Unindexed RLS Meltdown**:
    - Executing `ALTER TABLE t ENABLE ROW LEVEL SECURITY` without `FORCE ROW LEVEL SECURITY`, allowing application connections using the migration owner role to silently bypass RLS and leak multi-tenant records across organizations.
    - Setting tenant context with session scope (`SET app.current_tenant_id = '...'`) instead of `SET LOCAL`, causing connection pooling (PgBouncer in transaction mode or backend pools) to leak the previous tenant's identity to subsequent requests.
    - Creating views over RLS tables without `WITH (security_invoker = true)` in PostgreSQL 15+, executing views with the creator's elevated permissions and stripping tenant RLS filters.
    - Defining RLS policies on tables lacking composite indexes with `tenant_id` as the leading leftmost column, forcing PostgreSQL to execute sequential table scans across millions of rows for simple primary key lookups.
  - ✅ **Production Invariant**:
    - Enforce `ALTER TABLE <table> FORCE ROW LEVEL SECURITY;` on 100% of multi-tenant tables.
    - Application pools connect strictly as an unprivileged role (`app_user`) with `NOSUPERUSER NOBYPASSRLS`.
    - Mandatory transaction-scoped context setting `SET LOCAL app.current_tenant_id = '...'` or parameterized `set_config('app.current_tenant_id', $1, true)`.
    - Fail-closed policy evaluation: `USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID)`.
    - 100% composite index coverage with `tenant_id` as the leftmost column (`PRIMARY KEY (tenant_id, id)`).
    - Mandatory `WITH (security_invoker = true, security_barrier = true)` on all multi-tenant views.
    ```sql
    -- 1. Comprehensive RLS & FORCE Flag Compliance Audit
    SELECT
      c.relname AS table_name,
      pg_get_userbyid(c.relowner) AS table_owner,
      c.relrowsecurity AS is_rls_enabled,
      c.relforcerowsecurity AS is_rls_forced,
      (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policy_count,
      EXISTS (
        SELECT 1 FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
        WHERE i.indrelid = c.oid AND a.attname = 'tenant_id'
      ) AS has_leftmost_tenant_index
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname = 'public'
      AND c.relname NOT IN ('schema_migrations');

    -- 2. View Security Invoker & Barrier Compliance Audit
    SELECT
      c.relname AS view_name,
      pg_get_userbyid(c.relowner) AS view_owner,
      COALESCE('security_invoker=true' = ANY(c.reloptions), false) AS has_security_invoker,
      COALESCE('security_barrier=true' = ANY(c.reloptions), false) AS has_security_barrier
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'v'
      AND n.nspname = 'public';

    -- 3. Production Hardening Template
    ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
    ALTER TABLE documents FORCE ROW LEVEL SECURITY;

    CREATE POLICY documents_tenant_isolation ON documents
      FOR ALL
      TO app_user
      USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID)
      WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

    CREATE INDEX idx_documents_tenant_created ON documents (tenant_id, created_at DESC);
    ```

- **Database Statistics, Extended Statistics (`CREATE STATISTICS`) & Query Planner Calibration Invariants**:
  - ❌ **Anti-Pattern: Correlated Predicate Underestimation, NVMe Random Cost Penalty & Stale Stats Spills**:
    - Relying on default independent column statistics when queries filter on correlated attributes (`WHERE country = 'US' AND state = 'CA'`), causing the planner to multiply probabilities, underestimate row count by orders of magnitude, and select disastrous Nested Loop joins.
    - Retaining default 1990s HDD storage parameters (`random_page_cost = 4.0`), penalizing B-tree index scans on modern NVMe SSDs and triggering unnecessary full sequential table scans.
    - Leaving JIT compilation enabled (`jit = on`) in low-latency OLTP services, adding 30ms–150ms of synchronous LLVM compilation overhead to queries that execute in 1.5ms.
    - Failing to execute `ANALYZE` after large batch ingestions, causing stale `pg_statistic` data to allocate undersized `work_mem` hash buckets that spill gigabytes to temporary disk files.
  - ✅ **Production Invariant**:
    - Calibrate storage cost parameters for NVMe SSDs: `random_page_cost = 1.1`, `seq_page_cost = 1.0`, and `effective_io_concurrency = 200`.
    - Turn off JIT for OLTP workloads (`jit = off`).
    - Create multivariate extended statistics on correlated multi-predicate queries: `CREATE STATISTICS <name> (dependencies, ndistinct, mcv) ON col_a, col_b FROM <table>;`.
    - Set granular column sample targets: `ALTER TABLE <table> ALTER COLUMN <col> SET STATISTICS 1000;` on high-skew attributes.
    - Proactively trigger `ANALYZE` post-batch operations and tune `autovacuum_analyze_scale_factor = 0.02`.
    ```sql
    -- 1. Query Extended Statistics Audit
    SELECT
      stxname AS statistics_name,
      stxnamespace::regnamespace AS schema_name,
      c.relname AS table_name,
      stxkind AS statistics_kinds,
      ARRAY(
        SELECT attname FROM pg_attribute
        WHERE attrelid = c.oid AND attnum = ANY(s.stxkeys)
      ) AS columns
    FROM pg_statistic_ext s
    JOIN pg_class c ON c.oid = s.stxrelid
    WHERE c.relnamespace = 'public'::regnamespace;

    -- 2. Hardware Planner Cost Alignment (NVMe SSDs)
    ALTER SYSTEM SET random_page_cost = 1.1;
    ALTER SYSTEM SET seq_page_cost = 1.0;
    ALTER SYSTEM SET effective_io_concurrency = 200;
    ALTER SYSTEM SET jit = off;
    SELECT pg_reload_conf();

    -- 3. Production Extended Statistics Creation
    CREATE STATISTICS IF NOT EXISTS stat_orders_tenant_status
      ON (dependencies, ndistinct, mcv)
      FROM orders (tenant_id, status);
    ANALYZE orders;
    ```

- **Database Memory Management, Temp Spillover Elimination & OOM Killer Defense Invariants**:
  - ❌ **Anti-Pattern: Unbounded work_mem Sizing, Undersized Vacuum TID Buffers & Unmonitored Spills**:
    - Sizing `work_mem` under the false assumption that it is allocated once per query or once per connection, unaware that each sort, hash join, and parallel worker allocates its own buffer, causing 50 concurrent queries with 6 execution nodes to exhaust host RAM and trigger Linux kernel OOM kills against the postmaster.
    - Retaining default `work_mem = 4MB` on heavy analytics or aggregation workloads, forcing queries into multi-pass external merge sorts and multi-batch hash joins that write tens of gigabytes to temporary disk files.
    - Leaving `log_temp_files = -1` and `temp_file_limit = -1`, allowing unmonitored queries and Cartesian products to silently consume storage until 100% disk exhaustion crashes the cluster.
    - Sizing `maintenance_work_mem = 64MB`, capping autovacuum's dead tuple TID array at 11M items and forcing 5–10 repeated full index scans on large churned tables.
  - ✅ **Production Invariant**:
    - Enforce host-level Linux postmaster OOM immunity (`oom_score_adj = -1000`), ensuring the kernel terminates rogue query backends rather than the database postmaster.
    - Configure hard storage fences: `ALTER SYSTEM SET temp_file_limit = '10GB';` and `ALTER SYSTEM SET log_temp_files = 0;`.
    - Calibrate autovacuum memory: `ALTER SYSTEM SET maintenance_work_mem = '1GB';` and `ALTER SYSTEM SET autovacuum_work_mem = '256MB';` for single-pass TID collection on up to 45M dead rows.
    - Execute heavy analytical reports strictly within transaction-scoped `SET LOCAL work_mem = '256MB';` envelopes, reverting automatically upon commit.
    ```sql
    -- 1. Cluster Memory & Temp File Safeguards
    ALTER SYSTEM SET work_mem = '32MB';
    ALTER SYSTEM SET hash_mem_multiplier = 2.0;
    ALTER SYSTEM SET maintenance_work_mem = '1GB';
    ALTER SYSTEM SET autovacuum_work_mem = '256MB';
    ALTER SYSTEM SET temp_file_limit = '10GB';
    ALTER SYSTEM SET log_temp_files = 0;
    SELECT pg_reload_conf();

    -- 2. Audit Database-Wide Disk Spill Volumes
    SELECT
      datname,
      temp_files AS total_temp_files_created,
      pg_size_pretty(temp_bytes) AS total_temp_bytes_spilled
    FROM pg_stat_database
    WHERE datname = current_database();

    -- 3. Transaction-Scoped Adaptive Memory Execution
    BEGIN;
      SET LOCAL work_mem = '256MB';
      SET LOCAL hash_mem_multiplier = 2.0;

      SELECT tenant_id, count(*), sum(amount_cents)
      FROM orders
      WHERE created_at >= NOW() - INTERVAL '30 days'
      GROUP BY tenant_id
      ORDER BY sum(amount_cents) DESC;
    COMMIT;
    ```

- **Database Full-Text Search, Trigram Indexing, GIN FastUpdate & Bloat Elimination Invariants**:
  - ❌ **Anti-Pattern: Leading Wildcard ILIKE, Dynamic to_tsvector, and Unmonitored GIN Pending Lists**:
    - Implementing search using unindexed leading wildcards (`WHERE title ILIKE '%' || $1 || '%'`), forcing full-table sequential scans over millions of rows that peg CPU at 100% and inflate p99 latency by $150\times$.
    - Computing `to_tsvector('english', title || ' ' || content)` dynamically inside `WHERE` clauses without a pre-computed generated column, redundantly tokenizing and Snowball-stemming text on every query.
    - Leaving `fastupdate = on` with default `gin_pending_list_limit = 4MB` on write-intensive tables, causing innocent `INSERT` statements to suddenly stall for 2,500ms–8,000ms while executing synchronous pending list cleanups.
    - Querying trigrams using `WHERE similarity(title, $1) > 0.3` instead of the sargable `%` or `%>` operators, causing the planner to ignore GIN/GiST indexes.
    - Linearly adding raw `ts_rank` and vector cosine distance scores, causing arbitrary vector magnitude drift to drown out exact keyword, SKU, or email matches.
  - ✅ **Production Invariant**:
    - Mandate stored generated `tsvector` columns with immutable language configurations (`unaccent_english`) to eliminate run-time stemming overhead.
    - Hardened GIN indexing: calibrate `gin_pending_list_limit = '16MB'` for read-heavy workloads or configure `WITH (fastupdate = off)` on latency-critical OLTP write paths.
    - Query text exclusively via `websearch_to_tsquery()` to prevent unescaped user syntax errors (`&`, `|`, `!`).
    - Enforce Reciprocal Rank Fusion (RRF with $k=60$) for hybrid lexical and vector semantic search.
    ```sql
    -- 1. Generated Stored Search Vector with Weighted Fields
    ALTER TABLE knowledge_articles
      ADD COLUMN IF NOT EXISTS search_vector tsvector
      GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(content, '')), 'B')
      ) STORED;

    -- 2. Hardened GIN Index with Calibrated Pending Limit
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_articles_fts
      ON knowledge_articles USING gin (search_vector)
      WITH (fastupdate = on, gin_pending_list_limit = '16MB');

    -- 3. Trigram Autocomplete Index with Zero Write Stalls
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_articles_title_trgm
      ON knowledge_articles USING gin (title gin_trgm_ops)
      WITH (fastupdate = off);

    -- 4. Safe Sargable Query Execution
    SELECT id, title, ts_rank_cd(search_vector, q) AS rank
    FROM knowledge_articles, websearch_to_tsquery('english', 'database "full text" -deprecated') q
    WHERE search_vector @@ q
    ORDER BY rank DESC
    LIMIT 20;
    ```

- **Database JSONB Document-Relational Modeling, `jsonb_path_ops`, TOAST De-TOASTing Defense & Schema Invariants**:
  - ❌ **Anti-Pattern: Unbounded `SELECT *`, Default `jsonb_ops` GIN Bloat, Non-Sargable `->>`, and Schemaless Mutation**:
    - Executing `SELECT * FROM events` on tables containing multi-kilobyte JSONB payloads exceeding `TOAST_TUPLE_THRESHOLD` (2KB), forcing PostgreSQL to fetch, de-chunk, and decompress out-of-line TOAST slices across multiple 8KB pages, driving cache eviction in `shared_buffers` and collapsing throughput by $90\%$.
    - Modifying single scalar keys via `UPDATE t SET payload = jsonb_set(payload, '{status}', '"paid"')`, rewriting the entire heap tuple and duplicating multi-kilobyte TOAST chunks with $10,000\times$ write amplification.
    - Creating default GIN indexes `USING gin (payload)` with `jsonb_ops`, decomposing every key and sub-element individually and ballooning index size to $3\times–6\times$ the table heap.
    - Querying via `WHERE payload->>'tenant_id' = $1`, which completely bypasses standard GIN indexes and degrades into a full-table sequential scan.
  - ✅ **Production Invariant**:
    - Mandate explicit column projection (`SELECT id, status, created_at`); never `SELECT *` on relations with JSONB columns.
    - Use `jsonb_path_ops` GIN indexing (`USING gin (payload jsonb_path_ops)`) for containment `@>` queries to achieve up to $65\%$ index compression and faster scans.
    - Build Expression B-Tree indexes (`CREATE INDEX ON t (((payload->>'tenant_id')::uuid))`) or `STORED GENERATED` columns for frequent scalar arrow lookups and foreign keys.
    - Enforce database-level schema constraints: validate mandatory keys with `?&` and types with `jsonb_typeof()`.
    - Hoist frequently mutated status flags and counters out of JSONB into dedicated relational columns to enable Heap-Only Tuples (HOT) updates without TOAST duplication.
    ```sql
    -- 1. Hardened Table with Relational Core + JSONB Satellite + Schema Fencing
    CREATE TABLE IF NOT EXISTS audit_events (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      tenant_id UUID NOT NULL,
      status VARCHAR(32) NOT NULL DEFAULT 'received',
      retry_count INT NOT NULL DEFAULT 0,
      external_id VARCHAR(128) GENERATED ALWAYS AS (
        NULLIF(payload->>'external_id', '')
      ) STORED,
      payload JSONB NOT NULL DEFAULT '{}'::jsonb,
      created_at TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP(),
      CONSTRAINT chk_payload_keys CHECK (payload ?& array['schema_version', 'data']),
      CONSTRAINT chk_payload_version CHECK (jsonb_typeof(payload->'schema_version') = 'number')
    );

    -- 2. Compact jsonb_path_ops Inverted Index for Containment Scans
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_events_payload_path_ops
      ON audit_events USING gin (payload jsonb_path_ops)
      WITH (fastupdate = on, gin_pending_list_limit = '16MB');

    -- 3. Expression B-Tree Index for Arrow Lookups
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_events_external_id
      ON audit_events (external_id)
      WHERE external_id IS NOT NULL;

    -- 4. Sargable Containment Query Execution
    SELECT id, tenant_id, status, created_at
    FROM audit_events
    WHERE tenant_id = 'a0000000-0000-0000-0000-000000000001'::uuid
      AND payload @> '{"data": {"priority": "high"}}'::jsonb
    ORDER BY created_at DESC
    LIMIT 50;
    ```

- **Database BRIN Indexing, Append-Only Time-Series Ingestion, Physical Heap Correlation & Space Amplification Defense**:
  - ❌ **Anti-Pattern: B-Tree Space Bloat on Append-Only Logs, Missing `autosummarize`, Out-of-Order Correlation Decay, and Default `minmax_ops` Outlier Poisoning**:
    - Creating standard B-Tree indexes on `created_at` or `timestamp` across 100M+ append-only telemetry/log rows, consuming 3GB–5GB of disk space per index and evicting hot OLTP working sets from `shared_buffers`.
    - Omitting `autosummarize = on` when creating BRIN indexes, causing newly appended heap pages at the table head to remain unsummarized and forcing real-time queries into sequential scans over gigabytes of heap data.
    - Creating BRIN indexes on random UUIDv4 or cryptographic hashes where physical disk correlation $|\text{correlation}| \approx 0$, resulting in 100% false-positive block hits and running slower than a sequential scan.
    - Using default `minmax_ops` vulnerable to single-record outlier poisoning (e.g. an erroneous future timestamp), permanently expanding range envelopes cluster-wide.
  - ✅ **Production Invariant**:
    - Deploy Block Range Indexes (BRIN) on naturally monotonic, append-only time columns, achieving $\ge 99\%$ index space reduction compared to B-Tree.
    - Always specify `WITH (autosummarize = on, pages_per_range = 32)` (or 64) to ensure background autovacuum summarization of newly appended pages.
    - Use PostgreSQL 14+ `minmax_multi_ops` (`recorded_at timestamptz_minmax_multi_ops`) to store non-overlapping interval ranges and isolate stray outliers.
    - Enforce monotonic primary keys (UUIDv7 or BigSerial) to guarantee physical disk correlation $|\text{correlation}| \ge 0.95$ in `pg_stats`.
    - Never wrap BRIN columns in non-sargable functions (`DATE_TRUNC`, `DATE()`, `CAST()`) in `WHERE` clauses.
    ```sql
    -- 1. Append-Only Telemetry Partition with Monotonic Timestamp Ordering
    CREATE TABLE IF NOT EXISTS telemetry_events_partition (
      id UUID NOT NULL,
      tenant_id UUID NOT NULL,
      metric_name VARCHAR(128) NOT NULL,
      value DOUBLE PRECISION NOT NULL,
      recorded_at TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP(),
      payload JSONB NOT NULL DEFAULT '{}'::jsonb,
      CONSTRAINT pk_telemetry_partition PRIMARY KEY (id, recorded_at)
    );

    -- 2. Compact BRIN Index with minmax_multi_ops & autosummarize = on
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_telemetry_recorded_at_brin
      ON telemetry_events_partition
      USING brin (recorded_at timestamptz_minmax_multi_ops)
      WITH (pages_per_range = 32, autosummarize = on);

    -- 3. Categorical Bloom Filter BRIN Index for Semi-Clustered Tenant Lookups
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_telemetry_tenant_bloom_brin
      ON telemetry_events_partition
      USING brin (tenant_id uuid_bloom_ops)
      WITH (pages_per_range = 64, autosummarize = on);

    -- 4. Sargable Direct Range Predicate (Bypass Date Functions)
    SELECT id, tenant_id, metric_name, value, recorded_at
    FROM telemetry_events_partition
    WHERE tenant_id = 'b0000000-0000-0000-0000-000000000002'::uuid
      AND recorded_at >= '2026-10-28 00:00:00+00'::timestamptz
      AND recorded_at < '2026-10-28 01:00:00+00'::timestamptz
    ORDER BY recorded_at ASC
    LIMIT 500;
    ```

- **Database pgvector HNSW Indexing, Halfvec Quantization, Filtered Vector Recall & Memory Amplification Defense**:
  - ❌ **Anti-Pattern: Filtered Vector 0-Row Under-Recall, Uncompressed FP32 Shared Buffers Eviction, Build Memory Starvation, and Operator Opclass Mismatch**:
    - Executing filtered vector queries (`WHERE tenant_id = $1 ORDER BY embedding <=> $2 LIMIT 10`) without setting `hnsw.iterative_scan = 'relaxed_order'`, causing HNSW graph traversal to evaluate top-$K$ candidates globally, reject non-matching rows during post-filtering, and return 0 results even when relevant documents exist.
    - Storing high-dimensional embeddings as raw `vector(1536)` (float32, 4 bytes/dim), consuming 6.1KB per row and dozens of gigabytes in RAM, evicting relational tables and B-tree indexes from `shared_buffers`.
    - Creating HNSW indexes under default `maintenance_work_mem = 64MB`, triggering disk swap thrashing and turning a 4-minute index build into an 18-hour frozen database lockup.
    - Creating indexes with `vector_cosine_ops` (`<=>`) but querying with Euclidean `<->` or inner product `<#>`, silently bypassing the HNSW index and running full-table sequential vector scans.
  - ✅ **Production Invariant**:
    - Migrate high-dimensional embeddings ($\ge 1024$ dims) to PostgreSQL pgvector 0.7.0+ `halfvec(1536)` (16-bit float) to cut memory usage by $50\%$ with $<0.05\%$ recall loss, or use Binary Quantization `bit(1536)` with Hamming distance `<~>` for two-phase candidate re-ranking.
    - Always activate `SET LOCAL hnsw.iterative_scan = 'relaxed_order'` and calibrate `SET LOCAL hnsw.ef_search = 100` inside transactions executing filtered vector queries.
    - Allocate `SET LOCAL maintenance_work_mem = '4GB'` and `SET LOCAL max_parallel_maintenance_workers = 4` before executing `CREATE INDEX CONCURRENTLY ... USING hnsw`.
    - Enforce unit-length normalization ($\|\mathbf{v}\|_2 = 1.0$) at insertion time to unlock fused multiply-add SIMD AVX-512 Inner Product line-rate acceleration.
    ```sql
    -- 1. Table with Halfvec 16-Bit Quantized Embedding & Tenant Indexing
    CREATE TABLE IF NOT EXISTS document_chunks (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      tenant_id UUID NOT NULL,
      document_id UUID NOT NULL,
      content TEXT NOT NULL,
      embedding halfvec(1536) NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP()
    );

    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_chunks_tenant_created
      ON document_chunks (tenant_id, created_at DESC);

    -- 2. Parallel HNSW Index Build with Calibrated Session Memory
    SET maintenance_work_mem = '4GB';
    SET max_parallel_maintenance_workers = 4;

    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_chunks_embedding_hnsw
      ON document_chunks
      USING hnsw (embedding halfvec_cosine_ops)
      WITH (m = 16, ef_construction = 128);

    RESET maintenance_work_mem;
    RESET max_parallel_maintenance_workers;

    -- 3. Filtered Vector Retrieval with Transactional Iterative Scan Guardrail
    BEGIN;
    SET LOCAL hnsw.iterative_scan = 'relaxed_order';
    SET LOCAL hnsw.ef_search = 100;

    SELECT
      id,
      tenant_id,
      content,
      1 - (embedding <=> $1::halfvec(1536)) AS similarity
    FROM document_chunks
    WHERE tenant_id = $2::UUID
    ORDER BY embedding <=> $1::halfvec(1536)
    LIMIT 10;
    COMMIT;
    ```

- **Database GiST & SP-GiST Indexing, Spatial Geometry, Temporal Range Exclusion & Collision Defense**:
  - ❌ **Anti-Pattern: Application-Level Pre-Check Race Conditions, Angular Degree Distance Disasters, Runtime Cast Index Bypassing, and Proximity Full-Scan Sorting**:
    - Checking for calendar or resource booking conflicts with application-level `SELECT COUNT(*) WHERE period && $1` before `INSERT`. Under concurrent transactions in `READ COMMITTED` or `REPEATABLE READ`, both transactions see zero conflicts and insert overlapping reservations, double-booking hotel rooms, conference halls, or fleet vehicles.
    - Storing geographic coordinates in unprojected `GEOMETRY(Point, 4326)` in angular degrees, and querying with `ST_DWithin(geom, $1, 1000)` assuming meters, which actually evaluates 1,000 degrees ($\approx 111,000\text{ km}$), matching the entire Earth 14 times over.
    - Casting indexed geometry columns to geography inside queries (`WHERE ST_DWithin(geom::geography, ...)`), which invalidates the GiST index and forces multi-second full-table sequential scans.
    - Writing proximity queries as `ORDER BY ST_Distance(location, $1) LIMIT 10`, which calculates distance across millions of rows and performs an expensive external sort instead of utilizing the GiST `<->` distance operator.
  - ✅ **Production Invariant**:
    - Enforce non-overlapping temporal and resource reservations at the engine level using PostgreSQL Exclusion Constraints (`EXCLUDE USING gist`) with the `btree_gist` extension and canonical half-open bounds `[)`. Catch SQLSTATE `23P01` (`exclusion_violation`) in application layers and return clean HTTP 409 Conflict responses.
    - Use native `GEOGRAPHY(Point, 4326)` for global spherical calculations in meters, or projected `GEOMETRY(Point, 3857)` for localized Euclidean math. Never perform runtime type casting on indexed spatial columns.
    - Accelerate nearest-neighbor (k-NN) queries with the native GiST `<->` distance operator (`ORDER BY location <-> ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography LIMIT 10`), enabling index-driven branch-and-bound traversal in $<1\text{ms}$.
    - Deploy Space-Partitioned GiST (`USING spgist`) Quadtrees for heavily clustered 2D spatial point datasets to eliminate bounding box overlaps and avoid multi-branch index descent penalties.
    ```sql
    -- 1. Extension Verification
    CREATE EXTENSION IF NOT EXISTS btree_gist;
    CREATE EXTENSION IF NOT EXISTS postgis;

    -- 2. Declarative Exclusion Constraint on Multi-Tenant Temporal Reservations
    CREATE TABLE IF NOT EXISTS vehicle_bookings (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      tenant_id UUID NOT NULL,
      vehicle_id UUID NOT NULL,
      booking_period TSTZRANGE NOT NULL,
      status VARCHAR(32) NOT NULL DEFAULT 'confirmed',
      created_at TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP(),
      CONSTRAINT chk_booking_period_half_open CHECK (
        NOT isempty(booking_period) AND
        lower_inc(booking_period) AND
        NOT upper_inc(booking_period)
      ),
      CONSTRAINT uq_vehicle_no_overlap EXCLUDE USING gist (
        tenant_id WITH =,
        vehicle_id WITH =,
        booking_period WITH &&
      ) WHERE (status <> 'cancelled')
    );

    -- 3. Native PostGIS Geography Fleet Tracking with GiST Indexing
    CREATE TABLE IF NOT EXISTS fleet_telemetry (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      tenant_id UUID NOT NULL,
      driver_id UUID NOT NULL,
      location GEOGRAPHY(Point, 4326) NOT NULL,
      recorded_at TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP()
    );

    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fleet_location_gist
      ON fleet_telemetry USING gist (location)
      WITH (fillfactor = 85);

    -- 4. Sub-Millisecond k-NN Distance Operator Proximity Search
    SELECT
      driver_id,
      ST_Distance(location, ST_SetSRID(ST_MakePoint(-73.9851, 40.7488), 4326)::geography) AS distance_meters
    FROM fleet_telemetry
    WHERE tenant_id = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID
      AND recorded_at >= NOW() - INTERVAL '5 minutes'
    ORDER BY location <-> ST_SetSRID(ST_MakePoint(-73.9851, 40.7488), 4326)::geography
    LIMIT 10;
    ```

- **PostgreSQL Foreign Data Wrappers (postgres_fdw), Cross-Database Federation & Remote Pushdown Optimization**:
  - ❌ **Anti-Pattern: Missing Remote Estimates, Default 100-Fetch Sizing, Non-Immutable WHERE Bypasses, and Stale Remote Transactions**:
    - Defining foreign servers without `OPTIONS (use_remote_estimate 'true', fetch_size '2000')`. PostgreSQL assumes an arbitrary 1,000-row dummy size, causing the query planner to choose disastrous nested loops over remote tables with millions of rows.
    - Querying foreign tables with non-immutable functions (`WHERE created_at >= NOW() - INTERVAL '7 days'`) or mismatched collations, preventing `postgres_fdw` from pushing the filter to the remote database and streaming 50,000,000 unneeded rows over the network into local memory.
    - Holding local transactions open across slow network or HTTP calls while querying foreign tables, causing remote connections to linger in `idle in transaction`, holding remote locks and pinning remote `$x_{\text{min}}$` autovacuum horizons.
    - Neglecting orphaned prepared transactions (`pg_prepared_xacts`) from distributed two-phase commits (2PC), which survive disconnects and permanently freeze database transaction ID horizons.
  - ✅ **Production Invariant**:
    - Configure foreign servers with calibrated `fetch_size = '2000'`, `use_remote_estimate = 'true'`, and bounded `keep_connections = 'on'`.
    - Verify with `EXPLAIN (VERBOSE)` that `Foreign Scan` shows the entire filter, aggregation, and limit inside `Remote SQL`.
    - Deploy background watchdogs querying `pg_prepared_xacts` to detect and roll back orphaned distributed commits older than 60 seconds.
    - Use dedicated, least-privilege user mappings (`CREATE USER MAPPING`) restricted strictly to required schemas, never mapping to remote superusers.
    ```sql
    -- 1. Foreign Server Definition with Pushdown & Batch Sizing Invariants
    CREATE EXTENSION IF NOT EXISTS postgres_fdw;

    CREATE SERVER IF NOT EXISTS order_analytics_server
      FOREIGN DATA WRAPPER postgres_fdw
      OPTIONS (
        host 'orders-db.internal',
        port '5432',
        dbname 'orders_prod',
        fetch_size '2000',
        use_remote_estimate 'true',
        keep_connections 'on'
      );

    -- 2. Granular Least-Privilege User Mapping
    CREATE USER MAPPING IF NOT EXISTS FOR app_user
      SERVER order_analytics_server
      OPTIONS (
        user 'analytics_federated_readonly',
        password 'secret_app_token_99'
      );

    -- 3. Pushdown-Friendly Foreign Table Projection
    CREATE FOREIGN TABLE IF NOT EXISTS foreign_orders (
      id UUID NOT NULL,
      tenant_id UUID NOT NULL,
      total_amount NUMERIC(12, 2) NOT NULL,
      created_at TIMESTAMPTZ NOT NULL
    )
    SERVER order_analytics_server
    OPTIONS (
      schema_name 'public',
      table_name 'orders',
      use_remote_estimate 'true',
      fetch_size '2000'
    );

    -- 4. Pushdown Verified Query: Remote SQL executes WHERE, GROUP BY, and LIMIT
    EXPLAIN (VERBOSE, BUFFERS)
    SELECT
      tenant_id,
      SUM(total_amount) AS total_revenue
    FROM foreign_orders
    WHERE created_at >= '2025-01-01 00:00:00+00'::TIMESTAMPTZ
      AND created_at < '2025-02-01 00:00:00+00'::TIMESTAMPTZ
    GROUP BY tenant_id
    ORDER BY total_revenue DESC
    LIMIT 10;
    ```

- **PostgreSQL Materialized Views, Concurrent Refresh (`REFRESH MATERIALIZED VIEW CONCURRENTLY`) & Zero-Bloat Shadow Swapping**:
  - ❌ **Anti-Pattern: Blocking ACCESS EXCLUSIVE Lock Refresh, Missing Unique Indexes, and Unbounded Multi-Worker Thundering Herds**:
    - Invoking `REFRESH MATERIALIZED VIEW mv_name` in application code without `CONCURRENTLY`, taking an `ACCESS EXCLUSIVE` lock that blocks all incoming user `SELECT` queries for minutes or hours, exhausting connection pools.
    - Attempting `REFRESH MATERIALIZED VIEW CONCURRENTLY` without a preexisting non-partial, non-nullable `UNIQUE INDEX`, causing immediate crashes with SQLSTATE 55000.
    - Creating materialized views with data inside migration transactions (`CREATE MATERIALIZED VIEW mv AS ...`), causing migrations to hang and lock tables for lengthy table scans.
    - Allowing parallel background workers or API handlers to simultaneously issue competing `REFRESH` queries without advisory locking, causing database CPU starvation and I/O thundering herds.
  - ✅ **Production Invariant**:
    - Always define materialized views `WITH NO DATA` during migrations and build unique indexes concurrently.
    - Always execute refreshes with `REFRESH MATERIALIZED VIEW CONCURRENTLY`.
    - Protect all refreshes with non-blocking session advisory locks (`pg_try_advisory_lock`) and bounded `statement_timeout`.
    - For large datasets ($N > 2 \times 10^6$ rows), utilize the **Shadow Table Swap (Blue-Green Rotation)** pattern to achieve sub-millisecond switchovers with zero MVCC dead-tuple churn.
    ```sql
    -- 1. Migration Step: Instant DDL with zero table scans
    CREATE MATERIALIZED VIEW IF NOT EXISTS mv_hourly_agent_metrics AS
    SELECT
      agent_id,
      DATE_TRUNC('hour', executed_at) AS metric_hour,
      COUNT(id) AS total_invocations,
      SUM(tokens_used) AS total_tokens,
      AVG(duration_ms) AS avg_duration_ms,
      NOW() AS refreshed_at
    FROM agent_executions
    WHERE status = 'completed'
    GROUP BY agent_id, DATE_TRUNC('hour', executed_at)
    WITH NO DATA;

    -- 2. Mandatory Unique Index: Required for CONCURRENT refresh
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_mv_hourly_agent_metrics_pk
      ON mv_hourly_agent_metrics (agent_id, metric_hour);

    -- 3. Non-Blocking Concurrent Refresh with Advisory Lock Fencing
    DO $$
    DECLARE
      v_locked BOOLEAN;
      v_lock_key CONSTANT BIGINT := 8847291039847291;
    BEGIN
      -- Acquire advisory lock without waiting
      v_locked := pg_try_advisory_lock(v_lock_key);
      IF NOT v_locked THEN
        RAISE NOTICE 'Refresh skipped: another worker is currently refreshing mv_hourly_agent_metrics';
        RETURN;
      END IF;

      BEGIN
        SET LOCAL statement_timeout = '600s'; -- 10 minute ceiling
        SET LOCAL lock_timeout = '2s';

        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_hourly_agent_metrics;
      EXCEPTION
        WHEN OTHERS THEN
          PERFORM pg_advisory_unlock(v_lock_key);
          RAISE;
      END;

      PERFORM pg_advisory_unlock(v_lock_key);
    END $$;
    ```

- **PostgreSQL Advisory Locks, 64-Bit Hash Namespaces & Connection Pooler Fencing (PgBouncer/pgpool)**:
  - ❌ **Anti-Pattern: Session-Mode Locks in Transaction Pools, 32-Bit Hash Collisions, and Blocking Connection Depletion**:
    - Invoking `SELECT pg_advisory_lock(...)` in environments using PgBouncer/pgpool in `transaction` mode, leaving session locks attached to physical server backends after the client returns the connection, causing phantom deadlocks on unrelated client transactions.
    - Passing raw integer IDs without namespace partitioning or using 32-bit hashes (`crc32`), causing collisions between unrelated business entities (e.g. `user_id = 42` blocking `order_id = 42`).
    - Using blocking `pg_advisory_lock` in web request handlers, holding connections open for seconds while waiting on third-party APIs and exhausting the database connection pool.
    - Acquiring multiple advisory locks in non-canonical order, triggering AB-BA deadlock exceptions (`40P01`).
  - ✅ **Production Invariant**:
    - Mandatory transaction-scoped locks (`pg_advisory_xact_lock` or `pg_try_advisory_xact_lock`), automatically released upon `COMMIT` or `ROLLBACK`.
    - Generate deterministic signed 64-bit bigint keys using `hashtextextended(namespace || ':' || tenant_id || ':' || entity_id, 0)`.
    - Canonical sorting of lock keys in ascending numerical order when acquiring $>1$ lock.
    - Active monitoring of `pg_locks WHERE locktype = 'advisory'` to identify blocking locks.

    ```sql
    -- 1. Deterministic 64-bit Advisory Key Generator
    CREATE OR REPLACE FUNCTION generate_advisory_key(
      p_namespace INT,
      p_tenant_id TEXT,
      p_resource_id TEXT
    ) RETURNS BIGINT AS $$
      SELECT hashtextextended(p_namespace::TEXT || ':' || COALESCE(p_tenant_id, 'global') || ':' || p_resource_id, 0);
    $$ LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

    -- 2. Non-Blocking Transaction-Scoped Application Mutex Pattern
    BEGIN;
      -- Fast-fail check with zero wait time:
      SELECT pg_try_advisory_xact_lock(generate_advisory_key(101, 'tenant_alpha', 'order_98721')) AS lock_acquired;

      -- If lock_acquired is FALSE: immediately ROLLBACK and return 409 Conflict to caller.
      -- If lock_acquired is TRUE: safely execute state mutation.

      UPDATE orders
      SET status = 'processing', updated_at = NOW()
      WHERE id = 'order_98721' AND tenant_id = 'tenant_alpha';

    COMMIT; -- PostgreSQL kernel automatically releases the advisory lock here!

    -- 3. Diagnostic Observability: Query active advisory locks
    SELECT
      l.pid,
      a.usename,
      a.client_addr,
      a.state,
      NOW() - a.query_start AS duration,
      l.mode,
      l.granted,
      CASE WHEN l.objsubid = 1 THEN l.objid::BIGINT::TEXT ELSE '(' || l.classid || ',' || l.objid || ')' END AS lock_key,
      a.query
    FROM pg_locks l
    JOIN pg_stat_activity a ON l.pid = a.pid
    WHERE l.locktype = 'advisory'
    ORDER BY a.query_start ASC;
    ```

- **Database Transaction Isolation Levels, Serializable Snapshot Isolation (SSI) & SIREAD Predicate Locks**:
  - ❌ **Anti-Pattern: Implicit Read Committed Skew, Repeatable Read Write Skew, and Unhandled 40001 Crashes**:
    - Relying on default `READ COMMITTED` isolation across multi-query business workflows, allowing concurrent commits to change balances or inventory between statements within the same transaction (Read Skew).
    - Believing `REPEATABLE READ` prevents all race conditions, only for concurrent transactions updating disjoint rows (such as the classic Doctor-on-Call or dual-balance overdraft) to both commit cleanly and violate cross-row invariants (Write Skew).
    - Running transactions in `SERIALIZABLE` without an automated idempotent retry loop, crashing user workflows on expected `SQLSTATE 40001 serialization_failure` errors.
    - Executing unindexed queries under SSI, silently escalating SIREAD locks to the table level (`locktype = 'relation'`) and aborting concurrent writers across the entire database.
    - Running large analytical/reporting queries in standard SSI, holding SIREAD locks that cause concurrent OLTP transactions to abort.
  - ✅ **Production Invariant**:
    - Explicit isolation level declaration (`BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE`).
    - Enforce cross-row constraints via SSI with automated retry or declarative PostgreSQL exclusion constraints (`EXCLUDE USING gist`).
    - Mandatory idempotent retry wrapper catching `SQLSTATE 40001` and `40P01` with decorrelated jitter backoff.
    - Analytical snapshots declare `BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE`, guaranteeing zero aborts and zero SIREAD locks.
    - Continuous monitoring of SIREAD predicate locks via `pg_locks WHERE mode = 'SIReadLock'`.

    ```sql
    -- 1. Declarative Cross-Row Constraint Defense: Exclusion Constraints
    -- Prevents double-booking / write skew without transaction-level retry overhead
    CREATE TABLE room_reservations (
      reservation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      room_id UUID NOT NULL,
      booking_period TSTZRANGE NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      EXCLUDE USING gist (room_id WITH =, booking_period WITH &&)
    );

    -- 2. Zero-Conflict Analytical Snapshots with SERIALIZABLE READ ONLY DEFERRABLE
    -- Waits once until a clean snapshot is available, then runs with ZERO abort risk!
    BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE;
      SELECT
        DATE_TRUNC('day', created_at) AS day,
        COUNT(*) AS total_reservations,
        SUM(amount) AS total_revenue
      FROM orders
      GROUP BY 1
      ORDER BY 1 DESC;
    COMMIT;

    -- 3. Diagnostic Query: Monitor SIREAD Predicate Locks & Lock Escalation
    -- Watch for relation-level locks which indicate unindexed range scans in SSI
    SELECT
      l.locktype,
      c.relname AS relation_name,
      l.page,
      l.tuple,
      l.pid,
      NOW() - a.query_start AS duration,
      a.query
    FROM pg_locks l
    LEFT JOIN pg_class c ON l.relation = c.oid
    JOIN pg_stat_activity a ON l.pid = a.pid
    WHERE l.mode = 'SIReadLock'
    ORDER BY l.locktype DESC, duration DESC;
    ```

- **Database Primary Key Architecture, UUIDv7 / TSID vs UUIDv4, Monotonic Locality & B-Tree Page Split Defense**:
  - ❌ **Anti-Pattern: Random UUIDv4 Leaf Page Splits, Auto-Increment IDOR, and VARCHAR(36) Bloat**:
    - Declaring primary keys with `UUID DEFAULT gen_random_uuid()` (UUIDv4) in high-throughput write tables, scattering inserts uniformly across all B-tree leaf pages, triggering constant 50-50 leaf page splits, capping storage fillfactor at ~50-60%, generating massive Full-Page Write (FPW) WAL volume, and evicting active OLTP working sets from `shared_buffers`.
    - Using naive `BIGSERIAL` / `BIGINT GENERATED ALWAYS AS IDENTITY` on public-facing entities, leaking daily sales velocity and user counts to competitors and opening trivial Insecure Direct Object Reference (IDOR) enumeration attacks.
    - Storing UUIDs as `VARCHAR(36)` strings, consuming 36 bytes instead of native 16-byte binary types, multiplying foreign key index sizes by 2.25x and ruining CPU cache line alignment.
  - ✅ **Production Invariant**:
    - Mandate RFC 9562 UUIDv7 or TSID for all primary keys in write-heavy tables.
    - Exploit 48-bit Unix millisecond timestamps for 99%+ rightmost leaf page append locality (near zero page splits, same write throughput as BIGINT).
    - Store identifiers as native PostgreSQL `UUID` (16 bytes) or MySQL `BINARY(16)` / `BIGINT`.
    - Pre-generate IDs client-side before issuing database transactions for zero-round-trip horizontal scaling and built-in idempotency keys.
    - Continuous monitoring of B-tree index bloat and leaf page density via `pg_stat_user_indexes`.

    ```sql
    -- 1. RFC 9562 UUIDv7 Generator for PostgreSQL 14-16 (Native in PostgreSQL 17+)
    CREATE OR REPLACE FUNCTION generate_uuid_v7()
    RETURNS uuid
    AS $$
    DECLARE
      v_epoch_ms bigint;
    BEGIN
      v_epoch_ms := (extract(epoch from clock_timestamp()) * 1000)::bigint;
      RETURN (
        lpad(to_hex(v_epoch_ms), 12, '0') ||
        '7' ||
        substr(md5(random()::text), 1, 3) ||
        to_hex(8 + (random() * 3)::integer) ||
        substr(md5(random()::text), 2, 3) ||
        substr(md5(random()::text), 5, 12)
      )::uuid;
    END;
    $$ LANGUAGE plpgsql VOLATILE;

    -- 2. Production Table Schema with Monotonic UUIDv7 Primary Key
    CREATE TABLE customer_orders (
      order_id UUID PRIMARY KEY DEFAULT generate_uuid_v7(),
      tenant_id UUID NOT NULL,
      customer_id UUID NOT NULL,
      total_cents BIGINT NOT NULL CHECK (total_cents >= 0),
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    -- 3. Composite Index with Monotonic Locality
    CREATE INDEX idx_orders_tenant_created 
    ON customer_orders (tenant_id, order_id DESC);

    -- 4. Diagnostic Query: Primary Key B-Tree Index Health & Bloat
    SELECT
      relname AS table_name,
      indexrelname AS index_name,
      pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
      idx_scan,
      idx_tup_read,
      idx_tup_fetch
    FROM pg_stat_user_indexes
    WHERE indexrelname LIKE '%pkey%' OR indexrelname LIKE '%pk%'
    ORDER BY pg_relation_size(indexrelid) DESC;
    ```

- **Foreign Key Indexing Discipline, Zero-Downtime NOT VALID Constraints & Cascading Lock Defense**:
  - ❌ **Anti-Pattern: Unindexed Foreign Keys, Synchronous DDL Locks & Monolithic Cascading Deletes**:
    - Relying on PostgreSQL foreign keys without creating explicit supporting B-tree indexes on referencing columns, forcing parent `DELETE` or `UPDATE` statements to execute full sequential scans on child tables, holding row or relation locks and exhausting connection pools.
    - Adding foreign keys synchronously with `ALTER TABLE ADD CONSTRAINT ... FOREIGN KEY ...` without `NOT VALID`, freezing reads and writes across both parent and child tables for minutes during full-table validation scans.
    - Declaring unbounded `ON DELETE CASCADE` across deep entity hierarchies, deleting 100,000+ rows in a single monolithic transaction, blowing lock table limits, generating gigabytes of WAL, and causing replica lag spikes.
    - Using single-column foreign keys in multi-tenant tables, allowing records from Tenant A to reference parents belonging to Tenant B.
  - ✅ **Production Invariant**:
    - Mandate B-tree indexes on 100% of foreign key columns (leftmost prefix).
    - Add constraints using the two-phase `NOT VALID` + `VALIDATE CONSTRAINT` pattern for zero read/write blocking.
    - Replace deep `ON DELETE CASCADE` with batched keyset cascade deletion workers (`LIMIT 1000`) throttled on replica lag ($\tau_{\text{lag}} < 1.0\text{s}$).
    - Enforce composite multi-tenant foreign keys `(tenant_id, parent_id) REFERENCES parent(tenant_id, id)`.

    ```sql
    -- 1. Two-Phase Zero-Downtime Foreign Key Creation
    -- Step A: Create supporting index concurrently (no lock on writes)
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_order_items_order_id
    ON order_items (tenant_id, order_id);

    -- Step B: Attach constraint as NOT VALID (instant catalog metadata lock)
    ALTER TABLE order_items
    ADD CONSTRAINT fk_order_items_order
    FOREIGN KEY (tenant_id, order_id)
    REFERENCES orders (tenant_id, id)
    ON DELETE RESTRICT
    NOT VALID;

    -- Step C: Validate constraint asynchronously (takes non-blocking SHARE UPDATE EXCLUSIVE)
    ALTER TABLE order_items
    VALIDATE CONSTRAINT fk_order_items_order;

    -- 2. Keyset Chunked Cascade Deletion Pattern (Zero Connection Starvation)
    WITH doomed_batch AS (
      SELECT id
      FROM order_items
      WHERE order_id = :target_order_id
      ORDER BY id ASC
      LIMIT 1000
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM order_items
    WHERE id IN (SELECT id FROM doomed_batch);

    -- 3. Introspect Unindexed Foreign Keys in PostgreSQL
    SELECT
      c.conrelid::regclass AS child_table,
      c.conname AS constraint_name,
      ARRAY_TO_STRING(ARRAY_AGG(att.attname ORDER BY u.attposition), ', ') AS fk_columns,
      c.confrelid::regclass AS parent_table
    FROM pg_constraint c
    JOIN LATERAL UNNEST(c.conkey) WITH ORDINALITY AS u(attnum, attposition) ON true
    JOIN pg_attribute att ON att.attrelid = c.conrelid AND att.attnum = u.attnum
    WHERE c.contype = 'f'
      AND NOT EXISTS (
        SELECT 1
        FROM pg_index i
        WHERE i.indrelid = c.conrelid
          AND i.indisvalid = true
          AND (i.indkey[0:array_length(c.conkey, 1) - 1] = c.conkey)
      )
    GROUP BY c.conrelid, c.conname, c.confrelid;
    ```

  - ❌ **Anti-Pattern: Synchronous CHECK Constraints, 3VL NULL Bypass & Native ENUM Lock-In**:
    - Adding CHECK constraints synchronously on large tables (`ALTER TABLE ... ADD CONSTRAINT ... CHECK (...)`) without `NOT VALID`, freezing reads and writes under `ACCESS EXCLUSIVE` during full-table sequential scans.
    - Misunderstanding SQL three-valued logic (3VL), where `CHECK (col <= 100)` or `CHECK (col != 'banned')` evaluates to `UNKNOWN` when `col` is `NULL`, silently bypassing the constraint.
    - Declaring PostgreSQL native enums (`CREATE TYPE status AS ENUM (...)`) that cannot be modified inside multi-statement transactions, cannot have values removed or reordered, and lock tables during schema evolution.
    - Storing mutually exclusive polymorphic relationships (e.g. `user_id` vs `org_id`) without database-level `num_nonnulls` constraints, leading to dirty state drift.
  - ✅ **Production Invariant**:
    - Add all CHECK constraints via two-phase `NOT VALID` + `VALIDATE CONSTRAINT` (`SHARE UPDATE EXCLUSIVE` non-blocking scan).
    - Always pair CHECK constraints on nullable columns with explicit `IS NULL OR` or column-level `NOT NULL`.
    - Use Lookup/Reference tables or validated `VARCHAR(32)` CHECK constraints over native DB enums.
    - Enforce mutually exclusive relationships with `CHECK (num_nonnulls(col1, col2, ...) = 1)`.

    ```sql
    -- 1. Two-Phase Zero-Downtime CHECK Constraint Protocol
    ALTER TABLE transactions
    ADD CONSTRAINT check_positive_amount
    CHECK (amount_cents > 0)
    NOT VALID;

    ALTER TABLE transactions
    VALIDATE CONSTRAINT check_positive_amount;

    -- 2. Mutually Exclusive Polymorphic Owner Invariant
    ALTER TABLE accounts
    ADD CONSTRAINT check_single_owner
    CHECK (num_nonnulls(user_id, organization_id) = 1)
    NOT VALID;

    ALTER TABLE accounts
    VALIDATE CONSTRAINT check_single_owner;

    -- 3. Reusable PostgreSQL Domain Types
    CREATE DOMAIN positive_cents AS BIGINT
    CHECK (VALUE >= 0);

    CREATE DOMAIN email_address AS VARCHAR(255)
    CHECK (VALUE ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$');
    ```

  - ❌ **Anti-Pattern: 32-Bit SERIAL/INT4 Integer Overflow, Synchronous Type Conversion & Sequence Lock Contention**:
    - Declaring surrogate primary keys or auto-incrementing transactional event tables with 32-bit `SERIAL` or `INTEGER GENERATED ALWAYS AS IDENTITY`, risking catastrophic system-wide write stoppage at $2,147,483,647$ rows (`SQLSTATE 22003 numeric_value_out_of_range`).
    - Attempting to fix integer exhaustion via naive synchronous `ALTER TABLE t ALTER COLUMN id TYPE bigint;`, holding `ACCESS EXCLUSIVE` table lock for hours during a full-table physical heap rewrite and connection pool collapse.
    - Keeping default `CACHE 1` on sequences in high-velocity insert tables, generating synchronous WAL records and buffer `LWLock` latch contention on every single row.
    - Using auto-increment database sequences for statutory gapless financial audit trails (invoices, tax receipts) where transaction aborts/rollbacks create unrecoverable sequence number gaps.
  - ✅ **Production Invariant**:
    - Declare all auto-increment surrogate keys as 64-bit `BIGINT GENERATED ALWAYS AS IDENTITY` with explicit `NO CYCLE`.
    - Modernize legacy `int4` columns to `BIGINT` via the 4-phase zero-downtime expand-contract protocol (shadow column $\to$ dual-write trigger $\to$ bounded batch backfill $\to$ concurrent index build $\to$ atomic column swap under `lock_timeout = '2s'`).
    - Configure sequence `CACHE 50` or `100` on high-throughput write workloads to eliminate sequence buffer contention and slash WAL generation by up to $98\%$.
    - Isolate gapless accounting sequences into dedicated pessimistic row-lock counters (`SELECT counter FROM invoice_series WHERE series = $1 FOR UPDATE`).

    ```sql
    -- 1. Modern SQL:2003 Identity Primary Key with High-Concurrency Cache
    CREATE TABLE transaction_records (
      id BIGINT GENERATED ALWAYS AS IDENTITY (CACHE 50 NO CYCLE) PRIMARY KEY,
      tenant_id UUID NOT NULL,
      amount_cents BIGINT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
    );

    -- 2. Tune Existing Sequence for High-Throughput Inserts
    ALTER SEQUENCE orders_id_seq CACHE 100;

    -- 3. Proactive Sequence Exhaustion Audit Query
    SELECT
      ns.nspname AS schema_name,
      tbl.relname AS table_name,
      att.attname AS column_name,
      typ.typname AS data_type,
      s.sequencename,
      s.last_value,
      s.max_value,
      ROUND((s.last_value::numeric / s.max_value::numeric) * 100, 2) AS percent_consumed
    FROM pg_sequences s
    JOIN pg_class seq ON seq.relname = s.sequencename
    JOIN pg_namespace seq_ns ON seq.relnamespace = seq_ns.oid AND seq_ns.nspname = s.schemaname
    JOIN pg_depend dep ON dep.objid = seq.oid AND dep.deptype IN ('a', 'i')
    JOIN pg_class tbl ON dep.refobjid = tbl.oid
    JOIN pg_namespace ns ON tbl.relnamespace = ns.oid
    JOIN pg_attribute att ON att.attrelid = tbl.oid AND att.attnum = dep.refobjsubid
    JOIN pg_type typ ON att.atttypid = typ.oid
    WHERE s.last_value::numeric / s.max_value::numeric >= 0.75
    ORDER BY percent_consumed DESC;
    ```

  - ❌ **Anti-Pattern: Check-Then-Insert Race, ANSI NULL Duplicate Leaks & Unguarded Upsert MVCC Bloat**:
    - Relying on application-level `SELECT ... IF NOT EXISTS INSERT ...`, causing duplicate key collision crashes (`SQLSTATE 23505`) under concurrent traffic.
    - Creating composite unique constraints on nullable columns without `NULLS NOT DISTINCT`, allowing infinite duplicate rows with `NULL` under ANSI SQL-92 semantics.
    - Adding monolithic table-level `UNIQUE(email)` on tables using soft deletes (`deleted_at`), permanently locking out soft-deleted users from re-registering.
    - Executing unconditional `ON CONFLICT DO UPDATE SET col = EXCLUDED.col, updated_at = NOW()`, causing continuous MVCC dead-tuple churn and breaking Heap-Only Tuple (HOT) updates even when data values did not change.
  - ✅ **Production Invariant**:
    - Replace check-then-insert with atomic `INSERT ... ON CONFLICT (key) DO UPDATE / DO NOTHING`.
    - Declare `UNIQUE NULLS NOT DISTINCT` on PostgreSQL 15+ composite nullable unique columns.
    - For tables with soft deletes, enforce partial B-tree unique indexes: `CREATE UNIQUE INDEX ... WHERE deleted_at IS NULL`.
    - Guard upsert updates with `WHERE target IS DISTINCT FROM EXCLUDED.target` to preserve HOT updates and slash dead tuple generation by up to $90\%$.
    - Add new unique constraints via two-phase concurrent migration (`CREATE UNIQUE INDEX CONCURRENTLY` followed by `ALTER TABLE ... ADD CONSTRAINT ... USING INDEX`).

    ```sql
    -- 1. Partial Unique Expression Index for Soft-Deleted Multi-Tenant Table
    CREATE UNIQUE INDEX CONCURRENTLY idx_users_active_tenant_lower_email
    ON users (tenant_id, LOWER(TRIM(email)))
    WHERE deleted_at IS NULL;

    -- 2. Guarded Atomic UPSERT with HOT Update Preservation
    INSERT INTO user_profiles (user_id, display_name, avatar_url, updated_at)
    VALUES ($1, $2, $3, clock_timestamp())
    ON CONFLICT (user_id)
    DO UPDATE SET
      display_name = EXCLUDED.display_name,
      avatar_url = EXCLUDED.avatar_url,
      updated_at = clock_timestamp()
    WHERE (user_profiles.display_name, user_profiles.avatar_url)
      IS DISTINCT FROM (EXCLUDED.display_name, EXCLUDED.avatar_url)
    RETURNING *;
    ```

  - ❌ **Anti-Pattern: Subtransactions, Savepoint-in-Loop & `pg_subtrans` SLRU Meltdown**:
    - Issuing `SAVEPOINT` (or ORM `begin_nested()` / `SavePoint()`) inside batch loops to catch errors per row, causing PostgreSQL's per-backend 64-subxid cache (`PGPROC.subxids`) to overflow.
    - Writing PL/pgSQL stored procedures with `BEGIN ... EXCEPTION WHEN ... END` inside `LOOP ... END LOOP`, silently creating thousands of internal subtransactions.
    - Triggering cluster-wide `SubtransSLRULock` contention where all concurrent backends checking row visibility must queue for single-lock disk reads, causing throughput to collapse by 99% and connection pools to exhaust.
  - ✅ **Production Invariant**:
    - Eradicate savepoints in loops; enforce declarative single-statement atomic DML (`INSERT ... ON CONFLICT`, `MERGE`).
    - Ban PL/pgSQL `EXCEPTION` blocks inside loops; refactor to set-based operations or `IF NOT EXISTS` conditions.
    - Partition large batch ingestions into discrete top-level transactions of $\le 500$ rows with explicit `SET LOCAL lock_timeout = '2000ms'`.
    - Monitor `pg_stat_activity` for `wait_event = 'SubtransSLRU'` and alert when backends hold $> 64$ transaction locks.

    ```sql
    -- 1. Continuous Watchdog for SubtransSLRU Lock Contention
    SELECT
      pid,
      usename,
      wait_event,
      wait_event_type,
      state,
      clock_timestamp() - state_change AS duration,
      query
    FROM pg_stat_activity
    WHERE wait_event IN ('SubtransSLRU', 'SubtransBuffer');

    -- 2. Declarative Zero-Savepoint Set Insertion (Replaces Procedural Exception Loops)
    INSERT INTO inventory_ledger (item_id, delta_qty, logged_at)
    SELECT
      (item->>'id')::UUID,
      (item->>'qty')::BIGINT,
      clock_timestamp()
    FROM jsonb_array_elements($1::jsonb) AS item
    ON CONFLICT (item_id)
    DO UPDATE SET
      delta_qty = inventory_ledger.delta_qty + EXCLUDED.delta_qty,
      logged_at = clock_timestamp();
    ```

  - ❌ **Anti-Pattern: Column Ordering Randomness & 8-Byte Word Padding Bloat (Missing Column Tetris)**:
    - Declaring columns semantically or alphabetically (e.g., interleaving `boolean` or `smallint` between `bigint` or `timestamptz`), forcing PostgreSQL to inject 2 to 7 dead zero-padding bytes between attributes to satisfy CPU 8-byte word alignment (`MAXALIGN = 8`).
    - Placing variable-length columns (`text`, `varchar`, `jsonb`) before fixed 8-byte types, destroying compile-time static byte offsets and degrading CPU cache line locality.
    - Appending columns via `ALTER TABLE ADD COLUMN` over time, permanently locking in physical heap fragmentation in `pg_attribute`.
  - ✅ **Production Invariant**:
    - Enforce Column Tetris layout in all table DDL: sort columns strictly in descending alignment order:
      1. Fixed 8-Byte Types (`bigint`, `timestamptz`, `timestamp`, `double precision`)
      2. Fixed 4-Byte Types (`integer`, `date`, `real`, `oid`)
      3. Fixed 2-Byte Types (`smallint`)
      4. Fixed 1-Byte Types (`boolean`, `char(1)`)
      5. Variable-Length Varlena Tail (`uuid`, `text`, `varchar`, `jsonb`, `bytea`, `numeric`)
    - Guarantees internal padding $P_i = 0$ for all fixed-width attributes, increasing 8KB page packing density by 20% to 35% and saving gigabytes of `shared_buffers` cache.
    - Use the following PostgreSQL catalog query to audit physical padding waste across existing tables:

    ```sql
    -- Continuous Audit for Table Padding Bloat & Column Tetris Alignment
    SELECT
      a.attname AS column_name,
      t.typname AS data_type,
      t.typalign AS alignment,
      t.typlen AS fixed_size,
      CASE t.typalign
        WHEN 'd' THEN '8 bytes (double/bigint)'
        WHEN 'i' THEN '4 bytes (integer/date)'
        WHEN 's' THEN '2 bytes (smallint)'
        WHEN 'c' THEN '1 byte (char/bool)'
        ELSE 'variable'
      END AS alignment_desc
    FROM pg_attribute a
    JOIN pg_type t ON a.atttypid = t.oid
    WHERE a.attrelid = 'user_audit_events'::regclass
      AND a.attnum > 0
      AND NOT a.attisdropped
    ORDER BY a.attnum ASC;
    ```

- **Prepared Statements, Plan Cache Invalidation, Parameter Sniffing & Generic Plan Drift Defense**:
  - ❌ **Anti-Pattern: The 5-Execution Generic Plan Flip & Parameter Sniffing Collapse**:
    - Relying on default `plan_cache_mode = auto` for queries filtering on skewed data distributions (e.g. status columns where 99.9% of rows are 'COMPLETED' and 0.01% are 'FAILED'). On the 6th execution, PostgreSQL evaluates a generic plan with `$1` placeholder, assumes average selectivity, and permanently binds to a Sequential Scan for the lifetime of that connection.
    - Dynamically constructing `WHERE id IN ($1, $2, ... $N)` clauses with variable parameter counts, spawning thousands of unique prepared statement handles in `pg_prepared_statements` and leaking backend memory until OOM.
    - Zero-downtime DDL migrations triggering unhandled SQLSTATE `0A000` / `XX000` (`cached plan must not change result type`) across long-lived connection pools, causing microservices to crash until restarted.
  - ✅ **Production Invariant**:
    - Mandate static array parameterization `WHERE id = ANY($1::UUID[])` instead of dynamic `IN (...)`, preserving a single static statement handle regardless of array length.
    - Set `SET LOCAL plan_cache_mode = 'force_custom';` inside transactions that execute queries on highly skewed or multi-tenant predicates to guarantee parameter-specific index scans.
    - In PgBouncer transaction pooling mode, strictly use unnamed prepared statements or verify PgBouncer 1.21+ `max_prepared_statements >= 100` with `server_reset_query = DISCARD ALL`.
    - Implement automatic transparent retry on SQLSTATE `0A000` / `XX000` by issuing `DISCARD PLANS` before retrying the query once.
    - Run PostgreSQL 16+ `EXPLAIN (GENERIC_PLAN, BUFFERS)` in CI performance regression pipelines to verify that the generic plan cost does not exceed $2.0\times$ the custom plan:

    ```sql
    -- 1. PostgreSQL 16+ CI Gate for Prepared Statement Generic Plan Verification
    EXPLAIN (GENERIC_PLAN, BUFFERS)
    SELECT id, tenant_id, status, created_at
    FROM customer_orders
    WHERE tenant_id = $1
      AND status = $2
      AND id = ANY($3::UUID[]);

    -- 2. Transaction-Scoped Plan Cache Mode Override for Skewed Predicates
    BEGIN;
    SET LOCAL plan_cache_mode = 'force_custom';
    SELECT id, tenant_id, status, created_at
    FROM customer_orders
    WHERE status = 'FAILED'
      AND created_at >= NOW() - INTERVAL '1 hour';
    COMMIT;
    ```

- **Row-Level Locking Modes, FOR NO KEY UPDATE vs FOR UPDATE & MultiXact Contention Defense**:
  - ❌ **Anti-Pattern: The Parent FOR UPDATE vs Child Foreign Key KEY SHARE Starvation**:
    - Defaulting to `SELECT ... FOR UPDATE` when locking a parent row (e.g. updating account balance, user status, or timestamps). In PostgreSQL, every child table `INSERT` or `UPDATE` takes an implicit `FOR KEY SHARE` (`LockTupleKeyShare`) lock on the referenced parent tuple to verify referential integrity. Because `FOR UPDATE` (`LockTupleExclusive`) conflicts with `FOR KEY SHARE`, ALL concurrent child insertions across the entire cluster are blocked waiting on the parent lock, collapsing throughput from 30,000 TPS to <100 TPS and starving connection pools.
    - Acquiring `FOR SHARE` or `FOR KEY SHARE` prior to an `UPDATE` in the same transaction. When two concurrent transactions read with `FOR SHARE` and then attempt to mutate the row, both attempt lock upgrades, creating a deterministic circular wait-for deadlock (`ERROR: 40P01: deadlock detected`).
    - Unmonitored hot-parent insertions spawning millions of `MultiXactId` members in `pg_multixact`, triggering heavy SLRU lock contention and driving `age(datminmxid)` toward `autovacuum_multixact_freeze_max_age`, causing emergency cluster-wide autovacuum freeze storms.
  - ✅ **Production Invariant**:
    - For all mutations that do NOT modify primary keys or unique index columns, MANDATE `SELECT ... FOR NO KEY UPDATE` (or Drizzle `.for('no key update')` / SQLAlchemy `with_for_update(mode='no_key_update')`). `LockTupleNoKeyExclusive` is 100% compatible with `LockTupleKeyShare`, allowing concurrent child foreign key validation inserts to proceed with 0ms lock wait.
    - Eliminate shared-to-exclusive lock upgrades: If a transaction has any probability of mutating the row, acquire `FOR NO KEY UPDATE` or `FOR UPDATE` immediately on initial read.
    - Wrap all row locks with sub-second timeout ladders: `SET LOCAL lock_timeout = '2000ms'`.
    - For interactive user mutations, use `NOWAIT` to fail-fast on SQLSTATE `55P03` (`lock_not_available`) and map to HTTP 409 Conflict.
    - Run continuous audit queries to track `age(datminmxid)` and tuple lock contention:

    ```sql
    -- 1. Precision Row Locking: FOR NO KEY UPDATE (Allows concurrent child FK inserts)
    BEGIN;
    SET LOCAL lock_timeout = '2000ms';
    SELECT id, balance_cents, version
    FROM accounts
    WHERE id = $1
    FOR NO KEY UPDATE NOWAIT;

    UPDATE accounts
    SET balance_cents = balance_cents - $2,
        version = version + 1,
        updated_at = NOW()
    WHERE id = $1;
    COMMIT;

    -- 2. Audit MultiXact Wraparound Headroom
    SELECT
      datname,
      datminmxid,
      age(datminmxid) AS multixact_age,
      2147483648 - age(datminmxid) AS mxid_headroom_remaining
    FROM pg_database
    WHERE datname = current_database();
    ```

- **Covering Indexes (INCLUDE Clause), Index-Only Scans & Visibility Map Defense**:
  - ❌ **Anti-Pattern: The Index-Only Scan Heap Fetch Degeneration & Payload Bloat**:
    - Adding projection columns into B-Tree index keys (`CREATE INDEX ON orders (user_id, status, total_amount)`), which duplicates wide non-filter attributes across every internal routing node, collapsing B-Tree fan-out $B$ by 70%, inflating index depth, and evicting the OLTP working set from `shared_buffers`.
    - Relying on `INCLUDE (...)` on write-heavy tables with default autovacuum. When `PD_ALL_VISIBLE` bits in the Visibility Map are cleared by updates, PostgreSQL is forced to fetch the physical heap block for every single index entry (`Heap Fetches: 300,000`), converting index-only scans into random I/O storms.
    - Appending projection columns directly to `CREATE UNIQUE INDEX`, inadvertently corrupting domain uniqueness by enforcing uniqueness across the entire composite tuple rather than the business key.
    - Placing frequently updated attributes (e.g. `updated_at`, `view_count`) inside `INCLUDE (...)`, permanently disabling Heap-Only Tuple (HOT) optimizations and triggering massive index bloat on every update.
  - ✅ **Production Invariant**:
    - Strictly separate search keys from projection payloads: Index keys contain ONLY filtered (`WHERE`), joined (`ON`), and sorted (`ORDER BY`) columns; non-key projection attributes reside strictly in `INCLUDE (...)`.
    - For unique lookups, use `CREATE UNIQUE INDEX ... (business_keys) INCLUDE (payload_columns)`.
    - Never include high-churn mutable columns in `INCLUDE`; restrict payloads to immutable or low-churn fields to preserve HOT update rates.
    - Tune autovacuum on high-read tables relying on Index-Only Scans (`autovacuum_vacuum_scale_factor = 0.05`, `autovacuum_vacuum_insert_scale_factor = 0.02`) to keep the Visibility Map warm.
    - Build covering indexes concurrently outside transaction blocks: `CREATE INDEX CONCURRENTLY ... INCLUDE (...) WITH (fillfactor = 90)`.

    ```sql
    -- 1. Optimal Covering Index with leaf-only payload and HOT preservation
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_users_tenant_email_cov
    ON users (tenant_id, email)
    INCLUDE (id, role, status, created_at)
    WITH (fillfactor = 90);

    -- 2. Audit Visibility Map Coverage & Index-Only Scan Heap Fetch Ratio
    SELECT
      c.relname AS table_name,
      i.relname AS index_name,
      stat.idx_scan,
      stat.idx_tup_fetch AS heap_fetches,
      CASE
        WHEN stat.idx_scan = 0 THEN 0.0
        ELSE ROUND((stat.idx_tup_fetch::numeric / stat.idx_scan::numeric), 2)
      END AS avg_heap_fetches_per_scan
    FROM pg_class c
    JOIN pg_index idx ON c.oid = idx.indrelid
    JOIN pg_class i ON i.oid = idx.indexrelid
    JOIN pg_statio_user_indexes stat ON stat.indexrelid = idx.indexrelid
    WHERE c.relname = 'users';
    ```

- **Partial Indexes, Filtered Predicates, NULL Compaction & Soft-Delete Uniqueness Defense**:
  - ❌ **Anti-Pattern: Monolithic Asymmetric Queue Indexing & Parameterized Non-Match Trap**:
    - Creating standard indexes across 200M rows where 99% are completed or historical tombstones (`CREATE INDEX ON tasks (tenant_id, status, created_at)`), wasting 25 GB of buffer RAM on dormant records.
    - Parameterizing the partial predicate in prepared statements (`WHERE tenant_id = $1 AND status = $2`), preventing the PostgreSQL planner from proving predicate implication in generic plans and forcing 45-second sequential scans.
    - Applying unconditional unique constraints to soft-delete tables (`UNIQUE (tenant_id, email)`), permanently locking soft-deleted users out of re-registration with SQLSTATE `23505`.
    - Full indexing of sparse optional attributes where 90%+ of values are NULL (`CREATE INDEX ON orders (dispute_id)`), polluting B-Tree leaves with millions of useless NULL pointers.
  - ✅ **Production Invariant**:
    - Build partial indexes strictly covering the active working set (`WHERE status IN ('PENDING', 'QUEUED')`) with `fillfactor = 85` to accommodate queue turnover.
    - Enforce business uniqueness on soft-delete models via partial unique indexes: `CREATE UNIQUE INDEX ... (tenant_id, lower(email)) WHERE deleted_at IS NULL`.
    - Statically hardcode the matching literal condition in SQL (`WHERE tenant_id = $1 AND status = 'PENDING'`) so query planners match the partial index under both custom and generic execution plans.
    - Compact sparse foreign keys and error codes via `WHERE column IS NOT NULL`.
    - Tune autovacuum on high-churn partial queue tables (`autovacuum_vacuum_scale_factor = 0.05`).

    ```sql
    -- 1. Asymmetric Queue Partial Index with Fillfactor for High Churn
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tasks_pending_queue
    ON tasks (tenant_id, created_at)
    WHERE status IN ('PENDING', 'QUEUED')
    WITH (fillfactor = 85);

    -- 2. Soft-Delete Partial Unique Index
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS uq_users_active_email
    ON users (tenant_id, lower(email))
    WHERE deleted_at IS NULL;

    -- 3. Sparse NULL Compaction Index (Saves 99% storage on optional attributes)
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_unresolved_disputes
    ON orders (dispute_id, customer_id, created_at)
    WHERE dispute_id IS NOT NULL;

    -- 4. Audit Table Skew and Partial Index Candidates
    SELECT
      relname AS table_name,
      n_live_tup AS live_tuples,
      n_dead_tup AS dead_tuples,
      ROUND((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)::numeric) * 100, 2) AS dead_tuple_pct
    FROM pg_stat_user_tables
    WHERE relname IN ('tasks', 'users', 'orders');
    ```

- **Common Table Expressions (CTEs), Materialization Controls, Inlining Optimization Fences & Recursive Cycle Defense**:
  - ❌ **Anti-Pattern: Multiple-Reference Implicit Materialization & Unbounded Recursive Loop**:
    - Re-referencing a CTE without declaring `AS MATERIALIZED` or `AS NOT MATERIALIZED`: in PostgreSQL 12+, referencing a CTE $\ge 2$ times causes the planner to automatically materialize it into a temporary tuplestore, blowing out `work_mem`, spilling to disk, and stripping index scans from outer joins.
    - Filtering by `tenant_id` in the outer query while declaring `AS MATERIALIZED` inside the CTE: the optimization fence blocks predicate pushdown, forcing a full table scan across all tenants.
    - Inlining CTEs with volatile functions like `gen_random_uuid()` or `random()`, causing the function to re-evaluate for every outer row and breaking consistency.
    - Writing `WITH RECURSIVE` without cycle detection, causing cyclic graphs to trigger infinite loops, memory exhaustion, and OOM postmaster crashes.
  - ✅ **Production Invariant**:
    - Explicitly declare `AS NOT MATERIALIZED` when predicate pushdown and index scans must cross CTE boundaries.
    - Explicitly declare `AS MATERIALIZED` when isolating expensive calculations or volatile functions (`uuid`, `random`) that must evaluate strictly once.
    - On recursive queries, mandate PostgreSQL 14+ `CYCLE id SET is_cycle USING path` and a depth boundary `WHERE depth < :max_depth`.
    - On data-modifying CTEs (`WITH deleted AS (DELETE ...) INSERT INTO ...`), consume mutations strictly via `RETURNING` clauses; never query the modified table within the same statement expecting to see CTE mutations.

    ```sql
    -- 1. Explicit Inlining for Predicate Pushdown and Index Usage
    WITH customer_metrics AS NOT MATERIALIZED (
      SELECT 
        customer_id,
        count(id) AS total_orders,
        sum(total_amount) AS lifetime_spend
      FROM orders
      WHERE created_at >= NOW() - INTERVAL '90 days'
      GROUP BY customer_id
    )
    SELECT c.id, c.email, m.total_orders, m.lifetime_spend
    FROM customers c
    JOIN customer_metrics m ON m.customer_id = c.id
    WHERE c.tenant_id = 'tenant_123';

    -- 2. Cycle-Safe Recursive CTE with Depth Fence
    WITH RECURSIVE org_hierarchy AS (
      SELECT id, parent_id, name, 1 AS depth
      FROM departments
      WHERE tenant_id = 'tenant_123' AND parent_id IS NULL
      
      UNION ALL
      
      SELECT d.id, d.parent_id, d.name, h.depth + 1
      FROM departments d
      JOIN org_hierarchy h ON d.parent_id = h.id
      WHERE d.tenant_id = 'tenant_123'
        AND h.depth < 25 -- Depth fence
    )
    CYCLE id SET is_cycle USING path
    SELECT id, parent_id, name, depth, path
    FROM org_hierarchy
    WHERE NOT is_cycle;
    ```

- **Keyset Pagination, Seek Method, Row-Value Comparisons, Deferred Joins & Cursor Drift Defense**:
  - ❌ **Anti-Pattern: High-Offset Scans, Missing Tie-Breakers & Early Join Bloat**:
    - Writing `LIMIT 20 OFFSET 100000`: PostgreSQL/MySQL must traverse and visibility-check 100,000 tuples, evicting the buffer pool and causing latencies to jump from 2ms to 15s.
    - Sorting by non-unique columns (`ORDER BY created_at DESC`) without primary key tie-breaker: duplicate timestamps return arbitrary heap order, causing random page jitter and skipped/duplicated items.
    - Multi-column row-value comparisons `(created_at, id) < ($1, $2)` with mismatched index direction or nullability, causing the planner to abandon index seeks.
    - Joining multiple wide dimension tables before applying pagination bounds, forcing the engine to materialize wide tuples in memory before discarding 99.9% of them.
  - ✅ **Production Invariant**:
    - Mandate Keyset Seek Method `(sort_col, id) < (:last_val, :last_id)` for $O(1)$ constant-time page retrieval.
    - Always append primary key `id` as the deterministic terminal tie-breaker with explicit `NULLS LAST` / `NULLS FIRST`.
    - Align composite B-Tree indexes precisely with equality filters, sort column, and tie-breaker: `(tenant_id, created_at DESC, id DESC)`.
    - Implement Deferred Joins (Late Lookup) for wide queries: seek only primary keys via compact index scan in a CTE with `LIMIT K`, then join wide dimension tables on matched keys.
    - Over-fetch by 1 (`LIMIT K + 1`) to determine `has_more` without expensive `COUNT(*)` scans.

    ```sql
    -- 1. Deterministic Keyset Seek with Composite Leftmost Index Alignment
    -- Supporting index: CREATE INDEX idx_invoices_seek ON customer_invoices (tenant_id, issue_date DESC, id DESC);
    SELECT id, tenant_id, customer_id, amount_cents, status, issue_date
    FROM customer_invoices
    WHERE tenant_id = :tenant_id
      AND (
        (:cursor_issue_date::timestamptz IS NULL AND :cursor_id::uuid IS NULL)
        OR (issue_date, id) < (:cursor_issue_date, :cursor_id)
      )
    ORDER BY issue_date DESC NULLS LAST, id DESC
    LIMIT 21; -- Over-fetch by 1 to compute has_more

    -- 2. Deferred Join (Late Lookup) for Wide Multi-Table Projection
    WITH target_keys AS (
      SELECT id
      FROM orders
      WHERE tenant_id = :tenant_id
        AND (
          (:cursor_created_at::timestamptz IS NULL AND :cursor_id::uuid IS NULL)
          OR (created_at, id) < (:cursor_created_at, :cursor_id)
        )
      ORDER BY created_at DESC, id DESC
      LIMIT 21
    )
    SELECT 
      o.id, o.order_number, o.total_amount, o.created_at,
      c.name AS customer_name, c.email AS customer_email,
      a.city AS shipping_city
    FROM target_keys k
    JOIN orders o ON o.id = k.id
    JOIN customers c ON c.id = o.customer_id
    JOIN addresses a ON a.id = o.shipping_address_id
    ORDER BY o.created_at DESC, o.id DESC;
    ```

- **Window Functions, Frame Specifications (ROWS vs RANGE), Running Totals & Memory Defense**:
  - ❌ **Anti-Pattern: Implicit RANGE Frames, Correlated Triangular Subqueries & Non-Deterministic Ranks**:
    - Writing `SUM(amount) OVER (PARTITION BY acct ORDER BY created_at)` without frame: Defaults to `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. Engine buffers peer groups with identical timestamps in `work_mem` (spilling to disk tuplestore), and sums all tie rows together, producing corrupted stepped jumps in running balances.
    - Computing cumulative running totals via $O(N^2)$ correlated self-joins (`WHERE t2.created_at <= t1.created_at`), causing $10^{10}$ comparisons on 100k rows and hours of CPU starvation.
    - Placing window functions inside `WHERE` clauses (`WHERE ROW_NUMBER() OVER (...) = 1`), crashing with `SQLSTATE 42803` because SQL evaluates `WHERE` before `WINDOW`.
    - Using `ROW_NUMBER()` or `RANK()` without an immutable unique primary key tie-breaker, causing non-deterministic ordering and pagination drift across database runs.
  - ✅ **Production Invariant**:
    - Mandate explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` on all running aggregates to stream in $O(1)$ memory.
    - Append primary key `id` as the deterministic terminal tie-breaker: `ORDER BY created_at ASC, id ASC`.
    - Align composite B-Tree indexes precisely with partition and order keys: `CREATE INDEX ON table (partition_col, order_col ASC, id ASC) INCLUDE (val)` to eliminate `Sort` executor nodes and external merge disk spills.
    - Use PostgreSQL `DISTINCT ON (group_col)` for high-performance Top-1 retrieval without window sort overhead, or wrap Top-K in an index-aligned CTE.
    - Consolidate repeated window declarations into a named `WINDOW w AS (...)` clause, and use bounded frames `ROWS BETWEEN (K-1) PRECEDING AND CURRENT ROW` for rolling moving averages to activate engine sliding-window optimizations.

    ```sql
    -- 1. Streaming Financial Running Balance with Explicit ROWS Frame and Named Window
    -- Supporting index: CREATE INDEX idx_bank_stream ON bank_ledger (tenant_id, account_id, created_at ASC, id ASC) INCLUDE (amount_cents);
    SELECT 
        id, tenant_id, account_id, amount_cents, created_at,
        SUM(amount_cents) OVER w AS running_balance,
        ROW_NUMBER() OVER w AS transaction_seq
    FROM bank_ledger
    WHERE tenant_id = :tenant_id AND account_id = :account_id
    WINDOW w AS (
        PARTITION BY account_id
        ORDER BY created_at ASC, id ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )
    ORDER BY created_at ASC, id ASC;

    -- 2. Rolling 7-Day Moving Metric with Bounded Frame Ring Buffer & Top-K Rank via CTE
    WITH ranked_store_metrics AS (
        SELECT 
            store_id, recorded_date, daily_revenue_cents,
            AVG(daily_revenue_cents) OVER w_7d AS trailing_7d_avg,
            DENSE_RANK() OVER (
                PARTITION BY store_id 
                ORDER BY daily_revenue_cents DESC, id ASC
            ) AS revenue_rank
        FROM store_daily_metrics
        WHERE tenant_id = :tenant_id
        WINDOW w_7d AS (
            PARTITION BY store_id 
            ORDER BY recorded_date ASC, id ASC
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        )
    )
    SELECT store_id, recorded_date, daily_revenue_cents, trailing_7d_avg, revenue_rank
    FROM ranked_store_metrics
    WHERE revenue_rank <= 3
    ORDER BY store_id, revenue_rank ASC;
    ```

- **Bulk Ingestion, PostgreSQL COPY Protocol, UNLOGGED Staging & Parameter Limits**:
  - ❌ **Anti-Pattern: Single-Row INSERT Loops, Parameter Limit Crashes & Active Index Thrashing**:
    - Executing single-row `INSERT` inside loops, multiplying network latency by $10^5$, exhausting connection pool slots, and thrashing WAL fsync commits.
    - Emitting dynamic multi-row `INSERT INTO t VALUES ($1, ...)` without parameter bounds, crashing with `SQLSTATE 54000 / 08P01` when exceeding PostgreSQL's 65,535 parameter limit or SQLite's 999/32,766 limit.
    - Inserting millions of rows directly into tables with active secondary indexes and foreign keys, causing random B-tree page splits ($O(M \log N)$ random I/O) and 20x WAL write amplification.
    - Wrapping multi-hour batch loads in a monolithic transaction, pinning the cluster-wide $x_{\text{min}}$ horizon and triggering autovacuum table bloat across concurrent OLTP tables.
  - ✅ **Production Invariant**:
    - For small batches ($< 5,000$ rows), bound multi-row inserts to $B = \min(1000, \lfloor 65535 / C_{\text{cols}} \rfloor)$ to guarantee parameter safety.
    - For large datasets ($> 5,000$ rows), mandate the native streaming `COPY` protocol (`COPY table FROM STDIN WITH (FORMAT binary)`), streaming records with $O(1)$ memory residency.
    - Ingest ETL data into an `UNLOGGED` staging table with `SET LOCAL synchronous_commit = off`, perform an atomic set-based `INSERT INTO ... SELECT ... ON CONFLICT DO UPDATE`, and immediately `TRUNCATE` the staging relation.
    - For partition loads created in the same transaction, mandate `COPY ... FREEZE` to mark tuples as `FrozenTransactionId`, eliminating future emergency autovacuum freezing I/O debt.

    ```sql
    -- High-Throughput UNLOGGED Staging + Set-Based Atomic Merge Pattern
    CREATE UNLOGGED TABLE staging_sensor_metrics (
        device_id UUID NOT NULL,
        metric VARCHAR(64) NOT NULL,
        val DOUBLE PRECISION NOT NULL,
        recorded_at TIMESTAMPTZ NOT NULL
    );

    -- Streamed via native COPY protocol from application runner:
    -- COPY staging_sensor_metrics (device_id, metric, val, recorded_at) FROM STDIN WITH (FORMAT binary);

    -- Atomic set-based merge into target relation
    INSERT INTO sensor_metrics (device_id, metric, val, recorded_at)
    SELECT device_id, metric, val, recorded_at
    FROM staging_sensor_metrics
    ON CONFLICT (device_id, recorded_at, metric) DO UPDATE
    SET val = EXCLUDED.val;

    TRUNCATE TABLE staging_sensor_metrics;
    ```

- **LATERAL Joins, Per-Group Top-K Optimization & Correlated Subquery Consolidation**:
  - ❌ **Anti-Pattern: Full-Table Window Partition Scans & Scalar Subquery Proliferation**:
    - Using `ROW_NUMBER() OVER (PARTITION BY group_id ORDER BY created_at DESC)` in a CTE or subquery to fetch Top-$K$ items per category or user, forcing the database engine to sequence-scan and sort 50 million rows ($O(N \log N)$) and spill to disk temp files when only 3 rows per group are needed.
    - Proliferating multiple independent scalar subqueries `(SELECT count(*) FROM orders WHERE customer_id = c.id)`, `(SELECT max(total) FROM orders WHERE customer_id = c.id)` inside the `SELECT` projection, multiplying index seeks by $M \times N$ and thrashing `shared_buffers`.
    - Using `CROSS JOIN LATERAL` when parent entities may have zero matching children, causing newly registered users or empty categories to vanish silently from query results.
    - Omitting the composite index on the child table `(foreign_key, sort_column DESC)`, causing the query planner to execute a sequential scan of the child table for every outer row ($O(|R| \cdot |S|)$ nested loop disaster).
  - ✅ **Production Invariant**:
    - Mandate `CROSS JOIN LATERAL` or `LEFT JOIN LATERAL` with `ORDER BY child.sort_col DESC LIMIT K` paired with a composite B-Tree index on `(foreign_key, sort_col DESC)`. The executor performs a Nested Loop with Index Scan seeking directly to the $K$ tuples per parent, reducing computational complexity from $O(N \log N)$ to $O(G \cdot K \log N)$ and query latency by over $4,000\times$.
    - Mandate `LEFT JOIN LATERAL ... ON true` when parent rows must survive zero matching child rows.
    - Consolidate multiple correlated scalar subqueries into a single `LEFT JOIN LATERAL` computing all counts, sums, and latest child attributes in a single pass.
    - Use `CROSS JOIN LATERAL (VALUES (...)) AS calc(val)` to factor expensive mathematical formulas or JSON extractions once per row and reuse the alias across `WHERE`, `SELECT`, and `ORDER BY`.

    ```sql
    -- High-Performance Top-3 Items Per Category with Zero Full-Table Sort
    -- Prerequisite Index: CREATE INDEX idx_products_cat_sales ON products (category_id, sales_count DESC) WHERE is_active = true;
    SELECT
        c.id AS category_id,
        c.name AS category_name,
        top_p.id AS product_id,
        top_p.name AS product_name,
        top_p.sales_count
    FROM categories c
    LEFT JOIN LATERAL (
        SELECT p.id, p.name, p.sales_count
        FROM products p
        WHERE p.category_id = c.id AND p.is_active = true
        ORDER BY p.sales_count DESC
        LIMIT 3
    ) top_p ON true
    WHERE c.is_visible = true;
    ```

- **Hierarchical Trees, LTree Path Indexing, Closure Tables & Adjacency List Cycle Defense**:
  - ❌ **Anti-Pattern: Unbounded Recursive CTEs, Naive String LIKE Paths & Self-Parenting Relocation Outages**:
    - Writing `WITH RECURSIVE` queries without PostgreSQL 14+ `CYCLE` detection or depth limits, which spin into infinite loops and crash connections when cycles are introduced by concurrent unvalidated updates.
    - Fetching ancestor breadcrumbs via $N$ sequential application-level round-trips (`while (parentId) { SELECT ... }`), multiplying network latency and pool pressure.
    - Moving nodes via unguarded `UPDATE nodes SET parent_id = $new_parent WHERE id = $id` without verifying that `$new_parent` is not a descendant of `$id`, severing subtrees into disconnected circular islands.
    - Storing hierarchy paths as raw `VARCHAR` strings and querying subtrees via `WHERE path LIKE '/1/%'`, causing substring collision bugs (`/10/20` matching `/1/%`) and triggering full table scans.
    - Omitting the B-Tree index on `parent_id` in adjacency list schemas, causing every tree step to execute an $O(N)$ sequential scan.
  - ✅ **Production Invariant**:
    - For simple Adjacency Lists, mandate a composite B-Tree index on `(tenant_id, parent_id)`, enforce PostgreSQL 14+ `CYCLE id SET is_cycle USING path`, and cap depth with `WHERE depth <= 25`.
    - For deep read-heavy hierarchies or taxonomies, deploy PostgreSQL's native `ltree` extension with dual indexing: GiST index (`CREATE INDEX USING gist (path)`) for `<@` (is descendant) and `@>` (is ancestor) subtree queries, and B-Tree index for exact equality and sorting.
    - Sanitize all `ltree` labels against `^[A-Za-z0-9_]{1,256}$` before persistence.
    - Atomic Subtree Relocation: Execute node relocation inside an explicit transaction block, pre-checking that the destination parent is not within the source node's descendants (`targetPath <@ sourcePath = false`), acquiring row locks in deterministic UUID order, and rewriting descendants' paths via `ltree` subpath concatenation: `SET path = $new_prefix::ltree || subpath(path, nlevel($old_prefix::ltree))`.

- **Database Triggers, Stored Procedures, Function Volatility, Transition Tables & Parallel Safety**:
  - ❌ **Anti-Pattern: Default-VOLATILE Functions, Row-by-Row Audit Triggers, Unguarded Loops & Unpinned SECURITY DEFINER**:
    - Omitting volatility categories (`IMMUTABLE`, `STABLE`, `VOLATILE`) on pure helper functions, defaulting to `VOLATILE`, disabling index evaluation on expression indexes, and forcing query planners to mark plans `PARALLEL UNSAFE`.
    - Marking impure functions `IMMUTABLE` when they query database tables or clocks, leading to permanently stale cached plans and B-Tree index corruption.
    - Creating `AFTER INSERT OR UPDATE FOR EACH ROW` triggers for audit logging or rollups, which incur $N$ PL/pgSQL context switches, exhaust `max_locks_per_transaction`, and run $300\times$ slower on batch updates.
    - Omitting `WHEN (OLD.* IS DISTINCT FROM NEW.*)` conditional predicates on row update triggers, causing runaway self-cascading triggers and `stack depth limit exceeded` crashes.
    - Writing `SECURITY DEFINER` stored procedures without pinning `SET search_path = pg_catalog, pg_temp`, creating critical CWE-426 privilege escalation vulnerabilities.
    - Concatenating raw strings in PL/pgSQL dynamic SQL `EXECUTE`, enabling SQL injection and destroying generic query plan caching.
  - ✅ **Production Invariant**:
    - Mark all pure mathematical, string, and hashing functions `IMMUTABLE PARALLEL SAFE STRICT`. Mark table-reading helper functions `STABLE PARALLEL SAFE`.
    - Use PostgreSQL 10+ statement triggers with transition tables (`REFERENCING NEW TABLE AS new_rows OLD TABLE AS old_rows FOR EACH STATEMENT`) for batch audit logging and rollup calculations.
    - Always guard row-level update triggers with `WHEN (OLD.* IS DISTINCT FROM NEW.*)` and depth checks (`IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;`).
    - Pin `SET search_path = pg_catalog, pg_temp` on every `SECURITY DEFINER` routine and strictly enforce least-privilege `REVOKE ALL FROM PUBLIC`.
    - In dynamic SQL, always parameterize literals with `USING` and sanitize table/column identifiers with `format('%I', identifier)`.

- **Database Server-Side Cursors, Portal Fetching, Stream Chunking & Client Memory OOM Defense**:
  - ❌ **Anti-Pattern: Unbounded In-Memory Buffering, Snapshot xmin Pinning & Dangerous WITH HOLD**:
    - Eagerly loading millions of rows into application memory with `await db.select().from(table)` or unchunked driver queries, triggering process container OOM kills (`SIGKILL 137`).
    - Opening a server cursor inside a long-running transaction while slowly consuming records over hours, pinning the database transaction horizon ($x_{\text{min}}$) and freezing Autovacuum cluster-wide.
    - Declaring `CURSOR WITH HOLD` to bypass transaction duration limits, forcing PostgreSQL on `COMMIT` to eagerly copy all remaining unconsumed tuples into `pgsql_tmp` disk files, exhausting NVMe disk space and causing massive write I/O stalls.
    - Executing cursor queries across multiple roundtrips behind transaction-mode PgBouncer, causing subsequent `FETCH` statements to land on different backend server connections and crash with `ERROR: cursor "..." does not exist`.
    - Omitting `NO SCROLL`, forcing the planner to inject a `Materialize` node and tuplestore buffer to support backward scrolling, destroying streaming pipelining.
    - Leaving cursor portals open on error paths or early loop breaks without an explicit `CLOSE cursor_name`, leaking portal descriptors and table locks.
  - ✅ **Production Invariant**:
    - Mandate bounded stream processing (`pgx.Rows`, `pg-query-stream`, `asyncpg.Cursor`) with constant memory consumption $M = \mathcal{O}(B)$ where batch size $B \le 2000$.
    - Enforce strict transaction timeout ladders (`idle_in_transaction_session_timeout = '30s'`) on cursor transactions; for long-running batch jobs exceeding 5 minutes, transition to keyset seek pagination across sub-second independent transactions.
    - Always declare cursors with explicit `NO SCROLL`: `DECLARE cur NO SCROLL CURSOR FOR SELECT ...`.
    - Pin connection checkout for the entire cursor lifecycle: execute `BEGIN`, `DECLARE`, chunked `FETCH`, `CLOSE`, and `COMMIT` within a single dedicated connection checkout.
    - Guarantee portal cleanup with RAII patterns (`defer tx.Exec("CLOSE cur")` in Go, `finally { client.release() }` in TypeScript).

- **Database Collations, Unicode Normalization (NFC/NFD), ICU Locales, Case-Insensitive Search & B-Tree glibc Corruption Defense**:
  - ❌ **Anti-Pattern: glibc Collation Drift, Case-Sensitive Impersonation & Unindexed Functions**:
    - Relying on default host OS glibc collations (`libc`) across Linux upgrades without monitoring `pg_collation.collversion`, leading to silent B-Tree index corruption, broken binary search lookups, and duplicate unique keys.
    - Declaring unique constraints on emails or usernames under case-sensitive collations, allowing `admin@corp.com` and `Admin@Corp.com` to register concurrently (CWE-178).
    - Querying case-folded columns with unindexed `WHERE LOWER(email) = LOWER($1)`, turning logarithmic $\mathcal{O}(\log N)$ index seeks into $\mathcal{O}(N)$ sequential table scans.
    - Accepting raw Unicode strings without canonical normalization, allowing visually identical decomposed NFD strings (`café`) and precomposed NFC strings to bypass unique constraints and authorization checks.
    - Storing UUIDs, API keys, tokens, and hashes under natural language collations, wasting up to 45% of CPU time executing multi-weight `strcoll()` linguistic routines instead of hardware `memcmp()`.
    - Querying prefix wildcards `WHERE sku LIKE 'PROD-%'` under locale collations without `text_pattern_ops` or `COLLATE "C"`, disabling B-Tree index acceleration.
  - ✅ **Production Invariant**:
    - Force `COLLATE "C"` or `COLLATE "POSIX"` on all synthetic identifiers, UUIDs, tokens, and hashes for $3\times–8\times$ faster joins and index lookups.
    - Enforce Canonical Unicode Composition (NFC) at the boundary gateway and in schema check constraints: `CHECK (username = unicode_normalize_nfc(username))`.
    - For case-insensitive user identities, utilize PostgreSQL 12+ non-deterministic ICU collations (`provider = icu`, `locale = 'und-u-ks-level2'`, `deterministic = false`) or deterministic functional unique indexes `CREATE UNIQUE INDEX ON users (LOWER(email))`.
    - Always specify `text_pattern_ops` or `varchar_pattern_ops` when creating B-Tree indexes intended for wildcard prefix matching under locale collations.
    - Establish automated CI/CD and deployment sentinels to monitor `pg_collation.collversion` vs `pg_collation_actual_version(oid)` and run zero-downtime `REINDEX CONCURRENTLY` runbooks on OS upgrades.

- **Database Transaction ID (XID) Wraparound, Freeze Map & Autovacuum Horizon Starvation Defense**:
  - ❌ **Anti-Pattern: Abandoned Slots, Pinned xmin & Antiquated Cost Limits**:
    - Permitting unconsumed logical/physical replication slots (`pg_replication_slots`) or uncommitted 2PC transactions (`pg_prepared_xacts`) to pin the global vacuum horizon $x_{\text{min}}$, rendering routine autovacuum passes completely futile while `age(datfrozenxid)` climbs toward $2^{31}$.
    - Leaving connections in `idle in transaction` without strict `idle_in_transaction_session_timeout`, holding `backend_xmin` and blocking dead tuple freezing across all database relations.
    - Running modern NVMe cloud databases with legacy 2005-era autovacuum throttles (`vacuum_cost_limit = 200`, `vacuum_cost_delay = 2ms` or `20ms`), limiting freeze throughput to 20–40 MB/s and making terabyte-scale anti-wraparound vacuums take days.
    - Ignoring MultiXact ID (`mxid`) consumption from excessive `SELECT ... FOR SHARE / FOR KEY SHARE` row locking, leading to `pg_multixact` SLRU member exhaustion and stop-the-world database shutdown.
    - Allowing `age(datfrozenxid)` to reach $2^{31} - 10,000,000$ ($2,137,483,648$), triggering postmaster `FATAL: database is not accepting commands` and requiring 24+ hours of offline single-user mode `postgres --single` maintenance.
  - ✅ **Production Invariant**:
    - Continuously monitor cluster transaction horizon age: trigger Tier 1 alerts at $\ge 100\text{M}$ transactions, Tier 2 proactive freeze actions at $\ge 200\text{M}$ (`autovacuum_freeze_max_age`), and Tier 3 emergency intervention at $\ge 1.0\text{B}$.
    - Calibrate autovacuum for modern high-IOPS NVMe storage: configure `autovacuum_vacuum_cost_limit = 3000`–`5000`, `autovacuum_vacuum_cost_delay = 2ms` (or 0ms on dedicated I/O), and dedicate `autovacuum_work_mem = 1GB`–`2GB` for single-pass TID collection.
    - Deploy autonomous saboteur watchdogs to terminate `idle in transaction` sessions older than 60 seconds, roll back orphaned prepared transactions older than 10 minutes, and drop disconnected replication slots where `age(xmin) > 10,000,000`.
    - Range-partition high-churn historical/audit tables and execute explicit one-time `VACUUM (FREEZE, ANALYZE)` on cold partitions, marking Visibility Map `all-frozen` bits and permanently eliminating them from future anti-wraparound scans.
    - Track Time-to-Wraparound (TTW): $T_{\text{ttw}} = \frac{2,137,483,648 - \text{age}(datfrozenxid)}{\lambda_{\text{xid}}}$; enforce automated canary alerts if $T_{\text{ttw}} < 72\text{ hours}$.

- **Database TOAST Storage Strategies, LZ4 Compression & De-TOASTing Memory Defense**:
  - ❌ **Anti-Pattern: De-TOASTing I/O Multiplication, PGLZ CPU Stalls & Ciphertext Compression**:
    - Querying tables with wide varlena columns using unrestricted `SELECT *`, forcing the engine to fetch out-of-line 2KB chunks across thousands of auxiliary `pg_toast` pages and decompress megabytes in RAM even when callers only need scalar columns.
    - Relying on legacy `pglz` compression on PostgreSQL 14+, burning 35%–55% of worker CPU cycles inside `pglz_decompress()` during heavy read workloads.
    - Storing high-entropy pre-compressed (gzip, zstd, PNG) or encrypted (AES-256-GCM ciphertext) data under default `STORAGE EXTENDED`, causing PostgreSQL to waste 40% CPU fruitlessly attempting to compress incompressible bytes before storing out-of-line.
    - Allowing wide columns (~1.5KB) to remain inline under default `TOAST_TUPLE_THRESHOLD` (2048B), packing only 3–5 tuples per 8KB heap page and bloating sequential scans by $15\times$.
    - Modifying parts of toasted columns in naive update loops, duplicating entire multi-kilobyte TOAST chunk sets and flooding Write-Ahead Logs (WAL).
    - Allowing auxiliary `pg_toast_<oid>` tables to accumulate millions of dead chunks without dedicated aggressive autovacuum scale factors (`autovacuum_vacuum_scale_factor = 0.05`).
  - ✅ **Production Invariant**:
    - Strictly eliminate `SELECT *` on relations with toasted columns; explicitly project only scalar metadata in query builders and ORMs.
    - Enforce `default_toast_compression = 'lz4'` cluster-wide (PostgreSQL 14+) and configure `ALTER TABLE ... ALTER COLUMN ... SET COMPRESSION lz4` for large `TEXT` and `JSONB` columns.
    - Enforce `ALTER TABLE ... ALTER COLUMN ... SET STORAGE EXTERNAL;` on all encrypted ciphertext, binary archives, and pre-compressed media blobs to bypass wasted CPU compression cycles.
    - Tune `ALTER TABLE ... SET (toast_tuple_target = 128);` on scan-intensive tables to aggressively move wide text out-of-line, packing 60+ tuples per 8KB page and keeping working-set heap tuples resident in `shared_buffers`.
    - Explicitly configure `autovacuum_vacuum_scale_factor = 0.05` on auxiliary `pg_toast` tables and execute zero-downtime `REINDEX TABLE CONCURRENTLY pg_toast.pg_toast_<oid>_index` during off-peak maintenance windows.

- **Database System Catalog Bloat, Relcache Invalidation Storms & Temporary Table Churn Defense**:
  - ❌ **Anti-Pattern: CREATE TEMP TABLE in Hot Paths, Shared Inval Ring Overruns & Catalog Starvation**:
    - Issuing `CREATE TEMP TABLE` or `CREATE TEMPORARY TABLE` inside batch ETL scripts, API endpoints, or worker loops, inserting 20+ rows into `pg_class`, `pg_attribute`, and `pg_type` per invocation and abandoning millions of dead catalog tuples upon session exit.
    - Allowing unvacuumed `pg_attribute` to swell to gigabytes; because catalog pages cannot be truncated without `ACCESS EXCLUSIVE` locks, query plan compilation slows down 100x across all connections.
    - Triggering shared invalidation ring buffer (`shared_inval`) overflows via rapid DDL or temp table churn, broadcasting nuclear cache resets that dump the entire `relcache` across hundreds of backends simultaneously and causing 100% CPU lock storms.
    - Utilizing temporary tables under transaction-pooled PgBouncer, leaving orphaned temporary objects across reused backend connections and triggering `relation already exists` failures or cross-tenant data leaks.
    - Leaving `pg_catalog` tables under default global autovacuum settings (`autovacuum_vacuum_scale_factor = 0.20`), requiring thousands of dead rows before autovacuum wakes up to clean volatile catalog tables.
  - ✅ **Production Invariant**:
    - Strictly enforce a zero-temp-table invariant in OLTP and API hot paths; replace all temporary staging tables with parameterized arrays (`UNNEST($1::type[])`), `jsonb_to_recordset()`, memory CTEs, or value constructors.
    - For bulk ETL workloads exceeding array wire limits (>100,000 rows), use permanent `UNLOGGED` staging tables partitioned by `session_id`/`batch_id` with `DELETE` or `TRUNCATE`, completely eliminating DDL catalog churn.
    - Calibrate dedicated aggressive catalog autovacuum parameters: `ALTER TABLE pg_catalog.pg_class SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 50);` and `ALTER TABLE pg_catalog.pg_attribute SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 100);`.
    - Enforce PgBouncer `server_reset_query = DISCARD ALL` in pool configurations to cleanly evict temporary state, prepared statements, and private relcache memory allocations on connection check-in.
    - Execute scheduled zero-downtime `REINDEX TABLE CONCURRENTLY pg_catalog.pg_class;` and `REINDEX TABLE CONCURRENTLY pg_catalog.pg_attribute;` during off-peak maintenance windows to eliminate catalog B-Tree fragmentation.

- **Database Extended Query Protocol, Wire Pipelining, Binary Format Encoding & Round-Trip Latency (RTT) Defense**:
  - ❌ **Anti-Pattern: Simple Query Protocol Text Re-Parsing, N+1 Wire RTT Waterfalls & Text Format Deserialization**:
    - Emitting queries via the legacy Simple Query (`'Q'`) protocol using raw text or string concatenation, forcing PostgreSQL to re-parse, re-analyze, and re-plan statements on every execution while creating severe SQL injection vulnerabilities.
    - Executing repetitive queries inside sequential client loops (`for item in batch: query(...)`), waiting for a full client-server TCP round trip per row; in cloud environments with 2ms–5ms RTT, executing 100 queries wastes 200ms–500ms of pure idle wire transit time, starving connection pools.
    - Transmitting UUIDs, timestamps, 64-bit integers, and vector embeddings in Text Format (`format code = 0`), bloating packet payloads by 2.5x and burning 35%–50% of CPU cycles in string formatting and regex parsing.
    - Sending explicit `Sync` (`'S'`) messages between sub-statements in multi-statement workflows, triggering unnecessary intermediate snapshot overhead and WAL evaluation cycles instead of packing requests into a single pipelined flight.
    - Omitting `TCP_NODELAY = 1` on client database sockets, allowing OS Nagle buffering to combine with remote 40ms delayed ACK timers and cause mysterious micro-stutters.
  - ✅ **Production Invariant**:
    - Strictly enforce Extended Query Protocol (`Parse`, `Bind`, `Execute`, `Sync`) parameterization (`$1, $2, ...`) across all database drivers, banning unparameterized simple query strings.
    - Mandate Wire Pipelining (`pgx.Batch` in Go, `PQpipelineMode` in libpq, `connection.pipeline()` in Python psycopg3, `drizzle-orm` batching) for all multi-statement operations, collapsing $N$ round trips into exactly $1$ RTT turnaround: $T = 1 \cdot \text{RTT} + \sum T_{\text{exec}}$.
    - Enforce native PostgreSQL Binary Format (`format code = 1`) for high-density types (`UUID` 16 bytes vs 36 ASCII chars, `TIMESTAMPTZ` 8-byte int64 vs 35-char ISO-8601, `FLOAT8`, `INT8`, `VECTOR`), slashing serialization CPU overhead and network payload size by 50%+.
    - Wrap pipelined operations with transactional savepoints (`SAVEPOINT sp_k`) when partial batch recovery is required, isolating `PGRES_PIPELINE_ABORTED` failures without invalidating entire batches.
    - Explicitly configure client TCP dialers with `TCP_NODELAY = true` and `keepAlive = true` to eradicate 40ms delayed ACK latency cliffs.

- **Database Standby Recovery Conflicts, Snapshot Isolation, `hot_standby_feedback`, Buffer Pin Contention & WAL Replay Starvation Defense**:
  - ❌ **Anti-Pattern: Standby Query Cancellation Storms, Pinned Primary Vacuum Horizons & Replication Slot Loss**:
    - Allowing unindexed or long-running read queries on read replicas to exceed `max_standby_streaming_delay` (default 30s), triggering continuous `canceling statement due to conflict with recovery` (SQLSTATE `40001` / `57014`) failures when primary `VACUUM` WAL records clean dead tuples.
    - Enabling `hot_standby_feedback = on` on read replicas without transaction timeouts or primary bloat monitors; when an unindexed analytical query or forgotten transaction runs for 45 minutes on the replica, it pins the primary's `$x_{\text{min}}$` vacuum horizon, accumulating millions of dead tuples on the primary, degrading B-tree indexes, and pushing the cluster toward XID wraparound emergency shutdowns.
    - Setting replica `statement_timeout` higher than `max_standby_streaming_delay`, causing queries to stall the replica recovery startup process and create multi-minute replication lag spikes before being killed.
    - Assuming `hot_standby_feedback = on` protects against buffer pin conflicts, when exclusive page reorganizations during WAL replay kill queries holding buffer pins during sequential table scans regardless of feedback.
    - Omitting `max_slot_wal_keep_size` on the primary, allowing lagging standby nodes to retain WAL segments until primary disk reaches 100% and crashes the postmaster; or conversely, failing to monitor `wal_status = lost` when replication slots are invalidated.
    - Failing to implement client-side retry harnesses catching recovery conflicts, treating intentional replica concurrency aborts as unhandled 500 errors or cascading queries to the primary writer in a thundering herd.
  - ✅ **Production Invariant**:
    - Strictly enforce the timeout ladder invariant on read replicas: `statement_timeout < max_standby_streaming_delay` (e.g. `statement_timeout = 15s`, `max_standby_streaming_delay = 30s`), guaranteeing queries fail fast or finish before stalling the recovery engine.
    - Architect a dual-tier replica topology: OLTP Replicas with `hot_standby_feedback = on` and `statement_timeout = 5s` for high-concurrency API reads; Analytical Replicas with `hot_standby_feedback = off` and elevated `max_standby_streaming_delay = 15min` for heavy batch aggregations, completely shielding the primary from bloat.
    - Enforce `idle_in_transaction_session_timeout = 5s` on all read replicas to prevent idle transactions from pinning upstream Primary vacuum horizons.
    - Enforce `max_slot_wal_keep_size = 50GB` on the primary to protect write storage from catastrophic disk full panics while monitoring `pg_replication_slots.wal_status`.
    - Implement driver-level recovery conflict retry middleware catching SQLSTATE `40001`/`57014` with message `conflict with recovery`, applying decorrelated exponential jitter $\tau_k = \min(T_{\max}, \mathcal{U}(T_{\text{base}}, \tau_{k-1} \times 3))$ with rate-limited fallback to the primary writer.

- **Database LISTEN / NOTIFY, Asynchronous Event Streaming, 8000-Byte Payload Limits & `pg_notify` SLRU Buffer Overflow Defense**:
  - ❌ **Anti-Pattern: 8KB Payload Clifftops, Transaction-Mode PgBouncer Pinning & SLRU Lockouts**:
    - Serializing entire JSON entities or table rows directly into `pg_notify(channel, row_to_json(NEW)::text)`; when an entity exceeds 8000 bytes (`NOTIFY_PAYLOAD_MAX_LENGTH`), PostgreSQL aborts with `ERROR: payload string too long` (SQLSTATE `54000`), rolling back the entire mutating business transaction.
    - Subscribing to notifications using `LISTEN` over PgBouncer in `pool_mode = transaction` (port 6432), which either pins backend server connections indefinitely (paralyzing pool multiplexing) or unbinds the connection between transactions, sending notifications to dead backend sessions or leaking events across tenant boundaries.
    - Allowing slow or hung subscriber processes to stall reading notifications without queue monitoring, causing PostgreSQL shared memory `pg_notify` SLRU ring buffer to hit 100% saturation and aborting all subsequent `NOTIFY` calls cluster-wide with `pg_notify queue is full`.
    - Failing to implement unconditional channel re-registration in client reconnection supervisors; when cloud NAT gateways drop idle TCP sockets, the client reconnects to a fresh backend without re-issuing `LISTEN`, silently dropping 100% of future notifications with zero error logs.
    - Relying on `LISTEN / NOTIFY` as the sole source of durable truth for business workflows, resulting in permanent data loss during service restarts or network partitions due to at-most-once delivery semantics.
    - Emitting notifications from row-level triggers during batch updates, causing tens of thousands of notification packets to flood client event loops simultaneously upon `COMMIT`.
  - ✅ **Production Invariant**:
    - Strictly enforce the **Thin Pointer (Claim-Check) Pattern**: payloads transmitted via `pg_notify` MUST be lightweight metadata envelopes strictly bounded under 256 bytes (e.g. `json_build_object('t', event_type, 'id', id, 'ts', epoch)`). Never serialize full domain entities into `NOTIFY`.
    - Isolate listener connections into a dedicated, direct, unpooled connection pool (direct port 5432 or strict session-mode port), strictly bypassing transaction-mode poolers.
    - Mandate hybrid **Wakeup + Keyset Outbox Replay**: treat `NOTIFY` solely as a zero-latency signal to wake up worker goroutines/threads; hydrate durable event rows from an append-only Outbox table using keyset seek queries (`WHERE id > :watermark ORDER BY id ASC LIMIT 500`), guaranteeing at-least-once delivery and zero data loss across pod restarts.
    - Wrap listener sockets in an autonomous supervisor loop with decorrelated exponential jitter reconnection, unconditional `LISTEN` channel re-registration, and synthetic heartbeat watchdogs (`pg_notify('__sys_heartbeat__', now())`) every 20 seconds.
    - Implement continuous monitoring of `pg_notification_queue_usage()`; alert at > 25% utilization and auto-evict hung listener backends via `pg_terminate_backend()` before queue saturation triggers cluster write lockouts.
    - Coalesce multi-row batch mutations using statement-level triggers with transition tables (`REFERENCING NEW TABLE AS inserted`) or application-level commit hooks, delivering exactly one aggregated notification per transaction.

- **Database Parallel Query Execution, Worker Starvation, DSM Exhaustion & Multiplied `work_mem` OOM Defense**:
  - ❌ **Anti-Pattern: Silent Serial Plan Downgrade, Multiplied Memory OOMs & Gather Bottlenecks**:
    - Allowing queries planned for multiple parallel workers to execute under worker pool saturation (`max_parallel_workers` / `max_worker_processes` exhausted), causing PostgreSQL to silently launch 0 workers and downgrade to a single-threaded leader sequential scan, turning sub-second queries into 40-second timeouts.
    - Setting global `work_mem` high (e.g. 512MB) to avoid disk sort spills without accounting for worker multiplication, causing parallel queries with $W$ workers to consume $K \cdot (W + 1) \cdot \text{work\_mem}$, driving the Linux kernel to invoke OOM-killer `SIGKILL` on the postmaster.
    - Running containerized PostgreSQL instances with default 64MB `/dev/shm` tmpfs, triggering `dsm_create: out of memory` or `could not resize shared memory segment: No space left on device` under concurrent parallel workloads.
    - Streaming millions of raw unaggregated tuples across `Gather` nodes, pinning a single leader CPU core at 100% in IPC deserialization while parallel workers block waiting for shared message queue buffers.
    - Calling unannotated PL/pgSQL functions or volatile expressions in scan predicates, which default to `VOLATILE` and `PARALLEL UNSAFE`, silently suppressing parallel execution across the entire query tree.
  - ✅ **Production Invariant**:
    - Strictly calibrate hardware limits: `max_parallel_workers_per_gather <= floor(cores / 2)` and `max_parallel_workers <= max_worker_processes`. Ensure `/dev/shm` tmpfs is mounted with at least $\max(1\text{GB}, 0.25 \times \text{RAM})$.
    - Enforce **Dynamic Session `work_mem` Fencing**: analytical batch runners must apply `SET LOCAL work_mem` dynamically inside readonly transactions, scaled as $\min(\text{work\_mem}, \lfloor \text{budget} / (W + 1) \rfloor)$, preventing multi-worker memory multiplication spikes.
    - Mandate **Partial Aggregation Pushdown**: ensure parallel workers perform `Partial Aggregate` locally so that only condensed summary rows (< 10,000 tuples) pass through `Gather` nodes to the leader for `Finalize Aggregate`.
    - Strictly audit functions used in parallel queries for `PARALLEL SAFE` annotations and isolate any unavoidable unsafe operations into distinct temporary tables or isolated CTEs.
    - Deploy `auto_explain` and `pg_stat_activity` sentinels to continuously detect `Workers Planned > Workers Launched` drift and alert when parallel worker starvation exceeds 5%.











