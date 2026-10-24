---
description: Cloudflare Workers, Edge Computing (WinterCG, Vercel Edge, Deno, Bun), Durable Objects, D1, Hyperdrive, and serverless runtime invariants
globs: **/*{worker,edge,cf,wrangler}*,**/workers/**,**/edge/**,**/wrangler.toml,**/wrangler.jsonc,**/functions/**
alwaysApply: false
---

# Edge Computing, Cloudflare Workers & Serverless Runtime Invariants

> Add these rules to your project if developing on Cloudflare Workers, Vercel Edge Functions, WinterCG runtimes, Deno Deploy, Cloudflare Pages Functions, or building stateful edge architectures with Durable Objects, D1, R2, KV, and Hyperdrive.

## 1. Isolate Execution Model & Concurrency Boundaries
- **Ephemeral V8 Isolates vs Node.js Long-Running Processes**:
  - Edge runtimes execute inside lightweight V8 isolates with fast startup times (<5ms), distinct from persistent Node.js servers or long-running containers.
  - Isolates can spin up, scale to thousands of concurrent instances, and be evicted at any moment without warning.
- **The Module-Scope Global State Trap**:
  - ❌ **NEVER store request-scoped data, authentication sessions, or transaction state in module-level global variables**:
    ```ts
    // ❌ AI Slop / Catastrophic State Leak across requests in the same isolate:
    let currentUser: User | null = null;
    let requestCount = 0;

    export default {
      async fetch(req: Request): Promise<Response> {
        currentUser = await authenticate(req); // Leaks to concurrent requests!
        requestCount++;
        return new Response(`User: ${currentUser.name}, count: ${requestCount}`);
      }
    };
    ```
  - Global variables persist across multiple requests handled by the *same* isolate instance, causing multi-tenant data contamination and security breaches.
  - Global scope is strictly reserved for immutable constants, pre-compiled regexes, or stateless singleton clients.
- **Mandatory `ctx.waitUntil()` for Asynchronous Lifecycles**:
  - ❌ **NEVER fire-and-forget an un-awaited Promise in an Edge handler**:
    ```ts
    // ❌ Broken: The runtime immediately freezes or terminates pending promises when Response is sent
    export default {
      async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
        logAnalytics(req); // Promise killed mid-execution!
        return new Response("OK");
      }
    };

    // ✅ Invariant: ctx.waitUntil preserves async work past response delivery
    export default {
      async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
        ctx.waitUntil(logAnalytics(req)); // Guaranteed execution to completion
        return new Response("OK");
      }
    };
    ```
  - Pass all post-response tasks (analytics flushes, webhook triggers, cache warming, audit logs) to `ctx.waitUntil(promise)`.

---

## 2. WinterCG Standards vs Node.js Native API Traps
- **Zero Native C++ Addons or Synchronous Blocking Syscalls**:
  - Edge isolates execute under the WinterCG (Web-interoperable Runtimes Community Group) standard.
  - ❌ **NEVER import or call native Node.js APIs that rely on OS threads or C++ bindings**:
    - Prohibited: `fs.readFileSync`, `child_process.exec`, `cluster`, `v8`, `node:sqlite3`.
  - Prefer standard Web APIs: `fetch`, `Request`, `Response`, `Headers`, `ReadableStream`, `TransformStream`, `crypto.subtle`, `URLPattern`, `CompressionStream`, `TextEncoder`, `TextDecoder`.
- **Node.js Compatibility Mode (`nodejs_compat`) Restraint**:
  - When utilizing `nodejs_compat` (e.g., in `wrangler.toml`), use polyfilled standard modules (`node:crypto`, `node:buffer`, `node:events`, `node:path`) strictly where required.
  - ❌ **NEVER bundle monolithic Node libraries** (e.g. standard Axios, full Lodash, heavy ORMs with C bindings) that bloat bundle size past the 1MB–3MB script limit and degrade cold start latency.

---

## 3. Database Connection Pooling & Serverless Drivers
- **The Direct TCP Connection Exhaustion Disaster**:
  - ❌ **NEVER establish direct raw TCP connection pools from short-lived edge isolates to traditional PostgreSQL/MySQL**:
    - Under a burst of 2,000 concurrent requests, 2,000 edge isolate instances will instantly spin up and open 2,000 separate TCP connections.
    - PostgreSQL default `max_connections` (typically 100) will exhaust in milliseconds, taking down the entire database cluster with `FATAL: remaining connection slots are reserved`.
- **Mandatory Connection Multiplexing & Serverless Drivers**:
  - Always route relational database queries through:
    1. **Cloudflare Hyperdrive**: Connects your Worker to your existing Postgres database using a pooled TCP connection maintained at the Cloudflare edge, with transparent query acceleration and connection reuse.
    2. **Serverless HTTP/WebSocket Drivers**: Use HTTP-based query drivers that do not maintain long-lived stateful TCP handshakes:
       - Neon serverless driver (`@neondatabase/serverless`)
       - Supabase via connection pooler (port 6543 / Supavisor in Transaction Mode)
       - PlanetScale Serverless driver (`@planetscale/database`)
       - Prisma Accelerate
- **Edge-Native Distributed SQLite (Cloudflare D1 & Turso/LibSQL)**:
  - For relational workloads at the edge, use Cloudflare D1 or Turso.
  - **Batching Invariant**: Always batch multi-statement queries to avoid per-statement roundtrip serialization overhead:
    ```ts
    // ✅ Invariant: Single network roundtrip batch execution
    const results = await env.DB.batch([
      env.DB.prepare("INSERT INTO orders (id, user_id) VALUES (?, ?)").bind(orderId, userId),
      env.DB.prepare("INSERT INTO audit_logs (action, target) VALUES (?, ?)").bind("order_created", orderId),
    ]);
    ```

---

## 4. Durable Objects, Actor Concurrency & WebSocket Hibernation
- **Single-Threaded Actor Model Guarantees**:
  - A Durable Object provides strongly consistent, globally unique, single-threaded in-memory execution and state for a specific coordination partition (e.g., a collaborative document, a multiplayer room, a distributed lock).
  - All requests addressed to the same Durable Object ID route to the exact same physical isolate globally.
- **Transactional Storage Invariants**:
  - Mutations across multiple storage keys within a Durable Object MUST be wrapped in `transaction()` to guarantee atomicity and automatic rollback upon errors:
    ```ts
    await this.ctx.storage.transaction(async (txn) => {
      const balance = (await txn.get<number>("balance")) ?? 0;
      if (balance < amount) {
        throw new Error("Insufficient funds");
      }
      await txn.put("balance", balance - amount);
      await txn.put("last_updated", Date.now());
    });
    ```
- **WebSocket Hibernation API (Zero-Cost Idle WebSockets)**:
  - ❌ **NEVER keep an active isolate in memory just to maintain idle WebSockets**:
    - Traditional WebSockets keep CPU memory pinned indefinitely, generating huge billable durations.
  - Implement the **WebSocket Hibernation API**:
    ```ts
    import { DurableObject } from "cloudflare:workers";

    export class ChatRoom extends DurableObject {
      async fetch(request: Request): Promise<Response> {
        const pair = new WebSocketPair();
        const [client, server] = Object.values(pair);

        // ✅ Invariant: Register with hibernation system
        this.ctx.acceptWebSocket(server, ["chat"]);

        return new Response(null, { status: 101, webSocket: client });
      }

      // Automatically invoked when frames arrive; isolate hibernates between messages
      async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
        this.ctx.getWebSockets("chat").forEach((client) => {
          if (client !== ws) client.send(message);
        });
      }

      async webSocketClose(ws: WebSocket, code: number, reason: string) {
        ws.close(code, reason);
      }
    }
    ```

---

## 5. Storage Tier Selection: KV vs D1 vs R2 vs Vectorize
- **Workers KV: Eventually Consistent Read Cache**:
  - Workers KV offers ultra-low latency reads globally, but writes are **eventually consistent** (replication delay up to 60 seconds across all 300+ edge locations).
  - ❌ **NEVER use Workers KV for transactional balances, seat inventory, or concurrent counters**.
  - Use KV strictly for: Configuration flags, localized translation strings, user permission sets (with TTL-based invalidation), and static asset redirects.
- **Cloudflare R2: S3-Compatible Object Storage with Zero Egress**:
  - Stream uploads and downloads directly using `ReadableStream`.
  - ❌ **NEVER buffer 100MB files into an array buffer or memory variable before writing to R2**:
    ```ts
    // ✅ Invariant: Pure streaming transfer without memory buffering
    await env.MY_BUCKET.put("uploads/large-file.bin", request.body);
    ```
- **Cloudflare Vectorize**:
  - For AI embeddings and vector search at the edge, query Vectorize directly alongside Workers AI without leaving the Cloudflare network fabric.

---

## 6. Streaming Architecture, Memory Protection & Subrequest Budgets
- **128MB Memory Ceiling Defense**:
  - Cloudflare Workers and Edge isolates default to a strict 128MB memory ceiling.
  - Always stream data transformations using `TransformStream` or `ReadableStream` instead of loading entire datasets into memory:
    ```ts
    // ✅ Invariant: Streaming response transformation
    const { readable, writable } = new TransformStream({
      transform(chunk, controller) {
        // Process chunks on the fly without accumulating whole payload in RAM
        controller.enqueue(chunk);
      }
    });
    ```
- **The 50-Subrequest Platform Ceiling**:
  - Cloudflare Workers enforces a limit on outbound `fetch()` calls per incoming request (default 50 subrequests).
  - ❌ **NEVER run unbounded loops executing sequential `fetch()` calls**.
  - Mitigate with:
    1. Response caching using the Cache API (`caches.default.match` / `caches.default.put`).
    2. Batching outbound API queries.
    3. Bulk cache purging using Cache-Tags rather than per-URL purges.
- **Smart Placement & Cross-Continental Latency Elimination**:
  - Executing serverless compute at the edge nearest the user is counterproductive if the compute must run 5 sequential database queries to an origin database located in `us-east-1` (5 hops $\times$ 120ms = 600ms latency tax).
  - Use **Smart Placement** in `wrangler.toml`:
    ```toml
    [placement]
    mode = "smart"
    ```
  - This automatically routes compute execution to the edge data center physically closest to your database, while keeping frontend assets and static edge caching distributed.

---

## 7. Secrets, Environment Variables & Configuration Hygiene
- ❌ **NEVER commit plaintext secrets or credentials to `wrangler.toml` or `wrangler.jsonc`**.
- Store local development secrets in `.dev.vars` (MANDATORY entry in `.gitignore`).
- Inject production secrets using the encrypted Wrangler CLI:
  ```bash
  npx wrangler secret put DATABASE_URL
  npx wrangler secret put STRIPE_API_KEY
  ```
- **Strictly Typed Environment Interface (`Env`)**:
  - Declare a single source of truth for all runtime bindings:
    ```ts
    export interface Env {
      // Bindings
      DB: D1Database;
      KV: KVNamespace;
      BUCKET: R2Bucket;
      ROOMS: DurableObjectNamespace;
      HYPERDRIVE: Hyperdrive;

      // Environment Variables & Secrets
      ENVIRONMENT: "development" | "staging" | "production";
      API_SECRET_KEY: string;
    }
    ```
