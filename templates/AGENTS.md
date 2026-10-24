# AGENTS.md - Multi-Agent Harness Architecture & Operational Guide

This document governs the multi-agent collaboration model and operational protocol across modern AI coding harnesses (Claude Code, Cursor, Pi, Codex, OpenCode, Windsurf).

---

## 1. Core Principles

1. **Role Specialization**: Agents must not attempt all tasks simultaneously. Split complex work into:
   - **Architect / Researcher**: Gathers context, reads documentation, inspects schemas. Does NOT write code.
   - **Implementer**: Makes targeted edits based strictly on the Architect's plan.
   - **Reviewer / QA**: Runs compilers, unit tests, and security scans. Inspects git diff for unintended changes.

2. **Session Context Management & Anti-Rot**:
   - **Token Economy & Progressive Disclosure**: Context is finite and degrades with bloat. Never dump whole directories or 2,000-line files into memory:
     - Step 1: List symbol outlines or search paths with `rg` / `grep`.
     - Step 2: Slice inspect only the targeted function or block with line offsets/limits.
     - Step 3: Read full files only when architectural refactoring is explicitly required.
   - **Compacted Hand-Off & Checkpoints**: In long multi-turn sessions, summarize findings into dense structured checkpoints:
     1. Stated objective & completed milestones.
     2. Active hypotheses & verified file paths.
     3. Blockers / root causes identified.
     4. Next immediate surgical actions.
   - **Sub-Agent & Scratchpad Isolation**: Use dedicated sub-agents or subshells for noisy exploratory searches (e.g., broad regex searches, running massive test suites) to prevent polluting the primary orchestrator's context window.
   - **Prompt Prefix Cache Awareness**: Frontier model performance and latency depend heavily on KV/prompt prefix caching. Keep static instructions, project architecture schemas, and invariant rules at the beginning of the prompt context. Append dynamic conversational turns, volatile command outputs, and diffs strictly to the tail to maximize cache hits.
   - **Semantic Delimiter Framing**: Wrap raw tool outputs, command outputs, and external web content in explicit boundary delimiters (e.g., `<tool_output name="...">` or `<file_content path="...">`) to prevent context confusion, parse degradation, and indirect prompt injection.
   - **Structured Checkpoint Protocol**: When delegating across sub-agents or concluding complex multi-turn steps, provide a compact structured handoff block:
     ```text
     [Context Hand-off Checkpoint]
     - Goal: Specific operational outcome and constraints.
     - Verified Ground Truth: Concrete file paths, symbols, and verified line numbers.
     - Completed Changes: Surgical diffs applied and verified passing.
     - Next Immediate Step: Precise subsequent action for the receiving agent.
     ```
   - **The 3-Attempt Circuit Breaker**: If an agent fails to resolve a compiler or test error after 3 consecutive edits, it MUST STOP immediately. Do not spam speculative changes. Revert unverified changes (`git checkout -- <file>`), formulate a new root-cause hypothesis, or summarize findings to the user.

3. **Deterministic Tools Over Generative Guessing**:
   - Use `grep`, `rg`, AST parsers, and language server diagnostics to locate symbols. Never guess line numbers, interfaces, or file locations.
   - Trust tool and compiler output above internal priors.

4. **Non-Interactive Execution & Subprocess Hygiene**:
   - Commands invoked by agents MUST pass non-interactive flags (`-y`, `--yes`, `DEBIAN_FRONTEND=noninteractive`, `CI=true`) to avoid blocking indefinitely on prompts.
   - Constrain log outputs using head/tail/offsets. Never dump unbounded logs or full dependency trees into prompt memory.
   - Deterministically terminate child test servers and background daemons upon task completion.

---

## 2. Model Context Protocol (MCP) & Tool Operations

When developing or invoking tools via MCP servers and native CLI integrations:

1. **Payload Restraint & Chunking**:
   - Never request raw multi-megabyte payloads into the context window.
   - Always supply filters, pagination parameters, or field projections (`limit`, `offset`, `fields`, `depth`).
2. **MCP Resources vs Tools**:
   - Use MCP Resources (`resources/read`) for static documentation, OpenAPI specs, and reference schemas.
   - Use MCP Tools (`tools/call`) exclusively for purposeful, state-changing or diagnostic actions with strict JSON Schema validation.
3. **Tool Design Discipline for MCP Servers**:
   - **JSON Schema Precision**: Every parameter must include a clear `description` explaining allowed formats (e.g., ISO-8601 dates, UUIDs, absolute paths). Never leave parameters untyped.
   - **Destructive Safety & Dry-Run**: Destructive tools (file writes, database mutations, external calls) must support a `dryRun: boolean` parameter whenever feasible.
   - **Structured Error Response**: Never crash the MCP transport on invalid input. Return `{ isError: true, content: [{ type: "text", text: "Descriptive error message and remediation hint" }] }`.
   - **Stdio Transport Hygiene**: When writing stdio-based MCP servers, strictly log diagnostic messages to `stderr` (`console.error` / `logging.error`). Never write arbitrary text to `stdout`, which corrupts the JSON-RPC stream.
4. **Local Tools First**:
   - Favor deterministic local tools (`git`, `grep`, `rg`, language server diagnostics) over costly remote MCP roundtrips when inspecting local codebases.

---

## 3. Self-Healing Verification Loop

Before declaring any implementation task complete:

```text
[Implementation] -> [Run Linters & Compilers] -> [Run Unit / Integration Tests] -> [Inspect Git Diff]
        ^                                                   | (if failure)
        └────────────────── Read Error Output ──────────────┘
```

- **Zero Blind Retries**: If a command fails, read the compiler or test output in full. Formulate a specific hypothesis before applying the next surgical edit.
- **Diff Sanity Check**: Run `git diff` to ensure zero unrelated whitespace, dependency, or file reformatting changes were introduced.
- **Machine-Verified Proof**: Every bug fix or feature must conclude with empirical evidence: a green exit code (`0`) from the compiler or test runner.
