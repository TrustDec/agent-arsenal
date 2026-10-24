---
name: context-engineering
description: Master AI Agent context economy, KV cache prefix optimization, multi-turn compaction, memory banks, and subagent handoffs. Use whenever designing autonomous agents, handling long context sessions, working with large repos, or managing MCP tool payloads.
---

# Agent Context Engineering & Memory Architecture Skill

Coding Agents default to context bloat: dumping 2,000-line files into memory, breaking prompt cache prefixes with dynamic timestamps, thrashing on failing tests, and suffering from catastrophic attention degradation ("Lost in the Middle").

This skill injects production-grade context hygiene, cache-friendly prompt layouts, and memory bank protocols into any AI agent harness.

---

## 1. PROMPT PREFIX CACHE INVARIANCE (KV Cache Preservation)

Frontier models (Claude 3.5/3.7, GPT-4o, Gemini 1.5/2.0) rely on prompt prefix caching for 5x–10x latency speedups and 75–90% cost savings. Invalidation destroys interactive responsiveness.

- **Deterministic Prefix Head**:
  - Keep static instructions, project architecture schemas, and invariant rules at the very beginning of the prompt context.
  - ❌ **NEVER inject dynamic timestamps, nonces, or volatile terminal outputs at the prompt prefix**.
  - Append dynamic conversational turns, volatile command outputs, and diffs strictly to the tail to maximize KV cache hits.
- **Cache Boundaries**:
  - Structure context with consistent XML/Markdown semantic delimiters (`<system_instructions>`, `<project_context>`, `<tool_declarations>`). Avoid mutating whitespace or headers between turns.

---

## 2. PROGRESSIVE DISCLOSURE & TOKEN ECONOMY

Context is finite and reasoning degrades with volume. Never dump entire repositories or unbounded logs into working memory.

- **The 3-Tier Inspection Protocol**:
  1. **Tier 1 (Outline & Discovery)**: Use `rg`, grep, or LSP symbol search to locate file paths and symbols.
  2. **Tier 2 (Surgical Slice)**: Inspect only the target function or block with explicit line offsets and limits (`offset: N, limit: M`).
  3. **Tier 3 (Full File Ingestion)**: Read full files only when architectural refactoring or whole-module rewrites are explicitly required.
- **Diagnostic Truncation**:
  - When running tests or linters, extract only failing assertions and stack traces. Discard hundreds of lines of passing test logs.
- **Tool Payload Projection**:
  - Enforce pagination (`limit: 25`, `offset: 0`) and field projections on all tool calls. Truncate collections to bounded subsets.

---

## 3. PERSISTENT MEMORY BANK & CHECKPOINT PROTOCOL

For long-running tasks or multi-turn collaborative sessions across restarts:

- **Maintain Memory Bank Files (`.agents/memory/` or project root)**:
  - `ACTIVE_CONTEXT.md`: Current sprint focus, active hypotheses, recently verified files, and immediate next steps.
  - `SYSTEM_PATTERNS.md`: Established architecture decisions, key abstractions, and prohibited antipatterns.
- **Structured Checkpoint Handoff**:
  - Conclude milestones or hand off tasks with a compact structured checkpoint:
    ```text
    [Context Hand-off Checkpoint]
    - Goal: Specific operational outcome and constraints.
    - Verified Ground Truth: Concrete file paths, symbols, and verified line numbers.
    - Completed Changes: Surgical diffs applied and verified passing.
    - Active Blockers / Invariants: Current compiler/test status.
    - Next Immediate Step: Precise subsequent action for the receiving agent.
    ```

---

## 4. THE 3-ATTEMPT CIRCUIT BREAKER

- If an agent fails to resolve a compiler or test error after **3 consecutive edits**, it MUST STOP immediately.
- ❌ **Do not spam speculative modifications**.
- Revert unverified changes (`git checkout -- <file>`), formulate a new root-cause hypothesis, or present the diagnostic findings to the user.

---

## 5. SUB-AGENT ISOLATION & SCRATCHPAD DISCIPLINE

- Offload noisy operations (broad regex sweeps, massive test runs, package audits) to sub-agents or sub-processes.
- Sub-agents must synthesize findings into dense 5-line summaries before reporting to the orchestrator, preserving the primary orchestrator's context window.
