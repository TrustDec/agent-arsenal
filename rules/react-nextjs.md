---
description: Next.js 14/15 App Router and React strict architectural discipline and hydration safety
globs: **/*.{tsx,jsx,ts,js}
alwaysApply: false
---

# Next.js 14/15 & React Strict Architectural Discipline

> Add these rules to your project if developing in Next.js (App Router) or modern React.

## 1. App Router Client vs Server Boundary
- **Default to Server Components**: Never add `'use client'` at the top of a page or layout unless client interactivity (`useState`, `useEffect`, event listeners, browser APIs) is strictly required.
- **Push Interactivity to the Leaves**: Extract small interactive widgets (e.g. `<FavoriteButton />`, `<SearchBar />`) into dedicated client components rather than turning the whole page into a Client Component.
- **Data Fetching Invariance**: Fetch data directly inside async Server Components via `fetch()` or direct ORM/DB calls. Never wrap server fetches in `useEffect()`.

## 2. Zero-Slop Styling & Hydration Safety
- **Hydration Mismatch Prevention**: Never render date formats, random IDs, or `window`-dependent values directly into HTML during initial render without suppressing hydration warnings or wrapping in a mounted guard.
- **Tailwind Restraint**: Avoid 40-class soup inline. If a pattern repeats across 3 components, extract a semantic component (`<Card>`, `<Badge>`).
- **No Inline Styles for Layout**: Use flex/grid utility classes. Do not use inline `style={{ ... }}` for positioning or layout logic.

## 3. Strict State Invariants
- Avoid redundant state. If a value can be derived from props or existing state, compute it synchronously during render.
- Always provide accessible keys when rendering lists (`key={item.id}`). Never use array index `key={index}` when items can be re-ordered or deleted.
