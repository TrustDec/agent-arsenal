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

---

## 4. CONTEXT ECONOMY & PROGRESSIVE DISCLOSURE

- **Progressive Discovery**: Do not dump 1,000+ line files into the conversation context. Use `rg` or symbol search first, inspect the target function or interface slice with line offsets, and read the entire file only when structural refactoring is explicitly necessary.
- **Isolate Noisy Operations**: Run broad exploratory regex searches, heavy test suites, or large log dumps in sub-shells or isolated tool calls. Never pollute the primary conversation history with thousands of lines of terminal output.
- **The 3-Attempt Circuit Breaker**: If a compilation error or failing test is not resolved after 3 consecutive edits, STOP immediately. Do not make speculative random changes. Revert unverified edits (`git checkout -- <file>`), formulate a new root-cause hypothesis, or present the diagnostic findings to the user.
- **Prompt Prefix Cache Awareness**: Keep static repository guidelines and rules unchanged at the prompt prefix to benefit from KV cache acceleration. Append dynamic context, execution results, and diffs strictly to the tail.
- **Memory Bank & Compacting Protocol**: In complex multi-turn sessions, maintain a rolling compact state (`[Goal] -> [Verified Ground Truth] -> [Applied Diffs] -> [Next Action]`). When context approaches capacity, compress conversation turns into dense structured milestones to eliminate "Lost in the Middle" attention degradation.
- **Bounded Diagnostic Truncation**: When running tests or linters, extract only the failing trace and line numbers. Never ingest 500 lines of passing green tests into prompt memory.

---

## 5. EXECUTION & CLI DISCIPLINE

- **Non-Interactive Execution**: Always pass non-interactive flags (`-y`, `--yes`, `CI=true`) to package managers, migrations, and CLI tools to avoid hanging on unanswerable interactive prompts.
- **Bounded Command Outputs**: When inspecting logs or running test suites, use targeted filters, line limits, or `head`/`tail` to prevent dumping thousands of lines of terminal output into the context.
- **Clean Subprocess Lifecycles**: Never leave orphan background processes or dangling test servers running; ensure test runs and tools terminate cleanly with deterministic exit codes.


