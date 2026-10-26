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

## 13. Progress Notifications, Tab Completion & Multi-Modal Content Payloads
- **Progress Notifications (`notifications/progress`) for Long-Running Tools**:
  - Tools that execute multi-step operations (large git clones, test suites, container builds) must accept an optional `_meta: { progressToken: string | number }` and emit standard MCP progress notifications to keep the client UI responsive:
    ```ts
    // Emitting progress notifications via MCP server transport
    if (params._meta?.progressToken) {
      await server.notification({
        method: 'notifications/progress',
        params: {
          progressToken: params._meta.progressToken,
          progress: currentStep,
          total: totalSteps,
        },
      });
    }
    ```
- **Contextual Argument Autocompletion (`completion/complete`)**:
  - When exposing tools with dynamic resource identifiers (e.g. database table names, git branches, kubernetes namespaces), implement the `completion/complete` handler so interactive agent TUIs and chat inputs can offer instant tab completion:
    ```ts
    server.setRequestHandler(CompleteRequestSchema, async (request) => {
      const { ref, argument } = request.params;
      if (ref.type === 'ref/prompt' || ref.name === 'execute_query') {
        if (argument.name === 'tableName') {
          return {
            completion: {
              values: ['users', 'orders', 'transactions', 'audit_logs'].filter((t) =>
                t.startsWith(argument.value)
              ),
              hasMore: false,
            },
          };
        }
      }
      return { completion: { values: [] } };
    });
    ```
- **Multi-Modal Content Response Discipline**:
  - Never return raw binary buffers or binary strings directly on stdout.
  - When returning visual graphs, screenshots, or generated charts from MCP tools, format them explicitly as typed image content blocks:
    ```ts
    return {
      content: [
        {
          type: 'text',
          text: 'Captured layout screenshot of component render:',
        },
        {
          type: 'image',
          data: base64PngBuffer,
          mimeType: 'image/png',
        },
      ],
    };
    ```

## 14. Roots Protocol, Filesystem Sandboxing & Concurrency Throttling
- **MCP Roots Protocol (`roots/list`) & Workspace Boundary Enforcement**:
  - Filesystem-manipulating MCP servers must query the client for permitted root directories via `roots/list` and listen for `notifications/roots/list_changed`:
    ```ts
    // Query client workspace roots to establish path boundaries
    const { roots } = await server.request(
      { method: 'roots/list' },
      ListRootsResultSchema
    );

    function assertPathInWorkspace(targetPath: string, allowedRoots: string[]) {
      const resolved = path.resolve(targetPath);
      const isAllowed = allowedRoots.some(root => {
        const rootPath = fileURLToPath(root.uri);
        return resolved.startsWith(rootPath) && !resolved.includes('..');
      });
      if (!isAllowed) {
        throw new McpError(
          ErrorCode.InvalidParams,
          `Access denied: path ${targetPath} is outside permitted workspace roots.`
        );
      }
    }
    ```
- **Parallel Tool Call Concurrency Throttling**:
  - Frontier LLMs frequently emit 5–15 simultaneous tool calls in a single response turn. Spawning unthrottled child processes or database connections simultaneously causes `EMFILE` (too many open files) or connection pool exhaustion.
  - Bound concurrent tool executions with an internal semaphore queue (e.g. max 4 concurrent tool runs, queueing remaining calls with execution timeouts).

## 15. MCP Sampling (`sampling/createMessage`) & Dynamic Resource Templates
- **Reverse LLM Sampling Protocol Boundaries**:
  - MCP allows servers to request LLM completions from the host client via `sampling/createMessage`. This enables servers to delegate fuzzy extraction or summarization back to the user's primary LLM harness without embedding private API keys in the MCP server.
  - **Invariants for Reverse Sampling**:
    - Always check host capabilities: Ensure `clientCapabilities.sampling` is enabled before calling `server.createMessage()`.
    - Set explicit `maxTokens` and reasonable `temperature` (default 0.1–0.2 for deterministic extraction).
    - Guard against infinite recursion: Never call tools inside a sampling request that invoke the same MCP server recursively.
- **Dynamic Resource Templates (`resources/templates/list`)**:
  - When exposing parameterized data (e.g., database tables, Git commits, or log streams), avoid registering thousands of static resources.
  - Expose parameterized URI templates (RFC 6570) via `resources/templates/list`:
    ```ts
    server.setRequestHandler(ListResourceTemplatesRequestSchema, async () => ({
      resourceTemplates: [
        {
          uriTemplate: 'db://{table}/rows/{id}',
          name: 'Database Row by ID',
          mimeType: 'application/json',
          description: 'Fetches a single row from the specified database table by primary key ID',
        },
      ],
    }));
    ```

## 16. Client Cancellation Notifications (`notifications/cancelled`) & Progress Telemetry
- **Propagating Client Abort Signals to In-Flight Operations**:
  - When a user stops generation in Claude Desktop/Cursor or an orchestrator encounters a step timeout, the client sends a `notifications/cancelled` notification with the target `requestId`.
  - ❌ **The Orphan Background Execution Trap**: If the MCP server ignores `notifications/cancelled`, expensive shell commands, LLM sampling calls, or database mutations continue executing in the background, wasting compute, leaking file handles, and corrupting state.
  - ✅ **Production Invariant**: Map incoming JSON-RPC `requestId`s to active `AbortController` instances. Upon receiving `notifications/cancelled`, immediately invoke `controller.abort()` to terminate child processes (`child.kill('SIGTERM')`), cancel HTTP fetches, and release database transactions:
    ```ts
    const activeRequests = new Map<string | number, AbortController>();

    server.setNotificationHandler(CancelledNotificationSchema, (notification) => {
      const controller = activeRequests.get(notification.params.requestId);
      if (controller) {
        controller.abort(notification.params.reason || 'Operation cancelled by MCP client');
        activeRequests.delete(notification.params.requestId);
      }
    });
    ```
- **Progress Token Telemetry (`notifications/progress`)**:
  - For long-running operations (e.g. repo indexing, large downloads, or multi-step migrations), accept an optional `_meta.progressToken` from the client request.
  - Emit intermediate `notifications/progress` updates with `progress` and `total` counters so the client UI displays accurate interactive progress indicators rather than hanging silently.

## 17. MCP Roots Protocol (`roots/list`) & Dynamic Path Sandboxing
- **Querying and Enforcing Client Workspace Boundaries**:
  - When operating in tools that access the local filesystem (`read_file`, `search_files`, `execute_script`), never assume arbitrary filesystem access.
  - ❌ **The Path Traversal Outside Allowed Workspaces Trap**: Allowing tool operations to traverse arbitrarily across `~/.ssh`, `/etc/passwd`, or other projects when the user intended to scope the MCP server to a single project folder.
  - ✅ **Production Invariant**: In MCP servers with filesystem access, implement the `roots/list` client capability query upon initialization. Canonicalize requested paths (`path.resolve` followed by `fs.realpathSync`) and verify that target paths fall strictly within one of the registered client roots:
    ```ts
    import path from 'node:path';
    import fs from 'node:fs';

    export async function validatePathWithinRoots(targetPath: string, server: Server): Promise<string> {
      const rootsResult = await server.request({ method: 'roots/list' }, ListRootsResultSchema);
      const allowedRoots = rootsResult.roots.map((r) => fs.realpathSync(new URL(r.uri).pathname));

      const canonicalTarget = fs.realpathSync(path.resolve(targetPath));
      const isAllowed = allowedRoots.some((root) => canonicalTarget.startsWith(root));

      if (!isAllowed) {
        throw new Error(`Access denied: path "${targetPath}" is outside client workspace roots.`);
      }
      return canonicalTarget;
    }
    ```

## 18. Schema Context Token Economy & Minimalist Tool Declarations
- **Preventing Schema Bloat in Multi-Server Host Environments**:
  - When an agent host (Claude Desktop, Cursor, Pi) connects to multiple MCP servers, the entire JSON Schema of every declared tool is injected into the prompt prefix on **every turn**.
  - ❌ **The 10k-Token Schema Bloat Disaster**: Declaring massive nested objects with hundreds of optional properties, verbose comments, or duplicated enum strings. 20 verbose tools can easily consume 8,000+ tokens of prompt context, exhausting cache boundaries and reducing LLM reasoning depth.
  - ✅ **Production Invariant**: Keep tool parameter schemas lean and flat. Restrict tool declarations to essential parameters, provide concise 1-sentence descriptions, and avoid deep nesting. For complex configurations, accept a path to a configuration file rather than inlining 50-field JSON objects.

## 19. MCP Dynamic Client Sampling Protocol (`sampling/createMessage`)
- **Leveraging Host LLM Reasoning without Hardcoded Keys**:
  - When an MCP server tool needs AI-driven evaluation, sentiment distillation, or schema translation, the tool should NOT bundle separate OpenAI or Anthropic API client libraries or require duplicate API keys in its environment.
  - ❌ **The Leaked Secondary Key & Provider Lock-in Trap**: Requiring users to configure `OPENAI_API_KEY` inside the MCP server configuration just to parse an unstructured string, bypassing user-configured privacy filters and rate limit pools.
  - ✅ **Production Invariant**: Use the Model Context Protocol `sampling/createMessage` client capability. The MCP server requests an LLM completion directly from the connecting host agent (e.g. Claude Code, Desktop, Cursor), inheriting the host's active model tier, user permissions, and privacy boundaries:
    ```ts
    import { Server } from '@modelcontextprotocol/sdk/server/index.js';
    import { CreateMessageRequestSchema } from '@modelcontextprotocol/sdk/types.js';

    export async function requestHostLLMSummary(server: Server, textToSummarize: string): Promise<string> {
      const response = await server.request(
        {
          method: 'sampling/createMessage',
          params: {
            messages: [
              {
                role: 'user',
                content: {
                  type: 'text',
                  text: `Distill the key architectural decisions from this log into 3 bullet points:\n\n${textToSummarize}`,
                },
              },
            ],
            systemPrompt: 'You are an isolated architectural extractor. Be concise and factual.',
            maxTokens: 300,
          },
        },
        CreateMessageRequestSchema
      );

      if (response.content.type === 'text') {
        return response.content.text;
      }
      throw new Error('Unexpected non-text sampling response from host');
    }
    ```

## 20. Remote MCP Transport Resiliency & Session Resumption (`Last-Event-ID`)
- **Handling SSE Transport Network Blips**:
  - When hosting MCP servers over HTTP Server-Sent Events (SSE) in distributed microservices or remote developer containers, transient network disconnections must not abruptly abort in-flight agent sessions.
  - ❌ **The Silent Stream Abandonment Failure**: Dropping client connections on TCP resets and discarding session state, causing the host agent to fail catastrophically midway through an autonomous workflow.
  - ✅ **Production Invariant**: Implement `Last-Event-ID` tracking on SSE streams. The MCP server assigns monotonically incrementing event IDs to all notifications and tool results, buffering the last $K$ events ($K \approx 100$) in memory or Redis. When the client reconnects with `Last-Event-ID`, replay missing messages to seamlessly resume the session without re-running side-effecting operations.

## 21. MCP Tool Cancellation Protocol (`notifications/cancelled`)
- **Handling User Interruption & Agent Timeout Signals**:
  - In autonomous agent harnesses, users frequently click "Stop" or the host's timeout budget fires while a long-running tool (e.g. database migration, test suite execution) is running on the MCP server.
  - ❌ **The Orphaned Heavy Task Disaster**: Ignoring cancellation notifications from the host agent and letting background processes run to completion, tying up system memory, CPU, and holding database locks.
  - ✅ **Production Invariant**: Register a cancellation handler for `notifications/cancelled`. Associate an `AbortController` with each incoming `requestId`. When the host sends a cancellation notification, trigger `abortController.abort()` to immediately terminate child processes and abort database queries:
    ```ts
    const inFlightRequests = new Map<string | number, AbortController>();

    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const abortController = new AbortController();
      const reqId = request.params._meta?.progressToken ?? 'default';
      inFlightRequests.set(reqId, abortController);

      try {
        return await executeToolWithAbort(request.params.name, request.params.arguments, abortController.signal);
      } finally {
        inFlightRequests.delete(reqId);
      }
    });

    server.setNotificationHandler(CancelledNotificationSchema, (notification) => {
      const controller = inFlightRequests.get(notification.params.requestId);
      if (controller) {
        controller.abort();
      }
    });
    ```

## 22. Stdio Stream Multi-Byte UTF-8 Boundary Reassembly
- **The Split Multi-Byte Character Parsing Crash**:
  - In stdio transports, OS pipe buffer chunks (typically 4096 or 8192 bytes) can slice right through the middle of a 3-byte or 4-byte UTF-8 character (e.g. emojis or CJK glyphs). Converting raw buffer chunks directly to strings with `chunk.toString('utf-8')` produces replacement characters (`\uFFFD`) and corrupts JSON-RPC payloads.
  - ✅ **Production Invariant**: Always pipe raw stream buffers through `string_decoder.StringDecoder('utf-8')` in Node.js or maintain a byte buffer prior to UTF-8 decoding to preserve character boundary integrity across chunk boundaries.

## 23. Structured Logging Protocol (`notifications/message`) vs Console Corruption
- **The Stdio Pipe Log Pollution Catastrophe**:
  - Printing diagnostic logs or stack traces to `console.log()` or `process.stdout` in a stdio MCP server. This injects arbitrary unstructured strings into the JSON-RPC wire, crashing the host's parser with fatal deserialization errors.
  - ✅ **Production Invariant**: Route all application logs strictly to `process.stderr` or emit formal MCP logging notifications (`notifications/message` via `server.sendLoggingMessage({ level: 'info', data: ... })`) adhering to the client's configured `logging/setLevel` filter.

## 24. MCP Resource ETag Verification & Cache Hydration
- **Uncached Multi-Megabyte Resource Re-Transmissions**:
  - Repeatedly fetching static resources (such as large schema definitions, system architecture diagrams, or OpenAPI specs) on every agent tool turn, saturating IPC bandwidth and burning host context memory.
  - ✅ **Production Invariant**: Attach content hashes / ETags to resource metadata and support conditional reads or client-side caching to eliminate redundant serialization roundtrips.

