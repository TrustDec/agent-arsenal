---
description: Web performance, Core Web Vitals (INP, LCP, CLS), layout thrashing prevention, asset optimization, and main-thread yielding discipline
globs: **/*.{ts,tsx,js,jsx,vue,svelte,html,css}
alwaysApply: false
---

# Web Performance, Core Web Vitals & Browser Runtime Invariants

> Add these rules to your project if developing in modern web frontends (React, Next.js, Vue, Nuxt, Svelte, SvelteKit, Astro, or vanilla TypeScript/JavaScript) where user interaction responsiveness, search engine rankings (SEO), and smooth 60/120fps rendering are mission-critical.

## 1. Interaction to Next Paint (INP) & Main-Thread Yielding
Google's Core Web Vital INP replaces FID, penalizing any user interaction (clicks, taps, keystrokes) taking >200ms to paint the next frame. AI-generated code notoriously freezes the main thread by executing heavy synchronous loops inside UI handlers.

- ❌ **TOTAL BAN ON BLOCKING LONG TASKS (>50ms) IN EVENT HANDLERS**:
  - Never execute CPU-heavy computations (large array transformations, deep filtering, heavy JSON serialization, complex regular expressions) synchronously inside `onClick`, `onInput`, or form handlers.
- **Yielding to the Browser Scheduler**:
  - Break long-running iterative tasks into chunked slices that yield control back to the browser to render pending frames:
    ```ts
    // Modern scheduler yield with backward-compatible fallback
    export async function yieldToMain(): Promise<void> {
      if ('scheduler' in window && 'yield' in (window as any).scheduler) {
        return (window as any).scheduler.yield();
      }
      return new Promise((resolve) => {
        setTimeout(resolve, 0); // Macrotask queue yields to paint pipeline
      });
    }

    // Process large batch without dropping frames:
    for (let i = 0; i < items.length; i++) {
      processChunk(items[i]);
      if (i % 100 === 0) {
        await yieldToMain();
      }
    }
    ```
- ❌ **NEVER USE `queueMicrotask` TO YIELD TO PAINT**:
  - Microtasks (`Promise.resolve().then(...)`, `queueMicrotask`) execute synchronously before the browser renders the next frame. Yielding with a microtask **DOES NOT** yield to the rendering pipeline and will still trigger an INP violation. Always yield using `scheduler.yield()` or a macrotask (`setTimeout(0)`).
- **Concurrent Transitions for Non-Urgent Updates**:
  - In React, wrap secondary or non-urgent state updates in `startTransition()` so immediate typing and pointer responses remain snappy:
    ```tsx
    const handleSearch = (e: React.ChangeEvent<HTMLInputElement>) => {
      setSearchInput(e.target.value); // Urgent: immediate visual feedback
      startTransition(() => {
        setDeferredQuery(e.target.value); // Non-urgent: can be interrupted
      });
    };
    ```

## 2. Layout Thrashing & Forced Synchronous Reflow
Layout thrashing occurs when JavaScript repeatedly interleaves reading computed geometry properties and writing style changes to the DOM, forcing the browser engine to perform multiple costly synchronous reflows within a single frame.

- ❌ **ABSOLUTE BAN ON INTERLEAVED DOM READ/WRITE LOOPS**:
  - Never read geometry properties right after mutating DOM styles inside a loop:
    ```ts
    // ❌ CATASTROPHIC LAYOUT THRASHING: Forces N full synchronous reflows!
    elements.forEach((el) => {
      const height = el.offsetHeight; // READ (forces synchronous layout)
      el.style.height = `${height + 10}px`; // WRITE (invalidates layout)
    });

    // ✅ BATCH READS FIRST, THEN BATCH WRITES IN ANIMATION FRAME:
    const heights = elements.map((el) => el.offsetHeight); // Batch READ phase
    requestAnimationFrame(() => {
      elements.forEach((el, index) => {
        el.style.height = `${heights[index] + 10}px`; // Batch WRITE phase
      });
    });
    ```
- **Geometry Read Triggers to Guard**:
  - Be vigilant with all layout-triggering properties: `offsetHeight`, `offsetWidth`, `clientHeight`, `clientWidth`, `scrollHeight`, `scrollWidth`, `scrollTop`, `scrollLeft`, `getBoundingClientRect()`, and `window.getComputedStyle()`.
- **CSS Containment & Offscreen Skipping**:
  - Apply `content-visibility: auto` paired with `contain-intrinsic-size` on long scrollable feeds, comments, or cards to instruct the browser engine to completely skip layout and painting for offscreen DOM subtrees:
    ```css
    .feed-card {
      content-visibility: auto;
      contain-intrinsic-size: auto 320px; /* Estimates height to preserve scrollbar accuracy */
    }
    ```

## 3. Cumulative Layout Shift (CLS) Invariants (Threshold < 0.1)
Unreserved layout shifts disorient users, trigger accidental misclicks, and destroy Core Web Vitals scores.

- **Mandatory Explicit Dimensions on All Media**:
  - Every `<img>`, `<video>`, `<canvas>`, and `<iframe>` tag MUST specify explicit `width` and `height` attributes or modern CSS `aspect-ratio` (`aspect-video`, `aspect-square`, `aspect-[4/3]`):
    ```html
    <!-- ✅ Space is reserved before image bytes download: Zero CLS -->
    <img src="/banner.webp" width="1200" height="630" class="w-full h-auto" alt="Banner" />
    ```
- **Dynamic Slot Reservation & Skeleton Matching**:
  - Dynamically injected content (banners, ads, user avatars, async widgets) must have a reserved placeholder wrapper with fixed min-height or exact dimensional bounds matching the loaded content.
- **Font FOUT / FOIS Shift Elimination**:
  - When loading custom web fonts with `font-display: swap`, eliminate layout shifts caused by different font glyph proportions using CSS font metric overrides (`size-adjust`, `ascent-override`, `descent-override`) matching the fallback system font:
    ```css
    @font-face {
      font-family: 'CustomSans-Fallback';
      src: local('Arial');
      size-adjust: 98.5%;
      ascent-override: 95%;
      descent-override: 24%;
    }
    ```
- ❌ **NEVER ANIMATE LAYOUT-TRIGGERING CSS PROPERTIES**:
  - Animate **ONLY** GPU-composited properties: `transform` and `opacity`.
  - ❌ **TOTAL BAN** on transitions/animations involving `top`, `left`, `bottom`, `right`, `width`, `height`, `margin`, or `padding`. Use `transform: translate3d(x, y, 0)` and `transform: scale()` instead.

## 4. Largest Contentful Paint (LCP) & Resource Loading Hierarchy
Target LCP is under 2.5 seconds. The element representing the primary hero content must receive the highest network and execution priority.

- **The LCP Element Invariant**:
  - ❌ **NEVER lazy-load the above-the-fold hero image**: Setting `loading="lazy"` on the main banner or product hero image is a critical production bug.
  - Mark above-the-fold hero images with `fetchpriority="high"` and `loading="eager"`:
    ```html
    <img
      src="/hero-cover.avif"
      fetchpriority="high"
      loading="eager"
      decoding="async"
      width="1280"
      height="720"
      alt="Hero banner"
    />
    ```
- **Preload Critical Assets in `<head>`**:
  - Preload critical hero images and primary brand web fonts in HTML head before CSS parsing discovers them:
    ```html
    <link rel="preload" as="image" href="/hero-cover.avif" fetchpriority="high" />
    <link rel="preload" as="font" type="font/woff2" href="/fonts/inter-latin.woff2" crossorigin />
    ```
- **Preconnect to Critical 3rd-Party Origins**:
  - For external image CDNs, fonts, or analytics, preconnect early to resolve DNS and TLS handshakes in parallel:
    ```html
    <link rel="preconnect" href="https://assets.cdn.example.com" />
    <link rel="dns-prefetch" href="https://assets.cdn.example.com" />
    ```
- **Modern Image Formats**:
  - Serve modern compressed formats: AVIF (primary) -> WebP (fallback) -> Optimized SVG/PNG/JPEG.

## 5. DOM Tree Ceiling & Virtualization
- **DOM Node Budget**:
  - Keep the total DOM tree below **1,500 nodes**.
  - Maximum DOM depth must not exceed **32 levels**.
  - Excessive DOM nodes balloon memory footprint, amplify style recalcs, and trigger scroll stutter.
- **Mandatory Virtualization for Large Collections**:
  - Any list, grid, or table rendering more than **100 records** MUST use windowing/virtualization (e.g., `@tanstack/react-virtual`, `vue-virtual-scroller`, or Svelte windowing):
    ```tsx
    // Virtualize rows to render strictly what fits on the active viewport
    const rowVirtualizer = useVirtualizer({
      count: items.length,
      getScrollElement: () => parentRef.current,
      estimateSize: () => 48,
      overscan: 5,
    });
    ```

## 6. Bundle Optimization & Dynamic Splitting
- **Dynamic Imports at Route & Modal Boundaries**:
  - Never import massive third-party libraries (Monaco Editor, Chart.js, Leaflet, Lottie, PDF.js, Highlight.js) statically in the root bundle.
  - Dynamically import heavy components on demand when the user interacts or mounts the view:
    ```tsx
    const RichTextEditor = React.lazy(() => import('@/components/RichTextEditor'));
    // Or in Vue:
    const MonacoEditor = defineAsyncComponent(() => import('@/components/MonacoEditor.vue'));
    ```
- ❌ **BAN ON BARREL FILE RE-EXPORT POLLUTION**:
  - Importing from index barrel files (`import { Check } from 'lucide-react'` or `import { debounce } from 'lodash'`) can inadvertently pull megabytes of unused code into client bundles when tree-shaking fails.
  - Prefer direct submodule imports (`import Check from 'lucide-react/dist/esm/icons/check'` or `import debounce from 'lodash-es/debounce'`) or configure package bundler optimizePackageImports (Next.js / Vite).

## 7. Memory Leak & Detached DOM Prevention
Single-page applications (SPAs) run indefinitely without full page refreshes. Dangling references cause detached DOM trees, steadily exhausting browser RAM until the tab crashes.

- **Symmetrical Observer & Listener Teardowns**:
  - Every `addEventListener`, `ResizeObserver`, `IntersectionObserver`, and `MutationObserver` MUST have an explicit `removeEventListener` / `.disconnect()` in component unmount (`useEffect` cleanup, `onUnmounted()`, `$effect` teardown).
- **AbortController for Async Flight Invariants**:
  - Cancel pending asynchronous network calls or SSE streams when a component unmounts to prevent state mutations on detached components:
    ```ts
    useEffect(() => {
      const controller = new AbortController();
      fetchUserData({ signal: controller.signal });
      return () => controller.abort();
    }, [userId]);
    ```
- **Clear Timer & Animation Frame Identifiers**:
  - Always store and cancel timer IDs: `clearTimeout(timerId)`, `clearInterval(intervalId)`, and `cancelAnimationFrame(rafId)`.
