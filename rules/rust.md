---
description: Rust industrial safety, anti-unwrap enforcement, async Tokio discipline, and zero-panic invariants
globs: **/*.rs,**/Cargo.toml
alwaysApply: false
---

# Rust Industrial Safety & Production Invariants

> Add these rules to your project if developing in Rust (backends, microservices, CLI tools, WASM modules, or systems software).

## 1. Zero Panics in Production Code
- ❌ **TOTAL BAN ON `.unwrap()` AND `.expect()` IN PRODUCTION BRANCHES**:
  - Never call `.unwrap()` or `.expect()` in request handlers, message loops, parsing code, or worker tasks.
  - An `.unwrap()` panic terminates the process or poisons thread synchronization primitives.
  - The ONLY permitted exceptions are:
    1. Unit test modules (`#[cfg(test)]`).
    2. Statically verified, mathematically provable invariants, strictly accompanied by a preceding `// SAFETY:` rationale comment.
- **Idiomatic Error Propagation**:
  - Use `?` operator for clean early returns.
  - **Library Crates**: Model typed, exhaustive domain errors using `thiserror`. Never expose generic `anyhow::Error` or `Box<dyn Error>` in public crate APIs.
  - **Application Binaries / CLI**: Use `anyhow::Result<T>` or `eyre` with rich context:
    ```rust
    use anyhow::Context;

    let config = std::fs::read_to_string(&path)
        .with_context(|| format!("failed to read configuration file at '{}'", path.display()))?;
    ```

## 2. Async Safety & Tokio Runtime Discipline
- ❌ **NEVER BLOCK THE ASYNC EXECUTOR**:
  - Never execute synchronous, long-running CPU calculations, disk I/O, or blocking network calls directly on Tokio async worker threads. Doing so starves the runtime and causes latency spikes across the entire process.
  - Always offload blocking work to dedicated worker threads:
    ```rust
    // ✅ Production Discipline: Offload blocking work
    let hash = tokio::task::spawn_blocking(move || compute_expensive_hash(&data)).await?;
    ```
- **Mutex Discipline Across `.await` Points**:
  - ❌ **NEVER** hold a `std::sync::MutexGuard` across an `.await` boundary (compiler will warn that `Future` is not `Send` or cause runtime deadlocks).
  - Use `tokio::sync::Mutex` ONLY when locks must be held across `.await` points. For purely synchronous in-memory state, use `std::sync::Mutex` and drop the guard before awaiting.

## 3. Minimal Allocations & Zero-Copy Patterns
- **Borrowing Over Gratuitous Allocation**:
  - Do not slap `.clone()` or `.to_string()` arbitrarily just to satisfy the borrow checker. Re-examine ownership lifetimes, pass immutable references (`&str`, `&[T]`), or restructure data flow.
  - Use `Cow<'a, str>` or `Cow<'a, [u8]>` when data might be borrowed in standard execution but needs modification in edge cases.
- **Buffer Reuse**:
  - For high-throughput network or file streaming, use `bytes::Bytes` and `bytes::BytesMut` instead of allocating repeated `Vec<u8>` buffers.

## 4. Concurrency & Type-Level Safety
- **Atomic Primitives Over Heavy Locks**:
  - For simple counters, flags, and monotonically increasing sequence IDs, use `AtomicUsize`, `AtomicBool`, etc., with appropriate memory ordering (`Ordering::Relaxed` or `Ordering::AcqRel`) instead of wrapping primitives in a `Mutex`.
- **Exhaustive Matching & Invariant Guarantees**:
  - Never use wildcards (`_ => ...`) blindly on domain enums. Enforce compile-time exhaustiveness checks so adding a new variant fails compilation until handled explicitly.

## 5. Verification & Clippy Invariants
- **Machine-Verified Proof**:
  - Every modification MUST be verified by running `cargo check`, `cargo test`, and `cargo clippy --all-targets -- -D warnings`.
  - Zero compiler or clippy warnings are permitted in committed code. Dead code, unused imports, and unhandled results must be resolved immediately.
