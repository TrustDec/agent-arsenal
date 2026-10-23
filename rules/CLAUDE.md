# CLAUDE.md - Senior Engineering Discipline & Anti-Hallucination Protocol

> Drop this file into your project root. Works out of the box with Claude Code, Cursor (`.cursorrules`), Pi, Codex, and OpenCode.

## 0. THE PRIME DIRECTIVES (NON-NEGOTIABLE)

1. **MINIMAL SURGICAL EDITS**: Never touch lines of code that do not strictly need changing. Do not reformat unchanged functions, do not reorder imports unless asked, do not "tidy up" surrounding code.
2. **NO PHANTOM FIXES**: Never assume a fix worked without concrete verification. If a test or command exists, run it. If there is a compiler/linter error, resolve the root cause—never suppress it with `any`, `@ts-ignore`, `unwrap()`, or empty `catch` blocks.
3. **NEVER HALLUCINATE PACKAGES**: Do not invent NPM/Cargo/PyPI libraries or methods. If unsure whether an API exists in a library version, check the local `node_modules`, `Cargo.lock`, or documentation before writing code.
4. **ASK BEFORE REFACTORING**: If you believe an architectural change or third-party dependency is required to solve the task, STOP and explain why first. Do not add dependencies or re-architect unilaterally.

---

## 1. CODE EDITING DISCIPLINE

- **Preserve Existing Patterns**: Mirror the naming conventions, error-handling idioms, and module layout of the host codebase.
- **Diff Minimization**: Your PR/diff should be easy for a human to review. A 2-line bug fix must NEVER result in a 50-line diff.
- **Fail Loudly & Explicitly**: Avoid silent fallbacks. When an invariant is broken, surface the error clearly instead of returning default mock objects that mask failures downstream.

---

## 2. THE 4-STEP EXECUTION PROTOCOL

When given a coding or debugging task, always follow this sequence:

1. **Investigate (Read-Only)**:
   - Read the relevant files first. Check call sites and imports.
   - Trace the actual data flow rather than guessing from function names.
2. **Hypothesize**:
   - Formulate a specific hypothesis about the root cause or required change.
3. **Surgically Implement**:
   - Apply the minimal change required to satisfy the requirement or resolve the bug.
4. **Empirically Verify**:
   - Run tests, compilers, or diagnostics. If something fails, do NOT guess again—read the error output thoroughly before taking the next action.

---

## 3. ZERO-AI-SLOP RULES (PROHIBITED HABITS)

- ❌ NEVER generate mock data placeholders (`// TODO: implement real logic`) inside what should be production code.
- ❌ NEVER delete comments, copyright notices, or existing type definitions without explicit instructions.
- ❌ NEVER replace working concrete implementations with generic over-abstracted classes, factory patterns, or unnecessary wrappers.
- ❌ NEVER write speculative code for "future extensibility" that was not requested.
