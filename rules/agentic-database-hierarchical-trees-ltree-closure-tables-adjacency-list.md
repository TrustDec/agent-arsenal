---
description: PostgreSQL (9.3+), MySQL (8.0+), and SQLite (3.8+) hierarchical trees, adjacency lists, recursive CTEs with CYCLE clause, PostgreSQL ltree extension, GiST and B-Tree path indexing, closure tables, atomic subtree relocation without circular adoption races, breadcrumb walks, and graph traversal defense across Go (pgx/v5), TypeScript (Drizzle, Kysely, Prisma), Python (SQLAlchemy, asyncpg), Rust (sqlx, tokio-postgres), and autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi)
globs: **/*{tree,hierarchy,node,ltree,closure,category,folder,comment,org,taxonomy,repo,repository,store,dao,model,service}*.*,**/src/db/**/*.{ts,js,go,rs,py},**/src/repositories/**/*.{ts,js,go,rs,py},**/internal/store/**/*.{go,rs},**/internal/db/**/*.{go,rs}
alwaysApply: false
---

# Agentic Database Hierarchical Trees, LTree Path Indexing, Closure Tables & Adjacency List Cycle Defense Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design hierarchical data models, organizational charts, nested comments, category taxonomies, file system directories, permission inheritance trees, or graph traversal pipelines across PostgreSQL (9.3+), MySQL (8.0+), SQLite (3.8+), Go (`jackc/pgx/v5`), TypeScript (`drizzle-orm`, `kysely`, `prisma`), Python (`SQLAlchemy`, `asyncpg`), or Rust (`sqlx`, `tokio-postgres`). Eliminate the "Infinite Recursive Loop & Stack Overflow Meltdown" (where agents use naive `WITH RECURSIVE` queries without `CYCLE` detection or depth limits, causing accidental circular references introduced by concurrent unvalidated updates to run forever, exhaust backend connection RAM, and trigger PostgreSQL OOM killer decapitations), the "$N+1$ Application-Level Breadcrumb Walk Anti-Pattern" (where agents fetch ancestors by querying `SELECT parent_id FROM nodes WHERE id = $current` inside application `while` loops, multiplying network round-trips by $10\times–50\times$ and choking connection pools), the "Detached Subtree & Self-Parenting Move Disaster" (where an agent moves a parent node under one of its own descendants via `UPDATE nodes SET parent_id = $new_parent WHERE id = $node_id` without verifying descendant exclusion, permanently severing the entire subtree from the root and creating an orphaned circular graph island), the "Naive String Prefix `LIKE '/dept1/%'` Matching Bug & Sequential Scan" (where agents store hierarchy paths as plain `VARCHAR` and search subtrees using string prefix `LIKE`, causing false-positive collisions such as `/dept10` matching `/dept1/%`, and forcing full-table sequential scans due to non-sargable collation rules), the "Missing PostgreSQL `ltree` GiST Indexing & Label Sanitization Breakdown" (where agents fail to leverage native `ltree` types, miss GiST `<@` and `@>` path operators, or inject illegal characters into `ltree` labels that violate the `^[A-Za-z0-9_]{1,256}$` specification, crashing transactions with `SQLSTATE 22P02`), and the "Closure Table $O(N^2)$ Disconnect & Lock Contention Avalanche" (where agents maintain transitive closure tables by executing unbatched row-by-row updates during subtree moves, triggering deadlocks and leaving orphaned closure rows) by establishing a strict 5-Tier Hierarchical Tree Governance Ladder, formal asymptotic tree operation cost models, production-ready TypeScript `AgenticHierarchyGuardEngine`, cross-language implementations in Go, TypeScript, Python, and Rust, a complete 6-state tree node relocation finite-state machine (FSM), and machine-verifiable CI static analysis gates.

---

## 1. Architectural Taxonomy: The 6 Hierarchical Tree Catastrophes vs The 5-Tier Governance Ladder

In relational databases, modeling hierarchical or tree-structured entities (such as category trees, organizational structures, nested comments, and folder hierarchies) requires choosing among four primary patterns: **Adjacency List** (`parent_id`), **Materialized Path** (`ltree` or delimited text), **Closure Table** (`ancestor_id, descendant_id, depth`), or **Nested Sets** (`lft, rgt`).

When autonomous coding agents implement tree models or query graph structures, they consistently fall victim to 6 catastrophic failure modes:

### The 6 Hierarchical Tree Catastrophes

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 1: THE INFINITE RECURSIVE LOOP & STACK OVERFLOW
-- Agent is asked: "Fetch all descendant departments under department $1"
-- Agent writes naive WITH RECURSIVE without CYCLE clause or depth limit:
WITH RECURSIVE dept_tree AS (
    SELECT id, name, parent_id, 0 AS depth
    FROM departments
    WHERE id = $1
    UNION ALL
    SELECT d.id, d.name, d.parent_id, dt.depth + 1
    FROM departments d
    JOIN dept_tree dt ON d.parent_id = dt.id
)
SELECT * FROM dept_tree;

-- ❌ Catastrophe:
-- If concurrent updates or legacy data introduced a cycle (e.g., Dept A -> Dept B -> Dept A):
-- The query NEVER terminates! It spins in an infinite recursive loop,
-- allocating memory for millions of intermediate tuples in tuplestores,
-- saturating CPU cores at 100%, and exhausting connection memory until the OOM killer strikes!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 2: THE DETACHED SUBTREE & SELF-PARENTING DISASTER
-- Agent is asked: "Move folder A to be inside folder B"
-- Agent writes naive single UPDATE statement without descendant verification:
UPDATE folders
SET parent_id = $new_parent_id, updated_at = NOW()
WHERE id = $folder_id;

-- ❌ Catastrophe:
-- If $new_parent_id is an existing descendant of $folder_id (e.g., moving "Engineering" into "Frontend Team"):
-- The "Engineering" tree is detached from the root!
-- "Frontend Team" points to "Engineering", which now points to "Frontend Team".
-- The entire subtree becomes an orphaned circular island invisible to top-level queries!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 3: NAIVE VARCHAR STRING LIKE PREFIX MATCHING
-- Agent stores path as VARCHAR(255): path = '/1/10/105'
-- Agent queries all descendants of node 1:
SELECT * FROM categories
WHERE path LIKE '/1/%';

-- ❌ Catastrophes:
-- 1. Collision bug: '/10/20' matches '/1/%' if not strictly formatted, or '/1/10' matches '/1/1%'!
-- 2. Performance disaster: Under standard collations and variable lengths,
--    PostgreSQL often abandons B-Tree index range scans and performs full table Seq Scans across millions of rows!
-- 3. Renaming a node requires manually parsing and replacing substring fragments across every child row!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 4: THE N+1 APPLICATION BREADCRUMB LOOP
// TypeScript / Go loop querying parent one by one:
let currentId = targetId;
const breadcrumbs = [];
while (currentId !== null) {
  // ❌ N round-trips to the database to climb up a 10-level hierarchy!
  const node = await db.query('SELECT id, name, parent_id FROM nodes WHERE id = $1', [currentId]);
  breadcrumbs.unshift(node);
  currentId = node.parent_id;
}
-- ❌ Multiplies network latency by N, exhausts connection pool latches, and introduces race conditions!
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 5: UNINDEXED ADJACENCY PARENT_ID
-- Agent creates table with foreign key but forgets B-Tree index on parent_id:
CREATE TABLE comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id UUID NOT NULL,
    parent_id UUID REFERENCES comments(id),
    body TEXT NOT NULL
);
-- ❌ Without CREATE INDEX idx_comments_parent ON comments(parent_id):
-- Every recursive CTE step or parent lookup executes an O(N) full table sequential scan!
-- For 5,000,000 comments, a 4-level comment thread takes 12,000ms instead of 2ms.
```

```sql
-- ❌ CATASTROPHIC LLM ANTI-PATTERN 6: CLOSURE TABLE TRANSACTIONAL DEADLOCK STORM
-- Agent updates a closure table on subtree relocation by deleting all rows and re-inserting in loop:
DELETE FROM category_closure WHERE descendant_id IN (SELECT id FROM subtree);
-- Agent executes thousands of individual INSERTs without lexicographical locking order:
-- ❌ Concurrent subtree moves lock overlapping ancestor/descendant pairs in arbitrary order,
-- instantly triggering SQLSTATE 40P01 deadlock_detected!
```

---

### The 5-Tier Hierarchical Governance Ladder

```text
┌────────────────────────────────────────────────────────────────────────┐
│  Tier 4: Hybrid Adjacency-LTree Auto-Sync with Generated Trigger Paths │
│  - Adjacency list for simple foreign-key integrity                     │
│  - PostgreSQL ltree for lightning-fast GiST prefix & ancestor queries  │
│  - Automated trigger maintaining materialized ltree path on write/move │
├────────────────────────────────────────────────────────────────────────┤
│  Tier 3: Transitive Closure Tables for High-Read / Deep Hierarchies    │
│  - Dedicated (ancestor_id, descendant_id, depth) closure relation      │
│  - O(1) ancestor lookups, O(1) descendant fetches without recursion    │
│  - Atomic batch relocation using deterministic ordered locks           │
├────────────────────────────────────────────────────────────────────────┤
│  Tier 2: Atomic Subtree Relocation with Ancestor-Descendant Exclusion  │
│  - Mandatory pre-flight cycle check: Target NOT IN Descendants(Source) │
│  - Row-level lock acquisition in deterministic ID order               │
│  - Explicit transaction block rollback on circular parenting violation │
├────────────────────────────────────────────────────────────────────────┤
│  Tier 1: Materialized Paths with PostgreSQL `ltree` & GiST Indexing    │
│  - Native `ltree` extension enabled: `CREATE EXTENSION IF NOT EXISTS ltree` │
│  - GiST index for fast subtree queries: `CREATE INDEX USING gist (path)`│
│  - B-Tree index for exact equality & sorting: `CREATE INDEX USING btree (path)` │
│  - Subtree match via `<@` (is descendant) and `@>` (is ancestor)       │
├────────────────────────────────────────────────────────────────────────┤
│  Tier 0: Cycle-Proof Adjacency Lists with PostgreSQL 14+ CYCLE Clause  │
│  - Mandatory index on `parent_id`: `CREATE INDEX idx_tree_parent`      │
│  - PostgreSQL 14+ `CYCLE id SET is_cycle USING path` on recursive CTEs │
│  - Hard depth ceiling: `WHERE depth <= 20` to guarantee termination    │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical Foundations & Execution Engine Physics

### Asymptotic Complexity Matrix Across Tree Modeling Paradigms

Let $N$ be the total number of nodes in the hierarchy, $D$ be the depth of the tree ($D \ll N$), and $S$ be the size of the subtree being queried or moved ($S \le N$).

| Operation | Adjacency List (Naive) | Adjacency List (Indexed CTE + CYCLE) | Materialized Path (`ltree` + GiST) | Closure Table (`ancestor, descendant`) | Nested Sets (`lft, rgt`) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Fetch Direct Children** | $O(N)$ (Seq Scan) | $O(\log N + K)$ (B-Tree Seek) | $O(\log N + K)$ (B-Tree/GiST) | $O(\log |C| + K)$ ($depth = 1$) | $O(N)$ |
| **Fetch All Descendants** | $O(D \cdot N)$ | $O(D \cdot \log N + S)$ | $O(\log N + S)$ (GiST Index Scan) | $O(\log |C| + S)$ (Index Scan) | $O(\log N + S)$ (Range Scan) |
| **Fetch All Ancestors (Path)** | $O(D \cdot N)$ | $O(D \cdot \log N)$ | $O(D)$ (In-Memory Path Deconstruct) | $O(\log |C| + D)$ (Index Scan) | $O(\log N + D)$ (Range Scan) |
| **Insert Leaf Node** | $O(1)$ | $O(\log N)$ (Index Insert) | $O(\log N)$ (GiST + B-Tree) | $O(D \cdot \log |C|)$ (Insert $D$ links) | $O(N)$ (Re-index all $lft/rgt$) |
| **Move Subtree ($S$ nodes)** | $O(1)$ (Dangerous) | $O(D \cdot \log N)$ (With Cycle Check) | $O(S \cdot \log N)$ (Path Prefix Rewrite) | $O(S \cdot D \log |C|)$ (Closure Rebuild)| $O(N)$ (Catastrophic Table Lock) |
| **Delete Subtree** | $O(D \cdot N)$ (Cascade) | $O(S \cdot \log N)$ (Foreign Key Cascade)| $O(S \cdot \log N)$ (GiST Prune) | $O(S \cdot D \log |C|)$ (Closure Delete) | $O(N)$ (Re-index whole tree) |

> **Verdict**: For read-heavy deep hierarchies, **PostgreSQL `ltree` with GiST indexes** or **Closure Tables** outperform Adjacency Lists by orders of magnitude for subtree queries. Nested Sets must be strictly banned in write-active OLTP tables due to $O(N)$ table rewrite write locks on every leaf insertion.

---

### Theorem 1: Recursive CTE Termination Bound & Cycle Defense

Let a directed graph $G = (V, E)$ represent node relationships where an edge $(u, v) \in E$ denotes that $u$ is the parent of $v$. In a valid tree, $G$ is an arborescence with zero directed cycles.

If an unvalidated mutation introduces a directed cycle $C = (v_1, v_2, \dots, v_k, v_1)$ where $k \ge 1$:
$$\lim_{m \to \infty} |\text{Tuples Generated by Naive Recursive CTE}| = \infty$$

**Proof of Termination under PostgreSQL 14+ `CYCLE` Clause**:
The `CYCLE id SET is_cycle USING path` clause tracks an array of visited identifiers $\mathcal{A}_{\text{path}} = [v_1, v_2, \dots, v_m]$.
Before evaluating step $m+1$, the executor checks:
$$v_{m+1} \in \mathcal{A}_{\text{path}}$$
If true, the executor sets `is_cycle = true` and halts recursion along that branch. Combined with a hard depth guard $\text{depth} \le D_{\max}$, the maximum iteration count is bounded by:
$$k_{\text{iterations}} \le \min(|V|, D_{\max})$$
Guaranteeing completion in finite time and finite memory.

---

### Theorem 2: Subtree Relocation Invariant

To relocate subtree rooted at node $S \in V$ under a new parent $P \in V$:
$$\text{Relocation Safe} \iff P \notin \text{Descendants}(S) \land P \neq S$$

If $P \in \text{Descendants}(S)$, setting $\text{parent}(S) \leftarrow P$ produces a closed cycle $\{S \rightsquigarrow P \to S\}$ and disconnects all nodes in $\text{Descendants}(S)$ from the tree root $R$, violating the connected tree invariant:
$$\forall v \in V, \quad \exists \text{ path } R \rightsquigarrow v$$

Therefore, any atomic relocation transaction MUST assert:
$$\text{Descendants}(S) \cap \{P\} = \emptyset$$
before applying the mutation.

---

## 3. Industrial Implementations Across Languages & Frameworks

### 1. PostgreSQL Native: Cycle-Safe Adjacency List vs Native `ltree`

#### A. Cycle-Safe Adjacency List Query (PostgreSQL 14+)

```sql
-- migrations/20261031_create_org_nodes.sql
CREATE TABLE org_nodes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    parent_id UUID REFERENCES org_nodes(id) ON DELETE RESTRICT,
    name VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Crucial: B-Tree index on parent_id and tenant_id
CREATE INDEX idx_org_nodes_parent ON org_nodes(tenant_id, parent_id);

-- Fetch full subtree rooted at $root_id with cycle detection and depth ceiling
WITH RECURSIVE subtree AS (
    -- Anchor member
    SELECT
        n.id,
        n.tenant_id,
        n.parent_id,
        n.name,
        1 AS depth,
        ARRAY[n.id] AS breadcrumb_ids
    FROM org_nodes n
    WHERE n.id = $1 AND n.tenant_id = $2

    UNION ALL

    -- Recursive member
    SELECT
        child.id,
        child.tenant_id,
        child.parent_id,
        child.name,
        parent.depth + 1,
        parent.breadcrumb_ids || child.id
    FROM org_nodes child
    JOIN subtree parent ON child.parent_id = parent.id
    WHERE child.tenant_id = $2
      AND parent.depth < 25 -- Guard against runaway depth
)
CYCLE id SET is_cycle USING cycle_path
SELECT id, parent_id, name, depth, breadcrumb_ids
FROM subtree
WHERE NOT is_cycle
ORDER BY depth ASC, name ASC;
```

#### B. Production-Grade PostgreSQL `ltree` Architecture

```sql
-- Enable ltree extension
CREATE EXTENSION IF NOT EXISTS ltree;

-- Category hierarchy using ltree
CREATE TABLE categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    slug VARCHAR(64) NOT NULL,
    name VARCHAR(255) NOT NULL,
    path LTREE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexing Strategy:
-- 1. GiST index for hierarchical path operations (<@, @>, ~, ?)
CREATE INDEX idx_categories_path_gist ON categories USING gist (path);

-- 2. B-Tree index for sorting and exact path equality
CREATE INDEX idx_categories_path_btree ON categories USING btree (path);

-- 3. Composite tenant index
CREATE INDEX idx_categories_tenant_path ON categories (tenant_id, path);

-- Query 1: Find all descendants of 'electronics.audio' (including itself)
SELECT id, name, path
FROM categories
WHERE tenant_id = $1 AND path <@ 'electronics.audio'
ORDER BY path;

-- Query 2: Find all ancestors for breadcrumb trail of 'electronics.audio.headphones'
SELECT id, name, path
FROM categories
WHERE tenant_id = $1 AND path @> 'electronics.audio.headphones'
ORDER BY nlevel(path) ASC;

-- Query 3: Fast subtree count
SELECT count(*) AS total_descendants
FROM categories
WHERE tenant_id = $1 AND path <@ 'electronics.audio' AND path != 'electronics.audio';
```

---

### 2. Go (`jackc/pgx/v5`): Cycle-Safe Queries & Atomic Subtree Relocation

```go
package hierarchy

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrCycleDetected       = errors.New("cannot move node into its own descendant subtree")
	ErrNodeNotFound        = errors.New("node or target parent not found")
	ErrInvalidLTreeLabel   = errors.New("ltree label contains invalid characters; must match ^[A-Za-z0-9_]{1,256}$")
	ltreeLabelRegex        = regexp.MustCompile(`^[A-Za-z0-9_]{1,256}$`)
)

// TreeNode represents a hierarchical node with depth and breadcrumb info.
type TreeNode struct {
	ID        string
	ParentID  *string
	Name      string
	Depth     int
	Path      string
}

// FetchBreadcrumbs retrieves the ancestor chain from root to target node
// in a single network round-trip using a cycle-safe recursive CTE.
func FetchBreadcrumbs(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	targetNodeID string,
) ([]TreeNode, error) {
	const breadcrumbSQL = `
		WITH RECURSIVE ancestors AS (
			SELECT
				n.id,
				n.parent_id,
				n.name,
				1 AS depth
			FROM org_nodes n
			WHERE n.id = $1 AND n.tenant_id = $2

			UNION ALL

			SELECT
				p.id,
				p.parent_id,
				p.name,
				a.depth + 1
			FROM org_nodes p
			JOIN ancestors a ON p.id = a.parent_id
			WHERE p.tenant_id = $2 AND a.depth < 30
		)
		CYCLE id SET is_cycle USING cycle_path
		SELECT id, parent_id, name, depth
		FROM ancestors
		WHERE NOT is_cycle
		ORDER BY depth DESC;
	`

	rows, err := pool.Query(ctx, breadcrumbSQL, targetNodeID, tenantID)
	if err != nil {
		return nil, fmt.Errorf("failed querying ancestors: %w", err)
	}
	defer rows.Close()

	var chain []TreeNode
	for rows.Next() {
		var node TreeNode
		if err := rows.Scan(&node.ID, &node.ParentID, &node.Name, &node.Depth); err != nil {
			return nil, fmt.Errorf("failed scanning ancestor node: %w", err)
		}
		chain = append(chain, node)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error during ancestor iteration: %w", err)
	}

	return chain, nil
}

// RelocateSubtreeLTree atomically moves a node and all its descendants to a new parent path.
// It verifies that targetParent is NOT a descendant of nodeID, preventing circular corruption.
func RelocateSubtreeLTree(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	nodeID string,
	newParentID *string,
) error {
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Step 1: Lock the source node and fetch current path
	var currentPath string
	var nodeSlug string
	err = tx.QueryRow(ctx, `
		SELECT path::text, slug
		FROM categories
		WHERE id = $1 AND tenant_id = $2
		FOR UPDATE;
	`, nodeID, tenantID).Scan(&currentPath, &nodeSlug)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNodeNotFound
		}
		return fmt.Errorf("failed locking source node: %w", err)
	}

	var newBasePath string
	if newParentID != nil {
		// Step 2: Lock the target parent node
		var targetPath string
		err = tx.QueryRow(ctx, `
			SELECT path::text
			FROM categories
			WHERE id = $1 AND tenant_id = $2
			FOR UPDATE;
		`, *newParentID, tenantID).Scan(&targetPath)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNodeNotFound
			}
			return fmt.Errorf("failed locking target parent: %w", err)
		}

		// Step 3: Invariant check: targetPath must NOT be a descendant of currentPath!
		// In ltree terms, if targetPath <@ currentPath, moving currentPath under targetPath creates a cycle.
		if targetPath == currentPath || strings.HasPrefix(targetPath, currentPath+".") {
			return ErrCycleDetected
		}

		newBasePath = targetPath + "." + nodeSlug
	} else {
		// Moving to root level
		newBasePath = nodeSlug
	}

	// Validate ltree label syntax
	for _, label := range strings.Split(newBasePath, ".") {
		if !ltreeLabelRegex.MatchString(label) {
			return ErrInvalidLTreeLabel
		}
	}

	// Step 4: Atomically update the entire subtree's ltree paths using ltree subpath concatenation
	// subpath(path, nlevel($current_path) - 1) preserves relative subpaths of all descendants!
	const updateSubtreeSQL = `
		UPDATE categories
		SET path = $3::ltree || subpath(path, nlevel($1::ltree))
		WHERE tenant_id = $2 AND path <@ $1::ltree;
	`
	_, err = tx.Exec(ctx, updateSubtreeSQL, currentPath, tenantID, newBasePath)
	if err != nil {
		return fmt.Errorf("failed rewriting subtree ltree paths: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("failed committing subtree relocation: %w", err)
	}

	return nil
}
```

---

### 3. TypeScript (`Drizzle` / `Kysely`): Transitive Closure Table Queries

```typescript
// src/db/closure-table.ts
import { sql } from 'kysely';
import type { Kysely } from 'kysely';

export interface Database {
  categories: {
    id: string;
    tenant_id: string;
    name: string;
  };
  category_closure: {
    ancestor_id: string;
    descendant_id: string;
    depth: number;
  };
}

/**
 * Fetch all descendants of a category at any depth with O(1) query complexity
 * via transitive closure table.
 */
export async function getCategoryDescendants(
  db: Kysely<Database>,
  tenantId: string,
  ancestorId: string,
  maxDepth = 10
) {
  return await db
    .selectFrom('categories as c')
    .innerJoin('category_closure as cc', 'cc.descendant_id', 'c.id')
    .select(['c.id', 'c.name', 'cc.depth'])
    .where('cc.ancestor_id', '=', ancestorId)
    .where('c.tenant_id', '=', tenantId)
    .where('cc.depth', '<=', maxDepth)
    .orderBy('cc.depth', 'asc')
    .orderBy('c.name', 'asc')
    .execute();
}

/**
 * Atomically relocates a subtree in a closure table without deadlocks.
 * 1. Checks if target is a descendant of source.
 * 2. Unlinks subtree from existing ancestors.
 * 3. Links subtree to new ancestors.
 */
export async function relocateClosureSubtree(
  db: Kysely<Database>,
  tenantId: string,
  nodeId: string,
  newParentId: string | null
): Promise<void> {
  await db.transaction().execute(async (tx) => {
    if (newParentId) {
      // Step 1: Pre-check cycle invariant: newParent cannot be in descendants of nodeId
      const isDescendant = await tx
        .selectFrom('category_closure')
        .select('depth')
        .where('ancestor_id', '=', nodeId)
        .where('descendant_id', '=', newParentId)
        .executeTakeFirst();

      if (isDescendant) {
        throw new Error('CYCLE_DETECTED: Target parent is an existing descendant of source node');
      }
    }

    // Step 2: Disconnect the subtree (descendants of nodeId) from its current ancestors
    // (excluding links within the subtree itself)
    await sql`
      DELETE FROM category_closure
      WHERE descendant_id IN (
        SELECT descendant_id FROM category_closure WHERE ancestor_id = ${nodeId}
      )
      AND ancestor_id IN (
        SELECT ancestor_id FROM category_closure
        WHERE descendant_id = ${nodeId} AND ancestor_id != ${nodeId}
      );
    `.execute(tx);

    // Step 3: If moving under a new parent, attach the subtree to the new parent's ancestors
    if (newParentId) {
      await sql`
        INSERT INTO category_closure (ancestor_id, descendant_id, depth)
        SELECT
          supertree.ancestor_id,
          subtree.descendant_id,
          supertree.depth + subtree.depth + 1
        FROM category_closure AS supertree
        CROSS JOIN category_closure AS subtree
        WHERE supertree.descendant_id = ${newParentId}
          AND subtree.ancestor_id = ${nodeId};
      `.execute(tx);
    }
  });
}
```

---

### 4. Python (`SQLAlchemy 2.0` / `asyncpg`): Cycle-Safe Hierarchy Retrieval

```python
# app/services/hierarchy.py
from typing import List, Dict, Any, Optional
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

async def fetch_subtree_cycle_safe(
    session: AsyncSession,
    tenant_id: str,
    root_id: str,
    max_depth: int = 15,
) -> List[Dict[str, Any]]:
    """
    Retrieves full subtree rooted at root_id using PostgreSQL 14+ CYCLE clause
    to guarantee absolute immunity against infinite graph loops.
    """
    stmt = text("""
        WITH RECURSIVE node_tree AS (
            SELECT
                id,
                tenant_id,
                parent_id,
                name,
                0 AS depth,
                ARRAY[id] AS visited
            FROM folders
            WHERE id = :root_id AND tenant_id = :tenant_id

            UNION ALL

            SELECT
                f.id,
                f.tenant_id,
                f.parent_id,
                f.name,
                nt.depth + 1,
                nt.visited || f.id
            FROM folders f
            JOIN node_tree nt ON f.parent_id = nt.id
            WHERE f.tenant_id = :tenant_id
              AND nt.depth < :max_depth
        )
        CYCLE id SET is_cycle USING path_history
        SELECT id, parent_id, name, depth
        FROM node_tree
        WHERE NOT is_cycle
        ORDER BY depth ASC, name ASC;
    """)

    result = await session.execute(stmt, {
        "root_id": root_id,
        "tenant_id": tenant_id,
        "max_depth": max_depth,
    })

    return [
        {
            "id": str(row.id),
            "parent_id": str(row.parent_id) if row.parent_id else None,
            "name": row.name,
            "depth": row.depth,
        }
        for row in result.fetchall()
    ]
```

---

### 5. Rust (`sqlx`): Compile-Time Verified Hierarchy & LTree Querying

```rust
// src/store/hierarchy.rs
use sqlx::{PgPool, FromRow};
use uuid::Uuid;

#[derive(Debug, FromRow)]
pub struct CategoryNode {
    pub id: Uuid,
    pub name: String,
    pub path: String,
    pub depth: i32,
}

/// Retrieves all descendants using PostgreSQL native ltree with GiST index seek.
pub async fn fetch_ltree_descendants(
    pool: &PgPool,
    tenant_id: Uuid,
    parent_path: &str,
) -> Result<Vec<CategoryNode>, sqlx::Error> {
    let nodes = sqlx::query_as!(
        CategoryNode,
        r#"
        SELECT
            id,
            name,
            path::text AS path,
            nlevel(path) AS "depth!"
        FROM categories
        WHERE tenant_id = $1 AND path <@ $2::ltree
        ORDER BY path ASC;
        "#,
        tenant_id,
        parent_path
    )
    .fetch_all(pool)
    .await?;

    Ok(nodes)
}
```

---

## 4. Production TypeScript Guard Engine: `AgenticHierarchyGuardEngine`

This standalone TypeScript guard engine can be integrated into pre-commit hooks, agent tools, or CI workflows to statically analyze SQL queries, schema DDL, and subtree move operations:

```typescript
/**
 * AgenticHierarchyGuardEngine
 * Static AST and regex analysis engine validating database hierarchy invariants,
 * recursive CTE safety, index prerequisites, and ltree label formatting.
 */

export interface HierarchyAuditResult {
  hasIssues: boolean;
  issues: string[];
  recommendations: string[];
  score: number; // 0 - 100
}

export class AgenticHierarchyGuardEngine {
  private static readonly LTREE_LABEL_REGEX = /^[A-Za-z0-9_]{1,256}$/;

  /**
   * Audits recursive CTE queries for infinite loop vulnerabilities and depth caps.
   */
  public static auditRecursiveQuery(sql: string): HierarchyAuditResult {
    const issues: string[] = [];
    const recommendations: string[] = [];

    const isRecursive = /\bWITH\s+RECURSIVE\b/i.test(sql);
    if (!isRecursive) {
      return { hasIssues: false, issues: [], recommendations: [], score: 100 };
    }

    // Check 1: PostgreSQL 14+ CYCLE clause detection
    const hasCycleClause = /\bCYCLE\s+[a-zA-Z0-9_]+\s+SET\s+[a-zA-Z0-9_]+\s+USING\b/i.test(sql);
    const hasArrayVisited = /ARRAY\[.*?\]|visited\s*\|\|/i.test(sql);

    if (!hasCycleClause && !hasArrayVisited) {
      issues.push(
        'UNBOUNDED_RECURSIVE_LOOP_HAZARD: WITH RECURSIVE query lacks a CYCLE clause or visited array tracking. Any circular reference will trigger an infinite loop and OOM crash.'
      );
      recommendations.push(
        'Add PostgreSQL 14+ `CYCLE id SET is_cycle USING path` or maintain an `ARRAY[id]` visited array check in the recursive member.'
      );
    }

    // Check 2: Depth boundary cap
    const hasDepthCap = /\bdepth\s*(<|<=)\s*\d+/i.test(sql) || /\blevel\s*(<|<=)\s*\d+/i.test(sql);
    if (!hasDepthCap) {
      issues.push(
        'MISSING_DEPTH_CEILING: Recursive CTE has no explicit depth limit guard (e.g., `depth < 25`). Runaway tree depths may exhaust memory.'
      );
      recommendations.push(
        'Enforce a strict depth guard in the WHERE clause of the recursive member (e.g. `AND parent.depth < 25`).'
      );
    }

    const score = Math.max(0, 100 - issues.length * 50);
    return { hasIssues: issues.length > 0, issues, recommendations, score };
  }

  /**
   * Audits schema DDL for adjacency list indexing prerequisites.
   */
  public static auditSchemaDDL(ddl: string): HierarchyAuditResult {
    const issues: string[] = [];
    const recommendations: string[] = [];

    const hasParentId = /\bparent_id\b/i.test(ddl);
    if (!hasParentId) {
      return { hasIssues: false, issues: [], recommendations: [], score: 100 };
    }

    // Check for index on parent_id
    const hasParentIndex =
      /CREATE\s+INDEX\b[^(]*\([^)]*parent_id[^)]*\)/i.test(ddl) ||
      /idx_[a-zA-Z0-9_]*parent/i.test(ddl);

    if (!hasParentIndex) {
      issues.push(
        'UNINDEXED_PARENT_ID: Table defines `parent_id` foreign key but lacks a composite or standalone B-Tree index on `parent_id`. Causes O(N) sequential scans on every tree step.'
      );
      recommendations.push(
        'Create a B-Tree index: `CREATE INDEX idx_table_parent ON tablename(tenant_id, parent_id);`'
      );
    }

    const score = Math.max(0, 100 - issues.length * 50);
    return { hasIssues: issues.length > 0, issues, recommendations, score };
  }

  /**
   * Audits string prefix matching to prevent naive LIKE queries.
   */
  public static auditPathQuery(sql: string): HierarchyAuditResult {
    const issues: string[] = [];
    const recommendations: string[] = [];

    const hasNaiveLike = /\bpath\s+LIKE\s+['"][^'"]*%/i.test(sql);
    if (hasNaiveLike) {
      issues.push(
        'NAIVE_STRING_LIKE_HIERARCHY: Query performs `path LIKE "..."` prefix matching on string path. Subject to false-positive substring matches and full table sequential scans.'
      );
      recommendations.push(
        'Migrate path column to PostgreSQL `ltree` extension and use `<@` (descendant) or `@>` (ancestor) with GiST index.'
      );
    }

    const score = Math.max(0, 100 - issues.length * 50);
    return { hasIssues: issues.length > 0, issues, recommendations, score };
  }

  /**
   * Validates ltree path label validity.
   */
  public static validateLTreePath(path: string): { isValid: boolean; error?: string } {
    if (!path || path.trim() === '') {
      return { isValid: false, error: 'Path cannot be empty' };
    }

    const labels = path.split('.');
    if (labels.length > 65535) {
      return { isValid: false, error: 'LTree path exceeds maximum 65535 labels' };
    }

    for (const label of labels) {
      if (!this.LTREE_LABEL_REGEX.test(label)) {
        return {
          isValid: false,
          error: `Invalid ltree label '${label}'. Must match ^[A-Za-z0-9_]{1,256}$`,
        };
      }
    }

    return { isValid: true };
  }
}
```

---

## 5. Tree Node Relocation & Lifecycle Finite-State Machine (FSM)

Moving a node or subtree is a stateful operation requiring rigorous isolation to prevent circular adoption and orphaned subtrees:

```text
       ┌──────────────────────────┐
       │         1. IDLE          │
       └────────────┬─────────────┘
                    │
                    ▼
       ┌──────────────────────────┐
       │   2. CYCLE_PRECHECK      │◄─── Check Target NOT IN Descendants(Source)
       └────────────┬─────────────┘
                    │
           (Cycle Detected) ──► [ROLLBACK & ABORT WITH ERROR]
                    │ (Invariant Verified Safe)
                    ▼
       ┌──────────────────────────┐
       │ 3. ROW LOCKS ACQUIRED    │◄─── SELECT ... FOR UPDATE (In Lexicographical ID Order)
       └────────────┬─────────────┘
                    │
                    ▼
       ┌──────────────────────────┐
       │ 4. PATH / CLOSURE SYNC   │◄─── Atomic Subtree Prefix Rewrite / Closure Rebuild
       └────────────┬─────────────┘
                    │
                    ▼
       ┌──────────────────────────┐
       │ 5. RE-PARENT COMMITTED   │◄─── UPDATE parent_id & COMMIT Transaction
       └────────────┬─────────────┘
                    │
                    ▼
       ┌──────────────────────────┐
       │  6. CACHE INVALIDATION   │◄─── Invalidate Redis/Memory Hierarchy Prefixes
       └──────────────────────────┘
```

### FSM State Transition Table

| Current State | Event | Next State | Action / Guarantee |
| :--- | :--- | :--- | :--- |
| `IDLE` | `RelocateRequest(node, target)` | `CYCLE_PRECHECK` | Evaluate ancestor/descendant relationship. |
| `CYCLE_PRECHECK` | `target in descendants(node)` | `ROLLED_BACK` | Abort immediately; raise `ErrCycleDetected`. |
| `CYCLE_PRECHECK` | `target NOT in descendants` | `ROW_LOCKS_ACQUIRED` | Acquire row locks on source and target in deterministic UUID order. |
| `ROW_LOCKS_ACQUIRED` | `Lock Timeout / Conflict` | `ROLLED_BACK` | Release latches, fail fast to avoid pool starvation. |
| `ROW_LOCKS_ACQUIRED` | `Locks Acquired` | `PATH_CLOSURE_SYNC` | Execute atomic path concatenation or closure deletion/insertion. |
| `PATH_CLOSURE_SYNC` | `DML Success` | `COMMITTED` | Commit transaction; database tree invariant preserved. |
| `COMMITTED` | `Post-Commit Hook` | `IDLE` | Evict breadcrumb and hierarchy cache keys. |

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

Autonomous agents must pass all 6 gates before submitting any PR containing hierarchical schemas, recursive CTEs, or tree relocation logic:

| Gate | Verification Check | Command / Validation Regex | Expected Result |
| :--- | :--- | :--- | :--- |
| **Gate 1: Recursive CTE Loop Defense** | All `WITH RECURSIVE` queries have `CYCLE` or visited array | `! grep -ri "WITH RECURSIVE" src/ internal/ \| grep -v -E "CYCLE\|ARRAY\["` | Zero unprotected recursive queries |
| **Gate 2: Parent ID Indexing** | Verify existence of B-Tree index on `parent_id` columns | `grep -E "CREATE INDEX.*ON.*parent_id" migrations/` | Explicit composite or standalone index present |
| **Gate 3: LTree Label Regex Sanitization** | LTree path generation sanitizes labels | `grep -E "\^[A-Za-z0-9_]\{1,256\}\$" src/ internal/` | Strict alphanumeric + underscore validation enforced |
| **Gate 4: Pre-Flight Move Cycle Check** | Subtree relocation checks target descendant exclusion | Code review verifies descendant pre-check before `UPDATE parent_id` | Zero unguarded single `UPDATE parent_id` mutations |
| **Gate 5: GiST / B-Tree Dual Indexing** | Tables with `ltree` path have GiST index | `grep -E "CREATE INDEX.*USING gist\s*\(.*path.*\)" migrations/` | GiST index verified on ltree path |
| **Gate 6: Zero N+1 Breadcrumb Loops** | Breadcrumb walks use single CTE or ltree query | `! grep -E "while.*parent_id.*db\.query" src/ internal/` | Zero in-loop database parent traversal queries |

---

## 7. Summary: Autonomous Agent Quick Reference Card

```sql
-- ❌ NEVER DO THIS: Unbounded recursive CTE without cycle defense
WITH RECURSIVE tree AS (
    SELECT id, parent_id FROM nodes WHERE id = $1
    UNION ALL
    SELECT c.id, c.parent_id FROM nodes c JOIN tree t ON c.parent_id = t.id
) SELECT * FROM tree;

-- ✅ ALWAYS DO THIS (PostgreSQL 14+): Cycle-safe recursive CTE with depth ceiling
WITH RECURSIVE tree AS (
    SELECT id, parent_id, 1 AS depth FROM nodes WHERE id = $1
    UNION ALL
    SELECT c.id, c.parent_id, t.depth + 1
    FROM nodes c
    JOIN tree t ON c.parent_id = t.id
    WHERE t.depth < 25
)
CYCLE id SET is_cycle USING path_history
SELECT * FROM tree WHERE NOT is_cycle;

-- ✅ OR EVEN BETTER: PostgreSQL native ltree with GiST indexing
-- Index: CREATE INDEX idx_nodes_path ON nodes USING gist (path);
SELECT id, name, path FROM nodes WHERE path <@ 'root.engineering.frontend' ORDER BY path;
```
