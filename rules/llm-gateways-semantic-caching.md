---
description: LLM gateway architecture, semantic vector caching, deterministic exact-match hashing, SSE streaming passthrough, multi-provider fallback cascades, token-aware dual-tier rate limiting, model routing, and cost optimization
globs: **/*{gateway,proxy,llm_router,semantic_cache,litellm,portkey,openrouter,ai_gateway,model_provider}*.*,**/gateway/**,**/routers/**,**/cache/semantic/**,**/proxy/**
alwaysApply: false
---

# LLM Gateways, Semantic Caching & Multi-Provider Resilience

> Add these rules to your project when building or operating production AI gateways, LLM reverse proxies, semantic vector caches, multi-provider model routers, and token rate limiters (LiteLLM, Portkey, Cloudflare AI Gateway, Langfuse, Helicone, vLLM proxy, custom Envoy/Go/Node gateways).

---

## 1. The Gateway Mission & Architecture Boundary

A production LLM Gateway is the mission-critical ingress controller between application workloads and external/self-hosted AI model providers (Anthropic Claude, OpenAI, Google Gemini, DeepSeek, Mistral, AWS Bedrock, Azure OpenAI, Groq, vLLM, Ollama).

```
[Client / Agent / SDK]
         │ (OpenAI-Compatible JSON or SSE Stream)
         ▼
┌─────────────────────────────────────────────────────────────┐
│                      LLM AI GATEWAY                         │
│  1. Tenant Auth, Spend Budget & Dual RPM/TPM Rate Limiting  │
│  2. Deterministic Exact Cache (SHA-256 Canonical JSON)      │
│  3. Semantic Vector Cache (Cosine Similarity ≥ 0.95-0.98)   │
│  4. Prompt Complexity Router & PII Sanitization             │
│  5. Fallback Waterfall Cascade & Circuit Breakers           │
│  6. Zero-Buffering SSE Stream Proxying & Async "Tee" Tap    │
└────────┬───────────────────┬───────────────────┬────────────┘
         │                   │                   │
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ Anthropic Claude│ │  OpenAI GPT-4o  │ │ Self-Hosted vLLM│
│  (Primary Tier) │ │ (Fallback Tier) │ │  (DeepSeek-V3)  │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

- **Core Production Directives**:
  - **Standardized Wire Format**: Enforce OpenAI-compatible wire formats (`/v1/chat/completions`, `/v1/embeddings`, `/v1/models`) across all backends. Normalize vendor-specific idiosyncrasies (e.g. Anthropic `tool_use`/`tool_result` vs OpenAI `tool_calls` vs Gemini `functionCall`) inside the gateway layer so applications remain completely vendor-agnostic.
  - **Zero Vendor Lock-In**: Client applications MUST NEVER directly invoke vendor-specific SDK endpoints (e.g. `api.anthropic.com` or `api.openai.com`) in business logic. All traffic must pass through the gateway endpoint.
  - **Strict Multi-Tenant Isolation**: Tenant budgets, rate limits, PII boundaries, and cache namespaces MUST be strictly isolated by `tenant_id` / `org_id`.

---

## 2. Two-Tier Caching: Deterministic Exact-Match vs Vector Semantic Caching

Uncached LLM requests lead to catastrophic latency spikes (1,500ms–8,000ms) and explosive API bills. A resilient gateway operates a coordinated two-tier caching architecture:

```
Incoming Request
      │
      ▼
┌───────────────────────────────┐
│ Tier 1: Canonical Exact Hash  │ ── Hit (< 2ms) ──► Return Cached Payload
└──────────────┬────────────────┘
               │ Miss
               ▼
┌───────────────────────────────┐
│ Tier 2: Semantic Vector Cache │ ── Hit (< 25ms, Cosine ≥ Threshold) ──► Return Cached
└──────────────┬────────────────┘
               │ Miss
               ▼
   Dispatch Upstream to LLM Provider
```

### Tier 1: Deterministic Exact-Match Hashing
- **The Non-Deterministic Serialization Trap**:
  - ❌ **Anti-Pattern**: Hashing raw JSON request strings directly (`sha256(raw_body)`). Variations in whitespace, JSON key ordering, or HTTP client header ordering cause false cache misses on identical semantic prompts.
- ✅ **Production Invariant**: Canonicalize the payload before computing the hash:
  1. Extract only cache-relevant properties: `model`, `messages` (role and content), `tools` (normalized schemas), `tool_choice`, `temperature`, `top_p`, and `seed`.
  2. Strip non-semantic metadata: `request_id`, dynamic timestamps, `user` tags, HTTP headers.
  3. Sort all JSON object keys recursively in lexicographical order.
  4. Normalize Unicode strings using `NFKC` and trim leading/trailing whitespace.
  5. Salt the key with `tenant_id` and the model version tag (e.g., `v1:org_123:claude-3-5-sonnet-20241022:<sha256>`).

### Tier 2: Semantic Similarity Caching (Vector Similarity)
Semantic caching matches incoming prompts that are syntactically distinct but semantically identical (e.g. *"What is the capital of France?"* vs *"Tell me France's capital city"*).

- **Similarity Threshold Invariants**:
  - Compute Cosine Similarity between the normalized prompt embedding vector $\vec{q}$ and cached prompt vectors $\vec{c}_i$:
    $$\text{Cosine}(\vec{q}, \vec{c}_i) = \frac{\vec{q} \cdot \vec{c}_i}{\|\vec{q}\| \|\vec{c}_i\|}$$
  - **Standard Informational Queries**: Require $\text{Cosine} \ge 0.95$.
  - **High-Precision Queries (Code, Math, Financial Ledger, SQL)**: Require $\text{Cosine} \ge 0.985$ or disable semantic caching entirely (`cache_control: "no-semantic"`). Hits below $0.95$ produce subtle, dangerous hallucinations where queries like *"How do I delete a user?"* match cached answers for *"How do I create a user?"*.
- ❌ **The Cross-Tenant Semantic Cache Leak**:
  - Never allow Tenant B to match or read cached prompt/completion entries generated by Tenant A. Even if two prompts are semantically identical, Tenant A's cached completion may contain proprietary business context, customer PII, or internal database schemas.
  - **Production Invariant**: Vector search queries MUST enforce a strict metadata filter: `WHERE tenant_id = :current_tenant_id`.
- **Dynamic Masking Before Embedding**:
  - Before generating query embeddings, mask ephemeral variables such as current dates/times, transaction UUIDs, and user names with standard tokens (`[DATE]`, `[UUID]`, `[USER]`). This maximizes cache hit rates while preventing semantic distortion.
- **Model-Version Drift Invalidation**:
  - When upstream model weights are updated (e.g., from `claude-3-5-sonnet-20240620` to `claude-3-5-sonnet-20241022`), the semantic cache namespace MUST be bumped immediately. An answer generated by an older model must never be returned under a newer model's version identifier.

---

## 3. Server-Sent Events (SSE) Streaming Passthrough & Zero-Buffering

Streaming completions via SSE (`text/event-stream`) is essential for human-perceived responsiveness (TTFT < 400ms). Buffering tokens in the gateway destroys the user experience.

- ❌ **The Synchronous Buffering Gateway Anti-Pattern**:
  - Accumulating the entire completion in gateway memory before sending it to the client in order to calculate tokens, verify guardrails, or store in cache. This turns a 300ms Time-to-First-Token into a 6,000ms blocking wait.
- ✅ **The Zero-Buffering Async "Tee" Architecture**:
  - Immediately flush every SSE chunk to the downstream client as soon as it arrives from the upstream provider (`flush()` / `WriteFlusher`).
  - Asynchronously tee (fan-out) the token chunks into a background buffer worker. When the stream concludes (`[DONE]`), the background worker calculates token usage, updates audit telemetry (Langfuse/Helicone/OpenTelemetry), and populates the exact/semantic caches without adding a single millisecond to the user's interactive stream.

```go
// Production Go Gateway SSE Transparent Reverse Proxy with Async Tee Tap
func (gw *LLMGateway) StreamChatCompletion(w http.ResponseWriter, r *http.Request, upstreamResp *http.Response) {
    flusher, ok := w.(http.Flusher)
    if !ok {
        http.Error(w, "Streaming unsupported", http.StatusInternalServerError)
        return
    }

    // Preserve exact SSE streaming headers
    w.Header().Set("Content-Type", "text/event-stream")
    w.Header().Set("Cache-Control", "no-cache")
    w.Header().Set("Connection", "keep-alive")
    w.Header().Set("X-Accel-Buffering", "no") // Disable Nginx proxy buffering
    w.WriteHeader(http.StatusOK)
    flusher.Flush()

    var accumulated strings.Builder
    reader := bufio.NewReader(upstreamResp.Body)
    defer upstreamResp.Body.Close()

    for {
        // Detect client disconnect; immediately cancel upstream context to stop LLM billing
        select {
        case <-r.Context().Done():
            gw.logger.WarnContext(r.Context(), "Client aborted SSE stream; canceling upstream generation")
            return
        default:
        }

        line, err := reader.ReadBytes('\n')
        if len(line) > 0 {
            // Forward chunk to downstream client instantly
            w.Write(line)
            flusher.Flush()

            // Asynchronously record payload in background accumulator
            if bytes.HasPrefix(line, []byte("data: ")) && !bytes.Contains(line, []byte("[DONE]")) {
                accumulated.Write(line[6:])
            }
        }
        if err != nil {
            if err == io.EOF {
                break
            }
            gw.logger.Error("Upstream stream read failure", "err", err)
            break
        }
    }

    // Trigger non-blocking async cache write and telemetry emission
    go gw.asyncPostStreamProcessing(context.WithoutCancel(r.Context()), accumulated.String())
}
```

- **Client Disconnect Upstream Cancellation Invariant**:
  - If a user closes the browser tab or client cancels the HTTP connection, the gateway MUST propagate the cancellation signal to the upstream provider context immediately. Continuing to generate tokens for disconnected clients silently wastes hundreds of dollars in unread tokens.

---

## 4. Multi-Provider Fallback Cascades & Circuit Breakers

Upstream LLM APIs suffer frequent degraded performance, 529 Overloaded errors, 429 rate limit thrashes, and cloud datacenter outages. A resilient gateway implements automated waterfall fallback cascades.

```
Request (Target: Claude 3.5 Sonnet)
      │
      ▼
[Primary: Anthropic API]
      │
      ├─ 200 OK ──────────────────────────────► Return Response
      │
      ├─ 429 (Rate Limit) / 529 (Overloaded)
      │
      ▼
[Secondary: AWS Bedrock Claude 3.5]
      │
      ├─ 200 OK ──────────────────────────────► Return Response
      │
      ├─ 503 / Timeout (> 4.5s TTFT)
      │
      ▼
[Tertiary: OpenAI GPT-4o]
      │
      ├─ 200 OK ──────────────────────────────► Return Response
      │
      ▼
[Local / Self-Hosted: DeepSeek-V3 on vLLM]
```

### Strict HTTP Error Classification Invariants
- **NEVER Fallback or Retry on Client 4xx Errors (except 429)**:
  - ❌ **Anti-Pattern**: Retrying on HTTP `400 Bad Request`, `401 Unauthorized`, `403 Forbidden`, or `422 Unprocessable Entity`.
  - A `400 Invalid Schema` or `Context length exceeded` error will fail identically across all providers or corrupt tool calls. Retrying client bugs burns provider rate limits and masks integration bugs. Return the 4xx error directly to the caller immediately.
- **Fail Fast on Provider Outages (500, 502, 503, 529)**:
  - Do not exhaust retries on the same provider when receiving `503 Service Unavailable` or `529 Overloaded`. Immediately step down to the next provider in the fallback waterfall cascade.
- **Exponential Backoff with Full Jitter for 429 (Rate Limits)**:
  - When encountering 429s, check for `Retry-After` header. If absent, apply exponential backoff with full jitter:
    $$T_{\text{sleep}} = \text{random}(0, \min(T_{\text{max}}, T_{\text{base}} \times 2^{\text{attempt}}))$$
  - If retry delay exceeds the configured client timeout ceiling (e.g. 2,000ms), trip to the fallback provider immediately.

### Circuit Breakers Per Provider Endpoint
- Track failure rate per model endpoint over a sliding window (e.g. 60 seconds):
  - **State CLOSED**: Normal operations.
  - **State OPEN**: If error rate $> 30\%$ over 50+ requests, open the circuit breaker for 30 seconds. All traffic for that model is instantly routed to fallback without touching the degraded provider.
  - **State HALF-OPEN**: After 30 seconds, dispatch a 2% canary sample of live requests to the primary provider. If all succeed, reset to CLOSED; if any fail, restore OPEN state for 60 seconds.

---

## 5. Token-Aware Dual-Tier Rate Limiting (RPM & TPM)

Traditional HTTP rate limiters track only Requests Per Minute (RPM). In LLM systems, an RPM limiter is dangerously inadequate: **a single request can consume 100 tokens or 128,000 tokens**. A single tenant sending large batches of 100k-token prompts will exhaust provider Token Per Minute (TPM) quotas, triggering organization-wide outages for all users.

- **Dual-Tier Rate Limiting Invariant**:
  - The gateway MUST enforce dual-dimensional leaky bucket or token bucket limits per tenant:
    1. **RPM Ceiling**: Maximum allowed HTTP requests per minute.
    2. **TPM Ceiling**: Maximum allowed total tokens (prompt + completion) per minute.
    3. **Concurrency Ceiling**: Maximum concurrent in-flight HTTP connections per tenant.

### Atomically Coordinated Pre-Reservation & Post-Reconciliation
Because upstream token counts are unknown until generation completes, the gateway must execute a two-step reservation cycle using Redis Lua:

1. **Step 1: Upfront Conservative Reservation**:
   - Estimate prompt tokens heuristically (e.g. `len(text) / 4` or fast tokenizer).
   - Add default completion token budget (e.g. `max_tokens` or 1,024).
   - Atomically check and decrement both RPM and TPM buckets in Redis via Lua. If insufficient, return `429 Too Many Requests` with `X-RateLimit-Reset-Tokens`.
2. **Step 2: Post-Execution Reconciliation**:
   - Extract actual `usage.prompt_tokens` and `usage.completion_tokens` from upstream response headers or payload.
   - Adjust the reserved token balance in Redis (refund over-reserved tokens or record debit difference).

```lua
-- Redis Lua Script: Atomic Dual-Tier Token & Request Bucket Check
-- KEYS[1]: rpm_key, KEYS[2]: tpm_key
-- ARGV[1]: current_timestamp, ARGV[2]: max_rpm, ARGV[3]: max_tpm, ARGV[4]: estimated_tokens

local current_time = tonumber(ARGV[1])
local max_rpm = tonumber(ARGV[2])
local max_tpm = tonumber(ARGV[3])
local est_tokens = tonumber(ARGV[4])

-- Check RPM
local req_count = redis.call("GET", KEYS[1])
if req_count and tonumber(req_count) >= max_rpm then
    return {0, "RPM_EXCEEDED"}
end

-- Check TPM
local token_count = redis.call("GET", KEYS[2])
if token_count and (tonumber(token_count) + est_tokens) > max_tpm then
    return {0, "TPM_EXCEEDED"}
end

-- Atomically increment both buckets with 60s expiration
local new_rpm = redis.call("INCR", KEYS[1])
if new_rpm == 1 then redis.call("EXPIRE", KEYS[1], 60) end

local new_tpm = redis.call("INCRBY", KEYS[2], est_tokens)
if tonumber(new_tpm) == est_tokens then redis.call("EXPIRE", KEYS[2], 60) end

return {1, "ALLOWED"}
```

---

## 6. Prompt Complexity Routing & Cost Optimization

Frontier reasoning models (o1, Claude 3.7 Sonnet thinking, DeepSeek-R1) cost 15x–50x more than lightweight distilled models (Claude 3.5 Haiku, GPT-4o-mini, Llama 3.3 70B). Routing all traffic indiscriminately to flagship models wastes 70–80% of enterprise AI budgets.

- **Automated Complexity Classification**:
  - Deploy a fast, low-latency classifier (or lightweight model with strict temperature 0.0) at the gateway edge to inspect prompt intent:
    - **Tier A (Basic / Extraction / Classification)**: Simple fact retrieval, sentiment, schema formatting, translation $\to$ route to **Claude 3.5 Haiku / GPT-4o-mini** (Cost: $\sim \$0.15-\$0.25 / \text{M tokens}$).
    - **Tier B (Complex Coding / Synthesizing / Long Context)**: Multi-file refactoring, database query generation, architecture analysis $\to$ route to **Claude 3.5 Sonnet / GPT-4o** (Cost: $\sim \$3.00 / \text{M tokens}$).
    - **Tier C (Deep Mathematical / Formal Proof / Algorithmic Reasoning)**: Complex symbolic math, formal verification $\to$ route to **Reasoning Models (o1 / DeepSeek-R1)**.
- **Budget Hard-Caps & Soft-Degradation**:
  - Maintain real-time spend accumulators per tenant.
  - When a tenant reaches 80% of monthly budget: emit telemetry alert to client headers (`X-Spend-Warning: 80%`).
  - When reaching 100% of budget: instead of crashing applications with 403, gracefully downgrade complex routes to free/cheap tier models (`gpt-4o-mini` or self-hosted vLLM) with explicit header tagging (`X-Model-Downgraded: true`).

---

## 7. Edge PII Redaction & Secret Sanitization

Before dispatching prompts to external third-party model providers, the gateway enforces real-time PII and secret sanitization to preserve compliance (GDPR, HIPAA, SOC 2).

- **Bi-Directional Reversible Tokenization**:
  - ❌ **Anti-Pattern**: Irreversibly masking PII with `[REDACTED]`. The LLM cannot reference the specific entity in context, producing broken responses or incorrect reasoning.
  - ✅ **Production Invariant**: Use reversible surrogate tokenization:
    ```
    Original Prompt:  "Send invoice for patient Alice Johnson (SSN: 000-12-3456) to alice@example.com"
                             │
                             ▼ Gateway Tokenizer (Store map in Redis TTL 10m)
    Sanitized Prompt: "Send invoice for patient [NAME_1] (SSN: [SSN_1]) to [EMAIL_1]"
                             │
                             ▼ LLM Provider Processes & Responds
    LLM Response:     "Invoice prepared for [NAME_1] and sent to [EMAIL_1]."
                             │
                             ▼ Gateway De-Tokenizer (Restores original values)
    Delivered Output: "Invoice prepared for Alice Johnson and sent to alice@example.com."
    ```
- **Strict Prohibition of Raw Secret Transmission**:
  - High-entropy API keys (e.g. AWS `AKIA...`, GitHub `ghp_...`, OpenAI `sk-...`, private SSH keys) MUST be unconditionally scrubbed and blocked at the gateway edge before hitting external model providers. Log an audit violation immediately.
