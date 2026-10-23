# Golang Production Discipline & Concurrency Safety

> Add these rules to your project if developing in Go (Golang) microservices, CLI tools, or distributed backends.

## 1. Concurrency & Context Lifecycle
- **Context is King**: `ctx context.Context` MUST always be the first parameter in I/O and long-running functions. **NEVER** store `context.Context` inside a `struct`.
- **Zero Goroutine Leaks**: Every goroutine spawned MUST have a deterministic termination condition (e.g., listening to `ctx.Done()`, bounded channel send/receive, or managed via `golang.org/x/sync/errgroup`).
- **Race Condition Immunity**: Always run tests with the race detector enabled: `go test -race ./...`. Any detected data race is a blocking bug.
- **Mutex Discipline**: Always pair `mu.Lock()` with `defer mu.Unlock()` immediately on the next line unless micro-benchmarked in high-frequency critical sections with documented rationale.

## 2. Explicit Error Handling & Zero Panic
- ❌ **NEVER USE `_ = err` or ignore returned errors**: Check every single error return, including `f.Close()`, `w.Write()`, and JSON encoding.
- **Wrap with Context**: Wrap errors with context using `fmt.Errorf("failed to process order %s: %w", orderID, err)` to preserve the causal chain for `errors.Is` and `errors.As`.
- **Zero Panic in Production**: `panic()` is strictly forbidden in request/worker lifecycles. Panic is only permissible in `init()` or `main()` when mandatory configuration or static initialization fails fatally.

## 3. Resource Management & HTTP Safety
- **Drain Before Close**: When consuming HTTP response bodies, ALWAYS drain before closing to ensure TCP connection reuse (keep-alive):
  ```go
  resp, err := client.Do(req)
  if err != nil {
      return err
  }
  defer resp.Body.Close()
  _, _ = io.Copy(io.Discard, resp.Body)
  ```
- **Timeouts on All I/O**: Never use `http.DefaultClient` in production. Always configure explicit `Timeout`, `IdleConnTimeout`, and transport deadlines.
- **Nil Slice vs Empty Slice**: Be deliberate with JSON serialization. `var s []T` serializes to `null`, while `s := []T{}` serializes to `[]`. Use consistent conventions across API boundaries.

## 4. Architecture & Interface Restraint
- **Accept Interfaces, Return Concrete Types**: Keep interfaces small and caller-defined (1-2 methods like `io.Reader`). Do not export massive mock-oriented interfaces from provider packages.
- **No Package Garbage Dumps**: Ban generic `common`, `utils`, and `helper` packages. Organize packages by domain capability.
