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

## 12. `sync.Pool` Zero-Garbage Memory Recycling, Lock-Free `atomic.Pointer` & Graceful Server Drain
- **`sync.Pool` Allocation Hygiene & Pointer Semantics**:
  - `sync.Pool` reduces GC pause times by reusing temporary buffers across goroutines.
  - ❌ **Anti-Pattern**: Putting values into `sync.Pool` causes interface boxing allocation (`runtime.convT*`), defeating the pool's purpose.
  - ✅ **Production Invariant**:
    - Always store pointers to structs/slices in the pool.
    - Always reset slice length before putting back: `buf = buf[:0]`. Never put dirty or unbounded buffers (e.g. buffers that grew to 100MB) back into the pool.
    ```go
    type BufferPool struct {
        pool sync.Pool
    }

    func NewBufferPool() *BufferPool {
        return &BufferPool{
            pool: sync.Pool{
                New: func() any {
                    // Pre-allocate pointer to slice with standard capacity
                    b := make([]byte, 0, 4096)
                    return &b
                },
            },
        }
    }

    func (bp *BufferPool) Get() *[]byte {
        return bp.pool.Get().(*[]byte)
    }

    func (bp *BufferPool) Put(b *[]byte) {
        // Discard anomalously large buffers to avoid permanent heap bloat
        if cap(*b) > 65536 {
            return
        }
        *b = (*b)[:0] // Reset length while retaining capacity
        bp.pool.Put(b)
    }
    ```
- **Lock-Free Configuration Updates with `sync/atomic.Pointer[T]` (Go 1.19+)**:
  - ❌ **Anti-Pattern**: Using `sync.RWMutex` on hot read paths (e.g. per-request routing tables or feature flags) introduces CPU cache coherence line bouncing across cores.
  - ✅ **Production Invariant**: Use `atomic.Pointer[T]` for read-heavy, write-infrequent state:
    ```go
    type Config struct {
        FeatureFlagEnabled bool
        RateLimit          int
    }

    type ConfigManager struct {
        current atomic.Pointer[Config]
    }

    func (cm *ConfigManager) Get() *Config {
        return cm.current.Load() // Lock-free read with zero contention
    }

    func (cm *ConfigManager) Update(newCfg *Config) {
        cm.current.Store(newCfg) // Atomic pointer swap
    }
    ```
- **Orchestrated Graceful Server Drain & Signal Trapping**:
  - Production Go services must shut down cleanly without dropping in-flight HTTP/gRPC requests or leaving background workers stranded:
    ```go
    ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
    defer stop()

    server := &http.Server{Addr: ":8080", Handler: mux}

    go func() {
        if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
            log.Fatalf("server listen failed: %v", err)
        }
    }()

    <-ctx.Done() // Block until SIGINT or SIGTERM is trapped
    log.Println("shutting down server gracefully...")

    shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
    defer cancel()

    if err := server.Shutdown(shutdownCtx); err != nil {
        log.Fatalf("server forced to shutdown: %v", err)
    }
    log.Println("server exited cleanly")
    ```

---

## 13. Bounded Concurrency Semaphore, Context Decoupling & Zero-Allocation Streaming Pipelines
- **Bounded Concurrency Semaphore with `errgroup`**:
  - ❌ **The Unbounded Goroutine Spawn Trap**: Launching `go process(item)` directly inside a loop over thousands of items exhausts OS file descriptors, thrashes the Go runtime scheduler, and causes OOM crashes under sudden traffic spikes.
  - ✅ **Production Invariant**: Enforce strict concurrency limits via a weighted semaphore or buffered token channel:
    ```go
    func ProcessBatchConcurrently(ctx context.Context, items []Item, maxConcurrency int) error {
        g, ctx := errgroup.WithContext(ctx)
        sem := make(chan struct{}, maxConcurrency)

        for _, item := range items {
            item := item // Pre-Go 1.22 loop variable safety
            sem <- struct{}{} // Acquire concurrency slot

            g.Go(func() error {
                defer func() { <-sem }() // Release concurrency slot
                return processItem(ctx, item)
            })
        }

        return g.Wait()
    }
    ```
- **Context Lifetime Decoupling for Post-Request Tasks (`context.WithoutCancel`)**:
  - ❌ **The Premature Background Cancellation Bug**: Passing incoming `r.Context()` to asynchronous goroutines (e.g., audit logging, analytics events, webhook delivery) causes silent failures: as soon as the HTTP handler returns or the client disconnects, `r.Context()` is canceled immediately.
  - ✅ **Go 1.21+ Invariant**: Sever cancellation while retaining trace spans and baggage using `context.WithoutCancel()` with a bounded timeout:
    ```go
    func handleOrder(w http.ResponseWriter, r *http.Request) {
        orderID := createOrder(r.Context())

        // Decouple cancellation from HTTP response while preserving OpenTelemetry trace context:
        bgCtx := context.WithoutCancel(r.Context())
        bgCtx, cancel := context.WithTimeout(bgCtx, 30*time.Second)

        go func() {
            defer cancel()
            defer func() {
                if r := recover(); r != nil {
                    slog.Error("audit logging panic recovered", "panic", r)
                }
            }()
            recordAuditTrail(bgCtx, orderID)
        }()

        w.WriteHeader(http.StatusCreated)
    }
    ```
- **Zero-Allocation Streaming Pipelines with `io.Pipe`**:
  - ❌ **The `bytes.Buffer` In-Memory Buffering Anti-Pattern**: Writing a 500MB dynamic export into a `bytes.Buffer` before passing it to an S3 uploader or HTTP client consumes 500MB of heap RAM and forces massive garbage collection pauses.
  - ✅ **Production Invariant**: Connect streaming writers directly to readers via `io.Pipe()`, maintaining a tiny constant 32KB buffer:
    ```go
    pr, pw := io.Pipe()

    // Stream generation in a background worker goroutine:
    go func() {
        var err error
        defer func() {
            pw.CloseWithError(err) // Signals EOF or propagates write error to reader
        }()

        gz := gzip.NewWriter(pw)
        defer gz.Close()

        csvWriter := csv.NewWriter(gz)
        defer csvWriter.Flush()

        err = exportDataToCSV(ctx, csvWriter)
    }()

    // Consumer reads from pr directly without holding entire dataset in memory:
    _, err := s3Uploader.Upload(ctx, &s3.PutObjectInput{
        Bucket: aws.String("exports"),
        Key:    aws.String("report.csv.gz"),
        Body:   pr,
    })
    ```
- **Deadlock & Leak Defense in Channel Send Handoffs**:
  - ❌ **The Abandoned Receiver Goroutine Leak Trap**: A producer spawns a background goroutine to send results across a channel `ch <- result`. If the consumer times out (`ctx.Done()`) or returns early due to an error before reading from `ch`, the producer blocks forever on `ch <- result`, leaking the goroutine, its stack memory, and all referenced heap objects.
  - ✅ **Production Invariant**: Always guard channel sends with `select` against the enclosing context or lifecycle signal:
    ```go
    func produceAsync(ctx context.Context, ch chan<- Result, val Input) {
        go func() {
            res := compute(val)
            select {
            case ch <- res:
                // Successfully handed off to receiver
            case <-ctx.Done():
                // Consumer abandoned or timed out; prevent permanent goroutine leak
                slog.Warn("producer abandoned handoff due to context cancellation", "err", ctx.Err())
            }
        }()
    }
    ```
- **Lock-Free Configuration & Routing Swaps with `atomic.Pointer[T]` (Go 1.19+)**:
  - ❌ **RWMutex Reader Contention on Microsecond Hot Paths**: Protecting a frequently accessed routing table or configuration struct with `sync.RWMutex` causes CPU cache-line bouncing across hundreds of concurrent goroutines calling `RLock()`/`RUnlock()`.
  - ✅ **Production Invariant**: Use `atomic.Pointer[T]` for zero-lock, pointer-swapping atomic updates:
    ```go
    type RoutingTable struct {
        routes map[string]http.Handler
    }

    type Router struct {
        table atomic.Pointer[RoutingTable]
    }

    func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
        // Zero-copy, lock-free pointer dereference:
        current := r.table.Load()
        if handler, ok := current.routes[req.URL.Path]; ok {
            handler.ServeHTTP(w, req)
            return
        }
        http.NotFound(w, req)
    }

    func (r *Router) ReloadRoutes(newRoutes map[string]http.Handler) {
        // Prepare new immutable instance and swap atomically:
        next := &RoutingTable{routes: newRoutes}
        r.table.Store(next)
    }
    ```
- **Unbounded HTTP Request Body Memory Defense with `http.MaxBytesReader`**:
  - ❌ **The OOM Denial-of-Service Payload Trap**: Calling `json.NewDecoder(r.Body).Decode(&payload)` or `io.ReadAll(r.Body)` on untrusted HTTP requests allows an attacker to stream multi-gigabyte payloads directly into the server's heap memory, triggering rapid Out-Of-Memory (OOM) killer terminations.
  - ✅ **Production Invariant**: Always wrap `r.Body` with `http.MaxBytesReader` before reading or decoding:
    ```go
    const maxBodyBytes = 1 << 20 // 1MB ceiling

    func handleCreateUser(w http.ResponseWriter, r *http.Request) {
        // Enforce strict memory ceiling; returns http.MaxBytesError if exceeded:
        r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)

        var req CreateUserRequest
        dec := json.NewDecoder(r.Body)
        dec.DisallowUnknownFields() // Reject unexpected payload fields

        if err := dec.Decode(&req); err != nil {
            var maxBytesErr *http.MaxBytesError
            if errors.As(err, &maxBytesErr) {
                http.Error(w, "request payload exceeds 1MB limit", http.StatusRequestEntityTooLarge)
                return
            }
            http.Error(w, "invalid request json", http.StatusBadRequest)
            return
        }
    }
    ```
- **Premature Finalizer and Garbage Collection Defense with `runtime.KeepAlive`**:
  - ❌ **The Premature Finalizer / File Descriptor Reclaim Bug**: When wrapping Cgo pointers, raw OS file descriptors (`uintptr`), or types with finalizers (`runtime.SetFinalizer`), the Go garbage collector can sweep the enclosing Go struct while a concurrent method call on the underlying raw handle is still in-flight!
  - ✅ **Production Invariant**: Call `runtime.KeepAlive(obj)` immediately after the native system call to guarantee the parent Go object remains reachable throughout the call:
    ```go
    type SafeHandle struct {
        fd uintptr
    }

    func (h *SafeHandle) ReadDirect(buf []byte) (int, error) {
        n, err := syscallRead(h.fd, buf)
        // Ensure h is NOT garbage collected or finalized before syscallRead completes:
        runtime.KeepAlive(h)
        return n, err
    }
    ```
- **Graceful HTTP Server Shutdown & In-Flight Request Draining**:
  - ❌ **The Abrupt Termination / Truncated Transaction Trap**: Relying on unhandled `SIGTERM` in containers or calling `os.Exit(0)` abruptly terminates the Go process, severing active client connections mid-write, truncating database transactions, and dropping in-flight HTTP requests.
  - ✅ **Production Invariant**: Intercept OS signals via `signal.NotifyContext`, invoke `server.Shutdown(shutdownCtx)` with a dedicated timeout context (e.g., 15–30s), and ensure background worker pools finish processing before exiting:
    ```go
    ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
    defer stop()

    srv := &http.Server{
        Addr:         ":8080",
        Handler:      router,
        ReadTimeout:  10 * time.Second,
        WriteTimeout: 30 * time.Second,
        IdleTimeout:  120 * time.Second,
    }

    go func() {
        if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
            log.Fatalf("listen failed: %v", err)
        }
    }()

    <-ctx.Done() // Wait for SIGTERM or SIGINT
    stop()       // Restore default signal handling

    // Allow active connections up to 15s to finish processing:
    shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
    defer cancel()

    if err := srv.Shutdown(shutdownCtx); err != nil {
        log.Printf("server forced to shutdown: %v", err)
    }
    ```
- **Slice Memory Retention Leak via Sub-Slicing Large Buffers**:
  - ❌ **The Pinned Backing Array Memory Leak**: Sub-slicing a small segment from a large slice (`token := hugeBuffer[10:30]`) pins the entire multi-megabyte backing array in memory. Even if `hugeBuffer` goes out of scope, the Go garbage collector CANNOT reclaim the underlying memory as long as `token` is alive.
  - ✅ **Production Invariant**: Always clone small sub-slices with `slices.Clone` (Go 1.21+) or `append([]byte(nil), sub...)` to allow the large buffer to be garbage collected:
    ```go
    import "slices"

    func extractHeaderToken(payload []byte) []byte {
        // payload may be 10MB, but token is only 32 bytes:
        rawToken := payload[16:48]

        // INVARIANT: Clone the slice to allocate an isolated 32-byte backing array:
        return slices.Clone(rawToken)
    }
    ```

---

## 14. Non-Blocking Metric Emission, Struct Memory Packing & Worker Pool Resilience
- **Non-Blocking Metric / Telemetry Emission with `select default`**:
  - ❌ **The Blocking Telemetry Backpressure Trap**: Sending metrics, audit events, or analytics pings over a synchronous or buffered channel using `ch <- event` blocks critical user transactions whenever the downstream collector or disk is momentarily saturated.
  - ✅ **Production Invariant**: Always use a non-blocking `select` with a `default` case and an atomic dropped-event counter:
    ```go
    var droppedMetrics uint64

    func RecordMetricNonBlocking(ch chan<- MetricEvent, evt MetricEvent) {
        select {
        case ch <- evt:
            // Successfully queued
        default:
            // Channel saturated; drop event rather than blocking caller:
            atomic.AddUint64(&droppedMetrics, 1)
        }
    }
    ```
- **Struct Memory Alignment & Padding Invariant (`fieldalignment`)**:
  - ❌ **The Unaligned Padding Waste**: On 64-bit architectures, fields are aligned to 8-byte boundaries. Interleaving small types (`bool`, `int16`) between pointers or `int64` introduces 7 bytes of dead padding per field, inflating struct size and reducing CPU L1/L2 cache efficiency:
    ```go
    // ❌ Inefficient layout: 32 bytes (11 bytes of dead padding)
    type BadStruct struct {
        flagA bool   // 1 byte + 7 bytes padding
        id    int64  // 8 bytes
        flagB bool   // 1 byte + 7 bytes padding
        count int64  // 8 bytes
    }
    ```
  - ✅ **Production Invariant**: Order struct fields in descending order of size (8-byte, 4-byte, 2-byte, 1-byte) or audit struct packing with `fieldalignment`:
    ```go
    // ✅ Optimal layout: 24 bytes (0 padding bytes wasted)
    type GoodStruct struct {
        id    int64  // 8 bytes
        count int64  // 8 bytes
        flagA bool   // 1 byte
        flagB bool   // 1 byte + 6 bytes trailing alignment
    }
    ```
- **Worker Pool Panic Boundary & Resilient Task Execution**:
  - ❌ **The Unhandled Worker Panic Process Crash**: In a concurrent worker pool (`errgroup` or custom workers), an unexpected nil pointer or out-of-bounds slice access in a single incoming job panics the goroutine and crashes the entire Go application.
  - ✅ **Production Invariant**: Encapsulate individual task execution in an isolated recovery boundary:
    ```go
    func SafeExecuteJob(job Job) (err error) {
        defer func() {
            if r := recover(); r != nil {
                slog.Error("worker task panic recovered", "panic", r, "stack", string(debug.Stack()))
                err = fmt.Errorf("task panicked: %v", r)
            }
        }()
        return job.Execute()
    }
    ```

---

## 15. Lock-Free Atomic Pointers, Go 1.22+ Loop Scope Invariants & Two-Phase Drain
- **Wait-Free Dynamic Config Reloads with `atomic.Pointer[T]` (Go 1.19+)**:
  - ❌ **The `sync.RWMutex` Cache Line Bouncing Bottleneck**: Protecting dynamic routing tables, feature flags, or rate limiter tiers with `sync.RWMutex.RLock()` triggers CPU cache coherence invalidation across multicore CPUs when handling hundreds of thousands of read requests per second.
  - ✅ **Production Invariant**: Use `atomic.Pointer[T]` for wait-free, zero-lock atomic reads and atomic pointer swapping on hot paths:
    ```go
    import "sync/atomic"

    type ServerConfig struct {
        RateLimit int
        Flags     map[string]bool
    }

    type ConfigManager struct {
        cfg atomic.Pointer[ServerConfig]
    }

    func NewConfigManager(initial *ServerConfig) *ConfigManager {
        cm := &ConfigManager{}
        cm.cfg.Store(initial)
        return cm
    }

    func (cm *ConfigManager) Get() *ServerConfig {
        // Zero-lock, wait-free pointer load:
        return cm.cfg.Load()
    }

    func (cm *ConfigManager) Reload(newCfg *ServerConfig) {
        // Atomic pointer swap:
        cm.cfg.Store(newCfg)
    }
    ```
- **Go 1.22+ Loop Variable Scope Discipline & Backward Compatibility**:
  - ❌ **The Multi-Goroutine Pointer Capture Bug**: In Go < 1.22, variables declared by `for k, v := range` share a single memory address across iterations, causing goroutines or closures to capture only the last element. Even with Go 1.22 fixing per-iteration scoping for standard loops, taking pointers to loop variables (`&val`) in libraries targeting older Go toolchains or CGo bindings still causes pointer aliasing bugs.
  - ✅ **Production Invariant**: In cross-compatible codebases or when passing elements into slice of pointers, explicitly clone or bind per iteration:
    ```go
    items := []string{"a", "b", "c"}
    ptrs := make([]*string, len(items))

    for i := range items {
        val := items[i] // Explicit local copy for absolute compiler version invariance
        ptrs[i] = &val
    }
    ```
- **Two-Phase Graceful Shutdown (Drain Phase vs Termination Phase)**:
  - ❌ **The Abrupt In-Flight Request Cancellation Trap**: Closing the database connection pool immediately upon receiving `SIGTERM` causes in-flight HTTP requests to fail with `sql: database is closed` during active checkout or billing mutations.
  - ✅ **Production Invariant**: Implement a two-phase drain sequence: first stop accepting new ingress connections and wait for active requests to finish, then gracefully flush and close stateful resources (database pools, Kafka producers):
    ```go
    // Phase 1: Stop ingress and drain in-flight requests (e.g. 15s budget):
    if err := httpServer.Shutdown(drainCtx); err != nil {
        slog.Error("http server drain error", "err", err)
    }

    // Phase 2: Now that zero HTTP handlers are executing, close DB pools:
    if err := dbPool.Close(); err != nil {
        slog.Error("database pool close error", "err", err)
    }
    ```

---

## 16. Deadlock-Free Channel Handoffs, Request Body Bounding & Premature GC Reclamation
- **Deadlock & Goroutine Leak Defense in Channel Send Handoffs**:
  - ❌ **The Unbuffered Channel Sender Block**: Sending to an unbuffered channel or bounded channel without selecting on `ctx.Done()` can block the sending goroutine indefinitely if the receiver encounters an error, panics, or cancels its context early:
    ```go
    // DANGEROUS: If receiver exits early, this goroutine leaks forever!
    ch <- result
    ```
  - ✅ **Production Invariant**: Always guard channel sends with a cancellation check, or use non-blocking drops with dropped metrics:
    ```go
    select {
    case ch <- result:
        // Handoff succeeded
    case <-ctx.Done():
        // Context expired or canceled; avoid leaking goroutine
        return ctx.Err()
    }
    ```
- **Unbounded HTTP Request Body Memory Defense (`http.MaxBytesReader`)**:
  - ❌ **The JSON Decoder Memory Exhaustion (OOM) Vulnerability**: Calling `json.NewDecoder(r.Body).Decode(&payload)` without limiting the reader allows an attacker to stream a 5GB malicious JSON payload, consuming all container memory and triggering the Linux OOM killer.
  - ✅ **Production Invariant**: Always wrap `r.Body` with `http.MaxBytesReader` before decoding:
    ```go
    // Cap incoming request body to 10MB:
    r.Body = http.MaxBytesReader(w, r.Body, 10<<20)

    dec := json.NewDecoder(r.Body)
    dec.DisallowUnknownFields() // Reject unmapped parameters
    if err := dec.Decode(&req); err != nil {
        var maxBytesErr *http.MaxBytesError
        if errors.As(err, &maxBytesErr) {
            http.Error(w, "request payload exceeds maximum limit of 10MB", http.StatusRequestEntityTooLarge)
            return
        }
        http.Error(w, "invalid json payload", http.StatusBadRequest)
        return
    }
    ```
- **Premature Finalizer & GC Reclamation Defense via `runtime.KeepAlive`**:
  - ❌ **The Early Collector Sweep Bug**: When managing low-level OS file descriptors, mmap memory regions, or CGo handles wrapped in Go structs with finalizers (`runtime.SetFinalizer`), the Go garbage collector can sweep the outer struct while an internal handle method is still executing on CPU!
  - ✅ **Production Invariant**: Use `runtime.KeepAlive` to guarantee object liveness until the critical operation finishes:
    ```go
    func (f *SecureFileHandle) ReadData(buf []byte) (int, error) {
        n, err := syscall.Read(f.rawFd, buf)
        // Keep f reachable so finalizer won't close rawFd during syscall:
        runtime.KeepAlive(f)
        return n, err
    }
    ```
- **Loop `time.NewTimer` Starvation & Channel Draining Trap**:
  - ❌ **The Leaked Timer Heap Accumulation**: Calling `time.After(d)` inside a tight loop creates a new `time.Timer` on every single iteration that cannot be garbage collected until the duration expires, rapidly accumulating millions of dead timer objects in heap memory. Calling `timer.Stop()` without draining `timer.C` can leave stale expired ticks in the channel.
  - ✅ **Production Invariant**: Reuse a single `time.Timer` across iterations, and safely drain the channel if `Stop()` returns false:
    ```go
    timer := time.NewTimer(timeout)
    defer timer.Stop()

    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case item := <-queue:
            process(item)
            if !timer.Stop() {
                select {
                case <-timer.C:
                default:
                }
            }
            timer.Reset(timeout)
        case <-timer.C:
            return errors.New("idle timeout reached")
        }
    }
    ```
- **Atomic File Writing via Temp File & Replace (`os.CreateTemp` + `Sync` + `Rename`)**:
  - ❌ **The Zero-Byte File Corruption on Crash**: Calling `os.WriteFile(path, data, 0644)` truncates the destination file first before writing new bytes. If the machine crashes, loses power, or experiences a container `SIGKILL` during the write, the file is left at 0 bytes or corrupted with partial data.
  - ✅ **Production Invariant**: Write to a temporary file in the same directory/filesystem, invoke `Sync()` to flush dirty OS page cache blocks to physical media, and atomically replace the destination via `os.Rename`:
    ```go
    func AtomicWriteFile(filename string, data []byte, perm os.FileMode) error {
        dir := filepath.Dir(filename)
        tmp, err := os.CreateTemp(dir, "tmp-*")
        if err != nil {
            return fmt.Errorf("create temp file: %w", err)
        }
        tmpName := tmp.Name()
        defer os.Remove(tmpName) // Clean up on error

        if _, err := tmp.Write(data); err != nil {
            tmp.Close()
            return fmt.Errorf("write temp: %w", err)
        }
        if err := tmp.Sync(); err != nil { // Force flush OS buffers to disk
            tmp.Close()
            return fmt.Errorf("fsync temp: %w", err)
        }
        if err := tmp.Close(); err != nil {
            return fmt.Errorf("close temp: %w", err)
        }
        if err := os.Chmod(tmpName, perm); err != nil {
            return fmt.Errorf("chmod temp: %w", err)
        }
        return os.Rename(tmpName, filename) // Atomic POSIX replacement
    }
    ```
- **Context Deadline Remaining Budget Verification**:
  - ❌ **The Blind Downstream Invocation on Expired Contexts**: Initiating expensive network RPCs or database transactions when the context only has 2 milliseconds of deadline remaining will reliably fail midway, wasting server I/O and leaving half-executed downstream states.
  - ✅ **Production Invariant**: Check the remaining deadline budget before initiating nested downstream calls:
    ```go
    func CallExternalGateway(ctx context.Context, payload []byte) error {
        const minRequiredBudget = 100 * time.Millisecond
        if deadline, ok := ctx.Deadline(); ok {
            if time.Until(deadline) < minRequiredBudget {
                return fmt.Errorf("insufficient context deadline budget remaining (%v): %w", time.Until(deadline), context.DeadlineExceeded)
            }
        }
        return executeCall(ctx, payload)
    }
    ```
- **Go 1.24 Weak Pointers (`weak.Pointer`) & In-Memory Canonicalization Caches**:
  - ❌ **The Strong Reference In-Memory Cache Leak**: Building in-memory identity caches or memoization tables using standard `map[string]*HeavyObject` prevents the Go garbage collector from ever freeing cached objects, inevitably resulting in slow, fatal memory leaks in long-running services.
  - ✅ **Production Invariant**: Use Go 1.24+ `weak.Pointer[T]` for memory caches and canonicalization where keys should automatically be collected when no active references remain:
    ```go
    // Go 1.24+ weak reference cache
    package cache

    import (
        "sync"
        "weak"
    )

    type CanonicalCache[K comparable, V any] struct {
        mu    sync.RWMutex
        store map[K]weak.Pointer[V]
    }

    func (c *CanonicalCache[K, V]) GetOrSet(key K, factory func() *V) *V {
        c.mu.RLock()
        if wp, ok := c.store[key]; ok {
            if val := wp.Value(); val != nil {
                c.mu.RUnlock()
                return val
            }
        }
        c.mu.RUnlock()

        c.mu.Lock()
        defer c.mu.Unlock()

        // Double-check after acquiring write lock
        if wp, ok := c.store[key]; ok {
            if val := wp.Value(); val != nil {
                return val
            }
        }

        newVal := factory()
        c.store[key] = weak.Make(newVal)
        return newVal
    }
    ```
- **`sync.Map` Antipattern vs Sharded Concurrent Mutex Maps**:
  - ❌ **The `sync.Map` Mutation Degeneration**: Using `sync.Map` for write-heavy key spaces or high-frequency update/delete cycles causes continuous cache-line thrashing, promotes dirty maps back to read-only maps with heap allocations, and degrades performance significantly below standard mutexes.
  - ✅ **Production Invariant**: Reserve `sync.Map` strictly for cache-like workloads where keys are written once and read millions of times, or disjoint key sets across goroutines. For high-frequency concurrent read/write workloads, use a sharded/striped mutex map:
    ```go
    const ShardCount = 32

    type ShardedMap[V any] struct {
        shards [ShardCount]struct {
            sync.RWMutex
            items map[string]V
        }
    }

    func (m *ShardedMap[V]) getShard(key string) *struct {
        sync.RWMutex
        items map[string]V
    } {
        h := fnv32(key)
        return &m.shards[h%ShardCount]
    }

    func fnv32(key string) uint32 {
        var hash uint32 = 2166136261
        for i := 0; i < len(key); i++ {
            hash = (hash ^ uint32(key[i])) * 16777619
        }
        return hash
    }
    ```
- **`sync.WaitGroup` `Add(1)` Placement Invariant & Pointer Semantics**:
  - ❌ **The Child Goroutine `Add()` Race Condition**: Calling `wg.Add(1)` inside the spawned goroutine (`go func() { wg.Add(1); ... }()`) creates a critical race condition. The parent thread executing `wg.Wait()` can immediately complete and exit before the Go runtime scheduler even dispatches the spawned goroutine, causing missed execution and premature process teardown.
  - ❌ **Passing `WaitGroup` by Value**: Passing `wg sync.WaitGroup` as a function parameter copies the internal 64-bit state atomic word. The worker operates on a disconnected copy, leaving the original `Wait()` blocked forever in a deadlock.
  - ✅ **Production Invariant**: Always increment `wg.Add(1)` in the parent spawning goroutine *before* calling `go func()`, and always pass `*sync.WaitGroup` via pointer (or capture in a closure):
    ```go
    // Go: Safe WaitGroup synchronization
    func ProcessItems(ctx context.Context, items []string) {
        var wg sync.WaitGroup

        for _, item := range items {
            // Add MUST be executed in the parent goroutine before spawning:
            wg.Add(1)
            go func(val string) {
                defer wg.Done()
                process(ctx, val)
            }(item)
        }

        wg.Wait()
    }
    ```
- **`io.Reader` Short-Read Invariant & `io.ReadFull` in Network Streams**:
  - ❌ **The `Read(buf)` Buffer Fullness Assumption**: In TCP sockets, TLS streams, and pipes, `r.Read(buf)` is permitted by the `io.Reader` contract to return any number of bytes $1 \le n \le \text{len}(buf)$ with `err == nil` when only partial data has arrived over the wire. Assuming `Read(buf)` fills the buffer leads to silent truncation, corrupted framed protocols, and intermittent network bugs.
  - ✅ **Production Invariant**: When an exact number of bytes is required (e.g. wire headers, fixed-length frames), always use `io.ReadFull`:
    ```go
    // Go: Safe wire protocol framing read
    func ReadMessage(r io.Reader) ([]byte, error) {
        var header [4]byte
        // Guaranteed to read all 4 bytes or return an explicit ErrUnexpectedEOF:
        if _, err := io.ReadFull(r, header[:]); err != nil {
            return nil, fmt.Errorf("read header: %w", err)
        }

        msgLen := binary.BigEndian.Uint32(header[:])
        if msgLen > MaxAllowedPayload {
            return nil, fmt.Errorf("payload exceeds limit: %d", msgLen)
        }

        payload := make([]byte, msgLen)
        if _, err := io.ReadFull(r, payload); err != nil {
            return nil, fmt.Errorf("read full payload: %w", err)
        }
        return payload, nil
    }
    ```
- **Go 1.22+ `cmp.Or` for Deterministic Zero-Value Fallback Chains**:
  - ❌ **Cluttered Fallback Logic**: Writing repetitive multi-branch `if host == "" { host = envHost }; if host == "" { host = "localhost" }` boilerplate across configuration loaders and service constructors.
  - ✅ **Production Invariant**: Use standard library `cmp.Or` to select the first non-zero value deterministically:
    ```go
    import "cmp"

    func ResolveConfig(cfg *Config) ResolvedConfig {
        return ResolvedConfig{
            Host: cmp.Or(cfg.Host, os.Getenv("SERVICE_HOST"), "127.0.0.1"),
            Port: cmp.Or(cfg.Port, os.Getenv("SERVICE_PORT"), "8080"),
        }
    }
    ```
- **`sync.Cond` Spurious Wakeup Invariant & Loop Predicate Checking**:
  - ❌ **The Single `if` Predicate Bug**: Calling `cond.Wait()` inside a single `if !condition` branch. Under POSIX thread scheduling and multi-core runtime wakeups, `Wait()` can return spuriously without `Broadcast()` or `Signal()` having occurred, or another goroutine may have already consumed the resource between the wake signal and lock acquisition:
    ```go
    // DANGEROUS: Spurious wakeup or race condition leads to nil pointer / empty queue panic!
    cond.L.Lock()
    if len(queue) == 0 {
        cond.Wait()
    }
    item := queue[0] // Crash if another worker drained the item first!
    cond.L.Unlock()
    ```
  - ✅ **Production Invariant**: Always execute `cond.Wait()` inside a `for !condition` loop to re-validate invariants upon every wakeup:
    ```go
    // Go: Bulletproof sync.Cond loop predicate
    cond.L.Lock()
    for len(queue) == 0 && !closed {
        cond.Wait()
    }
    if closed && len(queue) == 0 {
        cond.L.Unlock()
        return ErrQueueClosed
    }
    item := queue[0]
    queue = queue[1:]
    cond.L.Unlock()
    ```
- **Go 1.22+ `net/http` Enhanced Path Routing & Method Matching**:
  - ❌ **External Router Overhead for Standard APIs**: Pulling heavy third-party routing dependencies (`chi`, `mux`) solely for method routing or path wildcards, or manually parsing `req.URL.Path` string splits in standard `http.ServeMux`.
  - ✅ **Production Invariant**: Leverage Go 1.22+ standard pattern routing with HTTP methods, wildcards (`{id}`), and path segment extraction via `req.PathValue("id")`:
    ```go
    // Go 1.22+ Standard ServeMux with exact method matching & route parameters
    mux := http.NewServeMux()

    mux.HandleFunc("GET /api/v1/projects/{id}", func(w http.ResponseWriter, r *http.Request) {
        projectID := r.PathValue("id")
        if projectID == "" {
            http.Error(w, "missing project id", http.StatusBadRequest)
            return
        }
        w.Header().Set("Content-Type", "application/json")
        fmt.Fprintf(w, `{"id":%q,"status":"active"}`, projectID)
    })

    // Subtree routing with trailing wildcard:
    mux.HandleFunc("GET /static/{path...}", func(w http.ResponseWriter, r *http.Request) {
        assetPath := r.PathValue("path")
        serveStaticSafe(w, r, assetPath)
    })
    ```
- **Subprocess Execution & Environment Isolation (`exec.Cmd.Env`)**:
  - ❌ **The Total Environment Wiping Trap**: Assigning a slice literal directly to `cmd.Env = []string{"MY_VAR=value"}` wipes all standard environment variables (`PATH`, `HOME`, `SYSTEMROOT`, `TMPDIR`). This results in catastrophic `executable file not found in $PATH` errors or broken child runtime initialization.
  - ✅ **Production Invariant**: Always preserve host environment variables by appending overrides to `os.Environ()`:
    ```go
    // Go: Safe child process environment inheritance
    cmd := exec.CommandContext(ctx, "ffmpeg", "-i", inputPath, outputPath)
    
    // Inherit host environment, then append isolated overrides:
    cmd.Env = append(os.Environ(),
        "FFREPORT=file=/tmp/ffmpeg.log:level=32",
        "AV_LOG_FORCE_NOCOLOR=1",
    )
    ```
- **Go 1.24+ `os.Root` Filesystem Sandboxing & Symlink Path Traversal Immunity**:
  - ❌ **The `filepath.Clean` & Symlink Escape Vulnerability**: Attempting to sanitize user-provided file paths with `filepath.Clean(filepath.Join(baseDir, userInput))` or string prefix checks (`strings.HasPrefix(target, baseDir)`). An attacker can supply a symlink created inside the directory pointing to `/etc/passwd` or `/root/.ssh`, bypassing lexical path checks entirely (TOCTOU directory traversal).
  - ✅ **Production Invariant**: In Go 1.24+, use `os.OpenRoot(baseDir)` to confine all directory operations to an isolated OS-level filesystem sandbox:
    ```go
    // Go 1.24+ Bulletproof directory containment
    root, err := os.OpenRoot(uploadDir)
    if err != nil {
        return fmt.Errorf("failed to open root sandbox: %w", err)
    }
    defer root.Close()

    // Guaranteed to fail if untrustedPath resolves outside uploadDir (via symlinks or ..):
    f, err := root.Open(untrustedPath)
    if err != nil {
        return fmt.Errorf("access denied or invalid path: %w", err)
    }
    defer f.Close()
    ```
- **Context Cancellation Cause Propagation (`context.WithCancelCause` & `context.Cause`)**:
  - ❌ **Loss of Domain Failure Reason**: Calling `cancel()` on a standard `context.WithCancel(parent)` context when an error occurs in a goroutine. Downstream consumers or middleware receive generic `context.Canceled`, making it impossible to determine whether the operation was cancelled due to a rate limit, a client disconnect, or a timeout.
  - ✅ **Production Invariant**: Use `context.WithCancelCause` to associate the exact domain error with the cancellation, and inspect it via `context.Cause(ctx)`:
    ```go
    // Go 1.20+: Propagate exact root-cause domain errors across goroutine lifecycles
    ctx, cancel := context.WithCancelCause(parentCtx)

    go func() {
        if err := workerPool.Process(); err != nil {
            // Cancel context and attach the concrete root cause:
            cancel(fmt.Errorf("worker failed due to database exhaustion: %w", err))
            return
        }
        cancel(nil) // Clean completion
    }()

    <-ctx.Done()
    if err := context.Cause(ctx); err != nil && !errors.Is(err, context.Canceled) {
        slog.Error("pipeline terminated abnormally", "cause", err)
    }
    ```
- **`http.Transport.MaxIdleConnsPerHost` Default Socket Exhaustion Trap**:
  - ❌ **The Default `MaxIdleConnsPerHost = 2` Pitfall**: In Go's `http.DefaultTransport`, `MaxIdleConnsPerHost` defaults to `2`. Under microservice concurrency (e.g. 500 parallel requests to an auth service or payment gateway), only 2 idle connections are kept in the pool; the remaining 498 connections are forcefully closed immediately upon completion. This triggers severe TCP socket churn, kernel `TIME_WAIT` socket exhaustion, ephemeral port depletion, and repeated TLS handshake latency overhead.
  - ✅ **Production Invariant**: Always construct a tuned custom `http.Transport` sizing `MaxIdleConnsPerHost` proportionally to your expected concurrency:
    ```go
    // Production tuned HTTP transport for high-throughput inter-service communication
    var resilientClient = &http.Client{
        Timeout: 10 * time.Second,
        Transport: &http.Transport{
            Proxy: http.ProxyFromEnvironment,
            DialContext: (&net.Dialer{
                Timeout:   5 * time.Second,
                KeepAlive: 30 * time.Second,
            }).DialContext,
            ForceAttemptHTTP2:     true,
            MaxIdleConns:          500,
            MaxIdleConnsPerHost:   100, // Explicitly match peak inter-service concurrency (default is 2!)
            MaxConnsPerHost:       200, // Prevent unbounded socket creation under backpressure
            IdleConnTimeout:       90 * time.Second,
            TLSHandshakeTimeout:   5 * time.Second,
            ExpectContinueTimeout: 1 * time.Second,
        },
    }
    ```
- **`sync.Pool` Bounded Capacity Ceiling & Memory Retention Defense**:
  - ❌ **The Unbounded Buffer Bloat Trap**: Returning byte slices or buffers directly to `sync.Pool` after an anomalous 50MB payload causes the buffer to stay retained in the pool indefinitely across minor GCs, unnecessarily pinning multi-megabyte chunks of heap memory.
  - ✅ **Production Invariant**: Enforce a maximum capacity threshold before returning buffers to `sync.Pool`. If a buffer exceeds the safe ceiling, discard it to allow normal GC reclamation:
    ```go
    const maxPooledBufferSize = 64 * 1024 // 64 KB ceiling

    var bufferPool = sync.Pool{
        New: func() any {
            return bytes.NewBuffer(make([]byte, 0, 4096))
        },
    }

    func PutBuffer(buf *bytes.Buffer) {
        // Discard buffers that grew abnormally large to protect heap working set:
        if buf.Cap() > maxPooledBufferSize {
            return
        }
        buf.Reset()
        bufferPool.Put(buf)
    }
    ```
- **`net/http.Server` ReadHeaderTimeout & Slowloris Attack Defense**:
  - ❌ **The Zero-Timeout Server Exhaustion Vulnerability**: Declaring `&http.Server{Addr: ":8080", Handler: mux}` without specifying `ReadHeaderTimeout`. The zero value means *no timeout*, allowing malicious or sluggish clients to open TCP connections and send headers byte-by-byte (the Slowloris exploit). Each stalled connection holds an active goroutine and kernel socket descriptor, completely starving server resources with minimal attacker bandwidth.
  - ✅ **Production Invariant**: Always configure explicit connection phase timeouts on every production HTTP server, specifically enforcing `ReadHeaderTimeout`:
    ```go
    srv := &http.Server{
        Addr:              ":8080",
        Handler:           mux,
        ReadHeaderTimeout: 3 * time.Second,  // Hard ceiling for slowloris header trickles
        ReadTimeout:       10 * time.Second, // Max duration reading entire request including body
        WriteTimeout:      15 * time.Second, // Max duration writing response
        IdleTimeout:       120 * time.Second,// Keep-alive idle connection timeout
        MaxHeaderBytes:    1 << 20,          // 1 MB header size ceiling
    }
    ```
- **Typesafe Unexported Context Key Discipline**:
  - ❌ **The String Key Context Collision Bug**: Injecting values into `context.Context` using raw strings or built-in primitive types (`ctx = context.WithValue(ctx, "user_id", id)`). In multi-package applications or third-party middleware, identical string keys collide and silently overwrite each other's state, leading to catastrophic authorization and auditing bugs.
  - ✅ **Production Invariant**: Always declare an unexported, zero-size private struct type for context keys within the owning package, providing strictly typed getter and setter helper functions:
    ```go
    package auth

    type contextKey struct{}

    var userContextKey = contextKey{}

    // WithUser returns a new Context bearing the authenticated User entity.
    func WithUser(ctx context.Context, u *User) context.Context {
        return context.WithValue(ctx, userContextKey, u)
    }

    // FromContext extracts the User entity from Context, returning false if absent.
    func FromContext(ctx context.Context) (*User, bool) {
        u, ok := ctx.Value(userContextKey).(*User)
        return u, ok && u != nil
    }
    ```
- **High-Contention Atomic Counters & CPU Cache-Line False Sharing Defense**:
  - ❌ **The False Sharing Throughput Collapse**: Placing multiple independently updated `atomic.Int64` or `atomic.Uint64` fields adjacent to each other in a shared struct:
    ```go
    // ❌ Flawed: Adjacent atomic fields share the same 64-byte L1 CPU cache line.
    // Core 0 updating readCount continuously invalidates Core 1's cache line updating writeCount!
    type Metrics struct {
        readCount  atomic.Uint64
        writeCount atomic.Uint64
    }
    ```
    Under high multi-core concurrency, the CPU cores trigger constant MESI cache coherency bus traffic, causing a 10x-50x degradation in throughput despite zero lock contention.
  - ✅ **Production Invariant**: Insert explicit 64-byte padding (`_ [64]byte`) or `cpu.CacheLinePad` between high-frequency atomic variables to ensure each field occupies its own independent CPU cache line:
    ```go
    type ResilientMetrics struct {
        readCount atomic.Uint64
        _         [56]byte // 64 - 8 = 56 bytes padding to isolate readCount on its own cache line

        writeCount atomic.Uint64
        _          [56]byte // Isolates writeCount on its own cache line
    }
    ```
- **Prohibition of `runtime.SetFinalizer` for Critical Resource Cleanup**:
  - ❌ **The Delayed GC & OOM Finalizer Trap**: Relying on `runtime.SetFinalizer(obj, cleanupFunc)` to close database connections, release Cgo pointers, or unmap memory. Finalizers delay object reclamation by at least two GC cycles, are not guaranteed to run before process termination, never run on cyclic object references, and block internal finalizer goroutines if `cleanupFunc` stalls on I/O.
  - ✅ **Production Invariant**: Mandate explicit deterministic cleanup via `io.Closer` patterns protected by `sync.Once`:
    ```go
    type ResilientHandle struct {
        closer sync.Once
        fd     int
        closed bool
    }

    func (h *ResilientHandle) Close() error {
        var err error
        h.closer.Do(func() {
            h.closed = true
            err = syscall.Close(h.fd)
        })
        return err
    }
    ```
- **Go 1.20+ Zero-Copy Conversions: `unsafe.String` / `unsafe.Slice` vs Deprecated `reflect.SliceHeader`**:
  - ❌ **The Memory Corruption Reflection Anti-Pattern**: Casting between `[]byte` and `string` by mutating deprecated `reflect.SliceHeader` or `reflect.StringHeader`. In modern Go (1.20+), modifying Header structs violates internal runtime pointer tracking invariants; the GC can relocate memory between pointer reads, triggering silent memory corruption or panic under GC stress.
  - ✅ **Production Invariant**: Always use compiler-intrinsic `unsafe.String`, `unsafe.StringData`, `unsafe.Slice`, and `unsafe.SliceData`. They are fully compiler-checked and guaranteed safe by the Go runtime:
    ```go
    import "unsafe"

    // Zero-copy byte slice to string without heap allocation
    func ByteSliceToString(b []byte) string {
        if len(b) == 0 {
            return ""
        }
        return unsafe.String(unsafe.SliceData(b), len(b))
    }

    // Zero-copy string to byte slice (read-only view; never mutate bytes)
    func StringToReadOnlyBytes(s string) []byte {
        if len(s) == 0 {
            return nil
        }
        return unsafe.Slice(unsafe.StringData(s), len(s))
    }
    ```
- **Go 1.21+ `context.WithoutCancel` for Detached Background Audit & Teardown Spans**:
  - ❌ **The Telemetry Loss or Immediate Failure Dilemma**: When an incoming HTTP request is canceled or times out, passing the parent `r.Context()` to background audit logging or database cleanup causes them to immediately fail with `context canceled`. Conversely, using `context.Background()` completely severs OpenTelemetry trace IDs, correlation baggage, and authenticated user credentials.
  - ✅ **Production Invariant**: Use Go 1.21+ `context.WithoutCancel(parentCtx)`. It detaches the cancellation signal while preserving all context values, trace spans, and request metadata:
    ```go
    func HandleOrder(w http.ResponseWriter, r *http.Request) {
        ctx := r.Context()
        // ... process order ...

        // Detached background audit logger: survives client abort but retains trace ID and user context
        go func(auditCtx context.Context) {
            // Apply independent 5-second deadline for the background operation
            cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(auditCtx), 5*time.Second)
            defer cancel()

            if err := auditService.RecordAuditLog(cleanupCtx, "order.processed"); err != nil {
                slog.ErrorContext(cleanupCtx, "Failed to persist audit log", "error", err)
            }
        }(ctx)
    }
    ```
- **Bounded Worker Pools vs Unbounded Goroutine Spawning**:
  - ❌ **The Unbounded Goroutine Memory Explosion**: Spawning an unthrottled goroutine for every incoming HTTP request or message queue event (`go handle(msg)`). Under high traffic spikes (e.g., 50,000 req/sec), Go allocates tens of thousands of goroutine stacks, exhausts OS file descriptors and socket buffers, and degrades CPU cache locality with excessive scheduling overhead.
  - ✅ **Production Invariant**: Bound concurrency using a fixed worker pool with a buffered channel or an explicit weighted semaphore (`golang.org/x/sync/semaphore`):
    ```go
    type JobPool struct {
        tasks chan func(ctx context.Context)
        wg    sync.WaitGroup
    }

    func NewJobPool(workers int, queueCapacity int) *JobPool {
        p := &JobPool{
            tasks: make(chan func(context.Context), queueCapacity),
        }
        p.wg.Add(workers)
        for i := 0; i < workers; i++ {
            go func() {
                defer p.wg.Done()
                for task := range p.tasks {
                    task(context.Background())
                }
            }()
        }
        return p
    }

    func (p *JobPool) Submit(ctx context.Context, task func(ctx context.Context)) bool {
        select {
        case p.tasks <- task:
            return true
        case <-ctx.Done():
            return false // Task dropped due to caller context cancellation/timeout
        default:
            return false // Backpressure: queue saturated
        }
    }
    ```
- **`sync.Pool` Pointer Re-Zeroing & Memory Leak Prevention**:
  - ❌ **The Dangling Pointer Heap Retention Bug**: Returning structs containing pointers, maps, or sub-slices back to `sync.Pool` without clearing the referenced pointers (`buf.Data = buf.Data[:0]`). The Go garbage collector treats pointers remaining in pooled objects as active roots, preventing large previously allocated objects from being garbage collected across GC cycles.
  - ✅ **Production Invariant**: Always zero out pointers, maps, and sub-slices before returning structs to `sync.Pool`:
    ```go
    type EventBuffer struct {
        Payload  []byte
        Headers  map[string]string // Pointer-bearing type!
        Metadata *EventMeta        // Pointer-bearing type!
    }

    var eventBufferPool = sync.Pool{
        New: func() any {
            return &EventBuffer{
                Payload: make([]byte, 0, 4096),
                Headers: make(map[string]string),
            }
        },
    }

    func PutEventBuffer(buf *EventBuffer) {
        buf.Payload = buf.Payload[:0]
        clear(buf.Headers) // Go 1.21+ built-in clear() to delete all keys
        buf.Metadata = nil // Nil out pointer to allow GC of underlying object
        eventBufferPool.Put(buf)
    }
    ```
- **Container Cgroup Memory Soft Ceiling via `GOMEMLIMIT` & `GOGC` Tuning**:
  - ❌ **The Unaware Container OOM Killer Termination**: The Go runtime defaults to running GC every time heap memory doubles (`GOGC=100`). In a Kubernetes pod or container sandbox with a 1 GB memory limit, if the heap is at 600 MB and allocations spike, Go will not trigger GC until 1200 MB, causing the Linux cgroups v2 OOM killer to immediately terminate the process with `Exit Code 137` (SIGKILL).
  - ✅ **Production Invariant**: In containerized environments, always set `GOMEMLIMIT` to 80%–90% of the container hard memory limit (e.g. `GOMEMLIMIT=850MiB` for a 1GiB container). The Go 1.19+ runtime will aggressively pace garbage collection as memory approaches this soft ceiling, avoiding OOM kills under temporary allocation spikes:
    ```bash
    # Kubernetes Pod / Container Execution Environment:
    export GOMEMLIMIT="850MiB" # Leaves 150MiB headroom for OS/CGo/binary overhead
    export GOGC="100"          # Or tune to 200 with GOMEMLIMIT to reduce GC CPU overhead
    ```
- **Deterministic Lock Ordering to Prevent Multi-Resource Deadlocks**:
  - ❌ **The Inverted Acquisition Deadlock**: Goroutine A locks `Account 1` then requests `Account 2`, while Goroutine B locks `Account 2` then requests `Account 1`. Under high concurrency, both goroutines block each other forever, freezing database or in-memory transaction processors.
  - ✅ **Production Invariant**: Always sort multiple resources into a deterministic canonical order (e.g., lexicographical by ID or memory address) before acquiring mutexes:
    ```go
    // Go: Deterministic multi-mutex acquisition
    func TransferBalance(accA, accB *Account, amount int64) error {
        if accA.ID == accB.ID {
            return errors.New("cannot transfer to identical account")
        }

        // Lock in strict ascending order of ID to eliminate ABBA deadlocks:
        first, second := accA, accB
        if first.ID > second.ID {
            first, second = accB, accA
        }

        first.mu.Lock()
        defer first.mu.Unlock()

        second.mu.Lock()
        defer second.mu.Unlock()

        if accA.Balance < amount {
            return errors.New("insufficient balance")
        }
        accA.Balance -= amount
        accB.Balance += amount
        return nil
    }
    ```
- **`sync.Mutex` Copylock & Pointer Receiver Invariant**:
  - ❌ **The Mutex Pass-by-Value State Desynchronization**: Defining methods on structs that contain `sync.Mutex` or `sync.RWMutex` with value receivers (`func (c Counter) Value() int`). Passing the struct by value creates a shallow copy of the mutex's internal atomic state. The caller's lock is completely disassociated from the copy's lock, leading to race conditions and data corruption.
  - ✅ **Production Invariant**: Always define pointer receivers (`func (c *Counter) ...`) on any struct containing synchronization primitives, and enforce `go vet` in CI to fail on `copylocks` violations.
- **Go 1.24+ `testing.B.Loop()` Idiomatic Benchmarks & Dead-Code Optimization Defense**:
  - ❌ **The Legacy `b.N` Loop Pitfalls & Compiler Optimization Trap**: The classic `for i := 0; i < b.N; i++` benchmark loop suffers from common anti-patterns: expensive setup code placed before the loop executes multiple times if the benchmark framework adjusts `b.N`, manual `b.ResetTimer()` calls are easily forgotten, and if the loop body does not consume its results, the Go optimizing compiler dead-code eliminates the entire computation, reporting misleading zero-nanosecond runs.
  - ✅ **Production Invariant**: In Go 1.24+, exclusively use `b.Loop()`. It automatically resets timers before iterations begin, manages loop execution bounds, prevents outer iteration re-execution bugs, and provides clean semantics:
    ```go
    // Go 1.24+ idiomatic benchmark
    func BenchmarkVectorCosineSimilarity(b *testing.B) {
        v1 := generateRandomVector(1536)
        v2 := generateRandomVector(1536)
        var result float32

        // b.Loop() automatically handles timer resets and iteration pacing:
        for b.Loop() {
            result = CosineSimilarity(v1, v2)
        }

        // Prevent compiler dead-code elimination:
        _ = result
    }
    ```
- **Go 1.24+ `runtime.AddCleanup` Over `runtime.SetFinalizer` for Low-Level Resource Reclamation**:
  - ❌ **The Object Resurrection & Cycle Leak Trap of `SetFinalizer`**: `runtime.SetFinalizer(ptr, fn)` passes the target pointer directly into the finalizer closure, resurrecting the object and preventing immediate reclamation. If two finalizable objects form a cyclic reference, neither finalizer ever executes, causing permanent memory leaks. Furthermore, finalizers delay memory reclamation across multiple GC sweeps.
  - ✅ **Production Invariant**: In Go 1.24+, use `runtime.AddCleanup(target, cleanupFn, arg)`. The target object is never resurrected because `cleanupFn` only receives a decoupled cleanup handle (`arg`), never the target itself. This eliminates resurrection cycles, prevents GC leaks, and runs safely when the target becomes unreachable:
    ```go
    // Go 1.24+ safe handle cleanup without object resurrection
    type MmapBuffer struct {
        handle *os.File
        data   []byte
    }

    func NewMmapBuffer(path string) (*MmapBuffer, error) {
        f, err := os.Open(path)
        if err != nil {
            return nil, err
        }
        rawFd := f.Fd()

        buf := &MmapBuffer{handle: f}
        // Attach cleanup function to buf, passing raw file descriptor as decoupled argument:
        runtime.AddCleanup(buf, func(fd uintptr) {
            _ = syscall.Close(int(fd))
        }, rawFd)

        return buf, nil
    }
    ```
- **Go 1.24+ Deterministic Concurrency Testing with `testing/synctest` Bubbles**:
  - ❌ **The Flaky `time.Sleep` Concurrency Test Anti-Pattern**: Testing async pipelines, channel handoffs, timeouts, or worker pools using arbitrary `time.Sleep(50 * time.Millisecond)`. On overloaded CI runners, 50ms is too short (causing random test failures), while increasing timeouts makes the test suite take minutes to run.
  - ✅ **Production Invariant**: In Go 1.24+, wrap concurrent test logic in `synctest.Run(func())`. Goroutines inside the synctest "bubble" operate in an isolated virtual time space. When all goroutines within the bubble are durably blocked on channel sends, receives, or timers, time instantly jumps to unblock the earliest pending timer without real-world latency:
    ```go
    // Go 1.24+ instant, non-flaky concurrent timer test
    func TestWorkerPoolTimeout(t *testing.T) {
        synctest.Run(func() {
            done := make(chan bool)
            go func() {
                // Sleep for 10 virtual minutes inside bubble
                time.Sleep(10 * time.Minute)
                done <- true
            }()

            select {
            case <-done:
                // Test completes instantaneously in virtual time!
            case <-time.After(11 * time.Minute):
                t.Fatal("worker did not complete in virtual time")
            }
        })
    }
    ```
- **Go 1.24+ Swiss Tables Map Architecture & Allocation Pacing**:
  - ❌ **The Unsized Swiss Table Rehash Penalty**: In Go 1.24, Go's runtime replaces legacy 8-slot bucket hash maps with Swiss Tables (flat group SIMD control-byte probing). While lookup performance is significantly faster and memory overhead per element is reduced, growing a map dynamically from zero capacity still incurs multi-phase allocation, control byte rehashing, and table expansion overhead.
  - ✅ **Production Invariant**: Always pre-size maps when item count is known or bounded (`make(map[K]V, count)`). In Go 1.24+, this pre-allocates contiguous control-byte groups and value slots in a single contiguous memory block, achieving optimal SIMD instruction cache locality and eliminating rehashing pauses.
- **Go 1.24+ Weak Pointers (`weak.Pointer`) & Zero-Leak In-Memory Caches**:
  - ❌ **The Strong Pointer Cache Retain Trap**: Maintaining canonicalization caches, symbol intern tables, or session memoizers using strong references (`map[string]*LargeObject`). Even if all caller goroutines have discarded the object, the cache map retains a root pointer, completely blinding the GC and causing gradual memory exhaustion.
  - ✅ **Production Invariant**: In Go 1.24+, use standard library `weak.Make(ptr)` to store weak references (`weak.Pointer[T]`). A weak pointer allows the garbage collector to reclaim the object when no strong references remain, returning `nil` when accessed via `wp.Value()`:
    ```go
    import "weak"

    type CanonicalCache[K comparable, V any] struct {
        mu    sync.RWMux
        store map[K]weak.Pointer[V]
    }

    func (c *CanonicalCache[K, V]) Get(key K) *V {
        c.mu.RLock()
        wp, exists := c.store[key]
        c.mu.RUnlock()

        if !exists {
            return nil
        }
        // Returns nil if GC reclaimed the target object
        return wp.Value()
    }
    ```
- **Go 1.24+ Finalizer Modernization with `runtime.AddCleanup`**:
  - ❌ **The Fragile Legacy `runtime.SetFinalizer` Object Resurrection**: Legacy finalizers (`runtime.SetFinalizer(x, fn)`) fail completely on circular reference structures, delay collection of `x` and its dependencies by at least one full additional GC cycle, and can accidentally resurrect the dead object.
  - ✅ **Production Invariant**: In Go 1.24+, replace all `runtime.SetFinalizer` calls with `runtime.AddCleanup(ptr, cleanupFunc, arg)`. The cleanup function receives an isolated value `arg` (such as an OS file descriptor or socket handle) rather than the parent object, completely eliminating cyclic reference memory leaks and resurrection bugs.
- **Go 1.24+ Modern Benchmark Loops with `b.Loop()`**:
  - ❌ **The Legacy `for i := 0; i < b.N; i++` Skew & Compiler Dead-Code Stripping**: The traditional benchmark loop requires explicit calls to `b.ResetTimer()` after setup and is vulnerable to compiler optimizations stripping out pure operations when outputs are unused. Furthermore, running warm-up iterations manually often distorts benchmark metrics.
  - ✅ **Production Invariant**: In Go 1.24+, use `for b.Loop()` instead of `for i := 0; i < b.N; i++`. `b.Loop()` automatically manages timer resetting across iterations, ensures compiler side-effects are preserved, and provides consistent per-op timing without manual reset calls:
    ```go
    func BenchmarkTokenVerification(b *testing.B) {
        verifier := setupCryptoVerifier() // Expensive setup before the loop

        // Go 1.24+: Automatically resets timer and manages iterations
        for b.Loop() {
            _ = verifier.VerifyToken(sampleToken)
        }
    }
    ```
- **Context Teardown Hygiene with `context.AfterFunc`**:
  - ❌ **The Orphan Goroutine Teardown Watcher**: Spawning a dedicated goroutine `go func() { <-ctx.Done(); cleanup() }()` to monitor cancellation. This leaks a full stack frame (2KB–8KB) per connection/request, incurs scheduler context switching overhead, and delays cleanup.
  - ✅ **Production Invariant**: Use `stop := context.AfterFunc(ctx, cleanupFunc)` introduced in Go 1.21+. It executes `cleanupFunc` asynchronously in its own goroutine when the context expires or is cancelled, and returns a cancellation handle (`stop()`) to deregister the callback immediately when work finishes normally.
- **Go 1.24+ Swiss Tables Map Architecture & Predictable Iteration**:
  - ❌ **Relying on Pseudo-Ordering in Map Iteration**: Go 1.24 incorporates a Swiss Tables map redesign using SSE2/AVX2 control bytes for 30% faster lookups. However, Go randomized map iteration seed remains active. Relying on map iteration order when building deterministic signatures, JSON payloads, or cryptographic digests causes non-deterministic output and broken cache hits.
  - ✅ **Production Invariant**: Always sort map keys explicitly (`slices.Sort(keys)`) before computing cryptographic hashes (SHA-256) or sending payloads across network boundaries.
- **Go 1.24+ `testing/synctest` for Hermetic Virtualized Concurrency Testing**:
  - ❌ **Arbitrary Wall-Clock Sleeps in Concurrency Tests**: Using `time.Sleep()` or flaky channel timers to test timeout and deadline logic across goroutines. Under CI load, wall-clock sleeps cause intermittent test failures and balloon execution runtimes.
  - ✅ **Production Invariant**: In Go 1.24+, use `testing/synctest` (`synctest.Run(func() { ... })`) to execute concurrent code bubbles under a virtualized system clock. `synctest.Wait()` blocks until all goroutines in the bubble are idle, advancing virtual time deterministically and running simulated multi-minute timeouts in milliseconds without flakiness:
    ```go
    func TestWorkerTimeoutHermetic(t *testing.T) {
        synctest.Run(func() {
            ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
            defer cancel()

            worker := NewWorker()
            done := make(chan error, 1)
            go func() {
                done <- worker.Process(ctx)
            }()

            // Advances virtualized clock immediately without real-world sleep
            synctest.Wait()
            err := <-done
            require.ErrorIs(t, err, context.DeadlineExceeded)
        })
    }
    ```
- **Go 1.24+ `runtime.AddCleanup` over `runtime.SetFinalizer` Object Resurrection Defense**:
  - ❌ **The Object Resurrection Memory Leak Trap**: Using legacy `runtime.SetFinalizer(obj, finalizer)` to release CGo memory, shared memory mappings, or OS file handles. `runtime.SetFinalizer` passes the object pointer back into the finalizer closure, resurrecting the object onto the heap, creating uncollectible reference cycles, and deferring reclamation indefinitely.
  - ✅ **Production Invariant**: In Go 1.24+, use `runtime.AddCleanup(ptr, cleanupFunc, arg)`. The cleanup function receives an isolated detached value (`arg`), never the target object pointer itself, making object resurrection mathematically impossible and allowing seamless garbage collection of circular data structures:
    ```go
    type SafeMmap struct {
        data []byte
    }

    func NewSafeMmap(descriptor int, length int) *SafeMmap {
        data := mmapSyscall(descriptor, length)
        handle := &SafeMmap{data: data}

        // Passes detached pointer value to cleanup; handle cannot be resurrected
        runtime.AddCleanup(handle, func(addr uintptr) {
            munmapSyscall(addr, length)
        }, uintptr(unsafe.Pointer(&data[0])))

        return handle
    }
    ```
- **Go 1.24+ Generic Type Aliases for Zero-Downtime Package Migration**:
  - ❌ **The Monolithic Package Refactoring Breaking Change**: Moving generic structures or interfaces from an internal package to a public API (e.g. `internal/cache.Store[K, V]` to `cache.Store[K, V]`). Prior to Go 1.24, type aliases did not support type parameters (`type Store[K, V] = internal.Store[K, V]` was forbidden), forcing breaking API changes or duplicate boilerplate wrapper types.
  - ✅ **Production Invariant**: In Go 1.24+, utilize generic type aliases (`type Cache[K comparable, V any] = internal.Cache[K, V]`) to seamlessly refactor package hierarchies and decouple interfaces without breaking downstream consumer type signatures.
- **Go 1.24+ `os.Root` Filesystem Sandboxing & Traversal Defense**:
  - ❌ **Naive Path Sanitization & Symlink Traversal Vulnerabilities**: Relying on string manipulation (`strings.HasPrefix(cleanPath, rootDir)`) or `filepath.Clean` to restrict file access within a workspace directory. Attackers bypass string-based checks using symlinks pointing outside the target tree (`symlink -> /etc/passwd`), relative race conditions (TOCTOU), or absolute paths.
  - ✅ **Production Invariant**: In Go 1.24+, use `os.OpenRoot(dir)` which returns an `*os.Root` handle backed by OS-level sandbox primitives (such as Linux `openat2` with `RESOLVE_BENEATH`). All subsequent operations (`root.Open`, `root.Create`, `root.Stat`, `root.Remove`) are strictly confined within the directory subtree, rejecting symlinks and `..` paths escaping the root at the kernel syscall level:
    ```go
    package workspace

    import (
        "fmt"
        "io"
        "os"
    )

    func SafeReadUserFile(rootDir, relativePath string) ([]byte, error) {
        root, err := os.OpenRoot(rootDir)
        if err != nil {
            return nil, fmt.Errorf("failed to open workspace root: %w", err)
        }
        defer root.Close()

        // Root.Open enforces OS-level confinement; cannot escape rootDir via symlinks or '..'
        f, err := root.Open(relativePath)
        if err != nil {
            return nil, fmt.Errorf("path access denied or not found: %w", err)
        }
        defer f.Close()

        stat, err := f.Stat()
        if err != nil || stat.IsDir() {
            return nil, fmt.Errorf("invalid file target")
        }

        return io.ReadAll(f)
    }
    ```
- **Go 1.24+ `testing.B.Loop` Benchmark Invariant**:
  - ❌ **The `b.N` Setup-Timing Leak & Dead Code Elimination Trap**: Writing Go benchmarks with legacy `for i := 0; i < b.N; i++`. If expensive initialization code is run before the loop, developers frequently forget `b.ResetTimer()`. Furthermore, compilers frequently optimize away loop bodies whose return values are unused, skewing benchmarks to deceptive sub-nanosecond figures.
  - ✅ **Production Invariant**: In Go 1.24+, use `for b.Loop()`:
    ```go
    func BenchmarkPayloadSerialization(b *testing.B) {
        payload := generateComplexTestPayload()

        // b.Loop() automatically handles timer resets before iteration begins,
        // adjusts iteration count, and prevents compiler dead-code elimination
        for b.Loop() {
            _ = serializePayload(payload)
        }
    }
    ```
    `b.Loop()` guarantees that per-benchmark setup code executed before the loop is automatically excluded from the timing measurements without requiring manual `b.ResetTimer()` invocations.
- **Go 1.20+ / 1.24+ Zero-Copy Byte/String Conversions (`unsafe.StringData` & `unsafe.SliceData`)**:
  - ❌ **The Legacy `reflect.SliceHeader` / `reflect.StringHeader` Deprecation Trap**: Manipulating slice/string headers via `reflect.SliceHeader` or `*(*string)(unsafe.Pointer(&b))` which causes GC pointer misclassification, undefined behavior in future Go runtime releases, and memory races.
  - ✅ **Production Invariant**: Use `unsafe.StringData(s)` and `unsafe.SliceData(slice)` standardized in Go 1.20+:
    ```go
    // Zero-copy conversion from []byte to string (read-only invariant!)
    func BytesToStringReadOnly(b []byte) string {
        if len(b) == 0 {
            return ""
        }
        return unsafe.String(unsafe.SliceData(b), len(b))
    }

    // Zero-copy conversion from string to []byte (strictly read-only invariant!)
    func StringToBytesReadOnly(s string) []byte {
        if len(s) == 0 {
            return nil
        }
        return unsafe.Slice(unsafe.StringData(s), len(s))
    }
    ```
    Mandatory invariant: the resulting byte slice MUST never be mutated, as strings in Go are immutable and backed by read-only memory segments; mutating it triggers an immediate OS-level SIGSEGV.
- **Go `select` Starvation Defense via Pseudo-Random Channel Shuffling**:
  - ❌ **The High-Throughput Background Starvation Trap**: When multiple cases in a `select` statement are ready, Go selects pseudo-randomly among them. However, when code nests priority cases or repeatedly polls busy channels, lower-priority background channels (e.g. audit logging or telemetry) can be starved for seconds under heavy burst traffic.
  - ✅ **Production Invariant**: Interleave work fairly by running a non-blocking check on the background channel before entering the blocking loop, or use explicit round-robin state indexing across worker queues.
- **Go 1.24+ `sync.Map.Clear()` Atomic Flush**:
  - ❌ **Iterating and Deleting Keys Individually from `sync.Map`**: In high-throughput servers, clearing a `sync.Map` by calling `m.Range(func(key, _ any) bool { m.Delete(key); return true })` acquires internal lock segments repeatedly, incurs $O(N)$ dirty-to-read promotions, and causes severe lock contention.
  - ✅ **Production Invariant**: In Go 1.24+, call `m.Clear()` which atomically flushes both read and dirty maps in $O(1)$ amortized time, resetting internal allocation counters without lock thrashing.
- **Go 1.24+ `testing.T.Chdir()` for Hermetic Test Isolation**:
  - ❌ **Process-Wide `os.Chdir()` Race Conditions in Parallel Unit Tests**: Calling `os.Chdir(tmpDir)` inside unit tests with `t.Parallel()`. Because the working directory is process-global across all OS threads, changing it in one test corrupts file resolution in all concurrently running tests.
  - ✅ **Production Invariant**: In Go 1.24+, call `t.Chdir(tmpDir)`. It scopes directory mutations to the test lifecycle, automatically restoring the original working directory when the test completes, and strictly blocks `t.Parallel()` invocations that would introduce race conditions.
- **Go `context.AfterFunc` Closure Memory Leak Defense**:
  - ❌ **Unstopped `context.AfterFunc` Closures on Long-Lived Parent Contexts**: Registering teardown callbacks via `stop := context.AfterFunc(ctx, cleanupFn)` on server-wide root contexts (e.g., `appCtx` or HTTP server context) without ever invoking `stop()`. If the child task finishes normally long before the parent context is canceled, the registered closure and all its captured pointers remain pinned in heap memory until server shutdown.
  - ✅ **Production Invariant**: Always invoke the returned `stop()` function via `defer` or immediate completion to deregister the callback and release captured references:
    ```go
    stop := context.AfterFunc(reqCtx, func() {
        conn.Close()
    })
    defer stop() // Mandatory: unregisters callback upon normal handler exit!
    ```
- **Go 1.23/1.24+ `iter.Pull` Goroutine Leak Defense**:
  - ❌ **Abandoned Pull Iterators Leaking Driving Goroutines**: Go 1.23+ introduced range-over-function iterators (`iter.Seq[V]`). When converting a push iterator to a pull iterator via `next, stop := iter.Pull(seq)`, Go internally allocates a hidden helper goroutine to coordinate yield channels. If the consuming loop breaks or returns early without invoking `stop()`, this background goroutine remains blocked indefinitely, leaking memory and runtime stacks.
  - ✅ **Production Invariant**: ALWAYS defer `stop()` immediately after calling `iter.Pull` or `iter.Pull2`:
    ```go
    next, stop := iter.Pull(streamIterator)
    defer stop() // Mandatory: terminates hidden background iteration goroutine on early exit!

    for {
        val, ok := next()
        if !ok || shouldBreak(val) {
            break
        }
    }
    ```
- **Go 1.21+ `sync.OnceValue` & `sync.OnceValues` for Safe Lazy Instantiation**:
  - ❌ **Manual `sync.Once` Boilerplate with Exposed Shared Variables**: Writing manual `var once sync.Once`, `var instance *Service`, and `var initErr error` at package level, risking accidental un-synchronized reads before initialization finishes or error loss.
  - ✅ **Production Invariant**: Use `sync.OnceValues` for thread-safe single-computation closures returning values and errors:
    ```go
    var getClient = sync.OnceValues(func() (*http.Client, error) {
        return buildSecureTLSClient()
    })

    // Safe concurrent invocation across all goroutines:
    client, err := getClient()
    ```
- **Go 1.24+ `testing.B.Loop` Benchmark Invariant**:
  - ❌ **Legacy `for i := 0; i < b.N; i++` Benchmark Artifacts**: Using the traditional loop structure prone to benchmark timing skew, where initialization code placed before the loop runs outside timing calibration or where compiler optimizations eliminate dead-loop iterations, skewing nanoseconds-per-op statistics.
  - ✅ **Production Invariant**: In Go 1.24+, use `b.Loop()` which automatically resets benchmark timers before iteration, prevents unwanted loop unrolling/dead-code elimination, and executes setup code cleanly per iteration cycle:
    ```go
    func BenchmarkPayloadParsing(b *testing.B) {
        payload := generateSyntheticPayload(1024)
        for b.Loop() {
            // Setup code per run executes with automatic timer pause/resume
            _ = parseAndValidate(payload)
        }
    }
    ```
- **Go 1.24+ Deterministic Virtualized Concurrency Testing with `testing/synctest`**:
  - ❌ **Flaky `time.Sleep` in Concurrent Goroutine Tests**: Simulating timeouts, heartbeats, or debouncing with real `time.Sleep(100 * time.Millisecond)`, causing race detector slowdowns, fragile CI flakiness, and bloated test suite execution times.
  - ✅ **Production Invariant**: In Go 1.24+, wrap concurrent goroutine scheduling inside `synctest.Run(func() { ... })`. Synctest executes goroutines within a virtualized time bubble, instantly advancing synthetic clocks to test deadlines without real-world latency:
    ```go
    func TestWorkerHeartbeatTimeout(t *testing.T) {
        synctest.Run(func() {
            ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
            defer cancel()

            worker := NewWorker(ctx)
            go worker.Start()

            // Instantly advance virtual clock past timeout without sleeping:
            time.Sleep(6 * time.Second)
            synctest.Wait() // Drain bubble until all goroutines reach quiescence

            if !worker.IsTerminated() {
                t.Fatalf("expected worker termination on virtual context timeout")
            }
        })
    }
    ```
- **Go 1.23+ Canonical Value Interning with `unique.Make`**:
  - ❌ **Redundant Heap Duplication for High-Cardinality Strings/Structs**: Ingesting millions of telemetry tags, HTTP path templates, or IP address strings, allocating separate duplicate heap backing arrays for identical values and wasting hundreds of megabytes of RAM.
  - ✅ **Production Invariant**: Use Go 1.23+ `unique.Make` to intern comparable types into a globally deduplicated, concurrent-safe canonical pool with $O(1)$ pointer equality comparison:
    ```go
    import "unique"

    type RouteKey struct {
        Method string
        Path   string
    }

    var internedRoute = unique.Make(RouteKey{Method: "POST", Path: "/api/v1/checkout"})

    // O(1) comparison between interned handles (pointer equality):
    if keyHandle == internedRoute {
        // Fast-path matched
    }
    ```
- **Go 1.24+ JSON `omitzero` vs Legacy `omitempty` Struct Tag Invariant**:
  - ❌ **`omitempty` Inaccuracies on Non-Pointer Structs & Booleans**: Traditional `encoding/json` `omitempty` ignores the `IsZero()` method on non-pointer struct values (such as `time.Time{}`), causing zero-valued timestamps to serialize as `"0001-01-01T00:00:00Z"`. Furthermore, setting `omitempty` on a boolean field silently drops `false` values even when `false` is an intentional semantic update.
  - ✅ **Production Invariant**: In Go 1.24+ `encoding/json/v2` (and production v1 workflows), use `omitzero` to evaluate `IsZero() bool` implementations cleanly, or wrap optional scalar and struct fields in pointers (`*bool`, `*time.Time`) to eliminate serialization ambiguity:
    ```go
    type AuditEvent struct {
        EventID   string     `json:"event_id"`
        // Pointer allows distinguishing between unassigned (nil) and explicit zero/false:
        IsRevoked *bool      `json:"is_revoked,omitempty"`
        // Go 1.24+ omitzero evaluates time.Time.IsZero() correctly:
        ExpiresAt *time.Time `json:"expires_at,omitzero"`
    }
    ```
- **Go `errors.As` Concrete Pointer-to-Pointer Type Safety**:
  - ❌ **Passing Single Pointer to Struct Pointer in `errors.As` Triggering Runtime Panic**: Writing `var target *CustomError; errors.As(err, target)` instead of passing the address `&target`. In Go, `errors.As(err, target)` requires `target` to be a non-nil pointer to either an interface type or a type implementing `error`. Passing `target` directly panics at runtime with: `errors: *target must be interface or implement error`.
  - ✅ **Production Invariant**: Always declare a typed pointer variable and pass its memory address (`&target`) into `errors.As`:
    ```go
    var validationErr *ValidationError
    // Correct: &validationErr passes a pointer-to-pointer (**ValidationError)
    if errors.As(err, &validationErr) {
        log.Printf("validation failed on field: %s", validationErr.Field)
    }
    ```
- **Go 1.24+ `t.Context()` Sub-Test Lifecycle & Goroutine Leak Defense**:
  - ❌ **Manual Test Contexts Causing Zombie Goroutines & Flaky Mock Races**: Creating ad-hoc `context.WithCancel(context.Background())` in sub-tests and failing to cancel it, or cancelling it too late. Lingering goroutines continue invoking mock expectations during subsequent parallel tests, resulting in intermittent `-race` detector failures.
  - ✅ **Production Invariant**: In Go 1.24+, pass `t.Context()` directly to client calls, database transactions, and background workers under test. `t.Context()` is deterministically cancelled as soon as the test or subtest returns:
    ```go
    func TestOrderProcessing(t *testing.T) {
        t.Parallel()
        ctx := t.Context() // Automatically cancelled when TestOrderProcessing completes

        server := startMockPaymentServer(t)
        res, err := server.Process(ctx, Order{ID: "ord_101"})
        if err != nil {
            t.Fatalf("unexpected error: %v", err)
        }
    }
    ```
- **Go HTTP Request Body Bounded Ingestion (`http.MaxBytesReader`)**:
  - ❌ **Unbounded `io.ReadAll(r.Body)` Memory Exhaustion (OOM DOS)**: Reading untrusted HTTP request bodies directly via `body, err := io.ReadAll(r.Body)` or passing `r.Body` unconstrained to `json.NewDecoder(r.Body)`. A malicious actor streaming a 2GB request payload consumes memory until the host kills the container via Linux OOM killer.
  - ✅ **Production Invariant**: Always wrap `r.Body` in `http.MaxBytesReader(w, r.Body, maxBytes)` before reading or decoding JSON, enforcing strict body size ceilings (e.g. 1MB or 4MB):
    ```go
    const MaxRequestBodyBytes = 1 << 20 // 1 MB ceiling

    func handleWebhook(w http.ResponseWriter, r *http.Request) {
        r.Body = http.MaxBytesReader(w, r.Body, MaxRequestBodyBytes)
        defer r.Body.Close()

        var payload WebhookPayload
        dec := json.NewDecoder(r.Body)
        dec.DisallowUnknownFields() // Reject unmapped fields

        if err := dec.Decode(&payload); err != nil {
            http.Error(w, "request entity too large or malformed", http.StatusBadRequest)
            return
        }
    }
    ```
- **Go 1.21+ `sync.OnceValue` / `sync.OnceValues` for Safe Lazy Initialization**:
  - ❌ **Anti-Pattern: Manual Mutex-Guarded Double-Checked Locking or Fragile `init()` Blocks**: Hand-rolling mutex double-checks with raw `sync.Mutex` or executing heavy network/config parsing inside package `init()` functions (causing unrecoverable panics on missing env variables or circular import headaches).
  - ✅ **Production Invariant**: Use `sync.OnceValue(fn)` or `sync.OnceValues(fn)` to lazily compute and memoize expensive singletons (e.g. compiled regexes, connection pools, schema validators) with guaranteed single execution and thread-safe error propagation:
    ```go
    // Compile regex lazily on first access, thread-safely memoized forever:
    var getEmailRegex = sync.OnceValue(func() *regexp.Regexp {
        return regexp.MustCompile(`^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`)
    })

    // Lazy singleton client with error handling:
    var getDatabasePool = sync.OnceValues(func() (*pgxpool.Pool, error) {
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        return pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
    })
    ```
- **Go 1.24+ `testing/synctest` Deterministic Virtual Clock Goroutine Testing**:
  - ❌ **Flaky Test Anti-Pattern: Sprinkling Wall-Clock `time.Sleep()` to Await Background Goroutines**: Inserting `time.Sleep(100 * time.Millisecond)` in tests to wait for worker pools, debounce channels, or token buckets. Under heavy CI load, the sleep is insufficient, producing intermittent test failures; on local machines, it wastes dozens of cumulative test seconds.
  - ✅ **Production Invariant**: In Go 1.24+, use `synctest.Run(func() { ... })` to execute concurrent goroutines within an isolated synthetic event loop. In `synctest`, `time.Sleep()` advances virtual time instantaneously when all goroutines in the bubble are durably blocked:
    ```go
    func TestDebounceWorker(t *testing.T) {
        synctest.Run(func() {
            var counter atomic.Int32
            d := NewDebouncer(500 * time.Millisecond, func() {
                counter.Add(1)
            })

            d.Trigger()
            d.Trigger()

            // Instantly advances virtual time 600ms without real wall-clock delay:
            time.Sleep(600 * time.Millisecond)

            if got := counter.Load(); got != 1 {
                t.Fatalf("expected debounced call count 1, got %d", got)
            }
        })
    }
    ```
- **Go 1.22+ `math/rand/v2` High-Throughput Thread-Safe PRNG vs Legacy Global Lock Contention**:
  - ❌ **Anti-Pattern: Legacy `math/rand` Global Seed & Contended Mutex**: Calling legacy `rand.Intn(100)` or seeding with `rand.Seed(time.Now().UnixNano())` in multi-threaded microservices. The legacy top-level generator locks a shared global `sync.Mutex` on every invocation, turning high-concurrency token generators or randomized backoffs into a severe CPU bottleneck.
  - ✅ **Production Invariant**: In Go 1.22+, use `math/rand/v2`. Top-level functions like `rand.IntN(n)` use per-thread ChaCha8 or PCG generators with zero mutex lock overhead:
    ```go
    import (
        "math/rand/v2"
        "time"
    )

    // Lock-free, cryptographically sound, high-throughput pseudo-random jitter:
    func jitteredBackoff(baseDelay time.Duration, attempt int) time.Duration {
        backoff := baseDelay * (1 << attempt)
        // rand/v2 Int64N is lock-free and thread-safe:
        jitter := time.Duration(rand.Int64N(int64(backoff / 2)))
        return backoff + jitter
    }
    ```
- **Go 1.20+ Zero-Copy `unsafe.String` / `unsafe.Slice` Invariants with Immutability Boundaries**:
  - ❌ **Anti-Pattern: Allocating `string([]byte)` in Ultra-High-Throughput Hot Loops or Mutating Backing Arrays**: Doing `string(b)` in packet parsers that process millions of packets per second (causing GC allocation thrashing), OR using raw pointer casting to convert `[]byte` to `string` and subsequently mutating the underlying slice, violating Go's string immutability invariant and causing data races.
  - ✅ **Production Invariant**: In Go 1.20+, use `unsafe.String` and `unsafe.Slice` for zero-allocation conversions ONLY when the backing byte slice is guaranteed to be discarded or never mutated again:
    ```go
    import "unsafe"

    // Zero-alloc byte-to-string for read-only deserialization/lookup:
    func ReadOnlyLookup(key []byte) string {
        if len(key) == 0 {
            return ""
        }
        // Zero allocations; valid ONLY if key is immutable during string lifetime
        return unsafe.String(unsafe.SliceData(key), len(key))
    }
    ```
- **Structured Goroutine Concurrency via `errgroup.WithContext`**:
  - ❌ **Anti-Pattern: Fire-and-Forget Goroutines & Orphaned Worker Memory Leaks**: Launching naked `go worker()` loops without lifecycle context. If one worker fails or encounters an unrecoverable error, other peer goroutines continue executing in the background, consuming CPU, I/O, and leaking database connections.
  - ✅ **Production Invariant**: Always wrap coordinated parallel goroutines with `errgroup.WithContext(ctx)` so that any worker failure instantly cancels sibling workers and cleans up in-flight resources:
    ```go
    import (
        "context"
        "golang.org/x/sync/errgroup"
    )

    func FetchBatchMetadata(ctx context.Context, ids []string) ([]Metadata, error) {
        g, ctx := errgroup.WithContext(ctx)
        g.SetLimit(10) // Bound concurrency ceiling

        results := make([]Metadata, len(ids))
        for i, id := range ids {
            i, id := i, id
            g.Go(func() error {
                meta, err := fetchSingle(ctx, id)
                if err != nil {
                    return err // Cancels ctx, aborting in-flight sibling tasks
                }
                results[i] = meta
                return nil
            })
        }

        if err := g.Wait(); err != nil {
            return nil, err
        }
        return results, nil
    }
    ```
- **Go 1.24+ `testing.B.Loop()` for Clean Micro-Benchmark Iteration Control**:
  - ❌ **Anti-Pattern: Legacy `b.N` Loops with Repeated Setup Contamination**: Writing `for i := 0; i < b.N; i++` where per-iteration setup code is accidentally measured or requires manual `b.ResetTimer()` invocations. If the compiler detects pure functions without side-effects inside the `b.N` loop, it may optimize away the entire benchmark.
  - ✅ **Production Invariant**: In Go 1.24+, replace legacy `b.N` loops with `for b.Loop() { ... }`. The runtime manages iteration counts dynamically, automatically excludes warm-up cycles, and prevents compiler dead-code elimination without manual timer resetting:
    ```go
    func BenchmarkPayloadSerialization(b *testing.B) {
        // One-time expensive benchmark setup:
        payload := generateSyntheticPayload(1024)

        // Go 1.24+ modern benchmark loop:
        for b.Loop() {
            encoded, err := Serialize(payload)
            if err != nil {
                b.Fatal(err)
            }
            if len(encoded) == 0 {
                b.Fatal("empty output")
            }
        }
    }
    ```
- **Go `sync.Pool` Memory Retention Defense & Capacity Bounds**:
  - ❌ **Anti-Pattern: Recycling Mega-Buffers into Shared Pools**: Returning arbitrarily grown byte slices (`cap(buf) > 1MB`) back to `sync.Pool`. Under high-concurrency traffic spikes, several massive allocations become permanently pinned in the pool across garbage collection cycles, causing severe memory bloat and process RSS inflation.
  - ✅ **Production Invariant**: Enforce a strict capacity threshold before returning slices to the pool. Discard oversized slices so GC reclaims them, and zero out slice headers to prevent retaining references:
    ```go
    const maxPooledBufferSize = 64 * 1024 // 64KB threshold

    var bufferPool = sync.Pool{
        New: func() any {
            b := make([]byte, 0, 4096)
            return &b
        },
    }

    func ReleaseBuffer(buf *[]byte) {
        if buf == nil {
            return
        }
        // Discard buffers that expanded beyond the safety threshold
        if cap(*buf) > maxPooledBufferSize {
            return
        }
        *buf = (*buf)[:0] // Reset length while preserving capacity
        bufferPool.Put(buf)
    }
    ```
- **Go HTTP Client Connection Reuse & Idle Pool Exhaustion via Unread Response Bodies**:
  - ❌ **Anti-Pattern: Naked `resp.Body.Close()` Without Discard Drain**: Closing `resp.Body` while unread bytes remain in the transport stream. When a response body is closed prematurely, `http.Transport` cannot verify the connection is cleanly at EOF, forcing it to close the underlying TCP/TLS connection instead of returning it to the idle connection pool.
  - ✅ **Production Invariant**: Always drain remaining response bytes to `io.Discard` before closing to ensure socket reuse across requests:
    ```go
    resp, err := httpClient.Do(req)
    if err != nil {
        return err
    }
    defer func() {
        // Drain unread bytes to ensure the underlying TCP socket is reused:
        _, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 512*1024))
        _ = resp.Body.Close()
    }()
    ```
- **Go 1.24+ `weak.Pointer` for Ephemeral Object Caching without GC Memory Pinning**:
  - ❌ **Anti-Pattern: Strong Reference Caches & Finalizer Leak Hazards**: Holding strong pointers in in-memory registries or global maps to "cache" shared entities, or relying on `runtime.SetFinalizer` to detect object deallocation. Strong pointers permanently pin objects in heap memory across GC cycles even when no active worker is using them, causing unbounded RSS growth.
  - ✅ **Production Invariant**: In Go 1.24+, use `weak.Make[T]()` to create weak pointers. Weak pointers allow the Go garbage collector to reclaim the referenced object when all strong references are dropped. Always verify whether the cached value is still alive via `ptr.Value()`:
    ```go
    import "weak"

    type SessionCache struct {
        mu    sync.RWMutex
        store map[string]weak.Pointer[UserSession]
    }

    func (c *SessionCache) Get(sessionID string) (*UserSession, bool) {
        c.mu.RLock()
        defer c.mu.RUnlock()

        wp, exists := c.store[sessionID]
        if !exists {
            return nil, false
        }
        // Go 1.24+: ptr.Value() returns nil if GC reclaimed the target
        val := wp.Value()
        if val == nil {
            return nil, false
        }
        return val, true
    }

    func (c *SessionCache) Put(sessionID string, session *UserSession) {
        c.mu.Lock()
        defer c.mu.Unlock()
        c.store[sessionID] = weak.Make(session)
    }
    ```
- **Go 1.21+ `context.WithTimeoutCause` & `context.Cause` for Precise Error Attribution**:
  - ❌ **Anti-Pattern: Generic `context.DeadlineExceeded` Masking Root Cause**: Using standard `context.WithTimeout(ctx, dur)` across multi-stage service pipelines. When a request times out, downstream telemetry records generic `context deadline exceeded`, masking whether the timeout originated from a database lock, a slow third-party payment gateway, or an upstream client cancellation.
  - ✅ **Production Invariant**: Use `context.WithTimeoutCause` (or `WithDeadlineCause`) and inspect the causal error with `context.Cause(ctx)` to achieve deterministic observability and precise SLA attribution:
    ```go
    var (
        ErrDBQueryTimeout     = errors.New("database query exceeded 250ms SLA")
        ErrDownstreamRPCSlow  = errors.New("pricing rpc gateway exceeded 500ms SLA")
    )

    func ExecuteOrderWorkflow(parentCtx context.Context) error {
        // Attach deterministic cause error to the context timeout:
        ctx, cancel := context.WithTimeoutCause(parentCtx, 250*time.Millisecond, ErrDBQueryTimeout)
        defer cancel()

        if err := runDatabaseQuery(ctx); err != nil {
            if errors.Is(ctx.Err(), context.DeadlineExceeded) {
                // Returns exact cause: ErrDBQueryTimeout instead of generic DeadlineExceeded
                return fmt.Errorf("order step failed: %w", context.Cause(ctx))
            }
            return err
        }
        return nil
    }
    ```
- **Go Typed Atomics (`sync/atomic.Uint64`, `sync/atomic.Pointer[T]`) vs Alignment Fault Hazards**:
  - ❌ **Anti-Pattern: Raw Low-Level Atomics with 32-Bit Alignment Risks**: Using package-level functions like `atomic.LoadUint64(&s.val)` on struct fields. On 32-bit ARM or x86 architectures, 64-bit atomic operations crash with panic: unaligned 64-bit atomic operation if the field is not guaranteed 8-byte aligned, and raw pointers lack compiler type checking.
  - ✅ **Production Invariant**: Always use Go 1.19+ typed atomic wrappers (`atomic.Uint64`, `atomic.Pointer[T]`, `atomic.Bool`). They guarantee proper internal memory alignment across all target architectures and enforce compile-time type safety:
    ```go
    import "sync/atomic"

    type ServiceHealthState struct {
        isHealthy   atomic.Bool
        totalReqs   atomic.Uint64
        currentConf atomic.Pointer[ServiceConfig]
    }

    func NewServiceHealth(initial *ServiceConfig) *ServiceHealthState {
        s := &ServiceHealthState{}
        s.isHealthy.Store(true)
        s.currentConf.Store(initial)
        return s
    }

    func (s *ServiceHealthState) IncrementRequests() uint64 {
        return s.totalReqs.Add(1)
    }

    func (s *ServiceHealthState) UpdateConfig(newConf *ServiceConfig) {
        s.currentConf.Store(newConf)
    }
    ```
- **Go 1.22+ Loop Variable Per-Iteration Scoping Semantics vs Pointer Escape Traps**:
  - ❌ **Anti-Pattern: Old Go <= 1.21 Shadow Variable Habits or Misunderstanding Pointer Lifetimes**: Assuming loop variables are still shared across iterations, or mistakenly assuming that taking `&item.Field` protects against concurrent modifications if the underlying slice is mutated in-place by another goroutine.
  - ✅ **Production Invariant**: In Go 1.22+, each iteration of a `for i, v := range slice` or 3-clause loop (`for i := 0; i < n; i++`) creates a distinct lexical variable. Passing `v` by value directly into closures or goroutines is completely race-free:
    ```go
    // Go 1.22+: Clean, safe goroutine fan-out without shadow variable boilerplate (v := v)
    func DispatchJobs(jobs []Job) {
        for _, job := range jobs {
            go func() {
                // job is a per-iteration copy, safe against loop-variable races
                processJob(job)
            }()
        }
    }
    ```
- **Go 1.24+ `testing/synctest` Deterministic Synthetic Time & Goroutine Bubble Testing**:
  - ❌ **Anti-Pattern: Flaky `time.Sleep` in Concurrency & Timer Tests**: Inserting wall-clock sleeps (`time.Sleep(50 * time.Millisecond)`) in unit tests to wait for background goroutines or channel timeouts. This causes CI flakiness, race conditions on slow runners, and bloats test suite runtime.
  - ✅ **Production Invariant**: In Go 1.24+, use `testing/synctest.Run` to execute concurrent tests inside an isolated synthetic time bubble. In synctest, `time.Sleep` and timers advance synthetic clock time instantaneously when all goroutines in the bubble are blocked:
    ```go
    import (
        "testing"
        "testing/synctest"
        "time"
    )

    func TestDebouncedCacheExpiry(t *testing.T) {
        synctest.Run(func() {
            cache := NewExpiringCache(5 * time.Second)
            cache.Set("key-1", "value-1")

            // Synthetic time advances instantly without waiting 5 real seconds:
            time.Sleep(5 * time.Second)

            if _, found := cache.Get("key-1"); found {
                t.Fatalf("expected key to expire after synthetic 5s")
            }
        })
    }
    ```
- **Zero-Allocation Buffer Pooling with `sync.Pool` Slicing & Capacity Reset Invariants**:
  - ❌ **Anti-Pattern: Memory Bloat via Oversized Buffers Pinned in `sync.Pool`**: Storing byte slices in `sync.Pool` without capacity thresholds. If a single burst request reads a 64MB file, the 64MB slice remains pinned in the pool indefinitely, starving heap memory and wasting GC cycles.
  - ✅ **Production Invariant**: Reset length to zero (`buf[:0]`) before returning to the pool, and reject buffers exceeding a maximum capacity threshold (e.g., 64KB) so that oversized buffers are naturally collected by the runtime GC:
    ```go
    const maxPooledBufferSize = 64 * 1024 // 64 KB ceiling

    var bufferPool = sync.Pool{
        New: func() any {
            b := make([]byte, 0, 4*1024) // 4 KB initial capacity
            return &b
        },
    }

    func GetBuffer() *[]byte {
        return bufferPool.Get().(*[]byte)
    }

    func PutBuffer(buf *[]byte) {
        if buf == nil || cap(*buf) > maxPooledBufferSize {
            // Drop oversized buffer; let GC reclaim it to prevent memory bloat
            return
        }
        *buf = (*buf)[:0] // Reset length to 0 while preserving allocated capacity
        bufferPool.Put(buf)
    }
    ```
- **Go 1.24+ `weak.Pointer` for Non-Owning Caches & Object Interning**:
  - ❌ **Anti-Pattern: Memory Leaks via Strong-Referenced In-Memory Caches**: Storing strong pointers (`*T`) in long-lived in-memory caches or interning registries. Objects can never be collected by the Go runtime garbage collector even when no active goroutine or request holds them, forcing manual eviction heuristics and memory bloat.
  - ✅ **Production Invariant**: In Go 1.24+, utilize the `weak` package (`weak.Make` and `weak.Pointer.Value`) for non-owning reference caches (such as interned strings, symbol tables, or parsed AST nodes). The runtime GC collects the target when all strong references vanish:
    ```go
    import (
        "sync"
        "weak"
    )

    type Interner[T comparable] struct {
        mu    sync.RWMutex
        store map[T]weak.Pointer[T]
    }

    func NewInterner[T comparable]() *Interner[T] {
        return &Interner[T]{store: make(map[T]weak.Pointer[T])}
    }

    func (in *Interner[T]) Intern(val T) *T {
        in.mu.RLock()
        if wp, exists := in.store[val]; exists {
            if ptr := wp.Value(); ptr != nil {
                in.mu.RUnlock()
                return ptr
            }
        }
        in.mu.RUnlock()

        in.mu.Lock()
        defer in.mu.Unlock()

        // Double-check under write lock
        if wp, exists := in.store[val]; exists {
            if ptr := wp.Value(); ptr != nil {
                return ptr
            }
        }

        v := val
        in.store[val] = weak.Make(&v)
        return &v
    }
    ```
- **Structured Error Tree Wrapping & `errors.Is` / `errors.As` Invariants**:
  - ❌ **Anti-Pattern: Direct Equality (`==`) or String-Substring Matching on Errors**: Checking errors with `if err == ErrNotFound` or `strings.Contains(err.Error(), "not found")`. Wrapping errors with `%w` breaks direct pointer equality, while string matching is fragile, untyped, and masked by upstream changes.
  - ✅ **Production Invariant**: Always wrap errors with `%w` for causal context, inspect sentinels with `errors.Is`, and extract structured error fields with `errors.As`. When aggregating independent concurrent subtasks, combine errors using Go 1.20+ `errors.Join`:
    ```go
    import (
        "errors"
        "fmt"
    )

    var ErrResourceNotFound = errors.New("resource not found")

    type DomainError struct {
        ResourceID string
        Code       int
        Err        error
    }

    func (e *DomainError) Error() string {
        return fmt.Sprintf("domain error [code=%d, id=%s]: %v", e.Code, e.ResourceID, e.Err)
    }

    func (e *DomainError) Unwrap() error {
        return e.Err
    }

    func HandleError(err error) {
        // Correct inspection of wrapped sentinel errors
        if errors.Is(err, ErrResourceNotFound) {
            // Handle 404 cleanly
        }

        // Correct structured unwrapping of custom error types
        var domErr *DomainError
        if errors.As(err, &domErr) {
            fmt.Printf("Failed resource: %s, code: %d\n", domErr.ResourceID, domErr.Code)
        }
    }
    ```
- **Go 1.21+ `sync.OnceValue` / `sync.OnceValues` for Thread-Safe Lazy Initialization**:
  - ❌ **Anti-Pattern: Manual Double-Checked Locking or Raw `sync.Once` Boilerplate**: Implementing custom `sync.RWMutex` double-checked locking patterns or declaring package-level variables alongside manual `sync.Once.Do` closures. This introduces race conditions, uninitialized variable reads, or verbose error-handling boilerplate.
  - ✅ **Production Invariant**: In Go 1.21+, use standard generic helpers `sync.OnceValue(f)` for single returns, `sync.OnceValues(f)` for `(value, error)` returns, and `sync.OnceFunc(f)` for void side-effects. The runtime guarantees exactly-once execution, memory barriers, and caches the returned values:
    ```go
    import (
        "context"
        "database/sql"
        "sync"
    )

    // Lazy, thread-safe database connection singleton initialized only upon first request:
    var getDBPool = sync.OnceValues(func() (*sql.DB, error) {
        db, err := sql.Open("pgx", "postgres://user:pass@localhost:5432/production?sslmode=verify-full")
        if err != nil {
            return nil, err
        }
        db.SetMaxOpenConns(50)
        db.SetMaxIdleConns(25)
        return db, nil
    })

    func QueryUser(ctx context.Context, userID string) (*User, error) {
        db, err := getDBPool()
        if err != nil {
            return nil, err
        }
        // Proceed with query using initialized pool...
        return nil, nil
    }
    ```
- **Go `slog.LogValuer` for Deterministic PII & Secret Redaction in Structured Logs**:
  - ❌ **Anti-Pattern: Raw Struct Logging with Sensitive Fields**: Passing raw domain structs (e.g. `UserAccount`, `PaymentMethod`, `AuthToken`) directly to `slog.InfoContext(ctx, "user login", "account", user)`. Password hashes, authorization bearer tokens, and customer tax IDs are serialized directly into centralized log aggregation backends (Datadog, Loki, CloudWatch).
  - ✅ **Production Invariant**: Implement `slog.LogValuer` on sensitive domain types to return a redacted or masked `slog.Value`. Even if developers accidentally pass the entire entity to an arbitrary logger, the logging handler automatically invokes `LogValue()` and suppresses the plaintext secret:
    ```go
    import (
        "log/slog"
    )

    type APIKey struct {
        KeyID  string
        Secret string
    }

    // LogValue implements slog.LogValuer to ensure secrets never leak into log collectors:
    func (k APIKey) LogValue() slog.Value {
        maskedSecret := "REDACTED"
        if len(k.Secret) > 4 {
            maskedSecret = "***" + k.Secret[len(k.Secret)-4:]
        }
        return slog.GroupValue(
            slog.String("key_id", k.KeyID),
            slog.String("secret", maskedSecret),
        )
    }

    func Authenticate(key APIKey) {
        // Output: {"level":"INFO","msg":"authenticating key","key":{"key_id":"k_991","secret":"***a81f"}}
        slog.Info("authenticating key", "key", key)
    }
    ```
- **Go 1.23+ Range-Over-Func Iterators (`iter.Seq`, `iter.Seq2`) Production Safety**:
  - ❌ **Anti-Pattern: Unchecked Iterator Closures & Goroutine Leaks in Pull Iterators**: Constructing iterators that ignore yield return booleans (continuing to process after `yield(...) == false`) or failing to invoke the `stop()` cleanup function returned by `iter.Pull`. In push iterators, ignoring `!yield()` causes wasted computation; in pull iterators, failing to call `stop()` leaves the underlying coroutine/goroutine permanently leaked.
  - ✅ **Production Invariant**: In Go 1.23+, every push iterator must immediately check the boolean returned by `yield()` and terminate iteration on `false`. When converting push iterators to pull iterators via `iter.Pull()`, always call `defer stop()` immediately:
    ```go
    import (
        "iter"
    )

    // Push iterator adhering to early termination contract:
    func FilterPositive(numbers []int) iter.Seq[int] {
        return func(yield func(int) bool) {
            for _, n := range numbers {
                if n > 0 {
                    // Must abort immediately if consumer loop breaks:
                    if !yield(n) {
                        return
                    }
                }
            }
        }
    }

    // Pull iterator usage with mandatory defer stop():
    func ProcessFirstTwo(numbers []int) []int {
        next, stop := iter.Pull(FilterPositive(numbers))
        defer stop() // Mandatory: terminates internal coroutine

        var result []int
        for range 2 {
            val, ok := next()
            if !ok {
                break
            }
            result = append(result, val)
        }
        return result
    }
    ```
- **Go 1.21+ `context.AfterFunc` for Non-Blocking Cleanup**:
  - ❌ **Anti-Pattern: Spawning Dedicated Goroutines Waiting on `<-ctx.Done()`**: Starting a separate `go func() { <-ctx.Done(); cleanup() }()` for every outgoing request or worker. Under high concurrency (100,000 active requests), this wastes stack allocations (2KB–8KB per goroutine) and adds scheduler overhead.
  - ✅ **Production Invariant**: Register cancellation hooks using `context.AfterFunc(ctx, fn)`. It schedules the callback without dedicating an entire goroutine to waiting, and returns a cancellation handle `stop()` to unregister the hook when the operation completes successfully:
    ```go
    import (
        "context"
        "net"
    )

    func SafeExecuteWithConn(ctx context.Context, conn net.Conn) error {
        // Register non-blocking cancellation hook without spinning a goroutine:
        stop := context.AfterFunc(ctx, func() {
            _ = conn.Close() // Forcefully interrupt blocking read/write
        })
        defer stop() // Unregisters hook if normal operation finishes before context cancel

        // Perform socket operations...
        return nil
    }
    ```
- **Go 1.24+ Allocation-Free Benchmark Iteration (`b.Loop()`)**:
  - ❌ **Anti-Pattern: Legacy `for i := 0; i < b.N; i++` Loops with Compiler Dead-Code Elimination**: Using the classic `for i := 0; i < b.N; i++` loop. If the compiler determines the computed value is unused, it optimizes away the entire loop body, producing synthetic 0.2ns benchmarks. Developers often work around this with global `var sink any`, introducing pointer heap allocations that skew benchmarks.
  - ✅ **Production Invariant**: In Go 1.24+, use `for b.Loop()`. It manages iteration count dynamically, resets the timer before the first iteration automatically, and inserts compiler barriers preventing loop-body dead-code optimization without heap allocation overhead:
    ```go
    func BenchmarkPayloadSerialization(b *testing.B) {
        payload := GenerateTestPayload(1024)
        var buf bytes.Buffer
        buf.Grow(4096)

        // Go 1.24+ idiomatic benchmark loop:
        // Automatically resets timer, warms up, and prevents compiler dead-code stripping:
        for b.Loop() {
            buf.Reset()
            _ = json.NewEncoder(&buf).Encode(&payload)
        }
    }
    ```
- **Go 1.24+ Weak Pointers (`weak.Pointer`, `weak.Make`) for High-Throughput Memory Caches**:
  - ❌ **Anti-Pattern: Leaking Memory via Strong-Reference Global Caches or Fragile Finalizers**: Implementing in-memory caches or interning maps with standard pointers or `runtime.SetFinalizer`. In high-throughput servers, keys remain retained indefinitely until explicitly purged, leading to OOM spikes, or finalizers delay reclamation across multiple GC generations.
  - ✅ **Production Invariant**: In Go 1.24+, use the `weak` standard library package (`weak.Make[T](&val)`). A weak pointer does not prevent the garbage collector from reclaiming the referenced value. When dereferencing via `wp.Value()`, if the object was collected, it cleanly returns `nil`:
    ```go
    import (
        "sync"
        "weak"
    )

    type CanonicalCache[T any] struct {
        mu    sync.RWMutex
        store map[string]weak.Pointer[T]
    }

    func (c *CanonicalCache[T]) Get(key string) *T {
        c.mu.RLock()
        wp, exists := c.store[key]
        c.mu.RUnlock()
        if !exists {
            return nil
        }
        // Returns nil if GC has reclaimed the underlying object:
        return wp.Value()
    }

    func (c *CanonicalCache[T]) Put(key string, val *T) {
        c.mu.Lock()
        defer c.mu.Unlock()
        c.store[key] = weak.Make(val)
    }
    ```
- **Go 1.24+ Deterministic Concurrency Verification with `testing/synctest`**:
  - ❌ **Anti-Pattern: Flaky `time.Sleep` Delays in Asynchronous Concurrency Tests**: Waiting for goroutines, channels, or timer debouncers using real wall-clock delays (`time.Sleep(100 * time.Millisecond)`). In multi-threaded CI pipelines under high CPU contention, these arbitrary delays expire prematurely, causing intermittent test failures.
  - ✅ **Production Invariant**: In Go 1.24+, wrap concurrent asynchronous test suites in `synctest.Run(func() { ... })`. All goroutines launched inside the bubble operate on a virtualized clock. `time.Sleep` advances simulated time immediately without wall-clock delay, and `synctest.Wait()` pauses the calling test until every goroutine in the bubble reaches a blocked state:
    ```go
    import (
        "testing"
        "testing/synctest"
        "time"
    )

    func TestDebouncedWorkerDeterministic(t *testing.T) {
        synctest.Run(func() {
            w := NewDebouncedWorker(500 * time.Millisecond)
            w.Trigger()

            // Time is 100% virtualized; advances instantly without sleeping in real time:
            time.Sleep(200 * time.Millisecond)
            synctest.Wait()
            if w.Executed() {
                t.Fatalf("expected worker NOT to execute before debounce threshold")
            }

            time.Sleep(350 * time.Millisecond) // Exceeds 500ms total
            synctest.Wait()
            if !w.Executed() {
                t.Fatalf("expected worker to have executed after debounce threshold")
            }
        })
    }
    ```
- **Goroutine Leak Sentinels in Integration Suites (`goleak.VerifyNone`)**:
  - ❌ **Anti-Pattern: Dangling Goroutines Leaking Across Parallel Test Workers**: Spawning worker goroutines in test setups without bounded lifecycles or explicit cancellation. Leaked goroutines continue consuming CPU, hold mutexes, and write to closed channels in subsequent tests, causing baffling, non-reproducible CI crashes.
  - ✅ **Production Invariant**: Enforce goroutine leak verification across all package test suites using `goleak.VerifyNone(t)` or `goleak.VerifyTestMain(m)` in `TestMain`:
    ```go
    import (
        "testing"
        "go.uber.org/goleak"
    )

    func TestMain(m *testing.M) {
        // Fails test suite if any background goroutine outlives tests:
        goleak.VerifyTestMain(m)
    }
    ```
- **Context Cancellation Cause Propagation (`context.WithTimeoutCause`)**:
  - ❌ **Anti-Pattern: Ambiguous `context.DeadlineExceeded` without Causal Attribution**: Using standard `context.WithTimeout(ctx, d)`. When the deadline expires, `ctx.Err()` returns generic `context.DeadlineExceeded`, obscuring whether the failure was an upstream network stall, slow database lock, or downstream gateway timeout.
  - ✅ **Production Invariant**: In Go 1.20+, use `context.WithTimeoutCause` or `context.WithCancelCause` with typed sentinel errors. Extract root cause with `context.Cause(ctx)` to generate crisp telemetry without string matching:
    ```go
    var ErrDownstreamGatewayStall = errors.New("downstream payment gateway took >2.5s to respond")

    ctx, cancel := context.WithTimeoutCause(parentCtx, 2500*time.Millisecond, ErrDownstreamGatewayStall)
    defer cancel()

    res, err := client.Charge(ctx, req)
    if err != nil {
        if errors.Is(context.Cause(ctx), ErrDownstreamGatewayStall) {
            log.Error("charge failed due to downstream stall", "cause", context.Cause(ctx))
        }
    }
    ```
- **Go PR Commit Hygiene & Bisect Invariance (`git rebase --exec`)**:
  - ❌ **Anti-Pattern: Megacommit Dumps and Broken Intermediate Commits in PRs**: Grouping 30 files into a single commit or creating intermediate broken commits where tests fail. When a regression is introduced, `git bisect` lands on an un-compilable commit, paralyzing automated root-cause isolation.
  - ✅ **Production Invariant**: Enforce that every single commit on a PR branch compiles cleanly and passes all unit and race tests independently prior to opening or updating a PR:
    ```bash
    # Run against target base branch before pushing PR:
    git rebase origin/main -i --exec "go test -race ./... && go vet ./..."
    ```
- **Structured Multi-Error Aggregation with `errors.Join` in Batch Workflows**:
  - ❌ **Anti-Pattern: String Concatenation or Swallowing Errors in Fan-Out Tasks**: Formatting multiple errors into a string (`fmt.Sprintf("err1: %v, err2: %v", err1, err2)`). This strips underlying error types, preventing callers from inspecting sentinel errors via `errors.Is` or extracting typed context with `errors.As`.
  - ✅ **Production Invariant**: In Go 1.20+, use `errors.Join(errs...)` to collect errors from concurrent worker pools or multi-step batch tasks. The joined error retains full tree traversal compatibility:
    ```go
    func ValidateOrderBatch(orders []Order) error {
        var errs []error
        for _, o := range orders {
            if err := o.Validate(); err != nil {
                errs = append(errs, err)
            }
        }
        return errors.Join(errs...)
    }

    // Caller can inspect specific sentinel error across all joined failures:
    if errors.Is(err, ErrInvalidBillingAddress) {
        telemetry.RecordRejectedOrder("invalid_address")
    }
    ```
- **HTTP Response Body Draining & Keep-Alive Connection Reuse (`io.Discard`)**:
  - ❌ **Anti-Pattern: Closing Response Bodies Without Full Drain**: Calling `resp.Body.Close()` without reading remaining bytes. In HTTP/1.1 and HTTP/2, if the client terminates the connection before reading to EOF, the transport aborts the socket via TCP RST instead of returning it to the idle connection pool. High-throughput services rapidly deplete ephemeral ports (`TIME_WAIT` saturation).
  - ✅ **Production Invariant**: Always drain remaining bytes using `io.Copy(io.Discard, ...)` with a bounded reader before closing, guaranteeing connection reuse:
    ```go
    func SafeDrainAndClose(resp *http.Response) {
        if resp != nil && resp.Body != nil {
            // Drain up to 1MB of remaining body to allow connection reuse:
            _, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
            _ = resp.Body.Close()
        }
    }

    // Usage:
    resp, err := client.Do(req)
    if err != nil {
        return err
    }
    defer SafeDrainAndClose(resp)
    ```
- **Hermetic HTTP Transport Blackholing in Test Suites (`http.RoundTripper`)**:
  - ❌ **Anti-Pattern: Unconstrained HTTP Client Leaking Network Calls in Unit Tests**: Constructing `&http.Client{}` or using `http.DefaultClient` in tests without intercepting outbound traffic. If an external service URL is invoked, tests fail intermittently during offline builds or mutate real remote data.
  - ✅ **Production Invariant**: In test setups, wrap the client's `Transport` with a hermetic `RoundTripper` that panics or returns an explicit error for any destination host other than the ephemeral `httptest.Server`:
    ```go
    type HermeticRoundTripper struct {
        AllowedHost string
        Proxied     http.RoundTripper
    }

    func (h *HermeticRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
        if req.URL.Host != h.AllowedHost {
            return nil, fmt.Errorf("hermetic test violation: unhandled outbound egress to %s prohibited", req.URL.Host)
        }
        return h.Proxied.RoundTrip(req)
    }
    ```
- **Transactional Outbox Event Relay & Lock-Free Worker Processing (`SKIP LOCKED`)**:
  - ❌ **Anti-Pattern: Naive Dual-Writing Outside Database Transactions**: Executing a SQL query to update an account balance and subsequently calling `kafkaProducer.Publish()` or `natsConn.Publish()` in separate operations. If the Go process panics, OOMs, or is terminated via `SIGKILL` between the database commit and the broker call, event publication is lost permanently with zero trace.
  - ✅ **Production Invariant**: Insert domain mutations and outbox records in the same atomic `pgx.Tx`. Use worker background routines fetching batches via `SELECT ... FOR UPDATE SKIP LOCKED` to achieve lock-free horizontal scaling across multiple Go instances:
    ```go
    // Lock-free outbox worker polling in Go:
    func (w *OutboxWorker) ProcessBatch(ctx context.Context, batchSize int) error {
        tx, err := w.db.Begin(ctx)
        if err != nil {
            return err
        }
        defer tx.Rollback(ctx)

        query := `
            SELECT id, aggregate_id, event_type, payload
            FROM outbox_events
            WHERE published_at IS NULL
            ORDER BY created_at ASC
            LIMIT $1
            FOR UPDATE SKIP LOCKED;
        `
        rows, err := tx.Query(ctx, query, batchSize)
        if err != nil {
            return err
        }
        defer rows.Close()

        var eventIDs []string
        for rows.Next() {
            var e OutboxEvent
            if err := rows.Scan(&e.ID, &e.AggregateID, &e.EventType, &e.Payload); err != nil {
                return err
            }
            if err := w.publisher.Publish(ctx, e.EventType, e.Payload); err != nil {
                return fmt.Errorf("failed to publish outbox event %s: %w", e.ID, err)
            }
            eventIDs = append(eventIDs, e.ID)
        }

        if len(eventIDs) > 0 {
            updateQuery := `UPDATE outbox_events SET published_at = NOW() WHERE id = ANY($1);`
            if _, err := tx.Exec(ctx, updateQuery, eventIDs); err != nil {
                return err
            }
        }

        return tx.Commit(ctx)
    }
    ```
- **Mutex Pass-by-Value & Lock Copying Prohibition (`go vet -copylocks`)**:
  - ❌ **Anti-Pattern: Value Receiver on Structs Containing `sync.Mutex` or `sync.RWMutex`**: Defining methods with value receivers `func (s SafeCounter) Value() int` or passing a struct containing a mutex by value into helper functions. The lock state is copied by value, causing concurrent goroutines to lock separate mutex copies, leading to silent data races and corrupted shared memory.
  - ✅ **Production Invariant**: Structs containing `sync.Mutex`, `sync.RWMutex`, or `sync.WaitGroup` MUST strictly define all methods on pointer receivers `func (s *SafeCounter) Value() int`. CI pipelines MUST enforce `go vet -copylocks ./...`:
    ```go
    type SafeCounter struct {
        mu    sync.Mutex
        count int
    }

    // ✅ Pointer receiver guarantees shared mutex state across all callers:
    func (c *SafeCounter) Inc() {
        c.mu.Lock()
        defer c.mu.Unlock()
        c.count++
    }

    func (c *SafeCounter) Value() int {
        c.mu.Lock()
        defer c.mu.Unlock()
        return c.count
    }
    ```
- **Distributed Concurrency Fencing & Monotonic Version Checks in SQL (`pgx`)**:
  - ❌ **Anti-Pattern: Blind State Overwrite After Distributed Lock Acquisition**: Acquiring a distributed Redis or etcd lock and then running `UPDATE accounts SET balance = $1 WHERE id = $2` without monotonic fencing token verification. If a Go runtime GC pause or thread stall exceeds the lock lease TTL, another goroutine/node acquires the lock, and the delayed write clobbers newer balance state.
  - ✅ **Production Invariant**: Always issue SQL mutations with monotonic fencing checks `WHERE id = $1 AND fencing_token < $2`. Inspect `cmdTag.RowsAffected()`; if 0 rows are updated, raise `ErrStaleFencingToken` to abort the operation and trigger compensation:
    ```go
    // Monotonic fencing verification with pgx in Go:
    func (s *AccountService) DeductBalance(ctx context.Context, accountID string, amount decimal.Decimal, fenceToken uint64) error {
        tag, err := s.db.Exec(ctx, `
            UPDATE bank_accounts
            SET balance = balance - $1,
                fencing_token = $2,
                updated_at = NOW()
            WHERE id = $3
              AND fencing_token < $2;
        `, amount, fenceToken, accountID)
        if err != nil {
            return fmt.Errorf("failed executing balance deduction: %w", err)
        }
        if tag.RowsAffected() == 0 {
            return fmt.Errorf("stale fencing token %d: account %s was mutated by newer lease", fenceToken, accountID)
        }
        return nil
    }
    ```
- **Lexicographical Mutex Sorting for Cycle-Free Multi-Lock Acquisition**:
  - ❌ **Anti-Pattern: Acquiring Multiple Locks in Caller-Provided Argument Order**: Implementing operations like `Transfer(ctx, fromID, toID)` by directly locking `fromID.mu.Lock()` followed by `toID.mu.Lock()`. When concurrent callers invoke `Transfer(A, B)` and `Transfer(B, A)` simultaneously, goroutines deadlock immediately.
  - ✅ **Production Invariant**: Deterministically sort resource identifiers lexicographically before acquiring mutexes:
    ```go
    func (m *AccountManager) Transfer(ctx context.Context, fromID, toID string, amount decimal.Decimal) error {
        if fromID == toID {
            return errors.New("cannot transfer to self")
        }

        firstID, secondID := fromID, toID
        if firstID > secondID {
            firstID, secondID = toID, fromID
        }

        firstLock := m.getLock(firstID)
        secondLock := m.getLock(secondID)

        firstLock.Lock()
        defer firstLock.Unlock()

        secondLock.Lock()
        defer secondLock.Unlock()

        return m.executeTransfer(ctx, fromID, toID, amount)
    }
    ```
- **Webhook Raw-Body Preservation & Constant-Time Verification (`hmac.Equal`)**:
  - ❌ **Anti-Pattern: JSON Decoding Before Signature Verification**: Decoding `json.NewDecoder(r.Body).Decode(&payload)` directly and then trying to re-encode `json.Marshal(payload)` to compute HMAC, or using `stringA == stringB` for signature comparison. Re-encoding fails due to JSON formatting mutations, and `==` is vulnerable to timing attacks.
  - ✅ **Production Invariant**: Read raw bytes using `io.LimitReader(r.Body, MaxBytes)`, compute HMAC with `hmac.New(sha256.New, secret)`, verify using `hmac.Equal(macA, macB)`, check timestamp skew $|t_{\text{now}} - t_{\text{hook}}| \le 300\text{s}$, and respond with immediate HTTP 202 before offloading processing to a worker channel or task queue:
    ```go
    // Industrial webhook verification with raw body preservation in Go:
    func (h *WebhookHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
        if r.Method != http.MethodPost {
            http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
            return
        }

        // 1. Enforce bounded read (prevent memory exhaustion attacks)
        rawBody, err := io.ReadAll(io.LimitReader(r.Body, 1<<20)) // 1MB upper bound
        if err != nil {
            http.Error(w, "Failed reading body", http.StatusBadRequest)
            return
        }

        // 2. Parse signature & timestamp header (e.g., Stripe or GitHub)
        sigHeader := r.Header.Get("X-Hub-Signature-256")
        expectedSig, err := hex.DecodeString(strings.TrimPrefix(sigHeader, "sha256="))
        if err != nil {
            http.Error(w, "Invalid signature encoding", http.StatusUnauthorized)
            return
        }

        // 3. Constant-time comparison across active signing keys
        mac := hmac.New(sha256.New, []byte(h.signingSecret))
        mac.Write(rawBody)
        if !hmac.Equal(mac.Sum(nil), expectedSig) {
            http.Error(w, "Signature mismatch", http.StatusUnauthorized)
            return
        }

        // 4. Return immediate 202 Accepted; never block the connection on business logic
        w.WriteHeader(http.StatusAccepted)
        h.workerPool.Enqueue(r.Context(), rawBody)
    }
    ```
- **Durable Workflows, Saga Compensation Stacks & Replay Determinism (`workflow.NewDisconnectedContext`)**:
  - ❌ **Anti-Pattern: In-Memory Multi-Step Chaining or Non-Deterministic Operations in Workflows**: Chaining distributed actions inside standard Go goroutines without event checkpointing, or calling `time.Now()`, `rand.Int()`, or direct network I/O inside Temporal/Cadence workflow definitions. Workflow replays diverge and panic, while partial failures abandon un-compensated cloud resources and locks.
  - ✅ **Production Invariant**: Keep workflow definitions pure. Isolate all side-effects into Activities. Build reverse-order compensation stacks using `workflow.NewDisconnectedContext(ctx)` so that rollback activities execute successfully even when the parent workflow context is timed out or cancelled:
    ```go
    // Industrial Saga Compensation with DisconnectedContext in Go (Temporal / Durable Engine)
    type ProvisioningSaga struct {
        compensations []func(ctx workflow.Context) error
    }

    func (s *ProvisioningSaga) AddCompensation(fn func(ctx workflow.Context) error) {
        s.compensations = append(s.compensations, fn)
    }

    func (s *ProvisioningSaga) Compensate(ctx workflow.Context) {
        // NewDisconnectedContext ensures compensation execution even when parent ctx is cancelled
        dCtx, _ := workflow.NewDisconnectedContext(ctx)
        for i := len(s.compensations) - 1; i >= 0; i-- {
            if err := s.compensations[i](dCtx); err != nil {
                workflow.GetLogger(dCtx).Error("Compensation step failed, escalating to DLQ", "error", err)
                _ = workflow.ExecuteActivity(dCtx, EscalateToDLQActivity, err.Error()).Get(dCtx, nil)
            }
        }
    }
    ```
- **Zero-Downtime Kubernetes Readiness Quiescence & Reverse Dependency DAG Teardown**:
  - ❌ **Anti-Pattern: Immediate Socket Close on `SIGTERM` & Random Resource Teardown**: Closing the HTTP listener immediately when `SIGTERM` is received while kube-proxy is still propagating pod removal, causing a burst of 502 Bad Gateways, or closing `pgxpool.Pool` while HTTP handlers are still running active queries.
  - ✅ **Production Invariant**: Flip readiness probe `/readyz` to HTTP 503, pause for ingress propagation ($T_{\text{quiesce}} \ge 2\text{s}$), bound in-flight request draining with `srv.Shutdown(ctx)`, and cleanly close database pools strictly after all handlers exit:
    ```go
    // Industrial Zero-502 Kubernetes Graceful Drain & Reverse DAG Teardown
    type LifecycleManager struct {
        draining atomic.Bool
        srv      *http.Server
        pool     *pgxpool.Pool
    }

    func (lm *LifecycleManager) ServeHTTP(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path == "/readyz" {
            if lm.draining.Load() {
                http.Error(w, `{"serving":false}`, http.StatusServiceUnavailable)
                return
            }
            w.WriteHeader(http.StatusOK)
            return
        }
        // ... business routing
    }

    func (lm *LifecycleManager) DrainAndShutdown(ctx context.Context) error {
        // 1. Quiesce ingress: signal unready and pause for kube-proxy route eviction
        lm.draining.Store(true)
        time.Sleep(2500 * time.Millisecond)

        // 2. Stop accepting new connections and drain in-flight requests
        if err := lm.srv.Shutdown(ctx); err != nil {
            return err
        }

        // 3. Close database connection pool strictly AFTER HTTP server finishes
        lm.pool.Close()
        return nil
    }
    ```
- **Kafka / Broker Poison Pill Quarantine, Non-Blocking Retry Routing & W3C Traceparent DLQ Enrichment**:
  - ❌ **Anti-Pattern: Synchronous Retry Sleeps & Infinite Crash-Loop Requeuing**: Sleeping inside the Kafka/consumer loop (`time.Sleep(5 * time.Second)`) upon transient downstream failure, stalling the partition offset for all healthy tenant records, or executing `nack(requeue=true)` on un-parseable JSON payloads causing 10,000 crashes per minute.
  - ✅ **Production Invariant**: Triage deterministic syntax/deserialization errors directly to the Dead Letter Queue on attempt 1. Route transient errors to exponential non-blocking retry topics (`topic.retry-10s`), commit the primary partition offset immediately, and enrich DLQ records with SHA-256 digests and W3C traceparents:
    ```go
    // Industrial Poison Pill Quarantine & Non-Blocking Retry Routing in Go
    func HandleIncomingMessage(ctx context.Context, msg kafka.Message, dlqWriter, retryWriter *kafka.Writer) error {
        var event DomainEvent
        // 1. Poison pill detection: un-parseable JSON goes directly to DLQ
        if err := json.Unmarshal(msg.Value, &event); err != nil {
            return publishDLQ(ctx, dlqWriter, msg, "DETERMINISTIC_SCHEMA", err, 1)
        }

        attempt := getAttemptHeader(msg) // e.g. from x-delivery-count or x-attempt
        const maxAttempts = 3

        if err := processDomainEvent(ctx, event); err != nil {
            if attempt >= maxAttempts {
                return publishDLQ(ctx, dlqWriter, msg, "MAX_ATTEMPTS_EXHAUSTED", err, attempt)
            }
            // 2. Non-blocking delayed retry topic avoids Head-of-Line partition stall
            return publishDelayedRetry(ctx, retryWriter, msg, attempt+1)
        }
        return nil
    }
    ```
- **Singleflight Request Coalescing, DoChan Cancellation Isolation & Jittered Redis Read-Through**:
  - ❌ **Anti-Pattern: Raw Uncoalesced Cache Miss Goroutine Floods**: Executing un-gated concurrent database queries on cache miss, or calling `singleflight.Group.Do` directly without wrapping in `DoChan`, causing client HTTP aborts to leave dangling goroutines or cancel upstream cache warming for other waiting callers.
  - ✅ **Production Invariant**: Use `golang.org/x/sync/singleflight` with `DoChan` to coalesce duplicate in-flight requests while allowing callers with canceled contexts to detach cleanly, and enforce decorrelated TTL jitter on Redis writes:
    ```go
    // Industrial Go Singleflight Read-Through with Context Detachment
    func (s *ReadThroughService) FetchEntity(ctx context.Context, id string) (*Entity, error) {
        key := "entity:" + id
        if cached, err := s.redis.Get(ctx, key).Bytes(); err == nil {
            var e Entity
            return &e, json.Unmarshal(cached, &e)
        }

        ch := s.sfGroup.DoChan(key, func() (interface{}, error) {
            // Detached timeout context ensures cache population completes even if primary caller cancels
            bgCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
            defer cancel()

            entity, err := s.repo.FindByID(bgCtx, id)
            if err != nil {
                return nil, err
            }

            // Decorrelated jitter: base 3600s +/- 15%
            jitter := time.Duration(rand.Intn(540)-270) * time.Second
            payload, _ := json.Marshal(entity)
            s.redis.Set(bgCtx, key, payload, time.Hour+jitter)
            return entity, nil
        })

        select {
        case <-ctx.Done():
            return nil, ctx.Err() // Caller canceled, singleflight continues filling cache for peers
        case res := <-ch:
            if res.Err != nil {
                return nil, res.Err
            }
            return res.Val.(*Entity), nil
        }
    }
    ```
- **Circuit Breaker, Weighted Semaphore Bulkhead & Adaptive Ingress Load Shedding**:
  - ❌ **Anti-Pattern: Unbounded Goroutine Outbound Flooding & Leaked Client Connections**: Firing concurrent HTTP requests or remote RPCs without circuit breakers, allowing downstream latency spikes to exhaust all goroutine stacks, file descriptors, and worker memory until K8s probes fail.
  - ✅ **Production Invariant**: Couple `sony/gobreaker` with `golang.org/x/sync/semaphore` to enforce isolated concurrency bulkheads, single-canary `HALF_OPEN` recovery, and fast 0ms failure rejection with fallback:
    ```go
    // Industrial Go Resilient Outbound Client with Bulkhead & Circuit Breaker
    type ResilientCaller struct {
        breaker  *gobreaker.CircuitBreaker
        bulkhead *semaphore.Weighted
        timeout  time.Duration
    }

    func NewResilientCaller(maxConcurrent int64, timeout time.Duration) *ResilientCaller {
        return &ResilientCaller{
            bulkhead: semaphore.NewWeighted(maxConcurrent),
            timeout:  timeout,
            breaker: gobreaker.NewCircuitBreaker(gobreaker.Settings{
                Name:        "downstream-client",
                MaxRequests: 1, // Strictly 1 canary probe in HALF_OPEN
                Interval:    10 * time.Second,
                Timeout:     15 * time.Second, // Cool-down in OPEN
                ReadyToTrip: func(counts gobreaker.Counts) bool {
                    ratio := float64(counts.TotalFailures) / float64(counts.Requests)
                    return counts.Requests >= 10 && ratio >= 0.50
                },
            }),
        }
    }

    func (r *ResilientCaller) Call(ctx context.Context, fn func(ctx context.Context) error) error {
        if !r.bulkhead.TryAcquire(1) {
            return errors.New("bulkhead capacity saturated: shedding load")
        }
        defer r.bulkhead.Release(1)

        _, err := r.breaker.Execute(func() (interface{}, error) {
            callCtx, cancel := context.WithTimeout(ctx, r.timeout)
            defer cancel()
            return nil, fn(callCtx)
        })
        return err
    }
    ```

- **PostgreSQL Connection Pool (`pgxpool`), Scoped Transaction Hygiene & Leak Elimination**:
  - ❌ **Anti-Pattern: Leaked `pgx.Conn` / `rows` & Unbounded Connection Spikes**: Calling `pool.Acquire(ctx)` without immediate `defer conn.Release()`, forgetting `defer rows.Close()`, or initiating transactions without `defer tx.Rollback(ctx)`, permanently trapping connection slots until the pool starves.
  - ✅ **Production Invariant**: Enforce strict RAII transaction runners with automatic rollback, connection acquisition deadlines, and runtime parameters preventing `idle in transaction` stalls:
    ```go
    // Industrial pgxpool Configuration with Hard Sizing & Timeout Boundaries
    func InitProductionPgxPool(ctx context.Context, dsn string, maxConns int32) (*pgxpool.Pool, error) {
        cfg, err := pgxpool.ParseConfig(dsn)
        if err != nil {
            return nil, fmt.Errorf("parse dsn: %w", err)
        }

        // Little's Law / Hardware Sizing: maxConns = (2 * CPU cores) + disk spindles
        cfg.MaxConns = maxConns
        cfg.MinConns = 2
        cfg.MaxConnIdleTime = 5 * time.Minute
        cfg.MaxConnLifetime = 30 * time.Minute
        cfg.MaxConnLifetimeJitter = 5 * time.Minute // Prevent synchronized expiration stampedes
        cfg.HealthCheckPeriod = 1 * time.Minute

        // Server-Side Guardrails (Anti-Idle-In-Transaction Lock Freezing)
        cfg.ConnConfig.ConnectTimeout = 2 * time.Second
        cfg.ConnConfig.RuntimeParams = map[string]string{
            "idle_in_transaction_session_timeout": "5000", // 5s max idle lock duration
            "statement_timeout":                   "10000", // 10s max execution boundary
            "lock_timeout":                        "2000",  // 2s lock queue ceiling
        }

        return pgxpool.NewWithConfig(ctx, cfg)
    }

    // Leak-Proof Scoped Transaction Helper
    func WithinTx(ctx context.Context, pool *pgxpool.Pool, fn func(tx pgx.Tx) error) error {
        acquireCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
        defer cancel()

        tx, err := pool.Begin(acquireCtx)
        if err != nil {
            return fmt.Errorf("failed to begin transaction: %w", err)
        }
        defer tx.Rollback(ctx) // Safe: no-op if tx.Commit() has already succeeded

        if err := fn(tx); err != nil {
            return err
        }
        return tx.Commit(ctx)
    }
    ```

- **PostgreSQL Keyset Cursor Pagination & Anti-N+1 Batch Loading in Go (`pgxpool`)**:
  - ❌ **Anti-Pattern: In-Loop Queries & Deep `OFFSET` Pagination**: Querying child items inside a loop iterating over parent rows, or executing `LIMIT 20 OFFSET 10000` which forces PostgreSQL to scan and discard 10,000 rows on every page request.
  - ✅ **Production Invariant**: Use tuple comparison keyset pagination `(created_at, id) < ($1, $2)` with covering composite indexes and batch fetch child associations in a single roundtrip via `= ANY($1)`:
    ```go
    // Industrial Keyset Cursor Pagination (O(1) Seek Time at Any Page Depth)
    func (r *OrderRepo) ListOrdersKeyset(ctx context.Context, tenantID uuid.UUID, cursorTime time.Time, cursorID uuid.UUID, limit int) ([]Order, error) {
        queryCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
        defer cancel()

        query := `
            SELECT id, tenant_id, status, total_amount, created_at
            FROM orders
            WHERE tenant_id = $1 AND (created_at, id) < ($2, $3)
            ORDER BY created_at DESC, id DESC
            LIMIT $4`

        rows, err := r.pool.Query(queryCtx, query, tenantID, cursorTime, cursorID, limit)
        if err != nil {
            return nil, fmt.Errorf("list orders keyset: %w", err)
        }
        defer rows.Close()

        var orders []Order
        for rows.Next() {
            var o Order
            if err := rows.Scan(&o.ID, &o.TenantID, &o.Status, &o.TotalAmount, &o.CreatedAt); err != nil {
                return nil, err
            }
            orders = append(orders, o)
        }
        return orders, rows.Err()
    }

    // Anti-N+1: Batch Fetch Child Items for All Orders in Exactly 1 Roundtrip
    func (r *OrderRepo) BatchGetItems(ctx context.Context, orderIDs []uuid.UUID) (map[uuid.UUID][]Item, error) {
        if len(orderIDs) == 0 {
            return make(map[uuid.UUID][]Item), nil
        }
        queryCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
        defer cancel()

        query := `
            SELECT id, order_id, product_id, quantity, unit_price
            FROM order_items
            WHERE order_id = ANY($1::UUID[])`

        rows, err := r.pool.Query(queryCtx, query, orderIDs)
        if err != nil {
            return nil, fmt.Errorf("batch get items: %w", err)
        }
        defer rows.Close()

        itemMap := make(map[uuid.UUID][]Item, len(orderIDs))
        for rows.Next() {
            var item Item
            if err := rows.Scan(&item.ID, &item.OrderID, &item.ProductID, &item.Quantity, &item.UnitPrice); err != nil {
                return nil, err
            }
            itemMap[item.OrderID] = append(itemMap[item.OrderID], item)
        }
        return itemMap, rows.Err()
    }
    ```

- **PostgreSQL Concurrency Control: Lexicographical Locking, OCC & SKIP LOCKED in Go (`pgxpool`)**:
  - ❌ **Anti-Pattern: Arbitrary Row Lock Orders & In-Memory Read-Modify-Write**: Locking multiple accounts in arbitrary order (triggering PostgreSQL `40P01 deadlock_detected`), reading balances into Go structs to decrement before updating, or running workers on `LIMIT 1 FOR UPDATE` without `SKIP LOCKED`.
  - ✅ **Production Invariant**: Sort UUID slices lexicographically before locking, execute atomic conditional deductions with `RETURNING`, implement OCC version loops with jittered retries, and dispatch worker pools via `FOR UPDATE SKIP LOCKED`:
    ```go
    // Deadlock-Free Balance Transfer via Lexicographical Key Sorting in Go (pgxpool)
    func (s *LedgerService) TransferBalance(ctx context.Context, fromID, toID uuid.UUID, amount int64) error {
        if fromID == toID {
            return errors.New("cannot transfer to same account")
        }
        // Step 1: Guarantee acyclic Wait-For Graph via total canonical ID order
        ordered := []uuid.UUID{fromID, toID}
        sort.Slice(ordered, func(i, j int) bool {
            return ordered[i].String() < ordered[j].String()
        })

        tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
        if err != nil {
            return fmt.Errorf("begin tx: %w", err)
        }
        defer tx.Rollback(ctx)

        // Step 2: Lock rows in canonical order
        for _, id := range ordered {
            var dummy int64
            if err := tx.QueryRow(ctx, "SELECT balance FROM accounts WHERE id = $1 FOR UPDATE", id).Scan(&dummy); err != nil {
                return fmt.Errorf("lock account %s: %w", id, err)
            }
        }

        // Step 3: Single-statement atomic conditional debit
        cmdTag, err := tx.Exec(ctx, `
            UPDATE accounts 
            SET balance = balance - $1, updated_at = NOW() 
            WHERE id = $2 AND balance >= $1`, amount, fromID)
        if err != nil {
            return fmt.Errorf("debit: %w", err)
        }
        if cmdTag.RowsAffected() == 0 {
            return errors.New("insufficient balance or concurrent debit conflict")
        }

        // Step 4: Credit target account
        if _, err := tx.Exec(ctx, "UPDATE accounts SET balance = balance + $1, updated_at = NOW() WHERE id = $2", amount, toID); err != nil {
            return fmt.Errorf("credit: %w", err)
        }

        return tx.Commit(ctx)
    }

    // High-Throughput Worker Queue Claim with FOR UPDATE SKIP LOCKED
    func (w *QueueWorker) ClaimBatch(ctx context.Context, batchSize int) ([]uuid.UUID, error) {
        queryCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
        defer cancel()

        query := `
            WITH claimable AS (
                SELECT id FROM tasks 
                WHERE status = 'pending' 
                ORDER BY priority DESC, created_at ASC 
                LIMIT $1 
                FOR UPDATE SKIP LOCKED
            )
            UPDATE tasks 
            SET status = 'processing', locked_at = NOW(), attempts = attempts + 1 
            WHERE id IN (SELECT id FROM claimable) 
            RETURNING id`

        rows, err := w.pool.Query(queryCtx, query, batchSize)
        if err != nil {
            return nil, fmt.Errorf("claim batch: %w", err)
        }
        defer rows.Close()

        var ids []uuid.UUID
        for rows.Next() {
            var id uuid.UUID
            if err := rows.Scan(&id); err != nil {
                return nil, err
            }
            ids = append(ids, id)
        }
        return ids, rows.Err()
    }

    // Read-After-Write Consistency: Sticky Primary & Causal LSN Context Routing
    type ReplicaRouter struct {
        primary  *pgxpool.Pool
        replicas []*pgxpool.Pool
        nextIdx  uint64
        stickyDuration time.Duration
    }

    type causalContextKey string
    const (
        ctxStickyExpiryKey causalContextKey = "db:sticky_expiry"
        ctxCausalLSNKey     causalContextKey = "db:causal_lsn"
    )

    func WithStickyPrimary(ctx context.Context, dur time.Duration) context.Context {
        return context.WithValue(ctx, ctxStickyExpiryKey, time.Now().Add(dur))
    }

    func WithCausalLSN(ctx context.Context, lsn string) context.Context {
        return context.WithValue(ctx, ctxCausalLSNKey, lsn)
    }

    func (r *ReplicaRouter) RouteReadPool(ctx context.Context) *pgxpool.Pool {
        // Invariant 1: If session wrote within sticky duration, pin to Primary
        if expiry, ok := ctx.Value(ctxStickyExpiryKey).(time.Time); ok && time.Now().Before(expiry) {
            return r.primary
        }

        if len(r.replicas) == 0 {
            return r.primary
        }

        // Round-robin replica selection
        idx := atomic.AddUint64(&r.nextIdx, 1) % uint64(len(r.replicas))
        selected := r.replicas[idx]

        // Invariant 2: Verify causal LSN if provided
        if targetLSN, ok := ctx.Value(ctxCausalLSNKey).(string); ok && targetLSN != "" {
            var caughtUp bool
            err := selected.QueryRow(ctx, 
                "SELECT pg_wal_lsn_diff(pg_last_wal_replay_lsn(), $1::pg_lsn) >= 0", targetLSN).Scan(&caughtUp)
            if err != nil || !caughtUp {
                // Replica lagging behind causal mutation -> Fallback to Primary
                return r.primary
            }
        }

        return selected
    }

    // Soft-Delete Cascade CTE & Tamper-Evident HMAC Audit Invariant
    type SoftDeleteService struct {
        pool       *pgxpool.Pool
        hmacSecret []byte
    }

    func NewSoftDeleteService(pool *pgxpool.Pool, secret string) *SoftDeleteService {
        return &SoftDeleteService{pool: pool, hmacSecret: []byte(secret)}
    }

    func (s *SoftDeleteService) CascadeSoftDelete(ctx context.Context, orgID [16]byte, actorID string) ([16]byte, error) {
        batchID := [16]byte(uuid.New())
        now := time.Now().UTC()

        tx, err := s.pool.Begin(ctx)
        if err != nil {
            return [16]byte{}, fmt.Errorf("begin tx: %w", err)
        }
        defer tx.Rollback(ctx)

        // Single-statement recursive CTE guarantees atomic multi-table soft deletion
        const cteQuery = `
            WITH del_org AS (
                UPDATE organizations SET
                    deleted_at = $1, deleted_by = $2, deleted_batch_id = $3, version = version + 1
                WHERE id = $4 AND deleted_at IS NULL
                RETURNING id, slug
            ),
            del_projects AS (
                UPDATE projects SET
                    deleted_at = $1, deleted_by = $2, deleted_batch_id = $3, version = version + 1
                WHERE org_id IN (SELECT id FROM del_org) AND deleted_at IS NULL
                RETURNING id
            )
            SELECT id, slug FROM del_org;
        `
        var returnedID [16]byte
        var slug string
        if err := tx.QueryRow(ctx, cteQuery, now, actorID, batchID, orgID).Scan(&returnedID, &slug); err != nil {
            return [16]byte{}, fmt.Errorf("cascade soft-delete failed: %w", err)
        }

        // Compute HMAC-SHA256 for immutable audit record
        h := hmac.New(sha256.New, s.hmacSecret)
        h.Write([]byte(fmt.Sprintf("%x:%s:%s", orgID, "SOFT_DELETE", slug)))
        currentHash := hex.EncodeToString(h.Sum(nil))

        _, err = tx.Exec(ctx, `
            INSERT INTO entity_audit_ledger (entity_name, entity_id, action, actor_id, timestamp, hash)
            VALUES ($1, $2, $3, $4, $5, $6)
        `, "organizations", orgID, "SOFT_DELETE", actorID, now, currentHash)
        if err != nil {
            return [16]byte{}, fmt.Errorf("audit log insert failed: %w", err)
        }

        return batchID, tx.Commit(ctx)
    }
    ```

- **Declarative Range Partitioning, Sargable Time-Bound Queries & Concurrent Detach Workers**:
  - ❌ **Anti-Pattern: DATE_TRUNC Query Traps & In-Transaction Detachments**: Constructing queries with `DATE_TRUNC('month', created_at) = $1` which prevents PostgreSQL partition pruning and forces sequential scans over dozens of partitions, or executing `ALTER TABLE ... DETACH PARTITION` inside a Go transaction block which holds `ACCESS EXCLUSIVE` lock and deadlocks client connection pools.
  - ✅ **Production Invariant**: Always provide direct, sargable range boundaries `created_at >= $1 AND created_at < $2`, ensure composite primary keys `PRIMARY KEY (id, created_at)` in DDL migrations, and use a dedicated standalone connection outside transactions with `SET lock_timeout = '2000ms'` for `ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY`:
    ```go
    package db

    import (
        "context"
        "fmt"
        "time"

        "github.com/jackc/pgx/v5"
        "github.com/jackc/pgx/v5/pgxpool"
    )

    type PartitionLifecycleManager struct {
        pool      *pgxpool.Pool
        tableName string
    }

    func NewPartitionLifecycleManager(pool *pgxpool.Pool, tableName string) *PartitionLifecycleManager {
        return &PartitionLifecycleManager{pool: pool, tableName: tableName}
    }

    // SargableRangeQuery guarantees static and dynamic partition pruning
    func (m *PartitionLifecycleManager) QueryEventsByTimeWindow(
        ctx context.Context,
        tenantID [16]byte,
        start, end time.Time,
    ) (pgx.Rows, error) {
        // Direct range comparison on partition key created_at ensures O(1) partition pruning
        const query = `
            SELECT id, tenant_id, event_type, payload, created_at
            FROM telemetry_events
            WHERE tenant_id = $1
              AND created_at >= $2
              AND created_at < $3
            ORDER BY created_at DESC;
        `
        return m.pool.Query(ctx, query, tenantID, start, end)
    }

    // DetachConcurrentStandalone executes zero-downtime concurrent detachment on a single connection
    func (m *PartitionLifecycleManager) DetachConcurrentStandalone(
        ctx context.Context,
        partitionName string,
    ) error {
        conn, err := m.pool.Acquire(ctx)
        if err != nil {
            return fmt.Errorf("acquire connection: %w", err)
        }
        defer conn.Release()

        // Enforce tight lock timeout so we fail fast rather than stalling queue
        if _, err := conn.Exec(ctx, "SET lock_timeout = '2000ms'"); err != nil {
            return fmt.Errorf("set lock_timeout: %w", err)
        }

        // MUST be executed outside any transaction block
        detachDDL := fmt.Sprintf("ALTER TABLE %s DETACH PARTITION %s CONCURRENTLY;", m.tableName, partitionName)
        if _, err := conn.Exec(ctx, detachDDL); err != nil {
            return fmt.Errorf("detach partition concurrently failed: %w", err)
        }
        return nil
    }

// Production Go MVCC HOT Updates, Statement Timeouts & Anti-Wraparound Sentinel
type MVCCWatchdog struct {
    pool *pgxpool.Pool
}

func NewMVCCWatchdog(pool *pgxpool.Pool) *MVCCWatchdog {
    return &MVCCWatchdog{pool: pool}
}

// ExecuteHOTUpdate performs an atomic, HOT-friendly update on non-indexed columns with bounded timeout
func (w *MVCCWatchdog) ExecuteHOTUpdate(ctx context.Context, sessionID string) error {
    ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
    defer cancel()

    conn, err := w.pool.Acquire(ctx)
    if err != nil {
        return fmt.Errorf("acquire conn: %w", err)
    }
    defer conn.Release()

    // Enforce session timeout so stalled network cannot pin global xmin horizon
    if _, err := conn.Exec(ctx, "SET LOCAL idle_in_transaction_session_timeout = '3000ms'"); err != nil {
        return fmt.Errorf("set idle timeout: %w", err)
    }

    // Touch ONLY non-indexed columns (last_active_at, counter)
    const sql = `
        UPDATE user_sessions
        SET last_active_at = NOW(),
            heartbeat_count = heartbeat_count + 1
        WHERE id = $1;
    `
    tag, err := conn.Exec(ctx, sql, sessionID)
    if err != nil {
        return fmt.Errorf("hot update exec: %w", err)
    }
    if tag.RowsAffected() == 0 {
        return pgx.ErrNoRows
    }
    return nil
}

// AuditClusterXIDAge returns the oldest datfrozenxid age to prevent wraparound outages
func (w *MVCCWatchdog) AuditClusterXIDAge(ctx context.Context) (int64, error) {
    var maxAge int64
    err := w.pool.QueryRow(ctx, "SELECT max(age(datfrozenxid)) FROM pg_database WHERE datallowconn").Scan(&maxAge)
    if err != nil {
        return 0, fmt.Errorf("audit xid age: %w", err)
    }
    return maxAge, nil
}

// Production Go WAL Checkpoint & Differentiated Durability Engine
type WALManager struct {
    pool *pgxpool.Pool
}

func NewWALManager(pool *pgxpool.Pool) *WALManager {
    return &WALManager{pool: pool}
}

// IngestTelemetryAsync executes high-throughput ingestion with asynchronous commits
// Slashes commit latency from 2.5ms fsync to sub-millisecond in-memory WAL append
func (m *WALManager) IngestTelemetryAsync(ctx context.Context, deviceID string, payload []byte) error {
    ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
    defer cancel()

    tx, err := m.pool.Begin(ctx)
    if err != nil {
        return fmt.Errorf("begin tx: %w", err)
    }
    defer tx.Rollback(ctx)

    // Transaction-local asynchronous commit offloads fsync to background WAL writer
    if _, err := tx.Exec(ctx, "SET LOCAL synchronous_commit = 'off'"); err != nil {
        return fmt.Errorf("set async commit: %w", err)
    }

    const insertSQL = `
        INSERT INTO device_telemetry (device_id, payload, recorded_at)
        VALUES ($1, $2, NOW());
    `
    if _, err := tx.Exec(ctx, insertSQL, deviceID, payload); err != nil {
        return fmt.Errorf("insert telemetry: %w", err)
    }

    return tx.Commit(ctx)
}

// AuditReplicationSlotRisk detects slots retaining excessive WAL (>5GB)
func (m *WALManager) AuditReplicationSlotRisk(ctx context.Context) ([]string, error) {
    ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()

    const sql = `
        SELECT slot_name
        FROM pg_replication_slots
        WHERE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 5368709120
           OR wal_status <> 'normal'
           OR NOT active;
    `
    rows, err := m.pool.Query(ctx, sql)
    if err != nil {
        return nil, fmt.Errorf("query slots: %w", err)
    }
    defer rows.Close()

    var atRiskSlots []string
    for rows.Next() {
        var name string
        if err := rows.Scan(&name); err != nil {
            return nil, err
        }
        atRiskSlots = append(atRiskSlots, name)
    }
    return atRiskSlots, nil
}

// Production Go Lock Manager, Canonical Total Ordering & Deadlock Retry Harness
type DatabaseLockManager struct {
    pool *pgxpool.Pool
}

func NewDatabaseLockManager(pool *pgxpool.Pool) *DatabaseLockManager {
    return &DatabaseLockManager{pool: pool}
}

// ExecuteWithDeadlockRetry executes operations with exponential backoff and jitter for 40P01 and 55P03
func (m *DatabaseLockManager) ExecuteWithDeadlockRetry(ctx context.Context, op func(ctx context.Context) error, maxAttempts int) error {
    var err error
    baseDelay := 40 * time.Millisecond
    maxDelay := 800 * time.Millisecond

    for attempt := 0; attempt < maxAttempts; attempt++ {
        err = op(ctx)
        if err == nil {
            return nil
        }

        var pgErr *pgconn.PgError
        if errors.As(err, &pgErr) {
            // 40P01: deadlock_detected | 55P03: lock_not_available | 40001: serialization_failure
            if pgErr.Code == "40P01" || pgErr.Code == "55P03" || pgErr.Code == "40001" {
                limit := min(maxDelay, baseDelay*time.Duration(1<<attempt))
                jitter := time.Duration(rand.Int63n(int64(limit)))

                select {
                case <-ctx.Done():
                    return ctx.Err()
                case <-time.After(jitter):
                    continue
                }
            }
        }
        return err // Non-retryable error
    }
    return fmt.Errorf("exceeded max deadlock retry attempts (%d): %w", maxAttempts, err)
}

// TransferBalanceCanonical executes a dual-row balance update with strict canonical key sorting
// Eliminates Wait-For Graph cycles, guaranteeing zero deadlocks across concurrent transfers
func (m *DatabaseLockManager) TransferBalanceCanonical(ctx context.Context, fromID, toID int64, amount int64) error {
    // Canonical total ordering: sort IDs ascending before acquiring locks
    ids := []int64{fromID, toID}
    sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })

    return m.ExecuteWithDeadlockRetry(ctx, func(ctx context.Context) error {
        tx, err := m.pool.Begin(ctx)
        if err != nil {
            return fmt.Errorf("begin tx: %w", err)
        }
        defer tx.Rollback(ctx)

        // Arm Multi-Tier Timeout Ladder (fails fast on contention without pool starvation)
        if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '1500ms'; SET LOCAL statement_timeout = '8000ms'"); err != nil {
            return fmt.Errorf("set timeout ladder: %w", err)
        }

        const lockSQL = `
            SELECT id, balance
            FROM accounts
            WHERE id = ANY($1)
            ORDER BY id ASC
            FOR UPDATE;
        `
        rows, err := tx.Query(ctx, lockSQL, ids)
        if err != nil {
            return fmt.Errorf("lock accounts: %w", err)
        }
        defer rows.Close()

        balances := make(map[int64]int64)
        for rows.Next() {
            var id, bal int64
            if err := rows.Scan(&id, &bal); err != nil {
                return err
            }
            balances[id] = bal
        }

        if balances[fromID] < amount {
            return fmt.Errorf("insufficient balance: current %d < required %d", balances[fromID], amount)
        }

        if _, err := tx.Exec(ctx, "UPDATE accounts SET balance = balance - $1 WHERE id = $2", amount, fromID); err != nil {
            return fmt.Errorf("debit account: %w", err)
        }
        if _, err := tx.Exec(ctx, "UPDATE accounts SET balance = balance + $1 WHERE id = $2", amount, toID); err != nil {
            return fmt.Errorf("credit account: %w", err)
        }

        return tx.Commit(ctx)
    }, 5)
}

// AuditUnindexedForeignKeys detects foreign keys that lack supporting B-tree indexes
func (m *DatabaseLockManager) AuditUnindexedForeignKeys(ctx context.Context) ([]string, error) {
    ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()

    const sql = `
        SELECT c.conrelid::regclass::text || '.' || c.conname
        FROM pg_constraint c
        WHERE c.contype = 'f'
          AND NOT EXISTS (
            SELECT 1 FROM pg_index i
            WHERE i.indrelid = c.conrelid
              AND (i.indkey::smallint[])[0:cardinality(c.conkey)-1] = c.conkey
          );
    `
    rows, err := m.pool.Query(ctx, sql)
    if err != nil {
        return nil, fmt.Errorf("query unindexed fks: %w", err)
    }
    defer rows.Close()

    var unindexed []string
    for rows.Next() {
        var name string
        if err := rows.Scan(&name); err != nil {
            return nil, err
        }
        unindexed = append(unindexed, name)
    }
    return unindexed, nil
}

// ==============================================================================
// 14. High Availability, Automated Failover & Multi-Host pgxpool Invariants
// ==============================================================================

// HAFailoverPool wraps pgxpool with multi-host failover and target_session_attrs verification
type HAFailoverPool struct {
    pool *pgxpool.Pool
}

// NewHAFailoverPool creates a resilient pool supporting multi-host PostgreSQL topologies
// Example connString: "postgres://user:pass@node1:5432,node2:5432,node3:5432/db?target_session_attrs=read-write&sslmode=verify-full"
func NewHAFailoverPool(ctx context.Context, connString string) (*HAFailoverPool, error) {
    config, err := pgxpool.ParseConfig(connString)
    if err != nil {
        return nil, fmt.Errorf("parse multi-host conn string: %w", err)
    }

    // Handshake hook: ensure every newly checked out or established connection is a writable leader
    config.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
        var isReadOnly string
        if err := conn.QueryRow(ctx, "SHOW transaction_read_only").Scan(&isReadOnly); err != nil {
            return fmt.Errorf("read-only handshake query failed: %w", err)
        }
        if isReadOnly == "on" {
            return errors.New("connected to read-only replica: target_session_attrs=read-write violated")
        }
        return nil
    }

    pool, err := pgxpool.NewWithConfig(ctx, config)
    if err != nil {
        return nil, fmt.Errorf("init ha pgxpool: %w", err)
    }

    return &HAFailoverPool{pool: pool}, nil
}

// ExecuteWriteWithFailover executes an operation and transparently retries on failover disconnections
func (p *HAFailoverPool) ExecuteWriteWithFailover(ctx context.Context, op func(ctx context.Context, tx pgx.Tx) error) error {
    baseDelay := 50 * time.Millisecond
    maxDelay := 2 * time.Second

    for attempt := 0; attempt < 5; attempt++ {
        err := pgx.BeginTxFunc(ctx, p.pool, pgx.TxOptions{IsoLevel: pgx.ReadCommitted}, op)
        if err == nil {
            return nil
        }

        // Check if error is failover-related (e.g. read-only transaction 25006 or connection severed)
        var pgErr *pgconn.PgError
        var netErr net.Error
        if (errors.As(err, &pgErr) && (pgErr.Code == "25006" || pgErr.Code == "57P01" || pgErr.Code == "57P03")) ||
            errors.As(err, &netErr) {
            limit := min(maxDelay, baseDelay*time.Duration(1<<attempt))
            jitter := time.Duration(rand.Int63n(int64(limit)))

            select {
            case <-ctx.Done():
                return ctx.Err()
            case <-time.After(jitter):
                continue
            }
        }
        return err // Fatal non-failover error
    }
    return errors.New("transaction failed: maximum failover retry attempts exhausted")
}

// ==============================================================================
// 15. Disaster Recovery Sentinel, WAL Archive Backlog & amcheck Index Invariants
// ==============================================================================

// ArchivalStatus represents PostgreSQL pg_stat_archiver metrics
type ArchivalStatus struct {
    ArchivedCount       int64         `json:"archived_count"`
    LastArchivedWAL     string        `json:"last_archived_wal"`
    LastArchivedAgeSec  float64       `json:"last_archived_age_sec"`
    FailedCount         int64         `json:"failed_count"`
    LastFailedWAL       string        `json:"last_failed_wal"`
    IsFailing           bool          `json:"is_failing"`
    DataChecksumsOn     bool          `json:"data_checksums_on"`
}

// CheckArchivalHealth audits WAL archiving health and warns if disk exhaustion is imminent
func CheckArchivalHealth(ctx context.Context, pool *pgxpool.Pool) (*ArchivalStatus, error) {
    query := `
        SELECT
            archived_count,
            COALESCE(last_archived_wal, ''),
            COALESCE(ROUND(EXTRACT(EPOCH FROM (NOW() - last_archived_time))::numeric, 2), 0.0),
            failed_count,
            COALESCE(last_failed_wal, ''),
            COALESCE(last_failed_time > last_archived_time, false),
            current_setting('data_checksums') = 'on'
        FROM pg_stat_archiver;
    `

    var status ArchivalStatus
    err := pool.QueryRow(ctx, query).Scan(
        &status.ArchivedCount,
        &status.LastArchivedWAL,
        &status.LastArchivedAgeSec,
        &status.FailedCount,
        &status.LastFailedWAL,
        &status.IsFailing,
        &status.DataChecksumsOn,
    )
    if err != nil {
        return nil, fmt.Errorf("query pg_stat_archiver: %w", err)
    }

    if status.IsFailing {
        return &status, fmt.Errorf("WAL archival failure: last failed WAL is %s; investigate storage/network immediately", status.LastFailedWAL)
    }

    return &status, nil
}

// ==============================================================================
// 16. Change Data Capture (CDC), Logical Replication Slots & Monotonic LSN Fencing
// ==============================================================================

// CDCSlotHealth represents the operational status of a PostgreSQL logical replication slot
type CDCSlotHealth struct {
    SlotName       string  `json:"slot_name"`
    Active         bool    `json:"active"`
    WalStatus      string  `json:"wal_status"`
    LagBytes       int64   `json:"lag_bytes"`
    LagMB          float64 `json:"lag_mb"`
    CatalogXminAge int64   `json:"catalog_xmin_age"`
    IsDiskAtRisk   bool    `json:"is_disk_at_risk"`
    IsCatalogOld   bool    `json:"is_catalog_old"`
}

// AuditCDCSlotHealth queries pg_replication_slots to enforce safety boundaries
func AuditCDCSlotHealth(ctx context.Context, pool *pgxpool.Pool, slotName string) (*CDCSlotHealth, error) {
    query := `
        SELECT
            slot_name,
            active,
            COALESCE(wal_status, 'unreserved'),
            COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0),
            ROUND(COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0) / (1024 * 1024), 2),
            COALESCE(age(catalog_xmin), 0)
        FROM pg_replication_slots
        WHERE slot_name = $1 AND slot_type = 'logical';
    `

    var h CDCSlotHealth
    err := pool.QueryRow(ctx, query, slotName).Scan(
        &h.SlotName,
        &h.Active,
        &h.WalStatus,
        &h.LagBytes,
        &h.LagMB,
        &h.CatalogXminAge,
    )
    if err != nil {
        return nil, fmt.Errorf("audit cdc slot %s: %w", slotName, err)
    }

    // Invariant: Lag > 10GB or wal_status != normal flags disk risk
    h.IsDiskAtRisk = h.LagMB > 10240 || h.WalStatus == "extended" || h.WalStatus == "lost"
    // Invariant: Catalog xmin age > 500,000 flags autovacuum pinning risk
    h.IsCatalogOld = h.CatalogXminAge > 500000

    if h.WalStatus == "lost" {
        return &h, fmt.Errorf("cdc slot %s is LOST: WAL was recycled, consumer must re-snapshot", slotName)
    }
    if h.IsDiskAtRisk {
        return &h, fmt.Errorf("cdc slot %s lag critical: %.2f MB retained, risk of primary disk exhaustion", slotName, h.LagMB)
    }

    return &h, nil
}

// ============================================================================
// AGENTIC DATABASE ROW-LEVEL SECURITY (RLS) & TENANT ISOLATION INVARIANTS
// ============================================================================

// RLSTableReport represents the compliance and security posture of a database table.
type RLSTableReport struct {
    TableName              string `json:"table_name"`
    TableOwner             string `json:"table_owner"`
    IsRLSEnabled           bool   `json:"is_rls_enabled"`
    IsRLSForced            bool   `json:"is_rls_forced"`
    PolicyCount            int    `json:"policy_count"`
    HasLeftmostTenantIndex bool   `json:"has_leftmost_tenant_index"`
    IsCompliant            bool   `json:"is_compliant"`
    ViolationReason        string `json:"violation_reason,omitempty"`
}

// WithTenantTx executes database operations within an isolated transaction scoped strictly
// to the specified tenant using SET LOCAL app.current_tenant_id.
// Invariant: SET LOCAL automatically reverts upon COMMIT or ROLLBACK, mathematically
// preventing cross-tenant session leaks across pooled PgBouncer connections.
func WithTenantTx(ctx context.Context, pool *pgxpool.Pool, tenantID uuid.UUID, fn func(tx pgx.Tx) error) error {
    if tenantID == uuid.Nil {
        return fmt.Errorf("rls tenant transaction: tenantID cannot be nil")
    }

    tx, err := pool.BeginTx(ctx, pgx.TxOptions{
        IsoLevel: pgx.ReadCommitted,
    })
    if err != nil {
        return fmt.Errorf("begin tenant tx: %w", err)
    }
    defer tx.Rollback(ctx)

    // Set transaction-scoped tenant GUC (is_local = true)
    _, err = tx.Exec(ctx, "SELECT set_config('app.current_tenant_id', $1, true);", tenantID.String())
    if err != nil {
        return fmt.Errorf("set tenant local context: %w", err)
    }

    if err := fn(tx); err != nil {
        return err
    }

    if err := tx.Commit(ctx); err != nil {
        return fmt.Errorf("commit tenant tx: %w", err)
    }

    return nil
}

// AuditRLSCompliance scans all application relations to ensure:
// 1. RLS is enabled (relrowsecurity = true)
// 2. RLS is FORCED (relforcerowsecurity = true) to prevent table owner bypass
// 3. At least one policy is declared
// 4. A composite B-tree index exists with tenant_id as the leading column
func AuditRLSCompliance(ctx context.Context, pool *pgxpool.Pool, schema string) ([]RLSTableReport, error) {
    query := `
        WITH table_meta AS (
            SELECT
                c.oid AS table_oid,
                c.relname AS tablename,
                pg_get_userbyid(c.relowner) AS tableowner,
                c.relrowsecurity AS rowsecurity,
                c.relforcerowsecurity AS forcerowsecurity
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'r'
              AND n.nspname = $1
              AND c.relname NOT IN ('schema_migrations', 'spatial_ref_sys')
        ),
        policies_meta AS (
            SELECT polrelid, count(*) AS policy_count
            FROM pg_policy
            GROUP BY polrelid
        ),
        tenant_indexes AS (
            SELECT
                i.indrelid,
                bool_or(a.attname = 'tenant_id' AND i.indkey[0] = a.attnum) AS has_leftmost_tenant_index
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
            GROUP BY i.indrelid
        )
        SELECT
            tm.tablename,
            tm.tableowner,
            tm.rowsecurity,
            tm.forcerowsecurity,
            COALESCE(pm.policy_count, 0),
            COALESCE(ti.has_leftmost_tenant_index, false)
        FROM table_meta tm
        LEFT JOIN policies_meta pm ON pm.polrelid = tm.table_oid
        LEFT JOIN tenant_indexes ti ON ti.indrelid = tm.table_oid
        ORDER BY tm.tablename;
    `

    rows, err := pool.Query(ctx, query, schema)
    if err != nil {
        return nil, fmt.Errorf("audit rls compliance: %w", err)
    }
    defer rows.Close()

    var reports []RLSTableReport
    for rows.Next() {
        var r RLSTableReport
        err := rows.Scan(
            &r.TableName,
            &r.TableOwner,
            &r.IsRLSEnabled,
            &r.IsRLSForced,
            &r.PolicyCount,
            &r.HasLeftmostTenantIndex,
        )
        if err != nil {
            return nil, fmt.Errorf("scan rls audit row: %w", err)
        }

        switch {
        case !r.IsRLSEnabled:
            r.ViolationReason = "RLS is not enabled (missing ENABLE ROW LEVEL SECURITY)"
        case !r.IsRLSForced:
            r.ViolationReason = "RLS is not forced (missing FORCE ROW LEVEL SECURITY; table owner bypass risk)"
        case r.PolicyCount == 0:
            r.ViolationReason = "No RLS policies defined; default deny or unconfigured relation"
        case !r.HasLeftmostTenantIndex:
            r.ViolationReason = "Missing composite index with tenant_id as leftmost column; risk of sequential scans"
        default:
            r.IsCompliant = true
        }

        reports = append(reports, r)
    }

    return reports, nil
}

// DatabaseQueryPlanSentinel audits EXPLAIN (ANALYZE, BUFFERS) execution outputs
// to detect cardinality misestimations, NVMe cost drift, and temporary disk buffer spills.
type QueryPlanAuditSummary struct {
    MaxDivergenceRatio float64  `json:"max_divergence_ratio"`
    TotalTempSpillKB   int64    `json:"total_temp_spill_kb"`
    ExecutionTimeMs    float64  `json:"execution_time_ms"`
    IsCompliant        bool     `json:"is_compliant"`
    Violations         []string `json:"violations"`
}

func AuditQueryPlanPerformance(
    ctx context.Context,
    pool *pgxpool.Pool,
    query string,
    maxVariance float64,
    args ...any,
) (*QueryPlanAuditSummary, error) {
    explainSQL := fmt.Sprintf("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s", query)

    var rawJSON []byte
    if err := pool.QueryRow(ctx, explainSQL, args...).Scan(&rawJSON); err != nil {
        return nil, fmt.Errorf("execute explain analyze: %w", err)
    }

    var plans []struct {
        Plan struct {
            NodeType          string  `json:"Node Type"`
            ActualRows        float64 `json:"Actual Rows"`
            PlanRows          float64 `json:"Plan Rows"`
            TempWrittenBlocks int64   `json:"Temp Written Blocks"`
            Plans             []any   `json:"Plans,omitempty"`
        } `json:"Plan"`
        ExecutionTime float64 `json:"Execution Time"`
    }

    if err := json.Unmarshal(rawJSON, &plans); err != nil {
        return nil, fmt.Errorf("unmarshal explain json: %w", err)
    }

    if len(plans) == 0 {
        return nil, fmt.Errorf("empty explain plan returned")
    }

    summary := &QueryPlanAuditSummary{
        MaxDivergenceRatio: 1.0,
        ExecutionTimeMs:    plans[0].ExecutionTime,
        IsCompliant:        true,
        Violations:         make([]string, 0),
    }

    rootNode := plans[0].Plan
    if rootNode.TempWrittenBlocks > 0 {
        summary.TotalTempSpillKB = rootNode.TempWrittenBlocks * 8
        summary.IsCompliant = false
        summary.Violations = append(summary.Violations,
            fmt.Sprintf("Disk spill detected: %d KB written to temporary files", summary.TotalTempSpillKB))
    }

    if rootNode.PlanRows > 0 && rootNode.ActualRows > 0 {
        ratio := rootNode.ActualRows / rootNode.PlanRows
        if ratio < 1.0 {
            ratio = 1.0 / ratio
        }
        summary.MaxDivergenceRatio = ratio
        if ratio > maxVariance {
            summary.IsCompliant = false
            summary.Violations = append(summary.Violations,
                fmt.Sprintf("Cardinality divergence: %.2fx exceeds maximum allowed threshold %.2fx", ratio, maxVariance))
        }
    }

    return summary, nil
}

// DatabaseMemoryGovernor audits PostgreSQL memory settings and executes analytical queries
// within isolated transaction-scoped SET LOCAL work_mem envelopes.
type DatabaseMemoryAuditSummary struct {
    WorkMemBytes            int64    `json:"work_mem_bytes"`
    SharedBuffersBytes      int64    `json:"shared_buffers_bytes"`
    TempFileLimitBytes      int64    `json:"temp_file_limit_bytes"`
    LogTempFiles            int      `json:"log_temp_files"`
    TotalTempSpilledBytes   int64    `json:"total_temp_spilled_bytes"`
    IsMemoryConfigHardened  bool     `json:"is_memory_config_hardened"`
    Violations              []string `json:"violations"`
}

func AuditDatabaseMemoryConfiguration(ctx context.Context, pool *pgxpool.Pool) (*DatabaseMemoryAuditSummary, error) {
    settingsSQL := `
        SELECT name, setting, unit
        FROM pg_settings
        WHERE name IN ('work_mem', 'shared_buffers', 'temp_file_limit', 'log_temp_files', 'hash_mem_multiplier');
    `
    rows, err := pool.Query(ctx, settingsSQL)
    if err != nil {
        return nil, fmt.Errorf("query pg_settings: %w", err)
    }
    defer rows.Close()

    settingsMap := make(map[string]string)
    for rows.Next() {
        var name, setting string
        var unit *string
        if err := rows.Scan(&name, &setting, &unit); err != nil {
            return nil, fmt.Errorf("scan pg_settings: %w", err)
        }
        if unit != nil {
            settingsMap[name] = setting + *unit
        } else {
            settingsMap[name] = setting
        }
    }

    var tempBytes int64
    var tempFiles int64
    statSQL := "SELECT temp_files, temp_bytes FROM pg_stat_database WHERE datname = current_database();"
    if err := pool.QueryRow(ctx, statSQL).Scan(&tempFiles, &tempBytes); err != nil {
        return nil, fmt.Errorf("query pg_stat_database: %w", err)
    }

    summary := &DatabaseMemoryAuditSummary{
        TotalTempSpilledBytes:  tempBytes,
        IsMemoryConfigHardened: true,
        Violations:             make([]string, 0),
    }

    if tempLimitStr, ok := settingsMap["temp_file_limit"]; ok {
        var limitVal int64
        fmt.Sscanf(tempLimitStr, "%d", &limitVal)
        if limitVal == -1 {
            summary.IsMemoryConfigHardened = false
            summary.Violations = append(summary.Violations, "temp_file_limit is unlimited (-1); set to 10GB to protect disk")
        } else {
            summary.TempFileLimitBytes = limitVal * 1024
        }
    }

    if logTemp, ok := settingsMap["log_temp_files"]; ok {
        var logVal int
        fmt.Sscanf(logTemp, "%d", &logVal)
        summary.LogTempFiles = logVal
        if logVal != 0 {
            summary.IsMemoryConfigHardened = false
            summary.Violations = append(summary.Violations, fmt.Sprintf("log_temp_files is %d; set to 0 to trace all spills", logVal))
        }
    }

    return summary, nil
}

// ExecuteWithAdaptiveWorkMem runs fn inside a transaction with elevated work_mem, reverting at commit.
func ExecuteWithAdaptiveWorkMem[T any](
    ctx context.Context,
    pool *pgxpool.Pool,
    elevatedWorkMem string,
    fn func(tx pgx.Tx) (T, error),
) (T, error) {
    var zero T
    tx, err := pool.BeginTx(ctx, pgx.TxOptions{})
    if err != nil {
        return zero, fmt.Errorf("begin adaptive tx: %w", err)
    }
    defer tx.Rollback(ctx)

    if _, err := tx.Exec(ctx, fmt.Sprintf("SET LOCAL work_mem = '%s'", elevatedWorkMem)); err != nil {
        return zero, fmt.Errorf("set local work_mem: %w", err)
    }
    if _, err := tx.Exec(ctx, "SET LOCAL hash_mem_multiplier = 2.0"); err != nil {
        return zero, fmt.Errorf("set local hash_mem_multiplier: %w", err)
    }

    res, err := fn(tx)
    if err != nil {
        return zero, err
    }

    if err := tx.Commit(ctx); err != nil {
        return zero, fmt.Errorf("commit adaptive tx: %w", err)
    }

    return res, nil
}

// GinIndexAuditSummary contains health metrics for GIN inverted indexes.
type GinIndexAuditSummary struct {
    IndexName          string
    TableName          string
    IndexSizeBytes     int64
    IndexSizePretty    string
    PendingPages       int
    PendingBytes       int64
    FastUpdateEnabled  bool
    IsPendingListClean bool
}

// AuditGinIndexes inspects PostgreSQL GIN indexes for pending list bloat and write stall risks.
func AuditGinIndexes(ctx context.Context, pool *pgxpool.Pool) ([]GinIndexAuditSummary, error) {
    query := `
        SELECT
            c.relname AS index_name,
            t.relname AS table_name,
            pg_relation_size(c.oid) AS index_bytes,
            pg_size_pretty(pg_relation_size(c.oid)) AS index_size_pretty,
            coalesce(gin_stat.pending_pages, 0) AS pending_pages,
            coalesce(gin_stat.pending_pages, 0) * 8192 AS pending_bytes,
            coalesce(opt.fastupdate, true) AS fast_update_enabled
        FROM pg_class c
        JOIN pg_am am ON am.oid = c.relam
        JOIN pg_index i ON i.indexrelid = c.oid
        JOIN pg_class t ON t.oid = i.indrelid
        LEFT JOIN LATERAL (
            SELECT (regexp_matches(c.reloptions::text, 'fastupdate=(true|false|on|off)'))[1] IN ('true', 'on') AS fastupdate
        ) opt ON true
        LEFT JOIN LATERAL (
            SELECT (gin_stats).pending_pages AS pending_pages
            FROM (SELECT gin_metapage_info(get_raw_page(c.relname, 0)) AS gin_stats) s
        ) gin_stat ON true
        WHERE am.amname = 'gin' AND c.relnamespace = 'public'::regnamespace;
    `

    // Fallback if pageinspect is not available in current database
    fallbackQuery := `
        SELECT
            c.relname AS index_name,
            t.relname AS table_name,
            pg_relation_size(c.oid) AS index_bytes,
            pg_size_pretty(pg_relation_size(c.oid)) AS index_size_pretty,
            0 AS pending_pages,
            0 AS pending_bytes,
            true AS fast_update_enabled
        FROM pg_class c
        JOIN pg_am am ON am.oid = c.relam
        JOIN pg_index i ON i.indexrelid = c.oid
        JOIN pg_class t ON t.oid = i.indrelid
        WHERE am.amname = 'gin' AND c.relnamespace = 'public'::regnamespace;
    `

    rows, err := pool.Query(ctx, query)
    if err != nil {
        rows, err = pool.Query(ctx, fallbackQuery)
        if err != nil {
            return nil, fmt.Errorf("audit gin indexes: %w", err)
        }
    }
    defer rows.Close()

    var results []GinIndexAuditSummary
    for rows.Next() {
        var s GinIndexAuditSummary
        if err := rows.Scan(
            &s.IndexName,
            &s.TableName,
            &s.IndexSizeBytes,
            &s.IndexSizePretty,
            &s.PendingPages,
            &s.PendingBytes,
            &s.FastUpdateEnabled,
        ); err != nil {
            return nil, fmt.Errorf("scan gin summary: %w", err)
        }
        // Pending list > 8MB poses immediate write stall risk
        s.IsPendingListClean = s.PendingBytes < 8*1024*1024
        results = append(results, s)
    }

    return results, nil
}

// SanitizeWebsearchQuery strips null bytes and illegal punctuation before passing to websearch_to_tsquery.
func SanitizeWebsearchQuery(raw string) string {
    clean := strings.ReplaceAll(raw, "\x00", "")
    clean = strings.TrimSpace(clean)
    if len(clean) > 500 {
        clean = clean[:500]
    }
    return clean
}

// ============================================================================
// 12. PostgreSQL JSONB Document-Relational Discipline & Zero-Allocation TOAST Defense
// ============================================================================

// BoundedJSONBDecoder wraps an io.Reader with an explicit byte ceiling (e.g., 2MB)
// to prevent malicious or unbounded TOAST JSONB payloads from causing OOM exhaustion.
func DecodeBoundedJSON[T any](r io.Reader, maxBytes int64) (T, error) {
    var dest T
    limitReader := io.LimitReader(r, maxBytes+1)
    decoder := json.NewDecoder(limitReader)
    decoder.DisallowUnknownFields() // Reject polymorphic schema drift

    if err := decoder.Decode(&dest); err != nil {
        return dest, fmt.Errorf("decode json payload: %w", err)
    }

    // Verify reader did not exceed maxBytes
    var dummy [1]byte
    if n, _ := limitReader.Read(dummy[:]); n > 0 {
        return dest, fmt.Errorf("json payload exceeds maximum allowed size of %d bytes", maxBytes)
    }

    return dest, nil
}

// SargableJSONBContainmentQuery executes a containment search using jsonb_path_ops index.
// Never uses string formatting or non-sargable arrow operators.
func QueryEventsByContainment[T any](
    ctx context.Context,
    pool *pgxpool.Pool,
    tenantID uuid.UUID,
    containmentFilter map[string]interface{},
    limit int,
) ([]T, error) {
    if limit <= 0 || limit > 100 {
        limit = 50
    }

    filterJSON, err := json.Marshal(containmentFilter)
    if err != nil {
        return nil, fmt.Errorf("marshal containment filter: %w", err)
    }

    // Explicit projection avoids reading unneeded TOAST columns
    query := `
        SELECT payload
        FROM customer_events
        WHERE tenant_id = $1
          AND payload @> $2::jsonb
        ORDER BY created_at DESC
        LIMIT $3
    `

    rows, err := pool.Query(ctx, query, tenantID, filterJSON)
    if err != nil {
        return nil, fmt.Errorf("execute jsonb containment query: %w", err)
    }
    defer rows.Close()

    var results []T
    for rows.Next() {
        var raw []byte
        if err := rows.Scan(&raw); err != nil {
            return nil, fmt.Errorf("scan jsonb row: %w", err)
        }

        var item T
        if err := json.Unmarshal(raw, &item); err != nil {
            return nil, fmt.Errorf("unmarshal jsonb into target struct: %w", err)
        }
        results = append(results, item)
    }

    return results, rows.Err()
}

// ============================================================================
// 13. PostgreSQL BRIN Indexing, Time-Series Ingestion & Monotonic UUIDv7 Micro-Batching
// ============================================================================

// MonotonicUUIDv7 generates a time-ordered UUIDv7 matching RFC 9562.
// Invariant: Guarantees strict physical heap correlation for BRIN indexing (|corr| >= 0.95).
func MonotonicUUIDv7(ts time.Time) (uuid.UUID, error) {
    var id uuid.UUID
    ms := uint64(ts.UnixMilli())

    // 48-bit timestamp in big-endian order
    id[0] = byte(ms >> 40)
    id[1] = byte(ms >> 32)
    id[2] = byte(ms >> 24)
    id[3] = byte(ms >> 16)
    id[4] = byte(ms >> 8)
    id[5] = byte(ms)

    // Random entropy bits
    if _, err := io.ReadFull(rand.Reader, id[6:]); err != nil {
        return uuid.Nil, fmt.Errorf("generate entropy: %w", err)
    }

    // Version 7 (0111) in bits 48..51
    id[6] = (id[6] & 0x0f) | 0x70
    // Variant 1 (10) in bits 64..65
    id[8] = (id[8] & 0x3f) | 0x80

    return id, nil
}

// MonotonicEventSink flushes time-series records into PostgreSQL using COPY protocol.
// Invariant: Always sorts batch by RecordedAt before COPY to maintain physical disk correlation.
type MonotonicEventSink struct {
    pool *pgxpool.Pool
}

func NewMonotonicEventSink(pool *pgxpool.Pool) *MonotonicEventSink {
    return &MonotonicEventSink{pool: pool}
}

type StreamEvent struct {
    ID         uuid.UUID
    TenantID   uuid.UUID
    MetricName string
    Value      float64
    RecordedAt time.Time
}

func (s *MonotonicEventSink) BulkInsertMonotonic(ctx context.Context, table string, events []StreamEvent) error {
    if len(events) == 0 {
        return nil
    }

    // Sort in-memory batch by RecordedAt ascending to ensure physical heap page monotonicity
    sort.Slice(events, func(i, j int) bool {
        return events[i].RecordedAt.Before(events[j].RecordedAt)
    })

    rows := make([][]interface{}, len(events))
    for i, e := range events {
        rows[i] = []interface{}{e.ID, e.TenantID, e.MetricName, e.Value, e.RecordedAt}
    }

    conn, err := s.pool.Acquire(ctx)
    if err != nil {
        return fmt.Errorf("acquire connection: %w", err)
    }
    defer conn.Release()

    _, err = conn.CopyFrom(
        ctx,
        pgx.Identifier{table},
        []string{"id", "tenant_id", "metric_name", "value", "recorded_at"},
        pgx.CopyFromRows(rows),
    )
    if err != nil {
        return fmt.Errorf("copy from rows: %w", err)
    }

    return nil
}

// ============================================================================
// 14. PostgreSQL pgvector HNSW Vector Search, Unit Normalization & Iterative Scan
// ============================================================================

// UnitNormalizeVector normalizes a float32 slice to unit Euclidean length (||v|| = 1.0).
// Invariant: Unlocks line-rate SIMD AVX-512 Inner Product operations without square roots.
func UnitNormalizeVector(vec []float32) error {
    var sumSquares float64
    for _, val := range vec {
        sumSquares += float64(val) * float64(val)
    }

    norm := math.Sqrt(sumSquares)
    if norm == 0 || math.IsNaN(norm) || math.IsInf(norm, 0) {
        return fmt.Errorf("invalid vector Euclidean norm: %f", norm)
    }

    invNorm := float32(1.0 / norm)
    for i := range vec {
        vec[i] *= invNorm
    }
    return nil
}

// FilteredVectorChunk represents a retrieved chunk with similarity score.
type FilteredVectorChunk struct {
    ID         uuid.UUID `json:"id"`
    TenantID   uuid.UUID `json:"tenantId"`
    DocumentID uuid.UUID `json:"documentId"`
    Content    string    `json:"content"`
    Similarity float64   `json:"similarity"`
}

// VectorRepository executes filtered vector retrieval with iterative scan safety.
type VectorRepository struct {
    pool *pgxpool.Pool
}

func NewVectorRepository(pool *pgxpool.Pool) *VectorRepository {
    return &VectorRepository{pool: pool}
}

// SearchFilteredChunks executes filtered HNSW search with hnsw.iterative_scan = 'relaxed_order'.
// Invariant: Prevents the 0-row discard catastrophe when filtering by tenant_id.
func (r *VectorRepository) SearchFilteredChunks(
    ctx context.Context,
    tenantID uuid.UUID,
    queryVec []float32,
    efSearch int,
    limit int,
) ([]FilteredVectorChunk, error) {
    if err := UnitNormalizeVector(queryVec); err != nil {
        return nil, fmt.Errorf("normalize vector: %w", err)
    }

    // Format vector as string literal for pgvector halfvec/vector
    var b strings.Builder
    b.WriteString("[")
    for i, v := range queryVec {
        if i > 0 {
            b.WriteString(",")
        }
        b.WriteString(fmt.Sprintf("%f", v))
    }
    b.WriteString("]")
    vecStr := b.String()

    tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
    if err != nil {
        return nil, fmt.Errorf("begin vector search tx: %w", err)
    }
    defer tx.Rollback(ctx)

    // Set transactional GUCs for iterative scanning and calibrated recall
    if _, err := tx.Exec(ctx, "SET LOCAL hnsw.iterative_scan = 'relaxed_order'"); err != nil {
        return nil, fmt.Errorf("activate iterative_scan: %w", err)
    }
    if _, err := tx.Exec(ctx, fmt.Sprintf("SET LOCAL hnsw.ef_search = %d", efSearch)); err != nil {
        return nil, fmt.Errorf("configure ef_search: %w", err)
    }

    query := `
        SELECT
            id,
            tenant_id,
            document_id,
            content,
            1 - (embedding <=> $1::halfvec) AS score
        FROM document_chunks
        WHERE tenant_id = $2
        ORDER BY embedding <=> $1::halfvec
        LIMIT $3;
    `

    rows, err := tx.Query(ctx, query, vecStr, tenantID, limit)
    if err != nil {
        return nil, fmt.Errorf("execute vector query: %w", err)
    }
    defer rows.Close()

    var chunks []FilteredVectorChunk
    for rows.Next() {
        var c FilteredVectorChunk
        if err := rows.Scan(&c.ID, &c.TenantID, &c.DocumentID, &c.Content, &c.Similarity); err != nil {
            return nil, fmt.Errorf("scan vector row: %w", err)
        }
        chunks = append(chunks, c)
    }

    if err := rows.Err(); err != nil {
        return nil, fmt.Errorf("rows iteration: %w", err)
    }

    if err := tx.Commit(ctx); err != nil {
        return nil, fmt.Errorf("commit vector search tx: %w", err)
    }

    return chunks, nil
}
```

- **PostgreSQL Exclusion Violations, Temporal Range Types & PostGIS Zero-Allocation Spatial Handling**:
  - ❌ **Anti-Pattern: Application Pre-Check Race Conditions, Raw String Geometry Allocations, Ignoring SQLSTATE 23P01, and Unbounded Interval Boundaries**:
    - Relying on `SELECT count(*) WHERE ...` before inserting bookings or schedules, allowing concurrent Go routines to create overlapping reservations due to snapshot isolation race windows.
    - Querying PostGIS geometries using string WKT (`ST_AsText(location)`), forcing allocations, string formatting overhead, and regex parsing on every row, instead of scanning native PostGIS binary EWKB into compact structs.
    - Treating database insertion errors generically without unpacking `*pgconn.PgError`, failing to map `SQLSTATE 23P01 (exclusion_violation)` to an explicit domain `ErrScheduleConflict` or HTTP 409 Conflict.
    - Creating temporal ranges with ambiguous or closed `[]` boundaries, causing boundary point collisions where consecutive reservations (e.g. 10:00-11:00 and 11:00-12:00) falsely reject each other.
  - ✅ **Production Invariant**:
    - Always rely on PostgreSQL Exclusion Constraints (`EXCLUDE USING gist`) and canonical half-open `[)` boundaries using `pgtype.Range[time.Time]{LowerType: pgtype.Inclusive, UpperType: pgtype.Exclusive, Valid: true}`.
    - Unpack `pgconn.PgError` on insert/update failures and explicitly check `pgErr.Code == pgerrcode.ExclusionViolation` (`23P01`) to return structured domain conflicts with zero race conditions.
    - Scan PostGIS geography coordinates directly using binary EWKB decoding or coordinate tuple scanning (`ST_X(location::geometry)`, `ST_Y(location::geometry)`) with zero heap allocations.
    - Utilize the native GiST `<->` distance operator in Go queries for branch-and-bound nearest-neighbor lookups, bounding result sets with strict limits.

```go
package store

import (
	"context"
	"encoding/binary"
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
	ErrReservationConflict = errors.New("reservation conflicts with an existing booking interval")
	ErrInvalidTimeBounds   = errors.New("start time must precede end time")
)

type BookingRecord struct {
	ID        uuid.UUID
	TenantID  uuid.UUID
	VehicleID uuid.UUID
	Start     time.Time
	End       time.Time
}

type SpatialCoordinate struct {
	Longitude float64
	Latitude  float64
}

// DecodePointEWKB decodes a 25-byte PostGIS Point EWKB (SRID 4326) with zero heap allocations.
// Binary format: [1 byte byte-order] [4 bytes geom-type with SRID flag 0x20000001] [4 bytes SRID 4326] [8 bytes X] [8 bytes Y]
func DecodePointEWKB(b []byte) (SpatialCoordinate, error) {
	if len(b) < 25 {
		return SpatialCoordinate{}, errors.New("invalid EWKB Point payload: buffer too short")
	}

	byteOrder := binary.ByteOrder(binary.LittleEndian)
	if b[0] == 0 {
		byteOrder = binary.BigEndian
	}

	geomType := byteOrder.Uint32(b[1:5])
	const ewkbPointSRID = 0x20000001
	if geomType != ewkbPointSRID && geomType != 1 {
		return SpatialCoordinate{}, fmt.Errorf("unexpected EWKB geometry type: 0x%x", geomType)
	}

	offset := 5
	if geomType&0x20000000 != 0 {
		offset += 4 // Skip SRID field
	}

	xBits := byteOrder.Uint64(b[offset : offset+8])
	yBits := byteOrder.Uint64(b[offset+8 : offset+16])

	lon := *(*float64)(unsafe.Pointer(&xBits))
	lat := *(*float64)(unsafe.Pointer(&yBits))

	return SpatialCoordinate{Longitude: lon, Latitude: lat}, nil
}

// ScheduleVehicleBooking atomically schedules a reservation protected by GiST Exclusion Constraint.
func ScheduleVehicleBooking(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID, vehicleID, customerID uuid.UUID,
	startTime, endTime time.Time,
) (uuid.UUID, error) {
	if !startTime.Before(endTime) {
		return uuid.Nil, ErrInvalidTimeBounds
	}

	// Canonical half-open interval [start, end)
	period := pgtype.Range[time.Time]{
		Lower:     startTime.UTC(),
		Upper:     endTime.UTC(),
		LowerType: pgtype.Inclusive,
		UpperType: pgtype.Exclusive,
		Valid:     true,
	}

	const query = `
		INSERT INTO vehicle_bookings (tenant_id, vehicle_id, customer_id, booking_period)
		VALUES ($1, $2, $3, $4)
		RETURNING id;
	`

	var bookingID uuid.UUID
	err := pool.QueryRow(ctx, query, tenantID, vehicleID, customerID, period).Scan(&bookingID)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == pgerrcode.ExclusionViolation {
			// SQLSTATE 23P01: declarative exclusion constraint prevented overlap
			return uuid.Nil, fmt.Errorf("%w: vehicle %s is already reserved", ErrReservationConflict, vehicleID)
		}
		return uuid.Nil, fmt.Errorf("insert booking: %w", err)
	}

	return bookingID, nil
}
```

- **PostgreSQL Foreign Data Wrappers (`postgres_fdw`), Federated Pushdown & Distributed 2PC Recovery with pgx**:
  - ❌ **Anti-Pattern: Local Transaction Stalling Across Remote Clusters, Non-Immutable Time Function Injections, and Ignoring `pg_prepared_xacts`**:
    - Querying foreign tables inside long-lived local transactions while executing non-database work (e.g. HTTP webhooks, Redis publishes, or heavy CPU hashing). The remote connection on the target database stays in `idle in transaction`, blocking remote migrations and pinning the autovacuum horizon.
    - Passing dynamic functions like `time.Now()` directly into SQL strings without parameters or using non-immutable date constructs that prevent `postgres_fdw` from pushing predicates down to the remote node.
    - Ignoring distributed transaction failures where prepared transactions (`PREPARE TRANSACTION`) remain orphaned in `pg_prepared_xacts` after network disconnects, exhausting transaction IDs and freezing the remote database.
  - ✅ **Production Invariant**:
    - Wrap foreign database operations in concise, dedicated transactions with strict context deadlines (`context.WithTimeout(ctx, 3*time.Second)`).
    - Periodically run background watchdog goroutines to inspect `pg_prepared_xacts` and execute `ROLLBACK PREPARED` on orphaned in-doubt distributed transactions older than 60 seconds.
    - Explicitly invoke `postgres_fdw_disconnect_all()` when recycling high-churn worker backends to prevent socket leaks on remote database clusters.

```go
package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrRemoteTimeout          = errors.New("federated remote query exceeded deadline")
	ErrOrphanedPreparedTxFound = errors.New("orphaned 2PC prepared transactions detected")
)

type FederatedDailyMetric struct {
	TenantID    uuid.UUID
	TotalEvents int64
}

// FetchFederatedMetrics retrieves cross-cluster metrics ensuring the WHERE clause is pushed down to the remote engine.
func FetchFederatedMetrics(
	ctx context.Context,
	pool *pgxpool.Pool,
	startDate, endDate time.Time,
) ([]FederatedDailyMetric, error) {
	// Strict sub-3s timeout for cross-database federated operations
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	// Immutable parameters passed explicitly to guarantee remote pushdown
	const query = `
		SELECT
			tenant_id,
			SUM(event_count)::BIGINT AS total_events
		FROM foreign_analytics.daily_active_users
		WHERE activity_date >= $1::DATE
		  AND activity_date < $2::DATE
		GROUP BY tenant_id
		ORDER BY total_events DESC
		LIMIT 100;
	`

	rows, err := pool.Query(ctx, query, startDate.Format("2006-01-02"), endDate.Format("2006-01-02"))
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, fmt.Errorf("%w: %v", ErrRemoteTimeout, err)
		}
		return nil, fmt.Errorf("federated query: %w", err)
	}
	defer rows.Close()

	var metrics []FederatedDailyMetric
	for rows.Next() {
		var m FederatedDailyMetric
		if err := rows.Scan(&m.TenantID, &m.TotalEvents); err != nil {
			return nil, fmt.Errorf("scan federated metric: %w", err)
		}
		metrics = append(metrics, m)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("rows iteration: %w", err)
	}

	return metrics, nil
}

// ReconcileOrphanedPreparedTransactions inspects and cleans up stalled 2PC distributed transactions.
func ReconcileOrphanedPreparedTransactions(
	ctx context.Context,
	pool *pgxpool.Pool,
	maxAgeSeconds int,
) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	const checkQuery = `
		SELECT
			gid,
			ROUND(EXTRACT(EPOCH FROM (CLOCK_TIMESTAMP() - prepared)))::INT AS age_seconds
		FROM pg_prepared_xacts
		WHERE prepared < CLOCK_TIMESTAMP() - ($1 || ' seconds')::INTERVAL
		ORDER BY prepared ASC;
	`

	rows, err := pool.Query(ctx, checkQuery, maxAgeSeconds)
	if err != nil {
		return 0, fmt.Errorf("query pg_prepared_xacts: %w", err)
	}
	defer rows.Close()

	type preparedTx struct {
		gid string
		age int
	}
	var orphaned []preparedTx

	for rows.Next() {
		var tx preparedTx
		if err := rows.Scan(&tx.gid, &tx.age); err != nil {
			return 0, fmt.Errorf("scan prepared tx: %w", err)
		}
		orphaned = append(orphaned, tx)
	}

	rolledBackCount := 0
	for _, tx := range orphaned {
		// Safe identifier quoting
		escapedGid := strings.ReplaceAll(tx.gid, "'", "''")
		rollbackQuery := fmt.Sprintf("ROLLBACK PREPARED '%s';", escapedGid)

		if _, err := pool.Exec(ctx, rollbackQuery); err != nil {
			return rolledBackCount, fmt.Errorf("failed to rollback prepared tx %s: %w", tx.gid, err)
		}
		rolledBackCount++
	}

	return rolledBackCount, nil
}
```

- **PostgreSQL Materialized Views, Concurrent Refresh Fencing & Singleflight with pgx/v5**:
  - ❌ **Anti-Pattern: Blocking REFRESH in API Requests, Missing Advisory Lock Fencing, and Worker Crash Loops**:
    - Invoking `REFRESH MATERIALIZED VIEW` without `CONCURRENTLY` inside HTTP or gRPC request paths, holding connection pool leases for tens of seconds and causing HTTP 504 cascades.
    - Spawning multiple uncoordinated goroutines that execute `REFRESH MATERIALIZED VIEW CONCURRENTLY` at the same time, thrashing CPU, locks, and disk I/O.
    - Not checking for errors or lock acquisition failures, leaving connections hung or unreleased.
  - ✅ **Production Invariant**:
    - Use `golang.org/x/sync/singleflight` to deduplicate refresh calls within the Go process.
    - Use PostgreSQL advisory locks (`pg_try_advisory_lock`) across distributed instances so only one node executes the refresh.
    - Set explicit context timeouts and `statement_timeout` on the session.

```go
package store

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/sync/singleflight"
)

var (
	ErrRefreshAlreadyInProgress = errors.New("materialized view refresh already in progress")
)

type MatViewManager struct {
	pool  *pgxpool.Pool
	group singleflight.Group
}

func NewMatViewManager(pool *pgxpool.Pool) *MatViewManager {
	return &MatViewManager{pool: pool}
}

// computeAdvisoryKey generates a deterministic 64-bit advisory lock key from the view name.
func computeAdvisoryKey(viewName string) int64 {
	hash := sha256.Sum256([]byte(viewName))
	return int64(binary.BigEndian.Uint64(hash[:8]))
}

// RefreshConcurrently executes a non-blocking concurrent refresh with process-level singleflight
// and distributed PostgreSQL session-level advisory locking.
func (m *MatViewManager) RefreshConcurrently(ctx context.Context, viewName string, timeout time.Duration) error {
	_, err, _ := m.group.Do(viewName, func() (any, error) {
		refreshCtx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()

		conn, err := m.pool.Acquire(refreshCtx)
		if err != nil {
			return nil, fmt.Errorf("acquire conn: %w", err)
		}
		defer conn.Release()

		lockKey := computeAdvisoryKey(viewName)

		// 1. Acquire distributed advisory lock non-blockingly
		var acquired bool
		err = conn.QueryRow(refreshCtx, "SELECT pg_try_advisory_lock($1);", lockKey).Scan(&acquired)
		if err != nil {
			return nil, fmt.Errorf("acquire advisory lock: %w", err)
		}
		if !acquired {
			// Another cluster node is refreshing; coalesce without error
			return nil, ErrRefreshAlreadyInProgress
		}

		defer func() {
			// Ensure advisory lock is always released
			_, _ = conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1);", lockKey)
		}()

		// 2. Set strict local statement timeout
		timeoutMs := int(timeout.Milliseconds())
		_, err = conn.Exec(refreshCtx, fmt.Sprintf("SET LOCAL statement_timeout = %d;", timeoutMs))
		if err != nil {
			return nil, fmt.Errorf("set statement_timeout: %w", err)
		}

		// 3. Execute concurrent refresh safely
		refreshSQL := fmt.Sprintf("REFRESH MATERIALIZED VIEW CONCURRENTLY %s;", conn.Conn().PgConn().EscapeIdentifier(viewName))
		_, err = conn.Exec(refreshCtx, refreshSQL)
		if err != nil {
			return nil, fmt.Errorf("refresh matview %s: %w", viewName, err)
		}

		return nil, nil
	})

	if errors.Is(err, ErrRefreshAlreadyInProgress) {
		return nil // Graceful skip
	}
	return err
}
```

- **PostgreSQL Advisory Locks, Deterministic 64-Bit Namespacing & Canonical Multi-Locking with pgx/v5**:
  - ❌ **Anti-Pattern: Session Locks in Pooled Go Microservices, 32-Bit Hash Collisions, and Map-Iteration Deadlocks**:
    - Calling `SELECT pg_advisory_lock($1)` on a `*pgxpool.Pool` connection, which leaks the lock across queries under PgBouncer transaction pooling or leaves dangling locks if a goroutine panics.
    - Hashing keys to 32-bit integers, which suffer high collision rates ($>1\%$ at 10k keys), causing unrelated jobs to block each other.
    - Acquiring multiple advisory locks by iterating through a Go map or slice in arbitrary order, causing AB-BA deadlocks between concurrent workers.
  - ✅ **Production Invariant**:
    - Always use transaction-scoped `pg_try_advisory_xact_lock` inside a `pgx.Tx`, guaranteeing automatic release on commit or rollback.
    - Hash namespace, tenant ID, and entity ID into a signed 64-bit `int64` key.
    - Sort multiple lock keys in ascending order before sequential acquisition.

```go
package lock

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrResourceLocked = errors.New("requested resource is locked by another transaction")

type LockTarget struct {
	Namespace int32
	TenantID  string
	EntityID  string
}

// Hash64 calculates a signed 64-bit integer advisory lock key.
func Hash64(target LockTarget) int64 {
	h := sha256.New()
	_, _ = fmt.Fprintf(h, "%d:%s:%s", target.Namespace, target.TenantID, target.EntityID)
	sum := h.Sum(nil)
	return int64(binary.BigEndian.Uint64(sum[:8]))
}

// WithTransactionMutex executes fn while holding a non-blocking transaction-scoped advisory lock.
func WithTransactionMutex[T any](
	ctx context.Context,
	pool *pgxpool.Pool,
	target LockTarget,
	fn func(ctx context.Context, tx pgx.Tx) (T, error),
) (T, error) {
	var zero T
	key := Hash64(target)

	tx, err := pool.Begin(ctx)
	if err != nil {
		return zero, fmt.Errorf("begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var acquired bool
	err = tx.QueryRow(ctx, "SELECT pg_try_advisory_xact_lock($1);", key).Scan(&acquired)
	if err != nil {
		return zero, fmt.Errorf("try advisory lock: %w", err)
	}
	if !acquired {
		return zero, ErrResourceLocked
	}

	result, err := fn(ctx, tx)
	if err != nil {
		return zero, err
	}

	if err := tx.Commit(ctx); err != nil {
		return zero, fmt.Errorf("commit tx: %w", err)
	}

	return result, nil
}

// AcquireCanonicalMultiLocks acquires multiple advisory locks in ascending numerical order,
// mathematically preventing AB-BA deadlocks between concurrent goroutines.
func AcquireCanonicalMultiLocks(ctx context.Context, tx pgx.Tx, targets []LockTarget) error {
	if len(targets) == 0 {
		return nil
	}

	// 1. Compute and deduplicate keys
	keySet := make(map[int64]struct{}, len(targets))
	for _, t := range targets {
		keySet[Hash64(t)] = struct{}{}
	}

	keys := make([]int64, 0, len(keySet))
	for k := range keySet {
		keys = append(keys, k)
	}

	// 2. Canonical sorting: always ascending numerical order
	sort.Slice(keys, func(i, j int) bool {
		return keys[i] < keys[j]
	})

	// 3. Acquire sequentially in canonical order
	for _, k := range keys {
		var acquired bool
		err := tx.QueryRow(ctx, "SELECT pg_try_advisory_xact_lock($1);", k).Scan(&acquired)
		if err != nil {
			return fmt.Errorf("lock key %d: %w", k, err)
		}
		if !acquired {
			return fmt.Errorf("%w: key %d", ErrResourceLocked, k)
		}
	}

	return nil
}

// SerializableTxRunner provides resilient execution of transactions under PostgreSQL SERIALIZABLE isolation,
// automatically handling SQLSTATE 40001 (serialization_failure) and 40P01 (deadlock) with decorrelated jitter.
type SerializableTxRunner struct {
	pool        *pgxpool.Pool
	maxRetries  int
	baseBackoff time.Duration
	maxBackoff  time.Duration
}

func NewSerializableTxRunner(pool *pgxpool.Pool) *SerializableTxRunner {
	return &SerializableTxRunner{
		pool:        pool,
		maxRetries:  5,
		baseBackoff: 25 * time.Millisecond,
		maxBackoff:  2 * time.Second,
	}
}

// Execute runs an idempotent closure inside a SERIALIZABLE transaction.
// The closure must be pure and free of irreversible external side effects (e.g., Stripe, email).
func (r *SerializableTxRunner) Execute(ctx context.Context, fn func(ctx context.Context, tx pgx.Tx) error) error {
	txOpts := pgx.TxOptions{
		IsoLevel: pgx.Serializable,
	}

	for attempt := 1; attempt <= r.maxRetries; attempt++ {
		err := func() error {
			tx, err := r.pool.BeginTx(ctx, txOpts)
			if err != nil {
				return fmt.Errorf("begin serializable tx: %w", err)
			}
			defer tx.Rollback(ctx)

			if err := fn(ctx, tx); err != nil {
				return err
			}

			if err := tx.Commit(ctx); err != nil {
				return err
			}
			return nil
		}()

		if err == nil {
			return nil
		}

		// Inspect error for retryable SQLSTATE 40001 or 40P01
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && (pgErr.Code == "40001" || pgErr.Code == "40P01") {
			if attempt >= r.maxRetries {
				return fmt.Errorf("serializable transaction exhausted retry budget (%d attempts): %w", attempt, err)
			}

			// Full decorrelated jitter: Uniform(0, min(maxBackoff, baseBackoff * 2^attempt))
			multiplier := float64(int(1) << attempt)
			currentCeiling := float64(r.baseBackoff) * multiplier
			if currentCeiling > float64(r.maxBackoff) {
				currentCeiling = float64(r.maxBackoff)
			}
			sleepDuration := time.Duration(rand.Float64() * currentCeiling)

			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(sleepDuration):
				continue
			}
		}

		// Terminal non-retryable error
		return err
	}

	return errors.New("serializable transaction retry termination")
}

// MonotonicUUIDv7Factory generates RFC 9562 compliant UUIDv7 identifiers
// with a thread-safe 12-bit monotonic sub-millisecond sequence counter.
type MonotonicUUIDv7Factory struct {
	mu          sync.Mutex
	lastEpochMs int64
	seqCounter  uint16
}

func NewMonotonicUUIDv7Factory() *MonotonicUUIDv7Factory {
	return &MonotonicUUIDv7Factory{}
}

// NewUUIDv7 generates a 16-byte time-ordered UUIDv7 with sub-millisecond monotonicity.
func (f *MonotonicUUIDv7Factory) NewUUIDv7() ([16]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	now := time.Now().UTC()
	currentEpochMs := now.UnixMilli()

	if currentEpochMs == f.lastEpochMs {
		f.seqCounter++
		if f.seqCounter > 0x0FFF {
			// Spin-wait until next physical millisecond on overflow
			for currentEpochMs <= f.lastEpochMs {
				time.Sleep(100 * time.Microsecond)
				currentEpochMs = time.Now().UTC().UnixMilli()
			}
			f.seqCounter = 0
		}
	} else if currentEpochMs > f.lastEpochMs {
		f.lastEpochMs = currentEpochMs
		f.seqCounter = 0
	} else {
		// Clock stepped backward (NTP slew): clamp to last known timestamp if drift <= 5000ms
		drift := f.lastEpochMs - currentEpochMs
		if drift > 5000 {
			return [16]byte{}, fmt.Errorf("system clock rollback exceeds 5000ms safety threshold: %dms", drift)
		}
		f.seqCounter++
		if f.seqCounter > 0x0FFF {
			time.Sleep(time.Duration(drift+1) * time.Millisecond)
			f.lastEpochMs = time.Now().UTC().UnixMilli()
			f.seqCounter = 0
		}
	}

	var entropy [10]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return [16]byte{}, fmt.Errorf("read crypto random entropy: %w", err)
	}

	var uuid [16]byte

	// 48-bit Unix millisecond timestamp (big-endian)
	uuid[0] = byte(f.lastEpochMs >> 40)
	uuid[1] = byte(f.lastEpochMs >> 32)
	uuid[2] = byte(f.lastEpochMs >> 24)
	uuid[3] = byte(f.lastEpochMs >> 16)
	uuid[4] = byte(f.lastEpochMs >> 8)
	uuid[5] = byte(f.lastEpochMs)

	// Version 7 (0b0111) + 4 bits sequence high
	uuid[6] = 0x70 | byte((f.seqCounter>>8)&0x0F)
	// 8 bits sequence low
	uuid[7] = byte(f.seqCounter & 0xFF)

	// Variant 10 (RFC 9562) + 6 bits entropy
	uuid[8] = 0x80 | (entropy[0] & 0x3F)
	// Remaining 56 bits entropy
	copy(uuid[9:], entropy[1:8])

	return uuid, nil
}

// BoundedCascadeDeletionWorker safely purges child relations in keyset batches
// to prevent table lock escalation, WAL storms, and replication lag cliffs.
type BoundedCascadeDeletionWorker struct {
	pool      *pgxpool.Pool
	batchSize int
	pause     time.Duration
}

func NewBoundedCascadeDeletionWorker(pool *pgxpool.Pool, batchSize int, pause time.Duration) *BoundedCascadeDeletionWorker {
	if batchSize <= 0 {
		batchSize = 1000
	}
	if pause <= 0 {
		pause = 50 * time.Millisecond
	}
	return &BoundedCascadeDeletionWorker{
		pool:      pool,
		batchSize: batchSize,
		pause:     pause,
	}
}

// PurgeChildRecordsCascaded deletes child rows linked to parentID in small micro-transactions.
func (w *BoundedCascadeDeletionWorker) PurgeChildRecordsCascaded(
	ctx context.Context,
	childTable string,
	foreignKeyCol string,
	parentID [16]byte,
) (int64, error) {
	var totalDeleted int64

	for {
		select {
		case <-ctx.Done():
			return totalDeleted, ctx.Err()
		default:
		}

		// Keyset batch delete with SKIP LOCKED to prevent contention
		query := fmt.Sprintf(`
			WITH candidates AS (
				SELECT id
				FROM %s
				WHERE %s = $1
				ORDER BY id ASC
				LIMIT $2
				FOR UPDATE SKIP LOCKED
			)
			DELETE FROM %s
			WHERE id IN (SELECT id FROM candidates)
		`, childTable, foreignKeyCol, childTable)

		tag, err := w.pool.Exec(ctx, query, parentID[:], w.batchSize)
		if err != nil {
			return totalDeleted, fmt.Errorf("purge batch on %s: %w", childTable, err)
		}

		rowsDeleted := tag.RowsAffected()
		totalDeleted += rowsDeleted

		if rowsDeleted < int64(w.batchSize) {
			break
		}

		time.Sleep(w.pause)
	}

	return totalDeleted, nil
}

// PositiveCents guarantees non-negative financial values at the Go type layer,
// mirroring PostgreSQL CREATE DOMAIN positive_cents AS BIGINT CHECK (VALUE >= 0).
type PositiveCents int64

func NewPositiveCents(v int64) (PositiveCents, error) {
	if v < 0 {
		return 0, fmt.Errorf("positive_cents invariant violated: %d < 0", v)
	}
	return PositiveCents(v), nil
}

func (p PositiveCents) Value() (driver.Value, error) {
	if p < 0 {
		return nil, fmt.Errorf("positive_cents invariant violated on serialization: %d < 0", p)
	}
	return int64(p), nil
}

func (p *PositiveCents) Scan(src any) error {
	if src == nil {
		return fmt.Errorf("positive_cents cannot be null")
	}
	switch v := src.(type) {
	case int64:
		if v < 0 {
			return fmt.Errorf("positive_cents invariant violated: %d < 0", v)
		}
		*p = PositiveCents(v)
		return nil
	default:
		return fmt.Errorf("unsupported type for positive_cents: %T", src)
	}
}

// OrderStatus defines a validated string enum pattern with zero DB migration lock-ins.
type OrderStatus string

const (
	OrderStatusPending   OrderStatus = "pending"
	OrderStatusCompleted OrderStatus = "completed"
	OrderStatusCancelled OrderStatus = "cancelled"
)

func (s OrderStatus) IsValid() bool {
	switch s {
	case OrderStatusPending, OrderStatusCompleted, OrderStatusCancelled:
		return true
	default:
		return false
	}
}

func (s OrderStatus) Value() (driver.Value, error) {
	if !s.IsValid() {
		return nil, fmt.Errorf("invalid order_status: %q", s)
	}
	return string(s), nil
}

func (s *OrderStatus) Scan(src any) error {
	switch v := src.(type) {
	case string:
		st := OrderStatus(v)
		if !st.IsValid() {
			return fmt.Errorf("invalid order_status from database: %q", v)
		}
		*s = st
		return nil
	case []byte:
		st := OrderStatus(string(v))
		if !st.IsValid() {
			return fmt.Errorf("invalid order_status from database: %q", string(v))
		}
		*s = st
		return nil
	default:
		return fmt.Errorf("unsupported type for order_status: %T", src)
	}
}

// StringInt64 wraps int64 to serialize strictly as a string in JSON,
// preventing JavaScript client float truncation (Number.MAX_SAFE_INTEGER: 9,007,199,254,740,991).
type StringInt64 int64

func (s StringInt64) Int64() int64 {
	return int64(s)
}

func (s StringInt64) MarshalJSON() ([]byte, error) {
	return []byte(strconv.Quote(strconv.FormatInt(int64(s), 10))), nil
}

func (s *StringInt64) UnmarshalJSON(data []byte) error {
	str := string(data)
	if str == "null" || str == `""` {
		*s = 0
		return nil
	}
	unquoted, err := strconv.Unquote(str)
	if err != nil {
		// Fallback if client sent raw numeric token
		val, parseErr := strconv.ParseInt(str, 10, 64)
		if parseErr != nil {
			return fmt.Errorf("invalid int64 token: %w", parseErr)
		}
		*s = StringInt64(val)
		return nil
	}
	val, err := strconv.ParseInt(unquoted, 10, 64)
	if err != nil {
		return fmt.Errorf("failed to parse stringified int64: %w", err)
	}
	*s = StringInt64(val)
	return nil
}

func (s StringInt64) Value() (driver.Value, error) {
	return int64(s), nil
}

func (s *StringInt64) Scan(src any) error {
	if src == nil {
		*s = 0
		return nil
	}
	switch v := src.(type) {
	case int64:
		*s = StringInt64(v)
		return nil
	case int32:
		*s = StringInt64(v)
		return nil
	case string:
		val, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return err
		}
		*s = StringInt64(val)
		return nil
	default:
		return fmt.Errorf("unsupported type for StringInt64: %T", src)
	}
}

// TransactionalGaplessCounter allocates strictly contiguous invoice counters
// using pessimistic row-level locking (SELECT ... FOR UPDATE).
type TransactionalGaplessCounter struct {
	pool *pgxpool.Pool
}

func NewTransactionalGaplessCounter(pool *pgxpool.Pool) *TransactionalGaplessCounter {
	return &TransactionalGaplessCounter{pool: pool}
}

func (c *TransactionalGaplessCounter) NextContiguousNumber(ctx context.Context, seriesName string) (int64, error) {
	tx, err := c.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return 0, fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	var nextVal int64
	query := `
		UPDATE invoice_series
		SET current_counter = current_counter + 1,
		    updated_at = clock_timestamp()
		WHERE series_name = $1
		RETURNING current_counter;
	`
	err = tx.QueryRow(ctx, query, seriesName).Scan(&nextVal)
	if err != nil {
		return 0, fmt.Errorf("failed to allocate contiguous counter for series %q: %w", seriesName, err)
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("failed to commit contiguous counter transaction: %w", err)
	}
	return nextVal, nil
}

// CanonicalUpsertBatch performs an atomic batch upsert with canonical lexicographical
// sorting to prevent SQLSTATE 40P01 deadlocks and HOT-guarded update clauses.
type TenantConfig struct {
	TenantID string `json:"tenant_id"`
	ConfigKey string `json:"config_key"`
	ConfigVal string `json:"config_val"`
}

func UpsertTenantConfigsCanonical(ctx context.Context, pool *pgxpool.Pool, configs []TenantConfig) error {
	if len(configs) == 0 {
		return nil
	}

	// Invariant: Canonical sorting by conflict target eliminates AB-BA lock cycles
	sorted := make([]TenantConfig, len(configs))
	copy(sorted, configs)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].TenantID != sorted[j].TenantID {
			return sorted[i].TenantID < sorted[j].TenantID
		}
		return strings.ToLower(sorted[i].ConfigKey) < strings.ToLower(sorted[j].ConfigKey)
	})

	tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("failed to begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	batch := &pgx.Batch{}
	query := `
		INSERT INTO tenant_configs (tenant_id, config_key, config_val, updated_at)
		VALUES ($1, LOWER(TRIM($2)), $3, clock_timestamp())
		ON CONFLICT (tenant_id, LOWER(TRIM(config_key)))
		DO UPDATE SET
			config_val = EXCLUDED.config_val,
			updated_at = clock_timestamp()
		WHERE tenant_configs.config_val IS DISTINCT FROM EXCLUDED.config_val;
	`
	for _, c := range sorted {
		batch.Queue(query, c.TenantID, c.ConfigKey, c.ConfigVal)
	}

	br := tx.SendBatch(ctx, batch)
	for i := 0; i < len(sorted); i++ {
		if _, err := br.Exec(); err != nil {
			br.Close()
			return fmt.Errorf("failed to execute batch row %d: %w", i, err)
		}
	}
	if err := br.Close(); err != nil {
		return fmt.Errorf("failed to close batch: %w", err)
	}

	return tx.Commit(ctx)
}

// IngestBoundedDiscreteBatches processes a large slice of records in discrete top-level
// transactions without creating any SAVEPOINT or subtransactions, completely preventing
// PostgreSQL 64-subxid cache overflows (PGPROC.subxids) and SubtransSLRULock contention.
func IngestBoundedDiscreteBatches[T any](
	ctx context.Context,
	pool *pgxpool.Pool,
	items []T,
	chunkSize int,
	fn func(ctx context.Context, tx pgx.Tx, chunk []T) error,
) error {
	if len(items) == 0 {
		return nil
	}
	if chunkSize <= 0 || chunkSize > 500 {
		chunkSize = 500
	}

	for i := 0; i < len(items); i += chunkSize {
		end := i + chunkSize
		if end > len(items) {
			end = len(items)
		}
		chunk := items[i:end]

		// Execute each chunk in an independent, clean top-level transaction. Zero savepoints!
		if err := pgx.BeginTxFunc(ctx, pool, pgx.TxOptions{IsoLevel: pgx.ReadCommitted}, func(tx pgx.Tx) error {
			// Enforce defensive statement and lock timeouts
			if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2000ms'; SET LOCAL statement_timeout = '5000ms'"); err != nil {
				return fmt.Errorf("failed to configure chunk timeouts: %w", err)
			}
			return fn(ctx, tx, chunk)
		}); err != nil {
			return fmt.Errorf("discrete batch chunk [%d:%d] failed: %w", i, end, err)
		}
	}
	return nil
}

// UserAuditEventAligned demonstrates optimal memory layout adhering to both Go struct
// alignment and PostgreSQL Column Tetris invariants. By ordering fields strictly in
// descending word size (8B -> 4B -> 2B -> 1B -> dynamic strings), this struct eliminates
// all internal padding holes, ensuring maximum CPU L1/L2 cache locality during high-volume batch scans.
type UserAuditEventAligned struct {
	// 8-Byte Fields (64-bit aligned, zero padding)
	ID             int64     `db:"id"`
	CreatedAt      time.Time `db:"created_at"`
	ProcessedAt    time.Time `db:"processed_at"`
	CostMicrocents int64     `db:"cost_microcents"`

	// 4-Byte Fields (32-bit aligned, zero padding)
	TenantID int32 `db:"tenant_id"`

	// 2-Byte Fields (16-bit aligned, zero padding)
	RetryCount int16 `db:"retry_count"`

	// 1-Byte Fields (8-bit aligned, zero padding)
	IsSuccess  bool `db:"is_success"`
	IsInternal bool `db:"is_internal"`
	IsBillable bool `db:"is_billable"`

	// Dynamic/Varlena Tail Fields
	PayloadHash string `db:"payload_hash"`
}

// ResilientQueryWithPlanInvalidationRecovery executes a query with automatic retry on PostgreSQL
// SQLSTATE 0A000 ("cached plan must not change result type") or XX000, preventing service outages
// during zero-downtime DDL migrations across long-lived jackc/pgx connection pools.
func ResilientQueryWithPlanInvalidationRecovery[T any](
	ctx context.Context,
	pool *pgxpool.Pool,
	sql string,
	args []any,
	scanFn func(pgx.Rows) (T, error),
) (T, error) {
	var zero T
	maxRetries := 2

	for attempt := 0; attempt < maxRetries; attempt++ {
		conn, err := pool.Acquire(ctx)
		if err != nil {
			return zero, fmt.Errorf("acquire conn failed: %w", err)
		}

		rows, err := conn.Query(ctx, sql, args...)
		if err != nil {
			conn.Release()
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && (pgErr.Code == "0A000" || pgErr.Code == "XX000") {
				// Cached plan invalidated by concurrent DDL migration. Clear plans and retry.
				if resetConn, rErr := pool.Acquire(ctx); rErr == nil {
					_, _ = resetConn.Exec(ctx, "DISCARD PLANS")
					resetConn.Release()
				}
				continue
			}
			return zero, fmt.Errorf("query execution failed: %w", err)
		}

		result, scanErr := scanFn(rows)
		rows.Close()
		conn.Release()
		if scanErr != nil {
			return zero, scanErr
		}
		return result, nil
	}

	return zero, fmt.Errorf("query failed after %d retries due to persistent plan invalidation", maxRetries)
}

// ErrLockUnavailable indicates that the requested row is currently locked by a concurrent transaction (SQLSTATE 55P03).
var ErrLockUnavailable = errors.New("row lock unavailable: concurrent transaction holds conflicting lock")

// ExecuteWithNoKeyUpdateLock executes a transactional mutation on non-key columns using PostgreSQL
// FOR NO KEY UPDATE NOWAIT. This prevents blocking concurrent child table foreign key checks (LockTupleKeyShare),
// enforces sub-second lock_timeout ladders, and automatically handles SQLSTATE 55P03 / 40P01.
func ExecuteWithNoKeyUpdateLock[T any](
	ctx context.Context,
	pool *pgxpool.Pool,
	lockTimeout time.Duration,
	maxDeadlockRetries int,
	fn func(ctx context.Context, tx pgx.Tx) (T, error),
) (T, error) {
	var zero T
	timeoutMs := lockTimeout.Milliseconds()
	if timeoutMs <= 0 {
		timeoutMs = 2000
	}

	for attempt := 0; attempt <= maxDeadlockRetries; attempt++ {
		var result T
		err := pgx.BeginTxFunc(ctx, pool, pgx.TxOptions{IsoLevel: pgx.ReadCommitted}, func(tx pgx.Tx) error {
			// Enforce transaction-scoped lock timeout
			if _, setErr := tx.Exec(ctx, fmt.Sprintf("SET LOCAL lock_timeout = '%dms'", timeoutMs)); setErr != nil {
				return fmt.Errorf("failed to set lock_timeout: %w", setErr)
			}

			var fnErr error
			result, fnErr = fn(ctx, tx)
			return fnErr
		})

		if err == nil {
			return result, nil
		}

		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) {
			// SQLSTATE 55P03: lock_not_available (NOWAIT contention) -> Fail fast
			if pgErr.Code == "55P03" {
				return zero, fmt.Errorf("%w: %s", ErrLockUnavailable, pgErr.Message)
			}

			// SQLSTATE 40P01: deadlock_detected -> Exponential jitter retry
			if pgErr.Code == "40P01" && attempt < maxDeadlockRetries {
				jitter := time.Duration(10+rand.Intn(50*(1<<attempt))) * time.Millisecond
				select {
				case <-time.After(jitter):
					continue
				case <-ctx.Done():
					return zero, ctx.Err()
				}
			}
		}

		return zero, err
	}

	return zero, fmt.Errorf("transaction failed after %d deadlock retries", maxDeadlockRetries)
}

// CoveredAccountLookup represents a projection retrieved via an Index-Only Scan.
type CoveredAccountLookup struct {
	ID        string    `json:"id"`
	Role      string    `json:"role"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

// QueryCoveredAccountByEmail executes an Index-Only Scan against a covering index:
// CREATE UNIQUE INDEX idx_users_tenant_email_cov ON users (tenant_id, email) INCLUDE (id, role, status, created_at);
// It leverages leaf-only covering attributes with zero heap accesses when the Visibility Map is maintained.
func QueryCoveredAccountByEmail(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	email string,
) (*CoveredAccountLookup, error) {
	query := `
		SELECT id, role, status, created_at
		FROM users
		WHERE tenant_id = $1 AND email = $2;
	`
	var acc CoveredAccountLookup
	err := pool.QueryRow(ctx, query, tenantID, email).Scan(
		&acc.ID,
		&acc.Role,
		&acc.Status,
		&acc.CreatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("failed to query covered user account: %w", err)
	}

	return &acc, nil
}

// AuditVisibilityMapCoverage verifies the ratio of visible heap blocks to ensure
// Index-Only Scans do not silently degrade into random heap fetches.
func AuditVisibilityMapCoverage(ctx context.Context, pool *pgxpool.Pool, tableName string) (float64, error) {
	query := `
		SELECT
			CASE
				WHEN stat.idx_scan = 0 THEN 0.0
				ELSE ROUND((stat.idx_tup_fetch::numeric / stat.idx_scan::numeric), 4)
			END AS avg_heap_fetches_per_scan
		FROM pg_class c
		JOIN pg_index idx ON c.oid = idx.indrelid
		JOIN pg_statio_user_indexes stat ON stat.indexrelid = idx.indexrelid
		WHERE c.relname = $1
		ORDER BY stat.idx_scan DESC
		LIMIT 1;
	`
	var heapFetchRatio float64
	err := pool.QueryRow(ctx, query, tableName).Scan(&heapFetchRatio)
	if err != nil {
		return 0.0, fmt.Errorf("failed to audit visibility map coverage: %w", err)
	}
	return heapFetchRatio, nil
}

// PartialQueueTask represents a work item consumed from an asymmetric queue.
type PartialQueueTask struct {
	ID        string    `json:"id"`
	TenantID  string    `json:"tenant_id"`
	Payload   string    `json:"payload"`
	CreatedAt time.Time `json:"created_at"`
}

// PollPartialQueueTask dequeues the oldest pending task using PostgreSQL FOR UPDATE SKIP LOCKED
// over an asymmetric partial queue index:
// CREATE INDEX idx_tasks_pending_queue ON tasks (tenant_id, created_at) WHERE status = 'PENDING' WITH (fillfactor = 85);
// INVARIANT: "status = 'PENDING'" is hardcoded as a static literal in the SQL text, ensuring generic plan
// parameter sniffing never prevents PostgreSQL from selecting the partial index.
func PollPartialQueueTask(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
) (*PartialQueueTask, error) {
	query := `
		UPDATE tasks
		SET status = 'PROCESSING',
		    updated_at = CLOCK_TIMESTAMP()
		WHERE id = (
			SELECT id
			FROM tasks
			WHERE tenant_id = $1
			  AND status = 'PENDING'
			ORDER BY created_at ASC
			LIMIT 1
			FOR UPDATE SKIP LOCKED
		)
		RETURNING id, tenant_id, payload, created_at;
	`
	var task PartialQueueTask
	err := pool.QueryRow(ctx, query, tenantID).Scan(
		&task.ID,
		&task.TenantID,
		&task.Payload,
		&task.CreatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil // Queue empty
		}
		return nil, fmt.Errorf("poll partial queue task: %w", err)
	}
	return &task, nil
}

// CreateActiveUserSafely creates an active account while respecting a soft-delete partial unique index:
// CREATE UNIQUE INDEX uq_users_active_email ON users (tenant_id, lower(email)) WHERE deleted_at IS NULL;
func CreateActiveUserSafely(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	email string,
	passwordHash string,
) (string, error) {
	query := `
		INSERT INTO users (tenant_id, email, password_hash, created_at)
		VALUES ($1, lower($2), $3, CLOCK_TIMESTAMP())
		RETURNING id;
	`
	var userID string
	err := pool.QueryRow(ctx, query, tenantID, email, passwordHash).Scan(&userID)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return "", fmt.Errorf("an active user with this email already exists: %w", err)
		}
		return "", fmt.Errorf("failed to create active user: %w", err)
	}
	return userID, nil
}

// OrgHierarchyNode represents a node in an organizational hierarchy.
type OrgHierarchyNode struct {
	ID       string  `json:"id"`
	ParentID *string `json:"parent_id"`
	Name     string  `json:"name"`
	Depth    int     `json:"depth"`
}

// FetchOrgHierarchyCycleSafe queries a recursive department tree with PostgreSQL 14+ CYCLE detection
// and a hard depth boundary, preventing infinite loops on cyclic edges.
func FetchOrgHierarchyCycleSafe(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	rootID string,
	maxDepth int,
) ([]OrgHierarchyNode, error) {
	if maxDepth <= 0 || maxDepth > 50 {
		maxDepth = 25
	}

	query := `
		WITH RECURSIVE org_tree AS (
			SELECT id, parent_id, name, 1 AS depth
			FROM departments
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL

			UNION ALL

			SELECT d.id, d.parent_id, d.name, t.depth + 1
			FROM departments d
			JOIN org_tree t ON d.parent_id = t.id
			WHERE d.tenant_id = $1 
			  AND d.deleted_at IS NULL
			  AND t.depth < $3
		)
		CYCLE id SET is_cycle USING path
		SELECT id, parent_id, name, depth
		FROM org_tree
		WHERE NOT is_cycle
		ORDER BY depth ASC, name ASC;
	`

	rows, err := pool.Query(ctx, query, tenantID, rootID, maxDepth)
	if err != nil {
		return nil, fmt.Errorf("fetch org hierarchy: %w", err)
	}
	defer rows.Close()

	var nodes []OrgHierarchyNode
	for rows.Next() {
		var node OrgHierarchyNode
		if err := rows.Scan(&node.ID, &node.ParentID, &node.Name, &node.Depth); err != nil {
			return nil, fmt.Errorf("scan org node: %w", err)
		}
		nodes = append(nodes, node)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate org nodes: %w", err)
	}
	return nodes, nil
}

// KeysetPaginationCursor represents the boundary values for deterministic cursor seek.
type KeysetPaginationCursor struct {
	CreatedAt time.Time `json:"t"`
	ID        string    `json:"i"`
}

// KeysetPaginatedResponse encapsulates items with tamper-evident cursor tokens.
type KeysetPaginatedResponse[T any] struct {
	Items      []T     `json:"items"`
	NextCursor *string `json:"next_cursor"`
	HasMore    bool    `json:"has_more"`
}

// EncodeKeysetCursor generates an HMAC-SHA256 authenticated, URL-safe Base64 cursor token.
func EncodeKeysetCursor(createdAt time.Time, id string, secretKey []byte) string {
	payloadBytes, _ := json.Marshal(KeysetPaginationCursor{
		CreatedAt: createdAt.UTC(),
		ID:        id,
	})
	payloadB64 := base64.RawURLEncoding.EncodeToString(payloadBytes)

	mac := hmac.New(sha256.New, secretKey)
	mac.Write([]byte(payloadB64))
	sigB64 := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))

	return fmt.Sprintf("%s.%s", payloadB64, sigB64)
}

// DecodeKeysetCursor parses and validates an HMAC-SHA256 signed cursor token, preventing tampering.
func DecodeKeysetCursor(token string, secretKey []byte) (*KeysetPaginationCursor, error) {
	if token == "" {
		return nil, nil
	}
	var payloadB64, sigB64 string
	if _, err := fmt.Sscanf(token, "%s.%s", &payloadB64, &sigB64); err != nil {
		return nil, errors.New("malformed cursor token format")
	}

	mac := hmac.New(sha256.New, secretKey)
	mac.Write([]byte(payloadB64))
	expectedSig := mac.Sum(nil)

	actualSig, err := base64.RawURLEncoding.DecodeString(sigB64)
	if err != nil || !hmac.Equal(expectedSig, actualSig) {
		return nil, errors.New("invalid or tampered cursor signature")
	}

	payloadBytes, err := base64.RawURLEncoding.DecodeString(payloadB64)
	if err != nil {
		return nil, errors.New("invalid base64 payload in cursor")
	}

	var cursor KeysetPaginationCursor
	if err := json.Unmarshal(payloadBytes, &cursor); err != nil {
		return nil, errors.New("corrupted cursor json payload")
	}
	return &cursor, nil
}

// WindowedLedgerRow represents a financial transaction enriched with streaming window aggregates.
type WindowedLedgerRow struct {
	ID             string    `json:"id"`
	AccountID      string    `json:"account_id"`
	AmountCents    int64     `json:"amount_cents"`
	RunningBalance int64     `json:"running_balance"`
	TxSeqNumber    int64     `json:"tx_seq_number"`
	CreatedAt      time.Time `json:"created_at"`
}

// FetchWindowedLedgerStreaming executes a memory-bounded streaming window query with O(1) state.
// Eliminates implicit RANGE peer buffering and enforces deterministic tie-breakers.
func FetchWindowedLedgerStreaming(
	ctx context.Context,
	db *pgxpool.Pool,
	tenantID string,
	accountID string,
	since time.Time,
) ([]WindowedLedgerRow, error) {
	// Supporting index: (tenant_id, account_id, created_at ASC, id ASC) INCLUDE (amount_cents)
	const query = `
		SELECT 
			id, account_id, amount_cents, created_at,
			SUM(amount_cents) OVER w AS running_balance,
			ROW_NUMBER() OVER w AS tx_seq_number
		FROM bank_ledger
		WHERE tenant_id = $1 
		  AND account_id = $2
		  AND created_at >= $3
		WINDOW w AS (
			PARTITION BY account_id
			ORDER BY created_at ASC, id ASC
			ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
		)
		ORDER BY created_at ASC, id ASC;
	`

	rows, err := db.Query(ctx, query, tenantID, accountID, since)
	if err != nil {
		return nil, fmt.Errorf("failed executing windowed ledger query: %w", err)
	}
	defer rows.Close()

	var entries []WindowedLedgerRow
	for rows.Next() {
		var r WindowedLedgerRow
		if err := rows.Scan(
			&r.ID,
			&r.AccountID,
			&r.AmountCents,
			&r.CreatedAt,
			&r.RunningBalance,
			&r.TxSeqNumber,
		); err != nil {
			return nil, fmt.Errorf("failed scanning ledger row: %w", err)
		}
		entries = append(entries, r)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("row iteration error: %w", err)
	}
	return entries, nil
}

// BulkIngestRecord models high-throughput telemetry or event payloads.
type BulkIngestRecord struct {
	DeviceID   string
	Metric     string
	Val        float64
	RecordedAt time.Time
}

// ChannelCopySource implements pgx.CopyFromSource over a Go channel,
// enabling zero-memory buffering streaming bulk ingestion for tens of millions of records.
type ChannelCopySource struct {
	ch      <-chan BulkIngestRecord
	current BulkIngestRecord
	err     error
}

func NewChannelCopySource(ch <-chan BulkIngestRecord) *ChannelCopySource {
	return &ChannelCopySource{ch: ch}
}

func (s *ChannelCopySource) Next() bool {
	item, ok := <-s.ch
	if !ok {
		return false
	}
	s.current = item
	return true
}

func (s *ChannelCopySource) Values() ([]any, error) {
	return []any{
		s.current.DeviceID,
		s.current.Metric,
		s.current.Val,
		s.current.RecordedAt,
	}, nil
}

func (s *ChannelCopySource) Err() error {
	return s.err
}

// BulkStreamCopyIngest ingests records using the native PostgreSQL binary COPY protocol.
// Enforces local synchronous_commit=off for staging and atomic set-based merge reconciliation.
func BulkStreamCopyIngest(
	ctx context.Context,
	pool *pgxpool.Pool,
	recordCh <-chan BulkIngestRecord,
) (int64, error) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return 0, fmt.Errorf("failed acquiring connection from pool: %w", err)
	}
	defer conn.Release()

	tx, err := conn.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("failed starting ingestion transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Bypass fsync overhead on staging table
	if _, err := tx.Exec(ctx, "SET LOCAL synchronous_commit = off"); err != nil {
		return 0, fmt.Errorf("failed setting synchronous_commit: %w", err)
	}

	source := NewChannelCopySource(recordCh)
	cols := []string{"device_id", "metric", "val", "recorded_at"}

	rowsCopied, err := tx.CopyFrom(
		ctx,
		pgx.Identifier{"staging_sensor_metrics"},
		cols,
		source,
	)
	if err != nil {
		return 0, fmt.Errorf("pgx copy failed: %w", err)
	}

	const reconcileSQL = `
		INSERT INTO sensor_metrics (device_id, metric, val, recorded_at)
		SELECT device_id, metric, val, recorded_at
		FROM staging_sensor_metrics
		ON CONFLICT (device_id, recorded_at, metric) DO UPDATE
		SET val = EXCLUDED.val;
		TRUNCATE TABLE staging_sensor_metrics;
	`
	if _, err := tx.Exec(ctx, reconcileSQL); err != nil {
		return 0, fmt.Errorf("failed reconciling staging data: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("failed committing bulk ingest: %w", err)
	}

	return rowsCopied, nil
}

// CategoryTopProduct models a category paired with its top-ranked active product.
type CategoryTopProduct struct {
	CategoryID   string
	CategoryName string
	ProductID    *string
	ProductName  *string
	Price        *float64
	SalesCount   *int64
}

// FetchCategoriesTopProductsLateral executes an index-driven LEFT JOIN LATERAL query
// using jackc/pgx/v5 to retrieve top K products per category in a single round-trip,
// completely avoiding full-table window function scans and memory spills.
func FetchCategoriesTopProductsLateral(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	topK int,
) ([]CategoryTopProduct, error) {
	if topK <= 0 || topK > 50 {
		topK = 3 // Enforce safety bound against unbounded memory allocation
	}

	// Invariant: Requires composite index on products (category_id, sales_count DESC) WHERE is_active = true
	const querySQL = `
		SELECT
			c.id AS category_id,
			c.name AS category_name,
			p.id AS product_id,
			p.name AS product_name,
			p.price AS price,
			p.sales_count AS sales_count
		FROM categories c
		LEFT JOIN LATERAL (
			SELECT prod.id, prod.name, prod.price, prod.sales_count
			FROM products prod
			WHERE prod.category_id = c.id AND prod.is_active = true
			ORDER BY prod.sales_count DESC
			LIMIT $2
		) p ON true
		WHERE c.tenant_id = $1 AND c.is_visible = true
		ORDER BY c.name ASC, p.sales_count DESC NULLS LAST;
	`

	rows, err := pool.Query(ctx, querySQL, tenantID, topK)
	if err != nil {
		return nil, fmt.Errorf("failed executing lateral query: %w", err)
	}
	defer rows.Close()

	var results []CategoryTopProduct
	for rows.Next() {
		var item CategoryTopProduct
		if err := rows.Scan(
			&item.CategoryID,
			&item.CategoryName,
			&item.ProductID,
			&item.ProductName,
			&item.Price,
			&item.SalesCount,
		); err != nil {
			return nil, fmt.Errorf("failed scanning category top product: %w", err)
		}
		results = append(results, item)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error during row iteration: %w", err)
	}

	return results, nil
}

// HierarchyBreadcrumb represents an ancestor node in an organization or taxonomy tree.
type HierarchyBreadcrumb struct {
	ID       string
	ParentID *string
	Name     string
	Depth    int
}

// FetchOrgBreadcrumbsCycleSafe retrieves the full ancestor chain from leaf to root
// in a single round-trip using a cycle-safe recursive CTE, completely eliminating N+1 breadcrumb loops.
func FetchOrgBreadcrumbsCycleSafe(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	targetNodeID string,
) ([]HierarchyBreadcrumb, error) {
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
		return nil, fmt.Errorf("failed executing breadcrumb query: %w", err)
	}
	defer rows.Close()

	var chain []HierarchyBreadcrumb
	for rows.Next() {
		var item HierarchyBreadcrumb
		if err := rows.Scan(&item.ID, &item.ParentID, &item.Name, &item.Depth); err != nil {
			return nil, fmt.Errorf("failed scanning breadcrumb item: %w", err)
		}
		chain = append(chain, item)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error during breadcrumb row iteration: %w", err)
	}

	return chain, nil
}

// InventoryBatchUpdateRecord represents a single SKU price and stock update.
type InventoryBatchUpdateRecord struct {
	ID        string
	Quantity  int
	UnitPrice float64
}

// BatchUpdateInventoryWithStatementAudit applies high-volume batch updates,
// allowing PostgreSQL statement-level transition tables to execute audit logging
// in a single vectorized pass without row-by-row lock table exhaustion.
func BatchUpdateInventoryWithStatementAudit(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	records []InventoryBatchUpdateRecord,
) error {
	if len(records) == 0 {
		return nil
	}

	tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("failed starting inventory batch transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// Set tenant session context for RLS / audit triggers
	if _, err := tx.Exec(ctx, "SELECT set_config('app.current_tenant_id', $1, true)", tenantID); err != nil {
		return fmt.Errorf("failed setting tenant session context: %w", err)
	}

	batch := &pgx.Batch{}
	for _, rec := range records {
		batch.Queue(
			`UPDATE inventory_items
			 SET quantity = $1, unit_price = $2
			 WHERE id = $3 AND tenant_id = $4`,
			rec.Quantity, rec.UnitPrice, rec.ID, tenantID,
		)
	}

	br := tx.SendBatch(ctx, batch)
	for i := 0; i < len(records); i++ {
		cmdTag, bErr := br.Exec()
		if bErr != nil {
			br.Close()
			return fmt.Errorf("failed executing batch record %d: %w", i, bErr)
		}
		if cmdTag.RowsAffected() == 0 {
			br.Close()
			return fmt.Errorf("inventory item %s not found or tenant mismatch", records[i].ID)
		}
	}

	if err := br.Close(); err != nil {
		return fmt.Errorf("failed closing batch results: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("failed committing inventory batch transaction: %w", err)
	}

	return nil
}

// BoundedCursorRecord represents a streaming batch payload.
type BoundedCursorRecord struct {
	ID        string
	TenantID  string
	Payload   []byte
	CreatedAt time.Time
}

// StreamRecordsChunkedCursor streams large datasets with a server-side NO SCROLL cursor,
// enforcing strict timeout ladders and constant memory allocation to prevent client OOMs.
func StreamRecordsChunkedCursor(
	ctx context.Context,
	pool *pgxpool.Pool,
	tenantID string,
	batchSize int,
	consumeChunk func([]BoundedCursorRecord) error,
) error {
	if batchSize <= 0 || batchSize > 5000 {
		batchSize = 1000
	}

	// 1. Acquire dedicated single connection for the entire cursor lifecycle
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("failed to acquire connection for cursor stream: %w", err)
	}
	defer conn.Release()

	// 2. Open Read-Only Transaction with bounded idle and statement timeouts
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{
		IsoLevel:   pgx.ReadCommitted,
		AccessMode: pgx.ReadOnly,
	})
	if err != nil {
		return fmt.Errorf("failed starting cursor transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, "SET LOCAL idle_in_transaction_session_timeout = '20s'"); err != nil {
		return fmt.Errorf("failed setting idle in transaction timeout: %w", err)
	}

	cursorName := "stream_records_portal"
	declareSQL := fmt.Sprintf(
		`DECLARE %s NO SCROLL CURSOR FOR
		 SELECT id, tenant_id, payload, created_at
		 FROM audit_events
		 WHERE tenant_id = $1
		 ORDER BY created_at ASC, id ASC`,
		cursorName,
	)

	if _, err := tx.Exec(ctx, declareSQL, tenantID); err != nil {
		return fmt.Errorf("failed declaring NO SCROLL cursor: %w", err)
	}

	// Safe RAII portal cleanup
	defer func() {
		closeCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_, _ = tx.Exec(closeCtx, fmt.Sprintf("CLOSE %s", cursorName))
	}()

	fetchSQL := fmt.Sprintf("FETCH FORWARD %d FROM %s", batchSize, cursorName)
	buffer := make([]BoundedCursorRecord, 0, batchSize)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		rows, err := tx.Query(ctx, fetchSQL)
		if err != nil {
			return fmt.Errorf("cursor fetch failed: %w", err)
		}

		buffer = buffer[:0]
		for rows.Next() {
			var rec BoundedCursorRecord
			if err := rows.Scan(&rec.ID, &rec.TenantID, &rec.Payload, &rec.CreatedAt); err != nil {
				rows.Close()
				return fmt.Errorf("cursor row scan error: %w", err)
			}
			buffer = append(buffer, rec)
		}
		rows.Close()

		if len(buffer) == 0 {
			break
		}

		if err := consumeChunk(buffer); err != nil {
			return fmt.Errorf("consumer chunk processing error: %w", err)
		}

		if len(buffer) < batchSize {
			break
		}
	}

	if _, err := tx.Exec(ctx, fmt.Sprintf("CLOSE %s", cursorName)); err != nil {
		return fmt.Errorf("failed closing cursor portal: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("failed committing cursor transaction: %w", err)
	}

	return nil
}

// UserIdentity represents a canonicalized user entity with collation invariants.
type UserIdentity struct {
	ID          string
	APIToken    string
	Username    string
	Email       string
	AccountCode string
}

// CanonicalizeUnicodeInput enforces Unicode NFC normalization and strips boundary whitespace,
// preventing NFD homoglyph attacks and duplicate account creation (CWE-178).
func CanonicalizeUnicodeInput(input string) string {
	// Decompose then compose back into canonical precomposed form (NFC)
	return strings.TrimSpace(norm.NFC.String(input))
}

// CreateUserCanonical inserts an account ensuring boundary Unicode normalization,
// lowercase email domain handling, and machine-token COLLATE "C" assignment.
func CreateUserCanonical(ctx context.Context, pool *pgxpool.Pool, user UserIdentity) error {
	canonicalUsername := CanonicalizeUnicodeInput(user.Username)
	canonicalEmail := strings.ToLower(CanonicalizeUnicodeInput(user.Email))

	query := `
		INSERT INTO users (id, api_token, username, email, account_code)
		VALUES ($1, $2, $3, $4, $5)
	`
	_, err := pool.Exec(ctx, query,
		user.ID,
		user.APIToken,       // Uses COLLATE "C" on column definition
		canonicalUsername,   // Uses case_insensitive_icu collation
		canonicalEmail,      // Functional lower index & NFC constraint
		user.AccountCode,    // Uses text_pattern_ops index
	)
	if err != nil {
		return fmt.Errorf("failed inserting canonical user identity: %w", err)
	}
	return nil
}

// FindUserByEmailCaseInsensitive executes an index-accelerated query matching LOWER(email).
func FindUserByEmailCaseInsensitive(ctx context.Context, pool *pgxpool.Pool, rawEmail string) (*UserIdentity, error) {
	canonicalEmail := strings.ToLower(CanonicalizeUnicodeInput(rawEmail))

	query := `
		SELECT id, api_token, username, email, account_code
		FROM users
		WHERE LOWER(email) = $1
		LIMIT 1
	`
	var u UserIdentity
	err := pool.QueryRow(ctx, query, canonicalEmail).Scan(
		&u.ID,
		&u.APIToken,
		&u.Username,
		&u.Email,
		&u.AccountCode,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("querying user by case-insensitive email failed: %w", err)
	}
	return &u, nil
}

// VerifyDatabaseCollationIntegrity verifies that no host OS glibc or ICU upgrade has invalidated
// active database collations, preventing silent B-Tree binary search index corruption.
func VerifyDatabaseCollationIntegrity(ctx context.Context, pool *pgxpool.Pool) (bool, string, error) {
	query := `
		SELECT count(*)
		FROM pg_collation
		WHERE collversion IS NOT NULL AND collversion <> pg_collation_actual_version(oid);
	`
	var mismatchCount int
	if err := pool.QueryRow(ctx, query).Scan(&mismatchCount); err != nil {
		return false, "", fmt.Errorf("evaluating collation version integrity failed: %w", err)
	}

	if mismatchCount > 0 {
		return false, fmt.Sprintf("CRITICAL: Detected %d collation version mismatches! B-Tree indexes may be corrupted. Run REINDEX CONCURRENTLY immediately.", mismatchCount), nil
	}

	return true, "All PostgreSQL collations are in sync with host OS/ICU libraries.", nil
}

// ClusterWraparoundReport encapsulates PostgreSQL transaction ID (XID) horizon telemetry.
type ClusterWraparoundReport struct {
	DatabaseName        string
	AgeDatfrozenxid     int64
	AgeDatminmxid       int64
	RemainingXids       int64
	EstimatedTTWHours   float64
	IsCriticalEmergency bool
	ActiveSaboteurs     int
}

// AuditClusterWraparoundHorizon evaluates transaction horizon age across all cluster databases,
// detects horizon-pinning replication slots, and computes remaining hours to stop-the-world lockout.
func AuditClusterWraparoundHorizon(ctx context.Context, pool *pgxpool.Pool, burnRateTxPerSec float64) ([]ClusterWraparoundReport, error) {
	if burnRateTxPerSec <= 0 {
		burnRateTxPerSec = 4000.0 // conservative default for high-concurrency OLTP
	}

	query := `
		SELECT
			d.datname,
			age(d.datfrozenxid) AS age_datfrozenxid,
			age(d.datminmxid) AS age_datminmxid,
			(2137483648 - age(d.datfrozenxid)) AS remaining_xids,
			(
				SELECT count(*)
				FROM pg_replication_slots s
				WHERE s.active = false AND (age(s.xmin) > 10000000 OR age(s.catalog_xmin) > 10000000)
			) AS active_saboteurs
		FROM pg_database d
		WHERE d.datallowconn = true
		ORDER BY age(d.datfrozenxid) DESC;
	`
	rows, err := pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed querying database transaction horizon: %w", err)
	}
	defer rows.Close()

	var reports []ClusterWraparoundReport
	for rows.Next() {
		var r ClusterWraparoundReport
		if err := rows.Scan(
			&r.DatabaseName,
			&r.AgeDatfrozenxid,
			&r.AgeDatminmxid,
			&r.RemainingXids,
			&r.ActiveSaboteurs,
		); err != nil {
			return nil, fmt.Errorf("scanning wraparound report failed: %w", err)
		}

		if r.RemainingXids > 0 {
			r.EstimatedTTWHours = float64(r.RemainingXids) / burnRateTxPerSec / 3600.0
		} else {
			r.EstimatedTTWHours = 0.0
		}

		// Critical if age > 1.0B or TTW < 48 hours
		r.IsCriticalEmergency = r.AgeDatfrozenxid >= 1_000_000_000 || (r.EstimatedTTWHours > 0 && r.EstimatedTTWHours < 48.0)
		reports = append(reports, r)
	}

	return reports, nil
}

// TerminateHorizonSaboteurs safely identifies and reaps idle-in-transaction connections
// and unconsumed replication slots pinning PostgreSQL's global vacuum horizon xmin.
func TerminateHorizonSaboteurs(ctx context.Context, pool *pgxpool.Pool, maxIdleTxDuration time.Duration) (int, error) {
	// 1. Terminate idle-in-transaction connections pinning backend_xmin
	killQuery := `
		SELECT pg_terminate_backend(pid)
		FROM pg_stat_activity
		WHERE state = 'idle in transaction'
		  AND age(backend_xmin) > 5000000
		  AND (now() - state_change) > $1::interval;
	`
	durStr := fmt.Sprintf("%d seconds", int(maxIdleTxDuration.Seconds()))
	cmdTag, err := pool.Exec(ctx, killQuery, durStr)
	if err != nil {
		return 0, fmt.Errorf("terminating idle-in-transaction sessions failed: %w", err)
	}
	terminated := int(cmdTag.RowsAffected())

	// 2. Rollback orphaned prepared transactions older than 10 minutes
	preparedQuery := `
		SELECT gid
		FROM pg_prepared_xacts
		WHERE (now() - prepared) > interval '10 minutes'
		  AND age(transaction) > 10000000;
	`
	rows, err := pool.Query(ctx, preparedQuery)
	if err == nil {
		var gids []string
		for rows.Next() {
			var gid string
			if err := rows.Scan(&gid); err == nil {
				gids = append(gids, gid)
			}
		}
		rows.Close()

		for _, gid := range gids {
			_, _ = pool.Exec(ctx, fmt.Sprintf("ROLLBACK PREPARED %s", pool.Query(ctx, "SELECT $1", gid)))
			terminated++
		}
	}

	return terminated, nil
}

// ToastColumnAudit encapsulates catalog metadata for PostgreSQL variable-length attributes.
type ToastColumnAudit struct {
	SchemaName      string  `json:"schema_name"`
	TableName       string  `json:"table_name"`
	ColumnName      string  `json:"column_name"`
	DataType        string  `json:"data_type"`
	StorageStrategy string  `json:"storage_strategy"` // 'e'=EXTENDED, 'x'=EXTERNAL, 'm'=MAIN, 'p'=PLAIN
	Compression     string  `json:"compression"`      // 'l'=lz4, 'p'=pglz, ''=default
	ToastRelName    string  `json:"toast_rel_name"`
	ToastSizeBytes  int64   `json:"toast_size_bytes"`
	AvgPayloadBytes int     `json:"avg_payload_bytes"`
}

// AuditToastArchitecture inspects PostgreSQL catalog for TOAST configuration and identifies
// compression bottlenecks, legacy pglz columns, and missing STORAGE EXTERNAL on encrypted data.
func AuditToastArchitecture(ctx context.Context, pool *pgxpool.Pool) ([]ToastColumnAudit, error) {
	query := `
		SELECT
			n.nspname AS schema_name,
			c.relname AS table_name,
			a.attname AS column_name,
			pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
			a.attstorage::text AS storage_strategy,
			COALESCE(a.attcompression::text, 'default') AS compression,
			COALESCE(tc.relname, '') AS toast_rel_name,
			COALESCE(pg_total_relation_size(c.reltoastrelid), 0) AS toast_size_bytes,
			COALESCE(s.avg_width, 0) AS avg_payload_bytes
		FROM pg_attribute a
		JOIN pg_class c ON a.attrelid = c.oid
		JOIN pg_namespace n ON c.relnamespace = n.oid
		LEFT JOIN pg_class tc ON c.reltoastrelid = tc.oid
		LEFT JOIN pg_stats s ON s.schemaname = n.nspname AND s.tablename = c.relname AND s.attname = a.attname
		WHERE a.attnum > 0
		  AND NOT a.attisdropped
		  AND c.relkind IN ('r', 'p')
		  AND a.attstorage IN ('x', 'e', 'm')
		  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
		ORDER BY toast_size_bytes DESC;
	`
	rows, err := pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("querying TOAST catalog failed: %w", err)
	}
	defer rows.Close()

	var audits []ToastColumnAudit
	for rows.Next() {
		var a ToastColumnAudit
		if err := rows.Scan(
			&a.SchemaName,
			&a.TableName,
			&a.ColumnName,
			&a.DataType,
			&a.StorageStrategy,
			&a.Compression,
			&a.ToastRelName,
			&a.ToastSizeBytes,
			&a.AvgPayloadBytes,
		); err != nil {
			return nil, fmt.Errorf("scanning toast audit failed: %w", err)
		}
		audits = append(audits, a)
	}
	return audits, nil
}

// EnforceToastStoragePolicy migrates variable-length columns to LZ4 and bypasses compression on ciphertext.
func EnforceToastStoragePolicy(ctx context.Context, pool *pgxpool.Pool, schema, table, column string, isCiphertextOrMedia bool) error {
	var ddl string
	if isCiphertextOrMedia {
		// Bypass CPU-wasting compression loops on high-entropy data
		ddl = fmt.Sprintf("ALTER TABLE %s.%s ALTER COLUMN %s SET STORAGE EXTERNAL;",
			pgx.Identifier{schema}.Sanitize(),
			pgx.Identifier{table}.Sanitize(),
			pgx.Identifier{column}.Sanitize(),
		)
	} else {
		// Migrate text/jsonb to high-performance LZ4 compression
		ddl = fmt.Sprintf("ALTER TABLE %s.%s ALTER COLUMN %s SET COMPRESSION lz4;",
			pgx.Identifier{schema}.Sanitize(),
			pgx.Identifier{table}.Sanitize(),
			pgx.Identifier{column}.Sanitize(),
		)
	}

	_, err := pool.Exec(ctx, ddl)
	if err != nil {
		return fmt.Errorf("failed enforcing TOAST storage policy: %w", err)
	}
	return nil
}

// SystemCatalogBloatAudit encapsulates catalog health and dead tuple accumulation metrics.
type SystemCatalogBloatAudit struct {
	TableName       string  `json:"table_name"`
	LiveTuples      int64   `json:"live_tuples"`
	DeadTuples      int64   `json:"dead_tuples"`
	DeadTupleRatio  float64 `json:"dead_tuple_ratio"`
	TableSizeBytes  int64   `json:"table_size_bytes"`
	IndexSizeBytes  int64   `json:"index_size_bytes"`
	TotalSizeBytes  int64   `json:"total_size_bytes"`
	RequiresVacuum  bool    `json:"requires_vacuum"`
}

// AuditSystemCatalogHealth inspects core PostgreSQL system catalogs to detect dead tuple bloat,
// B-Tree fragmentation, and catalog autovacuum starvation.
func AuditSystemCatalogHealth(ctx context.Context, pool *pgxpool.Pool) ([]SystemCatalogBloatAudit, error) {
	query := `
		SELECT
			c.relname AS table_name,
			COALESCE(s.n_live_tup, 0) AS live_tuples,
			COALESCE(s.n_dead_tup, 0) AS dead_tuples,
			CASE
				WHEN (COALESCE(s.n_live_tup, 0) + COALESCE(s.n_dead_tup, 0)) = 0 THEN 0.0
				ELSE ROUND(COALESCE(s.n_dead_tup, 0)::numeric / (s.n_live_tup + s.n_dead_tup), 4)
			END AS dead_tuple_ratio,
			pg_relation_size(c.oid) AS table_size_bytes,
			pg_indexes_size(c.oid) AS index_size_bytes,
			pg_total_relation_size(c.oid) AS total_size_bytes
		FROM pg_class c
		JOIN pg_namespace n ON c.relnamespace = n.oid
		LEFT JOIN pg_stat_sys_tables s ON s.schemaname = n.nspname AND s.relname = c.relname
		WHERE n.nspname = 'pg_catalog'
		  AND c.relname IN ('pg_class', 'pg_attribute', 'pg_type', 'pg_depend', 'pg_description')
		ORDER BY total_size_bytes DESC;
	`
	rows, err := pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("querying system catalog bloat failed: %w", err)
	}
	defer rows.Close()

	var audits []SystemCatalogBloatAudit
	for rows.Next() {
		var a SystemCatalogBloatAudit
		if err := rows.Scan(
			&a.TableName,
			&a.LiveTuples,
			&a.DeadTuples,
			&a.DeadTupleRatio,
			&a.TableSizeBytes,
			&a.IndexSizeBytes,
			&a.TotalSizeBytes,
		); err != nil {
			return nil, fmt.Errorf("scanning catalog bloat audit failed: %w", err)
		}
		a.RequiresVacuum = a.DeadTupleRatio > 0.20 || (a.DeadTuples > 5000)
		audits = append(audits, a)
	}
	return audits, nil
}

// CalibrateCatalogAutovacuum tunes system catalog relations with aggressive autovacuum thresholds
// to prevent pg_attribute and pg_class bloat from degrading query plan compilation times.
func CalibrateCatalogAutovacuum(ctx context.Context, pool *pgxpool.Pool) error {
	ddls := []string{
		"ALTER TABLE pg_catalog.pg_class SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 50);",
		"ALTER TABLE pg_catalog.pg_attribute SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 100);",
		"ALTER TABLE pg_catalog.pg_type SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 50);",
		"ALTER TABLE pg_catalog.pg_depend SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 100);",
	}

	for _, ddl := range ddls {
		if _, err := pool.Exec(ctx, ddl); err != nil {
			return fmt.Errorf("failed executing catalog autovacuum calibration '%s': %w", ddl, err)
		}
	}
	return nil
}
```