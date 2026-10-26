---
description: Agentic trajectory observability, OpenTelemetry distributed tracing, OpenInference GenAI semantic conventions, token spend calculus & cost budgeting, TTFT / latency monitoring, looping anomaly detection, and trajectory export across Claude Code, Cursor, Windsurf, Devin, and Pi
globs: **/*{telemetry,tracing,opentelemetry,openinference,trajectory,langfuse,traceloop,phoenix,observability,span,cost,metrics}*.*,**/rules/**,**/.cursorrules,**/CLAUDE.md,**/AGENTS.md,**/.agents/**
alwaysApply: false
---

# Agentic Trajectory Observability, OpenTelemetry Distributed Tracing & Token Cost Governance

> Add these rules to your project when architecting, executing, or auditing autonomous coding agents, multi-agent swarms, or SWE-bench agent harnesses (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode). Eliminate the "Black-Box Trajectory Dilemma" by instrumenting agent reasoning loops, tool executions, and subagent handoffs with OpenTelemetry and OpenInference semantic conventions, enforcing real-time token spend calculus, monitoring streaming latency (TTFT / ITL), detecting semantic reasoning loops, and scrubbing sensitive credentials prior to telemetry export.

---

## 1. Architectural Taxonomy: The Black-Box Trajectory Dilemma vs OpenInference Telemetry

In autonomous software engineering, agents operate across long-horizon trajectories (20–80 turns) involving LLM inference, shell command execution, file modifications, git operations, and subagent delegations. Operating without distributed tracing creates critical production failure modes:

- **The Black-Box Trajectory Dilemma ($O(T)$ Blindness)**:
  - An agent fails a task, modifies the wrong files, or times out after 40 turns.
  - Engineers only see raw, unformatted console terminal output. It is impossible to isolate which specific prompt caused the hallucination, how much each tool call cost, or where latency bottlenecks occurred.
- **The Runaway Spend Disaster**:
  - An agent enters an unconstrained retry loop or attempts to ingest multi-megabyte minified bundles into its context window.
  - In the absence of real-time token cost governance, a single run burns $30–$50 in frontier model API credits before human intervention.
- **The APM Credential Poisoning Trap**:
  - The agent reads `.env` files, extracts database connection strings, or invokes APIs with authorization bearer tokens.
  - Naive APM instrumentation exports raw tool arguments and stdout dumps to external observability backends (Langfuse, Arize Phoenix, Datadog, Honeycomb), permanently exposing production secrets and violating SOC2 / GDPR invariants.
- **The Distributed Context Disconnect**:
  - When an orchestrator agent delegates a subtask to an ephemeral worker agent or an external Model Context Protocol (MCP) server, trace correlation breaks. Tool executions appear as orphaned spans without causality links to the originating user prompt.
- **The OpenInference Production Standard**:
  - All agentic runs must be modeled as a **Hierarchical Distributed Trace Tree** conforming to the OpenInference semantic specification:
    - Root Span: `AGENT` (representing the entire autonomous mission).
    - Child Spans: `CHAIN` (workflow stages such as Planning, Execution, Verification).
    - Leaf Spans: `LLM` (inference steps with token counts, cache hit metrics, TTFT) and `TOOL` (bash, file system, MCP, or git operations).
    - Retrieval Spans: `RETRIEVER` (code intelligence search, vector lookups, repository map queries).

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ User Intent / Issue Ticket ("Fix race condition in background worker pool")                       │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: Unstructured Terminal Logging]                                  ▼ [PRODUCTION: OpenInference Trajectory Tree]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ Raw console.log / print dumps to stdout.        │               │ Trace: [agent.run] (UUIDv7, W3C Traceparent)    │
│ No trace ID, no span hierarchy.                 │               ├─────────────────────────────────────────────────┤
├─────────────────────────────────────────────────┤               │ ├── [chain.plan] (Planning stage)               │
│ - Secret API keys leaked into plain terminal.   │               │ │   └── [llm.reasoning] (Claude 3.7 Sonnet)     │
│ - 40 turns burn $25 with zero cost alarms.      │               │ │       Attrs: tokens.prompt=3,120, cache_hit=92% │
│ - Infinite tool loop undetected until crash.    │               │ ├── [chain.execute] (Execution loop)            │
│ - Orphaned MCP subagent traces lose causality.  │               │ │   ├── [tool.bash] (git diff --stat)           │
├─────────────────────────────────────────────────┤               │ │   ├── [tool.mcp] (fetch_ast_definition)       │
│ Outcome: Post-mortem impossible; SWE-bench      │               │ │   │   Injects: W3C traceparent via MCP _meta    │
│ regression failures cannot be reproduced.       │               │ │   └── [llm.codeact] (Generating surgical patch)│
└─────────────────────────────────────────────────┘               │ └── [chain.verify] (TDD & Compiler Verification)│
                                                                  │     └── [tool.test] (go test -race ./...)       │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Real-Time Governance:                           │
                                                                  │ • Real-time cost accumulator ($1.42 / $2.00 cap) │
                                                                  │ • Automated PII & API secret redaction firewall │
                                                                  │ • Action N-gram loop detector (cosine sim < 0.92)│
                                                                  └─────────────────────────────────────────────────┘
```

---

## 2. Mathematical Formalism: Token Economics, Spend Trajectory Calculus & Anomaly Detection

### 2.1 The Multi-Tier Token Spend Equation

Every LLM inference turn $t$ within an agent trajectory incurs costs across four distinct token tiers: un-cached prompt tokens, prompt cache read tokens, prompt cache write tokens, and completion tokens. Let $P_{\text{input}}$, $P_{\text{cache\_read}}$, $P_{\text{cache\_write}}$, and $P_{\text{output}}$ represent the unit prices per token:

$$C_{\text{turn}}(t) = \left( T_{\text{prompt\_miss}}(t) \cdot P_{\text{input}} \right) + \left( T_{\text{cache\_hit}}(t) \cdot P_{\text{cache\_read}} \right) + \left( T_{\text{cache\_write}}(t) \cdot P_{\text{cache\_write}} \right) + \left( T_{\text{completion}}(t) \cdot P_{\text{output}} \right)$$

The cumulative trajectory cost $C_{\text{trajectory}}(T)$ across $T$ turns must obey the Hard Spend Ceiling $C_{\text{budget}}$:

$$C_{\text{trajectory}}(T) = \sum_{t=1}^{T} C_{\text{turn}}(t) \le C_{\text{budget}}$$

If $C_{\text{trajectory}}(t) \ge C_{\text{budget}}$, the telemetry engine must trigger an emergency non-recoverable trip (`CIRCUIT_BREAKER_TRIPPED`), halting agent execution and returning a structured partial work checkpoint.

### 2.2 Streaming Latency Decomposition

For streaming LLM interactions, total turn latency $\Delta t_{\text{turn}}$ must be decomposed into Time-to-First-Token ($\tau_{\text{TTFT}}$) and Inter-Token Latency ($\tau_{\text{ITL}}$):

$$\tau_{\text{TTFT}} = t_{\text{first\_token}} - t_{\text{request\_sent}}$$

$$\tau_{\text{ITL}} = \frac{t_{\text{stream\_end}} - t_{\text{first\_token}}}{T_{\text{completion}} - 1}$$

- **Degradation Sentinel**: If $\tau_{\text{TTFT}} > 10{,}000\text{ms}$ or $\tau_{\text{ITL}} > 150\text{ms/token}$, the span must be tagged with `anomaly.latency_degradation = true` to inform routing failover to secondary providers.

### 2.3 Semantic Reasoning Loop & Oscillation Detection

Agents occasionally enter circular reasoning loops, repeatedly issuing identical or near-identical tool arguments with cosmetic variations. The telemetry engine tracks a sliding window of the last $K = 4$ action embeddings $E_t \in \mathbb{R}^d$:

$$\sigma_{\text{consecutive}} = \frac{E_t \cdot E_{t-1}}{\|E_t\|_2 \|E_{t-1}\|_2}$$

In addition, action signatures are hashed via canonical tokenization:

$$H_t = \text{SHA256}(\text{ToolName} \mathbin{\Vert} \text{NormalizedArgs})$$

- **Loop Invariant**: If $H_t = H_{t-2}$ (reciprocal ping-pong) or if $\sigma_{\text{consecutive}} \ge 0.94$ across 3 consecutive turns without file-system mutation, the trajectory is classified as `STALLED_IN_REASONING_LOOP`. The engine trips the circuit breaker to prevent token incineration.

---

## 3. 6-State Trajectory Lifecycle Finite-State Machine (FSM)

The agent trajectory telemetry engine enforces a deterministic finite-state machine governing span lifecycles, context propagation, and spend enforcement:

```
┌────────────────────────┐
│  SESSION_INITIALIZED   │── (Create root AGENT span, initialize budget & W3C headers)
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│     STEP_REASONING     │◄──────────────────────────────────────────────────────┐
│       (LLM Span)       │                                                       │
└───────────┬────────────┘                                                       │
            │ (Action selected: tool call emitted)                               │
            ▼                                                                    │
┌────────────────────────┐                                                       │
│    PREFLIGHT_AUDIT     │                                                       │
│  (Redaction & Limits)  │                                                       │
└───────────┬────────────┘                                                       │
            │                                                                    │
    ┌───────┴────────────────────────┐                                           │
    │ Check bounds                   │                                           │
    ▼ [Exceeded Budget / Loop]       ▼ [Bounds Nominal]                          │
┌────────────────────────┐   ┌────────────────────────┐                          │
│   CIRCUIT_BREAKER_     │   │      TOOL_EXECUTE      │                          │
│        TRIPPED         │   │   (TOOL / MCP Span)    │                          │
└───────────┬────────────┘   └───────────┬────────────┘                          │
            │                            │ (Tool returns stdout / JSON)          │
            │                            ▼                                       │
            │                ┌────────────────────────┐                          │
            │                │ BUDGET_RECONCILIATION  │──────────────────────────┘
            │                │ (Accumulate $ cost)    │ (Loop until mission end)
            │                └───────────┬────────────┘
            │                            │
            │                            ▼ [Mission Succeeded]
            │                ┌────────────────────────┐
            └───────────────►│    EXPORT_TELEMETRY    │
                             │ (OTLP / Langfuse flush)│
                             └────────────────────────┘
```

| Current State | Event Trigger | Next State | Telemetry Guardrail Invariant |
| :--- | :--- | :--- | :--- |
| `SESSION_INITIALIZED` | Task dispatched by human or harness | `STEP_REASONING` | Generate root `trace_id` (UUIDv7 format). Initialize $C_{\text{trajectory}} = 0$. |
| `STEP_REASONING` | Stream first chunk, then stream end | `PREFLIGHT_AUDIT` | Record TTFT, ITL, prompt cache hit/miss tokens. Compute turn cost $\Delta C$. |
| `PREFLIGHT_AUDIT` | $C_{\text{trajectory}} + \Delta C > C_{\text{budget}}$ | `CIRCUIT_BREAKER_TRIPPED` | Halt agent immediately. Emit `agent.budget_exceeded` event with partial diff. |
| `PREFLIGHT_AUDIT` | Action hash collision or cosine loop | `CIRCUIT_BREAKER_TRIPPED` | Halt agent immediately. Emit `agent.loop_detected` event. |
| `PREFLIGHT_AUDIT` | Cost and action within limits | `TOOL_EXECUTE` | Scrub tool arguments for secrets. Inject W3C `traceparent` into child env. |
| `TOOL_EXECUTE` | Subprocess / MCP call exits | `BUDGET_RECONCILIATION` | Capture tool duration, exit code, and truncate stdout to 50KB. Scrub secrets. |
| `BUDGET_RECONCILIATION` | Goal verified by test pass | `EXPORT_TELEMETRY` | Mark root `AGENT` span `STATUS_OK`. Asynchronously flush OTLP spans. |

---

## 4. Production-Ready Engine: TypeScript `AgentTrajectoryTelemetryEngine`

Save this engine as `agent-trajectory-telemetry.ts` in your harness or agent execution runtime:

```typescript
import { randomBytes, createHash } from 'node:crypto';

// ============================================================================
// OpenInference Semantic Conventions & Types
// ============================================================================

export type OpenInferenceSpanKind = 'AGENT' | 'CHAIN' | 'LLM' | 'TOOL' | 'RETRIEVER';

export interface TokenUsage {
  promptMissTokens: number;
  promptCacheHitTokens: number;
  promptCacheWriteTokens: number;
  completionTokens: number;
}

export interface ModelPricing {
  promptMissPricePerMillion: number;
  promptCacheHitPricePerMillion: number;
  promptCacheWritePricePerMillion: number;
  completionPricePerMillion: number;
}

export interface SpanRecord {
  traceId: string;
  spanId: string;
  parentSpanId?: string;
  name: string;
  spanKind: OpenInferenceSpanKind;
  startTimeMs: number;
  endTimeMs?: number;
  attributes: Record<string, string | number | boolean | null>;
  events: Array<{ name: string; timestampMs: number; attributes?: Record<string, unknown> }>;
  status: 'UNSET' | 'OK' | 'ERROR';
  statusMessage?: string;
}

export interface TrajectoryConfig {
  taskName: string;
  budgetUsd: number;
  pricing: ModelPricing;
  maxConsecutiveIdenticalActions: number;
  exportSink?: (spans: SpanRecord[]) => Promise<void>;
}

// ============================================================================
// Sensitive Data Redaction Firewall
// ============================================================================

const SECRET_PATTERNS = [
  /(?:bearer\s+[a-zA-Z0-9_\-\.]{20,})/gi,
  /(?:sk-[a-zA-Z0-9]{20,})/gi,
  /(?:ghp_[a-zA-Z0-9]{36})/gi,
  /(?:AKIA[0-9A-Z]{16})/gi,
  /(?:xox[baprs]-[0-9a-zA-Z]{10,48})/gi,
  /(?:password|secret|token|api_key)\s*[:=]\s*["']?([^"'\s]+)["']?/gi,
];

export function redactSensitiveData(payload: string): string {
  let sanitized = payload;
  for (const pattern of SECRET_PATTERNS) {
    sanitized = sanitized.replace(pattern, (match) => {
      if (match.toLowerCase().startsWith('bearer ')) {
        return 'Bearer [REDACTED_SECRET]';
      }
      return '[REDACTED_SECRET]';
    });
  }
  return sanitized;
}

// ============================================================================
// Trajectory Telemetry & Cost Engine
// ============================================================================

export class AgentTrajectoryTelemetryEngine {
  private readonly traceId: string;
  private readonly rootSpanId: string;
  private readonly spans: Map<string, SpanRecord> = new Map();
  private readonly actionHashHistory: string[] = [];
  private accumulatedCostUsd = 0;
  private circuitBreakerTripped = false;

  constructor(private readonly config: TrajectoryConfig) {
    this.traceId = randomBytes(16).toString('hex');
    this.rootSpanId = randomBytes(8).toString('hex');

    // Initialize Root AGENT Span
    const rootSpan: SpanRecord = {
      traceId: this.traceId,
      spanId: this.rootSpanId,
      name: `agent.${config.taskName}`,
      spanKind: 'AGENT',
      startTimeMs: Date.now(),
      attributes: {
        'openinference.span.kind': 'AGENT',
        'agent.task_name': config.taskName,
        'agent.budget_usd': config.budgetUsd,
      },
      events: [],
      status: 'UNSET',
    };
    this.spans.set(this.rootSpanId, rootSpan);
  }

  public getTraceId(): string {
    return this.traceId;
  }

  public getW3CTraceparent(currentSpanId: string): string {
    return `00-${this.traceId}-${currentSpanId}-01`;
  }

  public getAccumulatedCost(): number {
    return this.accumulatedCostUsd;
  }

  public isCircuitBreakerTripped(): boolean {
    return this.circuitBreakerTripped;
  }

  // --------------------------------------------------------------------------
  // LLM Reasoning Span Tracking & Token Economics
  // --------------------------------------------------------------------------

  public startLLMSpan(modelName: string, promptPreview: string, parentSpanId?: string): string {
    if (this.circuitBreakerTripped) {
      throw new Error(`Circuit breaker tripped: Budget ceiling ($${this.config.budgetUsd}) reached.`);
    }

    const spanId = randomBytes(8).toString('hex');
    const span: SpanRecord = {
      traceId: this.traceId,
      spanId,
      parentSpanId: parentSpanId || this.rootSpanId,
      name: `llm.${modelName}`,
      spanKind: 'LLM',
      startTimeMs: Date.now(),
      attributes: {
        'openinference.span.kind': 'LLM',
        'llm.model_name': modelName,
        'llm.prompt_preview': redactSensitiveData(promptPreview.slice(0, 500)),
      },
      events: [],
      status: 'UNSET',
    };

    this.spans.set(spanId, span);
    return spanId;
  }

  public recordFirstToken(spanId: string): void {
    const span = this.spans.get(spanId);
    if (!span) return;
    const ttftMs = Date.now() - span.startTimeMs;
    span.attributes['llm.latency.ttft_ms'] = ttftMs;
    span.events.push({ name: 'first_token_received', timestampMs: Date.now() });
  }

  public endLLMSpan(
    spanId: string,
    usage: TokenUsage,
    completionPreview: string,
    error?: Error
  ): void {
    const span = this.spans.get(spanId);
    if (!span) return;

    span.endTimeMs = Date.now();
    const durationMs = span.endTimeMs - span.startTimeMs;

    // Calculate Turn Cost
    const p = this.config.pricing;
    const turnCostUsd =
      (usage.promptMissTokens * p.promptMissPricePerMillion) / 1_000_000 +
      (usage.promptCacheHitTokens * p.promptCacheHitPricePerMillion) / 1_000_000 +
      (usage.promptCacheWriteTokens * p.promptCacheWritePricePerMillion) / 1_000_000 +
      (usage.completionTokens * p.completionPricePerMillion) / 1_000_000;

    this.accumulatedCostUsd += turnCostUsd;

    // Attach OpenInference Attributes
    span.attributes['llm.token_count.prompt'] = usage.promptMissTokens + usage.promptCacheHitTokens;
    span.attributes['llm.token_count.prompt_cache_hit'] = usage.promptCacheHitTokens;
    span.attributes['llm.token_count.prompt_cache_write'] = usage.promptCacheWriteTokens;
    span.attributes['llm.token_count.completion'] = usage.completionTokens;
    span.attributes['llm.token_count.total'] =
      usage.promptMissTokens + usage.promptCacheHitTokens + usage.completionTokens;
    span.attributes['llm.cost_usd'] = Number(turnCostUsd.toFixed(6));
    span.attributes['agent.cumulative_cost_usd'] = Number(this.accumulatedCostUsd.toFixed(6));
    span.attributes['llm.completion_preview'] = redactSensitiveData(completionPreview.slice(0, 500));

    // Calculate Inter-Token Latency (ITL)
    const ttftMs = (span.attributes['llm.latency.ttft_ms'] as number) || 0;
    if (usage.completionTokens > 1 && durationMs > ttftMs) {
      span.attributes['llm.latency.itl_ms'] = Number(
        ((durationMs - ttftMs) / (usage.completionTokens - 1)).toFixed(2)
      );
    }

    if (error) {
      span.status = 'ERROR';
      span.statusMessage = error.message;
    } else {
      span.status = 'OK';
    }

    // Spend Ceiling Guardrail
    if (this.accumulatedCostUsd >= this.config.budgetUsd) {
      this.circuitBreakerTripped = true;
      span.events.push({
        name: 'budget_exceeded_abort',
        timestampMs: Date.now(),
        attributes: { accumulatedCost: this.accumulatedCostUsd, budget: this.config.budgetUsd },
      });
    }
  }

  // --------------------------------------------------------------------------
  // Tool & MCP Span Tracking with Loop Detection & Redaction
  // --------------------------------------------------------------------------

  public startToolSpan(
    toolName: string,
    rawParameters: Record<string, unknown>,
    parentSpanId?: string
  ): { spanId: string; sanitizedParams: Record<string, unknown> } {
    if (this.circuitBreakerTripped) {
      throw new Error(`Circuit breaker active: Cannot execute tool '${toolName}'. Budget exhausted.`);
    }

    // 1. Redact parameters before attaching to trace attributes
    const serializedParams = JSON.stringify(rawParameters);
    const sanitizedSerialized = redactSensitiveData(serializedParams);
    const sanitizedParams = JSON.parse(sanitizedSerialized) as Record<string, unknown>;

    // 2. Anomaly Sentinel: N-gram Action Loop Detection
    const actionFingerprint = createHash('sha256')
      .update(`${toolName}:${sanitizedSerialized}`)
      .digest('hex');

    this.actionHashHistory.push(actionFingerprint);
    const historyLen = this.actionHashHistory.length;
    if (historyLen >= this.config.maxConsecutiveIdenticalActions) {
      const recent = this.actionHashHistory.slice(-this.config.maxConsecutiveIdenticalActions);
      const isIdentical = recent.every((hash) => hash === actionFingerprint);
      if (isIdentical) {
        this.circuitBreakerTripped = true;
        throw new Error(
          `Circuit breaker tripped: Detected infinite execution loop. Tool '${toolName}' invoked ` +
          `${this.config.maxConsecutiveIdenticalActions} times with identical parameters.`
        );
      }
    }

    const spanId = randomBytes(8).toString('hex');
    const span: SpanRecord = {
      traceId: this.traceId,
      spanId,
      parentSpanId: parentSpanId || this.rootSpanId,
      name: `tool.${toolName}`,
      spanKind: 'TOOL',
      startTimeMs: Date.now(),
      attributes: {
        'openinference.span.kind': 'TOOL',
        'tool.name': toolName,
        'tool.parameters': sanitizedSerialized.slice(0, 1000),
      },
      events: [],
      status: 'UNSET',
    };

    this.spans.set(spanId, span);
    return { spanId, sanitizedParams };
  }

  public endToolSpan(spanId: string, output: string, exitCode = 0, error?: Error): void {
    const span = this.spans.get(spanId);
    if (!span) return;

    span.endTimeMs = Date.now();
    span.attributes['tool.exit_code'] = exitCode;

    // Hard 50KB truncation and redaction for tool output telemetry
    const truncatedOutput = output.length > 50_000 ? output.slice(0, 50_000) + '...[TRUNCATED]' : output;
    span.attributes['tool.output'] = redactSensitiveData(truncatedOutput);

    if (error || exitCode !== 0) {
      span.status = 'ERROR';
      span.statusMessage = error ? error.message : `Tool failed with exit code ${exitCode}`;
    } else {
      span.status = 'OK';
    }
  }

  // --------------------------------------------------------------------------
  // Trajectory Finalization & Export
  // --------------------------------------------------------------------------

  public async completeTrajectory(success: boolean, summaryMessage: string): Promise<SpanRecord[]> {
    const rootSpan = this.spans.get(this.rootSpanId);
    if (rootSpan) {
      rootSpan.endTimeMs = Date.now();
      rootSpan.status = success ? 'OK' : 'ERROR';
      rootSpan.statusMessage = summaryMessage;
      rootSpan.attributes['agent.total_cost_usd'] = Number(this.accumulatedCostUsd.toFixed(6));
      rootSpan.attributes['agent.total_spans'] = this.spans.size;
    }

    const spanList = Array.from(this.spans.values());

    if (this.config.exportSink) {
      await this.config.exportSink(spanList).catch((err) => {
        console.error('Failed to export OpenInference trajectory spans:', err);
      });
    }

    return spanList;
  }
}
```

---

## 5. Concrete Code Examples: Anti-Patterns vs Production Invariants

### Anti-Pattern 1: Unstructured Console Dumps & Silent Agent Divergence

```typescript
// ❌ ANTI-PATTERN: Raw unformatted stdout logging without spans or causality
async function runAgentStep(step: number, prompt: string) {
  console.log(`Step ${step}: Sending prompt to model...`);
  const response = await llmClient.complete(prompt);
  console.log(`Model responded: ${response.text}`);

  if (response.toolCall) {
    console.log(`Calling tool: ${response.toolCall.name}`);
    const result = await executeTool(response.toolCall.name, response.toolCall.args);
    console.log(`Tool result: ${result}`);
  }
}
// Flaws:
// 1. Zero distributed trace ID; impossible to correlate with webhooks, CI, or user sessions.
// 2. No token accounting or cache hit tracking.
// 3. If executeTool fails or hangs, no structured error span is generated.
```

### Production Invariant 1: Typed OpenInference Hierarchical Spans

```typescript
// ✅ PRODUCTION INVARIANT: Hierarchical distributed spans with OpenInference conventions
async function runAgentStepInstrumented(
  telemetry: AgentTrajectoryTelemetryEngine,
  parentSpanId: string,
  modelName: string,
  prompt: string
) {
  const llmSpanId = telemetry.startLLMSpan(modelName, prompt, parentSpanId);

  try {
    const stream = await llmClient.streamComplete(prompt);
    let isFirst = true;
    let fullText = '';

    for await (const chunk of stream) {
      if (isFirst) {
        telemetry.recordFirstToken(llmSpanId);
        isFirst = false;
      }
      fullText += chunk.text;
    }

    telemetry.endLLMSpan(
      llmSpanId,
      {
        promptMissTokens: stream.usage.promptTokens - stream.usage.cacheReadTokens,
        promptCacheHitTokens: stream.usage.cacheReadTokens,
        promptCacheWriteTokens: stream.usage.cacheWriteTokens,
        completionTokens: stream.usage.completionTokens,
      },
      fullText
    );

    return fullText;
  } catch (err) {
    telemetry.endLLMSpan(
      llmSpanId,
      { promptMissTokens: 0, promptCacheHitTokens: 0, promptCacheWriteTokens: 0, completionTokens: 0 },
      '',
      err as Error
    );
    throw err;
  }
}
```

---

### Anti-Pattern 2: APM Credential Poisoning & Plaintext Secret Export

```typescript
// ❌ ANTI-PATTERN: Blindly attaching environment variables and database URLs to spans
async function executeDatabaseMigration(dbUrl: string, sql: string) {
  const span = tracer.startSpan('tool.db_migrate');
  // LEAKS credentials (postgres://admin:super_secret_pwd@prod.internal:5432) to APM!
  span.setAttribute('db.connection_string', dbUrl);
  span.setAttribute('db.statement', sql);
  await db.query(sql);
  span.end();
}
```

### Production Invariant 2: Automated Secret Redaction & Sanitized Spans

```typescript
// ✅ PRODUCTION INVARIANT: In-flight regex redaction before span registration
async function executeDatabaseMigrationInstrumented(
  telemetry: AgentTrajectoryTelemetryEngine,
  dbUrl: string,
  sql: string
) {
  // telemetry.startToolSpan automatically scans and masks passwords, bearer tokens, and keys
  const { spanId, sanitizedParams } = telemetry.startToolSpan('db_migrate', {
    connectionString: dbUrl,
    statement: sql,
  });

  try {
    const result = await db.query(sql);
    telemetry.endToolSpan(spanId, JSON.stringify(result), 0);
  } catch (err) {
    telemetry.endToolSpan(spanId, '', 1, err as Error);
    throw err;
  }
}
```

---

### Anti-Pattern 3: Disjoint Subagent Spans Losing Causality

```typescript
// ❌ ANTI-PATTERN: Invoking child MCP server or subagent with empty context
async function delegateToSubagent(task: string) {
  // Spawns independent process without passing trace context
  const res = await fetch('http://mcp-server:8080/execute', {
    method: 'POST',
    body: JSON.stringify({ task }),
  });
  return res.json();
}
// Flaws: The MCP server generates a brand new root trace. Causality is severed.
```

### Production Invariant 3: W3C TraceContext Propagation Across MCP & Subagents

```typescript
// ✅ PRODUCTION INVARIANT: Injecting W3C Traceparent into MCP _meta and child envs
async function delegateToSubagentInstrumented(
  telemetry: AgentTrajectoryTelemetryEngine,
  parentSpanId: string,
  task: string
) {
  const { spanId } = telemetry.startToolSpan('mcp.subagent_delegate', { task }, parentSpanId);
  const traceparent = telemetry.getW3CTraceparent(spanId);

  try {
    const res = await fetch('http://mcp-server:8080/execute', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        traceparent: traceparent, // W3C distributed trace context
      },
      body: JSON.stringify({
        task,
        _meta: { traceparent }, // Model Context Protocol metadata encapsulation
      }),
    });

    const body = await res.text();
    telemetry.endToolSpan(spanId, body, res.ok ? 0 : 1);
    return body;
  } catch (err) {
    telemetry.endToolSpan(spanId, '', 1, err as Error);
    throw err;
  }
}
```

---

## 6. 6-Gate Machine-Verifiable Definition of Done (DoD) Matrix

Before declaring any agent telemetry or observability integration complete, the harness must satisfy all six automated verification gates:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               6-GATE MACHINE-VERIFIABLE TELEMETRY DEFINITION OF DONE                   │
├───────────────┬───────────────────────────────────┬────────────────────────────────────┤
│ GATE          │ VERIFICATION TARGET               │ ENFORCEMENT COMMAND / ASSERTION    │
├───────────────┼───────────────────────────────────┼────────────────────────────────────┤
│ 1. Schema     │ OpenInference Span Compliance     │ span.attributes['openinference.    │
│               │ (AGENT, LLM, TOOL, RETRIEVER)     │ span.kind'] in allowed kinds       │
├───────────────┼───────────────────────────────────┼────────────────────────────────────┤
│ 2. Context    │ W3C TraceContext Distributed Flow │ Child spans match root traceId;    │
│               │                                   │ traceparent header transmitted     │
├───────────────┼───────────────────────────────────┼────────────────────────────────────┤
│ 3. Redaction  │ Zero Plaintext Secrets in APM     │ Regex audit on exported spans;     │
│               │                                   │ Bearer tokens & sk-* masked        │
├───────────────┼───────────────────────────────────┼────────────────────────────────────┤
│ 4. Economics  │ Bit-for-Bit Token & Spend Calc    │ promptCacheHit + miss + completion │
│               │                                   │ equals provider billing usage      │
├───────────────┼───────────────────────────────────┼────────────────────────────────────┤
│ 5. Sentinels  │ Loop & Budget Circuit Breakers    │ Test verifies hard abort if spend  │
│               │                                   │ >= budget or identical tool loop   │
├───────────────┼───────────────────────────────────┼────────────────────────────────────┤
│ 6. Overhead   │ Telemetry Overhead Discipline     │ Non-blocking async queue;          │
│               │                                   │ Telemetry latency impact < 1.0%    │
└───────────────┴───────────────────────────────────┴────────────────────────────────────┘
```

1. **Gate 1 (OpenInference Conformance)**: Every span emitted into the collector contains an explicit `openinference.span.kind` matching `AGENT`, `LLM`, `TOOL`, `CHAIN`, or `RETRIEVER`. Root spans are always `AGENT`.
2. **Gate 2 (W3C Distributed Trace Propagation)**: Subagents, MCP calls, and background child workers inherit the root `trace_id` and pass standard `traceparent: 00-{trace_id}-{span_id}-01` headers.
3. **Gate 3 (Zero Secret Leakage Firewall)**: Telemetry exporters run automated regex scanners against all serialized attributes (`tool.parameters`, `tool.output`, `llm.prompt_preview`). Any span containing unmasked credentials triggers an immediate CI test failure.
4. **Gate 4 (Token Spend Calculus)**: Telemetry captures cache read, cache write, and uncached tokens accurately. Accumulated USD cost updates monotonically and matches provider tier formulas.
5. **Gate 5 (Loop & Runaway Circuit Breaker Test)**: An automated mock test verifies that when an agent invokes the same tool 4 times with identical parameters, or when cumulative cost hits `budgetUsd`, the harness immediately aborts with `CIRCUIT_BREAKER_TRIPPED`.
6. **Gate 6 (Non-Blocking Zero-Overhead Execution)**: Telemetry exports run in detached asynchronous background workers with unbounded queues rejected and bounded buffering ($<1{,}000$ spans in memory). In-flight agent latency must not be degraded by more than $1.0\%$.
