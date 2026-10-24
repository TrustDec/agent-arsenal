---
description: Vue 3 & Nuxt 3 strict reactivity discipline, Composition API, and SSR hydration safety
globs: **/*.{vue,ts,js}
alwaysApply: false
---

# Vue 3 & Nuxt 3 Strict Reactivity & SSR Discipline

> Add these rules to your project if developing in Vue 3 (Vite / Nuxt 3) with TypeScript.

## 1. Composition API & Script Setup Invariants
- **Exclusively Use `<script setup lang="ts">`**: Strictly ban Vue 2 Options API (`export default { data(), methods: {} }`) in modern codebases.
- **Vue 3.5+ Reactive Props Destructuring**:
  - In Vue 3.5+, destructuring props directly is officially supported via compile-time transform:
    ```ts
    const { count = 0, disabled = false } = defineProps<{ count?: number; disabled?: boolean }>()
    ```
  - For projects on Vue < 3.5, NEVER destructure props without `toRefs(props)` or `toRef(props, 'count')`. Doing so permanently breaks reactivity tracking.
- **`useTemplateRef` for Typed DOM Element Access (Vue 3.5+)**:
  - Prefer `useTemplateRef<HTMLInputElement>('inputRef')` over legacy `const inputRef = ref<HTMLInputElement | null>(null)`. It decouples variable naming from template strings and guarantees type safety.
- **`ref()` vs `reactive()` Discipline**:
  - Prefer `ref()` for discrete state variables and primitives.
  - ❌ **NEVER reassign a `reactive()` object**: `state = { ... }` destroys the original reactive proxy and breaks template tracking. Always mutate individual properties or use `Object.assign(state, payload)`.
- **`shallowRef()` for Heavy 3rd-Party Instances**:
  - Always use `shallowRef()` or `markRaw()` for complex non-Vue instances (Three.js objects, Monaco Editor, Leaflet/Mapbox maps, ECharts, Web Audio nodes).
  - Deep reactivity proxies on large external objects cause catastrophic memory and CPU overhead.

## 2. Nuxt 3 SSR & Hydration Hygiene
- ❌ **PREVENT SSR CROSS-REQUEST STATE POLLUTION**:
  - ❌ **NEVER declare `ref()`, `reactive()`, or mutable state at module scope (outside setup / component functions)**:
    ```ts
    // ❌ CATASTROPHIC SECURITY HOLE: Leaks state across all concurrent user requests in Node SSR!
    const currentUser = ref<User | null>(null)
    export default defineComponent({ ... })
    ```
  - Always encapsulate SSR state inside `useState('key', () => initialValue)` or inside a Pinia store instance.
- ❌ **ZERO BROWSER GLOBALS IN SETUP ROOT**:
  - Never reference `window`, `document`, `localStorage`, `sessionStorage`, or `navigator` in the setup root execution scope.
  - Wrap client-only code in `onMounted()`, `if (import.meta.client)`, or enclose components in `<ClientOnly>`.
- **Data Fetching Invariance**:
  - Always use Nuxt composables (`useFetch()` or `useAsyncData()`) for data loaded during page rendering.
  - ❌ **NEVER use raw `axios` or bare `fetch()` inside setup root**: Bare calls run once on the server and again during client hydration, creating unnecessary waterfalls and DOM hydration mismatches.
  - Always supply a unique, deterministic key to `useAsyncData('user-profile', ...)` when dynamic route parameters or pagination are involved.
- **Payload Serialization Discipline**:
  - Everything returned from server handlers (`server/api/*`) or `useAsyncData` is serialized via `devalue` into the HTML page payload.
  - Never return non-serializable objects (Functions, Symbols, raw DOM nodes, or classes with cyclic references) from SSR data loaders.
- **Head & SEO Management**:
  - Use `useHead()` or `useSeoMeta()` reactively. Never inject raw meta/script tags into the DOM via raw JavaScript strings.

## 3. Lifecycle Hygiene & Memory Leak Prevention
- **Mandatory Side-Effect Cleanup**:
  - Every timer (`setInterval`, `setTimeout`), event listener (`window.addEventListener`), WebSocket subscription, or observer (`ResizeObserver`, `IntersectionObserver`) started in `onMounted()` MUST be cleanly unregistered in `onUnmounted()` or `onBeforeUnmount()`.
- **Async Watcher Cleanup (`onWatcherCleanup` in Vue 3.5+)**:
  - Use `onWatcherCleanup()` or the watcher's 3rd `onCleanup` parameter to abort in-flight requests or timers before triggering a new search:
    ```ts
    watch(searchQuery, (newQuery) => {
      const controller = new AbortController()
      onWatcherCleanup(() => controller.abort())
      fetchResults(newQuery, { signal: controller.signal })
    })
    ```
- **Narrow Watchers**:
  - Avoid `{ deep: true }` watchers on large nested structures. Deep watching traverses every property on every tick, destroying framerates. Watch specific getters instead: `watch(() => state.filter.status, ...)`

## 4. Pinia State Management Invariants
- **Setup Stores Syntax**: Prefer the Composition API syntax (`defineStore('user', () => { ... })`) for clean composable interoperability.
- ❌ **MANDATORY `storeToRefs`**:
  - When destructuring state or getters from a Pinia store in components, ALWAYS use `storeToRefs(store)`:
    ```ts
    const userStore = useUserStore()
    const { profile, isAuthenticated } = storeToRefs(userStore) // ✅ Preserves reactivity
    const { logout } = userStore // ✅ Actions can be destructured directly
    ```

## 5. Nuxt 3 Nitro Server Routes & Validation
- **Event Handler Discipline**:
  - Always write server endpoints using `defineEventHandler(async (event) => { ... })`.
- **Runtime Request Validation**:
  - Never trust raw incoming data. Always use `readValidatedBody(event, schema.parse)` or `getValidatedQuery(event, schema.parse)` with Zod/Valibot:
    ```ts
    export default defineEventHandler(async (event) => {
      const body = await readValidatedBody(event, loginSchema.parse)
      return { success: true }
    })
    ```
- **Error Propagation**:
  - ❌ **NEVER throw raw strings or generic `new Error()`**: Throw `createError({ statusCode: 400, statusMessage: 'Invalid input' })` to guarantee proper HTTP status codes and JSON error formatting.

## 6. Modern Component Architecture, Frontend Taste & Accessibility (a11y)
- **Accessibility (a11y) & Keyboard Navigation**:
  - All interactive elements (modals, dropdowns, accordions, comboboxes) MUST support keyboard navigation (Tab, Shift+Tab, Escape to close, Enter/Space to activate) and maintain visible focus rings (`focus-visible:ring-2 focus-visible:outline-none`).
  - Use headless accessible component primitives (Radix Vue / Reka UI) rather than building un-accessible custom div-based widgets.
  - Ensure custom icons and image buttons include descriptive `aria-label` attributes.
- **Teleport SSR Hydration Safety**:
  - In Nuxt SSR, teleporting directly to document body (`<Teleport to="body">`) during initial server render causes hydration mismatch errors because the server HTML has not mounted client document targets.
  - Wrap Teleport components in `<ClientOnly>` or guard rendering with a client-mounted flag:
    ```vue
    <script setup lang="ts">
    const isMounted = ref(false)
    onMounted(() => { isMounted.value = true })
    </script>

    <template>
      <Teleport to="body" v-if="isMounted">
        <div class="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm" role="dialog" aria-modal="true">
          <!-- Modal Content -->
        </div>
      </Teleport>
    </template>
    ```
- **Image Optimization & CLS Elimination**:
  - Always use `<NuxtImg>` or `<NuxtPicture>` for user-facing media to automatically generate modern formats (AVIF, WebP), responsive `srcset` breakpoints, and blur placeholders.
  - Always specify explicit `width` and `height` attributes or CSS `aspect-ratio` to eradicate Cumulative Layout Shift.
- **GPU-Accelerated Transitions**:
  - Always use `mode="out-in"` on `<Transition>` to ensure the exiting component completely leaves before the entering component enters, preventing simultaneous dual-element layout jumps:
    ```vue
    <Transition name="fade" mode="out-in">
      <component :is="activeComponent" />
    </Transition>
    ```
  - Animate strictly GPU-composited properties (`transform`, `opacity`). Never animate layout dimensions (`width`, `height`, `margin`, `padding`).

## 7. Frontend Taste, Optimistic Updates & Reactive Performance
- **Optimistic UI Updates with Rollback**:
  - For high-frequency interactive actions (likes, toggles, task completion), update the local reactive state immediately before the network request resolves, with explicit rollback on error:
    ```ts
    async function toggleFavorite(itemId: string) {
      const item = items.value.find(i => i.id === itemId)
      if (!item) return
      const previousState = item.isFavorite
      item.isFavorite = !previousState // Immediate optimistic feedback

      try {
        await $fetch(`/api/items/${itemId}/favorite`, { method: 'POST' })
      } catch (err) {
        item.isFavorite = previousState // Rollback on failure
        toast.error('Failed to update favorite status')
      }
    }
    ```
- **Micro-Interactions & Hover Delay Ergonomics**:
  - ❌ **NEVER trigger tooltips or popovers with zero delay**: Instant hover triggers create visual clutter as the user sweeps their cursor across the viewport.
  - Implement a 150–200ms open delay on tooltips and 0ms close delay (`delayDuration: 150` in Radix Vue / Reka UI).
  - Use tactile active states (`active:scale-[0.98] transition-transform duration-75`) on buttons to give physical feedback upon click.
- **`shallowRef` for Large Data Grids & Virtualized Lists**:
  - When rendering data tables or infinite scroll feeds containing hundreds or thousands of rows, wrap the collection in `shallowRef([])`.
  - Vue's deep reactivity creates a reactive Proxy for every single row and cell, consuming massive heap memory and stalling scroll performance. Replace the array reference wholesale when data updates: `items.value = newItems`.
- **Accessible Focus Trap & Focus Restoration**:
  - Modal dialogues and slide-over drawers MUST trap keyboard focus within the dialog container while open.
  - Upon closing, focus MUST be returned programmatically to the element that triggered the dialog, preserving keyboard navigation flow for screen readers and power users.
- **`useAsyncData` Key Deduplication Invariant**:
  - In Nuxt 3, `useAsyncData` uses its first argument as the deduplication cache key across SSR and client hydration:
    ```ts
    // ❌ Broken: Omitting unique key or dynamic parameters causes cross-route cache collisions
    const { data } = await useAsyncData(() => $fetch(`/api/posts/${route.params.id}`))

    // ✅ Invariant: Parameterized unique cache key
    const { data } = await useAsyncData(
      `post:${route.params.id}`,
      () => $fetch(`/api/posts/${route.params.id}`),
      { watch: [() => route.params.id] }
    )
    ```
- **Custom Directive Event Listener Cleanup**:
  - Custom directives attached to `window` or `document` (e.g. `v-click-outside`, `v-shortcut`) MUST remove all event listeners in the `unmounted(el)` hook.
  - Failing to remove listeners retains detached DOM trees indefinitely, creating silent single-page application memory leaks.
- **Vue 3.4+ `defineModel()` Two-Way Binding Invariant**:
  - In Vue 3.4+, ALWAYS use `defineModel()` for two-way component bindings.
  - Ban verbose legacy `defineProps(['modelValue'])` and `defineEmits(['update:modelValue'])` boilerplate:
    ```vue
    <script setup lang="ts">
    // ✅ Vue 3.4+ Invariant: Typed two-way reactive model with modifiers
    const count = defineModel<number>('count', { default: 0 })
    const [modelValue, modelModifiers] = defineModel<string>({
      set(val) {
        return modelModifiers.trim ? val.trim() : val
      }
    })
    </script>
    ```
- **Nuxt Server Handlers & Nitro Middleware Memory Hygiene**:
  - Event handlers in `server/api/` or `server/middleware/` run inside persistent Node.js/Nitro worker processes.
  - ❌ **NEVER declare mutable caches or append unpruned listeners at top-level module scope**:
    ```ts
    // ❌ Memory Leak: userTokens grows unbounded across all tenant requests
    const userTokens = new Map<string, string>()
    export default defineEventHandler((event) => { ... })
    ```
  - Use Nitro storage (`useStorage('cache')`) or Redis for server caching, guaranteeing TTL eviction and multi-replica safety.
- **Accessible Headless Primitives (Radix Vue / Reka UI)**:
  - For complex widgets (dialogs, dropdown menus, comboboxes, command palettes), use tested accessible headless primitives (e.g. Radix Vue / Reka UI) rather than rolling naive `v-if` divs. This guarantees ARIA role semantics, keyboard navigation (`ArrowDown`, `Home`, `End`, `Escape`), and focus restoration out of the box.
- **Vue 3.5+ `useId()` Hydration-Safe ID Generation**:
  - ❌ **NEVER use `Math.random()`, UUIDs, or client-incrementing counters** to generate HTML `id`, `for`, or `aria-describedby` attributes in SSR components. This triggers Vue hydration attribute mismatches.
  - ✅ **Vue 3.5+ Invariant**: Use `useId()` to produce deterministic, collision-free IDs that match between server render and client hydration:
    ```vue
    <script setup lang="ts">
    const emailInputId = useId()
    const errorId = useId()
    </script>

    <template>
      <label :for="emailInputId">Email Address</label>
      <input :id="emailInputId" :aria-describedby="errorId" type="email" />
      <span :id="errorId" class="error">Invalid email format</span>
    </template>
    ```
- **Nuxt 3 Route Middleware Navigation Discipline**:
  - In Nuxt route middleware (`defineNuxtRouteMiddleware`), ALWAYS return `navigateTo(to)` or `abortNavigation(error)`:
    ```ts
    // ❌ Broken: Omitting return causes concurrent race conditions and partial renders
    export default defineNuxtRouteMiddleware((to) => {
      if (!isAuthenticated) navigateTo('/login') // Dangling navigation!
    })

    // ✅ Invariant: Return the navigation promise
    export default defineNuxtRouteMiddleware((to) => {
      if (!isAuthenticated) {
        return navigateTo('/login', { redirectCode: 302 })
      }
    })
    ```
- **`v-memo` Subtree Optimization for High-Density Virtual Lists & Tables**:
  - In lists with hundreds of rows or data table cells, standard Virtual DOM diffing traverses every child VNode on each keystroke or unrelated state change.
  - ✅ **Invariant**: Use `v-memo` to skip VDOM diffing entirely when row dependencies have not changed:
    ```vue
    <template>
      <div 
        v-for="item in items" 
        :key="item.id" 
        v-memo="[item.id === selectedId, item.status, item.updatedAt]"
      >
        <p>{{ item.name }} - {{ item.status }}</p>
      </div>
    </template>
    ```
- **Composable Lifecycle Cleanup with `onScopeDispose`**:
  - ❌ **Anti-Pattern**: Attaching window event listeners, intervals, or WebSocket subscriptions inside composables without ensuring teardown when the calling component unmounts.
  - ✅ **Production Invariant**: Use `onScopeDispose` inside headless composables. Unlike `onUnmounted`, `onScopeDispose` executes correctly whether invoked within a component setup, Pinia store, or custom effect scope:
    ```ts
    import { onScopeDispose } from 'vue';

    export function useWindowResize(handler: () => void) {
      window.addEventListener('resize', handler);
      onScopeDispose(() => {
        window.removeEventListener('resize', handler);
      });
    }
    ```

---

## 8. Watcher Race Cancellation, Composable Ergonomics & Deterministic SSR
- **Watcher Asynchronous Race Cancellation with `onWatcherCleanup` (Vue 3.5+)**:
  - ❌ **The Asynchronous Stale Overwrite Trap**: When a watcher triggers an async fetch on search input, slow responses from an earlier keystroke can resolve *after* a newer keystroke, overwriting fresh data with stale results.
  - ✅ **Vue 3.5+ Invariant**: Use `onWatcherCleanup` with `AbortController` to cancel in-flight operations when the watched value mutates:
    ```vue
    <script setup lang="ts">
    import { ref, watch, onWatcherCleanup } from 'vue';

    const searchQuery = ref('');
    const searchResults = ref<Item[]>([]);

    watch(searchQuery, async (newQuery) => {
      const controller = new AbortController();
      // Register cleanup callback invoked before the next watch execution or unmount:
      onWatcherCleanup(() => controller.abort());

      try {
        const res = await fetch(`/api/search?q=${encodeURIComponent(newQuery)}`, {
          signal: controller.signal
        });
        searchResults.value = await res.json();
      } catch (err: any) {
        if (err.name !== 'AbortError') throw err;
      }
    });
    </script>
    ```
- **Composable Argument Flexibility with `toValue` & `MaybeRefOrGetter` (Vue 3.3+)**:
  - Headless composables should flexibly accept plain values, `Ref<T>`, or getter functions `() => T`:
    ```ts
    import { toValue, computed, type MaybeRefOrGetter } from 'vue';

    export function useFormattedCurrency(amount: MaybeRefOrGetter<number>) {
      // toValue reactively normalizes plain values, refs, or getters
      return computed(() => {
        const val = toValue(amount);
        return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(val);
      });
    }
    ```
- **Deterministic SSR Hydration Hygiene**:
  - ❌ **Total Ban on Non-Deterministic Invocations in SSR Templates**: Invoking `Math.random()`, `Date.now()`, `crypto.randomUUID()`, or checking `window.innerWidth` during setup or template execution generates differing markup between server and client, causing hydration mismatches.
  - ✅ **Production Invariant**:
    - Use Nuxt/Vue `useId()` for deterministic, accessible HTML element IDs.
    - Wrap client-specific dynamic widgets (e.g. local time displays or browser viewport banners) in `<ClientOnly>` with a lightweight skeleton placeholder.
- **Server Endpoint Caching & Multi-Tenant Isolation with `defineCachedEventHandler` (Nitro / Nuxt 3)**:
  - ❌ **The Multi-Tenant Shared Cache Data Leak**: Wrapping an endpoint in `defineCachedEventHandler` without a customized `getKey` function causes Nitro to key caches strictly by route path. If User A requests `/api/dashboard`, User B will receive User A's cached private data.
  - ✅ **Production Invariant**:
    - Restrict `defineCachedEventHandler` strictly to public, unauthenticated data or supply explicit cache keys incorporating tenant context:
    ```ts
    // server/api/catalog.get.ts
    export default defineCachedEventHandler(
      async (event) => {
        const query = getQuery(event);
        return await fetchPublicProducts(query.category as string);
      },
      {
        maxAge: 60 * 5, // Cache for 5 minutes
        swr: true,      // Stale-While-Revalidate background refresh
        name: 'public-catalog',
        getKey: (event) => {
          const query = getQuery(event);
          return `cat:${query.category || 'all'}`;
        }
      }
    );
    ```








