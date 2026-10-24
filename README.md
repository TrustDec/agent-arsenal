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

- 🧪 **Testing Discipline & Anti-Flakiness Invariants (`rules/testing-discipline.md`)**: Absolute ban on arbitrary `sleep` timeouts, clock virtualization (`fakeTimers`) for temporal logic, hermetic test isolation with per-test transaction rollback, multi-worker test database partitioning, elimination of "testing the mock" antipatterns, strict table-driven boundary matrices, and zero unhandled floating promises in async tests.
- 🚀 **CI/CD Automation & GitHub Actions Security (`rules/cicd-github-actions.md`)**: Full 40-character SHA pinning for third-party actions to prevent supply-chain hijacking, absolute elimination of script injection via intermediate environment variable mapping, top-level `permissions: contents: read` least privilege enforcement, elimination of the dangerous `pull_request_target` fork checkout trap, and OIDC cloud federation over static long-lived credentials.
- 🌐 **Resilient API Design & Distributed Systems (`rules/api-distributed-systems.md`)**: Mandatory `Idempotency-Key` contracts with atomic reservation & SHA-256 payload checksum validation, retry storm immunity with full-jitter exponential backoff, circuit breaker state machines (Closed/Open/Half-Open), W3C `traceparent` OpenTelemetry distributed context propagation, elimination of the Dual-Write trap via the Transactional Outbox pattern, RFC 7807 Problem Details error formatting, and distributed sliding-window rate limiting.
- 🧠 **AI, LLM Apps & RAG Systems (`rules/ai-llm-rag.md`)**: Strict Structured Outputs / JSON Schema validation, semantic chunking boundaries, hybrid search (dense embeddings + lexical BM25 via Reciprocal Rank Fusion), cross-encoder reranking, anti-prompt injection delimiter containment, token window budgeting, full-jitter exponential backoff, and SSE streaming disconnect cleanup.
- 🛡️ **Application Security & OWASP Defense (`rules/security-appsec.md`)**: Anti-SSRF guards with DNS pre-flight & private IP bans, absolute command injection / shell interpolation elimination, parameterized SQL invariants, path traversal immunity with canonical base checks, constant-time cryptographic comparison (`timingSafeEqual`), CSPRNG token discipline, and ReDoS prevention.
- 🐳 **Docker & Container Production Invariants (`rules/docker-containers.md`)**: Multi-stage build isolation with minimal attack surfaces (`distroless`/`alpine`), absolute ban on running as root (`USER nonroot`), PID 1 signal forwarding (`tini`/exec form) for zero-downtime graceful shutdown, secret isolation via `--mount=type=secret`, same-layer package cache pruning, and deterministic healthchecks.
- ☸️ **Kubernetes & Cloud-Native Infrastructure (`rules/kubernetes-cloud-native.md`)**: Absolute ban on external dependency checks in `livenessProbe` (preventing cascading cluster death spirals), mandatory `preStop` sleep hooks to eliminate 502 errors during rolling deployments, `terminationGracePeriodSeconds` sizing, Pod Security Standards (PSS) restricted hardening (`runAsNonRoot: true`, `readOnlyRootFilesystem: true`, drop all capabilities), `immutable: true` ConfigMaps/Secrets, secret volume mounts over environment variables, and PodDisruptionBudgets (PDB).
- 🔌 **Model Context Protocol (MCP) Server Engineering (`rules/mcp-server.md`)**: Absolute ban on stdio `stdout` pollution (`console.log` / `print` breaks JSON-RPC byte framing), mandatory descriptive Zod/Pydantic schemas for LLM tool selection, bounded token payload ceilings with pagination/projections, graceful error handling (`isError: true`), and path traversal / shell injection immunity.
- 🔷 **TypeScript & Runtime Discipline (`rules/typescript.md`)**: Total ban on `any` and unvalidated type assertions (`as T`), mandatory Zod/runtime validation at I/O boundaries, zero floating promises, non-null assertion (`!`) ban, discriminated unions, and safe Node/Bun stream & memory leak prevention.
- 🐹 **Golang Concurrency & Systems (`rules/golang.md`)**: Context lifecycle propagation, zero goroutine leaks with `errgroup`, sub-slice memory leak traps, `go test -race` invariants, explicit error wrapping (`%w`), HTTP response body drain requirements, and graceful OS signal shutdown.
- 🗄️ **SQL & Database Production Safety (`rules/database-sql.md`)**: Expand-and-contract zero-downtime migrations, `SELECT *` ban in production endpoints, compound index leftmost prefix discipline, partial soft-delete indexing, concurrent indexing, short transactions, and zero network I/O inside DB transactions.
- ⚡ **Redis & In-Memory Caching Invariants (`rules/redis-caching.md`)**: Absolute ban on `KEYS *` in production (enforces non-blocking `SCAN` cursors), `UNLINK` over synchronous `DEL` for BigKeys, cache stampede / thundering herd mitigation via Singleflight and probabilistic early expiration (XFetch), mandatory TTL jitter to eliminate cache avalanches, cache penetration defense (sentinel empty caching & Bloom filters), safe distributed locking with atomic token verification via Lua scripts, sliding-window rate limiters with Sorted Sets, and cache-aside invalidation discipline.
- 📨 **Apache Kafka & Event Streaming Invariants (`rules/kafka-event-streaming.md`)**: Mandatory idempotent producer (`enable.idempotence=true`), strict `acks=all` with `min.insync.replicas=2` delivery guarantees, partition key strategies to eliminate hot partitions, consumer poll loop heartbeat safety (`max.poll.interval.ms` starvation prevention), prohibition of auto-commit (`enable.auto.commit=false`) to prevent silent data loss, `CooperativeStickyAssignor` to eradicate stop-the-world rebalance storms, three-tier non-blocking retries with Dead Letter Topics (DLT), Schema Registry backward/forward compatibility contracts, and signal-driven graceful shutdown with consumer `wakeup()`.
- 📊 **Observability, OpenTelemetry & Telemetry Hygiene (`rules/observability-telemetry.md`)**: Absolute ban on raw unformatted log statements, structured JSON logging with automated PII and credential masking, Prometheus metric cardinality explosion defense (strict ban on dynamic user/order IDs in labels), metric type semantics (Counter, Gauge, Histogram buckets), the Four Golden Signals, W3C `traceparent` distributed context propagation, OpenTelemetry span lifecycle management with explicit error status tagging, and probe decoupling (`/livez` vs `/readyz`).
- 💚 **Vue 3 & Nuxt 3 (`rules/vue-nuxt.md`)**: Enforces `<script setup lang="ts">`, Vue 3.5+ reactive props destructuring & `useTemplateRef()`, `onWatcherCleanup()`, bans `reactive()` reassignment, strictly bans module-scope mutable state in Nuxt SSR (prevents multi-tenant cross-request state pollution), enforces Nitro runtime validation (`readValidatedBody`), and guarantees Pinia `storeToRefs` & side-effect cleanup.
- 🧡 **Svelte 5 Runes & SvelteKit (`rules/svelte-sveltekit.md`)**: Complete ban on legacy Svelte 3/4 reactive syntax, strict `$state` vs `$state.raw` memory discipline, prohibition of `$effect()` for derived computations, SSR hydration guards, form actions progressive enhancement (`use:enhance`), and universal reactivity safety in `.svelte.ts`.
- ⚛️ **Next.js 14/15 & React (`rules/react-nextjs.md`)**: Enforces App Router Server/Client boundaries, Next.js 15 async request APIs (`await params`), `server-only` leak protection, Server Actions authorization guards, and hydration mismatch elimination.
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
│   ├── testing-discipline.md # Anti-flakiness, hermetic isolation & test engineering
│   ├── cicd-github-actions.md # Action SHA pinning, script injection & CI/CD safety
│   ├── api-distributed-systems.md # Resilient APIs, idempotency & distributed tracing
│   ├── ai-llm-rag.md       # AI, LLM apps, RAG pipelines & vector search safety
│   ├── security-appsec.md  # Application security, SSRF defense & OWASP invariants
│   ├── docker-containers.md# Multi-stage builds, non-root user & container safety
│   ├── kubernetes-cloud-native.md # Probes, preStop zero-downtime & k8s security
│   ├── mcp-server.md       # Model Context Protocol (MCP) server & tool discipline
│   ├── typescript.md       # Strict typing, runtime validation & Node/Bun invariants
│   ├── golang.md           # Concurrency, context & Go production discipline
│   ├── database-sql.md     # Zero-downtime migrations & SQL invariants
│   ├── redis-caching.md    # Redis caching, distributed locks & stampede defense
│   ├── kafka-event-streaming.md # Apache Kafka, rebalances, idempotent producers & DLT
│   ├── observability-telemetry.md # OpenTelemetry tracing, Prometheus & logging
│   ├── svelte-sveltekit.md # Svelte 5 Runes & SvelteKit SSR invariants
│   ├── vue-nuxt.md         # Vue 3 Composition API & Nuxt 3 SSR invariants
│   ├── react-nextjs.md     # Next.js 15 App Router & Server Actions invariants
│   ├── rust.md             # Anti-unwrap, async Tokio & Rust safety rules
│   └── python-fastapi.md   # Strict typing & Python invariants
├── skills/
│   ├── design-system/      # Apple/Vercel-level aesthetic taste engine
│   └── code-discipline/    # Staff Engineer verification protocol
├── templates/
│   └── AGENTS.md           # Multi-agent collaboration & MCP context protocols
└── install.sh              # 1-click installer (Cursor, Claude Code, Windsurf, Copilot, Pi)
```

---

## 📄 License

MIT © [TrustDec](https://github.com/TrustDec)
