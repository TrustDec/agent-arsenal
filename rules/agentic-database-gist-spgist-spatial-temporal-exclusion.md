---
description: PostgreSQL GiST (Generalized Search Tree) and SP-GiST (Space-Partitioned GiST) indexing, PostGIS spatial geometry/geography, temporal range exclusion constraints (EXCLUDE USING gist), k-NN distance operator (<->) search, and collision defense across Go (pgx/v5), TypeScript (Drizzle/Kysely/Prisma), Python (psycopg3/GeoAlchemy2), Rust (tokio-postgres/geo), and autonomous agents (Claude Code, Cursor, Windsurf, Devin, Roo Code, Pi)
globs: **/*{spatial,geo,gis,gist,spgist,temporal,schedule,booking,reservation,range,geometry,geography,overlap,collision}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database GiST & SP-GiST Indexing, Spatial Geometry, Temporal Range Exclusion & Collision Defense

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design geospatial systems, booking platforms, scheduling engines, calendar architectures, physical fleet tracking, or multi-dimensional range indexes inside PostgreSQL (`GiST`, `SP-GiST`, `btree_gist`, `PostGIS`), Go (`jackc/pgx/v5`), TypeScript (`Drizzle`, `Kysely`, `Prisma`), Python (`psycopg3`, `GeoAlchemy2`), or Rust (`tokio-postgres`, `geo`). Eliminate the "Temporal Overlap & Double-Booking Race Condition Disaster" (where agents execute an application-level pre-check `SELECT COUNT(*) FROM bookings WHERE room_id = $1 AND period && $2` before issuing `INSERT INTO bookings`, allowing concurrent transactions under standard `READ COMMITTED` or `REPEATABLE READ` to both observe zero conflicts and insert overlapping reservations, when declarative PostgreSQL Exclusion Constraints `EXCLUDE USING gist` with `btree_gist` guarantee serializable non-overlapping invariant enforcement at engine level with zero transaction isolation overhead), the "GiST Lossy Page & Recheck Overhead Penalty" (where bounding box overlapping in dense spatial datasets triggers massive `Rows Removed by Index Recheck: 120,000` execution penalties and burns CPU cycles re-evaluating polygons from heap tuples, when GiST buffering and SP-GiST space-partitioning eliminate bounding box overlap), the "PostGIS Geography vs Geometry Spatial Trap & Cartesian SRID Mismatch" (where agents store geospatial coordinates as unprojected `GEOMETRY(Point, 4326)` in angular degrees and query distances using `ST_DWithin(geom, $1, 1000)` assuming meters, which actually evaluates 1,000 degrees [$\approx 111,000\text{ km}$] or cast `geom::geography` inside query predicates bypassing the GiST index and triggering full-table sequential scans across millions of coordinates), the "GiST vs SP-GiST Space-Partitioning Misalignment" (where agents force standard balanced GiST R-trees onto heavily clustered, non-uniform 2D spatial distributions or phone/IP prefixes where internal bounding boxes heavily overlap, whereas unbalanced Space-Partitioned GiST `spgist` Quadtrees partition space disjointly, eliminating branch overlaps and delivering $2\times–5\times$ faster point lookups), the "k-Nearest Neighbors (k-NN) Distance Operator `<->` Ordering Stagnation" (where proximity queries execute `ORDER BY ST_Distance(location, $1) LIMIT 10`, forcing PostgreSQL to evaluate geometric distances on every single row and execute expensive external disk sorts, when the GiST `<->` operator performs an index-driven branch-and-bound nearest-neighbor walk returning the top-$K$ items in $<1\text{ms}$), and the "GiST Index Bloat & Split-Cascade Degeneracy" (where frequent updates to ranges or spatial coordinates cause GiST leaf pages to fragment without B-tree style re-balancing, requiring calibrated `fillfactor = 85`, `buffering = on` during bulk builds, and periodic online `REINDEX CONCURRENTLY` management) by establishing a strict 5-Tier GiST & SP-GiST Governance Ladder, PostGIS SRID projection tiers, declarative exclusion constraints, and machine-verifiable CI sentinels.

---

## 1. Architectural Taxonomy: The 6 GiST/SP-GiST Catastrophes vs The 5-Tier Governance Ladder

Multi-dimensional data (geographic coordinates, polygons, calendar time-ranges, numeric intervals, IP address subnets) cannot be ordered on a linear 1-dimensional number line. Standard B-Tree indexes rely on strict scalar ordering ($A < B < C$), making them fundamentally incapable of indexing multi-dimensional containment, intersection, bounding box overlaps, or nearest-neighbor distance metrics.

PostgreSQL solves this with **GiST** (Generalized Search Tree) and **SP-GiST** (Space-Partitioned GiST). However, when autonomous coding agents generate schemas and queries involving spatial points or temporal schedules, LLMs routinely introduce catastrophic architectural anti-patterns:

```typescript
// ❌ CATASTROPHIC LLM GIST & TEMPORAL/SPATIAL ANTI-PATTERNS

// 1. The Application-Level Pre-Check Race Condition! (Double-Booking Catastrophe)
// Under READ COMMITTED / REPEATABLE READ, two concurrent transactions both run this SELECT,
// both receive count === 0, and both execute INSERT. The conference room / doctor is double-booked!
const conflict = await db.query(`
  SELECT count(*) FROM room_bookings
  WHERE room_id = $1 AND booking_period && tstzrange($2, $3, '[)');
`, [roomId, start, end]);

if (conflict.rows[0].count === '0') {
  await db.query(`
    INSERT INTO room_bookings (room_id, booking_period)
    VALUES ($1, tstzrange($2, $3, '[)'));
  `, [roomId, start, end]);
}

// 2. The PostGIS Geography vs Geometry Trap & Degree Miscalculation!
// GEOMETRY(Point, 4326) operates in degrees! ST_DWithin with 5000 checks 5,000 degrees (~555,000 km)!
// It matches the entire planet 14 times over!
await db.query(`
  CREATE TABLE delivery_drivers (
    id UUID PRIMARY KEY,
    location GEOMETRY(Point, 4326) -- Angular coordinates in degrees!
  );
  -- Querying meters against angular degrees:
  SELECT * FROM delivery_drivers WHERE ST_DWithin(location, ST_MakePoint($1, $2), 5000);
`);

// 3. The Runtime Cast Index-Bypass Trap!
// Query casts geom to geography inside the WHERE clause: ST_DWithin(location::geography, ...).
// The planner CANNOT use the GiST index on location! Runs a 14-second full-table Seq Scan!
const drivers = await db.query(`
  SELECT id FROM delivery_drivers
  WHERE ST_DWithin(location::geography, ST_MakePoint($1, $2)::geography, 5000);
`);

// 4. The k-NN Distance Ordering Meltdown!
// Ordering by ST_Distance calculates distance for all 5,000,000 rows and runs an external disk sort!
// Missing the GiST distance operator <-> !
const nearest = await db.query(`
  SELECT id FROM stores
  ORDER BY ST_Distance(location, ST_MakePoint($1, $2)::geography)
  LIMIT 10;
`);
```

### The 6 Catastrophes of Autonomous GiST & Spatial/Temporal Architectures

1. **The Temporal Overlap & Double-Booking Race Condition Disaster**:
   Autonomous agents routinely attempt to guard against overlapping reservations by executing an application-level check (`SELECT COUNT(*) ... WHERE period && new_period`) followed by an `INSERT`. In concurrent environments, this violates ACID atomicity. Two simultaneous booking requests for the same room or driver both see zero conflicts in their transaction snapshots and commit conflicting rows. Relying on `SERIALIZABLE` transaction isolation introduces high abort/retry rates (`SQLSTATE 40001`) and thrashing under load. The only declarative, zero-retry database-engine invariant is PostgreSQL **Exclusion Constraints** (`EXCLUDE USING gist`) with `btree_gist`, which enforces mathematical non-overlap at the storage engine level with zero application-level race windows.
2. **The GiST Lossy Page & Recheck Overhead Penalty (`Rows Removed by Index Recheck`)**:
   GiST indexes store bounding boxes (Minimum Bounding Rectangles - MBR). When bounding boxes overlap heavily in the tree or when internal GiST pages become lossy, the index scan returns candidate physical tuples that may not actually satisfy the search predicate. PostgreSQL must then fetch the physical heap tuples and execute a CPU-intensive runtime filter, shown in `EXPLAIN (ANALYZE, BUFFERS)` as `Rows Removed by Index Recheck: 120,000`. If agents fail to cluster spatial data, calibrate range bounds, or partition high-overlap datasets, query latency spikes by $10\times–50\times$.
3. **The PostGIS Geography vs Geometry Spatial Trap & Cartesian SRID Mismatch**:
   `GEOMETRY(Point, 4326)` stores coordinates on the WGS 84 spatial reference system in **angular degrees** (longitude, latitude). When agents run `ST_DWithin(geom, point, 1000)` expecting 1,000 meters, PostGIS evaluates 1,000 degrees ($\approx 111,000\text{ km}$), matching all records on Earth. When agents realize the unit mismatch, they naively cast the column in the query (`WHERE ST_DWithin(geom::geography, point::geography, 1000)`), which invalidates the GiST index on `geom` and forces a full-table sequential scan. True production architecture dictates using native `GEOGRAPHY(Point, 4326)` for metric distance calculations on spherical coordinates, or projected Cartesian systems like `GEOMETRY(Point, 3857)` (Web Mercator) with explicit planar SRID transforms.
4. **The GiST vs SP-GiST Space-Partitioning Misalignment**:
   GiST implements a balanced tree where child bounding boxes are permitted to overlap. In datasets with heavy geographic clustering (e.g. 95% of deliveries clustered in downtown metropolitan zones) or high-density IP ranges, GiST nodes overlap substantially, forcing index scans to descend multiple tree branches simultaneously. **SP-GiST** (Space-Partitioned GiST) implements disjoint space decomposition (such as 2D Quadtrees for spatial points, Radix trees for `inet`/`cidr` subnets, and Prefix tries for text/ranges). Because SP-GiST partitions space into non-overlapping quadrants, point queries descend a single deterministic path without branch backtracking, delivering $2\times–5\times$ faster lookups on skewed data.
5. **The k-Nearest Neighbors (k-NN) Distance Operator `<->` Ordering Stagnation**:
   When users ask for "the 10 closest restaurants or drivers", agents write `ORDER BY ST_Distance(location, :target) LIMIT 10`. The query planner is forced to calculate `ST_Distance` across every tuple in the table, materialize all distances in memory, and execute an `External sort` or `Top-N heapsort`. By contrast, PostGIS and GiST provide the native distance operator `<->`. Using `ORDER BY location <-> :target LIMIT 10` executes a branch-and-bound priority-queue index traversal that visits only the closest bounding boxes in the GiST tree, completing in $<1\text{ms}$ with zero heap full-scans.
6. **The GiST Index Bloat & Split-Cascade Degeneracy**:
   Unlike B-Trees, which split pages symmetrically at 50% capacity, GiST uses domain-specific penalty and `picksplit` heuristics to partition multi-dimensional bounding boxes. Under heavy in-place `UPDATE` and `DELETE` churn, GiST leaf pages become fragmented and internal bounding boxes expand to encompass dead space, causing progressive degradation in index pruning efficiency. Furthermore, building massive GiST indexes without `WITH (buffering = on)` results in continuous random I/O thrashing during index creation.

---

### The 5-Tier GiST & SP-GiST Governance Ladder

```
┌────────────────────────────────────────────────────────────────────────┐
│               THE 5-TIER GIST & SP-GIST GOVERNANCE LADDER              │
├────────┬────────────────────────────────┬──────────────────────────────┤
│ Tier 0 │ Declarative Exclusion &        │ btree_gist extension active, │
│        │ Race Condition Defense         │ EXCLUDE USING gist on ranges │
│        │                                │ Zero double-booking races    │
├────────┼────────────────────────────────┼──────────────────────────────┤
│ Tier 1 │ Spatial Typing & Coordinate    │ Native GEOGRAPHY for meters, │
│        │ System Invariance              │ or GEOMETRY(3857) projected; │
│        │                                │ Zero runtime cast bypassing  │
├────────┼────────────────────────────────┼──────────────────────────────┤
│ Tier 2 │ Index-Driven k-NN Proximity    │ Distance operator <-> walk;  │
│        │ Acceleration                   │ branch-and-bound queue, zero │
│        │                                │ full-table ST_Distance sorts │
├────────┼────────────────────────────────┼──────────────────────────────┤
│ Tier 3 │ SP-GiST Quadtree Specialization│ Quadtree USING spgist for    │
│        │ for Skewed Clustered Domains   │ non-overlapping 2D clusters; │
│        │                                │ zero branch overlap penalty  │
├────────┼────────────────────────────────┼──────────────────────────────┤
│ Tier 4 │ Continuous Recheck CI Sentinel │ EXPLAIN BUFFERS verification;│
│        │ & Buffering Build Lifecycle    │ zero lossy page scan cliffs; │
│        │                                │ REINDEX CONCURRENTLY hygiene │
└────────┴────────────────────────────────┴──────────────────────────────┘
```

---

## 2. Mathematical Foundations: R-Tree MBR Calculus, SP-GiST Quadtree Convergence & Geodesic Distortion

### 2.1 R-Tree Minimum Bounding Box (MBR) Expansion Cost Calculus

GiST spatial indexing models multi-dimensional points and geometries using Minimum Bounding Rectangles (MBR). A rectangle $R \subset \mathbb{R}^d$ is defined by its lower and upper coordinate vectors:
$$R = \left[\mathbf{x}_{\min}, \mathbf{x}_{\max}\right] = \prod_{i=1}^d [x_{i,\min}, x_{i,\max}]$$

The volume/area of bounding box $R$ in 2D space is:
$$\text{Area}(R) = (x_{1,\max} - x_{1,\min}) \times (x_{2,\max} - x_{2,\min})$$

When inserting a new geometry with bounding box $r$ into an internal GiST node containing candidate child bounding boxes $\{R_1, R_2, \dots, R_k\}$, GiST's `penalty` method selects the child box $R^*$ that minimizes the **MBR Area Expansion**:
$$\Delta \text{Area}(R_j) = \text{Area}(R_j \cup r) - \text{Area}(R_j)$$
$$R^* = \arg\min_{R_j} \Delta \text{Area}(R_j)$$

**The Overlap Penalty Dilemma**: In dense, non-uniform spatial clusters, multiple $R_j$ boxes may expand to overlap each other:
$$\text{Overlap}(R_i, R_j) = \text{Area}(R_i \cap R_j) > 0$$

When a search query bounding box $Q$ intersects the overlapping region $R_i \cap R_j$, the GiST search algorithm must traverse **both child subtrees**:
$$\mathbb{P}(\text{Multi-Branch Descent}) = \frac{\text{Area}\left(\bigcup_{i \neq j} (R_i \cap R_j)\right)}{\text{Area}\left(\bigcup R_k\right)}$$
As overlap approaches $1.0$, GiST search complexity degrades from $\mathcal{O}(\log_M N)$ to $\mathcal{O}(N)$, degenerating into a sequential scan with index overhead.

---

### 2.2 SP-GiST Quadtree Disjoint Space-Partitioning Convergence

Unlike GiST where sibling bounding boxes can overlap, **SP-GiST Quadtrees** divide 2D continuous space into four mutually disjoint quadrants around a centroid $(x_c, y_c)$:
$$\begin{aligned}
Q_{\text{NW}} &= (-\infty, x_c) \times [y_c, \infty) \\
Q_{\text{NE}} &= [x_c, \infty) \times [y_c, \infty) \\
Q_{\text{SW}} &= (-\infty, x_c) \times (-\infty, y_c) \\
Q_{\text{SE}} &= [x_c, \infty) \times (-\infty, y_c)
\end{aligned}$$

Because the quadrants are pairwise disjoint:
$$Q_a \cap Q_b = \emptyset \quad \forall a \neq b \implies \text{Overlap Factor } \Omega = 0$$

For any search point $\mathbf{p} = (x, y)$, the target quadrant is deterministically computable in $\mathcal{O}(1)$ scalar comparisons:
$$\text{Quadrant}(\mathbf{p}) = \begin{cases}
\text{NW} & \text{if } x < x_c \land y \ge y_c \\
\text{NE} & \text{if } x \ge x_c \land y \ge y_c \\
\text{SW} & \text{if } x < x_c \land y < y_c \\
\text{SE} & \text{if } x \ge x_c \land y < y_c
\end{cases}$$

**Search Complexity Theorem**: For an SP-GiST quadtree indexed on $N$ points with maximum leaf capacity $C$, point lookup visits exactly one node per tree depth level:
$$T_{\text{SP-GiST Point}} = \mathcal{O}(h) \approx \mathcal{O}(\log_4 N)$$
Backtracking is mathematically impossible for exact point queries. For spatial range queries $[x_1, x_2] \times [y_1, y_2]$, only quadrants intersecting the query box are explored.

---

### 2.3 Exclusion Constraint Serializable Equivalence Theorem

Let a reservation record be $R_i = (k_i, T_i)$ where $k_i$ is a discrete resource key (e.g. `room_id`, `driver_id`) and $T_i = [t_{i,\text{start}}, t_{i,\text{end}})$ is a half-open temporal interval.

Two reservations conflict if and only if:
$$\text{Conflict}(R_i, R_j) \iff (k_i = k_j) \land (T_i \cap T_j \neq \emptyset)$$

In standard SQL transactions executing at `READ COMMITTED` or `REPEATABLE READ`, transaction $T_A$ and transaction $T_B$ evaluating:
$$\text{SELECT COUNT(*) WHERE } k = k_0 \land T \cap [t_1, t_2) \neq \emptyset$$
read from isolated MVCC snapshots. Neither transaction has committed its pending insert; therefore, both count queries return $0$. Both transactions proceed to insert their respective records.

**The Exclusion Constraint Proof of Serializable Equivalence**:
PostgreSQL Exclusion Constraints define a predicate:
$$\text{EXCLUDE USING gist } (k \text{ WITH } =, T \text{ WITH } \&\&)$$

During index tuple insertion in PostgreSQL:
1. The engine enters `check_exclusion_constraint()`.
2. It acquires a buffer lock on the GiST index page.
3. It performs a GiST index probe using the exact insert operators: equality on $k$ and interval intersection `&&` on $T$.
4. If an overlapping committed tuple exists, the insertion immediately aborts with `SQLSTATE 23P01 (exclusion_violation)`.
5. If an overlapping uncommitted tuple inserted by concurrent transaction $T_B$ exists, transaction $T_A$ **blocks on $T_B$'s transaction ID lock** (`XWAIT`).
   - If $T_B$ commits: $T_A$ wakes up, detects the conflict in the GiST index, and throws `23P01`.
   - If $T_B$ rolls back: $T_A$ wakes up, verifies no conflict remains, and successfully commits.

$$\mathbb{P}(\text{Overlap Under Exclusion Constraint}) \equiv 0$$
Declarative GiST exclusion constraints achieve serializable non-overlap guarantees at the storage layer while allowing overall system throughput to scale at `READ COMMITTED` speed.

---

### 2.4 Geodesic Haversine / Vincenty Distance vs Planar Euclidean Distortion

The metric distance between two coordinates $(\lambda_1, \phi_1)$ and $(\lambda_2, \phi_2)$ on a spherical Earth of mean radius $R = 6,371,008.8\text{ meters}$ is governed by the Great-Circle Haversine formula:
$$\Delta\sigma = 2 \arcsin \left(\sqrt{\sin^2\left(\frac{\Delta\phi}{2}\right) + \cos \phi_1 \cos \phi_2 \sin^2\left(\frac{\Delta\lambda}{2}\right)}\right)$$
$$d_{\text{geodesic}} = R \cdot \Delta\sigma$$

When an agent mistakenly uses Euclidean planar distance on unprojected longitude/latitude coordinates:
$$d_{\text{Cartesian}} = \sqrt{(\Delta\lambda)^2 + (\Delta\phi)^2} \quad \text{[degrees]}$$

At latitude $\phi$:
- $1^\circ$ of latitude $\approx 111.13\text{ km}$
- $1^\circ$ of longitude $\approx 111.32 \cdot \cos(\phi)\text{ km}$

At latitude $\phi = 60^\circ$ (e.g. Oslo, Stockholm, Helsinki), $\cos(60^\circ) = 0.5$. A degree of longitude is half the physical length of a degree of latitude. A Cartesian Euclidean distance query forms an elongated ellipse in physical space, producing up to **50% spatial distortion error** and invalidating radius-based proximity searches.

**Production Invariant**:
- Use `GEOGRAPHY(Point, 4326)` for true spherical geodesic calculations in meters across global datasets.
- Use `GEOMETRY(Point, 3857)` (Web Mercator) or local Universal Transverse Mercator (UTM) projections for high-speed planar Euclidean computations within a localized zone.
- Never use `ST_DWithin` on `GEOMETRY(Point, 4326)` with an integer distance argument without casting to `geography` or utilizing a functional index.

---

## 3. Production PostgreSQL DDL: Exclusion Constraints, PostGIS & SP-GiST Quadtrees

```sql
-- ============================================================================
-- PRODUCTION GIST, SP-GIST & POSTGIS TEMPORAL/SPATIAL REFERENCE SCHEMA
-- ============================================================================

-- 1. Required PostgreSQL Extensions
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- Enables scalar types (=, <, >) in GiST
CREATE EXTENSION IF NOT EXISTS postgis;     -- Spatial geometry, geography & operators

-- ----------------------------------------------------------------------------
-- ARCHITECTURE 1: MULTI-TENANT RESERVATION SCHEDULING (ZERO RACE CONDITIONS)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS vehicle_rentals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL,
  vehicle_id UUID NOT NULL,
  customer_id UUID NOT NULL,
  -- Half-open interval [start, end) prevents boundary collisions:
  rental_period TSTZRANGE NOT NULL,
  status VARCHAR(32) NOT NULL DEFAULT 'confirmed',
  created_at TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP(),

  -- CHECK: Bounds must be canonical half-open [) and non-empty:
  CONSTRAINT chk_rental_period_valid CHECK (
    NOT isempty(rental_period) AND
    lower_inc(rental_period) AND
    NOT upper_inc(rental_period)
  ),

  -- TIER 0 INVARIANT: Multi-column declarative exclusion constraint!
  -- Guarantees that no two rentals for the same vehicle overlap, scoped to tenant!
  -- Ignores 'cancelled' bookings using a partial exclusion constraint:
  CONSTRAINT uq_vehicle_no_double_booking EXCLUDE USING gist (
    tenant_id WITH =,
    vehicle_id WITH =,
    rental_period WITH &&
  ) WHERE (status <> 'cancelled')
);

-- Index for tenant timeline range queries:
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_rentals_tenant_period
  ON vehicle_rentals USING gist (tenant_id, rental_period);

-- ----------------------------------------------------------------------------
-- ARCHITECTURE 2: POSTGIS HIGH-THROUGHPUT GEOGRAPHIC FLEET TRACKING
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS driver_telemetry (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id UUID NOT NULL,
  tenant_id UUID NOT NULL,
  -- Native spherical GEOGRAPHY in meters (WGS 84 SRID 4326):
  location GEOGRAPHY(Point, 4326) NOT NULL,
  speed_mps NUMERIC(5, 2) NOT NULL DEFAULT 0.0,
  heading_deg NUMERIC(5, 2) NOT NULL DEFAULT 0.0,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP()
);

-- TIER 1 & 2 INVARIANT: GiST index on native geography with fillfactor headroom
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_driver_telemetry_location_gist
  ON driver_telemetry USING gist (location)
  WITH (fillfactor = 85);

-- Compound index for tenant + time pruning:
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_driver_telemetry_tenant_time
  ON driver_telemetry (tenant_id, recorded_at DESC);

-- ----------------------------------------------------------------------------
-- ARCHITECTURE 3: SP-GIST QUADTREE FOR CLUSTERED 2D DISJOINT SEARCH
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS spatial_points_of_interest (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category VARCHAR(64) NOT NULL,
  -- 2D Geometric Point for Cartesian / localized Quadtree partitioning:
  coordinates POINT NOT NULL,
  title VARCHAR(255) NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- TIER 3 INVARIANT: SP-GiST Quadtree eliminates bounding box overlap in dense clusters
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_poi_coordinates_spgist
  ON spatial_points_of_interest USING spgist (coordinates);

-- ----------------------------------------------------------------------------
-- SARGABLE PRODUCTION QUERIES WITH ZERO INDEX BYPASS
-- ----------------------------------------------------------------------------

-- Query A: Safe Atomic Booking Insertion (Guaranteed Conflict Freedom)
-- If concurrent insert conflicts, PostgreSQL raises SQLSTATE 23P01 (exclusion_violation)
INSERT INTO vehicle_rentals (tenant_id, vehicle_id, customer_id, rental_period)
VALUES (
  'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID,
  'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22'::UUID,
  'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33'::UUID,
  tstzrange('2026-11-01 10:00:00+00', '2026-11-01 14:00:00+00', '[)')
)
RETURNING id, rental_period;

-- Query B: Index-Accelerated k-NN Proximity Search via GiST <-> Distance Operator
-- Runs in < 1ms using branch-and-bound traversal, avoiding full-table distance sorting!
SELECT
  driver_id,
  location,
  ST_Distance(location, ST_SetSRID(ST_MakePoint(-73.9851, 40.7488), 4326)::geography) AS distance_meters
FROM driver_telemetry
WHERE tenant_id = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID
  AND recorded_at >= NOW() - INTERVAL '5 minutes'
ORDER BY location <-> ST_SetSRID(ST_MakePoint(-73.9851, 40.7488), 4326)::geography
LIMIT 10;

-- Query C: PostGIS Metric Radius Search via ST_DWithin (In Meters)
-- Sizable index seek on GiST without runtime casts!
SELECT driver_id, speed_mps, recorded_at
FROM driver_telemetry
WHERE ST_DWithin(
  location,
  ST_SetSRID(ST_MakePoint(-73.9851, 40.7488), 4326)::geography,
  3000 -- Exactly 3,000 meters (3km)
);
```

---

## 4. Application-Layer Invariants: Go (`pgx/v5`) & TypeScript (`Drizzle`/`Kysely`)

### 4.1 Go 1.24+ (`jackc/pgx/v5`): Range Handling, PostGIS Decoding & `23P01` Error Mapping

In Go applications, interacting with PostgreSQL temporal ranges and spatial constraints requires handling `pgtype.Range[T]` with half-open intervals and mapping PostgreSQL error code `23P01` (`exclusion_violation`) to a clean `HTTP 409 Conflict`.

```go
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgerrcode"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrReservationConflict = errors.New("reservation conflicts with an existing booking window")
	ErrInvalidPeriod       = errors.New("start time must precede end time")
)

type RentalRepository struct {
	pool *pgxpool.Pool
}

func NewRentalRepository(pool *pgxpool.Pool) *RentalRepository {
	return &RentalRepository{pool: pool}
}

// CreateRental atomically creates a rental record, protected by PostgreSQL Exclusion Constraint.
func (r *RentalRepository) CreateRental(
	ctx context.Context,
	tenantID, vehicleID, customerID uuid.UUID,
	start, end time.Time,
) (uuid.UUID, error) {
	if !start.Before(end) {
		return uuid.Nil, ErrInvalidPeriod
	}

	// Construct canonical half-open [start, end) interval:
	rentalRange := pgtype.Range[time.Time]{
		Lower:     start.UTC(),
		Upper:     end.UTC(),
		LowerType: pgtype.Inclusive,
		UpperType: pgtype.Exclusive,
		Valid:     true,
	}

	query := `
		INSERT INTO vehicle_rentals (tenant_id, vehicle_id, customer_id, rental_period)
		VALUES ($1, $2, $3, $4)
		RETURNING id;
	`

	var rentalID uuid.UUID
	err := r.pool.QueryRow(ctx, query, tenantID, vehicleID, customerID, rentalRange).Scan(&rentalID)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) {
			// Catch PostgreSQL SQLSTATE 23P01 (exclusion_violation)
			if pgErr.Code == pgerrcode.ExclusionViolation {
				return uuid.Nil, fmt.Errorf("%w: vehicle is already booked for this period", ErrReservationConflict)
			}
		}
		return uuid.Nil, fmt.Errorf("failed to insert rental: %w", err)
	}

	return rentalID, nil
}

// NearestDriver represents a driver located via GiST <-> branch-and-bound walk.
type NearestDriver struct {
	DriverID       uuid.UUID
	DistanceMeters float64
}

// FindNearestDrivers executes an index-accelerated k-NN proximity query.
func (r *RentalRepository) FindNearestDrivers(
	ctx context.Context,
	tenantID uuid.UUID,
	lon, lat float64,
	limit int,
) ([]NearestDriver, error) {
	query := `
		SELECT
			driver_id,
			ST_Distance(location, ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography) AS dist_meters
		FROM driver_telemetry
		WHERE tenant_id = $1
		  AND recorded_at >= NOW() - INTERVAL '5 minutes'
		ORDER BY location <-> ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography
		LIMIT $4;
	`

	rows, err := r.pool.Query(ctx, query, tenantID, lon, lat, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to query nearest drivers: %w", err)
	}
	defer rows.Close()

	drivers := make([]NearestDriver, 0, limit)
	for rows.Next() {
		var d NearestDriver
		if err := rows.Scan(&d.DriverID, &d.DistanceMeters); err != nil {
			return nil, fmt.Errorf("scan error: %w", err)
		}
		drivers = append(drivers, d)
	}

	return drivers, rows.Err()
}
```

---

### 4.2 TypeScript / Kysely: Exclusion Handling & PostGIS Query Construction

```typescript
import { Kysely, sql } from 'kysely';

export interface VehicleRentalTable {
  id: string;
  tenant_id: string;
  vehicle_id: string;
  customer_id: string;
  rental_period: unknown; // PostgreSQL tstzrange
  status: string;
  created_at: Date;
}

export interface Database {
  vehicle_rentals: VehicleRentalTable;
}

export class RentalService {
  constructor(private readonly db: Kysely<Database>) {}

  public async bookVehicle(params: {
    tenantId: string;
    vehicleId: string;
    customerId: string;
    start: Date;
    end: Date;
  }): Promise<{ id: string }> {
    if (params.start >= params.end) {
      throw new Error('Start time must precede end time');
    }

    try {
      // Pass canonical half-open tstzrange [start, end)
      const result = await sql<{ id: string }>`
        INSERT INTO vehicle_rentals (tenant_id, vehicle_id, customer_id, rental_period)
        VALUES (
          ${params.tenantId}::UUID,
          ${params.vehicleId}::UUID,
          ${params.customerId}::UUID,
          tstzrange(${params.start.toISOString()}::timestamptz, ${params.end.toISOString()}::timestamptz, '[)')
        )
        RETURNING id
      `.execute(this.db);

      return result.rows[0];
    } catch (error: any) {
      // PostgreSQL SQLSTATE 23P01: exclusion_violation
      if (error?.code === '23P01') {
        const customErr = new Error('Vehicle is already booked during this time interval');
        (customErr as any).statusCode = 409;
        throw customErr;
      }
      throw error;
    }
  }

  public async findNearestDrivers(params: {
    tenantId: string;
    lon: number;
    lat: number;
    limit: number;
  }) {
    // Uses GiST <-> distance operator for sub-millisecond branch-and-bound traversal
    return await sql<{ driver_id: string; distance_meters: number }>`
      SELECT
        driver_id,
        ST_Distance(location, ST_SetSRID(ST_MakePoint(${params.lon}, ${params.lat}), 4326)::geography) AS distance_meters
      FROM driver_telemetry
      WHERE tenant_id = ${params.tenantId}::UUID
        AND recorded_at >= NOW() - INTERVAL '5 minutes'
      ORDER BY location <-> ST_SetSRID(ST_MakePoint(${params.lon}, ${params.lat}), 4326)::geography
      LIMIT ${params.limit}
    `.execute(this.db);
  }
}
```

---

## 5. Full Production TypeScript `AgenticDatabaseGiSTEngine` Reference Implementation

```typescript
/**
 * AgenticDatabaseGiSTEngine
 * Production-grade validation, inspection, and migration engine for PostgreSQL
 * GiST, SP-GiST, PostGIS spatial and temporal exclusion constraint architectures.
 */

export interface GiSTIndexMetrics {
  indexName: string;
  tableName: string;
  indexType: 'gist' | 'spgist';
  isExclusionConstraint: boolean;
  totalSizeHuman: string;
  indexedColumns: string[];
  recheckRowsEstimated: number;
  hasBtreeGistExtension: boolean;
}

export interface ExclusionConflictCheckResult {
  hasConflict: boolean;
  conflictingRowId?: string;
  sqlState?: string;
}

export class AgenticDatabaseGiSTEngine {
  /**
   * Generates a safe, zero-downtime DDL payload for temporal exclusion constraints.
   */
  public static generateExclusionConstraintDDL(options: {
    tableName: string;
    constraintName: string;
    equalityColumns: string[];
    rangeColumn: string;
    predicateFilter?: string;
  }): string {
    const equalityClauses = options.equalityColumns
      .map((col) => `    ${col} WITH =`)
      .join(',\n');

    const predicate = options.predicateFilter
      ? `\n  WHERE (${options.predicateFilter})`
      : '';

    return `-- 1. Ensure btree_gist extension is installed
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- 2. Declarative exclusion constraint preventing temporal overlaps
ALTER TABLE ${options.tableName}
  ADD CONSTRAINT ${options.constraintName}
  EXCLUDE USING gist (
${equalityClauses},
    ${options.rangeColumn} WITH &&
  )${predicate};
`;
  }

  /**
   * Generates a sargable PostGIS k-NN proximity query using the <-> distance operator.
   */
  public static generateKNNProximitySQL(options: {
    tableName: string;
    geographyColumn: string;
    filterColumn?: string;
    filterValueParam: string;
    lonParam: string;
    latParam: string;
    limitParam: string;
  }): string {
    const filterClause = options.filterColumn
      ? `WHERE ${options.filterColumn} = ${options.filterValueParam}\n  `
      : 'WHERE ';

    return `SELECT
  id,
  ${options.geographyColumn},
  ST_Distance(
    ${options.geographyColumn},
    ST_SetSRID(ST_MakePoint(${options.lonParam}, ${options.latParam}), 4326)::geography
  ) AS distance_meters
FROM ${options.tableName}
${filterClause}ORDER BY ${options.geographyColumn} <-> ST_SetSRID(ST_MakePoint(${options.lonParam}, ${options.latParam}), 4326)::geography
LIMIT ${options.limitParam};`;
  }

  /**
   * Validates whether a spatial query is prone to the angular degree vs meter trap.
   */
  public static auditSpatialQueryPlan(planText: string): {
    isVulnerableToDegreeMismatch: boolean;
    hasSeqScanIndexBypass: boolean;
    hasRecheckOverheadWarning: boolean;
  } {
    const isVulnerableToDegreeMismatch =
      planText.includes('geometry') &&
      planText.includes('st_dwithin') &&
      !planText.includes('geography');

    const hasSeqScanIndexBypass =
      planText.includes('Seq Scan') &&
      (planText.includes('location') || planText.includes('coordinates') || planText.includes('geom'));

    const hasRecheckOverheadWarning =
      /Rows Removed by Index Recheck:\s*([1-9]\d{3,})/.test(planText);

    return {
      isVulnerableToDegreeMismatch,
      hasSeqScanIndexBypass,
      hasRecheckOverheadWarning,
    };
  }

  /**
   * Audits database schema to ensure btree_gist is loaded when exclusion constraints exist.
   */
  public static generateVerificationAuditSQL(): string {
    return `WITH exclusion_constraints AS (
  SELECT
    c.conname AS constraint_name,
    cls.relname AS table_name,
    am.amname AS index_type
  FROM pg_constraint c
  JOIN pg_class cls ON c.conrelid = cls.oid
  JOIN pg_am am ON am.amname IN ('gist', 'spgist')
  WHERE c.contype = 'x'
),
installed_extensions AS (
  SELECT extname FROM pg_extension WHERE extname = 'btree_gist'
)
SELECT
  ec.constraint_name,
  ec.table_name,
  ec.index_type,
  EXISTS (SELECT 1 FROM installed_extensions) AS has_btree_gist
FROM exclusion_constraints ec;`;
  }
}
```

---

## 6. 6-State GiST & Exclusion Lifecycle Finite-State Machine (FSM)

```
        ┌────────────────────────────────────────────────────────┐
        │                     [S0: UNINDEXED]                   │
        │           No GiST / SP-GiST Index Configured          │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │                 [S1: EXTENSION_HYDRATED]               │
        │       btree_gist / postgis extensions verified         │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │                 [S2: SCHEMA_DECLARED]                  │
        │     EXCLUDE USING gist or native GEOGRAPHY column      │
        │       Half-open canonical bounds [) guaranteed         │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │                 [S3: INDEX_CONSTRUCTED]                │
        │      CREATE INDEX CONCURRENTLY with fillfactor 85      │
        │        SP-GiST quadtree for skewed 2D clusters         │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │                 [S4: SARGABLE_ACTIVE]                  │
        │       Queries use <-> for k-NN & ST_DWithin metric     │
        │         Zero runtime castSeq Scan bypasses             │
        └──────────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
        ┌────────────────────────────────────────────────────────┐
        │                 [S5: HYGIENE_AUDITED]                  │
        │        Zero 'Rows Removed by Recheck' cliffs           │
        │       Periodic REINDEX CONCURRENTLY scheduled          │
        └────────────────────────────────────────────────────────┘
```

---

## 7. 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

| Gate | Verification Target | Deterministic Metric / Pass Criterion | Remediation if Failed |
|---|---|---|---|
| **Gate 1: Race Invariance** | Exclusion Constraint Enforcement | Table has `EXCLUDE USING gist` for overlapping intervals. Application-level `SELECT COUNT` race is 100% eliminated. | Add `EXCLUDE USING gist (resource_id WITH =, period WITH &&)`. |
| **Gate 2: Extension Parity** | `btree_gist` Availability | Extension `btree_gist` is registered in `pg_extension` before deploying multi-column exclusion constraints. | Run `CREATE EXTENSION IF NOT EXISTS btree_gist;`. |
| **Gate 3: Unit Metric Invariance** | Geodesic vs Planar Typing | Distance queries on longitude/latitude use native `GEOGRAPHY(Point, 4326)` or projected coordinates, never raw degrees. | Convert column to `geography` or use functional index with explicit projection. |
| **Gate 4: Proximity Search Sizing** | k-NN Operator Utilization | Proximity `ORDER BY` queries utilize `<->` operator class; `EXPLAIN` confirms `Index Scan using ... (location <-> ...)`. | Replace `ORDER BY ST_Distance(...)` with `ORDER BY location <-> ... LIMIT K`. |
| **Gate 5: Disjoint Quadtree Efficiency**| SP-GiST on Clustered 2D Data | Highly non-uniform 2D point datasets utilize `USING spgist` to eliminate internal bounding box overlap. | Rebuild index using `CREATE INDEX ... USING spgist (coordinates)`. |
| **Gate 6: Recheck Bloat Invariance** | Zero Lossy Recheck Spikes | `EXPLAIN (ANALYZE, BUFFERS)` confirms `Rows Removed by Index Recheck < 100`. Zero sequential scan fallbacks in CI. | Optimize clustering, lower `fillfactor`, or execute `REINDEX CONCURRENTLY`. |

---

## 8. Anti-Patterns & Verification Checklist

- [ ] **No Application-Level Pre-Checks**: Never rely on `SELECT count(*) WHERE period && new_period` before `INSERT`. Under concurrent transactions, this causes double bookings. Always enforce `EXCLUDE USING gist`.
- [ ] **Map SQLSTATE `23P01` to HTTP 409 Conflict**: Catch `exclusion_violation` errors in application layers (Go `pgerrcode.ExclusionViolation`, TypeScript `error.code === '23P01'`) and translate them cleanly to user-friendly conflict messages.
- [ ] **Enforce Half-Open Canonical Bounds `[)`**: Always use `[)` ranges (`tstzrange(start, end, '[)')`). Closed intervals `[]` cause phantom collisions on exact boundary endpoints (e.g. 10:00:00 to 11:00:00 conflicting with 11:00:00 to 12:00:00).
- [ ] **Avoid Runtime Casts on Indexed Spatial Columns**: Never write `WHERE ST_DWithin(geom::geography, ...)` against an index on `geom`. The planner will bypass the index and perform a full-table sequential scan. Build the index directly on `geography` or use an expression index.
- [ ] **Use `<->` for Proximity Search**: Never write `ORDER BY ST_Distance(location, target) LIMIT K`. Always use `ORDER BY location <-> target LIMIT K` to execute an index-driven branch-and-bound walk.
- [ ] **Tune `fillfactor = 85` on Churned GiST Tables**: GiST pages fragment under updates. Giving pages 15% headroom prevents premature node splits.
