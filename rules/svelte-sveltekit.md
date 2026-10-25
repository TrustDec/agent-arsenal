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

## 6. Modern UI Architecture, Frontend Taste & Accessibility (a11y)
- **Accessibility (a11y) & Headless Primitives**:
  - Build interactive widgets (modals, popovers, dropdowns, command palettes) with accessible headless primitives (Bits UI / Melt UI) rather than non-standard div wrappers.
  - Interactive elements must maintain visible keyboard focus indicators (`focus-visible:ring-2 focus-visible:outline-none`) and appropriate ARIA attributes (`aria-expanded`, `aria-haspopup`, `aria-selected`).
- **Seamless Page Transitions via View Transitions API**:
  - In SvelteKit, leverage native browser View Transitions inside `+layout.svelte` using `onNavigate()` for smooth, zero-jank page transitions:
    ```svelte
    <script lang="ts">
      import { onNavigate } from '$app/navigation';

      onNavigate((navigation) => {
        if (!document.startViewTransition) return;
        return new Promise((resolve) => {
          document.startViewTransition(async () => {
            resolve();
            await navigation.complete;
          });
        });
      });
    </script>
    ```
- **Responsive Media & `@sveltejs/enhanced-img`**:
  - Use `@sveltejs/enhanced-img` for image assets to automatically generate modern formats (AVIF, WebP), responsive `srcset` breakpoints, and intrinsic dimensions at build time, completely eliminating Cumulative Layout Shift (CLS).
- **Snippet Composition over Prop Drilling**:
  - Leverage Svelte 5 snippets (`{#snippet row(item)}...{/snippet}`) for template slot composition rather than passing deeply nested rendering callbacks or unwieldy configuration objects. Snippets keep view presentation declarative and close to where data lives.

## 7. Frontend Taste, Optimistic Mutations & Reactive Invariants
- **Untracked Reads with `untrack()`**:
  - When you need to read a reactive value inside an `$effect()` or `$derived()` WITHOUT subscribing to its changes, use `untrack()`:
    ```svelte
    <script lang="ts">
      import { untrack } from 'svelte';
      let page = $state(1);
      let query = $state('');

      $effect(() => {
        // Re-runs only when `query` changes, reading the current `page` without subscribing:
        console.log(`Search for: ${query} on page:`, untrack(() => page));
      });
    </script>
    ```
- **Optimistic UI Mutations in SvelteKit Form Actions**:
  - With SvelteKit's `use:enhance`, update local list or card state instantly, then reconcile or rollback if the server responds with a validation or transaction error:
    ```svelte
    <form method="POST" action="?/deleteItem" use:enhance={() => {
      const removedIndex = items.findIndex(i => i.id === targetId);
      const [removedItem] = items.splice(removedIndex, 1); // Optimistic immediate deletion

      return async ({ result, update }) => {
        if (result.type === 'failure' || result.type === 'error') {
          items.splice(removedIndex, 0, removedItem); // Rollback on failure
        }
        await update({ reset: false });
      };
    }}>
      <button type="submit">Delete</button>
    </form>
    ```
- **Physics-Based Transitions (`svelte/motion`) vs Mechanical Easing**:
  - For drag, pan, or floating indicators (active tab indicator pill), use `spring()` from `svelte/motion` rather than rigid CSS linear transitions. Natural damping and stiffness produce an organic, Apple/Vercel-tier tactile feel.
- **Focus Restoration & Keyboard Dialog Ergonomics**:
  - When dismissing modals, popovers, or sheets via `Escape` or backdrop clicks, programmatically restore keyboard focus to the triggering element:
    ```svelte
    <script lang="ts">
      let triggerButton: HTMLButtonElement | null = null;
      let isOpen = $state(false);

      function closeModal() {
        isOpen = false;
        triggerButton?.focus();
      }
    </script>
    ```
- **Svelte 5 Snippets over Legacy Slots**:
  - In Svelte 5, `<slot>` is completely deprecated. Use typed Snippets for flexible, parameter-safe component composition:
    ```svelte
    <script lang="ts">
      import type { Snippet } from 'svelte';
      let { children, header }: { children: Snippet; header?: Snippet<[string]> } = $props();
    </script>

    {#if header}
      {@render header('Section Title')}
    {/if}
    {@render children()}
    ```
- **Untracked Reactive Reads with `untrack()`**:
  - In `$effect()` or `$derived.by()`, when you need to inspect a reactive value without registering it as an active dependency, wrap the read in `untrack()`:
    ```svelte
    $effect(() => {
      // Runs only when `count` changes; reading `analyticsId` will NOT re-trigger this effect
      sendAnalytics(count, untrack(() => analyticsId));
    });
    ```
- **SvelteKit Streaming Data in `PageServerLoad`**:
  - Stream slow, non-critical database queries by returning un-awaited Promises from `+page.server.ts`:
    ```ts
    export const load: PageServerLoad = async () => {
      return {
        criticalUser: await getUser(), // Blocks SSR until ready
        streamedFeed: getSlowFeed(),    // Streams concurrently without blocking initial HTML
      };
    };
    ```
  - In the template, use `<svelte:boundary>` and Svelte 5 snippets to render instant skeletons while the stream resolves.
- **Svelte 5 `$bindable()` Runes Discipline**:
  - In Svelte 5, two-way bindings via `bind:prop` are strictly prohibited on component props unless the component explicitly declares the prop with `$bindable()`:
    ```svelte
    <script lang="ts">
      // ✅ Explicit two-way binding contract with optional fallback default
      let { value = $bindable(''), disabled = false }: { value?: string; disabled?: boolean } = $props();
    </script>
    <input bind:value {disabled} />
    ```
  - This prevents accidental child-to-parent mutation leaks and guarantees an explicit contract at the component boundary.
- **Universal Cross-Component Reactivity with `.svelte.ts`**:
  - Replace legacy Svelte 3/4 `writable()` / `readable()` stores with native runes inside `.svelte.ts` modules:
    ```ts
    // theme.svelte.ts
    class ThemeState {
      current = $state<'light' | 'dark'>('dark');

      toggle() {
        this.current = this.current === 'dark' ? 'light' : 'dark';
      }
    }
    export const theme = new ThemeState();
    ```
  - Any Svelte component importing `theme` reacts to `theme.current` changes automatically with zero manual subscriptions or `$` prefix dereferencing.
- **Form Action Validation Ergonomics with `fail()`**:
  - In `+page.server.ts` actions, never return raw unstatused objects on client validation errors:
    ```ts
    import { fail } from '@sveltejs/kit';

    export const actions = {
      default: async ({ request }) => {
        const data = await request.formData();
        const email = data.get('email');
        if (!email || typeof email !== 'string') {
          return fail(400, { email, missing: true, message: 'Valid email address is required.' });
        }
      }
    };
    ```
  - SvelteKit maps the failed response to `form` in `let { form } = $props()`, preserving user input and rendering accessible inline error messages without page reload.
- **Svelte 5 `$derived.by()` Multi-Statement Derivations**:
  - For complex derived values requiring branching, loops, or error handling, use `$derived.by()` with a closure:
    ```svelte
    <script lang="ts">
      let items = $state<Item[]>([]);
      // ✅ Invariant: $derived.by encapsulates multi-statement logic cleanly
      let activeTotal = $derived.by(() => {
        let sum = 0;
        for (const item of items) {
          if (item.active) sum += item.price;
        }
        return sum;
      });
    </script>
    ```
- **SvelteKit Granular Cache Invalidation (`invalidate` over `invalidateAll`)**:
  - ❌ **NEVER invoke `invalidateAll()` as a lazy shortcut** after every mutation:
    - `invalidateAll()` re-executes EVERY active `load` function in the current layout and page hierarchy, triggering waterfall queries and thrashing server cache.
  - ✅ **Invariant**: Target the specific dependency using `invalidate(url)` or predicate matcher:
    ```ts
    import { invalidate } from '$app/navigation';

    // Target only the relevant data dependency:
    await invalidate('/api/cart');
    // Or match by URL pattern:
    await invalidate((url) => url.pathname.startsWith('/api/orders'));
    ```
- **Svelte 5 Snippets & Render Directives (`{#snippet}` & `{@render}`)**:
  - ❌ **TOTAL BAN ON DEPRECATED `<slot />` AND `let:` DIRECTIVES**:
    - Svelte 5 completely deprecates legacy slot syntax in favor of first-class snippets with typed arguments.
  - ✅ **Production Invariant**: Use `{#snippet name(args)}` and `{@render name(args)}` for component composition:
    ```svelte
    <!-- List.svelte -->
    <script lang="ts" generics="T">
      import type { Snippet } from 'svelte';
      let { items, row }: { items: T[]; row: Snippet<[T]> } = $props();
    </script>

    <ul>
      {#each items as item}
        <li>{@render row(item)}</li>
      {/each}
    </ul>

    <!-- Consuming component -->
    <List items={users}>
      {#snippet row(user)}
        <span>{user.name} ({user.email})</span>
      {/snippet}
    </List>
    ```
- **Optimistic UI with `use:enhance` and Svelte 5 `$state`**:
  - Provide instant UI feedback for user actions (like toggling a todo or liking a post) with automatic rollback on server error:
    ```svelte
    <script lang="ts">
      import { enhance } from '$app/forms';
      let completed = $state(false);
    </script>

    <form 
      method="POST" 
      action="?/toggle" 
      use:enhance={() => {
        // 1. Optimistically flip UI state immediately before network request
        const previous = completed;
        completed = !completed;

        return async ({ result, update }) => {
          if (result.type === 'failure' || result.type === 'error') {
            // 2. Roll back optimistic state on failure
            completed = previous;
          }
          await update({ reset: false });
        };
      }}
    >
      <button type="submit">{completed ? 'Mark Incomplete' : 'Mark Complete'}</button>
    </form>
    ```

---

## 8. Effect Timing (`$effect.pre`), `untrack()` Dependency Isolation & Server Boundaries
- **DOM Pre-Paint Measurements with `$effect.pre`**:
  - `$effect()` executes *after* the DOM has been updated and painted. If you need to read or adjust DOM geometry *before* the browser paints (e.g., preserving scroll positions when prepending messages to a chat thread):
    ```svelte
    <script lang="ts">
      let messages = $state<string[]>([]);
      let container: HTMLElement;
      let previousScrollHeight = 0;

      $effect.pre(() => {
        // Access messages to create dependency
        messages;
        if (container) {
          previousScrollHeight = container.scrollHeight;
        }
      });

      $effect(() => {
        // After DOM updates, adjust scroll to prevent jump
        if (container) {
          container.scrollTop += container.scrollHeight - previousScrollHeight;
        }
      });
    </script>
    ```
- **Intentional Dependency Exclusion with `untrack()`**:
  - When an effect needs to read a reactive value without re-triggering whenever that specific value changes, wrap the read in `untrack()`:
    ```svelte
    <script lang="ts">
      import { untrack } from 'svelte';

      let { activeTab, telemetryToken }: { activeTab: string; telemetryToken: string } = $props();

      $effect(() => {
        // Effect tracks changes to activeTab:
        const currentTab = activeTab;

        // Reads telemetryToken WITHOUT re-running this effect when token refreshes:
        const token = untrack(() => telemetryToken);

        sendAnalytics(currentTab, token);
      });
    </script>
    ```
- **SvelteKit Server Security Boundaries (`+page.server.ts` vs `+page.ts`)**:
  - ❌ **The Universal Load Secret Leak**: Placing database credentials, ORM queries (`db.query...`), or third-party secret API keys in `+page.ts` leaks private code and tokens into the browser client bundle because universal `load` runs on both server and client.
  - ✅ **Production Security Invariant**:
    - All database queries, secret token operations, and mutations MUST be defined strictly in `+page.server.ts` or `+server.ts`.
    - Universal `+page.ts` should only be used when fetching publicly cacheable data or executing client-side redirects.
- **Streaming Non-Blocking Deferred Promises in SvelteKit `load`**:
  - ❌ **The Waterfall TTFB Bottleneck**: Awaiting slow third-party analytics or recommendation calls directly in `load` blocks the HTTP response from starting, causing high Time To First Byte (TTFB).
  - ✅ **Production Invariant**: Return the unresolved promise directly without `await` to let SvelteKit stream the page shell immediately, resolving data client-side with `{#await}`:
    ```ts
    // src/routes/dashboard/+page.server.ts
    export const load: PageServerLoad = async ({ locals }) => {
      return {
        // Critical data awaited immediately for fast SSR shell:
        user: await locals.auth.getUser(),
        // Non-critical data streamed asynchronously via unawaited promise:
        recommendations: fetchPersonalizedRecommendations(locals.userId)
      };
    };
    ```
    ```svelte
    <!-- src/routes/dashboard/+page.svelte -->
    <script lang="ts">
      let { data } = $props();
    </script>

    <h1>Welcome, {data.user.name}</h1>

    {#await data.recommendations}
      <div class="skeleton-loader">Loading recommendations...</div>
    {:then items}
      <ul>
        {#each items as item}
          <li>{item.title}</li>
        {/each}
      </ul>
    {:catch error}
      <p class="error">Failed to load recommendations.</p>
    {/await}
    ```
- **Internal Service Auth & Request Rewriting with `handleFetch`**:
  - ❌ **The SSR Cookie / Header Loss Trap**: When a SvelteKit `load` function on the server calls `fetch('/api/v1/user')`, the browser's incoming cookies and authorization headers are NOT automatically attached to internal sub-requests, causing spurious 401 Unauthorized errors during SSR.
  - ✅ **Production Invariant**: Implement `handleFetch` in `src/hooks.server.ts` to forward authorization headers and route requests to internal service addresses directly:
    ```ts
    // src/hooks.server.ts
    import type { HandleFetch } from '@sveltejs/kit';

    export const handleFetch: HandleFetch = async ({ event, request, fetch }) => {
      // If fetching an internal API route from server-side load:
      if (request.url.startsWith('https://api.internal.example.com')) {
        // Forward incoming Authorization or Cookie header:
        const token = event.cookies.get('session_token');
        if (token) {
          request.headers.set('Authorization', `Bearer ${token}`);
        }
      }

      return fetch(request);
    };
    ```
- **Transient UI & Scroll Preservation with SvelteKit `snapshot`**:
  - ❌ Users filling out an uncommitted form navigate away, press the browser back button, and find their inputs completely wiped.
  - ✅ **Production Invariant**: Use the `snapshot` API to preserve and restore ephemeral DOM/state across client-side history navigation:
    ```svelte
    <!-- src/routes/draft/+page.svelte -->
    <script lang="ts">
      import type { Snapshot } from './$types';

      let comment = $state('');

      export const snapshot: Snapshot<string> = {
        capture: () => comment,
        restore: (value) => {
          comment = value;
        }
      };
    </script>

    <textarea bind:value={comment} placeholder="Write draft..."></textarea>
    ```
- **Svelte 5 Universal Reactivity Boundaries: Absolute Ban on Synchronous `$effect` Mutations**:
  - ❌ **The Cascading Reactive Loop & Microtask Starvation**: Mutating a `$state` signal directly inside an `$effect` block synchronously triggers cascading re-renders, cyclic microtask scheduling, and runtime crashes (`Maximum update depth exceeded`).
  - ✅ **Production Invariant**:
    - Reserve `$effect` exclusively for leaf-node imperative side effects (DOM measurements, canvas rendering, third-party library lifecycle bridges, local storage synchronization).
    - If a value depends on other reactive state, ALWAYS use `$derived` or `$derived.by`:
      ```svelte
      <script lang="ts">
        let count = $state(0);

        // ❌ NEVER DO THIS:
        // let doubled = $state(0);
        // $effect(() => { doubled = count * 2; });

        // ✅ INVARIANT: Pure, zero-overhead derived calculation:
        let doubled = $derived(count * 2);

        // ✅ Complex derivations using derived.by:
        let filteredItems = $derived.by(() => {
          return items.filter(item => item.score > count);
        });
      </script>
      ```
- **SvelteKit Progressive Enhancement Form Actions & CSRF Defense**:
  - ❌ **The JS-Only Form & CSRF Bypass Vulnerability**: Submitting forms via ad-hoc client-side `fetch` requires custom CSRF header plumbing. If JavaScript fails to load or an extension interferes, the form becomes completely inert.
  - ✅ **Production Invariant**: Always use SvelteKit Form Actions with `use:enhance`. SvelteKit automatically enforces Origin header verification against Cross-Site Request Forgery (CSRF) and gracefully falls back to native standard POST when JavaScript is unavailable:
    ```svelte
    <script lang="ts">
      import { enhance } from '$app/forms';

      let isSubmitting = $state(false);
    </script>

    <form
      method="POST"
      action="?/updateProfile"
      use:enhance={() => {
        isSubmitting = true;
        return async ({ update }) => {
          await update();
          isSubmitting = false;
        };
      }}
    >
      <input name="displayName" required />
      <button type="submit" disabled={isSubmitting}>Save Profile</button>
    </form>
    ```

---

## 9. Svelte 5 Class Stores, Snippet Composition (`{@render}`) & Streaming Promises
- **Universal Svelte 5 State Classes in `.svelte.ts`**:
  - ❌ **The Svelte 4 Writable Store Boilerplate Trap**: Using `writable()`, `$derived` wrappers, and manual subscription cleanup in shared utility modules creates verbose boilerplate and memory leak risks.
  - ✅ **Production Invariant**: Encapsulate complex business state in TypeScript classes with `$state` and getters inside `.svelte.ts` files:
    ```ts
    // src/lib/stores/cart.svelte.ts
    export class CartState {
      items = $state<{ id: string; price: number; quantity: number }[]>([]);

      total = $derived(
        this.items.reduce((sum, item) => sum + item.price * item.quantity, 0)
      );

      addItem(id: string, price: number) {
        const existing = this.items.find((i) => i.id === id);
        if (existing) {
          existing.quantity += 1;
        } else {
          this.items.push({ id, price, quantity: 1 });
        }
      }
    }
    ```
- **Type-Safe Snippets & Composition (`{#snippet}` and `{@render}`)**:
  - ❌ **The Deprecated Slot Syntax**: In Svelte 5, `<slot>` and `let:prop` are deprecated. Relying on legacy slots causes deprecation warnings and prevents fine-grained prop typing.
  - ✅ **Production Invariant**: Use `{#snippet}` and `{@render}` for flexible, type-safe template composition:
    ```svelte
    <script lang="ts">
      import type { Snippet } from 'svelte';

      interface Props {
        header: Snippet<[{ title: string }]>;
        children: Snippet;
      }

      let { header, children }: Props = $props();
    </script>

    <div class="card">
      <header>
        {@render header({ title: 'Workspace Dashboard' })}
      </header>
      <main>
        {@render children()}
      </main>
    </div>
    ```
- **SvelteKit Deferred Streaming with Server Promises (`{#await}`)**:
  - ❌ **The Slow SSR TTFB Bottleneck**: Awaiting slow secondary API queries (e.g. recommendations, analytics, heavy joins) in `+page.server.ts` blocks the entire server response, inflating Time to First Byte (TTFB) to multiple seconds.
  - ✅ **Production Invariant**: Return un-awaited promises from `load` functions to stream fast HTML immediately, rendering skeletons with `{#await}` while the slow data streams over HTTP:
    ```ts
    // src/routes/dashboard/+page.server.ts
    export const load = async ({ fetch }) => {
      // Fast critical data (awaited):
      const user = await fetch('/api/user').then((r) => r.json());

      // Slow non-critical data (streamed un-awaited promise):
      const slowStatsPromise = fetch('/api/heavy-stats').then((r) => r.json());

      return {
        user,
        streamed: { stats: slowStatsPromise },
      };
    };
    ```
    ```svelte
    <!-- src/routes/dashboard/+page.svelte -->
    <script lang="ts">
      let { data } = $props();
    </script>

    <h1>Welcome, {data.user.name}</h1>

    {#await data.streamed.stats}
      <div class="skeleton-loader">Loading analytics...</div>
    {:then stats}
      <div class="stats-panel">{stats.revenueToday}</div>
    {:catch error}
      <p class="error">Failed to load statistics.</p>
    {/await}
    ```

---

## 10. Svelte 5 `$bindable` Contracts, SvelteKit `use:enhance` & Ephemeral Snapshot State
- **Explicit Two-Way Prop Contracts with `$bindable()` (Svelte 5)**:
  - ❌ **The Read-Only Prop Binding Error**: In Svelte 5, component props are immutable by default. Attempting `bind:value` on a child prop without declaring it as `$bindable()` causes compile-time errors or broken reactivity.
  - ✅ **Production Invariant**: Explicitly mark two-way bindable props using `$bindable()` with fallback defaults:
    ```svelte
    <!-- src/lib/components/NumberInput.svelte -->
    <script lang="ts">
      let {
        value = $bindable(0),
        min = 0,
        max = 100,
      }: { value?: number; min?: number; max?: number } = $props();
    </script>

    <input
      type="number"
      {min}
      {max}
      bind:value
      class="rounded-lg border px-3 py-2"
    />
    ```
- **SvelteKit Form Actions with Progressive Enhancement (`use:enhance`)**:
  - ❌ **The JavaScript-Dependent Form Submission**: Submitting forms via client-side `fetch` breaks when JavaScript is loading or blocked, and loses native form validation, browser autofill, and automatic CSRF handling.
  - ✅ **Production Invariant**: Use standard HTML forms enhanced progressively with `use:enhance` for optimistic updates and automatic hydration:
    ```svelte
    <script lang="ts">
      import { enhance } from '$app/forms';
      let isSubmitting = $state(false);
    </script>

    <form
      method="POST"
      action="?/createInvoice"
      use:enhance={() => {
        isSubmitting = true;
        return async ({ update }) => {
          isSubmitting = false;
          await update();
        };
      }}
    >
      <input type="text" name="customerName" required />
      <button type="submit" disabled={isSubmitting}>
        {isSubmitting ? 'Creating...' : 'Create Invoice'}
      </button>
    </form>
    ```
- **Ephemeral State Preservation across Navigation with `snapshot`**:
  - ❌ **The Lost Multi-Step Filter / Form State**: When a user navigates away from a deep search or multi-step form to view a detail page and hits browser Back, standard `$state` is reset to defaults, destroying user inputs.
  - ✅ **Production Invariant**: Export a `snapshot` object in `+page.svelte` to preserve ephemeral state in session history:
    ```svelte
    <script lang="ts">
      import type { Snapshot } from './$types';

      let searchQuery = $state('');
      let filterTag = $state('all');

      export const snapshot: Snapshot<{ searchQuery: string; filterTag: string }> = {
        capture: () => ({ searchQuery, filterTag }),
        restore: (values) => {
          searchQuery = values.searchQuery;
          filterTag = values.filterTag;
        },
      };
    </script>
    ```

---

## 11. Svelte 5 Typed Callback Props, SvelteKit `handleFetch` & Targeted Invalidation
- **Svelte 5 Typed Callback Props over Deprecated `createEventDispatcher` and `on:click`**:
  - ❌ **The Legacy Event Dispatcher Boilerplate**: In Svelte 5, using `createEventDispatcher()` or directive syntax (`on:select`) is deprecated. It introduces runtime event bubbling overhead and lacks native TypeScript return inference.
  - ✅ **Production Invariant**: Declare typed callback props directly in `$props()`:
    ```svelte
    <!-- src/lib/components/Modal.svelte -->
    <script lang="ts">
      let {
        title,
        onConfirm,
        onClose,
      }: {
        title: string;
        onConfirm: () => Promise<void> | void;
        onClose: () => void;
      } = $props();
    </script>

    <div class="modal">
      <h2>{title}</h2>
      <button onclick={onClose}>Cancel</button>
      <button onclick={onConfirm}>Confirm</button>
    </div>
    ```
- **SvelteKit `handleFetch` Internal Service Auth & Host Rewriting**:
  - ❌ **The Server-Side DNS Loop & Lost Auth Cookies**: When SvelteKit SSR calls internal microservices or API endpoints via `fetch('/api/...)`, it executes an external HTTP round-trip without user session cookies unless explicitly forwarded.
  - ✅ **Production Invariant**: Implement `handleFetch` in `src/hooks.server.ts` to clone requests, forward incoming cookies, and route directly to internal service addresses:
    ```ts
    // src/hooks.server.ts
    import type { HandleFetch } from '@sveltejs/kit';

    export const handleFetch: HandleFetch = async ({ event, request, fetch }) => {
      // Forward authentication cookie to internal API endpoints:
      if (request.url.startsWith('https://api.internal/')) {
        request.headers.set('cookie', event.request.headers.get('cookie') || '');
      }

      return fetch(request);
    };
    ```
- **SvelteKit Page Invalidation Precision (`invalidate(url)` vs `invalidateAll()`)**:
  - ❌ **The Brutal `invalidateAll()` Refetch Storm**: Calling `invalidateAll()` upon small user interactions forces every `load` function on the page (user profile, navigation counts, heavy data tables) to re-run concurrently.
  - ✅ **Production Invariant**: Use targeted URL invalidation or `depends` tags to refresh only the exact data affected:
    ```svelte
    <script lang="ts">
      import { invalidate } from '$app/navigation';

      async function refreshInvoices() {
        // Re-runs only load functions that depend on '/api/invoices':
        await invalidate('/api/invoices');
      }
    </script>
    ```
- **SvelteKit Server-Sent Events (SSE) Streaming & Connection Cleanup**:
  - ❌ **The Dangling SSE Connection & Leaked Timer**: Returning a raw text stream without listening to client cancellation leaves infinite background tickers running and leaking memory on the Node/Bun server after the client closes the browser tab.
  - ✅ **Production Invariant**: Implement native `ReadableStream` and listen to `request.signal.addEventListener('abort', ...)`:
    ```ts
    // src/routes/api/events/+server.ts
    import type { RequestHandler } from './$types';

    export const GET: RequestHandler = ({ request }) => {
      let intervalId: ReturnType<typeof setInterval>;

      const stream = new ReadableStream({
        start(controller) {
          intervalId = setInterval(() => {
            const data = JSON.stringify({ timestamp: Date.now() });
            controller.enqueue(`data: ${data}\n\n`);
          }, 1000);

          request.signal.addEventListener('abort', () => {
            clearInterval(intervalId);
            controller.close();
          });
        },
        cancel() {
          clearInterval(intervalId);
        }
      });

      return new Response(stream, {
        headers: {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
        },
      });
    };
    ```
- **Svelte 5 Rune `$inspect` Deep Diagnostics vs Zero Production Overhead**:
  - ❌ **The Reactive Proxy Log Pollution**: Logging Svelte 5 `$state` proxies via `console.log(state)` prints cryptic internal reactive proxies instead of current snapshot values. Leaving console logs in production bundles bloats client assets.
  - ✅ **Production Invariant**: Use the Svelte 5 `$inspect` rune with `.with(...)`. The Svelte compiler automatically strips all `$inspect(...)` calls in production builds (`NODE_ENV=production`):
    ```svelte
    <script lang="ts">
      let formState = $state({ username: '', permissions: [] as string[] });

      // Completely removed by the compiler in production builds:
      $inspect(formState).with((type, val) => {
        console.debug(`[FormState ${type}]`, val);
      });
    </script>
    ```
- **SvelteKit Progressive Enhancement Form Actions with Pending State UI Lockout**:
  - ❌ **The Double-Click Transaction Duplication**: Users on slow mobile networks frequently tap submit buttons multiple times. Without disabling UI controls during in-flight form action mutations, duplicate backend mutations occur.
  - ✅ **Production Invariant**: Use `use:enhance` with an optimistic pending lock:
    ```svelte
    <script lang="ts">
      import { enhance } from '$app/forms';

      let isSubmitting = $state(false);
    </script>

    <form
      method="POST"
      action="?/createInvoice"
      use:enhance={() => {
        isSubmitting = true;
        return async ({ update }) => {
          await update();
          isSubmitting = false;
        };
      }}
    >
      <input type="text" name="customer" required />
      <button type="submit" disabled={isSubmitting}>
        {isSubmitting ? 'Processing...' : 'Create Invoice'}
      </button>
    </form>
    ```
- **SvelteKit `sequence` Helper for Modular Server Middleware Hooks (`hooks.server.ts`)**:
  - ❌ **The Monolithic Hook Anti-Pattern**: Combining authentication, tenant extraction, CSRF validation, and telemetry inside a single massive `handle` function in `src/hooks.server.ts` creates tight coupling and makes unit testing impossible.
  - ✅ **Production Invariant**: Compose modular handlers using the official `sequence` helper:
    ```ts
    // src/hooks.server.ts
    import { sequence } from '@sveltejs/kit/hooks';
    import type { Handle } from '@sveltejs/kit';

    const auth: Handle = async ({ event, resolve }) => {
      event.locals.user = await authenticateRequest(event);
      return resolve(event);
    };

    const telemetry: Handle = async ({ event, resolve }) => {
      const start = performance.now();
      const response = await resolve(event);
      const duration = performance.now() - start;
      response.headers.set('Server-Timing', `total;dur=${duration.toFixed(2)}`);
      return response;
    };

    export const handle: Handle = sequence(auth, telemetry);
    ```
- **Svelte 5 Deep Reactive Proxy Mutation vs Unnecessary Object Spreading**:
  - ❌ **The Legacy Svelte 4 Spread Boilerplate**: In Svelte 5, using `state = { ...state, key: val }` or `array = [...array, newItem]` on `$state` objects triggers unnecessary object reallocations and breaks fine-grained signals.
  - ✅ **Production Invariant**: Svelte 5 `$state` creates deep reactive proxies. Mutate object properties and array elements directly in place:
    ```svelte
    <script lang="ts">
      let user = $state({ profile: { name: 'Alice', visits: 0 } });
      let items = $state<string[]>([]);

      function recordVisit(item: string) {
        // Direct fine-grained mutation in Svelte 5:
        user.profile.visits++;
        items.push(item);
      }
    </script>
    ```
- **Svelte 5 `$derived.by()` for Multi-Branch Computations vs Abusive IIFEs**:
  - ❌ **The Single-Line Ternary / IIFE Anti-Pattern**: Trying to squeeze complex derivations with loops, intermediate variables, or branching into `$derived(a ? b : c ? d : e)` or wrapping an IIFE `$derived((() => { ... })())`.
  - ✅ **Production Invariant**: Use Svelte 5 native `$derived.by` for multi-statement computed logic:
    ```svelte
    <script lang="ts">
      let orders = $state<Order[]>([]);
      let filterStatus = $state('shipped');

      // Clean, expressive multi-statement signal derivation:
      let totalFilteredRevenue = $derived.by(() => {
        let sum = 0;
        for (const order of orders) {
          if (order.status === filterStatus) {
            sum += order.totalCents;
          }
        }
        return sum / 100;
      });
    </script>
    ```
- **SvelteKit `depends()` Custom Keys & Granular `invalidate()` Hygiene**:
  - ❌ **Brittle URL Invalidation**: Coupling load cache invalidation to hardcoded API URL strings (`invalidate('/api/projects')`), which silently breaks when backend routes or query params change.
  - ✅ **Production Invariant**: Register semantic dependency keys using `depends()` inside `load` functions and trigger targeted invalidation using `invalidate('app:projects')`:
    ```ts
    // src/routes/dashboard/+page.ts
    export const load = async ({ fetch, depends }) => {
      // Register custom semantic dependency:
      depends('data:notifications');
      const res = await fetch('/api/v2/user/notifications');
      return { notifications: await res.json() };
    };
    ```
    ```svelte
    <!-- src/routes/dashboard/+page.svelte -->
    <script lang="ts">
      import { invalidate } from '$app/navigation';

      async function markAllRead() {
        await fetch('/api/v2/notifications/read-all', { method: 'POST' });
        // Granular cache refresh matching custom key:
        await invalidate('data:notifications');
      }
    </script>
    ```
- **Svelte 5 `$host()` Rune for Web Components & Custom Elements**:
  - ❌ **Legacy Component Host Access**: Attempting to access custom element host properties or dispatch custom DOM events across the Shadow DOM boundary via hacky `document.querySelector` or deprecated `createEventDispatcher`.
  - ✅ **Production Invariant**: In Svelte 5 custom elements (`<svelte:options customElement="x-element" />`), use `$host()` to obtain a direct reference to the enclosing Custom Element instance:
    ```svelte
    <svelte:options customElement="project-badge" />

    <script lang="ts">
      let { title = 'Active' } = $props<{ title?: string }>();
      
      // Svelte 5: Direct, type-safe custom element host reference
      const hostElement = $host<HTMLElement>();

      function emitCustomEvent() {
        hostElement.dispatchEvent(new CustomEvent('badge-click', {
          bubbles: true,
          composed: true, // Cross shadow DOM boundaries cleanly
          detail: { title },
        }));
      }
    </script>

    <button onclick={emitCustomEvent} class="px-2 py-1 bg-zinc-900 text-zinc-100 rounded text-xs">
      {title}
    </button>
    ```
- **SvelteKit Server Route Streaming via `ReadableStream` & Controller Invariants**:
  - ❌ **Memory Buffering LLM / NDJSON Responses**: Awaiting an entire stream or large dataset in `+server.ts` before calling `json(fullPayload)` creates long multi-second TTFB, memory spikes, and poor user responsiveness.
  - ✅ **Production Invariant**: Return a native streaming `Response` utilizing `ReadableStream` with proper chunk encoding and client abort cancellation:
    ```ts
    // src/routes/api/stream/+server.ts
    import type { RequestHandler } from './$types';

    export const GET: RequestHandler = ({ request }) => {
      const encoder = new TextEncoder();

      const stream = new ReadableStream({
        async start(controller) {
          // Listen to client disconnect signal
          request.signal.addEventListener('abort', () => {
            controller.close();
          });

          for (let i = 0; i < 5; i++) {
            if (request.signal.aborted) break;
            controller.enqueue(encoder.encode(`data: ${JSON.stringify({ step: i, ts: Date.now() })}\n\n`));
            await new Promise((r) => setTimeout(r, 100));
          }
          controller.close();
        },
      });

      return new Response(stream, {
        headers: {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
        },
      });
    };
    ```
- **SvelteKit `data-sveltekit-preload-data="hover"` vs `"tap"` Invariant**:
  - ❌ **Network Flooding on Data Tables & Long Feeds**: Placing `data-sveltekit-preload-data="hover"` on high-density list items, search result feeds, or data tables. Casual pointer movement over dozens of rows triggers concurrent `load` function executions, exhausting browser connection limits and overloading backend servers.
  - ✅ **Production Invariant**: Scope `"hover"` exclusively to high-intent primary navigation (e.g. main navbar, primary CTA buttons). For dense lists and tables, use `"tap"` (which initiates preloading on `touchstart` / `mousedown` with zero accidental hover network thrashing):
    ```svelte
    <!-- High-intent navigation: hover is safe -->
    <nav data-sveltekit-preload-data="hover">
      <a href="/dashboard">Dashboard</a>
    </nav>

    <!-- Dense list / data tables: enforce tap preloading -->
    <ul data-sveltekit-preload-data="tap">
      {#each items as item (item.id)}
        <li><a href="/items/{item.id}">{item.name}</a></li>
      {/each}
    </ul>
    ```
- **Svelte 5 Recursive Snippet Safeguards & Depth Guard Invariant**:
  - ❌ **Call Stack Overflow on Cyclic or Deep Data**: Invoking a recursive Svelte 5 snippet without a termination depth guard. If user data contains unexpected circular references (nested comments, category trees), the browser throws `Maximum call stack size exceeded` and freezes the page.
  - ✅ **Production Invariant**: Pass an explicit depth counter to recursive snippets and enforce a hard rendering ceiling:
    ```svelte
    <script lang="ts">
      interface CategoryNode {
        id: string;
        name: string;
        children?: CategoryNode[];
      }

      let { tree }: { tree: CategoryNode[] } = $props();
      const MAX_DEPTH = 8;
    </script>

    {#snippet renderTree(nodes: CategoryNode[], depth: number)}
      {#if depth < MAX_DEPTH}
        <ul class="pl-4 border-l border-zinc-200">
          {#each nodes as node (node.id)}
            <li>
              <span>{node.name}</span>
              {#if node.children && node.children.length > 0}
                {@render renderTree(node.children, depth + 1)}
              {/if}
            </li>
          {/each}
        </ul>
      {/if}
    {/snippet}

    {@render renderTree(tree, 0)}
    ```
- **SvelteKit `load` Function `await parent()` Waterfall Defense**:
  - ❌ **The Cascading Serialization Waterfall**: Calling `const parentData = await parent()` at the top of a child `+page.server.ts` or `+layout.server.ts` `load` function before starting independent fetch operations. This forces the browser/server to wait for the root layout and all ancestor layouts to resolve before even initiating the page-specific queries, multiplying Time to First Byte (TTFB) by the number of layout tiers.
  - ✅ **Production Invariant**: Initiate independent child fetch promises *in parallel* before awaiting `parent()`, or omit `await parent()` entirely if the child only needs route parameters:
    ```typescript
    // +page.server.ts - Parallel execution pattern
    export const load: PageServerLoad = async ({ params, fetch, parent }) => {
      // 1. Initiate independent page fetch immediately (do not block on parent):
      const pageDataPromise = fetch(`/api/projects/${params.id}`).then(r => r.json());

      // 2. Only await parent() if parent layout data (e.g. session user) is strictly required:
      const { user } = await parent();

      // 3. Await page-specific promise in parallel:
      const project = await pageDataPromise;

      return { user, project };
    };
    ```
- **SvelteKit `use:enhance` Atomic Submitter UI Lockout**:
  - ❌ **Concurrent Form Double-Submit Vulnerability**: Submitting a form with `use:enhance` without disabling the submit button or handling `isSubmitting` state. Users double-clicking a "Pay Now" or "Delete Account" button trigger two concurrent HTTP POST requests before the client state updates.
  - ✅ **Production Invariant**: Manage pending state within the `use:enhance` callback to disable submit controls atomically:
    ```svelte
    <script lang="ts">
      import { enhance } from '$app/forms';
      import type { SubmitFunction } from './$types';

      let isSubmitting = $state(false);

      const handleEnhance: SubmitFunction = () => {
        isSubmitting = true;
        return async ({ update }) => {
          try {
            await update();
          } finally {
            isSubmitting = false;
          }
        };
      };
    </script>

    <form method="POST" action="?/checkout" use:enhance={handleEnhance}>
      <button type="submit" disabled={isSubmitting} class="disabled:opacity-50 disabled:cursor-not-allowed">
        {isSubmitting ? 'Processing...' : 'Complete Purchase'}
      </button>
    </form>
    ```
- **SvelteKit `handleServerError` Error Sanitization & Secret Leak Defense**:
  - ❌ **The Internal Database / Secret Error Leak Trap**: Allowing unhandled server exceptions (such as database connection strings, raw SQL queries, or internal stack traces) to bubble up directly to the client. By default, uncaught exceptions can leak internal network topologies, table schemas, or authorization credentials.
  - ✅ **Production Invariant**: Implement `handleServerError` in `src/hooks.server.ts` to log errors securely to server telemetry and return an opaque reference ID to the client:
    ```typescript
    // src/hooks.server.ts
    import type { HandleServerError } from '@sveltejs/kit';
    import crypto from 'node:crypto';

    export const handleServerError: HandleServerError = ({ error, event }) => {
      const errorId = crypto.randomUUID();

      // Log full diagnostic context to server-side telemetry / APM:
      console.error(`[Unhandled Server Error: ${errorId}]`, {
        url: event.url.pathname,
        method: event.request.method,
        error: error instanceof Error ? error.stack : error,
      });

      // Return strictly sanitized error payload to the browser client:
      return {
        message: 'An unexpected internal error occurred. Please contact support.',
        errorId,
      };
    };
    ```
- **Svelte 5 `$host()` Custom Element Shadow DOM Access Invariant**:
  - ❌ **The Fragile Global DOM Query Trap in Web Components**: Authoring Svelte 5 custom elements (`<svelte:options customElement="x-player" />`) and attempting to locate the host DOM element via `document.querySelector('x-player')`. In multi-instance or nested shadow DOM trees, this returns the wrong component instance and breaks encapsulation.
  - ✅ **Production Invariant**: In Svelte 5, use the `$host()` rune to retrieve a direct, typesafe reference to the custom element's containing host element:
    ```svelte
    <svelte:options customElement={{ tag: 'audio-player', shadow: 'open' }} />

    <script lang="ts">
      const host = $host<HTMLElement>();

      function dispatchCustomStatus(status: string) {
        // Dispatch native CustomEvent directly from the host element:
        host.dispatchEvent(new CustomEvent('playbackchange', {
          detail: { status },
          bubbles: true,
          composed: true, // Escape shadow DOM boundary
        }));
      }
    </script>

    <div class="player-controls">
      <button onclick={() => dispatchCustomStatus('playing')}>Play</button>
    </div>
    ```







