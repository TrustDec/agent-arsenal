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
- **Reactivity Overhead Optimization with `shallowRef` & `shallowReactive`**:
  - ❌ **The Deep Proxy Memory Inflation Trap**: Wrapping a 10,000-row array of complex nested objects in `ref()` or `reactive()` causes Vue to recursively walk every property and wrap each nested object in a `Proxy`. This can increase memory consumption by 3–5x and block the main thread for 100ms+ during initial ingestion.
  - ✅ **Production Invariant**:
    - For large immutable collections (e.g. data tables, GeoJSON, chart datasets, markdown ASTs), ALWAYS use `shallowRef`:
    ```vue
    <script setup lang="ts">
    import { shallowRef } from 'vue';

    interface HeavyRecord {
      id: string;
      meta: Record<string, unknown>;
    }

    // Only .value assignment is reactive; nested properties are not wrapped in Proxies:
    const records = shallowRef<HeavyRecord[]>([]);

    async function loadData() {
      const response = await fetchLargeCatalog();
      // Whole-replacement triggers reactivity cleanly without nested proxy overhead:
      records.value = response;
    }
    </script>
    ```
- **Granular Error Boundaries with `<NuxtErrorBoundary>` & `onErrorCaptured`**:
  - ❌ Letting an unhandled exception in a non-critical sub-component (e.g., a recommendations sidebar or comments widget) crash the entire page with a fatal full-screen Nuxt error page (`error.vue`).
  - ✅ **Production Invariant**:
    - Isolate volatile widgets using `<NuxtErrorBoundary>`:
    ```vue
    <template>
      <div class="product-layout">
        <ProductMainDetails :product="product" />

        <NuxtErrorBoundary>
          <!-- If recommendations fail, only this section displays error fallback -->
          <RecommendedProducts :category-id="product.categoryId" />
          <template #error="{ error, clearError }">
            <div class="p-4 border border-rose-500/20 bg-rose-500/5 rounded-lg">
              <p class="text-sm text-rose-400">Could not load recommendations.</p>
              <button @click="clearError" class="text-xs text-rose-300 underline mt-1">Retry</button>
            </div>
          </template>
        </NuxtErrorBoundary>
      </div>
    </template>
    ```
- **Deterministic SSR Accessible IDs with `useId()` (Vue 3.5+ & Nuxt 3.10+)**:
  - ❌ **The Hydration Mismatch Accessibility Trap**: Generating dynamic IDs using `Math.random()` or `nanoid()` inside components produces one ID during Node.js SSR and a mismatched ID during browser hydration, triggering `[Vue warn]: Hydration attribute mismatch on id` and breaking `<label for="...">` screen-reader bindings.
  - ✅ **Production Invariant**: Always use the native `useId()` composable to guarantee deterministic, collision-free identifier generation across SSR and client hydration:
    ```vue
    <script setup lang="ts">
    import { useId } from 'vue';

    // Generates deterministic IDs like "v-0", matching exactly on server and client:
    const inputId = useId();
    const errorId = useId();
    </script>

    <template>
      <div class="form-group">
        <label :for="inputId">Work Email</label>
        <input :id="inputId" type="email" :aria-describedby="errorId" />
        <p :id="errorId" class="error-text">Please enter a valid company address.</p>
      </div>
    </template>
    ```
- **Custom Object Preservation with Nuxt Payload Reducers & Revivers**:
  - ❌ **The Hydration Type-Degradation Bug**: Returning rich objects (e.g. `Set`, `Map`, `Decimal.js`, or custom classes) from `useAsyncData` causes Nuxt's SSR JSON payload serializer to downgrade them into plain strings or empty objects, leading to runtime crashes (`value.has is not a function`) on the client.
  - ✅ **Production Invariant**: Register custom payload serializers with `definePayloadReducer` and `definePayloadReviver` in a Nuxt plugin:
    ```ts
    // plugins/payload-decimal.ts
    import Decimal from 'decimal.js';

    export default defineNuxtPlugin(() => {
      // 1. Serialize on server:
      definePayloadReducer('Decimal', (val) => val instanceof Decimal && val.toString());

      // 2. Hydrate as genuine class instance on client:
      definePayloadReviver('Decimal', (val) => new Decimal(val));
    });
    ```

---

## 9. Modern `defineModel` Ergonomics, Shallow Ref Performance & SSR Browser Isolation
- **Modern Declarative Two-Way Binding with `defineModel` (Vue 3.4+)**:
  - ❌ **The Verbose Prop/Emit Boilerplate**: Writing manual `props: ['modelValue']` and `emit('update:modelValue', val)` boilerplate creates synchronization bugs, missing type definitions, and bloated component code.
  - ✅ **Production Invariant**: Use Vue 3.4+ `defineModel()` for fully type-safe, bidirectional reactive models:
    ```vue
    <script setup lang="ts">
    // Two-way bound model with modifiers and default value:
    const model = defineModel<string>({ default: '', required: false });
    const isVisible = defineModel<boolean>('visible', { default: false });
    </script>

    <template>
      <input v-model="model" type="text" />
      <button @click="isVisible = !isVisible">Toggle</button>
    </template>
    ```
- **`shallowRef` & `markRaw` for Massive Datasets & Heavy Third-Party Instances**:
  - ❌ **The Deep Reactive Proxy Memory Bloat**: Wrapping large collections (e.g. 50,000 data table rows, GeoJSON features) or complex third-party class instances (Monaco Editor, Chart.js, Three.js scenes) in standard `ref()` or `reactive()` forces Vue to recursively proxy every nested property, causing multi-megabyte heap allocation spikes and sluggish frame rates.
  - ✅ **Production Invariant**: Use `shallowRef()` for large immutable collections and `markRaw()` for non-reactive third-party objects:
    ```vue
    <script setup lang="ts">
    import { shallowRef, markRaw, onMounted } from 'vue';
    import * as monaco from 'monaco-editor';

    // Shallow ref tracks only reference replacement (.value = newArray):
    const largeDataset = shallowRef<DataPoint[]>([]);

    let editorInstance: monaco.editor.IStandaloneCodeEditor | null = null;

    onMounted(() => {
      const container = document.getElementById('editor')!;
      // Mark as raw to prevent Vue reactivity proxying:
      editorInstance = markRaw(
        monaco.editor.create(container, { value: '// code', language: 'typescript' })
      );
    });
    </script>
    ```
- **SSR Browser API Isolation & `import.meta.client` Guards**:
  - ❌ **The SSR Server Crash on `window` / `localStorage`**: Referencing `window`, `document`, `navigator`, or `localStorage` directly in `<script setup>` top-level scope crashes the Node/Nitro SSR server with `ReferenceError: window is not defined` during SSR page rendering.
  - ✅ **Production Invariant**: Gate browser-only APIs behind `import.meta.client` or defer execution to `onMounted()`:
    ```vue
    <script setup lang="ts">
    import { ref, onMounted } from 'vue';

    const theme = ref<string>('light');

    // Safe: onMounted only executes on client:
    onMounted(() => {
      theme.value = localStorage.getItem('user-theme') ?? 'light';
    });

    function saveTheme(newTheme: string) {
      theme.value = newTheme;
      if (import.meta.client) {
        localStorage.setItem('user-theme', newTheme);
      }
    }
    </script>
    ```

---

## 10. Nuxt 3 `useAsyncData` Dynamic Key Scoping, Custom Debounced Refs & Teleport Hydration
- **Nuxt 3 `useAsyncData` Dynamic Cache Key Isolation**:
  - ❌ **The Static Key Data Cross-Contamination Bug**: Using a static key like `useAsyncData('user-profile', () => fetchUser(route.params.id))` causes Nuxt to return cached profile data of user A when the client navigates to user B's profile page.
  - ✅ **Production Invariant**: Always include dynamic parameters in the key string, or pass reactive getters to watch:
    ```vue
    <script setup lang="ts">
    const route = useRoute();

    // Key dynamically tracks param, refreshing automatically on route change:
    const { data: user, status } = await useAsyncData(
      () => `user-${route.params.id}`,
      () => $fetch(`/api/users/${route.params.id}`)
    );
    </script>
    ```
- **Performance Debouncing with Vue `customRef`**:
  - ❌ **The Fragmented `watch` + `setTimeout` State Spaghetti**: Managing search debouncing via manual `watch` handlers and timer IDs creates race conditions with rapid typing and leaves dangling timeouts when components unmount.
  - ✅ **Production Invariant**: Encapsulate debouncing into a reusable `customRef` that integrates seamlessly with `v-model`:
    ```ts
    import { customRef } from 'vue';

    export function useDebouncedRef<T>(value: T, delay = 300) {
      let timeout: ReturnType<typeof setTimeout>;
      return customRef((track, trigger) => ({
        get() {
          track();
          return value;
        },
        set(newValue: T) {
          clearTimeout(timeout);
          timeout = setTimeout(() => {
            value = newValue;
            trigger();
          }, delay);
        },
      }));
    }
    ```
- **Teleport SSR Target Mounting & Hydration Crash Prevention**:
  - ❌ **The Missing Teleport Target Hydration Error**: Teleporting to an element (`<Teleport to="#drawer-portal">`) that is rendered later in the DOM tree or conditioned by a client-side flag causes SSR hydration failures (`Cannot find target element`).
  - ✅ **Production Invariant**: Wrap dynamic teleports inside `<ClientOnly>` or verify the target element exists after mount:
    ```vue
    <template>
      <ClientOnly>
        <Teleport to="#modal-root">
          <div class="modal-dialog">
            <slot />
          </div>
        </Teleport>
      </ClientOnly>
    </template>
    ```

---

## 11. Nuxt 3 Navigation Return Discipline, Pinia `$patch` Batching & Post-Flush DOM Watchers
- **Nuxt 3 Route Middleware Navigation Return Discipline (`return navigateTo(...)`)**:
  - ❌ **The Middleware Fallthrough Race Bug**: Calling `navigateTo('/login')` inside a Nuxt route middleware without returning its result causes execution to fall through, executing subsequent middleware or rendering protected component lifecycles before the client can redirect:
    ```ts
    // DANGEROUS: Missing return statement!
    export default defineNuxtRouteMiddleware((to) => {
      const auth = useAuthStore();
      if (!auth.isAuthenticated) {
        navigateTo('/login'); // Missing return!
      }
    });
    ```
  - ✅ **Production Invariant**: Always `return navigateTo(...)`:
    ```ts
    export default defineNuxtRouteMiddleware((to) => {
      const auth = useAuthStore();
      if (!auth.isAuthenticated) {
        return navigateTo({
          path: '/login',
          query: { redirect: to.fullPath },
        });
      }
    });
    ```
- **Pinia `$patch` Atomic State Mutation Batching**:
  - ❌ **The Cascading Reactive Notification Penalty**: Mutating 5 Pinia state properties sequentially in a tight loop triggers 5 distinct subscriber notifications and watcher evaluations.
  - ✅ **Production Invariant**: Batch multi-property updates into a single reactive notification tick using `$patch`:
    ```ts
    const cart = useCartStore();

    // Batched into a single mutation event:
    cart.$patch((state) => {
      state.items.push(newItem);
      state.totalQuantity += 1;
      state.lastUpdated = Date.now();
    });
    ```
- **Vue 3.5+ `watchEffect` Timing Control (`flush: 'post'` vs `watchPostEffect`)**:
  - ❌ **The Stale DOM Layout Measurement**: By default, `watch` and `watchEffect` run before the DOM is updated. Reading scroll height or element dimensions inside the watcher returns layout metrics from before the reactive state change.
  - ✅ **Production Invariant**: Use `watchPostEffect` or `{ flush: 'post' }` when measuring or scrolling the rendered DOM:
    ```vue
    <script setup lang="ts">
    import { ref, watchPostEffect } from 'vue';

    const messages = ref<string[]>([]);
    const containerRef = useTemplateRef<HTMLDivElement>('container');

    // Runs strictly after DOM has completed rendering the new messages:
    watchPostEffect(() => {
      if (containerRef.value) {
        containerRef.value.scrollTop = containerRef.value.scrollHeight;
      }
    });
    </script>
    ```
- **Nuxt 3 `useCookie` Security Hardening & Chunking Defense**:
  - ❌ **The Plaintext & Truncated Cookie Hazard**: Storing authentication or session tokens in `useCookie('token')` without setting `httpOnly: true`, `secure: true`, and `sameSite: 'lax'` exposes tokens to client-side XSS exfiltration. Furthermore, cookies exceeding 4096 bytes are silently dropped or truncated by web browsers, triggering intermittent authentication loss.
  - ✅ **Production Invariant**: Always enforce strict cookie security attributes, and keep payload sizes well below 4KB:
    ```ts
    const authToken = useCookie('auth_token', {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'lax',
      maxAge: 60 * 60 * 24 * 7, // 7 days
      path: '/',
    });
    ```
- **Composable Memory Leak Defense with `onScopeDispose`**:
  - ❌ **The Dangling Composable Listener Leak**: Setting up `window.addEventListener`, `setInterval`, or WebSocket connections inside custom Vue composables without registering cleanup callbacks causes massive event listener leaks and memory retention whenever calling components are unmounted.
  - ✅ **Production Invariant**: Always bind cleanup to the active effect scope lifecycle using `onScopeDispose`:
    ```ts
    import { ref, onScopeDispose } from 'vue';

    export function useNetworkStatus() {
      const isOnline = ref(typeof navigator !== 'undefined' ? navigator.onLine : true);

      const handleOnline = () => { isOnline.value = true; };
      const handleOffline = () => { isOnline.value = false; };

      if (typeof window !== 'undefined') {
        window.addEventListener('online', handleOnline);
        window.addEventListener('offline', handleOffline);

        onScopeDispose(() => {
          window.removeEventListener('online', handleOnline);
          window.removeEventListener('offline', handleOffline);
        });
      }

      return { isOnline };
    }
    ```
- **`shallowRef` & `markRaw` for High-Overhead Heavy Instances**:
  - ❌ **The Deep Reactive Proxy Performance Collapse**: Wrapping complex third-party instances (Mapbox GL, Leaflet, Three.js scenes, Monaco Editor, WebGL buffers) in `ref()` forces Vue to recursively inspect and wrap thousands of nested properties in reactive `Proxy` objects, causing severe CPU spikes and memory bloat.
  - ✅ **Production Invariant**: Use `shallowRef` for instances and `markRaw` for raw classes to bypass reactive overhead:
    ```vue
    <script setup lang="ts">
    import { shallowRef, onMounted, onScopeDispose, markRaw } from 'vue';
    import * as monaco from 'monaco-editor';

    const editorContainer = useTemplateRef<HTMLDivElement>('editorContainer');
    const editorInstance = shallowRef<monaco.editor.IStandaloneCodeEditor | null>(null);

    onMounted(() => {
      if (editorContainer.value) {
        editorInstance.value = markRaw(
          monaco.editor.create(editorContainer.value, {
            value: 'console.log("hello world");',
            language: 'typescript',
          })
        );
      }
    });

    onScopeDispose(() => {
      editorInstance.value?.dispose();
    });
    </script>
    ```
- **Nuxt 3 Nitro Server Route Error Sanitization (`createError`)**:
  - ❌ **The Unfiltered Database Error Leak**: Catching an error in a Nitro server route (`server/api/...`) and rethrowing it directly leaks database connection strings, table schemas, and SQL syntax details to the client browser in production.
  - ✅ **Production Invariant**: Sanitize and throw via `createError` with safe client-facing messages:
    ```ts
    // server/api/projects/[id].get.ts
    export default defineEventHandler(async (event) => {
      const id = getRouterParam(event, 'id');
      try {
        const project = await db.query.projects.findFirst({
          where: eq(projects.id, id),
        });
        if (!project) {
          throw createError({
            statusCode: 404,
            statusMessage: 'Project not found',
          });
        }
        return project;
      } catch (err: any) {
        if (err.statusCode) throw err;
        console.error('[Database Error]', err); // Server-side log with full details
        throw createError({
          statusCode: 500,
          statusMessage: 'Internal server error', // Sanitized message for client
        });
      }
    });
    ```
- **SSR Hydration-Safe Deterministic Timestamps**:
  - ❌ **The `new Date()` Hydration Mismatch**: Evaluating `new Date().toLocaleDateString()` directly in Vue component templates produces different strings on the Node.js server (UTC) and the client browser (local timezone), triggering Vue warning `[Vue warn]: Hydration text content mismatch`.
  - ✅ **Production Invariant**: Use ISO string formatting from the server and defer localized formatting to client-mounted components or `<ClientOnly>`:
    ```vue
    <script setup lang="ts">
    import { ref, onMounted } from 'vue';

    const props = defineProps<{ timestamp: string }>();
    const formattedDate = ref(props.timestamp); // Safe fallback matching SSR

    onMounted(() => {
      // Localize only after hydration completes safely:
      formattedDate.value = new Intl.DateTimeFormat(navigator.language, {
        dateStyle: 'medium',
        timeStyle: 'short',
      }).format(new Date(props.timestamp));
    });
    </script>

    <template>
      <time :datetime="props.timestamp">{{ formattedDate }}</time>
    </template>
    ```
- **Vue 3.5+ `watch` Depth Limiting (`deep: number`) vs Unbounded Traversal**:
  - ❌ **The `deep: true` CPU Freeze**: Passing `{ deep: true }` to watch a complex reactive tree (e.g. data tables, ASTs, canvas state) forces Vue's reactivity engine to recursively walk every nested object and array key on every mutation, burning CPU cycles and dropping frames.
  - ✅ **Production Invariant**: In Vue 3.5+, limit traversal depth with a numeric parameter `{ deep: 1 }`, or prefer watching specific getters instead of whole trees:
    ```ts
    // Vue 3.5+ bounded depth traversal (only checks immediate child mutations):
    watch(
      () => complexState.value,
      (newVal) => handleMutation(newVal),
      { deep: 1 }
    );

    // Or target exact properties directly:
    watch(
      () => complexState.value.activeTabId,
      (newId) => loadTabData(newId)
    );
    ```
- **Nuxt 3 `useFetch` vs `$fetch` Inside Event Handlers**:
  - ❌ **The Composable Inside Callback Anti-Pattern**: Calling `await useFetch('/api/submit', { method: 'POST' })` inside a button `@click` or form submission handler triggers `[nuxt] A composable that requires access to the Nuxt instance was called outside of a plugin, Nuxt hook, or Nuxt composable.` and leaves dangling reactive watchers in memory.
  - ✅ **Production Invariant**: Reserve `useFetch` / `useAsyncData` strictly for declarative data fetching at the top level of `<script setup>`. Use `$fetch` for imperative event actions:
    ```vue
    <script setup lang="ts">
    // Declarative page data fetching at setup time:
    const { data: profile } = await useFetch('/api/profile');

    // Imperative mutation inside user event handler:
    async function onSave() {
      await $fetch('/api/profile', {
        method: 'PUT',
        body: { bio: profile.value?.bio },
      });
    }
    </script>
    ```
- **Vue 3.5+ `useTemplateRef` vs Legacy `ref(null)` Linkage**:
  - ❌ **The Mismatched Identifier Trap**: Declaring `const inputRef = ref<HTMLInputElement | null>(null)` while the template has `ref="user-input"`. If the identifier names diverge during refactoring, Vue fails to bind silently, leaving the ref `null` and producing mysterious runtime crashes when calling `.focus()`.
  - ✅ **Production Invariant**: In Vue 3.5+, use `useTemplateRef<T>('templateRefKey')` for explicit, refactor-safe template bindings:
    ```vue
    <script setup lang="ts">
    import { useTemplateRef, onMounted } from 'vue';

    // Strongly-typed reference bound to template ref="editorCanvas"
    const canvasRef = useTemplateRef<HTMLCanvasElement>('editorCanvas');

    onMounted(() => {
      if (canvasRef.value) {
        const ctx = canvasRef.value.getContext('2d');
        // Initialize canvas drawing...
      }
    });
    </script>

    <template>
      <canvas ref="editorCanvas" class="w-full h-96 border border-zinc-800 rounded-lg" />
    </template>
    ```
- **SSR-Safe Teleport Invariant in Nuxt 3**:
  - ❌ **Hydration Failure on Direct `<Teleport to="body">`**: During SSR rendering, `document.body` does not exist on the server. If a `<Teleport>` renders unconditionally on initial page load, Nuxt throws `Cannot read properties of undefined (reading 'insertBefore')` or produces severe client-side DOM hydration mismatches.
  - ✅ **Production Invariant**: Always wrap target Teleports with `<ClientOnly>` or guard rendering with a mounted state check:
    ```vue
    <script setup lang="ts">
    import { ref, onMounted } from 'vue';

    const isMounted = ref(false);
    onMounted(() => {
      isMounted.value = true;
    });
    </script>

    <template>
      <!-- Option A: ClientOnly wrapper -->
      <ClientOnly>
        <Teleport to="#modal-root">
          <div role="dialog" aria-modal="true" class="fixed inset-0 z-50 bg-black/60">
            <!-- Modal Content -->
          </div>
        </Teleport>
      </ClientOnly>

      <!-- Option B: Mounted guard -->
      <Teleport v-if="isMounted" to="body">
        <aside class="fixed bottom-4 right-4 z-50">
          <NotificationToast />
        </aside>
      </Teleport>
    </template>
    ```
- **Vue 3.5+ Watcher Controls (`pause()` and `resume()`) for Programmatic Batch Updates**:
  - ❌ **Cascading Feedback Loops on External Hydration**: When syncing state from external sources (WebSockets, IndexedDB, or server payloads), updating multiple reactive refs triggers active watchers that emit change events or make redundant HTTP calls.
  - ✅ **Production Invariant**: In Vue 3.5+, use watcher controls to pause triggers during batch mutations and resume cleanly:
    ```vue
    <script setup lang="ts">
    import { ref, watch } from 'vue';

    const formData = ref({ title: '', tags: [] as string[] });

    const { pause, resume } = watch(formData, (val) => {
      autoSaveToServer(val);
    }, { deep: true });

    function hydrateFromRemote(remotePayload: typeof formData.value) {
      pause(); // Temporarily suspend auto-save trigger
      formData.value = { ...remotePayload };
      // State is updated without firing unwanted auto-save network requests
      resume();
    }
    </script>
    ```
- **Nuxt 3 SSR Host Header Poisoning Defense**:
  - ❌ **Unvalidated `useRequestURL()` in SSR Rendered Links**: Directly interpolating `useRequestURL().origin` into canonical metadata tags (`<link rel="canonical" :href="url">`) or password reset email templates during SSR. If behind an unvalidated reverse proxy, an attacker can send a spoofed `Host: evil.com` or `X-Forwarded-Host: evil.com` header, poisoning the server-side generated HTML and downstream CDN caches.
  - ✅ **Production Invariant**: Always validate or derive canonical URLs from explicit runtime configuration:
    ```typescript
    // In Nuxt 3 composables or pages:
    const config = useRuntimeConfig();
    const allowedBaseUrl = config.public.siteUrl; // e.g. 'https://app.example.com'

    useHead({
      link: [
        { rel: 'canonical', href: `${allowedBaseUrl}${useRoute().path}` }
      ]
    });
    ```
- **Vue 3.5+ `onWatcherCleanup` for Race-Free Async Fetching & AbortController**:
  - ❌ **The Asynchronous Stale Overwrite Race**: When watching search inputs or filter selections, subsequent fast requests may return earlier than an earlier slow request. Without aborting in-flight requests, the earlier slow response resolves last, overwriting the UI with outdated results.
  - ✅ **Production Invariant**: In Vue 3.5+, use the first-class `onWatcherCleanup` helper to cleanly register an abort callback whenever the watcher re-evaluates:
    ```vue
    <script setup lang="ts">
    import { ref, watch, onWatcherCleanup } from 'vue';

    const searchQuery = ref('');
    const results = ref<SearchResult[]>([]);

    watch(searchQuery, async (newQuery) => {
      if (!newQuery.trim()) {
        results.value = [];
        return;
      }

      const controller = new AbortController();
      // Automatically triggered when searchQuery changes again or component unmounts:
      onWatcherCleanup(() => controller.abort());

      try {
        const data = await $fetch<SearchResult[]>('/api/search', {
          query: { q: newQuery },
          signal: controller.signal,
        });
        results.value = data;
      } catch (err: any) {
        if (err.name !== 'AbortError') {
          console.error('Search failed:', err);
        }
      }
    });
    </script>
    ```
- **Nuxt 3 `useAsyncData` Scoped Cache Key Invariant in Multi-Tenant Apps**:
  - ❌ **The Cross-User Static Key Collision**: Using a static key like `useAsyncData('user-profile', ...)` across an SSR application. Because Nuxt's hydration cache indexes payloads by this key, requests sharing the same server cache can leak one user's or tenant's private profile data to another user during hydration.
  - ✅ **Production Invariant**: Parameterize every `useAsyncData` key with explicit tenant and entity IDs:
    ```typescript
    // In Nuxt 3 page or component:
    const { tenantId, userId } = useAuth();
    
    // Explicitly scope cache keys to guarantee complete tenant and user isolation:
    const { data: profile } = await useAsyncData(
      `tenant:${tenantId.value}:user:${userId.value}:profile`,
      () => $fetch(`/api/tenants/${tenantId.value}/users/${userId.value}`)
    );
    ```
- **Nuxt 3 `useHead` / Unhead Raw HTML XSS Sanitization & Injection Defense**:
  - ❌ **The Head Title / Meta Tag XSS Vulnerability**: Interpolating unsanitized user-generated strings directly into `useHead` or SSR meta tags: `useHead({ title: userProvidedTitle })`. If an attacker inputs `</title><script>evil()</script>`, the raw closing tag breaks out of the SSR-generated `<title>` node and executes arbitrary JavaScript in the victim's browser context.
  - ✅ **Production Invariant**: Always sanitize or escape user-provided strings before binding to `useHead`, or leverage Unhead's built-in title templates with strict string escaping:
    ```typescript
    // In Nuxt 3 / Vue component:
    const route = useRoute();
    const rawPostTitle = ref(post.value?.title ?? '');

    // Unhead automatically escapes strings passed into titleTemplate, but manually escape inner raw HTML:
    useHead({
      title: computed(() => rawPostTitle.value.replace(/[<>]/g, '')),
      titleTemplate: '%s · Acme Enterprise',
      meta: [
        {
          name: 'description',
          content: computed(() => post.value?.summary?.slice(0, 160) ?? ''),
        },
      ],
    });
    ```
- **Vue 3.5 `toRef` Getter Syntax for Lightweight Readonly Projections**:
  - ❌ **The Over-Engineered `computed()` Heap Bloat**: Creating multiple `computed(() => props.item.name)` watchers for lightweight, simple property reads. Each `computed` allocates an internal reactive effect, dependency tracker set, and dirty check state machine.
  - ✅ **Production Invariant**: In Vue 3.5+, use getter-based `toRef(() => expr)` for zero-overhead readonly reactive references without instantiating heavy `computed` effect instances:
    ```typescript
    <script setup lang="ts">
    import { toRef } from 'vue';

    const props = defineProps<{ user: { firstName: string; lastName: string } }>();

    // Lightweight getter-ref: tracks reactivity dynamically without computed cache overhead:
    const fullName = toRef(() => `${props.user.firstName} ${props.user.lastName}`);
    </script>
    ```
- **Vue 3.5 `onWatcherCleanup` for Stale Async Watcher Race Elimination**:
  - ❌ **The Stale Promise Overwrite Bug**: Firing asynchronous fetches inside `watch` without aborting in-flight requests. Fast consecutive input changes trigger multiple simultaneous HTTP calls. If an earlier request finishes after a later request, the earlier stale response overwrites the latest UI state.
  - ✅ **Production Invariant**: In Vue 3.5+, use the first-class `onWatcherCleanup()` API to cleanly bind an `AbortController` that cancels obsolete in-flight network requests before the watcher re-executes:
    ```typescript
    import { ref, watch, onWatcherCleanup } from 'vue';

    const searchQuery = ref('');
    const searchResults = ref<SearchResult[]>([]);

    watch(searchQuery, async (newQuery) => {
      if (!newQuery.trim()) {
        searchResults.value = [];
        return;
      }

      const controller = new AbortController();
      // Automatically triggered when searchQuery changes again or component unmounts:
      onWatcherCleanup(() => controller.abort());

      try {
        const response = await fetch(`/api/search?q=${encodeURIComponent(newQuery)}`, {
          signal: controller.signal,
        });
        if (response.ok) {
          searchResults.value = await response.json();
        }
      } catch (err: unknown) {
        if ((err as Error).name !== 'AbortError') {
          console.error('Search request failed:', err);
        }
      }
    });
    ```
- **Nuxt 3 `useRequestEvent()` Server-Only Isolation in Shared Composables**:
  - ❌ **The Cross-Environment Hydration Crash**: Invoking `useRequestEvent()` inside universal composables used across both SSR and client-side hydration. On the browser client, `useRequestEvent()` returns `undefined`, and accessing properties like `event.node.req` throws an uncaught `TypeError` that breaks client-side routing.
  - ✅ **Production Invariant**: Always guard server event access with `import.meta.server`, or delegate to portable Nuxt composables (`useRequestURL`, `useRequestHeader`):
    ```typescript
    // In composables/useClientGeo.ts:
    export function useClientGeo() {
      const geoCountry = useState<string>('geo_country', () => 'US');

      if (import.meta.server) {
        const event = useRequestEvent();
        if (event) {
          // Safe server-side header extraction via H3:
          const cloudflareCountry = getHeader(event, 'cf-ipcountry');
          if (cloudflareCountry) {
            geoCountry.value = cloudflareCountry;
          }
        }
      }

      return { geoCountry: readonly(geoCountry) };
    }
    ```
- **Vue 3.5 `useTemplateRef` for Decoupled Static Ref Typing**:
  - ❌ **The Fragile Identifier Renaming Fragility**: Declaring DOM refs with `const inputRef = ref<HTMLInputElement | null>(null)` where the variable name must match the `<input ref="inputRef">` template attribute. Refactoring or renaming the TypeScript variable silently breaks the DOM connection with zero compiler errors.
  - ✅ **Production Invariant**: In Vue 3.5+, use `useTemplateRef<T>('refName')`. It cleanly separates the local variable identifier from the template ref attribute string, enforces strict DOM typing, and guarantees safe ref resolution across component lifecycles:
    ```vue
    <script setup lang="ts">
    import { useTemplateRef, onMounted } from 'vue';

    // Type-safe template ref decoupled from local variable name:
    const searchInputElement = useTemplateRef<HTMLInputElement>('searchInput');

    onMounted(() => {
      searchInputElement.value?.focus();
    });
    </script>

    <template>
      <input
        ref="searchInput"
        type="search"
        placeholder="Type to search..."
        class="rounded-lg border px-3 py-2"
      />
    </template>
    ```
- **Nuxt 3 `callOnce()` vs In-Component Flags for Idempotent Setup Execution**:
  - ❌ **The Double Execution Hydration Trap**: Executing global one-time initialization (e.g. analytics setup, token verification, or feature-flag loading) in a top-level `<script setup>` or `onMounted()` using a component-scoped boolean flag. During SSR and subsequent client hydration, or during client-side page transitions, the setup logic runs twice or executes repeatedly on page re-entry.
  - ✅ **Production Invariant**: Wrap universal one-time operations in Nuxt 3.9+ `callOnce('key', async () => { ... })`. It executes strictly once across both SSR and client hydration, serializing execution status into `useNuxtApp().payload`:
    ```vue
    <script setup lang="ts">
    // Runs on the server during SSR, and skips completely on client hydration.
    // On pure client navigation, it runs strictly once per user session.
    await callOnce('init-app-telemetry', async () => {
      const telemetry = useTelemetry();
      await telemetry.registerAppSession();
    });
    </script>
    ```
- **`shallowRef` & `markRaw` for Non-UI Instances & High-Frequency Datasets**:
  - ❌ **The Deep Proxy Overhead Trap**: Wrapping large arrays (e.g. 10,000 table rows) or complex third-party class instances (e.g. Monaco Editor, ECharts, Three.js scenes, Leaflet maps) with standard `ref()` or `reactive()`. Vue recursively walks and converts every nested property into a reactive Proxy, triggering catastrophic CPU stalls, GC churn, and unexpected mutation bugs inside third-party internal prototypes.
  - ✅ **Production Invariant**: Use `shallowRef()` for collections that are updated wholesale, and wrap third-party class instances with `markRaw()`:
    ```vue
    <script setup lang="ts">
    import { shallowRef, markRaw, onMounted, onBeforeUnmount } from 'vue';
    import * as echarts from 'echarts';

    // shallowRef: Only mutations to .value trigger re-renders; avoids deep Proxy traversal
    const timeSeriesData = shallowRef<Array<{ time: number; value: number }>>([]);

    // markRaw: Explicitly prevents Vue from ever wrapping the chart instance in a Proxy
    let chartInstance: echarts.ECharts | null = null;

    onMounted(() => {
      const container = document.getElementById('chart-container');
      if (container) {
        chartInstance = markRaw(echarts.init(container));
      }
    });

    onBeforeUnmount(() => {
      chartInstance?.dispose();
    });
    </script>
    ```
- **Nuxt 3 Route Middleware Navigation Guards & Hydration Mismatch Safety**:
  - ❌ **The Direct Browser Window / Storage Access Anti-Pattern**: Accessing `window.localStorage` or `document.cookie` directly inside universal route middleware without SSR guards. During SSR execution on the server, `window` is `undefined`, crashing the rendering engine with `ReferenceError: window is not defined`.
  - ✅ **Production Invariant**: Use `useCookie()` or `import.meta.client` guards in Nuxt 3 route middleware:
    ```ts
    // middleware/auth.global.ts
    export default defineNuxtRouteMiddleware((to, from) => {
      // useCookie is universal: seamlessly works across server SSR and client hydration
      const sessionToken = useCookie('session_token');

      if (!sessionToken.value && to.path.startsWith('/admin')) {
        return navigateTo('/login', { redirectCode: 302 });
      }
    });
    ```
- **SSR Server Memory Leak Prevention in Universal Setup**:
  - ❌ **The Node.js Server Leak Disaster**: Registering intervals, event listeners, or reactive subscriptions (`setInterval`, `window.addEventListener`, global event bus) directly inside `<script setup>` outside lifecycle hooks. During SSR, the server executes `setup()` for *every single incoming HTTP request*, but server-side rendering **never executes `onBeforeUnmount()` or `onUnmounted()`**! The intervals and listeners remain bound in Node.js heap memory forever, causing catastrophic server OOM crashes under production traffic.
  - ✅ **Production Invariant**: All browser-only side effects, timers, and unmount cleanup MUST reside strictly inside `onMounted()`:
    ```vue
    <script setup lang="ts">
    import { onMounted, onBeforeUnmount } from 'vue';

    // ❌ FORBIDDEN in setup() body:
    // setInterval(pollStatus, 5000); // Leaks on Node.js server!

    // ✅ Production Discipline: Confined to browser lifecycle
    let timerId: ReturnType<typeof setInterval> | null = null;

    onMounted(() => {
      timerId = setInterval(pollStatus, 5000);
    });

    onBeforeUnmount(() => {
      if (timerId) clearInterval(timerId);
    });
    </script>
    ```
- **`v-memo` Subtree Re-rendering Optimization for High-Density Tables**:
  - ❌ **The Virtual DOM Re-diffing Bottleneck**: Rendering large interactive lists (e.g. 500 table rows) where only 1 row changes state (e.g. selected or status toggled). Vue re-evaluates VNodes and diffs the entire 500-item subtree on every tick.
  - ✅ **Production Invariant**: Use `v-memo="[row.id, row.selected, row.updatedAt]"` to skip VNode creation and diffing entirely unless the memoized dependencies have changed:
    ```vue
    <template>
      <div
        v-for="item in heavyList"
        :key="item.id"
        v-memo="[item.id, item.status, item.isSelected]"
        class="table-row"
      >
        <span class="font-mono">{{ item.id }}</span>
        <span :class="item.status">{{ item.status }}</span>
        <button @click="toggleSelect(item.id)">{{ item.isSelected ? 'Selected' : 'Select' }}</button>
      </div>
    </template>
    ```
- **Nuxt 3 Hybrid Rendering & `routeRules` Caching Discipline**:
  - ❌ **The Uncached Dynamic SSR Server Meltdown**: Leaving high-traffic marketing, documentation, or public catalog routes as default uncached dynamic SSR. Every client visit or bot crawl triggers full server-side Vue component compilation and downstream database fetches, creating high TTFB and CPU saturation under load.
  - ✅ **Production Invariant**: Define explicit hybrid rendering policies via `routeRules` in `nuxt.config.ts`. Apply `swr` (Stale-While-Revalidate) or `isr` (Incremental Static Regeneration) for public content, and designate authenticated user admin routes as `ssr: false`:
    ```ts
    // nuxt.config.ts
    export default defineNuxtConfig({
      routeRules: {
        // Public marketing pages: regenerate static HTML in background every hour
        '/': { isr: 3600 },
        '/blog/**': { swr: 3600, headers: { 'cache-control': 's-maxage=3600, stale-while-revalidate=86400' } },
        // Public API endpoints: edge cached with stale-while-revalidate
        '/api/catalog/**': { cache: { maxAge: 60, swr: true } },
        // Authenticated client portal: bypass SSR entirely, render client-side SPA
        '/dashboard/**': { ssr: false },
      }
    });
    ```
- **Pinia `$onAction` & `$subscribe` Lifecycle Detachment Defense**:
  - ❌ **The Detached Store Subscription Memory Leak**: Invoking `store.$subscribe(...)` or `store.$onAction(...)` inside a composable or component without scoping. If subscriptions are detached from the component's active effect scope, they persist in the global Pinia root store indefinitely after the component unmounts, firing duplicate mutation callbacks on every subsequent action.
  - ✅ **Production Invariant**: Explicitly bind subscriptions to the component lifecycle, or capture the unsubscribe callback and register it inside `onScopeDispose()`:
    ```ts
    import { onScopeDispose } from 'vue';
    import { useCartStore } from '~/stores/cart';

    export function useCartTelemetry() {
      const cart = useCartStore();

      // Pass detached: false (default inside setup) to bind to current effect scope:
      const unsubscribe = cart.$onAction(({ name, args, after, onError }) => {
        after(() => {
          sendTelemetry('cart_action', { action: name });
        });
      }, false);

      onScopeDispose(() => {
        unsubscribe();
      });
    }
    ```
- **Vue 3.5+ `useTemplateRef` & Typed Component Instance Invariants**:
  - ❌ **The Brittle Variable-Name Matching of Legacy `ref(null)`**: In Vue 3.0–3.4, template refs relied on the variable name in `<script setup>` matching the string attribute in template (`<MyModal ref="modalRef" />` with `const modalRef = ref(null)`). Renaming variables during refactoring or minification broke the association silently, leaving `modalRef.value` as `null` with zero compiler warnings.
  - ✅ **Production Invariant**: In Vue 3.5+, use `useTemplateRef<T>('refName')`. It explicitly decouples the JavaScript variable name from the template identifier, provides clean autocomplete, and enforces strict component instance typing:
    ```vue
    <script setup lang="ts">
    import { useTemplateRef, onMounted } from 'vue';
    import type UserModal from '~/components/UserModal.vue';

    // Strongly-typed component instance ref
    const userModal = useTemplateRef<InstanceType<typeof UserModal>>('userModalRef');

    function openModal() {
      // Safe, fully typed method invocation
      userModal.value?.open({ userId: 'usr_123' });
    }
    </script>

    <template>
      <button @click="openModal">Edit Profile</button>
      <UserModal ref="userModalRef" />
    </template>
    ```
- **Nuxt 3 Nitro Server Storage via Unstorage & Multi-Environment Drivers**:
  - ❌ **The Ephemeral In-Memory State & Edge Filesystem Crash**: Storing cached API responses, rate limits, or user session tokens in module-level `Map` instances or local `fs.writeFile` in Nuxt Nitro server routes (`/server/api/*`). On serverless or edge deployments (Vercel, Cloudflare Workers, AWS Lambda), each execution isolate is ephemeral and has read-only filesystems, resulting in lost state or crashes.
  - ✅ **Production Invariant**: Always use Nitro's unified `useStorage()` abstraction configured with environment-appropriate Unstorage drivers (Redis or Cloudflare KV in production, memory/fs in local development):
    ```ts
    // nuxt.config.ts
    export default defineNuxtConfig({
      nitro: {
        storage: {
          cache: process.env.NODE_ENV === 'production'
            ? { driver: 'redis', url: process.env.REDIS_URL, ttl: 3600 }
            : { driver: 'fs', base: '.cache/nitro' }
        }
      }
    });

    // server/api/catalog.get.ts
    export default defineEventHandler(async (event) => {
      const storage = useStorage('cache');
      const cachedData = await storage.getItem('catalog:featured');
      if (cachedData) return cachedData;

      const freshData = await fetchFromDatabase();
      await storage.setItem('catalog:featured', freshData);
      return freshData;
    });
    ```
- **Vue 3.5+ Native Reactive Props Destructuring & Default Values**:
  - ❌ **The Lost Reactivity Trap of Legacy `defineProps`**: In Vue 3.0–3.4, destructuring `defineProps()` (`const { title } = defineProps<Props>()`) stripped reactivity, forcing developers to use boilerplate `toRefs()` or `withDefaults(...)`.
  - ✅ **Production Invariant**: In Vue 3.5+, props destructuring is compiled into reactive getters. Use native JavaScript default parameters directly; the Vue compiler preserves full reactivity across `computed`, `watch`, and templates:
    ```vue
    <script setup lang="ts">
    import { computed } from 'vue';

    // Vue 3.5+ fully reactive destructuring with native defaults
    const { count = 0, label = 'Counter' } = defineProps<{
      count?: number;
      label?: string;
    }>();

    const doubled = computed(() => count * 2);
    </script>

    <template>
      <div>{{ label }}: {{ count }} (Doubled: {{ doubled }})</div>
    </template>
    ```
- **Nuxt 3 Route Middleware Invariants & Universal Auth Guards**:
  - ❌ **The SSR Window Crash & Infinite Redirect Loop**: Accessing browser-only globals (`window.localStorage`) inside `defineNuxtRouteMiddleware` causes SSR 500 server crashes. Failing to check `to.path === '/login'` causes infinite client redirect loops.
  - ✅ **Production Invariant**: Always use `useCookie()` for universal token access across SSR and client transitions. Always guard redirection against the target destination to eliminate redirect loops:
    ```ts
    // middleware/auth.ts
    export default defineNuxtRouteMiddleware((to) => {
      const token = useCookie('auth_token');

      // Unauthenticated users trying to access protected routes
      if (!token.value && to.path !== '/login') {
        return navigateTo({
          path: '/login',
          query: { redirect: to.fullPath },
        });
      }

      // Authenticated users trying to visit login page
      if (token.value && to.path === '/login') {
        return navigateTo('/dashboard');
      }
    });
    ```
- **Vue 3.5+ Type-Safe Template Refs with `useTemplateRef`**:
  - ❌ **The Fragile String Matching Ref Anti-Pattern**: Using generic `const input = ref<HTMLInputElement | null>(null)` with `ref="input"` in template. Renaming either the variable or the template string causes silent ref breakage and runtime `undefined` access errors.
  - ✅ **Production Invariant**: In Vue 3.5+, use `useTemplateRef<T>('refName')`. It provides explicit, type-safe coupling between template ref attributes and script bindings without requiring matching variable identifier names:
    ```vue
    <script setup lang="ts">
    import { useTemplateRef, onMounted } from 'vue';

    // Vue 3.5+ explicit template ref binding
    const searchInput = useTemplateRef<HTMLInputElement>('search-box');

    onMounted(() => {
      searchInput.value?.focus();
    });
    </script>

    <template>
      <input ref="search-box" type="search" placeholder="Query symbols..." />
    </template>
    ```
- **Nuxt Server Routes Streaming for Large Context Payloads**:
  - ❌ **The In-Memory Buffer Overflow on Large JSON**: Buffering massive LLM outputs or dataset exports into a single in-memory JavaScript object before returning from `defineEventHandler`. This spikes Node.js heap memory and causes high TTFT (time-to-first-token) latency.
  - ✅ **Production Invariant**: Use `sendStream(event, readableStream)` or Web ReadableStreams in Nitro server routes to pipe chunks directly to the client without buffering:
    ```ts
    // server/api/stream.ts
    export default defineEventHandler(async (event) => {
      setHeader(event, 'Content-Type', 'text/event-stream');
      setHeader(event, 'Cache-Control', 'no-cache');
      setHeader(event, 'Connection', 'keep-alive');

      const stream = getUpstreamLLMStream();
      return sendStream(event, stream);
    });
    ```
- **Vue 3.5+ Reactive Props Destructuring with Default Values**:
  - ❌ **The Legacy `toRefs` Clutter & Reactivity Loss Fear**: In Vue 3.0–3.4, destructuring `const { count } = defineProps<{ count?: number }>()` broke reactivity. In Vue 3.5+, reactive props destructuring is stable and compiler-optimized. Destructured identifiers retain dynamic reactivity automatically.
  - ✅ **Production Invariant**: Destructure props directly in `<script setup>` with standard JavaScript default values; avoid obsolete `withDefaults` boilerplate:
    ```vue
    <script setup lang="ts">
    // Vue 3.5+: Reactive destructuring with native default values
    const { count = 0, status = 'idle' } = defineProps<{
      count?: number;
      status?: 'idle' | 'running' | 'completed';
    }>();

    // count and status are reactive getters tracked automatically by template and watchers
    watch(() => count, (newCount) => {
      console.log('Count updated:', newCount);
    });
    </script>
    ```
- **Nuxt 3 `useAsyncData` Key Discipline in Reusable Components**:
  - ❌ **The Autogenerated Key Cache Collision**: Calling `useAsyncData(() => fetchProfile(id))` in a reusable card component without a dynamic key. Nuxt defaults to autogenerating keys from file path and line number; when multiple card instances render on the same page, they collide, sharing a single cache and showing duplicate data.
  - ✅ **Production Invariant**: Always provide a dynamic, deterministic key incorporating instance IDs:
    ```ts
    const { data: profile } = await useAsyncData(
      `user-profile-${userId}`,
      () => $fetch(`/api/users/${userId}`),
      { watch: [userId], dedupe: 'defer' }
    );
    ```
- **Nuxt 3 Server Components (`.server.vue`) & Zero-JS Islands**:
  - ❌ **The Client Hydration Bloat on Static Content**: Rendering heavy static markdown blocks, syntax-highlighted code containers (e.g. Shiki), or complex legal terms as standard universal client components. The browser downloads megabytes of Vue component bytecode and executes wasteful hydration passes on DOM nodes that never change.
  - ✅ **Production Invariant**: Suffix static or read-only components with `.server.vue` (e.g., `MarkdownRenderer.server.vue`). Nuxt renders them exclusively on the server and ships raw HTML to the client with **zero** JavaScript bundle overhead. Wrap client interactive controls inside client slots:
    ```vue
    <!-- components/AuditLogViewer.server.vue -->
    <template>
      <div class="audit-log-container font-mono text-xs">
        <div v-for="log in logs" :key="log.id" class="py-1 border-b border-zinc-800">
          <span class="text-zinc-500">{{ log.timestamp }}</span> - {{ log.message }}
        </div>
      </div>
    </template>
    ```
- **Vue 3.5+ `onWatcherCleanup` for Eliminating Async Race Conditions**:
  - ❌ **The Out-of-Order Stale Response Race**: Triggering async fetch requests inside `watch(query, async (newQuery) => ...)` without cancelling prior requests. If query #1 takes 500ms and query #2 takes 100ms, query #1 resolves last and silently overwrites query #2 with stale data.
  - ✅ **Production Invariant**: In Vue 3.5+, invoke `onWatcherCleanup()` inside the watcher body. It runs automatically when the watcher re-executes or the component unmounts, cleanly aborting pending requests:
    ```ts
    import { watch, onWatcherCleanup } from 'vue';

    watch(searchQuery, async (query) => {
      const controller = new AbortController();
      onWatcherCleanup(() => controller.abort());

      const results = await $fetch('/api/search', {
        query: { q: query },
        signal: controller.signal,
      });
      searchResults.value = results;
    });
    ```
- **Nuxt 3 / Vue 3.5 `useId()` Deterministic Hydration Identifier**:
  - ❌ **The Math.random / Ephemeral Counter Hydration Mismatch**: Generating client-side component IDs using `Math.random()`, `nanoid()`, or local variable counters inside `<script setup>` for HTML form `id` and `label for` binding. During Server-Side Rendering (SSR), the server generates one ID while the client hydrates with a different ID, triggering hydration mismatch warnings and accessibility degradation.
  - ✅ **Production Invariant**: In Vue 3.5+ and Nuxt 3, always use `useId()`:
    ```vue
    <script setup lang="ts">
    import { useId } from 'vue';

    // useId generates stable, unique, SSR-safe deterministic IDs across server and client
    const emailInputId = useId();
    const helperTextId = useId();
    </script>

    <template>
      <div class="form-group flex flex-col gap-1.5">
        <label :for="emailInputId" class="text-sm font-medium text-zinc-300">Email Address</label>
        <input
          :id="emailInputId"
          type="email"
          :aria-describedby="helperTextId"
          class="rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-zinc-100"
        />
        <p :id="helperTextId" class="text-xs text-zinc-500">We never share your email with third parties.</p>
      </div>
    </template>
    ```
- **Nuxt Declarative `routeRules` vs Heavy Server Middleware**:
  - ❌ **The Blocking Server Middleware Bottleneck**: Enforcing caching, headers, or client-only rendering via custom Nitro middleware scripts that execute on every single incoming HTTP request, blocking Node.js event loops and adding unnecessary TTFT latency.
  - ✅ **Production Invariant**: Offload static optimization, stale-while-revalidate (SWR), and edge caching directly to `nuxt.config.ts` via `routeRules`:
    ```ts
    // nuxt.config.ts
    export default defineNuxtConfig({
      routeRules: {
        // Edge CDN stale-while-revalidate caching for public feeds
        '/api/public/**': { swr: 3600, headers: { 'cache-control': 's-maxage=3600' } },
        // Static pre-rendered marketing pages
        '/blog/**': { prerender: true },
        // Client-only single-page app mode for dense interactive dashboards
        '/dashboard/**': { ssr: false },
        // Proxy microservice routes without server overhead
        '/legacy-api/**': { proxy: 'https://backend.internal.org/api/**' }
      }
    });
    ```
- **Vue 3.5+ Custom Directive Lifecycle Cleanup (`mounted` & `unmounted`)**:
  - ❌ **The Directive DOM Listener & Observer Memory Leak**: Attaching `addEventListener`, `ResizeObserver`, or `IntersectionObserver` inside directive `mounted(el, binding)` hook without unbinding in `unmounted`. When components mount and unmount dynamically in SPAs, detached DOM trees remain retained in V8 heap memory.
  - ✅ **Production Invariant**: Always store cleanup callbacks or observer references on the element (`el._cleanup`) and tear them down in `unmounted`:
    ```ts
    export const vClickOutside = {
      mounted(el: HTMLElement, binding: DirectiveBinding<(e: MouseEvent) => void>) {
        const handler = (event: MouseEvent) => {
          if (!el.contains(event.target as Node)) {
            binding.value(event);
          }
        };
        document.addEventListener('pointerdown', handler);
        (el as any)._cleanup = () => document.removeEventListener('pointerdown', handler);
      },
      unmounted(el: HTMLElement) {
        (el as any)._cleanup?.();
      }
    };
    ```
- **Nuxt Nitro Streaming Payloads (`sendStream`) vs Large Array Buffering**:
  - ❌ **Buffering Multi-Megabyte JSON Payloads in V8 Heap**: Returning massive arrays (`event.node.res.end(JSON.stringify(hugeDataset))`) in server API routes, triggering aggressive V8 GC pauses and driving container memory spikes under concurrent client traffic.
  - ✅ **Production Invariant**: Stream large tabular exports, NDJSON, or logs directly to the HTTP response using Nitro's `sendStream(event, readableStream)` with backpressure preservation.
- **Vue 3.5+ `useTemplateRef` Type-Safe Template References**:
  - ❌ **Manual String-Ref Typing & Casting (`ref<InstanceType<typeof Comp> | null>(null)`)**: Declaring template refs with generic ref variables whose names must match template strings, susceptible to silent ref name drift and awkward TypeScript null assertions.
  - ✅ **Production Invariant**: In Vue 3.5+, use `useTemplateRef`:
    ```vue
    <script setup lang="ts">
    import { useTemplateRef, onMounted } from 'vue';

    const searchInput = useTemplateRef<HTMLInputElement>('searchInput');

    onMounted(() => {
      searchInput.value?.focus();
    });
    </script>

    <template>
      <input ref="searchInput" type="text" placeholder="Search..." />
    </template>
    ```
- **Vue 3.5+ `onWatcherCleanup` for Asynchronous Effect Hygiene**:
  - ❌ **Boilerplate Boolean Flags for Aborting Stale Async Watchers**: Managing manual `let isStale = false` flags inside asynchronous watchers to discard out-of-order network responses, leading to memory leaks and race condition bugs.
  - ✅ **Production Invariant**: Use `onWatcherCleanup` inside `watch` or `watchEffect`:
    ```ts
    import { watch, onWatcherCleanup } from 'vue';

    watch(searchQuery, async (newQuery) => {
      const controller = new AbortController();
      onWatcherCleanup(() => controller.abort());

      const data = await fetchResults(newQuery, controller.signal);
      results.value = data;
    });
    ```
- **Vue 3.5+ `shallowRef` & `triggerRef` for Massive Tabular & Streaming Data**:
  - ❌ **Wrapping Large Collections in Deep `ref()`**: Storing arrays with 10,000+ items or real-time streaming feeds in a standard `ref()`. Vue recursively wraps every nested object in a reactive `Proxy`, causing massive GC pauses, high memory footprint, and frame drops during table updates.
  - ✅ **Production Invariant**: Use `shallowRef()` for large collections, Three.js/WebGL scene graphs, or external class instances. Trigger explicit render notifications using `triggerRef()` when in-place mutations occur:
    ```ts
    import { shallowRef, triggerRef } from 'vue';

    const largeMatrix = shallowRef<MetricRecord[]>([]);

    function appendRecords(newRecords: MetricRecord[]) {
      // In-place update without deep proxy wrapping overhead
      largeMatrix.value.push(...newRecords);
      triggerRef(largeMatrix); // Notify template observers in O(1)
    }
    ```
- **Nuxt 3 `useAsyncData` Deduplication & `getCachedData` Cache Warming**:
  - ❌ **Duplicate Network Roundtrips on Client Route Transitions**: Leaving `useAsyncData` with default behavior when navigating between routes sharing common datasets (e.g., category trees or profile headers), causing redundant HTTP requests and layout flicker.
  - ✅ **Production Invariant**: Define explicit deduplication keys and implement `getCachedData` to serve warm cache data instantly while validating freshness in background:
    ```ts
    const { data: categories } = await useAsyncData('global-categories', () => $fetch('/api/categories'), {
      getCachedData(key, nuxtApp) {
        // Return cached payload from Nuxt payload state if fresh (< 5 minutes)
        const cached = nuxtApp.payload.data[key] || nuxtApp.static.data[key];
        if (cached && Date.now() - cached.fetchedAt < 300_000) {
          return cached;
        }
        return undefined;
      }
    });
    ```
- **Vue 3.5+ `useTemplateRef` Type-Safe Element & Component Binding**:
  - ❌ **Legacy String Template Refs with Mismatched Types**: Using `ref<HTMLInputElement | null>(null)` with matching variable names that silently break or fall back to `any` when refactored across template and script blocks.
  - ✅ **Production Invariant**: Use Vue 3.5+ `useTemplateRef<T>()` with explicit generic typing for deterministic, type-checked DOM and component references:
    ```vue
    <script setup lang="ts">
    import { useTemplateRef, onMounted } from 'vue';

    const inputRef = useTemplateRef<HTMLInputElement>('searchInput');

    onMounted(() => {
      inputRef.value?.focus();
    });
    </script>

    <template>
      <input ref="searchInput" type="text" placeholder="Search..." />
    </template>
    ```
- **Vue 3.5+ Reactive Props Destructuring with Default Values**:
  - ❌ **Legacy `withDefaults(defineProps<Props>(), ...)` Boilerplate**: Writing verbose `withDefaults` wrappers or using `toRefs(props)` to prevent reactivity loss during destructuring.
  - ✅ **Production Invariant**: In Vue 3.5+, destructure `defineProps` directly in `<script setup>`. Vue's compiler automatically maintains reactivity for destructured prop identifiers and default values:
    ```vue
    <script setup lang="ts">
    interface Props {
      title?: string;
      threshold?: number;
    }

    // Direct destructuring with native reactivity retention:
    const { title = 'Default Dashboard', threshold = 100 } = defineProps<Props>();

    // Watching destructured prop maintains reactive tracking:
    watch(() => threshold, (newVal) => {
      console.log('Threshold updated:', newVal);
    });
    </script>
    ```
- **Vue 3.5+ Built-in Lazy Hydration Strategies with `defineAsyncComponent`**:
  - ❌ **Client Hydration Blocking on Heavy Below-the-Fold Widgets**: Eagerly hydrating below-the-fold UI components (e.g. interactive comment sections, analytics charts, heavy rich-text editors) during initial page load, blocking the main thread and degrading First Contentful Paint (FCP) and Interaction to Next Paint (INP).
  - ✅ **Production Invariant**: In Vue 3.5+, use built-in lazy hydration strategies (`hydrateOnVisible`, `hydrateOnIdle`, `hydrateOnInteraction`, `hydrateOnMediaQuery`) to defer component hydration until necessary:
    ```vue
    <script setup lang="ts">
    import { defineAsyncComponent, hydrateOnVisible, hydrateOnIdle } from 'vue';

    // Hydrates strictly when the component scrolls into the browser viewport:
    const LazyAuditChart = defineAsyncComponent({
      loader: () => import('./components/AuditChart.vue'),
      hydrate: hydrateOnVisible(),
    });

    // Hydrates when the main thread browser CPU reaches idle:
    const LazyCommentFeed = defineAsyncComponent({
      loader: () => import('./components/CommentFeed.vue'),
      hydrate: hydrateOnIdle(),
    });
    </script>

    <template>
      <main>
        <section class="above-fold">Essential Dashboard View</section>
        <LazyAuditChart />
        <LazyCommentFeed />
      </main>
    </template>
    ```
- **Nuxt 4 Forward Compatibility & `app/` Directory Standard**:
  - ❌ **Scattering Top-Level Directories Without Compatibility Flags**: Mixing root-level `components/`, `composables/`, and `pages/` folders in Nuxt 3 projects without enabling future compatibility, leading to breaking file-system collisions and configuration migration churn during Nuxt 4 upgrades.
  - ✅ **Production Invariant**: Structure modern Nuxt projects inside the `app/` directory (`app/components/`, `app/composables/`, `app/pages/`, `app/router.options.ts`) and declare `future: { compatibilityVersion: 4 }` in `nuxt.config.ts`:
    ```typescript
    // nuxt.config.ts
    export default defineNuxtConfig({
      future: {
        compatibilityVersion: 4,
      },
      experimental: {
        typedPages: true,
      },
    });
    ```
- **Vue 3.5+ `useTemplateRef` Type-Safe Template Referencing**:
  - ❌ **Legacy `ref<HTMLElement | null>(null)` Variable Name Coupling**: Declaring template refs via `const input = ref<HTMLInputElement | null>(null)` matching `<input ref="input" />`. Renaming the TypeScript variable silently breaks the template binding without compiler warnings, and dynamic component refs require manual typecasting.
  - ✅ **Production Invariant**: In Vue 3.5+, use `useTemplateRef<T>(key)` for type-safe template referencing decoupled from local variable identifiers:
    ```vue
    <script setup lang="ts">
    import { useTemplateRef, onMounted } from 'vue';

    // Typed directly to the HTMLInputElement interface:
    const searchInput = useTemplateRef<HTMLInputElement>('search-input-ref');

    onMounted(() => {
      searchInput.value?.focus();
    });
    </script>

    <template>
      <input ref="search-input-ref" placeholder="Search orders..." />
    </template>
    ```
- **Vue 3.5+ `onWatcherCleanup` for Async Request Race Condition Elimination**:
  - ❌ **Stale Response Race Conditions in Async Watchers**: Launching asynchronous fetches inside `watch(userId, async (id) => { ... })` without cancelling in-flight requests. If `userId` changes from `A` to `B` quickly, response `A` may arrive after `B`, corrupting the UI state with stale data.
  - ✅ **Production Invariant**: Use Vue 3.5+ `onWatcherCleanup` to abort pending HTTP requests or clear timers whenever the watcher re-executes or the component unmounts:
    ```vue
    <script setup lang="ts">
    import { ref, watch, onWatcherCleanup } from 'vue';

    const userId = ref('usr_101');
    const userProfile = ref<UserProfile | null>(null);

    watch(userId, async (newId) => {
      const controller = new AbortController();

      // Automatically abort the previous fetch when userId changes:
      onWatcherCleanup(() => controller.abort());

      try {
        const res = await fetch(`/api/users/${newId}`, { signal: controller.signal });
        userProfile.value = await res.json();
      } catch (err: any) {
        if (err.name !== 'AbortError') {
          console.error('Fetch failed', err);
        }
      }
    });
    </script>
    ```
- **Vue 3.5+ Reactive Props Destructure & Default Values**:
  - ❌ **Anti-Pattern: Legacy `withDefaults` Boilerplate or Non-Reactive Plain Destructure**: Using verbose `withDefaults(defineProps<Props>(), { ... })` or manually wrapping destructured primitives with `toRef` to avoid losing reactivity when passing them into composables or computed properties.
  - ✅ **Production Invariant**: In Vue 3.5+, use native reactive props destructuring. Destructured variables automatically remain reactive without `toRef`:
    ```vue
    <script setup lang="ts">
    import { computed } from 'vue';

    interface Props {
      count?: number;
      label?: string;
    }

    // Native destructuring with defaults; fully reactive and tracked:
    const { count = 0, label = 'Submit' } = defineProps<Props>();

    const doubleCount = computed(() => count * 2);
    </script>

    <template>
      <button class="px-4 py-2 font-medium">
        {{ label }}: {{ doubleCount }}
      </button>
    </template>
    ```
- **Nuxt 3 / Vue SSR Hydration Mismatch & Client-Only Guardrails**:
  - ❌ **Hydration Crash Anti-Pattern: Accessing Browser Globals During Setup**: Calling `window`, `localStorage`, or `navigator` in root setup scope or rendering dynamic unseeded timestamps (`new Date().toLocaleTimeString()`) on the server. The client renders different DOM from the server, triggering hydration mismatch errors and unstyled layout jumps.
  - ✅ **Production Invariant**: Enclose client-only components or browser dependencies in `<ClientOnly>` with a semantic `#fallback` skeleton:
    ```vue
    <template>
      <div class="user-panel">
        <ClientOnly>
          <UserLocalPreferences />
          <template #fallback>
            <div class="h-10 w-full animate-pulse rounded-lg bg-zinc-100 dark:bg-zinc-800" />
          </template>
        </ClientOnly>
      </div>
    </template>
    ```
- **Nuxt 3 `useAsyncData` & `useFetch` Unique Key Invariants & Deduplication**:
  - ❌ **Anti-Pattern: Auto-Key Collisions in Reusable Components or Double Fetching**: Calling `useFetch('/api/user')` without an explicit key inside reusable child components. Nuxt auto-generates keys based on file/line numbers; rendering multiple instances can share an accidental key collision, or navigating between pages triggers redundant network requests without caching.
  - ✅ **Production Invariant**: Always provide explicit semantic keys with reactive dependencies, and configure `dedupe: 'defer'` to eliminate concurrent duplicate network requests:
    ```typescript
    const route = useRoute();
    const userId = computed(() => route.params.id as string);

    // Explicit unique key tied to reactive identifier + dedupe
    const { data: user, status, error, refresh } = await useAsyncData(
      `user-profile-${userId.value}`,
      () => $fetch(`/api/users/${userId.value}`),
      {
        watch: [userId],
        dedupe: 'defer',
        lazy: true,
        transform: (raw) => ({ id: raw.id, displayName: raw.name.trim() })
      }
    );
    ```
- **Pinia State SSR Cross-Request Pollution Defense**:
  - ❌ **SSR Memory Leak & User Session Leak Anti-Pattern**: Declaring state outside the store definition function or mutating global shared objects in SSR setup. When running Node.js / Nitro SSR, a single Node process handles requests from hundreds of different users; shared references leak authenticated user tokens or private data between concurrent requests.
  - ✅ **Production Invariant**: Always define Pinia stores using function syntax or factory options where state is strictly returned from a fresh closure:
    ```typescript
    import { defineStore } from 'pinia';
    import { ref } from 'vue';

    export const useSessionStore = defineStore('session', () => {
      // Fresh ref created per SSR request context:
      const currentUser = ref<User | null>(null);
      const authToken = ref<string | null>(null);

      function reset() {
        currentUser.value = null;
        authToken.value = null;
      }

      return { currentUser, authToken, reset };
    });
    ```
- **Vue 3.5+ Custom Directives with SSR Clean-Up & Hydration Guardrails**:
  - ❌ **Anti-Pattern: Attaching Direct Event Listeners in Directives Without Unmount Cleanup**: Using custom directives (`v-click-outside`, `v-tooltip`) that attach global window/document event listeners in `mounted` but fail to clean them up in `unmounted`, or crashing the SSR server by attempting DOM access during SSR render.
  - ✅ **Production Invariant**: Always implement `unmounted` lifecycle cleanup and provide `getSSRProps` when custom directives are used in SSR applications:
    ```typescript
    import type { Directive } from 'vue';

    export const vClickOutside: Directive<HTMLElement, (e: MouseEvent) => void> = {
      mounted(el, binding) {
        const handler = (event: MouseEvent) => {
          if (!el.contains(event.target as Node)) {
            binding.value(event);
          }
        };
        (el as any).__clickOutsideHandler__ = handler;
        document.addEventListener('pointerdown', handler, { passive: true });
      },
      unmounted(el) {
        if ((el as any).__clickOutsideHandler__) {
          document.removeEventListener('pointerdown', (el as any).__clickOutsideHandler__);
          delete (el as any).__clickOutsideHandler__;
        }
      },
      // SSR safety: prevent SSR engine from crashing on custom DOM attributes
      getSSRProps() {
        return {};
      }
    };
    ```
- **Vue 3.5+ `onWatcherCleanup` for Clean In-Flight Request Cancellation**:
  - ❌ **Anti-Pattern: Manual Outer Scope AbortControllers & Race Conditions**: Declaring mutable `let activeController: AbortController | null` in the component script and manually checking state inside `watch()`. On rapid keystrokes or tab switching, responses from earlier requests arrive out-of-order and overwrite newer state, causing stale data bugs and memory leaks.
  - ✅ **Production Invariant**: In Vue 3.5+, use the built-in `onWatcherCleanup` API. It cleanly decouples cleanup registration from the callback parameter list, automatically aborting prior requests before the watcher triggers again or when the component unmounts:
    ```typescript
    import { ref, watch, onWatcherCleanup } from 'vue';

    const searchQuery = ref('');
    const searchResults = ref<Item[]>([]);

    watch(searchQuery, async (query) => {
      if (!query.trim()) {
        searchResults.value = [];
        return;
      }

      const controller = new AbortController();
      // Automatically invoked when searchQuery changes or component unmounts:
      onWatcherCleanup(() => controller.abort());

      try {
        const response = await fetch(`/api/search?q=${encodeURIComponent(query)}`, {
          signal: controller.signal
        });
        searchResults.value = await response.json();
      } catch (err: unknown) {
        if ((err as Error).name !== 'AbortError') {
          console.error('Search fetch failed', err);
        }
      }
    });
    ```
- **Vue 3.5+ Native Reactive Props Destructuring with Defaults**:
  - ❌ **Anti-Pattern: Verbose `withDefaults` Boilerplate or Legacy `toRefs`**: Writing cumbersome `withDefaults(defineProps<Props>(), { ... })` or manually extracting properties with `toRefs(props)` to prevent losing reactivity during destructuring.
  - ✅ **Production Invariant**: In Vue 3.5+, destructure `defineProps` directly in `<script setup>`. The compiler automatically transforms destructured variables into reactive accessors, retaining reactivity and supporting ergonomic default values:
    ```vue
    <script setup lang="ts">
    interface Props {
      count?: number;
      label: string;
      disabled?: boolean;
    }

    // Direct destructuring with full reactivity and TypeScript type checking:
    const { count = 0, label, disabled = false } = defineProps<Props>();

    // count and disabled remain fully reactive inside computed and watchers:
    const formattedLabel = computed(() => `${label}: ${count} ${disabled ? '(disabled)' : ''}`);
    </script>
    ```
- **`<TransitionGroup>` FLIP Animations & Absolute Leave Positioning**:
  - ❌ **Anti-Pattern: Index Keys & Missing `.v-leave-active` Absolute Positioning**: Using array index `:key="index"` in `<TransitionGroup>` or omitting `position: absolute` on the leave transition. Removing an element causes the surrounding elements to snap instantly into their new slots before the deleted element finishes its fade animation, resulting in violent layout jumping.
  - ✅ **Production Invariant**: Always key on immutable business identifiers (`:key="item.id"`), apply `.list-move` for CSS FLIP transitions, and set `position: absolute` on `.list-leave-active`:
    ```vue
    <template>
      <TransitionGroup name="list" tag="ul" class="relative">
        <li v-for="item in items" :key="item.id" class="list-item">
          {{ item.title }}
        </li>
      </TransitionGroup>
    </template>

    <style scoped>
    .list-move,
    .list-enter-active,
    .list-leave-active {
      transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .list-enter-from,
    .list-leave-to {
      opacity: 0;
      transform: translateY(-8px);
    }
    /* Essential: remove leaving items from the normal document flow so siblings glide smoothly: */
    .list-leave-active {
      position: absolute;
      width: 100%;
    }
    </style>
    ```
- **SSR Hydration Mismatch Defense: Non-Deterministic State & `useId()`**:
  - ❌ **Anti-Pattern: Rendering Browser-Dependent State in SSR Tree**: Directly interpolating non-deterministic or client-only values in templates (e.g. `new Date().toLocaleTimeString()`, `Math.random()`, or `window.innerWidth`). This causes the Vue SSR hydration algorithm to fail with `Hydration completed but contains mismatches`, forcing a full client-side DOM teardown and violent visual flash.
  - ✅ **Production Invariant**: Use Vue 3.5+ native `useId()` for deterministic accessible IDs across SSR and client boundaries. Wrap browser-specific elements in `<ClientOnly>` with explicit fallback skeletons, or defer non-deterministic rendering to `onMounted()`:
    ```vue
    <script setup lang="ts">
    import { ref, onMounted } from 'vue';

    // Vue 3.5+ deterministic SSR-safe ID generation:
    const inputId = useId();
    const formattedTimestamp = ref<string>('');

    onMounted(() => {
      // Safe client-only localization:
      formattedTimestamp.value = new Date().toLocaleTimeString();
    });
    </script>

    <template>
      <div class="field">
        <label :for="inputId">Username</label>
        <input :id="inputId" type="text" />

        <ClientOnly>
          <span class="client-time">Last active: {{ formattedTimestamp }}</span>
          <template #fallback>
            <span class="animate-pulse bg-slate-200 h-4 w-24 rounded inline-block" />
          </template>
        </ClientOnly>
      </div>
    </template>
    ```
- **`shallowRef` & `markRaw` for Heavy Third-Party Engine Instances (Monaco, Three.js, Leaflet)**:
  - ❌ **Anti-Pattern: Deeply Wrapping Complex Class Instances in `ref()` / `reactive()`**: Assigning complex engine instances (e.g. Monaco Editor, Three.js Scene, Leaflet Map, or Chart.js) to standard `ref()` or `reactive()`. Vue recursively traverses thousands of private internal properties and prototype chains with ES Proxies, causing catastrophic UI thread freezing, memory bloat, and breaking internal library state machines.
  - ✅ **Production Invariant**: Always wrap third-party instances in `shallowRef()` or use `markRaw()` to completely opt out of recursive reactivity:
    ```vue
    <script setup lang="ts">
    import { shallowRef, onMounted, onBeforeUnmount } from 'vue';
    import * as monaco from 'monaco-editor';

    const editorContainer = shallowRef<HTMLElement | null>(null);
    // shallowRef only tracks reference assignment, never internal properties:
    const editorInstance = shallowRef<monaco.editor.IStandaloneCodeEditor | null>(null);

    onMounted(() => {
      if (editorContainer.value) {
        editorInstance.value = monaco.editor.create(editorContainer.value, {
          value: 'const greeting = "hello";',
          language: 'typescript'
        });
      }
    });

    onBeforeUnmount(() => {
      editorInstance.value?.dispose();
    });
    </script>

    <template>
      <div ref="editorContainer" class="h-96 w-full" />
    </template>
    ```
- **Nuxt 3 `useAsyncData` & `useFetch` Key Deduplication Invariants**:
  - ❌ **Anti-Pattern: Implicit Dynamic Keys Causing Over-Fetching or Stale Caches**: Calling `useAsyncData(() => fetchUser(userId))` without an explicit key or without binding the key to the reactive param. When `userId` updates or the component is mounted across route transitions, Nuxt either serves stale cached data or triggers duplicate redundant network requests across SSR payload serialization.
  - ✅ **Production Invariant**: Provide a unique, deterministic cache key incorporating all reactive query dependencies:
    ```typescript
    const route = useRoute();
    const userId = computed(() => route.params.id as string);

    // Explicit unique key guarantees safe SSR caching and re-fetches when key changes:
    const { data: user, pending, error } = await useAsyncData(
      `user-${userId.value}`,
      () => $fetch(`/api/users/${userId.value}`),
      {
        watch: [userId],
        lazy: true,
        default: () => null
      }
    );
    ```
- **Vue 3.5+ Reactive Props Destructuring & Default Values**:
  - ❌ **Anti-Pattern: Legacy `toRefs(props)` or `withDefaults` Overhead**: Writing verbose `withDefaults(defineProps<Props>(), { count: 0 })` or wrapping destructured props in `toRefs` to prevent losing reactivity.
  - ✅ **Production Invariant**: In Vue 3.5+, destructuring from `defineProps` is compiled directly into reactive variable getters. Default values are declared using native JavaScript assignment:
    ```vue
    <script setup lang="ts">
    interface Props {
      count?: number;
      label?: string;
    }

    // Vue 3.5+: Clean native destructure with defaults, retaining 100% reactivity!
    const { count = 0, label = 'Submit' } = defineProps<Props>();

    // Watching a destructured prop: pass a getter function
    watch(() => count, (newCount) => {
      console.log('Count changed:', newCount);
    });
    </script>

    <template>
      <button>{{ label }} ({{ count }})</button>
    </template>
    ```
- **Vue 3.5+ `useTemplateRef()` Compile-Time Type Safety vs Untyped String Refs**:
  - ❌ **Anti-Pattern: Fragile String Matching with `ref<HTMLElement | null>(null)`**: Declaring `const myInput = ref<HTMLInputElement | null>(null)` and trusting that the template has `<input ref="myInput" />`. If the variable or template string is renamed during a refactor, it silently fails without compiler feedback.
  - ✅ **Production Invariant**: Use Vue 3.5+ `useTemplateRef<T>(refName)` for explicit, typed template references:
    ```vue
    <script setup lang="ts">
    import { useTemplateRef, onMounted } from 'vue';

    // Type-safe template ref linked to ref="searchBox" in template:
    const searchInput = useTemplateRef<HTMLInputElement>('searchBox');

    onMounted(() => {
      searchInput.value?.focus();
    });
    </script>

    <template>
      <input ref="searchBox" type="search" placeholder="Search..." />
    </template>
    ```
- **SSR Hydration Mismatch Defense: Deterministic `useId()` for Accessible Forms**:
  - ❌ **Anti-Pattern: Dynamic Random IDs (`Math.random()` or Global Counters)**: Generating unique IDs for form labels and `aria-describedby` via random strings. Client and server evaluate different random values, triggering Vue hydration mismatch warnings and accessibility degradation.
  - ✅ **Production Invariant**: Use Vue 3.5+ / Nuxt 3 built-in `useId()` to generate deterministic, SSR-safe unique identifiers guaranteed to match between server render and client hydration:
    ```vue
    <script setup lang="ts">
    import { useId } from 'vue';

    const emailId = useId();
    const helperId = useId();
    </script>

    <template>
      <div>
        <label :for="emailId">Work Email</label>
        <input :id="emailId" type="email" :aria-describedby="helperId" />
        <span :id="helperId" class="text-xs text-gray-500">We never share your email.</span>
      </div>
    </template>
    ```
- **Vue 3.5+ `watchEffect` with `onCleanup` & `AbortController` Race Condition Defense**:
  - ❌ **Anti-Pattern: Uncancelled Async Requests in Reactive Watchers**: Launching asynchronous network calls inside `watch` or `watchEffect` without aborting previous in-flight requests when dependencies change. If request A takes 800ms and request B takes 150ms, response A resolves last and overwrites response B with stale data.
  - ✅ **Production Invariant**: Use `onCleanup` to abort prior in-flight fetch requests via `AbortController`, preventing out-of-order state corruption:
    ```vue
    <script setup lang="ts">
    import { ref, watchEffect } from 'vue';

    const searchQuery = ref('');
    const searchResults = ref<string[]>([]);

    watchEffect(async (onCleanup) => {
      const query = searchQuery.value.trim();
      if (!query) {
        searchResults.value = [];
        return;
      }

      const controller = new AbortController();
      onCleanup(() => controller.abort());

      try {
        const res = await fetch(`/api/search?q=${encodeURIComponent(query)}`, {
          signal: controller.signal,
        });
        searchResults.value = await res.json();
      } catch (err: any) {
        if (err.name !== 'AbortError') {
          console.error('Search request failed:', err);
        }
      }
    });
    </script>
    ```
- **Vue 3.5+ Reactive Props Destructuring & Default Values**:
  - ❌ **Anti-Pattern: Verbose `toRefs` Boilerplate or Avoiding Props Destructuring**: Relying on legacy `toRefs(props)` or avoiding destructuring due to outdated Vue 3.2 fears of losing reactivity.
  - ✅ **Production Invariant**: In Vue 3.5+, destructuring `defineProps` directly in `<script setup>` is fully reactive by default; default values are also assigned natively without `withDefaults`:
    ```vue
    <script setup lang="ts">
    interface Props {
      title: string;
      maxItems?: number;
      isActive?: boolean;
    }

    // Vue 3.5+ natively compiles destructured props into reactive getters:
    const { title, maxItems = 10, isActive = false } = defineProps<Props>();
    </script>

    <template>
      <div :class="{ active: isActive }">
        <h3>{{ title }} (Max: {{ maxItems }})</h3>
      </div>
    </template>
    ```
- **Nuxt 3 `useAsyncData` & `useFetch` Deterministic Key Invariant**:
  - ❌ **Anti-Pattern: Implicit Dynamic URLs Without Explicit Cache Keys**: Calling `useFetch(() => '/api/user/' + userId.value)` without providing an explicit unique key string as the first parameter. Nuxt auto-generates keys based on file path and line number; when components are reused across dynamic routes or tabs, responses collide and display stale data or cause hydration mismatches between SSR and client.
  - ✅ **Production Invariant**: Always provide a deterministic, scoped cache key to `useAsyncData` or `useFetch`. Use `watch` options to trigger refetches when dependent route params change:
    ```vue
    <script setup lang="ts">
    const route = useRoute();
    const userId = computed(() => route.params.id as string);

    // Deterministic scoped cache key bound to current resource identity:
    const { data: userProfile, status, error, refresh } = await useAsyncData(
      () => `user:profile:${userId.value}`,
      () => $fetch(`/api/users/${userId.value}`),
      {
        watch: [userId],
        lazy: false,
        transform: (raw: any) => ({
          id: raw.id,
          name: raw.full_name,
          email: raw.email,
        }),
      }
    );
    </script>
    ```
- **Vue 3.5+ `shallowRef` & `markRaw` for Massive Datasets & Heavy Third-Party Instances**:
  - ❌ **Anti-Pattern: Wrapping Large Collections or External SDK Instances in Deep `ref()`**: Placing 50,000-row tabular datasets or complex non-reactive class instances (e.g., Monaco Editor, Three.js scenes, Leaflet maps, Chart.js instances) into standard `ref()`. Vue recursively wraps thousands of nested properties in `Proxy` objects, causing massive GC pressure, multi-second freezes, and memory leaks.
  - ✅ **Production Invariant**: Use `shallowRef` for large immutable collections (mutating via `.value = nextArray` or `triggerRef`) and wrap external object graphs with `markRaw()` to explicitly opt them out of the reactivity system:
    ```vue
    <script setup lang="ts">
    import { shallowRef, markRaw, onMounted, onBeforeUnmount } from 'vue';
    import * as monaco from 'monaco-editor';

    const editorContainer = ref<HTMLDivElement | null>(null);
    // shallowRef ensures Vue never wraps internal Monaco state in Proxies:
    const editorInstance = shallowRef<monaco.editor.IStandaloneCodeEditor | null>(null);

    onMounted(() => {
      if (editorContainer.value) {
        const rawEditor = monaco.editor.create(editorContainer.value, {
          value: 'console.log("hello world");',
          language: 'javascript',
        });
        // markRaw prevents any accidental reactivity wrapping
        editorInstance.value = markRaw(rawEditor);
      }
    });

    onBeforeUnmount(() => {
      editorInstance.value?.dispose();
    });
    </script>
    ```
- **Nuxt 3 `callOnce` for Universal Initialization Deduplication**:
  - ❌ **Anti-Pattern: Executing Expensive Initialization Logic in Component Setup**: Running heavy bootstrap routines (e.g. logging user telemetry, initializing analytics scripts, prefetching global site configuration) directly inside `<script setup>`. In SSR mode, the code executes once on the server and again during client hydration, creating duplicate API calls and double events.
  - ✅ **Production Invariant**: In Nuxt 3.9+, wrap initialization logic in `callOnce(key, fn)`. Nuxt guarantees the callback executes strictly once across SSR and client navigation:
    ```vue
    <script setup lang="ts">
    // Guaranteed to execute only once: on the server during SSR, or on client if navigated client-side
    await callOnce('init-app-analytics', async () => {
      const config = await $fetch('/api/bootstrap-config');
      console.info('Global telemetry initialized with tenant:', config.tenantId);
    });
    </script>
    ```
- **Vue 3 SSR Custom Directive Hydration Safety (`getSSRProps`)**:
  - ❌ **Anti-Pattern: Mutating DOM Attributes in Directive `mounted` Hooks Without SSR Support**: Creating custom directives (e.g., `v-tooltip`, `v-focus`, `v-highlight`) that inject attributes or classes into the DOM inside `mounted()`. Because the server rendered HTML without those attributes, the browser encounters severe Hydration Mismatch warnings and may reconstruct the DOM tree.
  - ✅ **Production Invariant**: When building custom directives used in SSR/Nuxt environments, define the `getSSRProps` hook to emit server-rendered attributes alongside client hooks:
    ```typescript
    import type { Directive } from 'vue';

    export const vTooltip: Directive = {
      // Server-side rendering hook: pre-renders attributes to prevent hydration mismatch
      getSSRProps(binding) {
        return {
          'data-tooltip': binding.value,
          'aria-label': binding.value,
        };
      },
      mounted(el, binding) {
        el.setAttribute('data-tooltip-active', 'true');
      },
    };
    ```
- **Vue 3.5+ Reactive Props Destructuring Invariant**:
  - ❌ **Anti-Pattern: Manual `toRef` / `toRefs` Ceremony or Losing Reactivity with Plain Destructure**: Writing verbose `const { title } = toRefs(props)` or mistakenly using naive object destructuring `const { title } = defineProps<Props>()` in older Vue versions, which breaks reactivity when props update.
  - ✅ **Production Invariant**: In Vue 3.5+, reactive props destructure is natively supported and compiled into reactive getter accessors under the hood. You can destructure directly and define default values with native JavaScript default syntax:
    ```vue
    <script setup lang="ts">
    interface Props {
      title: string;
      threshold?: number;
      tags?: string[];
    }

    // Vue 3.5+ native reactive destructuring with default values:
    // Reactivity is 100% preserved; no toRef/toRefs boilerplate needed
    const { title, threshold = 10, tags = () => [] } = defineProps<Props>();

    // Watching destructured prop requires a getter function:
    watch(() => title, (newTitle) => {
      console.log('Title updated to:', newTitle);
    });
    </script>
    ```
- **Vue 3.5+ `shallowRef` & `triggerRef` for High-Frequency Canvas / Data Grid State**:
  - ❌ **Anti-Pattern: Deep Proxy Overhead on Large Arrays / High-Frequency Streaming Data**: Storing 50,000-row tabular datasets or 60fps animation state in standard `ref([])`. Vue wraps every nested object in a `Proxy`, consuming significant memory and triggering cascading microtask reactivity flushes.
  - ✅ **Production Invariant**: Use `shallowRef` for large or frequently mutated datasets. Only the `.value` access itself is reactive. Mutate properties in-place and call `triggerRef` to notify subscribers in a single coordinated flush:
    ```typescript
    import { shallowRef, triggerRef } from 'vue';

    const largeDataset = shallowRef<DataRecord[]>([]);

    function updateRecordsInPlace(updates: Partial<DataRecord>[]) {
      // Direct in-place mutation without deep Proxy wrapping overhead:
      for (const update of updates) {
        const item = largeDataset.value.find((r) => r.id === update.id);
        if (item) Object.assign(item, update);
      }
      // Single atomic flush notification:
      triggerRef(largeDataset);
    }
    ```
- **Vue 3.5+ `onWatcherCleanup` for Deterministic Timer & AbortController Disposal**:
  - ❌ **Anti-Pattern: Leaking Async Side-Effects & Manual Callback Tracking Across Watch Runs**: Manually maintaining local `let timeoutId` or `let abortController` variables outside a watcher. When reactive dependencies change rapidly, race conditions occur where responses from previous network requests resolve out of order and overwrite fresh state.
  - ✅ **Production Invariant**: In Vue 3.5+, call `onWatcherCleanup` inside the watcher effect. Vue guarantees invocation immediately before the watcher re-evaluates and upon component unmount:
    ```typescript
    import { watch, onWatcherCleanup } from 'vue';

    watch(searchQuery, (newQuery) => {
      const controller = new AbortController();

      // Vue 3.5+ idiomatic watcher cleanup:
      onWatcherCleanup(() => {
        controller.abort(); // Automatically aborts prior pending fetch on new keystroke
      });

      fetchSearchResults(newQuery, { signal: controller.signal });
    });
    ```
- **Deterministic Test Microtask & Reactivity Flushing (`flushPromises` + `nextTick`)**:
  - ❌ **Anti-Pattern: Arbitrary `setTimeout` Sleeps in Component Testing**: Writing `await new Promise(r => setTimeout(r, 50))` to wait for Vue components to complete asynchronous fetches and reactivity flushes in Vitest or Vue Test Utils. Under CI thread pressure, this causes intermittent failures.
  - ✅ **Production Invariant**: Pair `flushPromises()` from `@vue/test-utils` (to drain pending Promise microtasks) with `nextTick()` (to flush Vue's DOM update queue deterministically):
    ```typescript
    import { mount, flushPromises } from '@vue/test-utils';
    import { nextTick } from 'vue';

    test('renders user profile after network fetch deterministically', async () => {
      const wrapper = mount(UserProfileComponent);

      // Drain all pending network/fetch microtasks:
      await flushPromises();

      // Flush Vue DOM reactivity queue:
      await nextTick();

      expect(wrapper.find('[data-testid="user-name"]').text()).toBe('Alice');
    });
    ```











