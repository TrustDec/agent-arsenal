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

## 解决的核心痛点

所有用 **Claude Code, Cursor, Pi, Codex, OpenCode** 写代码的开发者，每天都在被这三件事折磨：

1. **自作主张瞎改**：让你修一个 2 行的 bug，AI 顺手把你 6 个无关文件的格式重排一遍，删掉你原有的注释，甚至引入一个庞大的外部依赖；
2. **假装修复（幻觉）**：没跑编译、没跑测试，信誓旦言说“已为您修复”，结果一运行全是报错；
3. **一眼 AI 味的土味 UI**：只要让 AI 写前端，永远是千篇一律的高饱和紫蓝渐变、巨大圆角的土气卡片、对比度极低的灰色字体。

---

## Agent Arsenal 注入的两大超能力

### 1. 🛡️ 工业级工程戒律 (`rules/CLAUDE.md`, `.cursorrules`, `skills/code-discipline`)
- **外科手术式修改**：严禁碰无关代码行，保持 Git Diff 干净最小化；
- **机器真实验证**：禁止用 `@ts-ignore` 或空 `catch` 掩盖错误，任务完成前必须跑通编译/测试；
- **拒绝虚构库**：禁止捏造不存在的 NPM/Cargo/PyPI 函数或参数。

### 2. 🎨 顶级审美设计系统 (`skills/design-system`)
- **终结廉价渐变**：切换为现代深 Zinc/Slate 中性色基底与精致的 1px 微边框；
- **排版与间距**：严格对齐 8pt 网格与 Geist/SF Pro 现代无衬线字体；
- **真实感交互**：自带按压微动效、可访问性焦点环，彻底告别 `Lorem Ipsum` 假数据。

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
