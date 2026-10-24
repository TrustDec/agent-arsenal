# Agent Arsenal 🛡️🎨

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/TrustDec/agent-arsenal.svg?style=social)](https://github.com/TrustDec/agent-arsenal)
[![兼容生态](https://img.shields.io/badge/兼容生态-Claude%20Code%20%7C%20Cursor%20%7C%20Windsurf%20%7C%20Copilot%20%7C%20Cline%20%7C%20Pi-emerald.svg)]()

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

- 🧪 **测试工程规范与反脆弱验证守则 (`rules/testing-discipline.md`)**：全面严禁硬编码 `sleep` 随缘等待（强制条件轮询与 Fake Timers 虚拟时间推进）、基于事务 Rollback 与独立数据库实例根治测试状态互相污染、坚决打击“给 Mock 写测试”的伪测试反模式、强制核心业务配备表驱动测试（Table-Driven）与边界极限值矩阵覆盖、严禁未 `await` 的浮动异步断言，以及多协程/线程竞争检测（`-race`）。
- 🚀 **CI/CD 自动化与 GitHub Actions 安全守则 (`rules/cicd-github-actions.md`)**：第三方 Actions 强制 40 位完整 SHA Hash 锁定（防语义化版本标签篡改发动供应链投毒）、全面根除 Bash 行内直接插值 `${{ github.event... }}` 导致的远程命令注入重大漏洞、强制顶层 `permissions: contents: read` 最小权限原则、严防 `pull_request_target` 触发器下检出不可信 Fork PR 代码导致仓库密钥泄露的著名安全陷阱，以及全链路 OIDC 短期凭证置换。
- 🌐 **高可用 API 设计与分布式系统规范 (`rules/api-distributed-systems.md`)**：强制状态变更接口幂等性规范（`Idempotency-Key` 原子预占与 SHA-256 请求体哈希校验防篡改）、全抖动指数退避根绝重试风暴（Thundering Herd）、熔断器状态机（Closed/Open/Half-Open 探针机制）、W3C `traceparent` 与 OpenTelemetry 分布式链路追踪透传、基于事务性发件箱（Transactional Outbox）根除双写数据不一致灾难、RFC 7807 Problem Details 统一错误响应，以及分布式滑动窗口限流与优雅过载保护。
- 🧠 **AI、LLM 应用与 RAG 检索增强生产级规范 (`rules/ai-llm-rag.md`)**：强制原生 Structured Outputs / JSON Schema 结构化提取与单轮自愈机制、严禁无脑固定字符切割（强制 Markdown/AST 语义边界切分）、混合检索（向量密集检索 + BM25 稀疏词法检索经 RRF 融合）、Cross-Encoder 精准重排、RAG 注入隔离边界（XML 显式防间接提示词注入）、严格 Token 窗口预算、全抖动指数退避抗 429 限流与 SSE 流式连接断开即时中止上游。
- 🛡️ **应用安全与 OWASP 防御规范 (`rules/security-appsec.md`)**：严打 Agent 随手写出的 SSRF 漏洞（强制 DNS 预解析与内网私有 IP/云元数据 169.254 封禁）、命令拼接与 Shell 注入绝对防御、SQL 参数化与动态列白名单校验、路径遍历根目录规范校验、密码/签名常量时间比较（`timingSafeEqual` 防时序侧信道攻击）、CSPRNG 密码学安全随机数与 ReDoS 正则灾难性回溯免疫。
- 🐳 **Docker 与容器化生产级规范 (`rules/docker-containers.md`)**：强制多阶段构建（Multi-Stage）收敛攻击面（`distroless`/`alpine`）、生产环境严禁 root 用户运行（`USER nonroot`）、PID 1 信号转发与轻量 Init（`tini`/Exec 格式）杜绝优雅关机超时死进程、BuildKit Secret 挂载防密钥硬编码至镜像层、同层包管理器缓存清理与真实健康检查。
- 🔌 **Model Context Protocol (MCP) 服务端与工具规范 (`rules/mcp-server.md`)**：全面严禁 stdio 传输下的 `stdout` 杂质输出（`console.log` / `print` 会彻底打崩 JSON-RPC 字节流致客户端断联）、工具入参强制配备详尽 Schema `description` 引导 Agent 决策、严格上限控制与分页防 Context 爆炸、错误统一走 `{ isError: true }` 优雅降级，以及路径遍历白名单与 Shell 注入绝对防御。
- 🔷 **TypeScript 与 Node.js/Bun 生产级规范 (`rules/typescript.md`)**：全面严禁 `any` 与未经校验的暴力断言（`as T`）、I/O 边界强制使用 Zod/运行时 Schema 校验、根绝浮动 Promise（Floating Promise）、严禁非空断言感叹号（`!`）、强制可辨识联合类型（Discriminated Unions）消除不可能状态、防范 Node/Bun 事件监听器泄露与无上限 Map 内存暴涨。
- 🐹 **Golang 并发与系统工程 (`rules/golang.md`)**：强制 `context.Context` 规范传递、`errgroup` 协同工作与严防 Goroutine 泄露、切片子切片内存截留排查、测试必带 `go test -race`、HTTP 响应体关闭前 Drain 排水排查、错误使用 `%w` 与 `errors.Is/As` 保持因果链、生产代码零 panic 与优雅停机。
- 🗄️ **SQL 与数据库生产级安全 (`rules/database-sql.md`)**：严守 Expand & Contract 零停机迁移法、生产接口严禁 `SELECT *`、复合索引最左前缀原则、软删除部分索引（Partial Index）、PostgreSQL 并发建索引、SQL 参数化防注入、超短事务与严禁事务内发起网络 I/O。
- 💚 **Vue 3 与 Nuxt 3 响应式与 SSR 严苛守则 (`rules/vue-nuxt.md`)**：强制 `<script setup lang="ts">`、适配 Vue 3.5+ 响应式 Props 解构与 `useTemplateRef()`、使用 `onWatcherCleanup()` 规范清理、严禁覆写 `reactive()` 对象引用、绝对严禁在 Nuxt SSR 模块作用域声明可变状态（根治多租户跨请求数据串扰重大漏洞）、Nitro 服务端接口强制 `readValidatedBody` 运行时校验、Pinia 状态解构必配 `storeToRefs` 与生命周期副作用必须卸载。
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
- 复制 `rules/CLAUDE.md` 到你的项目根目录（以及 `./.windsurfrules`, `./.clinerules`, `./.github/copilot-instructions.md`）
- 复制 `rules/.cursorrules` 到你的项目根目录（或将规则作为 `.mdc` 存入 `.cursor/rules/`）
- 复制 `skills/` 到你的 `.agents/skills/`
- 复制 `templates/AGENTS.md` 到你的 `AGENTS.md`

---

## 📂 仓库目录结构

```text
agent-arsenal/
├── rules/
│   ├── CLAUDE.md           # Claude Code, Windsurf, Copilot, Cline 主规则
│   ├── .cursorrules        # Cursor 经典根目录规则
│   ├── testing-discipline.md # 测试工程规范、防 Flaky 与反伪测试准则
│   ├── cicd-github-actions.md # Actions 供应链加固、命令注入免疫与 CI 安全
│   ├── api-distributed-systems.md # 高可用 API 设计、幂等性与分布式追踪规范
│   ├── ai-llm-rag.md       # AI, LLM 应用、RAG 检索增强与向量检索规范
│   ├── security-appsec.md  # 应用安全、SSRF 防御与 OWASP 严苛守则
│   ├── docker-containers.md# 容器化多阶段构建、无 root 运行与优雅停机规范
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
└── install.sh              # 1 键极速安装脚本（支持 Cursor, Claude Code, Windsurf, Copilot 等）
```

---

## 📄 开源协议

MIT © [TrustDec](https://github.com/TrustDec)
