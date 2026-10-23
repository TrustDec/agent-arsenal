#!/usr/bin/env bash
# Agent Arsenal - 1-Second Setup for Claude Code, Cursor, Pi & OpenCode
set -e

TARGET_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "⚡ Installing Agent Arsenal rules into: $TARGET_DIR"

mkdir -p "$TARGET_DIR/.agents/skills"

# Copy Rules
cp "$SCRIPT_DIR/rules/CLAUDE.md" "$TARGET_DIR/CLAUDE.md"
cp "$SCRIPT_DIR/rules/.cursorrules" "$TARGET_DIR/.cursorrules"
cp "$SCRIPT_DIR/templates/AGENTS.md" "$TARGET_DIR/AGENTS.md"

# Copy Skills
cp -r "$SCRIPT_DIR/skills/design-system" "$TARGET_DIR/.agents/skills/"
cp -r "$SCRIPT_DIR/skills/code-discipline" "$TARGET_DIR/.agents/skills/"

echo "✅ Done! Injected:"
echo "   - CLAUDE.md (Anti-hallucination & minimal surgical diffs)"
echo "   - .cursorrules (Cursor Staff Engineer persona)"
echo "   - AGENTS.md (Multi-agent collaboration protocol)"
echo "   - .agents/skills/design-system (Apple/Vercel grade UI aesthetics)"
echo "   - .agents/skills/code-discipline (Industrial verification discipline)"
echo ""
echo "Restart your Claude Code / Cursor session to activate."
