# Agent Arsenal 🛡️🎨

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/TrustDec/agent-arsenal.svg?style=social)](https://github.com/TrustDec/agent-arsenal)
[![兼容生态](https://img.shields.io/badge/兼容生态-Claude%20Code%20%7C%20Cursor%20%7C%20Pi%20%7C%20Codex%20%7C%20Windsurf-emerald.svg)]()

**专为 Coding Agents 打造的工业级工程防暴走规范与审美设计系统。**  
*一秒终结 AI 瞎改文件、虚假修复、以及高饱和土味渐变 UI。*

[English](README.md) | [简体中文](README_zh.md)

</div>

---

## ⚡ 效果对比（Before vs After）

| 默认 AI 生成状态（AI 糊弄） | 注入 Agent Arsenal 之后 |
| :--- | :--- |
| ❌ 高饱和刺眼紫蓝渐变背景卡片 | ✅ 纯正深 Zinc/Slate 优雅中性色 + 1px 精致微边框 |
| ❌ 臃肿滑稽的 `rounded-3xl` 大圆角堆叠 | ✅ 严苛 8pt 网格对齐、光学字偶距微调与 Geist/SF Pro 现代排版 |
| ❌ 满屏 `Lorem Ipsum` 和假数据 | ✅ 贴合真实生产业务的数据语义、按压微交互与可访问性焦点环 |
| ❌ 修 2 行 bug 造成 200 行污染 Diff | ✅ 外科手术式修改，无辜代码行 0 变动 |
| ❌ 遇到报错无脑用 `unwrap()` 或 `@ts-ignore` 掩盖 | ✅ 机器真实验证（编译/测试），根因排查彻底修复 |

---

## ✨ 垂直技术栈专属严苛规范

除了通用的防幻觉规则外，现已全面补充主流技术栈与现代协议规范：

- 🔌 **Model Context Protocol (MCP) 服务端与工具规范 (`rules/mcp-server.md`)**：全面严禁 stdio 传输下的 `stdout` 杂质输出（`console.log` / `print` 会彻底打崩 JSON-RPC 字节流致客户端断联）、工具入参强制配备详尽 Schema `description` 引导 Agent 决策、严格上限控制与分页防 Context 爆炸、错误统一走 `{ isError: true }` 优雅降级，以及路径遍历白名单与 Shell 注入绝对防御。
- 🔷 **TypeScript 与 Node.js/Bun 生产级规范 (`rules/typescript.md`)**：全面严禁 `any` 与未经校验的暴力断言（`as T`）、I/O 边界强制使用 Zod/运行时 Schema 校验、根绝浮动 Promise（Floating Promise）、严禁非空断言感叹号（`!`）、强制可辨识联合类型（Discriminated Unions）消除不可能状态、防范 Node/Bun 事件监听器泄露与无上限 Map 内存暴涨。
- 🐹 **Golang 并发与系统工程 (`rules/golang.md`)**：强制 `context.Context` 规范传递、严防 Goroutine 泄露、测试必带 `go test -race`、HTTP 响应体关闭前 Drain 排水排查、错误严格包装与生产代码零 panic。
- 🗄️ **SQL 与数据库生产级安全 (`rules/database-sql.md`)**：严守 Expand & Contract 零停机迁移法、生产接口严禁 `SELECT *`、外键与筛选列强制索引、PostgreSQL 并发建索引、超短事务与严禁事务内发起网络 I/O。
- 💚 **Vue 3 与 Nuxt 3 响应式与 SSR 严苛守则 (`rules/vue-nuxt.md`)**：强制 `<script setup lang="ts">`、严禁直接解构 Props（丢失响应式）、严禁覆写 `reactive()` 对象引用、消灭 Nuxt SSR 水合不匹配（Setup 严禁访问浏览器全局变量）、Pinia 状态解构必配 `storeToRefs` 与生命周期副作用必须卸载。
- 🧡 **Svelte 5 Runes 与 SvelteKit 生产级守则 (`rules/svelte-sveltekit.md`)**：全面废弃 Svelte 3/4 旧语法，强制使用 Svelte 5 符文（Runes: `$state`, `$derived`, `$props`），严禁滥用 `$effect()` 造成多轮重渲染/死循环，消灭 SSR 水合不匹配，原生 Form Actions 渐进增强（`use:enhance`）与 `.svelte.ts` 模块级防 SSR 用户间数据泄漏。
- ⚛️ **Next.js 14/15 与 React 生产架构 (`rules/react-nextjs.md`)**：严格划分 App Router 服务端组件与客户端组件边界、适配 Next.js 15 异步请求 API（`await params`）、强制 `server-only` 防密钥泄露、Server Actions 权限与 Zod 校验，根除 Hydration 水合不匹配。
- 🦀 **Rust 工业级安全与 Tokio 异步规范 (`rules/rust.md`)**：生产代码严禁 `.unwrap()` / `.expect()`，强制 `Result<?>` 错误向上传播、严禁在 Tokio 异步工作线程中执行阻塞式计算与 I/O、跨 await 锁规范，杜绝无脑 `.clone()`。
- 🐍 **Python 与 FastAPI (`rules/python-fastapi.md`)**：强制全函数类型注解（Type Hints）、严格 Pydantic 校验，严禁静默吞掉报错的 `except Exception: pass`。
- 🤖 **多 Agent 协同与 MCP 协议 (`templates/AGENTS.md`)**：防 Context 衰减与膨胀机制、压缩式信息交接、Sub-agent 隔离，以及 Model Context Protocol (MCP) 工具调用与数据安全约束。
- 🎯 **原生支持现代化 Cursor `.mdc` 规则引擎**：所有规则均自带 YAML Frontmatter（包含 `globs` 自动匹配与 `description`），支持智能按需挂载。

---

## ⚡ 1 秒极速集成

在你的项目根目录下执行：

```bash
curl -fsSL https://raw.githubusercontent.com/TrustDec/agent-arsenal/main/install.sh | bash
```

或者直接按需复制到你的项目：
- 复制 `rules/CLAUDE.md` 到你的项目根目录
- 复制 `rules/.cursorrules` 到你的项目根目录（或将规则作为 `.mdc` 存入 `.cursor/rules/`）
- 复制 `skills/` 到你的 `.agents/skills/`
- 复制 `templates/AGENTS.md` 到你的 `AGENTS.md`

---

## 📂 仓库目录结构

```text
agent-arsenal/
├── rules/
│   ├── CLAUDE.md           # Claude Code 与通用 Harness 主规则
│   ├── .cursorrules        # Cursor 经典根目录规则
│   ├── mcp-server.md       # Model Context Protocol (MCP) 服务端与工具生产规范
│   ├── typescript.md       # 严格类型、运行时校验与 Node/Bun 生产准则
│   ├── golang.md           # Go 并发安全、生命周期与系统级规范
│   ├── database-sql.md     # 数据库零停机迁移、索引与事务准则
│   ├── svelte-sveltekit.md # Svelte 5 Runes 与 SvelteKit 生产规范
│   ├── vue-nuxt.md         # Vue 3 响应式规范与 Nuxt 3 SSR 准则
│   ├── react-nextjs.md     # Next.js 15 App Router 与 Server Actions 生产边界
│   ├── rust.md             # Rust 工业级安全、Tokio 异步与反 unwrap 守则
│   └── python-fastapi.md   # Python 严格类型提示与 FastAPI 生产规范
├── skills/
│   ├── design-system/      # Apple/Vercel 级审美与 UI 设计系统
│   └── code-discipline/    # Staff Engineer 外科手术式工程验证协议
├── templates/
│   └── AGENTS.md           # 多 Agent 协同编排与 MCP 上下文管理规范
└── install.sh              # 1 键极速安装脚本（支持 Cursor .mdc, Claude Code, Pi 等）
```

---

## 📄 开源协议

MIT © [TrustDec](https://github.com/TrustDec)
