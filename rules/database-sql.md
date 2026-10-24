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



