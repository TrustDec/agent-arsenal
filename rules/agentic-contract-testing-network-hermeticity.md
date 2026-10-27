---
description: Agentic contract testing, hermetic network interception, schema-driven test doubles, Consumer-Driven Contracts (Pact), OpenAPI 3.1 mock validation, default-deny outbound network isolation, and record-replay sanitization across Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{contract,mock,msw,wiremock,pact,fixture,recorder,replay}*.*,**/tests/**/*.{ts,js,py,go},**/test/**/*.{ts,js,py,go},**/contracts/**/*.{json,yaml,yml,proto}
alwaysApply: false
---

# Agentic Contract Testing, Hermetic Network Interception & Test Double Verification

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to write integration tests, synthesize API mocks, integrate third-party services (Stripe, GitHub, AWS, OAuth, OpenAI), or verify distributed microservice boundaries. Eliminate the "Fantasy Wire Mock Trap" (where agents invent fictional JSON responses that pass unit tests but fail catastrophically against real APIs), the "Leaky Outbound Network Disaster" (where tests make accidental HTTP calls to external staging/production endpoints, exhausting rate limits or failing offline), the "Over-Mocking Amnesia" (where agents mock away the very business logic under test), and "Silent Contract Drift" by establishing a strict 5-Tier Test Double & Network Hermeticity Ladder, quantitative mock fidelity scoring, schema-validated test doubles, consumer-driven contracts (Pact), and automated PII/secret-scrubbed record-replay engines.

---

## 1. Architectural Taxonomy: The Fantasy Wire Mock Dilemma vs The 5-Tier Test Double Ladder

In autonomous agent-driven development, agents are frequently instructed to "write integration tests for the payment provider" or "mock the external user authentication service." Without strict machine-enforced boundaries, LLMs exhibit four dangerous failure modes:

- **The "Fantasy Wire Mock" Trap**:
  - LLM agents hallucinate external HTTP API payloads. They generate JSON fixtures that satisfy local TypeScript types but completely diverge from upstream reality:
    - Inventing property names (e.g. `{ "success": true, "transaction_id": "123" }` instead of Stripe's `{ "status": "succeeded", "id": "ch_123" }`).
    - Lowercasing header names or misrepresenting nested wrapper envelopes (`{ "data": { ... } }` vs top-level arrays).
    - Fabricating timestamp formats (numeric milliseconds vs ISO 8601 UTC strings `2026-03-30T12:00:00Z`).
  - The local test suite passes with 100% green checkmarks, but the application crashes immediately upon deployment when receiving actual wire responses.
- **The "Leaky Outbound Network" Disaster**:
  - Unconstrained agents write tests using standard HTTP clients (`fetch`, `axios`, `http.Client`, `requests`) without installing an airtight interception layer.
  - Tests attempt real TCP handshakes to live endpoints (`api.stripe.com`, `api.github.com`). In offline environments, CI runners, or air-gapped sandboxes, the suite hangs or crashes with DNS resolution failures. Worse, in un-sandboxed environments, tests may execute live mutations (creating real test users, sending real Slack webhooks, burning paid API tokens).
- **The "Over-Mocking Amnesia" Anti-Pattern**:
  - To achieve green test runs, agents frequently mock internal collaborators rather than external system boundaries.
  - An agent instructed to test a repository will monkey-patch `db.query` or `prisma.user.findUnique` to return hardcoded records. This eliminates test coverage for SQL syntax, column mapping, serialization, nullability constraints, and database connection pooling. The agent tests its own mock rather than the software.
- **The "Silent Contract Drift" Catastrophe**:
  - Microservices and third-party APIs evolve independently. When an upstream provider updates an OpenAPI specification or deprecates a field, downstream agent mocks continue using stale fixtures. The drift remains undetected until integration or production failure.
- **The 5-Tier Test Double & Network Hermeticity Ladder**:
  - Autonomous agents must adhere to 5 ascending verification tiers to guarantee test fidelity and network hermeticity:
    - **Tier 0: Default-Deny Hermetic Network Isolation**: The test runner enforces hard transport-level blackholing. Any unhandled outbound HTTP/TCP request immediately fails the test with a descriptive violation error. Zero bytes leave the loopback boundary.
    - **Tier 1: Schema-Validated Wire Mocks**: Every synthetic test double and mock response is verified against the official OpenAPI 3.1, JSON Schema, or Protobuf descriptor. If an agent mock violates the schema, the test harness rejects it before execution.
    - **Tier 2: Consumer-Driven Contract Verification (Pact / Bidirectional Contracts)**: Interactions between distributed services are formalized as executable contracts. Providers verify contracts against real handlers; consumers verify mocks against published contracts.
    - **Tier 3: Sanitized Record-Replay Fixtures (VCR / HAR Cassettes)**: Real network interactions are captured once during explicit live recording passes, scrubbed of all secrets/PII, and replayed deterministically in hermetic CI runs.
    - **Tier 4: Ephemeral In-Process Mock Servers (MSW / WireMock / Go `httptest.Server`)**: Interception operates at the transport boundary (Service Worker, Node `undici` dispatcher, Go `RoundTripper`), simulating HTTP status codes, headers, delays, and network failures with zero external infrastructure.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Autonomous Agent Generates Integration Tests & Third-Party Service Mocks                         │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: The Fantasy Mock & Egress Leak]                                  ▼ [PRODUCTION: 5-Tier Test Double Ladder]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ jest.mock('../client') with fabricated JSON     │               │ Tier 0: Default-Deny Network Hermeticity        │
│ ❌ Hallucinated response wire schemas           │               │ • Unhandled egress strictly prohibited          │
│ ❌ Unhandled outbound HTTP leaks to real APIs   │               │ • Transport-level blackhole on live calls       │
│ ❌ Mocks business logic instead of boundaries   │               ├─────────────────────────────────────────────────┤
│ ❌ Fails silently on upstream API drift         │               │ Tier 1: Schema-Validated Wire Mocks             │
│ ❌ Flaky CI crashes in offline runner enclaves  │               │ • Mocks validated against OpenAPI 3.1 / Zod     │
└─────────────────────────────────────────────────┘               │ • Type & constraint verification at mock boundary│
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 2: Consumer-Driven Contracts (Pact)        │
                                                                  │ • Consumer expectations verified by provider    │
                                                                  │ • Automated drift detection in CI pipelines     │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 3: Sanitized Record-Replay (VCR / HAR)     │
                                                                  │ • Real HTTP captured during explicit live sync  │
                                                                  │ • Mandatory PII & auth header redaction         │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 4: Ephemeral In-Process Interception       │
                                                                  │ • MSW / Go RoundTripper / WireMock              │
                                                                  │ • Zero infrastructure, zero socket leaks        │
                                                                  └─────────────────────────────────────────────────┘
```

---

## 2. Mathematical Formulations & Quantitative Mock Fidelity Calculus

To eliminate subjective guesswork and prevent hallucinated fixtures, autonomous agents must calculate quantitative mock fidelity and schema drift metrics.

### 2.1 The Mock Fidelity Index ($F_{\text{mock}}$)

The Mock Fidelity Index measures the degree to which a test double adheres to the formal schema specification $\mathcal{S}$:

$$F_{\text{mock}} = \mathbb{I}_{\text{valid}} \cdot \left( w_{\text{req}} \cdot \frac{|\mathcal{F}_{\text{mock}} \cap \mathcal{F}_{\text{required}}|}{|\mathcal{F}_{\text{required}}|} + w_{\text{opt}} \cdot \frac{|\mathcal{F}_{\text{mock}} \cap \mathcal{F}_{\text{optional}}|}{|\mathcal{F}_{\text{optional}}|} - w_{\text{halluc}} \cdot \frac{|\mathcal{F}_{\text{mock}} \setminus (\mathcal{F}_{\text{required}} \cup \mathcal{F}_{\text{optional}})|}{|\mathcal{F}_{\text{mock}}|} \right)$$

Where:
- $\mathbb{I}_{\text{valid}} \in \{0, 1\}$: Binary schema validation indicator (1 if payload compiles against OpenAPI/Zod schema, 0 if validation fails).
- $\mathcal{F}_{\text{required}}$: Set of required fields defined in the schema.
- $\mathcal{F}_{\text{optional}}$: Set of optional fields defined in the schema.
- $\mathcal{F}_{\text{mock}}$: Set of fields present in the agent-authored mock.
- $w_{\text{req}} = 0.60, \, w_{\text{opt}} = 0.25, \, w_{\text{halluc}} = 0.50$: Tuning weights penalizing hallucinated extra fields.
- **Production Invariant**: $F_{\text{mock}} \ge 0.85$ with $|\mathcal{F}_{\text{mock}} \setminus (\mathcal{F}_{\text{required}} \cup \mathcal{F}_{\text{optional}})| \equiv 0$ (Zero hallucinated fields permitted).

### 2.2 Contract Drift Divergence ($D_{\text{contract}}$)

Given an expected contract schema $\mathcal{S}_{\text{expected}}$ and an actual upstream schema $\mathcal{S}_{\text{upstream}}$, the contract drift metric is defined as:

$$D_{\text{contract}} = 1 - \frac{|\text{Properties}(\mathcal{S}_{\text{expected}}) \cap \text{Properties}(\mathcal{S}_{\text{upstream}})|}{|\text{Properties}(\mathcal{S}_{\text{expected}}) \cup \text{Properties}(\mathcal{S}_{\text{upstream}})|}$$

- When $D_{\text{contract}} = 0$, the contract is in perfect synchronization.
- If $D_{\text{contract}} > 0$, breaking changes or schema drift have occurred, triggering mandatory quarantine of dependent test doubles.

### 2.3 Network Hermeticity Invariant ($\mathcal{H}_{\text{net}}$)

Let $\mathcal{R}_{\text{test}}$ be the set of all HTTP/TCP requests emitted during the test run, and $\mathcal{A}_{\text{loopback}}$ be the allowed local in-process listeners (`127.0.0.1`, `::1`, `localhost`):

$$\mathcal{H}_{\text{net}} \equiv \forall r \in \mathcal{R}_{\text{test}}, \quad \text{Host}(r) \in \mathcal{A}_{\text{loopback}} \implies P(\text{leak}) = 0$$

If any request $r \in \mathcal{R}_{\text{test}}$ targets an external IP or unhandled host, the test harness MUST throw an uncatchable fatal assertion:

$$\text{UnhandledEgressException} \implies \text{ExitCode} \neq 0$$

---

## 3. The 4 Golden Rules of Test Doubles & Mocking Discipline

Autonomous agents must strictly abide by four invariant rules when authoring test doubles:

### Rule 1: Mock at Architectural Boundaries, Never Internal Units
- ❌ **Prohibited**: Mocking internal domain services, helper classes, or database ORMs (`jest.spyOn(userService, 'hashPassword')` or `prisma.account.update = jest.fn()`).
- ✅ **Mandatory**: Mock at the physical I/O boundary (HTTP transport layer, database network driver, message broker protocol handler). Execute real internal application logic from controller down to the wire client.

### Rule 2: Strict Default-Deny on All Unhandled Network Egress
- ❌ **Prohibited**: Allowing unmatched HTTP requests to "pass through" to live external networks during test execution (`passthrough()` or unhandled fallback).
- ✅ **Mandatory**: Interception engines (MSW, Nock, WireMock, Go `RoundTripper`) must configure strict error modes (`onUnhandledRequest: 'error'`). Any unmocked request immediately aborts the test with a descriptive failure showing the unhandled method, URL, and headers.

### Rule 3: Zero Fictional Payload Schemas (Schema-First Verification)
- ❌ **Prohibited**: Freehand crafting JSON mock fixtures from prompt memory.
- ✅ **Mandatory**: Every test double fixture must be validated through formal schema validators (Zod, Ajv for OpenAPI 3.1, or Protobuf runtime validators) before returning from the mock handler. If the schema validator rejects the mock, the test fails immediately.

### Rule 4: Secret & PII Scrubbing in Replay Cassettes
- ❌ **Prohibited**: Committing raw VCR or HAR network cassettes containing live authorization tokens, session cookies, API keys, email addresses, or payment card numbers.
- ✅ **Mandatory**: Automated regex scrubbers MUST sanitize all `Authorization`, `Cookie`, `X-Api-Key`, and sensitive JSON fields (e.g. `client_secret`, `card_number`, `ssn`) into deterministic placeholders (`REDACTED_SECRET_TOKEN`) before persisting to version control.

---

## 4. Architectural Interception Topology: MSW, WireMock & Go Transports

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Modern In-Process & Transport-Level Interception Architecture                          │
└────────────────────────────────────────────────────────────────────────────────────────┘

 [Application Under Test]
        │
        │ HTTP Request (e.g. GET https://api.stripe.com/v1/customers/cus_123)
        ▼
 ┌──────────────────────────────────────────────────────────────────────────────────────┐
 │ Hermetic Transport Interception Firewall                                             │
 │ (MSW Node Interceptor / Go http.RoundTripper / Python Responses Transport)          │
 └──────────────────────┬────────────────────────────────────────┬──────────────────────┘
                        │                                        │
           [Match Found in Handlers]                [No Match / Unhandled Host]
                        │                                        │
                        ▼                                        ▼
 ┌──────────────────────────────────────────────┐ ┌─────────────────────────────────────┐
 │ Schema Validation Gate                       │ │ Hard Failure Sentinel               │
 │ • Validates mock payload vs OpenAPI/Zod      │ │ • Blocks TCP connection immediately │
 │ • Verifies HTTP status code & headers        │ │ • Emits UnhandledEgressException    │
 │ • Injects realistic network delay (5-15ms)   │ │ • Test FAILS (Exit Code 1)          │
 └──────────────────────┬───────────────────────┘ └─────────────────────────────────────┘
                        │
                        ▼
       [Synthesized Schema-Valid Response]
                        │
                        ▼
 [Application Under Test processes wire response]
```

---

## 5. Production Reference Implementation: `AgenticContractVerificationEngine`

The following TypeScript engine provides a complete, production-ready contract verification and hermetic test double harness. It features default-deny transport interception, OpenAPI/Zod schema validation, mock fidelity calculation, and secret scrubbing for cassette recording.

```typescript
// agentic-contract-engine.ts
// Production Hermetic Contract Verification & Mock Fidelity Harness

import { z, ZodSchema } from 'zod';

export interface ContractInteraction {
  id: string;
  provider: string;
  consumer: string;
  request: {
    method: 'GET' | 'POST' | 'PUT' | 'DELETE' | 'PATCH';
    path: string;
    headers?: Record<string, string>;
    query?: Record<string, string>;
    bodySchema?: ZodSchema<any>;
    body?: unknown;
  };
  response: {
    status: number;
    headers?: Record<string, string>;
    bodySchema: ZodSchema<any>;
    body: unknown;
  };
}

export interface VerificationResult {
  interactionId: string;
  passed: boolean;
  fidelityScore: number;
  unhandledEgressDetected: boolean;
  errors: string[];
}

export interface SanitizationRule {
  pattern: RegExp;
  replacement: string;
}

export class AgenticContractVerificationEngine {
  private registeredInteractions: Map<string, ContractInteraction> = new Map();
  private recordedCalls: Array<{ method: string; url: string; timestamp: number }> = [];
  private allowedHosts: Set<string> = new Set(['127.0.0.1', 'localhost', '::1']);

  private defaultSanitizationRules: SanitizationRule[] = [
    { pattern: /Bearer\s+[A-Za-z0-9_\-\.]+/gi, replacement: 'Bearer [REDACTED_AUTH_TOKEN]' },
    { pattern: /(api[_-]?key|secret|password)["']?\s*[:=]\s*["']?[^"'\s,]+/gi, replacement: '$1: "[REDACTED_SECRET]"' },
    { pattern: /\b\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}\b/g, replacement: '[REDACTED_CARD_NUMBER]' },
    { pattern: /[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+/g, replacement: 'redacted_user@example.test' },
  ];

  constructor(allowedLocalHosts?: string[]) {
    if (allowedLocalHosts) {
      for (const h of allowedLocalHosts) this.allowedHosts.add(h);
    }
  }

  /**
   * Register a contract interaction with strict schema pinning.
   */
  public registerInteraction(interaction: ContractInteraction): void {
    // Pre-flight check: validate that response body adheres to its own schema
    const parseResult = interaction.response.bodySchema.safeParse(interaction.response.body);
    if (!parseResult.success) {
      throw new Error(
        `[ContractRegistrationError] Interaction '${interaction.id}' has an invalid mock response body: ` +
        JSON.stringify(parseResult.error.format())
      );
    }

    this.registeredInteractions.set(interaction.id, interaction);
  }

  /**
   * Intercept and dispatch a request against registered contracts.
   * Enforces Default-Deny Network Hermeticity.
   */
  public async handleRequest(
    method: string,
    urlStr: string,
    headers: Record<string, string> = {},
    body?: unknown
  ): Promise<{ status: number; headers: Record<string, string>; body: unknown }> {
    const parsedUrl = new URL(urlStr);
    this.recordedCalls.push({ method, url: urlStr, timestamp: Date.now() });

    // Tier 0 Check: Is host allowed or intercepted?
    const isLocal = this.allowedHosts.has(parsedUrl.hostname);

    // Search matching contract interaction
    let matched: ContractInteraction | undefined;
    for (const interaction of this.registeredInteractions.values()) {
      if (
        interaction.request.method === method.toUpperCase() &&
        parsedUrl.pathname === interaction.request.path
      ) {
        matched = interaction;
        break;
      }
    }

    if (!matched) {
      if (!isLocal) {
        // Hard failure: Unhandled external egress attempt!
        throw new Error(
          `[HermeticNetworkViolation] Unhandled outbound HTTP request detected!\n` +
          `Destination: ${method} ${urlStr}\n` +
          `Security Policy: Default-Deny active. Zero external network egress permitted in test suites.\n` +
          `Remedy: Register an explicit schema-verified ContractInteraction or mock handler before executing.`
        );
      }
      throw new Error(`[UnhandledLocalRequest] No contract registered for local endpoint: ${method} ${parsedUrl.pathname}`);
    }

    // Verify request body schema if defined
    if (matched.request.bodySchema) {
      const reqParse = matched.request.bodySchema.safeParse(body);
      if (!reqParse.success) {
        throw new Error(
          `[ContractViolation] Outbound request body violates expected contract for '${matched.id}': ` +
          JSON.stringify(reqParse.error.format())
        );
      }
    }

    return {
      status: matched.response.status,
      headers: matched.response.headers || { 'content-type': 'application/json' },
      body: matched.response.body,
    };
  }

  /**
   * Quantitative Mock Fidelity Calculation
   */
  public calculateFidelity(interactionId: string): number {
    const interaction = this.registeredInteractions.get(interactionId);
    if (!interaction) return 0;

    const parseResult = interaction.response.bodySchema.safeParse(interaction.response.body);
    if (!parseResult.success) return 0;

    const mockBody = interaction.response.body;
    if (typeof mockBody !== 'object' || mockBody === null) return 1.0;

    const mockKeys = Object.keys(mockBody as Record<string, unknown>);
    
    // Introspect Zod shape if available
    const schemaShape = (interaction.response.bodySchema as any).shape;
    if (!schemaShape) return 1.0;

    const expectedKeys = Object.keys(schemaShape);
    const requiredKeys = expectedKeys.filter((k) => !schemaShape[k].isOptional());
    const optionalKeys = expectedKeys.filter((k) => schemaShape[k].isOptional());

    const matchedRequired = mockKeys.filter((k) => requiredKeys.includes(k)).length;
    const matchedOptional = mockKeys.filter((k) => optionalKeys.includes(k)).length;
    const hallucinatedKeys = mockKeys.filter((k) => !expectedKeys.includes(k)).length;

    const wReq = 0.6;
    const wOpt = 0.25;
    const wHalluc = 0.5;

    const reqScore = requiredKeys.length > 0 ? (matchedRequired / requiredKeys.length) * wReq : wReq;
    const optScore = optionalKeys.length > 0 ? (matchedOptional / optionalKeys.length) * wOpt : wOpt;
    const hallucPenalty = mockKeys.length > 0 ? (hallucinatedKeys / mockKeys.length) * wHalluc : 0;

    return Math.max(0, Math.min(1.0, reqScore + optScore - hallucPenalty));
  }

  /**
   * Sanitize recorded payload for deterministic, secret-free cassette persistence.
   */
  public sanitizePayload(rawPayload: string): string {
    let sanitized = rawPayload;
    for (const rule of this.defaultSanitizationRules) {
      sanitized = sanitized.replace(rule.pattern, rule.replacement);
    }
    return sanitized;
  }

  /**
   * Complete verification report for the session
   */
  public generateReport(): VerificationResult[] {
    const results: VerificationResult[] = [];

    for (const [id] of this.registeredInteractions.entries()) {
      const fidelity = this.calculateFidelity(id);
      results.push({
        interactionId: id,
        passed: fidelity >= 0.85,
        fidelityScore: fidelity,
        unhandledEgressDetected: false,
        errors: fidelity < 0.85 ? [`Fidelity score ${fidelity.toFixed(2)} below threshold 0.85`] : [],
      });
    }

    return results;
  }
}
```

---

## 6. The 6-State Contract Testing & Mock Verification Lifecycle (FSM)

Autonomous agents must transition deterministically through the 6-state lifecycle when authoring tests involving external or distributed boundaries:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ The 6-State Contract & Network Hermeticity Lifecycle Finite-State Machine                        │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘

   [STATE 0: BOUNDARY_DISCOVERY]
          │ AST parse identifies outbound HTTP/gRPC client invocations & endpoints
          ▼
   [STATE 1: SCHEMA_PINNING]
          │ Ingest official OpenAPI 3.1, JSON Schema, or Protobuf descriptors
          ▼
   [STATE 2: HERMETIC_INTERCEPTION_INSTALL]
          │ Configure MSW / RoundTripper with default-deny onUnhandledRequest: 'error'
          ▼
   [STATE 3: WIRE_MOCK_SYNTHESIS]
          │ Synthesize fixtures conforming to pinned schema (F_mock >= 0.85, zero hallucinated fields)
          ▼
   [STATE 4: ISOLATED_EXECUTION_GATE]
          │ Execute test suite in offline runner; trap any unhandled egress or schema failures
          ├── [Unhandled Egress or Schema Error] ──► [STATE 5: QUARANTINE_ON_DRIFT]
          ▼ [All Tests Pass & Verified Hermetic]           │ Generate minimal repro diff & fix schema
   [MERGE_READY / GREEN PASS] ◄────────────────────────────┘
```

1. **State 0: BOUNDARY_DISCOVERY**: The agent uses static analysis (Tree-sitter/AST) to identify all outbound network boundaries (`fetch`, `axios`, `http.Client`, database drivers, third-party SDKs) within the code under test.
2. **State 1: SCHEMA_PINNING**: The agent locates and pins the official OpenAPI 3.1 specification, Protobuf definition, or Zod contract representing the external service.
3. **State 2: HERMETIC_INTERCEPTION_INSTALL**: The agent installs a default-deny transport interception layer (`onUnhandledRequest: 'error'`) ensuring zero external network egress.
4. **State 3: WIRE_MOCK_SYNTHESIS**: The agent synthesizes mock payloads that strictly validate against the schema ($F_{\text{mock}} \ge 0.85$, zero hallucinated extra properties).
5. **State 4: ISOLATED_EXECUTION_GATE**: The test suite executes in a hermetically sealed environment. If any unhandled request or schema divergence is detected, the run immediately aborts.
6. **State 5: QUARANTINE_ON_DRIFT**: If upstream schemas change or tests fail contract assertions, the agent captures the exact schema delta, isolates the failing interaction, and updates either the contract or the application consumer.

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

Before any integration test or third-party service mock is approved, it must satisfy all 6 machine-verifiable gates:

| Gate | Verification Dimension | Target Threshold / Invariant | Validation Command |
|---|---|---|---|
| **Gate 1** | **Network Hermeticity** | $P(\text{leak}) \equiv 0$; zero unhandled outbound HTTP/TCP calls | `CI=true pnpm test -- --network-check` or `go test -v ./...` with hermetic transport |
| **Gate 2** | **Schema Conformance** | $F_{\text{mock}} \ge 0.85$; $0$ schema validation errors | `npx ajv-cli validate -s schema.json -d mock.json` or Zod safeParse check |
| **Gate 3** | **Zero Hallucinated Fields** | $|\mathcal{F}_{\text{mock}} \setminus (\mathcal{F}_{\text{req}} \cup \mathcal{F}_{\text{opt}})| \equiv 0$ | Strict schema parsing rejecting unknown keys (`z.object().strict()`) |
| **Gate 4** | **Secret Redaction** | $0$ API keys, Bearer tokens, or live credentials in cassettes | `rg -i "bearer [a-z0-9_\-\.]{20,}" tests/fixtures/` returns zero hits |
| **Gate 5** | **Offline Test Pass** | 100% test pass rate with network disabled (`unshare -n` or offline container) | `ip link set lo up && pnpm test` or `go test ./...` |
| **Gate 6** | **Contract Parity** | $D_{\text{contract}} \equiv 0$; upstream provider contract verification passes | `npx pact-broker can-i-deploy` or local provider verification task |

---

## 8. Stack-Specific Implementation Guides & Production Recipes

### 8.1 TypeScript / Vitest / MSW (Mock Service Worker)

In modern Node.js and Vitest test suites, enforce MSW with strict unhandled request rejection and Zod schema verification:

```typescript
// tests/setup/msw-server.ts
import { setupServer } from 'msw/node';
import { http, HttpResponse } from 'msw';
import { z } from 'zod';

// Official Stripe Customer Schema slice
const StripeCustomerSchema = z.object({
  id: z.string().startsWith('cus_'),
  object: z.literal('customer'),
  email: z.string().email(),
  balance: z.number().int(),
  created: z.number().int(),
  livemode: z.boolean(),
}).strict(); // Prohibits hallucinated properties!

export const handlers = [
  http.get('https://api.stripe.com/v1/customers/:id', ({ params }) => {
    const rawMock = {
      id: params.id,
      object: 'customer',
      email: 'alex@example.test',
      balance: 0,
      created: 1711800000,
      livemode: false,
    };

    // Gate: Reject mock immediately if it fails the official schema
    const validated = StripeCustomerSchema.parse(rawMock);
    return HttpResponse.json(validated, { status: 200 });
  }),
];

export const server = setupServer(...handlers);

// Vitest Setup Lifecycle with Hard Hermetic Boundary
beforeAll(() => {
  // CRITICAL: 'error' aborts tests on any unmocked outbound request!
  server.listen({ onUnhandledRequest: 'error' });
});

afterEach(() => {
  server.resetHandlers();
});

afterAll(() => {
  server.close();
});
```

### 8.2 Go: Hermetic `http.RoundTripper` & `httptest.Server`

In Go, prevent unhandled external network calls by injecting a hermetic `RoundTripper` that blocks unhandled hosts:

```go
package client_test

import (
    "fmt"
    "io"
    "net/http"
    "net/http/httptest"
    "testing"
    "github.com/stretchr/testify/require"
)

// HermeticTransport panics on any network egress outside the local test server
type HermeticTransport struct {
    AllowedHost string
    Underlying  http.RoundTripper
}

func (h *HermeticTransport) RoundTrip(req *http.Request) (*http.Response, error) {
    if req.URL.Host != h.AllowedHost {
        return nil, fmt.Errorf("FATAL HERMETIC VIOLATION: Unhandled egress to host '%s' prohibited", req.URL.Host)
    }
    return h.Underlying.RoundTrip(req)
}

func TestPaymentClient_GetCustomer_Hermetic(t *testing.T) {
    // 1. Spin up ephemeral loopback server
    ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        require.Equal(t, "/v1/customers/cus_123", r.URL.Path)
        require.Equal(t, "Bearer test_secret_key", r.Header.Get("Authorization"))

        w.Header().Set("Content-Type", "application/json")
        w.WriteHeader(http.StatusOK)
        _, _ = w.Write([]byte(`{
            "id": "cus_123",
            "object": "customer",
            "email": "dev@example.test",
            "balance": 0
        }`))
    }))
    defer ts.Close()

    // 2. Configure HTTP client with strict hermetic transport
    client := &http.Client{
        Transport: &HermeticTransport{
            AllowedHost: ts.Listener.Addr().String(),
            Underlying:  http.DefaultTransport,
        },
    }

    // 3. Execute client against test server
    resp, err := client.Get(ts.URL + "/v1/customers/cus_123")
    require.NoError(t, err)
    defer func() {
        _, _ = io.Copy(io.Discard, resp.Body)
        _ = resp.Body.Close()
    }()

    require.Equal(t, http.StatusOK, resp.StatusCode)
}
```

### 8.3 Python / pytest: Hermetic Transport Interception with `pytest-httpx`

In Python, configure `httpx` or `requests` to deny unmocked calls by default:

```python
# test_billing_hermetic.py
import pytest
import httpx
from pydantic import BaseModel, ConfigDict

class CustomerResponse(BaseModel):
    model_config = ConfigDict(extra="forbid") # Prohibits hallucinated fields
    id: str
    object: str
    email: str
    balance: int

def test_fetch_customer_hermetic(httpx_mock):
    # Enforce strict default-deny: unhandled outbound calls fail the test!
    httpx_mock.add_response(
        method="GET",
        url="https://api.stripe.com/v1/customers/cus_123",
        status_code=200,
        json={
            "id": "cus_123",
            "object": "customer",
            "email": "py@example.test",
            "balance": 0
        }
    )

    with httpx.Client() as client:
        response = client.get("https://api.stripe.com/v1/customers/cus_123")
        assert response.status_code == 200

        # Validate schema conformance
        validated = CustomerResponse.model_validate(response.json())
        assert validated.id == "cus_123"
```
