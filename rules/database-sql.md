---
description: SQL and database production invariants, zero-downtime migrations, and query safety
globs: **/*.{sql,prisma},**/migrations/**
alwaysApply: false
---

# SQL & Database Production Invariants

> Add these rules to your project if writing relational database migrations, SQL queries, or ORM data models (PostgreSQL, MySQL, SQLite).

## 1. Zero-Downtime Migrations (Expand & Contract)
- **Never Break Running Services**: Database schema changes and application deployments are asynchronous. All migrations must be backwards-compatible with running versions of the app.
- **Three-Phase Migration Discipline**:
  1. **Expand**: Add new nullable columns or tables; deploy dual-write application logic.
  2. **Backfill**: Backfill historical rows asynchronously in batches with rate-limiting.
  3. **Contract**: Switch reads to new columns; remove old code; drop deprecated columns in a subsequent release.
- **Lock Contention Invariant**:
  - PostgreSQL: Always use `CREATE INDEX CONCURRENTLY` (outside a transaction block).
  - Never add non-null columns without defaults on high-traffic tables.
  - Set a strict `lock_timeout` before executing DDL migrations to avoid blocking user transactions.

## 2. Query Discipline & Indexing
- ❌ **BAN `SELECT *` IN PRODUCTION**: Explicitly enumerate needed columns to reduce network overhead, prevent memory waste, and avoid breaking when columns are added/removed.
- **Mandatory Foreign Key Indexing**: Every foreign key column (`user_id`, `org_id`, etc.) MUST have a corresponding index to avoid full table scans during cascade checks and joins.
- **Pagination Safety**: Never use high-offset `LIMIT 100 OFFSET 100000` on large tables. Use keyset/cursor-based pagination (`WHERE id > :last_seen_id ORDER BY id ASC LIMIT :page_size`).
- **N+1 Prevention**: In ORM operations (Prisma, TypeORM, SQLAlchemy, GORM, ActiveRecord), always use eager loading / batch fetching (`include`, `select_related`, `preload`). Never execute queries inside loops.

## 3. Transaction Hygiene & Boundary Safety
- **Keep Transactions Micro-Short**: Hold transactions open only for the minimal number of write operations.
- ❌ **ZERO NETWORK I/O INSIDE TRANSACTIONS**: Never make external HTTP calls, RPC calls, email triggers, or file uploads while holding an active database transaction.
- **Idempotent Writes**: Design state-changing mutations with idempotency keys or unique constraints to gracefully handle network retries without duplicate billing or data corruption.

## 4. Connection Pool & Statement Limits
- Every production database connection MUST configure:
  - `statement_timeout`: Abort runaway queries before exhausting connection slots.
  - `max_open_conns` and `max_idle_conns`: Prevent connection spikes from crashing database clusters.
  - `conn_max_lifetime`: Recycle stale connections to handle DNS failovers and load balancer recycles cleanly.
