---
description: Agentic context compaction, progressive summarization, ephemeral observation pruning, long-horizon session checkpointing, and KV cache-aware memory management
globs: **/*{compactor,context_manager,memory_bank,session_manager,agent_harness,compaction}*.*,**/context/*.{ts,js,py,go},**/memory/*.{ts,js,py,go},**/{CLAUDE,AGENTS}.md,**/.cursor/rules/**,**/.agents/**
alwaysApply: false
---

# Agentic Context Compaction, Dynamic Memory Pruning & Long-Horizon Session Checkpointing

> Add these rules to your project when building or operating long-horizon autonomous AI coding agents, multi-turn tool-calling harnesses, or interactive CLI agent sessions (Claude Code, Cursor Composer, Windsurf Cascade, Roo Code, Pi, OpenAI Agents SDK, LangGraph).

---

## 1. The Context Cliff & Cognitive Degradation in Multi-Turn Trajectories

In long-horizon autonomous agent executions (such as solving multi-file SWE-bench tasks, complex refactoring, or running iterative test-fix loops), the agent conversation history expands rapidly across 20 to 50+ turns.

Unchecked context growth triggers the **Context Cliff**:
1. **Attention Dissipation ("Lost in the Middle")**: Even in 128k–200k+ frontier models (Claude 3.7 Sonnet, GPT-4o), attention retrieval accuracy follows a U-shaped curve. As token counts exceed 40k–60k tokens, the model's ability to recall subtle constraints, file paths, or negative invariants placed in the conversational midsection degrades exponentially.
2. **Context Rot & Noise Amplification**: Historical turns contain failed hypotheses, multi-hundred line compiler stack traces, dead-end bash outputs, and stale file snapshots. The agent begins hallucinating that fixed bugs are still active or repeats already disproven reasoning trajectories.
3. **Quadratic Prefill & Memory Bandwidth Latency**: While warm prompt KV caching accelerates static prefixes, every new token added to the conversational tail increases decode latency and increases the cost of any un-cached turn:
$$\text{Latency}_{\text{turn}} \propto O(\text{Tokens}_{\text{total}}) + \frac{\text{Memory}_{\text{KV}}}{\text{Memory Bandwidth}_{\text{GPU}}}$$
4. **Catastrophic Out-of-Context Failure**: When context limits (e.g. 128k or 200k) are reached, naive agents fail with hard API errors (`400 context_length_exceeded`) or truncate history arbitrarily, dropping initial system instructions or active project requirements.

```
Token History Growth Without Compaction:
Turn 1  [Sys + Tools + Prompt] ────────────────────────────────► 4k tokens
Turn 5  [Sys + Tools + 4 turns with 500-line bash dumps] ──────► 18k tokens
Turn 15 [Sys + Tools + 14 turns + stale file reads] ───────────► 65k tokens (Attention degrades!)
Turn 30 [Sys + Tools + 29 turns + repeated diffs] ─────────────► 140k tokens (Catastrophic Context Cliff!)

Token History Growth With Dynamic 4-Stage Compaction:
Turn 1  [Sys + Tools + Prompt] ────────────────────────────────► 4k tokens
Turn 5  [Sys + Tools + Pruned Observations] ───────────────────► 7k tokens
Turn 15 [Sys + Tools + Ground-Truth Checkpoint + 3 turns] ─────► 12k tokens (Constant high attention!)
Turn 30 [Sys + Tools + Ground-Truth Checkpoint + 3 turns] ─────► 14k tokens (Hermetic, fast, deterministic)
```

---

## 2. The 4-Stage Compaction & Memory Hierarchy

Modern production agent architectures (Claude Code, Cursor Composer, Windsurf) employ a **hierarchical, multi-stage compaction strategy** that segregates ephemeral observations from durable architectural truth.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        AGENT CONTEXT WINDOW                            │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Tier 1: Real-Time Ephemeral Tool Output Stripping & Eviction     │  │
│  │ (Evicts raw bash/grep stdout after reasoning turn; retains facts)│  │
│  └──────────────────────────────────▲───────────────────────────────┘  │
│                                     │                                  │
│  ┌──────────────────────────────────┴───────────────────────────────┐  │
│  │ Tier 2: Lossless AST & Tool Output Deduplication                 │  │
│  │ (Coalesces redundant file reads, strips ANSI codes & passes)     │  │
│  └──────────────────────────────────▲───────────────────────────────┘  │
│                                     │ When tokens > Soft Limit (65%)   │
│  ┌──────────────────────────────────┴───────────────────────────────┐  │
│  │ Tier 3: Semantic Structured Summarization (Ground-Truth FSM)     │  │
│  │ (Compresses past N turns into a 4-part typed state checkpoint)   │  │
│  └──────────────────────────────────▲───────────────────────────────┘  │
│                                     │ When session crosses milestones  │
│  ┌──────────────────────────────────┴───────────────────────────────┐  │
│  │ Tier 4: Memory Bank Externalization (Disk Persistence)           │  │
│  │ (Spills architectural decisions & patterns to MEMORY.md)         │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

### Compaction Tier Comparison Matrix
| Tier | Trigger Mechanism | Compression Ratio | Information Loss | Primary Target |
| :--- | :--- | :--- | :--- | :--- |
| **Tier 1: Ephemeral Stripping** | Immediately after tool digestion turn | $60\% - 85\%$ | Zero semantic loss (drops raw terminal bytes) | Multi-line command outputs, raw grep dumps, test runs |
| **Tier 2: Lossless Deduplication** | After each tool cycle | $20\% - 40\%$ | Bit-for-bit lossless | Duplicate file read snapshots, passing test lines, ANSI codes |
| **Tier 3: Semantic Checkpoint** | Token threshold ($\ge 65\%$ context window) | $80\% - 95\%$ | Controlled (drops dead-end reasoning paths) | Full conversational history (older than the last 3 turns) |
| **Tier 4: Memory Bank Spill** | Explicit milestone / user session end | $98\%$ | High abstraction (retains rules & architecture) | Project memory files (`MEMORY.md`, `ACTIVE_CONTEXT.md`) |

---

## 3. Threshold-Triggered Compaction Finite-State Machine (FSM)

Never wait until context window exhaustion ($> 95\%$) to trigger compaction. Emergency compaction under near-exhausted context risks token generation truncation and leaves zero headroom for LLM summarization.

### The Dual-Threshold State Machine
1. **Soft Threshold ($\tau_{\text{soft}} = 65\%$ capacity)**:
   - Triggers **non-blocking asynchronous pre-compaction**.
   - An isolated, low-cost model (or background thread) summarizes turns $0 \dots T-4$ into a draft ground-truth checkpoint while the user/agent continues interacting.
2. **Hard Threshold ($\tau_{\text{hard}} = 85\%$ capacity)**:
   - Triggers **blocking synchronous compaction**.
   - The interactive turn loop pauses. The pre-computed or freshly generated checkpoint replaces turns $0 \dots T-3$. Context is instantly pruned down to $\le 30\%$ capacity before the agent executes its next action.

```
       [ Context < 65% ]
       ┌───────────────┐
       │    HEALTHY    │◄─────────────────────────────┐
       └───────┬───────┘                              │
               │ Context >= 65% (Soft Limit)          │
               ▼                                      │
       ┌───────────────┐                              │
       │ PRECOMPUTING  │                              │
       │  CHECKPOINT   │ (Runs in background worker)  │
       └───────┬───────┘                              │
               │ Context >= 85% (Hard Limit)          │ Compaction Complete
               ▼                                      │ Context pruned to < 30%
       ┌───────────────┐                              │
       │    BLOCKING   │                              │
       │  COMPACTION   │                              │
       └───────┬───────┘                              │
               │ Validate Checkpoint Integrity & Paths│
               ▼                                      │
       ┌───────────────┐                              │
       │   VALIDATED   ├──────────────────────────────┘
       │  REHYDRATION  │
       └───────────────┘
```

---

## 4. Claude Code `/compact` Architecture & Interactive CLI Session Mechanics

Anthropic's Claude Code interactive CLI harness popularized structured terminal context compaction (`/compact`).

### Core Invariants of the Claude Code Architecture
1. **Three-Zone Message Partitioning**:
   - **Zone A: Immutable System Prompt & Tool Schemas** (Bit-for-bit static, 100% KV cache hit rate).
   - **Zone B: Compacted Historical Checkpoint** (A single synthetic system/assistant message encapsulating all consolidated work).
   - **Zone C: Active Ephemeral Tail** (The most recent 2 to 4 turns containing the immediate user query, active diff, and compiler feedback).
2. **Absolute Preservation of Zone A**:
   - Compaction MUST NEVER mutate, rephrase, or reorder the system prompt, guidelines, or tool schemas. Modifying Zone A destroys the root KV cache prefix for the entire session.
3. **Surgical Boundary Insertion**:
   ```text
   [System Prompt & MCP Tools]  <─── Immutable Prefix (Cached)
   [Boundary Marker: <session_checkpoint version="3">]
     - Goals & Requirements
     - Completed Architectural Changes
     - Verified Invariants & Codebase Facts
     - Active Hypothesis
   [Boundary Marker: </session_checkpoint>]
   [User Message: Turn T-1]     <─── Ephemeral Context Tail
   [Assistant Plan: Turn T-1]
   [Tool Result: Turn T-1]
   [User Message: Turn T (Active)]
   ```

---

## 5. Ephemeral Observation Stripping & Result Minification

The single largest source of context bloat in coding agents is **unfiltered tool output**: `cat` dumps, `git log`, `npm test`, and `grep -rn`. 

Once the agent has reasoned over a tool result and formulated its next action, **the raw byte stream of that tool output loses 99% of its utility**.

### The "Tee & Evict" Pattern
- ❌ **The Hoarding Anti-Pattern**: Leaving 2,000 lines of passing Jest/Vitest output in the conversation history across 20 turns, consuming 50,000 tokens for zero information gain.
- ✅ **Production Invariant**:
  1. Capture full tool output in an ephemeral local disk buffer or in-memory map keyed by `tool_call_id`.
  2. In the conversation history, replace massive outputs with a **synthesized observation envelope** as soon as the next assistant turn begins:
     ```xml
     <!-- Raw output (5,400 tokens) evicted; replaced with compact factual envelope (65 tokens) -->
     <tool_result tool_use_id="call_npm_test_9821" evicted="true">
       <status>success</status>
       <exit_code>0</exit_code>
       <summary>48 test suites passed, 312 tests passed, 0 failures in 3.42s.</summary>
       <retained_diagnostic>All unit invariants verified.</retained_diagnostic>
     </tool_result>
     ```

### ANSI Escape Code & Whitespace Stripping
Always sanitize raw terminal stdout before appending to context:
- Strip ANSI color/style escape codes (`\x1b\[[0-9;]*[a-zA-Z]`).
- Collapse repetitive empty lines ($\ge 3$ consecutive newlines collapsed to 1).
- Truncate long horizontal rules (`------` or `======` repeated $> 10$ times capped to 10 characters).

---

## 6. Deterministic KV Cache Prefix Preservation During Compaction

Naive compaction implementations wipe the entire conversation message array and replace it with `[system, user: "Here is what happened: " + summary]`. 

**This destroys the KV cache prefix**, forcing the provider (Anthropic, OpenAI, DeepSeek) to re-prefill all system rules, MCP schemas, and project guides at full cost and maximum latency.

### The Cache-Preserving Compactor Invariant
1. Keep the exact array reference and byte-for-byte token serialization for the initial `system` message and all `tools` configurations.
2. In the `messages` array, preserve message index 0 if it contains initial static user context.
3. Consolidate messages from index $1$ to $T-3$ into a single structured summary message.
4. Ensure the summary message uses a **deterministic timestamp and ID layout** to avoid unnecessary cache busts in multi-branch agent search.

```ts
// ✅ Cache-friendly compaction message transformation
export function applyCacheFriendlyCompaction(
  systemPrompt: string,
  tools: ToolDefinition[],
  messages: AgentMessage[],
  checkpointText: string,
  preservedTailCount: number = 3
): { system: string; tools: ToolDefinition[]; messages: AgentMessage[] } {
  // System prompt and tools remain strictly untouched (100% KV prefix hit)
  const tailMessages = messages.slice(-preservedTailCount);

  const compactedMessages: AgentMessage[] = [
    {
      role: 'user',
      content: `<session_state_checkpoint>\n${checkpointText}\n</session_state_checkpoint>\n\nPlease continue executing the task based on the verified checkpoint above.`
    },
    {
      role: 'assistant',
      content: `Understood. I have re-grounded my working memory on the verified checkpoint. Resuming execution without repeating completed tasks.`
    },
    ...tailMessages
  ];

  return { system: systemPrompt, tools, messages: compactedMessages };
}
```

---

## 7. The 4-Part Ground-Truth Checkpoint Schema

When generating a semantic summary (Tier 3), do not permit the LLM to write vague prose ("The agent worked on tests and edited some files"). Vague summaries cause catastrophic context drift.

Enforce a **strict 4-part typed JSON/XML ground-truth checkpoint**:

```xml
<session_checkpoint version="1.0">
  <!-- 1. OBJECTIVE & BOUNDARIES: Unchanged intent and non-negotiables -->
  <objective>
    <user_intent>Fix race condition in OrderProcessor concurrent checkout</user_intent>
    <non_negotiable_invariants>
      - Must not introduce table-level locks on pg_orders
      - Must maintain backward compatibility with Stripe v3 webhooks
    </non_negotiable_invariants>
  </objective>

  <!-- 2. COMPLETED ARCHITECTURAL WORK: Definite, immutable facts -->
  <completed_work>
    <modified_file path="pkg/order/processor.go" status="verified">
      Replaced sync.Mutex with per-order key lock using singleflight; eliminated lock contention.
    </modified_file>
    <modified_file path="pkg/order/processor_test.go" status="verified">
      Added TestConcurrentCheckoutRace deterministic reproduction with 100 parallel goroutines.
    </modified_file>
  </completed_work>

  <!-- 3. VERIFIED CODEBASE FACTS: Hard-won knowledge (prevents re-discovery) -->
  <verified_facts>
    - PostgreSQL test container runs on port 5433 (not default 5432)
    - Redis connection requires explicit db index 2 in test suite
    - Migration 004_add_order_status.sql has already been executed on the dev instance
  </verified_facts>

  <!-- 4. ACTIVE HYPOTHESIS & IMMEDIATE NEXT STEP: Precise continuity -->
  <next_action>
    <current_hypothesis>
      Unit tests pass, but integration test TestProcessor_PaymentWebhookTimeout fails due to context cancellation timing.
    </current_hypothesis>
    <immediate_step>
      Inspect pkg/order/webhook.go:142 to verify if ctx is passed from HTTP request or detached for async processing.
    </immediate_step>
  </next_action>
</session_checkpoint>
```

---

## 8. Dynamic Token Budget Allocation Matrix

Never operate an agent without a strict **token allocation budget**. The total context window must be partitioned into deterministic operational slices:

```
┌────────────────────────────────────────────────────────────────────────┐
│                   TOTAL CONTEXT WINDOW BUDGET (100%)                   │
├───────────┬───────────┬──────────────┬───────────────┬─────────────────┤
│ System &  │ MCP Tool  │ Repo Map &   │ State Checkpt │ Immediate Tail  │
│ Directives│ Schemas   │ AST Slices   │ & Memory Bank │ & Headroom      │
│   (10%)   │   (10%)   │    (15%)     │     (25%)     │      (40%)      │
└───────────┴───────────┴──────────────┴───────────────┴─────────────────┘
```

### Allocation Rules for 128k Context
- **System Directives & Rules ($\le 12\text{k}$ tokens)**: Core identity, language rules, safety invariants.
- **MCP Tool Virtualization ($\le 12\text{k}$ tokens)**: Virtual tool catalog schemas (see `rules/mcp-client-tool-virtualization.md`).
- **AST Repository Map ($\le 20\text{k}$ tokens)**: Condensed PageRank symbol signatures (see `rules/code-intelligence-repo-maps-ast-editing.md`).
- **State Checkpoint & Memory Bank ($\le 32\text{k}$ tokens)**: Consolidated ground-truth summary and project memory bank files.
- **Immediate Conversation Tail ($\le 35\text{k}$ tokens)**: Last 3–5 active turns, current tool outputs, and user prompts.
- **Generation Headroom ($\ge 16\text{k}$ tokens)**: Reserved exclusively for the model's output completion, preventing token generation truncation (`max_tokens`).

---

## 9. Anti-Hallucination & Information Preservation Guardrails

Recursive summarization suffers from the **"Telephone Game" effect**: across 5 successive compaction cycles, subtle details degrade or get hallucinated.

### Mandatory Verification Gates Before Accepting a Checkpoint
1. **File Path Ground-Truth Check**:
   - Extract all file paths mentioned in the summary (`pkg/order/processor.go`).
   - Programmatically run `fs.existsSync(path)` or `git ls-files --error-unmatch <path>` on the host.
   - If the summarizer hallucinated an imaginary file path that does not exist in the working directory, **abort the checkpoint and reject the compaction turn**.
2. **Deterministic Constraint Pinning**:
   - Critical user-specified parameters (e.g., ports, error codes, specific user constraints, reproduction test flags) must be tagged with `<pin>` attributes in the prompt.
   - The compaction engine regex-validates that all `<pin>` values from turn 0 exist verbatim in the consolidated checkpoint.
3. **Failing Test Signature Invariance**:
   - If an active bug is under investigation, the exact reproduction command (`go test -run TestConcurrentCheckoutRace -race ./pkg/...`) and error trace signature MUST be preserved word-for-word. Summarizing a reproduction command into "Ran unit tests" is strictly prohibited.

---

## 10. Externalized Memory Banks & Disk-Backed Persistence Patterns

For multi-day or multi-session tasks, working memory in RAM is insufficient. Agents must externalize knowledge into structured markdown files stored in the repository root (`.agents/` or `.claude/`).

### Standard Memory Bank Hierarchy
- `MEMORY.md`: Core system directives, architecture decisions, and immutable invariants.
- `ACTIVE_CONTEXT.md`: Current goal, active branch, work in progress, and recent decisions.
- `PROGRESS.md`: Epic and subtask checklist with verified completion timestamps.
- `PATTERNS.md`: Discovered architectural patterns, idiomatic conventions, and testing practices.

### Two-Phase Memory Commit Protocol
- ❌ **Spontaneous Disk Overwrites**: Having the agent overwrite `MEMORY.md` on every minor thought, polluting the git status diff with thousands of lines of uncommitted noise.
- ✅ **Production Invariant**:
  1. Hold memory updates in an in-memory draft queue during task execution.
  2. Perform an atomic two-phase commit to disk ONLY when:
     - A task milestone is reached (e.g. all tests pass).
     - The user explicitly requests session termination or `/compact`.
     - An architectural decision is finalized.
  3. Prefix all memory commits with `[agent-memory]` and exclude temporary scratchpads from production git commits via `.gitignore`.

---

## 11. Production-Ready Implementation: Agentic Context Compactor

```ts
// context-compactor.ts
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';

export interface Message {
  role: 'system' | 'user' | 'assistant';
  content: string;
  tool_use_id?: string;
  tool_calls?: any[];
}

export interface CompactorConfig {
  maxContextTokens: number;
  softThresholdRatio: number; // e.g. 0.65
  hardThresholdRatio: number; // e.g. 0.85
  preservedTailTurns: number; // e.g. 3
}

export class AgentContextCompactor {
  constructor(private config: CompactorConfig) {}

  // Fast token estimation heuristic (3.5 chars per token for code/text)
  public estimateTokens(messages: Message[]): number {
    let charCount = 0;
    for (const msg of messages) {
      charCount += msg.content.length;
      if (msg.tool_calls) {
        charCount += JSON.stringify(msg.tool_calls).length;
      }
    }
    return Math.ceil(charCount / 3.5);
  }

  public shouldCompact(messages: Message[]): boolean {
    const tokens = this.estimateTokens(messages);
    return tokens >= this.config.maxContextTokens * this.config.hardThresholdRatio;
  }

  // Tier 1: Real-time stripping of obsolete tool stdout
  public pruneEphemeralObservations(messages: Message[]): Message[] {
    const pruned: Message[] = [];
    const total = messages.length;

    for (let i = 0; i < total; i++) {
      const msg = messages[i];
      // If message is a tool output and is older than the last 4 messages, minify it
      if (msg.role === 'user' && msg.tool_use_id && i < total - 4) {
        const lines = msg.content.split('\n');
        if (lines.length > 20) {
          const summary = lines.slice(0, 3).join('\n') +
            `\n... [${lines.length - 6} lines of historical tool output pruned] ...\n` +
            lines.slice(-3).join('\n');
          pruned.push({ ...msg, content: summary });
          continue;
        }
      }
      pruned.push(msg);
    }
    return pruned;
  }

  // Tier 3: Verify and apply ground truth checkpoint
  public applyCheckpoint(
    messages: Message[],
    checkpointXml: string,
    verifiedFiles: string[]
  ): Message[] {
    // 1. Guardrail: Validate all mentioned files exist on host
    for (const file of verifiedFiles) {
      if (!existsSync(file)) {
        throw new Error(`Compaction rejected: Hallucinated file path detected: ${file}`);
      }
    }

    // 2. Preserve static system head and ephemereal tail
    const systemMessage = messages.find(m => m.role === 'system');
    const tailMessages = messages.slice(-this.config.preservedTailTurns);

    const result: Message[] = [];
    if (systemMessage) {
      result.push(systemMessage);
    }

    result.push({
      role: 'user',
      content: `<session_state_checkpoint>\n${checkpointXml}\n</session_state_checkpoint>\n\nResume execution from the verified state above.`
    });

    result.push({
      role: 'assistant',
      content: 'Checkpoint ingested. Grounded on verified state and ready to execute immediate next action.'
    });

    result.push(...tailMessages);
    return result;
  }
}
```

---

## 12. Production Checklist for Long-Horizon Agent Context Systems

- [ ] **Prefix Invariance Verified**: System prompt, instructions, and tool schemas remain bit-for-bit static to preserve 90%+ KV prompt cache discounts.
- [ ] **Dual Thresholds Configured**: Non-blocking soft threshold set to 65% capacity; blocking hard threshold set to 85% capacity.
- [ ] **Tier 1 Observation Pruning Active**: Historical tool outputs exceeding 20 lines pruned once the assistant has advanced past them.
- [ ] **ANSI Escape Codes Stripped**: Terminal control codes sanitized before feeding shell outputs back into the LLM context.
- [ ] **Strict 4-Part Checkpoint Schema Enforced**: Summaries partitioned into Objective, Completed Work, Verified Facts, and Next Action.
- [ ] **File Path Guardrail Enabled**: Programmatic check confirms every file path in the summary exists on disk before accepting the checkpoint.
- [ ] **Exact Reproduction Commands Pinned**: Deterministic test commands and failure signatures preserved verbatim without lossy paraphrasing.
- [ ] **Token Allocation Headroom Guaranteed**: At least 15% of the context window reserved strictly for model output generation (`max_tokens`).
- [ ] **Memory Bank Two-Phase Commit**: Persistent project state written to disk only at milestones, avoiding git status churn.
- [ ] **No Raw Binary / Lockfile Ingestion**: Multi-megabyte files routed to summary extractors (`jq`, `grep`, `ast-grep`) rather than full-file ingestion.
- [ ] **Lossless Deduplication Implemented**: Duplicate reads of the same unchanged file coalesced to point to the initial read.
- [ ] **Interactive `/compact` Command Supported**: Users and autonomous harness loops can manually trigger compaction at logical pause points.
