---
description: Vue 3 & Nuxt 3 strict reactivity discipline, Composition API, and SSR hydration safety
globs: **/*.{vue,ts,js}
alwaysApply: false
---

# Vue 3 & Nuxt 3 Strict Reactivity & SSR Discipline

> Add these rules to your project if developing in Vue 3 (Vite / Nuxt 3) with TypeScript.

## 1. Composition API & Script Setup Invariants
- **Exclusively Use `<script setup lang="ts">`**: Strictly ban Vue 2 Options API (`export default { data(), methods: {} }`) in modern codebases.
- ❌ **PREVENT REACTIVITY LOSS ON PROPS**:
  - Never destructure props directly (`const { user, count } = defineProps<Props>()`) without `toRefs(props)` or Vue 3.5+ reactive props destructure syntax.
  - Doing so permanently disconnects the local variable from the reactive dependency graph.
- **`ref()` vs `reactive()` Discipline**:
  - Prefer `ref()` for discrete state variables and primitives.
  - **NEVER reassign a `reactive()` object**: `state = { ... }` destroys the original reactive proxy and breaks template tracking. Always mutate properties or use `Object.assign(state, payload)`.
- **`shallowRef()` for Heavy 3rd-Party Instances**:
  - Always use `shallowRef()` or `markRaw()` for complex non-Vue instances (Three.js objects, Monaco Editor, Leaflet/Mapbox maps, ECharts, Web Audio nodes).
  - Deep reactivity proxies on large external objects cause catastrophic memory and CPU overhead.

## 2. Nuxt 3 SSR & Hydration Hygiene
- ❌ **ZERO BROWSER GLOBALS IN SETUP ROOT**:
  - Never reference `window`, `document`, `localStorage`, `sessionStorage`, or `navigator` in the setup root execution scope.
  - Wrap client-only code in `onMounted()`, `if (import.meta.client)`, or enclose components in `<ClientOnly>`.
- **Data Fetching Invariance**:
  - Always use Nuxt composables (`useFetch()` or `useAsyncData()`) for data loaded during page rendering.
  - ❌ **NEVER use raw `axios` or bare `fetch()` inside setup root**: Bare calls run once on the server and again during client hydration, creating unnecessary waterfalls and DOM hydration mismatches.
  - Always supply a unique, deterministic key to `useAsyncData('user-profile', ...)` when dynamic route parameters or pagination are involved.
- **Head & SEO Management**:
  - Use `useHead()` or `useSeoMeta()` reactively. Never inject raw meta/script tags into the DOM via raw JavaScript strings.

## 3. Lifecycle Hygiene & Memory Leak Prevention
- **Mandatory Side-Effect Cleanup**:
  - Every timer (`setInterval`, `setTimeout`), event listener (`window.addEventListener`), WebSocket subscription, or observer (`ResizeObserver`, `IntersectionObserver`) started in `onMounted()` MUST be cleanly unregistered in `onUnmounted()` or `onBeforeUnmount()`.
- **Async Watcher Cleanup**:
  - When watching search inputs or filter changes with asynchronous API calls, use the `onCleanup` callback to abort in-flight requests before starting a new search:
    ```ts
    watch(searchQuery, (newQuery, _, onCleanup) => {
      const controller = new AbortController()
      onCleanup(() => controller.abort())
      fetchResults(newQuery, { signal: controller.signal })
    })
    ```

## 4. Pinia State Management Invariants
- **Setup Stores Syntax**: Prefer the Composition API syntax (`defineStore('user', () => { ... })`) for clean composable interoperability.
- ❌ **MANDATORY `storeToRefs`**:
  - When destructuring state or getters from a Pinia store in components, ALWAYS use `storeToRefs(store)`:
    ```ts
    const userStore = useUserStore()
    const { profile, isAuthenticated } = storeToRefs(userStore) // ✅ Preserves reactivity
    const { logout } = userStore // ✅ Actions can be destructured directly
    ```
