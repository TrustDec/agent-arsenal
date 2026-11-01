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
- **Vue 3.5+ Type-Safe Template Refs with `useTemplateRef`**:
  - ❌ **Anti-Pattern: Magic String Variable Coupling with `ref<HTMLElement | null>(null)`**: Relying on variable identifier names matching template `ref="id"` strings. Refactoring renames break template connections silently at runtime without compiler warnings.
  - ✅ **Production Invariant**: In Vue 3.5+, use `useTemplateRef<T>('refName')`. The compiler verifies ref target types and keeps script definitions decoupled from variable names:
    ```vue
    <script setup lang="ts">
    import { useTemplateRef, onMounted } from 'vue';

    // Type-safe ref resolution in Vue 3.5+:
    const searchInput = useTemplateRef<HTMLInputElement>('searchInput');

    onMounted(() => {
      searchInput.value?.focus();
    });
    </script>

    <template>
      <input ref="searchInput" type="text" placeholder="Search..." />
    </template>
    ```
- **Nuxt 3 Deterministic SSR Hydration Defense (`<ClientOnly>`)**:
  - ❌ **Anti-Pattern: Rendering Browser-Dependent State in SSR Templates**: Accessing `window`, `localStorage`, or timezone-dependent formatting directly inside `<template>`. When the client hydrates the server-rendered HTML, mismatches cause DOM reconciliation errors, lost input focus, or layout shifts.
  - ✅ **Production Invariant**: Wrap non-deterministic browser-specific components in `<ClientOnly>` with deterministic skeleton fallback templates:
    ```vue
    <template>
      <ClientOnly>
        <TimezoneClock :client-time="Date.now()" />
        <template #fallback>
          <span class="inline-block w-20 h-4 bg-gray-200 animate-pulse rounded" />
        </template>
      </ClientOnly>
    </template>
    ```
- **Vue 3.5 `shallowRef` & `markRaw` for Third-Party Non-DOM Instances**:
  - ❌ **Anti-Pattern: Wrapping Heavy Third-Party Instances in Deep `ref()`**: Storing Three.js WebGL scenes, Monaco Editor instances, Leaflet/Mapbox maps, or Chart.js objects inside deep `ref()`. Vue recursively traverses thousands of internal methods and circular references to attach reactive proxies, causing severe CPU spikes, memory bloat, and broken internal library methods.
  - ✅ **Production Invariant**: Use `shallowRef` or wrap external instances in `markRaw()` to bypass proxy wrapping completely. Mutate only the root reference or invoke class methods directly:
    ```vue
    <script setup lang="ts">
    import { shallowRef, onMounted, onBeforeUnmount } from 'vue';
    import * as THREE from 'three';

    // shallowRef eliminates deep reactive proxy overhead on WebGL scene graph:
    const renderer = shallowRef<THREE.WebGLRenderer | null>(null);

    onMounted(() => {
      renderer.value = new THREE.WebGLRenderer({ antialias: true });
    });

    onBeforeUnmount(() => {
      renderer.value?.dispose();
    });
    </script>
    ```
- **Nuxt 3 Unique AsyncData Keys & Collision Avoidance (`useAsyncData`)**:
  - ❌ **Anti-Pattern: Omitting Unique Keys in `useAsyncData` Across Dynamic Routes**: Relying on auto-generated keys or static keys when fetching data with dynamic route parameters or pagination. In SSR, cache collision across concurrent requests causes user A to receive cached data belonging to user B, or stale page data during route navigation.
  - ✅ **Production Invariant**: Always provide an explicit, unique cache key incorporating all relevant reactive variables:
    ```vue
    <script setup lang="ts">
    const route = useRoute();
    const page = ref(1);

    // Explicit parameterized key prevents SSR cache collision across pages:
    const { data: posts, status } = await useAsyncData(
      `posts-${route.params.category}-${page.value}`,
      () => $fetch(`/api/posts/${route.params.category}`, { params: { page: page.value } }),
      { watch: [page] }
    );
    </script>
    ```
- **Deterministic Frontend Idempotency Keys in Mutation Forms (`useIdempotencyKey`)**:
  - ❌ **Anti-Pattern: Submitting Non-Idempotent POST Mutations on Button Click**: Triggering `$fetch('/api/v1/checkout', { method: 'POST', body })` without an `Idempotency-Key` header, or generating a brand-new UUID on every single retry attempt. When a user double-clicks the checkout button, or network retry fires after a 504 gateway timeout, multiple distinct orders are submitted to the server.
  - ✅ **Production Invariant**: Encapsulate mutation lifecycle in an idempotency composable that binds a stable key per user action intent, disables form submission during in-flight mutations, and transmits the exact same key across retries:
    ```typescript
    // composables/useIdempotencyMutation.ts
    export function useIdempotentMutation<TData, TResult>(
      endpoint: string,
      options: { method?: 'POST' | 'PUT' | 'PATCH' } = {}
    ) {
      const isSubmitting = ref(false);
      const idempotencyKey = ref(crypto.randomUUID());

      async function execute(data: TData): Promise<TResult> {
        if (isSubmitting.value) {
          throw new Error('A mutation is already in progress.');
        }

        isSubmitting.value = true;
        try {
          const response = await $fetch<TResult>(endpoint, {
            method: options.method ?? 'POST',
            body: data,
            headers: {
              'Idempotency-Key': idempotencyKey.value,
            },
          });
          // Rotate key only after confirmed success to prepare for next distinct submission:
          idempotencyKey.value = crypto.randomUUID();
          return response;
        } finally {
          isSubmitting.value = false;
        }
      }

      return { execute, isSubmitting, idempotencyKey: readonly(idempotencyKey) };
    }
    ```
- **Async Concurrency Fencing & Stale Action Cancellation (`useConcurrentFencing`)**:
  - ❌ **Anti-Pattern: Unfenced Rapid Async State Updates (Out-of-Order Race Condition)**: When a user quickly toggles search filters, tabs, or pagination, multiple asynchronous requests fly concurrently. If request #1 returns after request #2 due to variable network latency, request #1's stale data overwrites request #2's fresh state.
  - ✅ **Production Invariant**: Implement a concurrency fencing composable with monotonic generation tokens and `AbortController`. Reject any resolved response whose generation token is older than the latest initiated action:
    ```typescript
    // composables/useConcurrentFencing.ts
    export function useConcurrentFencing<TArgs extends any[], TResult>(
      asyncFn: (signal: AbortSignal, ...args: TArgs) => Promise<TResult>
    ) {
      const latestToken = ref(0);
      let activeController: AbortController | null = null;
      const data = ref<TResult | null>(null);
      const isLoading = ref(false);

      async function trigger(...args: TArgs): Promise<TResult | null> {
        // Abort previous in-flight request
        if (activeController) {
          activeController.abort();
        }
        activeController = new AbortController();
        const currentToken = ++latestToken.value;
        isLoading.value = true;

        try {
          const result = await asyncFn(activeController.signal, ...args);
          // Fencing invariant: ignore if a newer execution was triggered
          if (currentToken !== latestToken.value) {
            return null;
          }
          data.value = result;
          return result;
        } catch (err: any) {
          if (err.name === 'AbortError') return null;
          throw err;
        } finally {
          if (currentToken === latestToken.value) {
            isLoading.value = false;
          }
        }
      }

      return { trigger, data: readonly(data), isLoading: readonly(isLoading) };
    }
    ```
- **Nuxt 3 Nitro Webhook Handlers: Raw Body Preservation & Constant-Time Validation**:
  - ❌ **Anti-Pattern: Using `readBody(event)` for Webhook Signature Verification**: In Nitro server handlers (`server/api/webhooks/...`), calling `readBody(event)` parses the incoming payload into a JavaScript object. Calculating an HMAC over `JSON.stringify(body)` produces false signature mismatches in production due to key ordering and whitespace mutations.
  - ✅ **Production Invariant**: Always call `await readRawBody(event)` to extract the unmutated Buffer/string, verify using `crypto.timingSafeEqual`, respond immediately with status 202, and delegate tasks asynchronously:
    ```typescript
    // server/api/webhooks/stripe.post.ts
    import crypto from 'node:crypto';

    export default defineEventHandler(async (event) => {
      const rawBody = await readRawBody(event);
      if (!rawBody) {
        throw createError({ statusCode: 400, message: 'Missing request body' });
      }

      const sigHeader = getHeader(event, 'stripe-signature');
      if (!sigHeader) {
        throw createError({ statusCode: 401, message: 'Missing signature header' });
      }

      const secret = useRuntimeConfig().stripeWebhookSecret;
      const expected = crypto.createHmac('sha256', secret).update(rawBody).digest();
      const received = Buffer.from(sigHeader, 'hex');

      if (expected.length !== received.length || !crypto.timingSafeEqual(expected, received)) {
        throw createError({ statusCode: 401, message: 'Invalid signature' });
      }

      // Return 202 immediately to satisfy upstream provider timeout SLA (<10s)
      setResponseStatus(event, 202);
      // Defer execution via Nitro task or worker queue
      return { status: 'accepted' };
    });
    ```
- **Nuxt 3 Nitro Durable Task Orchestration & Reactive Workflow Polling Composable**:
  - ❌ **Anti-Pattern: Blocking Nitro Server Routes with Long-Running Sagas**: Executing multi-step distributed operations inside standard Nuxt 3 server event handlers. Gateway proxies (Cloudflare, Nginx) drop HTTP connections after 30 seconds with 504 Gateway Timeout, while the client has no way to track progress or trigger rollbacks.
  - ✅ **Production Invariant**: Initiate durable workflows via Nitro event handler, persist initial execution state, return HTTP 202 with workflow ID, and provide a client-side Vue 3 composable `useDurableWorkflow` that handles backoff polling, abort signals, and reactive step progression:
    ```typescript
    // composables/useDurableWorkflow.ts
    export function useDurableWorkflow(workflowId: Ref<string | null>) {
      const status = ref<'IDLE' | 'RUNNING' | 'COMPLETED' | 'COMPENSATED' | 'FAILED_DLQ'>('IDLE');
      const currentStep = ref<string>('');
      const error = ref<string | null>(null);

      let timer: ReturnType<typeof setTimeout> | null = null;

      async function poll() {
        if (!workflowId.value) return;
        try {
          const res = await $fetch<{ status: any; currentStep: string; error?: string }>(
            `/api/workflows/${workflowId.value}`
          );
          status.value = res.status;
          currentStep.value = res.currentStep;
          if (res.status === 'RUNNING' || res.status === 'COMPENSATING') {
            timer = setTimeout(poll, 2000);
          }
        } catch (err: any) {
          error.value = err.message;
        }
      }

      watch(workflowId, (newId) => {
        if (timer) clearTimeout(timer);
        if (newId) {
          status.value = 'RUNNING';
          poll();
        }
      }, { immediate: true });

      onUnmounted(() => {
        if (timer) clearTimeout(timer);
      });

      return { status: readonly(status), currentStep: readonly(currentStep), error: readonly(error) };
    }
    ```
- **Nuxt Nitro Engine Graceful Shutdown & Zero-502 Readiness Middleware**:
  - ❌ **Anti-Pattern: Unhandled Node Process Signals in Nuxt SSR Containers**: Running `nuxt start` in Kubernetes or Docker without registering Nitro runtime close hooks or readiness gating, causing rolling deployments to drop in-flight SSR renders and throw 502 errors to incoming traffic.
  - ✅ **Production Invariant**: Register Nitro runtime plugins that hook into `nitroApp.hooks.hook('close')`, flip an internal readiness flag, and allow active SSR renders to finish within a bounded drain budget:
    ```typescript
    // server/plugins/lifecycle.ts - Nuxt Nitro Graceful Drain & Readiness Invariant
    export default defineNitroPlugin((nitroApp) => {
      let isDraining = false;

      nitroApp.hooks.hook('request', (event) => {
        if (event.path === '/readyz') {
          if (isDraining) {
            setResponseStatus(event, 503);
            return { status: 'DRAINING', serving: false };
          }
          return { status: 'READY', serving: true };
        }
      });

      nitroApp.hooks.hook('close', async () => {
        isDraining = true;
        // Pause 2.5s for Kubernetes ingress endpoint propagation
        await new Promise((r) => setTimeout(r, 2500));
      });
    });
    ```
- **Nuxt Nitro Event Ingestion DLQ Boundary & Admin Redrive Composables**:
  - ❌ **Anti-Pattern: Unchecked Bulk Replay from Admin UI Crushing Backend Services**: Triggering unconstrained client-side loops (`for id in ids: await fetch('/api/redrive', ...)`) from a Nuxt admin page without rolling error rate checks or progress streaming, knocking down the backend service.
  - ✅ **Production Invariant**: Implement typed DLQ management composables (`useDeadLetterQueue`) that stream redrive progress via SSE, monitor error rates in real-time, and trip an internal circuit breaker if the failure rate exceeds $2\%$:
    ```typescript
    // composables/useDeadLetterQueue.ts - Resilient DLQ Canary Redrive Composable
    export function useDeadLetterQueue(topic: string) {
      const isRedriving = ref(false);
      const circuitTripped = ref(false);
      const redriveStats = ref({ attempted: 0, succeeded: 0, failed: 0 });

      async function triggerCanaryRedrive(batchSize = 5) {
        isRedriving.value = true;
        circuitTripped.value = false;

        const { data, error } = await useFetch('/api/admin/dlq/canary', {
          method: 'POST',
          body: { topic, batchSize }
        });

        if (error.value || (data.value && data.value.failureRate > 0.20)) {
          circuitTripped.value = true;
          console.error('[DLQ] Canary redrive aborted: failure rate exceeded 20% limit');
        }
        isRedriving.value = false;
        return data.value;
      }

      return { isRedriving: readonly(isRedriving), circuitTripped: readonly(circuitTripped), triggerCanaryRedrive };
    }
    ```
- **Nuxt Nitro Multi-Tier Read-Through Cache Driver & Client-Side Singleflight Composable**:
  - ❌ **Anti-Pattern: Redundant Multi-Component `$fetch` Calls & Stampeding Nitro Handlers**: Having multiple sibling Vue components fire duplicate `$fetch` calls on mount without request deduplication, and letting Nitro server handlers execute un-coalesced upstream database requests on cache expiry.
  - ✅ **Production Invariant**: Implement typed client singleflight composables (`useCoalescedFetch`) to share promises across the component tree, and leverage Nitro's `cachedEventHandler` with `swr: true` and decorrelated jitter:
    ```typescript
    // server/api/catalog/[id].ts - Nuxt 3 Nitro Resilient Cached Handler
    export default defineCachedEventHandler(
      async (event) => {
        const id = getRouterParam(event, 'id');
        const db = useDatabase();

        const item = await db.query('SELECT * FROM catalog WHERE id = $1', [id]);
        if (!item) {
          throw createError({ statusCode: 404, statusMessage: 'Item not found' });
        }
        return item;
      },
      {
        maxAge: 60 * 60,       // Cache 1 hour
        swr: true,             // Stale-While-Revalidate background refresh
        name: 'catalogItem',
        getKey: (event) => `catalog:${getRouterParam(event, 'id')}`,
        varies: ['Accept-Encoding']
      }
    );
    ```
- **Vue 3 / Nuxt 3 Resilient Composables, Request Timeout Budgets & Degraded State UI**:
  - ❌ **Anti-Pattern: Indefinite Suspense Hanging & Unhandled Boundary Crashes**: Calling raw `$fetch` in component setup or `useAsyncData` without timeout protection, causing the entire Vue tree or Nuxt route transition to hang indefinitely during upstream network degradation.
  - ✅ **Production Invariant**: Encapsulate async data fetching in a resilient composable with explicit `AbortController` timeouts, circuit trip detection, and degraded state rendering:
    ```typescript
    // composables/useResilientFetch.ts - Nuxt 3 Resilient Data Fetching
    export function useResilientFetch<T>(
      key: string,
      endpoint: string,
      fallbackData: T,
      timeoutMs: number = 3000
    ) {
      const isDegraded = ref(false);

      const asyncData = useAsyncData<T>(key, async () => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeoutMs);

        try {
          const res = await $fetch<T>(endpoint, { signal: controller.signal });
          isDegraded.value = false;
          return res;
        } catch (err: any) {
          // Fall back gracefully instead of bubbling fatal error to Nuxt error boundary
          isDegraded.value = true;
          return fallbackData;
        } finally {
          clearTimeout(timer);
        }
      });

      return {
        ...asyncData,
        isDegraded: readonly(isDegraded),
      };
    }
    ```

- **Nuxt 3 Nitro Server Handlers Database Connection Scoping & Transaction Safety**:
  - ❌ **Anti-Pattern: Unscoped Connection Checkouts in Nitro Handlers**: Calling `const client = await pool.connect()` inside `server/api/...` without a guaranteed `finally { client.release() }`, causing connection leaks on client disconnection or validation errors.
  - ✅ **Production Invariant**: Use a shared server plugin singleton (`server/plugins/database.ts`) with a scoped transaction utility `withScopedTransaction`:
    ```typescript
    // server/api/billing/charge.post.ts
    import { defineEventHandler, readBody, createError } from 'h3';
    import { dbPool } from '~/server/utils/db';

    export default defineEventHandler(async (event) => {
      const body = await readBody(event);

      // Scoped database lease: connection release guaranteed on error, abort, or success
      const client = await dbPool.connect();
      try {
        await client.query('BEGIN');
        await client.query('SET LOCAL statement_timeout = 5000');

        const user = await client.query('SELECT balance FROM users WHERE id = $1 FOR UPDATE', [body.userId]);
        if (!user.rows[0] || user.rows[0].balance < body.amount) {
          throw createError({ statusCode: 400, message: 'Insufficient funds' });
        }

        await client.query('UPDATE users SET balance = balance - $1 WHERE id = $2', [body.amount, body.userId]);
        await client.query('INSERT INTO transactions (user_id, amount) VALUES ($1, $2)', [body.userId, body.amount]);

        await client.query('COMMIT');
        return { success: true };
      } catch (err: any) {
        await client.query('ROLLBACK').catch(() => {});
        throw createError({
          statusCode: err.statusCode || 500,
          message: err.message || 'Billing transaction failed',
        });
      } finally {
        client.release(); // Crucial: return connection to pool immediately
      }
    });
    ```

- **Nuxt 3 Nitro Server Routes Keyset Cursor Pagination & Anti-N+1 Batch Loading**:
  - ❌ **Anti-Pattern: In-Loop Database Calls & Deep `OFFSET` in Nitro Event Handlers**: Iterating over parent rows and issuing individual child queries inside `server/api/`, or using `OFFSET` pagination that degrades exponentially with page depth.
  - ✅ **Production Invariant**: Mandate keyset pagination via opaque cursor tokens and batch fetch all child relations in a single database roundtrip:
    ```typescript
    // server/api/orders/index.get.ts
    import { defineEventHandler, getQuery, createError } from 'h3';
    import { dbPool } from '~/server/utils/db';

    export default defineEventHandler(async (event) => {
      const query = getQuery(event);
      const tenantId = event.context.auth?.tenantId;
      const cursor = query.cursor as string | undefined;
      const limit = Math.min(Math.max(Number(query.limit) || 20, 1), 50);

      const client = await dbPool.connect();
      try {
        let sql = `
          SELECT id, tenant_id, status, total_amount, created_at
          FROM orders
          WHERE tenant_id = $1`;
        const params: any[] = [tenantId];

        if (cursor) {
          const [cursorTime, cursorId] = Buffer.from(cursor, 'base64url').toString().split('|');
          sql += ` AND (created_at, id) < ($2, $3)`;
          params.push(cursorTime, cursorId);
        }

        sql += ` ORDER BY created_at DESC, id DESC LIMIT $${params.length + 1}`;
        params.push(limit);

        const ordersRes = await client.query(sql, params);
        if (ordersRes.rows.length === 0) {
          return { items: [], nextCursor: null };
        }

        // Anti-N+1: Batch fetch all items in exactly 1 roundtrip
        const orderIds = ordersRes.rows.map((r: any) => r.id);
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

        const enriched = ordersRes.rows.map((order: any) => ({
          ...order,
          items: itemsByOrderId.get(order.id) ?? [],
        }));

        const last = enriched[enriched.length - 1];
        const nextCursor = enriched.length === limit
          ? Buffer.from(`${last.created_at.toISOString()}|${last.id}`).toString('base64url')
          : null;

        return { items: enriched, nextCursor };
      } catch (err: any) {
        throw createError({ statusCode: 500, message: `Failed to fetch orders: ${err.message}` });
      } finally {
        client.release();
      }
    });
    ```

- **Optimistic UI Updates with Version Epochs & 409 Conflict Recovery in Nuxt / Pinia**:
  - ❌ **Anti-Pattern: Blind Form Submission & Silent Overwrite**: Submitting edit forms without sending the entity's `version` token, causing concurrent editors to overwrite each other's data with zero notification.
  - ✅ **Production Invariant**: Include monotonic `version` in payload, apply immediate optimistic state mutation in Pinia, and catch HTTP 409 Conflict errors to trigger non-destructive three-way diff merge dialogs:
    ```vue
    <!-- components/CustomerProfileEditor.vue -->
    <script setup lang="ts">
    import { ref } from 'vue';

    interface Customer {
      id: string;
      email: string;
      name: string;
      version: number;
    }

    const props = defineProps<{ customer: Customer }>();
    const emit = defineEmits<{ (e: 'saved', updated: Customer): void }>();

    const localEmail = ref(props.customer.email);
    const isSaving = ref(false);
    const conflictData = ref<{ currentVersion: number; serverData: Customer } | null>(null);

    async function handleSave() {
      isSaving.value = true;
      conflictData.value = null;

      try {
        const updated = await $fetch<Customer>(`/api/customers/${props.customer.id}`, {
          method: 'PATCH',
          body: {
            email: localEmail.value,
            expectedVersion: props.customer.version,
          },
        });
        emit('saved', updated);
      } catch (err: any) {
        if (err.statusCode === 409) {
          // Concurrency conflict! Server entity version has advanced.
          conflictData.value = {
            currentVersion: err.data.currentVersion,
            serverData: err.data.serverRecord,
          };
        } else {
          alert(`Save failed: ${err.message}`);
        }
      } finally {
        isSaving.value = false;
      }
    }
    </script>

    <template>
      <form @submit.prevent="handleSave" class="space-y-4">
        <input v-model="localEmail" class="border p-2 rounded w-full" :disabled="isSaving" />
        <div v-if="conflictData" class="p-3 bg-amber-50 border border-amber-300 rounded text-amber-900 text-sm">
          ⚠️ Another teammate modified this profile (Version {{ conflictData.currentVersion }}). 
          Please review the updated data before retrying.
        </div>
        <button type="submit" :disabled="isSaving" class="px-4 py-2 bg-blue-600 text-white rounded">
          {{ isSaving ? 'Saving...' : 'Save Profile' }}
        </button>
      </form>
    </template>

    <!-- Nuxt 3 Server Route & Client Read-After-Write Consistency -->
    <!-- server/api/posts.post.ts sets sticky epoch cookie; server/api/posts.get.ts reads from Primary if cookie active -->
    <script setup lang="ts">
    // Nuxt 3 Client page with refreshNuxtData()
    const { data: posts, refresh } = await useFetch('/api/posts');

    async function handleAddPost(title: string) {
      // POST endpoint sets 'x-db-write-epoch' cookie
      await $fetch('/api/posts', {
        method: 'POST',
        body: { title },
      });
      // Immediate re-fetch: Server API will inspect 'x-db-write-epoch' and query Primary DB,
      // avoiding stale read / missing new item from asynchronous read replica!
      await refresh();
    }
    </script>

    <!-- Nuxt 3 Soft-Delete & Instant Undo Toast Pattern -->
    <script setup lang="ts">
    const toast = useToast();
    const { data: workspaces, refresh } = await useFetch('/api/workspaces');

    async function handleDelete(workspaceId: string) {
      // 1. Soft-delete API call returns tombstone batch ID
      const { batchId } = await $fetch(`/api/workspaces/${workspaceId}`, {
        method: 'DELETE',
      });
      await refresh();

      // 2. Show 10-second undo toast
      toast.add({
        title: 'Workspace Deleted',
        description: 'Workspace and related documents have been soft-deleted.',
        actions: [{
          label: 'Undo',
          click: async () => {
            await $fetch(`/api/workspaces/${workspaceId}/restore`, {
              method: 'POST',
              body: { batchId },
            });
            await refresh();
            toast.add({ title: 'Workspace Restored', color: 'green' });
          },
        }],
      });
    }
    </script>

    <!-- Nuxt 3 Sargable Partitioned Range Query & Live Telemetry -->
    <script setup lang="ts">
    const route = useRoute();
    const router = useRouter();

    const range = reactive({
      start: (route.query.start as string) || new Date(Date.now() - 7 * 86400000).toISOString(),
      end: (route.query.end as string) || new Date().toISOString(),
    });

    // Server API executes sargable range query: WHERE created_at >= start AND created_at < end
    // Triggering static partition pruning and skipping hundreds of older partitions
    const { data: telemetry, pending, refresh } = await useFetch('/api/telemetry', {
      query: computed(() => ({ start: range.start, end: range.end })),
      watch: [() => range.start, () => range.end],
    });

    // Nuxt 3 MVCC Health & Stale Transaction Watchdog Composable
    export function useDatabaseMVCCWatchdog() {
      const { data: mvccData, refresh } = useFetch('/api/admin/mvcc-health');
      const criticalBloat = computed(() => {
        return mvccData.value?.tables?.filter((t: any) => t.dead_ratio_pct > 15) ?? [];
      });
      const isXidAtRisk = computed(() => {
        return (mvccData.value?.oldest_xid_age ?? 0) > 100_000_000;
      });

      return {
        mvccData,
        criticalBloat,
        isXidAtRisk,
        refresh,
      };
    }

    // Nuxt 3 WAL Health & Replication Slot Sentinel Composable
    export function useDatabaseWALCheckpointWatchdog() {
      const { data: walData, refresh } = useFetch('/api/admin/wal-health');
      const isCheckpointRatioSuboptimal = computed(() => {
        return (walData.value?.checkpointHealth?.timed_pct ?? 100) < 95;
      });
      const stalledReplicationSlots = computed(() => {
        return walData.value?.replicationSlots?.filter((s: any) => s.retained_mb > 5120 || s.wal_status !== 'normal') ?? [];
      });

      return {
        walData,
        isCheckpointRatioSuboptimal,
        stalledReplicationSlots,
        refresh,
      };
    }

    // Nuxt 3 Database Lock Contention & Deadlock Sentinel Composable
    export function useDatabaseLockContentionSentinel() {
      const { data: lockData, refresh } = useFetch('/api/admin/lock-contention');
      const hasHeadOfLineContention = computed(() => {
        return (lockData.value?.blockedQueries?.some((q: any) => q.wait_seconds > 2.0)) ?? false;
      });
      const unindexedFkRisk = computed(() => {
        return lockData.value?.unindexedForeignKeys?.length ?? 0;
      });

      return {
        lockData,
        hasHeadOfLineContention,
        unindexedFkRisk,
        refresh,
      };
    }

    // Nuxt 3 Database High Availability & Failover Sentinel Composable
    export function useDatabaseHAClusterSentinel() {
      const { data: haData, refresh } = useFetch('/api/admin/ha-topology');
      const hasSevereReplicationLag = computed(() => {
        return (haData.value?.standbys?.some((s: any) => s.lag_seconds > 5.0)) ?? false;
      });
      const isZeroRpoGuaranteed = computed(() => {
        return haData.value?.hasZeroRpoSync ?? false;
      });

      return {
        haData,
        hasSevereReplicationLag,
        isZeroRpoGuaranteed,
        refresh,
      };
    }

    // Nuxt 3 Database Disaster Recovery & Continuous Archiving Sentinel Composable
    export function useDatabaseDRSentinel() {
      const { data: drData, refresh } = useFetch('/api/admin/dr-archival-status');
      const isArchivalLagging = computed(() => {
        return (drData.value?.archivalHealth?.secondsSinceLastArchive ?? 0) > 300;
      });
      const isPitrReady = computed(() => {
        return (drData.value?.dataChecksumsEnabled ?? false) && !isArchivalLagging.value;
      });

      return {
        drData,
        isArchivalLagging,
        isPitrReady,
        refresh,
      };
    }

    // Nuxt 3 Database Change Data Capture (CDC) & Slot Health Sentinel Composable
    export function useDatabaseCDCSentinel(slotName: string) {
      const { data: cdcData, refresh } = useFetch(`/api/admin/cdc-slot/${slotName}`);
      const isDiskAtRisk = computed(() => {
        return (cdcData.value?.replicationLag?.lagMb ?? 0) > 10240 || cdcData.value?.walStatus === 'lost';
      });
      const isCatalogBloated = computed(() => {
        return (cdcData.value?.catalogHealth?.catalogXminAge ?? 0) > 500000;
      });
      const isStreamHealthy = computed(() => {
        return (cdcData.value?.active ?? false) && !isDiskAtRisk.value && !isCatalogBloated.value;
      });

      return {
        cdcData,
        isDiskAtRisk,
        isCatalogBloated,
        isStreamHealthy,
        refresh,
      };
    }

    // Nuxt 3 Database Row-Level Security (RLS) & Multi-Tenant Sentinel Composable
    export function useDatabaseRLSSentinel(schemaName: string = 'public') {
      const { data: rlsData, refresh } = useFetch(`/api/admin/database-rls/${schemaName}`);
      const unforcedTables = computed(() => {
        return (rlsData.value?.tableAudits ?? []).filter((t: any) => t.isRLSEnabled && !t.isRLSForced);
      });
      const unindexedTables = computed(() => {
        return (rlsData.value?.tableAudits ?? []).filter((t: any) => !t.hasLeftmostTenantIndex);
      });
      const leakyViews = computed(() => {
        return (rlsData.value?.viewAudits ?? []).filter((v: any) => !v.securityInvoker);
      });
      const isFleetCompliant = computed(() => {
        return (
          unforcedTables.value.length === 0 &&
          unindexedTables.value.length === 0 &&
          leakyViews.value.length === 0
        );
      });

      return {
        rlsData,
        unforcedTables,
        unindexedTables,
        leakyViews,
        isFleetCompliant,
        refresh,
      };
    }

    // Nuxt 3 Database Query Planner & Statistics Sentinel Composable
    export function useDatabaseStatisticsSentinel(schemaName: string = 'public') {
      const { data: statsData, refresh } = useFetch(`/api/admin/database-stats/${schemaName}`);
      const isRandomCostCalibrated = computed(() => {
        const val = parseFloat(statsData.value?.settings?.random_page_cost || '4.0');
        return val <= 1.2;
      });
      const isJitSafeForOLTP = computed(() => {
        return statsData.value?.settings?.jit === 'off';
      });
      const isPlannerOptimized = computed(() => {
        return isRandomCostCalibrated.value && isJitSafeForOLTP.value;
      });

      return {
        statsData,
        isRandomCostCalibrated,
        isJitSafeForOLTP,
        isPlannerOptimized,
        refresh,
      };
    }

    // Nuxt 3 Database Memory & Temp Spill Sentinel Composable
    export function useDatabaseMemorySentinel() {
      const { data: memoryData, refresh } = useFetch('/api/admin/database-memory');
      const isOOMHardened = computed(() => {
        return memoryData.value?.isMemorySafe === true;
      });
      const hasUnboundedDiskRisk = computed(() => {
        return memoryData.value?.settings?.temp_file_limit === '-1';
      });
      const hasUnloggedSpills = computed(() => {
        return memoryData.value?.settings?.log_temp_files !== '0';
      });

      return {
        memoryData,
        isOOMHardened,
        hasUnboundedDiskRisk,
        hasUnloggedSpills,
        refresh,
      };
    }

    // Nuxt 3 Database Full-Text Search & GIN Sentinel Composable
    export function useDatabaseSearchSentinel(schemaName: string = 'public') {
      const { data: searchData, refresh } = useFetch(`/api/admin/database-search/${schemaName}`);
      const isTrgmInstalled = computed(() => {
        return searchData.value?.installedExtensions?.includes('pg_trgm') === true;
      });
      const hasBloatedPendingLists = computed(() => {
        const indexes = searchData.value?.ginIndexes || [];
        return indexes.some((i: any) => i.isBloated === true);
      });
      const isSearchFleetHealthy = computed(() => {
        return isTrgmInstalled.value && !hasBloatedPendingLists.value;
      });

      return {
        searchData,
        isTrgmInstalled,
        hasBloatedPendingLists,
        isSearchFleetHealthy,
        refresh,
      };
    }

    // Nuxt 3 Database JSONB Document & TOAST Sentinel Composable
    // Uses shallowRef to avoid deep reactive proxy traversal on multi-megabyte JSON payloads
    export function useDatabaseJsonbSentinel(schemaName: string = 'public') {
      const { data: jsonbData, refresh } = useFetch(`/api/admin/database-jsonb/${schemaName}`);
      const rawPayloads = shallowRef<Record<string, unknown>>({});

      const hasBloatedIndexes = computed(() => {
        const warnings = jsonbData.value?.bloatWarnings || [];
        return warnings.length > 0;
      });

      const largestToastTables = computed(() => {
        const cols = jsonbData.value?.jsonbColumns || [];
        return [...cols].sort((a: any, b: any) => b.toast_bytes - a.toast_bytes).slice(0, 5);
      });

      return {
        jsonbData,
        rawPayloads,
        hasBloatedIndexes,
        largestToastTables,
        refresh,
      };
    }

    // Nuxt 3 Database BRIN Index & Physical Heap Correlation Composable
    // Monitors BRIN compression ratio, unsummarized blocks, and pg_stats.correlation
    export function useDatabaseBrinSentinel(schemaName: string = 'public') {
      const { data: brinData, refresh } = useFetch(`/api/admin/database-brin/${schemaName}`);

      const hasDegradedCorrelation = computed(() => {
        const stats = brinData.value?.correlationStats || [];
        return stats.some((s: any) => Math.abs(parseFloat(s.correlation)) < 0.95);
      });

      const missingAutosummarizeIndexes = computed(() => {
        const indexes = brinData.value?.brinIndexes || [];
        return indexes.filter((idx: any) => !idx.autosummarize);
      });

      const isBrinFleetHealthy = computed(() => {
        return !hasDegradedCorrelation.value && missingAutosummarizeIndexes.value.length === 0;
      });

      return {
        brinData,
        hasDegradedCorrelation,
        missingAutosummarizeIndexes,
        isBrinFleetHealthy,
        refresh,
      };
    }

    // Nuxt 3 Database pgvector & HNSW Quantization Composable
    // Monitors pgvector version, uncompressed FP32 columns, and HNSW graph parameters
    export function useDatabaseVectorSentinel(schemaName: string = 'public') {
      const { data: vectorData, refresh } = useFetch(`/api/admin/database-vector/${schemaName}`);

      const isVersionSupported = computed(() => {
        const ver = vectorData.value?.pgvectorVersion || '0.0.0';
        const [major, minor] = ver.split('.').map(Number);
        return major > 0 || minor >= 7;
      });

      const uncompressedColumns = computed(() => {
        const cols = vectorData.value?.vectorColumns || [];
        return cols.filter((c: any) => c.data_type === 'vector' && c.dimensions >= 1024);
      });

      const isVectorFleetOptimal = computed(() => {
        return isVersionSupported.value && uncompressedColumns.value.length === 0;
      });

      return {
        vectorData,
        isVersionSupported,
        uncompressedColumns,
        isVectorFleetOptimal,
        refresh,
      };
    }

    // Vue 3.5+ Spatial FeatureCollection & Temporal Scheduling Composable
    // Uses shallowRef to avoid deep reactive proxy traversal on massive GeoJSON coordinate trees
    export function useSpatialFleetViewer() {
      // 1. shallowRef for GeoJSON FeatureCollections:
      const geoJsonData = shallowRef<GeoJSON.FeatureCollection | null>(null);
      const isOverlapping = ref(false);

      // 2. Debounced spatial viewport bounding box watcher:
      const viewportBbox = ref<[number, number, number, number] | null>(null);

      // 3. Computed temporal reservation overlap check [start, end)
      function checkIntervalOverlap(
        reqStart: Date,
        reqEnd: Date,
        existingRanges: Array<{ start: Date; end: Date }>
      ): boolean {
        if (reqStart >= reqEnd) return true; // Invalid bounds treated as conflict

        return existingRanges.some((range) => {
          const maxStart = reqStart > range.start ? reqStart : range.start;
          const minEnd = reqEnd < range.end ? reqEnd : range.end;
          return maxStart < minEnd; // Half-open intersection
        });
      }

      return {
        geoJsonData,
        viewportBbox,
        isOverlapping,
        checkIntervalOverlap,
      };
    }

    // Nuxt 3 Federated FDW & Prepared Transaction Sentinel Composable
    export function useDatabaseFDWSentinel() {
      const { data: fdwData, status, refresh } = useFetch('/api/admin/database-fdw-health', {
        lazy: true,
        server: false,
      });

      const hasOrphanedPreparedTransactions = computed(() => {
        return (fdwData.value?.orphanedPreparedTransactions?.length ?? 0) > 0;
      });

      const hasMisconfiguredServers = computed(() => {
        return (fdwData.value?.violations?.length ?? 0) > 0;
      });

      const isFDWClusterHealthy = computed(() => {
        return !hasOrphanedPreparedTransactions.value && !hasMisconfiguredServers.value;
      });

      return {
        fdwData,
        status,
        hasOrphanedPreparedTransactions,
        hasMisconfiguredServers,
        isFDWClusterHealthy,
        refresh,
      };
    }

    // Nuxt 3 Materialized View Staleness & Auto-Refresh Trigger Composable
    export function useMaterializedViewHealth(viewName: string, maxStalenessMinutes = 30) {
      const { data: health, status, refresh: recheckHealth } = useFetch(`/api/matviews/${viewName}/health`, {
        lazy: true,
        server: false,
      });

      const isStale = computed(() => {
        if (!health.value?.lastRefreshedAt) return true;
        const diffMinutes = (Date.now() - new Date(health.value.lastRefreshedAt).getTime()) / 60000;
        return diffMinutes > maxStalenessMinutes;
      });

      const isRefreshing = ref(false);

      async function triggerConcurrentRefresh() {
        if (isRefreshing.value) return;
        isRefreshing.value = true;
        try {
          await $fetch(`/api/matviews/${viewName}/refresh`, {
            method: 'POST',
          });
          await recheckHealth();
        } finally {
          isRefreshing.value = false;
        }
      }

      return {
        health,
        status,
        isStale,
        isRefreshing,
        recheckHealth,
        triggerConcurrentRefresh,
      };
    }

    // Nuxt 3 Advisory Lock Fencing Composable for Concurrent Mutations
    export function useAdvisoryLockedMutation<T>() {
      const isLocked = ref(false);
      const isPending = ref(false);
      const lockError = ref<string | null>(null);

      async function executeLocked(url: string, body: Record<string, any>): Promise<T | null> {
        if (isPending.value || isLocked.value) return null;
        isPending.value = true;
        lockError.value = null;

        try {
          const res = await $fetch<T>(url, {
            method: 'POST',
            body,
            onResponseError({ response }) {
              if (response.status === 409) {
                isLocked.value = true;
                lockError.value = response._data?.message || 'Resource is currently locked by another worker.';
              }
            },
          });
          return res;
        } catch (err: any) {
          if (!isLocked.value) {
            lockError.value = err.message || 'Operation failed';
          }
          return null;
        } finally {
          isPending.value = false;
        }
      }

      function resetLockState() {
        isLocked.value = false;
        lockError.value = null;
      }

      return {
        isLocked,
        isPending,
        lockError,
        executeLocked,
        resetLockState,
      };
    }

    // Composable: useSerializableMutation with automatic optimistic conflict feedback
    export function useSerializableMutation<T>() {
      const isRetrying = ref(false);
      const retryCount = ref(0);
      const lastError = ref<string | null>(null);

      async function mutateWithRetry(
        action: () => Promise<T>,
        maxClientRetries = 3
      ): Promise<T | null> {
        retryCount.value = 0;
        lastError.value = null;

        for (let i = 0; i <= maxClientRetries; i++) {
          try {
            if (i > 0) isRetrying.value = true;
            return await action();
          } catch (err: any) {
            // Detect HTTP 409 Conflict or serialization conflict payload
            const isConflict = err?.statusCode === 409 || err?.data?.code === '40001';
            if (isConflict && i < maxClientRetries) {
              retryCount.value++;
              // Jittered backoff before client re-submission
              const backoff = Math.floor(Math.random() * 200 * Math.pow(1.5, i));
              await new Promise((resolve) => setTimeout(resolve, backoff));
              continue;
            }
            lastError.value = err?.data?.message || err?.message || 'Transaction failed';
            return null;
          } finally {
            isRetrying.value = false;
          }
        }
        return null;
      }

      return {
        isRetrying,
        retryCount,
        lastError,
        mutateWithRetry,
      };
    }

    // Composable: useMonotonicUUIDv7 for client-side pre-generation and optimistic collections
    export function useMonotonicUUIDv7() {
      let lastEpochMs = 0;
      let seqCounter = 0;

      function generate(): string {
        let now = Date.now();
        if (now === lastEpochMs) {
          seqCounter++;
          if (seqCounter > 0x0fff) {
            while (Date.now() <= lastEpochMs) {}
            now = Date.now();
            lastEpochMs = now;
            seqCounter = 0;
          }
        } else if (now > lastEpochMs) {
          lastEpochMs = now;
          seqCounter = 0;
        } else {
          seqCounter++;
        }

        const bytes = new Uint8Array(16);
        crypto.getRandomValues(bytes);

        bytes[0] = (lastEpochMs / 0x10000000000) & 0xff;
        bytes[1] = (lastEpochMs / 0x100000000) & 0xff;
        bytes[2] = (lastEpochMs / 0x1000000) & 0xff;
        bytes[3] = (lastEpochMs / 0x10000) & 0xff;
        bytes[4] = (lastEpochMs / 0x100) & 0xff;
        bytes[5] = lastEpochMs & 0xff;

        bytes[6] = 0x70 | ((seqCounter >> 8) & 0x0f);
        bytes[7] = seqCounter & 0xff;
        bytes[8] = 0x80 | (bytes[8] & 0x3f);

        const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
        return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
      }

      return {
        generate,
      };
    }

    // Nitro Server Handler: Atomic Parent-Child Mutation with Referential Integrity
    export default defineEventHandler(async (event) => {
      const body = await readBody(event);
      const tenantId = event.context.tenantId;

      if (!tenantId || !body.items || !Array.isArray(body.items)) {
        throw createError({ statusCode: 400, message: 'Invalid payload or unauthenticated tenant' });
      }

      // Execute parent-child transaction with composite foreign key guarantees
      return await useNitroPostgresPool().transaction(async (tx) => {
        const orderId = body.orderId || (await generateUUIDv7());

        // 1. Insert parent
        await tx.query(
          `INSERT INTO orders (id, tenant_id, total_cents, status) VALUES ($1, $2, $3, 'pending')`,
          [orderId, tenantId, body.totalCents]
        );

        // 2. Batch insert child items referencing composite (tenant_id, order_id)
        for (const item of body.items) {
          await tx.query(
            `INSERT INTO order_items (id, tenant_id, order_id, sku, price_cents)
             VALUES ($1, $2, $3, $4, $5)`,
            [await generateUUIDv7(), tenantId, orderId, item.sku, item.priceCents]
          );
        }

        return { success: true, orderId };
      });
    });
    </script>
    ```

- **Vue 3 / Nuxt 3 Form Invariants: Mirroring Relational Check Constraints & Cross-Field Rules**:
  - ❌ **Anti-Pattern: Primitive Form State Without Invariant Fencing**:
    - Allowing numeric inputs to submit negative currency cents or mutually exclusive fields simultaneously, resulting in `SQLSTATE 23514 check_violation` crashes.
  - ✅ **Production Invariant**:
    - Use VeeValidate or Zod form composables to validate multi-column state machines (e.g. `num_nonnulls` owner exclusivity and positive currency limits) before calling Nitro server API endpoints.

    ```typescript
    import { z } from 'zod';
    import { useForm } from 'vee-validate';
    import { toTypedSchema } from '@vee-validate/zod';

    export const orderFormSchema = toTypedSchema(
      z.object({
        customerType: z.enum(['individual', 'organization']),
        userId: z.string().uuid().optional(),
        orgId: z.string().uuid().optional(),
        amountCents: z.number().int().positive('Amount must be greater than 0'),
      }).refine((data) => {
        if (data.customerType === 'individual') {
          return Boolean(data.userId) && !data.orgId;
        }
        return Boolean(data.orgId) && !data.userId;
      }, {
        message: 'Order must reference exactly one customer entity (User or Organization)',
        path: ['userId'],
      })
    );
    ```

- **Vue 3 / Nuxt 3: 64-Bit BIGINT Identifier Precision Defense & String Route Params**:
  - ❌ **Anti-Pattern: Nuxt Nitro Numeric BIGINT Deserialization Trap**:
    - Casting route parameters or database `BIGINT` primary keys to JavaScript `Number(route.params.id)`, causing silent truncation on values $> 2^{53}-1$ (`9,007,199,254,740,991`).
  - ✅ **Production Invariant**:
    - Preserve database `BIGINT` surrogate IDs as string refs throughout Vue components and Pinia stores. In Nitro event handlers, validate stringified BigInts using Zod schemas.

    ```typescript
    // server/api/records/[id].get.ts
    import { z } from 'zod';

    const idParamSchema = z.string().regex(/^\d+$/, 'Record ID must be numeric string');

    export default defineEventHandler(async (event) => {
      const rawId = getRouterParam(event, 'id');
      const recordId = idParamSchema.parse(rawId);

      // Perform database query with bigint parameter
      const record = await db.query.records.findFirst({
        where: (t, { eq }) => eq(t.id, BigInt(recordId)),
      });

      if (!record) {
        throw createError({ statusCode: 404, statusMessage: 'Record Not Found' });
      }

      // Return record with stringified BigInt ID
      return {
        ...record,
        id: record.id.toString(),
      };
    });
    ```

- **Vue 3 / Nuxt 3: Nitro Atomic UPSERT & Duplicate Collision Defense (409 Conflict)**:
  - ❌ **Anti-Pattern: Check-Then-Insert Race in Nuxt Server Handlers**:
    - Writing `if (!(await findUser(email))) { await createUser(email) }` in Nitro event handlers, failing with unhandled 500 errors on concurrent calls.
  - ✅ **Production Invariant**:
    - Execute atomic upserts directly against the database with input normalization (`email.toLowerCase().trim()`) and convert `SQLSTATE 23505` to structured HTTP 409 Conflict responses.

    ```typescript
    // server/api/organizations/[id]/members.post.ts
    import { z } from 'zod';

    const memberPayloadSchema = z.object({
      email: z.string().email().transform((e) => e.trim().toLowerCase()),
      role: z.enum(['admin', 'member', 'viewer']),
    });

    export default defineEventHandler(async (event) => {
      const orgId = getRouterParam(event, 'id');
      const body = await readValidatedBody(event, (b) => memberPayloadSchema.parse(b));

      try {
        const query = `
          INSERT INTO organization_members (org_id, email, role, updated_at)
          VALUES ($1, $2, $3, clock_timestamp())
          ON CONFLICT (org_id, email) WHERE deleted_at IS NULL
          DO UPDATE SET
            role = EXCLUDED.role,
            updated_at = clock_timestamp()
          WHERE organization_members.role IS DISTINCT FROM EXCLUDED.role
          RETURNING id, org_id, email, role;
        `;
        const res = await useDatabase().query(query, [orgId, body.email, body.role]);
        return { success: true, member: res.rows[0] };
      } catch (err: any) {
        if (err.code === '23505') {
          throw createError({
            statusCode: 409,
            statusMessage: 'Conflict: Active member with this email already exists in organization.',
          });
        }
        throw err;
      }
    });

    // server/api/organizations/[id]/bulk-tags.post.ts
    // Invariant: Bounded chunked transactions with ZERO savepoints (eliminates pg_subtrans SLRU lockup)
    export const bulkTagHandler = defineEventHandler(async (event) => {
      const orgId = getRouterParam(event, 'id');
      const { tags } = await readBody<{ tags: string[] }>(event);

      const CHUNK_SIZE = 250;
      let inserted = 0;

      for (let i = 0; i < tags.length; i += CHUNK_SIZE) {
        const chunk = tags.slice(i, i + CHUNK_SIZE).map((t) => t.trim().toLowerCase());
        await useDatabase().transaction(async (tx) => {
          await tx.query("SET LOCAL lock_timeout = '2000ms'");
          const result = await tx.query(
            `INSERT INTO tags (org_id, name, created_at)
             SELECT $1, unnest($2::text[]), clock_timestamp()
             ON CONFLICT (org_id, name) DO NOTHING`,
            [orgId, chunk]
          );
          inserted += result.rowCount || 0;
        });
      }

      return { success: true, count: inserted };
    });

    // server/api/audit-events/export.get.ts
    // Invariant: Optimized projection matching Column Tetris physical storage layout
    // for maximum streaming throughput and minimal deserialization overhead
    export const exportAuditEventsHandler = defineEventHandler(async (event) => {
      const db = useDatabase();
      const events = await db.query(
        `SELECT
           id, created_at, processed_at, cost_microcents,
           tenant_id, retry_count, is_success, is_internal, is_billable,
           payload_hash
         FROM user_audit_events
         ORDER BY id DESC
         LIMIT 500;`
      );
      return { events: events.rows };
    });

    // server/api/orders/lookup.post.ts
    // Invariant: Static SQL using = ANY($1::uuid[]) to prevent prepared statement cache explosion,
    // plus resilient recovery on PostgreSQL SQLSTATE 0A000 (cached plan invalidation during DDL)
    export const orderLookupHandler = defineEventHandler(async (event) => {
      const body = await readBody<{ orderIds: string[]; status?: string }>(event);
      if (!Array.isArray(body?.orderIds) || body.orderIds.length === 0) {
        throw createError({ statusCode: 400, message: 'Invalid orderIds array' });
      }

      const db = useDatabase();
      const sql = `
        SELECT id, tenant_id, status, amount_cents, created_at
        FROM customer_orders
        WHERE id = ANY($1::UUID[])
          AND ($2::TEXT IS NULL OR status = $2)
        ORDER BY created_at DESC;
      `;

      try {
        const result = await db.query(sql, [body.orderIds, body.status || null]);
        return { orders: result.rows };
      } catch (err: any) {
        if (err?.code === '0A000' || err?.code === 'XX000') {
          // Cached plan invalidated by concurrent zero-downtime DDL migration; retry once
          await db.query('DISCARD PLANS');
          const retryRes = await db.query(sql, [body.orderIds, body.status || null]);
          return { orders: retryRes.rows };
        }
        throw err;
      }
    });

    // server/api/accounts/deduct.post.ts
    // Invariant: Non-key row locking using FOR NO KEY UPDATE NOWAIT.
    // Prevents blocking concurrent child table foreign key validations (LockTupleKeyShare),
    // and maps PostgreSQL SQLSTATE 55P03 (lock_not_available) to HTTP 409 Conflict.
    export const accountDeductHandler = defineEventHandler(async (event) => {
      const body = await readBody<{ accountId: string; amountCents: number }>(event);
      if (!body?.accountId || typeof body.amountCents !== 'number' || body.amountCents <= 0) {
        throw createError({ statusCode: 400, message: 'Invalid deduction payload' });
      }

      const client = await useDatabase().connect();
      try {
        await client.query('BEGIN;');
        await client.query("SET LOCAL lock_timeout = '2000ms';");

        // Lock row with weak exclusive lock: allows child FK checks to proceed
        const selectSql = `
          SELECT id, balance_cents
          FROM accounts
          WHERE id = $1
          FOR NO KEY UPDATE NOWAIT;
        `;
        const res = await client.query(selectSql, [body.accountId]);
        if (res.rowCount === 0) {
          throw createError({ statusCode: 404, message: 'Account not found' });
        }

        const currentBalance = Number(res.rows[0].balance_cents);
        if (currentBalance < body.amountCents) {
          throw createError({ statusCode: 422, message: 'Insufficient balance' });
        }

        const updateSql = `
          UPDATE accounts
          SET balance_cents = balance_cents - $1,
              updated_at = NOW()
          WHERE id = $2
          RETURNING id, balance_cents;
        `;
        const updateRes = await client.query(updateSql, [body.amountCents, body.accountId]);
        await client.query('COMMIT;');

        return { success: true, account: updateRes.rows[0] };
      } catch (err: any) {
        await client.query('ROLLBACK;').catch(() => {});
        if (err?.code === '55P03') {
          // Resource currently locked by another concurrent transaction
          throw createError({
            statusCode: 409,
            message: 'Account is currently being modified by another transaction. Please retry.',
          });
        }
        throw err;
      } finally {
        client.release();
      }
    });

    // server/api/orders/user.get.ts
    // Invariant: Zero-heap Index-Only Scan via PostgreSQL covering index with leaf-only INCLUDE payload.
    // Relies on: CREATE INDEX CONCURRENTLY idx_orders_user_cov ON orders (user_id) INCLUDE (status, total_amount_cents, created_at);
    // Preserves Heap-Only Tuple (HOT) update efficiency by excluding mutable timestamps from INCLUDE.
    export const userOrdersCoveredHandler = defineEventHandler(async (event) => {
      const query = getQuery(event);
      const userId = query.userId as string;
      if (!userId) {
        throw createError({ statusCode: 400, message: 'Missing userId parameter' });
      }

      const client = await useDatabase().connect();
      try {
        const sql = `
          SELECT id, status, total_amount_cents, created_at
          FROM orders
          WHERE user_id = $1
          ORDER BY user_id
          LIMIT 50;
        `;
        const res = await client.query(sql, [userId]);
        return { success: true, count: res.rowCount, orders: res.rows };
      } catch (err: any) {
        throw createError({ statusCode: 500, message: `Failed to fetch user orders: ${err.message}` });
      } finally {
        client.release();
      }
    });

    // server/api/tasks/poll.post.ts
    // Invariant: Non-blocking worker dequeue over asymmetric partial queue index.
    // Relies on: CREATE INDEX idx_tasks_pending_queue ON tasks (tenant_id, created_at) WHERE status = 'PENDING' WITH (fillfactor = 85);
    // Hardcodes literal "status = 'PENDING'" in SQL to guarantee partial index match across generic and custom plans.
    export const pollPendingTaskHandler = defineEventHandler(async (event) => {
      const body = await readBody(event);
      const tenantId = body?.tenantId as string;
      if (!tenantId) {
        throw createError({ statusCode: 400, message: 'Missing tenantId parameter' });
      }

      const client = await useDatabase().connect();
      try {
        const sql = `
          UPDATE tasks
          SET status = 'PROCESSING',
              updated_at = CLOCK_TIMESTAMP()
          WHERE id = (
            SELECT id
            FROM tasks
            WHERE tenant_id = $1
              AND status = 'PENDING'
            ORDER BY created_at ASC
            LIMIT 1
            FOR UPDATE SKIP LOCKED
          )
          RETURNING id, tenant_id, payload, created_at;
        `;
        const res = await client.query(sql, [tenantId]);
        if (res.rowCount === 0) {
          return { success: true, task: null };
        }
        return { success: true, task: res.rows[0] };
      } catch (err: any) {
        throw createError({ statusCode: 500, message: `Failed to poll task: ${err.message}` });
      } finally {
        client.release();
      }
    });

    // server/api/analytics/customer-summary.get.ts
    // Invariant: CTE with explicit "AS NOT MATERIALIZED" ensuring predicate pushdown
    // and preventing the 2+ reference implicit materialization disk spill trap.
    export const getCustomerSummaryHandler = defineEventHandler(async (event) => {
      const query = getQuery(event);
      const tenantId = query.tenantId as string;
      if (!tenantId) {
        throw createError({ statusCode: 400, message: 'Missing tenantId query parameter' });
      }

      const client = await useDatabase().connect();
      try {
        const sql = `
          WITH customer_metrics AS NOT MATERIALIZED (
            SELECT 
              customer_id,
              COUNT(id) AS total_orders,
              COALESCE(SUM(total_amount), 0) AS lifetime_spend,
              MAX(created_at) AS last_order_date
            FROM orders
            WHERE tenant_id = $1
            GROUP BY customer_id
          )
          SELECT 
            c.id,
            c.email,
            c.name,
            m.total_orders,
            m.lifetime_spend,
            m.last_order_date
          FROM customers c
          JOIN customer_metrics m ON m.customer_id = c.id
          WHERE c.tenant_id = $1
            AND c.status = 'ACTIVE'
          ORDER BY m.lifetime_spend DESC
          LIMIT 100;
        `;
        const result = await client.query(sql, [tenantId]);
        return { success: true, count: result.rowCount, customers: result.rows };
      } catch (err: any) {
        throw createError({ statusCode: 500, message: `Failed to fetch customer summary: ${err.message}` });
      } finally {
        client.release();
      }
    });

    // server/api/orders/feed.get.ts
    // Invariant: Keyset cursor pagination with Deferred Join (Late Lookup).
    // Avoids O(N) offset scans and eliminates wide tuple materialization in work_mem.
    export const getOrdersFeedHandler = defineEventHandler(async (event) => {
      const query = getQuery(event);
      const tenantId = query.tenantId as string;
      const cursorToken = query.cursor as string | undefined;
      const limit = Math.min(parseInt(query.limit as string || '20', 10), 100);

      if (!tenantId) {
        throw createError({ statusCode: 400, message: 'Missing tenantId parameter' });
      }

      let cursorTime: string | null = null;
      let cursorId: string | null = null;

      if (cursorToken) {
        try {
          const [payloadB64, sig] = cursorToken.split('.');
          const secret = useRuntimeConfig().cursorSecret || 'default-secret-key';
          const expectedSig = crypto.createHmac('sha256', secret).update(payloadB64).digest('base64url');
          if (sig !== expectedSig) {
            throw createError({ statusCode: 400, message: 'Tampered cursor signature' });
          }
          const payload = JSON.parse(Buffer.from(payloadB64, 'base64url').toString('utf8'));
          cursorTime = payload.t;
          cursorId = payload.i;
        } catch (e: any) {
          throw createError({ statusCode: 400, message: 'Malformed cursor token' });
        }
      }

      const client = await useDatabase().connect();
      try {
        // Two-phase deferred join: seeks IDs on compact index first, then joins dimension tables
        const sql = `
          WITH target_ids AS (
            SELECT id
            FROM orders
            WHERE tenant_id = $1
              AND (
                ($2::timestamptz IS NULL AND $3::uuid IS NULL)
                OR (created_at, id) < ($2, $3)
              )
            ORDER BY created_at DESC NULLS LAST, id DESC
            LIMIT $4
          )
          SELECT 
            o.id, o.order_number, o.total_amount, o.created_at,
            c.name AS customer_name, c.email AS customer_email
          FROM target_ids tid
          JOIN orders o ON o.id = tid.id
          JOIN customers c ON c.id = o.customer_id
          ORDER BY o.created_at DESC, o.id DESC;
        `;

        const result = await client.query(sql, [tenantId, cursorTime, cursorId, limit + 1]);
        const hasMore = result.rows.length > limit;
        const items = hasMore ? result.rows.slice(0, limit) : result.rows;

        let nextCursor: string | null = null;
        if (hasMore && items.length > 0) {
          const last = items[items.length - 1];
          const secret = useRuntimeConfig().cursorSecret || 'default-secret-key';
          const payload = Buffer.from(
            JSON.stringify({ t: last.created_at, i: last.id })
          ).toString('base64url');
          const sig = crypto.createHmac('sha256', secret).update(payload).digest('base64url');
          nextCursor = `${payload}.${sig}`;
        }

        return { success: true, items, nextCursor, hasMore };
      } catch (err: any) {
        throw createError({ statusCode: 500, message: `Keyset feed query failed: ${err.message}` });
      } finally {
        client.release();
      }
    });

    // server/api/analytics/store-metrics.get.ts
    // Invariant: Window aggregation with explicit bounded sliding frames & named WINDOW consolidation
    export const getStoreMetricsHandler = defineEventHandler(async (event) => {
      const query = getQuery(event);
      const tenantId = query.tenantId as string;
      const storeId = query.storeId as string;

      if (!tenantId || !storeId) {
        throw createError({ statusCode: 400, message: 'Missing tenantId or storeId' });
      }

      const client = await useDatabase().connect();
      try {
        const sql = `
          SELECT 
            id, store_id, recorded_date, daily_revenue_cents,
            SUM(daily_revenue_cents) OVER w_mtd AS mtd_revenue_cents,
            AVG(daily_revenue_cents) OVER w_7d AS trailing_7d_avg_cents,
            DENSE_RANK() OVER (
              PARTITION BY store_id 
              ORDER BY daily_revenue_cents DESC, id ASC
            ) AS revenue_rank
          FROM store_daily_metrics
          WHERE tenant_id = $1 AND store_id = $2
          WINDOW 
            w_mtd AS (
              PARTITION BY store_id 
              ORDER BY recorded_date ASC, id ASC
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ),
            w_7d AS (
              PARTITION BY store_id 
              ORDER BY recorded_date ASC, id ASC
              ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
            )
          ORDER BY recorded_date ASC, id ASC;
        `;

        const result = await client.query(sql, [tenantId, storeId]);
        return { success: true, metrics: result.rows };
      } catch (err: any) {
        throw createError({ statusCode: 500, message: `Store metrics calculation failed: ${err.message}` });
      } finally {
        client.release();
      }
    });

    // server/api/v1/telemetry/bulk.post.ts - Bulk Ingestion Handler
    // Enforces parameter safety bounds (chunkSize <= 1000) and atomic set reconciliation
    export default defineEventHandler(async (event) => {
      const tenantId = event.context.auth?.tenantId;
      if (!tenantId) {
        throw createError({ statusCode: 401, message: 'Unauthorized' });
      }

      const body = await readBody(event);
      const readings = body?.readings as Array<{ deviceId: string; metric: string; val: number; recordedAt: string }>;
      if (!Array.isArray(readings) || readings.length === 0) {
        throw createError({ statusCode: 400, message: 'Invalid or empty readings payload' });
      }

      const cols = 5; // tenant_id, device_id, metric, val, recorded_at
      const chunkSize = Math.min(1000, Math.floor((65535 - 500) / cols));
      const client = await useDatabase().connect();

      try {
        await client.query('BEGIN');
        await client.query('SET LOCAL synchronous_commit = off');

        for (let i = 0; i < readings.length; i += chunkSize) {
          const chunk = readings.slice(i, i + chunkSize);
          const params: any[] = [];
          const rowsSql: string[] = [];

          chunk.forEach((r, idx) => {
            const base = idx * cols;
            rowsSql.push(`($${base + 1}, $${base + 2}, $${base + 3}, $${base + 4}, $${base + 5})`);
            params.push(tenantId, r.deviceId, r.metric, r.val, r.recordedAt);
          });

          await client.query(
            `INSERT INTO sensor_metrics (tenant_id, device_id, metric, val, recorded_at)
             VALUES ${rowsSql.join(', ')}
             ON CONFLICT (tenant_id, device_id, recorded_at, metric) DO UPDATE
             SET val = EXCLUDED.val;`,
            params
          );
        }

        await client.query('COMMIT');
        return { success: true, ingested: readings.length };
      } catch (err: any) {
        await client.query('ROLLBACK');
        throw createError({ statusCode: 500, message: `Bulk ingestion failed: ${err.message}` });
      } finally {
        client.release();
      }
    });

    // server/api/v1/categories/top-products.get.ts - Per-Group Top-K Lateral Endpoint
    // Enforces LEFT JOIN LATERAL seek with clamped limit and zero full-table window sort
    export default defineEventHandler(async (event) => {
      const tenantId = event.context.auth?.tenantId;
      if (!tenantId) {
        throw createError({ statusCode: 401, message: 'Unauthorized' });
      }

      const query = getQuery(event);
      const limitParam = parseInt(query.limit as string || '3', 10);
      const topK = Math.max(1, Math.min(limitParam, 20));

      const client = await useDatabase().connect();
      try {
        const result = await client.query(
          `SELECT
             c.id AS category_id,
             c.name AS category_name,
             top_p.id AS product_id,
             top_p.name AS product_name,
             top_p.price,
             top_p.sales_count
           FROM categories c
           LEFT JOIN LATERAL (
             SELECT p.id, p.name, p.price, p.sales_count
             FROM products p
             WHERE p.category_id = c.id AND p.is_active = true
             ORDER BY p.sales_count DESC
             LIMIT $2
           ) top_p ON true
           WHERE c.tenant_id = $1 AND c.is_visible = true
           ORDER BY c.name ASC, top_p.sales_count DESC NULLS LAST;`,
          [tenantId, topK]
        );

        return { categories: result.rows };
      } catch (err: any) {
        throw createError({ statusCode: 500, message: `Failed querying category top products: ${err.message}` });
      } finally {
        client.release();
      }
    });

    // server/api/v1/categories/relocate.post.ts - Safe Subtree Relocation Endpoint
    // Enforces cycle pre-check and atomic ltree path rewriting in a single transaction
    export default defineEventHandler(async (event) => {
      const tenantId = event.context.auth?.tenantId;
      if (!tenantId) {
        throw createError({ statusCode: 401, message: 'Unauthorized' });
      }

      const body = await readBody(event);
      const { nodeId, newParentId } = body;
      if (!nodeId) {
        throw createError({ statusCode: 400, message: 'Missing nodeId parameter' });
      }

      const client = await useDatabase().connect();
      try {
        await client.query('BEGIN');

        // 1. Lock source node and get current path
        const sourceRes = await client.query(
          'SELECT path::text, slug FROM categories WHERE id = $1 AND tenant_id = $2 FOR UPDATE',
          [nodeId, tenantId]
        );
        if (sourceRes.rowCount === 0) {
          throw createError({ statusCode: 404, message: 'Source node not found' });
        }
        const { path: currentPath, slug } = sourceRes.rows[0];

        let newBasePath = slug;
        if (newParentId) {
          // 2. Lock target parent
          const parentRes = await client.query(
            'SELECT path::text FROM categories WHERE id = $1 AND tenant_id = $2 FOR UPDATE',
            [newParentId, tenantId]
          );
          if (parentRes.rowCount === 0) {
            throw createError({ statusCode: 404, message: 'Target parent node not found' });
          }
          const targetPath = parentRes.rows[0].path;

          // 3. Cycle pre-check: target cannot be within currentPath's subtree
          if (targetPath === currentPath || targetPath.startsWith(`${currentPath}.`)) {
            throw createError({
              statusCode: 400,
              message: 'Cycle detected: Cannot move a node into its own descendant subtree',
            });
          }
          newBasePath = `${targetPath}.${slug}`;
        }

        // 4. Atomic subtree rewrite via ltree subpath concatenation
        await client.query(
          `UPDATE categories
           SET path = $3::ltree || subpath(path, nlevel($1::ltree))
           WHERE tenant_id = $2 AND path <@ $1::ltree`,
          [currentPath, tenantId, newBasePath]
        );

        await client.query('COMMIT');
        return { success: true, newPath: newBasePath };
      } catch (err: any) {
        await client.query('ROLLBACK');
        if (err.statusCode) throw err;
        throw createError({ statusCode: 500, message: `Subtree relocation failed: ${err.message}` });
      } finally {
        client.release();
      }
    });

    // server/api/v1/inventory/batch-update.post.ts - Batch Inventory Update Endpoint
    // Leverages PostgreSQL statement transition tables for vectorized audit logging
    export default defineEventHandler(async (event) => {
      const tenantId = event.context.auth?.tenantId;
      if (!tenantId) {
        throw createError({ statusCode: 401, message: 'Unauthorized' });
      }

      const body = await readBody(event);
      const updates = body.updates as Array<{ id: string; quantity: number; unitPrice: number }>;
      if (!Array.isArray(updates) || updates.length === 0) {
        throw createError({ statusCode: 400, message: 'Invalid or empty updates array' });
      }

      const client = await useDatabase().connect();
      try {
        await client.query('BEGIN');

        // Set tenant session context for RLS / audit triggers
        await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);

        // Vectorized bulk update via JSONB recordset - statement transition table triggers execute once
        const updateSql = `
          WITH batch_data AS (
            SELECT * FROM jsonb_to_recordset($1::jsonb) 
            AS x(id uuid, quantity int, unit_price numeric)
          )
          UPDATE inventory_items inv
          SET quantity = b.quantity,
              unit_price = b.unit_price
          FROM batch_data b
          WHERE inv.id = b.id AND inv.tenant_id = $2::uuid;
        `;

        const result = await client.query(updateSql, [JSON.stringify(updates), tenantId]);

        await client.query('COMMIT');
        return { success: true, updatedCount: result.rowCount };
      } catch (err: any) {
        await client.query('ROLLBACK');
        throw createError({ statusCode: 500, message: `Batch inventory update failed: ${err.message}` });
      } finally {
        client.release();
      }
    });

    // server/api/v1/audit/stream-export.get.ts - Nitro Streaming Endpoint
    // Streams audit events using a server-side NO SCROLL cursor and Web Streams with constant RAM
    export default defineEventHandler(async (event) => {
      const tenantId = event.context.auth?.tenantId;
      if (!tenantId) {
        throw createError({ statusCode: 401, message: 'Unauthorized' });
      }

      const client = await useDatabase().connect();
      const cursorName = 'nitro_audit_stream_cur';
      let inTransaction = false;

      setResponseHeader(event, 'Content-Type', 'application/x-ndjson');
      setResponseHeader(event, 'Content-Disposition', 'attachment; filename="export.ndjson"');

      const stream = new ReadableStream({
        async start(controller) {
          try {
            await client.query('BEGIN READ ONLY');
            await client.query("SET LOCAL idle_in_transaction_session_timeout = '20s'");
            await client.query(
              `DECLARE ${cursorName} NO SCROLL CURSOR FOR
               SELECT id, payload, created_at
               FROM audit_events
               WHERE tenant_id = $1
               ORDER BY created_at ASC, id ASC`,
              [tenantId]
            );
            inTransaction = true;
          } catch (err: any) {
            controller.error(err);
            client.release();
          }
        },
        async pull(controller) {
          try {
            const res = await client.query(`FETCH FORWARD 500 FROM ${cursorName}`);
            if (res.rows.length === 0) {
              if (inTransaction) {
                await client.query(`CLOSE ${cursorName}`);
                await client.query('COMMIT');
                inTransaction = false;
              }
              client.release();
              controller.close();
              return;
            }

            const encoder = new TextEncoder();
            for (const row of res.rows) {
              controller.enqueue(encoder.encode(JSON.stringify(row) + '\n'));
            }
          } catch (err: any) {
            if (inTransaction) {
              await client.query('ROLLBACK').catch(() => {});
            }
            client.release();
            controller.error(err);
          }
        },
        async cancel() {
          if (inTransaction) {
            await client.query('ROLLBACK').catch(() => {});
          }
          client.release();
        },
      });

      return sendStream(event, stream);
    });

    // composables/useUnicodeCanonicalize.ts - Unicode Form C (NFC) Canonicalization Composable
    export function useUnicodeCanonicalize() {
      // Normalizes strings to Unicode NFC and strips whitespace
      const canonicalize = (val: string): string => {
        if (!val) return '';
        return val.normalize('NFC').trim();
      };

      // Canonicalizes email addresses (NFC + lowercase domain)
      const canonicalizeEmail = (email: string): string => {
        if (!email) return '';
        const trimmed = email.normalize('NFC').trim();
        const atIdx = trimmed.lastIndexOf('@');
        if (atIdx === -1) return trimmed.toLowerCase();
        const local = trimmed.slice(0, atIdx);
        const domain = trimmed.slice(atIdx + 1).toLowerCase();
        return `${local}@${domain}`;
      };

      return {
        canonicalize,
        canonicalizeEmail,
      };
    }

    // server/api/v1/auth/register.post.ts - Nitro Auth Endpoint with Invariant Enforcement
    export default defineEventHandler(async (event) => {
      const body = await readBody(event);
      const rawUsername = body.username as string;
      const rawEmail = body.email as string;

      if (!rawUsername || !rawEmail) {
        throw createError({ statusCode: 400, message: 'Username and email are required.' });
      }

      // Enforce Unicode NFC Canonicalization
      const canonicalUsername = rawUsername.normalize('NFC').trim();
      const canonicalEmail = rawEmail.normalize('NFC').trim().toLowerCase();

      const db = useDatabase();
      try {
        // Leverages PostgreSQL case_insensitive_icu collation and uidx_users_email_lower
        const result = await db.query(
          `INSERT INTO users (id, api_token, session_hash, username, email, account_code)
           VALUES (gen_random_uuid(), gen_random_uuid()::text, gen_random_uuid()::text, $1, $2, $3)
           RETURNING id, username, email, created_at`,
          [canonicalUsername, canonicalEmail, 'ACC-DEFAULT']
        );

        return { success: true, user: result.rows[0] };
      } catch (err: any) {
        if (err.code === '23505') { // Unique violation
          throw createError({ statusCode: 409, message: 'Username or email already registered.' });
        }
        if (err.code === '23514') { // Check constraint violation (e.g. NFC failure)
          throw createError({ statusCode: 422, message: 'Input violates Unicode canonical normalization standards.' });
        }
        throw createError({ statusCode: 500, message: 'Internal registration failure.' });
      }
    });

    // server/api/v1/ops/xid-wraparound.get.ts - Server Endpoint Auditing PostgreSQL XID Wraparound Posture
    export default defineEventHandler(async (event) => {
      const db = useDatabase();
      const query = `
        SELECT
          d.datname,
          age(d.datfrozenxid) AS age_datfrozenxid,
          age(d.datminmxid) AS age_datminmxid,
          (2137483648 - age(d.datfrozenxid)) AS remaining_xids,
          (
            SELECT count(*)
            FROM pg_replication_slots s
            WHERE s.active = false AND (age(s.xmin) > 10000000 OR age(s.catalog_xmin) > 10000000)
          ) AS abandoned_slots
        FROM pg_database d
        WHERE d.datallowconn = true
        ORDER BY age(d.datfrozenxid) DESC;
      `;
      const result = await db.query(query);
      const burnRatePerSec = 3500; // Expected baseline transactions per second

      const databases = result.rows.map((row: any) => {
        const remaining = Number(row.remaining_xids);
        const ttwHours = Math.max(0, Math.round((remaining / burnRatePerSec / 3600) * 10) / 10);
        const age = Number(row.age_datfrozenxid);

        let riskLevel = 'NOMINAL';
        if (age >= 1_500_000_000 || ttwHours < 24) riskLevel = 'EMERGENCY';
        else if (age >= 1_000_000_000 || ttwHours < 48) riskLevel = 'CRITICAL';
        else if (age >= 200_000_000) riskLevel = 'WARNING';

        return {
          datname: row.datname,
          ageDatfrozenxid: age,
          ageDatminmxid: Number(row.age_datminmxid),
          remainingXids: remaining,
          timeToWraparoundHours: ttwHours,
          abandonedSlots: Number(row.abandoned_slots),
          riskLevel,
        };
      });

      return {
        timestamp: new Date().toISOString(),
        databases,
        hasCriticalRisk: databases.some((d: any) => d.riskLevel === 'CRITICAL' || d.riskLevel === 'EMERGENCY'),
      };
    });

    // server/api/admin/database/toast-health.ts - Nuxt 3 server route for TOAST storage diagnostics
    export default defineEventHandler(async (event) => {
      const db = useDatabase();

      const query = `
        SELECT
          n.nspname AS schema_name,
          c.relname AS table_name,
          a.attname AS column_name,
          pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
          a.attstorage::text AS storage_strategy,
          COALESCE(a.attcompression::text, 'default') AS compression,
          COALESCE(tc.relname, '') AS toast_rel_name,
          COALESCE(pg_total_relation_size(c.reltoastrelid), 0) AS toast_size_bytes,
          COALESCE(s.avg_width, 0) AS avg_payload_bytes
        FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        LEFT JOIN pg_class tc ON c.reltoastrelid = tc.oid
        LEFT JOIN pg_stats s ON s.schemaname = n.nspname AND s.tablename = c.relname AND s.attname = a.attname
        WHERE a.attnum > 0
          AND NOT a.attisdropped
          AND c.relkind IN ('r', 'p')
          AND a.attstorage IN ('x', 'e', 'm')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY toast_size_bytes DESC;
      `;
      const result = await db.query(query);

      const toastAudits = result.rows.map((r: any) => {
        const isLegacyPglz = (r.data_type.includes('text') || r.data_type.includes('jsonb')) && r.compression === 'p';
        const isLowDensity = r.avg_payload_bytes >= 600 && r.avg_payload_bytes <= 1900 && r.storage_strategy === 'e';

        return {
          schema: r.schema_name,
          table: r.table_name,
          column: r.column_name,
          dataType: r.data_type,
          strategy: r.storage_strategy === 'e' ? 'EXTENDED' : r.storage_strategy === 'x' ? 'EXTERNAL' : 'MAIN',
          compression: r.compression === 'l' ? 'lz4' : r.compression === 'p' ? 'pglz' : 'default',
          toastSizeBytes: Number(r.toast_size_bytes),
          avgPayloadBytes: Number(r.avg_payload_bytes),
          needsLz4Migration: isLegacyPglz,
          needsToastTargetTuning: isLowDensity,
        };
      });

      return {
        timestamp: new Date().toISOString(),
        columns: toastAudits,
        totalToastedColumns: toastAudits.length,
        legacyPglzCount: toastAudits.filter((c: any) => c.needsLz4Migration).length,
      };
    });

    // server/api/admin/database/catalog-health.ts - Nuxt 3 server route for System Catalog bloat diagnostics
    export default defineEventHandler(async (event) => {
      const db = useDatabase();

      const query = `
        SELECT
          c.relname AS table_name,
          COALESCE(s.n_live_tup, 0) AS live_tuples,
          COALESCE(s.n_dead_tup, 0) AS dead_tuples,
          CASE
            WHEN (COALESCE(s.n_live_tup, 0) + COALESCE(s.n_dead_tup, 0)) = 0 THEN 0.0
            ELSE ROUND(COALESCE(s.n_dead_tup, 0)::numeric / (s.n_live_tup + s.n_dead_tup), 4)
          END AS dead_tuple_ratio,
          pg_total_relation_size(c.oid) AS total_size_bytes
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        LEFT JOIN pg_stat_sys_tables s ON s.schemaname = n.nspname AND s.relname = c.relname
        WHERE n.nspname = 'pg_catalog'
          AND c.relname IN ('pg_class', 'pg_attribute', 'pg_type', 'pg_depend')
        ORDER BY total_size_bytes DESC;
      `;
      const result = await db.query(query);

      const catalogs = result.rows.map((r: any) => ({
        tableName: r.table_name,
        liveTuples: Number(r.live_tuples),
        deadTuples: Number(r.dead_tuples),
        deadRatioPct: Number(r.dead_tuple_ratio) * 100,
        totalSizeMb: Number((Number(r.total_size_bytes) / (1024 * 1024)).toFixed(2)),
        bloatAlert: Number(r.dead_tuple_ratio) > 0.20 || Number(r.dead_tuples) > 5000,
      }));

      return {
        timestamp: new Date().toISOString(),
        catalogs,
        hasCatalogBloatRisk: catalogs.some((c: any) => c.bloatAlert),
      };
    });
    ```

- **Nuxt 3 Server API Database Pipelining & SSR Round-Trip Latency (RTT) Minimization**:
  - ❌ **Anti-Pattern: Sequential Awaited DB Queries in Nitro Event Handlers**:
    - Writing `for (const id of ids) { await db.query(...) }` inside `server/api/` Nitro endpoints, burning $N \times \text{RTT}$ in network idle time and exhausting serverless worker timeout budgets.
    - Serializing complex relational state into verbose JSON strings on the server and re-parsing on the client, instead of leveraging native binary / typed representations.
  - ✅ **Production Invariant**:
    - Enforce wire pipelining with `Promise.all()` or driver-level batching (`postgres.js` / `drizzle-orm` batch API) within Nuxt 3 event handlers to execute all sub-queries in a single network turnaround.
    - Explicitly set `{ noDelay: true }` on database client socket configurations inside Nuxt server plugins (`server/plugins/database.ts`).
    ```typescript
    // server/api/v1/batch-metrics.post.ts
    // Nitro route enforcing pipelined batch execution and zero N+1 wire turnarounds
    import { defineEventHandler, readBody } from 'h3';
    import { getDatabaseClient } from '~/server/utils/db';

    export default defineEventHandler(async (event) => {
      const body = await readBody(event);
      const items = body.items as Array<{ id: string; category: string }>;
      if (!items || items.length === 0) return { inserted: 0 };

      const sql = getDatabaseClient();

      // Pipelined execution: postgres.js dispatches all queries concurrently in a single TCP socket stream
      const results = await sql.begin(async (tx) => {
        const promises = items.map((item) =>
          tx`
            INSERT INTO telemetry_events (id, category, recorded_at)
            VALUES (${item.id}, ${item.category}, NOW())
          `
        );
        return Promise.all(promises);
      });

      return { inserted: results.length };
    });
    ```

- **Nuxt 3 Nitro Server Database Read Replica Standby Recovery Conflict Defense**:
  - ❌ **Anti-Pattern: Unhandled Recovery Aborts & Primary Flooding in SSR Handlers**:
    - Querying read replicas directly from Nitro routes without catching SQLSTATE `40001` or `57014` (`canceling statement due to conflict with recovery`), causing intermittent HTTP 500 errors during peak primary write traffic.
    - Catching replica errors and instantly falling back to the Primary writer for all requests without jitter or rate limiting, triggering a cascading thundering herd that takes down the Primary database.
  - ✅ **Production Invariant**:
    - Wrap Nitro read queries in a resilient helper that detects recovery conflict signatures, executes decorrelated exponential jitter retries on the replica, and falls back to primary only as a circuit-broken last resort.
    ```typescript
    // server/utils/resilient-replica-query.ts
    // Nitro utility executing resilient reads across PostgreSQL read replicas
    import { getReplicaClient, getPrimaryClient } from '~/server/utils/db';

    export async function executeResilientReplicaRead<T>(
      queryBuilder: (sql: any) => Promise<T>,
      options = { maxRetries: 3, baseDelayMs: 50, maxDelayMs: 2000, allowFallback: true }
    ): Promise<T> {
      const replicaSql = getReplicaClient();
      let delay = options.baseDelayMs;

      for (let attempt = 1; attempt <= options.maxRetries; attempt++) {
        try {
          return await queryBuilder(replicaSql);
        } catch (error: any) {
          const code = error?.code;
          const msg = (error?.message || '').toLowerCase();
          const detail = (error?.detail || '').toLowerCase();
          const isRecoveryConflict =
            (code === '40001' || code === '57014') &&
            (msg.includes('conflict with recovery') || detail.includes('conflict with recovery'));

          if (!isRecoveryConflict) throw error;

          if (attempt === options.maxRetries) {
            if (options.allowFallback) {
              const primarySql = getPrimaryClient();
              return await queryBuilder(primarySql);
            }
            throw error;
          }

          // Decorrelated jitter backoff: min(maxDelay, random(baseDelay, prev * 3))
          const high = Math.min(options.maxDelayMs, delay * 3);
          delay = Math.floor(options.baseDelayMs + Math.random() * (high - options.baseDelayMs + 1));
          await new Promise((resolve) => setTimeout(resolve, delay));
        }
      }

      throw new Error('Standby recovery conflict retries exhausted');
    }
    ```

- **Nuxt 3 Nitro Server PostgreSQL LISTEN / NOTIFY & Realtime Event Streaming Invariants**:
  - ❌ **Anti-Pattern: Running LISTEN over Pooled Nitro Clients & Serializing Full Entity JSON**:
    - Invoking `sql.listen()` using the standard pooled Nitro database client routed through PgBouncer in transaction mode, leading to connection pinning or unhandled server exceptions.
    - Emitting full reactive component state or large database entities directly in `pg_notify()`, triggering PostgreSQL 8000-byte payload limits (SQLSTATE `54000`) and crashing SSR updates.
  - ✅ **Production Invariant**:
    - Instantiate a dedicated unpooled connection specifically for event listening on direct port 5432.
    - Implement the Thin Pointer (Claim-Check) pattern with monotonic keyset Outbox seek to hydrate live updates before streaming to clients via Server-Sent Events (SSE).
    ```typescript
    // server/routes/api/live-events.ts
    // Nuxt 3 Nitro SSE endpoint consuming PostgreSQL LISTEN/NOTIFY with Claim-Check Outbox hydration
    import { createEventStream } from 'h3';
    import postgres from 'postgres';

    export default defineEventHandler(async (event) => {
      // INVARIANT: Dedicated direct connection on direct port 5432, NOT PgBouncer transaction mode
      const directListener = postgres(process.env.DIRECT_DATABASE_URL!, {
        max: 1,
        idle_timeout: 0,
        keep_alive: 10,
      });

      const eventStream = createEventStream(event);
      let lastProcessedId = 0;

      // Thin Pointer listener waking up Outbox keyset seek
      await directListener.listen('outbox_stream', async (rawPayload) => {
        try {
          const envelope = JSON.parse(rawPayload);
          const rows = await directListener`
            SELECT id, aggregate_id, event_type, payload, created_at
            FROM event_outbox
            WHERE id > ${lastProcessedId}
            ORDER BY id ASC
            LIMIT 50
          `;

          for (const row of rows) {
            lastProcessedId = row.id;
            await eventStream.push(JSON.stringify(row));
          }
        } catch (err: any) {
          console.error('[Nitro Realtime] Outbox hydration failed:', err);
        }
      });

      eventStream.onClosed(async () => {
        try {
          await directListener.end({ timeout: 2 });
        } catch (_) {}
      });

      return eventStream.send();
    });
    ```

## 18. Nuxt 3 & Nitro Heavy Reporting & Parallel Query Streaming

When handling heavy dashboard data tables, aggregations, or export endpoints:

- **Chunked Streaming Response via Nitro**:
  - Never buffer gigabyte analytical query results into V8 heap memory before responding.
  - Stream results chunk-by-chunk using `sendStream` or `createEventStream`, applying `SET LOCAL work_mem` on the server transaction to prevent worker starvation and memory spikes:

    ```ts
    // server/api/reports/stream.get.ts
    import { defineEventHandler } from 'h3';
    import { getDbPool } from '~/server/utils/db';

    export default defineEventHandler(async (event) => {
      const pool = getDbPool();
      const client = await pool.connect();

      try {
        await client.query('BEGIN READ ONLY');
        await client.query('SET LOCAL max_parallel_workers_per_gather = 2');
        await client.query('SET LOCAL work_mem = "32MB"');

        const cursor = client.query(new (await import('pg-cursor')).default(
          'SELECT metric_name, sum(value) as total FROM analytical_events GROUP BY metric_name'
        ));

        // Read chunks and stream to client without heap bloat
        // ...
      } finally {
        await client.query('ROLLBACK');
        client.release();
      }
    });
    ```

## 19. Distributed Transaction (2PC) & `pg_prepared_xacts` Dashboard Sentinel

When building administrative, DevOps, or system health portals in Nuxt 3:

- **Reactive Watchdog for In-Doubt Transactions**:
  - Never allow an orphaned prepared transaction to escape notice in system monitoring dashboards.
  - Implement real-time polling or Server-Sent Events (SSE) checking `pg_prepared_xacts` and displaying age status:

  ```vue
  <!-- components/TwoPhaseMonitor.vue -->
  <script setup lang="ts">
  interface PreparedTx {
    gid: string;
    prepared: string;
    owner: string;
    database: string;
    age_secs: number;
  }

  const { data: transactions, refresh } = await useFetch<PreparedTx[]>('/api/admin/prepared-tx', {
    default: () => [],
  });

  const criticalCount = computed(() => 
    transactions.value.filter(tx => tx.age_secs > 60).length
  );
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5 bg-white dark:bg-zinc-900 shadow-sm">
      <div class="flex items-center justify-between pb-4 border-b border-zinc-100 dark:border-zinc-800">
        <div>
          <h3 class="font-medium text-zinc-900 dark:text-zinc-100">In-Doubt Prepared Transactions (2PC)</h3>
          <p class="text-xs text-zinc-500">Monitors pg_prepared_xacts to prevent cluster-wide xmin vacuum horizon pinning</p>
        </div>
        <span
          :class="criticalCount > 0 ? 'bg-red-100 text-red-700 dark:bg-red-950/50 dark:text-red-400' : 'bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-400'"
          class="text-xs font-mono font-medium px-2.5 py-1 rounded-full"
        >
          {{ criticalCount > 0 ? `${criticalCount} CRITICAL` : 'HEALTHY' }}
        </span>
      </div>

      <div v-if="transactions.length === 0" class="py-8 text-center text-sm text-zinc-400">
        Zero active prepared transactions. Global vacuum horizon is unpinned.
      </div>

      <ul v-else class="divide-y divide-zinc-100 dark:divide-zinc-800 mt-3 font-mono text-xs">
        <li v-for="tx in transactions" :key="tx.gid" class="py-2.5 flex items-center justify-between">
          <span class="truncate max-w-md text-zinc-700 dark:text-zinc-300">{{ tx.gid }}</span>
          <span :class="tx.age_secs > 60 ? 'text-red-600 font-bold' : 'text-amber-500'">
            {{ tx.age_secs }}s
          </span>
        </li>
      </ul>
    </div>
  </template>
  ```

- **PostgreSQL Buffer Pool & `bgwriter` Telemetry Monitor (Vue 3 / Nuxt 3)**:
  - Telemetry card with Apple/Vercel design system displaying per-table cache hit ratios, backend write tax indicators, and cold relation warnings.

  ```vue
  <!-- components/BufferCacheMonitor.vue -->
  <script setup lang="ts">
  interface RelationMetric {
    relation: string;
    blocksRead: number;
    blocksHit: number;
    hitRatioPercent: number;
  }

  interface BgwriterStats {
    buffersClean: number;
    buffersBackend: number;
    backendWriteRatioPercent: number;
  }

  interface CacheHealthResponse {
    bgwriter: BgwriterStats;
    relations: RelationMetric[];
  }

  const { data: cacheData, refresh } = await useFetch<CacheHealthResponse>('/api/admin/buffercache', {
    default: () => ({
      bgwriter: { buffersClean: 0, buffersBackend: 0, backendWriteRatioPercent: 0 },
      relations: [],
    }),
  });

  const hasBackendWriteTax = computed(() => 
    (cacheData.value?.bgwriter.backendWriteRatioPercent ?? 0) > 5.0
  );

  const coldRelations = computed(() => 
    cacheData.value?.relations.filter(r => r.hitRatioPercent < 95.0) ?? []
  );
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5 bg-white dark:bg-zinc-900 shadow-sm space-y-5">
      <div class="flex items-center justify-between pb-4 border-b border-zinc-100 dark:border-zinc-800">
        <div>
          <h3 class="font-medium text-zinc-900 dark:text-zinc-100">Buffer Pool & bgwriter Telemetry</h3>
          <p class="text-xs text-zinc-500">PostgreSQL shared_buffers residency & synchronous write tax defense</p>
        </div>
        <span
          :class="hasBackendWriteTax ? 'bg-amber-100 text-amber-800 dark:bg-amber-950/50 dark:text-amber-300' : 'bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-400'"
          class="text-xs font-mono font-medium px-2.5 py-1 rounded-full"
        >
          {{ hasBackendWriteTax ? `BACKEND TAX: ${cacheData.bgwriter.backendWriteRatioPercent}%` : 'BGWRITER OPTIMAL' }}
        </span>
      </div>

      <!-- Quick Metrics Grid -->
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <div class="p-3.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/40 border border-zinc-100 dark:border-zinc-800">
          <p class="text-2xs uppercase tracking-wider text-zinc-400 font-semibold">Clean Buffers</p>
          <p class="text-lg font-mono font-bold text-zinc-900 dark:text-zinc-100 mt-0.5">
            {{ cacheData.bgwriter.buffersClean.toLocaleString() }}
          </p>
        </div>
        <div class="p-3.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/40 border border-zinc-100 dark:border-zinc-800">
          <p class="text-2xs uppercase tracking-wider text-zinc-400 font-semibold">Backend Writes</p>
          <p :class="hasBackendWriteTax ? 'text-amber-600' : 'text-zinc-900 dark:text-zinc-100'" class="text-lg font-mono font-bold mt-0.5">
            {{ cacheData.bgwriter.buffersBackend.toLocaleString() }}
          </p>
        </div>
        <div class="p-3.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/40 border border-zinc-100 dark:border-zinc-800">
          <p class="text-2xs uppercase tracking-wider text-zinc-400 font-semibold">Cold Relations</p>
          <p :class="coldRelations.length > 0 ? 'text-red-600' : 'text-emerald-600'" class="text-lg font-mono font-bold mt-0.5">
            {{ coldRelations.length }}
          </p>
        </div>
      </div>

      <!-- Top Relations List -->
      <div class="mt-4">
        <h4 class="text-2xs font-semibold uppercase tracking-wider text-zinc-400 mb-2">High-Volume Relation Hit Ratios</h4>
        <ul class="divide-y divide-zinc-100 dark:divide-zinc-800 font-mono text-xs">
          <li v-for="rel in cacheData.relations" :key="rel.relation" class="py-2.5 flex items-center justify-between">
            <span class="truncate max-w-sm text-zinc-700 dark:text-zinc-300">{{ rel.relation }}</span>
            <div class="flex items-center gap-3">
              <span class="text-2xs text-zinc-400">R: {{ rel.blocksRead }} / H: {{ rel.blocksHit }}</span>
              <span :class="rel.hitRatioPercent < 95.0 ? 'text-red-600 font-bold' : 'text-emerald-600'">
                {{ rel.hitRatioPercent.toFixed(1) }}%
              </span>
            </div>
          </li>
        </ul>
      </div>
    </div>
  </template>
  ```

- **PostgreSQL B-Tree Index Skip Scan & Distinct Query Audit Component**:
  - Implement a real-time audit card for detecting slow `DISTINCT` queries and providing one-click copyable Recursive CTE Loose Index Scan rewrites with predicted buffer savings.

  ```vue
  <!-- components/database/IndexSkipScanAuditCard.vue -->
  <script setup lang="ts">
  import { ref, computed } from 'vue';

  export interface SkipScanCandidate {
    id: string;
    tableName: string;
    columnName: string;
    totalRows: number;
    distinctKeys: number;
    meanTimeMs: number;
    sharedBlocks: number;
    rewrittenSql: string;
  }

  const props = defineProps<{
    candidates: SkipScanCandidate[];
    isScanning?: boolean;
  }>();

  const copiedId = ref<string | null>(null);

  const copyRewrite = async (candidate: SkipScanCandidate) => {
    await navigator.clipboard.writeText(candidate.rewrittenSql);
    copiedId.value = candidate.id;
    setTimeout(() => {
      copiedId.value = null;
    }, 2000);
  };

  const highImpactCount = computed(() =>
    props.candidates.filter(c => c.totalRows > 1000000 && (c.distinctKeys / c.totalRows) <= 0.05).length
  );
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 shadow-sm">
      <div class="flex items-center justify-between border-b border-zinc-100 dark:border-zinc-800 pb-4">
        <div>
          <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
            <span>⚡ Index Skip Scan Opportunities</span>
            <span v-if="candidates.length > 0" class="px-2 py-0.5 rounded-full text-2xs font-mono font-medium bg-indigo-50 text-indigo-700 dark:bg-indigo-950/60 dark:text-indigo-400">
              {{ candidates.length }} Detected
            </span>
          </h3>
          <p class="text-xs text-zinc-500 mt-0.5">
            Identify slow leaf-page traversals on DISTINCT; replace with Recursive CTE Loose Index Seeks.
          </p>
        </div>
        <span v-if="highImpactCount > 0" class="px-2.5 py-1 rounded-md text-xs font-medium bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300">
          {{ highImpactCount }} High Impact (≥100x Speedup)
        </span>
      </div>

      <div v-if="candidates.length === 0" class="py-8 text-center text-xs text-zinc-400">
        No slow DISTINCT queries detected. All indexed prefix scans are optimal.
      </div>

      <div v-else class="divide-y divide-zinc-100 dark:divide-zinc-800 mt-3">
        <div v-for="c in candidates" :key="c.id" class="py-3.5">
          <div class="flex items-center justify-between text-xs font-mono">
            <span class="font-semibold text-zinc-800 dark:text-zinc-200">
              {{ c.tableName }}.{{ c.columnName }}
            </span>
            <div class="flex items-center gap-3 text-2xs text-zinc-400">
              <span>Rows: {{ c.totalRows.toLocaleString() }}</span>
              <span>Keys: {{ c.distinctKeys.toLocaleString() }}</span>
              <span class="text-amber-600 font-bold">{{ c.meanTimeMs.toFixed(1) }}ms</span>
            </div>
          </div>

          <div class="mt-2 relative">
            <pre class="p-2.5 rounded-lg bg-zinc-950 text-zinc-200 font-mono text-2xs overflow-x-auto leading-relaxed">{{ c.rewrittenSql }}</pre>
            <button
              @click="copyRewrite(c)"
              class="absolute top-2 right-2 px-2 py-1 rounded bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-2xs font-sans transition-colors"
            >
              {{ copiedId === c.id ? '✓ Copied' : 'Copy SQL' }}
            </button>
          </div>
        </div>
      </div>
    </div>
  </template>
  ```

- **PostgreSQL B-Tree Index Deduplication & Posting List Health Card**:
  - Implement a real-time audit card for monitoring B-Tree deduplication efficiency, highlighting indexes wasting write CPU on high-entropy unique keys, and providing one-click copyable `REINDEX CONCURRENTLY` remediation DDL.

  ```vue
  <!-- components/database/BTreeDedupHealthCard.vue -->
  <script setup lang="ts">
  import { ref, computed } from 'vue';

  export interface BTreeAuditItem {
    indexName: string;
    tableName: string;
    indexSizeMb: number;
    cardinalityRatio: number;
    deduplicationEnabled: boolean;
    fillfactor: number;
    status: 'OPTIMAL' | 'HIGH_ENTROPY_CPU_PENALTY' | 'UNCOMPRESSED_LOW_CARDINALITY' | 'SUBOPTIMAL_FILLFACTOR';
    action: string;
    recommendedDdl: string;
  }

  const props = defineProps<{
    items: BTreeAuditItem[];
    isLoading?: boolean;
  }>();

  const copiedIndex = ref<string | null>(null);

  const riskCount = computed(() =>
    props.items.filter(i => i.status !== 'OPTIMAL').length
  );

  const copyDdl = async (item: BTreeAuditItem) => {
    if (!item.recommendedDdl) return;
    await navigator.clipboard.writeText(item.recommendedDdl);
    copiedIndex.value = item.indexName;
    setTimeout(() => {
      copiedIndex.value = null;
    }, 2000);
  };
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 shadow-xs">
      <div class="flex items-center justify-between border-b border-zinc-100 dark:border-zinc-800 pb-3">
        <div>
          <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">B-Tree Deduplication & Posting Lists</h3>
          <p class="text-xs text-zinc-500 mt-0.5">PostgreSQL 13+ index compression and entropy governor</p>
        </div>
        <div class="flex items-center gap-2">
          <span
            v-if="riskCount > 0"
            class="px-2 py-0.5 rounded-full text-2xs font-medium bg-amber-500/10 text-amber-600 dark:text-amber-400 border border-amber-500/20"
          >
            {{ riskCount }} Actionable
          </span>
          <span
            v-else
            class="px-2 py-0.5 rounded-full text-2xs font-medium bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border border-emerald-500/20"
          >
            Optimal
          </span>
        </div>
      </div>

      <div v-if="items.length === 0" class="py-8 text-center text-xs text-zinc-400">
        No B-Tree indexes found or audit data pending.
      </div>

      <div v-else class="divide-y divide-zinc-100 dark:divide-zinc-800 mt-3">
        <div v-for="item in items" :key="item.indexName" class="py-3">
          <div class="flex items-center justify-between text-xs">
            <div class="flex items-center gap-2">
              <span class="font-mono font-semibold text-zinc-800 dark:text-zinc-200">{{ item.indexName }}</span>
              <span class="text-2xs text-zinc-400 font-mono">({{ item.tableName }})</span>
            </div>
            <div class="flex items-center gap-2 text-2xs">
              <span class="text-zinc-500">{{ item.indexSizeMb.toFixed(1) }} MB</span>
              <span
                class="px-1.5 py-0.5 rounded font-mono"
                :class="{
                  'bg-rose-500/10 text-rose-500': item.status === 'HIGH_ENTROPY_CPU_PENALTY',
                  'bg-amber-500/10 text-amber-500': item.status === 'UNCOMPRESSED_LOW_CARDINALITY' || item.status === 'SUBOPTIMAL_FILLFACTOR',
                  'bg-emerald-500/10 text-emerald-500': item.status === 'OPTIMAL'
                }"
              >
                {{ item.status }}
              </span>
            </div>
          </div>

          <div v-if="item.recommendedDdl" class="mt-2 relative">
            <pre class="p-2 rounded bg-zinc-950 text-zinc-200 font-mono text-2xs overflow-x-auto">{{ item.recommendedDdl }}</pre>
            <button
              @click="copyDdl(item)"
              class="absolute top-1.5 right-1.5 px-2 py-0.5 rounded bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-2xs transition-colors"
            >
              {{ copiedIndex === item.indexName ? '✓ Copied' : 'Copy DDL' }}
            </button>
          </div>
        </div>
      </div>
    </div>
  </template>
  ```

- **PostgreSQL Page Checksums & Durability Integrity Card**:
  - Implement a real-time reactive card auditing cluster durability invariants (`data_checksums`, `full_page_writes`, `zero_damaged_pages`) with visual alerts for dangerous configuration drift.

  ```vue
  <!-- components/database/PageChecksumIntegrityCard.vue -->
  <script setup lang="ts">
  import { computed } from 'vue';

  export interface DurabilityAudit {
    dataChecksums: boolean;
    fullPageWrites: boolean;
    zeroDamagedPages: boolean;
    auditedAt: string;
    corruptionsDetected: number;
  }

  const props = defineProps<{
    audit: DurabilityAudit;
    isLoading?: boolean;
  }>();

  const isSafe = computed(() =>
    props.audit.fullPageWrites && !props.audit.zeroDamagedPages && props.audit.corruptionsDetected === 0
  );

  const riskLabel = computed(() => {
    if (props.audit.zeroDamagedPages) return 'CRITICAL: zero_damaged_pages is ON';
    if (!props.audit.fullPageWrites) return 'DURABILITY BREACH: full_page_writes is OFF';
    if (props.audit.corruptionsDetected > 0) return `CORRUPTIONS DETECTED: ${props.audit.corruptionsDetected} blocks`;
    if (!props.audit.dataChecksums) return 'WARNING: data_checksums is OFF';
    return 'DURABILITY VERIFIED';
  });
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <span
            class="h-2.5 w-2.5 rounded-full"
            :class="isSafe ? 'bg-emerald-500 ring-4 ring-emerald-500/20' : 'bg-rose-500 ring-4 ring-rose-500/20 animate-pulse'"
          />
          <h3 class="font-medium text-sm text-zinc-900 dark:text-zinc-100">Page Checksums & Block Integrity</h3>
        </div>
        <span
          class="text-xs px-2 py-0.5 rounded font-mono font-medium"
          :class="isSafe ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-400' : 'bg-rose-50 text-rose-700 dark:bg-rose-950/50 dark:text-rose-400'"
        >
          {{ riskLabel }}
        </span>
      </div>

      <div class="grid grid-cols-3 gap-3 text-xs mt-3">
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-1">data_checksums</div>
          <div class="font-mono font-semibold" :class="audit.dataChecksums ? 'text-emerald-600' : 'text-amber-500'">
            {{ audit.dataChecksums ? 'ENABLED (on)' : 'DISABLED (off)' }}
          </div>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-1">full_page_writes</div>
          <div class="font-mono font-semibold" :class="audit.fullPageWrites ? 'text-emerald-600' : 'text-rose-600'">
            {{ audit.fullPageWrites ? 'PROTECTED (on)' : 'VULNERABLE (off)' }}
          </div>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-1">zero_damaged_pages</div>
          <div class="font-mono font-semibold" :class="!audit.zeroDamagedPages ? 'text-emerald-600' : 'text-rose-600 animate-pulse'">
            {{ audit.zeroDamagedPages ? 'ACTIVE (DANGER!)' : 'SAFE (off)' }}
          </div>
        </div>
      </div>
    </div>
  </template>
  ```

- **PostgreSQL Wait Event & Active Session History (ASH) Dashboard Card (Vue 3 / Nuxt 3)**:
  - Implement a real-time reactive card visualizing Average Active Sessions (AAS) breakdown across CPU, IO, Lock, and Zombie sessions using `<script setup lang="ts">` and `computed()`.

  ```vue
  <!-- components/database/WaitEventAshCard.vue -->
  <script setup lang="ts">
  import { computed } from 'vue';

  export interface AshMetrics {
    cpuAas: number;
    ioAas: number;
    lockAas: number;
    lwlockAas: number;
    clientZombieAas: number;
    cpuCores: number;
  }

  const props = defineProps<{
    metrics: AshMetrics;
  }>();

  const totalAas = computed(() =>
    props.metrics.cpuAas + props.metrics.ioAas + props.metrics.lockAas + props.metrics.lwlockAas
  );

  const isCpuSaturated = computed(() => props.metrics.cpuAas > props.metrics.cpuCores * 0.8);
  const isLockContended = computed(() => props.metrics.lockAas > 1.0 && props.metrics.lockAas / (totalAas.value || 1) > 0.3);
  const hasZombies = computed(() => props.metrics.clientZombieAas > 0.5);

  const statusSeverity = computed(() => {
    if (hasZombies.value) return 'bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-400';
    if (isLockContended.value) return 'bg-rose-50 text-rose-700 dark:bg-rose-950/50 dark:text-rose-400';
    if (isCpuSaturated.value) return 'bg-orange-50 text-orange-700 dark:bg-orange-950/50 dark:text-orange-400';
    return 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-400';
  });

  const statusLabel = computed(() => {
    if (hasZombies.value) return 'ZOMBIE IDLE-IN-TX';
    if (isLockContended.value) return 'LOCK CONTENTION';
    if (isCpuSaturated.value) return 'CPU SATURATED';
    return 'HEALTHY AAS';
  });
  </script>

  <template>
    <div class="p-4 rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 shadow-xs">
      <div class="flex items-center justify-between pb-3 border-b border-zinc-100 dark:border-zinc-800/80">
        <div>
          <h3 class="font-medium text-sm text-zinc-900 dark:text-zinc-100">Wait Events & Active Session History</h3>
          <p class="text-xs text-zinc-500 font-mono mt-0.5">Total AAS: {{ totalAas.toFixed(2) }} / {{ metrics.cpuCores }} Cores</p>
        </div>
        <span class="text-xs px-2 py-0.5 rounded font-mono font-medium" :class="statusSeverity">
          {{ statusLabel }}
        </span>
      </div>

      <div class="grid grid-cols-4 gap-2 text-xs mt-3">
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50 text-center">
          <div class="text-zinc-400 text-2xs mb-0.5">CPU</div>
          <div class="font-mono font-bold" :class="isCpuSaturated ? 'text-orange-500' : 'text-zinc-800 dark:text-zinc-200'">
            {{ metrics.cpuAas.toFixed(1) }}
          </div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50 text-center">
          <div class="text-zinc-400 text-2xs mb-0.5">IO</div>
          <div class="font-mono font-bold text-sky-600 dark:text-sky-400">
            {{ metrics.ioAas.toFixed(1) }}
          </div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50 text-center">
          <div class="text-zinc-400 text-2xs mb-0.5">LOCK</div>
          <div class="font-mono font-bold" :class="isLockContended ? 'text-rose-600 animate-pulse' : 'text-zinc-800 dark:text-zinc-200'">
            {{ metrics.lockAas.toFixed(1) }}
          </div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50 text-center">
          <div class="text-zinc-400 text-2xs mb-0.5">ZOMBIE</div>
          <div class="font-mono font-bold" :class="hasZombies ? 'text-amber-600 animate-pulse' : 'text-zinc-400'">
            {{ metrics.clientZombieAas.toFixed(1) }}
          </div>
        </div>
      </div>
    </div>
  </template>
  ```

- **PostgreSQL JIT Compilation & Latency Cliff Profiler Card (Vue 3 / Nuxt 3)**:
  - Implement a real-time reactive component displaying JIT compilation timing breakdown (Generation, Inlining, Optimization, Emission) and flagging queries where LLVM compile overhead exceeds execution time.

  ```vue
  <!-- components/database/JitCompilationProfilerCard.vue -->
  <script setup lang="ts">
  import { computed } from 'vue';

  export interface JitMetrics {
    querySnippet: string;
    totalExecutionTimeMs: number;
    jitCompileTimeMs: number;
    generationMs: number;
    inliningMs: number;
    optimizationMs: number;
    emissionMs: number;
    isJitActive: boolean;
  }

  const props = defineProps<{
    metrics: JitMetrics;
  }>();

  const pureExecutionTimeMs = computed(() =>
    Math.max(0.001, props.metrics.totalExecutionTimeMs - props.metrics.jitCompileTimeMs)
  );

  const jitOverheadRatio = computed(() =>
    props.metrics.totalExecutionTimeMs > 0
      ? props.metrics.jitCompileTimeMs / props.metrics.totalExecutionTimeMs
      : 0
  );

  const isSevereCliff = computed(() => jitOverheadRatio.value >= 0.70);
  const isModerateCliff = computed(() => jitOverheadRatio.value > 0.20 && !isSevereCliff.value);

  const statusSeverity = computed(() => {
    if (isSevereCliff.value) return 'bg-rose-50 text-rose-700 dark:bg-rose-950/50 dark:text-rose-400 border-rose-200 dark:border-rose-800';
    if (isModerateCliff.value) return 'bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-400 border-amber-200 dark:border-amber-800';
    return 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-400 border-emerald-200 dark:border-emerald-800';
  });

  const statusLabel = computed(() => {
    if (isSevereCliff.value) return 'CRITICAL JIT CLIFF';
    if (isModerateCliff.value) return 'JIT OVERHEAD HIGH';
    return 'JIT BENEFICIAL';
  });
  </script>

  <template>
    <div class="p-4 rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 shadow-xs">
      <div class="flex items-center justify-between pb-3 border-b border-zinc-100 dark:border-zinc-800/80">
        <div class="truncate max-w-[70%]">
          <h3 class="font-medium text-sm text-zinc-900 dark:text-zinc-100 truncate">JIT LLVM Compilation Profile</h3>
          <p class="text-xs text-zinc-500 font-mono mt-0.5 truncate">{{ metrics.querySnippet }}</p>
        </div>
        <span class="text-xs px-2.5 py-0.5 rounded border font-mono font-medium" :class="statusSeverity">
          {{ statusLabel }}
        </span>
      </div>

      <div class="grid grid-cols-3 gap-3 my-3 text-xs">
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">TOTAL TIME</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">
            {{ metrics.totalExecutionTimeMs.toFixed(1) }}ms
          </div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">JIT COMPILE</div>
          <div class="font-mono font-bold" :class="isSevereCliff ? 'text-rose-600 dark:text-rose-400' : 'text-zinc-900 dark:text-zinc-100'">
            {{ metrics.jitCompileTimeMs.toFixed(1) }}ms ({{ (jitOverheadRatio * 100).toFixed(1) }}%)
          </div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">PURE EXEC</div>
          <div class="font-mono font-bold text-emerald-600 dark:text-emerald-400">
            {{ pureExecutionTimeMs.toFixed(1) }}ms
          </div>
        </div>
      </div>

      <!-- Compilation Phase Breakdown Bar -->
      <div class="pt-2 border-t border-zinc-100 dark:border-zinc-800/80 text-2xs text-zinc-500">
        <div class="flex justify-between font-mono mb-1">
          <span>Gen: {{ metrics.generationMs.toFixed(1) }}ms</span>
          <span>Inline: {{ metrics.inliningMs.toFixed(1) }}ms</span>
          <span>Opt: {{ metrics.optimizationMs.toFixed(1) }}ms</span>
          <span>Emit: {{ metrics.emissionMs.toFixed(1) }}ms</span>
        </div>
        <div v-if="isSevereCliff" class="mt-2 text-rose-600 dark:text-rose-400 font-mono text-xs">
          ⚠️ Action: Compile time is {{ (metrics.jitCompileTimeMs / pureExecutionTimeMs).toFixed(1) }}x pure execution! Apply "SET LOCAL jit = off;".
        </div>
      </div>
    </div>
  </template>
  ```

- **PostgreSQL Expression Index & AST Subsumption Card (Vue 3 / Nuxt Composition API)**:
  - Deliver clean micro-bordered cards auditing whether queries hit expression indexes or trigger catastrophic sequential scans.

  ```vue
  <!-- components/database/ExpressionIndexSubsumptionCard.vue -->
  <script setup lang="ts">
  import { computed } from 'vue';

  interface SubsumptionAudit {
    tableName: string;
    predicateSnippet: string;
    isSubsumed: boolean;
    planType: 'IndexScan' | 'IndexOnlyScan' | 'BitmapIndexScan' | 'SeqScan';
    indexName?: string;
    cost: number;
    executionTimeMs: number;
  }

  const props = defineProps<{
    audit: SubsumptionAudit;
  }>();

  const isSeqScan = computed(() => props.audit.planType === 'SeqScan');
  const badgeClass = computed(() => {
    if (isSeqScan.value) {
      return 'bg-rose-50 text-rose-700 border-rose-200 dark:bg-rose-950/40 dark:text-rose-400 dark:border-rose-900';
    }
    if (props.audit.planType === 'IndexOnlyScan') {
      return 'bg-emerald-50 text-emerald-700 border-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-400 dark:border-emerald-900';
    }
    return 'bg-blue-50 text-blue-700 border-blue-200 dark:bg-blue-950/40 dark:text-blue-400 dark:border-blue-900';
  });
  </script>

  <template>
    <div class="p-4 rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 shadow-xs">
      <div class="flex items-center justify-between pb-3 border-b border-zinc-100 dark:border-zinc-800/80">
        <div class="truncate max-w-[70%]">
          <h3 class="font-medium text-sm text-zinc-900 dark:text-zinc-100 truncate">AST Subsumption Audit</h3>
          <p class="text-xs text-zinc-500 font-mono mt-0.5 truncate">{{ audit.tableName }} &middot; {{ audit.predicateSnippet }}</p>
        </div>
        <span class="text-xs px-2.5 py-0.5 rounded border font-mono font-medium" :class="badgeClass">
          {{ audit.planType }}
        </span>
      </div>

      <div class="grid grid-cols-3 gap-3 my-3 text-xs">
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">SUBSUMED?</div>
          <div class="font-mono font-bold" :class="audit.isSubsumed ? 'text-emerald-600 dark:text-emerald-400' : 'text-rose-600 dark:text-rose-400'">
            {{ audit.isSubsumed ? 'YES' : 'NO (FALLBACK)' }}
          </div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">INDEX USED</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100 truncate">
            {{ audit.indexName ?? 'None (SeqScan)' }}
          </div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">EXEC TIME</div>
          <div class="font-mono font-bold" :class="isSeqScan ? 'text-rose-600 dark:text-rose-400' : 'text-emerald-600 dark:text-emerald-400'">
            {{ audit.executionTimeMs.toFixed(2) }}ms
          </div>
        </div>
      </div>

      <div v-if="isSeqScan" class="pt-2 border-t border-rose-100 dark:border-rose-900/40 text-xs text-rose-600 dark:text-rose-400 font-mono">
        ⚠️ AST Subsumption Failure: Predicate did not match expression index AST. Align type casts or deploy STORED generated column.
      </div>
    </div>
  </template>
  ```

- **Partition-Wise Join & Execution Memory Telemetry Card (Vue 3 / Nuxt 3)**:
  - Visual display of partition-wise execution metrics, temporary disk spillover, and planning latency.

  ```vue
  <!-- components/PartitionwiseJoinTelemetryCard.vue -->
  <script setup lang="ts">
  import { computed } from 'vue';

  interface PartitionwiseTelemetry {
    queryId: string;
    isPartitionwiseJoinUsed: boolean;
    isPartitionwiseAggregateUsed: boolean;
    activePartitions: number;
    tempWrittenBlocks: number;
    planningTimeMs: number;
    executionTimeMs: number;
  }

  const props = defineProps<{
    telemetry: PartitionwiseTelemetry;
  }>();

  const hasSpill = computed(() => props.telemetry.tempWrittenBlocks > 0);
  const isOptimized = computed(() => props.telemetry.isPartitionwiseJoinUsed && !hasSpill.value);
  </script>

  <template>
    <div class="rounded-lg border p-4 bg-white dark:bg-zinc-900 border-zinc-200 dark:border-zinc-800">
      <div class="flex items-center justify-between pb-3 border-b border-zinc-100 dark:border-zinc-800">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Partition-Wise Join Telemetry</h4>
          <p class="text-xs text-zinc-500 font-mono">Query: {{ telemetry.queryId }}</p>
        </div>
        <span
          class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium"
          :class="isOptimized ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-400' : 'bg-amber-50 text-amber-700 dark:bg-amber-950/60 dark:text-amber-400'"
        >
          {{ isOptimized ? 'PARTITION-WISE OPTIMIZED' : 'MONOLITHIC FALLBACK' }}
        </span>
      </div>

      <div class="grid grid-cols-4 gap-3 my-3 text-xs">
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">PARTITIONS</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ telemetry.activePartitions }}</div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">DISK SPILL</div>
          <div class="font-mono font-bold" :class="hasSpill ? 'text-rose-600 dark:text-rose-400' : 'text-emerald-600 dark:text-emerald-400'">
            {{ telemetry.tempWrittenBlocks }} blks
          </div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">PLAN TIME</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ telemetry.planningTimeMs.toFixed(1) }}ms</div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">EXEC TIME</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ telemetry.executionTimeMs.toFixed(1) }}ms</div>
        </div>
      </div>
    </div>
  </template>
  ```

- **Bloom Index & Lossless Bitmap Scan Telemetry Card (Vue 3 / Nuxt 3)**:
  - Visual display of Bloom index selectivity, exact vs lossy heap page counts, discarded recheck rows, and query execution time.

  ```vue
  <!-- components/BloomIndexTelemetryCard.vue -->
  <script setup lang="ts">
  import { computed } from 'vue';

  interface BloomTelemetry {
    indexName: string;
    tableName: string;
    signatureLength: number;
    exactHeapPages: number;
    lossyHeapPages: number;
    recheckRowsDiscarded: number;
    executionTimeMs: number;
  }

  const props = defineProps<{
    telemetry: BloomTelemetry;
  }>();

  const isLossy = computed(() => props.telemetry.lossyHeapPages > 0);
  const isHealthy = computed(() => !isLossy.value && props.telemetry.recheckRowsDiscarded < 5000);
  </script>

  <template>
    <div class="rounded-lg border p-4 bg-white dark:bg-zinc-900 border-zinc-200 dark:border-zinc-800">
      <div class="flex items-center justify-between pb-3 border-b border-zinc-100 dark:border-zinc-800">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Bloom Index Scan Telemetry</h4>
          <p class="text-xs text-zinc-500 font-mono">{{ telemetry.tableName }} ({{ telemetry.indexName }})</p>
        </div>
        <span
          class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium"
          :class="isLossy ? 'bg-rose-50 text-rose-700 dark:bg-rose-950/60 dark:text-rose-400' : isHealthy ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-400' : 'bg-amber-50 text-amber-700 dark:bg-amber-950/60 dark:text-amber-400'"
        >
          {{ isLossy ? 'LOSSY BITMAP SPILL' : isHealthy ? 'EXACT LOSSLESS SCAN' : 'HIGH COLLISION RATE' }}
        </span>
      </div>

      <div class="grid grid-cols-4 gap-3 my-3 text-xs">
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">SIGNATURE</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ telemetry.signatureLength }} bits</div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">EXACT / LOSSY</div>
          <div class="font-mono font-bold" :class="isLossy ? 'text-rose-600 dark:text-rose-400' : 'text-emerald-600 dark:text-emerald-400'">
            {{ telemetry.exactHeapPages }} / {{ telemetry.lossyHeapPages }}
          </div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">RECHECK DISCARD</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ telemetry.recheckRowsDiscarded }}</div>
        </div>
        <div class="p-2 rounded bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">EXEC TIME</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ telemetry.executionTimeMs.toFixed(1) }}ms</div>
        </div>
      </div>
    </div>
  </template>
  ```

- **Vue 3 / Nuxt Composition API HypoPG Virtual Index Advisor & Cost Inspector**:
  - Implement a real-time What-If index recommendation inspector visualizing baseline vs hypothetical planner costs, adoption status, and physical size estimates.

  ```vue
  <!-- components/database/HypoPGAdvisorResultCard.vue -->
  <script setup lang="ts">
  import { computed } from 'vue';

  interface HypoEvaluation {
    tableName: string;
    columns: string[];
    baselineCost: number;
    hypoCost: number;
    costReductionPct: number;
    estimatedSizePretty: string;
    isAdopted: boolean;
    isApproved: boolean;
    suggestedMigrationDDL?: string;
  }

  const props = defineProps<{
    evaluation: HypoEvaluation;
  }>();

  const isApproved = computed(() => props.evaluation.isApproved);
  const isAdopted = computed(() => props.evaluation.isAdopted);

  const badgeClass = computed(() => {
    if (isApproved.value) {
      return 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-400 border-emerald-200 dark:border-emerald-800';
    }
    if (!isAdopted.value) {
      return 'bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400 border-zinc-200 dark:border-zinc-700';
    }
    return 'bg-amber-50 text-amber-700 dark:bg-amber-950/60 dark:text-amber-400 border-amber-200 dark:border-amber-800';
  });

  const badgeText = computed(() => {
    if (isApproved.value) return 'APPROVED (>=60% BOOST)';
    if (!isAdopted.value) return 'REJECTED BY PLANNER';
    return 'SUB-OPTIMAL (<60%)';
  });
  </script>

  <template>
    <div class="rounded-xl border p-4 bg-white dark:bg-zinc-900 border-zinc-200 dark:border-zinc-800 shadow-xs">
      <div class="flex items-center justify-between pb-3 border-b border-zinc-100 dark:border-zinc-800">
        <div>
          <span class="text-2xs font-semibold text-zinc-400 tracking-wider uppercase">HypoPG Virtual Index</span>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 font-mono mt-0.5">
            {{ evaluation.tableName }} ({{ evaluation.columns.join(', ') }})
          </h4>
        </div>
        <span class="inline-flex items-center px-2.5 py-1 rounded-full text-xs font-semibold border" :class="badgeClass">
          {{ badgeText }}
        </span>
      </div>

      <div class="grid grid-cols-4 gap-3 my-3 text-xs">
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">BASELINE COST</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ evaluation.baselineCost.toFixed(1) }}</div>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">VIRTUAL COST</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ evaluation.hypoCost.toFixed(1) }}</div>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">COST REDUCTION</div>
          <div
            class="font-mono font-bold"
            :class="evaluation.costReductionPct >= 60 ? 'text-emerald-600 dark:text-emerald-400' : 'text-amber-600 dark:text-amber-400'"
          >
            {{ evaluation.costReductionPct.toFixed(1) }}%
          </div>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <div class="text-zinc-400 text-2xs mb-0.5">EST. FOOTPRINT</div>
          <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ evaluation.estimatedSizePretty }}</div>
        </div>
      </div>

      <div v-if="evaluation.suggestedMigrationDDL && isApproved" class="mt-3 pt-3 border-t border-zinc-100 dark:border-zinc-800">
        <div class="text-2xs font-semibold text-zinc-400 uppercase tracking-wider mb-1">Safe Online Migration</div>
        <pre class="p-2 rounded bg-zinc-900 text-zinc-200 text-2xs font-mono overflow-x-auto selection:bg-zinc-700">{{ evaluation.suggestedMigrationDDL }}</pre>
      </div>
    </div>
  </template>
  ```

- **Vue 3 Composition API: `QueryPerformanceDiffViewer.vue` (`pg_stat_statements` Differential Canary Dashboard)**:
  - Construct a production canary diff inspector in Vue 3 script setup + TypeScript.
  - Automatically compares pre- and post-deployment snapshots, flagging queries with tail latency variance ($c_v \ge 2.0$), disk spillage (`temp_blks_written > 0`), or buffer cache hit degradation ($< 98.5\%$) with zero destructive database resets.

  ```vue
  <!-- src/components/telemetry/QueryPerformanceDiffViewer.vue -->
  <script setup lang="ts">
  import { computed } from 'vue';

  export interface QueryDiffItem {
    queryId: string;
    querySnippet: string;
    deltaCalls: number;
    meanLatencyMs: number;
    stddevMs: number;
    cacheHitRatioPct: number;
    tempSpillBlocks: number;
    ioWaitPercent: number;
    isRegressed: boolean;
    defects: string[];
  }

  interface Props {
    queries: QueryDiffItem[];
    canaryTag?: string;
  }

  const props = withDefaults(defineProps<Props>(), {
    canaryTag: 'v2.4.0-canary',
  });

  const emit = defineEmits<{
    (e: 'inspect', queryId: string): void;
    (e: 'rollback'): void;
  }>();

  const regressedQueries = computed(() => props.queries.filter((q) => q.isRegressed));
  const hasRegressions = computed(() => regressedQueries.value.length > 0);
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 bg-white p-5 shadow-xs dark:border-zinc-800 dark:bg-zinc-900">
      <div class="flex items-center justify-between mb-4 pb-3 border-b border-zinc-100 dark:border-zinc-800">
        <div>
          <div class="flex items-center gap-2">
            <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">pg_stat_statements Canary Audit</h3>
            <span class="font-mono text-3xs px-2 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300">
              {{ canaryTag }}
            </span>
          </div>
          <p class="text-xs text-zinc-500 dark:text-zinc-400">Differential snapshot analysis (Zero-reset baseline preservation)</p>
        </div>

        <div class="flex items-center gap-3">
          <span
            class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium"
            :class="hasRegressions ? 'bg-rose-50 text-rose-700 dark:bg-rose-950/40 dark:text-rose-400 border border-rose-200 dark:border-rose-900' : 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-400 border border-emerald-200 dark:border-emerald-900'"
          >
            <span class="w-1.5 h-1.5 rounded-full" :class="hasRegressions ? 'bg-rose-500 animate-pulse' : 'bg-emerald-500'"></span>
            {{ hasRegressions ? `${regressedQueries.length} Regressions` : 'Baseline Verified Clean' }}
          </span>

          <button
            v-if="hasRegressions"
            type="button"
            @click="emit('rollback')"
            class="px-3 py-1 text-xs font-semibold rounded bg-rose-600 hover:bg-rose-700 text-white shadow-xs transition-colors"
          >
            Trigger Rollback
          </button>
        </div>
      </div>

      <div class="space-y-3">
        <div
          v-for="item in queries"
          :key="item.queryId"
          class="p-3.5 rounded-lg border transition-colors"
          :class="item.isRegressed ? 'border-rose-200 bg-rose-50/30 dark:border-rose-900/50 dark:bg-rose-950/20' : 'border-zinc-100 bg-zinc-50/50 dark:border-zinc-800 dark:bg-zinc-800/30'"
        >
          <div class="flex items-start justify-between gap-3 mb-2">
            <div class="flex items-center gap-2">
              <span class="font-mono text-3xs font-medium px-1.5 py-0.5 rounded bg-zinc-200/70 dark:bg-zinc-700/60 text-zinc-700 dark:text-zinc-300">
                {{ item.queryId.slice(0, 8) }}
              </span>
              <span
                v-for="defect in item.defects"
                :key="defect"
                class="px-1.5 py-0.5 rounded text-3xs font-medium bg-rose-100 text-rose-800 dark:bg-rose-950/80 dark:text-rose-300"
              >
                {{ defect }}
              </span>
            </div>
            <button
              type="button"
              @click="emit('inspect', item.queryId)"
              class="text-2xs font-medium text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100"
            >
              EXPLAIN (BUFFERS)
            </button>
          </div>

          <code class="block font-mono text-2xs text-zinc-700 dark:text-zinc-300 truncate mb-3">
            {{ item.querySnippet }}
          </code>

          <div class="grid grid-cols-4 gap-2 text-center text-xs">
            <div class="p-2 rounded bg-white dark:bg-zinc-900/60 border border-zinc-100 dark:border-zinc-800">
              <div class="text-3xs text-zinc-400">MEAN LATENCY</div>
              <div class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ item.meanLatencyMs.toFixed(1) }}ms</div>
            </div>
            <div class="p-2 rounded bg-white dark:bg-zinc-900/60 border border-zinc-100 dark:border-zinc-800">
              <div class="text-3xs text-zinc-400">STDDEV (c_v)</div>
              <div
                class="font-mono font-bold"
                :class="(item.stddevMs / (item.meanLatencyMs || 1)) >= 2.0 ? 'text-amber-600 dark:text-amber-400' : 'text-zinc-700 dark:text-zinc-300'"
              >
                {{ (item.stddevMs / (item.meanLatencyMs || 1)).toFixed(2) }}
              </div>
            </div>
            <div class="p-2 rounded bg-white dark:bg-zinc-900/60 border border-zinc-100 dark:border-zinc-800">
              <div class="text-3xs text-zinc-400">CACHE HIT RATIO</div>
              <div
                class="font-mono font-bold"
                :class="item.cacheHitRatioPct < 98.5 ? 'text-indigo-600 dark:text-indigo-400' : 'text-zinc-700 dark:text-zinc-300'"
              >
                {{ item.cacheHitRatioPct.toFixed(1) }}%
              </div>
            </div>
            <div class="p-2 rounded bg-white dark:bg-zinc-900/60 border border-zinc-100 dark:border-zinc-800">
              <div class="text-3xs text-zinc-400">DELTA CALLS</div>
              <div class="font-mono font-bold text-zinc-700 dark:text-zinc-300">{{ item.deltaCalls.toLocaleString() }}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </template>
  ```

- **Vue 3 Composition API: `AutoExplainPlanVisualizer.vue` (Plan AST Tree & Anomaly Inspector)**:
  - Deliver a production execution plan visualizer in Vue 3 script setup + TypeScript.
  - Recursively highlights plan nodes with high cardinality error ratios ($\mathcal{E}_{\text{card}} \ge 10.0$), temp disk spills, and high physical read counts without unnecessary DOM thrashing.

  ```vue
  <!-- src/components/telemetry/AutoExplainPlanVisualizer.vue -->
  <script setup lang="ts">
  import { ref, computed } from 'vue';

  export interface PlanNodeData {
    'Node Type': string;
    'Relation Name'?: string;
    'Plan Rows': number;
    'Actual Rows'?: number;
    'Actual Loops'?: number;
    'Actual Total Time'?: number;
    'Shared Hit Blocks'?: number;
    'Shared Read Blocks'?: number;
    'Temp Written Blocks'?: number;
    Plans?: PlanNodeData[];
  }

  interface Props {
    queryText: string;
    rootPlan: PlanNodeData;
    executionTimeMs?: number;
  }

  const props = defineProps<Props>();

  const collapsedPaths = ref<Record<string, boolean>>({});

  function toggleCollapse(path: string) {
    collapsedPaths.value[path] = !collapsedPaths.value[path];
  }

  function getCardinalityRatio(node: PlanNodeData) {
    const act = (node['Actual Rows'] ?? 0) * (node['Actual Loops'] ?? 1);
    const est = Math.max(1, node['Plan Rows']);
    const ratio = act >= est ? act / est : est / Math.max(1, act);
    return {
      ratio,
      isSevere: ratio >= 10.0 && act > 50,
      actualTotal: act,
    };
  }
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 bg-white p-5 shadow-xs dark:border-zinc-800 dark:bg-zinc-900">
      <div class="flex items-center justify-between pb-3 border-b border-zinc-100 dark:border-zinc-800 mb-4">
        <div>
          <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Execution Plan Tree (auto_explain AST)</h3>
          <p class="text-xs text-zinc-500 dark:text-zinc-400">Zero-timing-overhead execution tree diagnostics</p>
        </div>
        <span v-if="executionTimeMs" class="font-mono text-xs px-2.5 py-1 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300 font-medium">
          {{ executionTimeMs.toFixed(2) }} ms
        </span>
      </div>

      <code class="block font-mono text-2xs p-2.5 rounded bg-zinc-50 dark:bg-zinc-950/60 border border-zinc-200/60 dark:border-zinc-800 text-zinc-700 dark:text-zinc-300 truncate mb-4">
        {{ queryText }}
      </code>

      <div class="space-y-1">
        <!-- Root node presentation -->
        <div class="p-3 rounded-lg border border-zinc-100 bg-zinc-50/50 dark:border-zinc-800 dark:bg-zinc-800/30">
          <div class="flex items-center justify-between text-xs">
            <span class="font-mono font-bold text-zinc-900 dark:text-zinc-100">{{ rootPlan['Node Type'] }}</span>
            <span class="font-mono text-3xs text-zinc-500 dark:text-zinc-400">
              Est: {{ Math.round(rootPlan['Plan Rows']).toLocaleString() }} rows
            </span>
          </div>
        </div>
      </div>
    </div>
  </template>
  ```

- **Vue 3.5 Reactive Props Destructuring for Database Storage Telemetry (`pg_stat_io`)**:
  - ✅ **Production Invariant**: Leverage Vue 3.5's reactive props destructure and `computed` to evaluate storage health and synchronous write anomalies without boilerplate:
  ```vue
  <script setup lang="ts">
  import { computed } from 'vue';

  interface IoRow {
    backend_type: string;
    target: string;
    context: string;
    deltaWrites: number;
    deltaReads: number;
  }

  // Vue 3.5 native reactive props destructuring with defaults
  const { metrics = [], windowSeconds = 60 } = defineProps<{
    metrics?: IoRow[];
    windowSeconds?: number;
  }>();

  const clientDirtyWrites = computed(() =>
    metrics
      .filter((m) => m.backend_type === 'client backend' && m.context === 'normal')
      .reduce((acc, m) => acc + m.deltaWrites, 0)
  );

  const tempSpillBlocks = computed(() =>
    metrics
      .filter((m) => m.target === 'temp relation')
      .reduce((acc, m) => acc + m.deltaWrites, 0)
  );

  const storageHealthScore = computed(() =>
    Math.max(0, 100 - clientDirtyWrites.value * 2 - tempSpillBlocks.value)
  );
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 space-y-3">
      <div class="flex items-center justify-between">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Storage Subsystem (pg_stat_io)</h4>
          <span class="text-xs text-zinc-500">Window: {{ windowSeconds }}s</span>
        </div>
        <span
          class="font-mono text-xs px-2.5 py-1 rounded-full font-semibold"
          :class="storageHealthScore >= 90 ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-400' : 'bg-rose-50 text-rose-700 dark:bg-rose-950 dark:text-rose-400'"
        >
          Score: {{ storageHealthScore }}/100
        </span>
      </div>

      <div v-if="clientDirtyWrites > 0 || tempSpillBlocks > 0" class="p-3 rounded-lg bg-rose-50 dark:bg-rose-950/40 text-xs text-rose-700 dark:text-rose-300 space-y-1">
        <p v-if="clientDirtyWrites > 0" class="font-medium">
          CRITICAL: {{ clientDirtyWrites }} synchronous client dirty writes! Tune bgwriter_lru_maxpages.
        </p>
        <p v-if="tempSpillBlocks > 0">
          HIGH: {{ tempSpillBlocks }} temp relation disk spill blocks! Elevate work_mem.
        </p>
      </div>
    </div>
  </template>
  ```

- **Vue 3.5 Reactive Props Destructuring for Query Anti-Join & Semi-Join Telemetry**:
  - ✅ **Production Invariant**: Leverage Vue 3.5's reactive props destructure and `computed` to evaluate query anti-join / semi-join compliance and 3VL risk:
  ```vue
  <script setup lang="ts">
  import { computed } from 'vue';

  interface PlanNodeSummary {
    nodeType: string;
    hasSubPlan: boolean;
  }

  // Vue 3.5 native reactive props destructuring with defaults
  const { queryText = '', planNodes = [] } = defineProps<{
    queryText?: string;
    planNodes?: PlanNodeSummary[];
  }>();

  const hasNotInHazard = computed(() => /\bNOT\s+IN\s*\(\s*SELECT\b/i.test(queryText));
  const hasJoinDistinct = computed(() => /\bSELECT\s+DISTINCT\b[\s\S]+?\bJOIN\b/i.test(queryText));
  const hasSubPlanLoop = computed(() => planNodes.some((n) => n.hasSubPlan || n.nodeType.includes('SubPlan')));

  const optimizationScore = computed(() => {
    let score = 100;
    if (hasNotInHazard.value) score -= 50;
    if (hasSubPlanLoop.value) score -= 30;
    if (hasJoinDistinct.value) score -= 20;
    return Math.max(0, score);
  });
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 space-y-3">
      <div class="flex items-center justify-between">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Anti-Join / Semi-Join Optimizer Sentinel</h4>
          <span class="text-xs text-zinc-500">Plan Unnesting & 3VL Defense</span>
        </div>
        <span
          class="font-mono text-xs px-2.5 py-1 rounded-full font-semibold"
          :class="optimizationScore >= 90 ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-400' : 'bg-rose-50 text-rose-700 dark:bg-rose-950 dark:text-rose-400'"
        >
          Score: {{ optimizationScore }}/100
        </span>
      </div>

      <div v-if="hasNotInHazard || hasSubPlanLoop || hasJoinDistinct" class="p-3 rounded-lg bg-rose-50 dark:bg-rose-950/40 text-xs text-rose-700 dark:text-rose-300 space-y-1">
        <p v-if="hasNotInHazard" class="font-medium">
          CRITICAL: NOT IN (SELECT ...) detected. NULL inner values will drop all results. Rewrite to NOT EXISTS.
        </p>
        <p v-if="hasSubPlanLoop">
          HIGH: Plan contains unnested SubPlan loop! Quadratic execution risk.
        </p>
        <p v-if="hasJoinDistinct">
          WARN: SELECT DISTINCT with JOIN detected. Use WHERE EXISTS for early termination.
        </p>
      </div>
      <div v-else class="p-3 rounded-lg bg-emerald-50 dark:bg-emerald-950/40 text-xs text-emerald-700 dark:text-emerald-300">
        ✓ Query verified: 2VL compliant with Hash Anti/Semi-Join execution plan.
      </div>
    </div>
  </template>
  ```

- **Vue 3.5 Reactive Destructuring for Table Compaction (`pg_repack`) Headroom Audit**:
  - ✅ **Production Invariant**: Use Vue 3.5 reactive props destructuring and computed properties to evaluate compaction prerequisites, primary keys, and 2.2x free space:
  ```vue
  <script setup lang="ts">
  import { computed } from 'vue';

  // Vue 3.5 reactive props destructuring
  const {
    tableName = '',
    tableSizeBytes = 0,
    availableDiskBytes = 0,
    hasPrimaryKey = false,
    orphanTriggers = 0,
    standbyLagSeconds = 0,
  } = defineProps<{
    tableName?: string;
    tableSizeBytes?: number;
    availableDiskBytes?: number;
    hasPrimaryKey?: boolean;
    orphanTriggers?: number;
    standbyLagSeconds?: number;
  }>();

  const requiredDiskBytes = computed(() => Math.ceil(tableSizeBytes * 2.2));
  const hasDiskHeadroom = computed(() => availableDiskBytes >= requiredDiskBytes.value);
  const isLagAcceptable = computed(() => standbyLagSeconds <= 30);
  const isTriggerClean = computed(() => orphanTriggers === 0);

  const canExecuteRepack = computed(() =>
    hasPrimaryKey && hasDiskHeadroom.value && isLagAcceptable.value && isTriggerClean.value
  );

  const commandPreview = computed(() =>
    canExecuteRepack.value
      ? `pg_repack --table="${tableName}" --wait-timeout=2 --no-kill-backend --no-order`
      : null
  );
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">PostgreSQL Bloat Compaction Sentinel</h4>
          <span class="text-xs text-zinc-500">pg_repack 2.2x Disk & Lock Queue Defense</span>
        </div>
        <span
          class="px-2.5 py-1 rounded-full text-xs font-medium"
          :class="canExecuteRepack ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-400' : 'bg-rose-100 text-rose-800 dark:bg-rose-950/60 dark:text-rose-400'"
        >
          {{ canExecuteRepack ? 'Safe to Compact' : 'Compaction Guard Blocked' }}
        </span>
      </div>
      <div v-if="!canExecuteRepack" class="p-3 rounded-lg bg-rose-50 dark:bg-rose-950/40 text-xs text-rose-700 dark:text-rose-300 space-y-1">
        <p v-if="!hasPrimaryKey">CRITICAL: Table lacks PRIMARY KEY or UNIQUE NOT NULL constraint.</p>
        <p v-if="!hasDiskHeadroom">CRITICAL: Insufficient disk space for 2.2x repack shadow table.</p>
        <p v-if="!isTriggerClean">HIGH: Orphaned repack triggers detected. Run pg_repack --clean.</p>
        <p v-if="!isLagAcceptable">WARN: Standby replication lag exceeds 30s threshold.</p>
      </div>
    </div>
  </template>
  ```

- **Vue 3.5+ Reactivity Invariant: Hash Join Multi-Batch Spill & Memory Monitor**:
  - Deploy `<script setup lang="ts">` with reactive prop destructuring to visualize PostgreSQL Hash Join execution nodes, surfacing single-batch status and memory spillage:
  ```vue
  <script setup lang="ts">
  import { computed } from 'vue';

  const {
    queryTitle = 'Analytics Hash Join',
    hashBatches = 1,
    tempWrittenBlocks = 0,
    peakMemoryKB = 0,
    allocatedWorkMemMB = 64,
  } = defineProps<{
    queryTitle?: string;
    hashBatches?: number;
    tempWrittenBlocks?: number;
    peakMemoryKB?: number;
    allocatedWorkMemMB?: number;
  }>();

  const isSingleBatch = computed(() => hashBatches === 1 && tempWrittenBlocks === 0);
  const memoryUsedMB = computed(() => (peakMemoryKB / 1024).toFixed(1));
  const spilledMB = computed(() => ((tempWrittenBlocks * 8) / 1024).toFixed(1));
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{{ queryTitle }}</h4>
          <span class="text-xs text-zinc-500">PostgreSQL Hash Join Memory & Batch Monitor</span>
        </div>
        <span
          class="px-2.5 py-1 rounded-full text-xs font-medium"
          :class="isSingleBatch ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-400' : 'bg-rose-100 text-rose-800 dark:bg-rose-950/60 dark:text-rose-400'"
        >
          {{ isSingleBatch ? 'In-Memory (Single Batch)' : `Multi-Batch Spill (${hashBatches} Batches)` }}
        </span>
      </div>

      <div class="grid grid-cols-3 gap-3 text-xs">
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Peak Memory:</span>
          <span class="block font-mono font-medium text-zinc-900 dark:text-zinc-100">{{ memoryUsedMB }} MB / {{ allocatedWorkMemMB }} MB</span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Hash Batches:</span>
          <span class="block font-mono font-medium" :class="hashBatches === 1 ? 'text-zinc-900 dark:text-zinc-100' : 'text-rose-600'">{{ hashBatches }}</span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Temp Disk Spill:</span>
          <span class="block font-mono font-medium" :class="tempWrittenBlocks === 0 ? 'text-emerald-600' : 'text-rose-600'">{{ spilledMB }} MB</span>
        </div>
      </div>
    </div>
  </template>
  ```

- **Vue 3.5+ Reactivity Invariant: Merge Join Sort Spill & Presorted Scan Sentinel**:
  - Deploy `<script setup lang="ts">` with reactive prop destructuring to monitor PostgreSQL Merge Join nodes, differentiating presorted B-Tree index scans from external merge disk spills:
  ```vue
  <script setup lang="ts">
  import { computed } from 'vue';

  const {
    queryTitle = 'Ordered Merge Join',
    hasMergeJoin = true,
    presortedScans = true,
    sortMethod = '',
    tempWrittenBlocks = 0,
    maxSortSpaceKB = 0,
    allocatedWorkMemMB = 64,
  } = defineProps<{
    queryTitle?: string;
    hasMergeJoin?: boolean;
    presortedScans?: boolean;
    sortMethod?: string;
    tempWrittenBlocks?: number;
    maxSortSpaceKB?: number;
    allocatedWorkMemMB?: number;
  }>();

  const isDiskSpill = computed(() => sortMethod.includes('external merge') || tempWrittenBlocks > 0);
  const sortSpaceMB = computed(() => (maxSortSpaceKB / 1024).toFixed(1));
  const spilledMB = computed(() => ((tempWrittenBlocks * 8) / 1024).toFixed(1));
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{{ queryTitle }}</h4>
          <span class="text-xs text-zinc-500">PostgreSQL Merge Join Presort & Spill Monitor</span>
        </div>
        <span
          class="px-2.5 py-1 rounded-full text-xs font-medium"
          :class="presortedScans ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-400' : isDiskSpill ? 'bg-rose-100 text-rose-800 dark:bg-rose-950/60 dark:text-rose-400' : 'bg-amber-100 text-amber-800 dark:bg-amber-950/60 dark:text-amber-400'"
        >
          {{ presortedScans ? 'Presorted Index Scan' : isDiskSpill ? 'Disk Sort Spill' : 'In-Memory Sort' }}
        </span>
      </div>

      <div class="grid grid-cols-3 gap-3 text-xs">
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Sort Method:</span>
          <span class="block font-mono font-medium text-zinc-900 dark:text-zinc-100">{{ presortedScans ? 'None (Presorted)' : sortMethod || 'quicksort' }}</span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Sort Space Used:</span>
          <span class="block font-mono font-medium text-zinc-900 dark:text-zinc-100">{{ sortSpaceMB }} MB / {{ allocatedWorkMemMB }} MB</span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Temp Disk Spill:</span>
          <span class="block font-mono font-medium" :class="!isDiskSpill ? 'text-emerald-600' : 'text-rose-600'">{{ spilledMB }} MB</span>
        </div>
      </div>
    </div>
  </template>
  ```

- **Vue 3.5+ Reactivity Invariant: Nested Loop Join Cartesian & Index Probe Sentinel**:
  - Deploy `<script setup lang="ts">` with reactive prop destructuring to monitor PostgreSQL Nested Loop execution, warning against unindexed inner sequential scans and cardinality estimation divergence:
  ```vue
  <script setup lang="ts">
  import { computed } from 'vue';

  const {
    queryTitle = 'Transactional Point Join',
    hasNestedLoop = true,
    innerSeqScan = false,
    actualLoops = 1,
    estimatedRows = 1,
    actualRows = 1,
    tempWrittenBlocks = 0,
  } = defineProps<{
    queryTitle?: string;
    hasNestedLoop?: boolean;
    innerSeqScan?: boolean;
    actualLoops?: number;
    estimatedRows?: number;
    actualRows?: number;
    tempWrittenBlocks?: number;
  }>();

  const divergenceRatio = computed(() => {
    const est = Math.max(estimatedRows, 1);
    const act = Math.max(actualRows, 1);
    return act > est ? (act / est).toFixed(1) : (est / act).toFixed(1);
  });
  const hasDivergence = computed(() => parseFloat(divergenceRatio.value) > 5.0);
  const isCartesianRisk = computed(() => innerSeqScan && actualLoops > 1);
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{{ queryTitle }}</h4>
          <span class="text-xs text-zinc-500">PostgreSQL Nested Loop Join Monitor</span>
        </div>
        <span
          class="px-2.5 py-1 rounded-full text-xs font-medium"
          :class="!isCartesianRisk ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-400' : 'bg-rose-100 text-rose-800 dark:bg-rose-950/60 dark:text-rose-400'"
        >
          {{ !isCartesianRisk ? 'Parameterized Index Probe' : 'Cartesian Inner Seq Scan' }}
        </span>
      </div>

      <div class="grid grid-cols-3 gap-3 text-xs">
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Inner Scan Mode:</span>
          <span class="block font-mono font-medium text-zinc-900 dark:text-zinc-100">{{ !innerSeqScan ? 'Index Scan' : 'Seq Scan' }}</span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Actual Loops:</span>
          <span class="block font-mono font-medium text-zinc-900 dark:text-zinc-100">{{ actualLoops.toLocaleString() }}</span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Cardinality Divergence:</span>
          <span class="block font-mono font-medium" :class="!hasDivergence ? 'text-zinc-900 dark:text-zinc-100' : 'text-amber-600'">{{ divergenceRatio }}x</span>
        </div>
      </div>
    </div>
  </template>
  ```

- **PostgreSQL Bitmap Scan Lossy Degradation Monitor (Vue 3 / Nuxt 3)**:
  - ❌ **Anti-Pattern**: Failing to observe lossy degradation in real-time APM interfaces, masking index recheck CPU stalls as unexplained query latency.
  - ✅ **Production Invariant**: Implement Vue 3 Composition API reactive components displaying exact vs lossy heap block ratios and discarded recheck rows:
  ```vue
  <script setup lang="ts">
  import { computed } from 'vue';

  const props = withDefaults(defineProps<{
    queryTitle?: string;
    exactBlocks?: number;
    lossyBlocks?: number;
    recheckRows?: number;
    isLimitSortTrap?: boolean;
  }>(), {
    queryTitle: 'Filtered Query',
    exactBlocks: 0,
    lossyBlocks: 0,
    recheckRows: 0,
    isLimitSortTrap: false,
  });

  const isLossy = computed(() => props.lossyBlocks > 0 || props.recheckRows > 0);
  const totalBlocks = computed(() => props.exactBlocks + props.lossyBlocks);
  const exactPercentage = computed(() =>
    totalBlocks.value > 0 ? ((props.exactBlocks / totalBlocks.value) * 100).toFixed(1) : '100.0'
  );
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{{ queryTitle }}</h4>
          <span class="text-xs text-zinc-500">PostgreSQL Bitmap Scan Lossy Monitor</span>
        </div>
        <span
          class="px-2.5 py-1 rounded-full text-xs font-medium"
          :class="!isLossy ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-400' : 'bg-rose-100 text-rose-800 dark:bg-rose-950/60 dark:text-rose-400'"
        >
          {{ !isLossy ? 'Exact TIDBitmap (lossy=0)' : `Lossy Degradation (${lossyBlocks.toLocaleString()} blks)` }}
        </span>
      </div>

      <div class="grid grid-cols-3 gap-3 text-xs">
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Exact Ratio:</span>
          <span class="block font-mono font-medium" :class="!isLossy ? 'text-zinc-900 dark:text-zinc-100' : 'text-rose-600'">{{ exactPercentage }}%</span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Recheck Discards:</span>
          <span class="block font-mono font-medium" :class="recheckRows === 0 ? 'text-zinc-900 dark:text-zinc-100' : 'text-rose-600'">{{ recheckRows.toLocaleString() }}</span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">LIMIT / Sort Risk:</span>
          <span class="block font-mono font-medium" :class="!isLimitSortTrap ? 'text-emerald-600' : 'text-amber-600'">{{ !isLimitSortTrap ? 'Optimal Scan' : 'Full Scan Trap' }}</span>
        </div>
      </div>
    </div>
  </template>
  ```

- **PostgreSQL Aggregation Spill & Streaming Monitor (Vue 3 / Nuxt 3)**:
  - ❌ **Anti-Pattern**: Failing to observe HashAggregate disk spilling batches in real-time APM telemetry, masking heavy NVMe write stalls behind generic database slow queries.
  - ✅ **Production Invariant**: Implement Vue 3 Composition API reactive components displaying HashAggregate batches, memory vs disk usage, and GroupAggregate streaming compliance:
  ```vue
  <script setup lang="ts">
  import { computed } from 'vue';

  const props = withDefaults(defineProps<{
    queryTitle?: string;
    strategy?: 'Hashed' | 'Sorted' | 'Plain';
    batches?: number;
    diskUsageKb?: number;
    memoryUsageKb?: number;
    hasSortDiskSpill?: boolean;
    isLimitTrap?: boolean;
  }>(), {
    queryTitle: 'Group Query',
    strategy: 'Hashed',
    batches: 1,
    diskUsageKb: 0,
    memoryUsageKb: 0,
    hasSortDiskSpill: false,
    isLimitTrap: false,
  });

  const isSpilling = computed(() => props.batches > 1 || props.diskUsageKb > 0 || props.hasSortDiskSpill);
  const memoryDisplayMb = computed(() => (props.memoryUsageKb / 1024).toFixed(1));
  const diskDisplayMb = computed(() => (props.diskUsageKb / 1024).toFixed(1));
  </script>

  <template>
    <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5 space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{{ queryTitle }}</h4>
          <span class="text-xs text-zinc-500">PostgreSQL Aggregation Monitor ({{ strategy }})</span>
        </div>
        <span
          class="px-2.5 py-1 rounded-full text-xs font-medium"
          :class="!isSpilling ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-400' : 'bg-rose-100 text-rose-800 dark:bg-rose-950/60 dark:text-rose-400'"
        >
          {{ !isSpilling ? 'Zero Spill (Batches: 1)' : `Disk Spill (${diskDisplayMb} MB)` }}
        </span>
      </div>

      <div class="grid grid-cols-3 gap-3 text-xs">
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Batches / Mode:</span>
          <span class="block font-mono font-medium" :class="!isSpilling ? 'text-zinc-900 dark:text-zinc-100' : 'text-rose-600'">
            {{ batches }} {{ batches === 1 ? '(In-Memory)' : '(Multi-Batch)' }}
          </span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">RAM / Disk:</span>
          <span class="block font-mono font-medium" :class="diskUsageKb === 0 ? 'text-zinc-900 dark:text-zinc-100' : 'text-rose-600'">
            {{ memoryDisplayMb }}MB / {{ diskDisplayMb }}MB
          </span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Streaming Status:</span>
          <span class="block font-mono font-medium" :class="!isLimitTrap ? 'text-emerald-600' : 'text-amber-600'">
            {{ !isLimitTrap ? (strategy === 'Sorted' ? 'Pipelined O(1)' : 'In-Memory') : 'Blocking Full Hash' }}
          </span>
        </div>
      </div>
    </div>
  </template>
  ```

- **PostgreSQL Sort & Incremental Sort Disk Spill Monitor (Vue 3 / Nuxt 3)**:
  - ❌ **Anti-Pattern**: Omitting sort execution telemetry in administrative consoles, allowing multi-gigabyte external merge sort disk thrashing to go undetected.
  - ✅ **Production Invariant**: Implement Vue 3 Composition API reactive components displaying sort space allocation, quicksort vs heapsort status, and incremental sort health:
  ```vue
  <script setup lang="ts">
  import { computed } from 'vue';

  const props = withDefaults(defineProps<{
    queryTitle?: string;
    sortMethod?: string;
    sortSpaceType?: 'Memory' | 'Disk';
    sortSpaceUsedKb?: number;
    isIncrementalSort?: boolean;
    isTopNPreserved?: boolean;
  }>(), {
    queryTitle: 'Ordered Query',
    sortMethod: 'quicksort',
    sortSpaceType: 'Memory',
    sortSpaceUsedKb: 0,
    isIncrementalSort: false,
    isTopNPreserved: false,
  });

  const isSpill = computed(() => props.sortSpaceType === 'Disk' || props.sortMethod.includes('external merge'));
  const sortSpaceMb = computed(() => (props.sortSpaceUsedKb / 1024).toFixed(1));
  </script>

  <template>
    <div class="p-4 rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 shadow-sm space-y-3">
      <div class="flex items-center justify-between">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{{ queryTitle }}</h4>
          <span class="text-xs text-zinc-500">PostgreSQL Sort Monitor ({{ isIncrementalSort ? 'Incremental Sort' : sortMethod }})</span>
        </div>
        <span
          class="px-2.5 py-1 rounded-full text-xs font-medium"
          :class="!isSpill ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-400' : 'bg-rose-100 text-rose-800 dark:bg-rose-950/60 dark:text-rose-400'"
        >
          {{ !isSpill ? (isTopNPreserved ? 'Top-N Heapsort (O(K))' : 'In-Memory (Zero Spill)') : `External Merge Spill (${sortSpaceMb} MB)` }}
        </span>
      </div>

      <div class="grid grid-cols-3 gap-3 text-xs">
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Method:</span>
          <span class="block font-mono font-medium text-zinc-900 dark:text-zinc-100 truncate">{{ sortMethod }}</span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Storage / Space:</span>
          <span class="block font-mono font-medium" :class="!isSpill ? 'text-zinc-900 dark:text-zinc-100' : 'text-rose-600'">
            {{ sortSpaceType }} ({{ sortSpaceMb }} MB)
          </span>
        </div>
        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-zinc-500">Optimization Mode:</span>
          <span class="block font-mono font-medium text-emerald-600">
            {{ isIncrementalSort ? 'Incremental Prefix Groups' : isTopNPreserved ? 'Bounded Priority Queue' : 'Full In-Memory Sort' }}
          </span>
        </div>
      </div>
    </div>
  </template>
  ```

- **PostgreSQL Query Cancellation & Zombie Backend Monitor (Vue 3 / Nuxt 3)**:
  - ❌ **Anti-Pattern**: Omitting real-time visibility into orphaned database sessions and transaction-lock holds, letting aborted `25P02` connections silently starve worker pools.
  - ✅ **Production Invariant**: Implement Vue 3 Composition API reactive components displaying zombie backends, active vs aborted states, and providing non-destructive `pg_cancel_backend` controls:
  ```vue
  <script setup lang="ts">
  import { computed } from 'vue';

  interface SessionRecord {
    pid: number;
    usename: string;
    applicationName: string;
    state: 'active' | 'idle' | 'idle in transaction' | 'idle in transaction (aborted)';
    durationMs: number;
    query: string;
  }

  const props = withDefaults(defineProps<{
    sessions?: SessionRecord[];
    statementTimeoutMs?: number;
  }>(), {
    sessions: () => [],
    statementTimeoutMs: 10000,
  });

  const emit = defineEmits<{
    (e: 'cancelBackend', pid: number): void;
    (e: 'terminateBackend', pid: number): void;
  }>();

  const abortedSessions = computed(() =>
    props.sessions.filter((s) => s.state === 'idle in transaction (aborted)')
  );

  const runawaySessions = computed(() =>
    props.sessions.filter((s) => s.state === 'active' && s.durationMs > props.statementTimeoutMs)
  );

  const hasZombies = computed(() => abortedSessions.value.length > 0 || runawaySessions.value.length > 0);
  </script>

  <template>
    <div class="p-4 rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 shadow-sm space-y-3">
      <div class="flex items-center justify-between">
        <div>
          <h4 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">PostgreSQL Backend Sentinel</h4>
          <span class="text-xs text-zinc-500">{{ sessions.length }} active backend sessions</span>
        </div>
        <span
          class="px-2.5 py-1 rounded-full text-xs font-medium"
          :class="!hasZombies ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-400' : 'bg-rose-100 text-rose-800 dark:bg-rose-950/60 dark:text-rose-400'"
        >
          {{ !hasZombies ? 'Zero Zombie Backends' : `${abortedSessions.length} Aborted (25P02), ${runawaySessions.length} Runaway` }}
        </span>
      </div>

      <div class="space-y-2">
        <template v-for="session in sessions" :key="session.pid">
          <div
            v-if="session.state === 'idle in transaction (aborted)' || (session.state === 'active' && session.durationMs > statementTimeoutMs)"
            class="flex items-center justify-between p-2.5 rounded-lg border border-rose-200 dark:border-rose-900/50 bg-rose-50/50 dark:bg-rose-950/20 text-xs"
          >
            <div class="space-y-1 truncate pr-3">
              <div class="flex items-center gap-2">
                <span class="font-mono font-semibold text-rose-700 dark:text-rose-400">PID {{ session.pid }}</span>
                <span class="px-1.5 py-0.5 rounded text-[10px] bg-rose-200 dark:bg-rose-900 text-rose-800 dark:text-rose-200 font-medium">
                  {{ session.state === 'idle in transaction (aborted)' ? 'ABORTED TX (25P02)' : `${(session.durationMs / 1000).toFixed(1)}s RUNAWAY` }}
                </span>
                <span class="text-zinc-500">[{{ session.applicationName || 'client' }}]</span>
              </div>
              <p class="font-mono text-zinc-600 dark:text-zinc-400 truncate">{{ session.query }}</p>
            </div>
            <div class="flex gap-1.5 shrink-0">
              <button
                @click="emit('cancelBackend', session.pid)"
                class="px-2 py-1 rounded bg-zinc-200 hover:bg-zinc-300 dark:bg-zinc-800 dark:hover:bg-zinc-700 text-zinc-800 dark:text-zinc-200 font-medium transition"
              >
                SIGINT Cancel
              </button>
              <button
                @click="emit('terminateBackend', session.pid)"
                class="px-2 py-1 rounded bg-rose-600 hover:bg-rose-700 text-white font-medium transition"
              >
                Terminate
              </button>
            </div>
          </div>
        </template>
      </div>
    </div>
  </template>
  ```

- **Nuxt 3 Server Routes & Database SubPlan Decorrelation Invariants (/server/api)**:
  - ❌ **Anti-Pattern: Correlated SubPlans in Nitro Event Handlers**:
    - Writing raw SQL queries inside `defineEventHandler` endpoints that embed correlated scalar subqueries in `SELECT` projections (`(SELECT count(*) FROM comments WHERE post_id = p.id)`). This forces PostgreSQL to evaluate a `SubPlan` for every item in the response list, increasing API response times from 15ms to 10+ seconds and exhausting Nitro worker concurrency.
    - Using `(SELECT count(*) FROM tags WHERE entity_id = e.id) > 0` instead of `EXISTS (SELECT 1 ...)`.
  - ✅ **Production Invariant**:
    - Always pre-aggregate child statistics in dedicated CTEs and join them via `LEFT JOIN`, or use window functions.
    - Enforce single-pass hash execution with zero `SubPlan` nodes, keeping API response latency under 25ms.
  ```typescript
  // server/api/users/summaries.get.ts
  import { defineEventHandler, getQuery, createError } from 'h3';
  import { db } from '~/server/utils/db';
  import { sql } from 'kysely';

  export default defineEventHandler(async (event) => {
    const query = getQuery(event);
    const tenantId = (event.context.tenantId as string) || (query.tenantId as string);

    if (!tenantId) {
      throw createError({ statusCode: 400, message: 'Missing tenantId' });
    }

    // INVARIANT: Pre-aggregate order stats via CTE and join via LEFT JOIN.
    // Compiles to a single Hash Aggregate + Hash Join with 0 SubPlans in EXPLAIN.
    const summaries = await db
      .with('order_stats', (db) =>
        db
          .selectFrom('orders')
          .select([
            'user_id',
            db.fn.count<number>('id').as('order_count'),
            db.fn.coalesce(db.fn.sum<number>('amount_cents'), sql<number>`0`).as('total_spent_cents'),
          ])
          .where('tenant_id', '=', tenantId)
          .groupBy('user_id')
      )
      .selectFrom('users')
      .leftJoin('order_stats', 'order_stats.user_id', 'users.id')
      .select([
        'users.id',
        'users.email',
        'users.created_at',
        sql<number>`COALESCE(order_stats.order_count, 0)`.as('order_count'),
        sql<number>`COALESCE(order_stats.total_spent_cents, 0)`.as('total_spent_cents'),
      ])
      .where('users.tenant_id', '=', tenantId)
      .where('users.status', '=', 'active')
      .orderBy('users.created_at', 'desc')
      .limit(50)
      .execute();

    return { summaries };
  });
  ```

- **Nuxt Server Handlers & Fast-Path Lock Preservation Invariants (server/api)**:
  - ❌ **Anti-Pattern: 16-Lock Slot Overflow & Unbounded Partition Locks in Event Handlers**:
    - Writing Nitro server event handlers with unpartitioned queries or large relational joins exceeding 16 total relation + index locks, spilling locks into shared memory (`LockMethodLockHash`), degrading concurrent SSR rendering throughput.
    - Using session-level advisory locks in server routes that leak across connection pool checkouts.
  - ✅ **Production Invariant**:
    - Guard server handlers with strict partition pruning parameters (`event_date = $1`) and keep joined relations $\le 16$.
    - Wrap advisory locks in explicit transaction blocks via `pg_advisory_xact_lock()`.
  ```typescript
  // server/api/events/daily.get.ts
  import { db } from '~/server/utils/db';
  import { sql } from 'kysely';

  export default defineEventHandler(async (event) => {
    const query = getQuery(event);
    const tenantId = event.context.auth?.tenantId;
    const dateParam = (query.date as string) || new Date().toISOString().split('T')[0];

    if (!tenantId) {
      throw createError({ statusCode: 401, message: 'Unauthorized' });
    }

    // INVARIANT: Static partition pruning via dateParam; avoids locking all child partitions.
    // Preserves fast-path 16-slot array and guarantees sub-5ms API response latency.
    const events = await db
      .selectFrom('partitioned_events')
      .select(['id', 'event_type', 'payload', 'created_at'])
      .where('tenant_id', '=', tenantId)
      .where('event_date', '=', sql<Date>`${dateParam}::date`)
      .orderBy('created_at', 'desc')
      .limit(100)
      .execute();

    return {
      date: dateParam,
      events,
    };
  });
  ```

- **Nuxt Nitro Server Handlers & Security Barrier View Invariants (server/api)**:
  - ❌ **Anti-Pattern: Unprotected Views & Leaky Functions in Nitro Event Handlers**:
    - Writing Nitro API endpoints that query user-filtered views lacking `WITH (security_barrier = true)`, exposing multi-tenant databases to side-channel timing and error exfiltration attacks.
    - Applying regex or custom UDFs in server route filters, triggering PostgreSQL's security barrier pushdown blockade.
  - ✅ **Production Invariant**:
    - Wrap tenant operations in `SET LOCAL` transactions, querying views marked `WITH (security_barrier = true)` using leakproof operators.
  ```typescript
  // server/api/invoices/[no].get.ts
  import { db } from '~/server/utils/db';
  import { sql } from 'kysely';

  export default defineEventHandler(async (event) => {
    const tenantId = event.context.auth?.tenantId;
    const invoiceNo = getRouterParam(event, 'no');

    if (!tenantId) {
      throw createError({ statusCode: 401, message: 'Unauthorized' });
    }
    if (!invoiceNo) {
      throw createError({ statusCode: 400, message: 'Missing invoice number' });
    }

    // INVARIANT: Scoped transaction with SET LOCAL + Security Barrier View.
    // Built-in '=' operator is leakproof and pushes down into the base index scan.
    const invoice = await db.transaction().execute(async (tx) => {
      await sql`SET LOCAL app.current_tenant_id = ${tenantId}`.execute(tx);

      return await tx
        .selectFrom('v_secure_invoices')
        .select(['id', 'tenant_id', 'invoice_no', 'amount_cents', 'status', 'created_at'])
        .where('invoice_no', '=', invoiceNo)
        .executeTakeFirst();
    });

    if (!invoice) {
      throw createError({ statusCode: 404, message: 'Invoice not found' });
    }

    return invoice;
  });
  ```

- **Nuxt Nitro Server Handlers & Differentiated Durability Invariants (server/api)**:
  - ❌ **Anti-Pattern: Global Asynchronous Blind Meltdowns & Fsync Stalls in Nitro Handlers**:
    - Invoking default `synchronous_commit = on` on high-throughput event logging routes in Nitro, capping API throughput at 300 requests/sec due to storage fsync latency.
    - Setting `synchronous_commit = off` globally or at session level, exposing financial order payments to unrecoverable data loss upon server restart.
  - ✅ **Production Invariant**:
    - Use `SET LOCAL synchronous_commit = 'off'` in Nitro event stream and metric ingest routes, and enforce `SET LOCAL synchronous_commit = 'on'` (or `'remote_apply'`) for critical order checkout and auth mutations.
  ```typescript
  // server/api/events/batch.post.ts
  import { db } from '~/server/utils/db';
  import { sql } from 'kysely';

  export default defineEventHandler(async (event) => {
    const body = await readBody<{ events: Array<{ type: string; payload: any }> }>(event);
    if (!body?.events?.length) {
      throw createError({ statusCode: 400, message: 'Empty event batch' });
    }

    // INVARIANT: Scoped transaction with SET LOCAL synchronous_commit = 'off'.
    // Bypasses the 2ms storage fsync barrier while maintaining full ACID atomicity,
    // boosting high-throughput telemetry ingestion by 20x without connection pool bleed.
    await db.transaction().execute(async (tx) => {
      await sql`SET LOCAL synchronous_commit = 'off'`.execute(tx);

      for (const item of body.events) {
        await tx
          .insertInto('analytics_events')
          .values({
            event_type: item.type,
            payload: JSON.stringify(item.payload),
            created_at: new Date(),
          })
          .execute();
      }
    });

    return { status: 'acknowledged', count: body.events.length };
  });
  ```

- **UNLOGGED Staging & Ephemeral Ingestion Route Invariants (Nuxt 3 / Nitro)**:
  - ❌ **Anti-Pattern: Dynamic TEMP Table in Server Routes & Read Replica Querying**:
    - Issuing `CREATE TEMP TABLE` inside Nitro route handlers, thrashing database system catalogs and leaking connections under PgBouncer transaction pooling.
    - Routing unlogged staging reads to replica connection pools, returning empty data (0 rows).
  - ✅ **Production Invariant**:
    - Pre-create permanent `UNLOGGED` tables with `batch_id UUID`. Route exclusively to primary writer database.
    - Insert batch in chunks, validate or transform, promote to permanent table, and purge staged batch in one transaction.
  ```typescript
  // server/api/import/bulk-csv.post.ts
  import { primaryDb } from '~/server/utils/db';
  import { sql } from 'kysely';
  import { v4 as uuidv4 } from 'uuid';

  export default defineEventHandler(async (event) => {
    const { rows } = await readBody<{ rows: Array<Record<string, unknown>> }>(event);
    if (!rows?.length) {
      throw createError({ statusCode: 400, message: 'No rows provided' });
    }

    const batchId = uuidv4();

    // INVARIANT 1: Pre-created UNLOGGED table eliminates catalog churn (zero CREATE TEMP TABLE)
    // INVARIANT 2: Routed strictly to primary writer (primaryDb)
    await primaryDb.transaction().execute(async (tx) => {
      await sql`SET LOCAL lock_timeout = '2000ms'`.execute(tx);

      // Stage items in chunks of 500
      for (let i = 0; i < rows.length; i += 500) {
        const slice = rows.slice(i, i + 500).map((r, idx) => ({
          batch_id: batchId,
          row_index: i + idx,
          raw_data: JSON.stringify(r),
          created_at: new Date(),
        }));
        await tx.insertInto('staging_unlogged_imports').values(slice).execute();
      }

      // Atomically promote valid records to permanent logged table
      await sql`
        INSERT INTO customers (id, email, metadata, created_at)
        SELECT 
          gen_random_uuid(),
          raw_data->>'email',
          raw_data,
          NOW()
        FROM staging_unlogged_imports
        WHERE batch_id = ${batchId}
        ON CONFLICT (email) DO NOTHING
      `.execute(tx);

      // Clean up batch to prevent unlogged MVCC table bloat
      await tx
        .deleteFrom('staging_unlogged_imports')
        .where('batch_id', '=', batchId)
        .execute();
    });

    return { success: true, batchId, processed: rows.length };
  });
  ```

- **Concurrent Index Audit & Safe Remediation Route Invariants (Nuxt 3 / Nitro)**:
  - ❌ **Anti-Pattern: Synchronous Reindexing & Unindexed Constraint Addition in Nitro**:
    - Triggering `REINDEX TABLE` or synchronous `ALTER TABLE ADD CONSTRAINT UNIQUE` directly from API routes, causing connection pool exhaustion and 504 timeouts.
    - Neglecting orphaned `_ccnew` / `_ccold` indexes left behind by failed reindexes.
  - ✅ **Production Invariant**:
    - Query `pg_index` for `indisvalid = false` to surface invalid zombie indexes.
    - Remediate invalid indexes exclusively via `DROP INDEX CONCURRENTLY IF EXISTS` with bounded `lock_timeout`.
  ```typescript
  // server/api/admin/indexes/remediate-invalid.post.ts
  import { primaryDb } from '~/server/utils/db';
  import { sql } from 'kysely';

  export default defineEventHandler(async (event) => {
    const { indexName } = await readBody<{ indexName: string }>(event);

    if (!indexName || !/^[a-zA-Z0-9_]+$/.test(indexName)) {
      throw createError({ statusCode: 400, message: 'Invalid or missing index name' });
    }

    // Step 1: Verify the target index is actually invalid or an orphaned shadow index
    const check = await sql<{ indisvalid: boolean; relname: string }>`
      SELECT i.indisvalid, c.relname
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = ${indexName};
    `.execute(primaryDb);

    if (check.rows.length === 0) {
      throw createError({ statusCode: 404, message: 'Index not found' });
    }

    if (check.rows[0].indisvalid === true && !indexName.includes('_ccnew') && !indexName.includes('_ccold')) {
      throw createError({
        statusCode: 400,
        message: 'Index is valid and healthy. Refusing to drop valid production index.',
      });
    }

    // Step 2: Safely drop invalid index concurrently with bounded lock timeout
    try {
      await sql`SET lock_timeout = '3000ms'`.execute(primaryDb);
      await sql`DROP INDEX CONCURRENTLY IF EXISTS ${sql.raw(`"${indexName}"`)}`.execute(primaryDb);
      return { success: true, remediatedIndex: indexName };
    } catch (err: any) {
      throw createError({
        statusCode: 500,
        message: `Failed dropping invalid index concurrently: ${err.message}`,
      });
    }
  });
  ```

- **Free Space Map (FSM) & Fillfactor Optimization Nitro Routes (Nuxt 3)**:
  - ❌ **Anti-Pattern: Executing VACUUM FULL in Nitro Server Handlers**:
    - Triggering synchronous table rewrites or running un-timed `ALTER TABLE ... SET` from API endpoints, exhausting database connection pools and timing out frontend clients.
  - ✅ **Production Invariant**:
    - Audit HOT efficiency across all entity tables via `pg_stat_user_tables`.
    - Apply fillfactor alterations with transaction-scoped `SET LOCAL lock_timeout = '1500ms'`.
  ```typescript
  // server/api/admin/storage/fsm/calibrate.post.ts
  import { primaryDb } from '~/server/utils/db';
  import { sql } from 'kysely';

  export default defineEventHandler(async (event) => {
    const { tableName, fillfactor } = await readBody<{ tableName: string; fillfactor: number }>(event);

    if (!tableName || !/^[a-zA-Z0-9_]+$/.test(tableName)) {
      throw createError({ statusCode: 400, message: 'Invalid or missing table name' });
    }
    if (!fillfactor || fillfactor < 50 || fillfactor > 100) {
      throw createError({ statusCode: 400, message: 'Fillfactor must be between 50 and 100' });
    }

    try {
      // INVARIANT: Always wrap ALTER in transaction with strict lock_timeout
      await primaryDb.transaction().execute(async (tx) => {
        await sql`SET LOCAL lock_timeout = '1500ms'`.execute(tx);
        await sql`ALTER TABLE ${sql.raw(`"${tableName}"`)} SET (fillfactor = ${sql.raw(fillfactor.toString())})`.execute(tx);
      });

      return {
        success: true,
        tableName,
        calibratedFillfactor: fillfactor,
        repackHint: `Execute "pg_repack --table '${tableName}'" online to repack existing pages without locking.`,
      };
    } catch (err: any) {
      throw createError({
        statusCode: 500,
        message: `Failed calibrating fillfactor: ${err.message}`,
      });
    }
  });
  ```

- **Replication Slot Health Sentinel & Orphan Reaper Nitro Routes (Nuxt 3)**:
  - ❌ **Anti-Pattern: Unchecked Drop Operations in API Handlers**:
    - Dropping replication slots without active checks or lock timeouts, hanging backend worker threads.
  - ✅ **Production Invariant**:
    - Audit `pg_replication_slots` for inactive consumers holding WAL.
    - Execute cleanup with transaction-scoped `SET LOCAL lock_timeout = '2000ms'`.
  ```typescript
  // server/api/admin/storage/replication-slots/reap.post.ts
  import { primaryDb } from '~/server/utils/db';
  import { sql } from 'kysely';

  export default defineEventHandler(async (event) => {
    const { slotName } = await readBody<{ slotName: string }>(event);

    if (!slotName || !/^[a-zA-Z0-9_]+$/.test(slotName)) {
      throw createError({ statusCode: 400, message: 'Invalid or missing slot name' });
    }

    try {
      let dropped = false;
      await primaryDb.transaction().execute(async (tx) => {
        await sql`SET LOCAL lock_timeout = '2000ms'`.execute(tx);
        const check = await sql<{ active: boolean }>`
          SELECT active FROM pg_replication_slots WHERE slot_name = ${slotName}
        `.execute(tx);

        if (check.rows.length === 0) {
          throw new Error(`Slot '${slotName}' does not exist.`);
        }
        if (check.rows[0].active) {
          throw new Error(`Slot '${slotName}' is active; cannot reap connected consumer.`);
        }

        await sql`SELECT pg_drop_replication_slot(${slotName})`.execute(tx);
        dropped = true;
      });

      return {
        success: true,
        slotName,
        reaped: dropped,
      };
    } catch (err: any) {
      throw createError({
        statusCode: 500,
        message: `Failed reaping replication slot: ${err.message}`,
      });
    }
  });
  ```

- **Autovacuum Health Sentinel & Hot Table Cost Isolator Nitro Routes (Nuxt 3)**:
  - ❌ **Anti-Pattern: Monolithic Cost Throttling in High-Churn APIs**:
    - Allowing queue tables or session logs to choke on global autovacuum limits without dedicated table overrides.
  - ✅ **Production Invariant**:
    - Audit `pg_stat_progress_vacuum` and global cost allowances.
    - Execute table-specific cost overrides under transaction-scoped `SET LOCAL lock_timeout = '2000ms'`.
  ```typescript
  // server/api/admin/storage/autovacuum/isolate.post.ts
  import { primaryDb } from '~/server/utils/db';
  import { sql } from 'kysely';

  export default defineEventHandler(async (event) => {
    const { tableName, costLimit = 5000, costDelay = 0 } = await readBody<{
      tableName: string;
      costLimit?: number;
      costDelay?: number;
    }>(event);

    if (!tableName || !/^[a-zA-Z0-9_]+$/.test(tableName)) {
      throw createError({ statusCode: 400, message: 'Invalid or missing table identifier' });
    }

    try {
      await primaryDb.transaction().execute(async (tx) => {
        await sql`SET LOCAL lock_timeout = '2000ms'`.execute(tx);
        await sql.raw(`
          ALTER TABLE ${tableName} SET (
            autovacuum_vacuum_cost_limit = ${costLimit},
            autovacuum_vacuum_cost_delay = ${costDelay},
            autovacuum_vacuum_scale_factor = 0.02,
            autovacuum_vacuum_threshold = 200
          )
        `).execute(tx);
      });

      return {
        success: true,
        table: tableName,
        isolatedCostLimit: costLimit,
        isolatedCostDelay: costDelay,
      };
    } catch (err: any) {
      throw createError({
        statusCode: 500,
        message: `Failed isolating table autovacuum: ${err.message}`,
      });
    }
  });
  ```

- **Commit Log (CLOG / `pg_xact`) SLRU Telemetry & Hint-Bit Pre-Warming Route (Nuxt 3)**:
  - ❌ **Anti-Pattern: Opening Cold Tables Directly to Nuxt API Handlers**:
    - Triggering hundreds of concurrent server routes against un-hinted tables, pinning database CPU in `CLogControlLock`.
  - ✅ **Production Invariant**:
    - Provide an administrative route to verify SLRU hit ratio and execute hint-bit pre-warming via `VACUUM (ANALYZE)` before directing API traffic.
  ```typescript
  // server/api/admin/storage/clog/prewarm.post.ts
  import { primaryDb } from '~/server/utils/db';
  import { sql } from 'kysely';

  export default defineEventHandler(async (event) => {
    const { tableName } = await readBody<{ tableName: string }>(event);

    if (!tableName || !/^[a-zA-Z0-9_]+$/.test(tableName)) {
      throw createError({ statusCode: 400, message: 'Invalid or missing table identifier' });
    }

    try {
      const start = performance.now();
      // Set hint bits across all pages of newly populated table
      await sql.raw(`VACUUM (ANALYZE) ${tableName}`).execute(primaryDb);
      const durationMs = performance.now() - start;

      // Audit resulting SLRU stats
      const slruRes = await sql<{ hit_ratio: string }>`
        SELECT 
          CASE 
            WHEN (blks_hit + blks_read) = 0 THEN 1.0 
            ELSE (blks_hit::float / (blks_hit + blks_read))
          END AS hit_ratio
        FROM pg_stat_slru
        WHERE name = 'clog'
      `.execute(primaryDb);

      return {
        success: true,
        table: tableName,
        durationMs,
        currentSlruHitRatio: parseFloat(slruRes.rows[0]?.hit_ratio || '1.0'),
      };
    } catch (err: any) {
      throw createError({
        statusCode: 500,
        message: `Failed pre-warming hint bits: ${err.message}`,
      });
    }
  });
  ```

### Vue 3 Composition API & Nuxt 3 Server Route Invariants for Visibility Map Observability

In Nuxt 3 administrative interfaces or monitoring panels, handling database storage internals requires clean separation between server-side execution and client-side reactive rendering:

1. **`shallowRef` for Large Tabular Datasets**: Avoid wrapping large collections of database relation metrics in deep `ref()`—deep reactivity adds recursive proxy overhead across thousands of table objects. Use `shallowRef()` for tabular observability records.
2. **`useAsyncData` Deduplication & Key Stability**: Always pass explicit unique keys to `useAsyncData` (`useAsyncData('db-visibility-metrics', () => ...)`) to prevent hydration mismatch and duplicate server-side query execution.
3. **h3 Server Event Safety**: Validate incoming table parameters with strict regular expressions (`/^[a-zA-Z0-9_]+$/`) and enforce bounded `SET statement_timeout` before issuing maintenance vacuum commands.

```typescript
// server/api/admin/visibility-map.get.ts
import { defineEventHandler, getQuery, createError } from 'h3';
import { sql } from 'kysely';
import { primaryDb } from '~~/server/utils/db';

export default defineEventHandler(async (event) => {
  const query = getQuery(event);
  const minPages = Number(query.minPages ?? 100);

  try {
    const result = await sql<{
      tableName: string;
      totalPages: number;
      allVisiblePages: number;
      allFrozenPages: number;
      allVisiblePct: number;
      allFrozenPct: number;
      oldestXidAge: number;
    }>`
      SELECT 
        c.relname AS "tableName",
        c.relpages::bigint AS "totalPages",
        v.all_visible::bigint AS "allVisiblePages",
        v.all_frozen::bigint AS "allFrozenPages",
        COALESCE(ROUND((100.0 * v.all_visible / NULLIF(c.relpages, 0))::numeric, 2), 0.0)::float AS "allVisiblePct",
        COALESCE(ROUND((100.0 * v.all_frozen / NULLIF(c.relpages, 0))::numeric, 2), 0.0)::float AS "allFrozenPct",
        age(c.relfrozenxid)::bigint AS "oldestXidAge"
      FROM pg_class c
      JOIN LATERAL pg_visibility_map_summary(c.oid) v ON true
      WHERE c.relkind = 'r' 
        AND c.relnamespace = 'public'::regnamespace
        AND c.relpages >= ${minPages}
      ORDER BY c.relpages DESC;
    `.execute(primaryDb);

    return {
      success: true,
      tables: result.rows,
      timestamp: new Date().toISOString(),
    };
  } catch (err: any) {
    throw createError({
      statusCode: 500,
      statusMessage: `Failed to retrieve Visibility Map summary: ${err.message}`,
    });
  }
});
```

### Vue 3 Composition API & Nuxt 3 Server Route Invariants for Real-Time Lock Tree Observability

In Nuxt 3 administrative dashboards or database diagnostics consoles, rendering live lock dependency trees and providing emergency root-blocker preemption controls requires high UI fidelity and strict safety guards:

1. **`shallowRef` for Lock Trees**: Real-time lock graphs contain recursive trees and arrays of blocked PIDs. Use `shallowRef()` to avoid Vue deep reactivity proxy overhead on high-frequency polling intervals.
2. **Server-Side Action Fencing**: The preemption server route (`server/api/admin/preempt-root.post.ts`) must strictly verify that the target PID is actually a root blocker ($d^+ = 0, d^- > 0$) before issuing `pg_cancel_backend` or `pg_terminate_backend`, preventing malicious or accidental termination of innocent client connections.
3. **Structured Visual Badging**: Distinguish Root Blockers (red badge), Intermediate Nodes (orange badge), and Blocked Victims (neutral badge) in the template.

```typescript
// server/api/admin/lock-trees.get.ts
import { defineEventHandler, createError } from 'h3';
import { sql } from 'kysely';
import { primaryDb } from '~~/server/utils/db';

export interface LockSessionRecord {
  pid: number;
  usename: string;
  appName: string;
  state: string;
  waitEventType: string | null;
  waitEvent: string | null;
  queryDurationMs: number;
  stateDurationMs: number;
  blockingPids: number[];
  query: string;
}

export default defineEventHandler(async () => {
  try {
    const result = await sql<LockSessionRecord>`
      SELECT
        pid,
        usename,
        application_name AS "appName",
        state,
        wait_event_type AS "waitEventType",
        wait_event AS "waitEvent",
        ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - query_start)) * 1000)::bigint AS "queryDurationMs",
        ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - state_change)) * 1000)::bigint AS "stateDurationMs",
        pg_blocking_pids(pid) AS "blockingPids",
        query
      FROM pg_stat_activity
      WHERE pid <> pg_backend_pid()
        AND state IS NOT NULL
      ORDER BY query_start ASC;
    `.execute(primaryDb);

    return {
      success: true,
      sessions: result.rows,
      timestamp: new Date().toISOString(),
    };
  } catch (err: any) {
    throw createError({
      statusCode: 500,
      statusMessage: `Failed to inspect lock trees: ${err.message}`,
    });
  }
});
```

### Vue 3 Composition API & Nuxt 3 Server Route Invariants for Real-Time Continuous WAL Archiving Telemetry

In Nuxt 3 administrative dashboards or database observability sentinels, visualizing PostgreSQL continuous WAL archiver health and alerting on pending `.ready` backlogs requires strict separation of concerns and high frontend taste:

1. **Server Route Isolation & Safe Error Handling**: The Nitro server endpoint (`server/api/admin/wal-archiver.get.ts`) wraps `pg_stat_archiver` queries in safe try/catch blocks, falling back gracefully if `pg_ls_archive_statusdir()` requires elevated database superuser privileges.
2. **`shallowRef` for Polling Telemetry**: On polling intervals ($\le 10\text{s}$), use `shallowRef` to eliminate Vue deep reactivity overhead on nested database metrics.
3. **Proportional Headroom Indicator**: Visual progress bar computing `timeToExhaustion` and flashing warning states when disk headroom is threatened.

```typescript
// server/api/admin/wal-archiver.get.ts
import { defineEventHandler, createError } from 'h3';
import { sql } from 'kysely';
import { primaryDb } from '~~/server/utils/db';

export interface ArchiverStatusPayload {
  archivedCount: number;
  lastArchivedWal: string | null;
  lastArchivedTime: string | null;
  failedCount: number;
  lastFailedWal: string | null;
  lastFailedTime: string | null;
  readyBacklog: number;
  currentWalLsn: string;
}

export default defineEventHandler(async (event): Promise<ArchiverStatusPayload> => {
  try {
    const statResult = await sql<{
      archived_count: string;
      last_archived_wal: string | null;
      last_archived_time: Date | null;
      failed_count: string;
      last_failed_wal: string | null;
      last_failed_time: Date | null;
      current_lsn: string;
      ready_backlog: string;
    }>`
      SELECT
        a.archived_count,
        a.last_archived_wal,
        a.last_archived_time,
        a.failed_count,
        a.last_failed_wal,
        a.last_failed_time,
        pg_current_wal_lsn()::text AS current_lsn,
        COALESCE((
          SELECT count(*)
          FROM pg_ls_archive_statusdir()
          WHERE name LIKE '%.ready'
        ), 0) AS ready_backlog
      FROM pg_stat_archiver a;
    `.execute(primaryDb);

    if (statResult.rows.length === 0) {
      throw new Error('pg_stat_archiver view unavailable');
    }

    const row = statResult.rows[0];
    return {
      archivedCount: parseInt(row.archived_count, 10),
      lastArchivedWal: row.last_archived_wal,
      lastArchivedTime: row.last_archived_time ? row.last_archived_time.toISOString() : null,
      failedCount: parseInt(row.failed_count, 10),
      lastFailedWal: row.last_failed_wal,
      lastFailedTime: row.last_failed_time ? row.last_failed_time.toISOString() : null,
      readyBacklog: parseInt(row.ready_backlog, 10),
      currentWalLsn: row.current_lsn,
    };
  } catch (err: any) {
    throw createError({
      statusCode: 500,
      statusMessage: `Failed to query WAL archiver telemetry: ${err.message}`,
    });
  }
});
```

### Vue 3 Composition API & Nuxt 3 Server Route Invariants for Real-Time Logical Replication Conflict Observability

In Nuxt 3 mission-critical database operations dashboards, surfacing PostgreSQL logical replication subscription health, active worker conflicts, and audited skip LSN actions requires strict decoupling of Nitro server endpoints and client composables:

1. **Nitro Server Route with Schema Safeguards**: The endpoint (`server/api/admin/replication/conflicts.get.ts`) queries `pg_stat_subscription_errors` and calculates byte lag via `pg_wal_lsn_diff`, handling PostgreSQL version variations (e.g. `disable_on_error` support in PG 15+).
2. **`shallowRef` Reactivity for High-Frequency Polling**: When polling subscription status every 5 seconds, use `shallowRef` to prevent Vue's deep proxy traversal on large metadata objects.
3. **Audited Skip Execution Action**: The skip action route enforces operator identity, mandatory rationale documentation, and atomic pre-flight conflict validation before invoking `ALTER SUBSCRIPTION ... SKIP (lsn = ...)`.

```typescript
// server/api/admin/replication/conflicts.get.ts
import { defineEventHandler, createError } from 'h3';
import { sql } from 'kysely';
import { subscriberDb } from '~~/server/utils/db';

export interface SubscriptionConflictPayload {
  subname: string;
  workerPid: number | null;
  errorCount: number;
  lastErrorCode: string | null;
  lastErrorMessage: string | null;
  lastErrorLsn: string | null;
  lastErrorTime: string | null;
  disableOnError: boolean;
  status: 'HEALTHY' | 'CRASH_LOOPING' | 'PAUSED_ON_ERROR' | 'UNINDEXED_RISK';
}

export default defineEventHandler(async (): Promise<SubscriptionConflictPayload[]> => {
  try {
    const results = await sql<{
      subname: string;
      pid: number | null;
      last_error_code: string | null;
      last_error_message: string | null;
      last_error_lsn: string | null;
      last_error_time: Date | null;
      last_error_count: string | null;
      subdisableonerr: boolean | null;
    }>`
      SELECT
        s.subname,
        stat.pid,
        err.last_error_code,
        err.last_error_message,
        err.last_error_lsn::text,
        err.last_error_time,
        err.last_error_count,
        COALESCE(s.subdisableonerr, false) AS subdisableonerr
      FROM pg_subscription s
      LEFT JOIN pg_stat_subscription stat ON stat.subid = s.oid
      LEFT JOIN pg_stat_subscription_errors err ON err.subid = s.oid;
    `.execute(subscriberDb);

    return results.rows.map((row) => {
      const errorCount = parseInt(row.last_error_count || '0', 10);
      let status: SubscriptionConflictPayload['status'] = 'HEALTHY';

      if (errorCount > 0) {
        status = row.subdisableonerr ? 'PAUSED_ON_ERROR' : 'CRASH_LOOPING';
      }

      return {
        subname: row.subname,
        workerPid: row.pid,
        errorCount,
        lastErrorCode: row.last_error_code,
        lastErrorMessage: row.last_error_message,
        lastErrorLsn: row.last_error_lsn,
        lastErrorTime: row.last_error_time ? row.last_error_time.toISOString() : null,
        disableOnError: Boolean(row.subdisableonerr),
        status,
      };
    });
  } catch (err: any) {
    throw createError({
      statusCode: 500,
      statusMessage: `Failed to query subscription errors: ${err.message}`,
    });
  }
});
```

```vue
<!-- components/admin/ReplicationConflictSentinel.vue -->
<script setup lang="ts">
import { shallowRef, computed, onMounted, onUnmounted } from 'vue';

interface SubscriptionRecord {
  subname: string;
  workerPid: number | null;
  errorCount: number;
  lastErrorCode: string | null;
  lastErrorMessage: string | null;
  lastErrorLsn: string | null;
  lastErrorTime: string | null;
  disableOnError: boolean;
  status: 'HEALTHY' | 'CRASH_LOOPING' | 'PAUSED_ON_ERROR' | 'UNINDEXED_RISK';
}

const subscriptions = shallowRef<SubscriptionRecord[]>([]);
const isPolling = shallowRef(false);
let timer: ReturnType<typeof setInterval> | null = null;

const hasCrashLoop = computed(() =>
  subscriptions.value.some((s) => s.status === 'CRASH_LOOPING')
);

async function refreshData() {
  try {
    const data = await $fetch<SubscriptionRecord[]>('/api/admin/replication/conflicts');
    subscriptions.value = data;
  } catch (err) {
    console.error('Failed to fetch replication conflicts', err);
  }
}

onMounted(() => {
  refreshData();
  timer = setInterval(refreshData, 5000);
});

onUnmounted(() => {
  if (timer) clearInterval(timer);
});
</script>

<template>
  <div class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm space-y-4">
    <div class="flex items-center justify-between">
      <div>
        <h2 class="text-base font-semibold text-slate-900">Logical Replication Sentinel</h2>
        <p class="text-xs text-slate-500">Live subscription worker health and conflict alerts</p>
      </div>
      <div>
        <span
          v-if="hasCrashLoop"
          class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold bg-rose-50 text-rose-700 border border-rose-200 animate-pulse"
        >
          ● Crash Loop Active
        </span>
        <span
          v-else
          class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold bg-emerald-50 text-emerald-700 border border-emerald-200"
        >
          ● All Workers Healthy
        </span>
      </div>
    </div>

    <div class="divide-y divide-slate-100">
      <div
        v-for="sub in subscriptions"
        :key="sub.subname"
        class="py-3 flex items-center justify-between"
      >
        <div>
          <span class="font-mono font-medium text-xs text-slate-800">{{ sub.subname }}</span>
          <p v-if="sub.errorCount > 0" class="text-xs text-rose-600 mt-0.5">
            Error on LSN <span class="font-mono font-semibold">{{ sub.lastErrorLsn }}</span>:
            {{ sub.lastErrorMessage }} ({{ sub.errorCount }} retries)
          </p>
        </div>
        <div class="text-right text-xs">
          <span
            :class="{
              'text-rose-600 font-bold': sub.status === 'CRASH_LOOPING',
              'text-amber-600 font-medium': sub.status === 'PAUSED_ON_ERROR',
              'text-emerald-600': sub.status === 'HEALTHY',
            }"
          >
            {{ sub.status }}
          </span>
        </div>
      </div>
    </div>
  </div>
</template>
```

---

## 15. Vue 3.5+ Reactivity Invariants & Memory Leak Elimination Discipline

In modern Vue 3.5+ and Nuxt 3/4 architectures, autonomous agents frequently make four critical mistakes: deeply proxying third-party objects (causing 100x memory overhead), leaking un-cancelled async requests in watchers, mishandling composable arguments, and triggering SSR hydration mismatches. Enforce these strict invariants:

```typescript
// composables/useAgentResourcePoller.ts
import { ref, shallowRef, toValue, watchEffect, onWatcherCleanup, type MaybeRefOrGetter } from 'vue';

export interface PollerOptions<T> {
  url: MaybeRefOrGetter<string>;
  intervalMs?: MaybeRefOrGetter<number>;
  onSuccess?: (data: T) => void;
}

/**
 * Vue 3.5+ Composable demonstrating:
 * 1. MaybeRefOrGetter normalization with toValue()
 * 2. Automatic async cleanup via onWatcherCleanup() (eliminating race conditions)
 * 3. shallowRef for heavy API responses to prevent deep reactivity overhead
 */
export function useAgentResourcePoller<T>(options: PollerOptions<T>) {
  // Use shallowRef for data payloads to eliminate deep reactive Proxy creation
  const data = shallowRef<T | null>(null);
  const isPending = ref(false);
  const error = shallowRef<Error | null>(null);

  watchEffect(() => {
    // Normalize reactive getters, refs, and plain values
    const targetUrl = toValue(options.url);
    const interval = toValue(options.intervalMs) ?? 10000;

    if (!targetUrl) return;

    const controller = new AbortController();

    // Register async abort cleanup for the active effect iteration (Vue 3.5+)
    onWatcherCleanup(() => {
      controller.abort();
    });

    const fetchData = async () => {
      isPending.value = true;
      try {
        const res = await fetch(targetUrl, { signal: controller.signal });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const json = (await res.json()) as T;
        data.value = json;
        error.value = null;
        options.onSuccess?.(json);
      } catch (err: any) {
        if (err.name !== 'AbortError') {
          error.value = err;
        }
      } finally {
        isPending.value = false;
      }
    };

    fetchData();
    const timer = setInterval(fetchData, interval);

    onWatcherCleanup(() => {
      clearInterval(timer);
    });
  });

  return {
    data,
    isPending,
    error,
  };
}

/**
 * useHashIndexAuditor (Vue 3.5 Composable)
 * Telemetry and audit composable for PostgreSQL Hash indexes with automatic abort cleanup.
 */
export function useHashIndexAuditor(indexName: MaybeRefOrGetter<string>) {
  const data = ref<{
    indexName: string;
    primaryPages: number;
    overflowPages: number;
    overflowRatio: number;
    needsReindex: boolean;
  } | null>(null);

  const isAuditing = ref(false);
  const error = ref<Error | null>(null);

  watchEffect(async () => {
    const target = toValue(indexName);
    if (!target) return;

    const controller = new AbortController();
    onWatcherCleanup(() => controller.abort());

    isAuditing.value = true;
    try {
      const res = await fetch(`/api/indexes/hash/audit?name=${encodeURIComponent(target)}`, {
        signal: controller.signal,
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      data.value = await res.json();
      error.value = null;
    } catch (err: any) {
      if (err.name !== 'AbortError') {
        error.value = err;
      }
    } finally {
      isAuditing.value = false;
    }
  });

  return {
    data,
    isAuditing,
    error,
  };
}

/**
 * useLargeObjectUploader (Vue 3.5 Composable)
 * Enforces client-side 3-Zone Storage Sizing (bytea vs LOB vs S3 Presigned URL)
 * and provides chunked streaming progress and abort cleanup.
 */
export function useLargeObjectUploader() {
  const isUploading = ref(false);
  const progressPercent = ref(0);
  const error = ref<Error | null>(null);

  const uploadFile = async (
    file: File,
    endpointUrl: string,
    options?: { signal?: AbortSignal }
  ) => {
    isUploading.value = true;
    progressPercent.value = 0;
    error.value = null;

    try {
      // 1. Client-Side 3-Zone Storage Qualification
      const MAX_DB_SIZE = 5 * 1024 * 1024; // 5 MB
      if (file.size > MAX_DB_SIZE) {
        // Exceeds 5MB: Request S3 presigned PUT URL instead of streaming into database
        const presignRes = await fetch('/api/storage/presigned-url', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ filename: file.name, byteSize: file.size, contentType: file.type }),
          signal: options?.signal,
        });
        if (!presignRes.ok) throw new Error('Failed to obtain presigned storage URL');
        const { uploadUrl, fileKey } = await presignRes.json();

        // Direct upload to S3 / Cloudflare R2
        await fetch(uploadUrl, {
          method: 'PUT',
          headers: { 'Content-Type': file.type },
          body: file,
          signal: options?.signal,
        });

        progressPercent.value = 100;
        return { storageTier: 'EXTERNAL_S3', fileKey };
      }

      // 2. Direct LOB / Bytea upload with XMLHttpRequest for upload progress tracking
      return await new Promise<{ storageTier: 'DATABASE'; oid?: number }>((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open('POST', endpointUrl, true);
        xhr.setRequestHeader('Content-Type', file.type);
        xhr.setRequestHeader('X-Filename', encodeURIComponent(file.name));

        if (options?.signal) {
          options.signal.addEventListener('abort', () => xhr.abort());
        }

        xhr.upload.onprogress = (event) => {
          if (event.lengthComputable) {
            progressPercent.value = Math.round((event.loaded / event.total) * 100);
          }
        };

        xhr.onload = () => {
          if (xhr.status >= 200 && xhr.status < 300) {
            try {
              const res = JSON.parse(xhr.responseText);
              resolve({ storageTier: 'DATABASE', oid: res.oid });
            } catch {
              resolve({ storageTier: 'DATABASE' });
            }
          } else {
            reject(new Error(`Upload failed with HTTP ${xhr.status}`));
          }
        };

        xhr.onerror = () => reject(new Error('Network error during upload'));
        xhr.onabort = () => reject(new DOMException('Upload aborted by user', 'AbortError'));

        xhr.send(file);
      });
    } catch (err: any) {
      if (err.name !== 'AbortError') {
        error.value = err;
      }
      throw err;
    } finally {
      isUploading.value = false;
    }
  };

  return {
    isUploading,
    progressPercent,
    error,
    uploadFile,
  };
}
```

---

## 15. Database DDL Audit & Table Rewrite Sentinel (Vue 3 / Nuxt 3)

When building administrative consoles, DevOps dashboards, or migration monitors:

- **Real-Time DDL Audit Sentinel**: Stream DDL change events with auto-refresh and highlight destructive commands (`DROP`, `ALTER`, `TRUNCATE`).
- **Table Rewrite Alert Banner**: Warn developers and operators before migration scripts trigger dangerous table rewrites.

```vue
<!-- components/DDLGuardrailStatusCard.vue -->
<script setup lang="ts">
import { ref, onMounted } from 'vue';

interface DDLAuditEntry {
  id: number;
  executed_at: string;
  tx_lsn: string;
  command_tag: string;
  object_type: string;
  object_identity: string;
  session_user_name: string;
}

interface GuardrailStatus {
  allInstalled: boolean;
  unindexedForeignKeysCount: number;
  recentAudits: DDLAuditEntry[];
}

const status = ref<GuardrailStatus | null>(null);
const isLoading = ref(true);
const errorMessage = ref<string | null>(null);

async function fetchStatus() {
  isLoading.value = true;
  errorMessage.value = null;
  try {
    const res = await $fetch<GuardrailStatus>('/api/admin/database/ddl-guards');
    status.value = res;
  } catch (err: any) {
    errorMessage.value = err?.data?.message || err.message || 'Failed to fetch DDL guardrail status';
  } finally {
    isLoading.value = false;
  }
}

onMounted(() => {
  fetchStatus();
});
</script>

<template>
  <div class="rounded-xl border border-zinc-800 bg-zinc-950 p-5 shadow-2xl">
    <div class="flex items-center justify-between pb-4 border-b border-zinc-850">
      <div class="flex items-center gap-3">
        <span
          class="flex h-3 w-3 rounded-full"
          :class="status?.allInstalled ? 'bg-emerald-500 ring-4 ring-emerald-500/20' : 'bg-rose-500 ring-4 ring-rose-500/20'"
        />
        <h3 class="text-sm font-semibold tracking-wide text-zinc-100">PostgreSQL DDL Guardrails</h3>
      </div>
      <button
        @click="fetchStatus"
        :disabled="isLoading"
        class="inline-flex items-center gap-1.5 rounded-lg border border-zinc-700 bg-zinc-900 px-2.5 py-1 text-xs font-medium text-zinc-300 hover:bg-zinc-800 active:scale-95 disabled:opacity-50 transition-all"
      >
        <span v-if="isLoading" class="h-3 w-3 animate-spin rounded-full border-2 border-zinc-400 border-t-transparent" />
        Refresh
      </button>
    </div>

    <!-- Warning: Unindexed FKs -->
    <div
      v-if="status && status.unindexedForeignKeysCount > 0"
      class="mt-4 flex items-start gap-3 rounded-lg border border-amber-500/30 bg-amber-500/10 p-3.5 text-xs text-amber-300"
    >
      <svg class="h-4 w-4 shrink-0 mt-0.5 text-amber-400" viewBox="0 0 20 20" fill="currentColor">
        <path fill-rule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495zM10 5a.75.75 0 01.75.75v4.5a.75.75 0 01-1.5 0v-4.5A.75.75 0 0110 5zm0 10a1 1 0 100-2 1 1 0 000 2z" clip-rule="evenodd" />
      </svg>
      <div>
        <p class="font-medium text-amber-200">Unindexed Foreign Keys Detected ({{ status.unindexedForeignKeysCount }})</p>
        <p class="mt-0.5 text-amber-300/80">Foreign keys lacking child indexes risk full table sequential scans and lock escalations during updates.</p>
      </div>
    </div>

    <!-- Recent DDL Events -->
    <div class="mt-5">
      <h4 class="text-xs font-medium text-zinc-400 uppercase tracking-wider">Recent Schema Mutations</h4>
      <div class="mt-2.5 divide-y divide-zinc-850 overflow-hidden rounded-lg border border-zinc-850">
        <div
          v-for="entry in status?.recentAudits || []"
          :key="entry.id"
          class="flex items-center justify-between p-2.5 text-xs bg-zinc-900/40 hover:bg-zinc-900/80 transition-colors"
        >
          <div class="flex items-center gap-2">
            <span
              class="rounded px-1.5 py-0.5 font-mono text-[10px] font-semibold"
              :class="{
                'bg-rose-500/20 text-rose-300 border border-rose-500/30': entry.command_tag.includes('DROP'),
                'bg-amber-500/20 text-amber-300 border border-amber-500/30': entry.command_tag.includes('ALTER'),
                'bg-blue-500/20 text-blue-300 border border-blue-500/30': entry.command_tag.includes('CREATE'),
              }"
            >
              {{ entry.command_tag }}
            </span>
            <span class="font-mono text-zinc-200 font-medium">{{ entry.object_identity }}</span>
          </div>
          <div class="flex items-center gap-3 text-zinc-500 font-mono text-[11px]">
            <span>{{ entry.session_user_name }}</span>
            <span>{{ new Date(entry.executed_at).toLocaleTimeString() }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
```

---

## 16. Parallel Data Swarm & Autovacuum Horizon Pinning Sentinel (Vue 3.5 / Nuxt 3)

When building database administration dashboards or ETL pipeline monitoring in Vue 3.5+ and Nuxt 3:

- **Shallow State for High-Frequency Telemetry**:
  - Pinned snapshot sessions can change rapidly during high-throughput parallel ingestion. Wrap session lists in `shallowRef` to eliminate unnecessary deep reactivity overhead.
- **Computed Risk Aggregation**:
  - Compute danger alert levels and starvation durations using standard Vue 3.5 `computed()`, and ensure timers are cleared via `onUnmounted()`.

```vue
<!-- components/admin/SnapshotHorizonSentinel.vue -->
<script setup lang="ts">
import { ref, shallowRef, computed, onMounted, onUnmounted } from 'vue';

interface PinnedSession {
  pid: number;
  user_name: string;
  client_ip: string | null;
  application_name: string;
  backend_xmin: string;
  duration_seconds: number;
  state: string;
  risk_tier: 'HEALTHY' | 'WARNING_ELEVATED_HORIZON' | 'DANGER_AUTOVACUUM_STARVATION';
}

interface SnapshotAuditPayload {
  thresholdSeconds: number;
  pinnedHorizonSessionsCount: number;
  starvationAlertsCount: number;
  pinnedHorizonSessions: PinnedSession[];
}

const props = withDefaults(defineProps<{ pollIntervalMs?: number }>(), {
  pollIntervalMs: 5000,
});

const auditData = shallowRef<SnapshotAuditPayload | null>(null);
const isLoading = ref(false);
const errorMessage = ref<string | null>(null);
let pollTimer: ReturnType<typeof setInterval> | null = null;

const dangerSessions = computed(() => {
  return auditData.value?.pinnedHorizonSessions.filter((s) => s.risk_tier === 'DANGER_AUTOVACUUM_STARVATION') ?? [];
});

async function refreshHorizonStatus() {
  isLoading.value = true;
  errorMessage.value = null;
  try {
    const data = await $fetch<SnapshotAuditPayload>('/api/admin/database/snapshots');
    auditData.value = data;
  } catch (err: any) {
    errorMessage.value = err.message || 'Failed to fetch snapshot status';
  } finally {
    isLoading.value = false;
  }
}

async function terminateSession(pid: number) {
  if (!confirm(`Are you sure you want to terminate backend PID ${pid}? This will unpin the autovacuum horizon.`)) return;
  try {
    await $fetch(`/api/admin/database/snapshots/${pid}/terminate`, { method: 'POST' });
    await refreshHorizonStatus();
  } catch (err: any) {
    alert(`Termination error: ${err.message}`);
  }
}

onMounted(() => {
  refreshHorizonStatus();
  pollTimer = setInterval(refreshHorizonStatus, props.pollIntervalMs);
});

onUnmounted(() => {
  if (pollTimer) clearInterval(pollTimer);
});
</script>

<template>
  <div class="rounded-xl border border-zinc-800 bg-zinc-950 p-6 text-zinc-100 shadow-2xl">
    <div class="flex items-center justify-between border-b border-zinc-800/80 pb-4">
      <div class="flex items-center gap-3">
        <div class="flex h-9 w-9 items-center justify-center rounded-lg bg-indigo-500/10 border border-indigo-500/20 text-indigo-400">
          <svg class="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
        </div>
        <div>
          <h3 class="text-sm font-semibold text-zinc-100">Transaction Snapshot & Horizon Sentinel</h3>
          <p class="text-xs text-zinc-400">Monitors oldestxmin freeze duration & autovacuum starvation</p>
        </div>
      </div>
      <button
        @click="refreshHorizonStatus"
        :disabled="isLoading"
        class="rounded-lg border border-zinc-700 bg-zinc-800/60 px-3 py-1.5 text-xs font-medium text-zinc-200 hover:bg-zinc-700 disabled:opacity-50 transition-colors"
      >
        {{ isLoading ? 'Refreshing...' : 'Refresh' }}
      </button>
    </div>

    <div v-if="errorMessage" class="mt-4 rounded-lg border border-rose-500/30 bg-rose-500/10 p-3 text-xs text-rose-300">
      {{ errorMessage }}
    </div>

    <div v-if="dangerSessions.length > 0" class="mt-4 rounded-lg border border-rose-500/40 bg-rose-500/10 p-3.5 text-xs text-rose-200">
      <div class="flex items-center gap-2 font-semibold text-rose-300">
        <svg class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
          <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.28 7.22a.75.75 0 00-1.06 1.06L8.94 10l-1.72 1.72a.75.75 0 101.06 1.06L10 11.06l1.72 1.72a.75.75 0 101.06-1.06L11.06 10l1.72-1.72a.75.75 0 00-1.06-1.06L10 8.94 8.28 7.22z" clip-rule="evenodd" />
        </svg>
        <span>Critical: {{ dangerSessions.length }} Backend(s) Pinning Autovacuum Horizon (&gt; 15 min)</span>
      </div>
      <p class="mt-1 text-rose-300/80">Dead tuples cannot be cleaned by autovacuum across any cluster table. Bloat accumulating.</p>
    </div>

    <div class="mt-5">
      <h4 class="text-xs font-medium uppercase tracking-wider text-zinc-400">Active Snapshot Sessions</h4>
      <div class="mt-2.5 divide-y divide-zinc-800/80 overflow-hidden rounded-lg border border-zinc-800/80">
        <div v-if="!auditData || auditData.pinnedHorizonSessions.length === 0" class="p-3 text-center text-xs text-zinc-500">
          Zero pinned snapshot backends. Cluster autovacuum running freely.
        </div>
        <div
          v-else
          v-for="session in auditData.pinnedHorizonSessions"
          :key="session.pid"
          class="flex items-center justify-between p-3 text-xs bg-zinc-900/40 hover:bg-zinc-900/70 transition-colors"
        >
          <div class="flex items-center gap-3">
            <span
              class="rounded px-2 py-0.5 font-mono text-[10px] font-semibold"
              :class="{
                'bg-rose-500/20 text-rose-300 border border-rose-500/30': session.risk_tier === 'DANGER_AUTOVACUUM_STARVATION',
                'bg-amber-500/20 text-amber-300 border border-amber-500/30': session.risk_tier === 'WARNING_ELEVATED_HORIZON',
                'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30': session.risk_tier === 'HEALTHY',
              }"
            >
              PID {{ session.pid }}
            </span>
            <div>
              <p class="font-mono text-zinc-200 font-medium">xmin: {{ session.backend_xmin }} ({{ session.application_name }})</p>
              <p class="text-[11px] text-zinc-500 font-mono">User: {{ session.user_name }} | IP: {{ session.client_ip || 'local' }} | {{ session.duration_seconds }}s active</p>
            </div>
          </div>
          <button
            v-if="session.risk_tier === 'DANGER_AUTOVACUUM_STARVATION'"
            @click="terminateSession(session.pid)"
            class="rounded bg-rose-500/20 px-2.5 py-1 text-[11px] font-medium text-rose-300 border border-rose-500/30 hover:bg-rose-500/30 transition-colors"
          >
            Terminate
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

---

## 17. Logical Replication Publication & Row Filter Monitor (Vue 3 / Nuxt 3)

When building database administration tools or CDC dashboards with Vue 3 / Nuxt 3:

```vue
<!-- components/PublicationSentinelCard.vue -->
<script setup lang="ts">
import { ref, onMounted } from 'vue';

interface PublicationTable {
  pubname: string;
  schemaname: string;
  tablename: string;
  rowfilter: string | null;
  replica_identity: string;
  has_pk: boolean;
  pubviaroot: boolean;
}

interface PublicationStatus {
  totalPublishedTables: number;
  totalHazardsCount: number;
  criticalCount: number;
  hazards: Array<{
    pubname: string;
    table: string;
    issue: string;
    severity: string;
    remediation: string;
  }>;
  publications: PublicationTable[];
}

const status = ref<PublicationStatus | null>(null);
const isLoading = ref(true);
const errorMessage = ref<string | null>(null);

async function fetchStatus() {
  isLoading.value = true;
  errorMessage.value = null;
  try {
    status.value = await $fetch<PublicationStatus>('/api/admin/database/publications');
  } catch (err: any) {
    errorMessage.value = err?.data?.message || err.message || 'Failed to load publication status';
  } finally {
    isLoading.value = false;
  }
}

onMounted(() => {
  fetchStatus();
});
</script>

<template>
  <div class="rounded-xl border border-zinc-800 bg-zinc-950 p-5 shadow-2xl">
    <div class="flex items-center justify-between pb-4 border-b border-zinc-850">
      <div class="flex items-center gap-3">
        <span
          class="flex h-3 w-3 rounded-full"
          :class="status && status.criticalCount === 0 ? 'bg-emerald-500 ring-4 ring-emerald-500/20' : 'bg-rose-500 ring-4 ring-rose-500/20'"
        />
        <div>
          <h3 class="text-sm font-semibold tracking-wide text-zinc-100">Logical Replication Publications</h3>
          <p class="text-[11px] text-zinc-500">Row filters, replica identity & partition root status</p>
        </div>
      </div>
      <button
        @click="fetchStatus"
        :disabled="isLoading"
        class="inline-flex items-center gap-1.5 rounded-lg border border-zinc-700 bg-zinc-900 px-2.5 py-1 text-xs font-medium text-zinc-300 hover:bg-zinc-800 active:scale-95 disabled:opacity-50 transition-all"
      >
        <span v-if="isLoading" class="h-3 w-3 animate-spin rounded-full border-2 border-zinc-400 border-t-transparent" />
        Refresh
      </button>
    </div>

    <!-- Hazard Alert -->
    <div
      v-if="status && status.criticalCount > 0"
      class="mt-4 flex items-start gap-3 rounded-lg border border-rose-500/30 bg-rose-500/10 p-3.5 text-xs text-rose-300"
    >
      <svg class="h-4 w-4 shrink-0 mt-0.5 text-rose-400" viewBox="0 0 20 20" fill="currentColor">
        <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.28 7.22a.75.75 0 00-1.06 1.06L8.94 10l-1.72 1.72a.75.75 0 101.06 1.06L10 11.06l1.72 1.72a.75.75 0 101.06-1.06L11.06 10l1.72-1.72a.75.75 0 00-1.06-1.06L10 8.94 8.28 7.22z" clip-rule="evenodd" />
      </svg>
      <div>
        <p class="font-medium text-rose-200">Critical Row Filter Hazards ({{ status.criticalCount }})</p>
        <p class="mt-0.5 text-rose-300/80">Tables with row filters lacking REPLICA IDENTITY FULL will crash publisher transactions upon updating filter columns (SQLSTATE 55000).</p>
      </div>
    </div>

    <!-- Publications List -->
    <div class="mt-5">
      <h4 class="text-xs font-medium text-zinc-400 uppercase tracking-wider">Published Relations ({{ status?.totalPublishedTables ?? 0 }})</h4>
      <div class="mt-2.5 divide-y divide-zinc-850 overflow-hidden rounded-lg border border-zinc-850">
        <div
          v-for="pub in status?.publications || []"
          :key="`${pub.pubname}.${pub.schemaname}.${pub.tablename}`"
          class="flex items-center justify-between p-3 text-xs bg-zinc-900/40 hover:bg-zinc-900/70 transition-colors"
        >
          <div>
            <div class="flex items-center gap-2">
              <span class="rounded bg-zinc-800 px-1.5 py-0.5 font-mono text-[10px] text-zinc-300">{{ pub.pubname }}</span>
              <span class="font-mono text-zinc-200 font-semibold">{{ pub.schemaname }}.{{ pub.tablename }}</span>
            </div>
            <p v-if="pub.rowfilter" class="mt-1 font-mono text-[11px] text-amber-400/90">WHERE {{ pub.rowfilter }}</p>
          </div>
          <span
            class="rounded px-1.5 py-0.5 font-mono text-[11px] border"
            :class="pub.replica_identity === 'f' ? 'bg-emerald-500/20 text-emerald-300 border-emerald-500/30' : 'bg-amber-500/20 text-amber-300 border-amber-500/30'"
          >
            replident: {{ pub.replica_identity }}
          </span>
        </div>
      </div>
    </div>
  </div>
</template>
```

---

## 18. PostgreSQL Extension Governance & Version Drift Sentinel (Vue 3.5 / Nuxt 3)

When building database observability interfaces in Vue 3.5 / Nuxt 3, audit extension versions, preloaded libraries, and schema isolation with reactive primitives and `useTemplateRef`:

```vue
<script setup lang="ts">
import { ref, computed, useTemplateRef } from 'vue';

interface ExtensionItem {
  name: string;
  installedVersion: string;
  defaultVersion: string;
  schema: string;
  isPreloaded: boolean;
  requiresPreload: boolean;
}

const props = defineProps<{
  extensions: ExtensionItem[];
}>();

const emit = defineEmits<{
  (e: 'update', name: string, targetVersion: string): void;
}>();

const searchInputRef = useTemplateRef<HTMLInputElement>('searchInput');
const searchFilter = ref('');

const filteredExtensions = computed(() => {
  const query = searchFilter.value.toLowerCase().trim();
  if (!query) return props.extensions;
  return props.extensions.filter(
    (ext) =>
      ext.name.toLowerCase().includes(query) ||
      ext.schema.toLowerCase().includes(query)
  );
});

const driftCount = computed(() =>
  props.extensions.filter((ext) => ext.installedVersion !== ext.defaultVersion).length
);

const missingPreloadCount = computed(() =>
  props.extensions.filter((ext) => ext.requiresPreload && !ext.isPreloaded).length
);
</script>

<template>
  <div class="rounded-xl border border-zinc-800 bg-zinc-950 p-6 text-zinc-100 shadow-2xl">
    <div class="flex items-center justify-between border-b border-zinc-800 pb-4">
      <div>
        <h3 class="text-sm font-semibold tracking-wide text-zinc-200">PostgreSQL Extension Sentinel</h3>
        <p class="text-xs text-zinc-400">Audit shared_preload_libraries, schema isolation & version drift</p>
      </div>
      <div class="flex items-center gap-2">
        <span
          v-if="missingPreloadCount > 0"
          class="rounded-full bg-rose-500/10 px-2.5 py-1 text-xs font-medium text-rose-400 border border-rose-500/20"
        >
          {{ missingPreloadCount }} Missing Preload
        </span>
        <span
          v-if="driftCount > 0"
          class="rounded-full bg-amber-500/10 px-2.5 py-1 text-xs font-medium text-amber-400 border border-amber-500/20"
        >
          {{ driftCount }} Version Drift
        </span>
        <span
          v-else
          class="rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-medium text-emerald-400 border border-emerald-500/20"
        >
          All Synced
        </span>
      </div>
    </div>

    <div class="mt-4">
      <input
        ref="searchInput"
        v-model="searchFilter"
        type="text"
        placeholder="Filter extensions or schemas..."
        class="w-full rounded-lg border border-zinc-800 bg-zinc-900/60 px-3.5 py-2 text-xs text-zinc-200 placeholder-zinc-500 focus:border-zinc-700 focus:outline-none"
      />
    </div>

    <div class="mt-4 divide-y divide-zinc-800/80">
      <div
        v-for="ext in filteredExtensions"
        :key="ext.name"
        class="flex items-center justify-between py-3"
      >
        <div class="space-y-1">
          <div class="flex items-center gap-2">
            <span class="font-mono text-xs font-semibold text-zinc-200">{{ ext.name }}</span>
            <span class="rounded bg-zinc-800 px-1.5 py-0.5 font-mono text-[10px] text-zinc-400">{{ ext.schema }}</span>
          </div>
          <div class="text-[11px] text-zinc-400">
            Installed: <span class="font-mono text-zinc-300">{{ ext.installedVersion }}</span>
            <span v-if="ext.installedVersion !== ext.defaultVersion" class="ml-1 text-amber-400 font-mono">
              (Available: {{ ext.defaultVersion }})
            </span>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <span
            v-if="ext.requiresPreload && !ext.isPreloaded"
            class="rounded bg-rose-950/60 px-2 py-0.5 text-[10px] text-rose-400 border border-rose-800/40"
          >
            Unpreloaded
          </span>
          <button
            v-if="ext.installedVersion !== ext.defaultVersion"
            @click="emit('update', ext.name, ext.defaultVersion)"
            class="rounded bg-zinc-800 px-2.5 py-1 text-xs font-medium text-zinc-200 hover:bg-zinc-700 transition"
          >
            Update
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
```















