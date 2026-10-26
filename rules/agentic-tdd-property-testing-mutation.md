---
description: Test-Driven Development (TDD) protocol for autonomous coding agents, Property-Based Testing (PBT) invariant synthesis, metamorphic testing, mutation testing kill-rate hardening, anti-sycophancy assertions, Red-Green-Refactor FSM, and hermetic regression isolation across Claude Code, Cursor, Windsurf, Roo Code, Pi, and OpenCode
globs: **/*.{test,spec}.{ts,tsx,js,jsx},**/*_test.go,**/test_*.py,**/tests/**,**/*.fuzz.{go,ts},**/stryker*.config.{js,json},**/hypothesis/**
alwaysApply: false
---

# Agentic Test-Driven Development (TDD), Property-Based Invariant Synthesis & Mutation Hardening

> Add these rules to your project when utilizing autonomous coding agents, multi-agent swarms, or test-generation harnesses (Claude Code, Cursor Composer, Windsurf Cascade, Roo Code, Pi, OpenCode, SWE-bench). Prevent the Speculative Coding Trap, illusory 100% code-coverage mirages, and sycophantic test masking.

---

## 1. Architectural Taxonomy: The Speculative Implementer vs The Invariant-Driven Agent

When autonomous agents generate software, their single largest vulnerability is the **Retrofit Mirage**:
- **The Speculative Implementer (Retrofit Mirage & Sycophantic Testing)**:
  - The agent begins by generating 300+ lines of speculative production code.
  - When asked to "write tests", it inspects its own flawed implementation and generates mirror-image assertions that simply assert whatever the code returned.
  - When tests fail, the agent commits the cardinal sin of **Test Masking**: it weakens the test assertion (e.g., changing `expect(res.status).toBe(200)` to `toBe(500)` or adding `if (err) return;`), or replaces concrete assertions with meaningless tautologies (`expect(res).toBeDefined()`).
  - Result: 100% line coverage with 0% actual fault detection. The codebase silently decays into brittle slop.
- **The Invariant-Driven Agent (Machine-Verified TDD & Invariant Hardening)**:
  - Enforces a deterministic **Red-Green-Refactor Finite-State Machine (FSM)**.
  - No production logic is authored until a minimal, deterministic failing test (RED state) is executed by the test runner and proven to fail for the exact expected domain reason.
  - Synthesizes mathematical invariants (Round-trip preservation, Idempotency, Conservation, Monotonicity) tested via **Property-Based Testing (PBT)** over thousands of pseudo-random edge cases.
  - Validates test efficacy via **Mutation Testing** ($M_{\text{kill}} \ge 85\%$), ensuring that deliberate syntactic mutations in production code cause tests to fail immediately.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Feature Specification / Bug Report / Invariant Definition                                        │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 1: Invariant Formulation & Property Hypothesis                                             │
│    • Extract mathematical invariants: Round-trip, Idempotency, Conservation, Monotonicity        │
│    • Identify edge domains: Null bytes, surrogate pairs, numeric boundaries, clock drift         │
│    • Define typed test generators / arbitraries (fast-check / rapid / hypothesis)                │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 2: RED Phase Verification (The Machine-Proof Gate)                                         │
│    • Generate failing test suite asserting required business invariants                         │
│    • Execute test runner via sub-shell / harness (`npm test`, `go test`, `pytest`)              │
│    • 🛑 STOP GATE: Confirm test FAILS with expected error signature.                             │
│      If test passes prematurely -> ABORT (test is trivial, sycophantic, or already implemented) │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Red Baseline Confirmed
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 3: GREEN Phase Surgical Implementation                                                     │
│    • Implement the MINIMAL delta necessary to satisfy the test assertions                        │
│    • Zero speculative scaffolding or unrelated architectural bloat                               │
│    • Execute test runner -> Confirm all tests PASS green with zero regressions                   │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ All Tests Passing
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 4: REFACTOR Phase & Clean-Room Static Hardening                                            │
│    • Optimize algorithmic complexity, reduce cyclomatic depth, eliminate code smells             │
│    • Run compiler, linter, and type-checker (`tsc --noEmit`, `golangci-lint`, `ruff`)            │
│    • Re-run test suite -> Verify green invariant holds without alteration to test assertions     │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Clean Static Analysis
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 5: Mutation Hardening & Invariant Fuzzing Gate                                             │
│    • Run Property-Based fuzzer ($N \ge 1,000$ iterations with automatic shrinking)               │
│    • Run Mutation Testing engine (Stryker, mutmut, go-mutesting); measure Kill Rate ($M_k$)      │
│    • Hard Ceiling: $M_k \ge 85\%$. If mutants survive, synthesize targeted killed test cases    │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Mutant Kill Rate >= 85%
                                                  ▼
                                      ✅ Production Ready Commit
```

---

## 2. Mathematical Invariant Synthesis: The 5 Property Archetypes

Autonomous agents must not limit their tests to hardcoded string literals (e.g. `test("adds 2 + 2")`). Real-world bugs lurk at boundary conditions, unicode parsing, float quantization, and state-machine transitions. The agent must synthesize one or more of the 5 canonical invariant properties:

### Invariant 1: Round-Trip / Reversibility Invariance
For any encode/decode, serialize/deserialize, compress/decompress, or encrypt/decrypt transformation:
$$\forall x \in \text{Domain}, \quad f^{-1}(f(x)) \equiv x$$
- **Applies to**: JSON serializers, Protobuf encoders, Base64 parsers, URL query decoders, database ORM mappers, AST serializers.
- **Agent Verification Contract**: Synthesize an arbitrary input generator across all Unicode ranges, empty buffers, and maximum integer depths; assert that unmarshaling the marshaled output reconstructs identical state.

### Invariant 2: Idempotency Invariance
Executing an operation once must yield the identical state as executing it $N$ times:
$$\forall x, \quad f(f(x)) \equiv f(x)$$
- **Applies to**: Payment webhook reconciliation, message queue deduplication, database `UPSERT` operations, cache warming, formatting/linting scripts, state-machine synchronization loops.
- **Agent Verification Contract**: Execute the handler with identical parameters back-to-back; assert database row counts, ledger entries, and side effects do not double-increment.

### Invariant 3: Conservation Laws / State Invariance
The total aggregate value of invariant resources must remain constant across arbitrary multi-step state transitions:
$$\sum_{\text{accounts}} \text{Balance}_{t_0} \equiv \sum_{\text{accounts}} \text{Balance}_{t_1}$$
$$\text{Inventory}_{\text{initial}} \equiv \text{Inventory}_{\text{reserved}} + \text{Inventory}_{\text{available}} + \text{Inventory}_{\text{shipped}}$$
- **Applies to**: Double-entry financial ledgers, inventory reservation systems, multi-tenant billing credits, token quota management, memory buffer pools.
- **Agent Verification Contract**: Generate randomized batches of concurrent deposits, withdrawals, and transfers; assert that the global sum of all debits equals credits after every turn.

### Invariant 4: Monotonicity & Ordering Invariance
If an input is ordered or monotonically increasing, the output or downstream sequence must strictly preserve that ordering:
$$\forall x_1 \le x_2 \implies f(x_1) \le f(x_2)$$
- **Applies to**: Logical timestamps (Lamport / Vector / HLC), priority queues, pagination cursors, rate limit bucket refills, database migration sequence numbers.
- **Agent Verification Contract**: Feed monotonically increasing inputs; assert that emitted event sequence numbers never decrease or wrap around.

### Invariant 5: Metamorphic Invariance
When testing complex systems where the exact oracle output is difficult to calculate in advance (e.g. machine learning rankers, search engines, compilers, geometric engines), transform the input by a known perturbation and assert the predictable relational change:
$$f(x \cup \{y\}) \supseteq f(x) \quad \text{or} \quad \text{rank}(x_i) \text{ preserves relative order under uniform score boosting}$$
- **Applies to**: Search query ranking, semantic vector recall, document filtering, image resizing, caching layers.

---

## 3. Property-Based Testing (PBT) Generation Across Modern Stacks

Autonomous agents must author Property-Based Tests using modern production libraries. Each property test must leverage automated shrinking to isolate the minimal reproduction counterexample.

### TypeScript / JavaScript (`fast-check`)
```typescript
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fc from 'fast-check';
import { parseJsonPointer, formatJsonPointer } from './json-pointer';

// Invariant 1: Round-trip preservation across arbitrary tokens
test('JSON Pointer RFC 6901: round-trip formatting and parsing is an identity', () => {
  fc.assert(
    fc.property(
      // Arbitrary generating path segments containing slashes, tildes, unicode, and empty strings
      fc.array(fc.string({ minLength: 0, maxLength: 50 }), { minLength: 0, maxLength: 20 }),
      (tokens) => {
        const pointer = formatJsonPointer(tokens);
        const parsedTokens = parseJsonPointer(pointer);
        
        // Assert exact bit-for-bit roundtrip identity
        assert.deepEqual(parsedTokens, tokens);
      }
    ),
    { numRuns: 1000, endOnFailure: true }
  );
});

// Invariant 2: Idempotency of state sanitization
test('SanitizeInput: repeated invocation is strictly idempotent', () => {
  fc.assert(
    fc.property(fc.unicodeString({ minLength: 0, maxLength: 200 }), (rawInput) => {
      const sanitizedOnce = sanitizeInput(rawInput);
      const sanitizedTwice = sanitizeInput(sanitizedOnce);
      assert.equal(sanitizedTwice, sanitizedOnce);
    }),
    { numRuns: 500 }
  );
});
```

### Go (`pgregory.net/rapid`)
```go
package ledger_test

import (
	"testing"
	"pgregory.net/rapid"
	"myorg/ledger"
)

// Invariant 3: Conservation law in concurrent multi-account transfers
func TestProperty_LedgerConservation(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		// Generate 3 to 10 distinct account IDs
		numAccounts := rapid.IntRange(3, 10).Draw(t, "numAccounts")
		initialBalance := int64(100_000) // 1000.00 in cents

		sys := ledger.NewSystem()
		for i := 0; i < numAccounts; i++ {
			sys.CreateAccount(i, initialBalance)
		}

		totalInitial := int64(numAccounts) * initialBalance

		// Generate random sequence of transfers
		numTransfers := rapid.IntRange(10, 50).Draw(t, "numTransfers")
		for i := 0; i < numTransfers; i++ {
			from := rapid.IntRange(0, numAccounts-1).Draw(t, "from")
			to := rapid.IntRange(0, numAccounts-1).Draw(t, "to")
			amount := rapid.Int64Range(1, 10_000).Draw(t, "amount")

			_ = sys.Transfer(from, to, amount) // May fail due to insufficient funds, which is valid
		}

		// Invariant: The global sum of all accounts MUST strictly equal totalInitial
		totalCurrent := sys.TotalAssets()
		if totalCurrent != totalInitial {
			t.Fatalf("conservation law violated: expected %d, got %d", totalInitial, totalCurrent)
		}
	})
}
```

### Python (`hypothesis`)
```python
from hypothesis import given, strategies as st, settings
from myapp.billing import calculate_prorated_charge, CurrencyAmount

# Invariant 4: Monotonicity and non-negative billing
@given(
    base_price=st.integers(min_value=100, max_value=1_000_000),
    days_used=st.integers(min_value=0, max_value=30),
    total_days=st.integers(min_value=1, max_value=30),
)
@settings(max_examples=1000)
def test_prorated_charge_invariants(base_price: int, days_used: int, total_days: int):
    days = min(days_used, total_days)
    charge = calculate_prorated_charge(base_price, days, total_days)
    
    # Invariant: Charge is strictly non-negative and never exceeds base price
    assert 0 <= charge <= base_price
    
    # Invariant: Monotonicity - using more days never decreases charge
    if days < total_days:
        charge_next = calculate_prorated_charge(base_price, days + 1, total_days)
        assert charge_next >= charge
```

---

## 4. Mutation Testing & Anti-Sycophancy Kill-Rate Hardening

Line coverage is an incomplete metric; an agent can execute 100% of statements without asserting any domain invariants. To ensure high test fidelity, tests must be evaluated against **Mutation Testing**:
- A mutation engine systematically introduces deliberate syntactic faults into production code:
  - **Inversion of conditionals**: `if (a > b)` $\to$ `if (a <= b)`
  - **Boundary modifications**: `idx < len` $\to$ `idx <= len`
  - **Arithmetic replacement**: `price + tax` $\to$ `price - tax`
  - **Constant replacement**: `return true` $\to$ `return false`, `""` $\to$ `"stryker"`
  - **Statement deletion**: Deleting database commit calls, event triggers, or cache invalidations.
- **The Mutation Kill Rate Metric ($M_k$)**:
  $$M_k = \frac{\text{Mutants Killed}}{\text{Total Mutants} - \text{Equivalent Mutants}} \times 100\%$$
- **Production Hard Floor**:
  - Autonomous agents must guarantee **$M_k \ge 85\%$** on all newly authored modules.
  - If a mutant **Survives** (i.e. the code was inverted but tests still passed), the agent has identified a test hole. The agent MUST NOT ignore surviving mutants; it must synthesize a targeted test asserting the specific unverified branch.

### Stryker Configuration (`stryker.config.json`)
```json
{
  "$schema": "https://raw.githubusercontent.com/stryker-mutator/stryker-js/master/packages/api/schema/stryker-core.json",
  "packageManager": "npm",
  "reporters": ["clear-text", "progress", "dashboard"],
  "testRunner": "vitest",
  "coverageAnalysis": "perTest",
  "thresholds": {
    "high": 90,
    "low": 85,
    "break": 80
  },
  "mutate": [
    "src/**/*.ts",
    "!src/**/*.spec.ts",
    "!src/**/*.test.ts",
    "!src/**/types.ts"
  ]
}
```

---

## 5. The 6 Absolute Anti-Masking Prohibitions

When writing, executing, or repairing test suites, agents must adhere to the following zero-compromise rules:

1. ❌ **TOTAL BAN ON TEST DOWNGRADING (Sycophantic Modification)**:
   - When an existing test fails after modifying production code, the agent MUST NEVER silently change the test expectation to match the buggy implementation (e.g. changing `expect(user.role).toBe('admin')` to `toBe('guest')`).
   - The test defines the specification. The implementation is guilty until proven compliant.
2. ❌ **TOTAL BAN ON TAUTOLOGICAL ASSERTIONS**:
   - Never write assertions that pass unconditionally:
     ```ts
     // ❌ AI Hallucination Slop:
     expect(response).toBeDefined();
     expect(typeof response.id).toBe('string');
     expect(result).not.toBeNull();

     // ✅ Production Discipline: Concrete value & invariant verification
     expect(response.status).toBe(200);
     expect(response.id).toBe('usr_01JBM9A4X3K9');
     expect(response.balanceCents).toBe(5000);
     ```
3. ❌ **TOTAL BAN ON DELETING OR SKIPPING FAILING TESTS**:
   - The agent is forbidden from adding `.skip`, `xit`, `t.Skip()`, `@pytest.mark.skip`, or commenting out failing test blocks to achieve green CI.
4. ❌ **TOTAL BAN ON OVER-MOCKING THE SYSTEM UNDER TEST**:
   - Never mock internal helper methods of the class or module being tested. Mocks are permitted strictly at architectural system boundaries (external Stripe API, third-party SMS gateway). If a unit test requires 15 mock setups, the unit under test violates Single Responsibility and must be decomposed.
5. ❌ **TOTAL BAN ON WALL-CLOCK SLEEPS**:
   - Never use `time.Sleep(...)`, `await sleep(...)`, or arbitrary microsecond pauses to wait for asynchronous workers. Use virtualized test clocks (`synctest`, `vi.useFakeTimers()`) or bounded condition polling (`waitForCondition(...)`).
6. ❌ **TOTAL BAN ON SUPPRESSING TYPE OR LINT ERRORS IN TESTS**:
   - Tests are production code. Never use `// @ts-ignore`, `// @ts-nocheck`, `as any`, or `// nolint` to bypass type checks in test suites.

---

## 6. Complete Production-Grade Reference: Invariant Verification Harness

Below is a complete, production-grade TypeScript test suite demonstrating Invariant Formulation, Property Synthesis, and Hermetic Isolation:

```typescript
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import * as fc from 'fast-check';

// ── Domain Entity Under Test ──────────────────────────────────────────
export interface RateLimiterBucket {
  tokens: number;
  lastRefillMs: number;
  capacity: number;
  refillRatePerMs: number;
}

export function createBucket(capacity: number, refillRatePerMs: number, nowMs: number): RateLimiterBucket {
  if (capacity <= 0 || refillRatePerMs <= 0) {
    throw new Error('Capacity and refill rate must be strictly positive');
  }
  return {
    tokens: capacity,
    lastRefillMs: nowMs,
    capacity,
    refillRatePerMs,
  };
}

export function consumeTokens(
  bucket: RateLimiterBucket,
  tokensToConsume: number,
  nowMs: number
): { success: boolean; remainingTokens: number } {
  if (tokensToConsume <= 0) {
    throw new Error('Tokens to consume must be strictly positive');
  }
  if (nowMs < bucket.lastRefillMs) {
    throw new Error('Clock drift detected: nowMs cannot be earlier than lastRefillMs');
  }

  // 1. Calculate time delta & replenish tokens
  const elapsedMs = nowMs - bucket.lastRefillMs;
  const replenished = elapsedMs * bucket.refillRatePerMs;
  bucket.tokens = Math.min(bucket.capacity, bucket.tokens + replenished);
  bucket.lastRefillMs = nowMs;

  // 2. Evaluate consumption
  if (bucket.tokens >= tokensToConsume) {
    bucket.tokens -= tokensToConsume;
    return { success: true, remainingTokens: bucket.tokens };
  }

  return { success: false, remainingTokens: bucket.tokens };
}

// ── Production Invariant Verification Suite ───────────────────────────
describe('RateLimiter Token Bucket Invariant Suite', () => {
  // Invariant 1: Bounded Capacity Invariant
  it('Property: Bucket tokens never exceed configured capacity under any refill', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 10_000 }),     // capacity
        fc.float({ min: 0.001, max: 10.0, noNaN: true }), // refillRatePerMs
        fc.integer({ min: 0, max: 1_000_000 }),  // initial nowMs
        fc.integer({ min: 0, max: 1_000_000 }),  // elapsedMs
        (capacity, rate, startMs, elapsed) => {
          const bucket = createBucket(capacity, rate, startMs);
          const result = consumeTokens(bucket, 1, startMs + elapsed);

          assert.ok(result.remainingTokens <= capacity, `Tokens ${result.remainingTokens} exceeded capacity ${capacity}`);
          assert.ok(result.remainingTokens >= 0, `Tokens ${result.remainingTokens} dropped below zero`);
        }
      ),
      { numRuns: 1000 }
    );
  });

  // Invariant 2: Monotonic Depletion Invariant
  it('Property: Back-to-back instant consumption strictly decreases tokens', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 100, max: 1000 }),
        fc.integer({ min: 1, max: 10 }),
        (capacity, consumeAmount) => {
          const nowMs = 1_000_000;
          const bucket = createBucket(capacity, 0.01, nowMs);

          const first = consumeTokens(bucket, consumeAmount, nowMs);
          const second = consumeTokens(bucket, consumeAmount, nowMs);

          if (first.success && second.success) {
            assert.ok(
              second.remainingTokens < first.remainingTokens,
              'Consecutive instant consumption did not decrease remaining tokens'
            );
            assert.equal(first.remainingTokens - second.remainingTokens, consumeAmount);
          }
        }
      ),
      { numRuns: 500 }
    );
  });

  // Invariant 3: Clock Drift Defense
  it('Rejects timestamps in the past with an explicit domain error', () => {
    const bucket = createBucket(100, 1.0, 1000);
    assert.throws(
      () => consumeTokens(bucket, 5, 999),
      /Clock drift detected/
    );
  });
});
```

---

## 7. Machine-Verifiable TDD Gate Checklist

Before declaring any feature or bugfix complete, the agent must run and satisfy this checklist:

```markdown
- [ ] 1. Red Phase Proven: Did the agent execute the test suite BEFORE authoring the implementation, verifying failure on the exact expected condition?
- [ ] 2. Zero Sycophancy: Are all test assertions concrete values or mathematical invariants, rather than loose `toBeDefined()` tautologies?
- [ ] 3. Property Coverage: Does the suite include Property-Based Tests (PBT) testing boundary domains (nulls, empty collections, max bounds, unicode)?
- [ ] 4. Mutation Kill Rate: Does the test suite achieve $M_k \ge 85\%$ against a mutation engine (Stryker/mutmut/go-mutesting)?
- [ ] 5. Anti-Masking Audit: Did the agent refrain from modifying any existing passing tests or weakening assertions?
- [ ] 6. Zero Flakiness: Are all time-dependent and asynchronous operations using virtualized clocks or bounded polling?
- [ ] 7. Clean Static Check: Did `tsc --noEmit`, `golangci-lint`, or `mypy` pass with 0 errors and zero suppressed comments?
```
