---
description: Agentic brownfield refactoring, characterization testing, AST-aware codemods (ts-morph, LibCST, go/ast), Strangler Fig migration, Tarjan cyclic dependency detection, and semantic invariant preservation across Claude Code, Cursor, Windsurf, Devin, and Pi
globs: **/*{refactor,migration,legacy,codemod,ast,strangler,characterization,seam,transform}*.*,**/rules/**,**/.cursorrules,**/CLAUDE.md,**/AGENTS.md,**/.agents/**
alwaysApply: false
---

# Agentic Brownfield Refactoring, Structural AST Codemods & Legacy Architecture Migration

> Add these rules to your project when architecting, executing, or auditing autonomous coding agents, multi-agent refactoring swarms, or SWE-bench agent harnesses (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode). Eliminate the "Speculative Rewrite Trap" and "Fragile Regex Destruction Catastrophe" by enforcing a 4-Tier Refactoring Safety Ladder: pinning legacy behavior via Golden Master Characterization Tests, executing lossless AST codemods instead of naive text substitution, detecting circular dependency cycles via Tarjan's Strongly Connected Components (SCC) algorithm, and safely migrating legacy modules via Branch by Abstraction and Strangler Fig dual-execution verification.

---

## 1. Architectural Taxonomy: The Brownfield Dilemma vs The Invariant-Preserving Refactoring Ladder

Over 95% of real-world enterprise engineering takes place in established "brownfield" codebases—repositories with years of accumulated business logic, undocumented corner cases, implicit temporal dependencies, and subtle backward-compatibility shims. When autonomous coding agents are assigned to refactor legacy code, decompose monoliths, or upgrade framework versions, naive agentic execution leads to catastrophic regressions:

- **The Speculative Rewrite Trap ($O(N^2)$ Blast Radius)**:
  - An agent inspects a 600-line legacy function, perceives it as "unidiomatic" or "messy," and replaces it with a concise 40-line greenfield rewrite.
  - In doing so, the agent silently deletes 15 critical edge-case fixes, timezone compensations, and database lock retry mechanisms that were never documented in comments. Production experiences silent data corruption.
- **The Fragile Regex Destruction Catastrophe**:
  - The agent uses string search-and-replace (`sed`, regex, or naive string replacement tools) to rename APIs or change parameter orders.
  - Regex cannot parse language grammar: it inadvertently modifies string literals, corrupts nested TypeScript generics, strips trailing commas, breaks multiline function signatures, and rewires variable names across shadowed scopes.
- **The Cyclic Dependency Deadlock ($O(V+E)$ Structural Corruption)**:
  - The agent extracts helper utilities into a newly created module (`utils/shared.ts` or `service/helper.go`) without auditing transitive import graphs.
  - The extraction creates a circular dependency (`A -> B -> C -> A`), causing ECMAScript/Node.js module loaders to emit `undefined` runtime imports, Go builds to fail with `import cycle not allowed`, or bundlers (Vite, Webpack) to freeze in deadlock during Hot Module Replacement (HMR).
- **The Untested Refactor Delusion**:
  - The agent alters code paths without first pinning existing system behavior using **Characterization Tests (Golden Master / Approval Tests)**. The agent evaluates success solely by running unit tests that it wrote itself (which suffer from sycophantic confirmation bias) rather than verifying parity against legacy behavior.
- **The Invariant-Preserving Refactoring Ladder**:
  - Production agentic refactoring follows a strict 4-tier safety progression:
    - **Tier 0: Characterization / Golden Master Invariant Pinning**: Before altering a single byte of application code, wrap the target module in black-box characterization tests that freeze input/output permutations, database mutations, and external calls.
    - **Tier 1: Lossless AST-Aware Codemod Transformation**: Perform structural transformations using Abstract Syntax Tree (AST) manipulators (`ts-morph`, `LibCST`, Go `go/ast`) that preserve trivia, comments, and formatting while enforcing grammatical soundness.
    - **Tier 2: Dependency Graph & Tarjan SCC Verification**: Construct the module import graph and compute Strongly Connected Components to mathematically guarantee that the refactoring introduces zero circular dependencies ($|\text{SCC}| \equiv 1$).
    - **Tier 3: Strangler Fig & Dual-Execution Shadow Verification**: Deploy Branch by Abstraction; run legacy and modern paths in parallel shadow mode, verifying exact semantic equivalence before decommissioning the legacy implementation.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ User Refactoring Ticket ("Migrate legacy callback-based PaymentGateway to async/await & Stripe v10")│
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: Speculative Naive Rewrite]                                      ▼ [PRODUCTION: 4-Tier Refactoring Ladder]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ Agent reads legacy file, declares it "ugly".     │               │ Tier 0: Characterization / Golden Master Pinning │
│ Performs full file rewrite via string replace.  │               │ • Capture inputs/outputs across 200+ edge cases.│
├─────────────────────────────────────────────────┤               │ • Freeze snapshot fixtures into test suite.     │
│ - Undocumented edge cases silently erased.      │               ├─────────────────────────────────────────────────┤
│ - Regex corrupts nested generics & comments.    │               │ Tier 1: Lossless AST Codemod Transformation     │
│ - Circular imports crash module loader.         │               │ • Transform syntax via ts-morph / LibCST.       │
│ - Unit tests pass because agent wrote them      │               │ • Zero regex string slicing. Comments preserved.│
│   to match its own broken implementation.       │               ├─────────────────────────────────────────────────┤
│ - Production outage upon deployment.            │               │ Tier 2: Tarjan SCC Dependency Graph Audit       │
└─────────────────────────────────────────────────┘               │ • Build module DAG; enforce zero import cycles. │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 3: Strangler Fig & Shadow Dual-Execution   │
                                                                  │ • Run Legacy & New concurrently in shadow mode. │
                                                                  │ • Validate return parity: ε(Legacy, New) === 0. │
                                                                  │ • Decommission legacy branch safely.            │
                                                                  └─────────────────────────────────────────────────┘
```

---

## 2. Characterization Testing: The Golden Master Invariant Pinning Protocol

Before modifying legacy code whose full operational specifications are unknown or poorly documented, the agent must treat the existing implementation as an immutable black box and construct **Characterization Tests** (also known as Golden Master or Approval Tests).

### 2.1 The Golden Master Pinning Algorithm
1. **Identify the Execution Seam**: Locate the module boundary where inputs enter and outputs/side-effects exit (e.g., public function arguments, HTTP request payloads, database writes).
2. **Generate Boundary Input Permutations**:
   - Synthesize a comprehensive set of input fixtures covering:
     - Normal operational parameters.
     - Boundary values (empty strings, zero, negative integers, `MAX_SAFE_INTEGER`, empty arrays, null/undefined).
     - Malformed or adversarial inputs (SQL characters, Unicode surrogate pairs, unexpected object schemas).
3. **Capture Execution Snapshots**: Run the legacy code against all synthesized inputs and record:
   - Synchronous and asynchronous return values.
   - Thrown exceptions (message, error code, stack signature).
   - Side effects (spied database calls, emitted events, dispatched HTTP requests).
4. **Freeze Snapshot Signatures**: Store serialized JSON snapshots in a committed test directory (`__snapshots__/legacy_golden_master.json`).
5. **Enforce Zero-Tolerance Diff Invariant**:
   $$\Delta(\text{Output}_{\text{refactored}}, \text{Output}_{\text{golden}}) \equiv 0$$
   Any deviation from the Golden Master snapshot is classified as a breaking regression unless explicitly authorized by the user prompt.

```typescript
// tests/characterization/payment-gateway.golden.test.ts
import { describe, it, expect } from 'vitest';
import { legacyProcessPayment } from '../../src/legacy/paymentGateway';
import goldenSnapshots from './fixtures/payment_gateway_snapshots.json';

describe('PaymentGateway Characterization Harness (Golden Master)', () => {
  for (const fixture of goldenSnapshots) {
    it(`preserves legacy behavior for input vector [${fixture.id}]: ${fixture.description}`, async () => {
      let actualOutput: any;
      let actualError: any = null;

      try {
        actualOutput = await legacyProcessPayment(fixture.input);
      } catch (err: any) {
        actualError = {
          name: err.name,
          message: err.message,
          code: err.code ?? null,
        };
      }

      if (fixture.expectedError) {
        expect(actualError).not.toBeNull();
        expect(actualError.message).toBe(fixture.expectedError.message);
        expect(actualError.code).toBe(fixture.expectedError.code);
      } else {
        expect(actualError).toBeNull();
        expect(actualOutput).toEqual(fixture.expectedOutput);
      }
    });
  }
});
```

---

## 3. Lossless AST Codemods vs Fragile Regex String Surgery

Autonomous agents must strictly prohibit using regular expressions or naive string replacement (`str.replace()`, `sed`, `awk`) for modifying code syntax. Agents must utilize **Lossless Abstract Syntax Tree (AST)** transformations.

### 3.1 Failure Modes of Regex Surgery
- **False-Positive String Collisions**: Replacing `id` with `userId` accidentally mutates string literals like `"valid_identity"` or HTML attributes like `id="container"`.
- **Scope Blindness**: Regex cannot distinguish between a package-level variable, a local function parameter, a destructured property, or a type declaration of the same name.
- **Syntax Corruption**: Multiline arguments, generic parameters (`<T, R>`), trailing commas, and inline comments break regex patterns, producing unparsable code that fails compilation.

### 3.2 AST-Driven Transformation Standards
- **TypeScript / JavaScript**: Use `ts-morph` or the native TypeScript Compiler API. AST transforms preserve comments, formatting, and type relations.
- **Python**: Use `LibCST` (Lossless Concrete Syntax Tree) rather than the standard `ast` module. `LibCST` preserves indentation, comments, and parentheses.
- **Go**: Use `go/parser`, `go/ast`, or `github.com/dave/dst` (Decorated Syntax Tree) to preserve comments and format with `gofmt` invariants.

```typescript
// scripts/codemods/migrate-callbacks-to-async.ts
import { Project, SyntaxKind, FunctionDeclaration } from 'ts-morph';

export function migrateCallbackToAsync(filePath: string): void {
  const project = new Project();
  project.addSourceFileAtPath(filePath);
  const sourceFile = project.getSourceFileOrThrow(filePath);

  const functions = sourceFile.getDescendantsOfKind(SyntaxKind.FunctionDeclaration);

  for (const fn of functions) {
    const params = fn.getParameters();
    if (params.length === 0) continue;

    const lastParam = params[params.length - 1];
    const paramName = lastParam.getName();

    // Check if the final parameter is a callback function
    if (paramName === 'callback' || paramName === 'cb' || paramName === 'done') {
      // 1. Mark function as async
      fn.setIsAsync(true);

      // 2. Remove the callback parameter
      lastParam.remove();

      // 3. Update return type to Promise<T>
      const returnType = fn.getReturnTypeNode();
      if (returnType && !returnType.getText().startsWith('Promise<')) {
        fn.setReturnType(`Promise<${returnType.getText()}>`);
      }

      // 4. Transform inner callback invocations into returns / throws
      fn.forEachDescendant((node) => {
        if (node.getKind() === SyntaxKind.CallExpression) {
          const call = node.asKindOrThrow(SyntaxKind.CallExpression);
          if (call.getExpression().getText() === paramName) {
            const args = call.getArguments();
            const parentStatement = call.getParent();

            if (args.length >= 2 && args[0].getText() === 'null') {
              // callback(null, result) -> return result;
              parentStatement?.replaceWithText(`return ${args[1].getText()};`);
            } else if (args.length >= 1 && args[0].getText() !== 'null') {
              // callback(err) -> throw err;
              parentStatement?.replaceWithText(`throw ${args[0].getText()};`);
            }
          }
        }
      });
    }
  }

  sourceFile.saveSync();
}
```

---

## 4. Architectural Decoupling, Seam Discovery & Tarjan SCC Cycle Prevention

When refactoring brownfield code, agents frequently decompose monolithic classes or god-files into separate modules. Without strict topological verification, this decomposition introduces cyclic dependencies.

### 4.1 Seam Discovery (Feathers' Model)
A **seam** is a place where you can alter behavior in a program without editing in that place directly:
1. **Object Seam**: Introduce polymorphism via interfaces; inject dependencies rather than calling concrete constructors (`new Gateway()`).
2. **Link Seam**: Intercept calls at the linking / module resolution level (e.g., dependency injection containers, module path aliases).
3. **Pre-Processing Seam**: Use build-time compilation flags or environment variables to conditionally route execution.

### 4.2 Tarjan's Strongly Connected Components (SCC) Cycle Sentinel
A set of modules forms a **Strongly Connected Component** if every module in the set is reachable from every other module in the set.
- **The Cycle-Free Invariant**: In a healthy modular architecture, every module must belong to an SCC of size 1 ($|\text{SCC}_i| \equiv 1$).
- **The Cycle Alarm**: If $|\text{SCC}_k| > 1$, a cyclic dependency exists containing the members of $\text{SCC}_k$. The agent must abort the refactoring step immediately.

$$\text{Cyclic Dependency Exists} \iff \exists \text{SCC}_i \text{ s.t. } |\text{SCC}_i| > 1$$

```typescript
// src/orchestrator/tarjan-cycle-detector.ts
export interface DependencyGraph {
  [module: string]: string[];
}

export class TarjanCycleDetector {
  private index = 0;
  private indices = new Map<string, number>();
  private lowlink = new Map<string, number>();
  private onStack = new Map<string, boolean>();
  private stack: string[] = [];
  private sccs: string[][] = [];

  public detectCycles(graph: DependencyGraph): string[][] {
    this.index = 0;
    this.indices.clear();
    this.lowlink.clear();
    this.onStack.clear();
    this.stack = [];
    this.sccs = [];

    const nodes = Object.keys(graph);
    for (const node of nodes) {
      if (!this.indices.has(node)) {
        this.strongConnect(node, graph);
      }
    }

    // Filter to only components that contain cycles (size > 1 or self-loop)
    return this.sccs.filter((scc) => {
      if (scc.length > 1) return true;
      const singleNode = scc[0];
      return (graph[singleNode] || []).includes(singleNode);
    });
  }

  private strongConnect(u: string, graph: DependencyGraph): void {
    this.indices.set(u, this.index);
    this.lowlink.set(u, this.index);
    this.index++;
    this.stack.push(u);
    this.onStack.set(u, true);

    const neighbors = graph[u] || [];
    for (const v of neighbors) {
      if (!this.indices.has(v)) {
        this.strongConnect(v, graph);
        this.lowlink.set(u, Math.min(this.lowlink.get(u)!, this.lowlink.get(v)!));
      } else if (this.onStack.get(v)) {
        this.lowlink.set(u, Math.min(this.lowlink.get(u)!, this.indices.get(v)!));
      }
    }

    if (this.lowlink.get(u) === this.indices.get(u)) {
      const scc: string[] = [];
      let w: string;
      do {
        w = this.stack.pop()!;
        this.onStack.set(w, false);
        scc.push(w);
      } while (w !== u);
      this.sccs.push(scc);
    }
  }
}
```

---

## 5. The Strangler Fig Pattern & Dual-Execution Shadow Verification

For critical production services, refactoring must never be performed via a "Big Bang" cutover. Agents must implement the **Strangler Fig Pattern** combined with **Dual-Execution Shadow Routing**.

### 5.1 Branch by Abstraction
1. **Define the Common Abstraction**: Extract an interface matching the capability being refactored.
2. **Implement Legacy Adapter**: Wrap the existing legacy implementation behind the interface.
3. **Implement Modern Component**: Write the clean, modern implementation conforming to the identical interface.
4. **Deploy Dual-Execution Proxy**: Intercept incoming calls, dispatch to both legacy and modern paths, compare outcomes, and return the legacy result to callers.
5. **Monitor Parity**: When telemetry records zero divergence ($\epsilon = 0$) across $100,000$ calls, toggle the primary caller to the modern path.
6. **Decommission Legacy Adapter**: Prune dead legacy code safely.

```typescript
// src/services/payment-strangler-proxy.ts
import { PaymentGateway, PaymentRequest, PaymentResult } from '../domain/payment';
import { LegacyPaymentGateway } from './legacyPaymentGateway';
import { ModernStripePaymentGateway } from './modernStripePaymentGateway';

export interface ShadowExecutionMetrics {
  totalCalls: number;
  parityMatches: number;
  divergences: number;
  modernFailures: number;
}

export class StranglerDualExecutionProxy implements PaymentGateway {
  private metrics: ShadowExecutionMetrics = {
    totalCalls: 0,
    parityMatches: 0,
    divergences: 0,
    modernFailures: 0,
  };

  constructor(
    private readonly legacy: LegacyPaymentGateway,
    private readonly modern: ModernStripePaymentGateway,
    private readonly isModernPrimary: boolean = false,
  ) {}

  public async charge(request: PaymentRequest): Promise<PaymentResult> {
    this.metrics.totalCalls++;

    if (this.isModernPrimary) {
      // Modern path is active primary
      return await this.modern.charge(request);
    }

    // Legacy path is primary; Modern path runs in shadow mode
    const legacyPromise = this.legacy.charge(request);

    // Execute modern path asynchronously in shadow mode without blocking primary response
    const modernPromise = this.modern.charge(request).catch((err) => {
      this.metrics.modernFailures++;
      console.error('[Shadow Execution] Modern path exception:', err);
      return null;
    });

    const legacyResult = await legacyPromise;
    const modernResult = await modernPromise;

    if (modernResult !== null) {
      this.auditParity(request, legacyResult, modernResult);
    }

    return legacyResult;
  }

  private auditParity(request: PaymentRequest, legacy: PaymentResult, modern: PaymentResult): void {
    const isEquivalent =
      legacy.status === modern.status &&
      legacy.amount === modern.amount &&
      legacy.currency === modern.currency;

    if (isEquivalent) {
      this.metrics.parityMatches++;
    } else {
      this.metrics.divergences++;
      console.warn('[Strangler Parity Divergence Detected]', {
        requestId: request.id,
        legacyResult: legacy,
        modernResult: modern,
      });
    }
  }

  public getMetrics(): Readonly<ShadowExecutionMetrics> {
    return { ...this.metrics };
  }
}
```

---

## 6. Complete Executable Engine: TypeScript `BrownfieldRefactoringOrchestrator`

Below is an enterprise-grade, self-contained TypeScript orchestrator implementing the complete 4-tier refactoring safety pipeline. It captures golden master fixtures, enforces AST transformations, validates import graphs for cyclic dependencies using Tarjan's algorithm, and rolls back atomically if regressions occur.

```typescript
// src/orchestrator/brownfield-refactoring-orchestrator.ts
import * as fs from 'node:fs';
import * as path from 'node:path';
import { TarjanCycleDetector, DependencyGraph } from './tarjan-cycle-detector';

export interface CharacterizationFixture<TInput, TOutput> {
  id: string;
  description: string;
  input: TInput;
  expectedOutput?: TOutput;
  expectedError?: { name: string; message: string };
}

export interface RefactoringStepConfig<TInput, TOutput> {
  targetFilePath: string;
  fixtures: CharacterizationFixture<TInput, TOutput>[];
  executeSubject: (input: TInput) => Promise<TOutput>;
  applyCodemod: (sourceCode: string) => string;
  dependencyGraph: DependencyGraph;
}

export interface RefactoringStepResult {
  success: boolean;
  phase: 'CHARACTERIZATION' | 'AST_TRANSFORM' | 'CYCLE_AUDIT' | 'PARITY_VERIFICATION' | 'COMPLETE';
  error?: string;
  divergences?: Array<{ fixtureId: string; expected: any; actual: any }>;
  circularComponents?: string[][];
}

export class BrownfieldRefactoringOrchestrator {
  private cycleDetector = new TarjanCycleDetector();

  public async orchestrateRefactoring<TInput, TOutput>(
    config: RefactoringStepConfig<TInput, TOutput>,
  ): Promise<RefactoringStepResult> {
    const backupPath = `${config.targetFilePath}.bak_${Date.now()}`;
    const originalContent = fs.readFileSync(config.targetFilePath, 'utf-8');

    // Step 1: Create atomic backup
    fs.writeFileSync(backupPath, originalContent, 'utf-8');

    try {
      // Phase 1: Baseline Characterization Pinning
      console.log('🔒 Phase 1: Verifying baseline against characterization fixtures...');
      for (const fixture of config.fixtures) {
        try {
          const res = await config.executeSubject(fixture.input);
          if (fixture.expectedOutput !== undefined) {
            const matches = JSON.stringify(res) === JSON.stringify(fixture.expectedOutput);
            if (!matches) {
              return {
                success: false,
                phase: 'CHARACTERIZATION',
                error: `Baseline failure on fixture ${fixture.id}: baseline output does not match expected snapshot.`,
              };
            }
          }
        } catch (err: any) {
          if (!fixture.expectedError || fixture.expectedError.message !== err.message) {
            return {
              success: false,
              phase: 'CHARACTERIZATION',
              error: `Baseline exception on fixture ${fixture.id}: ${err.message}`,
            };
          }
        }
      }

      // Phase 2: Apply AST Codemod Transformation
      console.log('⚡ Phase 2: Applying AST codemod transformation...');
      const transformedContent = config.applyCodemod(originalContent);
      if (transformedContent === originalContent) {
        return {
          success: false,
          phase: 'AST_TRANSFORM',
          error: 'Codemod resulted in no changes to target file.',
        };
      }
      fs.writeFileSync(config.targetFilePath, transformedContent, 'utf-8');

      // Phase 3: Tarjan Dependency Graph Cycle Audit
      console.log('🕸️ Phase 3: Auditing dependency graph for cyclic imports...');
      const cycles = this.cycleDetector.detectCycles(config.dependencyGraph);
      if (cycles.length > 0) {
        // Rollback immediately
        fs.writeFileSync(config.targetFilePath, originalContent, 'utf-8');
        return {
          success: false,
          phase: 'CYCLE_AUDIT',
          error: `Refactoring introduced ${cycles.length} circular dependency cycle(s).`,
          circularComponents: cycles,
        };
      }

      // Phase 4: Post-Transformation Parity Verification
      console.log('🧪 Phase 4: Executing post-transformation parity verification...');
      const divergences: Array<{ fixtureId: string; expected: any; actual: any }> = [];

      for (const fixture of config.fixtures) {
        try {
          const actualOutput = await config.executeSubject(fixture.input);
          if (fixture.expectedOutput !== undefined) {
            const match = JSON.stringify(actualOutput) === JSON.stringify(fixture.expectedOutput);
            if (!match) {
              divergences.push({
                fixtureId: fixture.id,
                expected: fixture.expectedOutput,
                actual: actualOutput,
              });
            }
          }
        } catch (err: any) {
          if (!fixture.expectedError || fixture.expectedError.message !== err.message) {
            divergences.push({
              fixtureId: fixture.id,
              expected: fixture.expectedError,
              actual: { name: err.name, message: err.message },
            });
          }
        }
      }

      if (divergences.length > 0) {
        // Regressions detected! Rollback atomically
        fs.writeFileSync(config.targetFilePath, originalContent, 'utf-8');
        return {
          success: false,
          phase: 'PARITY_VERIFICATION',
          error: `Post-transformation verification failed with ${divergences.length} divergence(s). Rollback executed.`,
          divergences,
        };
      }

      // Cleanup backup on unequivocal success
      fs.unlinkSync(backupPath);
      return {
        success: true,
        phase: 'COMPLETE',
      };
    } catch (unexpectedErr: any) {
      // Ensure rollback on any unhandled crash
      if (fs.existsSync(backupPath)) {
        fs.writeFileSync(config.targetFilePath, originalContent, 'utf-8');
        fs.unlinkSync(backupPath);
      }
      return {
        success: false,
        phase: 'AST_TRANSFORM',
        error: `Unexpected refactoring error: ${unexpectedErr.message}`,
      };
    }
  }
}
```

---

## 7. The 6-State Brownfield Refactoring Lifecycle Finite-State Machine (FSM)

Autonomous refactoring agents must advance sequentially through the following deterministic lifecycle states. Jumping states or retrofitting tests after code modification is strictly prohibited.

```
   ┌──────────────────────────────────────────────────────────┐
   │                  1. SEAM_DISCOVERY                       │
   │  Identify boundary interfaces, input types, and seams.   │
   └─────────────────────────────┬────────────────────────────┘
                                 │
                                 ▼
   ┌──────────────────────────────────────────────────────────┐
   │               2. CHARACTERIZATION_PIN                    │
   │  Generate 50–200 boundary fixtures; freeze Golden Master.│
   └─────────────────────────────┬────────────────────────────┘
                                 │
                                 ▼
   ┌──────────────────────────────────────────────────────────┐
   │              3. AST_CODEMOD_TRANSFORM                    │
   │  Execute AST transforms (ts-morph / LibCST / go/ast).    │
   └─────────────────────────────┬────────────────────────────┘
                                 │
                                 ▼
   ┌──────────────────────────────────────────────────────────┐
   │                  4. CYCLE_AUDIT                          │
   │  Run Tarjan SCC on import graph; enforce |SCC| === 1.    │
   └─────────────────────────────┬────────────────────────────┘
                                 │
                                 ▼
   ┌──────────────────────────────────────────────────────────┐
   │             5. DUAL_EXECUTION_VERIFY                     │
   │  Shadow-run legacy & refactored paths; assert ε === 0.   │
   └─────────────────────────────┬────────────────────────────┘
                                 │
                                 ▼
   ┌──────────────────────────────────────────────────────────┐
   │               6. STRANGLE_AND_CLEANUP                    │
   │  Safely prune legacy adapter; clean backups & commit.    │
   └──────────────────────────────────────────────────────────┘
```

1. **State 1: `SEAM_DISCOVERY`**: Locate the seams of the legacy component (argument signatures, imported modules, database dependencies). Document public contracts.
2. **State 2: `CHARACTERIZATION_PIN`**: Generate boundary input fixtures, run the legacy code, and commit serialized golden master snapshot files. Verify 100% baseline pass rate.
3. **State 3: `AST_CODEMOD_TRANSFORM`**: Apply AST-based structural changes. Never use string regex replacements. Verify zero compiler diagnostic errors.
4. **State 4: `CYCLE_AUDIT`**: Construct the project import graph and evaluate Strongly Connected Components via Tarjan's algorithm. If any component has size $> 1$, rollback immediately.
5. **State 5: `DUAL_EXECUTION_VERIFY`**: Run the refactored code against the golden master test suite. Assert zero semantic divergence ($\Delta \equiv 0$). If differences appear, roll back to backup.
6. **State 6: `STRANGLE_AND_CLEANUP`**: Remove transitional adapters, delete backups, format with repository linter, and generate a surgical, verified Git commit.

---

## 8. The 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

An autonomous agent must fulfill all six machine-verifiable verification gates before submitting a refactoring Pull Request or completing a task:

| Gate | Verification Target | Machine-Proof Command / Invariant | Threshold / Enforcement |
| :--- | :--- | :--- | :--- |
| **Gate 1: Golden Master Parity** | Semantic Invariance | `npm run test:characterization` / `pytest tests/golden/` | $\Delta(\text{Legacy}, \text{Refactored}) \equiv 0$; 100% fixture pass rate |
| **Gate 2: AST & Type Soundness** | Type Safety & Diagnostics | `tsc --noEmit` / `mypy --strict` / `go vet ./...` | **0 errors, 0 warnings**; strict ban on `@ts-ignore` / `any` |
| **Gate 3: Circular Dependency Free**| Module DAG Topology | Tarjan SCC Analyzer (`madge --circular src/` or custom engine) | $|\text{SCC}_i| \equiv 1$ for all components; 0 cyclic import chains |
| **Gate 4: Mutation Hardening** | Test Suite Acuity | `npx stryker run` / `mutmut run` / `go-mutesting` | Mutation score $M_k \ge 85\%$ on refactored modules |
| **Gate 5: Clean Patch Verification**| Git Working Tree Soundness | `git diff --check && git apply --check <patch>` | Zero whitespace errors, zero binary conflicts, clean tree |
| **Gate 6: Zero-Downtime Rollout** | Strangler Migration Safety | Shadow execution metrics audit | Zero uncaught exceptions; error rate divergence $\le 0.0001$ |

---

## 9. Zero-Compromise Refactoring Anti-Patterns

- ❌ **The "Clean Slate" Greenfield Rewrite Delusion**: Never delete an existing multi-hundred-line legacy file to write a "cleaner" version from scratch without user authorization. Legacy code contains years of hard-won bugfixes.
- ❌ **Regex-Based AST Modification**: Never use `replace()`, `sed`, or regex patterns to modify code declarations, rename symbols, or reorder parameters. Always use an AST manipulator (`ts-morph`, `LibCST`, Go AST).
- ❌ **Retrofitting Characterization Tests After the Edit**: Never write tests *after* modifying the code to prove the modification works. Tests written post-hoc suffer from developer confirmation bias and will test the newly broken behavior.
- ❌ **Ignoring Import Cycles**: Never introduce mutual imports between modules. Always extract shared types or interfaces to a decoupled lower-level module.
- ❌ **Masking Legacy Errors as "Fixes"**: If the legacy code returned `{ code: 404 }` on empty input, the refactored code must return `{ code: 404 }`. Do not change the contract to `{ code: 200, data: [] }` unless explicitly specified in the user prompt.
