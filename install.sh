#!/usr/bin/env bash
# Agent Arsenal - 1-Second Setup for Claude Code, Cursor, Windsurf, Copilot, Cline, Pi & OpenCode
set -euo pipefail

TARGET_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
TEMP_DIR=""

cleanup() {
  local exit_code=$?
  if [ -n "${TEMP_DIR:-}" ] && [ -d "${TEMP_DIR:-}" ]; then
    rm -rf "${TEMP_DIR}"
  fi
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

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
mkdir -p "$TARGET_DIR/.github"

# Copy Master Harness Rules
cp "$SOURCE_DIR/rules/CLAUDE.md" "$TARGET_DIR/CLAUDE.md"
cp "$SOURCE_DIR/rules/.cursorrules" "$TARGET_DIR/.cursorrules"
cp "$SOURCE_DIR/templates/AGENTS.md" "$TARGET_DIR/AGENTS.md"

# Universal Harness Mirrors (Windsurf, Cline/Roo Code, GitHub Copilot)
cp "$SOURCE_DIR/rules/CLAUDE.md" "$TARGET_DIR/.windsurfrules"
cp "$SOURCE_DIR/rules/CLAUDE.md" "$TARGET_DIR/.clinerules"
cp "$SOURCE_DIR/rules/CLAUDE.md" "$TARGET_DIR/.github/copilot-instructions.md"

# Copy Specialized Language & Stack Rules (Modern Cursor .mdc format with globs frontmatter)
for rule_file in "$SOURCE_DIR"/rules/*.md; do
  rule_name="$(basename "$rule_file" .md)"
  if [ "$rule_name" != "CLAUDE" ]; then
    cp "$rule_file" "$TARGET_DIR/.cursor/rules/${rule_name}.mdc"
  fi
done

# Mirror into .agents/rules for universal agent harnesses (Claude Code, Pi, OpenCode, Windsurf)
cp "$SOURCE_DIR"/rules/*.md "$TARGET_DIR/.agents/rules/"

# Copy Skills dynamically
for skill_dir in "$SOURCE_DIR/skills"/*; do
  if [ -d "$skill_dir" ]; then
    cp -r "$skill_dir" "$TARGET_DIR/.agents/skills/"
  fi
done

echo "✅ Done! Injected:"
echo "   - CLAUDE.md & .cursorrules (Anti-hallucination & minimal surgical diffs)"
echo "   - Universal mirrors: .windsurfrules, .clinerules, .github/copilot-instructions.md"
echo "   - .cursor/rules/*.mdc (Modern modular Cursor rules with glob triggers)"
echo "   - AGENTS.md (Multi-agent collaboration & MCP context protocols)"
echo "   - .agents/rules/* (Agentic Self-Correction, Automated Debugging & Root Cause Analysis (RCA) (Deterministic Bug Reproduction Harnesses, Fault Localization SBFL Ochiai/Tarantula, Automated Git Bisect State Machines, Causal Delta Debugging ddmin, Anti-Masking Disciplines, The 3-Attempt Circuit Breaker & 5-Gate SWE-bench Verification Funnels), Agentic Code Intelligence, Repository Maps, Tree-sitter AST & Surgical Editing (Level 0–2 Code Navigation, PageRank Symbol Graphs, Multi-Pass Tolerant Patching, Blast Radius Transitive Analysis, Pre-Commit AST Checks & SWE-bench Quality Funnels), Agentic Reasoning, Test-Time Compute (TTC) & Verification Loops (Inference-Time Scaling, Process Reward Models PRM vs ORM, Monte Carlo Tree Search MCTS, Upper Confidence Bound UCT, Best-of-N Reranking, Deterministic Backtracking FSM, Dual-Agent Actor-Critic Critique & Scratchpad Token Budgeting), Agentic Browser Automation, Computer-Use & Web Scraping (DOM Distillation, AXTree, Set-of-Marks SoM Grounding, Anti-Fingerprinting Stealth, Turnstile Evasion, CDP Network Interception, Action Verification FSM & Anti-SSRF Firewalls), Agentic Memory Systems, GraphRAG & Episodic Recall (4-Tier Cognitive Architecture, Two-Phase Sleep Consolidation, Temporal Decay Ebbinghaus Forgetting Curves, Tri-Hybrid RRF Retrieval, Belief Revision FSM & Memory Poisoning Defense), Agent Sandboxing, Secure Code Execution Runtimes & Isolated Tool Environments (MicroVMs Firecracker, gVisor runsc, Rootless Containers, Default-Deny seccomp-bpf, Linux cgroups v2 pids.max, Anti-SSRF IMDS 169.254 Egress Blocking, CoW OverlayFS & Process Group Reaping), Prompt Caching, KV Cache Optimization & Context Management (Deterministic Prefix Invariance, Anthropic 4-Breakpoint Strategic Allocation, OpenAI Prefix Caching, vLLM RadixAttention, Lost-in-the-Middle Mitigation, Lossless AST Deduplication & Structured Checkpointing), LLM Gateways, Semantic Caching & Multi-Provider Resilience (Exact Canonical Hash & Vector Semantic Caching, Zero-Buffering SSE Streaming Passthrough, Async Chunk Tapping, Waterfall Provider Cascades, Token-Aware Dual-Tier RPM/TPM Limiting, Complexity Routing & Edge PII Masking), LLM Evals, Guardrails, LLM-as-a-Judge & Automated AI Benchmarking (The 4-Tier Eval Pyramid, G-Eval / MT-Bench Rubrics, RAG Triad Faithfulness & Hallucination Elimination, Position & Verbosity Bias Mitigation, Agent Trajectory Evals & CI/CD Regression Gateways), Autonomous Agents, Tool Calling & Multi-Agent Orchestration (ReAct Loops, Strict Schema Validation, Sandboxed Timeouts, Context Token Budgeting, Indirect Prompt Injection Defense, Circuit Breakers, HITL Approval & Structured Handoffs), Rate Limiting, Traffic Shaping & Resilient Concurrency (Sliding Window, Token Bucket Lua, Dual-Tier LLM RPM/TPM, Little's Law Adaptive Limits, Hedging & Jittered Backoff), Event Sourcing, CQRS & Domain-Driven Event Architecture (EventStore, Aggregates, Projections, Snapshots, Outbox CDC, Expected Version Concurrency, Upcasting & GDPR Crypto-Shredding), Real-Time Collaboration, Local-First Architecture & CRDT Sync (Yjs, Automerge, Replicache, ElectricSQL & HLC), Secrets Management, KMS Envelope Encryption & Zero-Trust Architecture (AWS KMS, HashiCorp Vault, AES-256-GCM Nonce Safety & Blind Indexing), Message Brokers & Queue Protocols (RabbitMQ, AMQP 0-9-1, NATS JetStream & MQTT), Cloud Object Storage & AWS S3 / Blob Systems (Direct Presigned Uploads, Multipart Lifecycle & Zero-Egress R2), Multi-Tenant SaaS Architecture & PostgreSQL RLS Isolation, Financial Ledgers & Payment Systems (Stripe/Adyen/Double-Entry), Vector Databases & Semantic Retrieval (pgvector/Qdrant/Milvus), GraphQL & Apollo Federation Supergraph, NGINX & Ingress Reverse Proxies, Elasticsearch/OpenSearch & Meilisearch, Monorepo & Workspaces (Turborepo/Nx/pnpm), SQLite/DuckDB & Embedded Storage, ClickHouse & Columnar OLAP Analytics, Shell & Bash Automation, Edge Computing & Serverless Workers, Background Jobs & Durable Workflows, Agent Context & Memory Architecture, Auth/OAuth 2.1 & Identity, Redis Caching, Kafka & Event Streaming, gRPC & Protobuf, WebSockets & Real-Time, Observability & Telemetry, Web Performance & Core Web Vitals, Testing Discipline, CI/CD GitHub Actions, Terraform & IaC, Kubernetes/Cloud-Native, Distributed Systems/API, AI/RAG, Security/AppSec, Docker, TypeScript, Go, SQL, Svelte 5/Kit, Vue/Nuxt, React/Next.js, Rust, Python, MCP Server)"
echo "   - .agents/skills/design-system (Apple/Vercel grade UI aesthetics)"
echo "   - .agents/skills/code-discipline (Industrial verification discipline)"
echo "   - .agents/skills/context-engineering (KV cache prefix preservation & memory bank discipline)"
echo ""
echo "Restart your Claude Code / Cursor / Windsurf / Copilot / Pi session to activate."
