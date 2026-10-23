# Agent Arsenal 🛡️🎨

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/TrustDec/agent-arsenal.svg?style=social)](https://github.com/TrustDec/agent-arsenal)
[![兼容生态](https://img.shields.io/badge/兼容生态-Claude%20Code%20%7C%20Cursor%20%7C%20Pi%20%7C%20Codex-emerald.svg)]()

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

除了通用的防幻觉规则外，现已全面补充特定技术栈的即插即用规范：

- ⚛️ **Next.js 14/15 与 React (`rules/react-nextjs.md`)**：严格划分 App Router 服务端组件与客户端组件边界，根除 Hydration 水合不匹配与客户端瀑布流请求。
- 🦀 **Rust 工业级安全 (`rules/rust.md`)**：生产代码严禁 `.unwrap()` / `.expect()`，强制 `Result<?>` 错误向上传播，杜绝为了通过编译而疯狂 `.clone()`。
- 🐍 **Python 与 FastAPI (`rules/python-fastapi.md`)**：强制全函数类型注解（Type Hints）、严格 Pydantic 校验，严禁静默吞掉报错的 `except Exception: pass`。

---

## ⚡ 1 秒极速集成

在你的项目根目录下执行：

```bash
curl -fsSL https://raw.githubusercontent.com/TrustDec/agent-arsenal/main/install.sh | bash
```

或者直接按需复制到你的项目：
- 复制 `rules/CLAUDE.md` 到你的项目根目录
- 复制 `rules/.cursorrules` 到你的项目根目录
- 复制 `skills/` 到你的 `.agents/skills/`

---

## 📄 开源协议

MIT © [TrustDec](https://github.com/TrustDec)
