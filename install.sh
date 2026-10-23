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

# Copy Specialized Language & Stack Rules (Modern Cursor .mdc format with globs frontmatter)
for rule_file in "$SCRIPT_DIR"/rules/*.md; do
  rule_name="$(basename "$rule_file" .md)"
  if [ "$rule_name" != "CLAUDE" ]; then
    cp "$rule_file" "$TARGET_DIR/.cursor/rules/${rule_name}.mdc"
  fi
done

# Mirror into .agents/rules for universal agent harnesses (Claude Code, Pi, OpenCode, Windsurf)
cp "$SCRIPT_DIR"/rules/*.md "$TARGET_DIR/.agents/rules/"

# Copy Skills
cp -r "$SCRIPT_DIR/skills/design-system" "$TARGET_DIR/.agents/skills/"
cp -r "$SCRIPT_DIR/skills/code-discipline" "$TARGET_DIR/.agents/skills/"

echo "✅ Done! Injected:"
echo "   - CLAUDE.md (Anti-hallucination & minimal surgical diffs)"
echo "   - .cursorrules & .cursor/rules/*.mdc (Modern modular Cursor rules with glob triggers)"
echo "   - AGENTS.md (Multi-agent collaboration & MCP context protocols)"
echo "   - .agents/rules/* (Go, SQL, Vue/Nuxt, React/Next.js, Rust, Python invariants)"
echo "   - .agents/skills/design-system (Apple/Vercel grade UI aesthetics)"
echo "   - .agents/skills/code-discipline (Industrial verification discipline)"
echo ""
echo "Restart your Claude Code / Cursor / Pi session to activate."
