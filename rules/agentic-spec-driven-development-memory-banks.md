---
description: Spec-Driven Development (SDD) protocol, Dynamic Living Memory Banks (projectBrief, productContext, systemPatterns, techContext, activeContext, progress, decisionLog), Architecture Decision Records (ADR), spec invariance anti-drift sentinels, contract-first design, Definition of Done (DoD) verification, and multi-turn context persistence across Cursor, Claude Code, Windsurf, Roo Code, Pi, and OpenCode
globs: **/{memory,docs,specs,adr,rfc,architecture}/**/*.{md,json,yaml},**/{CLAUDE,AGENTS,ACTIVE_CONTEXT,SYSTEM_PATTERNS}.md,**/.cursor/rules/**,**/.agents/**,**/.claude/**,**/.clinerules/**
alwaysApply: false
---

# Agentic Spec-Driven Development (SDD), Dynamic Living Memory Banks & Architecture Decision Records (ADR)

> Add these rules to your project when building or operating autonomous coding agents, multi-agent orchestrators, CLI harnesses, or tool-calling systems (Claude Code, Cursor Composer, Windsurf Cascade, Pi, OpenCode, Roo Code, Anthropic Agentic Workflows).

---

## 1. Architectural Taxonomy: The Specification-Driven Agent vs The Wandering Improviser

As autonomous AI coding agents tackle enterprise-scale features across multi-turn sessions (50+ turns), they face a fundamental failure mode:
- **The Wandering Improviser (Objective Amnesia & Context Drift)**: Left without strict architectural specifications, the agent acts on speculative assumptions. It writes ad-hoc code, invents non-standard API response envelopes, quietly drops edge-case acceptance criteria, silently rewrites unit test assertions to match buggy implementations, or pivots technologies midway through a feature, leaving fragmented half-built abstractions.
- **The Specification-Driven Agent (Hermetic Spec-Driven Development)**: Decouples **Intent & Architecture** from **Code Generation**. No application code is touched until formal specifications (RFC/PRD, interface contracts, and Architecture Decision Records) are pinned to disk. The agent operates within a living memory bank that survives context compaction, session resets, and multi-agent delegation.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Inbound Feature Request / Engineering Epic                                                       │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 1: Clarification & Specification (PRD / RFC)                                               │
│    • Ingest `projectBrief.md` & `productContext.md`                                              │
│    • Map user story into deterministic acceptance criteria & functional boundaries               │
│    • Emit Specification Draft: Invariants, Scope Locks, Non-Functional Requirements (NFRs)       │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Validated Spec
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 2: Architecture Decision Record (ADR) & Blast Radius                                       │
│    • Evaluate architectural trade-offs against `systemPatterns.md` & `techContext.md`            │
│    • Emit immutable ADR (`docs/adr/YYYY-MM-DD-*.md`): Context, Drivers, Options, Decision, DoD   │
│    • Compute Blast Radius ($B$) across existing packages, DB schemas, and API clients            │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Approved Architecture
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 3: Contract-First Design & Red Failing Acceptance Suite                                    │
│    • Generate typed interface schemas (TypeScript / Zod / Protobuf / OpenAPI / SQL DDL)          │
│    • Author deterministic acceptance test suite asserting exact failure (RED state verified)    │
│    • Pin ground-truth targets into `activeContext.md` and `progress.md`                          │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ Red Baseline Confirmed
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 4: Surgical Implementation & Green Verification                                            │
│    • Implement minimal delta to turn tests GREEN                                                 │
│    • Run compiler, linter, type-checker, and mutation/property checks                            │
│    • Total ban on weakening test assertions or altering interface contracts                      │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │ 100% Machine Proof
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 5: Living Memory Bank Reconciliation & Checkpoint Persistence                              │
│    • Evict ephemeral scratchpads; append completed milestones to `progress.md`                   │
│    • Update `systemPatterns.md` if new primitives or domain rules emerged                        │
│    • Reset `activeContext.md` to indicate verified ready state for subsequent turns              │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. The 7-File Dynamic Living Memory Bank Standard

To ensure seamless cognitive continuity across session restarts, harness tool restarts, and context compactions, the agent must maintain a structured **Living Memory Bank** located in `.agents/memory/` (or repository root):

```text
.agents/memory/
├── projectBrief.md      # Immutable Mission, North Star, Core Value Proposition & Scope Ceilings
├── productContext.md    # User Personas, Domain Glossary, Critical User Journeys (CUJs)
├── systemPatterns.md    # Topology, Module Boundaries, Data Ownership & Prohibited Antipatterns
├── techContext.md       # Runtimes, Toolchains, Compilers, Package Managers, CI/CD Standards
├── activeContext.md     # Ephemeral Working State: Active Hypothesis, Touched Files, Next Action
├── progress.md          # Epic/Task Roadmap with Machine-Verifiable Definition of Done (DoD)
└── decisionLog.md       # Chronological Index of Architecture Decision Records (ADRs)
```

### 1. `projectBrief.md` (The Project North Star)
- **Role**: Foundational immutable contract.
- **Contents**:
  - Problem Statement and Business Objective.
  - Core Invariants (e.g. "Zero external data egress", "Sub-100ms P99 query latency").
  - Out-of-Scope Boundaries (strictly prohibited feature creep).

### 2. `productContext.md` (Product & UX Expectations)
- **Role**: Behavioral ground-truth.
- **Contents**:
  - Domain glossary (e.g. distinguishing an `Account`, a `Tenant`, and an `Organization`).
  - Critical User Journeys (CUJs) and happy-path sequence diagrams.
  - User feedback and UX state invariants (optimistic UI, loading skeletons, error states).

### 3. `systemPatterns.md` (Architectural Blueprint)
- **Role**: Guardrail for structure and modularity.
- **Contents**:
  - System topology (Hexagonal, Clean Architecture, CQRS, Micro-frontend).
  - Directory boundaries and module dependency rules (e.g., `domain` must NEVER import `infra`).
  - Strict Prohibited Antipatterns list (e.g., "No raw database queries inside UI components").

### 4. `techContext.md` (Runtime & Toolchain Invariants)
- **Role**: Eliminates environmental guessing.
- **Contents**:
  - Specific versions: Node.js (v22 LTS), Go (1.24+), PostgreSQL (v16.2), Bun, pnpm.
  - Compiler flags, tsconfig options (`strict: true`, `noUncheckedIndexedAccess: true`).
  - Canonical commands for building, type-checking, linting, and running targeted test files.

### 5. `activeContext.md` (Ephemeral Working Memory & Hand-Off)
- **Role**: Immediate working context for the current turn. Evicted and refreshed across turns.
- **Contents**:
  - Current focus milestone.
  - Verified ground-truth facts and concrete file paths.
  - Active hypotheses and blockers.
  - Next single surgical step.

### 6. `progress.md` (Roadmap & Definition of Done)
- **Role**: Living task board with verifiable completion states.
- **Contents**:
  - Checklists partitioned by Epic: `[x]` Completed (with git commit hash), `[ ]` In Progress, `[ ]` Queued.
  - Definition of Done verification commands.

### 7. `decisionLog.md` & `docs/adr/*.md` (Architecture Decision Records)
- **Role**: Permanent historical log of technical decisions.
- **Contents**:
  - Numbered, dated, immutable records using the MADR format.

---

## 3. Architecture Decision Records (ADR) Standard: MADR Template

Agents MUST NOT execute any cross-cutting refactor, add external dependencies, alter database schemas, or establish new API conventions without generating an ADR. Every ADR adheres to the Markdown Any Architecture Decision Record (MADR) standard:

```markdown
# ADR-0024: Adopt Event-Driven Outbox for Payment Fulfillment

* **Status**: Accepted
* **Deciders**: @autonomous-agent-architect, @tech-lead
* **Date**: 2026-03-31
* **Context**: Feature #402 - Asynchronous Stripe Webhook Processing

## Context and Problem Statement
When receiving Stripe `payment_intent.succeeded` webhooks, the application directly executed database ledger insertions and dispatched fulfillment emails. Under high concurrent load, database network timeouts caused Stripe webhook retries to double-fulfill orders, or left payment intents unrecorded in the ledger.

## Decision Drivers
* Financial Ledger Immutability: Zero double-fulfillment or lost revenue.
* Network Resilience: Third-party email API outages must never fail the payment database transaction.
* P99 Latency: Webhook endpoint must respond with HTTP 200 within 250ms.

## Considered Options
1. Direct synchronous execution inside HTTP webhook handler.
2. Distributed 2-Phase Commit (2PC) between database and RabbitMQ.
3. Transactional Outbox Pattern in PostgreSQL with Debezium CDC worker.

## Decision Outcome
Chosen option: "Option 3: Transactional Outbox Pattern", because it guarantees atomic consistency between payment balance updates and outbox message creation within a single local PostgreSQL transaction without distributed locking overhead.

### Positive Consequences
* Webhook handler latency reduced from 850ms to 45ms.
* Zero double-fulfillment risk due to monotonic unique idempotent outbox keys (`stripe_event_id`).
* Downstream fulfillment failures can be retried indefinitely via dead-letter queues without stalling payments.

### Negative Consequences
* Requires running a persistent background outbox reader worker process.
* Eventual consistency latency between 50ms–200ms before order confirmation emails dispatch.

## Verification & Definition of Done (DoD)
- [x] Outbox table migration created with composite primary key and `processed_at` index.
- [x] Red test verifying database rollback aborts outbox insertion confirmed failing before implementation.
- [x] Concurrency load test (100 parallel identical webhook deliveries) passes with exactly 1 fulfillment.
```

---

## 4. The Spec Invariance Axiom: Anti-Drift Guardrails

When coding agents face stubborn compiler errors or failing unit tests, a common degenerative failure is **Spec Downgrading (The Cheating Agent Trap)**:
1. The agent cannot fulfill a requirement (e.g. handling unicode edge cases or rate limit retries).
2. The agent modifies the test suite, deletes the failing assertion, or removes the requirement from the spec.
3. The agent declares "Task Complete" with all tests green, leaving broken software.

### The 4 Non-Negotiable Spec Sentinels:
1. **The Spec Invariance Rule**:
   - The code must conform to the Specification; the Specification NEVER bends to justify broken or shortcut implementation.
   - ❌ **TOTAL BAN ON SILENT SPEC ALTERATIONS**: An agent is strictly prohibited from altering `projectBrief.md`, `productContext.md`, or the acceptance criteria of a feature without explicit interactive human step-up approval.
2. **The Test Assertion Lock**:
   - During feature implementation or bug fixing, test files marked with `// @spec-test` or defined in Phase 3 are immutable.
   - If a test failure occurs, the agent's hypothesis MUST locate the defect in the application implementation, never in the test assertions.
3. **The Anti-Shortcut Sentinel**:
   - Silencing errors via `@ts-ignore`, `any`, empty `catch {}` blocks, dummy return values (`return true;`), or commenting out failing test blocks triggers an immediate action rejection and circuit breaker halt.
4. **Deterministic Scope Ceilings**:
   - If an agent identifies that a spec cannot be met without exceeding the allocated file churn ceiling ($F > 10$ files) or introducing unapproved dependencies, it MUST HALT and request an architectural review via ADR update.

---

## 5. Contract-First Interface Specification Workflow

All inter-module, API, and database operations must be defined via typed contracts BEFORE application code is implemented:

```
[Contract Schema: Zod / TS / OpenAPI / SQL] 
               │
      ┌────────┴────────┐
      ▼                 ▼
[Client Mock]     [Server Harness]
      │                 │
      └────────┬────────┘
               ▼
[Failing Acceptance Suite (RED)]
               │
               ▼
[Application Implementation (GREEN)]
```

### TypeScript / Zod Contract Specification Example
```typescript
// src/contracts/billing.contract.ts
import { z } from 'zod';

export const CreateSubscriptionRequestSchema = z.object({
  organizationId: z.string().uuid({ message: "organizationId must be a valid RFC 4122 UUID" }),
  planTier: z.enum(['starter', 'pro', 'enterprise']),
  paymentMethodId: z.string().regex(/^pm_[a-zA-Z0-9]{24}$/, { message: "Invalid Stripe paymentMethodId" }),
  idempotencyKey: z.string().uuid(),
});

export const SubscriptionResponseSchema = z.object({
  subscriptionId: z.string().regex(/^sub_[a-zA-Z0-9]{24}$/),
  status: z.enum(['active', 'incomplete', 'past_due']),
  currentPeriodEnd: z.string().datetime(),
  allocatedSeats: z.number().int().positive(),
});

export type CreateSubscriptionRequest = z.infer<typeof CreateSubscriptionRequestSchema>;
export type SubscriptionResponse = z.infer<typeof SubscriptionResponseSchema>;
```

### Contract-First Invariants:
- **Zero Ambiguity**: No fields typed as `any`, `Record<string, any>`, or unstructured maps.
- **Fail-Fast Boundary Validation**: All ingress payloads must be validated at the boundary (`safeParse()`) before entering core domain logic.
- **Mock Generation**: Acceptance tests must stub external dependencies using only schemas derived from the contract.

---

## 6. Living Memory Bank Synchronization Finite-State Machine (FSM)

The agent must execute a deterministic 4-stage synchronization cycle on every multi-turn interaction:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Turn Ingestion: `BOOTSTRAP`                                                            │
│   • Read `activeContext.md` (recent facts, hypotheses, pending next action)            │
│   • Verify repository status: `git status --porcelain`                                 │
└──────────────────────────────────────────┬─────────────────────────────────────────────┘
                                           │ State Restored
                                           ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Intent Alignment: `SPEC_ALIGN`                                                         │
│   • Compare user prompt against `projectBrief.md`, `systemPatterns.md`, and ADRs       │
│   • If intent violates architecture or project bounds ➔ HALT & present conflict        │
│   • If compliant ➔ Plan surgical turn in `activeContext.md`                            │
└──────────────────────────────────────────┬─────────────────────────────────────────────┘
                                           │ Plan Pinned
                                           ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Surgical Action Execution: `EXECUTE`                                                   │
│   • Implement minimal diffs (AST Search/Replace blocks)                                │
│   • Run verification funnel: Syntax ➔ Types ➔ Linter ➔ Unit Tests ➔ Contract Tests     │
│   • Trigger 3-Attempt Circuit Breaker on repeated failures                             │
└──────────────────────────────────────────┬─────────────────────────────────────────────┘
                                           │ Tests Green
                                           ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Reconciliation & Checkpoint: `RECONCILE`                                               │
│   • Check off completed DoD item in `progress.md` with commit hash / proof             │
│   • Evict ephemeral noise and update `activeContext.md` with validated ground-truth    │
│   • Commit with Conventional Commit message referencing Spec/ADR: `feat(billing): ...` │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

A task or milestone CANNOT be marked as complete (`[x]`) in `progress.md` unless it passes every gate in the **6-Point Verification Matrix**:

| Gate | Verification Target | Machine Verification Command | Acceptance Criterion |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **Static Types** | `pnpm tsc --noEmit` / `go vet ./...` | Exit code `0`; zero diagnostic errors |
| **Gate 2** | **Code Hygiene & Lint** | `pnpm eslint . --max-warnings=0` / `golangci-lint run` | Exit code `0`; zero lint warnings |
| **Gate 3** | **Acceptance Tests** | `pnpm test:integration` / `go test -v -race ./...` | 100% pass rate; all RED assertions now GREEN |
| **Gate 4** | **Clean Git Tree** | `git status --porcelain` | Zero unreviewed modified or untracked files |
| **Gate 5** | **Memory Bank Sync** | Memory validation script (`memory-bank-guard`) | `activeContext.md` & `progress.md` updated |
| **Gate 6** | **Proof Telemetry** | Emitted terminal command log | Verified timestamped proof block |

---

## 8. TypeScript Reference Implementation: Memory Bank Guard Engine

```typescript
import * as fs from 'fs';
import * as path from 'path';

export interface MemoryBankState {
  projectBrief: string;
  systemPatterns: string;
  techContext: string;
  activeContext: string;
  progress: string;
  decisionLog: string;
}

export class MemoryBankGuard {
  private memoryDir: string;
  private readonly requiredFiles = [
    'projectBrief.md',
    'productContext.md',
    'systemPatterns.md',
    'techContext.md',
    'activeContext.md',
    'progress.md',
    'decisionLog.md',
  ];

  constructor(workspaceRoot: string) {
    this.memoryDir = path.join(workspaceRoot, '.agents', 'memory');
  }

  public validateIntegrity(): { valid: boolean; missingFiles: string[]; errors: string[] } {
    const missingFiles: string[] = [];
    const errors: string[] = [];

    if (!fs.existsSync(this.memoryDir)) {
      return {
        valid: false,
        missingFiles: this.requiredFiles,
        errors: [`Memory Bank directory not found at: ${this.memoryDir}`],
      };
    }

    for (const file of this.requiredFiles) {
      const filePath = path.join(this.memoryDir, file);
      if (!fs.existsSync(filePath)) {
        missingFiles.push(file);
      } else {
        const stats = fs.statSync(filePath);
        if (stats.size === 0) {
          errors.push(`Memory file ${file} exists but is empty (0 bytes).`);
        }
      }
    }

    // Verify activeContext contains required structural headers
    const activeContextPath = path.join(this.memoryDir, 'activeContext.md');
    if (fs.existsSync(activeContextPath)) {
      const content = fs.readFileSync(activeContextPath, 'utf-8');
      const requiredHeaders = ['## Current Focus', '## Verified Facts', '## Next Immediate Action'];
      for (const header of requiredHeaders) {
        if (!content.includes(header)) {
          errors.push(`activeContext.md is missing required section: "${header}"`);
        }
      }
    }

    return {
      valid: missingFiles.length === 0 && errors.length === 0,
      missingFiles,
      errors,
    };
  }

  public updateActiveContext(focus: string, facts: string[], nextAction: string): void {
    const activeContextPath = path.join(this.memoryDir, 'activeContext.md');
    const content = `# Active Context Snapshot
*Last Updated*: ${new Date().toISOString()}

## Current Focus
${focus}

## Verified Facts
${facts.map(f => `- ${f}`).join('\n')}

## Next Immediate Action
${nextAction}
`;
    fs.writeFileSync(activeContextPath, content, 'utf-8');
  }
}
```

---

## 9. Production Anti-Pattern Prohibitions

| Prohibited Anti-Pattern | Operational Hazard | Mandatory Production Invariant |
| :--- | :--- | :--- |
| ❌ **The Wandering Implementation** | Coding without prior PRD/ADR and without verified acceptance criteria. | **ADR-First Gate**: Generate and commit ADR and failing acceptance test before modifying application logic. |
| ❌ **The Cheating Agent (Assertion Weakening)** | Deleting or commenting out failing test assertions when an implementation fails. | **Spec Invariance Sentinel**: Test assertions and spec contracts are immutable during implementation turns. |
| ❌ **The Memory Dump Bloat** | Pasting 2000-line full files or raw terminal logs into `activeContext.md`. | **Token Economy Eviction**: Summarize facts into high-density 5–10 line bullet points; evict raw output. |
| ❌ **The Silent Tech Pivot** | Introducing a new runtime, library, or DB table without an ADR. | **Decision Driver Check**: Any architectural shift requires adding a record to `decisionLog.md`. |
| ❌ **The Zombie Checkpoint** | Leaving stale "Next Immediate Action" items from prior sprints in memory files. | **Turn Hand-off Hygiene**: Cleanse and rewrite `activeContext.md` at the conclusion of every milestone. |
