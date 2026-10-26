---
description: Model Context Protocol (MCP) client & host architecture, dynamic tool virtualization, catalog discovery, sampling protocol security, roots workspace sandboxing, child process lifecycle, and prompt injection defense
globs: **/*{mcp_client,mcp_host,tool_router,tool_virtualization,agent_harness,mcp_manager}*.*,**/client.{ts,js,py,go},**/host.{ts,js,py,go},**/mcp/*.{ts,js,py,go},**/.agents/**
alwaysApply: false
---

# Model Context Protocol (MCP) Client Architecture, Dynamic Tool Virtualization & Host Protocols

> Add these rules to your project when building or configuring an AI Agent Harness, MCP Host, Client Tool Virtualizer, or Multi-Server Gateway (Claude Code, Cursor, Windsurf, Roo Code, Goose, Pi harness, LangChain / LangGraph, OpenAI Agents SDK).

---

## 1. Architectural Taxonomy: MCP Host vs Client vs Server Ecosystem

In the Model Context Protocol (MCP) architecture, an **MCP Host** (e.g. Claude Code, Cursor, Pi, custom AI Agent) acts as the runtime orchestrator. It manages connections to multiple independent **MCP Servers** (Postgres, GitHub, Slack, Filesystem, Docker, Memory), discovers available tools, resources, and prompt templates, and arbitrates execution between the Frontier LLM and external machines.

```
┌────────────────────────────────────────────────────────────────────────┐
│                              MCP HOST AGENT                            │
│  ┌───────────────────────┐  ┌───────────────────────────────────────┐  │
│  │   Reasoning Engine    │  │       Tool Virtualization Tier        │  │
│  │  (Claude 3.7 / GPT-4o)│  │ (Catalog Index, Semantic Filter, RRF) │  │
│  └───────────▲───────────┘  └───────────────────▲───────────────────┘  │
│              │ Context Window                   │ Tool Schemas          │
│              ▼                                  ▼                       │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │              Security Firewall & Execution Controller            │  │
│  │  (Env Cleansing, Prompt Injection Escaping, HITL Approval Gates) │  │
│  └───────┬──────────────────────────────┬───────────────────┬───────┘  │
└──────────┼──────────────────────────────┼───────────────────┼──────────┘
           │ stdio (JSON-RPC 2.0)         │ stdio             │ SSE / HTTP Stream
           ▼                              ▼                   ▼
┌──────────────────────┐      ┌──────────────────────┐   ┌──────────────────────┐
│  GitHub MCP Server   │      │  Postgres MCP Server │   │   Remote SaaS MCP    │
│ (Repos, PRs, Issues) │      │  (Read-only queries) │   │ (Slack, Jira, Docs)  │
└──────────────────────┘      └──────────────────────┘   └──────────────────────┘
```

The fundamental failure mode of naive MCP hosts is treating MCP servers as trusted local libraries: passing sensitive environment variables down to child processes, dumping 100+ raw tool schemas directly into system prompts, and letting tool outputs execute unescaped inside LLM context.

---

## 2. The 100-Tool Context Tax & The Need for Tool Virtualization

When an agent connects to 5–15 MCP servers, each exposing 10–25 tools, the agent faces the **100-Tool Context Tax**:

| Metric | Monolithic Schema Injection | Dynamic Tool Virtualization |
| :--- | :--- | :--- |
| **Prompt Token Overhead** | **35,000 – 60,000 tokens** / turn | **1,500 – 3,000 tokens** / turn |
| **Prompt Prefix KV Cache** | Frequently invalidated by shifting schemas | **100% Deterministic & Cache-Stable** |
| **Tool Selection Accuracy** | Severe hallucination & parameter confusion | **High Precision via Focused Context** |
| **Time to First Token (TTFT)** | 3.5s – 8.0s latency penalty | Sub-second streaming start |
| **Token Cost per Turn** | ~$0.15 – $0.35 wasted per user message | <$0.01 tool metadata overhead |

### The Anti-Pattern: Monolithic Schema Ingestion
- ❌ **Dumping All Server Tool Schemas into System Prompts**: Sending every registered MCP tool definition to the LLM on every turn. This induces "Lost in the Middle" attention degradation, causes the model to hallucinate arguments across similar tools (e.g. `github_create_issue` vs `linear_create_issue`), and exhausts TPM/RPM rate limits.

---

## 3. Two-Tier Tool Virtualization: Catalog Discovery & On-Demand Hydration

To scale to hundreds of MCP tools with zero context bloat, implement the **Two-Tier Tool Virtualization Pattern**:

1. **Tier 1 (The Virtual Meta-Catalog)**: Expose only 3 lightweight host-controlled meta-tools in the primary LLM prompt:
   - `mcp_search_tools(query: string, category?: string)`: Returns matching tool names and 1-line descriptions.
   - `mcp_get_tool_schema(tool_name: string)`: Returns the detailed JSON Schema for a specific tool.
   - `mcp_execute_tool(tool_name: string, arguments: Record<string, unknown>)`: Validates parameters against the cached schema and executes the tool on the target MCP server.
2. **Tier 2 (On-Demand Hydration)**: Once the LLM determines which domain tool is required, dynamically hydrate that specific schema into the active tool set for the subsequent turn, or invoke it directly via `mcp_execute_tool`.

```ts
// host/tool_virtualizer.ts
import { z } from 'zod';

export interface VirtualToolManifest {
  serverName: string;
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export class ToolVirtualizer {
  private toolRegistry = new Map<string, VirtualToolManifest>();

  registerTool(serverName: string, tool: { name: string; description?: string; inputSchema: Record<string, unknown> }) {
    const fullName = `${serverName}__${tool.name}`;
    this.toolRegistry.set(fullName, {
      serverName,
      name: tool.name,
      description: tool.description ?? 'No description provided',
      inputSchema: tool.inputSchema,
    });
  }

  // Meta-Tool 1: Return lightweight catalog matches (consumes <300 tokens)
  searchTools(query: string): Array<{ name: string; description: string }> {
    const normalizedQuery = query.toLowerCase();
    const results: Array<{ name: string; description: string }> = [];

    for (const [fullName, manifest] of this.toolRegistry.entries()) {
      if (fullName.toLowerCase().includes(normalizedQuery) || manifest.description.toLowerCase().includes(normalizedQuery)) {
        results.push({ name: fullName, description: manifest.description });
      }
    }
    return results.slice(0, 10);
  }

  // Meta-Tool 2: Hydrate full schema only on demand
  getToolSchema(toolName: string): Record<string, unknown> {
    const tool = this.toolRegistry.get(toolName);
    if (!tool) {
      throw new Error(`Tool '${toolName}' not found in virtual registry.`);
    }
    return {
      name: toolName,
      description: tool.description,
      parameters: tool.inputSchema,
    };
  }
}
```

---

## 4. Semantic Tool Indexing & Dynamic $k$-NN Tool Pruning

For complex tasks requiring spontaneous multi-tool synthesis, pre-index all registered MCP tools into an in-memory vector or BM25 lexical index.

- **Dynamic $k$-NN Tool Ingestion**: Before each LLM generation, retrieve the top $k=5$ most relevant tool schemas based on the latest user prompt and active scratchpad goals.
- **Prefix Preservation Rule**: Keep the retrieved tools array sorted deterministically by tool name (`tools.sort((a, b) => a.name.localeCompare(b.name))`) to maximize prefix matching within the provider's KV cache.
- **Reciprocal Rank Fusion (RRF)**: Combine lexical search (BM25 for exact function names like `git_diff`, `grep_search`) and dense embeddings (for semantic intents like "inspect branch changes") to achieve 99.4% recall on relevant tool identification.

---

## 5. Subprocess Spawning, Stdio Transport Framing & Environment Cleansing

When launching local MCP servers over standard I/O (`stdio`), never inherit the host process environment indiscriminately.

### The Catastrophic Environment Leak
- ❌ **Inheriting `process.env` Wholesale**: Running `child_process.spawn(cmd, args, { env: process.env })`. This leaks `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, AWS IAM credentials, database connection strings, and personal access tokens to arbitrary third-party MCP servers.
- ✅ **Strict Environment Allowlisting**: Construct a clean, isolated environment containing only required operating system paths and explicitly allowlisted server parameters:

```ts
// host/mcp_process.ts
import { spawn, ChildProcess } from 'node:child_process';

const ALLOWED_ENV_VARS = new Set([
  'PATH',
  'HOME',
  'USER',
  'TMPDIR',
  'LANG',
  'LC_ALL',
  'NODE_ENV',
]);

export function spawnCleanMcpServer(
  command: string,
  args: string[],
  serverSpecificEnv: Record<string, string> = {}
): ChildProcess {
  const sanitizedEnv: Record<string, string> = {};

  // 1. Copy only safe system environment variables
  for (const [key, value] of Object.entries(process.env)) {
    if (ALLOWED_ENV_VARS.has(key) && value !== undefined) {
      sanitizedEnv[key] = value;
    }
  }

  // 2. Explicitly overlay server-specific variables (e.g. GITHUB_TOKEN for GitHub MCP)
  Object.assign(sanitizedEnv, serverSpecificEnv);

  // 3. Spawn with detached process group for clean subtree termination
  return spawn(command, args, {
    env: sanitizedEnv,
    stdio: ['pipe', 'pipe', 'pipe'],
    detached: process.platform !== 'win32',
  });
}
```

### Stdio JSON-RPC Stream Framing & Stderr Isolation
- **Strict Content-Length Framing & Delimited Streams**: MCP stdio transport supports both newline-delimited JSON (`\n`) and HTTP-style `Content-Length: ...\r\n\r\n` headers. Buffer chunks carefully to handle fragmented TCP/pipe deliveries without JSON parse crashes.
- **Isolate STDERR to Host Diagnostic Ring Buffers**: Capture child `stderr` into an in-memory rolling ring buffer (500 lines). When a tool fails or the process exits unexpectedly, include the latest stderr lines in the diagnostic trace, but never let stderr spill onto the main client stdout.

---

## 6. Reverse MCP Sampling Protocol (`sampling/createMessage`) Security

The MCP specification defines the **Sampling Protocol**, allowing an MCP server to request an LLM completion from the Host Agent (e.g. a code analysis server requesting a 3-bullet summary of an AST). The Host acts as the LLM provider for the server.

### Host Defense Invariants for Reverse Sampling
1. **Host-Controlled Model Mapping**: Never allow the MCP server to dictate arbitrary model IDs (e.g. requesting expensive `o3-high` or obsolete models). Map server hints (`speed` vs `intelligence`) to host-approved models.
2. **Hard Token & Cost Budgets**: Enforce strict caps on `maxTokens` (e.g. ceiling of 1,000 tokens) and per-server invocation limits (e.g. max 5 sampling requests per user interaction).
3. **Zero-Tool Confinement (Loop Defense)**: Never grant the sampling LLM completion access to tools. If a sampling request could trigger tool calls, a compromised MCP server could construct an infinite recursive loop or invoke privileged tools out of band.
4. **Prompt Injection Scanning on Server Messages**: Server-provided messages must be scrutinized with regex guards and canary checks before passing to the host LLM.

```ts
// host/sampling_handler.ts
import { CreateMessageRequestSchema, CreateMessageResult } from '@modelcontextprotocol/sdk/types.js';

const HOST_MAX_SAMPLING_TOKENS = 1000;
const SERVER_SAMPLING_RATE_LIMIT = 5;

export class McpSamplingHandler {
  private callCounts = new Map<string, number>();

  async handleSamplingRequest(
    serverName: string,
    params: { messages: Array<{ role: string; content: { type: string; text: string } }>; maxTokens?: number }
  ): Promise<{ role: 'assistant'; content: { type: 'text'; text: string }; model: string }> {
    const currentCount = this.callCounts.get(serverName) ?? 0;
    if (currentCount >= SERVER_SAMPLING_RATE_LIMIT) {
      throw new Error(`Sampling rate limit exceeded for MCP server: ${serverName}`);
    }
    this.callCounts.set(serverName, currentCount + 1);

    // Enforce upper bound token ceiling
    const boundedTokens = Math.min(params.maxTokens ?? 500, HOST_MAX_SAMPLING_TOKENS);

    // Host enforces isolated completion (ZERO tools provided to model)
    const completion = await callHostLLM({
      model: 'claude-3-5-haiku-latest', // Economical, fast model for sub-tasks
      system: 'You are an isolated assistant performing a specific data summarization subtask.',
      messages: params.messages,
      maxTokens: boundedTokens,
      tools: [], // ABSOLUTELY ZERO TOOLS GRANTED TO SERVER SAMPLING
    });

    return {
      role: 'assistant',
      content: { type: 'text', text: completion.text },
      model: 'claude-3-5-haiku-latest',
    };
  }
}
```

---

## 7. MCP Roots Protocol (`roots/list`) & Filesystem Sandboxing

The MCP Roots Protocol allows the Host to declare the bounded list of directory roots that MCP servers are permitted to access.

- **Expose Only Workspace Roots**: Return strictly authorized project paths via the `roots/list` request handler (`[{ uri: "file:///path/to/project", name: "workspace" }]`).
- **Dynamic Roots Notifications**: When a user opens or closes a folder in the workspace, emit `notifications/roots/list_changed` to prompt servers to refresh their boundary checks.
- **Host-Side Verification (Defense in Depth)**: Do not trust the MCP server to honor roots boundaries. If a tool call accepts a path argument (e.g. `filePath: "../../.ssh/id_rsa"`), the Host MUST normalize the path and reject it if it resolves outside the declared workspace roots before dispatching the call to the server.

---

## 8. Tool Execution State Machine, Strict Deadlines & Process Tree Pruning

Tool executions can hang indefinitely if an MCP server blocks on an unhandled deadlock, waiting on a hanging network socket, or running an infinite CPU loop.

```
       ┌─────────────────┐
       │   CallTool FSM  │
       └────────┬────────┘
                │
                ▼
   [Validate Input via Zod]
                │
                ├─── (Invalid Schema) ──────► Reject with descriptive validation error
                │
                ▼
     [Dispatch to Server] ──────► [Start Hard Timeout Timer (e.g. 30s)]
                │                                    │
   (Tool Completes in Time)                  (Timeout Fires)
                │                                    │
                ▼                                    ▼
       [Sanitize Output]                  [Send SIGTERM to -PID]
                │                                    │ (Wait 2000ms grace)
                ▼                                    ▼
       [Inject to Context]                 [Send SIGKILL to -PID]
                                                     │
                                                     ▼
                                          [Return Timeout Failure]
```

### The Subprocess Tree Pruning Invariant
- ❌ **Killing Only the Direct Parent PID**: Calling `child.kill('SIGTERM')`. If the MCP server spawned child subprocesses (e.g. `git`, `python`, `node`), killing only the parent leaves orphaned child processes running indefinitely in the background, consuming 100% CPU and locking ports.
- ✅ **Process Group Signal Dispatching (`-PID`)**: Spawn with `detached: true` on POSIX systems. When terminating, send `SIGTERM` (and later `SIGKILL`) to `-child.pid`, terminating the entire process group:

```ts
// host/safe_process_kill.ts
export function terminateProcessGroup(pid: number, gracePeriodMs = 2000): Promise<void> {
  return new Promise((resolve) => {
    try {
      // Send SIGTERM to entire process group
      process.kill(-pid, 'SIGTERM');
    } catch {
      return resolve();
    }

    const timer = setTimeout(() => {
      try {
        // Escalate to SIGKILL if processes remain
        process.kill(-pid, 'SIGKILL');
      } catch {
        // Process group already exited
      }
      resolve();
    }, gracePeriodMs);

    // Do not block Node event loop
    timer.unref();
  });
}
```

---

## 9. Host-Side Prompt Injection Firewalls & Untrusted Content Framing

MCP tool results often ingest untrusted external data (web pages from Puppeteer/Brave, unreviewed PR diffs from GitHub, raw records from PostgreSQL). If fed directly into the LLM context, malicious third-party content can hijack the agent's instructions.

### The 4-Layer Tool Return Firewall
1. **Structural XML Framing**: Wrap tool outputs in explicit boundary tags:
   `<mcp_tool_result server="${serverName}" tool="${toolName}" untrusted_data="true">`
2. **Delimiter Escaping**: Escape any occurrences of `</mcp_tool_result>` or custom delimiter tags within the payload to prevent injection breakouts.
3. **Unicode Steganography Pruning**: Strip Unicode Plane 14 tag characters (`\u{E0001}`–`\u{E007F}`), zero-width characters (`\u200B`–`\u200D`, `\uFEFF`), and bidirectional overrides (`\u202E`).
4. **Secret Redaction**: Scan tool returns for patterns matching API keys (`sk-[a-zA-Z0-9]{32,}`, `ghp_[a-zA-Z0-9]{36}`, JWTs) and redact them before writing to prompt context.

```ts
// host/content_sanitizer.ts
export function sanitizeMcpToolOutput(serverName: string, toolName: string, rawOutput: string): string {
  // 1. Strip Unicode tag smuggling and invisible zero-width chars
  const stripped = rawOutput
    .replace(/[\u{E0001}-\u{E007F}]/gu, '')
    .replace(/[\u200B-\u200D\uFEFF]/g, '');

  // 2. Escape closing XML delimiters
  const escaped = stripped.replaceAll('</mcp_tool_result>', '&lt;/mcp_tool_result&gt;');

  // 3. Redact common secret patterns
  const redacted = escaped
    .replace(/sk-[a-zA-Z0-9_-]{20,}/g, '[REDACTED_API_KEY]')
    .replace(/ghp_[a-zA-Z0-9]{30,}/g, '[REDACTED_GITHUB_TOKEN]')
    .replace(/ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, '[REDACTED_JWT]');

  // 4. Return framed boundary block
  return `<mcp_tool_result server="${serverName}" tool="${toolName}" untrusted_data="true">\n${redacted}\n</mcp_tool_result>`;
}
```

---

## 10. Human-in-the-Loop (HITL) 3-Tier Tool Permission & Approval Matrix

Never allow autonomous agents to execute all MCP tools with equal privilege. Classify every tool into a risk tier:

| Tier | Category | Example Tools | Policy |
| :--- | :--- | :--- | :--- |
| **Tier 1** | **Read-Only Inspection** | `fs_read_file`, `git_status`, `sql_select`, `docker_ps` | **Auto-Approved** (Zero friction) |
| **Tier 2** | **Reversible Mutation** | `fs_write_file` (with git snapshot), `git_checkout`, `sql_insert_staging` | **Auto-Approved with Audit Log & Rollback Snapshot** |
| **Tier 3** | **Irreversible / High Blast Radius** | `shell_exec`, `sql_drop_table`, `git_push_force`, `aws_terminate_instance` | **Mandatory Human-in-the-Loop (HITL) Interactive Confirmation** |

- **Confirmation Contract for Tier 3 Actions**: The agent must display the target server, tool name, exact arguments, and prospective impact, requiring explicit human affirmation (`y` / `approve`) before executing.

---

## 11. Transport Resiliency, Heartbeat `ping` & Circuit Breaker FSM

Remote MCP servers connected via Server-Sent Events (SSE) or long-running stdio processes can silently drop or enter zombie states.

- **Periodic JSON-RPC `ping` Keepalives**: Send a `ping` request every 30 seconds. If a server fails to answer 2 consecutive pings within 5 seconds, mark the connection as degraded.
- **Circuit Breaker States**:
  - **Closed**: Server healthy; all tool calls routed directly.
  - **Open**: Server failed 3 consecutive operations or ping timeouts. Immediately reject tool requests with `{ isError: true, error: "Server unreachable (Circuit Open)" }` to prevent blocking the agent loop.
  - **Half-Open**: After 30s cool-down, send a single test `ping`. If successful, close the circuit; otherwise, reset cool-down.
- **Jittered Exponential Reconnection**: When auto-reconnecting stdio or SSE transports, apply exponential backoff with full jitter ($T = \min(M, B \times 2^{\text{attempt}}) \times \text{random}(0.5, 1.5)$) to eliminate thundering herd storms on server restarts.

---

## 12. Resource Subscriptions (`resources/subscribe`) & Prompt Cache Integration

MCP Resources provide read-only context (documentation, OpenAPI definitions, database schemas).

- **Dynamic Resource Invalidation**: Use `resources/subscribe` to listen for resource updates. When the host receives `notifications/resources/updated(uri)`, invalidate only that resource's local cache.
- **Cache Boundary Alignment**: Place subscribed static resources inside the prompt prefix boundary. When a resource updates, update the specific context block while keeping system instructions intact, preserving partial KV cache acceleration.

---

## 13. Production Checklist for Agent MCP Hosts

Before deploying an autonomous agent harness or MCP host to production:

- [ ] **Environment Allowlisting**: `process.env` is never passed wholesale to child MCP servers; sensitive API keys are stripped.
- [ ] **Tool Virtualization Active**: If total tools $> 20$, Tier 1 catalog search and dynamic schema hydration are enabled.
- [ ] **Reverse Sampling Guarded**: Host-side model selection mapping, rate limits ($N \le 5$), and token caps ($\le 1000$) are enforced; sampling LLM has zero tools.
- [ ] **Roots Filesystem Sandboxing**: Workspace boundaries are declared and validated before path-based tools execute.
- [ ] **Process Group Termination**: Child process timeouts cleanly kill the entire process group (`-PID`) with SIGTERM $\to$ SIGKILL escalation.
- [ ] **Untrusted Output Framing**: Tool results are wrapped in `<mcp_tool_result untrusted_data="true">` with delimiter escaping and secret scrubbing.
- [ ] **HITL Approval Gates**: Destructive operations (Tier 3) require explicit user confirmation.
- [ ] **Circuit Breakers Configured**: Stalled servers fail fast without blocking agent reasoning loops.
