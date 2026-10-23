---
description: Svelte 5 Runes & SvelteKit strict reactivity discipline, SSR hydration hygiene, and modern full-stack invariants
globs: **/*.{svelte,svelte.ts,svelte.js,ts,js}
alwaysApply: false
---

# Svelte 5 & SvelteKit Strict Reactivity & Full-Stack Discipline

> Add these rules to your project if developing in Svelte 5 (Vite / SvelteKit) with TypeScript.

## 1. Svelte 5 Runes & Reactivity Invariants
- ❌ **STRICTLY BAN SVELTE 3/4 LEGACY SYNTAX**:
  - Never use `let count = 0; count++` expecting reactivity. Always declare reactive state with `$state()`: `let count = $state(0)`.
  - **Ban Reactive Declarations**: Never use `$: doubled = count * 2;`. Always use `$derived()`: `const doubled = $derived(count * 2)`.
  - **Ban Legacy Props**: Never use `export let foo = 'bar';`. Always use `$props()`: `let { foo = 'bar', ...rest }: Props = $props()`.
  - **Ban `<slot />` and `let:` syntax**: Always use Svelte 5 snippets (`{#snippet header(title)}...{/snippet}`) and render them with `{@render header('Title')}` or `{@render children?.()}`.
  - **Ban `createEventDispatcher()`**: Pass typed callback props directly (e.g. `onclick={() => onSelect(item.id)}` with `onSelect?: (id: string) => void`).
- ❌ **NEVER USE `$effect()` FOR DERIVED STATE**:
  - Do NOT synchronize state using `$effect()`. This causes unnecessary render cycles, layout thrashing, and infinite loop bugs:
    ```svelte
    <!-- ❌ AI Anti-Pattern -->
    <script lang="ts">
      let count = $state(0);
      let doubled = $state(0);
      $effect(() => { doubled = count * 2; });
    </script>

    <!-- ✅ Correct Svelte 5 Rune -->
    <script lang="ts">
      let count = $state(0);
      const doubled = $derived(count * 2);
    </script>
    ```
  - Use `$derived.by(() => { ... })` for complex, multi-statement derived computations.
  - `$effect()` is strictly reserved for side effects: DOM mutations, timers, analytics beacons, or third-party non-reactive integrations.
- **`$state()` vs `$state.raw()` Performance**:
  - Use `$state()` for objects, arrays, and primitives that require fine-grained property mutation tracking.
  - Use `$state.raw()` for large immutable payloads, raw API responses that are replaced wholesale, or third-party class instances (Three.js, Monaco, Leaflet, Web Audio) to prevent deep proxying overhead.

## 2. SvelteKit SSR & Hydration Hygiene
- ❌ **ZERO BROWSER GLOBALS IN TOP-LEVEL MODULE SCOPE**:
  - Never access `window`, `document`, `navigator`, `localStorage`, or `sessionStorage` in the root `<script>` scope or in server load functions.
  - Enclose client-only calls inside `onMount(() => { ... })` or guard with `if (browser)` imported from `$app/environment`.
- **Deterministic Initial Markup**:
  - Never generate non-deterministic markup (e.g., `Math.random()`, unseeded UUIDs, or client-locale timestamps) directly during SSR without matching client fallback. This causes hydration mismatch errors.
- **Data Loading Boundaries**:
  - Use `+page.server.ts` or `+layout.server.ts` for database calls, secret environment variables (`$env/static/private`), or direct ORM queries.
  - Universal `+page.ts` load functions must remain idempotent and safe to run in both server and browser runtimes.
  - Consume page data reactively via `let { data } = $props()`.

## 3. SvelteKit Form Actions & Progressive Enhancement
- **Prefer Form Actions over Manual Fetch**:
  - Use SvelteKit native actions in `+page.server.ts` (`export const actions = { default: async ({ request }) => { ... } }`) for standard CRUD operations.
  - Always progressively enhance forms using `use:enhance` from `$app/forms` to enable zero-JavaScript submission support with client-side smoothness:
    ```svelte
    <script lang="ts">
      import { enhance } from '$app/forms';
      let isSubmitting = $state(false);
    </script>

    <form method="POST" use:enhance={() => {
      isSubmitting = true;
      return async ({ update }) => {
        isSubmitting = false;
        await update();
      };
    }}>
      <button type="submit" disabled={isSubmitting}>Submit</button>
    </form>
    ```

## 4. Universal Reactivity in `.svelte.ts` & Context Isolation
- **Domain State with Runes Modules**:
  - Encapsulate reactive domain models in `.svelte.ts` (or `.svelte.js`) using Runes classes or functions:
    ```ts
    // cart.svelte.ts
    export class CartState {
      items = $state<Item[]>([]);
      total = $derived(this.items.reduce((sum, item) => sum + item.price, 0));

      add(item: Item) {
        this.items.push(item);
      }
    }
    ```
- ❌ **BAN SHARED MUTABLE SINGLETONS IN SSR**:
  - Never export a global mutable `$state` instance from a module file in a SvelteKit application. Shared module state will leak data between concurrent user requests on the Node/Edge server.
  - Always scope state to the component tree via `setContext()` and `getContext()` or initialize per-request state in `+layout.server.ts`.

## 5. Lifecycle Discipline & Resource Cleanup
- **Clean Teardown with `$effect` and `onMount`**:
  - Return a cleanup closure from `$effect` or `onMount` for all event listeners, intervals, animation frames, and observer subscriptions:
    ```ts
    $effect(() => {
      const controller = new AbortController();
      window.addEventListener('keydown', handleKeyDown, { signal: controller.signal });
      return () => controller.abort();
    });
    ```
- **Store Subscriptions**:
  - If consuming legacy Svelte stores or RxJS Observables, use the auto-subscription syntax (`$store`) only in `.svelte` files, or ensure manual `.subscribe()` calls have paired `unsubscribe()` teardowns.
