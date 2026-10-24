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

## 7. High-Performance Allocations, Structured Logging & Interface Safety
- **Slice & Map Capacity Pre-Allocation**:
  - ❌ **NEVER append in a loop to a zero-capacity slice or insert into an un-sized map** when the upper bound is known:
    ```go
    // ❌ Triggers multiple array re-allocations and GC copying:
    var results []Item
    for _, id := range ids { results = append(results, fetch(id)) }

    // ✅ Pre-allocate capacity: exactly 1 allocation
    results := make([]Item, 0, len(ids))
    for _, id := range ids { results = append(results, fetch(id)) }
    ```
- **High-Performance Structured Logging (`log/slog` in Go 1.21+)**:
  - Prefer Go 1.21+ standard library `log/slog` over third-party loggers or unformatted `log.Printf`.
  - Use strongly-typed attribute constructors (`slog.String()`, `slog.Int64()`, `slog.Duration()`, `slog.Time()`) instead of loosely-typed key-value pairs (`slog.Any()`). Typed attributes avoid reflection and runtime heap allocations on hot execution paths:
    ```go
    // ✅ Zero-allocation typed attributes:
    logger.InfoContext(ctx, "order processed successfully",
        slog.String("order_id", orderID),
        slog.Int64("latency_ms", elapsed.Milliseconds()),
    )
    ```
- **Nil Interface Conversion Trap**:
  - An interface containing a typed `nil` pointer is NOT `nil`:
    ```go
    var buf *bytes.Buffer = nil
    var r io.Reader = buf
    if r != nil {
        // Evaluates to TRUE! r contains type information (*bytes.Buffer), causing nil dereference panics
    }
    ```
  - Always return an untyped `nil` explicitly when returning errors or interfaces:
    ```go
    func getReader() io.Reader {
        var buf *bytes.Buffer
        if condition {
            buf = bytes.NewBuffer(data)
            return buf
        }
        return nil // ✅ Explicit untyped nil
    }
    ```
- **Zero-Allocation String/Byte Conversions (Go 1.20+)**:
  - In extreme high-throughput network or message parsing, avoid allocating a new string when converting read-only byte slices using `unsafe.String(unsafe.SliceData(b), len(b))` with strict lifetime verification. When returning data outside the caller's stack lifecycle, always copy or use `strings.Clone(s)` to prevent pinning large temporary network buffers.

## 8. Singleflight Stampede Suppression, Context Loop Checks & Profiling Security
- **Singleflight Duplicate Call Suppression**:
  - In high-throughput services, simultaneous cache misses for the same key trigger a thundering herd on primary databases.
  - Use `golang.org/x/sync/singleflight` to coalesce duplicate in-flight requests into a single execution:
    ```go
    var requestGroup singleflight.Group

    func FetchUserData(ctx context.Context, userID string) (*UserData, error) {
        val, err, _ := requestGroup.Do(userID, func() (any, error) {
            return queryDatabaseForUser(ctx, userID)
        })
        if err != nil {
            return nil, err
        }
        return val.(*UserData), nil
    }
    ```
- **Context Cancellation Checks in Iterative Batch Loops**:
  - In long-running batch processors, ETL loops, or queue consumers, ALWAYS check `ctx.Err()` at the beginning of each iteration:
    ```go
    for _, item := range batch {
        if err := ctx.Err(); err != nil {
            return fmt.Errorf("batch execution aborted: %w", err)
        }
        if err := process(ctx, item); err != nil {
            return err
        }
    }
    ```
  - Without this check, a canceled request continues burning CPU and database I/O across thousands of remaining items.
- **Pprof Endpoint Security Invariant**:
  - ❌ **NEVER register `net/http/pprof` directly on the public default HTTP mux (`http.DefaultServeMux`)**:
    - Importing `_ "net/http/pprof"` automatically registers profiling endpoints (`/debug/pprof/`) on `http.DefaultServeMux`, exposing heap dumps, goroutine stack traces, and environment tokens to the internet.
  - Expose pprof exclusively on an unexposed, internal loopback listener (e.g. `127.0.0.1:6060` or Kubernetes internal management port) protected by mTLS or authentication.
- **Escape Analysis & Stack vs Heap Semantics**:
  - Avoid returning pointers for small structs ($\le 64$ bytes with no internal pointers, e.g. `Point{X, Y int}`). Returning pointers forces stack escape to the heap, generating needless GC sweep pressure.
  - Run `go build -gcflags="-m"` during performance optimization to prove variables stay on the stack.

## 9. sync.Pool Memory Discipline, Channel Ownership & Atomic Swaps
- **`sync.Pool` Memory Retention & Capacity Ceiling**:
  - `sync.Pool` eliminates allocation overhead for high-frequency short-lived objects (e.g. byte buffers, JSON decoders).
  - ❌ **NEVER return byte slices to `sync.Pool` without resetting length**:
    ```go
    var bufPool = sync.Pool{
        New: func() any {
            return bytes.NewBuffer(make([]byte, 0, 4096))
        },
    }

    buf := bufPool.Get().(*bytes.Buffer)
    buf.Reset() // MANDATORY: reset buffer before use or before Put
    defer func() {
        // CEILING GUARD: discard abnormally large buffers (>64KB) to avoid memory pinning
        if buf.Cap() <= 65536 {
            bufPool.Put(buf)
        }
    }()
    ```
  - **Pointer Zeroing**: Before returning a struct to `sync.Pool`, zero any pointer fields (`s.Data = nil`). Retained pointers prevent GC from freeing the referenced data, causing silent heap leaks.
- **Channel Direction Typing & Ownership Principle**:
  - ALWAYS specify channel directions in function signatures (`<-chan Task` for read-only consumers, `chan<- Task` for write-only producers) to catch architectural direction errors at compile time.
  - **The Channel Ownership Rule**: The goroutine that writes to/creates a channel OWNS it. The owner is the SOLE entity permitted to call `close()`.
  - ❌ **NEVER close a channel from the receiver side, and NEVER close a channel with multiple concurrent writers**:
    - Writing to or closing a closed channel causes an immediate unrecoverable `panic: send on closed channel`.
    - For multiple senders, coordinate shutdown via `context.Context` cancellation or a dedicated `sync.Once` wrapper.
- **Mutex Copy Prevention & `atomic.Pointer[T]` (Go 1.19+)**:
  - Structs containing `sync.Mutex` or `sync.RWMutex` MUST ALWAYS be passed by pointer (`*Server`), never by value (`Server`). Passing by value creates a shallow copy of the internal mutex lock state, breaking mutual exclusion and triggering `go vet` (`copylocks`).
  - For read-heavy shared data structures that update infrequently (e.g. dynamic routing tables, feature flags, configuration snapshots), avoid lock contention using `atomic.Pointer[Config]`:
    ```go
    type ConfigManager struct {
        cfg atomic.Pointer[AppConfig]
    }

    func (m *ConfigManager) Get() *AppConfig {
        return m.cfg.Load() // Lock-free atomic pointer read
    }

    func (m *ConfigManager) Update(newCfg *AppConfig) {
        m.cfg.Store(newCfg) // Atomic pointer swap; readers see newCfg immediately
    }
    ```

## 10. Modern Error Joining (`errors.Join`), Context `AfterFunc` & Escape Optimization
- **Clean Multiple Error Aggregation (`errors.Join` in Go 1.20+)**:
  - In batch operations or multi-resource cleanup where multiple errors must be recorded without short-circuiting:
    ```go
    var errs []error
    for _, res := range resources {
        if err := res.Close(); err != nil {
            errs = append(errs, fmt.Errorf("failed closing resource %s: %w", res.ID(), err))
        }
    }
    return errors.Join(errs...)
    ```
  - Unlike custom string concatenation, `errors.Join` preserves full compatibility with `errors.Is` and `errors.As` across every joined error in the chain.
- **Context Cancellation Callbacks (`context.AfterFunc` in Go 1.21+)**:
  - Prefer `context.AfterFunc(ctx, callback)` over spawning a dedicated background goroutine that blocks on `<-ctx.Done()` just to trigger a cleanup action:
    ```go
    // ✅ Replaces wasteful "listener goroutine":
    stop := context.AfterFunc(ctx, func() {
        conn.SetReadDeadline(time.Now()) // Interrupt blocked socket read cleanly
    })
    defer stop() // Unregisters callback if work finishes before context cancellation
    ```
- **Heap Escape Analysis & Interface Boxing Defense**:
  - Boxing a concrete struct into `any` or an interface forces a heap allocation if the compiler cannot prove the value does not escape the stack:
    ```go
    // ❌ Causes heap allocation per call:
    func logMetric(val any) { ... }

    // ✅ Zero allocation: pass concrete types or generics
    func logMetric[T constraints.Integer | constraints.Float](val T) { ... }
    ```
  - Run `go build -gcflags="-m"` to inspect compiler escape decisions. Ensure critical inner-loop types (state machines, coordinates, parsers) stay allocated on the goroutine stack.
- **Slice Growth & Amortized Pre-allocation (`growslice`)**:
  - Go's runtime reallocation doubles capacity up to 256 elements, then switches to a smooth transition towards 1.25x growth. Frequent reallocations cause memory copy overhead and GC fragmentation.
  - When batch size is known or estimable, ALWAYS pre-allocate slice capacity: `make([]T, 0, expectedCap)` or use `slices.Grow(slice, n)` (Go 1.21+). Never append repeatedly to an unallocated `nil` slice in performance-critical code paths.

## 11. Range-Over-Func Iterators (Go 1.23+), Sub-Slice Memory Leaks & Transport Connection Reuse
- **Go 1.23+ Standard Iterators (`iter.Seq` & `iter.Seq2`)**:
  - Implement custom iterators using Go 1.23's standard `iter.Seq[V]` or `iter.Seq2[K, V]` instead of returning pre-allocated slices or using channels for synchronous traversal:
    ```go
    // ✅ Zero allocation, lazy, memory-safe collection traversal:
    func (c *Container[T]) All() iter.Seq2[int, T] {
        return func(yield func(int, T) bool) {
            for i, item := range c.items {
                // MANDATORY: If yield returns false, the caller break'd out of loop; STOP immediately
                if !yield(i, item) {
                    return
                }
            }
        }
    }
    ```
  - Invariant: Always check the boolean returned by `yield()`. Continuing to yield after `false` violates the iterator contract and causes panics or undefined loop behavior.
- **Sub-Slice Backing Array Memory Retention Trap**:
  - ❌ **NEVER retain a tiny slice extracted from a massive buffer without cloning**:
    ```go
    // ❌ Memory Leak: Retains the entire 50MB backing array in heap memory forever
    func readHeader(largePayload []byte) []byte {
        return largePayload[:16] 
    }

    // ✅ Production Invariant: Clone the sub-slice so GC can collect the 50MB buffer
    func readHeader(largePayload []byte) []byte {
        return bytes.Clone(largePayload[:16]) // Go 1.20+ bytes.Clone or slices.Clone
    }
    ```
- **HTTP Transport Connection Reuse & Response Drain Invariant**:
  - ❌ **NEVER call `resp.Body.Close()` without draining remaining bytes**:
    ```go
    resp, err := client.Do(req)
    if err != nil {
        return err
    }
    // MANDATORY DRAIN: If the body is not completely read to EOF, the HTTP Transport 
    // CANNOT reuse the underlying TCP/TLS connection and terminates it with RST/FIN
    _, _ = io.Copy(io.Discard, resp.Body)
    defer resp.Body.Close()
    ```
  - **`MaxIdleConnsPerHost` Tuning**: The standard `http.DefaultTransport` sets `MaxIdleConnsPerHost = 2`. In high-throughput microservices making 1,000 req/sec to a backend, 99.8% of requests open and close raw TCP connections. Always configure a custom `&http.Transport{MaxIdleConnsPerHost: 100, MaxIdleConns: 1000, IdleConnTimeout: 90 * time.Second}`.






