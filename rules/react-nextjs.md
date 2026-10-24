---
description: Next.js 14/15 App Router and React strict architectural discipline, Server Actions safety, and hydration invariants
globs: **/*.{tsx,jsx,ts,js}
alwaysApply: false
---

# Next.js 14/15 & React Strict Architectural Discipline

> Add these rules to your project if developing in Next.js (App Router) or modern React 18/19.

## 1. App Router Server vs Client Boundary
- **Default to Server Components (RSC)**:
  - Never add `'use client'` at the top of a page, layout, or data-heavy component unless client interactivity (`useState`, `useEffect`, event listeners, browser-only APIs) is strictly required.
  - Push interactivity to the leaves of the tree. Extract small interactive widgets (e.g. `<FavoriteButton />`, `<SearchBar />`) into dedicated client components rather than turning an entire page or layout into a Client Component.
- **Server Data Fetching Invariant**:
  - Fetch data directly inside async Server Components via `fetch()` or direct ORM/DB calls.
  - ❌ **NEVER** wrap server data fetching in client-side `useEffect()` waterfalls with loading spinners.
  - Use `Suspense` with targeted skeleton fallbacks (`<Suspense fallback={<Skeleton />}>`) to stream slow queries without blocking the initial shell render.
- **Server-Only Package Protection**:
  - In files that access database clients, private API keys, or internal microservices, ALWAYS import `server-only`:
    ```ts
    import 'server-only';
    ```
    This triggers a build-time compiler error if a server module is ever accidentally imported by a Client Component.

## 2. Next.js 15 Async Request APIs & React 19 Alignment
- **Mandatory `await` on Dynamic Request Parameters (Next.js 15)**:
  - In Next.js 15, `params`, `searchParams`, `cookies()`, and `headers()` are asynchronous Promises:
    ```tsx
    // ❌ Broken in Next.js 15: Synchronous access causes runtime warnings/errors
    export default function Page({ params }: { params: { id: string } }) {
      const { id } = params;
    }

    // ✅ Next.js 15 Invariant: Awaited params
    export default async function Page({
      params,
    }: {
      params: Promise<{ id: string }>;
    }) {
      const { id } = await params;
    }
    ```
- **React 19 Action Hooks**:
  - Favor `useActionState` and `useOptimistic` over manual `useState(isLoading)` flags when wiring mutations to Server Actions.

## 3. Server Actions Security & Input Validation
- ❌ **NEVER TREAT SERVER ACTIONS AS TRUSTED PRIVATE CODE**:
  - Server Actions compile down to publicly accessible POST endpoints. Any user can trigger them directly with arbitrary HTTP requests.
  - **Mandatory Authentication & Authorization Guard**: Check user session and permissions at the very top of every Server Action:
    ```ts
    'use server';

    export async function updateProfile(formData: FormData) {
      const session = await auth();
      if (!session?.user) {
        throw new Error('Unauthorized');
      }
      // Validate inputs before DB mutation
    }
    ```
- **Mandatory Input Validation via Zod/Valibot**:
  - Validate all `formData` or action payload arguments through runtime schemas before executing database mutations.
- **Cache Revalidation Discipline**:
  - Call `revalidatePath('/dashboard')` or `revalidateTag('user-profile')` surgically after successful mutations. Never wipe cache indiscriminately.

## 4. Hydration Safety & Zero-AI-Slop Styling
- ❌ **ELIMINATE HYDRATION MISMATCHES**:
  - Never render date formatting (`new Date().toLocaleDateString()`), random IDs (`Math.random()`), or `window`-dependent values directly into HTML during initial SSR.
  - For accessible component IDs, use React's built-in `useId()`.
  - For timestamps that must format on the client, wrap them in a mounted guard or use a dedicated client component with `suppressHydrationWarning` on the specific text element:
    ```tsx
    <time dateTime={date.toISOString()} suppressHydrationWarning>
      {formattedDate}
    </time>
    ```
- **Tailwind & Component Restraint**:
  - Avoid 50-class unreadable string soup in JSX. If a layout pattern, button, or badge repeats across 3 components, extract a semantic component (`<Button variant="primary">`, `<Badge>`).
  - Never use inline styles (`style={{ ... }}`) for positioning or layout logic. Rely on Tailwind utility classes or CSS variables for dynamic values.

## 5. State Invariants & Key Discipline
- **Derived State Over Redundant `useState` + `useEffect`**:
  - Never sync props to state or use `useEffect` to recalculate filtered/sorted lists. Compute derived values synchronously during render or wrap in `useMemo` if computationally expensive.
- **Stable Keys in Dynamic Lists**:
  - Always provide unique, stable keys when rendering collections (`key={item.id}`).
  - ❌ **NEVER** use array indices (`key={index}`) when list items can be re-ordered, filtered, or deleted.

## 6. Server Secret Taint Defense & Non-Blocking Transitions
- **Server Secret Leak Prevention via React Taint APIs**:
  - In React 19 / Next.js 15, protect sensitive tokens, API secrets, and raw user records from accidentally crossing the server-to-client component boundary using React Taint APIs:
    ```ts
    import 'server-only';
    import { experimental_taintUniqueValue, experimental_taintObjectReference } from 'react';

    export async function getSecureUserData(userId: string) {
      const user = await db.user.findUnique({ where: { id: userId } });
      if (!user) return null;

      // ❌ Throws immediate error if this string or object is ever passed to a Client Component
      experimental_taintUniqueValue('Do not leak API key to client', user, user.stripeApiKey);
      experimental_taintObjectReference('Do not pass raw user entity to client', user);

      return user;
    }
    ```
- **Non-Blocking Transitions with `useTransition`**:
  - Wrap route updates, tab switches, and Server Action triggers in `startTransition` to prevent UI freezing:
    ```tsx
    const [isPending, startTransition] = useTransition();

    function handleTabSwitch(tab: string) {
      startTransition(async () => {
        setActiveTab(tab);
        await updateServerPreference(tab);
      });
    }
    ```
  - Keeps the browser responsive to immediate user inputs (clicks, keyboard navigation) while the background transition renders.

## 7. Frontend Taste, Tactile Restraint & Accessible Dialogues
- **Apple/Vercel Aesthetic Restraint**:
  - Deep neutral surfaces (`bg-zinc-950 text-zinc-100 border-zinc-800/60`), subtle 1px micro-borders, and optical kerning (`tracking-tight` on headings).
  - Absolute ban on amateur neon-purple gradients, oversized `rounded-3xl` bubble cards, and fake placeholder text.
  - Tactile interactive feedback: `active:scale-[0.98] transition-all duration-75 ease-out`.
  - Tooltips MUST have an intentional open delay (150–200ms) to prevent visual flashing when sweeping the cursor across dense layouts.
- **Accessible Focus Trap & Keyboard Navigation**:
  - All modal dialogs and slide-over panels MUST trap keyboard focus within the dialog container while mounted.
  - Pressing `Escape` must dismiss the dialog and restore keyboard focus to the originating trigger button.

