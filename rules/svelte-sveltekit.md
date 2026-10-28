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
- **Svelte 5 `$inspect.trace()` for Granular Signal Dependency Diagnostics**:
  - ❌ **The Console Log Reactivity Mystery**: Debugging unexpected `$effect` re-runs or derived re-evaluations by manually logging state variables. It fails to expose the exact internal signal or deep object property that triggered the invalidation.
  - ✅ **Production Invariant**: In Svelte 5, invoke `$inspect.trace()` inside complex derived or effect blocks. Svelte emits structured browser console traces identifying the exact signal mutation responsible for re-running the computation. The compiler automatically strips all `$inspect` invocations from production builds with zero bundle overhead:
    ```svelte
    <script lang="ts">
      let items = $state<Item[]>([]);
      let filterTag = $state('active');

      const filteredItems = $derived.by(() => {
        // Traces which signal (items vs filterTag) triggered this derivation in DEV mode:
        $inspect.trace();
        return items.filter(i => i.status === filterTag);
      });
    </script>
    ```
- **SvelteKit `preloadCode` vs `preloadData` Intent-Driven Warming Invariants**:
  - ❌ **The Speculative Load Server Flooding Trap**: Blindly calling `preloadData('/dashboard/analytics')` on all menu items or list items on initial page load. `preloadData` executes the route's server-side `load` function, hammering upstream databases and microservices with expensive queries for views the user may never visit.
  - ✅ **Production Invariant**: Decouple asset chunk warming from server data loading. Use `preloadCode` to download JS/CSS bundles without server execution, and reserve `preloadData` strictly for high-intent interactions (e.g., hover lasting >150ms or pointerdown):
    ```svelte
    <script lang="ts">
      import { preloadCode, preloadData } from '$app/navigation';

      function handleHover(href: string) {
        // Fast-path: Preload JavaScript and CSS assets immediately on pointer enter:
        preloadCode(href);
      }

      function handleIntentionalHover(href: string) {
        // Execute server load() only after confirmed user dwell time (>150ms):
        preloadData(href);
      }
    </script>

    <a
      href="/app/reports"
      onmouseenter={() => handleHover('/app/reports')}
    >
      Reports
    </a>
    ```
- **Svelte 5 `untrack()` inside `$effect` to Eliminate Reactive Over-Subscription Loops**:
  - ❌ **The Auxiliary Dependency Cascade Trap**: Reading secondary configuration or telemetry state inside an `$effect` intended to track a primary entity. When the secondary state changes, the effect re-runs unexpectedly, causing unintended side effects, duplicated API calls, or infinite reactive loops.
  - ✅ **Production Invariant**: In Svelte 5, isolate auxiliary state reads with `untrack(() => ...)` so the effect establishes dependencies strictly on intended reactive signals:
    ```svelte
    <script lang="ts">
      import { untrack } from 'svelte';

      let activeTab = $state('overview');
      let userAnalyticsId = $state('usr_987');

      $effect(() => {
        // Primary dependency: This effect will ONLY re-run when activeTab changes
        const tab = activeTab;

        // untrack ensures changes to userAnalyticsId do NOT re-trigger this effect
        const userId = untrack(() => userAnalyticsId);

        navigator.sendBeacon('/api/telemetry', JSON.stringify({ tab, userId }));
      });
    </script>
    ```
- **Svelte 5 `$host()` for Web Components & Custom Elements Integration**:
  - ❌ **The Fragile Shadow DOM Element Query**: Accessing the host custom element via `document.querySelector` or manual component binding when compiling Svelte components to web components (`customElement: true`). It fails in nested shadow trees, breaks encapsulation, and leaks memory.
  - ✅ **Production Invariant**: In Svelte 5 custom elements, use the `$host()` rune to retrieve a direct reference to the outer custom element instance, allowing idiomatic DOM event dispatching and attribute reflection:
    ```svelte
    <svelte:options customElement="user-profile-badge" />

    <script lang="ts">
      let { name, role } = $props<{ name: string; role: string }>();

      // Safe direct access to the hosting Web Component DOM element:
      const hostElement = $host<HTMLElement>();

      function handleBadgeClick() {
        hostElement.dispatchEvent(
          new CustomEvent('badge-click', {
            bubbles: true,
            composed: true, // Pierces Shadow DOM boundary into main document
            detail: { name, role }
          })
        );
      }
    </script>

    <button onclick={handleBadgeClick} class="badge-button">
      <span>{name}</span> - <span>{role}</span>
    </button>
    ```
- **Svelte 5 `$derived.by` for Complex Multi-Statement Computations**:
  - ❌ **The IIFE Derivation Anti-Pattern**: Attempting to execute multi-step branching logic or loops inside `$derived((() => { ... })())`. This introduces unnecessary closure overhead, clutters code, and deviates from Svelte 5 idiomatic reactive primitives.
  - ✅ **Production Invariant**: Use Svelte 5 `$derived.by(() => { ... })` for any derived computation requiring branching logic, temporary variables, or array transformations:
    ```svelte
    <script lang="ts">
      let { products, searchQuery, minRating } = $props<{
        products: Array<{ id: string; title: string; rating: number; inStock: boolean }>;
        searchQuery: string;
        minRating: number;
      }>();

      // Idiomatic Svelte 5 multi-statement computation:
      const matchedProducts = $derived.by(() => {
        const query = searchQuery.trim().toLowerCase();
        return products.filter(p => {
          if (!p.inStock) return false;
          if (p.rating < minRating) return false;
          return query === '' || p.title.toLowerCase().includes(query);
        });
      });
    </script>
    ```
- **SvelteKit Fine-Grained `depends()` & Targeted `invalidate()` vs Wholesale `invalidateAll()`**:
  - ❌ **The `invalidateAll()` Over-Fetching Cascade**: Invoking `invalidateAll()` upon every single user mutation. This forces SvelteKit to re-run every `load` function on the page hierarchy, triggering unnecessary database queries and destroying client cache performance.
  - ✅ **Production Invariant**: Register targeted custom URI dependencies using `depends('app:orders')` in `load` functions, and invalidate only that specific tag upon mutation:
    ```ts
    // src/routes/dashboard/+page.ts
    export const load = async ({ fetch, depends }) => {
      // Register custom dependency tag:
      depends('app:dashboard-metrics');

      const res = await fetch('/api/v1/metrics');
      return { metrics: await res.json() };
    };
    ```
    ```svelte
    <!-- src/routes/dashboard/+page.svelte -->
    <script lang="ts">
      import { invalidate } from '$app/navigation';

      async function refreshMetrics() {
        // Only re-runs load functions tagged with 'app:dashboard-metrics'
        await invalidate('app:dashboard-metrics');
      }
    </script>
    ```
- **Svelte 5 Runes: `untrack()` for Reading Signals Without Dependency Subscription**:
  - ❌ **The Accidental Effect Re-run Loop**: Reading a secondary signal (e.g. logging page URL, analytics token, or modal state) inside `$effect(() => { ... })` causes the effect to re-run whenever that secondary signal mutates, triggering infinite loops or duplicate API mutations.
  - ✅ **Production Invariant**: Use `untrack(() => signal)` when you only want to read a state's current value inside an effect without establishing a reactive subscription:
    ```svelte
    <script lang="ts">
      import { untrack } from 'svelte';

      let { activeUserId, analyticsEnabled } = $props<{
        activeUserId: string;
        analyticsEnabled: boolean;
      }>();

      $effect(() => {
        // We want this effect to trigger ONLY when activeUserId changes:
        const userId = activeUserId;

        // Read analyticsEnabled without subscribing to its mutations:
        const enabled = untrack(() => analyticsEnabled);
        if (enabled) {
          sendTelemetry('user_view', { userId });
        }
      });
    </script>
    ```
- **SvelteKit Server Data Streaming with Non-Blocking Deferred Promises**:
  - ❌ **The Slowest-Query Waterfall Stall**: A page `load` function executing `await Promise.all([fastHeaderQuery, slowAnalyticsQuery])` delays the entire HTML response until the slowest query (e.g. 3 seconds) completes, destroying TTFT (Time To First Byte) and First Contentful Paint.
  - ✅ **Production Invariant**: Return the slow promise directly (unawaited) from the `load` function and stream it to the client using Svelte's `{#await}` block:
    ```ts
    // src/routes/dashboard/+page.server.ts
    export const load = async () => {
      return {
        // Instant response:
        user: await fetchFastUserData(),
        // Streamed deferred response (does not block initial page render):
        slowMetrics: fetchHeavyAnalyticsData(),
      };
    };
    ```
    ```svelte
    <!-- src/routes/dashboard/+page.svelte -->
    <script lang="ts">
      let { data } = $props();
    </script>

    <!-- Renders immediately without waiting for slowMetrics -->
    <h1>Welcome, {data.user.name}</h1>

    <!-- Streamed asynchronously when server resolves the promise -->
    {#await data.slowMetrics}
      <div class="skeleton-loader">Loading analytics...</div>
    {:then metrics}
      <AnalyticsChart data={metrics} />
    {:catch error}
      <p class="text-error">Failed to load analytics: {error.message}</p>
    {/await}
    ```
- **Svelte 5 `$effect.tracking()` for Safe Reactivity Detection in Utility Helpers**:
  - ❌ **The Reactive Tracking Context Blindness Trap**: Invoking reactive logic or signal subscriptions from general-purpose utility libraries or event handlers. If the utility assumes an active reactive tracking context, it may silently fail to update or throw Svelte runtime warnings when invoked outside an effect or component template.
  - ✅ **Production Invariant**: In Svelte 5, use `$effect.tracking()` to detect whether the caller is executing within an active reactive tracking scope before registering reactive subscriptions:
    ```svelte
    <script lang="ts">
      import { untrack } from 'svelte';

      export function readStateSafely<T>(getter: () => T): T {
        // If we are currently inside an active tracking context (effect or template),
        // we can safely read the signal directly; otherwise, read untracked:
        if ($effect.tracking()) {
          return getter();
        }
        return untrack(getter);
      }
    </script>
    ```
- **SvelteKit `use:enhance` Form Submission Lifecycle & Optimistic State Invariants**:
  - ❌ **The Naive `use:enhance` Form Reset Trap**: Using unconfigured `<form method="POST" use:enhance>` on critical mutation forms (e.g. settings, inline editing). When the server returns validation errors (`fail(400, { ... })`), the default enhance behavior can wipe unsaved form field inputs, causing frustrating data loss for users.
  - ✅ **Production Invariant**: Always provide a custom submission lifecycle callback to `use:enhance`. Explicitly disable form reset on validation failure (`update({ reset: false })`), manage local `isSubmitting` reactive states to prevent double-submit race conditions, and capture optimistic UI rollbacks:
    ```svelte
    <script lang="ts">
      import { enhance } from '$app/forms';
      import type { SubmitFunction } from './$types';

      let isSubmitting = $state(false);
      let errorMessage = $state<string | null>(null);

      const handleSubmit: SubmitFunction = ({ cancel }) => {
        if (isSubmitting) {
          cancel(); // Prevent concurrent double-submits
          return;
        }

        isSubmitting = true;
        errorMessage = null;

        return async ({ result, update }) => {
          try {
            if (result.type === 'failure') {
              errorMessage = (result.data?.message as string) ?? 'Submission failed.';
              // Crucial: preserve user input on validation failure!
              await update({ reset: false });
            } else {
              await update({ reset: true });
            }
          } finally {
            isSubmitting = false;
          }
        };
      };
    </script>

    <form method="POST" action="?/saveSettings" use:enhance={handleSubmit}>
      {#if errorMessage}
        <div class="alert-error" role="alert">{errorMessage}</div>
      {/if}
      <button type="submit" disabled={isSubmitting}>
        {isSubmitting ? 'Saving...' : 'Save Settings'}
      </button>
    </form>
    ```
- **Svelte 5 Snippets Composition & Total Deprecation of `<slot />`**:
  - ❌ **The Legacy `<slot>` and `let:item` Scoped Slot Anti-Pattern**: In Svelte 5, legacy `<slot />` elements and scoped slot syntax (`<div slot="item" let:item>`) are deprecated. They introduced non-standard scoping rules, lacked type safety, and could not be passed as first-class props or composed conditionally.
  - ✅ **Production Invariant**: In Svelte 5, use the `{#snippet}` block and `{@render ...}` tags. Type snippet props using `import type { Snippet } from 'svelte'`, passing typed arguments directly to custom renderers:
    ```svelte
    <!-- DataTable.svelte -->
    <script lang="ts" generics="T">
      import type { Snippet } from 'svelte';

      interface Props {
        items: T[];
        row: Snippet<[item: T, index: number]>;
        empty?: Snippet;
      }

      let { items, row, empty }: Props = $props();
    </script>

    {#if items.length === 0}
      {#if empty}
        {@render empty()}
      {:else}
        <p class="text-muted">No items found.</p>
      {/if}
    {:else}
      <ul>
        {#each items as item, index (index)}
          <li>{@render row(item, index)}</li>
        {/each}
      </ul>
    {/if}
    ```
- **SvelteKit Server Load Parallelization & Deferred Streaming**:
  - ❌ **The Sequential `await` Load Waterfall Trap**: Writing sequential `await` calls in `+page.server.ts` (`const user = await getUser(); const products = await getProducts(); const stats = await getStats();`). The total server response time equals the sum of all database queries ($t = t_1 + t_2 + t_3$), directly inflating TTFB and causing poor Largest Contentful Paint (LCP).
  - ✅ **Production Invariant**: Execute independent database queries concurrently using `Promise.all()`, and stream non-critical slow promises without awaiting them, letting SvelteKit stream HTML immediately while the client renders loading skeletons via `{#await}`:
    ```ts
    // src/routes/dashboard/+page.server.ts
    import type { PageServerLoad } from './$types';

    export const load: PageServerLoad = async ({ locals }) => {
      // 1. Critical data needed for immediate SSR layout (fetched in parallel)
      const [user, preferences] = await Promise.all([
        locals.db.user.findUnique({ where: { id: locals.userId } }),
        locals.db.preferences.findFirst({ where: { userId: locals.userId } })
      ]);

      // 2. Return slow / non-critical queries as unawaited promises for streaming
      return {
        user,
        preferences,
        // SvelteKit streams HTML immediately; client resolves promise with {#await}
        streamedAnalytics: locals.db.analytics.calculateMonthlyRollups(locals.userId),
      };
    };
    ```
- **Svelte 5 `$bindable()` Two-Way State Invariants**:
  - ❌ **The Implicit Mutation Bug**: Mutating incoming `$props()` directly or expecting child changes to reflect in parents without contracts. In Svelte 5, props are strictly read-only and unidirectional by default.
  - ✅ **Production Invariant**: When a child component must support two-way synchronization with parent state (e.g., custom checkboxes, range sliders, or dialog states), declare the prop explicitly with `$bindable()`:
    ```svelte
    <!-- Switch.svelte -->
    <script lang="ts">
      let { checked = $bindable(false), label = 'Toggle' }: {
        checked?: boolean;
        label?: string;
      } = $props();
    </script>

    <button
      role="switch"
      aria-checked={checked}
      onclick={() => checked = !checked}
    >
      {label}: {checked ? 'ON' : 'OFF'}
    </button>
    ```
- **SvelteKit Progressive Enhancement via `use:enhance` & Optimistic Rollbacks**:
  - ❌ **The Full-Page Browser Flash on Mutation**: Submitting forms natively without progressive enhancement causes jarring browser reloads, drops active client state, and resets viewport scroll positions.
  - ✅ **Production Invariant**: Always attach `use:enhance` to SvelteKit mutation forms. Apply optimistic state updates immediately in the callback, and roll back cleanly if the server action returns an error:
    ```svelte
    <script lang="ts">
      import { enhance } from '$app/forms';

      let items = $state<string[]>(['Item 1']);

      function optimisticSubmit() {
        const newItem = `Item ${items.length + 1}`;
        const previous = [...items];
        items.push(newItem); // Optimistic UI update

        return async ({ result, update }) => {
          if (result.type === 'failure' || result.type === 'error') {
            items = previous; // Rollback on failure
          }
          await update();
        };
      }
    </script>

    <form method="POST" action="?/add" use:enhance={optimisticSubmit}>
      <button type="submit">Add Item</button>
    </form>
    ```
- **Svelte 5 Snippets (`{#snippet ...}`) vs Legacy `<slot>`**:
  - ❌ **The Legacy `<slot>` & Let-Directive Clutter**: Using Svelte 4 `<slot>` and `let:item` attributes for parameterized component composition. Slots cannot be passed as first-class props, cannot be instantiated conditionally outside the template body, and introduce scope confusion.
  - ✅ **Production Invariant**: In Svelte 5, replace all slots with native snippets (`{#snippet ...}`) and `@render`. Snippets are first-class values that can be passed as component props, typed via `Snippet<[T]>`, and rendered anywhere:
    ```svelte
    <script lang="ts">
      import type { Snippet } from 'svelte';

      let { items, header, row }: {
        items: string[];
        header?: Snippet;
        row: Snippet<[string, number]>;
      } = $props();
    </script>

    {#if header}
      {@render header()}
    {/if}

    <ul>
      {#each items as item, index}
        <li>{@render row(item, index)}</li>
      {/each}
    </ul>
    ```
- **SvelteKit Snapshot API for BFCache State Persistence**:
  - ❌ **The Back-Forward Navigation Form Loss**: Users filling out multi-step agent inputs or complex filters lose all form state when navigating away and clicking the browser's "Back" button.
  - ✅ **Production Invariant**: Use SvelteKit's `snapshot` object export to persist ephemeral form state into `sessionStorage` automatically:
    ```svelte
    <script lang="ts">
      import type { Snapshot } from './$types';

      let filterQuery = $state('');
      let selectedTab = $state('all');

      export const snapshot: Snapshot<{ query: string; tab: string }> = {
        capture: () => ({ query: filterQuery, tab: selectedTab }),
        restore: (value) => {
          filterQuery = value.query;
          selectedTab = value.tab;
        }
      };
    </script>
    ```
- **Svelte 5 `$effect.pre` for Synchronous Layout & Scroll Restoration**:
  - ❌ **The Screen Flickering & FOUC in `$effect`**: Measuring DOM heights or restoring scroll positions inside standard `$effect()`. In Svelte 5, `$effect` runs *after* the browser has already painted the DOM, causing noticeable layout shifts, jitter, and screen flickering.
  - ✅ **Production Invariant**: Use `$effect.pre()` to run layout calculations and scroll stabilization *before* the DOM updates are painted to the screen:
    ```svelte
    <script lang="ts">
      let messages = $state<string[]>([]);
      let container: HTMLElement;

      $effect.pre(() => {
        // Read current scroll height before DOM mutation
        if (container) {
          const isAtBottom = container.scrollHeight - container.scrollTop === container.clientHeight;
          // Synchronous post-update scroll restoration before screen paint
          tick().then(() => {
            if (isAtBottom) container.scrollTop = container.scrollHeight;
          });
        }
      });
    </script>
    ```
- **SvelteKit Universal `fetch` vs Naked Global `fetch`**:
  - ❌ **The Naked Global `fetch` Cookie & Hydration Hazard**: Calling global `fetch()` inside a `load` function instead of using the provided `{ fetch }` parameter in `PageLoad` / `LayoutLoad`. Naked `fetch` fails to inherit incoming request cookies/auth headers during SSR and causes double-fetching on the client instead of inlining data into the hydration payload.
  - ✅ **Production Invariant**: Always use the injected event `load({ fetch })` parameter across all SvelteKit load functions.
- **SvelteKit `handleServerError` Sanitization & Diagnostic Error IDs**:
  - ❌ **Leaking Database Errors & Internal Paths in Production**: When an unhandled exception occurs in a form action or `+page.server.ts` load, naive error handling bubbles raw PostgreSQL errors, file paths, or table schemas to the client UI.
  - ✅ **Production Invariant**: Implement `handleServerError` in `src/hooks.server.ts`. Capture the raw error in server-side logs with full stack traces, assign a monotonic UUIDv7 `errorId`, and return an opaque, sanitized payload to the client:
    ```ts
    // src/hooks.server.ts
    import type { HandleServerError } from '@sveltejs/kit';

    export const handleServerError: HandleServerError = ({ error, event }) => {
      const errorId = crypto.randomUUID();

      // Log full diagnostic trace internally
      console.error(`[Server Error ${errorId}] on ${event.url.pathname}:`, error);

      // Return sanitized object safe for public consumption
      return {
        message: 'An unexpected internal error occurred. Please quote the reference ID.',
        errorId,
      };
    };
    ```
- **Svelte 5 `$derived.by` for Complex Multi-Statement Memoization**:
  - ❌ **The `$effect` State Sync Anti-Pattern**: Updating a secondary `$state` variable inside an `$effect()` whenever a dependency changes. This introduces an extra render cycle, causes UI frame tearing, and can induce infinite re-render loops.
  - ✅ **Production Invariant**: Use `$derived.by(() => { ... })` for multi-step derivations, complex matrix filters, or grouped collections. `$derived.by` is pure, lazy, synchronously memoized, and tracked cleanly by Svelte's push-pull reactivity graph:
    ```svelte
    <script lang="ts">
      let items = $state<Array<{ id: string; category: string; price: number }>>([]);
      let selectedCategory = $state('all');

      // Pure memoized computation; zero intermediate state variables or effects
      const filteredTotal = $derived.by(() => {
        let sum = 0;
        for (const item of items) {
          if (selectedCategory === 'all' || item.category === selectedCategory) {
            sum += item.price;
          }
        }
        return sum;
      });
    </script>
    ```
- **Svelte 5 Snippets (`{#snippet ...}`) & Render Tags (`{@render ...}`)**:
  - ❌ **The Fragile Legacy `<slot />` and `let:` Binding Anti-Pattern**: Using legacy Svelte 3/4 `<slot>` and `slot="name"` directives for component composition. Slots had ambiguous scoping, lacked strict TypeScript argument checking, suffered from awkward `let:data` syntax, and could not be passed as first-class function arguments.
  - ✅ **Production Invariant**: In Svelte 5, use `{#snippet name(args)}` and `{@render name(args)}`. Snippets are first-class typed closures that can be defined inline, passed as standard component props, and assigned default fallback implementations:
    ```svelte
    <script lang="ts">
      import type { Snippet } from 'svelte';

      interface TableProps<T> {
        items: T[];
        rowHeader: Snippet<[item: T]>;
        rowDetails?: Snippet<[item: T]>;
      }

      let { items, rowHeader, rowDetails }: TableProps<{ id: string; name: string; status: string }> = $props();
    </script>

    <div class="table-container divide-y divide-zinc-800">
      {#each items as item (item.id)}
        <div class="row-wrapper p-3">
          <!-- Render required snippet with typed argument -->
          {@render rowHeader(item)}

          <!-- Conditional snippet rendering with fallback -->
          {#if rowDetails}
            {@render rowDetails(item)}
          {/if}
        </div>
      {/each}
    </div>
    ```
- **SvelteKit Progressive Enhancement Form Actions with `use:enhance`**:
  - ❌ **Manual `preventDefault` and Ad-hoc `fetch` POST Handling**: Intercepting form submissions with manual `on:submit|preventDefault`, constructing `FormData`, calling `fetch('/api/...')`, and manually managing loading state and validation errors. This breaks when JavaScript is loading or disabled, and fails to handle native SvelteKit form action invalidation.
  - ✅ **Production Invariant**: Use SvelteKit's built-in `use:enhance` on native HTML forms. It automatically handles progressive enhancement, updates `$page.form` errors, re-runs affected `load` functions via `invalidateAll()`, and allows clean optimistic UI updates:
    ```svelte
    <script lang="ts">
      import { enhance } from '$app/forms';
      import type { ActionData } from './$types';

      let { form }: { form: ActionData } = $props();
      let isSubmitting = $state(false);
    </script>

    <form
      method="POST"
      action="?/createProject"
      use:enhance={() => {
        isSubmitting = true;
        return async ({ update }) => {
          isSubmitting = false;
          await update();
        };
      }}
      class="flex flex-col gap-3"
    >
      <input name="projectName" required placeholder="Project Name" class="input" />
      {#if form?.error}
        <p class="text-xs text-red-400">{form.error}</p>
      {/if}
      <button type="submit" disabled={isSubmitting} class="btn-primary">
        {isSubmitting ? 'Creating...' : 'Create Project'}
      </button>
    </form>
    ```
- **Svelte 5 `$host()` Rune for Web Components & Custom Elements**:
  - ❌ **Direct DOM Traversal to Discover Shadow Host**: In custom element mode (`<svelte:options customElement="x-widget" />`), attempting to discover the host element using parent element searches (`$el.parentElement`) or global query selectors, which breaks across nested shadow DOM boundaries.
  - ✅ **Production Invariant**: In Svelte 5, use the `$host()` rune to retrieve a direct, reactive reference to the custom element's enclosing DOM host instance, facilitating custom event dispatches (`host.dispatchEvent(...)`) and host attribute reflection.
- **Svelte 5 `<svelte:boundary>` Component Crash Isolation**:
  - ❌ **Uncaught Child Component Errors Crashing the Entire Page**: Allowing a runtime error in a complex interactive subtree (e.g. chart rendering, rich text editor) to bubble uncaught, unmounting the entire application root and leaving users with a blank white screen.
  - ✅ **Production Invariant**: Wrap risky client-rendered subtrees in `<svelte:boundary>` with typed fallback snippets, isolating component failures and displaying graceful error recovery UI without tearing down the surrounding page layout:
    ```svelte
    <svelte:boundary>
      <ComplexDataVisualization data={activeSeries} />
      {#snippet failed(error, reset)}
        <div class="rounded border border-red-500/20 bg-red-950/20 p-4 text-xs text-red-300">
          <p>Failed to render visualization: {error.message}</p>
          <button onclick={reset} class="btn-secondary mt-2">Retry</button>
        </div>
      {/snippet}
    </svelte:boundary>
    ```
- **Svelte 5 `$derived.by()` for Multi-Statement Reactive Computations**:
  - ❌ **Using `$effect` to Mutate Secondary State for Complex Calculations**: Calculating complex derived values (filtering, sorting, aggregations) by modifying a `$state` variable inside an `$effect`, causing infinite reactive loops, out-of-order layout renders, and memory overhead.
  - ✅ **Production Invariant**: Use `$derived.by(() => { ... })` for pure, multi-statement reactive derivations:
    ```svelte
    <script lang="ts">
    let transactions = $state<Transaction[]>([]);
    let filterCategory = $state<string>('all');

    // Clean, isolated, pure derivation without side-effect cascades
    const filteredTotal = $derived.by(() => {
      let sum = 0;
      for (const t of transactions) {
        if (filterCategory === 'all' || t.category === filterCategory) {
          sum += t.amountInCents;
        }
      }
      return sum;
    });
    </script>
    ```
- **SvelteKit `preloadData` & `preloadCode` Predictive Navigation Prefetching**:
  - ❌ **Relying Solely on Default Hover Prefetching on Slow Connections**: Depending entirely on `data-sveltekit-preload-data="hover"` which triggers network requests only when the pointer physically enters a link boundary (leaving <100ms before click on mobile touch).
  - ✅ **Production Invariant**: For high-confidence next steps (e.g. wizard navigation, checkout step transitions), imperatively invoke `preloadData('/checkout/payment')` and `preloadCode('/checkout/payment')` on step validation to achieve instant 0ms perceived transitions.
- **Svelte 5 `$bindable()` Two-Way Binding Discipline**:
  - ❌ **Uncontrolled Prop Two-Way Binding Across Deep Hierarchies**: Exposing all component props as two-way bindable via `$bindable()`, creating tight bidirectional coupling and making state mutations unpredictable across parent/child boundaries.
  - ✅ **Production Invariant**: Restrict `$bindable()` strictly to leaf form control primitives (e.g., custom input, checkbox, slider). For domain models or complex state, enforce unidirectional data flow with explicit event callbacks:
    ```svelte
    <!-- Leaf primitive: OK for bindable value -->
    <script lang="ts">
    let { value = $bindable(''), oncommit }: { value?: string; oncommit?: () => void } = $props();
    </script>

    <!-- Composite container: Prefer unidirectional events -->
    <script lang="ts">
    let { user, onUserUpdate }: { user: User; onUserUpdate: (updated: User) => void } = $props();
    </script>
    ```
- **SvelteKit `handleFetch` Server Hook for Internal Service Auth Forwarding**:
  - ❌ **Manual Header Clones in Every Server Load Function**: Manually copying JWT authorization headers and cookies in every `+page.server.ts` or `+layout.server.ts` `fetch()` call, prone to accidental leakage of session credentials to third-party endpoints.
  - ✅ **Production Invariant**: Intercept and forward internal microservice credentials centrally inside `hooks.server.ts` via `handleFetch`:
    ```ts
    export const handleFetch: HandleFetch = async ({ event, request, fetch }) => {
      // Forward authentication headers ONLY to trusted internal API domains
      if (request.url.startsWith('https://internal-api.service.local/')) {
        request.headers.set('authorization', event.request.headers.get('authorization') ?? '');
        request.headers.set('x-forwarded-for', event.getClientAddress());
      }
      return fetch(request);
    };
    ```
- **Svelte 5 `$derived.by()` for Complex Multi-Statement Reactive Computations**:
  - ❌ **Abusing `$effect` for Computed State**: Using `$effect()` to recalculate derived values into another `$state()` variable, creating extra re-render microtasks, stale intermediate states, and infinite invalidation loops.
  - ✅ **Production Invariant**: Use `$derived.by()` when the computed derivation requires loops, multiple branches, or complex intermediate calculations:
    ```svelte
    <script lang="ts">
    let items = $state<Item[]>([]);
    let filterCategory = $state('electronics');
    let minRating = $state(4.0);

    // Pure synchronous derivation executed only when dependencies change:
    const filteredSummary = $derived.by(() => {
      let totalValue = 0;
      let count = 0;
      for (const item of items) {
        if (item.category === filterCategory && item.rating >= minRating) {
          totalValue += item.price;
          count++;
        }
      }
      return { totalValue, count, avgPrice: count > 0 ? totalValue / count : 0 };
    });
    </script>
    ```
- **Svelte 5 `$inspect.trace()` for Granular Reactive Dependency Pinpointing**:
  - ❌ **Inserting Arbitrary `console.log` in Runes**: Littering reactive components with ad-hoc `console.log()` calls that fail to identify which specific reactive signal caused an effect or derivation re-run.
  - ✅ **Production Invariant**: Use `$inspect(signal).with(fn)` or `$inspect.trace()` in development to log the exact dependency that triggered the reactive evaluation with call-site stack traces:
    ```svelte
    <script lang="ts">
    let user = $state({ name: 'Alice', role: 'admin' });
    $inspect(user).with((type, val) => {
      console.debug(`[reactive-${type}]`, val);
      debugger; // Step directly into reactive dependency trigger
    });
    </script>
    ```
- **Svelte 5 Snippet Prop Typing & Fallback Invocation with `Snippet<[T]>`**:
  - ❌ **Untyped Function Callbacks for Template Injection**: Using raw `() => void` or `any` props to inject custom templates into components, which bypasses Svelte 5 compiler snippet optimizations and causes runtime crashes when optional slots are omitted without check.
  - ✅ **Production Invariant**: Explicitly type snippet props with `import type { Snippet } from 'svelte'`, and use optional invocation `{@render optionalSnippet?.(item)}` or default fallback snippets to ensure fail-safe rendering:
    ```svelte
    <script lang="ts">
    import type { Snippet } from 'svelte';

    interface Props {
      items: string[];
      itemTemplate?: Snippet<[item: string, index: number]>;
    }

    let { items, itemTemplate }: Props = $props();
    </script>

    <ul>
      {#each items as item, index}
        <li>
          {#if itemTemplate}
            {@render itemTemplate(item, index)}
          {:else}
            <span>{item}</span>
          {/if}
        </li>
      {/each}
    </ul>
    ```
- **SvelteKit Server Form Actions & Schema Validation with Safe Extraction**:
  - ❌ **Manual Unvalidated `request.formData()` Parsing**: Reading form values directly via `const email = data.get('email') as string` in `+page.server.ts` actions without validating types or string boundaries, inviting runtime crashes on empty or array-like malicious input.
  - ✅ **Production Invariant**: Always validate `event.request.formData()` through a strict schema validator (Zod / Valibot / Standard Schema) and return structured `fail(400, { errors, values })` responses with automatic CSRF protection:
    ```typescript
    import { fail } from '@sveltejs/kit';
    import { z } from 'zod';
    import type { Actions } from './$types';

    const loginSchema = z.object({
      email: z.string().email(),
      password: z.string().min(8),
    });

    export const actions: Actions = {
      default: async ({ request }) => {
        const formData = await request.formData();
        const parsed = loginSchema.safeParse(Object.fromEntries(formData));

        if (!parsed.success) {
          return fail(400, {
            errors: parsed.error.flatten().fieldErrors,
            values: { email: formData.get('email')?.toString() ?? '' },
          });
        }

        // Proceed with authenticated session creation
      },
    };
    ```
- **Svelte 5 `$derived.by()` for Multi-Branch State Derivation**:
  - ❌ **Complex Inline Ternaries or Untracked External Functions in `$derived`**: Writing nested ternary chains inside `$derived(cond1 ? (cond2 ? a : b) : c)` or calling helper functions outside the reactivity graph, leading to unreadable code or missed dependency tracking.
  - ✅ **Production Invariant**: In Svelte 5, use `$derived.by(() => { ... })` for calculations requiring local variables, early returns, loops, or complex filtering:
    ```svelte
    <script lang="ts">
    interface Transaction {
      id: string;
      amount: number;
      category: string;
    }

    let { transactions, activeCategory }: { transactions: Transaction[]; activeCategory: string } = $props();

    // Clean multi-statement computation with automatic signal tracking:
    const filteredTotal = $derived.by(() => {
      let sum = 0;
      for (const t of transactions) {
        if (activeCategory === 'all' || t.category === activeCategory) {
          sum += t.amount;
        }
      }
      return sum;
    });
    </script>
    ```
- **Svelte 5 Snippet Parameter Typing & Callback Props (Deprecating Legacy Slots & `createEventDispatcher`)**:
  - ❌ **Using Deprecated `<slot>` and `createEventDispatcher`**: Relying on Svelte 4 slot mechanisms and event dispatchers in Svelte 5 components. Slots lack TypeScript parameter safety, and event dispatchers bypass standard DOM bubbling semantics.
  - ✅ **Production Invariant**: Declare typed snippets with `Snippet<[T]>` and callback props (`onSelect: (item: T) => void`) for 100% type-safe component composition:
    ```svelte
    <!-- ListBox.svelte -->
    <script lang="ts" generics="T">
    import type { Snippet } from 'svelte';

    let { 
      items, 
      renderRow, 
      onSelect 
    }: { 
      items: T[]; 
      renderRow: Snippet<[item: T]>; 
      onSelect?: (item: T) => void;
    } = $props();
    </script>

    <div class="list-container">
      {#each items as item}
        <div class="row" onclick={() => onSelect?.(item)}>
          {@render renderRow(item)}
        </div>
      {/each}
    </div>
    ```
- **Svelte 5 Runes: `$inspect()` Hygiene & Production Build Elimination**:
  - ❌ **Anti-Pattern: Stray `console.log` in Reactive Effects**: Leaving debugging `console.log()` statements inside `$effect` blocks. Under high state change frequencies, this severely degrades rendering performance, triggers memory retention in browser DevTools, and clutters server/client logs.
  - ✅ **Production Invariant**: Use the native `$inspect(state)` rune for development debugging. Svelte compiler automatically strips `$inspect()` during production builds (`npm run build`), ensuring zero production bundle bloat or runtime overhead:
    ```svelte
    <script lang="ts">
    let count = $state(0);

    // Development-only reactive inspector; automatically stripped in production:
    $inspect(count).with((type, val) => {
      console.debug(`[Count Inspector - ${type}]:`, val);
    });
    </script>
    ```
- **SvelteKit Form Actions & Progressive Enhancement (`use:enhance`)**:
  - ❌ **Anti-Pattern: Custom Fetch Handlers Breaking Form Degradation**: Writing manual `fetch('/api/...')` submit handlers with ad-hoc loading spinners, losing native browser form semantics and bypassing SvelteKit's built-in page data invalidation and action data typing.
  - ✅ **Production Invariant**: Use SvelteKit's native form actions combined with `use:enhance` to achieve instant optimistic UI, automatic pending state transitions, and server response mapping:
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
          isSubmitting = false;
          await update();
        };
      }}
    >
      <input name="displayName" required disabled={isSubmitting} />
      <button type="submit" disabled={isSubmitting}>
        {isSubmitting ? 'Saving changes...' : 'Save Profile'}
      </button>
    </form>
    ```
- **Svelte 5 `$derived.by` for Complex Multi-Statement Computed Computations**:
  - ❌ **Anti-Pattern: IIFEs Inside `$derived` or Misusing `$effect` to Sync State**: Wrapping immediately invoked function expressions `(() => { ... })()` inside `$derived(...)` or writing `$effect(() => { computedValue = ... })` which introduces an extra render tick and risks infinite reactivity loops.
  - ✅ **Production Invariant**: Use `$derived.by(() => { ... })` for multi-branch, try-catch, or iterative derived values. It creates a clean reactive computation closure with automatic dependency tracking:
    ```svelte
    <script lang="ts">
    let rawTransactions = $state<Transaction[]>([]);
    let filterCategory = $state<string>('all');

    // Multi-statement derived state with branch filtering and aggregation:
    const activeSummary = $derived.by(() => {
      const filtered = filterCategory === 'all'
        ? rawTransactions
        : rawTransactions.filter(t => t.category === filterCategory);

      return {
        count: filtered.length,
        totalUsd: filtered.reduce((acc, t) => acc + t.amountUsd, 0)
      };
    });
    </script>
    ```
- **SvelteKit Fine-Grained Invalidation via `depends()` vs Blunt `invalidateAll()`**:
  - ❌ **Anti-Pattern: Triggering Global Cascade with `invalidateAll()`**: Invoking `invalidateAll()` after a small mutation (e.g., toggling a star or liking an item). This forces SvelteKit to re-run every `load()` function across all active layout and page routes, wasting database queries and introducing layout flicker.
  - ✅ **Production Invariant**: Declare explicit semantic cache keys using `depends('app:resource')` in `load` functions, and invalidate only the affected sub-tree with `invalidate('app:resource')`:
    ```typescript
    // +page.ts (or +page.server.ts)
    export const load = async ({ fetch, depends }) => {
      depends('data:notifications'); // Register cache tag
      const res = await fetch('/api/notifications');
      return { notifications: await res.json() };
    };

    // Client-side mutation handler:
    import { invalidate } from '$app/navigation';
    async function markAsRead(id: string) {
      await fetch(`/api/notifications/${id}/read`, { method: 'POST' });
      // Invalidate ONLY the notification stream, sparing all other page/layout load calls:
      await invalidate('data:notifications');
    }
    ```
- **Svelte 5 `$effect.root` for Isolated Non-Component Reactive Lifecycles**:
  - ❌ **Anti-Pattern: Running Unbounded Effects Outside Component Hierarchies**: Initializing global event listeners, WebSockets, or worker managers in standalone TypeScript modules using `$effect`, which triggers compile-time errors or leaks memory because there is no owning component to tear it down.
  - ✅ **Production Invariant**: Use `$effect.root(cleanupFn)` to establish an explicit, manually tearable reactive scope in external state machines or service classes:
    ```typescript
    export class RealtimeChannel {
      private cleanup: () => void;

      constructor(private topic: string) {
        this.cleanup = $effect.root(() => {
          $effect(() => {
            const socket = new WebSocket(`wss://api.example.com/${this.topic}`);
            return () => socket.close();
          });
        });
      }

      public destroy() {
        this.cleanup(); // Cleanly teardowns all effects within the root
      }
    }
    ```
- **Svelte 5 Snippets vs Deprecated `<slot>` for Typed Dynamic Projection**:
  - ❌ **Anti-Pattern: Legacy Svelte 4 `<slot>` with Untyped `let:` Bindings**: Using `<slot name="header" :item="data" />` in Svelte 5 projects. `<slot>` is deprecated; it cannot be type-checked by `svelte-check`, cannot be passed cleanly as props, and lacks closure scope ergonomics.
  - ✅ **Production Invariant**: In Svelte 5, use `{#snippet}` and `{@render}`. Snippets are first-class, strongly-typed template functions that can be passed as regular component props:
    ```svelte
    <script lang="ts">
    import type { Snippet } from 'svelte';

    interface Props<T> {
      items: T[];
      // Typed snippet prop contract:
      row: Snippet<[item: T, index: number]>;
      fallback?: Snippet;
    }

    let { items, row, fallback }: Props<any> = $props();
    </script>

    {#if items.length === 0 && fallback}
      {@render fallback()}
    {:else}
      <ul>
        {#each items as item, i (item.id ?? i)}
          <li>
            {@render row(item, i)}
          </li>
        {/each}
      </ul>
    {/if}
    ```
- **Svelte 5 Encapsulated Reactive Model Classes with `$state`**:
  - ❌ **Anti-Pattern: Legacy `writable()` Stores or Leaky Object References**: Exposing mutable state objects or using legacy Svelte 4 `writable()` stores in Svelte 5 projects, forcing consumers to deal with `$` syntax and manual subscriptions.
  - ✅ **Production Invariant**: Encapsulate complex state machines into standard TypeScript classes using private `#field = $state(...)` and public getters. Svelte 5 automatically tracks property access reactively across module boundaries:
    ```typescript
    export class CartModel {
      #items = $state<Array<{ id: string; price: number; qty: number }>>([]);

      get totalCount(): number {
        return this.#items.reduce((acc, item) => acc + item.qty, 0);
      }

      get subtotalUsd(): number {
        return this.#items.reduce((acc, item) => acc + item.price * item.qty, 0);
      }

      public addItem(id: string, price: number): void {
        const existing = this.#items.find(i => i.id === id);
        if (existing) {
          existing.qty += 1;
        } else {
          this.#items.push({ id, price, qty: 1 });
        }
      }

      public clear(): void {
        this.#items = [];
      }
    }
    ```
- **SvelteKit Cookie Security & Subdomain Propagation Invariants**:
  - ❌ **Anti-Pattern: Pathless `cookies.set()` Causing Route-Scoped Auth Drift**: Calling `cookies.set('session', token)` without an explicit `path`. SvelteKit defaults the cookie path to the current request pathname (e.g. `/api/auth/login`), causing subsequent requests to `/dashboard` to omit the cookie and appear unauthenticated.
  - ✅ **Production Invariant**: Always provide explicit security attributes and `path: '/'` on all cookie mutations:
    ```typescript
    import { dev } from '$app/environment';
    import type { RequestEvent } from '@sveltejs/kit';

    export function setAuthCookie(event: RequestEvent, token: string): void {
      event.cookies.set('session_id', token, {
        path: '/',
        httpOnly: true,
        sameSite: 'lax',
        secure: !dev,
        maxAge: 60 * 60 * 24 * 7 // 7 days
      });
    }

    export function clearAuthCookie(event: RequestEvent): void {
      event.cookies.delete('session_id', {
        path: '/'
      });
    }
    ```
- **Svelte 5 `untrack()` for Non-Triggering Reactive Reads**:
  - ❌ **Anti-Pattern: Unintended Dependency Tracking in `$effect`**: Reading secondary state (e.g. telemetry trackers, analytics IDs, or routing breadcrumbs) inside an `$effect`. The effect re-runs every time any read signal mutates, creating infinite re-render loops or flooding the server with duplicate analytical beacons.
  - ✅ **Production Invariant**: Wrap secondary or non-triggering reads in `untrack()`. The effect will only re-execute when primary, tracked dependencies change:
    ```svelte
    <script lang="ts">
    import { untrack } from 'svelte';

    let { count, telemetryUserId }: { count: number; telemetryUserId: string } = $props();

    $effect(() => {
      // Primary tracked dependency: effect triggers ONLY when count changes
      const currentCount = count;

      // untrack() reads telemetryUserId without creating a reactive subscription:
      untrack(() => {
        sendAnalyticsBeacon({
          userId: telemetryUserId,
          metric: 'counter_updated',
          value: currentCount
        });
      });
    });
    </script>
    ```
- **SvelteKit Non-Blocking Streaming SSR via Unawaited Promises**:
  - ❌ **Anti-Pattern: Blocking Full SSR Response on Slow Third-Party APIs**: Awaiting slow secondary data (e.g. recommendations, related comments, analytics) directly inside `PageServerLoad`. This stalls the initial HTML response, degrading Time to First Byte (TTFB) from 60ms to over 2000ms.
  - ✅ **Production Invariant**: Return the unresolved Promise directly from the load function. SvelteKit will immediately stream the main page HTML to the client and resolve the nested stream as the data completes:
    ```typescript
    // src/routes/dashboard/+page.server.ts
    import type { PageServerLoad } from './$types';

    export const load: PageServerLoad = async ({ fetch }) => {
      // 1. Await critical fast data required for initial viewport render:
      const userRes = await fetch('/api/user/me');
      const user = await userRes.json();

      // 2. Return slow promise WITHOUT await to stream asynchronously:
      const slowStatsPromise = fetch('/api/reports/analytics')
        .then(r => r.json());

      return {
        user,
        streamed: {
          stats: slowStatsPromise
        }
      };
    };
    ```
    ```svelte
    <!-- src/routes/dashboard/+page.svelte -->
    <script lang="ts">
      let { data } = $props();
    </script>

    <h1>Welcome, {data.user.name}</h1>

    <!-- Streamed asynchronously without stalling initial SSR: -->
    {#await data.streamed.stats}
      <div class="skeleton-loader">Loading analytics...</div>
    {:then stats}
      <div class="analytics-card">Total Revenue: {stats.totalRevenue}</div>
    {:catch error}
      <p class="error">Failed to load analytics: {error.message}</p>
    {/await}
    ```
- **Svelte 5 Callback Props vs Deprecated `createEventDispatcher`**:
  - ❌ **Anti-Pattern: Using Legacy `createEventDispatcher` in Svelte 5**: In Svelte 5 Runes mode, `createEventDispatcher` is legacy and lacks native TypeScript return value typing and async promise propagation.
  - ✅ **Production Invariant**: Use standard typed callback props (`onclick`, `onchange`, `onSelect`). They support strict typing, optional arguments, and can return Promises:
    ```svelte
    <!-- ModalDialog.svelte (Svelte 5) -->
    <script lang="ts">
    import type { Snippet } from 'svelte';

    let { 
      isOpen = false, 
      onConfirm, 
      onCancel, 
      children 
    }: {
      isOpen: boolean;
      onConfirm: () => Promise<void> | void;
      onCancel: () => void;
      children?: Snippet;
    } = $props();

    let isSubmitting = $state(false);

    async function handleConfirm() {
      isSubmitting = true;
      try {
        await onConfirm();
      } finally {
        isSubmitting = false;
      }
    }
    </script>

    {#if isOpen}
      <div class="dialog">
        {@render children?.()}
        <button disabled={isSubmitting} onclick={handleConfirm}>
          {isSubmitting ? 'Saving...' : 'Confirm'}
        </button>
        <button onclick={onCancel}>Cancel</button>
      </div>
    {/if}
    ```
- **Svelte 5 Runes: `$effect.pre` for Pre-DOM Layout & Scroll Position Preservation**:
  - ❌ **Anti-Pattern: Post-Paint Visual Jitter with Standard `$effect`**: Measuring DOM element dimensions or restoring scroll positions inside `$effect`. Because `$effect` runs *after* the browser paints the DOM update, users experience visible layout jumping or flickering.
  - ✅ **Production Invariant**: Use `$effect.pre(() => { ... })` to run logic *before* DOM updates are flushed to the screen. Ideal for scroll locking, measurements, and pre-paint layout stabilization:
    ```svelte
    <script lang="ts">
    let messages = $state<string[]>([]);
    let chatContainer: HTMLElement | null = $state(null);
    let shouldAutoScroll = false;

    // Runs immediately before DOM mutation:
    $effect.pre(() => {
      if (chatContainer) {
        // Detect if user was scrolled to bottom before new message arrived:
        const { scrollTop, scrollHeight, clientHeight } = chatContainer;
        shouldAutoScroll = scrollHeight - scrollTop - clientHeight < 50;
      }
    });

    // Runs after DOM mutation:
    $effect(() => {
      if (shouldAutoScroll && chatContainer) {
        chatContainer.scrollTop = chatContainer.scrollHeight;
      }
    });
    </script>

    <div bind:this={chatContainer} class="overflow-y-auto h-64">
      {#each messages as msg}
        <p>{msg}</p>
      {/each}
    </div>
    ```
- **Svelte 5 `untrack()` for Fine-Grained Reactive Dependency Isolation**:
  - ❌ **Anti-Pattern: Unintended Effect Re-triggers on Incidental State Reads**: Reading multiple reactive variables inside an `$effect` or `$derived.by` block. Svelte 5 automatically tracks every reactive read as an active dependency, causing the effect to re-run on changes to variables that were only meant for snapshot reads.
  - ✅ **Production Invariant**: Wrap non-dependency reads inside `untrack(() => ...)` so the effect only triggers on intentional reactive dependencies:
    ```svelte
    <script lang="ts">
    import { untrack } from 'svelte';

    let activeTab = $state('overview');
    let analyticsPayload = $state({ userRole: 'admin', teamId: 42 });

    // Re-run ONLY when activeTab changes, taking a snapshot of analyticsPayload:
    $effect(() => {
      const currentTab = activeTab;
      // untrack prevents analyticsPayload mutations from re-triggering this effect:
      const meta = untrack(() => analyticsPayload);

      sendAnalyticsEvent('tab_switched', { tab: currentTab, ...meta });
    });
    </script>
    ```
- **SvelteKit Progressive Enhancement with Form Actions & `use:enhance`**:
  - ❌ **Anti-Pattern: Manual `fetch()` Handlers Breaking Built-in Invalidation**: Replacing native `<form>` elements with custom `onclick={handleSubmit}` calling `fetch('/api/...')`. This loses zero-JS fallback accessibility and forces manual cache-busting of all active load functions (`invalidateAll()`).
  - ✅ **Production Invariant**: Use standard SvelteKit Form Actions with `use:enhance`. SvelteKit transparently intercepts the form submission via client-side fetch, manages pending states, and automatically re-runs active page load functions:
    ```svelte
    <script lang="ts">
    import { enhance } from '$app/forms';

    let isPending = $state(false);
    </script>

    <form
      method="POST"
      action="?/updateProfile"
      use:enhance={() => {
        isPending = true;
        return async ({ update }) => {
          await update();
          isPending = false;
        };
      }}
    >
      <input name="displayName" required />
      <button disabled={isPending}>
        {isPending ? 'Saving...' : 'Save Profile'}
      </button>
    </form>
    ```
- **Svelte 5 `$derived.by` for Complex Multi-Statement Computed Reductions**:
  - ❌ **Anti-Pattern: Mutating Intermediate `$state` Inside `$effect` for Computed Values**: Using an `$effect` to listen to multiple reactive signals and update another `$state` variable. This introduces unnecessary re-render cycles, race conditions, and infinite loop bugs.
  - ✅ **Production Invariant**: Use `$derived.by(() => { ... })` for multi-line reactive calculations, filtering, or aggregations. Svelte 5 automatically tracks fine-grained dependencies inside the function and recalculates only when consumed dependencies change:
    ```svelte
    <script lang="ts">
    interface OrderItem {
      id: string;
      price: number;
      quantity: number;
      taxable: boolean;
    }

    let items = $state<OrderItem[]>([]);
    let taxRate = $state(0.08);

    // Pure, dependency-tracked derived calculation without $effect mutations:
    const orderSummary = $derived.by(() => {
      let subtotal = 0;
      let taxableAmount = 0;

      for (const item of items) {
        const itemTotal = item.price * item.quantity;
        subtotal += itemTotal;
        if (item.taxable) {
          taxableAmount += itemTotal;
        }
      }

      const tax = taxableAmount * taxRate;
      return {
        subtotal,
        tax,
        total: subtotal + tax,
      };
    });
    </script>
    ```
- **Svelte 5 `$inspect` Telemetry & Production Stripping Invariant**:
  - ❌ **Anti-Pattern: Scattering `console.log` in Templates or Shipping `$inspect` to Production**: Sprinkling temporary `console.log` statements in component templates that trigger extra DOM renders and leak sensitive client data in production browser devtools.
  - ✅ **Production Invariant**: Use `$inspect(state)` exclusively during development. `$inspect` automatically logs the previous and current values when the signal mutates. Attach `.with()` for targeted conditional logging and ensure Vite/Rollup tree-shakes `$inspect` in production:
    ```svelte
    <script lang="ts">
    let userQuery = $state('');

    // Svelte 5 built-in reactive inspection (auto-stripped in production builds):
    $inspect(userQuery).with((type, value) => {
      if (import.meta.env.DEV) {
        console.debug(`[State Inspection: ${type}] query updated to:`, value);
      }
    });
    </script>
    ```
- **SvelteKit `snapshot` Invariant for History & Ephemeral Form State Preservation**:
  - ❌ **Anti-Pattern: Losing Unsubmitted Form Drafts on Browser Navigation**: When a user navigates away from a complex multi-step form to consult documentation and clicks the browser back button, the component re-mounts from scratch, wiping all unsubmitted inputs. Storing drafts in `localStorage` requires manual cleanup and risks leaking stale data across user sessions.
  - ✅ **Production Invariant**: Export a `snapshot` object containing `capture` and `restore` handlers from the page component. SvelteKit automatically serializes this state to `sessionStorage` associated with the current history entry and restores it when the user navigates back/forward:
    ```svelte
    <script lang="ts">
    import type { Snapshot } from './$types';

    let draftComment = $state('');
    let selectedCategory = $state('feedback');

    export const snapshot: Snapshot<{ draft: string; category: string }> = {
      capture: () => ({ draft: draftComment, category: selectedCategory }),
      restore: (value) => {
        draftComment = value.draft;
        selectedCategory = value.category;
      },
    };
    </script>

    <form>
      <input bind:value={draftComment} placeholder="Draft your review..." />
      <select bind:value={selectedCategory}>
        <option value="feedback">Feedback</option>
        <option value="bug">Bug Report</option>
      </select>
    </form>
    ```
- **Svelte 5 `$bindable()` Macro for Two-Way Contract Invariants**:
  - ❌ **Anti-Pattern: Implicit Two-Way Prop Mutation or Clumsy Event Plumbing**: Attempting to mutate non-bindable child props directly, or writing verbose custom event dispatches (`on:change` / callback props) for simple bidirectional form controls.
  - ✅ **Production Invariant**: In Svelte 5, child components must explicitly declare which props are permitted to participate in two-way binding using the `$bindable()` macro with an optional fallback. Consumers can then choose to use `bind:value={...}` or provide a normal one-way prop:
    ```svelte
    <!-- NumericStepper.svelte -->
    <script lang="ts">
    let {
      value = $bindable(0),
      min = 0,
      max = 100,
      step = 1,
    }: {
      value?: number;
      min?: number;
      max?: number;
      step?: number;
    } = $props();

    function increment() {
      if (value + step <= max) value += step;
    }

    function decrement() {
      if (value - step >= min) value -= step;
    }
    </script>

    <div class="stepper">
      <button onclick={decrement} disabled={value <= min}>-</button>
      <span>{value}</span>
      <button onclick={increment} disabled={value >= max}>+</button>
    </div>
    ```
- **Svelte 5 `$inspect.trace()` for Reactive Dependency Diagnostics**:
  - ❌ **Anti-Pattern: Littering Code with `console.log` Inside Effects**: Inserting arbitrary log prints into `$effect()` or template blocks to track why a component is re-rendering. This pollutes terminal and browser consoles with hundreds of duplicate lines and creates observer bias.
  - ✅ **Production Invariant**: In Svelte 5, use the `$inspect(...)` rune with `.trace()` in development mode. It logs deep stack traces and pinpoints exactly which state rune mutation triggered the reactive calculation:
    ```svelte
    <script lang="ts">
    let count = $state(0);
    let multiplier = $state(2);
    let total = $derived(count * multiplier);

    // Development diagnostic: prints whenever count or multiplier causes total to recalculate
    $inspect(total).with((type, val) => {
      console.debug(`[reactive-trace] ${type}:`, val);
    });

    // Or use $inspect.trace() inside derived calculations to log the exact dependency path:
    let loggedCalculation = $derived.by(() => {
      $inspect.trace();
      return count * multiplier;
    });
    </script>
    ```
- **SvelteKit `preloadData` for Intent-Driven Predictive Navigation**:
  - ❌ **Anti-Pattern: Relying Solely on Native `<a>` Clicks or Monolithic `data-sveltekit-preload-data="hover"` on Everything**: Enabling blanket hover prefetching across hundreds of heavy links on a page (e.g. data tables with 50 links per view). Hovering across items floods the server with unneeded prefetch requests.
  - ✅ **Production Invariant**: Programmatically trigger `preloadData(url)` with intent thresholds (e.g., focus or intentional mouse hover $>65\text{ms}$), and prefetch critical modal or route assets dynamically before user navigation:
    ```svelte
    <script lang="ts">
    import { preloadData, goto } from '$app/navigation';

    let hoverTimer: ReturnType<typeof setTimeout> | null = null;

    function handleMouseEnter(targetUrl: string) {
      // Intent gate: avoid prefetching on rapid casual pointer sweeps
      hoverTimer = setTimeout(() => {
        preloadData(targetUrl);
      }, 65);
    }

    function handleMouseLeave() {
      if (hoverTimer) clearTimeout(hoverTimer);
    }
    </script>

    <a 
      href="/analytics/dashboard" 
      onmouseenter={() => handleMouseEnter('/analytics/dashboard')}
      onmouseleave={handleMouseLeave}
    >
      Dashboard
    </a>
    ```
- **Svelte 5 Runes `$state.raw` for Performance-Critical Unproxied State**:
  - ❌ **Anti-Pattern: Deep Proxy Overhead on Immutable / Third-Party Data Structures**: Wrapping large immutable collections, Three.js scene graphs, or Monaco Editor instances with standard `$state(...)`. Svelte deeply proxies all properties, introducing unnecessary CPU cycles and memory bloat.
  - ✅ **Production Invariant**: In Svelte 5, use `$state.raw(...)` for large, complex, or third-party objects that should only trigger reactivity upon reassignment:
    ```svelte
    <script lang="ts">
    interface HeavyMetric {
      timestamp: number;
      series: Float64Array;
    }

    // $state.raw avoids deep proxying; reactivity is triggered only when reassigning `metrics`:
    let metrics = $state.raw<HeavyMetric[]>([]);

    function appendMetrics(newBatch: HeavyMetric[]) {
      // Reassign root reference to notify subscribers cleanly:
      metrics = [...metrics, ...newBatch];
    }
    </script>
    ```
- **Svelte 5 `$effect.tracking()` vs Clean Untracked Execution with `untrack`**:
  - ❌ **Anti-Pattern: Accidental Infinite Effect Loops via Implicit Dependency Tracking**: Reading telemetry, logging state, or secondary reactive signals inside an `$effect(...)` without isolating them, causing unwanted dependency subscriptions and infinite re-triggering loops.
  - ✅ **Production Invariant**: Wrap side-effect reads or secondary non-triggering dependencies in `untrack(() => ...)`:
    ```svelte
    <script lang="ts">
    import { untrack } from 'svelte';

    let count = $state(0);
    let auditLog = $state<string[]>([]);

    $effect(() => {
      // Triggers ONLY when `count` changes:
      const current = count;

      // Reading auditLog is explicitly untracked to avoid cyclic effect loops:
      untrack(() => {
        auditLog = [...auditLog, `Count reached: ${current}`];
      });
    });
    </script>
    ```
- **Svelte 5 Deterministic State Batch Flushing in Unit Tests (`tick()`)**:
  - ❌ **Anti-Pattern: Arbitrary Sleeps Waiting for Svelte 5 Signals to Flush**: Inserting `await new Promise(r => setTimeout(r, 20))` in Vitest or Playwright tests when asserting against `$state` mutations. Svelte batches reactive updates across microtasks; arbitrary sleeps fail intermittently in CI environments.
  - ✅ **Production Invariant**: Always import and await `tick()` from `svelte` immediately following state mutations to ensure the pending microtask batch is completely applied to the DOM:
    ```typescript
    import { render, screen } from '@testing-library/svelte';
    import { tick } from 'svelte';
    import Counter from './Counter.svelte';

    test('increments counter deterministically without wall-clock sleeps', async () => {
      render(Counter);
      const btn = screen.getByRole('button', { name: /increment/i });

      btn.click();
      // Flushes Svelte 5 reactive effect queue deterministically:
      await tick();

      expect(screen.getByTestId('count')).toHaveTextContent('1');
    });
    ```
- **Svelte 5 `$inspect` & `$inspect().with(...)` for Zero-Overhead Production Logging**:
  - ❌ **Anti-Pattern: Polluting `$effect` with `console.log` for State Tracing**: Using `$effect(() => console.log(state))` to debug reactive runes. This creates unnecessary subscription dependencies and leaves runtime overhead in production bundles.
  - ✅ **Production Invariant**: Use Svelte 5's `$inspect(rune)`. The compiler guarantees that `$inspect` declarations are entirely eliminated during production builds (`mode: 'production'`), ensuring zero client overhead:
    ```svelte
    <script lang="ts">
    let session = $state({ token: 'abc', authenticated: false });

    // Stripped automatically in production builds:
    $inspect(session).with((type, val) => {
      console.debug(`[Rune Debug: ${type}]`, val);
    });
    </script>
    ```
- **Svelte 5 `$state.raw` for Large Datasets & Proxy Memory Optimization**:
  - ❌ **Anti-Pattern: Deep Proxying Large Lists or GeoJSON with `$state`**: Wrapping arrays with thousands of items in `$state([...])`. Svelte 5 creates reactive proxies for every nested object, consuming excessive memory and slowing down garbage collection.
  - ✅ **Production Invariant**: Use `$state.raw` for immutable objects or large collections that are replaced wholesale. Only reassignment triggers updates, incurring zero proxy overhead:
    ```svelte
    <script lang="ts">
    interface HeavyMetric { id: string; val: number; ts: number; }

    // Bypasses recursive proxying for large datasets:
    let metrics = $state.raw<HeavyMetric[]>([]);

    function refreshMetrics(batch: HeavyMetric[]) {
      // Reassignment notifies dependents efficiently:
      metrics = batch;
    }
    </script>
    ```
- **SvelteKit Progressive Form Enhancement & Deterministic Mutation (`use:enhance`)**:
  - ❌ **Anti-Pattern: Ad-Hoc `fetch` in Forms Bypassing SvelteKit Form Actions**: Manually attaching `on:submit` with custom `fetch` handlers. This breaks progressive enhancement, loses automatic CSRF validation, and complicates error handling.
  - ✅ **Production Invariant**: Always pair SvelteKit `<form method="POST">` with `use:enhance` from `$app/forms` for seamless optimistic updates and automatic invalidation:
    ```svelte
    <script lang="ts">
    import { enhance } from '$app/forms';

    let pending = $state(false);
    </script>

    <form
      method="POST"
      action="?/save"
      use:enhance={() => {
        pending = true;
        return async ({ update }) => {
          pending = false;
          await update();
        };
      }}
    >
      <input name="title" required />
      <button type="submit" disabled={pending}>Save</button>
    </form>
    ```
- **Svelte 5 `$derived.by` for Multi-Statement Computed Logic**:
  - ❌ **Anti-Pattern: Using Side-Effectful `$effect` to Sync Derived State**: Mutating a `$state` variable inside `$effect(() => { total = subtotal - discount })`. This introduces unnecessary microtask latency, risks infinite reactivity loops, and exposes intermediate stale states to child components.
  - ✅ **Production Invariant**: Use `$derived.by(() => { ... })` for any computed calculation that requires multiple statements, loops, or complex branch conditions. It executes synchronously and tracks fine-grained reactive dependencies with zero extra ticks:
    ```svelte
    <script lang="ts">
    interface CartItem { id: string; price: number; quantity: number; }

    let items = $state<CartItem[]>([]);
    let couponRate = $state(0.1);

    // Glitch-free synchronous multi-statement derived calculation:
    const cartSummary = $derived.by(() => {
      const subtotal = items.reduce((sum, item) => sum + item.price * item.quantity, 0);
      const discount = subtotal * couponRate;
      const tax = (subtotal - discount) * 0.08;
      const total = subtotal - discount + tax;

      return { subtotal, discount, tax, total, count: items.length };
    });
    </script>
    ```
- **SvelteKit Server Route Cache Control & CDN Revalidation (`setHeaders`)**:
  - ❌ **Anti-Pattern: Returning Raw Load Data Without Cache Directives**: Returning objects from `+page.server.ts` without declaring HTTP headers. Shared CDN edge nodes or intermediate proxies may accidentally cache authenticated user session responses, or conversely flood the origin server on high-traffic public catalog queries.
  - ✅ **Production Invariant**: In `+page.server.ts` or `+server.ts`, explicitly control caching via `setHeaders`:
    ```typescript
    import type { PageServerLoad } from './$types';

    export const load: PageServerLoad = async ({ setHeaders }) => {
      // Edge CDN caches for 5 minutes; background revalidation for 24 hours:
      setHeaders({
        'cache-control': 'public, max-age=60, s-maxage=300, stale-while-revalidate=86400',
      });

      return {
        catalog: await fetchCatalogItems(),
      };
    };
    ```
- **SvelteKit Progressive Enhancement Form Actions with Idempotency Keys (`use:enhance`)**:
  - ❌ **Anti-Pattern: Double Form Submissions in `use:enhance` Without Idempotency Headers**: Using raw `<form method="POST">` or naive `use:enhance` without deduplication tokens. On slow 3G or mobile networks, impatient users click the submit button multiple times, firing multiple concurrent POST actions that create duplicate orders or double bank transfers.
  - ✅ **Production Invariant**: Bind an ephemeral idempotency key to the form state using Svelte 5 runes, attach it to submission headers in `use:enhance`, and disable the submit trigger during flight:
    ```svelte
    <script lang="ts">
    import { enhance } from '$app/forms';

    let isSubmitting = $state(false);
    let formIdempotencyKey = $state(crypto.randomUUID());
    </script>

    <form
      method="POST"
      action="?/createOrder"
      use:enhance={({ cancel }) => {
        if (isSubmitting) {
          cancel();
          return;
        }
        isSubmitting = true;

        return async ({ update, result }) => {
          try {
            await update();
            if (result.type === 'success') {
              // Rotate idempotency key only after verified success:
              formIdempotencyKey = crypto.randomUUID();
            }
          } finally {
            isSubmitting = false;
          }
        };
      }}
    >
      <input type="hidden" name="idempotencyKey" value={formIdempotencyKey} />
      <button type="submit" disabled={isSubmitting}>
        {isSubmitting ? 'Processing Order...' : 'Confirm Order'}
      </button>
    </form>
    ```
- **Svelte 5 Concurrency Fencing & Stale Async Race Condition Defense with Runes**:
  - ❌ **Anti-Pattern: Async Fetch Race Condition Overwriting Reactive State**: Calling `fetch()` inside event handlers or `$effect` without fencing tokens. If slower network responses arrive out of sequence, obsolete search or filter results overwrite the most recent user action.
  - ✅ **Production Invariant**: Use monotonic sequence counters and `AbortController` in Svelte 5 runes to fence out-of-order async responses:
    ```svelte
    <script lang="ts">
    let query = $state('');
    let results = $state<string[]>([]);
    let isPending = $state(false);

    let activeSequence = 0;
    let abortController: AbortController | null = null;

    async function handleSearch(searchQuery: string) {
      if (abortController) abortController.abort();
      abortController = new AbortController();

      const sequence = ++activeSequence;
      isPending = true;

      try {
        const response = await fetch(`/api/search?q=${encodeURIComponent(searchQuery)}`, {
          signal: abortController.signal
        });
        const data = await response.json();

        // Concurrency fence: strictly discard if newer query dispatched
        if (sequence !== activeSequence) return;
        results = data.items;
      } catch (err: any) {
        if (err.name === 'AbortError') return;
        console.error('Search failure:', err);
      } finally {
        if (sequence === activeSequence) {
          isPending = false;
        }
      }
    }
    </script>
    ```
- **SvelteKit `+server.ts` Webhook Endpoints & Raw ArrayBuffer Verification**:
  - ❌ **Anti-Pattern: Calling `await request.json()` Prior to Webhook Signature Check**: In SvelteKit API endpoints (`src/routes/api/webhooks/+server.ts`), calling `request.json()` parses the stream into memory. Re-stringifying with `JSON.stringify()` fails HMAC validation against Stripe, GitHub, or Shopify signatures.
  - ✅ **Production Invariant**: Read raw bytes via `await request.arrayBuffer()` or `await request.text()`, calculate HMAC-SHA256 with Web Crypto API (`crypto.subtle`), perform constant-time comparison, return `new Response(null, { status: 202 })`, and pass the verified event to a background job queue:
    ```typescript
    // src/routes/api/webhooks/+server.ts
    import type { RequestHandler } from './$types';
    import crypto from 'node:crypto';

    export const POST: RequestHandler = async ({ request }) => {
      // 1. Read unmutated raw text/buffer
      const rawBody = await request.text();
      const signature = request.headers.get('stripe-signature');

      if (!signature) {
        return new Response('Missing signature', { status: 401 });
      }

      const secret = process.env.STRIPE_WEBHOOK_SECRET!;
      const expected = crypto.createHmac('sha256', secret).update(rawBody, 'utf8').digest();
      const received = Buffer.from(signature, 'hex');

      if (expected.length !== received.length || !crypto.timingSafeEqual(expected, received)) {
        return new Response('Invalid signature', { status: 401 });
      }

      // 2. Immediate 202 response to avoid provider timeouts
      // Offload to background worker or durable queue
      return new Response(JSON.stringify({ received: true }), {
        status: 202,
        headers: { 'Content-Type': 'application/json' }
      });
    };
    ```
- **SvelteKit Durable Workflow Orchestration & Real-Time SSE Status Streaming**:
  - ❌ **Anti-Pattern: Synchronously Awaiting Multi-Step Distributed Tasks in `+page.server.ts`**: Running multi-step provisioning or payment pipelines inside SvelteKit form actions using `await step1(); await step2();`. Serverless runtimes (Cloudflare, Vercel) terminate executions exceeding 10–15 seconds, killing the un-compensated task.
  - ✅ **Production Invariant**: Trigger the saga via server action, return immediately with a durable `workflowId`, and expose an SSE endpoint in `src/routes/api/workflows/[id]/stream/+server.ts` streaming step-level journal updates to the Svelte 5 `$state` UI:
    ```typescript
    // src/routes/api/workflows/[id]/stream/+server.ts
    import type { RequestHandler } from './$types';

    export const GET: RequestHandler = async ({ params }) => {
      const { id } = params;

      const stream = new ReadableStream({
        async start(controller) {
          const encoder = new TextEncoder();
          const unsubscribe = sagaJournalStore.subscribe(id, (record) => {
            controller.enqueue(encoder.encode(`data: ${JSON.stringify(record)}\n\n`));
            if (record.eventType === 'STEP_COMPLETED' && record.isFinal) {
              controller.close();
            }
          });
        },
      });

      return new Response(stream, {
        headers: {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
          Connection: 'keep-alive',
        },
      });
    };
    ```
- **Server Lifecycle Hooks, SSE / WebSocket Connection Draining & Ingress Quiescence**:
  - ❌ **Anti-Pattern: Abandoned Server Streams & Abrupt Connection Termination on Node Shutdown**: When Node.js restarts or SvelteKit node-adapter containers terminate, open SSE streams and WebSocket subscriptions are abruptly dropped without sending close frames, causing clients to immediately reconnect in a thundering herd.
  - ✅ **Production Invariant**: Intercept `SIGTERM` in `hooks.server.ts`, notify active SSE/WS clients with a reconnect backoff hint and RFC 6455 1001 Close Frame, and cleanly close server streams before container exit:
    ```typescript
    // src/hooks.server.ts - Zero-Downtime Drain & SSE Stream Quiescence
    let isShuttingDown = false;
    const activeStreams = new Set<ReadableStreamDefaultController>();

    if (typeof process !== 'undefined') {
      process.on('SIGTERM', async () => {
        isShuttingDown = true;
        // Broadcast reconnect hint to active SSE clients
        const encoder = new TextEncoder();
        for (const controller of activeStreams) {
          try {
            controller.enqueue(encoder.encode('event: drain\ndata: {"retry": 5000}\n\n'));
            controller.close();
          } catch {}
        }
        activeStreams.clear();
      });
    }
    ```
- **SvelteKit Server Actions & Background Job DLQ Dead-Letter Boundary**:
  - ❌ **Anti-Pattern: Blind Unhandled Action Crashes & Unlogged Queue Failures**: Letting background tasks or webhook handlers triggered by SvelteKit actions fail silently without capturing failure taxonomy or allowing admin operators to replay dead-lettered events.
  - ✅ **Production Invariant**: Isolate async worker and server action failures, wrap failed jobs into structured diagnostic envelopes, and provide authenticated canary redrive endpoints bounded by rate limiters:
    ```typescript
    // src/routes/api/admin/dlq/redrive/+server.ts - Rate-Limited Canary Redrive Endpoint
    import { json, error } from '@sveltejs/kit';
    import type { RequestHandler } from './$types';

    export const POST: RequestHandler = async ({ request, locals }) => {
      if (!locals.user?.isAdmin) throw error(403, 'Unauthorized');

      const { dlqId, dryRun } = await request.json();
      const deadLetter = await locals.db.deadLetterEvents.findUnique({ where: { dlqId } });
      if (!deadLetter) throw error(404, 'Dead letter record not found');

      // Dispatch canary redrive with explicit X-Redrive-Attempt header
      const outcome = await replayDomainEvent(deadLetter.payload, {
        isCanary: dryRun ?? true,
        traceparent: deadLetter.traceparent
      });

      return json({ dlqId, status: outcome.success ? 'REPLAY_SUCCEEDED' : 'REPLAY_FAILED' });
    };
    ```
- **SvelteKit Server-Side Read-Through Cache, In-Process Singleflight & Cache-Control Headers**:
  - ❌ **Anti-Pattern: SSR Database Slamming & Missing Shared In-Process Deduplication**: Executing identical database queries on every incoming SSR page render or API load function without in-memory coalescing, causing database CPU spikes during traffic surges.
  - ✅ **Production Invariant**: Implement in-process singleflight coalescing inside SvelteKit server hooks / load functions with decorrelated caching and HTTP `stale-while-revalidate` response headers:
    ```typescript
    // src/routes/api/products/[id]/+server.ts - SvelteKit Resilient Singleflight Server Endpoint
    import { json, error } from '@sveltejs/kit';
    import type { RequestHandler } from './$types';

    const productInFlight = new Map<string, Promise<any>>();

    export const GET: RequestHandler = async ({ params, setHeaders, locals }) => {
      const productId = params.id;
      if (!productId) throw error(400, 'Missing product ID');

      // Coalesce concurrent SSR requests for the exact same product ID
      if (!productInFlight.has(productId)) {
        const fetchPromise = locals.db.product.findUnique({
          where: { id: productId }
        }).finally(() => {
          productInFlight.delete(productId);
        });
        productInFlight.set(productId, fetchPromise);
      }

      const product = await productInFlight.get(productId);
      if (!product) throw error(404, 'Product not found');

      // Edge CDN and browser caching with background revalidation
      setHeaders({
        'Cache-Control': 'public, max-age=60, s-maxage=300, stale-while-revalidate=600',
        'Vary': 'Accept-Encoding'
      });

      return json(product);
    };
    ```
- **SvelteKit Server Load Circuit Breakers, AbortSignal Budgets & Degraded SSR Fallbacks**:
  - ❌ **Anti-Pattern: Cascading SSR 500 Outage on External Dependency Failure**: Letting a downstream third-party service failure or slow response crash the entire SvelteKit `load` function and render an unstyled 500 server error page.
  - ✅ **Production Invariant**: Wrap downstream data queries in server-side circuit breakers with timeout budgets and deterministic fallback props, keeping the page renderable in degraded mode:
    ```typescript
    // src/routes/dashboard/+page.server.ts - SvelteKit Resilient Load with Fallback
    import type { PageServerLoad } from './$types';

    let failureCount = 0;
    let circuitOpenUntil = 0;

    export const load: PageServerLoad = async ({ fetch }) => {
      const now = Date.now();

      // Fast-fail if circuit is OPEN
      if (now < circuitOpenUntil) {
        return {
          stats: { visits: 0, conversions: 0 },
          isDegraded: true,
          notice: 'Live stats temporarily unavailable.',
        };
      }

      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 2000); // 2s budget

      try {
        const res = await fetch('https://metrics.internal/v1/stats', { signal: controller.signal });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const stats = await res.json();
        failureCount = 0;
        return { stats, isDegraded: false };
      } catch (err) {
        failureCount++;
        if (failureCount >= 5) {
          circuitOpenUntil = now + 15000; // Open circuit for 15s
        }
        return {
          stats: { visits: 0, conversions: 0 },
          isDegraded: true,
          notice: 'Live stats temporarily unavailable.',
        };
      } finally {
        clearTimeout(timeout);
      }
    };
    ```

- **SvelteKit Server Route Database Connection Scoping & PgBouncer Safety**:
  - ❌ **Anti-Pattern: Creating Ad-Hoc Connection Pools or Abandoned Transactions in `+page.server.ts`**: Initializing `new Pool()` inside route loaders or failing to release connections when a server action errors out, quickly exhausting database connections during SSR rendering spikes.
  - ✅ **Production Invariant**: Maintain a singleton database pool instance in `$lib/server/db.ts`, execute all mutations in scoped transaction helpers, and ensure `event.locals` carries pre-scoped transaction contexts:
    ```typescript
    // src/routes/api/orders/+server.ts
    import { json, error } from '@sveltejs/kit';
    import { pool } from '$lib/server/db';
    import type { RequestHandler } from './$types';

    export const POST: RequestHandler = async ({ request }) => {
      const { customerId, items } = await request.json();

      // Scoped connection acquisition: guarantees release on route completion or error
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        await client.query('SET LOCAL statement_timeout = 3000');

        const orderRes = await client.query(
          'INSERT INTO orders (customer_id, status) VALUES ($1, $2) RETURNING id',
          [customerId, 'pending']
        );
        const orderId = orderRes.rows[0].id;

        for (const item of items) {
          await client.query(
            'INSERT INTO order_items (order_id, product_id, quantity) VALUES ($1, $2, $3)',
            [orderId, item.productId, item.quantity]
          );
        }

        await client.query('COMMIT');
        return json({ orderId, status: 'created' });
      } catch (err: any) {
        await client.query('ROLLBACK').catch(() => {});
        throw error(500, `Transaction aborted: ${err.message}`);
      } finally {
        client.release(); // Crucial: prevent connection pool exhaustion in SSR workloads
      }
    };
    ```

- **SvelteKit Server Loaders Keyset Pagination & Anti-N+1 Batching**:
  - ❌ **Anti-Pattern: `OFFSET` Pagination & N+1 Queries in `load` Functions**: Using `searchParams.get('page')` with `OFFSET` in `+page.server.ts` or fetching related records sequentially for each row inside the server loader.
  - ✅ **Production Invariant**: Implement opaque keyset cursors via search params and batch fetch child relations in a single database query:
    ```typescript
    // src/routes/dashboard/orders/+page.server.ts
    import type { PageServerLoad } from './$types';
    import { pool } from '$lib/server/db';
    import { error } from '@sveltejs/kit';

    export const load: PageServerLoad = async ({ url, locals }) => {
      const cursor = url.searchParams.get('cursor');
      const limit = 20;

      const client = await pool.connect();
      try {
        let query = `
          SELECT id, tenant_id, status, total_amount, created_at
          FROM orders
          WHERE tenant_id = $1`;
        const params: any[] = [locals.tenantId];

        if (cursor) {
          const [cursorTime, cursorId] = Buffer.from(cursor, 'base64url').toString().split('|');
          query += ` AND (created_at, id) < ($2, $3)`;
          params.push(cursorTime, cursorId);
        }

        query += ` ORDER BY created_at DESC, id DESC LIMIT $${params.length + 1}`;
        params.push(limit);

        const ordersRes = await client.query(query, params);
        if (ordersRes.rows.length === 0) {
          return { orders: [], nextCursor: null };
        }

        // Anti-N+1: Batch fetch items for all loaded orders in exactly ONE query
        const orderIds = ordersRes.rows.map((r) => r.id);
        const itemsRes = await client.query(
          `SELECT order_id, product_id, quantity, unit_price FROM order_items WHERE order_id = ANY($1::UUID[])`,
          [orderIds]
        );

        const itemsByOrderId = new Map<string, any[]>();
        for (const item of itemsRes.rows) {
          const list = itemsByOrderId.get(item.order_id) ?? [];
          list.push(item);
          itemsByOrderId.set(item.order_id, list);
        }

        const enriched = ordersRes.rows.map((order) => ({
          ...order,
          items: itemsByOrderId.get(order.id) ?? [],
        }));

        const last = enriched[enriched.length - 1];
        const nextCursor = enriched.length === limit
          ? Buffer.from(`${last.created_at.toISOString()}|${last.id}`).toString('base64url')
          : null;

        return { orders: enriched, nextCursor };
      } catch (err: any) {
        throw error(500, `Failed to load orders: ${err.message}`);
      } finally {
        client.release();
      }
    };
    ```

- **Optimistic Form Actions with Version Epochs & 409 Conflict Handling in SvelteKit**:
  - ❌ **Anti-Pattern: Unchecked Form Post Without Version Token**: Executing updates in SvelteKit `actions` without verifying entity version, silently overwriting intervening writes from concurrent browser tabs.
  - ✅ **Production Invariant**: Include hidden `<input name="version" />` in forms, assert `version = expected` in form actions, and return `fail(409, { conflict: true, currentData })` to render reactive conflict resolution modals:
    ```typescript
    // src/routes/items/[id]/+page.server.ts
    import { fail } from '@sveltejs/kit';
    import type { Actions } from './$types';
    import { dbPool } from '$lib/server/db';

    export const actions: Actions = {
      update: async ({ request, params }) => {
        const data = await request.formData();
        const title = data.get('title') as string;
        const version = parseInt(data.get('version') as string, 10);
        const itemId = params.id;

        const client = await dbPool.connect();
        try {
          const res = await client.query(
            `UPDATE items 
             SET title = $1, version = version + 1, updated_at = NOW() 
             WHERE id = $2 AND version = $3 
             RETURNING id, title, version`,
            [title, itemId, version]
          );

          if (res.rows.length === 0) {
            const current = await client.query('SELECT id, title, version FROM items WHERE id = $1', [itemId]);
            return fail(409, {
              conflict: true,
              message: 'This record was modified by another user.',
              currentRecord: current.rows[0],
            });
          }

          return { success: true, item: res.rows[0] };
        } finally {
          client.release();
        }
      },
    };

    // SvelteKit Read-After-Write Consistency: Sticky Primary Session Cookie & InvalidateAll
    // When executing mutations in Form Actions, set a short-lived sticky write epoch cookie.
    // In load() functions, check the cookie to decide whether to query Primary vs Replica,
    // preventing stale data during immediate client-side invalidateAll() navigations.
    export const actionsWithSticky: Actions = {
      create: async ({ request, cookies }) => {
        const formData = await request.formData();
        const text = formData.get('text') as string;

        const client = await dbPoolPrimary.connect();
        try {
          const res = await client.query(
            'INSERT INTO posts (content, created_at) VALUES ($1, NOW()) RETURNING id, content, created_at',
            [text]
          );

          // Set 5-second sticky write epoch cookie to pin subsequent SSR load() to Primary
          cookies.set('x-db-write-epoch', Date.now().toString(), {
            path: '/',
            maxAge: 5,
            httpOnly: true,
            sameSite: 'lax',
          });

          return { success: true, post: res.rows[0] };
        } finally {
          client.release();
        }
      },
    };

    // SvelteKit Soft-Delete & Instant Undo Invariant: Atomic Tombstone Batching
    // Form Action returns a unique batchId. If the user clicks "Undo" within 10s,
    // the restore action uses the exact batchId to unmask parent and child entities.
    export const actionsWithSoftDelete: Actions = {
      deleteWorkspace: async ({ request, locals }) => {
        const formData = await request.formData();
        const workspaceId = formData.get('workspaceId') as string;
        const batchId = crypto.randomUUID();

        const client = await dbPoolPrimary.connect();
        try {
          const res = await client.query(
            `WITH del_ws AS (
               UPDATE workspaces SET
                 deleted_at = NOW(), deleted_by = $1, deleted_batch_id = $2, version = version + 1
               WHERE id = $3 AND deleted_at IS NULL
               RETURNING id
             )
             UPDATE documents SET
               deleted_at = NOW(), deleted_by = $1, deleted_batch_id = $2
             WHERE workspace_id IN (SELECT id FROM del_ws) AND deleted_at IS NULL;`,
            [locals.user.id, batchId, workspaceId]
          );

          return { success: true, workspaceId, batchId, undoable: true };
        } finally {
          client.release();
        }
      },

      undoDeleteWorkspace: async ({ request }) => {
        const formData = await request.formData();
        const workspaceId = formData.get('workspaceId') as string;
        const batchId = formData.get('batchId') as string;

        const client = await dbPoolPrimary.connect();
        try {
          await client.query(
            `WITH res_ws AS (
               UPDATE workspaces SET
                 deleted_at = NULL, deleted_by = NULL, deleted_batch_id = NULL, version = version + 1
               WHERE id = $1 AND deleted_batch_id = $2::uuid
               RETURNING id
             )
             UPDATE documents SET
               deleted_at = NULL, deleted_by = NULL, deleted_batch_id = NULL
             WHERE workspace_id IN (SELECT id FROM res_ws) AND deleted_batch_id = $2::uuid;`,
            [workspaceId, batchId]
          );

          return { success: true, restored: true };
        } finally {
          client.release();
        }
      },
    };
    ```

- **SvelteKit 5 Time-Partitioned Keyset Pagination & Sargable Range Loaders**:
  - ❌ **Anti-Pattern: Unbounded Timeseries Sweeps & Non-Sargable Date Filters**: Querying partitioned tables using `where(sql`DATE(created_at) = ${date}`)` or omitting time ranges, causing queries to hit every single child partition and stalling the server route.
  - ✅ **Production Invariant**: In SvelteKit load functions, enforce sargable date bounds using ISO-8601 query parameters and pass explicit `gte(created_at, start)` and `lt(created_at, end)` to ensure $O(1)$ partition pruning:
    ```svelte
    <!-- src/routes/audit-logs/+page.svelte -->
    <script lang="ts">
      let { data } = $props();
      let selectedRange = $state({
        start: data.start,
        end: data.end,
      });
    </script>

    <div class="audit-dashboard">
      <div class="filter-bar">
        <span>Partitions Scanned: <strong>{data.prunedPartitionCount} (Pruned)</strong></span>
        <span class="badge">Query Time: {data.executionTimeMs}ms</span>
      </div>

      <table class="data-table">
        <thead>
          <tr>
            <th>Event ID</th>
            <th>Type</th>
            <th>Timestamp (Partition Key)</th>
          </tr>
        </thead>
        <tbody>
          {#each data.events as event (event.id)}
            <tr>
              <td><code>{event.id}</code></td>
              <td>{event.eventType}</td>
              <td>{new Date(event.createdAt).toISOString()}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>

    <!-- Svelte 5 Reactive MVCC Bloat & HOT Health Monitor -->
    <script lang="ts">
      interface TableHealth {
        name: string;
        deadRatioPct: number;
        hotRatioPct: number;
        totalBytes: number;
      }

      let { tables = [] }: { tables: TableHealth[] } = $props();
      let bloatedTables = $derived(tables.filter((t) => t.deadRatioPct > 15));
      let hotEfficiencyAlerts = $derived(tables.filter((t) => t.hotRatioPct < 85));
    </script>

    <div class="mvcc-monitor">
      <header>
        <h3>Database MVCC Bloat & HOT Health</h3>
        {#if bloatedTables.length > 0}
          <span class="badge danger">{bloatedTables.length} Bloated Tables</span>
        {:else}
          <span class="badge success">All Relations Clean</span>
        {/if}
      </header>

      <div class="metrics-grid">
        {#each tables as table (table.name)}
          <div class="card">
            <h4>{table.name}</h4>
            <p>Dead Tuples: <strong>{table.deadRatioPct}%</strong></p>
            <p>HOT Efficiency: <strong class={table.hotRatioPct >= 90 ? 'text-green' : 'text-red'}>{table.hotRatioPct}%</strong></p>
          </div>
        {/each}
      </div>
    </div>

    <!-- Svelte 5 Reactive WAL Generation & Checkpoint Health Monitor -->
    <script lang="ts">
      interface ReplicationSlot {
        slotName: string;
        retainedMB: number;
        walStatus: string;
        active: boolean;
      }

      interface CheckpointReport {
        timedPct: number;
        writeTimeMs: number;
        syncTimeMs: number;
        slots: ReplicationSlot[];
      }

      let { report }: { report: CheckpointReport } = $props();
      let isCheckpointHealthy = $derived(report.timedPct >= 95);
      let riskySlots = $derived(report.slots.filter((s) => s.retainedMB > 5120 || s.walStatus !== 'normal' || !s.active));
    </script>

    <div class="wal-monitor">
      <header>
        <h3>WAL & Checkpoint Durability Monitor</h3>
        <span class={isCheckpointHealthy ? 'badge success' : 'badge warning'}>
          Timed Checkpoints: {report.timedPct}%
        </span>
      </header>

      {#if riskySlots.length > 0}
        <div class="alert danger">
          <strong>Disk Meltdown Warning:</strong> {riskySlots.length} replication slots retaining > 5GB WAL!
        </div>
      {/if}

      <div class="slots-list">
        {#each report.slots as slot (slot.slotName)}
          <div class="slot-item">
            <span>{slot.slotName}</span>
            <span class={slot.retainedMB > 5120 ? 'text-red font-bold' : ''}>{slot.retainedMB} MB</span>
            <span class="status">{slot.walStatus}</span>
          </div>
        {/each}
      </div>
    </div>

    <!-- Svelte 5 Reactive Heavyweight Lock Contention & Deadlock Monitor -->
    <script lang="ts">
      interface BlockedQuery {
        blockedPid: number;
        blockedUser: string;
        blockingPid: number;
        blockingUser: string;
        blockedStatement: string;
        currentStatementInBlockingProcess: string;
        waitSeconds: number;
      }

      interface LockContentionReport {
        blockedQueries: BlockedQuery[];
        deadlocksCount: number;
        unindexedFksCount: number;
      }

      let { report }: { report: LockContentionReport } = $props();
      let hasSevereContention = $derived(report.blockedQueries.some((q) => q.waitSeconds > 2.0));
      let isClusterClean = $derived(report.blockedQueries.length === 0 && report.unindexedFksCount === 0);
    </script>

    <div class="lock-sentinel">
      <header>
        <h3>Database Lock Contention & Deadlock Sentinel</h3>
        <span class={isClusterClean ? 'badge success' : 'badge warning'}>
          Blocked Queries: {report.blockedQueries.length}
        </span>
      </header>

      {#if hasSevereContention}
        <div class="alert danger">
          <strong>Head-of-Line Contention Alert:</strong> Queries waiting > 2s on contested table locks!
        </div>
      {/if}

      {#if report.unindexedFksCount > 0}
        <div class="alert warning">
          <strong>Schema Warning:</strong> {report.unindexedFksCount} unindexed foreign keys risking lock escalation!
        </div>
      {/if}

      <div class="blocks-list">
        {#each report.blockedQueries as block (block.blockedPid)}
          <div class="block-card">
            <span class="pid">PID {block.blockedPid} blocked by PID {block.blockingPid}</span>
            <span class="wait">{block.waitSeconds}s</span>
            <p class="query">{block.blockedStatement}</p>
          </div>
        {/each}
      </div>
    </div>

    <!-- Svelte 5 Reactive High Availability Failover & Standby Health Monitor -->
    <script lang="ts">
      interface StandbyNode {
        ip: string;
        name: string;
        syncState: 'sync' | 'quorum' | 'async' | 'potential';
        lagMb: number;
        lagSeconds: number;
      }

      interface HAClusterStatus {
        isPrimary: boolean;
        isReadOnly: boolean;
        hasZeroRpoSync: boolean;
        standbys: StandbyNode[];
      }

      let { cluster }: { cluster: HAClusterStatus } = $props();
      let hasSevereLag = $derived(cluster.standbys.some((s) => s.lagSeconds > 5.0));
      let isClusterHealthy = $derived(cluster.hasZeroRpoSync && !hasSevereLag);
    </script>

    <div class="ha-cluster-monitor">
      <header>
        <h3>Database High Availability Sentinel</h3>
        <span class={isClusterHealthy ? 'badge success' : 'badge danger'}>
          {cluster.isPrimary ? 'Leader Active' : 'Standby Node'} ({cluster.hasZeroRpoSync ? 'Zero-RPO' : 'Async'})
        </span>
      </header>

      {#if !cluster.hasZeroRpoSync}
        <div class="alert danger">
          <strong>RPO Warning:</strong> Cluster lacks active synchronous standby! Data loss possible on un-fenced failover.
        </div>
      {/if}

      <div class="standby-grid">
        {#each cluster.standbys as standby (standby.ip)}
          <div class="standby-card" class:lagging={standby.lagSeconds > 5.0}>
            <span class="name">{standby.name} ({standby.syncState})</span>
            <span class="lag">{standby.lagSeconds}s lag ({standby.lagMb} MB)</span>
          </div>
        {/each}
      </div>
    </div>

    <!-- Svelte 5 Reactive Disaster Recovery & WAL Archiving SLA Monitor -->
    <script lang="ts">
      interface DRArchivalStatus {
        archivedCount: number;
        lastArchivedWal: string;
        secondsSinceLastArchive: number;
        isArchivalFailing: boolean;
        pendingWalCount: number;
        dataChecksumsEnabled: boolean;
      }

      let { drStatus }: { drStatus: DRArchivalStatus } = $props();
      let isRpoAtRisk = $derived(drStatus.secondsSinceLastArchive > 300 || drStatus.isArchivalFailing);
      let isPitrGuaranteed = $derived(drStatus.dataChecksumsEnabled && !isRpoAtRisk);
    </script>

    <div class="dr-sla-card" class:critical={isRpoAtRisk}>
      <header>
        <h4>Disaster Recovery & PITR Sentinel</h4>
        <span class={isPitrGuaranteed ? 'badge success' : 'badge danger'}>
          {isPitrGuaranteed ? 'PITR Protected' : 'RPO SLA Breached'}
        </span>
      </header>

      {#if !drStatus.dataChecksumsEnabled}
        <div class="alert danger">
          <strong>Silent Bit Rot Risk:</strong> data_checksums is disabled! Backups may harbor undetected corrupt blocks.
        </div>
      {/if}

      <div class="metrics-grid">
        <div class="metric">
          <label>WAL Archive Latency</label>
          <span class="value">{drStatus.secondsSinceLastArchive}s</span>
        </div>
        <div class="metric">
          <label>Pending Archival Queue</label>
          <span class="value">{drStatus.pendingWalCount} segments</span>
        </div>
        <div class="metric">
          <label>Total Archived Segments</label>
          <span class="value">{drStatus.archivedCount}</span>
        </div>
      </div>
    </div>

    <!-- Svelte 5 Reactive Change Data Capture (CDC) Slot Health & Lag Sentinel -->
    <script lang="ts">
      interface CDCSlotAuditData {
        slotName: string;
        active: boolean;
        walStatus: string;
        lagMb: number;
        catalogXminAge: number;
        isDiskAtRisk: boolean;
        isCatalogBloated: boolean;
      }

      let { cdcSlot }: { cdcSlot: CDCSlotAuditData } = $props();
      let isCriticalLag = $derived(cdcSlot.lagMb > 10240 || cdcSlot.walStatus === 'lost');
      let statusTheme = $derived(cdcSlot.active && !isCriticalLag ? 'success' : 'danger');
    </script>

    <div class="cdc-slot-card" class:warning={cdcSlot.isCatalogBloated} class:critical={isCriticalLag}>
      <header>
        <h4>CDC Slot: {cdcSlot.slotName}</h4>
        <span class={`badge ${statusTheme}`}>
          {cdcSlot.walStatus.toUpperCase()} ({cdcSlot.active ? 'ACTIVE' : 'INACTIVE'})
        </span>
      </header>

      {#if isCriticalLag}
        <div class="alert danger">
          <strong>Disk Exhaustion Warning:</strong> Replication lag ({cdcSlot.lagMb.toFixed(1)} MB) exceeds safety threshold!
        </div>
      {/if}

      {#if cdcSlot.isCatalogBloated}
        <div class="alert warning">
          <strong>Catalog Bloat Warning:</strong> catalog_xmin age ({cdcSlot.catalogXminAge}) is pinning autovacuum horizons!
        </div>
      {/if}

      <div class="metrics-grid">
        <div class="metric">
          <label>WAL Retained Lag</label>
          <span class="value">{cdcSlot.lagMb.toFixed(1)} MB</span>
        </div>
        <div class="metric">
          <label>Catalog xmin Age</label>
          <span class="value">{cdcSlot.catalogXminAge.toLocaleString()} txns</span>
        </div>
      </div>
    </div>

    <!-- Svelte 5 Row-Level Security (RLS) & Multi-Tenant Sentinel Component -->
    <script lang="ts">
      interface RLSTableStatus {
        tableName: string;
        isRLSEnabled: boolean;
        isRLSForced: boolean;
        policyCount: number;
        hasLeftmostTenantIndex: boolean;
        isCompliant: boolean;
        violations: string[];
      }

      let { rlsTable } = $props<{ rlsTable: RLSTableStatus }>();

      let isOwnerBypassRisk = $derived(rlsTable.isRLSEnabled && !rlsTable.isRLSForced);
      let isSeqScanRisk = $derived(!rlsTable.hasLeftmostTenantIndex);
      let statusTheme = $derived(rlsTable.isCompliant ? 'success' : 'danger');
    </script>

    <div class="rls-audit-card" class:warning={isOwnerBypassRisk} class:critical={!rlsTable.isRLSEnabled || isSeqScanRisk}>
      <header>
        <h4>Relation: {rlsTable.tableName}</h4>
        <span class={`badge ${statusTheme}`}>
          {rlsTable.isCompliant ? 'SECURE' : 'VULNERABLE'}
        </span>
      </header>

      {#if !rlsTable.isRLSEnabled}
        <div class="alert danger">
          <strong>Critical Isolation Breach:</strong> RLS is completely disabled on this multi-tenant relation!
        </div>
      {:else if isOwnerBypassRisk}
        <div class="alert warning">
          <strong>Owner Bypass Hazard:</strong> Table lacks FORCE ROW LEVEL SECURITY; administrative connections bypass filters.
        </div>
      {/if}

      {#if isSeqScanRisk}
        <div class="alert warning">
          <strong>Performance Risk:</strong> Missing leftmost index on tenant_id; queries risk full sequential table scans.
        </div>
      {/if}

      <div class="metrics-grid">
        <div class="metric">
          <label>RLS Forced</label>
          <span class="value">{rlsTable.isRLSForced ? 'YES (Protected)' : 'NO (Vulnerable)'}</span>
        </div>
        <div class="metric">
          <label>Active Policies</label>
          <span class="value">{rlsTable.policyCount}</span>
        </div>
        <div class="metric">
          <label>Leftmost Tenant Index</label>
          <span class="value">{rlsTable.hasLeftmostTenantIndex ? 'OPTIMAL' : 'MISSING'}</span>
        </div>
      </div>
    </div>

    <!-- Svelte 5 Query Plan & Extended Statistics Sentinel Component -->
    <script lang="ts">
      interface PlannerAudit {
        randomPageCost: number;
        jitEnabled: boolean;
        extendedStatisticsCount: number;
        isPlannerCalibrated: boolean;
        violations: string[];
      }

      let { audit } = $props<{ audit: PlannerAudit }>();

      let isHighRandomCost = $derived(audit.randomPageCost > 1.5);
      let isJitRisk = $derived(audit.jitEnabled);
      let statusBadge = $derived(audit.isPlannerCalibrated ? 'OPTIMIZED' : 'NEEDS CALIBRATION');
    </script>

    <div class="planner-sentinel-card" class:warning={!audit.isPlannerCalibrated}>
      <header>
        <h4>Query Planner & Cost Model Sentinel</h4>
        <span class={`badge ${audit.isPlannerCalibrated ? 'success' : 'warning'}`}>
          {statusBadge}
        </span>
      </header>

      {#if isHighRandomCost}
        <div class="alert warning">
          <strong>Storage Cost Mismatch:</strong> random_page_cost is {audit.randomPageCost}. On NVMe SSDs, calibrate to 1.1 to prevent index scan avoidance.
        </div>
      {/if}

      {#if isJitRisk}
        <div class="alert warning">
          <strong>OLTP Latency Risk:</strong> JIT compilation is enabled. Turn off to avoid 30ms-150ms LLVM compilation spikes.
        </div>
      {/if}

      <div class="metrics-grid">
        <div class="metric">
          <label>random_page_cost</label>
          <span class="value">{audit.randomPageCost}</span>
        </div>
        <div class="metric">
          <label>OLTP JIT Status</label>
          <span class="value">{audit.jitEnabled ? 'ENABLED (Risk)' : 'OFF (Safe)'}</span>
        </div>
        <div class="metric">
          <label>Extended Statistics</label>
          <span class="value">{audit.extendedStatisticsCount} relations</span>
        </div>
      </div>
    </div>

    <!-- Svelte 5 Database Memory & Disk Spill Sentinel Component -->
    <script lang="ts">
      interface MemorySentinelAudit {
        workMem: string;
        tempFileLimit: string;
        logTempFiles: number;
        totalTempSpilledFormatted: string;
        isMemorySafe: boolean;
        violations: string[];
      }

      let { audit } = $props<{ audit: MemorySentinelAudit }>();

      let isSpillRisk = $derived(audit.violations.length > 0);
      let statusText = $derived(audit.isMemorySafe ? 'PROTECTED' : 'AT RISK');
    </script>

    <div class="memory-sentinel-card" class:danger={isSpillRisk}>
      <header>
        <h4>Database Memory & Disk Spill Sentinel</h4>
        <span class={`badge ${audit.isMemorySafe ? 'success' : 'danger'}`}>
          {statusText}
        </span>
      </header>

      {#if isSpillRisk}
        <div class="alert danger">
          <strong>Memory / Storage Vulnerability:</strong>
          <ul>
            {#each audit.violations as violation}
              <li>{violation}</li>
            {/each}
          </ul>
        </div>
      {/if}

      <div class="metrics-grid">
        <div class="metric">
          <label>Baseline work_mem</label>
          <span class="value">{audit.workMem}</span>
        </div>
        <div class="metric">
          <label>temp_file_limit</label>
          <span class="value">{audit.tempFileLimit}</span>
        </div>
        <div class="metric">
          <label>Cumulative Disk Spill</label>
          <span class="value">{audit.totalTempSpilledFormatted}</span>
        </div>
      </div>
    </div>

    <!-- Svelte 5 Full-Text Search & GIN Index Sentinel Component -->
    <script lang="ts">
      interface GinIndexHealth {
        indexName: string;
        tableName: string;
        indexSizePretty: string;
        fastUpdateEnabled: boolean;
        isBloated: boolean;
      }

      interface SearchSentinelAudit {
        hasTrgmExtension: boolean;
        hasUnaccentExtension: boolean;
        ginIndexes: GinIndexHealth[];
        isSearchOptimized: boolean;
        violations: string[];
      }

      let { audit } = $props<{ audit: SearchSentinelAudit }>();

      let isAtRisk = $derived(audit.violations.length > 0 || !audit.isSearchOptimized);
      let statusText = $derived(audit.isSearchOptimized ? 'OPTIMIZED' : 'AT RISK');
    </script>

    <div class="search-sentinel-card" class:danger={isAtRisk}>
      <header>
        <h4>Database Full-Text Search & GIN Sentinel</h4>
        <span class={`badge ${audit.isSearchOptimized ? 'success' : 'danger'}`}>
          {statusText}
        </span>
      </header>

      {#if isAtRisk}
        <div class="alert danger">
          <strong>Search / GIN Indexing Vulnerability:</strong>
          <ul>
            {#each audit.violations as violation}
              <li>{violation}</li>
            {/each}
          </ul>
        </div>
      {/if}

      <div class="metrics-grid">
        <div class="metric">
          <label>pg_trgm Extension</label>
          <span class="value">{audit.hasTrgmExtension ? 'Active' : 'Missing'}</span>
        </div>
        <div class="metric">
          <label>GIN Indexes Audited</label>
          <span class="value">{audit.ginIndexes.length} relations</span>
        </div>
        <div class="metric">
          <label>FastUpdate Health</label>
          <span class="value">{audit.ginIndexes.filter(i => i.isBloated).length === 0 ? 'Normal' : 'Stalled'}</span>
        </div>
      </div>
    </div>

    <!-- Svelte 5 JSONB Document & TOAST Sentinel Component -->
    <!-- Invariant: Uses $state.raw for multi-megabyte JSON payloads to prevent deep proxy tracking overhead -->
    <script lang="ts">
      interface JsonbAuditSummary {
        totalJsonbColumns: number;
        toastBytesTotal: number;
        bloatedIndexes: string[];
        unconstrainedColumns: string[];
      }

      let { summary } = $props<{ summary: JsonbAuditSummary }>();

      // Raw unproxied state for heavy document rendering
      let rawJsonDocument = $state.raw<Record<string, unknown>>({});

      let hasBloat = $derived(summary.bloatedIndexes.length > 0);
      let hasMissingChecks = $derived(summary.unconstrainedColumns.length > 0);
      let isHealthy = $derived(!hasBloat && !hasMissingChecks);
    </script>

    <div class="jsonb-sentinel-card" class:warning={!isHealthy}>
      <header>
        <h4>Database JSONB Document & TOAST Sentinel</h4>
        <span class={`badge ${isHealthy ? 'success' : 'warning'}`}>
          {isHealthy ? 'GOVERNED' : 'ACTION REQUIRED'}
        </span>
      </header>

      {#if hasBloat}
        <div class="alert warning">
          <strong>Default jsonb_ops GIN Bloat Detected:</strong>
          <p>The following indexes should be migrated to jsonb_path_ops:</p>
          <ul>
            {#each summary.bloatedIndexes as idx}
              <li>{idx}</li>
            {/each}
          </ul>
        </div>
      {/if}
    </div>

    <!-- Svelte 5 BRIN Index & Heap Correlation Sentinel Component -->
    <!-- Invariant: Uses $derived for real-time correlation evaluation and warning display -->
    <script lang="ts">
      interface BrinAuditSummary {
        totalBrinIndexes: number;
        spaceSavedBytes: number;
        degradedCorrelations: Array<{ table: string; column: string; correlation: number }>;
        missingAutosummarize: string[];
      }

      let { brinSummary } = $props<{ brinSummary: BrinAuditSummary }>();

      let hasDegradedCorr = $derived(brinSummary.degradedCorrelations.length > 0);
      let hasMissingAutosummarize = $derived(brinSummary.missingAutosummarize.length > 0);
      let isBrinOptimal = $derived(!hasDegradedCorr && !hasMissingAutosummarize);
    </script>

    <div class="brin-sentinel-card" class:warning={!isBrinOptimal}>
      <header>
        <h4>Database BRIN Index & Correlation Sentinel</h4>
        <span class={`badge ${isBrinOptimal ? 'success' : 'danger'}`}>
          {isBrinOptimal ? 'OPTIMAL' : 'CORRELATION DEGRADED'}
        </span>
      </header>

      {#if hasDegradedCorr}
        <div class="alert danger">
          <strong>Degraded Physical Disk Correlation (|corr| &lt; 0.95):</strong>
          <ul>
            {#each brinSummary.degradedCorrelations as item}
              <li>{item.table}.{item.column}: corr = {item.correlation.toFixed(3)} (Re-cluster required)</li>
            {/each}
          </ul>
        </div>
      {/if}

      {#if hasMissingAutosummarize}
        <div class="alert warning">
          <strong>Missing autosummarize = on:</strong>
          <p>The following indexes are vulnerable to hot-head sequential scans:</p>
          <ul>
            {#each brinSummary.missingAutosummarize as idx}
              <li>{idx}</li>
            {/each}
          </ul>
        </div>
      {/if}
    </div>

    <!-- Svelte 5 pgvector & HNSW Retrieval Sentinel Component -->
    <script lang="ts">
      interface VectorAuditSummary {
        version: string;
        uncompressedFp32Columns: string[];
        lowEfIndexes: string[];
        hasIterativeScanEnabled: boolean;
      }

      let { vectorSummary } = $props<{ vectorSummary: VectorAuditSummary }>();

      let isVersionSupported = $derived(
        parseFloat(vectorSummary.version.split('.').slice(0, 2).join('.')) >= 0.7
      );
      let hasMemoryWaste = $derived(vectorSummary.uncompressedFp32Columns.length > 0);
      let isVectorHealthy = $derived(
        isVersionSupported && !hasMemoryWaste && vectorSummary.lowEfIndexes.length === 0
      );
    </script>

    <div class="vector-sentinel-card" class:warning={!isVectorHealthy}>
      <header>
        <h4>pgvector HNSW & Quantization Sentinel</h4>
        <span class={`badge ${isVectorHealthy ? 'success' : 'danger'}`}>
          {isVectorHealthy ? 'HEALTHY' : 'OPTIMIZATION NEEDED'}
        </span>
      </header>

      {#if !isVersionSupported}
        <div class="alert danger">
          <strong>Outdated pgvector Version ({vectorSummary.version}):</strong>
          <p>Upgrade to &gt;= 0.7.0 for halfvec and hnsw.iterative_scan support.</p>
        </div>
      {/if}

      {#if hasMemoryWaste}
        <div class="alert warning">
          <strong>Uncompressed FP32 Embeddings (Memory Waste):</strong>
          <ul>
            {#each vectorSummary.uncompressedFp32Columns as col}
              <li>{col} (Migrate to halfvec to cut RAM by 50%)</li>
            {/each}
          </ul>
        </div>
      {/if}

      {#if vectorSummary.lowEfIndexes.length > 0}
        <div class="alert warning">
          <strong>Suboptimal HNSW Search Depth (ef_construction &lt; 64):</strong>
          <ul>
            {#each vectorSummary.lowEfIndexes as idx}
              <li>{idx}</li>
            {/each}
          </ul>
        </div>
      {/if}
    </div>
    ```

- **Svelte 5 Runes: Temporal Interval Collision Defense & PostGIS GeoJSON Spatial Reactivity**:
  - ❌ **Anti-Pattern: Naive Closed Boundary Checks, Cyclic Map Center Mutation, and Blocking GeoJSON Reactivity**:
    - Checking interval overlaps with closed comparison (`startA <= endB && endA >= startB`), which falsely flags contiguous time slots (e.g. 10:00-11:00 and 11:00-12:00) as colliding.
    - Synchronizing Mapbox/Leaflet spatial viewports by updating `$state` inside map move listeners without `untrack()`, creating infinite update cycles between camera position and marker lists.
    - Storing massive multi-megabyte GeoJSON feature collections inside deep reactive proxies, causing high garbage collection overhead and frame drops during map panning.
  - ✅ **Production Invariant**:
    - Implement half-open interval overlap algebra `[startA, endA) ∩ [startB, endB) ≠ ∅` $\iff \max(\text{startA}, \text{startB}) < \min(\text{endA}, \text{endB})$ using Svelte 5 `$derived`.
    - Isolate external map camera events using `untrack()` inside `$effect` to ensure unidirectional data flow between viewport coordinates and API queries.
    - Freeze GeoJSON data with `Object.freeze()` before assigning to `$state` or use lightweight coordinate arrays to eliminate proxy overhead.
    ```svelte
    <script lang="ts">
      import { untrack } from 'svelte';

      interface BookingSlot {
        id: string;
        start: Date;
        end: Date;
      }

      let { existingSlots = [] }: { existingSlots: BookingSlot[] } = $props();

      // Temporal range inputs:
      let requestedStartStr = $state('');
      let requestedEndStr = $state('');

      const requestedStart = $derived(requestedStartStr ? new Date(requestedStartStr) : null);
      const requestedEnd = $derived(requestedEndStr ? new Date(requestedEndStr) : null);

      // Invariant: Half-open interval boundary collision detection
      const isValidWindow = $derived.by(() => {
        if (!requestedStart || !requestedEnd) return false;
        return requestedStart < requestedEnd;
      });

      const conflictingSlot = $derived.by(() => {
        if (!isValidWindow || !requestedStart || !requestedEnd) return null;

        // Mathematical half-open overlap: max(A_start, B_start) < min(A_end, B_end)
        return existingSlots.find((slot) => {
          const maxStart = requestedStart > slot.start ? requestedStart : slot.start;
          const minEnd = requestedEnd < slot.end ? requestedEnd : slot.end;
          return maxStart < minEnd;
        }) ?? null;
      });

      const hasConflict = $derived(conflictingSlot !== null);
    </script>

    <div class="booking-form">
      <input type="datetime-local" bind:value={requestedStartStr} />
      <input type="datetime-local" bind:value={requestedEndStr} />

      {#if !isValidWindow && requestedStartStr && requestedEndStr}
        <p class="error">Start time must precede end time.</p>
      {:else if hasConflict}
        <div class="alert danger">
          <strong>Time Slot Unavailable:</strong>
          Conflicts with existing reservation ({conflictingSlot?.start.toLocaleTimeString()} - {conflictingSlot?.end.toLocaleTimeString()}).
        </div>
      {:else if isValidWindow}
        <button type="submit" class="btn primary">Confirm Reservation</button>
      {/if}
    </div>
    ```

- **SvelteKit Federated Cross-Database Data Loading & Pushdown-Safe Route Streaming**:
  - ❌ **Anti-Pattern: Blocking Server Loads on Slow Federated FDW Queries**: Running cross-database queries against foreign tables inside synchronous `+page.server.ts` `load()` functions without streaming promises or timeout boundaries, stalling SSR and rendering blank screens.
  - ✅ **Production Invariant**: Return non-blocking promises from `+page.server.ts` to enable progressive streaming via Svelte 5 snippets and `{#await}`, passing parameterized bounds that push filtering directly to remote PostgreSQL servers:
    ```ts
    // src/routes/analytics/+page.server.ts
    import type { PageServerLoad } from './$types';
    import { dbPool } from '$lib/server/db';
    import { error } from '@sveltejs/kit';

    export const load: PageServerLoad = async ({ url, locals }) => {
      if (!locals.user) throw error(401, 'Unauthorized');

      const startDate = url.searchParams.get('start') || new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10);
      const endDate = url.searchParams.get('end') || new Date().toISOString().slice(0, 10);

      // Return streaming promise for federated cross-database metrics
      const federatedMetricsPromise = (async () => {
        const client = await dbPool.connect();
        try {
          // Explicit parameterized query pushing WHERE and GROUP BY to foreign cluster
          const res = await client.query(`
            SELECT
              tenant_id,
              SUM(event_count)::BIGINT AS total_events
            FROM foreign_analytics.daily_active_users
            WHERE activity_date >= $1::DATE
              AND activity_date < $2::DATE
            GROUP BY tenant_id
            ORDER BY total_events DESC
            LIMIT 50;
          `, [startDate, endDate]);
          return res.rows;
        } finally {
          client.release();
        }
      })();

      return {
        streamed: {
          metrics: federatedMetricsPromise,
        },
      };
    };
    ```
    ```svelte
    <!-- src/routes/analytics/+page.svelte -->
    <script lang="ts">
      import type { PageData } from './$types';

      let { data }: { data: PageData } = $props();
    </script>

    <div class="analytics-dashboard">
      <h1>Federated Analytics Overview</h1>

      {#await data.streamed.metrics}
        <div class="skeleton-loader p-4 bg-zinc-800 animate-pulse rounded-lg">
          Loading cross-cluster metrics...
        </div>
      {:then rows}
        <table class="w-full text-left text-sm text-zinc-300">
          <thead>
            <tr>
              <th class="p-2 border-b border-zinc-700">Tenant</th>
              <th class="p-2 border-b border-zinc-700">Total Events</th>
            </tr>
          </thead>
          <tbody>
            {#each rows as row}
              <tr>
                <td class="p-2 font-mono">{row.tenant_id}</td>
                <td class="p-2 font-semibold text-emerald-400">{row.total_events}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      {:catch err}
        <div class="alert danger p-4 bg-rose-950 text-rose-200 rounded">
          Failed to load federated metrics: {err.message}
        </div>
      {/await}
    </div>
    ```