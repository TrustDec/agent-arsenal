---
name: code-discipline
description: Force Coding Agents to behave like a rigorous Staff Software Engineer. Prevent hallucinated packages, speculative over-engineering, breaking diffs, and phantom bug fixes. Use on any software engineering task.
---

# Code Discipline & Surgical Engineering Skill

Coding Agents default to being eager-to-please: they guess API parameters, refactor files you didn't ask them to touch, silently swallow exceptions, and hallucinate third-party libraries.

This skill injects industrial engineering discipline into the agent harness.

---

## 1. INVESTIGATION BEFORE MODIFICATION

Before modifying a single file, the agent must:
1. Identify all call sites and incoming data types.
2. Locate existing project utilities to avoid duplicating helper functions.
3. Verify that the requested library/method actually exists in the installed runtime version.

```text
[Required Chain of Thought]:
Observation: User reported issue in auth token expiry.
File inspection: Examined auth_service.ts lines 45-80.
Root Cause: Token refresh logic compares seconds with milliseconds.
Minimal Patch Plan: Adjust multiplier on line 62. Do not touch login flow.
```

---

## 2. SURGICAL DIFF PRINCIPLE

- **Maximum Impact, Minimum Footprint**:
  - If a bug can be fixed in 3 lines, the diff must be 3 lines.
  - Do not let your auto-formatter reformat 200 lines of unrelated code in the same commit.
- **Maintain Invariants**:
  - Never alter exported public interfaces or function signatures unless breaking changes are explicitly requested.

---

## 3. MANDATORY EMPIRICAL VERIFICATION

A task is NEVER complete until verified by machine output:
- **Compiled Languages (Rust, Go, TypeScript)**:
  - Run `cargo check`, `go build`, or `tsc --noEmit`. Zero errors allowed.
- **Interpreted Languages (Python, Node.js)**:
  - Run the affected script or test suite.
- If no test exists and the change is non-trivial, write a minimal unit test to confirm the fix before reporting completion.
