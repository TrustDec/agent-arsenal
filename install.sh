#!/usr/bin/env bash
# Agent Arsenal - 1-Second Setup for Claude Code, Cursor, Pi & OpenCode
set -e

TARGET_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "⚡ Installing Agent Arsenal rules into: $TARGET_DIR"

# Create destination directories
mkdir -p "$TARGET_DIR/.agents/skills"
mkdir -p "$TARGET_DIR/.agents/rules"
mkdir -p "$TARGET_DIR/.cursor/rules"

# Copy Master Harness Rules
cp "$SCRIPT_DIR/rules/CLAUDE.md" "$TARGET_DIR/CLAUDE.md"
cp "$SCRIPT_DIR/rules/.cursorrules" "$TARGET_DIR/.cursorrules"
cp "$SCRIPT_DIR/templates/AGENTS.md" "$TARGET_DIR/AGENTS.md"

# Copy Specialized Language & Stack Rules
cp "$SCRIPT_DIR/rules/react-nextjs.md" "$TARGET_DIR/.cursor/rules/react-nextjs.md"
cp "$SCRIPT_DIR/rules/rust.md" "$TARGET_DIR/.cursor/rules/rust.md"
cp "$SCRIPT_DIR/rules/python-fastapi.md" "$TARGET_DIR/.cursor/rules/python-fastapi.md"
cp "$SCRIPT_DIR/rules/golang.md" "$TARGET_DIR/.cursor/rules/golang.md"
cp "$SCRIPT_DIR/rules/database-sql.md" "$TARGET_DIR/.cursor/rules/database-sql.md"

# Mirror into .agents/rules for universal agent harnesses
cp "$SCRIPT_DIR"/rules/*.md "$TARGET_DIR/.agents/rules/"

# Copy Skills
cp -r "$SCRIPT_DIR/skills/design-system" "$TARGET_DIR/.agents/skills/"
cp -r "$SCRIPT_DIR/skills/code-discipline" "$TARGET_DIR/.agents/skills/"

echo "✅ Done! Injected:"
echo "   - CLAUDE.md (Anti-hallucination & minimal surgical diffs)"
echo "   - .cursorrules & .cursor/rules/* (Modern multi-rule Cursor support)"
echo "   - AGENTS.md (Multi-agent collaboration & MCP context protocols)"
echo "   - .agents/rules/* (Go, SQL, Rust, React/Next.js, Python invariants)"
echo "   - .agents/skills/design-system (Apple/Vercel grade UI aesthetics)"
echo "   - .agents/skills/code-discipline (Industrial verification discipline)"
echo ""
echo "Restart your Claude Code / Cursor / Pi session to activate."
