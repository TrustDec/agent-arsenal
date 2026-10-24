# Agent Arsenal 🛡️🎨

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/TrustDec/agent-arsenal.svg?style=social)](https://github.com/TrustDec/agent-arsenal)
[![Compatible With](https://img.shields.io/badge/Compatible%20with-Claude%20Code%20%7C%20Cursor%20%7C%20Windsurf%20%7C%20Copilot%20%7C%20Cline%20%7C%20Pi-emerald.svg)]()

**Production-grade discipline and Apple/Vercel-level aesthetic taste for Coding Agents.**  
*Stop AI hallucinations, breaking diffs, and ugly purple-gradient UI slop in 1 second.*

[English](README.md) | [简体中文](README_zh.md)

</div>

---

## ⚡ The Visual Contrast (Before vs After)

| Default AI Generation (AI Slop) | With Agent Arsenal Injected |
| :--- | :--- |
| ❌ Neon purple/blue linear gradient cards | ✅ Deep Zinc/Slate neutral surfaces with 1px micro-borders |
| ❌ Cluttered `rounded-3xl` bubbly shapes | ✅ Refined 8pt grid, optical kerning & Geist/SF Pro typography |
| ❌ `Lorem Ipsum` and fake placeholder stats | ✅ Realistic domain data, accessible focus rings & tactile feedback |
| ❌ Uncontrolled 200-line diff for 2-line bug | ✅ Surgical 2-line diff; zero untouched code modifications |
| ❌ Uses `unwrap()` or `@ts-ignore` to silence errors | ✅ Root-cause fixes verified by machine compiler & test output |

---

## ✨ Specialized Language & Stack Invariants

Beyond core general rules, `agent-arsenal` includes plug-and-play rules for modern stacks and environments:

- 📊 **ClickHouse & Real-Time Columnar OLAP Analytics (`rules/clickhouse-olap.md`)**: Columnar storage execution model, MergeTree family engine selection (`ReplacingMergeTree`, `VersionedCollapsingMergeTree`, `AggregatingMergeTree`), total ban on single-row OLTP-style inserts, write batching invariants (10,000–100,000 rows or server-side `async_insert=1` buffers) to eliminate the fatal `Too many parts` crash, coarse-grained monthly partition key pruning (`toYYYYMM`) with <1,000 active partition ceiling, `ORDER BY` physical sorting and sparse primary index marks (low to high cardinality column ordering), `SELECT ... FINAL` performance degradation defense with vectorized `argMax` deduplication, ban on heavy asynchronous `ALTER TABLE ... UPDATE/DELETE` mutations in hot paths, automatic TTL purges, `LowCardinality(String)` 85% disk compression and integer filtering, avoidance of `Nullable(T)` overhead, streaming insert-time Materialized Views with `AggregatingMergeTree` (`-State` and `-Merge` combinators), query memory ceilings (`max_memory_usage` and external disk spill), `GLOBAL JOIN` broadcast against multi-node network fanout, and HyperLogLog approximation (`uniq` / `uniqCombined64`).
- 💻 **Shell Scripting, Bash Automation & POSIX CLI Discipline (`rules/shell-bash-cli.md`)**: Mandatory strict mode (`set -euo pipefail` and `IFS=$'\n\t'`), total ban on unquoted variables to prevent word splitting and glob expansion, the `local` declaration exit code masking trap (separate `local x` from assignment `x=$(cmd)`), self-resolving deterministic script location (`BASH_SOURCE[0]`), atomic temporary workspaces with `mktemp -d` and deterministic signal cleanup traps (`trap cleanup EXIT INT TERM`), atomic file updates (`mv -f temp dest`), safe stream processing with `while IFS= read -r line`, catastrophic recursive deletion defense (`rm -rf "${DIR:?}"/*` with empty variable protection), stdout (machine data) vs stderr (human diagnostics) stream separation, portable binary discovery (`command -v` over `which`), and non-interactive CLI flags for automation.
- ⚡ **Edge Computing, Cloudflare Workers & Serverless Runtimes (`rules/edge-serverless-workers.md`)**: Ephemeral V8 isolate execution model and strict ban on mutable module-scope global state (prevents multi-tenant isolate cross-request data leaks), mandatory `ctx.waitUntil(promise)` lifecycle preservation for post-response async operations, zero-native C++ WinterCG boundary enforcement, relational database connection exhaustion defense via Cloudflare Hyperdrive and serverless HTTP drivers, Durable Objects actor consistency with atomic multi-key `storage.transaction()`, zero-cost WebSocket Hibernation API (`ctx.acceptWebSocket()`), storage tier invariants (Workers KV eventual consistency vs D1 relational SQLite vs R2 zero-egress object storage), 128MB memory ceiling streaming defense (`ReadableStream` / `TransformStream`), 50-subrequest budget mitigation, Smart Placement cross-continental latency elimination, and encrypted Wrangler secrets.
- ⚙️ **Distributed Background Jobs, Task Queues & Durable Workflows (`rules/background-jobs-workflows.md`)**: Universal at-least-once delivery reality and mandatory handler idempotency keys, payload minimalism (pass lightweight IDs, never live database entities), exponential backoff with full jitter to eliminate retry storm thundering herds, Dead Letter Queue (DLQ) poison pill isolation, Temporal/Cadence/Inngest durable execution determinism (ban on `time.Now()`, `Math.random()`, direct network I/O, or raw goroutines inside workflows; delegate all non-deterministic logic to activities), worker graceful shutdown (`SIGTERM`) with in-flight drain and heartbeat timeouts, multi-tenant fair queuing against starvation, and incremental batch checkpointing.
- 🧠 **Agent Context Engineering, Memory Architecture & KV Cache Optimization (`rules/context-memory-engineering.md`)**: Strict Prompt Prefix KV Caching determinism for 10x latency speedups and 75-90% cost savings (ban on volatile timestamps/metrics before prompt prefix), 3-tier progressive disclosure hierarchy (AST/symbol discovery -> targeted line slices -> complete file reads only on structural refactors), persistent memory bank protocols (`ACTIVE_CONTEXT.md` / `SYSTEM_PATTERNS.md`), sub-agent isolation with 5-line synthesized handoff blocks to prevent orchestrator context rot, semantic delimiter containment (`<file_content>`, `<tool_output>`) against indirect prompt injection, and the 3-attempt circuit breaker against speculative thrashing.
- 🔐 **Authentication, OAuth 2.1 & Identity Security (`rules/auth-identity.md`)**: Absolute ban on `localStorage` / `sessionStorage` token storage (prevents XSS exfiltration), hardened `__Host-` / `HttpOnly` / `SameSite=Lax/Strict` cookie enforcement, JWT algorithm pinning (eliminates `alg: none` and RS256/HS256 public key confusion exploits), refresh token rotation (RTR) with automatic token family breach invalidation, mandatory OAuth 2.1 PKCE (`S256`), CSRF `state` and OIDC `nonce` validation, exact-match redirect URI whitelisting, Broken Object Level Authorization (BOLA/IDOR) tenant scoping guards, and WebAuthn/Passkeys monotonic signature counter verification.
- 🧪 **Testing Discipline & Anti-Flakiness Invariants (`rules/testing-discipline.md`)**: Absolute ban on arbitrary `sleep` timeouts, clock virtualization (`fakeTimers`) for temporal logic, hermetic test isolation with per-test transaction rollback, multi-worker test database partitioning, elimination of "testing the mock" antipatterns, strict table-driven boundary matrices, and zero unhandled floating promises in async tests.
- 🚀 **CI/CD Automation & GitHub Actions Security (`rules/cicd-github-actions.md`)**: Full 40-character SHA pinning for third-party actions to prevent supply-chain hijacking, absolute elimination of script injection via intermediate environment variable mapping, top-level `permissions: contents: read` least privilege enforcement, elimination of the dangerous `pull_request_target` fork checkout trap, and OIDC cloud federation over static long-lived credentials.
- 🌐 **Resilient API Design & Distributed Systems (`rules/api-distributed-systems.md`)**: Mandatory `Idempotency-Key` contracts with atomic reservation & SHA-256 payload checksum validation, retry storm immunity with full-jitter exponential backoff, circuit breaker state machines (Closed/Open/Half-Open), W3C `traceparent` OpenTelemetry distributed context propagation, elimination of the Dual-Write trap via the Transactional Outbox pattern, RFC 7807 Problem Details error formatting, and distributed sliding-window rate limiting.
- 🧠 **AI, LLM Apps & RAG Systems (`rules/ai-llm-rag.md`)**: Strict Structured Outputs / JSON Schema validation, semantic chunking boundaries, hybrid search (dense embeddings + lexical BM25 via Reciprocal Rank Fusion), cross-encoder reranking, anti-prompt injection delimiter containment, token window budgeting, full-jitter exponential backoff, and SSE streaming disconnect cleanup.
- 🛡️ **Application Security & OWASP Defense (`rules/security-appsec.md`)**: Anti-SSRF guards with DNS pre-flight & private IP bans, absolute command injection / shell interpolation elimination, parameterized SQL invariants, path traversal immunity with canonical base checks, constant-time cryptographic comparison (`timingSafeEqual`), CSPRNG token discipline, and ReDoS prevention.
- 🐳 **Docker & Container Production Invariants (`rules/docker-containers.md`)**: Multi-stage build isolation with minimal attack surfaces (`distroless`/`alpine`), absolute ban on running as root (`USER nonroot`), PID 1 signal forwarding (`tini`/exec form) for zero-downtime graceful shutdown, secret isolation via `--mount=type=secret`, same-layer package cache pruning, and deterministic healthchecks.
- ☸️ **Kubernetes & Cloud-Native Infrastructure (`rules/kubernetes-cloud-native.md`)**: Absolute ban on external dependency checks in `livenessProbe` (preventing cascading cluster death spirals), mandatory `preStop` sleep hooks to eliminate 502 errors during rolling deployments, `terminationGracePeriodSeconds` sizing, Pod Security Standards (PSS) restricted hardening (`runAsNonRoot: true`, `readOnlyRootFilesystem: true`, drop all capabilities), `immutable: true` ConfigMaps/Secrets, secret volume mounts over environment variables, and PodDisruptionBudgets (PDB).
- 🏗️ **Terraform & Infrastructure as Code (IaC) (`rules/terraform-iac.md`)**: Remote state locking with DynamoDB/S3 encryption, mandatory `lifecycle { prevent_destroy = true }` on production stateful resources, `create_before_destroy = true` for zero-downtime resource replacement, absolute ban on IAM wildcard `Action: "*"` and `Resource: "*"` statements, `0.0.0.0/0` ingress prohibition on non-web ports, mandatory S3 4-point public access blocks and SSE-KMS encryption, dynamic secret injection over plaintext `.tfvars`, and pessimistic provider version pinning (`~> 5.40`).
- 🔌 **Model Context Protocol (MCP) Server Engineering (`rules/mcp-server.md`)**: Absolute ban on stdio `stdout` pollution (`console.log` / `print` breaks JSON-RPC byte framing), mandatory descriptive Zod/Pydantic schemas for LLM tool selection, bounded token payload ceilings with pagination/projections, graceful error handling (`isError: true`), and path traversal / shell injection immunity.
- 🔷 **TypeScript & Runtime Discipline (`rules/typescript.md`)**: Total ban on `any` and unvalidated type assertions (`as T`), mandatory Zod/runtime validation at I/O boundaries, zero floating promises, non-null assertion (`!`) ban, discriminated unions, and safe Node/Bun stream & memory leak prevention.
- 🐹 **Golang Concurrency & Systems (`rules/golang.md`)**: Context lifecycle propagation, zero goroutine leaks with `errgroup`, sub-slice backing array memory retention traps (`bytes.Clone` / `slices.Clone`), Go 1.23+ range-over-func standard iterators (`iter.Seq` / `iter.Seq2`) and yield contract invariants, `http.Client` Transport response body draining requirement (`io.Copy(io.Discard, resp.Body)`) and `MaxIdleConnsPerHost` socket pool exhaustion defense, `go test -race` invariants, explicit error wrapping (`%w`), multi-error aggregation with `errors.Join` (Go 1.20+), asynchronous cancellation callbacks with `context.AfterFunc` (Go 1.21+), compiler escape analysis optimization (`go build -gcflags="-m"`), slice/map capacity pre-allocation to eliminate amortized `growslice` spikes, graceful OS signal shutdown, container cgroup GC pacing via `GOMEMLIMIT` & `GOGC`, 64-bit struct field memory alignment/padding optimization, `sync.OnceFunc` lazy initialization (Go 1.21+), mandatory worker goroutine `defer recover()` panic boundaries, typed `log/slog` attributes, untyped nil interface conversion defense, `singleflight.Group` thundering herd suppression, `ctx.Err()` loop cancellation checks, unexposed internal `pprof` profiling security, `sync.Pool` memory retention and capacity ceiling guards, channel direction typing and strict single-owner closure principle, mutex copy prevention, and lock-free `atomic.Pointer[T]` swaps.
- 🗄️ **SQL & Database Production Safety (`rules/database-sql.md`)**: Expand-and-contract zero-downtime migrations, `SELECT *` ban in production endpoints, compound index leftmost prefix discipline, partial soft-delete indexing, concurrent indexing, short transactions, zero network I/O inside DB transactions, PgBouncer transaction pooling mode safety (session state bans & `pg_advisory_xact_lock`), JSONB GIN `jsonb_path_ops` vs expression indexing, XID wraparound autovacuum defense, declarative range partitioning for append-only tables, covering indexes (`INCLUDE`) for pure index-only scans, sequential UUIDv7 to eliminate B-tree page splits, mandatory foreign key indexing, mandatory DDL `lock_timeout` and `statement_timeout` guards, connection pool sizing mathematics (Little's Law), lost update prevention in read-modify-write cycles (atomic updates, row locks, OCC), partial indexing on active/pending status queues, correlated column extended statistics (`CREATE STATISTICS`), pgvector HNSW vs IVFFlat production invariants (cosine `<=>` vs inner product `<#>` and `maintenance_work_mem`), MVCC dead tuple bloat autovacuum tuning, transaction isolation anomaly retry loops, Row-Level Security (RLS) query planner traps with `security_invoker = true` views, and Write-Ahead Log (WAL) volume defense via `UNLOGGED` scratch tables.
- ⚡ **Redis & In-Memory Caching Invariants (`rules/redis-caching.md`)**: Absolute ban on `KEYS *` in production (enforces non-blocking `SCAN` cursors), `UNLINK` over synchronous `DEL` for BigKeys, cache stampede / thundering herd mitigation via Singleflight and probabilistic early expiration (XFetch), mandatory TTL jitter to eliminate cache avalanches, cache penetration defense (sentinel empty caching & Bloom filters), safe distributed locking with atomic token verification via Lua scripts, sliding-window rate limiters with Sorted Sets, and cache-aside invalidation discipline.
- 📨 **Apache Kafka & Event Streaming Invariants (`rules/kafka-event-streaming.md`)**: Mandatory idempotent producer (`enable.idempotence=true`), strict `acks=all` with `min.insync.replicas=2` delivery guarantees, partition key strategies to eliminate hot partitions, consumer poll loop heartbeat safety (`max.poll.interval.ms` starvation prevention), prohibition of auto-commit (`enable.auto.commit=false`) to prevent silent data loss, `CooperativeStickyAssignor` to eradicate stop-the-world rebalance storms, three-tier non-blocking retries with Dead Letter Topics (DLT), Schema Registry backward/forward compatibility contracts, and signal-driven graceful shutdown with consumer `wakeup()`.
- 📊 **Observability, OpenTelemetry & Telemetry Hygiene (`rules/observability-telemetry.md`)**: Absolute ban on raw unformatted log statements, structured JSON logging with automated PII and credential masking, Prometheus metric cardinality explosion defense (strict ban on dynamic user/order IDs in labels), metric type semantics (Counter, Gauge, Histogram buckets), the Four Golden Signals, W3C `traceparent` distributed context propagation, OpenTelemetry span lifecycle management with explicit error status tagging, and probe decoupling (`/livez` vs `/readyz`).
- ⚡ **gRPC & Protocol Buffers Production Invariants (`rules/grpc-protobuf.md`)**: Binary wire compatibility guarantees, immutable field tag numbering, mandatory `reserved` tagging upon field deprecation, `ENUM_TYPE_UNSPECIFIED = 0` standard to prevent zero-value semantic ambiguity, proto3 `optional` presence flags, W3C `grpc-timeout` deadline propagation, canonical gRPC status code mapping (`codes.InvalidArgument`, `codes.NotFound`, `codes.FailedPrecondition`), rich error details with `google.rpc.Status` (`BadRequest.FieldViolation`), streaming backpressure safety, singleton `ClientConn` reuse, NAT/load balancer keepalive ping settings (`KeepaliveEnforcementPolicy`), and layered interceptor ordering.
- 📡 **WebSockets, Server-Sent Events & Real-Time Streaming (`rules/websockets-realtime.md`)**: Architectural protocol matrix (SSE for unidirectional LLM token/progress streams vs WebSockets for duplex collaborative editing), absolute ban on short-polling, native Ping/Pong control frame heartbeats and dead TCP connection pruning, reconnection storm mitigation via full-jitter exponential backoff, monotonic message IDs with server replay ring buffers for gapless reconnection, outbound backpressure with slow consumer eviction to prevent server OOM, multi-node horizontal fanout via distributed pub/sub brokers (Redis Streams/NATS), zero-downtime rolling deploys with WebSocket Close Code `1001 (Going Away)`, and Cross-Site WebSocket Hijacking (CSWSH) Origin whitelist validation.
- ⚡ **Web Performance, Core Web Vitals & Browser Runtime Invariants (`rules/web-performance-vitals.md`)**: Absolute ban on blocking long tasks (>50ms) in event handlers (Interaction to Next Paint / INP < 200ms threshold), yielding to paint via `scheduler.yield()` / macrotask fallback, layout thrashing & forced synchronous reflow elimination (batching reads before writes in `requestAnimationFrame`), Cumulative Layout Shift (CLS < 0.1) defense with mandatory media dimensions and font metric matching (`size-adjust`), Largest Contentful Paint (LCP < 2.5s) hero image priority (`fetchpriority="high"`, `loading="eager"`), DOM tree ceiling (<1,500 nodes) with list virtualization, dynamic code splitting for heavy dependencies, and detached DOM memory leak elimination.
- 💚 **Vue 3 & Nuxt 3 (`rules/vue-nuxt.md`)**: Enforces `<script setup lang="ts">`, Vue 3.4+ `defineModel()` two-way binding invariants, Vue 3.5+ `useId()` hydration-safe accessible ID generation, reactive props destructuring & `useTemplateRef()`, `onWatcherCleanup()`, bans `reactive()` reassignment, strictly bans module-scope mutable state in Nuxt SSR (prevents multi-tenant cross-request state pollution), enforces Nitro runtime validation (`readValidatedBody`) and server middleware memory leak defense, Nuxt 3 route middleware navigation return discipline (`return navigateTo(...)`), guarantees Pinia `storeToRefs` & side-effect cleanup, accessible headless component primitives (Radix Vue / Reka UI) with keyboard focus traps, Teleport client-mounted guards, Nuxt image optimization, optimistic UI updates with rollback, `shallowRef` for large virtualized collections, `useAsyncData` parameterized unique cache key deduplication, and custom directive event listener cleanup.
- 🧡 **Svelte 5 Runes & SvelteKit (`rules/svelte-sveltekit.md`)**: Complete ban on legacy Svelte 3/4 reactive syntax, strict `$state` vs `$state.raw` memory discipline, Svelte 5 `$derived.by()` multi-statement derivations, Svelte 5 `$bindable()` runes two-way contract, prohibition of `$effect()` for derived computations, SSR hydration guards, form actions progressive enhancement (`use:enhance`) with accessible `fail(400, ...)` validation errors, universal reactivity safety in `.svelte.ts` modules, accessible headless widget primitives (Bits UI), View Transitions API integration, compile-time image optimization (`@sveltejs/enhanced-img`), untracked reads with `untrack()`, optimistic mutations, granular cache invalidation (`invalidate(url)` over `invalidateAll()`), Svelte 5 typed Snippets over legacy `<slot>`, and non-critical streaming data in `PageServerLoad`.
- ⚛️ **Next.js 14/15 & React (`rules/react-nextjs.md`)**: Enforces App Router Server/Client boundaries, Next.js 15 async request APIs (`await params`), `server-only` leak protection, Server Actions authorization guards, hydration mismatch elimination, Server Secret leak prevention via React Taint APIs (`experimental_taintUniqueValue` / `experimental_taintObjectReference`), non-blocking transitions with `useTransition`, and tactile aesthetic restraint.
- 🦀 **Rust Industrial Safety (`rules/rust.md`)**: Strictly bans `.unwrap()` in production branches, enforces `Result<?>` error propagation, Tokio async executor starvation guards, and zero-copy borrowing patterns.
- 🐍 **Python & FastAPI (`rules/python-fastapi.md`)**: Mandates strict type hints, Pydantic validation, and bans silent `except Exception: pass`.
- 🤖 **Multi-Agent & MCP Protocols (`templates/AGENTS.md`)**: Context window anti-rot discipline, compacted hand-offs, sub-agent isolation, and safe Model Context Protocol (MCP) tool payload constraints.
- 🎯 **Modern Cursor `.mdc` Rules**: All rules include YAML frontmatter (`description`, `globs`, `alwaysApply: false`) ready for Cursor's intelligent auto-attaching rule engine.

---

## ⚡ 1-Second Quick Start

Drop into your current project with one command:

```bash
curl -fsSL https://raw.githubusercontent.com/TrustDec/agent-arsenal/main/install.sh | bash
```

Or copy the files directly into your project root:
- Copy `rules/CLAUDE.md` to `./CLAUDE.md` (and `./.windsurfrules`, `./.clinerules`, `./.github/copilot-instructions.md`)
- Copy `rules/.cursorrules` to `./.cursorrules` (and stack rules into `./.cursor/rules/*.mdc`)
- Copy `skills/` to `./.agents/skills/`
- Copy `templates/AGENTS.md` to `./AGENTS.md`

---

## 📂 Repository Structure

```text
agent-arsenal/
├── rules/
│   ├── CLAUDE.md           # Master rules for Claude Code, Windsurf, Copilot, Cline
│   ├── .cursorrules        # Optimized rules for Cursor IDE (root fallback)
│   ├── clickhouse-olap.md  # ClickHouse columnar OLAP, MergeTree engines & analytics
│   ├── shell-bash-cli.md   # Shell/Bash automation, strict mode & CLI discipline
│   ├── edge-serverless-workers.md # Cloudflare Workers, Durable Objects & Edge runtime invariants
│   ├── background-jobs-workflows.md # Distributed task queues, durable execution & worker safety
│   ├── context-memory-engineering.md # Agent context engineering, KV caching & memory banks
│   ├── auth-identity.md    # OAuth 2.1, JWT security, token rotation & session invariants
│   ├── testing-discipline.md # Anti-flakiness, hermetic isolation & test engineering
│   ├── cicd-github-actions.md # Action SHA pinning, script injection & CI/CD safety
│   ├── api-distributed-systems.md # Resilient APIs, idempotency & distributed tracing
│   ├── ai-llm-rag.md       # AI, LLM apps, RAG pipelines & vector search safety
│   ├── security-appsec.md  # Application security, SSRF defense & OWASP invariants
│   ├── docker-containers.md# Multi-stage builds, non-root user & container safety
│   ├── kubernetes-cloud-native.md # Probes, preStop zero-downtime & k8s security
│   ├── terraform-iac.md    # Remote state locks, prevent_destroy & cloud IaC safety
│   ├── mcp-server.md       # Model Context Protocol (MCP) server & tool discipline
│   ├── typescript.md       # Strict typing, runtime validation & Node/Bun invariants
│   ├── golang.md           # Concurrency, context & Go production discipline
│   ├── database-sql.md     # Zero-downtime migrations & SQL invariants
│   ├── redis-caching.md    # Redis caching, distributed locks & stampede defense
│   ├── kafka-event-streaming.md # Apache Kafka, rebalances, idempotent producers & DLT
│   ├── grpc-protobuf.md    # gRPC, Protocol Buffers wire compatibility & streaming
│   ├── websockets-realtime.md # WebSockets, SSE, heartbeats & reconnect jitter
│   ├── web-performance-vitals.md # Web performance, Core Web Vitals (INP/LCP/CLS) & runtime
│   ├── observability-telemetry.md # OpenTelemetry tracing, Prometheus & logging
│   ├── svelte-sveltekit.md # Svelte 5 Runes & SvelteKit SSR invariants
│   ├── vue-nuxt.md         # Vue 3 Composition API & Nuxt 3 SSR invariants
│   ├── react-nextjs.md     # Next.js 15 App Router & Server Actions invariants
│   ├── rust.md             # Anti-unwrap, async Tokio & Rust safety rules
│   └── python-fastapi.md   # Strict typing & Python invariants
├── skills/
│   ├── design-system/      # Apple/Vercel-level aesthetic taste engine
│   ├── code-discipline/    # Staff Engineer verification protocol
│   └── context-engineering/# KV cache prefix optimization & memory bank protocols
├── templates/
│   └── AGENTS.md           # Multi-agent collaboration & MCP context protocols
└── install.sh              # 1-click installer (Cursor, Claude Code, Windsurf, Copilot, Pi)
```

---

## 📄 License

MIT © [TrustDec](https://github.com/TrustDec)
