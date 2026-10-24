---
description: Golang concurrency safety, context lifecycle propagation, memory leak prevention, and production invariants
globs: **/*.go,**/go.mod
alwaysApply: false
---

# Golang Production Discipline & Concurrency Safety

> Add these rules to your project if developing in Go (Golang) microservices, CLI tools, high-performance network services, or distributed backends.

## 1. Concurrency, Context Lifecycle & Goroutine Hygiene
- **Context is King**:
  - `ctx context.Context` MUST always be the first parameter in I/O and long-running functions.
  - ❌ **NEVER store `context.Context` inside a `struct`**. Pass it down explicitly through call stacks.
  - When spawning background work derived from a request, deliberately choose between propagating cancellation (`ctx`) or detaching for async completion (`context.WithoutCancel(ctx)` in Go 1.21+).
- **Zero Goroutine Leaks**:
  - Every goroutine spawned MUST have a deterministic, provable termination condition (e.g., listening to `ctx.Done()`, bounded channel iteration, or managed via `golang.org/x/sync/errgroup`).
  - Prefer `errgroup.WithContext(ctx)` for concurrent task fan-out so the first error cancels sibling workers:
    ```go
    g, ctx := errgroup.WithContext(ctx)
    for _, item := range items {
        item := item // invariant for Go < 1.22
        g.Go(func() error {
            return processItem(ctx, item)
        })
    }
    if err := g.Wait(); err != nil {
        return fmt.Errorf("batch processing failed: %w", err)
    }
    ```
- **Loop Variable Goroutine Capture**:
  - In Go 1.22+, `for` loop variables are scoped per iteration. However, for codebases targeting Go < 1.22 or maintaining backward-compatible libraries, ALWAYS shadow loop variables (`item := item`) before passing into a goroutine or closure.
- **Modern Typed Atomics (`sync/atomic`)**:
  - Use Go 1.19+ typed atomic primitives (`atomic.Int64`, `atomic.Bool`, `atomic.Pointer[T]`) instead of error-prone low-level pointer arithmetic (`atomic.AddInt64(&val, 1)`). They guarantee memory alignment and type safety.
- **Channel Sizing, Backpressure & Non-Blocking Invariants**:
  - Prefer unbuffered channels for strict synchronous synchronization handoffs.
  - Buffered channels must have explicit documented sizing rationale; never use unbounded buffers as makeshift queues.
  - When emitting telemetry or dropping low-priority events under high load, use non-blocking `select` with `default` to prevent worker starvation:
    ```go
    select {
    case ch <- metric:
    default:
        // Channel full: record drop metric to prevent blocking producer goroutines
        droppedCounter.Add(1)
    }
    ```
- **Race Condition Immunity**:
  - Always run tests with the race detector enabled: `go test -race ./...`. Any detected data race is a blocking production bug.
- **Mutex Discipline & Copy Prevention**:
  - Always pair `mu.Lock()` with `defer mu.Unlock()` immediately on the next line unless micro-benchmarked in high-frequency critical sections with documented rationale.
  - ❌ **NEVER copy structs containing `sync.Mutex` or `sync.RWMutex` by value**. Pass them via pointer (`*Server`), or declare them with `go vet` copylocks checking.
- **Channel Ownership Discipline**:
  - The sender goroutine owns the channel and is exclusively responsible for closing it.
  - ❌ **NEVER close a channel from the receiver end** or close a channel multiple times (causes panic).

## 2. Explicit Error Handling & Sentinel Hygiene
- ❌ **NEVER USE `_ = err` or ignore returned errors**:
  - Check every single error return, including `f.Close()`, `w.Write()`, and JSON encoding.
- **Preserve Causal Chains**:
  - Wrap errors with context using `%w`: `fmt.Errorf("failed to process order %s: %w", orderID, err)`.
  - Use `errors.Is(err, target)` instead of direct equality (`err == target`) to support wrapped errors.
  - Use `errors.As(err, &targetStruct)` instead of type asserting (`err.(*CustomError)`).
- **Zero Panic in Production**:
  - `panic()` is strictly forbidden in request/worker lifecycles. Panic is only permissible in `init()` or `main()` when mandatory configuration or static initialization fails fatally.

## 3. Memory & Resource Safety
- **Slice Sub-slicing Memory Retention Trap**:
  - Sub-slicing a small portion of a massive array keeps the entire underlying memory pinned:
    ```go
    // ❌ Leaks the entire 10MB buffer:
    smallHeader := hugeBuffer[:32]

    // ✅ Allocate a new slice to let the GC reclaim hugeBuffer:
    smallHeader := make([]byte, 32)
    copy(smallHeader, hugeBuffer[:32])
    ```
- **Timer & Ticker Leaks in Long-Running Loops**:
  - Always stop tickers: `ticker := time.NewTicker(interval); defer ticker.Stop()`.
  - ❌ **AVOID `time.After` inside loops or select statements**: `time.After` allocations are not garbage collected until the timer expires. Use an explicit `time.NewTimer` and stop/drain it when done.
- **`sync.Pool` Reset Discipline & Memory Retention**:
  - Always reset slice lengths (`buf = buf[:0]`) before returning buffers to a `sync.Pool`.
  - Cap buffer sizes before `pool.Put(buf)` to avoid retaining memory from abnormal large spikes:
    ```go
    if cap(buf) <= maxReusableBufferSize {
        pool.Put(buf[:0])
    }
    ```
  - Never store pointers to structs that retain references to external large objects inside `sync.Pool`, which pins them against garbage collection.
- **Drain Before Close for HTTP Response Bodies**:
  - When consuming HTTP response bodies, ALWAYS drain before closing to ensure TCP connection reuse (keep-alive):
    ```go
    resp, err := client.Do(req)
    if err != nil {
        return err
    }
    defer resp.Body.Close()
    _, _ = io.Copy(io.Discard, resp.Body)
    ```
- **Timeouts on All Network I/O**:
  - ❌ **NEVER use `http.DefaultClient` in production**: It has no timeout by default. Always configure explicit `Timeout`, `IdleConnTimeout`, and transport deadlines.
- **Nil Slice vs Empty Slice**:
  - Be deliberate with JSON serialization: `var s []T` serializes to `null`, while `s := []T{}` serializes to `[]`. Use consistent conventions across API boundaries.

## 4. Architecture, Receivers & Interface Restraint
- **Accept Interfaces, Return Concrete Types**:
  - Keep interfaces small, caller-defined, and focused (1-2 methods like `io.Reader`, `io.Closer`).
  - Do not export massive mock-oriented interfaces from provider packages.
- **Receiver Consistency**:
  - Do not mix pointer and value receivers on the same type arbitrarily.
  - Use pointer receivers (`func (s *Service) Method()`) if the method mutates state, contains locks, or if the struct is large. Use value receivers only for small immutable scalar values.
- **No Generic Garbage Dumps**:
  - Ban generic `common`, `utils`, and `helper` packages. Organize packages by domain capability (e.g., `auth`, `billing`, `storage`).

## 5. Graceful Shutdown Invariant
- Distributed services and HTTP servers must cleanly shut down on OS signals:
  ```go
  ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
  defer stop()

  srv := &http.Server{Addr: ":8080", Handler: router}
  go func() {
      if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
          log.Fatalf("listen error: %v", err)
      }
  }()

  <-ctx.Done()
  shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
  defer cancel()
  if err := srv.Shutdown(shutdownCtx); err != nil {
      log.Printf("server forced to shutdown: %v", err)
  }
  ```

## 6. GC Tuning, Struct Memory Layout & Goroutine Panic Boundaries
- **Container Memory Limits & GC Pacing (`GOMEMLIMIT` & `GOGC`)**:
  - In containerized workloads (Kubernetes, ECS), Go's runtime default GC triggers when heap size doubles, making it blind to cgroup memory limits and triggering abrupt OOM kills.
  - Set `GOMEMLIMIT` to ~85-90% of the container's hard memory limit (e.g., `GOMEMLIMIT=900MiB` for a 1GiB pod) and tune `GOGC` (default 100) to balance GC CPU overhead against memory pressure under traffic spikes.
- **Struct Memory Alignment & Field Ordering**:
  - On 64-bit architectures, struct fields are padded to 8-byte word boundaries.
  - Order struct fields by descending size (pointers, `int64`, `float64` first; `int32`, `int16` middle; `bool`, `byte` last) to eliminate padding holes. For slices of millions of structs, proper alignment cuts memory footprint by 20–40%.
- **`sync.OnceFunc` & Thread-Safe Lazy Initialization (Go 1.21+)**:
  - Prefer Go 1.21+ functional once primitives (`sync.OnceFunc`, `sync.OnceValue`, `sync.OnceValues`) over manual `sync.Once` and outer-scoped closure variables. They automatically propagate panics and simplify thread-safe lazy singletons.
- **Goroutine Panic Boundary Protection**:
  - ❌ **NEVER spawn a background goroutine without panic recovery**: An unhandled panic in ANY spawned goroutine instantly crashes the entire Go process, bypassing HTTP recovery middleware.
  - Enforce safe worker recovery wrappers for async goroutines:
    ```go
    func SafeGo(logger *slog.Logger, fn func()) {
        go func() {
            defer func() {
                if r := recover(); r != nil {
                    logger.Error("recovered from unhandled goroutine panic",
                        "error", r,
                        "stack", string(debug.Stack()),
                    )
                }
            }()
            fn()
        }()
    }
    ```
- **Zero-Allocation String Concatenation**:
  - ❌ **NEVER use `+` or `fmt.Sprintf` in high-frequency loops**:
  - Use `strings.Builder` and pre-allocate capacity via `builder.Grow(estimatedLen)` to eradicate intermediate heap allocations and GC pressure.

