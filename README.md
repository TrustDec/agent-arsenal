# Agent Arsenal 🛡️🎨

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/TrustDec/agent-arsenal.svg?style=social)](https://github.com/TrustDec/agent-arsenal)
[![Compatible With](https://img.shields.io/badge/Compatible%20with-Claude%20Code%20%7C%20Cursor%20%7C%20Pi%20%7C%20Codex%20%7C%20Windsurf-emerald.svg)]()

**Production-grade discipline and Apple/Vercel-level aesthetic taste for Coding Agents.**  
*Stop AI hallucinations, breaking diffs, and ugly purple-gradient UI slop in 1 second.*

[English](README.md) | [简体中文](README_zh.md)

</div>

---

## ⚡ The Visual Contrast (Before vs After)

| Default AI Generation (AI Slop) | With Agent Arsenal Injected |
| :--- | :--- |
| ❌ Neon purple/blue linear gradient cards | ✅ Deep Zinc/Slate neutral surfaces with 1px micro-borders |
| ❌ Cluttered `rounded-3xl` bubbly shapes | ✅ Refined 8pt grid, optical kerning & Geist/SF Pro typography |
| ❌ `Lorem Ipsum` and fake placeholder stats | ✅ Realistic domain data, accessible focus rings & tactile feedback |
| ❌ Uncontrolled 200-line diff for 2-line bug | ✅ Surgical 2-line diff; zero untouched code modifications |
| ❌ Uses `unwrap()` or `@ts-ignore` to silence errors | ✅ Root-cause fixes verified by machine compiler & test output |

---

## ✨ Specialized Language & Stack Invariants

Beyond core general rules, `agent-arsenal` includes plug-and-play rules for modern stacks and environments:

- 🐹 **Golang Concurrency & Systems (`rules/golang.md`)**: Context lifecycle propagation, zero goroutine leaks, `go test -race` invariants, explicit error wrapping, and HTTP response body drain requirements.
- 🗄️ **SQL & Database Production Safety (`rules/database-sql.md`)**: Expand-and-contract zero-downtime migrations, `SELECT *` ban in production endpoints, concurrent indexing, short transactions, and zero network I/O inside DB transactions.
- 💚 **Vue 3 & Nuxt 3 (`rules/vue-nuxt.md`)**: Enforces `<script setup lang="ts">`, preserves prop reactivity (`toRefs` invariants), bans `reactive()` reassignment, prevents Nuxt SSR hydration mismatches (zero browser globals in setup), and guarantees Pinia `storeToRefs` & side-effect cleanup.
- 🧡 **Svelte 5 Runes & SvelteKit (`rules/svelte-sveltekit.md`)**: Complete ban on legacy Svelte 3/4 reactive syntax, strict `$state` vs `$state.raw` memory discipline, prohibition of `$effect()` for derived computations, SSR hydration guards, form actions progressive enhancement (`use:enhance`), and universal reactivity safety in `.svelte.ts`.
- ⚛️ **Next.js 14/15 & React (`rules/react-nextjs.md`)**: Enforces App Router Server/Client Component boundaries, eliminates hydration mismatches, and bans client-side waterfall fetches.
- 🦀 **Rust Industrial Safety (`rules/rust.md`)**: Strictly bans `.unwrap()` in production branches, enforces `Result<?>` error propagation, and blocks gratuitous `.clone()` spam.
- 🐍 **Python & FastAPI (`rules/python-fastapi.md`)**: Mandates strict type hints, Pydantic validation, and bans silent `except Exception: pass`.
- 🤖 **Multi-Agent & MCP Protocols (`templates/AGENTS.md`)**: Context window anti-rot discipline, compacted hand-offs, sub-agent isolation, and safe Model Context Protocol (MCP) tool payload constraints.
- 🎯 **Modern Cursor `.mdc` Rules**: All rules include YAML frontmatter (`description`, `globs`, `alwaysApply: false`) ready for Cursor's intelligent auto-attaching rule engine.

---

## ⚡ 1-Second Quick Start

Drop into your current project with one command:

```bash
curl -fsSL https://raw.githubusercontent.com/TrustDec/agent-arsenal/main/install.sh | bash
```

Or copy the files directly into your project root:
- Copy `rules/CLAUDE.md` to `./CLAUDE.md`
- Copy `rules/.cursorrules` to `./.cursorrules` (and stack rules into `./.cursor/rules/*.mdc`)
- Copy `skills/` to `./.agents/skills/`
- Copy `templates/AGENTS.md` to `./AGENTS.md`

---

## 📂 Repository Structure

```text
agent-arsenal/
├── rules/
│   ├── CLAUDE.md           # Master rules for Claude Code & general harnesses
│   ├── .cursorrules        # Optimized rules for Cursor IDE (root fallback)
│   ├── golang.md           # Concurrency, context & Go production discipline
│   ├── database-sql.md     # Zero-downtime migrations & SQL invariants
│   ├── svelte-sveltekit.md # Svelte 5 Runes & SvelteKit SSR invariants
│   ├── vue-nuxt.md         # Vue 3 Composition API & Nuxt 3 SSR invariants
│   ├── react-nextjs.md     # App Router & React invariants
│   ├── rust.md             # Anti-unwrap & Rust safety rules
│   └── python-fastapi.md   # Strict typing & Python invariants
├── skills/
│   ├── design-system/      # Apple/Vercel-level aesthetic taste engine
│   └── code-discipline/    # Staff Engineer verification protocol
├── templates/
│   └── AGENTS.md           # Multi-agent collaboration & MCP context protocols
└── install.sh              # 1-click installer (Cursor .mdc, Claude Code, Pi, OpenCode)
```

---

## 📄 License

MIT © [TrustDec](https://github.com/TrustDec)
