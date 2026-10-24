---
description: SQLite and DuckDB embedded database production invariants, WAL mode tuning, single-writer concurrency safety, PRAGMA hygiene, FTS5 full-text search, in-process columnar analytics, and local-first data synchronization
globs: **/*.{sqlite,sqlite3,db,duckdb},**/sqlite/**,**/duckdb/**,**/migrations/sqlite/**,**/local-first/**,**/embedded/**
alwaysApply: false
---

# SQLite, DuckDB & Embedded Database Production Invariants

> Add these rules to your project if developing with SQLite, DuckDB, LibSQL/Turso, Cloudflare D1, local-first client architectures, desktop applications (Tauri/Electron), mobile apps, or local AI agent memory and analytics storage.

---

## 1. SQLite PRAGMA Production Baselining & Storage Tuning
By default, SQLite initializes in legacy rollback journal mode with relaxed concurrency, foreign key enforcement turned **OFF**, and minimal cache. Every production connection MUST execute a strict initial PRAGMA tuning sequence:

- **Mandatory Initialization PRAGMAs**:
  ```sql
  -- 1. Enable Write-Ahead Logging (WAL) for concurrent reads while writing
  PRAGMA journal_mode = WAL;

  -- 2. NORMAL synchronous mode: full ACID durability in WAL mode, cuts fsync disk I/O by ~90%
  PRAGMA synchronous = NORMAL;

  -- 3. Non-zero busy timeout: wait up to 5000ms instead of immediately failing with SQLITE_BUSY (code 5)
  PRAGMA busy_timeout = 5000;

  -- 4. CRITICAL: Foreign key enforcement is DISABLED by default in SQLite for legacy backwards compatibility
  PRAGMA foreign_keys = ON;

  -- 5. Allocate 64MB memory page cache (negative number denotes KiB; default is only 2MB)
  PRAGMA cache_size = -64000;

  -- 6. Keep temporary tables and index sort spills in RAM instead of disk
  PRAGMA temp_store = MEMORY;

  -- 7. Memory-mapped I/O (256MB): avoids userspace-to-kernel buffer copies on reads
  PRAGMA mmap_size = 268435456;
  ```

- **Connection Setup Invariants Across Stacks**:
  - **TypeScript (`better-sqlite3`)**:
    ```ts
    import Database from 'better-sqlite3';

    const db = new Database('data/app.db', { timeout: 5000 });
    db.pragma('journal_mode = WAL');
    db.pragma('synchronous = NORMAL');
    db.pragma('foreign_keys = ON');
    db.pragma('cache_size = -64000');
    db.pragma('temp_store = MEMORY');
    db.pragma('mmap_size = 268435456');
    ```
  - **Go (`modernc.org/sqlite` or `mattn/go-sqlite3`)**:
    ```go
    // Configure DSN connection string parameters to enforce PRAGMAs on every pooled connection:
    dsn := "file:app.db?_journal_mode=WAL&_synchronous=NORMAL&_busy_timeout=5000&_foreign_keys=ON"
    db, err := sql.Open("sqlite", dsn)
    ```
  - **Python (`sqlite3`)**:
    ```python
    import sqlite3

    conn = sqlite3.connect("app.db", timeout=5.0)
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA synchronous = NORMAL;")
    conn.execute("PRAGMA foreign_keys = ON;")
    conn.execute("PRAGMA cache_size = -64000;")
    ```

---

## 2. Concurrency Architecture: Single-Writer Lock Contention & Transaction Discipline
SQLite's concurrency architecture in WAL mode allows **unlimited concurrent readers** but **strictly AT MOST ONE writer** at any given moment.

- ❌ **THE `BEGIN` VS `BEGIN IMMEDIATE` DEADLOCK TRAP**:
  - The default `BEGIN` statement starts a *deferred* transaction. It begins as a read lock. If two concurrent threads read data, and both subsequently attempt an `INSERT` or `UPDATE`, both try to upgrade their read lock to a reserved write lock simultaneously.
  - SQLite cannot grant both upgrades, resulting in guaranteed immediate deadlock and `SQLITE_BUSY` crashes.
  - ✅ **Production Invariant**: ALWAYS start write transactions with `BEGIN IMMEDIATE`:
    ```sql
    -- ❌ Broken: Deferred write transaction invites concurrent upgrade deadlocks
    BEGIN TRANSACTION;
    UPDATE accounts SET balance = balance - 100 WHERE id = 1;
    COMMIT;

    -- ✅ Production Invariant: Acquires the write lock at the start, serializing concurrent writers cleanly
    BEGIN IMMEDIATE;
    UPDATE accounts SET balance = balance - 100 WHERE id = 1;
    COMMIT;
    ```
  - In `better-sqlite3`, transactions executed via `db.transaction(...)` default to `BEGIN IMMEDIATE` automatically.

- **Connection Pool Sizing: Never Treat SQLite Like Postgres**:
  - ❌ **Anti-Pattern**: Configuring a connection pool of 50 read-write connections in SQLite causes massive file lock contention, thrashing, and write timeouts.
  - ✅ **Production Invariant**:
    - **Single-Writer Pattern**: Maintain exactly **one** dedicated write connection for mutations, and a small pool (e.g. 2–8 connections) of read-only connections (`mode=ro`) for parallel queries.
    - In Go: `db.SetMaxOpenConns(1)` for write-heavy services, or isolate reads and writes into separate `*sql.DB` instances.

---

## 3. Strict Tables, Data Types & Indexing Discipline

- **SQLite 3.37+ `STRICT` Tables Invariant**:
  - Standard SQLite uses dynamic type affinity: any column (except `INTEGER PRIMARY KEY`) accepts any data type (e.g. inserting `'abc'` into an `INTEGER` column succeeds silently).
  - Production Invariant: Define all new tables with the `STRICT` keyword to enforce schema integrity at write time:
    ```sql
    CREATE TABLE users (
        id TEXT PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        age INTEGER CHECK(age >= 0),
        balance REAL NOT NULL DEFAULT 0.0,
        metadata BLOB,
        created_at TEXT NOT NULL
    ) STRICT;
    ```
  - Supported `STRICT` data types: `INT`, `INTEGER`, `REAL`, `TEXT`, `BLOB`, `ANY`.

- **UTC Timestamp ISO-8601 Invariant**:
  - SQLite lacks a dedicated datetime type.
  - Store dates strictly as **ISO-8601 UTC strings** (`TEXT`, e.g. `'2025-10-25T12:00:00.000Z'`) or **Unix Epoch Milliseconds** (`INTEGER`).
  - Standardizing on ISO-8601 allows lexicographical string comparisons (`WHERE created_at >= '2025-01-01'`) and seamless SQLite datetime function support (`datetime(created_at, '+1 day')`).

- **Stored vs Virtual Generated Columns**:
  - Extract frequently queried JSON keys into generated columns and index them:
    ```sql
    CREATE TABLE events (
        id TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        user_id TEXT GENERATED ALWAYS AS (json_extract(payload, '$.user_id')) STORED,
        status TEXT GENERATED ALWAYS AS (json_extract(payload, '$.status')) VIRTUAL
    ) STRICT;

    CREATE INDEX idx_events_user_id ON events (user_id);
    ```
  - Use `STORED` generated columns when indexing to avoid re-evaluating the JSON expression during index scans.

---

## 4. Full-Text Search (FTS5) & Search Index Optimization

- **External Content Tables (`content='...'`)**:
  - Storing documents in both your relational table and a standard FTS5 table doubles disk usage.
  - Use **External Content FTS5 tables** to index text without storing redundant copies:
    ```sql
    -- Base relational table:
    CREATE TABLE documents (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL
    ) STRICT;

    -- External content FTS5 virtual table:
    CREATE VIRTUAL TABLE fts_documents USING fts5(
        title,
        body,
        content='documents',
        content_rowid='id',
        tokenize='unicode61 remove_diacritics 2'
    );
    ```

- **Keep FTS Synced via Triggers**:
  - Automatically maintain the search index on `INSERT`, `UPDATE`, and `DELETE`:
    ```sql
    CREATE TRIGGER trg_docs_ai AFTER INSERT ON documents BEGIN
        INSERT INTO fts_documents(rowid, title, body) VALUES (new.id, new.title, new.body);
    END;

    CREATE TRIGGER trg_docs_ad AFTER DELETE ON documents BEGIN
        INSERT INTO fts_documents(fts_documents, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
    END;

    CREATE TRIGGER trg_docs_au AFTER UPDATE ON documents BEGIN
        INSERT INTO fts_documents(fts_documents, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
        INSERT INTO fts_documents(rowid, title, body) VALUES (new.id, new.title, new.body);
    END;
    ```

- **BM25 Ranking & Substring Trigram Tokenizers**:
  - Utilize FTS5's built-in BM25 ranking, weighting titles higher than body:
    ```sql
    SELECT d.id, d.title, snippet(fts_documents, 1, '<b>', '</b>', '...', 15) AS snippet
    FROM fts_documents f
    JOIN documents d ON d.id = f.rowid
    WHERE fts_documents MATCH :search_query
    ORDER BY bm25(fts_documents, 5.0, 1.0) -- Weight title 5x over body
    LIMIT 20;
    ```
  - For wildcard and substring searching (e.g. searching code symbols, log fragments), specify `tokenize='trigram'`.

---

## 5. DuckDB Embedded Columnar OLAP & Analytical Invariants

DuckDB is the columnar analytical equivalent of SQLite—an in-process, zero-dependency, vectorized query engine optimized for OLAP aggregations, Parquet, and Apache Arrow.

- **Direct Parquet & CSV Pushdown (Zero Ingestion Lag)**:
  - ❌ **Anti-Pattern**: Loading a 20GB Parquet file into Pandas/Python memory just to compute an aggregate.
  - ✅ **Production Invariant**: Execute analytical queries directly against raw files using vectorized filter and projection pushdown:
    ```sql
    SELECT 
        customer_id,
        count(*) AS total_orders,
        round(sum(total_amount), 2) AS lifetime_spend
    FROM read_parquet('data/orders/*.parquet')
    WHERE order_date >= '2025-01-01'
    GROUP BY customer_id
    HAVING sum(total_amount) > 1000
    ORDER BY lifetime_spend DESC
    LIMIT 100;
    ```

- **Host Process Memory Ceiling & Spill-to-Disk**:
  - DuckDB will eagerly utilize all host CPU cores and RAM unless bounded. Unbounded analytical queries can trigger OS Out-of-Memory (OOM) kills on the host service.
  - Always enforce memory limits and external disk spill paths in production:
    ```sql
    SET max_memory = '4GB';
    SET threads = 4;
    SET temp_directory = '/tmp/duckdb_spill';
    SET preserve_insertion_order = false; -- Reduces memory overhead during bulk imports
    ```

- **Zero-Copy Apache Arrow Data Exchange**:
  - When passing data between DuckDB and Python/TypeScript runtimes, avoid copying rows into native objects. Use zero-copy Arrow RecordBatches:
    ```python
    import duckdb

    con = duckdb.connect()
    # Query parquet and convert directly to PyArrow Table without intermediate Python object allocation:
    arrow_table = con.execute("SELECT * FROM read_parquet('metrics.parquet') WHERE value > 99.0").arrow()
    ```

- **Direct SQLite Interop (`ATTACH` Database)**:
  - DuckDB can query and aggregate SQLite databases directly without ETL or data movement:
    ```sql
    ATTACH 'app.db' AS sqlite_db (TYPE SQLITE);

    -- Run ultra-fast vectorized aggregates across your operational SQLite database:
    SELECT status, count(*), avg(balance)
    FROM sqlite_db.users
    GROUP BY status;
    ```

---

## 6. Zero-Downtime Table Migrations & Online Backups

- **The 12-Step Safe Table Recreation Procedure**:
  - SQLite does not natively support altering column nullability, changing column types, or complex constraints in place. When structural alterations are required:
    ```sql
    PRAGMA foreign_keys = OFF;
    BEGIN IMMEDIATE;

    -- 1. Create target table with desired schema
    CREATE TABLE users_new (
        id TEXT PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        phone TEXT,
        created_at TEXT NOT NULL
    ) STRICT;

    -- 2. Copy existing data into new table
    INSERT INTO users_new (id, email, created_at)
    SELECT id, email, created_at FROM users;

    -- 3. Drop old table
    DROP TABLE users;

    -- 4. Rename new table to original name
    ALTER TABLE users_new RENAME TO users;

    -- 5. Recreate indexes and triggers
    CREATE INDEX idx_users_email ON users (email);

    -- 6. Verify foreign key constraints are not violated
    PRAGMA foreign_key_check;

    COMMIT;
    PRAGMA foreign_keys = ON;
    ```

- **Online Zero-Downtime Database Backups (`VACUUM INTO`)**:
  - ❌ **TOTAL BAN ON RAW `cp app.db backup.db` WHILE WRITING**:
    - Copying a live SQLite database file using OS copy utilities while writes are occurring produces corrupted backups because active WAL frames are split or missing.
  - ✅ **Production Invariant**: Use `VACUUM INTO`:
    ```sql
    -- Atomic, zero-corruption, non-blocking online backup:
    VACUUM INTO '/backups/app_backup_20251025.db';
    ```
    `VACUUM INTO` creates an atomic, defragmented copy of the database into the target file while concurrent readers and writers continue uninterrupted.

- **WAL Checkpointing & Incremental Vacuum Hygiene**:
  - Under continuous heavy writes, the `.db-wal` file can grow indefinitely if readers hold open snapshots.
  - Periodically monitor and trigger passive checkpointing:
    ```sql
    -- Checkpoint WAL frames to main DB without blocking readers or writers:
    PRAGMA wal_checkpoint(PASSIVE);
    ```
  - For databases with frequent deletions, configure `PRAGMA auto_vacuum = INCREMENTAL;` during creation and reclaim pages incrementally via `PRAGMA incremental_vacuum(500);` to prevent unrecoverable file bloat.

---

## 7. Local-First & Edge SQLite Discipline (Turso/LibSQL & Cloudflare D1)

- **Client UUID v7 Generation**:
  - In local-first or distributed edge architectures (PowerSync, ElectricSQL, Turso, D1), multiple nodes insert data offline.
  - ❌ Never use auto-incrementing integers (`AUTOINCREMENT`) for IDs in distributed/local-first systems (causes inevitable primary key collisions during sync).
  - ✅ Production Invariant: Generate time-ordered **UUID v7** strings on the client. UUID v7 embeds a millisecond timestamp prefix, preserving B-tree index locality and preventing sequential fragmentation.

- **Read-Your-Own-Writes Consistency on Edge Replicas**:
  - Edge SQLite solutions (Turso/libSQL, D1) replicate writes asynchronously from a primary region to edge read replicas.
  - Invalidate local read caches and supply a replication consistency token (`last_write_tx_id`) when querying replicas immediately after mutations to eliminate stale-read anomalies.
