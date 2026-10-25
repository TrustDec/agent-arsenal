---
description: Model Context Protocol (MCP) server & tool implementation discipline, stdio transport safety, schema invariants, and context payload limits
globs: **/*mcp*/**/*.{ts,js,py,go,rs},**/mcp.json,**/src/tools/**/*.{ts,js,py},**/server.{ts,js,py}
alwaysApply: false
---

# Model Context Protocol (MCP) Server & Tool Production Invariants

> Add these rules to your project if developing or maintaining MCP (Model Context Protocol) servers, tool plugins, resource providers, or agent extensions (Claude Code, Cursor, Windsurf, Pi, OpenCode).

## 1. Stdio Transport Purity & Stream Safety
- ❌ **TOTAL BAN ON `stdout` POLLUTION**:
  - In stdio-based MCP servers, `stdout` is the dedicated transport channel for JSON-RPC messages. **ANY** unformatted text, diagnostic print, debug trace, or library log written to `stdout` corrupts the JSON-RPC byte stream and crashes the client connection (Claude Desktop, Cursor, Pi, etc.).
  - **Always route logs to `stderr`**:
    - TypeScript/Node: use `console.error(...)` or a logger configured strictly for `process.stderr`. Never use `console.log()`.
    - Python: use `logging.basicConfig(stream=sys.stderr)` or `sys.stderr.write(...)`. Never use `print()` without `file=sys.stderr`.
    - Go: use `log.SetOutput(os.Stderr)` or `fmt.Fprintln(os.Stderr, ...)`.
  - Silence noisy third-party dependencies that write banners or status updates to `stdout`.
- **Clean Process Lifecycle**:
  - Handle `SIGINT` and `SIGTERM` cleanly. Close active file handles, drain pending database connections, and shut down child processes before terminating.
  - Never call `process.exit(0)` prematurely while transport buffers are flushing.

## 2. Strict Tool Schemas & Parameter Descriptions
- **Mandatory Detailed `description` on Every Field**:
  - LLMs do not see your implementation code; they decide when and how to call tools based solely on schema descriptions.
  - Every tool parameter MUST include a clear `description` explaining valid formats (e.g., `"ISO-8601 string (e.g. 2025-01-01T00:00:00Z)"`, `"Absolute POSIX file path"`, `"UUID v4 identifier"`), valid ranges, and fallback defaults.
- **Strict Schema Validation (Zod / Pydantic)**:
  - Never accept open-ended untyped objects (`z.any()`, `z.record(z.any())`, `Dict[str, Any]`).
  - Explicitly define enums for known discrete options:
    ```ts
    // ❌ AI Anti-Pattern: Vague and prone to hallucinated values
    { status: z.string() }

    // ✅ Production Discipline: Constrained enum with clear guidance
    {
      status: z.enum(['pending', 'running', 'completed', 'failed'])
        .describe('Current execution phase to filter by. Defaults to all statuses if omitted.')
    }
    ```
- **Safe Error Signaling (`isError: true`)**:
  - Never throw unhandled exceptions out of tool execution handlers. An uncaught rejection terminates the MCP server process.
  - When an operation fails (e.g., file not found, API rate limit, invalid argument), return a structured tool error response:
    ```ts
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Error: Failed to read file '${path}': File not found. Verify path exists in project workspace.`
        }
      ]
    };
    ```

## 3. Context Window Anti-Rot & Bounded Payload Limits
- **Hard Payload Ceiling**:
  - MCP tool responses are directly injected into the LLM context window. Never return raw multi-megabyte payloads, raw binary dumps, or unpaged 10,000-row database responses.
  - Impose a strict response size limit (e.g., maximum ~20KB or ~4,000 tokens per call).
- **Mandatory Projections & Pagination**:
  - Always support projection (`fields: string[]`) and pagination (`limit: number`, `cursor?: string`).
  - Set a safe default `limit` (e.g., 20 items, max 100 items).
- **Summarization & Truncation Invariants**:
  - When returning large logs, file searches, or tabular data, return the head/tail and append an explicit truncation notice:
    ```text
    [Showing first 50 of 1,240 matches. Use offset=50 or refine query filter to inspect more.]
    ```

## 4. Architectural Segregation: Tools vs Resources vs Prompts
- **MCP Tools (`tools/call`)**:
  - Use tools exclusively for dynamic actions, side-effects, computations, or parameterized searches.
  - For destructive operations (file mutations, git pushes, database writes, external deletions), provide a `dryRun: boolean` parameter (defaulting to `false`) and return a clear preview of affected resources before executing.
- **MCP Resources (`resources/read`)**:
  - Use resources for read-only static or addressable assets (documentation, OpenAPI specs, project configurations, logs).
  - Use standard URI schemes: `workspace://docs/api.json`, `config://environments/staging`.
- **MCP Prompts (`prompts/get`)**:
  - Use prompts for standardized multi-step agent workflows (e.g., code review templates, incident post-mortem analysis).

## 5. Security, Path Traversal & Injection Immunity
- **Path Traversal Immunity**:
  - When a tool accepts file paths or directory paths, resolve them against an allowed workspace root (`path.resolve(allowedRoot, userPath)`).
  - Verify that the resolved path starts with the allowed root directory:
    ```ts
    const safePath = path.resolve(WORKSPACE_ROOT, inputPath);
    if (!safePath.startsWith(WORKSPACE_ROOT)) {
      return {
        isError: true,
        content: [{ type: "text", text: "Security Error: Path traversal outside workspace root is blocked." }]
      };
    }
    ```
- **Subprocess Execution Safety**:
  - Never execute commands via string concatenation or shell interpolation (`exec(\`git log \${branch}\`)`).
  - Always pass discrete argument arrays using `execFile` or `spawn` without shell wrappers:
    ```ts
    // ❌ AI Vulnerability: Shell injection
    exec(`git log ${branchName}`);

    // ✅ Production Discipline: Safe argument vector
    execFile('git', ['log', '--', branchName]);
    ```
- **Secret Hygiene**:
  - Mask credentials, authorization headers, and API keys before logging or returning payloads to the agent.

## 6. HTTP / Server-Sent Events (SSE) Transport & Session Lifecycle
- **Dual Endpoint Architecture**:
  - For remote / multi-client MCP servers, use standard HTTP with SSE:
    - `GET /sse`: Establishes the downstream event stream from server to client.
    - `POST /message?sessionId=<uuid>`: Ingests upstream JSON-RPC client messages.
- **Session Resumption & Isolated State**:
  - Generate a secure cryptographically random `sessionId` (UUIDv4) upon establishing the `/sse` connection.
  - Store transport message buffers per session; never cross-contaminate state across distinct client sessions.
- **SSE Keep-Alive Pings**:
  - Send periodic comment pings (`: ping\n\n`) every 15-30 seconds to prevent intermediate reverse proxies (NGINX, Cloudflare, ALB) from terminating idle SSE connections.
- **Strict CORS & Origin Validation**:
  - Remote MCP SSE endpoints must validate incoming `Origin` and `Host` headers to prevent Cross-Site WebSocket/SSE Hijacking and SSRF.

## 7. Capability Exchange & Bi-directional Sampling
- **Dynamic Capability Negotiation**:
  - During `initialize`, declare exact server capabilities:
    ```json
    {
      "capabilities": {
        "tools": { "listChanged": true },
        "resources": { "subscribe": true, "listChanged": true },
        "prompts": { "listChanged": true },
        "logging": {}
      }
    }
    ```
- **Server-to-Client Sampling (`sampling/createMessage`)**:
  - MCP allows servers to request nested LLM inference from the client agent host (Claude Desktop, Cursor, Pi).
  - Use sampling sparingly for intelligent tool-level tasks (e.g. summarizing a 500-line diff before returning to orchestrator).
  - Always enforce `maxTokens`, `temperature: 0.0`, and provide clear system instructions in sampling requests.

## 8. Progress Tokens & Task Cancellation Invariants
- **Progress Reporting (`notifications/progress`)**:
  - For long-running operations (e.g. database migration, test suite run, heavy build), accept `_meta: { progressToken: string | number }` in tool arguments.
  - Emit periodic `notifications/progress` notifications with `progress` and `total` values so the client harness can render accurate UI progress bars:
    ```json
    {
      "jsonrpc": "2.0",
      "method": "notifications/progress",
      "params": {
        "progressToken": "token-123",
        "progress": 45,
        "total": 100
      }
    }
    ```
- **Cancellation Token Handling (`notifications/cancelled`)**:
  - MCP clients dispatch `notifications/cancelled` when the user aborts an action.
  - Pass an `AbortSignal` through all asynchronous tool handlers; immediately abort background subprocesses and network fetch calls when `notifications/cancelled` is received.

## 9. Standard JSON-RPC 2.0 Error Codes
- Return standard JSON-RPC 2.0 protocol error codes for protocol-level failures:
  - `-32700`: Parse error (invalid JSON received by the server).
  - `-32600`: Invalid Request (payload is not a valid JSON-RPC 2.0 object).
  - `-32601`: Method not found (tool, resource, or prompt method does not exist).
  - `-32602`: Invalid params (Zod/schema validation failure on tool arguments).
  - `-32603`: Internal error (unhandled internal server crash).
- Application-level business errors (e.g. "record not found", "insufficient balance") MUST be returned inside `{ isError: true, content: [...] }` as a successful JSON-RPC response, NOT as protocol-level `-32603` errors.

## 10. Workspace Trust & Client Root Boundaries (`roots/list`)
- **Querying Client Roots**:
  - MCP servers with filesystem or repository access must not assume arbitrary disk access.
  - Request active workspace root URIs from the client via `roots/list`:
    ```json
    {
      "jsonrpc": "2.0",
      "method": "roots/list"
    }
    ```
- **Confining Operations to Declared Roots**:
  - Always canonicalize paths (`filepath.EvalSymlinks`) and reject any tool execution targeting paths outside the declared client roots.
- **Dynamic Root Changes (`notifications/roots/list_changed`)**:
  - Listen for client root updates when user opens/closes folders or workspaces in Claude Desktop, Cursor, or Pi.

## 11. Resource Templates & Cursor-Based Pagination
- **Parameterized Resource Templates (`resources/templates/list`)**:
  - Use RFC 6570 URI templates for dynamic parameterized resources rather than attempting to enumerate infinite static resources:
    ```json
    {
      "resourceTemplates": [
        {
          "uriTemplate": "postgres://tables/{tableName}/schema",
          "name": "Database Table Schema",
          "mimeType": "application/json",
          "description": "Returns the DDL and column schema for a given PostgreSQL table."
        }
      ]
    }
    ```
- **Cursor-Based List Pagination**:
  - When exposing large catalogs of tools or resources (> 50 items), support `cursor` parameter in requests and return `nextCursor` in responses to avoid multi-megabyte JSON-RPC frame overloads.

## 12. Dynamic Tool Federation & Multi-Server MCP Gateways
- **Tool Name Collision Defense via Namespacing**:
  - In architectures where an MCP gateway aggregates tools from multiple downstream MCP servers (e.g., PostgreSQL MCP + GitHub MCP + Kubernetes MCP), tool names frequently collide (`get_status`, `list_items`).
  - Always enforce deterministic prefix namespacing at the gateway level:
    ```ts
    // Prefix federated tool names with server namespace
    const federatedTools = upstreamTools.map(tool => ({
      ...tool,
      name: `${serverNamespace}_${tool.name}`, // e.g. 'postgres_execute_query', 'k8s_get_pods'
      description: `[${serverNamespace}] ${tool.description}`
    }));
    ```
- **Incremental Tool Output Streaming via Notifications**:
  - For long-running operations (builds, test suites, multi-step queries), do not wait until total completion to return a massive monolithic payload.
  - Emit real-time stderr/stdout chunks to the agent client using `notifications/message` or logging notifications:
    ```json
    {
      "jsonrpc": "2.0",
      "method": "notifications/message",
      "params": {
        "level": "info",
        "logger": "git-runner",
        "data": "Running test suite 14/85..."
      }
    }
    ```
- **Session Boundary & Tenant Isolation in Remote SSE Gateways**:
  - Never store tool cache, client tokens, or workspace paths in module-level global variables in SSE MCP servers.
  - All ephemeral state must be strictly keyed by `sessionId` with an automatic eviction TTL (e.g. 30 minutes of inactivity) to prevent cross-client state leaks and memory leaks.



