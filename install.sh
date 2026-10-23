#!/usr/bin/env bash
# Agent Arsenal - 1-Second Setup for Claude Code, Cursor, Pi & OpenCode
set -e

TARGET_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
TEMP_DIR=""

cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

# Check if running from local repository checkout or via piped curl
if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/rules" ] && [ -d "$SCRIPT_DIR/skills" ]; then
  SOURCE_DIR="$SCRIPT_DIR"
else
  echo "🌐 Remote installation detected. Fetching latest Agent Arsenal release..."
  TEMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'agent-arsenal')"
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 https://github.com/TrustDec/agent-arsenal.git "$TEMP_DIR" --quiet
  else
    curl -fsSL https://github.com/TrustDec/agent-arsenal/archive/refs/heads/main.tar.gz | tar -xz -C "$TEMP_DIR" --strip-components=1
  fi
  SOURCE_DIR="$TEMP_DIR"
fi

echo "⚡ Installing Agent Arsenal rules into: $TARGET_DIR"

# Create destination directories
mkdir -p "$TARGET_DIR/.agents/skills"
mkdir -p "$TARGET_DIR/.agents/rules"
mkdir -p "$TARGET_DIR/.cursor/rules"

# Copy Master Harness Rules
cp "$SOURCE_DIR/rules/CLAUDE.md" "$TARGET_DIR/CLAUDE.md"
cp "$SOURCE_DIR/rules/.cursorrules" "$TARGET_DIR/.cursorrules"
cp "$SOURCE_DIR/templates/AGENTS.md" "$TARGET_DIR/AGENTS.md"

# Copy Specialized Language & Stack Rules (Modern Cursor .mdc format with globs frontmatter)
for rule_file in "$SOURCE_DIR"/rules/*.md; do
  rule_name="$(basename "$rule_file" .md)"
  if [ "$rule_name" != "CLAUDE" ]; then
    cp "$rule_file" "$TARGET_DIR/.cursor/rules/${rule_name}.mdc"
  fi
done

# Mirror into .agents/rules for universal agent harnesses (Claude Code, Pi, OpenCode, Windsurf)
cp "$SOURCE_DIR"/rules/*.md "$TARGET_DIR/.agents/rules/"

# Copy Skills
cp -r "$SOURCE_DIR/skills/design-system" "$TARGET_DIR/.agents/skills/"
cp -r "$SOURCE_DIR/skills/code-discipline" "$TARGET_DIR/.agents/skills/"

echo "✅ Done! Injected:"
echo "   - CLAUDE.md (Anti-hallucination & minimal surgical diffs)"
echo "   - .cursorrules & .cursor/rules/*.mdc (Modern modular Cursor rules with glob triggers)"
echo "   - AGENTS.md (Multi-agent collaboration & MCP context protocols)"
echo "   - .agents/rules/* (TypeScript, Go, SQL, Svelte 5/Kit, Vue/Nuxt, React/Next.js, Rust, Python)"
echo "   - .agents/skills/design-system (Apple/Vercel grade UI aesthetics)"
echo "   - .agents/skills/code-discipline (Industrial verification discipline)"
echo ""
echo "Restart your Claude Code / Cursor / Pi session to activate."
