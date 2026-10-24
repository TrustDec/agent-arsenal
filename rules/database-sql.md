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









