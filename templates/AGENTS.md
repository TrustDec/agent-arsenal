# AGENTS.md - Multi-Agent Harness Architecture & Operational Guide

This document governs the multi-agent collaboration model across AI coding harnesses (Claude Code, Cursor, Pi, Codex, OpenCode, Windsurf).

---

## 1. Core Principles

1. **Role Specialization**: Agents must not attempt all tasks simultaneously. Split complex work into:
   - **Architect / Researcher**: Gathers context, reads documentation, inspects schemas. Does NOT write code.
   - **Implementer**: Makes targeted edits based strictly on the Architect's plan.
   - **Reviewer / QA**: Runs compilers, unit tests, and security scans. Inspects git diff for unintended changes.

2. **Session Context Management & Anti-Rot**:
   - **Token Economy & Progressive Disclosure**: Context is finite and degrades with bloat. Never dump whole directories or 2,000-line files into memory. First list symbols/paths, then slice inspect only the relevant functions.
   - **Compacted Hand-Off & Checkpoints**: In long multi-turn sessions, summarize findings into dense structured checkpoints:
     1. Stated objective & completed milestones.
     2. Active hypotheses & verified file paths.
     3. Blockers / root causes identified.
     4. Next immediate surgical actions.
   - **Sub-Agent & Scratchpad Isolation**: Use dedicated sub-agents or subshells for noisy exploratory searches (e.g., broad regex searches, running massive test suites) to prevent polluting the primary orchestrator's context window.

3. **Deterministic Tools Over Generative Guessing**:
   - Use `grep`, `rg`, AST parsers, and language server diagnostics to locate symbols. Never guess line numbers, interfaces, or file locations.
   - Trust tool and compiler output above internal priors.

---

## 2. Model Context Protocol (MCP) & Tool Operations

When invoking tools via MCP servers or native CLI integrations:

1. **Payload Restraint & Chunking**:
   - Never request raw multi-megabyte payloads into the context window.
   - Always supply filters, pagination parameters, or field projections (`limit`, `offset`, `fields`, `depth`).
2. **MCP Resources vs Tools**:
   - Use MCP Resources (`resources/read`) for static documentation, OpenAPI specs, and reference schemas.
   - Use MCP Tools (`tools/call`) exclusively for purposeful, state-changing or diagnostic actions with strict JSON Schema validation.
3. **Fail Fast on Missing Schemas**:
   - Verify tool arguments against the declared JSON Schema before execution.
   - If an MCP tool returns an error, parse the diagnostic error message before attempting any fallback.
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
