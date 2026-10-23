---
name: design-system
description: Elevate AI-generated frontend UI/UX from generic 'AI slop' to production-grade, Apple/Vercel-level aesthetic taste. Use whenever generating HTML, React, Vue, Tailwind, CSS, or modern Web UI.
---

# Design System & Aesthetic Taste Engine for Coding Agents

By default, LLMs generate generic, outdated UI: neon purple-blue gradients, rounded-3xl cards everywhere, low-contrast gray text, and chaotic spacing.

This skill forces modern, human-crafted design intelligence into every component you build.

---

## 1. PALETTE PHILOSOPHY (Kill the Neon AI Slop)

### ❌ What to AVOID:
- Saturated linear purple-to-blue gradients (`from-purple-600 to-indigo-600`) as background hero elements.
- Random pastel card backgrounds.
- Pure black (`#000000`) on harsh white (`#ffffff`).

### ✅ What to USE:
- **Base Neutrals**:
  - Dark mode: True zinc/slate deep slate (`#09090b`, `#18181b`, `#27272a`).
  - Light mode: Warm stone or crisp off-white (`#fafafa`, `#f4f4f5`, `#e4e4e7`).
- **Accents**:
  - A single, restrained accent color (e.g. International Klein Blue, emerald `#10b981`, or safety amber).
  - High contrast ratio (WCAG AAA compliant): text should be readable without eye strain.
- **Surface Elevation**:
  - Distinguish layers with subtle 1px border strokes (`border border-white/10` or `border-zinc-200`) rather than heavy drop shadows.

---

## 2. TYPOGRAPHY HIERARCHY

- **Font Stacks**: Use modern geometric or neutral sans:
  - System sans: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Geist", "Inter", sans-serif`.
  - Code/Mono: `"Geist Mono", "JetBrains Mono", "SF Mono", monospace`.
- **Rhythm**:
  - Clear scale: 12px (micro), 14px (secondary), 16px (body), 20px (subhead), 28px/36px (title).
  - Tracking: Tighter letter-spacing on large headings (`tracking-tight`), normal or slightly open on small uppercase labels (`tracking-wider text-xs uppercase`).
  - Line-height: Tight on headings (`leading-tight`), generous on body text (`leading-relaxed`).

---

## 3. SPACING & MICRO-INTERACTIONS

- **Spacing Grid**: Stick strictly to an 8pt/4pt grid system (`gap-2`, `gap-4`, `p-6`, `p-8`).
- **Border Radius**:
  - Avoid bubbly `rounded-3xl` on everything.
  - Buttons & Inputs: `rounded-md` (6px) or `rounded-lg` (8px).
  - Modals & Cards: `rounded-xl` (12px) to `rounded-2xl` (16px).
- **Hover & Focus States**:
  - Every interactive element MUST have tactile feedback: `transition-all duration-150 active:scale-[0.98]`.
  - Visible, accessible focus rings: `focus-visible:ring-2 focus-visible:ring-offset-2`.

---

## 4. CONTENT DENSITY & REALISM

- **Realistic Mock Content**:
  - NEVER use `Lorem Ipsum dolor sit amet` or `User 123`.
  - Use realistic domain data: real company names, ISO dates (`2026-04-14`), plausible metrics (`$12,450.00`, `99.98% uptime`).
- **Empty & Error States**:
  - Always design the zero-data state with a helpful illustration/icon and a clear primary Call To Action.
