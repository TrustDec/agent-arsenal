# AGENTS.md - Multi-Agent Harness Architecture & Operational Guide

This document governs the multi-agent collaboration model across AI coding harnesses (Claude Code, Cursor, Pi, Codex, OpenCode).

## Core Principles

1. **Role Specialization**: Agents must not attempt all tasks simultaneously. Split complex work into:
   - **Architect / Researcher**: Gathers context, reads documentation, inspects schemas. Does NOT write code.
   - **Implementer**: Makes targeted edits based strictly on the Architect's plan.
   - **Reviewer / QA**: Runs compilers, unit tests, and security scans. Inspects git diff for unintended changes.

2. **Session Context Management**:
   - Keep conversation history focused.
   - Summarize findings before handing off to implementation.
   - Drop irrelevant file contents from working memory once inspected.

3. **Deterministic Tools Over Generative Guessing**:
   - Use `grep`, `find`, and AST parsers to locate symbols. Never guess line numbers or file locations.
   - Trust tool output above internal priors.
