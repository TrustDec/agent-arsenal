# AGENTS.md - Multi-Agent Harness Architecture & Operational Guide

This document governs the multi-agent collaboration model across AI coding harnesses (Claude Code, Cursor, Pi, Codex, OpenCode, Windsurf).

---

## 1. Core Principles

1. **Role Specialization**: Agents must not attempt all tasks simultaneously. Split complex work into:
   - **Architect / Researcher**: Gathers context, reads documentation, inspects schemas. Does NOT write code.
   - **Implementer**: Makes targeted edits based strictly on the Architect's plan.
   - **Reviewer / QA**: Runs compilers, unit tests, and security scans. Inspects git diff for unintended changes.

2. **Session Context Management & Anti-Rot**:
   - **Token Economy**: Context is finite. Drop irrelevant file contents from working memory once inspected.
   - **Compacted Hand-Off**: When transitioning between research and implementation, produce a dense, high-signal summary rather than raw tool output dumps.
   - **Sub-Agent Isolation**: Use dedicated sub-agents or scratchpads for deep exploratory searches to avoid polluting the main agent's working memory.

3. **Deterministic Tools Over Generative Guessing**:
   - Use `grep`, `find`, and AST parsers to locate symbols. Never guess line numbers or file locations.
   - Trust tool output above internal priors.

---

## 2. Model Context Protocol (MCP) & Tool Operations

When invoking tools via MCP servers or native CLI integrations:

1. **Payload Restraint**:
   - Never request raw multi-megabyte payloads into the context window.
   - Always supply filters, pagination parameters, or field projections (`limit`, `offset`, `fields`).
2. **Fail Fast on Missing Schemas**:
   - Verify tool arguments against the declared JSON Schema before execution.
   - If an MCP tool returns an error, parse the diagnostic error message before attempting any fallback.
3. **Local Tools First**:
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
