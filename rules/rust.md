# Rust Industrial Safety & Anti-Unwrap Rules

> Add these rules to your project if developing in Rust.

## 1. Zero Panics in Production Code
- ❌ **NEVER USE `.unwrap()` or `.expect()`** on production branches unless in unit test files or statically proven invariants (documented with a `// SAFETY:` comment).
- Always use `?` (early return with `anyhow::Result` / `thiserror`) or explicit pattern matching (`if let Some(...) = ...`, `match`).

## 2. Minimal Cloning & Zero Premature Allocation
- Do not add `.clone()` arbitrarily just to appease the borrow checker. Re-examine the data lifetime, borrow immutably (`&T` or `&str` instead of `String`), or pass references.
- Prefer `&str` and `&[T]` over `String` and `Vec<T>` in function input parameters.

## 3. Strict Verification Invariant
- Every time code is edited, the agent MUST run `cargo check` and `cargo test` before declaring completion.
- Compiler warnings are treated as errors. Clean up unused imports, dead variables, and missing documentation immediately.
