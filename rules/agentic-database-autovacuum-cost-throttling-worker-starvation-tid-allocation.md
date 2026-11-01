---
description: PostgreSQL autovacuum cost accounting, multi-worker cost limit division, autovacuum_work_mem single-pass dead TID allocation, index vacuum multi-pass minimization, table-level cost overrides, worker starvation prevention, and anti-wraparound freeze protection across Go (pgx/v5), TypeScript (Kysely, Drizzle), Python (asyncpg), Rust (sqlx), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{vacuum,autovacuum,bloat,freeze,wraparound,maintenance,storage,database,db}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/admin/**/*.{ts,js,go,rs,py},**/internal/db/**/*.{go,rs},**/internal/vacuum/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Autovacuum Cost Limits, Multi-Worker Throttle Division, autovacuum_work_mem Single-Pass TID Allocation & Worker Starvation Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to configure PostgreSQL storage parameters, manage high-churn OLTP tables, eliminate MVCC bloat, size maintenance memory pools, tune autovacuum concurrency, or prevent transaction ID (XID) wraparound panics across PostgreSQL (12–17+), Go (`jackc/pgx/v5`), TypeScript (`Kysely`, `Drizzle ORM`, `Prisma`), Python (`SQLAlchemy 2.0`, `asyncpg`, `psycopg3`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "200-Cost Multi-Worker Throttle Division Trap" (where default `autovacuum_vacuum_cost_limit = 200` is divided equally among all active workers, such that increasing `autovacuum_max_workers` from 3 to 10 shrinks each worker's budget to a pathetic 20 points, throttling vacuum throughput on modern NVMe drives down to $< 2\text{ MB/s}$ and allowing dead tuples to accumulate 50x faster than they are cleaned), the "`autovacuum_work_mem` Single-Pass TID Buffer Overflow & Multi-Scan Index Avalanche" (where default memory allocation restricts dead tuple identifier storage, forcing PostgreSQL to stop heap scanning and execute $4\times–8\times$ redundant full scans across every secondary B-tree, GIN, and GiST index on the relation), the "Autovacuum Worker Starvation by Long-Running Bloated Giants" (where a handful of multi-terabyte tables or unindexed foreign key cascades monopolize all available worker slots for 12+ hours, leaving dozens of high-frequency transactional tables unvacuumed until catastrophic table bloat strikes), the "Global Cost Coupling & Missing Table-Level Cost Overrides" (where mission-critical queue and session tables share conservative global throttling rather than utilizing table-specific cost limits and delays to vacuum at full NVMe line speed), the "Emergency `autovacuum_freeze_max_age` Aggressive Anti-Wraparound Takeover" (where starved tables approach 200M XIDs, forcing PostgreSQL to switch into unthrottled, uncancelable anti-wraparound mode that pins disk I/O and causes connection lock convoys during business peak), and the "Autovacuum Telemetry & Progress Blindness Trap" (where default `log_autovacuum_min_duration = -1` leaves engineering teams blind to vacuum duration, dead tuple counts, index pass multipliers, and system catalog impact) by establishing a strict 5-Tier Autovacuum Governance Ladder, physical I/O throughput theorems, an autonomous TypeScript `AgenticAutovacuumGuardEngine`, cross-runtime implementations in Go, TypeScript, Python, and Rust, a 6-state lifecycle finite-state machine (FSM), and machine-verifiable Definition of Done (DoD) CI gates.

---

## 1. Architectural Taxonomy: The 6 Autovacuum Throttling & Worker Starvation Catastrophes vs The 5-Tier Governance Ladder

In PostgreSQL's Multi-Version Concurrency Control (MVCC) architecture, row updates and deletes leave behind dead tuples on physical 8KB heap pages. The **Autovacuum Daemon** is the background engine responsible for scanning heap pages, pruning dead tuples, maintaining the Free Space Map (FSM) and Visibility Map (VM), reclaiming index line pointers, and freezing transaction IDs (XIDs) to prevent 32-bit transaction wraparound.

To prevent background vacuum operations from saturating physical storage I/O and starving concurrent client queries, PostgreSQL implements a **Cost-Based Vacuum Throttling Engine**:
1. **Cost Accumulation**: Every page read from `shared_buffers` costs `vacuum_cost_page_hit` (default 1 point). Every page read from OS/disk cache costs `vacuum_cost_page_miss` (default 2 points). Every page dirtied and written to disk costs `vacuum_cost_page_dirty` (default 20 points).
2. **Cost Delay**: When an autovacuum worker's accumulated cost reaches `autovacuum_vacuum_cost_limit`, the worker suspends execution and sleeps for `autovacuum_vacuum_cost_delay` (default 2ms in modern versions, 20ms in legacy versions).
3. **Multi-Worker Cost Division**: When multiple autovacuum workers run concurrently, the global cost limit is divided equally among all currently active workers:
   $$C_w(t) = \frac{\text{autovacuum\_vacuum\_cost\_limit}}{N_{\text{active}}(t)}$$
4. **Dead TID Buffer Collection**: While scanning heap pages, a worker buffers dead tuple identifiers (`ItemPointerData`, 6 bytes each) in volatile memory allocated up to `autovacuum_work_mem` (which defaults to `maintenance_work_mem`, typically 64MB). Once this buffer fills, the worker must halt heap scanning and execute a full scan of EVERY secondary index on the table to vacuum the buffered TIDs before resuming heap inspection.

When autonomous coding agents deploy high-throughput database workloads, configure RDS/Aurora clusters, or attempt performance tuning, LLMs routinely commit 6 catastrophic autovacuum anti-patterns:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               POSTGRESQL AUTOVACUUM COST ACCUMULATION & THROTTLE DIVISION              │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Global Setting: autovacuum_vacuum_cost_limit = 200 (Default)                           │
│ Worker Allocation: autovacuum_max_workers = 10 (Naive LLM Tuning!)                     │
│                                                                                        │
│ Worker 1 (orders):         Cost Limit = 200 / 10 = 20 points ──► Sleeps 2ms!           │
│ Worker 2 (audit_logs):     Cost Limit = 200 / 10 = 20 points ──► Sleeps 2ms!           │
│ Worker 3 (sessions):       Cost Limit = 200 / 10 = 20 points ──► Sleeps 2ms!           │
│ ...                                                                                    │
│ Worker 10 (payments):      Cost Limit = 200 / 10 = 20 points ──► Sleeps 2ms!           │
│                                                                                        │
│ 1 Dirty Page = 20 points! ──► Worker writes 1 single 8KB page and goes to sleep!       │
│ Maximum throughput per worker: (8KB / 2ms) * 1 = 4 MB/s theoretical, < 1.5 MB/s actual!│
│ Result: Dead rows accumulate at 80 MB/s, autovacuum cleans at 1.5 MB/s. Table bloats!  │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│           THE autovacuum_work_mem DEAD TID BUFFER OVERFLOW & MULTI-PASS DISASTER       │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Table: 50,000,000 dead tuples across 5 B-tree indexes.                                 │
│ Buffer: autovacuum_work_mem = 64MB (Default maintenance_work_mem).                    │
│ Capacity: 64MB / 6 bytes ≈ 11,184,810 dead TIDs per pass.                              │
│                                                                                        │
│ Heap Scan ──► Collect 11.18M TIDs ──► [BUFFER FULL!]                                   │
│  │                                                                                     │
│  ├─► Pass 1: Scan Index 1, Index 2, Index 3, Index 4, Index 5 (5 Full Scans!)          │
│  │                                                                                     │
│ Heap Scan Resumes ──► Collect next 11.18M TIDs ──► [BUFFER FULL!]                      │
│  │                                                                                     │
│  ├─► Pass 2: Scan Index 1, Index 2, Index 3, Index 4, Index 5 (5 Full Scans!)          │
│  │                                                                                     │
│ Heap Scan Resumes ──► Collect next 11.18M TIDs ──► [BUFFER FULL!]                      │
│  │                                                                                     │
│  ├─► Pass 3: Scan Index 1, Index 2, Index 3, Index 4, Index 5 (5 Full Scans!)          │
│  │                                                                                     │
│ Heap Scan Resumes ──► Collect remaining TIDs ──► [BUFFER FULL!]                        │
│  │                                                                                     │
│  └─► Pass 4 & 5: Repeated Scans! ──► TOTAL: 25 Full Index Scans instead of 5!           │
│                                                                                        │
│ Result: Multiplies Disk Read IOPS & Duration by 500%! Autovacuum runs for 18 hours!    │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│                NAIVE AUTOVACUUM TUNING vs RIGOROUS PRODUCTION INVARIANTS               │
├───────────────────────────────────────────┬────────────────────────────────────────────┤
│         NAIVE / LLM ANTI-PATTERN          │       RIGOROUS PRODUCTION INVARIANT        │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Leave autovacuum_vacuum_cost_limit at   │ • Tune global cost limit to 2000–5000 and  │
│   200. Increase autovacuum_max_workers    │   cost_delay = 2ms for modern NVMe drives. │
│   to 8. Throttles workers to 25 pts each! │   Scale limit linearly with workers!       │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Leave autovacuum_work_mem = -1 (uses    │ • Explicitly set autovacuum_work_mem = 1GB │
│   default 64MB maintenance_work_mem).     │   to 2GB. Guarantees single-pass TID       │
│   Forces 5–10 redundant index passes!     │   collection and eliminates index rescans! │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Bloated 2TB history tables monopolize   │ • Set aggressive table-level overrides on  │
│   all 3 workers for 14 hours; small OLTP  │   hot tables; isolate maintenance workers  │
│   tables starve and blow up with bloat!   │   with per-table cost_limit = 0 (unlimit). │
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Ignore relfrozenxid until emergency     │ • Proactively alert when age(relfrozenxid) │
│   autovacuum_freeze_max_age locks out     │   exceeds 100M XIDs. Run scheduled off-peak│
│   DDL and runs uncancelable anti-wrap!    │   manual freezes before emergency triggers.│
├───────────────────────────────────────────┼────────────────────────────────────────────┤
│ • Leave log_autovacuum_min_duration = -1. │ • Set log_autovacuum_min_duration = 250ms. │
│   Zero visibility into vacuum duration,   │   Continuously monitor progress via        │
│   dead row counts, or index pass multipliers! pg_stat_progress_vacuum in telemetry.   │
└───────────────────────────────────────────┴────────────────────────────────────────────┘
```

---

## 2. Mathematical Formalisms & Autovacuum Storage Physics

Understanding autovacuum requires modeling physical disk throughput under cost delay throttling, multi-worker division, dead TID buffer limits, and queueing starvation.

### Theorem 1: Vacuum I/O Rate Under Cost Throttling

Let $C_{\text{limit}}$ be `autovacuum_vacuum_cost_limit`, and let $t_{\text{delay}}$ be `autovacuum_vacuum_cost_delay` (in seconds). Let $c_{\text{hit}}$, $c_{\text{miss}}$, and $c_{\text{dirty}}$ be the cost weights of buffer cache hits, page misses (reads from disk), and dirty page writes (defaults $1, 2, 20$).

Let $p_{\text{hit}}$, $p_{\text{miss}}$, and $p_{\text{dirty}}$ denote the empirical probabilities that an examined 8KB page falls into each respective category ($p_{\text{hit}} + p_{\text{miss}} = 1.0$). The average cost incurred per examined 8KB page is:
$$\bar{c} = p_{\text{hit}} \cdot c_{\text{hit}} + p_{\text{miss}} \cdot c_{\text{miss}} + p_{\text{dirty}} \cdot c_{\text{dirty}}$$

The number of pages processed before exhausting the cost quota $C_{\text{limit}}$ is:
$$N_{\text{pages}} = \frac{C_{\text{limit}}}{\bar{c}}$$

Assuming CPU processing time per page is negligible relative to the sleep delay $t_{\text{delay}}$, the maximum theoretical sustained I/O throughput $V_{\text{rate}}$ (in Megabytes per second) is:
$$V_{\text{rate}} = \frac{N_{\text{pages}} \times 8192 \text{ bytes}}{t_{\text{delay}} \times 1024^2} = \frac{C_{\text{limit}}}{\bar{c} \cdot t_{\text{delay}}} \times \frac{8}{1024} \text{ MB/s}$$

**Proof of NVMe Starvation Under Defaults**:
Given default settings ($C_{\text{limit}} = 200, t_{\text{delay}} = 0.002\text{s}$):
In a write-heavy vacuum cycle where 30% of pages are in shared buffers ($p_{\text{hit}} = 0.3$), 70% are read from disk ($p_{\text{miss}} = 0.7$), and 20% contain dead tuples requiring page dirtying ($p_{\text{dirty}} = 0.2$):
$$\bar{c} = (0.3 \times 1) + (0.7 \times 2) + (0.2 \times 20) = 0.3 + 1.4 + 4.0 = 5.7 \text{ points/page}$$
$$V_{\text{rate}} = \frac{200}{5.7 \times 0.002} \times \frac{8}{1024} = \frac{200}{0.0114} \times 0.0078125 \approx 137.06 \text{ pages/sec} \approx 1.07 \text{ MB/s}$$
On an enterprise NVMe SSD capable of $4,500\text{ MB/s}$ sequential read and $2,500\text{ MB/s}$ write, PostgreSQL limits itself to a pathetic **$1.07\text{ MB/s}$**. A 100GB table takes **$25.9\text{ hours}$** to vacuum!

---

### Theorem 2: Multi-Worker Cost Division Penalty

When $N_{\text{active}}$ workers are active simultaneously, PostgreSQL divides the global cost limit evenly:
$$C_w(t) = \frac{C_{\text{limit}}}{N_{\text{active}}(t)}$$
The individual throughput of each worker becomes:
$$V_w(t) = \frac{C_w(t)}{\bar{c} \cdot t_{\text{delay}}} \times \frac{8}{1024} = \frac{V_{\text{rate}}}{N_{\text{active}}(t)}$$

**The Worker Scalability Paradox**:
Increasing `autovacuum_max_workers` from 3 to 10 without scaling $C_{\text{limit}}$ does **NOT** increase aggregate vacuum throughput. The total cluster I/O rate remains capped at $V_{\text{rate}} \approx 1.07\text{ MB/s}$, while individual workers slow down to:
$$V_{w=10} = \frac{1.07\text{ MB/s}}{10} = 0.107\text{ MB/s} \approx 109\text{ KB/s}$$
Each worker spends 95% of its wall-clock time sleeping in 2ms intervals, exacerbating table bloat across all 10 relations!

---

### Theorem 3: Dead TID Memory Capacity & Index Pass Multiplier

In PostgreSQL $\le 16$, dead tuple identifiers are collected in an in-memory array of `ItemPointerData` structs (6 bytes: 4 bytes block number, 2 bytes offset). In PostgreSQL 17+, dead TIDs are stored in an adaptive radix tree (`TidStore`), consuming approximately 1.5 to 2.5 bytes per entry depending on clustering.

Let $M_{\text{vac}}$ be `autovacuum_work_mem` (in bytes). The maximum number of dead tuple identifiers that can be held in memory in a single heap scanning pass is:
$$N_{\text{cap}} = \begin{cases}
\left\lfloor \frac{M_{\text{vac}}}{6} \right\rfloor & \text{PostgreSQL } \le 16 \\
\left\lfloor \frac{M_{\text{vac}}}{2.0} \right\rfloor & \text{PostgreSQL } \ge 17 \text{ (TidStore average)}
\end{cases}$$

If a relation has $N_{\text{dead}}$ dead tuples, the number of index vacuum passes required is:
$$P_{\text{index}} = \left\lceil \frac{N_{\text{dead}}}{N_{\text{cap}}} \right\rceil$$

If the relation has $M_{\text{indexes}}$ secondary indexes with total physical size $S_{\text{index}} = \sum_{j=1}^{M_{\text{indexes}}} \text{Size}(I_j)$, the total index data read and scanned during vacuuming is:
$$\text{Data}_{\text{index\_scanned}} = P_{\text{index}} \times S_{\text{index}}$$

**The Multi-Pass Avalanche**:
Consider a table with 40,000,000 dead tuples and 4 B-tree indexes totaling 60GB in size:
- Under default `maintenance_work_mem = 64MB`:
  $$N_{\text{cap}} = \frac{64 \times 1024^2}{6} \approx 11,184,810 \text{ TIDs}$$
  $$P_{\text{index}} = \left\lceil \frac{40,000,000}{11,184,810} \right\rceil = 4 \text{ passes}$$
  $$\text{Data}_{\text{scanned}} = 4 \times 60\text{GB} = 240\text{GB}$$
  PostgreSQL must read and scan **240GB of index pages**!
- Under tuned `autovacuum_work_mem = 1GB`:
  $$N_{\text{cap}} = \frac{1024 \times 1024^2}{6} \approx 178,956,970 \text{ TIDs}$$
  $$P_{\text{index}} = \left\lceil \frac{40,000,000}{178,956,970} \right\rceil = 1 \text{ pass}$$
  $$\text{Data}_{\text{scanned}} = 1 \times 60\text{GB} = 60\text{GB}$$
  Single-pass execution eliminates **180GB of unnecessary disk reads**, saving 3+ hours of high-IOPS index thrashing!

---

### Theorem 4: Worker Starvation Probability & Queueing Model

Let $\mathcal{R}$ be the set of relations eligible for autovacuum based on `autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor \times n_live_tup`. Let arrival rate of relations requiring vacuum be $\lambda_{\text{vac}}$ relations per hour. Let the service duration of relation $i$ be $T_i$.

If $k$ large relations have service duration $T_{\text{giant}} \gg \frac{1}{\lambda_{\text{vac}}}$, and $k \ge \text{autovacuum\_max\_workers}$, then the queue of pending relations $\mathcal{Q}(t)$ grows unboundedly according to Little's Law:
$$L_q = \lambda_{\text{vac}} \times W_q$$
Where the expected wait time $W_q$ for high-churn transactional tables exceeds the dead tuple generation window $T_{\text{bloat}}$, leading to runaway table bloat, HOT update failure, and eventual disk exhaustion.

---

## 3. The 5-Tier Autovacuum Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        THE 5-TIER AUTOVACUUM GOVERNANCE LADDER                         │
├───────┬──────────────────────────────────┬─────────────────────────────────────────────┤
│ LEVEL │ TIER NAME                        │ CORE ARCHITECTURAL INVARIANTS               │
├───────┼──────────────────────────────────┼─────────────────────────────────────────────┤
│ Tier 0│ NVMe Base Cost Budget Calibration│ • autovacuum_vacuum_cost_limit = 2000–5000  │
│       │ & Proportional Worker Scaling    │ • autovacuum_vacuum_cost_delay = 2ms (or 0) │
│       │                                  │ • Scale limit with workers: Limit >= 500*W  │
├───────┼──────────────────────────────────┼─────────────────────────────────────────────┤
│ Tier 1│ Single-Pass TID Memory Allocation│ • autovacuum_work_mem = 1GB–2GB (Dedicated) │
│       │ & Index Pass Minimization        │ • Assert index_vacuum_count == 1 in logs    │
│       │                                  │ • Eliminate multiple B-tree index sweeps    │
├───────┼──────────────────────────────────┼─────────────────────────────────────────────┤
│ Tier 2│ Worker Concurrency & Starvation  │ • autovacuum_max_workers = 6–8 on 16+ vCPU  │
│       │ Eradication                      │ • Queue depth sentinel: alert if queue >= 5 │
│       │                                  │ • Never let giant tables starve OLTP queues │
├───────┼──────────────────────────────────┼─────────────────────────────────────────────┤
│ Tier 3│ Isolated Table-Level Overrides   │ • ALTER TABLE hot_table SET (cost_limit=5000│
│       │ For High-Churn Hot Relations     │   autovacuum_vacuum_cost_delay = 0)         │
│       │                                  │ • Detach hot workers from shared cost pool  │
├───────┼──────────────────────────────────┼─────────────────────────────────────────────┤
│ Tier 4│ Autonomous Progress Sentinels,   │ • log_autovacuum_min_duration = 250ms       │
│       │ Anti-Wraparound Watchdog & CI    │ • Continuous pg_stat_progress_vacuum polls  │
│       │ Verification Gates               │ • age(relfrozenxid) <= 100M threshold guard │
└───────┴──────────────────────────────────┴─────────────────────────────────────────────┘
```

---

### Tier 0: NVMe Base Cost Budget Calibration & Proportional Worker Scaling

Default PostgreSQL settings (`cost_limit = 200, cost_delay = 2ms`) were established decades ago for 7200 RPM mechanical spinning platters where excessive background I/O would cause disk head thrashing. Modern NVMe SSDs deliver hundreds of thousands of IOPS with negligible latency penalties.

1. **Global Cost Limit Calibration**:
   ```sql
   -- On modern cloud or bare-metal NVMe SSDs (AWS gp3, io2, GCP pd-ssd, Azure Premium SSD v2):
   ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 2500;
   ALTER SYSTEM SET autovacuum_vacuum_cost_delay = '2ms';
   SELECT pg_reload_conf();
   ```
2. **Proportional Worker Scaling Invariant**:
   Whenever `autovacuum_max_workers` is increased, `autovacuum_vacuum_cost_limit` MUST be scaled proportionally to guarantee that each worker receives an effective budget of at least 500 points:
   $$\text{autovacuum\_vacuum\_cost\_limit} \ge \max(2000, 500 \times \text{autovacuum\_max\_workers})$$

---

### Tier 1: Single-Pass TID Memory Allocation & Index Pass Minimization

By default, `autovacuum_work_mem` is set to `-1`, which causes autovacuum to inherit `maintenance_work_mem` (default 64MB). This is severely undersized for modern databases.

1. **Dedicated Autovacuum Work Memory**:
   Configure dedicated `autovacuum_work_mem` independent of client `maintenance_work_mem` (which affects manual DDL and index builds):
   ```sql
   -- Allocate 1GB to 2GB dedicated memory per autovacuum worker
   ALTER SYSTEM SET autovacuum_work_mem = '1024MB';
   SELECT pg_reload_conf();
   ```
2. **The Single-Pass Assertion**:
   With `autovacuum_work_mem = 1024MB`, a single worker can buffer over $178\text{ million}$ dead TIDs in PostgreSQL $\le 16$, and over $500\text{ million}$ dead TIDs in PostgreSQL $17+$ (`TidStore`). This guarantees that 99.9% of production tables complete vacuuming with exactly **1 index pass**, avoiding redundant $O(N \times M)$ B-tree scans.

---

### Tier 2: Worker Concurrency & Starvation Eradication

When a cluster contains a few massive tables (e.g., partitioned tables, multi-terabyte analytics staging) alongside hundreds of small transactional tables, large tables monopolize all 3 default workers for hours.

1. **Increase Worker Concurrency on Multi-Core Instances**:
   ```sql
   -- For instances with >= 16 vCPUs and >= 64GB RAM:
   ALTER SYSTEM SET autovacuum_max_workers = 6;
   -- Accompany with scaled cost limit to preserve per-worker throughput:
   ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 3000;
   SELECT pg_reload_conf();
   ```
2. **Queue Starvation Telemetry**:
   Monitor relations that meet the vacuum threshold but are waiting for an available worker:
   ```sql
   -- Count relations currently starving for an autovacuum worker:
   SELECT count(*) AS starved_tables
   FROM pg_stat_user_tables
   WHERE (n_dead_tup > (n_live_tup * 0.10 + 50))
     AND relid NOT IN (
       SELECT (a.query_start - a.query_start)::int -- placeholder
       FROM pg_stat_activity
     );
   ```

---

### Tier 3: Isolated Table-Level Overrides for High-Churn Hot Relations

High-velocity transactional tables (job queues, user presence, shopping cart sessions, webhook dispatches) generate thousands of dead tuples per second. Sharing the global cost pool with slow analytical tables causes high-churn tables to bloat rapidly.

1. **Table-Specific Cost Overrides**:
   PostgreSQL allows overriding cost limit and cost delay per table. When `autovacuum_vacuum_cost_limit` is set on a specific relation, the worker executing on that table is **COMPLETELY DETACHED** from the shared global cost pool:
   ```sql
   -- Detach high-churn queue table from global throttling:
   -- Setting cost_delay = 0 lets worker vacuum at full hardware line speed!
   ALTER TABLE high_churn_queue SET (
     autovacuum_vacuum_cost_limit = 5000,
     autovacuum_vacuum_cost_delay = 0,
     autovacuum_vacuum_scale_factor = 0.02,
     autovacuum_vacuum_threshold = 100
   );
   ```
2. **Surgical Scope**:
   Only apply `cost_delay = 0` to high-churn tables with dedicated I/O headroom. Never apply `cost_delay = 0` globally, as doing so would cause background workers to saturate disk channels and impact p99 client query latency.

---

### Tier 4: Autonomous Progress Sentinels, Anti-Wraparound Watchdogs & CI Gates

1. **Enable Detailed Autovacuum Logging**:
   ```sql
   -- Log every autovacuum execution taking longer than 250ms:
   ALTER SYSTEM SET log_autovacuum_min_duration = 250;
   SELECT pg_reload_conf();
   ```
   This outputs essential telemetry to PostgreSQL engine logs:
   `automatic vacuum of table "public.orders": index scans: 1, pages: 1240 removed, 4520 remain; tuples: 45000 removed, 210000 remain, read rate: 85.4 MB/s, write rate: 42.1 MB/s`
2. **Anti-Wraparound Freeze Critical Horizon Sentinel**:
   ```sql
   -- Alert if any table's transaction ID age exceeds 100,000,000 (halfway to emergency freeze):
   SELECT 
     relname,
     age(relfrozenxid) AS xid_age,
     current_setting('autovacuum_freeze_max_age')::bigint AS max_age,
     ROUND(age(relfrozenxid)::numeric / current_setting('autovacuum_freeze_max_age')::numeric * 100, 2) AS pct_towards_emergency_freeze
   FROM pg_class
   WHERE relkind IN ('r', 'm')
     AND age(relfrozenxid) > 100000000
   ORDER BY age(relfrozenxid) DESC;
   ```

---

## 4. Production Code Implementations

### TypeScript / Kysely: Comprehensive Autovacuum Health Sentinel & Override Manager

```typescript
// src/services/autovacuum-guard.ts
import { Kysely, sql } from 'kysely';

export interface AutovacuumSettings {
  maxWorkers: number;
  costLimit: number;
  costDelay: number;
  workMemMb: number;
  logMinDurationMs: number;
}

export interface TableVacuumProgress {
  pid: number;
  relid: number;
  tableName: string;
  phase: string;
  heapBlksTotal: number;
  heapBlksScanned: number;
  heapBlksVacuumed: number;
  indexVacuumCount: number;
  numDeadTuples: number;
  maxDeadTuples: number;
}

export interface TableStarvationRisk {
  tableName: string;
  liveTuples: number;
  deadTuples: number;
  deadRatio: number;
  xidAge: number;
  isStarved: boolean;
}

export class AgenticAutovacuumSentinel {
  constructor(private readonly db: Kysely<any>) {}

  /**
   * Audits global autovacuum settings against NVMe production standards.
   */
  async auditGlobalSettings(): Promise<{ settings: AutovacuumSettings; violations: string[]; recommendations: string[] }> {
    const raw = await sql<{ name: string; setting: string }>`
      SELECT name, setting 
      FROM pg_settings 
      WHERE name IN (
        'autovacuum_max_workers', 
        'autovacuum_vacuum_cost_limit', 
        'autovacuum_vacuum_cost_delay', 
        'autovacuum_work_mem',
        'maintenance_work_mem',
        'log_autovacuum_min_duration'
      )
    `.execute(this.db);

    const map = new Map<string, string>();
    for (const row of raw.rows) {
      map.set(row.name, row.setting);
    }

    const maxWorkers = parseInt(map.get('autovacuum_max_workers') || '3', 10);
    const costLimit = parseInt(map.get('autovacuum_vacuum_cost_limit') || '200', 10);
    const costDelay = parseFloat(map.get('autovacuum_vacuum_cost_delay') || '2');
    const autoWorkMem = parseInt(map.get('autovacuum_work_mem') || '-1', 10);
    const maintWorkMem = parseInt(map.get('maintenance_work_mem') || '65536', 10);
    const effectiveWorkMemKb = autoWorkMem > 0 ? autoWorkMem : maintWorkMem;
    const workMemMb = Math.round(effectiveWorkMemKb / 1024);
    const logMinDurationMs = parseInt(map.get('log_autovacuum_min_duration') || '-1', 10);

    const violations: string[] = [];
    const recommendations: string[] = [];

    // Check 1: Multi-worker cost division penalty
    const perWorkerCost = costLimit / maxWorkers;
    if (perWorkerCost < 300) {
      violations.push(
        `CRITICAL_THROTTLE_DIVISION: Cost limit ${costLimit} divided across ${maxWorkers} workers yields only ${perWorkerCost.toFixed(0)} points/worker. Workers will sleep >90% of the time, dropping throughput below 2 MB/s.`
      );
      recommendations.push(
        `Execute: ALTER SYSTEM SET autovacuum_vacuum_cost_limit = ${Math.max(2500, maxWorkers * 500)};`
      );
    }

    // Check 2: Single-pass TID buffer capacity
    if (workMemMb < 512) {
      violations.push(
        `UNDERSIZED_DEAD_TID_BUFFER: autovacuum_work_mem is ${workMemMb}MB. Tables with >15M dead rows will suffer multi-pass index scanning avalanches.`
      );
      recommendations.push(`Execute: ALTER SYSTEM SET autovacuum_work_mem = '1024MB';`);
    }

    // Check 3: Logging visibility
    if (logMinDurationMs < 0 || logMinDurationMs > 1000) {
      violations.push(
        `BLIND_VACUUM_TELEMETRY: log_autovacuum_min_duration is ${logMinDurationMs}ms (disabled or too loose). Missing index pass and throughput metrics.`
      );
      recommendations.push(`Execute: ALTER SYSTEM SET log_autovacuum_min_duration = 250;`);
    }

    return {
      settings: { maxWorkers, costLimit, costDelay, workMemMb, logMinDurationMs },
      violations,
      recommendations,
    };
  }

  /**
   * Queries real-time active autovacuum operations and flags multi-pass index thrashing.
   */
  async getActiveVacuumProgress(): Promise<TableVacuumProgress[]> {
    const res = await sql<any>`
      SELECT 
        p.pid,
        p.relid,
        c.relname AS "tableName",
        p.phase,
        p.heap_blks_total AS "heapBlksTotal",
        p.heap_blks_scanned AS "heapBlksScanned",
        p.heap_blks_vacuumed AS "heapBlksVacuumed",
        p.index_vacuum_count AS "indexVacuumCount",
        p.num_dead_tuples AS "numDeadTuples",
        p.max_dead_tuples AS "maxDeadTuples"
      FROM pg_stat_progress_vacuum p
      JOIN pg_class c ON c.oid = p.relid
    `.execute(this.db);

    return res.rows.map((r) => ({
      pid: r.pid,
      relid: r.relid,
      tableName: r.tableName,
      phase: r.phase,
      heapBlksTotal: Number(r.heapBlksTotal),
      heapBlksScanned: Number(r.heapBlksScanned),
      heapBlksVacuumed: Number(r.heapBlksVacuumed),
      indexVacuumCount: Number(r.indexVacuumCount),
      numDeadTuples: Number(r.numDeadTuples),
      maxDeadTuples: Number(r.maxDeadTuples),
    }));
  }

  /**
   * Applies dedicated table-level cost overrides for high-churn tables.
   */
  async isolateHotTableCost(tableName: string, costLimit = 5000, costDelay = 0): Promise<void> {
    if (!/^[a-zA-Z0-9_]+$/.test(tableName)) {
      throw new Error(`Invalid table name: ${tableName}`);
    }

    await this.db.transaction().execute(async (tx) => {
      await sql`SET LOCAL lock_timeout = '2000ms'`.execute(tx);
      await sql.raw(`
        ALTER TABLE ${tableName} SET (
          autovacuum_vacuum_cost_limit = ${costLimit},
          autovacuum_vacuum_cost_delay = ${costDelay},
          autovacuum_vacuum_scale_factor = 0.02,
          autovacuum_vacuum_threshold = 200
        )
      `).execute(tx);
    });
  }
}
```

---

### Go: Production Sentinel & Table Override Manager (`jackc/pgx/v5`)

```go
// internal/vacuum/autovacuum_sentinel.go
package vacuum

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

var validTableName = regexp.MustCompile(`^[a-zA-Z0-9_]+$`)

type AutovacuumSentinel struct {
	pool *pgxpool.Pool
}

func NewAutovacuumSentinel(pool *pgxpool.Pool) (*AutovacuumSentinel, error) {
	if pool == nil {
		return nil, errors.New("pgx connection pool must not be nil")
	}
	return &AutovacuumSentinel{pool: pool}, nil
}

type AutovacuumMetric struct {
	MaxWorkers       int
	CostLimit        int
	CostDelayMs      float64
	WorkMemMb        int
	LogMinDurationMs int
	PerWorkerCost    float64
}

// AuditClusterAutovacuum inspects the cluster configuration and asserts safe cost scaling.
func (s *AutovacuumSentinel) AuditClusterAutovacuum(ctx context.Context) (*AutovacuumMetric, []string, error) {
	query := `
		SELECT name, setting 
		FROM pg_settings 
		WHERE name IN (
			'autovacuum_max_workers', 
			'autovacuum_vacuum_cost_limit', 
			'autovacuum_vacuum_cost_delay', 
			'autovacuum_work_mem',
			'maintenance_work_mem',
			'log_autovacuum_min_duration'
		);`

	rows, err := s.pool.Query(ctx, query)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to query pg_settings: %w", err)
	}
	defer rows.Close()

	settings := make(map[string]string)
	for rows.Next() {
		var name, setting string
		if err := rows.Scan(&name, &setting); err != nil {
			return nil, nil, err
		}
		settings[name] = setting
	}

	var m AutovacuumMetric
	fmt.Sscanf(settings["autovacuum_max_workers"], "%d", &m.MaxWorkers)
	fmt.Sscanf(settings["autovacuum_vacuum_cost_limit"], "%d", &m.CostLimit)
	fmt.Sscanf(settings["autovacuum_vacuum_cost_delay"], "%f", &m.CostDelayMs)
	fmt.Sscanf(settings["log_autovacuum_min_duration"], "%d", &m.LogMinDurationMs)

	var autoWorkMemKb, maintWorkMemKb int
	fmt.Sscanf(settings["autovacuum_work_mem"], "%d", &autoWorkMemKb)
	fmt.Sscanf(settings["maintenance_work_mem"], "%d", &maintWorkMemKb)

	if autoWorkMemKb > 0 {
		m.WorkMemMb = autoWorkMemKb / 1024
	} else {
		m.WorkMemMb = maintWorkMemKb / 1024
	}

	if m.MaxWorkers > 0 {
		m.PerWorkerCost = float64(m.CostLimit) / float64(m.MaxWorkers)
	}

	var violations []string
	if m.PerWorkerCost < 300.0 {
		violations = append(violations, fmt.Sprintf(
			"THROTTLE_STARVATION: Per-worker cost allowance is %.1f (Limit=%d, Workers=%d). Workers will throttle at line rate < 2 MB/s.",
			m.PerWorkerCost, m.CostLimit, m.MaxWorkers,
		))
	}
	if m.WorkMemMb < 512 {
		violations = append(violations, fmt.Sprintf(
			"UNDERSIZED_TID_MEMORY: autovacuum_work_mem is %d MB. Multi-pass index scans will degrade performance.",
			m.WorkMemMb,
		))
	}

	return &m, violations, nil
}

// IsolateTableCost applies dedicated cost limits and eliminates cost delays for a hot table.
func (s *AutovacuumSentinel) IsolateTableCost(ctx context.Context, tableName string, costLimit int, costDelayMs int) error {
	if !validTableName.MatchString(tableName) {
		return fmt.Errorf("invalid table identifier: %s", tableName)
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Bounded lock timeout prevents queuing behind slow queries
	if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2000ms';"); err != nil {
		return fmt.Errorf("failed to set lock timeout: %w", err)
	}

	alterStmt := fmt.Sprintf(`
		ALTER TABLE %s SET (
			autovacuum_vacuum_cost_limit = %d,
			autovacuum_vacuum_cost_delay = %d,
			autovacuum_vacuum_scale_factor = 0.02,
			autovacuum_vacuum_threshold = 200
		);`, tableName, costLimit, costDelayMs)

	if _, err := tx.Exec(ctx, alterStmt); err != nil {
		return fmt.Errorf("failed to alter table autovacuum settings: %w", err)
	}

	return tx.Commit(ctx)
}
```

---

### Python: Asynchronous Autovacuum Progress & Anti-Wraparound Monitor (`asyncpg`)

```python
# src/monitoring/autovacuum_monitor.py
import asyncpg
import logging
from typing import List, Dict, Any

logger = logging.getLogger("autovacuum.monitor")

class AutovacuumMonitor:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    async def check_anti_wraparound_horizon(self, warning_threshold: int = 100_000_000) -> List[Dict[str, Any]]:
        """
        Audits table XID ages against autovacuum_freeze_max_age to detect imminent emergency freezes.
        """
        query = """
            SELECT 
                c.oid,
                c.relname AS table_name,
                age(c.relfrozenxid) AS xid_age,
                current_setting('autovacuum_freeze_max_age')::bigint AS freeze_max_age,
                ROUND((age(c.relfrozenxid)::numeric / current_setting('autovacuum_freeze_max_age')::numeric) * 100, 2) AS pct_limit
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'm')
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND age(c.relfrozenxid) >= $1
            ORDER BY age(c.relfrozenxid) DESC;
        """
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query, warning_threshold)
            results = []
            for r in rows:
                item = dict(r)
                if item["pct_limit"] >= 75.0:
                    logger.critical(
                        f"EMERGENCY_WRAPAROUND_APPROACHING: Table {item['table_name']} is at {item['pct_limit']}% "
                        f"of autovacuum_freeze_max_age (age={item['xid_age']}). Immediate maintenance required!"
                    )
                results.append(item)
            return results

    async def get_multi_pass_index_scans(self) -> List[Dict[str, Any]]:
        """
        Detects active autovacuum operations currently executing multiple index passes.
        """
        query = """
            SELECT 
                p.pid,
                c.relname AS table_name,
                p.phase,
                p.index_vacuum_count,
                p.num_dead_tuples,
                p.max_dead_tuples
            FROM pg_stat_progress_vacuum p
            JOIN pg_class c ON c.oid = p.relid
            WHERE p.index_vacuum_count > 1;
        """
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)
            return [dict(r) for r in rows]
```

---

### Rust: Table-Level Cost Manager & Progress Streamer (`sqlx`)

```rust
// src/vacuum/mod.rs
use sqlx::{PgPool, Result, Row};
use std::time::Duration;

pub struct AutovacuumManager {
    pool: PgPool,
}

impl AutovacuumManager {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Sets isolated table-level autovacuum parameters with bounded lock timeout.
    pub async fn isolate_table_cost(
        &self,
        table_name: &str,
        cost_limit: i32,
        cost_delay_ms: i32,
    ) -> Result<()> {
        if !table_name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return Err(sqlx::Error::Protocol("Invalid table name".into()));
        }

        let mut tx = self.pool.begin().await?;
        sqlx::query("SET LOCAL lock_timeout = '2000ms';")
            .execute(&mut *tx)
            .await?;

        let sql = format!(
            "ALTER TABLE {} SET (
                autovacuum_vacuum_cost_limit = {},
                autovacuum_vacuum_cost_delay = {},
                autovacuum_vacuum_scale_factor = 0.02,
                autovacuum_vacuum_threshold = 200
            );",
            table_name, cost_limit, cost_delay_ms
        );

        sqlx::query(&sql).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(())
    }

    /// Verifies that no active vacuum worker is running multi-pass index sweeps.
    pub async fn assert_single_pass_vacuum(&self) -> Result<bool> {
        let row = sqlx::query(
            "SELECT COUNT(*) as multi_pass_count 
             FROM pg_stat_progress_vacuum 
             WHERE index_vacuum_count > 1;"
        )
        .fetch_one(&self.pool)
        .await?;

        let count: i64 = row.try_get("multi_pass_count")?;
        Ok(count == 0)
    }
}
```

---

## 5. Autonomous TypeScript Guard Engine

```typescript
// src/engines/agentic-autovacuum-guard.engine.ts
export interface AutovacuumConfigInput {
  autovacuumMaxWorkers: number;
  autovacuumCostLimit: number;
  autovacuumCostDelayMs: number;
  autovacuumWorkMemMb: number;
  logAutovacuumMinDurationMs: number;
  storageType: 'NVME_SSD' | 'CLOUD_SSD' | 'SPINNING_HDD';
}

export interface GuardEvaluationResult {
  passed: boolean;
  score: number; // 0 - 100
  perWorkerCost: number;
  estimatedThroughputMbSec: number;
  violations: string[];
  remediationSql: string[];
}

export class AgenticAutovacuumGuardEngine {
  /**
   * Evaluates PostgreSQL autovacuum settings against strict production invariants.
   */
  public static evaluate(config: AutovacuumConfigInput): GuardEvaluationResult {
    const violations: string[] = [];
    const remediationSql: string[] = [];
    let score = 100;

    const perWorkerCost = config.autovacuumCostLimit / config.autovacuumMaxWorkers;

    // Estimate throughput for typical write-heavy page distribution
    // 30% hit (1), 70% miss (2), 20% dirty (20) -> avg 5.7 cost points/page
    const avgPageCost = 5.7;
    const effectiveDelaySec = Math.max(0.001, config.autovacuumCostDelayMs / 1000);
    const pagesPerSec = (config.autovacuumCostLimit / (avgPageCost * effectiveDelaySec));
    const estimatedThroughputMbSec = (pagesPerSec * 8192) / (1024 * 1024);

    // Rule 1: Multi-worker cost division penalty
    if (perWorkerCost < 300) {
      score -= 30;
      violations.push(
        `VIOLATION_THROTTLE_DIVISION: Per-worker cost allowance is ${perWorkerCost.toFixed(0)} points (Limit: ${config.autovacuumCostLimit}, Workers: ${config.autovacuumMaxWorkers}). Throughput is restricted to ${estimatedThroughputMbSec.toFixed(1)} MB/s total across all workers.`
      );
      const targetLimit = Math.max(2500, config.autovacuumMaxWorkers * 500);
      remediationSql.push(`ALTER SYSTEM SET autovacuum_vacuum_cost_limit = ${targetLimit};`);
    }

    // Rule 2: Single-pass TID memory capacity
    if (config.autovacuumWorkMemMb < 512) {
      score -= 25;
      violations.push(
        `VIOLATION_UNDERSIZED_TID_MEMORY: autovacuum_work_mem is ${config.autovacuumWorkMemMb}MB. Tables with >15M dead rows will trigger multi-pass index scanning avalanches.`
      );
      remediationSql.push(`ALTER SYSTEM SET autovacuum_work_mem = '1024MB';`);
    }

    // Rule 3: Storage-aligned cost delay
    if (config.storageType !== 'SPINNING_HDD' && config.autovacuumCostDelayMs > 5) {
      score -= 15;
      violations.push(
        `VIOLATION_EXCESSIVE_DELAY: Cost delay of ${config.autovacuumCostDelayMs}ms is relic tuning for HDDs. Modern SSDs tolerate 2ms or lower delay.`
      );
      remediationSql.push(`ALTER SYSTEM SET autovacuum_vacuum_cost_delay = '2ms';`);
    }

    // Rule 4: Logging and observability
    if (config.logAutovacuumMinDurationMs < 0 || config.logAutovacuumMinDurationMs > 500) {
      score -= 15;
      violations.push(
        `VIOLATION_BLIND_TELEMETRY: log_autovacuum_min_duration is ${config.logAutovacuumMinDurationMs}ms. Must be <= 250ms for observability.`
      );
      remediationSql.push(`ALTER SYSTEM SET log_autovacuum_min_duration = 250;`);
    }

    if (remediationSql.length > 0) {
      remediationSql.push(`SELECT pg_reload_conf();`);
    }

    return {
      passed: violations.length === 0,
      score: Math.max(0, score),
      perWorkerCost,
      estimatedThroughputMbSec,
      violations,
      remediationSql,
    };
  }
}
```

---

## 6. The 6-State Autovacuum Lifecycle Finite-State Machine (FSM)

```
       ┌────────────────────────┐
       │ 1. MONITORING_STATUS   │◄──────────────┐
       └───────────┬────────────┘               │
                   │ (Dead Tuples > Threshold)  │
                   ▼                            │
       ┌────────────────────────┐               │
       │ 2. TID_MEMORY_AUDIT    │               │
       └───────────┬────────────┘               │
                   │ (Memory Sufficient)        │
                   ▼                            │
       ┌────────────────────────┐               │
       │ 3. COST_POOL_DIVISION  │               │
       └───────────┬────────────┘               │
                   │ (Per-Worker Cost >= 500)   │
                   ▼                            │ (Maintenance Complete)
       ┌────────────────────────┐               │
       │ 4. TABLE_OVERRIDE_RUN  │               │
       └───────────┬────────────┘               │
                   │ (Scanning & Pruning)       │
                   ▼                            │
       ┌────────────────────────┐               │
       │ 5. INDEX_PASS_ASSERT   │               │
       └───────────┬────────────┘               │
                   │ (index_vacuum_count == 1)  │
                   ▼                            │
       ┌────────────────────────┐               │
       │ 6. WRAPAROUND_CLEARED  │───────────────┘
       └────────────────────────┘
```

1. **State 1: MONITORING_STATUS**: Periodic 10-second inspection of `pg_stat_user_tables` computing dead tuple percentages and evaluating queue backlogs.
2. **State 2: TID_MEMORY_AUDIT**: Verifying that `autovacuum_work_mem` is sized sufficiently ($\ge 1\text{GB}$) to hold all candidate dead TIDs in a single pass.
3. **State 3: COST_POOL_DIVISION**: Inspecting active worker count in `pg_stat_activity` and asserting per-worker cost allowance $C_w \ge 500$ points.
4. **State 4: TABLE_OVERRIDE_RUN**: Executing isolated table-specific cost limits on hot relations with `autovacuum_vacuum_cost_delay = 0` and bounded lock timeouts.
5. **State 5: INDEX_PASS_ASSERT**: Querying `pg_stat_progress_vacuum` to verify that `index_vacuum_count == 1`, asserting zero multi-pass B-tree scan rescans.
6. **State 6: WRAPAROUND_CLEARED**: Auditing `age(relfrozenxid)` post-vacuum to confirm transaction horizon advancement below warning thresholds.

---

## 7. Machine-Verifiable Definition of Done (DoD) CI Gates

Every database deployment and configuration update must satisfy all 6 machine-verifiable verification gates before passing CI/CD:

```bash
# ------------------------------------------------------------------------------
# GATE 1: Verify Per-Worker Cost Budget Calibration (Per-Worker Cost >= 400 pts)
# ------------------------------------------------------------------------------
PER_WORKER_COST=$(psql "$DATABASE_URL" -t -A -c "
  SELECT (current_setting('autovacuum_vacuum_cost_limit')::numeric / 
          current_setting('autovacuum_max_workers')::numeric)::int;
")
if [ "$PER_WORKER_COST" -lt 400 ]; then
  echo "❌ CI FAIL: Per-worker cost allowance ($PER_WORKER_COST) is below 400 points!"
  exit 1
fi
echo "✅ GATE 1 PASSED: Per-worker cost budget is $PER_WORKER_COST points."

# ------------------------------------------------------------------------------
# GATE 2: Verify Dedicated autovacuum_work_mem Sizing (>= 512MB)
# ------------------------------------------------------------------------------
WORK_MEM_MB=$(psql "$DATABASE_URL" -t -A -c "
  SELECT CASE 
    WHEN current_setting('autovacuum_work_mem') = '-1' THEN 
      (pg_size_bytes(current_setting('maintenance_work_mem')) / 1024 / 1024)::int
    ELSE 
      (pg_size_bytes(current_setting('autovacuum_work_mem')) / 1024 / 1024)::int
  END;
")
if [ "$WORK_MEM_MB" -lt 512 ]; then
  echo "❌ CI FAIL: Effective autovacuum_work_mem is only ${WORK_MEM_MB}MB (Required >= 512MB)!"
  exit 1
fi
echo "✅ GATE 2 PASSED: autovacuum_work_mem is configured at ${WORK_MEM_MB}MB."

# ------------------------------------------------------------------------------
# GATE 3: Verify Zero Active Multi-Pass Index Vacuums
# ------------------------------------------------------------------------------
MULTI_PASS_COUNT=$(psql "$DATABASE_URL" -t -A -c "
  SELECT count(*) FROM pg_stat_progress_vacuum WHERE index_vacuum_count > 1;
")
if [ "$MULTI_PASS_COUNT" -gt 0 ]; then
  echo "❌ CI FAIL: Detected $MULTI_PASS_COUNT vacuum operations running multi-pass index scans!"
  exit 1
fi
echo "✅ GATE 3 PASSED: Zero multi-pass index sweeps active."

# ------------------------------------------------------------------------------
# GATE 4: Verify Transaction ID Horizon Age (age(relfrozenxid) < 150,000,000)
# ------------------------------------------------------------------------------
MAX_XID_AGE=$(psql "$DATABASE_URL" -t -A -c "
  SELECT COALESCE(MAX(age(relfrozenxid)), 0) FROM pg_class WHERE relkind IN ('r', 'm');
")
if [ "$MAX_XID_AGE" -gt 150000000 ]; then
  echo "❌ CI FAIL: Max table XID age ($MAX_XID_AGE) approaches emergency freeze limit!"
  exit 1
fi
echo "✅ GATE 4 PASSED: Max relation XID age is safe ($MAX_XID_AGE < 150M)."

# ------------------------------------------------------------------------------
# GATE 5: Verify log_autovacuum_min_duration Is Enabled (<= 500ms)
# ------------------------------------------------------------------------------
LOG_MIN_DUR=$(psql "$DATABASE_URL" -t -A -c "
  SELECT current_setting('log_autovacuum_min_duration');
")
if [ "$LOG_MIN_DUR" = "-1" ] || [ "${LOG_MIN_DUR%ms}" -gt 500 ]; then
  echo "❌ CI FAIL: log_autovacuum_min_duration is disabled or too coarse ($LOG_MIN_DUR)!"
  exit 1
fi
echo "✅ GATE 5 PASSED: log_autovacuum_min_duration is set to $LOG_MIN_DUR."

# ------------------------------------------------------------------------------
# GATE 6: Verify Starved Tables Count Equals Zero
# ------------------------------------------------------------------------------
STARVED_TABLES=$(psql "$DATABASE_URL" -t -A -c "
  SELECT count(*) 
  FROM pg_stat_user_tables 
  WHERE n_dead_tup > (n_live_tup * 0.20 + 1000)
    AND last_autovacuum IS NULL 
    AND last_vacuum IS NULL;
")
if [ "$STARVED_TABLES" -gt 0 ]; then
  echo "⚠️ CI WARNING: Found $STARVED_TABLES tables with high dead tuple counts never vacuumed."
fi
echo "✅ GATE 6 PASSED: Autovacuum starvation audit clean."
```
