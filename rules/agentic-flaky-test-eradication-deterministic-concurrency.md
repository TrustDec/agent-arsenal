---
description: Agentic flaky test eradication, race condition detection, deterministic concurrency verification, thread sanitizers, clock virtualization, ephemeral state isolation, and statistical stress testing across Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{test,spec}.{ts,tsx,js,jsx}*,**/*_test.go,**/test_*.py,**/tests/**,**/*.rs,**/cypress/**,**/playwright/**,**/vitest.config.*,**/jest.config.*
alwaysApply: false
---

# Agentic Flaky Test Eradication, Race Condition Detection & Deterministic Concurrency Verification

> Add these rules to your project when running, triaging, authoring, or refactoring test suites with autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode). Eliminate the "Test Lottery Trap" (where agents retry intermittent failures until green), the "Arbitrary Sleep Contention Disaster" (where hardcoded delays fail under CI thread load), and the "Shared State Cross-Pollution Collision" by enforcing a strict 5-Tier Flakiness Quarantine Ladder, mandatory `-race` / ThreadSanitizer execution, Go 1.24 `testing/synctest` & Vitest fake timer clock virtualization, per-test ephemeral schema isolation, and order-agnostic multiset assertions.

---

## 1. Architectural Taxonomy: The Intermittent Failure Dilemma vs The 5-Tier Flakiness Quarantine Ladder

In autonomous agentic software development, agents interact with test runners (`npm test`, `vitest`, `go test`, `pytest`, `cargo test`) as their primary feedback loop. While tests provide automated verification, intermittent, non-deterministic test failures (**flaky tests**) induce catastrophic failure modes in autonomous agents:

- **The "Retry Until Green" Test Lottery Trap**:
  - When an autonomous agent encounters a test failure, if the failure is non-deterministic (e.g. 1 failure in 5 runs), the agent re-executes the test command. When the test happens to pass on attempt 3, the agent assumes its code edit was successful and terminates its task.
  - In reality, the underlying race condition, deadlock, or timing bug remains completely unaddressed. The broken code is committed to version control, polluting CI pipelines and degrading team trust.
- **The Arbitrary Sleep Padding Antipattern (`time.Sleep`, `setTimeout`, `time.sleep`)**:
  - When an agent notices an asynchronous timing failure, its default heuristic is to inject arbitrary delays (`await new Promise(r => setTimeout(r, 1000))` or `time.Sleep(500 * time.Millisecond)`).
  - On a local developer machine with low CPU load, the sleep appears to fix the test. However, inside a resource-constrained, multi-threaded CI runner (e.g., GitHub Actions, GitLab CI), thread contention inflates microtask latency, causing the test to fail intermittently again while ballooning suite runtime from seconds to minutes.
- **The Shared Global State & Cross-Worker Mutation Collision**:
  - When test runners execute tests in parallel across worker processes (`pytest -n auto`, `vitest --threads`, `go test -p=8`), naive tests that read or write to shared resources (global singletons, shared database tables, static file caches, environment variables) collide.
  - Test A updates a database row while Test B is asserting against that row's original value. The resulting failure appears random and depends entirely on the operating system process scheduler.
- **The Non-Deterministic Collection Iteration & Relational Ordering Trap**:
  - Agents frequently assert array or slice equality (`expect(res).toEqual([...])`) on query results or dictionary iterations.
  - SQL queries without an explicit `ORDER BY` clause return rows in non-deterministic order depending on database disk pages, index scans, or vacuum status. Go maps deliberately randomize iteration order across runs. Asserting positional index values against unordered collections creates immediate flakiness.
- **The Ephemeral Port & Resource Contention Trap**:
  - Tests binding HTTP, gRPC, or WebSocket servers to hardcoded ports (`localhost:8080`) collide when run in parallel or across concurrent test suites, throwing `EADDRINUSE` errors intermittently.
- **The 5-Tier Flakiness Quarantine Ladder**:
  - Zero-flakiness engineering mandates 5 machine-enforced verification tiers before any test suite modification is accepted:
    - **Tier 0: Statistical Stress & Shuffling Gate**: Every modified or suspect test must pass $N=50$ (or $N=100$) consecutive iterations under randomized execution order and simulated CPU throttling with zero failures ($k_{\text{fail}} = 0$).
    - **Tier 1: Concurrency Sanitizer Enforcement**: Tests must execute under runtime race detectors (`go test -race`, Clang/GCC `-fsanitize=thread`, Node `--trace-uncaught`, Rust Loom/ThreadSanitizer). Any detected data race is an automatic hard failure.
    - **Tier 2: Clock Virtualization & Step Ticking**: Real-time wall-clock delays are strictly banned. Time must be virtualized using step tickers (Go 1.24 `testing/synctest`, Vitest/Jest `vi.useFakeTimers()`, Python `time_machine`).
    - **Tier 3: Hermetic Ephemeral Isolation**: Each test executes in an isolated sandbox with dynamic OS-assigned ports (`:0`), per-test PostgreSQL schemas (`test_schema_<uuid>`), isolated temp directories (`t.TempDir()`), and deterministic pseudo-random seeds.
    - **Tier 4: Order-Agnostic Structural Set Equivalence**: Assertions on collection outputs must enforce deterministic sorting or utilize bag/multiset equivalence comparisons (`expect(res).toIncludeSameMembers(...)`).

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Agent Encounters Intermittent Test Failure or Authors New Asynchronous Test                      │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: The Test Lottery]                                                ▼ [PRODUCTION: 5-Tier Quarantine Ladder]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ Re-run test 3 times until lucky green           │               │ Tier 0: Statistical Stress Gate (N = 50 runs)   │
│ ❌ Injects sleep(1000) to mask timing bug       │               │ • Run 50x in parallel under CPU throttle        │
│ ❌ Masks failure with test.skip or lax assert   │               │ • Flakiness confidence Pfail <= 0.001           │
│ ❌ Hardcoded localhost:8080 port collision      │               ├─────────────────────────────────────────────────┤
│ ❌ Asserts array order without ORDER BY         │               │ Tier 1: Concurrency Race Sanitizers             │
│ ❌ Leaves leaked goroutines & unclosed handles  │               │ • go test -race / ThreadSanitizer tsan          │
└─────────────────────────────────────────────────┘               │ • Zero unsynchronized shared memory reads       │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 2: Deterministic Clock Virtualization      │
                                                                  │ • Go 1.24 testing/synctest / vi.useFakeTimers() │
                                                                  │ • Zero real-world wall-clock sleeps             │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 3: Hermetic Ephemeral Isolation            │
                                                                  │ • Dynamic Port 0 (net.Listen(":0"))             │
                                                                  │ • Isolated per-test DB schemas test_uuid        │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 4: Order-Agnostic Set Equivalence          │
                                                                  │ • Bag comparison or deterministic ORDER BY id   │
                                                                  └─────────────────────────────────────────────────┘
```

---

## 2. Quantitative Flakiness Calculus & Statistical Confidence Models

Flakiness cannot be diagnosed from a single run. Autonomous agents must apply formal statistical confidence bounds to quantify flakiness probability and establish test reliability.

### 2.1. The Binomial Flakiness Confidence Model
Let a test suite run $N$ times. If the test fails $k$ times, the sample failure rate is $\hat{p} = \frac{k}{N}$.
For a flaky test with underlying intermittent failure probability $p_{\text{fail}}$, the probability of observing $k=0$ failures in $N$ consecutive runs is:

$$P(k = 0 \mid p_{\text{fail}}, N) = (1 - p_{\text{fail}})^N$$

To verify with $(1 - \alpha)$ statistical confidence (e.g. $95\%$ confidence, $\alpha = 0.05$) that an intermittent failure rate $p_{\text{fail}} \ge p_{\text{target}}$ does not exist:

$$N \ge \frac{\ln(\alpha)}{\ln(1 - p_{\text{target}})}$$

- For detecting an intermittent bug that occurs in $5\%$ of runs ($p_{\text{target}} = 0.05$) with $95\%$ confidence ($\alpha = 0.05$):
  $$N \ge \frac{\ln(0.05)}{\ln(0.95)} \approx \frac{-2.9957}{-0.0513} \approx 59 \text{ runs}$$
- Autonomous agents MUST execute at least **60 consecutive stress iterations** before certifying a flaky test remediation as complete.

### 2.2. The Flakiness Severity Score ($S_{\text{flake}}$)
When triaging test failures across a repository, the agent computes the **Flakiness Severity Score** $S_{\text{flake}} \in [0, 1]$:

$$S_{\text{flake}} = w_f \cdot \frac{k_{\text{fail}}}{N} + w_v \cdot \frac{\sigma_{\text{duration}}}{\mu_{\text{duration}}} + w_c \cdot \mathbb{I}_{\text{race}}$$

Where:
- $\frac{k_{\text{fail}}}{N}$ is the observed failure ratio ($w_f = 0.5$).
- $\frac{\sigma_{\text{duration}}}{\mu_{\text{duration}}}$ is the coefficient of variation of test execution duration ($w_v = 0.2$), indicating timing instability and thread starvation.
- $\mathbb{I}_{\text{race}} \in \{0, 1\}$ is the ThreadSanitizer / `-race` indicator ($w_c = 0.3$).
- If $S_{\text{flake}} > 0.05$, the test is classified as **CRITICALLY FLAKY** and must be quarantined immediately.

---

## 3. Strict Ecosystem Invariants for Flakiness Prevention

### 3.1. Go (1.24+) Production Invariants
- ❌ **BAN ON `time.Sleep` IN CONCURRENCY TESTS**: Never write `time.Sleep(100 * time.Millisecond)` to await a channel write, goroutine completion, or timer expiration.
- ✅ **Use Go 1.24 `testing/synctest`**: Use `synctest.Run(func() { ... })` to virtualize time and step all goroutines in a fake synthetic bubble:
  ```go
  // Go 1.24+ Deterministic Concurrency with synctest:
  func TestWorkerTimeout(t *testing.T) {
      synctest.Run(func() {
          w := NewWorker()
          go w.Start()

          // Advance virtual clock deterministically without real-world latency:
          time.Sleep(5 * time.Second) // Virtualized by synctest!
          synctest.Wait()             // Wait for all goroutines in bubble to block

          if !w.IsTimedOut() {
              t.Fatalf("expected worker to be timed out")
          }
      })
  }
  ```
- ✅ **Mandatory Goroutine Leak Sentinel (`goleak`)**: Always verify zero leaked goroutines in asynchronous test teardowns:
  ```go
  func TestMain(m *testing.M) {
      goleak.VerifyTestMain(m)
  }
  ```
- ✅ **Mandatory Dynamic Ephemeral Ports**: Never listen on static ports like `:8080`. Listen on `:0` to let the OS kernel assign a collision-free TCP port:
  ```go
  ln, err := net.Listen("tcp", "127.0.0.1:0")
  if err != nil {
      t.Fatalf("failed to bind ephemeral port: %v", err)
  }
  defer ln.Close()
  addr := ln.Addr().String()
  ```

### 3.2. TypeScript / Vitest / Node.js Invariants
- ❌ **BAN ON REAL TIMERS FOR TIMEOUT / DEBOUNCE TESTS**:
  - Never allow `setTimeout` or `setInterval` to elapse in real-time.
- ✅ **Vitest Fake Timers with Step Ticking**:
  ```typescript
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  test('debounced search executes exactly once after delay', async () => {
    const fn = vi.fn();
    const debounced = debounce(fn, 500);

    debounced('query');
    expect(fn).not.toHaveBeenCalled();

    // Advance clock precisely:
    vi.advanceTimersByTime(500);
    expect(fn).toHaveBeenCalledTimes(1);
  });
  ```
- ✅ **Deterministic Microtask Flushing**: When testing Promise resolution chains, always call `await flushPromises()` instead of arbitrary delays.

### 3.3. Database & SQL Invariants
- ❌ **BAN ON ARRAYS WITHOUT EXPLICIT `ORDER BY`**:
  - Relational databases guarantee zero ordering without an explicit `ORDER BY` clause. Any query asserted against a positional array MUST include a primary key tie-breaker (`ORDER BY created_at DESC, id ASC`).
- ✅ **Ephemeral Schema-per-Test Isolation**:
  - In parallel integration tests, never share database tables. Create an isolated schema per test run and drop it on teardown:
  ```sql
  -- Run at start of test worker:
  CREATE SCHEMA test_worker_a9f1;
  SET search_path TO test_worker_a9f1, public;
  -- Run at teardown:
  DROP SCHEMA test_worker_a9f1 CASCADE;
  ```

---

## 4. Production Reference Implementation: `AgenticFlakyTestDeFlakerEngine`

The following TypeScript engine provides a fully automated, standalone diagnostic and de-flaking harness. It executes statistical stress testing ($N$ iterations), parses race detector outputs, inspects AST patterns for anti-patterns (`time.Sleep`, `setTimeout`, un-ordered SQL assertions), and generates quarantine manifests.

```typescript
import { exec, spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import * as path from 'node:path';

export interface TestExecutionResult {
  runIndex: number;
  passed: boolean;
  durationMs: number;
  stdout: string;
  stderr: string;
  raceDetected: boolean;
  exitCode: number;
}

export interface FlakinessAnalysisReport {
  testIdentifier: string;
  totalRuns: number;
  passedRuns: number;
  failedRuns: number;
  failureRate: number;
  meanDurationMs: number;
  durationStdDevMs: number;
  racesDetectedCount: number;
  isFlaky: boolean;
  rootCauseCategory: 'CONCURRENCY_RACE' | 'WALL_CLOCK_DRIFT' | 'SHARED_STATE_COLLISION' | 'UNORDERED_COLLECTION' | 'UNKNOWN' | 'NONE';
  quarantineRecommended: boolean;
  identifiedAntiPatterns: string[];
}

export class AgenticFlakyTestDeFlakerEngine {
  private readonly targetDir: string;

  constructor(targetDir: string) {
    this.targetDir = targetDir;
  }

  /**
   * Execute N consecutive stress runs of a specific test command
   * to detect intermittent failures and timing variance.
   */
  async runStatisticalStressHarness(
    testCommand: string,
    iterations: number = 60,
    concurrency: number = 4
  ): Promise<TestExecutionResult[]> {
    const results: TestExecutionResult[] = [];
    let completed = 0;

    const worker = async (workerIndex: number): Promise<void> => {
      while (completed < iterations) {
        const runIndex = ++completed;
        const startTime = Date.now();
        const res = await this.executeSingleTest(testCommand);
        const durationMs = Date.now() - startTime;

        results.push({
          runIndex,
          passed: res.exitCode === 0,
          durationMs,
          stdout: res.stdout,
          stderr: res.stderr,
          raceDetected: this.detectDataRace(res.stdout, res.stderr),
          exitCode: res.exitCode,
        });
      }
    };

    const workers = Array.from({ length: concurrency }, (_, i) => worker(i));
    await Promise.all(workers);
    return results;
  }

  /**
   * Static AST & Regex inspection for flaky antipatterns inside test source code.
   */
  async inspectTestSourceCode(filePath: string): Promise<string[]> {
    const content = await fs.readFile(filePath, 'utf-8');
    const antiPatterns: string[] = [];

    // Check for hardcoded wall-clock sleeps:
    if (/time\.Sleep\(/m.test(content) || /setTimeout\(/m.test(content) || /time\.sleep\(/m.test(content)) {
      antiPatterns.push('PROHIBITED_WALL_CLOCK_SLEEP: Use clock virtualization (synctest / fake timers) instead of sleep');
    }

    // Check for hardcoded localhost ports:
    if (/localhost:\d{4,5}/m.test(content) || /127\.0\.0\.1:\d{4,5}/m.test(content)) {
      antiPatterns.push('HARDCODED_PORT_CONTENTION: Bind to port 0 (:0) for kernel-assigned ephemeral ports');
    }

    // Check for unseeded pseudo-random number generators:
    if (/Math\.random\(\)/m.test(content) || /rand\.Intn\(/m.test(content)) {
      antiPatterns.push('UNSEEDED_PSEUDO_RANDOMNESS: PRNG calls must use deterministic, reproducible seeds');
    }

    // Check for array assertions without explicit ORDER BY in SQL:
    if (/SELECT\s+.*?\s+FROM\s+/im.test(content) && !/ORDER\s+BY/im.test(content)) {
      if (/toEqual\(|assert\.Equal|assertEqual/m.test(content)) {
        antiPatterns.push('UNORDERED_SQL_RESULT_ASSERTION: Relational queries asserted against ordered slices must use ORDER BY');
      }
    }

    return antiPatterns;
  }

  /**
   * Analyzes stress execution results and static findings into a structured report.
   */
  analyzeResults(
    testIdentifier: string,
    results: TestExecutionResult[],
    antiPatterns: string[]
  ): FlakinessAnalysisReport {
    const totalRuns = results.length;
    const failedRuns = results.filter((r) => !r.passed).length;
    const passedRuns = totalRuns - failedRuns;
    const failureRate = totalRuns > 0 ? failedRuns / totalRuns : 0;
    const racesDetected = results.filter((r) => r.raceDetected).length;

    const durations = results.map((r) => r.durationMs);
    const meanDuration = durations.reduce((a, b) => a + b, 0) / (totalRuns || 1);
    const variance = durations.reduce((acc, d) => acc + Math.pow(d - meanDuration, 2), 0) / (totalRuns || 1);
    const durationStdDev = Math.sqrt(variance);

    // Determine if test is flaky: failed at least once, but passed at least once:
    const isFlaky = failedRuns > 0 && passedRuns > 0;

    let rootCause: FlakinessAnalysisReport['rootCauseCategory'] = 'NONE';
    if (racesDetected > 0) {
      rootCause = 'CONCURRENCY_RACE';
    } else if (antiPatterns.some((p) => p.includes('WALL_CLOCK_SLEEP'))) {
      rootCause = 'WALL_CLOCK_DRIFT';
    } else if (antiPatterns.some((p) => p.includes('HARDCODED_PORT'))) {
      rootCause = 'SHARED_STATE_COLLISION';
    } else if (antiPatterns.some((p) => p.includes('UNORDERED_SQL'))) {
      rootCause = 'UNORDERED_COLLECTION';
    } else if (isFlaky) {
      rootCause = 'UNKNOWN';
    }

    const quarantineRecommended = isFlaky || racesDetected > 0;

    return {
      testIdentifier,
      totalRuns,
      passedRuns,
      failedRuns,
      failureRate,
      meanDurationMs: Math.round(meanDuration),
      durationStdDevMs: Math.round(durationStdDev),
      racesDetectedCount: racesDetected,
      isFlaky,
      rootCauseCategory: rootCause,
      quarantineRecommended,
      identifiedAntiPatterns: antiPatterns,
    };
  }

  /**
   * Helper to detect ThreadSanitizer or Go race detector output.
   */
  private detectDataRace(stdout: string, stderr: string): boolean {
    const combined = `${stdout}\n${stderr}`;
    return (
      combined.includes('WARNING: DATA RACE') ||
      combined.includes('ThreadSanitizer: data race') ||
      combined.includes('fatal error: concurrent map read and map write') ||
      combined.includes('fatal error: concurrent map writes')
    );
  }

  /**
   * Execute a single shell command and capture outputs.
   */
  private executeSingleTest(command: string): Promise<{ stdout: string; stderr: string; exitCode: number }> {
    return new Promise((resolve) => {
      exec(command, { cwd: this.targetDir, env: process.env }, (error, stdout, stderr) => {
        resolve({
          stdout: stdout.toString(),
          stderr: stderr.toString(),
          exitCode: error ? error.code ?? 1 : 0,
        });
      });
    });
  }
}
```

---

## 5. The 6-State Flaky Test Eradication Finite-State Machine (FSM)

Autonomous coding agents MUST follow this deterministic finite-state machine when dealing with flaky tests. Transitioning to `VERIFIED_DETERMINISTIC` without passing all states is strictly prohibited.

```
       ┌────────────────────────────────────────────────────────┐
       │                   S0: DETECT_ANOMALY                   │
       │     (Test fails intermittently in CI or Stress Run)    │
       └───────────────────────────┬────────────────────────────┘
                                   │
                                   ▼
       ┌────────────────────────────────────────────────────────┐
       │                  S1: QUARANTINE_ISOLATE                │
       │    (Tag test @quarantine; prevent CI build blockage)   │
       └───────────────────────────┬────────────────────────────┘
                                   │
                                   ▼
       ┌────────────────────────────────────────────────────────┐
       │                  S2: REPRODUCE_CONCURRENT              │
       │  (Run N=60 stress loops under -race & CPU throttling)  │
       └───────────────────────────┬────────────────────────────┘
                                   │
                                   ▼
       ┌────────────────────────────────────────────────────────┐
       │                  S3: CLASSIFY_ROOT_CAUSE               │
       │  (Race / Clock Sleep / Shared State / Unordered Map)   │
       └───────────────────────────┬────────────────────────────┘
                                   │
                                   ▼
       ┌────────────────────────────────────────────────────────┐
       │                  S4: HARDEN_INVARIANTS                 │
       │  (Inject synctest/fake timers, Port 0, UUID schema)    │
       └───────────────────────────┬────────────────────────────┘
                                   │
                                   ▼
       ┌────────────────────────────────────────────────────────┐
       │                S5: CERTIFY_DETERMINISTIC               │
       │   (N=100 clean stress passes, 0 races, un-quarantine)  │
       └────────────────────────────────────────────────────────┘
```

### State Machine Transition Table
| Source State | Target State | Trigger / Event | Invariant Guarantees |
|---|---|---|---|
| `S0: DETECT_ANOMALY` | `S1: QUARANTINE_ISOLATE` | Intermittent pass/fail detected in CI or local run | Quarantine tag added; prevents main branch blocking while investigation proceeds. |
| `S1: QUARANTINE_ISOLATE` | `S2: REPRODUCE_CONCURRENT` | Stress harness initiated ($N \ge 60$ loops) | Test executed with race detector enabled (`-race`, `tsan`) under multi-threaded load. |
| `S2: REPRODUCE_CONCURRENT` | `S3: CLASSIFY_ROOT_CAUSE` | Failure or race signature captured deterministically | Failure classified into one of 5 root causes (Race, Sleep, Shared State, Order, Port). |
| `S3: CLASSIFY_ROOT_CAUSE` | `S4: HARDEN_INVARIANTS` | Anti-pattern replaced with deterministic primitive | Replaces `sleep` with virtual clock; replaces hardcoded port with `:0`; isolates DB schema. |
| `S4: HARDEN_INVARIANTS` | `S5: CERTIFY_DETERMINISTIC` | $N=100$ consecutive stress runs pass with 0 races | Machine-verified zero failure rate ($p_{\text{fail}} = 0$) across 100 runs. Quarantine lifted. |

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

An autonomous agent is strictly forbidden from claiming a flaky test is "fixed" unless every gate below passes:

| Gate | Verification Target | Machine Verification Command | Passing Criteria | Action on Failure |
|---|---|---|---|---|
| **Gate 1: Zero-Sleep Invariant** | Source code test files | `git diff -U0 \| grep -E "(time\.Sleep\|setTimeout\|time\.sleep)"` | 0 matches found in new/modified test code | Reject patch; replace sleep with clock virtualization or state polling. |
| **Gate 2: Race Sanitizer Pass** | Concurrency safety | `go test -race ./...` or `ctest --extra-verbose -R tsan` | 0 data races, 0 concurrent map read/write panics | Reject patch; synchronize shared memory access with mutex or channels. |
| **Gate 3: Statistical Stress Gate** | Intermittent failure elimination | `AgenticFlakyTestDeFlakerEngine.runStatisticalStressHarness(cmd, 60)` | $k_{\text{fail}} = 0$ over 60 consecutive parallel runs | Re-enter Root Cause Analysis; test remains flaky. |
| **Gate 4: Goroutine / Resource Leak** | Process teardown cleanliness | `go test -v -run TestWorker ./...` with `goleak` | Clean exit with 0 leaked goroutines or open sockets | Add proper context cancellation and defer close calls. |
| **Gate 5: Ephemeral Port Compliance** | Network socket bindings | `git diff \| grep -E "Listen\(\".*:[0-9]{2,5}\"\)"` | 0 hardcoded static port bindings; only port `:0` allowed | Replace static port with dynamic kernel-assigned `:0`. |
| **Gate 6: Deterministic Ordering** | Relational / Map assertions | Check for `ORDER BY` in SQL queries asserted against ordered slices | All queries contain explicit tie-breaker ordering | Append `ORDER BY id ASC` to SQL query or use bag equivalence. |

---

## 7. Concrete Anti-Patterns & Corrective Production Recipes

### Anti-Pattern 1: The Arbitrary Sleep Async Poll vs Deterministic Polling with Timeout
- ❌ **Anti-Pattern (Fragile Sleep Delay)**:
  ```typescript
  // ❌ FAILS intermittently when CI runner is CPU-throttled:
  test('processes background job', async () => {
    queue.push(task);
    // Arbitrary sleep: fails if background job takes 201ms in CI:
    await new Promise((r) => setTimeout(r, 200));
    expect(task.status).toBe('COMPLETED');
  });
  ```
- ✅ **Production Recipe (Bounded Deterministic Polling)**:
  ```typescript
  // ✅ Passes deterministically regardless of execution speed:
  test('processes background job', async () => {
    queue.push(task);
    await waitForCondition(
      async () => (await getTask(task.id))?.status === 'COMPLETED',
      { timeoutMs: 5000, pollIntervalMs: 20 }
    );
  });
  ```

### Anti-Pattern 2: Unordered SQL Results vs Deterministic Tie-Breakers
- ❌ **Anti-Pattern (Non-deterministic row order assertion)**:
  ```typescript
  // ❌ PostgreSQL returns rows in arbitrary order depending on table heap pages:
  const rows = await db.query('SELECT id, name FROM users WHERE team_id = $1', [teamId]);
  expect(rows).toEqual([
    { id: 1, name: 'Alice' },
    { id: 2, name: 'Bob' },
  ]); // Randomly fails if Bob is returned first!
  ```
- ✅ **Production Recipe (Explicit Tie-Breaker or Bag Comparison)**:
  ```typescript
  // ✅ Deterministic tie-breaker added to query:
  const rows = await db.query(
    'SELECT id, name FROM users WHERE team_id = $1 ORDER BY id ASC',
    [teamId]
  );
  expect(rows).toEqual([
    { id: 1, name: 'Alice' },
    { id: 2, name: 'Bob' },
  ]);
  // OR use bag comparison:
  expect(rows).toEqual(expect.arrayContaining([
    { id: 1, name: 'Alice' },
    { id: 2, name: 'Bob' },
  ]));
  ```

### Anti-Pattern 3: Shared Database Collision vs Ephemeral Schema Isolation
- ❌ **Anti-Pattern (Shared Database Mutation in Parallel Tests)**:
  ```go
  // ❌ Parallel tests overwrite the same tenant row simultaneously:
  func TestUpdateBalance_Parallel(t *testing.T) {
      t.Parallel()
      db.Exec("UPDATE accounts SET balance = 100 WHERE id = 1")
      // Collides with another parallel test updating account 1!
  }
  ```
- ✅ **Production Recipe (Per-Test Ephemeral Schema Isolation)**:
  ```go
  // ✅ Each test runs in its own hermetic database schema:
  func TestUpdateBalance_Isolated(t *testing.T) {
      t.Parallel()
      schema := fmt.Sprintf("test_%s", strings.ReplaceAll(uuid.New().String(), "-", ""))
      db.Exec(fmt.Sprintf("CREATE SCHEMA %s", schema))
      t.Cleanup(func() {
          db.Exec(fmt.Sprintf("DROP SCHEMA %s CASCADE", schema))
      })

      conn := getConnWithSearchPath(schema)
      conn.Exec("CREATE TABLE accounts (id INT PRIMARY KEY, balance INT)")
      conn.Exec("INSERT INTO accounts VALUES (1, 100)")
      // Completely isolated from all other concurrent test workers!
  }
  ```
