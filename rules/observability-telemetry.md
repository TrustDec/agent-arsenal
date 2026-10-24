---
description: Production observability, OpenTelemetry distributed tracing, Prometheus metric hygiene, and structured logging invariants
globs: **/*.{ts,js,go,py,rs,java},**/telemetry/**,**/logger/**,**/metrics/**
alwaysApply: false
---

# Observability, OpenTelemetry & Production Telemetry Invariants

> Add these rules to your project if writing production services, instrumenting microservices with OpenTelemetry, publishing Prometheus metrics, or configuring structured logging.

## 1. Structured Logging & Sensitive Data Masking
- ❌ **ABSOLUTE BAN ON RAW PRINT STATEMENTS IN PRODUCTION**:
  - Never use `console.log`, `fmt.Println`, or `print()` for application logs.
  - ✅ **Always use structured JSON loggers** (`pino` / `winston` for Node, `zap` / `zerolog` for Go, `structlog` for Python, `tracing` for Rust). Output must be machine-parseable single-line JSON on `stdout`.
- ❌ **ZERO SENSITIVE DATA IN LOGS (PII & CREDENTIAL DEFENSE)**:
  - NEVER log raw authorization headers, bearer tokens, API keys, passwords, session cookies, payment card numbers (PAN), CVVs, or unmasked national IDs.
  - Implement automated log redaction at logger initialization:
    ```ts
    // Example Pino redaction configuration
    const logger = pino({
      redact: {
        paths: [
          'req.headers.authorization',
          'req.headers.cookie',
          'password',
          'token',
          'credit_card',
          'secret'
        ],
        censor: '[REDACTED]'
      }
    })
    ```
- **Contextual Correlation Invariant**:
  - Every log emitted during an HTTP request, background job, or RPC call MUST include contextual identifiers:
    - `trace_id`: Correlates logs directly with OpenTelemetry traces.
    - `span_id`: Identifies the specific operation unit.
    - `tenant_id` / `org_id`: Identifies multi-tenant context.
    - Never log unbounded request/response bodies without size truncation (e.g., cap payloads at 2KB).

## 2. Prometheus & OpenMetrics Cardinality Defense
- ❌ **ABSOLUTE BAN ON HIGH-CARDINALITY METRIC LABELS**:
  - The number of unique time series stored in Prometheus TSDB is the Cartesian product of all label values. Labeling a metric with unbounded, high-cardinality values will exhaust cluster memory and crash Prometheus.
  - ❌ **NEVER use the following as Prometheus metric labels**:
    - `user_id`, `account_id`, `tenant_id` (if thousands of tenants exist)
    - `order_id`, `transaction_id`, `uuid`
    - Full URL paths with dynamic path parameters (`/api/v1/orders/9847291`)
    - Error messages or stack trace strings
    - Client IP addresses or email addresses
  - ✅ **Always normalize paths to parameterized route templates**:
    ```text
    // ❌ Disastrous (creates millions of TSDB series):
    http_requests_total{path="/users/usr_948271"} 1

    // ✅ Normalized route template (bounded series):
    http_requests_total{path="/users/:id", method="GET", status="200"} 1
    ```
- **Metric Type Semantics**:
  - **Counter**: Monotonically increasing value (e.g., `http_requests_total`, `errors_total`). Never decrement a Counter; use `Rate()` or `Increase()` in PromQL.
  - **Gauge**: Instantaneous value that goes up and down (e.g., `active_connections`, `memory_allocated_bytes`, `queue_depth`).
  - **Histogram**: Measures distribution of values (e.g., `http_request_duration_seconds`). Always configure explicit, exponential, or domain-tuned buckets. Do not use default fine-grained linear buckets across 4 orders of magnitude.
- **The Four Golden Signals**:
  - Every critical production service MUST expose metrics covering:
    1. **Latency**: Duration to service requests (p50, p95, p99 histograms).
    2. **Traffic**: Demand placed on the service (requests per second counter).
    3. **Errors**: Rate of failed requests (status code 5xx counters).
    4. **Saturation**: Utilization of constrained resources (memory %, connection pool utilization gauge).

## 3. OpenTelemetry (OTel) Distributed Tracing Invariants
- **W3C Trace Context Propagation**:
  - Distributed context MUST be propagated across all network hops (HTTP, gRPC, Kafka, RabbitMQ) using standard W3C `traceparent` and `tracestate` headers:
    ```text
    traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
    ```
  - When issuing downstream HTTP calls, inject active context via OTel propagators:
    ```go
    otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
    ```
- **Span Lifecycle & Error Recording**:
  - Every started span MUST be terminated via `span.End()` (or defer in Go/Rust) to prevent memory leaks and skewed durations:
    ```go
    ctx, span := tracer.Start(ctx, "ProcessOrder")
    defer span.End()

    if err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return err
    }
    ```
  - Mark span status explicitly with `StatusCode.ERROR` when an operation fails. Recording an exception alone without setting the error status leaves the span marked as successful in APM dashboards.
- **Semantic Conventions**:
  - Strictly follow standard OpenTelemetry semantic convention attribute names:
    - HTTP: `http.request.method`, `http.response.status_code`, `url.path`
    - Database: `db.system`, `db.name`, `db.statement` (sanitized of literal values)
    - RPC: `rpc.system`, `rpc.service`, `rpc.method`
  - Do not invent custom attribute names for concepts already standardized by OTel.
- **Trace Sampling Discipline**:
  - For high-throughput services (>1,000 req/s), never use 100% head-based trace sampling in production.
  - Use parent-based sampling with probabilistic ratio (e.g., 5-10%) or tail-based sampling in an OpenTelemetry Collector to capture 100% of errors while bounding ingestion costs.

## 4. Health Check Probes & Telemetry Separation
- **Decouple Telemetry from Business Traffic**:
  - Expose Prometheus `/metrics` and internal health probes on a dedicated internal port or protected route path.
  - Ban public internet exposure of `/metrics` endpoints (prevents information disclosure and DoS against metric scrapers).
- **Liveness vs Readiness Probe Distinction**:
  - `/livez` (Liveness): Returns `200 OK` if the process is alive and event loop is not deadlocked. ❌ **NEVER check external dependencies (DB, Redis, downstream APIs) in liveness checks**. A database outage must not cause Kubernetes to kill and restart all application pods.
  - `/readyz` (Readiness): Returns `200 OK` only when the service has warmed caches, connected to database pools, and is ready to accept incoming user traffic.
