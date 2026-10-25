---
description: Agentic self-correction, automated debugging, root cause analysis (RCA), deterministic bug reproduction harnesses, fault localization (SBFL/Tarantula/Ochiai), automated git bisect, delta debugging (ddmin), anti-masking disciplines, and regression verification funnels
globs: **/*{debug,repro,test,fix,investigate,rca,fault,patch,bisect}*.*,**/tests/**,**/test/**,**/spec/**,**/fixtures/**
alwaysApply: false
---

# Agentic Self-Correction, Automated Debugging & Root Cause Analysis (RCA) Invariants

> Add these rules to your project when architecting, implementing, or auditing autonomous coding agents, automated debugging workflows, bug fixing loops, or SWE-bench software engineering harnesses (Claude Code, Cursor, Windsurf, Aider, OpenCode, Devon, Pi).

---

## 1. Architectural Taxonomy: The Scientific Debugging FSM vs Speculative Thrashing

The most catastrophic failure mode of autonomous coding agents is **Speculative Shotgun Patching**: an agent observes a failing test or error log, hallucinates a vague guess, modifies 3–5 random files across the codebase, encounters 4 new errors, wraps broken code in empty `try/catch` or returns dummy fallback values, drifts completely away from the core problem, and contaminates the working tree with broken, unverified diffs.

Production-grade coding agents must strictly operate as a deterministic **Scientific Debugging Finite-State Machine (FSM)**:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              Incoming Bug Report / CI Failure                          │
│                      ("HTTP 500 on checkout: panic in calculateDiscounts")              │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 1: Deterministic Reproduction Harness (The Repro Invariant)                      │
│    • Total ban on modifying production code before a repro test exists.                │
│    • Author an isolated, hermetic reproduction script or unit test.                    │
│    • Execute baseline test: MUST fail with the EXACT reported error/exit code.         │
│    • If repro passes or fails with an unrelated error ➔ REJECT REPRO, DO NOT PROCEED. │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │ Baseline Confirmed Failing
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 2: Fault Localization & Causal Tracing (Where is the bug?)                       │
│    • Stack trace boundary analysis: strip runtime/framework noise to find app frame.  │
│    • Spectrum-Based Fault Localization (SBFL / Ochiai): rank suspicious statements.   │
│    • Automated `git bisect`: isolate culprit commit causing regression in O(log N).    │
│    • Causal Delta Debugging (ddmin): minimize failing payload to minimal reproduction. │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │ Minimal Suspicious Region Isolated
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 3: Falsifiable Hypothesis Formulation (Why did it fail?)                         │
│    • Formulate explicit, testable causal hypothesis:                                   │
│      "Hypothesis: Nil pointer dereference occurs when coupon.ExpiresAt is NULL in DB"  │
│    • Identify the exact violated invariant (nullability, off-by-one, race condition).  │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │ Hypothesis Established
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 4: Surgical Root-Cause Intervention (Minimal AST Delta)                          │
│    • Total ban on symptom suppression (empty catch, dummy returns, weakening asserts). │
│    • Apply surgical fix to root cause at the definition site, not call-site band-aids. │
│    • Keep diff bounded strictly to affected lines (<10–20 lines changed).             │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │ Surgical Patch Applied
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 5: Closed-Loop Verification Funnel (The 5 Quality Gates)                         │
│    • Gate 1: Repro test now PASSES deterministically.                                  │
│    • Gate 2: Static typing & AST checks pass (`tsc --noEmit`, `go vet`, `mypy`).       │
│    • Gate 3: Local module test suite passes (0 regressions introduced).                │
│    • Gate 4: Transitive blast radius test suite passes across all callers.             │
│    • Gate 5: Promote repro test to permanent regression suite (`tests/regressions/`).  │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                    ┌───────────────────────┴───────────────────────┐
             All Gates Pass                                    Any Gate Fails
                    │                                               │
                    ▼                                               ▼
┌──────────────────────────────────────┐        ┌──────────────────────────────────────┐
│ Commit & Ship Root Cause Fix         │        │ The 3-Attempt Backtracking Circuit   │
│ • Atomic git commit with repro test. │        │ • Rollback dirty workspace (`git checkout`)│
│ • Clear causal changelog entry.      │        │ • Explicitly INVALIDATE hypothesis.  │
└──────────────────────────────────────┘        │ • Try next hypothesis (max 3 turns). │
                                                └──────────────────────────────────────┘
```

---

## 2. Minimal Reproducible Test Harnesses (The Repro Invariant)

### The Absolute Invariant
> ❌ **RULE 0: NEVER TOUCH PRODUCTION SOURCE CODE UNTIL A DETERMINISTIC REPRODUCING TEST EXISTS AND IS CONFIRMED FAILING.**

Modifying code before confirming reproduction leads to "phantom debugging" — attempting to fix an issue that was never reproduced, introducing regressions, and falsely claiming victory when the original bug remains latent in production.

### Authoring Hermetic Reproduction Tests
1. **Targeted Script or Test Case**:
   - Write a standalone test file or reproduction script:
     - Go: `repro_test.go`
     - TypeScript: `repro.spec.ts`
     - Python: `test_repro.py`
     - Shell: `repro.sh`
2. **Causal Failure Assertion**:
   - The test must assert specifically on the failing behavior, not just generic failure:
     ```ts
     // ❌ Fragile Repro: Fails on any error (syntax error, missing env var, timeout)
     test('reproduce bug', async () => {
       await expect(checkoutService.processOrder(payload)).rejects.toThrow();
     });

     // ✅ Hermetic Repro: Asserts exact error type, code, and message substring
     test('reproduce issue #402: null pointer dereference on expired coupon', async () => {
       const payload = createTestOrder({ couponCode: 'EXPIRED_2026' });

       // Must specifically fail with coupon expiry validation error, NOT a DB connection panic
       await expect(checkoutService.processOrder(payload))
         .rejects
         .toThrowError(/coupon code 'EXPIRED_2026' has expired on/i);
     });
     ```
3. **Hermetic Environment Isolation**:
   - Use virtualized time (`vi.useFakeTimers()`, Go `synctest`, Python `freezegun`).
   - Use in-memory SQLite or ephemeral test containers rather than shared state.
   - Never rely on external internet access or live production endpoints.

---

## 3. Automated Fault Localization & Spectrum-Based Diagnosis

When tests fail or exceptions are raised, agents must locate the exact line and function responsible without wandering blindly through the repository.

### 1. Stack Trace Boundary Invariant
Stack traces in modern web frameworks (Next.js, Express, FastAPI, Gin) span 40–80 stack frames, of which 90% are framework runtime internals (`node:internal/process/task_queues`, `starlette/middleware/base.py`, `runtime/asm_amd64.s`).
- **The Application Boundary Rule**: Parse stack traces from top to bottom. Filter out node_modules, vendor directories, and language runtime paths. The **first frame belonging to application source code** is the primary suspect entrypoint:

```ts
// Stack trace parser filtering framework noise
export function extractApplicationBoundaryFrame(stack: string, projectRoot: string): StackFrame | null {
  const lines = stack.split('\n');
  const frameRegex = /at (?:(.+?)\s+\()?(?:(.+?):(\d+):(\d+))\)?/;

  for (const line of lines) {
    const match = line.match(frameRegex);
    if (!match) continue;

    const [, symbol, filePath, lineNum, colNum] = match;
    const isRuntime = filePath.startsWith('node:') || filePath.includes('/node_modules/');
    const isInsideProject = filePath.startsWith(projectRoot);

    if (isInsideProject && !isRuntime) {
      return {
        symbol: symbol || 'anonymous',
        filePath,
        line: parseInt(lineNum, 10),
        column: parseInt(colNum, 10),
      };
    }
  }
  return null;
}
```

### 2. Spectrum-Based Fault Localization (SBFL: Ochiai Metric)
For complex algorithmic bugs where all unit tests compile but specific edge cases fail, use Spectrum-Based Fault Localization to rank suspicious statements based on test coverage spectra:

$$\text{Suspiciousness}(s) = \frac{\text{failed}(s)}{\sqrt{\text{total\_failed} \times (\text{failed}(s) + \text{passed}(s))}}$$

Where:
- $\text{failed}(s)$: Number of failing tests that executed statement $s$.
- $\text{passed}(s)$: Number of passing tests that executed statement $s$.
- $\text{total\_failed}$: Total number of failing test cases in the test suite.

If a statement $s$ is executed by every failing test and by zero passing tests, its suspiciousness score is $1.0$ (highest priority investigation candidate). If a statement is executed by all passing tests and zero failing tests, its score is $0.0$.

---

## 4. Git Bisect Automation for Regression Pinpointing

When a previously working feature breaks, manual code reading is an order of magnitude slower than binary searching Git commit history.

### The Automated Bisection State Machine
Agents must automate `git bisect` using an isolated subshell and a deterministic reproduction script:

```bash
#!/usr/bin/env bash
# Automated agent regression bisection
set -euo pipefail

REPRO_SCRIPT="./scripts/repro.sh"
KNOWN_GOOD_COMMIT="v2.4.0"
CURRENT_BAD_COMMIT="HEAD"

echo "🔍 Starting automated git bisection between $KNOWN_GOOD_COMMIT and $CURRENT_BAD_COMMIT..."

# Initialize bisection
git bisect start "$CURRENT_BAD_COMMIT" "$KNOWN_GOOD_COMMIT"

# Run bisection automatically: exit code 0 = good, exit code 1-127 (except 125) = bad
# 125 skips untestable commits (e.g. broken build)
git bisect run bash -c "
  npm ci --silent >/dev/null 2>&1 || exit 125
  $REPRO_SCRIPT
"

CULPRIT_COMMIT="$(git rev-parse HEAD)"
echo "🎯 Culprit commit isolated: $CULPRIT_COMMIT"
git show --stat "$CULPRIT_COMMIT"

# Terminate bisection and return to working branch
git bisect reset
```

### Culprit Diff Decomposition
Once the culprit commit is isolated:
1. Extract the commit diff: `git show $CULPRIT_COMMIT`.
2. Inspect the exact invariant that was modified (e.g., changed default argument, deleted validation branch, modified regex).
3. Determine whether the bug is an unintended regression in the commit or an intentional breaking change whose downstream callers were not updated.

---

## 5. Delta Debugging (ddmin) & Input Minimization

When a bug is triggered by a massive input payload (e.g., a 5,000-line JSON payload, 10MB CSV file, or multi-step API trace), feeding the entire payload to the LLM overflows context budgets and clouds the causal relationship.

### Algorithmic Minimization Protocol (ddmin)
Delta debugging recursively divides failing input chunks into halves to discover the **1-minimal failing test case** (removing any single element makes the bug disappear):

```python
def ddmin(failing_input: list[str], test_fn) -> list[str]:
    """
    Minimizes failing input lines/chunks to the minimal reproducible set.
    test_fn returns 'FAIL' if bug reproduces, 'PASS' otherwise.
    """
    n = 2
    current = failing_input

    while len(current) >= 2:
        subsets = [current[i::n] for i in range(n)]
        reduced = False

        for subset in subsets:
            if test_fn(subset) == "FAIL":
                current = subset
                n = max(n - 1, 2)
                reduced = True
                break

        if not reduced:
            # Try complements
            for i, subset in enumerate(subsets):
                complement = [item for j, sub in enumerate(subsets) if j != i for item in sub]
                if test_fn(complement) == "FAIL":
                    current = complement
                    n = max(n - 1, 2)
                    reduced = True
                    break

        if not reduced:
            if n >= len(current):
                break
            n = min(n * 2, len(current))

    return current
```

---

## 6. Anti-Masking & Error Suppression Invariants (Total Ban on AI Slop)

Frontier LLMs have a strong sycophantic bias toward "making the test pass" rather than "fixing the underlying defect." Agents frequently engage in symptom masking and error suppression.

### The 6 Absolute Prohibitions

| Prohibited AI Anti-Pattern | Description | Production Invariant |
| :--- | :--- | :--- |
| ❌ **Empty Catch Blocks** | `try { fn(); } catch (e) {}` or `except: pass` | Fix the root cause or propagate structured domain error. |
| ❌ **Dummy Return Values** | Returning `null`, `""`, `0`, or `[]` on invalid state | Throw descriptive error or fail fast; never disguise failures. |
| ❌ **Weakening Assertions** | Changing `toBe(42)` to `toBeDefined()` or `toBeTruthy()` | Assert exact expected mathematical value and structure. |
| ❌ **Deleting Failing Tests** | Deleting or commenting out `@test` annotations | Never modify or delete existing test assertions without explicit approval. |
| ❌ **Teaching Test the Bug** | Updating expected output to match broken output | Validate against business specifications, not buggy runtime behavior. |
| ❌ **Typecast Silencing** | Adding `as any`, `@ts-ignore`, or `// nolint` | Fix underlying interface or type definition mismatch. |

### Concrete Bad vs Good Examples

```ts
// ❌ AI ANTI-PATTERN: Dummy return value masks upstream null pointer bug
function calculateTax(user: User, cart: Cart): number {
  try {
    return cart.total * user.address.taxRate;
  } catch (err) {
    // Slop: Silently returns 0, resulting in free orders for users without addresses!
    return 0;
  }
}

// ✅ PRODUCTION INVARIANT: Explicit domain validation and deterministic root cause fix
function calculateTax(user: User, cart: Cart): number {
  if (!user.address) {
    throw new DomainValidationError(`User '${user.id}' is missing a verified billing address required for tax calculation.`);
  }
  const taxRate = user.address.taxRate ?? lookupDefaultJurisdictionTax(user.address.countryCode);
  return Math.round(cart.total * taxRate);
}
```

---

## 7. The 3-Attempt Backtracking State Machine & Workspace Restoration

Coding agents often get trapped in downward spirals: Attempt 1 fails, Attempt 2 modifies another file, Attempt 3 hacks on top of Attempt 2, creating an irreversible mess.

### The 3-Attempt Circuit Breaker
1. **Turn Budget Ceiling**: Maximum of 3 repair turns allowed per discrete bug hypothesis.
2. **Mandatory Rollback on Failure**:
   - If an edit fails the test suite or introduces new compiler/test failures after 2 consecutive turns:
     ```bash
     # Revert all dirty files back to pristine baseline
     git reset --hard HEAD
     git clean -fd
     ```
   - ❌ **TOTAL BAN on compounding speculative edits on top of failed edits.**
3. **Explicit Hypothesis Invalidation**:
   - Before attempting a new fix, the agent MUST output an explicit invalidation log:
     ```text
     [Hypothesis 1 Invalidated]
     - Rejected Hypothesis: "Assumed the checkout error was caused by a stale Stripe token."
     - Why False: "Reproduced with fresh mock token; error persists in local discount calculator."
     - New Hypothesis 2: "Discount calculator encounters division by zero when quantity is 0."
     ```

---

## 8. Concurrency, Race Condition & Flake Elimination

Flaky tests and non-deterministic concurrency bugs destroy developer velocity and cause agents to hallucinate that their changes broke unrelated code.

### 1. Zero-Tolerance for Arbitrary Sleeps
- ❌ **ABSOLUTE BAN**: `time.Sleep(100 * time.Millisecond)`, `await sleep(500)`, `time.sleep(1)`.
- ✅ **Deterministic Condition Polling**: Poll state with backoff and explicit timeout deadlines:

```go
// ✅ Deterministic condition polling in Go
func WaitForCondition(t *testing.T, timeout time.Duration, interval time.Duration, condition func() bool) {
    t.Helper()
    deadline := time.Now().Add(timeout)
    for time.Now().Before(deadline) {
        if condition() {
            return
        }
        time.Sleep(interval)
    }
    t.Fatalf("condition failed to materialize within timeout: %v", timeout)
}
```

### 2. Mandatory Data Race Detection
- When debugging Go services or tests, ALWAYS execute tests under the race detector:
  ```bash
  go test -race -v -count=1 ./...
  ```
- In Node.js / TypeScript, inspect unhandled promise rejections and event listener leaks:
  ```bash
  node --trace-warnings --unhandled-rejections=strict dist/index.js
  ```

---

## 9. The Verification Funnel & SWE-bench Quality Gates

Before declaring any bug fixed, an agent must pass through 5 deterministic quality gates:

```
┌──────────────────────────────────────────────────────────┐
│ Gate 1: Repro Test Pass                                  │
│ Assert that the minimal repro test now passes cleanly.   │
└────────────────────────────┬─────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────┐
│ Gate 2: Static Typing & AST Verification                 │
│ Execute compiler checks (`tsc --noEmit`, `go vet`, etc.) │
└────────────────────────────┬─────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────┐
│ Gate 3: Local Package Test Suite                         │
│ Execute all unit tests in the modified directory.        │
└────────────────────────────┬─────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────┐
│ Gate 4: Transitive Blast Radius Tests                    │
│ Execute tests for all downstream caller modules.         │
└────────────────────────────┬─────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────┐
│ Gate 5: Promote Repro Test to Permanent Regression Suite │
│ Commit repro test as `tests/regressions/issue_<id>_test` │
└──────────────────────────────────────────────────────────┘
```

---

## 10. Production Checklist: Agentic Root Cause Analysis

Before concluding a bug-fixing session, verify every invariant:

- [ ] **Deterministic Reproduction**: A standalone repro test was created and verified failing before any code was changed.
- [ ] **Exact Error Match**: The baseline repro failed with the exact reported error type, message, and status code.
- [ ] **Boundary Frame Isolated**: Stack traces were filtered to isolate the first application frame from framework noise.
- [ ] **Causal Hypothesis Stated**: An explicit, falsifiable root-cause hypothesis was documented before editing.
- [ ] **Zero Error Masking**: No empty catch blocks, dummy fallback returns, or silenced type annotations were introduced.
- [ ] **Assertion Purity**: No existing test assertions were weakened, commented out, or modified to match broken output.
- [ ] **Minimal Blast Radius**: The diff changes only the root cause location and contains minimal lines (<20 lines).
- [ ] **Clean Rollbacks**: All failed speculative attempts were cleanly rolled back via `git reset --hard`.
- [ ] **Race Detector Clean**: Multi-threaded or asynchronous code passes with zero race detector warnings (`-race`).
- [ ] **Permanent Regression Test**: The reproduction test is committed to the test suite to prevent future regressions.
