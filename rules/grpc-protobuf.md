---
description: gRPC, Protocol Buffers schema evolution, context deadline propagation, streaming backpressure, and high-performance RPC production invariants
globs: **/*.proto,**/*grpc*.*,**/*pb.go,**/*_pb2.py,**/*.pb.ts,**/buf.gen.yaml,**/buf.yaml
alwaysApply: false
---

# gRPC & Protocol Buffers Production Invariants

> Add these rules to your project if developing microservices, high-performance distributed RPCs, AI inference streaming endpoints, or gRPC clients/servers (Go, Rust, Python, TypeScript, Java).

---

## 1. Protobuf Schema Evolution & Wire Compatibility Invariants
- **Field Numbers (Tags) are the Irreversible Wire Contract**:
  - In Protocol Buffers, field names are purely syntactic sugar for human code; the binary wire format encodes ONLY field tags and wire types.
  - ❌ **NEVER change, reuse, or reassign a field tag number** once published. Reassigning field `2` from `user_id` to `organization_id` causes silent data corruption in existing client deserializers.
- **Mandatory `reserved` Directives on Field Deprecation**:
  - When removing or deprecating fields, IMMEDIATELY declare both tag numbers and field names as `reserved`:
    ```protobuf
    syntax = "proto3";
    package acme.orders.v1;

    message Order {
      // ❌ NEVER delete tag 3 or reuse it for a new concept!
      reserved 3, 7, 15 to 20;
      reserved "old_auth_token", "legacy_status";

      string order_id = 1;
      int64 amount_cents = 2;
      // Tag 3 is permanently retired
      OrderStatus status = 4;
    }
    ```
  - This prevents future engineers or AI agents from reallocating the deprecated tag or name.
- **Strict Prohibition of Wire Type Alterations**:
  - ❌ **NEVER change the type of an existing field** (e.g. `int32` to `string`, or `string` to `bytes`). While some scalar types share wire types (like `int32`, `int64`, `bool` as varints), client-side decoders across Go, Python, and Rust will throw deserialization errors or truncate data.
- **Enum Zero-Value Standard (`ENUM_TYPE_UNSPECIFIED`)**:
  - The first enum value MUST always be tag `0` and explicitly suffixed with `_UNSPECIFIED`:
    ```protobuf
    enum OrderStatus {
      ORDER_STATUS_UNSPECIFIED = 0;
      ORDER_STATUS_PENDING = 1;
      ORDER_STATUS_PAID = 2;
      ORDER_STATUS_FULFILLED = 3;
      ORDER_STATUS_CANCELLED = 4;
    }
    ```
  - **Rationale**: In proto3, unset fields default to `0`. If tag `0` represents a valid business state (e.g., `ORDER_STATUS_PENDING = 0;`), an uninitialized or missing field masquerades as a valid state, causing silent state machine corruption.
- **Presence Semantics: Proto3 Optional vs Wrappers**:
  - In proto3, scalar fields have no natural `null` value (defaulting to `0`, `""`, or `false`).
  - When you need to distinguish between "field not provided" vs "explicitly set to 0/false" (e.g., PATCH updates or nullable database columns), use `optional`:
    ```protobuf
    // Generates has_discount_percent() / hasDiscountPercent() presence checks:
    optional int32 discount_percent = 5;
    ```
- **Package Versioning & File Directory Alignment**:
  - Every proto file MUST include a major version in its package declaration: `package acme.inventory.v1;`.
  - Directory structures must mirror the package name: `proto/acme/inventory/v1/inventory.proto`.
  - Never introduce breaking changes to `v1`. When an API requires incompatible alterations, create `acme.inventory.v2` in a parallel directory to allow both versions to coexist on the same gRPC server port.

---

## 2. Context Deadline, Timeout & Cancellation Propagation
- **Mandatory Client-Side Context Deadlines**:
  - ❌ **NEVER call a gRPC RPC without an explicit context timeout/deadline**:
    ```go
    // ❌ CATASTROPHIC: Unbounded wait can hang indefinitely on network partitions
    resp, err := client.GetOrder(ctx, req)

    // ✅ Enforce bounded timeout on every RPC call:
    ctx, cancel := context.WithTimeout(parentCtx, 2500*time.Millisecond)
    defer cancel()
    resp, err := client.GetOrder(ctx, req)
    ```
  - Default gRPC calls without timeouts wait forever, exhausting application thread pools and goroutines during network splits or downstream outages.
- **W3C & `grpc-timeout` Downstream Deadline Propagation**:
  - gRPC automatically serializes deadlines over the wire using the `grpc-timeout` header.
  - Downstream microservices MUST accept and propagate the incoming `ctx` to all subsequent database queries, cache lookups, and downstream RPC calls.
- **Early Cancellation Checks Before Expensive Operations**:
  - In long-running RPC handlers or streaming loops, proactively check `ctx.Err()` before executing expensive computations or external I/O:
    ```go
    if err := ctx.Err(); err != nil {
        return status.FromContextError(err).Err()
    }
    ```
- **Distinguish Client Disconnects from System Errors**:
  - Handle `codes.Canceled` (client closed connection or clicked "Cancel") as expected operational events. Log at `INFO` or `DEBUG` level—never trigger pager alerts on `codes.Canceled`.

---

## 3. Canonical Status Codes & Rich Error Models
- ❌ **BAN RAW STRING ERRORS OR LEAKING INTERNAL STACK TRACES**:
  - Never return raw Go `errors.New("db connection failed")` or Python exceptions over gRPC. They map to generic untyped errors and expose internal infrastructure details.
- **Canonical gRPC Status Code Mapping**:
  - Always map domain failures to exact canonical status codes (`google.golang.org/grpc/codes`, `grpc::StatusCode`):
    | Failure Scenario | Canonical gRPC Code | HTTP Equivalent |
    | :--- | :--- | :--- |
    | Payload validation error, missing field | `codes.InvalidArgument` | 400 Bad Request |
    | Missing auth token, expired signature | `codes.Unauthenticated` | 401 Unauthorized |
    | Caller lacks permission for resource | `codes.PermissionDenied` | 403 Forbidden |
    | Resource ID does not exist | `codes.NotFound` | 404 Not Found |
    | Unique constraint / idempotency key conflict | `codes.AlreadyExists` | 409 Conflict |
    | Invalid state transition (e.g. cancel paid order) | `codes.FailedPrecondition` | 412 Precondition Failed |
    | Rate limit exceeded, quota exhausted | `codes.ResourceExhausted` | 429 Too Many Requests |
    | RPC context deadline expired | `codes.DeadlineExceeded` | 504 Gateway Timeout |
    | Downstream service temporarily unavailable | `codes.Unavailable` | 503 Service Unavailable |
    | Unhandled exception, internal panic | `codes.Internal` | 500 Internal Error |

- **Rich Error Models with `google.rpc.Status` & Typed Details**:
  - Use `status.WithDetails()` to return machine-readable structured error payloads alongside the status code:
    ```go
    st := status.New(codes.InvalidArgument, "invalid order parameters")
    br := &errdetails.BadRequest{
        FieldViolations: []*errdetails.BadRequest_FieldViolation{
            {Field: "amount_cents", Description: "amount must be greater than zero"},
        },
    }
    stWithDetails, err := st.WithDetails(br)
    if err == nil {
        return stWithDetails.Err()
    }
    return st.Err()
    ```
  - Standard error details to leverage:
    - `errdetails.BadRequest`: Granular field-level validation violations.
    - `errdetails.RetryInfo`: Specifies `retry_delay` for backoff on transient spikes.
    - `errdetails.ErrorInfo`: Machine-readable error `reason` and `domain` without brittle string parsing.

---

## 4. Streaming Discipline & Backpressure Safety
- **Server Streaming Loop Cancellation Awareness**:
  - ❌ **NEVER iterate over a stream without checking context cancellation**:
    ```go
    // ✅ Safe server streaming pattern:
    for item := range itemQueue {
        select {
        case <-stream.Context().Done():
            return status.FromContextError(stream.Context().Err()).Err()
        default:
            if err := stream.Send(item); err != nil {
                return fmt.Errorf("failed to send stream message: %w", err)
            }
        }
    }
    ```
- **Backpressure & Bounded Memory Queues in Bidirectional Streaming**:
  - When bridging internal channels or queues to a gRPC stream, always use bounded channels (`make(chan T, 256)`).
  - If a slow client fails to read from the stream, bounded channels apply backpressure upstream. Never buffer unlimited items in heap memory.
- **Concurrent Stream Send/Recv Race Condition Ban**:
  - In Go and other gRPC client libraries, calling `stream.SendMsg()` or `stream.RecvMsg()` concurrently from multiple goroutines/threads on the same stream is **STRICTLY PROHIBITED** and causes race panics or corrupt frames.
  - Serialize all outbound `Send()` calls through a single dedicated worker goroutine.

---

## 5. Connection Lifecycle, HTTP/2 Multiplexing & Keepalives
- **Singleton `ClientConn` Reuse**:
  - A gRPC `ClientConn` represents a pooled set of multiplexed HTTP/2 connections and is fully thread-safe.
  - ❌ **NEVER create a new `ClientConn` per RPC request**:
    ```go
    // ❌ CATASTROPHIC ANTIPATTERN: Handshakes TLS and HTTP/2 on every single request
    conn, _ := grpc.Dial(target, opts...)
    defer conn.Close()
    ```
  - Instantiate a single `ClientConn` at service startup, share it across all concurrent handlers, and close it only on application shutdown.
- **NAT Gateway & Cloud Load Balancer Keepalive Settings**:
  - AWS ALBs, GCP Cloud Load Balancers, and corporate NAT gateways silently terminate idle TCP connections after 60 to 350 seconds without sending TCP RST or FIN packets.
  - Clients must configure active keepalive pings to keep long-lived gRPC connections healthy:
    ```go
    var clientKeepalive = keepalive.ClientParameters{
        Time:                30 * time.Second, // Send ping every 30s if idle
        Timeout:             10 * time.Second, // Wait 10s for ping ack before dropping conn
        PermitWithoutStream: true,             // Send pings even with no active RPC streams
    }
    conn, err := grpc.Dial(target, grpc.WithKeepaliveParams(clientKeepalive), ...)
    ```
- **Server-Side Ping Flood Protection (`KeepaliveEnforcementPolicy`)**:
  - Servers must permit client keepalive pings without immediately severing connections with `ENHANCE_YOUR_CALM` / `too_many_pings` GOAWAY frames:
    ```go
    var serverEnforcement = keepalive.EnforcementPolicy{
        MinTime:             10 * time.Second, // Minimum ping interval expected from clients
        PermitWithoutStream: true,             // Allow pings even when no active streams exist
    }
    s := grpc.NewServer(grpc.KeepaliveEnforcementPolicy(serverEnforcement), ...)
    ```
- **Graceful Shutdown Drain**:
  - On OS termination signals (`SIGTERM`), call `server.GracefulStop()` to reject new incoming RPCs while allowing active in-flight requests to finish processing.
  - Pair with a fallback `context.WithTimeout` to call hard `server.Stop()` after a reasonable window (e.g., 10-15 seconds) so pods do not hang indefinitely during rolling deploys.

---

## 6. Interceptor Ordering & Pipeline Layering
- Interceptors must execute in a deterministic outer-to-inner pipeline:
  ```text
  Client Request
    │
    ▼
  1. Recovery Interceptor     ──► Traps panics, converts them into codes.Internal
    │
    ▼
  2. OpenTelemetry Tracing   ──► Extracts W3C traceparent, starts RPC span
    │
    ▼
  3. Prometheus Metrics       ──► Starts timer, increments request counter
    │
    ▼
  4. Authentication           ──► Validates JWT/mTLS credentials, injects caller identity
    │
    ▼
  5. Authorization (RBAC)     ──► Checks caller permissions against requested method
    │
    ▼
  6. Request Validation       ──► Validates Protobuf payload rules (protovalidate)
    │
    ▼
  7. Business Handler
  ```
- **Why Recovery First**: If an uncaught panic occurs anywhere in the handler or subsequent interceptors, the recovery interceptor catches it, logs the stack trace internally, and returns a sanitized `codes.Internal` status to the caller instead of crashing the process.

---

## 7. Tooling, Code Generation & Schema Hygiene
- ❌ **NEVER MANUALLY EDIT GENERATED PROTOC FILES**:
  - Never edit `*.pb.go`, `*_pb2.py`, or `*.pb.ts`. All changes must be made directly in `.proto` files and recompiled.
- **Enforce Modern Schema Linting & Breaking Change Checks via Buf**:
  - Use `buf` to enforce consistent naming conventions and catch breaking wire-format changes in CI:
    ```bash
    # Lint style conventions (PascalCase messages, snake_case fields):
    buf lint

    # Detect accidental breaking changes against main branch:
    buf breaking --against '.git#branch=main'
    ```
- **Validate Inputs Declaratively with `protovalidate`**:
  - Avoid handwritten repetitive validation code. Annotate `.proto` fields with standard constraints:
    ```protobuf
    import "buf/validate/validate.proto";

    message CreateUserRequest {
      string email = 1 [(buf.validate.field).string.email = true];
      string username = 2 [(buf.validate.field).string = {min_len: 3, max_len: 32}];
    }
    ```
