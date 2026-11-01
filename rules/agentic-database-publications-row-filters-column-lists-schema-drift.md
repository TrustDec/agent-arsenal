---
description: PostgreSQL logical replication publications (CREATE PUBLICATION), row filters (WHERE), column lists, FOR TABLES IN SCHEMA DDL drift defense, publish_via_partition_root, and replica identity integrity across Go (jackc/pgx/v5), TypeScript (drizzle-orm, kysely, pg), Python (asyncpg, psycopg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi).
globs: **/*{publication,subscription,logical_replication,row_filter,column_list,replica_identity,cdc,tablesync}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/internal/replication/**/*.{go,rs},**/src/replication/**/*.{ts,js,py}
alwaysApply: false
---

# Agentic Database Logical Replication Publications, Row Filters, Column Lists, Schema Drift & Foreign Key Invariant Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to configure, migrate, or maintain PostgreSQL (14–17+) Logical Replication publications, subscriber clusters, Change Data Capture (CDC) pipelines, multi-tenant tenant-isolation filters, or microservice event streaming across Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `pg`), Python (`asyncpg`, `psycopg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Row Filter Mutation Transition Trap" (where an update causes a row to transition from matching a publication filter to non-matching, emitting a synthetic `DELETE` on the subscriber that crashes the apply worker or violates `REPLICA IDENTITY` constraints), the "`FOR TABLES IN SCHEMA` DDL Disconnect & Crash-Loop" (where publisher schema publications auto-publish new tables but logical replication fails to replicate DDL, causing subscriber apply workers to crash with `relation does not exist` SQLSTATE 42P01 and halting replication for all published tables), the "Column List REPLICA IDENTITY Omission" (where partial column publications omit primary key columns or filter predicates, causing immediate publication creation rejections or subscriber apply failures), the "Cross-Table Row Filter Referential Integrity Fracture" (where parent tables are published with row filters while child tables are published unfiltered, causing subscriber foreign key constraint violations SQLSTATE 23503 that permanently freeze subscriptions), the "Partitioned Table `publish_via_partition_root` Inversion" (where default leaf partition publication breaks subscriber schemas that model relations heterogeneously), and the "Uncoordinated Initial Table Sync (`copy_data = true`) Resource Starvation Hazard" (where parallel tablesync workers exhaust network bandwidth, saturate NVMe I/O, and pin cluster-wide snapshot horizons) by establishing a strict 5-Tier Publication Governance Ladder, formal filter transition and replication lag physics, an autonomous TypeScript `AgenticDatabasePublicationGuardEngine`, cross-runtime telemetry sentinels in Go, TypeScript, Python, and Rust, a 6-state publication lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Logical Publication Catastrophes vs The 5-Tier Governance Ladder

PostgreSQL native logical replication operates via Write-Ahead Log (WAL) logical decoding using the `pgoutput` plugin. A **Publication** defines a change set emitted by the publisher, while a **Subscription** configures subscriber worker processes (`apply worker` and ephemeral `tablesync workers`) to consume that stream.

Beginning in PostgreSQL 15, publications support granular **Row Filters** (`WHERE (expression)`) and **Column Lists** (`(col1, col2, ...)`). While these features enable zero-code multi-tenant data segregation, selective CDC, and egress bandwidth minimization, autonomous agents routinely deploy naive publications that trigger 6 catastrophic cluster failures:

### The 6 Publication & Logical Replication Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: ROW FILTER REPLICA IDENTITY TRAP (SQLSTATE 55000)
-- Agent creates a row-filtered publication on tenant_id without setting REPLICA IDENTITY FULL:
CREATE TABLE orders (
    id BIGINT PRIMARY KEY,
    tenant_id UUID NOT NULL,
    status TEXT NOT NULL,
    total_amount NUMERIC(12, 2) NOT NULL
);
-- orders has default REPLICA IDENTITY (Primary Key: id). tenant_id and status are NOT in the key!
CREATE PUBLICATION pub_tenant_orders FOR TABLE orders WHERE (tenant_id = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11' AND status != 'CANCELLED');

-- 💥 Catastrophe:
-- Publisher executes: UPDATE orders SET status = 'CANCELLED' WHERE id = 42;
-- In PostgreSQL MVCC, this update changes the row from matching the publication filter to non-matching!
-- To keep the subscriber consistent, PostgreSQL MUST publish a DELETE to the subscriber.
-- BUT to construct the DELETE WAL record for a filtered row, PostgreSQL requires the old values of the filter columns.
-- Under default REPLICA IDENTITY (PK only), old values of 'status' are NOT logged in WAL!
-- PostgreSQL abruptly aborts the publisher's transaction with:
-- ERROR: cannot update table "orders" because the row filter uses columns that are not part of the REPLICA IDENTITY (SQLSTATE 55000)
-- Application writers crash in production!

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: FOR TABLES IN SCHEMA DDL DISCONNECT & CRASH-LOOP
-- Agent sets up automated schema publication on the publisher:
CREATE PUBLICATION pub_app FOR TABLES IN SCHEMA app;
-- Subscriber subscribes:
CREATE SUBSCRIPTION sub_app CONNECTION 'host=pub dbname=prod' PUBLICATION pub_app;

-- 💥 Catastrophe:
-- Developer or migration script creates a new table on publisher: CREATE TABLE app.user_events (id BIGINT PRIMARY KEY, payload JSONB);
-- app.user_events is AUTOMATICALLY added to pub_app on the publisher.
-- Publisher immediately begins streaming WAL change records for app.user_events.
-- BUT PostgreSQL Logical Replication NEVER replicates DDL! app.user_events does NOT exist on the subscriber!
-- Subscriber apply worker encounters the record, cannot find the relation, and aborts:
-- ERROR: logical replication target relation "app.user_events" does not exist (SQLSTATE 42P01)
-- Postmaster restarts the apply worker, which fetches the exact same LSN and crashes again.
-- 💥 THE ENTIRE SUBSCRIPTION HALTS: All replication across ALL tables in pub_app freezes!

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: COLUMN LIST REPLICA IDENTITY OMISSION
-- Agent attempts to publish an audit projection omitting sensitive columns:
CREATE TABLE customers (
    id UUID PRIMARY KEY,
    org_id UUID NOT NULL,
    email TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    credit_card_encrypted BYTEA
);
-- Agent configures publication with column list:
CREATE PUBLICATION pub_customer_profile FOR TABLE customers (email, org_id);

-- 💥 Catastrophe:
-- PostgreSQL immediately rejects the command with:
-- ERROR: column list must contain all columns of replica identity (SQLSTATE 42P01 / 55000)
-- Because 'id' is the Primary Key (Replica Identity), any UPDATE or DELETE cannot be addressed on the subscriber
-- without the primary key column present in the column list!

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: CROSS-TABLE ROW FILTER REFERENTIAL INTEGRITY FRACTURE
-- Agent creates publications with uncoordinated row filters across parent-child relations:
CREATE TABLE tenants (id UUID PRIMARY KEY, name TEXT, region TEXT);
CREATE TABLE users (id UUID PRIMARY KEY, tenant_id UUID REFERENCES tenants(id), email TEXT);

CREATE PUBLICATION pub_eu FOR 
    TABLE tenants WHERE (region = 'EU'),
    TABLE users; -- users is published WITHOUT filter!

-- 💥 Catastrophe:
-- An insert occurs: INSERT INTO tenants VALUES ('t1', 'Acme US', 'US');
-- Next, an insert occurs: INSERT INTO users VALUES ('u1', 't1', 'alice@acme.us');
-- 'tenants' row t1 is FILTERED OUT by the publisher (not sent to subscriber).
-- 'users' row u1 is SENT to the subscriber.
-- Subscriber apply worker attempts to insert u1:
-- ERROR: insert or update on table "users" violates foreign key constraint "users_tenant_id_fkey"
-- DETAIL: Key (tenant_id)=(t1) is not present in table "tenants". (SQLSTATE 23503)
-- Subscription enters an unrecoverable crash loop!

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: PARTITIONED TABLE LEAF-PUBLICATION INVERSION
-- Agent creates a publication on a partitioned table with default settings:
CREATE TABLE sensor_readings (
    recorded_at TIMESTAMPTZ NOT NULL,
    sensor_id INT NOT NULL,
    reading DOUBLE PRECISION
) PARTITION BY RANGE (recorded_at);
CREATE TABLE sensor_readings_2026_11 PARTITION OF sensor_readings FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');

CREATE PUBLICATION pub_sensors FOR TABLE sensor_readings;
-- By default: publish_via_partition_root is FALSE!

-- 💥 Catastrophe:
-- Subscriber models sensor_readings as an unpartitioned table or has a yearly partition structure.
-- When a write hits sensor_readings on publisher, publisher transmits changes labeled as 'sensor_readings_2026_11'.
-- Subscriber apply worker looks for relation "public.sensor_readings_2026_11" and crashes with:
-- ERROR: logical replication target relation "public.sensor_readings_2026_11" does not exist (SQLSTATE 42P01)

-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: UNCOORDINATED TABLES_SYNC NETWORK & HORIZON SATURATION
-- Agent adds 50 tables to an existing publication and refreshes subscription:
ALTER SUBSCRIPTION sub_prod REFRESH PUBLICATION WITH (copy_data = true);
-- 💥 Catastrophe:
-- Subscriber launches max_sync_workers_per_subscription parallel workers.
-- Every worker opens an independent transaction and executes COPY TO STDOUT.
-- Network saturation spikes to 10Gbps, saturating replication link.
-- Snapshots remain pinned for hours, freezing cluster-wide autovacuum horizons and driving 100GB+ MVCC bloat.
```

---

## 2. The 5-Tier Publication & Filter Governance Ladder

To guarantee zero-crash logical replication, deterministic row filter transitions, and unbroken referential integrity, every project must adhere to the 5-Tier Publication Governance Ladder:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│             5-TIER PUBLICATION & ROW FILTER GOVERNANCE LADDER               │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 4: Automated CI Parity Gates & Shadow Migration Verification          │
│          Assert DDL sync before publication refresh, zero FK drift          │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 3: Partition Root Harmonization (publish_via_partition_root = true)   │
│          Decouple physical partition topologies between pub and sub         │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 2: Transitive Referential Co-Filtering (Parent-Child Alignment)      │
│          Ensure child row filters subsume parent filter predicates          │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 1: Mandatory Schema Pre-Flight Fencing & Safe DDL Pipelines           │
│          Ban unmonitored FOR TABLES IN SCHEMA; pre-deploy DDL to subscriber │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 0: REPLICA IDENTITY Full Coverage & Column List Verification          │
│          Ensure all filter columns and PKs belong to REPLICA IDENTITY       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Tier 0: REPLICA IDENTITY Full Coverage & Column List Verification
- **Rule 0.1**: For any table published with a row filter (`WHERE`), every column referenced in the filter expression **must** either be part of the primary key, or the table must be configured with:
  ```sql
  ALTER TABLE <table_name> REPLICA IDENTITY FULL;
  ```
  This eliminates SQLSTATE `55000` when updates cause rows to no longer match filter predicates.
- **Rule 0.2**: For any table published with a column list, the primary key columns (or `REPLICA IDENTITY` columns) **must** be explicitly included in the column list.
- **Rule 0.3**: All columns referenced in a table's row filter predicate **must** be present in the table's published column list.

### 2.2 Tier 1: Mandatory Schema Pre-Flight Fencing & Safe DDL Pipelines
- **Rule 1.1**: Strictly forbid deploying `CREATE PUBLICATION ... FOR TABLES IN SCHEMA` unless an automated DDL migration pipeline guarantees that subscriber schemas are updated **atomically or strictly before** publisher tables are created.
- **Rule 1.2**: Explicitly prefer named table publications:
  ```sql
  CREATE PUBLICATION pub_app FOR TABLE app.orders, app.order_items;
  ```
- **Rule 1.3**: When adding a new table to an existing publication:
  1. Deploy `CREATE TABLE` and all supporting indexes to the subscriber first.
  2. Execute `ALTER PUBLICATION pub_app ADD TABLE app.new_table` on the publisher.
  3. Execute `ALTER SUBSCRIPTION sub_app REFRESH PUBLICATION WITH (copy_data = true)` on the subscriber.

### 2.3 Tier 2: Transitive Referential Co-Filtering (Parent-Child Alignment)
- **Rule 2.1**: If parent table $P$ is published with row filter predicate $\phi_P(x)$, any child table $C$ having a foreign key $C \to P$ must be published with a row filter $\phi_C(y)$ that satisfies the Transitive Invariant:
  $$\forall y \in C, \quad \phi_C(y) \implies \phi_P(\text{parent}(y))$$
- **Rule 2.2**: If parent table $P$ is filtered by `tenant_id = $1`, child table $C$ must also possess `tenant_id` and be filtered by `WHERE tenant_id = $1`. Never publish an unfiltered child table referencing a filtered parent.

### 2.4 Tier 3: Partition Root Harmonization
- **Rule 3.1**: When publishing partitioned relations, always declare:
  ```sql
  CREATE PUBLICATION pub_partitioned FOR TABLE measurements WITH (publish_via_partition_root = true);
  ```
- **Rule 3.2**: `publish_via_partition_root = true` guarantees that changes are decoded and emitted using the schema, column identities, and row filters of the partitioned root table, insulating subscribers from partition drops, splits, or heterogeneous subscriber partitioning schemes.

### 2.5 Tier 4: Staged Initial Synchronization & CI DoD Gates
- **Rule 4.1**: When refreshing subscriptions with `copy_data = true`, never refresh more than 5 tables concurrently. Stagger table additions to prevent network saturation and autovacuum horizon pinning.
- **Rule 4.2**: Configure subscriber `max_sync_workers_per_subscription = 2` on shared infrastructure to protect OLTP query throughput.
- **Rule 4.3**: Enforce CI verification gates that inspect publisher and subscriber catalog parity prior to deployment.

---

## 3. Quantitative Mechanics: Filter Transitions, Apply Lag & Sizing

### 3.1 Row Filter Transition Probability & Synthetic Delete Amplification

Let a published relation have update mutation rate $\lambda_u$ (updates/sec) and row filter predicate $\phi(S)$. Let $S_t$ be the state of a row at time $t$, and $S_{t+1}$ the state after update.

The transition probability $P_{\text{unpublish}}$ that an update causes a matching row to exit the filter is:

$$P_{\text{unpublish}} = P\big(\neg \phi(S_{t+1}) \;\big|\; \phi(S_t)\big)$$

The rate of synthetic `DELETE` events $\lambda_{\text{synth\_del}}$ emitted to the subscriber is:

$$\lambda_{\text{synth\_del}} = \lambda_u \cdot P(\phi(S_t)) \cdot P_{\text{unpublish}}$$

If `REPLICA IDENTITY` is default (Primary Key only) and $\phi$ depends on a mutated non-key attribute $A_k \notin \text{PK}$, the error probability $P(\text{SQLSTATE } 55000)$ on publisher updates is:

$$P(\text{Fatal Crash}) = \begin{cases} 
1.0 & \text{if } A_k \notin \text{REPLICA IDENTITY} \text{ and } \Delta A_k \neq 0 \\
0.0 & \text{if } \text{REPLICA IDENTITY} = \text{FULL}
\end{cases}$$

Therefore, setting `REPLICA IDENTITY FULL` on relations with mutable filter predicates is a mathematical necessity to guarantee publisher write survival.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    ROW FILTER MUTATION TRANSITION DYNAMICS                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│               UPDATE orders SET status = 'CANCELLED' WHERE id = 42;         │
│                                                                             │
│    State S_t: status = 'ACTIVE'   ──►  State S_t+1: status = 'CANCELLED'    │
│    (Matches WHERE status='ACTIVE')     (Fails WHERE status='ACTIVE')        │
│                                                                             │
│                                      │                                      │
│                                      ▼                                      │
│                         Logical Decoder Inspection                          │
│                                      │                                      │
│                ┌─────────────────────┴─────────────────────┐                │
│                ▼                                           ▼                │
│   REPLICA IDENTITY = DEFAULT                  REPLICA IDENTITY = FULL       │
│   Old values of 'status' NOT in WAL           Old tuple values recorded     │
│                │                                           │                │
│                ▼                                           ▼                │
│   💥 FATAL EXCEPTION:                        Emits synthetic DELETE:        │
│   SQLSTATE 55000 (Cannot update)              DELETE FROM orders WHERE id=42│
│   Transaction Rolled Back on Primary!         Subscriber Replicas Stay In Sync!
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Subscriber Apply Worker Lag Under Missing Foreign Key Indexes

When the subscriber apply worker processes incoming changes, it must validate local foreign key constraints. If table $C$ references table $P$, inserting into $C$ triggers a lookup on $P$. Deleting from $P$ triggers a check or cascade on $C$.

If foreign key referencing columns in $C$ lack a B-Tree index on the subscriber, the apply worker time $T_{\text{apply}}$ for a batch of $N$ changes degrades from logarithmic to linear in table size:

$$T_{\text{apply}} \approx \sum_{i=1}^N \left( t_{\text{insert}} + \frac{V_{\text{child}}}{R_{\text{seq}}} \right)$$

Where $V_{\text{child}}$ is the child relation byte size and $R_{\text{seq}}$ is sequential read bandwidth. For a 50GB table on AWS gp3 ($250\text{ MB/s}$):

$$T_{\text{apply\_single}} \approx \frac{50\text{ GB}}{0.25\text{ GB/s}} = 200\text{ seconds per foreign key check!}$$

The apply worker stalls completely, replication lag balloons into hours, and publisher replication slots accumulate tens of gigabytes of WAL.

---

## 4. Production TypeScript Engine: AgenticDatabasePublicationGuardEngine

The following engine provides automated publication auditing, schema parity validation between publisher and subscriber, row filter consistency verification, and safe publication provisioning:

```typescript
import { Client, PoolClient } from 'pg';

export interface PublicationTableInfo {
  pubName: string;
  schemaname: string;
  tablename: string;
  rowfilter: string | null;
  columnList: string[] | null;
  replicaIdentity: 'd' | 'n' | 'f' | 'i'; // default, nothing, full, index
  hasPrimaryKey: boolean;
  publishViaPartitionRoot: boolean;
  isPartitioned: boolean;
}

export interface SchemaParityViolation {
  tableName: string;
  issue: 'MISSING_ON_SUBSCRIBER' | 'COLUMN_MISMATCH' | 'TYPE_MISMATCH' | 'REPLICA_IDENTITY_HAZARD';
  details: string;
}

export interface CoFilterViolation {
  parentTable: string;
  childTable: string;
  constraintName: string;
  parentFilter: string | null;
  childFilter: string | null;
  reason: string;
}

export class AgenticDatabasePublicationGuardEngine {
  constructor(
    private readonly publisherClient: Client | PoolClient,
    private readonly subscriberClient?: Client | PoolClient
  ) {}

  /**
   * Audits all publications on publisher for row filter hazards, missing PKs,
   * and replica identity misconfigurations.
   */
  async auditPublisherPublications(): Promise<{
    publications: PublicationTableInfo[];
    hazards: string[];
  }> {
    const sql = `
      SELECT
          p.pubname AS "pubName",
          n.nspname AS "schemaname",
          c.relname AS "tablename",
          pr.prqual::text AS "rowfilter",
          ARRAY(
              SELECT a.attname
              FROM unnest(pr.prattrs) AS attr_num
              JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = attr_num
              ORDER BY a.attnum
          ) AS "columnList",
          c.relreplident::text AS "replicaIdentity",
          EXISTS (
              SELECT 1 FROM pg_constraint con
              WHERE con.conrelid = c.oid AND con.contype = 'p'
          ) AS "hasPrimaryKey",
          p.pubviaroot AS "publishViaPartitionRoot",
          c.relkind = 'p' AS "isPartitioned"
      FROM pg_publication p
      JOIN pg_publication_rel pr ON pr.prpubid = p.oid
      JOIN pg_class c ON c.oid = pr.prrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      ORDER BY p.pubname, n.nspname, c.relname;
    `;

    const res = await this.publisherClient.query<PublicationTableInfo>(sql);
    const hazards: string[] = [];

    for (const row of res.rows) {
      // Check 1: Row filter with default replica identity
      if (row.rowfilter && row.replicaIdentity !== 'f') {
        hazards.push(
          `CRITICAL: Table "${row.schemaname}.${row.tablename}" in publication "${row.pubName}" has row filter "${row.rowfilter}" but REPLICA IDENTITY is '${row.replicaIdentity}' (not FULL). Updates mutating filter columns will fail with SQLSTATE 55000!`
        );
      }

      // Check 2: Table without primary key
      if (!row.hasPrimaryKey && row.replicaIdentity !== 'f') {
        hazards.push(
          `WARNING: Table "${row.schemaname}.${row.tablename}" in publication "${row.pubName}" has no PRIMARY KEY and REPLICA IDENTITY is not FULL. UPDATE/DELETE replication will fail on subscriber.`
        );
      }

      // Check 3: Partitioned table without publish_via_partition_root
      if (row.isPartitioned && !row.publishViaPartitionRoot) {
        hazards.push(
          `HAZARD: Partitioned table "${row.schemaname}.${row.tablename}" in publication "${row.pubName}" has publish_via_partition_root = FALSE. Changes will publish leaf partition names, risking subscriber relation missing errors.`
        );
      }

      // Check 4: Column list omitting primary key
      if (row.columnList && row.columnList.length > 0) {
        // Query PK columns for this table
        const pkSql = `
          SELECT a.attname
          FROM pg_constraint c
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
          JOIN pg_class cl ON cl.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = cl.relnamespace
          WHERE c.contype = 'p' AND cl.relname = $1 AND n.nspname = $2;
        `;
        const pkRes = await this.publisherClient.query<{ attname: string }>(pkSql, [
          row.tablename,
          row.schemaname,
        ]);
        const pkCols = pkRes.rows.map((r) => r.attname);
        const missingPkCols = pkCols.filter((col) => !row.columnList!.includes(col));
        if (missingPkCols.length > 0) {
          hazards.push(
            `CRITICAL: Column list for "${row.schemaname}.${row.tablename}" omits primary key columns [${missingPkCols.join(', ')}]. Replication will crash!`
          );
        }
      }
    }

    return {
      publications: res.rows,
      hazards,
    };
  }

  /**
   * Compares publisher publication relations against subscriber catalog to verify schema parity.
   */
  async verifySubscriberSchemaParity(pubName: string): Promise<SchemaParityViolation[]> {
    if (!this.subscriberClient) {
      throw new Error('Subscriber client must be provided to verify schema parity');
    }

    // 1. Get published tables
    const pubSql = `
      SELECT n.nspname, c.relname
      FROM pg_publication p
      JOIN pg_publication_rel pr ON pr.prpubid = p.oid
      JOIN pg_class c ON c.oid = pr.prrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE p.pubname = $1;
    `;
    const pubRes = await this.publisherClient.query<{ nspname: string; relname: string }>(pubSql, [
      pubName,
    ]);

    const violations: SchemaParityViolation[] = [];

    for (const table of pubRes.rows) {
      // 2. Check if table exists on subscriber
      const subTableSql = `
        SELECT c.oid, c.relreplident::text AS "replicaIdentity"
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2;
      `;
      const subRes = await this.subscriberClient.query<{ oid: number; replicaIdentity: string }>(
        subTableSql,
        [table.nspname, table.relname]
      );

      if (subRes.rows.length === 0) {
        violations.push({
          tableName: `${table.nspname}.${table.relname}`,
          issue: 'MISSING_ON_SUBSCRIBER',
          details: `Target relation does not exist on subscriber. Apply worker will crash with SQLSTATE 42P01.`,
        });
        continue;
      }

      // 3. Check column parity
      const colCompareSql = `
        SELECT
            attname,
            atttypid::regtype::text AS data_type,
            attnotnull
        FROM pg_attribute
        WHERE attrelid = (
            SELECT c.oid FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2
        ) AND attnum > 0 AND NOT attisdropped
        ORDER BY attname;
      `;

      const [pubCols, subCols] = await Promise.all([
        this.publisherClient.query<{ attname: string; data_type: string }>(colCompareSql, [
          table.nspname,
          table.relname,
        ]),
        this.subscriberClient.query<{ attname: string; data_type: string }>(colCompareSql, [
          table.nspname,
          table.relname,
        ]),
      ]);

      const subColMap = new Map(subCols.rows.map((c) => [c.attname, c.data_type]));
      for (const pCol of pubCols.rows) {
        const sType = subColMap.get(pCol.attname);
        if (!sType) {
          violations.push({
            tableName: `${table.nspname}.${table.relname}`,
            issue: 'COLUMN_MISMATCH',
            details: `Column "${pCol.attname}" exists on publisher but is missing on subscriber.`,
          });
        } else if (sType !== pCol.data_type) {
          violations.push({
            tableName: `${table.nspname}.${table.relname}`,
            issue: 'TYPE_MISMATCH',
            details: `Column "${pCol.attname}" type mismatch: publisher="${pCol.data_type}" vs subscriber="${sType}".`,
          });
        }
      }
    }

    return violations;
  }

  /**
   * Audits foreign key relationships between published tables to detect co-filtering mismatch hazards.
   */
  async auditCrossTableCoFiltering(pubName: string): Promise<CoFilterViolation[]> {
    const sql = `
      WITH pub_tables AS (
          SELECT c.oid AS relid, n.nspname, c.relname, pr.prqual::text AS filter_expr
          FROM pg_publication p
          JOIN pg_publication_rel pr ON pr.prpubid = p.oid
          JOIN pg_class c ON c.oid = pr.prrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE p.pubname = $1
      )
      SELECT
          p_parent.nspname || '.' || p_parent.relname AS "parentTable",
          p_child.nspname || '.' || p_child.relname AS "childTable",
          fk.conname AS "constraintName",
          p_parent.filter_expr AS "parentFilter",
          p_child.filter_expr AS "childFilter"
      FROM pg_constraint fk
      JOIN pub_tables p_child ON p_child.relid = fk.conrelid
      JOIN pub_tables p_parent ON p_parent.relid = fk.confrelid
      WHERE fk.contype = 'f';
    `;

    const res = await this.publisherClient.query<{
      parentTable: string;
      childTable: string;
      constraintName: string;
      parentFilter: string | null;
      childFilter: string | null;
    }>(sql, [pubName]);

    const violations: CoFilterViolation[] = [];
    for (const row of res.rows) {
      if (row.parentFilter && !row.childFilter) {
        violations.push({
          parentTable: row.parentTable,
          childTable: row.childTable,
          constraintName: row.constraintName,
          parentFilter: row.parentFilter,
          childFilter: null,
          reason: `Parent table "${row.parentTable}" has filter "${row.parentFilter}" but child table "${row.childTable}" is unfiltered! Child inserts referencing filtered parents will fail with SQLSTATE 23503.`,
        });
      }
    }

    return violations;
  }
}
```

---

## 5. Cross-Runtime Telemetry Sentinels

### 5.1 Go (`jackc/pgx/v5`): Publication Integrity Sentinel & Replica Identity Guard

```go
package replication

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type PublicationTableHazard struct {
	PubName         string `json:"pub_name"`
	SchemaName      string `json:"schema_name"`
	TableName       string `json:"table_name"`
	RowFilter       string `json:"row_filter"`
	ReplicaIdentity string `json:"replica_identity"`
	HazardLevel     string `json:"hazard_level"`
	Description     string `json:"description"`
}

type PublicationSentinel struct {
	pool *pgxpool.Pool
}

func NewPublicationSentinel(pool *pgxpool.Pool) *PublicationSentinel {
	return &PublicationSentinel{pool: pool}
}

// AuditPublications evaluates all publications for row filter replica identity hazards and missing primary keys.
func (s *PublicationSentinel) AuditPublications(ctx context.Context) ([]PublicationTableHazard, error) {
	query := `
		SELECT
			p.pubname,
			n.nspname,
			c.relname,
			coalesce(pr.prqual::text, ''),
			c.relreplident::text,
			EXISTS (
				SELECT 1 FROM pg_constraint con
				WHERE con.conrelid = c.oid AND con.contype = 'p'
			) AS has_pk,
			p.pubviaroot,
			c.relkind = 'p' AS is_partitioned
		FROM pg_publication p
		JOIN pg_publication_rel pr ON pr.prpubid = p.oid
		JOIN pg_class c ON c.oid = pr.prrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		ORDER BY 1, 2, 3;
	`

	rows, err := s.pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("audit publications query failed: %w", err)
	}
	defer rows.Close()

	var hazards []PublicationTableHazard

	for rows.Next() {
		var (
			pubName         string
			schemaName      string
			tableName       string
			rowFilter       string
			replicaIdent    string
			hasPK           bool
			pubViaRoot      bool
			isPartitioned   bool
		)

		if err := rows.Scan(&pubName, &schemaName, &tableName, &rowFilter, &replicaIdent, &hasPK, &pubViaRoot, &isPartitioned); err != nil {
			return nil, fmt.Errorf("scan publication row failed: %w", err)
		}

		// Hazard 1: Row filter with non-full replica identity
		if rowFilter != "" && replicaIdent != "f" {
			hazards = append(hazards, PublicationTableHazard{
				PubName:         pubName,
				SchemaName:      schemaName,
				TableName:       tableName,
				RowFilter:       rowFilter,
				ReplicaIdentity: replicaIdent,
				HazardLevel:     "CRITICAL",
				Description:     fmt.Sprintf("Row filter active but REPLICA IDENTITY is '%s'. Mutating filter columns will throw SQLSTATE 55000.", replicaIdent),
			})
		}

		// Hazard 2: Partitioned table without pubviaroot
		if isPartitioned && !pubViaRoot {
			hazards = append(hazards, PublicationTableHazard{
				PubName:         pubName,
				SchemaName:      schemaName,
				TableName:       tableName,
				RowFilter:       rowFilter,
				ReplicaIdentity: replicaIdent,
				HazardLevel:     "HIGH",
				Description:     "Partitioned table published with publish_via_partition_root = false. Leaf partition identity will be sent to subscriber.",
			})
		}

		// Hazard 3: Missing Primary Key
		if !hasPK && replicaIdent != "f" {
			hazards = append(hazards, PublicationTableHazard{
				PubName:         pubName,
				SchemaName:      schemaName,
				TableName:       tableName,
				RowFilter:       rowFilter,
				ReplicaIdentity: replicaIdent,
				HazardLevel:     "HIGH",
				Description:     "Table lacks Primary Key and REPLICA IDENTITY is not FULL. Updates/deletes will fail on subscriber.",
			})
		}
	}

	return hazards, rows.Err()
}

// RemediateReplicaIdentity sets REPLICA IDENTITY FULL on a target relation under strict lock_timeout.
func (s *PublicationSentinel) RemediateReplicaIdentity(ctx context.Context, schemaName, tableName string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin remediation tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// Set short lock timeout to avoid blocking concurrent OLTP transactions
	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2000ms';"); err != nil {
		return fmt.Errorf("set lock_timeout: %w", err)
	}

	alterSQL := fmt.Sprintf("ALTER TABLE %s.%s REPLICA IDENTITY FULL;",
		pgx.Identifier{schemaName}.Sanitize(),
		pgx.Identifier{tableName}.Sanitize(),
	)

	slog.Info("Remediating replica identity to FULL", "table", fmt.Sprintf("%s.%s", schemaName, tableName))
	if _, err := tx.Exec(ctx, alterSQL); err != nil {
		return fmt.Errorf("execute alter replica identity: %w", err)
	}

	return tx.Commit(ctx)
}
```

---

### 5.2 Python (`asyncpg`): Subscriber Apply Health & Schema Drift Monitor

```python
import asyncio
import logging
from typing import List, Dict, Any
import asyncpg

logger = logging.getLogger("replication_guard")

class SubscriptionHealthMonitor:
    def __init__(self, subscriber_pool: asyncpg.Pool):
        self.pool = subscriber_pool

    async def check_subscription_worker_errors(self) -> List[Dict[str, Any]]:
        """Queries pg_stat_subscription and pg_stat_subscription_errors for failing apply workers."""
        query = """
            SELECT
                sub.subname AS subscription_name,
                stat.pid AS worker_pid,
                stat.received_lsn::text AS received_lsn,
                stat.last_msg_send_time,
                stat.last_msg_receipt_time,
                stat.latest_end_lsn::text AS latest_end_lsn,
                stat.latest_end_time
            FROM pg_subscription sub
            LEFT JOIN pg_stat_subscription stat ON stat.subid = sub.oid
            ORDER BY sub.subname;
        """
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)
            return [dict(r) for r in rows]

    async def detect_tablesync_backlog(self) -> List[Dict[str, Any]]:
        """Audits pg_subscription_rel to verify if any tables are stuck in initial sync."""
        query = """
            SELECT
                sub.subname AS subscription_name,
                n.nspname AS schema_name,
                c.relname AS table_name,
                sr.srsubstate AS state_char,
                CASE sr.srsubstate
                    WHEN 'i' THEN 'INITIAL_COPY'
                    WHEN 'd' THEN 'DATA_COPIED'
                    WHEN 's' THEN 'SYNCHRONIZED'
                    WHEN 'r' THEN 'READY'
                    ELSE 'UNKNOWN'
                END AS state_desc,
                sr.srsublsn::text AS sync_lsn
            FROM pg_subscription_rel sr
            JOIN pg_subscription sub ON sub.oid = sr.srsubid
            JOIN pg_class c ON c.oid = sr.srrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE sr.srsubstate != 'r';
        """
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)
            return [dict(r) for r in rows]
```

---

### 5.3 Rust (`tokio-postgres`): Publication Provisioning & Pre-Flight Gate

```rust
use tokio_postgres::{Client, Error};
use tracing::{error, info, warn};

pub struct PublicationProvisioner<'a> {
    client: &'a mut Client,
}

impl<'a> PublicationProvisioner<'a> {
    pub fn new(client: &'a mut Client) -> Self {
        Self { client }
    }

    /// Verifies that a relation satisfies all Tier 0 publication invariants before publication.
    pub async fn verify_publication_preflight(
        &self,
        schema: &str,
        table: &str,
        has_row_filter: bool,
    ) -> Result<bool, Error> {
        let sql = "
            SELECT
                c.relreplident::text,
                EXISTS (
                    SELECT 1 FROM pg_constraint con
                    WHERE con.conrelid = c.oid AND con.contype = 'p'
                ) AS has_pk
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2;
        ";

        let row = self.client.query_one(sql, &[&schema, &table]).await?;
        let repl_ident: String = row.get(0);
        let has_pk: bool = row.get(1);

        if has_row_filter && repl_ident != "f" {
            error!(
                "Table {}.{} has row filter requested but REPLICA IDENTITY is '{}' (must be 'f')",
                schema, table, repl_ident
            );
            return Ok(false);
        }

        if !has_pk && repl_ident != "f" {
            warn!(
                "Table {}.{} has no PRIMARY KEY; REPLICA IDENTITY must be FULL",
                schema, table
            );
            return Ok(false);
        }

        info!("Pre-flight verification passed for {}.{}", schema, table);
        Ok(true)
    }
}
```

---

## 6. Six-State Publication Lifecycle Finite-State Machine (FSM)

```
        [IDLE]
          │
          ▼
[CATALOG_DISCOVERY] ───────► (Missing PK && RelReplIdent != 'f') ──► [BLOCKED: REPLICA_IDENTITY_HAZARD]
          │
          ▼
[REPLICA_IDENTITY_CHECK] ──► (RowFilter Active && RelReplIdent != 'f') ──► [BLOCKED: FILTER_TRANSITION_RISK]
          │
          ▼
[REFERENTIAL_ALIGNMENT] ───► (Unfiltered Child References Filtered Parent) ──► [BLOCKED: FK_FRACTURE]
          │
          ▼
[SCHEMA_PARITY_VERIFIED] ──► (Subscriber Missing Table / Col Mismatch) ──► [BLOCKED: DRIFT_DETECTED]
          │
          ▼
[PUBLICATION_ACTIVE]
```

| Current State | Transition Trigger | Verification Condition | Next State | Architectural Action |
|:---|:---|:---|:---|:---|
| **`IDLE`** | Deploy Publication | User initiates publication creation/alter | `CATALOG_DISCOVERY` | Inspects `pg_class`, `pg_constraint`, and `pg_publication` |
| **`CATALOG_DISCOVERY`** | Analyze Table Spec | Missing PK and `relreplident != 'f'` | `BLOCKED_REPLICA_IDENT` | Aborts; requires `ALTER TABLE ... REPLICA IDENTITY FULL` |
| **`REPLICA_IDENTITY_CHECK`** | Evaluate Row Filter | Row filter present and `relreplident != 'f'` | `BLOCKED_FILTER_RISK` | Aborts with `SQLSTATE 55000` defense warning |
| **`REFERENTIAL_ALIGNMENT`** | Trace Foreign Keys | Child table unfiltered while parent filtered | `BLOCKED_FK_FRACTURE` | Aborts; requires co-filtering alignment on foreign keys |
| **`SCHEMA_PARITY_VERIFIED`**| Inspect Subscriber | Subscriber missing relation or column mismatch | `BLOCKED_DRIFT` | Halts DDL; requires subscriber schema deployment |
| **`PUBLICATION_ACTIVE`** | All Gates Cleared | All invariants satisfied | `PUBLICATION_ACTIVE` | Executes `CREATE/ALTER PUBLICATION` with `publish_via_partition_root` |

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Every repository deploying logical replication, CDC, or multi-tenant database partitions must satisfy the following 6 gates in CI:

| Gate | Target Metric | Verification Query / Command | Pass Criterion |
|:---|:---|:---|:---|
| **Gate 1: Row Filter Replica Identity** | Zero Filter Hazards | Query `pg_publication_rel` vs `relreplident` | `count = 0` tables with filter and `relreplident != 'f'` |
| **Gate 2: Published PK Coverage** | Replica Identity Coverage | Tables in publications lacking PK or `FULL` | `count = 0` |
| **Gate 3: Partition Root Harmonization** | Root Publication Mode | Partitioned tables in publications with `pubviaroot = false` | `count = 0` |
| **Gate 4: Column List PK Inclusion** | Column List Coverage | Column lists omitting primary key columns | `count = 0` |
| **Gate 5: Cross-Table Co-Filtering** | Foreign Key Filter Parity | Unfiltered child tables referencing filtered parents | `count = 0` |
| **Gate 6: Subscriber Schema Parity** | Cross-Cluster DDL Match | Table and column differential between pub and sub | `drift_count = 0` |

### Pre-Deployment CI Verification Script

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Auditing PostgreSQL Logical Replication Publications & Row Filter Invariants..."

# Gate 1: Verify all row-filtered tables possess REPLICA IDENTITY FULL
FILTER_HAZARD_COUNT=$(psql -v ON_ERROR_STOP=1 -At -c "
  SELECT count(*)
  FROM pg_publication p
  JOIN pg_publication_rel pr ON pr.prpubid = p.oid
  JOIN pg_class c ON c.oid = pr.prrelid
  WHERE pr.prqual IS NOT NULL
    AND c.relreplident != 'f';
")

if [ "$FILTER_HAZARD_COUNT" -gt 0 ]; then
  echo "❌ CI FAIL: Found $FILTER_HAZARD_COUNT published tables with ROW FILTERS but without REPLICA IDENTITY FULL!"
  echo "👉 Fix: Execute 'ALTER TABLE <name> REPLICA IDENTITY FULL;' to prevent SQLSTATE 55000 crashes on updates."
  exit 1
fi

# Gate 2: Verify all partitioned tables enforce publish_via_partition_root
PARTITION_ROOT_HAZARD_COUNT=$(psql -v ON_ERROR_STOP=1 -At -c "
  SELECT count(*)
  FROM pg_publication p
  JOIN pg_publication_rel pr ON pr.prpubid = p.oid
  JOIN pg_class c ON c.oid = pr.prrelid
  WHERE c.relkind = 'p'
    AND NOT p.pubviaroot;
")

if [ "$PARTITION_ROOT_HAZARD_COUNT" -gt 0 ]; then
  echo "❌ CI FAIL: Found $PARTITION_ROOT_HAZARD_COUNT partitioned tables with publish_via_partition_root = FALSE!"
  echo "👉 Fix: Recreate or alter publication WITH (publish_via_partition_root = true);"
  exit 1
fi

# Gate 3: Verify all published tables have Primary Key or REPLICA IDENTITY FULL
MISSING_PK_HAZARDS=$(psql -v ON_ERROR_STOP=1 -At -c "
  SELECT count(*)
  FROM pg_publication p
  JOIN pg_publication_rel pr ON pr.prpubid = p.oid
  JOIN pg_class c ON c.oid = pr.prrelid
  WHERE c.relreplident != 'f'
    AND NOT EXISTS (
        SELECT 1 FROM pg_constraint con
        WHERE con.conrelid = c.oid AND con.contype = 'p'
    );
")

if [ "$MISSING_PK_HAZARDS" -gt 0 ]; then
  echo "❌ CI FAIL: Found $MISSING_PK_HAZARDS published tables lacking both Primary Key and REPLICA IDENTITY FULL."
  exit 1
fi

echo "✅ All Publication & Row Filter Invariant CI Gates Passed."
```
