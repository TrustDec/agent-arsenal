---
description: Prompt caching architecture, KV cache optimization, deterministic prefix preservation, Anthropic 4-breakpoint strategy, OpenAI prefix caching, vLLM RadixAttention, context window management, and progressive compaction
globs: **/*{prompt,context,cache,agent,llm,anthropic,openai,vllm}*.*,**/prompts/**,**/agents/**,**/context/**,**/cache/**,**/{CLAUDE,AGENTS}.md
alwaysApply: false
---

# Prompt Caching, KV Cache Optimization & Agent Context Window Management

> Add these rules to your project when building or operating long-context AI agents, multi-turn coding assistants, tool-calling harnesses, or high-throughput LLM pipelines (Claude Code, Cursor, Pi, OpenAI API, Anthropic API, vLLM, DeepSeek).

---

## 1. The KV Cache Physical Layer & Economic Realities

In modern Transformer architectures (Claude 3.5/3.7, GPT-4o, DeepSeek-V3, Llama 3), autoregressive inference runs in two phases:
1. **Prefill Phase**: Computes Key-Value (KV) tensors for all input prompt tokens in parallel ($O(N^2)$ attention compute).
2. **Decode Phase**: Generates tokens sequentially one-by-one ($O(1)$ compute per step, but memory-bandwidth bound).

During decoding, KV tensors for all previous tokens are held in GPU High Bandwidth Memory (HBM). The physical memory footprint of the KV cache is:
$$\text{Memory}_{\text{KV}} = 2 \times n_{\text{layers}} \times n_{\text{heads}} \times d_{\text{head}} \times \text{tokens} \times \text{bytes\_per\_element}$$

For a 70B parameter model with 128k context, a single un-cached session consumes tens of gigabytes of VRAM. **Prefix Prompt Caching** stores precomputed KV tensors in host/GPU memory, enabling subsequent requests with identical prefixes to bypass the prefill phase entirely.

```
Request 1 (Cold):
[System Prompt + Tools + Context] ──► Full Prefill ($O(N^2)$ GPU compute) ──► Write to KV Cache
                                                                              │ (5-min TTL)
Request 2 (Warm Cache Hit):                                                   ▼
[System Prompt + Tools + Context] ──► Instant Cache Hit! (Bypass Prefill) ──► Read KV Cache
+ [New Dynamic User Turn]          ──► Prefill Only New Tokens (~90% Cost & Latency Reduction)
```

### Production Invariants across Model Providers
| Provider / Engine | Cache Mechanism | Minimum Threshold | Cost Reduction | Invalidation Policy |
| :--- | :--- | :--- | :--- | :--- |
| **Anthropic Claude** | Explicit `cache_control: {"type": "ephemeral"}` | 1,024 tokens (Sonnet/Opus)<br>2,048 tokens (Haiku) | 90% discount on cache read tokens | 5-minute TTL, auto-refreshed on hit; max 4 breakpoints |
| **OpenAI GPT-4o** | Automatic Prefix Caching | 1,024 tokens | 50% discount on cache read tokens | 128-token increment blocks; LRU eviction |
| **DeepSeek-V3 / R1** | Context Caching | 64 tokens | Up to 90% discount | Multi-tenant shared prefix cache |
| **vLLM / SGLang** | PagedAttention & RadixAttention | Dynamic block size (16–32 tokens) | Eliminates prefill VRAM duplication | Radix Tree prefix matching across all concurrent requests |

---

## 2. Deterministic Prompt Prefix Invariance (The Bit-for-Bit Rule)

Prompt caching matches tokens sequentially from the absolute first token ($T_0$). **Any mutation, whitespace discrepancy, or non-deterministic dictionary serialization at token $T_i$ completely invalidates the cache for all tokens from $T_i$ to $T_N$.**

### The Cache Invalidation Cascade Disaster
- ❌ **The Volatile Header Anti-Pattern**:
  ```python
  # ❌ Catastrophic Anti-Pattern: Timestamp or dynamic PID at the prompt head
  # Every turn has a different timestamp -> 100% cache miss rate every single call!
  system_prompt = f"""
  You are an expert software engineer.
  Current Time: {datetime.now().isoformat()}  # <-- Destroys KV cache for all downstream tokens!
  Current Process PID: {os.getpid()}          # <-- Destroys KV cache on every process restart!
  
  [15,000 tokens of static architecture guides, rules, and tool definitions...]
  """
  ```

### The Three-Tier Prompt Anatomy
Organize prompt payloads into three immutable architectural zones:

```
┌─────────────────────────────────────────────────────────────┐
│ Zone 1: Immutable Static Core (100% Deterministic & Frozen) │
│ - System persona & invariant developer instructions         │
│ - Repository architecture standards & coding rules          │
│ - Deterministic JSON schemas for all tools (keys sorted)    │
│ ───► [Cache Breakpoint 1] ◄──────────────────────────────── │
├─────────────────────────────────────────────────────────────┤
│ Zone 2: Semi-Static Context (Updated on Epoch / File Save)   │
│ - Ingested workspace symbol index & directory trees         │
│ - Active specification files & design system contracts      │
│ - Pinned documentation / reference manuals                  │
│ ───► [Cache Breakpoint 2] ◄──────────────────────────────── │
├─────────────────────────────────────────────────────────────┤
│ Zone 3: Volatile Tail (Ephemeral, Uncached Dynamic Stream)  │
│ - Dynamic system clock (e.g., date: 2026-10-25)             │
│ - Multi-turn conversational dialogue & tool executions      │
│ - Immediate user query & target edit diffs                  │
└─────────────────────────────────────────────────────────────┘
```

- ✅ **Production Invariant**:
  - All tool definitions MUST have keys sorted deterministically (`json.dumps(schema, sort_keys=True)`).
  - Volatile timestamps must either be truncated to a coarse epoch (e.g. `2026-10-25`, changing only once per day) or placed strictly in the volatile user turn at the end of the context.

---

## 3. Anthropic 4-Breakpoint Strategic Allocation

Anthropic models permit at most **4 explicit cache breakpoints** (`"cache_control": {"type": "ephemeral"}`) per API call. Misallocating these four slots forfeits caching benefits for multi-megabyte workspaces.

```
Turn 1: [Zone 1: Tools & Rules (BP 1)] ─► [Zone 2: Repo Index (BP 2)] ─► [User Turn 1 (No BP)]
Turn 2: [Zone 1 (Hit)] ─► [Zone 2 (Hit)] ─► [User Turn 1 + Assistant 1 (BP 3)] ─► [User Turn 2]
Turn 3: [Zone 1 (Hit)] ─► [Zone 2 (Hit)] ─► [Turn 1 (Hit)] ─► [Turn 2 (Hit)] ─► [User Turn 3]
```

### Optimal 4-Breakpoint Allocation Strategy
1. **Breakpoint 1 (System Head & Tools)**: Place on the last tool declaration or at the end of the immutable system instructions.
2. **Breakpoint 2 (Project Ground-Truth Index)**: Place at the end of the static project overview, architecture rules, and database schema representations.
3. **Breakpoint 3 (Sliding Conversation History)**: Place on the assistant message at turn $N-1$ or $N-2$.
4. **Breakpoint 4 (Active Scratchpad / Memory Bank)**: Place on the persistent state checkpoint (`ACTIVE_CONTEXT.md`).

### The Sliding-Window Conversation Cache Algorithm
Moving the conversation cache breakpoint on every single turn creates a cache write and cold miss on every turn. Instead, advance the conversation breakpoint in stepped increments:

```typescript
// Production Invariant: Advance conversation cache breakpoint in blocks of K turns
const CACHE_STEP = 3; // Advance breakpoint every 3 turns

function buildAnthropicMessages(history: Message[], currentPrompt: string) {
  const messages: any[] = [];
  const totalTurns = history.length;
  
  // Determine index of the sliding cache checkpoint
  const cacheTurnIndex = totalTurns > 0 
    ? Math.floor((totalTurns - 1) / CACHE_STEP) * CACHE_STEP 
    : -1;

  for (let i = 0; i < totalTurns; i++) {
    const msg = history[i];
    if (i === cacheTurnIndex) {
      // Set Breakpoint 3 on the stepped boundary
      messages.push({
        role: msg.role,
        content: [
          {
            type: "text",
            text: msg.text,
            cache_control: { type: "ephemeral" }
          }
        ]
      });
    } else {
      messages.push({ role: msg.role, content: msg.text });
    }
  }

  // Volatile current turn (Uncached tail)
  messages.push({ role: "user", content: currentPrompt });
  return messages;
}
```

---

## 4. Attention Degradation & "Lost in the Middle" Invariants

Frontier LLMs exhibit a U-shaped attention curve: retrieval precision and instruction compliance are highest at the absolute **beginning (primacy effect)** and **end (recency effect)** of the context window. Information positioned between 30% and 75% of a 128k+ token prompt experiences up to **40-60% degradation** in recall accuracy.

```
Attention
Precision
  100% ────┐                                           ┌──── 100%
           │ Primacy Effect             Recency Effect │
           │ (System Rules)             (User Query)   │
   50%     │                                           │
           └─────────┐                       ┌─────────┘
                     │  "Lost in the Middle" │
    0%               └───────────────────────┘
          0%                50%               100% Prompt Depth
```

- **Placement Invariants**:
  - **Head (0-10% Depth)**: Behavioral constraints, security boundaries, type definitions, and negative bans ("NEVER do X").
  - **Middle (10-85% Depth)**: Reference documentation, retrieved search documents, passive codebase context, and historical execution logs.
  - **Tail (85-100% Depth)**: The immediate user command, specific file targets, negative refusal reminders, and output format requirements.
- **Explicit Retrieval Framing**:
  - Documents placed in the middle MUST be encapsulated in semantic XML blocks with explicit IDs:
    ```xml
    <context_documents>
      <document id="doc_auth_middleware" path="src/auth/jwt.go" lines="1-85">
        ... code slice ...
      </document>
    </context_documents>
    ```
  - Direct the model in the tail prompt: *"When citing facts or modifying interfaces from context, explicitly reference the `<document id="...">`."*

---

## 5. Hierarchical Progressive Disclosure & Context Economy

LLM context windows degrade in reasoning precision as raw token volume inflates. Ingesting whole codebases causes context bloat, cache thrashing, and hallucination loops.

```
Level 0: Structural Discovery  ──► ls, rg, outline symbols (Token cost: ~50-200)
Level 1: Targeted AST Slices   ──► Specific 50-line functions (Token cost: ~200-800)
Level 2: Full File Read        ──► Only for top-to-bottom rewrites (Token cost: ~2k-10k)
```

- **The 3-Level Progressive Read Protocol**:
  1. **Level 0 (Metadata Discovery)**: Use `rg --files`, AST symbol outlines, or LSP definitions to locate target files. Never ingest entire directories blindly.
  2. **Level 1 (Targeted AST Slice)**: Read specific function, class, or interface declarations using explicit line limits (`offset: 40, limit: 60`).
  3. **Level 2 (Full Ingestion)**: Ingest entire files ONLY when executing structural refactoring or creating complete sibling modules.
- **Total Ban on Low-Entropy Junk Ingestion**:
  - ❌ **NEVER ingest raw lockfiles** (`package-lock.json`, `pnpm-lock.yaml`, `Cargo.lock`, `go.sum`). Use CLI commands (`npm ls <pkg>`, `go list -m all`) to inspect specific dependency versions.
  - ❌ **NEVER dump raw compiled binaries, minified bundles, or base64 assets into context**.
  - ❌ **NEVER return unpaged database or log queries**: Impose a strict 20-row / 50-line ceiling on all search and database tools.

---

## 6. Lossless vs Lossy Context Compaction Algorithms

When conversation context reaches **70-75% of model capacity** ($T \ge 0.75 \times T_{\text{max}}$), the agent harness MUST execute context compaction to prevent hard context cutoffs.

### Lossless Compaction (Zero Semantic Loss)
1. **Tool Result Deduplication**: Replace redundant past tool call outputs with pointer references:
   ```xml
   <!-- Turn 3 Tool Result (Truncated upon subsequent identical read) -->
   <tool_result id="call_read_config_json" turn="3">
     [Output identical to Turn 1 result for "config.json". Refer to Turn 1.]
   </tool_result>
   ```
2. **Terminal & Test Output Cleansing**:
   - Strip ANSI terminal escape color codes (`\x1b[31m`).
   - Discard passing test lines (`✓ test_user_model.py (passed)`). Retain only failing assertions, stack traces, and exit codes.
3. **AST Comment & Whitespace Stripping**: Strip multi-line docstrings and non-essential comments from large reference snippets before injection.

### Lossy Compaction (Structured Checkpointing)
Never summarize conversation history into unstructured prose (*"The user asked to fix a bug and we edited some files..."*). Unstructured summaries lose file paths, exact error codes, and technical constraints.

- ✅ **The 4-Part Structured Checkpoint Invariant**:
  ```markdown
  ### Context Checkpoint (Compacted at Turn 18)
  
  #### 1. Verified Technical Ground Truth
  - Database: PostgreSQL 16 with pgvector extension enabled.
  - Auth: RS256 JWT tokens verified via JWKS endpoint at `/api/v1/.well-known/jwks.json`.
  - Touched Files: `src/auth/jwt.ts` (verified), `src/middleware/guard.ts` (verified).

  #### 2. Architectural Decisions & Discarded Alternatives
  - Rejected: In-memory token blacklist (rejected due to multi-pod deployment).
  - Selected: Redis sliding window blocklist with 15-minute TTL.

  #### 3. Applied & Verified Code Modifications
  - Modified `src/auth/jwt.ts`: added `ValidateTokenWithRevocation()` with test coverage.
  - Tests: `npm run test:auth` passing (4/4 tests green).

  #### 4. Active Blockers & Immediate Next Action
  - Blocker: Missing Redis client injection in `src/middleware/guard.ts:42`.
  - Immediate Next Action: Wire Redis connection pool into `guard.ts` and verify HTTP 401 on revoked token.
  ```

---

## 7. Zero-Waste Tool Response Formatting

Tool outputs are injected directly into LLM working memory. Poorly formatted tool responses waste thousands of tokens on syntactic boilerplate.

- **Prohibition of Indented Multi-Megabyte JSON**:
  - Tool outputs should return compact, dense text or minified JSON. Never return pretty-printed JSON with 4-space indents:
    ```
    Pretty JSON (4 spaces):   ~1,200 tokens
    Minified JSON / YAML:     ~450 tokens  (62% token savings)
    Dense Line-Oriented Text: ~280 tokens  (76% token savings)
    ```
- **Explicit Truncation Markers**:
  - When returning large logs or search results, enforce an upper bound (e.g. 2,000 words / 4,000 tokens) and append a deterministic continuation token:
    ```text
    [Showing lines 1-100 of 842 total lines. Output truncated. Use offset=101 to inspect further.]
    ```

---

## 8. Quick Diagnostic Checklist

- [ ] Is the prompt prefix (system persona, rules, tool schemas) 100% deterministic and bit-for-bit identical across turns?
- [ ] Are dynamic timestamps, UUIDs, and system metrics placed strictly at the tail of the prompt or in the uncached user turn?
- [ ] Are Anthropic `cache_control: {"type": "ephemeral"}` breakpoints placed at logical architectural boundaries (max 4 per request)?
- [ ] Is the sliding conversation history cache breakpoint advanced in stepped increments (e.g. every 3 turns) rather than every turn?
- [ ] Are high-priority operational rules located at the head (0-10%) and the target user task at the tail (85-100%) to mitigate Lost-in-the-Middle attention decay?
- [ ] Are tool outputs bounded with line/token ceilings and stripped of ANSI escape codes?
- [ ] When context exceeds 75% capacity, is the session compacted into a structured 4-part ground-truth checkpoint?
