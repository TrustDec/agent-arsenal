---
description: PostgreSQL Column Tetris, data type memory alignment, 8-byte word padding elimination, heap tuple header sizing, NULL bitmap packing, varlena tail layout, and zero-downtime table compaction across Go (pgx/sqlc), TypeScript (Drizzle, Prisma, Kysely), Python (SQLAlchemy), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{schema,migration,column,tetris,alignment,padding,tuple,table,model,entity}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/models/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs},**/migrations/**/*.{sql,ts,go}
alwaysApply: false
---

# Agentic Database Column Tetris, Data Type Alignment, 8-Byte Word Padding & Heap Tuple Layout Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design relational database schemas, DDL migrations, ORM entities, and high-throughput table models across PostgreSQL, Go (`jackc/pgx`, `sqlc`), TypeScript (`Drizzle`, `Prisma`, `Kysely`), Python (`SQLAlchemy 2.0`), or Rust (`sqlx`). Eliminate the "Naive Column Ordering & 8-Byte Word Alignment Padding Trap" (where declaring columns in semantic or alphabetical order forces PostgreSQL to inject 2 to 7 zero-padding bytes between mismatched attributes, inflating physical tuple size by 20% to 50% and wasting gigabytes of RAM in `shared_buffers`), the "Heap Tuple Header & Null Bitmap (t_bits) Padding Boundary Trap" (where crossing an 8-column nullable threshold unexpectedly balloons the 23-byte `HeapTupleHeaderData` by 8 bytes due to `MAXALIGN` padding), the "Varlena 1-Byte vs 4-Byte Header & Tail Alignment Trap" (where interleaving variable-length `text` or `varchar` before fixed 8-byte types ruins fixed-offset CPU memory reads and forces unpredictable mid-row padding), the "Shared Buffers Eviction & Scan I/O Amplification Disaster" (where padded tuples drastically reduce the number of rows packed per 8KB disk page, causing sequential scans and index-guided heap fetches to burn 30% to 50% more IOPS and prematurely evict working sets from memory), the "CPU L1/L2 Cache Line Crossing & Serialization Stall" (where unnecessarily bloated tuples straddle multiple 64-byte hardware cache lines, incurring double memory bus stalls during intensive analytical filtering), and the "`ALTER TABLE ADD COLUMN` Physical Catalog Lock-In" (where appending new columns physically positions them at the tail of `pg_attribute`, permanently entrenching layout fragmentation) by establishing a strict 5-Tier Column Tetris Governance Ladder, descending alignment theorems ($P_i = 0$), production TypeScript layout engines, and machine-verifiable CI DDL gates.

---

## 1. Architectural Taxonomy: The 6 Tuple Layout Catastrophes vs The 5-Tier Column Tetris Governance Ladder

PostgreSQL stores table rows as physical C structs on 8KB disk pages. Every hardware architecture (x86_64, ARM64) mandates that CPU instructions read words on memory boundaries divisible by their size. In PostgreSQL, `MAXALIGN` is 8 bytes on 64-bit platforms. When an autonomous coding agent designs a table naively, the database engine quietly injects invisible dead bytes:

```typescript
// ❌ CATASTROPHIC LLM SCHEMA DEFINITION (24 BYTES OF DEAD PADDING PER ROW!)
// An autonomous agent creates a standard SaaS user event log table:
// Notice how columns are organized semantically:
/*
CREATE TABLE user_audit_events (
    id              BIGINT PRIMARY KEY, -- 8 bytes (Offset: 0..7)
    is_success      BOOLEAN NOT NULL,   -- 1 byte  (Offset: 8)
    -- ❌ PADDING: 7 DEAD BYTES inserted here to align next 8-byte column! (Offset: 9..15)
    created_at      TIMESTAMPTZ NOT NULL, -- 8 bytes (Offset: 16..23)
    is_internal     BOOLEAN NOT NULL,   -- 1 byte  (Offset: 24)
    -- ❌ PADDING: 7 DEAD BYTES inserted here! (Offset: 25..31)
    processed_at    TIMESTAMPTZ,        -- 8 bytes (Offset: 32..39)
    retry_count     SMALLINT NOT NULL,  -- 2 bytes (Offset: 40..41)
    -- ❌ PADDING: 2 DEAD BYTES inserted here to align 4-byte int! (Offset: 42..43)
    tenant_id       INT NOT NULL,       -- 4 bytes (Offset: 44..47)
    is_billable     BOOLEAN NOT NULL,   -- 1 byte  (Offset: 48)
    -- ❌ PADDING: 7 DEAD BYTES inserted here to align 8-byte bigint! (Offset: 49..55)
    cost_microcents BIGINT NOT NULL,    -- 8 bytes (Offset: 56..63)
    payload_hash    CHAR(32) NOT NULL   -- 32 bytes (Offset: 64..95)
);
-- ❌ Total User Data: 72 bytes.
-- ❌ Total Dead Padding Wasted: 23 bytes (over 24% of the entire row is PURE ZERO-FILL AIR!).
-- On a 100,000,000 row table: 2.3 GB of dead RAM in shared_buffers and 2.3 GB of dead disk!
*/

// ✅ THE COLUMN TETRIS CURE: SORTED BY STRICT DESCENDING ALIGNMENT
/*
CREATE TABLE user_audit_events_optimized (
    -- GROUP 1: Fixed 8-Byte Types (typalign = 'd', attlen = 8) -> 0 padding!
    id              BIGINT PRIMARY KEY,   -- 8 bytes (Offset: 0..7)
    created_at      TIMESTAMPTZ NOT NULL, -- 8 bytes (Offset: 8..15)
    processed_at    TIMESTAMPTZ,          -- 8 bytes (Offset: 16..23)
    cost_microcents BIGINT NOT NULL,      -- 8 bytes (Offset: 24..31)

    -- GROUP 2: Fixed 4-Byte Types (typalign = 'i', attlen = 4) -> 0 padding!
    tenant_id       INT NOT NULL,         -- 4 bytes (Offset: 32..35)

    -- GROUP 3: Fixed 2-Byte Types (typalign = 's', attlen = 2) -> 0 padding!
    retry_count     SMALLINT NOT NULL,    -- 2 bytes (Offset: 36..37)

    -- GROUP 4: Fixed 1-Byte Types (typalign = 'c', attlen = 1) -> 0 padding!
    is_success      BOOLEAN NOT NULL,     -- 1 byte  (Offset: 38)
    is_internal     BOOLEAN NOT NULL,     -- 1 byte  (Offset: 39)
    is_billable     BOOLEAN NOT NULL,     -- 1 byte  (Offset: 40)

    -- GROUP 5: Fixed/Var Array / Character Types
    payload_hash    CHAR(32) NOT NULL     -- 32 bytes (Offset: 41..72)
    -- Tail MAXALIGN padding: (8 - (73 % 8)) % 8 = 7 bytes padding at end
);
-- ✅ Saved 16 bytes per row! Tuple density per 8KB page increases by 21.6%!
-- Sequential scans run 20% faster; shared_buffers holds 21% more active rows!
*/
```

### The 6 Tuple Layout Catastrophes

1. **The Naive Column Ordering & 8-Byte Word Alignment Padding Trap**:
   - PostgreSQL requires attributes to begin at memory addresses matching their `typalign`:
     - `'d'` (double/8-byte): `BIGINT`, `TIMESTAMPTZ`, `TIMESTAMP`, `DOUBLE PRECISION`, `FLOAT8`, `INTERVAL`. Must align to multiple of 8.
     - `'i'` (int/4-byte): `INTEGER`, `DATE`, `REAL`, `FLOAT4`, `OID`, `INET`. Must align to multiple of 4.
     - `'s'` (short/2-byte): `SMALLINT`, `INT2`. Must align to multiple of 2.
     - `'c'` (char/1-byte): `BOOLEAN`, `CHAR(1)`, `"char"`. No alignment constraint (1 byte).
   - Placing a 1-byte `BOOLEAN` immediately followed by an 8-byte `BIGINT` forces PostgreSQL to pad 7 zero-bytes. Repeating this across several columns wastes up to 30–40 bytes per row.

2. **The Heap Tuple Header & Null Bitmap (`t_bits`) Padding Boundary Trap**:
   - Every physical tuple in PostgreSQL begins with `HeapTupleHeaderData` (23 bytes):
     - `t_xmin` (4B), `t_xmax` (4B), `t_cid/t_xvac` (4B), `t_ctid` (6B), `t_infomask2` (2B), `t_infomask` (2B), `t_hoff` (1B) = 23 bytes.
   - If ALL columns are declared `NOT NULL`, there is no null bitmap. However, the tuple data must start on a `MAXALIGN` (8-byte) boundary. Byte 23 is padded with 1 byte to reach 24 bytes (`t_hoff = 24`).
   - If ANY column is nullable, a null bitmap is present. The bitmap uses 1 bit per column:
     - 1 to 8 nullable columns: 1 byte bitmap. $23 + 1 = 24$ bytes (perfect 8-byte alignment, 0 padding).
     - 9 to 16 nullable columns: 2 byte bitmap. $23 + 2 = 25$ bytes. To reach `MAXALIGN = 8`, PostgreSQL pads **7 dead bytes** to reach 32 bytes (`t_hoff = 32`)!
   - Unaware agents who arbitrarily add a 9th nullable column instantly penalize every single row in the table with 7 extra bytes of header padding.

3. **The Varlena 1-Byte vs 4-Byte Header & Tail Alignment Trap**:
   - Variable-length types (`TEXT`, `VARCHAR`, `JSONB`, `BYTEA`, `NUMERIC`) use `varlena` structures.
   - Short strings ($\le 126$ bytes) use a 1-byte header (`typalign = 'c'`). Long strings use a 4-byte header (`typalign = 'i'`).
   - If variable-length attributes are placed in the middle of a schema before fixed 8-byte columns, the physical offset of subsequent columns becomes variable and requires dynamic run-time padding checks.
   - Placing all variable-length columns at the TAIL of the tuple layout guarantees that all preceding fixed-width columns sit at deterministic, compile-time static byte offsets, maximizing CPU instruction cache efficiency.

4. **The Shared Buffers Eviction & Scan I/O Amplification Disaster**:
   - PostgreSQL reads and writes data in 8192-byte disk pages (`shared_buffers`).
   - The number of tuples per page is:
     $$N_{\text{tuples}} = \left\lfloor \frac{8192 - \text{SizeOf}(PageHeaderData)}{S_{\text{tuple}} + \text{SizeOf}(ItemIdData)} \right\rfloor = \left\lfloor \frac{8168}{S_{\text{tuple}} + 4} \right\rfloor$$
   - Inflating $S_{\text{tuple}}$ from 72 bytes to 96 bytes drops tuple density from 107 tuples/page down to 81 tuples/page (a 24.3% loss).
   - A sequential scan or bitmap index scan over 100M rows must read 1,234,567 pages instead of 934,579 pages—burning 300,000 additional disk I/O reads (2.45 GB) and displacing active working sets from `shared_buffers`.

5. **The CPU L1/L2 Cache Line Crossing & Memory Bus Serialization Stall**:
   - Modern server CPUs (AMD EPYC, Intel Xeon, AWS Graviton) load memory into 64-byte L1 cache lines.
   - When a tuple is compact ($\le 64$ bytes), it often fits inside a single cache line. Evaluating `WHERE` filter predicates requires 1 memory fetch.
   - When padding bloats the tuple across cache line boundaries, the CPU memory controller must issue 2 separate cache-line transactions per tuple. In high-frequency analytical queries processing millions of rows per second, memory bus bandwidth becomes the hard bottleneck.

6. **The `ALTER TABLE ADD COLUMN` Physical Catalog Lock-In**:
   - In PostgreSQL, running `ALTER TABLE ADD COLUMN` always appends the new column to the END of physical tuple storage in `pg_attribute.attnum`, regardless of where it appears in application ORMs.
   - If an agent repeatedly adds columns over time (e.g., adding a `BIGINT` after previously added `TEXT` or `BOOLEAN` columns), the physical disk layout degenerates into a severely fragmented state with maximum padding holes.
   - Only a zero-downtime shadow table swap (`pg_repack` or expand-contract rotation) can physically reorder the tuple layout.

---

### The 5-Tier Column Tetris Governance Ladder

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 5-TIER COLUMN TETRIS & TUPLE LAYOUT GOVERNANCE LADDER                       │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 4: Autonomous CI DDL AST Linting & Catalog Sizing Sentinels            │
│         - Static analysis in CI: fail if DDL has internal padding > 0 bytes  │
│         - Continuous pg_attribute inspection & bloat alerting               │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Zero-Downtime Table Compaction & Shadow Swap Migration              │
│         - Expand-contract rotation or pg_repack for bloated live relations  │
│         - Sub-second lock_timeout atomic rename swap                        │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Varlena Tail Positioning & Fixed-Offset CPU Acceleration           │
│         - All variable-length types (TEXT, JSONB, VARCHAR) placed at TAIL   │
│         - Deterministic static byte offsets for fixed OLTP columns          │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Null Bitmap Alignment & Bit-Packing Invariants                     │
│         - Pack booleans into bitmasks / bit(n) when > 8 flags exist         │
│         - Bound nullable columns to 8-bit boundaries; prevent 7B jumps      │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Decreasing Alignment Invariant (Zero Internal Padding)              │
│         - Strict ordering: 8-Byte -> 4-Byte -> 2-Byte -> 1-Byte             │
│         - Guarantees internal padding Pi = 0 for 100% of fixed columns      │
└─────────────────────────────────────────────────────────────────────────────┘
```

| Governance Tier | Strategy | Implementation | Benefit | Failure Mode Prevented |
| :--- | :--- | :--- | :--- | :--- |
| **Tier 0** | **Decreasing Alignment Invariant** | 8B (`bigint`, `timestamptz`) $\to$ 4B (`int`, `date`) $\to$ 2B (`smallint`) $\to$ 1B (`bool`, `char`) | Zero internal padding bytes between columns ($P_i = 0$) | 20%–50% silent physical disk and RAM bloat |
| **Tier 1** | **Null Bitmap Sizing & Bit-Packing** | Coalesce $>8$ booleans into `bit(n)` or integer flags; bound nullables | Prevents sudden 7-byte `HeapTupleHeaderData` `MAXALIGN` padding leaps | Unexpected 8-byte jump from 24B to 32B tuple header |
| **Tier 2** | **Varlena Tail Positioning** | Place `text`, `varchar`, `jsonb`, `bytea` at very end of table DDL | Fixed compile-time static offsets for all fixed-width fields | Jittery runtime byte alignment and offset arithmetic |
| **Tier 3** | **Zero-Downtime Table Compaction** | Reorder legacy tables via shadow table swap or `pg_repack` under `lock_timeout = '2s'` | Reclaims gigabytes of disk and buffer cache without downtime | `ALTER TABLE ADD COLUMN` permanent layout fragmentation |
| **Tier 4** | **CI DDL Linting & Catalog Sentinels** | CI AST linter rejecting unaligned DDL migrations; `pg_attribute` sentinels | 100% of production tables adhere to Column Tetris layout | Regressive unaligned DDL merged by junior developers or agents |

---

## 2. Mathematical Invariants & Physical Tuple Physics Models

### 1. Exact Heap Tuple Sizing Equation

A PostgreSQL heap tuple size $S_{\text{tuple}}$ for a relation with $M$ attributes is formally defined by:

$$S_{\text{tuple}} = \text{MAXALIGN}(H_{\text{header}} + B_{\text{null}}) + \sum_{i=1}^{M} (S_i + P_i)$$

Where:
- $H_{\text{header}} = 23\text{ bytes}$ (`sizeof(HeapTupleHeaderData)`).
- $B_{\text{null}} = \begin{cases} 0 & \text{if all columns are NOT NULL} \\ \left\lceil \frac{K_{\text{nullable}}}{8} \right\rceil & \text{if } K_{\text{nullable}} > 0 \end{cases}$
- $\text{MAXALIGN}(x) = \left\lceil \frac{x}{8} \right\rceil \times 8$ on 64-bit architectures.
- $S_i$ is the physical size of attribute $i$.
- $P_i$ is the padding bytes inserted before attribute $i$ to satisfy its hardware alignment constraint:
  $$P_i = (\text{Align}_i - (\text{Offset}_i \bmod \text{Align}_i)) \bmod \text{Align}_i$$
  where $\text{Align}_i \in \{8, 4, 2, 1\}$ and $\text{Offset}_i$ is the running byte offset after attribute $i-1$.

---

### 2. The Column Tetris Zero-Padding Theorem

**Theorem**: Let a relation schema have $M$ fixed-length attributes sorted in non-increasing order of their alignment constraints:

$$\text{Align}_1 \ge \text{Align}_2 \ge \dots \ge \text{Align}_M, \quad \text{where } \text{Align}_i \in \{8, 4, 2, 1\}$$

If the initial data offset $\text{Offset}_1$ is aligned to $\text{MAXALIGN} = 8$ (guaranteed by $\text{MAXALIGN}(H_{\text{header}} + B_{\text{null}})$), then the internal padding before every attribute is identically zero:

$$\forall i \in \{1, \dots, M\}: P_i = 0$$

**Proof**:
1. Base case ($i=1$): $\text{Offset}_1 \equiv 0 \pmod 8$. Since $\text{Align}_1 \le 8$ and $8$ is divisible by $\text{Align}_1 \in \{8, 4, 2, 1\}$, $\text{Offset}_1 \equiv 0 \pmod{\text{Align}_1}$. Thus $P_1 = 0$.
2. Inductive step: Assume $\text{Offset}_k \equiv 0 \pmod{\text{Align}_k}$.
   The next attribute offset is $\text{Offset}_{k+1} = \text{Offset}_k + S_k$.
   For standard PostgreSQL types, the fixed size $S_k$ is always an integer multiple of its alignment $\text{Align}_k$ (e.g., `BIGINT`: size 8, align 8; `INT`: size 4, align 4; `SMALLINT`: size 2, align 2; `CHAR(N)`: size $N$, align 1).
   Therefore, $\text{Offset}_{k+1} \equiv 0 \pmod{\text{Align}_k}$.
   Since the sequence is sorted in non-increasing order, $\text{Align}_{k+1}$ divides $\text{Align}_k$ (because $8 \mid 8$, $4 \mid 8$, $2 \mid 4$, $1 \mid 2$).
   Since $\text{Offset}_{k+1}$ is a multiple of $\text{Align}_k$, it is necessarily a multiple of $\text{Align}_{k+1}$:
   $$\text{Offset}_{k+1} \equiv 0 \pmod{\text{Align}_{k+1}} \implies P_{k+1} = 0$$
   By induction, $P_i = 0$ for all $i \in \{1, \dots, M\}$. $\blacksquare$

---

### 3. Page Packing Density & I/O Reduction Calculus

The number of tuples stored per standard 8192-byte page is:

$$N_{\text{tuples/page}} = \left\lfloor \frac{8192 - 24}{S_{\text{tuple}} + 4} \right\rfloor = \left\lfloor \frac{8168}{S_{\text{tuple}} + 4} \right\rfloor$$

(where 24 bytes is `PageHeaderData` and 4 bytes is `ItemIdData` pointer per tuple).

If naive column ordering produces $S_{\text{naive}} = 92\text{ bytes}$ and Column Tetris produces $S_{\text{tetris}} = 68\text{ bytes}$:
- $N_{\text{naive}} = \lfloor 8168 / 96 \rfloor = 85\text{ tuples/page}$
- $N_{\text{tetris}} = \lfloor 8168 / 72 \rfloor = 113\text{ tuples/page}$

The Page Packing Efficiency Gain is:

$$\mathcal{G}_{\text{packing}} = \frac{N_{\text{tetris}} - N_{\text{naive}}}{N_{\text{naive}}} = \frac{113 - 85}{85} = +32.9\%$$

For a table of $N = 10^8$ rows:
- Pages required (Naive): $\frac{10^8}{85} \approx 1,176,470\text{ pages} \approx 9.64\text{ GB}$
- Pages required (Tetris): $\frac{10^8}{113} \approx 884,955\text{ pages} \approx 7.25\text{ GB}$
- **Net Storage & Shared Buffers Reclaimed**: $\mathbf{2.39\text{ GB}}$ ($>24\%$ memory & disk savings for the lifetime of the database).

---

## 3. Production Engine: TypeScript Implementation

```typescript
/**
 * AgenticDatabaseColumnTetrisEngine
 * 
 * Production-grade engine that audits PostgreSQL schemas for 8-byte word padding bloat,
 * computes exact tuple storage layouts, executes the Column Tetris reordering algorithm,
 * and generates zero-downtime shadow table migration DDL.
 */

export interface ColumnDefinition {
  name: string;
  dataType: string;
  isNullable: boolean;
  defaultValue?: string;
  isPrimaryKey?: boolean;
}

export interface AlignmentMetadata {
  alignBytes: 8 | 4 | 2 | 1;
  fixedLength: number; // -1 for varlena / dynamic
  isVarlena: boolean;
}

export interface ColumnLayoutAudit {
  name: string;
  dataType: string;
  alignBytes: number;
  sizeBytes: number;
  offsetBefore: number;
  paddingBytes: number;
  offsetAfter: number;
}

export interface TableLayoutAuditResult {
  tableName: string;
  headerSizeBytes: number;
  userSizeBytes: number;
  totalPaddingBytes: number;
  totalTupleSizeBytes: number;
  paddingWasteRatioPercent: number;
  tuplesPerPage: number;
  pagesPerMillionRows: number;
  columnsAudit: ColumnLayoutAudit[];
}

export class AgenticDatabaseColumnTetrisEngine {
  // Mapping PostgreSQL data types to hardware alignment and byte length
  private static readonly TYPE_ALIGNMENT_MAP: Record<string, AlignmentMetadata> = {
    // 8-byte alignment (typalign = 'd')
    bigint: { alignBytes: 8, fixedLength: 8, isVarlena: false },
    int8: { alignBytes: 8, fixedLength: 8, isVarlena: false },
    timestamptz: { alignBytes: 8, fixedLength: 8, isVarlena: false },
    timestamp: { alignBytes: 8, fixedLength: 8, isVarlena: false },
    'timestamp with time zone': { alignBytes: 8, fixedLength: 8, isVarlena: false },
    'timestamp without time zone': { alignBytes: 8, fixedLength: 8, isVarlena: false },
    'double precision': { alignBytes: 8, fixedLength: 8, isVarlena: false },
    float8: { alignBytes: 8, fixedLength: 8, isVarlena: false },
    interval: { alignBytes: 8, fixedLength: 16, isVarlena: false },

    // 4-byte alignment (typalign = 'i')
    integer: { alignBytes: 4, fixedLength: 4, isVarlena: false },
    int: { alignBytes: 4, fixedLength: 4, isVarlena: false },
    int4: { alignBytes: 4, fixedLength: 4, isVarlena: false },
    date: { alignBytes: 4, fixedLength: 4, isVarlena: false },
    real: { alignBytes: 4, fixedLength: 4, isVarlena: false },
    float4: { alignBytes: 4, fixedLength: 4, isVarlena: false },
    oid: { alignBytes: 4, fixedLength: 4, isVarlena: false },
    inet: { alignBytes: 4, fixedLength: -1, isVarlena: true },

    // 2-byte alignment (typalign = 's')
    smallint: { alignBytes: 2, fixedLength: 2, isVarlena: false },
    int2: { alignBytes: 2, fixedLength: 2, isVarlena: false },

    // 1-byte alignment (typalign = 'c')
    boolean: { alignBytes: 1, fixedLength: 1, isVarlena: false },
    bool: { alignBytes: 1, fixedLength: 1, isVarlena: false },
    char: { alignBytes: 1, fixedLength: 1, isVarlena: false },
    bpchar: { alignBytes: 1, fixedLength: -1, isVarlena: true },

    // Special fixed types
    uuid: { alignBytes: 1, fixedLength: 16, isVarlena: false }, // uuid in Postgres is 16 bytes, align 'c'

    // Variable length types (varlena - attlen = -1, typalign = 'i')
    text: { alignBytes: 4, fixedLength: -1, isVarlena: true },
    varchar: { alignBytes: 4, fixedLength: -1, isVarlena: true },
    'character varying': { alignBytes: 4, fixedLength: -1, isVarlena: true },
    jsonb: { alignBytes: 4, fixedLength: -1, isVarlena: true },
    json: { alignBytes: 4, fixedLength: -1, isVarlena: true },
    bytea: { alignBytes: 4, fixedLength: -1, isVarlena: true },
    numeric: { alignBytes: 4, fixedLength: -1, isVarlena: true },
  };

  /**
   * Resolve type alignment metadata. Fallback to 4-byte varlena for unknown complex types.
   */
  public static getTypeMetadata(dataType: string): AlignmentMetadata {
    const normalized = dataType.toLowerCase().trim().replace(/\(.*\)/, '');
    return (
      this.TYPE_ALIGNMENT_MAP[normalized] ?? {
        alignBytes: 4,
        fixedLength: -1,
        isVarlena: true,
      }
    );
  }

  /**
   * Audit physical tuple padding of a schema.
   */
  public static auditLayout(tableName: string, columns: ColumnDefinition[]): TableLayoutAuditResult {
    const nullableCount = columns.filter((c) => c.isNullable).length;
    
    // Header calculation: 23B + null bitmap, padded to MAXALIGN (8)
    const nullBitmapBytes = nullableCount > 0 ? Math.ceil(nullableCount / 8) : 0;
    const rawHeader = 23 + nullBitmapBytes;
    const headerSizeBytes = Math.ceil(rawHeader / 8) * 8; // MAXALIGN

    let currentOffset = headerSizeBytes;
    let totalPadding = 0;
    let userDataSize = 0;
    const columnsAudit: ColumnLayoutAudit[] = [];

    for (const col of columns) {
      const meta = this.getTypeMetadata(col.dataType);
      const align = meta.alignBytes;
      const size = meta.fixedLength > 0 ? meta.fixedLength : 8; // Assume 8B average for varlena in sizing

      // Compute padding required to align this column
      const remainder = currentOffset % align;
      const padding = remainder === 0 ? 0 : align - remainder;

      totalPadding += padding;
      userDataSize += size;

      const offsetBefore = currentOffset;
      const offsetAfter = currentOffset + padding + size;
      currentOffset = offsetAfter;

      columnsAudit.push({
        name: col.name,
        dataType: col.dataType,
        alignBytes: align,
        sizeBytes: size,
        offsetBefore,
        paddingBytes: padding,
        offsetAfter,
      });
    }

    // Tail MAXALIGN padding: PostgreSQL pads the total tuple size to a multiple of 8
    const tailRemainder = currentOffset % 8;
    const tailPadding = tailRemainder === 0 ? 0 : 8 - tailRemainder;
    totalPadding += tailPadding;
    currentOffset += tailPadding;

    const totalTupleSizeBytes = currentOffset;
    const paddingWasteRatioPercent = Math.round((totalPadding / totalTupleSizeBytes) * 10000) / 100;

    // 8192 page minus 24B page header, tuple requires 4B ItemIdData pointer
    const tuplesPerPage = Math.floor(8168 / (totalTupleSizeBytes + 4));
    const pagesPerMillionRows = Math.ceil(1_000_000 / tuplesPerPage);

    return {
      tableName,
      headerSizeBytes,
      userSizeBytes: userDataSize,
      totalPaddingBytes: totalPadding,
      totalTupleSizeBytes,
      paddingWasteRatioPercent,
      tuplesPerPage,
      pagesPerMillionRows,
      columnsAudit,
    };
  }

  /**
   * The Column Tetris Algorithm:
   * Sort columns strictly by descending alignment requirement:
   * 1. Fixed 8-Byte types (typalign = 'd', length = 8 or 16)
   * 2. Fixed 4-Byte types (typalign = 'i', length = 4)
   * 3. Fixed 2-Byte types (typalign = 's', length = 2)
   * 4. Fixed 1-Byte types (typalign = 'c', length = 1)
   * 5. Fixed composite/UUID types (length > 0, align 1)
   * 6. Variable length types (varlena, length = -1)
   */
  public static optimizeColumnOrder(columns: ColumnDefinition[]): ColumnDefinition[] {
    return [...columns].sort((a, b) => {
      const metaA = this.getTypeMetadata(a.dataType);
      const metaB = this.getTypeMetadata(b.dataType);

      // Rule 1: Fixed length columns MUST precede variable-length (varlena) columns
      if (!metaA.isVarlena && metaB.isVarlena) return -1;
      if (metaA.isVarlena && !metaB.isVarlena) return 1;

      // Rule 2: Higher alignment comes first (8 -> 4 -> 2 -> 1)
      if (metaA.alignBytes !== metaB.alignBytes) {
        return metaB.alignBytes - metaA.alignBytes;
      }

      // Rule 3: For identical alignment, larger fixed lengths first
      if (metaA.fixedLength !== metaB.fixedLength) {
        return metaB.fixedLength - metaA.fixedLength;
      }

      // Rule 4: Stable alphabetical order for ties
      return a.name.localeCompare(b.name);
    });
  }

  /**
   * Generates safe zero-downtime shadow table swap migration DDL.
   */
  public static generateZeroDowntimeCompactionDDL(
    tableName: string,
    optimizedColumns: ColumnDefinition[],
    primaryKeyColumn: string
  ): string {
    const shadowTable = `${tableName}_tetris_shadow`;
    const colDefs = optimizedColumns
      .map((c) => {
        const nullClause = c.isNullable ? '' : ' NOT NULL';
        const defaultClause = c.defaultValue ? ` DEFAULT ${c.defaultValue}` : '';
        const pkClause = c.isPrimaryKey ? ' PRIMARY KEY' : '';
        return `    ${c.name.padEnd(20)} ${c.dataType}${nullClause}${defaultClause}${pkClause}`;
      })
      .join(',\n');

    const colNames = optimizedColumns.map((c) => c.name).join(', ');

    return `-- =========================================================================
-- ZERO-DOWNTIME COLUMN TETRIS SHADOW TABLE COMPACTION FOR: ${tableName}
-- Eliminates internal 8-byte word padding bloat and reclaims disk & buffer cache
-- =========================================================================

-- Phase 1: Create Shadow Table with Column Tetris Optimized Layout
CREATE TABLE ${shadowTable} (
${colDefs}
);

-- Phase 2: Deploy Dual-Write Trigger to Capture In-Flight Mutations
CREATE OR REPLACE FUNCTION tf_${shadowTable}_sync()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM ${shadowTable} WHERE ${primaryKeyColumn} = OLD.${primaryKeyColumn};
    RETURN OLD;
  ELSIF (TG_OP = 'UPDATE') THEN
    UPDATE ${shadowTable}
    SET ${optimizedColumns.map((c) => `${c.name} = NEW.${c.name}`).join(', ')}
    WHERE ${primaryKeyColumn} = OLD.${primaryKeyColumn};
    RETURN NEW;
  ELSIF (TG_OP = 'INSERT') THEN
    INSERT INTO ${shadowTable} (${colNames})
    VALUES (${optimizedColumns.map((c) => `NEW.${c.name}`).join(', ')})
    ON CONFLICT (${primaryKeyColumn}) DO UPDATE
    SET ${optimizedColumns.filter((c) => !c.isPrimaryKey).map((c) => `${c.name} = EXCLUDED.${c.name}`).join(', ')};
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_${shadowTable}_sync
AFTER INSERT OR UPDATE OR DELETE ON ${tableName}
FOR EACH ROW EXECUTE FUNCTION tf_${shadowTable}_sync();

-- Phase 3: Keyset Batch Backfill (Run via application worker in chunks of 2,000)
-- INSERT INTO ${shadowTable} (${colNames})
-- SELECT ${colNames} FROM ${tableName}
-- WHERE ${primaryKeyColumn} > $last_seen_id
-- ORDER BY ${primaryKeyColumn} ASC
-- LIMIT 2000
-- ON CONFLICT (${primaryKeyColumn}) DO NOTHING;

-- Phase 4: Atomic Sub-Second Catalog Swap under Strict Lock Timeout
-- Execute when backfill lag = 0 rows:
BEGIN;
SET LOCAL lock_timeout = '2000ms';
SET LOCAL statement_timeout = '5000ms';

DROP TRIGGER trg_${shadowTable}_sync ON ${tableName};
DROP FUNCTION tf_${shadowTable}_sync();

ALTER TABLE ${tableName} RENAME TO ${tableName}_legacy_bloated;
ALTER TABLE ${shadowTable} RENAME TO ${tableName};

COMMIT;

-- Phase 5: Drop legacy table asynchronously after verification
-- DROP TABLE ${tableName}_legacy_bloated;
`;
  }

  /**
   * Static CI Lint Gate: Asserts that a table's column ordering has 0 internal padding bytes.
   */
  public static lintTableDDL(tableName: string, columns: ColumnDefinition[]): {
    isValid: boolean;
    wastedBytes: number;
    wastedPercent: number;
    errorMessage?: string;
  } {
    const audit = this.auditLayout(tableName, columns);
    const hasInternalPadding = audit.columnsAudit.some((c) => c.paddingBytes > 0);

    if (hasInternalPadding) {
      const paddingDetails = audit.columnsAudit
        .filter((c) => c.paddingBytes > 0)
        .map((c) => `Column '${c.name}' (${c.dataType}) introduces ${c.paddingBytes} bytes of padding`)
        .join('; ');

      return {
        isValid: false,
        wastedBytes: audit.totalPaddingBytes,
        wastedPercent: audit.paddingWasteRatioPercent,
        errorMessage: `[ColumnTetris] Table '${tableName}' violates Column Tetris! ${paddingDetails}. Run optimizeColumnOrder() to eliminate bloat.`,
      };
    }

    return {
      isValid: true,
      wastedBytes: audit.totalPaddingBytes,
      wastedPercent: audit.paddingWasteRatioPercent,
    };
  }
}
```

---

## 4. The 6-State Column Tetris Lifecycle Finite-State Machine (FSM)

Every database table schema must transition through a verified 6-state lifecycle to eliminate padding bloat before reaching production:

```
┌────────────────────┐     CI AST Lint      ┌────────────────────┐
│  ANALYSIS_PENDING  │ ───────────────────> │  PADDING_DETECTED  │
└────────────────────┘                      └────────────────────┘
                                                       │
                                                       │ Sort by Descending Alignment
                                                       ▼
┌────────────────────┐   Keyset Backfill    ┌────────────────────┐
│   SHADOW_SYNCED    │ <─────────────────── │   TETRIS_SORTED    │
└────────────────────┘                      └────────────────────┘
          │
          │ SET LOCAL lock_timeout = '2s' (Atomic Swap)
          ▼
┌────────────────────┐    amcheck / I/O     ┌────────────────────┐
│   ATOMIC_SWAPPED   │ ───────────────────> │  OPTIMIZED_COMPACT │
└────────────────────┘                      └────────────────────┘
```

1. **`ANALYSIS_PENDING`**: Relation DDL or ORM model is submitted in a pull request. The engine extracts attribute data types and alignments.
2. **`PADDING_DETECTED`**: Schema audit calculates total internal padding bytes. If $P_i > 0$ for any column or total padding waste ratio $> 5\%$, CI gate triggers a blocking check.
3. **`TETRIS_SORTED`**: The Column Tetris algorithm reorders attributes in descending alignment sequence (8B $\to$ 4B $\to$ 2B $\to$ 1B $\to$ Varlena Tail). All internal padding $P_i$ collapses to 0.
4. **`SHADOW_SYNCED`**: For live tables, a shadow table with optimized layout is created, dual-write triggers are deployed, and historical rows are keyset-backfilled in bounded chunks ($\le 2000$ rows) without locking production reads or writes.
5. **`ATOMIC_SWAPPED`**: When replication lag reaches 0, an atomic catalog rename (`ALTER TABLE ... RENAME`) executes under `SET LOCAL lock_timeout = '2000ms'`.
6. **`OPTIMIZED_COMPACT`**: Tuple density per 8KB page is empirically verified via `pg_attribute` and `pg_class.relpages`. Buffer cache residency increases by $20\%+$.

---

## 5. Machine-Verifiable Definition of Done (DoD) & Anti-Patterns Matrix

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 6-GATE DEFINITION OF DONE (DoD) MATRIX: COLUMN TETRIS INVARIANTS            │
├─────────────────────────────────────────────────────────────────────────────┤
│ [Gate 1: Zero Internal Padding]                                             │
│          - For all fixed columns i: Pi = 0 (Descending alignment 8->4->2->1) │
├─────────────────────────────────────────────────────────────────────────────┤
│ [Gate 2: Varlena Tail Positioning]                                          │
│          - All varlena types (text, jsonb, varchar) positioned at tail      │
├─────────────────────────────────────────────────────────────────────────────┤
│ [Gate 3: Null Bitmap Bounds]                                                │
│          - Nullable columns bound to ceil(K/8)*8; no arbitrary 9th null jump│
├─────────────────────────────────────────────────────────────────────────────┤
│ [Gate 4: Sub-Second Swap Lockout]                                           │
│          - Live migrations execute atomic swap with lock_timeout <= 2000ms  │
├─────────────────────────────────────────────────────────────────────────────┤
│ [Gate 5: Buffer Density Verification]                                       │
│          - Tuples/page density verified in pg_class: tuples/page >= threshold│
├─────────────────────────────────────────────────────────────────────────────┤
│ [Gate 6: CI AST Linter]                                                     │
│          - CI fails if any migration introduces internal tuple padding      │
└─────────────────────────────────────────────────────────────────────────────┘
```

| Anti-Pattern (LLM Slop) | Production Invariant (Agent Arsenal Standard) | Machine Verification Rule |
| :--- | :--- | :--- |
| **Alphabetical/Semantic Ordering** | Declaring columns in descending alignment order: 8B $\to$ 4B $\to$ 2B $\to$ 1B $\to$ Varlena Tail | CI DDL AST linter asserts $\forall i, P_i = 0$ |
| **Interleaved Varlena Columns** | Placing `text` or `varchar` before `bigint` or `timestamptz` | Varlena attributes MUST occupy the highest `attnum` indices |
| **Unchecked 9th Nullable Column** | Adding a 9th nullable column, jumping tuple header from 24B to 32B | Linting alerts when nullable count crosses $8k + 1$ |
| **Direct `ALTER TABLE ADD COLUMN` on Bloated Live Tables** | Appending columns to the end of fragmented live tables | Use Expand-Contract shadow table swap or `pg_repack` |
| **Boolean Flag Sprawl** | Adding 10 individual `boolean` columns (10B + padding) | Pack flags into a single `INT` bitmask or PostgreSQL `bit(16)` |
| **Synchronous `VACUUM FULL` to Reclaim Space** | Running `VACUUM FULL` to compact layout, locking entire table for hours | Strictly use zero-downtime shadow table swap or `pg_repack` |
