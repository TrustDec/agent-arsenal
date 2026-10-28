---
description: Database check constraints, domain types (CREATE DOMAIN), enum migration traps, SQL three-valued logic NULL bypass defense, multi-column business invariants, mutually exclusive pointers (num_nonnulls), zero-downtime NOT VALID migrations, and data integrity at rest across Go (pgx/v5), TypeScript (Drizzle/Prisma/Kysely), Python (SQLAlchemy), Rust (sqlx), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{check,constraint,domain,enum,invariant,validate,schema,migration,model,entity}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/models/**/*.{ts,js,go,rs,py},**/src/entities/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Check Constraints, Domain Types, Enum Traps & Multi-Column Table Invariant Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design relational database schemas, column constraints, domain types, enum lifecycles, multi-column state machines, or data validation layers across PostgreSQL, MySQL/InnoDB, SQLite, Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Prisma`, `Kysely`, `TypeORM`), Python (`SQLAlchemy`), or Rust (`sqlx`). Eliminate the "Synchronous CHECK Constraint Full Table Scan & Lockout Outage" (where agents run `ALTER TABLE orders ADD CONSTRAINT check_positive_amount CHECK (amount_cents > 0);` without `NOT VALID`, acquiring `ACCESS EXCLUSIVE` on the table for the entire duration of a sequential scan over tens of millions of rows, freezing all concurrent production reads and writes and exhausting connection pools), the "Ternary Logic NULL-Bypass Illusion" (where SQL standard three-valued logic treats `UNKNOWN` as non-violating, causing `CHECK (discount_percent <= 100)` or `CHECK (status != 'banned')` to silently allow `NULL` values to pass and corrupting application invariants that assumed the column was non-nullable), the "PostgreSQL Native `CREATE TYPE ... AS ENUM` Trap" (where autonomous agents declare native DB enums whose values cannot be removed, cannot be renamed or reordered without full table rewrites, cannot be added within transaction blocks alongside DDL in older versions or used in the same transaction block, and escalate locks during migrations), the "Cross-Column Business Invariant Drift & Mutually Exclusive State Corruption" (where interdependent columns—such as a billing account belonging to either `user_id` OR `org_id`, or `status = 'refunded'` requiring `refunded_at IS NOT NULL` and `refund_amount_cents > 0`—are checked only in application code, allowing background scripts, bulk imports, and race conditions to insert corrupt, divergent state), the "Volatile Function & Backtracking Regex CPU Meltdown Trap" (where agents attempt dynamic temporal checks like `CHECK (expires_at > now())` which violates PostgreSQL constraint immutability, or place unanchored catastrophic-backtracking regular expressions that execute on every row write and destroy transaction throughput), and the "Primitive Obsession Vulnerability & Missing PostgreSQL `CREATE DOMAIN` Invariants" (where emails, monetary amounts, and percentages are stored as raw untyped primitives across dozens of tables with divergent, copy-pasted validation logic) by establishing a strict 5-Tier Constraint & Domain Invariant Governance Ladder, SQL three-valued logic mathematical proofs, zero-downtime two-phase validation pipelines, and machine-verifiable CI test gates.

---

## 1. Architectural Taxonomy: The 6 Constraint & Domain Catastrophes vs The 5-Tier Invariant Governance Ladder

Relational databases guarantee data integrity at rest. However, autonomous coding agents frequently misunderstand the locking mechanics, ternary logic semantics, and migration constraints of relational engines (especially PostgreSQL):

```typescript
// ❌ CATASTROPHIC LLM CHECK CONSTRAINT & ENUM ANTI-PATTERNS

// 1. The Synchronous CHECK Constraint Lockout Outage!
// Running synchronous ALTER TABLE in migration files:
// ALTER TABLE orders ADD CONSTRAINT check_positive_cents CHECK (amount_cents > 0);
// Takes ACCESS EXCLUSIVE lock on orders for 2 minutes while scanning 30M rows! Full system downtime!
export const orders = pgTable('orders', {
  id: uuid('id').primaryKey().defaultRandom(),
  amountCents: bigint('amount_cents', { mode: 'number' }).notNull(),
  // ❌ LLM adds synchronous CHECK in migration without NOT VALID!
});

// 2. The Ternary Logic NULL-Bypass Illusion!
// In SQL 3-valued logic, a CHECK constraint passes if the predicate evaluates to TRUE OR UNKNOWN (NULL).
// If discount_percent is NULL, (NULL <= 100) evaluates to UNKNOWN, which PASSES!
// The agent assumes this column can never be NULL without adding NOT NULL!
export const products = pgTable('products', {
  id: uuid('id').primaryKey().defaultRandom(),
  discountPercent: integer('discount_percent'), // ❌ Nullable! Passes CHECK (discount_percent <= 100) silently!
});

// 3. The PostgreSQL Native CREATE TYPE ... AS ENUM Trap!
// CREATE TYPE payment_status AS ENUM ('pending', 'captured', 'refunded');
// Later when adding 'disputed', ALTER TYPE payment_status ADD VALUE 'disputed' cannot run inside
// a multi-statement transaction or be used in the same transaction block!
// Cannot delete obsolete statuses without full-table type rewrite!
export const paymentStatusEnum = pgEnum('payment_status', ['pending', 'captured', 'refunded']);

// 4. The Cross-Column Mutually Exclusive State Corruption!
// A subscription can belong to a user OR an organization, NEVER both, NEVER neither.
// Without CHECK (num_nonnulls(user_id, org_id) = 1), dirty records slip in via raw SQL or worker jobs!
export const subscriptions = pgTable('subscriptions', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').references(() => users.id),
  orgId: uuid('org_id').references(() => orgs.id),
  // ❌ Missing CHECK: Both can be NULL, or both can be set simultaneously!
});

// 5. The Volatile Function Temporal Constraint Trap!
// LLMs write CHECK (expires_at > now()) - FAILS in PostgreSQL!
// PostgreSQL requires CHECK constraints to be IMMUTABLE. 'now()' is STABLE/VOLATILE!
```

To eliminate these failure modes, production systems enforce the **5-Tier Constraint & Domain Invariant Governance Ladder**:

```
+----------------------------------------------------------------------------------------------------+
|                   5-TIER CONSTRAINT & DOMAIN INVARIANT GOVERNANCE LADDER                           |
+----------------------------------------------------------------------------------------------------+
| Tier 0: Explicit Three-Valued Logic & Mandatory NOT NULL Co-location                               |
|   - Zero ambiguous NULL passes: CHECK constraints MUST explicitly account for NULLs.              |
|   - Either pair with explicit NOT NULL column constraint, or use CHECK (col IS NULL OR ...).       |
|   - Eliminate accidental bypass: CHECK (status != 'banned') -> CHECK (status IS NOT NULL AND ...). |
+----------------------------------------------------------------------------------------------------+
| Tier 1: Two-Phase Online Zero-Downtime CHECK Constraint Protocol                                   |
|   - Step 1: ALTER TABLE ... ADD CONSTRAINT ... CHECK (...) NOT VALID (instant catalog metadata lock).|
|   - Step 2: ALTER TABLE ... VALIDATE CONSTRAINT ... (SHARE UPDATE EXCLUSIVE; non-blocking to writes)|
|   - Guarantees zero ACCESS EXCLUSIVE lock queueing on high-volume production tables.               |
+----------------------------------------------------------------------------------------------------+
| Tier 2: Lookup Reference Tables or Validated Text CHECKs over Native ENUMs                         |
|   - Dynamic or evolving sets: Lookup table (code VARCHAR(32) PRIMARY KEY) with Foreign Key.       |
|   - Static low-cardinality sets: VARCHAR(32) + validated CHECK (status IN (...)) NOT VALID.         |
|   - Avoids PostgreSQL ALTER TYPE transactional limitations, lock-ins, and full-table rewrites.     |
+----------------------------------------------------------------------------------------------------+
| Tier 3: Multi-Column Cross-Field Coherence Invariants (State Machines & Mutually Exclusive)       |
|   - Mutually exclusive ownership: CHECK (num_nonnulls(user_id, org_id) = 1).                       |
|   - State-dependent columns: CHECK ((status = 'refunded' AND refunded_at IS NOT NULL) OR          |
|     (status != 'refunded' AND refunded_at IS NULL)).                                               |
|   - Temporal sanity: CHECK (started_at <= completed_at) using strictly immutable operators.        |
+----------------------------------------------------------------------------------------------------+
| Tier 4: Reusable PostgreSQL CREATE DOMAIN Invariants & Continuous Catalog Audits                   |
|   - Encapsulate domain rules: CREATE DOMAIN positive_cents AS BIGINT CHECK (VALUE >= 0).           |
|   - Reusable email, currency, percentage, and ISO country domains preventing primitive obsession.  |
|   - Continuous CI auditing via pg_constraint: 0 unvalidated constraints, 0 volatile functions.    |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. Mathematical Formalism: SQL Three-Valued Logic, Lock Contention Sizing & Table Rewrite Amplification

### 2.1 The SQL Three-Valued Logic (3VL) Predicate Satisfaction Theorem

In standard ANSI SQL and PostgreSQL, boolean evaluations operate on a ternary truth domain:
$$\mathbb{T} = \{\text{TRUE}, \text{FALSE}, \text{UNKNOWN}\}$$

Where $\text{UNKNOWN} \equiv \text{NULL}$.

#### Constraint Satisfaction Axiom
A row tuple $T$ satisfies a table `CHECK (P)` constraint if and only if the predicate $P(T)$ does **NOT** evaluate to $\text{FALSE}$:
$$\text{Satisfied}(P, T) \iff P(T) \neq \text{FALSE} \iff P(T) \in \{\text{TRUE}, \text{UNKNOWN}\}$$

#### The Silent NULL Bypass Proof
Consider an agent defining a discount constraint intended to bound discounts:
$$P(x) \equiv (x \le 100)$$

If a row has $x = \text{NULL}$:
$$P(\text{NULL}) \equiv (\text{NULL} \le 100) = \text{UNKNOWN}$$
$$\text{Satisfied}(P, T) = (\text{UNKNOWN} \neq \text{FALSE}) = \text{TRUE}$$

The constraint **passes**, even though $x$ is not $\le 100$.

Similarly, for exclusion filters:
$$P_{\text{not\_banned}}(s) \equiv (s \neq \text{'banned'})$$
If $s = \text{NULL}$:
$$(\text{NULL} \neq \text{'banned'}) = \text{UNKNOWN} \implies \text{Passes!}$$

**Mathematical Invariant**: To guarantee that a predicate $P(x)$ strictly holds on non-empty data, it must be formulated as:
$$P_{\text{strict}}(x) \equiv (x \text{ IS NOT NULL}) \land P(x)$$
Or enforced by combining a column-level `NOT NULL` with the check constraint.

### 2.2 Lock Contention Differential: Synchronous vs Two-Phase Constraint Addition

When an agent executes `ALTER TABLE T ADD CONSTRAINT c CHECK (P)`:
1. **Synchronous Mode (without `NOT VALID`)**:
   PostgreSQL acquires an `ACCESS EXCLUSIVE` lock on relation $T$.
   - Mode: Incompatible with ALL other lock modes (`SELECT`, `INSERT`, `UPDATE`, `DELETE`).
   - Duration: Proportional to the full sequential scan time over $N$ rows:
     $$t_{\text{scan}} = \frac{N \cdot S_{\text{row}}}{\text{Throughput}_{\text{seq\_scan}}}$$
   - Blocked Queue Growth (Little's Law):
     $$Q_{\text{blocked}} = \lambda_{\text{traffic}} \times t_{\text{scan}}$$
     For $\lambda = 500\text{ req/s}$ and $t_{\text{scan}} = 20\text{s}$:
     $$Q_{\text{blocked}} = 500 \times 20 = 10,000\text{ blocked connections!}$$
     The database connection pool ($N_{\text{pool}} \approx 100 - 300$) is exhausted within $\frac{300}{500} = 0.6\text{ seconds}$, causing cascading 504 Gateway Timeouts cluster-wide.

2. **Two-Phase Mode (`NOT VALID` + `VALIDATE CONSTRAINT`)**:
   - **Phase 1 (`ADD CONSTRAINT ... NOT VALID`)**:
     Acquires `ACCESS EXCLUSIVE` momentarily only to update system catalog `pg_constraint` with `convalidated = false`.
     $$t_{\text{catalog}} \le 5\text{ms} \implies Q_{\text{blocked}} = 500 \times 0.005 = 2.5 \approx 0$$
   - **Phase 2 (`VALIDATE CONSTRAINT`)**:
     Acquires `SHARE UPDATE EXCLUSIVE` lock.
     - `SHARE UPDATE EXCLUSIVE` is compatible with `SELECT`, `INSERT`, `UPDATE`, and `DELETE`.
     - Concurrent read and write traffic proceeds uninterrupted at normal latency:
       $$Q_{\text{blocked}} = 0$$

### 2.3 Mutually Exclusive Non-Null Counting Calculus

For an entity possessing $K$ possible owner/parent foreign keys $c_1, c_2, \dots, c_K$, exact-one polymorphic association requires:
$$\sum_{i=1}^K \mathbb{I}(c_i \neq \text{NULL}) = 1$$
Where the indicator function $\mathbb{I}$ is implemented via PostgreSQL's native `num_nonnulls(c_1, c_2, \dots, c_K)`.

For zero-or-one (optional exclusive) association:
$$\text{num_nonnulls}(c_1, c_2, \dots, c_K) \le 1$$

---

## 3. The 5 Core Production Invariants

### 3.1 Invariant 1: Mandatory Two-Phase Zero-Downtime CHECK Constraint Protocol
Never execute synchronous `ADD CONSTRAINT ... CHECK` on tables containing $> 1,000$ rows. Every check constraint addition MUST be split into:
1. `ALTER TABLE <table> ADD CONSTRAINT <name> CHECK (<expr>) NOT VALID;`
2. `ALTER TABLE <table> VALIDATE CONSTRAINT <name>;`

```sql
-- Step 1: Instant metadata registration (sub-10ms ACCESS EXCLUSIVE)
ALTER TABLE transactions
ADD CONSTRAINT check_positive_amount
CHECK (amount_cents > 0)
NOT VALID;

-- Step 2: Concurrently scan existing data without blocking reads or writes (SHARE UPDATE EXCLUSIVE)
ALTER TABLE transactions
VALIDATE CONSTRAINT check_positive_amount;
```

### 3.2 Invariant 2: Explicit Three-Valued Logic & Strict NOT NULL Co-location
A `CHECK` constraint MUST NOT be relied upon to prevent `NULL` values unless explicit `IS NOT NULL` checks are included.
- If a column MUST NOT be null: Declare the column `NOT NULL`.
- If a column is optional, but must satisfy invariant when present: Use `CHECK (col IS NULL OR col >= 0)`.
- Never write negative inequality checks on nullable columns: `CHECK (status != 'banned')` allows `NULL`! Write:
  ```sql
  CHECK (status IS NOT NULL AND status != 'banned')
  ```

### 3.3 Invariant 3: Lookup / Reference Tables or Validated Text CHECKs over Native `CREATE TYPE ... AS ENUM`
PostgreSQL native ENUMs carry severe operational friction:
- Adding a value cannot run inside a multi-statement transaction in PostgreSQL $< 12$.
- In all versions, newly added enum values cannot be referenced in the same transaction block (`unsafe use of new value ... of enum type`).
- Enum values can never be dropped or renamed without dropping all dependent tables or performing complex catalog surgery.

**Production Selection Standard**:
1. **Dynamic or User-Configurable Sets**: Lookup / Reference table:
   ```sql
   CREATE TABLE order_statuses (
     code VARCHAR(32) PRIMARY KEY,
     label TEXT NOT NULL,
     is_active BOOLEAN NOT NULL DEFAULT true,
     display_order INTEGER NOT NULL DEFAULT 0
   );
   ```
2. **Static Core Statuses ($< 15$ values)**: Native `VARCHAR(32)` or `TEXT` with a validated `CHECK (status IN ('pending', 'completed', 'cancelled')) NOT VALID` constraint. Adding a new status requires only a two-phase check constraint swap, which is 100% zero-downtime and transaction-safe.

### 3.4 Invariant 4: Multi-Column Cross-Field Coherence Invariants
When multiple columns in a table represent state transitions, temporal ranges, or mutually exclusive ownership, enforce the relationship at the relational engine level:
1. **Mutually Exclusive Polymorphic Pointers**:
   ```sql
   ALTER TABLE billing_accounts
   ADD CONSTRAINT check_single_owner
   CHECK (num_nonnulls(user_id, organization_id) = 1)
   NOT VALID;
   ```
2. **State-Dependent Attributes**:
   ```sql
   ALTER TABLE orders
   ADD CONSTRAINT check_refund_consistency
   CHECK (
     (status = 'refunded' AND refunded_at IS NOT NULL AND refund_cents > 0) OR
     (status != 'refunded' AND refunded_at IS NULL AND refund_cents IS NULL)
   )
   NOT VALID;
   ```
3. **Temporal Bounds**:
   ```sql
   ALTER TABLE service_intervals
   ADD CONSTRAINT check_valid_time_range
   CHECK (started_at <= completed_at)
   NOT VALID;
   ```

### 3.5 Invariant 5: Reusable PostgreSQL `CREATE DOMAIN` Invariants & Strict Immutability
Eliminate primitive obsession and copy-pasted validation rules across schemas using PostgreSQL `DOMAIN` types. Ensure all expressions in check constraints and domains are strictly **IMMUTABLE**:
- Never call `now()`, `CURRENT_TIMESTAMP`, or volatile user-defined functions inside constraints.
- Anchor all regular expressions to prevent catastrophic backtracking: `^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`.

```sql
-- Reusable domain types enforced uniformly across tables
CREATE DOMAIN currency_cents AS BIGINT
CHECK (VALUE >= 0);

CREATE DOMAIN percentage_bps AS INTEGER
CHECK (VALUE >= 0 AND VALUE <= 10000);

CREATE DOMAIN email_address AS VARCHAR(255)
CHECK (VALUE ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$');

CREATE DOMAIN iso_country_alpha2 AS CHAR(2)
CHECK (VALUE ~ '^[A-Z]{2}$');
```

---

## 4. Production Reference Implementation: TypeScript & SQL

Below is a complete, production-grade TypeScript implementation of the `AgenticDatabaseConstraintEngine`, providing two-phase migration SQL synthesis, ternary logic safety analysis, mutually exclusive invariant generators, and database constraint auditing:

```typescript
import { z } from 'zod';

export interface CheckConstraintDefinition {
  tableName: string;
  constraintName: string;
  predicate: string;
  nullableColumnsTested?: string[];
  isTwoPhase?: boolean;
}

export interface MutuallyExclusiveDefinition {
  tableName: string;
  constraintName: string;
  columns: string[];
  allowNone?: boolean;
}

export interface StateDependentDefinition {
  tableName: string;
  constraintName: string;
  stateColumn: string;
  stateValue: string;
  requiredWhenActive: string[];
  nullWhenInactive: string[];
}

export interface ConstraintValidationResult {
  isValid: boolean;
  warnings: string[];
  errors: string[];
  generatedSql: string[];
}

export class AgenticDatabaseConstraintEngine {
  /**
   * Generates a safe, zero-downtime two-phase migration script for adding a CHECK constraint.
   */
  public static generateTwoPhaseCheckConstraint(def: CheckConstraintDefinition): ConstraintValidationResult {
    const warnings: string[] = [];
    const errors: string[] = [];

    // Verify constraint name length (PostgreSQL 63 byte limit)
    if (def.constraintName.length > 63) {
      errors.push(`Constraint name '${def.constraintName}' exceeds PostgreSQL 63-character limit (${def.constraintName.length} chars)`);
    }

    // Check for volatile temporal functions
    const volatilePattern = /\b(now\(\)|current_timestamp|current_date|current_time|random\(\))\b/i;
    if (volatilePattern.test(def.predicate)) {
      errors.push(`Predicate contains non-immutable/volatile function (${def.predicate}). PostgreSQL forbids volatile functions in CHECK constraints.`);
    }

    // Check for ternary logic NULL bypass risk
    if (def.nullableColumnsTested && def.nullableColumnsTested.length > 0) {
      for (const col of def.nullableColumnsTested) {
        const nullCheckPattern = new RegExp(`\\b${col}\\s+(is\\s+not\\s+null|is\\s+null)\\b`, 'i');
        if (!nullCheckPattern.test(def.predicate)) {
          warnings.push(
            `Column '${col}' is tested in CHECK constraint without explicit NULL guard. In SQL 3-valued logic, NULL evaluates to UNKNOWN and passes the constraint!`
          );
        }
      }
    }

    const step1 = [
      `-- Phase 1: Register constraint with NOT VALID (instant catalog lock)`,
      `ALTER TABLE ${def.tableName}`,
      `  ADD CONSTRAINT ${def.constraintName}`,
      `  CHECK (${def.predicate})`,
      `  NOT VALID;`,
    ].join('\n');

    const step2 = [
      `-- Phase 2: Asynchronously validate constraint on historical rows (SHARE UPDATE EXCLUSIVE, non-blocking)`,
      `ALTER TABLE ${def.tableName}`,
      `  VALIDATE CONSTRAINT ${def.constraintName};`,
    ].join('\n');

    return {
      isValid: errors.length === 0,
      warnings,
      errors,
      generatedSql: [step1, step2],
    };
  }

  /**
   * Generates a mutually exclusive column check constraint using PostgreSQL num_nonnulls().
   */
  public static generateMutuallyExclusiveCheck(def: MutuallyExclusiveDefinition): ConstraintValidationResult {
    const errors: string[] = [];
    if (def.columns.length < 2) {
      errors.push('Mutually exclusive check requires at least 2 columns');
    }

    const targetCount = def.allowNone ? '<= 1' : '= 1';
    const cols = def.columns.join(', ');
    const predicate = `num_nonnulls(${cols}) ${targetCount}`;

    return this.generateTwoPhaseCheckConstraint({
      tableName: def.tableName,
      constraintName: def.constraintName,
      predicate,
    });
  }

  /**
   * Generates a state-machine dependent constraint (e.g. status = 'refunded' requires refunded_at).
   */
  public static generateStateDependentCheck(def: StateDependentDefinition): ConstraintValidationResult {
    const activeReqs = def.requiredWhenActive.map((col) => `${col} IS NOT NULL`).join(' AND ');
    const inactiveNulls = def.nullWhenInactive.map((col) => `${col} IS NULL`).join(' AND ');

    const predicate = [
      `(${def.stateColumn} = '${def.stateValue}' AND ${activeReqs})`,
      `(${def.stateColumn} != '${def.stateValue}' AND ${inactiveNulls})`,
    ].join(' OR ');

    return this.generateTwoPhaseCheckConstraint({
      tableName: def.tableName,
      constraintName: def.constraintName,
      predicate,
    });
  }

  /**
   * Returns a diagnostic SQL query to introspect all unvalidated or risky constraints.
   */
  public static getIntrospectionQuery(): string {
    return `
      SELECT
        c.conrelid::regclass AS table_name,
        c.conname AS constraint_name,
        c.contype AS constraint_type,
        c.convalidated AS is_validated,
        pg_get_constraintdef(c.oid) AS constraint_definition
      FROM pg_constraint c
      JOIN pg_namespace n ON n.oid = c.connamespace
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND c.contype IN ('c', 'f')
      ORDER BY c.convalidated ASC, c.conrelid::regclass::text;
    `.trim();
  }
}
```

---

## 5. Constraint Lifecycle Finite-State Machine (FSM)

Check constraints and domain types progress through an explicit 6-state lifecycle:

```
[ 1. DRAFTED ]
      |
      | (Static AST validation, immutability & 3VL ternary logic audit)
      v
[ 2. METADATA_ATTACHED ]  <--- ALTER TABLE ... ADD CONSTRAINT ... NOT VALID
      |
      | (Sub-millisecond catalog lock released, writes unblocked)
      v
[ 3. BACKGROUND_VALIDATING ] <--- ALTER TABLE ... VALIDATE CONSTRAINT (SHARE UPDATE EXCLUSIVE)
      |
      +--------------------------------------+
      |                                      |
      | (All historical rows satisfy P)      | (Violation detected: SQLSTATE 23514)
      v                                      v
[ 4. ENFORCED_VALID ]                  [ 5. REMEDIATION_REQUIRED ]
      |                                      |
      | (Schema evolution / deprecation)     | (Data backfill / quarantine)
      v                                      |
[ 6. RETIRED_DROPPED ] <---------------------+
```

| State | Permitted Operations | Concurrency Lock | Failure Remediation |
| :--- | :--- | :--- | :--- |
| `DRAFTED` | Local linting, SQL synthesis | None | Abort migration generation if volatile functions detected |
| `METADATA_ATTACHED` | New writes enforced; old rows unvalidated | Brief `ACCESS EXCLUSIVE` ($< 10\text{ms}$) | Drop constraint if application errors on new writes |
| `BACKGROUND_VALIDATING` | Full table scan of historical tuples | `SHARE UPDATE EXCLUSIVE` (Writes normal) | Retry validation if cancelled by timeout |
| `ENFORCED_VALID` | Complete relational integrity guaranteed | None (Standard operation) | Monitor performance via `pg_stat_user_tables` |
| `REMEDIATION_REQUIRED` | Historical invalid records identified | None | Backfill or clean dirty tuples before re-validating |
| `RETIRED_DROPPED` | `ALTER TABLE ... DROP CONSTRAINT` | `ACCESS EXCLUSIVE` (Brief) | Ensure no queries depend on constraint logic |

---

## 6. Machine-Verifiable Definition of Done (DoD)

Autonomous agents must satisfy all 6 gates before marking constraint changes complete:

- [ ] **Gate 1: Zero Synchronous Full-Table Lockouts (`NOT VALID` Verification)**:
  Every newly added `CHECK` or `FOREIGN KEY` constraint on tables with $> 1,000$ rows is added via `NOT VALID` followed by `VALIDATE CONSTRAINT`. Zero bare `ADD CONSTRAINT ... CHECK` without `NOT VALID`.
- [ ] **Gate 2: Explicit Three-Valued Logic & Null Invariance**:
  Every check constraint on a nullable column explicitly uses `IS NULL OR` or is accompanied by an explicit `NOT NULL` constraint. No implicit reliance on ternary SQL logic to filter `NULL`s.
- [ ] **Gate 3: Anti-Native-ENUM Invariance**:
  Dynamic or frequently evolving states use Lookup / Reference tables with foreign keys. Static sets use `VARCHAR(32)` or `TEXT` with validated check constraints. Zero raw `CREATE TYPE ... AS ENUM` with expected future additions inside transaction blocks.
- [ ] **Gate 4: Mutually Exclusive & State-Dependent Invariants**:
  Polymorphic or mutually exclusive references enforce `CHECK (num_nonnulls(...) = 1)`. State-dependent columns (e.g. `refunded_at`) have explicit paired conditions matching their triggering status.
- [ ] **Gate 5: Constraint Immutability & Determinism**:
  All expressions in check constraints are strictly `IMMUTABLE`. Zero calls to `now()`, `CURRENT_TIMESTAMP`, or volatile functions. Regexes are anchored and linear-time.
- [ ] **Gate 6: CI Catalog Introspection Cleanliness**:
  Continuous integration verifies `SELECT COUNT(*) FROM pg_constraint WHERE NOT convalidated` reaches 0 after migration completion, with zero constraint violations (`SQLSTATE 23514`).
