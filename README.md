# Agent Arsenal 🛡️🎨

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/TrustDec/agent-arsenal.svg?style=social)](https://github.com/TrustDec/agent-arsenal)
[![Compatible With](https://img.shields.io/badge/Compatible%20with-Claude%20Code%20%7C%20Cursor%20%7C%20Pi%20%7C%20Codex-emerald.svg)]()

**Production-grade discipline and Apple/Vercel-level aesthetic taste for Coding Agents.**  
*Stop AI hallucinations, breaking diffs, and ugly purple-gradient UI slop in 1 second.*

[English](README.md) | [简体中文](README_zh.md)

</div>

---

## The Problem with Modern Coding Agents

Every developer using **Claude Code, Cursor, Pi, Codex, or OpenCode** faces the same recurring frustrations:

1. **The Over-Engineering Trap**: You ask for a 2-line bug fix; the agent unilaterally refactors 6 unrelated files, re-orders your imports, and deletes existing comments.
2. **Phantom Fixes**: The agent hallucinates that an issue is resolved without compiling or running a single test.
3. **AI Slop UI**: Every frontend the agent generates has the same generic look: oversaturated purple-to-blue linear gradients, rounded-3xl bubbly cards, low contrast gray text, and chaotic spacing.

---

## What Agent Arsenal Injects

`agent-arsenal` gives your coding agents the operational discipline of a **Staff Software Engineer** and the design taste of a **Principal Product Designer**.

### 1. 🛡️ Anti-Hallucination & Code Discipline (`rules/CLAUDE.md`, `.cursorrules`)
- **Minimal Surgical Edits**: Strict invariant that prevents touching unaffected code lines.
- **Empirical Verification**: Forces the agent to compile, lint, and run tests before claiming completion.
- **Zero Phantom Packages**: Prevents inventing fictitious NPM/Cargo/PyPI libraries.

### 2. 🎨 Aesthetic Taste & Design System (`skills/design-system`)
- **Kills Neon Gradients**: Replaces amateur AI palettes with sophisticated zinc/slate neutrals and restrained accent strokes.
- **Typography & Grid**: Enforces strict 8pt rhythm, SF Pro/Geist font stacks, and optical kerning.
- **Tactile Feedback**: Mandates accessible focus rings, active scaling, and realistic mock data (no `Lorem Ipsum`).

### 3. 🤝 Multi-Agent Architecture (`templates/AGENTS.md`)
- Clear role division between Architect (read-only research), Implementer (targeted diffs), and Reviewer (compiler & lint checks).

---

## ⚡ 1-Second Quick Start

Drop into your current project with one command:

```bash
curl -fsSL https://raw.githubusercontent.com/TrustDec/agent-arsenal/main/install.sh | bash
```

Or copy the files directly into your project root:
- Copy `rules/CLAUDE.md` to `./CLAUDE.md`
- Copy `rules/.cursorrules` to `./.cursorrules`
- Copy `skills/` to `./.agents/skills/`

---

## 📂 Repository Structure

```text
agent-arsenal/
├── rules/
│   ├── CLAUDE.md           # Master rules for Claude Code & general harnesses
│   └── .cursorrules        # Optimized rules for Cursor IDE
├── skills/
│   ├── design-system/      # Apple/Vercel-level aesthetic taste engine
│   └── code-discipline/    # Staff Engineer verification protocol
├── templates/
│   └── AGENTS.md           # Multi-agent collaboration protocol
└── install.sh              # 1-click installer
```

---

## 📄 License

MIT © [TrustDec](https://github.com/TrustDec)
