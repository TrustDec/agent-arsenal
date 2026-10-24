---
description: Testing discipline, anti-flakiness invariants, mock hygiene, hermetic test isolation, and deterministic async verification
globs: **/*.{test,spec}.{ts,tsx,js,jsx},**/*_test.go,**/test_*.py,**/tests/**,**/cypress/**,**/playwright/**
alwaysApply: false
---

# Testing Discipline & Production Test Suite Invariants

> Add these rules to your project when writing unit, integration, or end-to-end (E2E) tests. Eliminate flaky CI runs, false-positive test passes, over-mocking antipatterns, and state pollution.

## 1. Zero-Flakiness Invariants & Clock Virtualization
- ❌ **ABSOLUTE BAN ON ARBITRARY SLEEP DELAYS**:
  - Never write `time.Sleep(500 * time.Millisecond)`, `await sleep(1000)`, or `time.sleep(1)` to wait for asynchronous events, network calls, or UI renders.
  - Arbitrary sleeps make test suites slow, fail intermittently under CI load, and mask underlying concurrency bugs.
- **Deterministic Polling & Condition Awaiting**:
  - Wait for explicit state transitions using bounded polling with backoff:
    ```ts
    // ✅ Wait for state transition with explicit timeout:
    await waitFor(() => {
      expect(screen.getByRole('status')).toHaveTextContent('Completed');
    }, { timeout: 3000, interval: 50 });
    ```
- **Virtualize Time for Temporal Logic**:
  - When testing timeouts, debouncing, throttling, token expiration, or scheduled jobs, virtualize the system clock instead of waiting in real-time:
    - **TypeScript / Jest / Vitest**: `vi.useFakeTimers(); vi.advanceTimersByTime(60_000);`
    - **Python**: `freezegun` or `time_machine` fixtures.
    - **Go**: Inject a clock interface or use `synctest` / virtualized tickers. Always restore real timers in teardown.

## 2. Mocking Hygiene & The Test Pyramid
- **The Mocking Hierarchy**:
  1. **Pure logic**: Test directly without any mocks.
  2. **Storage / State**: Prefer fast in-memory implementations (SQLite `:memory:`, fake repository) over mocking query builders.
  3. **External I/O (APIs, Payment Gateways, Email)**: Mock at the architectural adapter boundary (HTTP client / interface), never internal implementation details.
- ❌ **DO NOT MOCK WHAT YOU DO NOT OWN**:
  - Never mock third-party ORMs, database drivers, or low-level HTTP client internals. Mock your domain-level gateway/adapter interfaces (`PaymentGateway`, `Mailer`).
- ❌ **THE "TESTING THE MOCK" ANTIPATTERN**:
  - If 80% of a test file consists of mock setup (`mockRepo.findUser.mockResolvedValue(...)`), the test is testing mock configuration rather than real application behavior. Refactor to contract tests or integration tests with lightweight ephemeral test containers.
- **Contract Verification for Stubs**:
  - Stubs and fakes must satisfy the identical interface and validation contracts as the production implementation. Test your test fakes against contract test suites.

## 3. Hermetic Test Isolation & State Hygiene
- **Zero Shared Mutable State Across Tests**:
  - Every test case must be completely self-contained and runnable in total isolation or in randomized order (`--shuffle` / `--randomize`).
  - Never rely on another test having run first to populate test data.
- **Database Hermetic Isolation**:
  - Wrap database tests in an explicit transaction and roll it back in test cleanup:
    ```go
    tx := db.Begin()
    t.Cleanup(func() { tx.Rollback() })
    ```
  - For parallel multi-worker test runners, allocate unique isolated databases/schemas per test worker process (`test_db_${WORKER_ID}`) to prevent concurrent write collisions.
- **Teardown Invariant (Clean Up All Side Effects)**:
  - Always clean up temporary resources in `t.Cleanup` / `afterEach` / fixtures:
    - Close database connections and file descriptors.
    - Stop background goroutines, event listeners, and timers.
    - Delete temporary files (`t.TempDir()`). Leaked resources cause file descriptor exhaustion and hanging CI processes.

## 4. Table-Driven Tests & Boundary Matrix
- **Structured Parameterized Test Cases**:
  - Express complex business rules, validation logic, and state transitions using table-driven tests (Go table tests, Vitest `test.each`, Pytest `@pytest.mark.parametrize`).
  - Clearly document test case name, input data, and expected outcome:
    ```go
    tests := []struct {
        name        string
        input       string
        expectedErr error
    }{
        {name: "valid payload", input: `{"id": "usr_1"}`, expectedErr: nil},
        {name: "empty payload", input: "", expectedErr: ErrEmptyPayload},
        {name: "malformed json", input: `{"id":`, expectedErr: ErrMalformedJSON},
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            err := ParseUser(tc.input)
            require.ErrorIs(t, err, tc.expectedErr)
        })
    }
    ```
- **Mandatory Boundary Value Matrix**:
  - Always include explicit test cases for:
    - `nil`, `null`, `undefined`, and zero-value primitives.
    - Empty collections (`[]`, `{}`), empty strings (`""`), and whitespace-only strings.
    - Off-by-one boundary limits (0, 1, max integer, max payload size).
    - Non-ASCII, Unicode characters, and multi-byte emojis.
    - Expired timestamps and clock skew conditions.

## 5. Async, Concurrency & Race Condition Elimination
- ❌ **ZERO FLOATING PROMISES IN TESTS**:
  - In JavaScript/TypeScript tests, every asynchronous call MUST be `await`ed. Floating promises cause assertions to run after the test framework has declared the test passed, masking failures.
    ```ts
    // ❌ Floating promise: assertion runs out of band, test passes even if error is thrown:
    it('saves user', () => {
      userService.save(user).then(res => expect(res.id).toBeDefined());
    });

    // ✅ Explicitly awaited:
    it('saves user', async () => {
      const res = await userService.save(user);
      expect(res.id).toBeDefined();
    });
    ```
- **Always Run Race Detectors**:
  - For compiled concurrent languages, test with data race detectors enabled on CI:
    - Go: `go test -race -count=1 ./...`
    - Rust: Run with Miri or ThreadSanitizer where applicable.
- **Test Cancellation & Abort Signals**:
  - When testing long-running or streaming operations, explicitly test cancellation scenarios (e.g. triggering `AbortController.abort()` or canceling `context.Context`) and assert that resources are freed promptly.

## 6. Assertion Precision & Anti-Fragility
- ❌ **AVOID GIANT SNAPSHOT DUMPS**:
  - Giant full-page DOM snapshots or 1,000-line JSON snapshots create brittle test suites that developers blindly update (`-u`) without inspecting changes.
  - Use targeted semantic assertions focused exclusively on the critical behavior under test:
    ```ts
    // ✅ Assert only the contract properties relevant to the test:
    expect(response.body).toMatchObject({
      status: 'SUCCESS',
      account: { tier: 'ENTERPRISE' }
    });
    ```
- **Assert Error Codes & Types, Not Localized Error Strings**:
  - Test for structured error codes (`ERR_INSUFFICIENT_FUNDS`), custom error classes (`instanceof InsufficientFundsError`), or sentinel errors (`errors.Is(err, ErrInsufficientFunds)`).
  - Never assert exact error message strings (`"User has insufficient balance in wallet"`) which break upon minor copy edits or internationalization changes.
