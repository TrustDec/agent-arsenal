---
description: Multi-tenant SaaS architecture, data isolation models, PostgreSQL Row-Level Security (RLS), PgBouncer transaction-safe tenant context, fair queuing, BOLA/IDOR prevention, and tenant data shredding invariants
globs: **/*{tenant,multitenant,multi_tenant,organization,org,workspace,saas,rls,isolation}*.*,**/tenants/**,**/organizations/**,**/workspaces/**,**/saas/**
alwaysApply: false
---

# Multi-Tenant SaaS Architecture, Data Isolation & RLS Invariants

> Add these rules to your project when architecting, implementing, or auditing multi-tenant SaaS applications, organization/workspace data isolation boundaries, PostgreSQL Row-Level Security (RLS), tenant context middleware, fair job scheduling, or tenant data shredding pipelines (PostgreSQL, PgBouncer, Go, Node.js/TypeScript, Redis, Asynq/Temporal).

---

## 1. Multi-Tenancy Isolation Models & Architectural Trade-offs
Selecting the incorrect tenancy model produces either catastrophic operational overhead (migrating 10,000 individual databases) or fatal cross-tenant security breaches (data leaking across organizations).

| Isolation Model | Data Separation | Operational Cost | Blast Radius | Schema Migration Complexity | Target Tier |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Pooled (Shared DB, Shared Schema)** | Row-level (`tenant_id` column + RLS) | Lowest (Single DB pool) | High (Single query bug risks data leak) | Low (Single migration run) | Free / Pro / Self-Serve |
| **Bridge (Shared DB, Schema-per-Tenant)** | PostgreSQL Schema (`search_path`) | Moderate (Catalog bloat >5,000 schemas) | Medium (Logical separation) | High (Iterate schemas in parallel) | Mid-Market / Compliance |
| **Silo (Database-per-Tenant)** | Separate DB instance or cluster | Highest (Resource waste at scale) | Isolated (Zero blast radius) | Highest (Fleet orchestrator required) | Enterprise / Gov / HIPAA |

- ✅ **The Hybrid Bridge-Silo Production Architecture**:
  - Place standard self-serve and pro tenants in a **Pooled** database using mandatory PostgreSQL Row-Level Security (RLS).
  - Dynamically route high-tier enterprise tenants with strict HIPAA/SOC2 air-gap requirements to dedicated **Silo** database connection pools resolved via tenant domain/license lookup.

---

## 2. PostgreSQL Row-Level Security (RLS) & The `FORCE` Trap
Naive RLS implementation gives developers a false sense of security. By default in PostgreSQL, **table owners and superusers completely bypass RLS policies**, leading to catastrophic data leaks when application services connect using administrative database roles.

- ❌ **THE TABLE OWNER RLS BYPASS VULNERABILITY**:
  ```sql
  -- DANGEROUS: If the app connects as the table owner, RLS is SILENTLY BYPASSED!
  ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation_policy ON documents
      USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid);
  ```
- ✅ **The `FORCE ROW LEVEL SECURITY` Production Invariant**:
  - Always enforce `FORCE ROW LEVEL SECURITY`. This ensures that even the table owner role cannot bypass the isolation filter:
  ```sql
  ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
  ALTER TABLE documents FORCE ROW LEVEL SECURITY;

  -- Create permissive policy for authenticated tenant sessions:
  CREATE POLICY documents_tenant_isolation ON documents
      FOR ALL
      TO app_user
      USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid)
      WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid);
  ```
- ✅ **The Second Argument in `current_setting`**:
  - Always pass `true` as the second argument: `current_setting('app.current_tenant_id', true)`. If set to `false` or omitted, PostgreSQL throws a fatal runtime exception (`unrecognized configuration parameter`) whenever a query executes outside an active tenant session (e.g., during healthchecks or background workers).

---

## 3. The PgBouncer Transaction Pooling Trap & Safe Session Scope
In modern scalable architectures, application servers connect to PostgreSQL via connection poolers (PgBouncer, AWS RDS Proxy) operating in **Transaction Pooling Mode** (where each physical connection is returned to the pool as soon as a `COMMIT` or `ROLLBACK` executes).

- ❌ **THE SESSION STATE CROSS-TENANT LEAK**:
  - Running `SET app.current_tenant_id = 'tenant_123'` without `LOCAL` applies the setting to the **underlying TCP session**.
  - When the connection is returned to PgBouncer, the next query executed by a completely different tenant (e.g. `tenant_456`) on that pooled connection will inherit `tenant_123`, **exposing private customer data across tenants**.
- ✅ **The `SET LOCAL` Invariant**:
  - In transaction pooling mode, ALWAYS use `SET LOCAL` within an explicit transaction block (`BEGIN ... COMMIT`). `SET LOCAL` automatically clears the parameter when the transaction terminates:
  ```sql
  BEGIN;
  -- Scoped strictly to this transaction; reset upon COMMIT/ROLLBACK:
  SET LOCAL app.current_tenant_id = 'c0a80101-0000-0000-0000-000000000001';

  SELECT id, title, content FROM documents WHERE status = 'published';
  COMMIT;
  ```
- ✅ **Go Production Helper with Transactional Context**:
  ```go
  package tenant

  import (
      "context"
      "database/sql"
      "fmt"
      "github.com/google/uuid"
  )

  type ctxKey struct{}

  func WithTenantID(ctx context.Context, tenantID uuid.UUID) context.Context {
      return context.WithValue(ctx, ctxKey{}, tenantID)
  }

  func FromContext(ctx context.Context) (uuid.UUID, error) {
      val, ok := ctx.Value(ctxKey{}).(uuid.UUID)
      if !ok || val == uuid.Nil {
          return uuid.Nil, fmt.Errorf("tenant context missing or invalid")
      }
      return val, nil
  }

  // ExecInTenantTx wraps DB operations with atomic, PgBouncer-safe SET LOCAL isolation
  func ExecInTenantTx(ctx context.Context, db *sql.DB, fn func(tx *sql.Tx) error) error {
      tenantID, err := FromContext(ctx)
      if err != nil {
          return err
      }

      tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
      if err != nil {
          return fmt.Errorf("failed to begin tx: %w", err)
      }
      defer tx.Rollback()

      // Set transaction-local setting; zero chance of connection pool pollution:
      setQuery := fmt.Sprintf("SET LOCAL app.current_tenant_id = '%s'", tenantID.String())
      if _, err := tx.ExecContext(ctx, setQuery); err != nil {
          return fmt.Errorf("failed to set tenant session context: %w", err)
      }

      if err := fn(tx); err != nil {
          return err
      }

      return tx.Commit()
  }
  ```

---

## 4. Broken Object Level Authorization (BOLA/IDOR) & Composite Keys
Relying solely on surrogate keys (`WHERE id = :id`) invites **Broken Object Level Authorization (BOLA / IDOR)** vulnerabilities. If an attacker replaces an ID in an API request, an application lacking tenant checks will update or return another organization's record.

- ❌ **THE SURROGATE KEY IDOR TRAP**:
  ```sql
  -- DANGEROUS: If user modifies document_id in URL, they access another tenant's doc!
  SELECT * FROM documents WHERE id = :document_id;
  UPDATE documents SET content = :content WHERE id = :document_id;
  ```
- ✅ **Composite Primary Keys & Dual Scoping**:
  - Define composite primary keys incorporating `tenant_id`:
  ```sql
  CREATE TABLE documents (
      tenant_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      id UUID NOT NULL DEFAULT gen_random_uuid(),
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
      PRIMARY KEY (tenant_id, id)
  );

  -- Index optimized for tenant-scoped lookups:
  CREATE INDEX idx_documents_tenant_created ON documents (tenant_id, created_at DESC);
  ```
- ✅ **Defense-in-Depth Query Invariant**:
  - Even when RLS is enabled, always explicitly include `WHERE tenant_id = :tenant_id AND id = :id` in application application-layer queries:
  ```go
  const query = `
      UPDATE documents
      SET title = $1, content = $2
      WHERE tenant_id = $3 AND id = $4
  `
  result, err := tx.ExecContext(ctx, query, title, content, tenantID, docID)
  ```

---

## 5. Subdomain & Cryptographic JWT Resolution Discipline
Tenants must never be resolved solely from untrusted user input (such as unvalidated JSON payloads or raw query parameters).

- ❌ **THE UNVALIDATED CLIENT TENANT INJECTION**:
  - Allowing the client to send `X-Tenant-ID: 123` without matching cryptographic proof allows privilege escalation.
- ✅ **The Subdomain / Custom Domain Resolution Pipeline**:
  - Resolve tenant identifiers via DNS subdomain (`acme.saas.com` $\to$ `acme`), custom domains, or **cryptographically verified JWT claims**:
  ```typescript
  // Node.js / Express / Fastify Tenant Context Middleware
  import { Request, Response, NextFunction } from 'express';
  import jwt from 'jsonwebtoken';

  export interface AuthenticatedTenantRequest extends Request {
    tenantId: string;
    userId: string;
  }

  export function tenantResolutionMiddleware(
    req: Request,
    res: Response,
    next: NextFunction
  ) {
    const authHeader = req.headers.authorization;
    if (!authHeader?.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'Missing bearer authorization header' });
    }

    try {
      const token = authHeader.substring(7);
      const payload = jwt.verify(token, process.env.JWT_PUBLIC_KEY!, {
        algorithms: ['RS256', 'EdDSA'],
      }) as { tid: string; sub: string };

      if (!payload.tid) {
        return res.status(403).json({ error: 'Token missing tenant claim (tid)' });
      }

      // If domain / subdomain is also provided, ensure strict alignment:
      const hostSubdomain = req.hostname.split('.')[0];
      if (req.headers['x-expected-subdomain'] && req.headers['x-expected-subdomain'] !== hostSubdomain) {
        return res.status(403).json({ error: 'Tenant domain mismatch' });
      }

      (req as AuthenticatedTenantRequest).tenantId = payload.tid;
      (req as AuthenticatedTenantRequest).userId = payload.sub;
      next();
    } catch (err) {
      return res.status(401).json({ error: 'Invalid or expired authorization token' });
    }
  }
  ```

---

## 6. Noisy Neighbor Defense: Fair Queuing & Tenant Starvation Prevention
In shared background worker environments (e.g., PDF generation, webhooks, AI embeddings), a single high-volume tenant enqueueing 100,000 tasks will monopolize worker pools, starving interactive tasks (e.g., password reset emails, invoice downloads) from other paying tenants.

- ❌ **THE SINGLE FIFO QUEUE DISASTER**:
  - Enqueueing all jobs into a single global Redis list (`LPUSH jobs ...`) allows one noisy tenant to cause site-wide denial of service.
- ✅ **Fair-Share Tenant Partitioned Queuing**:
  - Segregate queues by tenant or tenant priority tier (`queue:tenant:{tenant_id}`).
  - Use Round-Robin queue dispatching or weighted fair queuing with dynamic worker concurrency caps per tenant:
  ```go
  // Weighted Fair Scheduling Worker Dispatcher
  type JobDispatcher struct {
      client     *redis.Client
      maxPerTenant int
  }

  func (d *JobDispatcher) FetchNextJob(ctx context.Context, activeTenants []string) (*Job, error) {
      // Rotate tenants list to prevent tenant 0 starvation (Deficit Round-Robin):
      for _, tenantID := range activeTenants {
          // Check active processing counter:
          concurrencyKey := fmt.Sprintf("tenant:%s:active_workers", tenantID)
          count, err := d.client.Get(ctx, concurrencyKey).Int()
          if err != nil && err != redis.Nil {
              continue
          }

          if count >= d.maxPerTenant {
              // Tenant reached fair-share concurrency ceiling; skip to next tenant
              continue
          }

          queueKey := fmt.Sprintf("queue:tenant:%s", tenantID)
          jobData, err := d.client.RPop(ctx, queueKey).Bytes()
          if err == redis.Nil {
              continue // No jobs for this tenant
          } else if err != nil {
              return nil, err
          }

          // Increment active worker count with 60s safety TTL:
          d.client.Incr(ctx, concurrencyKey)
          d.client.Expire(ctx, concurrencyKey, 60*time.Second)

          var job Job
          json.Unmarshal(jobData, &job)
          return &job, nil
      }
      return nil, nil // No eligible work across all tenants
  }
  ```

---

## 7. Multi-Tenant In-Memory Caching & Collision Invariants
Caching entities without tenant namespaces allows accidental cross-tenant data leaks and invalidation hazards.

- ❌ **THE UNPREFIXED CACHE KEY COLLISION**:
  ```typescript
  // CATASTROPHIC: Tenant B requests user 101 and receives Tenant A's sensitive data!
  const cacheKey = `user:${userId}`;
  await redis.get(cacheKey);
  ```
- ✅ **Strict Hierarchical Cache Namespacing**:
  - Cache keys must always be prefixed with the `tenant_id`:
    $$\text{cache\_key} = \text{tenant}:\{\text{tenant\_id}\}:\{\text{resource}\}:\{\text{resource\_id}\}$$
    ```typescript
    export function buildTenantCacheKey(tenantId: string, resource: string, id: string): string {
      return `tenant:${tenantId}:${resource}:${id}`;
    }
    ```
- ✅ **Tenant-Level Ephemeral Invalidation via Version Tags**:
  - Instead of running expensive `KEYS tenant:123:*` scans (which blocks Redis single-threaded event loop), use a **tenant cache version counter**:
  ```typescript
  async function getTenantCacheVersion(redis: Redis, tenantId: string): Promise<number> {
    const v = await redis.get(`tenant:${tenantId}:cache_version`);
    return v ? parseInt(v, 10) : 1;
  }

  // To invalidate ALL cached entries for a tenant instantly:
  async function purgeTenantCache(redis: Redis, tenantId: string): Promise<void> {
    await redis.incr(`tenant:${tenantId}:cache_version`);
  }

  // Composed key: tenant:{tenantId}:v{version}:{resource}:{id}
  ```

---

## 8. Per-Tenant Dynamic Rate Limiting & Resource Quotas
Different tenant tiers (Free, Professional, Enterprise) require isolated rate limit counters to ensure free-tier abuse does not impact enterprise SLAs.

- ✅ **Sliding-Window Lua Script with Tenant Quota Tiers**:
  ```lua
  -- KEYS[1]: tenant_ratelimit:{tenant_id}
  -- ARGV[1]: current_timestamp (milliseconds)
  -- ARGV[2]: window_size_in_ms (e.g., 60000 for 1 minute)
  -- ARGV[3]: max_requests_limit (e.g., 60 or 5000)

  local key = KEYS[1]
  local now = tonumber(ARGV[1])
  local window = tonumber(ARGV[2])
  local limit = tonumber(ARGV[3])
  local clearBefore = now - window

  -- Remove timestamps older than current sliding window:
  redis.call('ZREMRANGEBYSCORE', key, 0, clearBefore)

  local currentCount = redis.call('ZCARD', key)
  if currentCount < limit then
      redis.call('ZADD', key, now, now)
      redis.call('PEXPIRE', key, window)
      return {1, limit - currentCount - 1} -- Allowed, remaining quota
  else
      return {0, 0} -- Rate limit exceeded
  end
  ```

---

## 9. Tenant Data Shredding & GDPR Right to be Forgotten
When an enterprise customer offboards, GDPR and SOC2 standards mandate **complete, verifiable data deletion** ("Right to be Forgotten"). Relying on simple `is_deleted = true` soft deletes leaves customer PII in production storage, vulnerable to audits, regulatory fines, and subsequent breaches.

- ❌ **THE INCOMPLETE CASCADE ORPHAN TRAP**:
  - Running `DELETE FROM organizations WHERE id = :id` on high-volume tables (>10M rows) locks child tables for minutes, causes transaction timeouts, and triggers replication lag.
- ✅ **Two-Phase Atomic Data Shredding Pipeline**:
  - **Phase 1 (Lockout & Tombstone)**: Immediately revoke all tenant API keys, terminate active JWT sessions, and mark tenant status as `pending_purge`.
  - **Phase 2 (Chunked Background Shredding)**: Use an asynchronous batch worker to delete child records in chunks of 5,000 using sequential primary key pagination to prevent lock escalation:
  ```sql
  -- Chunked deletion batch loop:
  DO $$
  DECLARE
      rows_deleted INT;
  BEGIN
      LOOP
          DELETE FROM audit_logs
          WHERE id IN (
              SELECT id FROM audit_logs
              WHERE tenant_id = 'c0a80101-0000-0000-0000-000000000001'
              LIMIT 5000
          );
          GET DIAGNOSTICS rows_deleted = ROW_COUNT;
          EXIT WHEN rows_deleted = 0;
          COMMIT; -- Release table locks between batches
          PERFORM pg_sleep(0.05); -- Yield I/O to avoid spiking replication lag
      END LOOP;
  END $$;
  ```

---

## 10. Multi-Tenant Audit Logging & Compliance Immutability
Enterprise tenants demand tamper-proof audit trails capturing all authorization events, data exports, and configuration updates.

- ✅ **The Multi-Tenant Audit Entry Invariant**:
  - Every tenant audit record must capture:
    1. `tenant_id` (UUID)
    2. `actor_id` (User UUID or API key hash)
    3. `actor_role` (e.g. `billing_admin`)
    4. `action` (e.g. `user.role_promoted`, `billing.plan_changed`)
    5. `resource_type` & `resource_id`
    6. `ip_address` & `user_agent`
    7. `prev_state` & `new_state` (JSONB)
    8. `prev_record_hash` (Cryptographic HMAC chaining to prevent table tampering)
  ```sql
  CREATE TABLE tenant_audit_logs (
      id UUID NOT NULL DEFAULT gen_random_uuid(),
      tenant_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      actor_id UUID NOT NULL,
      action VARCHAR(64) NOT NULL,
      resource_id VARCHAR(64) NOT NULL,
      ip_address INET NOT NULL,
      changes JSONB NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
      entry_hash BYTEA NOT NULL,
      PRIMARY KEY (tenant_id, id)
  ) PARTITION BY RANGE (created_at);
  ```
