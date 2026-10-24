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

