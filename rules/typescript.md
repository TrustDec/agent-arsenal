---
description: TypeScript & Node.js/Bun strict runtime discipline, zero-any enforcement, async promise safety, and ESM invariants
globs: **/*.{ts,mts,cts},**/tsconfig*.json
alwaysApply: false
---

# TypeScript & Runtime Production Invariants

> Add these rules to your project if developing in TypeScript, Node.js, Bun, or Deno (backends, full-stack apps, libraries, CLI tools, MCP servers).

## 1. Strict Type System & Zero-`any` Invariants
- ❌ **TOTAL BAN ON `any` AND UNVALIDATED CASTING (`as T`)**:
  - Never use `any` to silence compiler errors. Use `unknown` when the type is truly unknown, and narrow it before usage.
  - Never use blind type assertions (`const user = res.body as User`). TypeScript types are erased at compile time; `as T` provides zero runtime safety.
  - **Mandatory Runtime Validation at I/O Boundaries**:
    Every boundary crossing (HTTP requests/responses, database query results, environment variables, message queues, `JSON.parse()`, file reads, user input) MUST be validated at runtime using schemas (`Zod`, `Valibot`, `ArkType`, or type guards `x is T`):
    ```ts
    // ❌ AI Anti-Pattern: Phantom compile-time lie
    const payload = JSON.parse(rawText) as OrderRequest;
    await processOrder(payload.id); // Runtime crash if payload is null or missing id!

    // ✅ Production Discipline: Validated runtime invariant
    import { z } from 'zod';
    const OrderRequestSchema = z.object({
      id: z.string().uuid(),
      amount: z.number().positive(),
      currency: z.enum(['USD', 'EUR', 'GBP']),
    });

    const result = OrderRequestSchema.safeParse(JSON.parse(rawText));
    if (!result.success) {
      throw new ValidationError(`Invalid order payload: ${result.error.message}`);
    }
    await processOrder(result.data.id);
    ```
- ❌ **BAN ON NON-NULL ASSERTION OPERATOR (`!`)**:
  - Never slap `!` onto nullable properties (`user!.profile!.email`). If the value can be `null` or `undefined`, write an explicit guard or provide a safe nullish coalescing fallback (`user?.profile?.email ?? 'anonymous'`).
- **Discriminated Unions Over Bag-of-Optionals**:
  - Never model multi-state logic with overlapping optional fields:
    ```ts
    // ❌ AI Anti-Pattern: Allows impossible states (loading: true AND error: Error)
    interface FetchState<T> {
      isLoading?: boolean;
      data?: T;
      error?: Error;
    }

    // ✅ Production Discipline: Discriminated Union
    type FetchState<T> =
      | { status: 'idle' }
      | { status: 'loading' }
      | { status: 'success'; data: T }
      | { status: 'error'; error: Error };
    ```
- **Exhaustiveness Checking with `assertNever`**:
  - In `switch` or `if/else` ladders over discriminated unions, always enforce exhaustiveness checking:
    ```ts
    export function assertNever(x: never, message = `Unhandled variant: ${x}`): never {
      throw new Error(message);
    }
    ```

## 2. Asynchronous Safety & Promise Hygiene
- ❌ **ZERO FLOATING PROMISES**:
  - Every `Promise` MUST be explicitly `await`ed, returned, or handled via `.catch()`.
  - Never fire-and-forget an async function without attaching an unhandled rejection handler (`void asyncTask().catch(logError)`). Floating promises mask fatal background crashes.
- **`Promise.all` vs `Promise.allSettled` Invariant**:
  - Never use `Promise.all` for batch operations where one item's failure should not discard the successful results of all others. Use `Promise.allSettled()` and process results and rejections separately.
- **Mandatory `AbortSignal` Propagation**:
  - All long-running async I/O, HTTP requests (`fetch`), database queries, and worker loops MUST accept an optional `signal?: AbortSignal` and forward it downstream.
  - Always clean up abort event listeners: `signal?.addEventListener('abort', onAbort, { once: true })`.

## 3. Node.js & Bun Runtime Hygiene (Memory, Leaks & Streams)
- **Zero Event Listener Leaks**:
  - Every `emitter.on(...)` or `addEventListener(...)` MUST have a deterministic cleanup path (`emitter.off()`, `removeEventListener()`, or use `AbortSignal`).
  - Never ignore `MaxListenersExceededWarning`; it is a production blocker indicating an accumulating leak.
- **Bounded In-Memory Caching (Zero Unbounded Maps)**:
  - ❌ NEVER use a naked `const cache = new Map()` or `const set = new Set()` for caching in long-running processes. Unbounded collections cause out-of-memory (OOM) fatal kills.
  - Always use an LRU cache with an explicit maximum entry count or TTL expiration (e.g., `lru-cache`).
- **Stream Backpressure & Safe Piping**:
  - ❌ Never use raw `.pipe()` in production Node.js. It does NOT automatically destroy streams or forward errors when the destination stream fails.
  - Always use `pipeline` from `node:stream/promises` for safe error propagation and descriptor cleanup:
    ```ts
    import { pipeline } from 'node:stream/promises';
    import { createReadStream, createWriteStream } from 'node:fs';

    await pipeline(createReadStream(sourcePath), transformStream, createWriteStream(destPath));
    ```

## 4. Modern ESM & Module Resolution Discipline
- **Explicit `node:` Built-in Protocol**:
  - Always prefix Node.js core modules with `node:` (`node:fs/promises`, `node:path`, `node:crypto`, `node:os`).
- **ESM NodeNext Import Extensions**:
  - When targeting `moduleResolution: "NodeNext"` / `"nodenext"` or ESM packages, relative imports MUST include the `.js` extension (e.g., `import { helper } from './helper.js'`), even in TypeScript source files.
- **Zero Circular Dependencies**:
  - Circular imports lead to elusive `undefined` imports at runtime. Structure modules with a strict unidirectional dependency graph.

## 5. Verification Protocol
- Before submitting TypeScript changes, the agent MUST run:
  1. `tsc --noEmit` (or project build script): Zero type errors allowed.
  2. Test runner (`vitest run`, `jest`, `bun test`, or `npm test`): Zero test regressions allowed.
  3. Linter (`eslint` / `biome check`): Zero linter violations allowed.
